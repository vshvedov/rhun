# Claude Code's SDK hooks in rhun's chat (phase 4 task 10): the extension's three (P 2.2, README finding 48),
# declared in initialize, called back through hook_callback control requests and answered with a control
# response: {"continue":true}, or after an edit with the problems that are new in its file:
# {"continue":true,"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":
# "<ide_diagnostics>JSON</ide_diagnostics>"}} (the extension's answerWith, EXT@3187815).
#   hook_0, PreToolUse Edit|Write|MultiEdit: the file's problems now, kept as its base by (path, session_id,
#     agent_id), at most BASE_MAX a conversation (the oldest goes); answered at once
#   hook_1, PreToolUse Edit|Write|Read: with [agents] autosave, the file's open document saved when it has
#     unsaved changes (rhun's own save: format on save and the save actions run as for Ctrl+S; a read-only
#     document, one whose file changed on disk, one without a file is not saved); the answer waits for the
#     save, at most SAVE_MS
#   hook_2, PostToolUse Edit|Write|MultiEdit (contextOnly): the problems that are new since the base
#     (edtool_diag_new: the extension's areDiagnosticsEqual), after a wait for the editor to check the edit:
#     WAIT_ACTIVE_MS when the file is the active tab, WAIT_OPEN_MS when it is open behind, none when it is not
#     open or no document of its language ever had marks in this window; the wait ends early once the
#     document was seen changed and the problems changed after that
# Finding 48: the CLI sends no deadline and waits as long as a hook takes, so rhun bounds its own waits (the
# values above; agent-timing hooksave= hookwait= for tests). A file outside the project (edtool_in_project) is
# neither saved nor checked; a callback of an unknown id, an input without a file path, any failure: answered
# {"continue":true} at once. A waiting answer belongs to its live record and dies with its process
# (claude_hooks_gone: cl_close, claude_ended, cl_start): it is never written to a later process. Stop answers
# the waiting ones at once (claude_hooks_flush); a control_cancel_request drops one unanswered.
# The answer with problems also makes the conversation's diagnostics row (claude_diag_row): the stream never
# carries the context (finding 48); the file's attachment line makes the same row when it is read again.
#
#   claude_hooks_init(sb)               "hooks":{...} into the open initialize request
#   claude_hook(AL*, record, request) -> eax 1          a hook_callback (h_request)
#   claude_hooks_cancel(AL*, record) -> eax 1           a control_cancel_request that named a waiting one
#   claude_hooks_gone(AL*), claude_hooks_flush(AL*)
#   claude_hooks_tick(), claude_hooks_timeout() -> eax ms or -1
#   print-agent-hooks (claude_mcp.s's table)
.include "rhun.inc"

.equ HW_MAX, 64                 # answers waiting, in all
.equ BS_MAX, 256                # bases kept, in all
.equ BASE_MAX, 64               # bases a conversation keeps
.equ SAVE_MS, 120000            # a save is waited for at most (the extension's)
.equ WAIT_ACTIVE_MS, 1500       # new problems are waited for at most: the file the active tab
.equ WAIT_OPEN_MS, 1000         #   open behind
.equ POLL_MS, 50                # a save is asked about again
.equ HWK_SAVE, 1
.equ HWK_PROBLEMS, 2
.equ PATH_MAX_HOOK, 4096

# HW: an answer that waits
STRUCT
F HW_al, 8              # its live record (0: a free slot)
F HW_id, 8              # owned cstr: the request's id as JSON text
F HW_path, 8            # owned cstr
F HW_until, 8           # time_ms: answered then at the latest
F HW_base, 8            # problems: the owned base, or 0
F HW_tuid, 8            # problems: owned tool_use_id, or 0
F HW_seen, 8            # problems: edtool_doc_seen of the base (or of the call)
F HW_gen, 8             # problems: edtool_diag_gen when the document was seen changed
F HW_kind, 4            # HWK_*
F HW_changed, 4         # problems: the document was seen changed
ENDSTRUCT HW_SIZE
# BS: a kept base
STRUCT
F BS_al, 8              # its live record (0: a free slot)
F BS_key, 8             # owned cstr: PATH, a line feed, session_id, a space, agent_id
F BS_base, 8            # owned base (edtool_diag_base)
F BS_seen, 8            # edtool_doc_seen then
F BS_age, 8             # when it was kept (a counter): the oldest goes
ENDSTRUCT BS_SIZE

