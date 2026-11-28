# the extension side of the debugger (docs/extensions/v1.1.md "debug"): feature `debug`. An
# extension starts a session of one of its own debuggers with `ID debug-start NAME_LEN LEN` + NAME +
# a configuration body, within 10 s of one of its commands (a test run's debug profile counts too),
# after the user's one approval per extension and project; it hears `0 debug-ended SESSION CODE`
# when that session is over, and may stop it with `ID debug-stop SESSION`. dap.s makes the session
# (dap_start_ext) and calls the replies here.
.include "rhun.inc"

.equ DBGX_WINDOW_MS, 10000      # debug-start must follow one of the extension's commands this soon
.equ DBGX_SLOTS, 64             # extensions remembered with their last command's time
.equ DBGX_NAME_MAX, 256

.equ RS_START_MS, 5000         # debug-resolve: an idle extension starts within this
.equ RS_ANSWER_MS, 60000        # and answers within this

.bss
.p2align 3
rs_owner: .quad 0               # the launch being resolved: another extension's debug-start
rs_oid: .quad 0                 # and its request id
.p2align 3
rs_gen: .long 0                 # before tasks: the launch a task's end belongs to
rs_pad: .long 0
rs_state: .long 0               # debug-resolve: 0 none, 1 the extension starts, 2 asked
rs_dbg: .long 0                 # the debugger
rs_ext: .quad 0
rs_id: .quad 0
rs_deadline: .quad 0
rs_body: .zero SB_SIZE          # the configuration sent
rs_line: .zero SB_SIZE
rs_keep: .zero SB_SIZE * 3      # before, after, server while the answer is read
rs_task: .zero SB_SIZE          # rs_state 3: the before task that runs
win_ext: .zero 8 * DBGX_SLOTS   # EXT*, 0 free
win_at: .zero 8 * DBGX_SLOTS    # time_ms of its last command
xmsg: .zero SB_SIZE             # a reply or event being built

.text

# dbgx_note_command(EXT*): rhun sent the extension one of its commands (extproto_send_invoke):
#   a debug-start may follow within 10 s, once. Keeps every register but rax, rcx, rdx, rsi, rdi,
#   r8-r11
FN dbgx_note_command
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    call time_ms
    mov r12, rax
    lea rsi, [rip + win_ext]
    lea rdi, [rip + win_at]
    # its own slot, else a free one, else the oldest
    xor ecx, ecx
    mov r8d, -1                 # a free slot
    xor r9d, r9d                # the oldest
1:  cmp ecx, DBGX_SLOTS
    jae 3f
    mov rax, [rsi + rcx*8]
    cmp rax, rbx
    je 5f
    test rax, rax
    jnz 2f
    test r8d, r8d
    jns 2f
    mov r8d, ecx
2:  mov rax, [rdi + rcx*8]
    cmp rax, [rdi + r9*8]
    jae 21f
    mov r9d, ecx
21: inc ecx
    jmp 1b
3:  mov ecx, r8d
    test ecx, ecx
    jns 5f
    mov ecx, r9d
5:  mov [rsi + rcx*8], rbx
    mov [rdi + rcx*8], r12
    add rsp, 8
    pop r12
    pop rbx
    ret

# window_take(EXT*) -> eax 1 when one of its commands ran in the last 10 s (the window is used up)
window_take:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    call time_ms
    mov r12, rax
    lea rsi, [rip + win_ext]
    lea rdi, [rip + win_at]
    xor ecx, ecx
1:  cmp ecx, DBGX_SLOTS
    jae 8f
    cmp [rsi + rcx*8], rbx
    je 2f
    inc ecx
    jmp 1b
2:  mov qword ptr [rsi + rcx*8], 0
    mov rax, r12
    sub rax, [rdi + rcx*8]
    cmp rax, DBGX_WINDOW_MS
    ja 8f
    mov eax, 1
    jmp 9f
8:  xor eax, eax
9:  add rsp, 8
    pop r12
    pop rbx
    ret

