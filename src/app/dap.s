# debug sessions (Debug Adapter Protocol client): starting a configuration, the session state
# machine (initialize, launch or attach, configuration, running and paused), events, the stack and
# variables of a stop with their lifetimes (epochs), stepping, and Stop's escalation. dapwire.s
# moves the bytes; debugcfg.s builds the launch; bp.s owns breakpoints.
.include "rhun.inc"

.bss
.p2align 3
.globl g_dsess, g_dfocus, g_dmsg
g_dsess: .zero DS_SIZE * DS_MAX
.data
g_dfocus: .long -1              # the focused session's slot, -1
dnext_id: .long 1
.bss
.p2align 3
g_dmsg: .zero SB_SIZE           # the message being built (jw_*)
pd: .zero PD_SIZE               # pend_take's copy
pathz: .zero SB_SIZE            # a NUL-terminated path from the pool
g_nodep:
nodep: .zero SB_SIZE            # a node's path
dlg_text: .zero 2048
.globl g_watches, g_nodep
restart_name: .zero SB_SIZE
restart_after: .long 0          # a restart waits for this session to end
restart_nodebug: .long 0
g_watches: .zero SB_SIZE        # watch expressions, one per line
.data
.globl g_dap_gen
g_dap_gen: .long 1              # bumped by every change the debug view shows
.globl g_hv_root, g_hv_slot, g_hv_epoch, g_hv_vgen
g_hv_root: .long -1             # the hover's value in the pool (r_hover), -1 none
g_hv_slot: .long -1             # its session, and the stop and pool it belongs to
g_hv_epoch: .long 0
g_hv_vgen: .long 0
.bss

.text

# ---------------- sessions ----------------

# dap_slot(i) -> DS*
FN dap_slot
    mov eax, edi
    imul rax, rax, DS_SIZE
    lea rcx, [rip + g_dsess]
    add rax, rcx
    ret

# dap_focused() -> DS* of the focused session, or 0
FN dap_focused
    mov edi, [rip + g_dfocus]
    test edi, edi
    js 1f
    call dap_slot
    cmp dword ptr [rax + DS_state], DSS_FREE
    je 1f
    ret
1:  xor eax, eax
    ret

# dap_live_count() -> eax sessions that have not ended
FN dap_live_count
    xor eax, eax
    lea rcx, [rip + g_dsess]
    xor edx, edx
1:  mov r8d, [rcx + DS_state]
    test r8d, r8d
    jz 2f
    cmp r8d, DSS_ENDED
    je 2f
    inc eax
2:  add rcx, DS_SIZE
    inc edx
    cmp edx, DS_MAX
    jb 1b
    ret

# slot_index(ds) -> eax its slot
FN dap_slot_index
slot_index:
    mov rax, rdi
    lea rcx, [rip + g_dsess]
    sub rax, rcx
    xor edx, edx
    mov ecx, DS_SIZE
    div rcx
    ret

# ds_alloc() -> DS* of a free (or ended and reaped) slot, reset; 0 when all 8 are taken
ds_alloc:
    PROLOGUE
    xor r12d, r12d
1:  cmp r12d, DS_MAX
    jae 8f
    mov edi, r12d
    call dap_slot
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_FREE
    je 2f
    cmp dword ptr [rbx + DS_state], DSS_ENDED
    jne 11f
    cmp dword ptr [rbx + DS_pid], 0
    jne 11f
    cmp dword ptr [rbx + DS_pgrp], 0
    je 2f                       # a group still to be killed keeps the slot
11: inc r12d
    jmp 1b
2:  mov rdi, rbx
    call ds_free_mem
    mov dword ptr [rbx + DS_in], -1
    mov dword ptr [rbx + DS_out], -1
    mov dword ptr [rbx + DS_err], -1
    mov dword ptr [rbx + DS_aout], -1
    mov dword ptr [rbx + DS_ain], -1
    mov dword ptr [rbx + DS_csock], -1
    mov eax, [rip + dnext_id]
    inc dword ptr [rip + dnext_id]
    mov [rbx + DS_id], eax
    mov dword ptr [rbx + DS_exit], -1
    mov dword ptr [rbx + DS_seq], 1
    mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ds_free_mem(ds): everything a session owns, the record zeroed but its buffers kept
ds_free_mem:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + DS_name]
    call mem_free
    mov rdi, [rbx + DS_reason]
    call mem_free
    mov rdi, [rbx + DS_desc]
    call mem_free
    mov rdi, [rbx + DS_after]
    call mem_free
    mov rdi, rbx
    call pend_clear
    # keep the buffers' memory, empty
    lea r12, [rip + ds_buffers]
1:  mov rax, [r12]
    test rax, rax
    js 2f
    mov qword ptr [rbx + rax + SB_len], 0
    add r12, 8
    jmp 1b
2:  # zero the scalars (everything before DS_launch, and the tail fields)
    mov rdi, rbx
    xor esi, esi
    mov edx, DS_launch
    call memset
    mov dword ptr [rbx + DS_total_frames], 0
    mov dword ptr [rbx + DS_npend], 0
    mov dword ptr [rbx + DS_nargs], 0
    mov dword ptr [rbx + DS_reading], 0
    mov qword ptr [rbx + DS_exited_at], 0
    mov dword ptr [rbx + DS_more], 0
    mov dword ptr [rbx + DS_pgrp], 0
    mov qword ptr [rbx + DS_dbg_ext], 0
    mov qword ptr [rbx + DS_wq_off], 0
    EPILOGUE

# ds_set_str(slot*, ptr, len): an owned cstr replaces the slot's
ds_set_str:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [rbx]
    call mem_free
    mov qword ptr [rbx], 0
    test r12, r12
    jz 1f
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rbx], rax
1:  pop r13
    pop r12
    pop rbx
    ret

# ds_set_cstr(slot*, cstr or 0)
ds_set_cstr:
    test rsi, rsi
    jz ds_set_str
    push rdi
    push rsi
    sub rsp, 8
    mov rdi, rsi
    call strlen
    add rsp, 8
    mov rdx, rax
    pop rsi
    pop rdi
    jmp ds_set_str

# ---------------- starting ----------------

# dap_start(name ptr, len, nodebug) -> eax the new session's id, 0 when it could not start (the
#   console and a toast say why). The first start of an extension's debugger in a project asks.
FN dap_start
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov [rsp], edx
    mov dword ptr [rip + dstart_resolved], 0
    mov dword ptr [rip + dstart_before], 0
    call dbgx_resolving
    test eax, eax
    jnz .Lst_preparing          # one launch waits for its extension at a time
    call dask_starting          # a launch the user starts forgets earlier answers
    mov rdi, r12
    mov rsi, r13
    mov edx, [rsp]
    call dcfg_prepare
    test eax, eax
    jnz 1f
    cmp dword ptr [rip + g_dcfg_code], DCE_ASK
    jne .Lst_cfgfail
    # ${ask:} and friends: the user answers, then the launch starts again (debugask.s)
    mov rdi, r12
    mov rsi, r13
    mov edx, [rsp]
    call dask_begin
    xor eax, eax
    EPILOGUE
1:  call dask_done              # the answers were used
    mov qword ptr [rip + dstart_owner], 0
    mov qword ptr [rip + dstart_oid], 0
.Lst_prepared:
    cmp qword ptr [rip + g_lc_compound + SB_len], 0
    jne .Lst_compound
    mov edi, [rip + g_lc_dbg]
    call dbg_row
    mov r14, rax
    mov r15, [r14 + DBG_ext]
    test dword ptr [r15 + EXT_needs], NEEDS_DEBUG
    jz .Lst_noneeds
    # resolve = yes: the extension sees the configuration first (debugext.s); the launch goes on
    # in dap_start_resolved. Not for its own debug-start sessions; another extension's debug-start
    # of it ([needs] debuggers: the Tests extension's of the Debug extension's js-debug) is resolved,
    # its answer waiting for the launch
    cmp dword ptr [r14 + DBG_resolve], 0
    je 1f
    cmp dword ptr [rip + dstart_resolved], 0
    jne 1f
    mov rax, [rip + dstart_owner]
    cmp rax, r15
    je 1f
    mov rdi, rax
    mov rsi, [rip + dstart_oid]
    call dbgx_resolve_owner
    mov rdi, r15
    mov esi, [rip + g_lc_dbg]
    call dbgx_resolve_begin
    test eax, eax
    jz .Lst_resfail
    xor eax, eax
    EPILOGUE
1:  # before = TASK: the tasks group runs it first; the launch goes on in dap_start_after_before
    cmp qword ptr [rip + g_lc_before + SB_len], 0
    je 2f
    cmp dword ptr [rip + dstart_before], 0
    jne 2f
    mov rdi, [rip + g_lc_before + SB_ptr]
    call dbgx_before_begin
    test eax, eax
    jz .Lst_resfail
    xor eax, eax
    EPILOGUE
2:  mov dword ptr [rsp + 4], DTR_STDIO
    mov dword ptr [rsp + 8], DAP_LOOPBACK
    cmp qword ptr [rip + g_lc_server + SB_len], 0
    jne .Lst_server
    cmp dword ptr [r14 + DBG_transport], 0
    jne .Lst_tcp
.Lst_cmd:
    call dcfg_adapter
    test eax, eax
    jz .Lst_cfgfail
.Lst_alloc:
    call ds_alloc
    test rax, rax
    jz .Lst_full
    mov rbx, rax
    mov eax, [rsp + 4]
    mov [rbx + DS_transport], eax
    mov eax, [rip + g_lc_port]
    mov [rbx + DS_port], eax
    mov eax, [rsp + 8]
    mov [rbx + DS_addr], eax
    mov eax, [rip + g_lc_dbg]
    mov [rbx + DS_dbg], eax
    mov [rbx + DS_dbg_ext], r15
    mov rax, [rip + dstart_owner]
    mov [rbx + DS_owner], rax
    mov rax, [rip + dstart_oid]
    mov [rbx + DS_owner_id], rax
    lea rdi, [rbx + DS_after]       # after = TASK runs when the session ends
    mov rsi, [rip + g_lc_after + SB_ptr]
    mov rdx, [rip + g_lc_after + SB_len]
    test rdx, rdx
    jnz 3f
    xor esi, esi
3:  call ds_set_str
    mov eax, [rip + g_lc_request]
    mov [rbx + DS_request], eax
    mov eax, [rip + g_lc_nodebug]
    mov [rbx + DS_nodebug], eax
    lea rdi, [rbx + DS_name]
    mov rsi, [rip + g_lc_name + SB_ptr]
    mov rdx, [rip + g_lc_name + SB_len]
    call ds_set_str
    lea rdi, [rbx + DS_launch]
    mov rsi, [rip + g_lc_json + SB_ptr]
    mov rdx, [rip + g_lc_json + SB_len]
    call sb_push
    lea rdi, [rbx + DS_args]
    mov rsi, [rip + g_lc_args + SB_ptr]
    mov rdx, [rip + g_lc_args + SB_len]
    call sb_push
    mov eax, [rip + g_lc_nargs]
    mov [rbx + DS_nargs], eax
    mov rdi, rbx
    call slot_index
    mov [rip + g_dfocus], eax
    # a server runs already: nothing is started, so nothing is asked
    cmp dword ptr [rbx + DS_transport], DTR_SERVER
    je 1f
    # one approval per extension and project (runallow.s): asked once, with the exact command
    mov dword ptr [rbx + DS_state], DSS_APPROVAL
    mov rdi, r15
    mov rsi, [rip + g_lc_cmd + SB_ptr]
    lea rdx, [rip + approval_done]
    mov ecx, [rbx + DS_id]
    call run_approve
    cmp eax, 1
    je 1f
    test eax, eax
    jz 2f
    # another dialog is open
    mov rdi, rbx
    lea rsi, [rip + .Lm_busy]
    call ds_fail
    xor eax, eax
    EPILOGUE
1:  mov rdi, rbx
    call launch_now
2:  mov eax, [rbx + DS_id]
    EPILOGUE
.Lst_busy:
    lea rdi, [rip + .Lm_busy]
    jmp .Lst_msg
.Lst_compound:
    # compound = A | B: each configuration starts in turn, the next once nothing waits for the
    # user or an extension (compound_next, from the tick)
    cmp dword ptr [rip + cq_starting], 0
    jne .Lst_inner              # a compound naming a compound (itself, say)
    cmp qword ptr [rip + cq + SB_len], 0
    jne .Lst_nested
    lea rdi, [rip + cq]
    mov rsi, [rip + g_lc_compound + SB_ptr]
    mov rdx, [rip + g_lc_compound + SB_len]
    call sb_push
    mov eax, [rip + g_lc_nodebug]
    mov [rip + cq_nodebug], eax
    call compound_next
    xor eax, eax
    EPILOGUE
.Lst_nested:
    lea rdi, [rip + .Lm_compound]
    jmp .Lst_msg
.Lst_inner:
    lea rdi, [rip + .Lm_compound_in]
    jmp .Lst_msg
.Lst_server:
    # server = HOST:PORT (or PORT): connect to an adapter that runs already
    mov rdi, [rip + g_lc_server + SB_ptr]
    call server_addr
    test eax, eax
    jz .Lst_badserver
    mov [rip + g_lc_port], eax
    mov [rsp + 8], edx
    mov dword ptr [rsp + 4], DTR_SERVER
    mov dword ptr [rip + g_lc_nargs], 0
    jmp .Lst_alloc
.Lst_badserver:
    lea rdi, [rip + .Lm_badserver]
    jmp .Lst_msg
.Lst_preparing:
    lea rdi, [rip + .Lm_preparing]
    jmp .Lst_msg
.Lst_resfail:
    mov rdi, [rip + g_dstart_msg]
    jmp .Lst_msg
.Lst_tcp:
    # a free loopback port for ${port}; the adapter listens there and rhun connects (in a remote
    #   window on the host's loopback, through the host: dap_connect_try)
    call dap_pick_port
    test eax, eax
    js .Lst_noport
    mov [rip + g_lc_port], eax
    mov dword ptr [rsp + 4], DTR_TCP
    jmp .Lst_cmd
.Lst_noport:
    lea rdi, [rip + .Lm_noport]
    jmp .Lst_msg

.Lst_noneeds:
    lea rdi, [rip + .Lm_noneeds]
    jmp .Lst_msg
.Lst_full:
    lea rdi, [rip + .Lm_full]
    jmp .Lst_msg
.Lst_cfgfail:
    lea rdi, [rip + g_dcfg_err]
.Lst_msg:
    mov [rip + g_dstart_msg], rdi
    call dap_error
    xor eax, eax
    EPILOGUE

# dap_start_ext(EXT*, request id) -> eax the new session's id, 0 when it could not start
#   (g_dstart_msg says why; the console and a toast too): debug-start (debugext.s) after
#   dcfg_from_leaves filled g_lc_*. The extension hears ok ID SESSION once the adapter starts, or an
#   error (cancelled, busy, refused) from ds_end; debug-ended when the session is over
FN dap_start_ext
    PROLOGUE 16
    mov [rip + dstart_owner], rdi
    mov [rip + dstart_oid], rsi
    mov dword ptr [rip + dstart_resolved], 0
    mov dword ptr [rip + dstart_before], 1      # its bodies have no before
    jmp .Lst_prepared

# dap_start_resolved() -> eax the session's id, 0: the debugger's extension answered debug-resolve
#   (debugext.s) and g_lc_* hold the configuration to launch
FN dap_start_resolved
    PROLOGUE 16
    call dbgx_take_owner        # another extension's debug-start: it hears of the session
    mov [rip + dstart_owner], rax
    mov [rip + dstart_oid], rdx
    mov dword ptr [rip + dstart_resolved], 1
    mov dword ptr [rip + dstart_before], 0
    jmp .Lst_prepared

# dap_start_after_before() -> eax the session's id, 0: launch.ini's before task ended well
#   (debugext.s) and g_lc_* still hold the configuration
FN dap_start_after_before
    PROLOGUE 16
    mov qword ptr [rip + dstart_owner], 0
    mov qword ptr [rip + dstart_oid], 0
    mov dword ptr [rip + dstart_resolved], 1
    mov dword ptr [rip + dstart_before], 1
    jmp .Lst_prepared

# compound_next(): the next configuration of a compound, unless a launch waits for the user (an
#   approval) or for its extension (debug-resolve, a before task)
compound_next:
    PROLOGUE
    cmp qword ptr [rip + cq + SB_len], 0
    je 9f
    call dbgx_resolving
    test eax, eax
    jnz 9f
    call dask_waiting           # a launch's question on screen: its answer starts it first
    test eax, eax
    jnz 9f
    xor ebx, ebx
1:  cmp ebx, DS_MAX
    jae 2f
    mov edi, ebx
    call dap_slot
    inc ebx
    cmp dword ptr [rax + DS_state], DSS_APPROVAL
    je 9f
    jmp 1b
2:  # the first name, without the spaces around it
    mov r12, [rip + cq + SB_ptr]
    mov r13, [rip + cq + SB_len]
    xor ecx, ecx
3:  cmp rcx, r13
    jae 4f
    cmp byte ptr [r12 + rcx], '|'
    je 4f
    inc rcx
    jmp 3b
4:  mov r14, rcx                # the name's end
    lea r15, [rcx + 1]          # what is left starts here
    cmp r15, r13
    jbe 41f
    mov r15, r13
41: xor eax, eax                # its start
5:  cmp rax, r14
    jae 6f
    cmp byte ptr [r12 + rax], ' '
    jne 6f
    inc rax
    jmp 5b
6:  cmp r14, rax
    jbe 7f
    cmp byte ptr [r12 + r14 - 1], ' '
    jne 7f
    dec r14
    jmp 6b
7:  lea rdi, [rip + cqname]
    lea rsi, [r12 + rax]
    mov rdx, r14
    sub rdx, rax
    call sb_set_cq
    # the rest stays
    mov rdi, r12
    lea rsi, [r12 + r15]
    mov rdx, r13
    sub rdx, r15
    mov [rip + cq + SB_len], rdx
    call memmove
    cmp qword ptr [rip + cqname + SB_len], 0
    je 9f
    mov dword ptr [rip + cq_starting], 1
    mov rdi, [rip + cqname + SB_ptr]
    mov rsi, [rip + cqname + SB_len]
    mov edx, [rip + cq_nodebug]
    call dap_start
    mov dword ptr [rip + cq_starting], 0
9:  EPILOGUE

# sb_set_cq(sb, ptr, len)
sb_set_cq:
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

# dap_error(cstr): a failure to start or run, in the console and as a toast
FN dap_error
    push rbx
    mov rbx, rdi
    call strlen
    xor edi, edi
    mov esi, DCON_ERROR
    mov rdx, rbx
    mov rcx, rax
    call dcon_line
    mov rdi, rbx
    call app_toast
    pop rbx
    ret

# approval_done(session id, allowed): the approval dialog's answer: the session starts, or ends
#   without running anything
approval_done:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    call slot_of_id
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_APPROVAL
    jne 9f
    test r13d, r13d
    jz 1f
    mov rdi, rbx
    call launch_now
    EPILOGUE
1:  mov rdi, rbx
    lea rsi, [rip + .Lm_cancelled]
    call ds_end
9:  EPILOGUE

# dap_slot_of_id(id) -> rax DS* of the session with that id, or 0
FN dap_slot_of_id
slot_of_id:
    PROLOGUE
    mov r12d, edi
    xor ebx, ebx
1:  cmp ebx, DS_MAX
    jae 8f
    mov edi, ebx
    call dap_slot
    cmp dword ptr [rax + DS_state], DSS_FREE
    je 2f
    cmp [rax + DS_id], r12d
    je 9f
2:  inc ebx
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# memcpy_max(dst, src, limit, n) -> end: n bytes, stopping at limit, NUL-terminated
memcpy_max:
1:  test rcx, rcx
    jz 2f
    cmp rdi, rdx
    jae 2f
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    dec rcx
    jmp 1b
2:  mov byte ptr [rdi], 0
    mov rax, rdi
    ret

# dap_forget_approvals(): Forget for every debugger's extension (tests)
FN dap_forget_approvals
    PROLOGUE
    xor ebx, ebx
1:  cmp ebx, [rip + g_ndebuggers]
    jae 9f
    mov edi, ebx
    call dbg_row
    mov rdi, [rax + DBG_ext]
    call run_forget
    inc ebx
    jmp 1b
9:  EPILOGUE

# launch_now(ds): spawn the adapter and send initialize. A tcp adapter (or a server) is connected
#   to first: initialize waits in the queue meanwhile. In a remote window an adapter in its
#   extension's folder waits (connecting) until that folder is on the host (copy_tick)
launch_now:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    call copy_first
    test eax, eax
    jg 5f                       # its extension's files are on their way
    js 9f                       # they cannot be: ended
    mov rdi, rbx
    call launch_go
    test eax, eax
    jnz 4f
9:  EPILOGUE
5:  mov dword ptr [rbx + DS_state], DSS_CONNECTING
    mov dword ptr [rbx + DS_rcopy], 1
    call time_ms
    mov [rbx + DS_deadline], rax
    add rax, DAP_COPY_MS
    mov [rbx + DS_conn_until], rax
4:  # debug-start: the extension that asked hears the session's id
    cmp qword ptr [rbx + DS_owner_id], 0
    je 41f
    mov rdi, [rbx + DS_owner]
    mov rsi, [rbx + DS_owner_id]
    mov edx, [rbx + DS_id]
    call dbgx_reply_ok
    mov qword ptr [rbx + DS_owner_id], 0
    mov dword ptr [rbx + DS_owner_ok], 1
