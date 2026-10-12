# holders (spec 5.4): who else holds an agent session. rhun's own children are never holders; a
# record it cannot prove stale is one; a record or file it cannot read makes the answer unknown.
.include "rhun.inc"

.bss
.p2align 3
own: .zero 4 * (CN_MAX + CN_ZOMBIES)     # every live connection and every stopped child
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

# holder_own_add(pid): one of rhun's own agent children (agent_conn.s keeps at most CN_MAX + CN_ZOMBIES)
FN holder_own_add
    mov eax, [rip + nown]
    cmp eax, CN_MAX + CN_ZOMBIES
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
    cmp rdx, -ENOENT            # the session ended between listing and reading
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

# base_dir(var, default under HOME, sb) -> 1 with the directory in sb, 0 without a home; an empty var is
#   unset
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
    cmp byte ptr [rax], 0
    je 1f                       # set but empty counts as unset, as Claude Code treats it
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

# holder_claude(sid) -> HOLDER_*; it calls json_parse, which resets the shared JSON arena (a caller's JV*
#   from an earlier parse is invalid afterwards)
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
    cmp rbx, -ENOENT            # a missing directory lists nothing, no holders
    jne 8f
1:  mov eax, [rip + hc_result]
    EPILOGUE
8:  mov eax, HOLDER_UNKNOWN
    EPILOGUE

# holder_grok(sid) -> HOLDER_*; it calls json_parse, which resets the shared JSON arena (a caller's JV*
#   from an earlier parse is invalid afterwards)
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
    cmp rdx, -ENOENT            # no file, nobody active
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

.bss
.p2align 3
pe_cb: .quad 0
pe_ctx: .quad 0
pe_name: .zero 256
pe_cwd: .zero 4096
pe_args: .zero 4096
pe_path: .zero 64
.section .rodata
.Lproc: .asciz "/proc"
.Lproc_slash: .asciz "/proc/"
.Lcomm: .asciz "/comm"
.Lcmdline: .asciz "/cmdline"
.Lopencode_name: .asciz "opencode"
.Lw_serve: .ascii "serve"
.Lw_acp: .ascii "acp"
.text

.ifdef MACOS
# proc_each(cb, ctx) -> 1, or 0 when the processes cannot be listed: cb(ctx, pid, name, cwd or 0, 0) for
#   every process by pid and name, with its cwd when readable; macOS gives no arguments
FN proc_each
    PROLOGUE
    mov [rip + pe_cb], rdi
    mov [rip + pe_ctx], rsi
    mov edi, 4 * 8192
    call mem_alloc
    mov rbx, rax
    mov rdi, rax
    mov esi, 4 * 8192
    call mac_proc_list
    test rax, rax
    js 8f
    mov r12, rax
    xor r13d, r13d
1:  cmp r13, r12
    jae 7f
    mov edi, [rbx + r13*4]
    inc r13
    test edi, edi
    jz 1b
    mov r14d, edi
    lea rsi, [rip + pe_name]
    mov edx, 256
    call mac_proc_name
    test rax, rax
    js 1b                       # gone since the listing
    mov edi, r14d
    lea rsi, [rip + pe_cwd]
    mov edx, 4096
    call proc_cwd
    lea r15, [rip + pe_cwd]
    test rax, rax
    jg 2f
    xor r15d, r15d
2:  mov rdi, [rip + pe_ctx]
    mov esi, r14d
    lea rdx, [rip + pe_name]
    mov rcx, r15
    xor r8d, r8d
    call [rip + pe_cb]
    jmp 1b
7:  mov rdi, rbx
    call mem_free
    mov eax, 1
    EPILOGUE
8:  mov rdi, rbx
    call mem_free
    xor eax, eax
    EPILOGUE
.else
# proc_read(path, buf, cap) -> the bytes read into buf, up to cap, or -errno (a /proc file reports size
#   0, which file_read_all would take for empty)
proc_read:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    call file_open_read
    test rax, rax
    js 9f
    mov ebx, eax
    xor r14d, r14d
1:  cmp r14, r13
    jae 3f
    mov edi, ebx
    lea rsi, [r12 + r14]
    mov rdx, r13
    sub rdx, r14
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    test rax, rax
    js 2f
    jz 3f
    add r14, rax
    jmp 1b
2:  mov r14, rax
3:  mov edi, ebx
    SYS SYS_close
    mov rax, r14
9:  EPILOGUE

# proc_entry(ctx, name): one /proc entry; numeric names are processes, and one that has gone since the
#   listing is skipped
proc_entry:
    PROLOGUE
    mov rbx, rsi
    mov rdi, rbx
    call strlen
    test rax, rax
    jz 9f
    mov rcx, rax
1:  dec rcx
    js 2f
    movzx eax, byte ptr [rbx + rcx]
    sub eax, '0'
    cmp eax, 9
    ja 9f
    jmp 1b
2:  mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call parse_u64
    mov r12d, eax               # pid
    # comm, without its newline
    lea rdi, [rip + pe_path]
    lea rsi, [rip + .Lproc_slash]
    call cstr_copy
    mov rdi, rax
    mov rsi, rbx
    call cstr_copy
    mov r13, rax                # where "/comm" and then "/cmdline" go
    mov rdi, rax
    lea rsi, [rip + .Lcomm]
    call cstr_copy
    lea rdi, [rip + pe_path]
    lea rsi, [rip + pe_name]
    mov edx, 255
    call proc_read
    test rax, rax
    js 9f
    lea rcx, [rip + pe_name]
    test rax, rax
    jz 3f
    cmp byte ptr [rcx + rax - 1], 10
    jne 3f
    dec rax
