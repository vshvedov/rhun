# debug console: the output of debug sessions as lines with a category (the program's stdout and
# stderr, the adapter's messages, rhun's own notes), at most [debug] console_lines of them
.include "rhun.inc"

STRUCT
F CL_off, 8             # into ctext
F CL_len, 4
F CL_cat, 2
F CL_open, 2            # 1: the text did not end with a newline; more may join it
F CL_sid, 4
F CL_pad, 4
ENDSTRUCT CL_SIZE

.bss
.p2align 3
clines: .zero VEC_SIZE
ctext: .zero SB_SIZE
clean: .zero SB_SIZE
.globl g_dcon_max, g_dcon_gen, g_dcon_reset
g_dcon_gen: .long 0             # bumped on every change (drawing)
g_dcon_reset: .long 0           # bumped when lines go (Clear, the cap): their indexes change
.data
g_dcon_max: .long 10000         # [debug] console_lines

.text

# dcon_text(session id, category, ptr, len): text that may hold several lines; a piece after the last
#   newline stays open, and the next text of the same session and category continues it
FN dcon_text
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov r12, rdx
    lea r13, [rdx + rcx]
1:  cmp r12, r13
    jae 9f
    mov rcx, r12
2:  cmp rcx, r13
    jae 3f
    cmp byte ptr [rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  mov r14, rcx
    xor r15d, r15d              # 1: ended by a newline
    cmp r14, r13
    jae 4f
    mov r15d, 1
4:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov rdx, r12
    mov rcx, r14
    sub rcx, r12
    jz 5f                       # an empty piece: only a newline closes the open line
    test rcx, rcx
    cmp byte ptr [rdx + rcx - 1], 13
    jne 41f
    dec rcx
41: mov r8d, r15d
    xor r8d, 1                  # open when no newline ended it
    call add_piece
    jmp 6f
5:  test r15d, r15d
    jz 6f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    call close_open
6:  lea r12, [r14 + 1]
    jmp 1b
9:  EPILOGUE

# dcon_line(session id, category, ptr, len): one closed line
FN dcon_line
    xor r8d, r8d
    jmp add_piece

# dcon_close(session id, category) / close_open: a newline ends the last line if it is open and theirs
FN dcon_close
close_open:
    mov rax, [rip + clines + VEC_len]
    test rax, rax
    jz 1f
    dec rax
    imul rax, rax, CL_SIZE
    add rax, [rip + clines + VEC_ptr]
    cmp word ptr [rax + CL_open], 0
    je 1f
    cmp [rax + CL_sid], edi
    jne 1f
    cmp [rax + CL_cat], si
    jne 1f
    mov word ptr [rax + CL_open], 0
1:  ret

# add_piece(session id, category, ptr, len, open): sanitized and appended, joining an open line of
#   the same session and category
add_piece:
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], r8d
    mov rdi, rdx
    mov rsi, rcx
    call sanitize
    inc dword ptr [rip + g_dcon_gen]
    mov dword ptr [rip + g_dirty], 1
    # join?
    mov rax, [rip + clines + VEC_len]
    test rax, rax
    jz 2f
    dec rax
    imul rax, rax, CL_SIZE
    add rax, [rip + clines + VEC_ptr]
    mov rbx, rax
    cmp word ptr [rbx + CL_open], 0
    je 2f
    mov ecx, [rsp]
    cmp [rbx + CL_sid], ecx
    jne 2f
    mov ecx, [rsp + 4]
    cmp [rbx + CL_cat], cx
    jne 2f
    # the open line is the last text: append to it, within the line cap
    mov rdx, [rip + clean + SB_len]
    mov eax, DCON_LINE_MAX
    sub eax, [rbx + CL_len]
    jle 1f
    cmp rdx, rax
    cmova rdx, rax
    add [rbx + CL_len], edx
    lea rdi, [rip + ctext]
    mov rsi, [rip + clean + SB_ptr]
    call sb_push
1:  mov eax, [rsp + 8]
    mov [rbx + CL_open], ax
    jmp 9f
2:  call trim_lines
    lea rdi, [rip + clines]
    mov esi, CL_SIZE
    call vec_push
    mov rbx, rax
    mov rax, [rip + ctext + SB_len]
    mov [rbx + CL_off], rax
    mov rdx, [rip + clean + SB_len]
    cmp rdx, DCON_LINE_MAX
    jbe 3f
    mov edx, DCON_LINE_MAX
3:  mov [rbx + CL_len], edx
    mov eax, [rsp]
    mov [rbx + CL_sid], eax
    mov eax, [rsp + 4]
    mov [rbx + CL_cat], ax
    mov eax, [rsp + 8]
    mov [rbx + CL_open], ax
    lea rdi, [rip + ctext]
    mov rsi, [rip + clean + SB_ptr]
    call sb_push
9:  EPILOGUE

