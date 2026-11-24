# headless commands for the AI features (wider-parity D), reached from control.s for names its
# table does not have: they drive the agents panel's extension sessions, the Review tab and tools,
# and print their state for tests
.include "rhun.inc"

.equ TK_UP, 0                   # agent-test-tool's keys (tt_keys)
.equ TK_STATE, 14
.equ TK_ITEM, 19
.equ TK_SRC, 20
.equ TK_READY, 21
.equ TK_DONE, 22
.equ TK_REPEAT, 23
.equ TT_MAX, 64                 # keys given at most

.bss
.p2align 3
args_p: .quad 0
args_n: .quad 0
outsb: .quad 0
tr_text: .zero SB_SIZE          # agent-test-row's and agent-test-tool's texts, unescaped

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
8:  xor edi, edi                # why not, as a line
    call no_chat
    mov rax, -1
    EPILOGUE

# no_chat(look): why the box takes nothing, a line of the output (the command answers error): the chat is
#   off, or this is a remote window (look 1: when the open session is a Claude Code one, or none is
#   open), else no open conversation takes prompts
no_chat:
    PROLOGUE
    test edi, edi
    jz 1f
    call agents_open_any
    test rax, rax
    jz 1f
    lea rbx, [rip + .Lr_no_box]
    cmp dword ptr [rax + AS_kind], AG_CLAUDE
    jne 3f
1:  lea rbx, [rip + .Lr_chat_off]
    cmp dword ptr [rip + cfg_claude_chat], 0
    je 3f
    lea rbx, [rip + agentext_remote_text]
    cmp dword ptr [rip + g_remote], 0
    jne 3f
    lea rbx, [rip + .Lr_no_box]
3:  call ai_out
    mov rdi, rax
    mov rsi, rbx
    call sb_push_cstr
    call ai_out
    mov rdi, rax
    mov esi, 10
    call sb_push_byte
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
    call agentext_box
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
8:  mov edi, 1
    call no_chat
    mov rax, -1
    EPILOGUE

# agent-type TEXT: TEXT typed into the prompt box, not sent (the session's program starts); while the command
#   menu's filter has the keys, into the filter
c_agent_type:
    PROLOGUE
    call ai_set
    call has_target
    test eax, eax
    jz 8f
    call agentpop_field         # the command menu's filter while it has the keys (agentpop.s)
    mov rbx, rax
    call ai_arg_rest
    mov rdi, rax
    mov rsi, rdx
    test rbx, rbx
    jz 1f
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, rbx
    call ta_insert
    xor eax, eax
    EPILOGUE
1:  call agentext_paste
    call agentext_typed
    call agentext_box_changed   # the typed command menu follows it (agentpop.s)
    xor eax, eax
    EPILOGUE
8:  mov edi, 1
    call no_chat
    mov rax, -1
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

# agent-card N | fold | details | dest | submit | close | link | review: option N (from 1) of the open session's card
#   (a rich card's button N once its lock is over, agentcard.s; the question card's row N of the question it
#   shows); a rich card's fold button, its Details, a click on its place; the question card's Submit
#   answers and its × (a dialog card's × too); a dialog card's "Learn more"
c_agent_card:
    PROLOGUE
    call ai_set
    call ai_arg
    mov r12, rax
    mov r13, rdx
    call agents_open_driven
    test rax, rax
    jz 9f
    mov r14, rax
    mov rdi, r12
    mov rsi, r13
    call card_word
    test eax, eax
    js 1f
    mov rdi, r14
    mov esi, eax
    call agentcard_toggle
    jmp 9f
1:  mov rdi, r12
    mov rsi, r13
    call parse_u64
    lea rbx, [rax - 1]
    mov rdi, r14
    call agentcard_of
    test rax, rax
    jz 2f
    mov rdi, r14
    mov rsi, rbx
    call agentcard_pick
    jmp 9f
2:  mov rdi, r14
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

# agent-timing [idle=MS] [term=MS] [kill=MS] [eof=MS] [hold=MS] [guard=N] [queue=BYTES] [cache=MS] [spin=MS]
#   [card=MS] [keyed=MS] [advance=MS]: shorter times (and a smaller cap, a smaller input queue, a prompt
#   cache's lifetime, 0 the CLI's) for tests; card: a rich card's lock, keyed: how recent a key in the box
#   keeps a new card from taking the keyboard, advance: the question card's move to the next question
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

# print-holder SID: whether another program has that Claude Code conversation open
#   ("holder=none|other|unknown", agent_holder.s)
c_print_holder:
    PROLOGUE
    call ai_set
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rbx, rax
    mov rdi, rax
    call holder_claude
    mov r12d, eax
    mov rdi, rbx
    call mem_free
    call ai_out
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + .Lw_holder]
    call sb_push_cstr
    lea rcx, [rip + holder_names]
    mov rsi, [rcx + r12*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor eax, eax
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

# print-sh-quote ps|sh value|command|assign [NAME] TEXT: how the terminal's command line quotes TEXT for
#   PowerShell or a POSIX shell, whatever the system (agent_sh_quote): a value, a command, NAME=TEXT
c_print_sh_quote:
    PROLOGUE 32
    call ai_set
    call ai_arg
    xor ecx, ecx
    test rdx, rdx
    jz 8f
    cmp byte ptr [rax], 'p'
    sete cl
    mov [rsp], ecx              # PowerShell
    call ai_arg
    test rdx, rdx
    jz 8f
    xor ecx, ecx                # value 0, command 1, assign 2
    cmp byte ptr [rax], 'c'
    jne 1f
    mov ecx, 1
1:  cmp byte ptr [rax], 'a'
    jne 2f
    mov ecx, 2
2:  mov [rsp + 4], ecx
    mov qword ptr [rsp + 8], 0
    cmp ecx, 2
    jne 3f
    call ai_arg                 # the name
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rsp + 8], rax
3:  call ai_arg_rest
4:  test rdx, rdx               # from its first character
    jz 5f
    cmp byte ptr [rax], ' '
    jne 5f
    inc rax
    dec rdx
    jmp 4b
5:  mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rsp + 16], rax
    call ai_out
    mov rdi, rax
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov rcx, [rsp + 8]
    mov r8, [rsp + 16]
    call agent_sh_quote
    mov rdi, [rsp + 8]
    call mem_free
    mov rdi, [rsp + 16]
    call mem_free
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# print-agent-placeholder: the prompt box's placeholder as drawn last (agentext_placeholder_dump)
c_print_agent_placeholder:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call agentext_placeholder_dump
    xor eax, eax
    EPILOGUE

# print-agent-composer: "draft=0|1 paint=START-END|-" of a driven conversation's box (composer_dump), nothing
#   for a draft's or an extension session's
c_print_agent_composer:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call composer_dump
    xor eax, eax
    EPILOGUE

# print-agents-box: the prompt row's layout at every panel size and width (agentext_box_dump)
c_print_agents_box:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call agentext_box_dump
    xor eax, eax
    EPILOGUE

# print-agents-metrics: the agents panel's text size and what follows from it (agentfont.s)
c_print_agents_metrics:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call agents_metrics_dump
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

# print-agent-thread: the open conversation's engine as the last frame left it (agents_thread_dump)
c_print_agent_thread:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call agents_thread_dump
    xor eax, eax
    EPILOGUE

# ---- phase 3 task 8: the error block ----

# print-agent-error: the open conversation's error block as the last frame drew it (agrow_err_dump: "text
#   X,Y,W,H T", "button PART X,Y,W,H ID" a link: 32 Retry, 33 new, 34 logs, 35 ×), "none" when it shows none
c_print_agent_error:
    PROLOGUE
    call ai_set
    call agents_viewed
    mov rbx, rax
    call ai_out
    mov rdi, rax
    mov rsi, rbx
    call agrow_err_dump
    xor eax, eax
    EPILOGUE

