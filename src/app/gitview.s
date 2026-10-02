# git history tab: commit graph of the branches, the selected commit's message and files
.include "rhun.inc"

STRUCT
F CM_hash, 8            # cstr; "" for the work tree row
F CM_parent, 8          # first parent cstr, the others follow it; 0 when none
F CM_np, 4
F CM_lane, 4            # lane of the node
F CM_author, 8
F CM_time, 8
F CM_refs, 8            # "HEAD -> main, tag: v1, origin/main"
F CM_subject, 8
F CM_pass, 8            # lanes going past the row
F CM_in, 8              # lanes ending in the node from above
F CM_out, 8             # lanes leaving the node below
ENDSTRUCT CM_SIZE

.equ ID_GV_ROW, 0x7000          # + row
.equ ID_GV_SCROLL, 0x7e01
.equ ID_GV_DSCROLL, 0x7e02
.equ ID_GV_FILE, 0x7f00         # + file
.equ MAX_ROWS, 0xe00
.equ LANES, 64
.equ SHOW_LANES, 16

.bss
.p2align 3
logbuf: .zero SB_SIZE
commits: .zero VEC_SIZE         # CM; the first one is the work tree
lanes: .zero 8 * LANES          # the commit each lane leads to
det: .zero SB_SIZE              # "show" output for the selected commit
files: .zero VEC_SIZE           # GF of the selected row
sel_hash: .zero 72
det_hash: .zero 72
head_ix: .quad 0
det_author: .quad 0
det_time: .quad 0
det_msg: .quad 0
maskbuf: .quad 0
maskcap: .quad 0
htab: .quad 0                   # commit index + 1 by hash
hcap: .quad 0
tmp: .zero SB_SIZE
log_state: .long 0              # 0 nothing yet, 2 shown
loading: .long 0
log_again: .long 0
nlanes: .long 0
show_lanes: .long 0             # lanes drawn
sel: .long 0
sel_reveal: .long 0
list_scroll: .long 0
list_h: .long 0
det_scroll: .long 0
det_h: .long 0                  # content height of the details
det_state: .long 0              # 0 none, 1 loading, 2 shown
det_running: .long 0
ns_running: .long 0
.p2align 3
seg: .zero 64                   # aa_seg floats

.text

# ---------------- rows ----------------

# nrows() -> eax; the first row is the work tree
nrows:
    mov rax, [rip + commits + VEC_len]
    ret

# row_cm(row) -> CM*
row_cm:
    mov eax, edi
    imul rax, rax, CM_SIZE
    add rax, [rip + commits + VEC_ptr]
    ret

# git_tab() -> index of the history tab, or -1
git_tab:
    xor ecx, ecx
1:  cmp rcx, [rip + g_tabs + VEC_len]
    jae 2f
    imul rax, rcx, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    cmp qword ptr [rax + TAB_kind], TAB_GIT
    je 3f
    inc rcx
    jmp 1b
2:  mov rax, -1
    ret
3:  mov rax, rcx
    ret

# ---------------- commands ----------------

FN cmd_git_history
    push rbx
    cmp dword ptr [rip + g_git_on], 0
    jne 1f
    lea rdi, [rip + .Lno_repo]
    call app_toast
    pop rbx
    ret
1:  call git_tab
    test rax, rax
    js 2f
    mov rdi, rax
    call app_activate_tab
    jmp 3f
2:  xor edi, edi
    mov esi, TAB_GIT
    call app_add_tab
3:  call gitview_load
    pop rbx
    ret

# cmd_toggle_git(): the history tab; closes it when it is the current one
FN cmd_toggle_git
    push rbx
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 1f
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_GIT
    jne 1f
    mov rdi, [rip + g_tab_cur]
    call app_close_tab
    pop rbx
    ret
1:  call cmd_git_history
    pop rbx
    ret

# gitview_show_wip(): the history tab with the work tree selected
FN gitview_show_wip
    push rbx
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 1f
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_GIT
    je 2f
1:  call cmd_git_history
2:  mov byte ptr [rip + sel_hash], 0
    cmp dword ptr [rip + log_state], 2
    jne 3f
    xor edi, edi
    call select_row
3:  pop rbx
    ret

# gitview_reset(): another repository
FN gitview_reset
    mov qword ptr [rip + commits + VEC_len], 0
    mov qword ptr [rip + files + VEC_len], 0
    mov dword ptr [rip + log_state], 0
    mov dword ptr [rip + loading], 0
    mov dword ptr [rip + log_again], 0
    mov dword ptr [rip + det_state], 0
    mov dword ptr [rip + det_running], 0
    mov dword ptr [rip + ns_running], 0
    mov dword ptr [rip + sel], 0
    mov dword ptr [rip + list_scroll], 0
    mov dword ptr [rip + det_scroll], 0
    mov byte ptr [rip + sel_hash], 0
    mov byte ptr [rip + det_hash], 0
    ret

# gitview_head_moved(): HEAD or branches changed
FN gitview_head_moved
    push rbx
    call git_tab
    test rax, rax
    js 1f
    call gitview_load
1:  pop rbx
    ret

# gitview_load(): the log again
gitview_load:
    cmp dword ptr [rip + loading], 0
    je 1f
    mov dword ptr [rip + log_again], 1
    ret
1:  push rbx
    lea rdi, [rip + args_log]
    lea rsi, [rip + on_log]
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call git_run
    mov [rip + loading], eax
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# ---------------- the log ----------------

# on_log(ctx, ptr, len, status)
on_log:
    PROLOGUE
    mov dword ptr [rip + loading], 0
    mov rbx, rsi
    mov r12, rdx
    mov r13d, ecx
    lea rdi, [rip + logbuf]
    call sb_clear
    # no commits yet: the work tree alone
    test r13d, r13d
    jnz 1f
    lea rdi, [rip + logbuf]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
1:  call parse_log
    call build_index
    mov dword ptr [rip + log_state], 2
    call layout
    call restore_sel
    cmp dword ptr [rip + log_again], 0
    je 3f
    mov dword ptr [rip + log_again], 0
    call gitview_load
3:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# parse_log(): records "hash\x1fparents\x1fauthor\x1ftime\x1frefs\x1fsubject\x1e" into commits (in place)
parse_log:
    PROLOGUE
    mov qword ptr [rip + commits + VEC_len], 0
    mov qword ptr [rip + head_ix], 0
    lea rdi, [rip + commits]
    mov esi, CM_SIZE
    call vec_push
    lea rcx, [rip + .Lempty]
    mov [rax + CM_hash], rcx
    mov [rax + CM_author], rcx
    mov [rax + CM_refs], rcx
    lea rcx, [rip + .Lwip]
    mov [rax + CM_subject], rcx
    mov rbx, [rip + logbuf + SB_ptr]
    mov r12, [rip + logbuf + SB_len]
    add r12, rbx
.Lpl_rec:
    cmp rbx, r12
    jae .Lpl_done
    cmp byte ptr [rbx], 10
    jne 1f
    inc rbx
    jmp .Lpl_rec
1:  mov r13, rbx
2:  cmp r13, r12
    jae .Lpl_done
    cmp byte ptr [r13], 0x1e
    je 3f
    inc r13
    jmp 2b
3:  mov byte ptr [r13], 0
    lea rdi, [rip + commits]
    mov esi, CM_SIZE
    call vec_push
    mov r14, rax
    mov [r14 + CM_hash], rbx
    mov rdi, rbx
    call next_field
    mov [r14 + CM_parent], rax
    mov rdi, rax
    call next_field
    mov [r14 + CM_author], rax
    mov rdi, rax
    call next_field
    mov r15, rax
    mov rdi, rax
    call next_field
    mov [r14 + CM_refs], rax
    mov rdi, rax
    call next_field
    mov [r14 + CM_subject], rax
    mov rdi, r15
    call strlen
    mov rdi, r15
    mov rsi, rax
    call parse_u64
    mov [r14 + CM_time], rax
    # parents: spaces become ends of strings
    mov rdi, [r14 + CM_parent]
    xor eax, eax
    cmp byte ptr [rdi], 0
    je 5f
    mov eax, 1
