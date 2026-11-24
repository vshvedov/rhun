# programs that run as the user: outside every extension's sandbox, with the user's login
# environment, each the leader of a session and process group of its own (a job object on Windows)
# that is signalled and killed as one. Task and extension terminals (termview.s), the debugger's
# adapters and the test runner's processes start here; nothing else in rhun spawns them.
#
#   uproc_env_start()                         resolve the login environment in the background
#   uproc_env_make(sets, sets2, unsets)       -> envp: that environment, then the "NAME=value" lists
#                                             sets and sets2 (each 0 or 0-terminated; sets2 wins), less
#                                             the "NAME" list unsets. mem_free the array only: its
#                                             strings are borrowed (the caller's live until the spawn)
#   uproc_which(name, envp)                   -> path to run (mem_free it), or 0: a name without a slash
#                                             is looked up on that environment's PATH (Windows too)
#   uproc_login_path()                        -> the PATH of uproc_envp(), or 0 (borrowed)
#   uproc_spawn(argv, envp, cwd, in, out, err, pty) -> pid, or -errno (-EAGAIN with 128 running)
#                                             argv[0] is the path; pty 1 makes `in` (a pty_open slave)
#                                             the controlling terminal; else a session without one
#                                             that also dies with rhun on Linux
#   uproc_signal(pid, sig)                    the signal to its whole group while the leader is not
#                                             reaped yet (Windows: any signal but 0 ends the job)
#   uproc_wait(pid, nohang)                   -> exit code (0-255 or 128 + signal; Windows the 32-bit
#                                             code), -1 still running, -2 not one of ours (any more).
#                                             What the leader left is killed: SIGHUP and SIGTERM to
#                                             its group then, SIGKILL 2 s later (see "processes")
#   uproc_end(pid, grace ms)                  the caller is done with it: SIGHUP and SIGTERM to the
#                                             group now, SIGKILL at the deadline, reaped here
#   uproc_env_failed() -> 1 when the login shell could not tell its environment (rhun's own is used)
#   uproc_env_ready() -> 1 once uproc_envp() would not block (asks the login shell when nobody has)
#   uproc_env_known() -> 1 once the environment programs start from is settled (asks nobody)
#   uproc_env_get(name) -> rax a variable's value in it (borrowed) or 0: the login shell's once known,
#                                             rhun's own before (asks nobody, never blocks)
.include "rhun.inc"

.equ UP_MAX, 128
.equ UPF_ORPHAN, 1              # nobody waits for it: reaped by uproc_tick
.equ UPF_NOGROUP, 2             # never signalled (reap_later: an editor window, a closed shell)
.equ UPF_EXITED, 4              # the leader is reaped (UP_code), its group is not empty yet
.equ UPF_KILLED, 8              # the group has had SIGKILL
.equ LINGER_MS, 2000            # what a leader left: SIGHUP and SIGTERM when it goes, SIGKILL 2 s on
.equ GIVEUP_MS, 5000            # a group still there this long after SIGKILL is given up
.equ ENV_MS, 5000               # the login shell's time to tell its environment
.equ ENV_MAX, 1048576
.equ QUIT_MS, 300
.equ ENV_BEGIN_LEN, 15          # .Lbegin's and .Lend's bytes, their NULs included
.equ ENV_END_LEN, 13
.equ SYS_nanosleep, 35

STRUCT
F UP_pid, 4
F UP_flags, 4
F UP_kill_at, 8                 # time_ms of the SIGKILL to the group (after it: giving up), 0 none
F UP_code, 4                    # the leader's exit code, once UPF_EXITED
F UP_pad, 4
ENDSTRUCT UP_SIZE

.bss
.p2align 3
procs: .zero UP_SIZE * UP_MAX
env_state: .long 0              # 0 not asked, 1 the login shell is telling, 2 known
env_fail: .long 0
env_pid: .long 0
env_deadline: .quad 0
env_list: .quad 0               # the login environment (envp into env_block), 0: rhun's own
env_block: .quad 0
env_out: .zero SB_SIZE
quit_t0: .quad 0
exe_var: .zero 4096 + 16        # "RHUN_EXE=/path/to/rhun"

.data
env_fd: .long -1

.text

# ---------------- the login environment ----------------
# An app started from the Dock or a desktop launcher lacks the PATH the user's shell sets up
# (/opt/homebrew/bin, ~/go/bin, ~/.cargo/bin), so `go` or `cargo` would not be found. When rhun's
# own environment has no TERM (it was not started from a terminal), the user's login shell runs
# once, without a terminal and reading /dev/null, and prints its environment through
# `rhun --print-env`; 5 s at most, else rhun's own environment stays.

# uproc_print_env(): --print-env: the environment between markers on standard output, then exit
FN uproc_print_env
    PROLOGUE 32
    lea rdi, [rsp]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    lea rsi, [rip + .Lbegin]
    mov edx, ENV_BEGIN_LEN
    call sb_push
    mov rbx, [rip + g_envp]
1:  mov rsi, [rbx]
    test rsi, rsi
    jz 2f
    mov rdi, rsi
    call strlen
    lea rdx, [rax + 1]          # with its NUL
    lea rdi, [rsp]
    mov rsi, [rbx]
    call sb_push
    add rbx, 8
    jmp 1b
2:  lea rdi, [rsp]
    lea rsi, [rip + .Lend]
    mov edx, ENV_END_LEN
    call sb_push
    mov edi, 1
    mov rsi, [rsp + SB_ptr]
    mov rdx, [rsp + SB_len]
    call write_all
    xor edi, edi
    call sys_exit

# uproc_env_start(): ask the login shell for its environment unless that is known or not needed
FN uproc_env_start
    PROLOGUE 96
    cmp dword ptr [rip + env_state], 0
    jne 9f
    mov dword ptr [rip + env_state], 2
.ifndef WINDOWS
    lea rdi, [rip + .Lterm]
    call getenv
    test rax, rax
    jnz 9f                      # started from a terminal: rhun has the user's environment
    # the shell: $SHELL, else the system's own
    lea rdi, [rip + .Lshell]
    call getenv
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 0
    jne 2f
1:  lea rax, [rip + .Ldef_shell]
2:  mov rdi, rax
    call proc_which
    test rax, rax
    jz .Les_fail
    mov r12, rax                # the shell's path (freed below)
    mov [rsp], rax
    lea rax, [rip + .Ldash_l]
    mov [rsp + 8], rax
    lea rax, [rip + .Ldash_i]
    mov [rsp + 16], rax
    lea rax, [rip + .Ldash_c]
    mov [rsp + 24], rax
    lea rax, [rip + .Lprint_cmd]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 0
    # RHUN_EXE: rhun's own path, which the shell runs
    lea rdi, [rip + exe_var]
    lea rsi, [rip + .Lexe_name]
    call cstr_copy
    mov rbx, rax
.ifdef MACOS
    mov rdi, rax
    mov esi, 4096
    call mac_exe_path
    test rax, rax
    jle .Les_free
.else
    lea rdi, [rip + .Lself_exe]
    mov rsi, rbx
    mov edx, 4095
    SYS SYS_readlink
    test rax, rax
    jle .Les_free
    mov byte ptr [rbx + rax], 0
.endif
    lea rax, [rip + exe_var]
    mov [rsp + 48], rax
    mov qword ptr [rsp + 56], 0
    lea rdi, [rsp + 48]
    call env_make
    mov r13, rax                # rhun's environment and RHUN_EXE
    lea rdi, [rip + .Ldevnull]
    mov esi, O_RDWR | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js .Les_env
    mov r14d, eax
    lea rdi, [rsp + 64]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Les_null
    lea rdi, [rip + .Lhome]
    call getenv
    lea rdi, [rsp]
    mov rsi, r13
    mov rdx, rax
    mov ecx, r14d
    mov r8d, [rsp + 68]
    mov r9d, r14d
    push 3                      # a session without a terminal: an interactive shell cannot take rhun's
    push 3
    call proc_spawn
    add rsp, 16
    mov r15, rax
    mov edi, [rsp + 68]
    SYS SYS_close
    test r15, r15
    jg 3f
    mov edi, [rsp + 64]
    SYS SYS_close
    jmp .Les_null
3:  mov [rip + env_pid], r15d
    mov edi, [rsp + 64]
    mov [rip + env_fd], edi
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov edi, [rip + env_fd]
    mov esi, POLLIN
    lea rdx, [rip + on_env]
    xor ecx, ecx
    call watch_add
    call time_ms
    add rax, ENV_MS
    mov [rip + env_deadline], rax
    mov dword ptr [rip + env_state], 1
    mov edi, r14d
    SYS SYS_close
    mov rdi, r13
    call mem_free
    mov rdi, r12
    call mem_free
    jmp 9f
.Les_null:
    mov edi, r14d
    SYS SYS_close
.Les_env:
    mov rdi, r13
    call mem_free
.Les_free:
    mov rdi, r12
    call mem_free
.Les_fail:
    mov dword ptr [rip + env_fail], 1
.endif
9:  EPILOGUE

.ifndef WINDOWS
# on_env(fd, revents, ctx): the login shell's output; its end is the environment
on_env:
    PROLOGUE
1:  lea rdi, [rip + env_out]
    mov esi, 65536
    call sb_reserve
    mov rsi, rax
    mov edi, [rip + env_fd]
    mov edx, 65536
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 2f
    add [rip + env_out + SB_len], rax
    cmp qword ptr [rip + env_out + SB_len], ENV_MAX
    jb 1b
2:  call env_done
9:  EPILOGUE

# env_done(): the shell has said all it will (or ran out of time): keep what lies between the markers
env_done:
    PROLOGUE
    cmp dword ptr [rip + env_state], 1
    jne 9f
    mov dword ptr [rip + env_state], 2
    mov edi, [rip + env_fd]
    call watch_remove
    mov edi, [rip + env_fd]
    SYS SYS_close
    mov dword ptr [rip + env_fd], -1
    # whatever the shell started in its session goes with it (it is not reaped yet: the group is its)
    mov edi, [rip + env_pid]
    neg edi
    mov esi, SIGKILL
    call proc_kill
    mov edi, [rip + env_pid]
    call reap_later
    # RHUN-ENV-BEGIN\0 NAME=value\0 ... RHUN-ENV-END\0
    mov rdi, [rip + env_out + SB_ptr]
    mov rsi, [rip + env_out + SB_len]
    lea rdx, [rip + .Lbegin]
    mov ecx, ENV_BEGIN_LEN
    call str_find
    test rax, rax
    js .Led_fail
    lea r12, [rax + ENV_BEGIN_LEN]       # first entry, offset
    mov rdi, [rip + env_out + SB_ptr]
    add rdi, r12
    mov rsi, [rip + env_out + SB_len]
    sub rsi, r12
    lea rdx, [rip + .Lend]
    mov ecx, ENV_END_LEN
    call str_find
    test rax, rax
    js .Led_fail
    mov r13, rax                # bytes of the entries
    mov rdi, [rip + env_out + SB_ptr]
    add rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rip + env_block], rax
    mov r14, rax
    # one pointer per NUL at most, and the list's end
    lea rdi, [r13 + 1]
    shl rdi, 3
    call mem_alloc
    mov [rip + env_list], rax
    mov r15, rax
    xor ebx, ebx                # offset
1:  cmp rbx, r13
    jae 4f
    lea rdi, [r14 + rbx]
    push rdi
    push rdi
    call strlen
    pop rdi
    pop rdi
    lea rbx, [rbx + rax + 1]
    test rax, rax
    jz 1b
    # NAME=value, not one of the shell's own
    mov rsi, rax
    lea rdx, [rip + .Lskip_names]
    push rdi
    push rdi
    call env_skipped
    pop rdi
    pop rdi
    test eax, eax
    jnz 1b
    mov [r15], rdi
    add r15, 8
    jmp 1b
4:  mov qword ptr [r15], 0
    jmp 9f
.Led_fail:
    mov dword ptr [rip + env_fail], 1
9:  lea rdi, [rip + env_out]
    call sb_free
    EPILOGUE

# env_skipped(entry, len, names) -> 1 when the entry has no '=' or its name is one of the list's
#   (cstrs, an empty one ends it): what describes the shell, not the user
env_skipped:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor ecx, ecx
1:  cmp rcx, r12
    jae 8f
    cmp byte ptr [rbx + rcx], '='
    je 2f
    inc rcx
    jmp 1b
2:  test rcx, rcx
    jz 8f
    mov r14, rcx                # name length
3:  cmp byte ptr [r13], 0
    je 7f
    mov rdi, r13
    call strlen
    mov r15, rax
    cmp rax, r14
    jne 4f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jnz 8f
4:  lea r13, [r13 + r15 + 1]
    jmp 3b
7:  xor eax, eax
    EPILOGUE
8:  mov eax, 1
    EPILOGUE
.endif

# uproc_env_failed() -> 1 when the login shell could not tell its environment
FN uproc_env_failed
    mov eax, [rip + env_fail]
    ret

# uproc_env_ready() -> eax 1 once uproc_envp() would not block: the login environment is known, or
#   was given up on. It asks the login shell itself when nobody has yet (as uproc_envp does) and is 0
#   while the shell answers; past the shell's time it gives up on it, as uproc_envp would. Callers
#   that must not block the loop (the chat's start) wait for it in their tick
FN uproc_env_ready
    PROLOGUE
    cmp dword ptr [rip + env_state], 0
    jne 1f
    call uproc_env_start
1:
.ifndef WINDOWS
    cmp dword ptr [rip + env_state], 1
    jne 8f
    call time_ms
    cmp rax, [rip + env_deadline]
    jb 7f
    mov dword ptr [rip + env_fail], 1
    call env_done
    jmp 8f
7:  xor eax, eax
    EPILOGUE
.endif
8:  mov eax, 1
    EPILOGUE

# FN uproc_env_known() -> eax 1 once the environment programs start from is settled: the login shell's
#   known, given up on, or not needed (started from a terminal)
FN uproc_env_known
    xor eax, eax
    cmp dword ptr [rip + env_state], 2
    sete al
    ret

# FN uproc_env_get(name cstr) -> rax the variable's value (borrowed) or 0: in the login environment once
#   it is known, else in rhun's own (what a program started now would get once the shell answers may
#   differ: uproc_env_known says when it cannot any more)
FN uproc_env_get
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + env_state], 2
    jne 8f
    mov r12, [rip + env_list]
    test r12, r12
    jz 8f
    mov rdi, rbx
    call strlen
    mov r13, rax
