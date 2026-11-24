# The dialog shell's form rows (claude-chat-p7b): text fields, the choices of a group and a row of tabs, for
# the dialogs that change a program's configuration. agentdlg.s calls in through five hooks (row_h,
# draw_row, focusable, agentdlg_key, dump_row; agentdlg_field and agentdlg_paste for a field's text) and
# lends what it keeps (agentdlg_x_*). Generic: it knows no agent.
#
#   FIELD (rhun.inc DGK_FIELD): t1 its label above it, t2 its placeholder, t3 a line under it (DGF_ERROR: in
#     the error colour), DGR_val its TF (the dialog's own, so the text outlives a rebuild of the rows; the
#     dialog empties it); DGF_MULTI: four lines shown, Enter a new line; DGF_SECRET: bullets in place of
#     the text (drawn and dumped); DGF_SECRETV: lines of NAME=value or Name: value whose values the dump
#     hides. Keys: what the field takes (typing, the caret, a selection, Ctrl+A ...); Enter in a one-line
#     field is DGR_act (0: the focus moves on); Up and Down leave a one-line field, a field of lines once its
#     caret can go no further; Tab, Escape, Page Up and Page Down stay the shell's
#   OPTION: a choice of a group: a round mark (filled with DGF_ON), t1, t2 under it (wrapped); Enter, Space or
#     a click is DGR_act (the shell's)
#   TABS: t1 the labels joined by 0x1f (a tab would become a space in a row's text), DGR_val the one shown; Left and Right (round), Space and
#     Enter (the next) and a click on a tab are DGR_act with the tab's index as its arg
#
#   agentdlg2_row_h(DR*, tw) -> eax, agentdlg2_draw_row(DR*, y, x, w, focus) -> eax 1 when an act ran,
#   agentdlg2_key(entry, keysym, cp, mods) -> eax 1 taken, agentdlg2_field(entry) -> rax TF* or 0,
#   agentdlg2_paste(entry, ptr, len) -> eax 1 taken, agentdlg2_dump_row(sb, DR*)
.include "rhun.inc"

.equ ID_ROW, 0x20               # ID_AGDLG + : a row's controls (agentdlg.s's DID_ROW), a field's TF_id
.equ ID_ROWS, 0xe0
.equ ID_TAB, 0x200              # ID_AGDLG + : a tab (0x200..0x2ff)
.equ MULTI_LINES, 4             # a field of lines shows four
.equ TABS_MAX, 8
.equ BULLETS_MAX, 64

.bss
.p2align 3
xsb: .zero SB_SIZE              # scratch: a secret's bullets, a dump's value

.text

# rowp(entry) -> rax its row (DR*) when the entry is a row's, else 0
rowp:
    mov eax, edi
    shr eax, 24
    cmp eax, 2                  # agentdlg.s's FT_ROW
    jne 1f
    and edi, 0xffffff
    jmp agentdlg_x_row
1:  xor eax, eax
    ret

# small_lines(cstr or 0, w) -> eax its lines in the small face (0 for none)
small_lines:
    PROLOGUE
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rbx, rdi
    mov r12d, esi
    call strlen
    mov rdx, rax
    mov rdi, [rip + ag_fsmall]
    mov rsi, rbx
    mov ecx, r12d
    call agentdlg_x_lines
9:  EPILOGUE

# box_h(DR*) -> eax the field's box height
box_h:
    PROLOGUE
    mov rbx, rdi
    call agentdlg_x_field_h
    test dword ptr [rbx + DGR_flags], DGF_MULTI
    jz 9f
    PM ecx, MI_12
    sub eax, ecx
    imul eax, eax, MULTI_LINES
    add eax, ecx
9:  EPILOGUE

# radio_w() -> eax the room an option's mark takes before its text
radio_w:
    PM eax, MI_16
    add eax, [rip + g_pmt + 4*MI_8]
    ret

# FN agentdlg2_row_h(DR*, tw) -> eax its height
FN agentdlg2_row_h
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov eax, [rbx + DGR_kind]
    cmp eax, DGK_OPTION
    je .Lh_option
    cmp eax, DGK_TABS
    je .Lh_tabs
    xor r13d, r13d              # FIELD: the label, the box, the line under it
    mov rdi, [rbx + DGR_t1]
    mov esi, r12d
    call small_lines
    test eax, eax
    jz 1f
    mov rcx, [rip + ag_fsmall]
    imul eax, [rcx + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_4]
    add r13d, eax
1:  mov rdi, rbx
    call box_h
    add r13d, eax
    mov rdi, [rbx + DGR_t3]
    mov esi, r12d
    call small_lines
    test eax, eax
    jz 2f
    mov rcx, [rip + ag_fsmall]
    imul eax, [rcx + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_4]
    add r13d, eax
2:  lea eax, [r13 + 0]
    add eax, [rip + g_pmt + 4*MI_8]
    EPILOGUE
.Lh_option:
    call radio_w
    sub r12d, eax
    mov rdi, [rbx + DGR_t2]
    mov esi, r12d
    call small_lines
    mov rcx, [rip + ag_fsmall]
    imul eax, [rcx + FACE_lineh]
    mov rcx, [rip + ag_fui]
    add eax, [rcx + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_6]
    add eax, [rip + g_pmt + 4*MI_6]
    EPILOGUE
.Lh_tabs:
    mov rcx, [rip + ag_fui]
    mov eax, [rcx + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_12]
    add eax, [rip + g_pmt + 4*MI_6]
    EPILOGUE

# focused(focus index) -> eax 1 when that focusable has the focus and the panel the keys
focused:
    push rdi
    call agentdlg_x_focus
    pop rdi
    test ecx, ecx
    jz 1f
    cmp eax, edi
    jne 1f
    cmp edi, -1
    je 1f
    mov eax, 1
    ret
1:  xor eax, eax
    ret

# FN agentdlg2_draw_row(DR*, y, x, w, focus index) -> eax 1 when an act ran (the rows may be gone)
FN agentdlg2_draw_row
    PROLOGUE 64
    mov rbx, rdi
    mov [rsp], esi              # y
    mov [rsp + 4], edx          # x
    mov [rsp + 8], ecx          # w
    mov [rsp + 12], r8d         # focus index
    mov edi, r8d
    call focused
    mov [rsp + 16], eax
    mov eax, [rsp + 12]         # its control id
    cmp eax, ID_ROWS - 1
    jbe 1f
    mov eax, ID_ROWS - 1
1:  add eax, ID_AGDLG + ID_ROW
    mov [rsp + 20], eax
    mov eax, [rbx + DGR_kind]
    cmp eax, DGK_OPTION
    je .Ld_option
    cmp eax, DGK_TABS
    je .Ld_tabs
    mov rsi, [rbx + DGR_t1]     # FIELD: the label
    test rsi, rsi
    jz 2f
    mov rdi, rsi
    call strlen
    mov r9, rax
    COLOR eax, T_FG
    test dword ptr [rbx + DGR_flags], DGF_OFF
    jz 11f
    COLOR eax, T_MUTED
11: push rax
    push rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 16 + 4]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 16 + 8]
    mov r8, [rbx + DGR_t1]
    call agentdlg_x_wrap
    add rsp, 16
    mov rcx, [rip + ag_fsmall]
    imul eax, [rcx + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_4]
    add [rsp], eax
2:  mov rdi, rbx
    call box_h
    mov [rsp + 24], eax
    mov r12, [rbx + DGR_val]    # its TF
    test r12, r12
    jz 5f
    mov rax, [rip + ag_fui]
    mov [r12 + TF_face], rax
    mov eax, [rsp + 20]
    mov [r12 + TF_id], eax
    test dword ptr [rbx + DGR_flags], DGF_SECRET
    jnz 3f
    mov rax, [rbx + DGR_t2]
    push rax
    push rax
    mov rdi, r12
    mov esi, [rsp + 16 + 4]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 16 + 8]
    mov r8d, [rsp + 16 + 24]
    mov r9d, [rsp + 16 + 16]
    call ui_textarea
    add rsp, 16
    jmp 4f
3:  mov rdi, rbx                # a secret: bullets
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 24]
    mov r9d, [rsp + 16]
    call secret_box
4:  test eax, UB_PRESS
    jz 5f
    test dword ptr [rbx + DGR_flags], DGF_OFF
    jnz 5f
    mov edi, [rsp + 12]
    cmp edi, -1
    je 5f
    call agentdlg_x_set_focus
5:  mov eax, [rsp + 24]         # the line under it
    add [rsp], eax
    mov rsi, [rbx + DGR_t3]
    test rsi, rsi
    jz 8f
    mov rdi, rsi
    call strlen
    mov r9, rax
    COLOR eax, T_MUTED
    test dword ptr [rbx + DGR_flags], DGF_ERROR
    jz 51f
    COLOR eax, T_ERROR
51: push rax
    push rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 16 + 4]
    mov edx, [rsp + 16]
    add edx, [rip + g_pmt + 4*MI_4]
    mov ecx, [rsp + 16 + 8]
    mov r8, [rbx + DGR_t3]
    call agentdlg_x_wrap
    add rsp, 16
8:  xor eax, eax
    EPILOGUE
.Ld_option:
    mov rdi, rbx                # the row's button: the hover and the focus under it
    mov esi, [rsp + 8]
    call agentdlg2_row_h
    mov r8d, eax
    mov [rsp + 28], eax
    mov edi, [rsp + 20]
    mov esi, [rsp + 4]
    sub esi, [rip + g_pmt + 4*MI_4]
    mov edx, [rsp]
    mov ecx, [rsp + 8]
    add ecx, [rip + g_pmt + 4*MI_8]
    call ui_btn
    mov [rsp + 32], eax
    COLOR r9d, T_SELECTION
    cmp dword ptr [rsp + 16], 0
    jne 1f
    COLOR r9d, T_HOVER
    test dword ptr [rsp + 32], UB_HOVER
    jz 2f
1:  mov edi, [rsp + 4]
    sub edi, [rip + g_pmt + 4*MI_4]
    mov esi, [rsp]
    mov edx, [rsp + 8]
    add edx, [rip + g_pmt + 4*MI_8]
    mov ecx, [rsp + 28]
    PM r8d, MI_RADIUS
    call gfx_round_rect
2:  mov r13d, [rsp]             # the first line's top
    add r13d, [rip + g_pmt + 4*MI_6]
    PM r14d, MI_14              # the mark: a ring, a dot inside when chosen
    mov rax, [rip + ag_fui]
    mov r15d, [rax + FACE_lineh]
    sub r15d, r14d
    sar r15d, 1
    add r15d, r13d              # its top
    COLOR r9d, T_MUTED
    test dword ptr [rbx + DGR_flags], DGF_ON
    jz 21f
    COLOR r9d, T_ACCENT
21: mov edi, [rsp + 4]
    mov esi, r15d
    mov edx, r14d
    mov ecx, r14d
    mov r8d, r14d
    shr r8d, 1
    call gfx_round_rect
    PM ecx, MI_2                # its inside: the input colour, a dot when chosen
    mov edi, [rsp + 4]
    add edi, ecx
    lea esi, [r15 + rcx]
    mov edx, r14d
    sub edx, ecx
    sub edx, ecx
    mov ecx, edx
    mov r8d, edx
    shr r8d, 1
    COLOR r9d, T_INPUT
    call gfx_round_rect
    test dword ptr [rbx + DGR_flags], DGF_ON
    jz 3f
    PM ecx, MI_4
    mov edi, [rsp + 4]
    add edi, ecx
    lea esi, [r15 + rcx]
    mov edx, r14d
    sub edx, ecx
    sub edx, ecx
    mov ecx, edx
    mov r8d, edx
    shr r8d, 1
    COLOR r9d, T_ACCENT
    call gfx_round_rect
3:  call radio_w
    mov r14d, [rsp + 4]
    add r14d, eax               # the text's x
    mov r15d, [rsp + 8]
    sub r15d, eax               # its width
    mov rsi, [rbx + DGR_t1]
    test rsi, rsi
    jz 4f
    mov rdi, rsi
    call strlen
    mov r8, rax
    mov rdi, [rip + ag_fui]
    mov esi, r14d
    mov edx, r13d
    mov rcx, [rbx + DGR_t1]
    push r15
    COLOR r9d, T_FG
    test dword ptr [rbx + DGR_flags], DGF_OFF
    jz 31f
    COLOR r9d, T_MUTED
