# The bridge for terminal claude (design 7.5; ext-host-ide.md 1): the IDE server the official extension runs for
# a `claude` in an integrated terminal, so that claude in rhun's terminal connects to rhun (/ide shows rhun),
# hears the selection and at-mentions, and shows its edits as diffs in rhun's Review tab.
#
# A WebSocket server (RFC 6455) on 127.0.0.1 only, on a random port from 10000 to 65535 (the port this rhun
# listened on before is tried first), while [claude] ide is on and a trusted project is open in a local
# window. The lock file <Claude folder>/ide/<port>.lock (claudecfg.s's claude_dir: CLAUDE_CONFIG_DIR or
# ~/.claude) holds the extension's six fields, ideName "rhun"; it is 0600 in a 0700 folder, rewritten when the
# window's folders change, removed when the server stops; locks of rhun processes that are gone are removed
# when it starts. Every terminal's program gets CLAUDE_CODE_SSE_PORT (termview.s's term_env_ide), which makes
# the CLI connect. A connection must send x-claude-code-ide-authorization with the token of the lock file
# (compared in constant time) in its upgrade request within 5 s; one client at a time: a newer one closes the
# older (4001). Frames: masked from the client, text or binary, fragments joined, at most 16 MiB a message
# (1009 above), ping answered, anything else of the protocol a 1002. At most 256 KiB read per wake-up; a
# client that does not read is dropped past 64 MiB waiting. Messages are MCP (mcpsrv.s) for edtools.s's
# server; selection_changed goes 300 ms after the selection last changed (and 500 ms after a client
# connects), at_mentioned from Claude: Insert @-Mention in Terminal.
#
#   ide_tick(), ide_timeout() -> eax ms or -1      app.s's loop
#   ide_shutdown()                                 rhun quits: the lock file goes
#   ide_later_done(token, sb, flags)               mcpsrv.s: a tool's late answer goes to its connection
#   ide_port() -> eax the port listened on, or 0
#   ide_mention() -> eax 1 when at_mentioned went to a connected claude
#   ide_connected() -> eax 1 while a claude is connected
#   ide_ctl: print-ide (control.s)
.include "rhun.inc"

.equ IC_MAX, 4                  # connections at once (one client, the rest handshaking or closing)
.equ HS_MAX, 8192               # an upgrade request
.equ HS_MS, 5000                # it must come within this
.equ CLOSE_MS, 1000             # a closing connection's last bytes
.equ MSG_MAX, 16777216          # a message, its fragments together
.equ WQ_MAX, 67108864           # bytes waiting to go out before the client is dropped
.equ READ_STEP, 65536
.equ READS, 4                   # reads per wake-up
.equ SEL_MS, 300
.equ RESEND_MS, 500
.equ PORT_TRIES, 50
.equ PL_MAX, 64                 # tool calls answered later, waiting
.equ ICS_FREE, 0
.equ ICS_HANDSHAKE, 1
.equ ICS_OPEN, 2
.equ ICS_CLOSING, 3             # its last bytes go out, then it closes
.equ ICS_DEAD, 4                # closed at the next tick

STRUCT
F IC_fd, 4
F IC_state, 4
F IC_gen, 8                     # its number: tokens carry it
F IC_deadline, 8                # the handshake's or the closing's end, 0 none
F IC_resend, 8                  # when the selection is sent again (a new client), 0 none
F IC_rbuf, SB_SIZE              # read, not parsed yet
F IC_roff, 8                    # parsed up to here
F IC_msg, SB_SIZE               # a fragmented message's parts so far
F IC_wq, SB_SIZE                # waiting to go out
F IC_woff, 8
F IC_mop, 4                     # the opcode of the message in IC_msg, 0 none
F IC_events, 4                  # what is watched
F IC_seq, 4                     # its calls, numbered
F IC_proto, 4                   # 1: it asked for the "mcp" subprotocol
ENDSTRUCT IC_SIZE

STRUCT
F PL_token, 8                   # 0: free
F PL_id, 8                      # the request's id as JSON text (owned)
F PL_idlen, 8
ENDSTRUCT PL_SIZE

.data
lfd: .long -1                   # the listener
.bss
.p2align 3
lport: .long 0
kport: .long 0                  # the port of this rhun's listener before: tried first
failed_for: .quad 0             # g_project the server could not start for (not tried again for it)
token: .zero 40                 # the lock file's authToken: a v4 UUID
lock_path: .zero 4200           # the lock file written, or empty
seen_gen: .quad 0               # g_ws_gen the lock file was written for
gen_next: .quad 0
active: .quad 0                 # the client (IC*), or 0
conns: .zero IC_SIZE * IC_MAX
pend: .zero PL_SIZE * PL_MAX
sel_key: .quad 0                # the selection's key last seen
sel_due: .quad 0                # selection_changed is due then, 0 none
last_sel: .zero SB_SIZE         # the params last sent
selb: .zero SB_SIZE
resp: .zero SB_SIZE             # an answer to a message
resp2: .zero SB_SIZE            # a late answer
lockb: .zero SB_SIZE
hbuf: .zero 256                 # a frame's header; the handshake's accept key
env_line: .zero 40              # CLAUDE_CODE_SSE_PORT=N
rnd: .zero 16
st_buf: .zero 160
n_conns: .quad 0                # connections accepted, refused, messages in and out
n_refused: .quad 0
n_in: .quad 0
n_out: .quad 0
n_notes: .quad 0                # notifications sent
last_method: .zero 64           # the last method a client sent

.text

# ---------------- whether it runs ----------------

# want() -> eax 1 when the server should listen: [claude] ide, a trusted project, a local window
want:
    xor eax, eax
    cmp dword ptr [rip + cfg_claude_ide], 0
    je 9f
    cmp qword ptr [rip + g_project], 0
    je 9f
    cmp dword ptr [rip + g_remote], 0
    jne 9f
    sub rsp, 8
    call wfold_count
    test eax, eax
    jz 8f
    xor edi, edi
    call wfold_flags
    and eax, WS_TRUSTED
    jz 8f
    mov eax, 1
8:  add rsp, 8
9:  ret

# FN ide_tick()
FN ide_tick
    PROLOGUE
    call want
    mov ebx, eax
    cmp dword ptr [rip + lfd], 0
    jge 2f
    test ebx, ebx               # not listening: start when wanted (once per project when it fails)
    jz 9f
    mov rax, [rip + g_project]
    cmp rax, [rip + failed_for]
    je 9f
    call start
    jmp 9f
2:  test ebx, ebx
    jnz 3f
    call stop
    jmp 9f
3:  mov rax, [rip + g_ws_gen]   # the folders changed: the lock file says so
    cmp rax, [rip + seen_gen]
    je 4f
    call write_lock
4:  call time_ms
    mov r12, rax
    # connections: deadlines, and those to close
    lea rbx, [rip + conns]
    xor r13d, r13d
5:  mov eax, [rbx + IC_state]
    cmp eax, ICS_DEAD
    je 51f
    cmp eax, ICS_FREE
    je 6f
    mov rax, [rbx + IC_deadline]
    test rax, rax
    jz 52f
    cmp r12, rax
    jb 52f
51: mov rdi, rbx
    call conn_free
    jmp 6f
52: cmp dword ptr [rbx + IC_state], ICS_OPEN
    jne 6f
    mov rax, [rbx + IC_resend]
    test rax, rax
    jz 6f
    cmp r12, rax
    jb 6f
    mov qword ptr [rbx + IC_resend], 0
    cmp rbx, [rip + active]
    jne 6f
    call send_selection_now     # a new client hears the selection as it is
