# editor presentation: folding. A fold hides the lines after its header up to its last line; the
# header ends in a pill (` ⋯ `, or a provider's collapsed text) and a right chevron in the gutter's
# fold lane. Folds are kept as positions (the header's line feed, the last hidden line's) that
# follow edits; an edit inside the hidden text, or deleting the header's line feed, removes the
# fold. Ranges come from indentation: line L starts one when the next non-blank line is indented
# deeper; it ends at the last line before the next non-blank line indented no deeper than L,
# trailing blank lines excluded, so a closing brace stays visible. A language's fold_markers (a
# START line to its END line, nested, langconf.s) are ranges too.
#
# A document with folds scrolls by rows (wrap.s's row machinery, a hidden line has no rows). Its
# queries, fast for a fold hiding ten million lines (a cache of merged hidden intervals with counts):
#   fold_hidden(doc, line) -> eax 1           fold_next_visible / fold_prev_visible(doc, line)
#   fold_hidden_before(doc, line) -> rax      fold_row_line(doc, row) -> rax the line of a row
#   fold_at(doc, line) -> rax FLD* of a fold whose header the line is (the widest), or 0
#   rows_mode() -> eax 1 when the active document scrolls by rows (wrapped lines, or folds)
.include "rhun.inc"

.text

# ---------------- the hidden lines ----------------

# fold_cache(doc) -> rax the document's PRS, its hidden-line cache current (0 without folds)
fold_cache:
    mov rax, [rdi + DOC_pres]
    test rax, rax
    jz 9f
    cmp qword ptr [rax + PRS_folds + VEC_len], 0
    je 8f
    cmp dword ptr [rip + cfg_folding], 0
    je 8f                       # folding turned off: folds hide nothing
    mov rcx, [rdi + DOC_version]
    cmp [rax + PRS_hidver], rcx
    jne 1f
    mov rcx, [rax + PRS_gen]
    inc rcx
    cmp [rax + PRS_hidgen], rcx
    jne 1f
    ret
1:  jmp fold_rebuild
8:  mov qword ptr [rax + PRS_hidden], 0
    mov qword ptr [rax + PRS_hid + VEC_len], 0
    mov qword ptr [rax + PRS_hidgen], 0     # built again when folds hide lines again
    xor eax, eax
9:  ret

# fold_rebuild(doc) -> rax PRS: the merged hidden intervals of the folds, with counts
fold_rebuild:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + DOC_pres]
    mov rax, [rbx + DOC_version]
    mov [r12 + PRS_hidver], rax
    mov rax, [r12 + PRS_gen]
    inc rax
    mov [r12 + PRS_hidgen], rax
    mov qword ptr [r12 + PRS_hid + VEC_len], 0
    mov qword ptr [r12 + PRS_hidden], 0
    xor r13d, r13d
1:  cmp r13, [r12 + PRS_folds + VEC_len]
    jae 5f
    imul r14, r13, FLD_SIZE
    add r14, [r12 + PRS_folds + VEC_ptr]
    inc r13
    mov rdi, rbx
    mov rsi, [r14 + FLD_a]
    call doc_line_of
    lea r15, [rax + 1]          # first hidden
    mov rdi, rbx
    mov rsi, [r14 + FLD_b]
    call doc_line_of
    cmp rax, r15
    jb 1b                       # (nothing hidden)
    # merged with the last interval when they touch or overlap (folds are sorted by header)
    mov rcx, [r12 + PRS_hid + VEC_len]
    test rcx, rcx
    jz 3f
    dec rcx
    imul rcx, rcx, HI_SIZE
    add rcx, [r12 + PRS_hid + VEC_ptr]
    mov rdx, [rcx + HI_last]
    inc rdx
    cmp r15, rdx
    ja 3f
    cmp rax, [rcx + HI_last]
    jbe 1b
    mov [rcx + HI_last], rax
    jmp 1b
3:  push rax
    push rax
    lea rdi, [r12 + PRS_hid]
    mov esi, HI_SIZE
    call vec_push
    pop rcx
    pop rcx
    mov [rax + HI_first], r15
    mov [rax + HI_last], rcx
    jmp 1b
5:  # the counts before each
    xor ecx, ecx
    xor edx, edx
6:  cmp rcx, [r12 + PRS_hid + VEC_len]
    jae 7f
    imul rax, rcx, HI_SIZE
    add rax, [r12 + PRS_hid + VEC_ptr]
    mov [rax + HI_before], rdx
    add rdx, [rax + HI_last]
    sub rdx, [rax + HI_first]
    inc rdx
    inc rcx
    jmp 6b
7:  mov [r12 + PRS_hidden], rdx
    mov rax, r12
    EPILOGUE

# hid_find(rax PRS, rsi line) -> rcx the interval holding the line or the last one before it
# (index; -1 when none), rdx its HI* (0 for none). Keeps rax, rsi, rdi.
hid_find:
    xor ecx, ecx                # lo
    mov rdx, [rax + PRS_hid + VEC_len]   # hi
1:  cmp rcx, rdx
    jae 2f
    lea r8, [rcx + rdx]
    shr r8, 1
    imul r9, r8, HI_SIZE
    add r9, [rax + PRS_hid + VEC_ptr]
    cmp [r9 + HI_first], rsi
    ja 11f
    lea rcx, [r8 + 1]
    jmp 1b
11: mov rdx, r8
    jmp 1b
2:  dec rcx                     # the last interval starting at or before the line
    js 8f
    imul rdx, rcx, HI_SIZE
    add rdx, [rax + PRS_hid + VEC_ptr]
    ret
8:  mov rcx, -1
    xor edx, edx
    ret

# fold_hidden(doc, line) -> eax 1 when the line is hidden
FN fold_hidden
    push rsi
    call fold_cache
    pop rsi
    test rax, rax
    jz 8f
    call hid_find
    test rdx, rdx
    jz 8f
    cmp rsi, [rdx + HI_last]
    ja 8f
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# fold_next_visible(doc, line) -> rax the line, or the first visible one after it
FN fold_next_visible
    push rsi
    call fold_cache
    pop rsi
    test rax, rax
    jz 8f
    call hid_find
    test rdx, rdx
    jz 8f
    cmp rsi, [rdx + HI_last]
    ja 8f
    mov rax, [rdx + HI_last]
    inc rax
    ret
8:  mov rax, rsi
    ret

# fold_prev_visible(doc, line) -> rax the line, or the last visible one before it (the header)
FN fold_prev_visible
    push rsi
    call fold_cache
    pop rsi
    test rax, rax
    jz 8f
    call hid_find
    test rdx, rdx
    jz 8f
    cmp rsi, [rdx + HI_last]
    ja 8f
    mov rax, [rdx + HI_first]
    dec rax
    ret
8:  mov rax, rsi
    ret

# fold_hidden_before(doc, line) -> rax the hidden lines before the line
FN fold_hidden_before
    push rsi
    call fold_cache
    pop rsi
    test rax, rax
    jz 8f
    call hid_find
    test rdx, rdx
    jz 8f
    mov rax, [rdx + HI_before]
    mov rcx, [rdx + HI_last]
    cmp rsi, rcx
    jbe 1f
    lea rcx, [rcx + 1]          # all of it is before
    sub rcx, [rdx + HI_first]
    add rax, rcx
    ret
