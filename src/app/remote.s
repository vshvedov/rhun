# remote windows (rhun --remote ssh:HOST PATH, docker:NAME, podman:NAME, local:): a window whose
# project, files, terminals, git and extensions are on another machine. The window starts the
# transport (ssh, docker exec) with `sh -s`, talks the shell into running `rhun --remote-agent` (the
# same static Linux binary, uploaded once into the host's cache), and then multiplexes everything
# over the transport's standard input and output. Every remote program is a local socketpair, so
# termview.s, git.s and ext.s read and write an ordinary descriptor; the pump here copies its bytes
# to and from the stream. vfs.s turns workspace file access into requests on channel 0.
#
# The mux protocol (internal: both ends are the same build). Lines end with LF; the last field of
# d, ok, v and of every request is the length of the bytes that follow the line.
#   d CH LEN + bytes      data on channel CH (either way)
#   e CH                  no more data on CH (from the window: close the program's input; from the
#                         agent: its output ended)
#   w CH N                N more bytes may be sent on CH (each side starts with MUX_WINDOW)
#   ID VERB ARG... LEN    a request (window to agent), answered by ok ID LEN + bytes or error ID ERRNO
#   x CH STATUS           the program on CH exited (STATUS as proc_wait reports it)
#   v WD MASK LEN + name  an inotify event of a watch
# The verbs are ragent.s's table: spawn kill resize close cwd info quit stat lstat realpath readlink
# read write list mkdir rename remove watch unwatch access files grep stats.
.include "rhun.inc"

.equ MUX_MAXCH, 1024
.equ MUX_WINDOW, 1048576
.equ MUX_LINE_MAX, 4096
.equ MUX_WQ_HIGH, 16777216
.equ MUX_GRANT, 65536
.equ MUX_READ, 65536
.equ MUX_FRAME, 4194304          # a program's input goes in frames this big (the agent takes 64 MB)
.equ MUX_RPC_MS, 10000          # a request waits this long without hearing anything from the host
.equ MUX_GC_MS, 30000           # an exited program nobody asked about is forgotten after this
.equ RLOG_MAX, 240
.equ RQ_MAX, 8                  # requests answered later (remote_request_cb)

STRUCT
F RQ_id, 4                      # 0 free
F RQ_done, 4
F RQ_status, 8                  # 0 or -errno
F RQ_cb, 8                      # cb(ctx, status, ptr, len) from remote_tick
F RQ_ctx, 8
F RQ_reply, SB_SIZE
ENDSTRUCT RQ_SIZE

# connection states (g_remote_state)
.equ RS_OFF, 0
.equ RS_DOWNLOAD, 1             # fetching the Linux binary (macOS, Windows)
.equ RS_CONNECT, 2              # the transport runs the bootstrap script
.equ RS_UPWAIT, 3               # the shell is about to read the binary
.equ RS_UPLOAD, 4               # sending the binary
.equ RS_START, 5                # waiting for the agent's hello
.equ RS_UP, 6
.equ RS_LOST, 7                 # the transport ended; Reconnect starts again
.equ RS_FAILED, 8               # it could not connect (the reason in rm_error)

# transports
.equ RT_SSH, 1
.equ RT_DOCKER, 2
.equ RT_PODMAN, 3
.equ RT_LOCAL, 4
.equ RT_WSL, 5

# channel kinds and flags
.equ CK_PROC, 1                 # a program; CH_fd is the pump's end of its socketpair
.equ CK_SINK, 2                 # a program's error output written to a descriptor (a log)
.equ CK_STREAM, 3               # bytes collected into CH_buf for the caller (file lists, search)
.equ CHF_REOF, 1                # the agent said e
.equ CHF_SHUT, 2                # the socket's sending side is shut (the local reader saw the end)
.equ CHF_LCLOSED, 4             # the local side closed its end
.equ CHF_EXITED, 8
.equ CHF_COLLECTED, 16          # proc_wait has reported the status
.equ CHF_ERRCH, 32              # a program's error output on a socketpair of its own (freed with it)
.equ CHF_DETACHED, 64           # the connection went; the program may still run in the host's session
.equ CHF_SEEN, 128              # remote_attach: the session still has it
.equ CHF_PENDING, 256           # a forwarded connection the host has not made yet: nothing is read

STRUCT
F CH_kind, 4                    # 0 free
F CH_fd, 4                      # -1 when closed
F CH_lfd, 4                     # the descriptor the caller holds (pty_resize finds the channel by it)
F CH_gen, 4
F CH_flags, 4
F CH_status, 4
F CH_pid, 4                     # the program's pid on the host
F CH_events, 4                  # what the loop watches CH_fd for
F CH_errch, 4                   # its error output's channel (CHF_ERRCH), 0 for none
F CH_cfail, 4                   # x's fourth field: the EXITC_* its confined child failed with, 0
F CH_credit, 8                  # bytes this side may still send to the agent
F CH_grant, 8                   # bytes delivered here and not yet credited back
F CH_off, 8                     # the delivered part of CH_buf
F CH_exited_at, 8
F CH_buf, SB_SIZE               # bytes from the agent not yet delivered
F CH_cb, 8                      # debugger: remote_sock_connect's cb(ctx, 0 connected | 1 refused), or 0
F CH_cbctx, 8
ENDSTRUCT CH_SIZE

.bss
.p2align 3
.globl g_remote, g_remote_state, g_remote_reply, g_remote_home, g_remote_window
g_remote: .long 0               # 1: this window is a remote window
g_remote_window: .long 0        # 1: it is one or will be (--remote, before the connection starts)
g_remote_state: .long 0         # RS_*
rm_kind: .long 0                # RT_*
rm_tpid: .long 0
rm_force: .long 0               # the cached binary did not match: send it again
rm_next_id: .long 0
rm_wait_id: .long 0             # the request a remote_call waits for
rm_got: .long 0                 # its answer came
rm_got_err: .long 0             # its error (positive errno), 0 for ok
rm_watching_in: .long 0
rm_need_open: .long 0           # connected: open the project on the next tick
rm_gen: .long 0
.p2align 3
rm_spec: .zero 512              # "ssh:HOST" as given
rm_sid: .zero 24                # the session the agent keeps on the host (16 hex digits), or empty
rm_ending: .long 0              # 1 while Disconnect ends the session (programs end with it)
rm_host: .zero 256              # HOST (or NAME)
rm_port: .zero 16
rm_path: .zero 4096             # the folder to open once connected
rm_error: .zero 512             # why it failed or was lost
rm_errline: .zero 512           # the last line the transport printed on its error output
rm_errlen: .quad 0
rm_rbuf: .zero SB_SIZE          # the stream from the host
rm_wq: .zero SB_SIZE            # the stream to the host
rm_wq_off: .quad 0
rm_up_total: .quad 0            # upload: bytes of the binary, and how far it got
rm_up_start: .quad 0            # rm_wq_off where the binary starts
rm_hash: .quad 0                # the binary's hash, checked against the agent's hello
rm_size: .quad 0
rm_bin: .zero 4096              # the binary sent to the host
g_remote_reply: .zero SB_SIZE   # the answer of the last remote_call
g_remote_home: .zero 4096       # the host's home folder
rm_line: .zero SB_SIZE          # scratch: a request's line
rm_toks: .zero 16 * 10
rm_ntok: .quad 0
rm_in_bytes: .quad 0            # counters for print-remote
rm_out_bytes: .quad 0
rm_rtt: .quad 0                 # the last request's round trip, ms
rm_log: .zero SB_SIZE           # the log's path
rm_dl_pid: .long 0              # the download of the Linux binary
rm_dl_out: .zero SB_SIZE
rm_ch: .zero CH_SIZE * MUX_MAXCH
rm_argv: .zero 8 * 20

.data
rm_tin: .long -1                # the transport's input (we write)
rm_tout: .long -1               # its output (we read)
rm_terr: .long -1               # its error output (the log)
rm_dl_fd: .long -1

.text

# ---------------- the wire ----------------

# mux_line(ptr, len) -> length of the first line with its LF; 0 when no LF yet; -1 when a line is
#   longer than MUX_LINE_MAX
FN mux_line
    mov rcx, rsi
    cmp rcx, MUX_LINE_MAX
    jbe 1f
    mov ecx, MUX_LINE_MAX
1:  xor eax, eax
2:  cmp rax, rcx
    jae 3f
    cmp byte ptr [rdi + rax], 10
    je 4f
    inc rax
    jmp 2b
3:  cmp rsi, MUX_LINE_MAX
    jb 5f
    mov rax, -1
    ret
5:  xor eax, eax
    ret
4:  inc rax
    ret

# mux_split(ptr, len, toks) -> count: the fields between single spaces, at most 10, as (ptr, len)
FN mux_split
    xor eax, eax                # fields
    xor ecx, ecx                # offset
    mov r8, rdi                 # start of the field
1:  cmp rcx, rsi
    jae 3f
    cmp byte ptr [rdi + rcx], ' '
    jne 2f
    cmp rax, 10
    jae 9f
    mov r9, rax
    shl r9, 4
    mov [rdx + r9], r8
    lea r10, [rdi + rcx]
    sub r10, r8
    mov [rdx + r9 + 8], r10
    inc rax
    lea r8, [rdi + rcx + 1]
2:  inc rcx
    jmp 1b
3:  lea r10, [rdi + rcx]
    sub r10, r8
    jz 9f
    cmp rax, 10
    jae 9f
    mov r9, rax
    shl r9, 4
    mov [rdx + r9], r8
    mov [rdx + r9 + 8], r10
    inc rax
9:  ret

# fnv_file(path) -> FNV-1a 64 of the file's bytes, 0 when it cannot be read. Names the binary in the
#   host's cache and lets the agent prove which binary it is (not a security check: ssh is)
FN fnv_file
    PROLOGUE 16
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 8f
    mov ebx, eax
    mov edi, 1048576
    call mem_alloc
    mov r12, rax
    mov r13, 0xcbf29ce484222325
    mov r15, 0x100000001b3
1:  mov edi, ebx
    mov rsi, r12
    mov edx, 1048576
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    test rax, rax
    jle 4f
    xor ecx, ecx
2:  movzx edx, byte ptr [r12 + rcx]
    xor r13, rdx
    imul r13, r15
    inc rcx
    cmp rcx, rax
    jb 2b
    jmp 1b
4:  mov r14, rax
    mov rdi, r12
    call mem_free
    mov edi, ebx
    SYS SYS_close
    xor eax, eax
    test r14, r14
    js 9f
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# rm_tok(i) -> rax ptr, rdx len of field i of the message being handled
rm_tok:
    mov eax, edi
    shl eax, 4
    lea rcx, [rip + rm_toks]
    mov rdx, [rcx + rax + 8]
    mov rax, [rcx + rax]
    ret

rm_num:
    call rm_tok
    mov rdi, rax
    mov rsi, rdx
    jmp parse_u64

# ---------------- connection ----------------

# remote_start(spec, path) -> 1 when the connection started. spec is ssh:HOST[:PORT],
#   docker:NAME, podman:NAME, wsl:DISTRO or local: (tests); path is the folder to open, or empty
#   for the host's home. The window becomes a remote window for good.
FN remote_start
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call strlen
    cmp rax, 500
    jae 8f
    lea rdi, [rip + rm_spec]
    mov rsi, rbx
    call cstr_copy
    mov byte ptr [rip + rm_path], 0
    test r12, r12
    jz 1f
    mov rdi, r12
    call strlen
    cmp rax, 4000
    jae 8f
    lea rdi, [rip + rm_path]
    mov rsi, r12
    call cstr_copy
1:  call rm_parse_spec
    test eax, eax
    jz 8f
    mov dword ptr [rip + g_remote], 1
    mov dword ptr [rip + g_remote_window], 1
    call rm_new_sid
    lea rdi, [rip + .Lenv_strict]
    call getenv
    test rax, rax
    jz 2f
    cmp byte ptr [rax], '1'
    jne 2f
    mov dword ptr [rip + g_remote_strict], 1
2:  # the when-clause keys remoteName and remoteHost
    call remote_kind_name
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov edi, CTX_REMOTE_NAME
    mov rsi, rbx
    mov rdx, rax
    call ctx_set
    lea rdi, [rip + rm_host]
    call strlen
    mov edi, CTX_REMOTE_HOST
    lea rsi, [rip + rm_host]
    mov rdx, rax
    call ctx_set
    call rm_connect
    mov eax, 1
    EPILOGUE
8:  lea rdi, [rip + .Lbad_spec]
    call app_toast
    xor eax, eax
    EPILOGUE

# rm_new_sid(): rm_sid, this window's session on the host (its programs outlive a dropped
#   connection); RHUN_REMOTE_SESSION=0 leaves it empty (they end with the connection, as before E5)
rm_new_sid:
    PROLOGUE 16
    mov byte ptr [rip + rm_sid], 0
    lea rdi, [rip + .Lenv_session]
    call getenv
    test rax, rax
    jz 1f
    cmp byte ptr [rax], '0'
    je 9f
1:  mov edi, 1                  # CLOCK_MONOTONIC
    lea rsi, [rsp]
    SYS SYS_clock_gettime
    SYS SYS_getpid
    mov rbx, 0xcbf29ce484222325
    mov r8, 0x100000001b3
    xor rbx, rax
    imul rbx, r8
    xor rbx, [rsp]
    imul rbx, r8
    xor rbx, [rsp + 8]
    imul rbx, r8
    call time_ms
    xor rbx, rax
    imul rbx, r8
    lea rdi, [rip + rm_sid]
    mov ecx, 60
2:  mov rax, rbx
    shr rax, cl
    and eax, 15
    lea rdx, [rip + hexdigits]
    mov al, [rdx + rax]
    mov [rdi], al
    inc rdi
    sub ecx, 4
    jns 2b
    mov byte ptr [rdi], 0
9:  EPILOGUE

# rm_push_exec(sb): `exec "$d/rhun" --remote-agent`, with --session SID when there is one
rm_push_exec:
    push rbx
    mov rbx, rdi
    lea rsi, [rip + .Lboot_exec]
    call sb_push_cstr
    cmp byte ptr [rip + rm_sid], 0
    je 9f
    mov rdi, rbx
    lea rsi, [rip + .Lopt_session]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + rm_sid]
    call sb_push_cstr
9:  pop rbx
    ret

# rm_parse_spec() -> 1 when rm_spec names a transport: rm_kind, rm_host, rm_port. Host and container
#   names are kept to letters, digits and ._@:- so no transport reads one as an option
rm_parse_spec:
    PROLOGUE
    lea rbx, [rip + rm_spec]
    lea r12, [rip + .Lspec_table]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 8f
    mov rdi, rsi
    call strlen
    mov r13, rax
    mov rdi, rbx
    mov rsi, [r12]
    mov rdx, r13
    call memeq
    test eax, eax
    jnz 2f
    add r12, 16
    jmp 1b
2:  mov eax, [r12 + 8]
    mov [rip + rm_kind], eax
    lea rsi, [rbx + r13]
    lea rdi, [rip + rm_host]
    xor ecx, ecx
3:  mov al, [rsi + rcx]
    test al, al
    jz 5f
    cmp ecx, 250
    jae 8f
    mov dl, al
    or dl, 0x20
    cmp dl, 'a'
    jb 31f
    cmp dl, 'z'
    jbe 4f
31: cmp al, '0'
    jb 32f
    cmp al, '9'
    jbe 4f
32: cmp al, '.'
    je 4f
    cmp al, '_'
    je 4f
    cmp al, '@'
    je 4f
    cmp al, ':'
    je 4f
    cmp al, '-'
    jne 8f
    test ecx, ecx
    jz 8f                       # never a leading dash
4:  mov [rdi + rcx], al
    inc ecx
    jmp 3b
