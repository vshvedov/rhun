# agent connections: a long-lived child on three pipes, started through uproc.s (the user's program:
# outside every sandbox, a process group of its own, a job object on Windows). Its stdout arrives as
# lines (CN_on_line), its stderr keeps its tail (CN_ebuf), its stdin is a bounded queue flushed on
# POLLOUT. Knows nothing of JSON or agents.
#
# Reaping is the connection's own, so the exit status is kept: once stdout reached its end, or the
# connection is stopping, the tick asks uproc_wait (each tick for 500 ms after the end or a signal, then
# at 1 s steps) and on a status delivers what the pipes still hold, then on_close(CN_E_EXIT) with
# CN_exit set. uproc_end is used only where nobody wants the status any more (conn_close, a break,
# agent_conn_shutdown): it hands the child to uproc_tick, which reaps it.
#
# The stop sequence: the input closes (conn_end_input once the queue drained; conn_stop at once),
# SIGTERM g_conn_term_ms later (conn_stop: now), SIGKILL g_conn_kill_ms after that. A child that closed
# its stdout but still runs g_conn_eof_ms later gets it too. On Windows the first signal ends the job.
#
# Callbacks: on_line and on_close may write to, end, stop, break, close or reopen their connection (a
# reopen moves CN_gen; a close leaves CN_IDLE, its buffers freed): every caller of a callback checks
# both before it touches the connection again. Once CN_exit is set (the child is reaped, a callback runs
# during the last drain) no signal goes to its pid: the kernel may have given the number to another.
#
# agent_conn_count() is how many are open (the cap), agent_conn_owns(pid) whether a pid is one of their
# children (rhun's own programs are no holders of a conversation: agent_holder.s).
.include "rhun.inc"

.equ REAP_FAST_MS, 500          # uproc_wait each tick this long after the end of stdout or a signal
.equ REAP_STEP_MS, 1000         # then this often
.equ FAST_TICK_MS, 50           # what the timeout asks for while reaping is fast
.equ READ_CHUNK, 65536
.equ ERR_CHUNK, 16384
.equ ERR_READS, 16              # stderr reads per wake-up (256 KiB)

.bss
.p2align 3
conns: .zero 8 * CN_MAX         # the open connections (CN_UP, CN_STOPPING), compacted
nconns: .long 0
.p2align 3
probe: .zero 8                  # a pollfd for on_in's check

.data
.p2align 2
.globl g_conn_term_ms, g_conn_kill_ms, g_conn_stall_ms, g_conn_eof_ms, g_conn_max
g_conn_term_ms: .long CN_TERM_MS
g_conn_kill_ms: .long CN_KILL_MS
g_conn_stall_ms: .long CN_STALL_MS
g_conn_eof_ms: .long CN_EOF_MS
g_conn_max: .long CN_MAX

.text

# nonblock(fd)
nonblock:
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    ret

# live(conn) -> eax 1 when it is CN_UP or CN_STOPPING
live:
    xor eax, eax
    cmp dword ptr [rdi + CN_state], CN_UP
    je 1f
    cmp dword ptr [rdi + CN_state], CN_STOPPING
    jne 2f
1:  mov eax, 1
2:  ret

# conn_open(conn, argv, envp, cwd) -> eax 1, or 0 with CN_err: CN_E_GUARD (g_conn_max open), CN_E_SPAWN
#   or CN_E_WATCH (everything released). argv[0] is a path (uproc_which first) and must be executable:
#   a failed exec is only a child that exits 127, so it is checked first. The caller sets CN_on_line,
#   CN_on_close and CN_ctx before. A connection that is not CN_IDLE is closed first (conn_close, no
#   callback), so a dead one may be reopened, from its on_close too.
FN conn_open
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    cmp dword ptr [rbx + CN_state], CN_IDLE
    je 1f
    mov rdi, rbx
    call conn_close
1:  mov dword ptr [rbx + CN_err], CN_E_GUARD
    mov eax, [rip + nconns]
    cmp eax, CN_MAX
    jae .Lco_fail
    cmp eax, [rip + g_conn_max]
    jae .Lco_fail
    mov dword ptr [rbx + CN_err], CN_E_SPAWN
    mov rdi, [r12]
    test rdi, rdi
    jz .Lco_fail
    mov esi, 1                  # X_OK
    SYS SYS_access
    test rax, rax
    jnz .Lco_fail
    lea rdi, [rsp]              # in: [0] the child reads, [4] rhun writes
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    jnz .Lco_fail
    lea rdi, [rsp + 8]          # out: [8] rhun reads, [12] the child writes
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    jnz .Lco_close_in
    lea rdi, [rsp + 16]         # err: [16] rhun reads, [20] the child writes
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    jnz .Lco_close_out
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov ecx, [rsp]
    mov r8d, [rsp + 12]
    mov r9d, [rsp + 20]
    xor eax, eax                # no terminal: a session of its own
    push rax
    push rax
    call uproc_spawn
    add rsp, 16
    mov r15, rax
    mov edi, [rsp]              # the child's ends
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
    lea rdi, [rbx + CN_ebuf]
    call sb_clear
    lea rdi, [rbx + CN_wbuf]
    call sb_clear
    xor eax, eax
    mov [rbx + CN_scanned], rax
    mov [rbx + CN_wpos], rax
    mov [rbx + CN_stop_at], rax
    mov [rbx + CN_eof_at], rax
    mov [rbx + CN_reap_from], rax
    mov [rbx + CN_reap_at], rax
    mov dword ptr [rbx + CN_flags], 0
    mov dword ptr [rbx + CN_exit], -1
    inc dword ptr [rbx + CN_gen]
    call time_ms
    mov [rbx + CN_moved], rax
    mov edi, [rbx + CN_fd_out]
    mov esi, POLLIN
    lea rdx, [rip + on_out]
    mov rcx, rbx
    call watch_try_add
    test eax, eax
    jz .Lco_nowatch
    mov edi, [rbx + CN_fd_err]
    mov esi, POLLIN
    lea rdx, [rip + on_err]
    mov rcx, rbx
    call watch_try_add
    test eax, eax
    jz .Lco_nowatch_out
    mov edi, [rbx + CN_fd_in]   # idle until bytes wait to go out; an error still wakes it
    xor esi, esi
    lea rdx, [rip + on_in]
    mov rcx, rbx
    call watch_try_add
    test eax, eax
    jz .Lco_nowatch_err
    mov dword ptr [rbx + CN_state], CN_UP
    mov dword ptr [rbx + CN_err], CN_E_NONE
    mov eax, [rip + nconns]
    lea rcx, [rip + conns]
    mov [rcx + rax*8], rbx
    inc dword ptr [rip + nconns]
    mov eax, 1
    EPILOGUE
.Lco_nowatch_err:
    mov edi, [rbx + CN_fd_err]
    call watch_remove
.Lco_nowatch_out:
    mov edi, [rbx + CN_fd_out]
    call watch_remove
.Lco_nowatch:
    mov dword ptr [rbx + CN_err], CN_E_WATCH
    mov edi, [rbx + CN_fd_in]
    SYS SYS_close
    mov edi, [rbx + CN_fd_out]
    SYS SYS_close
    mov edi, [rbx + CN_fd_err]
    SYS SYS_close
    mov dword ptr [rbx + CN_fd_in], -1
    mov dword ptr [rbx + CN_fd_out], -1
    mov dword ptr [rbx + CN_fd_err], -1
    mov edi, [rbx + CN_pid]
    mov esi, SIGKILL
    call uproc_signal
    mov edi, [rbx + CN_pid]     # uproc_tick reaps it
    xor esi, esi
    call uproc_end
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

# ---------------- stdout and stderr ----------------

# deliver(conn): every complete line of CN_rbuf to CN_on_line; the remainder moves to the front. The
#   search starts at CN_scanned, so a long line is scanned once, not once per read. A line above
#   CN_LINE_MAX breaks the connection (CN_E_LINE) instead. Stops when a callback closed the connection
#   (CN_IDLE: its buffers are gone) or reopened it (CN_gen moved: the buffers are the new child's).
deliver:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d              # bytes consumed
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
    cmp r13, CN_LINE_MAX        # a whole line can pass the limit within one read: never delivered
    ja 4f
    mov rdi, rbx
    mov rsi, [rbx + CN_rbuf + SB_ptr]
    add rsi, r12
    mov rdx, r13
    call [rbx + CN_on_line]
    lea r12, [r12 + r13 + 1]
    mov r14, r12
    jmp 1b
4:  mov rdi, rbx                # on_close may close or reopen it: the loop's checks come first
    mov esi, CN_E_LINE
    call conn_break
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

# drain_out(conn) -> eax 0 when more may come (nothing to read now, or CN_DRAIN bytes read), 1 at the
#   end of stdout (or it was closed already), 2 when the connection is not this one's any more (a
#   callback closed, broke or reopened it, or it broke here on a read error or a line too long)
drain_out:
    PROLOGUE
    mov rbx, rdi
    mov r12, CN_DRAIN           # bytes left in this wake-up's budget
    mov r13d, [rbx + CN_gen]
1:  cmp dword ptr [rbx + CN_fd_out], 0
    jl 8f
    lea rdi, [rbx + CN_rbuf]
    mov esi, READ_CHUNK
    call sb_reserve
    mov rsi, rax
    mov edi, [rbx + CN_fd_out]
    mov edx, READ_CHUNK
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 7f
    test rax, rax
    jz 8f
    js 5f
    add [rbx + CN_rbuf + SB_len], rax
    sub r12, rax
    mov rdi, rbx
    call deliver
    cmp r13d, [rbx + CN_gen]
    jne 6f
    mov rdi, rbx
    call live
    test eax, eax
    jz 6f
    cmp qword ptr [rbx + CN_rbuf + SB_len], CN_LINE_MAX
    ja 4f
    test r12, r12
    jg 1b
7:  xor eax, eax
    EPILOGUE
4:  mov rdi, rbx
    mov esi, CN_E_LINE
    call conn_break
    jmp 6f
5:  mov rdi, rbx
    mov esi, CN_E_READ
    call conn_break
6:  mov eax, 2
    EPILOGUE
8:  mov eax, 1
    EPILOGUE

# on_out(fd, revents, conn): stdout is readable or at its end. At the end an unterminated last line is
#   a line too, CN_eof_at is set and reaping begins.
on_out:
    PROLOGUE
    mov rbx, rdx
    mov r12d, [rbx + CN_gen]
    mov rdi, rbx
    call drain_out
    cmp eax, 1
    jne 9f
    cmp dword ptr [rbx + CN_fd_out], 0
    jl 9f
    mov edi, [rbx + CN_fd_out]
    call watch_remove
    mov edi, [rbx + CN_fd_out]
    SYS SYS_close
    mov dword ptr [rbx + CN_fd_out], -1
    mov rdx, [rbx + CN_rbuf + SB_len]
    test rdx, rdx
    jz 1f
    mov rdi, rbx
    mov rsi, [rbx + CN_rbuf + SB_ptr]
    call [rbx + CN_on_line]
    cmp r12d, [rbx + CN_gen]
    jne 9f
    mov rdi, rbx
    call live
    test eax, eax
    jz 9f
    mov qword ptr [rbx + CN_rbuf + SB_len], 0
    mov qword ptr [rbx + CN_scanned], 0
1:  call time_ms
    mov [rbx + CN_eof_at], rax
    mov [rbx + CN_reap_from], rax
    mov qword ptr [rbx + CN_reap_at], 0
9:  EPILOGUE

# drain_err(conn): read stderr, keep its last CN_ERR_KEEP bytes; at its end the pipe closes. Calls no one.
drain_err:
    PROLOGUE
    mov rbx, rdi
    mov r12d, ERR_READS
1:  cmp dword ptr [rbx + CN_fd_err], 0
    jl 9f
    lea rdi, [rbx + CN_ebuf]
    mov esi, ERR_CHUNK
    call sb_reserve
    mov rsi, rax
    mov edi, [rbx + CN_fd_err]
    mov edx, ERR_CHUNK
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
    sub rax, CN_ERR_KEEP        # bytes to drop
    mov rdi, [rbx + CN_ebuf + SB_ptr]
    lea rsi, [rdi + rax]
    mov edx, CN_ERR_KEEP
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