1:  mov rcx, rsi                # inside it: the part before the line
    sub rcx, [rdx + HI_first]
    add rax, rcx
    ret
8:  xor eax, eax
    ret

# fold_row_line(doc, row) -> rax the line whose visible index is row
FN fold_row_line
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call fold_cache
    test rax, rax
    jz 8f
    # the last interval whose first line's row is at or before the row: row(first) = first - before
    xor ecx, ecx
    mov rdx, [rax + PRS_hid + VEC_len]
1:  cmp rcx, rdx
    jae 2f
    lea r8, [rcx + rdx]
    shr r8, 1
    imul r9, r8, HI_SIZE
    add r9, [rax + PRS_hid + VEC_ptr]
    mov r10, [r9 + HI_first]
    sub r10, [r9 + HI_before]
    cmp r10, r12
    ja 11f
    lea rcx, [r8 + 1]
    jmp 1b
11: mov rdx, r8
    jmp 1b
2:  test rcx, rcx
    jz 8f
    dec rcx
    imul rdx, rcx, HI_SIZE
    add rdx, [rax + PRS_hid + VEC_ptr]
    mov rax, [rdx + HI_last]
    sub rax, [rdx + HI_first]
    inc rax
    add rax, [rdx + HI_before]  # hidden lines up to its end
    add rax, r12
    EPILOGUE
8:  mov rax, r12
    EPILOGUE

# rows_mode() -> eax 1 when the active document scrolls by rows: wrapped lines, or folds. Keeps
# every register but rax.
FN rows_mode
    mov eax, 1
    cmp dword ptr [rip + cfg_word_wrap], 0
    jne 9f
    xor eax, eax
    push rcx
    mov rcx, [rip + g_doc]
    test rcx, rcx
    jz 8f
    mov rcx, [rcx + DOC_pres]
    test rcx, rcx
    jz 8f
    cmp qword ptr [rcx + PRS_folds + VEC_len], 0
    setne al
    and eax, [rip + cfg_folding]
    cmp qword ptr [rip + gh_rows], 0                # or rows of ghost text (ghost.s)
    jne 7f
    cmp qword ptr [rcx + PRS_lens + VEC_len], 0     # or code lens rows (lens.s)
    je 8f
    cmp dword ptr [rip + cfg_code_lens], 0
    je 8f
7:  mov eax, 1
8:  pop rcx
9:  ret

# fold_view_sync(doc): the scroll's form follows the mode (lines: DOC_scrolly; rows: the top line
# and DOC_woff rows into it) and the top line is a visible one
FN fold_view_sync
    PROLOGUE
    mov rbx, rdi
    call rows_mode
    mov r12d, eax
    test dword ptr [rbx + DOC_flags], DF_ROWS
    setnz cl
    movzx ecx, cl
    cmp r12d, ecx
    je 3f
    cmp dword ptr [rip + cfg_word_wrap], 0
    jne 2f                      # wrapped mode keeps its own rows
    test r12d, r12d
    jz 1f
    # lines -> rows
    mov rax, [rbx + DOC_scrolly]
    mov rcx, rax
    and ecx, 255
    mov [rbx + DOC_woff], rcx
    shr rax, 8
    mov [rbx + DOC_wtop], rax
    jmp 2f
1:  # rows -> lines
    mov rax, [rbx + DOC_scrolly]
    shr rax, 8
    xor ecx, ecx
    cmp rax, [rbx + DOC_wtop]
    jne 11f
    mov rcx, [rbx + DOC_woff]
    cmp rcx, 255
    jbe 11f
    mov ecx, 255
11: shl rax, 8
    or rax, rcx
    mov [rbx + DOC_scrolly], rax
2:  and dword ptr [rbx + DOC_flags], ~DF_ROWS
    test r12d, r12d
    jz 3f
    or dword ptr [rbx + DOC_flags], DF_ROWS
3:  # a hidden top line: its fold's header, from its start
    test r12d, r12d
    jz 9f
    mov rsi, [rbx + DOC_scrolly]
    shr rsi, 8
    mov rdi, rbx
    call fold_hidden
    test eax, eax
    jz 9f
    mov rsi, [rbx + DOC_scrolly]
    shr rsi, 8
    mov rdi, rbx
    call fold_prev_visible
    mov [rbx + DOC_wtop], rax
    mov qword ptr [rbx + DOC_woff], 0
    shl rax, 8
    mov [rbx + DOC_scrolly], rax
9:  EPILOGUE

# fold_scroll_rows(doc) -> rax the lines the view scrolls through (folded ones left out)
FN fold_scroll_rows
    push rbx
    mov rbx, rdi
    mov rsi, [rbx + DOC_nlines]
    call fold_hidden_before
    mov rcx, [rbx + DOC_nlines]
    sub rcx, rax
    mov rax, rcx
    pop rbx
    ret

# fold_scroll_value(doc) -> rax the scroll in 1/256 of those lines: DOC_scrolly less the folded
# lines above the top (and the rows' offset into the top line in rows mode, unwrapped)
FN fold_scroll_value
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, [rbx + DOC_scrolly]
    mov rsi, r12
    shr rsi, 8
    call fold_hidden_before
    shl rax, 8
    sub r12, rax
    test dword ptr [rbx + DOC_flags], DF_ROWS
    jz 1f
    cmp dword ptr [rip + cfg_word_wrap], 0
    jne 1f
    mov rax, [rbx + DOC_scrolly]
    shr rax, 8
    cmp rax, [rbx + DOC_wtop]
    jne 1f
    and r12, -256
    mov rax, [rbx + DOC_woff]
    cmp rax, 255
    jbe 2f
    mov eax, 255
2:  add r12, rax
1:  mov rax, r12
    add rsp, 8
    pop r12
    pop rbx
    ret

# fold_scroll_set(doc, value): the scroll from a value in those 1/256 lines (a scrollbar drag)
FN fold_scroll_set
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jns 1f
    xor r12d, r12d
1:  mov rsi, r12
    shr rsi, 8
    call fold_row_line
    mov rcx, r12
    and ecx, 255
    mov [rbx + DOC_wtop], rax
    mov [rbx + DOC_woff], rcx
    shl rax, 8
    or rax, rcx
    mov [rbx + DOC_scrolly], rax
    add rsp, 8
    pop r12
    pop rbx
    ret

# fold_toggle_line(doc, line): the fold lane's click: the line's folds open, or the range it starts
# folds
FN fold_toggle_line
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [rip + cfg_folding], 0
    je 9f
    call fold_unfold_line
    test rax, rax
    jnz 9f
    mov rdi, rbx
    mov rsi, r12
    call range_end
    test rax, rax
    js 9f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call fold_add
    call fold_caret_out
9:  EPILOGUE

# fold_line_inlays(doc, line): the pill at a folded header's end, to vt_add
FN fold_line_inlays
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [rip + cfg_folding], 0
    je 9f
    call fold_at
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_text
    lea r14, [rip + vi_fold]
    mov [r14 + VI_off], rdx
    mov byte ptr [r14 + VI_side], VS_AFTER
    mov byte ptr [r14 + VI_kind], VK_FOLD
    mov word ptr [r14 + VI_flags], 0
    mov [r14 + VI_ref], r12
    mov dword ptr [r14 + VI_prio], 0
    mov dword ptr [r14 + VI_cells], 0
    lea rax, [rip + .Lpill]
    mov ecx, .Lpill_end - .Lpill
    mov rdx, [r13 + FLD_text]
    test rdx, rdx
    jz 1f
    mov rax, rdx
    mov rdi, rdx
    push rax
    push rax
    call strlen
    mov rcx, rax
    pop rax
    pop rax
