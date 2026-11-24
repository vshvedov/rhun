# SHA-1 (FIPS 180-4) and Base64 (RFC 4648, with padding) for the WebSocket handshake of the bridge for
# terminal claude (ide_server.s): Sec-WebSocket-Accept is the Base64 of the SHA-1 of the key and a GUID.
# Small and plain: one pass, no state kept between calls.
#
#   sha1(ptr, len, out20)              the 20-byte digest of len bytes
#   b64_encode(ptr, len, out) -> rax   the Base64 text (4 * ceil(len / 3) bytes) at out, its length
.include "rhun.inc"

.text

# sha1(ptr, len, out20). The frame: W[0..79] at [rsp] (320 bytes; block() reads it at the caller's
#   [rsp]), the padded last block or two at [rsp + 320] (128 bytes), out at [rsp + 448], the padded size
#   at [rsp + 456]
FN sha1
    PROLOGUE 464
    mov [rsp + 448], rdx
    mov r12, rdi                # data
    mov r13, rsi                # len
    mov r14, rsi                # the whole blocks' bytes
    and r14, -64
    # h0..h4 in r8d..r11d, ebx
    mov r8d, 0x67452301
    mov r9d, 0xEFCDAB89
    mov r10d, 0x98BADCFE
    mov r11d, 0x10325476
    mov ebx, 0xC3D2E1F0
    xor r15d, r15d              # offset of the next whole block
1:  cmp r15, r14
    jae 2f
    lea rdi, [r12 + r15]
    call block
    add r15, 64
    jmp 1b
2:  # the tail, the 0x80 byte, zeros, and the length in bits (big-endian): one block or two
    lea rdi, [rsp + 320]
    xor eax, eax
    mov ecx, 16
3:  mov [rdi + rcx*8 - 8], rax
    dec ecx
    jnz 3b
    mov rcx, r13
    sub rcx, r14                # the tail's length, below 64
    xor edx, edx
4:  cmp rdx, rcx
    jae 5f
    movzx eax, byte ptr [r12 + r14]
    mov [rdi + rdx], al
    inc r14
    inc rdx
    jmp 4b
5:  mov byte ptr [rdi + rdx], 0x80
    mov r15d, 64
    cmp rdx, 56
    jb 6f
    mov r15d, 128
6:  mov rax, r13
    shl rax, 3
    bswap rax
    mov [rdi + r15 - 8], rax
    mov [rsp + 456], r15
    lea rdi, [rsp + 320]
    call block
    cmp qword ptr [rsp + 456], 128
    jne 7f
    lea rdi, [rsp + 384]
    call block
7:  mov rdi, [rsp + 448]
    bswap r8d
    mov [rdi], r8d
    bswap r9d
    mov [rdi + 4], r9d
    bswap r10d
    mov [rdi + 8], r10d
    bswap r11d
    mov [rdi + 12], r11d
    bswap ebx
    mov [rdi + 16], ebx
    EPILOGUE

# block(ptr): one 64-byte block into the state r8d..r11d, ebx. W lives at the caller's [rsp] (this
#   function's [rsp + 8]); it uses rax, rcx, rdx, rsi, rdi and r13 (saved), r15 (saved)
block:
    push r13
    push r15
    # W at the caller's frame: [rsp + 24] here (return address and two pushes)
    lea rsi, [rsp + 24]
    xor ecx, ecx
1:  mov eax, [rdi + rcx*4]
    bswap eax
    mov [rsi + rcx*4], eax
    inc ecx
    cmp ecx, 16
    jb 1b
2:  mov eax, [rsi + rcx*4 - 12]
    xor eax, [rsi + rcx*4 - 32]
    xor eax, [rsi + rcx*4 - 56]
    xor eax, [rsi + rcx*4 - 64]
    rol eax, 1
    mov [rsi + rcx*4], eax
    inc ecx
    cmp ecx, 80
    jb 2b
    # a..e in eax-free registers: a edx, b r13d, c r15d, d edi, e ecx (rounds keep the index on the stack)
    push rsi
    mov edx, r8d
    mov r13d, r9d
    mov r15d, r10d
    mov edi, r11d
    push rbx                    # e
    xor ecx, ecx
