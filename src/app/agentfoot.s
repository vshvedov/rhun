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
#                                       break in the text as \n), after it "link KIND X,Y LABEL\tURL" for a
#                                       band with a link (ev_band_link: a line of its own under the text,
#                                       asked before it opens), then "room=R drawn=D" when one shows: the
#                                       room bands_h gives them at the last width, and the room drawn
#   foot_h(AS* or 0, w) -> eax          the footer's room under the box: a row when the box's driver has
#                                       permission modes (DRVC_MODES; 0: a built-in driver's draft), two at
#                                       stage 2, else 0
#   foot_draw(AS* or 0, x, y, w)        the footer row: the mode button (a dot of the mode's colour, its
#                                       label cut with "…" to the room left; a click opens the modes
#                                       picker; tooltip "DESCRIPTION. Click to change, or press Shift+Tab
#                                       to cycle."), the model pill ("NAME · EFFORT · Ultracode"; title
#                                       "Switch model (NAME)"; a click opens the models picker), then at the
#                                       right the context pie (2.15: less than half the window left; a
#                                       click sends /compact), the prompt cache's clock (2.17), the fast mark
#                                       (a spark while fast mode is on or cooling down) and the command
#                                       menu's button "/" (title "Show command menu (/)"). Send keeps its
#                                       place beside the box (box_fit). It fits in three stages (2.23,
#                                       layout): 0 all of it, 1 the clock goes and the label is cut, 2 the
#                                       pill on a row of its own. A warm clock asks the panel to redraw the
#                                       second its minutes change (agents_label_due): no timer of its own
#   foot_ring(AS* or 0) -> eax          the box's frame colour in the current mode: a theme slot + 1 (TF_ring)
#   foot_mode_set(AS* or 0, id) -> eax 1   a mode the user picked (the picker, agent-mode): only one the
#                                       driver offers now (bypass only through its gate); a draft becomes its
#                                       conversation first (nothing starts)
#   foot_mode_cycle() -> eax 1 taken    Shift+Tab in the box: the next mode offered, wrapping
#   agent_ctx_used(AGU*) -> eax %, edx known; agent_cache_state(AGU*) -> eax CACHE_*, rdx ms (left or idle)
#   foot_dump(sb, every)                print-agents-foot: "mode=ID ring=N mode_at=X,Y menu_at=X,Y
#                                       pill_at=X,Y fast_at=X,Y ctx_at=X,Y cache_at=X,Y fast=off|on|cooldown
#                                       clock=Nm|cold|- stage=N label=LABEL\tpill=TEXT\ttitle=TITLE" (the open
#                                       conversation's, as drawn last; at 0,0: not drawn), then for every
#                                       panel size 8 to 32 and width 240 to 900 (step 20) "size=S w=W h=H
#                                       send_x= send_y= send_w= send_h= mode_x= mode_y= mode_w= mode_h=
#                                       menu_x= menu_y= menu_w= menu_h= pill_x= pill_y= pill_w= pill_h=
#                                       pill_text= fast_x= fast_y= fast_w= fast_h= ctx_x= ctx_y= ctx_w= ctx_h=
#                                       cache_x= cache_y= cache_w= cache_h= stage=N [combo=N] label=SHOWN
#                                       \tpill=SHOWN" (from the panel's left and the prompt row's top; H the
#                                       prompt row and the footer; a width 0: not shown; pill_text the
#                                       width of its text as shown); every: those lines for each combination
#                                       of the extras (combo bits: 1 fast, 2 the pie, 4 a warm clock)
.include "rhun.inc"

.equ BAND_LINES, 4
.equ FOOT_MODE, 0               # ID_AGFOOT + : the mode button
.equ FOOT_MENU, 1               #   the command menu's button
.equ FOOT_PILL, 2               #   the model pill
.equ FOOT_FAST, 3               #   the fast mark
.equ FOOT_CTX, 4                #   the context pie
.equ FOOT_CACHE, 5              #   the prompt cache's clock
.equ FOOT_ADD, 6                #   the "+" (phase 4 task 3: a driver that takes parts)
.equ FOOT_SEL, 7                #   the selection chip, its x (phase 4 task 8)
.equ FOOT_SELX, 8
.equ BAND_LINK, 8               # ID_AGBAND + BAND_LINK + kind: a band's link

.data
fl_force: .long -1              # print-agents-foot every: the extras as a mask (extras), -1 the conversation's

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
lsb2: .zero SB_SIZE             # a band's link as shown
fl_row: .long 0                 # layout(): the row's height, the mode button's x and width, whether its dot
fl_mx: .long 0                  #   shows, the label's x and room, the menu button's x and width (from the
fl_mw: .long 0                  #   panel's left)
fl_dot: .long 0
fl_lx: .long 0
fl_lw: .long 0
fl_nx: .long 0
fl_nw: .long 0
fl_px: .long 0                  #   the pill's x and width (0: none), the fast mark's
fl_pw: .long 0
fl_fx: .long 0
fl_fw: .long 0
fl_ix: .long 0                  #   the context pie's x and width (0: none), the clock's
fl_iw: .long 0
fl_cx: .long 0
fl_cw: .long 0
fl_py: .long 0                  #   the pill's y from the footer's top (stage 2: the row under the first)
fl_stage: .long 0               #   the stage (2.23): 0, 1, 2
fl_hfast: .long 0               # extras(): the fast mark, the pie, the clock's state, its minutes, the share in
fl_hctx: .long 0                #   use (percent)
fl_cstate: .long 0
fl_cmin: .long 0
fl_pct: .long 0
fd_stage: .long 0               # as drawn last: the stage, the pie's centre, the clock's, each band's link's
fd_ctx: .long 0
fd_ctx_y: .long 0
fd_cache: .long 0
fd_cache_y: .long 0
band_lx: .zero 4 * BK_COUNT
band_ly: .zero 4 * BK_COUNT
.p2align 3
fl_cms: .quad 0                 #   a warm clock's ms left, a cold one's idle ms
csb: .zero SB_SIZE              # the clock's minutes as shown ("Nm")
fd_mode: .long 0                # as drawn last: the buttons' centres
fd_mode_y: .long 0
fd_menu: .long 0
fd_menu_y: .long 0
fd_pill: .long 0
fd_pill_y: .long 0
fd_fast: .long 0
fd_fast_y: .long 0
fd_add: .long 0                 # phase 4 task 3: the "+" as drawn last (its centre)
fd_add_y: .long 0
fl_ax: .long 0                  #   layout(): the "+"'s x, width (0: none), y from the footer's top (at
fl_aw: .long 0                  #   stage 2 it is on the pill's row, before the pill), and which row the pass
fl_ay: .long 0                  #   puts it on (1, 2)
fl_arow: .long 0
fl_sx: .long 0                  # phase 4 task 8: the selection chip's x, width (0: none), stage, label's width
fl_sw: .long 0
fl_sst: .long 0
fl_slw: .long 0
fl_res: .long 0                 #   the room it takes (0: none), and at the stages past 0
fl_res1: .long 0
fd_sel: .long 0                 #   as drawn last: its centre, its x's
fd_sel_y: .long 0
fd_selx: .long 0
fd_selx_y: .long 0
.p2align 3
ssb: .zero SB_SIZE              #   its label as shown, its tip
ssb2: .zero SB_SIZE
.p2align 3
pill_name: .quad 0              # the name pill_drv found (cstr), or 0
psb2: .zero SB_SIZE             # the pill's text
psb3: .zero SB_SIZE             # as shown (cut)

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

# band_link(AS* or 0, kind) -> rax the band's link ("LABEL\0URL\0", ev_band_link) or 0
band_link:
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rdi, [rdi + AS_live]
    test rdi, rdi
    jz 9f
    mov eax, esi
    mov rax, [rdi + AL_blinks + rax*8]
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
    mov r15d, eax
    mov rdi, rbx                # its link: a line of its own
    lea esi, [r12 - 1]
    call band_link
    test rax, rax
    jz 2f
    inc r15d
2:  mov edi, r15d
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
    lea r10, [rip + band_lx]
    mov dword ptr [r10 + r12*4], 0
    lea r10, [rip + band_ly]
    mov dword ptr [r10 + r12*4], 0
    mov rdi, rbx
    mov esi, r12d
    call band_link
    mov edi, [rsp + 16]
    test rax, rax
    jz 1f
    inc edi                     # its link's line
1:  call band_h
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
    mov rdi, rbx                # the link, on the line under the text
    mov esi, r12d
    call band_link
    test rax, rax
    jz .Lbd_close
    mov rdi, rax
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_12]
    add esi, [rip + g_pmt + 4*MI_8]
    mov rax, [rip + ag_fsmall]
    mov edx, [rax + FACE_lineh]
    imul edx, [rsp + 16]
    add edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_6]
    mov ecx, r12d
    mov r8d, [rsp + 12]
    call link_draw
.Lbd_close:
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