# print-agent-look: around the open conversation's rows as the last frame drew them (agents_look_dump: the
#   veil, the jump button, the error block, the sticky prompt, the empty conversation's line)
c_print_agent_look:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call agents_look_dump
    xor eax, eax
    EPILOGUE

# agent-error-click N: as a click on the error block's link N (0 Retry, 1 Start a new conversation, 2 View
#   output logs, 3 ×), followed after the frame
c_agent_error_click:
    PROLOGUE
    call ai_set
    call agents_viewed
    test rax, rax
    jz 8f
    mov rbx, rax
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    cmp rax, 3
    ja 8f
    mov rdi, rbx
    mov rsi, rax
    call agrow_err_click
    test eax, eax
    jz 8f
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# print-agent-spinner: the spinner line of the open conversation and the tick (agspin_dump; phase 3 task 5)
c_print_agent_spinner:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call agspin_dump
    xor eax, eax
    EPILOGUE

# agent-spin-tick [N]: N steps of the tick now (1), whatever its time (agent-timing spin=0 holds it)
c_agent_spin_tick:
    PROLOGUE
    call ai_set
    mov ebx, 1
    call ai_arg
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov ebx, eax
1:  test ebx, ebx
    jz 9f
    call agspin_step
    dec ebx
    jmp 1b
9:  xor eax, eax
    EPILOGUE

# agent-test-view: as a setting that changes heights (agents_view_changed)
c_agent_test_view:
    PROLOGUE
    call ai_set
    call agents_view_changed
    xor eax, eax
    EPILOGUE

# ai_unescape(ptr, len, sb): the text with "\n" a line feed, "\t" a tab, "\r" a carriage return, "\e" an
#   escape, "\a" a bell, "\xHH" that byte and "\\" a backslash, into sb (cleared)
ai_unescape:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rbx, rdx
    mov rdi, rbx
    call sb_clear
    xor r14d, r14d
1:  cmp r14, r13
    jae 9f
    movzx esi, byte ptr [r12 + r14]
    inc r14
    cmp esi, '\\'
    jne 3f
    cmp r14, r13
    jae 3f
    movzx eax, byte ptr [r12 + r14]
    cmp eax, 'n'
    jne 21f
    mov esi, 10
    jmp 2f
21: cmp eax, 't'
    jne 22f
    mov esi, 9
    jmp 2f
22: cmp eax, 'r'
    jne 23f
    mov esi, 13
    jmp 2f
23: cmp eax, 'e'
    jne 24f
    mov esi, 27
    jmp 2f
24: cmp eax, 'a'
    jne 25f
    mov esi, 7
    jmp 2f
25: cmp eax, 'x'
    jne 26f
    lea rax, [r14 + 3]
    cmp rax, r13
    ja 3f
    movzx edi, byte ptr [r12 + r14 + 1]
    call hex_val
    mov r15d, eax
    movzx edi, byte ptr [r12 + r14 + 2]
    call hex_val
    test eax, eax
    js 3f
    test r15d, r15d
    js 3f
    shl r15d, 4
    or eax, r15d
    mov esi, eax
    add r14, 2
    jmp 2f
26: cmp eax, '\\'
    jne 3f
2:  inc r14
3:  mov rdi, rbx
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# hex_val(byte) -> eax its value as a hex digit, -1
hex_val:
    lea eax, [rdi - '0']
    cmp eax, 9
    jbe 9f
    mov eax, edi
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 5
    ja 8f
    add eax, 10
9:  ret
8:  mov eax, -1
    ret

# ai_opt(word ptr, len, names table) -> eax the index of its name in the table ("NAME=" it begins with), -1
#   none; rdx the value's start, rcx its length
ai_opt:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor ebx, ebx
1:  mov r15, [r14 + rbx*8]
    test r15, r15
    jz 8f
    mov rdi, r15
    call strlen
    mov rcx, rax
    lea rax, [rcx + 1]
    cmp r13, rax
    jb 2f
    cmp byte ptr [r12 + rcx], '='
    jne 2f
    push rcx
    push rcx
    mov rdi, r12
    mov rsi, r15
    mov rdx, rcx
    call memeq
    pop rcx
    pop rcx
    test eax, eax
    jz 2f
    lea rdx, [r12 + rcx + 1]
    mov rax, r13
    sub rax, rcx
    dec rax
    mov rcx, rax
    mov eax, ebx
    EPILOGUE
2:  inc ebx
    jmp 1b
8:  mov eax, -1
    EPILOGUE

# agent-test-row thinking|meta|compact|unknown|user|agent [OPT=V...] TEXT [OPT=V...]: a row of that kind at
#   the end of the open conversation ("\n", "\t" in TEXT), as a reader would make it; the options, before or
#   after the text: ms=N (thinking's time), live=1 (still streaming), t=UNIXMS (its time), notice=1 (a wrapped
#   notice), echo=1 (a slash command's echo), n=N (a compaction's thousands of tokens freed), manual=1 (a
#   compaction asked for), failed=1 (a failed reply), open=1 (a prompt or marker shown whole)
c_agent_test_row:
    PROLOGUE 80
    call ai_set
    call agents_viewed
    test rax, rax
    jz 8f
    mov [rsp], rax
    call ai_arg
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + row_kinds]
    call ai_opt_word
    test eax, eax
    js 8f
    lea rcx, [rip + row_roles]
    mov eax, [rcx + rax*4]
    mov [rsp + 8], eax          # the role
    mov dword ptr [rsp + 12], -1    # ms
    mov qword ptr [rsp + 16], 0     # flags
    mov qword ptr [rsp + 24], 0     # t
    mov qword ptr [rsp + 32], 0     # n
    call ai_arg_rest
    mov rdi, rax
    mov rsi, rdx
    call trim
    mov r12, rax                # what is left
    mov r13, rdx
1:  mov rdi, r12                # the options before the text
    mov rsi, r13
    call next_word
    mov [rsp + 40], rcx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rsp]
    call row_opt
    test eax, eax
    jz 2f
    add r12, [rsp + 40]
    sub r13, [rsp + 40]
    jmp 1b
2:  mov rdi, r12                # and after it
    mov rsi, r13
    call trim
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 4f
    mov rcx, r13
3:  dec rcx
    js 31f
    cmp byte ptr [r12 + rcx], ' '
    jne 3b
31: inc rcx                     # the last word's start
    mov [rsp + 40], rcx
    lea rdi, [r12 + rcx]
    mov rsi, r13
    sub rsi, rcx
    lea rdx, [rsp]
    call row_opt
    test eax, eax
    jz 4f
    mov r13, [rsp + 40]
    jmp 2b
4:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + tr_text]
    call ai_unescape
    mov rbx, [rsp]
    mov rdi, rbx
    mov rsi, [rsp + 24]
    call agents_stamp
    mov rdi, rbx
    mov esi, [rsp + 8]
    mov rdx, [rip + tr_text + SB_ptr]
    test rdx, rdx
    jnz 41f
    lea rdx, [rip + .Lempty_str]
