# the Claude Code driver (agent_drv.s's table for AS_kind AG_CLAUDE): it runs the user's installed claude
# on stream-json pipes (agent_conn.s) and turns its records into agent_drv.s's events. The command line,
# the environment and the shapes are pinned in tests/data/claude-shapes/README.txt (Claude Code 2.1.330):
#
#   [WRAPPER] CLAUDE --output-format stream-json --verbose --input-format stream-json
#     --include-partial-messages --permission-prompt-tool=stdio --replay-user-messages
#     --setting-sources=user,project,local | --setting-sources=user     (the project trusted or not)
#     --max-thinking-tokens=31999 | --thinking=disabled                 (the project's thinking level)
#     [--model=VALUE] [--effort=LEVEL]                                  (the project's choices)
#     [--permission-mode=MODE]                                          (claude_start_mode)
#     [--allow-dangerously-skip-permissions]                            ([claude] allow_bypass_permissions)
#     --session-id=UUID | --resume=ID | --resume=SRC --fork-session --session-id=UUID
#
# Every user message carries the uuid agent_send made: its command_lifecycle and its replay (finding 17)
# say when a message written during a turn starts (ev_started) or will not run (ev_dropped).
#
# A new conversation gets our UUID (agent_new); an existing one is continued with --resume and the id
# its transcript is named after; a copy (Continue in a copy, ALF_FORK) is forked from its source with our
# UUID. Before a --resume, cl_held says whether another program has the conversation open.
#
# The sign-in state (cl_auth) is `[WRAPPER] CLAUDE auth status --json`, run once a window in the background
# with claude's environment: a pipe read by a watch of its own (not a connection: it does not count against
# the cap), 64 KiB at most, 10 s at most. Only its loggedIn is read; no credential is read anywhere. A turn
# that fails with an authentication error shows the sign-in notice too. cl_terminal puts claude (or its
# sign-in) in rhun's terminal prompt, as the rhun.run tool does.
#
# The first line it is sent is initialize; nothing else goes until its answer (the prompts wait in
# AL_queue, agent_drv.s). Its answer's lists go to the project's record (claude_session.s), then
# get_settings asks what is in effect, then the prompts go. The user's model, effort and Ultracode picks are
# asked of a running program with apply_flag_settings (cl_apply), thinking with set_max_thinking_tokens
# (cl_thinking); update_settings is never sent (Claude Code's own settings are the user's alone).
# A turn streams: message_start names the message, a text block's start is a
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
.equ OA_MODE, 2                 # set_permission_mode rhun asks for itself (before allowing ExitPlanMode)
.equ OA_STOP, 3                 # interrupt (its answer is not needed: the turn's result follows)
.equ OA_SETTINGS, 4             # get_settings (claude_settings_answer)
.equ OA_PICK, 5                 # set_permission_mode the user asked for (claude_mode_answer)
.equ OA_FLAGS, 6                # apply_flag_settings / set_max_thinking_tokens (claude_flags_answer): + its
.equ OA_FLAGS_END, 9            #   kind (claude_session.s's CLF_*: model, effort, ultracode, thinking)
.equ OA_PLAN_MODE, 10           # plan review: set_permission_mode auto before a plan's Yes (claude_plan_mode_answer)
.equ OA_GET_PLAN, 11            # plan review: get_plan for /plan (claude_plan_answer)
.equ QUESTION_OPTS, 16          # a question's card shows its first 16 options
.equ AUTH_MS, 10000             # the sign-in question's answer is waited for this long
.equ AUTH_MAX, 65536            # bytes of its answer kept
.equ AU_UNKNOWN, 0              # a profile's answer: not asked (or to be asked again)
.equ AU_ASKING, 1               # au_state: a question runs (for au_key)
.equ AU_IN, 2
.equ AU_OUT, 3
.ifdef WINDOWS
.equ SH_PS, 1
.else
.equ SH_PS, 0
.endif
.equ AU_SLOTS, 16               # profiles whose answer is kept (the oldest goes after that)

.bss
.p2align 3
.globl claude_cw
claude_cw:                      # (claude_cards.s writes its answers here too)
cw: .zero SB_SIZE               # the message being written
ksb: .zero SB_SIZE              # an item key, a request id
asb: .zero SB_SIZE              # the arguments built for argv
psb: .zero SB_SIZE              # a transcript path
dsb: .zero SB_SIZE              # the projects folder (find_file)
tsb: .zero SB_SIZE              # a request's id or input as JSON text
found_al: .quad 0               # find_file's session
au_buf: .zero SB_SIZE           # the sign-in question's answer
au_until: .quad 0               # time_ms its answer is given up on
au_state: .long 0               # AU_ASKING while a question runs, else AU_UNKNOWN
au_pid: .long 0                 # the question's process while it runs
.p2align 3
au_key: .quad 0                 # owned cstr: the profile (Claude folder) the running question is for
au_keys: .zero 8 * AU_SLOTS     # owned cstrs: the profiles answered this window
au_ans: .zero 4 * AU_SLOTS      # their answers (AU_IN, AU_OUT)
au_next: .long 0                # the slot a new profile takes when all are used
.data
.p2align 2
au_fd: .long -1                 # its output's pipe while it runs
sh_ps: .long SH_PS              # the terminal's shell: PowerShell (Windows) or a POSIX shell (sh_word)

.text

# ---- start ----

# cl_start(AL*) -> eax 1 with claude started and initialize written, 0 with AL_report saying why. Locals:
#   [rsp] argv (28 slots), [rsp + 224] envp, [rsp + 232] the argv prefix (claude_exe), [rsp + 240] where a
#   copy's --session-id= starts in asb (-1: not a copy), [rsp + 248], [rsp + 256], [rsp + 264] where
#   --model=, --effort= and --permission-mode= start in asb (-1: not passed)
cl_start:
    PROLOGUE 288
    mov rbx, rdi
    mov r12, [rbx + AL_as]
    lea rdi, [rbx + AL_report]
    call sb_clear
    mov edi, AG_CLAUDE          # a start is a writer's action: the project's record is read (agentcfg.s)
    call agentcfg_get
    mov rdi, rax
    call agentcfg_need
    call claude_exe
    test rax, rax
    jz .Lcs_missing
    mov [rsp + 232], rax
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
    mov edi, AG_CLAUDE          # the project's thinking level (unset: on)
    call agentcfg_get
    mov r15, rax
    lea rcx, [rip + .La_thinking]
    lea rdx, [rip + .La_nothink]
    cmp dword ptr [r15 + AGC_think], 0
    cmove rcx, rdx
    mov [r13 + 8], rcx
    add r13, 16
    # --session-id=UUID (new) or --resume=ID, or a copy's --resume=SRC --fork-session --session-id=UUID
    # (its first start); before them the project's --model= and --effort= (finding 13) and the mode
    lea rdi, [rip + asb]
    call sb_clear
    mov qword ptr [rsp + 240], -1   # where a copy's --session-id= starts in asb
    mov eax, [rbx + AL_flags]
    and eax, ALF_NEW | ALF_FORK
    cmp eax, ALF_NEW | ALF_FORK
    jne 41f
    lea rdi, [rip + asb]
    lea rsi, [rip + .La_resume]
    call sb_push_cstr
    lea rdi, [rip + asb]
    lea rsi, [rbx + AL_fork]
    call sb_push_cstr
    lea rdi, [rip + asb]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + asb + SB_len]
    mov [rsp + 240], rax
    lea rsi, [rip + .La_sid]
    jmp 42f
41: lea rsi, [rip + .La_sid]
    lea rax, [rip + .La_resume]
    test dword ptr [rbx + AL_flags], ALF_NEW
    cmovz rsi, rax