# dbgx_h_debug_start(): ID debug-start NAME_LEN LEN + NAME + configuration body (extproto.s's verb
#   table). ok ID SESSION comes from launch_now; errors here: unknown (feature not agreed), needs,
#   syntax, refused (no recent command of its own, or a type not its own), busy, toobig
FN dbgx_h_debug_start
    PROLOGUE 16
    call xp_cur
    mov rbx, rax
    call xp_cur_id
    mov r12, rax
    FEAT_TEST rbx, FEAT_DEBUG
    jnz 1f
    mov rdi, r12
    lea rsi, [rip + .Le_unknown]
    call xp_reply_error
    EPILOGUE
1:  mov edi, NEEDS_DEBUG
    call xp_need
    test eax, eax
    jz 9f
    # a launch being prepared (its extension, its before task) keeps its configuration in g_lc_*:
    #   nothing is parsed meanwhile
    call dbgx_resolving
    test eax, eax
    jz 10f
    mov rdi, r12
    lea rsi, [rip + .Le_preparing]
    call xp_reply_error
    EPILOGUE
10: call xp_nfields
    cmp rax, 4
    jne .Lds_syntax
    mov edi, 2
    call xp_field_u64
    test edx, edx
    jz .Lds_syntax
    mov r13, rax                # NAME_LEN
    test r13, r13
    jz .Lds_syntax
    cmp r13, DBGX_NAME_MAX
    ja .Lds_syntax
    call xp_body
    mov r14, rax
    mov r15, rdx
    cmp r15, r13
    jb .Lds_syntax
    # the configuration
    mov rdi, r14
    mov rsi, r13
    lea rdx, [r14 + r13]
    mov rcx, r15
    sub rcx, r13
    mov r8, rbx
    call dcfg_from_leaves
    test eax, eax
    jnz 2f
    cmp dword ptr [rip + g_dcfg_code], DCE_MISSING
    jne 11f
    lea rdi, [rip + g_dcfg_err] # the user hears what to install; the extension, that it is missing
    call app_toast
    mov rdi, r12
    lea rsi, [rip + .Le_missing]
    call xp_reply_error
    EPILOGUE
11: cmp dword ptr [rip + g_dcfg_code], DCE_REFUSED
    jne .Lds_syntax
    mov rdi, r12
    lea rsi, [rip + .Le_type]
    call xp_reply_error
    EPILOGUE
2:  # one session per command it ran in the last 10 s (or per debug-profile test run)
    mov rdi, rbx
    call window_take
    test eax, eax
    jnz 3f
    mov rdi, rbx
    call testproto_debug_window # a queued or running debug-profile test run (testing group)
    test eax, eax
    jnz 3f
    mov rdi, r12
    lea rsi, [rip + .Le_window]
    call xp_reply_error
    EPILOGUE
3:  call dap_live_count
    cmp eax, DS_MAX
    jb 4f
    mov rdi, r12
    lea rsi, [rip + .Le_toobig]
    call xp_reply_error
    EPILOGUE
4:  mov qword ptr [rip + g_dstart_msg], 0
    mov rdi, rbx
    mov rsi, r12
    call dap_start_ext
    test eax, eax
    jnz 9f                      # answered by launch_now or ds_end
    mov rsi, [rip + g_dstart_msg]
    test rsi, rsi
    jz 9f                       # a session was made and ended at once: ds_end answered
    mov rdi, rbx
    mov rdx, rsi
    mov rsi, r12
    call dbgx_reply_failed
9:  EPILOGUE
.Lds_syntax:
    mov rdi, r12
    call xp_reply_syntax
    EPILOGUE

# dbgx_h_debug_stop(): ID debug-stop SESSION: Stop (as the toolbar's) on a session this extension
#   started. ok ID at once; debug-ended follows when the session is over (one already over is ok
#   too). Errors: unknown, needs, syntax, refused (not a session it started)
FN dbgx_h_debug_stop
    PROLOGUE
    call xp_cur
    mov rbx, rax
    call xp_cur_id
    mov r12, rax
    FEAT_TEST rbx, FEAT_DEBUG
    jnz 1f
    mov rdi, r12
    lea rsi, [rip + .Le_unknown_stop]
    call xp_reply_error
    EPILOGUE
1:  mov edi, NEEDS_DEBUG
    call xp_need
    test eax, eax
    jz 9f
    call xp_nfields
    cmp rax, 3
    jne .Lsp_syntax
    mov edi, 2
    call xp_field_u64
    test edx, edx
    jz .Lsp_syntax
    mov rcx, rax
    shr rcx, 31
    jnz .Lsp_not_yours
    mov edi, eax
    call dap_slot_of_id
    test rax, rax
    jz .Lsp_not_yours
    cmp [rax + DS_owner], rbx
    jne .Lsp_not_yours
    mov r13, rax
    mov rdi, r12
    call xp_reply_ok
    mov rdi, r13
    call dap_stop_session
    EPILOGUE
.Lsp_not_yours:
    mov rdi, r12
    lea rsi, [rip + .Le_not_yours]
    call xp_reply_error
9:  EPILOGUE
.Lsp_syntax:
    mov rdi, r12
    call xp_reply_syntax
    EPILOGUE

# ---------------- debug-resolve ----------------

# dbgx_resolve_begin(EXT*, debugger index) -> eax 1 when the extension is being asked (the launch
#   continues in dap_start_resolved), 0 with g_dstart_msg: dap_start's debugger says resolve = yes.
#   `ID debug-resolve TYPE REQUEST NODEBUG LEN` + the configuration (variables and types applied)
#   and a context record; an idle extension is started first (5 s for its hello)
FN dbgx_resolve_begin
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov [rip + rs_ext], rbx
    mov [rip + rs_dbg], r12d
    # the body: the leaves, then context DOC LINE COL LEN + the active document's path
    lea rdi, [rip + rs_body]
    call sb_clear
    lea rdi, [rip + rs_body]
    call dcfg_leaves
    lea rdi, [rip + rs_body]
    lea rsi, [rip + .Lr_context]
    call sb_push_cstr
    mov r13, [rip + g_doc]
    test r13, r13
    jz 1f
    lea rdi, [rip + rs_body]
    mov rsi, [r13 + DOC_id]
    call sb_push_u64
    lea rdi, [rip + rs_body]
    mov esi, ' '
    call sb_push_byte
    mov rdi, r13
    mov rsi, [r13 + DOC_cur]
    call doc_line_of
    mov r14, rax
    lea rdi, [rip + rs_body]
    lea rsi, [rax + 1]
    call sb_push_u64
    lea rdi, [rip + rs_body]
    mov esi, ' '
    call sb_push_byte
    mov rdi, r13
    mov rsi, r14
    call doc_line_start
    mov rsi, [r13 + DOC_cur]
    sub rsi, rax
    inc rsi
    lea rdi, [rip + rs_body]
    call sb_push_u64
    lea rdi, [rip + rs_body]
    mov esi, ' '
    call sb_push_byte
    xor r14d, r14d
    mov r15, [r13 + DOC_path]
    test r15, r15
    jz 11f
    mov rdi, r15
    call strlen
    mov r14, rax
11: lea rdi, [rip + rs_body]
    mov rsi, r14
    call sb_push_u64
    lea rdi, [rip + rs_body]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + rs_body]
    mov rsi, r15
    mov rdx, r14
    call sb_push
    jmp 2f
1:  lea rdi, [rip + rs_body]
    lea rsi, [rip + .Lr_nodoc]
    call sb_push_cstr
2:  # the console says what waits
    mov edi, 0
    mov esi, DCON_INFO
    lea rdx, [rip + .Lm_preparing]
    mov ecx, .Lm_preparing_end - .Lm_preparing
    call dcon_line
    mov eax, [rbx + EXT_status]
    cmp eax, ES_RUNNING
    je 5f
    cmp eax, ES_STARTING
    je 4f
    mov rdi, rbx
    call ext_start
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    je 5f
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    jne .Lrb_nostart
4:  mov dword ptr [rip + rs_state], 1
    call time_ms
    add rax, RS_START_MS
    mov [rip + rs_deadline], rax
    mov eax, 1
    EPILOGUE