31: push r9
    call agentdlg_x_fit
    add rsp, 16
4:  mov rsi, [rbx + DGR_t2]
    test rsi, rsi
    jz 5f
    mov rdi, rsi
    call strlen
    mov r9, rax
    mov rax, [rip + ag_fui]
    add r13d, [rax + FACE_lineh]
    COLOR eax, T_MUTED
    push rax
    push rax
    mov rdi, [rip + ag_fsmall]
    mov esi, r14d
    mov edx, r13d
    mov ecx, r15d
    mov r8, [rbx + DGR_t2]
    call agentdlg_x_wrap
    add rsp, 16
5:  test dword ptr [rsp + 32], UB_CLICK
    jz 8b
    test dword ptr [rbx + DGR_flags], DGF_OFF
    jnz 8b
    mov edi, [rsp + 12]
    cmp edi, -1
    je 8b
    call agentdlg_x_set_focus
    mov edi, [rbx + DGR_act]
    test edi, edi
    jz 8b
    mov rsi, [rbx + DGR_arg]
    mov rdx, rbx
    call agentdlg_x_act
    mov eax, 1
    EPILOGUE
.Ld_tabs:
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_12]
    mov [rsp + 28], eax         # a tab's height
    cmp dword ptr [rsp + 16], 0 # the focus: a ring round the row
    je 1f
    mov edi, [rsp + 4]
    sub edi, [rip + g_pmt + 4*MI_2]
    mov esi, [rsp]
    mov edx, [rsp + 8]
    add edx, [rip + g_pmt + 4*MI_4]
    mov ecx, [rsp + 28]
    call agentdlg_x_ring
1:  mov edi, [rsp + 4]          # the line under the tabs
    mov esi, [rsp]
    add esi, [rsp + 28]
    sub esi, [rip + g_pmt + 4*MI_1]
    mov edx, [rsp + 8]
    PM ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    mov rdi, [rbx + DGR_t1]     # the tabs: each its share of the row at most
    call tab_count
    mov r12d, eax
    test eax, eax
    jz 8b
    mov eax, [rsp + 8]
    xor edx, edx
    div r12d
    mov [rsp + 36], eax         # a share
    mov r13d, [rsp + 4]         # x
    xor r14d, r14d              # the tab
    mov r15, [rbx + DGR_t1]     # its label
2:  cmp r14d, r12d
    jae 8b
    mov rdi, r15                # its label's length
    xor ecx, ecx
21: movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz 22f
    cmp eax, 31
    je 22f
    inc rcx
    jmp 21b
22: mov [rsp + 40], rcx
    mov rdi, [rip + ag_fui]
    mov rsi, r15
    mov rdx, rcx
    call text_width
    PM ecx, MI_12
    lea eax, [rax + rcx*2]
    cmp eax, [rsp + 36]
    jle 23f
    mov eax, [rsp + 36]
23: mov [rsp + 52], eax         # its width
    lea edi, [r14 + ID_AGDLG + ID_TAB]
    mov esi, r13d
    mov edx, [rsp]
    mov ecx, eax
    mov r8d, [rsp + 28]
    call ui_btn
    mov [rsp + 56], eax
    test eax, UB_HOVER
    jz 24f
    mov edi, r13d
    mov esi, [rsp]
    mov edx, [rsp + 52]
    mov ecx, [rsp + 28]
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
24: COLOR r9d, T_MUTED
    cmp r14, [rbx + DGR_val]
    jne 25f
    mov edi, r13d               # the one shown: underlined in the accent
    mov esi, [rsp]
    add esi, [rsp + 28]
    sub esi, [rip + g_pmt + 4*MI_2]
    mov edx, [rsp + 52]
    PM ecx, MI_2
    COLOR r8d, T_ACCENT
    call gfx_fill
    COLOR r9d, T_FG