1:  mov [r14 + VI_text], rax
    mov [r14 + VI_len], ecx
    COLOR eax, T_INLAY
    mov [r14 + VI_fg], eax
    COLOR eax, T_INLAY_BG
    mov [r14 + VI_bg], eax
    mov rdi, r14
    call vt_add
9:  EPILOGUE

# ---------------- folds ----------------

# fold_at(doc, line) -> rax FLD* of the widest fold whose header the line is, or 0
FN fold_at
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + DOC_pres]
    test r13, r13
    jz 8f
    cmp qword ptr [r13 + PRS_folds + VEC_len], 0
    je 8f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    mov r14, rax                # the header's line feed would be here
    xor r15d, r15d              # the widest so far
    xor ecx, ecx
1:  cmp rcx, [r13 + PRS_folds + VEC_len]
    jae 7f
    imul rax, rcx, FLD_SIZE
    add rax, [r13 + PRS_folds + VEC_ptr]
    inc rcx
    cmp [rax + FLD_a], r14
    jne 1b
    test r15, r15
    jz 2f
    mov rdx, [rax + FLD_b]
    cmp rdx, [r15 + FLD_b]
    jbe 1b
2:  mov r15, rax
    jmp 1b
7:  mov rax, r15
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# fold_add(doc, header, last): a fold of lines header+1..last (kept sorted; an equal one is not
# added twice)
FN fold_add
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r13, r12
    jbe 9f
    cmp r13, [rbx + DOC_nlines]
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    mov r12, rax                # a
    mov rdi, rbx
    mov rsi, r13
    call doc_line_end
    mov rdx, rax                # b
    mov rdi, rbx
    mov rsi, r12
    call fold_add_at
9:  EPILOGUE

# fold_add_at(doc, a, b): a fold from the header's line feed a to the last line's b; a provider's
# range with the same lines gives it its collapsed text
fold_add_at:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    call pres_ensure
    mov r15, rax
    # its place
    xor r14d, r14d
1:  cmp r14, [r15 + PRS_folds + VEC_len]
    jae 3f
    imul rax, r14, FLD_SIZE
    add rax, [r15 + PRS_folds + VEC_ptr]
    cmp [rax + FLD_a], r12
    jb 2f
    ja 3f
    cmp [rax + FLD_b], r13
    je 9f                       # already folded
2:  inc r14
    jmp 1b
3:  lea rdi, [r15 + PRS_folds]
    mov esi, FLD_SIZE
    call vec_push
    mov rcx, [r15 + PRS_folds + VEC_len]
    dec rcx
    sub rcx, r14
    imul rdx, rcx, FLD_SIZE
    imul rsi, r14, FLD_SIZE
    add rsi, [r15 + PRS_folds + VEC_ptr]
    push rsi
    push rsi
    lea rdi, [rsi + FLD_SIZE]
    call memmove
    pop rax
    pop rax
    mov [rax + FLD_a], r12
    mov [rax + FLD_b], r13
    mov qword ptr [rax + FLD_text], 0
    mov r14, rax
    mov rdi, r15
    mov rsi, r12
    mov rdx, r13
    call fr_same
    test rax, rax
    jz 4f
    mov rdi, [rax + FRG_text]
    test rdi, rdi
    jz 4f
    call dup_cstr
    mov [r14 + FLD_text], rax
4:  mov rdi, rbx
    call pres_touch
9:  EPILOGUE

# fold_drop(doc, index): the fold goes
fold_drop:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + DOC_pres]
    imul rax, r12, FLD_SIZE
    add rax, [r13 + PRS_folds + VEC_ptr]
    mov r14, rax
    mov rdi, [r14 + FLD_text]
    call mem_free
    mov rcx, [r13 + PRS_folds + VEC_len]
    dec rcx
    mov [r13 + PRS_folds + VEC_len], rcx
    sub rcx, r12
    imul rdx, rcx, FLD_SIZE
    mov rdi, r14
    lea rsi, [r14 + FLD_SIZE]
    call memmove
    mov rdi, rbx
    call pres_touch
    EPILOGUE

# fold_unfold_line(doc, line) -> rax the folds whose header the line is, removed
FN fold_unfold_line
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r15d, r15d
    mov r13, [rbx + DOC_pres]
    test r13, r13
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    mov r14, rax
    xor ecx, ecx
1:  cmp rcx, [r13 + PRS_folds + VEC_len]
    jae 9f
    imul rax, rcx, FLD_SIZE
    add rax, [r13 + PRS_folds + VEC_ptr]
    cmp [rax + FLD_a], r14
    je 2f
    inc rcx
    jmp 1b
2:  push rcx
    push rcx
    mov rdi, rbx
    mov rsi, rcx
    call fold_drop
    pop rcx
    pop rcx
    inc r15
    jmp 1b
9:  mov rax, r15
    EPILOGUE

# fold_reveal(doc, pos) -> rax the folds removed so the position is no longer hidden
FN fold_reveal
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r15d, r15d
    mov r13, [rbx + DOC_pres]
    test r13, r13
    jz 9f
    xor r14d, r14d
1:  cmp r14, [r13 + PRS_folds + VEC_len]
    jae 9f
    imul rax, r14, FLD_SIZE
    add rax, [r13 + PRS_folds + VEC_ptr]
    cmp r12, [rax + FLD_a]
    jbe 2f
    cmp r12, [rax + FLD_b]
    ja 2f
    mov rdi, rbx
    mov rsi, r14
    call fold_drop
    inc r15
    jmp 1b
2:  inc r14
    jmp 1b
9:  mov rax, r15
    EPILOGUE

# fold_shift(doc, entry): an edit inside a fold's hidden text, or one taking its header's line feed,
# removes the fold; the others move with the text before them
FN fold_shift
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call fr_shift               # a provider's ranges move with the text
    mov r13, [rbx + DOC_pres]
    cmp qword ptr [r13 + PRS_folds + VEC_len], 0
    je 9f
    xor r14d, r14d
1:  cmp r14, [r13 + PRS_folds + VEC_len]
    jae 9f
    imul r15, r14, FLD_SIZE
    add r15, [r13 + PRS_folds + VEC_ptr]
    mov rsi, [r12 + TE_pos]
    cmp qword ptr [r12 + TE_ins], 0
    je 3f
    # an insert in (a, b]: inside the hidden lines
    cmp rsi, [r15 + FLD_a]
    jbe 4f
    cmp rsi, [r15 + FLD_b]
    ja 4f
    jmp 6f
3:  # a deletion [p, p + del) over [a, b]
    cmp rsi, [r15 + FLD_b]
    ja 4f
    mov rax, rsi
    add rax, [r12 + TE_del]
    cmp rax, [r15 + FLD_a]
    ja 6f
