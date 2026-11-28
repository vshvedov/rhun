# log views (feature view-log): append-only lines with a severity and SGR colors, kept in a ring of
# the last 10000 lines and 4 MB, following the tail; find, line selection and copy. A log is drawn
# in the editor's monospaced face; only the lines in view are drawn. Lines are numbered from the
# first ever appended, so the cursor and the selection stay on their lines as old ones drop.
.include "rhun.inc"

.equ LOG_LINES, 10000
.equ LOG_BYTES, 4194304
.equ ID_LOG, 0x5c0000            # + slot << 8: a log's ui ids (+0 body, +1 scrollbar, +2 find)

# a line
STRUCT
F LL_ptr, 8             # owned: its text, control characters gone but SGR sequences kept
F LL_len, 4
F LL_sev, 4             # LS_*
ENDSTRUCT LL_SIZE
.equ LS_NONE, 0
.equ LS_TRACE, 1
.equ LS_DEBUG, 2
.equ LS_INFO, 3
.equ LS_WARN, 4
.equ LS_ERROR, 5

# a log
STRUCT
F LG_ring, 8            # LL * LOG_LINES, allocated with the first line
F LG_seq, 8             # lines ever appended: line k is ring[k % LOG_LINES] while k >= seq - count
F LG_count, 8
F LG_bytes, 8
F LG_dropped, 8         # lines dropped to keep the limits
F LG_scroll, 4          # pixels
F LG_follow, 4          # 1: the view stays on the last line
F LG_cur, 8             # the cursor's line (absolute), -1
F LG_anchor, 8          # the selection's other end, -1 when only the cursor is selected
F LG_find, TF_SIZE      # the find field
F LG_findopen, 4
F LG_slot, 4            # its instance (ui ids)
F LG_match, 8           # the line of the current match, -1
F LG_rect, 16           # where its lines were last drawn
F LG_drag, 4
F LG_pad, 4
F LG_face, 8            # the face its lines are drawn in, 0: the editor's monospaced face
ENDSTRUCT LG_SIZE

.bss
.p2align 3
lg_tmp: .zero SB_SIZE           # a line being cleaned, the copied lines
lg_face: .quad 0                # the face of the log being drawn or keyed (lg_use)
lg_find_tmp: .zero SB_SIZE      # a line without its SGR sequences, for find

.text

# log_new(slot) -> LG*
FN log_new
    push rbx
    mov ebx, edi
    mov edi, LG_SIZE
    call mem_alloc
    mov [rax + LG_slot], ebx
    mov dword ptr [rax + LG_follow], 1
    mov qword ptr [rax + LG_face], 0
    mov qword ptr [rax + LG_cur], -1
    mov qword ptr [rax + LG_anchor], -1
    mov qword ptr [rax + LG_match], -1
    pop rbx
    ret

# log_set_face(LG*, FACE*): its lines in that face (the terminal's, for the Debug Console and Test
#   Results), 0 the editor's monospaced one
FN log_set_face
    mov [rdi + LG_face], rsi
    mov dword ptr [rip + g_dirty], 1
    ret

# lg_use(rdi = LG*): lg_face is the log's face (keeps every register but rax)
lg_use:
    mov rax, [rdi + LG_face]
    test rax, rax
    jnz 1f
    lea rax, [rip + g_face_code]
1:  mov [rip + lg_face], rax
    ret

# log_drop_last(LG*): its newest line goes (a line still growing is put back with log_append)
FN log_drop_last
    push rbx
    mov rbx, rdi
    cmp qword ptr [rbx + LG_count], 0
    je 9f
    mov rsi, [rbx + LG_seq]
    dec rsi
    call line_at
    mov ecx, [rax + LL_len]
    sub [rbx + LG_bytes], rcx
    mov rdi, [rax + LL_ptr]
    mov qword ptr [rax + LL_ptr], 0
    call mem_free
    dec qword ptr [rbx + LG_seq]
    dec qword ptr [rbx + LG_count]
    mov dword ptr [rip + g_dirty], 1
9:  pop rbx
    ret

# log_print_rect(LG*, sb, label cstr): "LABEL X Y W H" and a newline: where its lines were last drawn
FN log_print_rect
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    mov rsi, rdx
    call sb_push_cstr
    xor r13d, r13d
1:  mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rdi, r12
    movsxd rsi, dword ptr [rbx + LG_rect + r13*4]
    call sb_push_u64
    inc r13
    cmp r13, 4
    jb 1b
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# log_clear(LG*): no lines (the numbering goes on)
FN log_clear
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
1:  cmp qword ptr [rbx + LG_count], 0
    je 2f
    mov rdi, rbx
    call drop_oldest
    jmp 1b
2:  mov qword ptr [rbx + LG_dropped], 0
    mov dword ptr [rbx + LG_scroll], 0
    mov dword ptr [rbx + LG_follow], 1
    mov qword ptr [rbx + LG_cur], -1
    mov qword ptr [rbx + LG_anchor], -1
    mov qword ptr [rbx + LG_match], -1
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# log_free(LG*)
FN log_free
    push rbx
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    call log_clear
    mov rdi, [rbx + LG_ring]
    call mem_free
    lea rdi, [rbx + LG_find + TF_sb]
    call sb_free
    mov rdi, rbx
    call mem_free
9:  pop rbx
    ret

# line_at(LG*, k) -> rax LL* of absolute line k (assumed kept)
line_at:
    mov rax, rsi
    xor edx, edx
    mov ecx, LOG_LINES
    div rcx
    imul rax, rdx, LL_SIZE
    add rax, [rdi + LG_ring]
    ret

# first_line(LG*) -> rax the absolute number of the oldest line kept
first_line:
    mov rax, [rdi + LG_seq]
    sub rax, [rdi + LG_count]
    ret

# drop_oldest(LG*)
drop_oldest:
    push rbx
    mov rbx, rdi
    call first_line
    mov rsi, rax
    mov rdi, rbx
    call line_at
    mov ecx, [rax + LL_len]
    sub [rbx + LG_bytes], rcx
    mov rdi, [rax + LL_ptr]
    mov qword ptr [rax + LL_ptr], 0
    call mem_free
    dec qword ptr [rbx + LG_count]
    inc qword ptr [rbx + LG_dropped]
    pop rbx
    ret

# log_append(LG*, sev, ptr, len): one line, cleaned: tabs as spaces, SGR sequences kept, other
#   escapes and control characters dropped; old lines drop past the limits
FN log_append
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp qword ptr [rbx + LG_ring], 0
    jne 1f
    mov edi, LL_SIZE * LOG_LINES
    call mem_alloc
    mov [rbx + LG_ring], rax
1:  lea rdi, [rip + lg_tmp]
    call sb_clear
    xor r15d, r15d
2:  cmp r15, r14
    jae 6f
    movzx eax, byte ptr [r13 + r15]
    cmp eax, 27
    je 3f
    cmp eax, 9
    je 21f
    cmp eax, 0x20
    jb 5f
    cmp eax, 0x7f
    je 5f
    lea rdi, [rip + lg_tmp]
    mov esi, eax
    call sb_push_byte
    jmp 5f
21: lea rdi, [rip + lg_tmp]     # a tab: spaces to the next stop of 4
    mov esi, ' '
    call sb_push_byte
    test qword ptr [rip + lg_tmp + SB_len], 3
    jnz 21b
    jmp 5f
3:  # ESC [ digits ; ... m is kept; any other escape goes with its sequence
    lea rcx, [r15 + 1]
    cmp rcx, r14
    jae 6f
    cmp byte ptr [r13 + rcx], ']'
    jne 39f
35: inc rcx                     # OSC: up to BEL or ESC backslash
    cmp rcx, r14
    jae 6f
    cmp byte ptr [r13 + rcx], 7
    je 34f
    cmp byte ptr [r13 + rcx], 27
    jne 35b
    inc rcx
    jmp 34f
39: cmp byte ptr [r13 + rcx], '['
    jne 4f
    inc rcx
31: cmp rcx, r14
    jae 6f
    movzx eax, byte ptr [r13 + rcx]
    cmp eax, ';'
    je 32f
    lea edx, [rax - '0']
    cmp edx, 9
    jbe 32f
    cmp eax, 'm'
    je 33f
    cmp eax, 0x40               # a final byte of another sequence: dropped
    jae 34f
32: inc rcx
    jmp 31b
33: lea rdx, [rcx + 1]
    sub rdx, r15
    lea rsi, [r13 + r15]
    lea rdi, [rip + lg_tmp]
    push rcx
    push rcx
    call sb_push
    pop rcx
    pop rcx
34: mov r15, rcx
    jmp 5f
4:  mov r15, rcx                # ESC and the next byte
5:  inc r15
    jmp 2b
6:  # room: the count and the bytes
    mov rax, [rip + lg_tmp + SB_len]
    add rax, [rbx + LG_bytes]
    cmp rax, LOG_BYTES
    jbe 7f
    cmp qword ptr [rbx + LG_count], 0
    je 7f
    mov rdi, rbx
    call drop_oldest
    jmp 6b