6:  add rbx, IC_SIZE
    inc r13d
    cmp r13d, IC_MAX
    jb 5b
    # the selection, while a client is connected
    cmp qword ptr [rip + active], 0
    je 9f
    call edtool_selection_key
    test rax, rax
    jz 8f
    cmp rax, [rip + sel_key]
    je 8f
    mov [rip + sel_key], rax
    lea rax, [r12 + SEL_MS]
    mov [rip + sel_due], rax
8:  mov rax, [rip + sel_due]
    test rax, rax
    jz 9f
    cmp r12, rax
    jb 9f
    mov qword ptr [rip + sel_due], 0
    call send_selection
9:  EPILOGUE

# FN ide_timeout() -> eax ms until ide_tick has work, or -1
FN ide_timeout
    PROLOGUE
    mov r13d, -1
    cmp dword ptr [rip + lfd], 0
    jl 9f
    call time_ms
    mov r12, rax
    mov rax, [rip + sel_due]
    test rax, rax
    jz 1f
    cmp qword ptr [rip + active], 0
    je 1f
    mov rdi, rax
    call at
1:  lea rbx, [rip + conns]
    xor r14d, r14d
2:  mov eax, [rbx + IC_state]
    cmp eax, ICS_FREE
    je 4f
    cmp eax, ICS_DEAD
    jne 3f
    xor r13d, r13d
    jmp 9f
3:  mov rdi, [rbx + IC_deadline]
    test rdi, rdi
    jz 31f
    call at
31: mov rdi, [rbx + IC_resend]
    test rdi, rdi
    jz 4f
    call at
4:  add rbx, IC_SIZE
    inc r14d
    cmp r14d, IC_MAX
    jb 2b
9:  mov eax, r13d
    EPILOGUE

# at(time): r13d = the smaller of r13d (-1: none) and the ms from r12 (now) to time
at:
    mov rax, rdi
    sub rax, r12
    jns 1f
    xor eax, eax
1:  cmp rax, 0x7fffffff
    jb 2f
    mov eax, 0x7fffffff
2:  test r13d, r13d
    js 3f
    cmp eax, r13d
    jae 4f
3:  mov r13d, eax
4:  ret

# ---------------- starting and stopping ----------------

# start(): the token, the listener, the lock file, the terminals' variable
start:
    PROLOGUE 32
    mov rax, [rip + g_project]
    mov [rip + failed_for], rax
    # the token: 16 random bytes as a v4 UUID
    lea rdi, [rip + rnd]
    mov esi, 16
    call wasi_os_random
    test rax, rax
    js 9f
    lea rbx, [rip + rnd]
    mov al, [rbx + 6]
    and al, 0x0f
    or al, 0x40
    mov [rbx + 6], al
    mov al, [rbx + 8]
    and al, 0x3f
    or al, 0x80
    mov [rbx + 8], al
    lea rdi, [rip + token]
    xor ecx, ecx
1:  cmp ecx, 4
    je 11f
    cmp ecx, 6
    je 11f
    cmp ecx, 8
    je 11f
    cmp ecx, 10
    jne 12f
11: mov byte ptr [rdi], '-'
    inc rdi
12: movzx eax, byte ptr [rbx + rcx]
    mov edx, eax
    shr eax, 4
    and edx, 15
    lea r8, [rip + .Lhex]
    movzx eax, byte ptr [r8 + rax]
    movzx edx, byte ptr [r8 + rdx]
    mov [rdi], al
    mov [rdi + 1], dl
    add rdi, 2
    inc ecx
    cmp ecx, 16
    jb 1b
    mov byte ptr [rdi], 0
    # the listener: the earlier port, else random ones
    mov edi, [rip + kport]
    test edi, edi
    jz 2f
    call listen_on
    test eax, eax
    jnz 4f
2:  xor r12d, r12d
3:  cmp r12d, PORT_TRIES
    jae .Lst_fail
    inc r12d
    lea rdi, [rip + rnd]
    mov esi, 2
    call wasi_os_random
    test rax, rax
    js .Lst_fail
    movzx eax, word ptr [rip + rnd]
    xor edx, edx
    mov ecx, 55536
    div ecx
    lea edi, [rdx + 10000]
    call listen_on
    test eax, eax
    jz 3b
4:  mov [rip + kport], eax
    mov [rip + lport], eax
    mov qword ptr [rip + failed_for], 0
    mov edi, [rip + lfd]
    mov esi, POLLIN
    lea rdx, [rip + on_accept]
    xor ecx, ecx
    call watch_try_add
    test eax, eax
    jz .Lst_close
    call clean_stale
    call write_lock
    # CLAUDE_CODE_SSE_PORT=N for every terminal started from now on
    lea rdi, [rip + env_line]
    lea rsi, [rip + .Lenv_name]
    call cstr_copy
    mov rbx, rax
    mov rdi, rax
    mov esi, [rip + lport]
    call fmt_u64
    mov byte ptr [rbx + rax], 0
    lea rdi, [rip + env_line]
    call term_env_ide
    mov qword ptr [rip + sel_key], 0
    mov qword ptr [rip + sel_due], 0
    lea rdi, [rip + last_sel]
    call sb_clear
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE
.Lst_close:
    mov edi, [rip + lfd]
    SYS SYS_close
    mov dword ptr [rip + lfd], -1
.Lst_fail:
    mov dword ptr [rip + lport], 0
    lea rdi, [rip + .Llog_fail]
    call log_cstr
    EPILOGUE

# listen_on(port) -> eax the port when 127.0.0.1:port is bound and listened on (lfd), else 0
listen_on:
    PROLOGUE 16
    mov r12d, edi
    mov edi, AF_INET
    mov esi, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js 8f
    mov ebx, eax
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 0
    mov word ptr [rsp], AF_INET
    mov eax, r12d               # the port in network order
    shr eax, 8
    mov ecx, r12d
    shl ecx, 8
    or eax, ecx
    mov [rsp + 2], ax
    mov dword ptr [rsp + 4], 0x0100007f     # 127.0.0.1
    mov edi, ebx
    lea rsi, [rsp]
    mov edx, 16
    SYS SYS_bind
    test rax, rax
    js 7f
    mov edi, ebx
    mov esi, 8
    SYS SYS_listen
    test rax, rax
    js 7f
    mov [rip + lfd], ebx
    mov eax, r12d
    EPILOGUE
7:  mov edi, ebx
    SYS SYS_close
8:  xor eax, eax
    EPILOGUE

# stop(): every connection closes (their diffs too), the listener goes, the lock file and the variable
stop:
    PROLOGUE
    lea rbx, [rip + conns]
    xor r12d, r12d
1:  cmp dword ptr [rbx + IC_state], ICS_FREE
    je 2f
    mov rdi, rbx
    call conn_free
2:  add rbx, IC_SIZE
    inc r12d
    cmp r12d, IC_MAX
    jb 1b
    mov edi, [rip + lfd]
    test edi, edi
    js 3f
    call watch_remove
    mov edi, [rip + lfd]
    SYS SYS_close
    mov dword ptr [rip + lfd], -1
3:  mov dword ptr [rip + lport], 0
    call remove_lock
    xor edi, edi
    call term_env_ide
    mov qword ptr [rip + sel_due], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN ide_shutdown(): rhun quits
FN ide_shutdown
    PROLOGUE
    cmp dword ptr [rip + lfd], 0
    jl 9f
    call stop
9:  EPILOGUE

# ---------------- the lock file ----------------