4:  mov rdi, [r15 + FLD_a]
    mov rdx, [r12 + TE_del]
    mov rcx, [r12 + TE_ins]
    mov r8d, GR_RIGHT           # an insert at the header's end goes before the fold
    call tape_shift
    mov [r15 + FLD_a], rax
    mov rdi, [r15 + FLD_b]
    call tape_shift
    mov [r15 + FLD_b], rax
    inc r14
    jmp 1b
6:  mov rdi, rbx
    mov rsi, r14
    call fold_drop
    jmp 1b
9:  EPILOGUE

# fold_clear(doc): every fold goes
FN fold_clear
    PROLOGUE
    mov rbx, rdi
    mov r13, [rbx + DOC_pres]
    test r13, r13
    jz 9f
1:  mov rcx, [r13 + PRS_folds + VEC_len]
    test rcx, rcx
    jz 9f
    dec rcx
    mov rdi, rbx
    mov rsi, rcx
    call fold_drop
    jmp 1b
9:  EPILOGUE

# ---------------- ranges ----------------

# indent_of(doc, line) -> eax the line's indentation in columns, or -1 for a blank line
indent_of:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call line_indent
    mov r13d, edx
    push rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_text
    pop rax
    cmp rax, rdx
    jb 1f
    mov eax, -1
    jmp 9f
1:  mov eax, r13d
9:  pop r13
    pop r12
    pop rbx
    ret

# ---------------- bracket ranges ----------------

# bracket_pair_info(al byte) -> eax open_ch, edx close_ch, ecx is_open (1: open, -1: close, 0: none)
bracket_pair_info:
    cmp al, '{'
    je 1f
    cmp al, '}'
    je 2f
    cmp al, '['
    je 3f
    cmp al, ']'
    je 4f
    cmp al, '('
    je 5f
    cmp al, ')'
    je 6f
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    ret
1:  mov eax, '{'
    mov edx, '}'
    mov ecx, 1
    ret
2:  mov eax, '{'
    mov edx, '}'
    mov ecx, -1
    ret
3:  mov eax, '['
    mov edx, ']'
    mov ecx, 1
    ret
4:  mov eax, '['
    mov edx, ']'
    mov ecx, -1
    ret
5:  mov eax, '('
    mov edx, ')'
    mov ecx, 1
    ret
6:  mov eax, '('
    mov edx, ')'
    mov ecx, -1
    ret

# bracket_match_forward(doc, pos, open_ch, close_ch) -> rax pos of matching close_ch, or -1
bracket_match_forward:
    PROLOGUE 48
    mov r13, rdi                # doc
    mov r12, rsi                # pos of open_ch
    inc r12                     # start from pos + 1
    mov [rsp + 8], edx          # open_ch
    mov [rsp + 16], ecx         # close_ch
    mov qword ptr [rsp + 24], 0 # depth
    mov qword ptr [rsp + 32], 150000 # max bytes
.Lbm_loop:
    dec qword ptr [rsp + 32]
    js .Lbm_not_found
    mov rdi, r13
    mov rsi, r12
    call doc_byte
    test eax, eax
    jz .Lbm_not_found           # EOF
    mov ebx, eax

    # check line comment //
    cmp ebx, '/'
    jne 1f
    lea rsi, [r12 + 1]
    mov rdi, r13
    call doc_byte
    cmp eax, '/'
    jne .Lbm_check_block_cmt
    add r12, 2
.Lbm_skip_line_cmt:
    mov rdi, r13
    mov rsi, r12
    call doc_byte
    test eax, eax
    jz .Lbm_not_found
    cmp eax, 10
    je .Lbm_next_char
    inc r12
    jmp .Lbm_skip_line_cmt

.Lbm_check_block_cmt:
    cmp eax, '*'
    jne 1f
    add r12, 2
.Lbm_skip_blk_cmt:
    mov rdi, r13
    mov rsi, r12
    call doc_byte
    test eax, eax
    jz .Lbm_not_found
    cmp eax, '*'
    jne .Lbm_skip_blk_cmt_next
    lea rsi, [r12 + 1]
    mov rdi, r13
    call doc_byte
    cmp eax, '/'
    jne .Lbm_skip_blk_cmt_next
    add r12, 2
    jmp .Lbm_loop
.Lbm_skip_blk_cmt_next:
    inc r12
    jmp .Lbm_skip_blk_cmt

1:  # check hash comment #
    cmp ebx, '#'
    jne 2f
    inc r12
.Lbm_skip_hash_cmt:
    mov rdi, r13
    mov rsi, r12
    call doc_byte
    test eax, eax
    jz .Lbm_not_found
    cmp eax, 10
    je .Lbm_next_char
    inc r12
    jmp .Lbm_skip_hash_cmt

2:  # check string literal
    cmp ebx, '"'
    je .Lbm_string
    cmp ebx, '\''
    je .Lbm_string
    cmp ebx, '`'
    je .Lbm_string
    jmp 3f

.Lbm_string:
    mov r14d, ebx               # quote char
    inc r12
.Lbm_str_loop:
    mov rdi, r13
    mov rsi, r12
    call doc_byte
    test eax, eax
    jz .Lbm_not_found
    cmp eax, '\\'
    jne .Lbm_str_no_esc
    add r12, 2
    jmp .Lbm_str_loop
.Lbm_str_no_esc:
    cmp eax, r14d
    je .Lbm_str_done
    cmp r14d, '`'
    je .Lbm_str_cont
    cmp eax, 10
    je .Lbm_next_char
.Lbm_str_cont:
    inc r12
    jmp .Lbm_str_loop
.Lbm_str_done:
    inc r12
    jmp .Lbm_loop

3:  # check bracket characters
    cmp ebx, [rsp + 8]          # open_ch
    jne 4f
    inc qword ptr [rsp + 24]    # depth++
    inc r12
    jmp .Lbm_loop

4:  cmp ebx, [rsp + 16]         # close_ch
    jne .Lbm_next_char
    mov rax, [rsp + 24]         # depth
    test rax, rax
    jz .Lbm_found
    dec qword ptr [rsp + 24]    # depth--
    inc r12
    jmp .Lbm_loop

.Lbm_next_char:
    inc r12
    jmp .Lbm_loop

.Lbm_found:
    mov rax, r12
    EPILOGUE

.Lbm_not_found:
    mov rax, -1
    EPILOGUE

# bracket_range_end(doc, line) -> rax last line of range (0-based), or -1
FN bracket_range_end
    PROLOGUE 48
    mov rbx, rdi                # doc
    mov r12, rsi                # line
    cmp r12, [rbx + DOC_nlines]
    jae .Lbre_none
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov r13, rax                # line start pos
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    mov r14, rax                # line end pos
    cmp r14, r13
    jbe .Lbre_none

    # find effective end of code (strip line comments)
    mov r15, r14
    mov rcx, r13
.Lbre_find_eff_end:
    cmp rcx, r14
    jae .Lbre_scan_brackets
    mov rdi, rbx
    mov rsi, rcx
    call doc_byte
    cmp eax, '/'
    jne 1f
    lea rsi, [rcx + 1]
    cmp rsi, r14
    jae 1f
    mov rdi, rbx
    call doc_byte
    cmp eax, '/'
    je .Lbre_comment_found
    cmp eax, '*'
    je .Lbre_comment_found