4:  mov cl, [rdi]
    test cl, cl
    jz 5f
    cmp cl, ' '
    jne 41f
    mov byte ptr [rdi], 0
    inc eax
41: inc rdi
    jmp 4b
5:  mov [r14 + CM_np], eax
    test eax, eax
    jnz 6f
    mov qword ptr [r14 + CM_parent], 0
6:  # the first commit HEAD names
    cmp qword ptr [rip + head_ix], 0
    jne 7f
    mov rdi, [r14 + CM_refs]
    call is_head
    test eax, eax
    jz 7f
    mov rax, [rip + commits + VEC_len]
    dec rax
    mov [rip + head_ix], rax
7:  lea rbx, [r13 + 1]
    jmp .Lpl_rec
.Lpl_done:
    # the work tree comes after HEAD
    mov rax, [rip + head_ix]
    test rax, rax
    jz 9f
    imul rax, rax, CM_SIZE
    add rax, [rip + commits + VEC_ptr]
    mov rcx, [rax + CM_hash]
    mov rax, [rip + commits + VEC_ptr]
    mov [rax + CM_parent], rcx
    mov dword ptr [rax + CM_np], 1
9:  EPILOGUE

# build_index(): htab from the commits' hashes
build_index:
    PROLOGUE
    mov rax, [rip + commits + VEC_len]
    add rax, rax
    mov ecx, 64
2:  cmp rcx, rax
    jae 3f
    add rcx, rcx
    jmp 2b
3:  cmp rcx, [rip + hcap]
    jbe 4f
    mov [rip + hcap], rcx
    mov rdi, [rip + htab]
    lea rsi, [rcx*4]
    call mem_realloc
    mov [rip + htab], rax
4:  mov rdi, [rip + htab]
    mov rcx, [rip + hcap]
    xor eax, eax
    rep stosd
    mov ebx, 1
5:  cmp rbx, [rip + commits + VEC_len]
    jae 9f
    imul r12, rbx, CM_SIZE
    add r12, [rip + commits + VEC_ptr]
    mov rdi, [r12 + CM_hash]
    call hash_slot
    lea rcx, [rbx + 1]
    mov [rax], ecx
    inc rbx
    jmp 5b
9:  EPILOGUE

# hash_slot(hash) -> slot of htab for it (holding its index + 1, or 0)
hash_slot:
    push rbx
    push r12
    push r13
    mov r12, rdi
    call strlen
    mov rdi, r12
    mov rsi, rax
    call hash_line
    mov r13, [rip + hcap]
    dec r13
    and rax, r13
    mov rbx, rax
1:  mov rax, [rip + htab]
    lea rax, [rax + rbx*4]
    mov ecx, [rax]
    test ecx, ecx
    jz 9f
    imul rcx, rcx, CM_SIZE
    add rcx, [rip + commits + VEC_ptr]
    mov rdi, [rcx - CM_SIZE + CM_hash]
    mov rsi, r12
    push rax
    push rax
    call strcmp_eq
    mov ecx, eax
    pop rax
    pop rax
    test ecx, ecx
    jnz 9f
    inc rbx
    and rbx, r13
    jmp 1b
9:  pop r13
    pop r12
    pop rbx
    ret

# shown_above(hash, row) -> 1 when that commit's row came before (dates out of order)
shown_above:
    push rbx
    mov rbx, rsi
    call hash_slot
    mov ecx, [rax]
    xor eax, eax
    test ecx, ecx
    jz 1f
    dec ecx
    cmp rcx, rbx
    setb al
1:  pop rbx
    ret

# next_field(p) -> the field after p (its 0x1f becomes 0), or the end of the record
next_field:
    mov rax, rdi
1:  mov cl, [rax]
    test cl, cl
    jz 2f
    cmp cl, 0x1f
    je 3f
    inc rax
    jmp 1b
2:  ret
3:  mov byte ptr [rax], 0
    inc rax
    ret

# is_head(refs) -> 1 when the list starts with HEAD
is_head:
    xor eax, eax
    cmp dword ptr [rdi], 0x44414548 # "HEAD"
    jne 1f
    movzx ecx, byte ptr [rdi + 4]
    test ecx, ecx
    jz 2f
    cmp ecx, ' '
    je 2f
    cmp ecx, ','
    jne 1f
2:  mov eax, 1
1:  ret

# layout(): lanes of the graph, row by row
layout:
    PROLOGUE 16
    lea rdi, [rip + lanes]
    xor eax, eax
    mov ecx, 8 * LANES
    rep stosb
    mov dword ptr [rip + nlanes], 1
    xor ebx, ebx
.Lly_row:
    cmp rbx, [rip + commits + VEC_len]
    jae .Lly_done
    imul r12, rbx, CM_SIZE
    add r12, [rip + commits + VEC_ptr]
    # lanes leading here; the first of them holds the node
    xor r13d, r13d
    mov r14d, -1
    xor r15d, r15d
1:  lea rax, [rip + lanes]
    mov rdi, [rax + r15*8]
    test rdi, rdi
    jz 2f
    mov rsi, [r12 + CM_hash]
    call strcmp_eq
    test eax, eax
    jz 2f
    bts r13, r15
    test r14d, r14d
    jns 2f
    mov r14d, r15d
2:  inc r15d
    cmp r15d, LANES
    jb 1b
    test r14d, r14d
    jns 3f
    call free_lane              # a branch starts
    mov r14d, eax
    test eax, eax
    jns 3f
    mov r14d, LANES - 1
3:  mov [r12 + CM_lane], r14d
    mov [r12 + CM_in], r13
    call occupied
    mov rcx, r13
    not rcx
    and rax, rcx
    btr rax, r14
    mov [r12 + CM_pass], rax
    # lanes ending here are free
    lea rcx, [rip + lanes]
4:  bsf rax, r13
    jz 5f
    btr r13, rax
    mov qword ptr [rcx + rax*8], 0
    jmp 4b
5:  # parents: the first goes on in this lane; one shown above already gets no line
    xor r13d, r13d
    mov r15, [r12 + CM_parent]
    test r15, r15
    jz 8f
    mov rdi, r15
    mov rsi, rbx
    call shown_above
    test eax, eax
    jnz 51f
    lea rcx, [rip + lanes]
    mov [rcx + r14*8], r15
    bts r13, r14
51: mov eax, [r12 + CM_np]
    mov [rsp], eax
6:  dec dword ptr [rsp]
    jle 8f
    mov rdi, r15
    call strlen
    lea r15, [r15 + rax + 1]
    mov rdi, r15
    mov rsi, rbx
    call shown_above
    test eax, eax
    jnz 6b
    # joins a lane that leads there already, or takes a free one
    mov rdi, r15
    call lane_of
    test eax, eax
    jns 7f
    call free_lane
    test eax, eax
    js 6b
    lea rcx, [rip + lanes]
    mov [rcx + rax*8], r15
7:  bts r13, rax
    jmp 6b
8:  mov [r12 + CM_out], r13
    mov rax, [r12 + CM_pass]
    or rax, [r12 + CM_in]
    or rax, r13
    bts rax, r14
    bsr rax, rax
    inc eax
    cmp eax, [rip + nlanes]
    jbe 9f
    mov [rip + nlanes], eax
9:  inc rbx
    jmp .Lly_row
.Lly_done:
    EPILOGUE

# free_lane() -> first lane leading nowhere, or -1
free_lane:
    lea rcx, [rip + lanes]
    xor eax, eax
1:  cmp qword ptr [rcx + rax*8], 0
    je 2f
    inc eax
    cmp eax, LANES
    jb 1b
    mov eax, -1
2:  ret

# occupied() -> mask of lanes leading somewhere
occupied:
    lea rcx, [rip + lanes]
    xor eax, eax
    xor edx, edx
