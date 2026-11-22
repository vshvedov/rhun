# Workspace folders (docs/guide.md; docs/extensions/v1.1.md, feature workspace-folders). A window has
# zero or more folders, 16 at most; the first, the primary, is g_project, and every other part of
# rhun that means "the project" keeps meaning it. Folders do not nest. Each folder has an id that
# stays the same for the rhun session (removing and adding a path again gives a new one) and a
# display name unique in the window (a second "src" is "src 2"). Folders added to a project are
# remembered with its primary folder (<state>/<project>.folders, one path a line) and come back
# when it is opened again, before the explorer, git and extensions see the project.
#
#   workspace_reset()            set_project: the primary, then the remembered (or carried) folders
#   workspace_add(path) -> rax the new folder's id, or -17 already a folder, -22 inside one or
#     around one, -28 16 folders, -20 not a folder
#   workspace_remove(id) -> eax 1 when it went (the primary's going opens the next folder)
#   wfold_count() -> eax; wfold_path(i), wfold_name(i) -> rax cstr; wfold_id(i) -> rax;
#   wfold_flags(i) -> eax WFR_*; wfold_index(id) -> rax index or -1; wfold_of(path) -> rax the index
#   of the folder the path is in, or -1; wfold_join(label) -> rax an owned absolute path for a label
#   a list shows ("name/rel" with two folders or more, "rel" with one)
#   g_ws_gen                      changes whenever the folders do
.include "rhun.inc"

.equ WS_MAX, 16
STRUCT
F WFR_path, 8           # owned, absolute, no trailing separator
F WFR_name, 8           # owned display name
F WFR_id, 8
ENDSTRUCT WFR_SIZE

.bss
.p2align 3
ws_folders: .zero VEC_SIZE
ws_next_id: .quad 0
ws_carry: .zero VEC_SIZE        # owned paths workspace_reset adds instead of the remembered ones
ws_buf: .zero SB_SIZE
ws_name: .zero 280
ws_it: .zero INI_SIZE
ws_file_next: .quad 0           # the workspace file workspace_reset takes as the window's
.globl g_ws_gen, g_ws_file
g_ws_file: .quad 0              # the workspace file the window opened or saved (owned), or 0
g_ws_gen: .long 0

.text

# FN wfold_count() -> eax
FN wfold_count
    mov rax, [rip + ws_folders + VEC_len]
    ret

# ws_at(i) -> rax the WSF of folder i, or 0
ws_at:
    xor eax, eax
    cmp rdi, [rip + ws_folders + VEC_len]
    jae 1f
    imul rax, rdi, WFR_SIZE
    add rax, [rip + ws_folders + VEC_ptr]
1:  ret

# FN wfold_path(i) -> rax
FN wfold_path
    call ws_at
    test rax, rax
    jz 1f
    mov rax, [rax + WFR_path]
1:  ret

# FN wfold_name(i) -> rax
FN wfold_name
    call ws_at
    test rax, rax
    jz 1f
    mov rax, [rax + WFR_name]
1:  ret

# FN wfold_id(i) -> rax
FN wfold_id
    call ws_at
    test rax, rax
    jz 1f
    mov rax, [rax + WFR_id]
1:  ret

# FN wfold_flags(i) -> eax WS_PRIMARY for the first, WS_TRUSTED unless a rhun:// link opened the
# project and the user has not trusted it
FN wfold_flags
    push rdi
    call ws_at
    pop rdi
    test rax, rax
    jz 9f
    xor eax, eax
    test rdi, rdi
    jnz 1f
    mov eax, WS_PRIMARY
1:  cmp dword ptr [rip + g_project_link], 0
    je 2f
    cmp qword ptr [rip + g_git_root], 0
    je 9f
    cmp dword ptr [rip + g_git_paused], 0
    jne 9f
2:  or eax, WS_TRUSTED
9:  ret

# FN wfold_index(id) -> rax
FN wfold_index
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + ws_folders + VEC_len]
    jae 8f
    mov rdi, rbx
    call ws_at
    cmp [rax + WFR_id], r12
    je 9f
    inc rbx
    jmp 1b
8:  mov rbx, -1
9:  mov rax, rbx
    EPILOGUE

# FN wfold_of(path) -> rax the index of the folder the path is in, or -1
FN wfold_of
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + ws_folders + VEC_len]
    jae 8f
    mov rdi, rbx
    call ws_at
    mov rdi, r12
    mov rsi, [rax + WFR_path]
    call app_path_inside
    test eax, eax
    jnz 9f
    inc rbx
    jmp 1b
8:  mov rbx, -1
9:  mov rax, rbx
    EPILOGUE

# FN wfold_cwd() -> rax the folder a new terminal starts in: the active document's workspace folder,
# else the primary (g_project, which may be 0)
FN wfold_cwd
    PROLOGUE
    mov rax, [rip + g_doc]
    test rax, rax
    jz 8f
    mov rdi, [rax + DOC_path]
    test rdi, rdi
    jz 8f
    call wfold_of
    test rax, rax
    js 8f
    mov rdi, rax
    call wfold_path
    EPILOGUE
8:  mov rax, [rip + g_project]
    EPILOGUE

# FN wfold_title() -> rax the window title's project part: the project's name, or the folders'
# names joined by " + " (a cstr of this module) with two folders or more
FN wfold_title
    PROLOGUE
    mov rdi, [rip + g_ws_file]  # a workspace file: its name
    test rdi, rdi
    jz 0f
    call strlen
    mov rdi, [rip + g_ws_file]
    mov rsi, rax
    call path_basename
    lea rdi, [rip + ws_name]
    mov rsi, rax
    call cstr_copy
    lea rcx, [rip + ws_name]
    sub rax, rcx
    cmp rax, 15
    jbe 87f
    lea rcx, [rip + ws_name]
    mov byte ptr [rcx + rax - 15], 0
87: lea rax, [rip + ws_name]
    EPILOGUE
0:  mov rax, [rip + g_project_name]
    cmp qword ptr [rip + ws_folders + VEC_len], 2
    jb 9f
    lea rdi, [rip + ws_buf]
    call sb_clear
    xor ebx, ebx
1:  cmp rbx, [rip + ws_folders + VEC_len]
    jae 2f
    test rbx, rbx
    jz 11f
    lea rdi, [rip + ws_buf]
    lea rsi, [rip + .Lplus]
    call sb_push_cstr
11: mov rdi, rbx
    call wfold_name
    lea rdi, [rip + ws_buf]
    mov rsi, rax
    call sb_push_cstr
    inc rbx
    jmp 1b
2:  lea rdi, [rip + ws_buf]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + ws_buf + SB_ptr]
9:  EPILOGUE

# FN wfold_join(label) -> rax an owned path: with one folder the label is relative to it, with more
# its first part names the folder
FN wfold_join
    PROLOGUE
    mov r12, rdi
    cmp qword ptr [rip + ws_folders + VEC_len], 1
    ja 2f
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 8f
1:  mov rsi, r12
    call path_join
    EPILOGUE
2:  xor ebx, ebx
3:  cmp rbx, [rip + ws_folders + VEC_len]
    jae 8f
    mov rdi, rbx
    call ws_at
    mov r13, rax
    mov rdi, [r13 + WFR_name]
    call strlen
    mov r14, rax
    mov rdi, r12
    mov rsi, [r13 + WFR_name]
    mov rdx, r14
    call strncmp_eq
    test eax, eax
    jz 4f
    cmp byte ptr [r12 + r14], '/'
    jne 4f
    mov rdi, [r13 + WFR_path]
    lea r12, [r12 + r14 + 1]
    jmp 1b
4:  inc rbx
    jmp 3b
8:  mov rdi, r12                # not a folder's: as it is
    call dup_cstr
    EPILOGUE

# strncmp_eq(a, b, n) -> eax 1 when the first n bytes are the same
strncmp_eq:
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 2f
    movzx eax, byte ptr [rdi + rcx]
    cmp al, [rsi + rcx]
    jne 3f
    inc rcx
    jmp 1b
2:  mov eax, 1
    ret
3:  xor eax, eax
    ret

# ---------------- changing the folders ----------------

# ws_clear(): every folder goes
ws_clear:
    PROLOGUE
1:  mov rax, [rip + ws_folders + VEC_len]
    test rax, rax
    jz 9f
    dec rax
    mov [rip + ws_folders + VEC_len], rax
    mov rdi, rax
    call ws_at_any
    mov rbx, rax
    mov rdi, [rbx + WFR_path]
    call mem_free
    mov rdi, [rbx + WFR_name]
    call mem_free
    jmp 1b
9:  EPILOGUE

# ws_at_any(i) -> rax the WSF slot i (also past the length)
ws_at_any:
    imul rax, rdi, WFR_SIZE
    add rax, [rip + ws_folders + VEC_ptr]
    ret

# ws_push(path cstr) -> rax the new folder's id: appended with a new id and a unique name
ws_push:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov r12, rax
    # its name: the last part, made unique
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call path_basename
    mov r13, rax
    cmp byte ptr [r13], 0
    jne 1f
    mov r13, r12                # a root: its path
1:  mov rdi, r13
    call strlen
    cmp rax, 250
    jbe 2f
    mov eax, 250
2:  lea rdi, [rip + ws_name]
    mov rsi, r13
    mov rcx, rax
    rep movsb
    mov byte ptr [rdi], 0
    mov r14, rdi                # where " N" goes
    mov r15d, 1
3:  call ws_name_taken
    test eax, eax
    jz 4f
    inc r15d
    mov byte ptr [r14], ' '
    lea rdi, [r14 + 1]
    mov esi, r15d
    call fmt_u64
    mov byte ptr [rdi], 0
    jmp 3b
4:  lea rdi, [rip + ws_folders]
    mov esi, WFR_SIZE
    call vec_push
    mov rbx, rax
    mov [rbx + WFR_path], r12
    lea rdi, [rip + ws_name]
    call dup_cstr
    mov [rbx + WFR_name], rax
    inc qword ptr [rip + ws_next_id]
    mov rax, [rip + ws_next_id]
    mov [rbx + WFR_id], rax
    inc dword ptr [rip + g_ws_gen]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ws_name_taken() -> eax 1 when a folder already has the name in ws_name
ws_name_taken:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + ws_folders + VEC_len]
    jae 8f
    mov rdi, rbx
    call ws_at
    mov rdi, [rax + WFR_name]
    lea rsi, [rip + ws_name]
    call strcmp_eq
    test eax, eax
    jnz 9f
    inc rbx
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# ws_check(path) -> rax 0 when the path may become a folder, else -errno (workspace_add's)
ws_check:
    PROLOGUE
    mov r12, rdi
    mov rax, -28
    cmp qword ptr [rip + ws_folders + VEC_len], WS_MAX
    jae 9f
    mov rdi, r12
    call vfs_is_dir
    test eax, eax
    mov rax, -20
    jz 9f
    xor ebx, ebx
1:  cmp rbx, [rip + ws_folders + VEC_len]
    jae 8f
    mov rdi, rbx
    call ws_at
    mov r13, [rax + WFR_path]
    mov rdi, r12
    mov rsi, r13
    call app_path_inside
    test eax, eax
    jz 2f
    # the folder itself, or inside it
    mov r14, rdx
    mov rdi, r12
    call strlen
    cmp rax, r14
    mov rax, -17
    je 9f
    mov rax, -22
    jmp 9f
2:  mov rdi, r13                # around it
    mov rsi, r12
    call app_path_inside
    test eax, eax
    mov rax, -22
    jnz 9f
    inc rbx
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# ws_path_clean(path) -> rax an owned absolute normalized copy without a trailing separator
ws_path_clean:
    PROLOGUE
    mov rbx, rdi
.ifdef WINDOWS
    call win_fullpath           # absolute, the system's way
    test rax, rax
    jnz 2f
    mov rdi, rbx
    call dup_cstr
    jmp 2f
.endif
    PATH_ABSOLUTE rbx, 1f
    sub rsp, 4096
    mov rdi, rsp
    mov esi, 4000
    SYS SYS_getcwd
    mov rdi, rsp
    mov rsi, rbx
    call path_join
    add rsp, 4096
    jmp 2f
1:  mov rdi, rbx
    call dup_cstr
2:  mov rbx, rax
    mov rdi, rax
    call path_normalize
    mov rdi, rbx
    call strlen
.ifdef WINDOWS
    mov r12, rax
    mov rdi, rbx
    call path_rootlen
    mov rcx, rax
    mov rax, r12
    cmp rax, rcx
.else
    cmp rax, 1
.endif
    jbe 3f
    movzx ecx, byte ptr [rbx + rax - 1]
    cmp ecx, '/'
    je 31f
    cmp ecx, 92
    jne 3f
31: mov byte ptr [rbx + rax - 1], 0
3:  mov rax, rbx
    EPILOGUE

# FN workspace_add(path) -> rax the id or -errno; a folder added is remembered with the project
FN workspace_add
    PROLOGUE
    cmp qword ptr [rip + g_project], 0
    jne 1f
    # a window without a project opens it as the primary
    call app_set_project
    mov rax, [rip + ws_folders + VEC_len]
    test rax, rax
    jz 7f
    xor edi, edi
    call wfold_id
    EPILOGUE
1:  call ws_path_clean
    mov rbx, rax
    mov rdi, rax
    call ws_check
    test rax, rax
    jnz 8f
    mov rdi, rbx
    call ws_push
    mov r12, rax
    call ws_save
    call ws_changed
    mov rdi, rbx
    call mem_free
    mov rax, r12
    EPILOGUE
7:  mov rax, -20
    EPILOGUE
8:  mov r12, rax
    mov rdi, rbx
    call mem_free
    mov rax, r12
    EPILOGUE

# FN workspace_remove(id) -> eax 1 when the folder went. The primary's going makes the next folder
# the primary: the window takes it up (its unsaved files asked about first) and keeps the others.
FN workspace_remove
    PROLOGUE
    call wfold_index
    test rax, rax
    js 8f
    mov rbx, rax
    test rbx, rbx
    jnz 3f
    # the primary: the next one takes its place
    cmp qword ptr [rip + ws_folders + VEC_len], 2
    jb 8f
    call ws_carry_clear
    mov r12d, 2
1:  cmp r12, [rip + ws_folders + VEC_len]
    jae 2f
    mov rdi, r12
    call wfold_path
    mov rdi, rax
    call dup_cstr
    mov r13, rax
    lea rdi, [rip + ws_carry]
    mov esi, 8
    call vec_push
    mov [rax], r13
    inc r12
    jmp 1b
