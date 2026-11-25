# editor presentation: the gutter's lanes. From left to right: the left lane (the gutter's first
# 16 px: glyphs such as breakpoints, test buttons, decoration icons and the diagnostic dot), the
# line numbers (with an optional tint behind them: coverage), the fold lane, the git bar.
#
# Built-in code puts glyphs in the left lane through kinds (gutter_kind): a kind has a priority (the
# highest glyph on a line shows), a click function and a tip function. Glyphs are kept per document
# at line positions that move with edits like the text (an insert at a line's start moves its glyph
# down with the line; a deleted line's glyph goes to the line that takes its place, and two of one
# kind on a line become one).
#
#   gutter_kind(prio, flags, click, tip, hover_glyph) -> eax kind (1..GK_MAX-1), 0 when full
#       click(doc, line, button, glyph): a press (BTN_LEFT or BTN_RIGHT) on the kind's glyph, or,
#           for the GK_EMPTY kind of highest priority, on a line where no kind has a glyph (glyph 0)
#       tip(doc, line, glyph) -> rax cstr or 0: the tooltip when the pointer rests on the glyph
#       hover_glyph: GK_EMPTY kinds: drawn faint on the line under the pointer (0: none)
#       flags: GK_EMPTY, GK_RESERVE (the lane keeps 16 px even with line numbers off)
#   gutter_glyph_set(doc, kind, line, glyph): glyph = GS_* | theme slot << 8 | GF_* << 16, 0 removes
#   gutter_glyph_get(doc, kind, line) -> eax glyph or 0
#   gutter_glyph_next(doc, kind, line) -> rax the first line >= line with a glyph of the kind, or -1
#   gutter_glyph_clear(doc, kind): all of the kind's glyphs (doc 0: on every open document)
#   gutter_tint(fn): fn(doc, line) -> eax argb or 0, drawn behind the line's number (coverage)
#   gutter_hit(x, y) -> eax GL_* lane, rdx line (of the last frame's layout), or LANE_NONE
#   gutter_shape_draw(shape, x, y, size, argb): a glyph shape in a size x size box
.include "rhun.inc"

.equ ID_GUTTER, 0x3d00          # + line & 255: a glyph's tooltip

.data
.p2align 3
gk_n: .long 1                   # kinds registered, 0 is none
.globl g_gl_hover_line
.p2align 3
g_gl_hover_line: .quad -1       # the line under the pointer in the left lane, or -1
.bss
.p2align 3
gk_prio: .zero 4 * GK_MAX
gk_flags: .zero 4 * GK_MAX
gk_hover: .zero 4 * GK_MAX
.p2align 3
gk_click: .zero 8 * GK_MAX
gk_tip: .zero 8 * GK_MAX
gt_fns: .zero 8 * 8             # tint functions
gt_n: .long 0
gl_gutter_hot: .long 0          # the pointer is over the gutter (the fold lane's chevrons show)
# the last frame's layout, x in pixels
.globl g_gl_lane_x, g_gl_lane_w, g_gl_digits_r, g_gl_fold_x, g_gl_fold_w
g_gl_lane_x: .long 0
g_gl_lane_w: .long 0
g_gl_digits_r: .long 0          # the right edge of the line numbers
g_gl_fold_x: .long 0
g_gl_fold_w: .long 0            # 0 without the fold lane
.p2align 3
tipbuf: .zero 512
mask: .zero 64 * 64             # a shape's coverage
pts: .zero 8 * 40               # a contour's points

.text

# ---------------- kinds and glyphs ----------------

FN gutter_kind
    mov eax, [rip + gk_n]
    cmp eax, GK_MAX
    jae 8f
    inc dword ptr [rip + gk_n]
    lea r10, [rip + gk_prio]
    mov [r10 + rax*4], edi
    lea r10, [rip + gk_flags]
    mov [r10 + rax*4], esi
    lea r10, [rip + gk_click]
    mov [r10 + rax*8], rdx
    lea r10, [rip + gk_tip]
    mov [r10 + rax*8], rcx
    lea r10, [rip + gk_hover]
    mov [r10 + rax*4], r8d
    ret
8:  xor eax, eax
    ret

FN gutter_tint
    mov eax, [rip + gt_n]
    cmp eax, 8
    jae 1f
    lea rcx, [rip + gt_fns]
    mov [rcx + rax*8], rdi
    inc dword ptr [rip + gt_n]