1:  cmp qword ptr [rcx + rdx*8], 0
    je 2f
    bts rax, rdx
2:  inc edx
    cmp edx, LANES
    jb 1b
    ret

# lane_of(hash) -> lane leading to that commit, or -1
lane_of:
    push rbx
    push r12
    push r13
    mov r12, rdi
    xor ebx, ebx
1:  lea rax, [rip + lanes]
    mov rdi, [rax + rbx*8]
    test rdi, rdi
    jz 2f
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 3f
2:  inc ebx
    cmp ebx, LANES
    jb 1b
    mov eax, -1
    jmp 4f
3:  mov eax, ebx
4:  pop r13
    pop r12
    pop rbx
    ret

# restore_sel(): select the row selected before, or the first
restore_sel:
    PROLOGUE
    call nrows
    mov r12d, eax
    test eax, eax
    jz 9f
    xor ebx, ebx
1:  cmp ebx, r12d
    jae 2f
    mov edi, ebx
    call row_cm
    mov rdi, [rax + CM_hash]
    lea rsi, [rip + sel_hash]
    call strcmp_eq
    test eax, eax
    jnz 3f
    inc ebx
    jmp 1b
2:  xor ebx, ebx
3:  mov edi, ebx
    call select_row
9:  EPILOGUE

# select_row(row): show its details
select_row:
    PROLOGUE
    mov [rip + sel], edi
    mov dword ptr [rip + sel_reveal], 1
    mov dword ptr [rip + g_dirty], 1
    call row_cm
    mov rbx, rax
    lea rdi, [rip + sel_hash]
    mov rsi, [rbx + CM_hash]
    call cstr_copy
    mov rax, [rbx + CM_hash]
    cmp byte ptr [rax], 0
    jne 1f
    # the work tree: the source control panel shows it
    mov byte ptr [rip + det_hash], 0
    mov dword ptr [rip + det_state], 2
    mov qword ptr [rip + files + VEC_len], 0
    EPILOGUE
1:  lea rdi, [rip + det_hash]
    mov rsi, [rbx + CM_hash]
    call strcmp_eq
    test eax, eax
    jz 2f
    cmp dword ptr [rip + det_state], 0
    jne 9f
2:  lea rdi, [rip + det_hash]
    mov rsi, [rbx + CM_hash]
    call cstr_copy
    mov dword ptr [rip + det_state], 1
    mov dword ptr [rip + det_scroll], 0
    mov qword ptr [rip + files + VEC_len], 0
    call details_fetch
9:  EPILOGUE

# details_fetch(): "show" for det_hash; one at a time, the one running asks again when it ends
details_fetch:
    cmp dword ptr [rip + det_running], 0
    jne 9f
    push rbx
    lea rax, [rip + det_hash]
    mov [rip + args_show_rev], rax
    lea rdi, [rip + args_show]
    lea rsi, [rip + on_details]
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call git_run
    mov [rip + det_running], eax
    pop rbx
9:  ret

# on_details(ctx, ptr, len, status): "hash\x1fparents\x1fauthor\x1ftime\x1fmessage\x1e", raw entries, numstat
on_details:
    PROLOGUE 16
    mov dword ptr [rip + det_running], 0
    mov rbx, rsi
    mov r12, rdx
    # for the commit still selected? if not, ask for that one
    lea rdi, [rip + det_hash]
    call strlen
    test rax, rax
    jz 9f
    cmp rax, r12
    ja 1f
    mov rdi, rbx
    lea rsi, [rip + det_hash]
    mov rdx, rax
    call memeq
    test eax, eax
    jnz 2f
1:  cmp dword ptr [rip + det_state], 1
    jne 9f
    call details_fetch
    jmp 9f
2:
    lea rdi, [rip + det]
    call sb_clear
    lea rdi, [rip + det]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    mov rbx, [rip + det + SB_ptr]
    mov r12, [rip + det + SB_len]
    add r12, rbx
    mov qword ptr [rip + files + VEC_len], 0
    # header
    mov r13, rbx
1:  cmp r13, r12
    jae 8f
    cmp byte ptr [r13], 0x1e
    je 2f
    inc r13
    jmp 1b
2:  mov byte ptr [r13], 0
    mov rdi, rbx
    call next_field
    mov rdi, rax
    call next_field
    mov [rip + det_author], rax
    mov rdi, rax
    call next_field
    mov r14, rax
    mov rdi, rax
    call next_field
    mov [rip + det_msg], rax
    mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    call parse_u64
    mov [rip + det_time], rax
    # files: ":mode mode id id X\0path\0"
    lea rbx, [r13 + 1]
.Lod_ent:
    cmp rbx, r12
    jae 8f
    movzx eax, byte ptr [rbx]
    test eax, eax
    jz 3f
    cmp eax, 10
    jne 4f
3:  inc rbx
    jmp .Lod_ent
4:  cmp eax, ':'
    jne 7f
    mov rdi, rbx
    call strlen
    lea r13, [rbx + rax]        # the NUL after the status letter
    movzx r14d, byte ptr [r13 - 1]
    lea rbx, [r13 + 1]
    cmp rbx, r12
    jae 8f
    cmp r14d, 'T'
    jne 41f
    mov r14d, 'M'
41: lea rdi, [rip + files]
    mov esi, GF_SIZE
    call vec_push
    mov [rax + GF_path], rbx
    mov [rax + GF_code], r14d
    mov dword ptr [rax + GF_add], -2
7:  # to the next entry
    mov rdi, rbx
    call strlen
    lea rbx, [rbx + rax + 1]
    jmp .Lod_ent
8:  mov dword ptr [rip + det_state], 2
    mov dword ptr [rip + g_dirty], 1
    call numstat_fetch
9:  EPILOGUE

# numstat_fetch(): lines added and deleted per file of det_hash, one job at a time
numstat_fetch:
    cmp dword ptr [rip + ns_running], 0
    jne 9f
    push rbx
    lea rax, [rip + det_hash]
    mov [rip + args_numstat_rev], rax
    lea rdi, [rip + args_numstat]
    lea rsi, [rip + on_numstat]
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call git_run
    mov [rip + ns_running], eax
    pop rbx
9:  ret

# on_numstat(ctx, ptr, len, status): "hash\0\n" then "added\tdeleted\tpath\0" in the order of the files
on_numstat:
    PROLOGUE
    mov dword ptr [rip + ns_running], 0
    mov rbx, rsi
    lea r12, [rsi + rdx]
    lea rdi, [rip + det_hash]
    call strlen
    mov r13, rax
    test rax, rax
    jz 9f
    lea rcx, [rbx + rax]
    cmp rcx, r12
    ja 1f
    mov rdi, rbx
    lea rsi, [rip + det_hash]
    mov rdx, r13
    call memeq
    test eax, eax
    jnz 2f
1:  # another commit is selected now
    cmp dword ptr [rip + det_state], 2
    jne 9f
    call numstat_fetch
    jmp 9f
2:  add rbx, r13
    xor r15d, r15d              # file
3:  cmp rbx, r12
    jae 8f
    movzx eax, byte ptr [rbx]
    test eax, eax
    jz 4f
    cmp eax, 10
    jne 5f
4:  inc rbx
    jmp 3b
5:  cmp r15, [rip + files + VEC_len]
    jae 8f
    imul r14, r15, GF_SIZE
    add r14, [rip + files + VEC_ptr]
    inc r15
    mov dword ptr [r14 + GF_add], -1
    cmp eax, '-'
    je 6f
    mov rdi, rbx
    mov rsi, r12
    sub rsi, rbx
    call parse_u64
    mov [r14 + GF_add], eax
    lea rdi, [rbx + rdx + 1]    # after the tab
    mov rsi, r12
    sub rsi, rdi
    call parse_u64
    mov [r14 + GF_del], eax
6:  mov rdi, rbx
    call strlen
    lea rbx, [rbx + rax + 1]
    jmp 3b
8:  mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# ---------------- drawing ----------------

