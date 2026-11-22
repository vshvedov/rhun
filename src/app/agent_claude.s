# the Claude Code driver (agent_drv.s's table for AS_kind AG_CLAUDE): it runs the user's installed claude
# on stream-json pipes (agent_conn.s) and turns its records into agent_drv.s's events. The command line,
# the environment and the shapes are pinned in tests/data/claude-shapes/README.txt (Claude Code 2.1.330):
#
#   [WRAPPER] CLAUDE --output-format stream-json --verbose --input-format stream-json
#     --include-partial-messages --permission-prompt-tool=stdio
#     --setting-sources=user,project,local | --setting-sources=user     (the project trusted or not)
#     --max-thinking-tokens=31999 --session-id=UUID | --resume=ID [--permission-mode=MODE]
#
# A new conversation gets our UUID (agent_new); an existing one is continued with --resume and the id
# its transcript is named after.
#
# The first line it is sent is initialize; nothing else goes until its answer (the prompts wait in
# AL_queue, agent_drv.s). A turn streams: message_start names the message, a text block's start is a
# reply row, its deltas add to it, the consolidated assistant record of the block is its finished text;
# result ends the turn. A tool call is a tool row once its block is complete, its result a result row,
# both as the file reader shows them. A tool's permission (can_use_tool, AskUserQuestion and
# ExitPlanMode included) is a card (agentext_card): one at a time, the oldest first, the others waiting
# in AL_reqs; control_cancel_request withdraws one. Records rhun does not use (subagents', thinking, rate
# limits, unknown types and subtypes, lines that are not JSON) are ignored; a request of another kind
# gets an error reply, so Claude never waits for rhun. Everything kept from a record is copied before anything
# may parse again (the JSON arena is global).
.include "rhun.inc"

.equ LINE_VALUES, 1000000       # json_parse_lim's limits for one record
.equ LINE_DEPTH, 200
.equ TRIM_AT, 1 << 20           # a record above this gives the arena's big block back (json_trim)
.equ ERR_TAIL, 2000             # bytes of stderr an error row shows at most
.equ OA_INIT, 1                 # what an answer rhun waits for answers (AL_out's act)
.equ OA_MODE, 2                 # set_permission_mode (nothing is done with its answer)
.equ OA_STOP, 3                 # interrupt (its answer is not needed: the turn's result follows)
.equ QUESTION_OPTS, 16          # a question's card shows its first 16 options
.equ R_ASSIST, 2                # the roles of agents.s's messages
.equ R_INFO, 6

.bss
.p2align 3
cw: .zero SB_SIZE               # the message being written
ksb: .zero SB_SIZE              # an item key, a request id
asb: .zero SB_SIZE              # the arguments built for argv
psb: .zero SB_SIZE              # a transcript path
dsb: .zero SB_SIZE              # the projects folder (find_file)
tsb: .zero SB_SIZE              # a request's id or input as JSON text
found_al: .quad 0               # find_file's session

.text

# ---- start ----

# cl_start(AL*) -> eax 1 with claude started and initialize written, 0 with AL_report saying why. Locals:
#   [rsp] argv (20 slots), [rsp + 160] envp, [rsp + 168] the argv prefix (claude_exe)
cl_start:
    PROLOGUE 176
    mov rbx, rdi
    mov r12, [rbx + AL_as]
    lea rdi, [rbx + AL_report]
    call sb_clear
    call claude_exe
    test rax, rax
    jz .Lcs_missing
    mov [rsp + 168], rax
    xor ecx, ecx                # [wrapper,] claude
1:  cmp ecx, edx
    jae 2f
    mov r8, [rax + rcx*8]
    mov [rsp + rcx*8], r8
    inc ecx
    jmp 1b
2:  lea r13, [rsp + rcx*8]      # the next slot
    test dword ptr [rbx + AL_flags], ALF_NEW
    jnz 21f
    mov rdi, rbx                # an existing conversation: its id is its file's name
    call resume_sid
    test eax, eax
    jz .Lcs_badid
21: lea rsi, [rip + cl_flags]
3:  mov rax, [rsi]
    test rax, rax
    jz 4f
    mov [r13], rax
    add r13, 8
    add rsi, 8
    jmp 3b
4:  xor edi, edi                # the project's own settings only when it is trusted (design 5)
    call wfold_flags
    lea rcx, [rip + .La_sources_all]
    lea rdx, [rip + .La_sources_user]
    test eax, WS_TRUSTED
    cmovz rcx, rdx
    mov [r13], rcx
    lea rax, [rip + .La_thinking]
    mov [r13 + 8], rax
    add r13, 16
    # --session-id=UUID (new) or --resume=ID, then --permission-mode=MODE when [claude] initial_mode
    # names one
    lea rdi, [rip + asb]
    call sb_clear
    lea rsi, [rip + .La_sid]
    lea rax, [rip + .La_resume]
    test dword ptr [rbx + AL_flags], ALF_NEW
    cmovz rsi, rax
    lea rdi, [rip + asb]
    call sb_push_cstr
    lea rdi, [rip + asb]
    lea rsi, [rbx + AL_sid]
    call sb_push_cstr
    lea rdi, [rip + asb]
    xor esi, esi
    call sb_push_byte
    mov r14, [rip + asb + SB_len]   # where the mode's argument starts, 0 without one
    call claude_mode
    test rax, rax
    jz 5f
    mov r15, rax
    lea rdi, [rip + asb]
    lea rsi, [rip + .La_mode]
    call sb_push_cstr
    lea rdi, [rip + asb]
    mov rsi, r15
    call sb_push_cstr
    lea rdi, [rip + asb]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + asb + SB_ptr]
    add rax, r14
    mov [r13], rax
    add r13, 8
5:  mov rax, [rip + asb + SB_ptr]
    mov [r13], rax
    mov qword ptr [r13 + 8], 0
    call claude_env
    mov [rsp + 160], rax
    lea rax, [rip + cl_line]
    mov [rbx + AL_cn + CN_on_line], rax
    lea rax, [rip + cl_close]
    mov [rbx + AL_cn + CN_on_close], rax
    mov [rbx + AL_cn + CN_ctx], rbx
    mov rcx, [r12 + AS_cwd]     # the conversation's checkout, else the project
    test rcx, rcx
    jnz 6f
    mov rcx, [rip + g_project]
6:  lea rdi, [rbx + AL_cn]
    lea rsi, [rsp]
    mov rdx, [rsp + 160]
    call conn_open
    mov r13d, eax
    mov rdi, [rsp + 160]
    call mem_free
    mov rdi, [rsp + 168]
    call mem_free
    test r13d, r13d
    jz .Lcs_fail
    mov qword ptr [rbx + AL_turns], 0
    mov qword ptr [rbx + AL_out + VEC_len], 0
    mov qword ptr [rbx + AL_next], 1        # r1, r2, ... per connection
    mov qword ptr [rbx + AL_row], -1
    mov byte ptr [rbx + AL_rowkey], 0
    mov byte ptr [rbx + AL_msgid], 0
    mov rdi, rbx                # initialize; nothing else goes until it is answered
    mov esi, OA_INIT
    call req_begin
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_subtype]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_initialize]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_hooks]
    call jw_key
    lea rdi, [rip + cw]
    call jw_null
    mov rdi, rbx
    call req_end
    mov eax, 1
    EPILOGUE
.Lcs_fail:
    lea rsi, [rip + .Lr_spawn]
    cmp dword ptr [rbx + AL_cn + CN_err], CN_E_GUARD
    jne 7f
    lea rsi, [rip + .Lr_busy]
7:  lea rdi, [rbx + AL_report]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE
.Lcs_missing:
    lea rdi, [rbx + AL_report]
    lea rsi, [rip + .Lr_missing]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE
.Lcs_badid:
    mov rdi, [rsp + 168]
    call mem_free
    lea rdi, [rbx + AL_report]
    lea rsi, [rip + .Lr_badid]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE

# resume_sid(AL*) -> eax 1 with AL_sid the conversation's id: its transcript's name without ".jsonl"
#   (Claude Code names the file after the id); 0 when that is empty or longer than an id
resume_sid:
    PROLOGUE
    mov rbx, rdi
    mov rax, [rbx + AL_as]
    mov r12, [rax + AS_path]
    xor eax, eax
    test r12, r12
    jz 9f
    mov rdi, r12
    call strlen
    mov r13, rax
    mov rcx, rax
1:  test rcx, rcx               # the name after the last separator
    jz 2f
    cmp byte ptr [r12 + rcx - 1], '/'
    je 2f
    cmp byte ptr [r12 + rcx - 1], '\\'
    je 2f
    dec rcx
    jmp 1b
2:  lea r14, [r12 + rcx]
    mov r15, r13
    sub r15, rcx
    cmp r15, 6
    jb 3f
    lea rdi, [r14 + r15 - 6]
    lea rsi, [rip + .Ljsonl]
    mov edx, 6
    call memeq
    test eax, eax
    jz 3f
    sub r15, 6
3:  xor eax, eax
    test r15, r15
    jz 9f
    cmp r15, 39
    ja 9f
    lea rdi, [rbx + AL_sid]
    mov rsi, r14
    mov rdx, r15
    mov byte ptr [rdi + rdx], 0
    call memmove
    mov eax, 1
9:  EPILOGUE

# ---- writing (one message at a time into cw) ----

# req_begin(AL*, act): {"type":"control_request","request_id":"rN","request":{ with N kept in AL_out
req_begin:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    mov esi, r12d
    call out_add
    mov r13, rax
    lea rdi, [rip + cw]
    call jw_begin
    lea rdi, [rip + cw]
    call jw_obj
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_type]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_control_request]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_request_id]
    call jw_key
    lea rdi, [rip + ksb]
    call sb_clear
    lea rdi, [rip + ksb]
    mov esi, 'r'
    call sb_push_byte
    lea rdi, [rip + ksb]
    mov rsi, r13
    call sb_push_u64
    lea rdi, [rip + cw]
    mov rsi, [rip + ksb + SB_ptr]
    mov rdx, [rip + ksb + SB_len]
    call jw_str
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_request]
    call jw_key
    lea rdi, [rip + cw]
    call jw_obj
    EPILOGUE

# req_end(AL*) -> eax 1 written: the request and its envelope closed and sent; one the connection
#   refused takes its number back out of AL_out, so no answer is waited for
req_end:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + cw]
    call jw_end_obj
    lea rdi, [rip + cw]
    call jw_end_obj
    mov rdi, rbx
    call cl_write
    test eax, eax
    jnz 9f
    cmp qword ptr [rbx + AL_out + VEC_len], 0
    je 9f
    dec qword ptr [rbx + AL_out + VEC_len]
9:  EPILOGUE

# cl_write(AL*) -> eax 1 when the connection took cw as one line
cl_write:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + cw]
    call jw_line
    lea rdi, [rbx + AL_cn]
    mov rsi, [rip + cw + SB_ptr]
    mov rdx, [rip + cw + SB_len]
    call conn_write
    EPILOGUE

# out_add(AL*, act) -> rax the number of rhun's next request, kept with what its answer is for
out_add:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, [rbx + AL_next]
    inc qword ptr [rbx + AL_next]
    lea rdi, [rbx + AL_out]
    mov esi, 16
    call vec_push
    mov [rax], r13
    mov [rax + 8], r12
    mov rax, r13
    EPILOGUE

# out_take(AL*, n) -> eax what the answer to request n is for (OA_*), 0 when rhun waits for none
out_take:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, [rdi + AL_out + VEC_len]
    jae 9f
    mov rdx, rcx
    shl rdx, 4
    add rdx, [rdi + AL_out + VEC_ptr]
    cmp [rdx], rsi
    je 2f
    inc rcx
    jmp 1b
2:  mov eax, [rdx + 8]
    mov rcx, [rdi + AL_out + VEC_len]   # the last slot takes its place
    dec rcx
    mov [rdi + AL_out + VEC_len], rcx
    shl rcx, 4
    add rcx, [rdi + AL_out + VEC_ptr]
    mov r8, [rcx]
    mov [rdx], r8
    mov r8, [rcx + 8]
    mov [rdx + 8], r8
9:  ret

# cl_send(AL*, ptr, len) -> eax 1 written: {"type":"user","message":{"role":"user","content":[{"type":
#   "text","text":T}]},"parent_tool_use_id":null,"session_id":""}
cl_send:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + cw]
    call jw_begin
    lea rdi, [rip + cw]
    call jw_obj
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_type]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_user]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_message]
    call jw_key
    lea rdi, [rip + cw]
    call jw_obj
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_role]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_user]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_content]
    call jw_key
    lea rdi, [rip + cw]
    call jw_arr
    lea rdi, [rip + cw]
    call jw_obj
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_type]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_text]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_text]
    call jw_key
    lea rdi, [rip + cw]
    mov rsi, r12
    mov rdx, r13
    call jw_str
    lea rdi, [rip + cw]
    call jw_end_obj             # the text block
    lea rdi, [rip + cw]
    call jw_end_arr
    lea rdi, [rip + cw]
    call jw_end_obj             # the message
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_parent]
    call jw_key
    lea rdi, [rip + cw]
    call jw_null
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_session_id]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lempty]
    call jw_cstr
    lea rdi, [rip + cw]
    call jw_end_obj
    mov rdi, rbx
    call cl_write
    test eax, eax
    jz 9f
    inc qword ptr [rbx + AL_turns]
9:  EPILOGUE

# cl_stop(AL*): Stop: {"type":"control_request","request_id":"rN","request":{"subtype":"interrupt"}}, once
#   a turn (ALF_STOP_ASKED until its result). Claude withdraws the requests that wait (control_cancel_request)
#   and ends the turn with an aborted result: the "Interrupted" row (ev_turn_end)
cl_stop:
    PROLOGUE
    mov rbx, rdi
    test dword ptr [rbx + AL_flags], ALF_STOP_ASKED
    jnz 9f
    cmp dword ptr [rbx + AL_cn + CN_state], CN_UP
    jne 9f
    or dword ptr [rbx + AL_flags], ALF_STOP_ASKED
    mov rdi, rbx
    mov esi, OA_STOP
    call req_begin
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_subtype]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_interrupt]
    call jw_cstr
    mov rdi, rbx
    call req_end
9:  EPILOGUE

# cl_release(AL*): claude's input ends; it exits by itself, the stop sequence follows (agent_conn.s)
cl_release:
    lea rdi, [rdi + AL_cn]
    jmp conn_end_input

# cl_held(AL*) -> eax HOLDER_NONE
cl_held:
    mov eax, HOLDER_NONE
    ret

# ---- reading ----

# cl_line(CN*, ptr, len): one record from claude, dispatched on its type
cl_line:
    PROLOGUE
    mov rbx, [rdi + CN_ctx]
    mov r13, rdx
    mov rdi, rsi
    mov rsi, rdx
    mov edx, LINE_VALUES
    mov ecx, LINE_DEPTH
    call json_parse_lim
    test rax, rax
    jz 8f                       # not JSON: ignored
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_type]
    call json_get
    mov r15, rax
    lea r12, [rip + cl_types]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 8f                       # a type rhun does not use
    mov rdi, r15
    call json_is
    test eax, eax
    jnz 2f
    add r12, 16
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r14
    call [r12 + 8]              # handler(AL*, record)
