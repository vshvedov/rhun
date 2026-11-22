# agents panel: Claude Code, Codex, Grok Build and OpenCode sessions, live
.include "rhun.inc"

STRUCT
F AM_role, 4
F AM_h, 4
F AM_w, 4
F AM_pad, 4
F AM_text, 8
F AM_len, 8
F AM_name, 8
ENDSTRUCT AM_SIZE

.equ R_USER, 1
.equ R_ASSIST, 2
.equ R_TOOL, 3
.equ R_RESULT, 4
.equ R_ERROR, 5                 # extension sessions (agentext.s): an error and a notice, drawn as results
.equ R_INFO, 6

.equ ID_AG_ROW, 0x400000          # + session: a range of its own, as the list has no end
.equ ID_AG_BACK, 0x5f00
.equ ID_AG_REFRESH, 0x5f01
.equ ID_AG_SCROLL, 0x5f02
.equ ID_AG_TSCROLL, 0x5f03
.equ ID_AG_FOLLOW, 0x5f04
.equ ID_AG_MORE, 0x5f05

.equ ROUTINE_GAP, 2000          # ms from one routine discovery run to the next
.equ INDEX_TIMEOUT, 60000       # ms a discovery run may take before it is stopped

.bss
.p2align 3
sessions: .zero VEC_SIZE        # AS*
pool: .zero VEC_SIZE            # owned sessions, including previously opened pages
list_scroll: .long 0
th_scroll: .long 0
th_content: .long 0
last_poll: .quad 0
label_due: .quad 0              # unix second when a label shown changes ("now" turns "1m ago", a live dot goes out)
last_scan: .quad 0
tmp: .zero SB_SIZE
line: .zero SB_SIZE
buf: .zero 96
.p2align 3
page_limit: .quad 0
page_count: .quad 0
total_count: .quad 0
incoming_total: .quad 0
incoming: .zero VEC_SIZE
reapers: .zero VEC_SIZE
index_out: .zero SB_SIZE
index_exe: .zero 4096
index_number: .zero 32
index_pid: .long 0
index_pending: .long 0
index_final: .long 0
index_error: .long 0
opencode_status: .long 0
index_loud: .long 0            # the next run was asked for (agents_scan): shown as loading
index_shown: .long 0           # the running worker shows as loading; routine runs are silent
last_visible: .long 0
.p2align 3
ext_listed: .quad 0             # rows of extensions' sessions in the page (agents_ext_rows)
keep_empty: .long 0             # add_msg keeps an empty message (an extension's indices count it)
.p2align 3
ext_pinned: .zero VEC_SIZE      # agents_ext_rows: the rows after the page while extension rows go in
index_debounce: .quad 0
index_started: .quad 0
index_runs: .quad 0             # workers started (print-agents-runs)
sources_hash: .quad 0
model_noted: .long 0            # row_model found a model since cleared (agent_session_tail_title)
.p2align 3
prefix_buf: .zero 65536         # model_before: the beginning of a line that begins near a window's end
.data
index_fd: .long -1
common_wd: .long -1             # the watch of the common .git folder (agents_watch_repo)
registry_wd: .long -1           # and of its worktrees folder
.bss


.text

# Config reloads can change sources while a worker is still running.
FN agents_apply_settings
    PROLOGUE
    mov rdi, [rip + cfg_agent_sources]
    call strlen
    mov rsi, rax
    mov rdi, [rip + cfg_agent_sources]
    call hash_line
    cmp rax, [rip + sources_hash]
    je 1f
    call agents_set_project
1:  EPILOGUE

# ---------- asynchronous index and paging ----------
FN agents_set_project
    PROLOGUE
    call agents_shutdown
    mov rdi, [rip + cfg_agent_sources]
    call strlen
    mov rsi, rax
    mov rdi, [rip + cfg_agent_sources]
    call hash_line
    mov [rip + sources_hash], rax
    mov eax, [rip + g_show_agents]
    mov [rip + last_visible], eax
    lea rdi, [rip + pool]
    call agent_records_free
    mov qword ptr [rip + sessions + VEC_len], 0
    mov qword ptr [rip + view], -1
    mov qword ptr [rip + page_count], 0
    mov qword ptr [rip + total_count], 0
    mov qword ptr [rip + page_limit], 50
    mov dword ptr [rip + list_scroll], 0
    mov dword ptr [rip + index_error], 0
    mov dword ptr [rip + opencode_status], 0
    mov qword ptr [rip + last_scan], 0
    mov qword ptr [rip + index_debounce], 0
    # the previous project's folders no longer run this one's discovery
    call watch_forget_agents
    mov dword ptr [rip + common_wd], -1
    mov dword ptr [rip + registry_wd], -1
    call agents_watch_repo
    # AI: the sessions extensions list, as this project shows them
    mov qword ptr [rip + ext_listed], 0
    call agentext_rematch
    call agents_ext_rows
    call agents_scan
    call index_dirty
    EPILOGUE

# Queue killed children for nonblocking reaping, never wait on the UI thread.
FN agents_shutdown
    PROLOGUE
    cmp dword ptr [rip + index_fd], 0
    jl 1f
    mov edi, [rip + index_fd]
    call watch_remove
    mov edi, [rip + index_fd]
    SYS SYS_close
    mov dword ptr [rip + index_fd], -1
1:  cmp dword ptr [rip + index_pid], 0
    jle 2f
    mov edi, [rip + index_pid]
.ifndef WINDOWS
    neg edi                    # the worker's process group includes its database CLI children
    mov esi, 9
    call proc_kill             # (on the host in a remote window)
    mov edi, [rip + index_pid] # and the worker, also before its first instruction makes that group
.endif
    mov esi, 9
    call proc_kill
    lea rdi, [rip + reapers]
    mov esi, 8
    call vec_push
    mov ecx, [rip + index_pid]
    mov [rax], rcx
2:  mov dword ptr [rip + index_pid], 0
    mov dword ptr [rip + index_pending], 0
    mov dword ptr [rip + index_loud], 0
    mov dword ptr [rip + index_shown], 0
    mov dword ptr [rip + index_final], 0
    lea rdi, [rip + incoming]
    call agent_records_free
    lea rdi, [rip + index_out]
    call sb_clear
    call index_reap
    EPILOGUE

index_reap:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + reapers + VEC_len]
    jae 9f
    mov rax, [rip + reapers + VEC_ptr]
    mov edi, [rax + rbx*8]
    mov esi, 1
    call proc_wait
    cmp eax, -1
    je 2f
    dec qword ptr [rip + reapers + VEC_len]
    mov rcx, [rip + reapers + VEC_len]
    mov rax, [rip + reapers + VEC_ptr]
    mov rdx, [rax + rcx*8]
    mov [rax + rbx*8], rdx
    jmp 1b
2:  inc rbx
    jmp 1b
9:  EPILOGUE

FN agents_busy
    mov eax, [rip + index_pid]
    or eax, [rip + index_pending]
    ret

# agents_scan(): a run asked for (the refresh button, Load more, a retry, a new project), shown as
# loading until its page. Routine runs set index_pending alone and show nothing.
FN agents_scan
    mov dword ptr [rip + index_pending], 1
    mov dword ptr [rip + index_loud], 1
    cmp qword ptr [rip + g_project], 0
    je 1f
    cmp dword ptr [rip + g_show_agents], 0
    je 2f
    cmp dword ptr [rip + index_pid], 0
    jne 2f
    # at startup the worker waits for the first frame: the tick right after it starts the run asked
    # for (agents_timeout gives it no wait), rather than a fork before the window shows
    cmp dword ptr [rip + g_started], 0
    je 2f
    jmp index_start
1:  mov dword ptr [rip + index_pending], 0
    mov dword ptr [rip + index_loud], 0
2:  ret

# index_loading() -> 1 while the panel shows loading: a run asked for is pending or going
index_loading:
    mov eax, [rip + index_shown]
    or eax, [rip + index_loud]
    ret

# agents_more(): 50 more rows; while a routine run is going, the larger page follows it
FN agents_more
    mov rax, [rip + page_count]
    cmp rax, [rip + total_count]
    jae 1f
    add qword ptr [rip + page_limit], 50
    jmp agents_scan
1:  ret

index_start:
    PROLOGUE 64
    mov dword ptr [rip + index_pending], 0
    mov dword ptr [rip + index_final], 0
    mov eax, [rip + index_loud]
    mov [rip + index_shown], eax
    mov dword ptr [rip + index_loud], 0
    call time_ms
    mov [rip + last_scan], rax
    mov [rip + index_started], rax
    lea rdi, [rip + index_exe]
    mov esi, 4096
    call proc_self_path
    test rax, rax
    jle .Lindex_start_fail
    lea rdi, [rip + index_number]
    mov rsi, [rip + page_limit]
    call fmt_u64
    lea rcx, [rip + index_number]
    mov byte ptr [rcx + rax], 0
    lea rax, [rip + index_exe]
    cmp dword ptr [rip + g_remote], 0     # remote hosts: the host's sessions, by the agent's binary
    je 2f
    lea rax, [rip + .Lat_self]
2:  mov [rsp], rax
    lea rax, [rip + .Lindex_arg]
    mov [rsp + 8], rax
    mov rax, [rip + g_project]
    mov [rsp + 16], rax
    lea rax, [rip + index_number]
    mov [rsp + 24], rax
    mov rax, [rip + cfg_agent_sources]
    mov [rsp + 32], rax
    lea rax, [rip + .Lempty]
    mov rcx, [rip + view]
    test rcx, rcx
    js 1f
    mov rdx, [rip + sessions + VEC_ptr]
    mov rdx, [rdx + rcx*8]
    cmp dword ptr [rdx + AS_kind], 4
    jne 1f
    mov rax, [rdx + AS_path]
1:  mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0
    call claude_index_envp      # Claude Code: an env.CLAUDE_CONFIG_DIR set reaches discovery (claudecfg.s)
    mov rsi, rax
    mov rdi, rsp
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, 2
    call vfs_run_piped_input
    test rax, rax
    jle .Lindex_start_fail
    mov [rip + index_pid], eax
    mov [rip + index_fd], edx
    inc qword ptr [rip + index_runs]
    lea rdi, [rip + index_out]
    call sb_clear
    mov edi, [rip + index_fd]
    mov esi, POLLIN
    lea rdx, [rip + index_read]
    xor ecx, ecx
    call watch_add
    # a routine run changes nothing on screen until its page
    cmp dword ptr [rip + index_shown], 0
    je 9f
    call index_dirty
9:  EPILOGUE
.Lindex_start_fail:
    mov dword ptr [rip + index_shown], 0
    mov dword ptr [rip + index_error], 1
    call index_dirty
    EPILOGUE

# A callback drains at most 256 KiB, so large pages yield to input/painting.
index_read:
    PROLOGUE
    mov r12d, 64
1:  lea rdi, [rip + index_out]
    mov esi, 4096
    call sb_reserve
    mov rsi, rax
    mov edi, [rip + index_fd]
    mov edx, 4096
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 3f
    add [rip + index_out + SB_len], rax
    cmp qword ptr [rip + index_out + SB_len], (1 << 26) + 4096
    ja .Lindex_read_fail
    call index_packets
    test eax, eax
    jz .Lindex_read_fail
    dec r12d
    jnz 1b
    jmp 9f
3:  test rax, rax
    js .Lindex_read_fail
    mov edi, [rip + index_fd]
    call watch_remove
    mov edi, [rip + index_fd]
    SYS SYS_close
    mov dword ptr [rip + index_fd], -1
    call index_finish
9:  EPILOGUE
.Lindex_read_fail:
    call agents_shutdown
    mov dword ptr [rip + index_error], 1
    call index_dirty
    EPILOGUE

index_packets:
    PROLOGUE
1:  mov r12, [rip + index_out + SB_ptr]
    cmp qword ptr [rip + index_out + SB_len], 32
    jb 8f
    mov r13, [r12 + 24]
    cmp r13, (1 << 26) - 32
    ja 9f
    add r13, 32
    cmp r13, [rip + index_out + SB_len]
    ja 8f
    mov rax, 0x31434f504f484152
    cmp [r12], rax
    jne 11f
    cmp r13, 32
    jne 9f
    cmp qword ptr [r12 + 16], 0
    jne 9f
    mov rax, [r12 + 8]
    cmp rax, 2
    ja 9f
    mov [rip + opencode_status], eax
    call index_dirty
    jmp 4f
11: mov rax, 0x3345474150484152
    xor ebx, ebx
    cmp [r12], rax
    je 2f
    mov rax, 0x3356455250484152
    cmp [r12], rax
    jne 9f
    mov ebx, 1
2:  cmp dword ptr [rip + index_final], 0
    jne 9f
    mov rax, [r12 + 8]
    cmp rax, [rip + page_limit]
    ja 9f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + incoming]
    call agent_records_decode
    test eax, eax
    jz 9f
    mov rax, [r12 + 16]
    mov [rip + incoming_total], rax
    test ebx, ebx
    jz 3f
    cmp qword ptr [rip + page_count], 0
    jne 21f
    call apply_page
21: lea rdi, [rip + incoming]
    call agent_records_free
    jmp 4f
3:  mov dword ptr [rip + index_final], 1
4:  sub [rip + index_out + SB_len], r13
    mov rdi, [rip + index_out + SB_ptr]
    lea rsi, [rdi + r13]
    mov rdx, [rip + index_out + SB_len]
    call memmove
    jmp 1b
8:  mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

index_finish:
    PROLOGUE
    cmp dword ptr [rip + index_pid], 0
    jle 9f
    cmp dword ptr [rip + index_fd], 0
    jge 9f
    mov edi, [rip + index_pid]
    mov esi, 1
    call proc_wait
    cmp eax, -1
    je 9f
    mov ebx, eax
.ifndef WINDOWS
    # The worker's process group outlives it only with what a database CLI stopped on its timeout
    # left running; the group's ID is not given to a new process while it has members.
    test eax, eax
    js 1f                       # not reaped here: the ID may be another process's by now
    mov edi, [rip + index_pid]
    neg edi
    mov esi, 9
    SYS SYS_kill
1:
.endif
    mov dword ptr [rip + index_pid], 0
    mov dword ptr [rip + index_shown], 0
    call time_ms
    mov [rip + last_scan], rax
    test ebx, ebx
    jnz 2f
    cmp dword ptr [rip + index_final], 0
    je 2f
    cmp qword ptr [rip + index_out + SB_len], 0
    jne 2f
    call apply_page
    mov dword ptr [rip + index_error], 0
    jmp 3f
2:  mov dword ptr [rip + index_error], 1
3:  lea rdi, [rip + incoming]
    call agent_records_free
    mov dword ptr [rip + index_final], 0
    call index_dirty
9:  EPILOGUE

# Merge a validated page. Old AS objects retain parsed messages and consumed stamps.
apply_page:
    PROLOGUE 32
    xor ebx, ebx
    mov rax, [rip + view]
    test rax, rax
    js 1f
    mov rcx, [rip + sessions + VEC_ptr]
    mov rbx, [rcx + rax*8]
1:  mov [rsp], rbx             # open AS, if any
    mov qword ptr [rip + view], -1
    mov qword ptr [rip + sessions + VEC_len], 0
    mov rax, [rip + incoming + VEC_len]
    mov [rip + page_count], rax
    mov rdx, [rip + incoming_total]
    mov [rip + total_count], rdx
    add rax, [rip + pool + VEC_len]
    mov ebx, 16
2:  lea rcx, [rax*2]
    cmp rbx, rcx
    ja 3f
    shl rbx, 1
    jmp 2b
3:  lea rdi, [rbx*8]
    call mem_alloc
    mov [rsp + 8], rax
    dec rbx
    mov [rsp + 16], rbx
    xor ebx, ebx
4:  cmp rbx, [rip + pool + VEC_len]
    jae 5f
    mov rax, [rip + pool + VEC_ptr]
    mov rdx, [rax + rbx*8]
    mov qword ptr [rdx + AS_seen], 0
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call agent_table_put
    inc rbx
    jmp 4b