1:  cmp eax, '#'
    je .Lbre_comment_found
    cmp eax, '"'
    je .Lbre_eff_str
    cmp eax, '\''
    je .Lbre_eff_str
    cmp eax, '`'
    je .Lbre_eff_str
    inc rcx
    jmp .Lbre_find_eff_end

.Lbre_eff_str:
    mov edx, eax
    inc rcx
.Lbre_eff_str_loop:
    cmp rcx, r14
    jae .Lbre_scan_brackets
    mov rdi, rbx
    mov rsi, rcx
    call doc_byte
    cmp eax, '\\'
    jne 2f
    add rcx, 2
    jmp .Lbre_eff_str_loop
2:  cmp eax, edx
    je .Lbre_eff_str_done
    inc rcx
    jmp .Lbre_eff_str_loop
.Lbre_eff_str_done:
    inc rcx
    jmp .Lbre_find_eff_end

.Lbre_comment_found:
    mov r15, rcx

.Lbre_scan_brackets:
    mov rcx, r15
.Lbre_scan_loop:
    cmp rcx, r13
    jbe .Lbre_none
    dec rcx
    mov rdi, rbx
    mov rsi, rcx
    mov [rsp], rcx
    call doc_byte
    call bracket_pair_info
    cmp ecx, 1
    jne .Lbre_scan_loop
    mov [rsp + 8], rax          # open_ch
    mov [rsp + 16], rdx         # close_ch
    mov rdi, rbx
    mov rsi, [rsp]              # pos
    mov edx, [rsp + 8]
    mov ecx, [rsp + 16]
    call bracket_match_forward
    cmp rax, -1
    je .Lbre_scan_resume
    mov rdi, rbx
    mov rsi, rax
    call doc_line_of
    cmp rax, r12
    jbe .Lbre_scan_resume
    lea rdx, [r12 + 1]
    cmp rax, rdx
    je .Lbre_ret_range
    dec rax
.Lbre_ret_range:
    EPILOGUE

.Lbre_scan_resume:
    mov rcx, [rsp]
    jmp .Lbre_scan_loop

.Lbre_none:
    mov rax, -1
    EPILOGUE

# range_starts(doc, line) -> eax 1 when the line starts a foldable range
FN range_starts
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call fr_find                # a provider's ranges decide once it answered
    test edx, edx
    jz 0f
    test rax, rax
    setnz al
    movzx eax, al
    EPILOGUE
0:  mov rdi, rbx                # a fold_markers START line (the language configuration, langconf.s)
    mov rsi, r12
    call lc_fold_marker
    cmp eax, 1
    jne 71f
    EPILOGUE
71: mov rdi, rbx
    mov rsi, r12
    call bracket_range_end
    cmp rax, -1
    je 72f
    mov eax, 1
    EPILOGUE
72: mov rdi, rbx
    mov rsi, r12
    call indent_of
    test eax, eax
    js 8f
    mov r13d, eax
    lea r14, [r12 + 1]
    mov r15d, 64
1:  cmp r14, [rbx + DOC_nlines]
    jae 8f
    dec r15d
    js 8f
    mov rdi, rbx
    mov rsi, r14
    call indent_of
    inc r14
    test eax, eax
    js 1b
    cmp eax, r13d
    jle 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# range_end(doc, line) -> rax the last line of the range the line starts, or -1
FN range_end
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call fr_find
    test edx, edx
    jz 0f
    test rax, rax
    jz 8f
    mov rdi, rbx
    mov rsi, [rax + FRG_b]
    call doc_line_of
    EPILOGUE
0:  mov rdi, rbx
    mov rsi, r12
    call lc_fold_marker
    cmp eax, 1
    jne 71f
    # a marker region: to its END line, nested regions counted
    mov r13d, 1                 # depth
    lea r14, [r12 + 1]
4:  cmp r14, [rbx + DOC_nlines]
    jae 8f
    mov rdi, rbx
    mov rsi, r14
    call lc_fold_marker
    cmp eax, 1
    jne 5f
    inc r13d
    jmp 6f
5:  cmp eax, 2
    jne 6f
    dec r13d
    jnz 6f
    mov rax, r14
    EPILOGUE
6:  inc r14
    jmp 4b
71: mov rdi, rbx
    mov rsi, r12
    call bracket_range_end
    cmp rax, -1
    je 72f
    EPILOGUE
72: mov rdi, rbx
    mov rsi, r12
    call range_starts
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call indent_of
    mov r13d, eax
    mov r15, r12                # the last non-blank line inside so far
    lea r14, [r12 + 1]
1:  cmp r14, [rbx + DOC_nlines]
    jae 7f
    mov rdi, rbx
    mov rsi, r14
    call indent_of
    test eax, eax
    js 2f
    cmp eax, r13d
    jle 7f
    mov r15, r14
2:  inc r14
    jmp 1b
7:  cmp r15, r12
    je 8f
    mov rax, r15
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# ---------------- commands ----------------

# fold_doc() -> rax the active document when it can fold (not a diff view, folding on), or 0
fold_doc:
    mov rax, [rip + g_doc]
    test rax, rax
    jz 8f
    cmp dword ptr [rip + cfg_folding], 0
    je 8f
    cmp qword ptr [rax + DOC_diff], 0
    jne 8f
    ret
8:  xor eax, eax
    ret

# fold_innermost(doc, line) -> rax header, rdx last of the innermost unfolded range whose header
# is the line or that holds it; rax -1 for none
fold_innermost:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + DOC_pres]
    test rax, rax
    jz 0f
    cmp qword ptr [rax + PRS_frext], 0
    je 0f
    call fr_innermost
    EPILOGUE
0:  mov r13, r12                # the candidate header
    mov r15d, 2000              # search limit lines up
1:  mov rdi, rbx
    mov rsi, r13
    call range_end
    test rax, rax
    js 3f
    cmp rax, r12
    jb 3f                       # it ends above the line
    mov r14, rax
    # not one already folded
    mov rdi, rbx
    mov rsi, r13
    call fold_at
    test rax, rax
    jz 2f
    mov rdi, rbx
    mov rsi, [rax + FLD_b]
    call doc_line_of
    cmp rax, r14
    je 3f
2:  mov rax, r13
    mov rdx, r14
    EPILOGUE
3:  test r13, r13
    jz 8f
    dec r15d
    js 8f
    dec r13
    jmp 1b
8:  mov rax, -1
    EPILOGUE

FN cmd_fold
    PROLOGUE
    call fold_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rsi, [rbx + DOC_cur]
    mov rdi, rbx
    call doc_line_of
    mov rdi, rbx
    mov rsi, rax
    call fold_innermost
    test rax, rax
    js 9f
    mov rdi, rbx
    mov rsi, rax
    call fold_add
    call fold_caret_out
9:  EPILOGUE

FN cmd_unfold
    PROLOGUE
    call fold_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rsi, [rbx + DOC_cur]
    mov rdi, rbx
    call doc_line_of
    mov rdi, rbx
    mov rsi, rax
    call fold_unfold_line
9:  EPILOGUE

FN cmd_toggle_fold
    PROLOGUE
    call fold_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rsi, [rbx + DOC_cur]
    mov rdi, rbx
    call doc_line_of
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    call fold_unfold_line
    test rax, rax
    jnz 9f
    call cmd_fold
9:  EPILOGUE