.data
.p2align 2
.globl g_hook_save_ms, g_hook_wait_ms
g_hook_save_ms: .long SAVE_MS   # agent-timing hooksave=
g_hook_wait_ms: .long 0         # agent-timing hookwait=: that bound for every wait, 0 the rule above

.bss
.p2align 3
hws: .zero HW_SIZE * HW_MAX
bss_: .zero BS_SIZE * BS_MAX
age: .quad 0
nwait: .quad 0
answered: .quad 0               # answers written (print-agent-hooks)
contexts: .quad 0               # of them with problems
hpath: .zero PATH_MAX_HOOK + 8  # the hook's file
kb: .zero SB_SIZE               # a base's key
hb: .zero SB_SIZE               # an answer
cb: .zero SB_SIZE               # the problems' JSON
ib: .zero SB_SIZE               # a request's id as JSON text
one: .zero HW_SIZE              # a waiting answer taken out of its slot to be written

.text

# FN claude_hooks_init(sb): "hooks":{...}, the extension's member (P 2.2; finding 48)
FN claude_hooks_init
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_hooks]
    call jw_key
    mov rdi, rbx
    lea rsi, [rip + .Lv_hooks]
    call jw_raw
    EPILOGUE

# FN claude_hook(AL*, record, request) -> eax 1: a hook_callback answered now or kept to be answered (the
#   conversation's checkout counts as the project's while it is: edtool_set_base)
FN claude_hook
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    call set_base
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call hook_body
    mov ebx, eax
    xor edi, edi
    call edtool_set_base
    mov eax, ebx
    EPILOGUE

# set_base(AL*): edtool_set_base with its conversation's checkout, else the project
set_base:
    mov rax, [rdi + AL_as]
    mov rdi, [rax + AS_cwd]
    test rdi, rdi
    jnz 1f
    mov rdi, [rip + g_project]
1:  jmp edtool_set_base

hook_body:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + ib]         # the id, as it came
    call jw_begin
    mov rdi, r12
    lea rsi, [rip + .Lk_request_id]
    call json_get
    lea rdi, [rip + ib]
    mov rsi, rax
    call jw_jv
    mov rdi, r13
    lea rsi, [rip + .Lk_input]
    call json_get
    mov r14, rax                # input
    mov rdi, rbx                # the file
    mov rsi, r14
    call hook_path
    test rax, rax
    jz .Lhk_continue
    mov rdi, r13
    lea rsi, [rip + .Lk_callback]
    call json_get
    mov r15, rax
    mov rdi, r15
    lea rsi, [rip + .Lv_hook0]
    call json_is
    test eax, eax
    jnz .Lhk_base
    mov rdi, r15
    lea rsi, [rip + .Lv_hook1]
    call json_is
    test eax, eax
    jnz .Lhk_save
    mov rdi, r15
    lea rsi, [rip + .Lv_hook2]
    call json_is
    test eax, eax
    jnz .Lhk_problems
.Lhk_continue:
    mov rdi, rbx
    lea rsi, [rip + ib]
    call answer_continue
    mov eax, 1
    EPILOGUE

.Lhk_base:                      # hook_0: the base, kept
    mov rdi, r14
    call base_key
    lea rdi, [rip + hpath]
    call edtool_diag_base
    test rax, rax
    jz .Lhk_continue            # outside the project
    mov rdi, rbx
    mov rsi, rax
    call base_keep
    jmp .Lhk_continue

.Lhk_save:                      # hook_1: the open document saved first
    cmp dword ptr [rip + cfg_agents_autosave], 0
    je .Lhk_continue
    lea rdi, [rip + hpath]
    call edtool_in_project
    test eax, eax
    jz .Lhk_continue
    lea rdi, [rip + hpath]
    call edtool_save
    cmp eax, EDS_SAVING
    jne .Lhk_continue
    mov rdi, rbx
    mov esi, HWK_SAVE
    call wait_new
    test rax, rax
    jz .Lhk_continue            # too many wait: answered at once
    mov r15, rax
    call time_ms
    mov ecx, [rip + g_hook_save_ms]
    add rax, rcx
    mov [r15 + HW_until], rax
    mov eax, 1
    EPILOGUE

