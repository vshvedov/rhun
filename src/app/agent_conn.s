# agent connections: a child with pipes for its stdin, stdout and stderr; stdout arrives as lines,
# stderr keeps its tail, stdin is a bounded queue flushed on POLLOUT (Task 6)
.include "rhun.inc"

.bss
.p2align 3
conns: .zero 8 * CN_MAX         # open connections, compacted
nconns: .long 0
.p2align 3
zombies: .zero 16 * CN_ZOMBIES  # pid (4), killed (4), kill_at (8): stopped children not yet reaped
nzombies: .long 0
.data
.globl g_conn_stall_ms
g_conn_stall_ms: .long CN_STALL_MS

.text

.ifndef WINDOWS

# nonblock(fd)
nonblock:
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    ret

# conn_open(conn, argv, envp, cwd) -> 1, or 0 with CN_err: CN_E_GUARD, CN_E_SPAWN or CN_E_WATCH.
# argv[0] is a path (proc_which first). It must be executable: proc_spawn cannot see a failed exec (the
# child just exits 127), so conn_open checks it first and reports CN_E_SPAWN rather than a later exit.
# The child gets a session of its own, so a stop signals the group. A broken connection (CN_DEAD) may be
# reopened without conn_close: its buffers are freed first, so a failed reopen leaks nothing.
FN conn_open
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    cmp dword ptr [rbx + CN_state], CN_DEAD
    jne 1f
    lea rdi, [rbx + CN_rbuf]
    call sb_free
    lea rdi, [rbx + CN_ebuf]
    call sb_free
    lea rdi, [rbx + CN_wbuf]
    call sb_free
    mov dword ptr [rbx + CN_state], CN_IDLE
1:  mov dword ptr [rbx + CN_err], CN_E_GUARD
    cmp dword ptr [rip + nconns], CN_MAX
    jae .Lco_fail
    mov dword ptr [rbx + CN_err], CN_E_SPAWN
    # proc_spawn cannot tell a failed exec from a child that exits 127: check the program first
    mov rdi, [r12]
    mov esi, 1                  # X_OK
    SYS SYS_access
    test rax, rax
    jnz .Lco_fail
    lea rdi, [rsp]              # in: [0] child reads, [4] rhun writes
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Lco_fail
    lea rdi, [rsp + 8]          # out: [8] rhun reads, [12] child writes
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Lco_close_in
    lea rdi, [rsp + 16]         # err: [16] rhun reads, [20] child writes
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Lco_close_out
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov ecx, [rsp]
    mov r8d, [rsp + 12]
    mov r9d, [rsp + 20]
    push 1
    push 1
    call proc_spawn
    add rsp, 16
    mov r15, rax
    mov edi, [rsp]
    SYS SYS_close
    mov edi, [rsp + 12]
    SYS SYS_close
    mov edi, [rsp + 20]
    SYS SYS_close
    test r15, r15
    jle .Lco_close_mine
    mov [rbx + CN_pid], r15d
    mov eax, [rsp + 4]
    mov [rbx + CN_fd_in], eax
    mov eax, [rsp + 8]
    mov [rbx + CN_fd_out], eax
    mov eax, [rsp + 16]
    mov [rbx + CN_fd_err], eax
    mov edi, [rbx + CN_fd_in]
    call nonblock
    mov edi, [rbx + CN_fd_out]
    call nonblock
    mov edi, [rbx + CN_fd_err]
    call nonblock
    lea rdi, [rbx + CN_rbuf]
    call sb_clear
    mov qword ptr [rbx + CN_scanned], 0
    lea rdi, [rbx + CN_ebuf]
    call sb_clear
    lea rdi, [rbx + CN_wbuf]
    call sb_clear
    mov qword ptr [rbx + CN_wpos], 0
    mov dword ptr [rbx + CN_exit], -1
    mov dword ptr [rbx + CN_wwatch], 0
    mov dword ptr [rbx + CN_eof_in], 0
    inc dword ptr [rbx + CN_gen]
    mov qword ptr [rbx + CN_kill_at], 0
    call time_ms
    mov [rbx + CN_moved], rax
    mov edi, [rbx + CN_fd_out]
    mov esi, POLLIN
    lea rdx, [rip + on_out]
    mov rcx, rbx
    call watch_add
    test eax, eax
    jz .Lco_nowatch
    mov edi, [rbx + CN_fd_err]
    mov esi, POLLIN
    lea rdx, [rip + on_err]
    mov rcx, rbx
    call watch_add
    test eax, eax
    jz .Lco_nowatch2
    mov dword ptr [rbx + CN_state], CN_UP
    mov dword ptr [rbx + CN_err], CN_E_NONE
    mov eax, [rip + nconns]
    lea rcx, [rip + conns]
    mov [rcx + rax*8], rbx
    inc dword ptr [rip + nconns]
    mov eax, 1
    EPILOGUE