8:  cmp r13, TRIM_AT
    jbe 9f
    call json_trim
9:  EPILOGUE

# is_sub(record) -> eax 1 when it is a subagent's (parent_tool_use_id is set): not shown
is_sub:
    push rbx
    lea rsi, [rip + .Lk_parent]
    call json_get
    mov rdi, rax
    call json_type
    xor ecx, ecx
    cmp eax, JT_STR
    sete cl
    mov eax, ecx
    pop rbx
    ret

# jstr(obj, key) -> rax ptr, rdx len of a string member (0, 0 otherwise)
jstr:
    push rbx
    call json_get
    mov rdi, rax
    call json_str
    pop rbx
    ret

# jint(obj, key) -> rax the member's integer value (0 when it is none)
jint:
    push rbx
    call json_get
    mov rdi, rax
    call json_int
    pop rbx
    ret

# set_msgid(AL*, ptr, len): the message the stream is in (at most 63 bytes kept)
set_msgid:
    cmp rdx, 63
    jbe 1f
    mov edx, 63
1:  lea rdi, [rdi + AL_msgid]
    mov byte ptr [rdi + rdx], 0
    push rax
    call memmove
    pop rax
    ret

# item_key(AL*, index) -> rax ptr, rdx len: "MESSAGE_ID#INDEX", a text block's key (ksb)
item_key:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + ksb]
    call sb_clear
    lea rdi, [rip + ksb]
    lea rsi, [rbx + AL_msgid]
    call sb_push_cstr
    lea rdi, [rip + ksb]
    mov esi, '#'
    call sb_push_byte
    lea rdi, [rip + ksb]
    mov rsi, r12
    call sb_push_u64
    mov rax, [rip + ksb + SB_ptr]
    mov rdx, [rip + ksb + SB_len]
    EPILOGUE

# h_stream(AL*, record): a partial message's event: message_start, a block's start, a text delta
h_stream:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call is_sub
    test eax, eax
    jnz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_event]
    call json_get
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_type]
    call json_get
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .Lv_message_start]
    call json_is
    test eax, eax
    jnz .Lhs_start
    mov rdi, r14
    lea rsi, [rip + .Lv_block_start]
    call json_is
    test eax, eax
    jnz .Lhs_block
    mov rdi, r14
    lea rsi, [rip + .Lv_block_delta]
    call json_is
    test eax, eax
    jnz .Lhs_delta
9:  EPILOGUE
.Lhs_start:                     # the API message's id: with a block's index it keys the block's row
    mov rdi, r13
    lea rsi, [rip + .Lk_message]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_id]
    call jstr
    mov rdi, rbx
    mov rsi, rax
    call set_msgid
    mov qword ptr [rbx + AL_row], -1
    mov byte ptr [rbx + AL_rowkey], 0
    EPILOGUE
.Lhs_block:
    mov rdi, r13
    lea rsi, [rip + .Lk_index]
    call jint
    mov [rbx + AL_block], rax
    mov rdi, r13
    lea rsi, [rip + .Lk_content_block]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_text]
    call json_is
    test eax, eax
    jnz 1f
    mov qword ptr [rbx + AL_row], -1    # another kind of block: text streams into no row now
    mov byte ptr [rbx + AL_rowkey], 0
    EPILOGUE
1:  mov rdi, rbx
    mov rsi, [rbx + AL_block]
    call item_key
    mov rdi, rbx                # an empty row the deltas fill
    mov rsi, rax
    lea rcx, [rip + .Lempty]
    xor r8d, r8d
    xor r9d, r9d
    call ev_text
    EPILOGUE
.Lhs_delta:
    mov rdi, r13
    lea rsi, [rip + .Lk_delta]
    call json_get
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_text_delta]
    call json_is
    test eax, eax
    jz 9b
    mov rdi, r13
    lea rsi, [rip + .Lk_index]
    call jint
    mov rdi, rbx
    mov rsi, rax
    call item_key
    mov r12, rax
    mov r13, rdx
    mov rdi, r14
    lea rsi, [rip + .Lv_text]
    call jstr
    mov rdi, rbx
    mov rsi, r12
    mov rcx, rax
    mov r8, rdx
    mov rdx, r13
    xor r9d, r9d
    call ev_text
    EPILOGUE

# h_assistant(AL*, record): finished content blocks (one record a block, the message's id, no index: it
#   is the block the latest content_block_start began). The record's model is noted as the file reader
#   notes it (agents_reply_model); a text block's text replaces what streamed under its key and its row
#   gets the label the file would give it; thinking is not shown. Locals: [rsp] the model, [rsp + 8] its
#   length, [rsp + 16] and [rsp + 24] the message id, then a block's key
h_assistant:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call is_sub
    test eax, eax
    jnz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_message]
    call json_get
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_model]
    call jstr
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, [rbx + AL_as]
    mov rsi, rax
    mov rcx, -1
    call agents_reply_model
    mov rdi, r13                # without partial messages no message_start named it
    lea rsi, [rip + .Lk_id]
    call jstr
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    lea rdi, [rbx + AL_msgid]
    call strlen
    cmp rax, [rsp + 24]
    jne 1f
    lea rdi, [rbx + AL_msgid]
    mov rsi, [rsp + 16]
    mov rdx, [rsp + 24]
    call memeq
    test eax, eax
    jnz 2f
1:  mov rdi, rbx
    mov rsi, [rsp + 16]
    mov rdx, [rsp + 24]
    call set_msgid
2:  mov rdi, r13
    lea rsi, [rip + .Lk_content]
    call json_get
    mov r14, rax
    xor r15d, r15d              # the block
3:  mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 9f
    mov rdi, r14
    mov esi, r15d
    call json_at
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_type]
    call json_get
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lv_text]
    call json_is
    test eax, eax
    jz 5f
    mov rdi, rbx
    mov rsi, [rbx + AL_block]
    add rsi, r15
    call item_key
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    mov rdi, r12
    lea rsi, [rip + .Lv_text]
    call jstr
    mov rdi, rbx
    mov rsi, [rsp + 16]
    mov rcx, rax
    mov r8, rdx
    mov rdx, [rsp + 24]
    mov r9d, 1                  # the finished text
    call ev_text
    mov rdi, [rbx + AL_as]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    mov rcx, rax
    call agents_reply_model
    jmp 7f
5:  mov rdi, r13                # a tool call: its row, as the file reader shows it
    lea rsi, [rip + .Lv_tool_use]
    call json_is
    test eax, eax
    jz 7f
    mov rdi, r12
    lea rsi, [rip + .Lk_input]
    call json_get
    mov rdi, rax
    call agents_tool_summary
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    mov rdi, r12
    lea rsi, [rip + .Lk_name]
    call jstr
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    call ev_tool
7:  inc r15d
    jmp 3b
9:  EPILOGUE

# h_user(AL*, record): what Claude sends as the user's: a tool's results as result rows, as the file
#   reader shows them. The user's own prompts (rhun showed them when sent), replayed copies, notices and a
#   subagent's records are not shown
h_user:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call is_sub
    test eax, eax
    jnz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_isReplay]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_TRUE
    je 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_isMeta]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_TRUE
    je 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_message]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_content]
    call json_get
    mov r13, rax
    xor r14d, r14d
1:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae 9f
    mov rdi, r13
    mov esi, r14d
    call json_at
    mov r15, rax
    inc r14d
    mov rdi, rax
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_tool_result]
    call json_is
    test eax, eax
    jz 1b
    mov rdi, r15
    lea rsi, [rip + .Lk_content]
    call json_get
    mov rdi, rax
    call agents_text_of
    mov rdi, rbx
    mov rsi, rax
    call ev_result_row
    jmp 1b
