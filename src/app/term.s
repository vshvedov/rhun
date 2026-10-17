# terminal emulator: xterm escape sequences applied to a screen of cells, with scrollback
# Internal helpers take the terminal in rbx.
.include "rhun.inc"

.equ S_GROUND, 0
.equ S_ESC, 1
.equ S_CSI, 2
.equ S_OSC, 3
.equ S_OSC_ESC, 4
.equ S_STR, 5
.equ S_STR_ESC, 6
.equ S_G0, 7
.equ S_G1, 8
.equ S_HASH, 9
.equ S_SKIP, 10
.equ MAXP, 16
.equ MAX_OSC, 4096

# address of cell col in line
.macro CELLP out, line, col
    lea \out, [\col + \col*2]
    lea \out, [\line + \out*4 + LN_HDR]
.endm

.bss
.p2align 2
# the unshifted character of the key being handled, set by a platform around its key event (0 when it
# has none): the kitty keyboard protocol names a key by it, Ctrl+Shift+2 as 2 with Shift
.globl g_key_base
g_key_base: .long 0

.text

# ---------------- setup ----------------

# term_new(cols, rows, scrollback lines) -> TERM*
FN term_new
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov edi, TM_SIZE
    call mem_alloc
    mov rbx, rax
    mov [rbx + TM_cols], r12d
    mov [rbx + TM_rows], r13d
    mov [rbx + TM_sbcap], r14d
    mov dword ptr [rbx + TM_modes], TMM_WRAP
    lea eax, [r13 - 1]
    mov [rbx + TM_bot], eax
    call screen_new
    mov [rbx + TM_lines], rax
    call screen_new
    mov [rbx + TM_other], rax
    mov edi, r14d
    shl rdi, 3
    test rdi, rdi
    jz 1f
    call mem_alloc
    mov [rbx + TM_sb], rax
1:  call tabs_reset
    mov rax, rbx
    EPILOGUE

# term_free(t)
FN term_free
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + TM_lines]
    call screen_free
    mov rdi, [rbx + TM_other]
    call screen_free
    call ring_clear
    mov rdi, [rbx + TM_sb]
    call mem_free
    mov rdi, [rbx + TM_tabs]
    call mem_free
    lea rdi, [rbx + TM_out]
    call sb_free
    lea rdi, [rbx + TM_str]
    call sb_free
    lea rdi, [rbx + TM_title]
    call sb_free
    mov rdi, rbx
    call mem_free
    EPILOGUE

# screen_new() -> TM_rows fresh lines
screen_new:
    push r12
    push r13
    push r14
    mov r12d, [rbx + TM_rows]
    lea rdi, [r12*8 + 8]
    call mem_alloc
    mov r13, rax
    xor r14d, r14d
1:  cmp r14d, r12d
    jae 2f
    call line_new
    mov [r13 + r14*8], rax
    inc r14d
    jmp 1b
2:  mov rax, r13
    pop r14
    pop r13
    pop r12
    ret

# screen_free(lines)
screen_free:
    push r12
    push r13
    push r14
    mov r12, rdi
    xor r13d, r13d
1:  cmp r13d, [rbx + TM_rows]
    jae 2f
    mov rdi, [r12 + r13*8]
    call mem_free
    inc r13d
    jmp 1b
2:  mov rdi, r12
    call mem_free
    pop r14
    pop r13
    pop r12
    ret

# line_new() -> a blank line of TM_cols cells
line_new:
    push r12
    mov r12d, [rbx + TM_cols]
    lea rdi, [r12 + r12*2]
    lea rdi, [rdi*4 + LN_HDR]
    call mem_alloc
    mov [rax + LN_cap], r12d
    cmp dword ptr [rbx + TM_bg], 0
    je 1f
    mov ecx, r12d
    shl ecx, 16
    mov [rax + LN_flags], ecx
    push rax
    lea rdi, [rax + LN_HDR]
    mov esi, r12d
    call fill_blank
    pop rax
1:  pop r12
    ret

# line_fit(line) -> line with room for TM_cols cells (new cells blank)
line_fit:
    mov eax, [rdi + LN_cap]
    cmp eax, [rbx + TM_cols]
    jae 1f
    push r12
    mov r12d, [rbx + TM_cols]
    lea rsi, [r12 + r12*2]
    lea rsi, [rsi*4 + LN_HDR]
    call mem_realloc
    mov [rax + LN_cap], r12d
    pop r12
    ret
1:  mov rax, rdi
    ret

# clear_line(line) -> line, all cells blank; only cells that may hold text are touched
clear_line:
    push rdi
    mov esi, [rdi + LN_flags]
    shr esi, 16
    mov dword ptr [rdi + LN_flags], 0
    cmp dword ptr [rbx + TM_bg], 0
    je 1f
    mov esi, [rdi + LN_cap]
    mov ecx, esi
    shl ecx, 16
    mov [rdi + LN_flags], ecx
1:  cmp esi, [rdi + LN_cap]
    jbe 2f
    mov esi, [rdi + LN_cap]
2:  add rdi, LN_HDR
    call fill_blank
    pop rax
    ret

# hw_mark(line, cells): the line may hold text in its first cells (kept in the high half of LN_flags)
hw_mark:
    mov eax, [rdi + LN_flags]
    mov ecx, eax
    shr ecx, 16
    cmp ecx, esi
    jae 1f
    and eax, 0xffff
    shl esi, 16
    or eax, esi
    mov [rdi + LN_flags], eax
1:  ret

# fill_blank(cells, n): blank in the current background
fill_blank:
    movsxd rsi, esi
    test rsi, rsi
    jle 9f
    mov eax, [rbx + TM_bg]
    test eax, eax
    jnz 2f
    lea rcx, [rsi + rsi*2]
    shl rcx, 2
    rep stosb
    ret
2:  mov qword ptr [rdi], 0
    mov [rdi + 8], eax
    add rdi, CELL_SIZE
    dec rsi
    jnz 2b
9:  ret

# tabs_reset(): a stop every 8 columns
tabs_reset:
    mov eax, [rbx + TM_cols]
    cmp eax, [rbx + TM_tabcap]
    jbe 1f
    push rax
    mov rdi, [rbx + TM_tabs]
    mov esi, eax
    call mem_realloc
    mov [rbx + TM_tabs], rax
    pop rax
    mov [rbx + TM_tabcap], eax
1:  mov rdi, [rbx + TM_tabs]
    xor ecx, ecx
2:  cmp ecx, [rbx + TM_tabcap]
    jae 3f
    xor edx, edx
    test ecx, 7
    setz dl
    test ecx, ecx
    jnz 21f
    xor edx, edx
21: mov [rdi + rcx], dl
    inc ecx
    jmp 2b
3:  ret

# cur_line() -> line of the cursor
cur_line:
    mov rax, [rbx + TM_lines]
    movsxd rcx, dword ptr [rbx + TM_cy]
    mov rax, [rax + rcx*8]
    ret

# ---------------- scrollback ----------------

# ring_push(line) -> the line, blank again; scrollback keeps a copy up to its last used cell
ring_push:
    push r12
    push r13
    push r14
    mov r12, rdi
    cmp dword ptr [rbx + TM_sbcap], 0
    je 8f
    mov r13d, [r12 + LN_flags]
    shr r13d, 16
    cmp r13d, [r12 + LN_cap]
    jbe 1f
    mov r13d, [r12 + LN_cap]
1:  test r13d, r13d
    jz 2f
    lea eax, [r13 - 1]
    CELLP rdx, r12, rax
    mov eax, [rdx]
    or eax, 0x20
    cmp eax, 0x20
    jne 2f
    cmp dword ptr [rdx + 8], 0
    jne 2f
    dec r13d
    jmp 1b
2:  lea rdi, [r13 + r13*2]
    lea rdi, [rdi*4 + LN_HDR]
    call mem_alloc
    mov r14, rax
    mov [r14 + LN_cap], r13d
    mov eax, [r12 + LN_flags]
    and eax, LF_WRAPPED
    mov ecx, r13d
    shl ecx, 16
    or eax, ecx
    mov [r14 + LN_flags], eax
    lea rdi, [r14 + LN_HDR]
    lea rsi, [r12 + LN_HDR]
    lea rdx, [r13 + r13*2]
    shl rdx, 2
    call memcpy
    inc qword ptr [rbx + TM_total]
    call view_keep
    mov ecx, [rbx + TM_sbcap]
    mov eax, [rbx + TM_sblen]
    cmp eax, ecx
    jae 4f
    add eax, [rbx + TM_sbhead]
    cmp eax, ecx
    jb 3f
    sub eax, ecx
3:  mov rdx, [rbx + TM_sb]
    mov [rdx + rax*8], r14
    inc dword ptr [rbx + TM_sblen]
    jmp 8f
4:  # full: the oldest goes
    mov edx, [rbx + TM_sbhead]
    mov rax, [rbx + TM_sb]
    mov rdi, [rax + rdx*8]
    mov [rax + rdx*8], r14
    inc edx
    cmp edx, ecx
    jb 5f
    xor edx, edx
5:  mov [rbx + TM_sbhead], edx
    call mem_free
8:  mov rdi, r12
    call clear_line
    pop r14
    pop r13
    pop r12
    ret

# ring_add(line): into scrollback; the line itself is freed
ring_add:
    push rdi
    call ring_push
    pop rdi
    jmp mem_free

# ring_pop() -> newest scrollback line (taken out), or 0
ring_pop:
    mov eax, [rbx + TM_sblen]
    test eax, eax
    jz 9f
    dec eax
    mov [rbx + TM_sblen], eax
    dec qword ptr [rbx + TM_total]
    add eax, [rbx + TM_sbhead]
    xor edx, edx
    div dword ptr [rbx + TM_sbcap]
    mov rax, [rbx + TM_sb]
    mov rax, [rax + rdx*8]
    ret
9:  xor eax, eax
    ret

# ring_clear(): drop the scrollback
ring_clear:
    push r12
1:  call ring_pop
    test rax, rax
    jz 2f
    mov rdi, rax
    call mem_free
    jmp 1b
2:  mov dword ptr [rbx + TM_sbhead], 0
    mov dword ptr [rbx + TM_view], 0
    pop r12
    ret

# view_keep(): a line went into scrollback; a scrolled-back view stays on the same text
view_keep:
    mov eax, [rbx + TM_view]
    test eax, eax
    jz 1f
    inc eax
    cmp eax, [rbx + TM_sbcap]
    jbe 2f
    mov eax, [rbx + TM_sbcap]
2:  mov [rbx + TM_view], eax
1:  ret

# ---------------- scrolling ----------------

# scroll_up(top, bot, n, to_scrollback): rows top..bot move up; blank lines enter at bot
#   lines leave into scrollback only from the top of the main screen
scroll_up:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov eax, r13d
    sub eax, r12d
    inc eax
    jle 9f
    cmp r14d, eax
    jle 1f
    mov r14d, eax
1:  test r14d, r14d
    jle 9f
    mov r15d, ecx
    test r12d, r12d
    jz 2f
    xor r15d, r15d
2:  test dword ptr [rbx + TM_modes], TMM_ALT
    jz 3f
    xor r15d, r15d
3:  mov rax, [rbx + TM_lines]
    movsxd rcx, r12d
    mov rdi, [rax + rcx*8]
    mov [rsp], rdi
    lea rdi, [rax + rcx*8]
    lea rsi, [rdi + 8]
    mov edx, r13d
    sub edx, r12d
    shl edx, 3
    call memmove
    mov rdi, [rsp]
    test r15d, r15d
    jz 4f
    call ring_push
    jmp 5f
4:  call clear_line
5:  mov rcx, [rbx + TM_lines]
    movsxd rdx, r13d
    mov [rcx + rdx*8], rax
    dec r14d
    jnz 3b
9:  add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    ret

# scroll_down(top, bot, n): rows top..bot move down; blank lines enter at top
scroll_down:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov eax, r13d
    sub eax, r12d
    inc eax
    jle 9f
    cmp r14d, eax
    jle 1f
    mov r14d, eax
1:  test r14d, r14d
    jle 9f
