# editor view: rendering, mouse, keyboard editing on the active document
.include "rhun.inc"

.text
# Drop every grammar-dependent class/bracket cache without touching the document text.
FN editor_language_changed
    cmp [rip + cls_doc], rdi
    jne 1f
    mov qword ptr [rip + cls_doc], 0
1:  cmp [rip + g_long_doc], rdi
    jne 2f
    mov qword ptr [rip + g_long_doc], 0
2:  cmp [rip + g_br_doc], rdi
    jne 3f
    mov qword ptr [rip + g_br_doc], 0
3:  ret

.equ ID_EDITOR, 0x1001
.equ ID_EDSCROLL, 0x1002
.equ ID_EDHSCROLL, 0x1004          # along the bottom, when lines do not wrap
.equ CLS_LONG, 4096                # bytes of a line whose classes are kept across frames
.equ WIDEST_FULL, 1 << 20       # bytes measured again on every change (about a millisecond)
.equ WIDEST_VISIBLE, 1 << 16    # total bytes measured from visible lines while editing a large text
.equ WIDEST_PAUSE, 400          # ms without edits before a longer text is measured again
.equ BLINK_MS, 530              # each half of the caret's blink
.equ BLINK_FOR, 30000           # it blinks this long after the last caret activity, then stays on

.bss
.p2align 3
.globl g_doc, g_reveal, g_blink_t0
g_doc: .quad 0
g_reveal: .long 0
.globl g_ed_cell
g_ed_cell: .long 0              # notebooks: editor_draw draws a cell (1), the one with the keyboard (3)
g_ed_x: .long 0
g_ed_y: .long 0
g_ed_w: .long 0
g_ed_h: .long 0
g_ed_tx: .long 0                # x of column 0 (before horizontal scroll)
ed_hovered: .long 0             # the pointer was over the editor this frame (hover tracking)
g_dragging: .long 0
hs_on: .long 0                  # the horizontal scrollbar is shown (hscroll_measure)
hs_content: .long 0             # px: the widest line and a margin
hs_view: .long 0                # px: the text area
hs_off: .long 0                 # px: DOC_scrollx for the scrollbar
hs_track: .zero 16              # x, y, w, h
ww_col: .long 0                 # widest_span: columns of the current line
ww_max: .long 0                 # and of the widest so far
.p2align 3
widest_due: .quad 0             # time_ms when a long text paused in doc_widest is measured, 0 none
.p2align 3
g_blink_t0: .quad 0
blink_seen: .long 0             # the half of the blink the last frame was asked for
caret_frame: .long 0            # this frame drew the caret that has the keyboard (ed_caret_shown)
caret_seen: .long 0             # the last frame did: only then is there a caret to blink
classes: .zero SB_SIZE          # per-byte syntax class for the line being drawn
clip_sb: .zero SB_SIZE
.globl g_ed_find
g_ed_find: .zero SB_SIZE        # find highlight text (set by the find bar)

.text

# ed_sel(doc) -> rax start, rdx end
FN ed_sel
    mov rax, [rdi + DOC_cur]
    mov rdx, [rdi + DOC_anchor]
    cmp rax, rdx
    jbe 1f
    xchg rax, rdx
1:  ret

# ed_touch(): cursor activity (reveal + solid caret)
FN ed_touch
    mov rdi, [rip + g_doc]
    call fold_touch             # a fold hiding the caret opens (fold.s)
    mov rdi, [rip + g_doc]
    call snippet_selection_changed
    mov dword ptr [rip + g_reveal], 1
    mov dword ptr [rip + g_dirty], 1
    call time_ms
    mov [rip + g_blink_t0], rax
    ret

# ed_set_cursor(doc, pos, extend)
FN ed_set_cursor
    mov [rdi + DOC_cur], rsi
    test edx, edx
    jnz 1f
    mov [rdi + DOC_anchor], rsi
1:  jmp ed_touch

# ed_delete_sel(doc, editkind) -> 1 if something was deleted
FN ed_delete_sel
    READONLY_RET rdi
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r13d, esi
    call snippet_user_begin
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    je 1f
    mov r12, rax
    mov rdi, rbx
    mov rsi, rax
    sub rdx, rax
    mov ecx, r13d
    call doc_delete
    mov [rbx + DOC_cur], r12
    mov [rbx + DOC_anchor], r12
    mov eax, 1
    jmp 2f
1:  xor eax, eax
2:  push rax
    mov rdi, rbx
    call snippet_user_end
    pop rax
    pop r13
    pop r12
    pop rbx
    ret

# ed_insert(doc, ptr, len, editkind): replace selection with text, cursor after it
FN ed_insert
    READONLY_RET rdi
    cmp qword ptr [rdi + DOC_selections], 0
    jne editor_multi_insert
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    call snippet_user_begin
    mov rdi, rbx
    call snippet_replace_begin
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    je 1f
    mov rdi, rbx
    call doc_begin_group
    mov rdi, rbx
    xor esi, esi
    call ed_delete_sel
    mov r15, [rbx + DOC_cur]
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r12
    mov rcx, r13
    xor r8d, r8d
    call doc_insert
    mov rdi, rbx
    call doc_end_group
    jmp 2f
1:  mov r15, [rbx + DOC_cur]
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r12
    mov rcx, r13
    mov r8d, r14d
    call doc_insert
2:  add r15, r13
    mov [rbx + DOC_cur], r15
    mov [rbx + DOC_anchor], r15
    mov qword ptr [rbx + DOC_prefx], -1
    call ed_touch
    mov rdi, rbx
    call snippet_user_end
    EPILOGUE

# line_indent(doc, line) -> rax = bytes of leading blanks, edx = visual columns
FN line_indent
    PROLOGUE
    mov rbx, rdi
    call doc_line_text
    mov r12, rax
    mov r13, rdx
    xor ecx, ecx
    xor r14d, r14d              # columns
1:  cmp rcx, r13
    jae 3f
    movzx eax, byte ptr [r12 + rcx]
    cmp al, ' '
    jne 2f
    inc r14d
    inc rcx
    jmp 1b
2:  cmp al, 9
    jne 3f
    mov eax, r14d
    xor edx, edx
    div dword ptr [rip + g_tab_width]
    mov eax, [rip + g_tab_width]
    sub eax, edx
    add r14d, eax
    inc rcx
    jmp 1b
3:  mov rax, rcx
    mov edx, r14d
    EPILOGUE

# ---- motions ----

# ed_move(kind, extend) ; kind: 0 left 1 right 2 up 3 down 4 home 5 end 6 wordl 7 wordr 8 pgup 9 pgdn 10 docstart 11 docend
FN ed_move
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    cmp qword ptr [rax + DOC_selections], 0
    jne sel_move                # several selections: each moves (editorsel.s)
1:  PROLOGUE 16
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lmv_ret
    mov r12d, edi
    mov r13d, esi
    mov r14, [rbx + DOC_cur]
    # collapsing a selection with left/right
    test r13d, r13d
    jnz 1f
    cmp r12d, 1
    ja 1f
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    je 1f
    mov r14, rax
    test r12d, r12d
    jz .Lmv_set_h
    mov r14, rdx
    jmp .Lmv_set_h
1:  mov eax, r12d
    cmp eax, 0
    je .Lmv_left
    cmp eax, 1
    je .Lmv_right
    cmp eax, 2
    je .Lmv_up
    cmp eax, 3
    je .Lmv_down
    cmp eax, 4
    je .Lmv_home
    cmp eax, 5
    je .Lmv_end
    cmp eax, 6
    je .Lmv_wordl
    cmp eax, 7
    je .Lmv_wordr
    cmp eax, 8
    je .Lmv_pgup
    cmp eax, 9
    je .Lmv_pgdn
    cmp eax, 10
    je .Lmv_start
    jmp .Lmv_endd
.Lmv_left:
    mov rdi, rbx
    mov rsi, r14
    call doc_prev_char
    mov r14, rax
    jmp .Lmv_skip_l
.Lmv_right:
    mov rdi, rbx
    mov rsi, r14
    call doc_next_char
    mov r14, rax
    jmp .Lmv_skip_r
.Lmv_wordl:
    mov rdi, rbx
    mov rsi, r14
    call doc_word_left
    mov r14, rax
.Lmv_skip_l:
    mov edx, -1
    jmp .Lmv_skip
.Lmv_wordr:
    mov rdi, rbx
    mov rsi, r14
    call doc_word_right
    mov r14, rax
.Lmv_skip_r:
    mov edx, 1
.Lmv_skip:
    mov rdi, rbx                # a position folds hide is stepped over (fold.s)
    mov rsi, r14
    call fold_skip
    mov r14, rax
    jmp .Lmv_set_h
.Lmv_home:
    # smart home: first non-blank, then column 0
    mov rdi, rbx
    mov rsi, r14
    call doc_line_of
    mov r15, rax
    mov rdi, rbx
    mov rsi, r15
    call doc_line_start
    mov [rsp], rax
    mov rdi, rbx
    mov rsi, r15
    call line_indent
    add rax, [rsp]
    cmp r14, rax
    je 2f
    mov r14, rax
    jmp .Lmv_set_h
2:  mov r14, [rsp]
    jmp .Lmv_set_h
.Lmv_end:
    mov rdi, rbx
    mov rsi, r14
    call doc_line_of
    mov rdi, rbx
    mov rsi, rax
    call doc_line_end
    mov r14, rax
    jmp .Lmv_set_h
.Lmv_start:
    xor r14d, r14d
    jmp .Lmv_set_h
.Lmv_endd:
    mov rdi, rbx
    call doc_len
    mov r14, rax
    jmp .Lmv_set_h
.Lmv_up:
    mov r15, -1
    jmp .Lmv_vert
.Lmv_down:
    mov r15, 1
    jmp .Lmv_vert
.Lmv_pgup:
    call page_lines
    neg rax
    mov r15, rax
    jmp .Lmv_vert
.Lmv_pgdn:
    call page_lines
    mov r15, rax
.Lmv_vert:
    call rows_mode              # wrapped lines or folds: one row at a time (fold.s)
    test eax, eax
    jnz .Lmv_wrap
    cmp qword ptr [rbx + DOC_prefx], -1
    jne 3f
    mov rdi, rbx
    mov rsi, r14
    call vt_doc_col             # visual cells, inlays included (vtext.s)
    mov [rbx + DOC_prefx], rax
3:  mov rdi, rbx
    mov rsi, r14
    call doc_line_of
    add rax, r15
    jns 4f
    # above the first line: go to start
    xor r14d, r14d
    jmp .Lmv_set_v
4:  cmp rax, [rbx + DOC_nlines]
    jb 5f
    mov rdi, rbx
    call doc_len
    mov r14, rax
    jmp .Lmv_set_v
5:  mov rdi, rbx
    mov rsi, rax
    mov rdx, [rbx + DOC_prefx]
    call vt_doc_pos_at_col
    mov r14, rax
    jmp .Lmv_set_v
.Lmv_wrap:
    # one visual row at a time; r15 = signed row count
    cmp qword ptr [rbx + DOC_prefx], -1
    jne 41f
    mov rdi, rbx
    call cursor_row
    mov [rbx + DOC_prefx], rcx
41: mov rax, [rbx + DOC_cur]
    mov [rsp], rax
    mov [rbx + DOC_cur], r14
42: test r15, r15
    jz 44f
    mov esi, 1
    mov rax, r15
    test rax, rax
    jns 43f
    mov rsi, -1
43: sub r15, rsi
    mov rdi, rbx
    mov rdx, [rbx + DOC_prefx]
    call wrap_move
    mov [rbx + DOC_cur], rax
    jmp 42b
44: mov r14, [rbx + DOC_cur]
    mov rax, [rsp]
    mov [rbx + DOC_cur], rax
    jmp .Lmv_set_v
.Lmv_set_h:
    mov qword ptr [rbx + DOC_prefx], -1
.Lmv_set_v:
    mov rdi, rbx
    mov rsi, r14
    mov edx, r13d
    mov [rbx + DOC_cur], rsi
    test edx, edx
    jnz 6f
    mov [rbx + DOC_anchor], rsi
6:  call ed_touch
.Lmv_ret:
    EPILOGUE

# page_lines() -> visible lines - 1 (at least 1)
page_lines:
    mov eax, [rip + g_ed_h]
    xor edx, edx
    mov ecx, [rip + g_lh]
    test ecx, ecx
    jz 1f
    div ecx
    dec eax
    cmp eax, 1
    jge 2f
1:  mov eax, 1
2:  ret

# ---- editing ----

# ed_type(cp): insert a typed character (auto-pairs, closing bracket overtype)
FN ed_type
    READONLY_RET
    mov rax, [rip + g_doc]
    test rax, rax
    jz .Lty_single
    cmp qword ptr [rax + DOC_selections], 0
    je .Lty_single
    mov esi, edi
    mov rdi, rax
    call editor_multi_type
    test eax, eax
    jnz .Lty_multi_done
    mov edi, edx
    jmp editor_multi_error
.Lty_multi_done:
    ret
.Lty_single:
    PROLOGUE 96                 # 0 the character, 8/16 the selection, 32 a pair, 48 the plan (LTP)
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lty_ret
    mov r12d, edi
    mov rdi, rbx
    mov esi, r12d
    call ws_linked_typed        # wsedit: a character outside the word ends linked editing first
    mov rdi, rbx
    call snippet_user_begin
    mov edi, r12d
    lea rsi, [rsp]
    call utf8_encode
    mov r13, rax
    # what typing it does: the language configuration's pairs and outdenting (langconf.s)
    mov rdi, rbx
    call ed_sel
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    mov rdi, rbx
    mov rsi, rax
    mov ecx, r12d
    lea r8, [rsp + 48]
    call lc_type
    cmp eax, LTK_OVER
    je .Lty_over
    cmp eax, LTK_PAIR
    je .Lty_pair
    cmp eax, LTK_OUTDENT
    je .Lty_outdent
    cmp eax, LTK_WRAP
    jne .Lty_plain
    # with a selection: wrap it
    movzx r15d, byte ptr [rsp + 48 + LTP_close]
    mov rdi, rbx
    call doc_begin_group
    mov rdi, rbx
    mov rsi, [rsp + 16]
    mov [rsp + 24], r15b
    lea rdx, [rsp + 24]
    mov ecx, 1
    xor r8d, r8d
    call doc_insert
    mov rdi, rbx
    mov rsi, [rsp + 8]
    lea rdx, [rsp]
    mov ecx, 1
    xor r8d, r8d
    call doc_insert
    mov rdi, rbx
    call doc_end_group
    mov rax, [rsp + 8]
    inc rax
    mov [rbx + DOC_anchor], rax
    mov rax, [rsp + 16]
    inc rax
    mov [rbx + DOC_cur], rax
    call ed_touch
    jmp .Lty_ret
.Lty_over:
    # a closer already there: over it
    mov rsi, [rbx + DOC_cur]
    inc rsi
    mov rdi, rbx
    xor edx, edx
    call ed_set_cursor
    jmp .Lty_ret
.Lty_pair:
    # the character and its CLOSE, the caret between
    lea rdi, [rsp + 32]
    lea rsi, [rsp]
    mov rdx, r13
    call memcpy
    lea rdi, [rsp + 32 + r13]
    lea rsi, [rsp + 48 + LTP_close]
    mov edx, [rsp + 48 + LTP_clen]
    call memcpy
    mov rdi, rbx
    lea rsi, [rsp + 32]
    mov edx, [rsp + 48 + LTP_clen]
    add rdx, r13
    mov ecx, EK_TYPE
    call ed_insert
    mov eax, [rsp + 48 + LTP_clen]
    sub [rbx + DOC_cur], rax
    sub [rbx + DOC_anchor], rax
    jmp .Lty_ret
.Lty_outdent:
    # the line one unit less, then the character, as one step
    mov rax, [rsp + 48 + LTP_from]
    mov [rbx + DOC_anchor], rax
    mov rax, [rsp + 16]
    mov [rbx + DOC_cur], rax
    mov rdi, rbx
    mov rsi, [rsp + 48 + LTP_text]
    mov rdx, [rsp + 48 + LTP_tlen]
    xor ecx, ecx
    call ed_insert
    jmp .Lty_ret
.Lty_plain:
    mov rdi, rbx
    lea rsi, [rsp]
    mov rdx, r13
    mov ecx, EK_TYPE
    call ed_insert
.Lty_ret:
    mov rdi, rbx
    call snippet_user_end
    EPILOGUE

# ed_newline(): newline keeping indentation, extra level after an opening bracket or ':'
FN ed_newline
    READONLY_RET
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    cmp qword ptr [rax + DOC_selections], 0
    je 1f
    mov rdi, rax
    call editor_multi_newline
    test eax, eax
    jnz 2f
    mov edi, edx
    jmp editor_multi_error
