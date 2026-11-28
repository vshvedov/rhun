# editor presentation: virtual text. An inlay is text drawn inside a line that is not part of it
# (a decoration's before/after text; later inlay hints, ghost text, fold placeholders, color
# swatches). It sits at a gap between two bytes, on a side: an `after` inlay belongs to the text
# before the gap (typing at the gap lands left of it), a `before` inlay to the text after it.
#
# The grid stays integral: an inlay is a whole number of cells. At one gap the `after` inlays come
# first, then the `before` ones. Positions never fall inside an inlay; the caret at a gap is drawn
# left of all its inlays when an `after` one is there, otherwise right of them, so it touches the
# text it extends. A range [S, E) covers the cells after every inlay at S and before every inlay at
# E (selection, backgrounds, underlines, find matches). On a wrapped line the inlays at a gap go
# with the row of the byte after it (the last row keeps those at the line's end).
#
#   vt_line(doc, line) -> rax items, rdx count     a line's inlays in drawing order (cached)
#   vt_row_set()                                    the row in g_row_* (draw_line): its inlays
#   vt_x(off, mode) -> eax                          x of a gap of the row (VTM_LEFT/RIGHT/CARET)
#   vt_draw_at(off, col, baseline) -> eax col        draws the row's inlays at a gap
#   vt_pos_at(doc, line, px) -> rax pos             the position under a pixel of an unwrapped
#                                                   line (g_vt_hit: the inlay there, or -1)
.include "rhun.inc"

.equ ID_VT_TIP, 0x3c00          # + gap: an inlay's tooltip

.bss
.p2align 3
vt_items: .zero VT_LINE_MAX * VI_SIZE
vt_keys: .zero VT_LINE_MAX * 8
vt_n: .quad 0
vt_kdoc: .quad 0                # what the items were built for
vt_kline: .quad 0
vt_kver: .quad 0
vt_kgen: .quad 0
vt_kdgen: .quad 0
vt_ktheme: .quad 0
vt_kdap: .long 0                # the debugger's generation (inline values)
.p2align 3
vr_i0: .quad 0                  # the row's inlays: items [vr_i0, vr_i1)
vr_i1: .quad 0
vr_next: .quad 0                # vt_draw_at's place in them
.globl g_row_vt
g_row_vt: .quad 0               # the row has inlays (their count)
.globl g_vt_hit, g_vt_widest
g_vt_hit: .quad 0               # vt_pos_at, pos_in_row: the inlay under the point + 1, or 0
g_vt_widest: .long 0            # the widest row drawn this frame, in cells (the scrollbar's extent)
.p2align 3
vt_hit_item: .zero VI_SIZE      # a copy of that inlay
.globl bt_n
bt_items: .quad 0               # the line wrap.s measures: its inlays
bt_n: .quad 0
tmp_vi: .zero VI_SIZE

.text

# ---------------- a line's inlays ----------------

# vt_line(doc, line) -> rax items, rdx count
FN vt_line
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + DOC_pres]
    test r13, r13
    jz .Lvl_none
    cmp [rip + vt_kdoc], rbx
    jne 1f
    cmp [rip + vt_kline], r12
    jne 1f
    mov rax, [rbx + DOC_version]
    cmp [rip + vt_kver], rax
    jne 1f
    mov rax, [r13 + PRS_gen]
    cmp [rip + vt_kgen], rax
    jne 1f
    mov rax, [rip + g_deco_gen]
    cmp [rip + vt_kdgen], rax
    jne 1f
    mov eax, [rip + g_dap_gen]
    cmp [rip + vt_kdap], eax
    jne 1f
    mov eax, [rip + g_theme + 4*T_FG]
    shl rax, 32
    or eax, [rip + g_theme + 4*T_BG]
    cmp [rip + vt_ktheme], rax
    je .Lvl_have