# trim_lines(): at the cap, the oldest half goes
trim_lines:
    PROLOGUE
    mov rax, [rip + clines + VEC_len]
    cmp eax, [rip + g_dcon_max]
    jb 9f
    shr rax, 1
    inc dword ptr [rip + g_dcon_reset]
    mov rbx, rax                # lines dropped
    imul rcx, rbx, CL_SIZE
    add rcx, [rip + clines + VEC_ptr]
    mov r12, [rcx + CL_off]     # text dropped
    # text
    mov rdx, [rip + ctext + SB_len]
    sub rdx, r12
    mov [rip + ctext + SB_len], rdx
    mov rdi, [rip + ctext + SB_ptr]
    lea rsi, [rdi + r12]
    call memmove
    # lines
    mov r13, [rip + clines + VEC_len]
    sub r13, rbx
    mov [rip + clines + VEC_len], r13
    mov rdi, [rip + clines + VEC_ptr]
    imul rsi, rbx, CL_SIZE
    add rsi, rdi
    imul rdx, r13, CL_SIZE
    call memmove
    mov rdi, [rip + clines + VEC_ptr]
    xor ecx, ecx
1:  cmp rcx, r13
    jae 9f
    sub [rdi + CL_off], r12
    add rdi, CL_SIZE
    inc rcx
    jmp 1b
9:  EPILOGUE

# sanitize(ptr, len): into clean: ANSI escape sequences dropped, control bytes but tab as U+FFFD,
#   cut at the line cap
sanitize:
    PROLOGUE
    mov r12, rdi
    lea r13, [rdi + rsi]
    lea rdi, [rip + clean]
    call sb_clear
1:  cmp r12, r13
    jae 9f
    cmp qword ptr [rip + clean + SB_len], DCON_LINE_MAX
    jae 9f
    movzx eax, byte ptr [r12]
    cmp eax, 27
    je 3f
    cmp eax, 9
    je 2f
    cmp eax, 0x20
    jb 4f
    cmp eax, 0x7f
    je 4f
2:  lea rdi, [rip + clean]
    mov esi, eax
    call sb_push_byte
    inc r12
    jmp 1b
4:  lea rdi, [rip + clean]
    lea rsi, [rip + .Lfffd]
    mov edx, 3
    call sb_push
    inc r12
    jmp 1b
3:  # ESC [ ... final (0x40-0x7e); ESC ] ... BEL or ESC \; ESC x
    inc r12
    cmp r12, r13
    jae 9f
    movzx eax, byte ptr [r12]
    inc r12
    cmp eax, '['
    je 5f
    cmp eax, ']'
    jne 1b
6:  cmp r12, r13
    jae 9f
    movzx eax, byte ptr [r12]
    inc r12
    cmp eax, 7
    je 1b
    cmp eax, 27
    jne 6b
    cmp r12, r13
    jae 9f
    inc r12
    jmp 1b
5:  cmp r12, r13
    jae 9f
    movzx eax, byte ptr [r12]
    inc r12
    sub eax, 0x40
    cmp eax, 0x3e
    ja 5b
    jmp 1b
9:  EPILOGUE

# dcon_clear(): an empty console
FN dcon_clear
    inc dword ptr [rip + g_dcon_reset]
    mov qword ptr [rip + clines + VEC_len], 0
    mov qword ptr [rip + ctext + SB_len], 0
    inc dword ptr [rip + g_dcon_gen]
    mov dword ptr [rip + g_dirty], 1
    ret

# dcon_count() -> rax lines
FN dcon_count
    mov rax, [rip + clines + VEC_len]
    ret

# dcon_get(i) -> rax text ptr, rdx len, ecx category, r8d session id
FN dcon_get
    mov rax, rdi
    imul rax, rax, CL_SIZE
    add rax, [rip + clines + VEC_ptr]
    movzx ecx, word ptr [rax + CL_cat]
    mov r8d, [rax + CL_sid]
    mov edx, [rax + CL_len]
    mov rax, [rax + CL_off]
    add rax, [rip + ctext + SB_ptr]
    ret

# dcon_cat_name(category) -> cstr
FN dcon_cat_name
    cmp edi, DCON_RESULT
    jbe 1f
    xor edi, edi
1:  lea rax, [rip + cat_names]
    mov rax, [rax + rdi*8]
    ret

# dcon_dump(sb, n): the last n lines (all with n 0) as "CATEGORY TEXT"
FN dcon_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, [rip + clines + VEC_len]
    xor r13d, r13d
    test rsi, rsi
    jz 1f
    cmp rsi, r12
    jae 1f
    mov r13, r12
    sub r13, rsi
1:  cmp r13, r12
    jae 9f
    mov rdi, r13
    call dcon_get
    mov r14, rax
    mov r15, rdx
    mov edi, ecx
    call dcon_cat_name
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r13
    jmp 1b
9:  EPILOGUE

# dcon_find(ptr, len) -> eax 1 when some line holds the text
FN dcon_find
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, [rip + clines + VEC_len]
    jae 8f
    mov rdi, rbx
    call dcon_get
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    mov rcx, r13
    call str_find
    test rax, rax
    jns 7f
    inc rbx
    jmp 1b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

.section .rodata
.Lfffd: .byte 0xef, 0xbf, 0xbd
.Lc_stdout: .asciz "stdout"
.Lc_stderr: .asciz "stderr"
.Lc_console: .asciz "console"
.Lc_important: .asciz "important"
.Lc_adapter: .asciz "adapter"
.Lc_error: .asciz "error"
.Lc_info: .asciz "info"
.Lc_input: .asciz "input"
.Lc_result: .asciz "result"
.p2align 3
cat_names:
    .quad .Lc_stdout, .Lc_stderr, .Lc_console, .Lc_important, .Lc_adapter, .Lc_error
    .quad .Lc_info, .Lc_input, .Lc_result
