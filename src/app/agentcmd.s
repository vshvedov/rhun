# The extension's commands as rhun's (design 10, ext-host-ide.md 3; phase 8). Generic: a command acts on the
# conversation the agents panel shows, or starts one of the first agent rhun can drive (agent_drv_for_kind);
# nothing here names an agent. keys.s lists them; the others of the extension are mapped in docs/guide.md.
#
#   cmd_agents_blur               Agents: Return to the Editor: the editor has the keys again
#   cmd_agents_sign_in, cmd_agents_sign_out, cmd_agents_install_plugin   the driver's program in rhun's
#                                 terminal prompt (DRV_terminal 1, 2, 3), for the shown conversation's profile
#   cmd_agents_mark_unread        Agents: Mark Conversation as Unread
#   cmd_agents_rename             Agents: Rename Conversation: the chat header's title is the rename field
#   cmd_agents_add_to_group       Agents: Add Conversation to Group: a menu of the groups and New group
#   cmd_agents_show_logs          Agents: Show Logs: the log of the programs rhun drives (starts, states, why one
#                                 failed) in a tab
#   aglog_state(AL*, ALS_*)       agent_state_set's: a line of the log (at most LOG_MAX bytes kept)
#   ck_claude_focus, ck_claude_use_terminal   when-clause keys: claudeFocus (the panel or its box has the keys),
#                                 claudeUseTerminal (agentsInputFocus is agentctx.s's)
#   agcmd_print_log(out, rest, len)   print-agents-log
#   agcmd_alias(label, len, query, qlen) -> eax score, -1 none   the palette's: an "Agents: X" command found as
#                                 "NAME: X" for each available driver's DRV_name ("Claude Code: Open in New Tab",
#                                 the extension's titles), scored by palette.s's fuzzy
# (New Conversation, Open in Side Panel are agenttab.s's; Insert @-Mention and Add to Chat agentctx.s's)
.include "rhun.inc"

.equ LOG_MAX, 65536             # the log's bytes kept (the older half goes past it)

.bss
.p2align 3
lsb: .zero SB_SIZE              # the log
wsb: .zero SB_SIZE              # a line of it; the log's tab text
asb: .zero SB_SIZE              # agcmd_alias's "NAME: X"

.text

# default_kind() -> eax the first built-in kind whose driver is available, or 0
default_kind:
    PROLOGUE
    mov ebx, 1
1:  cmp ebx, 4
    ja 8f
    mov edi, ebx
    call agent_drv_for_kind
    test rax, rax
    jnz 2f
    inc ebx
    jmp 1b
2:  mov eax, ebx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agcmd_alias(label, len, query, qlen) -> eax the best fuzzy score of "NAME: X" for an "Agents: X" label and
#   each available driver's name, -1 none (another label, no driver, no match)
FN agcmd_alias
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov dword ptr [rsp], -1
    lea rdx, [rip + .La_prefix]
    mov ecx, 8                  # "Agents: "
    call str_starts
    test eax, eax
    jz 9f
    mov ebx, 1
1:  cmp ebx, 4
    ja 9f
    mov edi, ebx
    inc ebx
    call agent_drv_for_kind
    test rax, rax
    jz 1b
    mov rsi, [rax + DRV_name]
    test rsi, rsi
    jz 1b
    lea rdi, [rip + asb]
    mov [rsp + 8], rsi
    call sb_clear
    lea rdi, [rip + asb]
    mov rsi, [rsp + 8]
    call sb_push_cstr
    lea rdi, [rip + asb]
    lea rsi, [rip + .La_colon]
    call sb_push_cstr
    lea rdi, [rip + asb]
    lea rsi, [r12 + 8]
    lea rdx, [r13 - 8]
    call sb_push
    mov rdi, [rip + asb + SB_ptr]
    mov rsi, [rip + asb + SB_len]
    mov rdx, r14
    mov rcx, r15
    call fuzzy
    cmp eax, [rsp]
    jle 1b
    mov [rsp], eax
    jmp 1b
9:  mov eax, [rsp]
    EPILOGUE

# FN cmd_agents_blur()
FN cmd_agents_blur
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov dword ptr [rip + g_dirty], 1
    ret

