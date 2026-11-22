# AI (wider-parity D): agent sources, edit proposals, tools and interactive sessions. Included in
# extproto.s for its parsed fields and reply builders; the features live in agentext.s, review.s and
# tools.s.
.text

# ai_agreed(feature index) -> eax 1 when cur agreed the feature, else 0 after replying unknown
ai_agreed:
    mov esi, edi
    mov rdi, [rip + cur]
    call ext_feature
    test eax, eax
    jz 1f
    ret
1:  mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_unknown]
    call reply_error
    xor eax, eax
    ret

# ai_answer(rax 0 or "CODE TEXT"): ok, or the error
ai_answer:
    test rax, rax
    jnz 1f
    mov rdi, [rip + cur_id]
    jmp reply_ok
1:  mov rdi, [rip + cur_id]
    mov rsi, rax
    jmp reply_error

# ID agent-sessions LEN + rows (feature agents)
h_agent_sessions:
    PROLOGUE
    mov edi, FEAT_AGENTS
    call ai_agreed
    test eax, eax
    jz 9f
    mov rdi, [rip + cur]
    mov rsi, [rip + body_ptr]
    mov rdx, [rip + body_len]
    call agentext_set_rows
    call ai_answer
9:  EPILOGUE

# ID agent-changed SID TOTAL FIRST (feature agents)
h_agent_changed:
    PROLOGUE 16
    mov edi, FEAT_AGENTS
    call ai_agreed
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 5
    jne 8f
    mov edi, 3
    call field_u64
    test edx, edx
    jz 8f
    mov [rsp], rax
    mov edi, 4
    call field_u64
    test edx, edx
    jz 8f
    mov [rsp + 8], rax
    mov edi, 2
    call field_at
    mov rdi, [rip + cur]
    mov rsi, rax
    mov rcx, [rsp]
    mov r8, [rsp + 8]
    call agentext_changed
    call ai_answer
    jmp 9f
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# ID propose LEN + LABEL_LEN SID_LEN LF, the label and session id, and a workspace edit (feature
# edit-review): checked at once, answered ok ID PROPOSAL; the user decides in the Review tab
h_propose:
    PROLOGUE
    mov edi, FEAT_EDIT_REVIEW
    call ai_agreed
    test eax, eax
    jz 9f
    mov edi, NEEDS_DOC_READ
    call need
    test eax, eax
    jz 9f
    mov rdi, [rip + cur]
    mov rsi, [rip + body_ptr]
    mov rdx, [rip + body_len]
    mov ecx, 1
    call review_propose
    test rax, rax
    jnz 1f
    mov rdi, [rip + cur_id]
    mov rsi, rdx
    call reply_ok_u64
    jmp 9f
1:  mov rdi, [rip + cur_id]
    mov rsi, rax
    call reply_error
9:  EPILOGUE

# ID unpropose PROPOSAL (feature edit-review)
h_unpropose:
    PROLOGUE
    mov edi, FEAT_EDIT_REVIEW
    call ai_agreed
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 3
    jne 8f
    mov edi, 2
    call field_u64
    test edx, edx
    jz 8f
    mov rdi, [rip + cur]
    mov rsi, rax
    call review_unpropose
    call ai_answer
    jmp 9f
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# FN extproto_ai_request(ext, line, len, body, body_len) -> rax the id of "ID LINE" sent with the body
#   (a request from rhun, section 12), or 0 when the extension is not running
FN extproto_ai_request
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8
    mov rax, [rip + cur]
    mov [rsp + 8], rax          # a reply to the extension being served may still be built
    xor r15d, r15d
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 8f
    cmp qword ptr [rbx + EXT_hreq], 2147483647
    jae 8f                      # exhausted ids are never reused
    mov [rip + cur], rbx
    inc qword ptr [rbx + EXT_hreq]
    mov r15, [rbx + EXT_hreq]
    call out_begin
    mov rdi, r15
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r12
    mov rsi, r13
    call out_bytes
    mov edi, 10
    call out_byte
    test r14, r14
    jz 1f
    mov rdi, r14
    mov rsi, [rsp]
    call out_bytes
1:  call out_end
    test rax, rax
    jns 8f
    xor r15d, r15d
8:  mov rax, [rsp + 8]
    mov [rip + cur], rax
    mov rax, r15
    EPILOGUE

# FN extproto_ai_event(ext, line, len, body, body_len): "0 LINE" and the body, when it runs
FN extproto_ai_event
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8
    mov rax, [rip + cur]
    mov [rsp + 8], rax
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 8f
    mov [rip + cur], rbx
    call out_begin
    mov edi, '0'
    call out_byte
    mov edi, ' '
    call out_byte
    mov rdi, r12
    mov rsi, r13
    call out_bytes
    mov edi, 10
    call out_byte
    test r14, r14
    jz 1f
    mov rdi, r14
    mov rsi, [rsp]
    call out_bytes