9:  EPILOGUE

# h_system(AL*, record): init (the session's id, its folder, the mode) and status (the mode)
h_system:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lv_init]
    call json_is
    test eax, eax
    jnz 1f
    mov rdi, r13
    lea rsi, [rip + .Lv_status]
    call json_is
    test eax, eax
    jz 9f
    jmp 5f
1:  mov rdi, r12                # the id it runs under: ours (--session-id), else it is taken
    lea rsi, [rip + .Lk_session_id]
    call jstr
    test rdx, rdx
    jz 4f
    cmp rdx, 39
    ja 4f
    mov r14, rax
    mov r15, rdx
    lea rdi, [rbx + AL_sid]
    call strlen
    cmp rax, r15
    jne 2f
    lea rdi, [rbx + AL_sid]
    mov rsi, r14
    mov rdx, r15
    call memeq
    test eax, eax
    jnz 4f
2:  lea rdi, [rbx + AL_sid]
    mov rsi, r14
    mov rdx, r15
    mov byte ptr [rdi + rdx], 0
    call memmove
    or dword ptr [rbx + AL_flags], ALF_NEW  # its path is computed again below
4:  test dword ptr [rbx + AL_flags], ALF_NEW
    jz 5f
    mov rdi, r12                # a new conversation's path: from the folder the CLI reports
    lea rsi, [rip + .Lk_cwd]
    call jstr
    test rdx, rdx
    jz 5f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r14, rax
    mov rdi, rbx
    mov rsi, r14
    call set_path
    mov rdi, r14
    call mem_free
5:  mov rdi, r12                # the permission mode
    lea rsi, [rip + .Lk_permissionMode]
    call jstr
    test rdx, rdx
    jz 9f
    mov rdi, rbx
    mov rsi, rax
    call ev_mode
9:  EPILOGUE

# set_path(AL*, cwd cstr): the session's transcript path is the one Claude Code gives AL_sid in that folder
set_path:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    mov rsi, r12
    lea rdx, [rbx + AL_sid]
    call claude_transcript
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, [rip + psb + SB_ptr]
    call take_path
9:  EPILOGUE

# take_path(AL*, path cstr): the session's AS_path becomes a copy of it, when it differs
take_path:
    PROLOGUE
    mov rbx, [rdi + AL_as]
    mov r12, rsi
    mov rdi, [rbx + AS_path]
    test rdi, rdi
    jz 1f
    call strcmp_eq
    test eax, eax
    jnz 9f
1:  mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov rdi, [rbx + AS_path]
    mov [rbx + AS_path], rax
    call mem_free
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# h_result(AL*, record): the turn's end. Before the handshake it is the start's failure (an id the CLI
#   does not know)
h_result:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi                # the text: errors[0], else result
    lea rsi, [rip + .Lk_errors]
    call json_get
    mov rdi, rax
    xor esi, esi
    call json_at
    mov rdi, rax
    call json_str
    test rdx, rdx
    jnz 1f
    mov rdi, r12
    lea rsi, [rip + .Lk_result]
    call jstr
1:  mov r13, rax
    mov r14, rdx
    cmp dword ptr [rbx + AL_state], ALS_STARTING
    jne 2f
    test r14, r14
    jnz 11f
    lea r13, [rip + .Lr_early]
    mov rdi, r13
    call strlen
    mov r14, rax
11: mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call ev_failed
    lea rdi, [rbx + AL_cn]
    call conn_end_input
    EPILOGUE
2:  mov rdi, r12
    lea rsi, [rip + .Lk_is_error]
    call json_get
    mov rdi, rax
    call json_bool
    mov r15d, TE_DONE
    test eax, eax
    jz 4f
    mov r15d, TE_INTERRUPTED
    test dword ptr [rbx + AL_flags], ALF_STOP_ASKED
    jnz 4f
    mov rdi, r12
    lea rsi, [rip + .Lk_terminal]
    call jstr
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_aborted]
    mov ecx, 7
    call str_starts
    test eax, eax
    jnz 4f
    mov r15d, TE_ERROR
4:  mov rdi, rbx
    mov esi, r15d
    mov rdx, r13
    mov rcx, r14
    call ev_turn_end
    test dword ptr [rbx + AL_flags], ALF_NEW
    jz 9f
    mov rdi, rbx                # a new conversation: its file is where the CLI wrote it
    call find_file
9:  EPILOGUE

# find_file(AL*): a new conversation whose file is not at AS_path yet takes the one named AL_sid.jsonl in
#   any folder of <claude dir>/projects (the CLI cuts a long folder name and adds a hash); once its file
#   exists it is new no longer
find_file:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AL_as]
    mov rdi, [r12 + AS_path]
    test rdi, rdi
    jz 1f
    call file_missing
    test eax, eax
    jz 8f
1:  lea rdi, [rip + dsb]
    call sb_clear
    lea rdi, [rip + dsb]
    call claude_dir
    test eax, eax
    jz 9f
    lea rdi, [rip + dsb]
    lea rsi, [rip + .Lprojects]
    call sb_push_cstr
    mov [rip + found_al], rbx
    mov rdi, [rip + dsb + SB_ptr]
    lea rsi, [rip + find_one]
    mov rdx, rbx
    call dir_each
    mov qword ptr [rip + found_al], 0
    mov rdi, [r12 + AS_path]
    test rdi, rdi
    jz 9f
    call file_missing
    test eax, eax
    jnz 9f
8:  and dword ptr [rbx + AL_flags], ~ALF_NEW
9:  EPILOGUE

# find_one(AL*, name, is_dir): dir_each's step: a folder that holds AL_sid.jsonl gives the path (the first)
find_one:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test edx, edx
    jz 9f
    cmp qword ptr [rip + found_al], 0
    je 9f
    lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    mov rsi, [rip + dsb + SB_ptr]
    call sb_push_cstr
    lea rdi, [rip + psb]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + psb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + psb]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + psb]
    lea rsi, [rbx + AL_sid]
    call sb_push_cstr
    lea rdi, [rip + psb]
    lea rsi, [rip + .Ljsonl]
    call sb_push_cstr
    mov rdi, [rip + psb + SB_ptr]
    call file_missing
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, [rip + psb + SB_ptr]
    call take_path
    mov qword ptr [rip + found_al], 0   # the first one found
9:  EPILOGUE

# ---- Claude's requests ----

# h_request(AL*, record): a request of Claude's. can_use_tool waits for the user (h_can_use); any other
#   kind gets an error reply, its id echoed as it came (a string or a number), so Claude never waits
h_request:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    lea rsi, [rip + .Lk_request]
    call json_get
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_can_use_tool]
    call json_is
    test eax, eax
    jz 1f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call h_can_use
    EPILOGUE
1:  mov rdi, r12
    lea rsi, [rip + .Lk_request_id]
    call json_get
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lv_unsupported]
    call err_reply
    EPILOGUE

# err_reply(AL*, id jv, text cstr): {"type":"control_response","response":{"subtype":"error",
#   "request_id":ID,"error":TEXT}}
err_reply:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + cw]
    call jw_begin
    lea rdi, [rip + cw]
    call jw_obj
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_type]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_control_response]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_response]
    call jw_key
    lea rdi, [rip + cw]
    call jw_obj
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_subtype]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_error]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_request_id]
    call jw_key
    lea rdi, [rip + cw]
    mov rsi, r12
    call jw_jv
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_error]
    call jw_key
    lea rdi, [rip + cw]
    mov rsi, r13
    call jw_cstr
    lea rdi, [rip + cw]
    call jw_end_obj
    lea rdi, [rip + cw]
    call jw_end_obj
    mov rdi, rbx
    call cl_write
    EPILOGUE

