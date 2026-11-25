# sha1 (src/app/sha1.s): FIPS 180-4's examples, every tail length around the one-block and two-block
# padding (0 to 130 bytes of a pattern), a million "a", and RFC 6455's handshake example (the key and its
# Sec-WebSocket-Accept, with base64.s's encoder; Base64 itself is base64_test.s's)
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
dig: .zero 32
pat: .zero 200
big: .zero 1000000
.text
FN main
    PROLOGUE
    lea rdi, [rip + .Lc_abc]
    mov esi, 3
    call one
    lea rdi, [rip + .Lc_448]
    mov esi, 56
    call one
    lea rdi, [rip + .Lc_896]
    mov esi, 112
    call one
    # a pattern of every length up to 130
    xor ecx, ecx
1:  lea eax, [rcx * 8 + 7]
    lea rdx, [rip + pat]
    mov [rdx + rcx], al
    inc ecx
    cmp ecx, 200
    jb 1b
    xor r12d, r12d
2:  lea rdi, [rip + pat]
    mov rsi, r12
    call one
    inc r12
    cmp r12, 130
    jbe 2b
    # a million a
    lea rdi, [rip + big]
    mov esi, 'a'
    mov edx, 1000000
    call memset
    lea rdi, [rip + big]
    mov esi, 1000000
    call one
    # RFC 6455 1.3: the key and the GUID, SHA-1, Base64
    lea rdi, [rip + .Lkey]
    mov esi, .Lkey_end - .Lkey
    lea rdx, [rip + dig]
    call sha1
    lea rdi, [rip + out]
    lea rsi, [rip + dig]
    mov edx, 20
    call b64_encode
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov edi, 1
    lea rax, [rip + out]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    call write_all
    xor eax, eax
    EPILOGUE

# one(ptr, len): "LEN HEX" of its digest
one:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + out]
    mov rsi, r12
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + dig]
    call sha1
    xor r13d, r13d
1:  lea rax, [rip + dig]
    movzx r14d, byte ptr [rax + r13]
    lea rcx, [rip + .Lhex]
    mov eax, r14d
    shr eax, 4
    movzx esi, byte ptr [rcx + rax]
    lea rdi, [rip + out]
    call sb_push_byte
    lea rcx, [rip + .Lhex]
    mov eax, r14d
    and eax, 15
    movzx esi, byte ptr [rcx + rax]
    lea rdi, [rip + out]
    call sb_push_byte
    inc r13
    cmp r13, 20
    jb 1b
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Lhex: .ascii "0123456789abcdef"
.Lc_abc: .ascii "abc"
.Lc_448: .ascii "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
.Lc_896: .ascii "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
.Lkey: .ascii "dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
.Lkey_end:
