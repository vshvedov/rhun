# agents panel: Claude Code, Codex, Grok Build and OpenCode sessions, live
.include "rhun.inc"

.equ QROWS_MAX, AL_QUEUE_MAX + AH_MAX   # queued rows at most (agent_queued)
.equ WALK_KEEP, 8               # chunks a frame's walked count tells its rows apart in
.equ HX_CAP, 0x3fffffff         # a chunk's height at most
.equ EST_CAP, 16777216          # a row's lines and bytes the estimate counts at most

.equ ID_AG_ROW, 0x400000          # + session: a range of its own, as the list has no end
.equ ID_AG_BACK, 0x5f00
.equ ID_AG_REFRESH, 0x5f01
.equ ID_AG_SCROLL, 0x5f02
.equ ID_AG_TSCROLL, 0x5f03
.equ ID_AG_FOLLOW, 0x5f04
.equ ID_AG_MORE, 0x5f05
.equ ID_AG_MD, 0x480000          # + (row & 255) * 4096: the links of the replies in view

.equ ROUTINE_GAP, 2000          # ms from one routine discovery run to the next
.equ INDEX_TIMEOUT, 60000       # ms a discovery run may take before it is stopped
.equ TRUNCATED_LEN, 53          # .Ltruncated's bytes

.bss
.p2align 3
sessions: .zero VEC_SIZE        # AS*
pool: .zero VEC_SIZE            # owned sessions, including previously opened pages
list_scroll: .long 0
th_scroll: .long 0
th_content: .long 0
.globl th_serial, th_textw
th_serial: .long 0              # frames of the conversation drawn (th_begin)
th_textw: .long 0               # the width its rows' text was laid out at last
.p2align 3
th_as: .quad 0                  # the session drawn (th_begin): its replies' links name its checkout
md_parses: .quad 0              # replies parsed (print-agent-row)
pend_link: .quad 0              # a link clicked in a reply, followed after the frame (owned cstr), or 0
pend_cwd: .quad 0               # and the checkout it was in (owned), or 0
pend_who: .quad 0               # a web link's: who asks to open it (links_ask_open), or 0
lk_buf: .zero 4096              # follow_file: the link's path
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
qrows: .zero AM_SIZE * QROWS_MAX    # the open conversation's queued messages as rows (queued_sync)
.p2align 3
th_aas: .quad 0                 # the session the anchor (th_arow, th_aoff) belongs to
add_x: .quad 0                  # agents_tool_row: the call the row add_msg makes owns
walk_c: .zero 8 * WALK_KEEP     # the rows whose height a frame asked (walked): their chunks
walk_m: .zero 8 * WALK_KEEP     #   and a bit per row of each
walk_k: .long 0                 # chunks noted
walk_x: .long 0                 # rows asked past WALK_KEEP chunks (counted, not told apart)
lay_off: .long 0                # th_layout: the pixels of lay_row above the area's top
th_pend: .long 0                # a page key's step, taken by the next frame as the wheel's
th_areah: .long 0               # the rows' area's height in the last frame (a page)
.globl ag_gen
ag_gen: .long 0                 # the view's generation: a setting or a state that changes heights moves it on
.data
.p2align 3
lay_row: .quad -1               # th_layout: the row drawn first this frame, -1 none
th_first: .long -1              # the rows the last frame drew, -1 none
th_last: .long -1
.globl th_arow, th_aoff
th_arow: .long -1               # the anchor: the row under the area's top edge, -1 none (the thread follows
th_aoff: .long 0                #   its end), and the pixels of it above the edge (row 0: -MI_12 at the top)
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
    call agents_sources_changed
1:  EPILOGUE

# ---------- asynchronous index and paging ----------

# FN agents_set_project(): another project (or none): the list is made again, the sessions rhun drives end
#   with their programs (agent_drv.s)
FN agents_set_project
    PROLOGUE
    call agent_drv_shutdown
    xor edi, edi
    call relist
    EPILOGUE

# FN agents_sources_changed(): the provider switches changed ([agents] claude, codex, ...: Settings, a
#   config reload): the list is made again with the new sources. A session rhun drives whose provider is
#   still listed keeps its program, its row and, when it is open, stays open; one whose provider was
#   switched off ends with its row (agent_drv_unlisted)
FN agents_sources_changed
    PROLOGUE
    call agent_drv_unlisted
    mov edi, 1
    call relist
    EPILOGUE

# relist(keep): the list is made again from a new discovery run. keep 0: every session goes; 1: the ones
#   rhun drives stay (keep_live)
relist:
    PROLOGUE
    mov ebx, edi
    call agents_shutdown
    mov rdi, [rip + cfg_agent_sources]
    call strlen
    mov rsi, rax
    mov rdi, [rip + cfg_agent_sources]
    call hash_line
    mov [rip + sources_hash], rax
    mov eax, [rip + g_show_agents]
    mov [rip + last_visible], eax
    test ebx, ebx
    jz 1f
    call keep_live
    jmp 2f
1:  lea rdi, [rip + pool]
    call agent_records_free
    mov qword ptr [rip + sessions + VEC_len], 0
    mov qword ptr [rip + view], -1
2:  mov qword ptr [rip + page_count], 0
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

# keep_live(): relist's keep: the pool keeps the sessions rhun drives, the others go; the kept ones are the
#   list's rows (after the page, which is empty until discovery's) and the open one stays open when kept
keep_live:
    PROLOGUE
    xor r14d, r14d              # the open session
    mov rax, [rip + view]
    test rax, rax
    js 1f
    cmp rax, [rip + sessions + VEC_len]
    jae 1f
    mov rcx, [rip + sessions + VEC_ptr]
    mov r14, [rcx + rax*8]
1:  mov qword ptr [rip + sessions + VEC_len], 0
    mov qword ptr [rip + view], -1
    xor ebx, ebx                # read
    xor r12d, r12d              # write
2:  cmp rbx, [rip + pool + VEC_len]
    jae 9f
    mov rax, [rip + pool + VEC_ptr]
    mov r13, [rax + rbx*8]
    inc rbx
    cmp qword ptr [r13 + AS_live], 0
    jne 3f
    cmp [rip + th_as], r13
    jne 21f
    mov qword ptr [rip + th_as], 0
21: mov rdi, r13
    call agent_session_free
    jmp 2b
3:  mov rax, [rip + pool + VEC_ptr]
    mov [rax + r12*8], r13
    inc r12
    cmp r13, r14
    jne 4f
    mov rax, [rip + sessions + VEC_len]
    mov [rip + view], rax
4:  lea rdi, [rip + sessions]
    mov esi, 8
    call vec_push
    mov [rax], r13
    jmp 2b
9:  mov [rip + pool + VEC_len], r12
    mov dword ptr [rip + g_dirty], 1
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
    lea rdi, [rbx + AS_hx]
    call vec_free
    lea rdi, [rbx + AS_wait]
    call vec_free
    lea rdi, [rbx + AS_folds]
    call vec_free
    lea rdi, [rbx + AS_tasks]
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
    mov rdi, [rbx + AS_draft]
    call mem_free
    mov rdi, rbx
    call mem_free
    EPILOGUE

session_clear_msgs:
    PROLOGUE
    mov rbx, rdi
    xor esi, esi
    call agents_rows_cut
    mov rdi, [rbx + AS_log_model]
    call mem_free
    mov rdi, [rbx + AS_shown_model]
    call mem_free
    mov qword ptr [rbx + AS_log_model], 0
    mov qword ptr [rbx + AS_shown_model], 0
    EPILOGUE

# msg_free(msg): what a message owns: its text, its name, its document and its call (agrow_free)
msg_free:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + AM_text]
    call mem_free
    mov rdi, [rbx + AM_name]
    call mem_free
    mov rdi, [rbx + AM_doc]
    call md_free
    mov rdi, [rbx + AM_x]
    test rdi, rdi
    jz 1f
    call agrow_free
1:  mov qword ptr [rbx + AM_text], 0
    mov qword ptr [rbx + AM_name], 0
    mov qword ptr [rbx + AM_doc], 0
    mov qword ptr [rbx + AM_x], 0
    pop rbx
    ret

# FN agents_msg_changed(AS*, index): the text of that message changed (it was set or added to in
#   place): its height and its Markdown are measured and parsed again when next needed
FN agents_msg_changed
    cmp rsi, [rdi + AS_msgs + VEC_len]
    jae 1f
    PROLOGUE
    imul rax, rsi, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    inc dword ptr [rax + AM_rev]
    mov dword ptr [rax + AM_w], -1
    or dword ptr [rax + AM_flags], AMF_EST
    mov dword ptr [rip + g_dirty], 1
    call hx_dirty               # its chunk: one chunk made again, whatever the conversation's length
    EPILOGUE
1:  ret

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
7:  mov rdi, rbx
    call row_init
    mov qword ptr [rbx + AS_changed], 0
9:  EPILOGUE

# row_init(s): the row add_msg just pushed (the last): its line feeds, its time (AS_now; a row the stream
#   feeds without one: the clock), its turn, no fold yet, an estimated height, its chunk dirtied; the first row
#   of a conversation starts the session's row state (AS_todo, AS_sticky, AS_day: none)
row_init:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AS_msgs + VEC_len]
    dec r12
    jnz 1f
    mov dword ptr [rbx + AS_todo], -1
    mov dword ptr [rbx + AS_sticky], -1
    mov qword ptr [rbx + AS_day], -1
1:  mov rdi, rbx
    mov rsi, r12
    call row_at
    mov r13, rax
    mov rdi, [r13 + AM_text]
    mov rsi, [r13 + AM_len]
    call count_lf
    mov [r13 + AM_nl], eax
    mov rax, [rbx + AS_now]
    test rax, rax
    jnz 3f
    mov rcx, [rbx + AS_live]    # a conversation rhun drives while its program runs: now
    test rcx, rcx
    jz 3f
    mov ecx, [rcx + AL_state]
    cmp ecx, ALS_STARTING
    jb 3f
    cmp ecx, ALS_HELD
    ja 3f
    call agtime_now
    mov rcx, rax
    mov rdi, rbx
    mov rsi, r12
    call row_at
    mov r13, rax
    mov rax, rcx
3:  mov [r13 + AM_t], rax
    mov eax, -1                 # its turn: a prompt starts one, any other row is in the one before it
    test r12, r12
    jz 4f
    mov eax, [r13 - AM_SIZE + AM_turn]
4:  cmp dword ptr [r13 + AM_role], R_USER
    jne 5f
    test dword ptr [r13 + AM_flags], AMF_QUEUED
    jnz 5f
    mov eax, r12d
5:  mov [r13 + AM_turn], eax
    mov dword ptr [r13 + AM_fold], -1
    mov dword ptr [r13 + AM_ms], -1
    or dword ptr [r13 + AM_flags], AMF_EST
    mov rax, [rip + add_x]      # a call's row: its call (agrow_ready chooses its fold)
    mov [r13 + AM_x], rax
    mov rdi, rbx
    mov rsi, r12
    call hx_dirty
    cmp qword ptr [rip + add_x], 0
    jne 9f
    mov rdi, rbx
    mov rsi, r12
    call agfold_add
9:  EPILOGUE

# FN agents_tool_row(AS*, AT*) -> rax the index of a new R_TOOL row at the end that owns that call (AM_x;
#   agentrows.s agrow_tool)
FN agents_tool_row
    PROLOGUE
    mov [rip + add_x], rsi
    mov esi, R_TOOL
    lea rdx, [rip + .Lempty]
    xor ecx, ecx
    xor r8d, r8d
    call agents_msg_add
    mov qword ptr [rip + add_x], 0
    EPILOGUE

# FN agents_row_peek(AS*, index, w) -> eax the height the sums use (the fold's too), edx 1 when it is exact
#   for the key: nothing is measured, nothing counted (print-agent-rows)
FN agents_row_peek
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    call row_at
    mov rdi, rax
    mov esi, r13d
    call row_valid
    mov r14d, eax
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call row_h0
    mov ecx, eax
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call agfold_h
    mov edx, r14d
    EPILOGUE

# FN agents_view_first() -> rax the first row the last frame drew, -1; agents_view_last() the last
FN agents_view_first
    movsxd rax, dword ptr [rip + th_first]
    ret
FN agents_view_last
    movsxd rax, dword ptr [rip + th_last]
    ret

# FN agents_reveal(AS*, row): that row brought into view (the row focus): when the last frame did not draw it
#   whole it is put at the area's top
FN agents_reveal
    cmp [rip + th_aas], rdi
    jne 9f
    movsxd rax, dword ptr [rip + th_first]
    cmp rsi, rax
    jle 1f                      # above, or the first: perhaps cut by the top edge
    movsxd rax, dword ptr [rip + th_last]
    cmp rsi, rax
    jl 9f                       # inside the view
1:  mov dword ptr [rip + th_follow], 0
    mov [rip + th_arow], esi
    mov dword ptr [rip + th_aoff], 0
    mov dword ptr [rip + g_dirty], 1
9:  ret

# FN agents_session_live(AS*) -> eax 1 when it is live (is_live: driven and working or waiting, or written to
#   in the last 20 seconds)
FN agents_session_live
    jmp is_live

# FN agents_open_link(AS*, ptr, len) -> eax 1 when it was a file's (opened now, as a reply's link is: after the
#   frame, relative to the conversation's checkout), 0 for a web link (asked before it opens, links_ask_open,
#   named by the conversation's driver, else "This reply") or another scheme (nothing)
FN agents_open_link
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call link_scheme
    cmp eax, 2
    jne 3f
    mov rdi, r12                # another scheme: a web link asks, anything else is nothing
    mov rsi, r13
    call links_url_ok
    test eax, eax
    jz 8f
    lea r14, [rip + .Lthis_reply]
    mov rdi, rbx
    call agent_drv_of
    test rax, rax
    jz 1f
    mov r14, [rax + DRV_name]
1:  mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov r15, rax
    mov rdi, r14
    mov rsi, r15
    call links_ask_open
    mov rdi, r15
    call mem_free
    jmp 8f
3:  mov rdi, [rip + pend_link]  # a file, file: or rhun://: the reply links' path (reply_follow)
    call mem_free
    mov rdi, [rip + pend_cwd]
    call mem_free
    mov qword ptr [rip + pend_cwd], 0
    mov qword ptr [rip + pend_who], 0
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rip + pend_link], rax
    mov r12, [rbx + AS_cwd]
    test r12, r12
    jz 4f
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [rip + pend_cwd], rax
4:  call reply_follow
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# count_lf(ptr, len) -> eax the line feeds in it
count_lf:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 9f
    cmp byte ptr [rdi + rcx], 10
    jne 2f
    inc eax
2:  inc rcx
    jmp 1b
9:  ret

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

# interrupt_mark(ptr, len) -> eax 1 when a user text is Claude Code's interrupt mark ("[Request interrupted
#   by user]", "[Request interrupted by user for tool use]"): it is drawn as the "Interrupted" row the live
#   stream ends such a turn with (agent_drv.s), so a file read again gives the rows the stream gave
interrupt_mark:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdx, [rip + .Lmark_stop]
    call str_eq_cstr
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lmark_tool]
    call str_eq_cstr
9:  EPILOGUE

# add_interrupted(s): the "Interrupted" row
add_interrupted:
    PROLOGUE
    mov esi, R_INFO
    lea rdx, [rip + .Linterrupted]
    mov ecx, 11
    xor r8d, r8d
    call add_msg
    EPILOGUE

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
    mov rdi, r12                # the rows the line makes carry its time
    lea rsi, [rip + .Ltimestamp]
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jz 0f
    mov rdi, rax
    mov rsi, rdx
    call agtime_iso
    mov rdi, rbx
    mov rsi, rax
    call agents_stamp
0:  mov rdi, r12
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
    mov rdi, r13
    lea rsi, [rip + .Lsystem]
    call json_is
    test eax, eax
    jz .Lil_ret
    cmp dword ptr [rsp], 0      # a system line: its kind's reader, when it has one
    je .Lil_ret
    mov rdi, rbx
    mov rsi, r12
    mov edx, ING_FILE
    call agent_ingest
    jmp .Lil_ret
.Lil_user:
    # the kind's reader first (agent_drv.s readers): when it made the line's rows, only the title is read
    #   below. (A reader must not parse while it reads: the title reads the record after it.)
    cmp dword ptr [rsp], 0
    je 0f
    mov rdi, rbx
    mov rsi, r12
    mov edx, ING_FILE
    call agent_ingest
    test eax, eax
    jz 0f
    mov dword ptr [rsp], 0
0:  # skip meta / command records
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
    mov rdi, rax
    mov rsi, rdx
    call interrupt_mark
    test eax, eax
    jnz .Lil_mark
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
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
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    mov rdi, rax
    mov rsi, rdx
    call interrupt_mark
    test eax, eax
    jz 31f
    mov rdi, rbx
    call add_interrupted
    jmp 4f
31: mov rdi, rbx
    mov esi, R_USER
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    xor r8d, r8d
    call add_msg
4:  inc r14d
    jmp 2b
.Lil_mark:                      # the interrupt mark as a string: no title, the Interrupted row
    cmp dword ptr [rsp], 0
    je .Lil_ret
    mov rdi, rbx
    call add_interrupted
    jmp .Lil_ret
.Lil_assist:
    cmp dword ptr [rsp], 0      # the kind's reader first, as for a user line
    je 0f
    mov rdi, rbx
    mov rsi, r12
    mov edx, ING_FILE
    call agent_ingest
    test eax, eax
    jz 0f
    mov dword ptr [rsp], 0
0:  mov rdi, r12
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
    mov qword ptr [rbx + AS_now], 0     # the next line's rows have their own time
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
    mov rax, [rbx + AS_off]     # the line's place in the file: what was read, less what is not parsed
    sub rax, [rbx + AS_part + SB_len]   #   yet, plus its start in that
    add rax, [rsp]
    mov [rbx + AS_line], rax
    sub rdx, [rsp]
    mov [rbx + AS_linelen], rdx
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
    mov qword ptr [rbx + AS_line], -1   # no line read: a row made now has no place
    mov qword ptr [rbx + AS_linelen], 0
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
7:  call claude_dir_moved      # the login environment names another Claude folder: discovery again
    test eax, eax
    jz 71f
    call agents_scan
