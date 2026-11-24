# The project's files and folders for the mention menu (generic). One list, made by filesearch.s's lister
# (git ls-files where git may run, so .gitignore holds; else a walk that leaves out the exclude setting; with
# [agents] respect_gitignore false the walk always, still without .git and what the exclude setting hides), at
# most FL_MAX paths. Made when a menu first wants it, never at startup; made again only when a menu next wants
# it and something changed since: a create, delete or move the watcher saw (watch_tree_gen), git's set of new,
# added, deleted and renamed paths (git_files_gen), rhun's own file operations (filelist_touch); and once when a
# query matched nothing and the list is older than FL_MISS_MS. While it is made again the old list answers.
#
# A query (the text after "@") is matched in slices of a few milliseconds, never in one frame: rhun's fuzzy
# (palette.s) over the paths under the typed folder prefix, the FL_TOP best kept (the extension's twr,
# EXT@3312300: the entries whose name or name without extension is the query's last part first, those with
# "test" in the path after them, then the others, each by score); with an empty last part, that folder's
# entries in order. A query that extends the last one looks only at what the last one matched.
#
#   filelist_want()                     a menu wants the list: made when there is none or it is stale
#   filelist_miss()                     a query matched nothing: listed again once when the list is old
#   filelist_touch()                    rhun made, renamed or deleted a file (explorer_refresh)
#   filelist_reset()                    quit, or the project changes: the list and its run go
#   filelist_state() -> eax FL_NONE 0, FL_LISTING 1, FL_READY 2;  filelist_gen() -> rax;  filelist_cut() -> eax
#   flq_set(ptr, len)                   the query; flq_step(us) -> eax 1 done;  flq_done() -> eax
#   flq_count() -> rax;  flq_at(i, out) -> eax 1: out path ptr 8, len 8, kind 4 (0 a file, 1 a folder)
#   flq_abs(i, sb) -> eax 1             row i's absolute path (a folder's with its "/")
#   flq_gen() -> rax                    moves when the rows changed
#   filelist_tick(), filelist_timeout() -> eax 0 while a menu's query or the list's run has work, else -1
#   filelist_dump(sb)                   print-filelist;  filelist_test(n, more) the speed tests' made-up list
.include "rhun.inc"

.equ FL_MAX, 200000
.equ FL_TOP, 100
.equ FL_MISS_MS, 5000
.equ FL_NONE, 0
.equ FL_LISTING, 1
.equ FL_READY, 2
.equ FLE_DIR, 1                 # an entry's flags (its high byte: the workspace folder's index)
.equ FLE_PREFIXED, 2            #   its path starts with the folder's name (two or more folders)
.equ FSF_DIRS_, 8               # filesearch.s's flags
.equ FSF_WALK_, 128
.equ Q_MAX, 512
.equ CHECK_EVERY, 64            # candidates between looks at the clock

.bss
.p2align 3
cur_paths: .zero SB_SIZE        # the list: path bytes, and an entry (off 4, len 2, flags 2) a path
cur_ents: .zero VEC_SIZE
cur_dirs: .zero VEC_SIZE        # dwords: the indices of its folders
new_paths: .zero SB_SIZE        # the list being made again (the old one answers meanwhile)
new_ents: .zero VEC_SIZE
new_dirs: .zero VEC_SIZE
run: .quad 0                    # the lister's run (its serial), 0 none
runs: .quad 0
gen: .quad 0
swaps: .quad 0
made_at: .quad 0                # time_ms the list was made
wgen: .quad 0                   # the change signals when the list's run started
ggen: .quad 0
tgen: .quad 0
touches: .quad 0
steps: .quad 0
step_max: .quad 0               # the longest step, microseconds (print-filelist maxstep=)
step_t0: .quad 0
cands_seen: .quad 0             # the candidates the current query looked at
state: .long 0
into_new: .long 0
cut: .long 0
new_cut: .long 0
missed: .long 0
# the query
q_buf: .zero Q_MAX + 8          # lower case, without "./" or a leading "/"
q_len: .quad 0
q_root: .quad 0                 # the folder it lists under: the length of its path and "/", 0 none
q_rootent: .quad 0              #   and its entry (an index: the list's bytes move as it grows)
q_dirs: .quad 0                 #   the folders the list had when it was looked for
q_restoff: .quad 0              # the part after the root (q_buf + q_restoff), and the last part's offset
q_lastoff: .quad 0
q_pos: .quad 0                  # the next entry to look at
q_cpos: .quad 0                 # the next of the last query's matches to look at (narrowing)
q_upto: .quad 0                 # the entries the last query had seen (narrowing: the ones after are new)
q_swaps: .quad 0
q_gen: .quad 0
q_list: .long 0                 # 1: an empty last part (a folder's entries in order)
q_narrow: .long 0
q_on: .long 0                   # a query was set
q_changed: .long 0
cands: .zero VEC_SIZE           # dwords: the last query's matches (narrowing)
matches: .zero VEC_SIZE         # dwords: this query's
top: .zero 16 * (FL_TOP + 1)    # the best: key 8, index 4, pad 4 (key lower is better)
top_n: .quad 0
tsb: .zero SB_SIZE