1:  ret

# line_span(rbx doc, line rsi) -> rax its start, rdx the next line's start (or past the end)
line_span:
    push rsi
    mov rdi, rbx
    call doc_line_start
    pop rsi
    push rax
    inc rsi
    cmp rsi, [rbx + DOC_nlines]
    jb 1f
    mov rdi, rbx
    call doc_len
    lea rdx, [rax + 1]
    pop rax
    ret
1:  mov rdi, rbx
    call doc_line_start
    mov rdx, rax
    pop rax
    ret

# glyph_lower(rbx doc, pos rsi) -> rax the index of the first entry at pos or after
glyph_lower:
    mov rdi, [rbx + DOC_pres]
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rcx, [rdi + PRS_glyphs + VEC_len]
    mov rdi, [rdi + PRS_glyphs + VEC_ptr]
1:  cmp rax, rcx
    jae 9f
    lea rdx, [rax + rcx]
    shr rdx, 1
    imul r8, rdx, GLE_SIZE
    cmp [rdi + r8 + GLE_pos], rsi
    jae 2f
    lea rax, [rdx + 1]
    jmp 1b
2:  mov rcx, rdx
    jmp 1b
9:  ret

# glyph_find(rbx doc, r12d kind, r13 line) -> rax entry or 0
glyph_find:
    push r14
    push r15
    sub rsp, 8
    mov rsi, r13
    call line_span
    mov r14, rax
    mov r15, rdx
    mov rsi, r14
    call glyph_lower
    mov rdi, [rbx + DOC_pres]
    test rdi, rdi
    jz 8f
1:  cmp rax, [rdi + PRS_glyphs + VEC_len]
    jae 8f
    imul rcx, rax, GLE_SIZE
    add rcx, [rdi + PRS_glyphs + VEC_ptr]
    cmp [rcx + GLE_pos], r15
    jae 8f
    inc rax
    cmp [rcx + GLE_kind], r12d
    jne 1b
    mov rax, rcx
    jmp 9f
8:  xor eax, eax
9:  add rsp, 8
    pop r15
    pop r14
    ret

FN gutter_glyph_set
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14d, ecx
    cmp r13, [rbx + DOC_nlines]
    jae 9f
    call glyph_find
    test rax, rax
    jz 2f
    test r14d, r14d
    jz 1f
    mov [rax + GLE_glyph], r14d
    jmp 8f
1:  # removed: the later entries move down over it
    mov rdi, [rbx + DOC_pres]
    mov rcx, [rdi + PRS_glyphs + VEC_ptr]
    imul rdx, [rdi + PRS_glyphs + VEC_len], GLE_SIZE
    add rdx, rcx
    lea rsi, [rax + GLE_SIZE]
    sub rdx, rsi
    mov rdi, rax
    call memmove
    mov rdi, [rbx + DOC_pres]
    dec qword ptr [rdi + PRS_glyphs + VEC_len]
    jmp 8f
2:  test r14d, r14d
    jz 9f
    mov rdi, rbx
    call pres_ensure
    mov rsi, r13
    call line_span
    mov r15, rax                # the line's start: the new entry's position
    mov rsi, rax
    call glyph_lower
    push rax
    push rax
    mov rdi, [rbx + DOC_pres]
    lea rdi, [rdi + PRS_glyphs]
    mov esi, GLE_SIZE
    call vec_push
    pop rax
    pop rax
    mov rdi, [rbx + DOC_pres]
    imul rsi, rax, GLE_SIZE
    add rsi, [rdi + PRS_glyphs + VEC_ptr]
    mov rdx, [rdi + PRS_glyphs + VEC_len]
    dec rdx
    sub rdx, rax
    imul rdx, rdx, GLE_SIZE
    push rsi
    push rsi
    lea rdi, [rsi + GLE_SIZE]
    call memmove
    pop rax
    pop rax
    mov [rax + GLE_pos], r15
    mov [rax + GLE_kind], r12d
    mov [rax + GLE_glyph], r14d
8:  mov rdi, rbx
    call pres_touch
9:  EPILOGUE

FN gutter_glyph_get
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    xor eax, eax
    cmp qword ptr [rbx + DOC_pres], 0
    je 9f
    cmp r13, [rbx + DOC_nlines]
    jae 9f
    call glyph_find
    test rax, rax
    jz 9f
    mov eax, [rax + GLE_glyph]