# gitview_draw(x, y, w, h)
FN gitview_draw
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    COLOR r8d, T_BG
    call gfx_fill
    lea r9, [rip + .Lgit_off]
    cmp dword ptr [rip + cfg_git], 0
    je 11f
    lea r9, [rip + .Lno_repo]
    cmp dword ptr [rip + g_git_on], 0
    je 11f
    cmp dword ptr [rip + log_state], 2
    je 2f
    lea r9, [rip + .Lloading]
    cmp dword ptr [rip + loading], 0
    je 9f
11: lea rdi, [rip + g_face_ui]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    COLOR eax, T_MUTED
    push rax
    push r9
    call ui_text_center
    add rsp, 16
    jmp 9f
2:  # the list, the details on the right
    mov eax, [rsp + 8]
    imul eax, eax, 2
    xor edx, edx
    mov ecx, 5
    div ecx
    mov ebx, eax                # details width
    mov edi, 260
    call sc
    cmp ebx, eax
    cmovl ebx, eax
    mov eax, [rsp + 8]
    sub eax, ebx
    dec eax
    mov r12d, eax               # list width
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, r12d
    mov ecx, [rsp + 12]
    call draw_list
    mov edi, [rsp]
    add edi, r12d
    mov esi, [rsp + 4]
    M edx, MI_1
    mov ecx, [rsp + 12]
    COLOR r8d, T_BORDER
    call gfx_fill
    mov edi, [rsp]
    add edi, r12d
    add edi, [rip + g_mt + 4*MI_1]
    mov esi, [rsp + 4]
    mov edx, ebx
    mov ecx, [rsp + 12]
    call draw_details
9:  EPILOGUE

# draw_list(x, y, w, h)
draw_list:
    PROLOGUE 96
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rip + list_h], ecx
    M r15d, MI_28               # row height
    call nrows
    mov [rsp + 16], eax
    # wheel
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call ui_in
    test eax, eax
    jz 1f
    mov eax, [rip + g_scroll_y]
    add [rip + list_scroll], eax
1:  # keep the selection in view
    cmp dword ptr [rip + sel_reveal], 0
    je 2f
    mov dword ptr [rip + sel_reveal], 0
    mov eax, [rip + sel]
    imul eax, r15d
    cmp eax, [rip + list_scroll]
    jge 11f
    mov [rip + list_scroll], eax
11: add eax, r15d
    sub eax, [rsp + 12]
    cmp eax, [rip + list_scroll]
    jle 2f
    mov [rip + list_scroll], eax
2:  mov eax, [rsp + 16]
    imul eax, r15d
    sub eax, [rsp + 12]
    jns 21f
    xor eax, eax
21: cmp [rip + list_scroll], eax
    jle 22f
    mov [rip + list_scroll], eax
22: cmp dword ptr [rip + list_scroll], 0
    jge 23f
    mov dword ptr [rip + list_scroll], 0
23: mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    # graph width: the lanes, up to a third of the list
    mov eax, [rsp + 8]
    xor edx, edx
    mov ecx, 3
    div ecx
    xor edx, edx
    div dword ptr [rip + g_mt + 4*MI_16]
    cmp eax, 1
    jge 24f
    mov eax, 1
24: cmp eax, SHOW_LANES
    jbe 25f
    mov eax, SHOW_LANES
25: # more lanes than that: the last column stands for the rest
    mov ecx, eax
    cmp eax, [rip + nlanes]
    jb 26f
    mov eax, [rip + nlanes]
    mov ecx, eax
    inc ecx
26: dec ecx
    mov [rip + show_lanes], ecx
    imul eax, [rip + g_mt + 4*MI_16]
    add eax, [rip + g_mt + 4*MI_8]
    mov [rsp + 20], eax
    # first visible row
    mov eax, [rip + list_scroll]
    xor edx, edx
    div r15d
    mov ebx, eax
    imul eax, r15d
    mov r13d, [rsp + 4]
    add r13d, eax
    sub r13d, [rip + list_scroll]
.Ldl_row:
    cmp ebx, [rsp + 16]
    jae .Ldl_done
    mov eax, [rsp + 4]
    add eax, [rsp + 12]
    cmp r13d, eax
    jge .Ldl_done
    mov edi, ebx
    call row_cm
    mov r14, rax
    # interaction
    xor eax, eax
    cmp ebx, MAX_ROWS
    jae 3f
    lea edi, [rbx + ID_GV_ROW]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_12]
    mov r8d, r15d
    call ui_btn
3:  mov [rsp + 24], eax
    test eax, UB_PRESS
    jz 4f
    mov edi, ebx
    call select_row
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
4:  # background; the text of a filled row takes the interface colors
    COLOR eax, T_FG
    mov [rsp + 36], eax         # text color
    COLOR eax, T_MUTED
    mov [rsp + 40], eax         # muted text color
    COLOR r8d, T_ACTIVE
    cmp ebx, [rip + sel]
    je 41f
    test dword ptr [rsp + 24], UB_HOVER
    jz 42f
    COLOR r8d, T_HOVER
41: COLOR eax, T_UI_FG
    mov [rsp + 36], eax
    COLOR eax, T_UI_MUTED
    mov [rsp + 40], eax
    mov edi, [rsp]
    mov esi, r13d
    mov edx, [rsp + 8]
    mov ecx, r15d
    call gfx_fill
42: mov rdi, r14
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, r13d
    mov ecx, r15d
    call draw_graph
    mov r12d, [rsp]
    add r12d, [rip + g_mt + 4*MI_8]
    add r12d, [rsp + 20]
    # right columns: date, author
    mov eax, [rsp]
    add eax, [rsp + 8]
    sub eax, [rip + g_mt + 4*MI_24]
    mov [rsp + 28], eax         # right edge of the text
    mov rax, [r14 + CM_hash]
    cmp byte ptr [rax], 0
    je .Ldl_wip
    mov rdi, [r14 + CM_time]
    lea rsi, [rsp + 48]
    call fmt_age
    mov [rsp + 32], eax
    lea rdi, [rip + g_face_small]
    lea rsi, [rsp + 48]
    mov edx, eax
    call text_width
    mov esi, [rsp + 28]
    sub esi, eax
    lea rdi, [rip + g_face_small]
    mov edx, r13d
    mov ecx, r15d
    lea r8, [rsp + 48]
    mov r9d, [rsp + 32]
    mov eax, [rsp + 40]
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    mov edi, 90
    call sc
    sub [rsp + 28], eax
    # the author when the subject keeps room
    mov edi, 450
    call sc
    mov ecx, [rsp + 28]
    sub ecx, r12d
    cmp ecx, eax
    jl 5f
    mov edi, 150
    call sc
    sub [rsp + 28], eax
    mov rdi, [r14 + CM_author]
    call strlen
    mov r9, rax
    mov edi, 140
    call sc
    push rax
    mov eax, [rsp + 40 + 8]
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 28 + 16]
    mov edx, r13d
    mov ecx, r15d
    mov r8, [r14 + CM_author]
    call ui_text_v_fit
    add rsp, 16
5:  # ref chips (at most 40% of the room), then the subject
    mov eax, [rsp + 28]
    sub eax, r12d
    imul eax, eax, 2
    xor edx, edx
    mov ecx, 5
    div ecx
    lea r8d, [r12 + rax]
    mov rdi, [r14 + CM_refs]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    call chips
    mov r12d, eax
    mov rdi, [r14 + CM_subject]
    call strlen
    mov r9, rax
    mov eax, [rsp + 28]
    sub eax, r12d
    sub eax, [rip + g_mt + 4*MI_12]
    jle .Ldl_next
    push rax
    mov eax, [rsp + 36 + 8]
    push rax
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    mov r8, [r14 + CM_subject]
    call ui_text_v_fit
    add rsp, 16
    jmp .Ldl_next
.Ldl_wip:
    cmp dword ptr [rip + g_git_changes], 0
    jne 1f
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    lea r8, [rip + .Lclean]
    mov r9d, [rsp + 40]
    call ui_text_c
    jmp .Ldl_next
