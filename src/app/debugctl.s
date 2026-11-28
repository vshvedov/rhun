# debugger commands for the headless driver (--script, --control): control.s hands over the commands
# it does not know. debug-start NAME | debug-run NAME | debug-stop | debug-pause | debug-continue |
# debug-step over|into|out | debug-frame N | debug-thread ID | debug-session ID | debug-connect-answer ID 0|1 | debug-set PATH VALUE | debug-expand PATH | debug-collapse PATH | debug-watch add|remove EXPR |
# debug-eval EXPR | debug-forget | bp PATH LINE [cond=C] [hits=H] [log=L] | bp-toggle PATH LINE |
# bp-enable PATH LINE 0|1 | bp-function NAME [cond=C] | bp-clear | exc-filter TYPE FILTER 0|1 |
# wait-debug STATE [MS] | wait-console TEXT | print-debug | print-stack | print-vars | print-watch |
# print-console [N] | print-bps | print-dap-log | print-configs | print-inline-values | print-bp-dialog
.include "rhun.inc"

.bss
.p2align 3
outp: .quad 0                   # the caller's output SB
argb: .zero SB_SIZE
argb2: .zero SB_SIZE
optc: .zero SB_SIZE
opth: .zero SB_SIZE
optl: .zero SB_SIZE

.text

# DCTL fn: an entry for control.s's ctl_tables, fn(out, rest, len) -> rax, around a handler that
#   reads the rest from rbx/r12 and writes to outp
.macro DCTL fn
e_\fn:
    PROLOGUE
    mov [rip + outp], rdi
    mov rbx, rsi
    mov r12, rdx
    call \fn
    EPILOGUE
.endm

# next_arg: rbx/r12 (the rest) -> rax word, rdx its length
next_arg:
    mov rdi, rbx
    mov rsi, r12
    call next_word
    add rbx, rcx
    sub r12, rcx
    ret

# rest_trim -> rax, rdx: what is left of the line, trimmed
rest_trim:
    mov rdi, rbx
    mov rsi, r12
    jmp trim

# out_byte(b), out_cstr(s), out_sb(sb)
out_cstr:
    mov rsi, rdi
    mov rdi, [rip + outp]
    jmp sb_push_cstr

# frame(): the event loop's work for a moment, as control.s's waits do
frame:
    mov edi, 20
    call loop_poll
    call app_tick
.ifndef WINDOWS
    cmp dword ptr [rip + g_headless], 0
    je 1f
.endif
    cmp dword ptr [rip + g_dirty], 0
    je 1f
    PCALL P_draw
1:  ret

# debug-start NAME / debug-run NAME
c_start:
    xor edx, edx
    jmp start_common
c_run:
    mov edx, 1
start_common:
    push rdx
    push rdx
    call rest_trim
    pop rcx
    pop rcx
    mov rdi, rax
    mov rsi, rdx
    mov edx, ecx
    call dap_start
    xor eax, eax
    ret

c_stop:
    call dap_stop
    xor eax, eax
    ret

c_pause:
    call dap_pause
    xor eax, eax
    ret

c_continue:
    xor edi, edi
    call dap_resume
    xor eax, eax
    ret

# debug-set PATH VALUE: setVariable on the focused session's variable at PATH (a Variables id)
c_set:
    push r13
    push r14
    push r15
    sub rsp, 16
    call next_arg
    mov r13, rax                # the path
    mov r14, rdx
    call rest_trim
    mov r15, rax                # the value
    mov [rsp], rdx
    call dap_focused
    test rax, rax
    jz 1f
    mov [rsp + 8], rax
    mov rdi, rax
    mov rsi, r13
    mov rdx, r14
    call dap_node_by_path
    test eax, eax
    js 1f
    mov rdi, [rsp + 8]
    mov esi, eax
    mov rdx, r15
    mov rcx, [rsp]
    call dap_set_variable
1:  add rsp, 16
    pop r15
    pop r14
    pop r13
    xor eax, eax
    ret

# print-vars-changed: the variables whose value changed since the last stop
c_print_changed:
    sub rsp, 8
    mov rdi, [rip + outp]
    call dap_changed_dump
    add rsp, 8
    xor eax, eax
    ret

# debug-frame N: the focused session's frame N (as a click on its Call Stack row)
c_frame:
    push rbx
    push rbx
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test edx, edx
    jz 1f
    mov rbx, rax
    call dap_focused
    test rax, rax
    jz 1f
    mov rdi, rax
    mov esi, ebx
    call dap_focus_frame