9:  EPILOGUE

FN gutter_glyph_next
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    cmp qword ptr [rbx + DOC_pres], 0
    je 8f
    cmp r13, [rbx + DOC_nlines]
    jae 8f
    mov rdi, rbx
    mov rsi, r13
    call doc_line_start
    mov rsi, rax
    call glyph_lower
    mov r14, rax
1:  mov rdi, [rbx + DOC_pres]
    cmp r14, [rdi + PRS_glyphs + VEC_len]
    jae 8f
    imul rcx, r14, GLE_SIZE
    add rcx, [rdi + PRS_glyphs + VEC_ptr]
    inc r14
    cmp [rcx + GLE_kind], r12d
    jne 1b
    mov rdi, rbx
    mov rsi, [rcx + GLE_pos]
    call doc_line_of
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

FN gutter_glyph_clear
    PROLOGUE
    mov r12d, esi
    test rdi, rdi
    jz 2f
    call glyph_clear_doc
    EPILOGUE
2:  xor r13d, r13d
3:  cmp r13, [rip + g_tabs + VEC_len]
    jae 9f
    imul rax, r13, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    inc r13
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 3b
    mov rdi, [rax + TAB_doc]
    test rdi, rdi
    jz 3b
    call glyph_clear_doc
    jmp 3b
9:  EPILOGUE

# glyph_clear_doc(doc, r12d kind): the kind's entries go
glyph_clear_doc:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + DOC_pres]
    test rdi, rdi
    jz 9f
    mov rsi, [rdi + PRS_glyphs + VEC_ptr]
    mov rcx, [rdi + PRS_glyphs + VEC_len]
    xor edx, edx                # read
    xor r8d, r8d                # write
1:  cmp rdx, rcx
    jae 2f
    imul r9, rdx, GLE_SIZE
    inc rdx
    cmp [rsi + r9 + GLE_kind], r12d
    je 1b
    imul r10, r8, GLE_SIZE
    inc r8
    mov rax, [rsi + r9]
    mov [rsi + r10], rax
    mov rax, [rsi + r9 + 8]
    mov [rsi + r10 + 8], rax
    jmp 1b
2:  cmp r8, rcx
    je 9f
    mov [rdi + PRS_glyphs + VEC_len], r8
    mov rdi, rbx
    call pres_touch
9:  pop rbx
    ret

# gutter_shift(doc, entry): the glyphs move with an edit; two of one kind on one line merge
FN gutter_shift
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + DOC_pres]
    mov rsi, [rax + PRS_glyphs + VEC_len]
    test rsi, rsi
    jz 9f
    mov rdi, [rax + PRS_glyphs + VEC_ptr]
    mov edx, GLE_SIZE
    mov ecx, GR_RIGHT
    mov r8, r12
    call shift_points
    cmp qword ptr [r12 + TE_del], 0
    je 9f
    # entries on the deletion's line: one per kind, the first
    mov rsi, [r12 + TE_line]
    call line_span
    mov r13, rax
    mov r14, rdx
    mov rsi, r13
    call glyph_lower
    mov r15, rax                # the line's first entry
1:  mov rdi, [rbx + DOC_pres]
    cmp r15, [rdi + PRS_glyphs + VEC_len]
    jae 9f
    imul rcx, r15, GLE_SIZE
    add rcx, [rdi + PRS_glyphs + VEC_ptr]
    cmp [rcx + GLE_pos], r14
    jae 9f
    inc r15
    # a later entry of the same kind on the line goes
    mov r8, r15
2:  cmp r8, [rdi + PRS_glyphs + VEC_len]
    jae 1b
    imul r9, r8, GLE_SIZE
    add r9, [rdi + PRS_glyphs + VEC_ptr]
    cmp [r9 + GLE_pos], r14
    jae 1b
    mov eax, [rcx + GLE_kind]
    cmp [r9 + GLE_kind], eax
    je 3f
    inc r8
    jmp 2b
