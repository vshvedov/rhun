# A conversation's typed rows, generic: nothing here names a driver, a tool or a record. Thinking, meta,
# compaction and unknown-block rows are drawn here (as a muted line of the small face until their own forms
# come); the engine (agents.s) asks their heights and draws them by index.
#
#   agrow_est(AS*, row) -> eax fix, edx lines, ecx bytes   the parts of its estimate (O(1))
#   agrow_h(AS*, row, w) -> eax, agrow_draw(AS*, row, x, y, w, h)
#   agrow_free(AT*), agrow_clone(AT*) -> rax AT*, agrow_cut(AS*, n) (its rows from n on go)
#   agrow_focus() -> rax row or -1, agrow_focus_set(row), agrow_key(AS*, keysym, cp, mods) -> eax 1 taken
#   agrow_follow()                  a click's or a key's action, after the frame
#   agrow_think() -> eax            thinking rows open (one state for the open conversation)
#   agrow_code_face() -> rax FACE*  code at the panel's text size, in the editor's family
#   agrow_row_dump(sb, AS*, row)    print-agent-row's lines of a typed row
.include "rhun.inc"

# RW: a text wrapped at a width, laid out and optionally drawn (rw_wrap)
STRUCT
F RW_face, 8
F RW_text, 8
F RW_len, 8
F RW_x, 4
F RW_y, 4
F RW_w, 4
F RW_lh, 4
F RW_color, 4
F RW_draw, 4
F RW_top, 4             # drawn only between these (the clip)
F RW_bot, 4
F RW_max, 4             # lines laid out at most, 0 all
F RW_pad, 4
F RW_out, 8             # SB*: each line laid out as its text and a line feed, or 0
F RW_pad2, 8
ENDSTRUCT RW_SIZE

.data
.p2align 3
rf_row: .quad -1                # the row focus: the row of the open conversation whose action Enter runs
.bss
.p2align 3
code_face: .zero FACE_SIZE      # agrow_code_face's, made for code_px, code_gen
code_px: .long 0
code_gen: .long 0
think_open: .long 0

.text

# rw_wrap(RW*) -> eax lines: a text wrapped at RW_w by its glyphs' advances, at a blank when the line has
#   one, else anywhere; a line feed ends a line; a TAB is four cells. Drawn (RW_draw) line by line between
#   RW_top and RW_bot; each line laid out added to RW_out
rw_wrap:
    PROLOGUE 48
    mov rbx, rdi
    xor r15d, r15d              # lines
    xor r12d, r12d              # p
    mov eax, [rbx + RW_w]
    cmp eax, 1
    jge 0f
    mov eax, 1
0:  shl eax, 6
    mov [rsp + 24], eax         # the width, 26.6
.Lrw_line:
    cmp r12, [rbx + RW_len]
    jae .Lrw_done
    cmp dword ptr [rbx + RW_max], 0
    je 1f
    cmp r15d, [rbx + RW_max]
    jae .Lrw_done
1:  mov r13, r12                # the line's start
    xor r14d, r14d              # its width
    mov qword ptr [rsp], -1     # the last blank
    mov rax, [rbx + RW_len]
    mov [rsp + 8], rax          # its end
    mov [rsp + 16], rax         # the next line's start
.Lrw_ch:
    cmp r12, [rbx + RW_len]
    jae .Lrw_emit
    mov rax, [rbx + RW_text]
    movzx ecx, byte ptr [rax + r12]
    cmp ecx, 10
    jne 2f
    mov [rsp + 8], r12
    lea rcx, [r12 + 1]
    mov [rsp + 16], rcx
    jmp .Lrw_emit2
2:  cmp ecx, ' '
    jne 3f
    mov [rsp], r12
3:  cmp ecx, 9
    jne 4f
    mov rax, [rbx + RW_face]    # a TAB: four cells
    mov eax, [rax + FACE_cellw]
    shl eax, 8
    mov dword ptr [rsp + 32], 1
    mov [rsp], r12
    jmp 5f
4:  lea rdi, [rax + r12]
    mov rsi, [rbx + RW_len]
    sub rsi, r12
    call utf8_decode
    mov [rsp + 32], edx
    mov rdi, [rbx + RW_face]
    mov esi, eax
    call face_glyph
    mov eax, [rax + GL_adv]
