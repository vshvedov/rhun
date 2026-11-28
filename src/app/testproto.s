# testing: the "tests" feature of protocol 1.1 (docs/extensions/v1.1.md). Controllers publish items
# (test-items, test-remove), answer tests-resolve for lazy items, run what rhun asks with test-run
# and report test-update records until test-end; test-coverage and test-exec belong to a run.
# extproto.s routes every tests verb here (h_tests) and the answers to rhun's requests
# (testproto_reply); this file answers through ext_send_checked itself.
.include "rhun.inc"

# a tests-resolve request that is out
STRUCT
F RQ_ext, 8
F RQ_id, 8
F RQ_item, 8
F RQ_gen, 8
F RQ_t0, 8
ENDSTRUCT RQ_SIZE

.bss
.p2align 3
mf_path: .zero 4096          # message_flush: a location's path as a cstr
.p2align 3
rq: .zero RQ_SIZE * TS_RESOLVE_MAX
ob: .zero SB_SIZE               # the message being built
req_ext: .quad 0                # the request being handled: its extension, id, verb fields
req_id: .quad 0
req_body: .quad 0
req_blen: .quad 0
req_run: .quad 0                # its run (test-update, test-end, test-coverage, test-exec)
req_tsc: .quad 0
# a results body being applied (test-update)
rr_run: .quad 0
rr_tsc: .quad 0
rr_ent: .quad 0                 # the record's TSE, 0 for an unknown item
rr_item: .quad 0                # its item index, -1 for the run itself
rr_apply: .quad 0               # 0 in the checking pass, 1 when applying
rr_msgs: .quad 0                # messages of this record so far
cm_open: .quad 0                # the current message: 1 while one is open
cm_text: .quad 0
cm_textlen: .quad 0
cm_path: .quad 0
cm_pathlen: .quad 0
cm_l1: .long 0
cm_c1: .long 0
cm_l2: .long 0
cm_c2: .long 0
cm_exp: .quad 0
cm_explen: .quad 0              # -1: none
cm_act: .quad 0
cm_actlen: .quad 0
hdr: .zero TSM_SIZE

.text

# ---------------- sending ----------------

ob_begin:
    lea rdi, [rip + ob]
    jmp sb_clear
ob_cstr:
    mov rsi, rdi
    lea rdi, [rip + ob]
    jmp sb_push_cstr
ob_u64:
    mov rsi, rdi
    lea rdi, [rip + ob]
    jmp sb_push_u64
ob_byte:
    mov esi, edi
    lea rdi, [rip + ob]
    jmp sb_push_byte
ob_bytes:
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + ob]
    jmp sb_push
# ob_send(ext) -> rax 0 when queued (ext_send_checked)
ob_send:
    mov rsi, [rip + ob + SB_ptr]
    mov rdx, [rip + ob + SB_len]
    jmp ext_send_checked

# reply_ok(id): "ok ID" to req_ext
reply_ok:
    push rbx
    mov rbx, rdi
    call ob_begin
    lea rdi, [rip + .Lw_ok]
    call ob_cstr
    mov rdi, rbx
    call ob_u64
    mov edi, 10
    call ob_byte
    mov rdi, [rip + req_ext]
    call ob_send
    pop rbx
    ret

# reply_ok_u64(id, value): "ok ID VALUE"
reply_ok_u64:
    push rbx
    push r12
    push r12
    mov rbx, rdi
    mov r12, rsi
    call ob_begin
    lea rdi, [rip + .Lw_ok]
    call ob_cstr
    mov rdi, rbx
    call ob_u64
    mov edi, ' '
    call ob_byte
    mov rdi, r12
    call ob_u64
    mov edi, 10
    call ob_byte
    mov rdi, [rip + req_ext]
    call ob_send
    pop r12
    pop r12
    pop rbx
    ret

# FN testproto_reply_error(id, "code text"): "error ID CODE TEXT" to the extension being served
FN testproto_reply_error
    push rbx
    push r12
    push r12
    mov rbx, rdi
    mov r12, rsi
    call ob_begin
    lea rdi, [rip + .Lw_error]
    call ob_cstr
    mov rdi, rbx
    call ob_u64
    mov edi, ' '
    call ob_byte
    mov rdi, r12
    call ob_cstr
    mov edi, 10
    call ob_byte
    mov rdi, [rip + req_ext]
    call ob_send
    pop r12
    pop r12
    pop rbx
    ret

# FN testproto_set_ext(ext): the replies that follow go to this extension (testexec.s's answers to a
# request that waited for the user's approval)
FN testproto_set_ext
    mov [rip + req_ext], rdi
    ret

# FN testproto_reply_ok_u64(id, value) for testexec.s
FN testproto_reply_ok_u64
    jmp reply_ok_u64

# next_id(ext) -> rax a fresh request id for rhun's request, 0 when ids ran out
next_id:
    cmp qword ptr [rdi + EXT_hreq], 2147483647
    jae 8f
    inc qword ptr [rdi + EXT_hreq]
    push qword ptr [rdi + EXT_hreq]
    push rdi
    mov rsi, [rdi + EXT_hreq]   # resources group: its time, for the cost counters and idle = stop
    lea rdx, [rip + .Ltp_kind]
    mov ecx, 5
    call extres_req_sent
    pop rdi
    pop rax
    ret
8:  xor eax, eax
    ret

# FN testproto_agreed(ext) -> eax 1 while its program runs and agreed tests
FN testproto_agreed
    xor eax, eax
    test rdi, rdi
    jz 9f
    cmp dword ptr [rdi + EXT_status], ES_RUNNING
    jne 9f
    FEAT_TEST rdi, FEAT_TESTS
    jz 9f
    mov eax, 1
9:  ret

# FN testproto_event(ext, ptr, len): an event's bytes to the extension (testexec.s's output)
FN testproto_event
    jmp ext_send_checked

# ---------------- the controller's life ----------------

# testproto_ready(ext): after hello: a controller that agreed tests is asked for its roots, and runs
#   waiting for it go out
FN testproto_ready
    PROLOGUE
    mov rbx, rdi
    FEAT_TEST rbx, FEAT_TESTS
    jz 9f
    mov rdi, rbx
    call testmodel_ctrl_make
    test rax, rax
    jz 9f
    mov r12, rax
    mov dword ptr [r12 + TSC_ready], 1
    call testview_ensure        # the Testing section shows its controllers
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call testproto_resolve
    call testproto_dispatch
9:  EPILOGUE

