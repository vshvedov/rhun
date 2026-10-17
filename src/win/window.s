# Win32 window, keyboard/mouse input, clipboard and DIB presentation.
.include "win.inc"
.bss
.p2align 4
win_hwnd: .quad 0
win_pixels: .quad 0
win_capacity: .quad 0
win_width: .long 0
win_height: .long 0
win_surrogate: .long 0
win_cursor: .quad 0
win_class: .zero 80
win_bmi: .zero 44
win_message: .zero 48
wheel_rem: .long 0, 0       # half a pixel left from the wheel, vertical and horizontal
.text

FN win_open_window
    PROLOGUE 96
    mov rcx, -4                # per-monitor-v2 DPI awareness
    API SetProcessDpiAwarenessContext
    xor ecx, ecx
    API GetModuleHandleW
    mov rbx, rax
    mov dword ptr [rip + win_class], 80
    mov dword ptr [rip + win_class + 4], 3
    lea rax, [rip + win_wndproc]
    mov [rip + win_class + 8], rax
    mov [rip + win_class + 24], rbx
    mov rcx, rbx
    mov edx, 1
    API LoadIconW
    mov [rip + win_class + 32], rax
    mov [rip + win_class + 72], rax
    lea rax, [rip + .Lclass]
    mov [rip + win_class + 64], rax
    xor ecx, ecx
    mov edx, 32512
    API LoadCursorW
    mov [rip + win_cursor], rax
    mov [rip + win_class + 40], rax
    lea rcx, [rip + win_class]
    API RegisterClassExW
    test ax, ax
    jz 8f
    lea rsi, [rip + win_platform]
    lea rdi, [rip + g_plat]
    mov ecx, PLAT_SIZE / 8
    rep movsq
    mov dword ptr [rip + g_csd], 0
    mov dword ptr [rip + win_bmi], 40
    mov word ptr [rip + win_bmi + 12], 1
    mov word ptr [rip + win_bmi + 14], 32
    xor ecx, ecx
    lea rdx, [rip + .Lclass]
    lea r8, [rip + .Ltitle]
    mov r9d, 0x00cf0000
    mov dword ptr [rsp + 32], 0x80000000
    mov dword ptr [rsp + 40], 0x80000000
    mov qword ptr [rsp + 48], 1280
    mov qword ptr [rsp + 56], 800
    mov qword ptr [rsp + 64], 0
    mov qword ptr [rsp + 72], 0
    mov [rsp + 80], rbx
    mov qword ptr [rsp + 88], 0
    API CreateWindowExW
    test rax, rax
    jz 8f
    mov [rip + win_hwnd], rax
    # a mode change since win_appearance_init reached no window of rhun's: read the mode again
    call win_setting_changed
    mov rdi, [rip + win_hwnd]
    xor esi, esi
    call win_title_theme
    mov rcx, [rip + win_hwnd]
    API GetDpiForWindow
    call win_dpi
    mov rcx, [rip + win_hwnd]
    mov edx, 5
    API ShowWindow
    mov rcx, [rip + win_hwnd]
    API UpdateWindow
    EPILOGUE
8:  lea rdi, [rip + .Lwindow_error]
    call die

# An explicit file launch brings its window forward, including a minimized startup state.
FN win_activate
    PROLOGUE 96
    mov rcx, [rip + win_hwnd]
    test rcx, rcx
    jz 9f
    API IsIconic
    mov edx, 5                 # SW_SHOW, retaining maximized windows
    test eax, eax
    jz 1f
    mov edx, 9                 # SW_RESTORE
1:  mov rcx, [rip + win_hwnd]
    API ShowWindow
    mov rcx, [rip + win_hwnd]
    API SetForegroundWindow
9:  EPILOGUE

win_dpi:
    test eax, eax
    jz 9f
    cvtsi2ss xmm0, eax
    divss xmm0, [rip + .Ldpi96]
    movss [rip + g_dpi_scale], xmm0
9:  ret

win_timeout:
    mov eax, -1
    ret
win_nop:
    ret

win_draw:
    PROLOGUE 112
    mov eax, [rip + win_width]
    mov edx, [rip + win_height]
    test eax, eax
    jle 9f
    test edx, edx
    jle 9f
    imul rax, rdx
    shl rax, 2
    cmp rax, [rip + win_capacity]
    jbe 1f
    mov r12, rax
    mov rdi, [rip + win_pixels]
    call mem_free
    mov rdi, r12
    call mem_alloc
    mov [rip + win_pixels], rax
    mov [rip + win_capacity], r12