# on_err(fd, revents, conn)
on_err:
    mov rdi, rdx
    jmp drain_err

# ---------------- stdin ----------------

# close_input(conn): stdin closes and its queue goes; after conn_end_input the SIGTERM is due
#   g_conn_term_ms from now (unless the stop sequence is further on already)
close_input:
    PROLOGUE
    mov rbx, rdi
    mov edi, [rbx + CN_fd_in]
    test edi, edi
    js 1f
    call watch_remove
    mov edi, [rbx + CN_fd_in]
    SYS SYS_close
    mov dword ptr [rbx + CN_fd_in], -1
1:  mov qword ptr [rbx + CN_wbuf + SB_len], 0
    mov qword ptr [rbx + CN_wpos], 0
    test dword ptr [rbx + CN_flags], CNF_ENDIN
    jz 9f
    test dword ptr [rbx + CN_flags], CNF_TERM
    jnz 9f
    cmp qword ptr [rbx + CN_stop_at], 0
    jne 9f
    call time_ms
    mov ecx, [rip + g_conn_term_ms]
    add rax, rcx
    mov [rbx + CN_stop_at], rax
9:  EPILOGUE

# flush(conn): write what is queued. CN_wpos saves moving the queue after every write; it is compacted
#   when drained or when its front half is written. The only callback it may cause is a break's on_close,
#   after which it touches nothing.
flush:
    PROLOGUE
    mov rbx, rdi
1:  cmp dword ptr [rbx + CN_fd_in], 0
    jl 9f
    mov r13, [rbx + CN_wbuf + SB_len]
    sub r13, [rbx + CN_wpos]
    jz 3f
    mov edi, [rbx + CN_fd_in]
    mov rsi, [rbx + CN_wbuf + SB_ptr]
    add rsi, [rbx + CN_wpos]
    mov rdx, r13
    SYS SYS_write
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 4f
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
    mov rdi, [rbx + CN_wbuf + SB_ptr]   # compact: the unwritten tail to the front
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
    xor esi, esi
    call watch_set_events
    test dword ptr [rbx + CN_flags], CNF_ENDIN
    jz 9f
    mov rdi, rbx
    call close_input
    jmp 9f
4:  mov edi, [rbx + CN_fd_in]
    mov esi, POLLOUT
    call watch_set_events
    jmp 9f
6:  mov rdi, rbx
    mov esi, CN_E_WRITE
    call conn_break
9:  EPILOGUE

# on_in(fd, revents, conn): stdin can take more, or its reader is gone. With nothing queued an error
#   is checked again (the descriptor's number may be another's by now) and then closes the input: a
#   watch with no events still reports it, at every poll.
on_in:
    PROLOGUE
    mov rbx, rdx
    mov rax, [rbx + CN_wbuf + SB_len]
    cmp rax, [rbx + CN_wpos]
    jne 5f
    test esi, POLLERR | POLLHUP
    jz 9f
    mov eax, [rbx + CN_fd_in]
    test eax, eax
    js 9f
    mov [rip + probe], eax
    mov dword ptr [rip + probe + 4], 0
    lea rdi, [rip + probe]
    mov esi, 1
    xor edx, edx
    SYS SYS_poll
    test rax, rax
    jle 9f
    test word ptr [rip + probe + 6], POLLERR | POLLHUP
    jz 9f
    mov rdi, rbx
    call close_input
    jmp 9f
5:  mov rdi, rbx
    call flush
9:  EPILOGUE

# conn_write(conn, ptr, len) -> eax 1, or 0 when the connection is not up, its input has ended or the
#   queue would pass CN_QUEUE_MAX. What the pipe cannot take now waits in CN_wbuf, behind anything
#   already waiting, and goes out on POLLOUT. A write error breaks the connection (CN_E_WRITE, on_close
#   before this returns 1).
FN conn_write
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp dword ptr [rbx + CN_state], CN_UP
    jne 8f
    cmp dword ptr [rbx + CN_fd_in], 0
    jl 8f
    mov rax, [rbx + CN_wbuf + SB_len]
    sub rax, [rbx + CN_wpos]
    mov r14, rax                # bytes waiting
    add rax, r13
    cmp rax, CN_QUEUE_MAX
    ja 8f
    test r13, r13
    jz 7f
    test r14, r14
    jnz 1f
    call time_ms                # the queue was empty: the stall clock starts now
    mov [rbx + CN_moved], rax