.Lhk_problems:                  # hook_2: what is new since the base, after the editor had its time
    mov rdi, r14
    call base_key
    mov rdi, rbx
    call base_take              # rax base or 0, rdx its seen
    mov [rsp], rax
    mov [rsp + 8], rdx
    lea rdi, [rip + hpath]
    call edtool_in_project
    test eax, eax
    jz .Lhk_drop
    mov rdi, r13                # the call's id, for the row
    lea rsi, [rip + .Lk_tool_use_id]
    call json_get
    mov rdi, rax
    call json_str
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    lea rdi, [rip + hpath]      # the wait
    call wait_ms
    test eax, eax
    jz .Lhk_now
    mov [rsp + 32], eax
    mov rdi, rbx
    mov esi, HWK_PROBLEMS
    call wait_new
    test rax, rax
    jz .Lhk_now
    mov r15, rax
    call time_ms
    mov ecx, [rsp + 32]
    add rax, rcx
    mov [r15 + HW_until], rax
    mov rax, [rsp]
    mov [r15 + HW_base], rax
    mov rax, [rsp + 16]
    mov rdx, [rsp + 24]
    call dup_n
    mov [r15 + HW_tuid], rax
    mov rax, [rsp + 8]          # the document as the base saw it, else as it is now
    cmp qword ptr [rsp], 0
    jne 1f
    lea rdi, [rip + hpath]
    call edtool_doc_seen
1:  mov [r15 + HW_seen], rax
    lea rdi, [rip + hpath]
    call edtool_doc_seen
    cmp rax, [r15 + HW_seen]
    je 2f
    mov dword ptr [r15 + HW_changed], 1
    call edtool_diag_gen
    mov [r15 + HW_gen], rax
2:  mov eax, 1
    EPILOGUE
.Lhk_now:
    mov rdi, rbx
    lea rsi, [rip + ib]
    mov rdx, [rsp]
    lea rcx, [rip + hpath]
    mov r8, [rsp + 16]
    mov r9, [rsp + 24]
    call answer_problems
    mov eax, 1
    EPILOGUE
.Lhk_drop:
    mov rdi, [rsp]
    call edtool_diag_free
    jmp .Lhk_continue

# hook_path(AL*, input) -> rax hpath (input.tool_input.file_path, absolute or under the conversation's
#   checkout), or 0 when there is none
hook_path:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_tool_input]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_file_path]
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jz 8f
    test rdx, rdx
    jz 8f
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d              # bytes written
    PATH_ABSOLUTE r12, 2f
    mov rax, [rbx + AL_as]      # relative: under the checkout, else the project
    mov r15, [rax + AS_cwd]
    test r15, r15
    jnz 1f
    mov r15, [rip + g_project]
    test r15, r15
    jz 8f
1:  mov rdi, r15
    call strlen
    lea rcx, [rax + r13 + 1]
    cmp rcx, PATH_MAX_HOOK
    ja 8f
    mov r14, rax
    lea rdi, [rip + hpath]
    mov rsi, r15
    mov rdx, rax
    call memcpy
    lea rax, [rip + hpath]
    mov byte ptr [rax + r14], '/'
    inc r14
2:  lea rax, [r14 + r13]
    cmp rax, PATH_MAX_HOOK
    ja 8f
    lea rdi, [rip + hpath]
    add rdi, r14
    mov rsi, r12
    mov rdx, r13
    call memcpy
    lea rax, [rip + hpath]
    add r14, r13
    mov byte ptr [rax + r14], 0
    mov rdi, rax                # a NUL inside: none
    call strlen
    cmp rax, r14
    jne 8f
    lea rax, [rip + hpath]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# base_key(input): kb holds "PATH\nSESSION AGENT" (hpath; the input's session_id and agent_id)
base_key:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + kb]
    call sb_clear
    lea rdi, [rip + kb]
    lea rsi, [rip + hpath]
    call sb_push_cstr
    lea rdi, [rip + kb]
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [rip + .Lk_session_id]
    call json_get
    mov rdi, rax
    call json_str
    lea rdi, [rip + kb]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + kb]
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [rip + .Lk_agent_id]
    call json_get
    mov rdi, rax
    call json_str
    lea rdi, [rip + kb]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + kb]
    xor esi, esi
    call sb_push_byte
    EPILOGUE