7:  cmp qword ptr [rbx + LG_count], LOG_LINES
    jb 8f
    mov rdi, rbx
    call drop_oldest
    jmp 7b
8:  mov rdi, [rip + lg_tmp + SB_ptr]
    mov rsi, [rip + lg_tmp + SB_len]
    test rdi, rdi
    jnz 81f
    lea rdi, [rip + .Lempty]
81: call mem_dup
    mov r15, rax
    mov rdi, rbx
    mov rsi, [rbx + LG_seq]
    call line_at
    mov [rax + LL_ptr], r15
    mov rcx, [rip + lg_tmp + SB_len]
    mov [rax + LL_len], ecx
    mov [rax + LL_sev], r12d
    add [rbx + LG_bytes], rcx
    inc qword ptr [rbx + LG_seq]
    inc qword ptr [rbx + LG_count]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# log_sev_word(ptr, len) -> eax LS_* + 1, 0 when the word is not a severity
FN log_sev_word
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  lea rax, [rip + sev_words]
    mov rdx, [rax + rbx*8]
    test rdx, rdx
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc ebx
    jmp 1b
2:  lea eax, [rbx + 1]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- drawing ----------------

# row_h() -> eax a line's height
row_h:
    mov rax, [rip + lg_face]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_mt + 4*MI_2]
    ret

# rows(LG*) -> rax rows drawn: the lines, and one saying how many dropped
rows:
    mov rax, [rdi + LG_count]
    cmp qword ptr [rdi + LG_dropped], 0
    je 1f
    inc rax
1:  ret

# log_draw(LG*, x, y, w, h, focused): the find field when open, the lines in view, the scrollbar;
#   clicks and drags select lines, the wheel scrolls (and stops following until End)
FN log_draw
    PROLOGUE 80
    call lg_use
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov [rsp + 16], r9d
    mov eax, [rbx + LG_slot]
    shl eax, 8
    add eax, ID_LOG
    mov [rsp + 20], eax         # ids
    # the find field over the lines
    cmp dword ptr [rbx + LG_findopen], 0
    je 1f
    lea rax, [rip + .Lfind_ph]
    push rax
    push rax
    lea rdi, [rbx + LG_find]
    mov esi, [rsp + 16]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 16 + 4]
    add edx, [rip + g_mt + 4*MI_2]
    mov ecx, [rsp + 16 + 8]
    sub ecx, [rip + g_mt + 4*MI_32]
    M r8d, MI_24
    mov r9d, [rsp + 16 + 16]
    call ui_textfield
    add rsp, 16
    M eax, MI_28
    add [rsp + 4], eax
    sub [rsp + 12], eax
1:  mov eax, [rsp]
    mov [rbx + LG_rect], eax
    mov eax, [rsp + 4]
    mov [rbx + LG_rect + 4], eax
    mov eax, [rsp + 8]
    mov [rbx + LG_rect + 8], eax
    mov eax, [rsp + 12]
    mov [rbx + LG_rect + 12], eax
    call row_h
    mov r12d, eax
    mov rdi, rbx
    call rows
    imul eax, r12d
    mov [rsp + 24], eax         # content height
    # the wheel stops following; following keeps the end in view
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call ui_in
    test eax, eax
    jz 2f
    mov eax, [rip + g_scroll_y]
    test eax, eax
    jz 2f
    add [rbx + LG_scroll], eax
    mov dword ptr [rbx + LG_follow], 0
2:  mov eax, [rsp + 24]
    sub eax, [rsp + 12]
    jns 21f
    xor eax, eax
21: cmp dword ptr [rbx + LG_follow], 0
    je 22f
    mov [rbx + LG_scroll], eax
22: cmp [rbx + LG_scroll], eax
    jl 23f
    mov [rbx + LG_scroll], eax
    mov dword ptr [rbx + LG_follow], 1     # at the end again: it follows
23: cmp dword ptr [rbx + LG_scroll], 0
    jge 24f
    mov dword ptr [rbx + LG_scroll], 0
24: # the pointer: a press selects a line (Shift extends), a drag extends
    mov edi, [rsp + 20]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_12]
    mov r8d, [rsp + 12]
    call ui_btn
    mov [rsp + 28], eax
    test eax, UB_HELD
    jz 3f
    mov eax, [rip + g_my]       # the row under the pointer
    sub eax, [rsp + 4]
    add eax, [rbx + LG_scroll]
    test eax, eax
    jns 25f
    xor eax, eax