2:  mov edi, 1
    call wfold_path
    mov rdi, rax
    call dup_cstr
    mov r12, rax
    mov dword ptr [rip + ws_carrying], 1
    mov rdi, r12
    call ws_carry_for_set
    mov rdi, r12
    call app_switch_project
    mov rdi, r12
    call mem_free
    mov eax, 1
    EPILOGUE
3:  mov rdi, rbx
    call ws_at
    mov r12, rax
    mov rdi, [r12 + WFR_path]
    call mem_free
    mov rdi, [r12 + WFR_name]
    call mem_free
    # the later ones move up
    mov rdi, r12
    lea rsi, [r12 + WFR_SIZE]
    mov rax, [rip + ws_folders + VEC_len]
    sub rax, rbx
    dec rax
    imul rdx, rax, WFR_SIZE
    call memmove
    dec qword ptr [rip + ws_folders + VEC_len]
    inc dword ptr [rip + g_ws_gen]
    call ws_save
    call ws_changed
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ws_carry_for_set(path): the carried folders join the project of this path only (a switch the user
# cancelled carries nothing into a later one)
ws_carry_for_set:
    PROLOGUE
    call dup_cstr
    mov rdi, [rip + ws_carry_for]
    mov [rip + ws_carry_for], rax
    call mem_free
    EPILOGUE

# ws_carry_clear(): the carried paths go
ws_carry_clear:
    PROLOGUE
1:  mov rax, [rip + ws_carry + VEC_len]
    test rax, rax
    jz 9f
    dec rax
    mov [rip + ws_carry + VEC_len], rax
    mov rcx, [rip + ws_carry + VEC_ptr]
    mov rdi, [rcx + rax*8]
    call mem_free
    jmp 1b
9:  mov dword ptr [rip + ws_carrying], 0
    EPILOGUE

# ws_changed(): the parts that show or use the folders follow
ws_changed:
    PROLOGUE
    call explorer_set_root
    call app_update_title
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN workspace_reset(): the primary (g_project), then the folders remembered with it, or those the
# primary's removal carried over
FN workspace_reset
    PROLOGUE
    call ws_clear
    inc dword ptr [rip + g_ws_gen]
    # the workspace file it came from, if one opened it (else none)
    mov rdi, [rip + g_ws_file]
    call mem_free
    mov rax, [rip + ws_file_next]
    mov [rip + g_ws_file], rax
    mov qword ptr [rip + ws_file_next], 0
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 8f
    call ws_push
    cmp dword ptr [rip + ws_carrying], 0
    je 3f
    mov rdi, [rip + g_project]  # carried for this project? (else for one the user cancelled)
    mov rsi, [rip + ws_carry_for]
    test rsi, rsi
    jz 0f
    call strcmp_eq
    test eax, eax
    jnz 86f
0:  call ws_carry_clear
    mov rdi, [rip + g_ws_file]  # nor its workspace file
    call mem_free
    mov qword ptr [rip + g_ws_file], 0
    jmp 3f
86: xor ebx, ebx
1:  cmp rbx, [rip + ws_carry + VEC_len]
    jae 2f
    mov rax, [rip + ws_carry + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call ws_add_quiet
    inc rbx
    jmp 1b
2:  call ws_carry_clear
    call ws_save
    jmp 8f
3:  # the remembered folders
    lea rdi, [rip + .Lext_folders]
    call session_project_file
    test rax, rax
    jz 8f
    mov rdi, rax
    call file_read_all
    test rax, rax
    jz 8f
    mov r12, rax
    lea r13, [rax + rdx]
    mov rbx, rax
4:  cmp rbx, r13
    jae 7f
    mov r14, rbx
5:  cmp r14, r13
    jae 6f
    cmp byte ptr [r14], 10
    je 6f
    inc r14
    jmp 5b
6:  mov byte ptr [r14], 0
    cmp r14, rbx
    je 61f
    mov rdi, rbx
    call ws_add_quiet
61: lea rbx, [r14 + 1]
    jmp 4b
7:  mov rdi, r12
    call mem_free
8:  EPILOGUE

# ws_add_quiet(path): added when it may be (a folder that went is skipped)
ws_add_quiet:
    PROLOGUE
    mov r12, rdi
    PATH_ABSOLUTE r12, 1f
    jmp 9f                      # remembered paths are absolute
1:  mov rdi, r12
    call ws_check
    test rax, rax
    jnz 9f
    mov rdi, r12
    call ws_push
9:  EPILOGUE

# ws_save(): <state>/<project>.folders: the folders after the primary, one a line (none: removed)
ws_save:
    PROLOGUE
    lea rdi, [rip + ws_buf]
    call sb_clear
    mov ebx, 1
1:  cmp rbx, [rip + ws_folders + VEC_len]
    jae 2f
    mov rdi, rbx
    call wfold_path
    lea rdi, [rip + ws_buf]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + ws_buf]
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 1b
2:  lea rdi, [rip + .Lext_folders]
    call session_project_file
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp qword ptr [rip + ws_buf + SB_len], 0
    jne 3f
    mov rdi, rbx
    call vfs_unlink
    jmp 9f
3:  mov rdi, rbx
    mov rsi, [rip + ws_buf + SB_ptr]
    mov rdx, [rip + ws_buf + SB_len]
    call file_write_all
9:  EPILOGUE

# ---------------- workspace files ----------------
# NAME.rhun-workspace (INI): [folders] with a path = line for each folder (relative to the file's
# folder, or absolute), then [owner/name] sections with extensions' workspace settings (extconfig.s).

# ws_is_file(path) -> eax 1 when the path names a .rhun-workspace file
ws_is_file:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lsuffix]
    mov ecx, 15
    call str_ends
    EPILOGUE

