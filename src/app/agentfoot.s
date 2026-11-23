# The bands above a driven conversation's prompt box, and its footer under it (generic: a driver gives the
# bands' texts through ev_band, agent_drv.s). Everything here is drawn in the panel's faces and metrics.
#
#   bands_h(AS* or 0, w) -> eax         the room the bands take above the box (0 with none shown)
#   bands_draw(AS* or 0, x, y, w)       each band shown: its text in the panel's small face, wrapped at
#                                       words, at most 4 lines (the 4th cut with "…"); its x ("Dismiss
#                                       error", "Dismiss warning", "Dismiss notice") takes it away until its
#                                       text changes (AL_bandoff)
#   bands_dump(sb, AS* or 0)            print-agent-bands: "band KIND lines=N close=X,Y TEXT" a line each
#                                       (KIND error, settings, auth, rate, notice; as drawn last; a line
#                                       break in the text as \n), then "room=R drawn=D" when one shows: the
#                                       room bands_h gives them at the last width, and the room drawn
#   foot_h(AS* or 0, w) -> eax          the footer's room under the box: a row when the box's driver has
#                                       permission modes (DRVC_MODES; 0: a built-in driver's draft), else 0
#   foot_draw(AS* or 0, x, y, w)        the footer row: the mode button (a dot of the mode's colour, its
#                                       label cut with "…" to the room left; a click opens the modes
#                                       picker; tooltip "DESCRIPTION. Click to change, or press Shift+Tab
#                                       to cycle."), then at the right the command menu's button "/" (title
#                                       "Show command menu (/)"). Send keeps its place beside the box (box_fit).
#                                       Short of room the dot goes, then the label is cut (the footer's
#                                       stages are task 8's)
#   foot_ring(AS* or 0) -> eax          the box's frame colour in the current mode: a theme slot + 1 (TF_ring)
#   foot_mode_set(AS* or 0, id) -> eax 1   a mode the user picked (the picker, agent-mode): only one the
#                                       driver offers now (bypass only through its gate); a draft becomes its
#                                       conversation first (nothing starts)
#   foot_mode_cycle() -> eax 1 taken    Shift+Tab in the box: the next mode offered, wrapping
#   foot_dump(sb)                       print-agents-foot: "mode=ID ring=N mode_at=X,Y menu_at=X,Y
#                                       label=LABEL" (the open conversation's, as drawn last), then for every
#                                       panel size 8 to 32 and width 240 to 900 (step 20) "size=S w=W h=H
#                                       send_x= send_y= send_w= send_h= mode_x= mode_y= mode_w= mode_h=
#                                       menu_x= menu_y= menu_w= menu_h= label=SHOWN" (from the panel's left
#                                       and the prompt row's top; H the prompt row and the footer)
.include "rhun.inc"

.equ BAND_LINES, 4
.equ FOOT_MODE, 0               # ID_AGFOOT + : the mode button
.equ FOOT_MENU, 1               #   the command menu's button

.bss
.p2align 3
bsb: .zero SB_SIZE              # a cut line with its "…"
band_lines: .zero 4 * BK_COUNT  # as drawn last: its lines, where its x is (its centre)
band_cx: .zero 4 * BK_COUNT
band_cy: .zero 4 * BK_COUNT
band_w: .long 0                 # the width and the room the last draw took (bands_dump checks bands_h)
band_room: .long 0
tsb: .zero SB_SIZE              # the mode button's tooltip
lsb: .zero SB_SIZE              # its label as shown
fl_row: .long 0                 # layout(): the row's height, the mode button's x and width, whether its dot
fl_mx: .long 0                  #   shows, the label's x and room, the menu button's x and width (from the
fl_mw: .long 0                  #   panel's left)
fl_dot: .long 0
fl_lx: .long 0
fl_lw: .long 0
fl_nx: .long 0
fl_nw: .long 0
fd_mode: .long 0                # as drawn last: the buttons' centres
fd_mode_y: .long 0
fd_menu: .long 0
fd_menu_y: .long 0

.text

# band_text(AS* or 0, kind) -> rax the band's text when it shows (it has one, not dismissed), else 0
band_text:
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rdi, [rdi + AS_live]
    test rdi, rdi
    jz 9f
    mov ecx, esi
    mov edx, 1
    shl edx, cl
    test dword ptr [rdi + AL_bandoff], edx
    jnz 9f
    mov eax, esi
    mov rax, [rdi + AL_bands + rax*8]
9:  ret