71: cmp qword ptr [rip + g_project], 0
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
    mov dword ptr [rip + th_arow], -1
    mov [rip + th_aas], rbx
    mov rdi, -1                 # no row focused in it yet
    call agrow_focus_set
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
1:  cmp rbx, [rip + sessions + VEC_len]
    jae 3f
    mov rdi, rbx                # the rows the list shows (row_shown)
    call row_shown
    test eax, eax
    jnz 11f
    inc rbx
    jmp 1b
11: mov rax, [rip + sessions + VEC_ptr]
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
    jae 8f
    imul r13, rbx, AM_SIZE
    add r13, [r12 + AS_msgs + VEC_ptr]
    mov rdi, r15                # the typed rows' lines (dump_typed)
    mov rsi, r13
    call dump_typed
    test eax, eax
    jz 40f
    inc rbx
    jmp 4b
40: mov eax, [r13 + AM_role]
    lea rcx, [rip + role_names]
    mov rsi, [rcx + rax*8]
    test dword ptr [r13 + AM_flags], AMF_PILL
    jz 41f
    lea rsi, [rip + .Lr_pill]   # a pill row: "pill TEXT"
41: mov rdi, r15
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
8:  xor ebx, ebx                # then the messages that have not started: "queued TEXT"
81: mov rdi, r12
    mov rsi, rbx
    call agent_queued
    test rax, rax
    jz 9f
    mov r13, rax
    mov r14, rdx
    mov rdi, r15
    lea rsi, [rip + .Lqueued_dump]
    call sb_push_cstr
    xor ecx, ecx
82: cmp rcx, r14
    jae 83f
    cmp rcx, 60
    jae 83f
    cmp byte ptr [r13 + rcx], 10
    je 83f
    inc rcx
    jmp 82b
83: mov rdi, r15
    mov rsi, r13
    mov rdx, rcx
    call sb_push
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 81b
9:  EPILOGUE

# dump_typed(sb, AM*) -> eax 1 when print-agents' line of that row was written here (or the row has none): a
#   typed tool row "tool(NAME) SUMMARY", then "result FIRST LINE" when it shows an OUT (a hidden call: no
#   line); "thinking(live|Ns|-) T"; "compact auto|manual Nk"; "unknown TYPE". 0: the plain line
dump_typed:
    PROLOGUE
    mov r15, rdi
    mov rbx, rsi
    mov r12, [rbx + AM_x]
    test r12, r12
    jz 3f
    test dword ptr [r12 + AT_flags], ATF_HIDDEN
    jnz 8f
    lea rsi, [rip + .Lr3]
    mov rdi, r15
    call sb_push_cstr
    mov rsi, [rbx + AM_name]
    test rsi, rsi
    jnz 1f
    mov rsi, [r12 + AT_name]
    test rsi, rsi
    jz 2f
1:  mov rdi, r15
    call dump_paren
2:  mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    mov rdi, r15
    mov rsi, [rbx + AM_text]
    mov rdx, [rbx + AM_len]
    call dump_line
    mov rdx, [r12 + AT_out + SB_len]
    test rdx, rdx
    jz 8f
    mov rdi, r15
    lea rsi, [rip + .Lr_result]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [r12 + AT_out + SB_ptr]
    mov rdx, [r12 + AT_out + SB_len]
    call dump_line
    jmp 8f
3:  mov eax, [rbx + AM_role]
    cmp eax, R_THINK
    je 4f
    cmp eax, R_COMPACT
    je 5f
    cmp eax, R_UNKNOWN
    je 6f
    xor eax, eax
    EPILOGUE
4:  mov rdi, r15                # thinking(live|Ns|-) T
    lea rsi, [rip + .Lr7]
    call sb_push_cstr
    mov rdi, r15
    mov esi, '('
    call sb_push_byte
    test dword ptr [rbx + AM_flags], AMF_LIVE
    jz 41f
    mov rdi, r15
    lea rsi, [rip + .Lr_live]
    call sb_push_cstr
    jmp 43f
41: mov eax, [rbx + AM_ms]
    test eax, eax
    jns 42f
    mov rdi, r15
    mov esi, '-'
    call sb_push_byte
    jmp 43f
42: xor edx, edx
    mov ecx, 1000
    div ecx
    mov rdi, r15
    mov esi, eax
    call sb_push_u64
    mov rdi, r15
    mov esi, 's'
    call sb_push_byte
43: mov rdi, r15
    lea rsi, [rip + .Lr_close]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + AM_text]
    mov rdx, [rbx + AM_len]
    call dump_line
    jmp 8f
5:  mov rdi, r15                # compact auto|manual Nk
    lea rsi, [rip + .Lr9]
    call sb_push_cstr
    lea rsi, [rip + .Lr_auto]
    test dword ptr [rbx + AM_flags], AMF_MANUAL
    jz 51f
    lea rsi, [rip + .Lr_manual]
51: mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + AM_n]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lr_k]
    call sb_push_cstr
    jmp 8f
6:  mov rdi, r15                # unknown TYPE
    lea rsi, [rip + .Lr10]
    call sb_push_cstr
    mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    mov rdi, r15
    mov rsi, [rbx + AM_text]
    mov rdx, [rbx + AM_len]
    call dump_line
8:  mov eax, 1
    EPILOGUE

# dump_paren(sb, cstr): "(TEXT)"
dump_paren:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov esi, '('
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ')'
    call sb_push_byte
    EPILOGUE

# dump_line(sb, ptr, len): its first line, 60 bytes at most, and a line feed
dump_line:
    PROLOGUE
    mov rbx, rdi
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 2f
    cmp rcx, 60
    jae 2f
    cmp byte ptr [rsi + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov rdx, rcx
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

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
    call agentpop_kind          # an open popup of the box's (agentpop.s) takes its keys first
    test eax, eax
    jz 0f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call agentpop_key
    test eax, eax
    jnz 5f
0:  call agentext_new_active    # AI (D4): a new session's draft hides the conversation and its card
    test rax, rax
    jnz 4f
    call agents_open_driven     # 1 to 9 pick an option of the open session's card
    test rax, rax
    jz 4f
    mov rbx, rax
    mov rdi, rbx                # a rich card first (agentcard.s)
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call agentcard_key
    test eax, eax
    jnz 5f
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
    cmp r12d, KEY_ESCAPE        # (Escape: a running turn's Stop first, below)
    je 61f
    mov edi, r12d               # the thread's keys: the ends, pages, the row focus (Enter: a focused row's)
    mov esi, r13d
    mov edx, r14d
    call th_keys
    test eax, eax
    jnz 5f
61: cmp r12d, KEY_RETURN        # Enter or Tab goes to its prompt box
    je 6f
    cmp r12d, KEY_TAB
    jne 4f
6:  mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT  # it has a driver: the box is there
    mov dword ptr [rip + g_dirty], 1
    jmp 5f
4:  call agentext_new_active
    test rax, rax
    jz 71f
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
71: cmp r12d, KEY_ESCAPE        # Escape while the open conversation's turn runs: Stop (agent_drv.s)
    jne 72f
    call agents_open_driven
    test rax, rax
    jz 72f
    mov rdi, rax
    call agent_stop_running
    test eax, eax
    jnz 5b
72: mov edi, r12d               # the thread's keys (Escape: a row focus goes before the conversation)
    mov esi, r13d
    mov edx, r14d
    call th_keys
    test eax, eax
    jnz 5b
7:  mov edi, r12d
    call key_list
    EPILOGUE

# th_keys(keysym, cp, mods) -> eax 1 taken: the open conversation's thread keys. Home or Cmd/Ctrl+Up: the
#   first row; End or Cmd/Ctrl+Down: the last, following; PageUp, PageDown: a page (the next frame steps the
#   anchor, as the wheel does); Up, Down, Enter, Space, Escape: the row focus (agrow_key)
th_keys:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov rax, [rip + view]
    test rax, rax
    js 8f
    cmp rax, [rip + sessions + VEC_len]
    jae 8f
    mov rcx, [rip + sessions + VEC_ptr]
    mov rbx, [rcx + rax*8]
    mov eax, r14d
    and eax, MOD_CTRL | MOD_SUPER
    jz 1f
    test r14d, MOD_ALT | MOD_SHIFT
    jnz 1f
    cmp r12d, KEY_UP
    je 2f
    cmp r12d, KEY_DOWN
    je 3f
    jmp 8f
1:  test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER | MOD_SHIFT
    jnz 6f
    cmp r12d, KEY_HOME
    je 2f
    cmp r12d, KEY_END
    je 3f
    cmp r12d, KEY_PAGEUP
    je 4f
    cmp r12d, KEY_PAGEDOWN
    je 5f
    jmp 6f
2:  mov dword ptr [rip + th_follow], 0  # the first row
    mov dword ptr [rip + th_arow], 0
    PM eax, MI_12
    neg eax
    mov [rip + th_aoff], eax
    mov [rip + th_aas], rbx
    jmp 7f
3:  mov dword ptr [rip + th_follow], 1  # the last, following
    mov dword ptr [rip + th_arow], -1
    jmp 7f
4:  call th_page
    sub [rip + th_pend], eax
    jmp 7f
5:  call th_page
    add [rip + th_pend], eax
    jmp 7f
6:  mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call agrow_key
    EPILOGUE
7:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# th_page() -> eax a page of the thread: the area's height less a line (MI_40), at least MI_20
th_page:
    mov eax, [rip + th_areah]
    sub eax, [rip + g_pmt + 4*MI_40]
    mov ecx, [rip + g_pmt + 4*MI_20]
    cmp eax, ecx
    cmovl eax, ecx
    ret

# FN agents_focus_last(): "Agents: Focus Last Message": the panel's keys, the open conversation at its end
#   (following), the row focus on its last row
FN agents_focus_last
    PROLOGUE
    call cmd_focus_agents
    mov rax, [rip + view]
    test rax, rax
    js 9f
    cmp rax, [rip + sessions + VEC_len]
    jae 9f
    mov rcx, [rip + sessions + VEC_ptr]
    mov rbx, [rcx + rax*8]
    mov dword ptr [rip + th_follow], 1
    mov dword ptr [rip + th_arow], -1
    mov rdi, [rbx + AS_msgs + VEC_len]
    dec rdi
    call agrow_focus_set
9:  mov dword ptr [rip + g_dirty], 1
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

# FN agents_open_any() -> rax the conversation the panel shows, whatever its kind, or 0
FN agents_open_any
    xor eax, eax
    mov rcx, [rip + view]
    test rcx, rcx
    js 1f
    cmp rcx, [rip + sessions + VEC_len]
    jae 1f
    mov rdx, [rip + sessions + VEC_ptr]
    mov rax, [rdx + rcx*8]
1:  ret

# FN agents_viewed() -> rax the open conversation (AS*), or 0 (the list)
FN agents_viewed
    xor eax, eax
    mov rcx, [rip + view]
    test rcx, rcx
    js 1f
    cmp rcx, [rip + sessions + VEC_len]
    jae 1f
    mov rax, [rip + sessions + VEC_ptr]
    mov rax, [rax + rcx*8]
1:  ret

# FN agents_scroll_dump(sb): " scroll=N max=N follow=0|1": the open thread as it was drawn last (where it
#   is scrolled, how far it can be, whether it follows what comes in)
FN agents_scroll_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_scroll]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + th_scroll]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_max]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + th_max]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_follow]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + th_follow]
    call sb_push_u64
    EPILOGUE

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

# FN agents_drop(AS*): a session made here that is not wanted (a new conversation left without a prompt)
#   leaves the list and the pool and is freed (its program ends: agent_closed); the open one closes
FN agents_drop
    PROLOGUE
    mov rbx, rdi
    xor ecx, ecx