1:  mov [rip + vt_kdoc], rbx
    mov [rip + vt_kline], r12
    mov rax, [rbx + DOC_version]
    mov [rip + vt_kver], rax
    mov rax, [r13 + PRS_gen]
    mov [rip + vt_kgen], rax
    mov rax, [rip + g_deco_gen]
    mov [rip + vt_kdgen], rax
    mov eax, [rip + g_dap_gen]
    mov [rip + vt_kdap], eax
    mov eax, [rip + g_theme + 4*T_FG]
    shl rax, 32
    or eax, [rip + g_theme + 4*T_BG]
    mov [rip + vt_ktheme], rax
    mov qword ptr [rip + vt_n], 0
    # the sources
    mov rdi, rbx
    mov rsi, r12
    call fold_line_inlays       # a folded header's pill (fold.s)
    mov rdi, rbx
    mov rsi, r12
    call deco_line_inlays
    mov rdi, rbx
    mov rsi, r12
    call inlay_line_inlays      # inlay hints (inlay.s)
    mov rdi, rbx
    mov rsi, r12
    call color_line_inlays      # color swatches (hicolor.s)
    mov rdi, rbx
    mov rsi, r12
    call ghost_line_inlays      # inline completion's first line (ghost.s)
    mov rdi, rbx
    mov rsi, r12
    call dg_line_inlays         # the debugger's inline values (debuggutter.s)
.Lvl_have:
    lea rax, [rip + vt_items]
    mov rdx, [rip + vt_n]
    EPILOGUE
.Lvl_none:
    lea rax, [rip + vt_items]
    xor edx, edx
    EPILOGUE

# vt_add(VI*): an inlay for the line vt_line builds (VI_cells 0: its text's width), kept in order
FN vt_add
    PROLOGUE
    mov rbx, rdi
    mov r12, [rip + vt_n]
    cmp r12, VT_LINE_MAX
    jae 9f
    # its width
    cmp dword ptr [rbx + VI_cells], 0
    jne 1f
    mov rdi, [rbx + VI_text]
    xor esi, esi
    mov edx, [rbx + VI_len]
    call seg_cols
    mov [rbx + VI_cells], eax
    test eax, eax
    jz 9f                       # nothing to draw
1:  # its order: the gap, the side (after first), the kind's rank, the priority
    mov r13, [rbx + VI_off]
    shl r13, 20
    movzx eax, byte ptr [rbx + VI_kind]
    movzx ecx, byte ptr [rbx + VI_side]
    mov edx, [rbx + VI_prio]
    and edx, 255
    test ecx, ecx
    jnz 2f
    mov r8d, 255                # after: the higher priority nearer the text
    sub r8d, edx
    mov edx, r8d
    jmp 3f
2:  lea r8, [rip + before_rank]
    movzx eax, byte ptr [r8 + rax]
3:  shl ecx, 19
    shl eax, 16
    shl edx, 8
    or r13, rcx
    or r13, rax
    or r13, rdx
    mov rax, r12
    and eax, 255
    or r13, rax
    # insertion: later items move up
    mov r14, r12
4:  test r14, r14
    jz 5f
    lea rax, [rip + vt_keys]
    cmp [rax + r14*8 - 8], r13
    jbe 5f
    mov rcx, [rax + r14*8 - 8]
    mov [rax + r14*8], rcx
    imul rsi, r14, VI_SIZE
    lea rdi, [rip + vt_items]
    add rsi, rdi
    lea rdi, [rsi]
    sub rsi, VI_SIZE
    mov edx, VI_SIZE
    call memcpy
    dec r14
    jmp 4b
5:  lea rax, [rip + vt_keys]
    mov [rax + r14*8], r13
    imul rdi, r14, VI_SIZE
    lea rax, [rip + vt_items]
    add rdi, rax
    mov rsi, rbx
    mov edx, VI_SIZE
    call memcpy
    inc qword ptr [rip + vt_n]
9:  EPILOGUE

# vt_has(doc, line) -> eax the line's inlays
FN vt_has
    cmp qword ptr [rdi + DOC_pres], 0
    jne 1f
    xor eax, eax
    ret
1:  sub rsp, 8
    call vt_line
    add rsp, 8
    mov eax, edx
    ret

# ---------------- the row ----------------