# ide_dir(sb) -> eax 1 with sb the folder <Claude folder>/ide (NUL after it), made 0700 when missing
ide_dir:
    PROLOGUE
    mov rbx, rdi
    call sb_clear
    mov rdi, rbx
    call claude_dir
    test eax, eax
    jz 8f
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    mov rdi, [rbx + SB_ptr]
    mov esi, 0700
    SYS SYS_mkdir               # the Claude folder itself, when it is missing (the extension's mkdir -p)
    dec qword ptr [rbx + SB_len]
    mov rdi, rbx
    lea rsi, [rip + .Lslash_ide]
    call sb_push_cstr
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    mov rdi, [rbx + SB_ptr]
    mov esi, 0700
    SYS SYS_mkdir
.ifndef WINDOWS
    # the user's own folder, and nobody else's: 0700
    mov rdi, [rbx + SB_ptr]
    lea rsi, [rip + st_buf]
    SYS SYS_lstat
    test rax, rax
    js 8f
    mov eax, [rip + st_buf + 24]
    and eax, 0170000
    cmp eax, 0040000
    jne 8f
    SYS SYS_getuid
    cmp eax, [rip + st_buf + 28]
    jne 8f
    mov eax, [rip + st_buf + 24]
    and eax, 0777
    cmp eax, 0700
    je 7f
    mov rdi, [rbx + SB_ptr]     # through a descriptor: macOS's shim has fchmod, not chmod
    mov esi, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 7f
    mov r12d, eax
    mov edi, eax
    mov esi, 0700
    SYS SYS_fchmod
    mov edi, r12d
    SYS SYS_close
.endif
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# write_lock(): <Claude folder>/ide/<port>.lock: {"pid","workspaceFolders","ideName","transport",
#   "runningInWindows","authToken"}, 0600, made anew
write_lock:
    PROLOGUE
    mov rax, [rip + g_ws_gen]
    mov [rip + seen_gen], rax
    lea rdi, [rip + selb]
    call ide_dir
    test eax, eax
    jz 8f
    lea rdi, [rip + selb]       # the path
    dec qword ptr [rip + selb + SB_len]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + selb]
    mov esi, [rip + lport]
    call sb_push_u64
    lea rdi, [rip + selb]
    lea rsi, [rip + .Ldot_lock]
    call sb_push_cstr
    lea rdi, [rip + selb]
    xor esi, esi
    call sb_push_byte
    cmp qword ptr [rip + selb + SB_len], 4100
    ja 8f
    # a lock written under another folder before (the Claude folder moved): it goes
    mov rdi, [rip + selb + SB_ptr]
    lea rsi, [rip + lock_path]
    call strcmp_eq
    test eax, eax
    jnz 1f
    call remove_lock
1:  lea rdi, [rip + lock_path]
    mov rsi, [rip + selb + SB_ptr]
    call cstr_copy
    # the content
    lea rbx, [rip + lockb]
    mov rdi, rbx
    call jw_begin
    mov rdi, rbx
    call jw_obj
    mov rdi, rbx
    lea rsi, [rip + .Lk_pid]
    call jw_key
    SYS SYS_getpid
    mov rdi, rbx
    mov rsi, rax
    call jw_u64
    mov rdi, rbx
    lea rsi, [rip + .Lk_folders]
    call jw_key
    mov rdi, rbx
    call jw_arr
    xor r12d, r12d
2:  call wfold_count
    cmp r12d, eax
    jae 3f
    mov edi, r12d
    call wfold_path
    mov rdi, rbx
    mov rsi, rax
    call jw_cstr
    inc r12d
    jmp 2b
3:  mov rdi, rbx
    call jw_end_arr
    mov rdi, rbx
    lea rsi, [rip + .Lk_ide_name]
    call jw_key
    mov rdi, rbx
    lea rsi, [rip + .Lv_rhun]
    call jw_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_transport]
    call jw_key
    mov rdi, rbx
    lea rsi, [rip + .Lv_ws]
    call jw_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_windows]
    call jw_key
    mov rdi, rbx
.ifdef WINDOWS
    mov esi, 1
.else
    xor esi, esi
.endif
    call jw_bool
    mov rdi, rbx
    lea rsi, [rip + .Lk_token]
    call jw_key
    mov rdi, rbx
    lea rsi, [rip + token]
    call jw_cstr
    mov rdi, rbx
    call jw_end_obj
    lea rdi, [rip + lock_path]  # a new file, never one that was there (a link to elsewhere)
    SYS SYS_unlink
    lea rdi, [rip + lock_path]
    mov rsi, [rbx + SB_ptr]
    mov rdx, [rbx + SB_len]
    call file_write_private
    test rax, rax
    jns 9f
    lea rdi, [rip + .Llog_lock]
    call log_cstr
    mov byte ptr [rip + lock_path], 0
    EPILOGUE
8:  call remove_lock
9:  EPILOGUE

# remove_lock(): the lock file written, if any, goes
remove_lock:
    lea rdi, [rip + lock_path]
    cmp byte ptr [rdi], 0
    je 1f
    sub rsp, 8
    SYS SYS_unlink
    mov byte ptr [rip + lock_path], 0
    add rsp, 8
1:  ret

# clean_stale(): lock files of rhun processes that are gone are removed (another IDE's are left alone)
clean_stale:
.ifdef WINDOWS
    ret                         # no way here to ask whether another process runs
.else
    PROLOGUE
    lea rdi, [rip + selb]
    call ide_dir
    test eax, eax
    jz 9f
    mov rdi, [rip + selb + SB_ptr]
    call dup_cstr
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + stale_one]
    mov rdx, rbx
    call dir_each
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# stale_one(folder, name, is_dir): NAME.lock whose ideName is "rhun" and whose pid runs no more: removed
stale_one:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    test edx, edx
    jnz 9f
    mov rdi, r13
    call strlen
    cmp rax, 5
    jbe 9f
    lea rdi, [r13 + rax - 5]
    lea rsi, [rip + .Ldot_lock]
    call strcmp_eq
    test eax, eax
    jz 9f
    lea rdi, [rip + resp2]
    call sb_clear
    lea rdi, [rip + resp2]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + resp2]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + resp2]
    mov rsi, r13
    call sb_push_cstr
    lea rdi, [rip + resp2]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + resp2 + SB_ptr]
    mov esi, 65536
    call file_read_limited
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    mov rsi, rdx
    mov edx, 1000
    mov ecx, 8
    call json_parse_lim
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_ide_name]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_rhun]
    call json_is
    test eax, eax
    jz 8f
    mov rdi, r14
    lea rsi, [rip + .Lk_pid]
    call json_get
    mov rdi, rax
    call json_int
    test edx, edx
    jz 8f
    test rax, rax
    jle 8f
    mov r15, rax
    SYS SYS_getpid
    cmp rax, r15
    je 8f                       # ours
    mov rdi, r15
    xor esi, esi
    SYS SYS_kill
    cmp rax, -3                 # ESRCH: no such process
    jne 8f
    mov rdi, [rip + resp2 + SB_ptr]
    SYS SYS_unlink
8:  mov rdi, rbx
    call mem_free
9:  EPILOGUE
.endif

# ---------------- connections ----------------

# on_accept(fd, revents, ctx): each connection waiting gets a free entry (none: it is closed at once)
on_accept:
    PROLOGUE
1:  mov edi, [rip + lfd]
    test edi, edi
    js 9f
    xor esi, esi
    xor edx, edx
    mov r10d, SOCK_CLOEXEC | SOCK_NONBLOCK
    SYS SYS_accept4
    cmp rax, -EINTR
    je 1b
    test rax, rax
    js 9f
    mov r12d, eax
    inc qword ptr [rip + n_conns]
    lea rbx, [rip + conns]
    xor ecx, ecx