1:  call out_end
8:  mov rax, [rsp + 8]
    mov [rip + cur], rax
    EPILOGUE

# FN extproto_ai_answer(ext, id, line, len, body, body_len): "ok ID LINE" and the body, or with
#   line 0 "error ID" and the body as CODE TEXT: a late answer to one of its requests (a prompt, a
#   tool call, a card)
FN extproto_ai_answer
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8
    mov [rsp + 16], r9
    mov rax, [rip + cur]
    mov [rsp + 8], rax
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 8f
    mov [rip + cur], rbx
    call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    test r13, r13
    jnz 1f
    lea rdi, [rip + .Lw_error_sp]
1:  call out_cstr
    mov rdi, r12
    call out_u64
    test r13, r13
    jz 3f
    test r14, r14
    jz 2f
    mov edi, ' '
    call out_byte
    mov rdi, r13
    mov rsi, r14
    call out_bytes
2:  mov edi, 10
    call out_byte
    mov rdi, [rsp]
    test rdi, rdi
    jz 4f
    mov rsi, [rsp + 16]
    call out_bytes
    jmp 4f
3:  mov edi, ' '                # an error: the body is its code and text, on the line
    call out_byte
    mov rdi, [rsp]
    mov rsi, [rsp + 16]
    call out_bytes
    mov edi, 10
    call out_byte
4:  call out_end
8:  mov rax, [rsp + 8]
    mov [rip + cur], rax
    EPILOGUE

# ai_reply(ext, id, ok, body, len) -> eax 1 when the reply answered one of the AI requests rhun sent
ai_reply:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], edx
    mov [rsp + 16], rcx
    mov [rsp + 24], r8
    FEAT_TEST rbx, FEAT_AGENTS
    jz 1f
    call agentext_reply
    test eax, eax
    jnz 9f
1:  FEAT_TEST rbx, FEAT_TOOLS
    jz 2f
    mov rdi, rbx
    mov rsi, [rsp]
    mov edx, [rsp + 8]
    mov rcx, [rsp + 16]
    mov r8, [rsp + 24]
    call tools_reply
    test eax, eax
    jnz 9f
2:  FEAT_TEST rbx, FEAT_AGENT_PROMPTS
    jz 8f
    mov rdi, rbx
    mov rsi, [rsp]
    mov edx, [rsp + 8]
    mov rcx, [rsp + 16]
    mov r8, [rsp + 24]
    call agentext_prompt_reply
    test eax, eax
    jnz 9f
8:  xor eax, eax
9:  EPILOGUE

# FN ai_query_expired(ext, id, 0, 0, 0): query.s gave up waiting for one of the AI requests: its
#   asker hears it as an error answer
FN ai_query_expired
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + .Le_no_answer]
    call strlen
    mov r8, rax
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    lea rcx, [rip + .Le_no_answer]
    call ai_reply
    EPILOGUE