.text

# ---- the list ----

# FN filelist_state() -> eax
FN filelist_state
    mov eax, [rip + state]
    ret

# FN filelist_gen() -> rax
FN filelist_gen
    mov rax, [rip + gen]
    ret

# FN filelist_cut() -> eax 1 when the lister stopped at FL_MAX
FN filelist_cut
    mov eax, [rip + cut]
    ret

# FN filelist_touch()
FN filelist_touch
    inc qword ptr [rip + touches]
    ret

# ent(i) -> rax the entry's address in the list
ent:
    lea rax, [rdi*8]
    add rax, [rip + cur_ents + VEC_ptr]
    ret

# ent_path(i) -> rax ptr, rdx len
ent_path:
    mov rax, [rip + cur_ents + VEC_ptr]
    mov ecx, [rax + rdi*8]
    movzx edx, word ptr [rax + rdi*8 + 4]
    mov rax, [rip + cur_paths + SB_ptr]
    add rax, rcx
    ret

# free_list(paths, ents, dirs)
free_list:
    PROLOGUE
    mov rbx, rsi
    mov r12, rdx
    call sb_free
    mov rdi, rbx
    call vec_free
    mov rdi, r12
    call vec_free
    EPILOGUE

# signals() -> rax, rdx, rcx: watch_tree_gen, git_files_gen, touches
signals:
    PROLOGUE
    call watch_tree_gen
    mov rbx, rax
    call git_files_gen
    mov rdx, rax
    mov rax, rbx
    mov rcx, [rip + touches]
    EPILOGUE

# start(into_new): the lister runs (all the project's folders)
start:
    PROLOGUE
    mov r12d, edi
    cmp qword ptr [rip + run], 0
    jne 9f
    call signals
    mov [rip + wgen], rax
    mov [rip + ggen], rdx
    mov [rip + tgen], rcx
    mov [rip + into_new], r12d
    mov dword ptr [rip + new_cut], 0
    lea rdi, [rip + new_paths]
    call sb_clear
    mov qword ptr [rip + new_ents + VEC_len], 0
    mov qword ptr [rip + new_dirs + VEC_len], 0
    mov edx, FSF_DIRS_
    cmp dword ptr [rip + cfg_agents_respect_gitignore], 0
    jne 1f
    or edx, FSF_WALK_
1:  xor edi, edi
    mov esi, FL_MAX
    lea rcx, [rip + found]
    xor r8d, r8d
    call filesearch_native
    test rax, rax
    jz 9f                       # every slot taken: the next want tries again
    mov [rip + run], rax
    inc qword ptr [rip + runs]
    test r12d, r12d
    jnz 9f
    mov dword ptr [rip + state], FL_LISTING
9:  EPILOGUE

# FN filelist_want(): see the top
FN filelist_want
    PROLOGUE
    cmp qword ptr [rip + g_project], 0
    jne 1f
    cmp dword ptr [rip + state], FL_READY   # no project: an empty list, ready
    je 9f
    call filelist_reset
    mov dword ptr [rip + state], FL_READY
    inc qword ptr [rip + gen]
    EPILOGUE
1:  cmp dword ptr [rip + state], FL_NONE
    jne 2f
    xor edi, edi
    call start
    EPILOGUE
2:  cmp dword ptr [rip + state], FL_READY
    jne 9f
    cmp qword ptr [rip + run], 0
    jne 9f
    call signals
    cmp rax, [rip + wgen]
    jne 3f
    cmp rdx, [rip + ggen]
    jne 3f
    cmp rcx, [rip + tgen]
    je 9f
3:  mov edi, 1
    call start
9:  EPILOGUE

# FN filelist_miss(): see the top
FN filelist_miss
    PROLOGUE
    cmp qword ptr [rip + g_project], 0
    je 9f
    cmp dword ptr [rip + state], FL_READY
    jne 9f
    cmp qword ptr [rip + run], 0
    jne 9f
    call time_ms
    sub rax, [rip + made_at]
    cmp rax, FL_MISS_MS
    jb 9f
    mov edi, 1
    call start
9:  EPILOGUE

# FN filelist_reset(): see the top
FN filelist_reset
    PROLOGUE
    mov rdi, [rip + run]
    test rdi, rdi
    jz 1f
    call filesearch_native_cancel
    mov qword ptr [rip + run], 0
