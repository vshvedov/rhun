# headless commands for the AI features (wider-parity D), reached from control.s for names its
# table does not have: they drive the agents panel's extension sessions, the Review tab and tools,
# and print their state for tests
.include "rhun.inc"

.bss
.p2align 3
args_p: .quad 0
args_n: .quad 0
outsb: .quad 0

.text

# ai_set(out, rest, len): the arguments the command's handler reads (every handler calls it first)
ai_set:
    mov [rip + outsb], rdi
    mov [rip + args_p], rsi
    mov [rip + args_n], rdx
    ret

# FN ai_arg() -> rax ptr, rdx len: the next space-separated argument
FN ai_arg
    mov rdi, [rip + args_p]
    mov rsi, [rip + args_n]
    push rbx
    call next_word
    add [rip + args_p], rcx
    sub [rip + args_n], rcx
    pop rbx
    ret

# FN ai_arg_rest() -> rax ptr, rdx len: what is left of the line
FN ai_arg_rest
    mov rax, [rip + args_p]
    mov rdx, [rip + args_n]
    ret

# FN ai_out() -> rax the output buffer (SB*)
FN ai_out
    mov rax, [rip + outsb]
    ret

# agents-source OWNER/NAME: its switch in Settings > Agents, flipped
c_agents_source:
    PROLOGUE
    call ai_set
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call agentext_toggle_named
    xor eax, eax
    EPILOGUE

# print-review: the proposals, their files and hunks
c_print_review:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call review_dump
    xor eax, eax
    EPILOGUE

# review accept|reject FILE|all [HUNK]: decide in the active Review tab (else the newest one); FILE and
#   HUNK count from 1
c_review:
    PROLOGUE 16
    call ai_set
    call review_current
    test rax, rax
    jz 9f
    mov rbx, rax
    call ai_arg
    mov r12d, 1
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lw_accept]
    push rdi
    push rsi
    call str_eq_cstr
    pop rsi
    pop rdi
    test eax, eax
    jnz 1f
    xor r12d, r12d
    lea rdx, [rip + .Lw_reject]
    call str_eq_cstr
    test eax, eax
    jz 9f
1:  call ai_arg
    mov r13, -1                 # all
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lw_all]
    push rdi
    push rsi
    call str_eq_cstr
    pop rsi
    pop rdi
    test eax, eax
    jnz 2f
    call parse_u64
    lea r13, [rax - 1]
2:  mov r14, -1
    call ai_arg
    test rdx, rdx
    jz 3f
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    lea r14, [rax - 1]
3:  mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    mov ecx, r12d
    call review_decide
9:  xor eax, eax
    EPILOGUE

# agent-new OWNER/NAME | KIND: the agents panel writes a new session of that extension (D4), or a new
#   conversation of a built-in driver (a name without "/": claude); error when that driver is off
c_agent_new:
    PROLOGUE
    call ai_set
    call ai_arg
    mov rbx, rax
    mov r12, rdx
    xor ecx, ecx
1:  cmp rcx, r12
    jae 3f
    cmp byte ptr [rbx + rcx], '/'
    je 2f
    inc rcx
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r12
    call agentext_named
    test rax, rax
    jz 9f
    mov rbx, rax
    call cmd_focus_agents
    mov rdi, rbx
    call agentext_new
9:  xor eax, eax
    EPILOGUE
3:  mov rdi, rbx
    mov rsi, r12
    call agent_kind_named
    test eax, eax
    jz 8f
    mov ebx, eax
    mov edi, eax
    call agent_drv_for_kind
    test rax, rax
    jz 8f
    call cmd_focus_agents
    mov edi, ebx
    call agentext_new_kind
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# has_target() -> eax 1 when the box has someone to go to: a new session being written, or an open
#   session with a driver
has_target:
    PROLOGUE
    call agentext_new_active
    mov ebx, 1
    test rax, rax
    jnz 9f
    call agents_open_driven
    xor ebx, ebx
    test rax, rax
    setnz bl
9:  mov eax, ebx
    EPILOGUE

# agent-prompt TEXT: TEXT in the prompt box, sent as Enter sends it; error when no session takes it
c_agent_prompt:
    PROLOGUE
    call ai_set
    call ai_arg_rest
    mov rbx, rax
    mov r12, rdx
    call agentext_field
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call tf_set
    call has_target
    test eax, eax
    jz 8f
    call agentext_send
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# agent-type TEXT: TEXT typed into the prompt box, not sent (the session's program starts)
c_agent_type:
    PROLOGUE
    call ai_set
    call has_target
    test eax, eax
    jz 8f
    call ai_arg_rest
    mov rdi, rax
    mov rsi, rdx
    call agentext_paste
    call agentext_typed
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# agent-stop: Stop in the open session
c_agent_stop:
    PROLOGUE
    call ai_set
    call agents_open_driven
    test rax, rax
    jz 9f
    mov rdi, rax
    call agent_stop