# FN workspace_open_file(path) -> eax 1 when it was a workspace file: its first folder becomes the
# primary (the window takes it up as Open Folder does), the others join it, and its settings apply
FN workspace_open_file
    PROLOGUE 16
    mov rbx, rdi
    call ws_is_file
    test eax, eax
    jz 9f
    mov rdi, rbx
    call vfs_is_dir
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov esi, 65536
    call vfs_read_limited
    test rax, rax
    jz 7f
    mov r12, rax
    mov r13, rdx
    call ws_carry_clear
    # its folder, for relative paths
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call path_dirlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov [rsp], rax
    lea r14, [rip + ws_it]
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    call ini_init
    xor r15d, r15d              # the first folder
1:  mov rdi, r14
    call ini_next
    test eax, eax
    jz 3f
    mov rdi, r14
    lea rsi, [rip + .Lsec_folders]
    call ini_sec_is
    test eax, eax
    jz 1b
    mov rdi, r14
    lea rsi, [rip + .Lk_path]
    call ini_key_is
    test eax, eax
    jz 1b
    mov rdi, [r14 + INI_val]
    mov rsi, [r14 + INI_vallen]
    call mem_dup
    mov [rsp + 8], rax
    mov rdi, rax
    PATH_ABSOLUTE rdi, 2f
    mov rdi, [rsp]              # relative: to the file's folder
    mov rsi, [rsp + 8]
    call path_join
    push rax
    push rax
    mov rdi, [rsp + 24]
    call mem_free
    pop rax
    pop rax
    mov [rsp + 8], rax
2:  mov rdi, [rsp + 8]
    call ws_path_clean
    push rax
    push rax
    mov rdi, [rsp + 24]
    call mem_free
    pop rax
    pop rax
    test r15, r15
    jnz 21f
    # the primary must be a folder (a later one is checked when it joins): else the next one
    push rax
    push rax
    mov rdi, rax
    call vfs_is_dir
    mov ecx, eax
    pop rax
    pop rax
    test ecx, ecx
    jz 22f
    mov r15, rax
    jmp 1b
22: mov rdi, rax
    call mem_free
    jmp 1b
21: mov r13, rax
    lea rdi, [rip + ws_carry]
    mov esi, 8
    call vec_push
    mov [rax], r13
    jmp 1b
3:  mov rdi, r12
    call mem_free
    mov rdi, [rsp]
    call mem_free
    test r15, r15
    jz 7f
    mov dword ptr [rip + ws_carrying], 1
    mov rdi, r15
    call ws_carry_for_set
    mov rdi, rbx
    call dup_cstr
    mov rdi, [rip + ws_file_next]
    mov [rip + ws_file_next], rax
    call mem_free
    # the project already: its folders and workspace file change in place (app_switch_project
    # keeps an unchanged project as it is)
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 41f
    mov rdi, r15
.ifdef WINDOWS
    call win_path_equal
.else
    call strcmp_eq
.endif
    test eax, eax
    jz 41f
    # a window a file opened adopts its folder as a project first (app_switch_project promotes it)
    mov rdi, [rip + g_project]
    call app_switch_project
    mov rdi, [rip + g_project]
    call ws_carry_for_set
    call workspace_reset
    call ws_changed
    jmp 5f
41: mov rdi, r15
    cmp dword ptr [rip + g_started], 0
    je 4f
    call app_switch_project
    jmp 5f
4:  call app_set_project
5:  mov rdi, r15
    call mem_free
    call app_update_title
8:  mov eax, 1
    EPILOGUE
7:  lea rdi, [rip + .Lt_no_folder]
    call app_toast
    mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# FN workspace_save_as(ptr, len): the folders (and the extensions' sections of the workspace file
# in use) written to NAME.rhun-workspace (the suffix added when missing; a relative name is in the
# primary folder); the window keeps it as its workspace file
FN workspace_save_as
    PROLOGUE 16
    cmp qword ptr [rip + g_project], 0
    je 9f
    call trim
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r12, rax
    PATH_ABSOLUTE r12, 1f
    mov rdi, [rip + g_project]
    mov rsi, r12
    call path_join
    mov rdi, r12
    mov r12, rax
    call mem_free
