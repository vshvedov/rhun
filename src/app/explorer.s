# file explorer: lazily loaded tree of the project directory
.include "rhun.inc"

STRUCT
F N_name, 8
F N_path, 8
F N_parent, 8
F N_kids, VEC_SIZE
F N_dir, 4
F N_open, 4
F N_loaded, 4
F N_depth, 4
F N_icon, 4                      # its icon: icon | color slot << 8, or an iconth.s value; | 0x80000000
                                 # (| 0x10000000 a folder's while open); 0 until drawn
F N_igen, 4                      # iconth_gen when N_icon was looked up
ENDSTRUCT N_SIZE

.equ ID_EXP_ROW, 0x300000         # + row: a range of its own, as the tree has no end
.equ ID_EXP_SCROLL, 0x3f02
.equ ID_EXP_EMPTY, 0x3f04
.equ ID_MENU, 0x3f10

.bss
.p2align 3
root: .quad 0
rows: .zero VEC_SIZE            # visible NODE*
exp_scroll: .long 0             # px
exp_cursor: .long 0             # keyboard row
exp_rect: .zero 16
openset: .zero VEC_SIZE         # paths kept open across refresh (cstr*)
menu_open: .long 0
menu_x: .long 0
menu_y: .long 0
menu_press: .long 0             # the presses of the frame that opened the menu
.p2align 3
menu_list: .quad 0
menu_kidx: .long 0              # phase 3 task 10: the item the keys are on (ctx_menu_keys), -1: the mouse alone (set at each open)
root_multi: .long 0             # resources group: the root's children are the workspace folders
.globl g_explorer_dir, g_explorer_target, g_exp_reveal
g_exp_reveal: .long 0             # reveal the active file on the next draw
g_explorer_dir: .zero 4096
g_explorer_target: .zero 4096
g_menu_cmd: .long 0               # a context menu item is running
.globl g_menu_keys, g_menu_index
g_menu_keys: .long 0              # the open menu shows its commands' shortcuts
g_menu_index: .long 0             # the item that was clicked, while its handler runs
delete_label: .zero 256
delete_path: .zero 4096          # the path named by the open confirmation

.text

# explorer_dump(sb): print-explorer (remotectl.s): the rows shown, indented by depth, folders with a /
FN explorer_dump
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + rows + VEC_len]
    jae 9f
    mov rax, [rip + rows + VEC_ptr]
    mov r13, [rax + rbx*8]
    mov r14d, [r13 + N_depth]
2:  test r14d, r14d
    jle 3f
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    dec r14d
    jmp 2b
3:  mov rdi, r12
    mov rsi, [r13 + N_name]
    call sb_push_cstr
    cmp dword ptr [r13 + N_dir], 0
    je 4f
    mov rdi, r12
    mov esi, '/'
    call sb_push_byte
4:  mov rdi, r12
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 1b
9:  EPILOGUE

# explorer_excluded(name cstr) -> 1 if listed in cfg_exclude
FN explorer_excluded
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
    mov r13, [rip + cfg_exclude]
    mov rdi, r13
    call strlen
    mov r14, rax
1:  test r14, r14
    jz 3f
    mov rdi, r13
    mov rsi, r14
    call next_word
    add r13, rcx
    sub r14, rcx
    test rdx, rdx
    jz 3f
    mov rdi, rbx
    mov rsi, r12
    mov rcx, rdx
    mov rdx, rax
    call str_eq
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
3:  xor eax, eax
    EPILOGUE

# node_new(parent, name, path(owned), dir) -> NODE*
node_new:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    mov edi, N_SIZE
    call mem_alloc
    mov r15, rax
    mov [r15 + N_parent], rbx
    mov [r15 + N_path], r13
    mov [r15 + N_dir], r14d
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [r15 + N_name], rax
    test rbx, rbx
    jz 1f
    mov eax, [rbx + N_depth]
    inc eax
    mov [r15 + N_depth], eax
1:  mov rax, r15
    EPILOGUE

node_free:
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    xor r12d, r12d
1:  cmp r12, [rbx + N_kids + VEC_len]
    jae 2f
    mov rax, [rbx + N_kids + VEC_ptr]
    mov rdi, [rax + r12*8]
    call node_free
    inc r12
    jmp 1b
2:  lea rdi, [rbx + N_kids]
    call vec_free
    mov rdi, [rbx + N_name]
    call mem_free
    mov rdi, [rbx + N_path]
    call mem_free
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# dir entries callback: ctx = parent node
load_cb:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rdi, r12
    call explorer_excluded
    test eax, eax
    jnz 9f
    mov rdi, [rbx + N_path]
    mov rsi, r12
    call path_join
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    mov ecx, r13d
    call node_new
    mov r14, rax
    lea rdi, [rbx + N_kids]
    mov esi, 8
    call vec_push
    mov [rax], r14
9:  EPILOGUE

# node_less(a, b) -> 1 if a sorts before b (dirs first, case-insensitive)
node_less:
    mov eax, [rdi + N_dir]
    cmp eax, [rsi + N_dir]
    je 1f
    seta al
    movzx eax, al
    ret
1:  mov rdi, [rdi + N_name]
    mov rsi, [rsi + N_name]
2:  movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    lea edx, [rax - 'A']
    cmp edx, 25
    ja 3f
    or eax, 0x20
3:  lea edx, [rcx - 'A']
    cmp edx, 25
    ja 4f
    or ecx, 0x20
4:  cmp eax, ecx
    jne 5f
    test eax, eax
    jz 6f
    inc rdi
    inc rsi
    jmp 2b
5:  setb al
    movzx eax, al
    ret
6:  xor eax, eax
    ret

# node_load(node): read children once, sorted
node_load:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + N_loaded], 0
    jne 9f
    mov dword ptr [rbx + N_loaded], 1
    mov rdi, [rbx + N_path]
    lea rsi, [rip + load_cb]
    mov rdx, rbx
    call vfs_dir_each
    mov rdi, [rbx + N_kids + VEC_ptr]
    mov rsi, [rbx + N_kids + VEC_len]
    call sort_nodes
9:  EPILOGUE

# sort_nodes(array, n): node pointers in node_less order, stable (equal names keep the folder's
#   order), by bottom-up merge sort: a folder of 20,000 entries took most of a second sorted by
#   insertion, at startup and again on every refresh
sort_nodes:
    PROLOGUE 64
    mov r12, rdi
    mov r13, rsi
    cmp r13, 2
    jb 9f
    lea rdi, [r13*8]
    call mem_alloc
    mov r14, rax
    mov r15, r12                # runs of [rsp] merged from r15 into rbx, which the next pass reads
    mov rbx, r14
    mov qword ptr [rsp], 1
.Lsn_pass:
    mov rax, [rsp]
    cmp rax, r13
    jae .Lsn_done
    mov qword ptr [rsp + 8], 0
.Lsn_run:
    mov rax, [rsp + 8]          # lo
    cmp rax, r13
    jae .Lsn_swap
    mov rcx, rax                # mid = min(lo + width, n)
    add rcx, [rsp]
    cmp rcx, r13
    cmova rcx, r13
    mov [rsp + 16], rcx
    mov rdx, rcx                # hi = min(mid + width, n)
    add rdx, [rsp]
    cmp rdx, r13
    cmova rdx, r13
    mov [rsp + 24], rdx
    mov [rsp + 32], rax         # l
    mov [rsp + 40], rcx         # r
    mov [rsp + 48], rax         # k
.Lsn_merge:
    mov rax, [rsp + 48]
    cmp rax, [rsp + 24]
    jae .Lsn_next
    mov rcx, [rsp + 32]
    cmp rcx, [rsp + 16]
    jae .Lsn_right
    mov rdx, [rsp + 40]
    cmp rdx, [rsp + 24]
    jae .Lsn_left
    mov rdi, [r15 + rdx*8]      # the right run's only when it sorts before: ties keep their order
    mov rsi, [r15 + rcx*8]
    call node_less
    test eax, eax
    jz .Lsn_left