# vt_row_set(): the row in g_row_* is being drawn: its inlays
FN vt_row_set
    PROLOGUE
    mov qword ptr [rip + vr_i0], 0
    mov qword ptr [rip + vr_i1], 0
    mov qword ptr [rip + vr_next], 0
    mov qword ptr [rip + g_row_vt], 0
    mov rdi, [rip + g_row_doc]
    cmp qword ptr [rdi + DOC_pres], 0
    je 9f
    mov rsi, [rip + g_row_line]
    call vt_line
    test rdx, rdx
    jz 9f
    mov r12, rax
    mov r13, rdx
    # [from, to) of the row, and the line's end on its last row
    mov r14, [rip + g_row_from]
    mov r15, [rip + g_row_to]
    xor ecx, ecx
1:  cmp rcx, r13
    jae 2f
    imul rax, rcx, VI_SIZE
    cmp [r12 + rax + VI_off], r14
    jae 2f
    inc rcx
    jmp 1b
2:  mov [rip + vr_i0], rcx
    mov [rip + vr_next], rcx
3:  cmp rcx, r13
    jae 4f
    imul rax, rcx, VI_SIZE
    mov rdx, [r12 + rax + VI_off]
    cmp rdx, r15
    jb 31f
    ja 4f
    cmp r15, [rip + g_row_len]  # at the row's end: only on the line's last row
    jne 4f
31: inc rcx
    jmp 3b
4:  mov [rip + vr_i1], rcx
    sub rcx, [rip + vr_i0]
    mov [rip + g_row_vt], rcx
    # the widest row's inlays, for the horizontal scrollbar's extent
    call vt_row_cells
    cmp eax, [rip + g_vt_widest]
    jbe 9f
    mov [rip + g_vt_widest], eax
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# vt_x(off, mode) -> eax x of a gap of the row: the text's columns from the row's start plus the
# cells of the row's inlays before the gap (and those at it, for VTM_RIGHT; for VTM_CARET when no
# `after` inlay is there)
FN vt_x
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    mov rcx, [rip + vr_i0]
    # VTM_CARET: an `after` inlay at the gap puts the caret before them all
    cmp r13d, VTM_CARET
    jne 2f
    mov r13d, VTM_RIGHT
    mov rdx, rcx
1:  cmp rdx, [rip + vr_i1]
    jae 2f
    imul rax, rdx, VI_SIZE
    lea r8, [rip + vt_items]
    add rax, r8
    inc rdx
    cmp [rax + VI_off], r12
    jb 1b
    ja 2f
    cmp byte ptr [rax + VI_side], VS_AFTER
    jne 1b
    mov r13d, VTM_LEFT
2:  # text and inlays in one pass, as drawn: a tab's stop counts the inlays before it
    xor ebx, ebx                # column
    mov r14, [rip + g_row_from] # text measured up to here
    mov r15, rcx
3:  cmp r15, [rip + vr_i1]
    jae 8f
    imul rax, r15, VI_SIZE
    lea r8, [rip + vt_items]
    add rax, r8
    mov rdx, [rax + VI_off]
    cmp rdx, r12
    jb 4f
    ja 8f
    cmp r13d, VTM_RIGHT
    jne 8f
4:  mov rdi, [rip + g_row_text]
    mov rsi, r14
    mov ecx, ebx
    mov r14, rdx
    call seg_cols_from
    mov ebx, eax
    imul rax, r15, VI_SIZE
    lea r8, [rip + vt_items]
    add ebx, [r8 + rax + VI_cells]
    inc r15
    jmp 3b
8:  mov rdi, [rip + g_row_text]
    mov rsi, r14
    mov rdx, r12
    mov ecx, ebx
    call seg_cols_from
    imul eax, [rip + g_cw]
    add eax, [rip + g_row_x]
    EPILOGUE

# vt_draw_at(off, col, baseline) -> eax the column after the row's inlays at the gap (drawn there)
FN vt_draw_at
    PROLOGUE 16
    mov r12, rdi
    mov ebx, esi
    mov [rsp], edx
1:  mov rcx, [rip + vr_next]
    cmp rcx, [rip + vr_i1]
    jae 9f
    imul r13, rcx, VI_SIZE
    lea rax, [rip + vt_items]
    add r13, rax
    cmp [r13 + VI_off], r12
    ja 9f
    inc qword ptr [rip + vr_next]
    jb 1b                       # (a gap the glyph loop stepped over: inside a character)
    mov edi, ebx
    imul edi, [rip + g_cw]
    add edi, [rip + g_row_x]
    mov r14d, edi               # x
    mov eax, [r13 + VI_cells]
    imul eax, [rip + g_cw]
    mov r15d, eax               # w
    add ebx, [r13 + VI_cells]
    # wholly outside the clip: only its cells count
    lea eax, [r14 + r15]
    cmp eax, [rip + g_cv + CV_cx0]
    jle 1b
    cmp r14d, [rip + g_cv + CV_cx1]
    jge 1b
    mov rdi, r13
    mov esi, r14d
    mov edx, r15d
    mov ecx, [rsp]
    call vi_paint
    jmp 1b
9:  mov eax, ebx
    EPILOGUE

# vi_paint(VI*, x, w, baseline): an inlay's pill and text
vi_paint:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov [rsp], ecx
    mov edi, [rbx + VI_bg]
    test edi, edi
    jz 1f
    mov r9d, edi
    mov edi, r12d
    mov esi, [rip + g_row_y]
    add esi, [rip + g_mt + 4*MI_2]
    mov edx, r13d
    mov ecx, [rip + g_lh]
    sub ecx, [rip + g_mt + 4*MI_4]
    M r8d, MI_4
    call gfx_round_rect
1:  cmp dword ptr [rbx + VI_len], 0
    je 9f
    sub rsp, 8
    push r13                    # maxw
    lea rdi, [rip + g_face_code]
    mov esi, r12d
    mov edx, [rsp + 16]
    mov rcx, [rbx + VI_text]
    mov r8d, [rbx + VI_len]
    mov r9d, [rbx + VI_fg]
    call text_draw_fit
    add rsp, 16
9:  EPILOGUE

# vt_row_end() -> eax the cells of the row's inlays at its end (for the widest-row measure)
FN vt_row_cells
    xor eax, eax
    mov rcx, [rip + vr_i0]
1:  cmp rcx, [rip + vr_i1]
    jae 9f
    imul rdx, rcx, VI_SIZE
    lea r8, [rip + vt_items]
    add eax, [r8 + rdx + VI_cells]
    inc rcx
    jmp 1b
9:  ret

# ---------------- hit tests ----------------

# vt_pos_at(doc, line, px) -> rax the position nearest to px (pixels from the line's column 0) on
# an unwrapped line; g_vt_hit is 1 + the inlay under px (vt_hit_item a copy), or 0
FN vt_pos_at
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], rdx              # px
    mov qword ptr [rip + g_vt_hit], 0
    mov rdi, rbx
    mov rsi, r12
    call vt_line
    mov r15, rax                # items
    mov [rsp + 8], rdx          # count
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov [rsp + 16], rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_text
    mov r12, rax                # text
    mov [rsp + 24], rdx         # len
    xor r13d, r13d              # i
    xor r14d, r14d              # col
    xor ebx, ebx                # item index
.Lvp_gap:
    # the inlays at gap i
    cmp rbx, [rsp + 8]
    jae 3f
    imul rax, rbx, VI_SIZE
    add rax, r15
    cmp [rax + VI_off], r13
    ja 3f
    jb 2f
    mov ecx, r14d
    add ecx, [rax + VI_cells]
    imul ecx, [rip + g_cw]
    movsxd rcx, ecx
    cmp [rsp], rcx
    jge 1f
    # under the pointer: the gap is the position
    lea rcx, [rbx + 1]
    mov [rip + g_vt_hit], rcx
    lea rdi, [rip + vt_hit_item]
    mov rsi, rax
    mov edx, VI_SIZE
    call memcpy
    jmp .Lvp_ret
1:  add r14d, [rax + VI_cells]
2:  inc rbx
    jmp .Lvp_gap
