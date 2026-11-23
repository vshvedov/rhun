# testing: a failure's expected and actual values as a line diff (the diff view's read-only tab, and
# the lines the Testing details show), and an item's output as a read-only tab. Values are at most
# 64 KiB each: a longest common subsequence over their lines, or, past a million line pairs, every
# expected line removed and every actual line added.
.include "rhun.inc"

.equ LCS_CELLS, 1048576         # (lines + 1) * (lines + 1) the table may hold

.bss
.p2align 3
la: .zero VEC_SIZE              # the expected lines: ptr, len
lb: .zero VEC_SIZE              # the actual lines
tab: .quad 0                    # the table: u32 per (i, j), (n + 1) x (m + 1), from the end
ud: .zero SB_SIZE               # the unified text
ctx: .zero 32                   # diffview_answer's request: [16] the document, [24] its number
seq: .quad 0

.text

# split(vec, ptr, len): the lines (ptr, len); a final LF ends the last line
split:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rsi + rdx]
    mov qword ptr [rbx + VEC_len], 0
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
    mov rdi, rbx
    mov esi, 16
    call vec_push
    mov [rax], r12
    mov rcx, r14
    sub rcx, r12
    mov [rax + 8], rcx
    lea r12, [r14 + 1]
    jmp 1b
9:  EPILOGUE

# same(i, j) -> eax 1 when expected line i equals actual line j
same:
    mov rax, [rip + la + VEC_ptr]
    shl rdi, 4
    add rdi, rax
    mov rax, [rip + lb + VEC_ptr]
    shl rsi, 4
    add rsi, rax
    mov rdx, [rdi + 8]
    cmp rdx, [rsi + 8]
    jne 8f
    mov rdi, [rdi]
    mov rsi, [rsi]
    jmp memeq
8:  xor eax, eax
    ret

# testdiff_build(a, alen, b, blen): ud holds the unified diff of the values: a hunk header, then each
#   line with " ", "-" (expected only) or "+" (actual only)
FN testdiff_build
    PROLOGUE 32
    mov [rsp], rdx
    mov [rsp + 8], rcx
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + la]
    call split
    lea rdi, [rip + lb]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call split
    lea rdi, [rip + ud]
    call sb_clear
    mov r12, [rip + la + VEC_len]   # n
    mov r13, [rip + lb + VEC_len]   # m
    # "@@ -1,n +1,m @@"
    lea rdi, [rip + ud]
    lea rsi, [rip + .Lh1]
    call sb_push_cstr
    lea rdi, [rip + ud]
    mov rsi, r12
    call sb_push_u64
    lea rdi, [rip + ud]
    lea rsi, [rip + .Lh2]
    call sb_push_cstr
    lea rdi, [rip + ud]
    mov rsi, r13
    call sb_push_u64
    lea rdi, [rip + ud]
    lea rsi, [rip + .Lh3]
    call sb_push_cstr
    lea rax, [r12 + 1]
    lea rcx, [r13 + 1]
    imul rax, rcx
    cmp rax, LCS_CELLS
    ja .Ltb_plain
    # the table: L[i][j] = lines in common from i, j on
    lea rdi, [rax*4]
    mov [rsp + 16], rdi
    mov rdi, [rip + tab]
    call mem_free
    mov rdi, [rsp + 16]
    call mem_alloc
    mov [rip + tab], rax
    mov rdi, rax
    xor esi, esi
    mov rdx, [rsp + 16]
    call memset
    lea r15, [r13 + 1]          # a row's cells
    mov rbx, r12
1:  test rbx, rbx
    jz 4f
    dec rbx                     # i
    mov r14, r13
2:  test r14, r14
    jz 1b
    dec r14                     # j
    mov rdi, rbx
    mov rsi, r14
    call same
    mov rcx, [rip + tab]
    lea rdx, [rbx + 1]
    imul rdx, r15
    add rdx, r14                # (i + 1, j)
    test eax, eax
    jz 3f
    mov eax, [rcx + rdx*4 + 4]  # (i + 1, j + 1)
    inc eax
    jmp 31f
3:  mov eax, [rcx + rdx*4]      # (i + 1, j)
    mov r8, rbx
    imul r8, r15
    add r8, r14
    mov r9d, [rcx + r8*4 + 4]   # (i, j + 1)
    cmp r9d, eax
    cmova eax, r9d
31: mov r8, rbx
    imul r8, r15
    add r8, r14
    mov [rcx + r8*4], eax
    jmp 2b
4:  # the walk
    xor ebx, ebx                # i
    xor r14d, r14d              # j