.Lco_nowatch2:
    mov edi, [rbx + CN_fd_out]
    call watch_remove
.Lco_nowatch:
    mov dword ptr [rbx + CN_err], CN_E_WATCH
    mov edi, [rbx + CN_pid]
    neg edi
    mov esi, SIGKILL
    SYS SYS_kill
    mov edi, [rbx + CN_pid]     # the child itself too: on macOS (fork) it may not have called setsid yet
    mov esi, SIGKILL
    SYS SYS_kill
    mov edi, [rbx + CN_pid]
    xor esi, esi
    call proc_wait              # a killed child is gone at once
    mov edi, [rbx + CN_fd_in]
    SYS SYS_close
    mov edi, [rbx + CN_fd_out]
    SYS SYS_close
    mov edi, [rbx + CN_fd_err]
    SYS SYS_close
    mov dword ptr [rbx + CN_state], CN_IDLE
    jmp .Lco_fail
.Lco_close_mine:
    mov edi, [rsp + 4]
    SYS SYS_close
    mov edi, [rsp + 8]
    SYS SYS_close
    mov edi, [rsp + 16]
    SYS SYS_close
    jmp .Lco_fail
.Lco_close_out:
    mov edi, [rsp + 8]
    SYS SYS_close
    mov edi, [rsp + 12]
    SYS SYS_close
.Lco_close_in:
    mov edi, [rsp]
    SYS SYS_close
    mov edi, [rsp + 4]
    SYS SYS_close
.Lco_fail:
    xor eax, eax
    EPILOGUE

# deliver(conn): every complete line of CN_rbuf to CN_on_line; the remainder moves to the front.
# The search starts at CN_scanned, so a long record is scanned once, not once per read.
# Stops if a callback closed the connection (state CN_IDLE: its buffers are gone) or closed and reopened
# it (CN_gen moved: the buffers belong to the new child).
deliver:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d              # consumed bytes
    mov r14, [rbx + CN_scanned] # where the newline search starts
    mov r15d, [rbx + CN_gen]
1:  cmp r15d, [rbx + CN_gen]
    jne 9f
    cmp dword ptr [rbx + CN_state], CN_IDLE
    je 9f
    cmp dword ptr [rbx + CN_state], CN_DEAD
    je 2f
    mov rdi, [rbx + CN_rbuf + SB_ptr]
    add rdi, r14
    mov rsi, [rbx + CN_rbuf + SB_len]
    sub rsi, r14
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    test rax, rax
    js 2f
    lea r13, [r14 + rax]
    sub r13, r12                # the line's length
    mov rdi, rbx
    mov rsi, [rbx + CN_rbuf + SB_ptr]
    add rsi, r12
    mov rdx, r13
    call [rbx + CN_on_line]
    lea r12, [r12 + r13 + 1]
    mov r14, r12
    jmp 1b
2:  test r12, r12
    jz 3f
    mov rdi, [rbx + CN_rbuf + SB_ptr]
    lea rsi, [rdi + r12]
    mov rdx, [rbx + CN_rbuf + SB_len]
    sub rdx, r12
    call memmove
    sub [rbx + CN_rbuf + SB_len], r12
3:  mov rax, [rbx + CN_rbuf + SB_len]   # the remainder holds no newline
    mov [rbx + CN_scanned], rax
9:  EPILOGUE

# drain_out(conn) -> 1 at EOF or error, 0 when more may come: read what stdout has, deliver lines.
# Also 1 when a callback reopened the connection (CN_gen moved): the caller checks CN_gen too.
drain_out:
    PROLOGUE
    mov rbx, rdi
    mov r12d, 64                # at most 256 KiB per call
    mov r13d, [rbx + CN_gen]