5:  lea ecx, [r14 + rax]
    cmp ecx, [rsp + 24]
    jle 7f
    cmp r12, r13
    je 7f                       # a line holds one character at least
    mov rax, [rsp]
    cmp rax, r13
    jle 6f
    mov [rsp + 8], rax          # at the last blank
    inc rax
    mov [rsp + 16], rax
    jmp .Lrw_emit2
6:  mov [rsp + 8], r12          # anywhere
    mov [rsp + 16], r12
    jmp .Lrw_emit2
7:  mov r14d, ecx
    mov eax, [rsp + 32]
    add r12, rax
    jmp .Lrw_ch
.Lrw_emit:
    mov [rsp + 8], r12
    mov [rsp + 16], r12
.Lrw_emit2:
    mov rdi, [rbx + RW_out]
    test rdi, rdi
    jz 8f
    mov rsi, [rbx + RW_text]
    add rsi, r13
    mov rdx, [rsp + 8]
    sub rdx, r13
    call sb_push
    mov rdi, [rbx + RW_out]
    mov esi, 10
    call sb_push_byte
8:  cmp dword ptr [rbx + RW_draw], 0
    je 9f
    mov eax, r15d
    imul eax, [rbx + RW_lh]
    add eax, [rbx + RW_y]
    mov ecx, eax
    add ecx, [rbx + RW_lh]
    cmp ecx, [rbx + RW_top]
    jle 9f
    cmp eax, [rbx + RW_bot]
    jge 9f
    mov rdx, [rbx + RW_face]
    add eax, [rdx + FACE_ascent]
    mov [rsp + 36], eax         # the baseline
    mov eax, [rbx + RW_x]
    mov [rsp + 40], eax         # the pen
    mov rcx, r13                # a segment at a time: a TAB moves the pen four cells
81: mov r8, rcx
82: cmp r8, [rsp + 8]
    jae 83f
    mov rax, [rbx + RW_text]
    cmp byte ptr [rax + r8], 9
    je 83f
    inc r8
    jmp 82b
83: mov [rsp + 44], r8d
    push rcx
    push r8
    mov rdi, [rbx + RW_face]
    mov esi, [rsp + 16 + 40]
    mov edx, [rsp + 16 + 36]
    sub r8, rcx
    add rcx, [rbx + RW_text]
    mov r9d, [rbx + RW_color]
    call text_draw
    mov [rsp + 16 + 40], eax
    pop r8
    pop rcx
    cmp r8, [rsp + 8]
    jae 9f
    mov rax, [rbx + RW_face]
    mov eax, [rax + FACE_cellw]
    shl eax, 2
    add [rsp + 40], eax
    lea rcx, [r8 + 1]
    jmp 81b
9:  inc r15d
    mov r12, [rsp + 16]
    jmp .Lrw_line
.Lrw_done:
    test r15d, r15d
    jnz 1f
    mov r15d, 1
1:  mov eax, r15d
    EPILOGUE

# row_of(AS*, row) -> rax AM*
row_of:
    imul rax, rsi, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    ret

# line_rw(RW*, AM*, w): a muted line row's text in the small face at the width
line_rw:
    mov rax, [rsi + AM_text]
    mov [rdi + RW_text], rax
    mov rax, [rsi + AM_len]
    mov [rdi + RW_len], rax
    mov [rdi + RW_w], edx
    mov rax, [rip + ag_fsmall]
    mov [rdi + RW_face], rax
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_3]
    mov [rdi + RW_lh], eax
    mov dword ptr [rdi + RW_draw], 0
    mov dword ptr [rdi + RW_max], 0
    mov qword ptr [rdi + RW_out], 0
    ret

# FN agrow_est(AS*, row) -> eax the pixels of its height that do not depend on the width, edx its lines and
#   ecx its bytes that wrap (agents.s's estimate and chunk aggregates)
FN agrow_est
    call row_of
    mov r8, rax
    mov edx, [r8 + AM_nl]
    inc edx
    mov rcx, [r8 + AM_len]
    cmp rcx, 16777216
    jbe 1f
    mov ecx, 16777216
1:  mov eax, [rip + g_pmt + 4*MI_12]
    ret