1:  cmp rcx, [rip + sessions + VEC_len]
    jae 5f
    mov rax, [rip + sessions + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 2f
    inc rcx
    jmp 1b
2:  mov rdx, [rip + view]       # the rows after it move up: the open one keeps its row
    cmp rdx, rcx
    jl 3f
    jg 21f
    mov qword ptr [rip + view], -1
    jmp 3f
21: dec qword ptr [rip + view]
3:  cmp rcx, [rip + page_count]
    jae 31f
    dec qword ptr [rip + page_count]
31: mov rax, [rip + sessions + VEC_ptr]
    mov rdx, [rip + sessions + VEC_len]
    dec rdx
    mov [rip + sessions + VEC_len], rdx
4:  cmp rcx, rdx
    jae 5f
    mov r8, [rax + rcx*8 + 8]
    mov [rax + rcx*8], r8
    inc rcx
    jmp 4b
5:  xor ecx, ecx
6:  cmp rcx, [rip + pool + VEC_len]
    jae 8f
    mov rax, [rip + pool + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 7f
    inc rcx
    jmp 6b
7:  mov rdx, [rip + pool + VEC_len]
    dec rdx
    mov [rip + pool + VEC_len], rdx
71: cmp rcx, rdx
    jae 8f
    mov r8, [rax + rcx*8 + 8]
    mov [rax + rcx*8], r8
    inc rcx
    jmp 71b
8:  cmp [rip + th_as], rbx
    jne 81f
    mov qword ptr [rip + th_as], 0
81: mov rdi, rbx
    call agent_session_free
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

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

# FN agents_reply_nth(AS*, n) -> rax ptr, rdx len of its n-th last reply (1 the latest; 0, or past them: rax
#   0), ecx how many it has (the last 20 at most): the rows of the agent's text (role R_ASSIST, not empty)
FN agents_reply_nth
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
    xor r14d, r14d
    xor r15d, r15d
    mov rcx, [rbx + AS_msgs + VEC_len]
1:  test rcx, rcx
    jz 9f
    cmp r13d, 20
    jae 9f
    dec rcx
    imul rax, rcx, AM_SIZE
    add rax, [rbx + AS_msgs + VEC_ptr]
    cmp dword ptr [rax + AM_role], R_ASSIST
    jne 1b
    cmp qword ptr [rax + AM_len], 0
    je 1b
    inc r13d
    cmp r13, r12
    jne 1b
    mov r14, [rax + AM_text]
    mov r15, [rax + AM_len]
    jmp 1b
9:  mov rax, r14
    mov rdx, r15
    mov ecx, r13d
    EPILOGUE

# FN agents_user_nth(AS*, n) -> rax ptr, rdx len of its n-th last prompt (1 the latest; past them: rax 0): the
#   rows of the user's text (role R_USER, not blank), what the box's recall goes back through
FN agents_user_nth
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
    mov r14, [rbx + AS_msgs + VEC_len]
1:  test r14, r14
    jz 8f
    dec r14
    imul r15, r14, AM_SIZE
    add r15, [rbx + AS_msgs + VEC_ptr]
    cmp dword ptr [r15 + AM_role], R_USER
    jne 1b
    mov rax, [r15 + AM_text]
    test rax, rax
    jz 1b
    xor ecx, ecx
2:  cmp rcx, [r15 + AM_len]
    jae 1b                      # blank
    cmp byte ptr [rax + rcx], ' '
    ja 3f
    inc rcx
    jmp 2b
3:  inc r13
    cmp r13, r12
    jne 1b
    mov rdx, [r15 + AM_len]
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

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

# FN agents_last_user(AS*) -> rax ptr, rdx len: the text of its last user row (in a session rhun drives, the
#   message that started last), rax 0 when it has none
FN agents_last_user
    mov rcx, [rdi + AS_msgs + VEC_len]
1:  xor eax, eax
    xor edx, edx
    test rcx, rcx
    jz 9f
    dec rcx
    imul rax, rcx, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    cmp dword ptr [rax + AM_role], R_USER
    jne 1b
    mov rdx, [rax + AM_len]
    mov rax, [rax + AM_text]
9:  ret

# FN agents_pill(AS*, ptr, len): a one-line pill row of a session rhun drives ("Switched to NAME"): an info
#   row drawn centred, muted, in a rounded frame (AMF_PILL); print-agents shows it as "pill TEXT"
FN agents_pill
    PROLOGUE
    mov rbx, rdi
    mov rcx, rdx
    mov rdx, rsi
    mov esi, R_INFO
    xor r8d, r8d
    call agents_msg_add
    test rax, rax
    js 9f
    imul rax, rax, AM_SIZE
    add rax, [rbx + AS_msgs + VEC_ptr]
    or dword ptr [rax + AM_flags], AMF_PILL
    mov rdi, rbx                # measured as a pill
    mov rsi, [rbx + AS_msgs + VEC_len]
    dec rsi
    call agents_msg_changed
9:  EPILOGUE

# queued_sync(AS*) -> eax n: the session's messages that have not started (agent_queued: those waiting
#   for a start, then those held) as the rows qrows[0..n): the user's look, AMF_QUEUED. A row keeps its
#   measured height while its message is the same (its text's place and length, and a held one's uuid)
queued_sync:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12d, QROWS_MAX
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call agent_queued
    test rax, rax
    jz 9f
    imul r13, r12, AM_SIZE
    lea r8, [rip + qrows]
    add r13, r8
    inc r12d
    cmp [r13 + AM_text], rax
    jne 2f
    cmp [r13 + AM_len], rdx
    jne 2f
    cmp [r13 + AM_qid], rcx     # (a freed message and a new one of its length at its address: not it)
    je 1b
2:  mov [r13 + AM_text], rax
    mov [r13 + AM_len], rdx
    mov [r13 + AM_qid], rcx
    mov dword ptr [r13 + AM_role], R_USER
    mov dword ptr [r13 + AM_flags], AMF_QUEUED
    mov dword ptr [r13 + AM_w], -1      # measured again
    inc dword ptr [r13 + AM_rev]
    jmp 1b
9:  mov eax, r12d
    EPILOGUE

# FN agents_sent(AS*): the user sent a message in that session: with [agents] scroll_on_send, its
#   conversation, when it is the open one, follows its end again
FN agents_sent
    cmp dword ptr [rip + cfg_agents_scroll_on_send], 0
    je 1f
    mov rax, [rip + view]
    test rax, rax
    js 1f
    mov rcx, [rip + sessions + VEC_ptr]
    cmp [rcx + rax*8], rdi
    jne 1f
    mov dword ptr [rip + th_follow], 1
    mov dword ptr [rip + g_dirty], 1
1:  ret

# FN agents_copy_rows(dst AS*, src AS*, n): the first n rows of src (at most all) added to dst, with their
#   labels (a copy of a conversation shows what the original showed)
FN agents_copy_rows
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r13, [r12 + AS_msgs + VEC_len]
    jbe 1f
    mov r13, [r12 + AS_msgs + VEC_len]
1:  xor r14d, r14d
2:  cmp r14, r13
    jae 9f
    imul r15, r14, AM_SIZE
    add r15, [r12 + AS_msgs + VEC_ptr]
    mov rdi, rbx
    mov esi, [r15 + AM_role]
    mov rdx, [r15 + AM_text]
    mov rcx, [r15 + AM_len]
    mov r8, [r15 + AM_name]
    call agents_msg_add
    test rax, rax
    js 3f
    mov rdi, rbx                # its flags, times and call too: the copy shows what its source showed
    mov rsi, rax
    mov rdx, r15
    call row_copy_parts
3:  inc r14
    jmp 2b
9:  EPILOGUE

# row_copy_parts(AS*, index, AM* source): a copied row gets its source's flags, times, counts and a deep
#   copy of its call
row_copy_parts:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call row_at
    mov r14, rax
    mov eax, [r13 + AM_flags]
    and eax, ~AMF_EST
    or [r14 + AM_flags], eax
    mov rax, [r13 + AM_t]
    mov [r14 + AM_t], rax
    mov eax, [r13 + AM_ms]
    mov [r14 + AM_ms], eax
    mov eax, [r13 + AM_n]
    mov [r14 + AM_n], eax
    mov rdi, [r13 + AM_x]
    test rdi, rdi
    jz 9f
    call agrow_clone
    mov r15, rax
    mov rdi, rbx
    mov rsi, r12
    call row_at
    mov [rax + AM_x], r15
    test r15, r15
    jz 9f
    mov [r15 + AT_row], r12d
9:  mov rdi, rbx
    mov rsi, r12
    call agents_msg_changed
    EPILOGUE

# FN agents_stamp(AS*, unix ms): the rows added next carry that time (0: none; then a row of a conversation
#   rhun drives while its program runs gets the clock)
FN agents_stamp
    mov [rdi + AS_now], rsi
    ret

# FN agents_row_add(AS*, role, ptr, len, name cstr or 0) -> rax its index, or -1: a row as a reader adds it
#   (add_msg's rule: trimmed, an empty one skipped; agents_msg_add stays the stream's)
FN agents_row_add
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AS_msgs + VEC_len]
    call add_msg
    mov rax, -1
    cmp [rbx + AS_msgs + VEC_len], r12
    je 9f
    mov rax, r12
9:  EPILOGUE

# FN agents_reply_add(AS*, ptr, len, synthetic) -> rax its index, or -1: a reply read from a file, with the
#   label reply_label gives it (none for the agent's own notices: synthetic 1)
FN agents_reply_add
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r8d, r8d
    test ecx, ecx
    jnz 1f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call reply_label
    mov r8, rax
1:  mov rdi, rbx
    mov esi, R_ASSIST
    mov rdx, r12
    mov rcx, r13
    call agents_row_add
    EPILOGUE

# FN agents_row_flag(AS*, index, AMF_* on): flags of a row on (measured again)
FN agents_row_flag
    cmp rsi, [rdi + AS_msgs + VEC_len]
    jae 1f
    imul rax, rsi, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    or [rax + AM_flags], edx
    jmp agents_msg_changed
1:  ret

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
    mov rdi, [r15 + AM_text]    # its line feeds
    add rdi, [r15 + AM_len]
    mov r13, rax
    mov rsi, rax
    call count_lf
    add [r15 + AM_nl], eax
    mov rax, r13
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
    mov rdi, r15
    mov rsi, r13
    call count_lf
    imul rcx, r12, AM_SIZE
    add rcx, [rbx + AS_msgs + VEC_ptr]
    mov [rcx + AM_nl], eax
    mov rdi, rbx
    mov rsi, r12
    call agents_msg_changed
9:  EPILOGUE

# FN agents_reply_model(AS*, model ptr, len, index): an assistant record of a session rhun drives, read
#   as ingest_line reads one from the file: its model is noted (the list's row, the replies that follow),
#   and the reply row at index (-1: the record has none) gets the label the file would give it: the
#   model where it changes, none for Claude Code's own notices ("<synthetic>")
FN agents_reply_model
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call note_model
    test r14, r14
    js 9f
    cmp r14, [rbx + AS_msgs + VEC_len]
    jae 9f
    test r13, r13
    jz 1f
    cmp byte ptr [r12], '<'
    je 9f
1:  imul r15, r14, AM_SIZE
    add r15, [rbx + AS_msgs + VEC_ptr]
    mov rdi, rbx
    mov rsi, [r15 + AM_text]
    mov rdx, [r15 + AM_len]
    call reply_label
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov rdi, [r15 + AM_name]
    mov [r15 + AM_name], rax
    call mem_free
    mov rdi, rbx
    mov rsi, r14
    call agents_msg_changed
9:  EPILOGUE

# FN agents_tool_summary(input jv) -> rax ptr, rdx len: what a tool call's row shows of its input, by the
#   file reader's rule (the most telling field; a path inside the project relative to it)
FN agents_tool_summary
    jmp tool_summary

# FN agents_text_of(jv) -> rax ptr, rdx len: a tool result's text as the file reader shows it (a string,
#   or the text parts of an array, a line feed between them; valid until the next call)
FN agents_text_of
    jmp text_of

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
    PROLOGUE 16
    mov rbx, rdi
    mov qword ptr [rsp], -1     # the view's anchor, as (its turn's number, its place in the turn)
    cmp [rip + th_aas], rbx
    jne 1f
    cmp dword ptr [rip + th_follow], 0
    jne 1f
    movsxd rsi, dword ptr [rip + th_arow]
    test rsi, rsi
    js 1f
    cmp rsi, [rbx + AS_msgs + VEC_len]
    jae 1f
    mov rdi, rbx
    call anchor_save
    mov [rsp], rax
    mov [rsp + 8], rdx
1:  mov rdi, rbx
    call session_clear_msgs
    mov qword ptr [rbx + AS_off], 0
    mov qword ptr [rbx + AS_part + SB_len], 0
    mov rdi, rbx
    call session_update
    mov rsi, [rsp]
    test rsi, rsi
    js 2f
    mov rdi, rbx                # the same place, or the turn's nearest row
    mov rdx, [rsp + 8]
    call anchor_restore
    cmp dword ptr [rip + th_arow], 0
    jl 2f
    mov dword ptr [rip + th_follow], 0  # (the rows' cut made it follow)
    mov [rip + th_aas], rbx
2:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# anchor_save(AS*, row) -> rax the number of its turn among the prompts (0: before the first), rdx its place
#   after that turn's prompt (agents_resync: what survives a reread)
anchor_save:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call row_at
    movsxd r13, dword ptr [rax + AM_turn]
    test r13, r13
    jns 1f
    xor eax, eax
    mov rdx, r12
    EPILOGUE
1:  xor r14d, r14d              # the turns up to it
    xor r15d, r15d
2:  cmp r15, r13
    ja 3f
    mov rdi, rbx
    mov rsi, r15
    call row_at
    movsxd rax, dword ptr [rax + AM_turn]
    cmp rax, r15
    jne 21f
    inc r14
21: inc r15
    jmp 2b
3:  mov rax, r14
    mov rdx, r12
    sub rdx, r13
    EPILOGUE

# anchor_restore(AS*, turn, place): the anchor at that place of that turn again (th_aoff kept): past the
#   turn's rows its last row, past the turns the last row
anchor_restore:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, [rbx + AS_msgs + VEC_len]
    test r14, r14
    jnz 1f
    mov dword ptr [rip + th_arow], -1
    mov dword ptr [rip + th_follow], 1
    EPILOGUE
1:  xor r15d, r15d              # the turn's prompt: the r12-th turn start (0: row 0)
    xor ecx, ecx                # turns seen
    test r12, r12
    jz 4f
2:  cmp r15, r14
    jae 6f                      # fewer turns: the last row
    mov rdi, rbx
    mov rsi, r15
    call row_at
    movsxd rax, dword ptr [rax + AM_turn]
    cmp rax, r15
    jne 3f
    inc rcx
    cmp rcx, r12
    je 4f
3:  inc r15
    jmp 2b
4:  lea rax, [r15 + r13]        # its place, but not past the turn's last row
    lea rcx, [r15 + 1]
5:  cmp rcx, rax
    ja 7f
    cmp rcx, r14
    jae 7f
    push rax
    push rcx
    mov rdi, rbx
    mov rsi, rcx
    call row_at
    movsxd rdx, dword ptr [rax + AM_turn]
    pop rcx
    pop rax
    cmp rdx, rcx
    je 51f                      # the next turn begins: the row before it
    inc rcx
    jmp 5b
51: lea rax, [rcx - 1]
7:  cmp rax, r14
    jb 8f
6:  lea rax, [r14 - 1]
8:  mov [rip + th_arow], eax
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
1:  mov rdi, rbx                # with the chunks and folds after them (agents_rows_cut)
    mov rsi, r12
    call agents_rows_cut
9:  EPILOGUE

# FN agents_rows_cut(AS*, n): the rows from n on go, with what they own, the chunks after them (the last one
#   left made again), the folds that began at or after n (one across it ends before n) and what names them:
#   the calls by id and the waiting calls (agrow_cut), the latest todo row, the pinned turn, the row focus, a
#   pending click, the anchor; at 0 also the calls' table, the day of the last stamped row, the tasks and the
#   reader's own data. session_clear_msgs is n = 0
FN agents_rows_cut
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, [rbx + AS_msgs + VEC_len]
    jbe 1f
    mov r12, [rbx + AS_msgs + VEC_len]
1:  mov rdi, rbx                # the calls of the rows that go leave the table first
    mov rsi, r12
    call agrow_cut
    mov r13, r12
2:  cmp r13, [rbx + AS_msgs + VEC_len]
    jae 3f
    mov rdi, rbx
    mov rsi, r13
    call row_at
    mov rdi, rax
    call msg_free
    inc r13
    jmp 2b
3:  mov [rbx + AS_msgs + VEC_len], r12
    lea rax, [r12 + 63]         # the chunks
    shr rax, HX_SHIFT
    cmp rax, [rbx + AS_hx + VEC_len]
    ja 4f
    mov [rbx + AS_hx + VEC_len], rax
4:  test r12, 63
    jz 5f
    mov rdi, rbx
    lea rsi, [r12 - 1]
    call hx_dirty
5:  mov rcx, [rbx + AS_folds + VEC_len]     # the folds
6:  test rcx, rcx
    jz 7f
    dec rcx
    imul rax, rcx, AF_SIZE
    add rax, [rbx + AS_folds + VEC_ptr]
    movsxd rdx, dword ptr [rax + AF_first]
    cmp rdx, r12
    jb 61f
    mov [rbx + AS_folds + VEC_len], rcx
    jmp 6b
61: movsxd rdx, dword ptr [rax + AF_last]
    cmp rdx, r12
    jb 7f
    lea rdx, [r12 - 1]
    mov [rax + AF_last], edx
7:  movsxd rax, dword ptr [rbx + AS_todo]
    cmp rax, r12
    jl 71f
    mov dword ptr [rbx + AS_todo], -1
71: movsxd rax, dword ptr [rbx + AS_sticky]
    cmp rax, r12
    jl 72f
    mov dword ptr [rbx + AS_sticky], -1
72: cmp [rip + th_aas], rbx     # the anchor
    jne 8f
    movsxd rax, dword ptr [rip + th_arow]
    cmp rax, r12
    jl 8f
    lea rax, [r12 - 1]
    mov [rip + th_arow], eax
    test r12, r12
    jnz 8f
    mov dword ptr [rip + th_follow], 1
8:  test r12, r12
    jnz 9f
    mov qword ptr [rbx + AS_day], -1
    mov rdi, rbx
    call agtask_clear
    mov rdi, [rbx + AS_rdata]
    call mem_free
    mov qword ptr [rbx + AS_rdata], 0
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

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
    mov rdi, [rip + ag_fsmall]
    mov rsi, r15
    mov rdx, rax
    call text_width
    mov r14d, eax
    add r14d, [rip + g_pmt + 4*MI_14]
    add r14d, [rip + g_pmt + 4*MI_4]
    add r14d, [rip + g_pmt + 4*MI_12]
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    PM ecx, MI_20
    PM r8d, MI_4
    mov r9d, [rsp + 4]
    call gfx_round_rect
    mov edi, r12d
    add edi, [rip + g_pmt + 4*MI_3]
    mov esi, r13d
    add esi, [rip + g_pmt + 4*MI_3]
    PM edx, MI_14
    mov rcx, rbx
    call badge
    mov rdi, [rip + ag_fsmall]
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_6]
    add esi, [rip + g_pmt + 4*MI_14]
    add esi, [rip + g_pmt + 4*MI_4]
    mov edx, r13d
    PM ecx, MI_20
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
    mov rdi, [rip + ag_fsmall]
    mov rsi, r15
    mov rdx, rax
    call text_width
    mov r14d, eax
    add r14d, [rip + g_pmt + 4*MI_14]
    add r14d, [rip + g_pmt + 4*MI_4]
    add r14d, [rip + g_pmt + 4*MI_12]
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    PM ecx, MI_20
    PM r8d, MI_4
    mov r9d, [rsp + 4]
    call gfx_round_rect
    mov edi, [rsp]
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, r13d
    add edx, [rip + g_pmt + 4*MI_3]
    PM ecx, MI_14
    mov r8d, [rsp + 8]
    call icon_draw
    mov rdi, [rip + ag_fsmall]
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_6]
    add esi, [rip + g_pmt + 4*MI_14]
    add esi, [rip + g_pmt + 4*MI_4]
    mov edx, r13d
    PM ecx, MI_20
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
    PM eax, MI_40
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
    mov rdi, [rip + ag_fsmall]
    mov rsi, r15
    mov rdx, rax
    call text_width
    mov r14d, eax
    add r14d, [rip + g_pmt + 4*MI_14]
    add r14d, [rip + g_pmt + 4*MI_4]
    add r14d, [rip + g_pmt + 4*MI_12]
    cmp r14d, [rsp + 16]
    cmovg r14d, [rsp + 16]
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    PM ecx, MI_20
    PM r8d, MI_4
    mov r9d, [rsp]
    call gfx_round_rect
    mov edi, IC_BRANCH
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, r13d
    add edx, [rip + g_pmt + 4*MI_3]
    PM ecx, MI_14
    mov r8d, ebx
    call icon_draw
    mov rdi, r15
    call strlen
    mov r9, rax
    mov rdi, [rip + ag_fsmall]
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_6]
    add esi, [rip + g_pmt + 4*MI_14]
    add esi, [rip + g_pmt + 4*MI_4]
    mov edx, r13d
    PM ecx, MI_20
    mov r8, r15
    mov r10d, ebx
    mov r11d, r14d
    sub r11d, [rip + g_pmt + 4*MI_14]
    sub r11d, [rip + g_pmt + 4*MI_4]
    sub r11d, [rip + g_pmt + 4*MI_12]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    lea eax, [r12 + r14]
    EPILOGUE
9:  mov eax, r12d
    EPILOGUE

# FN agents_label_due(unix second): something the panel draws changes by itself then (a countdown in the
#   footer): the panel's poll redraws it once that second has come (agents_tick), with no timer of its own.
#   Called while drawing (agents_draw resets label_due first), so a label that is not drawn asks nothing
FN agents_label_due
    cmp rdi, [rip + label_due]
    jae 1f
    mov [rip + label_due], rdi
1:  ret

# FN agents_web_link(who cstr, url ptr, len): a web link clicked in the panel's bottom area (a band's), asked
#   about once the frame is drawn (reply_follow: links_ask_open, as a reply's link)
FN agents_web_link
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    call links_url_ok
    test eax, eax
    jz 9f
    mov rdi, [rip + pend_link]
    call mem_free
    mov rdi, [rip + pend_cwd]
    call mem_free
    mov qword ptr [rip + pend_cwd], 0
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rip + pend_link], rax
    mov [rip + pend_who], rbx
9:  EPILOGUE

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

# ---------- the thread's engine: heights without walking the conversation ----------
#
# A row's height is exact once it was measured (row_exact) for the key (the width, the panel's text size,
# g_face_gen, ag_gen: row_valid); until then it is an estimate from its byte and line counts (row_parts,
# row_est), O(1). The rows' heights and their gaps are summed per 64 rows (AS_hx, HX records): a chunk nobody
# looks into is its aggregates at any width (hx_value: no step a row), a chunk a row of which is located or
# drawn is its rows' own heights (hx_resolve, HXF_ROWS). A row of height 0 (a hidden call, a folded row) has
# no gap either. The view is kept as a row and an offset (th_arow, th_aoff), so a height that changes above it
# moves nothing; the content offsets (th_top, th_locate) begin with MI_12 above row 0.

# row_at(AS*, index) -> rax AM*
row_at:
    imul rax, rsi, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    ret

# hx_of(AS*, row) -> rax its chunk's HX* (made when the row is the first of a new chunk)
hx_of:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    shr r12, HX_SHIFT
1:  cmp r12, [rbx + AS_hx + VEC_len]
    jb 2f
    lea rdi, [rbx + AS_hx]
    mov esi, HX_SIZE
    call vec_push
    jmp 1b
2:  imul rax, r12, HX_SIZE
    add rax, [rbx + AS_hx + VEC_ptr]
    EPILOGUE

# hx_dirty(AS*, row): that row was added or changed: its chunk's sum and aggregates are made again when needed
hx_dirty:
    PROLOGUE
    call hx_of
    mov dword ptr [rax + HX_flags], 0
    EPILOGUE

# walk_note(row): a frame asked that row's height (print-agent-thread walked=)
walk_note:
    mov rax, rdi
    shr rax, HX_SHIFT
    mov ecx, edi
    and ecx, 63
    mov edx, 1
    shl rdx, cl
    xor ecx, ecx