1:  mov r14, [r12]
    test r14, r14
    jz 7f
    add r12, 8
    mov rdi, r14
    mov rsi, rbx
    mov rdx, r13
    call memeq
    test eax, eax
    jz 1b
    cmp byte ptr [r14 + r13], '='
    jne 1b
    lea rax, [r14 + r13 + 1]
    EPILOGUE
7:  xor eax, eax
    EPILOGUE
8:  mov rdi, rbx
    call getenv
    EPILOGUE

# uproc_envp() -> the environment programs start from: the login shell's once known (waiting for the
#   rest of its 5 s when it is still telling), else rhun's own
FN uproc_envp
    PROLOGUE 16
    cmp dword ptr [rip + env_state], 0
    jne 1f
    call uproc_env_start
.ifndef WINDOWS
1:  cmp dword ptr [rip + env_state], 1
    jne 3f
    call time_ms
    cmp rax, [rip + env_deadline]
    jae 2f
    # read what has come, then a short sleep (not the event loop's poll: nothing else runs here)
    xor edi, edi
    xor esi, esi
    xor edx, edx
    call on_env
    cmp dword ptr [rip + env_state], 1
    jne 3f
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 10000000
    mov rdi, rsp
    xor esi, esi
    SYS SYS_nanosleep
    jmp 1b
2:  mov dword ptr [rip + env_fail], 1
    call env_done
3:
.else
1:
.endif
    mov rax, [rip + env_list]
    test rax, rax
    jnz 9f
    mov rax, [rip + g_envp]
9:  EPILOGUE

# uproc_env_make(sets, sets2, unsets) -> envp (see the top of the file)
FN uproc_env_make
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    call uproc_envp
    mov rbx, rax
    jmp env_merge

# uproc_env_sets(sets, sets2, unsets) -> envp: as uproc_env_make without the login environment under the
#   lists (nothing waits for the login shell): a program on a remote window's host, which has that host's
#   login environment, gets only what the lists set (remote_spawn sends no more anyway)
FN uproc_env_sets
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    lea rbx, [rip + .Lno_env]
env_merge:
    # room for all of them
    mov rdi, rbx
    call list_len
    mov r15, rax
    mov rdi, r12
    call list_len
    add r15, rax
    mov rdi, r13
    call list_len
    add r15, rax
    lea rdi, [r15 + 1]
    shl rdi, 3
    call mem_alloc
    mov [rsp], rax
    mov r15, rax                # out
    # the environment, less what the lists set or remove
1:  mov rdi, [rbx]
    test rdi, rdi
    jz 2f
    add rbx, 8
    mov rsi, r12
    call name_in
    test eax, eax
    jnz 1b
    mov rsi, r13
    call name_in
    test eax, eax
    jnz 1b
    mov rsi, r14
    call name_in
    test eax, eax
    jnz 1b
    mov [r15], rdi
    add r15, 8
    jmp 1b
2:  # sets, less what sets2 sets or unsets removes
    test r12, r12
    jz 4f
3:  mov rdi, [r12]
    test rdi, rdi
    jz 4f
    add r12, 8
    mov rsi, r13
    call name_in
    test eax, eax
    jnz 3b
    mov rsi, r14
    call name_in
    test eax, eax
    jnz 3b
    mov [r15], rdi
    add r15, 8
    jmp 3b
4:  test r13, r13
    jz 6f
5:  mov rdi, [r13]
    test rdi, rdi
    jz 6f
    add r13, 8
    mov rsi, r14
    call name_in
    test eax, eax
    jnz 5b
    mov [r15], rdi
    add r15, 8
    jmp 5b
6:  mov qword ptr [r15], 0
    mov rax, [rsp]
    EPILOGUE

# list_len(list or 0) -> entries
list_len:
    xor eax, eax
    test rdi, rdi
    jz 2f
1:  cmp qword ptr [rdi + rax*8], 0
    je 2f
    inc rax
    jmp 1b
2:  ret

# name_in(entry, list or 0) -> 1 when an item of the list ("NAME=value" or "NAME") names the entry's
#   variable; keeps rdi
name_in:
    test rsi, rsi
    jz 8f
1:  mov r8, [rsi]
    test r8, r8
    jz 8f
    xor ecx, ecx
2:  movzx eax, byte ptr [rdi + rcx]
    movzx edx, byte ptr [r8 + rcx]
.ifdef WINDOWS
    # names in any case: "Path" is PATH
    lea r9d, [rax - 65]
    cmp r9d, 25
    ja 21f
    or eax, 0x20
21: lea r9d, [rdx - 65]
    cmp r9d, 25
    ja 22f
    or edx, 0x20
22:
.endif
    cmp al, '='
    jne 3f
    xor eax, eax                # the entry's name ends
3:  cmp dl, '='
    jne 4f
    xor edx, edx
4:  cmp eax, edx
    jne 5f
    test eax, eax
    jz 9f                       # both names end here
    inc rcx
    jmp 2b