42: lea rdi, [rip + asb]
    call sb_push_cstr
    lea rdi, [rip + asb]
    lea rsi, [rbx + AL_sid]
    call sb_push_cstr
    lea rdi, [rip + asb]
    xor esi, esi
    call sb_push_byte
    mov rdi, r15
    lea rsi, [r15 + AGC_model]
    lea rdx, [rip + .La_model]
    lea rcx, [rsp + 248]
    call arg_add
    mov rdi, r15
    lea rsi, [r15 + AGC_effort]
    lea rdx, [rip + .La_effort]
    lea rcx, [rsp + 256]
    call arg_add
    mov rdi, rbx                # the conversation's mode, the project's default, initial_mode; bypass
    call claude_start_mode      #   only with [claude] allow_bypass_permissions
    mov rsi, rax
    test rax, rax
    jnz 43f
    lea rsi, [rip + .Lempty]
43: mov rdi, r15
    lea rdx, [rip + .La_mode]
    lea rcx, [rsp + 264]
    call arg_add
    mov r14, [rip + asb + SB_ptr]   # asb grows no more: its strings' places
    mov ecx, 248
44: mov rax, [rsp + rcx]
    cmp rax, -1
    je 45f
    add rax, r14
    mov [r13], rax
    add r13, 8
45: add ecx, 8
    cmp ecx, 264
    jbe 44b
    cmp dword ptr [rip + cfg_claude_allow_bypass], 0
    je 5f
    lea rax, [rip + .La_danger] # a running process may switch to bypass only with it (finding 10)
    mov [r13], rax
    add r13, 8
5:  mov [r13], r14
    mov rcx, [rsp + 240]
    cmp rcx, -1
    je 51f
    lea rdx, [rip + .La_fork]
    mov [r13 + 8], rdx
    lea rax, [r14 + rcx]
    mov [r13 + 16], rax
    add r13, 16
51: mov qword ptr [r13 + 8], 0
    mov rdi, rbx
    call start_env
    mov [rsp + 224], rax
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
    mov rdx, [rsp + 224]
    call conn_open
    mov r13d, eax
    mov rdi, [rsp + 224]
    call mem_free
    mov rdi, [rsp + 232]
    call mem_free
    test r13d, r13d
    jz .Lcs_fail
    mov rdi, rbx                # what its first answers settle (claude_session.s)
    call claude_started
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
    lea rdi, [rip + cw]         # [claude] prompt_suggestions (finding 19)
    lea rsi, [rip + .Lk_suggestions]
    call jw_key
    lea rdi, [rip + cw]
    mov esi, [rip + cfg_claude_prompt_suggestions]
    call jw_bool
    lea rdi, [rip + cw]         # the dialog kinds rhun can show (claude_cards.s: the dialog cards; a
    lea rsi, [rip + .Lk_dialog_kinds]   #   request of any other kind gets an error reply, finding 25)
    call jw_key
    lea rdi, [rip + cw]
    call jw_arr
    call claude_dialog_kinds
    lea rdi, [rip + cw]
    call jw_end_arr
    lea rdi, [rip + cw]         # the two members the extension always sends (P 2.2; finding 34: for an
    lea rsi, [rip + .Lk_task_stop]      #   agent of depth 1 they change nothing visible)
    call jw_key
    lea rdi, [rip + cw]
    mov esi, 1
    call jw_bool
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_nested]
    call jw_key
    lea rdi, [rip + cw]
    mov esi, 1
    call jw_bool
    mov rdi, rbx                # a child gone already breaks the connection here: its close reports the
    call req_end                #   failed start (cl_close: ev_failed, ev_closed), the state says so
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
    mov rdi, [rsp + 232]
    call mem_free
    lea rdi, [rbx + AL_report]
    lea rsi, [rip + .Lr_badid]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE

# arg_add(-, value cstr, prefix cstr, slot*): "PREFIXVALUE" and a NUL after asb's strings, its place in
#   asb into the slot; an empty value adds nothing (-1 in the slot)
arg_add:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov qword ptr [r14], -1
    cmp byte ptr [r12], 0
    je 9f
    mov rax, [rip + asb + SB_len]
    mov [r14], rax
    lea rdi, [rip + asb]
    mov rsi, r13
    call sb_push_cstr
    lea rdi, [rip + asb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + asb]
    xor esi, esi
    call sb_push_byte
9:  EPILOGUE

# start_env(AL*) -> rax envp for its program (mem_free it): claude_env's, or with CLAUDE_CONFIG_DIR its
#   conversation's folder (live_dir) when the configuration names another one now
start_env:
    PROLOGUE
    mov rbx, rdi
    call live_dir
    test rax, rax
    jz 8f
    mov r12, rax
    lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    call claude_dir
    test eax, eax
    jz 1f
    mov rdi, r12
    mov rsi, [rip + psb + SB_ptr]
    call strcmp_eq
    test eax, eax
    jnz 8f
1:  mov rdi, r12
    call claude_env_dir
    EPILOGUE
8:  call claude_env
    EPILOGUE

# live_dir(AL*) -> rax the Claude folder its conversation lives in (AL_cdir; 0 without any), kept from its
#   first use while the record lives: for an existing conversation where its file is (AS_path:
#   FOLDER/projects/SLUG/ID.jsonl), for a new one (no file yet; a copy has its source's: claude_fork_dir)
#   the one claude_dir gives at its first start. Used by start_env and pin (the transcript, the search by
#   id, the holder check)
live_dir:
    PROLOGUE
    mov rbx, rdi
    mov rax, [rbx + AL_cdir]
    test rax, rax
    jnz 9f
    test dword ptr [rbx + AL_flags], ALF_NEW
    jnz 7f
    mov rax, [rbx + AL_as]
    mov rdi, [rax + AS_path]
    call path_folder
    test rax, rax
    jnz 8f
7:  lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    call claude_dir
    test eax, eax
    jz 9f
    mov rdi, [rip + psb + SB_ptr]
    mov rsi, [rip + psb + SB_len]
    call mem_dup
8:  mov [rbx + AL_cdir], rax
9:  EPILOGUE

# path_folder(path cstr or 0) -> rax the Claude folder of a transcript's path, mem_dup'd: what comes before
#   "/projects/SLUG/NAME" (either separator on Windows); 0 when the path is not of that shape
path_folder:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    test rbx, rbx
    jz 9f
    call strlen
    mov r12, rax                # where the search goes back from
    xor r13d, r13d              # separators found
1:  test r12, r12
    jz 8f
    dec r12
    movzx eax, byte ptr [rbx + r12]
    cmp eax, '/'
    je 2f
.ifdef WINDOWS
    cmp eax, 92
    je 2f
.endif
    jmp 1b
2:  inc r13d
    cmp r13d, 2
    jne 3f
    mov r14, r12                # the separator after "projects"
3:  cmp r13d, 3
    jb 1b
    mov rax, r14                # the component between this separator and the next is "projects"
    sub rax, r12
    cmp rax, 9
    jne 8f
    lea rdi, [rbx + r12 + 1]
    lea rsi, [rip + .Lw_projects]
    mov edx, 8
    call memeq
    test eax, eax
    jz 8f
    test r12, r12
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call mem_dup
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN claude_fork_dir(copy AL*, source AL*): Continue in a copy: the copy lives where its source does (the
#   fork reads the source's file there): its folder and its transcript's path are the source's folder's
FN claude_fork_dir
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    call live_dir
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov r13, rax
    mov rdi, [rbx + AL_cdir]
    call mem_free
    mov [rbx + AL_cdir], r13
    mov rdi, r13                # its file's path in that folder
    call claude_dir_pin
    lea rdi, [rip + psb]
    call sb_clear
    mov rax, [rbx + AL_as]
    mov rsi, [rax + AS_cwd]
    test rsi, rsi
    jnz 1f
    mov rsi, [rip + g_project]
1:  lea rdi, [rip + psb]
    lea rdx, [rbx + AL_sid]
    call claude_transcript
    mov r14d, eax
    xor edi, edi
    call claude_dir_pin
    test r14d, r14d
    jz 9f
    mov rdi, rbx
    mov rsi, [rip + psb + SB_ptr]
    call take_path
9:  EPILOGUE

# pin(AL*): claude_dir gives the folder its conversation lives in (live_dir)
pin:
    PROLOGUE
    call live_dir
    mov rdi, rax
    call claude_dir_pin
    EPILOGUE

# unpin(): claude_dir follows the configuration again
unpin:
    xor edi, edi
    jmp claude_dir_pin

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

# cl_send(AL*, ptr, len, uuid cstr or 0) -> eax 1 written: {"type":"user","message":{"role":"user",
#   "content":[{"type":"text","text":T}]},"parent_tool_use_id":null,"session_id":"","uuid":U}: the uuid
#   comes back in its command_lifecycle and its replay (finding 17). 0 when the connection refused it, or
#   broke under the write (its close reported that: the state is not the caller's any more)
cl_send:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
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
    test r14, r14
    jz 1f
    cmp byte ptr [r14], 0
    je 1f
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_uuid]
    call jw_key
    lea rdi, [rip + cw]
    mov rsi, r14
    call jw_cstr
