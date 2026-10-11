# holders (spec 5.4): who else holds an agent session. rhun's own children are never holders; a
# record it cannot prove stale is one; a record or file it cannot read makes the answer unknown.
.include "rhun.inc"

.bss
.p2align 3
own: .zero 4 * 64
nown: .long 0
.p2align 3
hc_sid: .quad 0             # the session looked for (cstr)
hc_dir: .quad 0             # the directory being scanned
hc_result: .long 0          # HOLDER_* so far; UNKNOWN sticks
.section .rodata
.Lk_sessionId: .asciz "sessionId"
.Lk_pid: .asciz "pid"
.Lk_pidDomain: .asciz "pidDomain"
.Lk_session_id: .asciz "session_id"
.Lclaude_cfg: .asciz "CLAUDE_CONFIG_DIR"
.Lgrok_home: .asciz "GROK_HOME"
.Lhome: .asciz "HOME"
.Ldot_claude: .asciz ".claude"
.Ldot_grok: .asciz ".grok"
.Lsessions: .asciz "sessions"
.Lactive: .asciz "active_sessions.json"
.Ljson_ext: .ascii ".json"
.ifdef MACOS
.Ldomain: .asciz "darwin"
.else
.Ldomain: .asciz "linux"
.endif
.text

# holder_own_add(pid): one of rhun's own agent children (at most 64 are remembered)
FN holder_own_add
    mov eax, [rip + nown]
    cmp eax, 64
    jae 9f
    lea rcx, [rip + own]
    mov [rcx + rax*4], edi
    inc dword ptr [rip + nown]
9:  ret

# holder_own_remove(pid): the child has gone
FN holder_own_remove
    lea rcx, [rip + own]
    xor eax, eax
1:  cmp eax, [rip + nown]
    jae 9f
    cmp [rcx + rax*4], edi
    je 2f
    inc eax
    jmp 1b
2:  dec dword ptr [rip + nown]
    mov edx, [rip + nown]
    mov edx, [rcx + rdx*4]
    mov [rcx + rax*4], edx
9:  ret

# own_pid(pid) -> 1 if it is one of rhun's children
own_pid:
    lea rcx, [rip + own]
    xor eax, eax
1:  cmp eax, [rip + nown]
    jae 8f
    cmp [rcx + rax*4], edi
    je 9f
    inc eax
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

.ifndef WINDOWS
# pid_alive(pid) -> 1 if a process has the pid (kill 0 succeeds or is refused for permission)
pid_alive:
    xor esi, esi
    SYS SYS_kill
    test rax, rax
    jz 9f
    cmp rax, -EPERM
    je 9f
    xor eax, eax
    ret
9:  mov eax, 1
    ret

# num(jv) -> rax value, rdx 1 when jv is a number that starts with a digit
num:
    test rdi, rdi
    jz 8f
    cmp dword ptr [rdi + JV_type], JT_NUM
    jne 8f
    mov esi, [rdi + JV_n]
    mov rdi, [rdi + JV_ptr]
    call parse_u64
    test rdx, rdx
    jz 8f
    mov edx, 1
    ret
8:  xor eax, eax
    xor edx, edx
    ret

# judge(record jv, sid key, pid key, domain key or 0): fold one record into hc_result
judge:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, rbx
    mov rsi, r12
    call json_get
    mov rdi, rax
    mov rsi, [rip + hc_sid]
    call json_is
    test eax, eax
    jz 9f                       # another session
    mov rdi, rbx
    mov rsi, r13
    call json_get
    mov rdi, rax
    call num
    test edx, edx
    jz .Ljudge_unknown
    mov r15, rax
    test r14, r14
    jz 1f
    mov rdi, rbx
    mov rsi, r14
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 1f                      # no platform named: judge the pid here
    mov rdi, r12
    lea rsi, [rip + .Ldomain]
    call json_is
    test eax, eax
    jz 9f                       # another machine's record
1:  mov edi, r15d
    call own_pid
    test eax, eax
    jnz 9f
    mov edi, r15d
    call pid_alive
    test eax, eax
    jz 9f
    cmp dword ptr [rip + hc_result], HOLDER_UNKNOWN
    je 9f
    mov dword ptr [rip + hc_result], HOLDER_OTHER
    jmp 9f
.Ljudge_unknown:
    mov dword ptr [rip + hc_result], HOLDER_UNKNOWN
9:  EPILOGUE

