# Process entry, Unicode conversion and the Linux-call register boundary.
.include "win.inc"

.bss
.p2align 4
.globl win_fds
win_fds: .zero FD_SIZE * FD_MAX

.text
FN win_start
    and rsp, -16
    sub rsp, 96
    # Keep inherited handles intact, including redirected output. The .com entry supplies
    # a console for CLI use; the .exe entry opens directly from the desktop.
    mov ecx, -10
    API GetStdHandle
    mov [rip + win_fds + FD_handle], rax
    mov [rip + win_fds + FD_write], rax
    mov dword ptr [rip + win_fds + FD_kind], FD_FILE
    mov ecx, -11
    API GetStdHandle
    mov [rip + win_fds + FD_SIZE + FD_handle], rax
    mov [rip + win_fds + FD_SIZE + FD_write], rax
    mov dword ptr [rip + win_fds + FD_SIZE + FD_kind], FD_FILE
    mov ecx, -12
    API GetStdHandle
    mov [rip + win_fds + 2*FD_SIZE + FD_handle], rax
    mov [rip + win_fds + 2*FD_SIZE + FD_write], rax
    mov dword ptr [rip + win_fds + 2*FD_SIZE + FD_kind], FD_FILE
    # Wide command line, including empty quoted arguments and non-ASCII paths.
    API GetCommandLineW
    mov rcx, rax
    lea rdx, [rsp + 80]
    API CommandLineToArgvW
    test rax, rax
    jz .Lstart_fail
    mov r12, rax
    mov r13d, [rsp + 80]
    mov [rip + g_argc], r13
    lea rdi, [r13*8 + 8]
    call mem_alloc
    mov r14, rax
    mov [rip + g_argv], rax
    xor ebx, ebx
1:  cmp rbx, r13
    jae 2f
    mov rdi, [r12 + rbx*8]
    call win_utf8
    test rax, rax
    jz .Lstart_fail
    mov [r14 + rbx*8], rax
    inc rbx
    jmp 1b
2:  mov qword ptr [r14 + r13*8], 0
    mov rcx, r12
    API LocalFree
    # Add conventional editor locations only when the user has not supplied overrides.
    lea rdi, [rip + .Lhome]
    lea rsi, [rip + .Lprofile]
    call win_env_default
    lea rdi, [rip + .Lconfig]
    lea rsi, [rip + .Lappdata]
    call win_env_default
    lea rdi, [rip + .Lstate]
    lea rsi, [rip + .Llocaldata]
    call win_env_default
    API GetEnvironmentStringsW
    test rax, rax
    jz .Lstart_fail
    mov r12, rax
    mov r13, rax
    xor ebx, ebx
3:  cmp word ptr [r13], 0
    je 5f
    inc ebx
4:  add r13, 2
    cmp word ptr [r13 - 2], 0
    jne 4b
    jmp 3b
5:  lea rdi, [rbx*8 + 8]
    call mem_alloc
    mov [rip + g_envp], rax
    mov r14, rax
    mov r13, r12
6:  cmp word ptr [r13], 0
    je 9f
    mov rdi, r13
    call win_utf8
    test rax, rax
    jz .Lstart_fail
    mov [r14], rax
    add r14, 8
    # Windows environment keys are case-insensitive; canonicalize names for the core.
    mov rcx, rax
7:  mov dl, [rcx]
    test dl, dl
    jz 8f
    cmp dl, '='
    je 8f
    cmp dl, 'a'
    jb 71f
    cmp dl, 'z'
    ja 71f
    sub byte ptr [rcx], 32
71: inc rcx
    jmp 7b
8:  add r13, 2
    cmp word ptr [r13 - 2], 0
    jne 8b
    jmp 6b
9:  mov qword ptr [r14], 0
    mov rcx, r12
    API FreeEnvironmentStringsW
    lea rdi, [rip + .Lhome]
    call win_env_slashes
    lea rdi, [rip + .Lconfig]
    call win_env_slashes
    lea rdi, [rip + .Lstate]
    call win_env_slashes
    call main
    mov ecx, eax
    API ExitProcess