3:  cmp r13, [rsp + 24]
    jae .Lvp_ret
    # the character at i: the nearer edge
    movzx eax, byte ptr [r12 + r13]
    mov ecx, 1
    cmp al, 9
    jne 4f
    mov eax, r14d
    xor edx, edx
    div dword ptr [rip + g_tab_width]
    mov eax, [rip + g_tab_width]
    sub eax, edx
    jmp 5f
4:  cmp al, 0x80
    jb 41f
    lea rdi, [r12 + r13]
    mov rsi, [rsp + 24]
    sub rsi, r13
    call utf8_decode
    push rdx
    push rdx
    mov edi, eax
    call cp_width
    pop rcx
    pop rcx
    jmp 5f
41: mov eax, 1
5:  # eax width, ecx bytes
    lea edx, [r14 + rax]
    imul edx, [rip + g_cw]
    movsxd rdx, edx
    cmp [rsp], rdx
    jge 6f
    lea edx, [r14 + r14]
    add edx, eax
    imul edx, [rip + g_cw]      # twice the middle
    movsxd rdx, edx
    mov r8, [rsp]
    add r8, r8
    cmp r8, rdx
    jl .Lvp_ret
    add r13, rcx
    jmp .Lvp_ret
6:  add r14d, eax
    add r13, rcx
    jmp .Lvp_gap
.Lvp_ret:
    mov rax, [rsp + 16]
    add rax, r13
    EPILOGUE

# ---------------- wrapped lines (wrap.s) ----------------
# break_text, pos_in_row and cursor_row count a line's inlays as cells glued to the character after
# their gap (the inlays at the line's end stay on its last row)

# vt_bt_set(doc, line): the line wrap.s measures next (its inlays, or none)
FN vt_bt_set
    mov qword ptr [rip + bt_n], 0
    cmp qword ptr [rdi + DOC_pres], 0
    je 1f
    sub rsp, 8
    call vt_line
    add rsp, 8
    mov [rip + bt_items], rax
    mov [rip + bt_n], rdx
1:  ret

# vt_bt_at(off) -> eax the cells of the inlays at a gap; keeps every register but rax
FN vt_bt_at
    push rcx
    push rdx
    push rsi
    xor eax, eax
    mov rcx, [rip + bt_n]
    mov rsi, [rip + bt_items]
1:  test rcx, rcx
    jz 9f
    cmp [rsi + VI_off], rdi
    jne 2f
    add eax, [rsi + VI_cells]
2:  add rsi, VI_SIZE
    dec rcx
    jmp 1b
9:  pop rsi
    pop rdx
    pop rcx
    ret

# vt_bt_hit(off, rel) -> eax the cells at the gap, edx 1 when rel (cells past the gap's start) falls
# on one of its inlays (g_vt_hit and vt_hit_item say which)
FN vt_bt_hit
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13d, esi
    xor ebx, ebx                # cells so far
    xor edx, edx
    mov rcx, [rip + bt_n]
    mov rsi, [rip + bt_items]
    xor r8d, r8d                # index
1:  test rcx, rcx
    jz 9f
    cmp [rsi + VI_off], r12
    jne 2f
    add ebx, [rsi + VI_cells]
    test edx, edx
    jnz 2f
    cmp r13d, ebx
    jge 2f
    test r13d, r13d
    js 2f
    mov edx, 1
    lea rax, [r8 + 1]
    mov [rip + g_vt_hit], rax
    push rcx
    push rdx
    push rsi
    push r8
    lea rdi, [rip + vt_hit_item]
    mov edx, VI_SIZE
    call memcpy
    pop r8
    pop rsi
    pop rdx
    pop rcx
2:  add rsi, VI_SIZE
    inc r8
    dec rcx
    jmp 1b
9:  mov eax, ebx
    pop r13
    pop r12
    pop rbx
    ret

# vt_bt_before(from, off) -> eax the cells of the inlays at gaps from..off, those at off by the
# caret's rule (none when an `after` inlay is there)
FN vt_bt_before
    xor eax, eax
    xor r9d, r9d                # the after-at-off rule found
    mov rcx, [rip + bt_n]
    mov r8, [rip + bt_items]