3:  # f and k by the round
    cmp ecx, 20
    jae 4f
    mov eax, r13d               # (b & c) | (~b & d)
    and eax, r15d
    push rcx
    mov ecx, r13d
    not ecx
    and ecx, edi
    or eax, ecx
    pop rcx
    add eax, 0x5A827999
    jmp 7f
4:  cmp ecx, 40
    jae 5f
    mov eax, r13d               # b ^ c ^ d
    xor eax, r15d
    xor eax, edi
    add eax, 0x6ED9EBA1
    jmp 7f
5:  cmp ecx, 60
    jae 6f
    mov eax, r13d               # (b & c) | (b & d) | (c & d)
    and eax, r15d
    push rcx
    mov ecx, r13d
    or ecx, r15d
    and ecx, edi
    or eax, ecx
    pop rcx
    add eax, 0x8F1BBCDC
    jmp 7f
6:  mov eax, r13d
    xor eax, r15d
    xor eax, edi
    add eax, 0xCA62C1D6
7:  # temp = rol(a, 5) + f + e + k + W[i]
    add eax, [rsp]              # e
    mov rsi, [rsp + 8]
    add eax, [rsi + rcx*4]
    push rcx
    mov ecx, edx
    rol ecx, 5
    add eax, ecx
    pop rcx
    # e = d, d = c, c = rol(b, 30), b = a, a = temp
    mov [rsp], edi
    mov edi, r15d
    mov r15d, r13d
    rol r15d, 30
    mov r13d, edx
    mov edx, eax
    inc ecx
    cmp ecx, 80
    jb 3b
    pop rax                     # e
    pop rsi
    add r8d, edx
    add r9d, r13d
    add r10d, r15d
    add r11d, edi
    add ebx, eax
    pop r15
    pop r13
    ret

# b64_encode(ptr, len, out) -> rax the length written
FN b64_encode
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea r14, [rip + .Lb64]
    xor r15d, r15d              # written
    xor ecx, ecx                # read
1:  mov rax, r12
    sub rax, rcx
    jz 9f
    cmp rax, 3
    jb 2f
    movzx eax, byte ptr [rbx + rcx]
    shl eax, 16
    movzx edx, byte ptr [rbx + rcx + 1]
    shl edx, 8
    or eax, edx
    movzx edx, byte ptr [rbx + rcx + 2]
    or eax, edx
    add rcx, 3
    mov edx, 4
    jmp 3f
2:  # one or two bytes left
    movzx edx, byte ptr [rbx + rcx]
    shl edx, 16
    cmp rax, 2
    jb 21f
    movzx esi, byte ptr [rbx + rcx + 1]
    shl esi, 8
    or edx, esi
21: mov r8, rax                 # 1 or 2 bytes: 2 or 3 characters
    mov eax, edx
    add rcx, r8
    lea edx, [r8 + 1]
3:  # edx characters of the 24 bits in eax, then '=' to four
    mov r8d, eax
    shr r8d, 18
    and r8d, 63
    movzx r8d, byte ptr [r14 + r8]
    mov [r13 + r15], r8b
    mov r8d, eax
    shr r8d, 12
    and r8d, 63
    movzx r8d, byte ptr [r14 + r8]
    mov [r13 + r15 + 1], r8b
    mov r8d, eax
    shr r8d, 6
    and r8d, 63
    movzx r8d, byte ptr [r14 + r8]
    mov byte ptr [r13 + r15 + 2], '='
    cmp edx, 3
    jb 4f
    mov [r13 + r15 + 2], r8b
4:  mov r8d, eax
    and r8d, 63
    movzx r8d, byte ptr [r14 + r8]
    mov byte ptr [r13 + r15 + 3], '='
    cmp edx, 4
    jb 5f
    mov [r13 + r15 + 3], r8b
5:  add r15, 4
    jmp 1b
9:  mov rax, r15
    EPILOGUE

.section .rodata
.Lb64: .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