3:  push rcx
    push r8
    mov rdi, r9
    lea rsi, [r9 + GLE_SIZE]
    mov rax, [rbx + DOC_pres]
    imul rdx, [rax + PRS_glyphs + VEC_len], GLE_SIZE
    add rdx, [rax + PRS_glyphs + VEC_ptr]
    sub rdx, rsi
    call memmove
    mov rax, [rbx + DOC_pres]
    dec qword ptr [rax + PRS_glyphs + VEC_len]
    pop r8
    pop rcx
    mov rdi, [rbx + DOC_pres]
    jmp 2b
9:  EPILOGUE

# ---------------- layout ----------------

# gutter_extra(doc) -> eax pixels the lanes add to the gutter: the fold lane while folding is on,
# the left lane with line numbers off while a kind reserves it. Keeps rdi and rcx.
FN gutter_extra
    xor eax, eax
    cmp dword ptr [rip + cfg_folding], 0
    je 0f
    M eax, MI_12
0:  cmp dword ptr [rip + cfg_line_numbers], 0
    jne 9f
    push rcx
    mov ecx, 1
1:  cmp ecx, [rip + gk_n]
    jae 8f
    lea rdx, [rip + gk_flags]
    test dword ptr [rdx + rcx*4], GK_RESERVE
    jnz 2f
    inc ecx
    jmp 1b
8:  pop rcx
    ret
2:  add eax, [rip + g_mt + 4*MI_16]
    pop rcx
    ret
9:  ret

# gutter_frame(doc): the frame's lane positions, once g_ed_x and g_ed_tx are known
FN gutter_frame
    mov eax, [rip + g_ed_x]
    mov [rip + g_gl_lane_x], eax
    M eax, MI_16
    mov [rip + g_gl_lane_w], eax
    mov dword ptr [rip + g_gl_fold_w], 0
    cmp dword ptr [rip + cfg_folding], 0
    je 1f
    M eax, MI_12
    mov [rip + g_gl_fold_w], eax
1:  mov eax, [rip + g_ed_tx]
    sub eax, [rip + g_mt + 4*MI_16]
    sub eax, [rip + g_gl_fold_w]
    mov [rip + g_gl_fold_x], eax
    mov [rip + g_gl_digits_r], eax
    ret

# gutter_hit(x, y) -> eax lane, rdx line (LANE_NONE: not over the gutter of a line)
FN gutter_hit
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 8f
    cmp qword ptr [rbx + DOC_diff], 0
    jne 8f
    cmp r12d, [rip + g_ed_x]
    jl 8f
    cmp r12d, [rip + g_ed_tx]
    jge 8f
    cmp r13d, [rip + g_ed_y]
    jl 8f
    mov eax, [rip + g_ed_y]
    add eax, [rip + g_ed_h]
    cmp r13d, eax
    jge 8f
    # the line: the text's own point mapping at its first column
    mov rdi, rbx
    mov esi, [rip + g_ed_tx]
    mov edx, r13d
    call pos_at_point_editor
    mov rdi, rbx
    mov rsi, rax
    call doc_line_of
    mov r14, rax
    mov eax, LANE_LEFT
    mov ecx, [rip + g_gl_lane_x]
    add ecx, [rip + g_gl_lane_w]
    cmp r12d, ecx
    jl 9f
    mov eax, LANE_DIGITS
    cmp r12d, [rip + g_gl_digits_r]
    jl 9f
    mov eax, LANE_FOLD
    mov ecx, [rip + g_gl_fold_x]
    add ecx, [rip + g_gl_fold_w]
    cmp r12d, ecx
    jl 9f
    mov eax, LANE_GIT
9:  mov rdx, r14
    EPILOGUE
8:  xor eax, eax
    mov rdx, -1
    EPILOGUE

# ---------------- drawing ----------------

# top_glyph(rbx doc, r13 line) -> eax glyph, edx kind (0: none) of the kinds' entries on the line
top_glyph:
    push r14
    push r15
    push r12
    xor r14d, r14d              # glyph
    xor r15d, r15d              # kind
    mov rdi, [rbx + DOC_pres]
    test rdi, rdi
    jz 9f
    cmp qword ptr [rdi + PRS_glyphs + VEC_len], 0
    je 9f
    mov rsi, r13
    call line_span
    mov r12, rdx
    mov rsi, rax
    call glyph_lower
    mov rdi, [rbx + DOC_pres]