5:  xor ebx, ebx
.Lapply_next:
    cmp rbx, [rip + incoming + VEC_len]
    jae .Lapply_done
    mov rax, [rip + incoming + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    mov rdx, [r12 + AS_path]
    call agent_table_find
    mov r13, rax
    test rax, rax
    jnz 6f
    mov r13, r12
    mov rdi, [r13 + AS_title]
    test rdi, rdi
    jz 51f
    call strlen
    mov rsi, rax
    mov rdi, [r13 + AS_title]
    call mem_dup
    mov [r13 + AS_index_title], rax
51: lea rdi, [rip + pool]
    mov esi, 8
    call vec_push
    mov [rax], r13
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    mov rdx, r13
    call agent_table_put
    jmp 8f
6:  cmp dword ptr [r13 + AS_kind], 4
    je 60f                    # OpenCode rows come from the worker alone, also a deletion's lower time
    mov rax, [r12 + AS_recency]
    cmp rax, [r13 + AS_recency]
    jb 69f                    # reject titles as well as timestamps from an older write
    cmp dword ptr [r13 + AS_loaded], 0
    je 60f
    mov rcx, [r13 + AS_changed]
    cmp rcx, [rip + index_started]
    jb 60f
    mov rcx, [r12 + AS_stamp]
    cmp rcx, [r13 + AS_stamp]
    jne 69f                   # same mtime can still contain newer consumed bytes
60:
    cmp qword ptr [r12 + AS_replaced], 0
    je 601f
    mov rdi, r13
    call session_clear_msgs
    mov qword ptr [r13 + AS_off], 0
    mov qword ptr [r13 + AS_part + SB_len], 0
    xor eax, eax
    cmp r13, [rsp]
    sete al
    mov [r13 + AS_loaded], eax # the open conversation is re-read below
    mov dword ptr [r13 + AS_titled], 0
    mov rdi, [r13 + AS_title]
    call mem_free
    mov qword ptr [r13 + AS_title], 0
601: mov rax, [r12 + AS_recency]
    mov [r13 + AS_recency], rax
    mov rax, [r12 + AS_mtime]
    mov [r13 + AS_mtime], rax
61: mov rdi, [r13 + AS_worktree]
    call mem_free
    mov rax, [r12 + AS_worktree]
    mov [r13 + AS_worktree], rax
    mov qword ptr [r12 + AS_worktree], 0
    mov rdi, [r13 + AS_model]
    call mem_free
    mov rax, [r12 + AS_model]
    mov [r13 + AS_model], rax
    mov qword ptr [r12 + AS_model], 0
    cmp dword ptr [r13 + AS_loaded], 0
    jne 62f
    mov rax, [r12 + AS_stamp]
    mov [r13 + AS_stamp], rax
62: mov dword ptr [rsp + 24], 1
    mov rdi, [r12 + AS_title]
    mov rsi, [r13 + AS_index_title]
    cmp rdi, rsi
    je 64f
    test rdi, rdi
    jz 65f
    test rsi, rsi
    jz 65f
    call strcmp_eq
    test eax, eax
    jz 65f
64: mov rax, [r12 + AS_title_rev]
    cmp rax, [r13 + AS_title_rev]
    setne al
    movzx eax, al
    mov [rsp + 24], eax
65: mov rax, [r12 + AS_title_rev]
    mov [r13 + AS_title_rev], rax
    mov rdi, [r13 + AS_index_title]
    call mem_free
    xor eax, eax
    mov rdi, [r12 + AS_title]
    test rdi, rdi
    jz 66f
    call strlen
    mov rsi, rax
    mov rdi, [r12 + AS_title]
    call mem_dup
66: mov [r13 + AS_index_title], rax
    cmp qword ptr [r12 + AS_replaced], 0
    jne 68f
    cmp dword ptr [rsp + 24], 0
    je 7f
    cmp qword ptr [r12 + AS_title], 0
    jne 67f
    cmp dword ptr [r13 + AS_loaded], 0
    jne 7f
67: cmp dword ptr [r13 + AS_loaded], 0
    je 68f
    cmp dword ptr [r13 + AS_titled], 0
    je 68f
    cmp dword ptr [r12 + AS_titled], 0
    je 7f                     # a tail user message cannot replace a known custom title
68: mov rdi, [r13 + AS_title]
    call mem_free
    mov rax, [r12 + AS_title]
    mov [r13 + AS_title], rax
    mov qword ptr [r12 + AS_title], 0
    mov eax, [r12 + AS_titled]
    mov [r13 + AS_titled], eax
7:  mov rdi, r12
    call agent_session_free
    jmp 8f
69: jmp 7b                    # new file observations already queue a refresh
8:  mov qword ptr [r13 + AS_seen], 1
    lea rdi, [rip + sessions]
    mov esi, 8
    call vec_push
    mov [rax], r13
    cmp r13, [rsp]
    jne 9f
    mov [rip + view], rbx
9:  inc rbx
    jmp .Lapply_next
.Lapply_done:
    mov qword ptr [rip + incoming + VEC_len], 0 # all ownership transferred
    mov r12, [rsp]
    test r12, r12
    jz 11f
    cmp qword ptr [rip + view], 0
    jge 10f
    mov rax, [rip + sessions + VEC_len]
    mov [rip + view], rax
    lea rdi, [rip + sessions]
    mov esi, 8
    call vec_push
    mov [rax], r12             # pin outside the page, hidden from the list
10: mov qword ptr [r12 + AS_seen], 1
    cmp dword ptr [rip + g_show_agents], 0
    je 11f
    mov rdi, r12
    call observe_session
    mov rdi, r12
    call session_update        # never suppress open transcript growth with an index stamp
11: mov rdi, [rsp + 8]
    call mem_free
    call pin_live              # sessions rhun drives stay listed when the page lacks them
    # Retain transcripts, release metadata for unopened rows no longer in the page.
    xor ebx, ebx
    xor r12d, r12d
12: cmp rbx, [rip + pool + VEC_len]
    jae 15f
    mov rax, [rip + pool + VEC_ptr]
    mov r13, [rax + rbx*8]
    cmp qword ptr [r13 + AS_seen], 0
    jne 13f
    cmp dword ptr [r13 + AS_loaded], 0
    jne 13f
    cmp qword ptr [r13 + AS_live], 0
    jne 13f                    # never a session rhun drives
    mov rdi, r13
    call agent_session_free
    jmp 14f
13: mov rax, [rip + pool + VEC_ptr]
    mov [rax + r12*8], r13
    inc r12
14: inc rbx
    jmp 12b
15: mov [rip + pool + VEC_len], r12
    # Watch only directories containing recent rows. Older resumes use the worker's scan.
    xor ebx, ebx
16: cmp rbx, [rip + page_count]
    jae 18f
    cmp ebx, 50
    jae 18f
    mov rax, [rip + sessions + VEC_ptr]
    mov rax, [rax + rbx*8]
    cmp dword ptr [rax + AS_kind], AS_KIND_EXT
    je 17f                      # an extension's session has no folder to watch
    mov r13, [rax + AS_path]
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call path_dirlen
    mov rdi, r13
    mov rsi, rax
    call mem_dup
    mov r13, rax
    mov rdi, rax
    call watch_agents_dir
    mov rdi, r13
    call mem_free
17: inc rbx
    jmp 16b
18: # AI: the extensions' rows go in again
    mov qword ptr [rip + ext_listed], 0
    call agents_ext_rows
    call index_dirty
    EPILOGUE

index_dirty:
    cmp dword ptr [rip + g_show_agents], 0
    je 1f
    mov dword ptr [rip + g_dirty], 1
1:  ret

# ---------- discovery ----------

FN agent_session_free
    PROLOGUE
    mov rbx, rdi
    call agent_closed           # a session rhun drives: its program ends, its record goes (agent_drv.s)
    mov rdi, rbx
    call session_clear_msgs
    lea rdi, [rbx + AS_msgs]
    call vec_free
    lea rdi, [rbx + AS_part]
    call sb_free
    mov rdi, [rbx + AS_path]
    call mem_free
    mov rdi, [rbx + AS_title]
    call mem_free
    mov rdi, [rbx + AS_index_title]
    call mem_free
    mov rdi, [rbx + AS_cwd]
    call mem_free
    mov rdi, [rbx + AS_worktree]
    call mem_free
    mov rdi, [rbx + AS_model]
    call mem_free
    mov rdi, rbx
    call mem_free
    EPILOGUE

session_clear_msgs:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + AS_msgs + VEC_len]
    jae 2f
    imul r13, r12, AM_SIZE
    add r13, [rbx + AS_msgs + VEC_ptr]
    mov rdi, [r13 + AM_text]
    call mem_free
    mov rdi, [r13 + AM_name]
    call mem_free
    inc r12
    jmp 1b
2:  mov qword ptr [rbx + AS_msgs + VEC_len], 0
    mov rdi, [rbx + AS_log_model]
    call mem_free
    mov rdi, [rbx + AS_shown_model]
    call mem_free
    mov qword ptr [rbx + AS_log_model], 0
    mov qword ptr [rbx + AS_shown_model], 0
    EPILOGUE

# agent_read_head(path, max) -> rax buf (NUL-terminated, mem_alloc), rdx len
FN agent_read_head
    xor edx, edx
    jmp agent_read_window

# agent_read_window(path, max, offset): bounded read used by metadata discovery.
FN agent_read_window
    cmp dword ptr [rip + g_remote], 0     # remote hosts: the host's file
    jne 20f
    PROLOGUE
    mov r12, rsi
    mov r15, rdx
    call file_open_read
    test rax, rax
    js 8f
    mov ebx, eax
    test r15, r15
    jz 3f
    mov edi, ebx
    mov rsi, r15
    xor edx, edx
    SYS SYS_lseek
    test rax, rax
    js 6f
3:
    lea rdi, [r12 + 1]
    call mem_alloc
    mov r13, rax
    xor r14d, r14d
2:  mov edi, ebx
    lea rsi, [r13 + r14]
    mov rdx, r12
    sub rdx, r14
    SYS SYS_read
    cmp rax, -EINTR
    je 2b
    test rax, rax
    js 7f
    jz 1f
    add r14, rax
    cmp r14, r12
    jb 2b
1:  mov byte ptr [r13 + r14], 0
    mov edi, ebx
    SYS SYS_close
    mov rax, r13
    mov rdx, r14
    EPILOGUE
7:  mov edi, ebx
    SYS SYS_close
    mov rdi, r13
    call mem_free
    jmp 8f
6:  mov edi, ebx
    SYS SYS_close
8:  xor eax, eax
    xor edx, edx
    EPILOGUE
20: xchg rsi, rdx
    call vfs_read_at
    test rax, rax
    jnz 21f
    xor edx, edx
21: ret

# agent_read_first_line(path, max) -> rax buf (NUL-terminated, mem_alloc), rdx len
# Failure returns rax=0, rdx=-errno for I/O errors or 0 for an oversized line.
# Read through newline or EOF, rejecting lines longer than max and read errors.
FN agent_read_first_line
    PROLOGUE 16
    mov qword ptr [rsp], 0
    lea r12, [rsi + 1]          # one extra byte distinguishes max bytes from overflow
    call file_open_read
    test rax, rax
    js 10f
    mov ebx, eax
    mov r14d, 4096             # grow only for unusually large metadata
    cmp r14, r12
    cmova r14, r12
    lea rdi, [r14 + 1]
    call mem_alloc
    mov r13, rax
    xor r15d, r15d
1:  mov edi, ebx
    lea rsi, [r13 + r15]
    mov rdx, r14
    sub rdx, r15
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    test rax, rax
    js 11f
    jz 6f                      # EOF also completes a line without a trailing newline
    mov rcx, r15
    add r15, rax
2:  cmp rcx, r15
    jae 3f
    cmp byte ptr [r13 + rcx], 10
    je 5f
    inc rcx
    jmp 2b
3:  cmp r15, r12
    jae 8f                     # no newline within max + 1 bytes
    cmp r15, r14
    jb 1b                      # continue after a short read
    add r14, r14
    cmp r14, r12
    cmova r14, r12
    mov rdi, r13
    lea rsi, [r14 + 1]
    call mem_realloc
    mov r13, rax
    jmp 1b
5:  mov r15, rcx
6:  mov byte ptr [r13 + r15], 0
    mov edi, ebx
    SYS SYS_close
    mov rax, r13
    mov rdx, r15
    EPILOGUE
8:  mov edi, ebx
    SYS SYS_close
    mov rdi, r13
    call mem_free
9:  xor eax, eax
    mov rdx, [rsp]
    EPILOGUE
10: mov [rsp], rax
    jmp 9b
11: mov [rsp], rax
    jmp 8b

# agent_session_header(s): title from the first part of the file
FN agent_session_header
    PROLOGUE 16
    mov rbx, rdi
    mov rdi, [rbx + AS_path]
    mov esi, 262144
    call agent_read_head
    test rax, rax
    jz 9f
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d              # line start
1:  cmp r14, r13
    jae 8f
    mov r15, r14
2:  cmp r15, r13
    jae 8f                      # incomplete last line: stop
    cmp byte ptr [r12 + r15], 10
    je 3f
    inc r15
    jmp 2b
3:  cmp r15, [rbx + AS_title_off]
    jb 31f                     # earlier records are already covered by the known title
    lea rax, [r15 + 1]
    mov [rbx + AS_record_off], rax
    mov rdi, rbx
    lea rsi, [r12 + r14]
    mov rdx, r15
    sub rdx, r14
    xor ecx, ecx                # title only
    call ingest_line
31: lea r14, [r15 + 1]
    # Later custom titles within this bounded prefix replace earlier ones.
    jmp 1b
8:  mov rdi, r12
    call mem_free
    mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

sort_sessions:
    PROLOGUE
    xor ebx, ebx
    mov rax, [rip + view]
    test rax, rax
    js 0f
    mov rcx, [rip + sessions + VEC_ptr]
    mov rbx, [rcx + rax*8]
0:
    mov r8, [rip + sessions + VEC_ptr]
    mov r9, [rip + page_count]
    mov ecx, 1
1:  cmp rcx, r9
    jae 4f
    mov rdx, rcx
2:  test rdx, rdx
    jz 3f
    mov rax, [r8 + rdx*8]
    mov r10, [r8 + rdx*8 - 8]
    mov r11, [rax + AS_recency]
    cmp r11, [r10 + AS_recency]
    jle 3f
    mov [r8 + rdx*8], r10
    mov [r8 + rdx*8 - 8], rax
    dec rdx
    jmp 2b
3:  inc rcx
    jmp 1b
4:  mov r9, [rip + sessions + VEC_len]
    test rbx, rbx
    jz 7f
    xor ecx, ecx
5:  cmp [r8 + rcx*8], rbx
    je 6f
    inc rcx
    jmp 5b
6:  mov [rip + view], rcx
7:  EPILOGUE

# ---------- parsing ----------

# set_title(s, ptr, len, strong): keep a short one-line title (strong = custom title)
set_title:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    test r14d, r14d
    jnz 1f
    cmp dword ptr [rbx + AS_titled], 0
    jne 9f
    cmp qword ptr [rbx + AS_title], 0
    jne 9f
1:  # first line, trimmed, at most 120 bytes
    xor ecx, ecx
2:  cmp rcx, r13
    jae 3f
    cmp byte ptr [r12 + rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  cmp rcx, 120
    jbe 4f
    mov ecx, 120
    # don't cut a utf-8 sequence
5:  movzx eax, byte ptr [r12 + rcx]
    and eax, 0xc0
    cmp eax, 0x80
    jne 4f
    dec rcx
    jmp 5b
4:  mov rdi, r12
    mov rsi, rcx
    call trim
    test rdx, rdx
    jz 9f
    push rax
    push rdx
    mov rdi, [rbx + AS_title]
    call mem_free
    pop rsi
    pop rdi
    call mem_dup
    mov [rbx + AS_title], rax
    test r14d, r14d
    jz 9f
    mov dword ptr [rbx + AS_titled], 1
    mov rcx, [rbx + AS_record_off]
    test rcx, rcx
    jz 9f                     # full transcript reads preserve the last index revision
    rol rcx, 17
    xor rcx, [rbx + AS_stamp]
    mov [rbx + AS_title_rev], rcx
9:  EPILOGUE

# add_msg(s, role, ptr, len, name cstr or 0)
# set_str(slot, ptr, len): *slot holds a copy of the bytes; an equal one stays
set_str:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [rbx]
    test rdi, rdi
    jz 1f
    call strlen
    cmp rax, r13
    jne 1f
    mov rdi, [rbx]
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jnz 9f
1:  mov rdi, [rbx]
    call mem_free
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rbx], rax
9:  EPILOGUE

# model_ok(ptr, len) -> 1 when the bytes name a model. Nothing, Claude Code's "<synthetic>" (its own
#   notices) and anything past a record's short string name none.
model_ok:
    xor eax, eax
    test rdi, rdi
    jz 9f
    test rsi, rsi
    jz 9f
    cmp rsi, 120
    ja 9f
    cmp byte ptr [rdi], '<'
    je 9f
    xor ecx, ecx
1:  cmp byte ptr [rdi + rcx], ' '
    jb 9f
    inc rcx
    cmp rcx, rsi
    jb 1b
    inc eax
9:  ret

# row_model(s, ptr, len): the model the session's row shows
row_model:
    PROLOGUE
    lea rbx, [rdi + AS_model]
    mov r14d, 1
    jmp 1f
# log_model(s, ptr, len): the model the log names for the replies that follow
log_model:
    PROLOGUE
    lea rbx, [rdi + AS_log_model]
    xor r14d, r14d
1:  mov r12, rsi
    mov r13, rdx
    mov rdi, rsi
    mov rsi, rdx
    call model_ok
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call set_str
    test r14d, r14d
    jz 9f
    mov dword ptr [rip + model_noted], 1
9:  EPILOGUE

# note_model(s, ptr, len): both: the log names the model of the replies that follow, and the last of
#   them is the row's
note_model:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call log_model
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call row_model
    EPILOGUE

# reply_label(s, text, len) -> the model a reply's label shows: the log's, when another one was shown
#   last (or none), else 0
reply_label:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call trim
    test rdx, rdx
    jz 8f                       # an empty reply is not shown
    mov rsi, [rbx + AS_log_model]
    test rsi, rsi
    jz 8f
    mov rdi, [rbx + AS_shown_model]
    test rdi, rdi
    jz 1f
    call strcmp_eq
    test eax, eax
    jnz 8f
1:  mov rdi, [rbx + AS_log_model]
    call strlen
    lea rdi, [rbx + AS_shown_model]
    mov rsi, [rbx + AS_log_model]
    mov rdx, rax
    call set_str
    mov rax, [rbx + AS_shown_model]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

add_msg:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    # trim, skip empty
    mov rdi, r13
    mov rsi, r14
    call trim
    test rdx, rdx
    jnz 1f
    test r15, r15
    jnz 1f
    cmp dword ptr [rip + keep_empty], 0
    je 9f                       # an extension's messages keep their places (agents_ext_msg)
1:  mov r13, rax
    mov r14, rdx
    # results are shown as a short excerpt
    cmp r12d, R_RESULT
    jne 3f
    xor ecx, ecx
    xor edx, edx
2:  cmp rcx, r14
    jae 3f
    cmp byte ptr [r13 + rcx], 10
    jne 21f
    inc edx
    cmp edx, 4
    je 22f
21: inc rcx
    cmp rcx, 360
    jb 2b
22: mov r14, rcx
3:  lea rdi, [rbx + AS_msgs]
    mov esi, AM_SIZE
    call vec_push
    mov [rsp], rax
    mov [rax + AM_role], r12d
    # sanitize: tabs -> spaces, drop CR and other controls
    lea rdi, [r14 + 1]
    call mem_alloc
    mov rcx, [rsp]
    mov [rcx + AM_text], rax
    xor ecx, ecx
    xor edx, edx
4:  cmp rcx, r14
    jae 6f
    movzx r8d, byte ptr [r13 + rcx]
    inc rcx
    cmp r8d, 10
    je 5f
    cmp r8d, 13
    je 4b
    cmp r8d, 27
    je 41f
    cmp r8d, 32
    jae 5f
    mov r8d, ' '
5:  mov [rax + rdx], r8b
    inc rdx
    jmp 4b
    # an escape sequence (the colors of a command's output) shows nothing: a CSI one up to its final
    # byte, any other the escape alone
41: cmp rcx, r14
    jae 4b
    cmp byte ptr [r13 + rcx], '['
    jne 4b
    inc rcx
42: cmp rcx, r14
    jae 4b
    movzx r8d, byte ptr [r13 + rcx]
    inc rcx
    sub r8d, 0x40
    cmp r8d, 0x3e
    ja 42b
    jmp 4b
6:  mov byte ptr [rax + rdx], 0
    mov rcx, [rsp]
    mov [rcx + AM_len], rdx
    test r15, r15
    jz 7f
    mov rdi, r15
    call strlen
    mov rdi, r15
    mov rsi, rax
    call mem_dup
    mov rcx, [rsp]
    mov [rcx + AM_name], rax
7:  mov qword ptr [rbx + AS_changed], 0
9:  EPILOGUE

# text_of(jv) -> rax ptr, rdx len : string, or concatenated "text" parts of an array (in tmp)
text_of:
    PROLOGUE
    mov rbx, rdi
    call json_type
    cmp eax, JT_STR
    jne 1f
    mov rdi, rbx
    call json_str
    EPILOGUE