# text_w(w) -> eax the width a band's text wraps at, in a panel w wide
text_w:
    mov eax, edi
    sub eax, [rip + g_pmt + 4*MI_12]
    sub eax, [rip + g_pmt + 4*MI_12]
    sub eax, [rip + g_pmt + 4*MI_8]
    sub eax, [rip + g_pmt + 4*MI_8]
    sub eax, [rip + g_pmt + 4*MI_20]
    sub eax, [rip + g_pmt + 4*MI_4]
    cmp eax, 1
    jge 1f
    mov eax, 1
1:  ret

# band_line(ptr, len, maxw) -> rax the bytes of the first line shown, rdx the bytes it takes (with the
#   space or line break that ends it): broken after a word when it can be, else where it fits (a
#   character at least)
band_line:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r15d, edx
    xor eax, eax
    xor edx, edx
    test r13, r13
    jz 9f
    xor r14d, r14d              # the line's end: a line break, or the text's
1:  cmp r14, r13
    jae 2f
    cmp byte ptr [r12 + r14], 10
    je 2f
    inc r14
    jmp 1b
2:  mov rdi, [rip + ag_fsmall]
    mov rsi, r12
    mov rdx, r14
    mov ecx, r15d
    call text_fit
    cmp rax, r14
    jb 3f
    mov rax, r14                # it all fits
    mov rdx, r14
    cmp r14, r13
    jae 9f
    inc rdx                     # and its line break
    EPILOGUE
3:  mov rbx, rax                # what fits; a break at a space there or before
    mov rcx, rax
4:  test rcx, rcx
    jz 5f
    cmp byte ptr [r12 + rcx], ' '
    je 6f
    dec rcx
    jmp 4b
6:  mov rax, rcx
    lea rdx, [rcx + 1]
    EPILOGUE
5:  test rbx, rbx               # one word wider than the line: cut where it fits
    jnz 7f
    mov rdi, r12
    mov rsi, r13
    call utf8_decode
    mov eax, edx
    EPILOGUE
7:  mov rax, rbx
    mov rdx, rbx
9:  EPILOGUE

# band_count(text cstr, maxw) -> eax its lines (at most BAND_LINES), edx 1 when text is left past them
band_count:
    PROLOGUE
    mov r12, rdi
    call strlen
    mov r13, rax
    mov r15d, esi
    xor ebx, ebx
1:  test r13, r13
    jz 8f
    cmp ebx, BAND_LINES
    jae 7f
    mov rdi, r12
    mov rsi, r13
    mov edx, r15d
    call band_line
    test rdx, rdx
    jz 8f
    add r12, rdx
    sub r13, rdx
    inc ebx
    jmp 1b
7:  mov eax, ebx
    mov edx, 1
    EPILOGUE
8:  test ebx, ebx
    jnz 9f
    inc ebx
9:  mov eax, ebx
    xor edx, edx
    EPILOGUE

# band_h(lines) -> eax a band's height: its lines (the x's room at least) and its padding
band_h:
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    imul eax, edi
    mov ecx, [rip + g_pmt + 4*MI_20]
    cmp eax, ecx
    cmovl eax, ecx
    add eax, [rip + g_pmt + 4*MI_6]
    add eax, [rip + g_pmt + 4*MI_6]
    ret

# FN bands_h(AS* or 0, w) -> eax the bands' room: MI_8 above each band shown, and the band
FN bands_h
    PROLOGUE
    mov rbx, rdi
    mov edi, esi
    call text_w
    mov r14d, eax
    xor r12d, r12d              # kind
    xor r13d, r13d              # height
1:  cmp r12d, BK_COUNT
    jae 9f
    mov rdi, rbx
    mov esi, r12d
    call band_text
    inc r12d
    test rax, rax
    jz 1b
    mov rdi, rax
    mov esi, r14d
    call band_count
    mov edi, eax
    call band_h
    add r13d, eax
    add r13d, [rip + g_pmt + 4*MI_8]
    jmp 1b
9:  mov eax, r13d
    EPILOGUE

# FN bands_draw(AS* or 0, x, y, w): the bands, one under the other from y
FN bands_draw
    PROLOGUE 64
    mov rbx, rdi
    mov [rsp], esi              # x
    mov [rsp + 4], edx          # y cursor
    mov [rsp + 8], ecx          # w
    mov [rip + band_w], ecx
    mov edi, ecx
    call text_w
    mov [rsp + 12], eax         # text width
    mov eax, [rsp + 4]
    mov [rsp + 28], eax         # where it starts
    xor r12d, r12d
