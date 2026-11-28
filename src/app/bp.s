# breakpoints: line breakpoints (with a condition, a hit count or a log message) and function
# breakpoints, kept per project in the state folder (PROJECT.debug, with the watches and the
# exception filters chosen), moved with edits, sent to sessions (the whole list of a file, as DAP
# wants), and what each session reports about them (verified, moved, rejected)
.include "rhun.inc"

.bss
.p2align 3
.globl g_bps, g_bp_hooks, g_bp_gen
g_bps: .zero VEC_SIZE           # BP records
g_bp_hooks: .long 0             # 1 while any breakpoint exists: doc.s calls bp_note_*
g_bp_gen: .long 0               # bumped on every change (drawing)
fdirty: .long 0                 # function breakpoints changed
.globl g_bp_muted
g_bp_muted: .long 0             # Mute Breakpoints: none goes to the sessions
save_due: .long 0
.p2align 3
dirty: .zero VEC_SIZE           # owned cstr paths whose list must go to sessions again
excs: .zero SB_SIZE             # chosen exception filters: "TYPE\tFILTER\t0|1\n"
loaded_for: .quad 0             # owned copy of the project the file was read for, or 0
loaded: .long 0
line: .zero SB_SIZE
field: .zero SB_SIZE
fpath: .zero SB_SIZE
.data
bp_next_id: .long 1

.text

# bp_row(i) -> BP*
FN bp_row
    imul rax, rdi, BP_SIZE
    add rax, [rip + g_bps + VEC_ptr]
    ret

# bp_count() -> rax
FN bp_count
    mov rax, [rip + g_bps + VEC_len]
    ret

# changed(): drawing, saving and the hooks follow
changed:
    inc dword ptr [rip + g_bp_gen]
    mov dword ptr [rip + save_due], 1
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    cmp qword ptr [rip + g_bps + VEC_len], 0
    setne al
    mov [rip + g_bp_hooks], eax
    ret

# bp_mute_toggle(): Mute Breakpoints on or off: while on, the sessions get no breakpoints (the
#   breakpoints stay as they are); every file's list goes to them again
FN bp_mute_toggle
    PROLOGUE
    call bp_ensure_loaded
    xor dword ptr [rip + g_bp_muted], 1
    xor ebx, ebx
1:  cmp rbx, [rip + g_bps + VEC_len]
    jae 2f
    mov rdi, rbx
    call bp_row
    cmp dword ptr [rax + BP_kind], 0
    jne 11f
    mov rdi, [rax + BP_path]
    call mark_dirty
11: inc rbx
    jmp 1b
2:  mov dword ptr [rip + fdirty], 1
    call changed
    EPILOGUE

# bp_find(path cstr, line) -> eax the line breakpoint's index, -1
FN bp_find
    PROLOGUE
    call bp_ensure
    mov r12, rdi
    mov r13d, esi
    xor ebx, ebx
1:  cmp rbx, [rip + g_bps + VEC_len]
    jae 8f
    mov rdi, rbx
    call bp_row
    cmp dword ptr [rax + BP_kind], 0
    jne 2f
    cmp [rax + BP_line], r13d
    jne 2f
    mov rdi, [rax + BP_path]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 9f
2:  inc rbx
    jmp 1b
8:  mov ebx, -1
9:  mov eax, ebx
    EPILOGUE

# bp_ensure(): the project's breakpoints are loaded (preserves rdi, rsi, rdx, rcx)
FN bp_ensure_loaded
bp_ensure:
    push rdi
    push rsi
    push rdx
    push rcx
    sub rsp, 8
    mov rdi, [rip + loaded_for]
    mov rsi, [rip + g_project]
    cmp dword ptr [rip + loaded], 0
    je 1f
    test rdi, rdi
    jz 2f
    test rsi, rsi
    jz 1f
    call strcmp_eq
    test eax, eax
    jnz 9f
    jmp 1f
2:  test rsi, rsi
    jz 9f
1:  # another project: what belongs to the one before is saved first (under its own name)
    cmp dword ptr [rip + save_due], 0
    je 3f
    call bp_save
3:  call bp_load
9:  add rsp, 8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

# bp_set(path cstr, line, cond, hit, log) -> eax the index: a line breakpoint added or updated; cond,
#   hit and log are cstrs (an empty one, or 0, removes it)
FN bp_set
    PROLOGUE 32
    mov [rsp], rdi
    mov [rsp + 8], esi
    mov [rsp + 16], rdx
    mov [rsp + 24], rcx
    mov r15, r8
    call bp_find
    test eax, eax
    jns 1f
    cmp qword ptr [rip + g_bps + VEC_len], BP_MAX
    jae 8f
    lea rdi, [rip + g_bps]
    mov esi, BP_SIZE
    call vec_push
    mov rbx, rax
    mov eax, [rip + bp_next_id]
    inc dword ptr [rip + bp_next_id]
    mov [rbx + BP_id], eax
    mov eax, [rsp + 8]
    mov [rbx + BP_line], eax
    mov dword ptr [rbx + BP_enabled], 1
    mov rdi, [rsp]
    call dup_cstr
    mov [rbx + BP_path], rax
    mov rax, [rip + g_bps + VEC_len]
    dec rax
1:  mov r12d, eax
    mov edi, eax
    call bp_row
    mov rbx, rax
    lea rdi, [rbx + BP_cond]
    mov rsi, [rsp + 16]
    call set_opt
    lea rdi, [rbx + BP_hit]
    mov rsi, [rsp + 24]
    call set_opt
    lea rdi, [rbx + BP_log]
    mov rsi, r15
    call set_opt
    mov rdi, [rbx + BP_path]
    call mark_dirty
    call changed
    mov eax, r12d
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# set_opt(slot*, cstr or 0): an owned optional string; empty means none
set_opt:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx]
    call mem_free
    mov qword ptr [rbx], 0
    test r12, r12
    jz 1f
    cmp byte ptr [r12], 0
    je 1f
    mov rdi, r12
    call dup_cstr
    mov [rbx], rax
1:  add rsp, 8
    pop r12
    pop rbx
    ret

# bp_index_of_id(id) -> eax its index, -1
FN bp_index_of_id
    xor ecx, ecx
1:  cmp rcx, [rip + g_bps + VEC_len]
    jae 8f
    imul rax, rcx, BP_SIZE
    add rax, [rip + g_bps + VEC_ptr]
    cmp [rax + BP_id], edi
    je 9f
    inc rcx
    jmp 1b
8:  mov eax, -1
    ret