41: mov edi, [rbx + DS_id]
    mov esi, DCON_INFO
    lea rdx, [rip + .Lm_starting]
    mov ecx, .Lm_starting_end - .Lm_starting
    cmp dword ptr [rbx + DS_nodebug], 0
    je 42f
    lea rdx, [rip + .Lm_starting_run]   # without debugging: the program, not the debugger
    mov ecx, .Lm_starting_run_end - .Lm_starting_run
42: call dcon_line
    mov rdi, rbx
    call dview_session_started
    mov dword ptr [rip + g_dirty], 1
    inc dword ptr [rip + g_dap_gen]
    EPILOGUE


# copy_first(ds) -> eax 0 when the adapter can start now, 1 when its extension's folder is on its
#   way to the host first (a remote window, and the adapter's command names that folder: an adapter
#   it ships), -1 when the folder cannot get there (the session ended, saying why)
copy_first:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    cmp dword ptr [rbx + DS_transport], DTR_SERVER
    je 9f
    mov r12, [rbx + DS_dbg_ext]
    test r12, r12
    jz 9f
    mov rdi, r12
    call remote_ext_remote
    test eax, eax
    jz 9f
    mov rdi, [r12 + EXT_dir]
    test rdi, rdi
    jz 8f
    call strlen
    mov rcx, rax
    test rcx, rcx
    jz 8f
    mov rdi, [rbx + DS_args + SB_ptr]
    mov rsi, [rbx + DS_args + SB_len]
    mov rdx, [r12 + EXT_dir]
    call str_find
    test rax, rax
    js 8f
    mov rdi, r12
    mov esi, 1
    call remote_ext_copy
    test eax, eax
    jg 8f
    jz 7f
    mov rdi, rbx
    mov rsi, rdx
    call copy_failed
    mov eax, -1
    EPILOGUE
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# copy_failed(ds, why cstr): the session ends: its extension's folder cannot reach the host
copy_failed:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + dlg_text]
    lea rsi, [rip + .Lm_copyfail]
    call cstr_copy
    mov rdi, rax
    mov rsi, r12
    call cstr_copy
    mov rdi, rbx
    lea rsi, [rip + dlg_text]
    call ds_end
    EPILOGUE

# copy_tick(ds): waiting for the extension's folder on the host: the adapter starts once it is
#   there; a failure, or 60 s, ends the session
copy_tick:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + DS_dbg_ext]
    xor esi, esi
    call remote_ext_copy
    test eax, eax
    jg 1f
    js 2f
    call time_ms
    cmp rax, [rbx + DS_conn_until]
    jae 3f
    add rax, DAP_CONNECT_EVERY
    mov [rbx + DS_deadline], rax
    EPILOGUE
1:  mov dword ptr [rbx + DS_rcopy], 0
    mov rdi, rbx
    call launch_go
    EPILOGUE
2:  mov rdi, rbx
    mov rsi, rdx
    call copy_failed
    EPILOGUE
3:  mov dword ptr [rbx + DS_rcopy], 0
    mov rdi, rbx
    lea rsi, [rip + .Lm_copyslow]
    call ds_end
    EPILOGUE

# launch_go(ds) -> eax 1 when the adapter started (or is connected to), 0 when the session ended
launch_go:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + DS_transport], DTR_SERVER
    je 2f
    mov rdi, rbx
    call dap_spawn
    test rax, rax
    jns 1f
    mov rdi, rbx
    lea rsi, [rip + .Lm_spawn]
    call ds_end
    xor eax, eax
    EPILOGUE
1:  cmp dword ptr [rbx + DS_transport], DTR_STDIO
    je 3f
    mov rdi, rbx
    call dap_tcp_split
2:  mov dword ptr [rbx + DS_state], DSS_CONNECTING
    call time_ms
    mov [rbx + DS_deadline], rax        # while connecting: the next try
    add rax, DAP_CONNECT_MS
    mov [rbx + DS_conn_until], rax
    mov rdi, rbx
    call send_initialize
    mov eax, 1
    EPILOGUE
3:  mov dword ptr [rbx + DS_state], DSS_INITIALIZING
    mov rdi, rbx
    call send_initialize
    call time_ms
    add rax, DAP_INIT_MS
    mov [rbx + DS_deadline], rax
    mov eax, 1
    EPILOGUE

# ---------------- building requests ----------------

# dap_req_begin(ds, command cstr): g_dmsg holds {"seq":N,"type":"request","command":C,"arguments":{
#   so the caller writes the arguments with jw_* into g_dmsg, then calls dap_req_send
FN dap_req_begin
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + g_dmsg]
    call jw_begin
    lea rdi, [rip + g_dmsg]
    call jw_obj
    lea rdi, [rip + .Lk_seq]
    call ak
    lea rdi, [rip + g_dmsg]
    mov esi, [rbx + DS_seq]
    call jw_u64
    lea rdi, [rip + .Lk_type]
    lea rsi, [rip + .Lv_request]
    call akv
    lea rdi, [rip + .Lk_command]
    mov rsi, r12
    call akv
    lea rdi, [rip + .Lk_arguments]
    call ak
    lea rdi, [rip + g_dmsg]
    call jw_obj
    EPILOGUE

# dap_req_send(ds, kind, ctx) -> eax the request's seq, 0 when it could not go out (the adapter is
#   gone or not reading, or 256 requests are in flight)
FN dap_req_send
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    lea rdi, [rip + g_dmsg]
    call jw_end_obj
    lea rdi, [rip + g_dmsg]
    call jw_end_obj
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r13
    call req_out
    EPILOGUE

# req_out(ds, kind, ctx) -> eax seq, 0: g_dmsg, complete, goes out and is remembered
req_out:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    cmp dword ptr [rbx + DS_npend], DS_PEND
    jae 8f
    mov rdi, rbx
    mov rsi, [rip + g_dmsg + SB_ptr]
    mov rdx, [rip + g_dmsg + SB_len]
    call dap_send
    test eax, eax
    jz 8f
    mov r14d, [rbx + DS_seq]
    inc dword ptr [rbx + DS_seq]
    mov eax, [rbx + DS_npend]
    inc dword ptr [rbx + DS_npend]
    imul rax, rax, PD_SIZE
    lea r15, [rbx + DS_pend + rax]
    mov [r15 + PD_seq], r14d
    mov [r15 + PD_kind], r12d
    mov eax, [rbx + DS_epoch]
    mov [r15 + PD_epoch], eax
    mov [r15 + PD_ctx], r13
    call time_ms
    mov [r15 + PD_sent], rax
    mov eax, r14d
    EPILOGUE
8:  # not sent: an owned context is freed
    cmp r12d, RQ_SETBP
    jne 81f
    mov rdi, r13
    call mem_free
81: xor eax, eax
    EPILOGUE

# ak(key cstr) / akv(key cstr, value cstr) / aki(key cstr, int) / akb(key cstr, bool) /
# aks(key cstr, ptr, len): argument writers into g_dmsg
FN ak
    mov rsi, rdi
    lea rdi, [rip + g_dmsg]
    jmp jw_key
FN akv
    push rsi
    push rsi
    call ak
    pop rsi
    pop rsi
    lea rdi, [rip + g_dmsg]
    jmp jw_cstr
FN aki
    push rsi
    push rsi
    call ak
    pop rsi
    pop rsi
    lea rdi, [rip + g_dmsg]
    jmp jw_int
FN akb
    push rsi
    push rsi
    call ak
    pop rsi
    pop rsi
    lea rdi, [rip + g_dmsg]
    jmp jw_bool
FN aks
    push rsi
    push rdx
    call ak
    pop rdx
    pop rsi
    lea rdi, [rip + g_dmsg]
    jmp jw_str

# pend_take(ds, seq) -> rax &pd (a copy) and the entry removed, or 0 for an answer rhun does not wait for
pend_take:
    mov ecx, [rdi + DS_npend]
    xor edx, edx
1:  cmp edx, ecx
    jae 8f
    mov eax, edx
    imul rax, rax, PD_SIZE
    lea r8, [rdi + DS_pend + rax]
    cmp [r8 + PD_seq], esi
    je 2f
    inc edx
    jmp 1b
2:  lea r9, [rip + pd]
    mov rax, [r8]
    mov [r9], rax
    mov rax, [r8 + 8]
    mov [r9 + 8], rax
    mov rax, [r8 + 16]
    mov [r9 + 16], rax
    mov rax, [r8 + 24]
    mov [r9 + 24], rax
    # the last entry takes its place
    dec ecx
    mov [rdi + DS_npend], ecx
    mov eax, ecx
    imul rax, rax, PD_SIZE
    lea r10, [rdi + DS_pend + rax]
    mov rax, [r10]
    mov [r8], rax
    mov rax, [r10 + 8]
    mov [r8 + 8], rax
    mov rax, [r10 + 16]
    mov [r8 + 16], rax
    mov rax, [r10 + 24]
    mov [r8 + 24], rax
    mov rax, r9
    ret
8:  xor eax, eax
    ret

# pend_clear(ds): every request forgotten (owned contexts freed)
pend_clear:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12d, [rbx + DS_npend]
    jae 9f
    mov eax, r12d
    imul rax, rax, PD_SIZE
    lea rax, [rbx + DS_pend + rax]
    cmp dword ptr [rax + PD_kind], RQ_SETBP
    jne 2f
    mov rdi, [rax + PD_ctx]
    call mem_free
2:  inc r12d
    jmp 1b
9:  mov dword ptr [rbx + DS_npend], 0
    EPILOGUE

# send_initialize(ds)
send_initialize:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Lc_initialize]
    call dap_req_begin
    lea rdi, [rip + .Lk_clientID]
    lea rsi, [rip + .Lv_rhun]
    call akv
    lea rdi, [rip + .Lk_clientName]
    lea rsi, [rip + .Lv_rhun]
    call akv
    mov edi, [rbx + DS_dbg]
    call dbg_row
    mov rsi, [rax + DBG_type]
    lea rdi, [rip + .Lk_adapterID]
    call akv
    lea rdi, [rip + .Lk_locale]
    lea rsi, [rip + .Lv_en]
    call akv
    lea rdi, [rip + .Lk_pathFormat]
    lea rsi, [rip + .Lv_path]
    call akv
    lea r12, [rip + init_true]
1:  mov rdi, [r12]
    test rdi, rdi
    jz 2f
    mov esi, 1
    call akb
    add r12, 8
    jmp 1b
2:  lea rdi, [rip + .Lk_supportsMemoryReferences]
    xor esi, esi
    call akb
    mov rdi, rbx
    mov esi, RQ_INITIALIZE
    xor edx, edx
    call dap_req_send
    EPILOGUE

# send_launch(ds): launch or attach with the prepared arguments, not awaited (adapters answer it
#   before or after initialized, or only after configurationDone)
send_launch:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lc_launch]
    cmp dword ptr [rbx + DS_request], 0
    je 1f
    lea rsi, [rip + .Lc_attach]
1:  mov rdi, rbx
    call dap_req_begin
    # the arguments object is the prepared JSON itself: it replaces the "{" just opened
    dec qword ptr [rip + g_dmsg + SB_len]
    lea rdi, [rip + g_dmsg]
    mov rsi, [rbx + DS_launch + SB_ptr]
    mov rdx, [rbx + DS_launch + SB_len]
    call sb_push
    lea rdi, [rip + g_dmsg]
    mov esi, '}'
    call sb_push_byte
    mov rdi, rbx
    mov esi, RQ_LAUNCH
    xor edx, edx
    call req_out
    EPILOGUE

# ---------------- the tick ----------------

# dap_tick(): every frame: messages from each adapter (2 ms or 64 at most), deadlines, ended adapters
FN dap_tick
    PROLOGUE
    xor r12d, r12d
1:  cmp r12d, DS_MAX
    jae 9f
    mov edi, r12d
    call dap_slot
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_FREE
    je 8f
    mov rdi, rbx
    call ds_tick
8:  inc r12d
    jmp 1b
9:  call bp_tick
    call restart_check
    call dg_hover_tick
    call dbgx_resolve_tick
    call compound_next
    call dview_anim_tick        # a spinner that moves (debugview.s)
    EPILOGUE

# ds_tick(ds)
ds_tick:
    PROLOGUE 16
    mov rbx, rdi
    cmp dword ptr [rbx + DS_state], DSS_ENDED
    jne 1f
    mov rdi, rbx
    call reap
    EPILOGUE
1:  cmp dword ptr [rbx + DS_state], DSS_APPROVAL
    je 9f
    cmp dword ptr [rbx + DS_state], DSS_CONNECTING
    jne 11f
    mov rdi, rbx
    call connect_tick
    EPILOGUE
11: call time_us
    mov r14, rax                # start
    xor r13d, r13d              # messages
    mov dword ptr [rbx + DS_more], 1    # until a frame turns out incomplete: the budget stops it
2:  cmp r13d, DAP_MSGS_TICK
    jae 5f
    call time_us
    sub rax, r14
    cmp rax, DAP_TICK_US
    jae 5f
    mov rdi, rbx
    call dap_frame
    test rax, rax
    jnz 21f
    mov dword ptr [rbx + DS_more], 0    # what is left is incomplete: input wakes the loop
    jmp 5f
21: test rax, rax
    js .Ltk_bad
    mov r15, rcx                # bytes to drop
    mov [rsp], rdx
    mov rdi, '<'
    mov esi, [rbx + DS_id]
    mov rcx, rdx
    mov rdx, rax
    push rax
    push rax
    call dap_log
    pop rax
    pop rax
    mov rdi, rax
    mov rsi, [rsp]
    mov edx, DAP_NODES_MAX
    mov ecx, DAP_DEPTH_MAX
    call json_parse_lim
    test rax, rax
    jz .Ltk_json
    mov rdi, rbx
    mov rsi, rax
    call on_message
    mov rdi, rbx
    mov rsi, r15
    call dap_drop
    cmp qword ptr [rsp], 1048576
    jb 3f
    call json_trim
3:  inc r13d
    cmp dword ptr [rbx + DS_state], DSS_ENDED
    je 9f
    jmp 2b
5:  mov rdi, rbx
    call dap_resume_reading
    # the adapter closed its output and everything it sent is handled
    test dword ptr [rbx + DS_flags], DSF_EOF
    jz 6f
    mov rdi, rbx
    call dap_frame
    test rax, rax
    jnz 6f
    mov rdi, rbx
    call adapter_gone
    EPILOGUE
6:  mov rdi, rbx
    call deadlines
9:  EPILOGUE
.Ltk_bad:
    mov rdi, rbx
    mov rsi, rdx
    call ds_fail
    EPILOGUE
.Ltk_json:
    mov rdi, rbx
    lea rsi, [rip + .Lm_json]
    call ds_fail
    EPILOGUE

# dap_timeout() -> ms until the next deadline (0 when messages wait for the next frame), or -1
FN dap_timeout
    PROLOGUE
    mov r13, -1
    call time_ms
    mov r14, rax
    xor r12d, r12d
1:  cmp r12d, DS_MAX
    jae 9f
    mov edi, r12d
    call dap_slot
    mov rbx, rax
    mov eax, [rbx + DS_state]
    test eax, eax
    jz 8f
    cmp eax, DSS_APPROVAL
    je 8f
    # complete messages waiting, or a closed output not yet handled: the next frame
    cmp eax, DSS_ENDED
    je 4f
    cmp dword ptr [rbx + DS_more], 0
    jne 5f
    test dword ptr [rbx + DS_flags], DSF_EOF
    jnz 5f
4:  lea r15, [rbx + DS_deadline]
    call near_deadline
    lea r15, [rbx + DS_killat]
    call near_deadline
    cmp dword ptr [rbx + DS_pid], 0
    je 41f
    cmp dword ptr [rbx + DS_state], DSS_ENDED
    jne 41f
    mov rax, 100                # an ended adapter is reaped
    call near_ms
41: cmp dword ptr [rbx + DS_npend], 0
    je 8f
    mov rax, 1000               # requests time out
    call near_ms
    jmp 8f
5:  xor r13d, r13d
    jmp 9f
8:  inc r12d
    jmp 1b
9:  call dg_hover_due           # the pointer's rest before a hover evaluation
    cmp eax, -1
    je 91f
    call near_ms
91: call dbgx_resolve_timeout   # debug-resolve's deadlines
    cmp rax, -1
    je 92f
    call near_ms
92: call dview_anim_due         # the spinners' next step
    cmp eax, -1
    je 921f
    call near_ms
921: cmp qword ptr [rip + cq + SB_len], 0
    je 93f
    mov eax, 50                 # a compound's next configuration
    call near_ms
93: mov rax, r13
    EPILOGUE
# near_deadline: r13 = min(r13, [r15] - now) for a set deadline
near_deadline:
    mov rax, [r15]
    test rax, rax
    jz 1f
    sub rax, r14
    jns 2f
    xor eax, eax
2:  jmp near_ms
1:  ret
# near_ms: r13 = min(r13, rax)
near_ms:
    cmp r13, -1
    je 1f
    cmp rax, r13
    jae 2f
1:  mov r13, rax
2:  ret

# deadlines(ds): initialize's, Stop's steps, a kill after disconnect, requests that timed out
deadlines:
    PROLOGUE
    mov rbx, rdi
    call time_ms
    mov r12, rax
    mov rax, [rbx + DS_deadline]
    test rax, rax
    jz 3f
    cmp r12, rax
    jb 3f
    mov qword ptr [rbx + DS_deadline], 0
    cmp dword ptr [rbx + DS_state], DSS_INITIALIZING
    jne 1f
    mov rdi, rbx
    lea rsi, [rip + .Lm_init_timeout]
    call ds_fail
    EPILOGUE
1:  cmp dword ptr [rbx + DS_stopstep], 0
    je 2f
    mov rdi, rbx
    call stop_step
    EPILOGUE
2:  # disconnect went out (after terminated, or a failed launch): it should have exited by now
    mov rdi, rbx
    xor esi, esi
    call ds_end
    EPILOGUE
3:  # requests: 10 s
    xor r13d, r13d
4:  cmp r13d, [rbx + DS_npend]
    jae 9f
    mov eax, r13d
    imul rax, rax, PD_SIZE
    lea r14, [rbx + DS_pend + rax]
    mov eax, [r14 + PD_kind]
    cmp eax, RQ_LAUNCH          # launch waits as long as the program builds
    je 5f
    cmp eax, RQ_RESUME
    je 5f
    mov rax, [r14 + PD_sent]
    add rax, DAP_REQ_MS
    cmp r12, rax
    jb 5f
    mov esi, [r14 + PD_seq]
    mov rdi, rbx
    call pend_take
    mov rdi, rbx
    mov rsi, rax
    call on_timeout
    jmp 4b
5:  inc r13d
    jmp 4b
9:  EPILOGUE

# on_timeout(ds, pd): a request that got no answer in 10 s
on_timeout:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + PD_kind]
    cmp eax, RQ_SETBP
    jne 1f
    mov rdi, [r12 + PD_ctx]
    call mem_free
1:  cmp eax, RQ_VARIABLES
    jne 2f
    mov eax, [r12 + PD_epoch]
    cmp eax, [rbx + DS_epoch]
    jne 2f
    mov eax, [r12 + PD_ctx + 4]
    cmp eax, [rbx + DS_vgen]
    jne 2f
    mov rdi, rbx
    mov esi, [r12 + PD_ctx]
    call vn_node
    and dword ptr [rax + VN_flags], ~VNF_LOADING
    or dword ptr [rax + VN_flags], VNF_ERROR
2:  # configuration answers count down even when they time out
    mov eax, [r12 + PD_kind]
    cmp eax, RQ_SETBP
    je 3f
    cmp eax, RQ_SETFBP
    je 3f
    cmp eax, RQ_SETEXC
    jne 4f
3:  mov rdi, rbx
    call cfg_answered
4:  mov edi, [rbx + DS_id]
    mov esi, DCON_ERROR
    lea rdx, [rip + .Lm_req_timeout]
    mov ecx, .Lm_req_timeout_end - .Lm_req_timeout
    call dcon_line
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# connect_tick(ds): a tcp adapter or a server is tried every 100 ms for 10 s; a tcp adapter that
#   exits meanwhile (its output and error output closed) ends the session with its last words
connect_tick:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + DS_rcopy], 0
    je 11f
    call copy_tick              # nothing started yet: its extension's folder goes to the host first
    EPILOGUE
11: cmp dword ptr [rbx + DS_transport], DTR_TCP
    jne 1f
    cmp dword ptr [rbx + DS_aout], 0
    jge 1f
    cmp dword ptr [rbx + DS_err], 0
    jge 1f
    cmp qword ptr [rbx + DS_exited_at], 0
    jne 10f
    call time_ms
    mov [rbx + DS_exited_at], rax
10: mov rdi, rbx
    call adapter_gone
    EPILOGUE
1:  call time_ms
    mov r12, rax
    cmp r12, [rbx + DS_deadline]
    jb 9f
    mov rdi, rbx
    call dap_connect_try
    test eax, eax
    jg 5f
    js 7f
    cmp r12, [rbx + DS_conn_until]
    jae 6f
    lea rax, [r12 + DAP_CONNECT_EVERY]
    mov [rbx + DS_deadline], rax