41: mov rcx, [rip + tr_text + SB_len]
    xor r8d, r8d
    call agents_msg_add
    mov r14, rax
    mov rdi, rbx
    xor esi, esi
    call agents_stamp
    test r14, r14
    js 8f
    imul rax, r14, AM_SIZE
    add rax, [rbx + AS_msgs + VEC_ptr]
    mov ecx, [rsp + 12]
    mov [rax + AM_ms], ecx
    mov ecx, [rsp + 16]
    or [rax + AM_flags], ecx
    mov ecx, [rsp + 32]
    mov [rax + AM_n], ecx
    mov rdi, rbx
    mov rsi, r14
    call agents_msg_changed
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# ai_opt_word(ptr, len, cstr table) -> eax the index of the word in the table, -1
ai_opt_word:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor ebx, ebx
1:  mov rdx, [r14 + rbx*8]
    test rdx, rdx
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 9f
    inc ebx
    jmp 1b
8:  mov ebx, -1
9:  mov eax, ebx
    EPILOGUE

# row_opt(word ptr, len, frame*) -> eax 1 when the word was one of agent-test-row's options (kept in the
#   frame: [12] ms, [16] flags, [24] t, [32] n)
row_opt:
    PROLOGUE
    mov rbx, rdx
    test rsi, rsi
    jz 8f
    lea rdx, [rip + row_opts]
    call ai_opt
    test eax, eax
    js 8f
    mov r12d, eax
    mov rdi, rdx
    mov rsi, rcx
    call parse_u64
    cmp r12d, 0
    jne 1f
    mov [rbx + 12], eax         # ms
    jmp 9f
1:  cmp r12d, 2
    jne 2f
    mov [rbx + 24], rax         # t
    jmp 9f
2:  cmp r12d, 5
    jne 3f
    mov [rbx + 32], eax         # n
    jmp 9f
3:  test rax, rax               # a flag word: on when not 0
    jz 9f
    lea rcx, [rip + row_flags]
    mov eax, [rcx + r12*4]
    or [rbx + 16], eax
9:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE


# print-agent-rows [content] [FROM [N]]: the open conversation's rows from FROM (0) on, N of them (all): a row
#   a line with its kind's fields and parts (agrow_dump); content: what a reread must give again
c_print_agent_rows:
    PROLOGUE 32
    call ai_set
    call agents_viewed
    mov rbx, rax
    xor r12d, r12d              # content
    xor r13d, r13d              # from
    mov r14, -1                 # n
    call ai_arg
    test rdx, rdx
    jz 3f
    cmp byte ptr [rax], 'c'
    jne 1f
    mov r12d, 1
    call ai_arg
    test rdx, rdx
    jz 3f
1:  mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov r13, rax
    call ai_arg
    test rdx, rdx
    jz 3f
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov r14, rax
3:  call ai_out
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r13
    mov rcx, r14
    mov r8d, r12d
    call agrow_dump
    xor eax, eax
    EPILOGUE

# print-agent-rows-fit: the typed rows laid out at every panel size and width (agrow_fit_dump)
c_print_agent_rows_fit:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call agrow_fit_dump
    xor eax, eax
    EPILOGUE

# agent-row-click N [PART]: as a click on that part of row N (from 1, as print-agent-row) of the open
#   conversation (link, in, out, pre, diff, note, toggle, copy, kids, more, stop, bg; none: the part Enter
#   runs), followed after the frame the command ends with
c_agent_row_click:
    PROLOGUE
    call ai_set
    call agents_viewed
    test rax, rax
    jz 8f
    mov rbx, rax
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test rax, rax
    jz 8f
    lea r12, [rax - 1]
    xor r13d, r13d
    call ai_arg
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + part_words]
    call ai_opt_word
    test eax, eax
    js 8f
    lea rcx, [rip + part_nums]
    mov r13d, [rcx + rax*4]
1:  mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call agrow_click
    test eax, eax
    jz 8f
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# agent-test-tool ID [up=ID] [name=T] [second=T] [link=T] [tail=T] [desc=T] [note=T] [in=T] [out=T] [a=T]
#   [b=T] [title=T] [find=T] [aux=T] [state=S] [flags=N] [l0=N] [l1=N] [nkids=N] [item=STATE:T]...
#   [src=FILE:OFFSET:LENGTH] [ready=1] [done=1] [repeat=N]: a typed row made (or changed: a call of that id)
#   on the open conversation through agrow_* alone. A value runs to the next " KEY=" of these keys ("\n",
#   "\t" in it); STATE of an item pending, active or done. repeat=N: N calls, ID-0 to ID-(N-1), alike.
#   No driver and no reader is asked
c_agent_test_tool:
    PROLOGUE 48
    call ai_set
    call agents_viewed
    test rax, rax
    jz 8f
    mov [rsp], rax
    call ai_arg                 # the id
    test rdx, rdx
    jz 8f
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    call ai_arg_rest
    mov rdi, rax
    mov rsi, rdx
    call trim
    mov [rip + tt_rest], rax
    mov [rip + tt_len], rdx
    call tt_split                # the keys' places
    mov qword ptr [rsp + 24], 0  # repeat
    mov edi, TK_REPEAT
    call tt_value
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov [rsp + 24], rax
1:  cmp qword ptr [rsp + 24], 0
    jne 2f
    mov rdi, [rsp]              # one call, ID
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    call tt_one
    jmp 7f
2:  mov dword ptr [rip + tt_many], 1
    xor r15d, r15d              # ID-0 .. ID-(N-1)
3:  cmp r15, [rsp + 24]
    jae 7f
    lea rdi, [rip + tt_id]
    call sb_clear
    lea rdi, [rip + tt_id]
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    call sb_push
    lea rdi, [rip + tt_id]
    mov esi, '-'
    call sb_push_byte
    lea rdi, [rip + tt_id]
    mov rsi, r15
    call sb_push_u64
    mov rdi, [rsp]
    mov rsi, [rip + tt_id + SB_ptr]
    mov rdx, [rip + tt_id + SB_len]
    call tt_one
    inc r15
    jmp 3b
7:  mov dword ptr [rip + tt_many], 0
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# tt_split(): agent-test-tool's keys in tt_rest: where each "KEY=" starts (at the start or after a blank), in
#   tt_at (key, value start), tt_n of them
tt_split:
    PROLOGUE
    mov dword ptr [rip + tt_n], 0
    xor r12d, r12d
1:  cmp r12, [rip + tt_len]
    jae 9f
    test r12, r12
    jz 2f
    mov rax, [rip + tt_rest]
    cmp byte ptr [rax + r12 - 1], ' '
    jne 3f
2:  mov rdi, [rip + tt_rest]
    add rdi, r12
    mov rsi, [rip + tt_len]
    sub rsi, r12
    lea rdx, [rip + tt_keys]
    call ai_opt
    test eax, eax
    js 3f
    mov ecx, [rip + tt_n]
    cmp ecx, TT_MAX
    jae 9f
    lea r8, [rip + tt_at]
    shl rcx, 4
    mov [r8 + rcx], rax         # the key
    sub rdx, [rip + tt_rest]
    mov [r8 + rcx + 8], rdx     # its value's start
    inc dword ptr [rip + tt_n]
3:  inc r12
    jmp 1b
9:  EPILOGUE

# tt_entry(i) -> rax the value's ptr, rdx its length (to the next key's blank), ecx the key
tt_entry:
    mov rax, rdi
    shl rax, 4
    lea r8, [rip + tt_at]
    mov ecx, [r8 + rax]
    mov r9, [r8 + rax + 8]      # its start
    mov rdx, [rip + tt_len]
    lea r10, [rdi + 1]
    cmp r10d, [rip + tt_n]
    jae 1f
    shl r10, 4
    mov rdx, [r8 + r10 + 8]     # the next key's start, less its key and the blank before it
    mov r11d, [r8 + r10]
    push rcx
    push rdx
    push r9
    push r11
    lea rax, [rip + tt_keys]
    mov rdi, [rax + r11*8]
    call strlen
    pop r11
    pop r9
    pop rdx
    pop rcx
    sub rdx, rax
    sub rdx, 2