# FN agrow_h(AS*, row, w) -> eax its height measured at the width
FN agrow_h
    PROLOGUE RW_SIZE
    mov r12d, edx
    call row_of
    lea rdi, [rsp]
    mov rsi, rax
    mov edx, r12d
    call line_rw
    lea rdi, [rsp]
    call rw_wrap
    imul eax, [rsp + RW_lh]
    add eax, [rip + g_pmt + 4*MI_12]
    EPILOGUE

# FN agrow_draw(AS*, row, x, y, w, h): drawn: a thinking, meta, compaction or unknown-block row as a muted
#   line of the small face
FN agrow_draw
    PROLOGUE RW_SIZE
    mov r12d, edx
    mov r13d, ecx
    mov r14d, r8d
    call row_of
    lea rdi, [rsp]
    mov rsi, rax
    mov edx, r14d
    call line_rw
    mov [rsp + RW_x], r12d
    mov eax, r13d
    add eax, [rip + g_pmt + 4*MI_6]
    mov [rsp + RW_y], eax
    COLOR eax, T_MUTED
    mov [rsp + RW_color], eax
    mov dword ptr [rsp + RW_draw], 1
    mov eax, [rip + g_cv + CV_cy0]
    mov [rsp + RW_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rsp + RW_bot], eax
    lea rdi, [rsp]
    call rw_wrap
    EPILOGUE

# FN agrow_free(AT*): a call and what it owns (phase 3 task 2b fills this in)
FN agrow_free
    jmp mem_free

# FN agrow_clone(AT*) -> rax a deep copy (2b)
FN agrow_clone
    xor eax, eax
    ret

# FN agrow_cut(AS*, n): its rows from n on go: the row focus on one of them goes
FN agrow_cut
    cmp [rip + rf_row], rsi
    jl 1f
    mov qword ptr [rip + rf_row], -1
1:  ret

# FN agrow_focus() -> rax the focused row, -1
FN agrow_focus
    mov rax, [rip + rf_row]
    ret

# FN agrow_focus_set(row or -1)
FN agrow_focus_set
    mov [rip + rf_row], rdi
    mov dword ptr [rip + g_dirty], 1
    ret

# FN agrow_key(AS*, keysym, cp, mods) -> eax 1 taken: Escape drops a row focus
FN agrow_key
    xor eax, eax
    cmp esi, KEY_ESCAPE
    jne 9f
    cmp qword ptr [rip + rf_row], 0
    jl 9f
    mov qword ptr [rip + rf_row], -1
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  ret

# FN agrow_follow(): the action a click or a key asked for, after the frame
FN agrow_follow
    ret

# FN agrow_think() -> eax 1 when the open conversation's thinking rows are open
FN agrow_think
    mov eax, [rip + think_open]
    ret

# FN agrow_code_face() -> rax FACE*: code at the panel's text size in the editor's family (made when the size
#   or the editor's face changed)
FN agrow_code_face
    PROLOGUE
    mov rax, [rip + ag_fui]
    mov ebx, [rax + FACE_px]
    lea rax, [rip + g_face_code]
    cmp qword ptr [rax + FACE_font], 0
    je 9f                       # no fonts yet
    cmp ebx, [rax + FACE_px]
    je 9f                       # the editor's own face is that size
    lea rax, [rip + code_face]
    cmp ebx, [rip + code_px]
    jne 1f
    mov rcx, [rip + g_face_code + FACE_font]
    cmp rcx, [rax + FACE_font]
    je 9f
1:  mov [rip + code_px], ebx
    lea rdi, [rip + code_face]
    mov rsi, [rip + g_face_code + FACE_font]
    mov edx, ebx
    cmp edx, 4
    jge 2f
    mov edx, 4
2:  call face_init
    lea rax, [rip + code_face]
9:  EPILOGUE

# FN agrow_row_dump(sb, AS*, row): print-agent-row's lines of a typed row ("plain TEXT" for a line row)
FN agrow_row_dump
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call row_of
    mov r12, rax
    mov rdi, rbx
    lea rsi, [rip + .Lplain]
    call sb_push_cstr
    mov rsi, [r12 + AM_text]
    mov rdx, [r12 + AM_len]
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 2f
    cmp rcx, 60
    jae 2f
    cmp byte ptr [rsi + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov rdi, rbx
    mov rdx, rcx
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Lplain: .asciz "plain "
.text