.Lbd_band:
    cmp r12d, BK_COUNT
    jae .Lbd_done
    lea r10, [rip + band_lines]
    mov dword ptr [r10 + r12*4], 0
    mov rdi, rbx
    mov esi, r12d
    call band_text
    test rax, rax
    jz .Lbd_next
    mov r13, rax                # the text
    mov rdi, rax
    mov esi, [rsp + 12]
    call band_count
    mov [rsp + 16], eax         # lines
    mov [rsp + 20], edx         # cut
    lea r10, [rip + band_lines]
    mov [r10 + r12*4], eax
    mov edi, eax
    call band_h
    mov [rsp + 24], eax         # h
    mov eax, [rsp + 4]
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + 4], eax          # its top
    lea rcx, [rip + band_colors]
    mov eax, [rcx + r12*4]
    lea rcx, [rip + g_theme]
    mov r14d, [rcx + rax*4]     # its colour
    COLOR edi, T_PANEL
    mov esi, r14d
    mov edx, 40
    call color_mix
    mov edi, [rsp]
    add edi, [rip + g_pmt + 4*MI_12]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    sub edx, [rip + g_pmt + 4*MI_12]
    sub edx, [rip + g_pmt + 4*MI_12]
    mov ecx, [rsp + 24]
    PM r8d, MI_RADIUS
    mov r9d, r14d
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    # its lines
    mov rdi, r13
    call strlen
    mov r14, rax                # bytes left
    xor r15d, r15d              # line
.Lbd_line:
    cmp r15d, [rsp + 16]
    jae .Lbd_x
    mov rdi, r13
    mov rsi, r14
    mov edx, [rsp + 12]
    call band_line
    mov [rsp + 32], rdx         # what it takes
    mov [rsp + 48], r13         # what it shows
    mov [rsp + 56], rax
    lea eax, [r15 + 1]
    cmp eax, [rsp + 16]
    jne 2f
    cmp dword ptr [rsp + 20], 0
    je 2f
    mov rdi, r13                # the last line, more after it: cut with "…"
    mov esi, [rsp + 12]
    call cut_line
    mov rax, [rip + bsb + SB_ptr]
    mov [rsp + 48], rax
    mov rax, [rip + bsb + SB_len]
    mov [rsp + 56], rax
2:  mov rdi, [rip + ag_fsmall]  # ui_text_v(face, x, y, h, ptr, len, argb)
    mov ecx, [rdi + FACE_lineh]
    mov edx, ecx
    imul edx, r15d
    add edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_6]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_12]
    add esi, [rip + g_pmt + 4*MI_8]
    mov r8, [rsp + 48]
    mov r9, [rsp + 56]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    add r13, [rsp + 32]
    sub r14, [rsp + 32]
    inc r15d
    jmp .Lbd_line
.Lbd_x:
    PM ecx, MI_20               # the x, at the top right
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rip + g_pmt + 4*MI_12]
    sub esi, [rip + g_pmt + 4*MI_4]
    sub esi, ecx
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_6]
    mov [rsp + 36], esi
    mov [rsp + 40], edx
    mov eax, ecx
    shr eax, 1
    lea r8d, [rsi + rax]
    lea r10, [rip + band_cx]
    mov [r10 + r12*4], r8d
    lea r8d, [rdx + rax]
    lea r10, [rip + band_cy]
    mov [r10 + r12*4], r8d
    lea edi, [r12 + ID_AGBAND]
    mov r8d, ecx
    mov r9d, IC_CLOSE
    call ag_icon_btn
    mov r15d, eax
    lea edi, [r12 + ID_AGBAND]
    mov esi, [rsp + 36]
    mov edx, [rsp + 40]
    add edx, [rip + g_pmt + 4*MI_20]
    PM ecx, MI_20
    mov r8d, r15d
    lea rax, [rip + band_tips]
    mov r9, [rax + r12*8]
    call tip_note_text
    test r15d, UB_CLICK
    jz 3f
    mov rax, [rbx + AS_live]    # dismissed: until its text changes
    mov ecx, r12d
    mov edx, 1
    shl edx, cl
    or [rax + AL_bandoff], edx
    mov dword ptr [rip + g_dirty], 1
3:  mov eax, [rsp + 24]
    add [rsp + 4], eax
.Lbd_next:
    inc r12d
    jmp .Lbd_band
.Lbd_done:
    mov eax, [rsp + 4]
    sub eax, [rsp + 28]
    mov [rip + band_room], eax
    EPILOGUE

# cut_line(ptr, maxw): bsb = as much of the text as fits at maxw with "…" after it
cut_line:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    lea rdi, [rip + bsb]
    call sb_clear
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lellipsis]
    mov edx, 3
    call text_width
    sub r13d, eax
    jns 1f
    xor r13d, r13d
