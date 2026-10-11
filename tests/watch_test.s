# watch_add: counts registrations until the table refuses, frees them, registers once more
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
fds: .zero 8 * 300
.text
noop:
    ret
FN main
    PROLOGUE 16
    xor ebx, ebx                # registrations that succeeded
1:  cmp ebx, 300
    jae 2f
    lea rdi, [rip + fds]
    lea rdi, [rdi + rbx*8]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js 2f
    lea rax, [rip + fds]
    mov edi, [rax + rbx*8]
    mov esi, POLLIN
    lea rdx, [rip + noop]
    xor ecx, ecx
    call watch_add
    test eax, eax
    jz 2f
    inc ebx
    jmp 1b
2:  lea rdi, [rip + out]
    lea rsi, [rip + .Lregistered]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, ebx
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    # remove every watch, then one more add must succeed
    xor r12d, r12d
3:  cmp r12d, ebx
    jae 4f
    lea rax, [rip + fds]
    mov edi, [rax + r12*8]
    call watch_remove
    inc r12d
    jmp 3b
4:  lea rax, [rip + fds]
    mov edi, [rax]
    mov esi, POLLIN
    lea rdx, [rip + noop]
    xor ecx, ecx
    call watch_add
    mov r13d, eax               # result of the add after the table emptied
    lea rdi, [rip + out]
    lea rsi, [rip + .Lagain]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE
.section .rodata
.Lregistered: .asciz "registered="
.Lagain: .asciz "again="
