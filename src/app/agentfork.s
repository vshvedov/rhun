# Phase 6 (claude-chat-p6b): the generic part of forking a conversation from one of its prompts, rewinding, and a
# turn cut off by quitting. It knows no agent: what a driver with DRVC_REWIND does (which entry a fork keeps,
# checkpoints, the export, a cut turn going on after a restart) is its own, reached through DRV_action with the
# acts ACT_REWIND .. ACT_OPENED (rhun.inc's p6b block).
#
#   agent_fork_at(AS* src, nrows, text ptr, len) -> rax the new conversation's live record, or 0: a new
#     conversation of src's kind titled "TITLE (fork)" holding src's first nrows rows, opened with text in its box,
#     a new one that never got a prompt (ALF_NEW | ALF_DRAFT, its own id); the driver makes it a fork of src
#   agfork_menu(items*, AS*, row) -> rax past the items it added: a prompt row's context menu entries (agentsel.s)
#   agfork_box_escape()                 Escape left an empty prompt box (the first of two)
#   agfork_panel_key(keysym, mods) -> eax 1 taken: a second Escape within 800 ms opens Rewind (agents_key)
#   agfork_opened(AS*)                  a conversation opened (agents.s open_session)
#   agfork_quit(lives VEC*)             rhun quits or the project changes (agent_drv_shutdown): the turns that run
#                                       are cut off
.include "rhun.inc"

.equ ESC_MS, 800                # Escape twice on an empty box within this: the Rewind picker (Ki=800 @5813120)

.bss
.p2align 3
tsb: .zero SB_SIZE              # the fork's title
fm_as: .quad 0                  # the context menu's conversation and prompt row
fm_row: .quad 0
esc_at: .quad 0                 # time_ms of an Escape that left an empty box, 0 none
esc_as: .quad 0                 #   the conversation it was on
fm_items: .zero 16 * 4          # agent-msg-action's look at the menu's entries

.text

# FN agent_fork_at(AS* src, nrows, text ptr, len) -> rax AL* or 0. Locals: [rsp] the new id (40 bytes), [rsp + 40]
#   the new AS
FN agent_fork_at
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    lea rdi, [rip + tsb]        # "TITLE (fork)", as the extension names a fork (forkSession @1325994)
    call sb_clear
    mov rsi, [rbx + AS_title]
    test rsi, rsi
    jz 1f
    cmp byte ptr [rsi], 0
    jne 2f
1:  lea rsi, [rip + .Lforked]
2:  lea rdi, [rip + tsb]
    call sb_push_cstr
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Lfork_suffix]
    call sb_push_cstr
    lea rdi, [rip + tsb]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rsp]
    call agent_uuid
    mov edi, [rbx + AS_kind]
    mov rsi, [rbx + AS_cwd]
    test rsi, rsi
    jnz 3f
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 8f
3:  mov rdx, [rip + tsb + SB_ptr]
    lea rcx, [rsp]
    call agent_new_as
    test rax, rax
    jz 8f
    mov r15, rax
    mov rdi, r15                # what the fork holds of its source: the rows before the prompt
    mov rsi, rbx
    mov rdx, r12
    call agents_copy_rows
    mov rdi, r15
    call agents_adopt
    mov rdi, r15
    call agents_open_as
    mov rdi, r15
    call agent_live
    test rax, rax
    jz 8f
    mov [rsp + 40], rax
    or dword ptr [rax + AL_flags], ALF_NEW | ALF_DRAFT
    lea rdi, [rax + AL_sid]
    lea rsi, [rsp]
    call cstr_copy
    test r14, r14               # the prompt in its box (the box is the fork's now)
    jz 4f
    mov rdi, r15
    mov rsi, r13
    mov rdx, r14
    call agentext_restore
4:  mov dword ptr [rip + g_dirty], 1
    mov rax, [rsp + 40]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# fork_driver(AS*) -> rax its driver when it forks and rewinds (DRVC_REWIND), else 0