1:  test rcx, rcx
    jz 3f
    mov rdx, [r8 + VI_off]
    cmp rdx, rdi
    jb 2f
    cmp rdx, rsi
    ja 2f
    jb 11f
    cmp byte ptr [r8 + VI_side], VS_AFTER
    jne 2f
    mov r9d, 1
    jmp 2f
11: add eax, [r8 + VI_cells]
2:  add r8, VI_SIZE
    dec rcx
    jmp 1b
3:  test r9d, r9d
    jnz 9f
    push rax
    mov rdi, rsi
    call vt_bt_at
    pop rcx
    add eax, ecx
9:  ret

# vt_hit_kind() -> eax the VK_* of the inlay vt_pos_at found
FN vt_hit_kind
    movzx eax, byte ptr [rip + vt_hit_item + VI_kind]
    ret

# vt_hover(doc): the pointer rests on the inlay vt_pos_at found: its tip (no hover event goes to
# extensions for it)
FN vt_hover
    PROLOGUE
    mov rbx, rdi
    call hovercard_covers       # the hover card shows (or is about to): no tooltip beside it
    test eax, eax
    jnz 9f
    lea r12, [rip + vt_hit_item]
    cmp byte ptr [r12 + VI_kind], VK_LENS
    jne 0f
    mov rdi, rbx                # a code lens item's tip (lens.s)
    mov rsi, [r12 + VI_ref]
    mov rdx, [r12 + VI_off]
    call lens_tip
    test rax, rax
    jz 9f
    jmp 2f
0:  cmp byte ptr [r12 + VI_kind], VK_HINT
    jne 1f
    mov rdi, rbx                # a hint part's tooltip (inlay.s)
    mov rsi, [r12 + VI_ref]
    call inlay_tip
    test rax, rax
    jz 9f
    jmp 2f
1:  cmp byte ptr [r12 + VI_kind], VK_DECO
    jne 9f
    mov rdi, rbx
    mov rsi, [r12 + VI_ref]
    call deco_dr_tip
    test rax, rax
    jz 9f
2:  mov r9, rax
    mov edi, ID_VT_TIP
    add edi, [r12 + VI_off]
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    add edx, [rip + g_mt + 4*MI_8]
    mov ecx, 1
    mov r8d, UB_HOVER
    call tip_note_text
9:  EPILOGUE

# FN vt_hit_set(kind, ref, off): the pointer is on something drawn in a line that is not an inlay
# (a code lens item, lens.s): it becomes the hit vt_hover and vt_click look at
FN vt_hit_set
    lea rax, [rip + vt_hit_item]
    mov [rax + VI_kind], dil
    mov [rax + VI_ref], rsi
    mov [rax + VI_off], rdx
    mov qword ptr [rip + g_vt_hit], 1
    ret

# vt_click(doc) -> eax 1 when a press on the inlay vt_pos_at found ran its command
FN vt_click
    PROLOGUE
    mov rbx, rdi
    lea r12, [rip + vt_hit_item]
    cmp byte ptr [r12 + VI_kind], VK_FOLD
    jne 1f
    mov rdi, rbx                # a fold's pill unfolds it
    mov rsi, [r12 + VI_ref]
    call fold_unfold_line
    mov eax, 1
    EPILOGUE
1:  cmp byte ptr [r12 + VI_kind], VK_LENS
    jne 11f
    mov rdi, rbx                # a code lens item's command (lens.s)
    mov rsi, [r12 + VI_ref]
    mov rdx, [r12 + VI_off]
    call lens_click
    EPILOGUE
11: cmp byte ptr [r12 + VI_kind], VK_SWATCH
    jne 12f
    mov rdi, rbx                # a swatch asks for its new color (hicolor.s)
    mov rsi, [r12 + VI_ref]
    call color_click
    EPILOGUE
12: cmp byte ptr [r12 + VI_kind], VK_HINT
    jne 2f
    mov rdi, rbx                # a hint part's command, place or edits (inlay.s)
    mov rsi, [r12 + VI_ref]
    call inlay_click
    EPILOGUE