1:  mov rdi, r12
    call strlen
    mov rcx, rax                # up to a line break
    xor edx, edx
2:  cmp rdx, rcx
    jae 3f
    cmp byte ptr [r12 + rdx], 10
    je 3f
    inc rdx
    jmp 2b
3:  mov rdi, [rip + ag_fsmall]
    mov rsi, r12
    mov ecx, r13d
    call text_fit
    lea rdi, [rip + bsb]
    mov rsi, r12
    mov rdx, rax
    call sb_push
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lellipsis]
    mov edx, 3
    call sb_push
    EPILOGUE

# FN bands_dump(sb, AS* or 0): "band KIND lines=N close=X,Y TEXT" for each band shown, as drawn last
FN bands_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
    xor r15d, r15d              # bands shown
1:  cmp r13d, BK_COUNT
    jae 9f
    mov rdi, r12
    mov esi, r13d
    call band_text
    test rax, rax
    jz 7f
    mov r14, rax
    mov rdi, rbx
    lea rsi, [rip + .Ld_band]
    call sb_push_cstr
    lea rax, [rip + band_names]
    mov rsi, [rax + r13*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_lines]
    call sb_push_cstr
    mov rdi, rbx
    lea r10, [rip + band_lines]
    mov esi, [r10 + r13*4]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_close]
    call sb_push_cstr
    mov rdi, rbx
    lea r10, [rip + band_cx]
    mov esi, [r10 + r13*4]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    lea r10, [rip + band_cy]
    mov esi, [r10 + r13*4]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
2:  movzx esi, byte ptr [r14]   # the text, a line break as \n
    test esi, esi
    jz 4f
    inc r14
    cmp esi, 10
    jne 3f
    mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
    mov esi, 'n'
3:  mov rdi, rbx
    call sb_push_byte
    jmp 2b
4:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r15d
7:  inc r13d
    jmp 1b
9:  test r15d, r15d
    jz 10f
    mov rdi, rbx
    lea rsi, [rip + .Ld_room]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rip + band_w]
    call bands_h
    mov esi, eax
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_drawn]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + band_room]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
10: EPILOGUE

# foot_drv(AS* or 0) -> rax the driver of the box's conversation (0: the box's draft) when it has permission
#   modes, else 0
foot_drv:
    PROLOGUE
    test rdi, rdi
    jz 1f
    call agent_drv_of
    jmp 2f
1:  call agentext_box_owner
    test rax, rax               # a draft only: an open conversation passes its AS
    jnz 8f
    test edx, edx
    jz 8f
    mov edi, edx
    call agent_drv_for_kind
2:  test rax, rax
    jz 9f
    test dword ptr [rax + DRV_caps], DRVC_MODES
    jnz 9f
8:  xor eax, eax
9:  EPILOGUE

# foot_cur(AS* or 0) -> rax the current mode (the driver's AMD) or 0, edx how many are offered, rcx the list
foot_cur:
    PROLOGUE 16
    mov rbx, rdi
    call foot_drv
    test rax, rax
    jz 8f
    mov qword ptr [rsp], 0
    mov rdi, rbx
    lea rsi, [rsp]
    call [rax + DRV_modes]
    mov rcx, [rsp]
    test rcx, rcx
    jnz 1f
    xor eax, eax
1:  mov r8d, eax                # n
    mov rax, rdx                # the current one
    mov edx, r8d
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    EPILOGUE

# row_h() -> eax the footer row's height: MI_24, or the small face's line and MI_2 above and below it
row_h:
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_2]
    add eax, [rip + g_pmt + 4*MI_2]
    mov ecx, [rip + g_pmt + 4*MI_24]
    cmp eax, ecx
    cmovl eax, ecx
    ret

# FN foot_h(AS* or 0, w) -> eax the footer's room: its row and MI_8 under it; 0 without a driver with modes
FN foot_h
    PROLOGUE
    call foot_drv
    test rax, rax
    jz 9f
    call row_h
    add eax, [rip + g_pmt + 4*MI_8]
9:  EPILOGUE

# FN foot_ring(AS* or 0) -> eax the box's frame colour in the current mode: its theme slot + 1, 0 for none
FN foot_ring
    PROLOGUE
    call foot_cur
    test rax, rax
    jz 9f
    mov eax, [rax + AMD_color]
    inc eax
9:  EPILOGUE

# mode_label(AMD* or 0) -> rax its label, "Mode" without one
mode_label:
    lea rax, [rip + .Lmode]
    test rdi, rdi
    jz 1f
    mov rax, [rdi + AMD_label]
1:  ret