1:  cmp ecx, [rip + walk_k]
    jae 2f
    lea r8, [rip + walk_c]
    cmp [r8 + rcx*8], rax
    je 3f
    inc ecx
    jmp 1b
2:  cmp ecx, WALK_KEEP
    jae 4f
    lea r8, [rip + walk_c]
    mov [r8 + rcx*8], rax
    lea r8, [rip + walk_m]
    mov qword ptr [r8 + rcx*8], 0
    inc dword ptr [rip + walk_k]
3:  lea r8, [rip + walk_m]
    or [r8 + rcx*8], rdx
    ret
4:  inc dword ptr [rip + walk_x]
    ret

# walk_count() -> eax the rows asked in the frame
walk_count:
    xor eax, eax
    xor ecx, ecx
1:  cmp ecx, [rip + walk_k]
    jae 9f
    lea r8, [rip + walk_m]
    mov rdx, [r8 + rcx*8]
2:  test rdx, rdx
    jz 3f
    lea r9, [rdx - 1]
    and rdx, r9
    inc eax
    jmp 2b
3:  inc ecx
    jmp 1b
9:  add eax, [rip + walk_x]
    ret

# est_lh() -> eax the line height an estimate counts (the panel's text face's, as a row wraps it)
est_lh:
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_3]
    ret

# row_parts(AS*, row) -> eax the pixels of its height that do not depend on the width (no gap), edx its
#   lines and ecx its bytes that wrap; 0, 0, 0: a row of no height at all. O(1): what the estimate and a
#   chunk's aggregates are made of
row_parts:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call row_at
    mov rbx, rax
    cmp qword ptr [rbx + AM_x], 0
    jne 5f
    mov eax, [rbx + AM_role]
    cmp eax, R_THINK
    je 5f
    cmp eax, R_META
    je 5f
    cmp eax, R_COMPACT
    je 5f
    cmp eax, R_UNKNOWN
    je 5f
    test dword ptr [rbx + AM_flags], AMF_PILL
    jnz 3f
    cmp eax, R_TOOL
    je 4f
    PM r14d, MI_40              # a prompt, a reply: the label line and paddings
    cmp eax, R_USER
    je 1f
    cmp eax, R_ASSIST
    je 1f
    PM r14d, MI_20              # a result, an error, a notice: boxed
1:  mov edx, [rbx + AM_nl]
    inc edx
    cmp edx, EST_CAP
    jbe 11f
    mov edx, EST_CAP
11: mov rcx, [rbx + AM_len]
    cmp rcx, EST_CAP
    jbe 12f
    mov ecx, EST_CAP
12: mov eax, r14d
    EPILOGUE
3:  call pill_h
    add eax, [rip + g_pmt + 4*MI_12]
    xor edx, edx
    xor ecx, ecx
    EPILOGUE
4:  PM eax, MI_32
    xor edx, edx
    xor ecx, ecx
    EPILOGUE
5:  mov rdi, r12                # a typed row (agentrows.s)
    mov rsi, r13
    call agrow_est
    EPILOGUE

# row_est(AS*, row, w) -> eax its estimated height at width w
row_est:
    PROLOGUE
    mov r12d, edx
    call row_parts
    mov ebx, eax
    mov r13d, edx
    mov r14d, ecx
    or eax, edx
    or eax, ecx
    jz 9f
    mov r15d, r12d
    cmp r15d, 1
    jge 1f
    mov r15d, 1
1:  mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_cellw]
    imul rax, r14
    xor edx, edx
    div r15                     # lines its bytes fill at the width
    add rax, r13
    mov r8, rax
    call est_lh
    imul rax, r8
    add rax, rbx
    mov ecx, HX_CAP
    cmp rax, rcx
    cmova rax, rcx
9:  EPILOGUE

# row_valid(AM*, w) -> eax 1 when AM_h is its exact height for the key
row_valid:
    xor eax, eax
    cmp [rdi + AM_w], esi
    jne 9f
    mov ecx, [rdi + AM_hrev]
    cmp ecx, [rdi + AM_rev]
    jne 9f
    mov rcx, [rip + ag_fui]
    mov ecx, [rcx + FACE_px]
    cmp ecx, [rdi + AM_hpx]
    jne 9f
    push rax
    call face_key
    mov ecx, eax
    pop rax
    cmp ecx, [rdi + AM_hgen]
    jne 9f
    mov ecx, [rip + ag_gen]
    cmp ecx, [rdi + AM_hag]
    jne 9f
    mov eax, 1
9:  ret

# row_h0(AS*, row, w) -> eax what the sums use for it before the fold: exact when cached, else the estimate
row_h0:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    call row_at
    mov rdi, rax
    mov esi, r13d
    mov r14, rax
    call row_valid
    test eax, eax
    jz 1f
    mov eax, [r14 + AM_h]
    EPILOGUE
1:  mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call row_est
    EPILOGUE

# FN row_h(AS*, index, w) -> eax the height the sums use: exact when it is cached for the key, else the
#   estimate (AMF_EST), 0 for a row a fold hides. Every caller of msg_height but the engine goes through it
FN row_h
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rdi, rsi
    call walk_note
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call row_h0
    mov ecx, eax
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call agfold_h
    EPILOGUE

# FN row_exact(AS*, index, w) -> eax measured now when it was not for the key (msg_height's work: a reply's
#   Markdown parsed if never, a typed row laid out; agentrows.s for typed rows); its chunk's sum follows
FN row_exact
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rdi, rsi
    call walk_note
    mov rdi, rbx
    mov rsi, r12
    call row_at
    mov r14, rax
    mov rdi, rax
    mov esi, r13d
    call row_valid
    test eax, eax
    jnz 8f
    mov rdi, rbx                # what its chunk's sum counted for it: the estimate
    mov rsi, r12
    mov edx, r13d
    call row_est
    mov ecx, eax
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call agfold_h
    mov [rsp], eax
    mov rdi, rbx                # measured
    mov rsi, r12
    mov edx, r13d
    call row_measure
    mov r15d, eax
    mov rdi, rbx
    mov rsi, r12
    call row_at
    mov r14, rax
    mov [r14 + AM_h], r15d
    mov [r14 + AM_w], r13d
    mov eax, [r14 + AM_rev]
    mov [r14 + AM_hrev], eax
    call panel_px
    mov [r14 + AM_hpx], eax
    call face_key
    mov [r14 + AM_hgen], eax
    mov eax, [rip + ag_gen]
    mov [r14 + AM_hag], eax
    and dword ptr [r14 + AM_flags], ~AMF_EST
    mov ecx, r15d
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call agfold_h
    mov r15d, eax
    mov rdi, rbx                # a chunk summed from its rows: by what it changed
    mov rsi, r12
    call hx_of
    test dword ptr [rax + HX_flags], HXF_ROWS
    jz 9f
    mov ecx, r15d
    test ecx, ecx
    jz 1f
    add ecx, [rip + g_pmt + 4*MI_8]
1:  mov edx, [rsp]
    test edx, edx
    jz 2f
    add edx, [rip + g_pmt + 4*MI_8]
2:  sub ecx, edx
    add [rax + HX_sum], ecx
    jmp 9f
8:  mov ecx, [r14 + AM_h]
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call agfold_h
    mov r15d, eax
9:  mov eax, r15d
    EPILOGUE

# row_measure(AS*, row, w) -> eax its height measured now: a typed row by agentrows.s, any other by
#   msg_height (a reply's Markdown parsed when it has none or its text changed)
row_measure:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    call row_at
    mov r14, rax
    cmp qword ptr [r14 + AM_x], 0
    jne 5f
    mov eax, [r14 + AM_role]
    cmp eax, R_THINK
    je 5f
    cmp eax, R_META
    je 5f
    cmp eax, R_COMPACT
    je 5f
    cmp eax, R_UNKNOWN
    je 5f
    mov dword ptr [r14 + AM_w], -1      # msg_height's own cache says nothing of ag_gen
    mov rdi, r14
    mov esi, r13d
    call msg_height
    EPILOGUE
5:  mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call agrow_h
    EPILOGUE

# hx_agg(AS*, chunk): its aggregates from its rows' parts (no height asked)
hx_agg:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    imul r15, r12, HX_SIZE
    add r15, [rbx + AS_hx + VEC_ptr]
    mov dword ptr [r15 + HX_fix], 0
    mov dword ptr [r15 + HX_lines], 0
    mov dword ptr [r15 + HX_bytes], 0
    mov r13, r12
    shl r13, HX_SHIFT
    lea r14, [r13 + 64]
    cmp r14, [rbx + AS_msgs + VEC_len]
    jbe 1f
    mov r14, [rbx + AS_msgs + VEC_len]
1:  cmp r13, r14
    jae 9f
    mov rdi, rbx
    mov rsi, r13
    call row_parts
    imul r15, r12, HX_SIZE
    add r15, [rbx + AS_hx + VEC_ptr]
    mov r8d, eax
    or r8d, edx
    or r8d, ecx
    jz 2f
    add eax, [rip + g_pmt + 4*MI_8]
    add [r15 + HX_fix], eax
    mov r8d, [r15 + HX_lines]
    add r8, rdx
    mov r9d, 0x3fffffff
    cmp r8, r9
    cmova r8, r9
    mov [r15 + HX_lines], r8d
    mov r8d, [r15 + HX_bytes]
    add r8, rcx
    cmp r8, r9
    cmova r8, r9
    mov [r15 + HX_bytes], r8d
2:  inc r13
    jmp 1b
9:  imul r15, r12, HX_SIZE
    add r15, [rbx + AS_hx + VEC_ptr]
    or dword ptr [r15 + HX_flags], HXF_AGG
    EPILOGUE

# hx_value(AS*, chunk, w) -> eax its height: its rows' own sum when it has one, else its aggregates at the
#   width (one step, whatever the width)
hx_value:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    imul r14, r12, HX_SIZE
    add r14, [rbx + AS_hx + VEC_ptr]
    test dword ptr [r14 + HX_flags], HXF_ROWS
    jz 1f
    mov eax, [r14 + HX_sum]
    EPILOGUE
1:  test dword ptr [r14 + HX_flags], HXF_AGG
    jnz 2f
    call hx_agg
    imul r14, r12, HX_SIZE
    add r14, [rbx + AS_hx + VEC_ptr]
2:  mov r15d, r13d
    cmp r15d, 1
    jge 3f
    mov r15d, 1
3:  mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_cellw]
    mov ecx, [r14 + HX_bytes]
    imul rax, rcx
    xor edx, edx
    div r15
    mov ecx, [r14 + HX_lines]
    add rax, rcx
    mov r8, rax
    call est_lh
    imul rax, r8
    mov ecx, [r14 + HX_fix]
    add rax, rcx
    mov ecx, HX_CAP
    cmp rax, rcx
    cmova rax, rcx
    EPILOGUE

# hx_resolve(AS*, chunk, w) -> eax its rows' own sum, kept (HXF_ROWS): its rows' heights asked once
hx_resolve:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    xor r15d, r15d
    mov r14, r12
    shl r14, HX_SHIFT
1:  mov rax, r12
    shl rax, HX_SHIFT
    add rax, 64
    cmp r14, rax
    jae 3f
    cmp r14, [rbx + AS_msgs + VEC_len]
    jae 3f
    mov rdi, rbx
    mov rsi, r14
    mov edx, r13d
    call row_h
    test eax, eax
    jz 2f
    add eax, [rip + g_pmt + 4*MI_8]
    add r15d, eax
2:  inc r14
    jmp 1b
3:  imul rax, r12, HX_SIZE
    add rax, [rbx + AS_hx + VEC_ptr]
    mov [rax + HX_sum], r15d
    or dword ptr [rax + HX_flags], HXF_ROWS
    mov eax, r15d
    EPILOGUE

# th_key(AS*, w): the sums are for this width, text size, g_face_gen and ag_gen. A text size or ag_gen
#   change drops every chunk's aggregates (made again once, from the rows' parts); a width or face change
#   only drops the chunks' own sums (a step a chunk, no step a row)
th_key:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call panel_px
    mov r13d, eax
    xor r14d, r14d              # the flags kept
    cmp [rbx + AS_hkey + 4], r13d
    jne 2f
    mov eax, [rip + ag_gen]
    cmp [rbx + AS_hkey + 12], eax
    jne 2f
    mov r14d, HXF_AGG
    cmp [rbx + AS_hkey], r12d
    jne 2f
    call face_key
    cmp [rbx + AS_hkey + 8], eax
    jne 2f
    EPILOGUE
2:  mov [rbx + AS_hkey], r12d
    mov [rbx + AS_hkey + 4], r13d
    call face_key
    mov [rbx + AS_hkey + 8], eax
    mov eax, [rip + ag_gen]
    mov [rbx + AS_hkey + 12], eax
    xor ecx, ecx
3:  cmp rcx, [rbx + AS_hx + VEC_len]
    jae 9f
    imul rax, rcx, HX_SIZE
    add rax, [rbx + AS_hx + VEC_ptr]
    and [rax + HX_flags], r14d
    inc rcx
    jmp 3b
9:  EPILOGUE

# th_rows_h(AS*, w) -> eax the rows' part of the content: every chunk's height
th_rows_h:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call th_key
    xor r13d, r13d
    xor r14d, r14d
1:  cmp r14, [rbx + AS_hx + VEC_len]
    jae 9f
    mov rdi, rbx
    mov rsi, r14
    mov edx, r12d
    call hx_value
    add r13d, eax
    inc r14
    jmp 1b
9:  mov eax, r13d
    EPILOGUE

# th_after(AS*, w) -> eax what follows the rows: the spinner, the task lines, the queued messages (each with
#   its gap)
th_after:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    call agspin_h
    mov r13d, eax
    mov rdi, rbx
    mov esi, r12d
    call agtask_h
    add r13d, eax
    mov rdi, rbx
    call queued_sync
    mov r14d, eax
    xor r15d, r15d
1:  cmp r15d, r14d
    jae 9f
    imul rdi, r15, AM_SIZE
    lea rax, [rip + qrows]
    add rdi, rax
    mov esi, r12d
    call msg_height
    add r13d, eax
    add r13d, [rip + g_pmt + 4*MI_8]
    inc r15d
    jmp 1b
9:  mov eax, r13d
    EPILOGUE

# FN th_total(AS*, w) -> eax the content's height: MI_12 above the first row, the chunk sums (a chunk without
#   its rows' own sum from its aggregates), the spinner, the task lines, the queued rows, MI_20 below
FN th_total
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call th_rows_h
    mov r13d, eax
    mov rdi, rbx
    mov esi, r12d
    call th_after
    add eax, r13d
    add eax, [rip + g_pmt + 4*MI_12]
    add eax, [rip + g_pmt + 4*MI_20]
    EPILOGUE

# FN th_locate(AS*, y, w) -> rax the row at that offset of the content, edx its top (-1 and MI_12 without
#   rows): the chunks' sums, then the rows of the one chunk it is in (resolved). Above row 0: row 0; past
#   the last row: the last row
FN th_locate
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov esi, edx
    call th_key
    PM r15d, MI_12              # the offset reached
    cmp qword ptr [rbx + AS_msgs + VEC_len], 0
    jne 1f
    mov rax, -1
    mov edx, r15d
    EPILOGUE
1:  cmp r12d, r15d
    jge 2f
    xor eax, eax
    mov edx, r15d
    EPILOGUE
2:  xor r14d, r14d              # the chunk
3:  mov rax, [rbx + AS_hx + VEC_len]
    dec rax
    mov [rsp + 8], rax          # the last chunk
    mov rdi, rbx
    mov rsi, r14
    mov edx, r13d
    call hx_value
    cmp r14, [rsp + 8]
    jae 4f                      # the last chunk: it is there
    lea ecx, [r15 + rax]
    cmp r12d, ecx
    jl 4f
    mov r15d, ecx
    inc r14
    jmp 3b
4:  imul rax, r14, HX_SIZE      # its rows (resolved: their own sum may say it is the next chunk)
    add rax, [rbx + AS_hx + VEC_ptr]
    test dword ptr [rax + HX_flags], HXF_ROWS
    jnz 5f
    mov rdi, rbx
    mov rsi, r14
    mov edx, r13d
    call hx_resolve
    cmp r14, [rsp + 8]
    jae 5f
    lea ecx, [r15 + rax]
    cmp r12d, ecx
    jl 5f
    mov r15d, ecx
    inc r14
    jmp 3b
5:  shl r14, HX_SHIFT
    lea rax, [r14 + 64]
    cmp rax, [rbx + AS_msgs + VEC_len]
    jbe 6f
    mov rax, [rbx + AS_msgs + VEC_len]
6:  dec rax
    mov [rsp], rax              # the chunk's last row
7:  mov rdi, rbx
    mov rsi, r14
    mov edx, r13d
    call row_h
    test eax, eax
    jz 8f
    add eax, [rip + g_pmt + 4*MI_8]
8:  cmp r14, [rsp]
    jae 9f
    lea ecx, [r15 + rax]
    cmp r12d, ecx
    jl 9f
    mov r15d, ecx
    inc r14
    jmp 7b
9:  mov rax, r14
    mov edx, r15d
    EPILOGUE

# FN th_top(AS*, index, w) -> eax a row's offset in the content: the chunks before its chunk, then its rows
#   before it (its chunk resolved)
FN th_top
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov esi, edx
    call th_key
    PM r15d, MI_12
    xor r14d, r14d
1:  mov rax, r12
    shr rax, HX_SHIFT
    cmp r14, rax
    jae 2f
    mov rdi, rbx
    mov rsi, r14
    mov edx, r13d
    call hx_value
    add r15d, eax
    inc r14
    jmp 1b
2:  cmp r14, [rbx + AS_hx + VEC_len]
    jae 9f
    imul rax, r14, HX_SIZE
    add rax, [rbx + AS_hx + VEC_ptr]
    test dword ptr [rax + HX_flags], HXF_ROWS
    jnz 3f
    mov rdi, rbx
    mov rsi, r14
    mov edx, r13d
    call hx_resolve