1:  cmp rax, [rdi + PRS_glyphs + VEC_len]
    jae 9f
    imul rcx, rax, GLE_SIZE
    add rcx, [rdi + PRS_glyphs + VEC_ptr]
    cmp [rcx + GLE_pos], r12
    jae 9f
    inc rax
    mov edx, [rcx + GLE_kind]
    test r15d, r15d
    jz 2f
    lea r8, [rip + gk_prio]
    mov r9d, [r8 + rdx*4]
    cmp r9d, [r8 + r15*4]
    jle 1b
2:  mov r15d, edx
    mov r14d, [rcx + GLE_glyph]
    jmp 1b
9:  mov eax, r14d
    mov edx, r15d
    pop r12
    pop r15
    pop r14
    ret

# empty_kind() -> eax the GK_EMPTY kind of highest priority, or 0
empty_kind:
    xor eax, eax
    mov ecx, 1
1:  cmp ecx, [rip + gk_n]
    jae 9f
    lea rdx, [rip + gk_flags]
    test dword ptr [rdx + rcx*4], GK_EMPTY
    jz 3f
    test eax, eax
    jz 2f
    lea rdx, [rip + gk_prio]
    mov r8d, [rdx + rcx*4]
    cmp r8d, [rdx + rax*4]
    jle 3f
2:  mov eax, ecx
3:  inc ecx
    jmp 1b
9:  ret

# gutter_line_under(doc, line, y, h): the tints behind the line's number
FN gutter_line_under
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    xor r13d, r13d
1:  cmp r13d, [rip + gt_n]
    jae 9f
    lea rax, [rip + gt_fns]
    mov rax, [rax + r13*8]
    inc r13d
    mov rdi, rbx
    mov rsi, r12
    call rax
    test eax, eax
    jz 1b
    mov r8d, eax
    mov edi, [rip + g_gl_lane_x]
    add edi, [rip + g_gl_lane_w]
    cmp dword ptr [rip + cfg_line_numbers], 0
    jne 2f
    mov edi, [rip + g_ed_x]     # no numbers: a strip at the gutter's left
    M edx, MI_4
    jmp 3f
2:  mov edx, [rip + g_gl_digits_r]
    sub edx, edi
3:  mov esi, [rsp]
    mov ecx, [rsp + 4]
    call gfx_fill
    jmp 1b
9:  EPILOGUE

# gutter_line(doc, line, y, h): the left lane's glyph for a line: the kinds' highest, else a
# decoration's icon, else the diagnostic dot; faint, the hover glyph of the line under the pointer
FN gutter_line
    PROLOGUE 32
    mov rbx, rdi
    mov r13, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    call top_glyph
    test eax, eax
    jz 2f
    mov r12d, eax
    movzx edi, al
    mov ecx, eax
    shr ecx, 8
    movzx ecx, cl
    lea rdx, [rip + g_theme]
    mov r8d, [rdx + rcx*4]
    test r12d, GF_FAINT << 16
    jz 1f
    call faint
1:  mov esi, r8d
    jmp .Lgl_draw
2:  # the hover glyph of the GK_EMPTY kind on the line under the pointer
    cmp r13, [rip + g_gl_hover_line]
    jne 3f
    call empty_kind
    test eax, eax
    jz 3f
    lea rcx, [rip + gk_hover]
    mov r12d, [rcx + rax*4]
    test r12d, r12d
    jz 3f
    movzx edi, r12b
    mov ecx, r12d
    shr ecx, 8
    movzx ecx, cl
    lea rdx, [rip + g_theme]
    mov r8d, [rdx + rcx*4]
    call faint
    mov esi, r8d
    jmp .Lgl_draw
3:  # a decoration's icon
    mov rdi, rbx
    mov rsi, r13
    call deco_gutter_icon       # -> eax shape, edx argb
    test eax, eax
    jz 4f
    mov edi, eax
    mov esi, edx
    jmp .Lgl_draw
4:  mov rdi, rbx
    mov rsi, r13
    call extmarks_line
    test eax, eax
    js 9f
    mov edi, eax
    call extmarks_color
    mov esi, eax
    mov edi, GS_DOT
.Lgl_draw:
    mov r8d, esi                # argb
    M ecx, MI_12                # the box
    mov eax, [rip + g_gl_lane_w]
    sub eax, ecx
    sar eax, 1
    add eax, [rip + g_gl_lane_x]
    mov esi, eax
    mov edx, [rip + g_lh]
    cmp edx, [rsp + 4]
    jle 5f
    mov edx, [rsp + 4]