5:  add rsi, 8
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# uproc_which(name, envp) -> path to run (mem_free it) or 0
FN uproc_which
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    call env_path
    mov rdi, rbx
    mov rsi, rax
    call proc_which_in
    EPILOGUE

# uproc_login_path() -> the PATH value of uproc_envp() (the login shell's once known), or 0 when it
#   has none (proc_which_in then searches rhun's own). Extensions get it, and their sandbox allows
#   the run list's programs as found on it (ext.s, confine.s)
FN uproc_login_path
    PROLOGUE
    call uproc_envp
    mov rdi, rax
    call env_path
    EPILOGUE

# env_path(envp) -> the value of its PATH (any case of it on Windows), or 0
env_path:
1:  mov rsi, [rdi]
    test rsi, rsi
    jz 2f
    add rdi, 8
    mov eax, [rsi]
.ifdef WINDOWS
    and eax, 0xdfdfdfdf         # "Path" as "PATH" (only letters fold to these four)
.endif
    cmp eax, 0x48544150         # "PATH"
    jne 1b
    cmp byte ptr [rsi + 4], '='
    jne 1b
    lea rax, [rsi + 5]
    ret
2:  xor eax, eax
    ret

# ---------------- processes ----------------
# A program's group can outlive its leader: a descendant that ignores SIGHUP and SIGTERM, or one
# that let go of the terminal. So the leader's exit is not the end of an entry: the group has SIGHUP
# and SIGTERM then, SIGKILL 2 s later, and the entry (UPF_EXITED, the leader's code kept) stays until
# kill(-pgid, 0) finds the group empty, whether or not the PTY reached its end and whoever reaped
# the leader. The group's id is not reused while any process is in it. Windows: reaping the leader
# closes its job object, which kills the rest of it (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE).

# slot(pid) -> rax its entry, or 0 (pid 0: a free entry)
slot:
    lea rax, [rip + procs]
    mov ecx, UP_MAX
1:  cmp [rax + UP_pid], edi
    je 2f
    add rax, UP_SIZE
    dec ecx
    jnz 1b
    xor eax, eax
2:  ret

# uproc_spawn(argv, envp, cwd, in, out, err, pty) -> pid or -errno
FN uproc_spawn
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov [rsp + 8], r9d
    xor edi, edi
    call slot
    test rax, rax
    jz .Lsp_full
    mov rbx, rax
    mov eax, 3                  # a session of its own, no terminal, dies with rhun (Linux)
    cmp dword ptr [rbp + 16], 0
    je 1f
    mov eax, 1                  # the session of the terminal `in`
1:  push rax
    push rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov ecx, [rsp + 16]
    mov r8d, [rsp + 20]
    mov r9d, [rsp + 24]
    call proc_spawn
    add rsp, 16
    test rax, rax
    jle 9f
    # an entry still holding this pid lets go: the pid is free again, so that group is gone
    lea rcx, [rip + procs]
    mov edx, UP_MAX
2:  cmp [rcx + UP_pid], eax
    jne 3f
    mov dword ptr [rcx + UP_pid], 0
3:  add rcx, UP_SIZE
    dec edx
    jnz 2b
    mov [rbx + UP_pid], eax
    mov dword ptr [rbx + UP_flags], 0
    mov qword ptr [rbx + UP_kill_at], 0
    mov dword ptr [rbx + UP_code], 0
9:  EPILOGUE
.Lsp_full:
    mov rax, -EAGAIN
    EPILOGUE

# uproc_signal(pid, sig) -> 0, or -3 when it is not a program of ours with a group left (no signal)
FN uproc_signal
    push rbx
    mov ebx, esi
    test edi, edi
    jle 8f
    test edi, REMOTE_PID_TAG    # a remote window's program (remote.s): its host knows it
    jnz 1f
    push rdi
    call slot
    pop rdi
    test rax, rax
    jz 8f
    test dword ptr [rax + UP_flags], UPF_NOGROUP
    jnz 8f
1:  neg edi
    mov esi, ebx
    call proc_kill
    xor eax, eax
    pop rbx
    ret
8:  mov rax, -3
    pop rbx
    ret

# wait_code(pid, nohang) -> the platform's exit status (see uproc_wait), not taking it off the list
wait_code:
.ifdef WINDOWS
    test edi, REMOTE_PID_TAG    # a remote window's program: its host reports it (remote.s)
    jnz proc_wait
    jmp win_wait_code
.else
    sub rsp, 8
    call proc_wait
    movsxd rax, eax             # -1 and -2 as such
    add rsp, 8
    ret
.endif

# uproc_wait(pid, nohang) -> exit code, -1 running, -2 unknown. Once known the code stays while what
#   the leader left is still going
FN uproc_wait
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov rax, -2
    test edi, edi
    jle 9f
    call slot
    mov rbx, rax
    test rax, rax
    jz 1f
    test dword ptr [rbx + UP_flags], UPF_EXITED
    jz 1f
    mov eax, [rbx + UP_code]
    jmp 9f