.Lsn_right:
    mov rdx, [rsp + 40]
    mov rax, [r15 + rdx*8]
    inc qword ptr [rsp + 40]
    jmp .Lsn_put
.Lsn_left:
    mov rcx, [rsp + 32]
    mov rax, [r15 + rcx*8]
    inc qword ptr [rsp + 32]
.Lsn_put:
    mov rcx, [rsp + 48]
    mov [rbx + rcx*8], rax
    inc qword ptr [rsp + 48]
    jmp .Lsn_merge
.Lsn_next:
    mov rax, [rsp + 24]
    mov [rsp + 8], rax
    jmp .Lsn_run
.Lsn_swap:
    xchg r15, rbx
    mov rax, [rsp]
    add rax, rax
    mov [rsp], rax
    jmp .Lsn_pass
.Lsn_done:
    cmp r15, r12
    je 1f
    mov rdi, r12
    mov rsi, r15
    lea rdx, [r13*8]
    call memcpy
1:  mov rdi, r14
    call mem_free
9:  EPILOGUE

# in_openset(path) -> 1 if it was open before a refresh
in_openset:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + openset + VEC_len]
    jae 2f
    mov rax, [rip + openset + VEC_ptr]
    mov rdi, [rax + r12*8]
    mov rsi, rbx
    call strcmp_eq
    test eax, eax
    jnz 3f
    inc r12
    jmp 1b
2:  xor eax, eax
3:  EPILOGUE

# rebuild_rows(): flatten open nodes
rebuild_rows:
    mov qword ptr [rip + rows + VEC_len], 0
    mov rdi, [rip + root]
    test rdi, rdi
    jz 1f
    jmp add_kids
1:  ret

add_kids:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + N_kids + VEC_len]
    jae 9f
    mov rax, [rbx + N_kids + VEC_ptr]
    mov r13, [rax + r12*8]
    lea rdi, [rip + rows]
    mov esi, 8
    call vec_push
    mov [rax], r13
    cmp dword ptr [r13 + N_open], 0
    je 2f
    mov rdi, r13
    call add_kids
2:  inc r12
    jmp 1b
9:  EPILOGUE

# open nodes recorded in openset are re-expanded after a reload
reopen:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + N_kids + VEC_len]
    jae 9f
    mov rax, [rbx + N_kids + VEC_ptr]
    mov r13, [rax + r12*8]
    cmp dword ptr [r13 + N_dir], 0
    je 2f
    mov rdi, [r13 + N_path]
    call in_openset
    test eax, eax
    jz 2f
    mov dword ptr [r13 + N_open], 1
    mov rdi, r13
    call node_load
    mov rdi, [r13 + N_path]
    call watch_dir
    mov rdi, r13
    call reopen
2:  inc r12
    jmp 1b
9:  EPILOGUE

# collect open dirs into openset
collect_open:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + N_kids + VEC_len]
    jae 9f
    mov rax, [rbx + N_kids + VEC_ptr]
    mov r13, [rax + r12*8]
    cmp dword ptr [r13 + N_open], 0
    je 2f
    mov rdi, [r13 + N_path]
    call strlen
    mov rdi, [r13 + N_path]
    mov rsi, rax
    call mem_dup
    mov r14, rax
    lea rdi, [rip + openset]
    mov esi, 8
    call vec_push
    mov [rax], r14
    mov rdi, r13
    call collect_open
2:  inc r12
    jmp 1b
9:  EPILOGUE

FN explorer_set_root
    PROLOGUE
    mov rdi, [rip + root]
    call node_free
    mov qword ptr [rip + root], 0
    mov dword ptr [rip + root_multi], 0
    mov dword ptr [rip + exp_scroll], 0
    mov dword ptr [rip + exp_cursor], 0
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 9f
    call wfold_count            # resources group: two workspace folders or more are roots of their own
    cmp eax, 2
    jae .Lsr_folders
    mov rdi, rsi
    call strlen
    mov rdi, [rip + g_project]
    mov rsi, rax
    call mem_dup
    mov rdx, rax
    xor edi, edi
    mov rsi, [rip + g_project_name]
    mov ecx, 1
    call node_new
    mov [rip + root], rax
    mov dword ptr [rax + N_depth], -1
    mov dword ptr [rax + N_open], 1
    mov rdi, rax
    call node_load
    mov rdi, [rip + g_project]
    call watch_dir
    call rebuild_rows
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE
.Lsr_folders:
    # a root that is no folder: each workspace folder a row of its own (open), its tree under it
    mov dword ptr [rip + root_multi], 1
    lea rdi, [rip + .Lempty_name]
    call dup_cstr
    mov rdx, rax
    xor edi, edi
    lea rsi, [rip + .Lempty_name]
    mov ecx, 1
    call node_new
    mov [rip + root], rax
    mov rbx, rax
    mov dword ptr [rbx + N_depth], -1
    mov dword ptr [rbx + N_open], 1
    mov dword ptr [rbx + N_loaded], 1
    xor r12d, r12d
1:  call wfold_count
    cmp r12, rax
    jae 2f
    mov rdi, r12
    call wfold_path
    mov rdi, rax
    call dup_cstr
    mov r13, rax
    mov rdi, r12
    call wfold_name
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r13
    mov ecx, 1
    call node_new
    mov r14, rax
    mov dword ptr [r14 + N_open], 1
    lea rdi, [rbx + N_kids]
    mov esi, 8
    call vec_push
    mov [rax], r14
    mov rdi, r14
    call node_load
    mov rdi, [r14 + N_path]
    call watch_dir
    inc r12
    jmp 1b
2:  call rebuild_rows
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# explorer_refresh(): reload the tree, keep expanded folders
FN explorer_refresh
    PROLOGUE
    call filelist_touch         # (phase 4 task 7) rhun's file list is made again at the next mention
    mov rbx, [rip + root]
    test rbx, rbx
    jz 9f
    cmp dword ptr [rip + root_multi], 0
    jne .Lrf_folders
    # remember open dirs
    xor r12d, r12d
1:  cmp r12, [rip + openset + VEC_len]
    jae 2f
    mov rax, [rip + openset + VEC_ptr]
    mov rdi, [rax + r12*8]
    call mem_free
    inc r12
    jmp 1b
2:  mov qword ptr [rip + openset + VEC_len], 0
    mov rdi, rbx
    call collect_open
    # reload root children
    xor r12d, r12d
3:  cmp r12, [rbx + N_kids + VEC_len]
    jae 4f
    mov rax, [rbx + N_kids + VEC_ptr]
    mov rdi, [rax + r12*8]
    call node_free
    inc r12
    jmp 3b
4:  mov qword ptr [rbx + N_kids + VEC_len], 0
    mov dword ptr [rbx + N_loaded], 0
    mov rdi, rbx
    call node_load
    mov rdi, rbx
    call reopen
    call rebuild_rows
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE
.Lrf_folders:
    # workspace folders: each folder's tree is read again, its open folders kept open
    call rf_openset
    xor r12d, r12d
1:  cmp r12, [rbx + N_kids + VEC_len]
    jae 2f
    mov rax, [rbx + N_kids + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    mov rdi, r13
    call rf_reload
    jmp 1b
2:  call rebuild_rows
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# rf_openset(): openset = the open folders of the tree (rbx the root)
rf_openset:
    PROLOGUE
    mov r13, rbx
    xor r12d, r12d
1:  cmp r12, [rip + openset + VEC_len]
    jae 2f
    mov rax, [rip + openset + VEC_ptr]
    mov rdi, [rax + r12*8]
    call mem_free
    inc r12
    jmp 1b
2:  mov qword ptr [rip + openset + VEC_len], 0
    mov rdi, r13
    call collect_open
    EPILOGUE

# rf_reload(node): a folder's children read again, the open ones in openset opened again
rf_reload:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + N_kids + VEC_len]
    jae 2f
    mov rax, [rbx + N_kids + VEC_ptr]
    mov rdi, [rax + r12*8]
    call node_free
    inc r12
    jmp 1b