1:  lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    lea r8, [rip + .Lwip]
    mov r9d, [rsp + 36]
    call ui_text_c
    add eax, [rip + g_mt + 4*MI_8]
    mov r12d, eax
    lea rdi, [rsp + 48]
    mov esi, [rip + g_git_changes]
    call fmt_u64
    mov byte ptr [rdi], 0
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    lea r8, [rsp + 48]
    mov r9d, [rsp + 40]
    call ui_text_c
.Ldl_next:
    add r13d, r15d
    inc ebx
    jmp .Ldl_row
.Ldl_done:
    call gfx_clip_pop
    mov eax, [rsp + 16]
    imul eax, r15d
    mov ecx, [rsp + 12]
    push rcx
    push rax
    mov edi, ID_GV_SCROLL
    mov esi, [rsp + 16]
    add esi, [rsp + 16 + 8]
    M eax, MI_12
    sub esi, eax
    mov edx, [rsp + 16 + 4]
    mov ecx, eax
    mov r8d, [rsp + 16 + 12]
    lea r9, [rip + list_scroll]
    call ui_scrollbar
    add rsp, 16
    EPILOGUE

# lane_color(lane) -> argb
lane_color:
    and edi, 7
    lea rax, [rip + lane_slots]
    movzx eax, byte ptr [rax + rdi]
    lea rcx, [rip + g_theme]
    mov eax, [rcx + rax*4]
    ret

# draw_graph(cm, x, y, h): lines through the row and the commit's node
draw_graph:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    M eax, MI_16
    mov [rsp + 12], eax         # lane width
    mov eax, [rsp + 8]
    shr eax, 1
    add eax, [rsp + 4]
    mov [rsp + 16], eax         # center y
    mov edi, [rbx + CM_lane]
    cmp edi, [rip + show_lanes]
    jbe 1f
    mov edi, [rip + show_lanes]
1:  call lane_x
    mov [rsp + 20], eax         # node x (the last column for lanes not shown)
    xor r12d, r12d
.Ldg_lane:
    cmp r12d, [rip + show_lanes]
    jae .Ldg_node
    mov edi, r12d
    call lane_x
    mov r13d, eax
    mov edi, r12d
    call lane_color
    mov r14d, eax
    bt qword ptr [rbx + CM_pass], r12
    jnc 1f
    mov edi, r13d
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    call vline
1:  bt qword ptr [rbx + CM_in], r12
    jnc 3f
    cmp r12d, [rbx + CM_lane]
    jne 2f
    mov edi, r13d
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    shr edx, 1
    inc edx
    call vline
    jmp 3f
2:  mov edi, r13d
    mov esi, [rsp + 4]
    mov edx, [rsp + 20]
    mov ecx, [rsp + 16]
    mov r8d, r14d
    call aa_seg
3:  bt qword ptr [rbx + CM_out], r12
    jnc 5f
    cmp r12d, [rbx + CM_lane]
    jne 4f
    mov edi, r13d
    mov esi, [rsp + 16]
    mov edx, [rsp + 4]
    add edx, [rsp + 8]
    sub edx, esi
    call vline
    jmp 5f
4:  mov edi, [rsp + 20]
    mov esi, [rsp + 16]
    mov edx, r13d
    mov ecx, [rsp + 4]
    add ecx, [rsp + 8]
    mov r8d, r14d
    call aa_seg
5:  inc r12d
    jmp .Ldg_lane
.Ldg_node:
    mov eax, [rbx + CM_lane]
    cmp eax, [rip + show_lanes]
    jb 6f
    # in a lane not shown: a small muted dot in the last column
    COLOR r9d, T_MUTED
    M r12d, MI_3
    mov edi, [rsp + 20]
    sub edi, r12d
    mov esi, [rsp + 16]
    sub esi, r12d
    lea edx, [r12 + r12]
    mov ecx, edx
    mov r8d, r12d
    call gfx_round_rect
    jmp 9f
6:  mov edi, [rbx + CM_lane]
    call lane_color
    mov r14d, eax
    M r12d, MI_5                # radius
    mov edi, [rsp + 20]
    sub edi, r12d
    mov esi, [rsp + 16]
    sub esi, r12d
    lea edx, [r12 + r12]
    mov ecx, edx
    mov r8d, r12d
    mov r9d, r14d
    call gfx_round_rect
    # the work tree: a ring
    mov rax, [rbx + CM_hash]
    cmp byte ptr [rax], 0
    jne 9f
    M eax, MI_2
    sub r12d, eax
    mov edi, [rsp + 20]
    sub edi, r12d
    mov esi, [rsp + 16]
    sub esi, r12d
    lea edx, [r12 + r12]
    mov ecx, edx
    mov r8d, r12d
    COLOR r9d, T_BG
    call gfx_round_rect
9:  EPILOGUE
# lane_x(lane) -> center x (in draw_graph's frame)
lane_x:
    imul edi, [rsp + 8 + 12]
    mov eax, [rsp + 8 + 12]
    shr eax, 1
    add eax, edi
    add eax, [rsp + 8]
    ret
# vline(x, y, h): lane line of r14d color centered on x
vline:
    M eax, MI_2
    mov ecx, edx
    mov edx, eax
    shr eax, 1
    sub edi, eax
    mov r8d, r14d
    jmp gfx_fill

# aa_seg(x0, y0, x1, y1, argb): a lane line between two points, antialiased
aa_seg:
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rsp + 16], r8d
    # box around it
    mov eax, edi
    cmp eax, edx
    cmovg eax, edx
    sub eax, 3
    mov [rsp + 20], eax         # box x
    mov eax, edi
    cmp eax, edx
    cmovl eax, edx
    add eax, 4
    sub eax, [rsp + 20]
    mov [rsp + 24], eax         # box w
    mov eax, esi
    cmp eax, ecx
    cmovg eax, ecx
    sub eax, 3
    mov [rsp + 28], eax         # box y
    mov eax, esi
    cmp eax, ecx
    cmovl eax, ecx
    add eax, 4
    sub eax, [rsp + 28]
    mov [rsp + 32], eax         # box h
    # ends at pixel centers, in the box
    lea r12, [rip + seg]
    mov eax, [rsp]
    sub eax, [rsp + 20]
    cvtsi2ss xmm0, eax
    addss xmm0, [rip + f_half]
    movss [r12], xmm0           # x0
    mov eax, [rsp + 4]
    sub eax, [rsp + 28]
    cvtsi2ss xmm1, eax
    movss [r12 + 4], xmm1       # y0 (lines meet the row edges exactly)
    mov eax, [rsp + 8]
    sub eax, [rsp + 20]
    cvtsi2ss xmm2, eax
    addss xmm2, [rip + f_half]
    movss [r12 + 8], xmm2       # x1
    mov eax, [rsp + 12]
    sub eax, [rsp + 28]
    cvtsi2ss xmm3, eax
    movss [r12 + 12], xmm3      # y1
    # half width across the line
    subss xmm2, xmm0            # dx
    subss xmm3, xmm1            # dy
    movss xmm4, xmm2
    mulss xmm4, xmm2
    movss xmm5, xmm3
    mulss xmm5, xmm3
    addss xmm4, xmm5
    sqrtss xmm4, xmm4
    comiss xmm4, [rip + f_half]
    jbe 9f
    cvtsi2ss xmm5, dword ptr [rip + g_mt + 4*MI_2]
    mulss xmm5, [rip + f_half]
    divss xmm5, xmm4
    mulss xmm2, xmm5            # dx * hw / len
    mulss xmm3, xmm5
    xorps xmm6, xmm6
    subss xmm6, xmm3
    movss [r12 + 16], xmm6      # n = (-dy, dx) * hw / len
    movss [r12 + 20], xmm2
    # corners p0 + n, p1 + n, p1 - n, p0 - n
    movss xmm0, [r12]
    movss xmm1, [r12 + 4]
    movss xmm2, [r12 + 8]
    movss xmm3, [r12 + 12]
    movss xmm4, [r12 + 16]
    movss xmm5, [r12 + 20]
    movss xmm6, xmm0
    addss xmm6, xmm4
    movss [r12 + 24], xmm6
    movss xmm6, xmm1
    addss xmm6, xmm5
    movss [r12 + 28], xmm6
    movss xmm6, xmm2
    addss xmm6, xmm4
    movss [r12 + 32], xmm6
    movss xmm6, xmm3
    addss xmm6, xmm5
    movss [r12 + 36], xmm6
    movss xmm6, xmm2
    subss xmm6, xmm4
    movss [r12 + 40], xmm6
    movss xmm6, xmm3
    subss xmm6, xmm5
    movss [r12 + 44], xmm6
    movss xmm6, xmm0
    subss xmm6, xmm4
    movss [r12 + 48], xmm6
    movss xmm6, xmm1
    subss xmm6, xmm5
    movss [r12 + 52], xmm6
    mov edi, [rsp + 24]
    mov esi, [rsp + 32]
    call raster_begin
    xor edi, edi
    mov esi, 1
    call seg_edge
    mov edi, 1
    mov esi, 2
    call seg_edge
    mov edi, 2
    mov esi, 3
    call seg_edge
    mov edi, 3
    xor esi, esi
    call seg_edge
    # coverage mask
    mov eax, [rsp + 24]
    imul eax, [rsp + 32]
    cmp rax, [rip + maskcap]
    jbe 1f
    mov [rip + maskcap], rax
    mov rdi, [rip + maskbuf]
    mov rsi, rax
    call mem_realloc
    mov [rip + maskbuf], rax