2:  cmp dword ptr [rbx + IC_state], ICS_FREE
    je 3f
    add rbx, IC_SIZE
    inc ecx
    cmp ecx, IC_MAX
    jb 2b
    inc qword ptr [rip + n_refused]
    mov edi, r12d
    SYS SYS_close
    jmp 1b
3:  mov rdi, rbx                # clean, keeping its buffers' memory
    call conn_reset
    mov [rbx + IC_fd], r12d
    mov dword ptr [rbx + IC_state], ICS_HANDSHAKE
    inc qword ptr [rip + gen_next]
    mov rax, [rip + gen_next]
    mov [rbx + IC_gen], rax
    call time_ms
    add rax, HS_MS
    mov [rbx + IC_deadline], rax
    mov dword ptr [rbx + IC_events], POLLIN
    mov edi, r12d
    mov esi, POLLIN
    lea rdx, [rip + on_conn]
    mov rcx, rbx
    call watch_try_add
    test eax, eax
    jnz 1b
    mov edi, r12d
    SYS SYS_close
    mov dword ptr [rbx + IC_state], ICS_FREE
    jmp 1b
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# conn_reset(IC*): its state cleared (its buffers kept)
conn_reset:
    mov dword ptr [rdi + IC_fd], -1
    mov dword ptr [rdi + IC_state], ICS_FREE
    xor eax, eax
    mov [rdi + IC_gen], rax
    mov [rdi + IC_deadline], rax
    mov [rdi + IC_resend], rax
    mov [rdi + IC_roff], rax
    mov [rdi + IC_woff], rax
    mov [rdi + IC_mop], eax
    mov [rdi + IC_events], eax
    mov [rdi + IC_seq], eax
    mov [rdi + IC_proto], eax
    mov [rdi + IC_rbuf + SB_len], rax
    mov [rdi + IC_msg + SB_len], rax
    mov [rdi + IC_wq + SB_len], rax
    ret

# conn_free(IC*): closed now; its calls waiting and its diffs go; its buffers' memory is given back
conn_free:
    PROLOGUE
    mov rbx, rdi
    mov edi, [rbx + IC_fd]
    test edi, edi
    js 1f
    call watch_remove
    mov edi, [rbx + IC_fd]
    SYS SYS_close
1:  cmp rbx, [rip + active]
    jne 2f
    mov qword ptr [rip + active], 0
    mov qword ptr [rip + sel_due], 0
2:  mov r12, [rbx + IC_gen]
    mov dword ptr [rbx + IC_state], ICS_FREE   # nothing goes to it from here on
    # its calls waiting
    lea r13, [rip + pend]
    xor r14d, r14d
3:  mov rax, [r13 + PL_token]
    test rax, rax
    jz 4f
    shl rax, 8
    shr rax, 28
    cmp rax, r12
    jne 4f
    mov qword ptr [r13 + PL_token], 0
    mov rdi, [r13 + PL_id]
    call mem_free
4:  add r13, PL_SIZE
    inc r14d
    cmp r14d, PL_MAX
    jb 3b
    test r12, r12
    jz 5f
    mov rdi, r12
    call edtools_conn_gone
5:  lea rdi, [rbx + IC_rbuf]
    call sb_free
    lea rdi, [rbx + IC_msg]
    call sb_free
    lea rdi, [rbx + IC_wq]
    call sb_free
    mov rdi, rbx
    call conn_reset
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# on_conn(fd, revents, IC*): what waits goes out; what came is read (at most READS x READ_STEP) and handled
on_conn:
    PROLOGUE
    mov rbx, rdx
    mov eax, [rbx + IC_state]
    cmp eax, ICS_FREE
    je 9f
    cmp eax, ICS_DEAD
    je 9f
    mov rdi, rbx
    call flush
    cmp dword ptr [rbx + IC_state], ICS_DEAD
    je 9f
    mov r13d, READS
1:  mov rax, [rbx + IC_rbuf + SB_len]
    cmp rax, MSG_MAX + 65536
    jae .Loc_full
    lea rdi, [rbx + IC_rbuf]
    mov esi, READ_STEP
    call sb_reserve
    mov edi, [rbx + IC_fd]
    mov rsi, rax
    mov edx, READ_STEP
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 3f
    test rax, rax
    jle .Loc_gone
    add [rbx + IC_rbuf + SB_len], rax
    dec r13d
    jnz 1b
3:  cmp dword ptr [rbx + IC_state], ICS_CLOSING
    jne 4f
    mov qword ptr [rbx + IC_rbuf + SB_len], 0     # a closing connection's input is dropped
    jmp 9f
4:  mov rdi, rbx
    call handle
    jmp 9f
.Loc_full:
    mov rdi, rbx                # cannot happen with the frame cap; a safety net
    mov esi, 1009
    call close_with
    jmp 9f
.Loc_gone:
    mov dword ptr [rbx + IC_state], ICS_DEAD
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# handle(IC*): the upgrade request, or the frames read
handle:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + IC_state], ICS_HANDSHAKE
    jne 1f
    call handshake
    cmp dword ptr [rbx + IC_state], ICS_OPEN
    jne 9f
1:  cmp dword ptr [rbx + IC_state], ICS_OPEN
    jne 9f
    mov rdi, rbx
    call frames
9:  EPILOGUE

# ---------------- the handshake ----------------

# handshake(IC*): a whole request (an empty line ends it) checked: GET, Upgrade websocket, Connection
#   upgrade, version 13, a key, the token. Then 101 and the connection is the client; else 401 or 400
handshake:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, [rbx + IC_rbuf + SB_ptr]
    mov r13, [rbx + IC_rbuf + SB_len]
    mov rdi, r12
    mov rsi, r13
    cmp rsi, HS_MAX
    jbe 1f
    mov esi, HS_MAX
1:  lea rdx, [rip + .Lcrlf2]
    mov ecx, 4
    call str_find
    test rax, rax
    jns 2f
    cmp r13, HS_MAX
    jb 9f                       # more to come
    jmp .Lhs_bad
2:  lea r14, [rax + 4]          # the request's length
    mov [rsp], r14
    # GET
    cmp r14, 16
    jb .Lhs_bad
    cmp dword ptr [r12], 0x20544547     # "GET "
    jne .Lhs_bad
    # the headers
    mov rdi, rbx
    lea rsi, [rip + .Lh_upgrade]
    call header
    test rax, rax
    jz .Lhs_bad
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_websocket]
    mov ecx, 9
    call str_ifind
    test rax, rax
    js .Lhs_bad
    mov rdi, rbx
    lea rsi, [rip + .Lh_connection]
    call header
    test rax, rax
    jz .Lhs_bad
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_upgrade]
    mov ecx, 7
    call str_ifind
    test rax, rax
    js .Lhs_bad
    mov rdi, rbx
    lea rsi, [rip + .Lh_version]
    call header
    cmp rdx, 2
    jne .Lhs_bad
    cmp word ptr [rax], 0x3331          # "13"
    jne .Lhs_bad
    mov rdi, rbx
    lea rsi, [rip + .Lh_key]
    call header
    test rdx, rdx
    jz .Lhs_bad
    cmp rdx, 64
    ja .Lhs_bad
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    # the token, in constant time
    mov rdi, rbx
    lea rsi, [rip + .Lh_auth]
    call header
    cmp rdx, 36
    jne .Lhs_unauthorized
    xor ecx, ecx
    xor r8d, r8d
    lea r9, [rip + token]
