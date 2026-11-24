# Base64 (RFC 4648, the standard alphabet, padded, no line breaks): an encoder that writes straight into a
# byte buffer, grown once. Generic: an agent's attachments are written with it, and a WebSocket handshake can
# use it. The decoder is snippetbase64.s's.
#
#   b64_len(n) -> rax                   the characters n bytes make (padding included)
#   b64_encode(sb, ptr, len)            appends them (the sb grows once, sb_reserve first); g_b64_out counts
#                                       every character written since start (print-agent-attachments encoded=)
.include "rhun.inc"

.data
.p2align 3
.globl g_b64_out
g_b64_out: .quad 0

.text

# FN b64_len(n) -> rax 4 * ceil(n / 3)
FN b64_len
    lea rax, [rdi + 2]
    xor edx, edx
    mov ecx, 3
    div rcx
    shl rax, 2
    ret

# FN b64_encode(sb, ptr, len): see the top
FN b64_encode
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call b64_len
    mov r14, rax
    mov rdi, rbx
    mov rsi, rax
    call sb_reserve             # rax: where the characters go
    mov rdi, rax
    lea r8, [rip + .Lalpha]
    mov rsi, r12
    mov rcx, r13
1:  cmp rcx, 3                  # three bytes make four characters
    jb 2f
    movzx eax, byte ptr [rsi]
    shl eax, 16
    movzx edx, byte ptr [rsi + 1]
    shl edx, 8
    or eax, edx
    movzx edx, byte ptr [rsi + 2]
    or eax, edx
    mov edx, eax
    shr edx, 18
    movzx edx, byte ptr [r8 + rdx]
    mov [rdi], dl
    mov edx, eax
    shr edx, 12
    and edx, 63
    movzx edx, byte ptr [r8 + rdx]
    mov [rdi + 1], dl
    mov edx, eax
    shr edx, 6
    and edx, 63
    movzx edx, byte ptr [r8 + rdx]
    mov [rdi + 2], dl
    and eax, 63
    movzx edx, byte ptr [r8 + rax]
    mov [rdi + 3], dl
    add rsi, 3
    add rdi, 4
    sub rcx, 3
    jmp 1b
2:  test rcx, rcx               # the tail: one or two bytes, padded
    jz 8f
    movzx eax, byte ptr [rsi]
    shl eax, 16
    cmp rcx, 2
    jb 3f
    movzx edx, byte ptr [rsi + 1]
    shl edx, 8
    or eax, edx
3:  mov edx, eax
    shr edx, 18
    movzx edx, byte ptr [r8 + rdx]
    mov [rdi], dl
    mov edx, eax
    shr edx, 12
    and edx, 63
    movzx edx, byte ptr [r8 + rdx]
    mov [rdi + 1], dl
    mov byte ptr [rdi + 2], '='
    mov byte ptr [rdi + 3], '='
    cmp rcx, 2
    jb 4f
    shr eax, 6
    and eax, 63
    movzx edx, byte ptr [r8 + rax]
    mov [rdi + 2], dl
4:  add rdi, 4
8:  mov byte ptr [rdi], 0
    add [rbx + SB_len], r14
    add [rip + g_b64_out], r14
    EPILOGUE

.section .rodata
.Lalpha: .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