25: xor edx, edx
    div r12d
    mov r13d, eax
    mov rdi, rbx
    call rows
    test rax, rax
    jz 3f
    dec rax
    cmp r13, rax
    jbe 251f
    mov r13, rax
251:mov rax, r13
26: cmp qword ptr [rbx + LG_dropped], 0
    je 27f
    test rax, rax
    jz 3f                       # the dropped-lines row
    dec rax
27: mov r13, rax
    mov rdi, rbx
    call first_line
    add r13, rax
    test dword ptr [rsp + 28], UB_PRESS
    jz 28f
    mov qword ptr [rbx + LG_anchor], -1
    test dword ptr [rip + g_mods], MOD_SHIFT
    jz 29f
28: cmp qword ptr [rbx + LG_anchor], -1
    jne 29f
    mov rax, [rbx + LG_cur]
    cmp r13, rax
    je 29f
    mov [rbx + LG_anchor], rax
29: mov [rbx + LG_cur], r13
    mov dword ptr [rip + g_dirty], 1
3:  # the rows in view
    mov eax, [rbx + LG_scroll]
    xor edx, edx
    div r12d
    mov r13d, eax               # first row
    imul eax, r12d
    mov r14d, [rsp + 4]
    add r14d, eax
    sub r14d, [rbx + LG_scroll] # its y
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_clip_push
.Lld_row:
    mov rdi, rbx
    call rows
    cmp r13, rax
    jae .Lld_done
    mov eax, [rsp + 4]
    add eax, [rsp + 12]
    cmp r14d, eax
    jge .Lld_done
    mov rax, r13
    cmp qword ptr [rbx + LG_dropped], 0
    je 4f
    test rax, rax
    jnz 41f
    mov rdi, rbx                # "N earlier lines dropped"
    mov esi, r14d
    lea rdx, [rsp]
    call dropped_row
    jmp .Lld_next
41: dec rax
4:  mov r15, rax
    mov rdi, rbx
    call first_line
    add r15, rax                # the absolute line
    mov rdi, rbx
    mov rsi, r15
    mov edx, r14d
    lea rcx, [rsp]
    call draw_line
.Lld_next:
    add r14d, r12d
    inc r13
    jmp .Lld_row
.Lld_done:
    call gfx_clip_pop
    mov eax, [rsp + 12]
    push rax
    mov eax, [rsp + 8 + 24]
    push rax
    mov edi, [rsp + 16 + 20]
    inc edi
    mov esi, [rsp + 16]
    add esi, [rsp + 16 + 8]
    M eax, MI_12
    sub esi, eax
    mov edx, [rsp + 16 + 4]
    mov ecx, eax
    mov r8d, [rsp + 16 + 12]
    lea r9, [rbx + LG_scroll]
    call ui_scrollbar
    add rsp, 16
    mov eax, [rip + g_active]   # dragging the thumb away from the end stops following
    mov ecx, [rsp + 20]
    inc ecx
    cmp eax, ecx
    jne 9f
    mov dword ptr [rbx + LG_follow], 0
9:  EPILOGUE

# dropped_row(LG*, y, frame*): the first row, when lines dropped
dropped_row:
    PROLOGUE 48
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    lea rdi, [rsp]
    mov rsi, [rbx + LG_dropped]
    call fmt_u64
    lea rdi, [rsp + rax]
    lea rsi, [rip + .Ldropped]
    call cstr_copy
    call row_h
    mov ecx, eax
    lea rdi, [rip + g_face_small]
    mov esi, [r13]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, r12d
    lea r8, [rsp]
    COLOR r9d, T_MUTED
    call ui_text_c
    EPILOGUE

# draw_line(LG*, k, y, frame*): line k: the selection behind it, then its text in its severity's
#   color with SGR colors applied, the current find match's line marked
draw_line:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r15, rcx
    # selected: between the anchor and the cursor (or the cursor alone)
    mov rax, [rbx + LG_cur]
    mov rcx, [rbx + LG_anchor]
    cmp rcx, -1
    jne 1f
    mov rcx, rax
1:  cmp rax, rcx
    jle 2f
    xchg rax, rcx
2:  cmp r12, rax
    jl 3f
    cmp r12, rcx
    jg 3f
    cmp qword ptr [rbx + LG_cur], -1
    je 3f
    call row_h
    mov ecx, eax
    mov edi, [r15]
    mov esi, r13d
    mov edx, [r15 + 8]
    COLOR r8d, T_SELECTION
    call gfx_fill
3:  cmp r12, [rbx + LG_match]
    jne 4f
    call row_h
    mov ecx, eax
    mov edi, [r15]
    mov esi, r13d
    M edx, MI_3
    COLOR r8d, T_ACCENT
    call gfx_fill
