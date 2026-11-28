# testing: test-exec. During a run the user started, a controller asks rhun to start one of the
# programs its manifest names in [needs] tests (go, cargo): rhun starts it outside the extension's
# sandbox, with the user's environment, in a folder of the project, in a process group of its own
# (a job object on Windows), and passes what it writes to the extension as test-out events and its
# end as test-exit. Its pipes are read only while the extension's outgoing queue is short, so a
# chatty test waits instead of growing memory. Every process starts through testexec_spawn.
.include "rhun.inc"

# a test process
STRUCT
F TSX_ext, 8             # its controller, 0 for a free slot
F TSX_run, 8             # its run (TSR*, slots never move) and that run's number
F TSX_runnum, 8
F TSX_exec, 8            # the number the extension knows it by
F TSX_pid, 4
F TSX_out, 4             # the read ends of its output and error pipes, -1 once closed
F TSX_err, 4
F TSX_status, 4          # its wait status once reaped, -1 before
F TSX_killed, 4          # 1: rhun stopped it (Cancel, the run ending, the extension stopping)
F TSX_paused, 4          # 1: its pipes wait for the extension's queue
F TSX_orphan, 4          # 1: its extension stopped; nothing more is sent
F TSX_handed, 4          # 1: stopped through uproc_end, which kills and reaps its whole group
F TSX_term_at, 8         # time_ms of the SIGTERM to its group, 0 none: SIGKILL 2 s later
F TSX_exit_at, 8         # time_ms it was reaped with a pipe still open (a child keeps it)
ENDSTRUCT TSX_SIZE
.equ TSX_LINGER_MS, 2000         # a pipe kept open after the program ended is closed this long after

.bss
.p2align 3
procs: .zero TSX_SIZE * TS_PROCS_ALL
exec_next: .quad 0              # the last EXEC number given
rbuf: .zero TS_OUT_EVENT
eb: .zero SB_SIZE               # an event being built
args: .zero VEC_SIZE            # argv being built: owned cstrs, then 0
envs: .zero VEC_SIZE            # extra variables: owned cstrs, then 0
cmd_prog: .quad 0
cmd_proglen: .quad 0
cmd_cwd: .quad 0
cmd_cwdlen: .quad 0
realproj: .zero 4096
realcwd: .zero 4096
pipe_out: .zero 8
pipe_err: .zero 8
parked_ext: .quad 0             # a request waiting for the approval question: its extension (0: none),
parked_id: .quad 0              #   request id, run and that run's number
parked_run: .quad 0
parked_runnum: .quad 0
cmdline: .zero 4096             # the command as the question shows it
cwd_buf: .zero 4096             # the request's folder, copied

.text

# testexec_request(ext, id, run, body, len): "ID test-exec RUN LEN" + "PROGRAM_LEN CWD_LEN ARGC ENVC"
#   LF PROGRAM CWD, ARGC args "LEN" LF bytes, ENVC variables "LEN" LF NAME=VALUE; answered "ok ID
#   EXEC" when the program started, else with the reason. The first program an extension runs in a
#   project waits for the user's approval (runallow.s): the request is parked meanwhile
FN testexec_request
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], rsi              # id
    mov r12, rdx                # run
    mov [rsp + 8], rcx
    mov [rsp + 16], r8
    cmp qword ptr [rip + parked_ext], 0
    jne .Lxr_parked             # one approval question at a time (its lists are in use)
    call free_lists
    # a folder a link opened runs nothing of its own until it is trusted
    cmp dword ptr [rip + g_git_paused], 0
    jne .Lxr_untrusted
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call parse_command
    test rax, rax
    jnz .Lxr_error
    # the program: a name the manifest lists, bare or at the end of a path
    mov rdi, rbx
    call prog_allowed
    test eax, eax
    jz .Lxr_needs
    # the counts: 4 a run, 8 in all
    xor ecx, ecx
    xor edx, edx
    lea rax, [rip + procs]
    xor r8d, r8d
1:  cmp qword ptr [rax + TSX_ext], 0
    je 2f
    inc ecx
    cmp [rax + TSX_run], r12
    jne 2f
    inc edx
2:  add rax, TSX_SIZE
    inc r8d
    cmp r8d, TS_PROCS_ALL
    jb 1b
    cmp ecx, TS_PROCS_ALL
    jae .Lxr_busy
    cmp edx, TS_PROCS_RUN
    jae .Lxr_busy
    # the user's approval for this extension and project: once, with the command shown
    call command_line
    mov rdi, rbx
    lea rsi, [rip + cmdline]
    lea rdx, [rip + on_approved]
    lea rcx, [rip + parked_ext]
    call run_approve
    cmp eax, 1
    je 3f
    test eax, eax
    jnz .Lxr_busy_open
    # asked: the request waits for the answer
    mov [rip + parked_ext], rbx
    mov rax, [rsp]
    mov [rip + parked_id], rax
    mov [rip + parked_run], r12
    mov rax, [r12 + TSR_num]
    mov [rip + parked_runnum], rax
    EPILOGUE
3:  mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, r12
    call exec_start
    EPILOGUE
.Lxr_untrusted:
    lea rsi, [rip + .Le_untrusted]
    jmp .Lxr_reply
.Lxr_busy:
    lea rsi, [rip + .Le_busy]
    jmp .Lxr_reply
.Lxr_busy_open:
    lea rsi, [rip + .Le_busy_open]
    jmp .Lxr_reply
.Lxr_error:
    mov rsi, rax
.Lxr_reply:
    mov rdi, [rsp]
    call testproto_reply_error
    call free_lists
    EPILOGUE
.Lxr_parked:
    # the parked request keeps its command: answered without touching the lists
    mov rdi, [rsp]
    lea rsi, [rip + .Le_busy_open]
    call testproto_reply_error
    EPILOGUE