9:  EPILOGUE
5:  # connected: initialize went out just now
    mov dword ptr [rbx + DS_state], DSS_INITIALIZING
    lea rax, [r12 + DAP_INIT_MS]
    mov [rbx + DS_deadline], rax
    xor ecx, ecx
51: cmp ecx, [rbx + DS_npend]
    jae 52f
    mov eax, ecx
    imul rax, rax, PD_SIZE
    mov [rbx + DS_pend + rax + PD_sent], r12
    inc ecx
    jmp 51b
52: mov dword ptr [rip + g_dirty], 1
    inc dword ptr [rip + g_dap_gen]
    EPILOGUE
6:  # "the debugger did not accept a connection on 127.0.0.1:PORT in 10 s"
    lea rdi, [rip + dlg_text]
    lea rsi, [rip + .Lm_noconn]
    call cstr_copy
    mov rdi, rax
    mov esi, [rbx + DS_addr]
    mov edx, [rbx + DS_port]
    call fmt_addr
    lea rsi, [rip + .Lm_noconn2]
    mov rdi, rax
    call cstr_copy
    mov rdi, rbx
    lea rsi, [rip + dlg_text]
    call ds_fail
    EPILOGUE
7:  mov rdi, rbx
    lea rsi, [rip + .Lm_nosocket]
    call ds_fail
    EPILOGUE

# fmt_addr(dst, IPv4 address in network order, port) -> rax the end (NUL-terminated): A.B.C.D:PORT
fmt_addr:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    xor r14d, r14d
1:  mov rdi, rbx
    movzx esi, r12b
    call fmt_u64
    add rbx, rax
    shr r12d, 8
    inc r14d
    mov byte ptr [rbx], '.'
    cmp r14d, 4
    jb 2f
    mov byte ptr [rbx], ':'
2:  inc rbx
    cmp r14d, 4
    jb 1b
    mov rdi, rbx
    mov esi, r13d
    call fmt_u64
    add rbx, rax
    mov byte ptr [rbx], 0
    mov rax, rbx
    EPILOGUE

# server_addr(cstr) -> eax the port (0 when it does not parse), edx the IPv4 address in network
#   order: "PORT", "HOST:PORT" with HOST localhost or A.B.C.D
server_addr:
    PROLOGUE
    mov rbx, rdi
    mov r12d, DAP_LOOPBACK
    # a colon: the host comes first
    mov rax, rbx
10: movzx ecx, byte ptr [rax]
    test ecx, ecx
    jz 5f
    cmp ecx, ':'
    je 11f
    inc rax
    jmp 10b
11: mov r13, rax                # the colon
    mov r14, rax
    sub r14, rbx                # the host's length
    cmp r14, 9
    jne 1f
    mov rdi, rbx
    lea rsi, [rip + .Ls_localhost]
    mov rdx, 9
    call memeq
    test eax, eax
    jnz 4f
1:  # four decimal numbers up to 255 separated by dots
    xor r12d, r12d
    xor r15d, r15d              # the part
2:  xor eax, eax
    xor ecx, ecx                # digits
3:  cmp rbx, r13
    jae 31f
    movzx edx, byte ptr [rbx]
    cmp edx, '.'
    je 31f
    sub edx, '0'
    cmp edx, 9
    ja .Lsa_bad
    imul eax, eax, 10
    add eax, edx
    cmp eax, 255
    ja .Lsa_bad
    inc ecx
    inc rbx
    jmp 3b
31: test ecx, ecx
    jz .Lsa_bad
    mov ecx, r15d
    shl ecx, 3
    shl eax, cl
    or r12d, eax
    inc r15d
    cmp rbx, r13
    jae 32f
    inc rbx                     # the dot
    cmp r15d, 4
    jb 2b
    jmp .Lsa_bad
32: cmp r15d, 4
    jne .Lsa_bad
4:  lea rbx, [r13 + 1]
5:  # the port: 1..65535
    xor eax, eax
    xor ecx, ecx
6:  movzx edx, byte ptr [rbx]
    test edx, edx
    jz 7f
    sub edx, '0'
    cmp edx, 9
    ja .Lsa_bad
    imul eax, eax, 10
    add eax, edx
    cmp eax, 65535
    ja .Lsa_bad
    inc ecx
    inc rbx
    jmp 6b
7:  test ecx, ecx
    jz .Lsa_bad
    mov edx, r12d
    EPILOGUE
.Lsa_bad:
    xor eax, eax
    xor edx, edx
    EPILOGUE

# ---------------- ending ----------------

# ds_fail(ds, reason cstr): the session ends with an error the console and a toast show
ds_fail:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call dap_error
    mov rdi, rbx
    mov rsi, r12
    call ds_end
    add rsp, 8
    pop r12
    pop rbx
    ret

# ds_end(ds, reason cstr or 0): the session is over: pipes closed, the adapter's group told to stop
#   (SIGKILL follows in 1 s), what sessions reported about breakpoints dropped
ds_end:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [rbx + DS_state], DSS_ENDED
    je 9f
    mov dword ptr [rbx + DS_state], DSS_ENDED
    mov qword ptr [rbx + DS_deadline], 0
    mov dword ptr [rbx + DS_stopstep], 0
    test r12, r12
    jnz 1f
    # a normal end: the program exited, or the debugging was ended
    lea r12, [rip + .Lm_terminated]
    test dword ptr [rbx + DS_flags], DSF_EXITED
    jz 1f
    lea r12, [rip + .Lm_exited_reason]
1:  lea rdi, [rbx + DS_reason]
    mov rsi, r12
    call ds_set_cstr
    mov rdi, rbx
    call dap_close_fds
    mov rdi, rbx
    call pend_clear
    mov edi, [rbx + DS_pid]
    test edi, edi
    jz 2f
    # the adapter's group: SIGTERM now, SIGKILL in 1 s, reaped by uproc
    mov esi, 1000
    call uproc_end
    mov dword ptr [rbx + DS_pid], 0
2:  mov rdi, rbx
    call slot_index
    mov edi, eax
    call bp_session_gone
    call dview_rtc_clear
    or dword ptr [rbx + DS_flags], DSF_STALE
    # debug-start: an answer still owed is an error; a session it was told of has ended
    mov rdi, [rbx + DS_owner]
    test rdi, rdi
    jz 3f
    mov rsi, [rbx + DS_owner_id]
    test rsi, rsi
    jz 21f
    mov rdx, r12
    call dbgx_reply_failed
    mov qword ptr [rbx + DS_owner_id], 0
    jmp 3f
21: cmp dword ptr [rbx + DS_owner_ok], 0
    je 3f
    mov esi, [rbx + DS_id]
    mov edx, [rbx + DS_exit]
    test dword ptr [rbx + DS_flags], DSF_EXITED
    jnz 22f
    mov edx, -1
22: call dbgx_ended
3:  # after = TASK, unless rhun quits
    mov rdi, [rbx + DS_after]
    test rdi, rdi
    jz 4f
    cmp dword ptr [rip + dap_quitting], 0
    jne 31f
    xor esi, esi
    xor edx, edx
    call tasks_run_named
31: mov rdi, [rbx + DS_after]
    call mem_free
    mov qword ptr [rbx + DS_after], 0
4:  # its child sessions (startDebugging) end with it
    xor r13d, r13d
41: cmp r13d, DS_MAX
    jae 43f
    mov edi, r13d
    call dap_slot
    inc r13d
    mov ecx, [rax + DS_parent]
    cmp ecx, [rbx + DS_id]
    jne 41b
    cmp dword ptr [rax + DS_state], DSS_FREE
    je 41b
    cmp dword ptr [rax + DS_state], DSS_ENDED
    je 41b
    mov rdi, rax
    call dap_stop_session
    jmp 41b
43: # the console says so
    mov edi, [rbx + DS_id]
    mov esi, DCON_INFO
    lea rdx, [rip + .Lm_ended]
    mov ecx, .Lm_ended_end - .Lm_ended
    call dcon_line
    mov dword ptr [rip + g_dirty], 1
    inc dword ptr [rip + g_dap_gen]
9:  EPILOGUE

# reap(ds): an adapter that exited before its session ended left its process group: SIGKILL to it
#   when SIGTERM's second is up (uproc_end looks after adapters still running)
reap:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + DS_pgrp], 0
    je 9f
    mov rax, [rbx + DS_killat]
    test rax, rax
    jz 9f
    mov r12, rax
    call time_ms
    cmp rax, r12
    jb 9f
    mov edi, [rbx + DS_pgrp]
    neg edi
    mov esi, SIGKILL
    call proc_kill
    mov dword ptr [rbx + DS_pgrp], 0
    mov qword ptr [rbx + DS_killat], 0
9:  EPILOGUE

# adapter_gone(ds): its output closed. After terminated or disconnect that is the normal end; before,
#   it crashed: the reason names its exit code and its last error lines
adapter_gone:
    PROLOGUE
    mov rbx, rdi
    test dword ptr [rbx + DS_flags], DSF_TERMINATED | DSF_DISCONNECT
    jz 1f
    mov rdi, rbx
    xor esi, esi
    call ds_end
    EPILOGUE
1:  # its exit code, once it has exited (half a second at most after its output closed)
    mov r13d, -1
    mov edi, [rbx + DS_pid]
    test edi, edi
    jz 11f
    mov esi, 1
    call uproc_wait
    cmp eax, -1
    je 10f
    mov r13d, eax               # its code, or -2: reaped elsewhere; not ours to wait for either way
    jmp 12f
10: call time_ms
    sub rax, [rbx + DS_exited_at]
    cmp rax, 500
    jb 9f                       # the next frame looks again
    jmp 11f
12: # reaped: what it started is still its group's: SIGTERM now, SIGKILL in 1 s (reap)
    mov edi, [rbx + DS_pid]
    mov [rbx + DS_pgrp], edi
    mov dword ptr [rbx + DS_pid], 0
    neg edi
    mov esi, SIGTERM
    call proc_kill
    call time_ms
    add rax, 1000
    mov [rbx + DS_killat], rax
11: lea rdi, [rip + dlg_text]
    lea rsi, [rip + .Lm_crash]
    call cstr_copy
    mov r12, rax
    test r13d, r13d
    js 3f
    cmp dword ptr [rbx + DS_pid], 0
    jne 3f
    mov rdi, r12
    lea rsi, [rip + .Lm_exitcode]
    call cstr_copy
    mov r12, rax
    mov rdi, rax
    mov esi, r13d
    call fmt_u64
    add r12, rax
    mov byte ptr [r12], ')'
    inc r12
    mov byte ptr [r12], 0
3:  # the last error lines, in the console already; the reason names the last one
    mov rsi, [rbx + DS_etail + SB_ptr]
    mov rdx, [rbx + DS_etail + SB_len]
    test rdx, rdx
    jz 5f
    dec rdx                     # its last newline
    mov rcx, rdx
4:  test rcx, rcx
    jz 41f
    cmp byte ptr [rsi + rcx - 1], 10
    je 41f
    dec rcx
    jmp 4b
41: lea rsi, [rsi + rcx]
    sub rdx, rcx
    mov byte ptr [r12], ':'
    mov byte ptr [r12 + 1], ' '
    lea rdi, [r12 + 2]
    mov rcx, rdx
    lea rdx, [rip + dlg_text + 1900]
    call memcpy_max
5:  mov rdi, rbx
    lea rsi, [rip + dlg_text]
    call ds_fail
9:  EPILOGUE

# ---------------- Stop ----------------

# dap_stop(): Stop on the focused session; a second press goes to the next step at once
FN dap_stop
    sub rsp, 8
    call dbgx_resolve_cancel    # Stop while the extension prepares the launch withdraws it
    add rsp, 8
    test eax, eax
    jnz 1f
    call dap_focused
    test rax, rax
    jz 1f
    mov rdi, rax
    jmp dap_stop_session
1:  ret

# dap_stop_session(ds)
FN dap_stop_session
    PROLOGUE
    mov rbx, rdi
    mov eax, [rbx + DS_state]
    cmp eax, DSS_ENDED
    je 9f
    test eax, eax
    jz 9f
    cmp eax, DSS_APPROVAL
    jne 1f
    # the question goes away unanswered
    mov edi, [rbx + DS_id]
    call run_approve_cancel
    mov rdi, rbx
    lea rsi, [rip + .Lm_cancelled]
    call ds_end
    EPILOGUE
1:  mov rdi, rbx
    call stop_step
9:  EPILOGUE

# stop_step(ds): the next step of Stop. Launch: terminate (when supported, 3 s), disconnect with
#   terminateDebuggee (2 s), then the adapter's process group is killed. Attach: disconnect leaving
#   the program running (2 s), then the kill.
stop_step:
    PROLOGUE
    mov rbx, rdi
    inc dword ptr [rbx + DS_stopstep]
    cmp dword ptr [rbx + DS_in], 0
    jl .Lss_kill                # its input is gone: nothing can be asked
    mov eax, [rbx + DS_stopstep]
    cmp dword ptr [rbx + DS_request], 0
    jne .Lss_attach
    cmp eax, 1
    jne 2f
    test qword ptr [rbx + DS_caps], CAP_TERMINATE
    jz 11f
    test dword ptr [rbx + DS_flags], DSF_TERMINATED
    jnz 11f
    cmp dword ptr [rbx + DS_state], DSS_INITIALIZING
    je 11f
    mov rdi, rbx
    lea rsi, [rip + .Lc_terminate]
    call dap_req_begin
    mov rdi, rbx
    mov esi, RQ_TERMINATE
    xor edx, edx
    call dap_req_send
    mov eax, 3000
    jmp .Lss_wait
11: inc dword ptr [rbx + DS_stopstep]
    mov eax, 2
2:  cmp eax, 2
    jne .Lss_kill
    mov rdi, rbx
    mov esi, 1
    call send_disconnect
    mov eax, 2000
    jmp .Lss_wait
.Lss_attach:
    cmp eax, 1
    jne .Lss_kill
    mov rdi, rbx
    xor esi, esi
    call send_disconnect
    mov eax, 2000
.Lss_wait:
    mov r12, rax
    call time_ms
    add rax, r12
    mov [rbx + DS_deadline], rax
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    je 3f
    cmp dword ptr [rbx + DS_state], DSS_RUNNING
    jne 4f
3:  mov dword ptr [rbx + DS_state], DSS_TERMINATING
4:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE
.Lss_kill:
    mov rdi, rbx
    lea rsi, [rip + .Lm_stopped]
    call ds_end
    EPILOGUE

# send_disconnect(ds, terminate debuggee)
send_disconnect:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    test dword ptr [rbx + DS_flags], DSF_DISCONNECT
    jnz 9f
    or dword ptr [rbx + DS_flags], DSF_DISCONNECT
    mov rdi, rbx
    lea rsi, [rip + .Lc_disconnect]
    call dap_req_begin
    lea rdi, [rip + .Lk_terminateDebuggee]
    mov esi, r12d
    call akb
    mov rdi, rbx
    mov esi, RQ_DISCONNECT
    xor edx, edx
    call dap_req_send
9:  EPILOGUE

# dap_shutdown(): rhun quits: disconnect every session (300 ms in all), then their groups are killed
FN dap_shutdown
    PROLOGUE
    mov dword ptr [rip + dap_quitting], 1
    xor r12d, r12d
    xor r13d, r13d              # any disconnect sent
1:  cmp r12d, DS_MAX
    jae 2f
    mov edi, r12d
    call dap_slot
    mov rbx, rax
    mov eax, [rbx + DS_state]
    test eax, eax
    jz 11f
    cmp eax, DSS_ENDED
    je 11f
    cmp dword ptr [rbx + DS_in], 0
    jl 11f
    mov rdi, rbx
    mov esi, 1
    cmp dword ptr [rbx + DS_request], 0
    je 12f
    xor esi, esi
12: call send_disconnect
    mov r13d, 1
11: inc r12d
    jmp 1b
2:  test r13d, r13d
    jz 4f
    call time_ms
    lea r14, [rax + 300]
3:  call time_ms
    cmp rax, r14
    jae 4f
    mov edi, 20
    call loop_poll
    call dap_tick
    call dap_live_count
    test eax, eax
    jnz 3b
4:  # whatever is left is killed
    xor r12d, r12d
5:  cmp r12d, DS_MAX
    jae 9f
    mov edi, r12d
    call dap_slot
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_FREE
    je 6f
    mov rdi, rbx
    xor esi, esi
    call ds_end                 # uproc_end: its quit kills what is left
    mov edi, [rbx + DS_pgrp]    # and a group an exited adapter left
    test edi, edi
    jz 6f
    neg edi
    mov esi, SIGKILL
    call proc_kill
    mov dword ptr [rbx + DS_pgrp], 0
6:  inc r12d
    jmp 5b
9:  EPILOGUE

# ---------------- messages ----------------

# on_message(ds, root): a response, an event or a reverse request
on_message:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Lk_type]
    call json_get
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lv_response]
    call json_is
    test eax, eax
    jz 1f
    mov rdi, rbx
    mov rsi, r12
    call on_response
    jmp 9f
1:  mov rdi, r13
    lea rsi, [rip + .Lv_event]
    call json_is
    test eax, eax
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    call on_event
    jmp 9f
2:  mov rdi, r13
    lea rsi, [rip + .Lv_request]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call on_reverse
9:  mov dword ptr [rip + g_dirty], 1
    inc dword ptr [rip + g_dap_gen]
    EPILOGUE

# jkey(obj, key cstr) -> JV* (json_get)
jkey:
    jmp json_get

# jint(obj, key cstr) -> rax value, edx 1 when present and an integer
jint:
    push rbx
    call json_get
    mov rdi, rax
    call json_int
    pop rbx
    ret

# jbool(obj, key cstr) -> eax 1 only for true
jbool:
    push rbx
    call json_get
    mov rdi, rax
    call json_bool
    pop rbx
    ret

# jstr(obj, key cstr) -> rax ptr, rdx len (0, 0 when missing or not a string)
jstr:
    push rbx
    call json_get
    mov rdi, rax
    call json_str
    pop rbx
    ret

# on_response(ds, root)
on_response:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Lk_request_seq]
    call jint
    test edx, edx
    jz 9f
    mov rdi, rbx
    mov esi, eax
    call pend_take
    test rax, rax
    jz 9f                       # late or unknown: dropped
    mov r13, rax                # &pd
    mov rdi, r12
    lea rsi, [rip + .Lk_success]
    call jbool
    mov r14d, eax
    mov rdi, r12
    lea rsi, [rip + .Lk_body]
    call json_get
    mov r15, rax
    mov eax, [r13 + PD_kind]
    lea rcx, [rip + resp_table]
    mov rax, [rcx + rax*8]
    test rax, rax
    jz 9f
    mov rdi, rbx
    mov rsi, r12                # root (for the message)
    mov rdx, r15                # body
    mov ecx, r14d               # success
    mov r8, r13                 # &pd
    call rax
9:  EPILOGUE

# resp_message(root, body) -> rax text, rdx len: body.error.format, else message
resp_message:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_error]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_format]
    call jstr
    test rdx, rdx
    jnz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_message]
    call jstr
    test rdx, rdx
    jnz 9f
    lea rax, [rip + .Lm_failed]
    mov edx, .Lm_failed_end - .Lm_failed
9:  EPILOGUE

# r_initialize(ds, root, body, success, pd): capabilities, then launch or attach
r_initialize:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test ecx, ecx
    jnz 1f
    mov rdi, r12
    mov rsi, r13
    call resp_message
    mov rdi, rbx
    mov rsi, rax
    call fail_text
    EPILOGUE
1:  mov qword ptr [rbx + DS_deadline], 0
    mov rdi, rbx
    mov rsi, r13
    call caps_merge
    mov dword ptr [rbx + DS_state], DSS_CONFIGURING
    mov rdi, rbx
    call send_launch
    EPILOGUE

# fail_text(ds, ptr, len): ds_fail with a text that is not NUL-terminated
fail_text:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + dlg_text]
    lea r8, [rip + dlg_text + 1900]
    mov rcx, rdx
    mov rdx, r8
    call memcpy_max
    mov rdi, rbx
    lea rsi, [rip + dlg_text]
    call ds_fail
    EPILOGUE

# caps_merge(ds, capabilities object): its supports* flags and exception filters
caps_merge:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 9f
    lea r13, [rip + cap_names]
1:  mov rsi, [r13]
    test rsi, rsi
    jz 2f
    mov rdi, r12
    call jbool
    test eax, eax
    jz 11f
    mov rax, [r13 + 8]
    or [rbx + DS_caps], rax
11: add r13, 16
    jmp 1b
2:  mov rdi, r12
    lea rsi, [rip + .Lk_exceptionBreakpointFilters]
    call json_get
    test rax, rax
    jz 9f
    mov r13, rax
    lea rdi, [rbx + DS_filters]
    call sb_clear
    xor r14d, r14d
3:  mov rdi, r13
    mov esi, r14d
    call json_at
    test rax, rax
    jz 9f
    mov r15, rax
    mov rdi, r15
    lea rsi, [rip + .Lk_filter]
    call jstr
    test rdx, rdx
    jz 4f
    lea rdi, [rbx + DS_filters]
    mov rsi, rax
    call sb_push_clean
    lea rdi, [rbx + DS_filters]
    mov esi, 9
    call sb_push_byte
    mov rdi, r15
    lea rsi, [rip + .Lk_label]
    call jstr
    lea rdi, [rbx + DS_filters]
    mov rsi, rax
    call sb_push_clean
    lea rdi, [rbx + DS_filters]
    mov esi, 9
    call sb_push_byte
    mov rdi, r15
    lea rsi, [rip + .Lk_default]
    call jbool
    lea esi, [rax + '0']
    lea rdi, [rbx + DS_filters]
    call sb_push_byte
    lea rdi, [rbx + DS_filters]
    mov esi, 10
    call sb_push_byte