2:  ret
1:
    PROLOGUE 32
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lnl_ret
    mov rdi, rbx
    mov esi, 10
    call ws_linked_typed        # wsedit: a newline ends linked editing first (not mirrored)
    mov rdi, rbx
    call snippet_user_begin
    # the text from the language configuration's rules (langconf.s): indentation, a continued
    # list or comment, a closer on a line of its own, an outdented closing word
    mov rdi, rbx
    call ed_sel
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rbx
    mov rsi, rax
    call lc_newline
    mov [rsp + 16], rcx
    mov r12, rax
    mov r13, rdx
    mov rax, [rsp]
    sub rax, r8
    mov [rsp + 24], rax
    mov [rbx + DOC_anchor], rax
    mov rax, [rsp + 8]
    mov [rbx + DOC_cur], rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    call ed_insert
    mov rax, [rsp + 24]
    add rax, [rsp + 16]
    mov [rbx + DOC_cur], rax
    mov [rbx + DOC_anchor], rax
.Lnl_ret:
    mov rdi, rbx
    call snippet_user_end
    EPILOGUE

# push_indent_unit(): append one indentation unit to the sb at [rsp+8] of the caller frame
push_indent_unit:
    lea rdi, [rsp + 8]
    cmp dword ptr [rip + g_insert_spaces], 0
    je 2f
    push rbx
    push rdi
    mov ebx, [rip + g_tab_width]
1:  mov rdi, [rsp]
    mov esi, ' '
    call sb_push_byte
    dec ebx
    jnz 1b
    pop rdi
    pop rbx
    ret
2:  mov esi, 9
    jmp sb_push_byte

# ed_backspace(word)
FN ed_backspace
    READONLY_RET
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    cmp qword ptr [rax + DOC_selections], 0
    je 1f
    mov edx, edi
    xor esi, esi
    mov rdi, rax
    jmp editor_multi_delete_ui
1:
    PROLOGUE 16
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov r12d, edi
    mov rdi, rbx
    call snippet_user_begin
    mov rdi, rbx
    mov esi, EK_BACK
    call ed_delete_sel
    test eax, eax
    jnz 8f
    mov r13, [rbx + DOC_cur]
    test r13, r13
    jz 9f
    mov rdi, rbx
    mov rsi, r13
    test r12d, r12d
    jz 1f
    call doc_word_left
    jmp 5f
1:  # inside leading blanks with spaces indentation: remove to previous tab stop
    call doc_prev_char
    mov r14, rax
    cmp dword ptr [rip + g_insert_spaces], 0
    je 4f
    mov rdi, rbx
    mov rsi, r14
    call doc_byte
    cmp al, ' '
    jne 4f
    mov rdi, rbx
    mov rsi, r13
    call doc_line_of
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov r15, rax
    mov rdi, rbx
    mov rsi, r13
    call doc_col_of
    test eax, eax
    jz 4f
    # only when everything before the cursor is blank
    mov rcx, r15
2:  cmp rcx, r13
    jae 3f
    push rcx
    mov rdi, rbx
    mov rsi, rcx
    call doc_byte
    pop rcx
    cmp al, ' '
    jne 4f
    inc rcx
    jmp 2b
3:  mov rdi, rbx
    mov rsi, r13
    call doc_col_of
    dec eax
    xor edx, edx
    div dword ptr [rip + g_tab_width]
    imul eax, [rip + g_tab_width]
    mov rcx, r13
    sub rcx, r15                # current col (all spaces)
    sub rcx, rax
    mov rax, r13
    sub rax, rcx
    jmp 5f
4:  mov rax, r14
    # delete an empty auto-closing pair "(|)" (the language configuration's pairs, langconf.s)
    cmp dword ptr [rip + cfg_auto_pairs], 0
    je 5f
    push rax
    push rax
    mov rdi, rbx
    mov rsi, r13
    call lc_pair_around
    test rax, rax
    jz 7f
    pop rcx
    pop rcx
    mov rsi, r13
    sub rsi, rax
    add rdx, rax
    mov r13, rsi
    mov rdi, rbx
    mov ecx, EK_BACK
    call doc_delete
    jmp 71f
7:  pop rax
    pop rax
5:  mov rdx, r13
    sub rdx, rax
    mov r13, rax
    mov rdi, rbx
    mov rsi, rax
    mov ecx, EK_BACK
    call doc_delete
71: mov [rbx + DOC_cur], r13
    mov [rbx + DOC_anchor], r13
8:  mov qword ptr [rbx + DOC_prefx], -1
    call ed_touch
9:  mov rdi, rbx
    call snippet_user_end
    EPILOGUE

# ed_delete_fwd(word)
FN ed_delete_fwd
    READONLY_RET
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    cmp qword ptr [rax + DOC_selections], 0
    je 1f
    mov edx, edi
    mov esi, 1
    mov rdi, rax
    jmp editor_multi_delete_ui
1:
    PROLOGUE
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov r12d, edi
    mov rdi, rbx
    call snippet_user_begin
    mov rdi, rbx
    mov esi, EK_DEL
    call ed_delete_sel
    test eax, eax
    jnz 8f
    mov r13, [rbx + DOC_cur]
    mov rdi, rbx
    mov rsi, r13
    test r12d, r12d
    jz 1f
    call doc_word_right
    jmp 2f
1:  call doc_next_char
2:  mov rdx, rax
    sub rdx, r13
    jz 8f
    mov rdi, rbx
    mov rsi, r13
    mov ecx, EK_DEL
    call doc_delete
    mov [rbx + DOC_cur], r13
    mov [rbx + DOC_anchor], r13
8:  mov qword ptr [rbx + DOC_prefx], -1
    call ed_touch
9:  mov rdi, rbx
    call snippet_user_end
    EPILOGUE

# sel_lines(doc) -> rax first line, rdx last line (selection end at column 0 excluded)
sel_lines:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    call ed_sel
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov r12, rax
    mov rdi, rbx
    mov rsi, r13
    call doc_line_of
    cmp rax, r12
    je 1f
    push rax
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov rcx, rax
    pop rax
    cmp rcx, r13
    jne 1f
    dec rax
1:  mov rdi, rbx                # a folded last line brings its hidden lines (fold.s)
    mov rsi, rax
    call fold_last_line
    mov rdx, rax
    mov rax, r12
    pop r13
    pop r12
    pop rbx
    ret

# ed_indent(dir): +1 indent selected lines, -1 outdent
FN ed_indent
    mov rax, [rip + g_doc]
    test rax, rax
    jz 99f
    cmp qword ptr [rax + DOC_selections], 0
    je 99f
    mov esi, 1
    test edi, edi
    jns 98f
    mov rsi, -1
98: mov rdi, rax
    jmp editor_multi_tab_ui
99: READONLY_RET
    PROLOGUE 48
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lin_ret
    mov [rsp + 32], edi
    mov rdi, rbx
    call snippet_user_begin
    mov rdi, rbx
    call sel_lines
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    call doc_begin_group
    # unit
    lea rdi, [rsp]
    xor esi, esi
    mov edx, SB_SIZE
    call memset
    call push_indent_unit_rsp
.Lin_line:
    cmp r12, r13
    ja .Lin_done
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov r14, rax
    cmp dword ptr [rsp + 32], 0
    jl .Lin_out
    # skip empty lines
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    cmp rax, r14
    je .Lin_next
    mov rax, [rbx + DOC_cur]
    mov r15, [rbx + DOC_anchor]
    mov rdi, rbx
    mov rsi, r14
    mov rdx, [rsp + SB_ptr]
    mov rcx, [rsp + SB_len]
    xor r8d, r8d
    call doc_insert
    jmp .Lin_next
.Lin_out:
    mov rdi, rbx
    mov rsi, r12
    call line_indent
    test rax, rax
    jz .Lin_next
    mov r15, rax
    mov rdi, rbx
    mov rsi, r14
    call doc_byte
    mov edx, 1
    cmp al, 9
    je 1f
    mov edx, [rip + g_tab_width]
    cmp rdx, r15
    cmova rdx, r15
1:  mov rdi, rbx
    mov rsi, r14
    xor ecx, ecx
    call doc_delete
.Lin_next:
    inc r12
    jmp .Lin_line
.Lin_done:
    mov rdi, rbx
    call doc_end_group
    lea rdi, [rsp]
    call sb_free
    call ed_touch
.Lin_ret:
    mov rdi, rbx
    call snippet_user_end
    EPILOGUE

push_indent_unit_rsp:
    # sb lives at [rsp+8] relative to our caller's frame after the call
    jmp push_indent_unit

# ed_tab(): indent selection spanning lines, else insert indentation at the cursor
FN ed_tab
    mov rax, [rip + g_doc]
    test rax, rax
    jz 99f
    cmp qword ptr [rax + DOC_selections], 0
    je 99f
    mov rdi, rax
    xor esi, esi
    jmp editor_multi_tab_ui
99: READONLY_RET
    PROLOGUE 32
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    mov esi, 9
    call ws_linked_typed        # wsedit: a tab ends linked editing first (not mirrored)
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    je 1f
    mov rdi, rbx
    call sel_lines
    cmp rax, rdx
    je 1f
    mov edi, 1
    call ed_indent
    jmp 9f
1:  cmp dword ptr [rip + g_insert_spaces], 0
    jne 2f
    mov byte ptr [rsp], 9
    mov edx, 1
    jmp 3f
2:  mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_col_of
    xor edx, edx
    div dword ptr [rip + g_tab_width]
    mov eax, [rip + g_tab_width]
    sub eax, edx
    mov edx, eax
    lea rdi, [rsp]
    mov ecx, edx
    mov al, ' '
    rep stosb
3:  mov rdi, rbx
    lea rsi, [rsp]
    xor ecx, ecx
    call ed_insert
9:  EPILOGUE

# ---- clipboard / line commands ----

# selection text or whole current line (with newline) -> clip_sb ; eax = 1 if it was a whole line
copy_to_clip:
    PROLOGUE 32
    mov rbx, rdi
    lea rdi, [rsp]
    xor esi, esi
    mov edx, SB_SIZE
    call memset
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    je 1f
    mov r12, rax
    mov r13, rdx
    xor r15d, r15d
    jmp 2f
1:  mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    mov r14, rax
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov r12, rax
    mov rdi, rbx                # a folded line with its hidden lines (fold.s)
    mov rsi, r14
    call fold_last_line
    mov r14, rax
    lea rsi, [r14 + 1]
    cmp rsi, [rbx + DOC_nlines]
    jae 3f
    mov rdi, rbx
    call doc_line_start
    mov r13, rax
    jmp 4f
3:  mov rdi, rbx
    call doc_len
    mov r13, rax
4:  mov r15d, 1
2:  mov rax, r13
    sub rax, r12
    cmp rax, DOC_MULTI_BYTES_MAX
    ja .Lcopy_fail
    test r15d, r15d
    jz .Lcopy_size_ready
    test rax, rax
    jz .Lcopy_size_ready
    mov rdi, rbx
    lea rsi, [r13 - 1]
    call doc_byte
    cmp eax, 10
    je .Lcopy_size_ready
    mov rax, r13
    sub rax, r12
    cmp rax, DOC_MULTI_BYTES_MAX
    jae .Lcopy_fail
.Lcopy_size_ready:
    mov rsi, r13
    sub rsi, r12
    lea rdi, [rsp]
    call sb_reserve
    mov rcx, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    sub rdx, r12
    call doc_copy
    mov rax, r13
    sub rax, r12
    add [rsp + SB_len], rax
    # whole last line without newline: add one so paste works line-wise
    test r15d, r15d
    jz 5f
    mov rax, [rsp + SB_len]
    test rax, rax
    jz 5f
    mov rcx, [rsp + SB_ptr]
    cmp byte ptr [rcx + rax - 1], 10
    je 5f
    lea rdi, [rsp]
    mov esi, 10
    call sb_push_byte
5:  mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    mov edx, r15d
    call ed_clip_set
    test eax, eax
    jnz .Lcopy_done
.Lcopy_fail:
    mov r15d, -1
.Lcopy_done:
    lea rdi, [rsp]
    call sb_free
    mov eax, r15d
    EPILOGUE

FN cmd_copy
    sub rsp, 8
    xor edi, edi                # a picture with the keyboard copies itself (views group, viewpic.s)
    call views_clip_command
    add rsp, 8
    test eax, eax
    jnz 1f
    mov rdi, [rip + g_doc]
    test rdi, rdi
    jz 1f
    cmp qword ptr [rdi + DOC_selections], 0
    je 2f
    xor esi, esi
    jmp editor_multi_copy_ui
2:  call copy_to_clip
    cmp eax, -1
    jne 1f
    jmp editor_clip_failure
1:  ret

FN cmd_cut
    sub rsp, 8
    mov edi, 1                  # a picture with the keyboard cuts itself (views group, viewpic.s)
    call views_clip_command
    add rsp, 8
    test eax, eax
    jz 0f
    ret
0:  READONLY_RET
    push rbx
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    cmp qword ptr [rbx + DOC_selections], 0
    jne .Lcut_multi
    mov rdi, rbx
    call copy_to_clip
    cmp eax, -1
    je .Lcut_failed
    test eax, eax
    jz 1f
    # whole line
    call cmd_delete_line
    jmp 9f
1:  mov rdi, rbx
    xor esi, esi
    call ed_delete_sel
    call ed_touch
    jmp 9f
.Lcut_multi:
    mov rdi, rbx
    mov esi, 1
    call editor_multi_copy_ui
    jmp 9f
.Lcut_failed:
    call editor_clip_failure
9:  pop rbx
    ret

FN cmd_paste
    jmp app_clip_request

# ed_paste(ptr, len): line-wise when the clipboard came from a whole-line copy of ours
FN ed_paste
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call ed_clip_observe
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lpaste_return
    test dword ptr [rbx + DOC_flags], DF_READONLY
    jnz .Lpaste_return
    test r13, r13
    jz .Lpaste_return
    cmp qword ptr [rbx + DOC_selections], 0
    jne .Lpaste_multiple
    mov rdi, rbx
    call snippet_user_begin
    mov rdi, r12
    mov rsi, r13
    call ed_clip_linewise
    test eax, eax
    jz 1f
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    jne 1f
    # insert above the current line, keep cursor column
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov r14, rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    mov rcx, r13
    xor r8d, r8d
    call doc_insert
    # the insert moved a cursor past the line start; one at the line start stays before the text
    cmp [rbx + DOC_cur], r14
    jne 2f
    add [rbx + DOC_cur], r13
    add [rbx + DOC_anchor], r13
2:  call ed_touch
    jmp 9f
1:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    call ed_insert
9:  mov rdi, rbx
    call snippet_user_end
.Lpaste_return:
    EPILOGUE
.Lpaste_multiple:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, [rip + cfg_multi_cursor_paste]
    call editor_multi_paste_ui
    EPILOGUE

FN cmd_select_all
    sub rsp, 8
    mov edi, 2                  # a picture with the keyboard selects all of itself (viewpic.s)
    call views_clip_command
    add rsp, 8
    test eax, eax
    jz 0f
    ret
0:  call ed_single              # one selection (multi-cursor)
    mov rdi, [rip + g_doc]
    test rdi, rdi
    jz 1f
    mov qword ptr [rdi + DOC_anchor], 0
    push rdi
    call doc_len
    pop rdi
    mov [rdi + DOC_cur], rax
    jmp ed_touch
1:  ret

# select the current line(s), extending on repeat
FN cmd_select_line
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    cmp qword ptr [rax + DOC_selections], 0
    jne lines_select              # several selections (editorlines.s)
1:  push rbx
    push r12
    push r13
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call sel_lines
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    je 1f
    # already selecting whole lines -> extend by one
    inc r13
1:  mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov [rbx + DOC_anchor], rax
    lea rsi, [r13 + 1]
    cmp rsi, [rbx + DOC_nlines]
    jae 2f
    mov rdi, rbx
    call doc_line_start
    jmp 3f
2:  mov rdi, rbx
    call doc_len
3:  mov [rbx + DOC_cur], rax
    call ed_touch
9:  pop r13
    pop r12
    pop rbx
    ret

# word_at(doc, pos) -> rax start, rdx end (empty when not on a word)
FN word_at
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rsi
1:  test r12, r12
    jz 2f
    mov rdi, rbx
    lea rsi, [r12 - 1]
    call doc_byte
    mov edi, eax
    call is_ident
    test eax, eax
    jz 2f
    dec r12
    jmp 1b
2:  mov rdi, rbx
    call doc_len
    mov r14, rax
3:  cmp r13, r14
    jae 4f
    mov rdi, rbx
    mov rsi, r13
    call doc_byte
    mov edi, eax
    call is_ident
    test eax, eax
    jz 4f
    inc r13
    jmp 3b
4:  mov rax, r12
    mov rdx, r13
    EPILOGUE

# Move Selection to Next Match: select word, or the selection moves to the next occurrence (ctrl+d
# before 0.18; editorsel.s's cmd_select_next adds the next match instead)
FN cmd_select_next_skip
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    cmp qword ptr [rax + DOC_selections], 0
    jne sel_next_skip           # several selections: the primary moves, the others stay
1:  PROLOGUE 16
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    jne 1f
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call word_at
    cmp rax, rdx
    je 9f
    mov [rbx + DOC_anchor], rax
    mov [rbx + DOC_cur], rdx
    call ed_touch
    jmp 9f
1:  mov r12, rax
    mov r13, rdx
    mov rsi, r13
    sub rsi, r12
    mov rdi, rbx
    mov rdx, r13                # search from end of selection
    mov rcx, r12
    call find_in_doc
    test rax, rax
    js 9f
    mov [rbx + DOC_anchor], rax
    add rax, r13
    sub rax, r12
    mov [rbx + DOC_cur], rax
    call ed_touch