2:  mov qword ptr [rbx + N_kids + VEC_len], 0
    mov dword ptr [rbx + N_loaded], 0
    mov rdi, rbx
    call node_load
    mov rdi, rbx
    call reopen
    EPILOGUE

# toggle(node)
toggle:
    push rbx
    mov rbx, rdi
    xor dword ptr [rbx + N_open], 1
    cmp dword ptr [rbx + N_open], 0
    je 1f
    call node_load
    mov rdi, [rbx + N_path]
    call watch_dir
1:  call rebuild_rows
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# select_target(node): remember path and containing dir for file commands
select_target:
    push rbx
    mov rbx, rdi
    lea rdi, [rip + g_explorer_target]
    mov rsi, [rbx + N_path]
    call cstr_copy
    lea rdi, [rip + g_explorer_dir]
    mov rsi, [rbx + N_path]
    cmp dword ptr [rbx + N_dir], 0
    jne 1f
    mov rax, [rbx + N_parent]
    test rax, rax
    jz 1f
    mov rsi, [rax + N_path]
1:  call cstr_copy
    pop rbx
    ret

# activate(node): open file / toggle dir
activate:
    push rbx
    mov rbx, rdi
    call select_target
    cmp dword ptr [rbx + N_dir], 0
    je 1f
    mov rdi, rbx
    call toggle
    pop rbx
    ret
1:  mov rdi, [rbx + N_path]
    call app_open_file
    pop rbx
    ret

# row_node(i) -> NODE* or 0
row_node:
    cmp rdi, [rip + rows + VEC_len]
    jae 1f
    mov rax, [rip + rows + VEC_ptr]
    mov rax, [rax + rdi*8]
    ret
1:  xor eax, eax
    ret

FN cmd_focus_explorer
    mov dword ptr [rip + cfg_sidebar], 1
    mov dword ptr [rip + g_focus], FOCUS_EXPLORER
    mov edi, 1
    jmp app_reveal_panel

FN cmd_new_folder
    lea rdi, [rip + .Lnew_folder]
    mov esi, PROMPT_NEW_FOLDER
    jmp prompt_open

FN cmd_rename_file
    # in a document with a rename provider, F2 renames the symbol under the cursor (langfeat.s)
    push rbx
    call langfeat_rename_start
    pop rbx
    test eax, eax
    jz 0f
    ret
0:  call file_target
    test eax, eax
    jz 1f
    lea rdi, [rip + .Lrename]
    mov esi, PROMPT_RENAME
    jmp prompt_open
1:  ret

FN cmd_delete_file
    push rbx
    call file_target
    test eax, eax
    jz 1f
    lea rdi, [rip + delete_path]
    lea rsi, [rip + g_explorer_target]
    call cstr_copy
    # "Delete NAME?"
    lea rdi, [rip + g_explorer_target]
    call strlen
    lea rdi, [rip + g_explorer_target]
    mov rsi, rax
    call path_basename
    mov rbx, rax
    cmp rdx, 200
    jbe 2f
    mov edx, 200
2:  lea rdi, [rip + delete_label]
    lea rsi, [rip + .Ldelete_a]
    call cstr_copy
    mov rdi, rax
    mov rsi, rbx
    mov rcx, rdx
    rep movsb
    lea rsi, [rip + .Ldelete_b]
    call cstr_copy
    lea rdi, [rip + delete_label]
    lea rsi, [rip + .Ldelete_text]
    lea rdx, [rip + .Lm4]
    lea rcx, [rip + explorer_delete_target]
    pop rbx
    jmp app_confirm
1:  pop rbx
    ret

# file_target() -> 1 with g_explorer_target set to the file a rename or delete is for: the explorer's
# item when its menu or the explorer itself has the command, otherwise the open file
file_target:
    cmp dword ptr [rip + g_menu_cmd], 0
    jne 1f
    cmp dword ptr [rip + g_focus], FOCUS_EXPLORER
    je 1f
    mov rax, [rip + g_file]
    test rax, rax
    jz 1f
    mov rsi, [rax + DOC_path]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + g_explorer_target]
    call cstr_copy
1:  xor eax, eax
    cmp byte ptr [rip + g_explorer_target], 0
    setne al
    ret

# FN explorer_context_target() -> rax g_explorer_target when a command runs from the explorer (its
#   menu, or with its focus) and something is selected, else 0 (the active file is the target)
FN explorer_context_target
    xor eax, eax
    cmp byte ptr [rip + g_explorer_target], 0
    je 9f
    cmp dword ptr [rip + g_menu_cmd], 0
    jne 1f
    cmp dword ptr [rip + g_focus], FOCUS_EXPLORER
    jne 9f
1:  lea rax, [rip + g_explorer_target]
9:  ret

# explorer_delete_target(): remove the confirmed file or directory and its contents
FN explorer_delete_target
    push rbx
    mov edi, WK_DELETE          # wsedit: a workspace edit of its own, undoable
    lea rsi, [rip + delete_path]
    xor edx, edx
    call ws_user_op
    test eax, eax
    js 2f
    jz 3f
    mov byte ptr [rip + g_explorer_target], 0
3:  mov byte ptr [rip + delete_path], 0
    pop rbx
    ret
2:  lea rdi, [rip + delete_path]
    call vfs_remove_tree
    mov rbx, rax
    # A failed deletion can still have removed some children.
    call explorer_refresh
    call close_deleted_tabs
    test rbx, rbx
    jns 1f
    lea rdi, [rip + .Lnot_deleted]
    call app_toast
    pop rbx
    ret
1:  mov byte ptr [rip + g_explorer_target], 0
    mov byte ptr [rip + delete_path], 0
    pop rbx
    ret

# close_deleted_tabs(): the tabs of what a deletion removed close, as in VS Code; one with unsaved
#   changes stays open, and so does one whose file is still there or may be (a deletion that failed
#   part way, a folder that cannot be searched)
close_deleted_tabs:
    PROLOGUE
    mov rbx, [rip + g_tabs + VEC_len]
1:  test rbx, rbx
    jz 9f
    dec rbx
    mov rdi, rbx
    call tab_at
    mov r12, [rax + TAB_doc]
    test r12, r12
    jz 1b
    mov rdi, [r12 + DOC_path]
    test rdi, rdi
    jz 1b
    lea rsi, [rip + delete_path]
    call app_path_inside
    test eax, eax
    jz 1b
    mov rdi, r12
    call doc_dirty
    test eax, eax
    jnz 1b
    mov rdi, [r12 + DOC_path]
    call vfs_missing
    test eax, eax
    jz 1b
    mov rdi, rbx
    call app_close_tab_now
    mov dword ptr [rip + g_dirty], 1
    jmp 1b
9:  EPILOGUE

# explorer_key(keysym, cp, mods) -> 1 if handled
FN explorer_key
    PROLOGUE
    mov r12d, edi
    test edx, MOD_CTRL | MOD_ALT
    jnz .Lek_no
    mov ebx, [rip + exp_cursor]
    cmp r12d, KEY_ESCAPE
    jne 1f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    jmp .Lek_yes
1:  cmp r12d, KEY_UP
    jne 2f
    test ebx, ebx
    jz .Lek_yes
    dec dword ptr [rip + exp_cursor]
    jmp .Lek_sel
2:  cmp r12d, KEY_DOWN
    jne 3f
    lea eax, [rbx + 1]
    cmp rax, [rip + rows + VEC_len]
    jae .Lek_yes
    mov [rip + exp_cursor], eax
    jmp .Lek_sel