1:  lea rdi, [rbx + CN_wbuf]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, rbx
    call flush
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# conn_end_input(conn): stdin closes once the queue drained, and the stop sequence is armed: SIGTERM
#   g_conn_term_ms after that unless the child left first. No more writes.
FN conn_end_input
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + CN_state], CN_UP
    jne 9f
    mov dword ptr [rbx + CN_state], CN_STOPPING
    or dword ptr [rbx + CN_flags], CNF_ENDIN
    call time_ms
    mov [rbx + CN_reap_from], rax
    mov qword ptr [rbx + CN_reap_at], 0
    mov rax, [rbx + CN_wbuf + SB_len]
    cmp rax, [rbx + CN_wpos]
    jne 9f
    mov rdi, rbx
    call close_input
9:  EPILOGUE

# conn_stop(conn): the stop sequence now: stdin closes (what is queued is dropped), SIGTERM at the next
#   tick, SIGKILL g_conn_kill_ms later; on_close(CN_E_EXIT) when it is reaped. Calls no one.
FN conn_stop
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    call live
    test eax, eax
    jz 9f
    mov dword ptr [rbx + CN_state], CN_STOPPING
    or dword ptr [rbx + CN_flags], CNF_ENDIN
    call time_ms
    mov [rbx + CN_reap_from], rax
    mov qword ptr [rbx + CN_reap_at], 0
    test dword ptr [rbx + CN_flags], CNF_TERM
    jnz 1f
    mov [rbx + CN_stop_at], rax
1:  mov rdi, rbx
    call close_input
9:  EPILOGUE

# ---------------- the end ----------------

# unwatch_close(conn): every watch removed, every pipe closed
unwatch_close:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rbx + CN_fd_in]
    xor r13d, r13d
1:  mov edi, [r12 + r13*4]
    test edi, edi
    js 2f
    call watch_remove
    mov edi, [r12 + r13*4]
    SYS SYS_close
    mov dword ptr [r12 + r13*4], -1
2:  inc r13d
    cmp r13d, 3                 # CN_fd_in, CN_fd_out, CN_fd_err are adjacent
    jb 1b
    EPILOGUE

# forget(conn): off the list of open connections (nothing when it is not there)
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

# conn_break(conn, err): the connection is unusable: its group is killed (and reaped by uproc_tick),
#   on_close(err) once. Buffers stay (CN_ebuf for the error row) until conn_close or conn_open.
FN conn_break
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    call live
    test eax, eax
    jz 9f
    mov [rbx + CN_err], r12d
    mov dword ptr [rbx + CN_state], CN_DEAD
    mov rdi, rbx
    call drain_err              # the last of stderr explains the end; drain_err calls no one
    mov rdi, rbx
    call unwatch_close
    mov rdi, rbx
    call forget
    cmp dword ptr [rbx + CN_exit], -1   # reaped already (a callback in reap): the pid is not ours
    jne 1f
    mov edi, [rbx + CN_pid]
    mov esi, SIGKILL
    call uproc_signal
    mov edi, [rbx + CN_pid]
    xor esi, esi
    call uproc_end
1:  mov rdi, rbx
    mov esi, r12d
    call [rbx + CN_on_close]
9:  EPILOGUE

# conn_close(conn): release everything, no callback; a child still running gets SIGHUP and SIGTERM now
#   and SIGKILL g_conn_kill_ms later, and uproc_tick reaps it
FN conn_close
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + CN_state], CN_IDLE
    je 9f
    mov rdi, rbx
    call live
    test eax, eax
    jz 1f
    mov rdi, rbx
    call forget
    cmp dword ptr [rbx + CN_exit], -1
    jne 1f
    mov edi, [rbx + CN_pid]
    mov esi, [rip + g_conn_kill_ms]
    call uproc_end
