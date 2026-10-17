# child processes: programs with a pipe for their output (git), shells on a pseudo-terminal
.include "rhun.inc"

.equ TIOCSCTTY, 0x540e
.equ TIOCSWINSZ, 0x5414
.equ TIOCSPTLCK, 0x40045431
.equ TIOCGPTN, 0x80045430
.equ TCGETS, 0x5401
.equ TCSETS, 0x5402
.equ IUTF8, 0x4000

.bss
.p2align 3
tmp_path: .zero 4096

.text

# proc_self_path(buf, capacity) -> length or negative error.
FN proc_self_path
.ifdef MACOS
    jmp mac_exe_path
.else
.ifdef WINDOWS
    mov rdx, rsi
    dec rdx
    mov rsi, rdi
    lea rdi, [rip + .Lproc_self]
    SYS SYS_readlink
    test rax, rax
    jle 1f
    mov byte ptr [rsi + rax], 0
1:  ret
.else
    # Keep launching the running inode even after an atomic application update.
    cmp rsi, 15
    jb 1f
    lea rsi, [rip + .Lproc_self]
    call cstr_copy
    mov eax, 14
    ret
1:  mov eax, -22
    ret
.endif
.endif

.section .rodata
.Lproc_self: .asciz "/proc/self/exe"
.text

# proc_cwd(pid, buf, capacity) -> length of the process's current folder, written to buf with a NUL, or
#   negative (a terminal's shell: relative paths in its output start there)
FN proc_cwd
.ifdef MACOS
    jmp mac_pid_cwd
.else
.ifdef WINDOWS
    mov rax, -1
    ret
.else
    PROLOGUE 48
    mov r12, rsi
    mov r13, rdx
    mov dword ptr [rsp], 0x6f72702f     # "/proc/"
    mov word ptr [rsp + 4], 0x2f63
    mov esi, edi
    lea rdi, [rsp + 6]
    call fmt_u64
    lea rcx, [rsp + rax + 6]
    mov dword ptr [rcx], 0x6477632f     # "/cwd"
    mov byte ptr [rcx + 4], 0
    mov rdi, rsp
    mov rsi, r12
    lea rdx, [r13 - 1]
    SYS SYS_readlink
    test rax, rax
    jle 9f
    mov byte ptr [r12 + rax], 0
9:  EPILOGUE
.endif
.endif

# env_make(extras): the environment with extras ("NAME=value", 0-terminated list) set -> envp
FN env_make
    PROLOGUE 16
    mov r12, rdi
    # count
    xor ebx, ebx
    mov rax, [rip + g_envp]
1:  cmp qword ptr [rax + rbx*8], 0
    je 2f
    inc rbx
    jmp 1b
2:  xor ecx, ecx
3:  cmp qword ptr [r12 + rcx*8], 0
    je 4f
    inc rcx
    jmp 3b
4:  lea rdi, [rbx + rcx + 1]
    shl rdi, 3
    call mem_alloc
    mov r13, rax
    xor r14d, r14d              # out index
    xor r15d, r15d
.Lem_env:
    mov rax, [rip + g_envp]
    mov rdi, [rax + r15*8]
    test rdi, rdi
    jz .Lem_extras
    call env_overridden
    test eax, eax
    jnz 5f
    mov rax, [rip + g_envp]
    mov rax, [rax + r15*8]
    mov [r13 + r14*8], rax
    inc r14
5:  inc r15
    jmp .Lem_env
.Lem_extras:
    xor ecx, ecx
6:  mov rax, [r12 + rcx*8]
    test rax, rax
    jz 7f
    mov [r13 + r14*8], rax
    inc r14
    inc rcx
    jmp 6b
7:  mov qword ptr [r13 + r14*8], 0
    mov rax, r13
    EPILOGUE
# env_overridden(rdi entry) -> 1 if r12's list sets the same name
env_overridden:
    xor ecx, ecx
1:  mov rsi, [r12 + rcx*8]
    test rsi, rsi
    jz 8f
    xor edx, edx
2:  mov al, [rsi + rdx]
    cmp al, [rdi + rdx]
    jne 3f
    cmp al, '='
    je 9f
    test al, al
    jz 3f
    inc rdx
    jmp 2b
3:  inc rcx
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# proc_which(name) -> path to run (mem_free it), or 0; names with a slash are taken as they are
.ifndef WINDOWS
FN proc_which
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
    cmp r12, 4096
    jae 8f
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lslash]
    mov ecx, 1
    call str_find
    test rax, rax
    js 1f
    mov rdi, rbx
    mov rsi, r12
    call mem_dup
    EPILOGUE
1:  lea rdi, [rip + .Lpath]
    call getenv
    mov r13, rax
    test rax, rax
    jnz 2f
    lea r13, [rip + .Ldef_path]
2:  # next directory of PATH
    cmp byte ptr [r13], 0
    je 8f
    xor ecx, ecx
3:  mov al, [r13 + rcx]
    test al, al
    jz 4f
    cmp al, ':'
    je 4f
    inc rcx
    jmp 3b