5:  mov byte ptr [rdi + rcx], 0
    mov byte ptr [rip + rm_port], 0
    cmp dword ptr [rip + rm_kind], RT_LOCAL
    je 7f
    test ecx, ecx
    jz 8f
    cmp dword ptr [rip + rm_kind], RT_SSH
    jne 7f
    # ssh:HOST:PORT
    lea rdi, [rip + rm_host]
    mov rsi, rcx
    lea rdx, [rip + .Lcolon]
    mov ecx, 1
    call str_find
    test rax, rax
    js 7f
    lea rsi, [rip + rm_host]
    mov byte ptr [rsi + rax], 0
    lea rsi, [rsi + rax + 1]
    lea rdi, [rip + rm_port]
    mov ecx, 0
6:  mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz 7f
    sub al, '0'
    cmp al, 9
    ja 8f
    inc ecx
    cmp ecx, 6
    jb 6b
    jmp 8f
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# rm_connect(): start (or start again) the connection
rm_connect:
    PROLOGUE
    call rm_reset_stream
    mov byte ptr [rip + rm_error], 0
    mov byte ptr [rip + rm_errline], 0
    mov qword ptr [rip + rm_errlen], 0
    call rm_binary
    test eax, eax
    jz 9f                       # downloading first, or failed (rm_error)
    call rm_spawn_transport
    test eax, eax
    jz 9f
    mov dword ptr [rip + g_remote_state], RS_CONNECT
    lea rdi, [rip + .Lrlog_connect]
    lea rsi, [rip + rm_spec]
    call rm_log2
    call rm_send_check
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# rm_fail(reason cstr): the connection could not be made
rm_fail:
    push rbx
    mov rbx, rdi
    lea rdi, [rip + rm_error]
    mov rsi, rbx
    call cstr_copy
    mov dword ptr [rip + g_remote_state], RS_FAILED
    lea rdi, [rip + .Lrlog_failed]
    lea rsi, [rip + rm_error]
    call rm_log2
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# rm_reset_stream(): empty queues and counters for a new transport
rm_reset_stream:
    sub rsp, 8
    inc dword ptr [rip + rm_reset_gen]
    lea rdi, [rip + rm_rbuf]
    call sb_clear
    lea rdi, [rip + rm_wq]
    call sb_clear
    mov qword ptr [rip + rm_wq_off], 0
    mov dword ptr [rip + rm_wait_id], 0
    mov dword ptr [rip + rm_got], 0
    add rsp, 8
    ret

# rm_binary() -> 1 when rm_bin names the Linux binary to send, with rm_hash and rm_size. The setting
#   [remote] agent_binary first; a Linux rhun sends itself; macOS and Windows download the release
#   once (RS_DOWNLOAD, then rm_connect again).
rm_binary:
    PROLOGUE
    mov rsi, [rip + cfg_remote_agent_binary]
    cmp byte ptr [rsi], 0
    jne 1f
.ifdef MACOS
    jmp 5f
.endif
.ifdef WINDOWS
    jmp 5f
.endif
    lea rsi, [rip + .Lself_exe]
1:  lea rdi, [rip + rm_bin]
    call cstr_copy
2:  lea rdi, [rip + rm_bin]
    call fnv_file
    test rax, rax
    jz 7f
    mov [rip + rm_hash], rax
    lea rdi, [rip + rm_bin]
    call file_open_read
    test rax, rax
    js 7f
    mov ebx, eax
    mov edi, eax
    call file_size
    mov [rip + rm_size], rax
    mov edi, ebx
    SYS SYS_close
    mov eax, 1
    EPILOGUE
5:  # the downloaded release, or its download now
    call rm_download_path
    lea rdi, [rip + rm_bin]
    mov rsi, rax
    call cstr_copy
    lea rdi, [rip + rm_bin]
    call file_missing
    test eax, eax
    jz 2b
    call rm_download
    xor eax, eax
    EPILOGUE
7:  lea rdi, [rip + .Lno_binary]
    call rm_fail
    xor eax, eax
    EPILOGUE

# rm_spawn_transport() -> 1 when the transport runs, with its three pipes watched
rm_spawn_transport:
    PROLOGUE 64
    # argv
    lea rbx, [rip + rm_argv]
    mov eax, [rip + rm_kind]
    cmp eax, RT_SSH
    jne 1f
    lea rdi, [rip + .Lenv_ssh]
    call getenv
    test rax, rax
    jz 11f
    cmp byte ptr [rax], 0
    jne 12f
11: lea rax, [rip + .Lssh]
12: mov [rbx], rax
    lea rax, [rip + .Ldash_t]
    mov [rbx + 8], rax
    lea rax, [rip + .Ldash_o]
    mov [rbx + 16], rax
    lea rax, [rip + .Lalive]
    mov [rbx + 24], rax
    lea rax, [rip + .Ldash_o]
    mov [rbx + 32], rax
    lea rax, [rip + .Lalive_max]
    mov [rbx + 40], rax
    lea rax, [rip + .Ldash_e]
    mov [rbx + 48], rax
    lea rax, [rip + .Lnone]
    mov [rbx + 56], rax
    lea rax, [rip + .Ldash_o]
    mov [rbx + 64], rax
    lea rax, [rip + .Lconnect_timeout]
    mov [rbx + 72], rax
    mov ecx, 10
    cmp byte ptr [rip + rm_port], 0
    je 13f
    lea rax, [rip + .Ldash_p]
    mov [rbx + 80], rax
    lea rax, [rip + rm_port]
    mov [rbx + 88], rax
    mov ecx, 12
13:
    lea rax, [rip + .Ldashdash]
    mov [rbx + rcx*8], rax
    lea rax, [rip + rm_host]
    mov [rbx + rcx*8 + 8], rax
    lea rax, [rip + .Lsh_s]
    mov [rbx + rcx*8 + 16], rax
    mov qword ptr [rbx + rcx*8 + 24], 0
    jmp 5f
1:  cmp eax, RT_LOCAL
    jne 2f
    lea rax, [rip + .Lbin_sh]
.ifdef WINDOWS
    # tests only: a POSIX sh RHUN_REMOTE_SH names (Wine runs Linux's own as Z:/bin/sh)
    lea rdi, [rip + .Lenv_remote_sh]
    call getenv
    test rax, rax
    jnz 14f
    lea rax, [rip + .Lsh]
14:
.endif
    mov [rbx], rax
    lea rax, [rip + .Ldash_s]
    mov [rbx + 8], rax
    mov qword ptr [rbx + 16], 0
    jmp 5f
2:  cmp eax, RT_WSL
    jne 3f
    lea rax, [rip + .Lwsl]
    mov [rbx], rax
    lea rax, [rip + .Ldash_d]
    mov [rbx + 8], rax
    lea rax, [rip + rm_host]
    mov [rbx + 16], rax
    lea rax, [rip + .Lsh]
    mov [rbx + 24], rax
    lea rax, [rip + .Ldash_s]
    mov [rbx + 32], rax
    mov qword ptr [rbx + 40], 0
    jmp 5f
3:  # docker exec -i NAME sh -s (podman the same)
    lea rax, [rip + .Ldocker]
    cmp dword ptr [rip + rm_kind], RT_PODMAN
    jne 31f
    lea rax, [rip + .Lpodman]
31: mov [rbx], rax
    lea rax, [rip + .Lexec]
    mov [rbx + 8], rax
    lea rax, [rip + .Ldash_i]
    mov [rbx + 16], rax
    lea rax, [rip + rm_host]
    mov [rbx + 24], rax
    lea rax, [rip + .Lsh]
    mov [rbx + 32], rax
    lea rax, [rip + .Ldash_s]
    mov [rbx + 40], rax
    mov qword ptr [rbx + 48], 0
5:  # the program, from PATH or the places a Mac app does not have in its PATH
    mov rdi, [rbx]
    call rm_which
    test rax, rax
    jz .Lst_noprog
    mov [rsp + 56], rax
    mov [rbx], rax
    # three pipes: [rsp] its input, [rsp+8] its output, [rsp+16] its errors
    lea rdi, [rsp]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Lst_pipes
    lea rdi, [rsp + 8]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Lst_pipes1
    lea rdi, [rsp + 16]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Lst_pipes2
    call rm_transport_env
    mov rsi, rax
    lea rdi, [rip + rm_argv]
    xor edx, edx
    mov ecx, [rsp]
    mov r8d, [rsp + 12]
    mov r9d, [rsp + 20]
    push 2                      # no terminal: ssh asks through askpass, never on a tty
    push 2
    call proc_spawn
    add rsp, 16
    mov r12, rax
    mov edi, [rsp]
    SYS SYS_close
    mov edi, [rsp + 12]
    SYS SYS_close
    mov edi, [rsp + 20]
    SYS SYS_close
    mov rdi, [rsp + 56]
    call mem_free
    test r12, r12
    jle .Lst_spawn
    mov [rip + rm_tpid], r12d
    mov eax, [rsp + 4]
    mov [rip + rm_tin], eax
    mov eax, [rsp + 8]
    mov [rip + rm_tout], eax
    mov eax, [rsp + 16]
    mov [rip + rm_terr], eax
    mov edi, [rip + rm_tin]
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov edi, [rip + rm_tout]
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov edi, [rip + rm_terr]
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov edi, [rip + rm_tout]
    mov esi, POLLIN
    lea rdx, [rip + rm_on_out]
    xor ecx, ecx
    call watch_add
    mov edi, [rip + rm_terr]
    mov esi, POLLIN
    lea rdx, [rip + rm_on_err]
    xor ecx, ecx
    call watch_add
    mov edi, [rip + rm_tin]
    xor esi, esi
    lea rdx, [rip + rm_on_in]
    xor ecx, ecx
    call watch_add
    mov dword ptr [rip + rm_watching_in], 0
    mov eax, 1
    EPILOGUE
.Lst_pipes2:
    mov edi, [rsp + 8]
    SYS SYS_close
    mov edi, [rsp + 12]
    SYS SYS_close
.Lst_pipes1:
    mov edi, [rsp]
    SYS SYS_close
    mov edi, [rsp + 4]
    SYS SYS_close
.Lst_pipes:
    mov rdi, [rsp + 56]
    call mem_free
.Lst_spawn:
    lea rdi, [rip + .Lno_transport]
    call rm_fail
    xor eax, eax
    EPILOGUE
.Lst_noprog:
    lea rdi, [rip + .Lno_program]
    call rm_fail
    xor eax, eax
    EPILOGUE

# rm_which(name) -> path (mem_free it) or 0: PATH, then /usr/local/bin and /opt/homebrew/bin
FN remote_which
rm_which:
    PROLOGUE
    mov rbx, rdi
    call proc_which
    test rax, rax
    jnz 9f
    lea r12, [rip + .Lextra_dirs]
1:  mov rdi, [r12]
    test rdi, rdi
    jz 8f
    mov rsi, rbx
    call path_join
    mov r13, rax
    mov rdi, rax
    mov esi, 1                  # X_OK
    SYS SYS_access
    test rax, rax
    jz 2f
    mov rdi, r13
    call mem_free
    add r12, 8
    jmp 1b
2:  mov rax, r13
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# rm_transport_env() -> envp for the transport: ours, with ssh asking for passwords and host keys
#   through `rhun --ssh-askpass` (remoteui.s), which shows the question in this window
rm_transport_env:
    sub rsp, 8
    mov rdi, [rip + rm_tenv]
    call mem_free
    lea rdi, [rip + .Lno_extras]
    cmp dword ptr [rip + rm_kind], RT_SSH
    jne 1f
    call remote_askpass_env
    mov rdi, rax
1:
    call env_make
    mov [rip + rm_tenv], rax
    add rsp, 8
    ret

# rm_send_check(): the bootstrap's first question: is the binary in the host's cache?
rm_send_check:
    PROLOGUE
    lea rdi, [rip + rm_line]
    call sb_clear
    lea rdi, [rip + rm_line]
    lea rsi, [rip + .Lboot_d]
    call sb_push_cstr
    lea rdi, [rip + rm_line]
    lea rsi, [rip + rhun_version]
    call sb_push_cstr
    lea rdi, [rip + rm_line]
    mov esi, '-'
    call sb_push_byte
    mov rsi, [rip + rm_hash]
    call rm_push_hex
    cmp dword ptr [rip + rm_force], 0
    je 1f
    lea rdi, [rip + rm_line]
    lea rsi, [rip + .Lboot_force]
    call sb_push_cstr
1:  lea rdi, [rip + rm_line]
    lea rsi, [rip + .Lboot_check]
    call sb_push_cstr
    mov rsi, [rip + rm_line + SB_ptr]
    mov rdx, [rip + rm_line + SB_len]
    call rm_send
    EPILOGUE

# rm_push_hex(rsi value): 16 hex digits onto rm_line
rm_push_hex:
    push rbx
    sub rsp, 32
    mov rbx, rsi
    mov ecx, 15
1:  mov eax, ebx
    and eax, 15
    lea rdx, [rip + .Lhex]
    mov al, [rdx + rax]
    mov [rsp + rcx], al
    shr rbx, 4
    dec ecx
    jns 1b
    lea rdi, [rip + rm_line]
    mov rsi, rsp
    mov edx, 16
    call sb_push
    add rsp, 32
    pop rbx
    ret

# rm_boot_line(ptr, len): a line the bootstrap printed (before the agent's hello)
rm_boot_line:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [rip + g_remote_state]
    cmp eax, RS_START
    je .Lbl_hello
    # "@rhun WORD ...": anything else is the host's chatter (a profile that prints)
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lat_rhun]
    mov ecx, 6
    call str_starts
    test eax, eax
    jz .Lbl_chatter
    lea r13, [rbx + 6]
    lea r14, [r12 - 6]
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lw_have]
    mov ecx, 4
    call str_starts
    test eax, eax
    jnz .Lbl_have
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lw_need]
    mov ecx, 4
    call str_starts
    test eax, eax
    jnz .Lbl_need
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lw_go]
    mov ecx, 2
    call str_starts
    test eax, eax
    jnz .Lbl_go
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lw_unsupported]
    mov ecx, 11
    call str_starts
    test eax, eax
    jnz .Lbl_unsupported
    # "@rhun error TEXT"
    lea rdi, [rip + rm_error]
    lea rsi, [rip + .Lboot_failed]
    call cstr_copy
    mov rdi, rax
    lea rsi, [r13 + 6]
    lea rdx, [r14 - 6]
    test rdx, rdx
    jle 2f
    cmp rdx, 300
    jb 1f
    mov edx, 300
1:  push rdi
    push rdx
    call memcpy
    pop rdx
    pop rdi
    add rdi, rdx
2:  mov byte ptr [rdi], 0
    jmp .Lbl_fail_set
.Lbl_unsupported:
    lea rdi, [rip + rm_error]
    lea rsi, [rip + .Lunsupported]
    call cstr_copy
    mov rdi, rax
    lea rsi, [r13 + 12]
    lea rdx, [r14 - 12]
    test rdx, rdx
    jle 3f
    cmp rdx, 200
    jb 4f
    mov edx, 200
4:  call memcpy
    mov byte ptr [rax + rdx], 0
3:
.Lbl_fail_set:
    mov dword ptr [rip + g_remote_state], RS_FAILED
    lea rdi, [rip + .Lrlog_failed]
    lea rsi, [rip + rm_error]
    call rm_log2
    call rm_kill_transport
    jmp 9f
.Lbl_have:
    lea rdi, [rip + rm_line]
    call sb_clear
    lea rdi, [rip + rm_line]
    call rm_push_exec
    lea rdi, [rip + rm_line]
    mov esi, 10
    call sb_push_byte
    mov rsi, [rip + rm_line + SB_ptr]
    mov rdx, [rip + rm_line + SB_len]
    call rm_send
    mov dword ptr [rip + g_remote_state], RS_START
    jmp 9f
.Lbl_need:
    # the binary goes after the shell said it reads it
    lea rdi, [rip + rm_line]
    call sb_clear
    lea rdi, [rip + rm_line]
    lea rsi, [rip + .Lboot_up1]
    call sb_push_cstr
    lea rdi, [rip + rm_line]
    mov rsi, [rip + rm_size]
    call sb_push_u64
    lea rdi, [rip + rm_line]
    lea rsi, [rip + .Lboot_up2]
    call sb_push_cstr
    lea rdi, [rip + rm_line]
    call rm_push_exec
    lea rdi, [rip + rm_line]
    lea rsi, [rip + .Lboot_up3]
    call sb_push_cstr
    mov rsi, [rip + rm_line + SB_ptr]
    mov rdx, [rip + rm_line + SB_len]
    call rm_send
    mov dword ptr [rip + g_remote_state], RS_UPWAIT
    lea rdi, [rip + .Lrlog_upload]
    lea rsi, [rip + rm_bin]
    call rm_log2
    jmp 9f
.Lbl_go:
    cmp dword ptr [rip + g_remote_state], RS_UPWAIT
    jne 9f
    lea rdi, [rip + rm_bin]
    call file_read_all
    test rax, rax
    jz .Lbl_readfail
    mov r13, rax
    mov r14, rdx
    mov rax, [rip + rm_wq + SB_len]
    mov [rip + rm_up_start], rax
    mov [rip + rm_up_total], r14
    mov rsi, r13
    mov rdx, r14
    call rm_send
    mov rdi, r13
    call mem_free
    mov dword ptr [rip + g_remote_state], RS_UPLOAD
    jmp 9f
.Lbl_readfail:
    lea rdi, [rip + .Lno_binary]
    call rm_fail
    call rm_kill_transport
    jmp 9f
.Lbl_hello:
    # hello rhun-remote VERSION HASH
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lw_hello]
    mov ecx, 18
    call str_starts
    test eax, eax
    jz .Lbl_chatter
    # the hash is the last 16 characters
    cmp r12, 34
    jb .Lbl_chatter
    lea rdi, [rbx + r12 - 16]
    mov esi, 16
    call parse_hex
    cmp rax, [rip + rm_hash]
    jne .Lbl_mismatch
    mov dword ptr [rip + rm_force], 0
    mov dword ptr [rip + g_remote_state], RS_UP
    mov dword ptr [rip + rm_need_open], 1
    lea rdi, [rip + .Lrlog_up]
    lea rsi, [rip + rm_host]
    call rm_log2
    jmp 9f
.Lbl_mismatch:
    # a damaged cache: once more with a fresh copy
    cmp dword ptr [rip + rm_force], 0
    jne 5f
    mov dword ptr [rip + rm_force], 1
    lea rdi, [rip + .Lrlog_mismatch]
    lea rsi, [rip + rm_host]
    call rm_log2
    call rm_kill_transport
    call rm_connect
    jmp 9f
5:  lea rdi, [rip + .Lmismatch]
    call rm_fail
    call rm_kill_transport
    jmp 9f
.Lbl_chatter:
    lea rdi, [rip + .Lrlog_said]
    call rm_log_cstr
    mov rdi, rbx
    mov rsi, r12
    call rm_log_bytes
9:  EPILOGUE

# rm_kill_transport(): the transport ends now (its pipes close; rm_lost runs only for a live one)
rm_kill_transport:
    PROLOGUE
    mov edi, [rip + rm_tpid]
    test edi, edi
    jle 1f
    neg edi
    mov esi, SIGTERM
    SYS SYS_kill
    mov edi, [rip + rm_tpid]
    mov esi, SIGTERM
    SYS SYS_kill
    mov edi, [rip + rm_tpid]
    call reap_later
    mov dword ptr [rip + rm_tpid], 0
1:  lea rbx, [rip + rm_tin]
    xor r12d, r12d
2:  mov edi, [rbx + r12*4]
    test edi, edi
    js 3f
    call watch_remove
    mov edi, [rbx + r12*4]
    SYS SYS_close
    mov dword ptr [rbx + r12*4], -1
3:  inc r12d
    cmp r12d, 3
    jb 2b
    EPILOGUE

# rm_lost(): the transport ended while connected: programs end, requests fail, a bar offers
#   Reconnect (remoteui.s)
rm_lost:
    PROLOGUE
    mov eax, [rip + g_remote_state]
    cmp eax, RS_UP
    je 1f
    cmp eax, RS_FAILED
    je 8f
    # it ended while connecting: why, from what it printed
    lea rdi, [rip + rm_error]
    lea rsi, [rip + .Lcould_not]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + rm_host]
    call cstr_copy
    cmp byte ptr [rip + rm_errline], 0
    je 2f
    mov rdi, rax
    lea rsi, [rip + .Lcolon_sp]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + rm_errline]
    call cstr_copy
2:  mov dword ptr [rip + g_remote_state], RS_FAILED
    lea rdi, [rip + .Lrlog_failed]
    lea rsi, [rip + rm_error]
    call rm_log2
    jmp 8f
1:  mov dword ptr [rip + g_remote_state], RS_LOST
    lea rdi, [rip + rm_error]
    lea rsi, [rip + .Llost]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + rm_host]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Llost2]
    call cstr_copy
    lea rdi, [rip + .Lrlog_lost]
    lea rsi, [rip + rm_host]
    call rm_log2
8:  call rm_kill_transport
    # every program ends: its readers see the end, proc_wait an exit. With a session on the host
    # (and not Disconnect) programs keep running there: their channels wait for remote_attach
    lea rbx, [rip + rm_ch]
    xor r12d, r12d
3:  cmp dword ptr [rbx + CH_kind], 0
    je 4f
    test dword ptr [rbx + CH_flags], CHF_EXITED
    jnz 31f
    cmp byte ptr [rip + rm_sid], 0
    je 32f
    cmp dword ptr [rip + rm_ending], 0
    jne 32f
    cmp dword ptr [rbx + CH_kind], CK_STREAM
    je 32f
    or dword ptr [rbx + CH_flags], CHF_DETACHED
    mov rdi, rbx
    call rm_events
    jmp 4f
32:
    or dword ptr [rbx + CH_flags], CHF_EXITED
    mov dword ptr [rbx + CH_status], 129     # as SIGHUP
    call time_ms
    mov [rbx + CH_exited_at], rax
31: or dword ptr [rbx + CH_flags], CHF_REOF
    mov rdi, rbx
    call rm_deliver
4:  add rbx, CH_SIZE
    inc r12d
    cmp r12d, MUX_MAXCH
    jb 3b
    call vfs_remote_lost
    call agent_conn_remote_lost # the chat's programs there end with it (agent_conn.s)
    call rm_rq_fail_all
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# remote_reconnect(): Reconnect on the bar, or the control command
FN remote_reconnect
    sub rsp, 8
    cmp dword ptr [rip + g_remote], 0
    je 1f
    mov eax, [rip + g_remote_state]
    cmp eax, RS_LOST
    je 2f
    cmp eax, RS_FAILED
    jne 1f
2:  call rm_connect
1:  add rsp, 8
    ret

# remote_disconnect(): Disconnect: the agent quits and the window stays, as if the connection was lost
FN remote_disconnect
    sub rsp, 8
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne 1f
    mov dword ptr [rip + rm_ending], 1  # the loss the wait may see is this one: programs end
    call rm_quit_call
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne 2f                      # the transport ended while it waited: handled as this ending
    call rm_lost
2:  mov dword ptr [rip + rm_ending], 0
1:  add rsp, 8
    ret

# remote_quit(): the window closes: its session on the host ends with it (programs and all)
FN remote_quit
    sub rsp, 8
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne 1f
    call rm_quit_call
1:  add rsp, 8
    ret

# rm_quit_call(): quit, answered: the agent has the request (and ends its session) before the
#   transport is killed; one that does not answer within remote_call's wait is killed all the same
rm_quit_call:
    sub rsp, 8
    lea rdi, [rip + .Lv_quit]
    mov esi, 4
    xor edx, edx
    xor ecx, ecx
    call remote_call
    add rsp, 8
    ret

# remote_sock_open(fd, port) -> 0 or -errno: a local TCP connection (remotefwd.s accepted it) becomes
#   a channel to PORT on the host's loopback; the channel owns fd from now on, also on failure
# remote_sock_connect(fd, port, cb, ctx) -> as remote_sock_open, and cb(ctx, 0 | 1) says whether the
#   host made the connection (0) or was refused (1; fd is closed then). The debugger's tcp adapters
#   in a remote window (dapwire.s) [debugger group]
FN remote_sock_open
    xor edx, edx
    xor ecx, ecx
FN remote_sock_connect
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r15, rdx
    mov [rsp], rcx
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne 7f
    call rm_alloc_chan
    test eax, eax
    js 6f
    mov r14d, eax
    mov rbx, rdx
    mov [rbx + CH_cb], r15
    mov rax, [rsp]
    mov [rbx + CH_cbctx], rax
    mov dword ptr [rbx + CH_kind], CK_PROC
    mov [rbx + CH_fd], r12d
    mov dword ptr [rbx + CH_pid], 0
    mov dword ptr [rbx + CH_flags], CHF_PENDING | CHF_COLLECTED   # nobody waits for its exit
    # connect CH PORT
    lea rdi, [rip + rm_kill_line]
    call sb_clear
    lea rdi, [rip + rm_kill_line]
    lea rsi, [rip + .Lv_connect]
    call sb_push_cstr
    lea rdi, [rip + rm_kill_line]
    mov esi, r14d
    call sb_push_u64
    lea rdi, [rip + rm_kill_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rm_kill_line]
    mov esi, r13d
    call sb_push_u64
    mov rdi, [rip + rm_kill_line + SB_ptr]
    mov rsi, [rip + rm_kill_line + SB_len]
    xor edx, edx
    xor ecx, ecx
    lea r8, [rip + rm_on_connected]
    mov r9, rbx
    call remote_request_cb
    test eax, eax
    jz 5f
    mov edi, r12d
    xor esi, esi
    lea rdx, [rip + rm_on_chan]
    mov rcx, rbx
    call watch_add
    mov dword ptr [rbx + CH_events], 0
    xor eax, eax
    EPILOGUE
5:  mov dword ptr [rbx + CH_kind], 0     # never asked for: forgotten at once
    mov dword ptr [rbx + CH_fd], -1
    mov qword ptr [rbx + CH_cb], 0
6:  mov rax, -24
    jmp 8f
7:  mov rax, -107
8:  mov rbx, rax
    mov edi, r12d
    SYS SYS_close
    mov rax, rbx
    EPILOGUE

# rm_on_connected(CH*, status, ptr, len): the host made the connection (it flows), or could not (the
#   local one closes)
rm_on_connected:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + CH_kind], CK_PROC
    jne 9f
    test dword ptr [rbx + CH_flags], CHF_PENDING
    jz 9f
    and dword ptr [rbx + CH_flags], ~CHF_PENDING
    test rsi, rsi
    js 1f
    mov rdi, rbx
    call rm_events
    xor esi, esi
    jmp 8f
1:  # refused: as if the host's side had ended at once
    or dword ptr [rbx + CH_flags], CHF_EXITED | CHF_REOF | CHF_LCLOSED
    mov dword ptr [rbx + CH_status], 1
    call time_ms
    mov [rbx + CH_exited_at], rax
    mov edi, [rbx + CH_fd]
    test edi, edi
    js 7f
    call watch_remove
    mov edi, [rbx + CH_fd]
    SYS SYS_close
    mov dword ptr [rbx + CH_fd], -1
7:  mov esi, 1
8:  # remote_sock_connect's caller hears how it went [debugger group]
    mov rax, [rbx + CH_cb]
    test rax, rax
    jz 9f
    mov qword ptr [rbx + CH_cb], 0
    mov rdi, [rbx + CH_cbctx]
    call rax
9:  EPILOGUE

# rm_send_close(ch): close CH, the agent forgets the channel
rm_send_close:
    push rbx
    mov ebx, edi
    lea rdi, [rip + rm_kill_line]
    call sb_clear
    lea rdi, [rip + rm_kill_line]
    lea rsi, [rip + .Lv_close]
    call sb_push_cstr
    lea rdi, [rip + rm_kill_line]
    mov esi, ebx
    call sb_push_u64
    mov rdi, [rip + rm_kill_line + SB_ptr]
    call rm_request_async
    pop rbx
    ret

# remote_attach(): connected again: the host's session says which detached channels still have a
#   program (exited or not, its output ended or not); the others end as when the connection went.
#   Both sides start the credits again (what was on the way when it went is lost).
FN remote_attach
    PROLOGUE
    lea rbx, [rip + rm_ch]
    xor r12d, r12d
1:  test dword ptr [rbx + CH_flags], CHF_DETACHED
    jnz 2f
    add rbx, CH_SIZE
    inc r12d
    cmp r12d, MUX_MAXCH
    jb 1b
    jmp 9f                      # nothing waits
2:  lea rdi, [rip + .Lv_attach]
    mov esi, 6
    xor edx, edx
    xor ecx, ecx
    call remote_call
    test rax, rax
    js 6f
    lea rdi, [rip + .Lrlog_attach]
    call rm_log_cstr
    mov rdi, [rip + g_remote_reply + SB_ptr]
    mov rsi, [rip + g_remote_reply + SB_len]
    call rm_log_bytes
    mov r13, [rip + g_remote_reply + SB_ptr]
    mov r14, [rip + g_remote_reply + SB_len]
3:  # CH MODE FLAGS STATUS
    test r14, r14
    jle 6f
    mov rdi, r13
    mov rsi, r14
    call parse_u64
    test rdx, rdx
    jz 6f
    mov r15, rax                # channel
    lea r13, [r13 + rdx]
    sub r14, rdx
    call .Lat_skip_word         # past " MODE"
    call .Lat_number            # FLAGS
    mov r12, rax
    call .Lat_number            # STATUS
    push rax
    push rax
    xor eax, eax
    test r14, r14
    jle 44f
    cmp byte ptr [r13], ' '
    jne 44f
    call .Lat_number            # CFAIL: its child could not confine itself (ragent.s)
44: mov r9, rax
    pop r8
    pop r8
    mov rax, r12
    # the rest of the line
4:  test r14, r14
    jle 41f
    movzx edx, byte ptr [r13]
    inc r13
    dec r14
    cmp edx, 10
    jne 4b
41: cmp r15, MUX_MAXCH
    jae 3b
    mov rdi, r15
    imul rdi, rdi, CH_SIZE
    lea rbx, [rip + rm_ch]
    add rbx, rdi
    test dword ptr [rbx + CH_flags], CHF_DETACHED
    jnz 43f
    mov edi, r15d               # not this window's any more: the session forgets it
    call rm_send_close
    jmp 3b
43: or dword ptr [rbx + CH_flags], CHF_SEEN
    mov qword ptr [rbx + CH_credit], MUX_WINDOW
    mov qword ptr [rbx + CH_grant], 0
    mov [rbx + CH_cfail], r9d
    test eax, 1
    jz 42f
    or dword ptr [rbx + CH_flags], CHF_EXITED
    mov [rbx + CH_status], r8d
    push rax
    push rax
    call time_ms
    mov [rbx + CH_exited_at], rax
    pop rax
    pop rax
42: test r12d, 2
    jz 3b
    or dword ptr [rbx + CH_flags], CHF_REOF
    jmp 3b
6:  # the ones the session does not have end now; all of them are watched again
    lea rbx, [rip + rm_ch]
    xor r12d, r12d
7:  mov eax, [rbx + CH_flags]
    test eax, CHF_DETACHED
    jz 8f
    test eax, CHF_SEEN
    jnz 71f
    test eax, CHF_EXITED
    jnz 72f
    or dword ptr [rbx + CH_flags], CHF_EXITED
    mov dword ptr [rbx + CH_status], 129     # as SIGHUP
    call time_ms
    mov [rbx + CH_exited_at], rax
72: or dword ptr [rbx + CH_flags], CHF_REOF
    jmp 73f
71: test eax, CHF_LCLOSED
    jz 73f
    test eax, CHF_EXITED
    jnz 73f
    mov edi, r12d               # its tab closed meanwhile: the program's input ends now
    call rm_send_eof
73: and dword ptr [rbx + CH_flags], ~(CHF_DETACHED | CHF_SEEN)
    mov rdi, rbx
    call rm_events
    mov rdi, rbx
    call rm_deliver