1:  lea rdi, [rip + cw]
    call jw_end_obj
    mov rdi, rbx
    call cl_write
    test eax, eax
    jz 9f
    xor eax, eax                # the write broke the connection (its close ran, cl_close): not sent
    cmp dword ptr [rbx + AL_cn + CN_state], CN_UP
    jne 9f
    inc qword ptr [rbx + AL_turns]
    mov eax, 1
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
    test eax, eax
    jnz 9f
    and dword ptr [rbx + AL_flags], ~ALF_STOP_ASKED   # refused (the input queue is full): not asked
9:  EPILOGUE

# cl_release(AL*): claude's input ends; it exits by itself, the stop sequence follows (agent_conn.s)
cl_release:
    lea rdi, [rdi + AL_cn]
    jmp conn_end_input

# cl_held(AL*) -> eax HOLDER_*: whether another program has the conversation open (agent_holder.s); a new
#   one (a copy too) is nobody else's
cl_held:
    PROLOGUE
    mov rbx, rdi
    mov eax, HOLDER_NONE
    test dword ptr [rbx + AL_flags], ALF_NEW
    jnz 9f
    call resume_sid
    mov ecx, eax
    mov eax, HOLDER_NONE
    test ecx, ecx
    jz 9f                       # no id: the start says so
    mov rdi, rbx                # in the folder it lives in
    call pin
    lea rdi, [rbx + AL_sid]
    call holder_claude
    mov ebx, eax
    call unpin
    mov eax, ebx
9:  EPILOGUE

# ---- the sign-in state: `claude auth status --json`, once a window, in the background ----

# cl_auth(AL*, again) -> eax AUTH_*: whether claude is signed in in the profile this conversation's program
#   uses (its Claude folder, live_dir: the environment start_env gives it). The first time a window asks
#   for a profile (and again after it said no, when again is 1: the next Send), `[WRAPPER] CLAUDE auth
#   status --json` runs in the background with that environment (au_begin); while it runs the answer is
#   AUTH_WAIT (also while another profile's question runs: one at a time). Only its loggedIn is read; an
#   answer rhun cannot read, one later than AUTH_MS, or a program that cannot be started is AUTH_IN: claude
#   says otherwise itself when it starts. Answers are kept per profile for the window
cl_auth:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call live_dir
    test rax, rax
    jz .Lau_in
    mov r13, rax                # the profile
    mov rdi, rax
    call au_get
    cmp eax, AU_IN
    je .Lau_in
    cmp eax, AU_OUT
    jne 1f
    test r12d, r12d
    jz .Lau_out
    mov rdi, r13                # asked again: a Send after "not signed in"
    xor esi, esi
    call au_set
1:  cmp dword ptr [rip + au_state], AU_ASKING
    jne 2f
    mov rdi, r13                # a question runs: another profile's, or this one's still in time
    mov rsi, [rip + au_key]
    call strcmp_eq
    test eax, eax
    jz .Lau_wait
    call time_ms
    cmp rax, [rip + au_until]
    jl .Lau_wait
    call au_timeout             # too slow: it counts as signed in
    jmp .Lau_in
2:  mov rdi, rbx
    call au_begin
    test eax, eax
    jz 3f
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call mem_dup
    mov [rip + au_key], rax
    jmp .Lau_wait
3:  mov rdi, r13                # cannot ask: signed in, as far as rhun knows
    mov esi, AU_IN
    call au_set
.Lau_in:
    mov eax, AUTH_IN
    EPILOGUE
.Lau_wait:
    mov eax, AUTH_WAIT
    EPILOGUE
.Lau_out:
    mov eax, AUTH_OUT
    EPILOGUE

# au_find(profile cstr) -> eax its slot in au_keys, or -1
au_find:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12d, AU_SLOTS
    jae 8f
    lea rax, [rip + au_keys]
    mov rsi, [rax + r12*8]
    test rsi, rsi
    jz 2f
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jnz 9f
2:  inc r12d
    jmp 1b
8:  mov r12d, -1
9:  mov eax, r12d
    EPILOGUE

# au_get(profile) -> eax its answer (AU_IN, AU_OUT) or AU_UNKNOWN
au_get:
    PROLOGUE
    call au_find
    test eax, eax
    js 8f
    lea rcx, [rip + au_ans]
    mov eax, [rcx + rax*4]
    EPILOGUE
8:  mov eax, AU_UNKNOWN
    EPILOGUE

# au_set(profile, answer): kept (AU_UNKNOWN: forgotten); a new profile takes a free slot, else the next
#   in turn
au_set:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call au_find
    test eax, eax
    jns 5f
    test r12d, r12d
    jz 9f                       # forgetting one that is not there
    xor ecx, ecx                # a free slot
1:  cmp ecx, AU_SLOTS
    jae 2f
    lea rdx, [rip + au_keys]
    cmp qword ptr [rdx + rcx*8], 0
    je 3f
    inc ecx
    jmp 1b
2:  mov ecx, [rip + au_next]    # none: the next in turn
    lea eax, [rcx + 1]
    and eax, AU_SLOTS - 1
    mov [rip + au_next], eax
3:  mov r13d, ecx
    lea rdx, [rip + au_keys]
    mov rdi, [rdx + r13*8]
    call mem_free
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    lea rdx, [rip + au_keys]
    mov [rdx + r13*8], rax
    mov eax, r13d
5:  mov r13d, eax
    lea rcx, [rip + au_ans]
    mov [rcx + r13*4], r12d
    test r12d, r12d
    jnz 9f
    lea rdx, [rip + au_keys]    # forgotten: the slot is free
    mov rdi, [rdx + r13*8]
    mov qword ptr [rdx + r13*8], 0
    call mem_free
9:  EPILOGUE

# au_done(answer): the running question ended with that answer for its profile (au_key), which goes
au_done:
    PROLOGUE
    mov r12d, edi
    mov rbx, [rip + au_key]
    mov qword ptr [rip + au_key], 0
    call claude_auth_end
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    mov esi, r12d
    call au_set
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# au_timeout(): the running question took too long: it ends, its profile counts as signed in
au_timeout:
    mov edi, AU_IN
    jmp au_done

# au_begin(AL*) -> eax 1 when the status question runs (AU_ASKING) with the environment the conversation's
#   start uses (start_env): its stdout (and stderr) on a pipe read by au_on_out, stdin at its end. Locals:
#   [rsp] argv (8 slots), [rsp + 64] the pipes, [rsp + 80] envp, [rsp + 88] the prefix
au_begin:
    PROLOGUE 96
    mov r12, rdi
    call claude_exe
    test rax, rax
    jz 8f
    mov [rsp + 88], rax
    xor ecx, ecx
1:  cmp ecx, edx
    jae 2f
    mov r8, [rax + rcx*8]
    mov [rsp + rcx*8], r8
    inc ecx
    jmp 1b