3:  mov edi, ebx
    call row_node
    test rax, rax
    jz .Lek_no
    mov r13, rax
    cmp r12d, KEY_RETURN
    jne 4f
    mov rdi, r13
    call activate
    cmp dword ptr [r13 + N_dir], 0
    jne .Lek_yes
    mov dword ptr [rip + g_focus], FOCUS_EXPLORER
    jmp .Lek_yes
4:  cmp r12d, KEY_RIGHT
    jne 5f
    cmp dword ptr [r13 + N_dir], 0
    je .Lek_yes
    cmp dword ptr [r13 + N_open], 0
    jne .Lek_down
    mov rdi, r13
    call toggle
    jmp .Lek_yes
.Lek_down:
    inc dword ptr [rip + exp_cursor]
    jmp .Lek_sel
5:  cmp r12d, KEY_LEFT
    jne 6f
    cmp dword ptr [r13 + N_dir], 0
    je 51f
    cmp dword ptr [r13 + N_open], 0
    je 51f
    mov rdi, r13
    call toggle
    jmp .Lek_yes
51: # go to parent row
    mov rax, [r13 + N_parent]
    cmp rax, [rip + root]
    je .Lek_yes
    xor ecx, ecx
52: cmp rcx, [rip + rows + VEC_len]
    jae .Lek_yes
    mov rdx, [rip + rows + VEC_ptr]
    cmp [rdx + rcx*8], rax
    je 53f
    inc rcx
    jmp 52b
53: mov [rip + exp_cursor], ecx
    jmp .Lek_sel
6:  cmp r12d, KEY_DELETE
    jne 7f
    mov rdi, r13
    call select_target
    call cmd_delete_file
    jmp .Lek_yes
7:  jmp .Lek_no
.Lek_sel:
    mov edi, [rip + exp_cursor]
    call row_node
    mov rdi, rax
    call select_target
    call reveal_cursor
.Lek_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lek_no:
    xor eax, eax
    EPILOGUE

# explorer_reveal(): open the folders down to the active file and put the cursor on it
explorer_reveal:
    PROLOGUE
    mov rbx, [rip + root]
    test rbx, rbx
    jz 9f
    mov rax, [rip + g_file]
    test rax, rax
    jz 9f
    mov r12, [rax + DOC_path]
    test r12, r12
    jz 9f
    # workspace folders: from the folder holding it (the root has no folder of its own)
    cmp dword ptr [rip + root_multi], 0
    je 10f
    xor r14d, r14d
11: cmp r14, [rbx + N_kids + VEC_len]
    jae 9f
    mov rax, [rbx + N_kids + VEC_ptr]
    mov r15, [rax + r14*8]
    inc r14
    mov rdi, r12
    mov rsi, [r15 + N_path]
    call app_path_inside
    test eax, eax
    jz 11b
    mov rbx, r15
    cmp dword ptr [rbx + N_open], 0
    jne 10f
    mov dword ptr [rbx + N_open], 1
    mov rdi, rbx
    call node_load
10: # only files under the project
    mov rdi, [rbx + N_path]
    xor ecx, ecx
1:  movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz 2f
    cmp al, [r12 + rcx]
    jne 9f
    inc rcx
    jmp 1b
2:  cmp byte ptr [r12 + rcx], '/'
    jne 9f
    lea r12, [r12 + rcx + 1]
.Lrv_comp:
    xor r13d, r13d
3:  movzx eax, byte ptr [r12 + r13]
    test eax, eax
    jz 4f
    cmp eax, '/'
    je 4f
    inc r13
    jmp 3b
4:  test r13, r13
    jz 9f
    mov rdi, rbx
    call node_load
    xor r14d, r14d
5:  cmp r14, [rbx + N_kids + VEC_len]
    jae 9f
    mov rax, [rbx + N_kids + VEC_ptr]
    mov r15, [rax + r14*8]
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r15 + N_name]
    call str_eq_cstr
    test eax, eax
    jnz 6f
    inc r14
    jmp 5b
6:  cmp byte ptr [r12 + r13], 0
    je 7f
    cmp dword ptr [r15 + N_open], 0
    jne 61f
    mov dword ptr [r15 + N_open], 1
    mov rdi, r15
    call node_load
    mov rdi, [r15 + N_path]
    call watch_dir
61: mov rbx, r15
    lea r12, [r12 + r13 + 1]
    jmp .Lrv_comp
7:  call rebuild_rows
    xor ecx, ecx
8:  cmp rcx, [rip + rows + VEC_len]
    jae 9f
    mov rax, [rip + rows + VEC_ptr]
    cmp [rax + rcx*8], r15
    je 81f
    inc rcx
    jmp 8b
81: mov [rip + exp_cursor], ecx
    call reveal_cursor
9:  EPILOGUE

reveal_cursor:
    M ecx, MI_ROW
    mov eax, [rip + exp_cursor]
    imul eax, ecx
    cmp eax, [rip + exp_scroll]
    jge 1f
    mov [rip + exp_scroll], eax
    ret
1:  add eax, ecx
    mov edx, [rip + exp_rect + 12]     # the list's height
    sub eax, edx
    cmp eax, [rip + exp_scroll]
    jle 2f
    mov [rip + exp_scroll], eax
2:  ret

# explorer_draw(x, y, w, h): the sidebar with the explorer alone: its title and buttons, the tree
#   under them
FN explorer_draw
    PROLOGUE 16
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
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    M ecx, MI_40
    lea r8, [rip + .Lheader]
    COLOR r9d, T_MUTED
    call ui_text_c
    xor edi, edi
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 4]
    M ecx, MI_40
    call explorer_actions
    xor edi, edi
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_40]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    sub r8d, [rip + g_mt + 4*MI_40]
    call explorer_body_draw
    call gfx_clip_pop
    EPILOGUE

# explorer_actions(ctx, right, y, h) -> eax the x left of them: the header's buttons (New File, New
#   Folder, Refresh) ending at right, centered in [y, y + h): the explorer's own header and its
#   section's in a sidebar of several (places.s)
FN explorer_actions
    PROLOGUE 32
    mov [rsp], esi
    mov [rsp + 4], edx
    mov r15d, ecx
    M r12d, MI_28
    mov esi, [rsp]
    sub esi, r12d
    mov [rsp + 16], esi
    mov edi, ID_EXP_REFRESH
    mov edx, r15d
    sub edx, r12d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_REFRESH
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_EXP_REFRESH
    mov esi, [rsp + 16]
    mov edx, [rsp + 4]
    add edx, r15d
    mov ecx, r12d
    call tip_note               # keeps the button flags in eax
    test eax, UB_CLICK
    jz 1f
    call explorer_refresh
1:  mov esi, [rsp + 16]
    sub esi, r12d
    mov edi, ID_EXP_NEW_FOLDER
    mov edx, r15d
    sub edx, r12d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_FOLDER_PLUS
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_EXP_NEW_FOLDER
    mov esi, [rsp + 16]
    sub esi, r12d
    mov edx, [rsp + 4]
    add edx, r15d
    mov ecx, r12d
    call tip_note               # keeps the button flags in eax
    test eax, UB_CLICK
    jz 11f
    call cmd_new_folder
11: mov esi, [rsp + 16]
    sub esi, r12d
    sub esi, r12d
    mov edi, ID_EXP_NEW
    mov edx, r15d
    sub edx, r12d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_FILE_PLUS
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_EXP_NEW
    mov esi, [rsp + 16]
    sub esi, r12d
    sub esi, r12d
    mov edx, [rsp + 4]
    add edx, r15d
    mov ecx, r12d
    call tip_note               # keeps the button flags in eax
    test eax, UB_CLICK
    jz 2f
    call cmd_new_file_prompt