1:  mov rdi, [rip + win_pixels]
    mov esi, [rip + win_width]
    mov edx, [rip + win_height]
    mov ecx, esi
    call gfx_set_target
    mov dword ptr [rip + g_dirty], 0
    call app_render
    mov rdi, [rip + win_hwnd]
    mov esi, 1
    call win_title_theme
    mov rcx, [rip + win_hwnd]
    API GetDC
    test rax, rax
    jz 9f
    mov rbx, rax
    mov eax, [rip + win_width]
    mov [rip + win_bmi + 4], eax
    mov edx, [rip + win_height]
    mov r12d, edx
    neg edx
    mov [rip + win_bmi + 8], edx
    mov rcx, rbx
    xor edx, edx
    xor r8d, r8d
    mov r9d, eax
    mov [rsp + 32], r12
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0
    mov [rsp + 56], rax
    mov [rsp + 64], r12
    mov rax, [rip + win_pixels]
    mov [rsp + 72], rax
    lea rax, [rip + win_bmi]
    mov [rsp + 80], rax
    mov qword ptr [rsp + 88], 0
    mov qword ptr [rsp + 96], 0x00cc0020
    API StretchDIBits
    mov rcx, [rip + win_hwnd]
    mov rdx, rbx
    API ReleaseDC
9:  EPILOGUE

win_title:
    PROLOGUE 96
    call win_wide
    mov rbx, rax
    test rax, rax
    jz 9f
    mov rcx, [rip + win_hwnd]
    mov rdx, rax
    API SetWindowTextW
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# Clipboard managers can hold the clipboard briefly after a content change.
win_clip_open:
    PROLOGUE 64
    mov ebx, 20
1:  mov rcx, [rip + win_hwnd]
    API OpenClipboard
    test eax, eax
    jnz 9f
    dec ebx
    jz 9f
    mov ecx, 25
    API Sleep
    jmp 1b
9:  EPILOGUE

win_clip_set:
    PROLOGUE 96
    # Copy a counted UTF-8 string before conversion; embedded editor buffers are not NUL terminated.
    call mem_dup
    mov rbx, rax
    mov rdi, rax
    call win_wide
    mov r12, rax
    mov rdi, rbx
    call mem_free
    test r12, r12
    jz 9f
    xor ebx, ebx
1:  add rbx, 2
    cmp word ptr [r12 + rbx - 2], 0
    jne 1b
    mov ecx, 2
    mov rdx, rbx
    API GlobalAlloc
    mov r13, rax
    test rax, rax
    jz 8f
    mov rcx, rax
    API GlobalLock
    test rax, rax
    jz 7f
    mov rdi, rax
    mov rsi, r12
    mov rdx, rbx
    call memcpy
    mov rcx, r13
    API GlobalUnlock
    call win_clip_open
    test eax, eax
    jz 7f
    API EmptyClipboard
    test eax, eax
    jz 6f
    mov ecx, 13
    mov rdx, r13
    API SetClipboardData
    test rax, rax
    jz 6f
    xor r13d, r13d
6:  API CloseClipboard
7:  test r13, r13
    jz 8f
    mov rcx, r13
    API GlobalFree
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

win_clip_get:
    PROLOGUE 96
    call win_clip_open
    test eax, eax
    jz 9f
    mov ecx, 13
    API GetClipboardData
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rcx, rax
    API GlobalLock
    test rax, rax
    jz 8f
    mov rdi, rax
    call win_utf8
    mov r12, rax
    mov rcx, rbx
    API GlobalUnlock
    API CloseClipboard
    test r12, r12
    jz 9f
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call app_on_paste
    mov rdi, r12
    call mem_free
    EPILOGUE
8:  API CloseClipboard
9:  EPILOGUE

win_set_cursor:
    PROLOGUE 96
    cmp edi, 6
    jbe 1f
    xor edi, edi
1:  lea rax, [rip + .Lcursors]
    mov edx, [rax + rdi*4]
    xor ecx, ecx
    API LoadCursorW
    mov [rip + win_cursor], rax
    mov rcx, rax
    API SetCursor
    EPILOGUE