# link_draw(link "LABEL\0URL\0", x, y, kind, maxw): a band's link: its label in the accent colour (cut to
#   maxw), underlined while hovered; a click asks before the URL opens, named by the conversation's driver
#   (agents_web_link: after the frame, links_ask_open)
link_draw:
    PROLOGUE 32
    mov r12, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov rdi, r12
    mov esi, r8d
    call cut_line_fit           # lsb2: the label as shown, eax its width
    mov [rsp + 12], eax
    mov edi, [rsp + 8]
    add edi, ID_AGBAND + BAND_LINK
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, eax
    mov rax, [rip + ag_fsmall]
    mov r8d, [rax + FACE_lineh]
    call ui_btn
    mov r13d, eax
    mov ecx, [rsp + 8]          # its centre, for the dump
    mov eax, [rsp + 12]
    shr eax, 1
    add eax, [rsp]
    lea r10, [rip + band_lx]
    mov [r10 + rcx*4], eax
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    shr eax, 1
    add eax, [rsp + 4]
    lea r10, [rip + band_ly]
    mov [r10 + rcx*4], eax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rdi + FACE_lineh]
    mov r8, [rip + lsb2 + SB_ptr]
    mov r9, [rip + lsb2 + SB_len]
    COLOR eax, T_ACCENT
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    test r13d, UB_HOVER
    jz 1f
    mov edi, [rsp]              # underlined while hovered
    mov rax, [rip + ag_fsmall]
    mov esi, [rax + FACE_lineh]
    add esi, [rsp + 4]
    sub esi, [rip + g_pmt + 4*MI_2]
    mov edx, [rsp + 12]
    PM ecx, MI_1
    COLOR r8d, T_ACCENT
    call gfx_fill
1:  test r13d, UB_CLICK
    jz 9f
    call agentext_box_owner     # the band's conversation: its driver names who asks
    mov rdi, rax
    lea rbx, [rip + .Lt_agent]
    test rdi, rdi
    jz 2f
    call agent_drv_of
    test rax, rax
    jz 2f
    mov rbx, [rax + DRV_name]
2:  mov rdi, r12                # the URL after the label
    call strlen
    lea r14, [r12 + rax + 1]
    mov rdi, r14                # "dialog:NAME": a dialog of the panel's (agentdlg.s)
    call agentdlg_link
    test eax, eax
    jnz 9f
    mov rdi, r14
    call strlen
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r14
    call agents_web_link
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# cut_line_fit(cstr, maxw) -> eax its width as shown: lsb2 = the text when it fits, else cut with "…"
cut_line_fit:
    PROLOGUE
    lea rdx, [rip + lsb2]
    call cut_into
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rip + lsb2 + SB_ptr]
    mov rdx, [rip + lsb2 + SB_len]
    call text_width
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
    mov rdi, r12                # "link KIND X,Y LABEL\tURL"
    mov esi, r13d
    call band_link
    test rax, rax
    jz 6f
    mov r14, rax
    mov rdi, rbx
    lea rsi, [rip + .Ld_link]
    call sb_push_cstr
    lea rax, [rip + band_names]
    mov rsi, [rax + r13*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    lea r10, [rip + band_lx]
    mov esi, [r10 + r13*4]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    lea r10, [rip + band_ly]
    mov esi, [r10 + r13*4]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r14
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rdi, r14
    call strlen
    lea rsi, [r14 + rax + 1]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
6:  inc r15d
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
#   modes, parts or the editor's context (phase 4 task 3: a footer with only the "+"), else 0; edx its DRVC_*
#   bits as the UI is told them (agent-test-caps)
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
    mov edx, [rax + DRV_caps]
    mov ecx, [rip + g_att_test_caps]
    cmp ecx, -1
    cmovne edx, ecx
    test edx, DRVC_MODES | DRVC_PARTS | DRVC_CONTEXT
    jnz 9f
8:  xor eax, eax
    xor edx, edx
9:  EPILOGUE

# foot_cur(AS* or 0) -> rax the current mode (the driver's AMD) or 0, edx how many are offered, rcx the list
foot_cur:
    PROLOGUE 16
    mov rbx, rdi
    call foot_drv
    test rax, rax
    jz 8f
    test edx, DRVC_MODES        # (phase 4 task 3: a footer without modes)
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

# FN foot_h(AS* or 0, w) -> eax the footer's room: its row and MI_8 under it, and at stage 2 the pill's row
#   and MI_4 above it; 0 without a driver with modes
FN foot_h
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call foot_drv
    test rax, rax
    jz 9f
    mov rdi, rbx
    mov esi, r12d
    call layout
    mov eax, [rip + fl_row]
    add eax, [rip + g_pmt + 4*MI_8]
    cmp dword ptr [rip + fl_stage], 2
    jne 9f
    cmp dword ptr [rip + fl_pw], 0
    je 9f
    add eax, [rip + fl_row]
    add eax, [rip + g_pmt + 4*MI_4]
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

# layout(AS* or 0, w): the footer's parts in fl_* (from the panel's left, the footer row's top): the menu
#   button square at the right end of the prompt row (where Send's right edge is); MI_8 before it, right to
#   left with MI_4 between them, the fast mark's square while fast mode is on or cooling down, the prompt
#   cache's clock (an icon, and "Nm" while it is warm), the context pie's square while less than half the
#   window is left; from the box's left the mode button: MI_6 in, its dot (MI_8) and MI_6, its label, MI_6;
#   then, MI_4 after it, the model pill (a driver with models): MI_8 in, its text, MI_8. The stage (2.23),
#   measured in the panel's faces: 0 all of it at its natural width; 1 the clock goes and the mode button's
#   label is cut to what the pill at its natural width leaves (two characters' worth at least); 2 the pill
#   goes to a row of its own under the first (cut to that row only when even it is too narrow), the label
#   cut to what is left. A mode button left less than the menu button's width takes the fast mark's room,
#   then the pie's. Without room for the dot and two characters' worth of label the dot goes. lsb: the
#   label as shown, psb2: the pill's whole text, psb3: as shown
layout:
    PROLOGUE
    mov rbx, rdi                # phase 4 task 3: the "+" on the first row; at stage 2 on the pill's row
    mov r12d, esi
    call sel_measure            # phase 4 task 8: the selection chip's room (fl_res), kept left of the menu
    mov dword ptr [rip + fl_arow], 1   #   button; the whole chip at stage 0, the icon and its x at the others,
    mov rdi, rbx                #   none when even that squeezes the mode button under a square
    mov esi, r12d
    call layout_pass
    cmp dword ptr [rip + fl_res], 0
    je 2f
    cmp dword ptr [rip + fl_stage], 0
    je 1f
    mov eax, [rip + fl_res1]
    mov [rip + fl_res], eax
    mov dword ptr [rip + fl_sst], 1
    mov rdi, rbx
    mov esi, r12d
    call layout_pass
1:  cmp dword ptr [rip + fl_mw], 0
    je 2f
    mov eax, [rip + fl_mw]
    cmp eax, [rip + fl_row]
    jge 2f
    mov dword ptr [rip + fl_res], 0
    mov rdi, rbx
    mov esi, r12d
    call layout_pass
2:  cmp dword ptr [rip + fl_stage], 2
    jne 9f
    cmp dword ptr [rip + fl_aw], 0
    je 9f
    cmp dword ptr [rip + fl_pw], 0
    je 9f
    mov dword ptr [rip + fl_arow], 2
    mov rdi, rbx
    mov esi, r12d
    call layout_pass
9:  call sel_place              # phase 4 task 8
    EPILOGUE

# layout_pass(AS* or 0, w): layout with the "+" on row fl_arow (2: the stage is 2, the "+" before the pill)
layout_pass:
    PROLOGUE 48
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
    sub r13d, [rip + fl_res]    # (phase 4 task 8: the selection chip's room, left of the menu button)
    mov rdi, rbx                # what comes and goes: fl_hfast, fl_hctx, fl_cstate (csb)
    call extras
    xor eax, eax                # the clock's width
    cmp dword ptr [rip + fl_cstate], CACHE_NONE
    je 1f
    mov eax, [rip + g_pmt + 4*MI_6]
    shl eax, 1
    add eax, [rip + g_pmt + 4*MI_16]
    cmp dword ptr [rip + fl_cstate], CACHE_WARM
    jne 1f
    mov [rsp + 40], eax
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rip + csb + SB_ptr]
    mov rdx, [rip + csb + SB_len]
    call text_width
    add eax, [rsp + 40]
    add eax, [rip + g_pmt + 4*MI_4]
1:  mov [rip + fl_cw], eax
    mov eax, [rip + fl_row]     # the right limit, without the clock and with it
    add eax, [rip + g_pmt + 4*MI_4]
    mov [rsp + 44], eax         # an extra square and its gap
    mov ecx, r13d
    sub ecx, [rip + g_pmt + 4*MI_8]
    cmp dword ptr [rip + fl_hfast], 0
    je 2f
    sub ecx, eax
2:  cmp dword ptr [rip + fl_hctx], 0
    je 3f
    sub ecx, eax
3:  mov [rsp + 24], ecx         # xr1
    mov edx, [rip + fl_cw]
    test edx, edx
    jz 4f
    sub ecx, edx
    sub ecx, [rip + g_pmt + 4*MI_4]
4:  mov [rsp + 28], ecx         # xr0
    PM r14d, MI_12              # the mode button's left (after the "+", phase 4 task 3)
    mov dword ptr [rip + fl_ax], 0
    mov dword ptr [rip + fl_aw], 0
    mov rdi, rbx
    call foot_drv
    mov [rsp + 32], edx         # (the driver's bits as the UI is told them)
    test rax, rax
    jnz 40f
    mov [rip + fl_nx], eax      # no footer at all (no modes, parts or context): nothing of it
    mov [rip + fl_nw], eax
    mov dword ptr [rsp + 32], 0