1:  sub rdx, r9
    jns 2f
    xor edx, edx
2:  mov rax, [rip + tt_rest]
    add rax, r9
    ret

# tt_value(key) -> rax ptr, rdx len of that key's (first) value, rax 0 when it is not given
tt_value:
    PROLOGUE
    mov ebx, edi
    xor r12d, r12d
1:  cmp r12d, [rip + tt_n]
    jae 8f
    mov edi, r12d
    call tt_entry
    cmp ecx, ebx
    je 9f
    inc r12d
    jmp 1b
8:  xor eax, eax
    xor edx, edx
9:  EPILOGUE

# tt_one(AS*, id ptr, len): agent-test-tool's call of that id, made or changed with every key given
tt_one:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp dword ptr [rip + tt_many], 0
    je 0f
    call agrow_find             # repeat=N: new calls (a row's own id is not looked for)
    jmp 8f
0:  call agrow_by_id
8:
    mov r14, rax
    test r14, r14
    jnz 1f
    mov edi, TK_UP              # made: under its parent when one is named
    call tt_value
    mov rcx, rax
    mov r8, rdx
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call agrow_tool
    mov r14, rax
    test r14, r14
    jz 9f
1:  mov edi, TK_SRC             # its place first: the texts keep a preview then
    call tt_value
    test rax, rax
    jz 2f
    mov rdi, r14
    mov rsi, rax
    call tt_src
2:  xor r15d, r15d
3:  cmp r15d, [rip + tt_n]
    jae 6f
    mov edi, r15d
    call tt_entry
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov [rsp + 16], ecx
    lea rax, [rip + tt_atx]     # a text part
    mov eax, [rax + rcx*4]
    test eax, eax
    js 4f
    mov [rsp + 20], eax
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rip + tr_text]
    call ai_unescape
    mov rdi, r14
    mov esi, [rsp + 20]
    mov rdx, [rip + tr_text + SB_ptr]
    mov rcx, [rip + tr_text + SB_len]
    test rdx, rdx
    jnz 31f
    lea rdx, [rip + .Lempty_str]
31: call agrow_set
    cmp dword ptr [rsp + 20], ATX_SECOND    # the row's summary: its second text
    jne 5f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, [rip + tr_text + SB_ptr]
    mov rcx, [rip + tr_text + SB_len]
    call agrow_summary
    jmp 5f
4:  mov rdi, rbx                # a number, a state, an item
    mov rsi, r14
    mov edx, [rsp + 16]
    mov rcx, [rsp]
    mov r8, [rsp + 8]
    call tt_num
5:  inc r15d
    jmp 3b
6:  mov edi, TK_READY
    call tt_value
    test rax, rax
    jz 61f
    mov rdi, rbx
    mov rsi, r14
    call agrow_ready
61: mov edi, TK_DONE
    call tt_value
    test rax, rax
    jz 62f
    mov rdi, rbx
    mov rsi, r14
    call agrow_done
62: mov rdi, rbx
    mov rsi, r14
    call agrow_touch
9:  EPILOGUE

# tt_src(AT*, "FILE:OFFSET:LENGTH")
tt_src:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, r13                # the last ':'
1:  test r14, r14
    jz 9f
    dec r14
    cmp byte ptr [r12 + r14], ':'
    jne 1b
    lea rdi, [r12 + r14 + 1]
    mov rsi, r13
    sub rsi, r14
    dec rsi
    call parse_u64
    mov [rsp], rax              # the length
    mov r15, r14                # the ':' before it
2:  test r15, r15
    jz 9f
    dec r15
    cmp byte ptr [r12 + r15], ':'
    jne 2b
    lea rdi, [r12 + r15 + 1]
    mov rsi, r14
    sub rsi, r15
    dec rsi
    call parse_u64
    mov rcx, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    mov r8, [rsp]
    call agrow_place
9:  EPILOGUE

# tt_num(AS*, AT*, key, value ptr, len): state=S, flags=N, l0=N, l1=N, nkids=N, item=STATE:T
tt_num:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
    cmp r13d, TK_STATE
    jne 1f
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + state_words]
    call ai_opt_word
    test eax, eax
    js 9f
    mov rdi, r12
    mov edx, eax
    mov esi, ATV_STATE
    call agrow_num
    jmp 9f
1:  cmp r13d, TK_ITEM
    je 5f
    lea rax, [rip + tt_atv]     # a number
    mov eax, [rax + r13*4]
    test eax, eax
    js 9f
    mov [rsp], eax
    mov rdi, r14
    mov rsi, r15
    call parse_u64
    mov rdi, r12
    mov esi, [rsp]
    mov edx, eax
    call agrow_num
    jmp 9f
5:  xor ecx, ecx                # item=STATE:T
6:  cmp rcx, r15
    jae 9f
    cmp byte ptr [r14 + rcx], ':'
    je 7f
    inc rcx
    jmp 6b
7:  mov [rsp], rcx
    mov rdi, r14
    mov rsi, rcx
    lea rdx, [rip + todo_words]
    call ai_opt_word
    test eax, eax
    jns 71f
    xor eax, eax
71: mov [rsp + 8], eax
    mov rcx, [rsp]
    lea rdi, [r14 + rcx + 1]
    mov rsi, r15
    sub rsi, rcx
    dec rsi
    lea rdx, [rip + tr_text]
    call ai_unescape
    mov rdi, r12
    mov rsi, [rip + tr_text + SB_ptr]
    mov rdx, [rip + tr_text + SB_len]
    test rsi, rsi
    jnz 72f
    lea rsi, [rip + .Lempty_str]
72: mov ecx, [rsp + 8]
    call agrow_item
9:  EPILOGUE

# agent-test-truncate N: the open conversation's rows from N on go (agents_rows_cut: the chunks, folds and
#   calls after them with them), as an extension's shorter transcript cuts them
c_agent_test_truncate:
    PROLOGUE
    call ai_set
    call agents_viewed
    test rax, rax
    jz 8f
    mov rbx, rax
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov rdi, rbx
    mov rsi, rax
    call agents_rows_cut
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# ---- focus view (agentfold.s, phase 3 task 9)

# print-agent-folds: the open conversation's folds (agfold_dump); "focus=0|1" alone without one open
c_print_agent_folds:
    PROLOGUE
    call ai_set
    call agents_viewed
    mov rbx, rax
    call ai_out
    mov rdi, rax
    mov rsi, rbx
    call agfold_dump
    xor eax, eax
    EPILOGUE

# print-agent-folds-fit: their lines laid out at every panel size and width (agfold_fit_dump)
c_print_agent_folds_fit:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call agfold_fit_dump
    xor eax, eax
    EPILOGUE

# agent-fold-click N: the fold of row N (from 1, as print-agent-row) of the open conversation opened or closed,
#   as a click on its line or its Collapse line
c_agent_fold_click:
    PROLOGUE
    call ai_set
    call agents_viewed
    test rax, rax
    jz 8f
    mov rbx, rax
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test rax, rax
    jz 8f
    lea rsi, [rax - 1]
    mov rdi, rbx
    call agfold_toggle_row
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

.section .rodata
.Lc_print_agent_folds: .asciz "print-agent-folds"
.Lc_print_agent_folds_fit: .asciz "print-agent-folds-fit"
.Lc_agent_fold_click: .asciz "agent-fold-click"
.text

