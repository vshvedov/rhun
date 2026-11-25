# Base64 (RFC 4648, the standard alphabet, padded, no line breaks): an encoder that writes straight into a
# byte buffer, grown once. Generic: an agent's attachments are written with it, and a WebSocket handshake can
# use it. b64_decode has no size limit of its own (snippetbase64.s's decoder is the snippets').
#
#   b64_len(n) -> rax                   the characters n bytes make (padding included)
#   b64_decode(sb, ptr, len) -> eax 1   the bytes of a Base64 text appended (0: not Base64)
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


# FN b64_decode(sb, ptr, len) -> eax 1 with the bytes appended to sb (grown once), 0 when the text is not Base64
#   (a character outside the alphabet, padding before the end, a stray last character). Blanks are skipped;
#   padding may be left out
FN b64_decode
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rax, r13                # at most 3 bytes per 4 characters
    shr rax, 2
    imul rax, rax, 3
    add rax, 3
    mov rsi, rax
    mov rdi, rbx
    call sb_reserve             # rax: where the bytes go
    mov rdi, rax
    lea r8, [rip + .Lunalpha]
    xor ecx, ecx                # characters read
    xor r9d, r9d                # bits gathered
    xor r10d, r10d              # how many characters in them (0-3)
    xor r11d, r11d              # padding seen
1:  cmp rcx, r13
    jae 5f
    movzx eax, byte ptr [r12 + rcx]
    inc rcx
    movzx edx, byte ptr [r8 + rax]
    cmp edx, 254
    je 1b                       # a blank
    cmp eax, '='
    je 4f
    test r11d, r11d
    jnz 8f                      # a character after padding
    cmp edx, 64
    jae 8f
    shl r9d, 6
    or r9d, edx
    inc r10d
    cmp r10d, 4
    jb 1b
    mov eax, r9d                # four characters: three bytes
    shr eax, 16
    mov [rdi], al
    mov eax, r9d
    shr eax, 8
    mov [rdi + 1], al
    mov eax, r9d
    mov [rdi + 2], al
    add rdi, 3
    xor r9d, r9d
    xor r10d, r10d
    jmp 1b
4:  inc r11d
    jmp 1b
5:  cmp r10d, 1                 # the tail: two or three characters make one or two bytes
    je 8f
    cmp r10d, 2
    jne 6f
    mov eax, r9d
    shr eax, 4
    mov [rdi], al
    inc rdi
    jmp 7f
6:  cmp r10d, 3
    jne 7f
    mov eax, r9d
    shr eax, 10
    mov [rdi], al
    mov eax, r9d
    shr eax, 2
    mov [rdi + 1], al
    add rdi, 2
7:  mov byte ptr [rdi], 0
    sub rdi, [rbx + SB_ptr]
    mov [rbx + SB_len], rdi
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

.section .rodata
.Lalpha: .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

.Lunalpha:
    .byte 255, 255, 255, 255, 255, 255, 255, 255, 255, 254, 254, 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255
    .byte 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 62, 255, 255, 255, 63, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 255, 255, 255, 255, 255, 255
    .byte 255, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 255, 255, 255, 255, 255
    .byte 255, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 255, 255, 255, 255, 255
    .byte 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255
    .byte 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255
    .byte 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255
    .byte 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255