1:  mov r14d, eax
    lea rdi, [rip + tmp]
    call sb_clear
    cmp r14d, JT_ARR
    jne 8f
    xor r12d, r12d
2:  mov rdi, rbx
    call json_len
    cmp r12d, eax
    jae 8f
    mov rdi, rbx
    mov esi, r12d
    call json_at
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Ltext]
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jz 3f
    push rax
    push rdx
    cmp qword ptr [rip + tmp + SB_len], 0
    je 21f
    lea rdi, [rip + tmp]
    mov esi, 10
    call sb_push_byte
21: pop rdx
    pop rsi
    lea rdi, [rip + tmp]
    call sb_push
3:  inc r12d
    jmp 2b
8:  mov rax, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    test rax, rax
    jnz 9f
    lea rax, [rip + .Lempty]
9:  EPILOGUE

# tool_summary(input jv) -> rax ptr, rdx len : the most telling field of a tool input,
# paths inside the project shown relative to it
tool_summary:
    push rbx
    push r12
    push r13
    call tool_field
    mov rbx, rax
    mov r12, rdx
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 1f
    call strlen
    mov r13, rax
    lea rax, [r13 + 1]
    cmp r12, rax
    jbe 1f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rip + g_project]
    mov rcx, r13
    call str_starts
    test eax, eax
    jz 1f
    cmp byte ptr [rbx + r13], '/'
    jne 1f
    lea rbx, [rbx + r13 + 1]
    sub r12, r13
    dec r12
1:  mov rax, rbx
    mov rdx, r12
    pop r13
    pop r12
    pop rbx
    ret

tool_field:
    PROLOGUE
    mov rbx, rdi
    call json_type
    cmp eax, JT_STR
    jne 1f
    mov rdi, rbx
    call json_str
    EPILOGUE
1:  lea r12, [rip + summary_keys]
2:  mov rsi, [r12]
    test rsi, rsi
    jz 3f
    mov rdi, rbx
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jnz 4f
    add r12, 8
    jmp 2b
3:  lea rax, [rip + .Lempty]
    xor edx, edx
4:  EPILOGUE

# ingest_line(s, ptr, len, full): full=0 only looks for a title
FN ingest_line
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], ecx
    mov rdi, rsi
    mov rsi, rdx
    call json_parse
    test rax, rax
    jz .Lil_ret
    mov r12, rax
    cmp dword ptr [rbx + AS_kind], 2
    je .Lil_codex
    cmp dword ptr [rbx + AS_kind], 3
    je .Lil_grok
    cmp dword ptr [rbx + AS_kind], 4
    je .Lil_opencode
    # ---- claude ----
    mov rdi, r12
    lea rsi, [rip + .Ltype]
    call json_get
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lcustom_title]
    call json_is
    test eax, eax
    jz 1f
    mov rdi, r12
    lea rsi, [rip + .LcustomTitle]
    call json_get
    mov rdi, rax
    call json_str
    mov rdi, rbx
    mov rsi, rax
    mov ecx, 1
    call set_title
    jmp .Lil_ret
1:  mov rdi, r13
    lea rsi, [rip + .Luser]
    call json_is
    test eax, eax
    jnz .Lil_user
    mov rdi, r13
    lea rsi, [rip + .Lassistant]
    call json_is
    test eax, eax
    jnz .Lil_assist
    jmp .Lil_ret
.Lil_user:
    # skip meta / command records
    mov rdi, r12
    lea rsi, [rip + .LisMeta]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_TRUE
    je .Lil_ret
    mov rdi, r12
    lea rsi, [rip + .Lmessage]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lcontent]
    call json_get
    mov r13, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne .Lil_user_arr
    mov rdi, r13
    call json_str
    cmp byte ptr [rax], '<'
    je .Lil_ret
    mov r14, rax
    mov r15, rdx
    mov rdi, rbx
    mov rsi, rax
    xor ecx, ecx
    call set_title
    cmp dword ptr [rsp], 0
    je .Lil_ret
    mov rdi, rbx
    mov esi, R_USER
    mov rdx, r14
    mov rcx, r15
    xor r8d, r8d
    call add_msg
    jmp .Lil_ret
.Lil_user_arr:
    cmp dword ptr [rsp], 0
    je .Lil_ret
    xor r14d, r14d
2:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae .Lil_ret
    mov rdi, r13
    mov esi, r14d
    call json_at
    mov r15, rax
    mov rdi, rax
    lea rsi, [rip + .Ltype]
    call json_get
    mov [rsp + 8], rax
    mov rdi, rax
    lea rsi, [rip + .Ltool_result]
    call json_is
    test eax, eax
    jz 3f
    mov rdi, r15
    lea rsi, [rip + .Lcontent]
    call json_get
    mov rdi, rax
    call text_of
    mov rdi, rbx
    mov esi, R_RESULT
    mov rcx, rdx
    mov rdx, rax
    xor r8d, r8d
    call add_msg
    jmp 4f
3:  mov rdi, [rsp + 8]
    lea rsi, [rip + .Ltext]
    call json_is
    test eax, eax
    jz 4f
    mov rdi, r15
    lea rsi, [rip + .Ltext]
    call json_get
    mov rdi, rax
    call json_str
    cmp byte ptr [rax], '<'
    je 4f
    mov rdi, rbx
    mov esi, R_USER
    mov rcx, rdx
    mov rdx, rax
    xor r8d, r8d
    call add_msg
4:  inc r14d
    jmp 2b
.Lil_assist:
    mov rdi, r12
    lea rsi, [rip + .Lmessage]
    call json_get
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lmodel]
    call json_get
    mov rdi, rax
    call json_str
    xor ecx, ecx                # Claude Code's own notices ("<synthetic>") are no model's replies
    test rdx, rdx
    jz 11f
    cmp byte ptr [rax], '<'
    sete cl
11: mov [rsp + 32], ecx
    mov rdi, rbx
    mov rsi, rax
    call note_model
    cmp dword ptr [rsp], 0
    je .Lil_ret
    mov rdi, r13
    lea rsi, [rip + .Lcontent]
    call json_get
    mov r13, rax
    xor r14d, r14d
5:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae .Lil_ret
    mov rdi, r13
    mov esi, r14d
    call json_at
    mov r15, rax
    mov rdi, rax
    lea rsi, [rip + .Ltype]
    call json_get
    mov [rsp + 8], rax
    mov rdi, rax
    lea rsi, [rip + .Ltext]
    call json_is
    test eax, eax
    jz 6f
    mov rdi, r15
    lea rsi, [rip + .Ltext]
    call json_get
    mov rdi, rax
    call json_str
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    xor r8d, r8d
    cmp dword ptr [rsp + 32], 0
    jne 12f
    mov rdi, rbx
    mov rsi, rax
    call reply_label
    mov r8, rax
12: mov rdi, rbx
    mov esi, R_ASSIST
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    call add_msg
    jmp 7f
6:  mov rdi, [rsp + 8]
    lea rsi, [rip + .Ltool_use]
    call json_is
    test eax, eax
    jz 7f
    mov rdi, r15
    lea rsi, [rip + .Lname]
    call json_get
    mov rdi, rax
    call json_str
    mov [rsp + 16], rax
    mov rdi, r15
    lea rsi, [rip + .Linput]
    call json_get
    mov rdi, rax
    call tool_summary
    mov r8, [rsp + 16]
    test r8, r8
    jnz 61f
    lea r8, [rip + .Ltool]
61: mov rdi, rbx
    mov esi, R_TOOL
    mov rcx, rdx
    mov rdx, rax
    call add_msg
7:  inc r14d
    jmp 5b
.Lil_opencode:
    mov rdi, r12
    lea rsi, [rip + .Loc_part]
    call json_get
    mov r13, rax
    test rax, rax
    jnz .Loc_part_message
    # The first snapshot record carries OpenCode's own title, including /rename.
    mov rdi, r12
    lea rsi, [rip + .Loc_updated]
    call json_get
    test rax, rax
    jz 11f
    cmp dword ptr [rax], JT_NUM
    jne 11f
    mov esi, [rax + 4]
    mov rdi, [rax + 8]
    call parse_u64
    mov rcx, 9223372036854
    cmp rax, rcx
    ja 11f
    imul rax, rax, 1000000
    mov [rbx + AS_recency], rax
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    mov [rbx + AS_mtime], rax
11:
    mov rdi, r12
    lea rsi, [rip + .Lmodel]
    call json_get
    mov rdi, rax
    call json_str
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    mov rdi, [rbx + AS_model]   # the header names the row's model, or none: a deleted message's goes
    call mem_free
    mov qword ptr [rbx + AS_model], 0
    mov rdi, rbx
    mov rsi, [rsp + 16]
    mov rdx, [rsp + 24]
    call row_model
    mov rdi, r12
    lea rsi, [rip + .Loc_title]
    call json_get
    mov rdi, rax
    call json_str
    mov rdi, rbx
    mov rsi, rax
    mov ecx, 1
    call set_title
    jmp .Lil_ret
.Loc_part_message:
    cmp dword ptr [rsp], 0
    je .Lil_ret
    mov rdi, r13
    lea rsi, [rip + .Ltype]
    call json_get
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Ltext]
    call json_is
    test eax, eax
    jz .Loc_part_tool
    mov rdi, r13
    lea rsi, [rip + .Loc_ignored]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_TRUE
    je .Lil_ret
    mov rdi, r13
    lea rsi, [rip + .Loc_synthetic]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_TRUE
    je .Lil_ret
    mov rdi, r12
    lea rsi, [rip + .Lrole]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Luser]
    call json_is
    mov r15d, R_ASSIST
    test eax, eax
    jz 1f
    mov r15d, R_USER
1:  mov rdi, r12
    lea rsi, [rip + .Lmodel]
    call json_get
    mov rdi, rax
    call json_str
    mov rdi, rbx                # the row keeps the header's: the latest message's, also one of tools
    mov rsi, rax
    call log_model
    mov rdi, r13
    lea rsi, [rip + .Ltext]
    call json_get
    mov rdi, rax
    call json_str
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    xor r14d, r14d
    cmp r15d, R_ASSIST
    jne 12f
    mov rdi, rbx
    mov rsi, rax
    call reply_label
    mov r14, rax
12: mov rdi, rbx
    mov esi, r15d
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    mov r8, r14
    call add_msg
    jmp .Lil_ret
.Loc_part_tool:
    mov rdi, r14
    lea rsi, [rip + .Loc_error]
    call json_is
    test eax, eax
    jz 10f
    mov rdi, r13
    lea rsi, [rip + .Ltext]
    call json_get
    mov rdi, rax
    call json_str
    mov rcx, rdx
    mov rdx, rax
    mov rdi, rbx
    mov esi, R_RESULT
    xor r8d, r8d
    call add_msg
    jmp .Lil_ret
10:
    mov rdi, r14
    lea rsi, [rip + .Ltool]
    call json_is
    test eax, eax
    jz .Lil_ret              # reasoning, snapshots and bookkeeping are not conversation messages
    mov rdi, r13
    lea rsi, [rip + .Loc_state]
    call json_get
    mov r14, rax
    mov rdi, r13
    lea rsi, [rip + .Ltool]
    call json_get
    mov rdi, rax
    call json_str
    mov r15, rax
    mov rdi, r14
    lea rsi, [rip + .Linput]
    call json_get
    mov rdi, rax
    call tool_summary
    mov rcx, rdx
    mov rdx, rax
    mov rdi, rbx
    mov esi, R_TOOL
    mov r8, r15
    call add_msg
    mov rdi, r14
    lea rsi, [rip + .Loutput]
    call json_get
    test rax, rax
    jnz 2f
    mov rdi, r14
    lea rsi, [rip + .Loc_error]
    call json_get
2:  mov rdi, rax
    call json_str
    mov rcx, rdx
    mov rdx, rax
    mov rdi, rbx
    mov esi, R_RESULT
    xor r8d, r8d
    call add_msg
    jmp .Lil_ret

.Lil_codex:
    mov rdi, r12
    lea rsi, [rip + .Ltype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lturn_context]
    call json_is
    test eax, eax
    jz .Lcx_item
    mov rdi, r12
    lea rsi, [rip + .Lpayload]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lmodel]
    call json_get
    mov rdi, rax
    call json_str
    mov rdi, rbx
    mov rsi, rax
    call note_model
    jmp .Lil_ret
.Lcx_item:
    mov rdi, r12
    lea rsi, [rip + .Lpayload]
    call json_get
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Ltype]
    call json_get
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .Lmessage]
    call json_is
    test eax, eax
    jz .Lcx_tool
    mov rdi, r13
    lea rsi, [rip + .Lrole]
    call json_get
    mov r15, rax
    mov rdi, r13
    lea rsi, [rip + .Lcontent]
    call json_get
    mov rdi, rax
    call text_of
    test rdx, rdx
    jz .Lil_ret
    cmp byte ptr [rax], '<'
    je .Lil_ret
    cmp byte ptr [rax], '#'
    je .Lil_ret
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    mov rdi, r15
    lea rsi, [rip + .Luser]
    call json_is
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    xor ecx, ecx
    call set_title
    mov esi, R_USER
    jmp 81f
8:  mov rdi, r15
    lea rsi, [rip + .Lassistant]
    call json_is
    test eax, eax
    jz .Lil_ret
    mov esi, R_ASSIST
81: cmp dword ptr [rsp], 0
    je .Lil_ret
    xor r8d, r8d
    cmp esi, R_ASSIST
    jne 82f
    mov rdi, rbx
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    call reply_label
    mov r8, rax
    mov esi, R_ASSIST
82: mov rdi, rbx
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    call add_msg
    jmp .Lil_ret
.Lcx_tool:
    cmp dword ptr [rsp], 0
    je .Lil_ret
    mov rdi, r14
    lea rsi, [rip + .Lfunction_call]
    call json_is
    test eax, eax
    jnz 9f
    mov rdi, r14
    lea rsi, [rip + .Lcustom_tool_call]
    call json_is
    test eax, eax
    jnz 9f
    mov rdi, r14
    lea rsi, [rip + .Lfunction_call_output]
    call json_is
    test eax, eax
    jnz 10f
    mov rdi, r14
    lea rsi, [rip + .Lcustom_tool_call_output]
    call json_is
    test eax, eax
    jnz 10f
    jmp .Lil_ret
9:  # name and arguments are copied out: the arguments are JSON text themselves
    mov rdi, r13
    lea rsi, [rip + .Lname]
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jnz 90f
    lea rax, [rip + .Ltool]
    mov edx, 4
90: mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rsp + 16], rax
    mov rdi, r13
    lea rsi, [rip + .Larguments]
    call json_get
    test rax, rax
    jnz 91f
    mov rdi, r13
    lea rsi, [rip + .Linput]
    call json_get
91: mov rdi, rax
    call tool_summary
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rsp + 24], rax
    mov rdi, rax
    call strlen
    mov rdi, [rsp + 24]
    mov rsi, rax
    call json_parse
    test rax, rax
    jz 93f
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Ls_command]
    call json_get
    test rax, rax
    jz 94f
    mov r15, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne 95f
    # command array -> words joined by spaces
    lea rdi, [rip + tmp]
    call sb_clear
    xor r14d, r14d
96: mov rdi, r15
    call json_len
    cmp r14d, eax
    jae 97f
    test r14d, r14d
    jz 98f
    lea rdi, [rip + tmp]
    mov esi, ' '
    call sb_push_byte
98: mov rdi, r15
    mov esi, r14d
    call json_at
    mov rdi, rax
    call json_str
    lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push
    inc r14d
    jmp 96b
97: mov rax, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    jmp 99f
95: mov rdi, r15
    call json_str
    test rax, rax
    jnz 99f
94: mov rdi, r14
    call tool_summary
    jmp 99f
93: mov rdi, [rsp + 24]
    call strlen
    mov rdx, rax
    mov rax, [rsp + 24]
99: mov rdi, rbx
    mov esi, R_TOOL
    mov rcx, rdx
    mov rdx, rax
    mov r8, [rsp + 16]
    call add_msg
    mov rdi, [rsp + 16]
    call mem_free
    mov rdi, [rsp + 24]
    call mem_free
    jmp .Lil_ret
10: mov rdi, r13
    lea rsi, [rip + .Loutput]
    call json_get
    mov rdi, rax
    call text_of
    mov rdi, rbx
    mov esi, R_RESULT
    mov rcx, rdx
    mov rdx, rax
    xor r8d, r8d
    call add_msg
    jmp .Lil_ret
    # ---- grok build: {"params": {"update": {"sessionUpdate": kind, ...}}}, whole messages ----
.Lil_grok:
    mov rdi, r12
    lea rsi, [rip + .Lparams]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lupdate]
    call json_get
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lsession_update]
    call json_get
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lgk_user]
    call json_is
    test eax, eax
    jnz 110f
    cmp dword ptr [rsp], 0
    je .Lil_ret                 # a title comes from a prompt only
    mov rdi, r14
    lea rsi, [rip + .Lgk_agent]
    call json_is
    test eax, eax
    jnz 111f
    mov rdi, r14
    lea rsi, [rip + .Lgk_tool]
    call json_is
    test eax, eax
    jnz 113f
    mov rdi, r14
    lea rsi, [rip + .Lgk_tool_update]
    call json_is
    test eax, eax
    jnz 114f
    jmp .Lil_ret                # thoughts, plans, modes, hooks, usage
110: mov rdi, r13
    lea rsi, [rip + .Lcontent]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Ltext]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz .Lil_ret
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    mov rdi, rbx
    mov rsi, rax
    xor ecx, ecx
    call set_title
    mov rdi, r13                # the model chosen for the prompt, when the log names it; the row shows
    lea rsi, [rip + .Lgk_meta]  # the session's current one, from summary.json
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lgk_model]
    call json_get
    mov rdi, rax
    call json_str
    mov rdi, rbx
    mov rsi, rax
    call log_model
    mov esi, R_USER
    jmp 112f
111: mov rdi, r13
    lea rsi, [rip + .Lcontent]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Ltext]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz .Lil_ret
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    mov esi, R_ASSIST
112: cmp dword ptr [rsp], 0
    je .Lil_ret
    xor r8d, r8d
    cmp esi, R_ASSIST
    jne 119f
    mov rdi, rbx
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    call reply_label
    mov r8, rax
    mov esi, R_ASSIST
119: mov rdi, rbx
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    call add_msg
    jmp .Lil_ret
    # a tool call: its title is the tool's name, rawInput its arguments as an object
113: mov rdi, r13
    lea rsi, [rip + .Ltitle]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jnz 1131f
    lea rax, [rip + .Ltool]