9:  mov eax, ecx
    ret

# bp_set_option(index, which, cstr): 1 its condition, 2 its hit count, 3 its log message (an empty
#   text removes it); the file's list goes to the sessions again
FN bp_set_option
    PROLOGUE
    mov r12d, esi
    mov r13, rdx
    call bp_row
    mov rbx, rax
    lea rdi, [rbx + BP_cond]
    cmp r12d, 2
    jne 1f
    lea rdi, [rbx + BP_hit]
1:  cmp r12d, 3
    jne 2f
    lea rdi, [rbx + BP_log]
2:  mov rsi, r13
    call set_opt
    mov rdi, [rbx + BP_path]
    call mark_dirty
    call changed
    EPILOGUE

# bp_save_soon(): the state file is written at the next tick (a watch changed)
FN bp_save_soon
    mov dword ptr [rip + save_due], 1
    ret

# bp_toggle(path cstr, line): removes the line breakpoint there, or adds one
FN bp_toggle
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    call bp_find
    test eax, eax
    js 1f
    mov edi, eax
    call bp_remove
    EPILOGUE
1:  mov rdi, r12
    mov esi, r13d
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call bp_set
    EPILOGUE

# bp_enable(index, enabled)
FN bp_enable
    push rbx
    push r12
    sub rsp, 8
    mov r12d, esi
    call bp_row
    mov rbx, rax
    mov [rbx + BP_enabled], r12d
    cmp dword ptr [rbx + BP_kind], 0
    jne 1f
    mov rdi, [rbx + BP_path]
    call mark_dirty
    jmp 2f
1:  mov dword ptr [rip + fdirty], 1
2:  call changed
    add rsp, 8
    pop r12
    pop rbx
    ret

# bp_remove(index)
FN bp_remove
    PROLOGUE
    mov r12d, edi
    call bp_row
    mov rbx, rax
    cmp dword ptr [rbx + BP_kind], 0
    jne 1f
    mov rdi, [rbx + BP_path]
    call mark_dirty
    jmp 2f
1:  mov dword ptr [rip + fdirty], 1
2:  mov rdi, rbx
    call bp_free_strs
    # the last takes its place
    mov rax, [rip + g_bps + VEC_len]
    dec rax
    mov [rip + g_bps + VEC_len], rax
    cmp r12, rax
    je 3f
    mov rdi, rax
    call bp_row
    mov rdi, rbx
    mov rsi, rax
    mov edx, BP_SIZE
    call memcpy
3:  call changed
    EPILOGUE

# bp_free_strs(bp)
bp_free_strs:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + BP_path]
    call mem_free
    mov rdi, [rbx + BP_cond]
    call mem_free
    mov rdi, [rbx + BP_hit]
    call mem_free
    mov rdi, [rbx + BP_log]
    call mem_free
    xor r12d, r12d
1:  mov rdi, [rbx + BP_msg + r12*8]
    call mem_free
    inc r12d
    cmp r12d, DS_MAX
    jb 1b
    EPILOGUE

# bp_function(name cstr, cond cstr or 0) -> eax index: a function breakpoint added (or its condition
#   changed)
FN bp_function
    PROLOGUE
    call bp_ensure
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, [rip + g_bps + VEC_len]
    jae 2f
    mov rdi, rbx
    call bp_row
    cmp dword ptr [rax + BP_kind], 1
    jne 11f
    mov rdi, [rax + BP_path]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 3f
11: inc rbx
    jmp 1b
2:  cmp qword ptr [rip + g_bps + VEC_len], BP_MAX
    jae 8f
    lea rdi, [rip + g_bps]
    mov esi, BP_SIZE
    call vec_push
    mov r14, rax
    mov eax, [rip + bp_next_id]
    inc dword ptr [rip + bp_next_id]
    mov [r14 + BP_id], eax
    mov dword ptr [r14 + BP_kind], 1
    mov dword ptr [r14 + BP_enabled], 1
    mov rdi, r12
    call dup_cstr
    mov [r14 + BP_path], rax
    mov rbx, [rip + g_bps + VEC_len]
    dec rbx
3:  mov rdi, rbx
    call bp_row
    lea rdi, [rax + BP_cond]
    mov rsi, r13
    call set_opt
    mov dword ptr [rip + fdirty], 1
    call changed
    mov eax, ebx
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# bp_clear_all(): every breakpoint goes
FN bp_clear_all
    PROLOGUE
    call bp_ensure
1:  mov rax, [rip + g_bps + VEC_len]
    test rax, rax
    jz 9f
    lea rdi, [rax - 1]
    call bp_remove
    jmp 1b
9:  EPILOGUE

# mark_dirty(path cstr): its list goes to the sessions at the next tick
mark_dirty:
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + dirty + VEC_len]
    jae 2f
    mov rax, [rip + dirty + VEC_ptr]
    mov rdi, [rax + rbx*8]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 9f
    inc rbx
    jmp 1b
2:  mov rdi, r12
    call dup_cstr
    mov rbx, rax
    lea rdi, [rip + dirty]
    mov esi, 8
    call vec_push
    mov [rax], rbx
9:  EPILOGUE

# ---------------- sessions ----------------

# session_ready(ds) -> eax 1 when the session takes breakpoints now (configuration began, debugging)
session_ready:
    xor eax, eax
    cmp dword ptr [rdi + DS_nodebug], 0
    jne 1f
    test dword ptr [rdi + DS_flags], DSF_INITIALIZED
    jz 1f
    cmp dword ptr [rdi + DS_state], DSS_TERMINATING
    jae 1f
    cmp dword ptr [rdi + DS_in], 0
    jl 1f
    mov eax, 1
1:  ret

# bp_tick(): changed lists go to the sessions; the file is saved
FN bp_tick
    PROLOGUE
    cmp qword ptr [rip + dirty + VEC_len], 0
    jne 1f
    cmp dword ptr [rip + fdirty], 0
    je 7f
1:  xor r12d, r12d
2:  cmp r12d, DS_MAX
    jae 6f
    mov edi, r12d
    call dap_slot
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_FREE
    je 5f
    mov rdi, rbx
    call session_ready
    test eax, eax
    jz 5f
    xor r13d, r13d
3:  cmp r13, [rip + dirty + VEC_len]
    jae 4f
    mov rax, [rip + dirty + VEC_ptr]
    mov rsi, [rax + r13*8]
    mov rdi, rbx
    call bp_send_file
    inc r13
    jmp 3b