win_minimize:
    PROLOGUE 96
    mov rcx, [rip + win_hwnd]
    mov edx, 6
    API ShowWindow
    EPILOGUE
win_maximize:
    PROLOGUE 96
    mov rcx, [rip + win_hwnd]
    API IsZoomed
    mov edx, 3
    test eax, eax
    jz 1f
    mov edx, 9
1:  mov rcx, [rip + win_hwnd]
    API ShowWindow
    EPILOGUE

# modifier bits in eax. AltGr must not become a Ctrl+Alt editor shortcut.
FN win_mods
    PROLOGUE 96
    xor ebx, ebx
    mov ecx, 16
    API GetKeyState
    test ax, 0x8000
    jz 1f
    or ebx, MOD_SHIFT
1:  mov ecx, 17
    API GetKeyState
    test ax, 0x8000
    jz 2f
    or ebx, MOD_CTRL
2:  mov ecx, 18
    API GetKeyState
    test ax, 0x8000
    jz 3f
    or ebx, MOD_ALT
3:  mov ecx, 0xa5
    API GetKeyState
    test ax, 0x8000
    jz 4f
    test ebx, MOD_CTRL         # plain Right Alt remains an Alt shortcut
    jz 4f
    and ebx, ~(MOD_ALT | MOD_CTRL)
4:  mov eax, ebx
    EPILOGUE

# the window procedure (tests/windows/wheel_test.s sends it messages)
.globl win_wndproc
win_wndproc:
    CALLBACK 96
    mov rbx, rcx
    mov r12d, edx
    mov r13, r8
    mov r14, r9
    cmp edx, 0x10
    je .Lwm_close
    cmp edx, 5
    je .Lwm_size
    cmp edx, 0x0f
    je .Lwm_paint
    cmp edx, 0x14
    je .Lwm_erased
    cmp edx, 6
    je .Lwm_focus
    cmp edx, 0x20
    je .Lwm_cursor
    cmp edx, 0x2e0
    je .Lwm_dpi
    cmp edx, 0x1a
    je .Lwm_setting
    cmp edx, 0x200
    je .Lwm_motion
    cmp edx, 0x201
    jb .Lwm_key
    cmp edx, 0x209
    jbe .Lwm_button
    cmp edx, 0x20a
    je .Lwm_scroll
    cmp edx, 0x20e
    je .Lwm_scroll
.Lwm_key:
    cmp r12d, 0x102
    je .Lwm_char
    cmp r12d, 0x106
    je .Lwm_char
    cmp r12d, 0x100
    je .Lwm_keydown
    cmp r12d, 0x104
    je .Lwm_keydown
.Lwm_default:
    mov rcx, rbx
    mov edx, r12d
    mov r8, r13
    mov r9, r14
    API DefWindowProcW
    jmp .Lwm_ret
.Lwm_close:
    call app_on_close
    jmp .Lwm_zero
.Lwm_setting:
    # WM_SETTINGCHANGE: the system's dark mode among others
    call win_setting_changed
    jmp .Lwm_default
.Lwm_size:
    cmp r13d, 1
    je .Lwm_zero
    movzx edi, r14w
    shr r14, 16
    movzx esi, r14w
    mov [rip + win_width], edi
    mov [rip + win_height], esi
    call app_on_resize
    jmp .Lwm_zero
.Lwm_paint:
    mov rcx, rbx
    lea rdx, [rsp + 96]
    API BeginPaint
    mov dword ptr [rip + g_dirty], 1
    mov rcx, rbx
    lea rdx, [rsp + 96]
    API EndPaint
    jmp .Lwm_zero
.Lwm_erased:
    mov eax, 1
    jmp .Lwm_ret
.Lwm_focus:
    xor edi, edi
    test r13w, r13w
    setne dil
    call app_on_focus
    jmp .Lwm_zero
.Lwm_cursor:
    cmp r14w, 1
    jne .Lwm_default
    mov rcx, [rip + win_cursor]
    API SetCursor
    mov eax, 1
    jmp .Lwm_ret
.Lwm_dpi:
    movzx eax, r13w
    call win_dpi
    call app_apply_settings
    mov rcx, rbx
    xor edx, edx
    mov r8d, [r14]
    mov r9d, [r14 + 4]
    mov eax, [r14 + 8]
    sub eax, r8d
    mov [rsp + 32], rax
    mov eax, [r14 + 12]
    sub eax, r9d
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0x14
    API SetWindowPos
    jmp .Lwm_zero