4:  mov r14, rcx
    lea rax, [rcx + r12 + 1]    # directory, slash, name and its terminating NUL
    cmp rax, 4096
    jae 6f
    lea rdi, [rip + tmp_path]
    mov rsi, r13
    mov rdx, r14
    call memcpy
    lea rdi, [rip + tmp_path]
    mov byte ptr [rdi + r14], '/'
    lea rdi, [rdi + r14 + 1]
    mov rsi, rbx
    call cstr_copy
    lea rdi, [rip + tmp_path]
    mov esi, 1                  # X_OK
    SYS SYS_access
    test rax, rax
    jnz 6f
    lea rdi, [rip + tmp_path]
    call strlen
    lea rdi, [rip + tmp_path]
    mov rsi, rax
    call mem_dup
    EPILOGUE
6:  add r13, r14
    cmp byte ptr [r13], ':'
    jne 2b
    inc r13
    jmp 2b
8:  xor eax, eax
    EPILOGUE

.endif

# proc_spawn(argv, envp, cwd, fd_in, fd_out, fd_err, ctty) -> pid or -errno
#   argv[0] is the path to run; cwd may be 0; ctty 1 makes fd_in the controlling terminal of a new
#   session; ctty 2 makes a new session without one that dies with rhun (extensions)
.ifndef WINDOWS
FN proc_spawn
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov [rsp + 8], r9d
    mov eax, [rbp + 16]
    mov [rsp + 12], eax
    # vfork: the child borrows this stack until exec, so below it only reads memory. An
    # extension (ctty 2) is a real fork: its confinement makes a user namespace, which a process
    # sharing its address space may not, and it may use the stack
    cmp dword ptr [rsp + 12], 2
    je 10f
    SYS SYS_vfork
    jmp 12f
10: SYS SYS_fork
12: test rax, rax
    jnz 9f
    cmp dword ptr [rsp + 12], 0
    je 1f
    SYS SYS_setsid
    cmp dword ptr [rsp + 12], 2
    je 11f
    mov edi, [rsp]
    mov esi, TIOCSCTTY
    xor edx, edx
    SYS SYS_ioctl
    jmp 1f
11:
.ifndef MACOS
    # ctty 2: an extension; it dies with rhun
    mov edi, PR_SET_PDEATHSIG
    mov esi, SIGKILL
    xor edx, edx
    xor r10d, r10d
    xor r8d, r8d
    SYS SYS_prctl
.endif
    call confine_child          # what confine_prepare set up, if anything; exits on failure
1:  mov edi, [rsp]
    xor esi, esi
    SYS SYS_dup2
    mov edi, [rsp + 4]
    mov esi, 1
    SYS SYS_dup2
    mov edi, [rsp + 8]
    mov esi, 2
    SYS SYS_dup2
    mov edi, 3
    mov esi, -1
    xor edx, edx
    SYS SYS_close_range
    test rax, rax
    jz 3f
    mov ebx, 3
2:  mov edi, ebx
    SYS SYS_close
    inc ebx
    cmp ebx, 1024
    jb 2b
3:  # rhun ignores SIGPIPE; the child should not
    mov edi, 13
    lea rsi, [rip + sig_dfl]
    xor edx, edx
    mov r10d, 8
    SYS SYS_rt_sigaction
    test r14, r14
    jz 4f
    mov rdi, r14
    SYS SYS_chdir
4:  mov rdi, [r12]
    mov rsi, r12
    mov rdx, r13
    SYS SYS_execve
    mov edi, 127
    SYS SYS_exit
9:  EPILOGUE

.endif

# proc_wait(pid, nohang) -> exit status (128 + signal when killed), -1 still running, -2 unknown pid
FN proc_wait
    sub rsp, 24
    mov dword ptr [rsp], 0
    xor edx, edx
    test esi, esi
    jz 1f
    mov edx, WNOHANG
1:  mov rsi, rsp
    xor r10d, r10d
    SYS SYS_wait4
    cmp rax, -EINTR
    je 1b
    test rax, rax
    jz 3f
    js 4f
    mov eax, [rsp]
    mov ecx, eax
    and ecx, 0x7f
    jz 2f
    lea eax, [rcx + 128]
    jmp 9f
2:  shr eax, 8
    and eax, 0xff
    jmp 9f
3:  mov eax, -1
    jmp 9f
4:  mov eax, -2
9:  add rsp, 24
    ret

# run_piped(argv, envp, cwd) -> rax pid (or -errno), edx fd to read the program's output from (nonblocking)
FN run_piped
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    jmp run_piped_input