# testproto_profiles(ext) -> eax the TSP_* bits it offers: run, and the words of tests.profiles
FN testproto_profiles
    PROLOGUE
    mov r15d, 1 << TSP_RUN
    mov r12, [rdi + EXT_tests_profiles]
    test r12, r12
    jz 9f
    mov rdi, r12
    call strlen
    mov r13, rax
1:  test r13, r13
    jz 9f
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 9f
    mov r14, rax
    mov rbx, rdx
    xor ecx, ecx
2:  lea rax, [rip + ts_profile_words]
    mov rdx, [rax + rcx*8]
    test rdx, rdx
    jz 1b
    push rcx
    push rcx
    mov rdi, r14
    mov rsi, rbx
    call str_eq_cstr
    pop rcx
    pop rcx
    test eax, eax
    jz 3f
    bts r15d, ecx
    jmp 1b
3:  inc ecx
    jmp 2b
9:  mov eax, r15d
    EPILOGUE

# testproto_ext_gone(ext): its program stopped: its runs end errored ("the extension stopped"),
#   their processes stop, its tests-resolve requests are dropped; its items stay
FN testproto_ext_gone
    PROLOGUE
    mov rbx, rdi
    call testmodel_ctrl
    test rax, rax
    jz 1f
    mov dword ptr [rax + TSC_ready], 0
1:  mov rdi, rbx
    call testexec_ext_gone
    lea r12, [rip + g_ts_runs]
    xor r13d, r13d
2:  cmp [r12 + TSR_ext], rbx
    jne 3f
    cmp dword ptr [r12 + TSR_state], TSRS_ENDED
    je 3f
    mov rdi, r12
    call testmodel_run_entry
    lea rsi, [rip + .Lm_stopped]
    mov rdi, rax
    call entry_note
    mov rdi, r12
    mov esi, 1
    call testmodel_run_end
3:  add r12, TSR_SIZE
    inc r13d
    cmp r13d, TS_RUNS_MAX
    jb 2b
    mov rdi, rbx
    xor esi, esi
    call drop_requests
9:  EPILOGUE

# testproto_resolving() -> eax tests-resolve requests out
FN testproto_resolving
    xor eax, eax
    lea rcx, [rip + rq]
    xor edx, edx
1:  cmp qword ptr [rcx + RQ_ext], 0
    je 2f
    inc eax
2:  add rcx, RQ_SIZE
    inc edx
    cmp edx, TS_RESOLVE_MAX
    jb 1b
    ret

# testproto_debug_window(ext) -> eax 1 while the extension has a queued or running run of profile
#   debug (the user asked to debug its tests): the debugger lets it start a session (debug-start)
FN testproto_debug_window
    xor eax, eax
    lea rcx, [rip + g_ts_runs]
    xor edx, edx
1:  cmp [rcx + TSR_ext], rdi
    jne 2f
    cmp dword ptr [rcx + TSR_profile], TSP_DEBUG
    jne 2f
    cmp dword ptr [rcx + TSR_state], TSRS_QUEUED
    je 3f
    cmp dword ptr [rcx + TSR_state], TSRS_RUNNING
    je 3f
2:  add rcx, TSR_SIZE
    inc edx
    cmp edx, TS_RUNS_MAX
    jb 1b
    ret
3:  mov eax, 1
    ret

# testproto_forget_requests(ext): its tests-resolve requests are dropped (the extension goes)
FN testproto_forget_requests
    mov esi, 1
    jmp drop_requests

# drop_requests(ext, forgotten): its requests leave the table; unless forgotten, their items stop
#   showing they are resolving
drop_requests:
    PROLOGUE
    mov rbx, rdi
    mov r14d, esi
    lea r12, [rip + rq]
    xor r13d, r13d
1:  cmp [r12 + RQ_ext], rbx
    jne 2f
    test r14d, r14d
    jnz 11f
    mov rdi, rbx
    call testmodel_ctrl
    test rax, rax
    jz 11f
    mov r15, rax
    mov rdi, rax
    mov rsi, [r12 + RQ_item]
    mov rdx, [r12 + RQ_gen]
    call testmodel_live
    test eax, eax
    jz 11f
    mov rdi, r15
    mov rsi, [r12 + RQ_item]
    xor edx, edx
    call testmodel_resolving
11: mov qword ptr [r12 + RQ_ext], 0
2:  add r12, RQ_SIZE
    inc r13d
    cmp r13d, TS_RESOLVE_MAX
    jb 1b
    EPILOGUE

# entry_note(TSE*, cstr): a message with that text on a result (the run's own, for a run that ended
#   for a reason rhun knows)
entry_note:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov r13, rax
    lea rdi, [rip + hdr]
    xor esi, esi
    mov edx, TSM_SIZE
    call memset
    mov [rip + hdr + TSM_text], r13d
    mov dword ptr [rip + hdr + TSM_exp], -1
    mov dword ptr [rip + hdr + TSM_act], -1
    lea rdi, [rbx + TSE_msgs]
    lea rsi, [rip + hdr]
    mov edx, TSM_SIZE
    call sb_push
    lea rdi, [rbx + TSE_msgs]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    inc dword ptr [rbx + TSE_nmsg]
    EPILOGUE

# ---------------- tests-resolve ----------------

# testproto_resolve(ext, tsc, index): "ID tests-resolve LEN" + the item's id (empty for the roots),
#   unless one is out for it already or the table is full
FN testproto_resolve
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    call testproto_agreed
    test eax, eax
    jz 9f
    # one at a time per item, and a free slot
    lea r14, [rip + rq]
    xor ecx, ecx
    xor r15d, r15d
1:  cmp qword ptr [r14 + RQ_ext], 0
    jne 2f
    test r15, r15
    jnz 3f
    mov r15, r14
    jmp 3f
2:  cmp [r14 + RQ_ext], rbx
    jne 3f
    cmp [r14 + RQ_item], r13
    je 9f
3:  add r14, RQ_SIZE
    inc ecx
    cmp ecx, TS_RESOLVE_MAX
    jb 1b
    test r15, r15
    jz 9f
    mov rdi, rbx
    call next_id
    test rax, rax
    jz 9f
    mov [r15 + RQ_id], rax
    mov [r15 + RQ_ext], rbx
    mov [r15 + RQ_item], r13
    mov rdi, r12
    mov rsi, r13
    call testmodel_item
    mov r14, rax
    mov eax, [r14 + TSI_gen]
    mov [r15 + RQ_gen], rax
    call time_ms
    mov [r15 + RQ_t0], rax
    call ob_begin
    mov rdi, [r15 + RQ_id]
    call ob_u64
    lea rdi, [rip + .Lv_resolve]
    call ob_cstr
    mov edi, [r14 + TSI_idlen]
    call ob_u64
    mov edi, 10
    call ob_byte
    mov rdi, [r14 + TSI_id]
    mov esi, [r14 + TSI_idlen]
    call ob_bytes
    mov rdi, rbx
    call ob_send
    test rax, rax
    jz 4f
    mov qword ptr [r15 + RQ_ext], 0
    jmp 9f