4:  cmp dword ptr [rip + fdirty], 0
    je 5f
    mov rdi, rbx
    call send_functions
5:  inc r12d
    jmp 2b
6:  # done
    xor r13d, r13d
61: cmp r13, [rip + dirty + VEC_len]
    jae 62f
    mov rax, [rip + dirty + VEC_ptr]
    mov rdi, [rax + r13*8]
    call mem_free
    inc r13
    jmp 61b
62: mov qword ptr [rip + dirty + VEC_len], 0
    mov dword ptr [rip + fdirty], 0
7:  cmp dword ptr [rip + save_due], 0
    je 9f
    call bp_save
9:  EPILOGUE

# bp_send_all(ds) -> eax requests sent: a setBreakpoints per file with enabled breakpoints and
#   setFunctionBreakpoints when the adapter takes them and there are some
FN bp_send_all
    PROLOGUE
    mov rbx, rdi
    call bp_ensure
    xor r13d, r13d              # sent
    xor r12d, r12d
1:  cmp r12, [rip + g_bps + VEC_len]
    jae 4f
    mov rdi, r12
    call bp_row
    mov r14, rax
    cmp dword ptr [r14 + BP_kind], 0
    jne 3f
    cmp dword ptr [r14 + BP_enabled], 0
    je 3f
    # the first enabled breakpoint of its file sends the file
    xor r15d, r15d
2:  cmp r15, r12
    jae 21f
    mov rdi, r15
    call bp_row
    cmp dword ptr [rax + BP_kind], 0
    jne 22f
    cmp dword ptr [rax + BP_enabled], 0
    je 22f
    mov rdi, [rax + BP_path]
    mov rsi, [r14 + BP_path]
    call strcmp_eq
    test eax, eax
    jnz 3f
22: inc r15
    jmp 2b
21: mov rdi, rbx
    mov rsi, [r14 + BP_path]
    call bp_send_file
    add r13d, eax
3:  inc r12
    jmp 1b
4:  mov rdi, rbx
    call send_functions
    add r13d, eax
    mov eax, r13d
    EPILOGUE

# bp_send_file(ds, path cstr) -> eax 1 when setBreakpoints went out with the file's enabled line
#   breakpoints. One the adapter cannot take (a condition, a hit count or a log message it does not
#   support) is left out and marked rejected.
FN bp_send_file
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call dap_slot_of
    mov [rsp + 8], eax
    # the ids sent, in order: [count][id]...
    mov rdi, [rip + g_bps + VEC_len]
    lea rdi, [rdi*4 + 8]
    call mem_alloc
    mov r15, rax
    mov dword ptr [r15], 0
    mov rdi, rbx
    lea rsi, [rip + .Lc_setBreakpoints]
    call dap_req_begin
    lea rdi, [rip + .Lk_source]
    call ak
    lea rdi, [rip + g_dmsg]
    call jw_obj
    lea rdi, [rip + .Lk_path]
    mov rsi, r12
    call akv
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call path_basename
    mov rsi, rax
    lea rdi, [rip + .Lk_name]
    call aks
    lea rdi, [rip + g_dmsg]
    call jw_end_obj
    lea rdi, [rip + .Lk_breakpoints]
    call ak
    lea rdi, [rip + g_dmsg]
    call jw_arr
    xor r13d, r13d
1:  cmp r13, [rip + g_bps + VEC_len]
    jae 5f
    mov rdi, r13
    call bp_row
    mov r14, rax
    cmp dword ptr [r14 + BP_kind], 0
    jne 4f
    cmp dword ptr [r14 + BP_enabled], 0
    je 4f
    cmp dword ptr [rip + g_bp_muted], 0
    jne 4f                      # muted: none goes
    mov rdi, [r14 + BP_path]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jz 4f
    cmp dword ptr [r15], BP_PER_FILE
    jae 4f
    mov rdi, rbx
    mov rsi, r14
    call unsupported
    test rax, rax
    jz 2f
    mov ecx, [rsp + 8]
    mov dword ptr [r14 + BP_ver + rcx*4], 3
    lea rdi, [r14 + BP_msg + rcx*8]
    mov rsi, rax
    call set_opt
    jmp 4f
2:  mov eax, [r15]
    inc dword ptr [r15]
    mov ecx, [r14 + BP_id]
    mov [r15 + rax*4 + 4], ecx
    lea rdi, [rip + g_dmsg]
    call jw_obj
    lea rdi, [rip + .Lk_line]
    mov esi, [r14 + BP_line]
    call aki
    mov rsi, [r14 + BP_cond]
    test rsi, rsi
    jz 21f
    lea rdi, [rip + .Lk_condition]
    call akv
21: mov rsi, [r14 + BP_hit]
    test rsi, rsi
    jz 22f
    lea rdi, [rip + .Lk_hitCondition]
    call akv
22: mov rsi, [r14 + BP_log]
    test rsi, rsi
    jz 23f
    lea rdi, [rip + .Lk_logMessage]
    call akv
23: lea rdi, [rip + g_dmsg]
    call jw_end_obj
    mov ecx, [rsp + 8]
    cmp dword ptr [r14 + BP_ver + rcx*4], 0
    jne 4f
    mov dword ptr [r14 + BP_ver + rcx*4], 1     # sent, not verified yet
4:  inc r13
    jmp 1b
5:  lea rdi, [rip + g_dmsg]
    call jw_end_arr
    lea rdi, [rip + .Lk_sourceModified]
    xor esi, esi
    call akb
    mov rdi, rbx
    mov esi, RQ_SETBP
    mov rdx, r15
    call dap_req_send
    test eax, eax
    setnz al
    movzx eax, al
    inc dword ptr [rip + g_bp_gen]
    EPILOGUE

# unsupported(ds, bp) -> rax the reason the adapter cannot take the breakpoint, or 0
unsupported:
    mov rax, [rdi + DS_caps]
    cmp qword ptr [rsi + BP_cond], 0
    je 1f
    test rax, CAP_COND
    jz 8f
1:  cmp qword ptr [rsi + BP_hit], 0
    je 2f
    test rax, CAP_HIT
    jz 8f
2:  cmp qword ptr [rsi + BP_log], 0
    je 3f
    test rax, CAP_LOG
    jz 9f
3:  xor eax, eax
    ret
8:  lea rax, [rip + .Lm_nocond]
    ret
9:  lea rax, [rip + .Lm_nolog]
    ret

# dap_slot_of(ds) -> eax its slot
dap_slot_of:
    mov rax, rdi
    lea rcx, [rip + g_dsess]
    sub rax, rcx
    xor edx, edx
    mov ecx, DS_SIZE
    div rcx
    ret