# base_keep(AL*, base): kept under kb's key (one there before is replaced); the conversation's oldest goes
#   past BASE_MAX, the window's past BS_MAX
base_keep:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    mov rdi, rbx                # the same key: replaced
    call base_find
    test rax, rax
    jz 1f
    mov rdi, rax
    call base_free
1:  xor r12d, r12d              # the conversation's count, its oldest; a free slot
    xor r13d, r13d
    mov r14, -1
    mov r15, -1
    lea rcx, [rip + bss_]
    xor edx, edx
2:  cmp edx, BS_MAX
    jae 4f
    imul rax, rdx, BS_SIZE
    add rax, rcx
    cmp qword ptr [rax + BS_al], 0
    jne 21f
    cmp r15, -1
    jne 3f
    mov r15, rax
    jmp 3f
21: cmp [rax + BS_al], rbx
    jne 3f
    inc r12d
    test r13, r13
    jz 22f
    mov r8, [rax + BS_age]
    cmp r8, [r13 + BS_age]
    jae 3f
22: mov r13, rax
3:  inc edx
    jmp 2b
4:  cmp r12d, BASE_MAX
    jb 5f
    mov rdi, r13                # the conversation's oldest goes
    call base_free
    mov r15, r13
5:  cmp r15, -1
    jne 6f
    lea rdi, [rip + bss_]       # the window's oldest goes
    call oldest_base
    mov r15, rax
    mov rdi, rax
    call base_free
6:  mov [r15 + BS_al], rbx
    mov rax, [rsp]
    mov [r15 + BS_base], rax
    mov rdi, [rip + kb + SB_ptr]
    mov rsi, [rip + kb + SB_len]
    call mem_dup
    mov [r15 + BS_key], rax
    lea rdi, [rip + hpath]
    call edtool_doc_seen
    mov [r15 + BS_seen], rax
    inc qword ptr [rip + age]
    mov rax, [rip + age]
    mov [r15 + BS_age], rax
    EPILOGUE

# oldest_base() -> rax the kept base with the smallest age
oldest_base:
    lea rcx, [rip + bss_]
    mov rax, rcx
    xor edx, edx
1:  inc edx
    cmp edx, BS_MAX
    jae 9f
    imul r8, rdx, BS_SIZE
    add r8, rcx
    mov r9, [r8 + BS_age]
    cmp r9, [rax + BS_age]
    jae 1b
    mov rax, r8
    jmp 1b
9:  ret

# base_find(AL*) -> rax the slot of kb's key for that record, or 0
base_find:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rip + bss_]
    xor r13d, r13d
1:  cmp r13d, BS_MAX
    jae 8f
    imul r14, r13, BS_SIZE
    add r14, r12
    inc r13d
    cmp [r14 + BS_al], rbx
    jne 1b
    mov rdi, [r14 + BS_key]
    mov rsi, [rip + kb + SB_ptr]
    call strcmp_eq
    test eax, eax
    jz 1b
    mov rax, r14
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# base_take(AL*) -> rax the base kept under kb's key (now the caller's) or 0, rdx its edtool_doc_seen
base_take:
    PROLOGUE
    call base_find
    test rax, rax
    jz 8f
    mov rbx, rax
    mov r12, [rbx + BS_base]
    mov r13, [rbx + BS_seen]
    mov qword ptr [rbx + BS_base], 0
    mov rdi, rbx
    call base_free
    mov rax, r12
    mov rdx, r13
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# base_free(BS*): its base and key go, the slot is free
base_free:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + BS_base]
    call edtool_diag_free
    mov rdi, [rbx + BS_key]
    call mem_free
    mov rdi, rbx
    xor esi, esi
    mov edx, BS_SIZE
    call memset
    EPILOGUE

# wait_ms(path) -> eax how long new problems are waited for (0: not at all)
wait_ms:
    PROLOGUE
    mov rbx, rdi
    call edtool_doc_where
    test eax, eax
    jz 8f
    mov r12d, WAIT_OPEN_MS
    cmp eax, 2
    jne 1f
    mov r12d, WAIT_ACTIVE_MS
1:  mov rdi, rbx
    call edtool_lang_marked
    test eax, eax
    jz 8f
    mov eax, [rip + g_hook_wait_ms]
    test eax, eax
    jnz 9f
    mov eax, r12d
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE

# wait_new(AL*, HWK_*) -> rax a waiting answer (the id from ib, the path from hpath), or 0 when HW_MAX wait
wait_new:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    lea r13, [rip + hws]
    xor ecx, ecx
1:  cmp ecx, HW_MAX
    jae 8f
    cmp qword ptr [r13 + HW_al], 0
    je 2f
    add r13, HW_SIZE
    inc ecx
    jmp 1b
2:  mov rdi, r13
    xor esi, esi
    mov edx, HW_SIZE
    call memset
    mov [r13 + HW_al], rbx
    mov [r13 + HW_kind], r12d
    mov rdi, [rip + ib + SB_ptr]
    mov rsi, [rip + ib + SB_len]
    call mem_dup
    mov [r13 + HW_id], rax
    lea rdi, [rip + hpath]
    call strlen
    mov rsi, rax
    lea rdi, [rip + hpath]
    call mem_dup
    mov [r13 + HW_path], rax
    inc qword ptr [rip + nwait]
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# dup_n(rax ptr, rdx len) -> rax an owned copy, or 0 for none
dup_n:
    test rax, rax
    jz 9f
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    jmp mem_dup
8:  xor eax, eax
9:  ret

# wait_free(HW*): what it owns goes, the slot is free (no answer)
wait_free:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + HW_id]
    call mem_free
    mov rdi, [rbx + HW_path]
    call mem_free
    mov rdi, [rbx + HW_base]
    call edtool_diag_free
    mov rdi, [rbx + HW_tuid]
    call mem_free
    mov rdi, rbx
    xor esi, esi
    mov edx, HW_SIZE
    call memset
    dec qword ptr [rip + nwait]
    EPILOGUE

# answer_continue(AL*, id sb): {"continue":true}
answer_continue:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    inc qword ptr [rip + answered]
    mov rdi, rbx
    mov rsi, [r12 + SB_ptr]
    mov rdx, [r12 + SB_len]
    lea rcx, [rip + .Lv_continue]
    mov r8d, .Lv_continue_end - .Lv_continue
    call claude_ok_reply
    EPILOGUE

# answer_problems(AL*, id sb, base or 0 (freed), path cstr, tool_use_id ptr or 0, len): {"continue":true}, or
#   with the new problems as the context; those make the conversation's diagnostics row first
answer_problems:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], r8
    mov [rsp + 8], r9
    mov r13, rcx
    mov [rsp + 24], rdx
    mov rax, [rbx + AL_as]      # the conversation outlives the write
    mov [rsp + 16], rax
    lea rdi, [rip + cb]
    call sb_clear
    mov rdi, [rsp + 24]
    mov rsi, r13
    lea rdx, [rip + cb]
    call edtool_diag_new
    test eax, eax
    jz 7f
    inc qword ptr [rip + contexts]
    lea rdi, [rip + hb]         # {"continue":true,"hookSpecificOutput":{"hookEventName":"PostToolUse",
    call jw_begin               #   "additionalContext":"<ide_diagnostics>JSON</ide_diagnostics>"}}
    lea rdi, [rip + hb]
    call jw_obj
    lea rdi, [rip + hb]
    lea rsi, [rip + .Lk_continue]
    call jw_key
    lea rdi, [rip + hb]
    mov esi, 1
    call jw_bool
    lea rdi, [rip + hb]
    lea rsi, [rip + .Lk_specific]
    call jw_key
    lea rdi, [rip + hb]
    call jw_obj
    lea rdi, [rip + hb]
    lea rsi, [rip + .Lk_event]
    call jw_key
    lea rdi, [rip + hb]
    lea rsi, [rip + .Lv_post]
    call jw_cstr
    lea rdi, [rip + hb]
    lea rsi, [rip + .Lk_context]
    call jw_key
    lea rdi, [rip + kb]         # the context's text
    call sb_clear
    lea rdi, [rip + kb]
    lea rsi, [rip + .Lv_open_tag]
    call sb_push_cstr
    lea rdi, [rip + kb]
    mov rsi, [rip + cb + SB_ptr]
    mov rdx, [rip + cb + SB_len]
    call sb_push
    lea rdi, [rip + kb]
    lea rsi, [rip + .Lv_close_tag]
    call sb_push_cstr
    lea rdi, [rip + hb]
    mov rsi, [rip + kb + SB_ptr]
    mov rdx, [rip + kb + SB_len]
    call jw_str
    lea rdi, [rip + hb]
    call jw_end_obj
    lea rdi, [rip + hb]
    call jw_end_obj
    mov rax, [rsp]              # the row, made from rhun's own answer (the stream never carries it)
    test rax, rax
    jz 6f
    mov rdi, [rsp + 16]
    mov rsi, rax
    mov rdx, [rsp + 8]
    mov rcx, [rip + cb + SB_ptr]
    mov r8, [rip + cb + SB_len]
    call claude_diag_row