FN cmd_unfold_all
    PROLOGUE
    call fold_doc
    test rax, rax
    jz 9f
    mov rdi, rax
    call fold_clear
9:  EPILOGUE

FN cmd_fold_all
    xor edi, edi
    jmp fold_levels
FN cmd_fold_level_1
    mov edi, 1
    jmp fold_levels
FN cmd_fold_level_2
    mov edi, 2
    jmp fold_levels
FN cmd_fold_level_3
    mov edi, 3
    jmp fold_levels

# fold_levels(depth): every range (depth 0) or those at that depth, in one pass over the lines with
# a stack of (line, indentation, deeper content seen): a line followed by a deeper one is a header,
# and its range ends at the last non-blank line before the next line indented no deeper
fold_levels:
    PROLOGUE 32
    mov [rsp], edi
    call fold_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp qword ptr [rbx + DOC_nlines], FOLD_ALL_MAX
    jbe 1f
    lea rdi, [rip + .Ltoo_long]
    call app_toast
    jmp 9f
1:  mov qword ptr [rip + fl_stack + VEC_len], 0
    mov rax, [rbx + DOC_pres]
    test rax, rax
    jz 2f
    cmp qword ptr [rax + PRS_frext], 0
    je 2f
    mov edi, [rsp]
    mov rsi, rbx
    call fr_levels              # a provider's ranges
    call fold_caret_out
    jmp 9f
2:  xor r12d, r12d              # line
    mov r15, -1                 # the last non-blank line
.Lfl_line:
    cmp r12, [rbx + DOC_nlines]
    jae .Lfl_end
    mov rdi, rbx
    mov rsi, r12
    call indent_of
    mov r13d, eax
    test r13d, r13d
    js .Lfl_next
    call fl_close_to            # the entries as deep or deeper end here
    # the one left on top is shallower: this line is its deeper content
    mov rcx, [rip + fl_stack + VEC_len]
    test rcx, rcx
    jz 2f
    dec rcx
    imul rcx, rcx, 24
    add rcx, [rip + fl_stack + VEC_ptr]
    mov qword ptr [rcx + 16], 1
2:  lea rdi, [rip + fl_stack]
    mov esi, 24
    call vec_push
    mov [rax], r12
    mov [rax + 8], r13
    mov r15, r12
.Lfl_next:
    inc r12
    jmp .Lfl_line
.Lfl_end:
    mov r13d, -1                # all the rest end at the last non-blank line
    call fl_close_to
    call fold_caret_out
9:  EPILOGUE
# fl_close_to(r13d indentation, -1: all): pops the entries indented at least that deep; each with
# deeper content is a range up to r15, folded when its depth is the one wanted ([rsp] of
# fold_levels' frame, 0: all)
fl_close_to:
    push r14
    sub rsp, 16
1:  mov rcx, [rip + fl_stack + VEC_len]
    test rcx, rcx
    jz 9f
    dec rcx
    imul rax, rcx, 24
    add rax, [rip + fl_stack + VEC_ptr]
    cmp r13d, -1
    je 2f
    cmp [rax + 8], r13d
    jl 9f
2:  mov [rip + fl_stack + VEC_len], rcx
    cmp qword ptr [rax + 16], 0
    je 1b                       # no deeper content: not a range
    mov r14, [rax]              # header
    mov edx, [rsp + 16 + 8 + 8] # the depth wanted
    test edx, edx
    jz 4f
    # its depth: the ranges below it on the stack, plus one
    mov r8d, 1
    xor r9d, r9d
3:  cmp r9, rcx
    jae 31f
    imul r10, r9, 24
    add r10, [rip + fl_stack + VEC_ptr]
    inc r9
    cmp qword ptr [r10 + 16], 0
    je 3b
    inc r8d
    jmp 3b
31: cmp r8d, edx
    jne 1b
4:  cmp r15, r14
    jbe 1b
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call fold_add
    jmp 1b
9:  add rsp, 16
    pop r14
    ret

# fold_caret_out(): a caret folds hid goes to its fold's header end (g_doc)
fold_caret_out:
    PROLOGUE
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov rsi, [rbx + DOC_cur]
    mov rdi, rbx
    call doc_line_of
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    call fold_hidden
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call fold_prev_visible
    mov rdi, rbx
    mov rsi, rax
    call doc_line_end
    mov [rbx + DOC_cur], rax
    mov [rbx + DOC_anchor], rax
9:  mov dword ptr [rip + g_dirty], 1
    mov dword ptr [rip + g_reveal], 1
    EPILOGUE

# ---------------- sessions ----------------
# A session line and a closed tab keep a document's folds as "H-E,H-E" (0-based header and last
# line, at most FOLD_SESSION_MAX); restoring keeps those with header < last < the line count.

# fold_session_out(doc, sb): "<TAB>folds=H-E,..." for a document with folds
FN fold_session_out
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + DOC_pres]
    test r13, r13
    jz 9f
    cmp qword ptr [r13 + PRS_folds + VEC_len], 0
    je 9f
    mov rdi, r12
    lea rsi, [rip + .Lfolds_eq]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    call fold_list_out
9:  EPILOGUE

# fold_list_out(doc, sb): "H-E,H-E..."
fold_list_out:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + DOC_pres]
    xor r14d, r14d
1:  cmp r14, [r13 + PRS_folds + VEC_len]
    jae 9f
    cmp r14, FOLD_SESSION_MAX
    jae 9f
    imul r15, r14, FLD_SIZE
    add r15, [r13 + PRS_folds + VEC_ptr]
    test r14, r14
    jz 2f
    mov rdi, r12
    mov esi, ','
    call sb_push_byte
2:  inc r14
    mov rdi, rbx
    mov rsi, [r15 + FLD_a]
    call doc_line_of
    mov rdi, r12
    mov rsi, rax
    call sb_push_u64
    mov rdi, r12
    mov esi, '-'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r15 + FLD_b]
    call doc_line_of
    mov rdi, r12
    mov rsi, rax
    call sb_push_u64
    jmp 1b
9:  EPILOGUE

# fold_session_string(doc) -> rax an owned "H-E,..." cstr of its folds, or 0 (a closed tab)
FN fold_session_string
    PROLOGUE
    mov rbx, rdi
    mov r13, [rbx + DOC_pres]
    test r13, r13
    jz 8f
    cmp qword ptr [r13 + PRS_folds + VEC_len], 0
    je 8f
    lea rdi, [rip + fs_tmp]
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + fs_tmp]
    call fold_list_out
    mov rdi, [rip + fs_tmp + SB_ptr]
    mov rsi, [rip + fs_tmp + SB_len]
    call mem_dup
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# fold_session_in(doc, cstr): the folds a session line's fields name ("folds=" after a tab), or a
# closed tab's "H-E,..." (cstr 0: none)
FN fold_session_in
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 9f
    cmp dword ptr [rip + cfg_folding], 0
    je 9f                       # folding is off: nothing is restored
    # after "folds=" when there is one, else the string itself is the list
    mov r13, r12
1:  cmp byte ptr [r13], 0
    je 2f
    mov rdi, r13
    lea rsi, [rip + .Lfolds_eq + 1]
    call cstr_starts
    test eax, eax
    jnz 3f
    inc r13
    jmp 1b
2:  cmp byte ptr [r12], '0'
    jb 9f
    cmp byte ptr [r12], '9'
    ja 9f
    mov r13, r12
    jmp 4f