8:  add rbx, CH_SIZE
    inc r12d
    cmp r12d, MUX_MAXCH
    jb 7b
    lea rdi, [rip + .Lrlog_attached]
    lea rsi, [rip + rm_sid]
    call rm_log2
9:  EPILOGUE
# remote_attach's reader of the reply (r13 position, r14 bytes left): .Lat_skip_word skips a space
#   and a word, .Lat_number reads a space and a number into rax
.Lat_skip_word:
    test r14, r14
    jle 2f
    cmp byte ptr [r13], ' '
    jne 1f
    inc r13
    dec r14
1:  test r14, r14
    jle 2f
    movzx eax, byte ptr [r13]
    cmp eax, ' '
    je 2f
    cmp eax, 10
    je 2f
    inc r13
    dec r14
    jmp 1b
2:  ret
.Lat_number:
    test r14, r14
    jle 1f
    cmp byte ptr [r13], ' '
    jne 1f
    inc r13
    dec r14
1:  mov rdi, r13
    mov rsi, r14
    sub rsp, 8
    call parse_u64
    add rsp, 8
    add r13, rdx
    sub r14, rdx
    ret

# remote_drop(): the transport is killed (tests: a dropped connection)
FN remote_drop
    sub rsp, 8
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne 1f
    call rm_lost
1:  add rsp, 8
    ret

# ---------------- the pump ----------------

# rm_send(ptr, len): onto the queue to the host; the loop writes it
rm_send:
    push rbx
    mov rbx, rdx
    lea rdi, [rip + rm_wq]
    call sb_push
    add [rip + rm_out_bytes], rbx
    call rm_want_in
    pop rbx
    ret

rm_send_cstr:
    push rbx
    mov rbx, rdi
    call strlen
    mov rdx, rax
    mov rsi, rbx
    call rm_send
    pop rbx
    ret

# rm_want_in(): POLLOUT on the transport's input while there is something to write
rm_want_in:
    push rbx
    mov rax, [rip + rm_wq + SB_len]
    cmp rax, [rip + rm_wq_off]
    setne bl
    movzx ebx, bl
    cmp ebx, [rip + rm_watching_in]
    je 1f
    mov [rip + rm_watching_in], ebx
    mov edi, [rip + rm_tin]
    test edi, edi
    js 1f
    xor esi, esi
    test ebx, ebx
    jz 2f
    mov esi, POLLOUT
2:  call watch_set_events
1:  pop rbx
    ret

# rm_on_in(fd, revents, ctx): room in the transport's input
rm_on_in:
    sub rsp, 8
    call rm_flush
    add rsp, 8
    ret

# rm_flush(): write as much as the transport takes
rm_flush:
    PROLOGUE
    mov r12, [rip + rm_wq + SB_len]
    sub r12, [rip + rm_wq_off]
    cmp r12, MUX_WQ_HIGH
    setae r13b
1:  mov rdx, [rip + rm_wq + SB_len]
    mov rsi, [rip + rm_wq_off]
    sub rdx, rsi
    jz 5f
    add rsi, [rip + rm_wq + SB_ptr]
    mov edi, [rip + rm_tin]
    test edi, edi
    js 5f
    SYS SYS_write
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 6f
    test rax, rax
    jle 7f
    add [rip + rm_wq_off], rax
    jmp 1b
5:  mov qword ptr [rip + rm_wq_off], 0
    mov qword ptr [rip + rm_wq + SB_len], 0
    cmp dword ptr [rip + g_remote_state], RS_UPLOAD
    jne 6f
    mov dword ptr [rip + g_remote_state], RS_START
    mov qword ptr [rip + rm_up_total], 0
6:  # keep it compact
    mov rax, [rip + rm_wq_off]
    cmp rax, 4194304
    jb 61f
    mov rdi, [rip + rm_wq + SB_ptr]
    lea rsi, [rdi + rax]
    mov rdx, [rip + rm_wq + SB_len]
    sub rdx, rax
    mov [rip + rm_wq + SB_len], rdx
    sub [rip + rm_up_start], rax
    mov qword ptr [rip + rm_wq_off], 0
    call memmove
61: call rm_want_in
    # the queue fell below its limit: the channels read again
    test r13b, r13b
    jz 9f
    mov rax, [rip + rm_wq + SB_len]
    sub rax, [rip + rm_wq_off]
    cmp rax, MUX_WQ_HIGH
    jae 9f
    call rm_all_events
    jmp 9f
7:  call rm_lost
9:  cmp dword ptr [rip + g_remote_state], RS_UPLOAD
    jne 91f
    mov dword ptr [rip + g_dirty], 1       # the progress
91: EPILOGUE

# rm_flush_now(): write the whole queue, waiting for the transport (Disconnect, a request)
rm_flush_now:
    PROLOGUE 16
    call time_ms
    lea r12, [rax + MUX_RPC_MS]
1:  mov rax, [rip + rm_wq + SB_len]
    cmp rax, [rip + rm_wq_off]
    je 9f
    cmp dword ptr [rip + rm_tin], 0
    jl 9f
    call rm_flush
    mov rax, [rip + rm_wq + SB_len]
    cmp rax, [rip + rm_wq_off]
    je 9f
    call time_ms
    cmp rax, r12
    jae 9f
    mov eax, [rip + rm_tin]
    mov [rsp], eax
    mov word ptr [rsp + 4], POLLOUT
    mov word ptr [rsp + 6], 0
    lea rdi, [rsp]
    mov esi, 1
    mov edx, 100
    SYS SYS_poll
    jmp 1b
9:  EPILOGUE

# rm_on_err(fd, revents, ctx): what the transport prints on its errors goes to the log; its last
#   line explains a failed connection
rm_on_err:
    PROLOGUE 4096
1:  mov edi, [rip + rm_terr]
    test edi, edi
    js 9f
    lea rsi, [rsp]
    mov edx, 4096
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    test rax, rax
    jle 5f
    mov rbx, rax
    lea rdi, [rsp]
    mov rsi, rbx
    call rm_log_raw
    # the last non-empty line, for the bar
    xor ecx, ecx
2:  cmp rcx, rbx
    jae 1b
    movzx eax, byte ptr [rsp + rcx]
    cmp al, 10
    je 3f
    cmp al, 13
    je 3f
    mov rdx, [rip + rm_errlen]
    cmp rdx, RLOG_MAX
    jae 4f
    lea rdi, [rip + rm_errline]
    mov [rdi + rdx], al
    mov byte ptr [rdi + rdx + 1], 0
    inc qword ptr [rip + rm_errlen]
    jmp 4f
3:  mov qword ptr [rip + rm_errlen], 0       # the next line replaces it, once it has text
    jmp 41f
4:
41: inc rcx
    jmp 2b
5:  cmp rax, -EAGAIN
    je 9f
    # its error output ended: no more watching it (the output's end tells the loss)
    mov edi, [rip + rm_terr]
    call watch_remove
    mov edi, [rip + rm_terr]
    SYS SYS_close
    mov dword ptr [rip + rm_terr], -1
9:  EPILOGUE

# rm_on_out(fd, revents, ctx): the stream from the host
rm_on_out:
    PROLOGUE
    mov r12d, 64                # at most 16 MB at once, then let the window draw
1:  mov edi, [rip + rm_tout]
    test edi, edi
    js 9f
    lea rdi, [rip + rm_rbuf]
    mov esi, 262144
    call sb_reserve
    mov rsi, rax
    mov edi, [rip + rm_tout]
    mov edx, 262144
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 2f
    test rax, rax
    jle 8f
    add [rip + rm_rbuf + SB_len], rax
    add [rip + rm_in_bytes], rax
    call rm_parse
    dec r12d
    jnz 1b
2:  call rm_parse
    jmp 9f
8:  call rm_parse
    call rm_lost
9:  EPILOGUE

# rm_parse(): handle every complete line or message in rm_rbuf
rm_parse:
    PROLOGUE 16
    mov eax, [rip + rm_reset_gen]
    mov [rsp], eax
    xor r12d, r12d              # offset
1:  mov rdi, [rip + rm_rbuf + SB_ptr]
    add rdi, r12
    mov rsi, [rip + rm_rbuf + SB_len]
    sub rsi, r12
    jz 6f
    mov r13, rdi
    mov r14, rsi
    call mux_line
    test rax, rax
    jz 6f
    js .Lrp_bad
    mov r15, rax
    cmp dword ptr [rip + g_remote_state], RS_UP
    je 2f
    # the bootstrap's lines
    add r12, r15
    mov rdi, r13
    lea rsi, [r15 - 1]
    call rm_boot_line
    mov eax, [rip + rm_reset_gen]
    cmp eax, [rsp]
    jne 9f                      # it connected again: the buffer is a new transport's
    jmp 1b
2:  mov rdi, r13
    lea rsi, [r15 - 1]
    lea rdx, [rip + rm_toks]
    call mux_split
    mov [rip + rm_ntok], rax
    test rax, rax
    jz 5f
    call rm_body_len
    test rax, rax
    js .Lrp_bad
    lea rcx, [r15 + rax]
    cmp rcx, r14
    ja 6f                       # its body is still coming
    mov rbx, rcx
    lea rdi, [r13 + r15]
    mov rsi, rax
    call rm_message
    add r12, rbx
    jmp 1b
5:  add r12, r15
    jmp 1b
6:  test r12, r12
    jz 9f
    mov rdi, [rip + rm_rbuf + SB_ptr]
    lea rsi, [rdi + r12]
    mov rdx, [rip + rm_rbuf + SB_len]
    sub rdx, r12
    mov [rip + rm_rbuf + SB_len], rdx
    call memmove
    jmp 9f
.Lrp_bad:
    lea rdi, [rip + .Lrlog_bad]
    lea rsi, [rip + rm_host]
    call rm_log2
    lea rdi, [rip + rm_rbuf]
    call sb_clear
    call rm_lost
9:  EPILOGUE

# rm_body_len() -> bytes after the line: d CH LEN, ok ID LEN, v WD MASK LEN; 0 for the others
rm_body_len:
    push rbx
    xor edi, edi
    call rm_tok
    mov rbx, rax
    cmp rdx, 1
    jne 3f
    cmp byte ptr [rbx], 'd'
    jne 1f
    mov edi, 2
    jmp 5f
1:  cmp byte ptr [rbx], 'v'
    jne 4f
    mov edi, 3
    jmp 5f
3:  cmp rdx, 2
    jne 4f
    cmp word ptr [rbx], 0x6b6f           # "ok"
    jne 4f
    mov edi, 2
5:  cmp rdi, [rip + rm_ntok]
    jae 8f
    call rm_num
    pop rbx
    ret
4:  xor eax, eax
    pop rbx
    ret
8:  mov rax, -1
    pop rbx
    ret

# rm_chan(ch) -> rax CH* (ch below MUX_MAXCH)
rm_chan:
    mov eax, edi
    imul rax, rax, CH_SIZE
    lea rcx, [rip + rm_ch]
    add rax, rcx
    ret

# rm_message(body, len): one message from the agent, its line in rm_toks
rm_message:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor edi, edi
    call rm_tok
    mov rbx, rax
    cmp rdx, 2
    je .Lrm_ok
    cmp rdx, 5
    je .Lrm_error
    cmp rdx, 1
    jne 9f
    movzx ebx, byte ptr [rbx]
    cmp ebx, 'v'
    je .Lrm_watch
    mov edi, 1
    call rm_num
    cmp rax, MUX_MAXCH
    jae 9f
    mov edi, eax
    call rm_chan
    mov r14, rax
    cmp dword ptr [r14 + CH_kind], 0
    je .Lrm_stale
    cmp ebx, 'd'
    je .Lrm_data
    cmp ebx, 'e'
    je .Lrm_eof
    cmp ebx, 'w'
    je .Lrm_credit
    cmp ebx, 'x'
    je .Lrm_exit
    jmp 9f
.Lrm_data:
    test dword ptr [r14 + CH_flags], CHF_LCLOSED
    jnz .Lrm_drop
    lea rdi, [r14 + CH_buf]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, r14
    call rm_deliver
    jmp 9f
.Lrm_drop:
    # nobody reads it here any more: its credit goes back at once
    mov edi, 1
    call rm_num
    mov edi, eax
    mov rsi, r13
    call rm_send_credit
    jmp 9f
.Lrm_eof:
    or dword ptr [r14 + CH_flags], CHF_REOF
    mov rdi, r14
    call rm_deliver
    jmp 9f
.Lrm_credit:
    mov edi, 2
    call rm_num
    add [r14 + CH_credit], rax
    mov rdi, r14
    call rm_events
    jmp 9f
.Lrm_exit:
    mov edi, 2
    call rm_num
    mov [r14 + CH_status], eax
    mov dword ptr [r14 + CH_cfail], 0
    cmp qword ptr [rip + rm_ntok], 4
    jb 1f
    mov edi, 3                  # x CH STATUS CODE: its child could not confine itself (ragent.s)
    call rm_num
    mov [r14 + CH_cfail], eax
1:  or dword ptr [r14 + CH_flags], CHF_EXITED
    call time_ms
    mov [r14 + CH_exited_at], rax
    jmp 9f
.Lrm_stale:
    # data for a channel forgotten here: credit it so the agent's side drains
    cmp ebx, 'd'
    jne 9f
    jmp .Lrm_drop
.Lrm_watch:
    mov edi, 1
    call rm_num
    mov r14, rax
    mov edi, 2
    call rm_num
    mov rdi, r14
    mov rsi, rax
    mov rdx, r12
    mov rcx, r13
    call vfs_remote_event
    jmp 9f
.Lrm_ok:
    cmp word ptr [rbx], 0x6b6f
    jne 9f
    mov edi, 1
    call rm_num
    mov edi, eax
    xor esi, esi
    mov rdx, r12
    mov rcx, r13
    call rm_rq_answer
    test eax, eax
    jnz 9f
    mov edi, 1
    call rm_num
    cmp eax, [rip + rm_wait_id]
    jne 9f
    test eax, eax
    jz 9f
    lea rdi, [rip + g_remote_reply]
    call sb_clear
    lea rdi, [rip + g_remote_reply]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov dword ptr [rip + rm_got_err], 0
    mov dword ptr [rip + rm_got], 1
    jmp 9f
.Lrm_error:
    mov rdi, rbx
    mov esi, 5
    lea rdx, [rip + .Lw_error]
    mov ecx, 5
    call str_eq
    test eax, eax
    jz 9f
    mov edi, 2
    call rm_num
    test eax, eax
    jnz 2f
    mov eax, 5
2:  mov r14, rax
    mov edi, 1
    call rm_num
    mov edi, eax
    mov rsi, r14
    neg rsi
    xor edx, edx
    xor ecx, ecx
    call rm_rq_answer
    test eax, eax
    jnz 9f
    mov edi, 1
    call rm_num
    cmp eax, [rip + rm_wait_id]
    jne 9f
    test eax, eax
    jz 9f
    mov eax, r14d
1:  mov [rip + rm_got_err], eax
    mov dword ptr [rip + rm_got], 1
9:  EPILOGUE

# rm_send_credit(ch, n): w CH N
rm_send_credit:
    test rsi, rsi
    jz 9f
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    lea rdi, [rip + rm_line]
    call sb_clear
    lea rdi, [rip + rm_line]
    lea rsi, [rip + .Lw_sp]
    call sb_push_cstr
    lea rdi, [rip + rm_line]
    mov esi, ebx
    call sb_push_u64
    lea rdi, [rip + rm_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rm_line]
    mov rsi, r12
    call sb_push_u64
    lea rdi, [rip + rm_line]
    mov esi, 10
    call sb_push_byte
    mov rsi, [rip + rm_line + SB_ptr]
    mov rdx, [rip + rm_line + SB_len]
    call rm_send
    pop r13
    pop r12
    pop rbx
9:  ret

# rm_chan_index(CH*) -> eax channel number
rm_chan_index:
    mov rax, rdi
    lea rcx, [rip + rm_ch]
    sub rax, rcx
    xor edx, edx
    mov ecx, CH_SIZE
    div rcx
    ret