1131: mov [rsp + 16], rax
    mov rdi, r13
    lea rsi, [rip + .Lraw_input]
    call json_get
    mov rdi, rax
    call tool_summary
    mov rdi, rbx
    mov esi, R_TOOL
    mov rcx, rdx
    mov rdx, rax
    mov r8, [rsp + 16]
    call add_msg
    jmp .Lil_ret
    # its result: the update that completes (or fails) the call, with text parts and diffs
114: mov rdi, r13
    lea rsi, [rip + .Lstatus]
    call json_get
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lgk_completed]
    call json_is
    test eax, eax
    jnz 115f
    mov rdi, r14
    lea rsi, [rip + .Lgk_failed]
    call json_is
    test eax, eax
    jz .Lil_ret                 # progress: the call's kind, title or locations
115: mov rdi, r13
    lea rsi, [rip + .Lcontent]
    call json_get
    mov r14, rax
    lea rdi, [rip + tmp]
    call sb_clear
    xor r15d, r15d
116: mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 118f
    mov rdi, r14
    mov esi, r15d
    call json_at
    mov [rsp + 8], rax
    mov rdi, rax
    lea rsi, [rip + .Lcontent]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Ltext]
    call json_get
    test rax, rax
    jnz 1161f
    mov rdi, [rsp + 8]
    lea rsi, [rip + .Lnew_text]
    call json_get
1161: mov rdi, rax
    call json_str
    test rdx, rdx
    jz 117f
    push rax
    push rdx
    cmp qword ptr [rip + tmp + SB_len], 0
    je 1162f
    lea rdi, [rip + tmp]
    mov esi, 10
    call sb_push_byte
1162: pop rdx
    pop rsi
    lea rdi, [rip + tmp]
    call sb_push
117: inc r15d
    jmp 116b
118: cmp qword ptr [rip + tmp + SB_len], 0
    je .Lil_ret
    mov rdi, rbx
    mov esi, R_RESULT
    mov rdx, [rip + tmp + SB_ptr]
    mov rcx, [rip + tmp + SB_len]
    xor r8d, r8d
    call add_msg
.Lil_ret:
    EPILOGUE

# agent_grok_summary(log) -> summary.json beside a Grok Build session's log, parsed (the JSON arena), or 0
FN agent_grok_summary
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call path_dirlen
    mov r12, rax
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    lea rdi, [rip + line]
    lea rsi, [rip + .Lgrok_summary]
    call sb_push_cstr
    mov rdi, [rip + line + SB_ptr]
    mov esi, 1 << 20
    call agent_read_head
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    mov rsi, rdx
    call json_parse
    mov rbx, rax
    mov rdi, r12
    call mem_free
    mov rax, rbx
9:  EPILOGUE

# agent_grok_title(s): Grok Build's title for the session (generated, or set with /rename) replaces the one
# from its first prompt
FN agent_grok_title
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + AS_path]
    call agent_grok_summary
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lcurrent_model_id]
    call json_get
    mov rdi, rax
    call json_str
    mov rdi, rbx
    mov rsi, rax
    call row_model               # the session's current model only: its log names none
    mov rdi, r12
    lea rsi, [rip + .Lgenerated_title]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 9f
    mov r12, rax
    mov r13, rdx
    mov rdi, [rbx + AS_title]
    call mem_free
    mov qword ptr [rbx + AS_title], 0
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    call set_title
9:  EPILOGUE

# session_update(s): parse bytes appended since the last read
FN session_update
    PROLOGUE 16
    mov rbx, rdi
    cmp dword ptr [rbx + AS_kind], AS_KIND_EXT
    je 9f                       # its extension sends its messages (agentext.s)
    mov rax, [rbx + AS_live]    # rhun drives it: while its program runs or is about to, its rows come
    test rax, rax               # from the stream and the file it writes is not read as well
    jz 16f                      # (agents_resync reads it again once the program is gone)
    mov eax, [rax + AL_state]
    cmp eax, ALS_STARTING
    jb 16f
    cmp eax, ALS_HELD
    jbe 9f
16: mov r12d, -1
    cmp dword ptr [rip + g_remote], 0     # remote hosts: the size from the host, no descriptor
    je 11f
    mov rdi, [rbx + AS_path]
    call vfs_stat
    test rax, rax
    js 9f
    mov rax, [rip + vfs_statbuf + 48]
    jmp 12f
11: mov rdi, [rbx + AS_path]
    call file_open_read
    test rax, rax
    js 9f
    mov r12d, eax
    mov edi, eax
    call file_size
12: mov r13, rax
    cmp rax, [rbx + AS_off]
    jb 10f                      # truncated: reload
    je 8f
    # read the new bytes into the partial-line buffer
    mov r14, r13
    sub r14, [rbx + AS_off]
    test r12d, r12d
    jns 13f
    mov rdi, [rbx + AS_path]
    mov rsi, [rbx + AS_off]
    mov rdx, r14
    call vfs_read_at
    test rax, rax
    jz 8f
    mov [rsp], rax
    mov [rsp + 8], rdx
    lea rdi, [rbx + AS_part]
    mov rsi, rdx
    call sb_reserve
    mov rdi, rax
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call memcpy
    mov rdi, [rsp]
    call mem_free
    mov rax, [rsp + 8]
    jmp 14f
13: lea rdi, [rbx + AS_part]
    mov rsi, r14
    call sb_reserve
    mov rsi, rax
    mov edi, r12d
    mov rdx, r14
    mov r10, [rbx + AS_off]
    mov eax, 17                 # pread64
    XSYS
14: test rax, rax
    jle 8f
    add [rbx + AS_off], rax
    add [rbx + AS_part + SB_len], rax
    # complete lines
    mov r14, [rbx + AS_part + SB_ptr]
    mov r15, [rbx + AS_part + SB_len]
    xor ecx, ecx                # line start
    mov [rsp], rcx
    xor edx, edx
1:  cmp rdx, r15
    jae 3f
    cmp byte ptr [r14 + rdx], 10
    jne 2f
    mov [rsp + 8], rdx
    mov rdi, rbx
    mov rcx, [rsp]
    lea rsi, [r14 + rcx]
    mov rdx, [rsp + 8]
    sub rdx, rcx
    mov ecx, 1
    call ingest_line
    mov rdx, [rsp + 8]
    lea rcx, [rdx + 1]
    mov [rsp], rcx
2:  inc rdx
    jmp 1b
3:  # keep the tail
    mov rcx, [rsp]
    mov rdx, r15
    sub rdx, rcx
    mov rdi, r14
    lea rsi, [r14 + rcx]
    push rdx
    push rdx
    call memmove
    pop rdx
    pop rdx
    mov [rbx + AS_part + SB_len], rdx
    call time_ms
    mov [rbx + AS_changed], rax
    mov dword ptr [rip + g_dirty], 1
8:  mov edi, r12d
    test edi, edi
    js 9f
    SYS SYS_close
9:  EPILOGUE
10: mov qword ptr [rbx + AS_off], 0
    mov qword ptr [rbx + AS_part + SB_len], 0
    mov rdi, rbx
    call session_clear_msgs
    mov edi, r12d
    test edi, edi
    js 15f
    SYS SYS_close
15:
    mov rdi, rbx
    call session_update
    EPILOGUE

# ---------- refresh ----------

# agents_poll(): inspect at most the newest 50 rows and the open conversation.
FN agents_poll
    PROLOGUE
    call time_ms
    mov [rip + last_poll], rax
    call agents_poll_prefetch   # remote hosts: their stats in one request
    xor ebx, ebx
    xor r13d, r13d
1:  cmp rbx, [rip + page_count]
    jae 3f
    cmp ebx, 50
    jae 3f
    mov rax, [rip + sessions + VEC_ptr]
    mov r12, [rax + rbx*8]
    call poll_session
    inc rbx
    jmp 1b
3:  mov rbx, [rip + view]     # the open conversation, unless the rows above had it (it can be
    test rbx, rbx               # pinned past a short page, at page_count)
    js 4f
    cmp rbx, [rip + page_count]
    jae 31f
    cmp rbx, 50
    jb 4f
31: mov rax, [rip + sessions + VEC_ptr]
    mov r12, [rax + rbx*8]
    call poll_session
4:  mov rbx, [rip + page_count] # the sessions rhun drives that the page lacks (a new conversation): their
41: cmp rbx, [rip + sessions + VEC_len]  # files' growth asks discovery to list them
    jae 42f
    mov rax, [rip + sessions + VEC_ptr]
    mov r12, [rax + rbx*8]
    cmp rbx, [rip + view]
    je 43f                      # polled above
    cmp qword ptr [r12 + AS_live], 0
    je 43f
    call poll_session
43: inc rbx
    jmp 41b
42: call vfs_stats_clear
    test r13d, r13d
    jz 5f
    call sort_sessions
    mov dword ptr [rip + g_dirty], 1
5:  EPILOGUE

# agents_poll_prefetch(): remote hosts: the files agents_poll stats, asked for in one request
agents_poll_prefetch:
    cmp dword ptr [rip + g_remote], 0
    je 9f
    PROLOGUE 432
    xor ebx, ebx                # rows
    xor r12d, r12d              # paths
1:  cmp rbx, [rip + page_count]
    jae 2f
    cmp ebx, 50
    jae 2f
    mov rax, [rip + sessions + VEC_ptr]
    mov rax, [rax + rbx*8]
    mov rcx, [rax + AS_path]
    test rcx, rcx
    jz 11f
    mov [rsp + r12*8], rcx
    inc r12
11: inc rbx
    jmp 1b
2:  mov rbx, [rip + view]
    test rbx, rbx
    js 3f
    cmp rbx, [rip + sessions + VEC_len]
    jae 3f
    mov rax, [rip + sessions + VEC_ptr]
    mov rax, [rax + rbx*8]
    mov rcx, [rax + AS_path]
    test rcx, rcx
    jz 3f
    mov [rsp + r12*8], rcx
    inc r12
3:  test r12, r12
    jz 8f
    mov rdi, rsp
    mov rsi, r12
    call vfs_stats_prefetch
8:  EPILOGUE
9:  ret

poll_session:
    cmp dword ptr [r12 + AS_kind], 4
    je 9f
    cmp dword ptr [r12 + AS_kind], AS_KIND_EXT
    je 9f                      # an extension says when its sessions change                      # the worker owns OpenCode snapshot replacement and database recency
    mov rdi, [r12 + AS_path]
    call vfs_stamp
    cmp rax, [r12 + AS_stamp]
    je 9f
    mov [r12 + AS_stamp], rax
    mov dword ptr [rip + index_pending], 1
    mov rdi, [r12 + AS_path]
    call vfs_mtime_ns
    mov [r12 + AS_recency], rax
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    mov [r12 + AS_mtime], rax
    mov r13d, 1
    call time_ms
    mov [r12 + AS_changed], rax
    cmp rbx, [rip + view]
    jne 9f
    mov rdi, r12
    call session_update
9:  ret

FN agents_on_change
    call agents_watch_repo      # a new worktree's registration folder too
    call time_ms
    add rax, 150
    mov [rip + index_debounce], rax
    ret

# agents_watch_repo(): the repository's worktree registrations add roots, so the panel watches them: the
# common .git folder (for its worktrees entry), .git/worktrees (a worktree added or removed) and each
# registration's folder (its gitdir names a moved worktree). A folder without a repository has none.
agents_watch_repo:
    PROLOGUE
    call git_project_common_dir
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    call watch_agents_dir
    mov [rip + common_wd], eax
    mov rdi, rbx
    lea rsi, [rip + .Lworktrees_entry]
    call path_join
    mov r12, rax
    mov rdi, rax
    call watch_agents_dir
    mov [rip + registry_wd], eax
    mov rdi, r12
    lea rsi, [rip + registration_cb]
    mov rdx, r12
    call vfs_dir_each
    mov rdi, r12
    call mem_free
9:  EPILOGUE

registration_cb:
    test edx, edx
    jz 1f
    push rbx
    call path_join
    mov rbx, rax
    mov rdi, rax
    call watch_agents_dir
    mov rdi, rbx
    call mem_free
    pop rbx
1:  ret

# agents_event(wd, name, mask) -> 1 when an event in a watched folder can change the sessions listed: in
# the common .git folder its worktrees entry alone, any registration added or removed, a registration's
# gitdir (a moved worktree), a session file created, removed or renamed. Growth is polled, and the rest
# of Git's activity (index, HEAD, refs) or of a shared Codex day folder changes nothing here.
FN agents_event
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    mov eax, 1
    cmp ebx, [rip + registry_wd]
    je 9f
    mov rdi, r12
    lea rsi, [rip + .Lworktrees_entry]
    cmp ebx, [rip + common_wd]
    je 1f
    lea rsi, [rip + .Lgitdir_entry]
1:  call strcmp_eq
    test eax, eax
    jnz 9f
    cmp ebx, [rip + common_wd]
    je 9f
    test r13d, IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO
    jz 9f
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rip + .Ljsonl_entry]
    mov ecx, 6
    call str_ends
9:  pop r13
    pop r12
    pop rbx
    ret

FN agents_timeout
    cmp dword ptr [rip + index_pid], 0
    jne 1f
    cmp qword ptr [rip + reapers + VEC_len], 0
    jne 1f
    cmp qword ptr [rip + g_project], 0
    je 3f
    cmp dword ptr [rip + g_show_agents], 0
    je 3f
    call time_ms
    mov rcx, [rip + last_poll]
    add rcx, 1000
    sub rcx, rax
    cmp qword ptr [rip + index_debounce], 0
    je 2f
    mov rdx, [rip + index_debounce]
    sub rdx, rax
    cmp rdx, rcx
    cmovl rcx, rdx
2:  cmp dword ptr [rip + index_pending], 0
    je 4f
    xor edx, edx                # a run asked for starts at once
    cmp dword ptr [rip + index_loud], 0
    jne 21f
    mov rdx, [rip + last_scan]  # a routine one once ROUTINE_GAP has passed since the last run
    add rdx, ROUTINE_GAP
    sub rdx, rax
21: cmp rdx, rcx
    cmovl rcx, rdx
4:  xor eax, eax
    test rcx, rcx
    cmovns rax, rcx
    ret
1:  mov eax, 50
    ret
3:  mov eax, -1
    ret

FN agents_tick
    PROLOGUE
    call index_reap
    call index_finish
    # a worker that does not finish (blocked on a FIFO named .jsonl, or a hung network home) would keep
    # every later run from starting: stop it and report the failure
    cmp dword ptr [rip + index_pid], 0
    je 7f
    call time_ms
    sub rax, [rip + index_started]
    cmp rax, INDEX_TIMEOUT
    jb 7f
    call agents_shutdown
    mov dword ptr [rip + index_error], 1
    call time_ms
    mov [rip + last_scan], rax
    call index_dirty
7:  cmp qword ptr [rip + g_project], 0
    je 9f
    cmp dword ptr [rip + g_show_agents], 0
    jne 0f
    mov dword ptr [rip + last_visible], 0
    jmp 9f
0:  cmp dword ptr [rip + last_visible], 0
    jne 81f
    mov dword ptr [rip + last_visible], 1
    mov dword ptr [rip + index_pending], 1
81:
    call time_ms
    mov rbx, rax
    cmp qword ptr [rip + index_debounce], 0
    je 1f
    cmp rbx, [rip + index_debounce]
    jb 1f
    mov qword ptr [rip + index_debounce], 0
    mov dword ptr [rip + index_pending], 1
1:  mov rax, rbx
    sub rax, [rip + last_poll]
    cmp rax, 1000
    jb 2f
    call agents_poll
    call time_now                # a frame when a label shown changes, not every second
    cmp rax, [rip + label_due]
    jb 2f
    mov dword ptr [rip + g_dirty], 1
2:  mov rax, rbx
    sub rax, [rip + last_scan]
    cmp rax, 10000
    jb 3f
    mov dword ptr [rip + index_pending], 1
3:  cmp dword ptr [rip + index_pid], 0
    jne 9f
    cmp dword ptr [rip + index_pending], 0
    je 9f
    # a run asked for starts now; a routine one (a session grew, a folder changed) waits until
    # ROUTINE_GAP after the last, so a live conversation does not run discovery back to back
    cmp dword ptr [rip + index_loud], 0
    jne 4f
    mov rax, rbx
    sub rax, [rip + last_scan]
    cmp rax, ROUTINE_GAP
    jb 9f
4:  call index_start
9:  EPILOGUE

# Explicit control waits can load sessions even while the panel is hidden.
FN agents_request_now
    cmp qword ptr [rip + g_project], 0
    je 1f
    cmp dword ptr [rip + index_pid], 0
    jne 1f
    cmp dword ptr [rip + g_show_agents], 0
    je 2f
    cmp dword ptr [rip + last_visible], 0
    jne 2f
    mov dword ptr [rip + last_visible], 1
    mov dword ptr [rip + index_pending], 1
2:
    cmp dword ptr [rip + index_pending], 0
    je 1f
    jmp index_start
1:  ret

FN agents_page_dump
    PROLOGUE
    mov r12, rdi
    lea rsi, [rip + .Lpage_shown]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rip + page_count]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Lpage_total]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rip + total_count]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Lpage_loading]
    call sb_push_cstr
    call index_loading           # what the panel shows; wait-agents waits for any run
    mov rdi, r12
    xor esi, esi
    test eax, eax
    setne sil
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Lpage_error]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rip + index_error]
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# agents_runs_dump(sb): "runs=N", the discovery runs started so far (print-agents-runs)
FN agents_runs_dump
    push rbx
    mov rbx, rdi
    lea rsi, [rip + .Lpage_runs]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + index_runs]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    pop rbx
    ret

# open_session(i)
open_session:
    PROLOGUE
    mov [rip + view], rdi
    mov rax, [rip + sessions + VEC_ptr]
    mov rbx, [rax + rdi*8]
    mov rdi, rbx
    call agentext_opened        # AI (D4): it replaces a new session being written; the box is its
    mov dword ptr [rbx + AS_loaded], 1
    cmp dword ptr [rbx + AS_kind], AS_KIND_EXT
    jne 1f
    mov rdi, rbx
    call agentext_open          # its extension is asked for the messages
1:  mov rdi, rbx
    call observe_session
    mov rdi, rbx
    call session_update
    mov dword ptr [rip + th_follow], 1
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

FN cmd_focus_agents
    mov dword ptr [rip + cfg_agents], 1
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov edi, 2
    jmp app_reveal_panel