2:  mov rax, [rbx + TM_lines]
    movsxd rcx, r13d
    mov rdi, [rax + rcx*8]
    mov [rsp], rdi
    movsxd rcx, r12d
    lea rsi, [rax + rcx*8]
    lea rdi, [rsi + 8]
    mov edx, r13d
    sub edx, r12d
    shl edx, 3
    call memmove
    mov rdi, [rsp]
    call clear_line
    mov rcx, [rbx + TM_lines]
    movsxd rdx, r12d
    mov [rcx + rdx*8], rax
    dec r14d
    jnz 2b
9:  add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    ret

# index(): cursor down one line, scrolling at the bottom of the region
index:
    mov dword ptr [rbx + TM_wrapnext], 0
    mov eax, [rbx + TM_cy]
    cmp eax, [rbx + TM_bot]
    jne 1f
    mov edi, [rbx + TM_top]
    mov esi, [rbx + TM_bot]
    mov edx, 1
    mov ecx, 1
    jmp scroll_up
1:  inc eax
    cmp eax, [rbx + TM_rows]
    jge 2f
    mov [rbx + TM_cy], eax
2:  ret

# rev_index(): cursor up one line, scrolling at the top of the region
rev_index:
    mov dword ptr [rbx + TM_wrapnext], 0
    mov eax, [rbx + TM_cy]
    cmp eax, [rbx + TM_top]
    jne 1f
    mov edi, [rbx + TM_top]
    mov esi, [rbx + TM_bot]
    mov edx, 1
    jmp scroll_down
1:  test eax, eax
    jz 2f
    dec eax
    mov [rbx + TM_cy], eax
2:  ret

# ---------------- characters ----------------

# char_width(cp) -> 0 (combining), 1 or 2
char_width:
    mov eax, 1
    cmp edi, 0x300
    jb 9f
    lea rsi, [rip + zero_ranges]
1:  mov ecx, [rsi]
    test ecx, ecx
    jz cp_width
    cmp edi, ecx
    jb 2f
    cmp edi, [rsi + 4]
    ja 2f
    xor eax, eax
    ret
2:  add rsi, 8
    jmp 1b
9:  ret

# unwide(line, col): a character written at col splits no double-width pair
unwide:
    test esi, esi
    js 9f
    cmp esi, [rbx + TM_cols]
    jge 9f
    movsxd rsi, esi
    CELLP rax, rdi, rsi
    mov ecx, [rax]
    test ecx, A_WIDE2
    jz 1f
    test esi, esi
    jz 1f
    mov dword ptr [rax - CELL_SIZE], 0
1:  test ecx, A_WIDE
    jz 2f
    lea edx, [rsi + 1]
    cmp edx, [rbx + TM_cols]
    jge 2f
    mov dword ptr [rax + CELL_SIZE], 0
2:  and ecx, ~(A_WIDE | A_WIDE2)
    mov [rax], ecx
9:  ret

# do_wrap(): the pending wrap of the last column
do_wrap:
    mov dword ptr [rbx + TM_wrapnext], 0
    test dword ptr [rbx + TM_modes], TMM_WRAP
    jz 1f
    call cur_line
    or dword ptr [rax + LN_flags], LF_WRAPPED
    mov dword ptr [rbx + TM_cx], 0
    jmp index
1:  ret

# put_char(cp)
put_char:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12d, edi
    # DEC line drawing in the active set
    mov eax, [rbx + TM_g0]
    cmp dword ptr [rbx + TM_gl], 0
    je 1f
    mov eax, [rbx + TM_g1]
1:  test eax, eax
    jz 2f
    lea ecx, [r12 - 0x5f]
    cmp ecx, 0x1f
    ja 2f
    lea rdx, [rip + dec_graphics]
    movzx r12d, word ptr [rdx + rcx*2]
2:  mov edi, r12d
    call char_width
    test eax, eax
    jz .Lpc_ret
    mov r13d, eax
    cmp dword ptr [rbx + TM_wrapnext], 0
    je 3f
    call do_wrap
3:  cmp r13d, 2
    jne 4f
    mov eax, [rbx + TM_cols]
    dec eax
    cmp [rbx + TM_cx], eax
    jl 4f
    # no room for both halves
    cmp eax, 1
    jge 31f
    mov r13d, 1
    jmp 4f
31: test dword ptr [rbx + TM_modes], TMM_WRAP
    jz 32f
    call cur_line
    mov rdi, rax
    mov esi, [rbx + TM_cx]
    call unwide
    call cur_line
    movsxd rcx, dword ptr [rbx + TM_cx]
    CELLP rdi, rax, rcx
    mov esi, 1
    call fill_blank
    call do_wrap
    jmp 4f
32: mov eax, [rbx + TM_cols]
    sub eax, 2
    mov [rbx + TM_cx], eax
4:  test dword ptr [rbx + TM_modes], TMM_INSERT
    jz 5f
    mov edi, r13d
    call insert_blanks
5:  call cur_line
    mov r14, rax
    movsxd r15, dword ptr [rbx + TM_cx]
    mov rdi, r14
    mov esi, r15d
    call unwide
    cmp r13d, 2
    jne 6f
    mov rdi, r14
    lea esi, [r15 + 1]
    call unwide
6:  CELLP rdi, r14, r15
    mov eax, [rbx + TM_attr]
    or eax, r12d
    cmp r13d, 2
    jne 7f
    or eax, A_WIDE
7:  mov [rdi], eax
    mov eax, [rbx + TM_fg]
    mov [rdi + 4], eax
    mov eax, [rbx + TM_bg]
    mov [rdi + 8], eax
    cmp r13d, 2
    jne 8f
    mov eax, [rbx + TM_attr]
    or eax, A_WIDE2
    mov [rdi + 12], eax
    mov eax, [rbx + TM_fg]
    mov [rdi + 16], eax
    mov eax, [rbx + TM_bg]
    mov [rdi + 20], eax
8:  mov [rbx + TM_lastcp], r12d
    mov rdi, r14
    lea esi, [r15 + r13]
    call hw_mark
    add r15d, r13d
    cmp r15d, [rbx + TM_cols]
    jl 9f
    mov r15d, [rbx + TM_cols]
    dec r15d
    mov dword ptr [rbx + TM_wrapnext], 1
9:  mov [rbx + TM_cx], r15d
.Lpc_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    ret

# insert_blanks(n): at the cursor, shifting the rest of the line right
insert_blanks:
    push r12
    push r13
    push r14
    mov dword ptr [rbx + TM_wrapnext], 0
    mov r12d, edi
    mov eax, [rbx + TM_cols]
    sub eax, [rbx + TM_cx]
    cmp r12d, eax
    jle 1f
    mov r12d, eax
1:  test r12d, r12d
    jle 9f
    call cur_line
    mov r13, rax
    movsxd r14, dword ptr [rbx + TM_cx]
    mov rdi, r13
    mov esi, r14d
    call unwide
    mov edx, [rbx + TM_cols]
    sub edx, r14d
    sub edx, r12d
    lea rdx, [rdx + rdx*2]
    shl rdx, 2
    CELLP rsi, r13, r14
    movsxd rax, r12d
    add rax, r14
    CELLP rdi, r13, rax
    call memmove
    CELLP rdi, r13, r14
    mov esi, r12d
    call fill_blank
    mov esi, [r13 + LN_flags]
    shr esi, 16
    add esi, r12d
    cmp esi, [rbx + TM_cols]
    jbe 1f
    mov esi, [rbx + TM_cols]
1:  mov rdi, r13
    call hw_mark
9:  pop r14
    pop r13
    pop r12
    ret

# delete_chars(n): at the cursor, shifting the rest of the line left
delete_chars:
    push r12
    push r13
    push r14
    mov dword ptr [rbx + TM_wrapnext], 0
    mov r12d, edi
    mov eax, [rbx + TM_cols]
    sub eax, [rbx + TM_cx]
    cmp r12d, eax
    jle 1f
    mov r12d, eax
1:  test r12d, r12d
    jle 9f
    call cur_line
    mov r13, rax
    movsxd r14, dword ptr [rbx + TM_cx]
    mov rdi, r13
    mov esi, r14d
    call unwide
    mov rdi, r13
    lea esi, [r14 + r12 - 1]
    call unwide
    mov edx, [rbx + TM_cols]
    sub edx, r14d
    sub edx, r12d
    lea rdx, [rdx + rdx*2]
    shl rdx, 2
    CELLP rdi, r13, r14
    movsxd rax, r12d
    add rax, r14
    CELLP rsi, r13, rax
    call memmove
    movsxd rax, dword ptr [rbx + TM_cols]
    movsxd rcx, r12d
    sub rax, rcx
    CELLP rdi, r13, rax
    mov esi, r12d
    call fill_blank
    cmp dword ptr [rbx + TM_bg], 0
    je 9f
    mov rdi, r13
    mov esi, [rbx + TM_cols]
    call hw_mark
9:  pop r14
    pop r13
    pop r12
    ret

# erase_cells(row, from, to): blank [from, to) of a row
erase_cells:
    push r12
    push r13
    push r14
    mov r12d, esi
    mov r13d, edx
    cmp r13d, [rbx + TM_cols]
    jle 1f
    mov r13d, [rbx + TM_cols]
1:  test r12d, r12d
    jns 2f
    xor r12d, r12d
2:  cmp r12d, r13d
    jge 9f
    mov rax, [rbx + TM_lines]
    movsxd rcx, edi
    mov r14, [rax + rcx*8]
    cmp r13d, [rbx + TM_cols]
    jl 3f
    and dword ptr [r14 + LN_flags], ~LF_WRAPPED
3:  mov rdi, r14
    mov esi, r12d
    call unwide
    mov rdi, r14
    lea esi, [r13 - 1]
    call unwide
    movsxd rax, r12d
    CELLP rdi, r14, rax
    mov esi, r13d
    sub esi, r12d
    call fill_blank
    cmp dword ptr [rbx + TM_bg], 0
    je 9f
    mov rdi, r14
    mov esi, r13d
    call hw_mark
9:  pop r14
    pop r13
    pop r12
    ret

# erase_rows(from, to): whole rows [from, to)
erase_rows:
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
1:  cmp r12d, r13d
    jge 9f
    mov rax, [rbx + TM_lines]
    movsxd rcx, r12d
    mov rdi, [rax + rcx*8]
    call clear_line
    inc r12d
    jmp 1b
9:  pop r14
    pop r13
    pop r12
    ret

# ---------------- cursor ----------------

# move_to(col, row): row counts from the region top in origin mode
move_to:
    mov dword ptr [rbx + TM_wrapnext], 0
    xor r8d, r8d
    mov r9d, [rbx + TM_rows]
    dec r9d
    test dword ptr [rbx + TM_modes], TMM_ORIGIN
    jz 1f
    mov r8d, [rbx + TM_top]
    mov r9d, [rbx + TM_bot]
    add esi, r8d
1:  cmp esi, r8d
    jge 2f
    mov esi, r8d
2:  cmp esi, r9d
    jle 3f
    mov esi, r9d
3:  mov [rbx + TM_cy], esi
    # column
    test edi, edi
    jns 4f
    xor edi, edi
4:  mov eax, [rbx + TM_cols]
    dec eax
    cmp edi, eax
    jle 5f
    mov edi, eax
5:  mov [rbx + TM_cx], edi
    ret

save_cursor:
    mov eax, [rbx + TM_cx]
    mov [rbx + TM_scx], eax
    mov eax, [rbx + TM_cy]
    mov [rbx + TM_scy], eax
    mov eax, [rbx + TM_attr]
    mov [rbx + TM_sattr], eax
    mov eax, [rbx + TM_fg]
    mov [rbx + TM_sfg], eax
    mov eax, [rbx + TM_bg]
    mov [rbx + TM_sbg], eax
    mov eax, [rbx + TM_g0]
    mov [rbx + TM_sg0], eax
    ret

restore_cursor:
    mov eax, [rbx + TM_sattr]
    mov [rbx + TM_attr], eax
    mov eax, [rbx + TM_sfg]
    mov [rbx + TM_fg], eax
    mov eax, [rbx + TM_sbg]
    mov [rbx + TM_bg], eax
    mov eax, [rbx + TM_sg0]
    mov [rbx + TM_g0], eax
    mov dword ptr [rbx + TM_wrapnext], 0
    mov eax, [rbx + TM_scx]
    mov ecx, [rbx + TM_cols]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov [rbx + TM_cx], eax
    mov eax, [rbx + TM_scy]
    mov ecx, [rbx + TM_rows]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov [rbx + TM_cy], eax
    ret

# tab_forward(): to the next stop
tab_forward:
    mov ecx, [rbx + TM_cx]
    mov rdx, [rbx + TM_tabs]
    mov eax, [rbx + TM_cols]
    dec eax
1:  cmp ecx, eax
    jge 2f
    inc ecx
    cmp byte ptr [rdx + rcx], 0
    je 1b
2:  mov [rbx + TM_cx], ecx
    mov dword ptr [rbx + TM_wrapnext], 0
    ret

tab_back:
    mov ecx, [rbx + TM_cx]
    mov rdx, [rbx + TM_tabs]
1:  test ecx, ecx
    jz 2f
    dec ecx
    cmp byte ptr [rdx + rcx], 0
    je 1b
2:  mov [rbx + TM_cx], ecx
    mov dword ptr [rbx + TM_wrapnext], 0
    ret

# alt_screen(on): switch between the main and the alternate screen
alt_screen:
    mov eax, [rbx + TM_modes]
    and eax, TMM_ALT
    test edi, edi
    jz 1f
    test eax, eax
    jnz 2f
    jmp 3f
1:  test eax, eax
    jz 9f
3:  mov rax, [rbx + TM_lines]
    mov rcx, [rbx + TM_other]
    mov [rbx + TM_lines], rcx
    mov [rbx + TM_other], rax
    xor dword ptr [rbx + TM_modes], TMM_ALT
    mov dword ptr [rbx + TM_view], 0
    test edi, edi
    jz 9f
2:  # a fresh alternate screen, without keyboard flags left from an earlier program
    lea rdi, [rbx + TM_kk + KK_BLOCK]
    xor eax, eax
    mov ecx, KK_BLOCK / 4
    rep stosd
    xor edi, edi
    mov esi, [rbx + TM_rows]
    jmp erase_rows
9:  mov dword ptr [rbx + TM_wrapnext], 0
    ret

# full_reset(): ESC c
full_reset:
    xor edi, edi
    call alt_screen
    lea rdi, [rbx + TM_kk]
    xor eax, eax
    mov ecx, KK_SIZE / 4
    rep stosd
    mov dword ptr [rbx + TM_modes], TMM_WRAP
    xor eax, eax
    mov [rbx + TM_attr], eax
    mov [rbx + TM_fg], eax
    mov [rbx + TM_bg], eax
    mov [rbx + TM_g0], eax
    mov [rbx + TM_g1], eax
    mov [rbx + TM_gl], eax
    mov [rbx + TM_top], eax
    mov [rbx + TM_cursor], eax
    mov [rbx + TM_mouse], eax
    mov [rbx + TM_cx], eax
    mov [rbx + TM_cy], eax
    mov [rbx + TM_wrapnext], eax
    mov eax, [rbx + TM_rows]
    dec eax
    mov [rbx + TM_bot], eax
    call save_cursor
    call tabs_reset
    xor edi, edi
    mov esi, [rbx + TM_rows]
    jmp erase_rows

# kk_block() -> rax: the active screen's kitty keyboard flags (TM_kk)
kk_block:
    lea rax, [rbx + TM_kk]
    test dword ptr [rbx + TM_modes], TMM_ALT
    jz 1f
    add rax, KK_BLOCK
1:  ret

# ---------------- replies ----------------

reply_cstr:
    mov rsi, rdi
    lea rdi, [rbx + TM_out]
    jmp sb_push_cstr

reply_num:
    mov rsi, rdi
    lea rdi, [rbx + TM_out]
    jmp sb_push_u64

reply_byte:
    mov esi, edi
    lea rdi, [rbx + TM_out]
    jmp sb_push_byte

# ---------------- parser ----------------

# term_feed(t, ptr, len): output of the program
FN term_feed
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.Lf_next:
    test r13, r13
    jz .Lf_done
    movzx eax, byte ptr [r12]
    inc r12
    dec r13
    mov ecx, [rbx + TM_state]
    test ecx, ecx
    jnz .Lf_seq
    cmp dword ptr [rbx + TM_utfn], 0
    jne .Lf_cont
    lea edx, [rax - 0x20]
    cmp edx, 0x5f
    jb .Lf_ascii
    cmp eax, 0x80
    jae .Lf_lead
    cmp eax, 0x7f
    je .Lf_next
    mov edi, eax
    call control
    jmp .Lf_next
.Lf_lead:
    cmp eax, 0xc2
    jb .Lf_bad
    cmp eax, 0xe0
    jae 1f
    and eax, 0x1f
    mov ecx, 1
    jmp 3f
1:  cmp eax, 0xf0
    jae 2f
    and eax, 0x0f
    mov ecx, 2
    jmp 3f
2:  cmp eax, 0xf5
    jae .Lf_bad
    and eax, 7
    mov ecx, 3
3:  mov [rbx + TM_utf], eax
    mov [rbx + TM_utfn], ecx
    jmp .Lf_next
.Lf_bad:
    mov edi, 0xfffd
    call put_char
    jmp .Lf_next
.Lf_cont:
    mov edx, eax
    and edx, 0xc0
    cmp edx, 0x80
    jne .Lf_broken
    mov ecx, [rbx + TM_utf]
    shl ecx, 6
    and eax, 0x3f
    or ecx, eax
    mov [rbx + TM_utf], ecx
    dec dword ptr [rbx + TM_utfn]
    jnz .Lf_next
    mov edi, ecx
    call put_char
    jmp .Lf_next
.Lf_broken:
    # a sequence cut short: a replacement character, then this byte again
    mov dword ptr [rbx + TM_utfn], 0
    mov edi, 0xfffd
    call put_char
    dec r12
    inc r13
    jmp .Lf_next
.Lf_ascii:
    # printable ASCII goes straight into the cells
    test dword ptr [rbx + TM_modes], TMM_INSERT
    jnz .Lf_slow
    mov ecx, [rbx + TM_g0]
    cmp dword ptr [rbx + TM_gl], 0
    je 1f
    mov ecx, [rbx + TM_g1]
1:  test ecx, ecx
    jnz .Lf_slow
    cmp dword ptr [rbx + TM_wrapnext], 0
    jne .Lf_slow
    mov esi, eax
    call cur_line
    mov r14, rax
    mov eax, esi
    movsxd r15, dword ptr [rbx + TM_cx]
.Lf_fast:
    CELLP rdi, r14, r15
    test dword ptr [rdi], A_WIDE | A_WIDE2
    jnz .Lf_fast_slow
    mov ecx, [rbx + TM_attr]
    or ecx, eax
    mov [rdi], ecx
    mov ecx, [rbx + TM_fg]
    mov [rdi + 4], ecx
    mov ecx, [rbx + TM_bg]
    mov [rdi + 8], ecx
    mov [rbx + TM_lastcp], eax
    inc r15d
    cmp r15d, [rbx + TM_cols]
    jae .Lf_edge
    test r13, r13
    jz .Lf_fast_end
    movzx eax, byte ptr [r12]
    lea edx, [rax - 0x20]
    cmp edx, 0x5f
    jae .Lf_fast_end
    inc r12
    dec r13
    jmp .Lf_fast
.Lf_edge:
    mov rdi, r14
    mov esi, r15d
    call hw_mark
    dec r15d
    mov dword ptr [rbx + TM_wrapnext], 1
    mov [rbx + TM_cx], r15d
    jmp .Lf_next
.Lf_fast_end:
    mov rdi, r14
    mov esi, r15d
    call hw_mark
    mov [rbx + TM_cx], r15d
    jmp .Lf_next
.Lf_fast_slow:
    mov [rbx + TM_cx], r15d
    push rax
    push rax
    mov rdi, r14
    mov esi, r15d
    call hw_mark
    pop rax
    pop rax
.Lf_slow:
    mov edi, eax
    call put_char
    jmp .Lf_next

.Lf_seq:
    cmp ecx, S_OSC_ESC
    je .Ls_oscesc
    cmp ecx, S_STR_ESC
    je .Ls_stresc
    cmp ecx, S_OSC
    je .Ls_osc
    cmp ecx, S_STR
    je .Ls_str
    cmp eax, 0x20
    jae 1f
    # controls run inside sequences; ESC starts over, CAN and SUB cancel
    cmp eax, 0x1b
    je .Lf_esc
    cmp eax, 0x18
    je .Lf_ground
    cmp eax, 0x1a
    je .Lf_ground
    mov edi, eax
    call control
    jmp .Lf_next
1:  cmp eax, 0x7f
    je .Lf_next
    cmp ecx, S_ESC
    je .Ls_esc
    cmp ecx, S_CSI
    je .Ls_csi
    cmp ecx, S_G0
    je .Ls_g0
    cmp ecx, S_G1
    je .Ls_g1
    cmp ecx, S_HASH
    je .Lf_ground
.Lf_ground:
    mov dword ptr [rbx + TM_state], S_GROUND
    jmp .Lf_next
.Lf_esc:
    mov dword ptr [rbx + TM_state], S_ESC
    mov dword ptr [rbx + TM_inter], 0
    jmp .Lf_next
.Lf_again:
    # the byte starts something new: run it again in the current state
    dec r12
    inc r13
    jmp .Lf_next

.Ls_osc:
    cmp eax, 7
    je 2f
    cmp eax, 0x1b
    je 3f
    cmp eax, 0x20
    jb .Lf_next
    cmp qword ptr [rbx + TM_str + SB_len], MAX_OSC
    jae .Lf_next
    lea rdi, [rbx + TM_str]
    mov esi, eax
    call sb_push_byte
    jmp .Lf_next
2:  call osc_dispatch
    jmp .Lf_ground
3:  mov dword ptr [rbx + TM_state], S_OSC_ESC
    jmp .Lf_next
.Ls_oscesc:
    push rax
    push rax
    call osc_dispatch
    pop rax
    pop rax
    cmp eax, '\\'
    je .Lf_ground
    mov dword ptr [rbx + TM_state], S_ESC
    mov dword ptr [rbx + TM_inter], 0
    jmp .Lf_again
.Ls_str:
    cmp eax, 7
    je .Lf_ground
    cmp eax, 0x1b
    jne .Lf_next
    mov dword ptr [rbx + TM_state], S_STR_ESC
    jmp .Lf_next
.Ls_stresc:
    cmp eax, '\\'
    je .Lf_ground
    mov dword ptr [rbx + TM_state], S_ESC
    mov dword ptr [rbx + TM_inter], 0
    jmp .Lf_again

.Ls_g0:
    xor ecx, ecx
    cmp eax, '0'
    sete cl
    mov [rbx + TM_g0], ecx
    jmp .Lf_ground
.Ls_g1:
    xor ecx, ecx
    cmp eax, '0'
    sete cl
    mov [rbx + TM_g1], ecx
    jmp .Lf_ground

.Ls_esc:
    mov dword ptr [rbx + TM_state], S_GROUND
    cmp eax, '['
    je .Le_csi
    cmp eax, ']'
    je .Le_osc
    cmp eax, 'P'
    je .Le_str
    cmp eax, 'X'
    je .Le_str
    cmp eax, '^'
    je .Le_str
    cmp eax, '_'
    je .Le_str
    cmp eax, '('
    je .Le_g0
    cmp eax, ')'
    je .Le_g1
    cmp eax, '#'
    je .Le_hash
    cmp eax, '/'
    ja 1f
    # other intermediates (G2/G3 sets, ESC SP, ESC %): skip the byte after
    mov dword ptr [rbx + TM_state], S_SKIP
    jmp .Lf_next
1:  cmp eax, '7'
    jne 2f
    call save_cursor
    jmp .Lf_next
2:  cmp eax, '8'
    jne 3f
    call restore_cursor
    jmp .Lf_next