3:  movzx r10d, byte ptr [rax + rcx]
    xor r10b, [r9 + rcx]
    or r8d, r10d
    inc ecx
    cmp ecx, 36
    jb 3b
    test r8d, r8d
    jnz .Lhs_unauthorized
    # the subprotocol: "mcp" when it is asked for
    mov dword ptr [rbx + IC_proto], 0
    mov rdi, rbx
    lea rsi, [rip + .Lh_protocol]
    call header
    test rax, rax
    jz 4f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_mcp]
    mov ecx, 3
    call str_ifind
    test rax, rax
    js 4f
    mov dword ptr [rbx + IC_proto], 1
4:  # Sec-WebSocket-Accept: Base64(SHA-1(key + GUID))
    lea rdi, [rip + resp]
    call sb_clear
    lea rdi, [rip + resp]
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    call sb_push
    lea rdi, [rip + resp]
    lea rsi, [rip + .Lguid]
    call sb_push_cstr
    mov rdi, [rip + resp + SB_ptr]
    mov rsi, [rip + resp + SB_len]
    lea rdx, [rip + hbuf]
    call sha1
    lea rdi, [rip + hbuf]
    mov esi, 20
    lea rdx, [rip + hbuf + 32]
    call b64_encode
    mov [rsp + 24], rax
    lea rdi, [rip + resp]
    call sb_clear
    lea rdi, [rip + resp]
    lea rsi, [rip + .Lr_101]
    call sb_push_cstr
    lea rdi, [rip + resp]
    lea rsi, [rip + hbuf + 32]
    mov rdx, [rsp + 24]
    call sb_push
    cmp dword ptr [rbx + IC_proto], 0
    je 5f
    lea rdi, [rip + resp]
    lea rsi, [rip + .Lr_proto]
    call sb_push_cstr
5:  lea rdi, [rip + resp]
    lea rsi, [rip + .Lr_end]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + resp + SB_ptr]
    mov rdx, [rip + resp + SB_len]
    call send_raw
    cmp dword ptr [rbx + IC_state], ICS_DEAD
    je 9f
    mov rax, [rsp]
    mov [rbx + IC_roff], rax
    mov dword ptr [rbx + IC_state], ICS_OPEN
    mov qword ptr [rbx + IC_deadline], 0
    # the client from now on: an older one is told to go (as the extension does)
    mov r15, [rip + active]
    mov [rip + active], rbx
    test r15, r15
    jz 6f
    cmp dword ptr [r15 + IC_state], ICS_OPEN
    jne 6f
    mov rdi, r15
    mov esi, 4001
    lea rdx, [rip + .Lreason_other]
    call close_reason
6:  call time_ms
    add rax, RESEND_MS
    mov [rbx + IC_resend], rax
    call edtool_selection_key
    mov [rip + sel_key], rax
    mov qword ptr [rip + sel_due], 0
    EPILOGUE
.Lhs_unauthorized:
    lea rsi, [rip + .Lr_401]
    jmp .Lhs_refuse
.Lhs_bad:
    lea rsi, [rip + .Lr_400]
.Lhs_refuse:
    inc qword ptr [rip + n_refused]
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call send_raw
    cmp dword ptr [rbx + IC_state], ICS_DEAD
    je 9f
    mov dword ptr [rbx + IC_state], ICS_CLOSING
    call time_ms
    add rax, CLOSE_MS
    mov [rbx + IC_deadline], rax
    mov rdi, rbx
    call close_if_sent
9:  EPILOGUE

# header(IC*, name cstr) -> rax the value (blanks trimmed), rdx its length; rax 0 when the request has
#   no such header (names ignore case; only the request's lines are read)
header:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call strlen
    mov r13, rax                # the name's length
    mov r14, [rbx + IC_rbuf + SB_ptr]
    mov rdi, r14
    mov rsi, [rbx + IC_rbuf + SB_len]
    lea rdx, [rip + .Lcrlf2]
    mov ecx, 4
    call str_find
    lea r15, [r14 + rax + 2]    # the request's end (the last line's CR LF included)
    # line by line, the first (the request line) skipped
1:  mov rdi, r14
    mov rsi, r15
    sub rsi, r14
    lea rdx, [rip + .Lcrlf2 + 2]
    mov ecx, 2
    call str_find
    test rax, rax
    js 8f
    lea r14, [r14 + rax + 2]    # the next line
    cmp r14, r15
    jae 8f
    # its end
    mov rdi, r14
    mov rsi, r15
    sub rsi, r14
    lea rdx, [rip + .Lcrlf2 + 2]
    mov ecx, 2
    call str_find
    test rax, rax
    js 8f
    mov [rsp], rax              # the line's length
    lea rcx, [r13 + 1]
    cmp rax, rcx
    jb 1b
    cmp byte ptr [r14 + r13], ':'
    jne 1b
    mov rdi, r14
    mov rsi, r13
    mov rdx, r12
    call str_ieq_cstr
    test eax, eax
    jz 1b
    lea rax, [r14 + r13 + 1]    # the value, blanks trimmed
    mov rdx, [rsp]
    sub rdx, r13
    dec rdx
2:  test rdx, rdx
    jz 3f
    cmp byte ptr [rax], ' '
    je 21f
    cmp byte ptr [rax], 9
    jne 3f
21: inc rax
    dec rdx
    jmp 2b
3:  test rdx, rdx
    jz 9f
    cmp byte ptr [rax + rdx - 1], ' '
    je 31f
    cmp byte ptr [rax + rdx - 1], 9
    jne 9f
31: dec rdx
    jmp 3b
8:  xor eax, eax
    xor edx, edx
9:  EPILOGUE

# str_ieq_cstr(ptr, len, cstr) -> eax 1 when equal, ASCII case ignored
str_ieq_cstr:
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 3f
    movzx eax, byte ptr [rdi + rcx]
    movzx r8d, byte ptr [rdx + rcx]
    test r8d, r8d
    jz 8f
    or eax, 0x20
    or r8d, 0x20
    cmp eax, r8d
    jne 8f
    inc rcx
    jmp 1b
3:  cmp byte ptr [rdx + rcx], 0
    jne 8f
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# ---------------- frames ----------------

# frames(IC*): every whole frame read is handled (RFC 6455 5.2: masked, no extension bits, control frames
#   whole and short, fragments in order)
frames:
    PROLOGUE 48
    mov rbx, rdi
.Lfr_next:
    cmp dword ptr [rbx + IC_state], ICS_OPEN
    jne .Lfr_done
    mov r12, [rbx + IC_rbuf + SB_ptr]
    add r12, [rbx + IC_roff]
    mov r13, [rbx + IC_rbuf + SB_len]
    sub r13, [rbx + IC_roff]    # bytes left
    cmp r13, 2
    jb .Lfr_done
    movzx eax, byte ptr [r12]
    mov [rsp], eax              # FIN, opcode
    movzx ecx, byte ptr [r12 + 1]
    test eax, 0x70
    jnz .Lfr_proto
    test ecx, 0x80
    jz .Lfr_proto               # a client's frame must be masked
    and ecx, 0x7f
    mov r14d, 2                 # the header's length so far
    cmp ecx, 126
    jb 2f
    je 1f
    cmp r13, 10
    jb .Lfr_done
    mov rcx, [r12 + 2]
    bswap rcx
    test rcx, rcx
    js .Lfr_proto
    mov r14d, 10
    jmp 2f