# agents_dump(sb): sessions (kind, title, messages) and the open thread, for tests
FN agents_dump
    PROLOGUE
    mov r15, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + page_count]
    jae 3f
    mov rax, [rip + sessions + VEC_ptr]
    mov r12, [rax + rbx*8]
    lea rsi, [rip + .Lclaude_name]
    cmp dword ptr [r12 + AS_kind], 2
    jne 23f
    lea rsi, [rip + .Lcodex_name]
23: cmp dword ptr [r12 + AS_kind], 3
    jne 2f
    lea rsi, [rip + .Lgrok_name]
2:  cmp dword ptr [r12 + AS_kind], 4
    jne 24f
    lea rsi, [rip + .Lopencode_name]
24: cmp dword ptr [r12 + AS_kind], AS_KIND_EXT
    jne 26f
    mov rdi, [r12 + AS_ext]
    call agentext_title
    mov rsi, rax
26: mov rdi, r15
    call sb_push_cstr
    mov rsi, [r12 + AS_worktree]
    test rsi, rsi
    jz 22f
    mov rdi, r15
    lea rsi, [rip + .Lworktree_dump]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [r12 + AS_worktree]
    call sb_push_cstr
    mov rdi, r15
    mov esi, ']'
    call sb_push_byte
22: mov rsi, [r12 + AS_model]
    test rsi, rsi
    jz 25f
    mov rdi, r15
    lea rsi, [rip + .Lmodel_dump]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [r12 + AS_model]
    call sb_push_cstr
    mov rdi, r15
    mov esi, ']'
    call sb_push_byte
25: mov rdi, r15
    mov esi, ':'
    call sb_push_byte
    mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    mov rsi, [r12 + AS_title]
    test rsi, rsi
    jnz 21f
    lea rsi, [rip + .Luntitled]
21: mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 1b
3:  mov rax, [rip + view]
    test rax, rax
    js 9f
    mov rcx, [rip + sessions + VEC_ptr]
    mov r12, [rcx + rax*8]
    xor ebx, ebx
4:  cmp rbx, [r12 + AS_msgs + VEC_len]
    jae 9f
    imul r13, rbx, AM_SIZE
    add r13, [r12 + AS_msgs + VEC_ptr]
    mov eax, [r13 + AM_role]
    lea rcx, [rip + role_names]
    mov rsi, [rcx + rax*8]
    mov rdi, r15
    call sb_push_cstr
    mov rsi, [r13 + AM_name]
    test rsi, rsi
    jz 5f
    mov rdi, r15
    mov esi, '('
    call sb_push_byte
    mov rdi, r15
    mov rsi, [r13 + AM_name]
    call sb_push_cstr
    mov rdi, r15
    mov esi, ')'
    call sb_push_byte
5:  mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    # first line, at most 60 bytes
    mov rsi, [r13 + AM_text]
    mov rdx, [r13 + AM_len]
    xor ecx, ecx
6:  cmp rcx, rdx
    jae 7f
    cmp rcx, 60
    jae 7f
    cmp byte ptr [rsi + rcx], 10
    je 7f
    inc rcx
    jmp 6b
7:  mov rdi, r15
    mov rdx, rcx
    call sb_push
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 4b
9:  EPILOGUE

# agents_open(i): open session i (tests / control socket)
FN agents_open
    cmp rdi, [rip + sessions + VEC_len]
    jae 1f
    jmp open_session
1:  ret

FN agents_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call agentext_new_active    # AI (D4): a new session's draft hides the conversation and its card
    test rax, rax
    jnz 4f
    call agents_open_driven     # 1 to 9 pick an option of the open session's card
    test rax, rax
    jz 4f
    mov rbx, rax
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz 4f
    mov rdi, rbx
    mov esi, r13d
    call agentext_card_key
    test eax, eax
    jnz 5f
    mov rdi, rbx
    mov esi, r12d
    call agentext_card_nav      # arrows among its options, Enter on the chosen one
    test eax, eax
    jnz 5f
    cmp r12d, KEY_RETURN        # Enter or Tab goes to its prompt box
    je 6f
    cmp r12d, KEY_TAB
    jne 4f
6:  mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT  # it has a driver: the box is there
    mov dword ptr [rip + g_dirty], 1
    jmp 5f
4:  call agentext_new_active
    test rax, rax
    jz 7f
    cmp r12d, KEY_RETURN        # writing a new session: Enter or Tab goes back to its box
    je 8f
    cmp r12d, KEY_TAB
    je 8f
    cmp r12d, KEY_ESCAPE
    jne 7f
    call agentext_new_leave
5:  mov eax, 1
    EPILOGUE
8:  mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
7:  mov edi, r12d
    call key_list
    EPILOGUE

key_list:
    cmp edi, KEY_ESCAPE
    jne 1f
    cmp qword ptr [rip + view], 0
    jl 2f
    mov qword ptr [rip + view], -1
    jmp 3f
2:  mov dword ptr [rip + g_focus], FOCUS_EDITOR
3:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    ret
1:  xor eax, eax
    ret

# ---------- sessions extensions list (AI, agentext.s) ----------

# FN agents_ext_rows(): the rows extensions list are in the page again: those the project shows, of
#   extensions whose sessions are switched on, sorted in with the others by recency. The open
#   conversation stays open by its object; one whose row went closes.
FN agents_ext_rows
    PROLOGUE 16
    xor ebx, ebx
    mov rax, [rip + view]
    test rax, rax
    js 1f
    cmp rax, [rip + sessions + VEC_len]
    jae 1f
    mov rcx, [rip + sessions + VEC_ptr]
    mov rbx, [rcx + rax*8]
1:  mov [rsp], rbx
    # the extension rows out, the pinned rows after the page aside
    mov qword ptr [rip + ext_pinned + VEC_len], 0
    xor r12d, r12d              # read
    xor r13d, r13d              # write
    xor r14d, r14d              # page rows dropped
2:  cmp r12, [rip + sessions + VEC_len]
    jae 4f
    mov rax, [rip + sessions + VEC_ptr]
    mov r15, [rax + r12*8]
    cmp dword ptr [r15 + AS_kind], AS_KIND_EXT
    jne 3f
    cmp r12, [rip + page_count]
    jae 21f
    inc r14
21: inc r12
    jmp 2b
3:  cmp r12, [rip + page_count]
    jb 31f
    lea rdi, [rip + ext_pinned]
    mov esi, 8
    call vec_push
    mov [rax], r15
    inc r12
    jmp 2b
31: mov rax, [rip + sessions + VEC_ptr]
    mov [rax + r13*8], r15
    inc r12
    inc r13
    jmp 2b
4:  mov [rip + sessions + VEC_len], r13
    sub [rip + page_count], r14
    mov rax, [rip + ext_listed]
    sub [rip + total_count], rax
    mov qword ptr [rip + ext_listed], 0
    # the rows each extension lists, when shown
    xor r12d, r12d
5:  cmp r12, [rip + g_exts + VEC_len]
    jae 7f
    imul rdi, r12, EXT_SIZE
    add rdi, [rip + g_exts + VEC_ptr]
    inc r12
    call ai_ext
    mov r13, rax
    cmp dword ptr [r13 + AX_agents], 0
    je 5b
    cmp dword ptr [r13 + AX_hidden], 0
    jne 5b
    xor r14d, r14d
6:  cmp r14, [r13 + AX_rows + VEC_len]
    jae 5b
    mov rax, [r13 + AX_rows + VEC_ptr]
    mov r15, [rax + r14*8]
    inc r14
    test dword ptr [r15 + AS_xflags], AXF_MATCH
    jz 6b
    lea rdi, [rip + sessions]
    mov esi, 8
    call vec_push
    mov [rax], r15
    inc qword ptr [rip + page_count]
    inc qword ptr [rip + ext_listed]
    jmp 6b
7:  mov rax, [rip + ext_listed]
    add [rip + total_count], rax
    xor r12d, r12d
8:  cmp r12, [rip + ext_pinned + VEC_len]
    jae 9f
    mov rax, [rip + ext_pinned + VEC_ptr]
    mov r15, [rax + r12*8]
    inc r12
    cmp r15, [rsp]
    je 81f
    cmp qword ptr [r15 + AS_live], 0
    je 8b                       # a pinned row stays while it is the open conversation or driven
81:
    lea rdi, [rip + sessions]
    mov esi, 8
    call vec_push
    mov [rax], r15
    jmp 8b
9:  # the open conversation again, by its object
    mov qword ptr [rip + view], -1
    mov rbx, [rsp]
    test rbx, rbx
    jz 12f
    xor ecx, ecx
10: cmp rcx, [rip + sessions + VEC_len]
    jae 12f
    mov rax, [rip + sessions + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 11f
    inc rcx
    jmp 10b
11: mov [rip + view], rcx
12: call sort_sessions
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agents_open_as(AS*): open that session when the page lists it (a new extension session)
FN agents_open_as
    xor eax, eax
1:  cmp rax, [rip + sessions + VEC_len]
    jae 2f
    mov rcx, [rip + sessions + VEC_ptr]
    cmp [rcx + rax*8], rdi
    je 3f
    inc rax
    jmp 1b
3:  mov rdi, rax
    jmp open_session
2:  ret

# FN agents_ext_open() -> rax the extension session the panel shows, or 0
FN agents_ext_open
    xor eax, eax
    mov rcx, [rip + view]
    test rcx, rcx
    js 1f
    cmp rcx, [rip + sessions + VEC_len]
    jae 1f
    mov rdx, [rip + sessions + VEC_ptr]
    mov rdx, [rdx + rcx*8]
    cmp dword ptr [rdx + AS_kind], AS_KIND_EXT
    jne 1f
    mov rax, rdx
1:  ret

# FN agents_ext_is_open(AS*) -> eax 1 when it is the conversation the panel shows
FN agents_ext_is_open
    xor eax, eax
    mov rcx, [rip + view]
    test rcx, rcx
    js 1f
    cmp rcx, [rip + sessions + VEC_len]
    jae 1f
    mov rdx, [rip + sessions + VEC_ptr]
    cmp [rdx + rcx*8], rdi
    jne 1f
    inc eax
1:  ret

# FN agents_open_driven() -> rax the conversation the panel shows when it has a driver (agent_drv.s):
#   the one its prompt box, card, Stop and the headless agent commands act on; or 0
FN agents_open_driven
    xor eax, eax
    mov rcx, [rip + view]
    test rcx, rcx
    js 1f
    cmp rcx, [rip + sessions + VEC_len]
    jae 1f
    mov rdx, [rip + sessions + VEC_ptr]
    mov rdi, [rdx + rcx*8]
    push rdi
    push rdi
    call agent_drv_of
    pop rdi
    pop rdi
    test rax, rax
    jz 1f
    mov rax, rdi
1:  ret

# FN agents_adopt(AS*): a session made here joins the pool and the list (pinned after the page's rows
#   until discovery lists it); it counts as opened and seen
FN agents_adopt
    PROLOGUE
    mov rbx, rdi
    mov dword ptr [rbx + AS_loaded], 1
    mov qword ptr [rbx + AS_seen], 1
    xor ecx, ecx
1:  cmp rcx, [rip + pool + VEC_len]
    jae 2f
    mov rax, [rip + pool + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 3f
    inc rcx
    jmp 1b
2:  lea rdi, [rip + pool]
    mov esi, 8
    call vec_push
    mov [rax], rbx
3:  xor ecx, ecx
4:  cmp rcx, [rip + sessions + VEC_len]
    jae 5f
    mov rax, [rip + sessions + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 9f
    inc rcx
    jmp 4b
5:  lea rdi, [rip + sessions]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# pin_live(): apply_page: the pool's sessions rhun drives that the page lacks go after its rows
pin_live:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + pool + VEC_len]
    jae 9f
    mov rax, [rip + pool + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    cmp qword ptr [r12 + AS_live], 0
    je 1b
    cmp qword ptr [r12 + AS_seen], 0
    jne 1b                      # in the page, or the open one pinned already
    mov qword ptr [r12 + AS_seen], 1
    lea rdi, [rip + sessions]
    mov esi, 8
    call vec_push
    mov [rax], r12
    jmp 1b
9:  EPILOGUE

# FN agents_msg_add(AS*, role, ptr, len, name cstr or 0) -> rax the new message's index, or -1 when
#   nothing was added: a row of a session rhun drives (an empty one stays: streamed text fills it)
FN agents_msg_add
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AS_msgs + VEC_len]
    mov dword ptr [rip + keep_empty], 1
    call add_msg
    mov dword ptr [rip + keep_empty], 0
    call time_ms
    mov [rbx + AS_changed], rax
    mov dword ptr [rip + g_dirty], 1
    mov rax, -1
    cmp [rbx + AS_msgs + VEC_len], r12
    je 9f
    mov rax, r12
9:  EPILOGUE

# FN agents_msg_append(AS*, index, ptr, len): more text for that message (streaming)
FN agents_msg_append
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 9f
    imul r15, r12, AM_SIZE
    add r15, [rbx + AS_msgs + VEC_ptr]
    mov rdi, [r15 + AM_text]
    mov rsi, [r15 + AM_len]
    lea rsi, [rsi + r14 + 1]
    call mem_realloc
    mov [r15 + AM_text], rax
    mov rdi, rax
    add rdi, [r15 + AM_len]
    mov rsi, r13
    mov rdx, r14
    call msg_clean
    add rax, [r15 + AM_len]
    mov [r15 + AM_len], rax
    mov rcx, [r15 + AM_text]
    mov byte ptr [rcx + rax], 0
    mov rdi, rbx
    mov rsi, r12
    call agents_msg_changed
9:  EPILOGUE

# FN agents_msg_set(AS*, index, ptr, len): that message's finished text (trimmed, as a read file shows it)
FN agents_msg_set
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 9f
    mov rdi, r13
    mov rsi, r14
    call trim
    mov r13, rax
    mov r14, rdx
    lea rdi, [r14 + 1]
    call mem_alloc
    mov r15, rax
    mov rdi, rax
    mov rsi, r13
    mov rdx, r14
    call msg_clean
    mov byte ptr [r15 + rax], 0
    mov r13, rax
    imul rcx, r12, AM_SIZE
    add rcx, [rbx + AS_msgs + VEC_ptr]
    mov rdi, [rcx + AM_text]
    mov [rcx + AM_text], r15
    mov [rcx + AM_len], r13
    call mem_free
    mov rdi, rbx
    mov rsi, r12
    call agents_msg_changed
9:  EPILOGUE

# agents_msg_changed(AS*, index): a message's text changed in place: its row is measured again
agents_msg_changed:
    imul rsi, rsi, AM_SIZE
    add rsi, [rdi + AS_msgs + VEC_ptr]
    mov dword ptr [rsi + AM_w], -1
    mov dword ptr [rip + g_dirty], 1
    ret

# msg_clean(dst, src, len) -> rax bytes written to dst (at most len): add_msg's rule: tabs and other
#   controls are spaces, CR goes, an escape sequence shows nothing
msg_clean:
    xor ecx, ecx
    xor eax, eax
1:  cmp rcx, rdx
    jae 9f
    movzx r8d, byte ptr [rsi + rcx]
    inc rcx
    cmp r8d, 10
    je 2f
    cmp r8d, 13
    je 1b
    cmp r8d, 27
    je 3f
    cmp r8d, 32
    jae 2f
    mov r8d, ' '
2:  mov [rdi + rax], r8b
    inc rax
    jmp 1b
3:  cmp rcx, rdx
    jae 1b
    cmp byte ptr [rsi + rcx], '['
    jne 1b
    inc rcx
4:  cmp rcx, rdx
    jae 1b
    movzx r8d, byte ptr [rsi + rcx]
    inc rcx
    sub r8d, 0x40
    cmp r8d, 0x3e
    ja 4b
    jmp 1b
9:  ret

# FN agents_resync(AS*): its rows go and its file is read again from the start (the file is the truth
#   once rhun stops driving it)
FN agents_resync
    PROLOGUE
    mov rbx, rdi
    call session_clear_msgs
    mov qword ptr [rbx + AS_off], 0
    mov qword ptr [rbx + AS_part + SB_len], 0
    mov rdi, rbx
    call session_update
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agents_ext_truncate(AS*, n): the messages from n on go
FN agents_ext_truncate
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 9f
    test r12, r12
    jnz 1f
    mov rdi, rbx
    call session_clear_msgs
    jmp 9f
1:  mov r13, r12
2:  cmp r13, [rbx + AS_msgs + VEC_len]
    jae 3f
    imul r14, r13, AM_SIZE
    add r14, [rbx + AS_msgs + VEC_ptr]
    mov rdi, [r14 + AM_text]
    call mem_free
    mov rdi, [r14 + AM_name]
    call mem_free
    inc r13
    jmp 2b
3:  mov [rbx + AS_msgs + VEC_len], r12
9:  EPILOGUE

# FN agents_ext_msg(AS*, role, ptr, len, label cstr or 0): one message of an extension's session
FN agents_ext_msg
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    # a reply names its model only where it changed, as the built-in sessions do
    cmp r12d, R_ASSIST
    jne 1f
    test r15, r15
    jz 1f
    mov rdi, r15
    mov rsi, [rbx + AS_shown_model]
    test rsi, rsi
    jz 2f
    call strcmp_eq
    test eax, eax
    jz 2f
    xor r15d, r15d
    jmp 1f
2:  mov rdi, r15
    call strlen
    lea rdi, [rbx + AS_shown_model]
    mov rsi, r15
    mov rdx, rax
    call set_str
1:  mov rdi, rbx
    mov esi, r12d
    mov rdx, r13
    mov rcx, r14
    mov r8, r15
    mov dword ptr [rip + keep_empty], 1
    call add_msg
    mov dword ptr [rip + keep_empty], 0
    call time_ms
    mov [rbx + AS_changed], rax
    EPILOGUE

# ext_badge(AS*, x, y) -> right edge: the badge of an extension's session: its icon and the source's
#   name, as agent_badge draws the built-in ones
ext_badge:
    PROLOGUE 16
    mov r12d, esi
    mov r13d, edx
    mov rbx, [rdi + AS_ext]
    mov rdi, rbx
    call agentext_title
    mov r15, rax
    COLOR edi, T_PANEL
    COLOR esi, T_MUTED
    mov edx, 48
    call color_mix
    mov [rsp + 4], eax
    mov rdi, r15
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r15
    mov rdx, rax
    call text_width
    mov r14d, eax
    add r14d, [rip + g_mt + 4*MI_14]
    add r14d, [rip + g_mt + 4*MI_4]
    add r14d, [rip + g_mt + 4*MI_12]
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    M ecx, MI_20
    M r8d, MI_4
    mov r9d, [rsp + 4]
    call gfx_round_rect
    mov edi, r12d
    add edi, [rip + g_mt + 4*MI_3]
    mov esi, r13d
    add esi, [rip + g_mt + 4*MI_3]
    M edx, MI_14
    mov rcx, rbx
    call badge
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_6]
    add esi, [rip + g_mt + 4*MI_14]
    add esi, [rip + g_mt + 4*MI_4]
    mov edx, r13d
    M ecx, MI_20
    mov r8, r15
    COLOR r9d, T_FG
    call ui_text_c
    lea eax, [r12 + r14]
    EPILOGUE

# ---------- drawing ----------

# agent_badge(kind, x, y) -> right edge; 14 px icon and small text in a 20 px badge
agent_badge:
    PROLOGUE 16
    mov r12d, esi
    mov r13d, edx
    lea r15, [rip + .Lclaude_name]
    mov dword ptr [rsp], IC_CLAUDE
    COLOR ebx, T_WARNING
    COLOR eax, T_ACCENT
    cmp ebx, eax
    jne 1f
    COLOR ebx, T_SUCCESS        # some themes share their warning and accent colors
1:
    cmp edi, 2
    jne 3f
    lea r15, [rip + .Lcodex_name]
    mov dword ptr [rsp], IC_OPENAI
    COLOR ebx, T_ACCENT
3:  cmp edi, 3
    jne 4f
    lea r15, [rip + .Lgrok_name]
    mov dword ptr [rsp], IC_GROK
    COLOR ebx, T_FG             # xAI's mark is black and white
4:  cmp edi, 4
    jne 5f
    lea r15, [rip + .Lopencode_name]
    mov dword ptr [rsp], IC_OPENCODE
    COLOR ebx, T_SUCCESS
5:  COLOR edi, T_PANEL
    mov esi, ebx
    mov edx, 48
    call color_mix
    mov [rsp + 4], eax
    COLOR eax, T_FG
    mov [rsp + 8], eax
    mov rdi, r15
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r15
    mov rdx, rax
    call text_width
    mov r14d, eax
    add r14d, [rip + g_mt + 4*MI_14]
    add r14d, [rip + g_mt + 4*MI_4]
    add r14d, [rip + g_mt + 4*MI_12]
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    M ecx, MI_20
    M r8d, MI_4
    mov r9d, [rsp + 4]
    call gfx_round_rect
    mov edi, [rsp]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_6]
    mov edx, r13d
    add edx, [rip + g_mt + 4*MI_3]
    M ecx, MI_14
    mov r8d, [rsp + 8]
    call icon_draw
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_6]
    add esi, [rip + g_mt + 4*MI_14]
    add esi, [rip + g_mt + 4*MI_4]
    mov edx, r13d
    M ecx, MI_20
    mov r8, r15
    mov r9d, [rsp + 8]
    call ui_text_c
    lea eax, [r12 + r14]
    EPILOGUE