2:  lea rax, [rip + .La_auth]
    mov [rsp + rcx*8], rax
    lea rax, [rip + .La_status]
    mov [rsp + rcx*8 + 8], rax
    lea rax, [rip + .La_json]
    mov [rsp + rcx*8 + 16], rax
    mov qword ptr [rsp + rcx*8 + 24], 0
    lea rdi, [rsp + 64]         # in: [64] it reads, [68] rhun's end, closed at once
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    jnz 7f
    lea rdi, [rsp + 72]         # out: [72] rhun reads, [76] it writes (stdout and stderr)
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    jnz 6f
    mov rdi, r12
    call start_env
    mov [rsp + 80], rax
    lea rdi, [rsp]
    mov rsi, rax
    mov rdx, [rip + g_project]
    mov ecx, [rsp + 64]
    mov r8d, [rsp + 76]
    mov r9d, [rsp + 76]
    xor eax, eax
    push rax
    push rax
    call uproc_spawn
    add rsp, 16
    mov rbx, rax
    mov rdi, [rsp + 80]
    call mem_free
    mov edi, [rsp + 64]
    SYS SYS_close
    mov edi, [rsp + 68]
    SYS SYS_close
    mov edi, [rsp + 76]
    SYS SYS_close
    test rbx, rbx
    jle 5f
    mov edi, [rsp + 72]
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov edi, [rsp + 72]
    mov esi, POLLIN
    lea rdx, [rip + au_on_out]
    xor ecx, ecx
    call watch_try_add
    test eax, eax
    jz 4f
    mov [rip + au_pid], ebx
    mov eax, [rsp + 72]
    mov [rip + au_fd], eax
    lea rdi, [rip + au_buf]
    call sb_clear
    call time_ms
    add rax, AUTH_MS
    mov [rip + au_until], rax
    mov dword ptr [rip + au_state], AU_ASKING
    mov rdi, [rsp + 88]
    call mem_free
    mov eax, 1
    EPILOGUE
4:  mov edi, ebx                # no room to watch it: it goes
    xor esi, esi
    call uproc_end
5:  mov edi, [rsp + 72]
    SYS SYS_close
    jmp 7f
6:  mov edi, [rsp + 64]
    SYS SYS_close
    mov edi, [rsp + 68]
    SYS SYS_close
7:  mov rdi, [rsp + 88]
    call mem_free
8:  xor eax, eax
    EPILOGUE

# au_on_out(fd, events, ctx): the status question's output, kept up to AUTH_MAX bytes; at its end the
#   answer is read
au_on_out:
    PROLOGUE
    mov ebx, edi
1:  lea rdi, [rip + au_buf]
    mov esi, 4096
    call sb_reserve
    mov rsi, rax
    mov edi, ebx
    mov edx, 4096
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 2f
    mov rcx, [rip + au_buf + SB_len]
    cmp rcx, AUTH_MAX
    jae 1b                      # past the limit: read and dropped
    add [rip + au_buf + SB_len], rax
    jmp 1b
2:  call au_answer
9:  EPILOGUE

# au_answer(): the question ended: its loggedIn, false -> AU_OUT, anything else -> AU_IN
au_answer:
    PROLOGUE
    mov ebx, AU_IN
    mov rdi, [rip + au_buf + SB_ptr]
    mov rsi, [rip + au_buf + SB_len]
    test rsi, rsi
    jz 9f
    xor ecx, ecx                # from its first "{": a line before it is not the answer
1:  cmp rcx, rsi
    jae 9f
    cmp byte ptr [rdi + rcx], '{'
    je 2f
    inc rcx
    jmp 1b
2:  add rdi, rcx
    sub rsi, rcx
    call json_parse
    test rax, rax
    jz 9f
    mov rdi, rax
    lea rsi, [rip + .Lk_loggedIn]
    call json_get
    mov rdi, rax
    call json_bool
    test edx, edx
    jz 9f
    test eax, eax
    jnz 9f
    mov ebx, AU_OUT
9:  mov edi, ebx                # (the answer is read before anything frees au_buf)
    call au_done
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN claude_auth_tick(): the sign-in question's time, kept whoever waits for it (a draft left before the
#   answer has no record to ask cl_auth): past AUTH_MS it ends and counts as signed in, as in cl_auth. The
#   driver's other clock goes with it: prompts that waited too long for a get_settings answer
#   (claude_settings_tick)
FN claude_auth_tick
    PROLOGUE
    call claude_settings_tick
    cmp dword ptr [rip + au_state], AU_ASKING
    jne 9f
    call time_ms
    cmp rax, [rip + au_until]
    jl 9f
    call au_timeout
9:  EPILOGUE

# FN claude_auth_timeout() -> eax ms until the sign-in question's time is up (0: now), or the wait for a
#   get_settings answer (claude_settings_timeout), whichever comes first; -1 when none runs
FN claude_auth_timeout
    PROLOGUE
    call claude_settings_timeout
    mov ebx, eax
    mov eax, -1
    cmp dword ptr [rip + au_state], AU_ASKING
    jne 9f
    call time_ms
    mov rcx, [rip + au_until]
    sub rcx, rax
    xor eax, eax
    test rcx, rcx
    cmovg eax, ecx
9:  test ebx, ebx
    js 8f
    test eax, eax
    js 7f
    cmp eax, ebx
    jbe 8f
7:  mov eax, ebx
8:  EPILOGUE

# FN claude_auth_end(): the status question, if one runs, ends (its watch, its pipe, its process); its
#   profile is asked again next time (au_done sets an answer after)
FN claude_auth_end
    PROLOGUE
    mov dword ptr [rip + au_state], AU_UNKNOWN
    mov rdi, [rip + au_key]
    mov qword ptr [rip + au_key], 0
    call mem_free
    mov edi, [rip + au_fd]
    test edi, edi
    js 1f
    call watch_remove
    mov edi, [rip + au_fd]
    SYS SYS_close
    mov dword ptr [rip + au_fd], -1
1:  mov edi, [rip + au_pid]
    test edi, edi
    jz 9f
    mov dword ptr [rip + au_pid], 0
    mov esi, 2000
    call uproc_end
9:  EPILOGUE

# cl_terminal(AL*, what): claude in rhun's terminal prompt (it runs when the user presses Enter there): the
#   configured program ("~/" expanded as the start does; the wrapper is not used there) or "claude",
#   found on the terminal's PATH, with "auth login" for what 1, "auth logout" for what 2. Before it, what the terminal's claude needs
#   to use the same profile as this conversation's program (claude_term_env: its CLAUDE_CONFIG_DIR, else
#   an env.HOME pair's HOME, when the terminal's differs); never anything else (values may be keys, and
#   the line ends up in the shell's history). For the shell rhun's terminal starts: a POSIX shell,
#   PowerShell on Windows
cl_terminal:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    xor r14d, r14d              # the conversation's folder, without fixing it (live_dir would): its own,
    mov rdi, [rbx + AL_cdir]    #   or where its file is (an existing one)
    test rdi, rdi
    jnz 0f
    test dword ptr [rbx + AL_flags], ALF_NEW
    jnz 0f
    mov rax, [rbx + AL_as]
    mov rdi, [rax + AS_path]
    call path_folder
    mov r14, rax                # (freed below)
    mov rdi, rax
0:  call claude_term_env
    mov r15, rdx
    lea r13, [rip + .Lw_config_dir]
    cmp eax, 1
    je 4f
    lea r13, [rip + .Lw_home]
    cmp eax, 2
    jne 1f
4:  lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    mov rsi, r13
    mov rdx, r15
    call sh_assign
    jmp 5f
1:  lea rdi, [rip + psb]
    call sb_clear
5:  mov rdi, r14
    call mem_free
    mov rdi, [rip + cfg_claude_executable]
    lea rsi, [rip + .Lw_claude]
    cmp byte ptr [rdi], 0
    je 2f
    call claude_expand_home     # "~/" as the start reads it: quoted, no shell would expand it
    mov rsi, rax