.Lxr_needs:
    # "needs tests=NAME"
    lea rdi, [rip + eb]
    call sb_clear
    lea rdi, [rip + eb]
    lea rsi, [rip + .Le_needs]
    call sb_push_cstr
    lea rdi, [rip + eb]
    mov rsi, [rip + cmd_prog]
    mov rdx, [rip + cmd_proglen]
    call sb_push
    lea rdi, [rip + eb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rsp]
    mov rsi, [rip + eb + SB_ptr]
    call testproto_reply_error
    call free_lists
    EPILOGUE

# on_approved(cookie, allowed): the user answered the approval question of the parked request
on_approved:
    PROLOGUE
    mov r15d, esi
    mov rbx, [rip + parked_ext]
    test rbx, rbx
    jz 9f
    mov qword ptr [rip + parked_ext], 0
    mov r12, [rip + parked_run]
    mov rax, [rip + parked_runnum]
    cmp [r12 + TSR_num], rax
    jne 8f                      # its run is gone
    cmp dword ptr [r12 + TSR_state], TSRS_RUNNING
    jne 8f
    mov rdi, rbx
    call testproto_agreed
    test eax, eax
    jz 8f
    mov rdi, rbx
    call testproto_set_ext
    test r15d, r15d
    jz 7f
    mov rdi, rbx
    mov rsi, [rip + parked_id]
    mov rdx, r12
    call exec_start
    jmp 9f
7:  mov rdi, [rip + parked_id]
    lea rsi, [rip + .Le_cancelled]
    call testproto_reply_error
8:  call free_lists
9:  EPILOGUE

# unpark(ext or 0, run or 0): a parked request of that extension (or run) is answered cancelled
#   and its question withdrawn (the run ended, the extension stopped)
unpark:
    PROLOGUE
    mov rbx, [rip + parked_ext]
    test rbx, rbx
    jz 9f
    test rdi, rdi
    jz 1f
    cmp rdi, rbx
    jne 9f
1:  test rsi, rsi
    jz 2f
    cmp rsi, [rip + parked_run]
    jne 9f
2:  mov qword ptr [rip + parked_ext], 0
    lea rdi, [rip + parked_ext]
    call run_approve_cancel
    mov rdi, rbx
    call testproto_agreed
    test eax, eax
    jz 8f
    mov rdi, rbx
    call testproto_set_ext
    mov rdi, [rip + parked_id]
    lea rsi, [rip + .Le_cancelled]
    call testproto_reply_error
8:  call free_lists
9:  EPILOGUE

# command_line(): cmdline holds the command as the approval question shows it: the program and its
#   arguments, those with spaces or quotes in single quotes
command_line:
    PROLOGUE
    lea rdi, [rip + eb]
    call sb_clear
    xor ebx, ebx
1:  cmp rbx, [rip + args + VEC_len]
    jae 5f
    test rbx, rbx
    jz 2f
    lea rdi, [rip + eb]
    mov esi, ' '
    call sb_push_byte
2:  mov rax, [rip + args + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov rdi, r12
    call strlen
    mov r13, rax
    xor ecx, ecx                # quoted?
    xor edx, edx
3:  cmp rdx, r13
    jae 4f
    movzx eax, byte ptr [r12 + rdx]
    inc rdx
    cmp eax, ' '
    jbe 31f
    cmp eax, 39
    je 31f
    cmp eax, '"'
    je 31f
    cmp eax, '$'
    je 31f
    jmp 3b
31: mov ecx, 1
4:  test r13, r13
    jnz 41f
    mov ecx, 1
41: mov r14d, ecx
    test r14d, r14d
    jz 42f
    lea rdi, [rip + eb]
    mov esi, 39
    call sb_push_byte
42: xor r15d, r15d              # its bytes, line breaks and other controls shown as spaces
44: cmp r15, r13
    jae 45f
    movzx esi, byte ptr [r12 + r15]
    inc r15
    cmp esi, ' '
    jae 46f
    mov esi, ' '
46: lea rdi, [rip + eb]
    call sb_push_byte
    jmp 44b
45: test r14d, r14d
    jz 43f
    lea rdi, [rip + eb]
    mov esi, 39
    call sb_push_byte
43: inc rbx
    cmp qword ptr [rip + eb + SB_len], 4000
    jb 1b
5:  mov rcx, [rip + eb + SB_len]
    cmp rcx, 4000
    jbe 6f
    mov ecx, 4000
6:  lea rdi, [rip + cmdline]
    mov rsi, [rip + eb + SB_ptr]
    mov rdx, rcx
    push rcx
    push rcx
    call memcpy
    pop rcx
    pop rcx
    lea rax, [rip + cmdline]
    mov byte ptr [rax + rcx], 0
    EPILOGUE

# exec_start(ext, id, run): the approved program starts: found on the user's PATH (the login
#   environment's), its folder checked, then the slot, its pipes watched and "ok ID EXEC"; the
#   reply goes to testproto's current extension
exec_start:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], rsi
    mov r12, rdx
    xor r13d, r13d              # the program's path (owned)
    mov rdi, [rip + envs + VEC_ptr]
    xor esi, esi
    xor edx, edx
    call uproc_env_make
    mov [rsp + 8], rax          # envp: the login environment and the variables
    cmp dword ptr [rip + g_remote], 0
    jne .Lxs_remote
    mov rax, [rip + args + VEC_ptr]
    mov rdi, [rax]
    mov rsi, [rsp + 8]
    call uproc_which
    test rax, rax
    jz .Lxs_nofile
    mov r13, rax
    # the folder: inside the project once links are resolved (none: the project)
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz .Lxs_cwd
    lea rsi, [rip + realproj]
    call ext_realpath
    test eax, eax
    jz .Lxs_cwd
    mov rdi, [rip + g_project]
    cmp qword ptr [rip + cmd_cwdlen], 0
    je 3f
    mov rdi, [rip + cmd_cwd]
    mov rsi, [rip + cmd_cwdlen]
    call mem_dup
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + realcwd]
    call ext_realpath
    mov r15d, eax
    mov rdi, r14
    call mem_free
    mov eax, r15d
    jmp 31f