1:  mov rdi, r12
    call ws_is_file
    test eax, eax
    jnz 2f
    lea rdi, [rip + ws_buf]
    call sb_clear
    lea rdi, [rip + ws_buf]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + ws_buf]
    lea rsi, [rip + .Lsuffix]
    call sb_push_cstr
    lea rdi, [rip + ws_buf]
    xor esi, esi
    call sb_push_byte
    mov rdi, r12
    call mem_free
    mov rdi, [rip + ws_buf + SB_ptr]
    call dup_cstr
    mov r12, rax
2:  # its folder: folders inside it are written relative to it
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call path_dirlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov r13, rax
    mov rdi, rax
    call strlen
    mov r14, rax
    lea rdi, [rip + ws_buf]
    call sb_clear
    lea rdi, [rip + ws_buf]
    lea rsi, [rip + .Lws_head]
    call sb_push_cstr
    xor ebx, ebx
3:  cmp rbx, [rip + ws_folders + VEC_len]
    jae 5f
    mov rdi, rbx
    call wfold_path
    mov r15, rax
    lea rdi, [rip + ws_buf]
    lea rsi, [rip + .Lws_path]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, r13
    call app_path_inside
    test eax, eax
    jz 4f
    mov rdi, r15
    call strlen
    cmp rax, r14
    jbe 31f
    lea rsi, [r15 + r14 + 1]    # inside: relative
    jmp 41f
31: lea rsi, [rip + .Ldot]      # the file's own folder
    jmp 41f
4:  mov rsi, r15
41: lea rdi, [rip + ws_buf]
    call sb_push_cstr
    lea rdi, [rip + ws_buf]
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 3b
5:  # the extensions' sections of the workspace file in use
    mov rdi, [rip + g_ws_file]
    test rdi, rdi
    jz 6f
    mov esi, 65536
    call vfs_read_limited
    test rax, rax
    jz 6f
    mov rdi, rax
    mov rsi, rdx
    push rax
    push rax
    call ws_copy_sections
    pop rdi
    pop rdi
    call mem_free
6:  mov rdi, r12
    mov rsi, [rip + ws_buf + SB_ptr]
    mov rdx, [rip + ws_buf + SB_len]
    call vfs_write_all
    test rax, rax
    js 7f
    mov rdi, [rip + g_ws_file]
    call mem_free
    mov [rip + g_ws_file], r12
    mov rdi, r13
    call mem_free
    call app_update_title
    EPILOGUE
7:  lea rdi, [rip + .Lt_write]
    call app_toast
    mov rdi, r12
    call mem_free
    mov rdi, r13
    call mem_free
9:  EPILOGUE

# ws_copy_sections(text, len): its lines of every section but [folders] onto ws_buf
ws_copy_sections:
    PROLOGUE
    mov r12, rdi
    lea r13, [rdi + rsi]
    xor r14d, r14d              # 1 inside a section that is copied
1:  cmp r12, r13
    jae 9f
    mov r15, r12
2:  cmp r15, r13
    jae 3f
    cmp byte ptr [r15], 10
    je 3f
    inc r15
    jmp 2b
3:  # [r12, r15) a line; a section's header may be indented (ini_next)
    mov rbx, r12
30: cmp rbx, r15
    jae 4f
    cmp byte ptr [rbx], ' '
    je 32f
    cmp byte ptr [rbx], 9
    jne 33f
32: inc rbx
    jmp 30b
33: cmp byte ptr [rbx], '['
    jne 4f
    mov rax, r15
    sub rax, rbx
    cmp rax, 9
    jb 31f
    mov rdi, rbx
    lea rsi, [rip + .Lsec_folders_line]
    mov rdx, 9
    call strncmp_eq
    xor r14d, r14d
    test eax, eax
    jnz 5f
31: mov r14d, 1
    lea rdi, [rip + ws_buf]
    mov esi, 10
    call sb_push_byte
4:  test r14d, r14d
    jz 5f
    lea rdi, [rip + ws_buf]
    mov rsi, r12
    mov rdx, r15
    sub rdx, r12
    call sb_push
    lea rdi, [rip + ws_buf]
    mov esi, 10
    call sb_push_byte
5:  lea r12, [r15 + 1]
    jmp 1b
9:  EPILOGUE

# FN cmd_save_workspace_as(): the palette asks for the workspace file's name
FN cmd_save_workspace_as
    PROLOGUE
    cmp qword ptr [rip + g_project], 0
    je 9f
    lea rdi, [rip + .Lask_save]
    mov esi, PROMPT_WS_SAVE
    lea rdx, [rip + .Ldefault_name]
    mov ecx, 24
    call palette_ext_prompt_open
9:  EPILOGUE

# FN c_workspace_save(out, args, len): workspace-save PATH
FN c_workspace_save
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call workspace_save_as
    xor eax, eax
    EPILOGUE

# ---------------- extensions ----------------