# send_functions(ds) -> eax 1 when setFunctionBreakpoints went out
send_functions:
    PROLOGUE 16
    mov rbx, rdi
    test qword ptr [rbx + DS_caps], CAP_FUNCBP
    jz 8f
    # any function breakpoints at all (or a change to none)?
    xor r12d, r12d
    xor r13d, r13d
1:  cmp r12, [rip + g_bps + VEC_len]
    jae 2f
    mov rdi, r12
    call bp_row
    cmp dword ptr [rax + BP_kind], 1
    jne 11f
    inc r13d
11: inc r12
    jmp 1b
2:  test r13d, r13d
    jnz 3f
    cmp dword ptr [rip + fdirty], 0
    je 8f
3:  mov rdi, rbx
    lea rsi, [rip + .Lc_setFunctionBreakpoints]
    call dap_req_begin
    lea rdi, [rip + .Lk_breakpoints]
    call ak
    lea rdi, [rip + g_dmsg]
    call jw_arr
    xor r12d, r12d
4:  cmp r12, [rip + g_bps + VEC_len]
    jae 5f
    mov rdi, r12
    call bp_row
    mov r14, rax
    cmp dword ptr [r14 + BP_kind], 1
    jne 41f
    cmp dword ptr [r14 + BP_enabled], 0
    je 41f
    cmp dword ptr [rip + g_bp_muted], 0
    jne 41f
    lea rdi, [rip + g_dmsg]
    call jw_obj
    lea rdi, [rip + .Lk_name]
    mov rsi, [r14 + BP_path]
    call akv
    mov rsi, [r14 + BP_cond]
    test rsi, rsi
    jz 42f
    lea rdi, [rip + .Lk_condition]
    call akv
42: lea rdi, [rip + g_dmsg]
    call jw_end_obj
41: inc r12
    jmp 4b
5:  lea rdi, [rip + g_dmsg]
    call jw_end_arr
    mov rdi, rbx
    mov esi, RQ_SETFBP
    xor edx, edx
    call dap_req_send
    test eax, eax
    setnz al
    movzx eax, al
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# bp_on_set(ds, ids, body, success): setBreakpoints' answer: the adapter's id, verified, line and
#   message of each breakpoint sent, in order
FN bp_on_set
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
    mov rdi, rbx
    call dap_slot_of
    mov [rsp + 4], eax
    mov rdi, r13
    lea rsi, [rip + .Lk_breakpoints]
    call json_get
    mov [rsp + 8], rax
    xor r14d, r14d
1:  cmp r14d, [r12]
    jae 9f
    mov edi, [r12 + r14*4 + 4]
    call bp_by_id
    test rax, rax
    jz 5f                       # removed meanwhile
    mov r15, rax
    mov ecx, [rsp + 4]
    cmp dword ptr [rsp], 0
    jne 2f
    mov dword ptr [r15 + BP_ver + rcx*4], 3
    jmp 5f
2:  mov rdi, [rsp + 8]
    mov esi, r14d
    call json_at
    test rax, rax
    jz 5f
    mov rdi, rbx
    mov rsi, r15
    mov rdx, rax
    call bp_take_state
5:  inc r14d
    jmp 1b
9:  inc dword ptr [rip + g_bp_gen]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# bp_take_state(ds, bp, breakpoint JV): id, verified, line and message as this session reports them
bp_take_state:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    call dap_slot_of
    mov r14d, eax
    mov rdi, r13
    lea rsi, [rip + .Lk_id]
    call json_get
    mov rdi, rax
    call json_int
    test edx, edx
    jz 1f
    mov [r12 + BP_sid + r14*4], eax
1:  mov rdi, r13
    lea rsi, [rip + .Lk_verified]
    call json_get
    mov rdi, rax
    call json_bool
    lea eax, [rax + 1]          # 1 unverified, 2 verified
    mov [r12 + BP_ver + r14*4], eax
    mov rdi, r13
    lea rsi, [rip + .Lk_line]
    call json_get
    mov rdi, rax
    call json_int
    test edx, edx
    jz 2f
    mov [r12 + BP_aline + r14*4], eax
2:  mov rdi, r13
    lea rsi, [rip + .Lk_message]
    call json_get
    mov rdi, rax
    call json_str
    lea rdi, [r12 + BP_msg + r14*8]
    push rdi
    push rax
    push rdx
    push rdx
    mov rdi, [rdi]
    call mem_free
    pop rdx
    pop rdx
    pop rsi
    pop rdi
    mov qword ptr [rdi], 0
    test rdx, rdx
    jz 9f
    push rdi
    push rdi
    mov rdi, rsi
    mov rsi, rdx
    cmp rsi, 1024
    jbe 3f
    mov esi, 1024
3:  call mem_dup
    pop rdi
    pop rdi
    mov [rdi], rax
9:  EPILOGUE

# bp_by_id(id) -> BP* or 0
bp_by_id:
    xor ecx, ecx
1:  cmp rcx, [rip + g_bps + VEC_len]
    jae 8f
    imul rax, rcx, BP_SIZE
    add rax, [rip + g_bps + VEC_ptr]
    cmp [rax + BP_id], edi
    je 9f
    inc rcx
    jmp 1b
8:  xor eax, eax
9:  ret

# bp_on_event(ds, breakpoint JV): the breakpoint event (changed): found by the adapter's id
FN bp_on_event
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call dap_slot_of
    mov r13d, eax
    mov rdi, r12
    lea rsi, [rip + .Lk_id]
    call json_get
    mov rdi, rax
    call json_int
    test edx, edx
    jz 9f
    test eax, eax
    jz 9f
    mov r14d, eax
    xor r15d, r15d
1:  cmp r15, [rip + g_bps + VEC_len]
    jae 9f
    mov rdi, r15
    call bp_row
    cmp [rax + BP_sid + r13*4], r14d
    je 2f
    inc r15
    jmp 1b
2:  mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    call bp_take_state
    inc dword ptr [rip + g_bp_gen]
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# bp_session_gone(slot): nothing is known about breakpoints in that session any more
FN bp_session_gone
    PROLOGUE
    mov r12d, edi
    xor ebx, ebx