# layout(AS* or 0, w): the footer row's parts in fl_* (from the panel's left): the menu button square at the
#   right end of the prompt row (where Send's right edge is), the mode button from the box's left up to MI_8
#   before it: MI_6 in, its dot (MI_8) and MI_6, its label, MI_6. Without room for the dot and two
#   characters' worth of label the dot goes; the label is cut to what is left. lsb: the label as shown
layout:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    call row_h
    mov [rip + fl_row], eax
    mov [rip + fl_nw], eax
    mov r13d, r12d              # the right end: w - MI_40 + MI_8 + MI_12
    sub r13d, [rip + g_pmt + 4*MI_40]
    add r13d, [rip + g_pmt + 4*MI_8]
    add r13d, [rip + g_pmt + 4*MI_12]
    sub r13d, eax
    mov [rip + fl_nx], r13d
    sub r13d, [rip + g_pmt + 4*MI_8]
    PM r14d, MI_12              # the mode button's left
    mov [rip + fl_mx], r14d
    sub r13d, r14d              # its room
    cmp r13d, 1
    jge 1f
    mov r13d, 1
1:  mov rdi, rbx
    call foot_cur
    mov rdi, rax
    call mode_label
    mov r15, rax
    mov rdi, rax
    call strlen
    mov rdx, rax
    mov rdi, [rip + ag_fsmall]
    mov rsi, r15
    call text_width
    mov [rsp], eax              # the label's width
    mov ecx, [rip + g_pmt + 4*MI_6]     # the room besides the label: MI_6, the dot and MI_6, MI_6
    imul ecx, ecx, 3
    add ecx, [rip + g_pmt + 4*MI_8]
    mov dword ptr [rip + fl_dot], 1
    mov eax, r13d
    sub eax, ecx
    cmp eax, [rip + g_pmt + 4*MI_16]    # the dot keeps two characters' worth of label at least
    jge 2f
    mov eax, [rsp]
    add eax, ecx
    cmp eax, r13d               # or the whole label beside it
    jle 2f
    mov dword ptr [rip + fl_dot], 0
    mov ecx, [rip + g_pmt + 4*MI_6]
    shl ecx, 1
2:  mov eax, [rip + g_pmt + 4*MI_6]  # the label's x
    cmp dword ptr [rip + fl_dot], 0
    je 3f
    add eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_6]
3:  add eax, r14d
    mov [rip + fl_lx], eax
    mov eax, r13d               # the label's room, and the button's width
    sub eax, ecx
    jns 4f
    xor eax, eax
4:  mov edx, [rsp]
    cmp edx, eax
    cmovl eax, edx
    mov [rip + fl_lw], eax
    add eax, ecx
    cmp eax, r13d
    cmovg eax, r13d
    mov [rip + fl_mw], eax
    mov rdi, r15                # lsb: what shows of the label
    mov esi, [rip + fl_lw]
    call label_cut
    EPILOGUE

# label_cut(cstr, maxw): lsb = the text when it fits in maxw (the small face), else as much as fits with "…"
#   after it, nothing when not even "…" does
label_cut:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    lea rdi, [rip + lsb]
    call sb_clear
    mov rdi, r12
    call strlen
    mov r14, rax
    mov rdi, [rip + ag_fsmall]
    mov rsi, r12
    mov rdx, r14
    call text_width
    cmp eax, r13d
    jg 1f
    lea rdi, [rip + lsb]
    mov rsi, r12
    mov rdx, r14
    call sb_push
    jmp 9f
1:  mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lellipsis]
    mov edx, 3
    call text_width
    cmp eax, r13d
    jg 9f
    mov rdi, r12
    mov esi, r13d
    call cut_line
    lea rdi, [rip + lsb]
    mov rsi, [rip + bsb + SB_ptr]
    mov rdx, [rip + bsb + SB_len]
    call sb_push
9:  lea rdi, [rip + lsb]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rip + lsb + SB_len]
    EPILOGUE

# FN foot_draw(AS* or 0, x, y, w): the footer row at y (layout)
FN foot_draw
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    call foot_drv
    test rax, rax
    jz 9f
    mov rdi, rbx
    mov esi, [rsp + 8]
    call layout
    mov rdi, rbx
    call foot_cur
    mov r15, rax                # the current mode, or 0
    # the mode button
    mov r12d, [rsp]
    add r12d, [rip + fl_mx]
    mov edi, ID_AGFOOT + FOOT_MODE
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rip + fl_mw]
    mov r8d, [rip + fl_row]
    call ui_btn
    mov r13d, eax
    mov ecx, [rip + fl_mw]
    shr ecx, 1
    lea eax, [r12 + rcx]
    mov [rip + fd_mode], eax
    mov eax, [rip + fl_row]
    shr eax, 1
    add eax, [rsp + 4]
    mov [rip + fd_mode_y], eax
    mov edi, APP_MODES
    mov esi, r13d
    call hover_bg
    mov edi, r12d
    mov esi, [rsp + 4]
    mov edx, [rip + fl_mw]
    call hover_draw
    cmp dword ptr [rip + fl_dot], 0     # its dot, in the mode's colour
    je 2f
    COLOR r9d, T_MUTED
    test r15, r15
    jz 1f
    mov eax, [r15 + AMD_color]
    lea rcx, [rip + g_theme]
    mov r9d, [rcx + rax*4]