.Lstart_fail:
    mov ecx, 1
    API ExitProcess

# win_env_default(name UTF-8, fallback name UTF-8)
win_env_default:
    PROLOGUE 8320
    mov r12, rsi
    call win_wide
    mov rbx, rax
    test rax, rax
    jz 9f
    mov rcx, rax
    lea rdx, [rsp + 96]
    mov r8d, 4096
    API GetEnvironmentVariableW
    test eax, eax
    jnz 8f
    mov rdi, r12
    call win_wide
    mov r12, rax
    mov rcx, rax
    lea rdx, [rsp + 96]
    mov r8d, 4096
    API GetEnvironmentVariableW
    test eax, eax
    jz 7f
    cmp eax, 4096
    jae 7f
    mov rcx, rbx
    lea rdx, [rsp + 96]
    API SetEnvironmentVariableW
7:  mov rdi, r12
    call mem_free
8:  mov rdi, rbx
    call mem_free
9:  EPILOGUE

# win_wide(UTF-8 cstr) -> allocated UTF-16 cstr, or 0. Reject malformed UTF-8.
FN win_wide
    PROLOGUE 96
    mov rbx, rdi
    test rdi, rdi
    jz 8f
    mov ecx, 65001
    mov edx, 8
    mov r8, rbx
    mov r9d, -1
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    API MultiByteToWideChar
    test eax, eax
    jz 8f
    mov r12d, eax
    lea edi, [rax*2]
    call mem_alloc
    mov r13, rax
    mov ecx, 65001
    mov edx, 8
    mov r8, rbx
    mov r9d, -1
    mov [rsp + 32], r13
    mov [rsp + 40], r12
    API MultiByteToWideChar
    test eax, eax
    jz 7f
    mov rax, r13
    EPILOGUE
7:  mov rdi, r13
    call mem_free
8:  xor eax, eax
    EPILOGUE

FN win_utf8
    PROLOGUE 96
    mov rbx, rdi
    mov ecx, 65001
    xor edx, edx
    mov r8, rbx
    mov r9d, -1
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    API WideCharToMultiByte
    test eax, eax
    jz 8f
    mov r12d, eax
    mov edi, eax
    call mem_alloc
    mov r13, rax
    mov ecx, 65001
    xor edx, edx
    mov r8, rbx
    mov r9d, -1
    mov [rsp + 32], r13
    mov [rsp + 40], r12
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    API WideCharToMultiByte
    test eax, eax
    jz 7f
    mov rax, r13
    EPILOGUE
7:  mov rdi, r13
    call mem_free
8:  xor eax, eax
    EPILOGUE

FN win_slashes
    mov rax, rdi
1:  cmp byte ptr [rdi], 0
    je 3f
    cmp byte ptr [rdi], 92
    jne 2f
    mov byte ptr [rdi], '/'
2:  inc rdi
    jmp 1b
3:  ret

# win_error(): Windows last-error value -> negative Linux errno.
FN win_error
    sub rsp, 40
    API GetLastError
    add rsp, 40
    mov ecx, eax
    mov rax, -5
    cmp ecx, 2
    je .Lenoent
    cmp ecx, 3
    je .Lenoent
    cmp ecx, 5
    je .Leacces
    cmp ecx, 32
    je .Leacces
    cmp ecx, 33
    je .Leacces
    cmp ecx, 6
    je .Lebadf
    cmp ecx, 80
    je .Leexist
    cmp ecx, 183
    je .Leexist
    cmp ecx, 112
    je .Lenospc
    cmp ecx, 206
    je .Lenametoolong
    cmp ecx, 145
    je .Lenotempty
    cmp ecx, 267
    je .Lenotdir
    cmp ecx, 995
    je .Leintr
    ret
.Lenoent: mov rax, -2
    ret
.Leacces: mov rax, -13
    ret
.Lebadf: mov rax, -9
    ret
.Leexist: mov rax, -17
    ret
.Lenospc: mov rax, -28
    ret
.Lenametoolong: mov rax, -36
    ret
