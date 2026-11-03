# Metadata index worker. OpenCode uses its database CLI; other sources read local files.
.include "rhun.inc"
.equ OPENCODE_RESCAN, 300        # s: an unchanged OpenCode database is queried again at least this often
.equ OPENCODE_BATCH, 8 << 20      # estimated bytes per transcript query
.equ OPENCODE_LARGEST, 24 << 20   # a larger conversation is listed but not copied: near the output limit

STRUCT
F AW_path, 8
F AW_claude, 8
F AW_name, 8
F AW_saved, 8
F AW_guard, 8
ENDSTRUCT AW_SIZE


.bss
.p2align 3
roots: .zero VEC_SIZE
entries: .zero VEC_SIZE
matches: .zero VEC_SIZE
tmp: .zero SB_SIZE
packet: .zero SB_SIZE
cache_key: .zero SB_SIZE
history_key_len: .quad 0        # stable repository/HOME prefix, shared with pre-profile histories
cache_file: .zero SB_SIZE
history_file: .zero SB_SIZE
history_dir: .zero SB_SIZE
history_item: .zero SB_SIZE
member_file: .zero SB_SIZE
repository: .quad 0
history_records: .zero VEC_SIZE
table: .quad 0
cache_hash: .quad 0             # of the cache's records as loaded (cache_load), 0 without one
page_limit: .quad 0
scan_failed: .long 0
opencode_status: .long 0
.p2align 3
opencode_dir: .zero SB_SIZE
opencode_sql: .zero SB_SIZE
opencode_path: .zero SB_SIZE
opencode_db: .zero SB_SIZE      # the database path the CLI reports
opencode_state: .zero SB_SIZE   # this project's state file, next to the cache
opencode_ident: .zero SB_SIZE
opencode_open: .quad 0
opencode_scope: .quad 0
opencode_st: .zero 48           # saved state: magic, CLI key, scan key, rows hash, time of the last query,
                                # OpenCode 2
opencode_rows: .quad 0          # opencode_rows_hash of the cache as loaded
opencode_cli_key: .quad 0
opencode_scan_key: .quad 0      # this run's listing identity, 0 when the database cannot be identified
opencode_time: .quad 0          # of the metadata query the rows come from
opencode_good: .long 0          # the rows are current: the state may be saved with the cache
opencode_skip: .long 0          # unchanged database: the cached rows stand in for the metadata query
opencode_single: .long 0        # a batch passed the output limit: one conversation a query
.text
# root_add(name path override or 0, path, linked): retain entries across refreshes.
root_add:
    PROLOGUE
    mov r12, rsi
    mov r13d, edx
    mov r14, rdi
    xor r15d, r15d
    xor ebx, ebx
1:  cmp rbx, [rip + roots + VEC_len]
    jae 2f
    mov rax, [rip + roots + VEC_ptr]
    mov rax, [rax + rbx*8]
    mov r15, rax
    mov rdi, [rax + AW_path]
    mov rsi, r12
.ifdef WINDOWS
    call win_path_equal
.else
    call strcmp_eq
.endif
    test eax, eax
    jnz 9f
    inc rbx
    jmp 1b
2:  cmp qword ptr [rip + roots + VEC_len], 4096
    jae 8f
    mov edi, AW_SIZE
    call mem_alloc
    mov r15, rax
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [r15 + AW_path], rax
    test r13d, r13d
    jz 3f
    test r14, r14
    cmovz r14, r12
    mov rdi, r14
    call worktree_name
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [r15 + AW_name], rax
3:  lea rdi, [rip + roots]
    mov esi, 8
    call vec_push
    mov [rax], r15
    mov rdi, r15
    call claude_root
9:  mov rax, r15
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# worktree_name(path) -> ptr, len. Codex puts the repo inside a named worktree directory.
worktree_name:
    PROLOGUE
    mov r12, rdi
    call strlen
    mov r13, rax
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lcodex_worktrees]
    mov ecx, 18
    call str_find
    test rax, rax
    js 3f
    lea rbx, [r12 + rax + 18]
    mov rax, rbx
1:  cmp byte ptr [rax], 0
    je 3f
    cmp byte ptr [rax], '/'
    je 2f
    inc rax
    jmp 1b
2:  mov rdx, rax
    sub rdx, rbx
    jz 3f
    mov rax, rbx
    EPILOGUE
3:
    mov rdi, r12
    mov rsi, r13
    call path_basename
    EPILOGUE

# claude_root(AW*): session directory for this checkout.
claude_root:
    PROLOGUE
    mov rbx, rdi
    # $CLAUDE_CONFIG_DIR/projects, else ~/.claude/projects, then the checkout's slug
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + .Lclaude_config_dir]
    call getenv
    lea r12, [rip + .Lprojects]
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 0
    jne 2f
1:
    lea rdi, [rip + .Lhome]
    call getenv
    test rax, rax
    jz 9f
    lea r12, [rip + .Lclaude_projects]
2:  lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, r12
    call sb_push_cstr
    mov r15, [rip + tmp + SB_len]
    mov rdi, [rip + tmp + SB_ptr]
    mov r12, [rbx + AW_path]
    mov rdi, r12
    call strlen
    lea r13, [r12 + rax]
3:  cmp r12, r13
    jae 4f
    mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    call utf8_decode
    add r12, rdx
    mov r14d, eax
    mov esi, eax
    lea ecx, [rax - '0']
    cmp ecx, 9
    jbe 31f
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    jbe 31f
    mov esi, '-'
31: lea rdi, [rip + tmp]
    call sb_push_byte
    # Claude's JS regex has no Unicode flag: supplementary characters take two '-'.
    cmp r14d, 0xffff
    jbe 3b
    lea rdi, [rip + tmp]
    mov esi, '-'
    call sb_push_byte
    jmp 3b
    # A folder name over 255 bytes cannot exist (a deep checkout): no folder rather than an open,
    # which Windows fails as an invalid name, not as one too long
4:  mov rax, [rip + tmp + SB_len]
    sub rax, r15
    cmp rax, 255
    ja 9f
    mov rdi, [rip + tmp + SB_ptr]
    mov rsi, [rip + tmp + SB_len]
    call mem_dup
    mov [rbx + AW_claude], rax
    mov rdi, rax
9:
    EPILOGUE


FN agent_index_main
    PROLOGUE
    mov rbx, [rip + g_argv]
    mov rax, [rbx + 16]
.ifdef WINDOWS
    # the project as the app spells it (C:/...): the worker can be started by other programs too
    mov rdi, rax
    call win_fullpath
    test rax, rax
    jz .Lindex_bad
    mov r12, rax
    mov rdi, rax
    call path_normalize
    mov rax, r12
.endif
    mov [rip + g_project], rax
    mov rdi, [rbx + 24]
    call strlen
    mov rsi, rax
    mov rdi, [rbx + 24]
    call parse_u64
    cmp rax, 50
    jb .Lindex_bad
    cmp rax, 100000
    ja .Lindex_bad
    mov [rip + page_limit], rax
    mov rax, [rbx + 32]
    mov [rip + cfg_agent_sources], rax
    cmp qword ptr [rip + g_argc], 6
    jb 1f
    mov rax, [rbx + 40]
    mov [rip + opencode_open], rax
1:  mov dword ptr [rip + cfg_git], 0
    call git_set_project
    mov rdi, [rip + g_git_root]
    mov rsi, [rip + g_project]
    xor edx, edx
    cmp byte ptr [rip + g_worktree], 0
    setne dl
    call root_add
    lea rdi, [rip + root_add]
    xor esi, esi
    call git_each_agent_worktree
    mov edi, 8 * 262144
    call mem_alloc
    mov [rip + table], rax
    call cache_path
    call history_load
    cmp dword ptr [rip + scan_failed], 0
    jne .Lindex_bad
    call history_save
    call cache_load
    xor edi, edi
    call opencode_rows_hash
    mov [rip + opencode_rows], rax
    call agent_opencode_data_dir
    test rax, rax
    jz 11f
    mov rbx, rax
    mov rdi, rax
    call agent_opencode_scope
    mov [rip + opencode_scope], rax
    mov rdi, rbx
    call mem_free
11:
    call verify_roots
    # Cached metadata supplies a provisional page before full directory discovery.
    xor edi, edi
    call collect_matches
    cmp dword ptr [rip + scan_failed], 0
    jne .Lindex_bad
    mov rdi, 0x3356455250484152   # RAHPREV3
    call emit_page
    call scan_sources
    cmp dword ptr [rip + scan_failed], 0
    jne .Lindex_bad
    call recover_roots
    call history_save
    call verify_roots
    mov edi, 1
    call collect_matches
    cmp dword ptr [rip + scan_failed], 0
    jne .Lindex_bad
    call opencode_refresh
    cmp dword ptr [rip + scan_failed], 0
    jne .Lindex_bad
    lea rdi, [rip + .Lopencode]
    call has_source
    test eax, eax
    jz 2f
    mov rdi, 0x31434f504f484152   # RAHOPOC1: OpenCode availability
    mov esi, [rip + opencode_status]
    xor edx, edx
    call packet_start
    call packet_finish
    mov edi, 1
    mov rsi, [rip + packet + SB_ptr]
    mov edx, 32
    call write_all
2:  mov rdi, 0x3345474150484152   # RAHPAGE3
    call emit_page
    call cache_save
    xor eax, eax
    EPILOGUE
.Lindex_bad:
    mov eax, 1
    EPILOGUE

has_source:
    PROLOGUE
    mov r12, rdi
    call strlen
    mov r13, rax
    mov rdi, [rip + cfg_agent_sources]
    call strlen
    mov rdi, [rip + cfg_agent_sources]
    mov rsi, rax
    mov rdx, r12
    mov rcx, r13
    call str_find
    not rax
    shr rax, 63
    EPILOGUE

# Append an environment value, separated by NUL so embedded newlines cannot alias profiles.
cache_env:
    PROLOGUE
    call getenv
    mov rbx, rax
    lea rdi, [rip + cache_key]
    xor esi, esi
    call sb_push_byte
    test rbx, rbx
    jz 1f
    lea rdi, [rip + cache_key]
    mov rsi, rbx
    call sb_push_cstr
1:  EPILOGUE

# Cache filename is hashed; the entire identity is also stored and checked on load.
cache_path:
    PROLOGUE 32
    call git_repository_id
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [rip + repository], rax
    lea rdi, [rip + cache_key]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + cache_key]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + .Lhome]
    call getenv
    test rax, rax
    jz 9f
    lea rdi, [rip + cache_key]
    mov rsi, rax
    call sb_push_cstr
    mov rax, [rip + cache_key + SB_len]
    mov [rip + history_key_len], rax
    # A provisional page must never come from another provider's configuration directory.
    lea rdi, [rip + .Lclaude_config_dir]
    call cache_env
    lea rdi, [rip + .Lcodex_home]
    call cache_env
    lea rdi, [rip + .Lgrok_home]
    call cache_env
    lea rdi, [rip + cache_file]
    call session_state_dir
    test eax, eax
    jz 9f
    mov rdi, [rip + cache_file + SB_ptr]
    call stale_temps
    lea rdi, [rip + history_file]
    mov rsi, [rip + cache_file + SB_ptr]
    call sb_push_cstr
    lea rdi, [rip + history_file]
    lea rsi, [rip + .Lhistory_prefix]
    call sb_push_cstr
    lea rdi, [rip + history_dir]
    mov rsi, [rip + cache_file + SB_ptr]
    call sb_push_cstr
    lea rdi, [rip + history_dir]
    lea rsi, [rip + .Lhistory_dir_prefix]
    call sb_push_cstr
    lea rdi, [rip + cache_file]
    lea rsi, [rip + .Lcache_prefix]
    call sb_push_cstr
    mov rdi, [rip + cache_key + SB_ptr]
    mov rsi, [rip + cache_key + SB_len]
    call hash_line
    mov rsi, rax
    mov rdi, rsp
    call fmt_hex
    mov [rsp + 24], rax
    mov rdx, rax
    lea rdi, [rip + cache_file]
    mov rsi, rsp
    call sb_push
    # Worktree associations survive provider switches and upgrades from the legacy cache key.
    mov rdi, [rip + cache_key + SB_ptr]
    mov rsi, [rip + history_key_len]
    call hash_line
    mov rsi, rax
    mov rdi, rsp
    call fmt_hex
    mov [rsp + 24], rax
    lea rdi, [rip + history_file]
    mov rsi, rsp
    mov rdx, [rsp + 24]
    call sb_push
    lea rdi, [rip + history_dir]
    mov rsi, rsp
    mov rdx, [rsp + 24]
    call sb_push
    mov rdi, [rip + history_dir + SB_ptr]
    call stale_temps
9:  EPILOGUE

# stale_temps(dir): remove the temporary files (.rhun-PID-N.tmp) of saves that never finished, an hour
# old or more. The app stops a worker at once (a project switch, quitting), also in the middle of a save:
# what it leaves, as large as the cache, nothing else would remove.
stale_temps:
    PROLOGUE 16
    mov [rsp], rdi
    call time_now
    mov [rsp + 8], rax
    mov rdi, [rsp]
    lea rsi, [rip + stale_cb]
    mov rdx, rsp
    call dir_each
    EPILOGUE