1:  cmp rbx, [rip + g_bps + VEC_len]
    jae 9f
    mov rdi, rbx
    call bp_row
    mov dword ptr [rax + BP_sid + r12*4], 0
    mov dword ptr [rax + BP_aline + r12*4], 0
    mov dword ptr [rax + BP_ver + r12*4], 0
    lea rdi, [rax + BP_msg + r12*8]
    push rdi
    push rdi
    mov rdi, [rdi]
    call mem_free
    pop rdi
    pop rdi
    mov qword ptr [rdi], 0
    inc rbx
    jmp 1b
9:  inc dword ptr [rip + g_bp_gen]
    EPILOGUE

# ---------------- exception filters ----------------

# exc_enabled(ds, filter ptr, len) -> eax 1 or 0 as the user chose for the debugger's type, -1 when
#   not chosen (the adapter's default applies)
FN exc_enabled
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    call bp_ensure
    mov edi, [rdi + DS_dbg]
    call dbg_row
    mov r14, [rax + DBG_type]
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    call exc_find
    test rax, rax
    js 8f
    movzx eax, byte ptr [rax]
    sub eax, '0'
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# exc_find(type cstr, filter ptr, len) -> rax pointer to the 0|1 of its line in excs, -1
exc_find:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rbx, [rip + excs + SB_ptr]
    mov r15, [rip + excs + SB_len]
    add r15, rbx
1:  cmp rbx, r15
    jae 8f
    # TYPE \t FILTER \t V \n
    mov rcx, rbx
2:  cmp byte ptr [rcx], 9
    je 3f
    inc rcx
    jmp 2b
3:  push rcx
    push rcx
    mov rdi, rbx
    mov rsi, rcx
    sub rsi, rbx
    mov rdx, r12
    call str_eq_cstr
    pop rcx
    pop rcx
    lea rbx, [rcx + 1]
    mov rcx, rbx
4:  cmp byte ptr [rcx], 9
    je 5f
    inc rcx
    jmp 4b
5:  test eax, eax
    jz 6f
    push rcx
    push rcx
    mov rdi, rbx
    mov rsi, rcx
    sub rsi, rbx
    mov rdx, r13
    mov rcx, r14
    call str_eq
    pop rcx
    pop rcx
    test eax, eax
    jz 6f
    lea rax, [rcx + 1]
    EPILOGUE
6:  cmp byte ptr [rcx], 10
    je 7f
    inc rcx
    jmp 6b
7:  lea rbx, [rcx + 1]
    jmp 1b
8:  mov rax, -1
    EPILOGUE

# bp_exc_set(type cstr, filter ptr, len, on): the user's choice; sessions of that type get the list
FN bp_exc_set
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov [rsp], ecx
    call bp_ensure
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call exc_find
    test rax, rax
    js 1f
    mov ecx, [rsp]
    add ecx, '0'
    mov [rax], cl
    jmp 2f
1:  lea rdi, [rip + excs]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + excs]
    mov esi, 9
    call sb_push_byte
    lea rdi, [rip + excs]
    mov rsi, r13
    mov rdx, r14
    call sb_push_clean_bp
    lea rdi, [rip + excs]
    mov esi, 9
    call sb_push_byte
    mov esi, [rsp]
    add esi, '0'
    lea rdi, [rip + excs]
    call sb_push_byte
    lea rdi, [rip + excs]
    mov esi, 10
    call sb_push_byte
2:  call changed
    # sessions of this type that take breakpoints now
    xor r15d, r15d
3:  cmp r15d, DS_MAX
    jae 9f
    mov edi, r15d
    call dap_slot
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_FREE
    je 4f
    mov rdi, rbx
    call session_ready
    test eax, eax
    jz 4f
    mov edi, [rbx + DS_dbg]
    call dbg_row
    mov rdi, [rax + DBG_type]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jz 4f
    mov rdi, rbx
    call send_exc_filters
4:  inc r15d
    jmp 3b
9:  EPILOGUE

# sb_push_clean_bp(sb, ptr, len): bytes with tabs and newlines as spaces
FN sb_push_clean_bp
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

# ---------------- following edits ----------------

# bp_note_insert(doc, line, new lines, pos): text with newlines was inserted on a line (zero-based):
#   breakpoints below move down, and the line's own when the text went in at its start
FN bp_note_insert
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, [rbx + DOC_path]
    test r15, r15
    jz 9f
    mov rax, [rbx + DOC_lines]
    xor ecx, ecx
    cmp [rax + r12*8], r14
    sete cl
    push rcx
    push rcx
    xor ebx, ebx
1:  cmp rbx, [rip + g_bps + VEC_len]
    jae 8f
    mov rdi, rbx
    call bp_row
    cmp dword ptr [rax + BP_kind], 0
    jne 3f
    mov ecx, [rax + BP_line]
    dec ecx                     # zero-based
    cmp rcx, r12
    jb 3f
    ja 2f
    cmp dword ptr [rsp], 0
    je 3f
2:  push rax
    push rax
    mov rdi, [rax + BP_path]
    mov rsi, r15
    call strcmp_eq
    pop rcx
    pop rcx
    test eax, eax
    jz 3f
    add [rcx + BP_line], r13d
    mov rdi, r15
    call mark_dirty
    call changed
3:  inc rbx
    jmp 1b
8:  pop rcx
    pop rcx
9:  EPILOGUE

# bp_note_delete(doc, line, lines removed): lines after `line` (zero-based) were joined into it:
#   a breakpoint on a removed line moves to `line`, those below move up; duplicates merge
FN bp_note_delete
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r15, [rbx + DOC_path]
    test r15, r15
    jz 9f
    xor r14d, r14d              # moved any
    xor ebx, ebx
1:  cmp rbx, [rip + g_bps + VEC_len]
    jae 5f
    mov rdi, rbx
    call bp_row
    cmp dword ptr [rax + BP_kind], 0
    jne 4f
    mov ecx, [rax + BP_line]
    dec ecx
    cmp rcx, r12
    jbe 4f
    push rax
    push rcx
    mov rdi, [rax + BP_path]
    mov rsi, r15
    call strcmp_eq
    pop rcx
    pop rdx
    test eax, eax
    jz 4f
    lea rax, [r12 + r13]
    cmp rcx, rax
    ja 2f
    lea eax, [r12 + 1]          # onto the line itself
    mov [rdx + BP_line], eax
    jmp 3f
2:  sub [rdx + BP_line], r13d
3:  mov r14d, 1
4:  inc rbx
    jmp 1b
5:  test r14d, r14d
    jz 9f
    mov rdi, r15
    call mark_dirty
    mov rdi, r15
    call merge_dups
    call changed
9:  EPILOGUE