1:  cmp dword ptr [rbx + CN_fd_out], 0
    jl 8f
    lea rdi, [rbx + CN_rbuf]
    mov esi, 4096
    call sb_reserve
    mov rsi, rax
    mov edi, [rbx + CN_fd_out]
    mov edx, 4096
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 7f
    test rax, rax
    jle 8f
    add [rbx + CN_rbuf + SB_len], rax
    mov rdi, rbx
    call deliver
    cmp r13d, [rbx + CN_gen]
    jne 8f
    cmp dword ptr [rbx + CN_state], CN_IDLE
    je 8f
    cmp qword ptr [rbx + CN_rbuf + SB_len], CN_LINE_MAX
    ja 6f
    dec r12d
    jnz 1b
7:  xor eax, eax
    EPILOGUE
6:  mov rdi, rbx
    mov esi, CN_E_LINE
    call conn_break
8:  mov eax, 1
    EPILOGUE

# on_out(fd, revents, ctx): stdout is readable or closed
on_out:
    PROLOGUE
    mov rbx, rdx
    mov r12d, [rbx + CN_gen]
    mov rdi, rbx
    call drain_out
    test eax, eax
    jz 9f
    cmp r12d, [rbx + CN_gen]    # a callback reopened it: nothing here is ours any more
    jne 9f
    cmp dword ptr [rbx + CN_state], CN_IDLE
    je 9f
    cmp dword ptr [rbx + CN_state], CN_DEAD
    je 9f
    # EOF: the last partial line is a line too
    mov edi, [rbx + CN_fd_out]
    call watch_remove
    mov edi, [rbx + CN_fd_out]
    SYS SYS_close
    mov dword ptr [rbx + CN_fd_out], -1
    mov rdx, [rbx + CN_rbuf + SB_len]
    test rdx, rdx
    jz 9f
    mov rdi, rbx
    mov rsi, [rbx + CN_rbuf + SB_ptr]
    call [rbx + CN_on_line]
    cmp r12d, [rbx + CN_gen]
    jne 9f
    cmp dword ptr [rbx + CN_state], CN_IDLE
    je 9f
    mov qword ptr [rbx + CN_rbuf + SB_len], 0
    mov qword ptr [rbx + CN_scanned], 0
9:  EPILOGUE

# drain_err(conn): read stderr, keep the last CN_ERR_KEEP bytes
drain_err:
    PROLOGUE
    mov rbx, rdi
    mov r12d, 64
1:  cmp dword ptr [rbx + CN_fd_err], 0
    jl 9f
    lea rdi, [rbx + CN_ebuf]
    mov esi, 4096
    call sb_reserve
    mov rsi, rax
    mov edi, [rbx + CN_fd_err]
    mov edx, 4096
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 8f
    add [rbx + CN_ebuf + SB_len], rax
    mov rax, [rbx + CN_ebuf + SB_len]
    cmp rax, CN_ERR_KEEP
    jbe 2f
    mov rdx, rax
    sub rdx, CN_ERR_KEEP        # bytes to drop
    mov rdi, [rbx + CN_ebuf + SB_ptr]
    lea rsi, [rdi + rdx]
    mov rdx, CN_ERR_KEEP
    call memmove
    mov qword ptr [rbx + CN_ebuf + SB_len], CN_ERR_KEEP
2:  dec r12d
    jnz 1b
    jmp 9f
8:  mov edi, [rbx + CN_fd_err]
    call watch_remove
    mov edi, [rbx + CN_fd_err]
    SYS SYS_close
    mov dword ptr [rbx + CN_fd_err], -1
9:  EPILOGUE

# on_err(fd, revents, ctx)
on_err:
    mov rdi, rdx
    jmp drain_err