5:  sub edx, ecx
    sar edx, 1
    add edx, [rsp]
    call gutter_shape_draw
9:  mov rdi, rbx
    mov rsi, r13
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    call fold_chevron
    EPILOGUE

# fold_chevron(doc, line, y, h): the fold lane: a right chevron on a folded header, a down one on a
# line that starts a range while the pointer is over the gutter
fold_chevron:
    PROLOGUE 16
    cmp dword ptr [rip + g_gl_fold_w], 0
    je 9f
    cmp qword ptr [rdi + DOC_diff], 0
    jne 9f
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    call fold_at
    mov r14d, IC_CHEV_R
    COLOR r15d, T_LINENO_ACTIVE
    test rax, rax
    jnz 1f
    cmp dword ptr [rip + gl_gutter_hot], 0
    je 9f
    mov rdi, rbx
    mov rsi, r12
    call range_starts
    test eax, eax
    jz 9f
    mov r14d, IC_CHEV_D
    COLOR r15d, T_LINENO
1:  M ecx, MI_10                # the icon's box, at the lane's right, in the row's middle
    mov esi, [rip + g_gl_fold_w]
    sub esi, ecx
    add esi, [rip + g_gl_fold_x]
    mov edx, [rip + g_lh]
    cmp edx, [rsp + 4]
    jle 2f
    mov edx, [rsp + 4]
2:  sub edx, ecx
    sar edx, 1
    add edx, [rsp]
    mov edi, r14d
    mov r8d, r15d
    call icon_draw
9:  EPILOGUE

# faint(r8d argb) -> r8d the color at a third of its alpha
faint:
    mov eax, r8d
    shr eax, 24
    imul eax, eax, 85
    shr eax, 8
    shl eax, 24
    and r8d, 0xffffff
    or r8d, eax
    ret

# gutter_hover(doc): the pointer is over the gutter this frame: the line under it in the left lane,
# and a glyph's tooltip
FN gutter_hover
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + gl_gutter_hot], 0
    jne 0f
    mov dword ptr [rip + gl_gutter_hot], 1  # the fold lane's chevrons show
    mov dword ptr [rip + g_dirty], 1
0:  mov rax, [rip + g_gl_hover_line]
    mov r14, rax
    mov edi, [rip + g_mx]
    mov esi, [rip + g_my]
    call gutter_hit
    mov r13, -1
    cmp eax, LANE_LEFT
    jne 1f
    mov r13, rdx
1:  mov [rip + g_gl_hover_line], r13
    cmp r13, r14
    je 2f
    mov dword ptr [rip + g_dirty], 1    # the hover glyph moves
2:  test r13, r13
    js 9f
    # the tooltip: the kind's, else a decoration's, else the line's diagnostic
    call top_glyph
    test edx, edx
    jz 3f
    lea rcx, [rip + gk_tip]
    mov rcx, [rcx + rdx*8]
    test rcx, rcx
    jz 9f
    mov rdi, rbx
    mov rsi, r13
    mov edx, eax
    call rcx
    test rax, rax
    jz 9f
    jmp 5f
3:  mov rdi, rbx
    mov rsi, r13
    call deco_gutter_tip
    test rax, rax
    jnz 5f
    mov rdi, rbx
    mov rsi, r13
    call gutter_mark_text
    test rax, rax
    jz 9f
5:  mov r9, rax
    mov edi, r13d
    and edi, 255
    add edi, ID_GUTTER
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    add edx, [rip + g_mt + 4*MI_8]
    mov ecx, 1
    mov r8d, UB_HOVER
    call tip_note_text
9:  EPILOGUE

# gutter_mark_text(doc, line) -> rax the message of the worst diagnostic on the line, or 0
gutter_mark_text:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call extmarks_line
    test eax, eax
    js 8f
    mov r13d, eax
    mov rsi, r12
    call line_span
    mov r14, rax
    mov r15, rdx
    mov rdi, [rbx + DOC_xmarks]
    test rdi, rdi
    jz 8f
    xor ecx, ecx