25: mov eax, [rsp + 52]
    PM ecx, MI_12
    sub eax, ecx
    sub eax, ecx
    push rax
    push r9
    mov rdi, [rip + ag_fui]
    lea esi, [r13 + rcx]
    mov edx, [rsp + 16]
    PM ecx, MI_6
    add edx, ecx
    mov rcx, r15
    mov r8, [rsp + 16 + 40]
    call agentdlg_x_fit
    add rsp, 16
    test dword ptr [rsp + 56], UB_CLICK
    jz 26f
    mov edi, [rsp + 12]         # a click: the focus, the tab's act
    cmp edi, -1
    je 251f
    call agentdlg_x_set_focus
251:mov edi, [rbx + DGR_act]
    test edi, edi
    jz 26f
    mov esi, r14d
    mov rdx, rbx
    call agentdlg_x_act
    mov eax, 1
    EPILOGUE
26: add r13d, [rsp + 52]
    add r15, [rsp + 40]
    cmp byte ptr [r15], 31
    jne 27f
    inc r15
27: inc r14d
    jmp 2b

# tab_count(cstr or 0) -> eax its labels (tab-separated), TABS_MAX at most
tab_count:
    xor eax, eax
    test rdi, rdi
    jz 9f
    cmp byte ptr [rdi], 0
    je 9f
    mov eax, 1
1:  movzx ecx, byte ptr [rdi]
    test ecx, ecx
    jz 9f
    inc rdi
    cmp ecx, 31
    jne 1b
    inc eax
    cmp eax, TABS_MAX
    jb 1b
9:  ret

# secret_box(DR*, y, x, w, h, focused) -> eax the ui_btn bits: a field drawn as bullets (one a character,
#   BULLETS_MAX at most), the caret after them when it has the keys
secret_box:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov [rsp + 16], r9d
    mov r12, [rbx + DGR_val]
    mov edi, [r12 + TF_id]
    mov esi, edx
    mov edx, [rsp]
    mov r8d, [rsp + 12]
    call ui_btn
    mov [rsp + 20], eax
    COLOR r9d, T_BORDER
    cmp dword ptr [rsp + 16], 0
    je 1f
    COLOR r9d, T_ACCENT
1:  COLOR eax, T_INPUT
    push rax
    push rax
    mov edi, [rsp + 16 + 4]
    mov esi, [rsp + 16]
    mov edx, [rsp + 16 + 8]
    mov ecx, [rsp + 16 + 12]
    PM r8d, MI_RADIUS
    call gfx_frame
    add rsp, 16
    mov rdi, r12
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call bullets
    mov rdi, [rip + ag_fui]
    mov rsi, [rip + xsb + SB_ptr]
    mov rdx, [rip + xsb + SB_len]
    call text_width
    mov r13d, eax
    mov esi, [rsp + 4]
    add esi, [rip + g_pmt + 4*MI_10]
    mov [rsp + 24], esi
    mov rdi, [rip + ag_fui]
    mov edx, [rsp + 12]
    sub edx, [rdi + FACE_lineh]
    sar edx, 1
    add edx, [rsp]
    mov [rsp + 28], edx
    add edx, [rdi + FACE_ascent]
    mov rcx, [rip + xsb + SB_ptr]
    mov r8, [rip + xsb + SB_len]
    COLOR r9d, T_FG
    call text_draw
    cmp dword ptr [rsp + 16], 0
    je 9f
    mov edi, [rsp + 24]
    add edi, r13d
    mov esi, [rsp + 28]
    PM edx, MI_2
    mov rax, [rip + ag_fui]
    mov ecx, [rax + FACE_lineh]
    COLOR r8d, T_CURSOR
    call gfx_fill
9:  mov eax, [rsp + 20]
    EPILOGUE

# bullets(ptr, len): xsb = a bullet for each character (BULLETS_MAX at most)
bullets:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + xsb]
    call sb_clear
    xor r13d, r13d              # bytes
    xor r14d, r14d              # bullets