# conn_write(conn, ptr, len) -> 1, or 0 when the connection is not up, its input has ended
# (conn_end_input) or the queue would pass CN_QUEUE_MAX. Bytes the pipe cannot take now wait in
# CN_wbuf, behind anything already waiting, and go out from on_in.
FN conn_write
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp dword ptr [rbx + CN_state], CN_UP
    jne .Lcw_no
    cmp dword ptr [rbx + CN_eof_in], 0      # conn_end_input was called: the input has ended
    jne .Lcw_no
    cmp dword ptr [rbx + CN_fd_in], 0
    jl .Lcw_no
    mov rax, [rbx + CN_wbuf + SB_len]
    sub rax, [rbx + CN_wpos]
    add rax, r13
    cmp rax, CN_QUEUE_MAX
    ja .Lcw_no
    mov rax, [rbx + CN_wbuf + SB_len]
    cmp rax, [rbx + CN_wpos]
    jne .Lcw_queue
    # the queue is empty: the stall clock starts now, not at the last write
    call time_ms
    mov [rbx + CN_moved], rax
1:  test r13, r13
    jz .Lcw_ok
    mov edi, [rbx + CN_fd_in]
    mov rsi, r12
    mov rdx, r13
    SYS SYS_write
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je .Lcw_queue
    test rax, rax
    js .Lcw_broken
    add r12, rax
    sub r13, rax
    call time_ms
    mov [rbx + CN_moved], rax
    jmp 1b
.Lcw_queue:
    lea rdi, [rbx + CN_wbuf]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    cmp dword ptr [rbx + CN_wwatch], 0
    jne .Lcw_ok
    mov edi, [rbx + CN_fd_in]
    mov esi, POLLOUT
    lea rdx, [rip + on_in]
    mov rcx, rbx
    call watch_add
    test eax, eax
    jz .Lcw_nowatch
    mov dword ptr [rbx + CN_wwatch], 1
.Lcw_ok:
    mov eax, 1
    EPILOGUE
.Lcw_broken:
    mov rdi, rbx
    mov esi, CN_E_WRITE
    call conn_break
    mov eax, 1                  # accepted; the connection reports its end through on_close
    EPILOGUE
.Lcw_nowatch:
    mov rdi, rbx
    mov esi, CN_E_WATCH
    call conn_break
    mov eax, 1
    EPILOGUE
.Lcw_no:
    xor eax, eax
    EPILOGUE

# on_in(fd, revents, ctx): the child's stdin can take more. CN_wpos avoids moving the queue after
# every write; the queue is compacted when it is drained or when the front half is dead.
# The only callback it triggers is conn_break's on_close, after which it touches nothing.
on_in:
    PROLOGUE
    mov rbx, rdx
1:  mov r13, [rbx + CN_wbuf + SB_len]
    sub r13, [rbx + CN_wpos]
    test r13, r13
    jz 3f
    mov edi, [rbx + CN_fd_in]
    mov rsi, [rbx + CN_wbuf + SB_ptr]
    add rsi, [rbx + CN_wpos]
    mov rdx, r13
    SYS SYS_write
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    js 6f
    add [rbx + CN_wpos], rax
    call time_ms
    mov [rbx + CN_moved], rax
    mov rax, [rbx + CN_wpos]
    mov rcx, [rbx + CN_wbuf + SB_len]
    shr rcx, 1
    cmp rax, rcx
    jb 1b
    # compact: move the live tail to the front
    mov rdi, [rbx + CN_wbuf + SB_ptr]
    lea rsi, [rdi + rax]
    mov rdx, [rbx + CN_wbuf + SB_len]
    sub rdx, rax
    call memmove
    mov rax, [rbx + CN_wpos]
    sub [rbx + CN_wbuf + SB_len], rax
    mov qword ptr [rbx + CN_wpos], 0
    jmp 1b
3:  mov qword ptr [rbx + CN_wbuf + SB_len], 0
    mov qword ptr [rbx + CN_wpos], 0
    mov edi, [rbx + CN_fd_in]
    call watch_remove
    mov dword ptr [rbx + CN_wwatch], 0
    cmp dword ptr [rbx + CN_eof_in], 0
    je 9f
    mov edi, [rbx + CN_fd_in]
    SYS SYS_close
    mov dword ptr [rbx + CN_fd_in], -1
    jmp 9f
6:  mov rdi, rbx
    mov esi, CN_E_WRITE
    call conn_break             # on_close may have closed or reopened the connection: return at once
9:  EPILOGUE