1:  mov rdi, rbx
    call unwatch_close
    lea rdi, [rbx + CN_rbuf]
    call sb_free
    lea rdi, [rbx + CN_ebuf]
    call sb_free
    lea rdi, [rbx + CN_wbuf]
    call sb_free
    mov qword ptr [rbx + CN_scanned], 0
    mov qword ptr [rbx + CN_wpos], 0
    mov dword ptr [rbx + CN_state], CN_IDLE
9:  EPILOGUE

# reap(conn, status): the child is gone (status -1: it was not ours any more): what the pipes still hold
#   is delivered, the last unterminated line too, then on_close(CN_E_EXIT). CN_exit is set first.
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
    cmp eax, 2
    je 9f
    mov rdx, [rbx + CN_rbuf + SB_len]
    test rdx, rdx
    jz 1f
    mov rdi, rbx
    mov rsi, [rbx + CN_rbuf + SB_ptr]
    call [rbx + CN_on_line]
    cmp r12d, [rbx + CN_gen]
    jne 9f
    mov rdi, rbx
    call live
    test eax, eax
    jz 9f
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

# agent_conn_shutdown(): rhun is leaving: every child still running gets SIGHUP and SIGTERM now (and
#   uproc_quit_end the rest); the pipes close, no callback. Each connection is left CN_DEAD.
FN agent_conn_shutdown
    PROLOGUE
1:  mov eax, [rip + nconns]
    test eax, eax
    jz 9f
    lea rcx, [rip + conns]
    mov rbx, [rcx + rax*8 - 8]
    dec dword ptr [rip + nconns]
    mov rdi, rbx
    call unwatch_close
    mov dword ptr [rbx + CN_state], CN_DEAD
    cmp dword ptr [rbx + CN_exit], -1
    jne 1b
    mov edi, [rbx + CN_pid]
    mov esi, [rip + g_conn_kill_ms]
    call uproc_end
    jmp 1b
9:  EPILOGUE

# agent_conn_tick(): reap what has gone, break stalled queues, the stop sequence's signals, the end of
#   stdout's deadline. A callback may change the list: the entry at the same index is looked at again.
FN agent_conn_tick
    PROLOGUE
    cmp dword ptr [rip + nconns], 0
    je 9f
    call time_ms
    mov r14, rax                # now
    xor r12d, r12d
.Lct_next:
    cmp r12d, [rip + nconns]
    jae 9f
    lea rax, [rip + conns]
    mov rbx, [rax + r12*8]
    # reaping: once stdout ended, or while stopping
    cmp qword ptr [rbx + CN_eof_at], 0
    jne 1f
    cmp dword ptr [rbx + CN_state], CN_STOPPING
    jne .Lct_stall
1:  mov r13, r14
    sub r13, [rbx + CN_reap_from]   # ms since the end or the last signal
    cmp r13, REAP_FAST_MS
    jl 2f
    cmp r14, [rbx + CN_reap_at]
    jl .Lct_stall
2:  mov edi, [rbx + CN_pid]
    mov esi, 1
    call uproc_wait
    cmp eax, -1
    je 3f
    cmp eax, -2
    jne 4f
    mov eax, -1                 # not ours any more: no status
4:  mov rdi, rbx
    mov esi, eax
    call reap
    jmp .Lct_next
3:  cmp r13, REAP_FAST_MS
    jl .Lct_stall
    lea rax, [r14 + REAP_STEP_MS]
    mov [rbx + CN_reap_at], rax
.Lct_stall:
    mov rax, [rbx + CN_wbuf + SB_len]
    cmp rax, [rbx + CN_wpos]
    je .Lct_eof
    mov rax, r14
    sub rax, [rbx + CN_moved]   # signed: a now sampled before the last write is not a huge age
    mov ecx, [rip + g_conn_stall_ms]
    cmp rax, rcx
    jle .Lct_eof
    mov rdi, rbx
    mov esi, CN_E_STALL
    call conn_break
    jmp .Lct_next
.Lct_eof:
    cmp dword ptr [rbx + CN_state], CN_UP
    jne .Lct_stop
    mov rax, [rbx + CN_eof_at]
    test rax, rax
    jz .Lct_stop
    mov ecx, [rip + g_conn_eof_ms]
    add rax, rcx
    cmp r14, rax
    jl .Lct_stop
    mov rdi, rbx                # stdout ended long ago and it still runs: it is stopped
    call conn_stop