6:  inc qword ptr [rip + answered]
    mov rdi, rbx
    mov rsi, [r12 + SB_ptr]
    mov rdx, [r12 + SB_len]
    mov rcx, [rip + hb + SB_ptr]
    mov r8, [rip + hb + SB_len]
    call claude_ok_reply
    EPILOGUE
7:  mov rdi, rbx
    mov rsi, r12
    call answer_continue
    EPILOGUE

# take_one(HW*): its fields copied into `one` and the slot freed (the strings and the base now `one`'s)
take_one:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + one]
    mov rsi, rbx
    mov edx, HW_SIZE
    call memcpy
    mov rdi, rbx
    xor esi, esi
    mov edx, HW_SIZE
    call memset
    dec qword ptr [rip + nwait]
    EPILOGUE

# answer_one(): `one` answered (a save: continue; problems: what is new now), then its strings freed
answer_one:
    PROLOGUE
    lea rbx, [rip + one]
    lea rdi, [rip + ib]         # its id
    call sb_clear
    lea rdi, [rip + ib]
    mov rsi, [rbx + HW_id]
    call sb_push_cstr
    cmp dword ptr [rbx + HW_kind], HWK_PROBLEMS
    je 1f
    mov rdi, [rbx + HW_al]
    lea rsi, [rip + ib]
    call answer_continue
    jmp 8f
1:  mov r12, [rbx + HW_tuid]
    xor r13d, r13d
    test r12, r12
    jz 2f
    mov rdi, r12
    call strlen
    mov r13, rax
2:  mov rdi, [rbx + HW_al]
    lea rsi, [rip + ib]
    mov rdx, [rbx + HW_base]
    mov rcx, [rbx + HW_path]
    mov r8, r12
    mov r9, r13
    mov qword ptr [rbx + HW_base], 0    # freed by edtool_diag_new
    call answer_problems
8:  lea rbx, [rip + one]
    mov rdi, [rbx + HW_id]
    call mem_free
    mov rdi, [rbx + HW_path]
    call mem_free
    mov rdi, [rbx + HW_tuid]
    call mem_free
    mov rdi, [rbx + HW_base]
    call edtool_diag_free
    lea rdi, [rip + one]
    xor esi, esi
    mov edx, HW_SIZE
    call memset
    EPILOGUE

# due(HW*, now) -> eax 1 when it is to be answered now
due:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, [rbx + HW_until]
    jge 7f
    cmp dword ptr [rbx + HW_kind], HWK_SAVE
    jne 1f
    mov rdi, [rbx + HW_path]
    call edtool_saved
    cmp eax, EDS_SAVING
    jne 7f
    jmp 8f
1:  cmp dword ptr [rbx + HW_changed], 0
    jne 2f
    mov rdi, [rbx + HW_path]
    call edtool_doc_seen
    cmp rax, [rbx + HW_seen]
    je 8f
    mov dword ptr [rbx + HW_changed], 1
    call edtool_diag_gen
    mov [rbx + HW_gen], rax
    jmp 8f
2:  call edtool_diag_gen
    cmp rax, [rbx + HW_gen]
    jne 7f
8:  xor eax, eax
    EPILOGUE
7:  mov eax, 1
    EPILOGUE

# FN claude_hooks_tick(): the answers that are due are written, one at a time (each write may change the
#   table)
FN claude_hooks_tick
    PROLOGUE
    cmp qword ptr [rip + nwait], 0
    je 9f
1:  call time_ms
    mov r12, rax
    lea rbx, [rip + hws]
    xor r13d, r13d