3:  lea rsi, [rip + realcwd]
    call ext_realpath
31: test eax, eax
    jz .Lxs_cwd
    lea rdi, [rip + realcwd]
    lea rsi, [rip + realproj]
    call app_path_inside
    test eax, eax
    jz .Lxs_cwd
    lea rdi, [rip + realcwd]
    call vfs_is_dir
    test eax, eax
    jz .Lxs_cwd
    # argv: the path, then the arguments
    mov rax, [rip + args + VEC_ptr]
    mov rdi, [rax]
    call mem_free
    mov rax, [rip + args + VEC_ptr]
    mov [rax], r13
    xor r13d, r13d              # args owns it now
.Lxs_spawn:
    mov rdi, [rip + args + VEC_ptr]
    mov rsi, [rsp + 8]
    cmp dword ptr [rip + g_remote], 0
    je 1f
    mov rsi, [rip + envs + VEC_ptr]  # a remote window: only the request's variables (the host
1:  lea rdx, [rip + realcwd]         #   has its own environment)
    call testexec_spawn
    mov r15, rax
    test r15, r15
    js .Lxs_failed
    # the slot
    lea rax, [rip + procs]
    xor ecx, ecx
4:  cmp qword ptr [rax + TSX_ext], 0
    je 5f
    add rax, TSX_SIZE
    inc ecx
    cmp ecx, TS_PROCS_ALL
    jb 4b
5:  mov r14, rax
    mov rdi, r14
    xor esi, esi
    mov edx, TSX_SIZE
    call memset
    mov [r14 + TSX_ext], rbx
    mov [r14 + TSX_run], r12
    mov rax, [r12 + TSR_num]
    mov [r14 + TSX_runnum], rax
    inc qword ptr [rip + exec_next]
    mov rax, [rip + exec_next]
    mov [r14 + TSX_exec], rax
    mov [r14 + TSX_pid], r15d
    mov dword ptr [r14 + TSX_status], -1
    mov eax, [rip + pipe_out]
    mov [r14 + TSX_out], eax
    mov eax, [rip + pipe_err]
    mov [r14 + TSX_err], eax
    inc dword ptr [r12 + TSR_procs]
    mov edi, [r14 + TSX_out]
    mov esi, POLLIN
    lea rdx, [rip + on_pipe]
    mov rcx, r14
    call watch_add
    mov edi, [r14 + TSX_err]
    test edi, edi
    js 6f                       # a remote window's program: its errors come with its output
    mov esi, POLLIN
    lea rdx, [rip + on_pipe]
    mov rcx, r14
    call watch_add
6:  mov rdi, [rsp]
    mov rsi, [r14 + TSX_exec]
    call testproto_reply_ok_u64
    mov dword ptr [rip + g_ts_dirty], 1
    mov dword ptr [rip + g_dirty], 1
    jmp .Lxs_done
.Lxs_remote:
    # a remote window: the host finds the program on its PATH and the folder is checked as written
    # (inside the project, normalized), since its links are the host's
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz .Lxs_cwd
    lea rdi, [rip + realproj]
    call cstr_copy
    lea rdi, [rip + realcwd]
    lea rsi, [rip + realproj]
    call cstr_copy
    cmp qword ptr [rip + cmd_cwdlen], 0
    je .Lxs_spawn
    lea rdi, [rip + realcwd]
    mov rsi, [rip + cmd_cwd]
    mov rdx, [rip + cmd_cwdlen]
    call memcpy
    mov rax, [rip + cmd_cwdlen]
    lea rcx, [rip + realcwd]
    mov byte ptr [rcx + rax], 0
    lea rdi, [rip + realcwd]
    call path_rootlen
    test rax, rax
    jz .Lxs_cwd
    lea rdi, [rip + realcwd]
    call path_normalize
    lea rdi, [rip + realcwd]
    lea rsi, [rip + realproj]
    call app_path_inside
    test eax, eax
    jz .Lxs_cwd
    jmp .Lxs_spawn
.Lxs_cwd:
    lea rsi, [rip + .Le_cwd]
    jmp .Lxs_reply
.Lxs_failed:
    lea rsi, [rip + .Le_failed]
    jmp .Lxs_reply
.Lxs_nofile:
    # "nofile NAME not found"
    lea rdi, [rip + eb]
    call sb_clear
    lea rdi, [rip + eb]
    lea rsi, [rip + .Le_nofile]
    call sb_push_cstr
    mov rax, [rip + args + VEC_ptr]
    mov rsi, [rax]
    lea rdi, [rip + eb]
    call sb_push_cstr
    lea rdi, [rip + eb]
    lea rsi, [rip + .Le_not_found]
    call sb_push_cstr
    lea rdi, [rip + eb]
    xor esi, esi
    call sb_push_byte
    mov rsi, [rip + eb + SB_ptr]
.Lxs_reply:
    mov rdi, [rsp]
    call testproto_reply_error
.Lxs_done:
    mov rdi, r13
    call mem_free
    mov rdi, [rsp + 8]
    call mem_free
    call free_lists
    EPILOGUE

# free_lists(): args and envs empty, their strings freed
free_lists:
    PROLOGUE
    lea rbx, [rip + args]
    call list_free
    lea rbx, [rip + envs]
    call list_free
    EPILOGUE