9:  EPILOGUE

# find_in_doc(doc, needle_len, from, needle_pos_in_doc) -> match pos or -1 (wraps)
find_in_doc:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    lea rdi, [r12 + 1]
    call mem_alloc
    mov r15, rax
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r12
    mov rcx, r15
    call doc_copy
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r12
    mov rcx, r13
    mov r8d, 1
    call doc_search
    mov r12, rax
    mov rdi, r15
    call mem_free
    mov rax, r12
    EPILOGUE

# doc_search(doc, needle, nlen, from, case_sensitive) -> pos or -1 ; searches forward, wraps
FN doc_search
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8d
    test r13, r13
    jz .Lds_none
    mov rdi, rbx
    call doc_len
    mov r15, rax
    mov rdi, rbx
    call doc_contiguous
    mov [rsp + 8], rax
    # search [from, len)
    mov rdi, rax
    add rdi, r14
    mov rsi, r15
    sub rsi, r14
    jb .Lds_wrap
    mov rdx, r12
    mov rcx, r13
    cmp dword ptr [rsp], 0
    je 1f
    call str_find
    jmp 2f
1:  call str_ifind
2:  test rax, rax
    js .Lds_wrap
    add rax, r14
    EPILOGUE
.Lds_wrap:
    mov rdi, [rsp + 8]
    mov rsi, r14
    add rsi, r13
    cmp rsi, r15
    cmova rsi, r15
    mov rdx, r12
    mov rcx, r13
    cmp dword ptr [rsp], 0
    je 3f
    call str_find
    EPILOGUE
3:  call str_ifind
    EPILOGUE
.Lds_none:
    mov rax, -1
    EPILOGUE

FN cmd_duplicate_line
    READONLY_RET
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    cmp qword ptr [rax + DOC_selections], 0
    jne lines_duplicate              # several selections (editorlines.s)
1:  PROLOGUE 16
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call snippet_user_begin
    mov rdi, rbx
    call sel_lines
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov r14, rax
    mov rdi, rbx
    mov rsi, r13
    call doc_line_end
    mov r15, rax
    # text = "\n" + lines, inserted at end of last line
    mov rdx, r15
    sub rdx, r14
    lea rdi, [rdx + 2]
    call mem_alloc
    mov [rsp], rax
    mov byte ptr [rax], 10
    lea rcx, [rax + 1]
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    sub rdx, r14
    call doc_copy
    mov rdi, rbx
    mov rsi, r15
    mov rdx, [rsp]
    mov rcx, r15
    sub rcx, r14
    inc rcx
    mov [rsp + 8], rcx
    xor r8d, r8d
    call doc_insert
    # onto the copy; the insert already moved what was past the end of the last line
    mov rax, [rsp + 8]
    cmp [rbx + DOC_cur], r15
    ja 1f
    add [rbx + DOC_cur], rax
1:  cmp [rbx + DOC_anchor], r15
    ja 2f
    add [rbx + DOC_anchor], rax
2:  mov rdi, [rsp]
    call mem_free
    call ed_touch
9:
    mov rdi, rbx
    call snippet_user_end
    EPILOGUE

FN cmd_delete_line
    READONLY_RET
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    cmp qword ptr [rax + DOC_selections], 0
    jne lines_delete              # several selections (editorlines.s)
1:  PROLOGUE
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call snippet_user_begin
    mov rdi, rbx
    call sel_lines
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov r14, rax
    lea rsi, [r13 + 1]
    cmp rsi, [rbx + DOC_nlines]
    jae 1f
    mov rdi, rbx
    call doc_line_start
    mov r15, rax
    jmp 2f
1:  # last line: also remove the preceding newline
    mov rdi, rbx
    call doc_len
    mov r15, rax
    test r14, r14
    jz 2f
    dec r14
2:  mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    sub rdx, r14
    xor ecx, ecx
    call doc_delete
    mov rdi, rbx
    mov rsi, r14
    call doc_line_of
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rbx + DOC_prefx]
    cmp rdx, -1
    jne 3f
    xor edx, edx
3:  call doc_pos_at_col
    mov [rbx + DOC_cur], rax
    mov [rbx + DOC_anchor], rax
    call ed_touch
9:
    mov rdi, rbx
    call snippet_user_end
    EPILOGUE

# ed_move_lines(dir): move selected lines up (-1) or down (1)
FN ed_move_lines
    READONLY_RET
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    cmp qword ptr [rax + DOC_selections], 0
    je 1f
    test edi, edi               # several selections (editorlines.s)
    js lines_move_up
    jmp lines_move_down
1:  PROLOGUE 48
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lml_ret
    mov [rsp + 40], edi
    mov rdi, rbx
    call snippet_user_begin
    mov rdi, rbx
    call sel_lines
    mov r12, rax                # first
    mov r13, rdx                # last
    cmp dword ptr [rsp + 40], 0
    jg 1f
    test r12, r12
    jz .Lml_ret
    lea r14, [r12 - 1]          # other line (above)
    jmp 2f
1:  lea r14, [r13 + 1]
    cmp r14, [rbx + DOC_nlines]
    jae .Lml_ret
2:  # block text [start(first), end(last)) and other line text
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov [rsp], rax              # block start
    mov rdi, rbx
    mov rsi, r13
    call doc_line_end
    mov [rsp + 8], rax          # block end
    mov rdi, rbx
    mov rsi, r14
    call doc_line_start
    mov [rsp + 16], rax
    mov rdi, rbx
    mov rsi, r14
    call doc_line_end
    mov [rsp + 24], rax         # other end
    mov rdi, rbx
    call doc_begin_group
    mov r15, [rbx + DOC_cur]
    mov rax, [rbx + DOC_anchor]
    mov [rsp + 32], rax
    # remove the other line (with its separating newline) and re-insert it on the other side
    mov rdx, [rsp + 24]
    sub rdx, [rsp + 16]         # other length
    push rdx
    push rdx
    lea rdi, [rdx + 2]
    call mem_alloc
    mov r14, rax
    pop rdx
    pop rdx
    mov [rsp + 24], rdx         # reuse: other length
    mov rdi, rbx
    mov rsi, [rsp + 16]
    mov rcx, r14
    call doc_copy
    cmp dword ptr [rsp + 40], 0
    jg 3f
    # up: delete "other\n" before the block, insert "\nother" after the block
    mov rdi, rbx
    mov rsi, [rsp + 16]
    mov rdx, [rsp + 24]
    inc rdx
    xor ecx, ecx
    call doc_delete
    lea rdi, [r14 + 1]
    mov rsi, r14
    mov rdx, [rsp + 24]
    call memmove
    mov byte ptr [r14], 10
    mov rsi, [rsp + 8]
    sub rsi, [rsp + 24]
    dec rsi
    mov rdi, rbx
    mov rdx, r14
    mov rcx, [rsp + 24]
    inc rcx
    xor r8d, r8d
    call doc_insert
    mov rax, [rsp + 24]
    inc rax
    sub r15, rax
    sub [rsp + 32], rax
    jmp 4f
3:  # down: delete "\nother" after the block, insert "other\n" before the block
    mov rdi, rbx
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 24]
    inc rdx
    xor ecx, ecx
    call doc_delete
    mov rax, [rsp + 24]
    mov byte ptr [r14 + rax], 10
    mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, r14
    mov rcx, [rsp + 24]
    inc rcx
    xor r8d, r8d
    call doc_insert
    mov rax, [rsp + 24]
    inc rax
    add r15, rax
    add [rsp + 32], rax
4:  # A selection ending at the next line's start includes a newline. At EOF,
    # the moved block has no following newline, so that endpoint must stop there.
    mov rdi, rbx
    call doc_len
    cmp r15, rax
    cmova r15, rax
    mov [rbx + DOC_cur], r15
    mov rcx, [rsp + 32]
    cmp rcx, rax
    cmova rcx, rax
    mov [rbx + DOC_anchor], rcx
    mov rdi, rbx
    call doc_end_group
    mov rdi, r14
    call mem_free
    call ed_touch
.Lml_ret:
    mov rdi, rbx
    call snippet_user_end
    EPILOGUE

# toggle line comments using the grammar's comment token
FN cmd_toggle_comment
    READONLY_RET
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    cmp qword ptr [rax + DOC_selections], 0
    jne lines_comment              # several selections (editorlines.s)
1:  PROLOGUE 32
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Ltc_ret
    mov rdi, rbx
    call snippet_user_begin
    mov rdi, rbx
    call lc_line_comment        # the language configuration's (langconf.s)
    test rdx, rdx
    jz .Ltc_block
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rbx
    call sel_lines
    mov r12, rax
    mov r13, rdx
    # all non-blank lines commented? -> uncomment
    mov r14, r12
    mov dword ptr [rsp + 16], 1
    mov qword ptr [rsp + 24], 1000000     # min indent columns
1:  cmp r14, r13
    ja 3f
    mov rdi, rbx
    mov rsi, r14
    call line_indent
    mov r15, rax
    mov rdi, rbx
    mov rsi, r14
    call doc_line_text
    cmp r15, rdx
    je 2f                       # blank line
    cmp r15, [rsp + 24]
    jae 11f
    mov [rsp + 24], r15
11: lea rdi, [rax + r15]
    mov rsi, rdx
    sub rsi, r15
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    call str_starts
    test eax, eax
    jnz 2f
    mov dword ptr [rsp + 16], 0
2:  inc r14
    jmp 1b
3:  mov rdi, rbx
    call doc_begin_group
    mov r14, r12
.Ltc_line:
    cmp r14, r13
    ja .Ltc_done
    mov rdi, rbx
    mov rsi, r14
    call line_indent
    mov r15, rax
    mov rdi, rbx
    mov rsi, r14
    call doc_line_text
    cmp r15, rdx
    je .Ltc_next
    mov rdi, rbx
    mov rsi, r14
    call doc_line_start
    cmp dword ptr [rsp + 16], 0
    je .Ltc_add
    # remove token and one following space
    add rax, r15
    mov r15, rax
    mov rdx, [rsp + 8]
    lea rsi, [r15 + rdx]
    mov rdi, rbx
    push rdx
    push rdx
    call doc_byte
    pop rdx
    pop rdx
    cmp al, ' '
    jne 4f
    inc rdx
4:  mov rdi, rbx
    mov rsi, r15
    xor ecx, ecx
    call doc_delete
    jmp .Ltc_next
.Ltc_add:
    add rax, [rsp + 24]
    mov r15, rax
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Lspace]
    mov ecx, 1
    xor r8d, r8d
    call doc_insert
    mov rdi, rbx
    mov rsi, r15
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    xor r8d, r8d
    call doc_insert
.Ltc_next:
    inc r14
    jmp .Ltc_line
.Ltc_done:
    mov rdi, rbx
    call doc_end_group
    call ed_touch
.Ltc_ret:
    mov rdi, rbx
    call snippet_user_end
    EPILOGUE
.Ltc_block:
    mov rdi, rbx
    call block_comment
    jmp .Ltc_ret

# block_comment(doc): without a line comment, Toggle Comment puts the block comment's START before
#   the selected lines (at the first one's indentation) and END after them, or takes them off
block_comment:
    PROLOGUE 64
    mov rbx, rdi
    call lc_block_comment
    test rdx, rdx
    jz 9f
    mov [rsp], rax              # START
    mov [rsp + 8], rdx
    mov [rsp + 16], rcx         # END
    mov [rsp + 24], r8
    mov rdi, rbx
    call sel_lines
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    mov rsi, r12
    call line_indent
    mov r14, rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    add r14, rax                # a: the first line's text
    mov rdi, rbx
    mov rsi, r13
    call doc_line_end
    mov r15, rax                # b: the last line's end, before its trailing blanks
1:  cmp r15, r14
    jbe 9f
    mov rdi, rbx
    lea rsi, [r15 - 1]
    call doc_byte
    cmp eax, ' '
    je 2f
    cmp eax, 9
    jne 3f
2:  dec r15
    jmp 1b
3:  mov rdi, rbx
    call doc_begin_group
    # commented already: START at a and END at b
    mov rax, [rsp + 8]
    add rax, [rsp + 24]
    mov rcx, r15
    sub rcx, r14
    cmp rcx, rax
    jb .Lbc_add
    mov rdi, rbx
    mov rsi, r14
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    call doc_has
    test eax, eax
    jz .Lbc_add
    mov rdi, rbx
    mov rsi, r15
    sub rsi, [rsp + 24]
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    call doc_has
    test eax, eax
    jz .Lbc_add
    # off: END (and a blank before it), then START (and a blank after it)
    mov rsi, r15
    sub rsi, [rsp + 24]
    mov rdx, [rsp + 24]
    mov rax, rsi
    sub rax, r14
    cmp rax, [rsp + 8]
    jbe 4f
    mov [rsp + 32], rsi
    mov [rsp + 40], rdx
    mov rdi, rbx
    lea rsi, [rsi - 1]
    call doc_byte
    mov rsi, [rsp + 32]
    mov rdx, [rsp + 40]
    cmp eax, ' '
    jne 4f
    dec rsi
    inc rdx
4:  mov rdi, rbx
    xor ecx, ecx
    call doc_delete
    mov rdx, [rsp + 8]
    mov [rsp + 40], rdx
    mov rdi, rbx
    mov rsi, r14
    add rsi, rdx
    call doc_byte
    mov rdx, [rsp + 40]
    cmp eax, ' '
    jne 5f
    inc rdx
5:  mov rdi, rbx
    mov rsi, r14
    xor ecx, ecx
    call doc_delete
    jmp 8f
.Lbc_add:
    # on: " END" after the text, "START " before it
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Lbc_space]
    mov ecx, 1
    xor r8d, r8d
    call doc_insert
    mov rdi, rbx
    lea rsi, [r15 + 1]
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    xor r8d, r8d
    call doc_insert
    mov rdi, rbx
    mov rsi, r14
    lea rdx, [rip + .Lbc_space]
    mov ecx, 1
    xor r8d, r8d
    call doc_insert
    mov rdi, rbx
    mov rsi, r14
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    xor r8d, r8d
    call doc_insert
8:  mov rdi, rbx
    call doc_end_group
    mov rdi, rbx
    mov rsi, r14
    xor edx, edx
    call ed_set_cursor
    call ed_touch
9:  EPILOGUE

# doc_has(doc, pos, ptr, len) -> eax 1 when the document has those bytes at pos
doc_has:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    xor r15d, r15d
1:  cmp r15, r14
    jae 2f
    mov rdi, rbx
    lea rsi, [r12 + r15]
    call doc_byte
    cmp al, [r13 + r15]
    jne 8f
    inc r15
    jmp 1b
2:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

FN cmd_undo
    cmp dword ptr [rip + g_focus], FOCUS_EXPLORER
    je cmd_undo_workspace_edit  # wsedit: the explorer's Rename and Delete undo from there
    READONLY_RET
    mov rdi, [rip + g_doc]
    test rdi, rdi
    jz 1f
    call doc_undo
    jmp ed_touch
1:  jmp ce_undo                 # custom editors: a view's tab (customed.s)

FN cmd_redo
    READONLY_RET
    mov rdi, [rip + g_doc]
    test rdi, rdi
    jz 1f
    call doc_redo
    jmp ed_touch
1:  jmp ce_redo                 # custom editors: a view's tab (customed.s)

# ---- drawing ----

# editor_gutter(doc) -> eax gutter width
editor_gutter:
    cmp qword ptr [rdi + DOC_diff], 0
    jne diffview_gutter
    cmp dword ptr [rip + g_ed_cell], 0      # a notebook's cell has no line numbers
    jne 2f
    cmp dword ptr [rip + cfg_line_numbers], 0
    je 2f
    mov rax, [rdi + DOC_nlines]
    mov ecx, 1
    mov r8d, 10
1:  cmp rax, r8
    jb 3f
    xor edx, edx
    div r8
    inc ecx
    jmp 1b
3:  cmp ecx, 3
    jge 4f
    mov ecx, 3
4:  imul ecx, [rip + g_cw]
    lea eax, [rcx + 0]
    add eax, [rip + g_mt + 4*MI_24]
    add eax, [rip + g_mt + 4*MI_8]
    mov ecx, eax
    call gutter_extra           # the lanes' share (gutter.s)
    add eax, ecx
    ret
2:  call gutter_extra
    add eax, [rip + g_mt + 4*MI_16]
    ret

# ed_top_inside(doc): the view starts at the last line when the text ends above its top line. Text
#   replaced under a view that is kept (a reload, a diff fetched again, a reopened tab) can do that,
#   and a wrapped view reads the rows of its top line first (its clamp, a click in it).
FN ed_top_inside
    mov rax, [rdi + DOC_nlines]
    dec rax
    mov rcx, [rdi + DOC_scrolly]
    sar rcx, 8
    cmp rcx, rax
    jle 1f
    mov [rdi + DOC_wtop], rax
    mov qword ptr [rdi + DOC_woff], 0
    shl rax, 8
    mov [rdi + DOC_scrolly], rax
1:  ret