# worktree_badge(name, x, y, max_width) -> right edge; fit long checkout names.
worktree_badge:
    PROLOGUE 32
    mov r15, rdi
    mov r12d, esi
    mov r13d, edx
    mov [rsp + 16], ecx
    M eax, MI_40
    cmp ecx, eax
    jl 9f
    COLOR ebx, T_MUTED
    COLOR edi, T_PANEL
    mov esi, ebx
    mov edx, 48
    call color_mix
    mov [rsp], eax
    mov rdi, r15
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r15
    mov rdx, rax
    call text_width
    mov r14d, eax
    add r14d, [rip + g_mt + 4*MI_14]
    add r14d, [rip + g_mt + 4*MI_4]
    add r14d, [rip + g_mt + 4*MI_12]
    cmp r14d, [rsp + 16]
    cmovg r14d, [rsp + 16]
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    M ecx, MI_20
    M r8d, MI_4
    mov r9d, [rsp]
    call gfx_round_rect
    mov edi, IC_BRANCH
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_6]
    mov edx, r13d
    add edx, [rip + g_mt + 4*MI_3]
    M ecx, MI_14
    mov r8d, ebx
    call icon_draw
    mov rdi, r15
    call strlen
    mov r9, rax
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_6]
    add esi, [rip + g_mt + 4*MI_14]
    add esi, [rip + g_mt + 4*MI_4]
    mov edx, r13d
    M ecx, MI_20
    mov r8, r15
    mov r10d, ebx
    mov r11d, r14d
    sub r11d, [rip + g_mt + 4*MI_14]
    sub r11d, [rip + g_mt + 4*MI_4]
    sub r11d, [rip + g_mt + 4*MI_12]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    lea eax, [r12 + r14]
    EPILOGUE
9:  mov eax, r12d
    EPILOGUE

# rel_time(unix seconds) -> cstr in buf ("now", "5m", "3h", "2d"); notes in label_due when it changes
rel_time:
    push rbx
    mov rbx, rdi
    call time_now
    sub rax, rbx
    jns 1f
    xor eax, eax
1:  mov r9, rax                 # the label changes at the next minute under an hour, then hourly, daily
    mov ecx, 60
    cmp rax, 3600
    jb 11f
    mov ecx, 3600
    cmp rax, 86400
    jb 11f
    mov ecx, 86400
11: xor edx, edx
    div rcx
    inc rax
    imul rax, rcx
    add rax, rbx
    cmp rax, [rip + label_due]
    jae 12f
    mov [rip + label_due], rax
12: mov rax, r9
    lea rdi, [rip + buf]
    cmp rax, 60
    jae 2f
    lea rsi, [rip + .Lnow]
    call cstr_copy
    pop rbx
    ret
2:  mov ecx, 'm'
    xor edx, edx
    mov r8d, 60
    div r8
    cmp rax, 60
    jb 3f
    mov ecx, 'h'
    xor edx, edx
    div r8
    cmp rax, 24
    jb 3f
    mov ecx, 'd'
    xor edx, edx
    mov r8d, 24
    div r8
3:  push rcx
    mov rsi, rax
    call fmt_u64
    pop rcx
    mov [rdi], cl
    lea rsi, [rip + .Lago]
    inc rdi
    call cstr_copy
    pop rbx
    ret

# is_live(s) -> 1 if written in the last 20 seconds; notes in label_due when the dot goes out
is_live:
    push rbx
    mov rbx, rdi
    cmp dword ptr [rbx + AS_kind], AS_KIND_EXT
    je 4f
    cmp qword ptr [rbx + AS_live], 0
    je 3f
4:  mov eax, [rbx + AS_state]   # an extension's or a driven session is live while it works or waits
    cmp eax, AGS_WORKING
    je 2f
    cmp eax, AGS_WAITING
    je 2f
3:  call time_now
    sub rax, [rbx + AS_mtime]
    cmp rax, 20
    ja 1f
    mov rax, [rbx + AS_mtime]   # the dot goes out once 20 seconds have passed
    add rax, 21
    cmp rax, [rip + label_due]
    jae 2f
    mov [rip + label_due], rax
2:  mov eax, 1
    pop rbx
    ret
1:  xor eax, eax
    pop rbx
    ret

# wrap(face, text, len, x, y, width, lh, color, draw) -> lines   (args via stack frame struct at rdi)
# rdi -> WR block: face, text, len, x, y, w, lh, color, draw, clip_top, clip_bottom
STRUCT
F WR_face, 8
F WR_text, 8
F WR_len, 8
F WR_x, 4
F WR_y, 4
F WR_w, 4
F WR_lh, 4
F WR_color, 4
F WR_draw, 4
F WR_top, 4
F WR_bot, 4
ENDSTRUCT WR_SIZE

wrap:
    PROLOGUE 48
    mov rbx, rdi
    xor r15d, r15d              # lines
    xor r12d, r12d              # p
.Lwr_line:
    cmp r12, [rbx + WR_len]
    jae .Lwr_done
    mov r13, r12                # line start
    xor r14d, r14d              # width 26.6
    mov qword ptr [rsp], -1     # last break
    mov rax, [rbx + WR_len]
    mov [rsp + 8], rax          # end (default)
    mov [rsp + 16], rax         # next
    mov eax, [rbx + WR_w]
    shl eax, 6
    mov [rsp + 24], eax
.Lwr_ch:
    cmp r12, [rbx + WR_len]
    jae .Lwr_emit
    mov rax, [rbx + WR_text]
    cmp byte ptr [rax + r12], 10
    jne 1f
    mov [rsp + 8], r12
    lea rcx, [r12 + 1]
    mov [rsp + 16], rcx
    jmp .Lwr_emit2
1:  cmp byte ptr [rax + r12], ' '
    jne 2f
    mov [rsp], r12
2:  lea rdi, [rax + r12]
    mov rsi, [rbx + WR_len]
    sub rsi, r12
    call utf8_decode
    mov [rsp + 32], edx
    mov rdi, [rbx + WR_face]
    mov esi, eax
    call face_glyph
    mov eax, [rax + GL_adv]
    lea ecx, [r14 + rax]
    cmp ecx, [rsp + 24]
    jle 4f
    cmp r12, r13
    je 4f
    # break the line
    mov rax, [rsp]
    cmp rax, r13
    jle 3f
    cmp rax, -1
    je 3f
    mov [rsp + 8], rax
    inc rax
    mov [rsp + 16], rax
    jmp .Lwr_emit2
3:  mov [rsp + 8], r12
    mov [rsp + 16], r12
    jmp .Lwr_emit2
4:  mov r14d, ecx
    mov eax, [rsp + 32]
    add r12, rax
    jmp .Lwr_ch
.Lwr_emit:
    mov [rsp + 8], r12
    mov [rsp + 16], r12
.Lwr_emit2:
    cmp dword ptr [rbx + WR_draw], 0
    je 5f
    mov eax, r15d
    imul eax, [rbx + WR_lh]
    add eax, [rbx + WR_y]
    mov ecx, eax
    add ecx, [rbx + WR_lh]
    cmp ecx, [rbx + WR_top]
    jl 5f
    cmp eax, [rbx + WR_bot]
    jg 5f
    mov rdx, [rbx + WR_face]
    add eax, [rdx + FACE_ascent]
    mov edx, eax
    mov rdi, [rbx + WR_face]
    mov esi, [rbx + WR_x]
    mov rcx, [rbx + WR_text]
    add rcx, r13
    mov r8, [rsp + 8]
    sub r8, r13
    mov r9d, [rbx + WR_color]
    call text_draw
5:  inc r15d
    mov r12, [rsp + 16]
    jmp .Lwr_line
.Lwr_done:
    test r15d, r15d
    jnz 6f
    mov r15d, 1
6:  mov eax, r15d
    EPILOGUE

# msg_height(msg, width) -> px (cached)
msg_height:
    PROLOGUE 96
    mov rbx, rdi
    mov r12d, esi
    cmp [rbx + AM_w], r12d
    jne 1f
    mov eax, [rbx + AM_h]
    EPILOGUE
1:  mov [rbx + AM_w], r12d
    mov eax, [rbx + AM_role]
    cmp eax, R_TOOL
    jne 2f
    M eax, MI_32
    jmp 9f
2:  lea rdi, [rsp]
    call wr_setup
    mov dword ptr [rsp + WR_draw], 0
    lea rdi, [rsp]
    call wrap
    imul eax, [rsp + WR_lh]
    mov ecx, [rbx + AM_role]
    cmp ecx, R_RESULT
    jb 3f                       # results, errors and notices are boxed
    add eax, [rip + g_mt + 4*MI_20]
    jmp 9f
3:  add eax, [rip + g_mt + 4*MI_40]
9:  mov [rbx + AM_h], eax
    EPILOGUE

# wr_setup(WR*) using rbx = msg, r12d = width. Measuring (msg_height) and drawing (draw_msg) share it,
# so a message wraps the same in both.
wr_setup:
    mov rax, [rbx + AM_text]
    mov [rdi + WR_text], rax
    mov rax, [rbx + AM_len]
    mov [rdi + WR_len], rax
    mov [rdi + WR_w], r12d
    lea rax, [rip + g_face_ui]
    mov ecx, [rip + g_face_ui + FACE_lineh]
    cmp dword ptr [rbx + AM_role], R_RESULT
    jb 1f                       # results, errors and notices are boxed
    lea rax, [rip + g_face_small]
    mov ecx, [rip + g_face_small + FACE_lineh]
    mov edx, r12d               # a result's box insets its text
    sub edx, [rip + g_mt + 4*MI_16]
    mov [rdi + WR_w], edx
1:  mov [rdi + WR_face], rax
    add ecx, [rip + g_mt + 4*MI_3]
    mov [rdi + WR_lh], ecx
    ret

# agents_draw(x, y, w, h)
FN agents_draw
    PROLOGUE 64
    mov qword ptr [rip + label_due], -1     # the labels drawn below say when they change
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    COLOR r8d, T_PANEL
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    call agentext_new_active    # AI (D4): a new session of an extension is being written
    test rax, rax
    jz 2f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call agentext_new_draw
    jmp 9f
2:  cmp qword ptr [rip + view], 0
    jl 1f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call thread_draw
    jmp 9f
1:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call list_draw
9:  call gfx_clip_pop
    EPILOGUE

list_draw:
    PROLOGUE 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    # header
    M r15d, MI_40
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    mov ecx, r15d
    lea r8, [rip + .Lheader]
    COLOR r9d, T_MUTED
    call ui_text_c
    M r12d, MI_28
    mov edi, ID_AG_REFRESH
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, r12d
    sub esi, [rip + g_mt + 4*MI_8]
    mov edx, r15d
    sub edx, r12d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_REFRESH
    call ui_icon_btn
    test eax, UB_CLICK
    jz 1f
    call agents_scan
1:  mov edi, [rsp]              # AI (D4): "+ TITLE" for extensions whose sessions take prompts
    add edi, [rsp + 8]
    sub edi, r12d
    sub edi, [rip + g_mt + 4*MI_12]
    mov esi, r15d
    sub esi, r12d
    sar esi, 1
    add esi, [rsp + 4]
    mov edx, r12d
    call agentext_list_buttons
    cmp qword ptr [rip + page_count], 0
    jne 2f
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    add edx, r15d
    M ecx, MI_24
    lea r8, [rip + .Lnone]
    cmp dword ptr [rip + opencode_status], 1
    jne 112f
    lea r8, [rip + .Loc_missing]
112: cmp dword ptr [rip + opencode_status], 2
    jne 113f
    lea r8, [rip + .Loc_failed]
113: cmp dword ptr [rip + index_error], 0
    je 110f
    lea r8, [rip + .Lfailed]
110: call index_loading          # a run asked for shows as loading, also a retry after a failure,
    test eax, eax               # as the footer does
    jz 111f
    lea r8, [rip + .Lloading]
111:
    cmp qword ptr [rip + g_project], 0
    jne 11f
    lea r8, [rip + .Lnoproj]
11: COLOR r9d, T_MUTED
    call ui_text_c
    jmp .Lld_ret
2:  mov eax, [rsp + 4]
    add eax, r15d
    mov [rsp + 16], eax         # list y
    mov eax, [rsp + 12]
    sub eax, r15d
    sub eax, [rip + g_mt + 4*MI_40]
    mov [rsp + 20], eax         # list h
    mov edi, [rsp]
    mov esi, [rsp + 16]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 20]
    call ui_in
    test eax, eax
    jz 3f
    mov eax, [rip + g_scroll_y]
    add [rip + list_scroll], eax
3:  M ebx, MI_48
    add ebx, [rip + g_mt + 4*MI_8]      # row h
    mov rax, [rip + page_count]
    imul eax, ebx
    sub eax, [rsp + 20]
    jns 31f
    xor eax, eax
31: cmp [rip + list_scroll], eax
    jle 32f
    mov [rip + list_scroll], eax
32: cmp dword ptr [rip + list_scroll], 0
    jge 33f
    mov dword ptr [rip + list_scroll], 0
33: mov edi, [rsp]
    mov esi, [rsp + 16]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 20]
    call gfx_clip_push
    xor r12d, r12d
    mov r13d, [rsp + 16]
    sub r13d, [rip + list_scroll]
.Lld_row:
    cmp r12, [rip + page_count]
    jae .Lld_rows_done
    mov eax, [rsp + 16]
    add eax, [rsp + 20]
    cmp r13d, eax
    jge .Lld_rows_done
    mov eax, r13d
    add eax, ebx
    cmp eax, [rsp + 16]
    jl .Lld_next
    mov rax, [rip + sessions + VEC_ptr]
    mov r14, [rax + r12*8]
    lea edi, [r12 + ID_AG_ROW]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 8]
    mov r8d, ebx
    call ui_btn
    mov [rsp + 24], eax
    test eax, UB_HOVER
    jz 4f
    M eax, MI_6
    mov edi, [rsp]
    add edi, eax
    mov esi, r13d
    add esi, [rip + g_mt + 4*MI_2]
    mov edx, [rsp + 8]
    sub edx, eax
    sub edx, eax
    mov ecx, ebx
    sub ecx, [rip + g_mt + 4*MI_4]
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
4:  # status dot
    M ecx, MI_8
    mov edi, [rsp]
    add edi, [rip + g_mt + 4*MI_16]
    mov esi, r13d
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_BORDER
    push rdi
    push rsi
    mov rdi, r14
    call is_live
    pop rsi
    pop rdi
    test eax, eax
    jz 5f
    COLOR r9d, T_SUCCESS
5:  mov ecx, edx
    call gfx_round_rect
    # title
    mov r8, [r14 + AS_title]
    test r8, r8
    jnz 6f
    lea r8, [rip + .Luntitled]
6:  mov [rsp + 32], r8
    mov rdi, r8
    call strlen
    mov r9, rax
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_32]
    mov edx, r13d
    add edx, [rip + g_mt + 4*MI_6]
    M ecx, MI_24
    mov r8, [rsp + 32]
    COLOR r10d, T_FG
    mov r11d, [rsp + 8]
    sub r11d, [rip + g_mt + 4*MI_48]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    # meta line: provider badge, worktree badge, then time and activity
    mov edi, [r14 + AS_kind]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_32]
    mov edx, r13d
    add edx, [rip + g_mt + 4*MI_28]
    cmp edi, AS_KIND_EXT
    jne 61f
    mov rdi, r14                # an extension's session: its badge (AI, agentext.s)
    call ext_badge
    jmp 62f
61: call agent_badge
62: mov [rsp + 40], eax
    mov rdi, [r14 + AS_worktree]
    test rdi, rdi
    jz 7f
    mov esi, eax
    add esi, [rip + g_mt + 4*MI_6]
    mov edx, r13d
    add edx, [rip + g_mt + 4*MI_28]
    mov ecx, [rsp]
    add ecx, [rsp + 8]
    sub ecx, esi
    sub ecx, [rip + g_mt + 4*MI_16]
    mov [rsp + 48], esi
    call worktree_badge
    mov [rsp + 40], eax
    # A narrow panel can shorten the badge; hovering it reveals the complete name.
    mov edi, [rsp + 48]
    mov esi, r13d
    add esi, [rip + g_mt + 4*MI_28]
    mov edx, eax
    sub edx, edi
    M ecx, MI_20
    call ui_in
    test eax, eax
    jz 7f
    lea edi, [r12 + ID_AG_ROW]
    mov esi, [rsp + 48]
    mov edx, r13d
    add edx, [rip + g_mt + 4*MI_48]
    mov ecx, [rsp + 40]
    sub ecx, esi
    mov r8d, UB_HOVER
    mov r9, [r14 + AS_worktree]
    call tip_note_text