# merge_dups(path cstr): two line breakpoints of the file on one line become the first
merge_dups:
    PROLOGUE
    mov r15, rdi
    xor r12d, r12d
1:  cmp r12, [rip + g_bps + VEC_len]
    jae 9f
    mov rdi, r12
    call bp_row
    mov r13, rax
    cmp dword ptr [r13 + BP_kind], 0
    jne 5f
    mov rdi, [r13 + BP_path]
    mov rsi, r15
    call strcmp_eq
    test eax, eax
    jz 5f
    lea r14, [r12 + 1]
2:  cmp r14, [rip + g_bps + VEC_len]
    jae 5f
    mov rdi, r14
    call bp_row
    cmp dword ptr [rax + BP_kind], 0
    jne 4f
    mov ecx, [rax + BP_line]
    cmp ecx, [r13 + BP_line]
    jne 4f
    mov rdi, [rax + BP_path]
    mov rsi, r15
    call strcmp_eq
    test eax, eax
    jz 4f
    mov rdi, r14
    call bp_remove
    mov rdi, r12                # r13 may have moved (the last record took a slot)
    call bp_row
    mov r13, rax
    jmp 2b
4:  inc r14
    jmp 2b
5:  inc r12
    jmp 1b
9:  EPILOGUE

# ---------------- for tests and drawing ----------------

# bp_dump(sb): per breakpoint "PATH LINE enabled=B cond=C hits=H log=L verified=V line=N msg=M" as
#   the focused session reports it (V: - not sent, 0 unverified, 1 verified, x rejected); function
#   breakpoints as "function NAME enabled=B cond=C"
FN bp_dump
    PROLOGUE 16
    mov r15, rdi
    call bp_ensure
    mov eax, [rip + g_dfocus]
    mov [rsp], eax
    xor r12d, r12d
1:  cmp r12, [rip + g_bps + VEC_len]
    jae 9f
    mov rdi, r12
    call bp_row
    mov rbx, rax
    cmp dword ptr [rbx + BP_kind], 0
    je 2f
    mov rdi, r15
    lea rsi, [rip + .Ld_function]
    call sb_push_cstr
2:  mov rdi, r15
    mov rsi, [rbx + BP_path]
    call sb_push_cstr
    cmp dword ptr [rbx + BP_kind], 0
    jne 3f
    mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    mov rdi, r15
    mov esi, [rbx + BP_line]
    call sb_push_u64
3:  mov rdi, r15
    lea rsi, [rip + .Ld_enabled]
    call sb_push_cstr
    mov esi, [rbx + BP_enabled]
    add esi, '0'
    mov rdi, r15
    call sb_push_byte
    lea rsi, [rip + .Ld_cond]
    mov rdx, [rbx + BP_cond]
    call dump_opt
    cmp dword ptr [rbx + BP_kind], 0
    jne 8f
    lea rsi, [rip + .Ld_hits]
    mov rdx, [rbx + BP_hit]
    call dump_opt
    lea rsi, [rip + .Ld_log]
    mov rdx, [rbx + BP_log]
    call dump_opt
    mov rdi, r15
    lea rsi, [rip + .Ld_verified]
    call sb_push_cstr
    mov esi, '-'
    mov ecx, [rsp]
    test ecx, ecx
    js 4f
    mov eax, [rbx + BP_ver + rcx*4]
    lea rdx, [rip + .Lver_chars]
    movzx esi, byte ptr [rdx + rax]
4:  mov rdi, r15
    call sb_push_byte
    mov rdi, r15
    lea rsi, [rip + .Ld_line]
    call sb_push_cstr
    xor esi, esi
    mov ecx, [rsp]
    test ecx, ecx
    js 5f
    mov esi, [rbx + BP_aline + rcx*4]
5:  mov rdi, r15
    call sb_push_u64
    lea rsi, [rip + .Ld_msg]
    xor edx, edx
    mov ecx, [rsp]
    test ecx, ecx
    js 6f
    mov rdx, [rbx + BP_msg + rcx*8]
6:  call dump_opt
8:  mov rdi, r15
    mov esi, 10
    call sb_push_byte
    inc r12
    jmp 1b
9:  EPILOGUE
# dump_opt: " key=" + the cstr (rdx, or nothing) into r15
dump_opt:
    push rdx
    push rdx
    mov rdi, r15
    call sb_push_cstr
    pop rsi
    pop rsi
    test rsi, rsi
    jz 1f
    mov rdi, r15
    jmp sb_push_cstr
1:  ret

# bp_line_state(path cstr, zero-based line) -> eax 0 none, else 1 + index of the breakpoint there,
#   for the gutter; the line is the user's (the adapter's moved line is shown by the focused session)
FN bp_at
    PROLOGUE
    mov r12, rdi
    lea r13d, [rsi + 1]
    mov rdi, r12
    mov esi, r13d
    call bp_find
    lea eax, [rax + 1]
    EPILOGUE

# ---------------- the file ----------------

# bp_load(): PROJECT.debug in the state folder: breakpoints, watches and exception filters
FN bp_load
    PROLOGUE 16
    # what was loaded belongs to the old project: dropped
1:  mov rax, [rip + g_bps + VEC_len]
    test rax, rax
    jz 2f
    dec rax
    mov [rip + g_bps + VEC_len], rax
    mov rdi, rax
    call bp_row
    mov rdi, rax
    call bp_free_strs
    jmp 1b
2:  lea rdi, [rip + excs]
    call sb_clear
    lea rdi, [rip + g_watches]
    call sb_clear
    mov rdi, [rip + loaded_for]
    call mem_free
    mov qword ptr [rip + loaded_for], 0
    mov dword ptr [rip + loaded], 1
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 3f
    call dup_cstr
    mov [rip + loaded_for], rax
3:  call debug_file
    test rax, rax
    jz 9f
    mov rdi, rax
    mov esi, 4194304
    call file_read_limited
    test rax, rax
    jz 9f
    mov r12, rax
    lea r13, [rax + rdx]
    mov [rsp], rax
4:  cmp r12, r13
    jae 8f
    mov rcx, r12
5:  cmp rcx, r13
    jae 6f
    cmp byte ptr [rcx], 10
    je 6f
    inc rcx
    jmp 5b
6:  mov r14, rcx
    mov rdi, r12
    mov rsi, rcx
    sub rsi, r12
    call load_line
    lea r12, [r14 + 1]
    jmp 4b
8:  mov rdi, [rsp]
    call mem_free