1:  xor eax, eax
    pop rbx
    pop rbx
    ret

# debug-thread ID: the focused session's thread ID (as a click on its Call Stack row)
c_thread:
    push rbx
    push rbx
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test edx, edx
    jz 1f
    mov rbx, rax
    call dap_focused
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, rbx
    call dap_focus_thread
1:  xor eax, eax
    pop rbx
    pop rbx
    ret

# debug-session ID: session ID is the focused one (as a click on its Call Stack row)
c_session:
    push rbx
    push rbx
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test edx, edx
    jz 1f
    mov edi, eax
    call dap_slot_of_id
    test rax, rax
    jz 1f
    mov rdi, rax
    call dap_focus_ds
1:  xor eax, eax
    pop rbx
    pop rbx
    ret

# debug-connect-answer ID 0|1: once the focused session (a remote window) has a connection attempt
#   the host has not answered yet (5 s at most), an answer to it (0 connected, 1 refused) as if it
#   belonged to session ID (tests: a late answer about a session that ended, its slot made anew)
c_conn_answer:
    sub rsp, 8
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test edx, edx
    jz 1f
    mov r13d, eax
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test edx, edx
    jz 1f
    mov r14d, eax
    mov ebx, 250
2:  call dap_focused
    test rax, rax
    jz 1f
    mov r15, rax
    cmp dword ptr [r15 + DS_rconn], 1
    je 3f
    dec ebx
    jz 1f
    call frame
    jmp 2b
3:  mov rax, r15
    mov rdi, rax
    call dap_slot_index
    mov edx, [r15 + DS_rtry]
    and edx, 0xffffff
    shl rdx, 8
    or rax, rdx
    mov edx, r13d
    shl rdx, 32
    or rax, rdx
    mov rdi, rax
    mov esi, r14d
    call dap_rconn_answer
1:  xor eax, eax
    add rsp, 8
    ret

# debug-step over|into|out
c_step:
    call next_arg
    mov r13, rax
    mov r14, rdx
    mov edi, 1
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Ls_into]
    call str_eq_cstr
    mov edi, 2
    test eax, eax
    jnz 1f
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Ls_out]
    call str_eq_cstr
    mov edi, 3
    test eax, eax
    jnz 1f
    mov edi, 1
1:  call dap_resume
    xor eax, eax
    ret

c_forget:
    call dap_forget_approvals
    xor eax, eax
    ret

# debug-expand PATH / debug-collapse PATH
c_expand:
    mov r15d, 1
    jmp expand_common
c_collapse:
    xor r15d, r15d
expand_common:
    call dap_focused
    test rax, rax
    jz 9f
    mov r13, rax
    call rest_trim
    mov rdi, r13
    mov rsi, rax
    call dap_find_node
    test eax, eax
    js 9f
    mov rdi, r13
    mov esi, eax
    test r15d, r15d
    jz 1f
    call vn_expand
    jmp 9f
1:  call vn_collapse
9:  mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    ret

# debug-watch add|remove EXPR
c_watch:
    call next_arg
    mov r13, rax
    mov r14, rdx
    call rest_trim
    mov r15, rax
    mov rbx, rdx
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Ls_remove]
    call str_eq_cstr
    mov rdi, r15
    mov rsi, rbx
    test eax, eax
    jnz 1f
    call dap_watch_add
    jmp 2f
1:  call dap_watch_remove
2:  call bp_save
    xor eax, eax
    ret

# debug-eval EXPR
c_eval:
    call rest_trim
    mov rdi, rax
    mov rsi, rdx
    call dap_eval
    xor eax, eax
    ret

# path_line() -> argb holds PATH (NUL-terminated), eax LINE; from the rest
path_line:
    push r13
    call next_arg
    lea rdi, [rip + argb]
    mov rsi, rax
    call sb_setz
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    pop r13
    ret

# sb_setz(sb, ptr, len): exactly these bytes, NUL-terminated
sb_setz:
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
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rbx + SB_len]
    pop r13
    pop r12
    pop rbx
    ret

# opts(): cond=, hits=, log= from the rest into optc, opth, optl (empty when absent); a value runs
#   to the next of these keys
opts:
    PROLOGUE
    lea rdi, [rip + optc]
    xor esi, esi
    xor edx, edx
    call sb_setz
    lea rdi, [rip + opth]
    xor esi, esi
    xor edx, edx
    call sb_setz
    lea rdi, [rip + optl]
    xor esi, esi
    xor edx, edx
    call sb_setz
    call rest_trim
    mov r13, rax
    lea r14, [rax + rdx]        # end