2:  mov eax, [rsp + 16]
    sub eax, r12d
    sub eax, r12d
    EPILOGUE

# explorer_body_draw(ctx, x, y, w, h): the tree of the project's files (or "No folder open") in the
#   rectangle, with its scrollbar; its context menus
FN explorer_body_draw
    PROLOGUE 64
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov [rip + exp_rect], esi
    mov [rip + exp_rect + 4], edx
    mov [rip + exp_rect + 8], ecx
    mov [rip + exp_rect + 12], r8d
    cmp dword ptr [rip + g_exp_reveal], 0
    je 1f
    mov dword ptr [rip + g_exp_reveal], 0
    call explorer_reveal
1:  cmp qword ptr [rip + root], 0
    jne 3f
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    M ecx, MI_24
    lea r8, [rip + .Lno_folder]
    COLOR r9d, T_MUTED
    call ui_text_c
    jmp .Lxd_ret
3:  # list area
    mov eax, [rsp + 4]
    mov [rsp + 20], eax         # list y
    mov eax, [rsp + 12]
    mov [rsp + 24], eax         # list h
    mov edi, [rsp]
    mov esi, [rsp + 20]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 24]
    call gfx_clip_push
    mov edi, [rsp]
    mov esi, [rsp + 20]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 24]
    call ui_in
    test eax, eax
    jz 4f
    mov eax, [rip + g_scroll_y]
    add [rip + exp_scroll], eax
4:  # clamp scroll
    M ebx, MI_ROW
    mov rax, [rip + rows + VEC_len]
    imul eax, ebx
    add eax, [rip + g_mt + 4*MI_16]
    sub eax, [rsp + 24]
    jns 41f
    xor eax, eax
41: cmp [rip + exp_scroll], eax
    jle 42f
    mov [rip + exp_scroll], eax
42: cmp dword ptr [rip + exp_scroll], 0
    jge 43f
    mov dword ptr [rip + exp_scroll], 0
43: # first row
    mov eax, [rip + exp_scroll]
    xor edx, edx
    div ebx
    mov r12d, eax               # row index
    imul eax, ebx
    mov ecx, [rsp + 20]
    sub ecx, [rip + exp_scroll]
    add ecx, eax
    mov r13d, ecx               # row y
.Lxd_row:
    mov edi, r12d
    call row_node
    test rax, rax
    jz .Lxd_rows_done
    mov r14, rax
    mov eax, [rsp + 20]
    add eax, [rsp + 24]
    cmp r13d, eax
    jge .Lxd_rows_done
    # interaction
    lea edi, [r12 + ID_EXP_ROW]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 8]
    mov r8d, ebx
    call ui_btn
    mov [rsp + 28], eax
    test eax, UB_PRESS
    jz 5f
    mov rdi, [r14 + N_path]     # phase 4 task 5: a press may begin a drag of its path (drop.s)
    call strlen
    mov rdi, [r14 + N_path]
    lea rsi, [rax + 1]
    call drag_paths_begin
    mov [rip + exp_cursor], r12d
    mov dword ptr [rip + g_focus], FOCUS_EXPLORER
    mov rdi, r14
    call activate
    cmp dword ptr [r14 + N_dir], 0
    jne 5f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
5:  test dword ptr [rsp + 28], UB_RPRESS
    jz 51f
    mov [rip + exp_cursor], r12d
    mov rdi, r14
    call select_target
    # files with changes: "Open Changes" too
    call agctx_chat_on          # phase 4 task 8: "Add to Chat" with the chat on (agentctx.s)
    lea rcx, [rip + menu_items]
    lea rdx, [rip + menu_items_chat]
    test eax, eax
    cmovnz rcx, rdx
    push rax
    push rcx
    cmp dword ptr [rip + root_multi], 0  # resources group: a workspace folder's own row
    je 49f
    cmp dword ptr [r14 + N_depth], 0
    jne 49f
    lea rcx, [rip + menu_items_folder]
    lea rdx, [rip + menu_items_folder_chat]
    cmp dword ptr [rsp + 8], 0
    cmovnz rcx, rdx
    mov [rsp], rcx
    jmp 50f
49: cmp dword ptr [r14 + N_dir], 0
    jne 50f
    mov rdi, [r14 + N_path]
    call git_status_of
    test eax, eax
    jz 50f
    lea rcx, [rip + menu_items_git]
    lea rdx, [rip + menu_items_git_chat]
    cmp dword ptr [rsp + 8], 0
    cmovnz rcx, rdx
    mov [rsp], rcx
50: pop rdi
    pop rax
    mov rsi, [r14 + N_path]
    mov edx, [r14 + N_dir]
    call menu_open_explorer     # with the extensions' items (menu.s)
51: # background: active document, keyboard cursor, hover
    M eax, MI_6
    mov edi, [rsp]
    add edi, eax
    mov esi, r13d
    mov edx, [rsp + 8]
    sub edx, eax
    sub edx, eax
    mov ecx, ebx
    M r8d, MI_RADIUS
    mov rax, [rip + g_file]
    test rax, rax
    jz 52f
    mov rax, [rax + DOC_path]
    test rax, rax
    jz 52f
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push r8
    mov rdi, rax
    mov rsi, [r14 + N_path]
    call strcmp_eq
    pop r8
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    test eax, eax
    jz 52f
    COLOR r9d, T_ACTIVE
    call gfx_round_rect
    jmp 54f
52: test dword ptr [rsp + 28], UB_HOVER
    jz 53f
    COLOR r9d, T_HOVER
    call gfx_round_rect
    jmp 54f
53: cmp dword ptr [rip + g_focus], FOCUS_EXPLORER
    jne 54f
    cmp r12d, [rip + exp_cursor]
    jne 54f
    COLOR r9d, T_ACCENT
    COLOR eax, T_PANEL
    push rax
    push rax
    call gfx_frame
    add rsp, 16
54: # indent + chevron + icon + name
    mov eax, [r14 + N_depth]
    imul eax, [rip + g_mt + 4*MI_12]
    add eax, [rsp]
    add eax, [rip + g_mt + 4*MI_8]
    mov r15d, eax
    M ecx, MI_16
    cmp dword ptr [r14 + N_dir], 0
    je 55f
    mov edi, IC_CHEV_R
    cmp dword ptr [r14 + N_open], 0
    je 551f
    mov edi, IC_CHEV_D
551:mov esi, r15d
    mov edx, ebx
    sub edx, ecx
    sar edx, 1
    add edx, r13d
    mov r8d, ecx
    shr ecx, 0
    mov ecx, r8d
    COLOR r8d, T_MUTED
    call icon_draw
55: add r15d, [rip + g_mt + 4*MI_16]
    add r15d, [rip + g_mt + 4*MI_2]
    # its icon: the file icon theme's, else rhun's (iconth.s); looked up once per theme and state
    call iconth_gen
    mov edx, eax
    mov eax, [r14 + N_icon]
    cmp edx, [r14 + N_igen]
    jne 50f
    test eax, eax
    jz 50f
    cmp dword ptr [r14 + N_dir], 0
    je 56f
    mov ecx, eax
    shr ecx, 28
    and ecx, 1
    cmp ecx, [r14 + N_open]
    je 56f
50: mov [r14 + N_igen], edx
    cmp dword ptr [r14 + N_dir], 0
    je 51f
    mov rdi, [r14 + N_name]
    mov esi, [r14 + N_open]
    call iconth_folder
    cmp eax, ITV_RHUN
    jne 52f
    mov eax, IC_FOLDER | (T_ACCENT << 8)
    jmp 52f
51: mov rdi, [r14 + N_name]
    call iconth_file
    cmp eax, ITV_RHUN
    jne 52f
    mov rdi, [r14 + N_name]
    call file_icon
    shl edx, 8
    or eax, edx
