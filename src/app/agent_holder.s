# holders: who else has a Claude Code conversation open. Every claude that runs registers itself in
# <claude dir>/sessions/<pid>.json (its pid, the conversation's sessionId, pidDomain: the system it runs
# on) and removes the file on a clean exit (tests/data/claude-shapes/README.txt). A record of this
# conversation whose process is alive holds it, unless that process is one of rhun's own programs (a live
# connection of agent_conn.s): another rhun window's claude is a holder like a terminal's. A record of
# another system's (pidDomain) or a dead pid holds nothing; a record rhun cannot read makes the answer
# unknown, which the caller takes as none (the records are advisory).
#
#   holder_claude(sid cstr) -> eax HOLDER_NONE, HOLDER_OTHER or HOLDER_UNKNOWN. It parses JSON: the
#     shared arena is reset (a JV* of an earlier parse is invalid afterwards). Windows: HOLDER_NONE
.include "rhun.inc"

.equ RECORD_MAX, 65536      # a session record is a few hundred bytes

.bss
.p2align 3
hc_sid: .quad 0             # the conversation looked for (cstr)
hc_dir: .quad 0             # the sessions folder being listed (owned)
hc_result: .long 0          # HOLDER_* so far; UNKNOWN sticks over NONE, OTHER over both
.p2align 3
hc_buf: .zero SB_SIZE

.section .rodata
.Lk_sessionId: .asciz "sessionId"
.Lk_pid: .asciz "pid"
.Lk_pidDomain: .asciz "pidDomain"
.Lsessions: .asciz "/sessions"
.Ljson_ext: .ascii ".json"
.ifdef MACOS
.Ldomain: .asciz "darwin"
.else
.Ldomain: .asciz "linux"
.endif
.text

.ifndef WINDOWS
# pid_alive(pid) -> eax 1 when a process has the pid (kill 0 succeeds, or is refused for permission)
pid_alive:
    xor esi, esi
    SYS SYS_kill
    test rax, rax
    jz 9f
    cmp rax, -1                 # EPERM
    je 9f
    xor eax, eax
    ret
9:  mov eax, 1
    ret

# record_pid(jv) -> rax the pid, rdx 1 when jv is a positive integer that fits a pid
record_pid:
    push rbx
    call json_int
    test edx, edx
    jz 8f
    test rax, rax
    jle 8f
    cmp rax, 0x7fffffff
    ja 8f
    pop rbx
    ret
8:  xor eax, eax
    xor edx, edx
    pop rbx
    ret

# judge(record jv): one record folded into hc_result. A record without a string session id, or with
#   this conversation's id and no pid, is one rhun cannot read: unknown
judge:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_sessionId]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 7f
    mov rdi, r12
    mov rsi, [rip + hc_sid]
    call json_is
    test eax, eax
    jz 9f                       # another conversation
    mov rdi, rbx
    lea rsi, [rip + .Lk_pid]
    call json_get
    mov rdi, rax
    call record_pid
    test edx, edx
    jz 7f
    mov r13d, eax
    mov rdi, rbx                # a system named, and not this one: another machine's record
    lea rsi, [rip + .Lk_pidDomain]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 1f
    mov rdi, r12
    lea rsi, [rip + .Ldomain]
    call json_is
    test eax, eax
    jz 9f
1:  mov edi, r13d               # rhun's own program: never a holder
    call agent_conn_owns
    test eax, eax
    jnz 9f
    mov edi, r13d
    call pid_alive
    test eax, eax
    jz 9f                       # it ended without removing its record
    mov dword ptr [rip + hc_result], HOLDER_OTHER
    EPILOGUE
7:  cmp dword ptr [rip + hc_result], HOLDER_OTHER
    je 9f
    mov dword ptr [rip + hc_result], HOLDER_UNKNOWN
9:  EPILOGUE

# one_file(ctx, name): dir_each_names' step: a file NAME.json of the sessions folder, read and judged.
#   Only a regular file of RECORD_MAX bytes at most is read: anything else there is no record (skipped)
one_file:
    PROLOGUE
    mov rbx, rsi
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Ljson_ext]
    mov ecx, 5
    call str_ends
    test eax, eax
    jz 9f
    mov rdi, [rip + hc_dir]
    mov rsi, rbx
    call path_join_tmp
    mov rdi, rax
    mov esi, RECORD_MAX
    call file_read_limited
    test rax, rax
    jnz 1f
    cmp rdx, -2                 # ENOENT: the session ended between the listing and the read
    je 9f
    cmp rdx, -22                # not a regular file (a FIFO would never end, a device), a folder, or
    je 9f                       #   larger than a record is: skipped
    cmp rdx, -21
    je 9f
    cmp rdx, -27
    je 9f
    jmp 8f
1:  mov r12, rax
    mov rdi, rax
    mov rsi, rdx
    call json_parse
    test rax, rax
    jz 7f
    mov rdi, rax                # the values point into the text: it is freed after the judging
    call judge
    mov rdi, r12
    call mem_free
    EPILOGUE
7:  mov rdi, r12
    call mem_free
8:  cmp dword ptr [rip + hc_result], HOLDER_OTHER
    je 9f
    mov dword ptr [rip + hc_result], HOLDER_UNKNOWN
9:  EPILOGUE

# FN holder_claude(sid) -> eax HOLDER_* (see the top)
FN holder_claude
    PROLOGUE
    mov [rip + hc_sid], rdi
    mov dword ptr [rip + hc_result], HOLDER_NONE
    lea rdi, [rip + hc_buf]     # the Claude folder by the one rule discovery and the driver use
    call sb_clear
    lea rdi, [rip + hc_buf]
    call claude_dir
    test eax, eax
    jz 8f
    lea rdi, [rip + hc_buf]
    lea rsi, [rip + .Lsessions]
    call sb_push_cstr
    mov rdi, [rip + hc_buf + SB_ptr]
    mov rsi, [rip + hc_buf + SB_len]
    call mem_dup
    mov [rip + hc_dir], rax
    mov rdi, rax
    lea rsi, [rip + one_file]
    xor edx, edx
    call dir_each_names
    mov rbx, rax
    mov rdi, [rip + hc_dir]
    call mem_free
    mov qword ptr [rip + hc_dir], 0
    test rbx, rbx
    jns 1f
    cmp rbx, -2                 # ENOENT: no sessions folder: nobody holds it
    jne 8f
1:  mov eax, [rip + hc_result]
    EPILOGUE
8:  mov eax, HOLDER_UNKNOWN
    EPILOGUE

.else
# Windows: the records name pids rhun does not check there yet
FN holder_claude
    mov eax, HOLDER_NONE
    ret
.endif