1:  cmp r13, r12
    jae 9f
    cmp r14d, BULLETS_MAX
    jae 9f
    movzx eax, byte ptr [rbx + r13]
    inc r13
    and eax, 0xc0
    cmp eax, 0x80
    je 1b                       # a continuation byte
    lea rdi, [rip + xsb]
    lea rsi, [rip + .Lbullet]
    call sb_push_cstr
    inc r14d
    jmp 1b
9:  EPILOGUE

# FN agentdlg2_key(entry, keysym, cp, mods) -> eax 1 when the focused form row took the key
FN agentdlg2_key
    PROLOGUE 16
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    call rowp
    test rax, rax
    jz .Lk_no
    mov rbx, rax
    test dword ptr [rbx + DGR_flags], DGF_OFF
    jnz .Lk_no
    mov eax, [rbx + DGR_kind]
    cmp eax, DGK_FIELD
    je .Lk_fieldk
    cmp eax, DGK_TABS
    jne .Lk_no
    mov rdi, [rbx + DGR_t1]     # TABS: Left, Right round; Space and Enter the next
    call tab_count
    mov ecx, eax
    test ecx, ecx
    jz .Lk_no
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Lk_no
    mov rax, [rbx + DGR_val]
    cmp r12d, KEY_LEFT
    jne 1f
    dec eax
    jns 3f
    lea eax, [rcx - 1]
    jmp 3f
1:  cmp r12d, KEY_RIGHT
    je 2f
    cmp r12d, KEY_RETURN
    je 2f
    cmp r12d, KEY_KP_ENTER
    je 2f
    cmp r13d, ' '
    jne .Lk_no
2:  inc eax
    cmp eax, ecx
    jb 3f
    xor eax, eax
3:  mov edi, [rbx + DGR_act]
    test edi, edi
    jz .Lk_yes
    mov esi, eax
    mov rdx, rbx
    call agentdlg_x_act
    jmp .Lk_yes
.Lk_fieldk:
    mov r15, [rbx + DGR_val]
    test r15, r15
    jz .Lk_no
    cmp r12d, KEY_TAB
    je .Lk_no
    cmp r12d, KEY_ISO_LEFT_TAB
    je .Lk_no
    cmp r12d, KEY_PAGEUP
    je .Lk_no
    cmp r12d, KEY_PAGEDOWN
    je .Lk_no
    cmp r12d, KEY_RETURN
    je 1f
    cmp r12d, KEY_KP_ENTER
    jne 4f
1:  test dword ptr [rbx + DGR_flags], DGF_MULTI
    jz 2f
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jz 5f                       # a new line
2:  mov edi, [rbx + DGR_act]    # a one-line field's Enter: its act, else the next
    test edi, edi
    jz 3f
    mov rsi, [rbx + DGR_arg]
    mov rdx, rbx
    call agentdlg_x_act
    jmp .Lk_yes
3:  mov edi, 1
    call agentdlg_x_move
    jmp .Lk_yes
4:  cmp r12d, KEY_UP
    je 41f
    cmp r12d, KEY_DOWN
    jne 5f
41: test dword ptr [rbx + DGR_flags], DGF_MULTI
    jz .Lk_no                   # a one-line field: the focus moves
    mov rax, [r15 + TF_cur]
    mov [rsp], rax
    mov rdi, r15
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call ta_key
    mov rax, [r15 + TF_cur]
    cmp rax, [rsp]
    je .Lk_no                   # the caret could go no further: the focus moves
    jmp .Lk_yes
5:  mov rdi, r15
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call ta_key
    test eax, eax
    jnz .Lk_yes
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Lk_no
    cmp r13d, ' '
    jb .Lk_no
.Lk_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lk_no:
    xor eax, eax
    EPILOGUE