1:  mov edi, r12d
    mov esi, r13d
    call wait_code
    cmp rax, -1
    je 9f
    test rbx, rbx
    jz 9f
    mov r13, rax
    cmp rax, -2
    jne 2f
    mov dword ptr [rbx + UP_pid], 0
    jmp 3f
2:  mov rdi, rbx
    mov esi, eax
    call leader_gone
3:  mov rax, r13
9:  EPILOGUE

# leader_gone(entry, code): its leader is reaped: the entry goes, or stays for the group it left
leader_gone:
    PROLOGUE
    mov rbx, rdi
    mov [rbx + UP_code], esi
.ifndef WINDOWS
    test dword ptr [rbx + UP_flags], UPF_NOGROUP
    jnz 8f
    mov edi, [rbx + UP_pid]
    test edi, REMOTE_PID_TAG    # a remote window's program: its host has the group
    jnz 8f
    or dword ptr [rbx + UP_flags], UPF_EXITED
    neg edi
    xor esi, esi
    call proc_kill
    test rax, rax
    jnz 8f                      # the group went with its leader
    cmp qword ptr [rbx + UP_kill_at], 0
    jne 9f                      # already going (uproc_end, a quit)
    mov rdi, rbx
    mov esi, LINGER_MS
    call group_term
    jmp 9f
.endif
8:  mov dword ptr [rbx + UP_pid], 0
9:  EPILOGUE

# group_term(entry, grace ms): SIGHUP and SIGTERM to its group now, SIGKILL at the deadline
group_term:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov edi, [rbx + UP_pid]
    neg edi
    mov esi, SIGHUP
    call proc_kill
    mov edi, [rbx + UP_pid]
    neg edi
    mov esi, SIGTERM
    call proc_kill
    call time_ms
    add rax, r12
    mov [rbx + UP_kill_at], rax
    EPILOGUE

# group_kill(entry): SIGKILL to its group; 5 s on, an entry whose leader is gone is given up
group_kill:
    PROLOGUE
    mov rbx, rdi
    mov edi, [rbx + UP_pid]
    neg edi
    mov esi, SIGKILL
    call proc_kill
    or dword ptr [rbx + UP_flags], UPF_KILLED
    call time_ms
    add rax, GIVEUP_MS
    mov [rbx + UP_kill_at], rax
    EPILOGUE

# uproc_end(pid, grace ms): see the top of the file
FN uproc_end
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    test edi, edi
    jle 9f
    call slot
    test rax, rax
    jnz 1f
    # a remote window's program is not in the table: it goes in now, to be killed and reaped
    test r12d, REMOTE_PID_TAG
    jz 9f
    xor edi, edi
    call slot
    test rax, rax
    jz 9f
    mov [rax + UP_pid], r12d
    mov dword ptr [rax + UP_flags], 0
    mov qword ptr [rax + UP_kill_at], 0
1:  mov rbx, rax
    test dword ptr [rbx + UP_flags], UPF_NOGROUP
    jnz 9f
    or dword ptr [rbx + UP_flags], UPF_ORPHAN
    test dword ptr [rbx + UP_flags], UPF_KILLED
    jnz 9f                      # past SIGTERM already
    test dword ptr [rbx + UP_flags], UPF_EXITED
    jz 3f
    # the leader is gone and its group had SIGTERM then: only an earlier SIGKILL
    call time_ms
    add rax, r13
    mov rcx, [rbx + UP_kill_at]
    test rcx, rcx
    jz 2f
    cmp rax, rcx
    jae 9f
2:  mov [rbx + UP_kill_at], rax
    jmp 9f
3:  mov rdi, rbx
    mov esi, r13d
    call group_term
9:  EPILOGUE

# uproc_adopt(pid) -> 1 when a program started elsewhere is now one of ours (remote hosts: a program
#   remote_spawn started on the host, signalled, waited for and ended as the others are; vfs.s)
FN uproc_adopt
    push rbx
    mov ebx, edi
    xor edi, edi
    call slot
    test rax, rax
    jz 9f
    mov [rax + UP_pid], ebx
    mov dword ptr [rax + UP_flags], 0
    mov qword ptr [rax + UP_kill_at], 0
    mov dword ptr [rax + UP_code], 0
    mov eax, 1
9:  pop rbx
    ret

# uproc_env_owned(entry) -> 1 when the "NAME=value" string is the login environment's (remote hosts:
#   a program on the host gets the host's login environment, not this one's)
FN uproc_env_owned
    xor eax, eax
    mov rcx, [rip + env_block]
    test rcx, rcx
    jz 9f
    cmp rdi, rcx
    jb 9f
    push rdi
    push rcx
    mov rdi, rcx
    call mem_capacity
    pop rcx
    pop rdi
    add rcx, rax
    xor eax, eax
    cmp rdi, rcx
    jae 9f
    mov eax, 1
9:  ret

# reap_later(pid): another child to reap once it exits, never signalled: an editor window
#   app_new_window started, a shell whose tab closed, the login shell
FN reap_later
    push rbx
    mov ebx, edi
    test edi, edi
    jle 9f
    xor edi, edi
    call slot
    test rax, rax
    jz 9f                       # full: it stays a zombie until rhun exits
    mov [rax + UP_pid], ebx
    mov dword ptr [rax + UP_flags], UPF_ORPHAN | UPF_NOGROUP
    mov qword ptr [rax + UP_kill_at], 0
9:  pop rbx
    ret

# uproc_tick(): the login shell's deadline; programs nobody waits for are killed at their deadline and
#   reaped; groups whose leader has gone are watched until they are empty, killed at their deadline
FN uproc_tick
    PROLOGUE
.ifndef WINDOWS
    cmp dword ptr [rip + env_state], 1
    jne 1f
    call time_ms
    cmp rax, [rip + env_deadline]
    jb 1f
    mov dword ptr [rip + env_fail], 1
    call env_done
1:
.endif
    xor r12d, r12d              # time_ms, once needed
    lea rbx, [rip + procs]
    mov r13d, UP_MAX
.Lut_next:
    mov eax, [rbx + UP_pid]
    test eax, eax
    jz .Lut_skip
    mov ecx, [rbx + UP_flags]
    test ecx, UPF_EXITED
    jnz .Lut_group
    test ecx, UPF_ORPHAN
    jz .Lut_skip
    # nobody waits for its leader: SIGKILL at the deadline, then its exit
    test ecx, UPF_KILLED
    jnz 4f
    cmp qword ptr [rbx + UP_kill_at], 0
    je 4f
    test r12, r12
    jnz 3f
    call time_ms
    mov r12, rax
3:  cmp r12, [rbx + UP_kill_at]
    jb 4f
    mov rdi, rbx
    call group_kill
4:  mov edi, [rbx + UP_pid]
    mov esi, 1
    call wait_code
    cmp rax, -1
    je .Lut_skip
    cmp rax, -2
    je .Lut_free
    mov rdi, rbx
    mov esi, eax
    call leader_gone
    jmp .Lut_skip
.Lut_group:
    # the leader is gone, what it left not yet: the entry goes when the group is empty
    mov edi, eax
    neg edi
    xor esi, esi
    call proc_kill
    test rax, rax
    jnz .Lut_free
    cmp qword ptr [rbx + UP_kill_at], 0
    je .Lut_skip
    test r12, r12
    jnz 5f
    call time_ms
    mov r12, rax
5:  cmp r12, [rbx + UP_kill_at]
    jb .Lut_skip
    test dword ptr [rbx + UP_flags], UPF_KILLED
    jnz .Lut_free               # still there 5 s after SIGKILL (stuck in the kernel): given up
    mov rdi, rbx
    call group_kill
    jmp .Lut_skip
.Lut_free:
    mov dword ptr [rbx + UP_pid], 0
.Lut_skip:
    add rbx, UP_SIZE
    dec r13d
    jnz .Lut_next
    EPILOGUE

# uproc_timeout() -> ms until uproc_tick has work, or -1
FN uproc_timeout
    PROLOGUE
    mov ebx, -1
    cmp dword ptr [rip + env_state], 1
    jne 1f
    call time_ms
    mov rcx, [rip + env_deadline]
    sub rcx, rax
    xor ebx, ebx
    test rcx, rcx
    cmovg ebx, ecx
1:  lea rax, [rip + procs]
    mov ecx, UP_MAX
2:  cmp dword ptr [rax + UP_pid], 0
    je 3f
    test dword ptr [rax + UP_flags], UPF_ORPHAN | UPF_EXITED
    jz 3f
    mov edx, 250
    cmp ebx, -1
    je 21f
    cmp ebx, edx
    jle 4f
21: mov ebx, edx
    jmp 4f
3:  add rax, UP_SIZE
    dec ecx
    jnz 2b
4:  mov eax, ebx
    EPILOGUE

# uproc_quit_begin(): rhun quits: SIGHUP and SIGTERM to every group (uproc_quit_end finishes)
FN uproc_quit_begin
    PROLOGUE
    call time_ms
    mov [rip + quit_t0], rax
.ifndef WINDOWS
    cmp dword ptr [rip + env_state], 1
    jne 1f
    mov edi, [rip + env_pid]
    neg edi
    mov esi, SIGKILL
    call proc_kill
1:
.endif
    lea rbx, [rip + procs]
    mov r12d, UP_MAX
2:  mov edi, [rbx + UP_pid]
    test edi, edi
    jz 3f
    test dword ptr [rbx + UP_flags], UPF_NOGROUP
    jnz 3f
    neg edi
    mov esi, SIGHUP
    call proc_kill
    mov edi, [rbx + UP_pid]
    neg edi
    mov esi, SIGTERM
    call proc_kill