fork_driver:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    test rbx, rbx
    jz 9f
    cmp dword ptr [rbx + AS_kind], AS_KIND_EXT
    je 8f
    call agent_drv_of
    test rax, rax
    jz 9f
    test dword ptr [rax + DRV_caps], DRVC_REWIND
    jnz 9f
8:  xor eax, eax
9:  EPILOGUE

# FN agfork_menu(items*, AS*, row) -> rax past the entries added: on a prompt of the user's (not a slash command's
#   echo, not one waiting to start) of a conversation whose driver forks: "Fork conversation from here", "Rewind
#   code to here", "Fork conversation and rewind code" (3.5's popup, IRe @5636966), each {label, fn}
FN agfork_menu
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    call fork_driver
    test rax, rax
    jz 9f
    test r13, r13
    js 9f
    cmp r13, [r12 + AS_msgs + VEC_len]
    jae 9f
    imul rax, r13, AM_SIZE
    add rax, [r12 + AS_msgs + VEC_ptr]
    cmp dword ptr [rax + AM_role], R_USER
    jne 9f
    test dword ptr [rax + AM_flags], AMF_ECHO | AMF_QUEUED
    jnz 9f
    mov [rip + fm_as], r12
    mov [rip + fm_row], r13
    lea rax, [rip + .Lm_fork]
    mov [rbx], rax
    lea rax, [rip + m_fork]
    mov [rbx + 8], rax
    lea rax, [rip + .Lm_rewind]
    mov [rbx + 16], rax
    lea rax, [rip + m_rewind]
    mov [rbx + 24], rax
    lea rax, [rip + .Lm_both]
    mov [rbx + 32], rax
    lea rax, [rip + m_both]
    mov [rbx + 40], rax
    add rbx, 48
9:  mov rax, rbx
    EPILOGUE

# m_fork(), m_rewind(), m_both(): the menu's entries: the driver's ACT_MSGACT for the row
m_fork:
    xor edi, edi
    jmp msg_act
m_rewind:
    mov edi, MSG_REWIND
    jmp msg_act
m_both:
    mov edi, MSG_BOTH
msg_act:
    PROLOGUE
    mov r12d, edi
    call agents_viewed          # still the conversation it was opened on
    mov rbx, rax
    test rax, rax
    jz 9f
    cmp rax, [rip + fm_as]
    jne 9f
    mov rdi, rbx
    mov esi, [rbx + AS_kind]
    mov edx, ACT_MSGACT
    mov rcx, [rip + fm_row]
    mov r8d, r12d
    call agentpop_run
9:  EPILOGUE

# FN agfork_box_escape(): Escape leaves the prompt box: when the box is empty and belongs to a conversation whose
#   driver rewinds, the next Escape within ESC_MS opens Rewind (agfork_panel_key)
FN agfork_box_escape
    PROLOGUE
    mov qword ptr [rip + esc_at], 0
    call agents_open_driven
    mov rbx, rax
    mov rdi, rax
    call fork_driver
    test rax, rax
    jz 9f
    call agentext_box
    mov rdi, rax
    call tf_text
    test rdx, rdx
    jnz 9f
    mov [rip + esc_as], rbx
    call time_ms
    mov [rip + esc_at], rax
9:  EPILOGUE

# FN agfork_panel_key(keysym, mods) -> eax 1 when it opened Rewind: Escape (no modifier) within ESC_MS of the one
#   that left the empty box, the same conversation still open; any other Escape forgets the first
FN agfork_panel_key
    PROLOGUE
    xor ebx, ebx
    cmp edi, KEY_ESCAPE
    jne 9f
    mov r12, [rip + esc_at]
    mov qword ptr [rip + esc_at], 0
    test r12, r12
    jz 9f
    test esi, MOD_CTRL | MOD_ALT | MOD_SUPER | MOD_SHIFT
    jnz 9f
    call time_ms
    sub rax, r12
    cmp rax, ESC_MS
    ja 9f
    call agents_open_driven
    test rax, rax
    jz 9f
    cmp rax, [rip + esc_as]
    jne 9f
    mov rdi, rax
    mov esi, [rax + AS_kind]
    mov edx, ACT_REWIND
    xor ecx, ecx
    xor r8d, r8d
    call agentpop_run
    mov ebx, 1
9:  mov eax, ebx
    EPILOGUE

# FN agfork_opened(AS*): a conversation opened: its driver hears of it (ACT_OPENED, no live record needed: the
#   AS in the act's pointer), so a turn cut off by quitting can go on
FN agfork_opened
    PROLOGUE
    mov rbx, rdi
    call fork_driver
    test rax, rax
    jz 9f
    xor edi, edi
    mov esi, ACT_OPENED
    mov rdx, rbx
    xor ecx, ecx
    call [rax + DRV_action]
9:  EPILOGUE

# FN agfork_quit(lives VEC* of AL*): every conversation whose turn runs (WORKING, WAITING) is cut off: its driver
#   hears of it (ACT_CUT) before its program is ended
FN agfork_quit
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [r12 + VEC_len]
    jae 9f
    mov rax, [r12 + VEC_ptr]
    mov r13, [rax + rbx*8]
    inc rbx
    mov eax, [r13 + AL_state]
    cmp eax, ALS_WORKING
    je 2f
    cmp eax, ALS_WAITING
    jne 1b
2:  mov rax, [r13 + AL_drv]
    test dword ptr [rax + DRV_caps], DRVC_REWIND
    jz 1b
    mov rdi, r13
    mov esi, ACT_CUT
    xor edx, edx
    xor ecx, ecx
    call [rax + DRV_action]
    jmp 1b
9:  EPILOGUE

# FN agfork_c_msg(out, rest, len): agent-msg-action ROW fork|rewind|both: the prompt row ROW (from 0, as
#   print-agent-rows) of the open conversation, as its context menu's entry; error when it has none
FN agfork_c_msg
    PROLOGUE
    mov rbx, rsi
    mov r12, rdx
    call agents_open_driven
    test rax, rax
    jz 8f
    mov r13, rax
1:  test r12, r12               # the row
    jz 8f
    cmp byte ptr [rbx], ' '
    ja 2f
    inc rbx
    dec r12
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r12
    call parse_u64
    test rdx, rdx
    jz 8f
    mov r14, rax
    add rbx, rdx
    sub r12, rdx
3:  test r12, r12
    jz 8f
    cmp byte ptr [rbx], ' '
    ja 4f
    inc rbx
    dec r12
    jmp 3b
4:  xor r15d, r15d              # the entry
    lea rcx, [rip + msg_words]
5:  mov rdx, [rcx + r15*8]
    test rdx, rdx
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 6f
    inc r15
    lea rcx, [rip + msg_words]
    jmp 5b
6:  lea rdi, [rip + fm_items]   # only a row its menu would offer the entry on
    mov rsi, r13
    mov rdx, r14
    call agfork_menu
    lea rcx, [rip + fm_items]
    cmp rax, rcx
    je 8f
    mov edi, r15d
    call msg_act
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

.section .rodata
.p2align 3
msg_words: .quad .Lw_fork, .Lw_rewind, .Lw_both, 0
.globl agfork_n_msg
agfork_n_msg: .asciz "agent-msg-action"
.Lw_fork: .asciz "fork"
.Lw_rewind: .asciz "rewind"
.Lw_both: .asciz "both"
.Lforked: .asciz "Forked session"
.Lfork_suffix: .asciz " (fork)"
.Lm_fork: .asciz "Fork conversation from here"
.Lm_rewind: .asciz "Rewind code to here"
.Lm_both: .asciz "Fork conversation and rewind code"