# FN workspace_ext_check(startup done): every frame (ext_tick): when the folders changed with the
# same primary folder, running extensions that read the project restart (a sandbox cannot widen
# after exec), the others that agreed workspace-folders hear "0 folders"; and idle extensions whose
# on = contains: patterns a folder has now start (once startup activation ran)
FN workspace_ext_check
    PROLOGUE
    mov r15d, edi
    mov eax, [rip + g_ws_gen]
    cmp eax, [rip + ws_gen_ext]
    je 5f
    mov [rip + ws_gen_ext], eax
    # the same primary? (a new one restarts everything: ext_project_check)
    mov rdi, [rip + g_project]
    mov rsi, [rip + ws_primary_seen]
    test rdi, rdi
    jz 1f
    test rsi, rsi
    jz 1f
    call strcmp_eq
    test eax, eax
    jnz 2f
1:  mov rdi, [rip + ws_primary_seen]
    call mem_free
    mov qword ptr [rip + ws_primary_seen], 0
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 5f
    call dup_cstr
    mov [rip + ws_primary_seen], rax
    jmp 5f
2:  xor r12d, r12d
3:  cmp r12, [rip + g_exts + VEC_len]
    jae 5f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    mov eax, [rbx + EXT_status]
    cmp eax, ES_RUNNING
    je 4f
    cmp eax, ES_STARTING
    jne 3b
4:  test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_READ | NEEDS_PROJECT_WRITE
    jz 41f
    mov dword ptr [rbx + EXT_restart], 1
    mov rdi, rbx
    lea rsi, [rip + .Lr_folders]
    call ext_stop
    jmp 3b
41: cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 3b
    mov rdi, rbx
    call extproto_send_folders
    jmp 3b
5:  # on = contains:
    test r15d, r15d
    jz 9f
    mov eax, [rip + g_ws_gen]
    cmp eax, [rip + ws_gen_contains]
    je 9f
    mov [rip + ws_gen_contains], eax
    xor r12d, r12d
6:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    test dword ptr [rbx + EXT_on], ON_CONTAINS
    jz 6b
    cmp dword ptr [rbx + EXT_status], ES_IDLE
    jne 6b
    mov rdi, rbx
    call ext_is_visible
    test eax, eax
    jz 6b
    mov rdi, rbx
    call extres_row
    test rax, rax
    jz 6b
    mov rdi, [rax + EL_contains]
    call ws_contains
    test eax, eax
    jz 6b
    mov rdi, rbx
    call ext_start
    jmp 6b
9:  EPILOGUE

# ws_contains(patterns cstr or 0) -> eax 1 when a folder has one of them: a name or a relative path
# (three levels at most) under it, or *.EXT at its top level
ws_contains:
    PROLOGUE 16
    mov r12, rdi
    test r12, r12
    jz 8f
1:  mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call next_word
    add r12, rcx
    test rdx, rdx
    jz 8f
    cmp rdx, 250
    ja 1b
    lea rdi, [rip + ws_name]
    mov rsi, rax
    mov rcx, rdx
    mov r13, rdx
    rep movsb
    mov byte ptr [rdi], 0
    xor r14d, r14d              # folder
2:  cmp r14, [rip + ws_folders + VEC_len]
    jae 1b
    mov rdi, r14
    inc r14
    call wfold_path
    mov r15, rax
    cmp word ptr [rip + ws_name], 0x2e2a   # "*."
    je 3f
    mov rdi, r15
    lea rsi, [rip + ws_name]
    call path_join
    mov rbx, rax
    mov rdi, rax
    call vfs_missing
    push rax
    push rax
    mov rdi, rbx
    call mem_free
    pop rax
    pop rax
    test eax, eax
    jz 9f
    jmp 2b
3:  # *.EXT: a name at the top level ending with .EXT
    mov dword ptr [rip + ws_found], 0
    mov rdi, r15
    lea rsi, [rip + ws_suffix_cb]
    xor edx, edx
    call vfs_dir_each
    cmp dword ptr [rip + ws_found], 0
    jne 9f
    jmp 2b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# ws_suffix_cb(ctx, name, is_dir): ws_found = 1 for a file whose name ends with ws_name after its *
ws_suffix_cb:
    PROLOGUE
    test edx, edx
    jnz 9f
    mov rbx, rsi
    mov rdi, rsi
    call strlen
    mov r12, rax
    lea rdi, [rip + ws_name + 1]
    call strlen
    cmp r12, rax
    jb 9f
    lea rdi, [rbx + r12]
    sub rdi, rax
    lea rsi, [rip + ws_name + 1]
    call strcmp_eq
    test eax, eax
    jz 9f
    mov dword ptr [rip + ws_found], 1
9:  EPILOGUE

# ---------------- commands ----------------

# FN cmd_add_workspace_folder(): the path browser picks a folder to add
FN cmd_add_workspace_folder
    mov edi, 2
    jmp browse_open_kind