7:  mov dword ptr [rsp + 52], 1   # with the model
71: lea rdi, [rip + tmp]
    call sb_clear
    cmp dword ptr [rsp + 52], 0
    je 72f
    mov rsi, [r14 + AS_model]
    test rsi, rsi
    jz 72f
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [r14 + AS_model]
    call sb_push_cstr
72: lea rdi, [rip + tmp]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    mov rdi, [r14 + AS_mtime]
    call rel_time
    lea rdi, [rip + tmp]
    lea rsi, [rip + buf]
    call sb_push_cstr
    cmp dword ptr [r14 + AS_kind], AS_KIND_EXT
    je 74f
    cmp qword ptr [r14 + AS_live], 0
    je 73f
74: mov eax, [r14 + AS_state]   # an extension's or a driven session says what it does
    test eax, eax
    jz 8f
    lea rcx, [rip + ext_state_labels]
    lea rdi, [rip + tmp]
    mov rsi, [rcx + rax*8]
    call sb_push_cstr
    jmp 8f
73: mov rdi, r14
    call is_live
    test eax, eax
    jz 8f
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Llive]
    call sb_push_cstr
8:  lea rdi, [rip + g_face_small]
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    call text_width
    mov ecx, [rsp]
    add ecx, [rsp + 8]
    sub ecx, [rsp + 40]
    sub ecx, [rip + g_mt + 4*MI_16]
    cmp eax, ecx
    jle 81f
    cmp dword ptr [rsp + 52], 0
    je 82f
    cmp qword ptr [r14 + AS_model], 0
    je 82f
    mov dword ptr [rsp + 52], 0  # a narrow panel keeps the age rather than the model
    jmp 71b
82: cmp qword ptr [r14 + AS_worktree], 0
    jne .Lld_meta_done          # keep the worktree name visible without partial age text
81: lea rdi, [rip + g_face_small]
    mov esi, [rsp + 40]
    mov edx, r13d
    add edx, [rip + g_mt + 4*MI_28]
    M ecx, MI_20
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR r10d, T_MUTED
    mov r11d, [rsp]
    add r11d, [rsp + 8]
    sub r11d, esi
    sub r11d, [rip + g_mt + 4*MI_16]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
.Lld_meta_done:
    test dword ptr [rsp + 24], UB_CLICK
    jz .Lld_next
    mov rdi, r12
    call open_session
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
.Lld_next:
    add r13d, ebx
    inc r12
    jmp .Lld_row
.Lld_rows_done:
    call gfx_clip_pop
.Lld_ret:
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rsp + 12]
    sub esi, [rip + g_mt + 4*MI_40]
    mov edx, [rsp + 8]
    call page_footer
    EPILOGUE

thread_draw:
    PROLOGUE 176
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov rax, [rip + view]
    mov rcx, [rip + sessions + VEC_ptr]
    mov rbx, [rcx + rax*8]      # session
    # header: back + title
    M r15d, MI_40
    M r12d, MI_28
    mov edi, ID_AG_BACK
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, r15d
    sub edx, r12d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_BACK
    call ui_icon_btn
    test eax, UB_CLICK
    jz 1f
    mov qword ptr [rip + view], -1
    call agentext_new_leave     # AI (D4): the prompt box's focus goes back to the panel
    mov dword ptr [rip + g_dirty], 1
    jmp .Ltd_ret
1:  mov r8, [rbx + AS_title]
    test r8, r8
    jnz 2f
    lea r8, [rip + .Luntitled]
2:  mov [rsp + 16], r8
    mov rdi, r8
    call strlen
    mov r9, rax
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_40]
    mov edx, [rsp + 4]
    mov ecx, r15d
    mov r8, [rsp + 16]
    COLOR r10d, T_FG
    mov r11d, [rsp + 8]
    sub r11d, [rip + g_mt + 4*MI_64]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    mov rdi, rbx
    call is_live
    test eax, eax
    jz 3f
    M ecx, MI_8
    mov edi, [rsp]
    add edi, [rsp + 8]
    sub edi, [rip + g_mt + 4*MI_16]
    mov esi, r15d
    sub esi, ecx
    sar esi, 1
    add esi, [rsp + 4]
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_SUCCESS
    call gfx_round_rect
3:  mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, r15d
    dec esi
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    # message area
    mov eax, [rsp + 4]
    add eax, r15d
    mov [rsp + 20], eax         # area y
    mov eax, [rsp + 12]
    sub eax, r15d
    mov [rsp + 24], eax         # area h
    mov dword ptr [rsp + 160], 0
    cmp dword ptr [rbx + AS_kind], AS_KIND_EXT
    je 44f
    mov rdi, rbx                # a session with a driver too (agent_drv.s)
    call agent_drv_of
    test rax, rax
    jz 41f
44: mov rdi, rbx                # AI (D4): its card and prompt box go under the messages
    mov esi, [rsp + 8]
    call agentext_bottom_h
    mov ecx, [rsp + 24]
    shr ecx, 1
    cmp eax, ecx
    jbe 42f
    mov eax, ecx                # at most half the panel
42: mov [rsp + 160], eax
    sub [rsp + 24], eax
41: M eax, MI_16
    mov [rsp + 28], eax         # pad
    mov eax, [rsp + 8]
    sub eax, [rsp + 28]
    sub eax, [rsp + 28]
    sub eax, [rip + g_mt + 4*MI_24]
    mov [rsp + 32], eax         # text width
    # total height
    xor r13d, r13d
    xor r12d, r12d
4:  cmp r12, [rbx + AS_msgs + VEC_len]
    jae 5f
    imul rdi, r12, AM_SIZE
    add rdi, [rbx + AS_msgs + VEC_ptr]
    mov esi, [rsp + 32]
    call msg_height
    add r13d, eax
    add r13d, [rip + g_mt + 4*MI_8]
    inc r12
    jmp 4b
5:  add r13d, [rip + g_mt + 4*MI_32]
    mov [rip + th_content], r13d
    # scrolling / follow
    mov edi, [rsp]
    mov esi, [rsp + 20]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 24]
    call ui_in
    test eax, eax
    jz 6f
    mov eax, [rip + g_scroll_y]
    test eax, eax
    jz 6f
    add [rip + th_scroll], eax
    mov dword ptr [rip + th_follow], 0
6:  mov eax, r13d
    sub eax, [rsp + 24]
    jns 61f
    xor eax, eax
61: mov [rsp + 36], eax         # max scroll
    cmp dword ptr [rip + th_follow], 0
    je 62f
    mov [rip + th_scroll], eax
62: cmp [rip + th_scroll], eax
    jl 63f
    mov [rip + th_scroll], eax
    mov dword ptr [rip + th_follow], 1
63: cmp dword ptr [rip + th_scroll], 0
    jge 64f
    mov dword ptr [rip + th_scroll], 0
64: mov edi, [rsp]
    mov esi, [rsp + 20]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 24]
    call gfx_clip_push
    cmp qword ptr [rbx + AS_msgs + VEC_len], 0
    jne 65f
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rsp + 28]
    mov edx, [rsp + 20]
    add edx, [rip + g_mt + 4*MI_8]
    M ecx, MI_24
    lea r8, [rip + .Lempty_thread]
    COLOR r9d, T_MUTED
    call ui_text_c
65: # messages
    mov r13d, [rsp + 20]
    add r13d, [rip + g_mt + 4*MI_12]
    sub r13d, [rip + th_scroll]
    xor r12d, r12d
.Ltd_msg:
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae .Ltd_msgs_done
    mov eax, [rsp + 20]
    add eax, [rsp + 24]
    cmp r13d, eax
    jge .Ltd_msgs_done
    imul r14, r12, AM_SIZE
    add r14, [rbx + AS_msgs + VEC_ptr]
    mov rdi, r14
    mov esi, [rsp + 32]
    call msg_height
    mov r15d, eax
    mov eax, r13d
    add eax, r15d
    cmp eax, [rsp + 20]
    jl .Ltd_next
    mov rdi, r14
    mov esi, r13d
    mov edx, r15d
    lea rcx, [rsp]
    call draw_msg
.Ltd_next:
    add r13d, r15d
    add r13d, [rip + g_mt + 4*MI_8]
    inc r12
    jmp .Ltd_msg
.Ltd_msgs_done:
    call gfx_clip_pop
    mov r8d, [rsp + 160]
    test r8d, r8d
    jz 43f
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 20]
    add edx, [rsp + 24]
    mov ecx, [rsp + 8]
    call agentext_bottom_draw
    cmp qword ptr [rip + view], 0
    jl .Ltd_ret
43:
    # scrollbar
    mov eax, [rsp + 24]
    push rax
    mov eax, [rip + th_content]
    push rax
    mov edi, ID_AG_TSCROLL
    mov esi, [rsp + 16]
    add esi, [rsp + 16 + 8]
    M eax, MI_12
    sub esi, eax
    mov edx, [rsp + 16 + 20]
    mov ecx, eax
    mov r8d, [rsp + 16 + 24]
    lea r9, [rip + th_scroll]
    call ui_scrollbar
    add rsp, 16
    cmp dword ptr [rip + g_active], ID_AG_TSCROLL
    jne 7f
    mov dword ptr [rip + th_follow], 0
    mov eax, [rip + th_scroll]
    cmp eax, [rsp + 36]
    jl 7f
    mov dword ptr [rip + th_follow], 1
7:  # jump-to-latest button when not following
    cmp dword ptr [rip + th_follow], 0
    jne .Ltd_ret
    M r12d, MI_32
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, r12d
    sub esi, [rip + g_mt + 4*MI_20]
    mov edx, [rsp + 20]
    add edx, [rsp + 24]
    sub edx, r12d
    sub edx, [rip + g_mt + 4*MI_16]
    mov [rsp + 40], esi
    mov [rsp + 44], edx
    mov edi, esi
    mov esi, edx
    mov edx, r12d
    mov ecx, r12d
    call ui_card
    mov edi, ID_AG_FOLLOW
    mov esi, [rsp + 40]
    mov edx, [rsp + 44]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_ARROW_DN
    call ui_icon_btn
    test eax, UB_CLICK
    jz .Ltd_ret
    mov dword ptr [rip + th_follow], 1
    mov dword ptr [rip + g_dirty], 1
.Ltd_ret:
    EPILOGUE

# draw_msg(msg, y, h, frame*) ; frame: x at [0], w at [8], pad [28], text width [32]
draw_msg:
    PROLOGUE 112
    mov rbx, rdi
    mov r12d, esi               # y
    mov r13d, edx               # h
    mov r14, rcx                # frame
    mov r15d, [r14]
    add r15d, [r14 + 28]        # left
    mov eax, [rbx + AM_role]
    cmp eax, R_TOOL
    je .Ldm_tool
    cmp eax, R_RESULT
    jae .Ldm_result
    # user / assistant: label line + wrapped text
    cmp eax, R_USER
    jne 1f
    # user bubble
    mov edi, r15d
    sub edi, [rip + g_mt + 4*MI_8]
    mov esi, r12d
    mov edx, [r14 + 32]
    add edx, [rip + g_mt + 4*MI_16]
    mov ecx, r13d
    sub ecx, [rip + g_mt + 4*MI_4]
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
    lea r8, [rip + .Lyou]
    COLOR r9d, T_MUTED
    jmp 2f
1:  lea r8, [rip + .Lagent]
    COLOR r9d, T_ACCENT
2:  lea rdi, [rip + g_face_small]
    mov esi, r15d
    mov edx, r12d
    add edx, [rip + g_mt + 4*MI_4]
    M ecx, MI_20
    call ui_text_c
    # the model of the replies from here on, where it changed
    cmp dword ptr [rbx + AM_role], R_ASSIST
    jne 3f
    mov rdi, [rbx + AM_name]
    test rdi, rdi
    jz 3f
    mov [rsp + 96], eax
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rbx + AM_name]
    call sb_push_cstr
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 96]
    mov edx, r12d
    add edx, [rip + g_mt + 4*MI_4]
    M ecx, MI_20
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR r10d, T_MUTED
    mov r11d, [r14]
    add r11d, [r14 + 8]
    sub r11d, esi
    sub r11d, [rip + g_mt + 4*MI_24]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
3:  lea rdi, [rsp]
    push r12
    push r12
    mov r12d, [r14 + 32]
    call wr_setup
    pop r12
    pop r12
    mov [rsp + WR_x], r15d
    mov eax, r12d
    add eax, [rip + g_mt + 4*MI_28]
    mov [rsp + WR_y], eax
    COLOR eax, T_FG
    mov [rsp + WR_color], eax
    mov dword ptr [rsp + WR_draw], 1
    mov eax, [rip + g_cv + CV_cy0]
    mov [rsp + WR_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rsp + WR_bot], eax
    lea rdi, [rsp]
    call wrap
    EPILOGUE
.Ldm_tool:
    M ecx, MI_16
    mov edi, IC_TERMINAL
    mov esi, r15d
    mov edx, r13d
    sub edx, ecx
    sar edx, 1
    add edx, r12d
    COLOR r8d, T_MUTED
    call icon_draw
    mov r8, [rbx + AM_name]
    test r8, r8
    jz 3f
    lea rdi, [rip + g_face_small]
    mov esi, r15d
    add esi, [rip + g_mt + 4*MI_24]
    mov edx, r12d
    mov ecx, r13d
    COLOR r9d, T_FG
    call ui_text_c
    mov [rsp + 96], eax
    jmp 4f
3:  mov eax, r15d
    add eax, [rip + g_mt + 4*MI_24]
    mov [rsp + 96], eax
4:  mov r9, [rbx + AM_len]
    test r9, r9
    jz 5f
    # first line of the summary
    mov rax, [rbx + AM_text]
    xor ecx, ecx
41: cmp rcx, r9
    jae 42f
    cmp byte ptr [rax + rcx], 10
    je 42f
    inc rcx
    jmp 41b
42: mov r9, rcx
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 96]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, r12d
    mov ecx, r13d
    mov r8, [rbx + AM_text]
    COLOR r10d, T_MUTED
    mov r11d, [r14]
    add r11d, [r14 + 8]
    sub r11d, esi
    sub r11d, [rip + g_mt + 4*MI_24]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
5:  EPILOGUE
.Ldm_result:
    mov edi, r15d
    mov esi, r12d
    mov edx, [r14 + 32]
    mov ecx, r13d
    sub ecx, [rip + g_mt + 4*MI_8]
    M r8d, MI_4
    COLOR r9d, T_BG
    call gfx_round_rect
    mov edi, r15d
    mov esi, r12d
    M edx, MI_2
    mov ecx, r13d
    sub ecx, [rip + g_mt + 4*MI_8]
    COLOR r8d, T_BORDER
    cmp dword ptr [rbx + AM_role], R_ERROR
    jne 1f
    COLOR r8d, T_ERROR          # an extension session's error and notice (AI)
1:  cmp dword ptr [rbx + AM_role], R_INFO
    jne 2f
    COLOR r8d, T_ACCENT
2:  call gfx_fill
    lea rdi, [rsp]
    push r12
    push r12
    mov r12d, [r14 + 32]
    call wr_setup
    pop r12
    pop r12
    mov eax, r15d
    add eax, [rip + g_mt + 4*MI_10]
    mov [rsp + WR_x], eax
    mov eax, r12d
    add eax, [rip + g_mt + 4*MI_6]
    mov [rsp + WR_y], eax
    COLOR eax, T_MUTED
    mov [rsp + WR_color], eax
    mov dword ptr [rsp + WR_draw], 1
    mov eax, [rip + g_cv + CV_cy0]
    mov [rsp + WR_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rsp + WR_bot], eax
    lea rdi, [rsp]
    call wrap
    EPILOGUE

.section .rodata
.Lr0: .asciz "?"
.Lr1: .asciz "user"
.Lr2: .asciz "agent"
.Lr3: .asciz "tool"
.Lr4: .asciz "result"
.Lr5: .asciz "error"
.Lr6: .asciz "info"
.Lst_working: .asciz "  \302\267  working"
.Lst_waiting: .asciz "  \302\267  waiting for you"
.Lst_error: .asciz "  \302\267  error"
.p2align 3
role_names: .quad .Lr0, .Lr1, .Lr2, .Lr3, .Lr4, .Lr5, .Lr6
ext_state_labels: .quad .Lr0, .Lst_working, .Lst_waiting, .Lst_error
.Lheader: .asciz "AGENTS"
.Lnone: .asciz "No agent sessions for this project yet"
.Loc_missing: .asciz "OpenCode: install the CLI, then refresh"
.Loc_failed: .asciz "OpenCode: check CLI and data access"
.Lnoproj: .asciz "Open a folder to see its agent sessions"
.Luntitled: .asciz "Untitled session"
.Lempty_thread: .asciz "Nothing here yet"
.Lclaude_name: .asciz "Claude"
.Lcodex_name: .asciz "Codex"
.Lgrok_name: .asciz "Grok"
.Lopencode_name: .asciz "OpenCode"
.Lat_self: .asciz "@self"
.Lworktree_dump: .asciz " [worktree: "
.Lmodel_dump: .asciz " [model: "
.Lmsg_obj: .ascii "\"message\":{"
.Ltc_type: .ascii "\"type\":\"turn_context\""
.Lkey_model: .ascii "\"model\":\""
.Lmodel: .asciz "model"
.Lturn_context: .asciz "turn_context"
.Lcurrent_model_id: .asciz "current_model_id"
.Lgk_meta: .asciz "_meta"
.Lgk_model: .asciz "modelId"
.Ldot: .asciz "  \302\267  "
.Llive: .asciz "  \302\267  live"
.Lnow: .asciz "just now"
.Lago: .asciz " ago"
.Lyou: .asciz "You"
.Lagent: .asciz "Agent"
.Lempty: .asciz ""
.Ltool: .asciz "tool"
.Loc_part: .asciz "part"
.Loc_title: .asciz "title"
.Loc_state: .asciz "state"
.Loc_error: .asciz "error"
.Loc_ignored: .asciz "ignored"
.Loc_synthetic: .asciz "synthetic"
.Loc_updated: .asciz "updated"
.Ltype: .asciz "type"
.Ltext: .asciz "text"
.Luser: .asciz "user"
.Lassistant: .asciz "assistant"
.Lmessage: .asciz "message"
.Lcontent: .asciz "content"
.Lcustom_title: .asciz "custom-title"
.LcustomTitle: .asciz "customTitle"
.LisMeta: .asciz "isMeta"
.Ltool_result: .asciz "tool_result"
.Ltool_use: .asciz "tool_use"
.Lname: .asciz "name"
.Linput: .asciz "input"
.Lpayload: .asciz "payload"
.Lrole: .asciz "role"
.Lfunction_call: .asciz "function_call"
.Lcustom_tool_call: .asciz "custom_tool_call"
.Lfunction_call_output: .asciz "function_call_output"
.Lcustom_tool_call_output: .asciz "custom_tool_call_output"
.Larguments: .asciz "arguments"
.Loutput: .asciz "output"
.Ls_command: .asciz "command"
.Ls_file_path: .asciz "file_path"
.Ls_filePath: .asciz "filePath"
.Ls_path: .asciz "path"
.Ls_pattern: .asciz "pattern"
.Ls_url: .asciz "url"
.Ls_description: .asciz "description"
.Ls_prompt: .asciz "prompt"
.Ls_query: .asciz "query"
.Ls_target_file: .asciz "target_file"
.Ls_target_directory: .asciz "target_directory"
.Lparams: .asciz "params"
.Lupdate: .asciz "update"
.Lsession_update: .asciz "sessionUpdate"
.Lgk_user: .asciz "user_message_chunk"
.Lgk_agent: .asciz "agent_message_chunk"
.Lgk_tool: .asciz "tool_call"
.Lgk_tool_update: .asciz "tool_call_update"
.Ltitle: .asciz "title"
.Lraw_input: .asciz "rawInput"
.Lstatus: .asciz "status"
.Lgk_completed: .asciz "completed"
.Lgk_failed: .asciz "failed"
.Lnew_text: .asciz "newText"
.Lgenerated_title: .asciz "generated_title"
.Lgrok_summary: .asciz "/summary.json"
.p2align 3
summary_keys:
    .quad .Ls_command, .Ls_filePath, .Ls_file_path, .Ls_target_file, .Ls_path, .Ls_target_directory, .Ls_pattern
    .quad .Ls_url, .Ls_description, .Ls_prompt, .Ls_query, .Lname, 0