2:  lea rdi, [rip + psb]
    mov edx, 1
    call sh_word
    test r12d, r12d
    jz 3f
    lea rsi, [rip + .Lw_login]
    cmp r12d, 2                 # 2: its sign-out
    jne 31f
    lea rsi, [rip + .Lw_logout]
31: lea rdi, [rip + psb]
    call sb_push_cstr
3:  mov rdi, [rip + psb + SB_ptr]
    mov rsi, [rip + psb + SB_len]
    call extproto_own_term
    test eax, eax
    jnz 9f
    lea rdi, [rip + .Lr_prompt_busy]
    call app_toast
9:  EPILOGUE

# sh_word(sb, cstr, head): the word for the terminal's shell (sh_ps: PowerShell, else a POSIX shell). POSIX:
#   as it is when it has only letters, digits and / . _ - + ~ : , @, else in single quotes (a quote in it as
#   '\''). PowerShell: a command (head 1) as it is when it has only letters, digits and / . _ - : \, else
#   "& " and the word in single quotes (a quoted word is a string there, not a command); a value (head 0)
#   always in single quotes (unquoted it would be run as a command); a quote in it doubled
sh_word:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r14d, edx
    lea r15, [rip + .Lsh_plain]
    cmp dword ptr [rip + sh_ps], 0
    je 0f
    lea r15, [rip + .Lsh_plain_ps]
    test r14d, r14d
    jz 31f                      # a PowerShell value: quoted, whatever it holds
0:  xor ecx, ecx
1:  movzx eax, byte ptr [r12 + rcx]
    test eax, eax
    jz 7f                       # all plain
    inc rcx
    mov rdx, r15
2:  movzx r8d, byte ptr [rdx]
    test r8d, r8d
    jz 3f
    inc rdx
    cmp eax, r8d
    je 1b
    jmp 2b
3:  mov r8d, eax                # a letter or a digit
    or r8d, 0x20
    sub r8d, 'a'
    cmp r8d, 25
    jbe 1b
    sub eax, '0'
    cmp eax, 9
    jbe 1b
    cmp dword ptr [rip + sh_ps], 0
    je 31f
    test r14d, r14d
    jz 31f
    mov rdi, rbx
    lea rsi, [rip + .Lsh_call]
    call sb_push_cstr
31: mov rdi, rbx                # quoted
    mov esi, 39
    call sb_push_byte
    xor r13d, r13d
4:  movzx esi, byte ptr [r12 + r13]
    test esi, esi
    jz 6f
    inc r13
    cmp esi, 39
    jne 5f
    mov rdi, rbx
    lea rsi, [rip + .Lsh_quote]
    cmp dword ptr [rip + sh_ps], 0
    je 41f
    lea rsi, [rip + .Lsh_quote_ps]
41: call sb_push_cstr
    jmp 4b
5:  mov rdi, rbx
    call sb_push_byte
    jmp 4b
6:  mov rdi, rbx
    mov esi, 39
    call sb_push_byte
    EPILOGUE
7:  mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    EPILOGUE

# sh_assign(sb, name cstr, value cstr): a variable for the command after it, in the terminal's shell:
#   "NAME=VALUE " (POSIX: for that command only), "$env:NAME=VALUE; " (PowerShell: for the session)
sh_assign:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp dword ptr [rip + sh_ps], 0
    je 1f
    lea rsi, [rip + .Lsh_env]
    call sb_push_cstr
1:  mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov esi, '='
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    xor edx, edx
    call sh_word
    mov rdi, rbx
    lea rsi, [rip + .Lsh_tail]
    cmp dword ptr [rip + sh_ps], 0
    je 2f
    lea rsi, [rip + .Lsh_tail_ps]
2:  call sb_push_cstr
    EPILOGUE

# FN agent_sh_quote(sb, ps, kind, name, text): print-sh-quote: the quoting of either shell on any system,
#   for tests: kind 0 a value, 1 a command, 2 "NAME=value" (sh_assign); a line
FN agent_sh_quote
    PROLOGUE
    mov rbx, rdi
    mov r12d, edx
    mov r13, rcx
    mov r14, r8
    mov r15d, [rip + sh_ps]
    mov [rip + sh_ps], esi
    cmp r12d, 2
    jne 1f
    mov rsi, r13
    mov rdx, r14
    call sh_assign
    jmp 2f
1:  mov rdi, rbx
    mov rsi, r14
    mov edx, r12d
    call sh_word
2:  mov [rip + sh_ps], r15d
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# auth_error(ptr, len) -> eax 1 when a turn's error says claude's sign-in was refused (an expired or
#   missing one): the words the CLI uses for it
auth_error:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + auth_words]
1:  mov r14, [rbx]
    test r14, r14
    jz 8f
    add rbx, 8
    mov rdi, r14
    call strlen
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, rax
    call str_find
    test rax, rax
    js 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---- reading ----

# cl_line(CN*, ptr, len): one record from claude, dispatched on its type; the rows it makes carry the
#   record's time (its timestamp, else the clock)
cl_line:
    PROLOGUE 16
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
2:  mov rax, [rbx + AL_as]
    mov [rsp], rax
    mov rdi, r14
    lea rsi, [rip + .Lk_timestamp]
    call jstr
    xor ecx, ecx
    test rdx, rdx
    jz 3f
    mov rdi, rax
    mov rsi, rdx
    call agtime_iso
    mov rcx, rax
3:  test rcx, rcx
    jnz 4f
    call agtime_now
    mov rcx, rax
4:  mov rdi, [rsp]
    mov rsi, rcx
    call agents_stamp
    mov rdi, rbx
    mov rsi, r14
    call [r12 + 8]              # handler(AL*, record)
    mov rdi, [rsp]              # (a handler may free the live record, never the conversation)
    xor esi, esi
    call agents_stamp
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
#   gets the label the file would give it; the other blocks (calls, unknown blocks) go to claude_ingest. A
#   record sent again is dropped; a subagent's reaches claude_ingest and nothing else. Locals: [rsp] the
#   model, [rsp + 8] its length, [rsp + 16] and [rsp + 24] the message id, then a block's key, [rsp + 32]
#   the record
h_assistant:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov [rsp + 32], rsi
    call claude_seen            # a record sent again (finding 30): dropped
    test eax, eax
    jnz 9f
    mov rdi, r12
    call is_sub
    test eax, eax
    jz 0f
    mov rdi, [rbx + AL_as]      # a subagent's: its calls under their parent, nothing else (not the context
    mov rsi, r12                #   numbers, not the model's label)
    mov edx, ING_LIVE
    call claude_ingest
    jmp 9f
0:  mov rdi, rbx                # the context in use and the prompt cache (claude_session.s)
    mov rsi, r12
    call claude_frame
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
    jae 8f
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
5:  inc r15d
    jmp 3b
8:  mov rdi, [rbx + AL_as]      # the record's other blocks: calls, unknown blocks (claude_blocks.s)
    mov rsi, [rsp + 32]
    mov edx, ING_LIVE
    call claude_ingest
9:  EPILOGUE

# h_user(AL*, record): what Claude sends as the user's: a tool's results go into their calls' rows
#   (claude_ingest), as the file reader puts them. The user's own prompts (rhun showed them when sent) and
#   notices are not shown; a replayed copy (isReplay) says a held message started (claude_replay); a
#   subagent's records reach claude_ingest and nothing else
h_user:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call claude_seen            # a record sent again (finding 30): dropped
    test eax, eax
    jnz 9f
    mov rdi, r12
    call is_sub
    test eax, eax
    jz 1f
    mov rdi, [rbx + AL_as]      # a subagent's: its results into its calls, nothing else (no request clock)
    mov rsi, r12
    mov edx, ING_LIVE
    call claude_ingest
    jmp 9f