5:  call rs_send
    EPILOGUE
.Lrb_nostart:
    lea rax, [rip + .Lm_nostart]
    mov [rip + g_dstart_msg], rax
    xor eax, eax
    EPILOGUE

# rs_send() -> eax 1 asked, 0 with g_dstart_msg (and the console says it when called from the tick)
rs_send:
    PROLOGUE
    mov rbx, [rip + rs_ext]
    FEAT_TEST rbx, FEAT_DEBUG
    jz .Lrs_feat
    lea rdi, [rip + rs_line]
    lea rsi, [rip + .Lr_verb]
    call sb_set_cstr_x
    mov edi, [rip + rs_dbg]
    call dbg_row
    mov rsi, [rax + DBG_type]
    lea rdi, [rip + rs_line]
    call sb_push_cstr
    lea rsi, [rip + .Lr_launch]
    cmp dword ptr [rip + g_lc_request], 0
    je 1f
    lea rsi, [rip + .Lr_attach]
1:  lea rdi, [rip + rs_line]
    call sb_push_cstr
    lea rdi, [rip + rs_line]
    mov esi, [rip + g_lc_nodebug]
    call sb_push_u64
    lea rdi, [rip + rs_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rs_line]
    mov rsi, [rip + rs_body + SB_len]
    call sb_push_u64
    mov rdi, rbx
    xor esi, esi
    mov rdx, [rip + rs_line + SB_ptr]
    mov rcx, [rip + rs_line + SB_len]
    mov r8, [rip + rs_body + SB_ptr]
    mov r9, [rip + rs_body + SB_len]
    call extproto_host_send_body
    test rax, rax
    jz .Lrs_unsent
    mov [rip + rs_id], rax
    mov rdi, rbx                # counted on the Extensions page (query.s)
    mov rsi, rax
    mov edx, PK_DEBUG_RESOLVE
    xor ecx, ecx
    call query_track
    mov dword ptr [rip + rs_state], 2
    call time_ms
    add rax, RS_ANSWER_MS
    mov [rip + rs_deadline], rax
    mov eax, 1
    EPILOGUE
.Lrs_feat:
    lea rax, [rip + .Lm_feat]
    jmp 9f
.Lrs_unsent:
    lea rax, [rip + .Lm_unsent]
9:  mov [rip + g_dstart_msg], rax
    mov dword ptr [rip + rs_state], 0
    xor eax, eax
    EPILOGUE

# rs_fail(cstr): the launch is abandoned with that reason (console and toast)
rs_fail:
    push rbx
    mov rbx, rdi
    mov dword ptr [rip + rs_state], 0
    call rs_owner_fail
    mov rdi, rbx
    call dap_error
    pop rbx
    ret

# dbgx_resolve_owner(EXT* or 0, request id): the launch being resolved is that extension's
#   debug-start (another extension's debugger): its answer waits for the launch
FN dbgx_resolve_owner
    mov [rip + rs_owner], rdi
    mov [rip + rs_oid], rsi
    ret

# dbgx_take_owner() -> rax EXT* or 0, rdx request id: the resolved launch's waiting debug-start
FN dbgx_take_owner
    mov rax, [rip + rs_owner]
    mov rdx, [rip + rs_oid]
    mov qword ptr [rip + rs_owner], 0
    mov qword ptr [rip + rs_oid], 0
    ret

# rs_owner_fail(reason cstr): the waiting debug-start, if any, hears that the launch did not happen
rs_owner_fail:
    PROLOGUE
    mov rdx, rdi
    mov rdi, [rip + rs_owner]
    test rdi, rdi
    jz 9f
    mov rsi, [rip + rs_oid]
    mov qword ptr [rip + rs_owner], 0
    mov qword ptr [rip + rs_oid], 0
    call dbgx_reply_failed
9:  EPILOGUE