40: test edx, DRVC_PARTS
    jz 41f
    mov [rip + fl_ax], r14d     # the "+": MI_20 wide, MI_4 before the mode button (or the pill)
    mov eax, [rip + g_pmt + 4*MI_20]
    mov [rip + fl_aw], eax
    mov dword ptr [rip + fl_ay], 0
    cmp dword ptr [rip + fl_arow], 2
    je 43f
    add r14d, eax
    add r14d, [rip + g_pmt + 4*MI_4]
    jmp 41f
43: mov eax, [rip + fl_row]     # (on the pill's row)
    add eax, [rip + g_pmt + 4*MI_4]
    mov [rip + fl_ay], eax
41: test dword ptr [rsp + 32], DRVC_MODES
    jnz 42f
    xor eax, eax                # no modes: no mode button, label, pill, fast mark, pie or clock
    mov [rip + fl_mx], eax
    mov [rip + fl_mw], eax
    mov [rip + fl_lw], eax
    mov [rip + fl_dot], eax
    mov [rip + fl_pw], eax
    mov [rip + fl_px], eax
    mov [rip + fl_py], eax
    mov [rip + fl_fx], eax
    mov [rip + fl_fw], eax
    mov [rip + fl_ix], eax
    mov [rip + fl_iw], eax
    mov [rip + fl_cx], eax
    mov [rip + fl_cw], eax
    mov [rip + fl_stage], eax
    mov [rip + fl_hfast], eax
    mov [rip + fl_hctx], eax
    lea rdi, [rip + lsb]
    call sb_clear
    lea rdi, [rip + psb3]
    call sb_clear
    EPILOGUE
42: mov [rip + fl_mx], r14d
    mov rdi, rbx
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
    mov ecx, [rip + g_pmt + 4*MI_6]
    imul ecx, ecx, 3
    add ecx, [rip + g_pmt + 4*MI_8]
    add ecx, eax
    mov [rsp + 12], ecx         # the mode button's natural width
    mov dword ptr [rsp + 4], 0  # the pill's natural width (0: none)
    mov rdi, rbx
    call pill_drv
    test rax, rax
    jz 5f
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rip + psb2 + SB_ptr]
    mov rdx, [rip + psb2 + SB_len]
    call text_width
    add eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + 4], eax
5:  mov eax, [rsp + 12]         # all of it on the row: stage 0
    mov ecx, [rsp + 4]
    test ecx, ecx
    jz 6f
    add eax, ecx
    add eax, [rip + g_pmt + 4*MI_4]
6:  mov ecx, [rsp + 28]
    sub ecx, r14d
    mov dword ptr [rip + fl_stage], 0
    mov r13d, [rsp + 12]
    cmp dword ptr [rip + fl_arow], 2    # (the second pass: stage 2 already decided)
    jne 60f
    mov dword ptr [rip + fl_cw], 0
    mov dword ptr [rip + fl_stage], 2
    mov ecx, [rsp + 24]
    sub ecx, r14d
    jmp 7f
60: cmp eax, ecx
    jle .Lly_mode
    mov dword ptr [rip + fl_cw], 0      # the clock goes
    mov dword ptr [rip + fl_stage], 1
    mov ecx, [rsp + 24]
    sub ecx, r14d               # room1
    mov eax, [rsp + 4]
    test eax, eax
    jz 7f
    mov edx, ecx                # the pill at its natural width, the label cut to what it leaves
    sub edx, eax
    sub edx, [rip + g_pmt + 4*MI_4]
    mov eax, [rip + g_pmt + 4*MI_6]
    imul eax, eax, 3
    add eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_16]
    cmp edx, eax
    jl 8f
    mov ecx, edx
    jmp 7f
8:  mov dword ptr [rip + fl_stage], 2   # too little: the pill on a row of its own
7:  cmp r13d, ecx
    cmovg r13d, ecx
    cmp r13d, [rip + fl_row]    # still less than the menu button: the fast mark's room, then the pie's
    jge .Lly_mode
    cmp dword ptr [rip + fl_hfast], 0
    je 9f
    mov dword ptr [rip + fl_hfast], 0
    add ecx, [rsp + 44]
    mov r13d, [rsp + 12]
    cmp r13d, ecx
    cmovg r13d, ecx
    cmp r13d, [rip + fl_row]
    jge .Lly_mode
9:  cmp dword ptr [rip + fl_hctx], 0
    je .Lly_mode
    mov dword ptr [rip + fl_hctx], 0
    add ecx, [rsp + 44]
    mov r13d, [rsp + 12]
    cmp r13d, ecx
    cmovg r13d, ecx
.Lly_mode:
    cmp r13d, 1
    jge 10f
    mov r13d, 1
10: mov ecx, [rip + g_pmt + 4*MI_6]     # the room besides the label: MI_6, the dot and MI_6, MI_6
    imul ecx, ecx, 3
    add ecx, [rip + g_pmt + 4*MI_8]
    mov dword ptr [rip + fl_dot], 1
    mov eax, r13d
    sub eax, ecx
    cmp eax, [rip + g_pmt + 4*MI_16]    # the dot keeps two characters' worth of label at least
    jge 11f
    mov eax, [rsp]
    add eax, ecx
    cmp eax, r13d               # or the whole label beside it
    jle 11f
    mov dword ptr [rip + fl_dot], 0
    mov ecx, [rip + g_pmt + 4*MI_6]
    shl ecx, 1
11: mov eax, [rip + g_pmt + 4*MI_6]  # the label's x
    cmp dword ptr [rip + fl_dot], 0
    je 12f
    add eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_6]
12: add eax, r14d
    mov [rip + fl_lx], eax
    mov eax, r13d               # the label's room, and the button's width
    sub eax, ecx
    jns 13f
    xor eax, eax
13: mov edx, [rsp]
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
    mov dword ptr [rip + fl_pw], 0      # the pill: after the mode button, or on the row under it
    mov dword ptr [rip + fl_px], 0
    mov dword ptr [rip + fl_py], 0
    mov ecx, [rsp + 4]
    test ecx, ecx
    jz .Lly_right
    mov eax, [rip + fl_mx]
    add eax, [rip + fl_mw]
    add eax, [rip + g_pmt + 4*MI_4]
    cmp dword ptr [rip + fl_stage], 2
    jne 14f
    mov eax, [rip + fl_row]
    add eax, [rip + g_pmt + 4*MI_4]
    mov [rip + fl_py], eax
    mov eax, r14d
    cmp dword ptr [rip + fl_arow], 2    # (after the "+" on that row)
    jne 131f
    add eax, [rip + fl_aw]
    add eax, [rip + g_pmt + 4*MI_4]
131:
    mov edx, [rip + fl_nx]      # that row ends where the menu button does
    add edx, [rip + fl_nw]
    sub edx, eax
    cmp ecx, edx
    cmovg ecx, edx
14: mov [rip + fl_px], eax
    mov [rip + fl_pw], ecx
    sub ecx, [rip + g_pmt + 4*MI_8]
    sub ecx, [rip + g_pmt + 4*MI_8]
    jg 15f
    mov dword ptr [rip + fl_pw], 0
    mov dword ptr [rip + fl_px], 0
    mov dword ptr [rip + fl_py], 0
    jmp .Lly_right
15: mov rdi, [rip + psb2 + SB_ptr]
    mov esi, ecx
    call label_cut2
.Lly_right:                     # right to left from the menu button (and the selection chip: phase 4 task 8)
    mov ecx, [rip + fl_nx]
    sub ecx, [rip + g_pmt + 4*MI_8]
    sub ecx, [rip + fl_res]
    mov edx, [rip + fl_row]
    xor eax, eax
    mov [rip + fl_fx], eax
    mov [rip + fl_fw], eax
    mov [rip + fl_ix], eax
    mov [rip + fl_iw], eax
    mov [rip + fl_cx], eax
    cmp dword ptr [rip + fl_hfast], 0
    je 16f
    sub ecx, edx
    mov [rip + fl_fx], ecx
    mov [rip + fl_fw], edx
    sub ecx, [rip + g_pmt + 4*MI_4]
16: mov eax, [rip + fl_cw]
    test eax, eax
    jz 17f
    sub ecx, eax
    mov [rip + fl_cx], ecx
    sub ecx, [rip + g_pmt + 4*MI_4]
17: cmp dword ptr [rip + fl_hctx], 0
    je 18f
    sub ecx, edx
    mov [rip + fl_ix], ecx
    mov [rip + fl_iw], edx
18: EPILOGUE

# extras(AS* or 0): fl_hfast (fast mode on or cooling down), fl_hctx (the pie: less than half the window
#   left), fl_cstate (CACHE_*) and fl_cmin (a warm cache's minutes left; csb "Nm"), fl_cms (its ms left),
#   fl_pct (the share in use, in percent), from the conversation's live record; fl_force (print-agents-foot
#   every) puts each of them in its stead: bit 1 the fast mark, 2 the pie at 60 %, 4 a warm clock of 60m
extras:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    mov [rip + fl_hfast], eax
    mov [rip + fl_hctx], eax
    mov [rip + fl_cstate], eax
    mov [rip + fl_pct], eax
    lea rdi, [rip + csb]
    call sb_clear
    mov eax, [rip + fl_force]
    test eax, eax
    js 1f
    mov ecx, eax
    and ecx, 1
    mov [rip + fl_hfast], ecx
    mov ecx, eax
    shr ecx, 1
    and ecx, 1
    mov [rip + fl_hctx], ecx
    mov dword ptr [rip + fl_pct], 60
    test eax, 4
    jz 9f
    mov dword ptr [rip + fl_cstate], CACHE_WARM
    mov eax, 60
    mov rdx, 3600000
    jmp 5f