# h_can_use(AL*, record, request): a tool's permission, a question or a plan Claude waits on: kept in
#   AL_reqs (AQ: the id and the input as JSON text, so both go back unchanged; the tool; the tool call's
#   id) and the oldest one's card shows. Past AQ_MAX waiting it gets an error reply; an input rhun cannot
#   echo whole is denied at once. ExitPlanMode's plan is a reply row. Locals: [rsp] jw_jv's result
h_can_use:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp qword ptr [rbx + AL_reqs + VEC_len], AQ_MAX
    jb 1f
    mov rdi, r12
    lea rsi, [rip + .Lk_request_id]
    call json_get
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lr_toomany]
    call err_reply
    EPILOGUE
1:  mov edi, AQ_SIZE
    call mem_alloc
    mov r14, rax
    mov dword ptr [r14 + AQ_kind], AQK_PERMISSION
    lea rdi, [rip + tsb]        # the id, as it came
    call jw_begin
    mov rdi, r12
    lea rsi, [rip + .Lk_request_id]
    call json_get
    lea rdi, [rip + tsb]
    mov rsi, rax
    call jw_jv
    call tsb_dup
    mov [r14 + AQ_id], rax
    mov rdi, r13
    lea rsi, [rip + .Lk_tool_name]
    call jstr
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [r14 + AQ_tool], rax
    mov rdi, r13
    lea rsi, [rip + .Lk_tool_use_id]
    call jstr
    test rdx, rdx
    jz 2f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [r14 + AQ_tuid], rax
2:  # the input, written at the depth an answer writes its members (three objects opened, then their
    # bytes cleared: the nesting stays), so what passes here passes there
    lea rdi, [rip + tsb]
    call jw_begin
    lea rdi, [rip + tsb]
    call jw_obj
    lea rdi, [rip + tsb]
    call jw_obj
    lea rdi, [rip + tsb]
    call jw_obj
    lea rdi, [rip + tsb]
    call sb_clear
    mov rdi, r13
    lea rsi, [rip + .Lk_input]
    call json_get
    mov r15, rax
    lea rdi, [rip + tsb]
    mov rsi, rax
    call jw_jv
    mov [rsp], eax
    call tsb_dup
    mov [r14 + AQ_input], rax
    mov rax, [rip + tsb + SB_len]
    mov [r14 + AQ_inlen], rax
    cmp dword ptr [rsp], 0
    jne 3f
    mov rdi, rbx
    mov rsi, r14
    lea rdx, [rip + .Lr_noecho]
    xor ecx, ecx
    call reply_deny
    mov rdi, r14
    call agent_aq_free
    EPILOGUE
3:  mov rdi, [r14 + AQ_tool]
    lea rsi, [rip + .Lt_ask]
    call strcmp_eq
    test eax, eax
    jz 4f
    mov dword ptr [r14 + AQ_kind], AQK_QUESTION     # a card per question, in order
    mov rdi, r15
    lea rsi, [rip + .Lk_questions]
    call json_get
    mov rdi, rax
    call json_len
    mov eax, eax
    mov [r14 + AQ_count], rax
    jmp 6f
4:  mov rdi, [r14 + AQ_tool]
    lea rsi, [rip + .Lt_plan]
    call strcmp_eq
    test eax, eax
    jz 5f
    mov dword ptr [r14 + AQ_kind], AQK_PLAN
    mov rdi, r15                # the plan, as a reply above its card
    lea rsi, [rip + .Lk_plan]
    call jstr
    test rdx, rdx
    jz 6f
    mov rdi, rbx
    mov esi, R_ASSIST
    mov rcx, rdx
    mov rdx, rax
    call ev_note
    jmp 6f
5:  mov rdi, r14                # a permission: the question for its tool
    mov rsi, r15
    call perm_prompt
6:  lea rdi, [rbx + AL_reqs]
    mov esi, 8
    call vec_push
    mov [rax], r14
    cmp qword ptr [rbx + AL_reqs + VEC_len], 1
    jne 9f
    mov rdi, rbx                # nothing else waits: its card shows
    call req_show
9:  EPILOGUE

# tsb_dup() -> rax a copy of tsb's bytes (a cstr)
tsb_dup:
    mov rdi, [rip + tsb + SB_ptr]
    mov rsi, [rip + tsb + SB_len]
    jmp mem_dup

# perm_prompt(AQ*, input jv): AQ_q, the card's question for the tool (the extension's wording): "Allow
#   this bash command?" and the command's first line, "Make this edit to FILE?", "Allow write to FILE?",
#   "Allow reading from FILE?", "Allow fetching this url?" and the url, else "Do you want to proceed
#   with TOOL?"
perm_prompt:
    PROLOGUE
    mov r12, rdi
    mov rdi, rsi
    call agents_tool_summary
    mov r14, rax
    xor ecx, ecx                # its first line
1:  cmp rcx, rdx
    jae 2f
    cmp byte ptr [r14 + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov r15, rcx
    lea rdi, [rip + psb]
    call sb_clear
    lea rbx, [rip + perm_qs]
3:  mov rsi, [rbx]
    test rsi, rsi
    jz 5f
    mov rdi, [r12 + AQ_tool]
    call strcmp_eq
    test eax, eax
    jnz 4f
    add rbx, 24
    jmp 3b
4:  lea rdi, [rip + psb]
    mov rsi, [rbx + 8]
    call sb_push_cstr
    lea rdi, [rip + psb]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    lea rdi, [rip + psb]
    mov rsi, [rbx + 16]
    call sb_push_cstr
    jmp 6f
5:  lea rdi, [rip + psb]
    lea rsi, [rip + .Lq_proceed]
    call sb_push_cstr
    lea rdi, [rip + psb]
    mov rsi, [r12 + AQ_tool]
    call sb_push_cstr
    lea rdi, [rip + psb]
    lea rsi, [rip + .Lq_mark]
    call sb_push_cstr
6:  mov rdi, [rip + psb + SB_ptr]
    mov rsi, [rip + psb + SB_len]
    call trim
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [r12 + AQ_q], rax
    EPILOGUE

# req_show(AL*): the oldest waiting request's card; one whose card cannot be shown is denied and the
#   next one tried. With none left the turn goes on (WORKING), or is over (READY)
req_show:
    PROLOGUE
    mov rbx, rdi
1:  cmp qword ptr [rbx + AL_reqs + VEC_len], 0
    je 8f
    mov rax, [rbx + AL_reqs + VEC_ptr]
    mov r12, [rax]
    mov eax, [r12 + AQ_kind]
    cmp eax, AQK_QUESTION
    jne 2f
    mov rdi, rbx
    mov rsi, r12
    call show_question
    jmp 4f
2:  lea r13, [rip + opts_plan]
    lea r14, [rip + .Lq_plan]
    cmp eax, AQK_PLAN
    je 3f
    lea r13, [rip + opts_yes_no]
    mov r14, [r12 + AQ_q]
3:  mov rdi, r14
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    mov rcx, rax
    mov r8, r13
    mov r9d, 2
    call ev_request
4:  test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lr_noshow]
    xor ecx, ecx
    call reply_deny
    mov rdi, rbx
    mov rsi, r12
    call ev_request_gone
    jmp 1b
8:  cmp dword ptr [rbx + AL_state], ALS_WAITING
    jne 9f
    mov esi, ALS_WORKING
    cmp qword ptr [rbx + AL_turns], 0
    jne 81f
    mov esi, ALS_READY
81: mov rdi, rbx
    call agent_state_set
9:  EPILOGUE