1:  cmp r13, r14
    jae 9f
    # which key starts here
    lea r15, [rip + opt_keys]
2:  mov rsi, [r15]
    test rsi, rsi
    jz 8f
    mov rdi, rsi
    call strlen
    mov rcx, rax
    mov rdx, r14
    sub rdx, r13
    cmp rdx, rcx
    jb 3f
    push rcx
    push rcx
    mov rdi, r13
    mov rsi, rcx
    mov rdx, [r15]
    call str_eq_n_cstr
    pop rcx
    pop rcx
    test eax, eax
    jnz 4f
3:  add r15, 16
    jmp 2b
4:  add r13, rcx                # the value: up to the next key at a word start
    mov rbx, r13
5:  cmp rbx, r14
    jae 6f
    cmp byte ptr [rbx], ' '
    jne 51f
    lea rdi, [rbx + 1]
    call key_at
    test eax, eax
    jnz 6f
51: inc rbx
    jmp 5b
6:  mov rdi, r13
    mov rsi, rbx
    sub rsi, r13
    call trim
    mov rdi, [r15 + 8]
    mov rsi, rax
    call sb_setz
    mov r13, rbx
7:  cmp r13, r14
    jae 9f
    cmp byte ptr [r13], ' '
    jne 1b
    inc r13
    jmp 7b
8:  inc r13
    jmp 1b
9:  EPILOGUE

# key_at(ptr) -> eax 1 when one of the option keys starts there (r14 the end)
key_at:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    lea r12, [rip + opt_keys]
1:  mov rdi, [r12]
    test rdi, rdi
    jz 8f
    call strlen
    mov rdx, r14
    sub rdx, rbx
    cmp rdx, rax
    jb 2f
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [r12]
    call str_eq_n_cstr
    test eax, eax
    jnz 9f
2:  add r12, 16
    jmp 1b
8:  xor eax, eax
9:  add rsp, 8
    pop r12
    pop rbx
    ret

# str_eq_n_cstr(ptr, n, cstr) -> eax 1 when the n bytes are the cstr
str_eq_n_cstr:
    jmp str_eq_cstr

# bp PATH LINE [cond=C] [hits=H] [log=L]
c_bp:
    PROLOGUE
    call path_line
    mov r15d, eax
    call opts
    lea rdi, [rip + argb]
    call sb_ptr
    mov rdi, rax
    mov esi, r15d
    mov rdx, [rip + optc + SB_ptr]
    mov rcx, [rip + opth + SB_ptr]
    mov r8, [rip + optl + SB_ptr]
    call bp_set
    xor eax, eax
    EPILOGUE

# sb_ptr(sb) -> its bytes
sb_ptr:
    mov rax, [rdi + SB_ptr]
    ret

# bp-toggle PATH LINE
c_bp_toggle:
    PROLOGUE
    call path_line
    mov esi, eax
    mov rdi, [rip + argb + SB_ptr]
    call bp_toggle
    xor eax, eax
    EPILOGUE

# bp-enable PATH LINE 0|1
c_bp_enable:
    PROLOGUE
    call path_line
    mov esi, eax
    mov rdi, [rip + argb + SB_ptr]
    call bp_find
    test eax, eax
    js 9f
    mov r15d, eax
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov edi, r15d
    mov esi, eax
    call bp_enable
9:  xor eax, eax
    EPILOGUE

# bp-function NAME [cond=C]
c_bp_function:
    PROLOGUE
    call next_arg
    lea rdi, [rip + argb]
    mov rsi, rax
    call sb_setz
    call opts
    mov rdi, [rip + argb + SB_ptr]
    mov rsi, [rip + optc + SB_ptr]
    call bp_function
    xor eax, eax
    EPILOGUE

c_bp_clear:
    call bp_clear_all
    xor eax, eax
    ret

# exc-filter TYPE FILTER 0|1
c_exc:
    PROLOGUE
    call next_arg
    lea rdi, [rip + argb]
    mov rsi, rax
    call sb_setz
    call next_arg
    lea rdi, [rip + argb2]
    mov rsi, rax
    call sb_setz
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov ecx, eax
    mov rdi, [rip + argb + SB_ptr]
    mov rsi, [rip + argb2 + SB_ptr]
    mov rdx, [rip + argb2 + SB_len]
    call bp_exc_set
    xor eax, eax
    EPILOGUE