1:  mov rdi, rbx                # a request goes out: the prompt cache's clock (claude_session.s)
    call claude_asked
    mov rdi, r12
    lea rsi, [rip + .Lk_isReplay]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_TRUE
    jne 2f
    mov rdi, rbx                # a message of the user's as its turn starts (claude_session.s)
    mov rsi, r12
    call claude_replay
    jmp 9f
2:  mov rdi, [rbx + AL_as]      # results into their calls' rows (claude_blocks.s)
    mov rsi, r12
    mov edx, ING_LIVE
    call claude_ingest
9:  EPILOGUE

# h_system(AL*, record): init (the session's id, its folder, the mode) and status (the mode)
h_system:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call claude_record          # fast mode's state, notifications (claude_session.s)
    mov rdi, r12
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
    jnz 5f
    mov rdi, r13
    lea rsi, [rip + .Lv_commands_changed]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, rbx                # the whole command list again (claude_session.s)
    mov rsi, r12
    call claude_commands_changed
    jmp 9f
1:  mov rdi, r12                # "ultrathink" painted in the box while the session offers it (finding 21)
    lea rsi, [rip + .Lk_ultrathink]
    call json_get
    mov rdi, rax
    call json_bool
    lea rsi, [rip + .Lv_ultrathink]
    test eax, eax
    jnz 11f
    lea rsi, [rip + .Lempty]
11: mov rdi, rbx
    call ev_word
    mov rdi, r12                # the id it runs under: ours (--session-id), else it is taken
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

# h_suggestion(AL*, record): prompt_suggestion {suggestion} (finding 19): the box's placeholder until the next
#   turn or Send, Tab takes it ([claude] prompt_suggestions off: initialize asked for none; one is dropped)
h_suggestion:
    PROLOGUE
    cmp dword ptr [rip + cfg_claude_prompt_suggestions], 0
    je 9f
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_suggestion]
    call jstr
    mov rdi, rbx
    mov rsi, rax
    call ev_suggest
9:  EPILOGUE

# set_path(AL*, cwd cstr): the session's transcript path is the one Claude Code gives AL_sid in that folder
set_path:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call pin                    # its program's folder
    lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    mov rsi, r12
    lea rdx, [rbx + AL_sid]
    call claude_transcript
    mov r13d, eax
    call unpin
    test r13d, r13d
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
    call claude_record          # fast mode's state (claude_session.s)
    mov rdi, r12                # the text: errors[0], else result
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
    cmp r15d, TE_ERROR          # refused credentials: the sign-in notice, the state asked again
    jne 5f
    mov rdi, r13
    mov rsi, r14
    call auth_error
    test eax, eax
    jz 5f
    mov rdi, rbx                # its profile is asked again at the next start
    call live_dir
    test rax, rax
    jz 41f
    mov rdi, rax
    xor esi, esi
    call au_set
41: mov rdi, rbx
    call ev_signed_out
5:  test dword ptr [rbx + AL_flags], ALF_NEW
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
1:  lea rdi, [rip + dsb]        # in its program's folder
    call sb_clear
    mov rdi, rbx
    call pin
    lea rdi, [rip + dsb]
    call claude_dir
    mov r13d, eax
    call unpin
    test r13d, r13d
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

# h_request(AL*, record): a request of Claude's. can_use_tool waits for the user (h_can_use); a dialog of
#   a kind rhun declared waits on its card (claude_dialog, claude_cards.s); any other kind gets an error
#   reply, its id echoed as it came (a string or a number), so Claude never waits
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
1:  mov rdi, rbx                # the dialog cards: one rhun shows waits as the others do
    mov rsi, r12
    mov rdx, r13
    call claude_dialog
    cmp rax, 1
    je 9f                       # answered at once
    lea r15, [rip + .Lr_toomany]
    cmp rax, 2
    je 3f                       # AQ_MAX wait: rhun is busy, as for a tool's request
    test rax, rax
    jz 2f
    mov r14, rax
    lea rdi, [rbx + AL_reqs]
    mov esi, 8
    call vec_push
    mov [rax], r14
    cmp qword ptr [rbx + AL_reqs + VEC_len], 1
    jne 9f
    mov rdi, rbx                # nothing else waits: its card shows
    call req_show
9:  EPILOGUE
2:  lea r15, [rip + .Lv_unsupported]
3:  mov rdi, r12
    lea rsi, [rip + .Lk_request_id]
    call json_get
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r15
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
    mov rdi, r14                # not in AL_reqs yet: a close the write caused did not free it
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
    mov rdi, rbx                # the question card (claude_cards.s); one rhun cannot show is denied
    mov rsi, r14
    mov rdx, r15
    call claude_question_build
    test eax, eax
    jnz 6f
    mov rdi, rbx
    mov rsi, r14
    lea rdx, [rip + .Lr_noshow]
    xor ecx, ecx
    call reply_deny
    mov rdi, r14                # not in AL_reqs yet: a close the write caused did not free it
    call agent_aq_free
    EPILOGUE
4:  mov rdi, [r14 + AQ_tool]
    lea rsi, [rip + .Lt_plan]
    call strcmp_eq
    test eax, eax
    jz 5f
    mov dword ptr [r14 + AQ_kind], AQK_PLAN
    mov rdi, rbx                # plan review: its rich card (claude_cards.s; the plan is the call's row)
    mov rsi, r14
    call claude_plan_build
    jmp 6f
5:  mov rdi, r14                # a permission: the question for its tool, and its rich card
    mov rsi, r15
    call perm_prompt
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r13
    call claude_card_build
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
    cmp qword ptr [r12 + AQ_card], 0    # the question card (claude_cards.s)
    jne 22f
    mov rdi, rbx
    mov rsi, r12
    call show_question
    jmp 4f
2:  lea r13, [rip + opts_plan]
    lea r14, [rip + .Lq_plan]
    cmp qword ptr [r12 + AQ_card], 0    # plan review: a plan's rich card too
    jne 22f
    cmp eax, AQK_PLAN
    je 3f
    jmp 21f
22: mov rdi, rbx                # a rich card (claude_cards.s)
    mov rsi, r12
    call claude_card_show
    jmp 4f
21:    lea r13, [rip + opts_yes_no]
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
    mov rdi, rbx                # the deny's write may have closed the connection: every request is
    mov rsi, r12                #   gone then (ev_closed), the state set
    call req_kept
    test eax, eax
    jz 9f
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
    PROLOGUE 144                # 16 labels; a multiple of 16 keeps the stack aligned
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
#   Then the next request's card shows. An answer the connection refuses (its queue is full, its input
#   ended) is not sent: the card shows again, with a toast. Writing can break the connection: its close
#   (cl_close -> ev_closed) frees every request, the card with them, before the write returns
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
    test eax, eax
    jz .Lca_keep                # refused: nothing went
    mov rdi, rbx                # the request is gone when the write closed the connection
    mov rsi, r12
    call req_kept
    test eax, eax
    jz .Lca_gone
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
    test eax, eax
    jnz 8f
    dec qword ptr [r12 + AQ_n]  # refused: the last pick is taken back, its question shows again
    dec qword ptr [r12 + AQ_picks + SB_len]
    jmp .Lca_keep
8:  test eax, eax
    jz .Lca_keep
    mov rdi, rbx                # written; when the write closed the connection, the request and its
    mov rsi, r12                #   card went with it (ev_closed): r12 is freed, nothing more to do
    call req_kept
    test eax, eax
    jz .Lca_gone
    mov rdi, rbx
    mov rsi, r12
    call ev_request_gone
    mov rdi, rbx
    call req_show
.Lca_gone:
    mov eax, 1
9:  EPILOGUE
.Lca_keep:                      # nothing was sent: the card again (agent_answer took it down)
    mov rdi, rbx
    call req_show
    lea rdi, [rip + .Lr_unsent]
    call app_toast
    mov eax, 1
    EPILOGUE