1:  PM ecx, MI_8
    mov edi, r12d
    add edi, [rip + g_pmt + 4*MI_6]
    mov esi, [rip + fl_row]
    sub esi, ecx
    sar esi, 1
    add esi, [rsp + 4]
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    call gfx_round_rect
2:  mov rdi, [rip + ag_fsmall]  # its label as layout cut it
    mov esi, [rsp]
    add esi, [rip + fl_lx]
    mov edx, [rsp + 4]
    mov ecx, [rip + fl_row]
    mov r8, [rip + lsb + SB_ptr]
    mov r9, [rip + lsb + SB_len]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    lea rdi, [rip + tsb]        # its tooltip
    call sb_clear
    test r15, r15
    jz 3f
    lea rdi, [rip + tsb]
    mov rsi, [r15 + AMD_desc]
    call sb_push_cstr
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Lt_dot]
    call sb_push_cstr
3:  lea rdi, [rip + tsb]
    lea rsi, [rip + .Lt_mode]
    call sb_push_cstr
    lea rdi, [rip + tsb]
    xor esi, esi
    call sb_push_byte
    mov edi, ID_AGFOOT + FOOT_MODE
    mov esi, r12d
    mov edx, [rsp + 4]
    add edx, [rip + fl_row]
    mov ecx, [rip + fl_mw]
    mov r8d, r13d
    mov r9, [rip + tsb + SB_ptr]
    call tip_note_text
    test r13d, UB_CLICK
    jz 4f
    mov edi, APP_MODES          # a click opens the picker, or closes it
    call toggle
    # the command menu's button
4:  mov r12d, [rsp]
    add r12d, [rip + fl_nx]
    mov edi, ID_AGFOOT + FOOT_MENU
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rip + fl_nw]
    mov r8d, [rip + fl_row]
    call ui_btn
    mov r13d, eax
    mov ecx, [rip + fl_nw]
    shr ecx, 1
    lea eax, [r12 + rcx]
    mov [rip + fd_menu], eax
    mov eax, [rip + fd_mode_y]
    mov [rip + fd_menu_y], eax
    mov edi, APP_MENU
    mov esi, r13d
    call hover_bg
    mov edi, r12d
    mov esi, [rsp + 4]
    mov edx, [rip + fl_nw]
    call hover_draw
    mov rdi, [rip + ag_fui]
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rip + fl_nw]
    mov r8d, [rip + fl_row]
    lea r9, [rip + .Lslash]
    COLOR eax, T_MUTED
    test r13d, UB_HOVER
    jz 5f
    COLOR eax, T_FG
5:  push rax
    push rax
    call ui_text_center
    add rsp, 16
    mov edi, ID_AGFOOT + FOOT_MENU
    mov esi, r12d
    mov edx, [rsp + 4]
    add edx, [rip + fl_row]
    mov ecx, [rip + fl_nw]
    mov r8d, r13d
    lea r9, [rip + .Lt_menu]
    call tip_note_text
    test r13d, UB_CLICK
    jz 9f
    mov edi, APP_MENU
    call toggle
9:  EPILOGUE

# hover_bg(popup kind, ub) -> eax 1 when the button is drawn lit: hovered, or its popup is open (the button
#   menu for APP_MENU)
hover_bg:
    PROLOGUE
    mov ebx, edi
    mov eax, 1
    test esi, UB_HOVER
    jnz 9f
    call agentpop_kind
    cmp eax, ebx
    jne 8f
    mov eax, 1
    cmp ebx, APP_MENU
    jne 9f
    call agentpop_field         # the typed menu is not the button's
    test rax, rax
    setnz al
    movzx eax, al
    jmp 9f
8:  xor eax, eax
9:  EPILOGUE

# hover_draw(x, y, w) with eax from hover_bg: the lit button's surface
hover_draw:
    test eax, eax
    jz 1f
    PROLOGUE
    mov ecx, [rip + fl_row]
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
    EPILOGUE