# wait-debug STATE [MS]: until the focused session is in that state (20 s by default); prints
#   debug=STATE with the state it is in
c_wait_debug:
    PROLOGUE
    call next_arg
    lea rdi, [rip + argb]
    mov rsi, rax
    call sb_setz
    call next_arg
    mov r13d, 20000
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov r13, rax
1:  call app_tick
    call time_ms
    lea r14, [rax + r13]
2:  call dap_focused
    lea r15, [rip + .Ls_none]
    test rax, rax
    jz 5f                       # no session: nothing will change
    mov edi, [rax + DS_state]
    call dap_state_name
    mov r15, rax
    mov rdi, rax
    mov rsi, [rip + argb + SB_ptr]
    call strcmp_eq
    test eax, eax
    jnz 4f
    call dap_focused            # an ended session will not change
    cmp dword ptr [rax + DS_state], DSS_ENDED
    je 5f
    jmp 3f
4:
    # paused: once what the stop asked for has come (nothing in flight)
    call dap_focused
    cmp dword ptr [rax + DS_state], DSS_PAUSED
    jne 5f
    cmp dword ptr [rax + DS_npend], 0
    je 5f
3:  call time_ms
    cmp rax, r14
    jae 5f
    call frame
    jmp 2b
5:  lea rdi, [rip + .Ls_debug_eq]
    call out_cstr
    mov rdi, r15
    call out_cstr
    mov rdi, [rip + outp]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

# wait-console TEXT: until a console line holds TEXT (20 s at most)
c_wait_console:
    PROLOGUE
    call rest_trim
    lea rdi, [rip + argb]
    mov rsi, rax
    call sb_setz
    call app_tick
    call time_ms
    lea r14, [rax + 20000]
1:  mov rdi, [rip + argb + SB_ptr]
    mov rsi, [rip + argb + SB_len]
    call dcon_find
    test eax, eax
    jnz 9f
    call time_ms
    cmp rax, r14
    jae 9f
    call frame
    jmp 1b
9:  xor eax, eax
    EPILOGUE

c_print_debug:
    mov rdi, [rip + outp]
    call dap_dump
    xor eax, eax
    ret

c_print_stack:
    mov rdi, [rip + outp]
    call dap_stack_dump
    xor eax, eax
    ret

c_print_vars:
    mov rdi, [rip + outp]
    xor esi, esi
    call dap_vars_dump
    xor eax, eax
    ret

c_print_watch:
    mov rdi, [rip + outp]
    mov esi, 1
    call dap_vars_dump
    xor eax, eax
    ret

# print-console [N]
c_print_console:
    call next_arg
    xor esi, esi
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov rsi, rax
1:  mov rdi, [rip + outp]
    call dcon_dump
    xor eax, eax
    ret

c_print_bps:
    mov rdi, [rip + outp]
    call bp_dump
    xor eax, eax
    ret

c_print_dap_log:
    mov rdi, [rip + outp]
    call dap_log_dump
    xor eax, eax
    ret

# print-debug-tree variables|watch|stack|breakpoints: that section's tree rows (tree_dump), filled now
c_print_debug_tree:
    PROLOGUE
    call next_arg
    mov r13, rax
    mov r14, rdx
    call dview_sync_all
    xor r15d, r15d
1:  cmp r15d, 4
    jae 9f
    lea rax, [rip + tree_names]
    mov rdx, [rax + r15*8]
    mov rdi, r13
    mov rsi, r14
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r15d
    jmp 1b
2:  mov edi, r15d
    call dview_tree
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, [rip + outp]
    call tree_dump
9:  xor eax, eax
    EPILOGUE

# print-debug-toolbar: the title bar's debug buttons as last drawn
c_print_debug_toolbar:
    mov rdi, [rip + outp]
    call dview_toolbar_dump
    xor eax, eax
    ret

# print-value-card: the debugger's hover card as last drawn (debuggutter.s)
c_print_hover_card:
    mov rdi, [rip + outp]
    call dg_hover_card_dump
    xor eax, eax
    ret

# print-bp-dialog: the Breakpoints dialog's state (bpdialog.s)
c_print_bp_dialog:
    mov rdi, [rip + outp]
    call bpdlg_dump
    xor eax, eax
    ret

# print-inline-values: "inline LINE TEXT" for each line of the paused frame's file with inline values
#   (1-based lines), from the first line to the paused one
c_print_inline_values:
    PROLOGUE
    mov r12, [rip + g_dg_doc]
    test r12, r12
    jz 9f
    xor ebx, ebx