4:  mov rdi, rbx                # the query engine keeps its 30 s and counts it
    mov rsi, [r15 + RQ_id]
    mov edx, PK_TESTS_RESOLVE
    mov ecx, QO_TESTS
    call query_track
    mov rdi, r12
    mov rsi, r13
    mov edx, 1
    call testmodel_resolving
9:  EPILOGUE

# testproto_reply(ext, id, ok, body or text, length) -> eax 1 when the answer was to a tests-resolve
#   or a test-run of this extension
FN testproto_reply
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
    lea rcx, [rip + rq]
    xor edx, edx
1:  cmp [rcx + RQ_ext], rbx
    jne 2f
    cmp [rcx + RQ_id], r12
    je .Ltr_resolve
2:  add rcx, RQ_SIZE
    inc edx
    cmp edx, TS_RESOLVE_MAX
    jb 1b
    # a test-run answer
    lea rcx, [rip + g_ts_runs]
    xor edx, edx
3:  cmp [rcx + TSR_ext], rbx
    jne 4f
    cmp [rcx + TSR_req], r12
    je .Ltr_run
4:  add rcx, TSR_SIZE
    inc edx
    cmp edx, TS_RUNS_MAX
    jb 3b
    xor eax, eax
    EPILOGUE
.Ltr_resolve:
    mov qword ptr [rcx + RQ_ext], 0
    mov rax, [rcx + RQ_item]
    mov [rsp + 8], rax
    mov rax, [rcx + RQ_gen]
    mov [rsp + 16], rax
    mov rdi, rbx
    call testmodel_ctrl
    test rax, rax
    jz 8f
    mov [rip + req_tsc], rax
    mov rdi, rax
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    call testmodel_live
    test eax, eax
    jz 8f
    mov rdi, [rip + req_tsc]
    mov rsi, [rsp + 8]
    xor edx, edx
    call testmodel_resolving
    test r13d, r13d
    jz .Ltr_resolve_err
    # the answer replaces the item's children; the item is resolved
    mov rdi, [rip + req_tsc]
    mov rsi, [rsp + 8]
    call testmodel_item
    mov rdi, [rip + req_tsc]
    mov esi, 1
    mov rdx, r14
    mov rcx, r15
    mov r8, [rax + TSI_id]
    mov r9d, [rax + TSI_idlen]
    call testmodel_items
    test rax, rax
    jnz .Ltr_bad_answer
    mov rdi, [rip + req_tsc]
    mov rsi, [rsp + 8]
    call testmodel_item
    and dword ptr [rax + TSI_flags], ~TSF_LAZY
    mov rdi, [rip + req_tsc]
    mov rsi, [rsp + 8]
    xor edx, edx
    xor ecx, ecx
    call testmodel_set_error
    jmp 8f
.Ltr_bad_answer:
    mov r14, rax                # a bad answer: its problem shows on the row
    mov rdi, rax
    call strlen
    mov rcx, rax
    mov rdi, [rip + req_tsc]
    mov rsi, [rsp + 8]
    mov rdx, r14
    call testmodel_set_error
    jmp 8f
.Ltr_resolve_err:
    mov rdi, [rip + req_tsc]
    mov rsi, [rsp + 8]
    mov rdx, r14
    mov rcx, r15
    call testmodel_set_error
8:  mov eax, 1
    EPILOGUE
.Ltr_run:
    mov qword ptr [rcx + TSR_req], 0
    test r13d, r13d
    jnz 8b
    # refused or busy: the run ends errored, and the reason shows
    mov r12, rcx
    mov rdi, r12
    call testmodel_run_entry
    mov rdi, rax
    mov rsi, r14
    mov rdx, r15
    call entry_note_bytes
    mov rdi, r12
    mov esi, 1
    call testmodel_run_end
    mov rdi, r14
    mov rsi, r15
    call toast_bytes
    call testproto_dispatch
    jmp 8b

# testproto_expired(ext, id, ...): the query engine gave up on a tests-resolve (30 s) or a test-run
#   (10 s): it is answered as an error saying so
FN testproto_expired
    xor edx, edx
    lea rcx, [rip + .Lm_no_answer]
    mov r8d, 17
    jmp testproto_reply

# entry_note_bytes(TSE*, ptr, len): as entry_note with bytes
entry_note_bytes:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r13, TS_MSG_MAX
    jbe 1f
    mov r13d, TS_MSG_MAX
1:  lea rdi, [rip + hdr]
    xor esi, esi
    mov edx, TSM_SIZE
    call memset
    mov [rip + hdr + TSM_text], r13d
    mov dword ptr [rip + hdr + TSM_exp], -1
    mov dword ptr [rip + hdr + TSM_act], -1
    lea rdi, [rbx + TSE_msgs]
    lea rsi, [rip + hdr]
    mov edx, TSM_SIZE
    call sb_push
    lea rdi, [rbx + TSE_msgs]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    inc dword ptr [rbx + TSE_nmsg]
    EPILOGUE

# toast_bytes(ptr, len): the first line, at most 200 bytes, as a toast
.bss
toast_buf: .zero 208
.text
toast_bytes:
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 2f
    cmp rcx, 200
    jae 2f
    movzx eax, byte ptr [rdi + rcx]
    cmp eax, 10
    je 2f
    lea rdx, [rip + toast_buf]
    mov [rdx + rcx], al
    inc rcx
    jmp 1b
2:  lea rdx, [rip + toast_buf]
    mov byte ptr [rdx + rcx], 0
    lea rdi, [rip + toast_buf]
    jmp app_toast

# ---------------- runs ----------------

# testproto_run(ext, profile, ids, len, n) -> TSR*, a run of those items (n 0: everything) that goes
#   out when its controller is ready and a slot is free; 0 when no run slot is left
FN testproto_run
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8
    mov rdi, rbx
    call testmodel_ctrl_make
    test rax, rax
    jz 8f
    mov rdi, rbx
    mov esi, r12d
    call testmodel_run_new
    test rax, rax
    jz 8f
    mov r15, rax
    lea rdi, [r15 + TSR_ids]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    mov rax, [rsp]
    mov [r15 + TSR_nids], eax
    # a controller not running yet starts (the run waits for its hello)
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    je 1f
    mov rdi, rbx
    call ext_start
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    je 1f
    mov rdi, r15                # it cannot start: the run ends errored, saying so
    call testmodel_run_entry
    mov rdi, rax
    lea rsi, [rip + .Lm_not_running]
    call entry_note
    mov rdi, r15
    mov esi, 1
    call testmodel_run_end
    jmp 2f
