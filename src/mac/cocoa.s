// rhun on macOS: the AppKit window
//
// One NSWindow with a full-size content view; rhun draws its own title bar under the traffic
// lights. Frames are rendered into IOSurfaces that become the view layer's contents. The event
// loop stays rhun's: poll() (src/mac/linux.s) comes here while the window is open and runs the
// Cocoa run loop until an event arrives, a watched descriptor is ready or the timeout passes.
//
// AppKit may call back into rhun from any depth, with x28 holding its own value, so everything
// that runs translated code loads the x86 stack pointer from g_xsp, which each entry from
// translated code (and x_syscall) stores.
.include "mac.inc"

.equ MOD_SHIFT, 1
.equ MOD_CTRL, 4
.equ MOD_ALT, 8
.equ NS_SHIFT, 1 << 17
.equ NS_CONTROL, 1 << 18
.equ NS_OPTION, 1 << 19
.equ NS_COMMAND, 1 << 20
.equ NSNotFound, 0x7fffffffffffffff
.equ NSURS, 3                   // surfaces in rotation
.equ TL_X, 13                   // traffic lights: left margin and spacing, points
.equ TL_STEP, 20

// selector and class references, resolved by the Objective-C runtime at load
.macro SEL reg, name
    adrp \reg, Ls_\name@PAGE
    ldr \reg, [\reg, Ls_\name@PAGEOFF]
.endm
.macro CLS reg, name
    adrp \reg, Lc_\name@PAGE
    ldr \reg, [\reg, Lc_\name@PAGEOFF]
.endm
// 64-bit and 32-bit globals
.macro LDX reg, sym
    adrp \reg, \sym@PAGE
    ldr \reg, [\reg, \sym@PAGEOFF]
.endm
.macro STX reg, sym, tmp=x16
    adrp \tmp, \sym@PAGE
    str \reg, [\tmp, \sym@PAGEOFF]
.endm
.macro LDW reg, sym
    adrp x16, \sym@PAGE
    ldr \reg, [x16, \sym@PAGEOFF]
.endm
.macro STW reg, sym
    adrp x16, \sym@PAGE
    str \reg, [x16, \sym@PAGEOFF]
.endm
// [recv sel]
.macro MSG sel
    SEL x1, \sel
    bl _objc_msgSend
.endm
// external data: the value of an exported pointer (NSString constants and the like)
.macro EXT reg, sym
    adrp \reg, \sym@GOTPAGE
    ldr \reg, [\reg, \sym@GOTPAGEOFF]
    ldr \reg, [\reg]
.endm
// native function called from translated code: records the x86 stack for callbacks
.macro XENTRY size=0
    STX x28, g_xsp
    ENTER \size
.endm
.macro XLEAVE
    LEAVE
    XRET
.endm
// method called by AppKit that may run translated code: the x86 stack continues from g_xsp,
// which is back where it was on return, or it would sink with every callback AppKit makes
// without returning to rhun's loop (a live resize draws from setFrameSize:)
.macro IMP size=0
    ENTER \size + 16
    LDX x28, g_xsp
    stur x28, [x29, #-16]
.endm
.macro IMPRET
    ldur x9, [x29, #-16]
    STX x9, g_xsp
    LEAVE
    ret
.endm

// ---------------------------------------------------------------- window

// mac_open_window(title cstr)
FN mac_open_window
    XENTRY 48
    mov x19, x0
    bl _objc_autoreleasePoolPush
    str x0, [sp]
    // platform table
    ADR x9, g_plat
    ADR x10, plat_fns
    mov x11, #0
2:  ldr x12, [x10, x11, lsl #3]
    str x12, [x9, x11, lsl #3]
    add x11, x11, #1
    cmp x11, #13
    b.lo 2b
    STW wzr, g_csd
    CLS x0, NSApplication
    MSG sharedApplication
    STX x0, app
    mov x2, #0                  // NSApplicationActivationPolicyRegular
    MSG setActivationPolicy_
    bl make_classes
    LDX x0, cls_appdel
    MSG new
    mov x2, x0
    LDX x0, app
    MSG setDelegate_
    bl make_menu
    LDX x0, app
    MSG finishLaunching
    // Deliver the launch Apple event before choosing a project or restoring tabs.
    bl drain
    // window
    LDX x0, cls_window
    MSG alloc
    fmov d0, xzr
    fmov d1, xzr
    ldr d2, f_win_w
    ldr d3, f_win_h
    mov x2, #0x800f             // titled closable miniaturizable resizable
    orr x2, x2, #0x8000         // full size content view
    mov x3, #2                  // buffered
    mov x4, #0
    MSG initWithContentRect_styleMask_backing_defer_
    STX x0, win
    mov x20, x0
    mov x0, x20
    mov x2, #1
    MSG setTitlebarAppearsTransparent_
    mov x0, x20
    mov x2, #1                  // NSWindowTitleHidden
    MSG setTitleVisibility_
    mov x0, x20
    mov x2, #2                  // NSWindowTabbingModeDisallowed
    MSG setTabbingMode_
    mov x0, x20
    mov x2, #0x80               // full screen primary
    MSG setCollectionBehavior_
    mov x0, x20
    mov x2, #0
    MSG setReleasedWhenClosed_
    mov x0, x20
    ldr d0, f_min_w
    ldr d1, f_min_h
    MSG setContentMinSize_
    // the view
    LDX x0, cls_view
    MSG alloc
    fmov d0, xzr
    fmov d1, xzr
    ldr d2, f_win_w
    ldr d3, f_win_h
    MSG initWithFrame_
    STX x0, view
    mov x21, x0
    mov x2, #1
    MSG setWantsLayer_
    mov x0, x21
    mov x2, #0                  // NSViewLayerContentsRedrawNever
    MSG setLayerContentsRedrawPolicy_
    mov x0, x21
    MSG layer
    STX x0, layer
    mov x2, #1
    MSG setOpaque_
    mov x0, x20
    mov x2, x21
    MSG setContentView_
    mov x0, x20
    mov x2, x21
    MSG makeFirstResponder_
    mov x0, x20
    mov x2, #1
    MSG setAcceptsMouseMovedEvents_
    LDX x0, cls_windel
    MSG new
    mov x2, x0
    mov x0, x20
    MSG setDelegate_
    // frame from the last run, or centered
    CLS x0, NSString
    ADR x2, s_autosave
    MSG stringWithUTF8String_
    mov x22, x0
    mov x0, x20
    mov x2, x22
    MSG setFrameUsingName_
    cbnz w0, 1f
    mov x0, x20
    MSG center
1:  mov x0, x20
    mov x2, x22
    MSG setFrameAutosaveName_
    mov x0, x19
    bl set_title
    ADR x9, gui_poll
    STX x9, g_poll_hook
    bl kq_init
    bl hook_titlebar
    bl update_size
    ldr x0, [sp]
    bl _objc_autoreleasePoolPop
    XLEAVE

// set_title(cstr)
set_title:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x2, x0
    CLS x0, NSString
    MSG stringWithUTF8String_
    mov x2, x0
    LDX x0, win
    MSG setTitle_
    ldp x29, x30, [sp], #16
    ret

// update_size(): pixel size, scale, window states; tells rhun when they change
update_size:
    ENTER 32
    stp d8, d9, [sp, #16]
    LDX x0, win
    cbz x0, 9f
    MSG backingScaleFactor
    fmov d8, d0
    LDX x0, view
    MSG bounds
    fmul d2, d2, d8
    fmul d3, d3, d8
    fcvtns w19, d2
    fcvtns w20, d3
    fcvt s0, d8
    STW s0, g_dpi_scale
    str d8, [sp]
    ADR x9, scale
    str d8, [x9]
    // states: bit0 zoomed, bit1 full screen, bit2 key
    LDX x0, win
    MSG styleMask
    ubfx x21, x0, #14, #1
    lsl w21, w21, #1
    LDX x0, win
    MSG isZoomed
    and w0, w0, #1
    orr w21, w21, w0
    LDX x0, win
    MSG isKeyWindow
    and w0, w0, #1
    orr w21, w21, w0, lsl #2
    STW w21, g_win_states
    bl place_buttons
    LDW w9, pw
    LDW w10, ph
    cmp w9, w19
    ccmp w10, w20, #0, eq
    b.eq 9f
    STW w19, pw
    STW w20, ph
    mov w0, w19
    mov w1, w20
    LDX x28, g_xsp
    XCALL app_on_resize
9:  ldp d8, d9, [sp, #16]
    LEAVE
    ret

// place_buttons(): traffic lights centered in rhun's title bar; its left inset leaves room
place_buttons:
    ENTER 64
    stp d8, d9, [sp]
    stp d10, d11, [sp, #16]
    stp d12, d13, [sp, #32]
    LDX x19, win
    cbz x19, 9f
    LDW d8, scale
    // title bar height in points
    ADR x9, g_mt
    ldr w9, [x9, #4 * 16]       // MI_TITLE
    scvtf d9, w9
    fdiv d9, d9, d8
    fcvtns w9, d9
    STW w9, tl_h
    LDW w10, g_win_states
    tbnz w10, #1, 8f            // full screen: the buttons live in the menu bar overlay
    mov x0, x19
    mov x2, #0                  // NSWindowCloseButton
    MSG standardWindowButton_
    cbz x0, 8f
    mov x20, x0
    MSG superview
    MSG superview               // titlebar container
    cbz x0, 8f
    mov x21, x0
    mov x0, x20
    MSG frame
    fmov d10, d3                // button height
    fmov d11, d2                // button width
    // container: the top d9 points of the window
    mov x0, x19
    MSG frame
    fsub d1, d3, d9
    fmov d0, xzr
    fmov d3, d9
    mov x0, x21
    MSG setFrame_
    // buttons: y centered, x from TL_X
    fsub d12, d9, d10
    fmov d13, #0.5
    fmul d12, d12, d13
    frintm d12, d12
    mov x22, #0
1:  mov x0, x19
    mov x2, x22
    MSG standardWindowButton_
    cbz x0, 2f
    mov x9, #TL_X
    mov x10, #TL_STEP
    madd x9, x10, x22, x9
    scvtf d0, x9
    fmov d1, d12
    MSG setFrameOrigin_
2:  add x22, x22, #1
    cmp x22, #3
    b.lo 1b
    // rhun's inset: past the zoom button plus the same margin
    mov x9, #TL_X + 2 * TL_STEP
    scvtf d0, x9
    fadd d0, d0, d11
    fmul d0, d0, d8
    fcvtns w9, d0
    STW w9, g_title_inset
    b 9f
8:  STW wzr, g_title_inset
9:  ldp d8, d9, [sp]
    ldp d10, d11, [sp, #16]
    ldp d12, d13, [sp, #32]
    LEAVE
    ret

// hook_titlebar(): AppKit lays the title bar out again now and then (key changes, resizes);
// the view holding the traffic lights becomes a subclass whose layout puts them back
hook_titlebar:
    ENTER 16
    LDX x0, win
    mov x2, #0
    MSG standardWindowButton_
    cbz x0, 9f
    MSG superview
    cbz x0, 9f
    mov x19, x0
    bl _object_getClass
    mov x20, x0
    STX x20, tb_super
    ADR x0, s_RhunTitlebarView
    bl _objc_getClass
    cbnz x0, 1f
    mov x0, x20
    ADR x1, s_RhunTitlebarView
    mov x2, #0
    bl _objc_allocateClassPair
    mov x21, x0
    SEL x1, layout
    ADR x2, tb_layout
    ADR x3, t_v
    bl _class_addMethod
    mov x0, x21
    bl _objc_registerClassPair
    mov x0, x21
1:  mov x1, x0
    mov x0, x19
    bl _object_setClass
9:  LEAVE
    ret

// layout: AppKit's, then the traffic lights where rhun wants them
tb_layout:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [sp, #16]
    LDX x9, tb_super
    str x9, [sp, #24]
    add x0, sp, #16
    SEL x1, layout
    bl _objc_msgSendSuper
    bl place_buttons
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------- drawing

// render(): draw a frame into a free surface and show it. With every surface still on the window
// server the frame waits: drawing into one would show it half drawn. pace tells p_timeout when to
// come back for a frame still due: at once when the frame asked for another, soon when it waited
render:
    ENTER 32
    mov w9, #-1
    STW w9, pace
    LDW w19, pw
    LDW w20, ph
    cbz w19, 9f
    cbz w20, 9f
    LDW w9, sw
    LDW w10, sh
    cmp w9, w19
    ccmp w10, w20, #0, eq
    b.eq 1f
    bl surfaces_make
1:  // a surface the window server is done with
    LDW w21, cur
    mov w22, #0
2:  add w21, w21, #1
    cmp w21, #NSURS
    csel w21, wzr, w21, hs
    ADR x9, surfs
    ldr x23, [x9, w21, uxtw #3]
    cbz x23, 9f
    mov x0, x23
    bl _IOSurfaceIsInUse
    cbz w0, 3f
    add w22, w22, #1
    cmp w22, #NSURS
    b.lo 2b
    mov w9, #2
    STW w9, pace
    b 9f
3:  STW w21, cur
    mov x0, x23
    mov w1, #0
    mov x2, #0
    bl _IOSurfaceLock
    mov x0, x23
    bl _IOSurfaceGetBytesPerRow
    lsr x24, x0, #2
    mov x0, x23
    bl _IOSurfaceGetBaseAddress
    mov w1, w19
    mov w2, w20
    mov w3, w24
    LDX x28, g_xsp
    XCALL gfx_set_target
    STW wzr, g_dirty
    XCALL app_render
    LDW w9, g_dirty
    cbz w9, 30f
    STW wzr, pace
30:
    mov x0, x23
    mov w1, #0
    mov x2, #0
    bl _IOSurfaceUnlock
    CLS x0, CATransaction
    MSG begin
    CLS x0, CATransaction
    mov x2, #1
    MSG setDisableActions_
    LDX x0, layer
    mov x2, x23
    MSG setContents_
    CLS x0, CATransaction
    MSG commit
    bl follow_theme
    // the window appears with its first frame
    LDW w9, shown
    cbnz w9, 31f
    mov w9, #1
    STW w9, shown
    LDX x0, win
    mov x2, #0
    MSG makeKeyAndOrderFront_
    LDX x0, app
    mov x2, #1
    MSG activateIgnoringOtherApps_
31:
    // title bar height follows rhun's ui scale
    ADR x9, g_mt
    ldr w9, [x9, #4 * 16]
    LDW w10, tl_px
    cmp w9, w10
    b.eq 4f
    STW w9, tl_px
    bl place_buttons
4:  // window requests made while drawing
    LDW w19, pending
    cbz w19, 9f
    STW wzr, pending
    tbz w19, #0, 5f
    LDX x0, win
    LDX x2, last_down
    cbz x2, 5f
    MSG performWindowDragWithEvent_
5:  tbz w19, #1, 6f
    bl title_double_click
6:  tbz w19, #2, 9f
    LDX x0, win
    mov x2, #0
    MSG miniaturize_
9:  LEAVE
    ret

// surfaces_make(): pw x ph BGRA surfaces in sRGB
surfaces_make:
    ENTER 32
    mov x19, #0
1:  ADR x9, surfs
    ldr x0, [x9, x19, lsl #3]
    str xzr, [x9, x19, lsl #3]
    cbz x0, 2f
    bl _CFRelease
2:  add x19, x19, #1
    cmp x19, #NSURS
    b.lo 1b
    LDW w9, pw
    LDW w10, ph
    STW w9, sw
    STW w10, sh
    // properties
    mov x0, #0
    mov x1, #0
    adrp x2, _kCFTypeDictionaryKeyCallBacks@GOTPAGE
    ldr x2, [x2, _kCFTypeDictionaryKeyCallBacks@GOTPAGEOFF]
    adrp x3, _kCFTypeDictionaryValueCallBacks@GOTPAGE
    ldr x3, [x3, _kCFTypeDictionaryValueCallBacks@GOTPAGEOFF]
    bl _CFDictionaryCreateMutable
    mov x20, x0
    EXT x1, _kIOSurfaceWidth
    LDW w2, pw
    bl dict_int
    EXT x1, _kIOSurfaceHeight
    LDW w2, ph
    bl dict_int
    EXT x1, _kIOSurfaceBytesPerElement
    mov w2, #4
    bl dict_int
    EXT x1, _kIOSurfacePixelFormat
    mov w2, #0x5241             // 'BGRA'
    movk w2, #0x4247, lsl #16
    bl dict_int
    EXT x0, _kCGColorSpaceSRGB
    bl _CGColorSpaceCreateWithName
    mov x21, x0
    bl _CGColorSpaceCopyPropertyList
    mov x22, x0
    mov x19, #0
3:  mov x0, x20
    bl _IOSurfaceCreate
    ADR x9, surfs
    str x0, [x9, x19, lsl #3]
    cbz x0, 4f
    EXT x1, _kIOSurfaceColorSpace
    mov x2, x22
    bl _IOSurfaceSetValue
4:  add x19, x19, #1
    cmp x19, #NSURS
    b.lo 3b
    mov x0, x22
    bl _CFRelease
    mov x0, x21
    bl _CGColorSpaceRelease
    mov x0, x20
    bl _CFRelease
    LEAVE
    ret

// dict_int(x20 dict, x1 key, w2 value)
dict_int:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    str x1, [sp, #16]
    str w2, [sp, #24]
    mov x0, #0
    mov x1, #3                  // kCFNumberSInt32Type
    add x2, sp, #24
    bl _CFNumberCreate
    str x0, [sp, #32]
    mov x2, x0
    ldr x1, [sp, #16]
    mov x0, x20
    bl _CFDictionarySetValue
    ldr x0, [sp, #32]
    bl _CFRelease
    ldp x29, x30, [sp], #48
    ret

// Return the effective system appearance, independent of the window's explicit appearance.
FN mac_system_appearance_dark
    XENTRY
    CLS x0, NSApplication
    MSG sharedApplication
    MSG effectiveAppearance
    MSG name
    EXT x2, _NSAppearanceNameDarkAqua
    MSG isEqualToString_
    cmp x0, #0
    cset w8, ne
    XLEAVE

// follow_theme(): the window's appearance (traffic lights, menus) matches a dark or light theme
follow_theme:
    ENTER
    LDW w19, g_theme_dark
    LDW w9, appearance
    add w19, w19, #1
    cmp w9, w19
    b.eq 9f
    STW w19, appearance
    EXT x2, _NSAppearanceNameAqua
    cmp w19, #1
    b.eq 1f
    EXT x2, _NSAppearanceNameDarkAqua
1:  CLS x0, NSAppearance
    MSG appearanceNamed_
    mov x2, x0
    LDX x0, win
    MSG setAppearance_
9:  LEAVE
    ret

// title_double_click(): what the user set for a double click on a title bar
title_double_click:
    ENTER
    CLS x0, NSUserDefaults
    MSG standardUserDefaults
    mov x19, x0
    CLS x0, NSString
    ADR x2, s_dblclick
    MSG stringWithUTF8String_
    mov x2, x0
    mov x0, x19
    MSG stringForKey_
    cbz x0, 3f
    mov x19, x0
    MSG UTF8String
    ldrb w9, [x0]
    cmp w9, #'N'                // None
    b.eq 9f
    cmp w9, #'M'                // Minimize (Maximize is the default)
    b.ne 3f
    ldrb w9, [x0, #1]
    cmp w9, #'i'
    b.ne 3f
    LDX x0, win
    mov x2, #0
    MSG miniaturize_
    b 9f
3:  LDX x0, win
    mov x2, #0
    MSG zoom_
9:  LEAVE
    ret

// ---------------------------------------------------------------- platform table (from rhun)

p_nop:
    XRET

// p_timeout: forever, unless a frame is still due (render's pace)
p_timeout:
    mov x8, #-1
    LDW w9, g_dirty
    cbz w9, 1f
    LDW w9, pace
    sxtw x8, w9
1:  XRET

p_draw:
    XENTRY
    bl _objc_autoreleasePoolPush
    mov x19, x0
    bl render
    mov x0, x19
    bl _objc_autoreleasePoolPop
    XLEAVE

// p_cursor(shape)
p_cursor:
    XENTRY
    LDW w9, cursor
    cmp w9, w0
    b.eq 9f
    STW w0, cursor
    bl cursor_set
9:  XLEAVE

cursor_set:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    LDW w9, cursor
    cmp w9, #6
    b.ls 1f
    mov w9, #0
1:  ADR x10, cursor_sels
    ldr x1, [x10, w9, uxtw #3]
    ldr x1, [x1]
    CLS x0, NSCursor
    bl _objc_msgSend
    MSG set
    ldp x29, x30, [sp], #16
    ret

// p_clip_set(ptr, len)
p_clip_set:
    XENTRY
    mov x19, x0
    mov x20, x1
    CLS x0, NSString
    MSG alloc
    mov x2, x19
    mov x3, x20
    mov x4, #4                  // NSUTF8StringEncoding
    MSG initWithBytes_length_encoding_
    mov x19, x0
    CLS x0, NSPasteboard
    MSG generalPasteboard
    mov x20, x0
    MSG clearContents
    cbz x19, 9f
    mov x0, x20
    mov x2, x19
    EXT x3, _NSPasteboardTypeString
    MSG setString_forType_
    mov x0, x19
    MSG release
9:  XLEAVE

// p_clip_get(): app_on_paste(text) right away
p_clip_get:
    XENTRY
    bl _objc_autoreleasePoolPush
    mov x21, x0
    CLS x0, NSPasteboard
    MSG generalPasteboard
    EXT x2, _NSPasteboardTypeString
    MSG stringForType_
    cbz x0, 9f
    MSG UTF8String
    cbz x0, 9f
    mov x19, x0
    bl _strlen
    mov x1, x0
    mov x0, x19
    XCALL app_on_paste
9:  mov x0, x21
    bl _objc_autoreleasePoolPop
    XLEAVE

// window requests come while drawing; they run after the frame
p_move:
    mov w9, #1
    b 1f
p_maximize:
    mov w9, #2
    b 1f
p_minimize:
    mov w9, #4
1:  LDW w10, pending
    orr w10, w10, w9
    STW w10, pending
    XRET

// p_title(cstr)
p_title:
    XENTRY
    mov x19, x0
    bl _objc_autoreleasePoolPush
    mov x20, x0
    mov x0, x19
    bl set_title
    mov x0, x20
    bl _objc_autoreleasePoolPop
    XLEAVE

// ---------------------------------------------------------------- event loop

// gui_poll(fds, n, timeout ms) -> ready count: poll() while the window is open
gui_poll:
    ENTER 48
    mov x19, x0
    mov x20, x1
    mov w21, w2
    bl _objc_autoreleasePoolPush
    mov x22, x0
    // ready already?
    mov x0, x19
    mov x1, x20
    mov w2, #0
    bl _poll
    cbnz w0, 8f
    bl drain
    cbnz w0, 7f
    cbz w21, 7f
    // wait on the run loop: events, the descriptors (through the kqueue) or the timeout
    mov x0, x19
    mov x1, x20
    bl kq_arm
    ldr d0, f_forever
    tbnz w21, #31, 1f
    scvtf d0, w21
    ldr d1, f_1000
    fdiv d0, d0, d1
1:  EXT x0, _kCFRunLoopDefaultMode
    mov w1, #1
    bl _CFRunLoopRunInMode
    bl drain
7:  mov x0, x19
    mov x1, x20
    mov w2, #0
    bl _poll
8:  sxtw x23, w0
    mov x0, x22
    bl _objc_autoreleasePoolPop
    cmn x23, #1
    b.ne 9f
    bl ___error
    ldr w0, [x0]
    bl linux_errno
    neg x23, x0
9:  mov x0, x23
    LEAVE
    ret

// drain() -> events dispatched
drain:
    ENTER 16
    mov x19, #0
    LDX x20, app
    CLS x0, NSDate
    MSG distantPast
    mov x21, x0
1:  mov x0, x20
    mov x2, #-1                 // NSEventMaskAny
    mov x3, x21
    EXT x4, _NSDefaultRunLoopMode
    mov x5, #1
    MSG nextEventMatchingMask_untilDate_inMode_dequeue_
    cbz x0, 9f
    mov x2, x0
    mov x0, x20
    MSG sendEvent_
    add x19, x19, #1
    b 1b
9:  mov x0, x19
    LEAVE
    ret

// the kqueue that wakes the run loop for rhun's descriptors
kq_init:
    ENTER 32
    bl _kqueue
    STW w0, kq
    mov w1, w0
    mov x0, #0
    mov w2, #0
    ADR x3, kq_fired
    mov x4, #0
    bl _CFFileDescriptorCreate
    STX x0, kq_cffd
    mov x19, x0
    mov x0, #0
    mov x1, x19
    mov x2, #0
    bl _CFFileDescriptorCreateRunLoopSource
    mov x20, x0
    bl _CFRunLoopGetMain
    mov x1, x20
    EXT x2, _kCFRunLoopCommonModes
    bl _CFRunLoopAddSource
    LEAVE
    ret

// kq_arm(fds, n): one-shot read/write filters for the polled descriptors
kq_arm:
    ENTER 64
    mov x19, x0
    mov x20, x1
    mov x21, #0
1:  cmp x21, x20
    b.hs 8f
    add x22, x19, x21, lsl #3
    ldr w23, [x22]              // fd
    ldrh w24, [x22, #4]         // events
    tbnz w23, #31, 7f
    tst w24, #1                 // POLLIN
    b.eq 2f
    mov w1, #-1                 // EVFILT_READ
    bl kq_add
2:  tst w24, #4                 // POLLOUT
    b.eq 7f
    mov w1, #-2                 // EVFILT_WRITE
    bl kq_add
7:  add x21, x21, #1
    b 1b
8:  LDX x0, kq_cffd
    mov x1, #1                  // kCFFileDescriptorReadCallBack
    bl _CFFileDescriptorEnableCallBacks
    LEAVE
    ret

// kq_add(w23 fd, w1 filter)
kq_add:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    add x9, sp, #16             // struct kevent
    str x23, [x9, #0]           // ident
    strh w1, [x9, #8]           // filter
    mov w10, #0x11              // EV_ADD | EV_ONESHOT
    strh w10, [x9, #10]
    str wzr, [x9, #12]
    stp xzr, xzr, [x9, #16]
    LDW w0, kq
    mov x1, x9
    mov w2, #1
    mov x3, #0
    mov w4, #0
    mov x5, #0
    bl _kevent
    ldp x29, x30, [sp], #64
    ret

// kq_fired(cffd, flags, info): consume the events; the run loop returns to gui_poll
kq_fired:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #528
    stp xzr, xzr, [sp]          // zero timeout
    LDW w0, kq
    mov x1, #0
    mov w2, #0
    add x3, sp, #16
    mov w4, #16
    mov x5, sp
    bl _kevent
    mov sp, x29
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------- keyboard

// mods(flags) -> rhun modifier bits: Command and Control both count as Ctrl
ns_mods:
    mov w9, #0
    tst x0, #NS_SHIFT
    b.eq 1f
    orr w9, w9, #MOD_SHIFT
1:  tst x0, #NS_CONTROL
    b.eq 11f
    orr w9, w9, #MOD_CTRL
11: tst x0, #NS_COMMAND
    b.eq 2f
    orr w9, w9, #MOD_CTRL
2:  tst x0, #NS_OPTION
    b.eq 3f
    orr w9, w9, #MOD_ALT
3:  mov w0, w9
    ret

// keyDown:(event)
v_keyDown:
    IMP 48
    mov x19, x0
    mov x20, x2
    str x20, [sp, #16]
    mov x0, x20
    MSG modifierFlags
    mov x21, x0                 // NS flags
    bl ns_mods
    mov w22, w0                 // rhun mods
    STW w22, key_mods
    // Command without Control: the terminal leaves it to rhun
    ubfx x9, x21, #20, #1       // Command
    ubfx x10, x21, #18, #1      // Control
    bic w9, w9, w10
    STW w9, g_mac_cmd
    // text being composed: the input method gets every key
    LDW w9, marked
    cbnz w9, Lkd_ime
    mov x0, x20
    MSG keyCode
    and w23, w0, #0xffff
    cmp w23, #128
    b.hs Lkd_char
    ADR x9, special_keys
    ldr w24, [x9, w23, uxtw #2]
    cbz w24, Lkd_char
    // Mac text navigation: Command for line and document ends, Option for words
    tst x21, #NS_COMMAND
    b.eq 3f
    ldr w9, key_left
    cmp w24, w9
    b.ne 1f
    ldr w24, key_home
    and w22, w22, #~MOD_CTRL
    b 5f
1:  ldr w9, key_right
    cmp w24, w9
    b.ne 11f
    ldr w24, key_end
    and w22, w22, #~MOD_CTRL
    b 5f
11: ldr w9, key_up
    cmp w24, w9
    b.ne 12f
    ldr w24, key_home
    b 5f
12: ldr w9, key_down
    cmp w24, w9
    b.ne 13f
    ldr w24, key_end
    b 5f
13: ldr w9, key_bs              // Command-Backspace: delete to the line start
    cmp w24, w9
    b.ne 5f
    tst x21, #NS_CONTROL
    b.ne 5f
    ldr w0, key_home
    mov w1, #0
    mov w2, #MOD_SHIFT
    XCALL app_on_key
    ldr w24, key_bs
    mov w22, #0
    b 5f
3:  tst x21, #NS_OPTION
    b.eq 5f
    ldr w9, key_left
    ldr w10, key_right
    cmp w24, w9
    ccmp w24, w10, #4, ne
    b.eq 4f
    ldr w9, key_bs
    ldr w10, key_delete
    cmp w24, w9
    ccmp w24, w10, #4, ne
    b.ne 5f
4:  and w22, w22, #~MOD_ALT
    orr w22, w22, #MOD_CTRL
5:  mov w0, w24
    mov w1, #0
    mov w2, w22
    XCALL app_on_key
    b Lkd_done
Lkd_char:
    // shortcuts: the key's character without modifiers (Shift aside); on a layout that is not
    // Latin, the key's character on the ASCII-capable layout, as Linux takes the first layout
    mov x0, x20
    MSG charactersIgnoringModifiers
    bl first_cp
    mov w24, w0
    cbz w24, Lkd_ime
    cmp w24, #0x80
    b.lo 51f
    tst w22, #MOD_CTRL | MOD_ALT
    b.eq 51f
    mov w0, w23
    ubfx x1, x21, #17, #1       // Shift
    bl ascii_key
    cbz w0, 51f
    mov w24, w0
51:
    // letters bind lowercase, as rhun looks them up
    tst w22, #MOD_CTRL
    b.ne 6f
    tst w22, #MOD_ALT
    b.eq Lkd_ime
    // Option: a binding wins, otherwise the character it types
    mov w0, w24
    mov w1, w22
    XCALL keys_lookup
    cbz x8, Lkd_ime
6:  mov w0, w24
    mov w1, w24
    mov w2, w22
    XCALL app_on_key
    b Lkd_done
Lkd_ime:
    // the input method: plain text, dead keys, composed input
    STW wzr, key_handled
    CLS x0, NSArray
    mov x2, x20
    MSG arrayWithObject_
    mov x2, x0
    mov x0, x19
    MSG interpretKeyEvents_
Lkd_done:
    STW wzr, g_mac_cmd
    IMPRET

// ascii_key(w0 key code, w1 shift) -> the character of the key on the current ASCII-capable
// keyboard layout, or 0
ascii_key:
    ENTER 32
    mov w19, w0
    mov w20, w1
    bl _TISCopyCurrentASCIICapableKeyboardLayoutInputSource
    cbz x0, 8f
    mov x21, x0
    EXT x1, _kTISPropertyUnicodeKeyLayoutData
    bl _TISGetInputSourceProperty
    cbz x0, 7f
    bl _CFDataGetBytePtr
    mov x22, x0
    bl _LMGetKbdType
    mov w4, w0                  // keyboard type
    mov x0, x22
    mov w1, w19                 // key code
    mov w2, #0                  // kUCKeyActionDown
    lsl w3, w20, #1             // shiftKey >> 8
    mov w5, #1                  // kUCKeyTranslateNoDeadKeysMask
    str wzr, [sp]               // dead key state
    add x6, sp, #0
    mov x7, #4                  // max length
    sub sp, sp, #16
    add x9, sp, #16 + 8
    str x9, [sp]                // actual length
    add x9, sp, #16 + 16
    str x9, [sp, #8]            // characters
    str xzr, [sp, #16 + 8]
    bl _UCKeyTranslate
    add sp, sp, #16
    mov w23, #0
    cbnz w0, 7f
    ldr x9, [sp, #8]
    cbz x9, 7f
    ldrh w23, [sp, #16]
7:  mov x0, x21
    bl _CFRelease
    mov w0, w23
    b 9f
8:  mov w0, #0
9:  LEAVE
    ret

// first_cp(NSString) -> first code point or 0
first_cp:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cbz x0, 9f
    MSG UTF8String
    cbz x0, 9f
    bl utf8_cp
9:  ldp x29, x30, [sp], #16
    ret

// utf8_cp(x0 ptr) -> w0 code point, x1 next
utf8_cp:
    ldrb w9, [x0]
    add x1, x0, #1
    cmp w9, #0x80
    b.lo 8f
    mov w10, #0
    cmp w9, #0xe0
    b.hs 1f
    and w9, w9, #0x1f
    mov w10, #1
    b 4f
1:  cmp w9, #0xf0
    b.hs 2f
    and w9, w9, #0x0f
    mov w10, #2
    b 4f
2:  and w9, w9, #0x07
    mov w10, #3
4:  ldrb w11, [x1]
    and w12, w11, #0xc0
    cmp w12, #0x80
    b.ne 8f
    add x1, x1, #1
    and w11, w11, #0x3f
    orr w9, w11, w9, lsl #6
    subs w10, w10, #1
    b.ne 4b
8:  mov w0, w9
    ret

// insertText:(string) replacementRange:(range): typed text
v_insertText:
    IMP 32
    STW wzr, marked
    mov x19, x2
    mov x0, x19
    CLS x2, NSAttributedString
    MSG isKindOfClass_
    cbz w0, 1f
    mov x0, x19
    MSG string
    mov x19, x0
1:  mov x0, x19
    MSG UTF8String
    cbz x0, 9f
    mov x20, x0
    LDW w21, key_mods
    and w21, w21, #MOD_SHIFT
2:  ldrb w9, [x20]
    cbz w9, 9f
    mov x0, x20
    bl utf8_cp
    mov x20, x1
    mov w22, w0
    // keysym: Latin-1 as is, other characters as Unicode keysyms
    mov w0, w22
    cmp w22, #0x100
    b.lo 3f
    orr w0, w22, #0x1000000
3:  cmp w22, #0x7f
    b.eq 2b
    sub w9, w22, #0xf, lsl #12
    sub w9, w9, #0x700
    cmp w9, #0x200
    b.lo 2b
    cmp w22, #0x20
    b.lo 2b
    mov w1, w22
    mov w2, w21
    XCALL app_on_key
    b 2b
9:  STW wzr, key_mods
    IMPRET

// setMarkedText:selectedRange:replacementRange:: composition in progress
v_setMarkedText:
    ENTER
    mov x0, x2
    MSG length
    cmp x0, #0
    cset w9, ne
    STW w9, marked
    LEAVE
    ret

v_unmarkText:
    STW wzr, marked
    ret

v_hasMarkedText:
    LDW w0, marked
    ret

// markedRange / selectedRange -> NSRange
v_markedRange:
    mov x0, #NSNotFound
    mov x1, #0
    ret

v_selectedRange:
    mov x0, #0
    mov x1, #0
    ret

v_nil:
    mov x0, #0
    ret

v_validAttributes:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    CLS x0, NSArray
    MSG array
    ldp x29, x30, [sp], #16
    ret

// firstRectForCharacterRange:actualRange: -> where the candidate window goes: under the
// caret while the editor has the focus, else at the pointer
v_firstRect:
    ENTER 32
    stp d8, d9, [sp]
    LDW w9, g_caret_ok
    cbz w9, 8f
    LDW w9, g_focus             // FOCUS_EDITOR
    cbnz w9, 8f
    LDW d8, scale
    LDW w9, g_lh
    scvtf d9, w9
    fdiv d9, d9, d8
    LDW w9, g_caret_x
    scvtf d0, w9
    fdiv d0, d0, d8
    LDW w9, g_caret_y
    scvtf d1, w9
    fdiv d1, d1, d8
    fadd d1, d1, d9
    LDX x0, view
    mov x2, #0
    MSG convertPoint_toView_
    LDX x0, win
    MSG convertPointToScreen_
    fmov d2, xzr
    fmov d3, d9
    b 9f
8:  CLS x0, NSEvent
    MSG mouseLocation
    fmov d2, xzr
    fmov d3, xzr
9:  ldp d8, d9, [sp]
    LEAVE
    ret

v_characterIndex:
    mov x0, #NSNotFound
    ret

v_doCommand:
    ret

v_yes:
    mov w0, #1
    ret

v_no:
    mov w0, #0
    ret

// ---------------------------------------------------------------- mouse

// point(event) -> w0 x, w1 y in pixels
ev_point:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str d8, [sp, #16]
    MSG locationInWindow
    LDX x0, view
    mov x2, #0
    MSG convertPoint_fromView_
    LDW d8, scale
    fmul d0, d0, d8
    fmul d1, d1, d8
    fcvtms w0, d0
    fcvtms w1, d1
    ldr d8, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// mouse(event, button, pressed): motion, then the button
mouse:
    ENTER 16
    mov x19, x0
    mov w20, w1
    mov w21, w2
    bl ev_point
    XCALL app_on_motion
    cbz w20, 9f
    mov x0, x19
    MSG modifierFlags
    bl ns_mods
    mov w2, w0
    mov w0, w20
    mov w1, w21
    XCALL app_on_button
9:  LEAVE
    ret

v_mouseDown:
    IMP
    mov x19, x2
    mov x0, x2
    MSG retain
    LDX x0, last_down
    cbz x0, 1f
    MSG release
1:  STX x19, last_down
    // Control-click is a right click
    mov x0, x19
    MSG modifierFlags
    mov w1, #1
    tst x0, #NS_CONTROL
    b.eq 2f
    mov w1, #3
2:  STW w1, left_as
    mov x0, x19
    mov w2, #1
    bl mouse
    IMPRET

v_mouseUp:
    IMP
    mov x0, x2
    LDW w1, left_as
    cbnz w1, 1f
    mov w1, #1
1:  mov w2, #0
    bl mouse
    IMPRET

v_rightMouseDown:
    IMP
    mov x0, x2
    mov w1, #3
    mov w2, #1
    bl mouse
    IMPRET

v_rightMouseUp:
    IMP
    mov x0, x2
    mov w1, #3
    mov w2, #0
    bl mouse
    IMPRET

v_otherMouseDown:
    IMP
    mov x19, x2
    mov x0, x2
    MSG buttonNumber
    cmp x0, #2
    b.ne 9f
    mov x0, x19
    mov w1, #2
    mov w2, #1
    bl mouse
9:  IMPRET

v_otherMouseUp:
    IMP
    mov x19, x2
    mov x0, x2
    MSG buttonNumber
    cmp x0, #2
    b.ne 9f
    mov x0, x19
    mov w1, #2
    mov w2, #0
    bl mouse
9:  IMPRET

v_mouseMoved:
    IMP
    mov x0, x2
    mov w1, #0
    mov w2, #0
    bl mouse
    IMPRET

v_mouseExited:
    IMP
    XCALL app_on_pointer_leave
    IMPRET

// scrollWheel:: trackpads give points, wheels give lines
v_scrollWheel:
    IMP 32
    stp d8, d9, [sp]
    mov x19, x2
    mov x0, x19
    MSG scrollingDeltaX
    fmov d8, d0
    mov x0, x19
    MSG scrollingDeltaY
    fmov d9, d0
    mov x0, x19
    MSG hasPreciseScrollingDeltas
    LDW d0, scale
    cbnz w0, 1f
    ldr d1, f_line
    fmul d0, d0, d1
1:  fneg d0, d0
    fmul d8, d8, d0
    fmul d9, d9, d0
    // whole pixels now, the fractions later
    ADR x9, scroll_rem
    ldp d0, d1, [x9]
    fadd d8, d8, d0
    fadd d9, d9, d1
    frintz d0, d8
    frintz d1, d9
    fsub d2, d8, d0
    fsub d3, d9, d1
    stp d2, d3, [x9]
    fcvtzs w20, d0
    fcvtzs w21, d1
    orr w9, w20, w21
    cbz w9, 9f
    // with Command or Control an image zooms
    mov x0, x19
    MSG modifierFlags
    bl ns_mods
    mov w2, w0
    mov w0, w20
    mov w1, w21
    XCALL app_on_scroll
9:  ldp d8, d9, [sp]
    IMPRET

// cursorUpdate:: the cursor rhun asked for
v_cursorUpdate:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl cursor_set
    ldp x29, x30, [sp], #16
    ret

// updateTrackingAreas: moves and exits over the whole view
v_updateTrackingAreas:
    ENTER
    mov x19, x0
    LDX x2, tracking
    cbz x2, 1f
    mov x0, x19
    MSG removeTrackingArea_
    LDX x0, tracking
    MSG release
1:  CLS x0, NSTrackingArea
    MSG alloc
    fmov d0, xzr
    fmov d1, xzr
    fmov d2, xzr
    fmov d3, xzr
    mov x2, #0x1 | 0x2 | 0x4 | 0x80 | 0x200   // entered/exited, moved, cursor update, always, in visible rect
    mov x3, x19
    mov x4, #0
    MSG initWithRect_options_owner_userInfo_
    STX x0, tracking
    mov x2, x0
    mov x0, x19
    MSG addTrackingArea_
    // [super updateTrackingAreas]
    stp x19, xzr, [sp, #-16]!
    CLS x9, NSView
    str x9, [sp, #8]
    mov x0, sp
    SEL x1, updateTrackingAreas
    bl _objc_msgSendSuper
    add sp, sp, #16
    LEAVE
    ret

// setFrameSize:(size): a live resize draws right away
v_setFrameSize:
    IMP 32
    stp d0, d1, [sp]
    stp x0, xzr, [sp, #16]
    CLS x9, NSView
    str x9, [sp, #24]
    add x0, sp, #16
    ldp d0, d1, [sp]
    SEL x1, setFrameSize_
    bl _objc_msgSendSuper
    LDX x9, win
    cbz x9, 9f
    bl update_size
    bl render
9:  IMPRET

v_viewDidChangeBackingProperties:
    IMP
    bl update_size
    mov w9, #1
    STW w9, g_dirty
    IMPRET

// ---------------------------------------------------------------- window and app delegates

w_shouldClose:
    IMP
    XCALL app_on_close
    mov w0, #0
    IMPRET

w_becomeKey:
    IMP
    mov w0, #1
    XCALL app_on_focus
    bl update_size
    IMPRET

w_resignKey:
    IMP
    mov w0, #0
    XCALL app_on_focus
    bl update_size
    IMPRET

w_changed:
    IMP
    bl update_size
    mov w9, #1
    STW w9, g_dirty
    IMPRET

// applicationShouldTerminate: rhun asks about unsaved files and quits itself
a_shouldTerminate:
    IMP
    XCALL app_on_close
    mov x0, #0                  // NSTerminateCancel
    IMPRET

// application:openURLs:: files and folders from Finder and the Dock
a_openURLs:
    IMP
    mov x19, x3
    mov x0, x19
    MSG count
    mov x20, x0
    mov x21, #0
1:  cmp x21, x20
    b.hs 9f
    mov x0, x19
    mov x2, x21
    MSG objectAtIndex_
    MSG fileSystemRepresentation
    cbz x0, 2f
    XCALL app_open_startup_path
2:  add x21, x21, #1
    b 1b
9:  mov w9, #1
    STW w9, g_dirty
    bl activate_window
    IMPRET

activate_window:
    ENTER
    LDX x0, win
    cbz x0, 9f                // initial URLs arrive before the window exists
    mov x2, #0
    MSG deminiaturize_
    LDX x0, app
    mov x2, #1
    MSG activateIgnoringOtherApps_
    LDX x0, win
    mov x2, #0
    MSG makeKeyAndOrderFront_
9:  LEAVE
    ret

a_reopen:
    ENTER
    bl activate_window
    mov w0, #1
    LEAVE
    ret

a_settings:
    IMP
    XCALL cmd_settings
    mov w9, #1
    STW w9, g_dirty
    IMPRET

// ---------------------------------------------------------------- classes and menu

// make_class(super x0 cstr, name x1 cstr, methods x2) -> class
make_class:
    ENTER
    mov x19, x1
    mov x20, x2
    bl _objc_getClass
    mov x1, x19
    mov x2, #0
    bl _objc_allocateClassPair
    mov x19, x0
1:  ldr x9, [x20]
    cbz x9, 2f
    ldr x1, [x9]                // selector
    ldr x2, [x20, #8]           // imp
    ldr x3, [x20, #16]          // types
    mov x0, x19
    bl _class_addMethod
    add x20, x20, #24
    b 1b
2:  mov x0, x19
    bl _objc_registerClassPair
    mov x0, x19
    LEAVE
    ret

make_classes:
    ENTER
    ADR x0, s_NSView
    ADR x1, s_RhunView
    ADR x2, view_methods
    bl make_class
    STX x0, cls_view
    mov x19, x0
    ADR x0, s_NSTextInputClient
    bl _objc_getProtocol
    mov x1, x0
    mov x0, x19
    cbz x1, 1f
    bl _class_addProtocol
1:  ADR x0, s_NSObject
    ADR x1, s_RhunWindowDelegate
    ADR x2, windel_methods
    bl make_class
    STX x0, cls_windel
    ADR x0, s_NSObject
    ADR x1, s_RhunAppDelegate
    ADR x2, appdel_methods
    bl make_class
    STX x0, cls_appdel
    ADR x0, s_NSWindow
    bl _objc_getClass
    STX x0, cls_window
    LEAVE
    ret

// item(menu x19, title cstr x0, action sel x1, key cstr x2, mask x3) -> item
menu_item:
    ENTER 32
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x2, x0
    CLS x0, NSString
    MSG stringWithUTF8String_
    mov x23, x0
    CLS x0, NSString
    mov x2, x21
    MSG stringWithUTF8String_
    mov x24, x0
    CLS x0, NSMenuItem
    MSG alloc
    mov x2, x23
    mov x3, x20
    mov x4, x24
    MSG initWithTitle_action_keyEquivalent_
    mov x21, x0
    cbz x22, 1f
    mov x2, x22
    MSG setKeyEquivalentModifierMask_
1:  mov x0, x19
    mov x2, x21
    MSG addItem_
    mov x0, x21
    MSG release
    mov x0, x21
    LEAVE
    ret

menu_sep:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    CLS x0, NSMenuItem
    MSG separatorItem
    mov x2, x0
    mov x0, x19
    MSG addItem_
    ldp x29, x30, [sp], #16
    ret

// submenu(bar x20, title cstr x0) -> x19 new menu
submenu:
    ENTER 16
    mov x21, x0
    mov x2, x0
    CLS x0, NSString
    MSG stringWithUTF8String_
    mov x22, x0
    CLS x0, NSMenu
    MSG alloc
    mov x2, x22
    MSG initWithTitle_
    mov x23, x0
    CLS x0, NSMenuItem
    MSG new
    mov x24, x0
    mov x2, x23
    MSG setSubmenu_
    mov x0, x20
    mov x2, x24
    MSG addItem_
    mov x0, x24
    MSG release
    mov x0, x23
    MSG autorelease
    mov x0, x23
    LEAVE
    ret

make_menu:
    ENTER 16
    CLS x0, NSMenu
    MSG new
    mov x20, x0
    // rhun
    ADR x0, s_rhun
    bl submenu
    mov x19, x0
    ADR x0, s_about
    SEL x1, orderFrontStandardAboutPanel_
    ADR x2, s_empty
    mov x3, #0
    bl menu_item
    bl menu_sep
    ADR x0, s_settings
    SEL x1, rhunSettings_
    ADR x2, s_empty
    mov x3, #0
    bl menu_item
    bl menu_sep
    ADR x0, s_hide
    SEL x1, hide_
    ADR x2, s_h
    mov x3, #0
    bl menu_item
    ADR x0, s_hide_others
    SEL x1, hideOtherApplications_
    ADR x2, s_h
    mov x3, #NS_COMMAND | NS_OPTION
    bl menu_item
    ADR x0, s_show_all
    SEL x1, unhideAllApplications_
    ADR x2, s_empty
    mov x3, #0
    bl menu_item
    bl menu_sep
    ADR x0, s_quit
    SEL x1, terminate_
    ADR x2, s_q
    mov x3, #0
    bl menu_item
    // Window
    ADR x0, s_window
    bl submenu
    mov x19, x0
    ADR x0, s_minimize
    SEL x1, performMiniaturize_
    ADR x2, s_m
    mov x3, #0
    bl menu_item
    ADR x0, s_zoom
    SEL x1, performZoom_
    ADR x2, s_empty
    mov x3, #0
    bl menu_item
    bl menu_sep
    ADR x0, s_fullscreen
    SEL x1, toggleFullScreen_
    ADR x2, s_f
    mov x3, #NS_COMMAND | NS_CONTROL
    bl menu_item
    LDX x0, app
    mov x2, x19
    MSG setWindowsMenu_
    LDX x0, app
    mov x2, x20
    MSG setMainMenu_
    mov x0, x20
    MSG release
    LEAVE
    ret

// ---------------------------------------------------------------- data

.p2align 3
f_win_w: .double 1200
f_win_h: .double 780
f_min_w: .double 480
f_min_h: .double 320
f_forever: .double 1e9
f_1000: .double 1000
f_line: .double 40
key_left: .long 0xff51
key_up: .long 0xff52
key_right: .long 0xff53
key_down: .long 0xff54
key_home: .long 0xff50
key_end: .long 0xff57
key_bs: .long 0xff08
key_delete: .long 0xffff

.section __DATA,__const
.p2align 3
plat_fns:
    .quad p_nop                 // P_flush
    .quad p_timeout
    .quad p_nop                 // P_tick
    .quad p_draw
    .quad p_cursor
    .quad p_clip_set
    .quad p_clip_get
    .quad p_move
    .quad p_nop                 // P_resize: AppKit resizes
    .quad p_minimize
    .quad p_maximize
    .quad p_title
    .quad p_nop                 // P_menu

// CUR_* -> NSCursor class methods
cursor_sels:
    .quad Ls_arrowCursor, Ls_IBeamCursor, Ls_pointingHandCursor, Ls_resizeLeftRightCursor
    .quad Ls_resizeUpDownCursor, Ls_arrowCursor, Ls_arrowCursor

// virtual key codes -> keysyms for keys that are not text
special_keys:
    .long 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0          // 0x00
    .long 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0          // 0x10
    .long 0, 0, 0, 0, 0xff0d, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0     // 0x20 Return
    .long 0xff09, 0, 0, 0xff08, 0, 0xff1b, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  // 0x30 Tab, Delete, Escape
    .long 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff8d, 0, 0, 0     // 0x40 keypad Enter
    .long 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0          // 0x50
    .long 0xffc2, 0xffc3, 0xffc4, 0xffc0, 0xffc5, 0xffc6, 0, 0xffc8  // 0x60 F5 F6 F7 F3 F8 F9 . F11
    .long 0, 0, 0, 0, 0, 0xffc7, 0, 0xffc9                        //      F10 F12
    .long 0, 0, 0xff63, 0xff50, 0xff55, 0xffff, 0xffc1, 0xff57    // 0x70 Help Home PgUp Del F4 End
    .long 0xffbf, 0xff56, 0xffbe, 0xff51, 0xff53, 0xff54, 0xff52, 0 // F2 PgDn F1 Left Right Down Up

// method tables: selector ref, implementation, type encoding
.macro METHOD sel, imp, types
    .quad Ls_\sel, \imp, \types
.endm
view_methods:
    METHOD isFlipped, v_yes, t_B
    METHOD isOpaque, v_yes, t_B
    METHOD acceptsFirstResponder, v_yes, t_B
    METHOD mouseDownCanMoveWindow, v_no, t_B
    METHOD wantsUpdateLayer, v_yes, t_B
    METHOD keyDown_, v_keyDown, t_v_id
    METHOD keyUp_, v_doCommand, t_v_id
    METHOD flagsChanged_, v_doCommand, t_v_id
    METHOD mouseDown_, v_mouseDown, t_v_id
    METHOD mouseUp_, v_mouseUp, t_v_id
    METHOD mouseDragged_, v_mouseMoved, t_v_id
    METHOD mouseMoved_, v_mouseMoved, t_v_id
    METHOD rightMouseDown_, v_rightMouseDown, t_v_id
    METHOD rightMouseUp_, v_rightMouseUp, t_v_id
    METHOD rightMouseDragged_, v_mouseMoved, t_v_id
    METHOD otherMouseDown_, v_otherMouseDown, t_v_id
    METHOD otherMouseUp_, v_otherMouseUp, t_v_id
    METHOD otherMouseDragged_, v_mouseMoved, t_v_id
    METHOD mouseExited_, v_mouseExited, t_v_id
    METHOD mouseEntered_, v_mouseMoved, t_v_id
    METHOD scrollWheel_, v_scrollWheel, t_v_id
    METHOD cursorUpdate_, v_cursorUpdate, t_v_id
    METHOD updateTrackingAreas, v_updateTrackingAreas, t_v
    METHOD setFrameSize_, v_setFrameSize, t_v_size
    METHOD viewDidChangeBackingProperties, v_viewDidChangeBackingProperties, t_v
    METHOD insertText_replacementRange_, v_insertText, t_insert
    METHOD setMarkedText_selectedRange_replacementRange_, v_setMarkedText, t_marked
    METHOD unmarkText, v_unmarkText, t_v
    METHOD hasMarkedText, v_hasMarkedText, t_B
    METHOD markedRange, v_markedRange, t_range
    METHOD selectedRange, v_selectedRange, t_range
    METHOD attributedSubstringForProposedRange_actualRange_, v_nil, t_attr
    METHOD validAttributesForMarkedText, v_validAttributes, t_id
    METHOD firstRectForCharacterRange_actualRange_, v_firstRect, t_rect
    METHOD characterIndexForPoint_, v_characterIndex, t_index
    METHOD doCommandBySelector_, v_doCommand, t_v_sel
    .quad 0
windel_methods:
    METHOD windowShouldClose_, w_shouldClose, t_B_id
    METHOD windowDidBecomeKey_, w_becomeKey, t_v_id
    METHOD windowDidResignKey_, w_resignKey, t_v_id
    METHOD windowDidResize_, w_changed, t_v_id
    METHOD windowDidEnterFullScreen_, w_changed, t_v_id
    METHOD windowDidExitFullScreen_, w_changed, t_v_id
    METHOD windowDidChangeBackingProperties_, w_changed, t_v_id
    .quad 0
appdel_methods:
    METHOD applicationShouldTerminate_, a_shouldTerminate, t_Q_id
    METHOD application_openURLs_, a_openURLs, t_v_id_id
    METHOD applicationShouldHandleReopen_hasVisibleWindows_, a_reopen, t_B_id_B
    METHOD applicationSupportsSecureRestorableState_, v_yes, t_B_id
    METHOD rhunSettings_, a_settings, t_v_id
    .quad 0

.section __TEXT,__cstring,cstring_literals
t_B: .asciz "B@:"
t_B_id: .asciz "B@:@"
t_B_id_B: .asciz "B@:@B"
t_Q_id: .asciz "Q@:@"
t_v: .asciz "v@:"
t_v_id: .asciz "v@:@"
t_v_id_id: .asciz "v@:@@"
t_v_sel: .asciz "v@::"
t_v_size: .asciz "v@:{CGSize=dd}"
t_id: .asciz "@@:"
t_insert: .asciz "v@:@{_NSRange=QQ}"
t_marked: .asciz "v@:@{_NSRange=QQ}{_NSRange=QQ}"
t_range: .asciz "{_NSRange=QQ}@:"
t_attr: .asciz "@@:{_NSRange=QQ}^{_NSRange=QQ}"
t_rect: .asciz "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}"
t_index: .asciz "Q@:{CGPoint=dd}"
s_NSView: .asciz "NSView"
s_NSObject: .asciz "NSObject"
s_NSWindow: .asciz "NSWindow"
s_NSTextInputClient: .asciz "NSTextInputClient"
s_RhunView: .asciz "RhunView"
s_RhunWindowDelegate: .asciz "RhunWindowDelegate"
s_RhunAppDelegate: .asciz "RhunAppDelegate"
s_RhunTitlebarView: .asciz "RhunTitlebarView"
s_autosave: .asciz "rhun"
s_dblclick: .asciz "AppleActionOnDoubleClick"
s_rhun: .asciz "rhun"
s_about: .asciz "About rhun"
s_settings: .asciz "Settings\342\200\246"
s_hide: .asciz "Hide rhun"
s_hide_others: .asciz "Hide Others"
s_show_all: .asciz "Show All"
s_quit: .asciz "Quit rhun"
s_window: .asciz "Window"
s_minimize: .asciz "Minimize"
s_zoom: .asciz "Zoom"
s_fullscreen: .asciz "Enter Full Screen"
s_empty: .asciz ""
s_h: .asciz "h"
s_q: .asciz "q"
s_m: .asciz "m"
s_f: .asciz "f"

.macro DEFSEL name, str
    .section __TEXT,__objc_methname,cstring_literals
Lsn_\name: .asciz "\str"
    .section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
    .p2align 3
Ls_\name: .quad Lsn_\name
.endm
DEFSEL alloc, "alloc"
DEFSEL new, "new"
DEFSEL release, "release"
DEFSEL retain, "retain"
DEFSEL autorelease, "autorelease"
DEFSEL sharedApplication, "sharedApplication"
DEFSEL setActivationPolicy_, "setActivationPolicy:"
DEFSEL setDelegate_, "setDelegate:"
DEFSEL finishLaunching, "finishLaunching"
DEFSEL deminiaturize_, "deminiaturize:"
DEFSEL initWithContentRect_styleMask_backing_defer_, "initWithContentRect:styleMask:backing:defer:"
DEFSEL setTitlebarAppearsTransparent_, "setTitlebarAppearsTransparent:"
DEFSEL setTitleVisibility_, "setTitleVisibility:"
DEFSEL setTabbingMode_, "setTabbingMode:"
DEFSEL setCollectionBehavior_, "setCollectionBehavior:"
DEFSEL setReleasedWhenClosed_, "setReleasedWhenClosed:"
DEFSEL setContentMinSize_, "setContentMinSize:"
DEFSEL initWithFrame_, "initWithFrame:"
DEFSEL setWantsLayer_, "setWantsLayer:"
DEFSEL setLayerContentsRedrawPolicy_, "setLayerContentsRedrawPolicy:"
DEFSEL layer, "layer"
DEFSEL setOpaque_, "setOpaque:"
DEFSEL setContentView_, "setContentView:"
DEFSEL makeFirstResponder_, "makeFirstResponder:"
DEFSEL setAcceptsMouseMovedEvents_, "setAcceptsMouseMovedEvents:"
DEFSEL stringWithUTF8String_, "stringWithUTF8String:"
DEFSEL setFrameUsingName_, "setFrameUsingName:"
DEFSEL setFrameAutosaveName_, "setFrameAutosaveName:"
DEFSEL center, "center"
DEFSEL setTitle_, "setTitle:"
DEFSEL makeKeyAndOrderFront_, "makeKeyAndOrderFront:"
DEFSEL activateIgnoringOtherApps_, "activateIgnoringOtherApps:"
DEFSEL backingScaleFactor, "backingScaleFactor"
DEFSEL bounds, "bounds"
DEFSEL styleMask, "styleMask"
DEFSEL isZoomed, "isZoomed"
DEFSEL isKeyWindow, "isKeyWindow"
DEFSEL standardWindowButton_, "standardWindowButton:"
DEFSEL superview, "superview"
DEFSEL frame, "frame"
DEFSEL setFrame_, "setFrame:"
DEFSEL setFrameOrigin_, "setFrameOrigin:"
DEFSEL begin, "begin"
DEFSEL commit, "commit"
DEFSEL setDisableActions_, "setDisableActions:"
DEFSEL setContents_, "setContents:"
DEFSEL performWindowDragWithEvent_, "performWindowDragWithEvent:"
DEFSEL miniaturize_, "miniaturize:"
DEFSEL zoom_, "zoom:"
DEFSEL appearanceNamed_, "appearanceNamed:"
DEFSEL effectiveAppearance, "effectiveAppearance"
DEFSEL name, "name"
DEFSEL isEqualToString_, "isEqualToString:"
DEFSEL setAppearance_, "setAppearance:"
DEFSEL standardUserDefaults, "standardUserDefaults"
DEFSEL stringForKey_, "stringForKey:"
DEFSEL UTF8String, "UTF8String"
DEFSEL set, "set"
DEFSEL arrowCursor, "arrowCursor"
DEFSEL IBeamCursor, "IBeamCursor"
DEFSEL pointingHandCursor, "pointingHandCursor"
DEFSEL resizeLeftRightCursor, "resizeLeftRightCursor"
DEFSEL resizeUpDownCursor, "resizeUpDownCursor"
DEFSEL initWithBytes_length_encoding_, "initWithBytes:length:encoding:"
DEFSEL generalPasteboard, "generalPasteboard"
DEFSEL clearContents, "clearContents"
DEFSEL setString_forType_, "setString:forType:"
DEFSEL stringForType_, "stringForType:"
DEFSEL distantPast, "distantPast"
DEFSEL nextEventMatchingMask_untilDate_inMode_dequeue_, "nextEventMatchingMask:untilDate:inMode:dequeue:"
DEFSEL sendEvent_, "sendEvent:"
DEFSEL modifierFlags, "modifierFlags"
DEFSEL keyCode, "keyCode"
DEFSEL charactersIgnoringModifiers, "charactersIgnoringModifiers"
DEFSEL characters, "characters"
DEFSEL arrayWithObject_, "arrayWithObject:"
DEFSEL interpretKeyEvents_, "interpretKeyEvents:"
DEFSEL isKindOfClass_, "isKindOfClass:"
DEFSEL string, "string"
DEFSEL length, "length"
DEFSEL array, "array"
DEFSEL mouseLocation, "mouseLocation"
DEFSEL locationInWindow, "locationInWindow"
DEFSEL convertPoint_fromView_, "convertPoint:fromView:"
DEFSEL convertPoint_toView_, "convertPoint:toView:"
DEFSEL convertPointToScreen_, "convertPointToScreen:"
DEFSEL buttonNumber, "buttonNumber"
DEFSEL scrollingDeltaX, "scrollingDeltaX"
DEFSEL scrollingDeltaY, "scrollingDeltaY"
DEFSEL hasPreciseScrollingDeltas, "hasPreciseScrollingDeltas"
DEFSEL removeTrackingArea_, "removeTrackingArea:"
DEFSEL addTrackingArea_, "addTrackingArea:"
DEFSEL initWithRect_options_owner_userInfo_, "initWithRect:options:owner:userInfo:"
DEFSEL count, "count"
DEFSEL objectAtIndex_, "objectAtIndex:"
DEFSEL fileSystemRepresentation, "fileSystemRepresentation"
DEFSEL initWithTitle_action_keyEquivalent_, "initWithTitle:action:keyEquivalent:"
DEFSEL setKeyEquivalentModifierMask_, "setKeyEquivalentModifierMask:"
DEFSEL addItem_, "addItem:"
DEFSEL separatorItem, "separatorItem"
DEFSEL initWithTitle_, "initWithTitle:"
DEFSEL setSubmenu_, "setSubmenu:"
DEFSEL setWindowsMenu_, "setWindowsMenu:"
DEFSEL setMainMenu_, "setMainMenu:"
DEFSEL orderFrontStandardAboutPanel_, "orderFrontStandardAboutPanel:"
DEFSEL rhunSettings_, "rhunSettings:"
DEFSEL hide_, "hide:"
DEFSEL hideOtherApplications_, "hideOtherApplications:"
DEFSEL unhideAllApplications_, "unhideAllApplications:"
DEFSEL terminate_, "terminate:"
DEFSEL performMiniaturize_, "performMiniaturize:"
DEFSEL performZoom_, "performZoom:"
DEFSEL toggleFullScreen_, "toggleFullScreen:"
DEFSEL isFlipped, "isFlipped"
DEFSEL layout, "layout"
DEFSEL isOpaque, "isOpaque"
DEFSEL acceptsFirstResponder, "acceptsFirstResponder"
DEFSEL mouseDownCanMoveWindow, "mouseDownCanMoveWindow"
DEFSEL wantsUpdateLayer, "wantsUpdateLayer"
DEFSEL keyDown_, "keyDown:"
DEFSEL keyUp_, "keyUp:"
DEFSEL flagsChanged_, "flagsChanged:"
DEFSEL mouseDown_, "mouseDown:"
DEFSEL mouseUp_, "mouseUp:"
DEFSEL mouseDragged_, "mouseDragged:"
DEFSEL mouseMoved_, "mouseMoved:"
DEFSEL rightMouseDown_, "rightMouseDown:"
DEFSEL rightMouseUp_, "rightMouseUp:"
DEFSEL rightMouseDragged_, "rightMouseDragged:"
DEFSEL otherMouseDown_, "otherMouseDown:"
DEFSEL otherMouseUp_, "otherMouseUp:"
DEFSEL otherMouseDragged_, "otherMouseDragged:"
DEFSEL mouseExited_, "mouseExited:"
DEFSEL mouseEntered_, "mouseEntered:"
DEFSEL scrollWheel_, "scrollWheel:"
DEFSEL cursorUpdate_, "cursorUpdate:"
DEFSEL updateTrackingAreas, "updateTrackingAreas"
DEFSEL setFrameSize_, "setFrameSize:"
DEFSEL viewDidChangeBackingProperties, "viewDidChangeBackingProperties"
DEFSEL insertText_replacementRange_, "insertText:replacementRange:"
DEFSEL setMarkedText_selectedRange_replacementRange_, "setMarkedText:selectedRange:replacementRange:"
DEFSEL unmarkText, "unmarkText"
DEFSEL hasMarkedText, "hasMarkedText"
DEFSEL markedRange, "markedRange"
DEFSEL selectedRange, "selectedRange"
DEFSEL attributedSubstringForProposedRange_actualRange_, "attributedSubstringForProposedRange:actualRange:"
DEFSEL validAttributesForMarkedText, "validAttributesForMarkedText"
DEFSEL firstRectForCharacterRange_actualRange_, "firstRectForCharacterRange:actualRange:"
DEFSEL characterIndexForPoint_, "characterIndexForPoint:"
DEFSEL doCommandBySelector_, "doCommandBySelector:"
DEFSEL windowShouldClose_, "windowShouldClose:"
DEFSEL windowDidBecomeKey_, "windowDidBecomeKey:"
DEFSEL windowDidResignKey_, "windowDidResignKey:"
DEFSEL windowDidResize_, "windowDidResize:"
DEFSEL windowDidEnterFullScreen_, "windowDidEnterFullScreen:"
DEFSEL windowDidExitFullScreen_, "windowDidExitFullScreen:"
DEFSEL windowDidChangeBackingProperties_, "windowDidChangeBackingProperties:"
DEFSEL applicationShouldTerminate_, "applicationShouldTerminate:"
DEFSEL application_openURLs_, "application:openURLs:"
DEFSEL applicationShouldHandleReopen_hasVisibleWindows_, "applicationShouldHandleReopen:hasVisibleWindows:"
DEFSEL applicationSupportsSecureRestorableState_, "applicationSupportsSecureRestorableState:"

.macro DEFCLS name
    .section __DATA,__objc_classrefs,regular,no_dead_strip
    .p2align 3
Lc_\name: .quad _OBJC_CLASS_$_\name
.endm
DEFCLS NSApplication
DEFCLS NSString
DEFCLS NSView
DEFCLS NSDate
DEFCLS NSArray
DEFCLS NSAttributedString
DEFCLS NSEvent
DEFCLS NSCursor
DEFCLS NSPasteboard
DEFCLS NSAppearance
DEFCLS NSUserDefaults
DEFCLS NSTrackingArea
DEFCLS NSMenu
DEFCLS NSMenuItem
DEFCLS CATransaction

.section __DATA,__objc_imageinfo,regular,no_dead_strip
    .long 0, 64

// x_key_test(keycode, state): X11 key injection for scripts; nothing to do here
FN x_key_test
    XRET

.data
.p2align 3
.globl g_csd, g_dpi_scale, g_win_states
app: .quad 0
win: .quad 0
view: .quad 0
layer: .quad 0
cls_view: .quad 0
cls_windel: .quad 0
cls_appdel: .quad 0
cls_window: .quad 0
last_down: .quad 0
tracking: .quad 0
kq_cffd: .quad 0
tb_super: .quad 0
scale: .double 1
scroll_rem: .double 0, 0
surfs: .quad 0, 0, 0
g_csd: .long 1
g_dpi_scale: .float 1.0
g_win_states: .long 0           // bit0 maximized, bit1 fullscreen, bit2 activated, bit3 tiled
pw: .long 0
ph: .long 0
sw: .long 0
sh: .long 0
cur: .long 0
pace: .long -1                  // ms until render should try again for a frame still due, -1 never
cursor: .long -1
marked: .long 0
key_mods: .long 0
.globl g_mac_cmd
g_mac_cmd: .long 0              // the key being handled has Command, not Control
key_handled: .long 0
left_as: .long 1
pending: .long 0
appearance: .long 0
tl_h: .long 0
tl_px: .long 0
shown: .long 0
kq: .long -1
