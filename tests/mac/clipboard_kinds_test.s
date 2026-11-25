// Phase 4 tasks 4 and 5: the pasteboard's files and images, and the view's drop methods, on private
// pasteboards (never the desktop's). Test-only AAPCS bridge, as clipboard_metadata_test.s.
.include "mac.inc"
.bss
.p2align 3
fixture_stack: .quad 0
.text
FN main
    ENTER
    ADR x9, fixture_stack
    str x28, [x9]
    ADR x9, g_argc
    ldr x0, [x9]
    ADR x9, g_argv
    ldr x1, [x9]
    bl _test_mac_clipboard_kinds
    XCALL sys_exit

// C Result call(function, arg0..arg5): a translated function or a native one that ends in XRET
FN _fixture_call
    ENTER
    mov x16, x0
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    mov x4, x5
    mov x5, x6
    ADR x9, fixture_stack
    ldr x28, [x9]
    adr x17, 1f
    str x17, [x28, #-8]!
    blr x16
1:  mov x0, x8
    mov x1, x2
    LEAVE
    ret
