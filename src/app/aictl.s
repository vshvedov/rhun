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

# agent-card N | fold | details | dest | submit | close: option N (from 1) of the open session's card (a
#   rich card's button N once its lock is over, agentcard.s; the question card's row N of the question it
#   shows); a rich card's fold button, its Details, a click on its place; the question card's Submit
#   answers and its ×
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

# agent-timing [idle=MS] [term=MS] [kill=MS] [eof=MS] [hold=MS] [guard=N] [queue=BYTES] [cache=MS]
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
#   else -1
card_word:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp ebx, 5
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
    .quad 0, 0
card_words: .quad .Lw_card_fold, .Lw_card_details, .Lw_card_dest
    .quad .Lw_card_submit, .Lw_card_close                          # the question card's
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
band_words: .quad .Lb_error, .Lb_settings, .Lb_auth, .Lb_rate, .Lb_notice
live_states: .quad .Ls_off, .Ls_starting, .Ls_ready, .Ls_working, .Ls_waiting, .Ls_held, .Ls_failed
timings: .quad .Lt_idle, g_drv_idle_ms, .Lt_term, g_conn_term_ms, .Lt_kill, g_conn_kill_ms
    .quad .Lt_eof, g_conn_eof_ms, .Lt_hold, g_drv_hold_ms, .Lt_guard, g_conn_max
    .quad .Lt_queue, g_conn_queue_max, .Lt_cache, g_cache_ttl_ms
    .quad .Lt_card, g_card_lock_ms, .Lt_keyed, g_card_keyed_ms     # the rich cards (agentcard.s)
    .quad .Lt_advance, g_card_advance_ms                            # the question card's move on
    .quad 0, 0