# FN workspace_add_ui(path): Add Folder's pick: added, or a toast says why not
FN workspace_add_ui
    PROLOGUE
    mov rbx, rdi
    call workspace_add
    test rax, rax
    jns 9f
    lea rdi, [rip + .Lt_nested]
    cmp rax, -22
    je 1f
    lea rdi, [rip + .Lt_already]
    cmp rax, -17
    je 1f
    lea rdi, [rip + .Lt_full]
    cmp rax, -28
    je 1f
    lea rdi, [rip + .Lt_not_folder]
1:  call app_toast
9:  EPILOGUE

# FN cmd_remove_workspace_folder(): the active document's folder (or the explorer's selection's)
# leaves the workspace; the primary only when another folder can take its place
FN cmd_remove_workspace_folder
    PROLOGUE
    cmp qword ptr [rip + ws_folders + VEC_len], 2
    jb 8f
    call explorer_context_target    # the explorer's selection only from its menu or with its focus
    mov rdi, rax
    test rax, rax
    jnz 1f
    mov rax, [rip + g_doc]
    test rax, rax
    jz 8f
    mov rdi, [rax + DOC_path]
    test rdi, rdi
    jz 8f
1:  call wfold_of
    test rax, rax
    js 8f
    mov rdi, rax
    call wfold_id
    mov rdi, rax
    call workspace_remove
    EPILOGUE
8:  lea rdi, [rip + .Lt_no_remove]
    call app_toast
    EPILOGUE

# FN c_print_folders(out, args, len): print-folders: "folder=ID name=N path=P flags=F" a line
FN c_print_folders
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + ws_folders + VEC_len]
    jae 9f
    mov rdi, r12
    lea rsi, [rip + .Lp_folder]
    call sb_push_cstr
    mov rdi, rbx
    call wfold_id
    mov rdi, r12
    mov rsi, rax
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Lp_name]
    call sb_push_cstr
    mov rdi, rbx
    call wfold_name
    mov rdi, r12
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Lp_path]
    call sb_push_cstr
    mov rdi, rbx
    call wfold_path
    mov rdi, r12
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Lp_flags]
    call sb_push_cstr
    mov rdi, rbx
    call wfold_flags
    mov rdi, r12
    mov esi, eax
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 1b
9:  xor eax, eax
    EPILOGUE

# FN c_folder_add(out, args, len): folder-add PATH: "id=N", or "error=-E"
FN c_folder_add
    PROLOGUE 16
    mov r12, rdi
    mov rdi, rsi
    mov rsi, rdx
    call mem_dup
    mov rbx, rax
    mov rdi, rax
    call workspace_add
    mov r13, rax
    mov rdi, rbx
    call mem_free
    mov rdi, r12
    lea rsi, [rip + .Lp_id]
    test r13, r13
    jns 1f
    lea rsi, [rip + .Lp_error]
    neg r13
1:  call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

# FN c_folder_remove(out, args, len): folder-remove ID
FN c_folder_remove
    PROLOGUE
    mov r12, rdi
    mov rdi, rsi
    mov rsi, rdx
    call parse_u64
    mov rdi, rax
    call workspace_remove
    mov rdi, r12
    mov esi, eax
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

.data
ws_carrying: .long 0            # workspace_reset adds ws_carry's paths
ws_gen_ext: .long -1            # g_ws_gen as workspace_ext_check last saw it
ws_gen_contains: .long -1       # and as contains: activation last saw it
ws_found: .long 0
.p2align 3
ws_primary_seen: .quad 0
ws_carry_for: .quad 0           # the project the carried folders are for (owned)

.section .rodata
.Lext_folders: .asciz ".folders"
.Lsuffix: .asciz ".rhun-workspace"
.Lsec_folders: .asciz "folders"
.Lsec_folders_line: .asciz "[folders]"
.Lk_path: .asciz "path"
.Ldot: .asciz "."
.Lws_head: .asciz "# rhun workspace: its folders, and workspace settings for extensions ([owner/name] sections)\n[folders]\n"
.Lws_path: .asciz "path = "
.Lask_save: .asciz "Save the workspace as"
.Ldefault_name: .asciz "workspace.rhun-workspace"
.Lt_no_folder: .asciz "The workspace file names no folder that is there"
.Lt_write: .asciz "The workspace file could not be written"
.Lplus: .asciz " + "
.Lt_nested: .asciz "A workspace folder cannot be inside another one, or around it"
.Lt_already: .asciz "That folder is in the workspace already"
.Lt_full: .asciz "A workspace has 16 folders at most"
.Lt_not_folder: .asciz "Not a folder"
.Lt_no_remove: .asciz "Only a workspace of two folders or more has one to remove"
.Lr_folders: .asciz "restarting after the workspace folders changed"
.Lp_folder: .asciz "folder="
.Lp_name: .asciz " name="
.Lp_path: .asciz " path="
.Lp_flags: .asciz " flags="
.Lp_id: .asciz "id="
.Lp_error: .asciz "error="