4:  mov rdi, rbx
    mov rsi, r12
    call line_at
    mov r14, rax
    mov eax, [r14 + LL_sev]
    lea rcx, [rip + sev_colors]
    mov eax, [rcx + rax*4]
    lea rcx, [rip + g_theme]
    mov eax, [rcx + rax*4]
    mov [rsp], eax              # the base color
    mov [rsp + 4], eax          # the current color
    mov eax, [r15]
    add eax, [rip + g_mt + 4*MI_8]
    mov [rsp + 8], eax          # x
    call row_h
    mov rcx, [rip + lg_face]
    sub eax, [rcx + FACE_ascent]
    sub eax, [rcx + FACE_descent]
    sar eax, 1
    add eax, r13d
    add eax, [rcx + FACE_ascent]
    mov [rsp + 12], eax         # baseline
    mov r12, [r14 + LL_ptr]
    mov r13d, [r14 + LL_len]
    xor ebx, ebx                # the segment's start
    xor ecx, ecx
5:  cmp ecx, r13d
    jae 8f
    cmp byte ptr [r12 + rcx], 27
    je 6f
    inc ecx
    jmp 5b
6:  mov [rsp + 16], ecx
    mov edx, ecx                # the text before the sequence
    sub edx, ebx
    call seg
    mov ecx, [rsp + 16]
    add ecx, 2                  # ESC [
    xor edx, edx                # the number being read
61: cmp ecx, r13d
    jae 8f
    movzx eax, byte ptr [r12 + rcx]
    inc ecx
    cmp eax, ';'
    je 62f
    cmp eax, 'm'
    je 62f
    sub eax, '0'
    imul edx, edx, 10
    add edx, eax
    jmp 61b
62: push rax
    push rcx
    mov edi, edx
    call sgr
    pop rcx
    pop rax
    xor edx, edx
    cmp eax, 'm'
    jne 61b
    mov ebx, ecx
    jmp 5b
8:  mov edx, r13d
    sub edx, ebx
    call seg
    EPILOGUE

# seg(): edx bytes from ebx of the line (draw_line's frame) in the current color
seg:
    test edx, edx
    jle 9f
    push rcx
    push rcx
    mov rdi, [rip + lg_face]
    mov esi, [rsp + 16 + 8 + 8]
    lea rcx, [r12 + rbx]
    mov r8d, edx
    mov r9d, [rsp + 16 + 8 + 4]
    mov edx, [rsp + 16 + 8 + 12]
    call text_draw
    mov [rsp + 16 + 8 + 8], eax
    pop rcx
    pop rcx
9:  ret

# sgr(n): one SGR parameter on the current color (draw_line's frame: it pushes two words first)
sgr:
    test edi, edi
    jz 1f
    cmp edi, 39
    je 1f
    cmp edi, 30
    jb 9f
    cmp edi, 37
    jbe 2f
    cmp edi, 90
    jb 9f
    cmp edi, 97
    ja 9f
    sub edi, 90 - 8 - 30        # bright: terminal colors 8..15
2:  sub edi, 30
    lea rax, [rip + g_theme]
    mov eax, [rax + rdi*4 + 4*T_TERM]
    mov [rsp + 8 + 16 + 4], eax # draw_line's current color (past the return and its two pushes)
    ret
1:  mov eax, [rsp + 8 + 16]     # its base color
    mov [rsp + 8 + 16 + 4], eax
9:  ret

# ---------------- keys ----------------

# log_key(LG*, keysym, cp, mods) -> eax 1 when taken: lines with the arrows (Shift extends),
#   Page Up/Down, Home, End (follows again), Ctrl+F the find field (Enter, F3 next, Shift+Enter
#   previous, Escape closes it), Ctrl+C copies the selected lines
FN log_key
    PROLOGUE 16
    call lg_use
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    cmp dword ptr [rbx + LG_findopen], 0
    je 1f
    cmp r12d, KEY_ESCAPE
    jne 101f
    mov dword ptr [rbx + LG_findopen], 0
    jmp .Llk_yes
101:cmp r12d, KEY_RETURN
    je 102f
    cmp r12d, KEY_F1 + 2        # F3
    jne 103f
102:mov rdi, rbx
    mov esi, 1
    test r14d, MOD_SHIFT
    jz 104f
    mov esi, -1
104:call log_find_next
    jmp .Llk_yes
103:lea rdi, [rbx + LG_find]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
    test eax, eax
    jnz .Llk_yes