4:  inc r14d
    cmp r14d, 64
    jb 3b
9:  EPILOGUE

# sb_push_clean(sb, ptr, len): bytes without tabs, newlines or other control bytes (as spaces)
sb_push_clean:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
1:  test r13, r13
    jz 9f
    movzx esi, byte ptr [r12]
    cmp esi, 0x20
    jae 2f
    mov esi, ' '
2:  mov rdi, rbx
    call sb_push_byte
    inc r12
    dec r13
    jmp 1b
9:  EPILOGUE

# r_launch(ds, root, body, success, pd): a failed launch ends the session (lldb-dap keeps answering
#   after one, so rhun ends it: disconnect, and the kill 2 s later)
r_launch:
    PROLOGUE
    mov rbx, rdi
    test ecx, ecx
    jz 1f
    or dword ptr [rbx + DS_flags], DSF_LAUNCHED
    test dword ptr [rbx + DS_flags], DSF_CONFIGDONE
    jz 9f
    cmp dword ptr [rbx + DS_state], DSS_CONFIGURING
    jne 9f
    mov dword ptr [rbx + DS_state], DSS_RUNNING
    jmp 9f
1:  mov rdi, rsi
    mov rsi, rdx
    call resp_message
    mov r12, rax
    mov r13, rdx
    lea rdi, [rip + dlg_text]
    lea rsi, [rip + .Lm_launch_failed]
    call cstr_copy
    mov rdi, rax
    mov rsi, r12
    mov rcx, r13
    lea rdx, [rip + dlg_text + 1900]
    call memcpy_max
    lea rdi, [rip + dlg_text]
    call dap_error
    lea rdi, [rbx + DS_reason]
    lea rsi, [rip + dlg_text]
    call ds_set_cstr
    mov rdi, rbx
    mov esi, 1
    call send_disconnect
    call time_ms
    add rax, 2000
    mov [rbx + DS_deadline], rax
    mov dword ptr [rbx + DS_state], DSS_TERMINATING
9:  EPILOGUE

# r_config(ds, root, body, success, pd): setBreakpoints, setFunctionBreakpoints, setExceptionBreakpoints
r_config:
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    mov r13d, ecx
    mov r14, r8
    cmp dword ptr [r14 + PD_kind], RQ_SETBP
    jne 1f
    mov rdi, rbx
    mov rsi, [r14 + PD_ctx]
    mov rdx, r12
    mov ecx, r13d
    call bp_on_set
    mov rdi, [r14 + PD_ctx]
    call mem_free
1:  mov rdi, rbx
    call cfg_answered
    EPILOGUE

# cfg_answered(ds): one configuration answer fewer to wait for; at none, configurationDone
cfg_answered:
    test dword ptr [rdi + DS_flags], DSF_CONFIGDONE
    jnz 1f
    cmp dword ptr [rdi + DS_cfgwait], 0
    je 1f
    dec dword ptr [rdi + DS_cfgwait]
    jnz 1f
    jmp config_done
1:  ret

# config_done(ds): configurationDone (when the adapter wants it); the program runs
config_done:
    PROLOGUE
    mov rbx, rdi
    or dword ptr [rbx + DS_flags], DSF_CONFIGDONE
    test qword ptr [rbx + DS_caps], CAP_CONFIGDONE
    jz 1f
    mov rdi, rbx
    lea rsi, [rip + .Lc_configurationDone]
    call dap_req_begin
    mov rdi, rbx
    mov esi, RQ_CONFIGDONE
    xor edx, edx
    call dap_req_send
1:  cmp dword ptr [rbx + DS_state], DSS_CONFIGURING
    jne 9f
    mov dword ptr [rbx + DS_state], DSS_RUNNING
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# r_none(ds, root, body, success, pd): answers with nothing to do but report a failure
r_none:
    PROLOGUE
    mov rbx, rdi
    test ecx, ecx
    jnz 9f
    mov rdi, rsi
    mov rsi, rdx
    call resp_message
    mov rcx, rdx
    mov rdx, rax
    mov edi, [rbx + DS_id]
    mov esi, DCON_ERROR
    call dcon_line
9:  EPILOGUE

# r_resume(ds, root, body, success, pd): continue, next, stepIn or stepOut refused: the program is
#   still paused there; the stack is asked for again (its references were given up)
r_resume:
    PROLOGUE
    mov rbx, rdi
    test ecx, ecx
    jnz 9f
    mov rdi, rsi
    mov rsi, rdx
    call resp_message
    mov rcx, rdx
    mov rdx, rax
    mov edi, [rbx + DS_id]
    mov esi, DCON_ERROR
    call dcon_line
    cmp dword ptr [rbx + DS_state], DSS_RUNNING
    jne 9f
    mov rdi, rbx
    call new_epoch
    mov dword ptr [rbx + DS_state], DSS_PAUSED
    and dword ptr [rbx + DS_flags], ~DSF_STALE
    mov rdi, rbx
    lea rsi, [rip + .Lc_threads]
    call dap_req_begin
    mov rdi, rbx
    mov esi, RQ_THREADS
    mov edx, 1
    call dap_req_send
    cmp qword ptr [rbx + DS_thread], 0
    je 9f
    mov rdi, rbx
    mov esi, 1
    call send_stack
9:  EPILOGUE

# r_disconnect(ds, ...): the adapter should exit now; it gets 2 s
r_disconnect:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + DS_stopstep], 0
    jne 9f                      # Stop's own step deadline stands
    call time_ms
    add rax, 2000
    mov [rbx + DS_deadline], rax
9:  EPILOGUE

# ---------------- events ----------------

# on_event(ds, root)
on_event:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Lk_event]
    call jstr
    test rdx, rdx
    jz 9f
    mov r13, rax
    mov r14, rdx
    mov rdi, r12
    lea rsi, [rip + .Lk_body]
    call json_get
    mov r15, rax
    lea r12, [rip + event_table]
1:  mov rdx, [r12]
    test rdx, rdx
    jz 9f
    mov rdi, r13
    mov rsi, r14
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add r12, 16
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r15
    call [r12 + 8]
9:  EPILOGUE

# e_initialized(ds, body): breakpoints, function breakpoints and exception filters, then
#   configurationDone once all are answered
e_initialized:
    PROLOGUE
    mov rbx, rdi
    test dword ptr [rbx + DS_flags], DSF_INITIALIZED
    jnz 9f
    or dword ptr [rbx + DS_flags], DSF_INITIALIZED
    mov dword ptr [rbx + DS_cfgwait], 0
    cmp dword ptr [rbx + DS_nodebug], 0
    jne 2f
    mov rdi, rbx
    call bp_send_all            # -> eax requests sent
    add [rbx + DS_cfgwait], eax
    mov rdi, rbx
    call send_exc_filters
    add [rbx + DS_cfgwait], eax
2:  cmp dword ptr [rbx + DS_cfgwait], 0
    jne 9f
    mov rdi, rbx
    call config_done
9:  EPILOGUE

# send_exc_filters(ds) -> eax 1 when setExceptionBreakpoints went out (the adapter lists filters)
FN send_exc_filters
    PROLOGUE
    mov rbx, rdi
    cmp qword ptr [rbx + DS_filters + SB_len], 0
    je 8f
    mov rdi, rbx
    lea rsi, [rip + .Lc_setExceptionBreakpoints]
    call dap_req_begin
    lea rdi, [rip + .Lk_filters]
    call ak
    lea rdi, [rip + g_dmsg]
    call jw_arr
    mov r12, [rbx + DS_filters + SB_ptr]
    mov r13, [rbx + DS_filters + SB_len]
    add r13, r12
1:  cmp r12, r13
    jae 5f
    # FILTER \t LABEL \t DEFAULT \n
    mov rcx, r12
2:  cmp byte ptr [rcx], 9
    je 3f
    inc rcx
    jmp 2b
3:  mov r14, rcx
    sub r14, r12                # the filter's length
    mov r15, rcx
4:  cmp byte ptr [r15], 10
    je 41f
    inc r15
    jmp 4b
41: movzx eax, byte ptr [r15 - 1]   # the default
    sub eax, '0'
    push rax
    push rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call exc_enabled
    pop rcx
    pop rcx
    cmp eax, -1
    jne 42f
    mov eax, ecx                # not chosen: the adapter's default
42: test eax, eax
    jz 43f
    lea rdi, [rip + g_dmsg]
    mov rsi, r12
    mov rdx, r14
    call jw_str
43: lea r12, [r15 + 1]
    jmp 1b
5:  lea rdi, [rip + g_dmsg]
    call jw_end_arr
    mov rdi, rbx
    mov esi, RQ_SETEXC
    xor edx, edx
    call dap_req_send
    test eax, eax
    setnz al
    movzx eax, al
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# e_stopped(ds, body): a new stop: the threads, the stack of the stopped thread, its first frame
#   with a source revealed, its scopes and variables, the watches
e_stopped:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call new_epoch
    mov dword ptr [rbx + DS_state], DSS_PAUSED
    and dword ptr [rbx + DS_flags], ~DSF_STALE
    call dview_rtc_clear        # Run to Cursor's breakpoint: its work is done
    call dap_focused            # the session that stopped takes the focus from one that is not paused
    test rax, rax               #   (js-debug's launcher runs on while its child session stops)
    jz 1f
    cmp dword ptr [rax + DS_state], DSS_PAUSED
    je 2f
1:  mov rdi, rbx
    call slot_index
    mov edi, eax
    call dap_focus_slot
2:
    mov rdi, r12
    lea rsi, [rip + .Lk_reason]
    call jstr
    lea rdi, [rbx + DS_reason]
    mov rsi, rax
    call ds_set_str
    mov rdi, r12
    lea rsi, [rip + .Lk_description]
    call jstr
    test rdx, rdx
    jnz 1f
    mov rdi, r12
    lea rsi, [rip + .Lk_text]
    call jstr
1:  lea rdi, [rbx + DS_desc]
    mov rsi, rax
    call ds_set_str
    and dword ptr [rbx + DS_flags], ~DSF_TNAMED
    mov rdi, r12
    lea rsi, [rip + .Lk_threadId]
    call jint
    test edx, edx
    jz 2f
    mov [rbx + DS_thread], rax
    or dword ptr [rbx + DS_flags], DSF_TNAMED
2:  mov rdi, r12
    lea rsi, [rip + .Lk_preserveFocusHint]
    call jbool
    mov [rsp], eax
    mov rdi, rbx
    lea rsi, [rip + .Lc_threads]
    call dap_req_begin
    mov rdi, rbx
    mov esi, RQ_THREADS
    mov edx, [rsp]
    call dap_req_send
    cmp qword ptr [rbx + DS_thread], 0
    je 3f
    mov rdi, rbx
    mov esi, [rsp]
    call send_stack
3:  # an exception: its id and description
    mov rdi, r12
    lea rsi, [rip + .Lk_reason]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_exception]
    call json_is
    test eax, eax
    jz 9f
    test qword ptr [rbx + DS_caps], CAP_EXCINFO
    jz 9f
    cmp qword ptr [rbx + DS_thread], 0
    je 9f
    mov rdi, rbx
    lea rsi, [rip + .Lc_exceptionInfo]
    call dap_req_begin
    lea rdi, [rip + .Lk_threadId]
    mov rsi, [rbx + DS_thread]
    call aki
    mov rdi, rbx
    mov esi, RQ_EXCINFO
    xor edx, edx
    call dap_req_send
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# new_epoch(ds): references of the last stop are dead: the pools start again
new_epoch:
    push rbx
    mov rbx, rdi
    cmp qword ptr [rbx + DS_vars + VEC_len], 0
    je 1f
    call snapshot_values        # the last stop's values, for the changed ones
1:  inc dword ptr [rbx + DS_epoch]
    inc dword ptr [rbx + DS_vgen]
    mov qword ptr [rbx + DS_threads + VEC_len], 0
    mov qword ptr [rbx + DS_frames + VEC_len], 0
    mov qword ptr [rbx + DS_vars + VEC_len], 0
    mov dword ptr [rbx + DS_frame], 0
    mov dword ptr [rbx + DS_total_frames], 0
    mov dword ptr [rbx + DS_hasvars], 0
    lea rdi, [rbx + DS_strs]
    call sb_clear
    lea rdi, [rbx + DS_strs]    # offset 0 means "none"
    xor esi, esi
    call sb_push_byte
    pop rbx
    ret

# send_stack(ds, preserve focus): the focused thread's first 20 frames
send_stack:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    lea rsi, [rip + .Lc_stackTrace]
    call dap_req_begin
    lea rdi, [rip + .Lk_threadId]
    mov rsi, [rbx + DS_thread]
    call aki
    lea rdi, [rip + .Lk_startFrame]
    xor esi, esi
    call aki
    lea rdi, [rip + .Lk_levels]
    mov esi, DAP_FRAMES
    call aki
    mov rdi, rbx
    mov esi, RQ_STACK
    mov edx, [rbx + DS_vgen]            # an answer about another thread is dropped
    shl rdx, 32
    or rdx, r12
    call dap_req_send
    EPILOGUE

# e_continued(ds, body): the program runs on, unless the adapter says only another thread did
#   (allThreadsContinued false for a thread that is not the focused one: its stop stays)
e_continued:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_allThreadsContinued]
    call jbool
    test edx, edx
    jz 1f
    test eax, eax
    jnz 1f
    mov rdi, r12
    lea rsi, [rip + .Lk_threadId]
    call jint
    test edx, edx
    jz 1f
    cmp rax, [rbx + DS_thread]
    jne 9f
1:  mov dword ptr [rbx + DS_state], DSS_RUNNING
    inc dword ptr [rbx + DS_epoch]
    or dword ptr [rbx + DS_flags], DSF_STALE
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# e_output(ds, body): to the console by category; telemetry is dropped
e_output:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r14d, DCON_CONSOLE
    mov rdi, r12
    lea rsi, [rip + .Lk_category]
    call json_get
    mov r13, rax
    test r13, r13
    jz 3f
    lea r15, [rip + out_cats]
1:  mov rsi, [r15]
    test rsi, rsi
    jz 3f
    mov rdi, r13
    call json_is
    test eax, eax
    jnz 2f
    add r15, 16
    jmp 1b
2:  mov r14, [r15 + 8]
    test r14d, r14d
    js 9f                       # telemetry
3:  mov rdi, r12
    lea rsi, [rip + .Lk_output]
    call jstr
    test rdx, rdx
    jz 9f
    mov edi, [rbx + DS_id]
    mov esi, r14d
    mov rcx, rdx
    mov rdx, rax
    call dcon_text
9:  EPILOGUE

# e_exited(ds, body): the program's exit code
e_exited:
    PROLOGUE 64
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_exitCode]
    call jint
    test edx, edx
    jz 9f
    mov [rbx + DS_exit], eax
    or dword ptr [rbx + DS_flags], DSF_EXITED
    lea rdi, [rsp]
    lea rsi, [rip + .Lm_exited]
    call cstr_copy
    mov r12, rax
    mov eax, [rbx + DS_exit]
    test eax, eax
    jns 1f
    mov byte ptr [r12], '-'
    inc r12
    neg eax
1:  mov rdi, r12
    mov esi, eax
    call fmt_u64
    add r12, rax
    mov rcx, r12
    lea rdx, [rsp]
    sub rcx, rdx
    mov edi, [rbx + DS_id]
    mov esi, DCON_INFO
    call dcon_line
9:  EPILOGUE

# e_terminated(ds, body): the debugging is over: disconnect, and the adapter gets 2 s to exit
e_terminated:
    PROLOGUE
    mov rbx, rdi
    or dword ptr [rbx + DS_flags], DSF_TERMINATED
    cmp dword ptr [rbx + DS_state], DSS_ENDED
    je 9f
    mov dword ptr [rbx + DS_state], DSS_TERMINATING
    mov rdi, rbx
    mov esi, 1
    cmp dword ptr [rbx + DS_request], 0
    je 1f
    xor esi, esi
1:  call send_disconnect
    cmp dword ptr [rbx + DS_stopstep], 0
    jne 9f
    call time_ms
    add rax, 2000
    mov [rbx + DS_deadline], rax
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# e_thread(ds, body): a thread started or exited. Paused, the list is fetched again at once;
#   running, at the next stop. A first thread is remembered for Pause; one that exited is
#   forgotten (Pause then asks for the list first)
e_thread:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    or dword ptr [rbx + DS_flags], DSF_THREADS
    mov rdi, r12
    lea rsi, [rip + .Lk_threadId]
    call jint
    test edx, edx
    jz 3f
    mov r13, rax
    mov rdi, r12
    lea rsi, [rip + .Lk_reason]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_exited]
    call json_is
    test eax, eax
    jz 2f
    cmp r13, [rbx + DS_thread]
    jne 3f
    and dword ptr [rbx + DS_flags], ~DSF_TNAMED
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    je 3f                       # the stop's stack stays as it came
    mov qword ptr [rbx + DS_thread], 0
    jmp 3f
2:  cmp qword ptr [rbx + DS_thread], 0
    jne 3f
    mov [rbx + DS_thread], r13
3:  cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    mov rdi, rbx
    lea rsi, [rip + .Lc_threads]
    call dap_req_begin
    mov rdi, rbx
    mov esi, RQ_THREADS
    mov edx, 1
    call dap_req_send
9:  EPILOGUE

# e_breakpoint(ds, body): a breakpoint the adapter verified, moved or rejected
e_breakpoint:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_breakpoint]
    call json_get
    test rax, rax
    jz 9f
    mov rsi, rax
    mov rdi, rbx
    call bp_on_event
9:  EPILOGUE

# e_capabilities(ds, body)
e_capabilities:
    push rbx
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_capabilities]
    call json_get
    mov rdi, rbx
    mov rsi, rax
    call caps_merge
    pop rbx
    ret

# ---------------- answers about a stop ----------------

# r_threads(ds, root, body, success, pd)
r_threads:
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    mov r13, r8
    test ecx, ecx
    jz 9f
    mov eax, [r13 + PD_epoch]
    cmp eax, [rbx + DS_epoch]
    jne 9f
    mov qword ptr [rbx + DS_threads + VEC_len], 0
    and dword ptr [rbx + DS_flags], ~DSF_THREADS
    mov rdi, r12
    lea rsi, [rip + .Lk_threads]
    call json_get
    mov r14, rax
    xor r15d, r15d
1:  cmp r15d, DAP_THREADS_MAX
    jae 2f
    mov rdi, r14
    mov esi, r15d
    call json_at
    test rax, rax
    jz 2f
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + .Lk_id]
    call jint
    test edx, edx
    jz 11f
    push rax
    push rax
    lea rdi, [rbx + DS_threads]
    mov esi, THR_SIZE
    call vec_push
    pop rcx
    pop rcx
    mov [rax + THR_id], rcx
    push rax
    push rax
    mov rdi, r12
    lea rsi, [rip + .Lk_name]
    call jstr
    mov rdi, rbx
    mov rsi, rax
    call pool_str
    pop rcx
    pop rcx
    mov [rcx + THR_name], eax
    mov [rcx + THR_namelen], edx
11: inc r15d
    jmp 1b
2:  cmp qword ptr [rbx + DS_thread], 0
    je 20f
    cmp dword ptr [rbx + DS_state], DSS_RUNNING
    jne 23f
    test dword ptr [r13 + PD_ctx], 2        # Pause asked for the list (a thread came meanwhile)
    jz 9f
    mov rdi, rbx
    call send_pause
    jmp 9f
23: mov rax, [rbx + DS_thread]
    # the thread the stop named stays listed, even when the adapter's list leaves it out
    #   (lldb-dap does at a worker thread's first stop)
    test dword ptr [rbx + DS_flags], DSF_TNAMED
    jz 9f
    mov rcx, [rbx + DS_threads + VEC_ptr]
    mov rdx, [rbx + DS_threads + VEC_len]
21: test rdx, rdx
    jz 22f
    cmp rax, [rcx + THR_id]
    je 9f
    add rcx, THR_SIZE
    dec rdx
    jmp 21b
22: mov rdi, rbx
    call thread_add_named
    mov dword ptr [rip + g_dirty], 1
    jmp 9f
20: # no thread named by the stop: the first one
    cmp qword ptr [rbx + DS_threads + VEC_len], 0
    je 9f
    mov rax, [rbx + DS_threads + VEC_ptr]
    mov rax, [rax + THR_id]
    mov [rbx + DS_thread], rax
    cmp dword ptr [rbx + DS_state], DSS_RUNNING
    jne 3f
    test dword ptr [r13 + PD_ctx], 2        # Pause asked for the list
    jz 9f
    mov rdi, rbx
    call send_pause
    jmp 9f
3:  cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    mov rdi, rbx
    mov esi, [r13 + PD_ctx]
    and esi, 1
    call send_stack
9:  EPILOGUE