# dbgx_before_begin(task name cstr) -> eax 1 when launch.ini's before task started (the launch goes
#   on in dap_start_after_before once it exits 0), 0 with g_dstart_msg
FN dbgx_before_begin
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + rs_line]
    lea rsi, [rip + .Lm_before]
    call sb_set_cstr_x
    lea rdi, [rip + rs_line]
    mov rsi, rbx
    call sb_push_cstr
    xor edi, edi
    mov esi, DCON_INFO
    mov rdx, [rip + rs_line + SB_ptr]
    mov rcx, [rip + rs_line + SB_len]
    call dcon_line
    lea rdi, [rip + rs_task]
    mov rsi, rbx
    call sb_set_cstr_x
    mov dword ptr [rip + rs_state], 3
    inc dword ptr [rip + rs_gen]
    mov rdi, rbx
    lea rsi, [rip + before_done]
    mov edx, [rip + rs_gen]     # its end is ignored once this launch is abandoned
    call tasks_run_named
    test eax, eax
    jz 8f
    mov dword ptr [rip + rs_state], 0
    lea rcx, [rip + .Lm_notask]
    cmp eax, -1
    je 1f
    lea rcx, [rip + .Lm_taskbusy]
1:  mov [rip + g_dstart_msg], rcx
    xor eax, eax
    EPILOGUE
8:  mov eax, 1
    EPILOGUE

# before_done(launch generation, TASK_DONE | TASK_FAILED): the before task ended
before_done:
    PROLOGUE
    cmp dword ptr [rip + rs_state], 3
    jne 9f                      # Stop abandoned the launch meanwhile
    cmp edi, [rip + rs_gen]
    jne 9f                      # an abandoned launch's task: another launch's runs
    mov dword ptr [rip + rs_state], 0
    cmp esi, TASK_DONE
    jne 1f
    call dap_start_after_before
    EPILOGUE
1:  # it failed: the user decides (Debug Anyway or Cancel), the launch waiting meanwhile
    mov dword ptr [rip + rs_state], 4
    lea rdi, [rip + rs_line]
    mov rsi, [rip + rs_task + SB_ptr]
    mov rdx, [rip + rs_task + SB_len]
    call sb_set_x
    lea rdi, [rip + rs_line]
    lea rsi, [rip + .Lm_anyway_line]
    call sb_push_cstr
    lea rdi, [rip + rs_line]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rip + .Lm_taskfailed_q]
    mov rsi, [rip + rs_line + SB_ptr]
    lea rdx, [rip + .Lm_anyway]
    lea rcx, [rip + before_anyway]
    call app_confirm
    lea rdi, [rip + before_cancel]
    call app_confirm_cancel
9:  EPILOGUE

# before_anyway(): Debug Anyway after a failed before task
before_anyway:
    sub rsp, 8
    cmp dword ptr [rip + rs_state], 4
    jne 1f
    mov dword ptr [rip + rs_state], 0
    call dap_start_after_before
1:  add rsp, 8
    ret

# before_cancel(): Cancel: the launch is abandoned
before_cancel:
    sub rsp, 8
    cmp dword ptr [rip + rs_state], 4
    jne 1f
    mov dword ptr [rip + rs_state], 0
    xor edi, edi
    mov esi, DCON_INFO
    lea rdx, [rip + .Lm_cancelled]
    mov ecx, .Lm_cancelled_end - .Lm_cancelled
    call dcon_line
1:  add rsp, 8
    ret

# dbgx_resolving() -> eax 1 while a launch waits for its extension (dap_start refuses another)
FN dbgx_resolving
    xor eax, eax
    cmp dword ptr [rip + rs_state], 0
    setne al
    ret

# dbgx_resolve_tick(): the start's 5 s, the answer's 60 s, an extension that stopped meanwhile
FN dbgx_resolve_tick
    PROLOGUE
    mov eax, [rip + rs_state]
    test eax, eax
    jz 9f
    mov rbx, [rip + rs_ext]
    call time_ms
    mov r12, rax
    cmp dword ptr [rip + rs_state], 3
    jae 9f                      # the before task and its question have no deadline of rhun's
    cmp dword ptr [rip + rs_state], 1
    jne 3f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 1f
    call rs_send
    test eax, eax
    jnz 9f
    mov rdi, [rip + g_dstart_msg]
    call rs_fail
    EPILOGUE