# clamp_scroll(doc)
clamp_scroll:
    cmp dword ptr [rip + g_ed_cell], 0      # a cell's lines are the notebook's to scroll
    jne 4f
    mov rax, [rdi + DOC_nlines]
    cmp dword ptr [rip + cfg_scroll_past_end], 0
    jne 1f
    call rows_mode
    test eax, eax
    jnz wrap_clamp
    mov rax, [rdi + DOC_nlines]  # (rows_mode returned in rax)
    # last line at the bottom
    mov ecx, [rip + g_ed_h]
    xor edx, edx
    push rax
    mov eax, ecx
    mov ecx, [rip + g_lh]
    div ecx
    mov rcx, rax
    pop rax
    sub rax, rcx
    jns 2f
    xor eax, eax
    jmp 2f
1:  dec rax
2:  shl rax, 8
    cmp [rdi + DOC_scrolly], rax
    jle 3f
    mov [rdi + DOC_scrolly], rax
3:  cmp qword ptr [rdi + DOC_scrolly], 0
    jge 4f
    mov qword ptr [rdi + DOC_scrolly], 0
4:  cmp qword ptr [rdi + DOC_scrollx], 0
    jge 5f
    mov qword ptr [rdi + DOC_scrollx], 0
5:  ret

# reveal(doc): scroll so the cursor is visible
reveal:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + g_ed_cell], 0      # a cell: the notebook keeps the line in view
    jne 5f
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    mov r12, rax                # line
    mov eax, [rip + g_ed_h]
    xor edx, edx
    div dword ptr [rip + g_lh]
    mov r13, rax                # visible lines
    cmp r13, 3
    jl 1f
    sub r13, 2                  # keep a line of margin
1:  mov rax, r12
    dec rax
    jns 2f
    xor eax, eax
2:  shl rax, 8
    cmp [rbx + DOC_scrolly], rax
    jle 3f
    mov [rbx + DOC_scrolly], rax
3:  mov rax, r12
    sub rax, r13
    jns 4f
    xor eax, eax
4:  shl rax, 8
    cmp [rbx + DOC_scrolly], rax
    jge 5f
    mov [rbx + DOC_scrolly], rax
5:  mov rdi, rbx
    call reveal_h
    mov rdi, rbx
    call clamp_scroll
    EPILOGUE

# reveal_h(doc): scroll sideways so the cursor is visible
reveal_h:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call vt_doc_col             # the caret's visual column, the line's inlays counted (vtext.s)
    mov r14d, eax
    # A long line's width may be deferred while typing. The caret's column is already known:
    # keep the scrollbar's extent wide enough for it without another scan of that line.
    cmp rax, [rbx + DOC_wcols]
    jbe 51f
    mov [rbx + DOC_wcols], rax
    call hscroll_extent
51: mov eax, r14d
    imul eax, [rip + g_cw]
    mov r14d, eax
    mov rdi, rbx
    call editor_gutter
    mov ecx, [rip + g_ed_w]
    sub ecx, eax
    sub ecx, [rip + g_mt + 4*MI_32]
    mov eax, r14d
    sub rax, [rbx + DOC_scrollx]
    cmp eax, ecx
    jle 6f
    mov eax, r14d
    sub eax, ecx
    mov [rbx + DOC_scrollx], rax
6:  movsxd rax, r14d
    cmp rax, [rbx + DOC_scrollx]
    jge 7f
    # going left: back to column 0 when the cursor fits, else center it
    movsxd rdx, ecx
    xor esi, esi
    cmp rax, rdx
    jl 61f
    sar rdx, 1
    mov rsi, rax
    sub rsi, rdx
61: mov [rbx + DOC_scrollx], rsi
7:  EPILOGUE

# pos_at_point_editor(doc, px, py) -> pos: pos_at_point for other files
FN pos_at_point_editor
    jmp pos_at_point

# pos_at_point(doc, px, py) -> pos
FN pos_at_point
    call rows_mode
    test eax, eax
    jnz wrap_pos_at
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    # line
    mov eax, r13d
    sub eax, [rip + g_ed_y]
    movsxd rax, eax
    # g_lh is 32 bits: a 64-bit multiply would take g_cw along as its high half
    movsxd rcx, dword ptr [rip + g_lh]
    imul rcx, [rbx + DOC_scrolly]
    sar rcx, 8
    add rax, rcx                # 64 bits: past 2^31 px a 32-bit sum went negative, to line 1
    jns 1f
    xor eax, eax
1:  movsxd rcx, dword ptr [rip + g_lh]
    xor edx, edx
    div rcx
    mov r14, rax
    cmp r14, [rbx + DOC_nlines]
    jb 2f
    mov rdi, rbx
    call doc_len
    jmp 9f
2:  # column
    mov qword ptr [rip + g_vt_hit], 0
    mov rdi, rbx
    mov rsi, r14
    call vt_has
    test eax, eax
    jnz 4f
    mov eax, r12d
    sub eax, [rip + g_ed_tx]
    add eax, [rbx + DOC_scrollx]
    mov ecx, [rip + g_cw]
    shr ecx, 1
    add eax, ecx
    jns 3f
    xor eax, eax
3:  xor edx, edx
    div dword ptr [rip + g_cw]
    mov rdi, rbx
    mov rsi, r14
    mov edx, eax
    call doc_pos_at_col
9:  EPILOGUE
4:  # a line with inlays: the pixel against its cells (vtext.s)
    movsxd rdx, r12d
    movsxd rax, dword ptr [rip + g_ed_tx]
    sub rdx, rax
    add rdx, [rbx + DOC_scrollx]
    jns 5f
    xor edx, edx
5:  mov rdi, rbx
    mov rsi, r14
    call vt_pos_at
    EPILOGUE

# drag_scroll(rbx doc, esi px)
drag_scroll:
    call rows_mode
    test eax, eax
    jz 1f
    mov rdi, rbx
    jmp scroll_by_px
1:  movsxd rax, esi
    shl rax, 8
    cqo
    movsxd rcx, dword ptr [rip + g_lh]
    idiv rcx
    add [rbx + DOC_scrolly], rax
    mov dword ptr [rip + g_dirty], 1
    ret

# draw_wrapped(doc): visible lines as wrapped rows
draw_wrapped:
    PROLOGUE 64
    mov rbx, rdi
    mov rdi, rbx
    call vim_sel
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    mov [rsp + 8], rax          # cursor line
    mov rdi, rbx
    call git_doc_marks
    mov [rsp], rax
    mov rdi, rbx
    call top_offset
    mov r13d, [rip + g_ed_y]
    sub r13d, eax               # y of the first row of the top line
    mov r12, [rbx + DOC_scrolly]
    shr r12, 8
.Ldw_line:
    cmp r12, [rbx + DOC_nlines]
    jae .Ldw_ret
    mov eax, [rip + g_ed_y]
    add eax, [rip + g_ed_h]
    cmp r13d, eax
    jge .Ldw_ret
    mov rdi, rbx
    mov rsi, r12
    call line_breaks
    mov r14d, eax               # rows
    test eax, eax
    jz .Ldw_hidden              # a folded line has none (fold.s)
    mov rdi, rbx                # its code lens row (lens.s): drawn, then the text rows below it
    mov rsi, r12
    mov edx, r13d
    call lens_row_take          # -> eax the rows drawn above the text (ghost rows, a lens row)
    test eax, eax
    jz 16f
    sub r14d, eax
    imul eax, [rip + g_lh]
    add r13d, eax
16:
    # current line highlight across all its rows
    cmp dword ptr [rip + cfg_highlight_line], 0
    je 12f
    cmp r12, [rsp + 8]
    jne 14f
    mov rax, [rsp + 16]
    cmp rax, [rsp + 24]
    jne 12f
    jmp 15f
14: mov rdi, rbx                # and the lines of the other carets
    mov rsi, r12
    call sel_line_tint
    test eax, eax
    jz 12f
15: mov edi, [rip + g_ed_x]
    mov esi, r13d
    mov edx, [rip + g_ed_w]
    mov ecx, [rip + g_lh]
    imul ecx, r14d
    COLOR r8d, T_LINE_HL
    call gfx_fill
12: mov rdi, r12
    mov esi, r13d
    mov edx, [rip + g_lh]
    imul edx, r14d
    call draw_disk_range
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, [rip + g_lh]
    imul ecx, r14d
    call deco_line_back
    mov rdi, rbx                # debugger: the paused line's background (debuggutter.s)
    mov rsi, r12
    mov edx, r13d
    mov ecx, [rip + g_lh]
    imul ecx, r14d
    call dbg_line_back
    # line number on the first row
    cmp qword ptr [rbx + DOC_diff], 0
    jne .Ldw_diff
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, [rip + g_lh]
    imul ecx, r14d
    call gutter_line_under
    cmp dword ptr [rip + cfg_line_numbers], 0
    je 1f
    lea rdi, [rsp + 40]
    lea rsi, [r12 + 1]
    call fmt_u64
    mov r15, rax
    lea rdi, [rip + g_face_code]
    lea rsi, [rsp + 40]
    mov rdx, rax
    call text_width
    mov esi, [rip + g_gl_digits_r]
    sub esi, eax
    COLOR r9d, T_LINENO
    cmp r12, [rsp + 8]
    jne 11f
    COLOR r9d, T_LINENO_ACTIVE
11: lea rdi, [rip + g_face_code]
    mov edx, r13d
    add edx, [rip + g_base]
    lea rcx, [rsp + 40]
    mov r8, r15
    call text_draw
1:  mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, [rip + g_lh]
    imul ecx, r14d
    call gutter_line            # the left lane's glyph (gutter.s)
    mov rax, [rsp]
    test rax, rax
    jz 13f
    movzx edi, byte ptr [rax + r12]
    test edi, edi
    jz 13f
    mov esi, r13d
    mov edx, [rip + g_lh]
    imul edx, r14d
    call mark_draw
13: xor r15d, r15d              # row
.Ldw_row:
    cmp r15d, r14d
    jae .Ldw_next
    mov eax, r13d
    add eax, [rip + g_lh]
    cmp eax, [rip + g_ed_y]
    jl .Ldw_rownext
    mov eax, [rip + g_ed_y]
    add eax, [rip + g_ed_h]
    cmp r13d, eax
    jge .Ldw_ret
    lea rax, [rip + wb_starts]
    mov ecx, [rax + r15*4]
    mov [rip + dl_from], ecx
    mov ecx, [rax + r15*4 + 4]
    mov [rip + dl_to], ecx
    lea eax, [r15 + 1]
    xor ecx, ecx
    cmp eax, r14d
    sete cl
    mov [rip + dl_last], ecx
    # draw_line re-reads the line text, keep the row table
    mov edi, [rip + g_ed_tx]
    sub edi, [rip + g_mt + 4*MI_4]
    mov esi, [rip + g_ed_y]
    mov edx, [rip + g_ed_x]
    add edx, [rip + g_ed_w]
    sub edx, edi
    mov ecx, [rip + g_ed_h]
    call gfx_clip_push
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    lea rcx, [rsp + 16]
    call draw_line
    call gfx_clip_pop
.Ldw_rownext:
    add r13d, [rip + g_lh]
    inc r15d
    jmp .Ldw_row
.Ldw_next:
    inc r12
    jmp .Ldw_line
.Ldw_hidden:
    mov rdi, rbx
    mov rsi, r12
    call fold_next_visible
    cmp rax, r12
    jbe .Ldw_next
    mov r12, rax
    jmp .Ldw_line
.Ldw_diff:
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, [rip + g_lh]
    imul ecx, r14d
    call diffview_line
    test eax, eax
    jz 13b
    mov eax, [rip + g_lh]
    imul eax, r14d
    add r13d, eax
    jmp .Ldw_next
.Ldw_ret:
    cmp r12, [rbx + DOC_nlines]   # presentation: past the last line, a ghost's lines below it
    jb 17f
    mov rdi, rbx
    mov esi, r13d
    call ghost_tail_draw
17: mov dword ptr [rip + dl_from], 0
    mov dword ptr [rip + dl_to], -1
    mov dword ptr [rip + dl_last], 1
    EPILOGUE

# mark_draw(mark, y, h): git change bar left of the text
mark_draw:
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, [rip + g_ed_tx]
    sub r14d, [rip + g_mt + 4*MI_12]
    test ebx, GM_ADD | GM_MOD
    jz 1f
    COLOR r8d, T_GIT_ADD
    test ebx, GM_MOD
    jz 11f
    COLOR r8d, T_GIT_MOD
11: mov edi, r14d
    mov esi, r12d
    M edx, MI_3
    mov ecx, r13d
    call gfx_fill
1:  test ebx, GM_DELUP
    jz 2f
    mov esi, r12d
    call del_wedge
2:  test ebx, GM_DELDOWN
    jz 9f
    lea esi, [r12 + r13]
    call del_wedge
9:  EPILOGUE
# del_wedge(y in esi): a small triangle pointing into the text where lines were deleted (r14d x)
del_wedge:
    push rbx
    push r12
    push r15
    mov r12d, esi
    M r15d, MI_4
    xor ebx, ebx
1:  cmp ebx, r15d
    jge 2f
    mov edi, r14d
    add edi, ebx
    mov ecx, r15d
    sub ecx, ebx                # half height of this column
    mov esi, r12d
    sub esi, ecx
    add ecx, ecx
    mov edx, 1
    COLOR r8d, T_GIT_DEL
    call gfx_fill
    inc ebx
    jmp 1b
2:  pop r15
    pop r12
    pop rbx
    ret

# editor_draw(x, y, w, h)
FN editor_draw
    PROLOGUE 112
    mov rbx, [rip + g_doc]
    mov [rip + g_ed_x], edi
    mov [rip + g_ed_y], esi
    mov [rip + g_ed_w], edx
    mov [rip + g_ed_h], ecx
    # background
    COLOR r8d, T_BG
    call gfx_fill
    test rbx, rbx
    jz .Led_ret
    call disk_colors
    mov edi, [rip + g_ed_x]
    mov esi, [rip + g_ed_y]
    mov edx, [rip + g_ed_w]
    mov ecx, [rip + g_ed_h]
    call gfx_clip_push
    call disk_warning
    mov rdi, rbx
    call editor_gutter
    mov [rsp], eax              # gutter width
    add eax, [rip + g_ed_x]
    mov [rip + g_ed_tx], eax
    mov rdi, rbx
    call gutter_frame           # the lanes' positions (gutter.s)
    mov rdi, rbx
    call fold_view_sync         # the scroll's form for folds (fold.s)
    mov edi, [rsp]
    call hscroll_measure
    cmp dword ptr [rip + g_ed_cell], 0      # a cell: no scrollbars, and input only with the keyboard
    je 150f
    mov dword ptr [rip + hs_on], 0
    cmp dword ptr [rip + g_ed_cell], 1
    je .Led_noinput
150: # ---- input ----
    call find_blocks_editor
    test eax, eax
    jnz .Led_noinput
    mov edi, [rip + g_ed_x]
    mov esi, [rip + g_ed_y]
    mov edx, [rip + g_ed_w]
    mov ecx, [rip + g_ed_h]
    call ui_in
    test eax, eax
    jz .Led_noinput
    mov eax, [rip + g_mx]
    cmp eax, [rip + g_ed_tx]
    jl 12f
    cmp dword ptr [rip + g_cursor], CUR_DEFAULT
    jne 1f
    mov dword ptr [rip + g_cursor], CUR_TEXT
1:  # the position the pointer rests on, for extensions' hovers and diagnostics' messages
    mov rdi, rbx
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call pos_at_point
    cmp qword ptr [rip + g_vt_hit], 0
    jne 14f
    mov rdi, rbx
    mov rsi, rax
    call ext_hover_track
    call ext_hover_tip
    call gutter_unhover
    jmp 13f
14: xor edi, edi                # over an inlay: its own tip (vtext.s)
    xor esi, esi
    call ext_hover_track
    mov rdi, rbx
    call vt_hover
    call gutter_unhover
    cmp dword ptr [rip + g_cursor], CUR_TEXT
    jne 13f
    mov dword ptr [rip + g_cursor], CUR_DEFAULT
    jmp 13f
12: xor edi, edi
    xor esi, esi
    call ext_hover_track
    mov rdi, rbx
    call gutter_hover           # the left lane's hover glyph and tips (gutter.s)
13: mov dword ptr [rip + ed_hovered], 1
    cmp dword ptr [rip + g_ed_cell], 0      # over a cell the wheel scrolls the notebook
    jne 3f
    # wheel (sideways with Shift: wheel_xy)
    call wheel_xy
    mov eax, edx
    test eax, eax
    jz 2f
    push rax
    push rax
    call rows_mode
    mov ecx, eax
    pop rax
    pop rax
    test ecx, ecx
    jz 11f
    mov rdi, rbx
    mov esi, eax
    call scroll_by_px
    jmp 2f
11: movsxd rax, eax
    shl rax, 8
    cqo
    movsxd rcx, dword ptr [rip + g_lh]
    idiv rcx
    add [rbx + DOC_scrolly], rax
    mov dword ptr [rip + g_dirty], 1
2:  call wheel_xy
    test eax, eax
    jz 3f
    cmp dword ptr [rip + cfg_word_wrap], 0
    jne 3f
    movsxd rax, eax
    add [rbx + DOC_scrollx], rax
    mov dword ptr [rip + g_dirty], 1