stale_cb:
    PROLOGUE
    test edx, edx
    jnz 9f
    mov r12, rdi                # [dir, now]
    mov r13, rsi
    mov rdi, rsi
    call strlen
    mov r14, rax
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Ltemp_prefix]
    mov ecx, 6
    call str_starts
    test eax, eax
    jz 9f
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Ltemp_suffix]
    mov ecx, 4
    call str_ends
    test eax, eax
    jz 9f
    mov rdi, [r12]
    mov rsi, r13
    call path_join
    mov rbx, rax
    mov rdi, rax
    call file_mtime
    test rax, rax
    jz 8f
    add rax, 3600
    cmp rax, [r12 + 8]
    ja 8f                       # a save may still be going on
    mov rdi, rbx
    SYS SYS_unlink
8:  mov rdi, rbx
    call mem_free
9:  EPILOGUE

# Repository-scoped worktree identities survive transcript cache rebuilds and Git pruning.
history_load:
    PROLOGUE
    cmp qword ptr [rip + history_file + SB_len], 0
    je 9f
    mov rdi, [rip + history_file + SB_ptr]
    xor esi, esi              # import the earlier whole-file format once
    call history_read_file
    mov rdi, [rip + history_dir + SB_ptr]
    lea rsi, [rip + history_cb]
    mov rdx, rdi
    call dir_each
    test rax, rax
    jns 9f
    cmp rax, -2
    je 9f
    cmp rax, -20              # unavailable optional state (ENOTDIR)
    je 9f
    cmp rax, -13              # unavailable optional state (EACCES)
    je 9f
    mov dword ptr [rip + scan_failed], 1
9:  EPILOGUE

history_cb:
    PROLOGUE
    test edx, edx
    jnz 9f
    mov r12, rdi
    mov rbx, rsi
    mov rdi, rsi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lhistory_suffix]
    mov ecx, 5
    call str_ends
    test eax, eax
    jz 9f
    mov rdi, r12
    mov rsi, rbx
    call path_join
    mov rbx, rax
    mov rdi, rax
    mov esi, 1
    call history_read_file
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

history_read_file:
    PROLOGUE 16
    mov [rsp], rdi
    mov [rsp + 8], esi
    mov esi, (1 << 20) + 1
    call agent_read_head
    test rax, rax
    jnz 10f
    # Preserve the association file and previous UI snapshot on a failed read.
    mov rdi, [rsp]
    call file_stamp
    test rax, rax
    jz 9f
    mov dword ptr [rip + scan_failed], 1
    jmp 9f
10:
    mov rbx, rax
    mov r12, rdx
    cmp r12, 40
    jb 8f
    cmp r12, 1 << 20
    ja 8f
    mov r13, [rbx]
    cmp r13, [rip + history_key_len]
    jne 8f
    lea rax, [r13 + 40]
    cmp rax, r12
    ja 8f
    lea rdi, [rbx + 8]
    mov rsi, [rip + cache_key + SB_ptr]
    mov rdx, r13
    call memeq
    test eax, eax
    jz 8f
    lea rdi, [rbx + r13 + 8]
    mov rax, 0x31544f4f52484152   # RAHROOT1
    cmp [rdi], rax
    jne 8f
    cmp qword ptr [rdi + 8], 4096
    ja 8f
    mov rsi, r12
    sub rsi, r13
    sub rsi, 8
    lea rdx, [rip + history_records]
    call agent_records_decode4
    test eax, eax
    jz 8f
    xor r13d, r13d
1:  cmp r13, [rip + history_records + VEC_len]
    jae 2f
    mov rax, [rip + history_records + VEC_ptr]
    mov r14, [rax + r13*8]
    cmp dword ptr [r14 + AS_kind], 1
    jne 7f
    cmp qword ptr [r14 + AS_cwd], 0
    je 7f
    cmp qword ptr [r14 + AS_worktree], 0
    je 7f
    mov rdi, [r14 + AS_path]
    mov rsi, [r14 + AS_cwd]
    call strcmp_eq
    test eax, eax
    jz 7f
    inc r13
    jmp 1b
2:  xor r13d, r13d
3:  cmp r13, [rip + history_records + VEC_len]
    jae 7f
    mov rax, [rip + history_records + VEC_ptr]
    mov rax, [rax + r13*8]
    mov rsi, [rax + AS_cwd]
    xor edi, edi
    mov edx, 1
    call root_add
    test rax, rax
    jz 31f
    cmp dword ptr [rsp + 8], 0
    je 31f
    mov qword ptr [rax + AW_saved], 1
31:
    inc r13
    jmp 3b
7:  lea rdi, [rip + history_records]
    call agent_records_free
8:  mov rdi, rbx
    call mem_free
9:  EPILOGUE

history_save:
    PROLOGUE 32
    cmp qword ptr [rip + history_dir + SB_len], 0
    je 9f
    mov rdi, [rip + history_dir + SB_ptr]
    call mkdir_p
    mov edi, AS_SIZE
    call mem_alloc
    mov r12, rax
    mov dword ptr [r12 + AS_kind], 1
    xor ebx, ebx
3:  cmp rbx, [rip + roots + VEC_len]
    jae 4f
    mov rax, [rip + roots + VEC_ptr]
    mov rax, [rax + rbx*8]
    mov r13, rax
    cmp qword ptr [r13 + AW_saved], 0
    jne 31f
    mov rdx, [rax + AW_name]
    test rdx, rdx
    jz 31f
    mov [r12 + AS_worktree], rdx
    mov rax, [rax + AW_path]
    mov [r12 + AS_path], rax
    mov [r12 + AS_cwd], rax
    mov rdi, 0x31544f4f52484152
    mov esi, 1
    mov edx, 1
    call packet_start
    lea rdi, [rip + packet]
    mov rsi, r12
    call agent_record_encode4
    call packet_finish
    lea rdi, [rip + history_item]
    call sb_clear
    lea rdi, [rip + history_item]
    mov rsi, [rip + history_dir + SB_ptr]
    call sb_push_cstr
    lea rdi, [rip + history_item]
    mov esi, '/'
    call sb_push_byte
    mov rdi, [r13 + AW_path]
    call strlen
    mov rsi, rax
    mov rdi, [r13 + AW_path]
    call hash_line
    mov rsi, rax
    mov rdi, rsp
    call fmt_hex
    mov rdx, rax
    lea rdi, [rip + history_item]
    mov rsi, rsp
    call sb_push
    lea rdi, [rip + history_item]
    lea rsi, [rip + .Lhistory_suffix]
    call sb_push_cstr
    mov rdi, [rip + history_item + SB_ptr]
    mov rsi, [rip + history_key_len]
    call keyed_save
    test rax, rax
    jnz 31f
    mov qword ptr [r13 + AW_saved], 1
31: inc rbx
    jmp 3b
4:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# A transcript proof is keyed by its path and stable first metadata record.
# Unlike a remembered checkout path, it cannot admit a new repository's session.
member_key:
    PROLOGUE 32
    mov r12, rdi
    cmp qword ptr [rip + history_dir + SB_len], 0
    je 9f
    cmp dword ptr [r12 + AS_kind], 4
    jne 11f
    mov rdi, [r12 + AS_index_title] # an OpenCode session's ID, from this run's listing: its snapshot
    test rdi, rdi               # may not be written yet
    jz 11f
    call strlen
    mov rsi, rax
    mov rdi, [r12 + AS_index_title]
    call hash_line
    mov r14, rax
    jmp 12f
11: mov rdi, [r12 + AS_path]
    mov esi, 1 << 20
    call agent_read_first_line
    test rax, rax
    jnz 10f
    test rdx, rdx
    jns 9f
    # a transcript deleted since it was cached (cleanup, archiving) has no identity: unknown, not a
    # failure, or the provisional page would fail every run and the cache never drop it
    cmp rdx, -2                 # ENOENT
    je 9f
    cmp rdx, -20                # ENOTDIR
    je 9f
    mov dword ptr [rip + scan_failed], 1
    jmp 9f
10:
    mov rbx, rax
    mov r13, rdx
    mov rdi, rax
    mov rsi, rdx
    call json_parse
    cmp dword ptr [r12 + AS_kind], 1
    je 1f
    cmp dword ptr [r12 + AS_kind], 4
    je 6f
    cmp dword ptr [r12 + AS_kind], 3
    je 5f
    mov rdi, rax
    lea rsi, [rip + .Lpayload]
    call json_get
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lsession_id]
    call json_get
    test rax, rax
    jnz 2f
    mov rdi, r14
    lea rsi, [rip + .Lid]
    call json_get
    jmp 2f
6:  mov rdi, rax
    lea rsi, [rip + .Lid]
    call json_get
    jmp 2f
1:  mov rdi, rax
    lea rsi, [rip + .Lclaude_session_id]
    call json_get
    jmp 2f
5:  mov rdi, rax
    lea rsi, [rip + .Lparams]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lclaude_session_id]
    call json_get
2:  mov rdi, rax
    call json_str
    mov rdi, rax
    mov rsi, rdx
    test rax, rax
    jz 3f
    test rdx, rdx
    jnz 4f
3:  mov rdi, rbx
    mov rsi, r13
4:  call hash_line
    mov r14, rax
    mov rdi, rbx
    call mem_free
12: lea rdi, [rip + member_file]
    call sb_clear
    lea rdi, [rip + member_file]
    mov rsi, [rip + history_dir + SB_ptr]
    call sb_push_cstr
    lea rdi, [rip + member_file]
    mov esi, '/'
    call sb_push_byte
    mov rdi, [r12 + AS_path]
    call strlen
    mov rsi, rax
    mov rdi, [r12 + AS_path]
    call hash_line
    mov rsi, rax
    mov rdi, rsp
    call fmt_hex
    mov rdx, rax
    lea rdi, [rip + member_file]
    mov rsi, rsp
    call sb_push
    lea rdi, [rip + member_file]
    mov esi, '-'
    call sb_push_byte
    mov rdi, rsp
    mov rsi, r14
    call fmt_hex
    mov rdx, rax
    lea rdi, [rip + member_file]
    mov rsi, rsp
    call sb_push
    lea rdi, [rip + member_file]
    lea rsi, [rip + .Lmember_suffix]
    call sb_push_cstr
    mov rax, [rip + member_file + SB_ptr]
    mov rdx, r14
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# member_save(AS*, foreign): immutable evidence for this transcript identity.
member_save:
    PROLOGUE 16
    mov [rsp], esi
    mov r12, rdi
    call member_key
    test rax, rax
    jz 9f
    mov r14, rdx
    mov rdi, rax
    call file_stamp
    test rax, rax
    jnz 9f
    mov edi, AS_SIZE
    call mem_alloc
    mov rbx, rax
    mov eax, [r12 + AS_kind]
    mov [rbx + AS_kind], eax
    mov rax, [r12 + AS_path]
    mov [rbx + AS_path], rax
    mov rax, [r12 + AS_cwd]
    mov [rbx + AS_cwd], rax
    mov [rbx + AS_prefix_hash], r14
    mov eax, [rsp]             # proof-only field: 0 owned, 1 foreign
    mov [rbx + AS_title_rev], rax
    mov rdi, 0x31424d454d484152   # RAHMEMB1
    mov esi, 1
    mov edx, 1
    call packet_start
    lea rdi, [rip + packet]
    mov rsi, rbx
    call agent_record_encode4
    mov rdi, rbx
    call mem_free
    call packet_finish
    mov rdi, [rip + member_file + SB_ptr]
    mov rsi, [rip + history_key_len]
    call keyed_save
9:  EPILOGUE

# member_check(AS*) -> 1 owned, -1 foreign, 0 unknown/invalid.
member_check:
    PROLOGUE 16
    mov r12, rdi
    xor r15d, r15d
    call member_key
    test rax, rax
    jz 9f
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rax
    mov esi, (1 << 20) + 1
    call agent_read_head
    test rax, rax
    jnz 10f
    mov rdi, [rsp]
    call file_stamp
    test rax, rax
    jz 9f
    mov dword ptr [rip + scan_failed], 1
    jmp 9f
10: mov rbx, rax
    mov r13, rdx
    cmp r13, 40
    jb 8f
    cmp r13, 1 << 20
    ja 8f
    mov r14, [rbx]
    cmp r14, [rip + history_key_len]
    jne 8f
    lea rax, [r14 + 40]
    cmp rax, r13
    ja 8f
    lea rdi, [rbx + 8]
    mov rsi, [rip + cache_key + SB_ptr]
    mov rdx, r14
    call memeq
    test eax, eax
    jz 8f
    lea rdi, [rbx + r14 + 8]
    mov rax, 0x31424d454d484152
    cmp [rdi], rax
    jne 8f
    cmp qword ptr [rdi + 8], 1
    jne 8f
    mov rsi, r13
    sub rsi, r14
    sub rsi, 8
    lea rdx, [rip + history_records]
    call agent_records_decode4
    test eax, eax
    jz 8f
    mov rax, [rip + history_records + VEC_ptr]
    mov r14, [rax]
    mov rax, [rsp + 8]
    cmp rax, [r14 + AS_prefix_hash]
    jne 7f
    cmp qword ptr [r14 + AS_title_rev], 1
    ja 7f
    mov eax, [r12 + AS_kind]
    cmp eax, [r14 + AS_kind]
    jne 7f
    cmp qword ptr [r14 + AS_cwd], 0
    je 7f
    mov rdi, [r14 + AS_path]
    mov rsi, [r12 + AS_path]
    call strcmp_eq
    test eax, eax
    jz 7f
    mov rdi, [r14 + AS_cwd]
    mov rsi, [r12 + AS_cwd]