# show_question(AL*, AQ*) -> eax 1 shown: the card of question AQ_n of an AskUserQuestion: its text, its
#   options' labels (at most 16). The input is parsed again (the arena is global: nothing may hold a value
#   of an earlier parse). Locals: [rsp] the labels
show_question:
    PROLOGUE 136
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [r12 + AQ_input]
    mov rsi, [r12 + AQ_inlen]
    mov edx, LINE_VALUES
    mov ecx, LINE_DEPTH
    call json_parse_lim
    test rax, rax
    jz 8f
    mov rdi, rax
    lea rsi, [rip + .Lk_questions]
    call json_get
    mov rdi, rax
    mov esi, [r12 + AQ_n]
    call json_at
    test rax, rax
    jz 8f
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_options]
    call json_get
    mov r14, rax
    xor r15d, r15d
1:  cmp r15d, QUESTION_OPTS
    jae 2f
    mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 2f
    mov rdi, r14
    mov esi, r15d
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_label]
    call jstr
    test rax, rax
    jnz 11f
    lea rax, [rip + .Lempty]
11: mov [rsp + r15*8], rax
    inc r15d
    jmp 1b
2:  mov rdi, r13
    lea rsi, [rip + .Lk_question]
    call jstr
    test rax, rax
    jnz 3f
    lea rax, [rip + .Lempty]
3:  mov rdi, rbx
    mov rsi, r12
    mov rcx, rdx
    mov rdx, rax
    lea r8, [rsp]
    mov r9, r15
    call ev_request
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# cl_answer(AL*, AQ*, n) -> eax 1: option n of the card of AL_reqs' oldest request. A permission: Yes
#   allows with the input unchanged, No denies with the extension's words and interrupts. A plan: Yes
#   asks for the default mode first (plan mode stays on otherwise), then allows; No keeps planning. A
#   question: the pick is kept and the next question's card shows; after the last one the answers go.
#   Then the next request's card shows
cl_answer:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor eax, eax
    cmp qword ptr [rbx + AL_reqs + VEC_len], 0
    je 9f
    mov rcx, [rbx + AL_reqs + VEC_ptr]
    cmp [rcx], r12
    jne 9f
    mov eax, [r12 + AQ_kind]
    cmp eax, AQK_QUESTION
    je .Lca_question
    cmp eax, AQK_PLAN
    je .Lca_plan
    test r13, r13
    jnz 2f
1:  mov rdi, rbx
    mov rsi, r12
    call reply_allow
    jmp 8f
2:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lr_rejected]
    mov ecx, 1
    call reply_deny
    jmp 8f
.Lca_plan:
    test r13, r13
    jnz 3f
    mov rdi, rbx
    call set_mode_default
    jmp 1b
3:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lr_keep_planning]
    xor ecx, ecx
    call reply_deny
    jmp 8f
.Lca_question:
    lea rdi, [r12 + AQ_picks]
    mov esi, r13d
    call sb_push_byte
    inc qword ptr [r12 + AQ_n]
    mov rax, [r12 + AQ_n]
    cmp rax, [r12 + AQ_count]
    jae 4f
    mov rdi, rbx                # the next question
    call req_show
    mov eax, 1
    EPILOGUE
4:  mov rdi, rbx
    mov rsi, r12
    call reply_answers
8:  mov rdi, rbx
    mov rsi, r12
    call ev_request_gone
    mov rdi, rbx
    call req_show
    mov eax, 1
9:  EPILOGUE

# set_mode_default(AL*): {"type":"control_request","request_id":"rN","request":{"subtype":
#   "set_permission_mode","mode":"default"}} (its answer is not waited for: system/status reports the mode)
set_mode_default:
    PROLOGUE
    mov rbx, rdi
    mov esi, OA_MODE
    call req_begin
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_subtype]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_set_mode]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_mode]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_default]
    call jw_cstr
    mov rdi, rbx
    call req_end
    EPILOGUE

# reply_begin(AL*, AQ*): {"type":"control_response","response":{"subtype":"success","request_id":ID,
#   "response":{  (the answer's members follow; reply_end closes it)
reply_begin:
    PROLOGUE
    mov r12, rsi
    lea rdi, [rip + cw]
    call jw_begin
    lea rdi, [rip + cw]
    call jw_obj
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_type]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_control_response]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_response]
    call jw_key
    lea rdi, [rip + cw]
    call jw_obj
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_subtype]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_success]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_request_id]
    call jw_key
    mov rdi, [r12 + AQ_id]
    call strlen
    lea rdi, [rip + cw]
    mov rsi, [r12 + AQ_id]
    mov rdx, rax
    call jw_rawn
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_response]
    call jw_key
    lea rdi, [rip + cw]
    call jw_obj
    EPILOGUE

# reply_end(AL*, AQ*) -> eax 1 written: "toolUseID" (every answer carries it), the three objects closed,
#   the line sent
reply_end:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rsi, [r12 + AQ_tuid]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_toolUseID]
    call jw_key
    lea rdi, [rip + cw]
    mov rsi, [r12 + AQ_tuid]
    call jw_cstr
1:  lea rdi, [rip + cw]
    call jw_end_obj
    lea rdi, [rip + cw]
    call jw_end_obj
    lea rdi, [rip + cw]
    call jw_end_obj
    mov rdi, rbx
    call cl_write
    EPILOGUE

# reply_allow(AL*, AQ*): {"behavior":"allow","updatedInput":INPUT,"toolUseID":ID}, the input unchanged
reply_allow:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call reply_begin
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_behavior]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_allow]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_updatedInput]
    call jw_key
    lea rdi, [rip + cw]
    mov rsi, [r12 + AQ_input]
    mov rdx, [r12 + AQ_inlen]
    call jw_rawn
    mov rdi, rbx
    mov rsi, r12
    call reply_end
    EPILOGUE

# reply_deny(AL*, AQ*, message cstr, interrupt): {"behavior":"deny","message":M,"interrupt":B,
#   "toolUseID":ID}
reply_deny:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    call reply_begin
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_behavior]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_deny]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_message]
    call jw_key
    lea rdi, [rip + cw]
    mov rsi, r13
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_interrupt]
    call jw_key
    lea rdi, [rip + cw]
    mov esi, r14d
    call jw_bool
    mov rdi, rbx
    mov rsi, r12
    call reply_end
    EPILOGUE

# reply_answers(AL*, AQ*): an AskUserQuestion's allow: updatedInput is its input (the questions as sent,
#   its other members kept) with "answers" {question text: the label picked, ...}. Locals: [rsp] a key's
#   text, [rsp + 8] its length
reply_answers:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [r12 + AQ_input]
    mov rsi, [r12 + AQ_inlen]
    mov edx, LINE_VALUES
    mov ecx, LINE_DEPTH
    call json_parse_lim
    mov r13, rax
    test rax, rax
    jnz 1f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lr_noecho]
    xor ecx, ecx
    call reply_deny
    EPILOGUE
1:  mov rdi, rbx
    mov rsi, r12
    call reply_begin
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_behavior]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_allow]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_updatedInput]
    call jw_key
    lea rdi, [rip + cw]
    call jw_obj
    xor r14d, r14d
2:  mov rdi, r13                # the input's members but its answers
    call json_npairs
    cmp r14d, eax
    jae 3f
    mov rdi, r13
    mov esi, r14d
    call json_pair
    inc r14d
    mov r15, rdx
    mov rdi, rax
    call json_str
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lk_answers]
    call str_eq_cstr
    test eax, eax
    jnz 2b
    lea rdi, [rip + cw]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call jw_keyn
    lea rdi, [rip + cw]
    mov rsi, r15
    call jw_jv
    jmp 2b
3:  lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_answers]
    call jw_key
    lea rdi, [rip + cw]
    call jw_obj
    mov rdi, r13
    lea rsi, [rip + .Lk_questions]
    call json_get
    mov r13, rax
    xor r14d, r14d