52: or eax, 0x80000000
    cmp dword ptr [r14 + N_dir], 0
    je 53f
    cmp dword ptr [r14 + N_open], 0
    je 53f
    or eax, 0x10000000
53: mov [r14 + N_icon], eax
56: M ecx, MI_16
    mov esi, r15d
    mov edx, ebx
    sub edx, ecx
    sar edx, 1
    add edx, r13d
    test eax, ITV_NONE
    jnz 59f
    test eax, ITV_IMAGE
    jz 57f
    mov [rsp + 52], esi
    mov [rsp + 56], edx
    mov edi, eax
    call iconth_draw
    test eax, eax
    jnz 59f
    # a picture that cannot be shown: rhun's icon
    mov eax, IC_FOLDER | (T_ACCENT << 8)
    cmp dword ptr [r14 + N_dir], 0
    jne 571f
    mov rdi, [r14 + N_name]
    call file_icon
    shl edx, 8
    or eax, edx
571:M ecx, MI_16
    mov esi, [rsp + 52]
    mov edx, [rsp + 56]
57: mov edi, eax
    and edi, 0xff
    shr eax, 8
    and eax, 0xff
    lea r8, [rip + g_theme]
    mov r8d, [r8 + rax*4]
    call icon_draw
59:
    add r15d, [rip + g_mt + 4*MI_20]
    add r15d, [rip + g_mt + 4*MI_2]
    # git (or another version control system's provider, scmpanel.s): name in the status color,
    # the letter at the right for files
    mov rdi, [r14 + N_path]
    call vcs_status_of
    mov [rsp + 32], eax
    mov [rsp + 36], edx
    mov [rsp + 40], ecx
    test eax, eax
    jnz 58f
    COLOR eax, T_PANEL_FG
    mov [rsp + 40], eax
58:
    mov rdi, [r14 + N_name]
    call strlen
    mov r9, rax
    lea rdi, [rip + g_face_ui]
    mov esi, r15d
    mov edx, r13d
    mov ecx, ebx
    mov r8, [r14 + N_name]
    # names cut with an ellipsis before the status letter
    mov r10d, [rsp]
    add r10d, [rsp + 8]
    sub r10d, [rip + g_mt + 4*MI_28]
    sub r10d, r15d
    mov eax, [rsp + 40]
    push r10
    push rax
    call ui_text_v_fit
    add rsp, 16
    cmp dword ptr [rsp + 32], 0
    je 59f
    cmp dword ptr [r14 + N_dir], 0
    jne 59f
    mov eax, [rsp + 32]
    mov [rsp + 44], eax         # letter, zero-terminated
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rip + g_mt + 4*MI_24]
    mov edx, r13d
    mov ecx, ebx
    lea r8, [rsp + 44]
    mov r9d, [rsp + 40]
    call ui_text_c
59:
    add r13d, ebx
    inc r12d
    jmp .Lxd_row
.Lxd_rows_done:
    # the empty space below the rows: the project folder's menu, without Rename and Delete
    mov edi, ID_EXP_EMPTY
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 20]
    add r8d, [rsp + 24]
    sub r8d, r13d
    call ui_btn
    test eax, UB_RPRESS
    jz 1f
    call root_menu_open
1:  call gfx_clip_pop
    # scrollbar
    mov rax, [rip + rows + VEC_len]
    movsxd rcx, ebx
    imul rax, rcx               # 64 bits before the i32 content cap
    movsxd rcx, dword ptr [rip + g_mt + 4*MI_16]
    add rax, rcx
    mov ecx, 0x7fffffff
    cmp rax, rcx
    cmovg rax, rcx
    mov ecx, [rsp + 24]
    push rcx
    push rax
    mov edi, ID_EXP_SCROLL
    mov esi, [rsp + 16]
    add esi, [rsp + 16 + 8]
    M eax, MI_12
    sub esi, eax
    mov edx, [rsp + 16 + 20]
    mov ecx, eax
    mov r8d, [rsp + 16 + 24]
    lea r9, [rip + exp_scroll]
    call ui_scrollbar
    add rsp, 16
.Lxd_ret:
    EPILOGUE

FN cmd_new_file_prompt
    lea rdi, [rip + .Lnew_file]
    mov esi, PROMPT_NEW_FILE
    jmp prompt_open

# root_menu_open(): the menu of the project folder itself. New files and folders go in it; the rename
# and delete target is left alone, so a later Rename or Delete never takes the whole project.
root_menu_open:
    PROLOGUE
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 9f
    lea rdi, [rip + g_explorer_dir]
    call cstr_copy
    lea rdi, [rip + menu_items_root]
    call menu_open_root         # with the extensions' items (menu.s)
9:  EPILOGUE

# explorer_menu_draw(): context menu overlay. An item without a handler is a separating line; with
# g_menu_keys set the items show their commands' shortcuts on the right.
FN explorer_menu_draw
    PROLOGUE 48
    cmp dword ptr [rip + menu_open], 0
    je .Lmd_ret
    M ebx, MI_32                # item h
    mov r15, [rip + menu_list]
    # size: the widest item, the items' heights
    mov edi, 200
    call sc
    mov r12d, eax               # w
    M r14d, MI_12               # h
    xor r13d, r13d
.Lmd_size:
    mov eax, r13d
    shl eax, 4
    cmp qword ptr [r15 + rax], 0
    je .Lmd_sized
    cmp qword ptr [r15 + rax + 8], 0
    jne 1f
    add r14d, [rip + g_mt + 4*MI_8]
    inc r13d
    jmp .Lmd_size
1:  add r14d, ebx
    mov edi, r13d
    call item_width
    add eax, [rip + g_mt + 4*MI_32]
    cmp eax, r12d
    cmovg r12d, eax
    inc r13d
    jmp .Lmd_size
.Lmd_sized:
    mov eax, [rip + g_cv + CV_w]
    sub eax, [rip + g_mt + 4*MI_16]
    cmp r12d, eax
    cmovg r12d, eax
    mov eax, [rip + menu_x]
    mov ecx, [rip + g_cv + CV_w]
    sub ecx, r12d
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp], eax
    mov eax, [rip + menu_y]
    mov ecx, [rip + g_cv + CV_h]
    sub ecx, r14d
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 4], eax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, r12d
    mov ecx, r14d
    call ui_card
    # click outside closes (after this frame's clicks were handled), but not the press that opened
    # the menu: a right press, or a tap whose release opened it in the same frame
    test dword ptr [rip + g_pressed], (1 << BTN_LEFT) | (1 << BTN_RIGHT)
    jz 3f
    cmp dword ptr [rip + menu_press], 0
    jne 3f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, r12d
    mov ecx, r14d
    call ui_in
    test eax, eax
    jnz 3f
    mov dword ptr [rip + menu_open], 0
    mov dword ptr [rip + g_dirty], 1    # a frame without it
    jmp .Lmd_ret
3:  mov eax, [rsp + 4]
    add eax, [rip + g_mt + 4*MI_6]
    mov [rsp + 8], eax          # item y
    xor ecx, ecx
    mov [rsp + 12], ecx         # item index
    mov dword ptr [rsp + 32], -1    # the item clicked in this frame
.Lmd_item:
    mov ecx, [rsp + 12]
    shl ecx, 4
    cmp qword ptr [r15 + rcx], 0
    je .Lmd_done
    cmp qword ptr [r15 + rcx + 8], 0
    jne 31f
    # a line across the middle
    M esi, MI_8
    shr esi, 1
    add esi, [rsp + 8]
    mov edi, [rsp]
    add edi, [rip + g_mt + 4*MI_12]
    mov edx, r12d
    sub edx, [rip + g_mt + 4*MI_24]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    mov eax, [rip + g_mt + 4*MI_8]
    add [rsp + 8], eax
    inc dword ptr [rsp + 12]
    jmp .Lmd_item
