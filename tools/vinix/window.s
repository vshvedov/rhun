// Bridges between the translated editor and the native window backend.
.macro ENTER
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
.endm
.macro LEAVE
    mov sp, x29
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x27, x28, [sp, #80]
    ldp x29, x30, [sp], #96
.endm
.macro XCALL fn
    adr x17, 1f
    str x17, [x28, #-8]!
    bl \fn
1:
.endm

.bss
.p2align 3
native_stack: .zero 8
.text

// C may use its own x28. Publish the private stack only for each bridge call,
// restoring the previous value after nested calls (such as updating a title).
.macro NATIVE name, function
.globl \name
\name:
    stp x29, x30, [sp, #-32]!
    adrp x9, native_stack
    ldr x10, [x9, :lo12:native_stack]
    str x10, [sp, #16]
    str x28, [x9, :lo12:native_stack]
    bl \function
    mov x8, x0
    adrp x9, native_stack
    ldr x10, [sp, #16]
    str x10, [x9, :lo12:native_stack]
    ldp x29, x30, [sp], #32
    add x28, x28, #8
    ret
.endm
NATIVE rhun_vinix_open_window, nv_open
NATIVE rhun_nv_draw, nv_draw
NATIVE rhun_nv_timeout, nv_timeout
NATIVE rhun_nv_flush, nv_flush
NATIVE rhun_nv_events, nv_events
NATIVE rhun_nv_title, nv_title
NATIVE rhun_nv_clip_set, nv_clip_set
NATIVE rhun_nv_clip_get, nv_clip_get
.globl rhun_nv_nop
rhun_nv_nop:
    add x28, x28, #8
    ret

.macro CALLBACK name, function
.globl \name
\name:
    ENTER
    adrp x9, native_stack
    ldr x28, [x9, :lo12:native_stack]
    XCALL \function
    mov x0, x8
    LEAVE
    ret
.endm
CALLBACK nv_watch_add, rhun_watch_add
CALLBACK nv_watch_remove, rhun_watch_remove
CALLBACK nv_watch_set_events, rhun_watch_set_events
CALLBACK nv_render, rhun_app_render
CALLBACK nv_target, rhun_gfx_set_target
CALLBACK nv_resize, rhun_app_on_resize
CALLBACK nv_motion, rhun_app_on_motion
CALLBACK nv_button, rhun_app_on_button
CALLBACK nv_scroll, rhun_app_on_scroll
CALLBACK nv_focus, rhun_app_on_focus
CALLBACK nv_key, rhun_app_on_key
CALLBACK nv_paste, rhun_app_on_paste
CALLBACK nv_close_request, rhun_app_on_close
CALLBACK nv_toast, rhun_app_toast
.section .note.GNU-stack,"",@progbits
