# git: the project's repository, the status of its files, open files as they are at HEAD
.include "rhun.inc"

# a git program running in the background
STRUCT
F JB_pid, 4
F JB_fd, 4
F JB_out, SB_SIZE
F JB_cb, 8              # cb(ctx, ptr, len, status); the job frees ctx afterwards
F JB_ctx, 8
F JB_gen, 4             # answers for an older repository are dropped
F JB_in, 4              # the pipe to its input while rhun feeds it (git_start), else -1
F JB_cap, 8             # most output bytes wanted (git_start), 0 no limit; more ends the program
F JB_over, 4            # the output went over JB_cap: cb gets status -1
F JB_pad, 4
F JB_inbuf, 8           # the input being fed, owned
F JB_inlen, 8
F JB_inoff, 8           # of it, written so far
ENDSTRUCT JB_SIZE

# status table slot
STRUCT
F GE_ptr, 8             # path in the work tree, points into stbuf
F GE_len, 4
F GE_code, 1            # 'M' 'A' 'U' 'D' 'R' 'C', 0 = empty slot
F GE_dir, 1             # 1 folder with changes below it, 2 untracked folder
F GE_pad, 2
ENDSTRUCT GE_SIZE

.equ DEBOUNCE, 150
.equ MAXARGS, 24
.equ BATCH_IN, 32768
.equ PIPE_IN, 61440             # input up to this fits the pipe: written at once (run_piped_input)

.bss
.p2align 3
files_gen: .quad 0              # (phase 4 task 7) git_files_gen
.globl g_git_on, g_git_ver, g_git_changes, g_git_root, g_git_rootlen, g_git_paused, g_project_link
.globl g_git_paused_text
.globl g_git_head, g_git_ahead, g_git_behind, g_git_upstream, g_worktree
g_git_on: .long 0               # the setting is on, there is a repository and a git program
g_git_paused: .long 0           # a rhun:// link opened the project, in a repository not trusted yet:
                                # git runs no command there (the repository's config could name one)
g_project_link: .long 0         # a rhun:// link opened the project (set_project)
g_git_ver: .long 0              # changes with every new status
g_git_changes: .long 0          # entries in the status
g_git_head: .long 0             # HD_*
g_git_ahead: .long 0            # commits of HEAD its upstream does not have
g_git_behind: .long 0           # and the other way round
g_git_upstream: .zero 256       # "origin/main", "" when the branch has none
g_worktree: .zero 64            # the folder of a linked work tree, "" in the main one
gen: .long 0
bin_tried: .long 0
st_running: .long 0
st_again: .long 0
touch_kind: .long 0             # 1 status, 2 HEAD moved
sudirs: .long 0                 # untracked folders in the table
run_flags: .long 0              # run_git: run_piped_input's errors flag
run_any: .long 0                # run_git: git_start_in: no repository of this module needed
run_nolit: .long 0              # run_git: no --literal-pathspecs (git_start_in_plain: check-ignore refuses it)
.p2align 3
run_cap: .quad 0                # run_git: JB_cap
run_cwd: .quad 0                # run_git: where git runs (git_start_in), 0: the work tree
git_track: .quad 0              # the path whose repository this module follows (owned), or 0
prim_root: .quad 0              # the project's repository (git_set_project): work tree, owned
prim_common: .quad 0            # and its common .git directory
prim_wt: .long 0                # its work tree is a linked one
.p2align 3
g_git_root: .quad 0             # work tree
g_git_rootlen: .quad 0
gitdir: .quad 0
commondir: .quad 0
logsdir: .quad 0
refsdir: .quad 0
git_bin: .quad 0
env: .quad 0
jobs: .zero VEC_SIZE            # JB*
stbuf: .zero SB_SIZE            # output of the last status
stab: .quad 0                   # GE slots
scap: .quad 0
sused: .quad 0
touch_at: .quad 0
seq: .quad 0
tmp: .zero SB_SIZE
docs: .zero VEC_SIZE

.text

# ---------------- repository ----------------

# Shared identity for all checkouts of a repository, or the standalone project.
FN git_repository_id
    mov rax, [rip + prim_common]
    test rax, rax
    jnz 1f
    mov rax, [rip + g_project]
1:  ret

# git_common_dir() -> the repository's common .git directory, or 0 outside a repository
FN git_common_dir
    mov rax, [rip + commondir]
    ret

# git_project_common_dir() -> the project's repository's common .git directory (agents), whichever
#   repository is shown, or 0
FN git_project_common_dir
    mov rax, [rip + prim_common]
    ret

# git_gitdir() -> the work tree's own git directory (a linked work tree's under worktrees/), or 0
FN git_gitdir
    mov rax, [rip + gitdir]
    ret

# git_status_records() -> rax ptr, rdx len of the last status's "XY path\0" records (after the branch
#   line; a rename or copy has the old name after it, NUL-ended too); 0, 0 before the first status
FN git_status_records
    mov rax, [rip + stbuf + SB_ptr]
    mov rdx, [rip + stbuf + SB_len]
    test rax, rax
    jnz 1f
    xor edx, edx
1:  ret

# git_set_project(): find the repository of g_project and start over
FN git_set_project
    mov rdi, [rip + g_project]
    mov esi, 1
    jmp set_root
# git_set_root(path or 0): find the repository of path and start over. The repository rhun shows
#   (status, Source Control, history, the branch) follows the active document's workspace folder
#   (resources group, gitrepos.s); agents keep the project's (git_each_agent_worktree)
FN git_set_root
    xor esi, esi
set_root:
    PROLOGUE 16
    mov [rsp], esi
    xor eax, eax
    test rdi, rdi               # an own copy: the path may be one of those freed below
    jz 0f
    call dup_cstr
0:  mov rdi, [rip + git_track]
    mov [rip + git_track], rax
    call mem_free
    call gitdata_reset          # extensions' git requests end here, before their jobs are dropped
    inc dword ptr [rip + gen]
    mov dword ptr [rip + g_git_on], 0
    mov dword ptr [rip + g_git_paused], 0
    mov dword ptr [rip + st_running], 0
    mov dword ptr [rip + st_again], 0
    mov dword ptr [rip + touch_kind], 0
    mov qword ptr [rip + touch_at], 0
    call status_clear
    mov byte ptr [rip + g_branch], 0
    mov byte ptr [rip + g_worktree], 0
    lea rbx, [rip + g_git_root]
    mov rdi, [rbx]
    call mem_free
    mov qword ptr [rbx], 0
    mov qword ptr [rip + g_git_rootlen], 0
    lea rbx, [rip + gitdir]
    call free_path
    lea rbx, [rip + commondir]
    call free_path
    lea rbx, [rip + logsdir]
    call free_path
    lea rbx, [rip + refsdir]
    call free_path
    call docs_reset
    call gitview_reset
    call scm_reset
    cmp qword ptr [rip + git_track], 0
    je 9f
    call find_repo
    cmp qword ptr [rip + gitdir], 0
    je 9f
    call git_read_branch
    call watch_repo
    # a repository a link opened runs git once trusted (git_trust); it is paused with git off too, so
    # that no session or restart keeps it as a folder opened by hand for when git is turned on
    cmp dword ptr [rip + g_project_link], 0
    je 2f
    mov rdi, [rip + g_git_root]
    call session_trusted
    test eax, eax
    jnz 2f
    mov dword ptr [rip + g_git_paused], 1
    jmp 9f
2:  cmp dword ptr [rip + cfg_git], 0
    je 9f
    cmp dword ptr [rip + bin_tried], 0
    jne 1f
    mov dword ptr [rip + bin_tried], 1
    lea rdi, [rip + .Lgit]
    cmp dword ptr [rip + g_remote], 0     # remote hosts: the host's git, found there by its name
    jne 3f
    call proc_which
    jmp 4f
3:  call dup_cstr
4:  mov [rip + git_bin], rax
    lea rdi, [rip + env_extras]
    call env_make
    mov [rip + env], rax
1:  cmp qword ptr [rip + git_bin], 0
    je 9f
    mov dword ptr [rip + g_git_on], 1
    # status and the open files' bases right away
    mov dword ptr [rip + touch_kind], 3
    call time_ms
    mov [rip + touch_at], rax
9:  cmp dword ptr [rsp], 0
    je 91f
    call prim_record
91: # the when-clause key gitTrusted (source control, wider-parity C)
    xor esi, esi
    cmp dword ptr [rip + g_git_paused], 0
    sete sil
    mov edi, CTX_GIT_TRUSTED
    call ctx_set_bool
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# prim_record(): the project's repository, for agents whatever repository the UI shows
prim_record:
    PROLOGUE
    lea rbx, [rip + prim_root]
    call free_path
    lea rbx, [rip + prim_common]
    call free_path
    mov rdi, [rip + g_git_root]
    test rdi, rdi
    jz 1f
    call dup_cstr
    mov [rip + prim_root], rax
1:  mov rdi, [rip + commondir]
    test rdi, rdi
    jz 2f
    call dup_cstr
    mov [rip + prim_common], rax
2:  movzx eax, byte ptr [rip + g_worktree]
    mov [rip + prim_wt], eax
    EPILOGUE

# free_path(): mem_free [rbx] and clear it
free_path:
    mov rdi, [rbx]
    call mem_free
    mov qword ptr [rbx], 0
    ret

# git_apply(): follow the setting (a paused repository stays so)
FN git_apply
    xor eax, eax
    cmp dword ptr [rip + cfg_git], 0
    je 1f
    cmp qword ptr [rip + gitdir], 0
    je 1f
    cmp dword ptr [rip + g_git_paused], 0
    jne 1f
    mov eax, 1
1:  cmp eax, [rip + g_git_on]
    jne git_set_project
    ret

# git_trust(): the repository a link opened is trusted from now on (session_trust), and git starts there
FN git_trust
    cmp dword ptr [rip + g_git_paused], 0
    je 1f
    push rax
    mov rdi, [rip + g_git_root]
    call session_trust
    pop rax
    mov dword ptr [rip + g_project_link], 0
    jmp git_set_project
1:  ret

# find_repo(): the repository of git_track (the project, or another workspace folder)
find_repo:
    PROLOGUE
    mov rdi, [rip + git_track]
    call git_find_repo
    test rax, rax
    jz 9f
    mov [rip + gitdir], rax
    mov [rip + g_git_root], rdx
    mov [rip + g_git_rootlen], rcx
9:  EPILOGUE

# git_find_repo(path) -> rax its repository's git directory (owned) or 0, rdx the work tree (owned),
#   rcx its length: walks up from path to the directory holding .git
FN git_find_repo
    PROLOGUE 16
    mov [rsp], rdi
    call strlen
    mov r13, rax
    mov rdi, [rsp]
    mov rsi, rax
    call mem_dup
    mov r12, rax                # directory, cut in place
.Lfr_try:
    mov byte ptr [r12 + r13], 0
    mov rdi, r12
    lea rsi, [rip + .Ldotgit]
    call path_join
    mov rbx, rax
    mov rdi, rax
    call vfs_is_dir
    test eax, eax
    jnz .Lfr_found
    mov rdi, rbx
    call vfs_read_all
    test rax, rax
    jnz .Lfr_file
    mov rdi, rbx
    call mem_free
    mov rdi, r12
    call path_rootlen
    cmp r13, rax
    jbe .Lfr_none
    mov rdi, r12
    mov rsi, r13
    call path_dirlen
    mov r13, rax
    test rax, rax
    jnz .Lfr_try
    # only a path rooted at / has / above it: a relative or C:\ one would try its first letter forever
    cmp byte ptr [r12], '/'
    jne .Lfr_none
    mov r13d, 1                 # "/"
    jmp .Lfr_try
.Lfr_file:
    # "gitdir: path" (worktrees, submodules)
    mov r14, rax
    mov r15, rdx
    mov rdi, rbx
    call mem_free
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lgitdir_pfx]
    mov ecx, 8
    call str_starts
    test eax, eax
    jz .Lfr_bad
    lea rsi, [r14 + 8]
    lea rcx, [r14 + r15]
1:  cmp rcx, rsi                # trim the line end
    jbe 2f
    cmp byte ptr [rcx - 1], ' '
    ja 2f
    dec rcx
    jmp 1b
2:  mov byte ptr [rcx], 0
    cmp rcx, rsi
    je .Lfr_bad
    PATH_ABSOLUTE rsi, 3f
    mov rdi, r12
    call path_join
    jmp 4f
3:  mov rdi, rsi
    sub rcx, rsi
    mov rsi, rcx
    call mem_dup
4:  mov rbx, rax
    mov rdi, rax
    call path_normalize
    mov rdi, r14
    call mem_free
.Lfr_found:
    mov rax, rbx
    mov rdx, r12
    mov rcx, r13
    EPILOGUE
.Lfr_bad:
    mov rdi, r14
    call mem_free
.Lfr_none:
    mov rdi, r12
    call mem_free
    xor eax, eax
    EPILOGUE

# watch_repo(): HEAD and the index (gitdir), the reflog, branches
watch_repo:
    PROLOGUE
    mov rdi, [rip + gitdir]
    lea rsi, [rip + .Llogs]
    call path_join
    mov [rip + logsdir], rax
    # linked worktrees keep branches in the common directory
    mov rdi, [rip + gitdir]
    lea rsi, [rip + .Lcommondir]
    call path_join
    mov rbx, rax
    mov rdi, rax
    call vfs_read_all
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    call mem_free
    mov r14, [rip + gitdir]
    xor r15d, r15d              # allocated common dir
    test r12, r12
    jz 3f
1:  test r13, r13
    jz 2f
    cmp byte ptr [r12 + r13 - 1], ' '
    ja 2f
    dec r13
    jmp 1b
2:  mov byte ptr [r12 + r13], 0
    test r13, r13
    jz 21f
    call read_worktree
    mov rdi, r14
    mov rsi, r12
    PATH_ABSOLUTE r12, 23f
    jmp 22f
23:
    lea rdi, [rip + .Lroot]
22: call path_join
    mov r15, rax
    mov r14, rax
    mov rdi, rax
    call path_normalize
21: mov rdi, r12
    call mem_free
3:  mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    call mem_dup
    mov [rip + commondir], rax
    mov rdi, r14
    lea rsi, [rip + .Lrefs_heads]
    call path_join
    mov [rip + refsdir], rax
    mov rdi, r15
    call mem_free
    mov rdi, [rip + gitdir]
    call watch_git
    mov rdi, [rip + logsdir]
    call watch_git
    mov rdi, [rip + refsdir]
    call watch_git
    EPILOGUE

# git_each_agent_worktree(cb, ctx): cb(ctx, root, linked) for this repository's checkouts. Git's
# registrations cover worktrees outside the project, including agent-managed checkouts, and those whose
# checkout has been removed (session history still names them). The agents panel watches the
# registrations itself (agents_watch_repo): this runs in the index worker, which watches nothing.
FN git_each_agent_worktree
    PROLOGUE 32
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov rsi, [rip + prim_root]
    test rsi, rsi
    jz 9f
    xor edx, edx
    cmp dword ptr [rip + prim_wt], 0
    setne dl
    mov rdi, [rsp + 8]
    call qword ptr [rsp]
    mov rbx, [rip + prim_common]
    test rbx, rbx
    jz 9f
    # In a normal repository the common .git directory sits inside the main checkout.
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call path_basename
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Ldotgit]
    call str_eq_cstr
    test eax, eax
    jz 2f
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call path_dirlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov r12, rax
    mov rdi, [rsp + 8]
    mov rsi, r12
    xor edx, edx
    call qword ptr [rsp]
    mov rdi, r12
    call mem_free
2:  mov rdi, rbx
    lea rsi, [rip + .Lworktrees]
    call path_join
    mov [rsp + 16], rax
    mov rdi, [rsp + 16]
    lea rsi, [rip + worktree_cb]
    mov rdx, rsp
    call vfs_dir_each
    mov rdi, [rsp + 16]
    call mem_free
9:  EPILOGUE

worktree_cb:
    PROLOGUE
    test edx, edx
    jz 9f
    mov rbx, rdi                # [callback, context, registrations directory]
    mov rdi, [rbx + 16]
    call path_join
    mov r12, rax                # registration directory
    mov rdi, rax
    lea rsi, [rip + .Lgitdir_file]
    call path_join
    mov r13, rax
    mov rdi, rax
    call vfs_read_all
    mov r14, rax
    mov r15, rdx
    mov rdi, r13
    call mem_free
    test r14, r14
    jz 8f
1:  test r15, r15
    jz 7f
    cmp byte ptr [r14 + r15 - 1], ' '
    ja 2f
    dec r15
    jmp 1b
2:  mov byte ptr [r14 + r15], 0
    mov rdi, r12
    mov rsi, r14
    PATH_ABSOLUTE r14, 3f
    jmp 4f
3:  lea rdi, [rip + .Lroot]
4:  call path_join
    mov r13, rax
    mov rdi, rax
    call path_normalize
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call path_dirlen
    mov byte ptr [r13 + rax], 0
    mov rdi, [rbx + 8]
    mov rsi, r13
    mov edx, 1
    call qword ptr [rbx]
    mov rdi, r13
    call mem_free
7:  mov rdi, r14
    call mem_free
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# read_worktree(): g_worktree from the work tree's folder name
read_worktree:
    PROLOGUE
    mov rdi, [rip + g_git_root]
    mov rsi, [rip + g_git_rootlen]
    call path_basename
    cmp rdx, 63
    jbe 1f
    mov edx, 63
1:  lea rdi, [rip + g_worktree]
    mov rsi, rax
    mov rcx, rdx
    rep movsb
    mov byte ptr [rdi], 0
    EPILOGUE

# git_read_branch(): g_branch from HEAD, the short commit id when detached
FN git_read_branch
    PROLOGUE
    mov rdi, [rip + gitdir]
    lea rsi, [rip + g_branch]
    call git_head_name
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# git_head_name(gitdir or 0, out 64 bytes): the branch HEAD names, the short commit id when detached,
#   "" when unknown
FN git_head_name
    PROLOGUE
    mov r14, rsi
    mov byte ptr [r14], 0
    test rdi, rdi
    jz 9f
    lea rsi, [rip + .Lhead]
    call path_join
    mov rbx, rax
    mov rdi, rax
    call vfs_read_all
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    call mem_free
    test r12, r12
    jz 9f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lrefs_heads_pfx]
    mov ecx, 11
    call str_find
    test rax, rax
    js 3f
    lea rsi, [r12 + rax + 11]
    lea rdx, [r12 + r13]
    mov ecx, 60
    jmp 4f
3:  # detached
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lref_pfx]
    mov ecx, 4
    call str_starts
    test eax, eax
    jnz 8f
    cmp r13, 7
    jb 8f
    mov rsi, r12
    lea rdx, [r12 + 7]
    mov ecx, 7
4:  mov rdi, r14
5:  cmp rsi, rdx
    jae 6f
    mov al, [rsi]
    cmp al, ' '
    jbe 6f
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz 5b
6:  mov byte ptr [rdi], 0
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# git_fs_event(dir, name): something changed in a watched git directory
FN git_fs_event
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rip + .Llock]
    mov ecx, 5
    call str_ends
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, [rip + gitdir]
    test rsi, rsi
    jz 9f
    call strcmp_eq
    test eax, eax
    jz 3f
    mov rdi, r12
    lea rsi, [rip + .Lindex]
    call strcmp_eq
    test eax, eax
    jz 1f
    call git_touch
    jmp 9f
1:  mov rdi, r12
    lea rsi, [rip + .Lhead]
    call strcmp_eq
    test eax, eax
    jnz 5f
    mov rdi, r12
    lea rsi, [rip + .Lpacked]
    call strcmp_eq
    test eax, eax
    jnz 5f
    # a fetch moved the remote branches: the history and what is ahead and behind
    mov rdi, r12
    lea rsi, [rip + .Lfetch_head]
    call strcmp_eq
    test eax, eax
    jnz 5f
    jmp 9f
3:  mov rdi, rbx
    mov rsi, [rip + logsdir]
    call strcmp_eq
    test eax, eax
    jnz 5f
    mov rdi, rbx
    mov rsi, [rip + refsdir]
    call strcmp_eq
    test eax, eax
    jz 9f
5:  call git_read_branch
    call git_touch_head
9:  EPILOGUE

# ---------------- background jobs ----------------

# git_run(args, cb, ctx, input ptr, input len) -> 1 if started
#   args: 0-terminated list after "git"; it runs in the work tree; ctx is 0 or mem_alloc'd (freed after cb)
FN git_run
    mov dword ptr [rip + run_flags], 0
    jmp 1f
# git_run_all(args, cb, ctx, input ptr, input len): git_run whose output has git's error messages too, and
#   that has no terminal to ask on (ssh fails instead of waiting for a password nobody sees)
FN git_run_all
    mov dword ptr [rip + run_flags], 1
1:  mov qword ptr [rip + run_cap], 0
    sub rsp, 8
    call run_git
    add rsp, 8
    test rax, rax
    setnz al
    movzx eax, al
    ret
# git_start_in(root, args, cb, ctx, cap) -> rax the job, or 0: git_start in another folder (another
#   workspace folder's repository, gitrepos.s), whatever repository this module follows; ctx owned
FN git_start_in
    mov dword ptr [rip + run_nolit], 0
git_start_in_body:
    PROLOGUE 16
    mov [rsp], rdi
    mov rbx, rsi
    mov r12, rdx
    mov r13, rcx
    mov r14, r8
    cmp dword ptr [rip + cfg_git], 0
    je 8f
    cmp qword ptr [rip + git_bin], 0
    jne 1f
    cmp dword ptr [rip + bin_tried], 0
    jne 8f
    mov dword ptr [rip + bin_tried], 1
    lea rdi, [rip + .Lgit]
    cmp dword ptr [rip + g_remote], 0
    jne 2f
    call proc_which
    jmp 3f
2:  call dup_cstr
3:  mov [rip + git_bin], rax
    lea rdi, [rip + env_extras]
    call env_make
    mov [rip + env], rax
    cmp qword ptr [rip + git_bin], 0
    je 8f
1:  mov rax, [rsp]
    mov [rip + run_cwd], rax
    mov dword ptr [rip + run_any], 1
    mov dword ptr [rip + run_flags], 0
    mov [rip + run_cap], r14
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    xor r8d, r8d
    call run_git
    mov qword ptr [rip + run_cwd], 0
    mov dword ptr [rip + run_any], 0
    EPILOGUE
8:  mov rdi, r13
    call mem_free
    xor eax, eax
    EPILOGUE

# FN git_start_in_plain(root, args, cb, ctx, cap) -> as git_start_in, without --literal-pathspecs (phase 4
#   task 8: `git check-ignore` refuses that magic and exits 128; it reads its paths as paths anyway)
FN git_start_in_plain
    mov dword ptr [rip + run_nolit], 1
    jmp git_start_in_body

# git_start(args, cb, ctx, input ptr, input len, cap) -> rax the job (for git_job_kill), or 0: git_run with
#   input of any length (copied; written as git reads it), and at most cap output bytes (0: no limit): a
#   program that writes more is ended, and cb gets status -1 and no output
FN git_start
    mov dword ptr [rip + run_flags], 0
    mov [rip + run_cap], r9
run_git:
    PROLOGUE 288                # argv; the errors flag, the input pipe, the input
    mov eax, [rip + run_flags]
    mov [rsp + 256], eax
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    cmp dword ptr [rip + run_any], 0
    jne 0f
    cmp dword ptr [rip + g_git_on], 0
    je 8f
0:  mov rax, [rip + git_bin]
    mov [rsp], rax
    lea rax, [rip + .Lno_locks]
    mov [rsp + 8], rax
    lea rax, [rip + .Lliteral]
    cmp dword ptr [rip + run_nolit], 0
    je 19f
    lea rax, [rip + .Lno_locks]  # (git_start_in_plain: the option said twice in its place)
19: mov dword ptr [rip + run_nolit], 0
    mov [rsp + 16], rax
    lea rax, [rip + .Ldash_c]
    mov [rsp + 24], rax
    lea rax, [rip + .Lquotepath]
    mov [rsp + 32], rax
    # no fsmonitor command from the repository's own config: opening a folder (a rhun:// link from a
    # web page) must not run a program that the folder names
    lea rax, [rip + .Ldash_c]
    mov [rsp + 40], rax
    lea rax, [rip + .Lno_fsmonitor]
    mov [rsp + 48], rax
    mov ecx, 7
    xor edx, edx
1:  mov rax, [rbx + rdx*8]
    mov [rsp + rcx*8], rax
    test rax, rax
    jz 2f
    inc rcx
    inc rdx
    cmp rcx, MAXARGS + 7
    jb 1b
    mov qword ptr [rsp + rcx*8], 0
2:  mov [rsp + 264], r14      # the input
    mov [rsp + 272], r15
    mov rdi, rsp
    mov rsi, [rip + env]
    mov rdx, [rip + run_cwd]
    test rdx, rdx
    jnz 21f
    mov rdx, [rip + g_git_root]
21: mov rcx, r14
    mov r8, r15
    mov r9d, [rsp + 256]
    cmp r15, PIPE_IN
    jbe 3f
    cmp dword ptr [rip + g_remote], 0
    jne 3f                      # a remote host takes the input whole (remote.s)
    or r9d, 4                   # longer than the pipe holds: fed as git reads it
3:  call vfs_run_piped_input    # on the host in a remote window
    cmp dword ptr [rip + g_remote], 0
    je 31f
    mov ecx, -1
31:
    test rax, rax
    jle 8f
    mov ebx, eax
    mov r14d, edx
    mov [rsp + 260], ecx        # the input pipe, or -1
    mov edi, JB_SIZE
    call mem_alloc
    mov r15, rax
    mov [r15 + JB_pid], ebx
    mov [r15 + JB_fd], r14d
    mov [r15 + JB_cb], r12
    mov [r15 + JB_ctx], r13
    mov eax, [rip + gen]
    cmp dword ptr [rip + run_any], 0
    je 22f
    mov eax, -1                 # git_start_in: answered whatever this module follows meanwhile
22: mov [r15 + JB_gen], eax
    mov rax, [rip + run_cap]
    mov [r15 + JB_cap], rax
    mov dword ptr [r15 + JB_in], -1
    lea rdi, [rip + jobs]
    mov esi, 8
    call vec_push
    mov [rax], r15
    mov edi, r14d
    mov esi, POLLIN
    lea rdx, [rip + on_job]
    mov rcx, r15
    call watch_add
    cmp qword ptr [rsp + 272], PIPE_IN
    jbe 4f
    mov eax, [rsp + 260]
    test eax, eax
    js 4f
    mov [r15 + JB_in], eax
    mov rdi, [rsp + 272]
    mov [r15 + JB_inlen], rdi
    call mem_alloc
    mov [r15 + JB_inbuf], rax
    mov rdi, rax
    mov rsi, [rsp + 264]
    mov rdx, [rsp + 272]
    call memcpy
    mov edi, [r15 + JB_in]
    mov esi, POLLOUT
    lea rdx, [rip + on_job_in]
    mov rcx, r15
    call watch_add
4:  mov rax, r15
    EPILOGUE
8:  mov rdi, r13
    call mem_free
    xor eax, eax
    EPILOGUE

# on_job_in(fd, revents, job): more of the input, as the program takes it; at its end (or when the
#   program stops reading) the pipe closes
on_job_in:
    PROLOGUE
    mov rbx, rdx
1:  mov rdx, [rbx + JB_inlen]
    sub rdx, [rbx + JB_inoff]
    jz 2f
    mov edi, [rbx + JB_in]
    mov rsi, [rbx + JB_inbuf]
    add rsi, [rbx + JB_inoff]
    SYS SYS_write
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 2f
    add [rbx + JB_inoff], rax
    jmp 1b
2:  call job_input_close
9:  EPILOGUE

# job_input_close(): rbx's input pipe and buffer go (keeps rbx)
job_input_close:
    push rbx
    mov edi, [rbx + JB_in]
    test edi, edi
    js 1f
    call watch_remove
    mov edi, [rbx + JB_in]
    SYS SYS_close
    mov dword ptr [rbx + JB_in], -1
1:  mov rdi, [rbx + JB_inbuf]
    call mem_free
    mov qword ptr [rbx + JB_inbuf], 0
    pop rbx
    ret

# git_job_kill(job): end the program; its callback still comes, with the status of a killed program
FN git_job_kill
    test rdi, rdi
    jz 9f
    push rbx
    mov edi, [rdi + JB_pid]
    mov esi, 9
    call proc_kill
    pop rbx
9:  ret

# on_job(fd, revents, job): collect the output; at its end hand it over
on_job:
    PROLOGUE
    mov rbx, rdx
1:  lea rdi, [rbx + JB_out]
    mov esi, 65536
    call sb_reserve
    mov rsi, rax
    mov edi, [rbx + JB_fd]
    mov edx, 65536
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 2f
    add [rbx + JB_out + SB_len], rax
    mov rax, [rbx + JB_cap]
    test rax, rax
    jz 1b
    cmp [rbx + JB_out + SB_len], rax
    jbe 1b
    # too much: the program ends, and what it wrote goes
    cmp dword ptr [rbx + JB_over], 0
    jne 11f
    mov dword ptr [rbx + JB_over], 1
    mov edi, [rbx + JB_pid]
    mov esi, 9
    call proc_kill
11: mov qword ptr [rbx + JB_out + SB_len], 0
    jmp 1b
2:  mov edi, [rbx + JB_fd]
    call watch_remove
    mov edi, [rbx + JB_fd]
    SYS SYS_close
    call job_input_close
    mov edi, [rbx + JB_pid]
    xor esi, esi
    call proc_wait
    mov r12d, eax
    cmp dword ptr [rbx + JB_over], 0
    je 21f
    mov r12d, -1
21: # out of the list
    xor ecx, ecx
3:  cmp rcx, [rip + jobs + VEC_len]
    jae 5f
    mov rax, [rip + jobs + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 4f
    inc rcx
    jmp 3b
4:  lea rdi, [rax + rcx*8]
    lea rsi, [rdi + 8]
    mov rdx, [rip + jobs + VEC_len]
    sub rdx, rcx
    dec rdx
    shl rdx, 3
    call memmove
    dec qword ptr [rip + jobs + VEC_len]
5:  mov rax, [rbx + JB_out + SB_ptr]
    add rax, [rbx + JB_out + SB_len]
    mov byte ptr [rax], 0
    mov eax, [rbx + JB_gen]
    cmp eax, -1
    je 51f
    cmp eax, [rip + gen]
    jne 6f
51: mov rdi, [rbx + JB_ctx]
    mov rsi, [rbx + JB_out + SB_ptr]
    mov rdx, [rbx + JB_out + SB_len]
    mov ecx, r12d
    call [rbx + JB_cb]
6:  mov rdi, [rbx + JB_ctx]
    call mem_free
    lea rdi, [rbx + JB_out]
    call sb_free
    mov rdi, rbx
    call mem_free
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# git_busy() -> 1 while programs run or a refresh waits
FN git_busy
    xor eax, eax
    cmp qword ptr [rip + jobs + VEC_len], 0
    jne 1f
    cmp qword ptr [rip + touch_at], 0
    jne 1f
    push rbx
    call gitrepos_busy
    pop rbx
    ret
1:  mov eax, 1
    ret

# ---------------- refresh ----------------

# git_touch(): files changed; the status is asked again shortly
FN git_touch
    push rbx
    call gitrepos_touch         # other workspace folders' repositories (gitrepos.s)
    pop rbx
    mov eax, 1
    jmp touch
# git_touch_head(): HEAD moved; the open files' bases too
FN git_touch_head
    mov eax, 3
touch:
    cmp dword ptr [rip + g_git_on], 0
    je 9f
    or [rip + touch_kind], eax
    cmp qword ptr [rip + touch_at], 0
    jne 9f
    push rbx
    call time_ms
    add rax, DEBOUNCE
    mov [rip + touch_at], rax
    pop rbx
9:  ret

# git_refresh(kind): git_touch (1) or git_touch_head (3) without waiting: after rhun's own changes
FN git_refresh
    cmp dword ptr [rip + g_git_on], 0
    je 9f
    or [rip + touch_kind], edi
    push rbx
    call time_ms
    mov [rip + touch_at], rax
    pop rbx
9:  ret

# git_timeout() -> ms until the next refresh or extension request deadline, or -1
FN git_timeout
    push rbx
    call gitdata_timeout
    mov ebx, eax
    mov rax, [rip + touch_at]
    test rax, rax
    jz 1f
    push rbx
    mov rbx, rax
    call time_ms
    sub rbx, rax
    mov eax, ebx
    pop rbx
    test eax, eax
    jns 2f
    xor eax, eax
2:  cmp ebx, -1
    je 3f
    cmp ebx, eax
    cmovb eax, ebx
3:  pop rbx
    ret
1:  mov eax, ebx
    pop rbx
    ret

# git_status_settled() -> 1 when no status runs or waits: the status in memory is the latest
FN git_status_settled
    xor eax, eax
    cmp dword ptr [rip + st_running], 0
    jne 1f
    cmp qword ptr [rip + touch_at], 0
    jne 1f
    mov eax, 1
1:  ret

FN git_tick
    PROLOGUE
    call gitdata_tick
    cmp qword ptr [rip + touch_at], 0
    je 9f
    call time_ms
    cmp rax, [rip + touch_at]
    jb 9f
    mov qword ptr [rip + touch_at], 0
    mov ebx, [rip + touch_kind]
    mov dword ptr [rip + touch_kind], 0
    cmp dword ptr [rip + g_git_on], 0
    je 9f
    test ebx, 2
    jz 1f
    call git_fetch_all
    call gitview_head_moved
    call gitdata_head_moved
1:  call status_refresh
9:  EPILOGUE

status_refresh:
    cmp dword ptr [rip + st_running], 0
    je 1f
    mov dword ptr [rip + st_again], 1
    ret
1:  push rbx
    lea rdi, [rip + args_status]
    lea rsi, [rip + on_status]
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call git_run
    mov [rip + st_running], eax
    pop rbx
    ret

# ---------------- status ----------------

# status_clear(): forget the status
status_clear:
    call table_clear
    mov dword ptr [rip + g_git_changes], 0
    mov dword ptr [rip + g_git_head], HD_BRANCH
    mov dword ptr [rip + g_git_ahead], 0
    mov dword ptr [rip + g_git_behind], 0
    mov byte ptr [rip + g_git_upstream], 0
    inc dword ptr [rip + g_git_ver]
    ret

# table_clear(): the status table empties
table_clear:
    lea rdi, [rip + stbuf]
    call sb_clear
    mov rdi, [rip + stab]
    test rdi, rdi
    jz 1f
    mov rcx, [rip + scap]
    shl rcx, 4
    xor eax, eax
    rep stosb
1:  mov qword ptr [rip + sused], 0
    mov dword ptr [rip + sudirs], 0
    ret

# git_table_swap(block): exchange the status table (its records, slots and counts) with a GT_SIZE
#   block: gitrepos.s keeps other repositories' tables so and swaps one in to load or ask it
FN git_table_swap
    lea rsi, [rip + stbuf]
    mov ecx, SB_SIZE/8
    call swap_q
    lea rsi, [rip + stab]
    mov ecx, 3
    call swap_q
    mov eax, [rip + sudirs]
    mov edx, [rdi]
    mov [rdi], eax
    mov [rip + sudirs], edx
    ret
# swap_q(a, b, n): exchange n qwords; leaves rdi after a's
swap_q:
1:  mov rax, [rdi]
    mov rdx, [rsi]
    mov [rdi], rdx
    mov [rsi], rax
    add rdi, 8
    add rsi, 8
    dec ecx
    jnz 1b
    ret

# git_table_load(ptr, len) -> eax changes: the swapped-in table holds these status --porcelain -z records
FN git_table_load
    push rbx
    push rdi
    push rsi
    call table_clear
    pop rsi
    pop rdi
    call status_fill
    pop rbx
    ret

# git_table_status(path ptr, len) -> git_status_rel in the swapped-in table, whether git is on or not
FN git_table_status
    push rbx
    push r12
    push r13
    xor eax, eax
    xor edx, edx
    cmp qword ptr [rip + sused], 0
    je 9f
    call status_rel
9:  pop r13
    pop r12
    pop rbx
    ret

# git_table_free(): the swapped-in table's memory goes
FN git_table_free
    push rbx
    lea rdi, [rip + stbuf]
    call sb_free
    mov rdi, [rip + stab]
    call mem_free
    mov qword ptr [rip + stab], 0
    mov qword ptr [rip + scap], 0
    mov qword ptr [rip + sused], 0
    mov dword ptr [rip + sudirs], 0
    pop rbx
    ret

# on_status(ctx, ptr, len, status): the branch ("## ..."), then "XY path\0" records of status --porcelain -z
on_status:
    PROLOGUE 16
    mov dword ptr [rip + st_running], 0
    test ecx, ecx
    jnz .Los_again
    mov rbx, rsi
    mov r12, rdx
    call status_clear
    cmp r12, 3
    jb 1f
    cmp word ptr [rbx], 0x2323      # "##"
    jne 1f
    mov rdi, rbx
    call parse_branch
    inc rax                         # and its NUL
    cmp rax, r12
    cmova rax, r12
    add rbx, rax
    sub r12, rax
1:  mov rdi, rbx
    mov rsi, r12
    call status_fill
    add [rip + g_git_changes], eax
    call files_hash             # (phase 4 task 7) git_files_gen
.Los_again:
    inc dword ptr [rip + g_git_ver]
    cmp dword ptr [rip + st_again], 0
    je 9f
    mov dword ptr [rip + st_again], 0
    call git_touch
9:  call gitdata_status_done      # extensions waiting for it, and "0 git changed"
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ---- phase 4 task 7: the set of new, added, deleted and renamed paths (rhun's file list, filelist.s) ----

# FN git_files_gen() -> rax a hash of the paths git's last status called untracked, added, deleted or renamed: it
#   moves when a file appears or goes for git, so the file list made from git's listing is made again
FN git_files_gen
    mov rax, [rip + files_gen]
    ret

# files_hash(): files_gen from the status table's records ("XY path\0", a rename's old name after it)
files_hash:
    PROLOGUE
    mov rbx, [rip + stbuf + SB_ptr]
    mov r12, [rip + stbuf + SB_len]
    add r12, rbx
    mov r13, 0xcbf29ce484222325
    mov r14, 0x100000001b3
    test rbx, rbx
    jz 8f
1:  lea rax, [rbx + 3]
    cmp rax, r12
    ja 8f
    movzx r15d, word ptr [rbx]  # X and Y
    lea rdi, [rbx + 3]
    call strlen
    lea rcx, [rbx + 3]
    lea rbx, [rcx + rax + 1]
    mov edx, r15d
    and edx, 0xff
    cmp edx, 'R'
    je 2f
    cmp edx, 'C'
    jne 3f
2:  push rcx                    # the old name follows
    push rax
    mov rdi, rbx
    call strlen
    lea rbx, [rbx + rax + 1]
    pop rax
    pop rcx
3:  mov edx, r15d               # '?', 'A', 'D' or 'R' in X or Y
    mov r8d, 2
4:  mov r9d, edx
    and r9d, 0xff
    cmp r9d, '?'
    je 5f
    cmp r9d, 'A'
    je 5f
    cmp r9d, 'D'
    je 5f
    cmp r9d, 'R'
    je 5f
    shr edx, 8
    dec r8d
    jnz 4b
    jmp 1b
5:  xor edx, edx                # the path's bytes, then its status
6:  cmp rdx, rax
    jae 7f
    movzx r9d, byte ptr [rcx + rdx]
    xor r13, r9
    imul r13, r14
    inc rdx
    jmp 6b
7:  xor r13, r15
    imul r13, r14
    jmp 1b
8:  mov [rip + files_gen], r13
    EPILOGUE

# status_fill(ptr, len) -> eax changes: the "XY path\0" records into the (cleared) table
status_fill:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov dword ptr [rsp + 8], 0
    lea rdi, [rip + stbuf]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    mov rbx, [rip + stbuf + SB_ptr]
    test rbx, rbx
    jz .Lsf_done
    add r12, rbx                # end
.Los_rec:
    lea rax, [rbx + 3]
    cmp rax, r12
    ja .Lsf_done
    movzx r13d, byte ptr [rbx]
    movzx r14d, byte ptr [rbx + 1]
    lea r15, [rbx + 3]
    mov rdi, r15
    call strlen
    mov [rsp], rax
    lea rbx, [r15 + rax + 1]
    cmp r13d, 'R'
    je 1f
    cmp r13d, 'C'
    jne 2f
1:  cmp rbx, r12                # the name it had before
    jae 2f
    mov rdi, rbx
    call strlen
    lea rbx, [rbx + rax + 1]
2:  mov edi, r13d
    mov esi, r14d
    call classify
    test eax, eax
    jz .Los_rec
    mov r13d, eax
    inc dword ptr [rsp + 8]
    mov rsi, [rsp]
    test rsi, rsi
    jz .Los_rec
    xor ecx, ecx
    cmp byte ptr [r15 + rsi - 1], '/'
    jne 3f
    dec rsi
    mov ecx, 2
3:  mov [rsp], rsi
    mov rdi, r15
    mov edx, r13d
    call st_add
    # the folders above it
    mov r14, [rsp]
4:  dec r14
    jle .Los_rec
    cmp byte ptr [r15 + r14], '/'
    jne 4b
    mov rdi, r15
    mov rsi, r14
    mov edx, r13d
    mov ecx, 1
    call st_add
    jmp 4b
.Lsf_done:
    mov eax, [rsp + 8]
    EPILOGUE

# parse_branch(record) -> rax its length: "## main...origin/main [ahead 1, behind 2]", "## main",
#   "## HEAD (no branch)", "## No commits yet on main" into g_git_head, _upstream, _ahead, _behind
parse_branch:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
    lea r13, [rbx + 3]
    lea r14, [rbx + rax]
    cmp r13, r14
    ja 9f
    mov r15, r14
    sub r15, r13                # length after "## "
    mov rdi, r13
    mov rsi, r15
    lea rdx, [rip + .Lb_unborn]
    mov ecx, 18
    call str_starts
    test eax, eax
    jnz 1f
    mov rdi, r13
    mov rsi, r15
    lea rdx, [rip + .Lb_initial]
    mov ecx, 18
    call str_starts
    test eax, eax
    jz 2f
1:  mov dword ptr [rip + g_git_head], HD_UNBORN
    jmp 9f
2:  mov rdi, r13
    mov rsi, r15
    lea rdx, [rip + .Lb_detached]
    mov ecx, 16
    call str_starts
    test eax, eax
    jz 3f
    mov dword ptr [rip + g_git_head], HD_DETACHED
    jmp 9f
3:  # the upstream follows "..." up to a space
    mov rdi, r13
    mov rsi, r15
    lea rdx, [rip + .Lb_dots]
    mov ecx, 3
    call str_find
    test rax, rax
    js 9f
    lea rsi, [r13 + rax + 3]
    lea rdi, [rip + g_git_upstream]
    mov ecx, 255
4:  cmp rsi, r14
    jae 5f
    mov al, [rsi]
    cmp al, ' '
    je 5f
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz 4b
5:  mov byte ptr [rdi], 0
    mov r13, rsi
    mov r15, r14
    sub r15, r13
    mov rdi, r13
    mov rsi, r15
    lea rdx, [rip + .Lb_ahead]
    lea rcx, [rip + g_git_ahead]
    call count_after
    mov rdi, r13
    mov rsi, r15
    lea rdx, [rip + .Lb_behind]
    lea rcx, [rip + g_git_behind]
    call count_after
9:  mov rax, r12
    EPILOGUE

# count_after(ptr, len, word, dest): the number after word ("ahead ") in ptr/len into dest
count_after:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, rdx
    call strlen
    mov r15, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r15
    call str_find
    test rax, rax
    js 9f
    lea rdi, [rbx + rax]
    add rdi, r15
    lea rsi, [rbx + r12]
    sub rsi, rdi
    call parse_u64
    mov [r14], eax
9:  EPILOGUE

# classify(X, Y) -> one letter for the two status columns, 0 to skip
classify:
    mov eax, 'U'
    cmp edi, '?'
    je 9f
    xor eax, eax
    cmp edi, '!'
    je 9f
    mov eax, 'C'
    cmp edi, 'U'
    je 9f
    cmp esi, 'U'
    je 9f
    cmp edi, esi
    jne 1f
    cmp edi, 'A'
    je 9f
    cmp edi, 'D'
    je 9f
1:  mov eax, 'D'
    cmp edi, 'D'
    je 9f
    cmp esi, 'D'
    je 9f
    mov eax, 'A'
    cmp edi, 'A'
    je 9f
    cmp edi, 'C'
    je 9f
    mov eax, 'R'
    cmp edi, 'R'
    je 9f
    mov eax, 'M'
9:  ret

# rank(code) -> how strongly a folder shows it
rank:
    mov eax, 3
    cmp edi, 'C'
    je 1f
    mov eax, 1
    cmp edi, 'A'
    je 1f
    cmp edi, 'U'
    je 1f
    mov eax, 2
1:  ret

# st_find(ptr, len) -> slot holding that path, or the empty slot for it
st_find:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call hash_line
    mov r13, [rip + scap]
    dec r13
    and rax, r13
1:  mov rcx, rax
    shl rcx, 4
    add rcx, [rip + stab]
    cmp byte ptr [rcx + GE_code], 0
    je 8f
    cmp [rcx + GE_len], r12d
    jne 2f
    push rax
    push rcx
    mov rdi, rbx
    mov rsi, [rcx + GE_ptr]
    mov rdx, r12
    call memeq
    pop rcx
    mov edx, eax
    pop rax
    test edx, edx
    jnz 8f
2:  inc rax
    and rax, r13
    jmp 1b
8:  mov rax, rcx
    pop r13
    pop r12
    pop rbx
    ret

# st_add(ptr, len, code, dir): a file, or a folder (merged with what is already there)
st_add:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    # a folder shows deletions and renames as changes
    cmp r14d, 1
    jne 1f
    cmp r13d, 'D'
    je 4f
    cmp r13d, 'R'
    jne 1f
4:  mov r13d, 'M'
1:  mov rax, [rip + sused]
    lea rax, [rax*2 + 2]
    cmp rax, [rip + scap]
    jb 2f
    call st_grow
2:  mov rdi, rbx
    mov rsi, r12
    call st_find
    mov r15, rax
    cmp byte ptr [r15 + GE_code], 0
    jne 3f
    mov [r15 + GE_ptr], rbx
    mov [r15 + GE_len], r12d
    mov [r15 + GE_code], r13b
    mov [r15 + GE_dir], r14b
    inc qword ptr [rip + sused]
    cmp r14d, 2
    jne 9f
    inc dword ptr [rip + sudirs]
    jmp 9f
3:  # a folder seen before: keep the stronger code
    movzx edi, byte ptr [r15 + GE_code]
    call rank
    mov ebx, eax
    mov edi, r13d
    call rank
    cmp eax, ebx
    jbe 9f
    mov [r15 + GE_code], r13b
9:  EPILOGUE

# st_grow(): twice the slots
st_grow:
    PROLOGUE
    mov r12, [rip + stab]
    mov r13, [rip + scap]
    lea rax, [r13 + r13]
    mov ecx, 64
    cmp rax, rcx
    cmovb rax, rcx
    mov [rip + scap], rax
    shl rax, 4
    mov rdi, rax
    call mem_alloc
    mov [rip + stab], rax
    xor ebx, ebx
1:  cmp rbx, r13
    jae 3f
    mov r14, rbx
    shl r14, 4
    add r14, r12
    cmp byte ptr [r14 + GE_code], 0
    je 2f
    mov rdi, [r14 + GE_ptr]
    mov esi, [r14 + GE_len]
    call st_find
    mov rcx, [r14]
    mov [rax], rcx
    mov rcx, [r14 + 8]
    mov [rax + 8], rcx
2:  inc rbx
    jmp 1b
3:  mov rdi, r12
    call mem_free
    EPILOGUE

# git_rel(path cstr) -> rax path inside the work tree, rdx its length; rax 0 when outside
FN git_rel
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    xor eax, eax
    cmp qword ptr [rip + g_git_root], 0
    je 9f
    call strlen
    mov r12, rax
    mov rdx, [rip + g_git_rootlen]
    lea rcx, [rdx + 1]
    xor eax, eax
    cmp r12, rcx
    jbe 9f
    cmp byte ptr [rbx + rdx], '/'
    jne 9f
    mov rdi, rbx
    mov rsi, [rip + g_git_root]
    call memeq
    test eax, eax
    jz 9f
    mov rcx, [rip + g_git_rootlen]
    lea rax, [rbx + rcx + 1]
    mov rdx, r12
    sub rdx, rcx
    dec rdx
9:  add rsp, 8
    pop r12
    pop rbx
    ret

# git_status_of(path cstr) -> eax code letter or 0, edx 1 or 2 for folders
#   (the other workspace folders' repositories: gitrepos.s)
FN git_status_of
    push rbx
    push r12
    push r13
    mov rbx, rdi
    cmp dword ptr [rip + g_git_on], 0
    je 8f
    call git_rel
    test rax, rax
    jz 8f
    mov r12, rax
    mov r13, rdx
    # a repository inside this one (another workspace folder's) has its own files
    mov rdi, rbx
    mov rsi, [rip + g_git_rootlen]
    call gitrepos_owns
    test eax, eax
    jnz 8f
    mov rdi, r12
    mov rsi, r13
    xor eax, eax
    xor edx, edx
    cmp qword ptr [rip + sused], 0
    je 9f
    call status_rel
    jmp 9f
8:  mov rdi, rbx
    call gitrepos_status_of
9:  pop r13
    pop r12
    pop rbx
    ret

# git_status_rel(ptr, len) -> git_status_of for a path in the work tree
FN git_status_rel
    push rbx
    push r12
    push r13
    xor eax, eax
    xor edx, edx
    cmp dword ptr [rip + g_git_on], 0
    je 9f
    cmp qword ptr [rip + sused], 0
    je 9f
    call status_rel
9:  pop r13
    pop r12
    pop rbx
    ret

# status_rel(ptr, len) -> eax code, edx folder kind (the table is not empty)
status_rel:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call st_find
    cmp byte ptr [rax + GE_code], 0
    jne 7f
    # inside an untracked folder
    cmp dword ptr [rip + sudirs], 0
    je 8f
    mov r13, r12
1:  dec r13
    jle 8f
    cmp byte ptr [rbx + r13], '/'
    jne 1b
    mov rdi, rbx
    mov rsi, r13
    call st_find
    cmp byte ptr [rax + GE_dir], 2
    jne 1b
    mov eax, 'U'
    mov edx, 2
    jmp 9f
7:  movzx edx, byte ptr [rax + GE_dir]
    movzx eax, byte ptr [rax + GE_code]
    jmp 9f
8:  xor eax, eax
    xor edx, edx
9:  pop r13
    pop r12
    pop rbx
    ret

# git_code_color(code) -> argb
FN git_code_color
    COLOR eax, T_GIT_ADD
    cmp edi, 'A'
    je 1f
    cmp edi, 'U'
    je 1f
    COLOR eax, T_GIT_DEL
    cmp edi, 'D'
    je 1f
    COLOR eax, T_ERROR
    cmp edi, 'C'
    je 1f
    COLOR eax, T_GIT_MOD
1:  ret

# git_path_color(path cstr) -> argb for its name, 0 when unchanged
FN git_path_color
    push rbx
    call git_status_of
    test eax, eax
    jz 1f
    mov edi, eax
    call git_code_color
1:  pop rbx
    ret

# ---------------- files at HEAD ----------------

# docs_reset(): open documents forget their bases
docs_reset:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 9f
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 2f
    mov rdi, [rax + TAB_doc]
    cmp dword ptr [rdi + DOC_gsrc], 0
    jne 2f                      # an extension's quick-diff base stays (git_drop_base_ext)
    call drop_base
    mov dword ptr [rdi + DOC_gstate], GS_NONE
2:  inc rbx
    jmp 1b
9:  EPILOGUE

# drop_base(doc): no base; keeps rdi
drop_base:
    push rdi
    mov rdi, [rdi + DOC_ghash]
    call mem_free
    pop rdi
    mov qword ptr [rdi + DOC_ghash], 0
    mov qword ptr [rdi + DOC_gnl], 0
    mov dword ptr [rdi + DOC_gstate], GS_NOBASE
    ret

# git_doc_opened(doc): ask for the file at HEAD (and a quick-diff provider for its base, scmext.s)
FN git_doc_opened
    push rdi
    call scmext_qd_want
    pop rdi
# git_doc_head(doc): ask for the file at HEAD only
git_doc_head:
    PROLOGUE
    cmp dword ptr [rip + g_git_on], 0
    je 9f
    # a refresh of every file is on its way
    test dword ptr [rip + touch_kind], 2
    jnz 9f
    mov rbx, rdi
    lea rdi, [rip + docs]
    mov qword ptr [rdi + VEC_len], 0
    mov esi, 8
    call vec_push
    mov [rax], rbx
    call request_bases
9:  EPILOGUE

# git_doc_saved(doc)
FN git_doc_saved
    push rbx
    push rdi
    call git_doc_opened
    pop rdi
    call git_touch
    pop rbx
    ret

# git_fetch_all(): every open file again
git_fetch_all:
    PROLOGUE
    lea rdi, [rip + docs]
    mov qword ptr [rdi + VEC_len], 0
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 2f
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 11f
    mov r12, [rax + TAB_doc]
    lea rdi, [rip + docs]
    mov esi, 8
    call vec_push
    mov [rax], r12
11: inc rbx
    jmp 1b
2:  call request_bases
    EPILOGUE

# request_bases(): cat-file --batch for the documents in `docs`
#   ctx: count, then (doc, request number) pairs
request_bases:
    PROLOGUE 16
    mov rdi, [rip + docs + VEC_len]
    shl rdi, 4
    add rdi, 16
    call mem_alloc
    mov r15, rax
    lea rdi, [rip + tmp]
    call sb_clear
    xor ebx, ebx
.Lrb_doc:
    cmp rbx, [rip + docs + VEC_len]
    jae .Lrb_run
    mov rax, [rip + docs + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    mov rdi, [r12 + DOC_path]
    test rdi, rdi
    jz .Lrb_doc
    test dword ptr [r12 + DOC_flags], DF_READONLY
    jnz .Lrb_doc
    call git_rel
    test rax, rax
    jz .Lrb_outside
    mov r13, rax
    mov r14, rdx
    # names with a line break cannot be asked for this way
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    test rax, rax
    jns .Lrb_outside
    mov rax, [rip + tmp + SB_len]
    add rax, r14
    cmp rax, BATCH_IN
    ja .Lrb_doc
    inc qword ptr [rip + seq]
    mov rax, [rip + seq]
    mov [r12 + DOC_gseq], eax
    cmp dword ptr [r12 + DOC_gstate], GS_BASE
    je 1f
    mov dword ptr [r12 + DOC_gstate], GS_ASKED
1:  mov rcx, [r15]
    shl rcx, 4
    mov [r15 + rcx + 16], r12
    mov [r15 + rcx + 24], rax
    inc qword ptr [r15]
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lhead_colon]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    lea rdi, [rip + tmp]
    mov esi, 10
    call sb_push_byte
    jmp .Lrb_doc
.Lrb_outside:
    cmp dword ptr [r12 + DOC_gsrc], 0
    jne .Lrb_doc                # an extension's quick-diff base stays
    mov rdi, r12
    call drop_base
    jmp .Lrb_doc
.Lrb_run:
    cmp qword ptr [r15], 0
    je 8f
    lea rdi, [rip + args_batch]
    lea rsi, [rip + on_bases]
    mov rdx, r15
    mov rcx, [rip + tmp + SB_ptr]
    mov r8, [rip + tmp + SB_len]
    call git_run
    EPILOGUE
8:  mov rdi, r15
    call mem_free
    EPILOGUE

# on_bases(ctx, ptr, len, status): "<id> blob <size>\n<text>\n" or "<name> missing\n" per file
on_bases:
    PROLOGUE 32
    mov r15, rdi
    mov r12, rsi
    lea r13, [rsi + rdx]
    xor ebx, ebx
.Lob_next:
    cmp rbx, [r15]
    jae .Lob_done
    mov rax, rbx
    shl rax, 4
    mov rcx, [r15 + rax + 16]
    mov [rsp], rcx              # doc
    mov rcx, [r15 + rax + 24]
    mov [rsp + 8], rcx          # request number
    inc rbx
    # header line
    mov r14, r12
1:  cmp r14, r13
    jae .Lob_done
    cmp byte ptr [r14], 10
    je 2f
    inc r14
    jmp 1b
2:  mov qword ptr [rsp + 16], -1    # text size, -1 none
    # object id: 40 or 64 hex digits, then " blob <size>"
    mov rcx, r12
3:  cmp rcx, r14
    jae 6f
    movzx eax, byte ptr [rcx]
    cmp al, ' '
    je 4f
    call is_hex
    jz 6f
    inc rcx
    jmp 3b
4:  mov rax, rcx
    sub rax, r12
    cmp rax, 40
    je 5f
    cmp rax, 64
    jne 6f
5:  lea rdi, [rcx + 1]
    mov rsi, r14
    sub rsi, rdi
    cmp rsi, 5
    jbe 6f
    # the size is the last field; the text follows whatever the type
    lea rcx, [r14 - 1]
51: cmp byte ptr [rcx], ' '
    je 52f
    dec rcx
    jmp 51b
52: push rdi
    push rcx
    lea rdi, [rcx + 1]
    mov rsi, r14
    sub rsi, rdi
    call parse_u64
    pop rcx
    pop rdi
    mov r8, rax
    lea rax, [r14 + 1]
    add rax, r8
    cmp rax, r13
    jae .Lob_done
    mov qword ptr [rsp + 24], 0
    sub rcx, rdi
    cmp rcx, 4
    jne 53f
    cmp dword ptr [rdi], 0x626f6c62 # "blob"
    jne 53f
    mov [rsp + 16], r8
53: lea r12, [r14 + 1]
    mov [rsp + 24], r12         # text
    lea r12, [r12 + r8 + 1]
    jmp 7f
6:  lea r12, [r14 + 1]
7:  mov rdi, [rsp]
    test rdi, rdi
    jz .Lob_next
    mov eax, [rsp + 8]
    cmp [rdi + DOC_gseq], eax
    jne .Lob_next
    cmp dword ptr [rdi + DOC_gsrc], 0
    jne .Lob_next               # an extension's quick-diff base is the one shown
    mov rdx, [rsp + 16]
    test rdx, rdx
    js 8f
    mov rsi, [rsp + 24]
    call set_base
    jmp .Lob_next
8:  call drop_base
    jmp .Lob_next
.Lob_done:
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# is_hex(al) -> ZF clear when a hex digit
is_hex:
    push rax
    or al, 0x20
    cmp al, '0'
    jb 1f
    cmp al, '9'
    jbe 2f
    cmp al, 'a'
    jb 1f
    cmp al, 'f'
    ja 1f
2:  pop rax
    or eax, 1                   # nonzero: ZF clear
    ret
1:  pop rax
    xor edx, edx
    test edx, edx               # ZF set
    ret

# set_base(doc, ptr, len): hashes of the file at HEAD (CRs of line ends dropped)
set_base:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rdx + 1]
    call mem_alloc
    mov r14, rax
    xor ecx, ecx
    xor edx, edx
1:  cmp rcx, r13
    jae 3f
    mov al, [r12 + rcx]
    inc rcx
    cmp al, 13
    jne 2f
    cmp rcx, r13
    jae 2f
    cmp byte ptr [r12 + rcx], 10
    je 1b
2:  mov [r14 + rdx], al
    inc rdx
    jmp 1b
3:  mov rdi, r14
    mov rsi, rdx
    lea rdx, [rsp]
    call hash_text
    mov r15, rax
    mov rdi, r14
    call mem_free
    # the same as before: keep the marks
    cmp dword ptr [rbx + DOC_gstate], GS_BASE
    jne 4f
    mov rdx, [rsp]
    cmp rdx, [rbx + DOC_gnl]
    jne 4f
    mov rdi, r15
    mov rsi, [rbx + DOC_ghash]
    shl rdx, 3
    call memeq
    test eax, eax
    jz 4f
    mov rdi, r15
    call mem_free
    EPILOGUE
4:  mov rdi, [rbx + DOC_ghash]
    call mem_free
    mov [rbx + DOC_ghash], r15
    mov rax, [rsp]
    mov [rbx + DOC_gnl], rax
    mov dword ptr [rbx + DOC_gstate], GS_BASE
    mov qword ptr [rbx + DOC_gver], -1
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# git_doc_marks(doc) -> GM_* per line, or 0
FN git_doc_marks
    xor eax, eax
    cmp dword ptr [rdi + DOC_gsrc], 0
    jne 2f                      # an extension's base: marks without git
    cmp dword ptr [rip + g_git_on], 0
    je 9f
2:  cmp dword ptr [rdi + DOC_gstate], GS_BASE
    jne 9f
    mov rax, [rdi + DOC_version]
    cmp rax, [rdi + DOC_gver]
    je 1f
    push rdi
    call diff_marks
    pop rdi
1:  mov rax, [rdi + DOC_gmarks]
9:  ret

# git_set_base_ext(doc, ptr, len): an extension's quick-diff base (scmext.s); the gutter marks follow it
FN git_set_base_ext
    PROLOGUE
    mov rbx, rdi
    mov dword ptr [rbx + DOC_gsrc], 1
    call set_base
    EPILOGUE

# git_drop_base_ext(doc): an extension's base goes; git's comes back when git runs there
FN git_drop_base_ext
    cmp dword ptr [rdi + DOC_gsrc], 0
    je 9f
    mov dword ptr [rdi + DOC_gsrc], 0
    push rdi
    push rdi
    mov rdi, [rdi + DOC_qbase]
    call mem_free
    pop rdi
    mov qword ptr [rdi + DOC_qbase], 0
    mov qword ptr [rdi + DOC_qblen], 0
    call drop_base
    mov rdi, [rsp]
    call git_doc_head
    pop rdi
9:  ret

# git_doc_free(doc): its git data; answers still on their way forget it
#   (jobs that answer for documents have a ctx of: count, then (doc, request number) pairs)
FN git_doc_free
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + DOC_qbase]
    call mem_free
    mov qword ptr [rbx + DOC_qbase], 0
    mov rdi, [rbx + DOC_ghash]
    call mem_free
    mov rdi, [rbx + DOC_gmarks]
    call mem_free
    mov rdi, [rbx + DOC_diff]
    call diffview_free
    xor r12d, r12d
1:  cmp r12, [rip + jobs + VEC_len]
    jae 9f
    mov rax, [rip + jobs + VEC_ptr]
    mov rax, [rax + r12*8]
    inc r12
    lea rcx, [rip + on_bases]
    cmp [rax + JB_cb], rcx
    je 11f
    lea rcx, [rip + diffview_answer]
    cmp [rax + JB_cb], rcx
    jne 1b
11: mov rax, [rax + JB_ctx]
    xor ecx, ecx
2:  cmp rcx, [rax]
    jae 1b
    mov rdx, rcx
    shl rdx, 4
    cmp [rax + rdx + 16], rbx
    jne 3f
    mov qword ptr [rax + rdx + 16], 0
3:  inc rcx
    jmp 2b
9:  EPILOGUE

# git_scm_list(vec): the status as GF records by group: conflicts, staged, then not staged (a file can
#   be in both of these); paths point into the status, valid until it changes
FN git_scm_list
    PROLOGUE 16
    mov rbx, rdi
    mov qword ptr [rbx + VEC_len], 0
    mov dword ptr [rsp], GG_MERGE
.Lsl_group:
    mov r12, [rip + stbuf + SB_ptr]
    test r12, r12
    jz 9f
    mov r13, [rip + stbuf + SB_len]
    add r13, r12
1:  lea rax, [r12 + 3]
    cmp rax, r13
    ja 8f
    movzx edi, byte ptr [r12]
    movzx esi, byte ptr [r12 + 1]
    movzx r15d, dil
    mov edx, [rsp]
    call group_code
    mov r14d, eax
    lea r12, [r12 + 3]
    test eax, eax
    jz 2f
    mov rdi, rbx
    mov esi, GF_SIZE
    call vec_push
    mov [rax + GF_path], r12
    mov [rax + GF_code], r14d
    mov dword ptr [rax + GF_add], -2
    mov ecx, [rsp]
    mov [rax + GF_group], ecx
2:  mov rdi, r12
    call strlen
    lea r12, [r12 + rax + 1]
    cmp r15d, 'R'
    je 3f
    cmp r15d, 'C'
    jne 1b
3:  mov rdi, r12
    call strlen
    lea r12, [r12 + rax + 1]
    jmp 1b
8:  inc dword ptr [rsp]
    cmp dword ptr [rsp], GG_CHANGES
    jbe .Lsl_group
9:  EPILOGUE

# group_code(X, Y, group) -> the letter of a status record in that group, 0 when not in it
group_code:
    xor eax, eax
    cmp edi, '!'
    je 9f
    # conflicts: either side unmerged, or both added or both deleted
    mov ecx, 1
    cmp edi, 'U'
    je 1f
    cmp esi, 'U'
    je 1f
    cmp edi, esi
    jne 2f
    cmp edi, 'A'
    je 1f
    cmp edi, 'D'
    je 1f
2:  xor ecx, ecx
1:  cmp edx, GG_MERGE
    jne 3f
    test ecx, ecx
    jz 9f
    mov eax, 'C'
    ret
3:  test ecx, ecx
    jnz 9f
    cmp edx, GG_STAGED
    jne 5f
    # the index: X
    cmp edi, ' '
    je 9f
    cmp edi, '?'
    je 9f
    mov eax, edi
    jmp 6f
5:  # the work tree: Y, untracked files
    mov eax, 'U'
    cmp edi, '?'
    je 9f
    xor eax, eax
    cmp esi, ' '
    je 9f
    mov eax, esi
6:  cmp eax, 'T'                # type changes
    jne 7f
    mov eax, 'M'
7:  cmp eax, 'C'                # copies are new files
    jne 9f
    mov eax, 'A'
9:  ret

# git_merge_msg() -> rax the message of the merge in progress (mem_free it), rdx its length; rax 0 if none
FN git_merge_msg
    PROLOGUE
    xor eax, eax
    xor edx, edx
    mov rdi, [rip + gitdir]
    test rdi, rdi
    jz 9f
    lea rsi, [rip + .Lmerge_msg]
    call path_join
    mov rbx, rax
    mov rdi, rax
    call vfs_read_all
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    call mem_free
    mov rax, r12
    mov rdx, r13
9:  EPILOGUE

# ---------------- scripts ----------------

# git_dump(sb): "git on|off branch=B", the status, the marks of the current file
FN git_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_git]
    call sb_push_cstr
    lea rsi, [rip + .Ld_on]
    cmp dword ptr [rip + g_git_on], 0
    jne 1f
    lea rsi, [rip + .Ld_off]
    cmp dword ptr [rip + g_git_paused], 0
    je 1f
    lea rsi, [rip + .Ld_paused]
1:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_branch]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + g_branch]
    call sb_push_cstr
    cmp byte ptr [rip + g_worktree], 0
    je 2f
    mov rdi, rbx
    lea rsi, [rip + .Ld_worktree]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + g_worktree]
    call sb_push_cstr
2:  cmp byte ptr [rip + g_git_upstream], 0
    je 1f
    mov rdi, rbx
    lea rsi, [rip + .Ld_upstream]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + g_git_upstream]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_ahead]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + g_git_ahead]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_behind]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + g_git_behind]
    call sb_push_u64
1:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    # status records in git's order
    mov r12, [rip + stbuf + SB_ptr]
    test r12, r12
    jz 5f
    mov r13, [rip + stbuf + SB_len]
    add r13, r12
2:  lea rax, [r12 + 3]
    cmp rax, r13
    ja 5f
    movzx edi, byte ptr [r12]
    movzx esi, byte ptr [r12 + 1]
    movzx r15d, dil
    call classify
    mov r14d, eax
    lea r12, [r12 + 3]
    test eax, eax
    jz 3f
    mov rdi, rbx
    mov esi, r14d
    call sb_push_byte
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
3:  mov rdi, r12
    call strlen
    lea r12, [r12 + rax + 1]
    cmp r15d, 'R'
    je 4f
    cmp r15d, 'C'
    jne 2b
4:  mov rdi, r12
    call strlen
    lea r12, [r12 + rax + 1]
    jmp 2b
5:  # marks: + added, ~ changed, - deleted above, _ deleted below, . same
    mov r12, [rip + g_doc]
    test r12, r12
    jz 9f
    mov rdi, r12
    call git_doc_marks
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, rbx
    lea rsi, [rip + .Ld_marks]
    call sb_push_cstr
    xor r14d, r14d
6:  cmp r14, [r12 + DOC_nlines]
    jae 8f
    movzx eax, byte ptr [r13 + r14]
    mov esi, '+'
    test eax, GM_ADD
    jnz 7f
    mov esi, '~'
    test eax, GM_MOD
    jnz 7f
    mov esi, '-'
    test eax, GM_DELUP
    jnz 7f
    mov esi, '_'
    test eax, GM_DELDOWN
    jnz 7f
    mov esi, '.'
7:  mov rdi, rbx
    call sb_push_byte
    inc r14
    jmp 6b
8:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

.section .rodata
.Lgit: .asciz "git"
.Ldotgit: .asciz ".git"
.Lgitdir_pfx: .ascii "gitdir: "
.Llogs: .asciz "logs"
.Lcommondir: .asciz "commondir"
.Lworktrees: .asciz "worktrees"
.Lgitdir_file: .asciz "gitdir"
.Lrefs_heads: .asciz "refs/heads"
.Lrefs_heads_pfx: .ascii "refs/heads/"
.Lref_pfx: .ascii "ref:"
.Lroot: .asciz "/"
.Lhead: .asciz "HEAD"
.Lindex: .asciz "index"
.Lpacked: .asciz "packed-refs"
.Llock: .ascii ".lock"
.Lnl: .ascii "\n"
.Lhead_colon: .asciz "HEAD:"
.Lfetch_head: .asciz "FETCH_HEAD"
.Lmerge_msg: .asciz "MERGE_MSG"
.Lbranch_opt: .asciz "--branch"
.Lb_unborn: .ascii "No commits yet on "
.Lb_initial: .ascii "Initial commit on "
.Lb_detached: .ascii "HEAD (no branch)"
.Lb_dots: .ascii "..."
.Lb_ahead: .asciz "ahead "
.Lb_behind: .asciz "behind "
.Ld_upstream: .asciz " upstream="
.Ld_ahead: .asciz " ahead="
.Ld_behind: .asciz " behind="
.Lno_locks: .asciz "--no-optional-locks"
.Lliteral: .asciz "--literal-pathspecs"
.Ldash_c: .asciz "-c"
.Lquotepath: .asciz "core.quotepath=off"
.Lno_fsmonitor: .asciz "core.fsmonitor=false"
.Lstatus: .asciz "status"
.Lporcelain: .asciz "--porcelain"
.Ldash_z: .asciz "-z"
.Lcat_file: .asciz "cat-file"
.Lbatch: .asciz "--batch"
.Lenv_locks: .asciz "GIT_OPTIONAL_LOCKS=0"
.Lenv_prompt: .asciz "GIT_TERMINAL_PROMPT=0"
.Lenv_editor: .asciz "GIT_EDITOR=:"         # a merge or rebase never waits on an editor
.Ld_git: .asciz "git "
.Ld_on: .asciz "on"
.Ld_off: .asciz "off"
.Ld_paused: .asciz "paused"
g_git_paused_text: .asciz "Git is paused for this folder until you trust it"
.Ld_branch: .asciz " branch="
.Ld_worktree: .asciz " worktree="
.Ld_marks: .asciz "marks "
.p2align 3
env_extras: .quad .Lenv_locks, .Lenv_prompt, .Lenv_editor, 0
args_status: .quad .Lstatus, .Lporcelain, .Ldash_z, .Lbranch_opt, 0
args_batch: .quad .Lcat_file, .Lbatch, 0