3:  # right click: menu (moves the cursor unless clicking inside the selection)
    test dword ptr [rip + g_pressed], 1 << BTN_RIGHT
    jz 31f
    mov eax, [rip + g_mx]
    cmp eax, [rip + g_ed_tx]
    jge 34f
    mov rdi, rbx
    mov esi, BTN_RIGHT
    call gutter_press           # a glyph's own menu
    test eax, eax
    jnz .Led_noinput
34: mov dword ptr [rip + g_focus], FOCUS_EDITOR
    call vim_export
    mov rdi, rbx
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call pos_at_point
    mov r12, rax
    mov rdi, rbx
    call ed_sel
    cmp r12, rax
    jb 32f
    cmp r12, rdx
    jbe 33f
32: mov rdi, rbx
    call sel_collapse           # a click outside the selection: one caret (multi-cursor)
    mov [rbx + DOC_cur], r12
    mov [rbx + DOC_anchor], r12
    mov rdi, rbx
    call snippet_selection_changed
33: call menu_open_editor       # with the extensions' items (menu.s)
    jmp .Led_noinput
31: # mouse press in the text area
    test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz .Led_noinput
    mov eax, [rip + g_ed_x]
    add eax, [rip + g_ed_w]
    sub eax, [rip + g_mt + 4*MI_12]
    cmp [rip + g_mx], eax
    jge .Led_noinput
    # nor the horizontal one's along the bottom of the text
    cmp dword ptr [rip + hs_on], 0
    je 311f
    mov eax, [rip + g_ed_y]
    add eax, [rip + g_ed_h]
    sub eax, [rip + g_mt + 4*MI_12]
    cmp [rip + g_my], eax
    jl 311f
    mov eax, [rip + g_mx]
    cmp eax, [rip + g_ed_tx]
    jge .Led_noinput
311:
    mov eax, [rip + g_mx]
    cmp eax, [rip + g_ed_tx]
    jge 312f
    mov rdi, rbx
    mov esi, BTN_LEFT
    call gutter_press           # a glyph or the left lane's owner takes it
    test eax, eax
    jnz .Led_noinput
312:
    mov edi, ID_EDITOR
    mov [rip + g_active], edi
    mov dword ptr [rip + g_dragging], 1
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    call vim_click
    mov rdi, rbx
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call pos_at_point
    mov r12, rax
    cmp qword ptr [rip + g_vt_hit], 0
    je 313f
    mov rdi, rbx                # an inlay with a command runs it (vtext.s)
    call vt_click
    test eax, eax
    jz 313f
    mov dword ptr [rip + g_dragging], 0
    mov dword ptr [rip + g_active], 0
    jmp .Led_noinput
313:
    mov rdi, rbx                # language features: ctrl+click on a link or a word (doclinks.s)
    mov rsi, r12
    call doclinks_click
    test eax, eax
    jz 314f
    mov dword ptr [rip + g_dragging], 0
    mov dword ptr [rip + g_active], 0
    jmp .Led_noinput
314:
    # multi-cursor: the modifier's clicks add carets, words or a box; a plain click collapses
    mov rdi, rbx
    mov rsi, r12
    mov edx, [rip + g_clicks]
    call sel_press
    test eax, eax
    jz 312f
    cmp eax, 1
    je .Led_noinput
    mov dword ptr [rip + g_dragging], 0
    jmp .Led_noinput
312:
    mov eax, [rip + g_clicks]
    cmp eax, 2
    je .Led_dbl
    cmp eax, 3
    je .Led_tri
    mov rdi, rbx
    mov rsi, r12
    mov edx, [rip + g_mods]
    and edx, MOD_SHIFT
    call ed_set_cursor
    mov qword ptr [rbx + DOC_prefx], -1
    mov dword ptr [rip + g_reveal], 0
    jmp .Led_noinput
.Led_dbl:
    mov dword ptr [rip + g_dragging], 0
    mov rdi, rbx
    mov rsi, r12
    call word_at
    mov [rbx + DOC_anchor], rax
    mov [rbx + DOC_cur], rdx
    call ed_touch
    mov dword ptr [rip + g_reveal], 0
    jmp .Led_noinput
.Led_tri:
    mov dword ptr [rip + g_dragging], 0
    mov [rbx + DOC_cur], r12
    mov [rbx + DOC_anchor], r12
    call cmd_select_line
    mov dword ptr [rip + g_reveal], 0
.Led_noinput:
    cmp dword ptr [rip + ed_hovered], 0
    jne 1f
    xor edi, edi
    xor esi, esi
    call ext_hover_track
    call gutter_unhover
1:  mov dword ptr [rip + ed_hovered], 0
    call hscroll_clamp           # a wheel or trackpad stops at the widest line
    # drag selection
    cmp dword ptr [rip + g_dragging], 0
    je 4f
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jnz 5f
    mov dword ptr [rip + g_dragging], 0
    mov rdi, rbx
    call sel_drag_end           # multi-cursor: a box is done, an alt+drag's selection merges
    jmp 4f
5:  mov rdi, rbx
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call sel_drag               # multi-cursor: a shift+alt drag's box follows the pointer
    test eax, eax
    jnz 6f
    mov rdi, rbx
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call pos_at_point
    cmp rax, [rbx + DOC_cur]
    je 6f
    mov [rbx + DOC_cur], rax
    mov dword ptr [rip + g_dirty], 1
    mov rdi, rbx
    call snippet_selection_changed
    call time_ms
    mov [rip + g_blink_t0], rax
6:  # autoscroll when dragging outside
    cmp dword ptr [rip + g_ed_cell], 0
    jne 4f
    mov eax, [rip + g_my]
    cmp eax, [rip + g_ed_y]
    jge 61f
    mov esi, [rip + g_lh]
    shr esi, 2
    neg esi
    call drag_scroll
61: mov eax, [rip + g_my]
    mov ecx, [rip + g_ed_y]
    add ecx, [rip + g_ed_h]
    cmp eax, ecx
    jl 4f
    mov esi, [rip + g_lh]
    shr esi, 2
    call drag_scroll
4:  cmp dword ptr [rip + cfg_vim], 0
    je 45f
    cmp dword ptr [rip + g_dragging], 0
    jne 45f
    cmp dword ptr [rip + g_ed_cell], 0
    jne 45f
    mov rdi, rbx
    call vim_view
45: test dword ptr [rbx + DOC_flags], DF_REVEAL
    jz 46f
    and dword ptr [rbx + DOC_flags], ~DF_REVEAL
    mov dword ptr [rip + g_reveal], 1
46: cmp dword ptr [rip + g_reveal], 0
    je 7f
    mov dword ptr [rip + g_reveal], 0
    cmp dword ptr [rip + g_ed_cell], 0      # the notebook places a cell's lines
    je 461f
    and dword ptr [rbx + DOC_flags], ~DF_CENTER
461:
    test dword ptr [rbx + DOC_flags], DF_CENTER
    jz 47f
    # its line in the middle of the view, now that the view's height is known (app_goto_line)
    and dword ptr [rbx + DOC_flags], ~DF_CENTER
    mov rdi, rbx
    call rows_mode
    test eax, eax
    jz 72f
    call center_wrap
    jmp 7f
72:
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    mov r8, rax                 # the line
    mov eax, [rip + g_ed_h]
    xor edx, edx
    div dword ptr [rip + g_lh]  # the lines shown
    shr eax, 1
    mov rcx, r8
    sub rcx, rax
    jns 73f
    xor ecx, ecx
73: shl rcx, 8
    mov [rbx + DOC_scrolly], rcx
47: mov rdi, rbx
    call rows_mode
    test eax, eax
    jz 71f
    call reveal_wrap
    cmp dword ptr [rip + cfg_word_wrap], 0
    jne 7f
    mov rdi, rbx                # rows because of folds: sideways as without them
    call reveal_h
    jmp 7f
71: call reveal
7:  mov rdi, rbx
    call clamp_scroll
    # syntax states for everything visible
    mov rsi, [rbx + DOC_scrolly]
    shr rsi, 8
    mov eax, [rip + g_ed_h]
    xor edx, edx
    div dword ptr [rip + g_lh]
    mov [rip + g_ed_h_lines], eax
    lea rsi, [rsi + rax + 2]
    mov rdi, rbx
    push rsi
    push rsi
    call syntax_prepare
    pop rdx
    pop rdx
    mov rsi, [rbx + DOC_scrolly]
    shr rsi, 8
    mov rdi, rbx
    call deco_frame             # the decorations on these lines, once per change (deco.s)
    # ---- lines ----
    mov qword ptr [rip + cls_doc], 0
    mov rdi, rbx
    cmp dword ptr [rip + g_ed_cell], 1      # a cell without the keyboard has no cursor to match at
    jne 152f
    mov qword ptr [rip + g_br], -1
    mov qword ptr [rip + g_br + 8], -1
    mov qword ptr [rip + g_br_doc], 0
    jmp 153f
152:
    call match_brackets
153:
    mov rdi, rbx
    call sel_frame              # the other selections, for draw_line's rows
    mov dword ptr [rip + g_caret_ok], 0
    mov dword ptr [rip + dl_from], 0
    mov dword ptr [rip + dl_to], -1
    mov dword ptr [rip + dl_last], 1
    call rows_mode
    test eax, eax
    jz 72f
    cmp dword ptr [rip + cfg_word_wrap], 0
    je 74f
    mov qword ptr [rbx + DOC_scrollx], 0
74: mov rdi, rbx
    call draw_wrapped
    jmp .Led_lines_done
72: mov rax, [rbx + DOC_scrolly]
    mov rcx, rax
    shr rax, 8
    mov r12, rax                # first line
    and ecx, 255
    imul ecx, [rip + g_lh]
    shr ecx, 8
    mov eax, [rip + g_ed_y]
    sub eax, ecx
    mov r13d, eax               # y of first line
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    mov [rsp + 8], rax          # cursor line
    mov rdi, rbx
    call vim_sel
    mov [rsp + 16], rax         # sel start
    mov [rsp + 24], rdx         # sel end
    mov dword ptr [rsp + 32], 0 # last indent (for blank lines)
    mov rdi, rbx
    call git_doc_marks
    mov [rsp + 96], rax
.Led_line:
    cmp r12, [rbx + DOC_nlines]
    jae .Led_lines_done
    mov eax, [rip + g_ed_y]
    add eax, [rip + g_ed_h]
    cmp r13d, eax
    jge .Led_lines_done
    # current line highlight
    cmp dword ptr [rip + cfg_highlight_line], 0
    je 1f
    cmp dword ptr [rip + g_ed_cell], 1      # not in a cell without the keyboard
    je 1f
    cmp r12, [rsp + 8]
    jne 14f
    mov rax, [rsp + 16]
    cmp rax, [rsp + 24]
    jne 1f
    jmp 15f
14: mov rdi, rbx                # and the lines of the other carets
    mov rsi, r12
    call sel_line_tint
    test eax, eax
    jz 1f
15: mov edi, [rip + g_ed_x]
    mov esi, r13d
    mov edx, [rip + g_ed_w]
    mov ecx, [rip + g_lh]
    COLOR r8d, T_LINE_HL
    call gfx_fill
1:  mov rdi, r12
    mov esi, r13d
    mov edx, [rip + g_lh]
    call draw_disk_range
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, [rip + g_lh]
    call deco_line_back         # whole-line decoration backgrounds
    mov rdi, rbx                # debugger: the paused line's background (debuggutter.s)
    mov rsi, r12
    mov edx, r13d
    mov ecx, [rip + g_lh]
    call dbg_line_back
    # line number
    cmp qword ptr [rbx + DOC_diff], 0
    jne .Led_diffline
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, [rip + g_lh]
    call gutter_line_under      # a tint behind it (coverage)
    cmp dword ptr [rip + cfg_line_numbers], 0
    je 2f
    lea rdi, [rsp + 40]
    lea rsi, [r12 + 1]
    call fmt_u64
    mov r14, rax
    lea rdi, [rip + g_face_code]
    lea rsi, [rsp + 40]
    mov rdx, rax
    call text_width
    mov esi, [rip + g_gl_digits_r]
    sub esi, eax
    COLOR r9d, T_LINENO
    cmp r12, [rsp + 8]
    jne 11f
    COLOR r9d, T_LINENO_ACTIVE
11: lea rdi, [rip + g_face_code]
    mov edx, r13d
    add edx, [rip + g_base]
    lea rcx, [rsp + 40]
    mov r8, r14
    call text_draw
2:  # git change mark
    mov rax, [rsp + 96]
    test rax, rax
    jz 21f
    movzx edi, byte ptr [rax + r12]
    test edi, edi
    jz 21f
    mov esi, r13d
    mov edx, [rip + g_lh]
    call mark_draw
21: mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, [rip + g_lh]
    call gutter_line            # the left lane's glyph (gutter.s)
    # text area clip
    mov edi, [rip + g_ed_tx]
    sub edi, [rip + g_mt + 4*MI_4]
    mov esi, [rip + g_ed_y]
    mov edx, [rip + g_ed_x]
    add edx, [rip + g_ed_w]
    sub edx, edi
    mov ecx, [rip + g_ed_h]
    call gfx_clip_push
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    lea rcx, [rsp + 16]
    call draw_line
    call gfx_clip_pop
.Led_adv:
    add r13d, [rip + g_lh]
    inc r12
    jmp .Led_line
.Led_diffline:
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, [rip + g_lh]
    call diffview_line
    test eax, eax
    jz 21b
    jmp .Led_adv
.Led_lines_done:
    # the lines shown, for extensions (`0 visible`, deco.s; the providers' windows, present.s)
    mov rdi, rbx
    mov rsi, [rbx + DOC_scrolly]
    shr rsi, 8
    call rows_mode
    test eax, eax
    jz 0f
    mov rsi, [rbx + DOC_wtop]
0:  mov rdx, [rip + g_row_line]
    cmp rdx, rsi
    jae 1f
    mov rdx, rsi
1:  call deco_visible
    # caret
    cmp dword ptr [rip + g_ed_cell], 1
    je 151f
    mov rdi, rbx
    call draw_caret
    mov rdi, rbx
    mov esi, [rip + g_ed_tx]
    call sel_carets             # and the other selections' carets
151:
    # gutter separator shadow when scrolled horizontally
    cmp qword ptr [rbx + DOC_scrollx], 0
    je 8f
    mov edi, [rip + g_ed_tx]
    sub edi, [rip + g_mt + 4*MI_4]
    mov esi, [rip + g_ed_y]
    M edx, MI_1
    mov ecx, [rip + g_ed_h]
    COLOR r8d, T_BORDER
    call gfx_fill
8:  cmp dword ptr [rip + g_ed_cell], 0      # a cell has no scrollbars
    jne 93f
    # scrollbar: px in 64 bits, a million lines' offset overflows 32. ui_scrollbar takes i32, so a
    # document past 2^31 px goes in units of 2^k px, the whole of it still under the thumb.
    # Folded lines are not counted (fold.s: the rows the view scrolls through).
    mov rdi, rbx
    call fold_scroll_rows
    inc rax
    movsxd rcx, dword ptr [rip + g_lh]
    imul rax, rcx
    cmp dword ptr [rip + cfg_scroll_past_end], 0
    je 81f
    movsxd rcx, dword ptr [rip + g_ed_h]
    add rax, rcx
    movsxd rcx, dword ptr [rip + g_lh]
    sub rax, rcx
81: xor ecx, ecx
82: cmp rax, 0x7fffffff
    jle 83f
    shr rax, 1
    inc ecx
    jmp 82b
83: mov [rsp + 48], eax         # content
    mov [rsp + 56], ecx         # k
    mov eax, [rip + g_block]
    mov [rsp + 104], eax
    call find_blocks_editor
    or [rip + g_block], eax
    mov eax, [rip + g_block]
    mov [rsp + 108], eax
    mov rdi, rbx
    call fold_scroll_value      # DOC_scrolly, or its row with folds
    movsxd rcx, dword ptr [rip + g_lh]
    imul rax, rcx
    sar rax, 8
    mov ecx, [rsp + 56]
    sar rax, cl
    mov [rsp + 52], eax         # offset
    mov [rsp + 60], eax         # as drawn: a frame that leaves it writes nothing back
    mov eax, [rip + g_ed_h]
    shr eax, cl
    push rax
    mov eax, [rsp + 48 + 8]
    push rax
    mov edi, ID_EDSCROLL
    mov esi, [rip + g_ed_x]
    add esi, [rip + g_ed_w]
    M eax, MI_12
    sub esi, eax
    mov edx, [rip + g_ed_y]
    mov ecx, eax
    mov r8d, [rip + g_ed_h]
    lea r9, [rsp + 52 + 16]
    call ui_scrollbar
    add rsp, 16
    mov rdi, rbx                # decorations' ticks over the track (deco.s)
    mov esi, [rip + g_ed_x]
    add esi, [rip + g_ed_w]
    sub esi, [rip + g_mt + 4*MI_12]
    mov edx, [rip + g_ed_y]
    M ecx, MI_12
    mov r8d, [rip + g_ed_h]
    call deco_scroll_ticks
    mov eax, [rsp + 104]
    mov [rip + g_block], eax
    # scrollbar drag writes pixels back when it moved them; the release frame leaves the offset,
    # and a round trip through px would round the scroll down
    cmp dword ptr [rsp + 108], 0
    jne 91f
    cmp dword ptr [rip + g_active], ID_EDSCROLL
    jne 91f
    mov eax, [rsp + 52]
    cmp eax, [rsp + 60]
    je 91f
    movsxd rax, eax
    mov ecx, [rsp + 56]
    shl rax, cl
    shl rax, 8
    cqo
    movsxd rcx, dword ptr [rip + g_lh]
    idiv rcx
    mov rdi, rbx
    mov rsi, rax
    call fold_scroll_set        # DOC_scrolly, through the rows with folds