9:  xor eax, eax
    EPILOGUE

# agent-release: the open session's program ends politely, as the idle stop ends it
c_agent_release:
    PROLOGUE
    call ai_set
    call agents_open_driven
    test rax, rax
    jz 9f
    mov rdi, rax
    call agent_release
9:  xor eax, eax
    EPILOGUE

# agent-card N: option N (from 1) of the open session's card
c_agent_card:
    PROLOGUE
    call ai_set
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    lea rbx, [rax - 1]
    call agents_open_driven
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rbx
    call agentext_pick
9:  xor eax, eax
    EPILOGUE

# print-agent-input: the prompt box, the new session, the prompt in flight, the box, the open card
c_print_agent_input:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call agentext_input_dump
    xor eax, eax
    EPILOGUE

# print-agent-live: the open session's live record (agent_live_dump)
c_print_agent_live:
    PROLOGUE
    call ai_set
    call agents_open_driven
    mov rbx, rax
    call ai_out
    mov rdi, rax
    mov rsi, rbx
    call agent_live_dump
    xor eax, eax
    EPILOGUE

# wait-agent STATE[|STATE...] [MS]: until the open session's live state is one of them (off starting
#   ready working waiting held failed; default 10000 ms); an error line with the state on timeout
c_wait_agent:
    PROLOGUE
    call ai_set
    call ai_arg
    mov r12, rax                # the states, then the mask
    mov r13, rdx
    xor r14d, r14d
1:  test r13, r13
    jz 4f
    xor ecx, ecx                # one word up to '|'
2:  cmp rcx, r13
    jae 3f
    cmp byte ptr [r12 + rcx], '|'
    je 3f
    inc rcx
    jmp 2b
3:  push rcx
    push rcx
    mov rdi, r12
    mov rsi, rcx
    call state_named
    pop rcx
    pop rcx
    test eax, eax
    js 8f
    bts r14, rax
    lea r12, [r12 + rcx]
    sub r13, rcx
    test r13, r13
    jz 4f
    inc r12                     # the '|'
    dec r13
    jmp 1b
4:  test r14d, r14d
    jz 8f
    mov r15d, 10000
    call ai_arg
    test rdx, rdx
    jz 5f
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov r15, rax
5:  call time_ms
    lea rbx, [rax + r15]
6:  call agents_open_driven
    mov rdi, rax
    call agent_live_state
    bt r14, rax
    jc 7f
    call time_ms
    cmp rax, rbx
    jae 81f
    mov edi, 20
    call loop_poll
    call app_tick
    jmp 6b
7:  xor eax, eax
    EPILOGUE
81: call ai_out                 # timed out: the state it is in
    mov rdi, rax
    lea rsi, [rip + .Lw_timeout]
    call sb_push_cstr
    call agents_open_driven
    mov rdi, rax
    call agent_live_state
    lea rcx, [rip + live_states]
    mov rsi, [rcx + rax*8]
    call ai_out
    mov rdi, rax
    call sb_push_cstr
    call ai_out
    mov rdi, rax
    mov esi, 10
    call sb_push_byte
8:  mov rax, -1
    EPILOGUE

# state_named(ptr, len) -> eax the ALS_* that word names, or -1
state_named:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp ebx, ALS_FAILED
    ja 8f
    lea rax, [rip + live_states]
    mov rdx, [rax + rbx*8]
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc ebx
    jmp 1b
2:  mov eax, ebx
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# agent-timing [idle=MS] [term=MS] [kill=MS] [eof=MS] [hold=MS] [guard=N]: shorter times for tests
c_agent_timing:
    PROLOGUE
    call ai_set
1:  call ai_arg
    test rdx, rdx
    jz 9f
    mov rbx, rax
    mov r12, rdx
    xor ecx, ecx                # NAME=VALUE
2:  cmp rcx, r12
    jae 8f
    cmp byte ptr [rbx + rcx], '='
    je 3f
    inc rcx
    jmp 2b
3:  mov r13, rcx
    lea rdi, [rbx + rcx + 1]
    mov rsi, r12
    sub rsi, rcx
    dec rsi
    call parse_u64
    mov r14, rax
    lea r15, [rip + timings]
4:  mov rdx, [r15]
    test rdx, rdx
    jz 8f
    mov rdi, rbx
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 5f
    add r15, 16
    jmp 4b
5:  mov rax, [r15 + 8]
    mov [rax], r14d
    jmp 1b