# thread_add_named(ds): the focused thread appended to the list as "Thread ID"
thread_add_named:
    PROLOGUE 48
    mov rbx, rdi
    lea rdi, [rsp]
    lea rsi, [rip + .Lm_thread]
    call cstr_copy
    mov r12, rax
    mov rdi, rax
    mov rsi, [rbx + DS_thread]
    call fmt_u64
    add r12, rax
    lea rdi, [rbx + DS_threads]
    mov esi, THR_SIZE
    call vec_push
    mov r13, rax
    mov rax, [rbx + DS_thread]
    mov [r13 + THR_id], rax
    mov rdi, rbx
    lea rsi, [rsp]
    mov rdx, r12
    sub rdx, rsi
    call pool_str
    mov [r13 + THR_name], eax
    mov [r13 + THR_namelen], edx
    EPILOGUE

# pool_str(ds, ptr, len) -> eax offset, edx length of a one-line copy in DS_strs (control bytes as
#   U+FFFD, a newline as U+21B5, at most 64 KiB); 0, 0 when the pool is full or the text empty
FN pool_str
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz 8f
    cmp r13, 65536
    jbe 1f
    mov r13d, 65536
1:  mov rax, [rbx + DS_strs + SB_len]
    add rax, r13
    cmp rax, DAP_STRS_MAX
    ja 8f
    mov r14, [rbx + DS_strs + SB_len]
    test r14, r14
    jnz 2f
    lea rdi, [rbx + DS_strs]
    xor esi, esi
    call sb_push_byte
    mov r14d, 1
2:  test r13, r13
    jz 7f
    movzx esi, byte ptr [r12]
    inc r12
    dec r13
    cmp esi, 10
    je 3f
    cmp esi, 9
    je 5f
    cmp esi, 0x20
    jb 4f
    cmp esi, 0x7f
    je 4f
5:  lea rdi, [rbx + DS_strs]
    call sb_push_byte
    jmp 2b
3:  lea rdi, [rbx + DS_strs]
    lea rsi, [rip + .Lnl_glyph]
    mov edx, 3
    call sb_push
    jmp 2b
4:  lea rdi, [rbx + DS_strs]
    lea rsi, [rip + .Lfffd]
    mov edx, 3
    call sb_push
    jmp 2b
7:  mov eax, r14d
    mov rdx, [rbx + DS_strs + SB_len]
    sub rdx, r14
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# r_stack(ds, root, body, success, pd): the focused thread's frames; the first with a source is
#   focused and revealed (unless the stop asked to keep focus), and its scopes are asked for
r_stack:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rdx
    mov r13, r8
    test ecx, ecx
    jz 9f
    mov eax, [r13 + PD_epoch]
    cmp eax, [rbx + DS_epoch]
    jne 9f
    mov eax, [r13 + PD_ctx + 4]
    cmp eax, [rbx + DS_vgen]
    jne 9f
    mov qword ptr [rbx + DS_frames + VEC_len], 0
    mov rdi, r12
    lea rsi, [rip + .Lk_totalFrames]
    call jint
    mov [rbx + DS_total_frames], eax
    mov rdi, r12
    lea rsi, [rip + .Lk_stackFrames]
    call json_get
    mov r14, rax
    xor r15d, r15d
    mov dword ptr [rsp], -1     # the first frame with a source
1:  cmp r15d, 1000
    jae 4f
    mov rdi, r14
    mov esi, r15d
    call json_at
    test rax, rax
    jz 4f
    mov r12, rax
    lea rdi, [rbx + DS_frames]
    mov esi, FR_SIZE
    call vec_push
    mov [rsp + 8], rax
    mov rdi, r12
    lea rsi, [rip + .Lk_id]
    call jint
    mov rcx, [rsp + 8]
    mov [rcx + FR_id], rax
    mov rdi, r12
    lea rsi, [rip + .Lk_name]
    call jstr
    mov rdi, rbx
    mov rsi, rax
    call pool_str
    mov rcx, [rsp + 8]
    mov [rcx + FR_name], eax
    mov [rcx + FR_namelen], edx
    mov rdi, r12
    lea rsi, [rip + .Lk_line]
    call jint
    mov rcx, [rsp + 8]
    mov [rcx + FR_line], eax
    mov rdi, r12
    lea rsi, [rip + .Lk_column]
    call jint
    mov rcx, [rsp + 8]
    mov [rcx + FR_col], eax
    mov rdi, r12
    lea rsi, [rip + .Lk_presentationHint]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_subtle]
    call json_is
    mov rcx, [rsp + 8]
    mov [rcx + FR_hint], eax
    mov rdi, r12
    lea rsi, [rip + .Lk_source]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_path]
    call jstr
    test rdx, rdx
    jz 3f
    mov rdi, rbx
    mov rsi, rax
    call pool_str
    mov rcx, [rsp + 8]
    mov [rcx + FR_path], eax
    mov [rcx + FR_pathlen], edx
    cmp dword ptr [rsp], 0
    jge 3f
    mov [rsp], r15d
3:  inc r15d
    jmp 1b
4:  mov eax, [rsp]
    test eax, eax
    jns 5f
    xor eax, eax
5:  mov [rbx + DS_frame], eax
    cmp dword ptr [r13 + PD_ctx], 0
    jne 6f                      # preserveFocusHint
    mov rdi, rbx
    call reveal_frame
6:  mov rdi, rbx
    call send_scopes
    mov rdi, rbx
    call send_watches
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# frame_ptr(ds) -> FR* of the focused frame, or 0
FN dap_frame_ptr
    mov eax, [rdi + DS_frame]
    cmp rax, [rdi + DS_frames + VEC_len]
    jae 1f
    imul rax, rax, FR_SIZE
    add rax, [rdi + DS_frames + VEC_ptr]
    ret
1:  xor eax, eax
    ret

# dap_pool_z(ds, offset, len) -> rax a NUL-terminated copy (pathz, valid until the next call)
FN dap_pool_z
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    lea rdi, [rip + pathz]
    call sb_clear
    lea rdi, [rip + pathz]
    mov rsi, [rbx + DS_strs + SB_ptr]
    add rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + pathz]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + pathz + SB_ptr]
    EPILOGUE

# reveal_frame(ds): the focused frame's file opened at its line
reveal_frame:
    PROLOGUE
    mov rbx, rdi
    call dap_frame_ptr
    test rax, rax
    jz 9f
    mov r12, rax
    cmp dword ptr [r12 + FR_pathlen], 0
    je 9f
    mov rdi, rbx
    mov esi, [r12 + FR_path]
    mov edx, [r12 + FR_pathlen]
    call dap_pool_z
    mov r13, rax
    mov rdi, rax
    call file_type
    cmp eax, 0x8000
    jne 9f
    mov rdi, r13
    call app_open_file
    test rax, rax
    js 9f
    mov edi, [r12 + FR_line]
    mov esi, [r12 + FR_col]
    test esi, esi
    jnz 1f
    mov esi, 1
1:  call app_goto_line
9:  EPILOGUE

# send_scopes(ds): the focused frame's scopes
send_scopes:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    call dap_frame_ptr
    test rax, rax
    jz 9f
    mov r12, rax
    mov dword ptr [rbx + DS_hasvars], 1
    mov rdi, rbx
    lea rsi, [rip + .Lc_scopes]
    call dap_req_begin
    lea rdi, [rip + .Lk_frameId]
    mov rsi, [r12 + FR_id]
    call aki
    mov rdi, rbx
    mov esi, RQ_SCOPES
    mov edx, [rbx + DS_vgen]            # the pool's generation, and the frame
    shl rdx, 32
    mov eax, [rbx + DS_frame]
    or rdx, rax
    call dap_req_send
9:  EPILOGUE

# vn_node(ds, index) -> VN*
FN vn_node
    mov eax, esi
    imul rax, rax, VN_SIZE
    add rax, [rdi + DS_vars + VEC_ptr]
    ret

# vn_add(ds, parent, depth, item JV, name key cstr, value key cstr) -> eax the new node's index, -1
#   when the pool is full: name, value, type, evaluateName and variablesReference from the item
vn_add:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov r12, rcx
    mov r13, r8
    mov r14, r9
    cmp qword ptr [rbx + DS_vars + VEC_len], DAP_VARS_MAX
    jae 8f
    lea rdi, [rbx + DS_vars]
    mov esi, VN_SIZE
    call vec_push
    mov rax, [rbx + DS_vars + VEC_len]
    dec rax
    mov r15d, eax
    mov rdi, rbx
    mov esi, r15d
    call vn_node
    mov ecx, [rsp]
    mov [rax + VN_parent], ecx
    mov ecx, [rsp + 4]
    mov [rax + VN_depth], ecx
    mov dword ptr [rax + VN_kid0], -1
    mov ecx, [rbx + DS_epoch]
    mov [rax + VN_epoch], ecx
    mov rdi, r12
    lea rsi, [rip + .Lk_variablesReference]
    call jint
    mov [rsp + 8], rax
    mov rdi, rbx
    mov esi, r15d
    call vn_node
    mov rcx, [rsp + 8]
    mov [rax + VN_ref], rcx
    # name, value, type, evaluateName (pool_str never moves the nodes)
    mov rdi, r12
    mov rsi, r13
    call jstr
    mov ecx, VN_name
    call vn_put
    mov rdi, r12
    mov rsi, r14
    call jstr
    mov ecx, VN_value
    call vn_put
    mov rdi, r12
    lea rsi, [rip + .Lk_type]
    call jstr
    mov ecx, VN_type
    call vn_put
    mov rdi, r12
    lea rsi, [rip + .Lk_evaluateName]
    call jstr
    mov ecx, VN_eval
    call vn_put
    mov rdi, r12
    lea rsi, [rip + .Lk_indexedVariables]
    call jint
    mov [rsp + 8], rax
    mov rdi, rbx
    mov esi, r15d
    call vn_node
    mov rcx, [rsp + 8]
    cmp rcx, 2147483647
    jbe 81f
    mov ecx, 2147483647
81: mov [rax + VN_indexed], ecx
    mov rdi, rbx
    mov esi, r15d
    call vn_changed
    mov eax, r15d
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# vn_changed(ds, node): VNF_CHANGED when the last stop had another value at the same path
vn_changed:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp qword ptr [rbx + DS_prevvals + SB_len], 0
    je 9f
    call dap_node_path
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    mov r13, rax
    mov r14, [rbx + DS_prevvals + SB_ptr]
    mov r15, r14
    add r15, [rbx + DS_prevvals + SB_len]
1:  cmp r14, r15
    jae 9f
    mov rax, r14
2:  cmp byte ptr [rax], 9
    je 3f
    inc rax
    jmp 2b
3:  mov rcx, rax
    sub rcx, r14                # the path's length
    lea rdx, [rax + 1]          # the value
    mov r8, rdx
4:  cmp byte ptr [r8], 10
    je 5f
    inc r8
    jmp 4b
5:  cmp rcx, [rip + g_nodep + SB_len]
    jne 7f
    push rdx
    push r8
    mov rdi, r14
    mov rsi, [rip + g_nodep + SB_ptr]
    mov rdx, rcx
    call memeq
    pop r8
    pop rdx
    test eax, eax
    jz 7f
    # the same variable: has its value changed?
    mov rcx, r8
    sub rcx, rdx
    cmp ecx, [r13 + VN_valuelen]
    jne 6f
    mov rdi, rdx
    mov esi, [r13 + VN_value]
    add rsi, [rbx + DS_strs + SB_ptr]
    mov rdx, rcx
    call memeq
    test eax, eax
    jnz 9f
6:  or dword ptr [r13 + VN_flags], VNF_CHANGED
    jmp 9f
7:  lea r14, [r8 + 1]
    jmp 1b
9:  EPILOGUE

# snapshot_values(ds): the values of this stop's variables, kept for the next stop's comparison
snapshot_values:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rbx + DS_prevvals]
    call sb_clear
    xor r12d, r12d
1:  cmp r12, [rbx + DS_vars + VEC_len]
    jae 9f
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    test dword ptr [rax + VN_flags], VNF_WATCH | VNF_CHUNK
    jnz 2f
    mov r13, rax
    mov rdi, rbx
    mov esi, r12d
    call dap_node_path
    lea rdi, [rbx + DS_prevvals]
    mov rsi, [rip + g_nodep + SB_ptr]
    mov rdx, [rip + g_nodep + SB_len]
    call sb_push
    lea rdi, [rbx + DS_prevvals]
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    mov esi, [rax + VN_value]
    add rsi, [rbx + DS_strs + SB_ptr]
    mov edx, [rax + VN_valuelen]
    lea rdi, [rbx + DS_prevvals]
    call sb_push
    lea rdi, [rbx + DS_prevvals]
    mov esi, 10
    call sb_push_byte
    cmp qword ptr [rbx + DS_prevvals + SB_len], 1048576
    jae 9f                      # enough
2:  inc r12
    jmp 1b
9:  EPILOGUE
# vn_put: (rax ptr, rdx len, ecx field offset) pooled into node r15 of rbx
vn_put:
    push rcx
    push rcx
    mov rdi, rbx
    mov rsi, rax
    call pool_str
    pop rcx
    pop rcx
    push rax
    push rdx
    mov rdi, rbx
    mov esi, r15d
    push rcx
    push rcx
    call vn_node
    pop rcx
    pop rcx
    pop rdx
    pop r8
    mov [rax + rcx], r8d
    mov [rax + rcx + 4], edx
    ret

# r_scopes(ds, root, body, success, pd): the frame's scopes as roots; the first that is not
#   expensive opens, and so does any that was open at the last stop
r_scopes:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rdx
    mov r13, r8
    test ecx, ecx
    jz 9f
    mov eax, [r13 + PD_epoch]
    cmp eax, [rbx + DS_epoch]
    jne 9f
    mov eax, [r13 + PD_ctx]
    cmp eax, [rbx + DS_frame]
    jne 9f
    mov eax, [r13 + PD_ctx + 4]
    cmp eax, [rbx + DS_vgen]
    jne 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_scopes]
    call json_get
    mov r14, rax
    xor r15d, r15d
    mov dword ptr [rsp], 0      # a scope was opened by default
1:  cmp r15d, 64
    jae 9f
    mov rdi, r14
    mov esi, r15d
    call json_at
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rbx
    mov esi, -1
    xor edx, edx
    mov rcx, r12
    lea r8, [rip + .Lk_name]
    lea r9, [rip + .Lk_novalue]
    call vn_add
    test eax, eax
    js 9f
    mov [rsp + 4], eax
    mov rdi, r12
    lea rsi, [rip + .Lk_expensive]
    call jbool
    mov [rsp + 8], eax
    test eax, eax
    jz 2f
    mov rdi, rbx
    mov esi, [rsp + 4]
    call vn_node
    or dword ptr [rax + VN_flags], VNF_EXPENSIVE
2:  # open it?
    mov rdi, rbx
    mov esi, [rsp + 4]
    call node_was_open
    test eax, eax
    jnz 3f
    cmp dword ptr [rsp + 8], 0
    jne 4f
    cmp dword ptr [rsp], 0
    jne 4f
3:  mov dword ptr [rsp], 1
    mov rdi, rbx
    mov esi, [rsp + 4]
    call vn_expand
4:  inc r15d
    jmp 1b
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# vn_hover_tree(ds, node) -> eax 1 when the node is the hover's value or under it (its root's parent
#   is -3)
.equ HV_DEPTH, 2                # the hover's card: two levels of members
FN vn_hover_tree
    mov rcx, [rdi + DS_vars + VEC_ptr]
    mov eax, esi
    mov edx, 64
1:  test eax, eax
    js 8f
    imul r8, rax, VN_SIZE
    mov r9d, [rcx + r8 + VN_parent]
    cmp r9d, -3
    je 9f
    mov eax, r9d
    dec edx
    jnz 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# vn_expand(ds, node) -> eax 1 when its children were asked for (or are there): it is marked open
FN vn_expand
    PROLOGUE
    inc dword ptr [rip + g_dap_gen]
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    mov r13, rax
    or dword ptr [r13 + VN_flags], VNF_EXPANDED
    mov rdi, rbx
    mov esi, r12d
    call vn_hover_tree
    test eax, eax
    jnz 0f                      # the hover's: not remembered across stops
    mov rdi, rbx
    mov esi, r12d
    call open_path_add
0:
    cmp qword ptr [r13 + VN_ref], 0
    je 8f
    cmp dword ptr [r13 + VN_kid0], 0
    jge 9f                      # loaded
    test dword ptr [r13 + VN_flags], VNF_LOADING
    jnz 9f
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 8f
    mov eax, [r13 + VN_epoch]
    cmp eax, [rbx + DS_epoch]
    jne 8f                      # a reference from an earlier stop is never sent
    # a chunk of more than DAP_CHUNK: smaller chunks under it, asked for when they open
    test dword ptr [r13 + VN_flags], VNF_CHUNK
    jz 1f
    cmp dword ptr [r13 + VN_indexed], DAP_CHUNK
    jbe 1f
    mov rdi, rbx
    mov esi, r12d
    mov edx, [r13 + VN_start]
    mov ecx, [r13 + VN_indexed]
    call make_chunks
    jmp 9f
1:  or dword ptr [r13 + VN_flags], VNF_LOADING
    mov rdi, rbx
    lea rsi, [rip + .Lc_variables]
    call dap_req_begin
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    mov r13, rax
    lea rdi, [rip + .Lk_variablesReference]
    mov rsi, [r13 + VN_ref]
    call aki
    # many indexed children: the named ones now, chunks for the rest (r_variables); a chunk: its range
    test dword ptr [r13 + VN_flags], VNF_CHUNK
    jnz 2f
    cmp dword ptr [r13 + VN_indexed], DAP_CHUNK
    jbe 3f
    lea rdi, [rip + .Lk_filter]
    lea rsi, [rip + .Lv_named]
    call akv
    jmp 3f
2:  lea rdi, [rip + .Lk_filter]
    lea rsi, [rip + .Lv_indexed]
    call akv
    lea rdi, [rip + .Lk_start]
    mov esi, [r13 + VN_start]
    call aki
    lea rdi, [rip + .Lk_count]
    mov esi, [r13 + VN_indexed]
    call aki
3:  mov rdi, rbx
    mov esi, RQ_VARIABLES
    mov edx, [rbx + DS_vgen]            # the pool's generation, and the node
    shl rdx, 32
    mov eax, r12d
    or rdx, rax
    call dap_req_send
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    and dword ptr [rax + VN_flags], ~VNF_LOADING
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# make_chunks(ds, node, start, count): a big chunk's children: smaller chunks, loaded at once
make_chunks:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov eax, [rbx + DS_vars + VEC_len]
    mov r13d, eax               # the first child
    mov rdi, rbx
    mov esi, r12d
    call add_chunks
    mov r14d, eax
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    mov [rax + VN_kid0], r13d
    mov [rax + VN_nkids], r14d
    # the ones open at the last stop open again (as r_variables does for an adapter's children)
    xor r15d, r15d
1:  cmp r15d, r14d
    jae 9f
    lea esi, [r13 + r15]
    mov rdi, rbx
    call node_was_open
    test eax, eax
    jz 2f
    lea esi, [r13 + r15]
    mov rdi, rbx
    call vn_expand
2:  inc r15d
    jmp 1b
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# add_chunks(ds, parent, start, count) -> eax the chunk nodes added: [start..start+count) in ranges
#   of DAP_CHUNK, or of DAP_CHUNK * DAP_CHUNK... so that at most DAP_CHUNK of them are made
add_chunks:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi              # the parent
    mov [rsp + 4], edx          # start
    mov [rsp + 8], ecx          # count
    mov eax, DAP_CHUNK
1:  mov edx, eax
    imul edx, edx, DAP_CHUNK
    cmp [rsp + 8], edx
    jbe 2f
    cmp eax, 1000000
    jae 2f
    imul eax, eax, DAP_CHUNK
    jmp 1b
2:  mov [rsp + 12], eax         # the chunk size
    xor r15d, r15d              # chunks made
    xor r12d, r12d              # offset
3:  cmp r12d, [rsp + 8]
    jae 9f
    cmp qword ptr [rbx + DS_vars + VEC_len], DAP_VARS_MAX
    jae 9f
    mov r13d, [rsp + 8]
    sub r13d, r12d
    cmp r13d, [rsp + 12]
    jbe 4f
    mov r13d, [rsp + 12]        # this chunk's count
4:  lea rdi, [rbx + DS_vars]
    mov esi, VN_SIZE
    call vec_push
    mov rax, [rbx + DS_vars + VEC_len]
    dec rax
    mov r14d, eax
    mov rdi, rbx
    mov esi, [rsp]
    call vn_node
    mov rcx, [rax + VN_ref]
    mov edx, [rax + VN_depth]
    mov [rsp + 16], rcx
    mov [rsp + 24], edx
    mov rdi, rbx
    mov esi, r14d
    call vn_node
    mov rcx, [rsp + 16]
    mov [rax + VN_ref], rcx
    mov ecx, [rsp]
    mov [rax + VN_parent], ecx
    mov ecx, [rsp + 24]
    inc ecx
    mov [rax + VN_depth], ecx
    mov dword ptr [rax + VN_kid0], -1
    mov ecx, [rbx + DS_epoch]
    mov [rax + VN_epoch], ecx
    mov dword ptr [rax + VN_flags], VNF_CHUNK
    mov ecx, [rsp + 4]
    add ecx, r12d
    mov [rax + VN_start], ecx
    mov [rax + VN_indexed], r13d
    # its name: [FIRST..LAST]
    lea rdi, [rip + chunkb]
    call sb_clear
    lea rdi, [rip + chunkb]
    mov esi, '['
    call sb_push_byte
    mov esi, [rsp + 4]
    add esi, r12d
    lea rdi, [rip + chunkb]
    call sb_push_u64
    lea rdi, [rip + chunkb]
    lea rsi, [rip + .Ldotdot]
    call sb_push_cstr
    mov esi, [rsp + 4]
    add esi, r12d
    add esi, r13d
    dec esi
    lea rdi, [rip + chunkb]
    call sb_push_u64
    lea rdi, [rip + chunkb]
    mov esi, ']'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [rip + chunkb + SB_ptr]
    mov rdx, [rip + chunkb + SB_len]
    call pool_str
    push rax
    push rdx
    mov rdi, rbx
    mov esi, r14d
    call vn_node
    pop rdx
    pop rcx
    mov [rax + VN_name], ecx
    mov [rax + VN_namelen], edx
    inc r15d
    add r12d, r13d
    jmp 3b