1:  ret

# toggle(kind): the footer's button for that popup: open it (the box's owner's), or close it when it is open
toggle:
    PROLOGUE
    mov ebx, edi
    call agentpop_kind
    cmp eax, ebx
    jne 1f
    cmp ebx, APP_MENU
    jne 2f
    call agentpop_field         # the typed menu gives way to the button's
    test rax, rax
    jz 1f
2:  call agentpop_close
    jmp 9f
1:  mov edi, ebx
    xor esi, esi
    xor edx, edx
    call agentpop_open
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN foot_mode_set(AS* or 0 for the box's draft, id cstr) -> eax 1 when the driver asked for it or kept it:
#   only a mode it offers now (DRV_modes), on the conversation's live record (a draft becomes its
#   conversation first; nothing starts)
FN foot_mode_set
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    call foot_cur
    test edx, edx
    jz 8f
    mov r13, rcx                # the list
    mov r14d, edx
    xor r15d, r15d
1:  cmp r15d, r14d
    jae 8f
    imul rax, r15, AMD_SIZE
    mov rdi, [r13 + rax + AMD_id]
    mov rsi, r12
    call strcmp_eq
    inc r15d
    test eax, eax
    jz 1b
    test rbx, rbx               # offered: on the conversation's record
    jnz 2f
    call agentext_draft_own
    mov rbx, rax
    test rax, rax
    jz 8f
2:  mov rdi, rbx
    call agent_live
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rcx, [rax + AL_drv]
    mov rsi, r12
    call [rcx + DRV_set_mode]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN foot_mode_cycle() -> eax 1 when the key was taken: Shift+Tab in the box picks the mode after the current
#   one among those offered (wrapping; none current: the first), as the extension's cycle does
FN foot_mode_cycle
    PROLOGUE
    call agentext_box_owner
    xor r15d, r15d
    test edx, edx
    jz 9f
    mov rbx, rax
    mov rdi, rax
    call foot_cur
    test edx, edx
    jz 9f
    mov r12, rcx
    mov r13d, edx
    xor r14d, r14d              # the one after the current
1:  cmp r14d, r13d
    jae 3f
    imul rax, r14, AMD_SIZE
    inc r14d
    test dword ptr [r12 + rax + AMD_flags], AMDF_CURRENT
    jz 1b
    cmp r14d, r13d
    jb 4f
3:  xor r14d, r14d
4:  imul rax, r14, AMD_SIZE
    mov rsi, [r12 + rax + AMD_id]
    mov rdi, rbx
    call foot_mode_set
    mov r15d, 1
9:  mov eax, r15d
    EPILOGUE

# FN foot_dump(sb): print-agents-foot (see the top of the file); the setting is the user's again after it
FN foot_dump
    PROLOGUE 48
    mov rbx, rdi
    call agentext_box_owner     # the box's conversation (0: its draft)
    mov r15, rax
    mov rdi, rax
    call foot_cur
    mov r12, rax
    mov rdi, rbx
    lea rsi, [rip + .Ld_mode]
    call sb_push_cstr
    lea rsi, [rip + .Ld_dash]
    test r12, r12
    jz 1f
    mov rsi, [r12 + AMD_id]
1:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_ring]
    call sb_push_cstr
    mov rdi, r15
    call foot_ring
    mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_mode_at]
    lea rdx, [rip + fd_mode]
    call put_at
    mov rdi, rbx
    lea rsi, [rip + .Ld_menu_at]
    lea rdx, [rip + fd_menu]
    call put_at
    mov rdi, rbx
    lea rsi, [rip + .Ld_label]
    call sb_push_cstr
    mov rdi, r12
    call mode_label
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    mov dword ptr [rsp + 4], 8  # size
.Lfd_size:
    cmp dword ptr [rsp + 4], 32
    ja .Lfd_done
    mov eax, [rsp + 4]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    mov dword ptr [rsp + 8], 240