1:  call testproto_dispatch
2:  mov dword ptr [rip + g_dirty], 1
    mov rax, r15
    EPILOGUE
8:  lea rdi, [rip + .Lm_no_slot]
    call app_toast
    xor eax, eax
    EPILOGUE

# testproto_dispatch(): queued runs go out, oldest first, while their controller is ready and it
#   has fewer than 4 and all have fewer than 8 running
FN testproto_dispatch
    PROLOGUE
1:  # the queued run with the lowest number whose controller is ready
    lea rcx, [rip + g_ts_runs]
    xor edx, edx
    xor ebx, ebx
2:  cmp qword ptr [rcx + TSR_ext], 0
    je 3f
    cmp dword ptr [rcx + TSR_state], TSRS_QUEUED
    jne 3f
    test rbx, rbx
    jz 21f
    mov rax, [rcx + TSR_num]
    cmp rax, [rbx + TSR_num]
    jae 3f
21: push rcx
    push rdx
    mov rdi, [rcx + TSR_ext]
    call testproto_agreed
    pop rdx
    pop rcx
    test eax, eax
    jz 3f
    push rcx
    push rdx
    mov rdi, [rcx + TSR_ext]
    call testmodel_running
    pop rdx
    pop rcx
    cmp eax, TS_RUNS_EXT
    jae 3f
    mov rbx, rcx
3:  add rcx, TSR_SIZE
    inc edx
    cmp edx, TS_RUNS_MAX
    jb 2b
    test rbx, rbx
    jz 9f
    xor edi, edi
    call testmodel_running
    cmp eax, TS_RUNS_ACTIVE
    jae 9f
    mov rdi, rbx
    call send_run
    jmp 1b
9:  EPILOGUE

# send_run(run): "ID test-run RUN PROFILE N LEN" + the ids; the run is running from now on (a
#   refused send ends it errored)
send_run:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + TSR_ext]
    mov dword ptr [rbx + TSR_state], TSRS_RUNNING
    call time_ms
    mov [rbx + TSR_t0], rax
    mov rdi, r12
    call next_id
    test rax, rax
    jz 8f
    mov [rbx + TSR_req], rax
    call ob_begin
    mov rdi, [rbx + TSR_req]
    call ob_u64
    lea rdi, [rip + .Lv_run]
    call ob_cstr
    mov rdi, [rbx + TSR_num]
    call ob_u64
    mov edi, ' '
    call ob_byte
    mov eax, [rbx + TSR_profile]
    lea rcx, [rip + ts_profile_words]
    mov rdi, [rcx + rax*8]
    call ob_cstr
    mov edi, ' '
    call ob_byte
    mov edi, [rbx + TSR_nids]
    call ob_u64
    mov edi, ' '
    call ob_byte
    mov rdi, [rbx + TSR_ids + SB_len]
    call ob_u64
    mov edi, 10
    call ob_byte
    mov rdi, [rbx + TSR_ids + SB_ptr]
    mov rsi, [rbx + TSR_ids + SB_len]
    call ob_bytes
    mov rdi, r12
    call ob_send
    test rax, rax
    jnz 8f
    mov rdi, r12
    mov rsi, [rbx + TSR_req]
    mov edx, PK_TEST_RUN
    mov ecx, QO_TESTS
    call query_track
    mov dword ptr [rip + g_ts_dirty], 3
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
8:  mov rdi, rbx
    mov esi, 1
    call testmodel_run_end
    EPILOGUE

# testproto_cancel(run): the user cancelled: a running run is told (test-cancel) and its processes
#   stop after 2 s; rhun ends it after 5 s if the extension has not; a queued one ends at once
FN testproto_cancel
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + TSR_state], TSRS_QUEUED
    jne 1f
    mov rdi, rbx
    xor esi, esi
    call testmodel_run_end
    jmp 9f
1:  cmp dword ptr [rbx + TSR_state], TSRS_RUNNING
    jne 9f
    cmp qword ptr [rbx + TSR_cancel_at], 0
    jne 9f
    call time_ms
    mov [rbx + TSR_cancel_at], rax
    call ob_begin
    lea rdi, [rip + .Lev_cancel]
    call ob_cstr
    mov rdi, [rbx + TSR_num]
    call ob_u64
    mov edi, 10
    call ob_byte
    mov rdi, [rbx + TSR_ext]
    call ob_send
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# testing_tick(): tests-resolve answers that waited 30 s, Cancel deadlines, runs waiting for a slot,
#   and the processes (testexec_tick)
FN testing_tick
    PROLOGUE
    call time_ms
    mov r15, rax
    # Cancel: processes stop after 2 s, the run ends after 5 s
    lea rbx, [rip + g_ts_runs]
    xor r12d, r12d
3:  cmp qword ptr [rbx + TSR_ext], 0
    je 4f
    cmp dword ptr [rbx + TSR_state], TSRS_RUNNING
    jne 4f
    mov rax, [rbx + TSR_cancel_at]
    test rax, rax
    jz 4f
    mov rcx, r15
    sub rcx, rax
    cmp rcx, TS_CANCEL_END_MS
    jb 31f
    mov rdi, rbx
    call testmodel_run_entry
    mov rdi, rax
    lea rsi, [rip + .Lm_cancelled]
    call entry_note
    mov rdi, rbx
    xor esi, esi
    call testmodel_run_end
    call testproto_dispatch
    jmp 4f
31: cmp rcx, TS_CANCEL_KILL_MS
    jb 4f
    cmp dword ptr [rbx + TSR_killed], 0
    jne 4f
    mov dword ptr [rbx + TSR_killed], 1
    mov rdi, rbx
    call testexec_run_kill
4:  add rbx, TSR_SIZE
    inc r12d
    cmp r12d, TS_RUNS_MAX
    jb 3b
    call testproto_dispatch
    call testexec_tick
    call testgutter_tick        # failures as problems
    call testview_cov_tick      # the Coverage section
    EPILOGUE

# testing_timeout() -> ms until testing_tick has something to do, -1 when nothing waits
FN testing_timeout
    PROLOGUE
    mov r12, -1                 # the earliest deadline
    lea rbx, [rip + g_ts_runs]
    xor r13d, r13d