1:  test rbx, rbx
    jz 9f
    mov r12, [rbx + AS_live]
    test r12, r12
    jz 9f
    cmp dword ptr [r12 + AL_fast], FS_OFF
    setne al
    movzx eax, al
    mov [rip + fl_hfast], eax
    lea rdi, [r12 + AL_usage]
    call agent_ctx_used
    test edx, edx
    jz 2f
    mov [rip + fl_pct], eax
    mov rax, [r12 + AL_usage + AGU_used]    # less than half left: used more than half
    shl rax, 1
    cmp rax, [r12 + AL_usage + AGU_window]
    seta al
    movzx eax, al
    mov [rip + fl_hctx], eax
2:  lea rdi, [r12 + AL_usage]
    call agent_cache_state
    mov [rip + fl_cstate], eax
    mov [rip + fl_cms], rdx
    cmp eax, CACHE_WARM
    jne 9f
    lea rax, [rdx + 59999]      # minutes left, rounded up
    mov r13, rdx
    xor edx, edx
    mov ecx, 60000
    div rcx
    mov rdx, r13
5:  mov [rip + fl_cmin], eax
    mov [rip + fl_cms], rdx
    lea rdi, [rip + csb]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rip + csb]
    mov esi, 'm'
    call sb_push_byte
9:  EPILOGUE

# FN agent_ctx_used(AGU*) -> eax the share of the context window in use, in percent (rounded, 100 at most),
#   edx 1 when the window is known
FN agent_ctx_used
    xor eax, eax
    xor edx, edx
    mov rcx, [rdi + AGU_window]
    test rcx, rcx
    jz 9f
    mov rax, [rdi + AGU_used]
    cmp rax, rcx
    jae 1f
    imul rax, rax, 100
    mov r8, rcx
    shr r8, 1
    add rax, r8
    xor edx, edx
    div rcx
    mov edx, 1
    ret
1:  mov eax, 100
    mov edx, 1
9:  ret

# FN agent_cache_state(AGU*) -> eax CACHE_NONE (no clock: no cache written or its lifetime unknown),
#   CACHE_WARM (rdx the ms left, the lifetime at most), CACHE_EXPIRED (rdx idle ms), CACHE_COMPACTED (the
#   conversation was compacted since: rdx idle ms) (the extension's lj, index.js @3601560)
FN agent_cache_state
    push rbx
    mov rbx, rdi
    call time_ms
    mov rcx, rax
    mov rdx, rcx
    sub rdx, [rbx + AGU_cache_at]
    cmp dword ptr [rbx + AGU_cold], CCOLD_COMPACTED
    jne 1f
    mov eax, CACHE_COMPACTED
    pop rbx
    ret
1:  xor eax, eax
    cmp qword ptr [rbx + AGU_cache_at], 0
    je 9f
    mov r8, [rbx + AGU_cache_ttl]
    test r8, r8
    jz 9f
    mov rax, [rbx + AGU_cache_at]
    add rax, r8
    sub rax, rcx                # ms left
    cmp rax, r8
    cmovg rax, r8
    test rax, rax
    jle 2f
    mov rdx, rax
    mov eax, CACHE_WARM
    pop rbx
    ret
2:  mov eax, CACHE_EXPIRED     # rdx: idle since it was written
9:  pop rbx
    ret

# label_cut(cstr, maxw): lsb = the text when it fits in maxw (the small face), else as much as fits with "…"
#   after it, nothing when not even "…" does
label_cut:
    lea rdx, [rip + lsb]
    jmp cut_into
# label_cut2(cstr, maxw): the same into psb3 (the pill's text as shown)
label_cut2:
    lea rdx, [rip + psb3]
# cut_into(cstr, maxw, sb)
cut_into:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    mov r15, rdx
    mov rdi, rdx
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
    mov rdi, r15
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
    mov rdi, r15
    mov rsi, [rip + bsb + SB_ptr]
    mov rdx, [rip + bsb + SB_len]
    call sb_push
9:  mov rdi, r15
    xor esi, esi
    call sb_push_byte
    dec qword ptr [r15 + SB_len]
    EPILOGUE

# fast_state(AS* or 0) -> eax its program's fast mode (FS_*), FS_OFF without a live record
fast_state:
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 9f
    mov eax, [rcx + AL_fast]
9:  ret

# pill_drv(AS* or 0) -> rax the box's driver when it has models (DRVC_MODELS: the pill shows), else 0;
#   psb2 = the pill's text: the model's name ("Model" without one), " · " and the effort level in effect,
#   " · Ultracode" while it is on (webview index.js @5758398). Reads nothing: the record as it is
pill_drv:
    PROLOGUE
    mov rbx, rdi
    mov qword ptr [rip + pill_name], 0
    lea rdi, [rip + psb2]
    call sb_clear
    mov rdi, rbx
    call foot_drv
    test rax, rax
    jz 8f
    test dword ptr [rax + DRV_caps], DRVC_MODELS
    jz 8f
    mov r15, rax
    mov edi, [rax + DRV_kind]
    call agentcfg_get
    mov r12, rax
    mov rdi, rbx
    mov rsi, rax
    call agentcfg_current
    mov r13, rax                # the model, or 0
    mov [rip + pill_name], rdx
    mov rsi, rdx
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lmodel]
1:  lea rdi, [rip + psb2]
    call sb_push_cstr
    test r13, r13
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call agentcfg_effort
    test rax, rax
    jz 2f
    mov r14, [rax + AEL_label]
    cmp byte ptr [r14], 0
    je 2f
    lea rdi, [rip + psb2]
    lea rsi, [rip + .Lsep]
    call sb_push_cstr
    lea rdi, [rip + psb2]
    mov rsi, r14
    call sb_push_cstr
2:  test rbx, rbx
    jz 3f
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 3f
    cmp dword ptr [rax + AL_ultra], 1
    jne 3f
    lea rdi, [rip + psb2]
    lea rsi, [rip + .Lultra]
    call sb_push_cstr
3:  lea rdi, [rip + psb2]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rip + psb2 + SB_len]
    mov rax, r15
    EPILOGUE
8:  lea rdi, [rip + psb2]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rip + psb2 + SB_len]
    xor eax, eax
    EPILOGUE

# FN foot_draw(AS* or 0, x, y, w): the footer row at y (layout)
FN foot_draw
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov dword ptr [rip + fd_sel], 0     # (phase 4 task 8: drawn below, when it shows)
    mov dword ptr [rip + fd_selx], 0
    call foot_drv
    test rax, rax
    jz 99f
    mov rdi, rbx
    mov esi, [rsp + 8]
    call layout
    mov eax, [rip + fl_stage]
    mov [rip + fd_stage], eax
    mov rdi, rbx                # phase 4 task 3: the "+"
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call add_draw
    cmp dword ptr [rip + fl_mw], 0
    je .Lfd_menu                # a footer without modes: the "+" and the menu's button
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
4:  mov rdi, rbx                # the model pill (layout cut its text)
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call pill_draw
    mov rdi, rbx                # the fast mark
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call fast_draw
    mov rdi, rbx                # the context pie
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call ctx_draw
    mov rdi, rbx                # the prompt cache's clock
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call clock_draw
    # the command menu's button
.Lfd_menu:
    mov r12d, [rsp]
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
    mov eax, [rip + fl_row]
    shr eax, 1
    add eax, [rsp + 4]
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
9:  mov rdi, rbx                # phase 4 task 8: the selection chip
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call sel_draw
99: EPILOGUE

# add_draw(AS* or 0, x, y): the "+" where layout put it (none: fl_aw 0): an icon, lit while hovered, tip "Add";
#   a click opens its menu above it (agatt_plus_menu: Upload from computer, Add context). Phase 4 task 3
add_draw:
    PROLOGUE 16
    mov dword ptr [rip + fd_add], 0
    mov dword ptr [rip + fd_add_y], 0
    cmp dword ptr [rip + fl_aw], 0
    je 9f
    mov r12d, esi
    add r12d, [rip + fl_ax]
    mov r13d, edx
    add r13d, [rip + fl_ay]
    mov edi, ID_AGFOOT + FOOT_ADD
    mov esi, r12d
    mov edx, r13d
    mov ecx, [rip + fl_aw]
    mov r8d, [rip + fl_row]
    call ui_btn
    mov r14d, eax
    mov ecx, [rip + fl_aw]
    shr ecx, 1
    lea eax, [r12 + rcx]
    mov [rip + fd_add], eax
    mov eax, [rip + fl_row]
    shr eax, 1
    add eax, r13d
    mov [rip + fd_add_y], eax
    test r14d, UB_HOVER
    jz 1f
    mov edi, r12d
    mov esi, r13d
    mov edx, [rip + fl_aw]
    mov ecx, [rip + fl_row]
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
1:  PM ecx, MI_16               # the icon, centred
    mov esi, [rip + fl_aw]
    sub esi, ecx
    sar esi, 1
    add esi, r12d
    mov edx, [rip + fl_row]
    sub edx, ecx
    sar edx, 1
    add edx, r13d
    mov edi, IC_PLUS
    COLOR r8d, T_MUTED
    test r14d, UB_HOVER
    jz 2f
    COLOR r8d, T_FG
2:  call icon_draw
    mov edi, ID_AGFOOT + FOOT_ADD
    mov esi, r12d
    mov edx, r13d
    add edx, [rip + fl_row]
    mov ecx, [rip + fl_aw]
    mov r8d, r14d
    lea r9, [rip + .Lt_add]
    call tip_note_text
    test r14d, UB_CLICK
    jz 9f
    mov edi, r12d
    mov esi, r13d
    call agatt_plus_menu