.bss
.p2align 3
tt_rest: .quad 0                # agent-test-tool: its keys and values, where each key's value starts
tt_len: .quad 0
tt_n: .long 0
tt_many: .long 0                # repeat=N runs
.p2align 3
tt_at: .zero 16 * TT_MAX
tt_id: .zero SB_SIZE
.section .rodata
.Lk_up: .asciz "up"
.Lk_name: .asciz "name"
.Lk_second: .asciz "second"
.Lk_link: .asciz "link"
.Lk_tail: .asciz "tail"
.Lk_desc: .asciz "desc"
.Lk_note: .asciz "note"
.Lk_in: .asciz "in"
.Lk_out: .asciz "out"
.Lk_a: .asciz "a"
.Lk_b: .asciz "b"
.Lk_title: .asciz "title"
.Lk_find: .asciz "find"
.Lk_aux: .asciz "aux"
.Lk_state: .asciz "state"
.Lk_flags: .asciz "flags"
.Lk_l0: .asciz "l0"
.Lk_l1: .asciz "l1"
.Lk_nkids: .asciz "nkids"
.Lk_item: .asciz "item"
.Lk_src: .asciz "src"
.Lk_ready: .asciz "ready"
.Lk_done: .asciz "done"
.Lk_repeat: .asciz "repeat"
.Ls_running: .asciz "running"
.Ls_ok: .asciz "ok"
.Ls_denied: .asciz "denied"
.Ls_stopped: .asciz "stopped"
.Lt_pending: .asciz "pending"
.Lt_active: .asciz "active"
.Lp_link: .asciz "link"
.Lp_in: .asciz "in"
.Lp_out: .asciz "out"
.Lp_pre: .asciz "pre"
.Lp_diff: .asciz "diff"
.Lp_note: .asciz "note"
.Lp_toggle: .asciz "toggle"
.Lp_copy: .asciz "copy"
.Lp_kids: .asciz "kids"
.Lp_more: .asciz "more"
.Lp_stop: .asciz "stop"
.Lp_bg: .asciz "bg"
.Lc_print_agent_rows: .asciz "print-agent-rows"
.Lc_print_agent_rows_fit: .asciz "print-agent-rows-fit"
.Lc_agent_test_tool: .asciz "agent-test-tool"
.Lc_agent_row_click: .asciz "agent-row-click"
.Lc_agent_test_truncate: .asciz "agent-test-truncate"
.p2align 3
tt_keys: .quad .Lk_up, .Lk_name, .Lk_second, .Lk_link, .Lk_tail, .Lk_desc, .Lk_note, .Lk_in, .Lk_out
    .quad .Lk_a, .Lk_b, .Lk_title, .Lk_find, .Lk_aux, .Lk_state, .Lk_flags, .Lk_l0, .Lk_l1, .Lk_nkids
    .quad .Lk_item, .Lk_src, .Lk_ready, .Lk_done, .Lk_repeat, 0
tt_atx: .long -1, ATX_NAME, ATX_SECOND, ATX_LINK, ATX_TAIL, ATX_DESC, ATX_NOTE, ATX_IN, ATX_OUT, ATX_A, ATX_B
    .long ATX_TITLE, ATX_FIND, ATX_AUX, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1
tt_atv: .long -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, ATV_SET, ATV_L0, ATV_L1, ATV_NKIDS
    .long -1, -1, -1, -1, -1
.p2align 3
state_words: .quad .Ls_running, .Ls_ok, .Ls_failed, .Ls_denied, .Ls_stopped, 0
todo_words: .quad .Lt_pending, .Lt_active, .Lk_done, 0
part_words: .quad .Lp_link, .Lp_in, .Lp_out, .Lp_pre, .Lp_diff, .Lp_note, .Lp_toggle, .Lp_copy, .Lp_kids
    .quad .Lp_more, .Lp_stop, .Lp_bg, 0
part_nums: .long PART_LINK, PART_IN, PART_OUT, PART_PRE, PART_DIFF, PART_NOTE, PART_TOGGLE, PART_COPY
    .long PART_KIDS, PART_MORE, PART_STOP, PART_BG
.text

# box_kind() -> eax the built-in driver kind the box belongs to: the open conversation's, else the new
#   one's being written; 0 none (an extension's)
box_kind:
    PROLOGUE
    call agents_open_driven
    test rax, rax
    jz 1f
    mov eax, [rax + AS_kind]
    jmp 2f
1:  call agentext_new_active
    cmp rax, AG_OPENCODE        # a small number is a built-in kind, a pointer an extension
    jbe 2f
    xor eax, eax
2:  cmp eax, AG_OPENCODE
    jbe 9f
    xor eax, eax
9:  EPILOGUE

# print-agent-cfg [KIND]: a driver kind's lists and choices for the project (agentcfg_dump; default
#   claude). It never reads the state file: read=0 says nothing has
c_print_agent_cfg:
    PROLOGUE
    call ai_set
    call ai_arg
    mov ebx, AG_CLAUDE
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call agent_kind_named
    test eax, eax
    jz 8f
    mov ebx, eax
1:  mov edi, ebx
    call agentcfg_get
    mov r12, rax
    call ai_out
    mov rdi, rax
    mov rsi, r12
    call agentcfg_dump
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# agent-models: the models picker, as the footer's pill opens it (its driver's record is read: a popup
#   opened is a writer's action, agentcfg_need); error without a box of a driver
c_agent_models:
    PROLOGUE
    call ai_set
    call box_kind
    test eax, eax
    jz 8f
    mov edi, eax
    call agentcfg_get
    mov rdi, rax
    call agentcfg_need
    mov edi, APP_MODELS
    xor esi, esi
    xor edx, edx
    call agentpop_open
    xor eax, eax
    EPILOGUE
8:  mov edi, 1
    call no_chat
    mov rax, -1
    EPILOGUE

# agent-cfg-set FIELD VALUE: a choice in the box's driver record (claude's when there is none), as a picker
#   makes it, for tests: model, effort, dest, newmode (text), ultra, think (-1 "-", 0, 1)
c_agent_cfg_set:
    PROLOGUE
    call ai_set
    call ai_arg
    mov r12, rax
    mov r13, rdx
    lea r14, [rip + cfg_fields]
1:  mov rdx, [r14]
    test rdx, rdx
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add r14, 16
    jmp 1b
2:  call box_kind
    test eax, eax
    jnz 3f
    mov eax, AG_CLAUDE
3:  mov edi, eax
    call agentcfg_get
    mov rbx, rax
    call ai_arg_rest
    mov r12, rax
    mov r13, rdx
6:  test r13, r13               # from its first character
    jz 7f
    cmp byte ptr [r12], ' '
    jne 7f
    inc r12
    dec r13
    jmp 6b
7:  cmp dword ptr [r14 + 12], 0
    je 5f
    mov rdx, -1                 # an int
    test r13, r13
    jz 4f
    cmp byte ptr [r12], '-'
    je 4f
    mov rdi, r12
    mov rsi, r13
    call parse_u64
    mov rdx, rax
4:  mov rdi, rbx
    mov esi, [r14 + 8]
    call agentcfg_set
    jmp 9f
5:  mov rdi, rbx
    mov esi, [r14 + 8]
    mov rdx, r12
    mov rcx, r13
    call agentcfg_set
9:  xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# ---- the command menu and the bands (agentpop.s, agentfoot.s) ----

# agent-menu [TEXT]: the command menu as its button opens it, TEXT typed into its filter; error without a box
#   of a built-in driver
c_agent_menu:
    PROLOGUE
    call ai_set
    mov edi, APP_MENU
    xor esi, esi
    xor edx, edx
    call agentpop_open
    test eax, eax
    jz 8f
    call ai_arg_rest
    mov rbx, rax
    mov r12, rdx