1:  lea rdi, [rip + cur_paths]
    lea rsi, [rip + cur_ents]
    lea rdx, [rip + cur_dirs]
    call free_list
    lea rdi, [rip + new_paths]
    lea rsi, [rip + new_ents]
    lea rdx, [rip + new_dirs]
    call free_list
    lea rdi, [rip + cands]
    call vec_free
    lea rdi, [rip + matches]
    call vec_free
    mov dword ptr [rip + state], FL_NONE
    mov dword ptr [rip + cut], 0
    mov dword ptr [rip + q_on], 0
    mov qword ptr [rip + top_n], 0
    inc qword ptr [rip + swaps]
    inc qword ptr [rip + gen]
    inc qword ptr [rip + q_gen]
    EPILOGUE

# add(paths, ents, dirs, path, len, flags): an entry
add:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp], r9d
    cmp r15, 0xffff
    ja 9f
    lea rdi, [r12]
    mov esi, 8
    call vec_push
    mov rcx, [rbx + SB_len]
    mov [rax], ecx
    mov [rax + 4], r15w
    mov ecx, [rsp]
    mov [rax + 6], cx
    test ecx, FLE_DIR
    jz 1f
    mov rdi, r13
    mov esi, 4
    call vec_push
    mov rcx, [r12 + VEC_len]
    dec ecx
    mov [rax], ecx
1:  mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call sb_push
9:  EPILOGUE

# found(ctx, path or 0, len, is_dir, folder id): the lister's callback (filesearch_native)
found:
    PROLOGUE 16
    test rsi, rsi
    jz .Lfd_end
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    mov rdi, r8                 # the folder's index, and its name first when there are several
    call wfold_index
    xor r15d, r15d
    test rax, rax
    js 1f
    mov r15, rax
1:  lea rdi, [rip + tsb]
    call sb_clear
    mov ebx, r14d               # FLE_DIR
    call wfold_count
    cmp eax, 2
    jb 2f
    mov rdi, r15
    call wfold_name
    lea rdi, [rip + tsb]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + tsb]
    mov esi, '/'
    call sb_push_byte
    or ebx, FLE_PREFIXED
2:  lea rdi, [rip + tsb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    shl r15d, 8
    or ebx, r15d
    lea rdi, [rip + cur_paths]
    lea rsi, [rip + cur_ents]
    lea rdx, [rip + cur_dirs]
    cmp dword ptr [rip + into_new], 0
    je 3f
    lea rdi, [rip + new_paths]
    lea rsi, [rip + new_ents]
    lea rdx, [rip + new_dirs]
3:  mov rcx, [rip + tsb + SB_ptr]
    mov r8, [rip + tsb + SB_len]
    mov r9d, ebx
    call add
    cmp dword ptr [rip + into_new], 0
    jne 9f
    inc qword ptr [rip + gen]   # rows found so far show (the first list)
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE
.Lfd_end:
    mov qword ptr [rip + run], 0
    mov ecx, edx                # 1: cut at FL_MAX
    cmp dword ptr [rip + into_new], 0
    je 4f
    mov [rsp], ecx              # the new list takes the old one's place
    lea rdi, [rip + cur_paths]
    lea rsi, [rip + cur_ents]
    lea rdx, [rip + cur_dirs]
    call free_list
    lea rsi, [rip + new_paths]
    lea rdi, [rip + cur_paths]
    mov ecx, SB_SIZE / 8
    call swap_q
    lea rsi, [rip + new_ents]
    lea rdi, [rip + cur_ents]
    mov ecx, VEC_SIZE / 8
    call swap_q
    lea rsi, [rip + new_dirs]
    lea rdi, [rip + cur_dirs]
    mov ecx, VEC_SIZE / 8
    call swap_q
    mov ecx, [rsp]
    inc qword ptr [rip + swaps]
    mov dword ptr [rip + into_new], 0
4:  mov [rip + cut], ecx
    mov dword ptr [rip + state], FL_READY
    call time_ms
    mov [rip + made_at], rax
    inc qword ptr [rip + gen]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# swap_q(a, b, n): n qwords exchanged
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

# ---- the query ----

# FN flq_gen() -> rax
FN flq_gen
    mov rax, [rip + q_gen]
    ret

# FN flq_count() -> rax the rows
FN flq_count
    mov rax, [rip + top_n]
    ret

# FN flq_at(i, out) -> eax 1: out path ptr 8, len 8, kind 4 (0 a file, 1 a folder); borrowed until the list
#   changes (the frame)
FN flq_at
    xor eax, eax
    cmp rdi, [rip + top_n]
    jae 9f
    shl rdi, 4
    lea rax, [rip + top]
    mov edi, [rax + rdi + 8]
    push rsi
    call ent_path
    pop rsi
    mov [rsi], rax
    mov [rsi + 8], rdx
    mov rax, [rip + cur_ents + VEC_ptr]
    movzx eax, word ptr [rax + rdi*8 + 6]
    and eax, FLE_DIR
    mov [rsi + 16], eax
    mov eax, 1
9:  ret

# FN flq_abs(i, sb) -> eax 1: row i's absolute path, a folder's with its "/"
FN flq_abs
    PROLOGUE
    mov r12, rsi
    xor eax, eax
    cmp rdi, [rip + top_n]
    jae 9f
    shl rdi, 4
    lea rax, [rip + top]
    mov ebx, [rax + rdi + 8]
    mov rax, [rip + cur_ents + VEC_ptr]
    movzx r13d, word ptr [rax + rbx*8 + 6]
    mov edi, r13d
    shr edi, 8
    call wfold_path
    mov rdi, r12
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r12
    mov esi, '/'
    call sb_push_byte
    mov rdi, rbx
    call ent_path
    mov r14, rax
    mov r15, rdx
    test r13d, FLE_PREFIXED     # the folder's name off
    jz 2f
1:  test r15, r15
    jz 2f
    movzx ecx, byte ptr [r14]
    inc r14
    dec r15
    cmp ecx, '/'
    jne 1b
2:  mov rdi, r12
    mov rsi, r14
    mov rdx, r15
    call sb_push
    test r13d, FLE_DIR
    jz 3f
    mov rdi, r12
    mov esi, '/'
    call sb_push_byte
3:  mov eax, 1
9:  EPILOGUE

# FN flq_done() -> eax 1 when the query has looked at every entry there is
FN flq_done
    xor eax, eax
    cmp dword ptr [rip + q_on], 0
    je 1f
    cmp dword ptr [rip + q_narrow], 0
    je 2f
    mov rcx, [rip + q_cpos]
    cmp rcx, [rip + cands + VEC_len]
    jb 9f
2:  mov rcx, [rip + q_pos]
    cmp rcx, [rip + cur_ents + VEC_len]
    jb 9f
1:  mov eax, 1
9:  ret

# FN flq_set(ptr, len): the query (the token after "@", its quotes too): see the top. The same query again
#   changes nothing
FN flq_set
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    cmp r13, 1                  # @"…: the quotes off
    jb 1f
    cmp byte ptr [r12], '"'
    jne 1f
    inc r12
    dec r13
    test r13, r13
    jz 1f
    cmp byte ptr [r12 + r13 - 1], '"'
    jne 1f
    dec r13
1:  cmp r13, 2                  # "./" or "/" at its start off
    jb 2f
    cmp word ptr [r12], 0x2f2e
    jne 2f
    add r12, 2
    sub r13, 2
2:  test r13, r13
    jz 3f
    cmp byte ptr [r12], '/'
    jne 3f
    inc r12
    dec r13
3:  cmp r13, Q_MAX
    jbe 4f
    mov r13, Q_MAX
4:  lea rdi, [rip + tsb]        # lower case
    call sb_clear
    xor ebx, ebx
5:  cmp rbx, r13
    jae 6f
    movzx esi, byte ptr [r12 + rbx]
    lea eax, [rsi - 'A']
    cmp eax, 25
    ja 51f
    or esi, 0x20
51: lea rdi, [rip + tsb]
    call sb_push_byte
    inc rbx
    jmp 5b
6:  mov rax, [rip + swaps]      # the same as now: nothing
    cmp dword ptr [rip + q_on], 0
    je 7f
    cmp rax, [rip + q_swaps]
    jne 7f
    cmp r13, [rip + q_len]
    jne 7f
    test r13, r13
    jz 9f
    mov rdi, [rip + tsb + SB_ptr]
    lea rsi, [rip + q_buf]
    mov rdx, r13
    call memeq
    test eax, eax
    jnz 9f
7:  # narrowing: the same list, the last query looked at everything and the new one extends it in the
    #   same folder (its matches are what the new one can match)
    xor r14d, r14d
    cmp dword ptr [rip + q_on], 0
    je 71f
    mov rax, [rip + swaps]
    cmp rax, [rip + q_swaps]
    jne 71f
    cmp dword ptr [rip + q_list], 0
    jne 71f
    call flq_done
    test eax, eax
    jz 71f
    mov rax, [rip + q_len]
    cmp rax, r13
    jae 71f
    mov rdi, [rip + tsb + SB_ptr]
    lea rsi, [rip + q_buf]
    mov rdx, rax
    call memeq
    test eax, eax
    jz 71f
    mov rdi, [rip + tsb + SB_ptr]   # no "/" in what was added: the same folder prefix
    mov rcx, [rip + q_len]
711: cmp rcx, r13
    jae 712f
    cmp byte ptr [rdi + rcx], '/'
    je 71f
    inc rcx
    jmp 711b
712: mov r14d, 1
71: mov rdi, [rip + tsb + SB_ptr]
    lea rsi, [rip + q_buf]      # (q_buf: the query from here on)
    mov rcx, r13
    test rcx, rcx
    jz 72f
    xchg rdi, rsi
    rep movsb
72: lea rax, [rip + q_buf]
    mov byte ptr [rax + r13], 0
    mov [rip + q_len], r13
    mov rax, [rip + swaps]
    mov [rip + q_swaps], rax
    mov dword ptr [rip + q_on], 1
    mov dword ptr [rip + missed], 0
    mov qword ptr [rip + top_n], 0
    mov qword ptr [rip + cands_seen], 0
    inc qword ptr [rip + q_gen]
    mov dword ptr [rip + g_dirty], 1
    test r14d, r14d
    jz 73f
    lea rsi, [rip + matches]    # the last query's matches become the candidates
    lea rdi, [rip + cands]
    mov ecx, VEC_SIZE / 8
    call swap_q
    mov rax, [rip + q_pos]
    mov [rip + q_upto], rax
    mov qword ptr [rip + q_cpos], 0
    mov dword ptr [rip + q_narrow], 1
    jmp 74f
73: mov dword ptr [rip + q_narrow], 0
    mov qword ptr [rip + q_pos], 0
74: mov qword ptr [rip + matches + VEC_len], 0
    call find_root
9:  EPILOGUE

# find_root(): q_root, q_restoff, q_lastoff, q_list from q_buf: the part up to the last "/" names a folder of
#   the list (any case): the entries under it are looked at, the rest is matched against their paths after it;
#   else the whole query against every path
find_root:
    PROLOGUE
    mov rax, [rip + cur_dirs + VEC_len]
    mov [rip + q_dirs], rax
    mov r12, [rip + q_len]
    mov r13, r12                # the last "/" + 1
1:  test r13, r13
    jz 2f
    lea rax, [rip + q_buf]
    cmp byte ptr [rax + r13 - 1], '/'
    je 2f
    dec r13
    jmp 1b
2:  mov [rip + q_lastoff], r13
    mov qword ptr [rip + q_root], 0
    mov qword ptr [rip + q_rootent], 0
    mov qword ptr [rip + q_restoff], 0
    cmp r13, 1
    jbe 8f
    xor r14d, r14d              # a folder whose path is the prefix without its "/"
3:  cmp r14, [rip + cur_dirs + VEC_len]
    jae 8f
    mov rax, [rip + cur_dirs + VEC_ptr]
    mov edi, [rax + r14*4]
    inc r14
    mov ebx, edi
    call ent_path
    lea rcx, [r13 - 1]
    cmp rdx, rcx
    jne 3b
    mov r15, rax
    xor ecx, ecx
4:  cmp rcx, rdx
    jae 5f
    movzx eax, byte ptr [r15 + rcx]
    lea r8d, [rax - 'A']
    cmp r8d, 25
    ja 41f
    or eax, 0x20
41: lea r8, [rip + q_buf]
    cmp al, [r8 + rcx]
    jne 3b
    inc rcx
    jmp 4b
5:  mov [rip + q_rootent], rbx
    mov [rip + q_root], r13     # its path and the "/"
    mov [rip + q_restoff], r13
8:  xor eax, eax
    cmp [rip + q_restoff], r12
    jne 9f
    mov eax, 1                  # nothing after the folder: its entries in order
9:  mov [rip + q_list], eax
    EPILOGUE

# rank(i, score) -> rax the entry's key (lower is better): its group (0 its name is the query's last part, 1
#   that and "test" in its path, 2 the others), then the score, then its place in the list
rank:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    call ent_path
    mov rbx, rax                # its last part (a folder's path has no "/" at the end here)
    mov r14, rdx
    mov rcx, rdx
1:  test rcx, rcx
    jz 2f
    cmp byte ptr [rbx + rcx - 1], '/'
    je 2f
    dec rcx
    jmp 1b
2:  lea r15, [rbx + rcx]        # the base and its length
    mov rdx, r14
    sub rdx, rcx
    mov rax, [rip + q_len]
    sub rax, [rip + q_lastoff]
    lea rsi, [rip + q_buf]
    add rsi, [rip + q_lastoff]
    mov rdi, r15
    mov rcx, rax
    push rdx
    push rax
    call ieq                    # the base
    pop rcx
    pop rdx
    test eax, eax
    jnz 4f
    mov r8, rdx                 # the name without its extension (the last ".", not the first character)
3:  cmp r8, 1
    jbe 5f
    dec r8
    cmp byte ptr [r15 + r8], '.'
    jne 3b
    mov rdi, r15
    mov rdx, r8
    lea rsi, [rip + q_buf]
    add rsi, [rip + q_lastoff]
    call ieq
    test eax, eax
    jz 5f
4:  xor eax, eax                # "test" in its path
    mov rdi, rbx
    mov rsi, r14
    lea rdx, [rip + .Ltest]
    mov ecx, 4
    call str_find
    xor ecx, ecx
    test rax, rax
    js 41f
    mov ecx, 1
41: mov rax, rcx
    jmp 6f
5:  mov eax, 2
6:  shl rax, 56
    mov ecx, 0xffffff
    cmp r13d, ecx
    cmovg r13d, ecx
    sub ecx, r13d
    shl rcx, 32
    or rax, rcx
    or rax, r12
    EPILOGUE

# ieq(a, b, alen in rdx, blen in rcx) -> eax 1 when the texts are equal, a in any case, b lower case
ieq:
    xor eax, eax
    cmp rdx, rcx
    jne 9f
    xor r8d, r8d
1:  cmp r8, rdx
    jae 8f
    movzx r9d, byte ptr [rdi + r8]
    lea r10d, [r9 - 'A']
    cmp r10d, 25
    ja 2f
    or r9d, 0x20
2:  cmp r9b, [rsi + r8]
    jne 9f
    inc r8
    jmp 1b
8:  mov eax, 1
9:  ret

# better(key, i, slot) -> eax 1 when the candidate goes before the kept one in that slot: by key, or in a
#   folder's listing by path
better:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    shl rdx, 4
    lea rax, [rip + top]
    mov r14, [rax + rdx]
    mov r15d, [rax + rdx + 8]
    cmp dword ptr [rip + q_list], 0
    jne 1f
    xor eax, eax
    cmp r12, r14
    setb al
    EPILOGUE
1:  mov edi, r13d               # by the paths' bytes
    call ent_path
    mov rbx, rax
    mov r12, rdx
    mov edi, r15d
    call ent_path
    mov r8, rax
    xor ecx, ecx
2:  cmp rcx, r12
    jae 4f
    cmp rcx, rdx
    jae 5f
    movzx eax, byte ptr [rbx + rcx]
    movzx r9d, byte ptr [r8 + rcx]
    cmp eax, r9d
    jb 4f
    ja 5f
    inc rcx
    jmp 2b
4:  cmp rcx, rdx                # a prefix goes first; equal paths: the first found stays
    jae 5f
    mov eax, 1
    EPILOGUE
5:  xor eax, eax
    EPILOGUE

# keep(key, i) -> eax 1 when it joined the best
keep:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    mov rbx, [rip + top_n]
    cmp rbx, FL_TOP
    jb 1f
    mov rdi, r12                # full: only one better than the last
    mov esi, r13d
    lea rdx, [rbx - 1]
    call better
    test eax, eax
    jz 8f
    dec rbx
1:  test rbx, rbx               # its place: after every kept one it is not better than
    jz 3f
    mov rdi, r12
    mov esi, r13d
    lea rdx, [rbx - 1]
    call better
    test eax, eax
    jz 3f
    lea rax, [rip + top]
    mov rcx, rbx
    shl rcx, 4
    mov rdx, [rax + rcx - 16]
    mov [rax + rcx], rdx
    mov rdx, [rax + rcx - 8]
    mov [rax + rcx + 8], rdx
    dec rbx
    jmp 1b
3:  lea rax, [rip + top]
    mov rcx, rbx
    shl rcx, 4
    mov [rax + rcx], r12
    mov [rax + rcx + 8], r13d
    mov rax, [rip + top_n]
    cmp rax, FL_TOP
    jae 4f
    inc qword ptr [rip + top_n]
4:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# look(i) -> eax 1 when the rows changed: entry i against the query
look:
    PROLOGUE
    mov r12d, edi
    inc qword ptr [rip + cands_seen]
    call ent_path
    mov rbx, rax
    mov r13, rdx
    mov rcx, [rip + q_root]     # under the folder
    test rcx, rcx
    jz 1f
    cmp r13, rcx
    jbe 8f
    mov rdi, [rip + q_rootent]
    call ent_path
    mov rsi, rax
    mov rdi, rbx
    mov rdx, [rip + q_root]
    dec rdx
    call memeq
    test eax, eax
    jz 8f
    mov rcx, [rip + q_root]
    cmp byte ptr [rbx + rcx - 1], '/'
    jne 8f
1:  cmp dword ptr [rip + q_list], 0
    je 3f
    mov rcx, [rip + q_root]     # a folder's own entries: nothing after another "/"
2:  cmp rcx, r13
    jae 21f
    cmp byte ptr [rbx + rcx], '/'
    je 8f
    inc rcx
    jmp 2b
21: xor edi, edi
    mov esi, r12d
    call keep
    EPILOGUE
3:  mov rcx, [rip + q_root]     # the rest of the query, fuzzily, over the path after the folder
    lea rdi, [rbx + rcx]
    mov rsi, r13
    sub rsi, rcx
    lea rdx, [rip + q_buf]
    add rdx, [rip + q_restoff]
    mov rcx, [rip + q_len]
    sub rcx, [rip + q_restoff]
    call fuzzy
    test eax, eax
    js 8f
    mov r14d, eax
    lea rdi, [rip + matches]
    mov esi, 4
    call vec_push
    mov [rax], r12d
    mov edi, r12d
    mov esi, r14d
    call rank
    mov rdi, rax
    mov esi, r12d
    call keep
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN flq_step(us) -> eax 1 when the query has looked at every entry: the next candidates until the time is
#   spent (a candidate more at most)
FN flq_step
    PROLOGUE 16
    cmp dword ptr [rip + q_on], 0
    je .Lst_done
    mov r12, rdi
    call flq_done
    test eax, eax
    jnz .Lst_done
    cmp qword ptr [rip + q_root], 0     # a folder prefix not found yet while the list is being made: it
    jne 0f                              #   may be there now (the query starts again under it)
    cmp qword ptr [rip + q_lastoff], 1
    jbe 0f
    mov rax, [rip + cur_dirs + VEC_len]
    cmp rax, [rip + q_dirs]
    je 0f
    call find_root
    cmp qword ptr [rip + q_root], 0
    je 0f
    mov qword ptr [rip + top_n], 0
    mov qword ptr [rip + q_pos], 0
    mov dword ptr [rip + q_narrow], 0
    mov qword ptr [rip + matches + VEC_len], 0
    inc qword ptr [rip + q_gen]
0:  inc qword ptr [rip + steps]
    call time_us
    mov [rip + step_t0], rax
    add r12, rax                # the deadline
    xor r13d, r13d              # rows changed
    xor r14d, r14d              # looked at since the clock
1:  cmp dword ptr [rip + q_narrow], 0
    je 2f
    mov rax, [rip + q_cpos]
    cmp rax, [rip + cands + VEC_len]
    jae 2f
    inc qword ptr [rip + q_cpos]
    mov rcx, [rip + cands + VEC_ptr]
    mov edi, [rcx + rax*4]
    jmp 3f
2:  mov rax, [rip + q_pos]
    cmp rax, [rip + cur_ents + VEC_len]
    jae 5f
    inc qword ptr [rip + q_pos]
    mov edi, eax
    cmp dword ptr [rip + q_narrow], 0
    je 3f
    cmp rax, [rip + q_upto]     # narrowing: only the entries the last query had not seen
    jb 1b
3:  call look
    or r13d, eax
    inc r14d
    cmp r14d, CHECK_EVERY
    jb 1b
    xor r14d, r14d
    call time_us
    cmp rax, r12
    jb 1b
    test r13d, r13d
    jz 4f
    inc qword ptr [rip + q_gen]
    mov dword ptr [rip + g_dirty], 1
4:  call step_end
    xor eax, eax
    EPILOGUE
5:  call step_end
    test r13d, r13d
    jz 6f
    inc qword ptr [rip + q_gen]
6:  mov dword ptr [rip + g_dirty], 1
    cmp qword ptr [rip + top_n], 0  # nothing matched: the list may be old (a file made where nothing
    jne .Lst_done                   #   watches): once
    cmp dword ptr [rip + missed], 0
    jne .Lst_done
    mov dword ptr [rip + missed], 1
    call filelist_miss
.Lst_done:
    mov eax, 1
    EPILOGUE

# step_end(): step_max follows the step that ends
step_end:
    sub rsp, 8
    call time_us
    sub rax, [rip + step_t0]
    cmp rax, [rip + step_max]
    jbe 1f
    mov [rip + step_max], rax
1:  add rsp, 8
    ret

# ---- the loop ----

# FN filelist_tick(): the lister's run gets its slice (filesearch.s's runs are otherwise ticked only while
#   extensions run); a menu's query goes on where it is drawn (agentpop.s's build)
FN filelist_tick
    PROLOGUE
    cmp qword ptr [rip + run], 0
    je 1f
    call filesearch_tick
1:  EPILOGUE                    # (the query goes on in the menu's draw: filelist_timeout brings the frames)

# FN filelist_timeout() -> eax 0 while the lister runs or a shown menu's query has work left, else -1
FN filelist_timeout
    PROLOGUE
    xor eax, eax
    cmp qword ptr [rip + run], 0
    jne 9f
    call agentpop_kind
    cmp eax, APP_MENTION
    jne 8f
    call flq_done
    test eax, eax
    jnz 8f
    xor eax, eax
    EPILOGUE
8:  mov eax, -1
9:  EPILOGUE

# ---- tests ----

# FN filelist_test(n, more): n made-up paths join the list ("dNNN/fNNNNNN.c", every hundredth the folder
#   "dNNN"), no disk: the speed tests'; more 1: the list stays "being made" (rows while it is made)
FN filelist_test
    PROLOGUE 16
    mov r12, rdi
    mov [rsp], esi
    mov rdi, [rip + run]
    test rdi, rdi
    jz 1f
    call filesearch_native_cancel
    mov qword ptr [rip + run], 0
    mov dword ptr [rip + into_new], 0
1:  xor r13d, r13d
2:  cmp r13, r12
    jae 7f
    mov rax, [rip + cur_ents + VEC_len]
    cmp rax, FL_MAX
    jb 3f
    mov dword ptr [rip + cut], 1
    jmp 7f
3:  mov r14, rax                # the entry's number
    lea rdi, [rip + tsb]
    call sb_clear
    lea rdi, [rip + tsb]
    mov esi, 'd'
    call sb_push_byte
    mov rax, r14
    xor edx, edx
    mov ecx, 100
    div rcx
    mov r15, rdx                # 0: the folder itself
    mov rdi, rax
    mov esi, 3
    call pad_num
    xor ebx, ebx
    test r15, r15
    jnz 4f
    mov ebx, FLE_DIR
    jmp 5f
4:  lea rdi, [rip + tsb]
    lea rsi, [rip + .Lslash_f]
    call sb_push_cstr
    mov rdi, r14
    mov esi, 6
    call pad_num
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Ldot_c]
    call sb_push_cstr
5:  lea rdi, [rip + cur_paths]
    lea rsi, [rip + cur_ents]
    lea rdx, [rip + cur_dirs]
    mov rcx, [rip + tsb + SB_ptr]
    mov r8, [rip + tsb + SB_len]
    mov r9d, ebx
    call add
    inc r13
    jmp 2b
7:  mov dword ptr [rip + state], FL_READY
    cmp dword ptr [rsp], 0
    je 8f
    mov dword ptr [rip + state], FL_LISTING
8:  call time_ms
    mov [rip + made_at], rax
    call signals                # as made now: not stale
    mov [rip + wgen], rax
    mov [rip + ggen], rdx
    mov [rip + tgen], rcx
    inc qword ptr [rip + gen]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# pad_num(n, width): n in decimal with leading zeros to tsb
pad_num:
    PROLOGUE 32
    mov rax, rdi
    mov ebx, esi
    lea r12, [rsp + 24]
    xor ecx, ecx
1:  xor edx, edx
    mov r8d, 10
    div r8
    add edx, '0'
    dec r12
    mov [r12], dl
    inc ecx
    test rax, rax
    jnz 1b
2:  cmp ecx, ebx
    jae 3f
    dec r12
    mov byte ptr [r12], '0'
    inc ecx
    jmp 2b
3:  lea rdi, [rip + tsb]
    mov rsi, r12
    mov edx, ecx
    call sb_push
    EPILOGUE

# FN filelist_dump(sb): "state=none|listing|ready n=N gen=G runs=R steps=S candidates=C rows=N cut=0|1"
FN filelist_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    mov eax, [rip + state]
    lea rcx, [rip + state_words]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    lea r12, [rip + dump_fields]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 2f
    mov rdi, rbx
    call sb_push_cstr
    mov rax, [r12 + 8]
    mov rsi, [rax]
    cmp qword ptr [r12 + 16], 0
    je 11f
    mov esi, esi
11: mov rdi, rbx
    call sb_push_u64
    add r12, 24
    jmp 1b
2:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Ltest: .ascii "test"
.Lslash_f: .asciz "/f"
.Ldot_c: .asciz ".c"
.Ld_state: .asciz "state="
.Ls_none: .asciz "none"
.Ls_listing: .asciz "listing"
.Ls_ready: .asciz "ready"
.Ld_n: .asciz " n="
.Ld_gen: .asciz " gen="
.Ld_runs: .asciz " runs="
.Ld_steps: .asciz " steps="
.Ld_cands: .asciz " candidates="
.Ld_rows: .asciz " rows="
.Ld_cut: .asciz " cut="
.Ld_maxstep: .asciz " maxstep="
.p2align 3
state_words: .quad .Ls_none, .Ls_listing, .Ls_ready
dump_fields:                    # the word, the value, 1 when it is a dword
    .quad .Ld_n, cur_ents + VEC_len, 0
    .quad .Ld_gen, gen, 0
    .quad .Ld_runs, runs, 0
    .quad .Ld_steps, steps, 0
    .quad .Ld_cands, cands_seen, 0
    .quad .Ld_rows, top_n, 0
    .quad .Ld_cut, cut, 1
    .quad .Ld_maxstep, step_max, 0
    .quad 0, 0, 0