3:  shl r14, HX_SHIFT
4:  cmp r14, r12
    jae 9f
    mov rdi, rbx
    mov rsi, r14
    mov edx, r13d
    call row_h
    test eax, eax
    jz 5f
    add eax, [rip + g_pmt + 4*MI_8]
5:  add r15d, eax
    inc r14
    jmp 4b
9:  mov eax, r15d
    EPILOGUE

# face_key() -> eax what the panel's faces are, as heights depend on them: the text and small faces' sizes
#   and line heights, the interface's and the editor's fonts. (Not g_face_gen: Markdown's sized faces move it
#   on when documents of other sizes are laid out, which would make every row's height stale every frame)
face_key:
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_px]
    imul eax, eax, 31
    mov rcx, [rip + ag_fui]
    add eax, [rcx + FACE_lineh]
    imul eax, eax, 31
    mov rcx, [rip + ag_fsmall]
    add eax, [rcx + FACE_lineh]
    imul eax, eax, 31
    add eax, [rip + g_face_code + FACE_px]
    imul eax, eax, 31
    mov rcx, [rip + g_face_code + FACE_font]
    add eax, ecx
    imul eax, eax, 31
    mov rcx, [rip + g_face_ui + FACE_font]
    add eax, ecx
    ret

# gap_of(h) -> eax h and the gap after it (none after a row of no height)
gap_of:
    mov eax, edi
    test eax, eax
    jz 1f
    add eax, [rip + g_pmt + 4*MI_8]
1:  ret

# FN agents_view_changed(): a setting or a state that changes heights (focus view, timestamps, thinking
#   open, a fold): ag_gen moves on (every chunk's aggregates and every row's height are made again, once)
FN agents_view_changed
    inc dword ptr [rip + ag_gen]
    mov dword ptr [rip + g_dirty], 1
    ret

# th_begin(AS*, w): a frame of the thread begins: its serial, the session, the width, the rows asked counted
#   from 0, the sums' key
th_begin:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    inc dword ptr [rip + th_serial]
    mov [rip + th_as], rbx
    mov [rip + th_textw], r12d
    mov dword ptr [rip + walk_k], 0
    mov dword ptr [rip + walk_x], 0
    mov rdi, rbx
    mov esi, r12d
    call th_key
    EPILOGUE

# th_resolve_rows(AS*, first, last, w): the chunks of those rows summed from their rows (the rows in view:
#   the content's height is right around them)
th_resolve_rows:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    shr r12, HX_SHIFT
    mov r13, rdx
    shr r13, HX_SHIFT
    mov r14d, ecx
1:  cmp r12, r13
    ja 9f
    cmp r12, [rbx + AS_hx + VEC_len]
    jae 9f
    imul rax, r12, HX_SIZE
    add rax, [rbx + AS_hx + VEC_ptr]
    test dword ptr [rax + HX_flags], HXF_ROWS
    jnz 2f
    mov rdi, rbx
    mov rsi, r12
    mov edx, r14d
    call hx_resolve
2:  inc r12
    jmp 1b
9:  EPILOGUE

# th_end(AS*, w, area h): the last rows measured exactly until they fill the area, and their chunks summed
#   from their rows: the end of the content is exact (following: the last row's bottom is the area's)
th_end:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14, [rbx + AS_msgs + VEC_len]
    test r14, r14
    jz 9f
    dec r14
    xor r15d, r15d
1:  test r14, r14
    js 2f
    cmp r15d, r13d
    jge 2f
    mov rdi, rbx
    mov rsi, r14
    mov edx, r12d
    call row_exact
    mov edi, eax
    call gap_of
    add r15d, eax
    dec r14
    jmp 1b
2:  lea rsi, [r14 + 1]
    mov rdx, [rbx + AS_msgs + VEC_len]
    dec rdx
    mov rdi, rbx
    mov ecx, r12d
    call th_resolve_rows
9:  EPILOGUE

# th_step(AS*, w): the anchor (lay_row, lay_off) moved to the row under the top edge again after its offset
#   changed (a wheel step, a page): over the rows passed, measured exactly, so the rows in view move by the
#   step alone. Above row 0 it stops at the content's top (-MI_12)
th_step:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
1:  mov eax, [rip + lay_off]
    test eax, eax
    jns 3f
    cmp qword ptr [rip + lay_row], 0
    jg 2f
    PM ecx, MI_12
    neg ecx
    cmp eax, ecx
    jge 9f
    mov [rip + lay_off], ecx
    jmp 9f
2:  dec qword ptr [rip + lay_row]
    mov rdi, rbx
    mov rsi, [rip + lay_row]
    mov edx, r12d
    call row_exact
    mov edi, eax
    call gap_of
    add [rip + lay_off], eax
    jmp 1b
3:  mov rdi, rbx
    mov rsi, [rip + lay_row]
    mov edx, r12d
    call row_exact
    mov edi, eax
    call gap_of
    cmp [rip + lay_off], eax
    jl 9f
    mov rcx, [rbx + AS_msgs + VEC_len]
    dec rcx
    cmp [rip + lay_row], rcx
    jge 9f
    sub [rip + lay_off], eax
    inc qword ptr [rip + lay_row]
    jmp 1b
9:  EPILOGUE

# th_view(AS*, w, area h): the rows in view from the anchor measured exactly (a reply's Markdown parsed
#   the first time), their chunks summed from their rows
th_view:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14, [rip + lay_row]
    test r14, r14
    js 9f
    mov r15d, [rip + lay_off]
    neg r15d                    # the row's top in the area
1:  cmp r14, [rbx + AS_msgs + VEC_len]
    jae 2f
    cmp r15d, r13d
    jge 2f
    mov rdi, rbx
    mov rsi, r14
    mov edx, r12d
    call row_exact
    mov edi, eax
    call gap_of
    add r15d, eax
    inc r14
    jmp 1b
2:  lea rdx, [r14 - 1]
    mov rsi, [rip + lay_row]
    cmp rdx, rsi
    jge 3f
    mov rdx, rsi
3:  mov rdi, rbx
    mov ecx, r12d
    call th_resolve_rows
9:  EPILOGUE

# th_from_end(AS*, w, area h): following: the end made exact, the scroll its largest, the anchor the row at it
th_from_end:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    call th_end
    mov rdi, rbx
    mov esi, r12d
    call th_total
    sub eax, r13d
    jns 1f
    xor eax, eax
1:  mov r14d, eax
    mov rdi, rbx
    mov esi, r14d
    mov edx, r12d
    call th_locate
    mov [rip + lay_row], rax
    sub r14d, edx
    mov [rip + lay_off], r14d
    EPILOGUE

# th_layout(AS*, frame*): where the thread is this frame (frame: thread_draw's, x [0], w [8], the area's y
#   [20] and h [24], the text width [32]). Following: the end. Else the anchor of the last frame (th_arow,
#   th_aoff), or the row at th_scroll when it has none (the scrollbar moved it). The wheel moves the anchor
#   over rows measured exactly; the rows in view are measured; th_scroll is derived from the anchor
#   (th_top), th_content and th_max from the sums. Sets lay_row and lay_off: the row drawn first, at the
#   area's top less lay_off
th_layout:
    PROLOGUE 16
    mov rbx, rdi
    mov r14, rsi
    mov r12d, [r14 + 32]        # the width
    mov r13d, [r14 + 24]        # the area's height
    mov dword ptr [rsp], 0      # the wheel
    mov edi, [r14]
    mov esi, [r14 + 20]
    mov edx, [r14 + 8]
    mov ecx, [r14 + 24]
    call ui_in
    test eax, eax
    jz 1f
    mov eax, [rip + g_scroll_y]
    mov [rsp], eax
1:  cmp [rip + th_aas], rbx
    je 2f
    mov [rip + th_aas], rbx     # another conversation: it starts at its end
    mov dword ptr [rip + th_follow], 1
2:  cmp qword ptr [rbx + AS_msgs + VEC_len], 0
    jne 3f
    mov qword ptr [rip + lay_row], -1
    PM eax, MI_12
    neg eax
    mov [rip + lay_off], eax
    mov dword ptr [rip + th_follow], 1
    mov dword ptr [rip + th_scroll], 0
    jmp 8f
3:  cmp dword ptr [rip + th_follow], 0
    jne 5f
    movsxd rax, dword ptr [rip + th_arow]
    test rax, rax
    js 4f
    cmp rax, [rbx + AS_msgs + VEC_len]
    jae 4f
    mov [rip + lay_row], rax
    mov eax, [rip + th_aoff]
    mov [rip + lay_off], eax
    jmp 6f
4:  mov rdi, rbx                # no anchor (the scrollbar was dragged): the row at the scroll
    mov esi, [rip + th_scroll]
    mov edx, r12d
    call th_locate
    mov [rip + lay_row], rax
    mov eax, [rip + th_scroll]
    sub eax, edx
    mov [rip + lay_off], eax
    jmp 6f
5:  mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    call th_from_end
6:  mov eax, [rsp]
    add eax, [rip + th_pend]    # a page key's step joins the wheel's
    mov dword ptr [rip + th_pend], 0
    test eax, eax
    jz 7f
    mov dword ptr [rip + th_follow], 0
    add [rip + lay_off], eax
    mov dword ptr [rsp], 0
7:  mov rdi, rbx
    mov esi, r12d
    call th_step
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    call th_view
    mov rdi, rbx
    mov rsi, [rip + lay_row]
    mov edx, r12d
    call th_top
    add eax, [rip + lay_off]
    mov [rsp + 4], eax          # the scroll
    cmp dword ptr [rip + th_follow], 0
    jne 8f
    mov rdi, rbx
    mov esi, r12d
    call th_total
    sub eax, r13d
    jns 71f
    xor eax, eax
71: cmp [rsp + 4], eax
    jl 72f
    mov dword ptr [rip + th_follow], 1      # at the end: it follows again
    jmp 5b
72: mov eax, [rsp + 4]
    test eax, eax
    jns 73f
    xor eax, eax
73: mov [rip + th_scroll], eax
8:  mov rdi, rbx
    mov esi, r12d
    call th_total
    mov [rip + th_content], eax
    sub eax, r13d
    jns 81f
    xor eax, eax
81: mov [rip + th_max], eax
    cmp dword ptr [rip + th_follow], 0
    je 82f
    mov [rip + th_scroll], eax
    mov dword ptr [rip + th_arow], -1
    mov dword ptr [rip + th_aoff], 0
    EPILOGUE
82: mov rax, [rip + lay_row]
    mov [rip + th_arow], eax
    mov eax, [rip + lay_off]
    mov [rip + th_aoff], eax
    EPILOGUE

# th_reanchor(AS*): th_scroll was set from outside the layout (the scrollbar, a key): the anchor is the row
#   at it, or the end when it is the largest
th_reanchor:
    PROLOGUE
    mov rbx, rdi
    mov eax, [rip + th_scroll]
    cmp eax, [rip + th_max]
    jl 1f
    mov dword ptr [rip + th_follow], 1
    mov dword ptr [rip + th_arow], -1
    jmp 9f
1:  mov dword ptr [rip + th_follow], 0
    test eax, eax
    jns 2f
    mov dword ptr [rip + th_scroll], 0
2:  mov rdi, rbx
    mov esi, [rip + th_scroll]
    mov edx, [rip + th_textw]
    call th_locate
    mov [rip + th_arow], eax
    mov ecx, [rip + th_scroll]
    sub ecx, edx
    mov [rip + th_aoff], ecx
9:  mov [rip + th_aas], rbx
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agents_thread_dump(sb): print-agent-thread, the open conversation's engine as the last frame left it:
#   "rows=N content=PX scroll=N max=N follow=0|1 anchor=ROW+PX|- first=N last=N exact=N est=N chunks=N
#   resolved=N walked=N gen=N focus=N|- think=0|1 sticky=N|- calls=N folds=N" (walked: the rows whose height
#   the last frame asked; exact and est: the rows whose height is measured for the width drawn last, or not)
FN agents_thread_dump
    PROLOGUE 16
    mov r15, rdi
    mov rax, [rip + view]
    test rax, rax
    js 9f
    cmp rax, [rip + sessions + VEC_len]
    jae 9f
    mov rcx, [rip + sessions + VEC_ptr]
    mov rbx, [rcx + rax*8]
    lea rsi, [rip + .Lt_rows]
    mov rdx, [rbx + AS_msgs + VEC_len]
    call td_num
    lea rsi, [rip + .Lt_content]
    mov edx, [rip + th_content]
    call td_num
    lea rsi, [rip + .Lt_scroll]
    mov edx, [rip + th_scroll]
    call td_num
    lea rsi, [rip + .Lt_max]
    mov edx, [rip + th_max]
    call td_num
    lea rsi, [rip + .Lt_follow]
    mov edx, [rip + th_follow]
    call td_num
    mov rdi, r15
    lea rsi, [rip + .Lt_anchor]
    call sb_push_cstr
    cmp dword ptr [rip + th_arow], 0
    jl 1f
    mov rdi, r15
    mov esi, [rip + th_arow]
    call sb_push_u64
    mov rdi, r15
    mov esi, '+'
    call sb_push_byte
    mov rdi, r15
    mov esi, [rip + th_aoff]
    call md_push_int
    jmp 2f
1:  mov rdi, r15
    mov esi, '-'
    call sb_push_byte
2:  lea rsi, [rip + .Lt_first]
    movsxd rdx, dword ptr [rip + th_first]
    call td_int
    lea rsi, [rip + .Lt_last]
    movsxd rdx, dword ptr [rip + th_last]
    call td_int
    xor r12d, r12d              # exact and estimated rows
    xor r13d, r13d
    xor r14d, r14d
3:  cmp r14, [rbx + AS_msgs + VEC_len]
    jae 4f
    mov rdi, rbx
    mov rsi, r14
    call row_at
    mov rdi, rax
    mov esi, [rip + th_textw]
    call row_valid
    add r12d, eax
    xor eax, 1
    add r13d, eax
    inc r14
    jmp 3b
4:  lea rsi, [rip + .Lt_exact]
    mov edx, r12d
    call td_num
    lea rsi, [rip + .Lt_est]
    mov edx, r13d
    call td_num
    lea rsi, [rip + .Lt_chunks]
    mov rdx, [rbx + AS_hx + VEC_len]
    call td_num
    xor r12d, r12d
    xor r14d, r14d
5:  cmp r14, [rbx + AS_hx + VEC_len]
    jae 6f
    imul rax, r14, HX_SIZE
    add rax, [rbx + AS_hx + VEC_ptr]
    mov eax, [rax + HX_flags]
    and eax, HXF_ROWS
    add r12d, eax
    inc r14
    jmp 5b
6:  lea rsi, [rip + .Lt_resolved]
    mov edx, r12d
    call td_num
    call walk_count
    lea rsi, [rip + .Lt_walked]
    mov edx, eax
    call td_num
    lea rsi, [rip + .Lt_gen]
    mov edx, [rip + ag_gen]
    call td_num
    call agrow_focus
    lea rsi, [rip + .Lt_focus]
    mov rdx, rax
    call td_opt
    call agrow_think
    lea rsi, [rip + .Lt_think]
    mov edx, eax
    call td_num
    lea rsi, [rip + .Lt_sticky]
    movsxd rdx, dword ptr [rbx + AS_sticky]
    cmp qword ptr [rbx + AS_msgs + VEC_len], 0
    jne 7f
    mov rdx, -1
7:  call td_opt
    lea rsi, [rip + .Lt_calls]
    mov edx, [rbx + AS_ncalls]
    call td_num
    lea rsi, [rip + .Lt_folds]
    mov rdx, [rbx + AS_folds + VEC_len]
    call td_num
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# td_num(rsi label, rdx value) using r15 = sb: " LABEL=N" (the label holds its blank and "="); td_int signed;
#   td_opt: N, or "-" when it is negative
td_num:
    push rdx
    push rdx
    mov rdi, r15
    call sb_push_cstr
    pop rsi
    pop rsi
    mov esi, esi
    mov rdi, r15
    jmp sb_push_u64
td_int:
    push rdx
    push rdx
    mov rdi, r15
    call sb_push_cstr
    pop rsi
    pop rsi
    mov rdi, r15
    jmp md_push_int
td_opt:
    push rdx
    push rdx
    mov rdi, r15
    call sb_push_cstr
    pop rsi
    pop rsi
    test rsi, rsi
    js 1f
    mov rdi, r15
    jmp sb_push_u64
1:  mov rdi, r15
    mov esi, '-'
    jmp sb_push_byte

.section .rodata
.Lt_rows: .asciz "rows="
.Lt_content: .asciz " content="
.Lt_scroll: .asciz " scroll="
.Lt_max: .asciz " max="
.Lt_follow: .asciz " follow="
.Lt_anchor: .asciz " anchor="
.Lt_first: .asciz " first="
.Lt_last: .asciz " last="
.Lt_exact: .asciz " exact="
.Lt_est: .asciz " est="
.Lt_chunks: .asciz " chunks="
.Lt_resolved: .asciz " resolved="
.Lt_walked: .asciz " walked="
.Lt_gen: .asciz " gen="
.Lt_focus: .asciz " focus="
.Lt_think: .asciz " think="
.Lt_sticky: .asciz " sticky="
.Lt_calls: .asciz " calls="
.Lt_folds: .asciz " folds="
.text

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
F WR_mute, 8            # the byte drawn muted from on (a prompt's truncation marker), -1 none
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
    mov rax, [rbx + WR_mute]    # muted from WR_mute on
    test rax, rax
    js 51f
    cmp rax, [rsp + 8]
    jae 51f
    cmp rax, r13
    ja 52f
    COLOR r9d, T_MUTED
51: call text_draw
    jmp 5f
52: mov [rsp + 40], edx         # the line's part before it, then the rest muted
    mov r8, rax
    sub r8, r13
    call text_draw
    mov esi, eax
    mov edx, [rsp + 40]
    mov rdi, [rbx + WR_face]
    mov rcx, [rbx + WR_text]
    add rcx, [rbx + WR_mute]
    mov r8, [rsp + 8]
    sub r8, [rbx + WR_mute]
    COLOR r9d, T_MUTED
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