1:  mov rdi, [rip + maskbuf]
    call raster_end
    mov edi, [rsp + 20]
    mov esi, [rsp + 28]
    mov rdx, [rip + maskbuf]
    mov ecx, [rsp + 24]
    mov r8d, [rsp + 32]
    mov r9d, [rsp + 16]
    call gfx_mask
9:  EPILOGUE

# seg_edge(i, j): the quad's edge from corner i to corner j
seg_edge:
    lea rax, [rip + seg + 24]
    movss xmm0, [rax + rdi*8]
    movss xmm1, [rax + rdi*8 + 4]
    movss xmm2, [rax + rsi*8]
    movss xmm3, [rax + rsi*8 + 4]
    jmp raster_line

# fmt_age(unix time, buf) -> eax length of "3 days ago"
fmt_age:
    PROLOGUE
    mov r12, rsi
    mov rbx, rdi
    call time_now
    sub rax, rbx
    jns 1f
    xor eax, eax
1:  mov r13, rax                # seconds ago
    cmp r13, 60
    jae 2f
    mov rdi, r12
    lea rsi, [rip + .Lnow]
    call cstr_copy
    sub rax, r12
    EPILOGUE
2:  # the largest unit that fits
    lea r14, [rip + age_units]
3:  mov rcx, [r14 + 16]
    test rcx, rcx
    jz 4f
    cmp r13, rcx
    jb 4f
    add r14, 16
    jmp 3b
4:  mov rax, r13
    xor edx, edx
    div qword ptr [r14]
    mov r15, rax
    mov rdi, r12
    mov rsi, rax
    call fmt_u64
    mov byte ptr [rdi], ' '
    inc rdi
    mov rsi, [r14 + 8]
    call cstr_copy
    mov rdi, rax
    cmp r15, 1
    je 5f
    mov byte ptr [rdi], 's'
    inc rdi
5:  lea rsi, [rip + .Lago]
    call cstr_copy
    sub rax, r12
    EPILOGUE

# chips(refs, x, y, h, right) -> x after the branch and tag names that fit left of right
chips:
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov [rsp + 24], r8d
.Lch_ref:
    cmp byte ptr [rbx], 0
    je .Lch_done
    # the name ends at ", "
    mov r15, rbx
1:  mov al, [r15]
    test al, al
    jz 2f
    cmp al, ','
    je 2f
    inc r15
    jmp 1b
2:  mov [rsp], r15
    mov dword ptr [rsp + 8], 0  # 1 current branch, 2 tag
    mov rdi, rbx
    mov rsi, r15
    sub rsi, rbx
    lea rdx, [rip + .Lhead_arrow]
    mov ecx, 8
    call str_starts
    test eax, eax
    jz 3f
    add rbx, 8
    mov dword ptr [rsp + 8], 1
    jmp 4f
3:  mov rdi, rbx
    mov rsi, r15
    sub rsi, rbx
    lea rdx, [rip + .Ltag]
    mov ecx, 5
    call str_starts
    test eax, eax
    jz 4f
    add rbx, 5
    mov dword ptr [rsp + 8], 2
4:  mov rax, r15
    sub rax, rbx
    mov [rsp + 16], rax         # name length
    lea rdi, [rip + g_face_small]
    mov rsi, rbx
    mov rdx, rax
    call text_width
    M ecx, MI_6
    lea eax, [rax + rcx*2]
    mov [rsp + 12], eax         # chip width
    add eax, r12d
    cmp eax, [rsp + 24]
    jg .Lch_done
    # chip
    COLOR r9d, T_HOVER
    cmp dword ptr [rsp + 8], 1
    jne 5f
    COLOR r9d, T_ACCENT
5:  cmp dword ptr [rsp + 8], 2
    jne 6f
    COLOR edi, T_BG
    COLOR esi, T_GIT_MOD
    mov edx, 60
    call color_mix
    mov r9d, eax
6:  M eax, MI_6
    mov edi, r12d
    lea esi, [r13 + rax]
    mov edx, [rsp + 12]
    mov ecx, r14d
    sub ecx, eax
    sub ecx, eax
    M r8d, MI_4
    call gfx_round_rect
    COLOR eax, T_UI_FG
    cmp dword ptr [rsp + 8], 1
    jne 7f
    COLOR eax, T_ACCENT_FG
7:  cmp dword ptr [rsp + 8], 2
    jne 71f
    COLOR eax, T_FG
71: push rax
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_6]
    mov edx, r13d
    mov ecx, r14d
    mov r8, rbx
    mov r9, [rsp + 16 + 16]
    call ui_text_v
    add rsp, 16
    add r12d, [rsp + 12]
    add r12d, [rip + g_mt + 4*MI_6]
    # next: skip ", "
    mov rbx, [rsp]
8:  mov al, [rbx]
    cmp al, ','
    je 81f
    cmp al, ' '
    jne .Lch_ref
81: inc rbx
    jmp 8b
.Lch_done:
    mov eax, r12d
    EPILOGUE

# draw_details(x, y, w, h): the selected row's message and changed files, source control for the work tree
draw_details:
    PROLOGUE 96
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov edi, [rip + sel]
    call row_cm
    mov rax, [rax + CM_hash]
    cmp byte ptr [rax], 0
    jne 2f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call scm_draw
    EPILOGUE
2:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    COLOR r8d, T_PANEL
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call ui_in
    test eax, eax
    jz 1f
    mov eax, [rip + g_scroll_y]
    add [rip + det_scroll], eax
1:  mov eax, [rip + det_h]
    sub eax, [rsp + 12]
    jns 11f
    xor eax, eax
11: cmp [rip + det_scroll], eax
    jle 12f
    mov [rip + det_scroll], eax
12: cmp dword ptr [rip + det_scroll], 0
    jge 13f
    mov dword ptr [rip + det_scroll], 0