# FN agentdlg2_field(entry) -> rax the focused field's TF, else 0
FN agentdlg2_field
    PROLOGUE
    call rowp
    test rax, rax
    jz 9f
    cmp dword ptr [rax + DGR_kind], DGK_FIELD
    jne 8f
    test dword ptr [rax + DGR_flags], DGF_OFF
    jnz 8f
    mov rax, [rax + DGR_val]
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agentdlg2_paste(entry, ptr, len) -> eax 1 when the focused row is a field: the text goes in (a one-line
#   field's line ends become spaces)
FN agentdlg2_paste
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    call rowp
    test rax, rax
    jz 8f
    mov rbx, rax
    cmp dword ptr [rbx + DGR_kind], DGK_FIELD
    jne 8f
    test dword ptr [rbx + DGR_flags], DGF_OFF
    jnz 8f
    mov rdi, [rbx + DGR_val]
    test rdi, rdi
    jz 8f
    mov rsi, r12
    mov rdx, r13
    test dword ptr [rbx + DGR_flags], DGF_MULTI
    jz 1f
    call ta_insert
    jmp 2f
1:  call tf_insert
2:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentdlg2_dump_row(sb, DR*): print-agent-dialog's line after "KIND[N]": field " LABEL\tVALUE\tHINT"
#   (a line end in the value as \n; DGF_SECRET: a * a character; DGF_SECRETV: each line's value after its
#   first = or : as ***) and its flags (multi, secret, error, disabled); option " T1\tT2 on|off"; tabs
#   " A|B shown=N"
FN agentdlg2_dump_row
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rsi, [r12 + DGR_t1]
    mov eax, [r12 + DGR_kind]
    cmp eax, DGK_TABS
    je .Ldu_tabs
    call push_c
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    cmp dword ptr [r12 + DGR_kind], DGK_OPTION
    je .Ldu_option
    mov rdi, [r12 + DGR_val]    # FIELD: the value
    test rdi, rdi
    jz 3f
    call tf_text
    mov r13, rax
    mov r14, rdx
    test dword ptr [r12 + DGR_flags], DGF_SECRET
    jz 1f
    mov rdi, r13
    mov rsi, r14
    call stars
    jmp 3f
1:  xor r15d, r15d              # 1: past the line's = or : (DGF_SECRETV)
    xor ecx, ecx
2:  cmp rcx, r14
    jae 3f
    movzx esi, byte ptr [r13 + rcx]
    inc rcx
    push rcx
    push rcx
    cmp esi, 10
    jne 21f
    xor r15d, r15d
    mov rdi, rbx
    mov esi, 92                 # a backslash
    call sb_push_byte
    mov rdi, rbx
    mov esi, 'n'
    call sb_push_byte
    jmp 24f
21: test r15d, r15d
    jnz 24f
    mov rdi, rbx
    call sb_push_byte
    test dword ptr [r12 + DGR_flags], DGF_SECRETV
    jz 24f
    mov rcx, [rsp]
    movzx eax, byte ptr [r13 + rcx - 1]
    cmp eax, '='
    je 22f
    cmp eax, ':'
    jne 24f
22: mov r15d, 1
    mov rdi, rbx
    lea rsi, [rip + .Lhidden]
    call sb_push_cstr
24: pop rcx
    pop rcx
    jmp 2b
3:  mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rsi, [r12 + DGR_t3]
    call push_c
    test dword ptr [r12 + DGR_flags], DGF_MULTI
    jz 4f
    lea rsi, [rip + .Lf_multi]
    call push_c
4:  test dword ptr [r12 + DGR_flags], DGF_SECRET
    jz 5f
    lea rsi, [rip + .Lf_secret]
    call push_c
5:  test dword ptr [r12 + DGR_flags], DGF_ERROR
    jz .Ldu_off
    lea rsi, [rip + .Lf_error]
    call push_c
    jmp .Ldu_off
.Ldu_option:
    mov rsi, [r12 + DGR_t2]
    call push_c
    lea rsi, [rip + .Lf_on]
    test dword ptr [r12 + DGR_flags], DGF_ON
    jnz 1f
    lea rsi, [rip + .Lf_off]
1:  call push_c
    jmp .Ldu_off
.Ldu_tabs:
    xor ecx, ecx                # the labels with | between them
    test rsi, rsi
    jz 3f
1:  movzx eax, byte ptr [rsi + rcx]
    test eax, eax
    jz 3f
    push rsi
    push rcx
    mov esi, eax
    cmp esi, 31
    jne 2f
    mov esi, '|'
2:  mov rdi, rbx
    call sb_push_byte
    pop rcx
    pop rsi
    inc rcx
    jmp 1b
3:  lea rsi, [rip + .Lf_shown]
    call push_c
    mov rdi, rbx
    mov rsi, [r12 + DGR_val]
    call sb_push_u64
.Ldu_off:
    test dword ptr [r12 + DGR_flags], DGF_OFF
    jz 8f
    lea rsi, [rip + .Lf_disabled]
    call push_c
8:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# push_c(rsi cstr or 0) onto rbx's sb
push_c:
    test rsi, rsi
    jz 1f
    mov rdi, rbx
    jmp sb_push_cstr
1:  ret

# stars(ptr, len) onto rbx's sb: a * a character
stars:
    PROLOGUE
    mov r13, rdi
    mov r14, rsi
    xor r15d, r15d
1:  cmp r15, r14
    jae 9f
    movzx eax, byte ptr [r13 + r15]
    inc r15
    and eax, 0xc0
    cmp eax, 0x80
    je 1b
    mov rdi, rbx
    mov esi, '*'
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# FN agentdlg2_c_setfield(out, rest, len) -> rax 0 or -1: agent-dialog-field N TEXT: the N-th field (from 1, in
#   the rows' order) holds TEXT ("\n" in it a line end; a one-line field's line ends become spaces)
FN agentdlg2_c_setfield
    PROLOGUE 16
    mov rbx, rdx                # the rest: N, a blank, TEXT
    mov r12, rsi
    xor ecx, ecx
1:  cmp rcx, rbx
    jae 8f
    cmp byte ptr [r12 + rcx], ' '
    je 2f
    inc rcx
    jmp 1b
2:  mov [rsp], rcx
    mov rdi, r12
    mov rsi, rcx
    call parse_u64
    mov r13, rax                # N
    test r13, r13
    jz 8f
    mov rcx, [rsp]
    lea r14, [r12 + rcx + 1]
    mov r15, rbx
    sub r15, rcx
    dec r15
    lea rdi, [rip + xsb]        # TEXT with its \n made line ends
    call sb_clear
    xor ecx, ecx
3:  cmp rcx, r15
    jae 5f
    movzx esi, byte ptr [r14 + rcx]
    inc rcx
    cmp esi, 92
    jne 4f
    cmp rcx, r15
    jae 4f
    cmp byte ptr [r14 + rcx], 'n'
    jne 4f
    inc rcx
    mov esi, 10
4:  mov [rsp + 8], rcx
    lea rdi, [rip + xsb]
    call sb_push_byte
    mov rcx, [rsp + 8]
    jmp 3b
5:  call agentdlg_x_nrows       # the N-th field
    mov rbx, rax
    xor r12d, r12d
6:  cmp r12, rbx
    jae 8f
    mov rdi, r12
    inc r12
    call agentdlg_x_row
    cmp dword ptr [rax + DGR_kind], DGK_FIELD
    jne 6b
    dec r13
    jnz 6b
    mov r12, rax
    mov rdi, [r12 + DGR_val]
    test rdi, rdi
    jz 8f
    call tf_clear
    mov rdi, [r12 + DGR_val]
    mov rsi, [rip + xsb + SB_ptr]
    mov rdx, [rip + xsb + SB_len]
    test dword ptr [r12 + DGR_flags], DGF_MULTI
    jz 7f
    call ta_insert
    jmp 71f
7:  call tf_insert
71: lea rdi, [rip + xsb]
    call sb_clear
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

.section .rodata
.globl agentdlg2_n_setfield
agentdlg2_n_setfield: .asciz "agent-dialog-field"
.globl agentdlg2_n_field, agentdlg2_n_option, agentdlg2_n_tabs
agentdlg2_n_field: .asciz "field"
agentdlg2_n_option: .asciz "option"
agentdlg2_n_tabs: .asciz "tabs"
.Lbullet: .asciz "\342\200\242"
.Lhidden: .asciz "***"
.Lf_multi: .asciz " multi"
.Lf_secret: .asciz " secret"
.Lf_error: .asciz " error"
.Lf_on: .asciz " on"
.Lf_off: .asciz " off"
.Lf_shown: .asciz " shown="
.Lf_disabled: .asciz " disabled"