# rm_deliver(CH*): the buffered bytes into the channel's descriptor; credit back what was taken;
#   the end once all is delivered
rm_deliver:
    PROLOGUE
    mov rbx, rdi
    call rm_chan_index
    mov r15d, eax
    mov eax, [rbx + CH_kind]
    cmp eax, CK_STREAM
    je .Lrd_stream
1:  mov rdx, [rbx + CH_buf + SB_len]
    mov rsi, [rbx + CH_off]
    sub rdx, rsi
    jz 4f
    mov edi, [rbx + CH_fd]
    test edi, edi
    js .Lrd_nofd
    add rsi, [rbx + CH_buf + SB_ptr]
    cmp dword ptr [rbx + CH_kind], CK_SINK
    je 2f
    SYS SYS_write
    jmp 3f
2:  call write_all              # a log: written whole
    test rax, rax
    js .Lrd_nofd
    mov rax, [rbx + CH_buf + SB_len]
    sub rax, [rbx + CH_off]
3:  cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 5f
    test rax, rax
    jle .Lrd_nofd
    add [rbx + CH_off], rax
    add [rbx + CH_grant], rax
    jmp 1b
.Lrd_nofd:
    # the reader is gone: drop the rest, its credit goes back
    mov rax, [rbx + CH_buf + SB_len]
    sub rax, [rbx + CH_off]
    add [rbx + CH_grant], rax
4:  mov qword ptr [rbx + CH_off], 0
    mov qword ptr [rbx + CH_buf + SB_len], 0
    # all delivered: the end follows
    test dword ptr [rbx + CH_flags], CHF_REOF
    jz 5f
    test dword ptr [rbx + CH_flags], CHF_SHUT
    jnz 5f
    or dword ptr [rbx + CH_flags], CHF_SHUT
    mov edi, [rbx + CH_fd]
    test edi, edi
    js 5f
    cmp dword ptr [rbx + CH_kind], CK_PROC
    jne 5f
    mov esi, 1                  # SHUT_WR: the local reader reads its end
    SYS SYS_shutdown
5:  # credit back
    mov rax, [rbx + CH_grant]
    test rax, rax
    jz 6f
    cmp rax, MUX_GRANT
    jae 51f
    mov rcx, [rbx + CH_buf + SB_len]
    cmp rcx, [rbx + CH_off]
    jne 6f
51: mov edi, r15d
    mov rsi, [rbx + CH_grant]
    call rm_send_credit
    mov qword ptr [rbx + CH_grant], 0
6:  mov rdi, rbx
    call rm_events
    EPILOGUE
.Lrd_stream:
    # the caller takes the bytes (remote_stream_take); the end is the flag
    EPILOGUE

# rm_events(CH*): what the loop watches the channel's descriptor for: POLLIN while the agent gives
#   credit and the queue has room, POLLOUT while bytes wait to be delivered
rm_events:
    cmp dword ptr [rdi + CH_kind], CK_PROC
    jne 9f
    cmp dword ptr [rdi + CH_fd], 0
    jl 9f
    xor esi, esi
    test dword ptr [rdi + CH_flags], CHF_LCLOSED
    jnz 2f
    test dword ptr [rdi + CH_flags], CHF_DETACHED | CHF_PENDING
    jnz 1f                      # what it writes waits in the socket until remote_attach
    cmp qword ptr [rdi + CH_credit], 0
    jle 1f
    mov rax, [rip + rm_wq + SB_len]
    sub rax, [rip + rm_wq_off]
    cmp rax, MUX_WQ_HIGH
    jae 1f
    or esi, POLLIN
1:  mov rax, [rdi + CH_buf + SB_len]
    cmp rax, [rdi + CH_off]
    je 2f
    or esi, POLLOUT
2:  cmp esi, [rdi + CH_events]
    je 9f
    mov [rdi + CH_events], esi
    mov edi, [rdi + CH_fd]
    jmp watch_set_events
9:  ret

# rm_all_events(): every channel's events again (the queue drained)
rm_all_events:
    push rbx
    push r12
    sub rsp, 8
    lea rbx, [rip + rm_ch]
    xor r12d, r12d
1:  mov rdi, rbx
    call rm_events
    add rbx, CH_SIZE
    inc r12d
    cmp r12d, MUX_MAXCH
    jb 1b
    add rsp, 8
    pop r12
    pop rbx
    ret

# rm_on_chan(fd, revents, CH*): the local side of a remote program wrote, closed, or has room
rm_on_chan:
    PROLOGUE
    mov rbx, rdx
    mov r12d, esi
    mov rdi, rbx
    call rm_chan_index
    mov r15d, eax
    test r12d, POLLOUT
    jz 1f
    mov rdi, rbx
    call rm_deliver
1:  test r12d, POLLIN | POLLHUP | POLLERR
    jz 9f
    test dword ptr [rbx + CH_flags], CHF_LCLOSED
    jnz 9f
    mov r13, [rbx + CH_credit]
    cmp r13, MUX_READ
    jbe 2f
    mov r13d, MUX_READ
2:  test r13, r13
    jg 21f
    # no credit: it waits, unless the local side hung up (poll reports that whatever it is asked,
    # and its last unread input is dropped rather than spinning on it)
    test r12d, POLLHUP | POLLERR
    jnz .Lrc_closed
    jmp 9f
21: lea rdi, [rip + rm_wq]
    lea rsi, [r13 + 32]
    call sb_reserve
    lea r14, [rax + 32]
3:  mov edi, [rbx + CH_fd]
    mov rsi, r14
    mov rdx, r13
    SYS SYS_read
    cmp rax, -EINTR
    je 3b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle .Lrc_closed
    mov r13, rax
    sub [rbx + CH_credit], rax
    lea rdi, [rip + rm_line]
    call sb_clear
    lea rdi, [rip + rm_line]
    lea rsi, [rip + .Ld_sp]
    call sb_push_cstr
    lea rdi, [rip + rm_line]
    mov esi, r15d
    call sb_push_u64
    lea rdi, [rip + rm_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rm_line]
    mov rsi, r13
    call sb_push_u64
    lea rdi, [rip + rm_line]
    mov esi, 10
    call sb_push_byte
    # header, then the data moved next to it (the reserve above keeps r14 valid)
    mov rdi, [rip + rm_wq + SB_ptr]
    add rdi, [rip + rm_wq + SB_len]
    mov rsi, [rip + rm_line + SB_ptr]
    mov rdx, [rip + rm_line + SB_len]
    call memcpy
    mov rax, [rip + rm_line + SB_len]
    add [rip + rm_wq + SB_len], rax
    mov rdi, [rip + rm_wq + SB_ptr]
    add rdi, [rip + rm_wq + SB_len]
    mov rsi, r14
    mov rdx, r13
    call memmove
    add [rip + rm_wq + SB_len], r13
    mov rax, [rip + rm_line + SB_len]
    add rax, r13
    add [rip + rm_out_bytes], rax
    call rm_want_in
    mov rdi, rbx
    call rm_events
    jmp 9f
.Lrc_closed:
    # the local side closed it: the program's input ends (a terminal hangs up)
    or dword ptr [rbx + CH_flags], CHF_LCLOSED
    mov edi, [rbx + CH_fd]
    call watch_remove
    mov edi, [rbx + CH_fd]
    SYS SYS_close
    mov dword ptr [rbx + CH_fd], -1
    mov dword ptr [rbx + CH_lfd], -1
    # what it never read is credited back
    mov rax, [rbx + CH_buf + SB_len]
    sub rax, [rbx + CH_off]
    add rax, [rbx + CH_grant]
    mov qword ptr [rbx + CH_grant], 0
    mov qword ptr [rbx + CH_off], 0
    mov qword ptr [rbx + CH_buf + SB_len], 0
    mov edi, r15d
    mov rsi, rax
    call rm_send_credit
    mov edi, r15d
    call rm_send_eof
9:  EPILOGUE

# rm_send_eof(ch): e CH
rm_send_eof:
    push rbx
    mov ebx, edi
    lea rdi, [rip + rm_line]
    call sb_clear
    lea rdi, [rip + rm_line]
    lea rsi, [rip + .Le_sp]
    call sb_push_cstr
    lea rdi, [rip + rm_line]
    mov esi, ebx
    call sb_push_u64
    lea rdi, [rip + rm_line]
    mov esi, 10
    call sb_push_byte
    mov rsi, [rip + rm_line + SB_ptr]
    mov rdx, [rip + rm_line + SB_len]
    call rm_send
    pop rbx
    ret

# ---------------- requests ----------------

# remote_call(line ptr, len, body ptr, body len) -> 0, or -errno (-ENOTCONN when not connected,
#   -ETIMEDOUT when the host went quiet). line is "VERB ARG..." without the id and the length; the
#   answer's bytes are in g_remote_reply. Other channels keep flowing meanwhile; watch events wait.
FN remote_call
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne .Lrc_notconn
    inc dword ptr [rip + rm_next_id]
    cmp dword ptr [rip + rm_next_id], 0x7fffffff
    jb 1f
    mov dword ptr [rip + rm_next_id], 1
1:  mov ebx, [rip + rm_next_id]
    lea rdi, [rip + rm_line]
    call sb_clear
    lea rdi, [rip + rm_line]
    mov esi, ebx
    call sb_push_u64
    lea rdi, [rip + rm_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rm_line]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + rm_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rm_line]
    mov rsi, r15
    call sb_push_u64
    lea rdi, [rip + rm_line]
    mov esi, 10
    call sb_push_byte
    mov rsi, [rip + rm_line + SB_ptr]
    mov rdx, [rip + rm_line + SB_len]
    call rm_send
    test r15, r15
    jz 2f
    mov rsi, r14
    mov rdx, r15
    call rm_send
2:  mov [rip + rm_wait_id], ebx
    mov dword ptr [rip + rm_got], 0
    call time_ms
    mov [rsp], rax              # sent at
    mov rdi, rax
    call rm_wait_answer
    mov dword ptr [rip + rm_wait_id], 0
    test eax, eax
    jz .Lrc_timeout
    call time_ms
    sub rax, [rsp]
    mov [rip + rm_rtt], rax
    mov eax, [rip + rm_got_err]
    neg rax
    EPILOGUE
.Lrc_timeout:
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne .Lrc_notconn
    mov rax, -110               # ETIMEDOUT
    EPILOGUE
.Lrc_notconn:
    lea rdi, [rip + g_remote_reply]
    call sb_clear
    mov rax, -107               # ENOTCONN
    EPILOGUE

# rm_wait_answer(start) -> 1 once rm_got, 0 when the connection went or stayed quiet MUX_RPC_MS
rm_wait_answer:
    PROLOGUE 16
    mov r12, rdi
    mov r13, [rip + rm_in_bytes]
1:  cmp dword ptr [rip + rm_got], 0
    jne 8f
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne 9f
    # quiet for too long?
    call time_ms
    cmp r13, [rip + rm_in_bytes]
    je 2f
    mov r13, [rip + rm_in_bytes]
    mov r12, rax
2:  mov rcx, rax
    sub rcx, r12
    cmp rcx, MUX_RPC_MS
    jae 9f
    mov edi, 100
    call rm_pump_once
    jmp 1b
8:  mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# rm_pump_once(timeout ms): wait for the transport and serve it, nothing else
rm_pump_once:
    PROLOGUE 16
    mov r12d, edi
    mov eax, [rip + rm_tout]
    test eax, eax
    js 9f
    mov [rsp], eax
    mov word ptr [rsp + 4], POLLIN
    mov word ptr [rsp + 6], 0
    mov eax, [rip + rm_tin]
    mov [rsp + 8], eax
    xor eax, eax
    mov rcx, [rip + rm_wq + SB_len]
    cmp rcx, [rip + rm_wq_off]
    je 1f
    mov eax, POLLOUT
1:  mov [rsp + 12], ax
    mov word ptr [rsp + 14], 0
    lea rdi, [rsp]
    mov esi, 2
    movsxd rdx, r12d
    SYS SYS_poll
    test rax, rax
    jle 9f
    test word ptr [rsp + 14], POLLOUT | POLLERR | POLLHUP
    jz 2f
    call rm_flush
2:  test word ptr [rsp + 6], POLLIN | POLLERR | POLLHUP
    jz 9f
    call rm_on_out
9:  EPILOGUE

# rm_request_async(line cstr): a request nobody waits for (id 0; its answer is dropped)
FN remote_request_async
rm_request_async:
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne 9f
    push rbx
    mov rbx, rdi
    lea rdi, [rip + rm_line]
    call sb_clear
    lea rdi, [rip + rm_line]
    lea rsi, [rip + .Lzero_sp]
    call sb_push_cstr
    lea rdi, [rip + rm_line]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + rm_line]
    lea rsi, [rip + .Lsp_zero_nl]
    call sb_push_cstr
    mov rsi, [rip + rm_line + SB_ptr]
    mov rdx, [rip + rm_line + SB_len]
    call rm_send
    pop rbx
9:  ret

# remote_request_cb(line ptr, len, body ptr, body len, cb, ctx) -> id, or 0 when not connected or
#   too many wait: a request whose answer comes later: remote_tick calls cb(ctx, status, ptr, len)
#   (status 0 or -errno; the bytes are valid during the call). Typing never waits for the host.
FN remote_request_cb
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov [rsp], r8
    mov [rsp + 8], r9
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne 8f
    lea rbx, [rip + rm_rq]
    xor ecx, ecx
1:  cmp dword ptr [rbx + RQ_id], 0
    je 2f
    add rbx, RQ_SIZE
    inc ecx
    cmp ecx, RQ_MAX
    jb 1b
    jmp 8f
2:  inc dword ptr [rip + rm_next_id]
    cmp dword ptr [rip + rm_next_id], 0x7fffffff
    jb 3f
    mov dword ptr [rip + rm_next_id], 1
3:  mov eax, [rip + rm_next_id]
    mov [rbx + RQ_id], eax
    mov dword ptr [rbx + RQ_done], 0
    mov rax, [rsp]
    mov [rbx + RQ_cb], rax
    mov rax, [rsp + 8]
    mov [rbx + RQ_ctx], rax
    lea rdi, [rip + rm_line]
    call sb_clear
    lea rdi, [rip + rm_line]
    mov esi, [rbx + RQ_id]
    call sb_push_u64
    lea rdi, [rip + rm_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rm_line]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + rm_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rm_line]
    mov rsi, r15
    call sb_push_u64
    lea rdi, [rip + rm_line]
    mov esi, 10
    call sb_push_byte
    mov rsi, [rip + rm_line + SB_ptr]
    mov rdx, [rip + rm_line + SB_len]
    call rm_send
    test r15, r15
    jz 4f
    mov rsi, r14
    mov rdx, r15
    call rm_send
4:  mov eax, [rbx + RQ_id]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# rm_rq_answer(id, status, ptr, len) -> eax 1 when id was a remote_request_cb's: its answer is kept
rm_rq_answer:
    PROLOGUE
    test edi, edi
    jz 8f
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    lea rbx, [rip + rm_rq]
    xor ecx, ecx
1:  cmp [rbx + RQ_id], edi
    je 2f
    add rbx, RQ_SIZE
    inc ecx
    cmp ecx, RQ_MAX
    jb 1b
8:  xor eax, eax
    EPILOGUE
2:  cmp dword ptr [rbx + RQ_done], 0
    jne 8f
    mov [rbx + RQ_status], r12
    lea rdi, [rbx + RQ_reply]
    call sb_clear
    test r14, r14
    jz 3f
    lea rdi, [rbx + RQ_reply]
    mov rsi, r13
    mov rdx, r14
    call sb_push
3:  mov dword ptr [rbx + RQ_done], 1
    mov dword ptr [rip + rm_rq_ready], 1
    mov eax, 1
    EPILOGUE

# rm_rq_dispatch(): the answers that came go to their callbacks (remote_tick: nothing is being parsed)
rm_rq_dispatch:
    PROLOGUE
    cmp dword ptr [rip + rm_rq_ready], 0
    je 9f
    mov dword ptr [rip + rm_rq_ready], 0
    lea rbx, [rip + rm_rq]
    xor r12d, r12d
1:  cmp dword ptr [rbx + RQ_id], 0
    je 2f
    cmp dword ptr [rbx + RQ_done], 0
    je 2f
    mov dword ptr [rbx + RQ_id], 0          # free before the call: it may ask again
    mov rdi, [rbx + RQ_ctx]
    mov rsi, [rbx + RQ_status]
    mov rdx, [rbx + RQ_reply + SB_ptr]
    mov rcx, [rbx + RQ_reply + SB_len]
    call [rbx + RQ_cb]
    lea rdi, [rbx + RQ_reply]
    call sb_clear
2:  add rbx, RQ_SIZE
    inc r12d
    cmp r12d, RQ_MAX
    jb 1b
9:  EPILOGUE

# rm_rq_fail_all(): the connection went: the waiting requests are answered ENOTCONN
rm_rq_fail_all:
    PROLOGUE
    lea rbx, [rip + rm_rq]
    xor r12d, r12d
1:  cmp dword ptr [rbx + RQ_id], 0
    je 2f
    cmp dword ptr [rbx + RQ_done], 0
    jne 2f
    mov qword ptr [rbx + RQ_status], -107
    lea rdi, [rbx + RQ_reply]
    call sb_clear
    mov dword ptr [rbx + RQ_done], 1
    mov dword ptr [rip + rm_rq_ready], 1
2:  add rbx, RQ_SIZE
    inc r12d
    cmp r12d, RQ_MAX
    jb 1b
    EPILOGUE

# ---------------- programs ----------------

# rm_alloc_chan() -> eax channel (1..), its CH* in rdx, or -1 when all are taken
rm_alloc_chan:
    lea rdx, [rip + rm_ch + CH_SIZE]
    mov eax, 1
1:  cmp dword ptr [rdx + CH_kind], 0
    je 2f
    add rdx, CH_SIZE
    inc eax
    cmp eax, MUX_MAXCH
    jb 1b
    mov eax, -1
    ret
2:  inc dword ptr [rip + rm_gen]
    mov ecx, [rip + rm_gen]
    and ecx, 0x7ffff
    jnz 3f
    mov ecx, 1
    mov [rip + rm_gen], ecx
3:  mov [rdx + CH_gen], ecx
    mov dword ptr [rdx + CH_flags], 0
    mov dword ptr [rdx + CH_status], 0
    mov dword ptr [rdx + CH_fd], -1
    mov dword ptr [rdx + CH_lfd], -1
    mov dword ptr [rdx + CH_events], 0
    mov dword ptr [rdx + CH_errch], 0
    mov qword ptr [rdx + CH_credit], MUX_WINDOW
    mov qword ptr [rdx + CH_grant], 0
    mov qword ptr [rdx + CH_off], 0
    mov qword ptr [rdx + CH_buf + SB_len], 0
    mov qword ptr [rdx + CH_cb], 0
    ret

# rm_free_chan(CH*): forgotten here (its descriptor already closed or never opened)
rm_free_chan:
    push rbx
    mov rbx, rdi
    mov edi, [rbx + CH_fd]
    test edi, edi
    js 1f
    cmp dword ptr [rbx + CH_kind], CK_PROC
    jne 2f
    call watch_remove
    mov edi, [rbx + CH_fd]
2:  cmp dword ptr [rbx + CH_kind], CK_SINK
    je 3f
    cmp dword ptr [rbx + CH_kind], CK_PROC
    jne 1f
3:  SYS SYS_close
1:  lea rdi, [rbx + CH_buf]
    call sb_free
    mov dword ptr [rbx + CH_kind], 0
    mov dword ptr [rbx + CH_fd], -1
    pop rbx
    ret

# remote_spawn(argv, envp, cwd, flags, errfd, input ptr, input len) -> rax pid (tagged) or -errno,
#   edx the local descriptor (nonblocking, both ways). flags: bit 0 a pty, bits 8-23 its columns and
#   bits 24-.. its rows; bit 1 keeps argv[0] as given (else its last part, found in the host's PATH).
#   errfd: -1 error output to /dev/null, -2 merged with the output, -3 a socketpair of its own whose
#   end comes back in ecx, else a descriptor that receives it (a log; kept open by the channel until
#   the program ends). Only envp's entries that are not the
#   window's own environment go along: the host has its login environment (flags bit 2: an
#   extension: exactly envp's entries and the host's PATH, nothing filtered; bit 3 with it: held on
#   the host by Landlock as remote_confine_blk says, the answer in g_remote_confined and
#   g_remote_confine_why). input (pipes): bytes for the program's input (any length), which then ends.
FN remote_spawn
    PROLOGUE 80
    mov [rsp], rdi              # argv
    mov [rsp + 8], rsi          # envp
    mov [rsp + 16], rdx         # cwd
    mov [rsp + 24], ecx         # flags
    mov [rsp + 28], r8d         # errfd
    mov [rsp + 32], r9          # input
    mov rax, [rbp + 16]
    mov [rsp + 40], rax         # input length
    mov dword ptr [rsp + 48], 0 # error channel
    mov dword ptr [rsp + 56], -1
    mov dword ptr [rsp + 60], -1
    mov dword ptr [rsp + 64], -1   # the error socketpair (errfd -3)
    mov dword ptr [rsp + 68], -1
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne .Lrs_notconn
    call rm_alloc_chan
    test eax, eax
    js .Lrs_full
    mov r12d, eax               # channel
    mov r13, rdx                # CH*
    mov dword ptr [r13 + CH_kind], CK_PROC
    # its error output on a channel of its own
    mov eax, [rsp + 28]
    cmp eax, -3
    je .Lrs_errpair
    test eax, eax
    js 1f
    call rm_alloc_chan
    test eax, eax
    js .Lrs_full_free
    mov [rsp + 48], eax
    mov dword ptr [rdx + CH_kind], CK_SINK
    mov rbx, rdx
    mov edi, [rsp + 28]
    xor esi, esi                # F_DUPFD: the channel keeps its own copy
    mov edx, 3
    SYS SYS_fcntl
    mov [rbx + CH_fd], eax
    test eax, eax
    js 1f
    mov edi, eax
    mov esi, 2                  # F_SETFD FD_CLOEXEC
    mov edx, 1
    SYS SYS_fcntl
    jmp 1f
.Lrs_errpair:
    call rm_alloc_chan
    test eax, eax
    js .Lrs_full_free
    mov [rsp + 48], eax
    mov [r13 + CH_errch], eax
    mov dword ptr [rdx + CH_kind], CK_PROC
    mov dword ptr [rdx + CH_flags], CHF_ERRCH
    mov rbx, rdx
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK
    xor edx, edx
    lea r10, [rsp + 64]
    SYS SYS_socketpair
    test rax, rax
    js .Lrs_fail_free
    mov eax, [rsp + 64]
    mov [rbx + CH_fd], eax
    mov eax, [rsp + 68]
    mov [rbx + CH_lfd], eax
1:  # the socketpair: [rsp+56] ours, [rsp+60] the caller's
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK
    xor edx, edx
    lea r10, [rsp + 56]
    SYS SYS_socketpair
    test rax, rax
    js .Lrs_fail_free
    mov eax, [rsp + 56]
    mov [r13 + CH_fd], eax
    mov eax, [rsp + 60]
    mov [r13 + CH_lfd], eax
    # the request: spawn CH MODE ERRCH COLS ROWS LEN
    lea rbx, [rip + rm_spawn_body]
    mov rdi, rbx
    call sb_clear
    mov rsi, [rsp + 16]
    test rsi, rsi
    jz 2f
    mov rdi, rbx
    call sb_push_cstr
2:  mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    # argv: the first by its last part unless kept
    mov r14, [rsp]
    mov rsi, [r14]
    test rsi, rsi
    jz 4f
    cmp byte ptr [rsi], 0
    je 31f
    test dword ptr [rsp + 24], 2
    jnz 3f
    mov rdi, rsi
    call strlen
    mov rdi, [r14]
    mov rsi, rax
    call path_basename
    mov rsi, rax
3:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
31: add r14, 8
32: mov rsi, [r14]
    test rsi, rsi
    jz 4f
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    add r14, 8
    jmp 32b
4:  mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    # the environment entries that are the caller's own
    mov r14, [rsp + 8]
    test r14, r14
    jz 6f
5:  mov rsi, [r14]
    test rsi, rsi
    jz 6f
    test dword ptr [rsp + 24], 4
    jnz 52f                     # an extension's list is sent whole
    call rm_env_inherited
    test eax, eax
    jnz 51f
52:
    mov rsi, [r14]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
51: add r14, 8
    jmp 5b
6:  test dword ptr [rsp + 24], 8
    jz 61f
    # an extension held on the host (remoteext.s): an empty entry ends the environment, then
    # NEEDS DIR SCRIPT STATE PROJECT RUNS
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [rip + remote_confine_blk]
    mov rdx, [rip + remote_confine_len]
    call sb_push
61: mov r15, [rbx + SB_ptr]
    mov r14, [rbx + SB_len]
    lea rdi, [rip + rm_spawn_line]
    call sb_clear
    lea rdi, [rip + rm_spawn_line]
    lea rsi, [rip + .Lv_spawn]
    call sb_push_cstr
    lea rdi, [rip + rm_spawn_line]
    mov esi, r12d
    call sb_push_u64
    lea rdi, [rip + rm_spawn_line]
    mov esi, ' '
    call sb_push_byte
    mov esi, [rsp + 24]
    and esi, 1
    test dword ptr [rsp + 24], 4
    jz 69f
    mov esi, 2                  # an extension's: its environment exactly (remoteext.s)
    test dword ptr [rsp + 24], 8
    jz 69f
    mov esi, 3                  # and held there by Landlock
69: lea rdi, [rip + rm_spawn_line]
    call sb_push_u64
    lea rdi, [rip + rm_spawn_line]
    mov esi, ' '
    call sb_push_byte
    # ERRCH: 0 /dev/null, CH merged, or the sink's channel
    xor esi, esi
    cmp dword ptr [rsp + 28], -2
    jne 7f
    mov esi, r12d
7:  cmp dword ptr [rsp + 48], 0
    je 71f
    mov esi, [rsp + 48]
71: lea rdi, [rip + rm_spawn_line]
    call sb_push_u64
    lea rdi, [rip + rm_spawn_line]
    mov esi, ' '
    call sb_push_byte
    mov esi, [rsp + 24]
    shr esi, 8
    and esi, 0xffff
    lea rdi, [rip + rm_spawn_line]
    call sb_push_u64
    lea rdi, [rip + rm_spawn_line]
    mov esi, ' '
    call sb_push_byte
    mov esi, [rsp + 24]
    shr esi, 24
    lea rdi, [rip + rm_spawn_line]
    call sb_push_u64
    mov rdi, [rip + rm_spawn_line + SB_ptr]
    mov rsi, [rip + rm_spawn_line + SB_len]
    mov rdx, r15
    mov rcx, r14
    call remote_call
    mov rbx, rax
    test rbx, rbx
    js .Lrs_refused
    mov rdi, [rip + g_remote_reply + SB_ptr]
    mov rsi, [rip + g_remote_reply + SB_len]
    call parse_u64
    mov [r13 + CH_pid], eax
    mov dword ptr [rip + g_remote_confined], -1
    mov byte ptr [rip + g_remote_confine_why], 0
    test dword ptr [rsp + 24], 8
    jz 79f
    call rm_confine_reply
79: # the input, then its end
    # (all of it at once: the agent keeps what the program has not read; the credit comes back
    # as it reads)
    mov rdx, [rsp + 40]
    test rdx, rdx
    jz 8f
    sub [r13 + CH_credit], rdx
    mov qword ptr [rsp + 72], 0 # sent: in frames the agent takes (MUX_FRAME each)
78: mov rax, [rsp + 40]
    sub rax, [rsp + 72]
    jz 79f
    cmp rax, MUX_FRAME
    jbe 77f
    mov eax, MUX_FRAME
77: mov rbx, rax
    lea rdi, [rip + rm_line]
    call sb_clear
    lea rdi, [rip + rm_line]
    lea rsi, [rip + .Ld_sp]
    call sb_push_cstr
    lea rdi, [rip + rm_line]
    mov esi, r12d
    call sb_push_u64
    lea rdi, [rip + rm_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rm_line]
    mov rsi, rbx
    call sb_push_u64
    lea rdi, [rip + rm_line]
    mov esi, 10
    call sb_push_byte
    mov rsi, [rip + rm_line + SB_ptr]
    mov rdx, [rip + rm_line + SB_len]
    call rm_send
    mov rsi, [rsp + 32]
    add rsi, [rsp + 72]
    mov rdx, rbx
    call rm_send
    add [rsp + 72], rbx
    jmp 78b
79: mov edi, r12d
    call rm_send_eof
8:  # the loop watches our end (bytes may have come during the request: rm_events sees them)
    mov edi, [r13 + CH_fd]
    xor esi, esi
    lea rdx, [rip + rm_on_chan]
    mov rcx, r13
    call watch_add
    mov dword ptr [r13 + CH_events], 0
    mov rdi, r13
    call rm_events
    cmp dword ptr [rsp + 64], 0
    jl 81f
    mov edi, [rsp + 48]
    call rm_chan
    mov rbx, rax
    mov edi, [rbx + CH_fd]
    xor esi, esi
    lea rdx, [rip + rm_on_chan]
    mov rcx, rbx
    call watch_add
    mov rdi, rbx
    call rm_events
81:
    # the tagged pid: the tag, the generation, the channel
    mov eax, [r13 + CH_gen]
    shl eax, 10
    or eax, r12d
    or eax, REMOTE_PID_TAG
    mov edx, [r13 + CH_lfd]
    mov ecx, [rsp + 68]
    EPILOGUE
.Lrs_refused:
    mov edi, [rsp + 60]
    SYS SYS_close
    mov dword ptr [r13 + CH_lfd], -1
    mov rax, rbx
    jmp .Lrs_free
.Lrs_fail_free:
    mov rbx, rax
.Lrs_free:
    mov [rsp + 56], rax
    mov edi, [rsp + 68]         # the caller's end of an error socketpair
    test edi, edi
    js 83f
    SYS SYS_close
83: mov rdi, r13
    call rm_free_chan
    mov edi, [rsp + 48]
    test edi, edi
    jz 9f
    call rm_chan
    mov rdi, rax
    call rm_free_chan
9:  mov rax, [rsp + 56]
    EPILOGUE
.Lrs_full_free:
    mov rdi, r13
    call rm_free_chan
.Lrs_full:
    mov rax, -24                # EMFILE
    EPILOGUE
.Lrs_notconn:
    mov rax, -107
    EPILOGUE

# rm_env_inherited(rsi entry) -> 1 when the entry is the window's own environment's: rhun's own, the
#   login environment uproc made (uproc_env_owned), or RHUN_EXE= (this machine's rhun)
rm_env_inherited:
    push rsi
    mov rdi, rsi
    call uproc_env_owned
    pop rsi
    test eax, eax
    jnz 9f
    cmp dword ptr [rsi], 0x4e554852            # "RHUN"
    jne 2f
    cmp dword ptr [rsi + 4], 0x4558455f        # "_EXE"
    jne 2f
    cmp byte ptr [rsi + 8], '='
    je 9f
2:  mov rcx, [rip + g_envp]
1:  mov rax, [rcx]
    test rax, rax
    jz 8f
    cmp rax, rsi
    je 9f
    add rcx, 8
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# rm_pid_chan(pid) -> rax CH* of a live tagged pid, 0 when it names none (any more)
rm_pid_chan:
    mov eax, edi
    test eax, eax
    jns 1f
    neg eax
1:  test eax, REMOTE_PID_TAG
    jz 8f
    mov ecx, eax
    and ecx, MUX_MAXCH - 1
    shr eax, 10
    and eax, 0x7ffff
    push rax
    mov edi, ecx
    call rm_chan
    pop rcx
    cmp dword ptr [rax + CH_kind], CK_PROC
    jne 8f
    cmp [rax + CH_gen], ecx
    jne 8f
    ret