3:  cmp qword ptr [rbx + TSR_ext], 0
    je 4f
    cmp dword ptr [rbx + TSR_state], TSRS_RUNNING
    jne 4f
    mov rax, [rbx + TSR_cancel_at]
    test rax, rax
    jz 4f
    lea rcx, [rax + TS_CANCEL_END_MS]
    cmp dword ptr [rbx + TSR_killed], 0
    jne 31f
    lea rcx, [rax + TS_CANCEL_KILL_MS]
31: cmp rcx, r12
    jae 4f
    mov r12, rcx
4:  add rbx, TSR_SIZE
    inc r13d
    cmp r13d, TS_RUNS_MAX
    jb 3b
    call testexec_timeout       # ms or -1
    mov r13, rax
    cmp r12, -1
    je 7f
    call time_ms
    mov rcx, r12
    sub rcx, rax
    jns 5f
    xor ecx, ecx
5:  mov rax, rcx
    cmp r13, -1
    je 9f
    cmp r13, rax
    jae 9f
7:  mov rax, r13
9:  EPILOGUE

# ---------------- requests from the controller ----------------

# testproto_request(ext, id, line, len, body, body length): a tests verb (h_tests in extproto.s)
FN testproto_request
    PROLOGUE 32
    mov rbx, rdi
    mov [rip + req_ext], rdi
    mov [rip + req_id], rsi
    mov [rip + req_body], r8
    mov [rip + req_blen], r9
    mov rdi, rdx
    mov rsi, rcx
    call tsb_fields
    mov r12d, eax               # fields
    FEAT_TEST rbx, FEAT_TESTS
    jz .Ltq_unknown
    mov edi, 1
    lea rsi, [rip + .Lv_items]
    call tsb_is
    test eax, eax
    jnz .Ltq_items
    mov edi, 1
    lea rsi, [rip + .Lv_update]
    call tsb_is
    test eax, eax
    jnz .Ltq_update
    mov edi, 1
    lea rsi, [rip + .Lv_end]
    call tsb_is
    test eax, eax
    jnz .Ltq_end
    mov edi, 1
    lea rsi, [rip + .Lv_remove]
    call tsb_is
    test eax, eax
    jnz .Ltq_remove
    mov edi, 1
    lea rsi, [rip + .Lv_coverage]
    call tsb_is
    test eax, eax
    jnz .Ltq_coverage
    mov edi, 1
    lea rsi, [rip + .Lv_exec]
    call tsb_is
    test eax, eax
    jnz .Ltq_exec
.Ltq_unknown:
    mov rdi, [rip + req_id]
    lea rsi, [rip + .Le_unknown]
    call testproto_reply_error
    EPILOGUE
.Ltq_syntax:
    mov rdi, [rip + req_id]
    lea rsi, [rip + .Le_syntax]
    call testproto_reply_error
    EPILOGUE

    # ID test-items MODE LEN
.Ltq_items:
    cmp r12d, 4
    jne .Ltq_syntax
    mov edi, 2
    lea rsi, [rip + .Lw_replace]
    call tsb_is
    mov r13d, eax
    test eax, eax
    jnz 1f
    mov edi, 2
    lea rsi, [rip + .Lw_add]
    call tsb_is
    test eax, eax
    jz .Ltq_syntax
1:  mov rdi, rbx
    call testmodel_ctrl_make
    test rax, rax
    jz .Ltq_full
    mov rdi, rax
    mov esi, r13d
    mov rdx, [rip + req_body]
    mov rcx, [rip + req_blen]
    xor r8d, r8d
    mov r9, -1
    call testmodel_items
    test rax, rax
    jnz .Ltq_error_text
    mov rdi, [rip + req_id]
    call reply_ok
    EPILOGUE
.Ltq_error_text:
    mov rsi, rax
    mov rdi, [rip + req_id]
    call testproto_reply_error
    EPILOGUE
.Ltq_full:
    mov rdi, [rip + req_id]
    lea rsi, [rip + .Le_ctrl_full]
    call testproto_reply_error
    EPILOGUE

    # ID test-remove N LEN + N ids, each ending in LF
.Ltq_remove:
    cmp r12d, 4
    jne .Ltq_syntax
    mov edi, 2
    call tsb_num
    test edx, edx
    jz .Ltq_syntax
    mov r13, rax
    mov rdi, rbx
    call testmodel_ctrl
    test rax, rax
    jz .Ltq_remove_ok
    mov r14, rax
    mov rdi, [rip + req_body]
    mov rsi, [rip + req_blen]
    call tsb_begin
    # check first: N lines that are ids
    xor r15d, r15d
2:  cmp r15, r13
    jae 3f
    call tsb_line
    test rax, rax
    jz .Ltq_syntax
    test rdx, rdx
    jz .Ltq_syntax
    cmp rdx, TS_ID_MAX
    ja .Ltq_syntax
    inc r15
    jmp 2b
3:  call tsb_left
    test rax, rax
    jnz .Ltq_syntax
    mov rdi, [rip + req_body]
    mov rsi, [rip + req_blen]
    call tsb_begin
4:  test r13, r13
    jz .Ltq_remove_ok
    dec r13
    call tsb_line
    mov rdi, r14
    mov rsi, rax
    call testmodel_remove_id
    jmp 4b
.Ltq_remove_ok:
    mov rdi, [rip + req_id]
    call reply_ok
    EPILOGUE

    # ID test-update RUN LEN + results
.Ltq_update:
    cmp r12d, 4
    jne .Ltq_syntax
    call req_run_arg
    test rax, rax
    jz 9f
    mov rdi, rax
    call apply_results
    test rax, rax
    jnz .Ltq_error_text
    mov rdi, [rip + req_id]
    call reply_ok
9:  EPILOGUE

    # ID test-end RUN
.Ltq_end:
    cmp r12d, 3
    jne .Ltq_syntax
    call req_run_arg
    test rax, rax
    jz 9b
    mov rdi, rax
    xor esi, esi
    call testmodel_run_end
    mov rdi, [rip + req_id]
    call reply_ok
    call testproto_dispatch
    EPILOGUE

    # ID test-coverage RUN LEN + coverage
.Ltq_coverage:
    cmp r12d, 4
    jne .Ltq_syntax
    call req_run_arg
    test rax, rax
    jz 9b
    mov rdi, rax
    mov rsi, [rip + req_body]
    mov rdx, [rip + req_blen]
    call testcover_apply
    test rax, rax
    jnz .Ltq_error_text
    mov rdi, [rip + req_id]
    call reply_ok
    EPILOGUE

    # ID test-exec RUN LEN + command