# conn_end_input(conn): close the child's stdin once the queue has drained
FN conn_end_input
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + CN_state], CN_IDLE     # never opened: CN_fd_in is not a pipe
    je 9f
    mov dword ptr [rbx + CN_eof_in], 1
    cmp dword ptr [rbx + CN_fd_in], 0
    jl 9f
    mov rax, [rbx + CN_wbuf + SB_len]
    cmp rax, [rbx + CN_wpos]
    jne 9f
    mov edi, [rbx + CN_fd_in]
    SYS SYS_close
    mov dword ptr [rbx + CN_fd_in], -1
9:  EPILOGUE

# unwatch_close(conn): remove every watch and close every pipe
unwatch_close:
    PROLOGUE
    mov rbx, rdi
    mov edi, [rbx + CN_fd_out]
    test edi, edi
    js 1f
    call watch_remove
    mov edi, [rbx + CN_fd_out]
    SYS SYS_close
    mov dword ptr [rbx + CN_fd_out], -1
1:  mov edi, [rbx + CN_fd_err]
    test edi, edi
    js 2f
    call watch_remove
    mov edi, [rbx + CN_fd_err]
    SYS SYS_close
    mov dword ptr [rbx + CN_fd_err], -1
2:  mov edi, [rbx + CN_fd_in]
    test edi, edi
    js 3f
    cmp dword ptr [rbx + CN_wwatch], 0
    je 21f
    call watch_remove
    mov dword ptr [rbx + CN_wwatch], 0
21: mov edi, [rbx + CN_fd_in]
    SYS SYS_close
    mov dword ptr [rbx + CN_fd_in], -1
3:  EPILOGUE

# forget(conn): drop it from conns
forget:
    lea r8, [rip + conns]
    xor ecx, ecx
1:  cmp ecx, [rip + nconns]
    jae 9f
    cmp [r8 + rcx*8], rdi
    je 2f
    inc ecx
    jmp 1b
2:  dec dword ptr [rip + nconns]
    mov edx, [rip + nconns]
    mov rax, [r8 + rdx*8]
    mov [r8 + rcx*8], rax
9:  ret

# zombie(pid, killed, kill_at): remember a child to reap; killed 1 means SIGKILL was already sent.
# The list holds CN_ZOMBIES: a child stopped when it is full is dropped (it keeps whatever signal it was
# sent, a SIGTERM is never escalated, and rhun never reaps it).
zombie:
    mov eax, [rip + nzombies]
    cmp eax, CN_ZOMBIES
    jae 9f
    shl eax, 4
    lea rcx, [rip + zombies]
    mov [rcx + rax], edi
    mov [rcx + rax + 4], esi
    mov [rcx + rax + 8], rdx
    inc dword ptr [rip + nzombies]
9:  ret

# conn_break(conn, err): the connection is unusable; kill the group, deliver on_close once.
# Buffers stay (CN_ebuf is shown in error cards) until conn_close.
FN conn_break
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp dword ptr [rbx + CN_state], CN_UP
    je 1f
    cmp dword ptr [rbx + CN_state], CN_STOPPING
    jne 9f
1:  mov [rbx + CN_err], r12d
    mov dword ptr [rbx + CN_state], CN_DEAD
    mov rdi, rbx
    call unwatch_close
    mov rdi, rbx
    call forget
    mov edi, [rbx + CN_pid]
    neg edi
    mov esi, SIGKILL
    SYS SYS_kill
    mov edi, [rbx + CN_pid]     # the child itself too: on macOS (fork) it may not have called setsid yet
    mov esi, SIGKILL
    SYS SYS_kill
    mov edi, [rbx + CN_pid]
    mov esi, 1
    xor edx, edx
    call zombie
    mov rdi, rbx
    mov esi, r12d
    call [rbx + CN_on_close]
9:  EPILOGUE

# conn_close(conn): SIGTERM the child (the tick escalates to SIGKILL), release everything; no on_close
FN conn_close
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + CN_state], CN_IDLE
    je 9f
    cmp dword ptr [rbx + CN_state], CN_DEAD
    je 2f
    mov edi, [rbx + CN_pid]
    neg edi
    mov esi, SIGTERM
    SYS SYS_kill
    mov edi, [rbx + CN_pid]     # here and below, the pid after its group: a child forked an instant
    mov esi, SIGTERM            # ago may not have called setsid yet (macOS vfork is a plain fork)
    SYS SYS_kill
    call time_ms
    add rax, CN_KILL_MS
    mov edi, [rbx + CN_pid]
    xor esi, esi
    mov rdx, rax
    call zombie
    mov rdi, rbx
    call forget