.Lct_stop:
    mov rax, [rbx + CN_stop_at]
    test rax, rax
    jz .Lct_skip
    cmp r14, rax
    jl .Lct_skip
    cmp dword ptr [rbx + CN_exit], -1
    jne .Lct_skip
    test dword ptr [rbx + CN_flags], CNF_TERM
    jnz 5f
    or dword ptr [rbx + CN_flags], CNF_TERM
    mov edi, [rbx + CN_pid]
    mov esi, SIGTERM
    call uproc_signal
    mov ecx, [rip + g_conn_kill_ms]
    lea rax, [r14 + rcx]
    mov [rbx + CN_stop_at], rax
    jmp 6f
5:  or dword ptr [rbx + CN_flags], CNF_KILL
    mov edi, [rbx + CN_pid]
    mov esi, SIGKILL
    call uproc_signal
    mov qword ptr [rbx + CN_stop_at], 0
6:  mov [rbx + CN_reap_from], r14   # reaping is fast again
    mov qword ptr [rbx + CN_reap_at], 0
.Lct_skip:
    inc r12d
    jmp .Lct_next
9:  EPILOGUE

# pick(rdi ms, r14 the soonest so far or -1) -> r14: the sooner of the two (ms below 0 is 0)
pick:
    test rdi, rdi
    jns 1f
    xor edi, edi
1:  mov eax, 0x3fffffff
    cmp rdi, rax
    jle 2f
    mov rdi, rax
2:  cmp r14, -1
    je 3f
    cmp rdi, r14
    jge 4f
3:  mov r14, rdi
4:  ret

# agent_conn_timeout() -> eax ms until the tick has work, or -1 (no connection, or none that waits for
#   anything): stop signals, stall deadlines, the end of stdout's deadline and reap retries
FN agent_conn_timeout
    PROLOGUE
    mov r14, -1
    cmp dword ptr [rip + nconns], 0
    je 9f
    call time_ms
    mov r15, rax
    xor r12d, r12d
1:  cmp r12d, [rip + nconns]
    jae 9f
    lea rax, [rip + conns]
    mov rbx, [rax + r12*8]
    cmp qword ptr [rbx + CN_eof_at], 0
    jne 2f
    cmp dword ptr [rbx + CN_state], CN_STOPPING
    jne 4f
2:  mov rax, r15
    sub rax, [rbx + CN_reap_from]
    mov edi, FAST_TICK_MS
    cmp rax, REAP_FAST_MS
    jl 3f
    mov rdi, [rbx + CN_reap_at]
    sub rdi, r15
3:  call pick
4:  mov rax, [rbx + CN_wbuf + SB_len]
    cmp rax, [rbx + CN_wpos]
    je 5f
    mov rdi, [rbx + CN_moved]
    mov eax, [rip + g_conn_stall_ms]
    lea rdi, [rdi + rax + 1]
    sub rdi, r15
    call pick
5:  cmp dword ptr [rbx + CN_state], CN_UP
    jne 6f
    mov rdi, [rbx + CN_eof_at]
    test rdi, rdi
    jz 6f
    mov eax, [rip + g_conn_eof_ms]
    add rdi, rax
    sub rdi, r15
    call pick
6:  mov rdi, [rbx + CN_stop_at]
    test rdi, rdi
    jz 7f
    sub rdi, r15
    call pick
7:  inc r12d
    jmp 1b
9:  mov eax, r14d
    EPILOGUE

# agent_conn_count() -> eax connections open (CN_UP or CN_STOPPING)
FN agent_conn_count
    mov eax, [rip + nconns]
    ret

# agent_conn_owns(pid) -> eax 1 when pid is the child of an open connection (rhun's own program)
FN agent_conn_owns
    xor ecx, ecx
    lea rdx, [rip + conns]
1:  cmp ecx, [rip + nconns]
    jae 8f
    mov rax, [rdx + rcx*8]
    inc ecx
    cmp [rax + CN_pid], edi
    jne 1b
    mov eax, 1
    ret
8:  xor eax, eax
    ret

.section .rodata
.Lnl: .byte 10
.text