9:  EPILOGUE

# pill_draw(AS* or 0, x, y): the model pill where layout put it (none: fl_pw 0): its text as layout cut it,
#   lit while hovered or while the models picker is open; title "Switch model (NAME)" ("Switch model"
#   without a name); a click opens the models picker, or closes it
pill_draw:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    add edx, [rip + fl_py]      # stage 2: on the row under the first
    mov [rsp + 4], edx
    mov dword ptr [rip + fd_pill], 0
    mov dword ptr [rip + fd_pill_y], 0
    cmp dword ptr [rip + fl_pw], 0
    je 9f
    mov r12d, [rsp]
    add r12d, [rip + fl_px]
    mov edi, ID_AGFOOT + FOOT_PILL
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rip + fl_pw]
    mov r8d, [rip + fl_row]
    call ui_btn
    mov r13d, eax
    mov ecx, [rip + fl_pw]
    shr ecx, 1
    lea eax, [r12 + rcx]
    mov [rip + fd_pill], eax
    mov eax, [rip + fl_row]
    shr eax, 1
    add eax, [rsp + 4]
    mov [rip + fd_pill_y], eax
    mov edi, APP_MODELS
    mov esi, r13d
    call hover_bg
    mov r14d, eax
    mov edi, r12d
    mov esi, [rsp + 4]
    mov edx, [rip + fl_pw]
    call hover_draw
    mov rdi, [rip + ag_fsmall]
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rsp + 4]
    mov ecx, [rip + fl_row]
    mov r8, [rip + psb3 + SB_ptr]
    mov r9, [rip + psb3 + SB_len]
    COLOR eax, T_MUTED
    test r14d, r14d
    jz 1f
    COLOR eax, T_FG
1:  push rax
    push rax
    call ui_text_v
    add rsp, 16
    call pill_title
    mov edi, ID_AGFOOT + FOOT_PILL
    mov esi, r12d
    mov edx, [rsp + 4]
    add edx, [rip + fl_row]
    mov ecx, [rip + fl_pw]
    mov r8d, r13d
    mov r9, [rip + tsb + SB_ptr]
    call tip_note_text
    test r13d, UB_CLICK
    jz 9f
    mov edi, APP_MODELS
    call toggle
9:  EPILOGUE

# pill_title(): tsb = "Switch model (NAME)" with the name pill_drv found, else "Switch model"
pill_title:
    PROLOGUE
    lea rdi, [rip + tsb]
    call sb_clear
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Lt_pill]
    call sb_push_cstr
    mov rbx, [rip + pill_name]
    test rbx, rbx
    jz 1f
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Lt_open]
    call sb_push_cstr
    lea rdi, [rip + tsb]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + tsb]
    mov esi, ')'
    call sb_push_byte
1:  lea rdi, [rip + tsb]
    xor esi, esi
    call sb_push_byte
    EPILOGUE

# fast_draw(AS* or 0, x, y): the fast mark while fast mode is on (the accent) or cooling down (muted): a
#   spark, title "Fast mode enabled" / "Fast mode cooling down" (webview index.js @5837659)
fast_draw:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov dword ptr [rip + fd_fast], 0
    mov dword ptr [rip + fd_fast_y], 0
    cmp dword ptr [rip + fl_fw], 0
    je 9f
    mov r12d, [rsp]
    add r12d, [rip + fl_fx]
    mov edi, ID_AGFOOT + FOOT_FAST
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rip + fl_fw]
    mov r8d, [rip + fl_row]
    call ui_btn
    mov r13d, eax
    mov ecx, [rip + fl_fw]
    shr ecx, 1
    lea eax, [r12 + rcx]
    mov [rip + fd_fast], eax
    mov eax, [rip + fl_row]
    shr eax, 1
    add eax, [rsp + 4]
    mov [rip + fd_fast_y], eax
    mov rdi, rbx
    call fast_state
    mov r14d, eax
    PM ecx, MI_16
    mov esi, [rip + fl_fw]
    sub esi, ecx
    sar esi, 1
    add esi, r12d
    mov edx, [rip + fl_row]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    mov edi, IC_SPARK
    COLOR r8d, T_ACCENT
    cmp r14d, FS_ON
    je 1f
    COLOR r8d, T_MUTED
1:  call icon_draw
    lea r9, [rip + .Lt_fast_on]
    cmp r14d, FS_ON
    je 2f
    lea r9, [rip + .Lt_fast_cool]
2:  mov edi, ID_AGFOOT + FOOT_FAST
    mov esi, r12d
    mov edx, [rsp + 4]
    add edx, [rip + fl_row]
    mov ecx, [rip + fl_fw]
    mov r8d, r13d
    call tip_note_text
9:  EPILOGUE

# ctx_draw(AS* or 0, x, y): the context pie where layout put it (none: fl_iw 0): the share in use as a
#   filled part of a disc; tooltip "N% of context remaining until auto-compact. Click to compact now."
#   (webview index.js @5787140 kFt); a click sends "/compact" as a prompt (held while a turn runs)
ctx_draw:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov dword ptr [rip + fd_ctx], 0
    mov dword ptr [rip + fd_ctx_y], 0
    cmp dword ptr [rip + fl_iw], 0
    je 9f
    mov r12d, [rsp]
    add r12d, [rip + fl_ix]
    mov edi, ID_AGFOOT + FOOT_CTX
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rip + fl_iw]
    mov r8d, [rip + fl_row]
    call ui_btn
    mov r13d, eax
    mov ecx, [rip + fl_iw]
    shr ecx, 1
    lea eax, [r12 + rcx]
    mov [rip + fd_ctx], eax
    mov eax, [rip + fl_row]
    shr eax, 1
    add eax, [rsp + 4]
    mov [rip + fd_ctx_y], eax
    xor eax, eax
    test r13d, UB_HOVER
    setnz al
    mov edi, r12d
    mov esi, [rsp + 4]
    mov edx, [rip + fl_iw]
    call hover_draw
    PM ecx, MI_16               # the disc
    mov edi, [rip + fl_iw]
    sub edi, ecx
    sar edi, 1
    add edi, r12d
    mov esi, [rip + fl_row]
    sub esi, ecx
    sar esi, 1
    add esi, [rsp + 4]
    mov edx, ecx
    mov ecx, [rip + fl_pct]
    call pie_draw
    lea rdi, [rip + tsb]        # its tooltip
    call sb_clear
    lea rdi, [rip + tsb]
    mov esi, 100
    sub esi, [rip + fl_pct]
    call sb_push_u64
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Lt_ctx]
    call sb_push_cstr
    lea rdi, [rip + tsb]
    xor esi, esi
    call sb_push_byte
    mov edi, ID_AGFOOT + FOOT_CTX
    mov esi, r12d
    mov edx, [rsp + 4]
    add edx, [rip + fl_row]
    mov ecx, [rip + fl_iw]
    mov r8d, r13d
    mov r9, [rip + tsb + SB_ptr]
    call tip_note_text
    test rbx, rbx
    jz 9f
    test r13d, UB_CLICK
    jz 9f
    mov rdi, rbx                # one at a time: nothing while a /compact of this conversation (the pie's or
    lea rsi, [rip + .Lv_compact]    #   typed) waits for a start, is held or runs (agent_pending)
    call agent_pending
    test eax, eax
    jnz 9f
    mov rdi, rbx                # compact now: a prompt, as if typed
    lea rsi, [rip + .Lv_compact]
    mov edx, 8
    call agent_send
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# pie_draw(x, y, d, percent): a disc d wide at x, y: the part in use from 12 o'clock clockwise in the warning
#   colour, the rest muted
pie_draw:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov r12d, edx               # d
    mov r13d, ecx
    cmp r13d, 100
    jbe 1f
    mov r13d, 100
1:  mov r14d, r12d              # (2r)^2, in half pixels
    imul r14d, r12d
    lea rax, [rip + pie_dirs]
    movsx ecx, word ptr [rax + r13*4]
    mov [rsp + 8], ecx          # the boundary: sin, cos (x 1024)
    movsx ecx, word ptr [rax + r13*4 + 2]
    mov [rsp + 12], ecx
    xor r15d, r15d              # row
2:  cmp r15d, r12d
    jae 9f
    xor ebx, ebx                # column
3:  cmp ebx, r12d
    jae 8f
    lea eax, [rbx + rbx]        # dx, dy in half pixels from the centre (y up)
    sub eax, r12d
    inc eax
    mov [rsp + 16], eax
    lea ecx, [r15 + r15]
    sub ecx, r12d
    inc ecx
    neg ecx
    mov [rsp + 20], ecx
    imul eax, eax
    imul ecx, ecx
    add eax, ecx
    cmp eax, r14d
    jg 7f                       # outside the disc
    mov ecx, r12d               # its rim, half covered
    dec ecx
    imul ecx, ecx
    mov edx, 255
    cmp eax, ecx
    jle 4f
    mov edx, 128
4:  mov [rsp + 24], edx
    mov edi, [rsp + 16]
    mov esi, [rsp + 20]
    mov edx, r13d
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call in_part
    mov edi, [rsp]
    add edi, ebx
    mov esi, [rsp + 4]
    add esi, r15d
    test eax, eax
    jz 5f
    COLOR edx, T_WARNING
    mov ecx, [rsp + 24]
    call gfx_blend_px
    jmp 7f