1:  cmp dword ptr [rbx + EXT_status], ES_STARTING
    jne 2f
    cmp r12, [rip + rs_deadline]
    jb 9f
    lea rdi, [rip + .Lm_nostart]
    call rs_fail
    EPILOGUE
2:  lea rdi, [rip + .Lm_stopped]
    call rs_fail
    EPILOGUE
3:  cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 2b
    cmp r12, [rip + rs_deadline]
    jb 9f
    mov rdi, rbx
    mov rsi, [rip + rs_id]
    call query_withdraw         # 0 cancel ID, counted cancelled
    lea rdi, [rip + .Lm_noanswer]
    call rs_fail
9:  EPILOGUE

# dbgx_resolve_timeout() -> ms until the resolve's deadline, or -1
FN dbgx_resolve_timeout
    sub rsp, 8
    mov rax, -1
    cmp dword ptr [rip + rs_state], 0
    je 9f
    cmp dword ptr [rip + rs_state], 3
    jae 9f
    call time_ms
    mov rcx, [rip + rs_deadline]
    sub rcx, rax
    jns 1f
    xor ecx, ecx
1:  mov rax, rcx
9:  add rsp, 8
    ret

# dbgx_resolve_cancel() -> eax 1 when a launch was waiting: Stop withdraws it (0 cancel ID)
FN dbgx_resolve_cancel
    PROLOGUE
    xor eax, eax
    cmp dword ptr [rip + rs_state], 0
    je 9f
    cmp dword ptr [rip + rs_state], 2
    jne 1f
    mov rdi, [rip + rs_ext]
    mov rsi, [rip + rs_id]
    call query_withdraw
1:  mov dword ptr [rip + rs_state], 0
    xor edi, edi
    mov esi, DCON_INFO
    lea rdx, [rip + .Lm_cancelled]
    mov ecx, .Lm_cancelled_end - .Lm_cancelled
    call dcon_line
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# dbgx_reply(EXT*, id, ok, body or "CODE TEXT", len) -> eax 1 when it answered debug-resolve
#   (extproto.s's answer chain): ok 0 keeps the configuration, ok LEN + body replaces it,
#   error cancelled abandons the launch quietly, any other error abandons it with its text
FN dbgx_reply
    PROLOGUE
    xor eax, eax
    cmp dword ptr [rip + rs_state], 2
    jne 9f
    cmp rdi, [rip + rs_ext]
    jne 9f
    cmp rsi, [rip + rs_id]
    jne 9f
    mov rbx, rdi
    mov r12d, edx
    mov r13, rcx
    mov r14, r8
    mov dword ptr [rip + rs_state], 0
    test r12d, r12d
    jz .Lrr_error
    test r14, r14
    jz .Lrr_go                  # unchanged
    # the resolved configuration replaces it; before, after and server stay launch.ini's
    lea r15, [rip + rs_keep]
    mov rdi, r15
    lea rsi, [rip + g_lc_before]
    call sb_copy_x
    lea rdi, [r15 + SB_SIZE]
    lea rsi, [rip + g_lc_after]
    call sb_copy_x
    lea rdi, [r15 + SB_SIZE * 2]
    lea rsi, [rip + g_lc_server]
    call sb_copy_x
    lea rdi, [rip + rs_line]        # the name, as dcfg_from_leaves copies it over itself
    lea rsi, [rip + g_lc_name]
    call sb_copy_x
    mov rdi, [rip + rs_line + SB_ptr]
    mov rsi, [rip + rs_line + SB_len]
    mov rdx, r13
    mov rcx, r14
    mov r8, rbx
    call dcfg_from_leaves
    mov r12d, eax
    lea rdi, [rip + g_lc_before]
    mov rsi, r15
    call sb_copy_x
    lea rdi, [rip + g_lc_after]
    lea rsi, [r15 + SB_SIZE]
    call sb_copy_x
    lea rdi, [rip + g_lc_server]
    lea rsi, [r15 + SB_SIZE * 2]
    call sb_copy_x
    test r12d, r12d
    jnz .Lrr_go
    lea rdi, [rip + .Lm_badanswer]
    call rs_owner_fail
    lea rdi, [rip + .Lm_badanswer]
    call dap_error
    jmp 8f