1:  cmp rcx, [rdi + VEC_len]
    jae 8f
    imul rax, rcx, MK_SIZE
    add rax, [rdi + VEC_ptr]
    inc rcx
    cmp [rax + MK_sev], r13d
    jne 1b
    cmp [rax + MK_start], r15
    jae 1b
    mov rdx, [rax + MK_end]
    cmp rdx, r14
    jb 1b
    mov rdi, [rax + MK_msg]     # as shown: cut at MARK_MSG_MAX (phase 4 task 9: marks keep it whole)
    call extmarks_shown
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# gutter_press(doc, button) -> eax 1 when a press in the left lane went to a kind
FN gutter_press
    PROLOGUE
    mov rbx, rdi
    mov r14d, esi
    mov edi, [rip + g_mx]
    mov esi, [rip + g_my]
    call gutter_hit
    cmp eax, LANE_FOLD
    je 7f
    cmp eax, LANE_LEFT
    jne 8f
    mov r13, rdx
    call top_glyph
    test edx, edx
    jnz 1f
    call empty_kind
    test eax, eax
    jz 8f
    mov edx, eax
    xor eax, eax
1:  mov r15d, eax
    lea rcx, [rip + gk_click]
    mov rax, [rcx + rdx*8]
    test rax, rax
    jz 8f
    mov rdi, rbx
    mov rsi, r13
    mov edx, r14d
    mov ecx, r15d
    call rax
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
7:  cmp r14d, BTN_LEFT          # the fold lane: a click toggles the line's fold (fold.s)
    jne 8f
    mov rdi, rbx
    mov rsi, rdx
    call fold_toggle_line
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- shapes ----------------

# gutter_shape_draw(shape, x, y, size, argb): the shape's contours rasterized into a size x size box
FN gutter_shape_draw
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 16], r8d
    cmp ecx, 64
    jle 1f
    mov ecx, 64
1:  cmp ecx, 4
    jl 9f
    mov [rsp + 12], ecx
    cmp edi, GS_COUNT
    jae 9f
    test edi, edi
    jz 9f
    mov esi, ecx
    mov edi, ecx
    call raster_begin
    cvtsi2ss xmm0, dword ptr [rsp + 12]
    divss xmm0, [rip + f_hundred]
    movss [rsp + 20], xmm0      # pixels per unit
    mov eax, [rsp]
    lea rcx, [rip + shape_table]
    mov rbx, [rcx + rax*8]      # the program
.Lsd_op:
    movzx eax, byte ptr [rbx]
    test eax, eax
    jz .Lsd_end
    cmp eax, 1
    je .Lsd_circle
    # 2 n x y ...: a polygon
    movzx r12d, byte ptr [rbx + 1]
    add rbx, 2
    xor r13d, r13d
2:  cmp r13d, r12d
    jae 3f
    movzx eax, byte ptr [rbx + r13*2]
    cvtsi2ss xmm0, eax
    mulss xmm0, [rsp + 20]
    lea rcx, [rip + pts]
    movss [rcx + r13*8], xmm0
    movzx eax, byte ptr [rbx + r13*2 + 1]
    cvtsi2ss xmm0, eax
    mulss xmm0, [rsp + 20]
    movss [rcx + r13*8 + 4], xmm0
    inc r13d
    jmp 2b
3:  lea rbx, [rbx + r12*2]
    call contour
    jmp .Lsd_op
.Lsd_circle:
    # 1 cx cy r dir: 24 points round, counterclockwise for dir 1, clockwise for dir 2
    movzx eax, byte ptr [rbx + 1]
    cvtsi2ss xmm4, eax
    mulss xmm4, [rsp + 20]
    movzx eax, byte ptr [rbx + 2]
    cvtsi2ss xmm5, eax
    mulss xmm5, [rsp + 20]
    movzx eax, byte ptr [rbx + 3]
    cvtsi2ss xmm6, eax
    mulss xmm6, [rsp + 20]
    movzx r14d, byte ptr [rbx + 4]
    add rbx, 5
    mov r12d, 32
    xor r13d, r13d
4:  cmp r13d, 32
    jae 5f
    mov eax, r13d
    cmp r14d, 1
    je 41f
    mov eax, 31
    sub eax, r13d
41: lea rcx, [rip + circle_tab]
    movss xmm0, [rcx + rax*8]
    mulss xmm0, xmm6
    addss xmm0, xmm4
    movss xmm1, [rcx + rax*8 + 4]
    mulss xmm1, xmm6
    addss xmm1, xmm5
    lea rcx, [rip + pts]
    movss [rcx + r13*8], xmm0
    movss [rcx + r13*8 + 4], xmm1
    inc r13d
    jmp 4b