.ifdef WINDOWS
    call win_path_equal
.else
    call strcmp_eq
.endif
    mov r15d, eax
    test eax, eax
    jz 7f
    cmp qword ptr [r14 + AS_title_rev], 0
    je 7f
    mov r15d, -1
7:  lea rdi, [rip + history_records]
    call agent_records_free
8:  mov rdi, rbx
    call mem_free
9:  mov eax, r15d
    EPILOGUE

cache_load:
    PROLOGUE
    cmp qword ptr [rip + cache_file + SB_len], 0
    je 9f
    mov rdi, [rip + cache_file + SB_ptr]
    call file_open_read
    test rax, rax
    js 9f
    mov ebx, eax
    mov edi, ebx
    call file_size
    mov r12, rax
    mov edi, ebx
    SYS SYS_close
    cmp r12, 40
    jb 9f
    cmp r12, 1 << 26
    ja 9f
    mov rdi, [rip + cache_file + SB_ptr]
    lea rsi, [r12 + 1]
    call agent_read_head
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp r12, rdx
    jne 8f
    cmp rdx, 40
    jb 8f
    mov r13, [rbx]
    cmp r13, [rip + cache_key + SB_len]
    jne 8f
    lea rax, [r13 + 40]
    cmp rax, r12
    ja 8f
    lea rdi, [rbx + 8]
    mov rsi, [rip + cache_key + SB_ptr]
    mov rdx, r13
    call memeq
    test eax, eax
    jz 8f
    lea rdi, [rbx + r13 + 8]
    mov rax, 0x3658444941484152   # RAHAIDX6, verified transcript ownership
    cmp [rdi], rax
    jne 8f
    mov rsi, r12
    sub rsi, r13
    sub rsi, 8
    lea rdx, [rip + entries]
    call agent_records_decode
    test eax, eax
    jz 8f
    lea rdi, [rbx + r13 + 8]    # what cache_save would write again unchanged
    mov rsi, r12
    sub rsi, r13
    sub rsi, 8
    call hash_line
    mov [rip + cache_hash], rax
    xor r13d, r13d
1:  cmp r13, [rip + entries + VEC_len]
    jae 8f
    mov rax, [rip + entries + VEC_ptr]
    mov rdx, [rax + r13*8]
    mov rdi, [rip + table]
    mov esi, 262143
    call agent_table_put
    inc r13
    jmp 1b
8:  mov rdi, rbx
    call mem_free
9:  EPILOGUE

# Start a length-framed packet: magic, count, total, payload length.
packet_start:
    PROLOGUE 32
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov qword ptr [rsp + 24], 0
    lea rdi, [rip + packet]
    call sb_clear
    lea rdi, [rip + packet]
    mov rsi, rsp
    mov edx, 32
    call sb_push
    EPILOGUE
packet_finish:
    mov rax, [rip + packet + SB_ptr]
    mov rcx, [rip + packet + SB_len]
    sub rcx, 32
    mov [rax + 24], rcx
    ret

emit_page:
    PROLOGUE
    mov r12, [rip + matches + VEC_len]
    mov rdx, r12
    cmp r12, [rip + page_limit]
    cmova r12, [rip + page_limit]
    mov rsi, r12
    call packet_start
    xor ebx, ebx
1:  cmp rbx, r12
    jae 2f
    mov rax, [rip + matches + VEC_ptr]
    mov rsi, [rax + rbx*8]
    lea rdi, [rip + packet]
    call agent_record_encode
    inc rbx
    jmp 1b
2:  call packet_finish
    cmp qword ptr [rip + packet + SB_len], 1 << 26
    ja 9f
    mov edi, 1
    mov rsi, [rip + packet + SB_ptr]
    mov rdx, [rip + packet + SB_len]
    call write_all
9:  EPILOGUE

cache_save:
    PROLOGUE 16
    cmp qword ptr [rip + cache_file + SB_len], 0
    je 9f
    xor ebx, ebx
    xor r12d, r12d
1:  cmp rbx, [rip + entries + VEC_len]
    jae 2f
    mov rax, [rip + entries + VEC_ptr]
    mov rax, [rax + rbx*8]
    cmp qword ptr [rax + AS_seen], 0
    je 11f
    inc r12
11: inc rbx
    jmp 1b
2:  mov rdi, 0x3658444941484152   # RAHAIDX6
    mov rsi, r12
    mov rdx, r12
    call packet_start
    xor ebx, ebx
3:  cmp rbx, [rip + entries + VEC_len]
    jae 4f
    cmp qword ptr [rip + packet + SB_len], (1 << 26) - 16384
    ja 9f
    mov rax, [rip + entries + VEC_ptr]
    mov rsi, [rax + rbx*8]
    cmp qword ptr [rsi + AS_seen], 0
    je 31f
    mov qword ptr [rsi + AS_replaced], 0 # replacement is a page event, never cached
    lea rdi, [rip + packet]
    call agent_record_encode
31: inc rbx
    jmp 3b
4:  call packet_finish
    mov rdi, [rip + packet + SB_ptr]
    mov rsi, [rip + packet + SB_len]
    call hash_line
    cmp rax, [rip + cache_hash]
    je 5f                       # unchanged since loaded: not written (and synced) again on every run
    mov rdi, [rip + cache_file + SB_ptr]
    mov rsi, [rip + cache_key + SB_len]
    call keyed_save
    test rax, rax
    jnz 9f
5:  mov edi, 1
    call opencode_rows_hash
    mov rdi, rax
    call opencode_state_save
9:  EPILOGUE

# keyed_save(path, key length): atomically write the identity prefix and current packet.
keyed_save:
    PROLOGUE 16
    mov r12, rdi
    mov [rsp], rsi
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, rsp
    mov edx, 8
    call sb_push
    lea rdi, [rip + tmp]
    mov rsi, [rip + cache_key + SB_ptr]
    mov rdx, [rsp]
    call sb_push
    lea rdi, [rip + tmp]
    mov rsi, [rip + packet + SB_ptr]
    mov rdx, [rip + packet + SB_len]
    call sb_push
    mov eax, 1                  # not saved
    cmp qword ptr [rip + tmp + SB_len], 1 << 26
    ja 9f
    mov rdi, r12
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    call file_write_all
9:  EPILOGUE

# Directory errors (I/O, a sources folder that is a file) preserve the previous UI snapshot. Absent
# directories are normal, and so is one that can never be read: no permission (a day folder that
# `sudo codex` made), a name too long for the file system, a symlink loop. Failing on those would
# fail every run, also for the sources that can be read.
scan_dir:
    call dir_each
    test rax, rax
    jns 1f
    cmp rax, -2                # ENOENT
    je 1f
    cmp rax, -1                # EPERM
    je 1f
    cmp rax, -13               # EACCES
    je 1f
    cmp rax, -36               # ENAMETOOLONG
    je 1f
    cmp rax, -40               # ELOOP
    je 1f
    mov dword ptr [rip + scan_failed], 1
1:  ret

scan_sources:
    PROLOGUE
    lea rdi, [rip + .Lclaude]
    call has_source
    test eax, eax
    jz 3f
    xor ebx, ebx
1:  cmp rbx, [rip + roots + VEC_len]
    jae 3f
    mov rax, [rip + roots + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov rdi, [r12 + AW_claude]
    test rdi, rdi
    jz 2f
    lea rsi, [rip + claude_cb]
    mov rdx, r12
    call scan_dir
    cmp qword ptr [r12 + AW_name], 0
    jne 2f
    mov rdi, r12
    call claude_retired_dirs
2:  inc rbx
    jmp 1b
3:  lea rdi, [rip + .Lcodex]
    call has_source
    test eax, eax
    jz 5f
    call codex_sessions
    test rax, rax
    jz 5f
    mov rbx, rax
    mov rdi, rax
    xor esi, esi
    call codex_walk
    mov rdi, rbx
    call mem_free
5:  lea rdi, [rip + .Lgrok]
    call has_source
    test eax, eax
    jz 8f
    call grok_sessions
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + grok_group_cb]
    mov rdx, rbx
    call scan_dir
    mov rdi, rbx
    call mem_free
8:  call opencode_scan
9:  EPILOGUE

claude_cb:
    PROLOGUE
    test edx, edx
    jnz 9f
    mov r12, rdi
    mov r13, rsi
    call jsonl_name
    test eax, eax
    jz 9f
    mov rdi, [r12 + AW_claude]
    mov rsi, r13
    call path_join
    mov rbx, rax
    mov rdi, rax
    mov esi, 1
    mov rdx, [r12 + AW_path]
    call index_file
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# Retired nested Claude worktrees leave project directories after Git prunes them.
# The folder prefix only selects candidates; exact cwd metadata verifies ownership.
claude_retired_dirs:
    PROLOGUE 32
    mov rbx, rdi
    mov rdi, [rbx + AW_claude]
    call strlen
    mov rdi, [rbx + AW_claude]
    mov rsi, rax
    call path_dirlen
    mov rdi, [rbx + AW_claude]
    mov rsi, rax
    call mem_dup
    mov [rsp], rax
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rbx + AW_claude]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lclaude_tree_slug]
    call sb_push_cstr
    mov rdi, [rip + tmp + SB_ptr]
    mov rsi, [rip + tmp + SB_len]
    mov [rsp + 16], rsi
    call mem_dup
    mov [rsp + 8], rax
    mov rdi, [rsp]
    lea rsi, [rip + retired_dir_cb]
    mov rdx, rsp
    call scan_dir
    mov rdi, [rsp]
    call mem_free
    mov rdi, [rsp + 8]
    call mem_free
    EPILOGUE

retired_dir_cb:
    PROLOGUE AW_SIZE
    test edx, edx
    jz 9f
    mov r12, rdi
    mov rdi, [r12]
    call path_join
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [r12 + 8]
    mov rcx, [r12 + 16]
    call str_starts
    test eax, eax
    jz 8f
    mov qword ptr [rsp + AW_path], 0
    mov [rsp + AW_claude], rbx
    mov qword ptr [rsp + AW_name], 0
    mov rdi, rbx
    lea rsi, [rip + claude_cb]
    mov rdx, rsp
    call scan_dir
8:  mov rdi, rbx
    call mem_free
9:  EPILOGUE

jsonl_name:
    push rsi
    mov rdi, rsi
    call strlen
    pop rdi
    mov rsi, rax
    lea rdx, [rip + .Ljsonl]
    mov ecx, 6
    jmp str_ends

codex_walk:
    PROLOGUE 16
    mov [rsp], rdi
    mov [rsp + 8], esi
    lea rsi, [rip + codex_cb]
    mov rdx, rsp
    call scan_dir
    EPILOGUE
codex_cb:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov rdi, [r12]
    call path_join
    mov rbx, rax
    test r14d, r14d
    jz 1f
    cmp dword ptr [r12 + 8], 3
    jae 9f
    mov rdi, rbx
    mov esi, [r12 + 8]
    inc esi
    call codex_walk
    jmp 9f
1:  mov rsi, r13
    call jsonl_name
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov esi, 2
    xor edx, edx
    call index_file
9:  mov rdi, rbx
    call mem_free
    EPILOGUE

codex_sessions:
    PROLOGUE
    lea rdi, [rip + .Lcodex_home]
    call getenv
    lea rsi, [rip + .Lsessions]
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 0
    jne 2f
1:  lea rdi, [rip + .Lhome]
    call getenv
    test rax, rax
    jz 9f
    lea rsi, [rip + .Lcodex_sessions]
2:  mov rdi, rax
    call path_join
9:  EPILOGUE

# grok_sessions() -> Grok Build's sessions folder (owned): $GROK_HOME/sessions, or ~/.grok/sessions; 0
# without a home
grok_sessions:
    PROLOGUE
    lea rdi, [rip + .Lgrok_home]
    call getenv
    lea rsi, [rip + .Lsessions]
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 0
    jne 2f
1:  lea rdi, [rip + .Lhome]
    call getenv
    test rax, rax
    jz 9f
    lea rsi, [rip + .Lgrok_sessions]
2:  mov rdi, rax
    call path_join
9:  EPILOGUE

# sessions/<the cwd, URL-encoded>/<session id>/updates.jsonl: the folder name is not decoded, as a long
# one is a slug and a hash instead; summary.json beside the log names the cwd (grok_cwd)
grok_group_cb:
    PROLOGUE
    test edx, edx
    jz 9f
    call path_join
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + grok_session_cb]
    mov rdx, rbx
    call scan_dir
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

grok_session_cb:
    PROLOGUE
    test edx, edx
    jz 9f
    call path_join
    mov rbx, rax
    mov rdi, rax
    lea rsi, [rip + .Lgrok_log]
    call path_join
    mov r12, rax
    mov rdi, rbx
    call mem_free
    mov rdi, r12
    call file_stamp
    test rax, rax
    jz 8f                       # a folder without its log yet
    mov rdi, r12
    mov esi, 3
    xor edx, edx
    call index_file
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# index_file(path, kind, Claude cwd or 0): hash lookup and stat, parse changed metadata only.
index_file:
    PROLOGUE 32
    mov r12, rdi
    mov r13d, esi
    mov r14, rdx
    mov rdx, rdi
    mov rdi, [rip + table]
    mov esi, 262143
    call agent_table_find
    mov rbx, rax
    test rax, rax
    jnz 1f
    cmp qword ptr [rip + entries + VEC_len], 100000
    jae .Lindex_full
    mov edi, AS_SIZE
    call mem_alloc
    mov rbx, rax
    mov [rbx + AS_kind], r13d
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [rbx + AS_path], rax
    lea rdi, [rip + entries]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    mov rdi, [rip + table]
    mov esi, 262143
    mov rdx, rbx
    call agent_table_put