5:  COLOR edx, T_MUTED
    mov ecx, [rsp + 24]
    shr ecx, 2
    call gfx_blend_px
7:  inc ebx
    jmp 3b
8:  inc r15d
    jmp 2b
9:  EPILOGUE

# in_part(dx, dy (y up), percent, sin, cos of the boundary x 1024) -> eax 1 when the point's angle from 12
#   o'clock, clockwise, is under the percent's
in_part:
    xor eax, eax
    test edx, edx
    jz 9f
    mov eax, 1
    cmp edx, 100
    jae 9f
    xor r9d, r9d                # its half: 0 the right one (from 12 to 6 o'clock), 1 the left
    test edi, edi
    jg 1f
    jl 2f
    test esi, esi
    jg 1f
2:  mov r9d, 1
1:  xor r10d, r10d
    cmp edx, 50
    jb 3f
    mov r10d, 1
3:  cmp r9d, r10d
    je 4f
    setb al                     # different halves: in it when the point's comes first
    movzx eax, al
    ret
4:  imul edi, r8d               # the same half: dx cos - dy sin < 0
    imul esi, ecx
    sub edi, esi
    xor eax, eax
    test edi, edi
    sets al
9:  ret

# clock_draw(AS* or 0, x, y): the prompt cache's clock where layout put it (none: fl_cw 0): an icon and "Nm"
#   while warm, the icon dimmed once cold; tooltip "Prompt cache warm, about N min left.", "Prompt cache
#   likely expired (idle 5m).", "Prompt cache does not cover the compacted conversation." (webview index.js
#   @3601560 HUe, BUe). While warm the panel redraws it the second its minutes change (agents_label_due):
#   no timer of its own, none at all once it is not drawn
clock_draw:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov dword ptr [rip + fd_cache], 0
    mov dword ptr [rip + fd_cache_y], 0
    cmp dword ptr [rip + fl_cw], 0
    je 9f
    mov r12d, [rsp]
    add r12d, [rip + fl_cx]
    mov edi, ID_AGFOOT + FOOT_CACHE
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rip + fl_cw]
    mov r8d, [rip + fl_row]
    call ui_btn
    mov r13d, eax
    mov ecx, [rip + fl_cw]
    shr ecx, 1
    lea eax, [r12 + rcx]
    mov [rip + fd_cache], eax
    mov eax, [rip + fl_row]
    shr eax, 1
    add eax, [rsp + 4]
    mov [rip + fd_cache_y], eax
    COLOR r14d, T_MUTED
    cmp dword ptr [rip + fl_cstate], CACHE_WARM
    je 1f
    COLOR edi, T_PANEL
    mov esi, r14d
    mov edx, 55
    call color_mix
    mov r14d, eax
1:  PM ecx, MI_16
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, [rip + fl_row]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    mov edi, IC_F_CLOCK
    mov r8d, r14d
    call icon_draw
    cmp dword ptr [rip + fl_cstate], CACHE_WARM
    jne 2f
    mov rdi, [rip + ag_fsmall]  # its minutes
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_6]
    add esi, [rip + g_pmt + 4*MI_16]
    add esi, [rip + g_pmt + 4*MI_4]
    mov edx, [rsp + 4]
    mov ecx, [rip + fl_row]
    mov r8, [rip + csb + SB_ptr]
    mov r9, [rip + csb + SB_len]
    push r14
    push r14
    call ui_text_v
    add rsp, 16
    cmp dword ptr [rip + fl_force], 0
    jge 2f
    mov eax, [rip + fl_cmin]    # the second its minutes change: ms left past the minute below
    dec eax
    imul rax, rax, 60000
    mov rcx, [rip + fl_cms]
    sub rcx, rax
    add rcx, 999
    mov rax, rcx
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov r15, rax
    call time_now
    lea rdi, [rax + r15]
    call agents_label_due
2:  call clock_tip
    mov edi, ID_AGFOOT + FOOT_CACHE
    mov esi, r12d
    mov edx, [rsp + 4]
    add edx, [rip + fl_row]
    mov ecx, [rip + fl_cw]
    mov r8d, r13d
    mov r9, [rip + tsb + SB_ptr]
    call tip_note_text
9:  EPILOGUE

# clock_tip(): tsb = the clock's tooltip in its state (fl_cstate, fl_cmin, fl_cms)
clock_tip:
    PROLOGUE
    lea rdi, [rip + tsb]
    call sb_clear
    mov eax, [rip + fl_cstate]
    cmp eax, CACHE_WARM
    jne 1f
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Lt_warm]
    call sb_push_cstr
    lea rdi, [rip + tsb]
    mov esi, [rip + fl_cmin]
    call sb_push_u64
    lea rsi, [rip + .Lt_warm_tail]
    jmp 8f
1:  lea rsi, [rip + .Lt_compacted]
    cmp eax, CACHE_COMPACTED
    je 8f
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Lt_expired]
    call sb_push_cstr
    mov rdi, [rip + fl_cms]     # BUe: "Nm", "Nh Nm", "Nd Nh"
    lea rsi, [rip + tsb]
    call idle_words
    lea rsi, [rip + .Lt_expired_tail]
8:  lea rdi, [rip + tsb]
    call sb_push_cstr
    lea rdi, [rip + tsb]
    xor esi, esi
    call sb_push_byte
    EPILOGUE

# idle_words(ms, sb): "5m" under an hour, "2h 5m" under a day, else "3d 2h"
idle_words:
    PROLOGUE
    mov r12, rsi
    mov rax, rdi
    test rax, rax
    jns 1f
    xor eax, eax
1:  xor edx, edx
    mov ecx, 60000
    div rcx
    mov rbx, rax                # minutes
    cmp rbx, 60
    jae 2f
    mov rdi, r12
    mov rsi, rbx
    call sb_push_u64
    mov esi, 'm'
    jmp 8f
2:  mov rax, rbx
    xor edx, edx
    mov ecx, 60
    div rcx
    mov r13, rax                # hours
    mov r14, rdx
    cmp r13, 24
    jae 3f
    mov rdi, r12
    mov rsi, r13
    call sb_push_u64
    lea rsi, [rip + .Lt_h_sp]
    mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r14
    call sb_push_u64
    mov esi, 'm'
    jmp 8f
3:  mov rax, r13
    xor edx, edx
    mov ecx, 24
    div rcx
    mov r14, rdx
    mov rdi, r12
    mov rsi, rax
    call sb_push_u64
    lea rsi, [rip + .Lt_d_sp]
    mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r14
    call sb_push_u64
    mov esi, 'h'
8:  mov rdi, r12
    call sb_push_byte
    EPILOGUE

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

# FN foot_dump(sb, esi every): print-agents-foot (see the top of the file); the setting is the user's again
#   after it. every: the layout lines once for each combination of the extras (combo= bits: 1 the fast mark,
#   2 the context pie, 4 a warm cache clock of "60m"), the conversation's own ones not looked at
FN foot_dump
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp + 36], esi
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
    lea rsi, [rip + .Ld_pill_at]
    lea rdx, [rip + fd_pill]
    call put_at
    mov rdi, rbx
    lea rsi, [rip + .Ld_fast_at]
    lea rdx, [rip + fd_fast]
    call put_at
    mov rdi, rbx
    lea rsi, [rip + .Ld_ctx_at]
    lea rdx, [rip + fd_ctx]
    call put_at
    mov rdi, rbx
    lea rsi, [rip + .Ld_cache_at]
    lea rdx, [rip + fd_cache]
    call put_at
    mov rdi, rbx                # phase 4 task 3
    lea rsi, [rip + .Ld_add_at]
    lea rdx, [rip + fd_add]
    call put_at
    mov rdi, rbx
    lea rsi, [rip + .Ld_fast]
    call sb_push_cstr
    mov rdi, r15
    call fast_state
    cmp eax, FS_COOLDOWN
    jbe 2f
    xor eax, eax
2:  lea rcx, [rip + fast_words]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx                # the clock as it would show now: "Nm", cold, or none
    lea rsi, [rip + .Ld_clock]
    call sb_push_cstr
    mov rdi, r15
    call extras
    mov eax, [rip + fl_cstate]
    cmp eax, CACHE_WARM
    jne 21f
    mov rdi, rbx
    mov rsi, [rip + csb + SB_ptr]
    mov rdx, [rip + csb + SB_len]
    call sb_push
    jmp 23f
21: lea rsi, [rip + .Ld_dash]
    cmp eax, CACHE_NONE
    je 22f
    lea rsi, [rip + .Ld_cold]
22: mov rdi, rbx
    call sb_push_cstr
23: mov rdi, rbx
    lea rsi, [rip + .Ld_stage]
    mov edx, [rip + fd_stage]
    call put_num
    lea rsi, [rip + .Ld_label]
    call sb_push_cstr
    mov rdi, r12
    call mode_label
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r15                # the pill's whole text and its title (a tab before each)
    call pill_drv
    mov rdi, rbx
    lea rsi, [rip + .Ld_pill]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + psb2 + SB_ptr]
    mov rdx, [rip + psb2 + SB_len]
    call sb_push
    call pill_title
    mov rdi, rbx
    lea rsi, [rip + .Ld_title]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + tsb + SB_ptr]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    mov dword ptr [rsp + 40], 0 # the combination
    cmp dword ptr [rsp + 36], 0
    je .Lfd_combo
    mov dword ptr [rip + fl_force], 0
.Lfd_combo:
    mov dword ptr [rsp + 4], 8  # size