3:  cmp eax, 'D'
    jne 4f
    call index
    jmp .Lf_next
4:  cmp eax, 'E'
    jne 5f
    mov dword ptr [rbx + TM_cx], 0
    call index
    jmp .Lf_next
5:  cmp eax, 'M'
    jne 6f
    call rev_index
    jmp .Lf_next
6:  cmp eax, 'H'
    jne 7f
    mov rcx, [rbx + TM_tabs]
    movsxd rdx, dword ptr [rbx + TM_cx]
    mov byte ptr [rcx + rdx], 1
    jmp .Lf_next
7:  cmp eax, 'c'
    jne .Lf_next
    call full_reset
    jmp .Lf_next
.Le_csi:
    mov dword ptr [rbx + TM_state], S_CSI
    xor eax, eax
    mov [rbx + TM_np], eax
    mov [rbx + TM_colon], eax
    mov [rbx + TM_priv], eax
    mov [rbx + TM_inter], eax
    lea rdi, [rbx + TM_params]
    mov ecx, MAXP
    rep stosd
    jmp .Lf_next
.Le_osc:
    mov dword ptr [rbx + TM_state], S_OSC
    lea rdi, [rbx + TM_str]
    call sb_clear
    jmp .Lf_next
.Le_str:
    mov dword ptr [rbx + TM_state], S_STR
    jmp .Lf_next
.Le_g0:
    mov dword ptr [rbx + TM_state], S_G0
    jmp .Lf_next
.Le_g1:
    mov dword ptr [rbx + TM_state], S_G1
    jmp .Lf_next
.Le_hash:
    mov dword ptr [rbx + TM_state], S_HASH
    jmp .Lf_next

.Ls_csi:
    lea edx, [rax - '0']
    cmp edx, 9
    ja 1f
    mov ecx, [rbx + TM_np]
    test ecx, ecx
    jnz 11f
    mov ecx, 1
    mov [rbx + TM_np], ecx
11: dec ecx
    lea rsi, [rbx + TM_params]
    mov r8d, [rsi + rcx*4]
    imul r8d, r8d, 10
    add r8d, edx
    cmp r8d, 65535
    jbe 12f
    mov r8d, 65535
12: mov [rsi + rcx*4], r8d
    jmp .Lf_next
1:  cmp eax, ';'
    je 2f
    cmp eax, ':'
    jne 3f
2:  mov ecx, [rbx + TM_np]
    test ecx, ecx
    jnz 21f
    mov ecx, 1
21: cmp ecx, MAXP
    jae 22f
    inc ecx
22: mov [rbx + TM_np], ecx
    cmp eax, ':'
    jne .Lf_next
    dec ecx
    bts dword ptr [rbx + TM_colon], ecx
    jmp .Lf_next
3:  lea edx, [rax - 0x3c]
    cmp edx, 3
    ja 4f
    mov [rbx + TM_priv], eax
    jmp .Lf_next
4:  cmp eax, 0x30
    jae 5f
    mov [rbx + TM_inter], eax
    jmp .Lf_next
5:  cmp eax, 0x40
    jb .Lf_next
    mov dword ptr [rbx + TM_state], S_GROUND
    mov edi, eax
    call csi_dispatch
    jmp .Lf_next
.Lf_done:
    EPILOGUE

# control(byte): C0 control characters
control:
    cmp edi, 10
    jb 1f
    cmp edi, 12
    ja 1f
    call index
    test dword ptr [rbx + TM_modes], TMM_LNM
    jz 9f
    mov dword ptr [rbx + TM_cx], 0
    ret
1:  cmp edi, 13
    jne 2f
    mov dword ptr [rbx + TM_cx], 0
    mov dword ptr [rbx + TM_wrapnext], 0
    ret
2:  cmp edi, 8
    jne 3f
    mov dword ptr [rbx + TM_wrapnext], 0
    cmp dword ptr [rbx + TM_cx], 0
    je 9f
    dec dword ptr [rbx + TM_cx]
    ret
3:  cmp edi, 9
    je tab_forward
    cmp edi, 14
    jne 4f
    mov dword ptr [rbx + TM_gl], 1
    ret
4:  cmp edi, 15
    jne 5f
    mov dword ptr [rbx + TM_gl], 0
    ret
5:  cmp edi, 0x1b
    jne 9f
    mov dword ptr [rbx + TM_state], S_ESC
    mov dword ptr [rbx + TM_inter], 0
9:  ret

# param(i, default) -> eax; 0 and missing parameters take the default
param:
    mov eax, esi
    cmp edi, [rbx + TM_np]
    jae 1f
    mov ecx, [rbx + TM_params + rdi*4]
    test ecx, ecx
    jz 1f
    mov eax, ecx
1:  ret

# csi_dispatch(final byte)
csi_dispatch:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12d, edi
    cmp dword ptr [rbx + TM_priv], 0
    jne .Lcd_priv
    mov eax, [rbx + TM_inter]
    test eax, eax
    jnz .Lcd_inter
    lea eax, [r12 - 0x40]
    cmp eax, 0x3f
    ja .Lcd_ret
    lea rcx, [rip + csi_table]
    movsxd rax, dword ptr [rcx + rax*4]
    add rax, rcx
    jmp rax

.Lcd_inter:
    cmp eax, ' '
    jne 1f
    cmp r12d, 'q'
    jne .Lcd_ret
    xor edi, edi
    xor esi, esi
    call param
    mov [rbx + TM_cursor], eax
    jmp .Lcd_ret
1:  cmp eax, '!'
    jne .Lcd_ret
    cmp r12d, 'p'
    jne .Lcd_ret
    # soft reset
    and dword ptr [rbx + TM_modes], TMM_ALT
    or dword ptr [rbx + TM_modes], TMM_WRAP
    xor eax, eax
    mov [rbx + TM_attr], eax
    mov [rbx + TM_fg], eax
    mov [rbx + TM_bg], eax
    mov [rbx + TM_g0], eax
    mov [rbx + TM_gl], eax
    mov [rbx + TM_top], eax
    mov eax, [rbx + TM_rows]
    dec eax
    mov [rbx + TM_bot], eax
    jmp .Lcd_ret

.Lcd_priv:
    mov eax, [rbx + TM_priv]
    cmp eax, '?'
    jne .Lcd_gt
    cmp dword ptr [rbx + TM_inter], '$'
    je .Lcd_decrqm
    cmp r12d, 'u'
    je .Lcd_kk_query
    cmp r12d, 'h'
    je 1f
    cmp r12d, 'l'
    je 1f
    cmp r12d, 'J'
    je .Lcsi_ed
    cmp r12d, 'K'
    je .Lcsi_el
    jmp .Lcd_ret
1:  xor r13d, r13d
2:  cmp r13d, [rbx + TM_np]
    jae .Lcd_ret
    mov edi, [rbx + TM_params + r13*4]
    xor esi, esi
    cmp r12d, 'h'
    sete sil
    call dec_mode
    inc r13d
    jmp 2b
.Lcd_decrqm:
    # CSI ? n $ p: report whether a private mode is set
    cmp r12d, 'p'
    jne .Lcd_ret
    xor edi, edi
    xor esi, esi
    call param
    mov r13d, eax
    mov edi, eax
    call dec_mode_get
    mov r14d, eax
    lea rdi, [rip + .Lr_rqm]
    call reply_cstr
    mov edi, r13d
    call reply_num
    mov edi, ';'
    call reply_byte
    mov edi, r14d
    call reply_num
    lea rdi, [rip + .Lr_rqm_end]
    call reply_cstr
    jmp .Lcd_ret
.Lcd_gt:
    cmp eax, '>'
    jne .Lcd_lt
    cmp r12d, 'u'
    je .Lcd_kk_push
    cmp r12d, 'c'
    jne 1f
    lea rdi, [rip + .Lr_da2]
    call reply_cstr
    jmp .Lcd_ret
1:  cmp r12d, 'q'
    jne .Lcd_ret
    lea rdi, [rip + .Lr_version]
    call reply_cstr
    jmp .Lcd_ret
.Lcd_lt:
    cmp r12d, 'u'
    jne .Lcd_ret
    cmp eax, '<'
    je .Lcd_kk_pop
    cmp eax, '='
    je .Lcd_kk_set
    jmp .Lcd_ret

# kitty keyboard protocol (sw.kovidgoyal.net/kitty/keyboard-protocol): only the flags in
# KK_SUPPORTED are kept, so a query tells the program which of its requests took
.Lcd_kk_query:
    # CSI ? u: the flags in effect
    call kk_block
    mov r13d, [rax]
    lea rdi, [rip + .Lr_rqm]
    call reply_cstr
    mov edi, r13d
    call reply_num
    mov edi, 'u'
    call reply_byte
    jmp .Lcd_ret
.Lcd_kk_push:
    # CSI > flags u: keep the flags in effect, then use these; a full stack loses its oldest
    xor edi, edi
    xor esi, esi
    call param
    and eax, KK_SUPPORTED
    mov r13d, eax
    call kk_block
    mov r14, rax
    mov ecx, [r14 + 4]
    cmp ecx, KK_DEPTH
    jb 2f
    xor ecx, ecx
1:  mov eax, [r14 + 12 + rcx*4]
    mov [r14 + 8 + rcx*4], eax
    inc ecx
    cmp ecx, KK_DEPTH - 1
    jb 1b
2:  mov eax, [r14]
    mov [r14 + 8 + rcx*4], eax
    inc ecx
    mov [r14 + 4], ecx
    mov [r14], r13d
    jmp .Lcd_ret
.Lcd_kk_pop:
    # CSI < n u: undo n pushes; popping past the first leaves no flags
    xor edi, edi
    mov esi, 1
    call param
    mov r13d, eax
    call kk_block
    mov r14, rax
1:  test r13d, r13d
    jz .Lcd_ret
    mov ecx, [r14 + 4]
    test ecx, ecx
    jz 2f
    dec ecx
    mov [r14 + 4], ecx
    mov eax, [r14 + 8 + rcx*4]
    mov [r14], eax
    dec r13d
    jmp 1b
2:  mov dword ptr [r14], 0
    jmp .Lcd_ret
.Lcd_kk_set:
    # CSI = flags ; mode u: mode 1 sets them, 2 adds them, 3 removes them
    xor edi, edi
    xor esi, esi
    call param
    and eax, KK_SUPPORTED
    mov r13d, eax
    mov edi, 1
    mov esi, 1
    call param
    mov r15d, eax
    call kk_block
    cmp r15d, 2
    je 2f
    cmp r15d, 3
    je 3f
    mov [rax], r13d
    jmp .Lcd_ret
2:  or [rax], r13d
    jmp .Lcd_ret
3:  not r13d
    and [rax], r13d
    jmp .Lcd_ret

.Lcsi_ich:
    xor edi, edi
    mov esi, 1
    call param
    mov edi, eax
    call insert_blanks
    jmp .Lcd_ret
.Lcsi_cuu:
    xor edi, edi
    mov esi, 1
    call param
    mov ecx, [rbx + TM_cy]
    xor edx, edx
    cmp ecx, [rbx + TM_top]
    jl 1f
    mov edx, [rbx + TM_top]
1:  sub ecx, eax
    cmp ecx, edx
    cmovl ecx, edx
    mov [rbx + TM_cy], ecx
    mov dword ptr [rbx + TM_wrapnext], 0
    cmp r12d, 'F'
    jne .Lcd_ret
    mov dword ptr [rbx + TM_cx], 0
    jmp .Lcd_ret
.Lcsi_cud:
    xor edi, edi
    mov esi, 1
    call param
    mov ecx, [rbx + TM_cy]
    mov edx, [rbx + TM_rows]
    dec edx
    cmp ecx, [rbx + TM_bot]
    jg 1f
    mov edx, [rbx + TM_bot]
1:  add ecx, eax
    cmp ecx, edx
    cmovg ecx, edx
    mov [rbx + TM_cy], ecx
    mov dword ptr [rbx + TM_wrapnext], 0
    cmp r12d, 'E'
    jne .Lcd_ret
    mov dword ptr [rbx + TM_cx], 0
    jmp .Lcd_ret