# ID tools (feature tools) -> ok ID LEN + every tool rhun offers (tools.s)
h_tools:
    PROLOGUE
    mov edi, FEAT_TOOLS
    call ai_agreed
    test eax, eax
    jz 9f
    lea rdi, [rip + ai_body]
    call sb_clear
    lea rdi, [rip + ai_body]
    call tools_list
    call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    mov rdi, [rip + cur_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, [rip + ai_body + SB_len]
    call out_u64
    mov edi, 10
    call out_byte
    mov rdi, [rip + ai_body + SB_ptr]
    mov rsi, [rip + ai_body + SB_len]
    call out_bytes
    call out_end
9:  EPILOGUE

# ID tool-call TOOL LEN + input (feature tools): answered when the tool is done (tools.s)
h_tool_call:
    PROLOGUE
    mov edi, FEAT_TOOLS
    call ai_agreed
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 4
    jne 8f
    mov edi, 2
    call field_at
    mov rdi, [rip + cur]
    mov rsi, [rip + cur_id]
    mov rcx, rdx
    mov rdx, rax
    mov r8, [rip + body_ptr]
    mov r9, [rip + body_len]
    call tools_call
    jmp 9f
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# ID agent-ask SID LEN + a prompt line and option lines (feature agent-prompts): a card in that
# session's conversation, answered ok ID N (from 1) when the user picks, or error cancelled
h_agent_ask:
    PROLOGUE
    mov edi, FEAT_AGENT_PROMPTS
    call ai_agreed
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 4
    jne 8f
    mov edi, 2
    call field_at
    mov rcx, rdx
    mov rdx, rax
    mov rdi, [rip + cur]
    mov rsi, [rip + cur_id]
    mov r8, [rip + body_ptr]
    mov r9, [rip + body_len]
    call agentext_ask
    test rax, rax
    jz 9f                       # answered when the user picks
    mov rdi, [rip + cur_id]
    mov rsi, rax
    call reply_error
    jmp 9f
8:  mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# FN extproto_tool_term(caller, id, ptr, len, call) -> rax 0 with the command in rhun's prompt as a
#   term request of the caller's would put it (rhun.run), or the error reply
FN extproto_tool_term
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    mov r12, rdx
    mov r13, rcx
    mov [rsp + 8], r8
    lea rax, [rip + .Le_syntax]
    test r13, r13
    jz 9f
    lea rax, [rip + .Le_toobig_term]
    cmp r13, EXT_TERM_MAX
    ja 9f
    mov rdi, r12
    mov rsi, r13
    call plain_text             # what is shown is what runs
    mov ecx, eax
    lea rax, [rip + .Le_syntax]
    test ecx, ecx
    jz 9f
    lea rax, [rip + .Le_busy]
    cmp qword ptr [rip + pr_id], 0
    jne 9f
    call palette_is_open
    mov ecx, eax
    lea rax, [rip + .Le_busy]
    test ecx, ecx
    jnz 9f
    lea rdi, [rip + .Lrun_label]
    mov esi, PROMPT_TERM
    mov rdx, r12
    mov rcx, r13
    call palette_ext_prompt_open
    call palette_field
    mov qword ptr [rax + TF_cur], 0
    mov qword ptr [rax + TF_anchor], 0
    mov qword ptr [rip + pr_kind], 3
    mov [rip + pr_ext], rbx
    mov rax, [rsp]
    mov [rip + pr_id], rax
    mov rax, [rsp + 8]
    mov [rip + pr_tool], rax
    call time_ms
    mov [rip + pr_opened], rax
    xor eax, eax
9:  EPILOGUE

# FN extproto_own_term(ptr, len) -> eax 1: a command of rhun's own in its terminal prompt (it runs when
#   the user presses Enter; nobody is answered), 0 when a prompt or the palette is open already. The
#   text must be one plain line
FN extproto_own_term
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor eax, eax
    test r13, r13
    jz 9f
    cmp r13, EXT_TERM_MAX
    ja 9f
    mov rdi, r12
    mov rsi, r13
    call plain_text             # what is shown is what runs
    test eax, eax
    jz 9f
    xor eax, eax
    cmp qword ptr [rip + pr_id], 0
    jne 9f
    call palette_is_open
    test eax, eax
    mov eax, 0
    jnz 9f
    lea rdi, [rip + .Lrun_label]
    mov esi, PROMPT_TERM
    mov rdx, r12
    mov rcx, r13
    call palette_ext_prompt_open
    call palette_field
    mov qword ptr [rax + TF_cur], 0
    mov qword ptr [rax + TF_anchor], 0
    mov qword ptr [rip + pr_kind], 3
    mov qword ptr [rip + pr_ext], 0     # rhun's own: no extension waits for the answer
    mov qword ptr [rip + pr_id], -1
    mov qword ptr [rip + pr_tool], 0
    call time_ms
    mov [rip + pr_opened], rax
    mov eax, 1
9:  EPILOGUE

# prompt_term_answer(ran): a term prompt closed: ok, or cancelled; for rhun.run the tool call is
#   answered instead (tools.s); rhun's own (extproto_own_term) answers nobody
prompt_term_answer:
    mov rax, [rip + pr_tool]
    test rax, rax
    jnz 1f
    cmp qword ptr [rip + pr_ext], 0
    je 3f
    test edi, edi
    jz 2f
    mov rdi, [rip + pr_id]
    jmp reply_ok
2:  mov rdi, [rip + pr_id]
    lea rsi, [rip + .Le_cancelled]
    jmp reply_error
1:  mov esi, edi
    mov rdi, rax
    mov qword ptr [rip + pr_tool], 0
    jmp tools_term_done
3:  ret

.bss
.p2align 3
ai_body: .zero SB_SIZE
pr_tool: .quad 0                # the rhun.run call the open term prompt answers, or 0
.text

.section .rodata
.Lv_agent_sessions: .asciz "agent-sessions"
.Lv_agent_changed: .asciz "agent-changed"
.Lv_propose: .asciz "propose"
.Lv_unpropose: .asciz "unpropose"
.Lv_tools: .asciz "tools"
.Le_no_answer: .asciz "busy the extension did not answer in time"
.Lv_tool_call: .asciz "tool-call"
.Lv_agent_ask: .asciz "agent-ask"
.text