91: # horizontal scrollbar: the widest line against the text area, when lines do not wrap
    cmp dword ptr [rip + hs_on], 0
    je 93f
    mov rax, [rbx + DOC_scrollx]
    mov [rip + hs_off], eax
    mov eax, [rip + g_block]
    mov [rsp + 104], eax
    call find_blocks_editor
    or [rip + g_block], eax
    mov eax, [rip + g_block]
    mov [rsp + 108], eax
    mov eax, [rip + g_ed_tx]
    mov [rip + hs_track], eax
    mov eax, [rip + g_ed_y]
    add eax, [rip + g_ed_h]
    sub eax, [rip + g_mt + 4*MI_12]
    mov [rip + hs_track + 4], eax
    mov eax, [rip + g_ed_x]
    add eax, [rip + g_ed_w]
    sub eax, [rip + g_mt + 4*MI_12]     # the corner stays the vertical one's
    sub eax, [rip + g_ed_tx]
    mov [rip + hs_track + 8], eax
    M eax, MI_12
    mov [rip + hs_track + 12], eax
    mov eax, [rip + hs_view]
    push rax
    mov eax, [rip + hs_content]
    push rax
    mov edi, ID_EDHSCROLL
    mov esi, [rip + hs_track]
    mov edx, [rip + hs_track + 4]
    mov ecx, [rip + hs_track + 8]
    mov r8d, [rip + hs_track + 12]
    lea r9, [rip + hs_off]
    call ui_hscrollbar
    add rsp, 16
    mov eax, [rsp + 104]
    mov [rip + g_block], eax
    cmp dword ptr [rsp + 108], 0
    jne 93f
    cmp dword ptr [rip + g_active], ID_EDHSCROLL
    jne 93f
    movsxd rax, dword ptr [rip + hs_off]
    mov [rbx + DOC_scrollx], rax
93: # a thin edge also signals changes outside the visible lines, without moving the view
    mov r8d, [rip + disk_edge]
    test r8d, r8d
    jz 92f
    mov edi, [rip + g_ed_x]
    mov esi, [rip + g_ed_y]
    mov edx, [rip + g_ed_w]
    M ecx, MI_2
    call gfx_fill
92: call gfx_clip_pop
.Led_ret:
    EPILOGUE

# editor_draw_cell(doc, x, y, w, h, keyboard): a notebook's cell (nbview.s) as the editor draws a
#   document, at its full height: no scrollbars, no vertical scrolling of its own (DOC_scrolly says
#   how much of it is above the view), no wrapping; with keyboard 1 it has the caret and takes the
#   pointer as the editor does, else it is drawn only
FN editor_draw_cell
    PROLOGUE 16
    mov rax, [rip + g_doc]
    mov [rsp], rax
    mov [rip + g_doc], rdi
    mov eax, [rip + cfg_word_wrap]
    mov [rsp + 8], eax
    mov dword ptr [rip + cfg_word_wrap], 0
    mov eax, 1
    test r9d, r9d
    jz 1f
    mov eax, 3
1:  mov [rip + g_ed_cell], eax
    mov edi, esi
    mov esi, edx
    mov edx, ecx
    mov ecx, r8d
    call editor_draw
    mov dword ptr [rip + g_ed_cell], 0
    mov eax, [rsp + 8]
    mov [rip + cfg_word_wrap], eax
    mov rax, [rsp]
    mov [rip + g_doc], rax
    EPILOGUE

# disk_colors(): compute the active file's fade once per frame
disk_colors:
    mov dword ptr [rip + disk_edge], 0
    mov dword ptr [rip + disk_tint], 0
    mov rax, [rip + g_doc]
    cmp qword ptr [rax + DOC_disk_until], 0
    je 2f
    push rbx
    mov rbx, rax
    call time_ms
    mov rcx, [rbx + DOC_disk_until]
    sub rcx, rax
    jle 1f
    imul rax, rcx, 255
    xor edx, edx
    mov ecx, DISK_FADE_MS
    div rcx
    cmp eax, 255
    jbe 3f
    mov eax, 255
3:  COLOR ecx, T_ACCENT
    and ecx, 0x00ffffff
    mov edx, eax
    shl edx, 24
    or edx, ecx
    mov [rip + disk_edge], edx
    shr eax, 2                 # line tint starts at 25% opacity, beneath text and selection
    shl eax, 24
    or eax, ecx
    mov [rip + disk_tint], eax
1:  pop rbx
2:  ret

# draw_disk_range(line, y, height): one inexpensive range check per visible logical line
draw_disk_range:
    mov r8d, [rip + disk_tint]
    test r8d, r8d
    jz 1f
    mov rax, [rip + g_doc]
    cmp rdi, [rax + DOC_disk_lo]
    jb 1f
    cmp rdi, [rax + DOC_disk_hi]
    jae 1f
    mov ecx, edx
    mov edi, [rip + g_ed_x]
    mov edx, [rip + g_ed_w]
    jmp gfx_fill
1:  ret

# disk_warning(): an inline warning only for a conflict; keep all local edits in the code view
disk_warning:
    PROLOGUE
    mov rax, [rip + g_doc]
    test dword ptr [rax + DOC_flags], DF_DISK_CHANGED
    jz 9f
    M ebx, MI_28
    mov eax, ebx
    add eax, ebx
    cmp [rip + g_ed_h], eax
    jl 9f
    mov edi, [rip + g_ed_x]
    mov esi, [rip + g_ed_y]
    mov edx, [rip + g_ed_w]
    mov ecx, ebx
    COLOR r8d, T_PANEL
    call gfx_fill
    lea rdi, [rip + g_face_small]
    mov esi, [rip + g_ed_x]
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, [rip + g_ed_y]
    mov ecx, ebx
    lea r8, [rip + .Ldisk_warning]
    COLOR r9d, T_WARNING
    call ui_text_c
    mov edi, [rip + g_ed_x]
    mov esi, [rip + g_ed_y]
    add esi, ebx
    sub esi, [rip + g_mt + 4*MI_1]
    mov edx, [rip + g_ed_w]
    M ecx, MI_1
    COLOR r8d, T_WARNING
    call gfx_fill
    add [rip + g_ed_y], ebx
    sub [rip + g_ed_h], ebx
9:  EPILOGUE

# draw_line(doc, line, y, selrange*): draws bytes [dl_from, dl_to) of the line as one visual row
draw_line:
    PROLOGUE 128
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx              # y
    mov rax, [rcx]
    mov [rsp + 8], rax          # sel start
    mov rax, [rcx + 8]
    mov [rsp + 16], rax         # sel end
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov [rsp + 24], rax         # line start pos
    mov rdi, rbx
    mov rsi, r12
    call doc_line_text
    mov r14, rax
    mov r15, rdx
    # segment
    mov eax, [rip + dl_to]
    cmp rax, r15
    jbe 1f
    mov rax, r15
1:  mov [rsp + 32], rax         # to (offset)
    mov eax, [rip + dl_from]
    mov [rsp + 96], rax         # from (offset)
    # classes for the whole line (cached across the rows of one line; a long one's across frames,
    # which tokenized all of a minified file's line on every frame)
    cmp r15, CLS_LONG
    jb 10f
    cmp [rip + g_long_doc], rbx
    jne 11f
    cmp [rip + long_line], r12
    jne 11f
    cmp [rip + long_len], r15
    jne 11f
    mov rax, [rbx + DOC_version]
    cmp [rip + long_ver], rax
    jne 11f
    mov rax, [rbx + DOC_svalid]
    cmp [rip + long_svalid], rax
    jne 11f
    mov rdi, rbx
    call doc_language
    cmp [rip + long_lang], rax
    je 12f
11: mov [rip + g_long_doc], rbx
    mov [rip + long_line], r12
    mov [rip + long_len], r15
    mov rax, [rbx + DOC_version]
    mov [rip + long_ver], rax
    mov rax, [rbx + DOC_svalid]
    mov [rip + long_svalid], rax
    mov rdi, rbx
    call doc_language
    mov [rip + long_lang], rax
    lea rdi, [rip + long_cls]
    mov qword ptr [rdi + SB_len], 0
    lea rsi, [r15 + 16]
    call sb_reserve
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    mov rcx, r15
    mov r8, [rip + long_cls + SB_ptr]
    call syntax_line
12: mov rax, [rip + long_cls + SB_ptr]
    mov [rip + cls_ptr], rax
    jmp 3f
10: cmp [rip + cls_doc], rbx
    jne 2f
    cmp [rip + cls_line], r12
    jne 2f
    mov rax, [rbx + DOC_version]
    cmp [rip + cls_ver], rax
    jne 2f
    mov rax, [rbx + DOC_svalid]
    cmp [rip + cls_svalid], rax
    je 13f
2:  mov [rip + cls_doc], rbx
    mov [rip + cls_line], r12
    mov rax, [rbx + DOC_version]
    mov [rip + cls_ver], rax
    mov rax, [rbx + DOC_svalid]
    mov [rip + cls_svalid], rax
    lea rdi, [rip + classes]
    mov qword ptr [rdi + SB_len], 0
    lea rsi, [r15 + 16]
    call sb_reserve
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    mov rcx, r15
    mov r8, [rip + classes + SB_ptr]
    call syntax_line
13: mov rax, [rip + classes + SB_ptr]
    mov [rip + cls_ptr], rax
3:  # semantic tokens over the syntax classes (semtok.s)
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rsp + 24]
    mov rcx, [rip + cls_ptr]
    mov r8, r15
    call semtok_line
    mov [rip + cls_ptr], rax
    # x origin
    mov eax, [rip + g_ed_tx]
    sub eax, [rbx + DOC_scrollx]
    mov [rsp + 40], eax
    # the row, for the presentation layers (deco.s): decoration backgrounds under the selection
    mov [rip + g_row_doc], rbx
    mov [rip + g_row_line], r12
    mov rcx, [rsp + 24]
    mov [rip + g_row_lstart], rcx
    mov [rip + g_row_text], r14
    mov [rip + g_row_len], r15
    mov rcx, [rsp + 96]
    mov [rip + g_row_from], rcx
    mov rcx, [rsp + 32]
    mov [rip + g_row_to], rcx
    mov [rip + g_row_x], eax
    mov eax, [rsp]
    mov [rip + g_row_y], eax
    call vt_row_set             # its inlays (vtext.s): every x below goes through vt_x
    call deco_row_back
    # ---- selection ----
    mov rax, [rsp + 8]
    cmp rax, [rsp + 16]
    je .Ldl_nosel
    mov rcx, [rsp + 24]
    add rcx, [rsp + 96]         # row start pos
    mov rdx, [rsp + 24]
    add rdx, [rsp + 32]         # row end pos
    cmp rax, rcx
    cmovb rax, rcx              # a = max(S, row start)
    mov r8, [rsp + 16]
    xor r9d, r9d                # extra cell for the newline
    cmp r8, rdx
    jbe 4f
    mov r8, rdx                 # b = min(E, row end)
    cmp dword ptr [rip + dl_last], 0
    je 4f
    mov r9d, 1
4:  cmp rax, r8
    ja .Ldl_nosel
    jb 5f
    test r9d, r9d
    jz .Ldl_nosel
5:  mov [rsp + 48], r8
    mov [rsp + 60], r9d
    mov rdi, rax
    sub rdi, [rsp + 24]
    mov [rsp + 104], rdi
    mov esi, VTM_RIGHT          # a range covers the inlays after its start, before its end
    call vt_x
    mov [rsp + 56], eax         # start x
    mov rdi, [rsp + 48]
    sub rdi, [rsp + 24]
    mov esi, VTM_LEFT
    call vt_x
    mov edx, [rsp + 60]
    imul edx, [rip + g_cw]
    add eax, edx
    sub eax, [rsp + 56]
    mov edx, eax
    mov edi, [rsp + 56]
    mov esi, [rsp]
    mov ecx, [rip + g_lh]
    COLOR r8d, T_SELECTION
    call gfx_fill
.Ldl_nosel:
    # the other selections' fills and carets on this row (multi-cursor)
    mov rdi, r14
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 96]
    mov rcx, [rsp + 32]
    mov r8d, [rsp + 40]
    mov r9d, [rsp]
    call sel_row
    mov rdi, r14                # wsedit: linked editing's ranges outlined
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 96]
    mov rcx, [rsp + 32]
    mov r8d, [rsp + 40]
    mov r9d, [rsp]
    call ws_linked_row
    # ---- find matches ----
    mov rcx, [rip + g_ed_find + SB_len]
    test rcx, rcx
    jz .Ldl_nofind
    mov rax, [rsp + 96]
    mov [rsp + 112], rax        # byte offset whose column is known
    mov dword ptr [rsp + 120], 0
    xor r13d, r13d
6:  lea rdi, [r14 + r13]
    mov rsi, r15
    sub rsi, r13
    jbe .Ldl_nofind
    mov rdx, [rip + g_ed_find + SB_ptr]
    mov rcx, [rip + g_ed_find + SB_len]
    call find_raw
62: test rax, rax
    js .Ldl_nofind
    add r13, rax
    cmp r13, [rsp + 32]
    jae .Ldl_nofind
    # clip [m, m+n) to the row
    mov rax, r13
    mov rdx, r13
    add rdx, [rip + g_ed_find + SB_len]
    mov rcx, [rsp + 96]
    cmp rax, rcx
    cmovb rax, rcx
    mov rcx, [rsp + 32]
    cmp rdx, rcx
    cmova rdx, rcx
    cmp rax, rdx
    jae 63f
    mov [rsp + 48], rdx
    mov [rsp + 104], rax
    cmp qword ptr [rip + g_row_vt], 0
    jne 64f
    mov rdi, r14
    mov rsi, [rsp + 112]
    mov rdx, rax
    mov ecx, [rsp + 120]
    call seg_cols_from
    mov [rsp + 56], eax
    imul eax, [rip + g_cw]
    add eax, [rsp + 40]
    cmp eax, [rip + g_cv + CV_cx1]
    jge .Ldl_nofind             # later matches are also outside the view
    mov rdi, r14
    mov rsi, [rsp + 104]
    mov rdx, [rsp + 48]
    mov ecx, [rsp + 56]
    call seg_cols_from
    mov [rsp + 120], eax
    mov rcx, [rsp + 48]
    mov [rsp + 112], rcx
    sub eax, [rsp + 56]
    imul eax, [rip + g_cw]
    mov edx, eax
    mov edi, [rsp + 56]
    imul edi, [rip + g_cw]
    add edi, [rsp + 40]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_1]
    mov ecx, [rip + g_lh]
    sub ecx, [rip + g_mt + 4*MI_2]
    M r8d, MI_3
    COLOR r9d, T_MATCH
    call gfx_round_rect
63: add r13, [rip + g_ed_find + SB_len]
    jmp 6b
64: # a row with inlays: the match's edges by the range rule (vtext.s)
    mov rdi, [rsp + 104]
    mov esi, VTM_RIGHT
    call vt_x
    mov [rsp + 56], eax
    cmp eax, [rip + g_cv + CV_cx1]
    jge .Ldl_nofind
    mov rdi, [rsp + 48]
    mov esi, VTM_LEFT
    call vt_x
    sub eax, [rsp + 56]
    mov edx, eax
    mov edi, [rsp + 56]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_1]
    mov ecx, [rip + g_lh]
    sub ecx, [rip + g_mt + 4*MI_2]
    M r8d, MI_3
    COLOR r9d, T_MATCH
    call gfx_round_rect
    jmp 63b
.Ldl_nofind:
    # ---- bracket pair ----
    mov qword ptr [rsp + 112], 0
.Ldl_br:
    mov rcx, [rsp + 112]
    cmp rcx, 2
    jae .Ldl_nobr
    inc qword ptr [rsp + 112]
    lea rax, [rip + g_br]
    mov rax, [rax + rcx*8]
    sub rax, [rsp + 24]
    js .Ldl_br
    cmp rax, [rsp + 96]
    jb .Ldl_br
    cmp rax, [rsp + 32]
    jae .Ldl_br
    mov rdi, rax
    mov esi, VTM_RIGHT
    call vt_x
    mov edi, eax
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_1]
    mov edx, [rip + g_cw]
    mov ecx, [rip + g_lh]
    sub ecx, [rip + g_mt + 4*MI_2]
    COLOR r8d, T_MUTED
    call draw_box
    jmp .Ldl_br
.Ldl_nobr:
    # ---- caret position ----
    mov rax, [rbx + DOC_cur]
    sub rax, [rsp + 24]
    js 7f
    cmp rax, [rsp + 96]
    jb 7f
    cmp rax, [rsp + 32]
    jb 71f
    ja 7f
    cmp dword ptr [rip + dl_last], 0
    je 7f