1:  mov qword ptr [rbx + AS_seen], 1
    mov rdi, r12
    call file_stamp
    mov r15, rax
    mov [rsp], rcx             # mtime and size from the same stat snapshot
    mov [rsp + 8], rdx
    cmp rax, [rbx + AS_stamp]
    jne 2f
    cmp qword ptr [rbx + AS_cwd], 0
    jne 9f
2:  mov rsi, [rbx + AS_stamp]
    xor rsi, [rbx + AS_recency]
    ror rsi, 32                # recover the previous size from file_stamp
    mov dword ptr [rsp + 24], 0
    cmp r13d, 1
    jne 3f
    mov rdx, [rsp + 8]
    mov rdi, rbx
    call claude_cwd
    test edx, edx
    jz 9f                     # unresolved reads retry, without guessing a slug identity
    mov [rsp + 24], ecx
    test rax, rax
    jnz 4f
    test r14, r14
    jz 4f
    mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    call mem_dup
    jmp 4f
3:  mov rdi, r12
    cmp r13d, 3
    je 33f
    call codex_cwd
    jmp 34f
33: call grok_cwd
34: test edx, edx
    jz 9f
4:  mov [rsp + 16], rax
    cmp dword ptr [rsp + 24], 0
    je 5f
    mov rdi, [rbx + AS_cwd]
    mov rsi, rax
    test rdi, rdi
    jz 5f
    test rsi, rsi
    jz 5f
.ifdef WINDOWS
    call win_path_equal
.else
    call strcmp_eq
.endif
    test eax, eax
    jnz 6f                    # same identity and verified append: keep the custom title
5:  cmp r13d, 1
    jne 51f
    mov rax, [rbx + AS_stamp]
    test rax, rax
    jz 51f
    cmp rax, r15
    je 51f
    mov qword ptr [rbx + AS_replaced], 1
51: mov rdi, [rbx + AS_title]
    call mem_free
    mov qword ptr [rbx + AS_title], 0
    mov dword ptr [rbx + AS_titled], 0
    mov qword ptr [rbx + AS_title_off], 0
    mov rdi, [rbx + AS_model]   # read again with the title
    call mem_free
    mov qword ptr [rbx + AS_model], 0
6:  mov [rbx + AS_stamp], r15
    mov rax, [rsp]
    mov [rbx + AS_recency], rax
    mov rdi, [rbx + AS_cwd]
    call mem_free
    mov rax, [rsp + 16]
    mov [rbx + AS_cwd], rax
    mov dword ptr [rbx + AS_pad], 0
    mov dword ptr [rbx + AS_loaded], 1 # newly parsed metadata needs an ownership proof
9:  EPILOGUE
.Lindex_full:
    mov dword ptr [rip + scan_failed], 1
    EPILOGUE

codex_cwd:
    PROLOGUE
    mov esi, 1 << 20
    call agent_read_first_line
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    mov rsi, rdx
    call json_parse
    mov rdi, rax
    lea rsi, [rip + .Lpayload]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lcwd]
    call json_get
    mov rdi, rax
    call json_str
    xor r12d, r12d
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r12, rax
1:  mov rdi, rbx
    call mem_free
    mov rax, r12
    mov edx, 1
    EPILOGUE
9:  xor edx, edx
    EPILOGUE

# grok_cwd(log) -> owned cwd, edx 1 when read (0: retry). A Grok Build session is listed once its log has
# a prompt (the interface makes the folder at its start), and a subagent's session (its parent's task)
# never is: both get an empty cwd, which matches no checkout and which scans keep until the log changes.
grok_cwd:
    PROLOGUE
    mov rbx, rdi
    mov esi, 262144
    call agent_read_head
    test rax, rax
    jz 8f
    mov r12, rax
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lgrok_prompt]
    mov ecx, 20
    call str_find
    mov r13, rax
    mov rdi, r12
    call mem_free
    test r13, r13
    js 6f
    mov rdi, rbx
    call agent_grok_summary
    test rax, rax
    jz 8f                       # being written: the next scan reads it again
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lsession_kind]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lsubagent]
    call json_is
    test eax, eax
    jnz 6f
    mov rdi, r12
    lea rsi, [rip + .Linfo]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lcwd]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov edx, 1
    EPILOGUE
6:  lea rdi, [rip + .Lempty]
    xor esi, esi
    call mem_dup
    mov edx, 1
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# Recover an exact nested checkout path from session metadata, without relying on its slug.
recover_roots:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + entries + VEC_len]
    jae 9f
    mov rax, [rip + entries + VEC_ptr]
    mov rax, [rax + rbx*8]
    mov rdi, [rax + AS_cwd]
    test rdi, rdi
    jz 2f
    call recover_nested
2:  inc rbx
    jmp 1b
9:  EPILOGUE

recover_nested:
    PROLOGUE
    mov r12, rdi
.ifdef WINDOWS
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov r12, rax
    mov rdi, rax
    call win_path_normalize
.endif
    mov rdi, r12
    call strlen
    mov r13, rax
    xor ebx, ebx
1:  cmp rbx, [rip + roots + VEC_len]
    jae 9f
    mov rax, [rip + roots + VEC_ptr]
    mov r14, [rax + rbx*8]
    cmp qword ptr [r14 + AW_name], 0
    jne 8f
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [r14 + AW_path]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lclaude_tree_path]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rip + tmp + SB_ptr]
    mov rcx, [rip + tmp + SB_len]
.ifdef WINDOWS
    cmp r13, rcx
    jb 8f
    mov rsi, rcx
    call mem_dup
    mov r15, rax
    mov rdi, rax
    mov rsi, [rip + tmp + SB_ptr]
    call win_path_equal
    mov r14d, eax
    mov rdi, r15
    call mem_free
    mov eax, r14d
.else
    call str_starts
.endif
    test eax, eax
    jz 8f
    mov rax, [rip + tmp + SB_len]
    lea r14, [r12 + rax]
    cmp byte ptr [r14], 0
    je 9f
    mov rax, r14
3:  cmp byte ptr [rax], 0
    je 4f
    cmp byte ptr [rax], '/'
    je 9f
    cmp byte ptr [rax], '\\'
    je 9f
    inc rax
    jmp 3b
4:  mov rdi, r14
    lea rsi, [rip + .Ldot]
    call strcmp_eq
    test eax, eax
    jnz 9f
    mov rdi, r14
    lea rsi, [rip + .Ldotdot]
    call strcmp_eq
    test eax, eax
    jnz 9f
    xor edi, edi
    mov rsi, r12
    mov edx, 1
    call root_add
    jmp 9f
8:  inc rbx
    jmp 1b
9:
.ifdef WINDOWS
    mov rdi, r12
    call mem_free
.endif
    EPILOGUE

# An existing remembered path may now be a checkout of an unrelated repository.
verify_roots:
    PROLOGUE
    mov r15, [rip + g_project]
    xor ebx, ebx
1:  cmp rbx, [rip + roots + VEC_len]
    jae 8f
    mov rax, [rip + roots + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov qword ptr [r12 + AW_guard], 0
    cmp qword ptr [r12 + AW_name], 0
    je 7f
    mov rdi, [r12 + AW_path]
    call file_is_dir
    test eax, eax
    jz 7f
    mov rax, [r12 + AW_path]
    mov [rip + g_project], rax
    call git_set_project
    call git_repository_id
    mov rdi, rax
    mov rsi, [rip + repository]
    test rdi, rdi
    jz 6f
    call same_dir
    test eax, eax
    jnz 7f
6:  mov qword ptr [r12 + AW_guard], 1
7:  inc rbx
    jmp 1b
8:  mov [rip + g_project], r15
    call git_set_project
    EPILOGUE

# same_dir(a, b) -> 1 when both paths name one folder: the same spelling, or the same folder on disk.
# Git writes a worktree's links as real paths, while the project may be spelled through a symlink
# (macOS's /tmp is /private/tmp): the spellings of one repository differ.
same_dir:
.ifdef WINDOWS
    jmp win_path_equal
.else
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    call strcmp_eq
    test eax, eax
    jnz 9f
    mov rdi, r12
    call file_id
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, r13
    call file_id
    test rax, rax
    jz 8f
    cmp rax, [rsp]
    jne 8f
    cmp rdx, [rsp + 8]
    jne 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE
.endif

# collect_matches(final): re-match cached cwd against known repository roots.
collect_matches:
    PROLOGUE
    mov r15d, edi
    mov qword ptr [rip + matches + VEC_len], 0
    xor ebx, ebx
.Lmatch_next:
    cmp rbx, [rip + entries + VEC_len]
    jae .Lmatch_done
    mov rax, [rip + entries + VEC_ptr]
    mov r12, [rax + rbx*8]
    test r15d, r15d
    jz 1f
    cmp qword ptr [r12 + AS_seen], 0
    je .Lmatch_skip
1:  cmp dword ptr [r12 + AS_kind], 4
    jne 11f
    mov rax, [rip + opencode_scope]
    test rax, rax
    jz .Lmatch_skip
    cmp rax, [r12 + AS_prefix_hash]
    jne .Lmatch_skip            # a cached page cannot expose another data profile's sessions
11: lea rdi, [rip + .Lclaude]
    cmp dword ptr [r12 + AS_kind], 1
    je 2f
    lea rdi, [rip + .Lcodex]
    cmp dword ptr [r12 + AS_kind], 2
    je 2f
    lea rdi, [rip + .Lgrok]
    cmp dword ptr [r12 + AS_kind], 3
    je 2f
    lea rdi, [rip + .Lopencode]
2:  call has_source
    test eax, eax
    jz .Lmatch_skip
    cmp qword ptr [r12 + AS_cwd], 0
    je .Lmatch_skip
    xor r13d, r13d
3:  cmp r13, [rip + roots + VEC_len]
    jae .Lmatch_skip
    mov rax, [rip + roots + VEC_ptr]
    mov r14, [rax + r13*8]
    mov rdi, [r12 + AS_cwd]
    mov rsi, [r14 + AW_path]
.ifdef WINDOWS
    call win_path_equal
.else
    call strcmp_eq
.endif
    test eax, eax
    jnz 4f
    inc r13
    jmp 3b
4:  cmp qword ptr [r14 + AW_name], 0
    je 42f
    mov rdi, r12
    call member_check
    cmp eax, -1
    je .Lmatch_skip
    cmp qword ptr [r14 + AW_guard], 0
    je 41f
    test eax, eax
    jnz 42f
    test r15d, r15d
    jz .Lmatch_skip
    mov rdi, r12
    mov esi, 1
    call member_save
    jmp .Lmatch_skip
41: test eax, eax
    jnz 42f
    test r15d, r15d
    jz 42f
    cmp dword ptr [r12 + AS_loaded], 0
    je 42f
    mov rdi, r12
    xor esi, esi
    call member_save
42: mov rdi, [r12 + AS_worktree]
    call mem_free
    mov qword ptr [r12 + AS_worktree], 0
    mov rdi, [r14 + AW_name]
    test rdi, rdi
    jz 5f
    call strlen
    mov rdi, [r14 + AW_name]
    mov rsi, rax
    call mem_dup
    mov [r12 + AS_worktree], rax
5:  lea rdi, [rip + matches]
    mov esi, 8
    call vec_push
    mov [rax], r12
.Lmatch_skip:
    inc rbx
    jmp .Lmatch_next
.Lmatch_done:
    call sort_matches
    test r15d, r15d
    jz 9f
    xor ebx, ebx
6:  cmp rbx, [rip + page_limit]
    jae 9f
    cmp rbx, [rip + matches + VEC_len]
    jae 9f
    mov rax, [rip + matches + VEC_ptr]
    mov r12, [rax + rbx*8]
    cmp dword ptr [r12 + AS_kind], 4
    je 7f
    cmp dword ptr [r12 + AS_pad], 0
    jne 7f
    mov rdi, r12
    call agent_session_header
    mov r14d, eax
    mov rdi, r12
    call agent_session_tail_title
    and eax, r14d
    mov [r12 + AS_pad], eax
    test eax, eax
    jz 7f
    mov rax, [r12 + AS_stamp]
    xor rax, [r12 + AS_recency]
    ror rax, 32
    mov [r12 + AS_title_off], rax
    # Grok Build titles a session itself, in summary.json: that file changes without the log
7:  cmp dword ptr [r12 + AS_kind], 3
    jne 71f
    mov rdi, r12
    call agent_grok_title
71: inc rbx
    jmp 6b
9:  EPILOGUE

# Heap sort by descending mtime, path ascending breaks ties deterministically.
sort_matches:
    PROLOGUE
    mov r12, [rip + matches + VEC_ptr]
    mov r13, [rip + matches + VEC_len]
    cmp r13, 2
    jb 9f
    mov rbx, r13
    shr rbx, 1
1:  test rbx, rbx
    jz 2f
    dec rbx
    mov rdi, rbx
    mov rsi, r13
    call sort_sift
    jmp 1b
2:  mov r14, r13
3:  dec r14
    jz 9f
    mov rax, [r12]
    mov rcx, [r12 + r14*8]
    mov [r12], rcx
    mov [r12 + r14*8], rax
    xor edi, edi
    mov rsi, r14
    call sort_sift
    jmp 3b
9:  EPILOGUE

# later(a,b) -> 1 when a belongs later in the final list.
later:
    mov rax, [rdi + AS_recency]
    cmp rax, [rsi + AS_recency]
    jne 1f
    mov rdi, [rdi + AS_path]
    mov rsi, [rsi + AS_path]
2:  movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    cmp eax, ecx
    jne 3f
    test eax, eax
    jz 4f
    inc rdi
    inc rsi
    jmp 2b
3:  seta al
    movzx eax, al
    ret
1:  setb al
    movzx eax, al
    ret
4:  xor eax, eax
    ret
sort_sift:
    PROLOGUE 32
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov rax, [r12 + rdi*8]
    mov [rsp + 16], rax
1:  mov rdi, [rsp]
    lea rbx, [rdi*2 + 1]
    cmp rbx, [rsp + 8]
    jae 4f
    lea r15, [rbx + 1]
    cmp r15, [rsp + 8]
    jae 2f
    mov rdi, [r12 + r15*8]
    mov rsi, [r12 + rbx*8]
    call later
    test eax, eax
    cmovnz rbx, r15
2:  mov rdi, [r12 + rbx*8]
    mov rsi, [rsp + 16]
    call later
    test eax, eax
    jz 4f
    mov rax, [r12 + rbx*8]
    mov rcx, [rsp]
    mov [r12 + rcx*8], rax
    mov [rsp], rbx
    jmp 1b
4:  mov rcx, [rsp]
    mov rax, [rsp + 16]
    mov [r12 + rcx*8], rax
    EPILOGUE

.section .rodata
.Lhome: .asciz "HOME"
.Lclaude_config_dir: .asciz "CLAUDE_CONFIG_DIR"
.Lcodex_home: .asciz "CODEX_HOME"
.Lprojects: .asciz "/projects/"
.Lclaude_projects: .asciz "/.claude/projects/"
.Lcodex_sessions: .asciz ".codex/sessions"
.Lcodex_worktrees: .ascii "/.codex/worktrees/"
.Ljsonl: .ascii ".jsonl"
.Lclaude: .asciz "claude"
.Lcodex: .asciz "codex"
.Lgrok: .asciz "grok"
.Lopencode: .asciz "opencode"
.Lgrok_home: .asciz "GROK_HOME"
.Lsessions: .asciz "sessions"
.Lgrok_sessions: .asciz ".grok/sessions"
.Lgrok_log: .asciz "updates.jsonl"
.Lgrok_prompt: .ascii "\"user_message_chunk\""
.Lsession_kind: .asciz "session_kind"
.Lsubagent: .asciz "subagent"
.Linfo: .asciz "info"
.Lparams: .asciz "params"
.Lempty: .asciz ""
.Lpayload: .asciz "payload"
.Lcwd: .asciz "cwd"
.Lcache_prefix: .asciz "/agents-index-v6-"
.Lhistory_prefix: .asciz "/agents-worktrees-v1-"
.Lhistory_dir_prefix: .asciz "/agents-worktrees-v2-"
.Lhistory_suffix: .asciz ".root"
.Lmember_suffix: .asciz ".member"
.Ltemp_prefix: .ascii ".rhun-"
.Ltemp_suffix: .ascii ".tmp"
.Lsession_id: .asciz "session_id"
.Lid: .asciz "id"
.Lclaude_session_id: .asciz "sessionId"
.Lclaude_tree_slug: .asciz "--claude-worktrees-"
.Lclaude_tree_path: .asciz "/.claude/worktrees/"
.Ldot: .asciz "."
.Ldotdot: .asciz ".."

.text
# claude_cwd(s, old size, new size) -> owned cwd, edx read success, ecx verified append.
# Select a cwd whose encoded path matches the transcript's directory. Attachments
# can name the main checkout before a later record names the actual worktree.
claude_cwd:
    PROLOGUE 64
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov dword ptr [rsp + 16], 0
    mov [rsp + 24], rdi
    mov rdi, [rdi + AS_path]
    call strlen
    mov rsi, rax
    mov rax, [rsp + 24]
    mov rdi, [rax + AS_path]
    call path_dirlen
    mov rsi, rax
    mov rax, [rsp + 24]
    mov rdi, [rax + AS_path]
    call mem_dup
    mov [rsp + 32], rax
    mov rax, [rsp + 24]
    mov rdi, [rax + AS_path]
    mov esi, 262144
    call agent_read_head
    test rax, rax
    jz .Lcwd_error
    mov r12, rax
    mov r13, rdx
    mov r14, [rsp + 24]
    mov rsi, [rsp]
    test rsi, rsi
    jz 6f
    cmp rsi, [rsp + 8]
    ja 6f                       # it shrank
    jb 5f
    cmp rsi, 262144             # the same size: unchanged (a touch) only if the hash covers it all
    ja 6f
5:  mov eax, 262144
    cmp rsi, rax
    cmova rsi, rax
    cmp rsi, r13
    ja 6f
    mov rdi, r12
    call hash_line
    cmp rax, [r14 + AS_prefix_hash]
    jne 6f
    mov dword ptr [rsp + 16], 1
    # the prefix the next run checks is the size this stat saw (the stamp's), not what was read: a
    # line appended since the stat would make the next append look like a rewrite
6:  mov rdi, r12
    mov rsi, r13
    mov rax, [rsp + 8]
    cmp rsi, rax
    cmova rsi, rax
    call hash_line
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], -1  # head first, then bounded streaming if needed
    mov dword ptr [rsp + 56], 0
    xor r15d, r15d