2:  cmp byte ptr [r12 + VI_kind], VK_DECO
    jne 8f
    mov rdi, rbx
    mov rsi, [r12 + VI_ref]
    call deco_dr_command
    test rax, rax
    jz 8f
    mov r13, rax
    mov rdi, r13
    mov rsi, [rbx + DOC_id]
    call cmdref_invoke
    mov rdi, r13
    call cmdref_free
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# vt_doc_col(doc, pos) -> rax the visual column of a position on its (unwrapped) line, inlays
# included by the caret's rule: the preferred column of vertical motion
FN vt_doc_col
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call doc_line_of
    mov r13, rax
    mov rdi, rbx
    mov rsi, r13
    call vt_has
    test eax, eax
    jnz 1f
    mov rdi, rbx
    mov rsi, r12
    call doc_col_of
    EPILOGUE
1:  call row_save
    mov rdi, rbx
    mov rsi, r13
    xor edx, edx
    call row_whole_line
    mov rdi, rbx
    mov rsi, r13
    call doc_line_start
    mov rdi, r12
    sub rdi, rax
    mov esi, VTM_CARET
    call vt_x
    xor edx, edx
    div dword ptr [rip + g_cw]
    push rax
    push rax
    call row_restore
    pop rax
    pop rax
    EPILOGUE

# vt_line_x(doc, line, off) -> eax the caret's x of a byte offset of an unwrapped line, from its
# column 0 (inlays by the caret's rule)
FN vt_line_x
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call row_save
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call row_whole_line
    mov rdi, r13
    mov esi, VTM_CARET
    call vt_x
    mov r14d, eax
    call row_restore
    mov eax, r14d
    EPILOGUE

# vt_doc_pos_at_col(doc, line, col) -> rax the position at a visual column of an unwrapped line,
# inlays included (doc_pos_at_col without them)
FN vt_doc_pos_at_col
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call vt_has
    test eax, eax
    jnz 1f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call doc_pos_at_col
    EPILOGUE
1:  mov rdx, r13
    imul edx, [rip + g_cw]
    mov rdi, rbx
    mov rsi, r12
    call vt_pos_at
    EPILOGUE

# row_whole_line(doc, line, x0): g_row_* for the whole line as one row starting at x0, and its inlays
row_whole_line:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov [rip + g_row_doc], rbx
    mov [rip + g_row_line], r12
    mov [rip + g_row_x], edx
    call doc_line_start
    mov [rip + g_row_lstart], rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_text
    mov [rip + g_row_text], rax
    mov [rip + g_row_len], rdx
    mov qword ptr [rip + g_row_from], 0
    mov [rip + g_row_to], rdx
    call vt_row_set
    EPILOGUE

# row_save(), row_restore(): g_row_* and the row's inlays kept across a measurement outside drawing
row_save:
    sub rsp, 8
    lea rdi, [rip + row_saved]
    lea rsi, [rip + g_row_doc]
    mov edx, 64
    call memcpy
    add rsp, 8
    mov rax, [rip + vr_i0]
    mov [rip + row_saved + 64], rax
    mov rax, [rip + vr_i1]
    mov [rip + row_saved + 72], rax
    mov rax, [rip + vr_next]
    mov [rip + row_saved + 80], rax
    mov rax, [rip + g_row_vt]
    mov [rip + row_saved + 88], rax
    ret
row_restore:
    sub rsp, 8
    lea rdi, [rip + g_row_doc]
    lea rsi, [rip + row_saved]
    mov edx, 64
    call memcpy
    add rsp, 8
    mov rax, [rip + row_saved + 64]
    mov [rip + vr_i0], rax
    mov rax, [rip + row_saved + 72]
    mov [rip + vr_i1], rax
    mov rax, [rip + row_saved + 80]
    mov [rip + vr_next], rax
    mov rax, [rip + row_saved + 88]
    mov [rip + g_row_vt], rax
    ret

.section .rodata
# the rank of a kind among the `before` inlays at one gap: decorations, hints, the swatch nearest
before_rank: .byte 3, 3, 1, 0, 2

.bss
.p2align 3
row_saved: .zero 96