# msg_height(msg, width) -> px, cached for the width, its text's revision, the text size, the faces and
#   whether its Markdown gave it: the measure of a row that is not typed (row_exact calls it for the rows
#   in view; the queued rows have no engine). A reply is as tall as its Markdown at the width, parsed now
#   when it has none or its text changed (a growing reply: at most once a frame); nothing else parses
msg_height:
    PROLOGUE 96
    mov rbx, rdi
    mov r12d, esi
    xor r13d, r13d              # 1: its document gives the height
    cmp dword ptr [rbx + AM_role], R_ASSIST
    jne 11f
    mov r13d, 1
    mov rdi, rbx
    call msg_doc
11: cmp [rbx + AM_w], r12d
    jne 1f
    mov eax, [rbx + AM_hrev]
    cmp eax, [rbx + AM_rev]
    jne 1f
    call panel_px
    cmp eax, [rbx + AM_hpx]
    jne 1f
    mov eax, [rip + g_face_gen]
    cmp eax, [rbx + AM_hgen]
    jne 1f
    cmp r13d, [rbx + AM_hdoc]
    jne 1f
    mov eax, [rbx + AM_h]
    EPILOGUE
1:  test r13d, r13d
    jz 12f
    mov rdi, [rbx + AM_doc]
    mov esi, r12d
    call md_layout
    add eax, [rip + g_pmt + 4*MI_40]
    jmp 9f
12: test dword ptr [rbx + AM_flags], AMF_PILL
    jz 13f
    call pill_h                 # a pill: one line of the small face, framed
    add eax, [rip + g_pmt + 4*MI_12]
    jmp 9f
13: mov eax, [rbx + AM_role]
    cmp eax, R_TOOL
    jne 2f
    PM eax, MI_32
    jmp 9f
2:  lea rdi, [rsp]
    call wr_setup
    mov dword ptr [rsp + WR_draw], 0
    lea rdi, [rsp]
    call wrap
    imul eax, [rsp + WR_lh]
    mov ecx, [rbx + AM_role]
    cmp ecx, R_USER
    je 3f
    cmp ecx, R_ASSIST
    je 3f
    add eax, [rip + g_pmt + 4*MI_20]    # results, errors and notices are boxed
    jmp 9f
3:  add eax, [rip + g_pmt + 4*MI_40]
9:  mov [rbx + AM_h], eax
    mov [rbx + AM_w], r12d
    mov r14d, eax
    mov eax, [rbx + AM_rev]
    mov [rbx + AM_hrev], eax
    call panel_px
    mov [rbx + AM_hpx], eax
    mov eax, [rip + g_face_gen] # after md_layout: it may have made the faces of its size
    mov [rbx + AM_hgen], eax
    mov [rbx + AM_hdoc], r13d
    mov eax, r14d
    EPILOGUE

# pill_h() -> eax a pill's frame: a line of the panel's small face and MI_6 above and below it
pill_h:
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_6]
    add eax, [rip + g_pmt + 4*MI_6]
    ret

# panel_px() -> eax the size of the agents panel's text, pixels (agentfont.s)
panel_px:
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_px]
    ret

# msg_doc(msg) -> rax a reply's Markdown, parsed now when it has none or its text changed since, and
#   at the panel's text size
msg_doc:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AM_doc]
    test r12, r12
    jz 1f
    mov eax, [rbx + AM_drev]
    cmp eax, [rbx + AM_rev]
    je 2f
1:  mov rdi, r12
    call md_free
    mov rdi, [rbx + AM_text]
    mov rsi, [rbx + AM_len]
    call md_new
    mov r12, rax
    mov [rbx + AM_doc], rax
    mov eax, [rbx + AM_rev]
    mov [rbx + AM_drev], eax
    mov dword ptr [rbx + AM_dpx], 0
    mov rdi, r12
    mov esi, 1
    call md_set_compact
    inc qword ptr [rip + md_parses]
2:  call panel_px
    cmp eax, [rbx + AM_dpx]
    je 9f
    mov [rbx + AM_dpx], eax
    mov rdi, r12
    mov esi, eax
    call md_set_size
9:  mov rax, r12
    EPILOGUE

# wr_setup(WR*) using rbx = msg, r12d = width. Measuring (msg_height) and drawing (draw_msg) share it,
# so a message wraps the same in both.
wr_setup:
    mov qword ptr [rdi + WR_mute], -1
    mov rax, [rbx + AM_text]
    mov [rdi + WR_text], rax
    mov rax, [rbx + AM_len]
    mov [rdi + WR_len], rax
    mov [rdi + WR_w], r12d
    mov rax, [rip + ag_fui]
    mov ecx, [rax + FACE_lineh]
    cmp dword ptr [rbx + AM_role], R_USER
    je 1f
    cmp dword ptr [rbx + AM_role], R_ASSIST
    je 1f                       # results, errors and notices are boxed
    mov rax, [rip + ag_fsmall]
    mov ecx, [rax + FACE_lineh]
    mov edx, r12d               # a result's box insets its text
    sub edx, [rip + g_pmt + 4*MI_16]
    mov [rdi + WR_w], edx
1:  mov [rdi + WR_face], rax
    add ecx, [rip + g_pmt + 4*MI_3]
    mov [rdi + WR_lh], ecx
    ret

# agents_draw(x, y, w, h)
FN agents_draw
    PROLOGUE 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    call agents_metrics         # the panel's own text size (agentfont.s)
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
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
    PM r15d, MI_40
    PM r12d, MI_28
    mov edi, ID_AG_REFRESH
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, r12d
    sub esi, [rip + g_pmt + 4*MI_8]
    mov edx, r15d
    sub edx, r12d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_REFRESH
    call ag_icon_btn
    test eax, UB_CLICK
    jz 1f
    call agents_scan
1:  mov edi, [rsp]              # AI (D4): "+ TITLE" for extensions whose sessions take prompts
    add edi, [rsp + 8]
    sub edi, r12d
    sub edi, [rip + g_pmt + 4*MI_12]
    mov esi, r15d
    sub esi, r12d
    sar esi, 1
    add esi, [rsp + 4]
    mov edx, r12d
    mov ecx, [rsp]
    add ecx, [rip + g_pmt + 4*MI_16]
    call agentext_list_buttons
    mov [rsp + 16], eax         # the label, where the buttons leave room for it
    lea rdi, [rip + .Lheader]
    call strlen
    mov rdx, rax
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lheader]
    call text_width
    add eax, [rsp]
    add eax, [rip + g_pmt + 4*MI_16]
    add eax, [rip + g_pmt + 4*MI_8]
    cmp eax, [rsp + 16]
    jg 12f
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_16]
    mov edx, [rsp + 4]
    mov ecx, r15d
    lea r8, [rip + .Lheader]
    COLOR r9d, T_MUTED
    call ui_text_c
12: call list_extra             # empty: nothing in the page, nothing rhun drives after it
    add rax, [rip + page_count]
    jnz 2f
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_16]
    mov edx, [rsp + 4]
    add edx, r15d
    PM ecx, MI_24
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
    sub eax, [rip + g_pmt + 4*MI_40]
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
3:  PM ebx, MI_48
    add ebx, [rip + g_pmt + 4*MI_8]      # row h
    call list_extra
    add rax, [rip + page_count]
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
    cmp r12, [rip + sessions + VEC_len]
    jae .Lld_rows_done
    mov rdi, r12                # the page's rows, then the sessions rhun drives after it
    call row_shown
    test eax, eax
    jz .Lld_skip
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
    PM eax, MI_6
    mov edi, [rsp]
    add edi, eax
    mov esi, r13d
    add esi, [rip + g_pmt + 4*MI_2]
    mov edx, [rsp + 8]
    sub edx, eax
    sub edx, eax
    mov ecx, ebx
    sub ecx, [rip + g_pmt + 4*MI_4]
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
4:  # status dot
    PM ecx, MI_8
    mov edi, [rsp]
    add edi, [rip + g_pmt + 4*MI_16]
    mov esi, r13d
    add esi, [rip + g_pmt + 4*MI_16]
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
    mov rdi, [rip + ag_fui]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_32]
    mov edx, r13d
    add edx, [rip + g_pmt + 4*MI_6]
    PM ecx, MI_24
    mov r8, [rsp + 32]
    COLOR r10d, T_FG
    mov r11d, [rsp + 8]
    sub r11d, [rip + g_pmt + 4*MI_48]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    # meta line: provider badge, worktree badge, then time and activity
    mov edi, [r14 + AS_kind]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_32]
    mov edx, r13d
    add edx, [rip + g_pmt + 4*MI_28]
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
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, r13d
    add edx, [rip + g_pmt + 4*MI_28]
    mov ecx, [rsp]
    add ecx, [rsp + 8]
    sub ecx, esi
    sub ecx, [rip + g_pmt + 4*MI_16]
    mov [rsp + 48], esi
    call worktree_badge
    mov [rsp + 40], eax
    # A narrow panel can shorten the badge; hovering it reveals the complete name.
    mov edi, [rsp + 48]
    mov esi, r13d
    add esi, [rip + g_pmt + 4*MI_28]
    mov edx, eax
    sub edx, edi
    PM ecx, MI_20
    call ui_in
    test eax, eax
    jz 7f
    lea edi, [r12 + ID_AG_ROW]
    mov esi, [rsp + 48]
    mov edx, r13d
    add edx, [rip + g_pmt + 4*MI_48]
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
8:  mov rdi, [rip + ag_fsmall]
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    call text_width
    mov ecx, [rsp]
    add ecx, [rsp + 8]
    sub ecx, [rsp + 40]
    sub ecx, [rip + g_pmt + 4*MI_16]
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
81: mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 40]
    mov edx, r13d
    add edx, [rip + g_pmt + 4*MI_28]
    PM ecx, MI_20
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR r10d, T_MUTED
    mov r11d, [rsp]
    add r11d, [rsp + 8]
    sub r11d, esi
    sub r11d, [rip + g_pmt + 4*MI_16]
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
.Lld_skip:
    inc r12
    jmp .Lld_row
.Lld_rows_done:
    call gfx_clip_pop
.Lld_ret:
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rsp + 12]
    sub esi, [rip + g_pmt + 4*MI_40]
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
    PM r15d, MI_40
    PM r12d, MI_28
    mov edi, ID_AG_BACK
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, r15d
    sub edx, r12d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_BACK
    call ag_icon_btn
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
    mov rdi, [rip + ag_fui]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_40]
    mov edx, [rsp + 4]
    mov ecx, r15d
    mov r8, [rsp + 16]
    COLOR r10d, T_FG
    mov r11d, [rsp + 8]
    sub r11d, [rip + g_pmt + 4*MI_64]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    mov rdi, rbx
    call is_live
    test eax, eax
    jz 3f
    PM ecx, MI_8
    mov edi, [rsp]
    add edi, [rsp + 8]
    sub edi, [rip + g_pmt + 4*MI_16]
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
    PM ecx, MI_1
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
    jnz 44f
    mov rdi, rbx                # and a remote window's Claude Code conversation: the line that says why not
    call agentext_remote_line
    test eax, eax
    jz 41f
44: mov rdi, rbx                # AI (D4): its card and prompt box go under the messages
    mov esi, [rsp + 8]
    call agentext_bottom_h
    mov [rsp + 160], eax
    call agents_font_size
    mov ecx, [rsp + 24]
    shr ecx, 1
    cmp eax, [rip + cfg_ui_font_size]
    jle 45f
    mov eax, [rsp + 24]         # two thirds with text larger than the interface's: a card shows more
    add eax, eax
    xor edx, edx
    mov r8d, 3
    div r8d
    mov ecx, eax
45: mov [rsp + 48], ecx
    mov rdi, rbx                # a rich card waiting (agentcard.s): all but a strip of the thread
    call agentcard_of
    mov ecx, [rsp + 48]
    test rax, rax
    jz 46f
    mov ecx, [rsp + 24]
    sub ecx, [rip + g_pmt + 4*MI_32]
    cmp ecx, [rsp + 48]
    jge 46f
    mov ecx, [rsp + 48]
46: test ecx, ecx                # (a panel too short for any: none)
    jg 47f
    xor ecx, ecx
47: mov eax, [rsp + 160]
    cmp eax, ecx
    jbe 42f
    mov eax, ecx                # at most half the panel
42: mov [rsp + 160], eax
    sub [rsp + 24], eax
41: PM eax, MI_16
    mov [rsp + 28], eax         # pad
    mov eax, [rsp + 8]
    sub eax, [rsp + 28]
    sub eax, [rsp + 28]
    sub eax, [rip + g_pmt + 4*MI_24]
    mov [rsp + 32], eax         # text width
    # where the thread is this frame (th_layout: the anchor, the wheel, the rows in view measured)
    mov eax, [rsp + 24]
    mov [rip + th_areah], eax
    call agentpop_shield        # the pointer over the popup is the popup's (drawn last, .Ltd_pop)
    mov rdi, rbx
    mov esi, [rsp + 32]
    call th_begin
    mov rdi, rbx
    lea rsi, [rsp]
    call th_layout
    mov eax, [rip + th_max]
    mov [rsp + 36], eax         # max scroll
    mov rdi, rbx                # the messages that have not started (th_layout counted them)
    call queued_sync
    mov [rsp + 164], eax
    mov edi, [rsp]
    mov esi, [rsp + 20]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 24]
    call gfx_clip_push
    cmp qword ptr [rbx + AS_msgs + VEC_len], 0
    jne 65f
    cmp dword ptr [rsp + 164], 0
    jne 65f
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rsp + 28]
    mov edx, [rsp + 20]
    add edx, [rip + g_pmt + 4*MI_8]
    PM ecx, MI_24
    lea r8, [rip + .Lempty_thread]
    COLOR r9d, T_MUTED
    call ui_text_c
65: # the rows from the anchor's, while in view
    mov r13d, [rsp + 20]
    sub r13d, [rip + lay_off]
    mov r12, [rip + lay_row]
    mov [rip + th_first], r12d
    mov dword ptr [rip + th_last], -1
    test r12, r12
    jns .Ltd_msg
    xor r12d, r12d
.Ltd_msg:
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae .Ltd_after
    mov eax, [rsp + 20]
    add eax, [rsp + 24]
    cmp r13d, eax
    jge .Ltd_msgs_done
    mov rdi, rbx
    mov rsi, r12
    mov edx, [rsp + 32]
    call row_exact
    mov r15d, eax
    test eax, eax
    jz .Ltd_next                # a row of no height (a hidden call, a fold's row)
    mov [rip + th_last], r12d
    imul rdi, r12, AM_SIZE
    add rdi, [rbx + AS_msgs + VEC_ptr]
    mov esi, r13d
    mov edx, r15d
    lea rcx, [rsp]
    call draw_msg
.Ltd_next:
    mov edi, r15d
    call gap_of
    add r13d, eax
    inc r12
    jmp .Ltd_msg
.Ltd_after:                     # then the spinner, the task lines, the queued messages
    mov rdi, rbx
    call agspin_h
    test eax, eax
    jz 66f
    mov [rsp + 48], eax
    mov rdi, rbx
    mov esi, [rsp]
    add esi, [rsp + 28]
    mov edx, r13d
    mov ecx, [rsp + 32]
    call agspin_draw
    add r13d, [rsp + 48]
66: mov rdi, rbx
    mov esi, [rsp + 32]
    call agtask_h
    test eax, eax
    jz 67f
    mov [rsp + 48], eax
    mov rdi, rbx
    mov esi, [rsp]
    add esi, [rsp + 28]
    mov edx, r13d
    mov ecx, [rsp + 32]
    call agtask_draw
    add r13d, [rsp + 48]
67: xor r12d, r12d
.Ltd_queued:                    # (queued_sync made them rows above)
    cmp r12d, [rsp + 164]
    jae .Ltd_msgs_done
    mov ecx, [rsp + 20]
    add ecx, [rsp + 24]
    cmp r13d, ecx
    jge .Ltd_msgs_done
    imul r14, r12, AM_SIZE
    lea rcx, [rip + qrows]
    add r14, rcx
    mov rdi, r14
    mov esi, [rsp + 32]
    call msg_height
    mov r15d, eax
    mov rdi, r14
    mov esi, r13d
    mov edx, r15d
    lea rcx, [rsp]
    call draw_msg
    add r13d, r15d
    add r13d, [rip + g_pmt + 4*MI_8]
    inc r12d
    jmp .Ltd_queued
.Ltd_msgs_done:
    call gfx_clip_pop
    mov r8d, [rsp + 160]
    test r8d, r8d
    jnz 431f
    mov rdi, rbx                # no room under the messages: its card is not drawn, and takes no key
    xor esi, esi
    call agentcard_room
    jmp 43f
431:mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 20]
    add edx, [rsp + 24]
    mov ecx, [rsp + 8]
    call agentext_bottom_draw
    cmp qword ptr [rip + view], 0
    jl .Ltd_pop
43:
    # scrollbar
    mov eax, [rsp + 24]
    push rax
    mov eax, [rip + th_content]
    push rax
    mov edi, ID_AG_TSCROLL
    mov esi, [rsp + 16]
    add esi, [rsp + 16 + 8]
    PM eax, MI_12
    sub esi, eax
    mov edx, [rsp + 16 + 20]
    mov ecx, eax
    mov r8d, [rsp + 16 + 24]
    lea r9, [rip + th_scroll]
    mov eax, [rip + th_scroll]
    mov [rsp + 16 + 52], eax
    call ui_scrollbar
    add rsp, 16
    cmp dword ptr [rip + g_active], ID_AG_TSCROLL
    je 71f
    mov eax, [rip + th_scroll]
    cmp eax, [rsp + 52]
    je 7f
71: mov rdi, rbx                # the scrollbar moved the thread: the anchor is the row at its scroll
    call th_reanchor
7:  # jump-to-latest button when not following
    cmp dword ptr [rip + th_follow], 0
    jne .Ltd_pop
    PM r12d, MI_32
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, r12d
    sub esi, [rip + g_pmt + 4*MI_20]
    mov edx, [rsp + 20]
    add edx, [rsp + 24]
    sub edx, r12d
    sub edx, [rip + g_pmt + 4*MI_16]
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
    call ag_icon_btn
    test eax, UB_CLICK
    jz .Ltd_pop
    mov dword ptr [rip + th_follow], 1
    mov dword ptr [rip + th_arow], -1
    mov dword ptr [rip + g_dirty], 1