4:  cmp r14, [r12 + AQ_picks + SB_len]
    jae 5f
    mov rdi, r13
    mov esi, r14d
    call json_at
    mov r15, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_question]
    call jstr
    lea rdi, [rip + cw]
    mov rsi, rax
    call jw_keyn
    mov rdi, r15
    lea rsi, [rip + .Lk_options]
    call json_get
    mov rdi, rax
    mov rcx, [r12 + AQ_picks + SB_ptr]
    movzx esi, byte ptr [rcx + r14]
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_label]
    call jstr
    lea rdi, [rip + cw]
    mov rsi, rax
    call jw_str
    inc r14
    jmp 4b
5:  lea rdi, [rip + cw]
    call jw_end_obj             # the answers
    lea rdi, [rip + cw]
    call jw_end_obj             # updatedInput
    mov rdi, rbx
    mov rsi, r12
    call reply_end
    EPILOGUE

# h_cancel(AL*, record): control_cancel_request: Claude does not wait for that request any more: its
#   card goes (the next one's shows), no answer is sent, an info row says so
h_cancel:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + tsb]
    call jw_begin
    mov rdi, r12
    lea rsi, [rip + .Lk_request_id]
    call json_get
    lea rdi, [rip + tsb]
    mov rsi, rax
    call jw_jv
    xor r13d, r13d
1:  cmp r13, [rbx + AL_reqs + VEC_len]
    jae 9f
    mov rax, [rbx + AL_reqs + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    mov rdi, [r14 + AQ_id]
    call strlen
    cmp rax, [rip + tsb + SB_len]
    jne 1b
    mov rdi, [r14 + AQ_id]
    mov rsi, [rip + tsb + SB_ptr]
    mov rdx, rax
    call memeq
    test eax, eax
    jz 1b
    mov rdi, rbx
    mov rsi, r14
    call ev_request_gone
    test dword ptr [rbx + AL_flags], ALF_STOP_ASKED
    jnz 2f                      # the user's Stop withdrew it: the turn's end says "Interrupted"
    lea rdi, [rip + .Lwithdrawn]
    call strlen
    mov rdi, rbx
    mov esi, R_INFO
    lea rdx, [rip + .Lwithdrawn]
    mov rcx, rax
    call ev_note
2:  cmp r13, 1
    jne 9f
    mov rdi, rbx                # it was the one shown
    call req_show
9:  EPILOGUE

# h_response(AL*, record): the answer to one of rhun's requests ("rN"); initialize's ends the handshake
#   (set_permission_mode's is not used: system/status reports the mode)
h_response:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_response]
    call json_get
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_request_id]
    call jstr
    cmp rdx, 2
    jb 9f
    cmp byte ptr [rax], 'r'
    jne 9f
    lea rdi, [rax + 1]
    lea rsi, [rdx - 1]
    call parse_u64
    mov rdi, rbx
    mov rsi, rax
    call out_take
    cmp eax, OA_INIT
    jne 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_success]
    call json_is
    test eax, eax
    jz 5f
    mov rdi, r12                # the mode it starts in, then the prompts that waited go
    lea rsi, [rip + .Lk_response]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_current_mode]
    call jstr
    test rdx, rdx
    jz 1f
    mov rdi, rbx
    mov rsi, rax
    call ev_mode
1:  mov rdi, rbx
    call ev_ready
9:  EPILOGUE
5:  mov rdi, r12                # refused: the start failed with its words, the process goes
    lea rsi, [rip + .Lk_error]
    call jstr
    mov r13, rax
    mov r14, rdx
    test rdx, rdx
    jnz 6f
    lea r13, [rip + .Lr_refused]
    mov rdi, r13
    call strlen
    mov r14, rax
6:  mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call ev_failed
    lea rdi, [rbx + AL_cn]
    call conn_stop
    EPILOGUE

# cl_close(CN*, err): the process is gone (or the connection broke). While it started or a turn ran
#   that is a failure: the reason and the end of its stderr as an error row; then ev_closed. An end rhun
#   asked for (ALF_ENDING: a release, the idle stop, the cap) is none, whatever the exit status
cl_close:
    PROLOGUE
    mov rbx, [rdi + CN_ctx]
    mov r12d, esi
    test dword ptr [rbx + AL_flags], ALF_ENDING
    jnz 8f
    mov eax, [rbx + AL_state]
    cmp eax, ALS_STARTING
    je 1f
    cmp eax, ALS_WORKING
    je 1f
    cmp eax, ALS_WAITING
    jne 8f
1:  lea rdi, [rbx + AL_report]
    call sb_clear
    lea rsi, [rip + .Lr_broke]
    cmp r12d, CN_E_LINE
    jne 2f
    lea rsi, [rip + .Lr_line]
2:  cmp r12d, CN_E_STALL
    jne 3f
    lea rsi, [rip + .Lr_stall]
3:  cmp r12d, CN_E_EXIT
    jne 4f
    lea rsi, [rip + .Lr_ended]
    cmp dword ptr [rbx + AL_state], ALS_STARTING
    jne 4f
    lea rsi, [rip + .Lr_ended_early]
4:  lea rdi, [rbx + AL_report]
    call sb_push_cstr
    cmp r12d, CN_E_EXIT
    jne 5f
    mov eax, [rbx + AL_cn + CN_exit]
    test eax, eax
    js 5f
    lea rdi, [rbx + AL_report]
    lea rsi, [rip + .Lr_status]
    call sb_push_cstr
    lea rdi, [rbx + AL_report]
    mov esi, [rbx + AL_cn + CN_exit]
    call sb_push_u64
    lea rdi, [rbx + AL_report]
    mov esi, ')'
    call sb_push_byte
5:  mov rdi, rbx
    call err_tail
    mov rdi, rbx
    mov rsi, [rbx + AL_report + SB_ptr]
    mov rdx, [rbx + AL_report + SB_len]
    call ev_failed
8:  mov rdi, rbx
    mov esi, r12d
    call ev_closed
    EPILOGUE

# err_tail(AL*): AL_report ends with ":\n" and the last lines of claude's stderr (at most ERR_TAIL bytes,
#   from a line's start when cut, controls as spaces), or with "." when it wrote nothing
err_tail:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AL_cn + CN_ebuf + SB_ptr]
    mov r13, [rbx + AL_cn + CN_ebuf + SB_len]
    cmp r13, ERR_TAIL
    jbe 3f
    lea r12, [r12 + r13 - ERR_TAIL]
    mov r13d, ERR_TAIL
    xor ecx, ecx                # from the first line that starts in the window, when one does
1:  cmp rcx, r13
    jae 2f
    cmp byte ptr [r12 + rcx], 10
    je 11f
    inc rcx
    jmp 1b
11: inc rcx
    add r12, rcx
    sub r13, rcx
    jmp 3f
2:  test r13, r13               # else from a character's start
    jz 3f
    movzx eax, byte ptr [r12]
    and eax, 0xc0
    cmp eax, 0x80
    jne 3f
    inc r12
    dec r13
    jmp 2b
3:  test r12, r12
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call trim
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 8f
    lea rdi, [rbx + AL_report]
    lea rsi, [rip + .Lr_colon]
    call sb_push_cstr
    xor r14d, r14d
4:  cmp r14, r13
    jae 9f
    movzx esi, byte ptr [r12 + r14]
    inc r14
    cmp esi, 10
    je 5f
    cmp esi, 32
    jae 5f
    mov esi, ' '
5:  lea rdi, [rbx + AL_report]
    call sb_push_byte
    jmp 4b
8:  lea rdi, [rbx + AL_report]
    mov esi, '.'
    call sb_push_byte
