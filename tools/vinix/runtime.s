// AAPCS bridge for the translated editor's private x86 stack.
.macro XCALL fn
    adr x17, 1f
    str x17, [x28, #-8]!
    bl \fn
1:
.endm

.text
.globl rhun_arm64_main
.type rhun_arm64_main, %function
rhun_arm64_main:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    mov x28, x0
    XCALL rhun_sys_init
    XCALL rhun_main
    mov x0, x8
    mov sp, x29
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x27, x28, [sp, #80]
    ldp x29, x30, [sp], #96
    ret

.globl x_syscall
.type x_syscall, %function
x_syscall:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #320
    stp x0, x1, [sp]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    str x6, [sp, #48]
    stp q0, q1, [sp, #64]
    stp q2, q3, [sp, #96]
    stp q4, q5, [sp, #128]
    stp q6, q7, [sp, #160]
    stp q16, q17, [sp, #192]
    stp q18, q19, [sp, #224]
    stp q20, q21, [sp, #256]
    stp q22, q23, [sp, #288]
    mov x0, x8
    ldp x1, x2, [sp]
    ldr x3, [sp, #16]
    ldr x4, [sp, #48]
    ldp x5, x6, [sp, #32]
    bl rhun_linux_syscall
    mov x8, x0
    ldp x0, x1, [sp]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldr x6, [sp, #48]
    ldp q0, q1, [sp, #64]
    ldp q2, q3, [sp, #96]
    ldp q4, q5, [sp, #128]
    ldp q6, q7, [sp, #160]
    ldp q16, q17, [sp, #192]
    ldp q18, q19, [sp, #224]
    ldp q20, q21, [sp, #256]
    ldp q22, q23, [sp, #288]
    mov sp, x29
    ldp x29, x30, [sp], #16
    ret
.section .note.GNU-stack,"",@progbits