1:  cmp rbx, [rip + g_dg_line]
    jg 9f
    mov rdi, r12
    mov rsi, rbx
    call vt_line
    mov r13, rax
    mov r14, rdx
    xor r15d, r15d
2:  cmp r15, r14
    jae 4f
    imul rcx, r15, VI_SIZE
    add rcx, r13
    cmp byte ptr [rcx + VI_kind], VK_DEBUG
    jne 3f
    push rcx
    push rcx
    lea rdi, [rip + .Ls_inline]
    call out_cstr
    mov rdi, [rip + outp]
    lea rsi, [rbx + 1]
    call sb_push_u64
    mov rdi, [rip + outp]
    mov esi, ' '
    call sb_push_byte
    pop rcx
    pop rcx
    mov rdi, [rip + outp]
    mov rsi, [rcx + VI_text]
    mov edx, [rcx + VI_len]
    call sb_push
    mov rdi, [rip + outp]
    mov esi, 10
    call sb_push_byte
3:  inc r15
    jmp 2b
4:  inc rbx
    jmp 1b
9:  xor eax, eax
    EPILOGUE

# print-debug-hover: the debugger's hover for the position the pointer rests on, or none
c_print_debug_hover:
    call dg_hover_text
    lea rdi, [rip + .Ls_none]
    test rax, rax
    jz 1f
    mov rdi, rax
1:  call out_cstr
    mov rdi, [rip + outp]
    mov esi, 10
    jmp sb_push_byte

# print-configs: launch.ini's configuration names, "config=NAME" per line
c_print_configs:
    PROLOGUE
    lea rdi, [rip + argb]
    call sb_clear
    lea rdi, [rip + argb]
    call dcfg_names
    mov r13, [rip + argb + SB_ptr]
    mov r14, [rip + argb + SB_len]
    add r14, r13
1:  cmp r13, r14
    jae 9f
    mov rcx, r13
