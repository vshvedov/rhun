# icon_draw draws nothing for a size no icon has (0, below it, above ICON_MAX): 0.20.0's agents footer
# passed a register's leftovers, 1436160 px, raster_begin's w * h wrapped and raster_line wrote past its
# buffer (SIGSEGV); without the check this test crashes the same way
.include "rhun.inc"
.equ NSIZES, 5
.text
FN main
    PROLOGUE
    xor r12d, r12d
1:  cmp r12d, NSIZES
    jae 2f
    mov edi, IC_CLOSE
    xor esi, esi
    xor edx, edx
    lea rax, [rip + sizes]
    mov ecx, [rax + r12*4]
    mov r8d, -1
    call icon_draw
    inc r12d
    jmp 1b
2:  lea rdi, [rip + ok]
    call log_cstr
    xor eax, eax
    EPILOGUE

.section .rodata
.p2align 2
sizes: .long 0, -16, 2049, 1436160, 0x7fffffff
ok: .asciz "ok\n"