.Ltd_pop:
    call agentpop_unshield      # the box's popup over the thread's bottom (agentpop.s: half of it, mostly)
    mov edi, [rsp]
    mov esi, [rsp + 20]
    add esi, [rsp + 24]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 24]
    call agentpop_draw
.Ltd_ret:
    call reply_follow           # a link clicked in a reply, now that nothing drawn is in use
    call agrow_follow           # and a typed row's click or key (agentrows.s)
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
    mov [rbx + AM_dx], r15d     # where it was drawn, for print-agent-row
    mov [rbx + AM_dy], r12d
    mov eax, [rip + th_serial]
    mov [rbx + AM_dser], eax
    test dword ptr [rbx + AM_flags], AMF_QUEUED
    jnz 0f                      # a queued row: not one of the conversation's (qrows)
    cmp qword ptr [rbx + AM_x], 0
    jne .Ldm_typed
    mov eax, [rbx + AM_role]
    cmp eax, R_THINK
    je .Ldm_typed
    cmp eax, R_META
    je .Ldm_typed
    cmp eax, R_COMPACT
    je .Ldm_typed
    cmp eax, R_UNKNOWN
    je .Ldm_typed
0:  test dword ptr [rbx + AM_flags], AMF_PILL
    jnz .Ldm_pill
    mov eax, [rbx + AM_role]
    cmp eax, R_TOOL
    je .Ldm_tool
    cmp eax, R_RESULT
    je .Ldm_result
    cmp eax, R_ERROR
    je .Ldm_result
    cmp eax, R_INFO
    je .Ldm_result
    # user / assistant: label line + wrapped text
    cmp eax, R_USER
    jne 1f
    # user bubble
    mov edi, r15d
    sub edi, [rip + g_pmt + 4*MI_8]
    mov esi, r12d
    mov edx, [r14 + 32]
    add edx, [rip + g_pmt + 4*MI_16]
    mov ecx, r13d
    sub ecx, [rip + g_pmt + 4*MI_4]
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
    lea r8, [rip + .Lyou]
    test dword ptr [rbx + AM_flags], AMF_QUEUED
    jz 11f
    lea r8, [rip + .Lqueued]    # not started yet: "queued", its text muted (below)
11: COLOR r9d, T_MUTED
    jmp 2f
1:  lea r8, [rip + .Lagent]
    COLOR r9d, T_ACCENT
2:  mov rdi, [rip + ag_fsmall]
    mov esi, r15d
    mov edx, r12d
    add edx, [rip + g_pmt + 4*MI_4]
    PM ecx, MI_20
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
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 96]
    mov edx, r12d
    add edx, [rip + g_pmt + 4*MI_4]
    PM ecx, MI_20
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR r10d, T_MUTED
    mov r11d, [r14]
    add r11d, [r14 + 8]
    sub r11d, esi
    sub r11d, [rip + g_pmt + 4*MI_24]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
3:  cmp dword ptr [rbx + AM_role], R_ASSIST
    jne 31f
    cmp qword ptr [rbx + AM_doc], 0
    jne .Ldm_md
    mov dword ptr [rip + g_dirty], 1    # (row_exact parsed it: not reached for a row in view)
31: lea rdi, [rsp]
    push r12
    push r12
    mov r12d, [r14 + 32]
    call wr_setup
    pop r12
    pop r12
    mov [rsp + WR_x], r15d
    mov eax, r12d
    add eax, [rip + g_pmt + 4*MI_28]
    mov [rsp + WR_y], eax
    COLOR eax, T_FG
    test dword ptr [rbx + AM_flags], AMF_QUEUED
    jz 32f
    COLOR eax, T_MUTED
32: mov [rsp + WR_color], eax
    cmp dword ptr [rbx + AM_role], R_USER       # a prompt the CLI cut: its marker muted
    jne 33f
    mov rdi, [rbx + AM_text]
    mov rsi, [rbx + AM_len]
    test rdi, rdi
    jz 33f
    lea rdx, [rip + .Ltruncated]
    mov ecx, TRUNCATED_LEN
    call str_find
    mov [rsp + WR_mute], rax
33: mov rax, [rsp + WR_mute]    # (print-agent-row muted=)
    mov [rbx + AM_mute], rax
    mov dword ptr [rsp + WR_draw], 1
    mov eax, [rip + g_cv + CV_cy0]
    mov [rsp + WR_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rsp + WR_bot], eax
    lea rdi, [rsp]
    call wrap
    EPILOGUE
.Ldm_typed:
    # a typed row (a call with its parts, thinking, a meta line, a compaction marker, an unknown block):
    #   agentrows.s draws it, by its index
    mov rcx, [rip + th_as]
    mov rax, rbx
    sub rax, [rcx + AS_msgs + VEC_ptr]
    xor edx, edx
    mov ecx, AM_SIZE
    div rcx
    mov rdi, [rip + th_as]
    mov rsi, rax
    mov edx, r15d
    mov ecx, r12d
    mov r8d, [r14 + 32]
    mov r9d, r13d
    call agrow_draw
    EPILOGUE
.Ldm_md:
    # a reply: its Markdown under the label, the part in view (as tall as msg_height measured it)
    mov eax, r12d
    add eax, [rip + g_pmt + 4*MI_28]
    mov ecx, r13d
    sub ecx, [rip + g_pmt + 4*MI_40]
    add ecx, eax                # its bottom
    mov edx, [rip + g_cv + CV_cy0]
    cmp edx, eax
    cmovl edx, eax              # the top drawn
    mov r8d, [rip + g_cv + CV_cy1]
    cmp r8d, ecx
    cmovg r8d, ecx              # and the bottom
    sub r8d, edx
    jle .Ldm_md_done
    mov r9d, edx
    sub r9d, eax                # what is above the view
    # its links' ids: a range per row, by its index
    mov rcx, [rip + th_as]
    mov rax, rbx
    sub rax, [rcx + AS_msgs + VEC_ptr]
    push rdx
    push r8
    push r9
    xor edx, edx
    mov ecx, AM_SIZE
    div rcx
    pop r9
    pop r8
    pop rdx
    and eax, 255
    shl eax, 12
    add eax, ID_AG_MD
    push rax
    push rax
    mov rdi, [rbx + AM_doc]
    mov esi, r15d
    mov ecx, [r14 + 32]
    call md_draw
    add rsp, 16
    test eax, eax
    js .Ldm_md_done
    mov rdi, rbx
    mov esi, eax
    call reply_click
.Ldm_md_done:
    EPILOGUE
.Ldm_tool:
    PM ecx, MI_16
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
    mov rdi, [rip + ag_fsmall]
    mov esi, r15d
    add esi, [rip + g_pmt + 4*MI_24]
    mov edx, r12d
    mov ecx, r13d
    COLOR r9d, T_FG
    call ui_text_c
    mov [rsp + 96], eax
    jmp 4f
3:  mov eax, r15d
    add eax, [rip + g_pmt + 4*MI_24]
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
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 96]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, r12d
    mov ecx, r13d
    mov r8, [rbx + AM_text]
    COLOR r10d, T_MUTED
    mov r11d, [r14]
    add r11d, [r14 + 8]
    sub r11d, esi
    sub r11d, [rip + g_pmt + 4*MI_24]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
5:  EPILOGUE
.Ldm_pill:
    # a pill: its one line centred in the text's width, muted, in a rounded frame (cut with "…")
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rbx + AM_text]
    mov rdx, [rbx + AM_len]
    call text_width
    mov ecx, [r14 + 32]         # the line's room
    sub ecx, [rip + g_pmt + 4*MI_12]
    sub ecx, [rip + g_pmt + 4*MI_12]
    cmp ecx, 1
    jge 1f
    mov ecx, 1
1:  cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 96], eax         # the text's width as drawn
    add eax, [rip + g_pmt + 4*MI_12]
    add eax, [rip + g_pmt + 4*MI_12]
    mov [rsp + 100], eax        # the frame's
    mov ecx, [r14 + 32]
    sub ecx, eax
    sar ecx, 1
    jns 2f
    xor ecx, ecx
2:  add ecx, r15d
    mov [rsp + 104], ecx        # its x
    call pill_h
    mov [rsp + 108], eax        # its height
    COLOR r9d, T_BORDER
    COLOR eax, T_PANEL
    mov edi, [rsp + 104]
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, [rsp + 100]
    mov ecx, [rsp + 108]
    PM r8d, MI_RADIUS
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    mov rdi, [rip + ag_fsmall]  # ui_text_v_fit(face, x, y, h, ptr, len, argb, maxw)
    mov esi, [rsp + 104]
    add esi, [rip + g_pmt + 4*MI_12]
    mov edx, r12d
    add edx, [rip + g_pmt + 4*MI_6]
    mov ecx, [rsp + 108]
    mov r8, [rbx + AM_text]
    mov r9, [rbx + AM_len]
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 96]
    inc r11d
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    EPILOGUE
.Ldm_result:
    mov edi, r15d
    mov esi, r12d
    mov edx, [r14 + 32]
    mov ecx, r13d
    sub ecx, [rip + g_pmt + 4*MI_8]
    PM r8d, MI_4
    COLOR r9d, T_BG
    call gfx_round_rect
    mov edi, r15d
    mov esi, r12d
    PM edx, MI_2
    mov ecx, r13d
    sub ecx, [rip + g_pmt + 4*MI_8]
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
    add eax, [rip + g_pmt + 4*MI_10]
    mov [rsp + WR_x], eax
    mov eax, r12d
    add eax, [rip + g_pmt + 4*MI_6]
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

# reply_click(msg, link): a link of a reply was clicked. A code block's Copy at once; an http or https
#   link asks before it opens (links_ask_open, after the frame, named by the conversation's driver);
#   other schemes as the Markdown preview follows them (nowhere); rhun:// links, files and file: URIs
#   after the frame (reply_follow), as opening one may change what is drawn
reply_click:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, [rbx + AM_doc]
    mov esi, r12d
    call md_is_copy
    test eax, eax
    jnz 5f
    mov rdi, [rbx + AM_doc]
    mov esi, r12d
    call md_link
    test rdx, rdx
    jz 9f
    cmp rdx, 4000
    ja 9f
    mov r13, rax
    mov r14, rdx
    mov rdi, r13
    mov rsi, r14
    call link_scheme
    mov qword ptr [rip + pend_who], 0
    cmp eax, 2
    jne 3f
    mov rdi, r13                # a web link: the chooser, after the frame
    mov rsi, r14
    call links_url_ok
    test eax, eax
    jz 5f
    lea rax, [rip + .Lthis_reply]
    mov [rip + pend_who], rax
    mov rdi, [rip + th_as]
    call agent_drv_of
    test rax, rax
    jz 3f
    mov rax, [rax + DRV_name]
    mov [rip + pend_who], rax
3:  mov rdi, [rip + pend_link]  # a file or rhun://: kept for after the frame
    call mem_free
    mov rdi, [rip + pend_cwd]
    call mem_free
    mov qword ptr [rip + pend_cwd], 0
    mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov [rip + pend_link], rax
    mov rax, [rip + th_as]
    test rax, rax
    jz 4f
    mov r13, [rax + AS_cwd]
    test r13, r13
    jz 4f
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call mem_dup
    mov [rip + pend_cwd], rax
4:  mov dword ptr [rip + g_dirty], 1
    jmp 9f
5:  mov rdi, [rbx + AM_doc]
    mov esi, r12d
    call md_open_link
9:  EPILOGUE

# link_scheme(ptr, len) -> eax 0 none (a path), 1 rhun://, 2 another scheme, 3 file: (any case): letters,
#   digits, + . - from a letter, two at least, then ':' and something not a digit (PATH:12 is a path)
link_scheme:
    xor eax, eax
    test rsi, rsi
    jz 9f
    movzx ecx, byte ptr [rdi]
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 25
    ja 9f
    mov ecx, 1
1:  cmp rcx, rsi
    jae 9f
    movzx edx, byte ptr [rdi + rcx]
    cmp edx, ':'
    je 3f
    inc rcx
    cmp edx, '+'
    je 1b
    cmp edx, '.'
    je 1b
    cmp edx, '-'
    je 1b
    lea r8d, [rdx - 48]
    cmp r8d, 9
    jbe 1b
    or edx, 0x20
    sub edx, 'a'
    cmp edx, 25
    jbe 1b
    ret
3:  cmp rcx, 2
    jb 9f                       # one letter: a drive
    lea rdx, [rcx + 1]
    cmp rdx, rsi
    jae 9f
    movzx edx, byte ptr [rdi + rcx + 1]
    sub edx, '0'
    cmp edx, 9
    jbe 9f
    cmp rcx, 4
    jne 4f
    mov edx, [rdi]
    or edx, 0x20202020
    cmp edx, 0x656c6966                 # "file"
    jne 4f
    mov eax, 3
    ret
4:  mov eax, 2
    cmp rsi, 7
    jb 9f
    cmp dword ptr [rdi], 0x6e756872     # "rhun"
    jne 9f
    cmp word ptr [rdi + 4], 0x2f3a      # ":/"
    jne 9f
    cmp byte ptr [rdi + 6], '/'
    jne 9f
    mov eax, 1
9:  ret

# reply_follow(): the link reply_click kept, followed: a model wrote it, so it only ever opens a file's text
#   in a tab (lk_try: no folder, no workspace file made the project, no extension installed): a
#   rhun://file/ link's path, a path, a file: URI (follow_file); other rhun:// links do nothing
reply_follow:
    PROLOGUE
    mov rbx, [rip + pend_link]
    test rbx, rbx
    jz 9f
    mov r12, [rip + pend_cwd]
    mov qword ptr [rip + pend_link], 0
    mov qword ptr [rip + pend_cwd], 0
    mov rdi, [rip + pend_who]   # a web link: asked before it opens (links.s)
    test rdi, rdi
    jz 0f
    mov qword ptr [rip + pend_who], 0
    mov rsi, rbx
    call links_ask_open
    jmp 2f
0:  mov rdi, rbx
    call strlen
    mov r13, rax
    mov rdi, rbx
    mov rsi, rax
    call link_scheme
    cmp eax, 1
    jne 1f
    cmp r13, 12                 # "rhun://file/" and more
    jbe 2f
    mov rdi, rbx
    lea rsi, [rip + .Lrhun_file]
    mov edx, 12
    call memeq
    test eax, eax
    jz 2f
    mov rdi, rbx                # decoded, and opened only as a file's text in a tab (lk_try): never
    lea rsi, [rip + lk_buf]     #   app_open_path, which makes a folder or a workspace file the project
    mov edx, 4000
    call rhun_url
    test rax, rax
    jle 2f
    mov r13d, edx               # (lk_try's line and column)
    mov r14d, ecx
    lea rdi, [rip + lk_buf]
    call path_normalize
    lea rdi, [rip + lk_buf]
    call strlen
    lea rdi, [rip + lk_buf]
    mov rsi, rax
    call mem_dup
    mov rdi, rax
    call lk_try                 # (a folder, or no such file: nothing)
    jmp 2f
1:  mov rdi, rbx
    mov rsi, r12
    call follow_file
2:  mov rdi, rbx
    call mem_free
    mov rdi, r12
    call mem_free
9:  EPILOGUE

# follow_file(target, cwd or 0): a reply's link to a file, opened in the editor at its line. The
#   target is PATH, PATH:L, PATH:L-M, PATH:L:C, PATH#LL or PATH#LL-LM, or a file: URI of one (file:///P,
#   file://HOST/P with the host left out, file:/P; file:///C:/P is C:/P), absolute or relative to the
#   conversation's checkout, then to the project. First the whole text, %XX decoded, is tried as a file's
#   name (a name written with a # or a : in it); then the suffix is split off the text as written and
#   only the path before it decoded (so %23 and %3A stay in the name). Only the first line of a range is
#   gone to. A toast when it names no file
follow_file:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call link_scheme
    xor ecx, ecx
    cmp eax, 3
    jne 12f
    mov ecx, 5                  # "file:" left out
    cmp word ptr [rbx + 5], 0x2f2f      # "//": an authority (a host, or none) up to the path's "/"
    jne 11f
    mov ecx, 7
10: movzx eax, byte ptr [rbx + rcx]
    test eax, eax
    jz 12f
    cmp eax, '/'
    je 11f
    inc ecx
    jmp 10b
11: cmp byte ptr [rbx + rcx], '/'   # "/C:/..." is a drive's path
    jne 12f
    movzx eax, byte ptr [rbx + rcx + 1]
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    ja 12f
    cmp byte ptr [rbx + rcx + 2], ':'
    jne 12f
    inc ecx
12: mov [rsp + 24], rcx         # where the path starts
    xor r13d, r13d              # the line
    xor r14d, r14d              # the column
    lea rsi, [rbx + rcx]        # first the whole text decoded, when a file has that very name
    call lk_decode              #   ("a#b.txt" written as it is, or "a%23b.txt")
    test rax, rax
    js 13f
    mov r15, rax
    call ff_resolve
    test eax, eax
    jnz 9f
13: mov rcx, [rsp + 24]         # then the suffix split from the text as written (a %23 or %3A is part
    lea rsi, [rbx + rcx]        #   of the name, never a line), the path before it decoded at .Lff_open
    lea rdi, [rip + lk_buf]
    lea r8, [rdi + 4000]
2:  movzx eax, byte ptr [rsi]
    test eax, eax
    jz 3f
    cmp rdi, r8
    jae .Lff_none
    mov [rdi], al
    inc rdi
    inc rsi
    jmp 2b
3:  mov byte ptr [rdi], 0
    lea rax, [rip + lk_buf]
    sub rdi, rax
    mov r15, rdi                # its length
    # "#L12" or "#L12-L20", any other fragment left out
    lea rdi, [rip + lk_buf]
    xor ecx, ecx
4:  cmp rcx, r15
    jae 5f
    cmp byte ptr [rdi + rcx], '#'
    je 41f
    inc rcx
    jmp 4b