.Lfd_size:
    cmp dword ptr [rsp + 4], 32
    ja .Lfd_next_combo
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
    lea rsi, [rip + .Ld_pill_x]
    mov edx, [rip + fl_px]
    call put_num
    lea rsi, [rip + .Ld_pill_y]
    mov edx, [rsp + 28]
    add edx, [rip + fl_py]
    call put_num
    lea rsi, [rip + .Ld_pill_w]
    mov edx, [rip + fl_pw]
    call put_num
    lea rsi, [rip + .Ld_pill_h]
    mov edx, [rip + fl_row]
    call put_num
    mov rdi, [rip + ag_fsmall]  # the pill's text as shown: its width
    mov rsi, [rip + psb3 + SB_ptr]
    mov rdx, [rip + psb3 + SB_len]
    xor eax, eax
    cmp dword ptr [rip + fl_pw], 0
    je 3f
    call text_width
3:  mov edx, eax
    mov rdi, rbx
    lea rsi, [rip + .Ld_pill_text]
    call put_num
    lea rsi, [rip + .Ld_fast_x]
    mov edx, [rip + fl_fx]
    call put_num
    lea rsi, [rip + .Ld_fast_y]
    mov edx, [rsp + 28]
    call put_num
    lea rsi, [rip + .Ld_fast_w]
    mov edx, [rip + fl_fw]
    call put_num
    lea rsi, [rip + .Ld_fast_h]
    mov edx, [rip + fl_row]
    call put_num
    lea rsi, [rip + .Ld_ctx_x]
    mov edx, [rip + fl_ix]
    call put_num
    lea rsi, [rip + .Ld_ctx_y]
    mov edx, [rsp + 28]
    call put_num
    lea rsi, [rip + .Ld_ctx_w]
    mov edx, [rip + fl_iw]
    call put_num
    lea rsi, [rip + .Ld_ctx_h]
    mov edx, [rip + fl_row]
    call put_num
    lea rsi, [rip + .Ld_cache_x]
    mov edx, [rip + fl_cx]
    call put_num
    lea rsi, [rip + .Ld_cache_y]
    mov edx, [rsp + 28]
    call put_num
    lea rsi, [rip + .Ld_cache_w]
    mov edx, [rip + fl_cw]
    call put_num
    lea rsi, [rip + .Ld_cache_h]
    mov edx, [rip + fl_row]
    call put_num
    lea rsi, [rip + .Ld_add_x]  # phase 4 task 3: the "+"
    mov edx, [rip + fl_ax]
    call put_num
    lea rsi, [rip + .Ld_add_y]
    mov edx, [rsp + 28]
    add edx, [rip + fl_ay]
    call put_num
    lea rsi, [rip + .Ld_add_w]
    mov edx, [rip + fl_aw]
    call put_num
    lea rsi, [rip + .Ld_add_h]
    mov edx, [rip + fl_row]
    call put_num
    lea rsi, [rip + .Ld_stage]
    mov edx, [rip + fl_stage]
    call put_num
    cmp dword ptr [rsp + 36], 0
    je 4f
    lea rsi, [rip + .Ld_combo]
    mov edx, [rsp + 40]
    call put_num
4:  lea rsi, [rip + .Ld_label]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + lsb + SB_ptr]
    mov rdx, [rip + lsb + SB_len]
    call sb_push
    mov rdi, rbx
    lea rsi, [rip + .Ld_pill_shown]
    call sb_push_cstr
    cmp dword ptr [rip + fl_pw], 0
    je 5f
    mov rdi, rbx
    mov rsi, [rip + psb3 + SB_ptr]
    mov rdx, [rip + psb3 + SB_len]
    call sb_push
5:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add dword ptr [rsp + 8], 20
    jmp .Lfd_w
.Lfd_next:
    inc dword ptr [rsp + 4]
    jmp .Lfd_size
.Lfd_next_combo:
    cmp dword ptr [rsp + 36], 0
    je .Lfd_done
    inc dword ptr [rsp + 40]
    mov eax, [rsp + 40]
    cmp eax, 8
    jae .Lfd_done
    mov [rip + fl_force], eax
    jmp .Lfd_combo
.Lfd_done:
    mov dword ptr [rip + fl_force], -1
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

# ---- phase 4 task 8: the selection chip ----

# sel_measure(AS* or 0): the selection chip's widths (agentctx.s's label for that conversation): fl_res the room
#   it takes at stage 0 (MI_6, an icon, MI_4, the label cut with "…" at MI_120, MI_4, its x, MI_2, and MI_4 before
#   the menu button), fl_res1 the icon and its x alone; both 0 without a chip. ssb the label as shown
sel_measure:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    mov [rip + fl_res], eax
    mov [rip + fl_res1], eax
    mov [rip + fl_sw], eax
    mov [rip + fl_slw], eax
    mov [rip + fl_sst], eax
    lea rdi, [rip + ssb]
    call sb_clear
    mov rdi, rbx
    call foot_drv
    test rax, rax
    jz 9f
    call agctx_sync
    mov rdi, rbx
    call agctx_label
    test rax, rax
    jz 9f
    mov r15, rax
    mov r12d, [rip + g_pmt + 4*MI_6]    # the icon and the x
    add r12d, [rip + g_pmt + 4*MI_14]
    add r12d, [rip + g_pmt + 4*MI_4]
    add r12d, [rip + g_pmt + 4*MI_16]
    add r12d, [rip + g_pmt + 4*MI_2]
    mov eax, [rip + g_pmt + 4*MI_40]    # the label at most MI_120
    imul eax, eax, 3
    mov rdi, r15
    mov esi, eax
    lea rdx, [rip + ssb]
    call cut_into
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rip + ssb + SB_ptr]
    mov rdx, [rip + ssb + SB_len]
    call text_width
    mov [rip + fl_slw], eax
    lea ecx, [r12 + rax]
    add ecx, [rip + g_pmt + 4*MI_4]
    add ecx, [rip + g_pmt + 4*MI_4]
    mov [rip + fl_res], ecx
    add r12d, [rip + g_pmt + 4*MI_4]
    mov [rip + fl_res1], r12d
9:  EPILOGUE

# sel_place(): where the chip goes: its right edge MI_4 before the menu button, its width the room layout kept
sel_place:
    mov dword ptr [rip + fl_sw], 0
    mov eax, [rip + fl_res]
    test eax, eax
    jz 9f
    cmp dword ptr [rip + fl_nw], 0
    je 9f
    sub eax, [rip + g_pmt + 4*MI_4]
    mov [rip + fl_sw], eax
    mov ecx, [rip + fl_nx]
    sub ecx, [rip + g_pmt + 4*MI_4]
    sub ecx, eax
    mov [rip + fl_sx], ecx
9:  ret

# sel_draw(AS* or 0, x, y): the chip where sel_layout put it: a button (its tip "Showing … (LABEL)") with the
#   icon and the label, then its x ("Remove from message", a hit area of MI_16): the chip goes for that
#   conversation until the selection changes
sel_draw:
    PROLOGUE 32
    mov rbx, rdi
    cmp dword ptr [rip + fl_sw], 0
    je 9f
    mov r12d, esi
    add r12d, [rip + fl_sx]
    mov r13d, edx
    mov r14d, [rip + fl_sw]     # the chip without its x
    sub r14d, [rip + g_pmt + 4*MI_16]
    sub r14d, [rip + g_pmt + 4*MI_2]
    mov edi, ID_AGFOOT + FOOT_SEL
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8d, [rip + fl_row]
    call ui_btn
    mov [rsp], eax
    mov edi, r12d               # its face: a quiet round box
    mov esi, r13d
    mov edx, [rip + fl_sw]
    mov ecx, [rip + fl_row]
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
    mov eax, r14d
    shr eax, 1
    add eax, r12d
    mov [rip + fd_sel], eax
    mov eax, [rip + fl_row]
    shr eax, 1
    add eax, r13d
    mov [rip + fd_sel_y], eax
    PM ecx, MI_14               # the icon
    mov edx, [rip + fl_row]
    sub edx, ecx
    sar edx, 1
    add edx, r13d
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_6]
    mov edi, IC_FILE
    COLOR r8d, T_MUTED
    call icon_draw
    cmp dword ptr [rip + fl_sst], 0
    jne 1f
    mov rdi, [rip + ag_fsmall]  # the label
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_6]
    add esi, [rip + g_pmt + 4*MI_14]
    add esi, [rip + g_pmt + 4*MI_4]
    mov edx, r13d
    mov ecx, [rip + fl_row]
    mov r8, [rip + ssb + SB_ptr]
    mov r9, [rip + ssb + SB_len]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
1:  lea rdi, [rip + ssb2]       # the chip's tip
    call sb_clear
    lea rdi, [rip + ssb2]
    mov rsi, rbx
    call agctx_tip
    mov edi, ID_AGFOOT + FOOT_SEL
    mov esi, r12d
    mov edx, r13d
    add edx, [rip + fl_row]
    mov ecx, r14d
    mov r8d, [rsp]
    mov r9, [rip + ssb2 + SB_ptr]
    call tip_note_text
    mov r15d, r12d              # its x
    add r15d, r14d
    PM ecx, MI_16
    mov [rsp + 8], ecx
    mov edi, ID_AGFOOT + FOOT_SELX
    mov esi, r15d
    mov edx, [rip + fl_row]
    sub edx, ecx
    sar edx, 1
    add edx, r13d
    mov [rsp + 12], edx
    mov r8d, ecx
    call ui_btn
    mov [rsp + 4], eax
    mov eax, [rsp + 8]
    shr eax, 1
    lea ecx, [r15 + rax]
    mov [rip + fd_selx], ecx
    add eax, [rsp + 12]
    mov [rip + fd_selx_y], eax
    test dword ptr [rsp + 4], UB_HOVER
    jz 2f
    mov edi, r15d
    mov esi, [rsp + 12]
    mov edx, [rsp + 8]
    mov ecx, edx
    PM r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    call gfx_round_rect