.Lcsi_cuf:
    xor edi, edi
    mov esi, 1
    call param
    add eax, [rbx + TM_cx]
    mov ecx, [rbx + TM_cols]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov [rbx + TM_cx], eax
    mov dword ptr [rbx + TM_wrapnext], 0
    jmp .Lcd_ret
.Lcsi_cub:
    xor edi, edi
    mov esi, 1
    call param
    mov ecx, [rbx + TM_cx]
    sub ecx, eax
    jns 1f
    xor ecx, ecx
1:  mov [rbx + TM_cx], ecx
    mov dword ptr [rbx + TM_wrapnext], 0
    jmp .Lcd_ret
.Lcsi_cha:
    xor edi, edi
    mov esi, 1
    call param
    lea edi, [rax - 1]
    mov esi, [rbx + TM_cy]
    test dword ptr [rbx + TM_modes], TMM_ORIGIN
    jz 1f
    sub esi, [rbx + TM_top]
1:  call move_to
    jmp .Lcd_ret
.Lcsi_cup:
    mov edi, 1
    mov esi, 1
    call param
    mov r13d, eax
    xor edi, edi
    mov esi, 1
    call param
    lea esi, [rax - 1]
    lea edi, [r13 - 1]
    call move_to
    jmp .Lcd_ret
.Lcsi_vpa:
    xor edi, edi
    mov esi, 1
    call param
    lea esi, [rax - 1]
    mov edi, [rbx + TM_cx]
    call move_to
    jmp .Lcd_ret
.Lcsi_cht:
    xor edi, edi
    mov esi, 1
    call param
    mov r13d, eax
1:  call tab_forward
    dec r13d
    jg 1b
    jmp .Lcd_ret
.Lcsi_cbt:
    xor edi, edi
    mov esi, 1
    call param
    mov r13d, eax
1:  call tab_back
    dec r13d
    jg 1b
    jmp .Lcd_ret
.Lcsi_ed:
    xor edi, edi
    xor esi, esi
    call param
    cmp eax, 3
    jne 1f
    call ring_clear
    jmp .Lcd_ret
1:  cmp eax, 2
    jne 2f
    xor edi, edi
    mov esi, [rbx + TM_rows]
    call erase_rows
    jmp .Lcd_ret
2:  cmp eax, 1
    jne 3f
    xor edi, edi
    mov esi, [rbx + TM_cy]
    call erase_rows
    mov edi, [rbx + TM_cy]
    xor esi, esi
    mov edx, [rbx + TM_cx]
    inc edx
    call erase_cells
    jmp .Lcd_ret
3:  mov edi, [rbx + TM_cy]
    mov esi, [rbx + TM_cx]
    mov edx, [rbx + TM_cols]
    call erase_cells
    mov edi, [rbx + TM_cy]
    inc edi
    mov esi, [rbx + TM_rows]
    call erase_rows
    jmp .Lcd_ret
.Lcsi_el:
    xor edi, edi
    xor esi, esi
    call param
    mov edi, [rbx + TM_cy]
    mov esi, [rbx + TM_cx]
    mov edx, [rbx + TM_cols]
    cmp eax, 1
    jne 1f
    xor esi, esi
    mov edx, [rbx + TM_cx]
    inc edx
    jmp 2f
1:  cmp eax, 2
    jne 2f
    xor esi, esi
2:  call erase_cells
    jmp .Lcd_ret
.Lcsi_il:
    mov eax, [rbx + TM_cy]
    cmp eax, [rbx + TM_top]
    jl .Lcd_ret
    cmp eax, [rbx + TM_bot]
    jg .Lcd_ret
    xor edi, edi
    mov esi, 1
    call param
    mov edx, eax
    mov edi, [rbx + TM_cy]
    mov esi, [rbx + TM_bot]
    call scroll_down
    mov dword ptr [rbx + TM_cx], 0
    mov dword ptr [rbx + TM_wrapnext], 0
    jmp .Lcd_ret
.Lcsi_dl:
    mov eax, [rbx + TM_cy]
    cmp eax, [rbx + TM_top]
    jl .Lcd_ret
    cmp eax, [rbx + TM_bot]
    jg .Lcd_ret
    xor edi, edi
    mov esi, 1
    call param
    mov edx, eax
    mov edi, [rbx + TM_cy]
    mov esi, [rbx + TM_bot]
    xor ecx, ecx
    call scroll_up
    mov dword ptr [rbx + TM_cx], 0
    mov dword ptr [rbx + TM_wrapnext], 0
    jmp .Lcd_ret
.Lcsi_dch:
    xor edi, edi
    mov esi, 1
    call param
    mov edi, eax
    call delete_chars
    jmp .Lcd_ret
.Lcsi_su:
    xor edi, edi
    mov esi, 1
    call param
    mov edx, eax
    mov edi, [rbx + TM_top]
    mov esi, [rbx + TM_bot]
    mov ecx, 1
    call scroll_up
    jmp .Lcd_ret
.Lcsi_sd:
    cmp dword ptr [rbx + TM_np], 1
    ja .Lcd_ret
    xor edi, edi
    mov esi, 1
    call param
    mov edx, eax
    mov edi, [rbx + TM_top]
    mov esi, [rbx + TM_bot]
    call scroll_down
    jmp .Lcd_ret
.Lcsi_ech:
    xor edi, edi
    mov esi, 1
    call param
    mov edx, [rbx + TM_cx]
    add edx, eax
    mov edi, [rbx + TM_cy]
    mov esi, [rbx + TM_cx]
    call erase_cells
    mov dword ptr [rbx + TM_wrapnext], 0
    jmp .Lcd_ret
.Lcsi_rep:
    xor edi, edi
    mov esi, 1
    call param
    mov r13d, eax
    mov eax, [rbx + TM_cols]
    imul eax, [rbx + TM_rows]
    cmp r13d, eax
    cmova r13d, eax
    mov r14d, [rbx + TM_lastcp]
    test r14d, r14d
    jz .Lcd_ret
1:  mov edi, r14d
    call put_char
    dec r13d
    jg 1b
    jmp .Lcd_ret
.Lcsi_da:
    xor edi, edi
    xor esi, esi
    call param
    test eax, eax
    jnz .Lcd_ret
    lea rdi, [rip + .Lr_da]
    call reply_cstr
    jmp .Lcd_ret
.Lcsi_tbc:
    xor edi, edi
    xor esi, esi
    call param
    mov rdi, [rbx + TM_tabs]
    test eax, eax
    jnz 1f
    movsxd rcx, dword ptr [rbx + TM_cx]
    mov byte ptr [rdi + rcx], 0
    jmp .Lcd_ret
1:  cmp eax, 3
    jne .Lcd_ret
    xor eax, eax
    mov ecx, [rbx + TM_tabcap]
    rep stosb
    jmp .Lcd_ret
.Lcsi_sm:
.Lcsi_rm:
    xor r13d, r13d
1:  cmp r13d, [rbx + TM_np]
    jae .Lcd_ret
    mov eax, [rbx + TM_params + r13*4]
    mov ecx, TMM_INSERT
    cmp eax, 4
    je 2f
    mov ecx, TMM_LNM
    cmp eax, 20
    jne 3f
2:  cmp r12d, 'h'
    jne 21f
    or [rbx + TM_modes], ecx
    jmp 3f
21: not ecx
    and [rbx + TM_modes], ecx
3:  inc r13d
    jmp 1b
.Lcsi_sgr:
    call sgr
    jmp .Lcd_ret
.Lcsi_dsr:
    xor edi, edi
    xor esi, esi
    call param
    cmp eax, 5
    jne 1f
    lea rdi, [rip + .Lr_ok]
    call reply_cstr
    jmp .Lcd_ret
1:  cmp eax, 6
    jne .Lcd_ret
    lea rdi, [rip + .Lr_csi]
    call reply_cstr
    mov edi, [rbx + TM_cy]
    test dword ptr [rbx + TM_modes], TMM_ORIGIN
    jz 2f
    sub edi, [rbx + TM_top]
2:  inc edi
    call reply_num
    mov edi, ';'
    call reply_byte
    mov edi, [rbx + TM_cx]
    inc edi
    call reply_num
    mov edi, 'R'
    call reply_byte
    jmp .Lcd_ret
.Lcsi_stbm:
    xor edi, edi
    mov esi, 1
    call param
    lea r13d, [rax - 1]
    mov edi, 1
    mov esi, [rbx + TM_rows]
    call param
    dec eax
    mov ecx, [rbx + TM_rows]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    cmp r13d, eax
    jge .Lcd_ret
    mov [rbx + TM_top], r13d
    mov [rbx + TM_bot], eax
    xor edi, edi
    xor esi, esi
    call move_to
    jmp .Lcd_ret
.Lcsi_scp:
    call save_cursor
    jmp .Lcd_ret
.Lcsi_rcp:
    call restore_cursor
    jmp .Lcd_ret
.Lcsi_winops:
    xor edi, edi
    xor esi, esi
    call param
    cmp eax, 18
    jne .Lcd_ret
    lea rdi, [rip + .Lr_size]
    call reply_cstr
    mov edi, [rbx + TM_rows]
    call reply_num
    mov edi, ';'
    call reply_byte
    mov edi, [rbx + TM_cols]
    call reply_num
    mov edi, 't'
    call reply_byte
.Lcd_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    ret

# dec_mode(mode, on): CSI ? n h / l
dec_mode:
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov ecx, TMM_APPCUR
    cmp r12d, 1
    je .Ldm_bit
    mov ecx, TMM_WRAP
    cmp r12d, 7
    je .Ldm_bit
    mov ecx, TMM_FOCUS
    cmp r12d, 1004
    je .Ldm_bit
    mov ecx, TMM_SGRMOUSE
    cmp r12d, 1006
    je .Ldm_bit
    mov ecx, TMM_PASTE
    cmp r12d, 2004
    je .Ldm_bit
    mov ecx, TMM_SYNC
    cmp r12d, 2026
    je .Ldm_bit
    cmp r12d, 6
    jne 1f
    mov ecx, TMM_ORIGIN
    call .Ldm_set
    xor edi, edi
    xor esi, esi
    call move_to
    jmp 9f
1:  cmp r12d, 25
    jne 2f
    mov ecx, TMM_HIDE
    xor r13d, 1
    jmp .Ldm_bit
2:  cmp r12d, 1000
    je 21f
    cmp r12d, 1002
    je 21f
    cmp r12d, 1003
    jne 3f
21: xor eax, eax
    test r13d, r13d
    cmovnz eax, r12d
    mov [rbx + TM_mouse], eax
    jmp 9f
3:  cmp r12d, 47
    je 31f
    cmp r12d, 1047
    jne 4f
31: mov edi, r13d
    call alt_screen
    jmp 9f
4:  cmp r12d, 1048
    jne 5f
    test r13d, r13d
    jz 41f
    call save_cursor
    jmp 9f
41: call restore_cursor
    jmp 9f
5:  cmp r12d, 1049
    jne 9f
    test r13d, r13d
    jz 51f
    call save_cursor
    mov edi, 1
    call alt_screen
    jmp 9f
51: xor edi, edi
    call alt_screen
    call restore_cursor
    jmp 9f
.Ldm_bit:
    call .Ldm_set
9:  pop r14
    pop r13
    pop r12
    ret
.Ldm_set:
    test r13d, r13d
    jz 1f
    or [rbx + TM_modes], ecx
    ret
1:  not ecx
    and [rbx + TM_modes], ecx
    ret

# dec_mode_get(mode) -> 1 set, 2 reset, 0 unknown (DECRQM)
dec_mode_get:
    lea rcx, [rip + mode_bits]
1:  mov eax, [rcx]
    test eax, eax
    jz 3f
    cmp eax, edi
    je 2f
    add rcx, 8
    jmp 1b
2:  mov eax, [rcx + 4]
    test [rbx + TM_modes], eax
    mov eax, 1
    jnz 9f
    mov eax, 2
    ret
3:  xor eax, eax
    cmp edi, 25
    jne 4f
    test dword ptr [rbx + TM_modes], TMM_HIDE
    mov eax, 2
    jnz 9f
    mov eax, 1
    ret