3:  add rbx, UP_SIZE
    dec r12d
    jnz 2b
    EPILOGUE

# uproc_quit_end(): up to 300 ms after uproc_quit_begin for the groups to go, leaders and what they
#   left, then SIGKILL to every group still there
FN uproc_quit_end
    PROLOGUE 16
1:  # reap what has gone; count what has not
    xor r13d, r13d
    lea rbx, [rip + procs]
    mov r12d, UP_MAX
2:  mov edi, [rbx + UP_pid]
    test edi, edi
    jz 3f
    test dword ptr [rbx + UP_flags], UPF_EXITED
    jnz 24f
    mov esi, 1
    call wait_code
    cmp rax, -1
    je 21f
    cmp rax, -2
    je 23f
    mov rdi, rbx
    mov esi, eax
    call leader_gone            # the entry goes unless the group lives on
    cmp dword ptr [rbx + UP_pid], 0
    je 3f
    inc r13d
    jmp 3f
21: test dword ptr [rbx + UP_flags], UPF_NOGROUP
    jnz 3f
    inc r13d
    jmp 3f
24: neg edi
    xor esi, esi
    call proc_kill
    test rax, rax
    jnz 23f
    inc r13d
    jmp 3f
23: mov dword ptr [rbx + UP_pid], 0
3:  add rbx, UP_SIZE
    dec r12d
    jnz 2b
    test r13d, r13d
    jz 9f
    call time_ms
    sub rax, [rip + quit_t0]
    cmp rax, QUIT_MS
    jae 5f
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 10000000
    mov rdi, rsp
    xor esi, esi
    SYS SYS_nanosleep
    jmp 1b
5:  lea rbx, [rip + procs]
    mov r12d, UP_MAX
6:  mov edi, [rbx + UP_pid]
    test edi, edi
    jz 7f
    test dword ptr [rbx + UP_flags], UPF_NOGROUP
    jnz 7f
    neg edi
    mov esi, SIGKILL
    call proc_kill
    test dword ptr [rbx + UP_flags], UPF_EXITED
    jnz 7f
    mov edi, [rbx + UP_pid]
    mov esi, 1
    call wait_code
7:  add rbx, UP_SIZE
    dec r12d
    jnz 6b
9:  EPILOGUE

# uproc_dump(sb): "uproc=N" and the pids of the entries, "*" after one nobody waits for, "+" after
#   one whose leader is gone while its group is not (print-uproc, for tests)
FN uproc_dump
    PROLOGUE
    mov r12, rdi
    lea rsi, [rip + .Ld_procs]
    call sb_push_cstr
    lea rbx, [rip + procs]
    mov r13d, UP_MAX
1:  mov eax, [rbx + UP_pid]
    test eax, eax
    jz 2f
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rdi, r12
    mov esi, [rbx + UP_pid]
    call sb_push_u64
    test dword ptr [rbx + UP_flags], UPF_ORPHAN
    jz 11f
    mov rdi, r12
    mov esi, '*'
    call sb_push_byte
11: test dword ptr [rbx + UP_flags], UPF_EXITED
    jz 2f
    mov rdi, r12
    mov esi, '+'
    call sb_push_byte
2:  add rbx, UP_SIZE
    dec r13d
    jnz 1b
    mov rdi, r12
    lea rsi, [rip + .Ld_env]
    call sb_push_cstr
    mov eax, [rip + env_state]
    lea rcx, [rip + .Ld_states]
    mov rsi, [rcx + rax*8]
    cmp dword ptr [rip + env_fail], 0
    je 3f
    lea rsi, [rip + .Ld_failed]
3:  mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Lbegin: .ascii "RHUN-ENV-BEGIN\0"
.Lend: .ascii "RHUN-ENV-END\0"
.Lterm: .asciz "TERM"
.Lshell: .asciz "SHELL"
.Lhome: .asciz "HOME"
.ifdef MACOS
.Ldef_shell: .asciz "/bin/zsh"
.else
.Ldef_shell: .asciz "/bin/sh"
.endif
.Ldash_l: .asciz "-l"
.Ldash_i: .asciz "-i"
.Ldash_c: .asciz "-c"
.Lprint_cmd: .asciz "\"$RHUN_EXE\" --print-env"
.Lexe_name: .asciz "RHUN_EXE="
.Lself_exe: .asciz "/proc/self/exe"
.Ldevnull: .asciz "/dev/null"
# what describes the shell that printed them, not the user
.Lskip_names: .asciz "PWD", "OLDPWD", "SHLVL", "_", "RHUN_EXE", ""
.Ld_procs: .asciz "uproc="
.Ld_env: .asciz " env="
.Ld_unasked: .asciz "unasked"
.Ld_asking: .asciz "asking"
.Ld_known: .asciz "known"
.Ld_failed: .asciz "failed"
.p2align 3
.Ld_states: .quad .Ld_unasked, .Ld_asking, .Ld_known
.Lno_env: .quad 0