.data
view: .quad -1
th_follow: .long 1

.section .rodata
.Lindex_arg: .asciz "--agent-index"
.Lworktrees_entry: .asciz "worktrees"
.Lgitdir_entry: .asciz "gitdir"
.Ljsonl_entry: .ascii ".jsonl"

.section .rodata
.Lpage_shown: .asciz "shown="
.Lpage_total: .asciz " total="
.Lpage_loading: .asciz " loading="
.Lpage_error: .asciz " error="
.Lpage_runs: .asciz "runs="

.section .rodata
.Lloading: .asciz "Loading sessions..."
.Lfailed: .asciz "Could not refresh. Try again."
.Lload_more: .asciz "Load more"
.Lrefreshing: .asciz "Loading..."
.Lfooter_error: .asciz "Retry refresh"
.Lfooter_of: .asciz " of "
.text

# Fixed footer: count at left, Load more (or retry) at right.
page_footer:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    M eax, MI_40
    mov [rsp + 12], eax
    mov ecx, [rip + g_mt + 4*MI_1]
    COLOR r8d, T_BORDER
    call gfx_fill
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rip + page_count]
    call sb_push_u64
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lfooter_of]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rip + total_count]
    call sb_push_u64
    mov eax, [rsp + 8]
    sub eax, [rip + g_mt + 4*MI_16]
    mov [rsp + 16], eax
    mov rax, [rip + page_count]
    cmp rax, [rip + total_count]
    jb 1f
    call index_loading
    test eax, eax
    jnz 1f
    cmp dword ptr [rip + index_error], 0
    je 5f
1:  M eax, MI_48
    add eax, eax
    add eax, [rip + g_mt + 4*MI_8]
    mov [rsp + 20], eax
    sub [rsp + 16], eax
    mov edi, ID_AG_MORE
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, eax
    sub esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 4]
    mov ecx, eax
    mov r8d, [rsp + 12]
    call ui_btn
    mov [rsp + 24], eax
    call index_loading
    test eax, eax
    jnz 3f
    mov eax, [rsp + 24]
    test eax, UB_CLICK
    jz 3f
    cmp dword ptr [rip + index_error], 0
    je 2f
    call agents_scan
    jmp 3f
2:  call agents_more
3:  lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 20]
    sub esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 20]
    mov r8d, [rsp + 12]
    lea r9, [rip + .Lload_more]
    cmp dword ptr [rip + index_error], 0
    je 4f
    lea r9, [rip + .Lfooter_error]
4:  call index_loading
    test eax, eax
    jz 41f
    lea r9, [rip + .Lrefreshing]
    COLOR eax, T_MUTED
    jmp 42f
41: COLOR eax, T_ACCENT
42: push rax
    push rax
    call ui_text_center
    add rsp, 16
5:  cmp dword ptr [rip + opencode_status], 0
    je 51f
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Loc_failed]
    cmp dword ptr [rip + opencode_status], 1
    jne 52f
    lea rsi, [rip + .Loc_missing]
52: call sb_push_cstr
51: lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR eax, T_MUTED
    mov r10d, [rsp + 16]
    sub r10d, [rip + g_mt + 4*MI_16]
    push r10
    push rax
    call ui_text_v_fit
    add rsp, 16
    EPILOGUE

# Recent title records can sit at the end of a long session. Read a bounded tail,
# with one preceding byte so a record starting exactly at the boundary is kept.
FN agent_session_tail_title
    PROLOGUE 32
    mov dword ptr [rsp + 16], 0
    mov qword ptr [rsp + 24], 0
    mov dword ptr [rip + model_noted], 0
    mov rbx, rdi
    mov rdi, [rbx + AS_path]
    call file_open_read
    test rax, rax
    js 9f
    mov r12d, eax
    mov edi, eax
    call file_size
    test rax, rax
    js 8f
    cmp rax, 262144
    jbe 81f
    sub rax, 262145
    mov [rsp + 8], rax
    mov edi, r12d
    mov rsi, rax
    xor edx, edx
    SYS SYS_lseek
    test rax, rax
    js 8f
    mov edi, 262146
    call mem_alloc
    mov r13, rax
    xor r14d, r14d
1:  mov edi, r12d
    lea rsi, [r13 + r14]
    mov edx, 262145
    sub rdx, r14
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    test rax, rax
    js 7f
    jz 2f
    add r14, rax
    cmp r14, 262145
    jb 1b
2:  mov dword ptr [rsp + 16], 1
    xor r15d, r15d
    cmp qword ptr [rsp + 8], 0
    je 4f
3:  cmp r15, r14
    jae 7f
    mov al, [r13 + r15]
    inc r15
    cmp al, 10
    jne 3b
    mov [rsp + 24], r15         # the window's first complete line
4:  cmp r15, r14
    jae 7f
    mov rax, r15
5:  cmp rax, r14
    jae 7f
    cmp byte ptr [r13 + rax], 10
    je 6f
    inc rax
    jmp 5b
6:  mov [rsp], rax
    mov rcx, [rsp + 8]
    add rcx, rax
    cmp rcx, [rbx + AS_title_off]
    jb 61f
    inc rcx
    mov [rbx + AS_record_off], rcx
    mov rdi, rbx
    lea rsi, [r13 + r15]
    mov rdx, rax
    sub rdx, r15
    xor ecx, ecx
    call ingest_line
61: mov r15, [rsp]
    inc r15
    jmp 4b
    # A long Claude Code or Codex log whose last window names no model (a turn of long output): the
    # latest model is in an earlier line, back to the bytes an earlier read covered (none on a first).
7:  cmp dword ptr [rip + model_noted], 0
    jne 71f
    cmp dword ptr [rbx + AS_kind], 2
    ja 71f
    mov rdx, [rsp + 24]         # from the window's first complete line, or its start inside a longer one
    add rdx, [rsp + 8]
    jz 71f
    mov rdi, rbx
    mov esi, r12d
    mov rcx, r13
    mov r8, [rbx + AS_title_off]
    call model_before
71: mov rdi, r13
    call mem_free
    jmp 8f
81: mov dword ptr [rsp + 16], 1
8:  mov edi, r12d
    SYS SYS_close
9:  mov eax, [rsp + 16]
    EPILOGUE

# model_before(s, fd, end, buffer of 262146 bytes, floor): the latest line between floor and end that
#   names a model, read back a window at a time, at most 32 windows
model_before:
    PROLOGUE 48
    mov rbx, rdi
    mov r12d, esi
    mov [rsp], rdx              # the bytes from here on are read
    mov r13, rcx
    mov dword ptr [rsp + 8], 32
    xor eax, eax
    test r8, r8
    jz 10f
    lea rax, [r8 - 1]           # with the byte before floor: a newline there starts a line at floor
10: mov [rsp + 32], rax
1:  mov rax, [rsp]
    cmp rax, [rsp + 32]
    jbe 9f
    dec dword ptr [rsp + 8]
    js 9f
    sub rax, 262144
    jb 11f
    cmp rax, [rsp + 32]
    jae 12f
11: mov rax, [rsp + 32]
12: mov [rsp + 16], rax         # this window's start
    mov edi, r12d
    mov rsi, rax
    xor edx, edx
    SYS SYS_lseek
    test rax, rax
    js 9f
    mov r14, [rsp]
    sub r14, [rsp + 16]
    xor r15d, r15d
2:  mov edi, r12d
    lea rsi, [r13 + r15]
    mov rdx, r14
    sub rdx, r15
    SYS SYS_read
    cmp rax, -EINTR
    je 2b
    test rax, rax
    jle 9f
    add r15, rax
    cmp r15, r14
    jb 2b
    # its lines from the last; it ends where a line begins
    mov r15, r14
3:  test r15, r15
    jz 6f
    lea rax, [r15 - 1]          # the newline that ends this line
    mov rcx, rax
4:  test rcx, rcx
    jz 5f
    cmp byte ptr [r13 + rcx - 1], 10
    je 5f
    dec rcx
    jmp 4b
5:  test rcx, rcx
    jnz 51f
    mov rax, [rsp + 16]
    test rax, rax
    jz 51f
    cmp rax, [rsp + 32]
    jne 6f                      # it may begin before the window: the next one reads it
    mov rdi, rbx                # at the floor, a line an earlier read ended inside of (it was being
    mov esi, r12d               # written): its beginning, before the floor
    mov rdx, rax
    call line_prefix
    jmp 9f
51: mov [rsp + 24], rcx
    mov rdi, rbx
    lea rsi, [r13 + rcx]
    mov rdx, rax
    sub rdx, rcx
    cmp r15, r14
    jne 52f
    cmp byte ptr [r13 + r14 - 1], 10
    je 52f
    inc rdx                     # the beginning of a line that ends past the window
    cmp rdx, 65536
    jae 54f
    mov rsi, [rsp + 16]         # too little of it here: 64 KB from where it begins
    add rsi, rcx
    mov edi, r12d
    xor edx, edx
    SYS SYS_lseek
    test rax, rax
    js 53f
55: mov edi, r12d
    lea rsi, [rip + prefix_buf]
    mov edx, 65536
    SYS SYS_read
    cmp rax, -EINTR
    je 55b
    test rax, rax
    jle 53f
    mov rdx, rax
    mov rdi, rbx
    lea rsi, [rip + prefix_buf]
54: call prefix_model
    jmp 53f
52: call line_model
53:
    cmp dword ptr [rip + model_noted], 0
    jne 9f
    mov r15, [rsp + 24]
    jmp 3b
    # the next window ends where this one's first complete line begins, past a newline before its end;
    # without one, at its start (inside a line longer than the window)
6:  xor ecx, ecx
    lea rdx, [r14 - 1]
7:  cmp rcx, rdx
    jae 71f
    cmp byte ptr [r13 + rcx], 10
    je 72f
    inc rcx
    jmp 7b
71: mov rax, [rsp + 16]
    mov [rsp], rax
    jmp 1b
72: mov rax, [rsp + 16]
    lea rax, [rax + rcx + 1]
    cmp rax, [rsp]
    jae 9f
    mov [rsp], rax
    jmp 1b
9:  EPILOGUE

# read_at(fd, offset, buffer, len) -> bytes read there (0 on failure)
read_at:
    PROLOGUE
    mov ebx, edi
    mov r12, rdx
    mov r13, rcx
    xor edx, edx
    SYS SYS_lseek
    test rax, rax
    js 8f
    xor r14d, r14d
1:  mov edi, ebx
    lea rsi, [r12 + r14]
    mov rdx, r13
    sub rdx, r14
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    test rax, rax
    jle 2f
    add r14, rax
    cmp r14, r13
    jb 1b
2:  mov rax, r14
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# line_prefix(s, fd, offset): prefix_model of the line that offset is in, from its beginning, found back
#   past at most 1 MB
line_prefix:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r14, rdx                # the bytes before it are searched
    mov dword ptr [rsp], 16
1:  xor eax, eax
    test r14, r14
    jz 4f                       # the file's first line
    dec dword ptr [rsp]
    js 9f
    mov r15, r14
    sub r15, 65536
    jnb 2f
    xor r15d, r15d
2:  mov edi, r12d
    mov rsi, r15
    lea rdx, [rip + prefix_buf]
    mov rcx, r14
    sub rcx, r15
    call read_at
    mov rcx, r14
    sub rcx, r15
    cmp rax, rcx
    jne 9f
3:  test rcx, rcx
    jz 31f
    lea rdx, [rip + prefix_buf]
    cmp byte ptr [rdx + rcx - 1], 10
    je 32f
    dec rcx
    jmp 3b
31: mov r14, r15                # no newline here: further back
    jmp 1b
32: lea rax, [r15 + rcx]        # the line begins after that newline
4:  mov edi, r12d
    mov rsi, rax
    lea rdx, [rip + prefix_buf]
    mov ecx, 65536
    call read_at
    test rax, rax
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + prefix_buf]
    mov rdx, rax
    call prefix_model
9:  EPILOGUE

# prefix_model(s, ptr, len): the beginning of a record too long to read whole names its model, in its
#   first 64 KB, before the content: a key of a Claude Code reply's message object (at the record's top
#   level, not a subagent's in a progress record), or of a Codex turn_context's payload, after its type
prefix_model:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp dword ptr [rbx + AS_kind], 2
    ja 9f
    cmp r13, 65536
    jbe 1f
    mov r13d, 65536
1:  xor ecx, ecx                # offset
    xor r8d, r8d                # depth
    xor r10d, r10d              # in the object whose model counts
4:  lea rax, [rcx + 21]         # the longest key compared
    cmp rax, r13
    ja 9f
    movzx eax, byte ptr [r12 + rcx]
    cmp al, '"'
    je 5f
    cmp al, '{'
    je 41f
    cmp al, '['
    je 41f
    cmp al, '}'
    je 42f
    cmp al, ']'
    je 42f
    inc rcx
    jmp 4b
41: inc r8d
    inc rcx
    jmp 4b
42: dec r8d
    inc rcx
    cmp dword ptr [rbx + AS_kind], 1
    jne 4b
    cmp r8d, 1
    jne 4b
    xor r10d, r10d              # past Claude Code's message object
    jmp 4b
5:  cmp r8d, 1                  # a key of the record itself
    jne 51f
    lea rsi, [rip + .Lmsg_obj]
    mov edx, 11
    cmp dword ptr [rbx + AS_kind], 2
    jne 50f
    lea rsi, [rip + .Ltc_type]
    mov edx, 21
50: lea rdi, [r12 + rcx]
    push rcx
    push r8
    call memeq
    pop r8
    pop rcx
    or r10d, eax
    jmp 6f
51: cmp r8d, 2                  # a key of the message or payload
    jne 6f
    test r10d, r10d
    jz 6f
    lea rsi, [rip + .Lkey_model]
    mov r9d, 9
52: lea rdi, [r12 + rcx]
    mov edx, r9d
    push rcx
    push r8
    call memeq
    pop r8
    pop rcx
    test eax, eax
    jnz 7f
6:  inc rcx                     # past the string
61: cmp rcx, r13
    jae 9f
    movzx eax, byte ptr [r12 + rcx]
    inc rcx
    cmp al, 92
    jne 62f
    inc rcx
    jmp 61b
62: cmp al, '"'
    jne 61b
    jmp 4b
7:  lea r14, [r12 + rcx]
    add r14, r9
    mov rax, r13
    sub rax, rcx
    sub rax, r9
    mov rcx, rax
    xor edx, edx
2:  cmp rdx, rcx
    jae 9f
    cmp byte ptr [r14 + rdx], '"'
    je 3f
    cmp byte ptr [r14 + rdx], 92
    je 9f                       # an escape: no model name
    inc rdx
    jmp 2b
3:  mov rdi, rbx
    mov rsi, r14
    call row_model
9:  EPILOGUE

# line_model(s, line, len): the model a Claude Code reply or a Codex turn_context line names, for the row
line_model:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call json_parse
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Ltype]
    call json_get
    mov r13, rax
    cmp dword ptr [rbx + AS_kind], 2
    je 2f
    mov rdi, r13
    lea rsi, [rip + .Lassistant]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, r12
    lea rsi, [rip + .Lmessage]
    call json_get
    jmp 3f
2:  mov rdi, r13
    lea rsi, [rip + .Lturn_context]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, r12
    lea rsi, [rip + .Lpayload]
    call json_get
3:  mov rdi, rax
    lea rsi, [rip + .Lmodel]
    call json_get
    mov rdi, rax
    call json_str
    mov rdi, rbx
    mov rsi, rax
    call row_model
9:  EPILOGUE

# Capture the file state being consumed by a full conversation read.
observe_session:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + AS_kind], AS_KIND_EXT
    je 1f
    mov rdi, [rbx + AS_path]
    call vfs_stamp
    cmp rax, [rbx + AS_stamp]
    je 1f
    mov [rbx + AS_stamp], rax
    cmp dword ptr [rbx + AS_kind], 4
    jne 2f
    mov qword ptr [rbx + AS_off], 0
    mov qword ptr [rbx + AS_part + SB_len], 0
    mov rdi, rbx
    call session_clear_msgs
    jmp 1f                    # recency comes from the database header, not the cache file's mtime
2:
    mov dword ptr [rip + index_pending], 1
    mov rdi, [rbx + AS_path]
    call vfs_mtime_ns
    mov [rbx + AS_recency], rax
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    mov [rbx + AS_mtime], rax
    call time_ms
    mov [rbx + AS_changed], rax
1:  EPILOGUE