9:  mov eax, r15d
    EPILOGUE

# dap_set_variable(ds, node, value ptr, len) -> eax 1 asked: setVariable on the node's parent's
#   reference, its name and the new value text; the answer replaces the shown value
FN dap_set_variable
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 8f
    test qword ptr [rbx + DS_caps], CAP_SETVAR
    jz .Lsv_nocap
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    mov r15, rax
    mov ecx, [r15 + VN_parent]
    test ecx, ecx
    js .Lsv_nocap               # a scope or a watch: no variable to set
    test dword ptr [r15 + VN_flags], VNF_CHUNK | VNF_WATCH
    jnz .Lsv_nocap
    mov rdi, rbx
    mov esi, ecx
    call vn_node
    mov rax, [rax + VN_ref]
    mov [rsp], rax
    mov rdi, rbx
    lea rsi, [rip + .Lc_setVariable]
    call dap_req_begin
    lea rdi, [rip + .Lk_variablesReference]
    mov rsi, [rsp]
    call aki
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    mov esi, [rax + VN_name]
    add rsi, [rbx + DS_strs + SB_ptr]
    mov edx, [rax + VN_namelen]
    lea rdi, [rip + .Lk_name]
    call aks
    lea rdi, [rip + .Lk_value]
    mov rsi, r13
    mov rdx, r14
    call aks
    mov rdi, rbx
    mov esi, RQ_SETVARIABLE
    mov edx, [rbx + DS_vgen]
    shl rdx, 32
    mov eax, r12d
    or rdx, rax
    call dap_req_send
    mov eax, 1
    EPILOGUE
.Lsv_nocap:
    mov edi, [rbx + DS_id]
    mov esi, DCON_ERROR
    lea rdx, [rip + .Lm_nosetvar]
    mov ecx, .Lm_nosetvar_end - .Lm_nosetvar
    call dcon_line
8:  xor eax, eax
    EPILOGUE

# r_setvar(ds, root, body, success, pd): the variable's new value (and children), or why not
r_setvar:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r15, r8
    test ecx, ecx
    jnz 1f
    # the adapter's message, in the console
    mov rdi, r12
    lea rsi, [rip + .Lk_message]
    call jstr
    test rax, rax
    jz 9f
    mov rcx, rdx
    mov rdx, rax
    mov edi, [rbx + DS_id]
    mov esi, DCON_ERROR
    call dcon_line
    jmp 9f
1:  mov eax, [r15 + PD_epoch]
    cmp eax, [rbx + DS_epoch]
    jne 9f
    mov eax, [r15 + PD_ctx + 4]
    cmp eax, [rbx + DS_vgen]
    jne 9f
    mov r14d, [r15 + PD_ctx]
    mov rdi, r13
    lea rsi, [rip + .Lk_value]
    call jstr
    test rax, rax
    jz 2f
    mov rdi, rbx
    mov rsi, rax
    call pool_str
    push rax
    push rdx
    mov rdi, rbx
    mov esi, r14d
    call vn_node
    pop rdx
    pop rcx
    mov [rax + VN_value], ecx
    mov [rax + VN_valuelen], edx
    or dword ptr [rax + VN_flags], VNF_CHANGED
2:  mov rdi, r13
    lea rsi, [rip + .Lk_type]
    call jstr
    test rax, rax
    jz 3f
    mov rdi, rbx
    mov rsi, rax
    call pool_str
    push rax
    push rdx
    mov rdi, rbx
    mov esi, r14d
    call vn_node
    pop rdx
    pop rcx
    mov [rax + VN_type], ecx
    mov [rax + VN_typelen], edx
3:  # its children: the answer's reference (none when it has no variablesReference: a list set to
    #   42 loses its elements), asked for again when opened
    mov rdi, r13
    lea rsi, [rip + .Lk_variablesReference]
    call jint
    test edx, edx
    jnz 31f
    xor eax, eax
31: mov [rsp], rax
    mov rdi, r13
    lea rsi, [rip + .Lk_indexedVariables]
    call jint
    test edx, edx
    jnz 32f
    xor eax, eax
32: mov [rsp + 8], eax
    mov rdi, rbx
    mov esi, r14d
    call vn_node
    mov rcx, [rsp]
    mov [rax + VN_ref], rcx
    mov ecx, [rsp + 8]
    mov [rax + VN_indexed], ecx
    mov dword ptr [rax + VN_kid0], -1
    mov dword ptr [rax + VN_nkids], 0
    and dword ptr [rax + VN_flags], ~VNF_EXPANDED
4:  # watches may show it too
    mov rdi, rbx
    call send_watches
    inc dword ptr [rip + g_dap_gen]
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# dap_node_by_path(ds, ptr, len) -> eax the node at that path (as print-debug-tree's ids), or -1
FN dap_node_by_path
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, [rbx + DS_vars + VEC_len]
    jae 8f
    mov rdi, rbx
    mov esi, r14d
    call dap_node_path
    cmp [rip + g_nodep + SB_len], r13
    jne 2f
    mov rdi, [rip + g_nodep + SB_ptr]
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jz 2f
    mov eax, r14d
    EPILOGUE
2:  inc r14
    jmp 1b
8:  mov eax, -1
    EPILOGUE

# dap_changed_dump(sb): the paths of the focused session's variables whose value changed since the
#   last stop, one per line (print-vars-changed)
FN dap_changed_dump
    PROLOGUE
    mov r15, rdi
    call dap_focused
    test rax, rax
    jz 9f
    mov rbx, rax
    xor r12d, r12d
1:  cmp r12, [rbx + DS_vars + VEC_len]
    jae 9f
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    test dword ptr [rax + VN_flags], VNF_CHANGED
    jz 2f
    mov rdi, rbx
    mov esi, r12d
    call dap_node_path
    mov rdi, r15
    mov rsi, [rip + g_nodep + SB_ptr]
    mov rdx, [rip + g_nodep + SB_len]
    call sb_push
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
2:  inc r12
    jmp 1b
9:  EPILOGUE

# vn_collapse(ds, node): closed, and not reopened at the next stop
FN vn_collapse
    PROLOGUE
    inc dword ptr [rip + g_dap_gen]
    mov rbx, rdi
    mov r12d, esi
    call vn_node
    and dword ptr [rax + VN_flags], ~VNF_EXPANDED
    mov rdi, rbx
    mov esi, r12d
    call open_path_remove
    EPILOGUE

# r_variables(ds, root, body, success, pd): a node's children; those open at the last stop reopen
r_variables:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rdx
    mov r13, r8
    mov r14d, ecx
    mov eax, [r13 + PD_epoch]
    cmp eax, [rbx + DS_epoch]
    jne 9f
    mov eax, [r13 + PD_ctx + 4]
    cmp eax, [rbx + DS_vgen]
    jne 9f                      # asked for another frame's pool
    mov rdi, rbx
    mov esi, [r13 + PD_ctx]
    call vn_node
    and dword ptr [rax + VN_flags], ~VNF_LOADING
    test r14d, r14d
    jnz 1f
    or dword ptr [rax + VN_flags], VNF_ERROR
    jmp 9f
1:  mov ecx, [rax + VN_depth]
    inc ecx
    mov [rsp], ecx
    mov rdi, r12
    lea rsi, [rip + .Lk_variables]
    call json_get
    mov r14, rax
    mov rax, [rbx + DS_vars + VEC_len]
    mov [rsp + 4], eax          # the first child
    xor r15d, r15d
2:  cmp r15d, 1000
    jae 3f
    mov rdi, r14
    mov esi, r15d
    call json_at
    test rax, rax
    jz 3f
    mov rdi, rbx
    mov esi, [r13 + PD_ctx]
    mov edx, [rsp]
    mov rcx, rax
    lea r8, [rip + .Lk_name]
    lea r9, [rip + .Lk_value]
    call vn_add
    test eax, eax
    js 3f
    inc r15d
    jmp 2b
3:  # paged: chunks follow the named children
    mov rdi, rbx
    mov esi, [r13 + PD_ctx]
    call vn_node
    test dword ptr [rax + VN_flags], VNF_CHUNK
    jnz 31f
    cmp dword ptr [rax + VN_indexed], DAP_CHUNK
    jbe 31f
    mov ecx, [rax + VN_indexed]
    mov rdi, rbx
    mov esi, [r13 + PD_ctx]
    xor edx, edx
    call add_chunks
    add r15d, eax
31: mov rdi, rbx
    mov esi, [r13 + PD_ctx]
    call vn_node
    mov ecx, [rsp + 4]
    mov [rax + VN_kid0], ecx
    mov [rax + VN_nkids], r15d
    mov rdi, rbx                # the hover's: its members open, HV_DEPTH levels down
    mov esi, [r13 + PD_ctx]
    call vn_hover_tree
    mov [rsp + 12], eax
    # reopen
    xor r12d, r12d
4:  cmp r12d, r15d
    jae 9f
    mov esi, [rsp + 4]
    add esi, r12d
    mov [rsp + 8], esi
    cmp dword ptr [rsp + 12], 0
    je 41f
    cmp dword ptr [rsp], HV_DEPTH
    jae 5f
    mov rdi, rbx
    mov esi, [rsp + 8]
    call vn_expand
    jmp 5f
41: mov rdi, rbx
    call node_was_open
    test eax, eax
    jz 5f
    mov rdi, rbx
    mov esi, [rsp + 8]
    call vn_expand
5:  inc r12d
    jmp 4b
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ---------------- open nodes across stops ----------------

# node_path(ds, node): nodep = the names from its root, separated by '/' (a watch: watch:EXPR/...)
FN dap_node_path
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [rip + nodep]
    call sb_clear
    # walk up, writing names reversed into the stack of indices
    xor r13d, r13d              # depth count
    mov r14d, r12d
1:  test r14d, r14d
    js 2f
    push r14
    inc r13d
    mov rdi, rbx
    mov esi, r14d
    call vn_node
    mov r14d, [rax + VN_parent]
    cmp r13d, 64
    jb 1b
2:  test r13d, r13d
    jz 9f
    pop r14
    dec r13d
    mov rdi, rbx
    mov esi, r14d
    call vn_node
    mov r15, rax
    cmp qword ptr [rip + nodep + SB_len], 0
    je 3f
    lea rdi, [rip + nodep]
    mov esi, '/'
    call sb_push_byte
    jmp 4f
3:  test dword ptr [r15 + VN_flags], VNF_WATCH
    jz 4f
    lea rdi, [rip + nodep]
    lea rsi, [rip + .Lwatch_prefix]
    call sb_push_cstr
4:  mov ecx, [r15 + VN_name]
    mov rsi, [rbx + DS_strs + SB_ptr]
    add rsi, rcx
    mov edx, [r15 + VN_namelen]
    lea rdi, [rip + nodep]
    call sb_push
    jmp 2b
9:  EPILOGUE

# open_find(ds) -> rax offset of nodep's line in DS_expanded, -1
open_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + DS_expanded + SB_ptr]
    mov r13, [rbx + DS_expanded + SB_len]
    xor r14d, r14d
1:  cmp r14, r13
    jae 8f
    mov rcx, r14
2:  cmp byte ptr [r12 + rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  mov r15, rcx
    lea rdi, [r12 + r14]
    mov rsi, rcx
    sub rsi, r14
    mov rdx, [rip + nodep + SB_ptr]
    mov rcx, [rip + nodep + SB_len]
    call str_eq
    test eax, eax
    jnz 9f
    lea r14, [r15 + 1]
    jmp 1b
8:  mov r14, -1
9:  mov rax, r14
    EPILOGUE

# node_was_open(ds, node) -> eax 1 when its path is in the open set
node_was_open:
    push rbx
    mov rbx, rdi
    call dap_node_path
    mov rdi, rbx
    call open_find
    xor ecx, ecx
    test rax, rax
    setns cl
    mov eax, ecx
    pop rbx
    ret

# open_path_add(ds, node)
open_path_add:
    PROLOGUE
    mov rbx, rdi
    call dap_node_path
    mov rdi, rbx
    call open_find
    test rax, rax
    jns 9f
    # at most 512 paths: count lines
    mov rdi, [rbx + DS_expanded + SB_ptr]
    mov rsi, [rbx + DS_expanded + SB_len]
    xor ecx, ecx
    xor edx, edx
1:  cmp rcx, rsi
    jae 2f
    cmp byte ptr [rdi + rcx], 10
    jne 11f
    inc edx
11: inc rcx
    jmp 1b
2:  cmp edx, DAP_EXPANDED_MAX
    jae 9f
    lea rdi, [rbx + DS_expanded]
    mov rsi, [rip + nodep + SB_ptr]
    mov rdx, [rip + nodep + SB_len]
    call sb_push
    lea rdi, [rbx + DS_expanded]
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# open_path_remove(ds, node)
open_path_remove:
    PROLOGUE
    mov rbx, rdi
    call dap_node_path
    mov rdi, rbx
    call open_find
    test rax, rax
    js 9f
    mov r12, rax
    mov rdi, [rbx + DS_expanded + SB_ptr]
    mov rcx, r12
1:  cmp byte ptr [rdi + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  inc rcx                     # past its newline
    mov rdx, [rbx + DS_expanded + SB_len]
    sub rdx, rcx
    lea rsi, [rdi + rcx]
    add rdi, r12
    mov r13, rcx
    sub r13, r12
    call memmove
    sub [rbx + DS_expanded + SB_len], r13
9:  EPILOGUE

# ---------------- watches ----------------

# send_watches(ds): each watch expression evaluated in the focused frame (a new round: answers to an
#   earlier one are dropped)
send_watches:
    PROLOGUE
    mov rbx, rdi
    inc dword ptr [rbx + DS_wgen]       # this session's round
    mov eax, [rip + g_dwlist]
    mov [rbx + DS_wlist], eax
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    mov rdi, rbx
    call dap_frame_ptr
    test rax, rax
    jz 9f
    mov r15, rax
    mov r12, [rip + g_watches + SB_ptr]
    mov r13, [rip + g_watches + SB_len]
    add r13, r12
    xor r14d, r14d              # watch index
1:  cmp r12, r13
    jae 9f
    mov rcx, r12
2:  cmp byte ptr [rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  push rcx
    push rcx
    mov rdi, rbx
    lea rsi, [rip + .Lc_evaluate]
    call dap_req_begin
    mov rcx, [rsp]
    lea rdi, [rip + .Lk_expression]
    mov rsi, r12
    mov rdx, rcx
    sub rdx, r12
    call aks
    lea rdi, [rip + .Lk_frameId]
    mov rsi, [r15 + FR_id]
    call aki
    lea rdi, [rip + .Lk_context]
    lea rsi, [rip + .Lv_watch]
    call akv
    mov rdi, rbx
    mov esi, RQ_WATCH
    mov edx, [rbx + DS_wgen]
    shl rdx, 32
    or rdx, r14
    call dap_req_send
    pop rcx
    pop rcx
    lea r12, [rcx + 1]
    inc r14d
    jmp 1b
9:  EPILOGUE

# watch_text(index) -> rax ptr, rdx len of a watch expression (0, 0 past the end)
FN dap_watch_text
    mov rax, [rip + g_watches + SB_ptr]
    mov rcx, [rip + g_watches + SB_len]
    add rcx, rax
    xor edx, edx
1:  cmp rax, rcx
    jae 8f
    mov r8, rax
2:  cmp byte ptr [r8], 10
    je 3f
    inc r8
    jmp 2b
3:  test edi, edi
    jz 4f
    dec edi
    lea rax, [r8 + 1]
    jmp 1b
4:  mov rdx, r8
    sub rdx, rax
    ret
8:  xor eax, eax
    xor edx, edx
    ret

# r_watch(ds, root, body, success, pd): a watch's value as a root (an error shows as its value)
r_watch:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    mov r15, r8
    mov eax, [r15 + PD_epoch]
    cmp eax, [rbx + DS_epoch]
    jne 9f
    mov eax, [r15 + PD_ctx + 4]
    cmp eax, [rbx + DS_wgen]
    jne 9f                      # an earlier round's answer
    mov eax, [r15 + PD_ctx]
    mov [rsp + 4], eax          # the watch's index
    mov rdi, rbx
    mov esi, -1
    xor edx, edx
    mov rcx, r13
    lea r8, [rip + .Lk_novalue]
    lea r9, [rip + .Lk_result]
    call vn_add
    test eax, eax
    js 9f
    mov [rsp], eax
    mov rdi, rbx
    mov esi, eax
    call vn_node
    or dword ptr [rax + VN_flags], VNF_WATCH
    # its name: the expression
    mov edi, [rsp + 4]
    call dap_watch_text
    mov r15d, [rsp]
    mov ecx, VN_name
    call vn_put
    test r14d, r14d
    jnz 2f
    mov rdi, rbx
    mov esi, [rsp]
    call vn_node
    or dword ptr [rax + VN_flags], VNF_ERROR
    mov rdi, r12
    mov rsi, r13
    call resp_message
    mov r15d, [rsp]
    mov ecx, VN_value
    call vn_put
    jmp 9f
2:  mov rdi, rbx
    mov esi, [rsp]
    call node_was_open
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov esi, [rsp]
    call vn_expand
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# dap_watch_add(ptr, len): a new watch (at most 64); evaluated at once when paused
FN dap_watch_add
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call bp_ensure_loaded
    test r13, r13
    jz 9f
    mov rdi, [rip + g_watches + SB_ptr]
    mov rsi, [rip + g_watches + SB_len]
    xor ecx, ecx
    xor edx, edx
1:  cmp rcx, rsi
    jae 2f
    cmp byte ptr [rdi + rcx], 10
    jne 11f
    inc edx
11: inc rcx
    jmp 1b
2:  cmp edx, WATCH_MAX
    jae 9f
    lea rdi, [rip + g_watches]
    mov rsi, r12
    mov rdx, r13
    call sb_push_clean
    lea rdi, [rip + g_watches]
    mov esi, 10
    call sb_push_byte
    call refresh_watches
9:  EPILOGUE

# dap_watch_remove(ptr, len): the watch with that text goes
FN dap_watch_remove
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call bp_ensure_loaded
    xor ebx, ebx
1:  mov edi, ebx
    call dap_watch_text
    test rax, rax
    jz 9f
    mov r14, rax
    mov r15, rdx
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    mov rcx, r13
    call str_eq
    test eax, eax
    jnz 2f
    inc ebx
    jmp 1b
2:  lea rsi, [r14 + r15 + 1]
    mov rdx, [rip + g_watches + SB_ptr]
    add rdx, [rip + g_watches + SB_len]
    sub rdx, rsi
    mov rdi, r14
    call memmove
    lea rax, [r15 + 1]
    sub [rip + g_watches + SB_len], rax
    call refresh_watches
9:  EPILOGUE

# dap_watches_changed(): the watch list was changed by hand (an evaluation, debugview.s): asked for
#   again
FN dap_watches_changed
    jmp refresh_watches

# refresh_watches(): the focused session's watch roots are dropped and asked for again
refresh_watches:
    sub rsp, 8
    inc dword ptr [rip + g_dwlist]      # the list changed
    call dap_focused
    add rsp, 8
    test rax, rax
    jz 1f
    mov rdi, rax
    jmp watches_again
1:  ret

# watches_again(ds): that session's watch roots are dropped and asked for again (the list may have
#   changed while another session had the focus)
watches_again:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    # watch roots are only hidden (the pool keeps indices stable): mark them stale-free by flag
    xor r12d, r12d
1:  cmp r12, [rbx + DS_vars + VEC_len]
    jae 2f
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    test dword ptr [rax + VN_flags], VNF_WATCH
    jz 11f
    cmp dword ptr [rax + VN_parent], -1
    jne 11f
    mov dword ptr [rax + VN_parent], -2     # dropped
    and dword ptr [rax + VN_flags], ~VNF_WATCH
11: inc r12
    jmp 1b
2:  mov rdi, rbx
    call send_watches
9:  mov dword ptr [rip + g_dirty], 1
    inc dword ptr [rip + g_dap_gen]
    EPILOGUE

# ---------------- the console's input ----------------

# dap_eval(ptr, len): an expression from the console, in the focused frame (context repl)
FN dap_eval
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call dap_focused
    test rax, rax
    jz 8f
    mov rbx, rax
    mov edi, [rbx + DS_id]
    mov esi, DCON_INPUT
    mov rdx, r12
    mov rcx, r13
    call dcon_line
    cmp dword ptr [rbx + DS_state], DSS_ENDED
    je 8f
    mov rdi, rbx
    lea rsi, [rip + .Lc_evaluate]
    call dap_req_begin
    lea rdi, [rip + .Lk_expression]
    mov rsi, r12
    mov rdx, r13
    call aks
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 1f
    mov rdi, rbx
    call dap_frame_ptr
    test rax, rax
    jz 1f
    lea rdi, [rip + .Lk_frameId]
    mov rsi, [rax + FR_id]
    call aki
1:  lea rdi, [rip + .Lk_context]
    lea rsi, [rip + .Lv_repl]
    call akv
    mov rdi, rbx
    mov esi, RQ_REPL
    xor edx, edx
    call dap_req_send
    EPILOGUE
8:  lea rdi, [rip + .Lm_nosession]
    call dap_error
    EPILOGUE

# dap_hover_eval(ds, expr cstr): evaluate for the pointer's hover in the focused frame (context hover
#   when the adapter offers it, else watch)
FN dap_hover_eval
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call dap_frame_ptr
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, rbx
    lea rsi, [rip + .Lc_evaluate]
    call dap_req_begin
    lea rdi, [rip + .Lk_expression]
    mov rsi, r12
    call akv
    lea rdi, [rip + .Lk_frameId]
    mov rsi, [r13 + FR_id]
    call aki
    lea rsi, [rip + .Lv_hover]
    test qword ptr [rbx + DS_caps], CAP_HOVER
    jnz 1f
    lea rsi, [rip + .Lv_watch]
1:  lea rdi, [rip + .Lk_context]
    call akv
    inc dword ptr [rip + hover_seq]     # an earlier hover's answer no longer counts
    mov rdi, rbx
    mov esi, RQ_HOVER
    mov edx, [rbx + DS_vgen]            # nor one about another frame
    shl rdx, 32
    mov eax, [rip + hover_seq]
    or rdx, rax
    call dap_req_send
9:  EPILOGUE

# r_hover(ds, root, body, success, pd): the hover's value (an error shows nothing)
r_hover:
    PROLOGUE
    mov r14, rdi
    mov rbx, rdx
    test ecx, ecx
    jz 9f
    mov eax, [r8 + PD_epoch]
    cmp eax, [rdi + DS_epoch]
    jne 9f
    mov eax, [r8 + PD_ctx]
    cmp eax, [rip + hover_seq]
    jne 9f                      # the pointer moved on to another expression
    mov eax, [r8 + PD_ctx + 4]
    cmp eax, [rdi + DS_vgen]
    jne 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_result]
    call jstr
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call jstr
    mov rcx, rdx
    mov rdx, rax
    mov rdi, r12
    mov rsi, r13
    call dg_hover_answer
    # the value as a root no view lists (parent -3), its members loaded two levels down for the
    #   hover's card (debuggutter.s)
    mov rdi, r14
    mov esi, -1
    xor edx, edx
    mov rcx, rbx
    lea r8, [rip + .Lk_novalue]
    lea r9, [rip + .Lk_result]
    call vn_add
    test eax, eax
    js 9f
    mov r15d, eax
    mov rdi, r14
    mov esi, eax
    call vn_node
    mov dword ptr [rax + VN_parent], -3
    mov [rip + g_hv_root], r15d
    mov rdi, r14
    call slot_index
    mov [rip + g_hv_slot], eax
    mov eax, [r14 + DS_epoch]
    mov [rip + g_hv_epoch], eax
    mov eax, [r14 + DS_vgen]
    mov [rip + g_hv_vgen], eax
    mov rdi, r14
    mov esi, r15d
    call vn_expand
9:  EPILOGUE

# r_repl(ds, root, body, success, pd): the value, or the error, in the console
r_repl:
    PROLOGUE
    mov rbx, rdi
    test ecx, ecx
    jz 1f
    mov rdi, rdx
    lea rsi, [rip + .Lk_result]
    call jstr
    mov rcx, rdx
    mov rdx, rax
    mov edi, [rbx + DS_id]
    mov esi, DCON_RESULT
    call dcon_text
    mov edi, [rbx + DS_id]
    mov esi, DCON_RESULT
    call dcon_close
    EPILOGUE
1:  mov rdi, rsi
    mov rsi, rdx
    call resp_message
    mov rcx, rdx
    mov rdx, rax
    mov edi, [rbx + DS_id]
    mov esi, DCON_ERROR
    call dcon_text
    mov edi, [rbx + DS_id]
    mov esi, DCON_ERROR
    call dcon_close
    EPILOGUE

# r_excinfo(ds, root, body, success, pd): the exception's id and description in the console
r_excinfo:
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    test ecx, ecx
    jz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_exceptionId]
    call jstr
    lea rdi, [rip + nodep]
    push rax
    push rdx
    call sb_clear
    pop rdx
    pop rsi
    lea rdi, [rip + nodep]
    call sb_push
    mov rdi, r12
    lea rsi, [rip + .Lk_description]
    call jstr
    test rdx, rdx
    jz 1f
    push rax
    push rdx
    lea rdi, [rip + nodep]
    lea rsi, [rip + .Lcolon_sp]
    call sb_push_cstr
    pop rdx
    pop rsi
    lea rdi, [rip + nodep]
    call sb_push
1:  mov edi, [rbx + DS_id]
    mov esi, DCON_ERROR
    mov rdx, [rip + nodep + SB_ptr]
    mov rcx, [rip + nodep + SB_len]
    call dcon_line
9:  EPILOGUE

# ---------------- reverse requests ----------------

# on_reverse(ds, root): runInTerminal (dapterm.s); others are refused
on_reverse:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Lk_seq]
    call jint
    mov r13, rax
    mov rdi, r12
    lea rsi, [rip + .Lk_command]
    call jstr
    mov r14, rax
    mov r15, rdx
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lc_runInTerminal]
    call str_eq_cstr
    test eax, eax
    jz 1f
    mov rdi, r12
    lea rsi, [rip + .Lk_arguments]
    call jkey
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r13
    call dap_run_in_terminal
    EPILOGUE