list_free:
    xor r12d, r12d
1:  cmp r12, [rbx + VEC_len]
    jae 2f
    mov rax, [rbx + VEC_ptr]
    mov rdi, [rax + r12*8]
    push rdi
    push rdi
    call mem_free
    pop rdi
    pop rdi
    inc r12
    jmp 1b
2:  mov qword ptr [rbx + VEC_len], 0
    ret

# list_add(vec, ptr, len): an owned cstr copy at the end
list_add:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    push rax
    mov rdi, rbx
    mov esi, 8
    call vec_push
    pop rcx
    mov [rax], rcx
    pop r13
    pop r12
    pop rbx
    ret

# parse_command(body, len) -> rax 0 with cmd_* set and args/envs filled (args[0] a placeholder,
#   both ending in 0), else the error text
parse_command:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    # no NUL anywhere
    xor ecx, ecx
1:  cmp rcx, r12
    jae 2f
    cmp byte ptr [rbx + rcx], 0
    je .Lpc_syntax
    inc rcx
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r12
    call tsb_begin
    call tsb_line
    test rax, rax
    jz .Lpc_syntax
    mov rdi, rax
    mov rsi, rdx
    call tsb_fields
    cmp eax, 4
    jne .Lpc_syntax
    xor edi, edi
    call tsb_num
    test edx, edx
    jz .Lpc_syntax
    test rax, rax
    jz .Lpc_syntax
    cmp rax, TS_PROG_PATH
    ja .Lpc_needs_name
    mov [rip + cmd_proglen], rax
    mov edi, 1
    call tsb_num
    test edx, edx
    jz .Lpc_syntax
    cmp rax, 4095
    ja .Lpc_syntax
    mov [rip + cmd_cwdlen], rax
    mov edi, 2
    call tsb_num
    test edx, edx
    jz .Lpc_syntax
    cmp rax, TS_EXEC_ARGS
    ja .Lpc_toobig
    mov r13, rax                # ARGC
    mov edi, 3
    call tsb_num
    test edx, edx
    jz .Lpc_syntax
    cmp rax, TS_EXEC_ENVS
    ja .Lpc_toobig
    mov r14, rax                # ENVC
    mov rdi, [rip + cmd_proglen]
    call tsb_take
    test rax, rax
    jz .Lpc_syntax
    mov [rip + cmd_prog], rax
    mov rdi, [rip + cmd_cwdlen]
    call tsb_take
    test rax, rax
    jz .Lpc_syntax
    # copied: a request waiting for the approval outlives its body
    lea rdi, [rip + cwd_buf]
    mov rsi, rax
    mov rdx, [rip + cmd_cwdlen]
    call memcpy
    lea rax, [rip + cwd_buf]
    mov rcx, [rip + cmd_cwdlen]
    mov byte ptr [rax + rcx], 0
    mov [rip + cmd_cwd], rax
    # the program: a name [A-Za-z0-9._+-], or a path inside the project to one (a .venv's python)
    mov rdi, [rip + cmd_prog]
    mov rsi, [rip + cmd_proglen]
    call prog_name_ok
    test eax, eax
    jz .Lpc_needs_name
    # args[0] holds the program's name until its path replaces it
    lea rdi, [rip + args]
    mov rsi, [rip + cmd_prog]
    mov rdx, [rip + cmd_proglen]
    call list_add
3:  test r13, r13
    jz 4f
    dec r13
    call counted
    test rax, rax
    jz .Lpc_syntax
    cmp rdx, TS_EXEC_ARG_MAX
    ja .Lpc_toobig
    lea rdi, [rip + args]
    mov rsi, rax
    call list_add
    jmp 3b
4:  test r14, r14
    jz 5f
    dec r14
    call counted
    test rax, rax
    jz .Lpc_syntax
    mov r15, rax
    push rdx
    push rdx
    mov rdi, rax
    mov rsi, rdx
    call env_name_ok
    pop rdx
    pop rdx
    test eax, eax
    jz .Lpc_env
    lea rdi, [rip + envs]
    mov rsi, r15
    call list_add
    jmp 4b
5:  call tsb_left
    test rax, rax
    jnz .Lpc_syntax
    lea rdi, [rip + args]
    mov esi, 8
    call vec_push
    mov qword ptr [rax], 0
    dec qword ptr [rip + args + VEC_len]    # the 0 ends the list without counting
    lea rdi, [rip + envs]
    mov esi, 8
    call vec_push
    mov qword ptr [rax], 0
    dec qword ptr [rip + envs + VEC_len]
    xor eax, eax
    EPILOGUE
.Lpc_syntax:
    lea rax, [rip + .Le_syntax_cmd]
    EPILOGUE
.Lpc_toobig:
    lea rax, [rip + .Le_toobig_cmd]
    EPILOGUE
.Lpc_needs_name:
    lea rax, [rip + .Le_bare]
    EPILOGUE
.Lpc_env:
    lea rax, [rip + .Le_env]
    EPILOGUE

# counted() -> rax the bytes of the next "LEN" LF record, rdx LEN; rax 0 when malformed
counted:
    push rbx
    call tsb_line
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call tsb_fields
    cmp eax, 1
    jne 8f
    xor edi, edi
    call tsb_num
    test edx, edx
    jz 8f
    mov rbx, rax
    mov rdi, rax
    call tsb_take
    test rax, rax
    jz 8f
    mov rdx, rbx
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret

# bare_name(ptr, len) -> eax 1 for [A-Za-z0-9._+-]+ (not "." or "..")
# prog_name_ok(ptr, len) -> eax 1 for a bare name (bare_name), or an absolute path inside the project
#   (no "..") whose last part is one
prog_name_ok:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    cmp r13, TS_PROG_NAME
    ja 1f
    call bare_name
    test eax, eax
    jnz 9f