9:  EPILOGUE

.section .rodata
.p2align 3
.globl claude_drv
claude_drv:
    .long AG_CLAUDE, DRVC_NEW | DRVC_RESUME
    .quad .Lname, cl_start, cl_send, cl_stop, cl_answer, cl_release, cl_held
cl_types:
    .quad .Lv_stream_event, h_stream, .Lv_assistant, h_assistant, .Lv_system, h_system
    .quad .Lv_result, h_result, .Lv_control_request, h_request, .Lv_control_response, h_response
    .quad .Lv_user, h_user, .Lv_cancel, h_cancel
    .quad 0, 0
perm_qs:                        # a permission card's question: the tool, before its summary, after it
    .quad .Lt_bash, .Lq_bash, .Lempty, .Lt_edit, .Lq_edit, .Lq_mark, .Lt_multiedit, .Lq_edit, .Lq_mark
    .quad .Lt_write, .Lq_write, .Lq_mark, .Lt_read, .Lq_read, .Lq_mark, .Lt_webfetch, .Lq_fetch, .Lempty
    .quad 0
opts_yes_no: .quad .Lo_yes, .Lo_no
opts_plan: .quad .Lo_yes, .Lo_keep
cl_flags:
    .quad .La_outf, .La_sj, .La_verbose, .La_inf, .La_sj, .La_partial, .La_ppt, 0
.Lname: .asciz "Claude Code"
.La_outf: .asciz "--output-format"
.La_inf: .asciz "--input-format"
.La_sj: .asciz "stream-json"
.La_verbose: .asciz "--verbose"
.La_partial: .asciz "--include-partial-messages"
.La_ppt: .asciz "--permission-prompt-tool=stdio"
.La_sources_all: .asciz "--setting-sources=user,project,local"
.La_sources_user: .asciz "--setting-sources=user"
.La_thinking: .asciz "--max-thinking-tokens=31999"
.La_sid: .asciz "--session-id="
.La_resume: .asciz "--resume="
.La_mode: .asciz "--permission-mode="
.Lk_type: .asciz "type"
.Lk_subtype: .asciz "subtype"
.Lk_request_id: .asciz "request_id"
.Lk_request: .asciz "request"
.Lk_response: .asciz "response"
.Lk_hooks: .asciz "hooks"
.Lk_message: .asciz "message"
.Lk_model: .asciz "model"
.Lk_role: .asciz "role"
.Lk_content: .asciz "content"
.Lk_parent: .asciz "parent_tool_use_id"
.Lk_session_id: .asciz "session_id"
.Lk_event: .asciz "event"
.Lk_id: .asciz "id"
.Lk_index: .asciz "index"
.Lk_content_block: .asciz "content_block"
.Lk_delta: .asciz "delta"
.Lk_cwd: .asciz "cwd"
.Lk_permissionMode: .asciz "permissionMode"
.Lk_current_mode: .asciz "current_permission_mode"
.Lk_errors: .asciz "errors"
.Lk_result: .asciz "result"
.Lk_is_error: .asciz "is_error"
.Lk_terminal: .asciz "terminal_reason"
.Lk_error: .asciz "error"
.Lv_control_request: .asciz "control_request"
.Lv_control_response: .asciz "control_response"
.Lv_stream_event: .asciz "stream_event"
.Lv_assistant: .asciz "assistant"
.Lv_system: .asciz "system"
.Lv_result: .asciz "result"
.Lv_initialize: .asciz "initialize"
.Lv_user: .asciz "user"
.Lv_text: .asciz "text"
.Lv_message_start: .asciz "message_start"
.Lv_block_start: .asciz "content_block_start"
.Lv_block_delta: .asciz "content_block_delta"
.Lv_text_delta: .asciz "text_delta"
.Lv_init: .asciz "init"
.Lv_status: .asciz "status"
.Lv_success: .asciz "success"
.Lv_error: .asciz "error"
.Lv_aborted: .asciz "aborted"
.Lv_unsupported: .asciz "not supported by rhun yet"
.Lv_interrupt: .asciz "interrupt"
.Lv_cancel: .asciz "control_cancel_request"
.Lv_can_use_tool: .asciz "can_use_tool"
.Lv_tool_use: .asciz "tool_use"
.Lv_tool_result: .asciz "tool_result"
.Lv_set_mode: .asciz "set_permission_mode"
.Lv_default: .asciz "default"
.Lv_allow: .asciz "allow"
.Lv_deny: .asciz "deny"
.Lk_input: .asciz "input"
.Lk_name: .asciz "name"
.Lk_isReplay: .asciz "isReplay"
.Lk_isMeta: .asciz "isMeta"
.Lk_tool_name: .asciz "tool_name"
.Lk_tool_use_id: .asciz "tool_use_id"
.Lk_questions: .asciz "questions"
.Lk_question: .asciz "question"
.Lk_options: .asciz "options"
.Lk_label: .asciz "label"
.Lk_answers: .asciz "answers"
.Lk_plan: .asciz "plan"
.Lk_mode: .asciz "mode"
.Lk_behavior: .asciz "behavior"
.Lk_updatedInput: .asciz "updatedInput"
.Lk_interrupt: .asciz "interrupt"
.Lk_toolUseID: .asciz "toolUseID"
.Lt_ask: .asciz "AskUserQuestion"
.Lt_plan: .asciz "ExitPlanMode"
.Lt_bash: .asciz "Bash"
.Lt_edit: .asciz "Edit"
.Lt_multiedit: .asciz "MultiEdit"
.Lt_write: .asciz "Write"
.Lt_read: .asciz "Read"
.Lt_webfetch: .asciz "WebFetch"
.Lq_bash: .asciz "Allow this bash command? "
.Lq_edit: .asciz "Make this edit to "
.Lq_write: .asciz "Allow write to "
.Lq_read: .asciz "Allow reading from "
.Lq_fetch: .asciz "Allow fetching this url? "
.Lq_proceed: .asciz "Do you want to proceed with "
.Lq_mark: .asciz "?"
.Lq_plan: .asciz "Accept this plan?"
.Lo_yes: .asciz "Yes"
.Lo_no: .asciz "No"
.Lo_keep: .asciz "No, keep planning"
.Lr_rejected: .ascii "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a "
    .ascii "file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the "
    .asciz "user to tell you how to proceed."
.Lr_keep_planning: .asciz "User chose to stay in plan mode and continue planning"
.Lr_noecho: .asciz "rhun cannot pass this input back unchanged"
.Lr_noshow: .asciz "rhun cannot show this request"
.Lr_toomany: .asciz "too many requests are waiting in rhun"
.Lwithdrawn: .asciz "Withdrawn by Claude"
.Lprojects: .asciz "/projects"
.Ljsonl: .asciz ".jsonl"
.Lempty: .asciz ""
.Lr_missing: .asciz "Claude Code was not found. Install it, or set its path in Settings > Claude Code."
.Lr_spawn: .asciz "Claude Code could not be started."
.Lr_busy: .asciz "Too many agents are running. Stop one and send again."
.Lr_badid: .asciz "rhun cannot continue this conversation: its file is not named after a Claude Code id."
.Lr_refused: .asciz "Claude Code refused to start the conversation."
.Lr_early: .asciz "Claude Code ended before it was ready."
.Lr_ended: .asciz "Claude Code ended"
.Lr_ended_early: .asciz "Claude Code ended before it was ready"
.Lr_status: .asciz " (exit status "
.Lr_line: .asciz "Claude Code sent a line longer than 64 MiB"
.Lr_stall: .asciz "Claude Code stopped reading what rhun sent"
.Lr_broke: .asciz "The connection to Claude Code broke"
.Lr_colon: .asciz ":\n"
