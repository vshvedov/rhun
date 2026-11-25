# The open conversation's header (phase 6, checklist 5.1, 5.2, 5.16, 5.22): Back to the list, the session's
# title as a button (a click renames it inline: Enter commits, Escape cancels, "Untitled session" when it has
# none), then "Session history" (the "Past conversations" dropdown of agentlist.s, hanging from it) and "New
# session" (a new conversation of the same agent, when rhun can drive it), and the live dot. A conversation
# in a linked worktree gets a band under it: "This session is in worktree NAME" with "Open worktree" (the
# worktree's folder in a new window). "Resume conversation" in the command menu and /resume open the same
# dropdown (agentpop_run's ACT_RESUME).
#
#   aghead_draw(AS*, x, y, w) -> eax the header's height (with the band), 0 when Back closed the conversation
#   aghead_history(AS*)          the dropdown, as the history button opens it (headless, /resume)
#   aghead_resume(AS* or 0, kind) the dropdown for "Resume conversation" and /resume (a draft: its kind's)
.include "rhun.inc"

.equ ID_AGH, 0x760000
.equ IDH_BACK, 0
.equ IDH_TITLE, 1
.equ IDH_HISTORY, 2
.equ IDH_NEW, 3
.equ IDH_WT, 4

.bss
.p2align 3
hist: .zero 16                  # the history button as drawn last (x, y, w, h)
wsb: .zero SB_SIZE

.section .rodata
.Luntitled: .asciz "Untitled session"
.Lt_title: .asciz "Rename session"
.Lt_history: .asciz "Session history"
.Lt_new: .asciz "New session"
.Lwt1: .asciz "This session is in worktree "
.Lwt_open: .asciz "Open worktree"
# the command menu's "Resume conversation" and /resume, /continue (claude_session.s's tables name them)
.globl aghead_m_resume, aghead_m_resume_d, aghead_n_resume, aghead_n_continue, aghead_d_resume
aghead_m_resume: .asciz "Resume conversation"
aghead_m_resume_d: .asciz "Continue a previous conversation"
aghead_n_resume: .asciz "resume"
aghead_n_continue: .asciz "continue"
aghead_d_resume: .asciz "Resume a previous conversation"
.globl aghead_a_focusview
aghead_a_focusview: .asciz "focusview"  # print-agent-cfg's word for ACT_FOCUSVIEW (agentcfg.s act_names)
.text

# FN aghead_draw(AS*, x, y, w) -> eax the header's height, 0 when Back closed the conversation
FN aghead_draw
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    PM r15d, MI_40
    PM r12d, MI_28
    mov eax, r15d               # the buttons' top
    sub eax, r12d
    sar eax, 1
    add eax, [rsp + 4]
    mov [rsp + 12], eax
    # Back (task 13: not in a conversation tab, which has no list)
    call agents_in_tab
    test eax, eax
    jnz 1f
    mov edi, ID_AGH + IDH_BACK
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rsp + 12]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_BACK
    call ag_icon_btn
    test eax, UB_CLICK
    jz 1f
    call agents_back
    xor eax, eax
    EPILOGUE
1:  # right to left: the live dot's room, New session, Session history
    mov eax, [rsp]
    add eax, [rsp + 8]
    sub eax, [rip + g_pmt + 4*MI_24]
    mov [rsp + 16], eax         # the buttons' right edge
    mov edi, [rbx + AS_kind]
    call agent_drv_for_kind
    test rax, rax
    jz 2f
    sub [rsp + 16], r12d
    mov edi, ID_AGH + IDH_NEW
    mov esi, [rsp + 16]
    mov edx, [rsp + 12]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_PLUS
    call ag_icon_btn
    mov r13d, eax
    mov edi, ID_AGH + IDH_NEW
    mov esi, [rsp + 16]
    mov edx, [rsp + 12]
    add edx, r12d
    mov ecx, r12d
    mov r8d, r13d
    lea r9, [rip + .Lt_new]
    call tip_note_text
    test r13d, UB_CLICK
    jz 2f
    mov edi, [rbx + AS_kind]    # a new conversation of this agent (agentext.s's draft)
    call agentext_new_kind
2:  sub [rsp + 16], r12d
    mov eax, [rsp + 16]
    mov [rip + hist], eax
    mov eax, [rsp + 12]
    mov [rip + hist + 4], eax
    mov [rip + hist + 8], r12d
    mov [rip + hist + 12], r12d
    mov edi, ID_AGH + IDH_HISTORY
    mov esi, [rsp + 16]
    mov edx, [rsp + 12]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_LIST
    call ag_icon_btn
    mov r13d, eax
    mov edi, ID_AGH + IDH_HISTORY
    mov esi, [rsp + 16]
    mov edx, [rsp + 12]
    add edx, r12d
    mov ecx, r12d
    mov r8d, r13d
    lea r9, [rip + .Lt_history]
    call tip_note_text
    test r13d, UB_CLICK
    jz 3f
    mov rdi, rbx
    call aghead_history
3:  # the title: a button, or the rename field
    call agents_in_tab          # (task 13: from the left edge in a tab, which has no Back)
    mov ecx, [rip + g_pmt + 4*MI_40]
    test eax, eax
    jz 31f
    mov ecx, [rip + g_pmt + 4*MI_8]