1:  cmp byte ptr [r12], '/'
    jne 8f
    mov rbx, [rip + g_project]  # the project's folder, then a slash
    test rbx, rbx
    jz 8f
    mov rdi, rbx
    call strlen
    mov r14, rax
    cmp r14, r13
    jae 8f
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r14
    call memeq
    test eax, eax
    jz 8f
    cmp byte ptr [r12 + r14], '/'
    jne 8f
    xor ecx, ecx                # no ".." part
2:  lea rdx, [rcx + 3]
    cmp rdx, r13
    ja 3f
    cmp word ptr [r12 + rcx], 0x2e2f    # "/."
    jne 21f
    cmp byte ptr [r12 + rcx + 2], '.'
    jne 21f
    lea rdx, [rcx + 3]
    cmp rdx, r13
    je 8f
    cmp byte ptr [r12 + rcx + 3], '/'
    je 8f
21: inc rcx
    jmp 2b
3:  mov rcx, r13                # the last part
4:  test rcx, rcx
    jz 8f
    cmp byte ptr [r12 + rcx - 1], '/'
    je 5f
    dec rcx
    jmp 4b
5:  lea rdi, [r12 + rcx]
    mov rsi, r13
    sub rsi, rcx
    call bare_name
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

bare_name:
    test rsi, rsi
    jz 8f
    cmp byte ptr [rdi], '.'
    je 8f
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 7f
    movzx eax, byte ptr [rdi + rcx]
    inc rcx
    cmp eax, '.'
    je 1b
    cmp eax, '_'
    je 1b
    cmp eax, '+'
    je 1b
    cmp eax, '-'
    je 1b
    lea edx, [rax - '0']
    cmp edx, 9
    jbe 1b
    or eax, 0x20
    lea edx, [rax - 'a']
    cmp edx, 25
    jbe 1b
8:  xor eax, eax
    ret
7:  mov eax, 1
    ret

# env_name_ok(ptr, len) -> eax 1 for NAME=VALUE with NAME [A-Z_][A-Z0-9_]*
env_name_ok:
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 8f
    movzx eax, byte ptr [rdi + rcx]
    cmp eax, '='
    je 6f
    inc rcx
    cmp eax, '_'
    je 1b
    lea edx, [rax - 'A']
    cmp edx, 25
    jbe 1b
    cmp rcx, 1                  # not a digit first
    je 8f
    lea edx, [rax - '0']
    cmp edx, 9
    jbe 1b
8:  xor eax, eax
    ret
6:  test rcx, rcx
    jz 8b
    mov eax, 1
    ret

# prog_allowed(ext) -> eax 1 when cmd_prog is a word of its [needs] tests, or a path whose last part
#   is one (a project's .venv/bin/python for `python`; the approval shows the whole command)
prog_allowed:
    PROLOGUE 16
    mov rax, [rip + cmd_prog]   # the name: after the path's last slash
    mov rcx, [rip + cmd_proglen]
    mov [rsp], rax
    mov [rsp + 8], rcx
    xor edx, edx
0:  cmp rdx, rcx
    jae 01f
    cmp byte ptr [rax + rdx], '/'
    jne 02f
    lea r8, [rax + rdx + 1]
    mov [rsp], r8
    mov r9, rcx
    sub r9, rdx
    dec r9
    mov [rsp + 8], r9
02: inc rdx
    jmp 0b
01: mov r12, [rdi + EXT_tests_progs]
    test r12, r12
    jz 8f
    mov rdi, r12
    call strlen
    mov r13, rax
1:  test r13, r13
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    test rcx, rcx
    jz 8f                       # a path ending in a slash
    call str_eq
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# testexec_spawn(argv, envp, cwd) -> rax pid or -errno, with pipe_out and pipe_err the nonblocking
#   read ends of its output and error. The one place a test process starts: through uproc_spawn
#   (input from the null device, a session and process group of its own, never confined), or on a
#   remote window's host
FN testexec_spawn
    PROLOGUE 48
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    cmp dword ptr [rip + g_remote], 0
    je 1f
    # a remote window: the program runs on the host (vfs.s), its errors merged with its output
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, 1
    call vfs_run_piped_input
    test rax, rax
    js 9f
    mov [rip + pipe_out], edx
    mov dword ptr [rip + pipe_err], -1
    EPILOGUE
1:
    mov dword ptr [rsp + 16], -1
    mov dword ptr [rsp + 20], -1
    mov dword ptr [rsp + 24], -1
    mov dword ptr [rsp + 28], -1
    lea rdi, [rip + .Ldevnull]
    mov esi, O_RDWR | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 9f
    mov ebx, eax
    lea rdi, [rsp + 16]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js 7f
    lea rdi, [rsp + 24]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js 7f
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov ecx, ebx
    mov r8d, [rsp + 20]
    mov r9d, [rsp + 28]
    xor eax, eax                # no terminal
    push rax
    push rax
    call uproc_spawn            # outside the sandbox, a group of its own, dies with rhun
    add rsp, 16
    mov r15, rax
    mov edi, [rsp + 20]
    SYS SYS_close
    mov edi, [rsp + 28]
    SYS SYS_close
    mov edi, ebx
    SYS SYS_close
    test r15, r15
    js 6f
    mov edi, [rsp + 16]
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov edi, [rsp + 24]
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov eax, [rsp + 16]
    mov [rip + pipe_out], eax
    mov eax, [rsp + 24]
    mov [rip + pipe_err], eax
    mov rax, r15
    EPILOGUE
6:  mov edi, [rsp + 16]
    SYS SYS_close
    mov edi, [rsp + 24]
    SYS SYS_close
    mov rax, r15
    EPILOGUE