# claude_file(ctx, name): one file of ~/.claude/sessions
claude_file:
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
    call file_read_all
    test rax, rax
    jnz 1f
    cmp rdx, -2                 # ENOENT: the session ended between listing and reading
    je 9f
    jmp 8f
1:  mov r12, rax
    mov rdi, rax
    mov rsi, rdx
    call json_parse
    test rax, rax
    jz 7f
    mov rdi, rax                # numbers point into the text: free it after judging
    lea rsi, [rip + .Lk_sessionId]
    lea rdx, [rip + .Lk_pid]
    lea rcx, [rip + .Lk_pidDomain]
    call judge
    mov rdi, r12
    call mem_free
    jmp 9f
7:  mov rdi, r12
    call mem_free
8:  mov dword ptr [rip + hc_result], HOLDER_UNKNOWN
9:  EPILOGUE

# base_dir(var, default under HOME, sb) -> 1 with the directory in sb, 0 without a home
base_dir:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r13
    call sb_clear
    mov rdi, rbx
    call getenv
    test rax, rax
    jz 1f
    mov rdi, r13
    mov rsi, rax
    call sb_push_cstr
    jmp 2f
1:  lea rdi, [rip + .Lhome]
    call getenv
    test rax, rax
    jz 8f
    mov rdi, r13
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r13
    mov esi, '/'
    call sb_push_byte
    mov rdi, r13
    mov rsi, r12
    call sb_push_cstr
2:  mov rdi, r13
    xor esi, esi
    call sb_push_byte           # NUL-terminate without counting it
    dec qword ptr [r13 + SB_len]
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
.bss
.p2align 3
hc_buf: .zero SB_SIZE
.text

# holder_claude(sid) -> HOLDER_*
FN holder_claude
    PROLOGUE
    mov [rip + hc_sid], rdi
    mov dword ptr [rip + hc_result], HOLDER_NONE
    lea rdi, [rip + .Lclaude_cfg]
    lea rsi, [rip + .Ldot_claude]
    lea rdx, [rip + hc_buf]
    call base_dir
    test eax, eax
    jz 8f
    mov rdi, [rip + hc_buf + SB_ptr]
    lea rsi, [rip + .Lsessions]
    call path_join
    mov [rip + hc_dir], rax
    mov rdi, rax
    lea rsi, [rip + claude_file]
    xor edx, edx
    call dir_each_names
    mov rbx, rax
    mov rdi, [rip + hc_dir]
    call mem_free
    test rbx, rbx
    jns 1f
    cmp rbx, -2                 # ENOENT: a missing directory lists nothing, no holders
    jne 8f
1:  mov eax, [rip + hc_result]
    EPILOGUE
8:  mov eax, HOLDER_UNKNOWN
    EPILOGUE

# holder_grok(sid) -> HOLDER_*
FN holder_grok
    PROLOGUE
    mov [rip + hc_sid], rdi
    mov dword ptr [rip + hc_result], HOLDER_NONE
    lea rdi, [rip + .Lgrok_home]
    lea rsi, [rip + .Ldot_grok]
    lea rdx, [rip + hc_buf]
    call base_dir
    test eax, eax
    jz 8f
    mov rdi, [rip + hc_buf + SB_ptr]
    lea rsi, [rip + .Lactive]
    call path_join_tmp
    mov rdi, rax
    call file_read_all
    test rax, rax
    jnz 2f
    cmp rdx, -2                 # ENOENT: no file, nobody active
    je 7f
    jmp 8f
2:  mov r12, rax
    mov rdi, rax
    mov rsi, rdx
    call json_parse
    mov rbx, rax
    mov rdi, rbx
    call json_type
    cmp eax, JT_ARR
    jne 6f                      # unparsable, or not a list of sessions
    xor r13d, r13d
1:  mov rdi, rbx
    call json_len
    cmp r13, rax
    jae 5f
    mov rdi, rbx
    mov rsi, r13
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_session_id]
    lea rdx, [rip + .Lk_pid]
    xor ecx, ecx
    call judge
    inc r13
    jmp 1b
5:  mov rdi, r12                # numbers point into the text: free it after judging
    call mem_free
7:  mov eax, [rip + hc_result]
    EPILOGUE
6:  mov rdi, r12
    call mem_free
8:  mov eax, HOLDER_UNKNOWN
    EPILOGUE
.else
FN holder_claude
    mov eax, HOLDER_UNKNOWN
    ret
FN holder_grok
    mov eax, HOLDER_UNKNOWN
    ret
.endif