.Lcwd_buffer:
    xor ebx, ebx
    cmp dword ptr [rsp + 56], 0
    je .Lcwd_line
.Lcwd_skip:
    cmp rbx, r13
    jae .Lcwd_advance
    mov al, [r12 + rbx]
    inc rbx
    cmp al, 10
    jne .Lcwd_skip
    mov dword ptr [rsp + 56], 0
.Lcwd_line:
    mov r14, rbx
1:  cmp r14, r13
    jae .Lcwd_partial
    cmp byte ptr [r12 + r14], 10
    je 2f
    inc r14
    jmp 1b
2:  lea rdi, [r12 + rbx]
    mov rsi, r14
    sub rsi, rbx
    mov rdx, [rsp + 32]
    call claude_cwd_line
    test rax, rax
    jnz .Lcwd_found
    lea rbx, [r14 + 1]
    jmp .Lcwd_line
.Lcwd_partial:
    cmp qword ptr [rsp + 48], -1
    jne 3f
    cmp r13, 262144
    je .Lcwd_advance
    jmp 4f
3:  cmp r13, 1 << 20
    je .Lcwd_advance
4:  lea rdi, [r12 + rbx]
    mov rsi, r13
    sub rsi, rbx
    mov rdx, [rsp + 32]
    call claude_cwd_line
    test rax, rax
    jnz .Lcwd_found
    jmp .Lcwd_done
.Lcwd_advance:
    cmp qword ptr [rsp + 48], -1
    jne 5f
    mov qword ptr [rsp + 48], 0
    jmp .Lcwd_read
5:  cmp r13, 1 << 20
    jb .Lcwd_done
    test rbx, rbx
    jnz 7f
    mov rbx, r13
    mov dword ptr [rsp + 56], 1 # a record over 1 MiB is skipped without allocating it
7:  add [rsp + 48], rbx
.Lcwd_read:
    mov rdi, r12
    call mem_free
    mov rax, [rsp + 24]
    mov rdi, [rax + AS_path]
    mov esi, 1 << 20
    mov rdx, [rsp + 48]
    call agent_read_window
    test rax, rax
    jz .Lcwd_error
    mov r12, rax
    mov r13, rdx
    jmp .Lcwd_buffer
.Lcwd_found:
    mov r15, rax
.Lcwd_done:
    mov rdi, r12
    call mem_free
    mov rdi, [rsp + 32]
    call mem_free
    mov rax, [rsp + 24]
    mov rdx, [rsp + 40]
    mov [rax + AS_prefix_hash], rdx
    mov rax, r15
    mov edx, 1
    mov ecx, [rsp + 16]
    EPILOGUE
.Lcwd_error:
    mov rdi, [rsp + 32]
    call mem_free
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    EPILOGUE

# claude_cwd_line(JSON line, bytes, directory) -> exact owned cwd or 0.
claude_cwd_line:
    PROLOGUE AW_SIZE
    mov r12, rdx
    call json_parse
    mov rdi, rax
    lea rsi, [rip + .Lcwd]
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jz 9f
    test rdx, rdx
    jz 9f
    cmp rdx, 4096
    ja 9f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rbx, rax
    mov [rsp + AW_path], rax
    mov qword ptr [rsp + AW_claude], 0
    mov qword ptr [rsp + AW_name], 0
    mov rdi, rsp
    call claude_root
    mov rdi, [rsp + AW_claude]
    test rdi, rdi
    jz 8f
    mov rsi, r12
.ifdef WINDOWS
    call win_path_equal
.else
    call strcmp_eq
.endif
    mov r13d, eax
    mov rdi, [rsp + AW_claude]
    call mem_free
    test r13d, r13d
    jz 8f
    mov rax, rbx
    EPILOGUE
8:  mov rdi, rbx
    call mem_free
9:  xor eax, eax
    EPILOGUE

# OpenCode metadata and materialized transcripts share the existing paging/ownership machinery.
# AS_part holds the next snapshot in the worker; AS_title_off is its last exported revision.
.text
opencode_scan:
    PROLOGUE 32
    lea rdi, [rip + .Lopencode]
    call has_source
    test eax, eax
    jz 9f
    # Without its data folder OpenCode has never run for this user: nothing to list, nothing to set up.
    call agent_opencode_data_dir
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    call file_is_dir
    mov r12d, eax
    xor r13d, r13d
    test eax, eax
    jz 12f
    call agent_opencode_init
    mov r13d, eax
    test eax, eax
    jz 12f
    mov rdi, rbx
    call agent_opencode_cli_key
    mov [rip + opencode_cli_key], rax
12: mov rdi, rbx
    call mem_free
    test r12d, r12d
    jz 9f
    test r13d, r13d
    jnz 1f
    mov dword ptr [rip + opencode_status], 1
    jmp .Loc_scan_keep
1:
    # Each CLI start costs about a second of CPU: the path and version it reports are kept until the CLI
    # changes.
    lea rdi, [rip + opencode_state]
    call sb_clear
    cmp qword ptr [rip + cache_file + SB_len], 0
    je 13f
    lea rdi, [rip + opencode_state]
    mov rsi, [rip + cache_file + SB_ptr]
    call sb_push_cstr
    lea rdi, [rip + opencode_state]
    lea rsi, [rip + .Loc_state]
    call sb_push_cstr
13: call opencode_state_load
    test eax, eax
    jnz 14f
    call agent_opencode_locate
    test rax, rax
    jz .Loc_scan_fail
    mov rbx, rax
    mov r12, rdx
    lea rdi, [rip + opencode_db]
    call sb_clear
    lea rdi, [rip + opencode_db]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    # Copies are kept per database and repository: a complete listing removes those not in it.
14: lea rdi, [rip + opencode_ident]
    call sb_clear
    lea rdi, [rip + opencode_ident]
    mov rsi, [rip + opencode_db + SB_ptr]
    mov rdx, [rip + opencode_db + SB_len]
    call sb_push
    lea rdi, [rip + opencode_ident]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + opencode_ident]
    mov rsi, [rip + cache_key + SB_ptr]
    mov rdx, [rip + cache_key + SB_len]
    call sb_push
    mov rdi, [rip + opencode_ident + SB_ptr]
    mov rsi, [rip + opencode_ident + SB_len]
    call hash_line
    mov rsi, rax
    mov rdi, rsp
    call fmt_hex
    mov [rsp + 24], rax
    lea rdi, [rip + opencode_dir]
    call session_state_dir
    test eax, eax
    jz .Loc_scan_fail
    lea rdi, [rip + opencode_dir]
    lea rsi, [rip + .Loc_cache]
    call sb_push_cstr
    lea rdi, [rip + opencode_dir]
    mov rsi, rsp
    mov rdx, [rsp + 24]
    call sb_push
    mov rdi, [rip + opencode_dir + SB_ptr]
.ifdef WINDOWS
    call mkdir_p
.else
    mov esi, 0700
    SYS SYS_mkdir
.endif
    cmp rax, -17              # EEXIST: the cache is normally already present
    je 11f
    test rax, rax
    js .Loc_scan_fail
11:
.ifndef WINDOWS
    mov rdi, [rip + opencode_dir + SB_ptr]
    mov esi, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js .Loc_scan_fail
    mov r15d, eax
    mov edi, eax
    mov esi, 0700              # transcripts contain conversation text, not just metadata
    SYS SYS_fchmod
    mov [rsp + 16], rax
    mov edi, r15d
    SYS SYS_close
    cmp qword ptr [rsp + 16], 0
    jne .Loc_scan_fail
.endif
    mov rdi, [rip + opencode_dir + SB_ptr]
    call stale_temps            # a copy the app stopped in the middle of its save
    lea rdi, [rip + opencode_sql]
    call sb_clear
    call opencode_metadata_sql
    lea rdi, [rip + opencode_sql]
    mov rsi, rax
    call sb_push_cstr
    xor ebx, ebx