7:  mov r15, rax
    mov edi, ebx
    SYS SYS_close
    mov edi, [rsp + 16]
    test edi, edi
    js 71f
    SYS SYS_close
    mov edi, [rsp + 20]
    SYS SYS_close
71: mov rax, r15
9:  EPILOGUE

# on_pipe(fd, events, TSX*): what the process wrote, as a test-out event; end of file closes the pipe
on_pipe:
    PROLOGUE
    mov r12d, edi
    mov rbx, rdx
    cmp qword ptr [rbx + TSX_ext], 0
    je 9f
    # back-pressure: the extension's queue first
    cmp dword ptr [rbx + TSX_orphan], 0
    jne 1f
    mov rdi, [rbx + TSX_ext]
    call queue_full
    test eax, eax
    jz 1f
    mov rdi, rbx
    call pause_pipes
    jmp 9f
1:  mov edi, r12d
    lea rsi, [rip + rbuf]
    mov edx, TS_OUT_EVENT
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 5f
    mov r13, rax
    cmp dword ptr [rbx + TSX_orphan], 0
    jne 9f
    # "0 test-out EXEC STREAM LEN" + the bytes
    lea rdi, [rip + eb]
    call sb_clear
    lea rdi, [rip + eb]
    lea rsi, [rip + .Lev_out]
    call sb_push_cstr
    lea rdi, [rip + eb]
    mov rsi, [rbx + TSX_exec]
    call sb_push_u64
    lea rsi, [rip + .Ls_out]
    cmp r12d, [rbx + TSX_out]
    je 2f
    lea rsi, [rip + .Ls_err]
2:  lea rdi, [rip + eb]
    call sb_push_cstr
    lea rdi, [rip + eb]
    mov rsi, r13
    call sb_push_u64
    lea rdi, [rip + eb]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + eb]
    lea rsi, [rip + rbuf]
    mov rdx, r13
    call sb_push
    mov rdi, [rbx + TSX_ext]
    mov rsi, [rip + eb + SB_ptr]
    mov rdx, [rip + eb + SB_len]
    call testproto_event
    jmp 9f
5:  # end of file or an error: that pipe is done
    mov edi, r12d
    call watch_remove
    mov edi, r12d
    SYS SYS_close
    cmp r12d, [rbx + TSX_out]
    jne 6f
    mov dword ptr [rbx + TSX_out], -1
    jmp 7f
6:  mov dword ptr [rbx + TSX_err], -1
7:  mov rdi, rbx
    call try_finish
9:  EPILOGUE

# queue_full(ext) -> eax 1 while its outgoing queue holds TS_QUEUE_PAUSE bytes or more
queue_full:
    mov rax, [rdi + EXT_wq + SB_len]
    sub rax, [rdi + EXT_wq_off]
    cmp rax, TS_QUEUE_PAUSE
    setae al
    movzx eax, al
    ret

# pause_pipes(TSX*), resume_pipes(TSX*): its open pipes stop (start) being watched for input
pause_pipes:
    xor esi, esi
    mov dword ptr [rdi + TSX_paused], 1
    jmp set_pipes
resume_pipes:
    mov esi, POLLIN
    mov dword ptr [rdi + TSX_paused], 0
set_pipes:
    push rbx
    push r12
    push r12
    mov rbx, rdi
    mov r12d, esi
    mov edi, [rbx + TSX_out]
    test edi, edi
    js 1f
    call watch_set_events
1:  mov edi, [rbx + TSX_err]
    test edi, edi
    js 2f
    mov esi, r12d
    call watch_set_events
2:  pop r12
    pop r12
    pop rbx
    ret

# try_finish(TSX*): once both pipes are closed and the program is reaped, test-exit goes out and the
#   slot is free
try_finish:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + TSX_handed], 0
    je 0f
    cmp dword ptr [rbx + TSX_out], 0
    jge 9f
    cmp dword ptr [rbx + TSX_err], 0
    jge 9f
    mov rdi, rbx
    call report_exit            # "killed"; uproc reaps it
    jmp 9f
0:  cmp dword ptr [rbx + TSX_status], -1
    jne 1f
    mov rdi, rbx
    call reap
1:  cmp dword ptr [rbx + TSX_status], -1
    je 9f
    cmp dword ptr [rbx + TSX_out], 0
    jge 9f
    cmp dword ptr [rbx + TSX_err], 0
    jge 9f
    mov rdi, rbx
    call report_exit
9:  EPILOGUE

# reap(TSX*): its wait status once it has ended, as uproc_wait (proc_wait for a remote window's
#   program) tells it without waiting: exit code N becomes N << 8, 128 + N signal N, as wait4 has them
reap:
    push rbx
    mov rbx, rdi
    mov edi, [rbx + TSX_pid]
    mov esi, 1
    test edi, REMOTE_PID_TAG
    jnz 1f
    call uproc_wait
    jmp 2f
1:  call proc_wait
2:  cmp eax, -1
    je 9f                       # still running
    cmp eax, -2
    jne 3f
    mov dword ptr [rbx + TSX_status], 9    # not ours any more: as if killed
    mov dword ptr [rbx + TSX_killed], 1
    jmp 5f
3:  cmp eax, 129
    jb 4f
    cmp eax, 192
    jae 4f
    sub eax, 128
    mov [rbx + TSX_status], eax
    jmp 5f
4:  shl eax, 8
    mov [rbx + TSX_status], eax
5:  call time_ms
    mov [rbx + TSX_exit_at], rax
9:  pop rbx
    ret