8:  mov rax, -1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# print-tools: the tools a tools request lists, then the calls in flight
c_print_tools:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call tools_dump
    xor eax, eax
    EPILOGUE

# tool-confirm once|session|deny: the answer to the tool dialog
c_tool_confirm:
    PROLOGUE
    call ai_set
    call tools_asking
    test rax, rax
    jz 9f
    call ai_arg
    mov rbx, rax
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lw_once]
    call str_eq_cstr
    test eax, eax
    jz 1f
    mov edi, 2                  # Allow once, the dialog's own button
    call app_dialog_button
    jmp 9f
1:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lw_session]
    call str_eq_cstr
    test eax, eax
    jz 2f
    mov edi, 1                  # Allow for this session, between
    call app_dialog_button
    jmp 9f
2:  xor edi, edi
    call app_dialog_button
9:  xor eax, eax
    EPILOGUE

# print-agent-row N: row N (from 1) of the open conversation as it is drawn (a reply's Markdown blocks)
c_print_agent_row:
    PROLOGUE
    call ai_set
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov rbx, rax
    call ai_out
    mov rdi, rax
    mov rsi, rbx
    call agents_row_dump
    xor eax, eax
    EPILOGUE

# agent-test-append TEXT: TEXT ("\n" a line end) added in place to the open conversation's last reply,
#   as a streaming reply grows (tests)
c_agent_test_append:
    PROLOGUE
    call ai_set
    call ai_arg_rest
    mov rdi, rax
    mov rsi, rdx
    call agents_test_append
    xor eax, eax
    EPILOGUE

.section .rodata
.Lc_print_agent_row: .asciz "print-agent-row"
.Lc_agent_test_append: .asciz "agent-test-append"
.Lc_agents_source: .asciz "agents-source"
.Lc_agent_new: .asciz "agent-new"
.Lc_agent_prompt: .asciz "agent-prompt"
.Lc_agent_stop: .asciz "agent-stop"
.Lc_agent_card: .asciz "agent-card"
.Lc_print_agent_input: .asciz "print-agent-input"
.Lc_agent_type: .asciz "agent-type"
.Lc_agent_release: .asciz "agent-release"
.Lc_wait_agent: .asciz "wait-agent"
.Lc_print_agent_live: .asciz "print-agent-live"
.Lc_agent_timing: .asciz "agent-timing"
.Lw_timeout: .asciz "timeout state="
.Ls_off: .asciz "off"
.Ls_starting: .asciz "starting"
.Ls_ready: .asciz "ready"
.Ls_working: .asciz "working"
.Ls_waiting: .asciz "waiting"
.Ls_held: .asciz "held"
.Ls_failed: .asciz "failed"
.Lt_idle: .asciz "idle"
.Lt_term: .asciz "term"
.Lt_kill: .asciz "kill"
.Lt_eof: .asciz "eof"
.Lt_hold: .asciz "hold"
.Lt_guard: .asciz "guard"
.Lc_print_tools: .asciz "print-tools"
.Lc_tool_confirm: .asciz "tool-confirm"
.Lw_once: .asciz "once"
.Lw_session: .asciz "session"
.Lc_print_review: .asciz "print-review"
.Lc_review: .asciz "review"
.Lw_accept: .asciz "accept"
.Lw_reject: .asciz "reject"
.Lw_all: .asciz "all"
.p2align 3
.globl ai_ctl
ai_ctl:
    .quad .Lc_agents_source, c_agents_source
    .quad .Lc_print_review, c_print_review, .Lc_review, c_review
    .quad .Lc_print_tools, c_print_tools, .Lc_tool_confirm, c_tool_confirm
    .quad .Lc_agent_new, c_agent_new, .Lc_agent_prompt, c_agent_prompt
    .quad .Lc_agent_stop, c_agent_stop, .Lc_agent_card, c_agent_card
    .quad .Lc_print_agent_input, c_print_agent_input
    .quad .Lc_agent_type, c_agent_type, .Lc_agent_release, c_agent_release
    .quad .Lc_wait_agent, c_wait_agent, .Lc_print_agent_live, c_print_agent_live
    .quad .Lc_agent_timing, c_agent_timing
    .quad .Lc_print_agent_row, c_print_agent_row, .Lc_agent_test_append, c_agent_test_append
    .quad 0, 0
live_states: .quad .Ls_off, .Ls_starting, .Ls_ready, .Ls_working, .Ls_waiting, .Ls_held, .Ls_failed
timings: .quad .Lt_idle, g_drv_idle_ms, .Lt_term, g_conn_term_ms, .Lt_kill, g_conn_kill_ms
    .quad .Lt_eof, g_conn_eof_ms, .Lt_hold, g_drv_hold_ms, .Lt_guard, g_conn_max, 0, 0