2:  mov rdi, rbx
    call unwatch_close
    lea rdi, [rbx + CN_rbuf]
    call sb_free
    lea rdi, [rbx + CN_ebuf]
    call sb_free
    lea rdi, [rbx + CN_wbuf]
    call sb_free
    mov dword ptr [rbx + CN_state], CN_IDLE
9:  EPILOGUE

# conn_stop(conn): ask the child to leave; the tick sends SIGKILL after CN_KILL_MS,
# and on_close(CN_E_EXIT) comes once it is reaped
FN conn_stop
    cmp dword ptr [rdi + CN_state], CN_UP
    jne 9f
    mov dword ptr [rdi + CN_state], CN_STOPPING
    push rdi
    call time_ms
    pop rdi
    add rax, CN_KILL_MS
    mov [rdi + CN_kill_at], rax
    push rdi
    mov edi, [rdi + CN_pid]
    neg edi
    mov esi, SIGTERM
    SYS SYS_kill
    pop rdi
    mov edi, [rdi + CN_pid]
    mov esi, SIGTERM
    SYS SYS_kill
9:  ret

# agent_conn_shutdown(): rhun is leaving; no child outlives it
FN agent_conn_shutdown
    push rbx
    xor ebx, ebx
1:  cmp ebx, [rip + nconns]
    jae 2f
    lea rax, [rip + conns]
    mov rax, [rax + rbx*8]
    mov edi, [rax + CN_pid]
    neg edi
    mov esi, SIGKILL
    SYS SYS_kill
    lea rax, [rip + conns]
    mov rax, [rax + rbx*8]
    mov edi, [rax + CN_pid]
    mov esi, SIGKILL
    SYS SYS_kill
    inc ebx
    jmp 1b
2:  xor ebx, ebx
3:  cmp ebx, [rip + nzombies]
    jae 9f
    mov eax, ebx
    shl eax, 4
    lea rcx, [rip + zombies]
    mov edi, [rcx + rax]
    neg edi
    mov esi, SIGKILL
    SYS SYS_kill
    mov eax, ebx
    shl eax, 4
    lea rcx, [rip + zombies]
    mov edi, [rcx + rax]
    mov esi, SIGKILL
    SYS SYS_kill
    inc ebx
    jmp 3b
9:  pop rbx
    ret

# reap(conn, status): the child exited: drain what the pipes still hold, then on_close(CN_E_EXIT)
reap:
    PROLOGUE
    mov rbx, rdi
    mov r12d, [rbx + CN_gen]
    mov [rbx + CN_exit], esi
    mov dword ptr [rbx + CN_err], CN_E_EXIT
    mov rdi, rbx
    call drain_err
    mov rdi, rbx
    call drain_out
    cmp r12d, [rbx + CN_gen]    # a callback reopened it: the new child is not this one
    jne 9f
    cmp dword ptr [rbx + CN_state], CN_IDLE
    je 9f
    cmp dword ptr [rbx + CN_state], CN_DEAD
    je 9f
    mov rdx, [rbx + CN_rbuf + SB_len]
    test rdx, rdx
    jz 1f
    mov rdi, rbx
    mov rsi, [rbx + CN_rbuf + SB_ptr]
    call [rbx + CN_on_line]
    cmp r12d, [rbx + CN_gen]
    jne 9f
    cmp dword ptr [rbx + CN_state], CN_IDLE
    je 9f
    mov qword ptr [rbx + CN_rbuf + SB_len], 0
    mov qword ptr [rbx + CN_scanned], 0
1:  mov dword ptr [rbx + CN_state], CN_DEAD
    mov rdi, rbx
    call unwatch_close
    mov rdi, rbx
    call forget
    mov rdi, rbx
    mov esi, CN_E_EXIT
    call [rbx + CN_on_close]
9:  EPILOGUE

# agent_conn_tick(now_ms): reap exited children, break stalled connections, escalate stops, reap zombies
FN agent_conn_tick
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12d, [rip + nconns]
    jae 3f
    lea rax, [rip + conns]
    mov r13, [rax + r12*8]
    mov edi, [r13 + CN_pid]
    mov esi, 1
    call proc_wait
    cmp eax, -1
    je 21f
    cmp eax, -2
    je 2f
    mov rdi, r13
    mov esi, eax
    call reap                   # forget() shifted the list: look at r12 again
    jmp 1b