# FN claude_req_after(AL*, AQ*, written): after a rich card's answer (claude_cards.s), as cl_answer ends:
#   written, the request goes (unless the write's close took it already) and the next one's card shows;
#   refused, the card shows again with a toast
FN claude_req_after
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test edx, edx
    jnz 1f
    call req_show
    lea rdi, [rip + .Lr_unsent]
    call app_toast
    EPILOGUE
1:  call req_kept
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call ev_request_gone
    mov rdi, rbx
    call req_show
9:  EPILOGUE

# FN claude_reply_begin(AL*, AQ*), FN claude_reply_end(AL*, AQ*) -> eax 1 written: an answer's envelope in
#   claude_cw (reply_begin, reply_end); FN claude_req_kept(AL*, AQ*) -> eax (req_kept)
FN claude_reply_begin
    jmp reply_begin
FN claude_reply_end
    jmp reply_end
FN claude_req_kept
    jmp req_kept

# req_kept(AL*, AQ*) -> eax 1 when the request is still in AL_reqs. A write that breaks the connection
#   runs its close (cl_close -> ev_closed), which frees every request; nothing adds one meanwhile (only a
#   line from claude does, and a write reads none), so a request that is not there is freed
req_kept:
    mov rcx, [rdi + AL_reqs + VEC_len]
    mov rdx, [rdi + AL_reqs + VEC_ptr]
1:  xor eax, eax
    test rcx, rcx
    jz 9f
    dec rcx
    cmp [rdx + rcx*8], rsi
    jne 1b
    mov eax, 1
9:  ret

# FN cl_set_mode(AL*, mode cstr) -> eax 1 written: set_permission_mode {mode} the user asked for (its answer:
#   claude_mode_answer, picked)
FN cl_set_mode
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov esi, OA_PICK
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
    mov rsi, r12
    call jw_cstr
    mov rdi, rbx
    call req_end
    EPILOGUE

# FN claude_sid(AL*) -> eax 1 when AL_sid is the conversation's id (an existing one's from its file's name,
#   as a start takes it), 0 when it has none
FN claude_sid
    mov eax, 1
    cmp byte ptr [rdi + AL_sid], 0
    jne 1f
    test dword ptr [rdi + AL_flags], ALF_NEW
    jnz 2f
    jmp resume_sid
2:  xor eax, eax
1:  ret

# set_mode_default(AL*): {"type":"control_request","request_id":"rN","request":{"subtype":
#   "set_permission_mode","mode":"default"}} (its answer, as system/status, reports the mode)
set_mode_default:
    lea rsi, [rip + .Lv_default]
    jmp claude_mode_quiet

# FN claude_mode_quiet(AL*, mode cstr) -> eax 1 written: set_permission_mode {mode} that is no pick of the
#   user's (a rule's setMode, a plan's answer): its answer is dropped, system/status reports the mode
FN claude_mode_quiet
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
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
    mov rsi, r12
    call jw_cstr
    mov rdi, rbx
    call req_end
    EPILOGUE

# plan review: FN claude_mode_plan(AL*, mode cstr) -> eax 1 written: set_permission_mode {mode} whose answer
#   claude_plan_mode_answer waits for (a plan's Yes with auto mode); FN claude_get_plan(AL*) -> eax 1
#   written: get_plan, its answer for claude_plan_answer (/plan)
FN claude_mode_plan
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov esi, OA_PLAN_MODE
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
    mov rsi, r12
    call jw_cstr
    mov rdi, rbx
    call req_end
    EPILOGUE
FN claude_get_plan
    PROLOGUE
    mov rbx, rdi
    mov esi, OA_GET_PLAN
    call req_begin
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_subtype]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_get_plan]
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
#   (set_permission_mode's mode is in effect: claude_mode_answer)
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
    mov r13, rsi
    call parse_u64
    cmp rdx, r13                # every byte after the "r" a digit: "r2abc" is another's id, not request 2
    jne 9f
    mov r15, rax                # the request's number
    mov rdi, rbx
    mov rsi, rax
    call out_take
    cmp eax, OA_PLAN_MODE       # plan review: auto before a plan's Yes, get_plan (claude_cards.s)
    jne 33f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15                # (the plan whose Yes waits for this request's answer)
    call claude_plan_mode_answer
    jmp 9f
33: cmp eax, OA_GET_PLAN
    jne 34f
    mov rdi, rbx
    mov rsi, r12
    call claude_plan_answer
    jmp 9f
34: cmp eax, OA_SETTINGS
    jne 1f
    mov rdi, rbx                # get_settings: the model, effort and Ultracode in effect (claude_session.s)
    mov rsi, r12
    call claude_settings_answer
    jmp 9f
1:  cmp eax, OA_FLAGS           # a choice the user made (claude_session.s)
    jb 2f
    cmp eax, OA_FLAGS_END
    ja 2f
    lea edx, [rax - OA_FLAGS]
    mov rdi, rbx
    mov rsi, r12
    mov rcx, r15                # (the request: the pick it settles)
    call claude_flags_answer
    jmp 9f
2:  xor edx, edx                # set_permission_mode: the mode it answers is in effect (no status line
    cmp eax, OA_MODE            #   comes when it was already: finding 10); a refused pick says why
    je 21f
    mov edx, 1
    cmp eax, OA_PICK
    jne 22f
21: mov rdi, rbx
    mov rsi, r12
    call claude_mode_answer
    jmp 9f
22: cmp eax, OA_INIT
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
    jnz 11f
    xor eax, eax                # none reported: a pick is still asked for
11: mov rdi, rbx                # a mode picked while it started is asked for below (claude_session.s)
    mov rsi, rax
    call claude_init_mode
    test rax, rax
    jz 1f
    mov rdi, rbx
    mov rsi, rax
    call ev_mode
1:  mov rdi, r12                # its lists, version and fast mode (claude_session.s)
    lea rsi, [rip + .Lk_response]
    call json_get
    mov rdi, rbx
    mov rsi, rax
    call claude_init_answer
    mov rdi, rbx                # then what is in effect; a write that broke has ended the start
    call send_get_settings
    cmp dword ptr [rbx + AL_cn + CN_state], CN_UP
    jne 9f
    mov rdi, rbx                # the mode picked while it started (default first after a start in bypass
    call claude_init_ask        #   without rhun's gate), before any prompt goes
    cmp dword ptr [rbx + AL_cn + CN_state], CN_UP
    jne 9f
    mov rdi, rbx                # the prompts wait for get_settings' answer: the kept choices go first
    call claude_prompts_wait    #   (claude_settings_answer, or the bound: claude_settings_tick)
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

# FN cl_apply(AL*, kind CLF_*, key cstr, value cstr or 0, r8d bool when it is 0) -> eax 1 written:
#   apply_flag_settings {"settings":{KEY:VALUE}} (this process only, finding 13; its answer:
#   claude_flags_answer)
FN cl_apply
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    mov r13, rcx
    mov r14d, r8d
    add esi, OA_FLAGS
    call req_begin
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_subtype]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_apply_flags]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_settings]
    call jw_key
    lea rdi, [rip + cw]
    call jw_obj
    lea rdi, [rip + cw]
    mov rsi, r12
    call jw_key
    lea rdi, [rip + cw]
    test r13, r13
    jz 1f
    mov rsi, r13
    call jw_cstr
    jmp 2f
1:  mov esi, r14d
    call jw_bool
2:  lea rdi, [rip + cw]
    call jw_end_obj
    mov rdi, rbx
    call req_end
    EPILOGUE

# FN cl_thinking(AL*, on, summaries) -> eax 1 written: set_max_thinking_tokens {max_thinking_tokens 31999,
#   thinking_display "summarized" or null} or {max_thinking_tokens 0} (finding 14)
FN cl_thinking
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov esi, OA_FLAGS_END
    call req_begin
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_subtype]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_set_thinking]
    call jw_cstr
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_max_thinking]
    call jw_key
    lea rdi, [rip + cw]
    xor esi, esi
    test r12d, r12d
    jz 1f
    mov esi, 31999