31: mov edi, [rsp + 12]
    add edi, ID_MENU
    M eax, MI_6
    mov esi, [rsp]
    add esi, eax
    mov edx, [rsp + 8]
    mov ecx, r12d
    sub ecx, eax
    sub ecx, eax
    mov r8d, ebx
    call ui_btn
    mov [rsp + 16], eax
    test eax, UB_HOVER
    jnz 32f
    mov eax, [rsp + 12]         # (task 10: or the item the keys are on)
    cmp eax, [rip + menu_kidx]
    jne 4f
32: M eax, MI_6
    mov edi, [rsp]
    add edi, eax
    mov esi, [rsp + 8]
    mov edx, r12d
    sub edx, eax
    sub edx, eax
    mov ecx, ebx
    M r8d, MI_RADIUS
    COLOR r9d, T_ACTIVE
    call gfx_round_rect
4:  # the shortcut, right-aligned
    mov dword ptr [rsp + 20], 0 # its width and a gap
    mov edi, [rsp + 12]
    call item_keys
    test rax, rax
    jz 41f
    mov [rsp + 24], rax
    mov rdi, rax
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, [rsp + 24]
    mov rdx, rax
    call text_width
    mov [rsp + 20], eax
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, r12d
    sub esi, [rip + g_mt + 4*MI_16]
    sub esi, eax
    mov edx, [rsp + 8]
    mov ecx, ebx
    mov r8, [rsp + 24]
    COLOR r9d, T_MUTED
    call ui_text_c
    mov eax, [rip + g_mt + 4*MI_16]
    add [rsp + 20], eax
41: # the label, clipped before the shortcut
    mov edi, [rsp]
    add edi, [rip + g_mt + 4*MI_16]
    mov esi, [rsp + 8]
    mov edx, r12d
    sub edx, [rip + g_mt + 4*MI_32]
    sub edx, [rsp + 20]
    mov ecx, ebx
    call gfx_clip_push
    mov ecx, [rsp + 12]
    shl ecx, 4
    mov r8, [r15 + rcx]
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 8]
    mov ecx, ebx
    COLOR r9d, T_FG
    call ui_text_c
    call gfx_clip_pop
    test dword ptr [rsp + 16], UB_CLICK
    jz 5f
    mov ecx, [rsp + 12]
    mov [rsp + 32], ecx
5:  add [rsp + 8], ebx
    inc dword ptr [rsp + 12]
    jmp .Lmd_item
.Lmd_done:
    # A clicked item's command runs once the whole menu is drawn (this frame is shown whole, not cut
    # after that item), and the next frame, without the menu, follows at once.
    mov ecx, [rsp + 32]
    test ecx, ecx
    js .Lmd_ret
    mov dword ptr [rip + menu_open], 0
    mov dword ptr [rip + g_dirty], 1
    mov [rip + g_menu_index], ecx
    shl ecx, 4
    mov rax, [r15 + rcx + 8]
    mov dword ptr [rip + g_menu_cmd], 1
    call rax
    mov dword ptr [rip + g_menu_cmd], 0
.Lmd_ret:
    mov dword ptr [rip + menu_press], 0
    EPILOGUE

# item_width(i) -> width of the menu item's label, with its shortcut and the gap before it
item_width:
    PROLOGUE
    mov r12d, edi
    mov rax, [rip + menu_list]
    mov ecx, r12d
    shl ecx, 4
    mov rbx, [rax + rcx]
    mov rdi, rbx
    call strlen
    lea rdi, [rip + g_face_ui]
    mov rsi, rbx
    mov rdx, rax
    call text_width
    mov r13d, eax
    mov edi, r12d
    call item_keys
    test rax, rax
    jz 1f
    mov rbx, rax
    mov rdi, rax
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, rbx
    mov rdx, rax
    call text_width
    add r13d, eax
    add r13d, [rip + g_mt + 4*MI_32]
1:  mov eax, r13d
    EPILOGUE

# item_keys(i) -> the shortcut of the command the menu item runs (with g_menu_keys), or 0
item_keys:
    push rdi
    call menu_row_cmd           # an extension's item: its command's shortcut (menu.s)
    pop rdi
    test rax, rax
    jz 2f
    mov rdi, rax
    jmp keys_for
2:  xor eax, eax
    cmp dword ptr [rip + g_menu_keys], 0
    je 1f
    mov rax, [rip + menu_list]
    shl edi, 4
    mov rdi, [rax + rdi + 8]
    call cmd_for_fn
    test rax, rax
    jz 1f
    mov rdi, rax
    jmp keys_for
1:  ret

# open_changes(): diff of the file the menu is for
open_changes:
    push rbx
    lea rdi, [rip + g_explorer_target]
    call git_rel
    test rax, rax
    jz 1f
    xor edi, edi
    mov rsi, rax
    call git_open_diff
1:  pop rbx
    ret

cmd_copy_path:
    lea rdi, [rip + g_explorer_target]
    push rdi
    call strlen
    pop rdi
    mov rsi, rax
    xor edx, edx
    call ed_clip_set
    jmp editor_clip_result

copy_project_path:
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 1f
    push rdi
    call strlen
    pop rdi
    mov rsi, rax
    xor edx, edx
    call ed_clip_set
    jmp editor_clip_result
1:  ret

reveal_project:
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 1f
    jmp desktop_reveal
1:  ret

FN cmd_reveal_file
    push rbx
    call file_target
    test eax, eax
    jz 1f
    lea rdi, [rip + g_explorer_target]
    call desktop_reveal
1:  pop rbx
    ret

FN explorer_menu_open
    mov eax, [rip + menu_open]
    ret

# ctx_menu_open(items, x, y): items are (label, handler) pairs ending with 0
FN ctx_menu_open
    mov [rip + menu_list], rdi
    mov [rip + menu_x], esi
    mov [rip + menu_y], edx
    mov eax, [rip + g_pressed]
    and eax, (1 << BTN_LEFT) | (1 << BTN_RIGHT)
    mov [rip + menu_press], eax
    mov dword ptr [rip + menu_open], 1
    mov dword ptr [rip + g_menu_keys], 0
    mov dword ptr [rip + menu_kidx], -1
    mov dword ptr [rip + g_dirty], 1
    ret

# FN ctx_menu_keys(): the open menu takes the keys (task 10: one opened by Shift+F10 or the Menu key): its first
#   item is the keys', Up and Down move, Home and End, Enter or Space runs it (ctx_menu_key), Escape closes
FN ctx_menu_keys
    cmp dword ptr [rip + menu_open], 0
    je 9f
    mov dword ptr [rip + menu_kidx], -1
    mov edi, 1
    jmp menu_step
9:  ret

# FN ctx_menu_key(keysym) -> eax 1 taken: an open menu that takes the keys (ctx_menu_keys): Up, Down, Home, End
#   move among its items (lines are passed over), Enter, the keypad's Enter and Space run the item
FN ctx_menu_key
    xor eax, eax
    cmp dword ptr [rip + menu_open], 0
    je 9f
    cmp dword ptr [rip + menu_kidx], 0
    jl 9f
    cmp edi, KEY_DOWN
    jne 1f
    mov edi, 1
    jmp menu_step
1:  cmp edi, KEY_UP
    jne 2f
    mov edi, -1
    jmp menu_step
2:  cmp edi, KEY_HOME
    jne 3f
    mov dword ptr [rip + menu_kidx], -1
    mov edi, 1
    jmp menu_step
3:  cmp edi, KEY_END
    jne 4f
    mov dword ptr [rip + menu_kidx], 0x7fff
    mov edi, -1
    jmp menu_step
4:  cmp edi, KEY_RETURN
    je 5f
    cmp edi, KEY_KP_ENTER
    je 5f
    cmp edi, ' '
    jne 9f