1:  test r12, r12               # from its first character
    jz 9f
    cmp byte ptr [rbx], ' '
    jne 2f
    inc rbx
    dec r12
    jmp 1b
2:  call agentpop_field
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call ta_insert
9:  xor eax, eax
    EPILOGUE
8:  mov edi, 1
    call no_chat
    mov rax, -1
    EPILOGUE

# agent-menu-pick N: row N (from 1) of the open popup as Enter takes it; error when it has none
c_agent_menu_pick:
    PROLOGUE
    call ai_set
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov rdi, rax
    call agentpop_pick
    test eax, eax
    jz 8f
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# print-agent-menu [fit]: the open popup (agentpop_dump); fit: its layout at every size and width
c_print_agent_menu:
    PROLOGUE
    call ai_set
    call ai_arg
    mov rbx, rdx
    call ai_out
    mov rdi, rax
    test rbx, rbx
    jnz 1f
    call agentpop_dump
    xor eax, eax
    EPILOGUE
1:  call agentpop_fit_dump
    xor eax, eax
    EPILOGUE

# agent-modes: the modes picker, as the footer's mode button opens it; error without a box of a built-in
#   driver that has modes
c_agent_modes:
    PROLOGUE
    call ai_set
    mov edi, APP_MODES
    xor esi, esi
    xor edx, edx
    call agentpop_open
    test eax, eax
    jz 8f
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# agent-mode ID: the box's conversation takes that mode as the picker gives it (foot_mode_set: only a mode
#   offered now); error when it is refused
c_agent_mode:
    PROLOGUE 48
    call ai_set
    call ai_arg
    test rdx, rdx
    jz 8f
    cmp rdx, 40
    jae 8f
    lea rdi, [rsp]
    mov rsi, rax
    mov byte ptr [rdi + rdx], 0
    call memmove
    call agentext_box_owner
    test edx, edx
    jz 8f
    mov rdi, rax
    lea rsi, [rsp]
    call foot_mode_set
    test eax, eax
    jz 8f
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# ---- the model, effort, Ultracode and thinking (task 6) ----

# box_live() -> rax the live record of the box's conversation (a draft becomes its conversation first;
#   nothing starts), or 0
box_live:
    PROLOGUE
    call agentext_box_owner
    test edx, edx
    jz 8f
    test rax, rax
    jnz 1f
    call agentext_draft_own
    test rax, rax
    jz 8f
1:  mov rdi, rax
    call agent_live
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# set_arg(rdi buf of 64) -> eax 1 with the command's first argument in buf (a cstr), 0 when there is none
#   or it is too long
set_arg:
    PROLOGUE
    mov rbx, rdi
    call ai_arg
    test rdx, rdx
    jz 8f
    cmp rdx, 63
    ja 8f
    mov rdi, rbx
    mov rsi, rax
    mov byte ptr [rdi + rdx], 0
    call memmove
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# agent-model VALUE, agent-effort ID: the box's conversation takes them as the pickers give them (DRV_set_model,
#   DRV_set_effort: the project's choice; nothing starts); error when refused
c_agent_model:
    mov eax, DRV_set_model
    jmp set_text
c_agent_effort:
    mov eax, DRV_set_effort
set_text:
    PROLOGUE 80
    mov r12d, eax
    call ai_set
    lea rdi, [rsp]
    call set_arg
    test eax, eax
    jz 8f
    call box_live
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rcx, [rax + AL_drv]
    lea rsi, [rsp]
    call [rcx + r12]
    test eax, eax
    jz 8f
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# agent-ultra on|off, agent-thinking on|off: as the switches give them (DRV_set_ultra, DRV_set_thinking);
#   error when refused
c_agent_ultra:
    mov eax, DRV_set_ultra
    jmp set_switch
c_agent_thinking:
    mov eax, DRV_set_thinking
set_switch:
    PROLOGUE 80
    mov r12d, eax
    call ai_set
    lea rdi, [rsp]
    call set_arg
    test eax, eax
    jz 8f
    mov r13d, 1
    lea rdi, [rsp]
    lea rsi, [rip + .Lw_on]
    call strcmp_eq
    test eax, eax
    jnz 1f
    xor r13d, r13d
    lea rdi, [rsp]
    lea rsi, [rip + .Lw_off]
    call strcmp_eq
    test eax, eax
    jz 8f
1:  call box_live
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rcx, [rax + AL_drv]
    mov esi, r13d
    call [rcx + r12]
    test eax, eax
    jz 8f
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# print-agents-foot [every]: the footer under the box (foot_dump; every: each combination of its extras)
c_print_agents_foot:
    PROLOGUE
    call ai_set
    call ai_arg                 # "every": every combination of the controls that come and go
    xor ebx, ebx
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lw_every]
    call str_eq_cstr
    mov ebx, eax
1:  call ai_out
    mov rdi, rax
    mov esi, ebx
    call foot_dump
    xor eax, eax
    EPILOGUE

# print-agent-bands: the open conversation's bands (bands_dump)
c_print_agent_bands:
    PROLOGUE
    call ai_set
    call agents_open_driven
    mov rbx, rax
    call ai_out
    mov rdi, rax
    mov rsi, rbx
    call bands_dump
    xor eax, eax
    EPILOGUE

# agent-test-band KIND TEXT: a band on the open conversation, as its driver would show it (tests; KIND error,
#   settings, auth, rate, notice; no TEXT takes it away)
c_agent_test_band:
    PROLOGUE
    call ai_set
    call ai_arg
    mov r12, rax
    mov r13, rdx
    xor ebx, ebx
1:  cmp ebx, BK_COUNT
    jae 8f
    lea rax, [rip + band_words]
    mov rdx, [rax + rbx*8]
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc ebx
    jmp 1b
2:  call agents_open_driven
    test rax, rax
    jz 8f
    mov rdi, rax
    call agent_live
    test rax, rax
    jz 8f
    mov r14, rax
    call ai_arg_rest
    mov r12, rax
    mov r13, rdx
3:  test r13, r13
    jz 4f
    cmp byte ptr [r12], ' '
    jne 5f
    inc r12
    dec r13
    jmp 3b
4:  xor r12d, r12d
5:  mov rdi, r14
    mov esi, ebx
    mov rdx, r12
    mov rcx, r13
    call ev_band
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# ---- the rich cards (agentcard.s) ----

# card_word(ptr, len) -> eax agentcard_toggle's what for "fold", "details", "dest", "submit", "close",
#   "link", else -1
card_word:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp ebx, 7
    jae 8f
    lea rax, [rip + card_words]
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

# print-agent-card: the open conversation's rich card (agentcard_dump)
c_print_agent_card:
    PROLOGUE
    call ai_set
    call agents_open_driven
    mov rbx, rax
    test rax, rax
    jz 9f
    call ai_out
    mov rdi, rax
    mov rsi, rbx
    call agentcard_dump
9:  xor eax, eax
    EPILOGUE

# ---- phase 4 tasks 11 and 12: proposed changes ----
# print-agent-offer: the open conversation's head request's proposed change in the Review tab (agoffer_dump):
#   offer=ID file=PATH label=LABEL changes=N decided=N edited=0|1 scratch=0|1 shown=0|1 done=0|1 locked=0|1,
#   or offer=none
c_print_agent_offer:
    PROLOGUE
    call ai_set
    call agents_open_driven
    mov rbx, rax
    call ai_out
    mov rdi, rax
    mov rsi, rbx
    call agoffer_dump
    xor eax, eax
    EPILOGUE

.section .rodata
.Lc_print_agent_offer: .asciz "print-agent-offer"
.Lw_card_review: .asciz "review"
.text
# ---- end of tasks 11 and 12 ----

# print-agent-card-fit: its layout at every panel size and width (agentcard_fit_dump)
c_print_agent_card_fit:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call agentcard_fit_dump
    xor eax, eax
    EPILOGUE

# agent-card-text field|edit|other TEXT: the rich card's reject field, or its command, holds TEXT (other:
#   a question's Other field, the question card's); error without such a field
c_agent_card_text:
    PROLOGUE
    call ai_set
    call ai_arg
    mov r12, rax
    mov r13, rdx
    xor ebx, ebx
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_card_field]
    call str_eq_cstr
    test eax, eax
    jnz 1f
    mov ebx, 1
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_card_edit]
    call str_eq_cstr
    test eax, eax
    jnz 1f
    mov ebx, 2                  # the question card's Other
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_card_other]
    call str_eq_cstr
    test eax, eax
    jz 8f
1:  call agents_open_driven
    test rax, rax
    jz 8f
    mov r12, rax
    call ai_arg_rest
2:  test rdx, rdx               # from its first character
    jz 3f
    cmp byte ptr [rax], ' '
    jne 3f
    inc rax
    dec rdx
    jmp 2b
3:  mov rdi, r12
    mov esi, ebx
    mov rcx, rdx
    mov rdx, rax
    call agentcard_set_text
    test eax, eax
    jz 8f
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# agent-focus editor|panel|box: the keyboard to the editor, the agents panel or its prompt box (as a click
#   would put it there; the panel stays as it is)
c_agent_focus:
    PROLOGUE
    call ai_set
    call ai_arg
    mov r12, rax
    mov r13, rdx
    xor ebx, ebx
1:  cmp ebx, 3
    jae 8f
    lea rax, [rip + focus_words]
    mov ecx, ebx
    shl ecx, 4
    mov rdx, [rax + rcx]
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc ebx
    jmp 1b
2:  lea rax, [rip + focus_words]
    shl ebx, 4
    mov eax, [rax + rbx + 8]
    mov [rip + g_focus], eax
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# ---- plan review (task 11): the plan's tab (mdtab.s) and the plan card's comments (agentcard.s) ----

# rest_text() -> rax ptr, rdx len: the rest of the line from its first character
rest_text:
    sub rsp, 8
    call ai_arg_rest
    add rsp, 8
1:  test rdx, rdx
    jz 2f
    cmp byte ptr [rax], ' '
    jne 2f
    inc rax
    dec rdx
    jmp 1b
2:  ret

# print-mdtab: the Markdown tabs (mdtab_dump)
c_print_mdtab:
    PROLOGUE
    call ai_set
    call ai_out
    mov rdi, rax
    call mdtab_dump
    xor eax, eax
    EPILOGUE

# mdtab-select TEXT: the text selected in the active Markdown tab (else the newest); error when not found
c_mdtab_select:
    PROLOGUE
    call ai_set
    call rest_text
    mov rdi, rax
    mov rsi, rdx
    call mdtab_select
    test eax, eax
    jz 8f
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# mdtab-comment [TEXT]: its Comment button: without TEXT the prompt opens, with it the comment goes as the
#   prompt's Enter sends it; error when the tab takes no comments
c_mdtab_comment:
    PROLOGUE
    call ai_set
    call rest_text
    mov rdi, rax
    mov rsi, rdx
    call mdtab_comment
    test eax, eax
    js 8f
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# agent-card-uncomment N: comment N (from 1) of the open conversation's card goes, as a click on its ×
c_agent_card_uncomment:
    PROLOGUE
    call ai_set
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test edx, edx
    jz 8f
    mov rbx, rax
    test rbx, rbx
    jz 8f
    call agents_open_driven
    mov rdi, rax
    call agentcard_of
    test rax, rax
    jz 8f
    mov rdi, rax
    lea rsi, [rbx - 1]
    call agentcard_uncomment
    test eax, eax
    jz 8f
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

.section .rodata
.Lc_print_mdtab: .asciz "print-mdtab"
.Lc_mdtab_select: .asciz "mdtab-select"
.Lc_mdtab_comment: .asciz "mdtab-comment"
.Lc_agent_card_uncomment: .asciz "agent-card-uncomment"

.section .rodata
.Lc_print_agent_row: .asciz "print-agent-row"
.Lc_print_agent_card: .asciz "print-agent-card"
.Lc_print_agent_card_fit: .asciz "print-agent-card-fit"
.Lc_agent_card_text: .asciz "agent-card-text"
.Lc_agent_focus: .asciz "agent-focus"
.Lw_card_field: .asciz "field"
.Lw_card_edit: .asciz "edit"
.Lw_card_fold: .asciz "fold"
.Lw_card_details: .asciz "details"
.Lw_card_dest: .asciz "dest"
.Lw_card_submit: .asciz "submit"
.Lw_card_close: .asciz "close"
.Lw_card_link: .asciz "link"
.Lw_card_other: .asciz "other"
.Lw_focus_editor: .asciz "editor"
.Lw_focus_panel: .asciz "panel"
.Lw_focus_box: .asciz "box"
.Lt_card: .asciz "card"
.Lt_keyed: .asciz "keyed"
.Lt_advance: .asciz "advance"
.Lc_print_agent_cfg: .asciz "print-agent-cfg"
.Lc_agent_models: .asciz "agent-models"
.Lc_agent_cfg_set: .asciz "agent-cfg-set"
.Lc_agent_menu: .asciz "agent-menu"
.Lc_agent_menu_pick: .asciz "agent-menu-pick"
.Lc_print_agent_menu: .asciz "print-agent-menu"
.Lc_print_agent_bands: .asciz "print-agent-bands"
.Lc_agent_test_band: .asciz "agent-test-band"
.Lc_agent_modes: .asciz "agent-modes"
.Lc_agent_mode: .asciz "agent-mode"
.Lc_print_agents_foot: .asciz "print-agents-foot"
.Lc_agent_model: .asciz "agent-model"
.Lc_agent_effort: .asciz "agent-effort"
.Lc_agent_ultra: .asciz "agent-ultra"
.Lc_agent_thinking: .asciz "agent-thinking"
.Lw_on: .asciz "on"
.Lw_off: .asciz "off"
.Lb_error: .asciz "error"
.Lb_settings: .asciz "settings"
.Lb_auth: .asciz "auth"
.Lb_rate: .asciz "rate"
.Lb_notice: .asciz "notice"
.Lf_model: .asciz "model"
.Lf_effort: .asciz "effort"
.Lf_dest: .asciz "dest"
.Lf_newmode: .asciz "newmode"
.Lf_ultra: .asciz "ultra"
.Lf_think: .asciz "think"
.Lc_print_agents_metrics: .asciz "print-agents-metrics"
.Lc_print_agents_box: .asciz "print-agents-box"
.Lc_print_agent_placeholder: .asciz "print-agent-placeholder"
.Lc_print_agent_composer: .asciz "print-agent-composer"
.Lc_print_sh_quote: .asciz "print-sh-quote"
.Lc_agent_test_append: .asciz "agent-test-append"
.Lc_print_agent_thread: .asciz "print-agent-thread"
.Lc_agent_test_row: .asciz "agent-test-row"
.Lc_agent_test_view: .asciz "agent-test-view"
.Lc_print_agent_error: .asciz "print-agent-error"
.Lc_agent_error_click: .asciz "agent-error-click"
.Lc_print_agent_look: .asciz "print-agent-look"
.Lo_failed: .asciz "failed"
.Lo_open: .asciz "open"
.Lc_print_agent_spinner: .asciz "print-agent-spinner"
.Lc_agent_spin_tick: .asciz "agent-spin-tick"
.Lk_thinking: .asciz "thinking"
.Lk_meta: .asciz "meta"
.Lk_compact: .asciz "compact"
.Lk_unknown: .asciz "unknown"
.Lk_user: .asciz "user"
.Lk_agent: .asciz "agent"
.Lo_ms: .asciz "ms"
.Lo_live: .asciz "live"
.Lo_t: .asciz "t"
.Lo_notice: .asciz "notice"
.Lo_echo: .asciz "echo"
.Lo_n: .asciz "n"
.Lo_manual: .asciz "manual"
.Lempty_str: .asciz ""
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
.Lt_queue: .asciz "queue"
.Lt_cache: .asciz "cache"
.Lw_every: .asciz "every"
.Lc_print_tools: .asciz "print-tools"
.Lc_print_holder: .asciz "print-holder"
.Lr_chat_off: .asciz "Chat with Claude Code is off (Settings > Claude Code)."
.Lr_no_box: .asciz "No open conversation takes prompts."