4:  lea eax, [rdi - 1000]
    cmp eax, 3
    ja 9f
    xor eax, eax
    cmp edi, 1001
    je 9f
    mov eax, 2
    cmp edi, [rbx + TM_mouse]
    jne 9f
    mov eax, 1
9:  ret

# sgr(): CSI ... m
sgr:
    push r12
    push r13
    push r14
    xor r12d, r12d
    cmp dword ptr [rbx + TM_np], 0
    jne .Lsg_loop
    mov dword ptr [rbx + TM_np], 1
    mov dword ptr [rbx + TM_params], 0
.Lsg_loop:
    cmp r12d, [rbx + TM_np]
    jae .Lsg_ret
    mov eax, [rbx + TM_params + r12*4]
    test eax, eax
    jnz 1f
    mov [rbx + TM_attr], eax
    mov [rbx + TM_fg], eax
    mov [rbx + TM_bg], eax
    jmp .Lsg_next
1:  cmp eax, 10
    jae 2f
    # 1-9: attributes on
    lea rcx, [rip + sgr_on]
    mov ecx, [rcx + rax*4]
    cmp eax, 4
    jne 11f
    # 4:0 turns underline off
    lea edx, [r12 + 1]
    bt dword ptr [rbx + TM_colon], edx
    jnc 11f
    cmp edx, [rbx + TM_np]
    jae 11f
    inc r12d
    cmp dword ptr [rbx + TM_params + rdx*4], 0
    jne 11f
    and dword ptr [rbx + TM_attr], ~A_UNDER
    jmp .Lsg_next
11: or [rbx + TM_attr], ecx
    jmp .Lsg_next
2:  cmp eax, 21
    jne 3f
    or dword ptr [rbx + TM_attr], A_UNDER
    jmp .Lsg_next
3:  cmp eax, 30
    jae 4f
    cmp eax, 22
    jb .Lsg_next
    # 22-29: attributes off
    lea rcx, [rip + sgr_off]
    mov ecx, [rcx + rax*4 - 22*4]
    not ecx
    and [rbx + TM_attr], ecx
    jmp .Lsg_next
4:  cmp eax, 38
    jae 5f
    sub eax, 30
    or eax, TC_IDX
    mov [rbx + TM_fg], eax
    jmp .Lsg_next
5:  jne 6f
    call ext_color
    mov [rbx + TM_fg], eax
    jmp .Lsg_next
6:  cmp eax, 39
    jne 7f
    mov dword ptr [rbx + TM_fg], 0
    jmp .Lsg_next
7:  cmp eax, 48
    jae 8f
    cmp eax, 40
    jb .Lsg_next
    sub eax, 40
    or eax, TC_IDX
    mov [rbx + TM_bg], eax
    jmp .Lsg_next
8:  jne 81f
    call ext_color
    mov [rbx + TM_bg], eax
    jmp .Lsg_next
81: cmp eax, 49
    jne 82f
    mov dword ptr [rbx + TM_bg], 0
    jmp .Lsg_next
82: cmp eax, 58
    jne 83f
    call ext_color              # underline color: parsed, not drawn
    jmp .Lsg_next
83: cmp eax, 90
    jb .Lsg_next
    cmp eax, 97
    ja 84f
    sub eax, 90 - 8
    or eax, TC_IDX
    mov [rbx + TM_fg], eax
    jmp .Lsg_next
84: cmp eax, 100
    jb .Lsg_next
    cmp eax, 107
    ja .Lsg_next
    sub eax, 100 - 8
    or eax, TC_IDX
    mov [rbx + TM_bg], eax
.Lsg_next:
    inc r12d
    jmp .Lsg_loop
.Lsg_ret:
    pop r14
    pop r13
    pop r12
    ret

# ext_color(): 38/48/58 ; 5 ; n  or  ; 2 ; r ; g ; b (also with ':' and a color space) -> eax, r12d moves on
ext_color:
    lea edx, [r12 + 1]
    cmp edx, [rbx + TM_np]
    jae 8f
    mov eax, [rbx + TM_params + rdx*4]
    cmp eax, 5
    jne 1f
    lea ecx, [rdx + 1]
    cmp ecx, [rbx + TM_np]
    jae 8f
    mov r12d, ecx
    movzx eax, byte ptr [rbx + TM_params + rcx*4]
    or eax, TC_IDX
    ret
1:  cmp eax, 2
    jne 7f
    lea ecx, [rdx + 1]          # r
    bt dword ptr [rbx + TM_colon], ecx
    jnc 2f
    # 38:2:cs:r:g:b has four more sub-parameters
    lea r8d, [rdx + 4]
    cmp r8d, [rbx + TM_np]
    jae 2f
    bt dword ptr [rbx + TM_colon], r8d
    jnc 2f
    inc ecx
2:  lea r8d, [rcx + 2]
    cmp r8d, [rbx + TM_np]
    jae 8f
    mov r12d, r8d
    movzx eax, byte ptr [rbx + TM_params + rcx*4]
    shl eax, 8
    mov r9d, ecx
    movzx ecx, byte ptr [rbx + TM_params + r9*4 + 4]
    or eax, ecx
    shl eax, 8
    movzx ecx, byte ptr [rbx + TM_params + r9*4 + 8]
    or eax, ecx
    or eax, TC_RGB
    ret
7:  mov r12d, edx
    xor eax, eax
    ret
8:  mov r12d, [rbx + TM_np]
    xor eax, eax
    ret

# osc_dispatch(): OSC number ; text
osc_dispatch:
    push r12
    push r13
    push r14
    mov r12, [rbx + TM_str + SB_ptr]
    mov r13, [rbx + TM_str + SB_len]
    test r12, r12
    jz 9f
    mov rdi, r12
    mov rsi, r13
    call parse_u64
    test rdx, rdx
    jz 9f
    cmp rdx, r13
    jae 9f
    cmp byte ptr [r12 + rdx], ';'
    jne 9f
    mov r14d, eax
    lea r12, [r12 + rdx + 1]
    sub r13, rdx
    dec r13
    cmp r14d, 0
    je 1f
    cmp r14d, 2
    jne 2f
1:  lea rdi, [rbx + TM_title]
    call sb_clear
    lea rdi, [rbx + TM_title]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rbx + TM_title]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rbx + TM_title + SB_len]
    jmp 9f
2:  # 10, 11, 12 ; ? : colors of the text, background and cursor
    lea eax, [r14 - 10]
    cmp eax, 2
    ja 9f
    cmp r13, 1
    jne 9f
    cmp byte ptr [r12], '?'
    jne 9f
    lea rcx, [rip + osc_slots]
    mov eax, [rcx + rax*4]
    lea rcx, [rip + g_theme]
    mov r12d, [rcx + rax*4]
    lea rdi, [rip + .Lr_osc]
    call reply_cstr
    mov edi, r14d
    call reply_num
    lea rdi, [rip + .Lr_rgb]
    call reply_cstr
    mov r13d, 16
3:  mov eax, r12d
    mov ecx, r13d
    shr eax, cl
    movzx eax, al
    imul eax, eax, 0x101
    sub rsp, 16
    mov rdi, rsp
    mov esi, eax
    call fmt_hex4
    lea rdi, [rbx + TM_out]
    mov rsi, rsp
    mov edx, 4
    call sb_push
    add rsp, 16
    test r13d, r13d
    jz 4f
    mov edi, '/'
    call reply_byte
    sub r13d, 8
    jmp 3b
4:  lea rdi, [rip + .Lr_st]
    call reply_cstr
9:  lea rdi, [rbx + TM_str]
    call sb_clear
    pop r14
    pop r13
    pop r12
    ret

# fmt_hex4(buf, value): four lowercase hex digits
fmt_hex4:
    mov ecx, 12
    lea r8, [rip + hexdigits]
1:  mov eax, esi
    shr eax, cl
    and eax, 15
    mov al, [r8 + rax]
    mov [rdi], al
    inc rdi
    sub ecx, 4
    jns 1b
    ret

# ---------------- size ----------------

# term_resize(t, cols, rows)
FN term_resize
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    cmp r12d, 2
    jge 1f
    mov r12d, 2
1:  cmp r13d, 1
    jge 2f
    mov r13d, 1
2:  cmp r12d, [rbx + TM_cols]
    jne 3f
    cmp r13d, [rbx + TM_rows]
    je .Lrs_ret
3:  # rows: the main screen keeps the cursor's line, trading lines with scrollback
    mov r14d, [rbx + TM_modes]
    and r14d, TMM_ALT
    lea r15, [rbx + TM_lines]   # main screen slot
    lea rax, [rbx + TM_other]
    test r14d, r14d
    cmovnz r15, rax
    lea rcx, [rbx + TM_cy]
    lea rax, [rbx + TM_scy]
    cmovnz rcx, rax             # the main screen's cursor row
    mov [rsp], rcx
    mov rdi, [r15]
    mov esi, r13d
    mov rdx, rcx
    mov ecx, 1
    call screen_rows
    mov [r15], rax
    # the other screen keeps its top
    lea r15, [rbx + TM_other]
    lea rax, [rbx + TM_lines]
    test r14d, r14d
    cmovnz r15, rax
    mov rdi, [r15]
    mov esi, r13d
    xor edx, edx
    xor ecx, ecx
    call screen_rows
    mov [r15], rax
    mov [rbx + TM_rows], r13d
    # columns: lines only grow
    mov [rbx + TM_cols], r12d
    mov rdi, [rbx + TM_lines]
    call screen_fit
    mov rdi, [rbx + TM_other]
    call screen_fit
    call tabs_reset
    mov dword ptr [rbx + TM_top], 0
    lea eax, [r13 - 1]
    mov [rbx + TM_bot], eax
    mov dword ptr [rbx + TM_wrapnext], 0
    mov dword ptr [rbx + TM_view], 0
    lea ecx, [r12 - 1]
    lea edx, [r13 - 1]
    lea r8, [rbx + TM_cx]
    call clamp_pos
    lea r8, [rbx + TM_scx]
    call clamp_pos
.Lrs_ret:
    EPILOGUE
# clamp_pos: [r8] col, [r8 + 4] row into ecx, edx
clamp_pos:
    mov eax, [r8]
    cmp eax, ecx
    cmovg eax, ecx
    mov [r8], eax
    mov eax, [r8 + 4]
    cmp eax, edx
    cmovg eax, edx
    test eax, eax
    jns 1f
    xor eax, eax
1:  mov [r8 + 4], eax
    ret

# screen_rows(lines, new rows, cursor row ptr or 0, main) -> new lines array
#   TM_rows is still the old count. The main screen drops lines above the cursor into scrollback
#   when shrinking and takes them back when growing.
screen_rows:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov r12, rdi
    mov r13d, esi
    mov [rsp], rdx
    mov [rsp + 8], ecx
    lea rdi, [r13*8 + 8]
    call mem_alloc
    mov r14, rax
    mov r15d, [rbx + TM_rows]
    cmp r13d, r15d
    jge .Lsr_grow
    # shrink: k lines off the top so the cursor row stays, the rest off the bottom
    xor ecx, ecx
    mov rdx, [rsp]
    test rdx, rdx
    jz 1f
    mov ecx, [rdx]
    inc ecx
    sub ecx, r13d
    jns 1f
    xor ecx, ecx
1:  mov [rsp + 12], ecx         # k
    xor eax, eax
    mov [rsp + 16], eax         # i
2:  mov eax, [rsp + 16]
    cmp eax, r15d
    jae 5f
    mov rdi, [r12 + rax*8]
    cmp eax, [rsp + 12]
    jae 3f
    cmp dword ptr [rsp + 8], 0
    je 4f
    call ring_add
    jmp 41f
3:  mov ecx, eax
    sub ecx, [rsp + 12]
    cmp ecx, r13d
    jae 4f
    mov [r14 + rcx*8], rdi
    jmp 41f
4:  call mem_free
41: inc dword ptr [rsp + 16]
    jmp 2b
5:  mov rdx, [rsp]
    test rdx, rdx
    jz .Lsr_done
    mov eax, [rsp + 12]
    sub [rdx], eax
    jmp .Lsr_done