.Lwm_motion:
    movsx edi, r14w
    mov rax, r14
    shr rax, 16
    movsx esi, ax
    call app_on_motion
    jmp .Lwm_zero
.Lwm_button:
    # Mouse coordinates also arrive with button events, even without a preceding move.
    movsx edi, r14w
    mov rax, r14
    shr rax, 16
    movsx esi, ax
    call app_on_motion
    call win_mods
    mov r15d, eax
    mov edi, BTN_LEFT
    cmp r12d, 0x204
    jb 1f
    mov edi, BTN_RIGHT
    cmp r12d, 0x207
    jb 1f
    mov edi, BTN_MIDDLE
1:  mov esi, 1
    cmp r12d, 0x202
    je 2f
    cmp r12d, 0x205
    je 2f
    cmp r12d, 0x208
    jne 3f
2:  xor esi, esi
3:  mov [rsp + 96], edi
    mov [rsp + 100], esi
    test esi, esi
    jz 4f
    mov rcx, rbx
    API SetCapture
    jmp 5f
4:  API ReleaseCapture
5:  mov edi, [rsp + 96]
    mov esi, [rsp + 100]
    mov edx, r15d
    call app_on_button
    jmp .Lwm_zero
.Lwm_scroll:
    call win_mods
    mov edx, eax
    # 120 a notch scrolls 60 px. A precision touchpad sends smaller steps: what falls short of a
    # pixel carries to the next message, so they add up and both directions round alike.
    shr r13, 16
    movsx eax, r13w
    xor ecx, ecx
    cmp r12d, 0x20e
    sete cl                       # 0 vertical, 1 horizontal
    lea r8, [rip + wheel_rem]
    add eax, [r8 + rcx*4]
    mov edi, eax
    shr edi, 31
    add edi, eax
    sar edi, 1                    # halved toward zero
    lea r9d, [rdi + rdi]
    sub eax, r9d
    mov [r8 + rcx*4], eax
    xor esi, esi
    test ecx, ecx
    jnz 1f                        # tilted right scrolls right
    mov esi, edi
    neg esi                       # turned away scrolls up
    xor edi, edi
1:  call app_on_scroll
    jmp .Lwm_zero
.Lwm_char:
    # WM_CHAR handles keyboard layouts and committed IME text as UTF-16.
    cmp r13d, 32
    jb .Lwm_zero
    cmp r13d, 0xd800
    jb 3f
    cmp r13d, 0xdbff
    ja 1f
    mov [rip + win_surrogate], r13d
    jmp .Lwm_zero
1:  cmp r13d, 0xdfff
    ja 3f
    mov eax, [rip + win_surrogate]
    test eax, eax
    jz .Lwm_zero
    sub eax, 0xd800
    shl eax, 10
    lea r13d, [rax + r13 - 0xdc00 + 0x10000]
3:  mov dword ptr [rip + win_surrogate], 0
    call win_mods
    test eax, MOD_CTRL | MOD_ALT
    jnz .Lwm_zero
    mov edx, eax
    mov edi, r13d
    mov esi, r13d
    call app_on_key
    jmp .Lwm_zero
.Lwm_keydown:
    call win_mods
    mov r15d, eax
    test eax, MOD_ALT
    jz 9f
    cmp r13d, 115              # Alt+F4 belongs to Windows
    je .Lwm_default
    cmp r13d, 32               # Alt+Space opens the system menu
    je .Lwm_default
9:  lea rdx, [rip + .Lkeys]
    xor ecx, ecx
1:  mov eax, [rdx + rcx*8]
    test eax, eax
    jz 2f
    cmp eax, r13d
    je 4f
    inc ecx
    jmp 1b
2:  test r15d, MOD_CTRL | MOD_ALT
    jz .Lwm_default
    mov ecx, r13d
    mov edx, 2
    API MapVirtualKeyW
    and eax, 0x7fffffff
    test eax, eax
    jz .Lwm_default
    mov edi, eax
    cmp edi, 'A'
    jb 3f
    cmp edi, 'Z'
    ja 3f
    add edi, 32