41: mov r15, rcx
    mov byte ptr [rdi + rcx], 0
    cmp byte ptr [rdi + rcx + 1], 'L'
    jne .Lff_open
    lea rdi, [rdi + rcx + 2]
    mov esi, 12
    call parse_u64
    test rdx, rdx
    jz .Lff_open
    mov r13d, eax
    jmp .Lff_open
5:  # ":12", ":12-20" or ":12:5" at the end
    mov rcx, r15
51: cmp rcx, 1
    jbe .Lff_open
    dec rcx
    cmp byte ptr [rdi + rcx], ':'
    jne 51b
    mov [rsp], rcx              # the colon
    lea rdi, [rdi + rcx + 1]
    mov rsi, r15
    sub rsi, rcx
    dec rsi
    call parse_u64
    test rdx, rdx
    jz .Lff_open
    mov [rsp + 8], eax          # the number
    mov rcx, [rsp]
    lea r8, [rcx + 1]
    add r8, rdx                 # after its digits
    mov dword ptr [rsp + 12], 0 # 1: a range follows
    cmp r8, r15
    je 52f
    lea rax, [rip + lk_buf]
    cmp byte ptr [rax + r8], '-'
    jne .Lff_open
    mov dword ptr [rsp + 12], 1
    lea rdi, [rax + r8 + 1]
    mov rsi, r15
    sub rsi, r8
    dec rsi
    mov [rsp + 16], rsi
    call parse_u64
    test rdx, rdx
    jz .Lff_open
    cmp rdx, [rsp + 16]
    jne .Lff_open
52: mov rcx, [rsp]
    lea rax, [rip + lk_buf]
    mov byte ptr [rax + rcx], 0
    mov r15, rcx
    mov r13d, [rsp + 8]
    cmp dword ptr [rsp + 12], 0
    jne .Lff_open
    # digits and a colon before it: ":LINE:COL"
    mov rdx, rcx
53: test rdx, rdx
    jz .Lff_open
    dec rdx
    movzx r8d, byte ptr [rax + rdx]
    cmp r8d, ':'
    je 54f
    sub r8d, '0'
    cmp r8d, 9
    jbe 53b
    jmp .Lff_open
54: lea r8, [rdx + 1]
    cmp r8, rcx
    je .Lff_open                # no digits
    test rdx, rdx
    jz .Lff_open
    mov [rsp], rdx
    lea rdi, [rax + rdx + 1]
    mov rsi, rcx
    sub rsi, rdx
    dec rsi
    call parse_u64
    mov r14d, r13d
    mov r13d, eax
    mov rdx, [rsp]
    lea rax, [rip + lk_buf]
    mov byte ptr [rax + rdx], 0
.Lff_open:
    lea rsi, [rip + lk_buf]     # the path, decoded in place
    call lk_decode
    test rax, rax
    js .Lff_none
    mov r15, rax
    call ff_resolve
    test eax, eax
    jnz 9f
.Lff_none:
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lno_file]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + tmp]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + tmp + SB_ptr]
    call app_toast
    EPILOGUE
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# lk_decode(src cstr) -> rax the length of src %XX-decoded into lk_buf (it may be lk_buf: decoding only
#   shortens), -1 when it is too long or holds %00. A % without two hex digits after it stays
lk_decode:
    lea rdi, [rip + lk_buf]
    lea r8, [rdi + 4000]
    mov r9, rdi
1:  movzx eax, byte ptr [rsi]
    test eax, eax
    jz 3f
    cmp rdi, r8
    jae 8f
    cmp eax, '%'
    jne 2f
    mov al, [rsi + 1]
    call lk_hex
    test eax, eax
    js 11f
    mov ecx, eax
    shl ecx, 4
    mov al, [rsi + 2]
    call lk_hex
    test eax, eax
    js 11f
    or eax, ecx
    jz 8f                       # %00
    add rsi, 2
    jmp 2f
11: mov eax, '%'
2:  mov [rdi], al
    inc rdi
    inc rsi
    jmp 1b
3:  mov byte ptr [rdi], 0
    mov rax, rdi
    sub rax, r9
    ret
8:  mov rax, -1
    ret

# ff_resolve() -> eax 1 opened: follow_file's lk_buf (r15 its length, r12 the checkout or 0, r13d and r14d
#   the line and column) as a file: absolute, else in the checkout, then in the project (lk_try)
ff_resolve:
    push rbx
    lea rdi, [rip + lk_buf]
    cmp byte ptr [rdi], 0
    je 8f
    PATH_ABSOLUTE rdi, 6f
    test r12, r12               # relative: to the checkout, then the project
    jz 1f
    mov rdi, r12
    lea rsi, [rip + lk_buf]
    call path_join
    mov rdi, rax
    call lk_try
    test eax, eax
    jnz 9f
1:  mov rdi, [rip + g_project]
    test rdi, rdi
    jz 8f
    lea rsi, [rip + lk_buf]
    call path_join
    mov rdi, rax
    call lk_try
    test eax, eax
    jnz 9f
    jmp 8f
6:  lea rdi, [rip + lk_buf]
    mov rsi, r15
    call mem_dup
    mov rdi, rax
    call lk_try
    test eax, eax
    jnz 9f
8:  xor eax, eax
9:  pop rbx
    ret

# lk_try(path, owned) using r13d = the line, r14d = the column: the file opened there, eax 1; 0 when
#   the path names no file (a folder, nothing). Frees the path
lk_try:
    push rbx
    push r15
    sub rsp, 8
    mov rbx, rdi
    xor r15d, r15d
    call vfs_stat
    test eax, eax
    jnz 8f
    mov rdi, rbx
    call vfs_is_dir
    test eax, eax
    jnz 8f
    mov r15d, 1
    mov rdi, rbx
    call app_open_file
    test rax, rax
    js 8f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    test r13d, r13d
    jz 8f
    mov edi, r13d
    mov esi, r14d
    test esi, esi
    jnz 7f
    mov esi, 1
7:  call app_goto_line
8:  mov rdi, rbx
    call mem_free
    mov eax, r15d
    add rsp, 8
    pop r15
    pop rbx
    ret

# lk_hex: al -> eax its value as a hex digit, or -1 (touches nothing else)
lk_hex:
    movzx eax, al
    cmp eax, '0'
    jb 8f
    cmp eax, '9'
    jbe 1f
    or eax, 0x20
    cmp eax, 'a'
    jb 8f
    cmp eax, 'f'
    ja 8f
    sub eax, 87                 # 'a' less 10
    ret
1:  sub eax, '0'
    ret
8:  mov eax, -1
    ret

# FN agents_row_dump(sb, n): row n (from 1) of the open conversation as the panel drew it last, for
#   tests: "row=N role=R height=H y=Y content=C parsed=0|1 parses=P muted=M|-" (y its top on screen in the
#   last frame, -1 when it was not drawn; M the byte a user row drawn then is muted from: the CLI's marker), then a parsed reply's Markdown a line per block (md_row_dump,
#   its links where they were drawn); "plain TEXT" for the other rows. It parses nothing
FN agents_row_dump
    PROLOGUE
    mov r15, rdi
    mov r12, rsi
    mov rax, [rip + view]
    test rax, rax
    js 9f
    cmp rax, [rip + sessions + VEC_len]
    jae 9f
    mov rcx, [rip + sessions + VEC_ptr]
    mov r13, [rcx + rax*8]
    dec r12
    js 9f
    cmp r12, [r13 + AS_msgs + VEC_len]
    jae 9f
    imul rbx, r12, AM_SIZE
    add rbx, [r13 + AS_msgs + VEC_ptr]
    mov rdi, r15
    lea rsi, [rip + .Lrow_n]
    call sb_push_cstr
    lea rsi, [r12 + 1]
    mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lrow_role]
    call sb_push_cstr
    mov eax, [rbx + AM_role]
    lea rcx, [rip + role_names]
    mov rsi, [rcx + rax*8]
    mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Lrow_height]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + AM_h]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lrow_y]
    call sb_push_cstr
    mov esi, -1
    mov eax, [rbx + AM_dser]
    cmp eax, [rip + th_serial]
    jne 11f
    mov esi, [rbx + AM_dy]
11: mov rdi, r15
    call md_push_int
    mov rdi, r15
    lea rsi, [rip + .Lrow_content]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rip + th_content]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lrow_parsed]
    call sb_push_cstr
    xor r14d, r14d
    cmp qword ptr [rbx + AM_doc], 0
    je 1f
    mov eax, [rbx + AM_drev]
    cmp eax, [rbx + AM_rev]
    jne 1f
    mov r14d, 1
1:  mov rdi, r15
    mov esi, r14d
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lrow_parses]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rip + md_parses]
    call sb_push_u64
    mov rdi, r15                # a user row drawn in the last frame: where its text turns muted
    lea rsi, [rip + .Lrow_muted]
    call sb_push_cstr
    mov eax, [rbx + AM_dser]
    cmp eax, [rip + th_serial]
    jne 2f
    cmp dword ptr [rbx + AM_role], R_USER
    jne 2f
    mov rsi, [rbx + AM_mute]
    test rsi, rsi
    js 2f
    mov rdi, r15
    call sb_push_u64
    jmp 4f
2:  mov rdi, r15
    mov esi, '-'
    call sb_push_byte
4:  test r14d, r14d             # a parsed reply: its text's size, its code's (the editor's family at it)
    jz 41f
    mov rdi, r15
    lea rsi, [rip + .Lrow_face]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + AM_dpx]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lrow_code]
    call sb_push_cstr
    call agrow_code_face
    mov rdi, r15
    mov esi, [rax + FACE_px]
    call sb_push_u64
41: mov rdi, r15
    mov esi, 10
    call sb_push_byte
    cmp qword ptr [rbx + AM_x], 0       # a typed row: its parts as drawn (agentrows.s)
    jne 42f
    mov eax, [rbx + AM_role]
    cmp eax, R_THINK
    je 42f
    cmp eax, R_META
    je 42f
    cmp eax, R_COMPACT
    je 42f
    cmp eax, R_UNKNOWN
    je 42f
    cmp dword ptr [rbx + AM_role], R_ASSIST
    jne 5f
    test r14d, r14d
    jz 9f
    mov edx, -1                 # where it is on screen, when it was drawn in the last frame
    mov ecx, -1
    mov eax, [rbx + AM_dser]
    cmp eax, [rip + th_serial]
    jne 3f
    mov edx, [rbx + AM_dx]
    mov ecx, [rbx + AM_dy]
    add ecx, [rip + g_pmt + 4*MI_28]
3:  mov rdi, [rbx + AM_doc]
    mov rsi, r15
    call md_row_dump
    jmp 9f
5:  mov rdi, r15
    lea rsi, [rip + .Lrow_plain]
    call sb_push_cstr
    mov rsi, [rbx + AM_text]
    mov rdx, [rbx + AM_len]
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
9:  EPILOGUE
42: mov rdi, r15
    mov rsi, r13
    mov rdx, r12
    call agrow_row_dump
    EPILOGUE

# FN agents_test_append(ptr, len): TEXT ("\n" in it a line end) added to the last reply of the open
#   conversation in place, as a streaming reply grows (agent-test-append)
FN agents_test_append
    PROLOGUE
    mov r14, rdi
    mov r15, rsi
    mov rax, [rip + view]
    test rax, rax
    js 9f
    cmp rax, [rip + sessions + VEC_len]
    jae 9f
    mov rcx, [rip + sessions + VEC_ptr]
    mov r13, [rcx + rax*8]
    mov r12, [r13 + AS_msgs + VEC_len]
1:  test r12, r12
    jz 9f
    dec r12
    imul rbx, r12, AM_SIZE
    add rbx, [r13 + AS_msgs + VEC_ptr]
    cmp dword ptr [rbx + AM_role], R_ASSIST
    jne 1b
    mov rdi, [rbx + AM_text]
    mov rsi, [rbx + AM_len]
    add rsi, r15
    inc rsi
    call mem_realloc
    mov [rbx + AM_text], rax
    mov rdi, rax
    add rdi, [rbx + AM_len]
    xor ecx, ecx
2:  cmp rcx, r15
    jae 4f
    movzx eax, byte ptr [r14 + rcx]
    inc rcx
    cmp eax, '\\'
    jne 3f
    cmp rcx, r15
    jae 3f
    cmp byte ptr [r14 + rcx], 'n'
    jne 3f
    inc rcx
    mov eax, 10
3:  mov [rdi], al
    inc rdi
    jmp 2b
4:  mov byte ptr [rdi], 0
    sub rdi, [rbx + AM_text]
    mov [rbx + AM_len], rdi
    mov rsi, rdi
    mov rdi, [rbx + AM_text]
    call count_lf
    mov [rbx + AM_nl], eax
    mov rdi, r13
    mov rsi, r12
    call agents_msg_changed
9:  EPILOGUE

.section .rodata
.Ld_scroll: .asciz " scroll="
.Ld_max: .asciz " max="
.Ld_follow: .asciz " follow="
.Lr0: .asciz "?"
.Lr1: .asciz "user"
.Lr2: .asciz "agent"
.Lr3: .asciz "tool"
.Lr4: .asciz "result"
.Lr5: .asciz "error"
.Lr6: .asciz "info"
.Lr7: .asciz "thinking"
.Lr8: .asciz "meta"
.Lr9: .asciz "compact"
.Lr10: .asciz "unknown"
.Lr_result: .asciz "result "
.Lr_live: .asciz "live"
.Lr_close: .asciz ") "
.Lr_auto: .asciz " auto "
.Lr_manual: .asciz " manual "
.Lr_k: .asciz "k\n"
.Lst_working: .asciz "  \302\267  working"
.Lst_waiting: .asciz "  \302\267  waiting for you"
.Lst_error: .asciz "  \302\267  error"
.p2align 3
role_names: .quad .Lr0, .Lr1, .Lr2, .Lr3, .Lr4, .Lr5, .Lr6, .Lr7, .Lr8, .Lr9, .Lr10
ext_state_labels: .quad .Lr0, .Lst_working, .Lst_waiting, .Lst_error
.Lheader: .asciz "AGENTS"
.Lnone: .asciz "No agent sessions for this project yet"
.Loc_missing: .asciz "OpenCode: install the CLI, then refresh"
.Loc_failed: .asciz "OpenCode: check CLI and data access"
.Lnoproj: .asciz "Open a folder to see its agent sessions"
.Luntitled: .asciz "Untitled session"
.Lthis_reply: .asciz "This reply"
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
.Ltruncated: .ascii "[Message truncated - exceeded 50,000 character limit]"   # the CLI's marker
.Llive: .asciz "  \302\267  live"
.Lnow: .asciz "just now"
.Lago: .asciz " ago"
.Lyou: .asciz "You"
.Lqueued: .asciz "queued"
.Lr_pill: .asciz "pill"
.Lqueued_dump: .asciz "queued "
.Lno_file: .asciz "No such file: "
.Lrhun_file: .ascii "rhun://file/"
.Lrow_n: .asciz "row="
.Lrow_role: .asciz " role="
.Lrow_height: .asciz " height="
.Lrow_y: .asciz " y="
.Lrow_content: .asciz " content="
.Lrow_parsed: .asciz " parsed="
.Lrow_parses: .asciz " parses="
.Lrow_muted: .asciz " muted="
.Lrow_plain: .asciz "plain "
.Lrow_face: .asciz " face="
.Lrow_code: .asciz " code="
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
.Lsystem: .asciz "system"
.Ltimestamp: .asciz "timestamp"
.Lmark_stop: .asciz "[Request interrupted by user]"
.Lmark_tool: .asciz "[Request interrupted by user for tool use]"
.Linterrupted: .asciz "Interrupted"
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
th_max: .long 0                 # the open thread's largest scroll, when it was drawn last

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

# list_extra() -> rax the rows the list shows after the page: the sessions rhun drives pinned there (a
#   new conversation discovery has not listed yet). Other rows pinned there (the open conversation's)
#   are not shown
list_extra:
    xor eax, eax
    mov rcx, [rip + page_count]
1:  cmp rcx, [rip + sessions + VEC_len]
    jae 9f
    mov rdx, [rip + sessions + VEC_ptr]
    mov rdx, [rdx + rcx*8]
    inc rcx
    cmp qword ptr [rdx + AS_live], 0
    je 1b
    inc rax
    jmp 1b
9:  ret

# row_shown(index) -> eax 1 when the list shows sessions[index]: in the page, or one rhun drives after it
row_shown:
    mov eax, 1
    cmp rdi, [rip + page_count]
    jb 9f
    xor eax, eax
    cmp rdi, [rip + sessions + VEC_len]
    jae 9f
    mov rcx, [rip + sessions + VEC_ptr]
    mov rcx, [rcx + rdi*8]
    cmp qword ptr [rcx + AS_live], 0
    setne al
9:  ret

# Fixed footer: count at left, Load more (or retry) at right.
page_footer:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    PM eax, MI_40
    mov [rsp + 12], eax
    mov ecx, [rip + g_pmt + 4*MI_1]
    COLOR r8d, T_BORDER
    call gfx_fill
    call list_extra             # the sessions rhun drives after the page count, on both sides
    mov [rsp + 24], rax
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rip + page_count]
    add rsi, [rsp + 24]
    call sb_push_u64
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lfooter_of]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rip + total_count]
    add rsi, [rsp + 24]
    call sb_push_u64
    mov eax, [rsp + 8]
    sub eax, [rip + g_pmt + 4*MI_16]
    mov [rsp + 16], eax
    mov rax, [rip + page_count]
    cmp rax, [rip + total_count]
    jb 1f
    call index_loading
    test eax, eax
    jnz 1f
    cmp dword ptr [rip + index_error], 0
    je 5f
1:  PM eax, MI_48
    add eax, eax
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + 20], eax
    sub [rsp + 16], eax
    mov edi, ID_AG_MORE
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, eax
    sub esi, [rip + g_pmt + 4*MI_8]
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
3:  mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 20]
    sub esi, [rip + g_pmt + 4*MI_8]
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
51: mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR eax, T_MUTED
    mov r10d, [rsp + 16]
    sub r10d, [rip + g_pmt + 4*MI_16]
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