1:  cmp r13, 4
    jb .Lfr_done
    movzx eax, byte ptr [r12 + 2]
    shl eax, 8
    movzx ecx, byte ptr [r12 + 3]
    or ecx, eax
    mov r14d, 4
2:  mov r15, rcx                # the payload's length
    mov eax, [rsp]
    and eax, 15
    mov [rsp + 4], eax          # the opcode
    cmp eax, 8
    jb 3f
    test dword ptr [rsp], 0x80  # control: whole, at most 125 bytes
    jz .Lfr_proto
    cmp r15, 125
    ja .Lfr_proto
    jmp 4f
3:  mov rax, [rbx + IC_msg + SB_len]    # data: the message within the cap
    add rax, r15
    cmp rax, MSG_MAX
    ja .Lfr_big
4:  lea rax, [r14 + 4]
    add rax, r15
    cmp r13, rax
    jb .Lfr_done                # not all here yet
    add [rbx + IC_roff], rax
    # unmask in place
    lea rsi, [r12 + r14]        # the mask
    lea rdi, [rsi + 4]          # the payload
    mov [rsp + 8], rdi
    xor ecx, ecx
5:  cmp rcx, r15
    jae 6f
    mov eax, ecx
    and eax, 3
    movzx eax, byte ptr [rsi + rax]
    xor [rdi + rcx], al
    inc rcx
    jmp 5b
6:  mov eax, [rsp + 4]
    cmp eax, 0
    je .Lfr_cont
    cmp eax, 1
    je .Lfr_data
    cmp eax, 2
    je .Lfr_data
    cmp eax, 8
    je .Lfr_close
    cmp eax, 9
    je .Lfr_ping
    cmp eax, 10
    je .Lfr_next                # a pong
    jmp .Lfr_proto
.Lfr_data:
    cmp dword ptr [rbx + IC_mop], 0
    jne .Lfr_proto              # a new message inside a fragmented one
    test dword ptr [rsp], 0x80
    jz 7f
    mov rdi, rbx                # whole: handled where it lies
    mov rsi, [rsp + 8]
    mov rdx, r15
    call message
    jmp .Lfr_next
7:  mov eax, [rsp + 4]
    mov [rbx + IC_mop], eax
    lea rdi, [rbx + IC_msg]
    call sb_clear
    lea rdi, [rbx + IC_msg]
    mov rsi, [rsp + 8]
    mov rdx, r15
    call sb_push
    jmp .Lfr_next
.Lfr_cont:
    cmp dword ptr [rbx + IC_mop], 0
    je .Lfr_proto
    lea rdi, [rbx + IC_msg]
    mov rsi, [rsp + 8]
    mov rdx, r15
    call sb_push
    test dword ptr [rsp], 0x80
    jz .Lfr_next
    mov dword ptr [rbx + IC_mop], 0
    mov rdi, rbx
    mov rsi, [rbx + IC_msg + SB_ptr]
    mov rdx, [rbx + IC_msg + SB_len]
    call message
    lea rdi, [rbx + IC_msg]
    call sb_clear
    jmp .Lfr_next
.Lfr_ping:
    mov rdi, rbx
    mov esi, 10
    mov rdx, [rsp + 8]
    mov rcx, r15
    call send_frame
    jmp .Lfr_next
.Lfr_close:
    # its code back (or none), and the connection ends
    xor esi, esi
    cmp r15, 2
    jb 8f
    mov rax, [rsp + 8]
    movzx esi, byte ptr [rax]
    shl esi, 8
    movzx ecx, byte ptr [rax + 1]
    or esi, ecx
8:  mov rdi, rbx
    lea rdx, [rip + .Lempty]
    call close_reason
    jmp .Lfr_done
.Lfr_proto:
    mov rdi, rbx
    mov esi, 1002
    call close_with
    jmp .Lfr_done
.Lfr_big:
    mov rdi, rbx
    mov esi, 1009
    call close_with
.Lfr_done:
    # what was parsed goes
    mov rax, [rbx + IC_roff]
    test rax, rax
    jz 9f
    mov rdx, [rbx + IC_rbuf + SB_len]
    sub rdx, rax
    jbe 91f
    mov rdi, [rbx + IC_rbuf + SB_ptr]
    lea rsi, [rdi + rax]
    mov [rbx + IC_rbuf + SB_len], rdx
    call memmove
    mov qword ptr [rbx + IC_roff], 0
    jmp 9f
91: mov qword ptr [rbx + IC_rbuf + SB_len], 0
    mov qword ptr [rbx + IC_roff], 0
9:  EPILOGUE

# message(IC*, ptr, len): one JSON-RPC message: answered now, later, or not at all
message:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    inc qword ptr [rip + n_in]
    mov rdi, r12
    mov rsi, r13
    mov edx, 1000000            # values
    mov ecx, 64                 # depth
    call json_parse_lim
    test rax, rax
    jz 9f                       # not JSON: dropped, as the extension's transport drops it
    mov r14, rax
    # the method, kept for print-ide
    mov rdi, r14
    lea rsi, [rip + .Lk_method]
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jz 1f
    cmp rdx, 63
    jbe 11f
    mov edx, 63
11: lea rdi, [rip + last_method]
    mov rsi, rax
    mov [rsp], rdx
    call memcpy
    mov rdx, [rsp]
    lea rax, [rip + last_method]
    mov byte ptr [rax + rdx], 0
1:  # its token: the transport, the connection, the call
    inc dword ptr [rbx + IC_seq]
    mov eax, [rbx + IC_seq]
    and eax, 0xfffff
    jnz 2f
    mov eax, 1
2:  mov rcx, [rbx + IC_gen]
    shl rcx, 20
    or rcx, rax
    mov rax, MCPT_IDE
    shl rax, 56
    or rcx, rax
    mov [rsp + 8], rcx
    lea rdi, [rip + edtool_ms]
    mov rsi, r14
    lea rdx, [rip + resp]
    call mcp_handle
    cmp eax, 1
    je 3f
    cmp eax, 2
    jne 9f
    # a tool answers later: its id kept
    lea r15, [rip + pend]
    xor ecx, ecx
4:  cmp qword ptr [r15 + PL_token], 0
    je 5f
    add r15, PL_SIZE
    inc ecx
    cmp ecx, PL_MAX
    jb 4b
    jmp 9f                      # cannot happen: openDiff's own limit is lower
5:  mov rdi, [rip + resp + SB_ptr]
    mov rsi, [rip + resp + SB_len]
    mov [r15 + PL_idlen], rsi
    call mem_dup
    mov [r15 + PL_id], rax
    mov rax, [rsp + 8]
    mov [r15 + PL_token], rax
    jmp 9f
3:  mov rdi, rbx
    mov esi, 1
    mov rdx, [rip + resp + SB_ptr]
    mov rcx, [rip + resp + SB_len]
    call send_frame
9:  EPILOGUE

# FN ide_later_done(token, sb, flags): the late answer of that call, to its connection if it is still open
FN ide_later_done
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    lea rbx, [rip + pend]
    xor ecx, ecx
1:  cmp [rbx + PL_token], r12
    je 2f
    add rbx, PL_SIZE
    inc ecx
    cmp ecx, PL_MAX
    jb 1b
    jmp 9f
2:  mov qword ptr [rbx + PL_token], 0
    mov r15, r12                # the connection: the token's generation
    shl r15, 8
    shr r15, 28
    lea rax, [rip + conns]
    xor ecx, ecx
3:  cmp [rax + IC_gen], r15
    jne 31f
    cmp dword ptr [rax + IC_state], ICS_OPEN
    je 4f