5:  push rbx
    mov ecx, [rip + menu_kidx]
    mov rbx, [rip + menu_list]
    mov dword ptr [rip + menu_open], 0
    mov dword ptr [rip + g_dirty], 1
    mov [rip + g_menu_index], ecx
    shl ecx, 4
    mov rax, [rbx + rcx + 8]
    test rax, rax
    jz 6f
    mov dword ptr [rip + g_menu_cmd], 1
    call rax
    mov dword ptr [rip + g_menu_cmd], 0
6:  pop rbx
    mov eax, 1
9:  ret

# menu_step(dir 1 or -1) -> eax 1: the keys' item moves to the next item with a handler that way (from before
#   the first, or after the last, when it is on none); at an end it stays
menu_step:
    mov rdx, [rip + menu_list]
    xor ecx, ecx                # the items
1:  mov eax, ecx
    shl eax, 4
    cmp qword ptr [rdx + rax], 0
    je 2f
    inc ecx
    jmp 1b
2:  mov eax, [rip + menu_kidx]
    test eax, eax
    js 3f
    cmp eax, ecx
    jl 4f
3:  mov eax, -1                 # on none: from an end
    test edi, edi
    jg 4f
    mov eax, ecx
4:  add eax, edi
    js 8f
    cmp eax, ecx
    jge 8f
    mov r9d, eax
    shl r9d, 4
    cmp qword ptr [rdx + r9 + 8], 0
    je 4b                       # a line
    mov [rip + menu_kidx], eax
    jmp 9f
8:  mov eax, [rip + menu_kidx]  # none further: it stays where it was, if that is an item
    cmp eax, ecx
    jl 9f
    mov dword ptr [rip + menu_kidx], -1
9:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    ret

FN ctx_menu_close
    mov dword ptr [rip + menu_open], 0
    mov dword ptr [rip + g_dirty], 1
    ret

# ctx_menu_list() -> the items of the open menu, or 0
FN ctx_menu_list
    xor eax, eax
    cmp dword ptr [rip + menu_open], 0
    je 1f
    mov rax, [rip + menu_list]
1:  ret

# menu_pick(ptr, len) -> 1 when the open menu has an item with that label: it runs, as a click on
# it would (tests)
FN menu_pick
    PROLOGUE
    mov r13, rdi
    mov r14, rsi
    cmp dword ptr [rip + menu_open], 0
    je 8f
    mov r12, [rip + menu_list]
    xor ebx, ebx
1:  mov rdx, [r12]
    test rdx, rdx
    jz 8f
    cmp qword ptr [r12 + 8], 0      # a line
    je 2f
    mov rdi, r13
    mov rsi, r14
    call str_eq_cstr
    test eax, eax
    jnz 3f
2:  add r12, 16
    inc ebx
    jmp 1b
3:  mov dword ptr [rip + menu_open], 0
    mov dword ptr [rip + g_dirty], 1
    mov [rip + g_menu_index], ebx
    mov dword ptr [rip + g_menu_cmd], 1
    call [r12 + 8]
    mov dword ptr [rip + g_menu_cmd], 0
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# menu_print(sb): the open menu's labels, a line each ("-" for a separating line; " *" after the item the keys
#   are on: ctx_menu_keys), or "none"
FN menu_print
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + menu_open], 0
    jne 1f
    lea rsi, [rip + .Lp_none]
    call sb_push_cstr
    EPILOGUE
1:  mov r12, [rip + menu_list]
    xor r14d, r14d
2:  mov r13, [r12]
    test r13, r13
    jz 9f
    cmp qword ptr [r12 + 8], 0
    jne 3f
    lea r13, [rip + .Lp_line]
3:  mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    mov edi, r14d               # an extension's row: " [OWNER/NAME]", a submenu " >" (menu.s)
    call menu_row_note
    test rax, rax
    jz 4f
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
4:  cmp r14d, [rip + menu_kidx] # task 10: the item the keys are on, " *"
    jne 41f
    mov rdi, rbx
    lea rsi, [rip + .Lp_keyed]
    call sb_push_cstr
41: mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add r12, 16
    inc r14d
    jmp 2b
9:  EPILOGUE

.section .rodata
.Lm_remove_folder: .asciz "Remove Folder from Workspace"
.Lp_keyed: .asciz " *"
.Lempty_name: .asciz ""
.Lheader: .asciz "EXPLORER"
.ifdef MACOS
.Lno_folder: .asciz "No folder open (\342\207\247\342\214\230O)"
.else
.Lno_folder: .asciz "No folder open (Ctrl+Shift+O)"
.endif
.Lnew_file: .asciz "New file"
.Lnew_folder: .asciz "New folder"
.Lrename: .asciz "Rename"
.Ldelete_a: .asciz "Delete "
.Ldelete_b: .asciz "?"
.Ldelete_text: .asciz "Undo Last Multi-File Edit brings it back until rhun quits."
.Lp_none: .asciz "none\n"
.Lp_line: .asciz "-"
.Lnot_deleted: .asciz "Could not delete. Check permissions and whether files are in use."
.Lm1: .asciz "New File"
.Lm2: .asciz "New Folder"
.Lm3: .asciz "Rename"
.Lm4: .asciz "Delete"
.Lm5: .asciz "Copy Path"
.Lm6: .asciz "Open Changes"
.Lm_chat: .asciz "Add to Chat"         # phase 4 task 8
.ifdef MACOS
.Lm_reveal: .asciz "Show in Finder"
.else
.ifdef WINDOWS
.Lm_reveal: .asciz "Show in Explorer"
.else
.Lm_reveal: .asciz "Open in File Manager"
.endif
.endif
.p2align 3
menu_items:
    .quad .Lm1, cmd_new_file_prompt, .Lm2, cmd_new_folder, .Lm3, cmd_rename_file
    .quad .Lm4, cmd_delete_file, .Lm5, cmd_copy_path, .Lm_reveal, cmd_reveal_file, 0, 0
menu_items_git:
    .quad .Lm6, open_changes, .Lm1, cmd_new_file_prompt, .Lm2, cmd_new_folder, .Lm3, cmd_rename_file
    .quad .Lm4, cmd_delete_file, .Lm5, cmd_copy_path, .Lm_reveal, cmd_reveal_file, 0, 0
menu_items_root:
    .quad .Lm1, cmd_new_file_prompt, .Lm2, cmd_new_folder, .Lm5, copy_project_path
    .quad .Lm_reveal, reveal_project, 0, 0
menu_items_folder:              # resources group: a workspace folder's row
    .quad .Lm1, cmd_new_file_prompt, .Lm2, cmd_new_folder, .Lm5, cmd_copy_path
    .quad .Lm_reveal, cmd_reveal_file, .Lm_remove_folder, cmd_remove_workspace_folder, 0, 0
# phase 4 task 8: with the chat on, "Add to Chat" first (agentctx.s); never on the project's root
menu_items_chat:
    .quad .Lm_chat, agctx_add_explorer
    .quad .Lm1, cmd_new_file_prompt, .Lm2, cmd_new_folder, .Lm3, cmd_rename_file
    .quad .Lm4, cmd_delete_file, .Lm5, cmd_copy_path, .Lm_reveal, cmd_reveal_file, 0, 0
menu_items_git_chat:
    .quad .Lm_chat, agctx_add_explorer
    .quad .Lm6, open_changes, .Lm1, cmd_new_file_prompt, .Lm2, cmd_new_folder, .Lm3, cmd_rename_file
    .quad .Lm4, cmd_delete_file, .Lm5, cmd_copy_path, .Lm_reveal, cmd_reveal_file, 0, 0
menu_items_folder_chat:
    .quad .Lm_chat, agctx_add_explorer
    .quad .Lm1, cmd_new_file_prompt, .Lm2, cmd_new_folder, .Lm5, cmd_copy_path
    .quad .Lm_reveal, cmd_reveal_file, .Lm_remove_folder, cmd_remove_workspace_folder, 0, 0