1:  test r14d, MOD_CTRL
    jz 2f
    cmp r13d, 'f'
    jne 11f
    mov dword ptr [rbx + LG_findopen], 1
    lea rdi, [rbx + LG_find]
    call tf_select_all
    jmp .Llk_yes
11: cmp r13d, 'c'
    jne .Llk_no
    mov rdi, rbx
    call log_copy
    jmp .Llk_yes
2:  cmp r12d, KEY_F1 + 2
    jne 21f
    mov rdi, rbx
    mov esi, 1
    test r14d, MOD_SHIFT
    jz 20f
    mov esi, -1
20: call log_find_next
    jmp .Llk_yes
21: mov rax, [rbx + LG_cur]
    cmp rax, -1
    jne 22f
    mov rdi, rbx                # no cursor yet: the last line
    mov rax, [rbx + LG_seq]
    dec rax
22: mov r15, rax
    cmp r12d, KEY_UP
    jne 3f
    dec r15
    jmp .Llk_move
3:  cmp r12d, KEY_DOWN
    jne 4f
    inc r15
    jmp .Llk_move
4:  cmp r12d, KEY_PAGEUP
    jne 5f
    call page
    sub r15, rax
    jmp .Llk_move
5:  cmp r12d, KEY_PAGEDOWN
    jne 6f
    call page
    add r15, rax
    jmp .Llk_move
6:  cmp r12d, KEY_HOME
    jne 7f
    mov rdi, rbx
    call first_line
    mov r15, rax
    mov dword ptr [rbx + LG_follow], 0
    jmp .Llk_move
7:  cmp r12d, KEY_END
    jne .Llk_no
    mov r15, [rbx + LG_seq]
    dec r15
    mov dword ptr [rbx + LG_follow], 1
    jmp .Llk_move
.Llk_move:
    mov rdi, rbx
    call first_line
    cmp r15, rax
    jge 81f
    mov r15, rax
81: mov rax, [rbx + LG_seq]
    dec rax
    cmp r15, rax
    jle 82f
    mov r15, rax
82: test r14d, MOD_SHIFT
    jz 83f
    cmp qword ptr [rbx + LG_anchor], -1
    jne 84f
    mov rax, [rbx + LG_cur]
    mov [rbx + LG_anchor], rax
    jmp 84f
83: mov qword ptr [rbx + LG_anchor], -1
84: mov [rbx + LG_cur], r15
    mov rdi, rbx
    mov rsi, r15
    call scroll_to
.Llk_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Llk_no:
    xor eax, eax
    EPILOGUE

# page() -> rax lines in the last drawn rectangle, at least 1 (rbx the log)
page:
    call row_h
    mov ecx, eax
    mov eax, [rbx + LG_rect + 12]
    xor edx, edx
    div ecx
    cmp eax, 1
    jge 1f
    mov eax, 1
1:  ret

# scroll_to(LG*, k): line k in view (following stops unless it is the last line)
scroll_to:
    push rbx
    mov rbx, rdi
    call first_line
    sub rsi, rax
    cmp qword ptr [rbx + LG_dropped], 0
    je 1f
    inc rsi
1:  call row_h
    imul esi, eax
    mov ecx, eax
    cmp esi, [rbx + LG_scroll]
    jge 2f
    mov [rbx + LG_scroll], esi
    mov dword ptr [rbx + LG_follow], 0
    jmp 9f
2:  add esi, ecx
    sub esi, [rbx + LG_rect + 12]
    cmp esi, [rbx + LG_scroll]
    jle 9f
    mov [rbx + LG_scroll], esi
9:  pop rbx
    ret

# log_find_next(LG*, dir): the next (1) or previous (-1) line holding the find text, from the
#   current match (or the cursor), wrapping; it becomes the cursor's line, in view
FN log_find_next
    PROLOGUE 16
    call lg_use
    mov rbx, rdi
    mov r12d, esi
    cmp qword ptr [rbx + LG_count], 0
    je 9f
    cmp qword ptr [rbx + LG_find + TF_sb + SB_len], 0
    je 9f
    mov r13, [rbx + LG_match]
    cmp r13, -1
    jne 1f
    mov r13, [rbx + LG_cur]
    cmp r13, -1
    jne 1f
    mov r13, [rbx + LG_seq]
1:  mov r14, [rbx + LG_count]   # lines to try
2:  test r14, r14
    jz 9f
    dec r14
    movsxd rax, r12d
    add r13, rax
    mov rdi, rbx
    call first_line
    cmp r13, rax
    jge 3f
    mov r13, [rbx + LG_seq]
    dec r13