3:  mov byte ptr [rcx + rax], 0
    # cwd
    mov edi, r12d
    lea rsi, [rip + pe_cwd]
    mov edx, 4096
    call proc_cwd
    xor r14d, r14d
    test rax, rax
    jle 4f
    lea r14, [rip + pe_cwd]
4:  # cmdline, its NULs to spaces
    mov rdi, r13
    lea rsi, [rip + .Lcmdline]
    call cstr_copy
    lea rdi, [rip + pe_path]
    lea rsi, [rip + pe_args]
    mov edx, 4095
    call proc_read
    xor r15d, r15d
    test rax, rax
    js 6f
    lea r15, [rip + pe_args]
    xor ecx, ecx
5:  cmp rcx, rax
    jae 51f
    cmp byte ptr [r15 + rcx], 0
    jne 52f
    mov byte ptr [r15 + rcx], ' '
52: inc rcx
    jmp 5b
51: mov byte ptr [r15 + rax], 0
6:  mov rdi, [rip + pe_ctx]
    mov esi, r12d
    lea rdx, [rip + pe_name]
    mov rcx, r14
    mov r8, r15
    call [rip + pe_cb]
9:  EPILOGUE

# proc_each(cb, ctx) -> 1, or 0 when the processes cannot be listed: cb(ctx, pid, name, cwd or 0,
#   args or 0) for every process in /proc, its arguments joined by spaces
FN proc_each
    PROLOGUE
    mov [rip + pe_cb], rdi
    mov [rip + pe_ctx], rsi
    lea rdi, [rip + .Lproc]
    lea rsi, [rip + proc_entry]
    xor edx, edx
    call dir_each_names
    test rax, rax
    js 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
.endif

.bss
.p2align 3
ho_root: .quad 0
ho_rootlen: .quad 0
.text

# has_word(args, word, wlen) -> 1 if a space-separated word of args equals word
has_word:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    call strlen
    mov r14, rax
1:  mov rdi, rbx
    mov rsi, r14
    call next_word
    test rdx, rdx
    jz 8f
    add rbx, rcx
    sub r14, rcx
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    mov rcx, r13
    call str_eq
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ho_cb(ctx, pid, name, cwd, args): one process against the OpenCode rule
ho_cb:
    PROLOGUE
    mov ebx, esi
    mov r12, rdx
    mov r13, rcx
    mov r14, r8
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rip + .Lopencode_name]
    call str_eq_cstr
    test eax, eax
    jz 9f
    mov edi, ebx
    call own_pid
    test eax, eax
    jnz 9f
    test r13, r13
    jz .Lho_holds               # no cwd: cannot exempt
    test r14, r14
    jz .Lho_holds               # no arguments: cannot exempt
    mov rdi, r14
    lea rsi, [rip + .Lw_serve]
    mov edx, 5
    call has_word
    test eax, eax
    jnz .Lho_holds
    mov rdi, r14
    lea rsi, [rip + .Lw_acp]
    mov edx, 3
    call has_word
    test eax, eax
    jnz .Lho_holds
    # inside the project: the root itself or a path under it
    mov rdi, r13
    call strlen
    mov r15, rax
    mov rdi, r13
    mov rsi, r15
    mov rdx, [rip + ho_root]
    mov rcx, [rip + ho_rootlen]
    call str_starts
    test eax, eax
    jz 9f
    mov rcx, [rip + ho_rootlen]
    cmp r15, rcx
    je .Lho_holds
    test rcx, rcx
    jz .Lho_holds
    mov rax, [rip + ho_root]
    cmp byte ptr [rax + rcx - 1], '/'
    je .Lho_holds               # a root that ends in a slash, such as /
    cmp byte ptr [r13 + rcx], '/'
    jne 9f                      # projectile is not under project
.Lho_holds:
    cmp dword ptr [rip + hc_result], HOLDER_UNKNOWN
    je 9f
    mov dword ptr [rip + hc_result], HOLDER_OTHER
9:  EPILOGUE

# holder_opencode(root) -> HOLDER_* (spec 5.4): any opencode process but rhun's own holds every OpenCode
#   session rhun holds or would resume, except one whose cwd is readable and outside root and whose
#   arguments are known and contain neither serve nor acp; a failed listing is unknown. It parses no JSON.
#   root must be a resolved path (the listing's cwds are canonical: readlink /proc/<pid>/cwd on Linux,
#   PROC_PIDVNODEPATHINFO on macOS), or an in-project process would be exempted.
FN holder_opencode
    PROLOGUE
    mov [rip + ho_root], rdi
    call strlen
    mov [rip + ho_rootlen], rax
    mov dword ptr [rip + hc_result], HOLDER_NONE
    lea rdi, [rip + ho_cb]
    xor esi, esi
    call proc_each
    test eax, eax
    jz 8f
    mov eax, [rip + hc_result]
    EPILOGUE
8:  mov eax, HOLDER_UNKNOWN
    EPILOGUE
.else
FN holder_claude
    mov eax, HOLDER_UNKNOWN
    ret
FN holder_grok
    mov eax, HOLDER_UNKNOWN
    ret
# no process listing until phase 8 adds Toolhelp, so every OpenCode session's holder is unknown (spec 5.4)
FN proc_each
    xor eax, eax
    ret
FN holder_opencode
    mov eax, HOLDER_UNKNOWN
    ret
.endif