# drv_terminal(what): DRV_terminal of the shown conversation's driver (its profile), else of the first agent
#   rhun can drive, for the configured profile (a record of its own, new, freed after)
drv_terminal:
    PROLOGUE
    mov r12d, edi
    call agents_open_driven
    test rax, rax
    jz 2f
    mov rbx, rax
    mov rdi, rax
    call agent_drv_of
    test dword ptr [rax + DRV_caps], DRVC_SESSION
    jnz 2f
    mov r13, rax
    mov rdi, rbx
    call agent_live
    test rax, rax
    jz 2f
    mov rdi, rax
    mov esi, r12d
    call [r13 + DRV_terminal]
    EPILOGUE
2:  call default_kind
    test eax, eax
    jz 8f
    mov edi, eax
    call agent_drv_for_kind
    mov r13, rax
    mov edi, AL_SIZE
    call mem_alloc
    mov rbx, rax
    mov dword ptr [rbx + AL_flags], ALF_NEW
    mov [rbx + AL_drv], r13
    mov rdi, rbx
    mov esi, r12d
    call [r13 + DRV_terminal]
    mov rdi, rbx
    call mem_free
    EPILOGUE
8:  lea rdi, [rip + .Lt_noagent]
    call app_toast
    EPILOGUE

# FN cmd_agents_sign_in(), cmd_agents_sign_out(), cmd_agents_install_plugin()
FN cmd_agents_sign_in
    mov edi, 1
    jmp drv_terminal
FN cmd_agents_sign_out
    mov edi, 2
    jmp drv_terminal
FN cmd_agents_install_plugin
    mov edi, 3
    jmp drv_terminal

# ---- the shown conversation ----

# shown() -> rax the conversation the panel shows, or 0 (a toast says so)
shown:
    PROLOGUE
    call agents_viewed
    test rax, rax
    jnz 9f
    lea rdi, [rip + .Lt_noconv]
    call app_toast
    xor eax, eax
9:  EPILOGUE

# FN cmd_agents_mark_unread()
FN cmd_agents_mark_unread
    PROLOGUE
    call shown
    test rax, rax
    jz 9f
    mov rdi, rax
    mov esi, SF_UNREAD
    xor edx, edx
    call agst_mark
    call aglist_touch
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN cmd_agents_rename()
FN cmd_agents_rename
    PROLOGUE
    call shown
    test rax, rax
    jz 9f
    mov rbx, rax
    call cmd_focus_agents
    mov rdi, rbx
    call aglist_rename_header
9:  EPILOGUE

# FN cmd_agents_add_to_group()
FN cmd_agents_add_to_group
    PROLOGUE
    call shown
    test rax, rax
    jz 9f
    mov rdi, rax
    call aglist_group_menu
9:  EPILOGUE

# ---- the log ----

# FN aglog_state(AL*, state): "TIME KIND TITLE STATE[: REPORT]" a line
FN aglog_state
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [rip + wsb]
    call sb_clear
    call time_now
    imul rsi, rax, 1000
    lea rdi, [rip + wsb]
    call agtime_clock
    lea rdi, [rip + wsb]
    mov esi, ' '
    call sb_push_byte
    mov rdi, [rbx + AL_as]
    call agent_src_word
    lea rdi, [rip + wsb]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + wsb]
    mov esi, ' '
    call sb_push_byte
    mov rdi, [rbx + AL_as]
    call aglist_title
    lea rdi, [rip + wsb]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + wsb]
    mov esi, ' '
    call sb_push_byte
    lea rax, [rip + state_words]
    mov rsi, [rax + r12*8]
    lea rdi, [rip + wsb]
    call sb_push_cstr
    cmp r12d, ALS_FAILED
    jne 1f
    cmp qword ptr [rbx + AL_report + SB_len], 0
    je 1f
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Lcolon]
    call sb_push_cstr
    lea rdi, [rip + wsb]
    mov rsi, [rbx + AL_report + SB_ptr]
    mov rdx, [rbx + AL_report + SB_len]
    call sb_push
1:  lea rdi, [rip + wsb]
    mov esi, 10
    call sb_push_byte
    mov rax, [rip + lsb + SB_len]   # past the cap: the older half goes, from a line's start
    add rax, [rip + wsb + SB_len]
    cmp rax, LOG_MAX
    jbe 3f
    mov rcx, [rip + lsb + SB_len]
    shr rcx, 1
    mov rdx, [rip + lsb + SB_ptr]