13: mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    call nrows
    test eax, eax
    jz .Ldd_end
    M r15d, MI_16               # padding
    mov r12d, [rsp]
    add r12d, r15d              # text x
    mov eax, [rsp + 8]
    sub eax, r15d
    sub eax, r15d
    mov [rsp + 16], eax         # text width
    mov r13d, [rsp + 4]
    add r13d, [rip + g_mt + 4*MI_8]
    sub r13d, [rip + det_scroll]    # y
    mov edi, [rip + sel]
    call row_cm
    mov r14, rax
    mov r8, [r14 + CM_subject]
    call .Ldd_title
    # id, author, age
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [r14 + CM_hash]
    mov edx, 7
    call sb_push
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lsep]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [r14 + CM_author]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lsep]
    call sb_push_cstr
    mov rdi, [r14 + CM_time]
    lea rsi, [rsp + 48]
    call fmt_age
    lea rdi, [rip + tmp]
    lea rsi, [rsp + 48]
    mov edx, eax
    call sb_push
    mov r9, [rip + tmp + SB_len]
    mov eax, [rsp + 16]
    push rax
    COLOR eax, T_UI_MUTED
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, r13d
    M ecx, MI_24
    mov r8, [rip + tmp + SB_ptr]
    call ui_text_v_fit
    add rsp, 16
    add r13d, [rip + g_mt + 4*MI_32]
    cmp dword ptr [rip + det_state], 2
    je 3f
    lea r8, [rip + .Lloading]
    call .Ldd_note
    jmp .Ldd_end_content
3:  # the message after its first line
    mov rbx, [rip + det_msg]
31: mov al, [rbx]
    test al, al
    jz .Ldd_files
    inc rbx
    cmp al, 10
    jne 31b
32: cmp byte ptr [rbx], 10      # blank lines after the subject
    jne 33f
    inc rbx
    jmp 32b
33: cmp byte ptr [rbx], 0
    je 36f
    mov rcx, rbx
34: mov al, [rcx]
    test al, al
    jz 35f
    cmp al, 10
    je 35f
    inc rcx
    jmp 34b
35: mov [rsp + 24], rcx
    mov r9, rcx
    sub r9, rbx
    mov eax, [rsp + 16]
    push rax
    COLOR eax, T_UI_FG
    push rax
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, r13d
    M ecx, MI_24
    mov r8, rbx
    call ui_text_v_fit
    add rsp, 16
    add r13d, [rip + g_mt + 4*MI_24]
    mov rbx, [rsp + 24]
    cmp byte ptr [rbx], 0
    je 36f
    inc rbx
    # trailing blank lines end the message
    mov rcx, rbx
37: cmp byte ptr [rcx], 10
    jne 38f
    inc rcx
    jmp 37b
38: cmp byte ptr [rcx], 0
    je 36f
    jmp 33b
36: add r13d, [rip + g_mt + 4*MI_12]
.Ldd_files:
    # "N files"
    lea rdi, [rsp + 48]
    mov rsi, [rip + files + VEC_len]
    call fmt_u64
    lea rsi, [rip + .Lfiles]
    cmp qword ptr [rip + files + VEC_len], 1
    jne 4f
    lea rsi, [rip + .Lfile]
4:  call cstr_copy
    lea r8, [rsp + 48]
    call .Ldd_note
    xor ebx, ebx
.Ldd_file:
    cmp rbx, [rip + files + VEC_len]
    jae .Ldd_end_content
    imul r15, rbx, GF_SIZE
    add r15, [rip + files + VEC_ptr]
    M eax, MI_28
    mov [rsp + 20], eax         # row h
    # rows out of sight only add their height
    mov eax, [rsp + 4]
    add eax, [rsp + 12]
    cmp r13d, eax
    jl 91f
    mov rax, [rip + files + VEC_len]
    sub rax, rbx
    imul eax, [rsp + 20]
    add r13d, eax
    jmp .Ldd_end_content
91: mov eax, r13d
    add eax, [rsp + 20]
    cmp eax, [rsp + 4]
    jg 92f
    add r13d, [rsp + 20]
    inc rbx
    jmp .Ldd_file
92: lea edi, [rbx + ID_GV_FILE]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_12]
    mov r8d, [rsp + 20]
    call ui_btn
    mov [rsp + 24], eax
    test eax, UB_HOVER
    jz 5f
    M eax, MI_6
    mov edi, [rsp]
    add edi, eax
    mov esi, r13d
    mov edx, [rsp + 8]
    sub edx, eax
    sub edx, eax
    mov ecx, [rsp + 20]
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
5:  test dword ptr [rsp + 24], UB_CLICK
    jz 6f
    # the file's diff in this commit
    mov rdi, [r15 + GF_path]
    call strlen
    mov rdx, rax
    mov rsi, [r15 + GF_path]
    mov rdi, [r14 + CM_hash]
    call git_open_diff
    jmp .Ldd_end_content
6:  # letter, path, +added -deleted
    mov eax, [r15 + GF_code]
    mov [rsp + 48], eax
    mov edi, eax
    call git_code_color
    mov r9d, eax
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, r13d
    mov ecx, [rsp + 20]
    lea r8, [rsp + 48]
    call ui_text_c
    # counts, right-aligned
    mov eax, [rsp]
    add eax, [rsp + 8]
    sub eax, [rip + g_mt + 4*MI_20]
    mov [rsp + 28], eax         # right edge
    cmp dword ptr [r15 + GF_add], 0
    jl 7f
    mov esi, [r15 + GF_del]
    lea rcx, [rip + .Lminus]
    COLOR r9d, T_GIT_DEL
    call .Ldd_count
    mov esi, [r15 + GF_add]
    lea rcx, [rip + .Lplus]
    COLOR r9d, T_GIT_ADD
    call .Ldd_count
7:  mov rdi, [r15 + GF_path]
    call strlen
    mov r9, rax
    mov eax, [rsp + 28]
    sub eax, r12d
    sub eax, [rip + g_mt + 4*MI_32]
    push rax
    COLOR eax, T_UI_FG
    push rax
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_20]
    mov edx, r13d
    mov ecx, [rsp + 20 + 16]
    mov r8, [r15 + GF_path]
    call ui_text_v_fit
    add rsp, 16
    add r13d, [rsp + 20]
    inc rbx
    jmp .Ldd_file
.Ldd_end_content:
    add r13d, [rip + g_mt + 4*MI_16]
    add r13d, [rip + det_scroll]
    sub r13d, [rsp + 4]
    mov [rip + det_h], r13d
.Ldd_end:
    call gfx_clip_pop
    mov eax, [rsp + 12]
    push rax
    mov eax, [rip + det_h]
    push rax
    mov edi, ID_GV_DSCROLL
    mov esi, [rsp + 16]
    add esi, [rsp + 16 + 8]
    M eax, MI_12
    sub esi, eax
    mov edx, [rsp + 16 + 4]
    mov ecx, eax
    mov r8d, [rsp + 16 + 12]
    lea r9, [rip + det_scroll]
    call ui_scrollbar
    add rsp, 16
    EPILOGUE
# title r8 (cstr) at r13d, then down
.Ldd_title:
    sub rsp, 8
    mov [rsp], r8
    mov rdi, r8
    call strlen
    mov r9, rax
    mov r8, [rsp]
    mov eax, [rsp + 16 + 16]
    push rax
    COLOR eax, T_UI_FG
    push rax
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, r13d
    M ecx, MI_32
    call ui_text_v_fit
    add rsp, 16
    add r13d, [rip + g_mt + 4*MI_32]
    add rsp, 8
    ret
# muted note r8 (cstr) at r13d, then down
.Ldd_note:
    sub rsp, 8
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, r13d
    M ecx, MI_24
    COLOR r9d, T_UI_MUTED
    call ui_text_c
    add r13d, [rip + g_mt + 4*MI_28]
    add rsp, 8
    ret
# count esi with sign rcx in r9d color, right-aligned at [rsp + 28] (moves it left)
.Ldd_count:
    push rbx
    push r12
    sub rsp, 40
    mov [rsp + 32], r9d
    mov [rsp], rcx
    lea rdi, [rsp + 8]
    mov al, [rcx]
    mov [rdi], al
    inc rdi
    call fmt_u64
    lea r12, [rax + 1]          # length with the sign
    lea rdi, [rip + g_face_small]
    lea rsi, [rsp + 8]
    mov rdx, r12
    call text_width
    mov ebx, eax
    mov esi, [rsp + 56 + 8 + 28]
    sub esi, ebx
    mov [rsp + 56 + 8 + 28], esi
    lea rdi, [rip + g_face_small]
    mov edx, r13d
    mov ecx, [rsp + 56 + 8 + 20]
    lea r8, [rsp + 8]
    mov r9, r12
    mov eax, [rsp + 32]
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    M eax, MI_6
    sub [rsp + 56 + 8 + 28], eax
    add rsp, 40
    pop r12
    pop rbx
    ret