.Lenotempty: mov rax, -39
    ret
.Lenotdir: mov rax, -20
    ret
.Leintr: mov rax, -4
    ret

# win_fd_alloc(handle, kind, flags) -> fd or -24. Allocation and closing run on the GUI thread.
FN win_fd_alloc
    mov eax, 3
    lea r8, [rip + win_fds + 3*FD_SIZE]
1:  cmp dword ptr [r8 + FD_kind], 0
    je 2f
    add r8, FD_SIZE
    inc eax
    cmp eax, FD_MAX
    jb 1b
    mov rax, -24
    ret
2:  mov [r8 + FD_handle], rdi
    mov [r8 + FD_write], rdi
    mov [r8 + FD_kind], esi
    mov [r8 + FD_flags], edx
    mov qword ptr [r8 + FD_path], 0
    mov qword ptr [r8 + FD_aux], 0
    mov qword ptr [r8 + FD_wend], 0
    mov qword ptr [r8 + FD_full], 0
    ret

# win_fd(fd) -> descriptor pointer or 0; does not change argument registers.
FN win_fd
    xor eax, eax
    cmp edi, FD_MAX
    jae 1f
    mov eax, edi
    shl eax, 6
    lea r11, [rip + win_fds]
    add rax, r11
    cmp dword ptr [rax + FD_kind], 0
    jne 1f
    xor eax, eax
1:  ret

# A Linux syscall preserves all general/SIMD registers except rax, rcx and r11. Windows
# message dispatch may call editor code, so save even the Windows nonvolatile SIMD registers.
FN win_syscall
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 320
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov [rsp + 24], r8
    mov [rsp + 32], r9
    mov [rsp + 40], r10
    movdqu [rsp + 64], xmm0
    movdqu [rsp + 80], xmm1
    movdqu [rsp + 96], xmm2
    movdqu [rsp + 112], xmm3
    movdqu [rsp + 128], xmm4
    movdqu [rsp + 144], xmm5
    movdqu [rsp + 160], xmm6
    movdqu [rsp + 176], xmm7
    movdqu [rsp + 192], xmm8
    movdqu [rsp + 208], xmm9
    movdqu [rsp + 224], xmm10
    movdqu [rsp + 240], xmm11
    movdqu [rsp + 256], xmm12
    movdqu [rsp + 272], xmm13
    movdqu [rsp + 288], xmm14
    movdqu [rsp + 304], xmm15
    mov rcx, r10
    cmp eax, 437
    jae 1f
    lea r11, [rip + win_systable]
    call [r11 + rax*8]
    jmp 2f
1:  mov rax, -38
2:  mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    mov r8, [rsp + 24]
    mov r9, [rsp + 32]
    mov r10, [rsp + 40]
    movdqu xmm0, [rsp + 64]
    movdqu xmm1, [rsp + 80]
    movdqu xmm2, [rsp + 96]
    movdqu xmm3, [rsp + 112]
    movdqu xmm4, [rsp + 128]
    movdqu xmm5, [rsp + 144]
    movdqu xmm6, [rsp + 160]
    movdqu xmm7, [rsp + 176]
    movdqu xmm8, [rsp + 192]
    movdqu xmm9, [rsp + 208]
    movdqu xmm10, [rsp + 224]
    movdqu xmm11, [rsp + 240]
    movdqu xmm12, [rsp + 256]
    movdqu xmm13, [rsp + 272]
    movdqu xmm14, [rsp + 288]
    movdqu xmm15, [rsp + 304]
    mov rsp, rbp
    pop rbp
    ret

CSTR .Lhome, "HOME"
CSTR .Lprofile, "USERPROFILE"
CSTR .Lconfig, "XDG_CONFIG_HOME"
CSTR .Lappdata, "APPDATA"
CSTR .Lstate, "XDG_STATE_HOME"
CSTR .Llocaldata, "LOCALAPPDATA"

win_env_slashes:
    push rbx
    call getenv
    test rax, rax
    jz 1f
    mov rdi, rax
    call win_slashes
1:  pop rbx
    ret