.Ltq_exec:
    cmp r12d, 4
    jne .Ltq_syntax
    call req_run_arg
    test rax, rax
    jz 9b
    mov rdi, rbx
    mov rsi, [rip + req_id]
    mov rdx, rax
    mov rcx, [rip + req_body]
    mov r8, [rip + req_blen]
    call testexec_request
    EPILOGUE

# req_run_arg() -> TSR* named by field 2 when it is this extension's and running, else 0 with the
#   error sent ("stale run over" for an unknown or finished run)
req_run_arg:
    push rbx
    mov edi, 2
    call tsb_num
    test edx, edx
    jz 7f
    mov rdi, rax
    call testmodel_run_by_num
    test rax, rax
    jz 8f
    mov rcx, [rip + req_ext]
    cmp [rax + TSR_ext], rcx
    jne 6f
    cmp dword ptr [rax + TSR_state], TSRS_RUNNING
    jne 8f
    mov [rip + req_run], rax
    pop rbx
    ret
6:  mov rdi, [rip + req_id]
    lea rsi, [rip + .Le_not_yours]
    call testproto_reply_error
    xor eax, eax
    pop rbx
    ret
7:  mov rdi, [rip + req_id]
    lea rsi, [rip + .Le_syntax]
    call testproto_reply_error
    xor eax, eax
    pop rbx
    ret
8:  mov rdi, [rip + req_id]
    lea rsi, [rip + .Le_stale_run]
    call testproto_reply_error
    xor eax, eax
    pop rbx
    ret

# ---------------- results ----------------

# apply_results(run) -> rax 0 when the body applied, else the error text (nothing changed). The
#   body: "N" LF, then N records "STATE MS ITEM_LEN EXTRA_LEN" LF ITEM EXTRA; extras message LEN,
#   location L1 C1 L2 C2 LEN (a path), expected LEN, actual LEN, output LEN
apply_results:
    PROLOGUE 16
    mov rbx, rdi
    mov [rip + rr_run], rdi
    mov rdi, [rbx + TSR_ext]
    call testmodel_ctrl
    mov [rip + rr_tsc], rax
    test rax, rax
    jz .Lar_syntax
    mov qword ptr [rip + rr_apply], 0
1:  mov rdi, [rip + req_body]
    mov rsi, [rip + req_blen]
    call tsb_begin
    call tsb_line
    test rax, rax
    jz .Lar_syntax
    mov rdi, rax
    mov rsi, rdx
    call tsb_fields
    cmp eax, 1
    jne .Lar_syntax
    xor edi, edi
    call tsb_num
    test edx, edx
    jz .Lar_syntax
    cmp rax, TS_RESULTS_MAX
    ja .Lar_toobig
    mov r12, rax
2:  test r12, r12
    jz 3f
    dec r12
    call result_record
    test rax, rax
    jnz .Lar_fail
    jmp 2b
3:  call tsb_left
    test rax, rax
    jnz .Lar_syntax
    cmp qword ptr [rip + rr_apply], 0
    jne 4f
    mov qword ptr [rip + rr_apply], 1
    jmp 1b
4:  call testmodel_budget
    mov dword ptr [rip + g_ts_dirty], 3
    mov dword ptr [rip + g_ts_marks], 1
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE
.Lar_fail:
    EPILOGUE
.Lar_syntax:
    lea rax, [rip + .Le_syntax_results]
    EPILOGUE
.Lar_toobig:
    lea rax, [rip + .Le_toobig_results]
    EPILOGUE

# result_record() -> rax 0 or the error text: one record, checked (rr_apply 0) or applied
result_record:
    PROLOGUE 32
    call tsb_line
    test rax, rax
    jz .Lrr_syntax
    mov rdi, rax
    mov rsi, rdx
    call tsb_fields
    cmp eax, 4
    jne .Lrr_syntax
    # the state: one of the words, or "-"
    mov r13, -1
    xor edi, edi
    lea rsi, [rip + .Ldash]
    call tsb_is
    test eax, eax
    jnz 2f
    xor r14d, r14d
1:  lea rax, [rip + result_words]
    mov rsi, [rax + r14*8]
    test rsi, rsi
    jz .Lrr_syntax
    xor edi, edi
    call tsb_is
    test eax, eax
    jnz 11f
    inc r14d
    jmp 1b
11: lea rax, [rip + result_states]
    mov r13d, [rax + r14*4]
2:  mov [rsp], r13              # the state, -1 for no change
    # ms: a number or "-"
    mov qword ptr [rsp + 8], -1
    mov edi, 1
    lea rsi, [rip + .Ldash]
    call tsb_is
    test eax, eax
    jnz 3f
    mov edi, 1
    call tsb_num
    test edx, edx
    jz .Lrr_syntax
    mov rcx, 0x7ffffffe
    cmp rax, rcx
    cmova rax, rcx
    mov [rsp + 8], rax
3:  mov edi, 2
    call tsb_num
    test edx, edx
    jz .Lrr_syntax
    cmp rax, TS_ID_MAX
    ja .Lrr_syntax
    mov r14, rax                # item length
    mov edi, 3
    call tsb_num
    test edx, edx
    jz .Lrr_syntax
    mov r15, rax                # extras length
    mov rdi, r14
    call tsb_take
    test rax, rax
    jz .Lrr_syntax
    mov r12, rax                # the item
    mov rdi, r15
    call tsb_take
    test rax, rax
    jz .Lrr_syntax
    mov [rsp + 16], rax         # the extras
    # the item: empty is the run itself (no change or errored only)
    mov qword ptr [rip + rr_ent], 0
    mov qword ptr [rip + rr_item], -1
    test r14, r14
    jnz 4f
    mov rax, [rsp]
    cmp rax, -1
    je 31f
    cmp rax, TSS_ERRORED
    jne .Lrr_syntax
31: cmp qword ptr [rip + rr_apply], 0
    je 6f
    mov rdi, [rip + rr_run]
    call testmodel_run_entry
    mov [rip + rr_ent], rax
    cmp qword ptr [rsp], TSS_ERRORED
    jne 6f
    mov rcx, [rip + rr_run]
    mov dword ptr [rcx + TSR_err], 1
    jmp 6f
4:  cmp qword ptr [rip + rr_apply], 0
    je 6f
    mov rdi, [rip + rr_tsc]
    mov rsi, r12
    mov rdx, r14
    call testmodel_find
    test rax, rax
    jle 5f                      # unknown (or the controller's row): dropped, counted
    mov [rip + rr_item], rax
    mov rdi, [rip + rr_run]
    mov rsi, [rip + rr_tsc]
    mov rdx, rax
    call testmodel_entry
    mov [rip + rr_ent], rax
    mov r13, rax
    mov rcx, [rsp]
    cmp rcx, -1
    je 41f
    mov [r13 + TSE_state], ecx
    # a new state without a message of this run yet: the old summary goes
    cmp dword ptr [r13 + TSE_nmsg], 0
    jne 40f
    mov rdi, [rip + rr_tsc]
    mov rsi, [rip + rr_item]
    call testmodel_item
    lea rdi, [rax + TSI_msg]
    xor esi, esi
    xor edx, edx
    call set_msg