2:  cmp rbx, [rip + roots + VEC_len]
    jae 3f
    test rbx, rbx
    jz 21f
    lea rdi, [rip + opencode_sql]
    mov esi, ','
    call sb_push_byte
21: mov rax, [rip + roots + VEC_ptr]
    mov rax, [rax + rbx*8]
    mov rsi, [rax + AW_path]
    lea rdi, [rip + opencode_sql]
    call agent_opencode_quote
    inc rbx
    jmp 2b
3:  lea rdi, [rip + opencode_sql]
    mov esi, ')'
    call sb_push_byte
.ifdef WINDOWS
    cmp qword ptr [rip + opencode_sql + SB_len], 24000
    ja .Loc_scan_fail
.endif
    call opencode_identify
    mov [rip + opencode_scan_key], rax
    test rax, rax
    jz 4f
    cmp rax, [rip + opencode_st + 16]
    jne 4f
    mov rax, [rip + opencode_rows]
    cmp rax, [rip + opencode_st + 24]
    jne 4f                      # the cache does not hold the rows saved with this state
    call time_now
    sub rax, [rip + opencode_st + 32]
    cmp rax, OPENCODE_RESCAN
    jae 4f
    # A worktree path another repository took over: a row's proof of membership needs its session ID,
    # which only the listing has for a conversation never copied.
    xor ebx, ebx
5:  cmp rbx, [rip + roots + VEC_len]
    jae 6f
    mov rax, [rip + roots + VEC_ptr]
    mov rax, [rax + rbx*8]
    cmp qword ptr [rax + AW_guard], 0
    jne 4f
    inc rbx
    jmp 5b
6:  # Nothing was written to the database: the cached rows stand in for the query.
    mov rax, [rip + opencode_st + 32]
    mov [rip + opencode_time], rax
    mov dword ptr [rip + opencode_skip], 1
    mov dword ptr [rip + opencode_good], 1
    call opencode_keep
    jmp 9f
4:  call opencode_metadata
9:  EPILOGUE
.Loc_scan_fail:
    mov dword ptr [rip + opencode_status], 2
.Loc_scan_keep:
    # Retain this provider's last snapshot on failure while allowing other sources to refresh.
    call opencode_keep
    jmp 9b

# opencode_keep(): the cached OpenCode rows stay listed (a missing CLI, a failed or skipped query).
opencode_keep:
    xor ecx, ecx
1:  cmp rcx, [rip + entries + VEC_len]
    jae 9f
    mov rax, [rip + entries + VEC_ptr]
    mov rax, [rax + rcx*8]
    cmp dword ptr [rax + AS_kind], 4
    jne 2f
    mov qword ptr [rax + AS_seen], 1
2:  inc rcx
    jmp 1b
9:  ret

# opencode_metadata(): the metadata query in opencode_sql; a failure keeps the cached rows.
opencode_metadata:
    PROLOGUE
    mov rdi, [rip + opencode_sql + SB_ptr]
    mov rsi, [rip + opencode_db + SB_ptr]
    call agent_opencode_query
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + opencode_metadata_line]
    call agent_opencode_each_line
    test eax, eax
    jz 8f
    call time_now
    mov [rip + opencode_time], rax
    xor eax, eax
    cmp qword ptr [rip + opencode_scan_key], 0
    setne al
    mov [rip + opencode_good], eax
    cmp qword ptr [rip + cache_key + SB_len], 0
    je 9f                       # without a repository's identity the folder is shared
    mov rdi, [rip + opencode_dir + SB_ptr]
    lea rsi, [rip + opencode_prune_cb]
    xor edx, edx
    call dir_each
9:  EPILOGUE
8:  mov dword ptr [rip + opencode_status], 2
    mov dword ptr [rip + opencode_good], 0
    call opencode_state_forget
    call opencode_keep
    EPILOGUE

# opencode_state_forget(): a query failed, so the next run asks the CLI for its version and database
#   again: the CLI can change behind a file whose stamp stays, a script that runs another installation.
opencode_state_forget:
    PROLOGUE
    mov dword ptr [rip + opencode_good], 0 # nor saved again with the cache at the run's end
    cmp qword ptr [rip + opencode_state + SB_len], 0
    je 9f
    mov rdi, [rip + opencode_state + SB_ptr]
    SYS SYS_unlink
9:  EPILOGUE

# opencode_prune_cb(0, name, folder): the copy of a session this complete listing does not have any more
#   (deleted, archived, moved) is removed: a transcript is not kept after OpenCode lets it go.
opencode_prune_cb:
    PROLOGUE
    test edx, edx
    jnz 9f
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rip + .Loc_jsonl]
    mov ecx, 6
    call str_ends
    test eax, eax
    jz 9f
    mov rdi, [rip + opencode_dir + SB_ptr]
    mov rsi, r12
    call path_join
    mov rbx, rax
    mov rdi, [rip + table]
    mov esi, 262143
    mov rdx, rax
    call agent_table_find
    test rax, rax
    jz 1f
    cmp qword ptr [rax + AS_seen], 0
    jne 2f
1:  mov rdi, rbx
    SYS SYS_unlink
2:  mov rdi, rbx
    call mem_free
9:  EPILOGUE

# opencode_identify() -> identity of the listing: the query and roots, the CLI and the writes to its database, or 0
#   when the database cannot be identified. OpenCode checkpoints its write-ahead log on every start, also
#   for a read, which rewrites the database file; the log itself changes only with a write. Without a
#   log (another journal mode) every write goes to the database file.
opencode_identify:
    PROLOGUE 48
    mov rbx, [rip + opencode_db + SB_ptr]
    test rbx, rbx
    jz 8f
    PATH_ABSOLUTE rbx, 1f
    jmp 8f
1:  mov rdi, rbx
    call file_id
    test rax, rax
    jz 8f
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rbx
    call file_stamp
    mov [rsp + 16], rax
    mov r12, rdx
    lea rdi, [rip + opencode_path]
    call sb_clear
    lea rdi, [rip + opencode_path]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + opencode_path]
    lea rsi, [rip + .Loc_wal]
    call sb_push_cstr
    mov rdi, [rip + opencode_path + SB_ptr]
    call file_stamp
    mov [rsp + 24], rax
    test rax, rax
    jz 2f
    mov [rsp + 16], r12         # with a log, the database's size alone
2:  lea rdi, [rip + opencode_ident]
    call sb_clear
    lea rdi, [rip + opencode_ident]
    mov rsi, rsp
    mov edx, 32
    call sb_push
    lea rdi, [rip + opencode_ident]
    lea rsi, [rip + opencode_cli_key]
    mov edx, 8
    call sb_push
    lea rdi, [rip + opencode_ident]
    mov rsi, [rip + opencode_db + SB_ptr]
    mov rdx, [rip + opencode_db + SB_len]
    call sb_push
    call opencode_metadata_sql
    lea rdi, [rip + opencode_ident]
    mov rsi, rax
    call sb_push_cstr
    # the roots in any order: windows of one repository list them in their own order
    xor r13d, r13d
    xor r14d, r14d
3:  cmp r14, [rip + roots + VEC_len]
    jae 4f
    mov rax, [rip + roots + VEC_ptr]
    mov rax, [rax + r14*8]
    mov r15, [rax + AW_path]
    mov rdi, r15
    call strlen
    mov rsi, rax
    mov rdi, r15
    call hash_line
    add r13, rax
    inc r14
    jmp 3b
4:  mov [rsp + 32], r13
    mov [rsp + 40], r14
    lea rdi, [rip + opencode_ident]
    lea rsi, [rsp + 32]
    mov edx, 16
    call sb_push
    mov rdi, [rip + opencode_ident + SB_ptr]
    mov rsi, [rip + opencode_ident + SB_len]
    call hash_line
    test rax, rax
    jnz 9f
    inc rax
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE

# opencode_state_load() -> 1 when the saved state is for this CLI: opencode_st holds it and opencode_db
#   the database path the CLI reported. 0 otherwise, with opencode_st cleared.
opencode_state_load:
    PROLOGUE
    lea rax, [rip + opencode_st]
    xor ecx, ecx
1:  mov qword ptr [rax + rcx*8], 0
    inc ecx
    cmp ecx, 6
    jb 1b
    cmp qword ptr [rip + opencode_state + SB_len], 0
    je 9f
    mov rdi, [rip + opencode_state + SB_ptr]
    mov esi, 48 + 4096
    call agent_read_head
    test rax, rax
    jz 9f
    mov rbx, rax
    mov r12, rdx
    cmp r12, 49
    jb 8f
    cmp r12, 48 + 4095
    ja 8f
    mov rax, 0x325453434f484152   # RAHOCST2
    cmp [rbx], rax
    jne 8f
    mov rax, [rbx + 8]
    cmp rax, [rip + opencode_cli_key]
    jne 8f
    cmp qword ptr [rbx + 40], 1
    ja 8f
    lea rdi, [rip + opencode_db]
    call sb_clear
    lea rdi, [rip + opencode_db]
    lea rsi, [rbx + 48]
    lea rdx, [r12 - 48]
    call sb_push
    lea rdx, [rip + opencode_st]
    xor ecx, ecx
2:  mov rax, [rbx + rcx*8]
    mov [rdx + rcx*8], rax
    inc ecx
    cmp ecx, 6
    jb 2b
    mov eax, [rbx + 40]         # the version the path came with: the CLI file has not changed since
    mov [rip + agent_opencode_v2], eax
    mov rdi, rbx
    call mem_free
    mov eax, 1
    EPILOGUE
8:  mov rdi, rbx
    call mem_free
9:  xor eax, eax
    EPILOGUE

# opencode_state_save(rows hash): after a run with current OpenCode rows, what the next run compares;
#   the hash is of the rows as cached, so a later run skips the query only with these rows.
opencode_state_save:
    PROLOGUE 48
    cmp dword ptr [rip + opencode_good], 0
    je 9f
    cmp qword ptr [rip + opencode_state + SB_len], 0
    je 9f
    mov rax, 0x325453434f484152   # RAHOCST2
    mov [rsp], rax
    mov rax, [rip + opencode_cli_key]
    mov [rsp + 8], rax
    mov rax, [rip + opencode_scan_key]
    mov [rsp + 16], rax
    mov [rsp + 24], rdi
    mov rax, [rip + opencode_time]
    mov [rsp + 32], rax
    mov eax, [rip + agent_opencode_v2]
    mov [rsp + 40], rax
    lea rdi, [rip + opencode_st]
    mov rsi, rsp
    mov edx, 48
    call memeq
    test eax, eax
    jnz 9f                      # as saved: not written (and synced) again on every run
    lea rdi, [rip + opencode_ident]
    call sb_clear
    lea rdi, [rip + opencode_ident]
    mov rsi, rsp
    mov edx, 48
    call sb_push
    lea rdi, [rip + opencode_ident]
    mov rsi, [rip + opencode_db + SB_ptr]
    mov rdx, [rip + opencode_db + SB_len]
    call sb_push
    mov rdi, [rip + opencode_state + SB_ptr]
    mov rsi, [rip + opencode_ident + SB_ptr]
    mov rdx, [rip + opencode_ident + SB_len]
    call file_write_all
9:  EPILOGUE

# opencode_rows_hash(seen only) -> identity of the cached OpenCode rows, in any order: their copies,
#   revisions and exported revisions. Windows of one repository share the cache, each with its own
#   worktree badges, and still agree on these rows.
opencode_rows_hash:
    PROLOGUE 32
    mov r14d, edi
    xor r12d, r12d
    xor r13d, r13d
    xor ebx, ebx
1:  cmp rbx, [rip + entries + VEC_len]
    jae 3f
    mov rax, [rip + entries + VEC_ptr]
    mov r15, [rax + rbx*8]
    cmp dword ptr [r15 + AS_kind], 4
    jne 2f
    test r14d, r14d
    jz 11f
    cmp qword ptr [r15 + AS_seen], 0
    je 2f
11: mov rdi, [r15 + AS_path]
    call strlen
    mov rsi, rax
    mov rdi, [r15 + AS_path]
    call hash_line
    mov [rsp], rax
    mov rax, [r15 + AS_title_rev]
    mov [rsp + 8], rax
    mov rax, [r15 + AS_title_off]
    mov [rsp + 16], rax
    mov rax, [r15 + AS_stamp]
    mov [rsp + 24], rax
    mov rdi, rsp
    mov esi, 32
    call hash_line
    add r12, rax
    inc r13
2:  inc rbx
    jmp 1b
3:  mov rax, 0x9e3779b97f4a7c15
    imul rax, r13
    add rax, r12
    EPILOGUE

# opencode_pending() -> 1 when a listed conversation (on the page, or the open one) lacks its current
#   snapshot: one never exported, or a file changed or removed since.
opencode_pending:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + matches + VEC_len]
    jae 8f
    mov rax, [rip + matches + VEC_ptr]
    mov r12, [rax + rbx*8]
    cmp dword ptr [r12 + AS_kind], 4
    jne 3f
    cmp rbx, [rip + page_limit]
    jb 2f
    mov rsi, [rip + opencode_open]
    test rsi, rsi
    jz 3f
    mov rdi, [r12 + AS_path]
    call strcmp_eq
    test eax, eax
    jz 3f
2:  mov rax, [r12 + AS_title_off]
    cmp rax, [r12 + AS_title_rev]
    jne 9f
    mov rdi, [r12 + AS_path]
    call file_stamp
    cmp rax, [r12 + AS_stamp]
    jne 9f