2:  cmp rcx, [rip + lsb + SB_len]
    jae 21f
    cmp byte ptr [rdx + rcx], 10
    je 21f
    inc rcx
    jmp 2b
21: inc rcx
    cmp rcx, [rip + lsb + SB_len]
    jbe 22f
    mov rcx, [rip + lsb + SB_len]
22: mov rsi, rdx
    add rsi, rcx
    mov rdi, rdx
    mov rax, [rip + lsb + SB_len]
    sub rax, rcx
    mov [rip + lsb + SB_len], rax
    mov rdx, rax
    call memmove
3:  lea rdi, [rip + lsb]
    mov rsi, [rip + wsb + SB_ptr]
    mov rdx, [rip + wsb + SB_len]
    call sb_push
    EPILOGUE

# FN cmd_agents_show_logs(): the log in a tab, as text in a code block
FN cmd_agents_show_logs
    PROLOGUE
    lea rdi, [rip + wsb]
    call sb_clear
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Llog_head]
    call sb_push_cstr
    cmp qword ptr [rip + lsb + SB_len], 0
    jne 1f
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Llog_empty]
    call sb_push_cstr
    jmp 2f
1:  lea rdi, [rip + wsb]
    lea rsi, [rip + .Lfence]
    call sb_push_cstr
    lea rdi, [rip + wsb]
    mov rsi, [rip + lsb + SB_ptr]
    mov rdx, [rip + lsb + SB_len]
    call sb_push
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Lfence_end]
    call sb_push_cstr
2:  lea rdi, [rip + .Llog_title]
    mov rsi, [rip + wsb + SB_ptr]
    mov rdx, [rip + wsb + SB_len]
    xor ecx, ecx
    xor r8d, r8d
    call mdtab_open
    EPILOGUE

# FN agcmd_print_log(out, rest, len): print-agents-log: the log's lines
FN agcmd_print_log
    PROLOGUE
    mov rsi, [rip + lsb + SB_ptr]
    mov rdx, [rip + lsb + SB_len]
    test rdx, rdx
    jz 9f
    call sb_push
9:  xor eax, eax
    EPILOGUE

# FN ck_claude_focus(): the panel or its box has the keys
FN ck_claude_focus
    xor eax, eax
    mov ecx, [rip + g_focus]
    cmp ecx, FOCUS_AGENT_INPUT
    sete al
    cmp ecx, FOCUS_AGENTS
    sete cl
    or al, cl
    jmp ck_word

# FN ck_claude_use_terminal(): [claude] use_terminal
FN ck_claude_use_terminal
    xor eax, eax
    cmp dword ptr [rip + cfg_claude_use_terminal], 0
    setne al
    jmp ck_word

ck_word:
    test eax, eax
    jz 1f
    lea rax, [rip + .Lw_true]
    mov edx, 4
    ret
1:  lea rax, [rip + .Lw_false]
    mov edx, 5
    ret

.section .rodata
.La_prefix: .asciz "Agents: "
.La_colon: .asciz ": "
.p2align 3
state_words: .quad .Ls_off, .Ls_starting, .Ls_ready, .Ls_working, .Ls_waiting, .Ls_held, .Ls_failed
.Ls_off: .asciz "off"
.Ls_starting: .asciz "starting"
.Ls_ready: .asciz "ready"
.Ls_working: .asciz "working"
.Ls_waiting: .asciz "waiting"
.Ls_held: .asciz "held"
.Ls_failed: .asciz "failed"
.Lcolon: .asciz ": "
.Lw_true: .asciz "true"
.Lw_false: .asciz "false"
.Lt_noagent: .asciz "No agent can start a conversation here: is its chat switched on in Settings?"
.Lt_noconv: .asciz "Open a conversation in the agents panel first."
.Llog_title: .asciz "Agents Log"
.Llog_head: .asciz "# Agents Log\n\nThe programs rhun drives for the agents panel: when each started, its states, and why one failed.\n\n"
.Llog_empty: .asciz "Nothing yet.\n"
.Lfence: .asciz "```text\n"
.Lfence_end: .asciz "```\n"