31: add rax, IC_SIZE
    inc ecx
    cmp ecx, IC_MAX
    jb 3b
    jmp 8f
4:  mov r15, rax
    lea rdi, [rip + resp2]
    mov rsi, [rbx + PL_id]
    mov rdx, [rbx + PL_idlen]
    mov rcx, r13
    mov r8d, r14d
    call mcp_result
    mov rdi, r15
    mov esi, 1
    mov rdx, [rip + resp2 + SB_ptr]
    mov rcx, [rip + resp2 + SB_len]
    call send_frame
8:  mov rdi, [rbx + PL_id]
    call mem_free
    mov qword ptr [rbx + PL_id], 0
9:  EPILOGUE

# ---------------- sending ----------------

# send_frame(IC*, opcode, ptr, len): one whole frame, unmasked
send_frame:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, 8
    jae 1f
    inc qword ptr [rip + n_out]
1:  lea rdi, [rip + hbuf]
    mov eax, r12d
    or eax, 0x80
    mov [rdi], al
    cmp r14, 126
    jae 2f
    mov [rdi + 1], r14b
    mov edx, 2
    jmp 4f
2:  cmp r14, 65536
    jae 3f
    mov byte ptr [rdi + 1], 126
    mov eax, r14d
    mov [rdi + 3], al
    shr eax, 8
    mov [rdi + 2], al
    mov edx, 4
    jmp 4f
3:  mov byte ptr [rdi + 1], 127
    mov rax, r14
    bswap rax
    mov [rdi + 2], rax
    mov edx, 10
4:  mov rdi, rbx
    lea rsi, [rip + hbuf]
    push r13
    push r14
    call queue
    pop rdx
    pop rsi
    mov rdi, rbx
    call send_raw
    EPILOGUE

# queue(IC*, ptr, len): onto its queue, unless that would pass the cap (then it is dropped)
queue:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + IC_state], ICS_DEAD
    je 9f
    cmp dword ptr [rbx + IC_state], ICS_FREE
    je 9f
    mov rax, [rbx + IC_wq + SB_len]
    sub rax, [rbx + IC_woff]
    add rax, rdx
    cmp rax, WQ_MAX
    ja 8f
    lea rdi, [rbx + IC_wq]
    call sb_push
    EPILOGUE
8:  mov dword ptr [rbx + IC_state], ICS_DEAD
9:  EPILOGUE

# send_raw(IC*, ptr, len): queued and written as far as the socket takes it
send_raw:
    PROLOGUE
    mov rbx, rdi
    call queue
    mov rdi, rbx
    call flush
    EPILOGUE

# flush(IC*): its queue written as far as the socket takes it; POLLOUT watched while some is left; a
#   closing connection whose queue is empty ends
flush:
    PROLOGUE
    mov rbx, rdi
1:  mov eax, [rbx + IC_state]
    cmp eax, ICS_DEAD
    je 9f
    cmp eax, ICS_FREE
    je 9f
    mov rsi, [rbx + IC_wq + SB_ptr]
    add rsi, [rbx + IC_woff]
    mov rdx, [rbx + IC_wq + SB_len]
    sub rdx, [rbx + IC_woff]
    jz 5f
    mov edi, [rbx + IC_fd]
    SYS SYS_write
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 4f
    test rax, rax
    js 8f
    add [rbx + IC_woff], rax
    jmp 1b
4:  mov esi, POLLIN | POLLOUT
    jmp 6f
5:  mov qword ptr [rbx + IC_wq + SB_len], 0
    mov qword ptr [rbx + IC_woff], 0
    cmp dword ptr [rbx + IC_state], ICS_CLOSING
    jne 51f
    mov dword ptr [rbx + IC_state], ICS_DEAD
    jmp 9f
51: mov esi, POLLIN
6:  cmp [rbx + IC_events], esi
    je 9f
    mov [rbx + IC_events], esi
    mov edi, [rbx + IC_fd]
    call watch_set_events
    jmp 9f
8:  mov dword ptr [rbx + IC_state], ICS_DEAD
9:  EPILOGUE

# close_with(IC*, code): a close frame with that code, then the connection ends
close_with:
    lea rdx, [rip + .Lempty]
    jmp close_reason

# close_reason(IC*, code or 0, reason cstr): a close frame (the code and reason, or empty for 0), then the
#   connection ends once it went out (CLOSE_MS at most)
close_reason:
    PROLOGUE 144
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov eax, [rbx + IC_state]
    cmp eax, ICS_OPEN
    je 1f
    cmp eax, ICS_HANDSHAKE
    jne 9f
1:  xor r14d, r14d
    test r12d, r12d
    jz 2f
    mov eax, r12d
    mov [rsp + 1], al
    shr eax, 8
    mov [rsp], al
    mov r14d, 2
    mov rdi, r13
    call strlen
    cmp rax, 120
    jbe 11f
    mov eax, 120
11: lea rdi, [rsp + 2]
    mov rsi, r13
    mov rdx, rax
    add r14, rax
    call memcpy
2:  mov rdi, rbx
    mov esi, 8
    lea rdx, [rsp]
    mov rcx, r14
    call send_frame
    cmp dword ptr [rbx + IC_state], ICS_DEAD
    je 9f
    mov dword ptr [rbx + IC_state], ICS_CLOSING
    call time_ms
    add rax, CLOSE_MS
    mov [rbx + IC_deadline], rax
    mov qword ptr [rbx + IC_resend], 0
    mov rdi, rbx
    call close_if_sent
    cmp rbx, [rip + active]
    jne 9f
    mov qword ptr [rip + active], 0
9:  EPILOGUE

# close_if_sent(IC*): a closing connection with nothing left to send ends
close_if_sent:
    mov rax, [rdi + IC_wq + SB_len]
    cmp rax, [rdi + IC_woff]
    ja 1f
    cmp dword ptr [rdi + IC_state], ICS_CLOSING
    jne 1f
    mov dword ptr [rdi + IC_state], ICS_DEAD
1:  ret

# note(method cstr, params sb): {"jsonrpc":"2.0","method":M,"params":P} to the client
note:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rbx, [rip + active]
    test rbx, rbx
    jz 9f
    cmp dword ptr [rbx + IC_state], ICS_OPEN
    jne 9f
    lea rdi, [rip + resp2]
    call sb_clear
    lea rdi, [rip + resp2]
    lea rsi, [rip + .Lnote_head]
    call sb_push_cstr
    lea rdi, [rip + resp2]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + resp2]
    lea rsi, [rip + .Lnote_params]
    call sb_push_cstr
    lea rdi, [rip + resp2]
    mov rsi, [r13 + SB_ptr]
    mov rdx, [r13 + SB_len]
    call sb_push
    lea rdi, [rip + resp2]
    mov esi, '}'
    call sb_push_byte
    inc qword ptr [rip + n_notes]
    mov rdi, rbx
    mov esi, 1
    mov rdx, [rip + resp2 + SB_ptr]
    mov rcx, [rip + resp2 + SB_len]
    call send_frame
9:  EPILOGUE

# send_selection(): selection_changed when the selection differs from the one sent last
send_selection:
    PROLOGUE
    lea rdi, [rip + selb]
    call edtool_selection
    test eax, eax
    jz 9f
    mov rax, [rip + selb + SB_len]
    cmp rax, [rip + last_sel + SB_len]
    jne 1f
    mov rdi, [rip + selb + SB_ptr]
    mov rsi, [rip + last_sel + SB_ptr]
    mov rdx, rax
    call memeq
    test eax, eax
    jnz 9f