5:  cmp rbx, r12
    jae 7f
    cmp r14, r13
    jae 6f
    mov rdi, rbx
    mov rsi, r14
    call same
    test eax, eax
    jz 51f
    mov edi, ' '
    mov rsi, rbx
    lea rdx, [rip + la]
    call line_out
    inc rbx
    inc r14
    jmp 5b
51: mov rcx, [rip + tab]
    lea rdx, [rbx + 1]
    imul rdx, r15
    add rdx, r14
    mov eax, [rcx + rdx*4]      # (i + 1, j)
    mov r8, rbx
    imul r8, r15
    add r8, r14
    cmp eax, [rcx + r8*4 + 4]   # (i, j + 1)
    jb 52f
6:  mov edi, '-'
    mov rsi, rbx
    lea rdx, [rip + la]
    call line_out
    inc rbx
    jmp 5b
52: mov edi, '+'
    mov rsi, r14
    lea rdx, [rip + lb]
    call line_out
    inc r14
    jmp 5b
7:  cmp r14, r13
    jae 9f
    mov edi, '+'
    mov rsi, r14
    lea rdx, [rip + lb]
    call line_out
    inc r14
    jmp 7b
.Ltb_plain:
    xor ebx, ebx
1:  cmp rbx, r12
    jae 2f
    mov edi, '-'
    mov rsi, rbx
    lea rdx, [rip + la]
    call line_out
    inc rbx
    jmp 1b
2:  xor ebx, ebx
3:  cmp rbx, r13
    jae 9f
    mov edi, '+'
    mov rsi, rbx
    lea rdx, [rip + lb]
    call line_out
    inc rbx
    jmp 3b
9:  mov rax, [rip + ud + SB_ptr]
    mov rdx, [rip + ud + SB_len]
    EPILOGUE

# line_out(sign, index, vec): "SIGN line" LF into ud
line_out:
    push rbx
    push r12
    push r12
    mov ebx, edi
    shl rsi, 4
    add rsi, [rdx + VEC_ptr]
    mov r12, rsi
    lea rdi, [rip + ud]
    mov esi, ebx
    call sb_push_byte
    lea rdi, [rip + ud]
    mov rsi, [r12]
    mov rdx, [r12 + 8]
    call sb_push
    lea rdi, [rip + ud]
    mov esi, 10
    call sb_push_byte
    pop r12
    pop r12
    pop rbx
    ret

# testdiff_open(title cstr, a, alen, b, blen) -> rax DOC*: a read-only diff tab of expected (a) against actual (b)
FN testdiff_open
    PROLOGUE
    mov r15, rdi
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rcx
    mov rcx, r8
    call testdiff_build
    call doc_new
    mov rbx, rax
    or dword ptr [rbx + DOC_flags], DF_READONLY
    mov edi, DV_SIZE
    call mem_alloc
    mov r12, rax
    mov rdi, rax
    xor esi, esi
    mov edx, DV_SIZE
    call memset
    # not git's (not fetched again, not reopened, no document for extensions), and an empty path
    # for whatever looks at a diff tab's file
    mov dword ptr [r12 + DV_flags], DVF_OWN
    mov [rbx + DOC_diff], r12
    lea rdi, [rip + .Ltd_empty]
    xor esi, esi
    call mem_dup
    mov [r12 + DV_path], rax
    mov rdi, r15
    call strlen
    mov rdi, r15
    mov rsi, rax
    call mem_dup
    mov [r12 + DV_name], rax
    mov [rbx + DOC_name], rax
    mov rdi, rbx
    call doc_language_refresh
    mov rdi, rbx
    mov esi, TAB_DOC
    call app_add_tab
    inc qword ptr [rip + seq]
    mov rax, [rip + seq]
    mov [rbx + DOC_gseq], eax
    mov [rip + ctx + 24], rax
    mov [rip + ctx + 16], rbx
    lea rdi, [rip + ctx]
    mov rsi, [rip + ud + SB_ptr]
    mov rdx, [rip + ud + SB_len]
    xor ecx, ecx
    call diffview_answer
    mov rax, rbx                # the document (a row's text finds its tab again by its DOC_id)
    EPILOGUE

# testdiff_output(title cstr, ptr, len) -> rax DOC*: a read-only tab holding the text (an item's output)
FN testdiff_output
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    call doc_new
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call doc_replace_all
    or dword ptr [rbx + DOC_flags], DF_READONLY
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [rbx + DOC_name], rax
    mov rdi, rbx
    call doc_language_refresh
    mov rdi, rbx
    mov esi, TAB_DOC
    call app_add_tab
    mov rax, rbx                # the document
    EPILOGUE

.section .rodata
.Lh1: .asciz "@@ -1,"
.Lh2: .asciz " +1,"
.Lh3: .asciz " @@\n"

.section .rodata
.Ltd_empty: .asciz ""
.text