1:  mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lc_startDebugging]
    call str_eq_cstr
    test eax, eax
    jz 2f
    mov rdi, r12
    lea rsi, [rip + .Lk_arguments]
    call jkey
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r13
    call start_child
    EPILOGUE
2:  lea rdi, [rip + nodep]
    lea rsi, [rip + .Lm_unsupported]
    call sb_set_cstr
    lea rdi, [rip + nodep]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    mov r8, [rip + nodep + SB_ptr]
    mov r9, [rip + nodep + SB_len]
    call dap_reply_fail
    EPILOGUE

# start_child(parent ds, request seq, arguments JV*): startDebugging {request, configuration}: a
#   child session of the same debugger, with the configuration as its launch or attach arguments.
#   Its adapter is the parent's command again (stdio), or the parent's server (tcp, server: an
#   adapter that takes several sessions listens there). No approval: the parent's covers it
start_child:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    mov r12, rdx
    mov rdi, r12
    lea rsi, [rip + .Lk_configuration]
    call json_get
    mov r13, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne .Lsc_bad
    call ds_alloc
    test rax, rax
    jz .Lsc_full
    mov r14, rax
    mov eax, [rbx + DS_dbg]
    mov [r14 + DS_dbg], eax
    mov rax, [rbx + DS_dbg_ext]
    mov [r14 + DS_dbg_ext], rax
    mov eax, [rbx + DS_id]
    mov [r14 + DS_parent], eax
    mov eax, [rbx + DS_nodebug]
    mov [r14 + DS_nodebug], eax
    # the request: attach or launch (the default)
    mov dword ptr [r14 + DS_request], 0
    mov rdi, r12
    lea rsi, [rip + .Lk_request]
    call jstr
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_attach]
    call str_eq_cstr
    mov [r14 + DS_request], eax
1:  # the arguments as they came
    lea rdi, [r14 + DS_launch]
    call jw_begin
    lea rdi, [r14 + DS_launch]
    mov rsi, r13
    call jw_jv
    test eax, eax
    jz .Lsc_badfree
    # its name: configuration.name, else the parent's
    mov rdi, r13
    lea rsi, [rip + .Lk_name]
    call jstr
    test rax, rax
    jnz 2f
    mov rdi, [rbx + DS_name]
    xor edx, edx
    test rdi, rdi
    jz 2f
    push rdi
    push rdi
    call strlen
    mov rdx, rax
    pop rax
    pop rax
2:  lea rdi, [r14 + DS_name]
    mov rsi, rax
    call ds_set_str
    # the adapter: the parent's command, or its server
    mov eax, [rbx + DS_transport]
    mov [r14 + DS_transport], eax
    mov eax, [rbx + DS_port]
    mov [r14 + DS_port], eax
    mov eax, [rbx + DS_addr]
    mov [r14 + DS_addr], eax
    cmp dword ptr [rbx + DS_transport], DTR_STDIO
    je 3f
    mov dword ptr [r14 + DS_transport], DTR_SERVER
    jmp 4f
3:  lea rdi, [r14 + DS_args]
    mov rsi, [rbx + DS_args + SB_ptr]
    mov rdx, [rbx + DS_args + SB_len]
    call sb_push
    mov eax, [rbx + DS_nargs]
    mov [r14 + DS_nargs], eax
4:  mov rdi, r14
    call launch_now
    # the answer: success once the child is on its way
    mov rdi, rbx
    mov rsi, [rsp]
    lea rdx, [rip + .Lc_startDebugging]
    call reply_ok_empty
    EPILOGUE
.Lsc_badfree:
    mov rdi, r14
    lea rsi, [rip + .Lm_child_bad]
    call ds_end
.Lsc_bad:
    lea r8, [rip + .Lm_child_bad]
    jmp 8f
.Lsc_full:
    lea r8, [rip + .Lm_full]
8:  mov rdi, r8
    call strlen
    mov r9, rax
    mov rdi, rbx
    mov rsi, [rsp]
    lea rdx, [rip + .Lc_startDebugging]
    mov ecx, 14
    call dap_reply_fail
    EPILOGUE

# reply_ok_empty(ds, request seq, command cstr): a successful response without a body
reply_ok_empty:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + g_dmsg]
    call jw_begin
    lea rdi, [rip + g_dmsg]
    call jw_obj
    lea rdi, [rip + .Lk_seq]
    mov esi, [rbx + DS_seq]
    inc dword ptr [rbx + DS_seq]
    call aki
    lea rdi, [rip + .Lk_type]
    lea rsi, [rip + .Lv_response]
    call akv
    lea rdi, [rip + .Lk_request_seq]
    mov rsi, r12
    call aki
    lea rdi, [rip + .Lk_success]
    mov esi, 1
    call akb
    lea rdi, [rip + .Lk_command]
    mov rsi, r13
    call akv
    lea rdi, [rip + g_dmsg]
    call jw_end_obj
    mov rdi, rbx
    mov rsi, [rip + g_dmsg + SB_ptr]
    mov rdx, [rip + g_dmsg + SB_len]
    call dap_send
    EPILOGUE

# sb_set_cstr(sb, cstr)
sb_set_cstr:
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

# dap_reply_fail(ds, request seq, command ptr, len, message ptr, len): an unsuccessful response
FN dap_reply_fail
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov [rsp + 16], rcx
    mov r12, r8
    mov r13, r9
    lea rdi, [rip + g_dmsg]
    call jw_begin
    lea rdi, [rip + g_dmsg]
    call jw_obj
    lea rdi, [rip + .Lk_seq]
    mov esi, [rbx + DS_seq]
    inc dword ptr [rbx + DS_seq]
    call aki
    lea rdi, [rip + .Lk_type]
    lea rsi, [rip + .Lv_response]
    call akv
    lea rdi, [rip + .Lk_request_seq]
    mov rsi, [rsp]
    call aki
    lea rdi, [rip + .Lk_success]
    xor esi, esi
    call akb
    lea rdi, [rip + .Lk_command]
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    call aks
    lea rdi, [rip + .Lk_message]
    mov rsi, r12
    mov rdx, r13
    call aks
    lea rdi, [rip + g_dmsg]
    call jw_end_obj
    mov rdi, rbx
    mov rsi, [rip + g_dmsg + SB_ptr]
    mov rdx, [rip + g_dmsg + SB_len]
    call dap_send
    EPILOGUE

# ---------------- stepping ----------------

# dap_resume(kind): 0 continue, 1 step over, 2 step into, 3 step out, on the focused paused session's
#   focused thread. The thread is shown running at once; the old stop's values stay, dimmed.
FN dap_resume
    PROLOGUE
    mov r12d, edi
    call bp_tick                # breakpoint changes reach the adapter before the program runs on
    call dap_focused
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    lea rax, [rip + resume_cmds]
    mov rsi, [rax + r12*8]
    mov rdi, rbx
    call dap_req_begin
    lea rdi, [rip + .Lk_threadId]
    mov rsi, [rbx + DS_thread]
    call aki
    mov rdi, rbx
    mov esi, RQ_RESUME
    xor edx, edx
    call dap_req_send
    test eax, eax
    jz 9f                       # it did not go out: still paused
    mov dword ptr [rbx + DS_state], DSS_RUNNING
    inc dword ptr [rbx + DS_epoch]
    or dword ptr [rbx + DS_flags], DSF_STALE
    mov dword ptr [rip + g_dirty], 1
    inc dword ptr [rip + g_dap_gen]
9:  EPILOGUE

# dap_pause(): Pause on the focused running session
FN dap_pause
    PROLOGUE
    call dap_focused
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_RUNNING
    jne 9f
    cmp qword ptr [rbx + DS_thread], 0
    jne 1f
    # no thread known yet: the list first; its answer pauses the first one
    mov rdi, rbx
    lea rsi, [rip + .Lc_threads]
    call dap_req_begin
    mov rdi, rbx
    mov esi, RQ_THREADS
    mov edx, 2
    call dap_req_send
    jmp 9f
1:  mov rdi, rbx
    call send_pause
9:  EPILOGUE

# send_pause(ds): pause the focused thread
send_pause:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Lc_pause]
    call dap_req_begin
    lea rdi, [rip + .Lk_threadId]
    mov rsi, [rbx + DS_thread]
    call aki
    mov rdi, rbx
    mov esi, RQ_PAUSE
    xor edx, edx
    call dap_req_send
9:  EPILOGUE

# dap_focus_slot(slot): that session is the focused one (the toolbar, the view and stepping act on it)
# dap_focus_ds(ds): that session is the focused one
FN dap_focus_ds
    sub rsp, 8
    call slot_index
    add rsp, 8
    mov edi, eax
FN dap_focus_slot
    PROLOGUE
    cmp edi, DS_MAX
    jae 9f
    cmp edi, [rip + g_dfocus]
    je 9f
    mov [rip + g_dfocus], edi
    inc dword ptr [rip + g_dap_gen]
    mov dword ptr [rip + g_dirty], 1
    # its watches, evaluated again when one was added or removed while another session had the
    #   focus (its old roots dropped); else they stay as they are
    call dap_slot
    mov ecx, [rip + g_dwlist]
    cmp ecx, [rax + DS_wlist]
    je 9f
    mov rdi, rax
    call watches_again
9:  EPILOGUE

# dap_focus_thread(ds, thread id): another thread of the paused program is the focused one: its
#   stack is asked for (the first frame revealed, its scopes, the watches); Continue and the
#   steps then name it
FN dap_focus_thread
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    cmp rsi, [rbx + DS_thread]
    je 9f
    mov [rbx + DS_thread], rsi
    or dword ptr [rbx + DS_flags], DSF_TNAMED
    inc dword ptr [rbx + DS_vgen]       # answers about the other thread's frames are dropped
    mov qword ptr [rbx + DS_frames + VEC_len], 0
    mov qword ptr [rbx + DS_vars + VEC_len], 0
    mov dword ptr [rbx + DS_frame], 0
    mov dword ptr [rbx + DS_total_frames], 0
    mov dword ptr [rbx + DS_hasvars], 0
    mov rdi, rbx
    xor esi, esi
    call send_stack
    inc dword ptr [rip + g_dap_gen]
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# dap_focus_frame(ds, index): another frame of the stopped thread: revealed, its scopes and the
#   watches asked for again (the variables of the old frame go)
FN dap_focus_frame
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    cmp r12, [rbx + DS_frames + VEC_len]
    jae 9f
    mov [rbx + DS_frame], r12d
    inc dword ptr [rbx + DS_vgen]       # answers about the other frame's pool are dropped
    mov qword ptr [rbx + DS_vars + VEC_len], 0
    mov rdi, rbx
    call reveal_frame
    mov rdi, rbx
    call send_scopes
    mov rdi, rbx
    call send_watches
    inc dword ptr [rip + g_dap_gen]
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# dap_restart(): Restart: the focused session stops and its configuration starts again when it ended
FN dap_restart
    PROLOGUE
    call dap_focused
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, [rbx + DS_name]
    test rdi, rdi
    jz 9f
    lea rdi, [rip + restart_name]
    call sb_clear
    lea rdi, [rip + restart_name]
    mov rsi, [rbx + DS_name]
    call sb_push_cstr
    mov eax, [rbx + DS_nodebug]
    mov [rip + restart_nodebug], eax
    mov eax, [rbx + DS_id]
    mov [rip + restart_after], eax
    cmp dword ptr [rbx + DS_state], DSS_ENDED
    je 1f
    mov rdi, rbx
    call dap_stop_session
    EPILOGUE
1:  call restart_check
9:  EPILOGUE

# restart_check(): a restart waits for its session to end, then starts the configuration again
restart_check:
    PROLOGUE
    mov eax, [rip + restart_after]
    test eax, eax
    jz 9f
    # the session with that id
    xor r12d, r12d
1:  cmp r12d, DS_MAX
    jae 2f
    mov edi, r12d
    call dap_slot
    cmp dword ptr [rax + DS_state], DSS_FREE
    je 11f
    mov ecx, [rip + restart_after]
    cmp [rax + DS_id], ecx
    jne 11f
    cmp dword ptr [rax + DS_state], DSS_ENDED
    jne 9f                      # still ending
    cmp dword ptr [rax + DS_pid], 0
    jne 9f
    jmp 2f
11: inc r12d
    jmp 1b
2:  mov dword ptr [rip + restart_after], 0
    mov rdi, [rip + restart_name + SB_ptr]
    mov rsi, [rip + restart_name + SB_len]
    mov edx, [rip + restart_nodebug]
    call dap_start
9:  EPILOGUE

# ---------------- state for tests and drawing ----------------

# dap_state_name(state) -> cstr
FN dap_state_name
    cmp edi, DSS_APPROVAL
    jbe 1f
    xor edi, edi
1:  lea rax, [rip + state_names]
    mov rax, [rax + rdi*8]
    ret

# dap_dump(sb): one line per session: session=ID name=N type=T state=S reason=R thread=ID frame=I
#   at=PATH:LINE noDebug=B exit=N
FN dap_dump
    PROLOGUE
    mov r15, rdi
    xor r12d, r12d
1:  cmp r12d, DS_MAX
    jae 9f
    mov edi, r12d
    call dap_slot
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_FREE
    je 8f
    mov rdi, r15
    lea rsi, [rip + .Ld_session]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + DS_id]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_name]
    call sb_push_cstr
    mov rsi, [rbx + DS_name]
    test rsi, rsi
    jz 2f
    mov rdi, r15
    call sb_push_cstr
2:  mov rdi, r15
    lea rsi, [rip + .Ld_type]
    call sb_push_cstr
    mov edi, [rbx + DS_dbg]
    call dbg_row
    mov rsi, [rax + DBG_type]
    mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    mov edi, [rbx + DS_state]
    call dap_state_name
    mov rdi, r15
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_reason]
    call sb_push_cstr
    mov rsi, [rbx + DS_reason]
    test rsi, rsi
    jz 3f
    mov rdi, r15
    call sb_push_cstr
3:  mov rdi, r15
    lea rsi, [rip + .Ld_thread]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + DS_thread]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_frame]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + DS_frame]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_at]
    call sb_push_cstr
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 4f
    mov rdi, rbx
    call dap_frame_ptr
    test rax, rax
    jz 4f
    mov r13, rax
    mov ecx, [r13 + FR_path]
    mov rsi, [rbx + DS_strs + SB_ptr]
    add rsi, rcx
    mov edx, [r13 + FR_pathlen]
    mov rdi, r15
    call sb_push
    mov rdi, r15
    mov esi, ':'
    call sb_push_byte
    mov rdi, r15
    mov esi, [r13 + FR_line]
    call sb_push_u64
4:  mov rdi, r15
    lea rsi, [rip + .Ld_nodebug]
    call sb_push_cstr
    mov esi, [rbx + DS_nodebug]
    add esi, '0'
    mov rdi, r15
    call sb_push_byte
    mov rdi, r15
    lea rsi, [rip + .Ld_exit]
    call sb_push_cstr
    mov eax, [rbx + DS_exit]
    test eax, eax
    jns 5f
    mov rdi, r15
    mov esi, '-'
    call sb_push_byte
    jmp 6f
5:  mov rdi, r15
    mov esi, eax
    call sb_push_u64
6:  mov rdi, r15
    lea rsi, [rip + .Ld_pid]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + DS_pid]
    call sb_push_u64
    cmp dword ptr [rbx + DS_parent], 0
    je 7f
    mov rdi, r15
    lea rsi, [rip + .Ld_parent]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + DS_parent]
    call sb_push_u64
7:  mov rdi, r15
    mov esi, 10
    call sb_push_byte