3:  mov esi, edi                # the terminal derives Ctrl+C and other control bytes from cp
    mov edx, r15d
    call app_on_key
    jmp .Lwm_zero
4:  mov edi, [rdx + rcx*8 + 4]
    xor esi, esi
    mov edx, r15d
    call app_on_key
.Lwm_zero:
    xor eax, eax
.Lwm_ret:
    CALLBACK_END 96

# Process the queue from the GUI thread, including input already queued before waiting.
FN win_messages
    PROLOGUE 96
1:  lea rcx, [rip + win_message]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 1
    API PeekMessageW
    test eax, eax
    jz 9f
    cmp dword ptr [rip + win_message + 8], 0x12
    jne 2f
    mov dword ptr [rip + g_quit], 1
    jmp 9f
2:  lea rcx, [rip + win_message]
    API TranslateMessage
    lea rcx, [rip + win_message]
    API DispatchMessageW
    jmp 1b
9:  EPILOGUE

# Poll never hands the descriptor set to a 64-handle Windows wait. Pipe/PTY readiness is
# sampled at 10 ms, directory notifications at 100 ms; messages wake either wait immediately.
FN ws_poll
    PROLOGUE 112
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    API GetTickCount64
    mov r15, rax
.Lpoll_again:
    call win_messages
    xor ebx, ebx
    mov qword ptr [rsp + 96], 100
    mov qword ptr [rsp + 104], 0
.Lpoll_fd:
    cmp rbx, r13
    jae .Lpoll_wait
    mov word ptr [r12 + rbx*8 + 6], 0
    mov edi, [r12 + rbx*8]
    call win_fd
    test rax, rax
    jz .Lpoll_next
    cmp dword ptr [rax + FD_kind], FD_WATCH
    je .Lpoll_watch
    cmp dword ptr [rax + FD_kind], FD_PIPE
    je .Lpoll_pipe_kind
    cmp dword ptr [rax + FD_kind], FD_PTY
    jne .Lpoll_ready
    test word ptr [r12 + rbx*8 + 4], POLLOUT
    jz .Lpoll_pipe
    mov rcx, [rax + FD_aux]
    mov edx, [rcx + 40]
    sub edx, [rcx + 44]
    cmp edx, 65536
    jae .Lpoll_pipe
    or word ptr [r12 + rbx*8 + 6], POLLOUT
.Lpoll_pipe:
    mov qword ptr [rsp + 96], 10
    mov rcx, [rax + FD_handle]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    lea rax, [rsp + 80]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 0
    API PeekNamedPipe
    test eax, eax
    jz .Lpoll_hup
    cmp dword ptr [rsp + 80], 0
    je .Lpoll_next
    test word ptr [r12 + rbx*8 + 4], POLLIN
    jz .Lpoll_next
    or word ptr [r12 + rbx*8 + 6], POLLIN
    jmp .Lpoll_next
.Lpoll_hup:
    or word ptr [r12 + rbx*8 + 6], POLLHUP
    jmp .Lpoll_next
.Lpoll_pipe_kind:
    cmp dword ptr [rax + FD_wend], 0
    je .Lpoll_pipe
    # a write end cannot be peeked: it is writable unless the last write found it full less than
    # 10 ms ago (a broken pipe shows as EPIPE on the next write)
    test word ptr [r12 + rbx*8 + 4], POLLOUT
    jz .Lpoll_next
    cmp qword ptr [rax + FD_full], 0
    je 1f
    mov [rsp + 88], rax
    mov qword ptr [rsp + 96], 10
    API GetTickCount64
    mov rcx, [rsp + 88]
    sub rax, [rcx + FD_full]
    cmp rax, 10
    jb .Lpoll_next
1:  or word ptr [r12 + rbx*8 + 6], POLLOUT
    jmp .Lpoll_next
.Lpoll_watch:
    call win_watch_ready
    test eax, eax
    jz .Lpoll_next
.Lpoll_ready:
    mov ax, [r12 + rbx*8 + 4]
    mov [r12 + rbx*8 + 6], ax
.Lpoll_next:
    cmp word ptr [r12 + rbx*8 + 6], 0
    je 1f
    inc qword ptr [rsp + 104]
1:  inc rbx
    jmp .Lpoll_fd
