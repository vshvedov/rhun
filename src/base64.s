# base64: the standard alphabet with padding, appended to an SB
.include "rhun.inc"

.section .rodata
b64_alphabet: .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

.text
# base64_encode(sb, ptr, len): append the encoding of len bytes
FN base64_encode
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    # 4 output bytes per 3 input bytes, rounded up
    lea rdi, [r13 + 2]
    xor edx, edx
    mov rax, rdi
    mov ecx, 3
    div rcx
    shl rax, 2
    mov rdi, rbx
    mov rsi, rax
    call sb_reserve
    mov r14, rax                # write position
    mov r15, rax
    lea r8, [rip + b64_alphabet]
1:  cmp r13, 3
    jb 2f
    movzx eax, byte ptr [r12]
    shl eax, 16
    movzx ecx, byte ptr [r12 + 1]
    shl ecx, 8
    or eax, ecx
    movzx ecx, byte ptr [r12 + 2]
    or eax, ecx
    mov ecx, eax
    shr ecx, 18
    and ecx, 63
    mov cl, [r8 + rcx]
    mov [r14], cl
    mov ecx, eax
    shr ecx, 12
    and ecx, 63
    mov cl, [r8 + rcx]
    mov [r14 + 1], cl
    mov ecx, eax
    shr ecx, 6
    and ecx, 63
    mov cl, [r8 + rcx]
    mov [r14 + 2], cl
    mov ecx, eax
    and ecx, 63
    mov cl, [r8 + rcx]
    mov [r14 + 3], cl
    add r14, 4
    add r12, 3
    sub r13, 3
    jmp 1b
    # 1 or 2 bytes left: 2 or 3 characters, then '=' padding to 4
2:  test r13, r13
    jz 9f
    movzx eax, byte ptr [r12]
    shl eax, 16
    cmp r13, 2
    jb 3f
    movzx ecx, byte ptr [r12 + 1]
    shl ecx, 8
    or eax, ecx
3:  mov ecx, eax
    shr ecx, 18
    and ecx, 63
    mov cl, [r8 + rcx]
    mov [r14], cl
    mov ecx, eax
    shr ecx, 12
    and ecx, 63
    mov cl, [r8 + rcx]
    mov [r14 + 1], cl
    mov byte ptr [r14 + 2], '='
    mov byte ptr [r14 + 3], '='
    cmp r13, 2
    jb 4f
    mov ecx, eax
    shr ecx, 6
    and ecx, 63
    mov cl, [r8 + rcx]
    mov [r14 + 2], cl
4:  add r14, 4
9:  mov byte ptr [r14], 0      # keep the SB NUL-terminated, as sb_push does
    sub r14, r15
    add [rbx + SB_len], r14
    EPILOGUE