31: mov eax, [rsp]
    add eax, ecx
    mov [rsp + 20], eax         # its x
    mov ecx, [rsp + 16]
    sub ecx, eax
    sub ecx, [rip + g_pmt + 4*MI_4]
    mov [rsp + 24], ecx         # its width
    cmp ecx, [rip + g_pmt + 4*MI_16]
    jl 6f
    mov rdi, rbx
    call aglist_renaming
    test eax, eax
    jz 4f
    mov edi, [rsp + 20]
    mov esi, [rsp + 12]
    mov edx, [rsp + 24]
    mov ecx, r12d
    call aglist_rename_field
    jmp 6f
4:  mov edi, ID_AGH + IDH_TITLE
    mov esi, [rsp + 20]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 24]
    mov r8d, r12d
    call ui_btn
    mov r13d, eax
    test eax, UB_HOVER
    jz 41f
    mov edi, [rsp + 20]
    mov esi, [rsp + 12]
    mov edx, [rsp + 24]
    mov ecx, r12d
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
    mov edi, ID_AGH + IDH_TITLE
    mov esi, [rsp + 20]
    mov edx, [rsp + 12]
    add edx, r12d
    mov ecx, [rsp + 24]
    mov r8d, r13d
    lea r9, [rip + .Lt_title]
    call tip_note_text
41: mov rdi, rbx
    call aglist_title
    mov r8, rax
    mov r9, rdx
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 20]
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, [rsp + 4]
    mov ecx, r15d
    COLOR r10d, T_FG
    mov r11d, [rsp + 24]
    sub r11d, [rip + g_pmt + 4*MI_12]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    test r13d, UB_CLICK
    jz 6f
    mov rdi, rbx
    call aglist_rename_header
6:  # the live dot
    mov rdi, rbx
    call agents_session_live
    test eax, eax
    jz 7f
    PM ecx, MI_8
    mov edi, [rsp]
    add edi, [rsp + 8]
    sub edi, [rip + g_pmt + 4*MI_16]
    mov esi, r15d
    sub esi, ecx
    sar esi, 1
    add esi, [rsp + 4]
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_SUCCESS
    call gfx_round_rect
7:  mov edi, [rsp]              # its line
    mov esi, [rsp + 4]
    add esi, r15d
    dec esi
    mov edx, [rsp + 8]
    PM ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    mov eax, r15d
    cmp qword ptr [rbx + AS_worktree], 0
    je 9f
    mov rdi, rbx                # the worktree's band
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, r15d
    mov ecx, [rsp + 8]
    call wt_band
    add eax, r15d
9:  EPILOGUE

# wt_band(AS*, x, y, w) -> eax its height: "This session is in worktree NAME" and "Open worktree" (its folder in
#   a new window)
wt_band:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    PM eax, MI_32
    mov [rsp + 12], eax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, eax
    COLOR r8d, T_HOVER
    call gfx_fill
    lea rdi, [rip + .Lwt_open]  # the button's width
    call strlen
    mov rdx, rax
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lwt_open]
    call text_width
    add eax, [rip + g_pmt + 4*MI_16]
    mov r12d, eax
    xor r13d, r13d
    cmp qword ptr [rbx + AS_cwd], 0
    je 1f                       # no folder known: no button
    mov edi, ID_AGH + IDH_WT
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, r12d
    sub esi, [rip + g_pmt + 4*MI_8]
    mov [rsp + 16], esi
    mov edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, [rsp + 12]
    call ui_btn
    mov r13d, eax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 16]
    mov edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, [rsp + 12]
    lea r9, [rip + .Lwt_open]
    COLOR eax, T_ACCENT
    push rax
    push rax
    call ui_text_center
    add rsp, 16
1:  lea rdi, [rip + wsb]
    call sb_clear
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Lwt1]
    call sb_push_cstr
    lea rdi, [rip + wsb]
    mov rsi, [rbx + AS_worktree]
    call sb_push_cstr
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, [rip + wsb + SB_ptr]
    mov r9, [rip + wsb + SB_len]
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 8]
    sub r11d, r12d
    sub r11d, [rip + g_pmt + 4*MI_32]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    test r13d, UB_CLICK
    jz 9f
    mov rdi, [rbx + AS_cwd]
    call app_new_window
9:  mov eax, [rsp + 12]
    EPILOGUE

# FN aghead_history(AS*): the "Past conversations" dropdown of its agent's conversations, hanging from the
#   history button; open already, it closes
FN aghead_history
    PROLOGUE
    mov edi, [rdi + AS_kind]
    mov esi, [rip + hist]
    mov edx, [rip + hist + 4]
    mov ecx, [rip + hist + 8]
    mov r8d, [rip + hist + 12]
    call aglist_drop_open
    EPILOGUE

# FN aghead_resume(AS* or 0, kind): "Resume conversation", /resume: the dropdown (a draft's: of its kind's
#   conversations, hanging from where the history button was)
FN aghead_resume
    PROLOGUE
    test rdi, rdi
    jz 1f
    mov esi, [rdi + AS_kind]
1:  mov edi, esi
    mov esi, [rip + hist]
    mov edx, [rip + hist + 4]
    mov ecx, [rip + hist + 8]
    mov r8d, [rip + hist + 12]
    call aglist_drop_close      # (asked while it shows: it shows again)
    call aglist_drop_open
    EPILOGUE