71: mov rdi, rax
    mov esi, VTM_CARET          # the caret touches the text it extends (vtext.s)
    call vt_x
    mov [rip + g_caret_x], eax
    mov eax, [rsp]
    mov [rip + g_caret_y], eax
    mov dword ptr [rip + g_caret_ok], 1
7:  # ---- glyphs ----
    mov r13, [rsp + 96]         # byte index
    mov dword ptr [rsp + 64], 0 # column
    mov eax, [rsp]
    add eax, [rip + g_base]
    mov [rsp + 72], eax         # baseline
    mov eax, [rip + g_cv + CV_cx1]
    mov [rsp + 76], eax
.Ldl_glyph:
    cmp qword ptr [rip + g_row_vt], 0
    je 70f
    mov rdi, r13                # the inlays at this gap (vtext.s)
    mov esi, [rsp + 64]
    mov edx, [rsp + 72]
    call vt_draw_at
    mov [rsp + 64], eax
70: cmp r13, [rsp + 32]
    jae .Ldl_guides
    mov eax, [rsp + 64]
    imul eax, [rip + g_cw]
    add eax, [rsp + 40]
    cmp eax, [rsp + 76]
    jge .Ldl_guides
    mov [rsp + 80], eax         # x
    movzx eax, byte ptr [r14 + r13]
    cmp al, 9
    jne 8f
    mov eax, [rsp + 64]
    xor edx, edx
    div dword ptr [rip + g_tab_width]
    mov eax, [rip + g_tab_width]
    sub eax, edx
    mov [rsp + 84], eax
    cmp dword ptr [rip + cfg_whitespace], 0
    je 81f
    lea rdi, [rip + g_face_code]
    mov esi, [rsp + 80]
    mov edx, [rsp + 72]
    lea rcx, [rip + .Ltab_arrow]
    mov r8d, 3
    COLOR r9d, T_GUIDE
    call text_draw
81: mov eax, [rsp + 84]
    add [rsp + 64], eax
    inc r13
    jmp .Ldl_glyph
8:  cmp al, ' '
    jne 9f
    cmp dword ptr [rip + cfg_whitespace], 0
    je 82f
    lea rdi, [rip + g_face_code]
    mov esi, [rsp + 80]
    mov edx, [rsp + 72]
    lea rcx, [rip + .Lmiddot]
    mov r8d, 2
    COLOR r9d, T_GUIDE
    call text_draw
82: inc dword ptr [rsp + 64]
    inc r13
    jmp .Ldl_glyph
    # a glyph wholly left of the clip (two cells, a wide one's) only moves the column: a long line
    # scrolled sideways drew all of its text up to the window's left edge every frame
9:  mov ecx, [rip + g_cw]
    mov eax, [rsp + 80]
    lea eax, [rax + rcx*2]
    cmp eax, [rip + g_cv + CV_cx0]
    jg 93f
    movzx eax, byte ptr [r14 + r13]
    lea ecx, [rax - 0x21]
    cmp ecx, 0x7e - 0x21
    ja 92f
    inc dword ptr [rsp + 64]
    inc r13
    jmp .Ldl_glyph
92: lea rdi, [r14 + r13]
    mov rsi, r15
    sub rsi, r13
    call utf8_decode
    mov [rsp + 84], edx
    mov edi, eax
    call cp_width
    add [rsp + 64], eax
    mov eax, [rsp + 84]
    add r13, rax
    jmp .Ldl_glyph
93: lea rdi, [r14 + r13]
    mov rsi, r15
    sub rsi, r13
    call utf8_decode
    mov [rsp + 84], edx         # byte length
    mov [rsp + 88], eax         # codepoint
    mov rcx, [rip + cls_ptr]
    movzx ecx, byte ptr [rcx + r13]
    lea rdx, [rip + g_theme]
    mov r9d, [rdx + rcx*4 + 4*T_SYN]
    cmp dword ptr [rip + g_row_fx], 0
    je 94f
    mov rdi, r13                # a decoration's text color (deco.s)
    mov esi, r9d
    call deco_span_color
    mov r9d, eax
94: mov r8d, [rsp + 84]
    lea rdi, [rip + g_face_code]
    mov esi, [rsp + 80]
    mov edx, [rsp + 72]
    lea rcx, [r14 + r13]
    call text_draw
    mov edi, [rsp + 88]
    call cp_width
    add [rsp + 64], eax
    mov eax, [rsp + 84]
    add r13, rax
    jmp .Ldl_glyph
.Ldl_guides:
    cmp dword ptr [rip + cfg_indent_guides], 0
    je .Ldl_ret
    cmp qword ptr [rsp + 96], 0
    jne .Ldl_ret
    # indent columns of this line (blank lines reuse the previous one)
    mov rdi, rbx
    mov rsi, r12
    call line_indent
    cmp rax, r15
    jne 10f
    mov edx, [rip + last_indent]
10: mov [rip + last_indent], edx
    mov ecx, [rip + g_tab_width]
    mov [rsp + 64], ecx
11: mov eax, [rsp + 64]
    cmp eax, [rip + last_indent]
    jg .Ldl_ret
    sub eax, [rip + g_tab_width]
    imul eax, [rip + g_cw]
    add eax, [rsp + 40]
    mov edi, eax
    mov esi, [rsp]
    M edx, MI_1
    mov ecx, [rip + g_lh]
    COLOR r8d, T_GUIDE
    call gfx_fill
    mov eax, [rip + g_tab_width]
    add [rsp + 64], eax
    jmp 11b
.Ldl_ret:
    call deco_row_front         # decorations' strike, underline, border (deco.s)
    # the extensions' marks on this row
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rsp + 96]
    mov rcx, [rsp + 32]
    mov r8d, [rsp + 40]
    mov r9d, [rsp]
    call extmarks_row
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rsp + 96]
    mov rcx, [rsp + 32]
    mov r8d, [rsp + 40]
    mov r9d, [rsp]
    call definitionlink_row
    EPILOGUE

# draw_box(x, y, w, h, argb): 1px outline, softened
draw_box:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebx, r8d
    and ebx, 0xffffff
    or ebx, 0xa0000000
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, [rip + g_border]
    mov r8d, ebx
    call gfx_fill
    mov edi, r12d
    lea esi, [r13 + r15]
    sub esi, [rip + g_border]
    mov edx, r14d
    mov ecx, [rip + g_border]
    mov r8d, ebx
    call gfx_fill
    mov edi, r12d
    mov esi, r13d
    add esi, [rip + g_border]
    mov edx, [rip + g_border]
    mov ecx, r15d
    sub ecx, [rip + g_border]
    sub ecx, [rip + g_border]
    mov r8d, ebx
    call gfx_fill
    lea edi, [r12 + r14]
    sub edi, [rip + g_border]
    mov esi, r13d
    add esi, [rip + g_border]
    mov edx, [rip + g_border]
    mov ecx, r15d
    sub ecx, [rip + g_border]
    sub ecx, [rip + g_border]
    mov r8d, ebx
    call gfx_fill
    EPILOGUE

# match_brackets(doc): g_br = the bracket at or before the cursor and its partner, else -1
match_brackets:
    PROLOGUE 32
    mov rbx, rdi
    # found again only when what it depends on changed: the search walks up to 100,000 bytes, on
    # every frame while the caret is at a bracket whose partner is far or missing
    cmp [rip + g_br_doc], rbx
    jne 0f
    mov rax, [rbx + DOC_version]
    cmp [rip + br_ver], rax
    jne 0f
    mov rax, [rbx + DOC_cur]
    cmp [rip + br_cur], rax
    jne 0f
    mov rax, [rbx + DOC_anchor]
    cmp [rip + br_anchor], rax
    jne 0f
    mov eax, [rip + cfg_match_brackets]
    cmp [rip + br_on], eax
    je 9f
0:  mov [rip + g_br_doc], rbx
    mov rax, [rbx + DOC_version]
    mov [rip + br_ver], rax
    mov rax, [rbx + DOC_cur]
    mov [rip + br_cur], rax
    mov rax, [rbx + DOC_anchor]
    mov [rip + br_anchor], rax
    mov eax, [rip + cfg_match_brackets]
    mov [rip + br_on], eax
    mov qword ptr [rip + g_br], -1
    mov qword ptr [rip + g_br + 8], -1
    cmp dword ptr [rip + cfg_match_brackets], 0
    je 9f
    mov rdi, rbx
    call lc_bracket_str         # the language configuration's brackets (langconf.s)
    mov [rip + br_set], rax
    mov r12, [rbx + DOC_cur]
    cmp r12, [rbx + DOC_anchor]
    jne 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_byte
    call bracket_kind
    test edx, edx
    jnz 1f
    test r12, r12
    jz 9f
    dec r12
    mov rdi, rbx
    mov rsi, r12
    call doc_byte
    call bracket_kind
    test edx, edx
    jz 9f
1:  mov r13d, eax               # this bracket
    mov r14d, ecx               # its partner
    movsxd r15, edx             # direction
    mov [rsp], r12
    mov qword ptr [rsp + 8], 0  # depth
    mov qword ptr [rsp + 16], 100000
2:  dec qword ptr [rsp + 16]
    js 9f
    add r12, r15
    js 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_byte
    test eax, eax
    jz 9f
    cmp eax, r13d
    jne 3f
    inc qword ptr [rsp + 8]
    jmp 2b
3:  cmp eax, r14d
    jne 2b
    dec qword ptr [rsp + 8]
    jns 2b
    mov rax, [rsp]
    mov [rip + g_br], rax
    mov [rip + g_br + 8], r12
9:  EPILOGUE

# bracket_kind(eax byte) -> eax byte, ecx partner, edx +1 opening / -1 closing / 0 none
bracket_kind:
    mov r8, [rip + br_set]
    test r8, r8
    jnz 0f
    lea r8, [rip + .Lbrackets]
0:
    xor edx, edx
1:  movzx ecx, byte ptr [r8 + rdx]
    test ecx, ecx
    jz 3f
    cmp eax, ecx
    je 2f
    inc edx
    jmp 1b
2:  test edx, 1
    jnz 4f
    movzx ecx, byte ptr [r8 + rdx + 1]
    mov edx, 1
    ret
4:  movzx ecx, byte ptr [r8 + rdx - 1]
    mov edx, -1
    ret
3:  xor edx, edx
    ret

# draw_caret(doc): at the position recorded by draw_line
draw_caret:
    PROLOGUE 16
    mov rbx, rdi
    cmp dword ptr [rip + g_caret_ok], 0
    je 9f
    cmp dword ptr [rip + g_vim_cmdline], 0
    jne 9f
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 9f
    mov edi, [rip + g_caret_x]
    cmp edi, [rip + g_ed_tx]
    jl 9f
    mov dword ptr [rip + caret_frame], 1     # on screen: a caret to blink
    call ed_caret_shown
    test eax, eax
    jz 9f
    mov edi, [rip + g_caret_x]
    # vim: a block over the character outside insert mode
    cmp dword ptr [rip + cfg_vim], 0
    je 11f
    mov eax, [rip + g_vim_mode]
    cmp eax, VM_INSERT
    je 11f
    cmp eax, VM_NORMAL
    jne draw_block
    mov rax, [rbx + DOC_cur]
    cmp rax, [rbx + DOC_anchor]
    je draw_block
11: mov esi, [rip + g_caret_y]
    M edx, MI_2
    cmp dword ptr [rip + cfg_smooth_caret], 0
    jne 2f
    M edx, MI_1
2:  mov ecx, [rip + g_lh]
    COLOR r8d, T_CURSOR
    call gfx_fill
9:  EPILOGUE

# draw_block: tail of draw_caret (rbx doc): the character at the cursor in the background color on the cursor color
draw_block:
    mov r12, [rbx + DOC_cur]
    mov rdi, rbx
    call doc_len
    mov r13, rax
    sub r13, r12                # bytes left
    mov r14d, [rip + g_cw]      # width
    xor r15d, r15d              # bytes to draw
    test r13, r13
    jz 3f
    mov rdi, rbx
    mov rsi, r12
    mov edx, 4
    cmp r13, 4
    cmovb rdx, r13
    mov [rsp + 8], rdx
    call doc_range
    mov [rsp], rax
    movzx ecx, byte ptr [rax]
    cmp ecx, ' '
    jbe 3f
    mov rdi, rax
    mov rsi, [rsp + 8]
    call utf8_decode
    mov r15d, edx
    mov edi, eax
    call cp_width
    imul r14d, eax
    # doc_range may reuse its scratch buffer: keep the bytes
    mov rsi, [rsp]
    xor ecx, ecx
4:  mov al, [rsi + rcx]
    mov [rsp + 8 + rcx], al
    inc ecx
    cmp ecx, r15d
    jb 4b
3:  mov edi, [rip + g_caret_x]
    mov esi, [rip + g_caret_y]
    mov edx, r14d
    mov ecx, [rip + g_lh]
    COLOR r8d, T_CURSOR
    call gfx_fill
    test r15d, r15d
    jz 9f
    lea rdi, [rip + g_face_code]
    mov esi, [rip + g_caret_x]
    mov edx, [rip + g_caret_y]
    add edx, [rip + g_base]
    lea rcx, [rsp + 8]
    mov r8d, r15d
    COLOR r9d, T_BG
    call text_draw
9:  EPILOGUE

# ed_clip_set(ptr, len, linewise0/1) -> accepted write; retain the old cache on failure.
FN ed_clip_set
    xor ecx, ecx
    jmp ed_clip_set_metadata

# Prepared Copy/Cut metadata is borrowed until the accepted platform write returns.
FN ed_clip_set_metadata
    PROLOGUE 32
    mov [rsp], rcx
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    cmp rsi, DOC_MULTI_BYTES_MAX
    ja .Lclip_invalid
    cmp rdx, 1
    ja .Lclip_invalid
    test rdi, rdi
    jnz 1f
    test rsi, rsi
    jnz .Lclip_invalid
1:  call snippet_utf8_valid
    test eax, eax
    jz .Lclip_invalid
    mov rdi, r12
    mov rsi, r13
    call mem_dup_try
    test rax, rax
    jz .Lclip_invalid
    mov rbx, rax
    cmp qword ptr [rip + g_plat + P_clip_write], 0
    je .Lclip_plain
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    mov rcx, [rsp]
    call clip_wire_encode
    test rax, rax
    jz .Lclip_rejected
    mov [rsp + 8], rax
    mov rdi, rax
    mov rsi, rdx
    PCALL P_clip_write
    mov [rsp + 16], rax
    mov rdi, [rsp + 8]
    call mem_free
    mov rax, [rsp + 16]
    jmp .Lclip_written
.Lclip_plain:
    mov rdi, rax
    mov rsi, r13
    PCALL P_clip_set
.Lclip_written:
    test eax, eax
    jz .Lclip_rejected
    call editor_clip_segments_clear
    lea rdi, [rip + clip_sb]
    call sb_free
    mov [rip + clip_sb + SB_ptr], rbx
    mov [rip + clip_sb + SB_len], r13
    lea rax, [r13 + 1]
    mov [rip + clip_sb + SB_cap], rax
    mov [rip + g_clip_line], r14d
    mov eax, 1
    EPILOGUE
.Lclip_rejected:
    mov rdi, rbx
    call mem_free
.Lclip_invalid:
    xor eax, eax
    EPILOGUE

# Copy callers share one failure message and preserve the boolean return value.
FN editor_clip_result
    test eax, eax
    jnz 1f
    jmp editor_clip_failure
1:  mov eax, 1
    ret
FN editor_clip_failure
    lea rdi, [rip + .Lclip_failure]
    call app_toast
    xor eax, eax
    ret

# Exact cache matching does not depend on the whole-line flag.
FN ed_clip_matches
    xor eax, eax
    cmp rsi, [rip + clip_sb + SB_len]
    jne 1f
    test rsi, rsi
    jz 2f
    test rdi, rdi
    jz 1f
    mov rdx, rsi
    mov rsi, [rip + clip_sb + SB_ptr]
    jmp memeq
2:  mov eax, 1
1:  ret

# ed_clip_linewise(ptr, len) -> matching last whole-line copy, permanently invalidated on mismatch.
FN ed_clip_linewise
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call clip_delivery_get
    test rax, rax
    jz 2f
    mov rax, [rax + CWB_line]
    jmp 1f
2:  mov rdi, rbx
    mov rsi, r12
    call ed_clip_observe
    test eax, eax
    jz 1f
    mov eax, [rip + g_clip_line]
1:  EPILOGUE

# blink_elapsed() -> ms since the last caret activity, -1 if no caret blinks (turned off, the last
# frame drew no caret with the keyboard, the window does not have it, BLINK_FOR idle); 0 while the
# mouse button is held (a drag moves the caret)
blink_elapsed:
    cmp dword ptr [rip + cfg_cursor_blink], 0
    je 1f
    cmp dword ptr [rip + g_win_focused], 0
    je 1f
    cmp dword ptr [rip + caret_seen], 0
    je 1f
    call time_ms
    sub rax, [rip + g_blink_t0]
    cmp rax, BLINK_FOR
    ja 1f
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jz 2f
    xor eax, eax