21: cmp dword ptr [r13 + CN_state], CN_STOPPING
    jne 22f
    mov rax, [r13 + CN_kill_at]
    test rax, rax
    jz 2f
    cmp rbx, rax
    jb 2f
    mov qword ptr [r13 + CN_kill_at], 0
    mov edi, [r13 + CN_pid]
    neg edi
    mov esi, SIGKILL
    SYS SYS_kill
    mov edi, [r13 + CN_pid]
    mov esi, SIGKILL
    SYS SYS_kill
    jmp 2f
22: cmp dword ptr [r13 + CN_state], CN_UP
    jne 2f
    mov rax, [r13 + CN_wbuf + SB_len]
    cmp rax, [r13 + CN_wpos]
    je 2f
    mov rax, rbx
    sub rax, [r13 + CN_moved]   # signed: a now sampled before the last write is not a huge age
    mov ecx, [rip + g_conn_stall_ms]
    cmp rax, rcx
    jle 2f
    mov rdi, r13
    mov esi, CN_E_STALL
    call conn_break             # forget() shifted the list: look at r12 again
    jmp 1b
2:  inc r12d
    jmp 1b
3:  xor r12d, r12d
4:  cmp r12d, [rip + nzombies]
    jae 9f
    mov eax, r12d
    shl eax, 4
    lea r13, [rip + zombies]
    add r13, rax
    mov edi, [r13]
    mov esi, 1
    call proc_wait
    cmp eax, -1
    jne 5f
    cmp dword ptr [r13 + 4], 0
    jne 6f
    cmp rbx, [r13 + 8]
    jb 6f
    mov edi, [r13]
    neg edi
    mov esi, SIGKILL
    SYS SYS_kill
    mov edi, [r13]
    mov esi, SIGKILL
    SYS SYS_kill
    mov dword ptr [r13 + 4], 1
6:  inc r12d
    jmp 4b
5:  # gone: move the last entry here
    dec dword ptr [rip + nzombies]
    mov eax, [rip + nzombies]
    shl eax, 4
    lea rcx, [rip + zombies]
    mov rdx, [rcx + rax]
    mov [r13], rdx
    mov rdx, [rcx + rax + 8]
    mov [r13 + 8], rdx
    jmp 4b
9:  EPILOGUE

# agent_conn_timeout() -> ms until the tick has work, or -1: zombies to reap, stops to escalate or
# queues to watch for stalls want 50 ms; a child that closed its pipes but runs on (its exit wakes
# no poll) wants 1 s
FN agent_conn_timeout
    cmp dword ptr [rip + nzombies], 0
    jne 1f
    xor ecx, ecx
    mov eax, -1
2:  cmp ecx, [rip + nconns]
    jae 9f
    lea rdx, [rip + conns]
    mov rdx, [rdx + rcx*8]
    cmp dword ptr [rdx + CN_state], CN_STOPPING
    je 1f
    mov r8, [rdx + CN_wbuf + SB_len]
    cmp r8, [rdx + CN_wpos]
    jne 1f
    cmp dword ptr [rdx + CN_fd_out], 0
    jge 3f
    cmp dword ptr [rdx + CN_fd_err], 0
    jge 3f
    mov eax, 1000
3:  inc ecx
    jmp 2b
1:  mov eax, 50
9:  ret

# agent_conn_zombies() -> stopped children not yet reaped (tests)
FN agent_conn_zombies
    mov eax, [rip + nzombies]
    ret

.section .rodata
.Lnl: .byte 10
.text

.else
FN conn_open
    mov dword ptr [rdi + CN_err], CN_E_SPAWN
    xor eax, eax
    ret
FN conn_break
    ret
FN conn_close
    ret
FN conn_stop
    ret
FN agent_conn_shutdown
    ret
FN conn_write
    xor eax, eax
    ret
FN conn_end_input
    ret
FN agent_conn_tick
    ret
FN agent_conn_timeout
    mov eax, -1
    ret
FN agent_conn_zombies
    xor eax, eax
    ret
.endif