# gitview_key(keysym, cp, mods) -> 1 when used
FN gitview_key
    PROLOGUE
    mov r12d, edi
    call nrows
    mov r13d, eax
    test eax, eax
    jz .Lgk_no
    mov ebx, [rip + sel]
    M ecx, MI_28
    mov eax, [rip + list_h]
    xor edx, edx
    div ecx
    dec eax
    cmp eax, 1
    jge 1f
    mov eax, 1
1:  mov r14d, eax               # rows per page
    cmp r12d, KEY_UP
    jne 2f
    dec ebx
    jmp .Lgk_set
2:  cmp r12d, KEY_DOWN
    jne 3f
    inc ebx
    jmp .Lgk_set
3:  cmp r12d, KEY_PAGEUP
    jne 4f
    sub ebx, r14d
    jmp .Lgk_set
4:  cmp r12d, KEY_PAGEDOWN
    jne 5f
    add ebx, r14d
    jmp .Lgk_set
5:  cmp r12d, KEY_HOME
    jne 6f
    xor ebx, ebx
    jmp .Lgk_set
6:  cmp r12d, KEY_END
    jne 61f
    lea ebx, [r13 - 1]
    jmp .Lgk_set
61: # Enter on the work tree: to the commit message
    cmp r12d, KEY_RETURN
    je 62f
    cmp r12d, KEY_KP_ENTER
    jne .Lgk_no
62: test ebx, ebx
    jnz .Lgk_no
    call scm_focus
    mov eax, 1
    EPILOGUE
.Lgk_set:
    test ebx, ebx
    jns 7f
    xor ebx, ebx
7:  cmp ebx, r13d
    jl 8f
    lea ebx, [r13 - 1]
8:  mov edi, ebx
    call select_row
    mov eax, 1
    EPILOGUE
.Lgk_no:
    xor eax, eax
    EPILOGUE

# gitview_dump(sb): the graph as text ('*' node, '|' going past, '/' joining, '\' leaving), then the files
FN gitview_dump
    PROLOGUE
    mov rbx, rdi
    call nrows
    mov r12d, eax
    xor r13d, r13d
.Lgd_row:
    cmp r13d, r12d
    jae .Lgd_files
    mov edi, r13d
    call row_cm
    mov r14, rax
    xor r15d, r15d
1:  cmp r15d, [rip + nlanes]
    jae 3f
    mov esi, ' '
    bt qword ptr [r14 + CM_pass], r15
    jnc 11f
    mov esi, '|'
11: bt qword ptr [r14 + CM_out], r15
    jnc 12f
    mov esi, '\\'
12: bt qword ptr [r14 + CM_in], r15
    jnc 13f
    mov esi, '/'
13: cmp r15d, [r14 + CM_lane]
    jne 14f
    mov esi, '*'
14: mov rdi, rbx
    call sb_push_byte
    inc r15d
    jmp 1b
3:  mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rsi, [r14 + CM_subject]
    mov rax, [r14 + CM_hash]
    cmp byte ptr [rax], 0
    jne 31f
    cmp dword ptr [rip + g_git_changes], 0
    jne 31f
    lea rsi, [rip + .Lclean]
31: mov rdi, rbx
    call sb_push_cstr
    mov rax, [r14 + CM_refs]
    cmp byte ptr [rax], 0
    je 4f
    mov rdi, rbx
    lea rsi, [rip + .Lparen]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + CM_refs]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ')'
    call sb_push_byte
4:  cmp r13d, [rip + sel]
    jne 5f
    mov rdi, rbx
    lea rsi, [rip + .Lselected]
    call sb_push_cstr
5:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r13d
    jmp .Lgd_row
.Lgd_files:
    # the work tree: its changes by group
    call nrows
    test eax, eax
    jz 51f
    mov edi, [rip + sel]
    call row_cm
    mov rax, [rax + CM_hash]
    cmp byte ptr [rax], 0
    jne 51f
    mov rdi, rbx
    call scm_dump_files
    jmp 9f
51: xor r13d, r13d
6:  cmp r13, [rip + files + VEC_len]
    jae 9f
    imul r14, r13, GF_SIZE
    add r14, [rip + files + VEC_ptr]
    mov rdi, rbx
    lea rsi, [rip + .Lindent]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r14 + GF_code]
    call sb_push_byte
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r14 + GF_path]
    call sb_push_cstr
    cmp dword ptr [r14 + GF_add], 0
    jl 7f
    mov rdi, rbx
    lea rsi, [rip + .Lsp_plus]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r14 + GF_add]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lsp_minus]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r14 + GF_del]
    call sb_push_u64
7:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r13
    jmp 6b
9:  EPILOGUE

.section .rodata
.Lno_repo: .asciz "No git repository"
.Lgit_off: .asciz "Git is turned off in settings"
.Lempty: .asciz ""
.Lwip: .asciz "Uncommitted changes"
.Lclean: .asciz "No uncommitted changes"
.Lloading: .asciz "Loading..."
.Lnow: .asciz "just now"
.Lago: .asciz " ago"
.Lhead_arrow: .ascii "HEAD -> "
.Ltag: .ascii "tag: "
.Lsep: .asciz "  "
.Lfiles: .asciz " files changed"
.Lfile: .asciz " file changed"
.Lplus: .ascii "+"
.Lminus: .ascii "-"
.Lparen: .asciz " ("
.Lselected: .asciz " <"
.Lindent: .asciz "    "
.Lsp_plus: .asciz " +"
.Lsp_minus: .asciz " -"
.Lminute: .asciz "minute"
.Lhour: .asciz "hour"
.Lday: .asciz "day"
.Lweek: .asciz "week"
.Lmonth: .asciz "month"
.Lyear: .asciz "year"
.Llog: .asciz "log"
.Lbranches: .asciz "--branches"
.Lremotes: .asciz "--remotes"
.Ltags: .asciz "--tags"
.Lhead: .asciz "HEAD"
.Lmax: .asciz "-n3000"
.Llog_format: .asciz "--format=%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%s%x1e"
.Lshow: .asciz "show"
.Lshow_format: .asciz "--format=%H%x1f%P%x1f%an <%ae>%x1f%at%x1f%B%x1e"
.Lraw: .asciz "--raw"
.Lhash_format: .asciz "--format=%H"
.Lnumstat: .asciz "--numstat"
.Lz: .asciz "-z"
.Lno_renames: .asciz "--no-renames"
.Ldash_m: .asciz "-m"
.Lfirst_parent: .asciz "--first-parent"
.p2align 3
age_units:
    .quad 60, .Lminute, 3600, .Lhour, 86400, .Lday, 604800, .Lweek
    .quad 2592000, .Lmonth, 31536000, .Lyear, 0, 0
args_log:
    .quad .Llog, .Lbranches, .Lremotes, .Ltags, .Lhead, .Lmax, .Llog_format, 0
lane_slots:
    .byte T_ACCENT, T_TERM + 2, T_TERM + 5, T_TERM + 3, T_TERM + 6, T_TERM + 1, T_TERM + 4, T_TERM + 13
.data
.p2align 3
args_show:
    .quad .Lshow, .Lshow_format, .Lraw, .Lz, .Lno_renames, .Ldash_m, .Lfirst_parent
args_show_rev:
    .quad 0, 0
args_numstat:
    .quad .Lshow, .Lhash_format, .Lnumstat, .Lz, .Lno_renames, .Ldash_m, .Lfirst_parent
args_numstat_rev:
    .quad 0, 0