9:  mov dword ptr [rip + save_due], 0
    xor eax, eax
    cmp qword ptr [rip + g_bps + VEC_len], 0
    setne al
    mov [rip + g_bp_hooks], eax
    inc dword ptr [rip + g_bp_gen]
    EPILOGUE

# debug_file() -> rax the state file's path (static) for the project the state was loaded for, or 0
#   without one
debug_file:
    push rbx
    mov rbx, [rip + g_project]
    mov rax, [rip + loaded_for]
    test rax, rax
    jz 1f
    mov [rip + g_project], rax
    lea rdi, [rip + .Lsuffix]
    call session_project_file
    mov [rip + g_project], rbx
1:  pop rbx
    ret

# field_next(ptr*, end) -> unescaped next tab-separated field in `field` (NUL-terminated); rax its
#   length, -1 at the end of the line
field_next:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx]
    mov r13, rsi
    cmp r12, r13
    ja 8f
    lea rdi, [rip + field]
    call sb_clear
1:  cmp r12, r13
    jae 4f
    movzx eax, byte ptr [r12]
    inc r12
    cmp eax, 9
    je 5f
    cmp eax, 92
    jne 3f
    cmp r12, r13
    jae 3f
    movzx eax, byte ptr [r12]
    inc r12
    cmp eax, 't'
    jne 21f
    mov eax, 9
    jmp 3f
21: cmp eax, 'n'
    jne 3f
    mov eax, 10
3:  lea rdi, [rip + field]
    mov esi, eax
    call sb_push_byte
    jmp 1b
4:  inc r12                     # past the end: the next call ends
5:  mov [rbx], r12
    lea rdi, [rip + field]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rip + field + SB_len]
    mov rax, [rip + field + SB_len]
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# load_line(ptr, len): one line of the file
load_line:
    PROLOGUE 48
    mov [rsp], rdi
    lea rax, [rdi + rsi]
    mov [rsp + 8], rax
    lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    cmp rax, 1
    jne 9f
    mov rax, [rip + field + SB_ptr]
    movzx eax, byte ptr [rax]
    cmp eax, 'b'
    je .Lll_b
    cmp eax, 'f'
    je .Lll_f
    cmp eax, 'x'
    je .Lll_x
    cmp eax, 'w'
    je .Lll_w
    jmp 9f
.Lll_b:
    # b PATH LINE ENABLED COND HIT LOG (a relative path is inside the project)
    lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    test rax, rax
    jle 9f
    lea rdi, [rip + fpath]
    call sb_clear
    mov rax, [rip + field + SB_ptr]
    PATH_ABSOLUTE rax, 1f
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + fpath]
    call sb_push_cstr
    lea rdi, [rip + fpath]
    mov esi, '/'
    call sb_push_byte
1:  lea rdi, [rip + fpath]
    mov rsi, [rip + field + SB_ptr]
    call sb_push_cstr
    lea rdi, [rip + fpath]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    mov rdi, [rip + field + SB_ptr]
    mov rsi, rax
    call parse_u64
    test eax, eax
    jz 9f
    mov [rsp + 16], eax         # line
    lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    mov rax, [rip + field + SB_ptr]
    movzx eax, byte ptr [rax]
    cmp eax, '0'
    setne al
    movzx eax, al
    mov [rsp + 20], eax         # enabled
    # cond, hit, log: copies, as field is reused
    xor ebx, ebx
2:  lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    xor ecx, ecx
    test rax, rax
    jle 3f
    mov rdi, [rip + field + SB_ptr]
    call dup_cstr
    mov rcx, rax
3:  mov [rsp + 24 + rbx*8], rcx
    inc ebx
    cmp ebx, 3
    jb 2b
    mov rdi, [rip + fpath + SB_ptr]
    mov esi, [rsp + 16]
    mov rdx, [rsp + 24]
    mov rcx, [rsp + 32]
    mov r8, [rsp + 40]
    call bp_set_raw
    test eax, eax
    js 4f
    mov edi, eax
    call bp_row
    mov ecx, [rsp + 20]
    mov [rax + BP_enabled], ecx
4:  mov rdi, [rsp + 24]
    call mem_free
    mov rdi, [rsp + 32]
    call mem_free
    mov rdi, [rsp + 40]
    call mem_free
    jmp 9f
.Lll_f:
    lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    test rax, rax
    jle 9f
    mov rdi, [rip + field + SB_ptr]
    call dup_cstr
    mov [rsp + 24], rax
    lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    mov rax, [rip + field + SB_ptr]
    movzx eax, byte ptr [rax]
    cmp eax, '0'
    setne al
    movzx eax, al
    mov [rsp + 20], eax
    lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    xor esi, esi
    test rax, rax
    jle 5f
    mov rsi, [rip + field + SB_ptr]
5:  mov rdi, [rsp + 24]
    call bp_function_raw
    test eax, eax
    js 6f
    mov edi, eax
    call bp_row
    mov ecx, [rsp + 20]
    mov [rax + BP_enabled], ecx
6:  mov rdi, [rsp + 24]
    call mem_free
    jmp 9f
.Lll_x:
    # x TYPE FILTER 0|1
    lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    test rax, rax
    jle 9f
    lea rdi, [rip + excs]
    mov rsi, [rip + field + SB_ptr]
    mov rdx, rax
    call sb_push_clean_bp
    lea rdi, [rip + excs]
    mov esi, 9
    call sb_push_byte
    lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    lea rdi, [rip + excs]
    mov rsi, [rip + field + SB_ptr]
    mov rdx, rax
    call sb_push_clean_bp
    lea rdi, [rip + excs]
    mov esi, 9
    call sb_push_byte
    lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    mov rax, [rip + field + SB_ptr]
    movzx esi, byte ptr [rax]
    cmp esi, '1'
    je 7f
    mov esi, '0'
7:  lea rdi, [rip + excs]
    call sb_push_byte
    lea rdi, [rip + excs]
    mov esi, 10
    call sb_push_byte
    jmp 9f
.Lll_w:
    lea rdi, [rsp]
    mov rsi, [rsp + 8]
    call field_next
    test rax, rax
    jle 9f
    lea rdi, [rip + g_watches]
    mov rsi, [rip + field + SB_ptr]
    mov rdx, rax
    call sb_push_clean_bp
    lea rdi, [rip + g_watches]
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# bp_set_raw / bp_function_raw: bp_set and bp_function without loading (the loader itself)
bp_set_raw:
    mov dword ptr [rip + loaded], 1
    jmp bp_set
bp_function_raw:
    mov dword ptr [rip + loaded], 1
    jmp bp_function

# bp_save(): the file, written whole
FN bp_save
    PROLOGUE
    mov dword ptr [rip + save_due], 0
    cmp dword ptr [rip + loaded], 0
    je 9f
    lea rdi, [rip + line]
    call sb_clear
    xor r12d, r12d
1:  cmp r12, [rip + g_bps + VEC_len]
    jae 4f
    mov rdi, r12
    call bp_row
    mov rbx, rax
    cmp dword ptr [rbx + BP_kind], 0
    jne 3f
    lea rdi, [rip + line]
    lea rsi, [rip + .Lrec_b]
    call sb_push_cstr
    # inside the project (the one the state belongs to): relative
    mov r13, [rbx + BP_path]
    mov r14, [rip + loaded_for]
    test r14, r14
    jz 2f
    mov rdi, r14
    call strlen
    mov r15, rax
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    mov rdx, r14
    mov rcx, r15
    call str_starts
    test eax, eax
    jz 2f
    cmp byte ptr [r13 + r15], '/'
    jne 2f
    lea r13, [r13 + r15 + 1]
2:  mov rdi, r13
    call put_field
    mov esi, [rbx + BP_line]
    call put_num
    mov esi, [rbx + BP_enabled]
    call put_num
    mov rdi, [rbx + BP_cond]
    call put_field
    mov rdi, [rbx + BP_hit]
    call put_field
    mov rdi, [rbx + BP_log]
    call put_field
    lea rdi, [rip + line]
    mov esi, 10
    call sb_push_byte
    jmp 31f
3:  lea rdi, [rip + line]
    lea rsi, [rip + .Lrec_f]
    call sb_push_cstr
    mov rdi, [rbx + BP_path]
    call put_field
    mov esi, [rbx + BP_enabled]
    call put_num
    mov rdi, [rbx + BP_cond]
    call put_field
    lea rdi, [rip + line]
    mov esi, 10
    call sb_push_byte
31: inc r12
    jmp 1b
4:  # exception filters: "x\t" + their line
    mov r12, [rip + excs + SB_ptr]
    mov r13, [rip + excs + SB_len]
    add r13, r12
5:  cmp r12, r13
    jae 6f
    mov rcx, r12
51: cmp byte ptr [rcx], 10
    je 52f
    inc rcx
    jmp 51b
52: lea r14, [rcx + 1]
    lea rdi, [rip + line]
    lea rsi, [rip + .Lrec_x]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov rsi, r12
    mov rdx, r14
    sub rdx, r12
    call sb_push
    mov r12, r14
    jmp 5b
6:  # watches
    mov r12, [rip + g_watches + SB_ptr]
    mov r13, [rip + g_watches + SB_len]
    add r13, r12
7:  cmp r12, r13
    jae 8f
    mov rcx, r12
71: cmp byte ptr [rcx], 10
    je 72f
    inc rcx
    jmp 71b
72: lea r14, [rcx + 1]
    mov rdi, r12                # Evaluate Expression's is not kept (debugview.s)
    mov rsi, rcx
    sub rsi, r12
    call dview_is_eval
    test eax, eax
    jz 73f
    mov r12, r14
    jmp 7b
73: lea rdi, [rip + line]
    lea rsi, [rip + .Lrec_w]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov rsi, r12
    mov rdx, r14
    sub rdx, r12
    call sb_push
    mov r12, r14
    jmp 7b
8:  call debug_file
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp qword ptr [rip + line + SB_len], 0
    jne 81f
    # nothing to keep: no file
    mov rdi, rbx
    SYS SYS_unlink
    jmp 9f
81: mov rdi, rbx
    mov rsi, [rip + line + SB_ptr]
    mov rdx, [rip + line + SB_len]
    call file_write_all
9:  EPILOGUE

# put_field(cstr or 0): "\t" + the escaped text into line
put_field:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + line]
    mov esi, 9
    call sb_push_byte
    test rbx, rbx
    jz 9f
1:  movzx eax, byte ptr [rbx]
    test eax, eax
    jz 9f
    inc rbx
    cmp eax, 9
    jne 2f
    lea rdi, [rip + line]
    lea rsi, [rip + .Lesc_t]
    call sb_push_cstr
    jmp 1b
2:  cmp eax, 10
    jne 3f
    lea rdi, [rip + line]
    lea rsi, [rip + .Lesc_n]
    call sb_push_cstr
    jmp 1b
3:  cmp eax, 92
    jne 4f
    lea rdi, [rip + line]
    lea rsi, [rip + .Lesc_b]
    call sb_push_cstr
    jmp 1b
4:  lea rdi, [rip + line]
    mov esi, eax
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# put_num(n): "\t" + n into line
put_num:
    push rbx
    mov ebx, esi
    lea rdi, [rip + line]
    mov esi, 9
    call sb_push_byte
    lea rdi, [rip + line]
    mov esi, ebx
    call sb_push_u64
    pop rbx
    ret

.section .rodata
.Lc_setBreakpoints: .asciz "setBreakpoints"
.Lc_setFunctionBreakpoints: .asciz "setFunctionBreakpoints"
.Lk_source: .asciz "source"
.Lk_path: .asciz "path"
.Lk_name: .asciz "name"
.Lk_breakpoints: .asciz "breakpoints"
.Lk_line: .asciz "line"
.Lk_condition: .asciz "condition"
.Lk_hitCondition: .asciz "hitCondition"
.Lk_logMessage: .asciz "logMessage"
.Lk_sourceModified: .asciz "sourceModified"
.Lk_id: .asciz "id"
.Lk_verified: .asciz "verified"
.Lk_message: .asciz "message"
.Lm_nocond: .asciz "this debugger does not support conditions"
.Lm_nolog: .asciz "this debugger does not support log messages"
.Ld_function: .asciz "function "
.Ld_enabled: .asciz " enabled="
.Ld_cond: .asciz " cond="
.Ld_hits: .asciz " hits="
.Ld_log: .asciz " log="
.Ld_verified: .asciz " verified="
.Ld_line: .asciz " line="
.Ld_msg: .asciz " msg="
.Lver_chars: .ascii "-01x"
.Lsuffix: .asciz ".debug"
.Lrec_b: .asciz "b"
.Lrec_f: .asciz "f"
.Lrec_x: .asciz "x\t"
.Lrec_w: .asciz "w\t"
.Lesc_t: .asciz "\\t"
.Lesc_n: .asciz "\\n"
.Lesc_b: .asciz "\\\\"