8:  xor eax, eax
    ret

# remote_pid_host(tagged pid) -> eax the program's pid on the host, 0 when it names none (any more): what a
#   record on the host names it by (agent_holder.s)
FN remote_pid_host
    call rm_pid_chan
    test rax, rax
    jz 9f
    mov eax, [rax + CH_pid]
    ret
9:  xor eax, eax
    ret

# rm_confine_reply(): "PID LEVEL REASON" (spawn MODE 3) into g_remote_confined and
#   g_remote_confine_why
rm_confine_reply:
    mov rsi, [rip + g_remote_reply + SB_ptr]
    mov rcx, [rip + g_remote_reply + SB_len]
    xor edx, edx
1:  cmp rdx, rcx
    jae 9f
    cmp byte ptr [rsi + rdx], ' '
    je 2f
    inc rdx
    jmp 1b
2:  inc rdx
    cmp rdx, rcx
    jae 9f
    movzx eax, byte ptr [rsi + rdx]
    sub eax, '0'
    cmp eax, 9
    ja 9f
    mov [rip + g_remote_confined], eax
    add rdx, 2
    lea rdi, [rip + g_remote_confine_why]
    xor r8d, r8d
3:  cmp rdx, rcx
    jae 4f
    cmp r8d, 300
    jae 4f
    mov al, [rsi + rdx]
    mov [rdi + r8], al
    inc rdx
    inc r8d
    jmp 3b
4:  mov byte ptr [rdi + r8], 0
9:  ret

# remote_confine_code(pid) -> eax the EXITC_* code the host's confined child failed with (read once),
#   or 0 (remoteext.s: "not confined: REASON" as for a local extension)
FN remote_confine_code
    call rm_pid_chan
    test rax, rax
    jz 9f
    mov ecx, [rax + CH_cfail]
    mov dword ptr [rax + CH_cfail], 0
    mov eax, ecx
    ret
9:  xor eax, eax
    ret

# remote_wait(pid, nohang) -> as proc_wait for a tagged pid: the status, -1 still running, -2 unknown
FN remote_wait
    PROLOGUE
    mov r12d, esi
    call rm_pid_chan
    test rax, rax
    jz 8f
    mov rbx, rax
    test r12d, r12d
    jnz 2f
    # blocking: serve the stream until the exit comes (git's jobs wait so after the output's end)
    call time_ms
    lea r13, [rax + MUX_RPC_MS]
1:  test dword ptr [rbx + CH_flags], CHF_EXITED
    jnz 2f
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne 2f
    call time_ms
    cmp rax, r13
    jae 7f
    mov edi, 100
    call rm_pump_once
    jmp 1b
2:  test dword ptr [rbx + CH_flags], CHF_EXITED
    jz 7f
    or dword ptr [rbx + CH_flags], CHF_COLLECTED
    mov eax, [rbx + CH_status]
    EPILOGUE
7:  mov eax, -1
    EPILOGUE
8:  mov eax, -2
    EPILOGUE

# remote_kill(pid, sig) -> 0: kill CH SIG GROUP for a tagged pid (negative: its process group)
FN remote_kill
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    call rm_pid_chan
    test rax, rax
    jz 9f
    test dword ptr [rax + CH_flags], CHF_EXITED
    jnz 9f
    mov rdi, rax
    call rm_chan_index
    mov ebx, eax
    lea rdi, [rip + rm_kill_line]
    call sb_clear
    lea rdi, [rip + rm_kill_line]
    lea rsi, [rip + .Lv_kill]
    call sb_push_cstr
    lea rdi, [rip + rm_kill_line]
    mov esi, ebx
    call sb_push_u64
    lea rdi, [rip + rm_kill_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rm_kill_line]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + rm_kill_line]
    mov esi, ' '
    call sb_push_byte
    xor esi, esi
    test r12d, r12d
    jns 1f
    mov esi, 1
1:  lea rdi, [rip + rm_kill_line]
    call sb_push_u64
    mov rdi, [rip + rm_kill_line + SB_ptr]
    call rm_request_async
9:  xor eax, eax
    EPILOGUE

# remote_pty_resize(fd, cols, rows) -> 1 when fd is a remote pty (resize CH COLS ROWS sent)
FN remote_pty_resize
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    lea rbx, [rip + rm_ch]
    xor r15d, r15d
1:  cmp dword ptr [rbx + CH_kind], CK_PROC
    jne 2f
    cmp [rbx + CH_lfd], r12d
    je 3f
2:  add rbx, CH_SIZE
    inc r15d
    cmp r15d, MUX_MAXCH
    jb 1b
    xor eax, eax
    EPILOGUE
3:  test dword ptr [rbx + CH_flags], CHF_EXITED | CHF_LCLOSED
    jnz 8f
    lea rdi, [rip + rm_kill_line]
    call sb_clear
    lea rdi, [rip + rm_kill_line]
    lea rsi, [rip + .Lv_resize]
    call sb_push_cstr
    lea rdi, [rip + rm_kill_line]
    mov esi, r15d
    call sb_push_u64
    lea rdi, [rip + rm_kill_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rm_kill_line]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + rm_kill_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rm_kill_line]
    mov esi, r14d
    call sb_push_u64
    mov rdi, [rip + rm_kill_line + SB_ptr]
    call rm_request_async
8:  mov eax, 1
    EPILOGUE

# remote_pid_cwd(pid, buf, cap) -> length of the program's current folder in buf, or -1
FN remote_pid_cwd
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    call rm_pid_chan
    test rax, rax
    jz 8f
    mov rdi, rax
    call rm_chan_index
    mov ebx, eax
    lea rdi, [rip + rm_kill_line]
    call sb_clear
    lea rdi, [rip + rm_kill_line]
    lea rsi, [rip + .Lv_cwd]
    call sb_push_cstr
    lea rdi, [rip + rm_kill_line]
    mov esi, ebx
    call sb_push_u64
    mov rdi, [rip + rm_kill_line + SB_ptr]
    mov rsi, [rip + rm_kill_line + SB_len]
    xor edx, edx
    xor ecx, ecx
    call remote_call
    test rax, rax
    js 8f
    mov rdx, [rip + g_remote_reply + SB_len]
    lea rax, [r13 - 1]
    cmp rdx, rax
    jae 8f
    mov rdi, r12
    mov rsi, [rip + g_remote_reply + SB_ptr]
    push rdx
    push rdx
    call memcpy
    pop rax
    pop rax
    mov byte ptr [r12 + rax], 0
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# remote_timeout() -> ms until remote_tick has work, or -1
FN remote_timeout
    cmp dword ptr [rip + rm_need_open], 0
    jne 1f
    call vfs_pending_events
    test eax, eax
    jnz 1f
    cmp dword ptr [rip + rm_rq_ready], 0
    jne 1f
    cmp dword ptr [rip + g_remote], 0
    je 2f
.ifdef WINDOWS
    # while connecting ssh may ask through askpass: its pipe is looked at often (remoteui.s)
    mov eax, [rip + g_remote_state]
    cmp eax, RS_CONNECT
    jb 3f
    cmp eax, RS_START
    ja 3f
    mov eax, 100
    ret
3:
.endif
    # forgotten programs are collected every few seconds
    mov eax, 5000
    ret
1:  xor eax, eax
    ret
2:  mov eax, -1
    ret

# remote_tick(): open the project once connected; forget programs whose end everybody saw
FN remote_tick
    PROLOGUE
    cmp dword ptr [rip + g_remote], 0
    je 9f
    cmp dword ptr [rip + rm_need_open], 0
    je 1f
    mov dword ptr [rip + rm_need_open], 0
    call remote_connected
1:  call vfs_tick               # watch events from the host
    call rm_rq_dispatch         # answers of requests made with remote_request_cb
.ifdef WINDOWS
    call remote_askpass_poll    # ssh's askpass program on the window's pipe (remoteui.s)
.endif
    call remote_ext_tick        # extensions' files on their way to the host (remoteext.s)
    call time_ms
    mov r13, rax
    lea rbx, [rip + rm_ch + CH_SIZE]
    mov r12d, 1
2:  mov eax, [rbx + CH_kind]
    test eax, eax
    jz 4f
    cmp eax, CK_PROC
    jne 3f
    test dword ptr [rbx + CH_flags], CHF_ERRCH
    jnz 4f                      # freed with its program's channel
    test dword ptr [rbx + CH_flags], CHF_EXITED
    jz 4f
    cmp dword ptr [rbx + CH_fd], 0
    jge 4f                      # the local side still has it open
    test dword ptr [rbx + CH_flags], CHF_COLLECTED
    jnz 31f
    mov rax, r13
    sub rax, [rbx + CH_exited_at]
    cmp rax, MUX_GC_MS
    jb 4f
31: mov edi, [rbx + CH_errch]
    test edi, edi
    jz 32f
    call rm_chan
    mov rdi, rax
    call rm_free_chan
32: mov rdi, rbx
    call rm_free_chan
    lea rdi, [rip + rm_kill_line]
    call sb_clear
    lea rdi, [rip + rm_kill_line]
    lea rsi, [rip + .Lv_close]
    call sb_push_cstr
    lea rdi, [rip + rm_kill_line]
    mov esi, r12d
    call sb_push_u64
    cmp dword ptr [rip + g_remote_state], RS_UP
    jne 4f
    mov rdi, [rip + rm_kill_line + SB_ptr]
    call rm_request_async
    jmp 4f
3:  # a program's error output: once its end came
    test dword ptr [rbx + CH_flags], CHF_REOF
    jz 4f
    mov rdi, rbx
    call rm_free_chan
4:  add rbx, CH_SIZE
    inc r12d
    cmp r12d, MUX_MAXCH
    jb 2b
9:  EPILOGUE

# remote_procs() -> eax programs running on the host
FN remote_procs
    lea rcx, [rip + rm_ch]
    xor edx, edx
    xor eax, eax
1:  cmp dword ptr [rcx + CH_kind], CK_PROC
    jne 2f
    test dword ptr [rcx + CH_flags], CHF_EXITED | CHF_ERRCH
    jnz 2f
    inc eax
2:  add rcx, CH_SIZE
    inc edx
    cmp edx, MUX_MAXCH
    jb 1b
    ret

# remote_dump(sb): print-remote: "remote=ssh host=H state=S channels=N rtt=MS in=B out=B procs=P"
FN remote_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_remote]
    call sb_push_cstr
    mov eax, [rip + rm_kind]
    lea rcx, [rip + .Lkind_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_host]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + rm_host]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    mov eax, [rip + g_remote_state]
    lea rcx, [rip + .Lstate_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    # channels in use
    lea rcx, [rip + rm_ch]
    xor edx, edx
    xor r12d, r12d
1:  cmp dword ptr [rcx + CH_kind], 0
    je 2f
    inc r12d
2:  add rcx, CH_SIZE
    inc edx
    cmp edx, MUX_MAXCH
    jb 1b
    mov rdi, rbx
    lea rsi, [rip + .Ld_channels]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_rtt]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + rm_rtt]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_in]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + rm_in_bytes]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_out]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + rm_out_bytes]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_procs]
    call sb_push_cstr
    call remote_procs
    mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    # programs waiting for the session to be reattached
    lea rcx, [rip + rm_ch]
    xor edx, edx
    xor r12d, r12d
4:  test dword ptr [rcx + CH_flags], CHF_DETACHED
    jz 5f
    inc r12d
5:  add rcx, CH_SIZE
    inc edx
    cmp edx, MUX_MAXCH
    jb 4b
    mov rdi, rbx
    lea rsi, [rip + .Ld_detached]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    call remote_forwards_dump   # remotefwd.s
    cmp byte ptr [rip + rm_error], 0
    je 3f
    mov rdi, rbx
    lea rsi, [rip + .Ld_error]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + rm_error]
    call sb_push_cstr
3:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# remote_host() -> rm_host (cstr), remote_kind_name() -> "ssh", "docker" ...
FN remote_host
    lea rax, [rip + rm_host]
    ret
FN remote_kind_name
    mov eax, [rip + rm_kind]
    lea rcx, [rip + .Lkind_names]
    mov rax, [rcx + rax*8]
    ret
FN remote_spec
    lea rax, [rip + rm_spec]
    ret
# remote_is_up() -> eax 1 while the agent answers
FN remote_is_up
    xor eax, eax
    cmp dword ptr [rip + g_remote_state], RS_UP
    sete al
    ret
FN remote_error
    lea rax, [rip + rm_error]
    ret
FN remote_path
    lea rax, [rip + rm_path]
    ret
# remote_upload_progress() -> rax bytes sent, rdx total (0 when not uploading)
FN remote_upload_progress
    mov rdx, [rip + rm_up_total]
    test rdx, rdx
    jz 1f
    mov rax, [rip + rm_wq_off]
    sub rax, [rip + rm_up_start]
    jns 2f
    xor eax, eax
2:  cmp rax, rdx
    jbe 3f
    mov rax, rdx
3:  ret
1:  xor eax, eax
    ret

# ---------------- the log ----------------

# rm_log_path() -> "$XDG_STATE_HOME/rhun/remote.log" (cstr) or 0
FN remote_log_path
    sub rsp, 8
    lea rdi, [rip + rm_log]
    call session_state_dir
    test eax, eax
    jz 1f
    lea rdi, [rip + rm_log]
    lea rsi, [rip + .Lremote_log]
    call sb_push_cstr
    mov rax, [rip + rm_log + SB_ptr]
    add rsp, 8
    ret
1:  xor eax, eax
    add rsp, 8
    ret

# rm_log_raw(ptr, len): appended to the log
rm_log_raw:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call remote_log_path
    test rax, rax
    jz 9f
    mov rdi, rax
    mov esi, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC
    mov edx, 0600
    SYS SYS_open
    test rax, rax
    js 9f
    mov ebx, eax
    mov edi, eax
    mov rsi, r12
    mov rdx, r13
    call write_all
    mov edi, ebx
    SYS SYS_close
9:  EPILOGUE

rm_log_cstr:
    push rbx
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call rm_log_raw
    pop rbx
    ret

# rm_log_bytes(ptr, len): a line with its LF
rm_log_bytes:
    sub rsp, 8
    call rm_log_raw
    lea rdi, [rip + .Lnl]
    call rm_log_cstr
    add rsp, 8
    ret

# rm_log2(a, b): "a" "b" LF
# remote_log2(a cstr, b cstr): a line of the remote log (remoteext.s)
FN remote_log2
rm_log2:
    push rbx
    mov rbx, rsi
    call rm_log_cstr
    mov rdi, rbx
    call rm_log_cstr
    lea rdi, [rip + .Lnl]
    call rm_log_cstr
    pop rbx
    ret

# ---------------- the Linux binary for macOS and Windows windows ----------------

# rm_download_path() -> "$XDG_STATE_HOME/rhun/remote/rhun-VERSION-linux-x86_64" (static)
rm_download_path:
    sub rsp, 8
    lea rdi, [rip + rm_dl_out]
    call session_state_dir
    lea rdi, [rip + rm_dl_out]
    lea rsi, [rip + .Ldl_dir]
    call sb_push_cstr
    lea rdi, [rip + rm_dl_out]
    lea rsi, [rip + rhun_version]
    call sb_push_cstr
    lea rdi, [rip + rm_dl_out]
    lea rsi, [rip + .Ldl_suffix]
    call sb_push_cstr
    mov rax, [rip + rm_dl_out + SB_ptr]
    add rsp, 8
    ret