3:  cmp r13, [rbx + LG_seq]
    jl 4f
    mov r13, rax
4:  mov rdi, rbx
    mov rsi, r13
    call line_at
    mov rdi, [rax + LL_ptr]     # the text shown: its SGR sequences left out
    mov esi, [rax + LL_len]
    lea rdx, [rip + lg_find_tmp]
    call strip_sgr
    mov rdi, [rip + lg_find_tmp + SB_ptr]
    mov rsi, [rip + lg_find_tmp + SB_len]
    mov rdx, [rbx + LG_find + TF_sb + SB_ptr]
    mov rcx, [rbx + LG_find + TF_sb + SB_len]
    call str_ifind
    test rax, rax
    js 2b
    mov [rbx + LG_match], r13
    mov [rbx + LG_cur], r13
    mov qword ptr [rbx + LG_anchor], -1
    mov rdi, rbx
    mov rsi, r13
    call scroll_to
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# strip_sgr(ptr, len, sb): the text without its SGR sequences into the buffer (cleared first)
strip_sgr:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, r14
    call sb_clear
    xor ebx, ebx
1:  cmp rbx, r13
    jae 9f
    movzx eax, byte ptr [r12 + rbx]
    cmp eax, 27
    jne 3f
2:  inc rbx                     # up to its m
    cmp rbx, r13
    jae 9f
    cmp byte ptr [r12 + rbx], 'm'
    jne 2b
    inc rbx
    jmp 1b
3:  mov rcx, rbx                # a stretch without ESC
4:  inc rcx
    cmp rcx, r13
    jae 5f
    cmp byte ptr [r12 + rcx], 27
    jne 4b
5:  push rcx
    push rcx
    mov rdi, r14
    lea rsi, [r12 + rbx]
    mov rdx, rcx
    sub rdx, rbx
    call sb_push
    pop rcx
    pop rcx
    mov rbx, rcx
    jmp 1b
9:  EPILOGUE

# log_copy(LG*): the selected lines (or the cursor's), without SGR sequences, to the clipboard
FN log_copy
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + LG_cur]
    cmp r12, -1
    je 9f
    mov r13, [rbx + LG_anchor]
    cmp r13, -1
    jne 1f
    mov r13, r12
1:  cmp r12, r13
    jle 2f
    xchg r12, r13
2:  mov rdi, rbx
    call first_line
    cmp r12, rax
    jge 21f
    mov r12, rax
21: lea rdi, [rip + lg_tmp]
    call sb_clear
3:  cmp r12, r13
    jg 6f
    cmp r12, [rbx + LG_seq]
    jge 6f
    mov rdi, rbx
    mov rsi, r12
    call line_at
    mov r14, [rax + LL_ptr]
    mov r15d, [rax + LL_len]
    xor ecx, ecx
4:  cmp ecx, r15d
    jae 5f
    movzx eax, byte ptr [r14 + rcx]
    cmp eax, 27                 # an SGR sequence: up to its m
    jne 41f
42: inc ecx
    cmp ecx, r15d
    jae 5f
    cmp byte ptr [r14 + rcx], 'm'
    jne 42b
    inc ecx
    jmp 4b
41: push rcx
    push rcx
    lea rdi, [rip + lg_tmp]
    mov esi, eax
    call sb_push_byte
    pop rcx
    pop rcx
    inc ecx
    jmp 4b
5:  lea rdi, [rip + lg_tmp]
    mov esi, 10
    call sb_push_byte
    inc r12
    jmp 3b
6:  mov rdi, [rip + lg_tmp + SB_ptr]
    mov rsi, [rip + lg_tmp + SB_len]
    test rsi, rsi
    jz 9f
    xor edx, edx
    call ed_clip_set
    call editor_clip_result
9:  EPILOGUE

# log_toggle_follow(LG*), log_open_find(LG*): the header's Follow and Find
FN log_toggle_follow
    xor dword ptr [rdi + LG_follow], 1
    mov dword ptr [rip + g_dirty], 1
    ret
FN log_open_find
    mov dword ptr [rdi + LG_findopen], 1
    mov dword ptr [rip + g_dirty], 1
    ret
FN log_following
    mov eax, [rdi + LG_follow]
    ret

# log_field(LG*) -> rax its find field while open (pasting goes there), or 0
FN log_field
    xor eax, eax
    test rdi, rdi
    jz 1f
    cmp dword ptr [rdi + LG_findopen], 0
    je 1f
    lea rax, [rdi + LG_find]
1:  ret