.Lfd_w:
    cmp dword ptr [rsp + 8], 900
    ja .Lfd_next
    mov edi, [rsp + 8]
    mov rsi, r15
    call agentext_send_at
    mov [rsp + 12], eax         # send x, y, w, h; the prompt row's height
    mov [rsp + 16], edx
    mov [rsp + 20], ecx
    mov [rsp + 24], r8d
    mov [rsp + 28], r9d
    mov rdi, r15
    mov esi, [rsp + 8]
    call foot_h
    add eax, [rsp + 28]
    mov [rsp + 32], eax
    mov rdi, r15
    mov esi, [rsp + 8]
    call layout
    mov rdi, rbx
    lea rsi, [rip + .Ld_size]
    mov edx, [rsp + 4]
    call put_num
    lea rsi, [rip + .Ld_w]
    mov edx, [rsp + 8]
    call put_num
    lea rsi, [rip + .Ld_h]
    mov edx, [rsp + 32]
    call put_num
    lea rsi, [rip + .Ld_send_x]
    mov edx, [rsp + 12]
    call put_num
    lea rsi, [rip + .Ld_send_y]
    mov edx, [rsp + 16]
    call put_num
    lea rsi, [rip + .Ld_send_w]
    mov edx, [rsp + 20]
    call put_num
    lea rsi, [rip + .Ld_send_h]
    mov edx, [rsp + 24]
    call put_num
    lea rsi, [rip + .Ld_mode_x]
    mov edx, [rip + fl_mx]
    call put_num
    lea rsi, [rip + .Ld_mode_y]
    mov edx, [rsp + 28]
    call put_num
    lea rsi, [rip + .Ld_mode_w]
    mov edx, [rip + fl_mw]
    call put_num
    lea rsi, [rip + .Ld_mode_h]
    mov edx, [rip + fl_row]
    call put_num
    lea rsi, [rip + .Ld_menu_x]
    mov edx, [rip + fl_nx]
    call put_num
    lea rsi, [rip + .Ld_menu_y]
    mov edx, [rsp + 28]
    call put_num
    lea rsi, [rip + .Ld_menu_w]
    mov edx, [rip + fl_nw]
    call put_num
    lea rsi, [rip + .Ld_menu_h]
    mov edx, [rip + fl_row]
    call put_num
    mov rdi, rbx
    lea rsi, [rip + .Ld_label]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + lsb + SB_ptr]
    mov rdx, [rip + lsb + SB_len]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add dword ptr [rsp + 8], 20
    jmp .Lfd_w
.Lfd_next:
    inc dword ptr [rsp + 4]
    jmp .Lfd_size
.Lfd_done:
    mov eax, [rsp]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    EPILOGUE

# put_num(sb, word cstr, edx n): WORD then n (rdi stays the sb)
put_num:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, edx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    pop r13
    pop r12
    pop rbx
    ret

# put_at(sb, word cstr, rdx {x, y} dwords): WORD then "X,Y"
put_at:
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r12]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r12 + 4]
    call sb_push_u64
    EPILOGUE

.section .rodata
.p2align 3
band_colors: .long T_ERROR, T_WARNING, T_WARNING, T_WARNING, T_INFO
band_names: .quad .Lk_error, .Lk_settings, .Lk_auth, .Lk_rate, .Lk_notice
band_tips: .quad .Lt_error, .Lt_warning, .Lt_warning, .Lt_warning, .Lt_notice
.Lk_error: .asciz "error"
.Lk_settings: .asciz "settings"
.Lk_auth: .asciz "auth"
.Lk_rate: .asciz "rate"
.Lk_notice: .asciz "notice"
.Lt_error: .asciz "Dismiss error"
.Lt_warning: .asciz "Dismiss warning"
.Lt_notice: .asciz "Dismiss notice"
.Ld_band: .asciz "band "
.Ld_lines: .asciz " lines="
.Ld_close: .asciz " close="
.Ld_room: .asciz "room="
.Ld_drawn: .asciz " drawn="
.Lellipsis: .ascii "\342\200\246"
.Lmode: .asciz "Mode"
.Lslash: .asciz "/"
.Lt_dot: .asciz ". "
.Lt_mode: .asciz "Click to change, or press Shift+Tab to cycle."
.Lt_menu: .asciz "Show command menu (/)"
.Ld_mode: .asciz "mode="
.Ld_dash: .asciz "-"
.Ld_ring: .asciz " ring="
.Ld_mode_at: .asciz " mode_at="
.Ld_menu_at: .asciz " menu_at="
.Ld_label: .asciz " label="
.Ld_size: .asciz "size="
.Ld_w: .asciz " w="
.Ld_h: .asciz " h="
.Ld_send_x: .asciz " send_x="
.Ld_send_y: .asciz " send_y="
.Ld_send_w: .asciz " send_w="
.Ld_send_h: .asciz " send_h="
.Ld_mode_x: .asciz " mode_x="
.Ld_mode_y: .asciz " mode_y="
.Ld_mode_w: .asciz " mode_w="
.Ld_mode_h: .asciz " mode_h="
.Ld_menu_x: .asciz " menu_x="
.Ld_menu_y: .asciz " menu_y="
.Ld_menu_w: .asciz " menu_w="
.Ld_menu_h: .asciz " menu_h="