2:  mov edi, IC_CLOSE
    mov esi, r15d
    mov edx, [rsp + 12]
    COLOR r8d, T_MUTED
    test dword ptr [rsp + 4], UB_HOVER
    jz 3f
    COLOR r8d, T_FG
3:  call icon_draw
    mov edi, ID_AGFOOT + FOOT_SELX
    mov esi, r15d
    mov edx, [rsp + 12]
    add edx, [rsp + 8]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 4]
    lea r9, [rip + .Lt_sel_remove]
    call tip_note_text
    test dword ptr [rsp + 4], UB_CLICK
    jz 9f
    mov rdi, rbx
    call agctx_dismiss
9:  EPILOGUE

# FN foot_sel_dump(sb): "at=X,Y x=X,Y stage=N shown=LABEL" of the selection chip as drawn last (0,0: not drawn),
#   for print-agent-context
FN foot_sel_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_sel_at]
    lea rdx, [rip + fd_sel]
    call put_at
    mov rdi, rbx
    lea rsi, [rip + .Ld_selx_at]
    lea rdx, [rip + fd_selx]
    call put_at
    mov rdi, rbx
    lea rsi, [rip + .Ld_sel_stage]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + fl_sst]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_sel_shown]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + ssb + SB_ptr]
    mov rdx, [rip + ssb + SB_len]
    test rsi, rsi
    jz 1f
    call sb_push
1:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# FN foot_sel_fit(sb): the chip at every panel size 8 to 32 and width 240 to 900 (step 20): "size=S w=W x=X
#   cw=W stage=N left=L right=R label=LW" (x and the row's parts from the panel's left, cw 0: not shown; L the
#   end of what the row holds at its left, R the start of its right group)
FN foot_sel_fit
    PROLOGUE 32
    mov rbx, rdi
    call agentext_box_owner
    mov r15, rax
    mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    mov dword ptr [rsp + 4], 8
1:  cmp dword ptr [rsp + 4], 32
    ja 8f
    mov eax, [rsp + 4]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    mov dword ptr [rsp + 8], 240
2:  cmp dword ptr [rsp + 8], 900
    ja 7f
    mov rdi, r15
    mov esi, [rsp + 8]
    call layout
    lea r12, [rip + sf_words]
    lea r13, [rsp + 4]
    mov rdi, rbx
    lea rsi, [rip + .Ls_size]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rsp + 4]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ls_w]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rsp + 8]
    call sb_push_u64
    lea r14, [rip + sf_vals]
3:  mov rsi, [r12]
    test rsi, rsi
    jz 4f
    mov rdi, rbx
    call sb_push_cstr
    mov rax, [r14]
    mov esi, [rax]
    mov rdi, rbx
    call sb_push_u64
    add r12, 8
    add r14, 8
    jmp 3b
4:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add dword ptr [rsp + 8], 20
    jmp 2b
7:  inc dword ptr [rsp + 4]
    jmp 1b
8:  mov eax, [rsp]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    EPILOGUE

.section .rodata
.Lt_sel_remove: .asciz "Remove from message"      # phase 4 task 8
.Ld_sel_at: .asciz " at="
.Ld_selx_at: .asciz " x="
.Ld_sel_stage: .asciz " stage="
.Ld_sel_shown: .asciz " shown="
.Ls_size: .asciz "size="
.Ls_w: .asciz " w="
.Ls_x: .asciz " x="
.Ls_cw: .asciz " cw="
.Ls_stage: .asciz " stage="
.Ls_mx: .asciz " mode_x="
.Ls_mw: .asciz " mode_w="
.Ls_nx: .asciz " menu_x="
.Ls_lw: .asciz " label="
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
.Ld_link: .asciz "link "
.Lt_agent: .asciz "The agent"
.Ld_drawn: .asciz " drawn="
.Lellipsis: .ascii "\342\200\246"
.Lmode: .asciz "Mode"
.Lslash: .asciz "/"
.Lt_dot: .asciz ". "
.Lt_mode: .asciz "Click to change, or press Shift+Tab to cycle."
.Lt_menu: .asciz "Show command menu (/)"
.Lt_add: .asciz "Add"
.Ld_add_at: .asciz " add_at="
.Ld_add_x: .asciz " add_x="
.Ld_add_y: .asciz " add_y="
.Ld_add_w: .asciz " add_w="
.Ld_add_h: .asciz " add_h="
.Lmodel: .asciz "Model"
.Lsep: .asciz " \302\267 "
.Lultra: .asciz " \302\267 Ultracode"
.Lt_pill: .asciz "Switch model"
.Lt_open: .asciz " ("
.Lt_ctx: .asciz "% of context remaining until auto-compact. Click to compact now."
.Lv_compact: .asciz "/compact"
.Lt_warm: .asciz "Prompt cache warm, about "
.Lt_warm_tail: .asciz " min left."
.Lt_expired: .asciz "Prompt cache likely expired (idle "
.Lt_expired_tail: .asciz ")."
.Lt_compacted: .asciz "Prompt cache does not cover the compacted conversation."
.Lt_h_sp: .asciz "h "
.Lt_d_sp: .asciz "d "
.Lt_fast_on: .asciz "Fast mode enabled"
.Lt_fast_cool: .asciz "Fast mode cooling down"
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
.Ld_pill_at: .asciz " pill_at="
.Ld_fast_at: .asciz " fast_at="
.Ld_fast: .asciz " fast="
.Ld_ctx_at: .asciz " ctx_at="
.Ld_cache_at: .asciz " cache_at="
.Ld_clock: .asciz " clock="
.Ld_cold: .asciz "cold"
.Ld_stage: .asciz " stage="
.Ld_combo: .asciz " combo="
.Ld_pill_shown: .asciz "\tpill="
.Ld_ctx_x: .asciz " ctx_x="
.Ld_ctx_y: .asciz " ctx_y="
.Ld_ctx_w: .asciz " ctx_w="
.Ld_ctx_h: .asciz " ctx_h="
.Ld_cache_x: .asciz " cache_x="
.Ld_cache_y: .asciz " cache_y="
.Ld_cache_w: .asciz " cache_w="
.Ld_cache_h: .asciz " cache_h="
.Ld_pill: .asciz "\tpill="
.Ld_title: .asciz "\ttitle="
.Ld_pill_x: .asciz " pill_x="
.Ld_pill_y: .asciz " pill_y="
.Ld_pill_w: .asciz " pill_w="
.Ld_pill_h: .asciz " pill_h="
.Ld_pill_text: .asciz " pill_text="
.Ld_fast_x: .asciz " fast_x="
.Ld_fast_y: .asciz " fast_y="
.Ld_fast_w: .asciz " fast_w="
.Ld_fast_h: .asciz " fast_h="
.Lf_off: .asciz "off"
.Lf_on: .asciz "on"
.Lf_cool: .asciz "cooldown"
.p2align 3
fast_words: .quad .Lf_off, .Lf_on, .Lf_cool
sf_words: .quad .Ls_x, .Ls_cw, .Ls_stage, .Ls_mx, .Ls_mw, .Ls_nx, .Ls_lw, 0      # phase 4 task 8
sf_vals: .quad fl_sx, fl_sw, fl_sst, fl_mx, fl_mw, fl_nx, fl_slw
pie_dirs:                       # sin, cos (x 1024) of each percent of a turn, 0 to 100
    .short 0, 1024, 64, 1022, 128, 1016, 192, 1006, 255, 992, 316, 974, 377, 952, 436, 927, 493, 897, 549, 865
    .short 602, 828, 653, 789, 701, 746, 746, 701, 789, 653, 828, 602, 865, 549, 897, 493, 927, 436, 952, 377
    .short 974, 316, 992, 255, 1006, 192, 1016, 128, 1022, 64, 1024, 0, 1022, -64, 1016, -128, 1006, -192, 992, -255
    .short 974, -316, 952, -377, 927, -436, 897, -493, 865, -549, 828, -602, 789, -653, 746, -701, 701, -746, 653, -789
    .short 602, -828, 549, -865, 493, -897, 436, -927, 377, -952, 316, -974, 255, -992, 192, -1006, 128, -1016, 64, -1022
    .short 0, -1024, -64, -1022, -128, -1016, -192, -1006, -255, -992, -316, -974, -377, -952, -436, -927, -493, -897, -549, -865
    .short -602, -828, -653, -789, -701, -746, -746, -701, -789, -653, -828, -602, -865, -549, -897, -493, -927, -436, -952, -377
    .short -974, -316, -992, -255, -1006, -192, -1016, -128, -1022, -64, -1024, 0, -1022, 64, -1016, 128, -1006, 192, -992, 255
    .short -974, 316, -952, 377, -927, 436, -897, 493, -865, 549, -828, 602, -789, 653, -746, 701, -701, 746, -653, 789
    .short -602, 828, -549, 865, -493, 897, -436, 927, -377, 952, -316, 974, -255, 992, -192, 1006, -128, 1016, -64, 1022
    .short 0, 1024