.Lpoll_wait:
    mov rax, [rsp + 104]
    test rax, rax
    jnz .Lpoll_done
    cmp dword ptr [rip + g_dirty], 0
    jne .Lpoll_done
    cmp dword ptr [rip + g_quit], 0
    jne .Lpoll_done
    test r14, r14
    jz .Lpoll_done
    mov rbx, [rsp + 96]
    test r13, r13
    jnz 2f
    mov rbx, -1
2:  test r14, r14
    js 3f
    API GetTickCount64
    sub rax, r15
    mov rdx, r14
    sub rdx, rax
    jle .Lpoll_zero
    cmp rbx, -1
    je 21f
    cmp rdx, rbx
    jae 3f
21: mov rbx, rdx
3:  xor ecx, ecx
    xor edx, edx
    mov r8d, ebx
    mov r9d, 0x04ff
    mov qword ptr [rsp + 32], 4
    API MsgWaitForMultipleObjectsEx
    jmp .Lpoll_again
.Lpoll_zero:
    xor eax, eax
.Lpoll_done:
    EPILOGUE

# win_open_link(UTF-8 URL): use the registered browser or mail application.
FN win_open_link
    PROLOGUE 96
    call win_wide
    test rax, rax
    jz 8f
    mov rbx, rax
    xor ecx, ecx
    API CoInitialize
    mov r14d, eax
    mov rcx, [rip + win_hwnd]
    lea rdx, [rip + .Lopen]
    mov r8, rbx
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 1
    API ShellExecuteW
    mov r12, rax
    mov rdi, rbx
    call mem_free
    test r14d, r14d
    js 1f
    API CoUninitialize
1:
    cmp r12, 32
    ja 9f
8:  call desktop_failed
9:  EPILOGUE

# Select files and directories in their parent folder, with Unicode paths intact.
FN win_reveal
    PROLOGUE 96
    call win_wide
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rcx, rax
1:  cmp word ptr [rcx], 0
    je 2f
    cmp word ptr [rcx], '/'
    jne 11f
    mov word ptr [rcx], 92
11: add rcx, 2
    jmp 1b
2:  xor ecx, ecx
    API CoInitialize
    mov r14d, eax
    mov rcx, rbx
    API ILCreateFromPathW
    mov r12, rax
    mov rdi, rbx
    call mem_free
    mov ebx, -1
    test r12, r12
    jz 3f
    mov rcx, r12
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    API SHOpenFolderAndSelectItems
    mov ebx, eax
    mov rcx, r12
    API ILFree
3:  test r14d, r14d
    js 4f
    API CoUninitialize
4:  test ebx, ebx
    jns 9f
8:  call desktop_failed
9:  EPILOGUE

.section .rdata,"dr"
.p2align 3
win_platform:
    .quad win_nop,win_timeout,win_nop,win_draw,win_set_cursor,win_clip_set,win_clip_get
    .quad win_nop,win_nop,win_minimize,win_maximize,win_title,win_nop
.Lclass: .short 'r','h','u','n','W','i','n','d','o','w',0
.Ltitle: .short 'r','h','u','n',0
.Lopen: .short 'o','p','e','n',0
.Ldpi96: .float 96.0
.Lcursors: .long 32512,32513,32649,32644,32645,32642,32643
.Lkeys:
    .long 8,KEY_BACKSPACE,9,KEY_TAB,13,KEY_RETURN,27,KEY_ESCAPE
    .long 33,KEY_PAGEUP,34,KEY_PAGEDOWN,35,KEY_END,36,KEY_HOME
    .long 37,KEY_LEFT,38,KEY_UP,39,KEY_RIGHT,40,KEY_DOWN,45,KEY_INSERT,46,KEY_DELETE
    .long 112,KEY_F1,113,KEY_F1+1,114,KEY_F1+2,115,KEY_F1+3,116,KEY_F1+4,117,KEY_F1+5
    .long 118,KEY_F1+6,119,KEY_F1+7,120,KEY_F1+8,121,KEY_F1+9,122,KEY_F1+10,123,KEY_F1+11,0,0
.Lwindow_error: .asciz "rhun: could not create a Windows window"

.data
.globl g_csd,g_dpi_scale,g_win_states
g_csd: .long 1
g_dpi_scale: .float 1.0
g_win_states: .long 0

# X11-specific scripted key injection has no native Windows counterpart.
FN x_key_test
    ret
