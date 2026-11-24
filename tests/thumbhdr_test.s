# thumbnails' groundwork (phase 4 task 6): b64_decode on RFC 4648's vectors, blanks, missing padding and bad
#   texts ("TEXT -> BYTES" or "TEXT -> bad"); then image_size against image_decode for each image named on the
#   command line: "name header=WxH decoded=WxH" ("-" for a file that is no image)
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
dec: .zero SB_SIZE
im: .zero IMG_SIZE
.text
FN main
    PROLOGUE 16
    lea r12, [rip + vectors]
1:  mov r13, [r12]
    test r13, r13
    jz 3f
    add r12, 8
    lea rdi, [rip + out]
    mov rsi, r13
    call sb_push_cstr
    lea rdi, [rip + out]
    lea rsi, [rip + .Larrow]
    call sb_push_cstr
    lea rdi, [rip + dec]
    call sb_clear
    mov rdi, r13
    call strlen
    lea rdi, [rip + dec]
    mov rsi, r13
    mov rdx, rax
    call b64_decode
    lea rsi, [rip + .Lbad]
    test eax, eax
    jz 2f
    lea rsi, [rip + .Lempty]
    cmp qword ptr [rip + dec + SB_len], 0
    je 2f
    lea rdi, [rip + out]
    mov rsi, [rip + dec + SB_ptr]
    mov rdx, [rip + dec + SB_len]
    call sb_push
    lea rsi, [rip + .Lnone]
2:  lea rdi, [rip + out]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    jmp 1b
3:  mov r12, [rip + g_argv]     # the images
    mov r13, [rip + g_argc]
    mov ebx, 1
4:  cmp rbx, r13
    jae 9f
    mov r14, [r12 + rbx*8]
    inc rbx
    mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    call path_basename
    lea rdi, [rip + out]
    mov rsi, rax
    call sb_push
    mov rdi, r14
    call image_probe
    mov r15d, eax
    test eax, eax
    jz 8f
    mov rdi, r14
    call file_read_all
    test rax, rax
    jz 8f
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rax
    mov rsi, rdx
    mov edx, r15d
    call image_size
    push rdx
    push rax
    lea rdi, [rip + out]
    lea rsi, [rip + .Lheader]
    call sb_push_cstr
    pop rsi
    push rsi
    lea rdi, [rip + out]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 'x'
    call sb_push_byte
    pop rax
    pop rsi
    lea rdi, [rip + out]
    call sb_push_u64
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov edx, r15d
    lea rcx, [rip + im]
    call image_decode
    mov r15d, eax
    mov rdi, [rsp]
    call mem_free
    lea rdi, [rip + out]
    lea rsi, [rip + .Ldecoded]
    call sb_push_cstr
    test r15d, r15d
    jnz 7f
    lea rdi, [rip + out]
    mov esi, [rip + im + IMG_w]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 'x'
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, [rip + im + IMG_h]
    call sb_push_u64
    lea rdi, [rip + im]
    call image_free
    jmp 6f
7:  lea rdi, [rip + out]
    mov esi, '-'
    call sb_push_byte
    jmp 6f
8:  lea rdi, [rip + out]
    lea rsi, [rip + .Lnot]
    call sb_push_cstr
6:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    jmp 4b
9:  mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE

.section .rodata
.Larrow: .asciz " -> "
.Lbad: .asciz "bad"
.Lempty: .asciz "(empty)"
.Lnone: .asciz ""
.Lheader: .asciz " header="
.Ldecoded: .asciz " decoded="
.Lnot: .asciz " -"
.Lv1: .asciz ""
.Lv2: .asciz "Zg=="
.Lv3: .asciz "Zm8="
.Lv4: .asciz "Zm9v"
.Lv5: .asciz "Zm9vYg=="
.Lv6: .asciz "Zm9vYmE="
.Lv7: .asciz "Zm9vYmFy"
.Lv8: .asciz "Zm9vYmE"
.Lv9: .asciz "Zm9v\nYmFy"
.Lv10: .asciz "Zm9v YmFy"
.Lv11: .asciz "Zm9vY"
.Lv12: .asciz "Zm=9v"
.Lv13: .asciz "Zm9v!mFy"
.Lv14: .asciz "Zm9vYmFy===="
.p2align 3
vectors: .quad .Lv1, .Lv2, .Lv3, .Lv4, .Lv5, .Lv6, .Lv7, .Lv8, .Lv9, .Lv10, .Lv11, .Lv12, .Lv13, .Lv14, 0