8:  inc r12d
    jmp 1b
9:  EPILOGUE

# dap_stack_dump(sb): the focused session's threads ("thread ID NAME", * on the focused one) and the
#   focused thread's frames ("  frame I NAME PATH:LINE", * on the focused one)
FN dap_stack_dump
    PROLOGUE
    mov r15, rdi
    call dap_focused
    test rax, rax
    jz 9f
    mov rbx, rax
    xor r12d, r12d
1:  cmp r12, [rbx + DS_threads + VEC_len]
    jae 4f
    imul r13, r12, THR_SIZE
    add r13, [rbx + DS_threads + VEC_ptr]
    mov rdi, r15
    lea rsi, [rip + .Ld_th]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [r13 + THR_id]
    call sb_push_u64
    mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    mov ecx, [r13 + THR_name]
    mov rsi, [rbx + DS_strs + SB_ptr]
    add rsi, rcx
    mov edx, [r13 + THR_namelen]
    mov rdi, r15
    call sb_push
    mov rax, [r13 + THR_id]
    cmp rax, [rbx + DS_thread]
    jne 2f
    mov rdi, r15
    lea rsi, [rip + .Ld_star]
    call sb_push_cstr
2:  mov rdi, r15
    mov esi, 10
    call sb_push_byte
    mov rax, [r13 + THR_id]
    cmp rax, [rbx + DS_thread]
    jne 3f
    mov rdi, r15
    mov rsi, rbx
    call frames_dump
3:  inc r12
    jmp 1b
4:  cmp qword ptr [rbx + DS_threads + VEC_len], 0
    jne 9f
    mov rdi, r15                # frames without a thread list yet
    mov rsi, rbx
    call frames_dump
9:  EPILOGUE

frames_dump:
    PROLOGUE
    mov r15, rdi
    mov rbx, rsi
    xor r12d, r12d
1:  cmp r12, [rbx + DS_frames + VEC_len]
    jae 9f
    imul r13, r12, FR_SIZE
    add r13, [rbx + DS_frames + VEC_ptr]
    mov rdi, r15
    lea rsi, [rip + .Ld_fr]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, r12
    call sb_push_u64
    mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    mov ecx, [r13 + FR_name]
    mov rsi, [rbx + DS_strs + SB_ptr]
    add rsi, rcx
    mov edx, [r13 + FR_namelen]
    mov rdi, r15
    call sb_push
    mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    mov ecx, [r13 + FR_path]
    mov rsi, [rbx + DS_strs + SB_ptr]
    add rsi, rcx
    mov edx, [r13 + FR_pathlen]
    mov rdi, r15
    call sb_push
    mov rdi, r15
    mov esi, ':'
    call sb_push_byte
    mov rdi, r15
    mov esi, [r13 + FR_line]
    call sb_push_u64
    cmp r12d, [rbx + DS_frame]
    jne 2f
    mov rdi, r15
    lea rsi, [rip + .Ld_star]
    call sb_push_cstr
2:  mov rdi, r15
    mov esi, 10
    call sb_push_byte
    inc r12
    jmp 1b
9:  EPILOGUE

# dap_vars_dump(sb, watches): visible rows: the scopes (watches 0) or the watch roots (1), and the
#   children of open nodes: "  "*depth NAME [= VALUE] [: TYPE] [!error] [~stale]
FN dap_vars_dump
    PROLOGUE
    mov r15, rdi
    mov r14d, esi
    call dap_focused
    test rax, rax
    jz 9f
    mov rbx, rax
    xor r12d, r12d
1:  cmp r12, [rbx + DS_vars + VEC_len]
    jae 9f
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    cmp dword ptr [rax + VN_parent], -1
    jne 2f
    mov ecx, [rax + VN_flags]
    and ecx, VNF_WATCH
    setnz cl
    movzx ecx, cl
    cmp ecx, r14d
    jne 2f
    mov rdi, r15
    mov rsi, rbx
    mov edx, r12d
    call row_dump
2:  inc r12
    jmp 1b
9:  EPILOGUE

# row_dump(sb, ds, node): the row and, when it is open, its children's rows
row_dump:
    PROLOGUE
    mov r15, rdi
    mov rbx, rsi
    mov r12d, edx
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    mov r13, rax
    mov r14d, [r13 + VN_depth]
1:  test r14d, r14d
    jz 2f
    mov rdi, r15
    lea rsi, [rip + .Ld_indent]
    call sb_push_cstr
    dec r14d
    jmp 1b
2:  mov ecx, [r13 + VN_name]
    mov rsi, [rbx + DS_strs + SB_ptr]
    add rsi, rcx
    mov edx, [r13 + VN_namelen]
    mov rdi, r15
    call sb_push
    cmp dword ptr [r13 + VN_valuelen], 0
    jne 3f
    cmp dword ptr [r13 + VN_depth], 0
    je 4f
3:  mov rdi, r15
    lea rsi, [rip + .Ld_eq]
    call sb_push_cstr
    mov ecx, [r13 + VN_value]
    mov rsi, [rbx + DS_strs + SB_ptr]
    add rsi, rcx
    mov edx, [r13 + VN_valuelen]
    mov rdi, r15
    call sb_push
4:  cmp dword ptr [r13 + VN_typelen], 0
    je 5f
    mov rdi, r15
    lea rsi, [rip + .Ld_colon]
    call sb_push_cstr
    mov ecx, [r13 + VN_type]
    mov rsi, [rbx + DS_strs + SB_ptr]
    add rsi, rcx
    mov edx, [r13 + VN_typelen]
    mov rdi, r15
    call sb_push
5:  test dword ptr [r13 + VN_flags], VNF_ERROR
    jz 6f
    mov rdi, r15
    lea rsi, [rip + .Ld_error]
    call sb_push_cstr
6:  test dword ptr [rbx + DS_flags], DSF_STALE
    jz 7f
    mov rdi, r15
    lea rsi, [rip + .Ld_stale]
    call sb_push_cstr
7:  mov rdi, r15
    mov esi, 10
    call sb_push_byte
    test dword ptr [r13 + VN_flags], VNF_EXPANDED
    jz 9f
    mov r14d, [r13 + VN_kid0]
    test r14d, r14d
    js 9f
    mov r13d, [r13 + VN_nkids]
    add r13d, r14d
8:  cmp r14d, r13d
    jae 9f
    mov rdi, r15
    mov rsi, rbx
    mov edx, r14d
    call row_dump
    inc r14d
    jmp 8b
9:  EPILOGUE

# dap_find_node(ds, path ptr, len) -> eax the node at a path of names ("Locals/p/x", "watch:EXPR"),
#   -1; only loaded nodes are found
FN dap_find_node
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, [rbx + DS_vars + VEC_len]
    jae 8f
    mov rdi, rbx
    mov esi, r14d
    call vn_node
    cmp dword ptr [rax + VN_parent], -2
    je 2f
    mov rdi, rbx
    mov esi, r14d
    call dap_node_path
    mov rdi, [rip + nodep + SB_ptr]
    mov rsi, [rip + nodep + SB_len]
    mov rdx, r12
    mov rcx, r13
    call str_eq
    test eax, eax
    jnz 9f
2:  inc r14
    jmp 1b
8:  mov r14d, -1
9:  mov eax, r14d
    EPILOGUE

.bss
.p2align 3
dstart_owner: .quad 0           # dap_start_ext's caller for the session being made, 0 the user
cq: .zero SB_SIZE               # a compound's configurations still to start, | separated
chunkb: .zero SB_SIZE           # a chunk's name
cqname: .zero SB_SIZE           # the one starting
cq_nodebug: .long 0
hover_seq: .long 0              # the latest hover evaluation's number
cq_starting: .long 0            # 1 while compound_next starts one of a compound's configurations
g_dwlist: .long 0               # the watch list's version: bumped by each add and remove
.p2align 3
dstart_oid: .quad 0
dstart_resolved: .long 0        # 1: debug-resolve answered for this launch
dstart_before: .long 0          # 1: the before task ran (or there is none to run)
dap_quitting: .long 0           # dap_shutdown: no after tasks
.p2align 3
.globl g_dstart_msg
g_dstart_msg: .quad 0           # why the last dap_start* could not make a session

.section .rodata
.globl dap_m_busy, dap_m_cancelled, dap_m_full
dap_m_busy:
.Lm_busy: .asciz "a debug session is waiting for your answer"
.Lm_compound: .asciz "a compound configuration starts while another one is still starting"
.Lm_compound_in: .asciz "a compound's configurations cannot be compounds themselves"
.Lm_preparing: .asciz "a launch is being prepared by its debugger's extension"
.Lm_badserver: .asciz "server must be PORT or HOST:PORT, with HOST localhost or an IPv4 address"
.Lm_noport: .asciz "no free TCP port on 127.0.0.1 for the debugger"
.Lm_copyfail: .asciz "the debugger's extension could not be copied to the host: "
.Lm_copyslow: .asciz "the debugger's extension did not reach the host in 60 s"
.Lm_nosocket: .asciz "rhun could not create a TCP socket for the debugger"
.Lm_noconn: .asciz "the debugger did not accept a connection on "
.Lm_noconn2: .asciz " in 10 s"
.Ls_localhost: .ascii "localhost"
.Lm_noneeds: .asciz "the debugger's extension does not declare debug = yes under [needs]"
.Lm_full:
dap_m_full: .asciz "8 debug sessions are running already"
dap_m_cancelled:
.Lm_cancelled: .asciz "cancelled"
.Lm_spawn: .asciz "the debugger could not be started"
.Lm_starting: .ascii "Starting the debugger"
.Lm_starting_end:
.Lm_starting_run: .ascii "Running without debugging"
.Lm_starting_run_end:
.Lm_ended: .ascii "Debug session ended"
.Lm_ended_end:
.Lm_json: .asciz "the debugger sent a message that is not JSON"
.Lm_init_timeout: .asciz "the debugger did not answer initialize in 10 s"
.Lm_req_timeout: .ascii "the debugger did not answer in 10 s"
.Lm_req_timeout_end:
.Lm_crash: .asciz "the debugger stopped unexpectedly"
.Lm_exitcode: .asciz " (exit code "
.Lm_stopped: .asciz "stopped"
.Lm_terminated: .asciz "terminated"
.Lm_exited_reason: .asciz "exited"
.Lm_failed: .ascii "the request failed"
.Lm_failed_end:
.Lm_launch_failed: .asciz "the program could not be debugged: "
.Lm_exited: .asciz "Program exited with code "
.Lm_thread: .asciz "Thread "
.Lv_exited: .asciz "exited"
.Lk_allThreadsContinued: .asciz "allThreadsContinued"
.Lm_nosession: .asciz "no debug session"
.Lm_unsupported: .asciz "rhun does not support "
.Ld_session: .asciz "session="
.Ld_name: .asciz " name="
.Ld_type: .asciz " type="
.Ld_state: .asciz " state="
.Ld_reason: .asciz " reason="
.Ld_thread: .asciz " thread="
.Ld_frame: .asciz " frame="
.Ld_at: .asciz " at="
.Ld_nodebug: .asciz " noDebug="
.Ld_exit: .asciz " exit="
.Ld_pid: .asciz " pid="
.Ld_parent: .asciz " parent="
.Ld_th: .asciz "thread "
.Ld_fr: .asciz "  frame "
.Ld_star: .asciz " *"
.Ld_indent: .asciz "  "
.Ld_eq: .asciz " = "
.Ld_colon: .asciz " : "
.Ld_error: .asciz " !error"
.Ld_stale: .asciz " ~stale"
.Lwatch_prefix: .asciz "watch:"
.Lcolon_sp: .asciz ": "
.Lnl_glyph: .byte 0xe2, 0x86, 0xb5
.Lfffd: .byte 0xef, 0xbf, 0xbd
.Ls_free: .asciz "free"
.Ls_initializing: .asciz "initializing"
.Ls_configuring: .asciz "configuring"
.Ls_running: .asciz "running"
.Ls_paused: .asciz "paused"
.Ls_terminating: .asciz "terminating"
.Ls_ended: .asciz "ended"
.Ls_connecting: .asciz "connecting"
.Ls_approval: .asciz "approval"
.Lc_initialize: .asciz "initialize"
.Lc_launch: .asciz "launch"
.Lc_attach: .asciz "attach"
.Lc_configurationDone: .asciz "configurationDone"
.Lc_setExceptionBreakpoints: .asciz "setExceptionBreakpoints"
.Lc_threads: .asciz "threads"
.Lc_stackTrace: .asciz "stackTrace"
.Lc_scopes: .asciz "scopes"
.Lc_variables: .asciz "variables"
.Lc_evaluate: .asciz "evaluate"
.Lc_continue: .asciz "continue"
.Lc_next: .asciz "next"
.Lc_stepIn: .asciz "stepIn"
.Lc_stepOut: .asciz "stepOut"
.Lc_pause: .asciz "pause"
.Lc_terminate: .asciz "terminate"
.Lc_disconnect: .asciz "disconnect"
.Lc_exceptionInfo: .asciz "exceptionInfo"
.Lk_seq: .asciz "seq"
.Lk_type: .asciz "type"
.Lk_command: .asciz "command"
.Lk_arguments: .asciz "arguments"
.Lk_request_seq: .asciz "request_seq"
.Lk_success: .asciz "success"
.Lk_message: .asciz "message"
.Lk_body: .asciz "body"
.Lk_error: .asciz "error"
.Lk_format: .asciz "format"
.Lk_event: .asciz "event"
.Lk_clientID: .asciz "clientID"
.Lk_clientName: .asciz "clientName"
.Lk_adapterID: .asciz "adapterID"
.Lk_locale: .asciz "locale"
.Lk_pathFormat: .asciz "pathFormat"
.Lk_linesStartAt1: .asciz "linesStartAt1"
.Lk_columnsStartAt1: .asciz "columnsStartAt1"
.Lk_supportsVariableType: .asciz "supportsVariableType"
.Lk_supportsVariablePaging: .asciz "supportsVariablePaging"
.Lk_supportsProgressReporting: .asciz "supportsProgressReporting"
.Lk_supportsInvalidatedEvent: .asciz "supportsInvalidatedEvent"
.Lk_supportsMemoryReferences: .asciz "supportsMemoryReferences"
.Lk_supportsRunInTerminalRequest: .asciz "supportsRunInTerminalRequest"
.Lc_runInTerminal: .asciz "runInTerminal"
.Lc_startDebugging: .asciz "startDebugging"
.Lk_request: .asciz "request"
.Lv_attach: .asciz "attach"
.Lk_supportsStartDebuggingRequest: .asciz "supportsStartDebuggingRequest"
.Lk_configuration: .asciz "configuration"
.Lk_indexedVariables: .asciz "indexedVariables"
.Lk_start: .asciz "start"
.Lk_count: .asciz "count"
.Lv_named: .asciz "named"
.Lv_indexed: .asciz "indexed"
.Lc_setVariable: .asciz "setVariable"
.Ldotdot: .asciz ".."
.Lm_nosetvar: .ascii "the debugger cannot set this value"
.Lm_nosetvar_end:
.Lm_child_bad: .asciz "startDebugging needs a configuration object"
.Lk_terminateDebuggee: .asciz "terminateDebuggee"
.Lk_exceptionBreakpointFilters: .asciz "exceptionBreakpointFilters"
.Lk_filter: .asciz "filter"
.Lk_filters: .asciz "filters"
.Lk_label: .asciz "label"
.Lk_default: .asciz "default"
.Lk_reason: .asciz "reason"
.Lk_description: .asciz "description"
.Lk_text: .asciz "text"
.Lk_threadId: .asciz "threadId"
.Lk_preserveFocusHint: .asciz "preserveFocusHint"
.Lk_startFrame: .asciz "startFrame"
.Lk_levels: .asciz "levels"
.Lk_category: .asciz "category"
.Lk_output: .asciz "output"
.Lk_exitCode: .asciz "exitCode"
.Lk_breakpoint: .asciz "breakpoint"
.Lk_capabilities: .asciz "capabilities"
.Lk_threads: .asciz "threads"
.Lk_id: .asciz "id"
.Lk_name: .asciz "name"
.Lk_totalFrames: .asciz "totalFrames"
.Lk_stackFrames: .asciz "stackFrames"
.Lk_line: .asciz "line"
.Lk_column: .asciz "column"
.Lk_presentationHint: .asciz "presentationHint"
.Lk_source: .asciz "source"
.Lk_path: .asciz "path"
.Lk_frameId: .asciz "frameId"
.Lk_scopes: .asciz "scopes"
.Lk_novalue: .asciz "-"
.Lk_value: .asciz "value"
.Lk_result: .asciz "result"
.Lk_expensive: .asciz "expensive"
.Lk_variablesReference: .asciz "variablesReference"
.Lk_variables: .asciz "variables"
.Lk_evaluateName: .asciz "evaluateName"
.Lk_expression: .asciz "expression"
.Lk_context: .asciz "context"
.Lk_exceptionId: .asciz "exceptionId"
.Lv_request: .asciz "request"
.Lv_response: .asciz "response"
.Lv_event: .asciz "event"
.Lv_rhun: .asciz "rhun"
.Lv_en: .asciz "en"
.Lv_path: .asciz "path"
.Lv_exception: .asciz "exception"
.Lv_subtle: .asciz "subtle"
.Lv_watch: .asciz "watch"
.Lv_repl: .asciz "repl"
.Lv_hover: .asciz "hover"
.Lv_stdout: .asciz "stdout"
.Lv_stderr: .asciz "stderr"
.Lv_console: .asciz "console"
.Lv_important: .asciz "important"
.Lv_telemetry: .asciz "telemetry"
.Le_initialized: .asciz "initialized"
.Le_stopped: .asciz "stopped"
.Le_continued: .asciz "continued"
.Le_output: .asciz "output"
.Le_exited: .asciz "exited"
.Le_terminated: .asciz "terminated"
.Le_thread: .asciz "thread"
.Le_breakpoint: .asciz "breakpoint"
.Le_capabilities: .asciz "capabilities"
.Lcap_configdone: .asciz "supportsConfigurationDoneRequest"
.Lcap_cond: .asciz "supportsConditionalBreakpoints"
.Lcap_hit: .asciz "supportsHitConditionalBreakpoints"
.Lcap_log: .asciz "supportsLogPoints"
.Lcap_funcbp: .asciz "supportsFunctionBreakpoints"
.Lcap_terminate: .asciz "supportsTerminateRequest"
.Lcap_restart: .asciz "supportsRestartRequest"
.Lcap_setvar: .asciz "supportsSetVariable"
.Lcap_hover: .asciz "supportsEvaluateForHovers"
.Lcap_excinfo: .asciz "supportsExceptionInfoRequest"
.Lcap_cancel: .asciz "supportsCancelRequest"
.Lcap_excoptions: .asciz "supportsExceptionFilterOptions"
.p2align 3
init_true:
    .quad .Lk_linesStartAt1, .Lk_columnsStartAt1, .Lk_supportsVariableType
    .quad .Lk_supportsVariablePaging, .Lk_supportsProgressReporting, .Lk_supportsInvalidatedEvent
    .quad .Lk_supportsRunInTerminalRequest, .Lk_supportsStartDebuggingRequest, 0
cap_names:
    .quad .Lcap_configdone, CAP_CONFIGDONE, .Lcap_cond, CAP_COND, .Lcap_hit, CAP_HIT
    .quad .Lcap_log, CAP_LOG, .Lcap_funcbp, CAP_FUNCBP, .Lcap_terminate, CAP_TERMINATE
    .quad .Lcap_restart, CAP_RESTART, .Lcap_setvar, CAP_SETVAR, .Lcap_hover, CAP_HOVER
    .quad .Lcap_excinfo, CAP_EXCINFO, .Lcap_cancel, CAP_CANCEL, .Lcap_excoptions, CAP_EXCOPTIONS
    .quad 0, 0
out_cats:
    .quad .Lv_stdout, DCON_STDOUT, .Lv_stderr, DCON_STDERR, .Lv_console, DCON_CONSOLE
    .quad .Lv_important, DCON_IMPORTANT, .Lv_telemetry, -1, 0, 0
event_table:
    .quad .Le_initialized, e_initialized, .Le_stopped, e_stopped, .Le_continued, e_continued
    .quad .Le_output, e_output, .Le_exited, e_exited, .Le_terminated, e_terminated
    .quad .Le_thread, e_thread, .Le_breakpoint, e_breakpoint, .Le_capabilities, e_capabilities
    .quad 0, 0
resp_table:     # by RQ_*
    .quad 0, r_initialize, r_launch, r_none, r_config, r_config, r_config, r_threads, r_stack
    .quad r_scopes, r_variables, r_none, r_resume, r_none, r_none, r_disconnect, r_setvar, r_excinfo
    .quad r_none, r_repl, r_watch, r_hover, 0
resume_cmds:
    .quad .Lc_continue, .Lc_next, .Lc_stepIn, .Lc_stepOut
state_names:
    .quad .Ls_free, .Ls_initializing, .Ls_configuring, .Ls_running, .Ls_paused, .Ls_terminating
    .quad .Ls_ended, .Ls_connecting, .Ls_approval
ds_buffers:
    .quad DS_launch, DS_rbuf, DS_wq, DS_ebuf, DS_etail, DS_filters, DS_threads, DS_frames
    .quad DS_vars, DS_strs, DS_args, DS_expanded, DS_prevvals, DS_obuf, -1