2:  ret
1:  mov rax, -1
    ret

# ed_caret_shown() -> eax 1 when the caret with the keyboard shows now: the window has the keyboard,
#   and the caret is in an even half of its blink or does not blink
FN ed_caret_shown
    xor eax, eax
    cmp dword ptr [rip + g_win_focused], 0
    je 9f
    call ed_blink_phase
    mov ecx, eax
    mov eax, 1
    cmp ecx, -1
    je 9f
    test ecx, 1
    jz 9f
    xor eax, eax
9:  ret

# ed_blink_timeout() -> ms until the caret toggles, -1 if not blinking
FN ed_blink_timeout
    call blink_elapsed
    test rax, rax
    js 1f
    xor edx, edx
    mov ecx, BLINK_MS
    div rcx
    mov eax, BLINK_MS
    sub eax, edx
1:  ret

# ed_blink_phase() -> the half of the blink the caret is in (odd: off), -1 if not blinking
FN ed_blink_phase
    call blink_elapsed
    test rax, rax
    js 1f
    xor edx, edx
    mov ecx, BLINK_MS
    div rcx
1:  ret

# ed_caret_draw(x, y, w, h): a text field's caret with the keyboard (ui_textfield, ui_textarea,
#   vim's command line), in its rect: noted for the blink when any of it is inside the clip (a field
#   scrolled out of view does not blink), and drawn while the blink shows it
FN ed_caret_draw
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov r8d, edi                # across: max(x, the clip's left) below min(x + w, its right)
    mov eax, [rip + g_cv + CV_cx0]
    cmp r8d, eax
    cmovl r8d, eax
    lea r9d, [rdi + rdx]
    mov eax, [rip + g_cv + CV_cx1]
    cmp r9d, eax
    cmovg r9d, eax
    cmp r8d, r9d
    jge 1f
    mov r8d, esi                # and down
    mov eax, [rip + g_cv + CV_cy0]
    cmp r8d, eax
    cmovl r8d, eax
    lea r9d, [rsi + rcx]
    mov eax, [rip + g_cv + CV_cy1]
    cmp r9d, eax
    cmovg r9d, eax
    cmp r8d, r9d
    jge 1f
    mov dword ptr [rip + caret_frame], 1
1:  call ed_caret_shown
    test eax, eax
    jz 9f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    COLOR r8d, T_CURSOR
    call gfx_fill
9:  EPILOGUE

# ed_blink_frame(): the frame is drawn: whether it had a caret to blink
FN ed_blink_frame
    mov eax, [rip + caret_frame]
    mov [rip + caret_seen], eax
    mov dword ptr [rip + caret_frame], 0
    ret

# ed_blink_tick(): a frame each time the caret turns on or off, and when it stops blinking
FN ed_blink_tick
    call ed_blink_phase
    cmp eax, [rip + blink_seen]
    je 1f
    mov [rip + blink_seen], eax
    mov dword ptr [rip + g_dirty], 1
1:  ret

.section .rodata
.Lem1: .asciz "Cut"
.Ldisk_warning: .asciz "Changed on disk. Unsaved edits kept."
.Lem2: .asciz "Copy"
.Lem3: .asciz "Paste"
.Lem4: .asciz "Select All"
.Lem5: .asciz "Toggle Comment"
.Lem6: .asciz "Go to File"
.p2align 3
.globl editor_menu
editor_menu:
    .quad .Lem1, cmd_cut, .Lem2, cmd_copy, .Lem3, cmd_paste, .Lem4, cmd_select_all
    .quad .Lem5, cmd_toggle_comment, .Lem6, cmd_quick_open, 0, 0
.globl pair_open, pair_close
pair_open: .asciz "([{\"'`"
pair_close: .asciz ")]}\"'`"
.Lspace: .ascii " "
.Ltab_arrow: .ascii "\342\206\222"
.Lmiddot: .ascii "\302\267"
.Lbrackets: .asciz "()[]{}"
.Lbc_space: .asciz " "

.text
# ---------------- the widest line (horizontal scrollbar) ----------------

# doc_widest(doc) -> rax columns of its widest line, tabs and wide characters as drawn; measured
#   again when its text or the tab width changed. Past WIDEST_FULL bytes the whole text is measured
#   once editing pauses, and on the frame after its first; meanwhile short lines on screen and the
#   caret can only widen it.
FN doc_widest
    PROLOGUE 16
    mov rbx, rdi
    call doc_len
    mov [rsp], rax
    mov rcx, 0x9e3779b97f4a7c15
    mov rdx, [rbx + DOC_version]
    imul rdx, rcx
    add rdx, [rbx + DOC_nlines]
    imul rdx, rcx
    add rdx, rax
    imul rdx, rcx
    mov eax, [rip + g_tab_width]
    add rdx, rax
    or rdx, 1                   # never 0, the key of a document not measured yet
    cmp rdx, [rbx + DOC_wkey]
    je 8f
    mov [rsp + 8], rdx
    cmp qword ptr [rsp], WIDEST_FULL
    jbe 7f
    # a long text never measured: its first frame takes the lines on screen, the next one all
    cmp qword ptr [rbx + DOC_wkey], 0
    jne 71f
    mov qword ptr [rbx + DOC_wkey], 2  # even: no key of a text
    call time_ms
    mov [rip + widest_due], rax
    jmp 72f
71: call time_ms
    sub rax, [rbx + DOC_lastedit]
    cmp rax, WIDEST_PAUSE
    jae 7f
    mov rax, [rbx + DOC_lastedit]
    add rax, WIDEST_PAUSE
    mov [rip + widest_due], rax
72: call widest_visible
    cmp rax, [rbx + DOC_wcols]
    jbe 8f
    mov [rbx + DOC_wcols], rax
    jmp 8f
7:  mov rdx, [rsp + 8]
    mov [rbx + DOC_wkey], rdx
    mov dword ptr [rip + ww_col], 0
    mov dword ptr [rip + ww_max], 0
    # the gap buffer's two runs of text
    mov rdi, [rbx + DOC_buf]
    mov rsi, [rbx + DOC_gs]
    call widest_span
    mov rdi, [rbx + DOC_buf]
    add rdi, [rbx + DOC_ge]
    mov rsi, [rbx + DOC_cap]
    sub rsi, [rbx + DOC_ge]
    call widest_span
    mov eax, [rip + ww_col]     # the last line has no newline
    cmp eax, [rip + ww_max]
    jae 1f
    mov eax, [rip + ww_max]
1:  mov [rbx + DOC_wcols], rax
8:  mov rax, [rbx + DOC_wcols]
    EPILOGUE

# editor_timeout() -> ms until a long text whose editing paused is measured again (a frame does it),
#   or -1
FN editor_timeout
    push rbx
    call deco_visible_due       # the visible event (deco.s)
    mov ebx, eax
    call present_timeout        # and the providers' requests (present.s)
    cmp eax, -1
    je 6f
    cmp ebx, -1
    je 5f
    cmp eax, ebx
    jge 6f
5:  mov ebx, eax
6:  call hl_timeout             # and the caret's highlights (hicolor.s)
    cmp eax, -1
    je 8f
    cmp ebx, -1
    je 7f
    cmp eax, ebx
    jge 8f
7:  mov ebx, eax
8:  call ghost_timeout          # and inline completion's pause (ghost.s)
    cmp eax, -1
    je 4f
    cmp ebx, -1
    je 3f
    cmp eax, ebx
    jge 4f
3:  mov ebx, eax
4:  mov rax, [rip + widest_due]
    test rax, rax
    jz 1f
    call time_ms
    mov rcx, [rip + widest_due]
    sub rcx, rax
    xor eax, eax
    test rcx, rcx
    cmovg eax, ecx
    cmp ebx, -1
    je 2f
    cmp eax, ebx
    jle 2f
1:  mov eax, ebx
2:  pop rbx
    ret

# editor_tick(): the frame that measures it
FN editor_tick
    sub rsp, 8
    call deco_visible_tick
    call present_tick           # the providers' requests that are due (present.s)
    call hl_tick                # the caret's highlights (hicolor.s)
    call ghost_tick             # inline completion (ghost.s)
    add rsp, 8
    cmp qword ptr [rip + widest_due], 0
    je 1f
    sub rsp, 8
    call time_ms
    add rsp, 8
    cmp rax, [rip + widest_due]
    jb 1f
    mov qword ptr [rip + widest_due], 0
    mov dword ptr [rip + g_dirty], 1
1:  ret

# widest_visible() -> rax columns of the widest measured line on screen (rbx doc).
# Long lines retain their cached extent until the pause: measuring even one whole minified line
# would scan megabytes on every edit. All lines measured in this frame share a byte budget.
widest_visible:
    PROLOGUE 16
    mov qword ptr [rsp], WIDEST_VISIBLE
    xor r14d, r14d
    mov r12, [rbx + DOC_scrolly]
    sar r12, 8                  # first line
    jns 1f
    xor r12d, r12d
1:  mov eax, [rip + g_ed_h]
    xor edx, edx
    mov ecx, [rip + g_lh]
    test ecx, ecx
    jz 9f
    div ecx
    lea r13, [r12 + rax + 2]    # past the last
    cmp r13, [rbx + DOC_nlines]
    jbe 2f
    mov r13, [rbx + DOC_nlines]
2:
3:  cmp r12, r13
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov r15, rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    mov rcx, rax
    sub rcx, r15
    cmp rcx, [rsp]
    ja 4f
    sub [rsp], rcx
    mov rdi, rbx
    mov rsi, rax
    call doc_col_of
    cmp eax, r14d
    cmova r14d, eax
4:  inc r12
    jmp 3b
9:  mov eax, r14d
    EPILOGUE

# widest_span(ptr, len): ww_col and ww_max through these bytes (as doc_col_of counts columns)
widest_span:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rdi + rsi]
    mov r13d, [rip + ww_col]
    mov r14d, [rip + ww_max]
    mov r15d, [rip + g_tab_width]
    test r15d, r15d
    jnz 1f
    mov r15d, 1
1:  cmp rbx, r12
    jae 9f
    movzx eax, byte ptr [rbx]
    cmp eax, 10
    je 3f
    cmp eax, 9
    je 4f
    cmp eax, 0x80
    jae 5f
    inc r13d
    inc rbx
    jmp 1b
3:  cmp r13d, r14d
    cmova r14d, r13d
    xor r13d, r13d
    inc rbx
    jmp 1b
4:  mov eax, r13d
    xor edx, edx
    div r15d
    mov eax, r15d
    sub eax, edx
    add r13d, eax
    inc rbx
    jmp 1b
5:  mov rdi, rbx
    mov rsi, r12
    sub rsi, rbx
    call utf8_decode
    test rdx, rdx
    jnz 6f
    mov edx, 1
6:  add rbx, rdx
    mov edi, eax
    call cp_width
    add r13d, eax
    jmp 1b
9:  mov [rip + ww_col], r13d
    mov [rip + ww_max], r14d
    EPILOGUE

# hscroll_measure(gutter w): hs_on, hs_content, hs_view for the active document: the widest line and
#   a margin against the text area, when lines do not wrap (rbx doc)
hscroll_measure:
    PROLOGUE
    mov r12d, edi
    mov dword ptr [rip + hs_on], 0
    mov dword ptr [rip + hs_content], 0
    mov eax, [rip + g_ed_w]
    sub eax, r12d
    mov [rip + hs_view], eax
    cmp dword ptr [rip + cfg_word_wrap], 0
    jne 9f
    mov rax, [rip + g_deco_gen]     # the widest inlays are measured again per document and when
    mov rcx, [rbx + DOC_pres]       # what it shows changes (presentation)
    test rcx, rcx
    jz 0f
    add rax, [rcx + PRS_gen]
0:  cmp rbx, [rip + vt_wide_doc]
    jne 2f
    cmp rax, [rip + vt_wide_gen]
    je 1f
2:  mov [rip + vt_wide_doc], rbx
    mov [rip + vt_wide_gen], rax
    mov dword ptr [rip + g_vt_widest], 0
1:  mov rdi, rbx
    call doc_widest
    mov ecx, [rip + g_vt_widest]
    add rax, rcx
    call hscroll_extent
9:  EPILOGUE

# hscroll_extent(columns): update the track's content width from a measured width or caret column.
# rax is the column count; hs_view was set by hscroll_measure for this frame.
hscroll_extent:
    mov ecx, [rip + g_cw]
    imul rax, rcx
    mov ecx, [rip + g_mt + 4*MI_32]     # as reveal keeps the caret off the edge
    add rax, rcx
    mov ecx, 0x3fffffff                 # pixels stay positive in 32 bits however long the line
    cmp rax, rcx
    cmova rax, rcx
    mov [rip + hs_content], eax
    cmp eax, [rip + hs_view]
    setg al
    movzx eax, al
    mov [rip + hs_on], eax
    ret

# hscroll_clamp(): the view goes no further right than the widest line (rbx doc); not while that
#   width is the first frame's guess (doc_widest), which would undo a view a reopened tab restored
hscroll_clamp:
    cmp qword ptr [rbx + DOC_wkey], 2
    je 2f
    mov eax, [rip + hs_content]
    sub eax, [rip + hs_view]
    jns 1f
    xor eax, eax
1:  cmp dword ptr [rip + cfg_word_wrap], 0
    jne 2f
    movsxd rax, eax
    cmp [rbx + DOC_scrollx], rax
    jle 2f
    mov [rbx + DOC_scrollx], rax
2:  ret

# editor_scroll_dump(sb): "x=PX y=N max=PX track=X,Y,W,H", the active document's scroll, y in
#   1/256 lines (print-scroll; max 0 and no track without the horizontal scrollbar)
FN editor_scroll_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lsd_x]
    call sb_push_cstr
    xor esi, esi
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    mov rsi, [rax + DOC_scrollx]
1:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lsd_y]
    call sb_push_cstr
    xor esi, esi
    mov rax, [rip + g_doc]
    test rax, rax
    jz 4f
    mov rsi, [rax + DOC_scrolly]
4:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lsd_max]
    call sb_push_cstr
    xor esi, esi
    cmp dword ptr [rip + hs_on], 0
    je 2f
    mov esi, [rip + hs_content]
    sub esi, [rip + hs_view]
2:  mov rdi, rbx
    call sb_push_u64
    cmp dword ptr [rip + hs_on], 0
    je 9f
    mov rdi, rbx
    lea rsi, [rip + .Lsd_track]
    call sb_push_cstr
    xor r12d, r12d
3:  lea rax, [rip + hs_track]
    mov esi, [rax + r12*4]
    mov rdi, rbx
    call sb_push_u64
    inc r12d
    cmp r12d, 4
    jae 9f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    jmp 3b
9:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Lsd_x: .asciz "x="
.Lsd_y: .asciz " y="
.Lsd_max: .asciz " max="
.Lsd_track: .asciz " track="
.text

.data
dl_to: .long -1
.p2align 3
g_br: .quad -1, -1
.globl g_br_doc
g_br_doc: .quad 0               # what g_br was found for: doc (0: nothing), version, caret, anchor, setting
br_ver: .quad 0
br_set: .quad 0                 # the bracket pairs of the document matched (lc_bracket_str)
br_cur: .quad 0
br_anchor: .quad 0
br_on: .long 0
.bss
.p2align 3
disk_edge: .long 0
disk_tint: .long 0
last_indent: .long 0
.globl g_ed_x, g_ed_y, g_ed_w, g_ed_h, g_ed_tx
.globl g_caret_x, g_caret_y, g_caret_ok
g_caret_x: .long 0
g_caret_y: .long 0
g_caret_ok: .long 0
dl_from: .long 0
.globl dl_last                  # editorsel.s draws the other selections on draw_line's row
dl_last: .long 0
.p2align 3
cls_doc: .quad 0
cls_line: .quad 0
cls_ver: .quad 0
cls_svalid: .quad 0
cls_ptr: .quad 0                # the classes of the line being drawn: classes', or long_cls's
.globl g_long_doc
g_long_doc: .quad 0             # a long line's classes, kept across frames: its doc (0: none), and
long_line: .quad 0              # what they depend on
long_len: .quad 0
long_ver: .quad 0
long_svalid: .quad 0
long_lang: .quad 0
long_cls: .zero SB_SIZE
.p2align 3
vt_wide_doc: .quad 0            # the document g_vt_widest was measured on
vt_wide_gen: .quad 0            # and what it showed (g_deco_gen + PRS_gen)
.globl g_clip_line, g_mods
g_clip_line: .long 0
g_mods: .long 0
# the row draw_line is drawing, for the presentation layers (deco.s)
.p2align 3
.globl g_row_doc, g_row_line, g_row_lstart, g_row_text, g_row_len, g_row_from, g_row_to
.globl g_row_x, g_row_y
g_row_doc: .quad 0
g_row_line: .quad 0
g_row_lstart: .quad 0           # the line's start position
g_row_text: .quad 0             # the line's text and length
g_row_len: .quad 0
g_row_from: .quad 0             # the row's bytes [from, to) of the line
g_row_to: .quad 0
g_row_x: .long 0                # x of the line's column 0
g_row_y: .long 0

.section .rodata
.Lclip_failure: .asciz "Could not copy to the clipboard."
