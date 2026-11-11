# Compound text from XIM servers (ctext.s): each case decoded into a buffer of the given size.
.include "rhun.inc"
.section .rodata
.p2align 3
cases:
    .quad n0, s0, 5, 64
    .quad n1, s1, 4, 64
    .quad n2, s2, 9, 64
    .quad n3, s3, 8, 64
    .quad n4, s4, 6, 64
    .quad n5, s5, 12, 64
    .quad n6, s6, 8, 64
    .quad n7, s7, 13, 64
    .quad n8, s8, 4, 64
    .quad n9, s9, 6, 64
    .quad n10, s10, 12, 64
    .quad n11, s11, 8, 4
    .quad n12, s12, 11, 64
    .quad n13, s13, 5, 64
    .quad 0
n0: .asciz "ascii"
s0: .byte 97,9,98,32,99
n1: .asciz "latin1"
s1: .byte 99,97,102,233
n2: .asciz "cyrillic"
s2: .byte 27,45,76,191,224,216,210,213,226
n3: .asciz "ksc-gl"
s3: .byte 27,36,40,67,71,81,49,91
n4: .asciz "ksc-gr"
s4: .byte 27,36,41,67,199,209
n5: .asciz "jis-then-ascii"
s5: .byte 27,36,40,66,70,124,75,92,27,40,66,33
n6: .asciz "gb"
s6: .byte 27,36,40,65,86,80,78,68
n7: .asciz "utf8-segment"
s7: .byte 27,37,71,240,159,152,128,111,107,27,37,64,120
n8: .asciz "katakana"
s8: .byte 27,41,73,177
n9: .asciz "unknown-set"
s9: .byte 27,36,40,68,33,33
n10: .asciz "extended-segment"
s10: .byte 27,37,47,49,128,133,97,98,2,120,120,122
n11: .asciz "cut-at-character"
s11: .byte 27,36,40,67,71,81,49,91
n12: .asciz "mixed"
s12: .byte 97,27,36,40,67,71,81,27,40,66,98
n13: .asciz "controls-dropped"
s13: .byte 97,1,127,133,98
.Lsep: .ascii ": "
.bss
out: .zero 64
.text
FN main
    PROLOGUE 16
    lea rbx, [rip + cases]
1:  mov rdi, [rbx]
    test rdi, rdi
    jz 9f
    call log_cstr
    lea rdi, [rip + .Lsep]
    mov esi, 2
    call log_write
    mov rdi, [rbx + 8]
    mov rsi, [rbx + 16]
    lea rdx, [rip + out]
    mov rcx, [rbx + 24]
    call ct_decode
    lea rdi, [rip + out]
    mov rsi, rax
    call log_write
    call log_nl
    add rbx, 32
    jmp 1b
9:  xor eax, eax
    EPILOGUE
