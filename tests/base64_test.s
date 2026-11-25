# base64: RFC 4648's test vectors (every tail length), b64_len, appending to a buffer that holds text
# already, and 1 MiB of bytes (i * 131 + 7) mod 256 whose encoding's length and FNV-1a hash the golden
# holds (made with Python's base64 module)
.include "rhun.inc"
.equ BIG, 1 << 20
.bss
.p2align 3
out: .zero SB_SIZE
.text
FN main
    PROLOGUE
    lea r12, [rip + vectors]
1:  mov r13, [r12]              # "f" -> "Zg==" ...
    test r13, r13
    jz 2f
    lea rdi, [rip + out]
    call sb_clear
    mov rdi, r13
    call strlen
    mov r14, rax
    lea rdi, [rip + out]
    mov rsi, r13
    mov rdx, r14
    call b64_encode
    mov rdi, r14
    call b64_len
    mov r15, rax
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, r15
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    add r12, 8
    jmp 1b
2:  lea rdi, [rip + out]        # appended after what is there
    call sb_clear
    lea rdi, [rip + out]
    lea rsi, [rip + .Lpre]
    call sb_push_cstr
    lea rdi, [rip + out]
    lea rsi, [rip + .Lfoobar]
    mov edx, 6
    call b64_encode
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    mov edi, BIG                # 1 MiB
    call mem_alloc
    mov rbx, rax
    xor ecx, ecx
3:  imul eax, ecx, 131
    add eax, 7
    mov [rbx + rcx], al
    inc rcx
    cmp rcx, BIG
    jb 3b
    lea rdi, [rip + out]
    call sb_free
    lea rdi, [rip + out]
    mov rsi, rbx
    mov edx, BIG
    call b64_encode
    mov rax, 0xcbf29ce484222325
    mov r8, 0x100000001b3
    mov rsi, [rip + out + SB_ptr]
    mov r13, [rip + out + SB_len]
    xor ecx, ecx
4:  cmp rcx, r13
    jae 5f
    movzx edx, byte ptr [rsi + rcx]
    xor rax, rdx
    imul rax, r8
    inc rcx
    jmp 4b
5:  mov r14, rax
    lea rdi, [rip + out]
    call sb_free
    lea rdi, [rip + out]
    lea rsi, [rip + .Lbig]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, r13
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Lfnv]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, r14
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
.Lv0: .asciz ""
.Lv1: .asciz "f"
.Lv2: .asciz "fo"
.Lfoo: .asciz "foo"
.Lv4: .asciz "foob"
.Lv5: .asciz "fooba"
.Lfoobar: .asciz "foobar"
.Lv7: .asciz "\377\376\375"
.Lpre: .asciz "x="
.Lbig: .asciz "1MiB len="
.Lfnv: .asciz " fnv="
.p2align 3
vectors: .quad .Lv0, .Lv1, .Lv2, .Lfoo, .Lv4, .Lv5, .Lfoobar, .Lv7, 0