# rm_download(): the release's Linux archive, checked against its SHA256SUMS, unpacked into the
#   state folder by a short shell script (curl, shasum or sha256sum, tar); rm_dl_done continues
rm_download:
.ifdef WINDOWS
    # Windows: runtime/windows/remote.ps1 (embedded by tools/build-windows.py), its inputs in
    # RHUN_RD_VERSION and RHUN_RD_OUT
    PROLOGUE 80
    cmp dword ptr [rip + rm_dl_pid], 0
    jne 9f
    lea rdi, [rip + rm_dl_env]
    call sb_clear
    lea rdi, [rip + rm_dl_env]
    lea rsi, [rip + .Le_rd_version]
    call sb_push_cstr
    lea rdi, [rip + rm_dl_env]
    lea rsi, [rip + rhun_version]
    call sb_push_cstr
    lea rdi, [rip + rm_dl_env]
    xor esi, esi
    call sb_push_byte
    mov rbx, [rip + rm_dl_env + SB_len]     # where the second one starts
    lea rdi, [rip + rm_dl_env]
    lea rsi, [rip + .Le_rd_out]
    call sb_push_cstr
    call rm_download_path
    mov rsi, rax
    lea rdi, [rip + rm_dl_env]
    call sb_push_cstr
    lea rdi, [rip + rm_dl_env]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + rm_dl_env + SB_ptr]
    mov [rsp], rax
    add rax, rbx
    mov [rsp + 8], rax
    mov qword ptr [rsp + 16], 0
    lea rdi, [rsp]
    call env_make
    mov [rsp + 72], rax
    lea rdi, [rip + .Lps]
    call proc_which
    test rax, rax
    jz 7f
    mov [rsp + 64], rax
    mov [rsp + 16], rax
    lea rax, [rip + .Lps_noprofile]
    mov [rsp + 24], rax
    lea rax, [rip + .Lps_nonint]
    mov [rsp + 32], rax
    lea rax, [rip + .Lps_encoded]
    mov [rsp + 40], rax
    lea rax, [rip + remote_download_script]
    mov [rsp + 48], rax
    mov qword ptr [rsp + 56], 0
    lea rdi, [rsp + 16]
    mov rsi, [rsp + 72]
    xor edx, edx
    call run_piped
    mov r12, rax
    mov r13d, edx
    mov rdi, [rsp + 64]
    call mem_free
    mov rdi, [rsp + 72]
    call mem_free
    test r12, r12
    jle 8f
    jmp .Ldl_started
7:  mov rdi, [rsp + 72]
    call mem_free
8:  lea rdi, [rip + .Lno_download]
    call rm_fail
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE
.Ldl_started:
    mov [rip + rm_dl_pid], r12d
    mov [rip + rm_dl_fd], r13d
    lea rdi, [rip + rm_dl_out]
    call sb_clear
    mov edi, r13d
    mov esi, POLLIN
    lea rdx, [rip + rm_on_download]
    xor ecx, ecx
    call watch_add
    mov dword ptr [rip + g_remote_state], RS_DOWNLOAD
    lea rdi, [rip + .Lrlog_download]
    lea rsi, [rip + rhun_version]
    call rm_log2
    jmp 9b
.else
    PROLOGUE 64
    cmp dword ptr [rip + rm_dl_pid], 0
    jne 9f
    call rm_download_path
    mov rdi, rax
    call mkdir_parent
    call rm_download_path
    mov rdi, rax
    call strlen
    mov rdi, [rip + rm_dl_out + SB_ptr]
    mov rsi, rax
    call mem_dup
    mov rbx, rax
    lea rax, [rip + .Lbin_sh]
    mov [rsp], rax
    lea rax, [rip + .Ldash_c]
    mov [rsp + 8], rax
    lea rax, [rip + .Ldl_script]
    mov [rsp + 16], rax
    lea rax, [rip + .Lsh]
    mov [rsp + 24], rax
    lea rax, [rip + rhun_version]
    mov [rsp + 32], rax
    mov [rsp + 40], rbx
    mov qword ptr [rsp + 48], 0
    lea rdi, [rsp]
    mov rsi, [rip + g_envp]
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, 1                  # its messages too, for the bar
    call run_piped_input
    mov r12, rax
    mov r13d, edx
    mov rdi, rbx
    call mem_free
    test r12, r12
    jle 8f
    mov [rip + rm_dl_pid], r12d
    mov [rip + rm_dl_fd], r13d
    lea rdi, [rip + rm_dl_out]
    call sb_clear
    mov edi, r13d
    mov esi, POLLIN
    lea rdx, [rip + rm_on_download]
    xor ecx, ecx
    call watch_add
    mov dword ptr [rip + g_remote_state], RS_DOWNLOAD
    lea rdi, [rip + .Lrlog_download]
    lea rsi, [rip + rhun_version]
    call rm_log2
    jmp 9f
8:  lea rdi, [rip + .Lno_download]
    call rm_fail
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE
.endif

# rm_on_download(fd, revents, ctx): the download's output; at its end, connect or say why not
rm_on_download:
    PROLOGUE
1:  lea rdi, [rip + rm_dl_out]
    mov esi, 4096
    call sb_reserve
    mov rsi, rax
    mov edi, [rip + rm_dl_fd]
    mov edx, 4096
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 2f
    cmp qword ptr [rip + rm_dl_out + SB_len], 65536
    jae 1b                      # enough said: the rest is dropped
    add [rip + rm_dl_out + SB_len], rax
    jmp 1b
2:  mov edi, [rip + rm_dl_fd]
    call watch_remove
    mov edi, [rip + rm_dl_fd]
    SYS SYS_close
    mov dword ptr [rip + rm_dl_fd], -1
    mov edi, [rip + rm_dl_pid]
    xor esi, esi
    call proc_wait
    mov ebx, eax
    mov dword ptr [rip + rm_dl_pid], 0
    mov rdi, [rip + rm_dl_out + SB_ptr]
    mov rsi, [rip + rm_dl_out + SB_len]
    test rdi, rdi
    jz 3f
    call rm_log_raw
3:  test ebx, ebx
    jnz 4f
    call rm_connect
    jmp 9f
4:  # the script's last line says what went wrong
    lea rdi, [rip + rm_error]
    lea rsi, [rip + .Ldl_failed]
    call cstr_copy
    mov dword ptr [rip + g_remote_state], RS_FAILED
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

.bss
.p2align 3
rm_spawn_line: .zero SB_SIZE
rm_spawn_body: .zero SB_SIZE
.globl remote_confine_blk, remote_confine_len, g_remote_confined, g_remote_confine_why
remote_confine_blk: .quad 0     # remote_spawn flags bit 3: NEEDS DIR SCRIPT STATE PROJECT RUNS
remote_confine_len: .quad 0
g_remote_confined: .long 0      # the host's answer: CONFINED_*, -1 none
.p2align 3
g_remote_confine_why: .zero 320 # why it is not held there (cstr), or empty
rm_kill_line: .zero SB_SIZE
rm_dl_env: .zero SB_SIZE         # Windows: the download's RHUN_RD_* entries
rm_reset_gen: .long 0
rm_tenv: .quad 0
rm_rq: .zero RQ_SIZE * RQ_MAX
rm_rq_ready: .long 0

.section .rodata
.p2align 3
.Lspec_table:
    .quad .Ls_ssh, RT_SSH, .Ls_docker, RT_DOCKER, .Ls_podman, RT_PODMAN, .Ls_local, RT_LOCAL
    .quad .Ls_wsl, RT_WSL, 0, 0
.Lkind_names:
    .quad .Lk_none, .Lk_ssh, .Lk_docker, .Lk_podman, .Lk_local, .Lk_wsl
.Lstate_names:
    .quad .Lst_off, .Lst_download, .Lst_connect, .Lst_upload, .Lst_upload, .Lst_start, .Lst_up
    .quad .Lst_lost, .Lst_failed
.Lextra_dirs:
    .quad .Ldir_usr_local, .Ldir_homebrew, 0
.Ls_ssh: .asciz "ssh:"
.Ls_docker: .asciz "docker:"
.Ls_podman: .asciz "podman:"
.Ls_local: .asciz "local:"
.Ls_wsl: .asciz "wsl:"
.Lk_none: .asciz "none"
.Lk_ssh: .asciz "ssh"
.Lk_docker: .asciz "docker"
.Lk_podman: .asciz "podman"
.Lk_local: .asciz "local"
.Lk_wsl: .asciz "wsl"
.Lst_off: .asciz "off"
.Lst_download: .asciz "downloading"
.Lst_connect: .asciz "connecting"
.Lst_upload: .asciz "uploading"
.Lst_start: .asciz "starting"
.Lst_up: .asciz "connected"
.Lst_lost: .asciz "lost"
.Lst_failed: .asciz "failed"
.Ldir_usr_local: .asciz "/usr/local/bin"
.Ldir_homebrew: .asciz "/opt/homebrew/bin"
.Lssh: .asciz "ssh"
.Ldocker: .asciz "docker"
.Lpodman: .asciz "podman"
.Lwsl: .asciz "wsl.exe"
.Lexec: .asciz "exec"
.Ldash_i: .asciz "-i"
.Ldash_t: .asciz "-T"
.Ldash_o: .asciz "-o"
.Ldash_e: .asciz "-e"
.Ldash_p: .asciz "-p"
.Ldash_d: .asciz "-d"
.Ldash_s: .asciz "-s"
.Ldash_c: .asciz "-c"
.Ldashdash: .asciz "--"
.Lnone: .asciz "none"
.Lalive: .asciz "ServerAliveInterval=15"
.Lalive_max: .asciz "ServerAliveCountMax=3"
.Lconnect_timeout: .asciz "ConnectTimeout=20"
.Lsh: .asciz "sh"
.Lsh_s: .asciz "sh -s"
.Lbin_sh: .asciz "/bin/sh"
.Lself_exe: .asciz "/proc/self/exe"
.Lenv_ssh: .asciz "RHUN_SSH"
.Lenv_strict: .asciz "RHUN_REMOTE_STRICT"
.Lcolon: .ascii ":"
.Lcolon_sp: .asciz ": "
.Lhex: .ascii "0123456789abcdef"
.Lnl: .asciz "\n"
# the bootstrap: one line at a time, each answered before the next is sent, so that the shell, which
# reads its script from the same pipe, never reads ahead into the binary
.Lboot_d: .asciz "d=\"${XDG_CACHE_HOME:-$HOME/.cache}/rhun-remote/"
.Lboot_force: .asciz "\"; rm -f \"$d/rhun"
.Lboot_check: .ascii "\"; case \"$(uname -sm)\" in \"Linux x86_64\") if [ -x \"$d/rhun\" ]; then echo \"@rhun have\"; "
    .ascii "else mkdir -p \"$d\" && chmod 700 \"${d%/*}\" \"$d\" && echo \"@rhun need\" || echo \"@rhun error cannot create $d\"; fi;; "
    .asciz "*) echo \"@rhun unsupported $(uname -sm)\";; esac\n"
.Lboot_exec: .asciz "exec \"$d/rhun\" --remote-agent"
.Lopt_session: .asciz " --session "
.Lboot_up1: .asciz "echo \"@rhun go\"; head -c "
.Lboot_up2: .asciz " > \"$d/rhun.part\" && chmod 700 \"$d/rhun.part\" && mv -f \"$d/rhun.part\" \"$d/rhun\" && "
.Lboot_up3: .asciz "; echo \"@rhun error the upload failed\"\n"
.Lenv_session: .asciz "RHUN_REMOTE_SESSION"
.Lat_rhun: .ascii "@rhun "
.Lw_have: .ascii "have"
.Lw_need: .ascii "need"
.Lw_go: .ascii "go"
.Lw_unsupported: .ascii "unsupported"
.Lw_hello: .ascii "hello rhun-remote "
.Lw_error: .ascii "error"
.Lv_spawn: .asciz "spawn "
.Lv_kill: .asciz "kill "
.Lv_resize: .asciz "resize "
.Lv_cwd: .asciz "cwd "
.Lv_close: .asciz "close "
.Lv_attach: .asciz "attach"
.Lenv_remote_sh: .asciz "RHUN_REMOTE_SH"
.Le_rd_version: .asciz "RHUN_RD_VERSION="
.Le_rd_out: .asciz "RHUN_RD_OUT="
.Lps: .asciz "powershell.exe"
.Lps_noprofile: .asciz "-NoProfile"
.Lps_nonint: .asciz "-NonInteractive"
.Lps_encoded: .asciz "-EncodedCommand"
.Lv_connect: .asciz "connect "
.Lrlog_attached: .asciz "attached to session "
.Lrlog_attach: .asciz "the session has: "
.Lv_quit: .asciz "quit"
.p2align 3
.Lno_extras: .quad 0
.Lzero_sp: .asciz "0 "
.Lsp_zero_nl: .asciz " 0\n"
.Ld_sp: .asciz "d "
.Le_sp: .asciz "e "
.Lw_sp: .asciz "w "
.Ld_remote: .asciz "remote="
.Ld_host: .asciz " host="
.Ld_state: .asciz " state="
.Ld_channels: .asciz " channels="
.Ld_rtt: .asciz " rtt="
.Ld_in: .asciz " in="
.Ld_out: .asciz " out="
.Ld_procs: .asciz " procs="
.Ld_detached: .asciz " detached="
.Ld_error: .asciz " error="
.Lremote_log: .asciz "/remote.log"
.Lbad_spec: .asciz "Not a remote: use ssh:HOST, docker:NAME or podman:NAME"
.Lno_binary: .asciz "No Linux rhun to start on the host (see [remote] agent_binary)"
.Lno_program: .asciz "The transport program (ssh, docker) was not found"
.Lno_transport: .asciz "The transport could not be started"
.Lunsupported: .asciz "The host is not Linux on x86-64: "
.Lboot_failed: .asciz "Starting failed: "
.Lmismatch: .asciz "The host keeps a damaged copy of rhun in ~/.cache/rhun-remote"
.Lcould_not: .asciz "Could not connect to "
.Llost: .asciz "Connection to "
.Llost2: .asciz " lost"
.Lno_download: .asciz "Could not download rhun for Linux (set [remote] agent_binary)"
.Ldl_failed: .asciz "Could not download rhun for Linux; see the remote log, or set [remote] agent_binary"
.Ldl_dir: .asciz "/remote/rhun-"
.Ldl_suffix: .asciz "-linux-x86_64"
.Lrlog_connect: .asciz "connect "
.Lrlog_failed: .asciz "failed: "
.Lrlog_upload: .asciz "uploading "
.Lrlog_up: .asciz "connected to "
.Lrlog_lost: .asciz "lost "
.Lrlog_mismatch: .asciz "the cached binary does not match, sending it again to "
.Lrlog_said: .asciz "host: "
.Lrlog_bad: .asciz "protocol error from "
.Lrlog_download: .asciz "downloading the Linux release "
# sh -c SCRIPT sh VERSION DEST
.Ldl_script: .ascii "set -e; base=${RHUN_RELEASES_URL:-https://github.com/vshvedov/rhun/releases}; v=$1; out=$2; "
    .ascii "tmp=$(mktemp -d); trap 'rm -rf \"$tmp\"' EXIT; name=rhun-$v-linux-x86_64.tar.gz; "
    .ascii "curl -fsSL --connect-timeout 10 --retry 3 -o \"$tmp/$name\" \"$base/download/v$v/$name\"; "
    .ascii "curl -fsSL --connect-timeout 10 --retry 3 -o \"$tmp/SHA256SUMS\" \"$base/download/v$v/SHA256SUMS\"; "
    .ascii "want=$(awk -v f=\"$name\" '$2 == f || $2 == \"*\" f { print $1 }' \"$tmp/SHA256SUMS\"); "
    .ascii "if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum \"$tmp/$name\" | awk '{ print $1 }'); "
    .ascii "else got=$(shasum -a 256 \"$tmp/$name\" | awk '{ print $1 }'); fi; "
    .ascii "[ -n \"$want\" ] && [ \"$got\" = \"$want\" ] || { echo \"$name does not match SHA256SUMS\"; exit 1; }; "
    .ascii "tar -xzf \"$tmp/$name\" -C \"$tmp\" \"rhun-$v/bin/rhun\"; "
    .asciz "chmod 755 \"$tmp/rhun-$v/bin/rhun\"; mv -f \"$tmp/rhun-$v/bin/rhun\" \"$out\""
.text