1:  lea rdi, [rip + last_sel]
    call sb_clear
    lea rdi, [rip + last_sel]
    mov rsi, [rip + selb + SB_ptr]
    mov rdx, [rip + selb + SB_len]
    call sb_push
    lea rdi, [rip + .Lm_selection]
    lea rsi, [rip + last_sel]
    call note
9:  EPILOGUE

# send_selection_now(): a new client hears the selection as it is (or the last one sent, when no file shows)
send_selection_now:
    PROLOGUE
    lea rdi, [rip + selb]
    call edtool_selection
    test eax, eax
    jz 1f
    lea rdi, [rip + last_sel]
    call sb_clear
    lea rdi, [rip + last_sel]
    mov rsi, [rip + selb + SB_ptr]
    mov rdx, [rip + selb + SB_len]
    call sb_push
1:  cmp qword ptr [rip + last_sel + SB_len], 0
    je 9f
    lea rdi, [rip + .Lm_selection]
    lea rsi, [rip + last_sel]
    call note
9:  EPILOGUE

# ---------------- for the rest of rhun ----------------

# FN ide_port() -> eax
FN ide_port
    mov eax, [rip + lport]
    ret

# FN ide_connected() -> eax 1 while a claude is connected
FN ide_connected
    xor eax, eax
    mov rcx, [rip + active]
    test rcx, rcx
    jz 1f
    cmp dword ptr [rcx + IC_state], ICS_OPEN
    sete al
1:  ret

# FN ide_mention() -> eax 1 when at_mentioned went to the connected claude (the active file, and its lines
#   when text is selected)
FN ide_mention
    PROLOGUE
    call ide_connected
    test eax, eax
    jz 9f
    lea rdi, [rip + selb]
    call edtool_mention
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lm_mention]
    lea rsi, [rip + selb]
    call note
    mov eax, 1
9:  EPILOGUE

# print-ide: "ide on=0|1 port=N lock=PATH token=0|1 conns=N refused=N in=N out=N notes=N client=GEN|none
#   method=M", a line per connection ("conn GEN state=… proto=0|1 queued=N"), edtools' diffs waiting, then
#   "selection=PARAMS" (the last sent)
c_print_ide:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Ld_on]
    call sb_push_cstr
    xor esi, esi
    cmp dword ptr [rip + lfd], 0
    setge sil
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_port]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + lport]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_lock]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + lock_path]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_conns]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + n_conns]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_refused]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + n_refused]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_in]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + n_in]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_out]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + n_out]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_notes]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + n_notes]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_client]
    call sb_push_cstr
    call ide_connected
    test eax, eax
    jz 1f
    mov rax, [rip + active]
    mov rdi, rbx
    mov rsi, [rax + IC_gen]
    call sb_push_u64
    jmp 2f
1:  mov rdi, rbx
    lea rsi, [rip + .Ld_none]
    call sb_push_cstr
2:  mov rdi, rbx
    lea rsi, [rip + .Ld_method]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + last_method]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_calls]
    call sb_push_cstr
    call mcp_calls
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    lea r12, [rip + conns]
    xor r13d, r13d
3:  mov eax, [r12 + IC_state]
    cmp eax, ICS_FREE
    je 4f
    mov rdi, rbx
    lea rsi, [rip + .Ld_conn]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r12 + IC_gen]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    mov eax, [r12 + IC_state]
    lea rcx, [rip + state_words]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_proto]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r12 + IC_proto]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_queued]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r12 + IC_wq + SB_len]
    sub rsi, [r12 + IC_woff]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
4:  add r12, IC_SIZE
    inc r13d
    cmp r13d, IC_MAX
    jb 3b
    mov rdi, rbx
    call edtools_dump
    mov rdi, rbx
    lea rsi, [rip + .Ld_selection]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + last_sel + SB_ptr]
    mov rdx, [rip + last_sel + SB_len]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

# ide-mention: Claude: Insert @-Mention in Terminal's at_mentioned (prints "sent=0|1")
c_ide_mention:
    PROLOGUE
    mov rbx, rdi
    call ide_mention
    mov r12d, eax
    mov rdi, rbx
    lea rsi, [rip + .Ld_sent]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

.section .rodata
.Lhex: .ascii "0123456789abcdef"
.Lenv_name: .asciz "CLAUDE_CODE_SSE_PORT="
.Lslash_ide: .asciz "/ide"
.Ldot_lock: .asciz ".lock"
.Lk_pid: .asciz "pid"
.Lk_folders: .asciz "workspaceFolders"
.Lk_ide_name: .asciz "ideName"
.Lk_transport: .asciz "transport"
.Lk_windows: .asciz "runningInWindows"
.Lk_token: .asciz "authToken"
.Lk_method: .asciz "method"
.Lv_rhun: .asciz "rhun"
.Lv_ws: .asciz "ws"
.Lcrlf2: .ascii "\r\n\r\n"
.Lh_upgrade: .asciz "upgrade"
.Lh_connection: .asciz "connection"
.Lh_version: .asciz "sec-websocket-version"
.Lh_key: .asciz "sec-websocket-key"
.Lh_auth: .asciz "x-claude-code-ide-authorization"
.Lh_protocol: .asciz "sec-websocket-protocol"
.Lv_websocket: .ascii "websocket"
.Lv_upgrade: .ascii "upgrade"
.Lv_mcp: .ascii "mcp"
.Lguid: .asciz "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
.Lr_101: .asciz "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
.Lr_proto: .asciz "\r\nSec-WebSocket-Protocol: mcp"
.Lr_end: .asciz "\r\n\r\n"
.Lr_400: .asciz "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
.Lr_401: .asciz "HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
.Lreason_other: .asciz "Another Claude Code session connected to this IDE"
.Lempty: .asciz ""
.Lnote_head: .asciz "{\"jsonrpc\":\"2.0\",\"method\":\""
.Lnote_params: .asciz "\",\"params\":"
.Lm_selection: .asciz "selection_changed"
.Lm_mention: .asciz "at_mentioned"
.Llog_fail: .asciz "rhun: the bridge for terminal claude found no free port on 127.0.0.1\n"
.Llog_lock: .asciz "rhun: the bridge for terminal claude could not write its lock file\n"
.Ld_on: .asciz "ide on="
.Ld_port: .asciz " port="
.Ld_lock: .asciz " lock="
.Ld_conns: .asciz " conns="
.Ld_refused: .asciz " refused="
.Ld_in: .asciz " in="
.Ld_out: .asciz " out="
.Ld_notes: .asciz " notes="
.Ld_client: .asciz " client="
.Ld_none: .asciz "none"
.Ld_method: .asciz " method="
.Ld_calls: .asciz " calls="
.Ld_conn: .asciz "conn "
.Ld_state: .asciz " state="
.Ld_proto: .asciz " proto="
.Ld_queued: .asciz " queued="
.Ld_selection: .asciz "selection="
.Ld_sent: .asciz "sent="
.Lc_print_ide: .asciz "print-ide"
.Lc_ide_mention: .asciz "ide-mention"
.Lw_free: .asciz "free"
.Lw_handshake: .asciz "handshake"
.Lw_open: .asciz "open"
.Lw_closing: .asciz "closing"
.Lw_dead: .asciz "dead"
.p2align 3
state_words: .quad .Lw_free, .Lw_handshake, .Lw_open, .Lw_closing, .Lw_dead
.globl ide_ctl
ide_ctl:
    .quad .Lc_print_ide, c_print_ide
    .quad .Lc_ide_mention, c_ide_mention
    .quad 0, 0