2:  cmp byte ptr [rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  mov r15, rcx
    lea rdi, [rip + .Ls_config_eq]
    call out_cstr
    mov rdi, [rip + outp]
    mov rsi, r13
    mov rdx, r15
    sub rdx, r13
    inc rdx
    call sb_push
    lea r13, [r15 + 1]
    jmp 1b
9:  mov rdi, [rip + outp]     # the status bar's configuration label
    call dview_status_config_dump
    xor eax, eax
    EPILOGUE

.text
DCTL c_start
DCTL c_run
DCTL c_stop
DCTL c_pause
DCTL c_continue
DCTL c_frame
DCTL c_thread
DCTL c_session
DCTL c_conn_answer
DCTL c_set
DCTL c_print_changed
DCTL c_step
DCTL c_expand
DCTL c_collapse
DCTL c_watch
DCTL c_eval
DCTL c_forget
DCTL c_bp
DCTL c_bp_toggle
DCTL c_bp_enable
DCTL c_bp_function
DCTL c_bp_clear
DCTL c_exc
DCTL c_wait_debug
DCTL c_wait_console
DCTL c_print_debug
DCTL c_print_stack
DCTL c_print_vars
DCTL c_print_watch
DCTL c_print_console
DCTL c_print_bps
DCTL c_print_dap_log
DCTL c_print_configs
DCTL c_print_debug_tree
DCTL c_print_debug_toolbar
DCTL c_print_debug_hover
DCTL c_print_inline_values
DCTL c_print_bp_dialog
DCTL c_print_hover_card

.section .rodata
.Ls_into: .asciz "into"
.Ls_out: .asciz "out"
.Ls_remove: .asciz "remove"
.Ls_none: .asciz "none"
.Ls_debug_eq: .asciz "debug="
.Ls_config_eq: .asciz "config="
.Lk_cond: .asciz "cond="
.Lk_hits: .asciz "hits="
.Lk_log: .asciz "log="
.Lc_debug_start: .asciz "debug-start"
.Lc_debug_run: .asciz "debug-run"
.Lc_debug_stop: .asciz "debug-stop"
.Lc_debug_pause: .asciz "debug-pause"
.Lc_debug_continue: .asciz "debug-continue"
.Lc_debug_frame: .asciz "debug-frame"
.Lc_debug_thread: .asciz "debug-thread"
.Lc_debug_session: .asciz "debug-session"
.Lc_debug_conn_answer: .asciz "debug-connect-answer"
.Lc_debug_set: .asciz "debug-set"
.Lc_print_vars_changed: .asciz "print-vars-changed"
.Lc_debug_step: .asciz "debug-step"
.Lc_debug_expand: .asciz "debug-expand"
.Lc_debug_collapse: .asciz "debug-collapse"
.Lc_debug_watch: .asciz "debug-watch"
.Lc_debug_eval: .asciz "debug-eval"
.Lc_debug_forget: .asciz "debug-forget"
.Lc_bp: .asciz "bp"
.Lc_bp_toggle: .asciz "bp-toggle"
.Lc_bp_enable: .asciz "bp-enable"
.Lc_bp_function: .asciz "bp-function"
.Lc_bp_clear: .asciz "bp-clear"
.Lc_exc_filter: .asciz "exc-filter"
.Lc_wait_debug: .asciz "wait-debug"
.Lc_wait_console: .asciz "wait-console"
.Lc_print_debug: .asciz "print-debug"
.Lc_print_stack: .asciz "print-stack"
.Lc_print_vars: .asciz "print-vars"
.Lc_print_watch: .asciz "print-watch"
.Lc_print_console: .asciz "print-console"
.Lc_print_bps: .asciz "print-bps"
.Lc_print_dap_log: .asciz "print-dap-log"
.Lc_print_configs: .asciz "print-configs"
.Lc_print_debug_tree: .asciz "print-debug-tree"
.Lc_print_debug_toolbar: .asciz "print-debug-toolbar"
.Lc_print_debug_hover: .asciz "print-debug-hover"
.Lc_print_inline_values: .asciz "print-inline-values"
.Lc_print_bp_dialog: .asciz "print-bp-dialog"
.Lc_print_hover_card: .asciz "print-value-card"
.Ls_inline: .asciz "inline "
.Lt_variables: .asciz "variables"
.Lt_watch: .asciz "watch"
.Lt_stack: .asciz "stack"
.Lt_breakpoints: .asciz "breakpoints"
.p2align 3
tree_names:
    .quad .Lt_variables, .Lt_watch, .Lt_stack, .Lt_breakpoints
opt_keys:
    .quad .Lk_cond, optc, .Lk_hits, opth, .Lk_log, optl, 0, 0
.globl debug_ctl
debug_ctl:
    .quad .Lc_debug_start, e_c_start, .Lc_debug_run, e_c_run, .Lc_debug_stop, e_c_stop
    .quad .Lc_debug_pause, e_c_pause, .Lc_debug_continue, e_c_continue, .Lc_debug_step, e_c_step
    .quad .Lc_debug_expand, e_c_expand, .Lc_debug_collapse, e_c_collapse, .Lc_debug_watch, e_c_watch
    .quad .Lc_debug_eval, e_c_eval, .Lc_debug_forget, e_c_forget, .Lc_debug_frame, e_c_frame
    .quad .Lc_debug_set, e_c_set, .Lc_print_vars_changed, e_c_print_changed
    .quad .Lc_debug_thread, e_c_thread, .Lc_debug_session, e_c_session
    .quad .Lc_debug_conn_answer, e_c_conn_answer
    .quad .Lc_bp, e_c_bp, .Lc_bp_toggle, e_c_bp_toggle, .Lc_bp_enable, e_c_bp_enable
    .quad .Lc_bp_function, e_c_bp_function, .Lc_bp_clear, e_c_bp_clear, .Lc_exc_filter, e_c_exc
    .quad .Lc_wait_debug, e_c_wait_debug, .Lc_wait_console, e_c_wait_console
    .quad .Lc_print_debug, e_c_print_debug, .Lc_print_stack, e_c_print_stack
    .quad .Lc_print_vars, e_c_print_vars, .Lc_print_watch, e_c_print_watch
    .quad .Lc_print_console, e_c_print_console, .Lc_print_bps, e_c_print_bps
    .quad .Lc_print_dap_log, e_c_print_dap_log, .Lc_print_configs, e_c_print_configs
    .quad .Lc_print_debug_tree, e_c_print_debug_tree, .Lc_print_debug_toolbar, e_c_print_debug_toolbar
    .quad .Lc_print_debug_hover, e_c_print_debug_hover, .Lc_print_inline_values, e_c_print_inline_values
    .quad .Lc_print_bp_dialog, e_c_print_bp_dialog, .Lc_print_hover_card, e_c_print_hover_card
    .quad 0, 0