5:  movss [rsp + 24], xmm4
    call contour
    jmp .Lsd_op
.Lsd_end:
    lea rdi, [rip + mask]
    call raster_end
    mov edi, [rsp + 4]
    mov esi, [rsp + 8]
    lea rdx, [rip + mask]
    mov ecx, [rsp + 12]
    mov r8d, ecx
    mov r9d, [rsp + 16]
    call gfx_mask_exact
9:  EPILOGUE

# contour(r12d points in pts): the closed polygon's edges
contour:
    push r13
    push r14
    sub rsp, 8
    xor r13d, r13d
1:  cmp r13d, r12d
    jae 9f
    lea r14d, [r13 + 1]
    cmp r14d, r12d
    jb 2f
    xor r14d, r14d
2:  lea rcx, [rip + pts]
    movss xmm0, [rcx + r13*8]
    movss xmm1, [rcx + r13*8 + 4]
    movss xmm2, [rcx + r14*8]
    movss xmm3, [rcx + r14*8 + 4]
    call raster_line
    inc r13d
    jmp 1b
9:  add rsp, 8
    pop r14
    pop r13
    ret

.section .rodata
.p2align 2
f_hundred: .float 100.0
.p2align 3
shape_table:
    .quad sh_none, sh_dot, sh_circle, sh_ring, sh_square, sh_diamond, sh_triangle, sh_bar
    .quad sh_check, sh_cross, sh_plus, sh_minus, sh_arrow, sh_circle_bar, sh_circle_tri, sh_bulb
# programs in hundredths of the box: 1 cx cy r dir (a circle), 2 n x0 y0 x1 y1 ... (a polygon);
# a hole is wound the other way
sh_none: .byte 0
sh_dot: .byte 1, 50, 50, 26, 1, 0
sh_circle: .byte 1, 50, 50, 42, 1, 0
sh_ring: .byte 1, 50, 50, 42, 1, 1, 50, 50, 26, 2, 0
sh_square: .byte 2, 4, 16, 16, 84, 16, 84, 84, 16, 84, 0
sh_diamond: .byte 2, 4, 50, 6, 94, 50, 50, 94, 6, 50, 0
sh_triangle: .byte 2, 3, 22, 10, 88, 50, 22, 90, 0
sh_bar: .byte 2, 4, 38, 8, 62, 8, 62, 92, 38, 92, 0
sh_check: .byte 2, 6, 8, 52, 22, 38, 40, 56, 78, 16, 92, 30, 40, 84, 0
sh_cross: .byte 2, 12, 22, 10, 50, 38, 78, 10, 90, 22, 62, 50, 90, 78, 78, 90, 50, 62, 22, 90, 10, 78, 38, 50, 10, 22, 0
sh_plus: .byte 2, 12, 41, 10, 59, 10, 59, 41, 90, 41, 90, 59, 59, 59, 59, 90, 41, 90, 41, 59, 10, 59, 10, 41, 41, 41, 0
sh_minus: .byte 2, 4, 12, 41, 88, 41, 88, 59, 12, 59, 0
sh_arrow: .byte 2, 7, 8, 36, 50, 36, 50, 12, 94, 50, 50, 88, 50, 64, 8, 64, 0
sh_circle_bar: .byte 1, 50, 50, 42, 1, 2, 4, 24, 42, 24, 58, 76, 58, 76, 42, 0
sh_circle_tri: .byte 1, 50, 50, 42, 1, 1, 50, 50, 28, 2, 2, 3, 50, 30, 70, 68, 30, 68, 0
sh_bulb: .byte 1, 50, 38, 30, 1, 2, 4, 36, 60, 64, 60, 64, 90, 36, 90, 0

.text
# gutter_unhover(): the pointer left the left lane
FN gutter_unhover
    cmp dword ptr [rip + gl_gutter_hot], 0
    je 0f
    mov dword ptr [rip + gl_gutter_hot], 0
    mov dword ptr [rip + g_dirty], 1
0:  cmp qword ptr [rip + g_gl_hover_line], -1
    je 1f
    mov qword ptr [rip + g_gl_hover_line], -1
    mov dword ptr [rip + g_dirty], 1
1:  ret