# report_exit(TSX*): "0 test-exit EXEC CODE" (CODE the exit status, "signal N", "killed"); pipes still
#   open are closed; the slot is free
report_exit:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    call close_pipes
    cmp dword ptr [rbx + TSX_orphan], 0
    jne 8f
    lea rdi, [rip + eb]
    call sb_clear
    lea rdi, [rip + eb]
    lea rsi, [rip + .Lev_exit]
    call sb_push_cstr
    lea rdi, [rip + eb]
    mov rsi, [rbx + TSX_exec]
    call sb_push_u64
    lea rdi, [rip + eb]
    mov esi, ' '
    call sb_push_byte
    cmp dword ptr [rbx + TSX_killed], 0
    je 1f
    lea rdi, [rip + eb]
    lea rsi, [rip + .Ls_killed]
    call sb_push_cstr
    jmp 3f
1:  mov eax, [rbx + TSX_status]
    mov ecx, eax
    and ecx, 0x7f
    jz 2f
    push rcx
    push rcx
    lea rdi, [rip + eb]
    lea rsi, [rip + .Ls_signal]
    call sb_push_cstr
    pop rsi
    pop rsi
    lea rdi, [rip + eb]
    call sb_push_u64
    jmp 3f
2:  shr eax, 8
    and eax, 0xff
    lea rdi, [rip + eb]
    mov esi, eax
    call sb_push_u64
3:  lea rdi, [rip + eb]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rbx + TSX_ext]
    mov rsi, [rip + eb + SB_ptr]
    mov rdx, [rip + eb + SB_len]
    call testproto_event
8:  # its run counts one process less (when it is still that run)
    mov rax, [rbx + TSX_run]
    mov rcx, [rbx + TSX_runnum]
    cmp [rax + TSR_num], rcx
    jne 81f
    cmp dword ptr [rax + TSR_procs], 0
    je 81f
    dec dword ptr [rax + TSR_procs]
81: mov rdi, rbx
    xor esi, esi
    mov edx, TSX_SIZE
    call memset
    mov dword ptr [rip + g_ts_dirty], 1
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# close_pipes(TSX*): the pipes still open, unwatched and closed
close_pipes:
    push rbx
    mov rbx, rdi
    mov edi, [rbx + TSX_out]
    test edi, edi
    js 1f
    call watch_remove
    mov edi, [rbx + TSX_out]
    SYS SYS_close
    mov dword ptr [rbx + TSX_out], -1
1:  mov edi, [rbx + TSX_err]
    test edi, edi
    js 2f
    call watch_remove
    mov edi, [rbx + TSX_err]
    SYS SYS_close
    mov dword ptr [rbx + TSX_err], -1
2:  pop rbx
    ret

# stop(TSX*, signal): the signal to its process group, while the group's number is still held (its
#   leader not reaped, or a pipe still open, which a member of the group keeps)
stop:
    mov dword ptr [rdi + TSX_killed], 1
    cmp dword ptr [rdi + TSX_status], -1
    je 1f
    cmp dword ptr [rdi + TSX_out], 0
    jge 1f
    cmp dword ptr [rdi + TSX_err], 0
    jge 1f
    ret
1:  push rbx
    mov rbx, rdi
    mov edi, [rbx + TSX_pid]
    test edi, REMOTE_PID_TAG
    jnz 2f
    call uproc_signal           # its whole group, while it is ours
    pop rbx
    ret
2:  neg edi
    call proc_kill              # a remote window's program
    pop rbx
    ret

# term(TSX*): SIGTERM now, SIGKILL in 2 s
term:
    push rbx
    mov rbx, rdi
    cmp qword ptr [rbx + TSX_term_at], 0
    jne 9f
    mov dword ptr [rbx + TSX_killed], 1
    call time_ms
    mov [rbx + TSX_term_at], rax
    cmp dword ptr [rbx + TSX_status], -1
    jne 9f                      # reaped: its group is no longer ours to signal
    test dword ptr [rbx + TSX_pid], REMOTE_PID_TAG
    jnz 1f
    # uproc keeps the group to the end: SIGTERM now, SIGKILL in 2 s even when the leader is gone
    # by then (a child that ignores SIGTERM dies too), reaped there
    mov dword ptr [rbx + TSX_handed], 1
    mov edi, [rbx + TSX_pid]
    mov esi, TS_CANCEL_KILL_MS
    call uproc_end
    jmp 9f
1:  mov rdi, rbx
    mov esi, SIGTERM
    call stop
9:  pop rbx
    ret

# testexec_run_over(run): the run ended: its processes stop (SIGTERM, then SIGKILL)
FN testexec_run_over
    PROLOGUE
    mov r12, rdi
    xor edi, edi
    mov rsi, r12
    call unpark
    lea rbx, [rip + procs]
    xor r13d, r13d
1:  cmp qword ptr [rbx + TSX_ext], 0
    je 2f
    cmp [rbx + TSX_run], r12
    jne 2f
    mov rdi, rbx
    call term
2:  add rbx, TSX_SIZE
    inc r13d
    cmp r13d, TS_PROCS_ALL
    jb 1b
    EPILOGUE

# testexec_run_kill(run): Cancel's deadline: the same
FN testexec_run_kill
    jmp testexec_run_over

# testexec_ext_gone(ext): its program stopped: its processes stop, and nothing more is sent
FN testexec_ext_gone
    PROLOGUE
    mov r12, rdi
    xor esi, esi
    call unpark
    lea rbx, [rip + procs]
    xor r13d, r13d
1:  cmp [rbx + TSX_ext], r12
    jne 2f
    mov dword ptr [rbx + TSX_orphan], 1
    cmp dword ptr [rbx + TSX_paused], 0
    je 11f
    mov rdi, rbx
    call resume_pipes           # drained and dropped from now on
11: mov rdi, rbx
    call term
2:  add rbx, TSX_SIZE
    inc r13d
    cmp r13d, TS_PROCS_ALL
    jb 1b
    EPILOGUE

# testexec_quit(): rhun quits: every test process group is killed and reaped
FN testexec_quit
    PROLOGUE
    lea rbx, [rip + procs]
    xor r13d, r13d
1:  cmp qword ptr [rbx + TSX_ext], 0
    je 2f
    mov dword ptr [rbx + TSX_orphan], 1
    mov rdi, rbx
    mov esi, SIGKILL
    call stop
    cmp dword ptr [rbx + TSX_status], -1
    jne 11f
    mov edi, [rbx + TSX_pid]
    xor esi, esi
    call proc_wait
11: mov rdi, rbx
    call close_pipes
2:  add rbx, TSX_SIZE
    inc r13d
    cmp r13d, TS_PROCS_ALL
    jb 1b
    EPILOGUE

# testexec_tick(): reap ended programs, resume paused pipes, the SIGKILL after a SIGTERM, close pipes
#   a child keeps open past its program's end
FN testexec_tick
    PROLOGUE
    call time_ms
    mov r14, rax
    lea rbx, [rip + procs]
    xor r13d, r13d
1:  cmp qword ptr [rbx + TSX_ext], 0
    je 6f
    cmp dword ptr [rbx + TSX_paused], 0
    je 2f
    cmp dword ptr [rbx + TSX_orphan], 0
    jne 11f
    mov rdi, [rbx + TSX_ext]
    call queue_full
    test eax, eax
    jnz 2f
11: mov rdi, rbx
    call resume_pipes
2:  cmp dword ptr [rbx + TSX_handed], 0
    je 21f
    mov rcx, r14                # handed to uproc: done once its pipes close, or a while after
    sub rcx, [rbx + TSX_term_at] #   the SIGKILL with pipes a stray process keeps
    cmp rcx, TS_CANCEL_KILL_MS + TSX_LINGER_MS
    jb 6f
    mov rdi, rbx
    call report_exit
    jmp 6f
21: cmp dword ptr [rbx + TSX_status], -1
    jne 3f
    mov rdi, rbx
    call reap
3:  mov rax, [rbx + TSX_term_at]
    test rax, rax
    jz 4f
    mov rcx, r14
    sub rcx, rax
    cmp rcx, TS_CANCEL_KILL_MS
    jb 4f
    mov rdi, rbx
    mov esi, SIGKILL
    call stop                   # a remote window's program (local ones are handed)
4:  cmp dword ptr [rbx + TSX_status], -1
    je 6f
    # ended: done when its pipes are, or a while after with pipes a child keeps
    cmp dword ptr [rbx + TSX_out], 0
    jge 5f
    cmp dword ptr [rbx + TSX_err], 0
    jge 5f
    mov rdi, rbx
    call report_exit
    jmp 6f
5:  mov rcx, r14
    sub rcx, [rbx + TSX_exit_at]
    cmp rcx, TSX_LINGER_MS
    jb 6f
    mov rdi, rbx
    call report_exit
6:  add rbx, TSX_SIZE
    inc r13d
    cmp r13d, TS_PROCS_ALL
    jb 1b
    EPILOGUE

# testexec_timeout() -> rax ms until testexec_tick should look again, -1 with no process
FN testexec_timeout
    mov rax, -1
    lea rcx, [rip + procs]
    xor edx, edx
1:  cmp qword ptr [rcx + TSX_ext], 0
    je 2f
    mov eax, 50                 # a running program is polled for its end; pipes wake rhun anyway
    cmp dword ptr [rcx + TSX_paused], 0
    je 2f
    mov eax, 10
    ret
2:  add rcx, TSX_SIZE
    inc edx
    cmp edx, TS_PROCS_ALL
    jb 1b
    ret

# testexec_dump(sb): print-test-procs: "exec=N run=N pid=P state=running|ended killed=0|1
#   paused=0|1" per process
FN testexec_dump
    PROLOGUE
    mov r12, rdi
    lea rbx, [rip + procs]
    xor r13d, r13d
1:  cmp qword ptr [rbx + TSX_ext], 0
    je 2f
    mov rdi, r12
    lea rsi, [rip + .Lp_exec]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + TSX_exec]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Lp_run]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + TSX_runnum]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Lp_killed]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + TSX_killed]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Lp_paused]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + TSX_paused]
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
2:  add rbx, TSX_SIZE
    inc r13d
    cmp r13d, TS_PROCS_ALL
    jb 1b
    EPILOGUE

.section .rodata
.Ldevnull: .asciz "/dev/null"
.Lev_out: .asciz "0 test-out "
.Lev_exit: .asciz "0 test-exit "
.Ls_out: .asciz " out "
.Ls_err: .asciz " err "
.Ls_killed: .asciz "killed"
.Ls_signal: .asciz "signal "
.Le_untrusted: .asciz "refused folder not trusted"
.Le_busy: .asciz "busy 4 processes per run, 8 in all"
.Le_busy_open: .asciz "busy a question is open"
.Le_cancelled: .asciz "cancelled"
.Le_failed: .asciz "refused the program could not be started"
.Le_cwd: .asciz "refused the folder is not inside the project"
.Le_needs: .asciz "needs tests="
.Le_nofile: .asciz "nofile "
.Le_not_found: .asciz " not found"
.Le_syntax_cmd: .asciz "syntax bad command body"
.Le_toobig_cmd: .asciz "toobig 1000 arguments of 32 KB, 64 variables"
.Le_bare: .asciz "refused the program must be a bare name"
.Le_env: .asciz "syntax a variable is NAME=VALUE with NAME of A-Z, 0-9 and _"
.Lp_exec: .asciz "exec="
.Lp_run: .asciz " run="
.Lp_killed: .asciz " killed="
.Lp_paused: .asciz " paused="