3:  inc rbx
    jmp 1b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# opencode_session_path(id) -> borrowed path, hashed under the CLI's actual database path.
opencode_session_path:
    PROLOGUE 32
    mov rbx, rdi
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call hash_line
    mov rsi, rax
    mov rdi, rsp
    call fmt_hex
    mov r12, rax
    lea rdi, [rip + opencode_path]
    call sb_clear
    lea rdi, [rip + opencode_path]
    mov rsi, [rip + opencode_dir + SB_ptr]
    call sb_push_cstr
    lea rdi, [rip + opencode_path]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + opencode_path]
    mov rsi, rsp
    mov rdx, r12
    call sb_push
    lea rdi, [rip + opencode_path]
    lea rsi, [rip + .Loc_jsonl]
    call sb_push_cstr
    mov rax, [rip + opencode_path + SB_ptr]
    EPILOGUE

opencode_metadata_line:
    PROLOGUE 32
    mov [rsp], rdi
    mov [rsp + 8], rsi
    call json_parse
    test rax, rax
    jz 8f
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lid]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 8f
    mov r13, rax
    mov rdi, rax
    call opencode_session_path
    mov rdx, rax
    mov rdi, [rip + table]
    mov esi, 262143
    call agent_table_find
    mov rbx, rax
    test rax, rax
    jnz 1f
    cmp qword ptr [rip + entries + VEC_len], 100000
    jae 8f
    mov edi, AS_SIZE
    call mem_alloc
    mov rbx, rax
    mov dword ptr [rbx + AS_kind], 4
    mov rdi, [rip + opencode_path + SB_ptr]
    call strlen
    mov rsi, rax
    mov rdi, [rip + opencode_path + SB_ptr]
    call mem_dup
    mov [rbx + AS_path], rax
    lea rdi, [rip + entries]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    mov rdi, [rip + table]
    mov esi, 262143
    mov rdx, rbx
    call agent_table_put
1:  mov rdi, [rbx + AS_index_title]
    call mem_free
    mov rdi, r13
    call strlen
    mov rsi, rax
    mov rdi, r13
    call mem_dup
    mov [rbx + AS_index_title], rax # worker-only session ID
    mov rdi, r12
    lea rsi, [rip + .Lcwd]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r14, rax
.ifdef WINDOWS
    mov rdi, r14
    call win_slashes
.endif
    mov rdi, [rbx + AS_cwd]
    call mem_free
    mov [rbx + AS_cwd], r14
    mov rdi, r12
    lea rsi, [rip + .Loc_updated]
    call json_get
    # Numbers are kept as their original bytes by the shared JSON parser.
    test rax, rax
    jz 8f
    cmp dword ptr [rax], JT_NUM
    jne 8f
    mov esi, [rax + 4]
    mov rdi, [rax + 8]
    call parse_u64
    mov rcx, 9223372036854
    cmp rax, rcx
    ja 8f
    imul rax, rax, 1000000
    mov [rbx + AS_recency], rax
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    mov [rbx + AS_mtime], rax
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call hash_line
    shl rax, 1
    shr rax, 1
    mov [rbx + AS_off], rax     # desired snapshot revision, distinct from file byte offsets
    lea rdi, [rbx + AS_part]
    call sb_clear
    lea rdi, [rbx + AS_part]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
    lea rdi, [rbx + AS_part]
    mov esi, 10
    call sb_push_byte
    # A snapshot is written once the row is on the page or open (opencode_refresh).
    mov rdi, [rbx + AS_path]
    call file_stamp
    cmp rax, [rbx + AS_stamp]
    je 21f
    mov qword ptr [rbx + AS_title_off], 0 # missing or externally replaced snapshots are rebuilt
21: mov [rbx + AS_stamp], rax
    mov qword ptr [rbx + AS_seen], 1
    mov dword ptr [rbx + AS_loaded], 1
    mov dword ptr [rbx + AS_pad], 1
    mov rax, [rip + opencode_scope]
    mov [rbx + AS_prefix_hash], rax
    # the revision ends with the copy's estimated size, "time:count:size:estimate"; read before ingest_line
    # parses the line again, in the same JSON arena
    mov rdi, r12
    lea rsi, [rip + .Loc_revision]
    call json_get
    mov rdi, rax
    call json_str
    mov rcx, rdx
3:  test rcx, rcx
    jz 4f
    cmp byte ptr [rax + rcx - 1], ':'
    je 4f
    dec rcx
    jmp 3b
4:  lea rdi, [rax + rcx]
    mov rsi, rdx
    sub rsi, rcx
    call parse_u64
    mov [rbx + AS_bytes], rax
    mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    xor ecx, ecx
    call ingest_line
    mov rax, [rbx + AS_off]
    mov [rbx + AS_title_rev], rax
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# Refresh changed visible conversations in one CLI invocation, including a pinned open row.
opencode_refresh:
    PROLOGUE
    cmp dword ptr [rip + opencode_status], 0
    jne 9f
    cmp qword ptr [rip + opencode_dir + SB_len], 0
    je 9f
    cmp dword ptr [rip + opencode_skip], 0
    je 10f
    call opencode_pending
    test eax, eax
    jz 9f
    # The cache keeps no session IDs: the query supplies them for the snapshots to export.
    mov dword ptr [rip + opencode_skip], 0
    call opencode_metadata
    cmp dword ptr [rip + opencode_status], 0
    jne 9f
    mov edi, 1
    call collect_matches
10: mov r13d, 1                 # the open conversation first, then the page
1:  mov edi, r13d
    call opencode_batch
    cmp dword ptr [rip + opencode_status], 0
    jne 9f                      # a copy could not be saved
    test eax, eax
    jnz 2f
    dec r13d
    jns 1b
    jmp 9f
2:
.ifdef WINDOWS
    cmp qword ptr [rip + opencode_sql + SB_len], 24000
    ja 8f
.endif
    mov rdi, [rip + opencode_sql + SB_ptr]
    mov rsi, [rip + opencode_db + SB_ptr]
    call agent_opencode_query
    test rax, rax
    jnz 3f
    cmp rdx, -1
    je 9f                       # out of time: the next run goes on
    cmp rdx, -2
    jne 81f
    call opencode_overflow
    jmp 1b
3:  mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + opencode_part_line]
    call agent_opencode_each_line
    test eax, eax
    jz 81f
    xor ebx, ebx
4:  cmp rbx, [rip + matches + VEC_len]
    jae 1b
    mov rax, [rip + matches + VEC_ptr]
    mov r12, [rax + rbx*8]
    cmp dword ptr [r12 + AS_kind], 4
    jne 5f
    cmp dword ptr [r12 + AS_loaded], 2
    jne 5f
    mov dword ptr [r12 + AS_loaded], 1
    mov rdi, [r12 + AS_path]
    mov rsi, [r12 + AS_part + SB_ptr]
    mov rdx, [r12 + AS_part + SB_len]
    call file_write_all
    test rax, rax
    jnz 8f
    lea rdi, [r12 + AS_part]
    call sb_free
    mov rdi, [r12 + AS_path]
    call file_stamp
    mov [r12 + AS_stamp], rax
    mov rax, [r12 + AS_off]
    mov [r12 + AS_title_off], rax
    mov qword ptr [r12 + AS_replaced], 1 # streamed parts replace previous contents, including same-size edits
5:  inc rbx
    jmp 4b
81: call opencode_state_forget      # the query failed
8:  mov dword ptr [rip + opencode_status], 2
9:  EPILOGUE

# opencode_batch(open only) -> conversations put in opencode_sql's transcript query (AS_loaded 2), in
#   page order, as many as fit OPENCODE_BATCH; a first one larger than that goes alone.
opencode_batch:
    PROLOGUE
    mov [rsp], edi
    lea rdi, [rip + opencode_sql]
    call sb_clear
    lea rsi, [rip + .Loc_parts]
    cmp dword ptr [rip + agent_opencode_v2], 0
    je 4f
    lea rsi, [rip + .Loc_parts2]
4:  lea rdi, [rip + opencode_sql]
    call sb_push_cstr
    xor ebx, ebx
    xor r14d, r14d              # characters
    xor r15d, r15d              # conversations
1:  cmp rbx, [rip + matches + VEC_len]
    jae 3f
    mov rax, [rip + matches + VEC_ptr]
    mov r12, [rax + rbx*8]
    cmp dword ptr [r12 + AS_kind], 4
    jne 2f
    mov rax, [r12 + AS_off]
    cmp rax, [r12 + AS_title_off]
    je 2f
    cmp qword ptr [r12 + AS_index_title], 0
    je 2f
    cmp dword ptr [rsp], 0
    jne 11f
    cmp rbx, [rip + page_limit]
    jb 12f
11: mov rsi, [rip + opencode_open]
    test rsi, rsi
    jz 2f
    mov rdi, [r12 + AS_path]
    call strcmp_eq
    test eax, eax
    jz 2f
12: mov rax, [r12 + AS_bytes]
    cmp rax, OPENCODE_LARGEST
    jbe 13f
    mov rdi, r12
    call opencode_title_only
    jmp 2f
13: test r15d, r15d
    jz 14f
    cmp dword ptr [rip + opencode_single], 0
    jne 3f
    lea rcx, [r14 + rax]
    cmp rcx, OPENCODE_BATCH
    ja 3f
    cmp r15d, 200
    jae 3f
    lea rdi, [rip + opencode_sql]
    mov esi, ','
    call sb_push_byte
14: add r14, [r12 + AS_bytes]
    lea rdi, [rip + opencode_sql]
    mov rsi, [r12 + AS_index_title]
    call agent_opencode_quote
    mov dword ptr [r12 + AS_loaded], 2
    inc r15d
2:  inc rbx
    jmp 1b
3:  test r15d, r15d
    jz 9f
    lea rsi, [rip + .Loc_parts_end]
    cmp dword ptr [rip + agent_opencode_v2], 0
    je 31f
    lea rsi, [rip + .Loc_parts2_end]
31: lea rdi, [rip + opencode_sql]
    call sb_push_cstr
9:  mov eax, r15d
    EPILOGUE

# opencode_metadata_sql() -> the start of the metadata query for the CLI's version
opencode_metadata_sql:
    lea rax, [rip + .Loc_metadata]
    cmp dword ptr [rip + agent_opencode_v2], 0
    je 1f
    lea rax, [rip + .Loc_metadata2]
1:  ret

# opencode_title_only(AS*): a conversation too large to copy keeps the title alone, also in place of an
#   older transcript, and is not tried again until it changes. A failed save is the provider's failure.
opencode_title_only:
    PROLOGUE
    mov rbx, rdi
    mov dword ptr [rbx + AS_loaded], 1
    mov rdi, [rbx + AS_path]
    mov rsi, [rbx + AS_part + SB_ptr]
    mov rdx, [rbx + AS_part + SB_len]
    call file_write_all
    test rax, rax
    jz 1f
    mov dword ptr [rip + opencode_status], 2
    jmp 9f
1:
    mov rdi, [rbx + AS_path]
    call file_stamp
    mov [rbx + AS_stamp], rax
    mov rax, [rbx + AS_off]
    mov [rbx + AS_title_off], rax
    mov qword ptr [rbx + AS_replaced], 1
9:  EPILOGUE

# opencode_overflow(): the batch in AS_loaded 2 passed the output limit. Several are tried again one by
#   one; one alone is too large to copy.
opencode_overflow:
    PROLOGUE
    xor ebx, ebx
    xor r13d, r13d              # conversations in the batch
    xor r14d, r14d              # the last of them
1:  cmp rbx, [rip + matches + VEC_len]
    jae 3f
    mov rax, [rip + matches + VEC_ptr]
    mov r12, [rax + rbx*8]
    cmp dword ptr [r12 + AS_kind], 4
    jne 2f
    cmp dword ptr [r12 + AS_loaded], 2
    jne 2f
    mov dword ptr [r12 + AS_loaded], 1
    mov r14, r12
    inc r13d
2:  inc rbx
    jmp 1b
3:  cmp r13d, 1
    jne 4f
    mov rdi, r14
    call opencode_title_only
    EPILOGUE
4:  mov dword ptr [rip + opencode_single], 1
    EPILOGUE

# A row that cannot be read is left out, rather than the transcripts with it.
opencode_part_line:
    PROLOGUE 16
    mov [rsp], rdi
    mov [rsp + 8], rsi
    call json_parse
    test rax, rax
    jz 9f
    mov rdi, rax
    lea rsi, [rip + .Loc_sessionId]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 9f
    mov rdi, rax
    call opencode_session_path
    mov rdx, rax
    mov rdi, [rip + table]
    mov esi, 262143
    call agent_table_find
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp dword ptr [rbx + AS_loaded], 2
    jne 9f
    lea rdi, [rbx + AS_part]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
    lea rdi, [rbx + AS_part]
    mov esi, 10
    call sb_push_byte
9:  mov eax, 1
    EPILOGUE