2:  cmp r13d, HW_MAX
    jae 9f
    cmp qword ptr [rbx + HW_al], 0
    je 3f
    mov rdi, [rbx + HW_al]
    call set_base
    mov rdi, rbx
    mov rsi, r12
    call due
    test eax, eax
    jz 3f
    mov rdi, rbx
    call take_one
    call answer_one
    xor edi, edi
    call edtool_set_base
    jmp 1b
3:  add rbx, HW_SIZE
    inc r13d
    jmp 2b
9:  xor edi, edi
    call edtool_set_base
    EPILOGUE

# FN claude_hooks_timeout() -> eax ms until an answer is due (POLL_MS at most while a save is waited for), or
#   -1 with nothing waiting
FN claude_hooks_timeout
    PROLOGUE
    mov eax, -1
    cmp qword ptr [rip + nwait], 0
    je 9f
    call time_ms
    mov r12, rax
    mov r13, -1
    lea rbx, [rip + hws]
    xor r14d, r14d
1:  cmp r14d, HW_MAX
    jae 5f
    cmp qword ptr [rbx + HW_al], 0
    je 4f
    mov rax, [rbx + HW_until]
    sub rax, r12
    jns 2f
    xor eax, eax
2:  cmp dword ptr [rbx + HW_kind], HWK_SAVE
    jne 3f
    mov ecx, POLL_MS
    cmp rax, rcx
    cmova rax, rcx
3:  cmp r13, -1
    je 31f
    cmp rax, r13
    jae 4f
31: mov r13, rax
4:  add rbx, HW_SIZE
    inc r14d
    jmp 1b
5:  mov rax, r13
9:  EPILOGUE

# FN claude_hooks_gone(AL*): its process is gone (or a new one starts): what waits for it and its bases go,
#   unanswered
FN claude_hooks_gone
    PROLOGUE
    mov r12, rdi
    lea rbx, [rip + hws]
    xor r13d, r13d
1:  cmp r13d, HW_MAX
    jae 2f
    cmp [rbx + HW_al], r12
    jne 11f
    mov rdi, rbx
    call wait_free
11: add rbx, HW_SIZE
    inc r13d
    jmp 1b
2:  lea rbx, [rip + bss_]
    xor r13d, r13d
3:  cmp r13d, BS_MAX
    jae 9f
    cmp [rbx + BS_al], r12
    jne 31f
    mov rdi, rbx
    call base_free
31: add rbx, BS_SIZE
    inc r13d
    jmp 3b
9:  EPILOGUE

# FN claude_hooks_flush(AL*): Stop: what waits for that record is answered now (as the extension's hooks
#   answer {"continue":true} once their signal is aborted)
FN claude_hooks_flush
    PROLOGUE
    mov r12, rdi
1:  lea rbx, [rip + hws]
    xor r13d, r13d
2:  cmp r13d, HW_MAX
    jae 9f
    cmp [rbx + HW_al], r12
    je 3f
    add rbx, HW_SIZE
    inc r13d
    jmp 2b
3:  mov rdi, r12
    call set_base
    mov rdi, rbx
    call take_one
    lea rdi, [rip + one]        # aborted: no context
    mov dword ptr [rdi + HW_kind], HWK_SAVE
    call answer_one
    jmp 1b
9:  xor edi, edi
    call edtool_set_base
    EPILOGUE

# FN claude_hooks_cancel(AL*, record) -> eax 1 when the control_cancel_request named a waiting answer: it
#   goes, unanswered
FN claude_hooks_cancel
    PROLOGUE
    mov r12, rdi
    mov r14, rsi
    lea rdi, [rip + ib]
    call jw_begin
    mov rdi, r14
    lea rsi, [rip + .Lk_request_id]
    call json_get
    lea rdi, [rip + ib]
    mov rsi, rax
    call jw_jv
    lea rbx, [rip + hws]
    xor r13d, r13d
1:  cmp r13d, HW_MAX
    jae 8f
    cmp [rbx + HW_al], r12
    jne 2f
    mov rdi, [rbx + HW_id]
    call strlen
    cmp rax, [rip + ib + SB_len]
    jne 2f
    mov rdi, [rbx + HW_id]
    mov rsi, [rip + ib + SB_ptr]
    mov rdx, rax
    call memeq
    test eax, eax
    jz 2f
    mov rdi, rbx
    call wait_free
    mov eax, 1
    EPILOGUE
2:  add rbx, HW_SIZE
    inc r13d
    jmp 1b
8:  xor eax, eax
    EPILOGUE