.Lrr_go:
    call dap_start_resolved
    jmp 8f
.Lrr_error:
    # cancelled: quietly; refused TEXT: the text; anything else as it came
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lw_cancelled]
    call str_starts_x
    test eax, eax
    jz 1f
    lea rdi, [rip + dap_m_cancelled]
    call rs_owner_fail
    xor edi, edi
    mov esi, DCON_INFO
    lea rdx, [rip + .Lm_cancelled]
    mov ecx, .Lm_cancelled_end - .Lm_cancelled
    call dcon_line
    jmp 8f
1:  mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lw_refused]
    call str_starts_x
    test eax, eax
    jz 2f
    add r13, 8                  # "refused "
    sub r14, 8
2:  lea rdi, [rip + rs_line]
    mov rsi, r13
    mov rdx, r14
    call sb_set_x
    lea rdi, [rip + rs_line]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + rs_line + SB_ptr]
    call rs_owner_fail
    mov rdi, [rip + rs_line + SB_ptr]
    call dap_error
8:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# str_starts_x(ptr, len, cstr) -> eax 1 when the bytes begin with cstr
str_starts_x:
    xor eax, eax
1:  movzx ecx, byte ptr [rdx]
    test ecx, ecx
    jz 2f
    test rsi, rsi
    jz 3f
    cmp cl, [rdi]
    jne 3f
    inc rdi
    inc rdx
    dec rsi
    jmp 1b
2:  mov eax, 1
3:  ret

# sb_copy_x(dst, src): dst holds src's bytes
sb_copy_x:
    mov rdx, [rsi + SB_len]
    mov rsi, [rsi + SB_ptr]
# sb_set_x(sb, ptr, len)
sb_set_x:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    pop r13
    pop r12
    pop rbx
    ret

# dbgx_reply_ok(EXT*, request id, session): ok ID SESSION
FN dbgx_reply_ok
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    call live
    test eax, eax
    jz 9f
    lea rdi, [rip + xmsg]
    lea rsi, [rip + .Lw_ok]
    call sb_set_cstr_x
    lea rdi, [rip + xmsg]
    mov rsi, r12
    call sb_push_u64
    lea rdi, [rip + xmsg]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + xmsg]
    mov esi, r13d
    call sb_push_u64
    call send_line
9:  EPILOGUE

# dbgx_reply_failed(EXT*, request id, reason cstr): error ID cancelled | busy | toobig | refused TEXT
FN dbgx_reply_failed
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call live
    test eax, eax
    jz 9f
    lea rdi, [rip + xmsg]
    lea rsi, [rip + .Lw_error]
    call sb_set_cstr_x
    lea rdi, [rip + xmsg]
    mov rsi, r12
    call sb_push_u64
    lea rsi, [rip + .Le_cancelled]
    lea rax, [rip + dap_m_cancelled]
    cmp r13, rax
    je 1f
    lea rsi, [rip + .Le_busy]
    lea rax, [rip + dap_m_busy]
    cmp r13, rax
    je 1f
    lea rsi, [rip + .Le_toobig_sp]
    lea rax, [rip + dap_m_full]
    cmp r13, rax
    je 1f
    # refused and the reason, on one line
    lea rdi, [rip + xmsg]
    lea rsi, [rip + .Le_refused]
    call sb_push_cstr
    mov r14, r13
2:  movzx esi, byte ptr [r14]
    test esi, esi
    jz 3f
    cmp esi, 10
    jne 21f
    mov esi, ' '
21: lea rdi, [rip + xmsg]
    call sb_push_byte
    inc r14
    jmp 2b
1:  lea rdi, [rip + xmsg]
    call sb_push_cstr
3:  call send_line
9:  EPILOGUE