.section .rodata
.Loc_cache: .asciz "/opencode-"
.Loc_jsonl: .asciz ".jsonl"
.Loc_state: .asciz "-opencode"
.Loc_wal: .asciz "-wal"
.Loc_updated: .asciz "updated"
.Loc_sessionId: .asciz "sessionId"
.Loc_revision: .asciz "revision"
# Upstream session/message/part schema, OpenCode 1.19.0. Include part changes in the revision:
# streaming, tool completion, deletion and message reversion need a new snapshot. Its last number
# estimates a copy's bytes: only text and tool parts are copied (what the panel shows; reasoning and
# files, which OpenCode writes with their type first, are not counted), and a part over 70000 bytes
# keeps the start of its text, output and inputs, in characters that stay within that in any script,
# without its metadata. A batch past the output limit is tried again one conversation at a time.
# After /undo OpenCode keeps the undone messages until the next prompt; as its TUI, the copy ends before
# session.revert's message, in OpenCode's message order (time, then ID), and so does the estimate.
# A reply's message names its model (a prompt's, the model chosen for the reply); the row shows the last.
.Loc_metadata: .ascii "SELECT json_object('id',s.id,'cwd',s.directory,'title',s.title,'updated',max(s.time_updated,coalesce((SELECT max(time_updated) FROM part WHERE session_id=s.id),0),coalesce((SELECT max(time_updated) FROM message WHERE session_id=s.id),0)),'created',s.time_created,'revision',CASE WHEN s.revert IS NULL THEN (SELECT coalesce(max(time_updated),0)||':'||count(*)||':'||coalesce(sum(length(data)),0)||':'||coalesce(sum(CASE WHEN substr(data,1,19)='{\"type\":\"reasoning\"' OR substr(data,1,14)='{\"type\":\"file\"' THEN 0 ELSE min(length(CAST(data AS BLOB)),70000) END),0) FROM part WHERE session_id=s.id) ELSE (SELECT coalesce(max(time_updated),0)||':'||count(*)||':'||coalesce(sum(length(data)),0) FROM part WHERE session_id=s.id)||':'||(SELECT coalesce(sum(CASE WHEN substr(p.data,1,19)='{\"type\":\"reasoning\"' OR substr(p.data,1,14)='{\"type\":\"file\"' THEN 0 ELSE min(length(CAST(p.data AS BLOB)),70000) END),0) FROM part p JOIN message m ON m.id=p.message_id LEFT JOIN message c ON c.id=CASE WHEN json_valid(s.revert) THEN json_extract(s.revert,'$.messageID') END WHERE p.session_id=s.id AND (c.id IS NULL OR m.time_created<c.time_created OR (m.time_created=c.time_created AND m.id<c.id))) END,'messages',(SELECT coalesce(max(time_updated),0)||':'||count(*)||':'||coalesce(sum(length(data)),0) FROM message WHERE session_id=s.id),'revert',s.revert,'model',(SELECT coalesce(json_extract(data,'$.modelID'),json_extract(data,'$.model.modelID')) FROM message WHERE session_id=s.id AND CASE WHEN json_valid(data) THEN coalesce(json_extract(data,'$.modelID'),json_extract(data,'$.model.modelID')) END IS NOT NULL ORDER BY time_created DESC,id DESC LIMIT 1)) AS line FROM session s WHERE s.parent_id IS NULL AND s.time_archived IS NULL AND "
.ifdef WINDOWS
    .ascii "replace(s.directory,char(92),'/') COLLATE NOCASE"
.else
    .ascii "s.directory"
.endif
    .asciz " IN ("
.Loc_parts: .asciz "WITH selected AS (SELECT s.id,c.time_created AS ct,c.id AS cid FROM session s LEFT JOIN message c ON c.id=CASE WHEN json_valid(s.revert) THEN json_extract(s.revert,'$.messageID') END WHERE s.id IN ("
.Loc_parts_end: .asciz ")) SELECT line FROM (SELECT json_object('sessionId',p.session_id,'role',CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.role') END,'model',CASE WHEN json_valid(m.data) THEN coalesce(json_extract(m.data,'$.modelID'),json_extract(m.data,'$.model.modelID')) END,'part',CASE WHEN length(CAST(p.data AS BLOB))<=70000 THEN json(p.data) ELSE json_remove(json_replace(p.data,'$.text',substr(json_extract(p.data,'$.text'),1,16384),'$.state.output',substr(json_extract(p.data,'$.state.output'),1,8192),'$.state.error',substr(json_extract(p.data,'$.state.error'),1,8192),'$.state.input.command',substr(json_extract(p.data,'$.state.input.command'),1,1024),'$.state.input.content',substr(json_extract(p.data,'$.state.input.content'),1,1024),'$.state.input.oldString',substr(json_extract(p.data,'$.state.input.oldString'),1,1024),'$.state.input.newString',substr(json_extract(p.data,'$.state.input.newString'),1,1024),'$.state.input.prompt',substr(json_extract(p.data,'$.state.input.prompt'),1,1024)),'$.state.metadata','$.state.attachments') END) AS line,p.session_id AS sid,m.time_created AS mc,m.id AS mid,p.id AS pid FROM part p JOIN message m ON m.id=p.message_id JOIN selected sel ON sel.id=p.session_id WHERE (sel.cid IS NULL OR m.time_created<sel.ct OR (m.time_created=sel.ct AND m.id<sel.cid)) AND CASE WHEN json_valid(p.data) THEN json_extract(p.data,'$.type') IN ('text','tool') END UNION ALL SELECT json_object('sessionId',m.session_id,'role','assistant','part',json_object('type','error','text',coalesce(json_extract(m.data,'$.error.data.message'),json_extract(m.data,'$.error.message'),'OpenCode request failed'))) AS line,m.session_id AS sid,m.time_created AS mc,m.id AS mid,'' AS pid FROM message m JOIN selected sel ON sel.id=m.session_id WHERE (sel.cid IS NULL OR m.time_created<sel.ct OR (m.time_created=sel.ct AND m.id<sel.cid)) AND CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.error') END IS NOT NULL) ORDER BY sid,mc,mid,pid"
# OpenCode 2 keeps sessions in session_v2 and their messages, in order (seq), in session_message: a prompt's
# text, a reply's model and content (text, reasoning, tool calls with their output as content), a command
# the user ran (shell: command, status, output.output), and rows of bookkeeping (system, synthetic, skill,
# compaction, idle, agent-, model- and location-switched). The copy has the shape of OpenCode 1's, which
# kept a user's command as a reply's tool call: prompts, reply text and tools, commands, a reply's error,
# with the same limits; the estimate counts what is copied. After /undo, as in OpenCode 2's TUI, the copy ends before session.revert's message. The row's
# model is the last reply's, or a switch since, else the session's (a prompt waiting for its reply). Until
# OpenCode 2 names a session (OpenCode 1 gave a new one a title at once) its first prompt stands in, its
# start alone (the panel shows a title's first line, at most 120 bytes).
.Loc_metadata2: .ascii "SELECT json_object('id',s.id,'cwd',s.directory,'title',substr(coalesce(nullif(s.title,''),(SELECT json_extract(data,'$.text') FROM session_message WHERE session_id=s.id AND type='user' AND json_valid(data) ORDER BY seq LIMIT 1),''),1,512),'updated',max(s.time_updated,coalesce((SELECT max(time_updated) FROM session_message WHERE session_id=s.id),0)),'created',s.time_created,'revision',(SELECT coalesce(max(time_updated),0)||':'||count(*)||':'||coalesce(sum(length(CAST(data AS BLOB))),0) FROM session_message WHERE session_id=s.id)||':'||(SELECT coalesce(sum(CASE WHEN m.type IN ('user','shell') THEN min(length(CAST(m.data AS BLOB)),70000) ELSE (SELECT coalesce(sum(min(length(CAST(c.value AS BLOB)),70000)),0) FROM json_each(m.data,'$.content') c WHERE CASE WHEN c.type='object' THEN json_extract(c.value,'$.type') END IN ('text','tool')) END),0) FROM session_message m WHERE m.session_id=s.id AND m.type IN ('user','assistant','shell') AND json_valid(m.data) AND m.seq<coalesce((SELECT r.seq FROM session_message r WHERE r.session_id=s.id AND r.id=CASE WHEN json_valid(s.revert) THEN json_extract(s.revert,'$.messageID') END),9223372036854775807)),'revert',s.revert,'model',coalesce((SELECT json_extract(data,'$.model.id') FROM session_message WHERE session_id=s.id AND type IN ('assistant','model-switched') AND CASE WHEN json_valid(data) THEN json_extract(data,'$.model.id') END IS NOT NULL ORDER BY seq DESC LIMIT 1),CASE WHEN json_valid(s.model) THEN json_extract(s.model,'$.id') END)) AS line FROM session_v2 s WHERE s.parent_id IS NULL AND s.time_archived IS NULL AND "
.ifdef WINDOWS
    .ascii "replace(s.directory,char(92),'/') COLLATE NOCASE"
.else
    .ascii "s.directory"
.endif
    .asciz " IN ("
.Loc_parts2: .asciz "WITH selected AS (SELECT s.id,coalesce((SELECT r.seq FROM session_message r WHERE r.session_id=s.id AND r.id=CASE WHEN json_valid(s.revert) THEN json_extract(s.revert,'$.messageID') END),9223372036854775807) AS cut FROM session_v2 s WHERE s.id IN ("
.Loc_parts2_end: .asciz ")),shown AS (SELECT m.session_id,m.seq,m.type,m.data FROM session_message m JOIN selected sel ON sel.id=m.session_id WHERE m.seq<sel.cut AND m.type IN ('user','assistant','shell') AND json_valid(m.data)) SELECT line FROM (SELECT json_object('sessionId',session_id,'role','user','part',json_object('type','text','text',substr(json_extract(data,'$.text'),1,CASE WHEN length(CAST(data AS BLOB))<=70000 THEN 2147483647 ELSE 16384 END))) AS line,session_id AS sid,seq AS sq,-1 AS ix FROM shown WHERE type='user' UNION ALL SELECT json_object('sessionId',m.session_id,'role','assistant','model',json_extract(m.data,'$.model.id'),'part',CASE json_extract(c.value,'$.type') WHEN 'text' THEN json_object('type','text','text',substr(json_extract(c.value,'$.text'),1,CASE WHEN length(CAST(c.value AS BLOB))<=70000 THEN 2147483647 ELSE 16384 END)) ELSE json_object('type','tool','tool',json_extract(c.value,'$.name'),'state',CASE WHEN json_extract(c.value,'$.state.status')='error' THEN json_object('status','error','input',CASE WHEN length(CAST(c.value AS BLOB))<=70000 OR json_type(c.value,'$.state.input') IS NOT 'object' THEN json_extract(c.value,'$.state.input') ELSE json_replace(json_extract(c.value,'$.state.input'),'$.command',substr(json_extract(c.value,'$.state.input.command'),1,1024),'$.content',substr(json_extract(c.value,'$.state.input.content'),1,1024),'$.oldString',substr(json_extract(c.value,'$.state.input.oldString'),1,1024),'$.newString',substr(json_extract(c.value,'$.state.input.newString'),1,1024),'$.prompt',substr(json_extract(c.value,'$.state.input.prompt'),1,1024)) END,'error',substr(coalesce(json_extract(c.value,'$.state.error.message'),CASE WHEN json_type(c.value,'$.state.error')='text' THEN json_extract(c.value,'$.state.error') END,''),1,CASE WHEN length(CAST(c.value AS BLOB))<=70000 THEN 2147483647 ELSE 8192 END)) ELSE json_object('status',json_extract(c.value,'$.state.status'),'input',CASE WHEN length(CAST(c.value AS BLOB))<=70000 OR json_type(c.value,'$.state.input') IS NOT 'object' THEN json_extract(c.value,'$.state.input') ELSE json_replace(json_extract(c.value,'$.state.input'),'$.command',substr(json_extract(c.value,'$.state.input.command'),1,1024),'$.content',substr(json_extract(c.value,'$.state.input.content'),1,1024),'$.oldString',substr(json_extract(c.value,'$.state.input.oldString'),1,1024),'$.newString',substr(json_extract(c.value,'$.state.input.newString'),1,1024),'$.prompt',substr(json_extract(c.value,'$.state.input.prompt'),1,1024)) END,'output',substr((SELECT group_concat(json_extract(x.value,'$.text'),char(10)) FROM json_each(c.value,'$.state.content') x WHERE CASE WHEN x.type='object' THEN json_extract(x.value,'$.type') END='text'),1,CASE WHEN length(CAST(c.value AS BLOB))<=70000 THEN 2147483647 ELSE 8192 END)) END) END) AS line,m.session_id AS sid,m.seq AS sq,c.key AS ix FROM shown m,json_each(m.data,'$.content') c WHERE m.type='assistant' AND CASE WHEN c.type='object' THEN json_extract(c.value,'$.type') END IN ('text','tool') UNION ALL SELECT json_object('sessionId',session_id,'role','assistant','part',json_object('type','tool','tool','shell','state',json_object('status',json_extract(data,'$.status'),'input',json_object('command',substr(json_extract(data,'$.command'),1,CASE WHEN length(CAST(data AS BLOB))<=70000 THEN 2147483647 ELSE 1024 END)),'output',substr(json_extract(data,'$.output.output'),1,CASE WHEN length(CAST(data AS BLOB))<=70000 THEN 2147483647 ELSE 8192 END)))) AS line,session_id AS sid,seq AS sq,0 AS ix FROM shown WHERE type='shell' UNION ALL SELECT json_object('sessionId',session_id,'role','assistant','part',json_object('type','error','text',coalesce(json_extract(data,'$.error.data.message'),json_extract(data,'$.error.message'),'OpenCode request failed'))) AS line,session_id AS sid,seq AS sq,1000000000 AS ix FROM shown WHERE type='assistant' AND json_extract(data,'$.error') IS NOT NULL) ORDER BY sid,sq,ix"