.Lw_holder: .asciz "holder="
.Lh_none: .asciz "none"
.Lh_other: .asciz "other"
.Lh_unknown: .asciz "unknown"
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
    # the thread's engine and rows (agents.s, agentrows.s: phase 3)
    .quad .Lc_print_agent_thread, c_print_agent_thread, .Lc_agent_test_row, c_agent_test_row
    .quad .Lc_agent_test_view, c_agent_test_view
    .quad .Lc_print_agent_error, c_print_agent_error, .Lc_agent_error_click, c_agent_error_click   # task 8
    .quad .Lc_print_agent_look, c_print_agent_look
    .quad .Lc_print_agent_spinner, c_print_agent_spinner, .Lc_agent_spin_tick, c_agent_spin_tick   # task 5
    .quad .Lc_print_agent_rows, c_print_agent_rows, .Lc_print_agent_rows_fit, c_print_agent_rows_fit
    .quad .Lc_agent_test_tool, c_agent_test_tool, .Lc_agent_row_click, c_agent_row_click
    .quad .Lc_agent_test_truncate, c_agent_test_truncate
    .quad .Lc_print_agent_folds, c_print_agent_folds, .Lc_print_agent_folds_fit, c_print_agent_folds_fit   # task 9
    .quad .Lc_agent_fold_click, c_agent_fold_click
    .quad .Lc_print_agents_metrics, c_print_agents_metrics, .Lc_print_agents_box, c_print_agents_box
    .quad .Lc_print_agent_placeholder, c_print_agent_placeholder, .Lc_print_sh_quote, c_print_sh_quote
    .quad .Lc_print_holder, c_print_holder
    .quad .Lc_print_agent_cfg, c_print_agent_cfg, .Lc_agent_models, c_agent_models
    .quad .Lc_agent_cfg_set, c_agent_cfg_set
    # the command menu and the bands (agentpop.s, agentfoot.s)
    .quad .Lc_agent_menu, c_agent_menu, .Lc_agent_menu_pick, c_agent_menu_pick
    .quad .Lc_print_agent_menu, c_print_agent_menu, .Lc_print_agent_bands, c_print_agent_bands
    .quad .Lc_agent_test_band, c_agent_test_band
    # the footer and the permission modes (agentfoot.s)
    .quad .Lc_agent_modes, c_agent_modes, .Lc_agent_mode, c_agent_mode
    .quad .Lc_print_agents_foot, c_print_agents_foot
    # the model, effort, Ultracode and thinking (task 6)
    .quad .Lc_agent_model, c_agent_model, .Lc_agent_effort, c_agent_effort
    .quad .Lc_agent_ultra, c_agent_ultra, .Lc_agent_thinking, c_agent_thinking
    # the composer (agentcompose.s)
    .quad .Lc_print_agent_composer, c_print_agent_composer
    # the rich cards (agentcard.s)
    .quad .Lc_print_agent_card, c_print_agent_card, .Lc_print_agent_card_fit, c_print_agent_card_fit
    .quad .Lc_agent_card_text, c_agent_card_text, .Lc_agent_focus, c_agent_focus
    # plan review (mdtab.s, agentcard.s)
    .quad .Lc_print_mdtab, c_print_mdtab, .Lc_mdtab_select, c_mdtab_select
    .quad .Lc_mdtab_comment, c_mdtab_comment, .Lc_agent_card_uncomment, c_agent_card_uncomment
    # phase 4 tasks 11 and 12: proposed changes (agentoffer.s, review.s)
    .quad .Lc_print_agent_offer, c_print_agent_offer
    .quad 0, 0
card_words: .quad .Lw_card_fold, .Lw_card_details, .Lw_card_dest
    .quad .Lw_card_submit, .Lw_card_close                          # the question card's
    .quad .Lw_card_link                                            # the dialog cards'
    .quad .Lw_card_review           # phase 4 task 11: "Review the change"
focus_words:                    # agent-focus's words and their focus
    .quad .Lw_focus_editor
    .long FOCUS_EDITOR, 0
    .quad .Lw_focus_panel
    .long FOCUS_AGENTS, 0
    .quad .Lw_focus_box
    .long FOCUS_AGENT_INPUT, 0
cfg_fields:                     # agent-cfg-set's words: the word, the AGF_*, whether it is an int
    .quad .Lf_model
    .long AGF_MODEL, 0
    .quad .Lf_effort
    .long AGF_EFFORT, 0
    .quad .Lf_dest
    .long AGF_DEST, 0
    .quad .Lf_newmode
    .long AGF_NEWMODE, 0
    .quad .Lf_ultra
    .long AGF_ULTRA, 1
    .quad .Lf_think
    .long AGF_THINK, 1
    .quad 0, 0
holder_names: .quad .Lh_none, .Lh_other, .Lh_unknown
row_kinds: .quad .Lk_thinking, .Lk_meta, .Lk_compact, .Lk_unknown, .Lk_user, .Lk_agent, 0
row_roles: .long R_THINK, R_META, R_COMPACT, R_UNKNOWN, R_USER, R_ASSIST
row_opts: .quad .Lo_ms, .Lo_live, .Lo_t, .Lo_notice, .Lo_echo, .Lo_n, .Lo_manual, .Lo_failed, .Lo_open, 0
row_flags: .long 0, AMF_LIVE, 0, AMF_NOTICE, AMF_ECHO, 0, AMF_MANUAL, AMF_FAILED, AMF_OPEN
band_words: .quad .Lb_error, .Lb_settings, .Lb_auth, .Lb_rate, .Lb_notice
live_states: .quad .Ls_off, .Ls_starting, .Ls_ready, .Ls_working, .Ls_waiting, .Ls_held, .Ls_failed
timings: .quad .Lt_idle, g_drv_idle_ms, .Lt_term, g_conn_term_ms, .Lt_kill, g_conn_kill_ms
    .quad .Lt_eof, g_conn_eof_ms, .Lt_hold, g_drv_hold_ms, .Lt_guard, g_conn_max
    .quad .Lt_queue, g_conn_queue_max, .Lt_cache, g_cache_ttl_ms
    .quad .Lt_card, g_card_lock_ms, .Lt_keyed, g_card_keyed_ms     # the rich cards (agentcard.s)
    .quad .Lt_advance, g_card_advance_ms                            # the question card's move on
    .quad .Lt_settings, g_settings_wait_ms      # the prompts' wait for get_settings (claude_session.s)
    .quad .Lt_spin, g_spin_ms                   # the spinner's tick, 0 held (agentspin.s)
    .quad 0, 0
.Lt_settings: .asciz "settings"
.Lt_spin: .asciz "spin"