40: mov rdi, [rip + rr_tsc]
    mov rsi, [rip + rr_item]
    mov rdx, [rsp]
    call testmodel_set_own
41: mov rcx, [rsp + 8]
    cmp rcx, -1
    je 6f
    mov [r13 + TSE_ms], ecx
    mov rdi, [rip + rr_tsc]
    mov rsi, [rip + rr_item]
    call testmodel_item
    mov rcx, [rsp + 8]
    mov [rax + TSI_ms], ecx
    jmp 6f
5:  mov rcx, [rip + rr_run]
    inc dword ptr [rcx + TSR_dropped]
6:  # the extras
    mov qword ptr [rip + cm_open], 0
    mov qword ptr [rip + rr_msgs], 0
    mov r12, [rsp + 16]
    lea r13, [r12 + r15]
7:  cmp r12, r13
    jae 8f
    mov rdi, r12
    mov rsi, r13
    call testmodel_extra
    test rax, rax
    jz .Lrr_syntax
    mov r12, r9
    mov rdi, rax
    mov rsi, rdx
    mov rdx, rcx
    mov rcx, r8
    call result_extra
    test rax, rax
    jnz .Lrr_fail
    jmp 7b
8:  call message_flush
    xor eax, eax
    EPILOGUE
.Lrr_fail:
    EPILOGUE
.Lrr_syntax:
    lea rax, [rip + .Le_syntax_results]
    EPILOGUE

# result_extra(name, name length, body, body length) -> rax 0 or the error text; tsb_f holds the
#   record's fields
result_extra:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r14, rdx
    mov r15, rcx
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lx_message]
    call str_eq_cstr
    test eax, eax
    jz 2f
    call message_flush
    mov qword ptr [rip + cm_open], 1
    mov [rip + cm_text], r14
    mov rax, r15
    cmp rax, TS_MSG_MAX
    jbe 1f
    mov eax, TS_MSG_MAX
1:  mov [rip + cm_textlen], rax
    mov qword ptr [rip + cm_pathlen], 0
    mov dword ptr [rip + cm_l1], 0
    mov dword ptr [rip + cm_c1], 0
    mov dword ptr [rip + cm_l2], 0
    mov dword ptr [rip + cm_c2], 0
    mov qword ptr [rip + cm_explen], -1
    mov qword ptr [rip + cm_actlen], -1
    jmp 8f
2:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lx_location]
    call str_eq_cstr
    test eax, eax
    jz 3f
    mov edi, 1                  # the record's fields are in tsb_f: location L1 C1 L2 C2 LEN
    call tsb_num
    test edx, edx
    jz 7f
    mov [rsp], eax
    mov edi, 2
    call tsb_num
    test edx, edx
    jz 7f
    mov [rsp + 4], eax
    mov edi, 3
    call tsb_num
    test edx, edx
    jz 7f
    mov [rsp + 8], eax
    mov edi, 4
    call tsb_num
    test edx, edx
    jz 7f
    mov [rsp + 12], eax
    cmp dword ptr [rsp], 0
    je 7f
    cmp dword ptr [rsp + 4], 0
    je 7f
    cmp r15, 4095
    ja 7f
    test r15, r15
    jz 7f
    mov eax, [rsp]
    mov [rip + cm_l1], eax
    mov eax, [rsp + 4]
    mov [rip + cm_c1], eax
    mov eax, [rsp + 8]
    mov [rip + cm_l2], eax
    mov eax, [rsp + 12]
    mov [rip + cm_c2], eax
    mov [rip + cm_path], r14
    mov [rip + cm_pathlen], r15
    jmp 8f
3:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lx_expected]
    call str_eq_cstr
    test eax, eax
    jz 4f
    mov rax, r15
    cmp rax, TS_VALUE_MAX
    jbe 31f
    mov eax, TS_VALUE_MAX
31: mov [rip + cm_exp], r14
    mov [rip + cm_explen], rax
    jmp 8f
4:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lx_actual]
    call str_eq_cstr
    test eax, eax
    jz 5f
    mov rax, r15
    cmp rax, TS_VALUE_MAX
    jbe 41f
    mov eax, TS_VALUE_MAX
41: mov [rip + cm_act], r14
    mov [rip + cm_actlen], rax
    jmp 8f
5:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lx_output]
    call str_eq_cstr
    test eax, eax
    jz 8f                       # unknown records are skipped
    cmp qword ptr [rip + rr_apply], 0
    je 8f
    mov rdi, r14
    mov rsi, r15
    call output_append
    jmp 8f
7:  lea rax, [rip + .Le_syntax_results]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# message_flush(): the open message goes into the record's result (16 per item per run; the first
#   line of the first one becomes the item's summary)
message_flush:
    PROLOGUE
    cmp qword ptr [rip + cm_open], 0
    je 9f
    mov qword ptr [rip + cm_open], 0
    cmp qword ptr [rip + rr_apply], 0
    je 9f
    mov rbx, [rip + rr_ent]
    test rbx, rbx
    jz 9f
    cmp dword ptr [rbx + TSE_nmsg], TS_MSGS_ITEM
    jae 9f
    # the budget: a run past it keeps no more messages
    cmp qword ptr [rip + g_ts_bytes], TS_BUDGET
    jb 1f
    mov rcx, [rip + rr_run]
    mov dword ptr [rcx + TSR_cut], 1
    jmp 9f
1:  mov eax, [rip + cm_l1]
    mov [rip + hdr + TSM_l1], eax
    mov eax, [rip + cm_c1]
    mov [rip + hdr + TSM_c1], eax
    mov eax, [rip + cm_l2]
    mov [rip + hdr + TSM_l2], eax
    mov eax, [rip + cm_c2]
    mov [rip + hdr + TSM_c2], eax
    mov rax, [rip + cm_textlen]
    mov [rip + hdr + TSM_text], eax
    mov rax, [rip + cm_pathlen]
    mov [rip + hdr + TSM_path], eax
    mov rax, [rip + cm_explen]
    mov [rip + hdr + TSM_exp], eax
    mov rax, [rip + cm_actlen]
    mov [rip + hdr + TSM_act], eax
    # the version of its file's open document: the problem's place follows later edits
    mov qword ptr [rip + hdr + TSM_ver], -1
    mov rdx, [rip + cm_pathlen]
    test rdx, rdx
    jz 11f
    lea rdi, [rip + mf_path]
    mov rsi, [rip + cm_path]
    call memcpy
    mov rcx, [rip + cm_pathlen]
    lea rdi, [rip + mf_path]
    mov byte ptr [rdi + rcx], 0
    call testgutter_doc_ver
    mov [rip + hdr + TSM_ver], rax
