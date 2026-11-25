# text/uri-list as local paths (urilist.s, phase 4 tasks 4 and 5): each case's input, then its paths with "|"
# for each NUL, or "none"
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
.text
FN main
    PROLOGUE
    lea r12, [rip + cases]
1:  mov r13, [r12]
    test r13, r13
    jz 9f
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call uri_list_paths
    mov rbx, rax
    mov r14, rdx
    lea rdi, [rip + out]
    call sb_clear
    test rbx, rbx
    jnz 2f
    lea rdi, [rip + out]
    lea rsi, [rip + .Lnone]
    call sb_push_cstr
    jmp 4f
2:  xor r15d, r15d
3:  cmp r15, r14
    jae 31f
    movzx esi, byte ptr [rbx + r15]
    test esi, esi
    jnz 32f
    mov esi, '|'
32: cmp esi, 10
    jne 33f
    mov esi, '~'                # a line feed inside a path, shown
33: lea rdi, [rip + out]
    call sb_push_byte
    inc r15
    jmp 3b
31: mov rdi, rbx
    call mem_free
4:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    add r12, 8
    jmp 1b
9:  xor edi, edi
    call sys_exit

.section .rodata
.Lnone: .asciz "none"
.Lc1: .asciz "file:///tmp/a.txt\r\nfile:///tmp/b%20c.png\r\n"
.Lc2: .asciz "# a comment\r\nfile://localhost/home/u/x\r\nhttp://example.com/y\r\nfile://other/z\r\n"
.Lc3: .asciz "file:/one/path\nFILE:///Two"
.Lc4: .asciz "file:///nul%00here\r\nfile:///ok%2Fslash%41\r\nfile:///bad%zz\r\nfile:///end%"
.Lc5: .asciz "file:///new%0Aline\r\nfile://relative\r\nfile://localhost\r\nrelative/path\r\n\r\n"
.Lc6: .asciz ""
.p2align 3
cases: .quad .Lc1, .Lc2, .Lc3, .Lc4, .Lc5, .Lc6, 0
