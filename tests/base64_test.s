# base64_encode on the lines of a file, one result per line
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
.text
FN main
    PROLOGUE
    mov rax, [rip + g_argv]
    mov rdi, [rax + 8]
    call file_read_all
    test rax, rax
    jz 9f
    mov r12, rax
    lea r13, [rax + rdx]
1:  cmp r12, r13
    jae 9f
    mov r14, r12
2:  cmp r12, r13
    jae 3f
    cmp byte ptr [r12], 10
    je 3f
    inc r12
    jmp 2b
3:  mov rdx, r12
    sub rdx, r14
    lea rdi, [rip + out]
    mov rsi, r14
    call base64_encode
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    inc r12
    jmp 1b
9:  mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE
