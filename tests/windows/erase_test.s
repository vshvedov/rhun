# Before the first frame, WM_ERASEBKGND paints the theme's background, not nothing (DWM then
# shows white: #99). After the first frame it leaves the window's pixels alone.
.include "win.inc"
.bss
dc: .quad 0
.text
FN main
    PROLOGUE 64
    mov dword ptr [rip + g_theme + 4 * T_BG], 0xff1c1e24
    xor ecx, ecx
    API CreateCompatibleDC
    test rax, rax
    jz 8f
    mov [rip + dc], rax
    mov ecx, 4
    mov edx, 4
    mov r8d, 1
    mov r9d, 32
    mov qword ptr [rsp + 32], 0
    API CreateBitmap
    test rax, rax
    jz 8f
    mov rcx, [rip + dc]
    mov rdx, rax
    API SelectObject
    # no frame yet: the erase paints the background
    call white
    call erase
    cmp eax, 1
    jne 8f
    call pixel
    cmp eax, 0x00241e1c          # COLORREF is 0x00bbggrr
    jne 8f
    # a frame was presented: the erase keeps what is there
    mov dword ptr [rip + win_presented], 1
    call white
    call erase
    cmp eax, 1
    jne 8f
    call pixel
    cmp eax, 0x00ffffff
    jne 8f
    xor eax, eax
    EPILOGUE
8:  mov eax, 1
    EPILOGUE

white:
    PROLOGUE 64
    mov rcx, [rip + dc]
    xor edx, edx
    xor r8d, r8d
    mov r9d, 4
    mov qword ptr [rsp + 32], 4
    mov qword ptr [rsp + 40], 0x00ff0062   # WHITENESS
    API PatBlt
    EPILOGUE

erase:
    PROLOGUE 64
    xor ecx, ecx
    mov edx, 0x14                # WM_ERASEBKGND
    mov r8, [rip + dc]
    xor r9d, r9d
    call win_wndproc
    EPILOGUE

pixel:
    PROLOGUE 64
    mov rcx, [rip + dc]
    mov edx, 1
    mov r8d, 2
    API GetPixel
    EPILOGUE