3:  add r13, 6
4:  # H-E pairs
    mov rdi, r13
    call num_at
    test edx, edx
    jz 9f
    mov r14, rax
    add r13, rcx
    cmp byte ptr [r13], '-'
    jne 9f
    inc r13
    mov rdi, r13
    call num_at
    test edx, edx
    jz 9f
    add r13, rcx
    cmp r14, rax
    jae 5f
    cmp rax, [rbx + DOC_nlines]
    jae 5f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, rax
    call fold_add
5:  cmp byte ptr [r13], ','
    jne 9f
    inc r13
    jmp 4b
9:  EPILOGUE

# num_at(cstr) -> rax the decimal number at its start, rcx its digits, edx 1 (0: none)
num_at:
    xor eax, eax
    xor ecx, ecx
    xor edx, edx
1:  movzx r8d, byte ptr [rdi + rcx]
    sub r8d, '0'
    cmp r8d, 9
    ja 9f
    cmp rcx, 18
    jae 9f
    imul rax, rax, 10
    add rax, r8
    inc rcx
    mov edx, 1
    jmp 1b
9:  ret

# cstr_starts(s, prefix) -> eax 1 when s starts with prefix
cstr_starts:
    xor ecx, ecx
1:  movzx eax, byte ptr [rsi + rcx]
    test eax, eax
    jz 8f
    cmp al, [rdi + rcx]
    jne 9f
    inc rcx
    jmp 1b
8:  mov eax, 1
    ret
9:  xor eax, eax
    ret

# fold_step(doc, line, delta) -> rax the line delta visible lines away (folded ones not counted),
# kept inside the text
FN fold_step
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
1:  test r13, r13
    jz 9f
    js 3f
    lea rsi, [r12 + 1]
    cmp rsi, [rbx + DOC_nlines]
    jae 9f
    mov rdi, rbx
    call fold_next_visible
    cmp rax, [rbx + DOC_nlines]
    jae 9f
    mov r12, rax
    dec r13
    jmp 1b
3:  test r12, r12
    jz 9f
    lea rsi, [r12 - 1]
    mov rdi, rbx
    call fold_prev_visible
    mov r12, rax
    inc r13
    jmp 1b
9:  mov rax, r12
    EPILOGUE

# fold_last_line(doc, line) -> rax the line, or the last line its folds hide (line commands take a
# folded header with its hidden lines)
FN fold_last_line
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call fold_at
    test rax, rax
    jz 1f
    mov rdi, rbx
    mov rsi, [rax + FLD_b]
    call doc_line_of
    EPILOGUE
1:  mov rax, r12
    EPILOGUE

# fold_skip(doc, pos, dir) -> rax the position, or for one folds hide the start of the first visible
# line after them (dir > 0) or the end of their header (dir < 0): caret motion steps over folds
FN fold_skip
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rax, r12
    mov rcx, [rbx + DOC_pres]
    test rcx, rcx
    jz 9f
    cmp qword ptr [rcx + PRS_folds + VEC_len], 0
    je 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov r14, rax
    mov rdi, rbx
    mov rsi, r14
    call fold_hidden
    test eax, eax
    mov rax, r12
    jz 9f
    test r13d, r13d
    js 2f
    mov rdi, rbx
    mov rsi, r14
    call fold_next_visible
    cmp rax, [rbx + DOC_nlines]
    jae 1f
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    EPILOGUE
1:  mov rdi, rbx                # the folds reach the end: stay at the header's end
2:  mov rdi, rbx
    mov rsi, r14
    call fold_prev_visible
    mov rdi, rbx
    mov rsi, rax
    call doc_line_end
9:  EPILOGUE

# fold_touch(doc): the caret moved: a fold that hides it opens (go to line, find, select, undo)
FN fold_touch
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    mov r12, [rbx + DOC_pres]
    test r12, r12
    jz 9f
    cmp qword ptr [r12 + PRS_folds + VEC_len], 0
    je 9f
    mov rsi, [rbx + DOC_cur]
    mov rdi, rbx
    call doc_line_of
    mov rdi, rbx
    mov rsi, rax
    call fold_hidden
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call fold_reveal
9:  EPILOGUE

# ---------------- a provider's ranges ----------------

# fr_lower(PRS, a) -> rax the index of the first range whose header's line feed is at or after a.
# Keeps rdi, rsi.
fr_lower:
    xor eax, eax
    mov rdx, [rdi + PRS_fr + VEC_len]
1:  cmp rax, rdx
    jae 9f
    lea rcx, [rax + rdx]
    shr rcx, 1
    imul r8, rcx, FRG_SIZE
    add r8, [rdi + PRS_fr + VEC_ptr]
    cmp [r8 + FRG_a], rsi
    jae 2f
    lea rax, [rcx + 1]
    jmp 1b
2:  mov rdx, rcx
    jmp 1b
9:  ret

# fr_find(doc, line) -> rax FR* of the widest provider range whose header is the line, or 0; edx 1
# when the document's ranges come from a provider (0: indentation decides)
fr_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + DOC_pres]
    test r13, r13
    jz 8f
    cmp qword ptr [r13 + PRS_frext], 0
    je 8f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    mov r14, rax
    mov rdi, r13
    mov rsi, r14
    call fr_lower
    mov rcx, rax
    xor r15d, r15d
1:  cmp rcx, [r13 + PRS_fr + VEC_len]
    jae 7f
    imul r8, rcx, FRG_SIZE
    add r8, [r13 + PRS_fr + VEC_ptr]
    cmp [r8 + FRG_a], r14
    jne 7f
    inc rcx
    mov rax, [r8 + FRG_b]
    cmp rax, r14
    jbe 1b                      # edits collapsed it
    test r15, r15
    jz 2f
    cmp rax, [r15 + FRG_b]
    jbe 1b
2:  mov r15, r8
    jmp 1b
7:  mov rax, r15
    mov edx, 1
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# fr_same(PRS, a, b) -> rax FR* of a provider range from a to b, or 0
fr_same:
    push rbx
    mov rbx, rdx
    call fr_lower
1:  cmp rax, [rdi + PRS_fr + VEC_len]
    jae 8f
    imul rcx, rax, FRG_SIZE
    add rcx, [rdi + PRS_fr + VEC_ptr]
    cmp [rcx + FRG_a], rsi
    jne 8f
    inc rax
    cmp [rcx + FRG_b], rbx
    jne 1b
    mov rax, rcx
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret

# fr_shift(doc, entry): the provider's ranges move with an edit (they stay; its next answer, half a
# second later, replaces them)
fr_shift:
    PROLOGUE
    mov r13, [rdi + DOC_pres]
    mov r14, [r13 + PRS_fr + VEC_len]
    test r14, r14
    jz 9f
    mov r12, rsi
    mov r15, [r13 + PRS_fr + VEC_ptr]
    mov rsi, [r12 + TE_pos]
    mov rdx, [r12 + TE_del]
    mov rcx, [r12 + TE_ins]
    mov r8d, GR_RIGHT
1:  mov rdi, [r15 + FRG_a]
    call tape_shift
    mov [r15 + FRG_a], rax
    mov rdi, [r15 + FRG_b]
    call tape_shift
    mov [r15 + FRG_b], rax
    add r15, FRG_SIZE
    dec r14
    jnz 1b