1:  call jw_u64
    test r12d, r12d
    jz 3f
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_thinking_display]
    call jw_key
    lea rdi, [rip + cw]
    test r13d, r13d
    jz 2f
    lea rsi, [rip + .Lv_summarized]
    call jw_cstr
    jmp 3f
2:  call jw_null
3:  mov rdi, rbx
    call req_end
    EPILOGUE

# FN claude_get_settings(AL*): get_settings again (after a choice was applied)
FN claude_get_settings
    jmp send_get_settings

# send_get_settings(AL*): get_settings (its answer: claude_settings_answer)
send_get_settings:
    PROLOGUE
    mov rbx, rdi
    mov esi, OA_SETTINGS
    call req_begin
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lk_subtype]
    call jw_key
    lea rdi, [rip + cw]
    lea rsi, [rip + .Lv_get_settings]
    call jw_cstr
    mov rdi, rbx
    call req_end
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

# cl_task(AL*, AGK_*, id cstr) -> eax 0: DRV_task; nothing is asked yet (phase 3 task 11 sends stop_task and
#   the background request)
cl_task:
    xor eax, eax
    ret

.section .rodata
.p2align 3
.globl claude_drv
claude_drv:
    .long AG_CLAUDE, DRVC_NEW | DRVC_RESUME | DRVC_FORK | DRVC_TRUST | DRVC_QUEUE | DRVC_MODES | DRVC_MODELS | DRVC_EFFORT | DRVC_THINKING
    .quad .Lname, cl_start, cl_send, cl_stop, cl_answer, cl_release, cl_held, cl_auth, cl_terminal
    .quad claude_modes, claude_set_mode, claude_set_model, claude_set_effort, claude_set_ultra
    .quad claude_set_thinking, claude_reply, claude_action
    .quad claude_menu
    .quad .Lhint                # DRV_hint
    .quad claude_ended          # DRV_ended (claude_session.s)
    .quad 0xffd97757            # DRV_brand: Claude's own colour (the running dot)
    .quad 0                     # DRV_verbs (phase 3 task 5)
    .quad 0                     # DRV_tips (phase 3 task 8)
    .quad cl_task               # DRV_task (phase 3 task 11)
cl_types:
    .quad .Lv_stream_event, h_stream, .Lv_assistant, h_assistant, .Lv_system, h_system
    .quad .Lv_result, h_result, .Lv_control_request, h_request, .Lv_control_response, h_response
    .quad .Lv_user, h_user, .Lv_cancel, h_cancel
    .quad .Lv_lifecycle, claude_lifecycle       # task 3: a message's lifecycle (claude_session.s)
    .quad .Lv_suggestion, h_suggestion          # the prompt Claude suggests next (finding 19)
    .quad .Lv_rate_event, claude_rate           # task 8: the rate-limit band (claude_session.s)
    .quad 0, 0
perm_qs:                        # a permission card's question: the tool, before its summary, after it
    .quad .Lt_bash, .Lq_bash, .Lempty, .Lt_edit, .Lq_edit, .Lq_mark, .Lt_multiedit, .Lq_edit, .Lq_mark
    .quad .Lt_write, .Lq_write, .Lq_mark, .Lt_read, .Lq_read, .Lq_mark, .Lt_webfetch, .Lq_fetch, .Lempty
    .quad 0
opts_yes_no: .quad .Lo_yes, .Lo_no
opts_plan: .quad .Lo_yes, .Lo_keep
cl_flags:
    .quad .La_outf, .La_sj, .La_verbose, .La_inf, .La_sj, .La_partial, .La_ppt, .La_replay, 0
.Lname: .asciz "Claude Code"
.Lhint: .asciz "Ask Claude to edit\xe2\x80\xa6"
.Lv_suggestion: .asciz "prompt_suggestion"
.Lv_rate_event: .asciz "rate_limit_event"
.Lk_suggestion: .asciz "suggestion"
.Lk_ultrathink: .asciz "ultrathink_available"
.Lv_ultrathink: .asciz "ultrathink"
.La_outf: .asciz "--output-format"
.La_inf: .asciz "--input-format"
.La_sj: .asciz "stream-json"
.La_verbose: .asciz "--verbose"
.La_partial: .asciz "--include-partial-messages"
.La_ppt: .asciz "--permission-prompt-tool=stdio"
.La_sources_all: .asciz "--setting-sources=user,project,local"
.La_sources_user: .asciz "--setting-sources=user"
.La_thinking: .asciz "--max-thinking-tokens=31999"
.La_nothink: .asciz "--thinking=disabled"
.La_replay: .asciz "--replay-user-messages"
.La_model: .asciz "--model="
.La_effort: .asciz "--effort="
.La_danger: .asciz "--allow-dangerously-skip-permissions"
.La_sid: .asciz "--session-id="
.La_resume: .asciz "--resume="
.La_fork: .asciz "--fork-session"
.La_auth: .asciz "auth"
.La_status: .asciz "status"
.La_json: .asciz "--json"
.Lk_loggedIn: .asciz "loggedIn"
.Lw_claude: .asciz "claude"
.Lw_projects: .ascii "projects"
.Lw_login: .asciz " auth login"
.Lw_logout: .asciz " auth logout"
.Lsh_plain: .asciz "/._-+~:,@"
# PowerShell, Windows' terminal shell: "," would make an array and "@" splat; "~" and "+" are kept out too
.Lsh_plain_ps: .asciz "/._-:\\"
.Lsh_quote: .asciz "'\\''"
.Lsh_quote_ps: .asciz "''"
.Lsh_call: .asciz "& "
.Lsh_env: .asciz "$env:"
.Lsh_tail: .asciz " "
.Lsh_tail_ps: .asciz "; "
.Lw_config_dir: .asciz "CLAUDE_CONFIG_DIR"
.Lw_home: .asciz "HOME"
.Lr_prompt_busy: .asciz "Close the open prompt first."
.La_w1: .asciz "authentication_error"
.La_w2: .asciz "Please run /login"
.La_w3: .asciz "Not logged in"
.La_w4: .asciz "Invalid API key"
.p2align 3
auth_words: .quad .La_w1, .La_w2, .La_w3, .La_w4, 0
.La_mode: .asciz "--permission-mode="
.Lk_type: .asciz "type"
.Lk_subtype: .asciz "subtype"
.Lk_request_id: .asciz "request_id"
.Lk_request: .asciz "request"
.Lk_response: .asciz "response"
.Lk_hooks: .asciz "hooks"
.Lk_suggestions: .asciz "promptSuggestions"
.Lk_dialog_kinds: .asciz "supportedDialogKinds"
.Lk_task_stop: .asciz "perTaskStopAffordance"
.Lk_nested: .asciz "forwardNestedSubagentToolCalls"
.Lk_timestamp: .asciz "timestamp"
.Lk_uuid: .asciz "uuid"
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
.Lv_get_settings: .asciz "get_settings"
.Lv_apply_flags: .asciz "apply_flag_settings"
.Lk_settings: .asciz "settings"
.Lv_set_thinking: .asciz "set_max_thinking_tokens"
.Lk_max_thinking: .asciz "max_thinking_tokens"
.Lk_thinking_display: .asciz "thinking_display"
.Lv_summarized: .asciz "summarized"
.Lv_commands_changed: .asciz "commands_changed"
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
.Lv_lifecycle: .asciz "command_lifecycle"
.Lv_can_use_tool: .asciz "can_use_tool"
.Lv_tool_use: .asciz "tool_use"
.Lv_tool_result: .asciz "tool_result"
.Lv_set_mode: .asciz "set_permission_mode"
.Lv_get_plan: .asciz "get_plan"            # plan review
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
.Lr_unsent: .asciz "Claude Code is not taking input now: the answer was not sent."
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