.Lsr_grow:
    # pull lines back from scrollback above the old ones
    xor ecx, ecx
    cmp dword ptr [rsp + 8], 0
    je 1f
    mov ecx, r13d
    sub ecx, r15d
    cmp ecx, [rbx + TM_sblen]
    jbe 1f
    mov ecx, [rbx + TM_sblen]
1:  mov [rsp + 12], ecx         # p
    mov [rsp + 16], ecx
2:  cmp dword ptr [rsp + 16], 0
    je 3f
    call ring_pop
    mov ecx, [rsp + 16]
    dec ecx
    mov [rsp + 16], ecx
    mov [r14 + rcx*8], rax
    jmp 2b
3:  xor ecx, ecx
4:  cmp ecx, r15d
    jae 5f
    mov rax, [r12 + rcx*8]
    mov edx, ecx
    add edx, [rsp + 12]
    mov [r14 + rdx*8], rax
    inc ecx
    jmp 4b
5:  mov eax, r15d
    add eax, [rsp + 12]
    mov [rsp + 16], eax
6:  mov eax, [rsp + 16]
    cmp eax, r13d
    jae 7f
    call line_new
    mov ecx, [rsp + 16]
    mov [r14 + rcx*8], rax
    inc dword ptr [rsp + 16]
    jmp 6b
7:  mov rdx, [rsp]
    test rdx, rdx
    jz .Lsr_done
    mov eax, [rsp + 12]
    add [rdx], eax
.Lsr_done:
    mov rdi, r12
    call mem_free
    mov rax, r14
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

# screen_fit(lines): every line has room for TM_cols cells
screen_fit:
    push r12
    push r13
    push r14
    mov r12, rdi
    xor r13d, r13d
1:  cmp r13d, [rbx + TM_rows]
    jae 2f
    mov rdi, [r12 + r13*8]
    call line_fit
    mov [r12 + r13*8], rax
    inc r13d
    jmp 1b
2:  pop r14
    pop r13
    pop r12
    ret

# term_clear(t): drop the scrollback and everything above the cursor's line, which moves to the top
FN term_clear
    PROLOGUE
    mov rbx, rdi
    test dword ptr [rbx + TM_modes], TMM_ALT
    jnz 9f
    xor edi, edi
    mov esi, [rbx + TM_rows]
    dec esi
    mov edx, [rbx + TM_cy]
    xor ecx, ecx
    call scroll_up
    mov dword ptr [rbx + TM_cy], 0
    call ring_clear
9:  EPILOGUE

# ---------------- queries ----------------

# term_row(t, row) -> line; negative rows are scrollback (-1 the newest), 0 when out of range
FN term_row
    test esi, esi
    js 1f
    cmp esi, [rdi + TM_rows]
    jge 2f
    mov rax, [rdi + TM_lines]
    movsxd rsi, esi
    mov rax, [rax + rsi*8]
    ret
1:  mov eax, [rdi + TM_sblen]
    add eax, esi
    js 2f
    add eax, [rdi + TM_sbhead]
    xor edx, edx
    div dword ptr [rdi + TM_sbcap]
    mov rax, [rdi + TM_sb]
    mov rax, [rax + rdx*8]
    ret
2:  xor eax, eax
    ret

# term_text(t, sb, row0, col0, row1, col1): text of the cells from (row0, col0) up to (row1, col1),
#   rows as in term_row; wrapped lines join, trailing blanks of a line are dropped
FN term_text
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx              # row
    mov [rsp + 4], ecx          # col0
    mov [rsp + 8], r8d          # row1
    mov [rsp + 12], r9d         # col1
.Ltt_row:
    mov eax, [rsp]
    cmp eax, [rsp + 8]
    jg .Ltt_done
    mov rdi, rbx
    mov esi, eax
    call term_row
    test rax, rax
    jz .Ltt_nl
    mov r13, rax
    # columns [c0, c1) of this row; only the first row starts at col0
    mov r14d, [rsp + 4]
    mov dword ptr [rsp + 4], 0
    mov r15d, [rbx + TM_cols]
    mov eax, [rsp]
    cmp eax, [rsp + 8]
    jne 1f
    mov r15d, [rsp + 12]
1:  cmp r15d, [r13 + LN_cap]
    jle 2f
    mov r15d, [r13 + LN_cap]
2:  # trailing blanks, except where the line wraps on
    mov ecx, r15d
    cmp eax, [rsp + 8]
    jge 4f
    test dword ptr [r13 + LN_flags], LF_WRAPPED
    jnz 5f
4:  cmp ecx, r14d
    jle 5f
    lea eax, [rcx - 1]
    CELLP rdx, r13, rax
    mov edx, [rdx]
    and edx, CP_MASK
    cmp edx, ' '
    ja 5f
    dec ecx
    jmp 4b
5:  mov [rsp + 16], ecx         # end of text
6:  cmp r14d, [rsp + 16]
    jge 7f
    CELLP rdx, r13, r14
    mov eax, [rdx]
    inc r14d
    test eax, A_WIDE2
    jnz 6b
    and eax, CP_MASK
    cmp eax, ' '
    jae 61f
    mov eax, ' '
61: mov rdi, r12
    mov esi, eax
    call sb_push_utf8
    jmp 6b
7:  # newline unless the line wraps into the next one
    mov eax, [rsp]
    cmp eax, [rsp + 8]
    jge .Ltt_done
    test dword ptr [r13 + LN_flags], LF_WRAPPED
    jnz .Ltt_next
.Ltt_nl:
    mov eax, [rsp]
    cmp eax, [rsp + 8]
    jge .Ltt_done
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
.Ltt_next:
    inc dword ptr [rsp]
    jmp .Ltt_row
.Ltt_done:
    EPILOGUE

# term_dump(t, sb): each row of the screen as a line of text, then "cursor ROW,COL"
FN term_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13d, [rbx + TM_rows]
    jae 2f
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    xor ecx, ecx
    mov r8d, r13d
    mov r9d, [rbx + TM_cols]
    call term_text
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    inc r13d
    jmp 1b
2:  mov rdi, r12
    lea rsi, [rip + .Ld_cursor]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + TM_cy]
    call sb_push_u64
    mov rdi, r12
    mov esi, ','
    call sb_push_byte
    mov rdi, r12
    mov esi, [rbx + TM_cx]
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# ---------------- input ----------------

# term_key(t, keysym, cp, mods) -> 1 when the key was turned into bytes for the program (in TM_out)
FN term_key
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    # xterm modifier parameter: 1 + shift + 2 alt + 4 ctrl
    mov r15d, 1
    test r14d, MOD_SHIFT
    jz 1f
    inc r15d
1:  test r14d, MOD_ALT
    jz 2f
    add r15d, 2
2:  test r14d, MOD_CTRL
    jz 3f
    add r15d, 4
3:  call kk_block
    mov eax, [rax]
    mov [rsp], eax
    lea rcx, [rip + key_seqs]
4:  mov eax, [rcx]
    test eax, eax
    jz .Lk_plain
    cmp eax, r12d
    je .Lk_special
    add rcx, 8
    jmp 4b
.Lk_special:
    movzx eax, byte ptr [rcx + 4]   # kind
    movzx r13d, byte ptr [rcx + 5]  # letter or number
    cmp eax, 1
    je .Lk_tilde
    cmp r15d, 1
    jne .Lk_modletter
    # SS3 for F1-F4, and for cursor keys in application mode
    cmp eax, 2
    je 5f
    test dword ptr [rbx + TM_modes], TMM_APPCUR
    jz 6f
5:  lea rdi, [rip + .Lk_ss3]
    call reply_cstr
    jmp 7f
6:  lea rdi, [rip + .Lr_csi]
    call reply_cstr
7:  mov edi, r13d
    call reply_byte
    jmp .Lk_yes
.Lk_modletter:
    lea rdi, [rip + .Lk_csi1]
    call reply_cstr
    mov edi, r15d
    call reply_num
    mov edi, r13d
    call reply_byte
    jmp .Lk_yes
.Lk_tilde:
    lea rdi, [rip + .Lr_csi]
    call reply_cstr
    mov edi, r13d
    call reply_num
    cmp r15d, 1
    je 1f
    mov edi, ';'
    call reply_byte
    mov edi, r15d
    call reply_num
1:  mov edi, '~'
    call reply_byte
    jmp .Lk_yes
.Lk_plain:
    # disambiguated (kitty flag 1): Escape, modified Enter, Tab and Backspace, and a character with
    # ctrl or alt become CSI code ; modifiers u. Plain Enter, Tab and Backspace stay as they were.
    test dword ptr [rsp], 1
    jz .Lk_legacy
    mov eax, r12d
    mov ecx, 27
    cmp eax, KEY_ESCAPE
    je .Lk_csiu
    mov ecx, 13
    cmp eax, KEY_RETURN
    je 1f
    cmp eax, KEY_KP_ENTER
    je 1f
    mov ecx, 9
    cmp eax, KEY_TAB
    je 1f
    cmp eax, KEY_ISO_LEFT_TAB
    je 1f
    mov ecx, 127
    cmp eax, KEY_BACKSPACE
    je 1f
    test r13d, r13d
    jz .Lk_legacy
    test r14d, MOD_CTRL | MOD_ALT
    jz .Lk_legacy
    # the key's own codepoint: unshifted (a letter in lower case, 2 for Ctrl+Shift+2 where the platform
    # tells the key's base character)
    mov ecx, [rip + g_key_base]
    test ecx, ecx
    jnz 15f
    mov ecx, r13d
15: lea eax, [rcx - 'A']
    cmp eax, 25
    ja .Lk_csiu
    add ecx, 32
    jmp .Lk_csiu
1:  cmp r15d, 1
    je .Lk_legacy
.Lk_csiu:
    mov [rsp + 4], ecx
    lea rdi, [rip + .Lr_csi]
    call reply_cstr
    mov edi, [rsp + 4]
    call reply_num
    cmp r15d, 1
    je 2f
    mov edi, ';'
    call reply_byte
    mov edi, r15d
    call reply_num
2:  mov edi, 'u'
    call reply_byte
    jmp .Lk_yes
.Lk_legacy:
    mov eax, r12d
    cmp eax, KEY_RETURN
    je 1f
    cmp eax, KEY_KP_ENTER
    jne 2f
1:  mov r13d, 13
    jmp .Lk_char
2:  cmp eax, KEY_BACKSPACE
    jne 3f
    mov r13d, 0x7f
    test r14d, MOD_CTRL
    jz .Lk_char
    mov r13d, 8
    jmp .Lk_char
3:  cmp eax, KEY_TAB
    je 31f
    cmp eax, KEY_ISO_LEFT_TAB
    jne 4f
31: test r14d, MOD_SHIFT
    jnz 32f
    mov r13d, 9
    jmp .Lk_char
32: lea rdi, [rip + .Lk_backtab]
    call reply_cstr
    jmp .Lk_yes
4:  cmp eax, KEY_ESCAPE
    jne 5f
    mov r13d, 0x1b
    jmp .Lk_char
5:  test r13d, r13d
    jz .Lk_no
    cmp r13d, 0x7f
    je .Lk_char
    cmp r13d, 0x20
    jb .Lk_char
    # control characters
    test r14d, MOD_CTRL
    jz .Lk_char
    mov eax, r13d
    or eax, 0x20
    lea ecx, [rax - 'a']
    cmp ecx, 25
    ja 6f
    lea r13d, [rcx + 1]
    jmp .Lk_char
6:  lea rcx, [rip + ctrl_chars]
7:  movzx eax, byte ptr [rcx]
    test eax, eax
    jz .Lk_char
    cmp eax, r13d
    je 8f
    add rcx, 2
    jmp 7b
8:  movzx r13d, byte ptr [rcx + 1]
.Lk_char:
    # alt sends ESC first
    test r14d, MOD_ALT
    jz 1f
    mov edi, 0x1b
    call reply_byte
1:  lea rdi, [rbx + TM_out]
    mov esi, r13d
    call sb_push_utf8
.Lk_yes:
    mov eax, 1
    EPILOGUE
.Lk_no:
    xor eax, eax
    EPILOGUE

# term_paste(t, ptr, len): pasted text, bracketed when the program asked for it; newlines become Enter
FN term_paste
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test dword ptr [rbx + TM_modes], TMM_PASTE
    jz 1f
    lea rdi, [rip + .Lp_start]
    call reply_cstr
1:  xor r14d, r14d
2:  cmp r14, r13
    jae 5f
    movzx esi, byte ptr [r12 + r14]
    inc r14
    cmp esi, 0x1b
    je 2b
    cmp esi, 13
    jne 3f
    cmp r14, r13
    jae 3f
    cmp byte ptr [r12 + r14], 10
    je 2b
3:  cmp esi, 10
    jne 4f
    mov esi, 13
4:  lea rdi, [rbx + TM_out]
    call sb_push_byte
    jmp 2b
5:  test dword ptr [rbx + TM_modes], TMM_PASTE
    jz 9f
    lea rdi, [rip + .Lp_end]
    call reply_cstr
9:  EPILOGUE

# term_write(t, ptr, len): bytes typed into the program as they are (no bracketed paste; LF is
# Enter, as a key would send it)
FN term_write
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, r13
    jae 9f
    movzx esi, byte ptr [r12 + r14]
    inc r14
    cmp esi, 10
    jne 2f
    mov esi, 13
2:  lea rdi, [rbx + TM_out]
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# term_mouse(t, button, kind, col, row, mods) -> 1 if the program gets the event
#   button 0 left, 1 middle, 2 right, 3 none, 64/65 wheel; kind 0 press, 1 release, 2 motion
FN term_mouse
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    mov eax, [rbx + TM_mouse]
    test eax, eax
    jz .Lm_no
    cmp r13d, 2
    jne 1f
    cmp eax, 1000
    je .Lm_no
    cmp eax, 1002
    jne 11f
    cmp r12d, 3
    je .Lm_no
11: add r12d, 32
1:  test r9d, MOD_SHIFT
    jz 2f
    add r12d, 4
2:  test r9d, MOD_ALT
    jz 3f
    add r12d, 8
3:  test r9d, MOD_CTRL
    jz 4f
    add r12d, 16
4:  test dword ptr [rbx + TM_modes], TMM_SGRMOUSE
    jz .Lm_x10
    lea rdi, [rip + .Lm_sgr]
    call reply_cstr
    mov edi, r12d
    call reply_num
    mov edi, ';'
    call reply_byte
    lea edi, [r14 + 1]
    call reply_num
    mov edi, ';'
    call reply_byte
    lea edi, [r15 + 1]
    call reply_num
    mov edi, 'M'
    cmp r13d, 1
    jne 5f
    mov edi, 'm'
5:  call reply_byte
    mov eax, 1
    EPILOGUE
.Lm_x10:
    cmp r13d, 1
    jne 1f
    and r12d, ~3
    or r12d, 3
1:  lea rdi, [rip + .Lm_x10s]
    call reply_cstr
    lea edi, [r12 + 32]
    call reply_byte
    mov edi, r14d
    cmp edi, 222
    jbe 2f
    mov edi, 222
2:  add edi, 33
    call reply_byte
    mov edi, r15d
    cmp edi, 222
    jbe 3f
    mov edi, 222
3:  add edi, 33
    call reply_byte
    mov eax, 1
    EPILOGUE
.Lm_no:
    xor eax, eax
    EPILOGUE

.section .rodata
.Lr_da: .asciz "\033[?62;22c"
.Lr_da2: .asciz "\033[>1;10;0c"
.Lr_version: .asciz "\033P>|rhun\033\\"
.Lr_ok: .asciz "\033[0n"
.Lr_csi: .asciz "\033["
.Lr_size: .asciz "\033[8;"
.Lr_rqm: .asciz "\033[?"
.Lr_rqm_end: .asciz "$y"
.Lr_osc: .asciz "\033]"
.Lr_rgb: .asciz ";rgb:"
.Lr_st: .asciz "\033\\"
.Lk_ss3: .asciz "\033O"
.Lk_csi1: .asciz "\033[1;"
.Lk_backtab: .asciz "\033[Z"
.Lp_start: .asciz "\033[200~"
.Lp_end: .asciz "\033[201~"
.Lm_sgr: .asciz "\033[<"
.Lm_x10s: .asciz "\033[M"
.Ld_cursor: .asciz "cursor "
# ctrl + character -> control code
ctrl_chars: .byte ' ', 0, '@', 0, '2', 0, '[', 27, '3', 27, '\\', 28, '4', 28, ']', 29, '5', 29
    .byte '^', 30, '6', 30, '_', 31, '-', 31, '7', 31, '/', 31, '8', 127, '?', 127, 0, 0
.p2align 2
# keysym, kind (0 CSI/SS3 letter, 1 CSI number ~, 2 SS3 letter), letter or number
key_seqs:
    .long KEY_UP
    .byte 0, 'A', 0, 0
    .long KEY_DOWN
    .byte 0, 'B', 0, 0
    .long KEY_RIGHT
    .byte 0, 'C', 0, 0
    .long KEY_LEFT
    .byte 0, 'D', 0, 0
    .long KEY_HOME
    .byte 0, 'H', 0, 0
    .long KEY_END
    .byte 0, 'F', 0, 0
    .long KEY_INSERT
    .byte 1, 2, 0, 0
    .long KEY_DELETE
    .byte 1, 3, 0, 0
    .long KEY_PAGEUP
    .byte 1, 5, 0, 0
    .long KEY_PAGEDOWN
    .byte 1, 6, 0, 0
    .long KEY_F1
    .byte 2, 'P', 0, 0
    .long KEY_F1 + 1
    .byte 2, 'Q', 0, 0
    .long KEY_F1 + 2
    .byte 2, 'R', 0, 0
    .long KEY_F1 + 3
    .byte 2, 'S', 0, 0
    .long KEY_F1 + 4
    .byte 1, 15, 0, 0
    .long KEY_F1 + 5
    .byte 1, 17, 0, 0
    .long KEY_F1 + 6
    .byte 1, 18, 0, 0
    .long KEY_F1 + 7
    .byte 1, 19, 0, 0
    .long KEY_F1 + 8
    .byte 1, 20, 0, 0
    .long KEY_F1 + 9
    .byte 1, 21, 0, 0
    .long KEY_F1 + 10
    .byte 1, 23, 0, 0
    .long KEY_F1 + 11
    .byte 1, 24, 0, 0
    .long 0, 0
# SGR 1..9 on, 22..29 off
sgr_on: .long 0, A_BOLD, A_DIM, A_ITALIC, A_UNDER, A_BLINK, A_BLINK, A_INVERSE, A_HIDDEN, A_STRIKE
sgr_off: .long A_BOLD | A_DIM, A_ITALIC, A_UNDER, A_BLINK, 0, A_INVERSE, A_HIDDEN, A_STRIKE
# DECRQM: private mode -> bit
mode_bits:
    .long 1, TMM_APPCUR, 6, TMM_ORIGIN, 7, TMM_WRAP, 1049, TMM_ALT, 47, TMM_ALT, 1047, TMM_ALT
    .long 1004, TMM_FOCUS, 1006, TMM_SGRMOUSE, 2004, TMM_PASTE, 2026, TMM_SYNC, 0, 0
osc_slots: .long T_FG, T_BG, T_CURSOR
# characters drawn in the previous cell's space
zero_ranges:
    .long 0x0300, 0x036f, 0x0483, 0x0489, 0x0591, 0x05bd, 0x0610, 0x061a, 0x064b, 0x065f
    .long 0x200b, 0x200f, 0x20d0, 0x20ff, 0x1ab0, 0x1aff, 0x1dc0, 0x1dff, 0xfe00, 0xfe0f
    .long 0xfe20, 0xfe2f, 0x1f3fb, 0x1f3ff, 0xe0100, 0xe01ef, 0, 0
# DEC special graphics for 0x5f..0x7e
dec_graphics:
    .short 0x00a0, 0x25c6, 0x2592, 0x2409, 0x240c, 0x240d, 0x240a, 0x00b0
    .short 0x00b1, 0x2424, 0x240b, 0x2518, 0x2510, 0x250c, 0x2514, 0x253c
    .short 0x23ba, 0x23bb, 0x2500, 0x23bc, 0x23bd, 0x251c, 0x2524, 0x2534
    .short 0x252c, 0x2502, 0x2264, 0x2265, 0x03c0, 0x2260, 0x00a3, 0x00b7
# CSI final byte 0x40..0x7f -> handler
.macro CSI_ENTRY lbl
    .long \lbl - csi_table
.endm
csi_table:
    CSI_ENTRY .Lcsi_ich        # @
    CSI_ENTRY .Lcsi_cuu        # A
    CSI_ENTRY .Lcsi_cud        # B
    CSI_ENTRY .Lcsi_cuf        # C
    CSI_ENTRY .Lcsi_cub        # D
    CSI_ENTRY .Lcsi_cud        # E
    CSI_ENTRY .Lcsi_cuu        # F
    CSI_ENTRY .Lcsi_cha        # G
    CSI_ENTRY .Lcsi_cup        # H
    CSI_ENTRY .Lcsi_cht        # I
    CSI_ENTRY .Lcsi_ed         # J
    CSI_ENTRY .Lcsi_el         # K
    CSI_ENTRY .Lcsi_il         # L
    CSI_ENTRY .Lcsi_dl         # M
    CSI_ENTRY .Lcd_ret         # N
    CSI_ENTRY .Lcd_ret         # O
    CSI_ENTRY .Lcsi_dch        # P
    CSI_ENTRY .Lcd_ret         # Q
    CSI_ENTRY .Lcd_ret         # R
    CSI_ENTRY .Lcsi_su         # S
    CSI_ENTRY .Lcsi_sd         # T
    CSI_ENTRY .Lcd_ret         # U
    CSI_ENTRY .Lcd_ret         # V
    CSI_ENTRY .Lcd_ret         # W
    CSI_ENTRY .Lcsi_ech        # X
    CSI_ENTRY .Lcd_ret         # Y
    CSI_ENTRY .Lcsi_cbt        # Z
    CSI_ENTRY .Lcd_ret         # [
    CSI_ENTRY .Lcd_ret         # backslash
    CSI_ENTRY .Lcd_ret         # ]
    CSI_ENTRY .Lcd_ret         # ^
    CSI_ENTRY .Lcd_ret         # _
    CSI_ENTRY .Lcsi_cha        # `
    CSI_ENTRY .Lcsi_cuf        # a
    CSI_ENTRY .Lcsi_rep        # b
    CSI_ENTRY .Lcsi_da         # c
    CSI_ENTRY .Lcsi_vpa        # d
    CSI_ENTRY .Lcsi_cud        # e
    CSI_ENTRY .Lcsi_cup        # f
    CSI_ENTRY .Lcsi_tbc        # g
    CSI_ENTRY .Lcsi_sm         # h
    CSI_ENTRY .Lcd_ret         # i
    CSI_ENTRY .Lcd_ret         # j
    CSI_ENTRY .Lcd_ret         # k
    CSI_ENTRY .Lcsi_rm         # l
    CSI_ENTRY .Lcsi_sgr        # m
    CSI_ENTRY .Lcsi_dsr        # n
    CSI_ENTRY .Lcd_ret         # o
    CSI_ENTRY .Lcd_ret         # p
    CSI_ENTRY .Lcd_ret         # q
    CSI_ENTRY .Lcsi_stbm       # r
    CSI_ENTRY .Lcsi_scp        # s
    CSI_ENTRY .Lcsi_winops     # t
    CSI_ENTRY .Lcsi_rcp        # u
    CSI_ENTRY .Lcd_ret         # v
    CSI_ENTRY .Lcd_ret         # w
    CSI_ENTRY .Lcd_ret         # x
    CSI_ENTRY .Lcd_ret         # y
    CSI_ENTRY .Lcd_ret         # z
    CSI_ENTRY .Lcd_ret         # {
    CSI_ENTRY .Lcd_ret         # |
    CSI_ENTRY .Lcd_ret         # }
    CSI_ENTRY .Lcd_ret         # ~
    CSI_ENTRY .Lcd_ret         # DEL