9:  EPILOGUE

# fd_has(PRS, a, b) -> eax 1 when a fold from a to b exists
fd_has:
    xor ecx, ecx
1:  cmp rcx, [rdi + PRS_folds + VEC_len]
    jae 8f
    imul rax, rcx, FLD_SIZE
    add rax, [rdi + PRS_folds + VEC_ptr]
    inc rcx
    cmp [rax + FLD_a], rsi
    jne 1b
    cmp [rax + FLD_b], rdx
    jne 1b
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# fr_innermost(doc, line) -> rax header, rdx last of the narrowest provider range not folded yet
# whose header is the line or that holds it; rax -1 for none
fr_innermost:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, [rbx + DOC_pres]
    call doc_line_end
    mov r13, rax                # the line's line feed
    mov r14, -1                 # the best's span
    xor r15d, r15d              # the best
    xor ecx, ecx
1:  cmp rcx, [r12 + PRS_fr + VEC_len]
    jae 5f
    imul rax, rcx, FRG_SIZE
    add rax, [r12 + PRS_fr + VEC_ptr]
    inc rcx
    cmp [rax + FRG_a], r13
    ja 5f                       # sorted: the rest start below the line
    cmp [rax + FRG_b], r13
    jb 1b
    mov rdx, [rax + FRG_b]
    sub rdx, [rax + FRG_a]
    jz 1b
    cmp rdx, r14
    jae 1b
    mov [rsp], rcx
    mov [rsp + 8], rax
    mov rdi, r12
    mov rsi, [rax + FRG_a]
    mov rdx, [rax + FRG_b]
    call fd_has
    mov rcx, [rsp]
    test eax, eax
    jnz 1b
    mov r15, [rsp + 8]
    mov r14, [r15 + FRG_b]
    sub r14, [r15 + FRG_a]
    jmp 1b
5:  test r15, r15
    jz 8f
    mov rdi, rbx
    mov rsi, [r15 + FRG_b]
    call doc_line_of
    mov [rsp], rax
    mov rdi, rbx
    mov rsi, [r15 + FRG_a]
    call doc_line_of
    mov rdx, [rsp]
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# fr_levels(depth, doc): the provider's ranges at that depth (0: all) fold; a range's depth is one
# more than the ranges holding it
fr_levels:
    PROLOGUE 16
    mov [rsp], edi
    mov rbx, rsi
    mov r12, [rbx + DOC_pres]
    mov qword ptr [rip + fr_stack + VEC_len], 0
    xor r13d, r13d
1:  cmp r13, [r12 + PRS_fr + VEC_len]
    jae 9f
    imul r14, r13, FRG_SIZE
    add r14, [r12 + PRS_fr + VEC_ptr]
    inc r13
    mov rax, [r14 + FRG_b]
    cmp rax, [r14 + FRG_a]
    jbe 1b
    # the ranges ending before this header no longer hold anything
2:  mov rcx, [rip + fr_stack + VEC_len]
    test rcx, rcx
    jz 3f
    mov rdx, [rip + fr_stack + VEC_ptr]
    mov rax, [rdx + rcx*8 - 8]
    cmp rax, [r14 + FRG_a]
    jae 3f
    dec qword ptr [rip + fr_stack + VEC_len]
    jmp 2b
3:  mov r15, [rip + fr_stack + VEC_len]
    inc r15                     # its depth
    lea rdi, [rip + fr_stack]
    mov esi, 8
    call vec_push
    mov rcx, [r14 + FRG_b]
    mov [rax], rcx
    mov eax, [rsp]
    test eax, eax
    jz 4f
    cmp r15, rax
    jne 1b
4:  mov rdi, r12
    mov rsi, [r14 + FRG_a]
    mov rdx, [r14 + FRG_b]
    call fd_has
    test eax, eax
    jnz 1b
    mov rdi, rbx
    mov rsi, [r14 + FRG_a]
    mov rdx, [r14 + FRG_b]
    call fold_add_at
    jmp 1b
9:  EPILOGUE

# FN fold_ranges_set(doc, ext): the ranges of an answer (fr_new, present.s) become the document's,
# sorted by header; indentation no longer decides for it
FN fold_ranges_set
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    call pres_ensure
    mov r12, rax
    lea rdi, [r12 + PRS_fr]
    call fr_vec_clear
    # sort keys: the header's line feed, then the answer's order
    mov r13, [rip + fr_new + VEC_len]
    mov qword ptr [rip + fr_keys + VEC_len], 0
    xor r14d, r14d
1:  cmp r14, r13
    jae 2f
    lea rdi, [rip + fr_keys]
    mov esi, 8
    call vec_push
    imul rcx, r14, FRG_SIZE
    add rcx, [rip + fr_new + VEC_ptr]
    mov rcx, [rcx + FRG_a]
    shl rcx, 16
    or rcx, r14
    mov [rax], rcx
    inc r14
    jmp 1b
2:  mov rdi, [rip + fr_keys + VEC_ptr]
    mov rsi, r13
    call sort_u64
    xor r14d, r14d
3:  cmp r14, r13
    jae 4f
    lea rdi, [r12 + PRS_fr]
    mov esi, FRG_SIZE
    call vec_push
    mov rdi, rax
    mov rsi, [rip + fr_keys + VEC_ptr]
    mov rsi, [rsi + r14*8]
    and esi, 0xffff
    imul rsi, rsi, FRG_SIZE
    add rsi, [rip + fr_new + VEC_ptr]
    mov edx, FRG_SIZE
    call memcpy
    inc r14
    jmp 3b
4:  mov qword ptr [rip + fr_new + VEC_len], 0   # the texts moved with the records
    mov rax, [rsp]
    mov [r12 + PRS_frext], rax
    mov rdi, rbx
    call pres_touch
    EPILOGUE

# FN fold_ext_gone(ext): documents whose ranges came from that extension go back to indentation
FN fold_ext_gone
    PROLOGUE
    mov r12, rdi
    xor r13d, r13d
1:  cmp r13, [rip + g_tabs + VEC_len]
    jae 9f
    imul rax, r13, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    inc r13
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 1b
    mov rbx, [rax + TAB_doc]
    test rbx, rbx
    jz 1b
    mov r14, [rbx + DOC_pres]
    test r14, r14
    jz 1b
    cmp [r14 + PRS_frext], r12
    jne 1b
    lea rdi, [r14 + PRS_fr]
    call fr_vec_clear
    mov qword ptr [r14 + PRS_frext], 0
    mov rdi, rbx
    call pres_touch
    jmp 1b
9:  EPILOGUE

.section .rodata
.Ltoo_long: .asciz "Too many lines to fold them all"
.Lfolds_eq: .asciz "\tfolds="
.Lpill: .ascii " \342\213\257 "
.Lpill_end:

.bss
.p2align 3
fl_stack: .zero VEC_SIZE        # fold_levels: open headers (line, indentation, deeper seen: 24 bytes)
fr_stack: .zero VEC_SIZE        # fr_levels: the ends of the provider ranges holding the next (8 bytes)
vi_fold: .zero VI_SIZE
fs_tmp: .zero SB_SIZE
fr_keys: .zero VEC_SIZE         # fold_ranges_set's sort keys