# run_piped_input(argv, envp, cwd, ptr, len, errors): run_piped with ptr/len (at most 60 KiB) on the
#   program's input; errors 1 sends its error output down the same pipe (else it goes to /dev/null) and
#   runs it in a session of its own, without a terminal to ask for passwords on.
#   errors 2 creates that session without merging stderr, for binary-output workers.
FN run_piped_input
    PROLOGUE 48
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov [rsp + 16], rcx
    mov [rsp + 24], r8
    mov [rsp + 32], r9d
    mov dword ptr [rsp + 8], -1         # input pipe
    mov dword ptr [rsp + 12], -1
    lea rdi, [rip + .Ldevnull]
    mov esi, O_RDWR | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 9f
    mov ebx, eax
    mov r15d, eax                       # the program's input
    cmp qword ptr [rsp + 24], 0
    je 1f
    lea rdi, [rsp + 8]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js 8f
    mov r15d, [rsp + 8]
1:  lea rdi, [rsp]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js 6f
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov ecx, r15d
    mov r8d, [rsp + 4]
    mov r9d, ebx
    test dword ptr [rsp + 32], 1
    jz 11f
    mov r9d, r8d
11: mov eax, [rsp + 32]
    push rax
    push rax
    call proc_spawn
    add rsp, 16
    mov r15, rax
    mov edi, [rsp + 4]
    SYS SYS_close
    mov edi, ebx
    SYS SYS_close
    mov edi, [rsp + 8]
    test edi, edi
    js 3f
    SYS SYS_close
    # the input fits the pipe, so this does not wait for the program
    test r15, r15
    js 21f
    mov r12, [rsp + 16]
    mov r13, [rsp + 24]
2:  test r13, r13
    jz 21f
    mov edi, [rsp + 12]
    mov rsi, r12
    mov rdx, r13
    SYS SYS_write
    cmp rax, -EINTR
    je 2b
    test rax, rax
    jle 21f
    add r12, rax
    sub r13, rax
    jmp 2b
21: mov edi, [rsp + 12]
    SYS SYS_close
3:  test r15, r15
    js 7f
    mov edi, [rsp]
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov rax, r15
    mov edx, [rsp]
    EPILOGUE
7:  mov edi, [rsp]
    SYS SYS_close
    mov rax, r15
    EPILOGUE
6:  mov r15, rax
    mov edi, [rsp + 8]
    test edi, edi
    js 61f
    SYS SYS_close
    mov edi, [rsp + 12]
    SYS SYS_close
61: mov edi, ebx
    SYS SYS_close
    mov rax, r15
    EPILOGUE
8:  mov r15, rax
    mov edi, ebx
    SYS SYS_close
    mov rax, r15
9:  EPILOGUE

# pty_open(cols, rows) -> eax master (nonblocking), edx slave; eax < 0 on failure
.ifndef WINDOWS
FN pty_open
    PROLOGUE 64
    mov r12d, edi
    mov r13d, esi
    lea rdi, [rip + .Lptmx]
    mov esi, O_RDWR | O_NOCTTY | O_CLOEXEC | O_NONBLOCK
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 9f
    mov ebx, eax
    mov dword ptr [rsp], 0
    mov edi, ebx
    mov esi, TIOCSPTLCK
    lea rdx, [rsp]
    SYS SYS_ioctl
    mov edi, ebx
    mov esi, TIOCGPTN
    lea rdx, [rsp]
    SYS SYS_ioctl
    test rax, rax
    js 8f
    lea rdi, [rsp + 16]
    lea rsi, [rip + .Lpts]
    call cstr_copy
    mov rdi, rax
    mov esi, [rsp]
    call fmt_u64
    mov byte ptr [rdi], 0      # fmt_u64 leaves rdi after the digits
    lea rdi, [rsp + 16]
    mov esi, O_RDWR | O_NOCTTY | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 8f
    mov r14d, eax
    # line editing that knows about UTF-8
    mov edi, r14d
    mov esi, TCGETS
    lea rdx, [rsp + 16]
    SYS SYS_ioctl
    test rax, rax
    js 1f
    or dword ptr [rsp + 16], IUTF8
    mov edi, r14d
    mov esi, TCSETS
    lea rdx, [rsp + 16]
    SYS SYS_ioctl
1:  mov edi, ebx
    mov esi, r12d
    mov edx, r13d
    xor ecx, ecx
    xor r8d, r8d
    call pty_resize
    mov eax, ebx
    mov edx, r14d
    EPILOGUE
8:  mov edi, ebx
    SYS SYS_close
9:  mov eax, -1
    EPILOGUE

.endif

# pty_resize(master, cols, rows, width px, height px)
.ifndef WINDOWS
FN pty_resize
    sub rsp, 24
    mov [rsp], dx               # rows
    mov [rsp + 2], si           # cols
    mov [rsp + 4], cx
    mov [rsp + 6], r8w
    mov esi, TIOCSWINSZ
    mov rdx, rsp
    SYS SYS_ioctl
    add rsp, 24
    ret

.endif

.section .rodata
.Lslash: .ascii "/"
.Lpath: .asciz "PATH"
.Ldef_path: .asciz "/usr/local/bin:/usr/bin:/bin"
.Ldevnull: .asciz "/dev/null"
.Lptmx: .asciz "/dev/ptmx"
.Lpts: .asciz "/dev/pts/"
.p2align 3
sig_dfl: .zero 32