# log_dump(LG*, sb): "lines=N dropped=D follow=F cur=C sel=A-B find=TEXT match=M" and a line per
#   line in view: "line K SEV TEXT" (TEXT without SGR sequences)
FN log_dump
    PROLOGUE 16
    call lg_use
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Ld_lines]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + LG_count]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_dropped]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + LG_dropped]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_follow]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + LG_follow]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_cur]
    call sb_push_cstr
    mov rsi, [rbx + LG_cur]
    call push_signed
    mov rdi, r12
    lea rsi, [rip + .Ld_anchor]
    call sb_push_cstr
    mov rsi, [rbx + LG_anchor]
    call push_signed
    mov rdi, r12
    lea rsi, [rip + .Ld_match]
    call sb_push_cstr
    mov rsi, [rbx + LG_match]
    call push_signed
    mov rdi, r12
    lea rsi, [rip + .Ld_find]
    call sb_push_cstr
    cmp dword ptr [rbx + LG_findopen], 0
    je 1f
    mov rdi, r12
    mov rsi, [rbx + LG_find + TF_sb + SB_ptr]
    mov rdx, [rbx + LG_find + TF_sb + SB_len]
    call sb_push
1:  mov rdi, r12
    mov esi, 10
    call sb_push_byte
    # the lines in view
    call row_h
    mov r13d, eax
    mov eax, [rbx + LG_scroll]
    xor edx, edx
    div r13d
    mov r14, rax                # first row
    mov eax, [rbx + LG_rect + 12]
    xor edx, edx
    div r13d
    inc eax
    mov r15, rax                # rows to print
2:  test r15, r15
    jz 9f
    dec r15
    mov rdi, rbx
    call rows
    cmp r14, rax
    jae 9f
    mov rax, r14
    inc r14
    cmp qword ptr [rbx + LG_dropped], 0
    je 3f
    test rax, rax
    jz 2b
    dec rax
3:  mov [rsp], rax
    mov rdi, rbx
    call first_line
    add [rsp], rax
    mov rdi, r12
    lea rsi, [rip + .Ld_line]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rsp]
    call sb_push_u64
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [rsp]
    call line_at
    mov [rsp + 8], rax
    mov ecx, [rax + LL_sev]
    lea rax, [rip + sev_names]
    mov rsi, [rax + rcx*8]
    mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rax, [rsp + 8]
    mov rdi, [rax + LL_ptr]
    mov esi, [rax + LL_len]
    xor ecx, ecx
4:  cmp ecx, esi
    jae 5f
    movzx eax, byte ptr [rdi + rcx]
    cmp eax, 27
    jne 41f
42: inc ecx
    cmp ecx, esi
    jae 5f
    cmp byte ptr [rdi + rcx], 'm'
    jne 42b
    inc ecx
    jmp 4b
41: push rdi
    push rsi
    push rcx
    push rcx
    mov rdi, r12
    mov esi, eax
    call sb_push_byte
    pop rcx
    pop rcx
    pop rsi
    pop rdi
    inc ecx
    jmp 4b
5:  mov rdi, r12
    mov esi, 10
    call sb_push_byte
    jmp 2b
9:  EPILOGUE

# push_signed(): rsi onto r12's buffer, "-1" for -1
push_signed:
    mov rdi, r12
    cmp rsi, -1
    jne 1f
    lea rsi, [rip + .Ld_minus1]
    jmp sb_push_cstr
1:  jmp sb_push_u64

.section .rodata
.Lempty: .asciz ""
.Lfind_ph: .asciz "Find in the log"
.Ldropped: .asciz " earlier lines dropped"
.Ls_trace: .asciz "trace"
.Ls_debug: .asciz "debug"
.Ls_info: .asciz "info"
.Ls_warn: .asciz "warn"
.Ls_error: .asciz "error"
.Ls_none: .asciz "-"
.Ld_lines: .asciz "lines="
.Ld_dropped: .asciz " dropped="
.Ld_follow: .asciz " follow="
.Ld_cur: .asciz " cur="
.Ld_anchor: .asciz " anchor="
.Ld_match: .asciz " match="
.Ld_find: .asciz " find="
.Ld_line: .asciz "line "
.Ld_minus1: .asciz "-1"
.p2align 3
sev_words: .quad .Ls_none, .Ls_trace, .Ls_debug, .Ls_info, .Ls_warn, .Ls_error, 0   # LS_* order
sev_names: .quad .Ls_none, .Ls_trace, .Ls_debug, .Ls_info, .Ls_warn, .Ls_error
sev_colors: .long T_FG, T_MUTED, T_MUTED, T_FG, T_WARNING, T_ERROR