11: lea rdi, [rbx + TSE_msgs]
    lea rsi, [rip + hdr]
    mov edx, TSM_SIZE
    call sb_push
    lea rdi, [rbx + TSE_msgs]
    mov rsi, [rip + cm_text]
    mov rdx, [rip + cm_textlen]
    call sb_push
    lea rdi, [rbx + TSE_msgs]
    mov rsi, [rip + cm_path]
    mov rdx, [rip + cm_pathlen]
    call sb_push
    mov rdx, [rip + cm_explen]
    mov r12, TSM_SIZE
    add r12, [rip + cm_textlen]
    add r12, [rip + cm_pathlen]
    cmp rdx, -1
    je 2f
    add r12, rdx
    lea rdi, [rbx + TSE_msgs]
    mov rsi, [rip + cm_exp]
    call sb_push
2:  mov rdx, [rip + cm_actlen]
    cmp rdx, -1
    je 3f
    add r12, rdx
    lea rdi, [rbx + TSE_msgs]
    mov rsi, [rip + cm_act]
    call sb_push
3:  mov rcx, [rip + rr_run]
    add [rcx + TSR_bytes], r12
    add [rip + g_ts_bytes], r12
    inc dword ptr [rbx + TSE_nmsg]
    cmp dword ptr [rbx + TSE_nmsg], 1
    jne 9f
    mov rsi, [rip + rr_item]
    test rsi, rsi
    js 9f
    mov rdi, [rip + rr_tsc]
    call testmodel_item
    lea rdi, [rax + TSI_msg]
    mov rsi, [rip + cm_text]
    mov rdx, [rip + cm_textlen]
    call set_msg
9:  EPILOGUE

# set_msg(slot*, ptr, len): the first line of the text, at most 200 bytes, as an owned cstr (0
#   for none)
set_msg:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [rbx]
    call mem_free
    mov qword ptr [rbx], 0
    xor ecx, ecx
1:  cmp rcx, r13
    jae 2f
    cmp rcx, 200
    jae 2f
    cmp byte ptr [r12 + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  test rcx, rcx
    jz 9f
    mov rsi, rcx
    mov rdi, r12
    mov rsi, rcx
    call mem_dup
    mov [rbx], rax
9:  EPILOGUE

# output_append(ptr, len): the record's output: the item's (256 KB a run) or the run's (4 MB), then
#   "[output cut]" once; nothing past the budget
output_append:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rbx, [rip + rr_ent]
    test rbx, rbx
    jz 9f
    mov r15, [rip + rr_run]
    lea r14, [rbx + TSE_out]
    mov rax, TS_OUT_ITEM
    cmp qword ptr [rip + rr_item], 0
    jge 1f
    lea r14, [r15 + TSR_out]    # the run's own output
    mov rax, TS_OUT_RUN
1:  cmp qword ptr [rip + g_ts_bytes], TS_BUDGET
    jb 11f
    mov dword ptr [r15 + TSR_cut], 1
    xor eax, eax                # nothing more fits
11: mov rcx, rax
    sub rcx, [r14 + SB_len]
    jbe 3f
    mov rdx, r13
    cmp rdx, rcx
    jbe 2f
    mov rdx, rcx
2:  add [r15 + TSR_bytes], rdx
    add [rip + g_ts_bytes], rdx
    push rdx
    push rdx
    mov rdi, r14
    mov rsi, r12
    call sb_push
    pop rdx
    pop rdx
    cmp rdx, r13
    jae 9f
3:  # cut: say so once
    cmp dword ptr [rbx + TSE_cut], 0
    jne 9f
    mov dword ptr [rbx + TSE_cut], 1
    mov rdi, r14
    lea rsi, [rip + .Lm_cut]
    call sb_push_cstr
9:  EPILOGUE

.section .rodata
.Ltp_kind: .asciz "tests"
.Lw_ok: .asciz "ok "
.Lw_error: .asciz "error "
.Lw_replace: .asciz "replace"
.Lw_add: .asciz "add"
.Ldash: .asciz "-"
.Lv_resolve: .asciz " tests-resolve "
.Lv_run: .asciz " test-run "
.Lv_items: .asciz "test-items"
.Lv_remove: .asciz "test-remove"
.Lv_update: .asciz "test-update"
.Lv_end: .asciz "test-end"
.Lv_coverage: .asciz "test-coverage"
.Lv_exec: .asciz "test-exec"
.Lev_cancel: .asciz "0 test-cancel "
.Lx_message: .asciz "message"
.Lx_location: .asciz "location"
.Lx_expected: .asciz "expected"
.Lx_actual: .asciz "actual"
.Lx_output: .asciz "output"
.Lr_queued: .asciz "queued"
.Lr_started: .asciz "started"
.Lr_passed: .asciz "passed"
.Lr_failed: .asciz "failed"
.Lr_errored: .asciz "errored"
.Lr_skipped: .asciz "skipped"
.Le_unknown: .asciz "unknown no such request"
.Le_syntax: .asciz "syntax cannot parse the line"
.Le_syntax_results: .asciz "syntax bad results body"
.Le_toobig_results: .asciz "toobig 2000 records per body"
.Le_stale_run: .asciz "stale run over"
.Le_not_yours: .asciz "refused not a run of this extension"
.Le_ctrl_full: .asciz "toobig 64 controllers"
.Lm_stopped: .asciz "the extension stopped"
.Lm_cancelled: .asciz "cancelled; the extension did not end the run within 5 s"
.Lm_no_slot: .asciz "Too many test runs: wait for one to finish"
.Lm_cut: .asciz "\n[output cut]\n"
.Lm_no_answer: .asciz "no answer in time"     # 17 bytes
.Lm_not_running: .asciz "the extension is not running"
.p2align 3
result_words: .quad .Lr_queued, .Lr_started, .Lr_passed, .Lr_failed, .Lr_errored, .Lr_skipped, 0
result_states: .long TSS_QUEUED, TSS_RUNNING, TSS_PASSED, TSS_FAILED, TSS_ERRORED, TSS_SKIPPED