# dbgx_ended(EXT*, session, exit code or -1): 0 debug-ended SESSION CODE (- when unknown)
FN dbgx_ended
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    call live
    test eax, eax
    jz 9f
    FEAT_TEST rbx, FEAT_DEBUG
    jz 9f
    lea rdi, [rip + xmsg]
    lea rsi, [rip + .Lev_ended]
    call sb_set_cstr_x
    lea rdi, [rip + xmsg]
    mov esi, r12d
    call sb_push_u64
    lea rdi, [rip + xmsg]
    mov esi, ' '
    call sb_push_byte
    test r13d, r13d
    js 1f
    lea rdi, [rip + xmsg]
    mov esi, r13d
    call sb_push_u64
    jmp 2f
1:  lea rdi, [rip + xmsg]
    mov esi, '-'
    call sb_push_byte
2:  call send_line
9:  EPILOGUE

# live() -> eax 1 when rbx's extension still runs (a reply to a stopped one is dropped)
live:
    xor eax, eax
    test rbx, rbx
    jz 1f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 1f
    mov eax, 1
1:  ret

# send_line(): xmsg and a newline to rbx's extension
send_line:
    sub rsp, 8
    lea rdi, [rip + xmsg]
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [rip + xmsg + SB_ptr]
    mov rdx, [rip + xmsg + SB_len]
    call xp_send
    add rsp, 8
    ret

# sb_set_cstr_x(sb, cstr)
sb_set_cstr_x:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    add rsp, 8
    pop r12
    pop rbx
    ret

.section .rodata
.Lr_verb: .asciz "debug-resolve "
.Lr_launch: .asciz " launch "
.Lr_attach: .asciz " attach "
.Lr_context: .asciz "context "
.Lr_nodoc: .asciz "0 0 0 0\n"
.Lw_cancelled: .asciz "cancelled"
.Lw_refused: .asciz "refused "
.Lm_preparing: .ascii "Preparing the launch (the debugger's extension resolves the configuration)"
.Lm_preparing_end:
.Lm_cancelled: .ascii "Launch cancelled"
.Lm_cancelled_end:
.Lm_nostart: .asciz "the debugger's extension did not start in 5 s"
.Lm_stopped: .asciz "the debugger's extension stopped while it prepared the launch"
.Lm_noanswer: .asciz "the debugger's extension did not answer in 60 s"
.Lm_feat: .asciz "the extension does not answer debug-resolve (feature debug not agreed)"
.Lm_unsent: .asciz "the debugger's extension could not be asked to prepare the launch"
.Lm_before: .asciz "Running the prelaunch task "
.Lm_notask: .asciz "the configuration's before task is not a task (or more than one task has that name)"
.Lm_taskbusy: .asciz "the tasks are busy: the before task could not start"
.Lm_taskfailed_q: .asciz "The prelaunch task failed"
.Lm_anyway_line: .asciz " did not succeed. Debug anyway?"
.Lm_anyway: .asciz "Debug Anyway"
.Lm_badanswer: .asciz "the debugger's extension answered with a configuration that does not parse, or not of its own type"
.globl dbgx_v_debug_start
dbgx_v_debug_start: .asciz "debug-start"
.globl dbgx_v_debug_stop
dbgx_v_debug_stop: .asciz "debug-stop"
.Lw_ok: .asciz "ok "
.Lw_error: .asciz "error "
.Lev_ended: .asciz "0 debug-ended "
.Le_unknown: .asciz "unknown debug-start needs the debug feature"
.Le_unknown_stop: .asciz "unknown debug-stop needs the debug feature"
.Le_not_yours: .asciz "refused not a session you started"
.Le_type: .asciz "refused the configuration's type is not one of your debuggers"
.Le_missing: .asciz "missing no installed extension provides a debugger of that type"
.Le_window: .asciz "refused not within 10 s of one of your commands"
.Le_toobig: .asciz "toobig 8 sessions"
.Le_toobig_sp: .asciz " toobig 8 sessions"
.Le_cancelled: .asciz " cancelled"
.Le_busy: .asciz " busy"
.Le_preparing: .asciz "busy a launch is being prepared"
.Le_refused: .asciz " refused "