# FN claude_hooks_dump(sb): print-agent-hooks: "waiting=N bases=N answered=N contexts=N timeout=MS|-1", then "hook ID
#   kind=save|problems file=PATH left=MS"
FN claude_hooks_dump
    PROLOGUE
    mov r15, rdi
    mov rdi, r15
    lea rsi, [rip + .Lw_waiting]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rip + nwait]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lw_bases]
    call sb_push_cstr
    xor esi, esi
    lea rbx, [rip + bss_]
    xor ecx, ecx
1:  cmp ecx, BS_MAX
    jae 2f
    cmp qword ptr [rbx + BS_al], 0
    je 11f
    inc esi
11: add rbx, BS_SIZE
    inc ecx
    jmp 1b
2:  mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lw_answered]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rip + answered]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lw_contexts]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rip + contexts]
    call sb_push_u64
    mov rdi, r15                # the timer: ms until the next answer is due, -1 none
    lea rsi, [rip + .Lw_timeout]
    call sb_push_cstr
    call claude_hooks_timeout
    test eax, eax
    jns 21f
    mov rdi, r15
    lea rsi, [rip + .Lw_none]
    call sb_push_cstr
    jmp 22f
21: mov rdi, r15
    mov esi, eax
    call sb_push_u64
22: mov rdi, r15
    mov esi, 10
    call sb_push_byte
    call time_ms
    mov r12, rax
    lea rbx, [rip + hws]
    xor r13d, r13d
3:  cmp r13d, HW_MAX
    jae 9f
    cmp qword ptr [rbx + HW_al], 0
    je 4f
    mov rdi, r15
    lea rsi, [rip + .Lw_hook]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + HW_id]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Lw_kind_save]
    cmp dword ptr [rbx + HW_kind], HWK_SAVE
    je 31f
    lea rsi, [rip + .Lw_kind_problems]
31: call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Lw_file]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + HW_path]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Lw_left]
    call sb_push_cstr
    mov rsi, [rbx + HW_until]
    sub rsi, r12
    jns 32f
    xor esi, esi
32: mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
4:  add rbx, HW_SIZE
    inc r13d
    jmp 3b
9:  EPILOGUE

.section .rodata
.Lk_hooks: .asciz "hooks"
.Lv_hooks: .ascii "{\"PreToolUse\":[{\"matcher\":\"Edit|Write|MultiEdit\",\"hookCallbackIds\":[\"hook_0\"]},"
    .ascii "{\"matcher\":\"Edit|Write|Read\",\"hookCallbackIds\":[\"hook_1\"]}],\"PostToolUse\":[{\"matcher\":"
    .asciz "\"Edit|Write|MultiEdit\",\"hookCallbackIds\":[\"hook_2\"],\"contextOnly\":true}]}"
.Lv_continue: .ascii "{\"continue\":true}"
.Lv_continue_end:
.Lk_request_id: .asciz "request_id"
.Lk_input: .asciz "input"
.Lk_callback: .asciz "callback_id"
.Lk_tool_input: .asciz "tool_input"
.Lk_file_path: .asciz "file_path"
.Lk_session_id: .asciz "session_id"
.Lk_agent_id: .asciz "agent_id"
.Lk_tool_use_id: .asciz "tool_use_id"
.Lk_continue: .asciz "continue"
.Lk_specific: .asciz "hookSpecificOutput"
.Lk_event: .asciz "hookEventName"
.Lk_context: .asciz "additionalContext"
.Lv_post: .asciz "PostToolUse"
.Lv_open_tag: .asciz "<ide_diagnostics>"
.Lv_close_tag: .asciz "</ide_diagnostics>"
.Lv_hook0: .asciz "hook_0"
.Lv_hook1: .asciz "hook_1"
.Lv_hook2: .asciz "hook_2"
.Lw_waiting: .asciz "waiting="
.Lw_bases: .asciz " bases="
.Lw_answered: .asciz " answered="
.Lw_contexts: .asciz " contexts="
.Lw_timeout: .asciz " timeout="
.Lw_none: .asciz "-1"
.Lw_hook: .asciz "hook "
.Lw_kind_save: .asciz " kind=save"
.Lw_kind_problems: .asciz " kind=problems"
.Lw_file: .asciz " file="
.Lw_left: .asciz " left="
