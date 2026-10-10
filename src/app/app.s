# application shell: init, tabs, layout, chrome (titlebar, tabs, status bar), input routing
.include "rhun.inc"

.equ ID_TITLE, 0x2000
.equ ID_WMIN, 0x2001
.equ ID_WMAX, 0x2002
.equ ID_WCLOSE, 0x2003
.equ ID_TOG_SIDE, 0x2004
.equ ID_TOG_AGENTS, 0x2005
.equ ID_SETTINGS_BTN, 0x2006
.equ ID_TOG_TERM, 0x2007
.equ ID_GIT_BTN, 0x2008
.equ ID_PROJECT_BTN, 0x2009
.equ PM_RECENT, 3                 # the project menu's first recent folder
.equ ID_TAB, 0x2100              # + index
.equ ID_TABX, 0x2400             # + index
.equ ID_SPLIT_L, 0x2700
.equ ID_SPLIT_R, 0x2701
.equ ID_DLG, 0x2800              # + button
.equ ID_STATUS, 0x2900           # + item
.equ TIP_DELAY, 500              # ms of steady hover before a tooltip shows
.equ TIP_PENDING, 0
.equ TIP_SHOWN, 1
.equ TIP_GRACE, 400               # ms after a tooltip hides that the next one shows at once
.equ TIP_DISMISSED, 2
.equ TT_id, 0                    # tip_table entry: button, text, handler
.equ TT_text, 8
.equ TT_fn, 16
.equ TT_SIZE, 24
.equ TIP_TEXT_MAX, 4400          # bytes of a tip_note_text tooltip (a git command with a file's path)
.equ RHUN_LEN, 5                # bytes of "rhûn", the name on the welcome screen
.equ ID_WELCOME, 0x2a00          # + item

.bss
.p2align 3
.globl g_focus, g_win_focused, g_tabs, g_tab_cur, g_project, g_project_name, g_branch
g_focus: .long 0
g_tabs: .zero VEC_SIZE
g_project: .quad 0
# the project is the folder of a file opened without one: it is not remembered as the last project
# and its session is not saved, so the folder's own session stays as it was
.globl g_project_adopted, g_wait
g_project_adopted: .long 0
g_wait: .long 0                 # --wait: a program waits for the editor
.p2align 3
.globl g_start_paths
g_start_paths: .zero VEC_SIZE
restart_paths: .quad 0
g_project_name: .quad 0
g_branch: .zero 64
.globl g_toast, g_toast_until
g_toast: .zero 256
g_toast_until: .quad 0
tip_id: .long 0                  # button whose tooltip is pending or visible, 0 = none
tip_cand: .long 0                # button hovered in this frame, noted while drawing
tip_cx: .long 0                  # its x, the y its tooltip hangs from, and its width
tip_cy: .long 0
tip_cw: .long 0
tip_state: .long 0               # TIP_PENDING, TIP_SHOWN, or TIP_DISMISSED by a key press
scroll_rem: .long 0, 0           # what scroll sensitivity left of a pixel, x and y, in hundredths
.p2align 3
tip_since: .quad 0               # time_ms when the pointer reached tip_id
tip_left: .quad 0                # time_ms when the pointer left a shown tooltip
tip_text_id: .long 0             # the button whose tooltip is in tip_text (tip_note_text)
tip_text: .zero TIP_TEXT_MAX
g_tabscroll: .long 0
g_side_px: .long 0
g_agents_px: .long 0
dlg_kind: .long 0                # 0 none, 1 close tab, 2 quit, 3 open another project, 4 app_confirm, 5 close all
dlg_tab: .quad 0
.p2align 3
dlg_title: .quad 0               # app_confirm: the question, a line under it, the button, its function
dlg_text: .quad 0
dlg_ok: .quad 0
dlg_fn: .quad 0
dlg_cancel: .quad 0              # app_confirm's Cancel calls this when it is set
ro_doc: .quad 0                  # ask_readonly: the file asked about, and the question
ro_kind: .long 0                 # a close or quit that asked about it (dlg_kind), carried on after Overwrite
ro_close: .long 0                # vim's :wq asked: Overwrite closes the file too
ro_title: .zero 256
ro_path: .zero 4096              # Save As onto a read-only file: that path
ro_dir: .zero 4096
switch_pending: .long 0          # a project switch waits on unsaved files
switch_path: .zero 4096
nw_exe: .zero 4096               # app_new_window: this program
.p2align 3
pm_items: .zero 16 * 13         # the project menu: 2 commands, a line, 9 folders, the end
.globl g_shot_path
g_shot_path: .quad 0
tmp_sb: .zero SB_SIZE
split_drag: .long 0
split_l_bits: .long 0           # UB_* of the dividers, hit tested before the panels
split_r_bits: .long 0
.globl g_editor_rect
g_editor_rect: .zero 16
.globl g_title_inset
g_title_inset: .long 0           # title bar space the platform keeps (macOS window buttons)
.p2align 3
.globl g_file
g_file: .quad 0                  # DOC of the active tab when it shows a file (text or image)

.text

# ---------------- init ----------------

FN app_init
    PROLOGUE 16
    call config_load
    call app_sync_panels
    call theme_scan
    mov edi, 1
    call theme_settings_init
    call theme_apply_config
    call app_load_fonts
    call syntax_load_all
    call keys_init
    call vim_sync
    call explorer_init
    call agents_init
    call watch_init
    call update_init
    call ai_apply
    EPILOGUE

# app_load_fonts(): built-in fonts unless the config names .ttf files
FN app_load_fonts
    PROLOGUE
    lea rdi, [rip + font_mono]
    lea rsi, [rip + font_mono_end]
    sub rsi, rdi
    mov rdx, [rip + cfg_font]
    call load_font_or
    mov [rip + g_font_code], rax
    lea rdi, [rip + font_ui]
    lea rsi, [rip + font_ui_end]
    sub rsi, rdi
    mov rdx, [rip + cfg_ui_font]
    call load_font_or
    mov [rip + g_font_ui], rax
    EPILOGUE

# load_font_or(builtin ptr, len, path cstr) -> FONT*
load_font_or:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    cmp byte ptr [rdx], 0
    je 1f
    mov rdi, rdx
    call file_read_all
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call font_load
    test rax, rax
    jnz 2f
1:  mov rdi, r12
    mov rsi, r13
    call font_load
2:  EPILOGUE

# app_set_project(dir cstr): project root for explorer, agents and session
FN app_set_project
    mov dword ptr [rip + g_project_adopted], 0
    mov dword ptr [rip + panels_hidden], 0 # a folder opened as such shows its panels
set_project:
    PROLOGUE
    mov rbx, rdi
    call app_sync_panels
    mov rdi, [rip + g_project]
    call mem_free
    mov rdi, rbx
    call strlen
    # strip trailing slash, retaining the complete filesystem root
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
    jbe 1f
    cmp byte ptr [rbx + rax - 1], '/'
    jne 1f
    dec rax
1:  mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov [rip + g_project], rax
    mov rdi, rax
    call strlen
    mov rdi, [rip + g_project]
    mov rsi, rax
    call path_basename
    mov [rip + g_project_name], rax
    call git_set_project
    call explorer_set_root
    call agents_set_project
    call session_remember_project
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# app_new_window(folder): another rhun opens the folder in a window of its own (on macOS with a Dock
# icon of its own) and this one keeps its project. It runs this program with the same environment,
# in a session of its own as a copy started from a terminal is, and is reaped when it quits.
# RHUN_NEW_WINDOW names another program to run (tests); without it a headless rhun starts none.
FN app_new_window
.ifdef WINDOWS
    PROLOGUE
    cmp dword ptr [rip + g_headless], 0
    jne 8f
    call win_new_window
    test eax, eax
    jnz 9f
8:  lea rdi, [rip + .Lnew_window_failed]
    call app_toast
9:  EPILOGUE
.else
    PROLOGUE 32
    mov rbx, rdi
    lea rdi, [rip + .Lenv_new_window]
    call getenv
    test rax, rax
    jz 2f
    cmp byte ptr [rax], 0
    je 2f
    mov r12, rax
    mov rdi, rax
    call strlen
    cmp rax, 4096
    jae 8f
    lea rdi, [rip + nw_exe]
    mov rsi, r12
    call cstr_copy
    jmp 3f
2:  cmp dword ptr [rip + g_headless], 0
    jne 8f
.ifdef MACOS
    lea rdi, [rip + nw_exe]
    mov esi, 4096
    call mac_exe_path
    test rax, rax
    js 8f
.else
    lea rdi, [rip + .Lproc_self_exe]
    lea rsi, [rip + nw_exe]
    mov edx, 4095
    SYS SYS_readlink
    test rax, rax
    jle 8f
    lea rcx, [rip + nw_exe]
    mov byte ptr [rcx + rax], 0
    # " (deleted)": an update replaced the file, and the new version opens the folder
    mov r12, rax
    lea rdi, [rip + nw_exe]
    mov rsi, rax
    lea rdx, [rip + .Ldeleted]
    mov ecx, 10
    call str_ends
    test eax, eax
    jz 1f
    lea rcx, [rip + nw_exe]
    mov byte ptr [rcx + r12 - 10], 0
1:
.endif
3:  lea rdi, [rip + .Ldevnull]
    mov esi, O_RDWR | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 8f
    mov r12d, eax
    lea rax, [rip + nw_exe]
    mov [rsp], rax
    mov [rsp + 8], rbx
    mov qword ptr [rsp + 16], 0
    lea rdi, [rsp]
    mov rsi, [rip + g_envp]
    xor edx, edx
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, r12d
    push 1                      # a new session; the terminal ioctl on /dev/null fails, so none
    push 1
    call proc_spawn
    add rsp, 16
    mov r13, rax
    mov edi, r12d
    SYS SYS_close
    test r13, r13
    jle 8f
    mov edi, r13d
    call reap_later
    EPILOGUE
8:  lea rdi, [rip + .Lnew_window_failed]
    call app_toast
    EPILOGUE
.endif

# app_switch_project(path): this window takes up another folder. The project's open files are
# remembered, unsaved ones are asked about (Cancel keeps the project), then they are closed and the
# folder opens with its last session.
FN app_switch_project
    PROLOGUE
    mov rbx, rdi
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 1f
.ifdef WINDOWS
    call win_path_equal
.else
    call strcmp_eq
.endif
    test eax, eax
    jnz 8f
1:  mov rdi, rbx
    call strlen
    cmp rax, 4000
    ja 9f
    lea rdi, [rip + switch_path]
    mov rsi, rbx
    call cstr_copy
    # before the questions: an answer closes that file, and a quit meanwhile must not save again
    call session_save
    mov dword ptr [rip + g_session_final], 1
    mov dword ptr [rip + switch_pending], 1
    call switch_continue
    jmp 9f
8:  # the same folder: a file's folder becomes the project itself, its last session joining the tabs
    cmp dword ptr [rip + g_project_adopted], 0
    je 9f
    mov dword ptr [rip + g_project_adopted], 0
    mov dword ptr [rip + panels_hidden], 0
    call app_sync_panels
    call session_remember_project
    call session_restore
    call app_update_title
9:  EPILOGUE

# app_adopt_folder(file): a file opened in a window without a project brings in its folder as one,
# for the explorer, new files, git and the terminal (see g_project_adopted). Not with --wait: a
# program waiting for an editor (git's commit message) wants just the file.
app_adopt_folder:
    PROLOGUE
    cmp qword ptr [rip + g_project], 0
    jne 9f
    cmp dword ptr [rip + g_wait], 0
    jne 9f
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call path_dirlen
    test rax, rax
    jnz 1f
    mov eax, 1                  # "/"
1:  mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov r12, rax
    mov rdi, rax
    call file_is_dir
    test eax, eax
    jz 8f
    mov dword ptr [rip + g_project_adopted], 1
    mov rdi, r12
    call set_project
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# switch_continue(): the next unsaved file asks first; with none left the project changes
switch_continue:
    PROLOGUE
    cmp dword ptr [rip + switch_pending], 0
    je 9f
    mov edi, 3
    call ask_unsaved
    test eax, eax
    jnz 9f
    mov dword ptr [rip + switch_pending], 0
    call close_tabs_now
    call closed_clear           # the last project's tabs are not this one's to reopen
    mov byte ptr [rip + g_explorer_dir], 0
    mov byte ptr [rip + g_explorer_target], 0
    lea rdi, [rip + switch_path]
    call app_set_project
    # the new project saves its own session
    mov dword ptr [rip + g_session_final], 0
    call session_restore
    call app_update_title
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# project_menu_open(x, y): Open Folder, Open File and the recent folders, under the project name
project_menu_open:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    lea rbx, [rip + pm_items]
    lea rax, [rip + .Lpm_folder]
    mov [rbx], rax
    lea rax, [rip + cmd_open_folder]
    mov [rbx + 8], rax
    lea rax, [rip + .Lpm_file]
    mov [rbx + 16], rax
    lea rax, [rip + cmd_open_file]
    mov [rbx + 24], rax
    add rbx, 32
    call session_recent
    mov r14d, eax
    test r14d, r14d
    jz 2f
    # a line, then the folders
    lea rax, [rip + .Lpm_line]
    mov [rbx], rax
    mov qword ptr [rbx + 8], 0
    add rbx, 16
    xor r15d, r15d
1:  cmp r15d, r14d
    jae 2f
    mov eax, r15d
    shl eax, 12
    lea rcx, [rip + g_recent_label]
    add rcx, rax
    mov [rbx], rcx
    lea rax, [rip + recent_open]
    mov [rbx + 8], rax
    add rbx, 16
    inc r15d
    jmp 1b
2:  mov qword ptr [rbx], 0
    mov qword ptr [rbx + 8], 0
    lea rdi, [rip + pm_items]
    mov esi, r12d
    mov edx, r13d
    call ctx_menu_open
    mov dword ptr [rip + g_menu_keys], 1
    EPILOGUE

# recent_open(): the recent folder picked in the project menu (the items after the line): this window
# takes it up, or with Shift held another window opens it
recent_open:
    mov eax, [rip + g_menu_index]
    sub eax, PM_RECENT
    js 1f
    shl eax, 12
    lea rdi, [rip + g_recent_path]
    add rdi, rax
    test dword ptr [rip + g_mods], MOD_SHIFT
    jnz app_new_window
    jmp app_switch_project
1:  ret

# ---------------- tabs ----------------

# app_restart_paths(executable) -> allocated argv. Project sessions reopen by folder;
# standalone windows keep their normal file tabs across an update restart.
FN app_restart_paths
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + g_restart], 0
    je 8f
    mov r12, [rip + restart_paths]
    test r12, r12
    jz 8f
    xor r13d, r13d
5:  inc r13
    cmp qword ptr [r12 + r13*8], 0
    jne 5b
    lea rdi, [r13*8 + 8]
    call mem_alloc
    mov r14, rax
    mov rdi, rax
    mov rsi, r12
    lea rdx, [r13*8 + 8]
    call memcpy
    mov [r14], rbx
    mov rax, r14
    EPILOGUE
8:
    mov rdi, [rip + g_tabs + VEC_len]
    add rdi, 3
    shl rdi, 3
    call mem_alloc
    mov r14, rax
    mov [r14], rbx
    mov r13d, 1
    mov rax, [rip + g_project]
    test rax, rax
    jz 1f
    cmp dword ptr [rip + g_project_adopted], 0
    jne 1f                      # a file's folder comes back with the file
    mov [r14 + r13*8], rax
    inc r13
    jmp 4f
1:  xor r12d, r12d
2:  cmp r12, [rip + g_tabs + VEC_len]
    jae 4f
    mov rdi, r12
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    je 21f
    cmp qword ptr [rax + TAB_kind], TAB_IMAGE
    jne 3f
21:
    mov rax, [rax + TAB_doc]
    mov rax, [rax + DOC_path]
    test rax, rax
    jz 3f
    mov [r14 + r13*8], rax
    inc r13
3:  inc r12
    jmp 2b
4:  cmp r13d, 1
    jne 41f
    lea rax, [rip + .Lrestart_empty]
    mov [r14 + r13*8], rax
    inc r13
41: mov qword ptr [r14 + r13*8], 0
    mov rax, r14
    EPILOGUE

# Snapshot before quit confirmations close dirty tabs. Owned path copies survive
# those closes; cancelling and requesting another restart replaces the snapshot.
FN app_remember_restart
    PROLOGUE
    mov r12, [rip + restart_paths]
    test r12, r12
    jz 3f
    mov r13d, 1
1:  mov rdi, [r12 + r13*8]
    test rdi, rdi
    jz 2f
    call mem_free
    inc r13
    jmp 1b
2:  mov rdi, r12
    call mem_free
3:  mov qword ptr [rip + restart_paths], 0
    lea rdi, [rip + .Lrhun]
    call app_restart_paths
    mov r12, rax
    mov r13d, 1
4:  mov rbx, [r12 + r13*8]
    test rbx, rbx
    jz 5f
    mov rdi, rbx
    call strlen
    lea rsi, [rax + 1]
    mov rdi, rbx
    call mem_dup
    mov [r12 + r13*8], rax
    inc r13
    jmp 4b
5:  mov [rip + restart_paths], r12
    EPILOGUE

# tab_at(i) -> TAB*
FN tab_at
    imul rax, rdi, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    ret

# app_sync_doc(): g_doc and g_file from the active tab
FN app_sync_doc
    mov qword ptr [rip + g_doc], 0
    mov qword ptr [rip + g_file], 0
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 1f
    call tab_at
    mov rcx, [rax + TAB_kind]
    cmp qword ptr [rax + TAB_doc], 0
    je 1f
    mov rdx, [rax + TAB_doc]
    mov [rip + g_file], rdx
    cmp rcx, TAB_DOC
    jne 2f
    mov [rip + g_doc], rdx
1:  # the view's copies of an image are only kept while it is shown
    call iv_cache_free
2:  mov dword ptr [rip + g_dirty], 1
    ret

# app_image() -> the active image view, or 0
FN app_image
    xor eax, eax
    mov rcx, [rip + g_file]
    test rcx, rcx
    jz 1f
    mov rax, [rcx + DOC_img]
1:  ret

FN app_activate_tab
    push rdi
    call vim_leave
    pop rdi
    mov [rip + g_tab_cur], rdi
    mov dword ptr [rip + g_exp_reveal], 1
    call app_sync_doc
    call watch_show
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov dword ptr [rip + g_tabscroll_reveal], 1
    call ed_touch
    jmp app_update_title

# app_update_title(): window title "name — project"
FN app_update_title
    PROLOGUE
    lea rdi, [rip + tmp_sb]
    call sb_clear
    mov rbx, [rip + g_file]
    test rbx, rbx
    jz 1f
    lea rdi, [rip + tmp_sb]
    mov rsi, [rbx + DOC_name]
    call sb_push_cstr
    lea rdi, [rip + tmp_sb]
    lea rsi, [rip + .Ldash]
    call sb_push_cstr
1:  mov rsi, [rip + g_project_name]
    test rsi, rsi
    jnz 2f
    lea rsi, [rip + .Lrhun]
2:  lea rdi, [rip + tmp_sb]
    call sb_push_cstr
    mov rdi, [rip + tmp_sb + SB_ptr]
    PCALL P_title
    EPILOGUE

# app_find_tab(path) -> index or -1
FN app_find_tab
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 3f
    mov rdi, rbx
    call tab_at
    mov rax, [rax + TAB_doc]
    test rax, rax
    jz 2f
    mov rdi, [rax + DOC_path]
    test rdi, rdi
    jz 2f
    mov rsi, r12
.ifdef WINDOWS
    call win_path_equal
.else
    call strcmp_eq
.endif
    test eax, eax
    jnz 4f
2:  inc rbx
    jmp 1b
3:  mov rax, -1
    EPILOGUE
4:  mov rax, rbx
    EPILOGUE

# app_open_startup_path(path): initial desktop events follow argv startup precedence.
FN app_open_startup_path
    # Finder delivers its initial URLs during AppKit startup. Queue them with argv so
    # the same project/session precedence applies; later events open ordinary tabs.
    cmp dword ptr [rip + g_started], 0
    jne app_open_path
    PROLOGUE
    mov rbx, rdi
    call strlen
    lea rsi, [rax + 1]
    mov rdi, rbx
    call mem_dup
    mov rbx, rax
    lea rdi, [rip + g_start_paths]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    EPILOGUE
# app_open_file(path) -> tab index or -1
FN app_open_file
    PROLOGUE 16
    mov r12, rdi
    call app_find_tab
    test rax, rax
    js 1f
    mov rdi, rax
    mov rbx, rax
    call app_activate_tab
    mov rax, rbx
    EPILOGUE
1:  # regular files only: opening a pipe or a device blocks until the other end comes (a missing
    # file can still be created)
    mov rdi, r12
    call file_type
    test eax, eax
    jz 12f
    cmp eax, 0x8000
    je 12f
    lea rdi, [rip + .Lnot_regular]
    call app_toast
    mov rax, -1
    EPILOGUE
12: mov r14d, TAB_DOC
    call doc_new
    mov rbx, rax
    # images open in an image tab, decoded when first shown
    mov rdi, r12
    call image_probe
    test eax, eax
    jz 11f
    mov r14d, TAB_IMAGE
    mov rdi, rbx
    mov rsi, r12
    call doc_set_path
    mov rdi, r12
    call file_stamp
    mov [rbx + DOC_mtime], rax
    call iv_new
    mov [rbx + DOC_img], rax
    jmp 3f
11: mov rdi, rbx
    mov rsi, r12
    call doc_load
    cmp rax, -1000
    je .Lof_binary
    cmp rax, -2                # a missing file can be created; other read errors cannot
    je 2f
    test rax, rax
    jns 2f
    lea r15, [rip + .Lopen_failed]
    jmp .Lof_failed
.Lof_binary:
    lea r15, [rip + .Lbinary]
.Lof_failed:
    mov rdi, rbx
    call doc_free
    mov rdi, r15
    call app_toast
    mov rax, -1
    EPILOGUE
2:  mov rdi, rbx
    call app_detect_lang
    mov rdi, rbx
    call git_doc_opened
    # replace an untouched untitled tab
    mov rax, [rip + g_tab_cur]
    test rax, rax
    js 3f
    mov rdi, rax
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 3f
    mov rcx, [rax + TAB_doc]
    cmp qword ptr [rcx + DOC_path], 0
    jne 3f
    mov rdi, rcx
    push rax
    push rcx
    call doc_len
    pop rcx
    pop rdx
    test rax, rax
    jnz 3f
    mov [rdx + TAB_doc], rbx
    mov [rdx + TAB_kind], r14
    mov rdi, rcx
    call doc_free
    mov rdi, [rip + g_tab_cur]
    mov r13, rdi
    call app_activate_tab
    mov rax, r13
    EPILOGUE
3:  mov rdi, rbx
    mov esi, r14d
    call app_add_tab
    EPILOGUE

# app_add_tab(doc, kind) -> index (inserted after the current tab, activated)
FN app_add_tab
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [rip + g_tabs]
    mov esi, TAB_SIZE
    call vec_push
    mov r13, [rip + g_tabs + VEC_len]
    dec r13                     # new slot index
    mov r14, [rip + g_tab_cur]
    inc r14                     # insert position
    # shift [r14, r13) right by one
    mov rcx, r13
1:  cmp rcx, r14
    jbe 2f
    mov rdi, rcx
    call tab_at
    mov rdx, [rax - TAB_SIZE + TAB_kind]
    mov [rax + TAB_kind], rdx
    mov rdx, [rax - TAB_SIZE + TAB_doc]
    mov [rax + TAB_doc], rdx
    dec rcx
    jmp 1b
2:  mov rdi, r14
    call tab_at
    mov [rax + TAB_kind], r12
    mov [rax + TAB_doc], rbx
    mov rdi, r14
    call app_activate_tab
    mov rax, r14
    EPILOGUE

# app_place_tab(i): the active tab moves to place i in the strip (the last place at most), the tabs
#   between closing up behind it
FN app_place_tab
    PROLOGUE
    mov r12, [rip + g_tab_cur]
    test r12, r12
    js 9f
    mov r13, [rip + g_tabs + VEC_len]
    dec r13
    cmp rdi, r13
    cmovb r13, rdi
    mov rdi, r12
    call tab_at
    mov r14, [rax + TAB_kind]
    mov r15, [rax + TAB_doc]
1:  cmp r12, r13
    je 3f
    mov rdi, r12
    call tab_at
    # the neighbor toward the new place moves into this slot
    mov rcx, TAB_SIZE
    mov rdx, 1
    cmp r12, r13
    jb 2f
    neg rcx
    neg rdx
2:  add r12, rdx
    lea rdx, [rax + rcx]
    mov rsi, [rdx + TAB_kind]
    mov [rax + TAB_kind], rsi
    mov rsi, [rdx + TAB_doc]
    mov [rax + TAB_doc], rsi
    jmp 1b
3:  mov rdi, r13
    call tab_at
    mov [rax + TAB_kind], r14
    mov [rax + TAB_doc], r15
    mov [rip + g_tab_cur], r13
    mov dword ptr [rip + g_tabscroll_reveal], 1
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# app_tab_label(i) -> cstr: the name the tab strip shows
FN app_tab_label
    call tab_at
    mov rcx, rax
    mov rax, [rcx + TAB_doc]
    test rax, rax
    jz 1f
    mov rax, [rax + DOC_name]
    ret
1:  lea rax, [rip + .Lsettings]
    cmp qword ptr [rcx + TAB_kind], TAB_GIT
    jne 2f
    lea rax, [rip + .Lgit_tab]
2:  ret

# app_detect_lang(doc)
FN app_detect_lang
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    xor esi, esi
    call doc_line_text
    mov r12, rax
    mov r13, rdx
    mov rdi, [rbx + DOC_path]
    test rdi, rdi
    jnz 1f
    lea rdi, [rip + .Lempty]
1:  mov rsi, r12
    mov rdx, r13
    call syntax_detect
    mov [rbx + DOC_lang], rax
    mov qword ptr [rbx + DOC_svalid], 0
    EPILOGUE

# app_new_file()
FN cmd_new_file
    call doc_new
    mov rdi, rax
    mov esi, TAB_DOC
    jmp app_add_tab

# app_close_tab_now(i): close without asking
FN app_close_tab_now
    PROLOGUE
    mov r12, rdi
    cmp r12, [rip + g_tab_cur]
    jne .Lclose_note
    call vim_leave              # out of visual mode, as leaving the tab is
.Lclose_note:
    mov rdi, r12
    call closed_note            # for Reopen Closed Tab
    mov rdi, r12
    call tab_at
    xor r13d, r13d
    cmp r12, [rip + g_tab_cur]
    jne .Lclose_focus_saved
    cmp qword ptr [rax + TAB_kind], TAB_SETTINGS
    jne .Lclose_focus_saved
    cmp dword ptr [rip + g_focus], FOCUS_SETTINGS
    jne .Lclose_focus_saved
    mov r13d, 1
.Lclose_focus_saved:
    mov rbx, [rax + TAB_doc]
    test rbx, rbx
    jz 1f
    mov rdi, rbx
    call vim_forget
    mov rdi, rbx
    call doc_free
1:  # remove slot
    mov rcx, r12
2:  lea rdx, [rcx + 1]
    cmp rdx, [rip + g_tabs + VEC_len]
    jae 3f
    mov rdi, rcx
    call tab_at
    mov rdx, [rax + TAB_SIZE + TAB_kind]
    mov [rax + TAB_kind], rdx
    mov rdx, [rax + TAB_SIZE + TAB_doc]
    mov [rax + TAB_doc], rdx
    inc rcx
    jmp 2b
3:  dec qword ptr [rip + g_tabs + VEC_len]
    mov rax, [rip + g_tab_cur]
    cmp rax, r12
    jb 4f
    ja 5f
    # closed the active one: keep index (next tab) or step back
    cmp rax, [rip + g_tabs + VEC_len]
    jb 4f
5:  dec rax
4:  mov rdi, rax
    cmp qword ptr [rip + g_tabs + VEC_len], 0
    jne 6f
    mov rdi, -1
6:  mov [rip + g_tab_cur], rdi
    test r13d, r13d
    jz .Lclose_focus_restored
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
.Lclose_focus_restored:
    call app_sync_doc
    call app_update_title
    EPILOGUE

# app_close_tab(i): ask when modified
FN app_close_tab
    PROLOGUE
    mov rbx, rdi
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 1f
    mov rdi, [rax + TAB_doc]
    call doc_dirty
    test eax, eax
    jz 1f
    mov [rip + dlg_tab], rbx
    mov dword ptr [rip + dlg_kind], 1
    mov dword ptr [rip + g_focus], FOCUS_DIALOG
    mov rdi, rbx
    call app_activate_tab
    mov dword ptr [rip + g_focus], FOCUS_DIALOG
    EPILOGUE
1:  mov rdi, rbx
    call app_close_tab_now
    EPILOGUE

FN cmd_close_tab
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 1f
    jmp app_close_tab
1:  ret

# cmd_close_all: close every tab. The first modified doc asks, and each answer that closes it comes
# back here for the next; a cancel stops, with the tabs not closed yet still open
FN cmd_close_all
    PROLOGUE
    mov edi, 5
    call ask_unsaved
    test eax, eax
    jnz 9f
    call close_tabs_now
9:  EPILOGUE

# ask_unsaved(kind) -> eax 1 when the first modified doc asks, in dialog kind (dlg_kind), else 0
ask_unsaved:
    PROLOGUE
    mov r12d, edi
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 3f
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 2f
    mov rdi, [rax + TAB_doc]
    call doc_dirty
    test eax, eax
    jz 2f
    mov [rip + dlg_tab], rbx
    mov [rip + dlg_kind], r12d
    mov rdi, rbx
    call app_activate_tab
    mov dword ptr [rip + g_focus], FOCUS_DIALOG
    mov eax, 1
    EPILOGUE
2:  inc rbx
    jmp 1b
3:  xor eax, eax
    EPILOGUE

# close_tabs_now(): close every tab without asking, the last first
close_tabs_now:
    PROLOGUE
1:  mov rdi, [rip + g_tabs + VEC_len]
    test rdi, rdi
    jz 9f
    dec rdi
    call app_close_tab_now
    jmp 1b
9:  EPILOGUE

FN cmd_next_tab
    mov esi, 1
    cmp dword ptr [rip + g_focus], FOCUS_TERMINAL   # in the terminal: the next terminal
    je term_cycle
    mov rax, [rip + g_tab_cur]
    test rax, rax
    js 1f
    inc rax
    cmp rax, [rip + g_tabs + VEC_len]
    jb 2f
    xor eax, eax
2:  mov rdi, rax
    jmp app_activate_tab
1:  ret

FN cmd_prev_tab
    mov esi, -1
    cmp dword ptr [rip + g_focus], FOCUS_TERMINAL
    je term_cycle
    mov rax, [rip + g_tab_cur]
    test rax, rax
    js 1f
    dec rax
    jns 2f
    mov rax, [rip + g_tabs + VEC_len]
    dec rax
2:  mov rdi, rax
    jmp app_activate_tab
1:  ret

# cmd_save(): save, or ask for a path for untitled docs; a read-only file asks before it is replaced
FN cmd_save
    xor edi, edi
    jmp save_doc

# app_save_close(): vim's :wq: save, and close the file once it is saved (after Overwrite, for a
#   read-only one)
FN app_save_close
    mov edi, 1
save_doc:
    READONLY_RET
    PROLOGUE
    mov r13d, edi
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    cmp qword ptr [rbx + DOC_path], 0
    jne 1f
    call cmd_save_as
    jmp 9f
1:  mov rdi, rbx
    call doc_readonly
    test eax, eax
    jz 3f
    mov [rip + ro_close], r13d
    mov rdi, rbx
    lea rsi, [rip + save_readonly_confirmed]
    call ask_readonly
    jmp 9f
3:  mov rdi, rbx
    call doc_save
    test rax, rax
    js 2f
    mov rdi, rbx
    call app_after_save
    test r13d, r13d
    jz 9f
    call cmd_close_tab
    jmp 9f
2:  lea rdi, [rip + .Lsave_failed]
    call app_toast
9:  EPILOGUE

# save_readonly_confirmed(): Overwrite, for cmd_save and :wq
save_readonly_confirmed:
    PROLOGUE
    mov rbx, [rip + ro_doc]
    cmp rbx, [rip + g_doc]
    jne 9f
    mov rdi, rbx
    call doc_save_readonly
    test rax, rax
    js 2f
    mov rdi, rbx
    call app_after_save
    cmp dword ptr [rip + ro_close], 0
    je 9f
    call cmd_close_tab
    jmp 9f
2:  lea rdi, [rip + .Lsave_failed]
    call app_toast
9:  EPILOGUE

# doc_readonly(doc) -> eax 1 when saving it would replace a file that says not to write it: file_readonly,
#   with a symlink followed as it is now, as the save will
FN doc_readonly
    mov rdi, [rdi + DOC_path]
    test rdi, rdi
    jnz file_readonly
    xor eax, eax
    ret

# file_readonly(path) -> path_readonly for the file a symlink there leads to (the one a save writes),
#   or for the path itself
FN file_readonly
    PROLOGUE
    mov rbx, rdi
    xor esi, esi
    call link_target
    mov r12, rax
    test rax, rax
    jz 1f
    mov rdi, rax
    call path_readonly
    mov ebx, eax
    mov rdi, r12
    call mem_free
    mov eax, ebx
    EPILOGUE
1:  mov rdi, rbx
    call path_readonly
    EPILOGUE

# path_readonly(path) -> eax 1 when the file there says not to write it (no write permission, or the
#   read-only attribute on Windows) while its folder takes a new file, so a save would replace it
#   anyway; in a folder that does not, a save fails as any other
FN path_readonly
    PROLOGUE
    mov rbx, rdi
    mov esi, 2                  # W_OK
    SYS SYS_access
    cmp rax, -13                # EACCES
    jne 8f
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call path_dirlen
    test rax, rax
    jnz 1f
    cmp byte ptr [rbx], '/'
    jne 7f
    mov eax, 1
1:  cmp rax, 4096
    jae 7f
    lea rdi, [rip + ro_dir]
    mov rsi, rbx
    mov rcx, rax
    rep movsb
    mov byte ptr [rdi], 0
    lea rdi, [rip + ro_dir]
    mov esi, 2
    SYS SYS_access
    test rax, rax
    jnz 8f
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# doc_save_readonly(doc) -> doc_save's result: a read-only file is replaced and stays read-only. On
#   Windows, where a read-only file cannot be replaced, the attribute is off while it is written (on
#   the file a symlink leads to, which is the one written).
FN doc_save_readonly
.ifdef WINDOWS
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + DOC_path]
    xor esi, esi
    call link_target            # as the save will follow it
    mov r13, rax
    test rax, rax
    jnz 1f
    mov r13, [rbx + DOC_path]
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call mem_dup                # the doc's paths are made again by the save
    mov r13, rax
1:
    mov rdi, r13
    mov esi, 0666
    SYS SYS_chmod
    mov rdi, rbx
    call doc_save
    mov r12, rax
    mov rdi, r13
    mov esi, 0444
    SYS SYS_chmod
    mov rdi, r13
    call mem_free
    mov rax, r12
    EPILOGUE
.else
    jmp doc_save
.endif

# app_save_as_readonly(path): Save As onto a read-only file asks first, as a save does
FN app_save_as_readonly
    PROLOGUE
    mov rbx, rdi
    call strlen
    cmp rax, 4096
    jae 9f
    lea rdi, [rip + ro_path]
    mov rsi, rbx
    call cstr_copy
    mov rax, [rip + g_doc]
    mov [rip + ro_doc], rax
    lea rdi, [rip + ro_path]
    call strlen
    lea rdi, [rip + ro_path]
    mov rsi, rax
    call path_basename
    mov rdi, rax
    lea rsi, [rip + save_as_readonly_confirmed]
    call ask_readonly_named
9:  EPILOGUE

# save_as_readonly_confirmed(): Overwrite, for Save As
save_as_readonly_confirmed:
    PROLOGUE
    mov rbx, [rip + ro_doc]
    test rbx, rbx
    jz 9f
    cmp rbx, [rip + g_doc]
    jne 9f
    mov rdi, rbx
    lea rsi, [rip + ro_path]
    call doc_set_path
    mov rdi, rbx
    call doc_save_readonly
    test rax, rax
    js 2f
    mov rdi, rbx
    call app_detect_lang
    mov rdi, rbx
    call app_after_save
    call app_update_title
    jmp 9f
2:  lea rdi, [rip + .Lsave_failed]
    call app_toast
9:  EPILOGUE

# ask_readonly(doc, fn): "Overwrite read-only NAME?", whose button calls fn
ask_readonly:
    mov [rip + ro_doc], rdi
    mov rdi, [rdi + DOC_name]
# ask_readonly_named(name, fn): the same for a file of that name
ask_readonly_named:
    PROLOGUE
    mov r12, rsi
    mov rbx, rdi
    call strlen
    cmp rax, 200
    jbe 1f
    mov eax, 200
1:  mov r13, rax
    lea rdi, [rip + ro_title]
    lea rsi, [rip + .Lro_a]
    call cstr_copy
    mov rdi, rax
    mov rsi, rbx
    mov rcx, r13
    rep movsb
    lea rsi, [rip + .Lro_b]
    call cstr_copy
    lea rdi, [rip + ro_title]
    lea rsi, [rip + .Lro_text]
    lea rdx, [rip + .Lro_button]
    mov rcx, r12
    call app_confirm
    EPILOGUE

# app_after_save(doc): re-detect language, config reload, explorer refresh
FN app_after_save
    PROLOGUE
    mov rbx, rdi
    cmp qword ptr [rbx + DOC_lang], 0
    jne 1f
    mov rdi, rbx
    call app_detect_lang
1:  lea rdi, [rip + .Lsaved]
    call app_toast
    call explorer_refresh
    mov rdi, rbx
    call git_doc_saved
    # saving the config file applies it right away
    call config_path
    mov rdi, rax
    mov rsi, [rbx + DOC_path]
.ifdef WINDOWS
    call win_path_equal
.else
    call strcmp_eq
.endif
    test eax, eax
    jz 2f
    call app_reload_config
2:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

FN cmd_save_as
    READONLY_RET
    lea rdi, [rip + .Lsave_as]
    mov esi, PROMPT_SAVE_AS
    jmp prompt_open

FN cmd_quit
    PROLOGUE
    # the session first, once: each answer to a question closes that file
    cmp dword ptr [rip + g_session_final], 0
    jne 4f
    call session_save
    mov dword ptr [rip + g_session_final], 1
4:  # the first modified doc asks; with none, quit
    mov edi, 2
    call ask_unsaved
    test eax, eax
    jnz 9f
    mov dword ptr [rip + g_quit], 1
9:  EPILOGUE

FN app_on_close
    jmp cmd_quit

# app_toast(cstr)
FN app_toast
    push rbx
    mov rsi, rdi
    lea rdi, [rip + g_toast]
    mov ecx, 250
1:  mov al, [rsi]
    mov [rdi], al
    test al, al
    jz 2f
    inc rsi
    inc rdi
    dec ecx
    jnz 1b
    mov byte ptr [rdi], 0
2:  call time_ms
    add rax, 2200
    mov [rip + g_toast_until], rax
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# app_reload_config(): re-read config and apply theme/fonts/sizes
FN app_reload_config
    PROLOGUE
    mov ebx, [rip + cfg_follow_system]
    mov rdi, [rip + cfg_theme]
    call theme_find
    mov r12, rax
    call config_load
    xor edi, edi
    call theme_settings_init
    # follow_system turned off in the file: theme becomes the theme shown, as in Settings, unless
    # theme was changed too
    test ebx, ebx
    jz 1f
    cmp dword ptr [rip + cfg_follow_system], 0
    jne 1f
    mov rdi, [rip + cfg_theme]
    call theme_find
    cmp rax, r12
    jne 1f
    lea rdi, [rip + cfg_theme]
    mov rsi, [rip + g_theme_cur]
    call theme_set
1:  call keys_reload
    call app_apply_settings
    EPILOGUE

# app_apply_settings(): push current cfg_* values into the running app
FN app_apply_settings
    PROLOGUE
    call theme_apply_config
    call app_sync_panels
    call git_apply
    call agents_apply_settings
    call ai_apply
    call vim_sync
    call watch_apply_settings
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ---------------- platform callbacks ----------------

FN app_on_resize
    mov dword ptr [rip + g_dirty], 1
    ret

FN app_on_motion
    call ui_input_motion
    mov dword ptr [rip + g_dirty], 1
    ret

FN app_on_pointer_leave
    mov edi, -10000
    mov esi, -10000
    call ui_input_motion
    mov dword ptr [rip + g_dirty], 1
    ret

# app_on_button(btn, pressed, mods)
FN app_on_button
    mov [rip + g_mods], edx
    # the caret shows at once, as after a key: a press or a release may have placed it
    push rdi
    push rsi
    push rdx
    call time_ms
    mov [rip + g_blink_t0], rax
    pop rdx
    pop rsi
    pop rdi
    call ui_input_button
    mov dword ptr [rip + g_dirty], 1
    ret

# app_on_scroll(dx, dy, mods)
FN app_on_scroll
    mov [rip + g_scroll_mods], edx
    mov ecx, [rip + cfg_scroll_sens]
    test edx, MOD_ALT
    jz 1f
    mov ecx, [rip + cfg_fast_sens]
    # in hundredths; what the division leaves carries to the next scroll, so a trackpad's
    # small steps add up instead of rounding away
1:  imul edi, ecx
    add edi, [rip + scroll_rem]
    imul esi, ecx
    add esi, [rip + scroll_rem + 4]
    mov ecx, 100
    mov eax, edi
    cdq
    idiv ecx
    mov edi, eax
    mov [rip + scroll_rem], edx
    mov eax, esi
    cdq
    idiv ecx
    mov esi, eax
    mov [rip + scroll_rem + 4], edx
    # less than a pixel so far: nothing to draw
    mov eax, edi
    or eax, esi
    jz 2f
    call ui_input_scroll
    mov dword ptr [rip + g_dirty], 1
2:  ret

# wheel_xy() -> eax x, edx y: this frame's wheel for a view that also scrolls sideways (the editor, an
#   image). Shift turns it sideways, as in other apps on Linux and Windows; macOS turns it itself.
#   Views that only scroll down keep Shift's wheel as it is (the terminal's scrollback).
FN wheel_xy
    mov eax, [rip + g_scroll_x]
    mov edx, [rip + g_scroll_y]
.ifndef MACOS
    test dword ptr [rip + g_scroll_mods], MOD_SHIFT
    jz 1f
    add eax, edx
    xor edx, edx
1:
.endif
    ret

FN app_on_focus
    mov [rip + g_win_focused], edi
    # files may have changed while away
    test edi, edi
    jz 1f
    push rdi
    call git_touch
    pop rdi
1:  call ed_touch
    mov dword ptr [rip + g_dirty], 1
    ret

# app_on_paste(ptr, len): route to the focused text target
FN app_on_paste
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call vim_paste
    test eax, eax
    jnz 9f
    # the commit message keeps line breaks
    cmp dword ptr [rip + g_focus], FOCUS_SCM
    jne 0f
    mov rdi, rbx
    mov rsi, r12
    call scm_paste
    jmp 9f
0:  mov rdi, rbx
    mov rsi, r12
    call focused_field
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call tf_insert
    call field_changed
    jmp 9f
1:  cmp dword ptr [rip + g_focus], FOCUS_TERMINAL
    jne 2f
    mov rdi, rbx
    mov rsi, r12
    call term_panel_paste
    jmp 9f
2:  cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 9f
    mov rdi, rbx
    mov rsi, r12
    call ed_paste
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# app_caret_focus() -> eax 1 when a caret has the keyboard: the editor's (with a text file) or a text
#   field's (the palette and its prompts, the find bar, a setting, vim's command line, the commit
#   message)
FN app_caret_focus
    mov eax, 1
    cmp dword ptr [rip + g_focus], FOCUS_SCM
    je 9f
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 1f
    cmp qword ptr [rip + g_doc], 0
    jne 9f
1:  call focused_field
    test rax, rax
    setnz al
    movzx eax, al
9:  ret

# focused_field() -> TF* that has keyboard focus, or 0
focused_field:
    mov eax, [rip + g_focus]
    cmp eax, FOCUS_PALETTE
    je palette_field
    cmp eax, FOCUS_PROMPT
    je palette_field
    cmp eax, FOCUS_FIND
    je find_field
    cmp eax, FOCUS_SETTINGS
    je settings_field
    cmp eax, FOCUS_EDITOR
    je vim_field
    xor eax, eax
    ret

# field_changed(): notify the owner of the focused field
field_changed:
    mov eax, [rip + g_focus]
    cmp eax, FOCUS_PALETTE
    je palette_changed
    cmp eax, FOCUS_PROMPT
    je palette_changed
    cmp eax, FOCUS_FIND
    je find_changed
    cmp eax, FOCUS_EDITOR
    je vim_field_changed
    ret

# app_on_key(keysym, cp, mods)
FN app_on_key
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call tip_dismiss
    mov [rip + g_mods], edx
    mov dword ptr [rip + g_dirty], 1
    call time_ms
    mov [rip + g_blink_t0], rax
    # dead keys and the Compose key
    mov edi, r12d
    mov esi, r14d
    call compose_key
    test eax, eax
    jnz 9f
    # modal dialog swallows keys
    cmp dword ptr [rip + dlg_kind], 0
    je 1f
    mov edi, r12d
    call dialog_key
    jmp 9f
1:  # Esc closes a context menu
    cmp r12d, KEY_ESCAPE
    jne 10f
    call explorer_menu_open
    test eax, eax
    jz 10f
    call ctx_menu_close
    jmp 9f
10: # focused components get the first chance
    mov eax, [rip + g_focus]
    cmp eax, FOCUS_PALETTE
    je 2f
    cmp eax, FOCUS_PROMPT
    jne 3f
2:  mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call palette_key
    test eax, eax
    jnz 9f
    jmp .Lk_bind
3:  cmp eax, FOCUS_FIND
    jne 4f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call find_key
    test eax, eax
    jnz 9f
    jmp .Lk_bind
4:  cmp eax, FOCUS_SETTINGS
    jne 5f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call settings_key
    test eax, eax
    jnz 9f
    jmp .Lk_bind
5:  cmp eax, FOCUS_EXPLORER
    jne 6f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call explorer_key
    test eax, eax
    jnz 9f
    jmp .Lk_bind
6:  cmp eax, FOCUS_AGENTS
    jne 7f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call agents_key
    test eax, eax
    jnz 9f
    jmp .Lk_bind
7:  cmp eax, FOCUS_TERMINAL
    jne 71f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call term_panel_key
    test eax, eax
    jnz 9f
    jmp .Lk_bind
71: cmp eax, FOCUS_SCM
    jne .Lk_bind
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call scm_key
    test eax, eax
    jnz 9f
.Lk_bind:
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 1f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call vim_key
    test eax, eax
    jnz 9f
1:  mov edi, r12d
    mov esi, r14d
    call keys_lookup
    test rax, rax
    jz .Lk_editor
    call rax
    jmp 9f
.Lk_editor:
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 9f
    call app_image
    test rax, rax
    jz 1f
    mov rdi, rax
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call iv_key
    jmp 9f
1:  # the history tab takes the arrows
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 8f
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_GIT
    jne 8f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call gitview_key
    jmp 9f
8:  mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call editor_key
9:  EPILOGUE

# editor_key(keysym, cp, mods): keys not bound to commands
FN editor_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    cmp qword ptr [rip + g_doc], 0
    je 9f
    mov r15d, r14d
    and r15d, MOD_SHIFT         # extend selection
    xor ebx, ebx                # word modifier
    test r14d, MOD_CTRL
    setnz bl
    mov eax, r12d
    cmp eax, KEY_LEFT
    jne 1f
    lea edi, [rbx*8 - 0]
    mov edi, 0
    test ebx, ebx
    jz 11f
    mov edi, 6
11: mov esi, r15d
    call ed_move
    jmp 9f
1:  cmp eax, KEY_RIGHT
    jne 2f
    mov edi, 1
    test ebx, ebx
    jz 21f
    mov edi, 7
21: mov esi, r15d
    call ed_move
    jmp 9f
2:  cmp eax, KEY_UP
    jne 3f
    test ebx, ebx
    jnz 31f
    mov edi, 2
    mov esi, r15d
    call ed_move
    jmp 9f
31: mov rax, [rip + g_doc]
    sub qword ptr [rax + DOC_scrolly], 256
    jmp 9f
3:  cmp eax, KEY_DOWN
    jne 4f
    test ebx, ebx
    jnz 41f
    mov edi, 3
    mov esi, r15d
    call ed_move
    jmp 9f
41: mov rax, [rip + g_doc]
    add qword ptr [rax + DOC_scrolly], 256
    jmp 9f
4:  cmp eax, KEY_HOME
    jne 5f
    mov edi, 4
    test ebx, ebx
    jz 51f
    mov edi, 10
51: mov esi, r15d
    call ed_move
    jmp 9f
5:  cmp eax, KEY_END
    jne 6f
    mov edi, 5
    test ebx, ebx
    jz 61f
    mov edi, 11
61: mov esi, r15d
    call ed_move
    jmp 9f
6:  cmp eax, KEY_PAGEUP
    jne 7f
    mov edi, 8
    mov esi, r15d
    call ed_move
    jmp 9f
7:  cmp eax, KEY_PAGEDOWN
    jne 8f
    mov edi, 9
    mov esi, r15d
    call ed_move
    jmp 9f
8:  cmp eax, KEY_BACKSPACE
    jne 81f
    mov edi, ebx
    call ed_backspace
    jmp 9f
81: cmp eax, KEY_DELETE
    jne 82f
    mov edi, ebx
    call ed_delete_fwd
    jmp 9f
82: cmp eax, KEY_RETURN
    je 83f
    cmp eax, KEY_KP_ENTER
    jne 84f
83: call ed_newline
    jmp 9f
84: cmp eax, KEY_TAB
    jne 85f
    test r14d, MOD_SHIFT
    jnz 86f
    call ed_tab
    jmp 9f
85: cmp eax, KEY_ISO_LEFT_TAB
    jne 87f
86: mov edi, -1
    call ed_indent
    jmp 9f
87: cmp eax, KEY_ESCAPE
    jne 88f
    # collapse selection
    mov rax, [rip + g_doc]
    mov rcx, [rax + DOC_cur]
    mov [rax + DOC_anchor], rcx
    lea rdi, [rip + g_ed_find]
    call sb_clear
    jmp 9f
88: # printable
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz 9f
    cmp r13d, 32
    jb 9f
    cmp r13d, 127
    je 9f
    mov edi, r13d
    call ed_type
9:  EPILOGUE

# ---------------- timers ----------------

FN app_timeout
    PROLOGUE
    call ed_blink_timeout
    mov ebx, eax
    # toast expiry
    mov rax, [rip + g_toast_until]
    test rax, rax
    jz 1f
    push rax
    call time_ms
    pop rcx
    sub rcx, rax
    jns 11f
    xor ecx, ecx
11: cmp ebx, -1
    je 12f
    cmp ecx, ebx
    jge 1f
12: mov ebx, ecx
1:  call agents_timeout
    cmp eax, -1
    je 2f
    cmp ebx, -1
    je 21f
    cmp eax, ebx
    jge 2f
21: mov ebx, eax
2:  call git_timeout
    cmp eax, -1
    je 3f
    cmp ebx, -1
    je 31f
    cmp eax, ebx
    jge 3f
31: mov ebx, eax
3:  call update_timeout
    cmp eax, -1
    je 4f
    cmp ebx, -1
    je 41f
    cmp eax, ebx
    jge 4f
41: mov ebx, eax
4:  call ai_timeout
    cmp eax, -1
    je 5f
    cmp ebx, -1
    je 51f
    cmp eax, ebx
    jge 5f
51: mov ebx, eax
5:  call watch_timeout
    cmp eax, -1
    je 6f
    cmp ebx, -1
    je 61f
    cmp eax, ebx
    jge 6f
61: mov ebx, eax
6:  call tip_timeout
    cmp eax, -1
    je 7f
    cmp ebx, -1
    je 71f
    cmp eax, ebx
    jge 7f
71: mov ebx, eax
7:  call palette_timeout
    cmp eax, -1
    je 8f
    cmp ebx, -1
    je 81f
    cmp eax, ebx
    jge 8f
81: mov ebx, eax
8:  call editor_timeout
    cmp eax, -1
    je 82f
    cmp ebx, -1
    je 83f
    cmp eax, ebx
    jge 82f
83: mov ebx, eax
82: call sb_timeout
    cmp eax, -1
    je 84f
    cmp ebx, -1
    je 85f
    cmp eax, ebx
    jge 84f
85: mov ebx, eax
84: mov eax, ebx
    EPILOGUE

FN app_tick
    PROLOGUE
    call watch_tick
    call tip_tick
    call sb_tick
    call ed_blink_tick
    mov rax, [rip + g_toast_until]
    test rax, rax
    jz 2f
    call time_ms
    cmp rax, [rip + g_toast_until]
    jb 2f
    mov qword ptr [rip + g_toast_until], 0
    mov dword ptr [rip + g_dirty], 1
2:  call agents_tick
    call term_tick
    call git_tick
    call update_tick
    call ai_tick
    call palette_tick
    call editor_tick
    EPILOGUE

# ---------------- rendering ----------------

FN app_render
    PROLOGUE 64
    call ui_update_metrics
    call ui_begin
    mov dword ptr [rip + tip_cand], 0   # hovered-button candidates are collected below
    mov eax, [rip + g_cv + CV_w]
    mov [rsp], eax              # W
    mov eax, [rip + g_cv + CV_h]
    mov [rsp + 4], eax          # H
    # modal layers block the base UI
    call app_modal_open
    mov [rsp + 8], eax
    mov [rip + g_block], eax
    call resize_edges
    mov [rsp + 36], eax
    test eax, eax
    jz 1f
    mov dword ptr [rip + g_block], 1
1:
    # background
    xor edi, edi
    xor esi, esi
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    COLOR r8d, T_BG
    call gfx_fill
    # panel sizes
    mov edi, [rip + cfg_sidebar_w]
    call sc
    mov [rip + g_side_px], eax
    mov edi, [rip + cfg_agents_w]
    call sc
    mov [rip + g_agents_px], eax
    # keep the editor at least 240pt wide
    mov edi, 240
    call sc
    mov ecx, [rsp]
    sub ecx, eax
    xor edx, edx
    cmp dword ptr [rip + g_show_side], 0
    je 1f
    mov edx, [rip + g_side_px]
1:  cmp dword ptr [rip + g_show_agents], 0
    je 2f
    add edx, [rip + g_agents_px]
2:  cmp edx, ecx
    jle 3f
    # shrink the agents panel first, then the sidebar
    sub edx, ecx
    mov eax, [rip + g_agents_px]
    sub eax, edx
    mov [rip + g_agents_px], eax
3:  M eax, MI_TITLE
    mov [rsp + 12], eax         # title h
    M eax, MI_STATUS
    mov ecx, [rsp + 4]
    sub ecx, eax
    mov [rsp + 16], ecx         # status y
    # body box
    mov eax, [rsp + 12]
    mov [rsp + 20], eax         # body y
    mov ecx, [rsp + 16]
    sub ecx, eax
    mov [rsp + 24], ecx         # body h
    mov dword ptr [rsp + 28], 0 # body x
    mov eax, [rsp]
    mov [rsp + 32], eax         # body right
    # the dividers take their strips first: the panels either side are drawn before them
    mov dword ptr [rip + split_l_bits], 0
    mov dword ptr [rip + split_r_bits], 0
    cmp dword ptr [rip + g_show_side], 0
    je 31f
    mov edi, ID_SPLIT_L
    mov esi, [rip + g_side_px]
    mov edx, [rsp + 20]
    mov ecx, [rsp + 24]
    call splitter_hit
    mov [rip + split_l_bits], eax
31: cmp dword ptr [rip + g_show_agents], 0
    je 32f
    mov edi, ID_SPLIT_R
    mov esi, [rsp]
    sub esi, [rip + g_agents_px]
    mov edx, [rsp + 20]
    mov ecx, [rsp + 24]
    call splitter_hit
    mov [rip + split_r_bits], eax
32:
    # sidebar
    cmp dword ptr [rip + g_show_side], 0
    je 4f
    xor edi, edi
    mov esi, [rsp + 20]
    mov edx, [rip + g_side_px]
    mov ecx, [rsp + 24]
    call explorer_draw
    mov eax, [rip + g_side_px]
    mov [rsp + 28], eax
    # border + splitter
    mov edi, eax
    mov esi, [rsp + 20]
    M edx, MI_1
    mov ecx, [rsp + 24]
    COLOR r8d, T_BORDER
    call gfx_fill
4:  cmp dword ptr [rip + g_show_agents], 0
    je 5f
    mov edi, [rsp]
    sub edi, [rip + g_agents_px]
    mov [rsp + 32], edi
    mov esi, [rsp + 20]
    mov edx, [rip + g_agents_px]
    mov ecx, [rsp + 24]
    call agents_draw
    mov edi, [rsp + 32]
    mov esi, [rsp + 20]
    M edx, MI_1
    mov ecx, [rsp + 24]
    COLOR r8d, T_BORDER
    call gfx_fill
5:  # editor column, the terminal panel under it
    mov edi, [rsp + 28]
    cmp dword ptr [rip + g_show_side], 0
    je 51f
    add edi, [rip + g_mt + 4*MI_1]
51: mov [rsp + 40], edi
    mov eax, [rsp + 32]
    sub eax, edi
    mov [rsp + 44], eax         # column w
    mov eax, [rsp + 24]
    mov [rsp + 48], eax         # editor h
    cmp dword ptr [rip + g_term_open], 0
    je 52f
    mov edi, [rip + cfg_term_h]
    call sc
    M edx, MI_64
    mov ecx, [rsp + 24]
    sub ecx, edx
    sub ecx, edx
    cmp eax, ecx
    cmovg eax, ecx
    cmp eax, edx
    cmovl eax, edx
    mov [rsp + 52], eax         # panel h
    mov ecx, [rsp + 24]
    sub ecx, eax
    mov [rsp + 48], ecx
52: # the terminal's top edge (term_panel_draw: MI_3 either side of it) is its handle, so the editor
    # above it does not take a press there too
    cmp dword ptr [rip + g_term_open], 0
    je 54f
    mov eax, [rsp + 40]
    mov [rip + g_hole], eax
    mov eax, [rsp + 20]
    add eax, [rsp + 48]
    sub eax, [rip + g_mt + 4*MI_3]
    mov [rip + g_hole + 4], eax
    mov eax, [rsp + 44]
    mov [rip + g_hole + 8], eax
    M eax, MI_3
    lea eax, [rax + rax + 1]
    mov [rip + g_hole + 12], eax
54: mov edi, [rsp + 40]
    mov esi, [rsp + 20]
    mov edx, [rsp + 44]
    mov ecx, [rsp + 48]
    call center_draw
    mov dword ptr [rip + g_hole + 12], 0
    cmp dword ptr [rip + g_term_open], 0
    je 53f
    mov edi, [rsp + 40]
    mov esi, [rsp + 20]
    add esi, [rsp + 48]
    mov edx, [rsp + 44]
    mov ecx, [rsp + 52]
    call term_panel_draw
53: # the dividers over everything in the body: their line and cursor win
    cmp dword ptr [rip + g_show_side], 0
    je 55f
    mov edi, ID_SPLIT_L
    mov esi, [rsp + 28]
    mov edx, [rsp + 20]
    mov ecx, [rsp + 24]
    mov r8d, [rip + split_l_bits]
    call splitter
55: cmp dword ptr [rip + g_show_agents], 0
    je 56f
    mov edi, ID_SPLIT_R
    mov esi, [rsp + 32]
    mov edx, [rsp + 20]
    mov ecx, [rsp + 24]
    mov r8d, [rip + split_r_bits]
    call splitter
56:
    # chrome
    xor edi, edi
    xor esi, esi
    mov edx, [rsp]
    mov ecx, [rsp + 12]
    call titlebar_draw
    xor edi, edi
    mov esi, [rsp + 16]
    mov edx, [rsp]
    M ecx, MI_STATUS
    call statusbar_draw
    # overlays (not blocked)
    mov dword ptr [rip + g_block], 0
    call explorer_menu_draw
    call palette_draw
    call dialog_draw
    call toast_draw
    call tip_commit             # after every button with a tooltip has been drawn
    call tip_draw
    mov edi, [rsp + 36]
    test edi, edi
    jz 2f
    call edge_cursor
    mov [rip + g_cursor], eax
2:  call ui_end
    # scripted screenshot
    mov rdi, [rip + g_shot_path]
    test rdi, rdi
    jz 9f
    mov qword ptr [rip + g_shot_path], 0
    call shot_write
9:  EPILOGUE

# app_modal_open() -> 1 when a modal layer should block the base ui
app_modal_open:
    cmp dword ptr [rip + dlg_kind], 0
    jne 1f
    call explorer_menu_open
    test eax, eax
    jnz 1f
    call palette_is_open
    ret
1:  mov eax, 1
    ret

# resize_edges() -> EDGE_* bits under the pointer (client-side decorations only); starts a resize on press
resize_edges:
    xor eax, eax
    cmp dword ptr [rip + g_csd], 0
    je 9f
    test dword ptr [rip + g_win_states], 1 | 2 | 8
    jnz 9f
    mov ecx, [rip + g_mx]
    mov edx, [rip + g_my]
    test ecx, ecx
    js 9f
    test edx, edx
    js 9f
    M r8d, MI_6
    cmp ecx, r8d
    jge 1f
    or eax, EDGE_LEFT
1:  mov r9d, [rip + g_cv + CV_w]
    sub r9d, r8d
    cmp ecx, r9d
    jl 2f
    or eax, EDGE_RIGHT
2:  cmp edx, r8d
    jge 3f
    or eax, EDGE_TOP
3:  mov r9d, [rip + g_cv + CV_h]
    sub r9d, r8d
    cmp edx, r9d
    jl 4f
    or eax, EDGE_BOTTOM
4:  test eax, eax
    jz 9f
    test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz 9f
    and dword ptr [rip + g_pressed], ~(1 << BTN_LEFT)
    push rax
    push rax
    mov edi, eax
    PCALL P_resize
    pop rax
    pop rax
9:  ret

# edge_cursor(edges) -> CUR_*
edge_cursor:
    mov eax, CUR_EW
    cmp edi, EDGE_LEFT
    je 1f
    cmp edi, EDGE_RIGHT
    je 1f
    mov eax, CUR_NS
    cmp edi, EDGE_TOP
    je 1f
    cmp edi, EDGE_BOTTOM
    je 1f
    mov eax, CUR_NWSE
    cmp edi, EDGE_TOP | EDGE_LEFT
    je 1f
    cmp edi, EDGE_BOTTOM | EDGE_RIGHT
    je 1f
    mov eax, CUR_NESW
1:  ret

# splitter_hit(id, x, y, h) -> UB_* bits: the divider's strip, MI_3 either side of x; it keeps its press
splitter_hit:
    PROLOGUE
    M eax, MI_3
    sub esi, eax
    lea r8d, [rax + rax + 1]
    xchg ecx, r8d
    call ui_btn
    test eax, UB_PRESS
    jz 1f
    and dword ptr [rip + g_pressed], ~(1 << BTN_LEFT)   # the press is the drag's; nothing under it takes it too
1:  EPILOGUE

# splitter(id, x, y, h, bits): cursor, line and drag of a divider hit tested by splitter_hit
splitter:
    PROLOGUE 16
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov eax, r8d
4:  test eax, UB_HOVER | UB_HELD
    jz 1f
    mov dword ptr [rip + g_cursor], CUR_EW
    mov [rsp], eax                  # feedback line over the divider
    M edx, MI_2
    mov edi, edx
    sar edi, 1
    neg edi
    add edi, r12d
    mov esi, r13d
    mov ecx, r14d
    xor r8d, r8d
    COLOR r9d, T_ACCENT
    call gfx_round_rect
    mov eax, [rsp]
1:  test eax, UB_HELD
    jz 9f
    # new width in logical points
    mov eax, [rip + g_mx]
    cmp ebx, ID_SPLIT_L
    jne 2f
    cvtsi2ss xmm0, eax
    divss xmm0, [rip + g_s]
    cvtss2si eax, xmm0
    cmp eax, 140
    jge 11f
    mov eax, 140
11: cmp eax, 600
    jle 12f
    mov eax, 600
12: mov [rip + cfg_sidebar_w], eax
    jmp 3f
2:  mov ecx, [rip + g_cv + CV_w]
    sub ecx, eax
    cvtsi2ss xmm0, ecx
    divss xmm0, [rip + g_s]
    cvtss2si eax, xmm0
    cmp eax, 240
    jge 21f
    mov eax, 240
21: cmp eax, 900
    jle 22f
    mov eax, 900
22: mov [rip + cfg_agents_w], eax
3:  mov dword ptr [rip + g_dirty], 1
    mov dword ptr [rip + g_settings_changed], 1
9:  EPILOGUE

# center_draw(x, y, w, h): tabs + editor / settings / welcome
FN center_draw
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    cmp qword ptr [rip + g_tabs + VEC_len], 0
    jne 1f
    call welcome_draw
    EPILOGUE
1:  M eax, MI_TAB
    mov [rsp + 16], eax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, eax
    call tabs_draw
    # the strip may have closed the last tab
    cmp qword ptr [rip + g_tabs + VEC_len], 0
    jne 3f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call welcome_draw
    EPILOGUE
3:  mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rsp + 16]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    sub ecx, [rsp + 16]
    mov [rip + g_editor_rect], edi
    mov [rip + g_editor_rect + 4], esi
    mov [rip + g_editor_rect + 8], edx
    mov [rip + g_editor_rect + 12], ecx
    mov rax, [rip + g_tab_cur]
    mov rdi, rax
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_IMAGE
    jne 4f
    mov rdi, [rax + TAB_doc]
    mov esi, [rip + g_editor_rect]
    mov edx, [rip + g_editor_rect + 4]
    mov ecx, [rip + g_editor_rect + 8]
    mov r8d, [rip + g_editor_rect + 12]
    call iv_draw
    EPILOGUE
4:  cmp qword ptr [rax + TAB_kind], TAB_GIT
    jne 1f
    mov edi, [rip + g_editor_rect]
    mov esi, [rip + g_editor_rect + 4]
    mov edx, [rip + g_editor_rect + 8]
    mov ecx, [rip + g_editor_rect + 12]
    call gitview_draw
    EPILOGUE
1:  cmp qword ptr [rax + TAB_kind], TAB_SETTINGS
    jne 2f
    mov edi, [rip + g_editor_rect]
    mov esi, [rip + g_editor_rect + 4]
    mov edx, [rip + g_editor_rect + 8]
    mov ecx, [rip + g_editor_rect + 12]
    call settings_draw
    EPILOGUE
2:  mov rbx, [rip + g_doc]
    mov rdi, rbx
    mov rsi, [rbx + DOC_scrolly]
    shr rsi, 8
    mov eax, [rip + g_editor_rect + 12]
    xor edx, edx
    div dword ptr [rip + g_lh]
    lea rsi, [rsi + rax + 2]
    call syntax_prepare
    mov edi, [rip + g_editor_rect]
    mov esi, [rip + g_editor_rect + 4]
    mov edx, [rip + g_editor_rect + 8]
    mov ecx, [rip + g_editor_rect + 12]
    call editor_draw
    call find_draw
    EPILOGUE

# titlebar_draw(x, y, w, h)
FN titlebar_draw
    PROLOGUE 80
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    COLOR r8d, T_TITLEBAR
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 12]
    dec esi
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    # buttons first; the empty title area (move, maximize, menu) is handled at the end
    mov eax, [rip + g_hot]
    mov [rsp + 32], eax
    mov dword ptr [rip + g_hot], 0
    # Scale button widths and gaps together only when the toolbar cannot fit.
    M eax, MI_32
    mov [rsp + 40], eax         # button width
    M eax, MI_8
    mov [rsp + 44], eax         # outer gap
    M eax, MI_4
    mov [rsp + 48], eax         # inner gap
    M eax, MI_48
    mov [rsp + 52], eax         # window control width
    M eax, MI_6
    mov [rsp + 56], eax         # project padding
    mov ecx, 160
    cmp dword ptr [rip + g_csd], 0
    je 21f
    add ecx, 144
21: cmp dword ptr [rip + g_git_on], 0
    je 22f
    add ecx, 36
22: mov eax, [rsp + 40]
    imul eax, ecx
    mov edx, [rsp + 8]
    sub edx, [rip + g_title_inset]
    imul edx, edx, 32
    cmp edx, eax
    jge 23f
    mov eax, edx
    cdq
    idiv ecx
    mov ecx, 1
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 40], eax
    mov ecx, eax
    shr ecx, 2
    mov [rsp + 44], ecx
    mov ecx, eax
    shr ecx, 3
    mov [rsp + 48], ecx
    lea ecx, [rax + rax*2]
    shr ecx, 1
    mov [rsp + 52], ecx
    imul ecx, eax, 3
    shr ecx, 4
    mov [rsp + 56], ecx
23: mov r12d, [rsp + 44]
    add r12d, [rip + g_title_inset]
    # sidebar toggle
    mov r13d, [rsp + 40]
    mov edi, ID_TOG_SIDE
    mov esi, r12d
    mov edx, [rsp + 12]
    sub edx, r13d
    sar edx, 1
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_SIDEBAR
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_TOG_SIDE
    mov esi, r12d
    M edx, MI_TITLE
    mov ecx, r13d
    call tip_note               # keeps the button flags in eax
    test eax, UB_CLICK
    jz 3f
    call cmd_toggle_sidebar
3:  add r12d, r13d
    add r12d, [rsp + 44]
    # Reserve the right toolbar before sizing the project label and its hitbox.
    mov eax, [rsp + 40]
    imul eax, eax, 3
    add eax, [rsp + 44]
    add eax, [rsp + 44]
    add eax, [rsp + 48]
    add eax, [rsp + 48]
    cmp dword ptr [rip + g_git_on], 0
    je 31f
    add eax, [rsp + 40]
    add eax, [rsp + 48]
31: cmp dword ptr [rip + g_csd], 0
    je 32f
    mov ecx, [rsp + 52]
    imul ecx, ecx, 3
    add eax, ecx
32: mov ecx, [rsp + 8]
    sub ecx, eax
    mov [rsp + 36], ecx        # left edge of the toolbar, with a gap
    # project name and a chevron: the button for the project menu
    mov rax, [rip + g_project_name]
    test rax, rax
    jnz 4f
    lea rax, [rip + .Lrhun]
4:  mov [rsp + 16], rax
    mov rdi, rax
    call strlen
    lea rdi, [rip + g_face_ui]
    mov rsi, [rsp + 16]
    mov rdx, rax
    call text_width
    mov r14d, r12d
    sub r14d, [rsp + 56]   # x
    mov r15d, eax
    add r15d, [rsp + 56]
    add r15d, [rsp + 56]
    add r15d, [rsp + 48]
    add r15d, [rip + g_mt + 4*MI_12]  # w
    mov eax, [rsp + 36]
    sub eax, r14d
    test eax, eax
    jle 44f
    cmp r15d, eax
    cmovg r15d, eax
    mov edi, r14d
    mov esi, [rsp + 4]
    mov edx, r15d
    mov ecx, [rsp + 12]
    call gfx_clip_push
    mov edi, ID_PROJECT_BTN
    mov esi, r14d
    M r8d, MI_28
    mov edx, [rsp + 12]
    sub edx, r8d
    sar edx, 1
    mov ecx, r15d
    call ui_btn
    mov ebx, eax
    # hovered, or its menu open
    test ebx, UB_HOVER
    jnz 41f
    call ctx_menu_list
    lea rcx, [rip + pm_items]
    cmp rax, rcx
    jne 42f
41: mov edi, r14d
    M ecx, MI_28
    mov esi, [rsp + 12]
    sub esi, ecx
    sar esi, 1
    mov edx, r15d
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
42: lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, [rsp + 16]
    COLOR r9d, T_FG
    call ui_text_c
    mov esi, eax
    add esi, [rsp + 48]
    M ecx, MI_12
    mov edx, [rsp + 12]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    mov edi, IC_CHEV_D
    COLOR r8d, T_MUTED
    test ebx, UB_HOVER
    jz 43f
    COLOR r8d, T_FG
43: call icon_draw
    call gfx_clip_pop
    lea r12d, [r14 + r15]
    test ebx, UB_CLICK
    jz 44f
    mov edi, r14d
    mov esi, [rsp + 4]
    add esi, [rsp + 12]
    call project_menu_open
44: # active file, centered (the branch is in the status bar)
    mov rbx, [rip + g_file]
    test rbx, rbx
    jz 6f
    mov rdi, rbx
    call doc_rel_path
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    lea rdi, [rip + g_face_small]
    mov rsi, rax
    call text_width
    mov esi, [rsp + 8]
    sub esi, eax
    sar esi, 1
    cmp esi, r12d
    jle 6f
    add eax, esi
    cmp eax, [rsp + 36]
    jg 6f
    lea rdi, [rip + g_face_small]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, [rsp + 16]
    mov r9, [rsp + 24]
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
6:  # right side buttons
    mov r12d, [rsp + 8]
    cmp dword ptr [rip + g_csd], 0
    je 7f
    # window controls: close, maximize, minimize (right to left)
    mov r13d, [rsp + 52]
    sub r12d, r13d
    mov edi, ID_WCLOSE
    mov esi, r12d
    xor edx, edx
    mov ecx, r13d
    mov r8d, [rsp + 12]
    call ui_btn
    mov ebx, eax
    COLOR r14d, T_MUTED
    test ebx, UB_HOVER
    jz 61f
    mov edi, r12d
    xor esi, esi
    mov edx, r13d
    mov ecx, [rsp + 12]
    dec ecx
    mov r8d, 0xffe0434f
    call gfx_fill
    mov r14d, 0xffffffff
61: mov edi, IC_WCLOSE
    mov esi, r12d
    xor edx, edx
    mov ecx, r13d
    mov r8d, [rsp + 12]
    mov r9d, r14d
    call ui_icon_center
    test ebx, UB_CLICK
    jz 62f
    call cmd_quit
62: sub r12d, r13d
    mov edi, ID_WMAX
    mov esi, r12d
    mov r14d, IC_MAX
    test dword ptr [rip + g_win_states], 1
    jz 63f
    mov r14d, IC_RESTORE
63: call .Ltb_wbtn
    test eax, UB_CLICK
    jz 64f
    PCALL P_maximize
64: sub r12d, r13d
    mov edi, ID_WMIN
    mov esi, r12d
    mov r14d, IC_MIN
    call .Ltb_wbtn
    test eax, UB_CLICK
    jz 7f
    PCALL P_minimize
7:  # settings + agents toggles
    mov r13d, [rsp + 40]
    sub r12d, r13d
    sub r12d, [rsp + 44]
    mov edi, ID_SETTINGS_BTN
    mov esi, r12d
    mov edx, [rsp + 12]
    sub edx, r13d
    sar edx, 1
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_SLIDERS
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_SETTINGS_BTN
    mov esi, r12d
    M edx, MI_TITLE
    mov ecx, r13d
    call tip_note               # keeps the button flags in eax
    test eax, UB_CLICK
    jz 8f
    call cmd_settings
8:  sub r12d, r13d
    sub r12d, [rsp + 48]
    mov edi, ID_TOG_AGENTS
    mov esi, r12d
    mov edx, [rsp + 12]
    sub edx, r13d
    sar edx, 1
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_SPARK
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_TOG_AGENTS
    mov esi, r12d
    M edx, MI_TITLE
    mov ecx, r13d
    call tip_note               # keeps the button flags in eax
    test eax, UB_CLICK
    jz 81f
    call cmd_toggle_agents
81: sub r12d, r13d
    sub r12d, [rsp + 48]
    mov edi, ID_TOG_TERM
    mov esi, r12d
    mov edx, [rsp + 12]
    sub edx, r13d
    sar edx, 1
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_TERMINAL
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_TOG_TERM
    mov esi, r12d
    M edx, MI_TITLE
    mov ecx, r13d
    call tip_note               # keeps the button flags in eax
    test eax, UB_CLICK
    jz 82f
    call cmd_toggle_terminal
82: cmp dword ptr [rip + g_git_on], 0
    je 9f
    sub r12d, r13d
    sub r12d, [rsp + 48]
    mov edi, ID_GIT_BTN
    mov esi, r12d
    mov edx, [rsp + 12]
    sub edx, r13d
    sar edx, 1
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_BRANCH
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_GIT_BTN
    mov esi, r12d
    M edx, MI_TITLE
    mov ecx, r13d
    call tip_note               # keeps the button flags in eax
    test eax, UB_CLICK
    jz 9f
    call cmd_toggle_git
9:  # a press on a button must not start a window move: the compositor would take the release
    cmp dword ptr [rip + g_hot], 0
    jne 13f
    mov edi, ID_TITLE
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call ui_btn
    test eax, UB_DOUBLE
    jz 11f
    PCALL P_maximize
    jmp 13f
11: test eax, UB_PRESS
    jz 12f
    PCALL P_move
    and dword ptr [rip + g_mdown], ~(1 << BTN_LEFT)   # the release goes to the compositor
    mov dword ptr [rip + g_active], 0
    jmp 13f
12: test eax, UB_RPRESS
    jz 13f
    mov edi, [rip + g_mx]
    mov esi, [rip + g_my]
    PCALL P_menu
13: cmp dword ptr [rip + g_hot], 0
    jne 14f
    mov eax, [rsp + 32]
    mov [rip + g_hot], eax
14: EPILOGUE
# window control button helper: edi id, esi x, r13d w, r14d icon -> eax UB bits
.Ltb_wbtn:
    push rbx
    push r15
    sub rsp, 8
    mov r15d, esi
    xor edx, edx
    mov ecx, r13d
    mov r8d, [rsp + 24 + 8 + 12]
    call ui_btn
    mov ebx, eax
    test ebx, UB_HOVER
    jz 1f
    mov edi, r15d
    xor esi, esi
    mov edx, r13d
    mov ecx, [rsp + 24 + 8 + 12]
    dec ecx
    COLOR r8d, T_HOVER
    call gfx_fill
1:  mov edi, r14d
    mov esi, r15d
    xor edx, edx
    mov ecx, r13d
    mov r8d, [rsp + 24 + 8 + 12]
    COLOR r9d, T_MUTED
    test ebx, UB_HOVER
    jz 2f
    COLOR r9d, T_FG
2:  call ui_icon_center
    mov eax, ebx
    add rsp, 8
    pop r15
    pop rbx
    ret

# doc_rel_path(doc) -> rax ptr, rdx len : path relative to the project when inside it
FN doc_rel_path
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + DOC_path]
    test r12, r12
    jnz 1f
    mov rax, [rbx + DOC_name]
    mov rdi, rax
    push rax
    call strlen
    mov rdx, rax
    pop rax
    EPILOGUE
1:  mov rdi, r12
    call strlen
    mov r13, rax
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 2f
    call strlen
    mov r14, rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rip + g_project]
    mov rcx, r14
    call str_starts
    test eax, eax
    jz 2f
    cmp r14, r13
    jae 2f
    cmp byte ptr [r12 + r14], '/'
    jne 2f
    lea rax, [r12 + r14 + 1]
    mov rdx, r13
    sub rdx, r14
    dec rdx
    EPILOGUE
2:  mov rax, r12
    mov rdx, r13
    EPILOGUE

# tabs_draw(x, y, w, h)
FN tabs_draw
    PROLOGUE 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    COLOR r8d, T_TAB
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rsp + 12]
    sub esi, [rip + g_mt + 4*MI_1]
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    # wheel scrolls the strip
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call ui_in
    test eax, eax
    jz 1f
    mov eax, [rip + g_scroll_y]
    add eax, [rip + g_scroll_x]
    add [rip + g_tabscroll], eax
1:  cmp dword ptr [rip + g_tabscroll], 0
    jge 2f
    mov dword ptr [rip + g_tabscroll], 0
2:  mov r12d, [rsp]
    sub r12d, [rip + g_tabscroll]
    xor ebx, ebx
.Ltd_tab:
    cmp rbx, [rip + g_tabs + VEC_len]
    jae .Ltd_done
    # label
    mov rdi, rbx
    call tab_at
    mov r15, rax
    mov rdi, rbx
    call app_tab_label
    mov r13, rax
    mov rdi, r13
    call strlen
    mov r14, rax
    lea rdi, [rip + g_face_ui]
    mov rsi, r13
    mov rdx, r14
    call text_width
    add eax, [rip + g_mt + 4*MI_40]
    add eax, [rip + g_mt + 4*MI_12]
    mov [rsp + 16], eax         # tab width
    # reveal the active tab
    cmp rbx, [rip + g_tab_cur]
    jne 5f
    cmp dword ptr [rip + g_tabscroll_reveal], 0
    je 5f
    mov dword ptr [rip + g_tabscroll_reveal], 0
    mov ecx, r12d
    sub ecx, [rsp]
    jns 41f
    add [rip + g_tabscroll], ecx
    add r12d, ecx
    sub r12d, ecx
    mov dword ptr [rip + g_dirty], 1
41: mov ecx, r12d
    add ecx, eax
    mov edx, [rsp]
    add edx, [rsp + 8]
    sub ecx, edx
    jle 5f
    add [rip + g_tabscroll], ecx
    mov dword ptr [rip + g_dirty], 1
5:  # interaction
    lea edi, [rbx + ID_TAB]
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rsp + 16]
    mov r8d, [rsp + 12]
    call ui_btn
    mov [rsp + 20], eax
    test eax, UB_PRESS
    jz 6f
    mov rdi, rbx
    call app_activate_tab
6:  test dword ptr [rsp + 20], UB_HOVER
    jz 61f
    test dword ptr [rip + g_pressed], 1 << BTN_MIDDLE
    jz 61f
    mov rdi, rbx
    call app_close_tab
    jmp .Ltd_done
61: # background
    cmp rbx, [rip + g_tab_cur]
    jne 7f
    mov edi, r12d
    mov esi, [rsp + 4]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 12]
    COLOR r8d, T_TAB_ACTIVE
    call gfx_fill
    # the active tab opens into the editor: borders at both sides run the full height and join
    # the strip's bottom line (the left one is the previous tab's separator column)
    mov edi, r12d
    sub edi, [rip + g_mt + 4*MI_1]
    mov esi, [rsp + 4]
    M edx, MI_1
    mov ecx, [rsp + 12]
    COLOR r8d, T_BORDER
    call gfx_fill
    mov edi, r12d
    add edi, [rsp + 16]
    sub edi, [rip + g_mt + 4*MI_1]
    mov esi, [rsp + 4]
    M edx, MI_1
    mov ecx, [rsp + 12]
    COLOR r8d, T_BORDER
    call gfx_fill
    mov edi, r12d
    mov esi, [rsp + 4]
    mov edx, [rsp + 16]
    sub edx, [rip + g_mt + 4*MI_1]
    M ecx, MI_2
    COLOR r8d, T_ACCENT
    call gfx_fill
    jmp 86f
7:  test dword ptr [rsp + 20], UB_HOVER
    jz 8f
    mov edi, r12d
    mov esi, [rsp + 4]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 12]
    sub ecx, [rip + g_mt + 4*MI_1]
    COLOR r8d, T_HOVER
    call gfx_fill
8:  # separator
    mov edi, r12d
    add edi, [rsp + 16]
    sub edi, [rip + g_mt + 4*MI_1]
    mov esi, [rsp + 4]
    add esi, [rip + g_mt + 4*MI_8]
    M edx, MI_1
    mov ecx, [rsp + 12]
    sub ecx, [rip + g_mt + 4*MI_16]
    COLOR r8d, T_BORDER
    call gfx_fill
86: # text: git status color, else muted (foreground when active)
    mov rax, [r15 + TAB_doc]
    test rax, rax
    jz 80f
    mov rdi, [rax + DOC_path]
    xor eax, eax
    test rdi, rdi
    jz 80f
    call git_path_color
80: mov r9d, eax
    test eax, eax
    jnz 81f
    COLOR r9d, T_MUTED
    cmp rbx, [rip + g_tab_cur]
    jne 81f
    COLOR r9d, T_FG
81: lea rdi, [rip + g_face_ui]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, r13
    push r9
    push r9
    mov r9, r14
    call ui_text_v
    add rsp, 16
    # close button / modified dot
    M r13d, MI_20
    mov esi, r12d
    add esi, [rsp + 16]
    sub esi, r13d
    sub esi, [rip + g_mt + 4*MI_8]
    mov [rsp + 24], esi
    mov edx, [rsp + 12]
    sub edx, r13d
    sar edx, 1
    add edx, [rsp + 4]
    mov [rsp + 28], edx
    lea edi, [rbx + ID_TABX]
    mov ecx, r13d
    mov r8d, r13d
    call ui_btn
    mov [rsp + 32], eax
    xor r14d, r14d              # modified?
    cmp qword ptr [r15 + TAB_kind], TAB_DOC
    jne 82f
    mov rdi, [r15 + TAB_doc]
    call doc_dirty
    mov r14d, eax
82: test dword ptr [rsp + 32], UB_HOVER
    jnz 84f
    test r14d, r14d
    jz 83f
    # dot
    M ecx, MI_8
    mov edi, [rsp + 24]
    mov esi, [rsp + 28]
    mov eax, r13d
    sub eax, ecx
    sar eax, 1
    add edi, eax
    add esi, eax
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_FG
    cmp rbx, [rip + g_tab_cur]
    je 821f
    COLOR r9d, T_MUTED
821:call gfx_round_rect
    jmp .Ltd_next
83: cmp rbx, [rip + g_tab_cur]
    jne 841f
    test dword ptr [rsp + 20], UB_HOVER
    jz 841f
84: # x
    test dword ptr [rsp + 32], UB_HOVER
    jz 85f
    mov edi, [rsp + 24]
    mov esi, [rsp + 28]
    mov edx, r13d
    mov ecx, r13d
    M r8d, MI_4
    COLOR r9d, T_HOVER
    call gfx_round_rect
85: mov edi, IC_CLOSE
    mov esi, [rsp + 24]
    mov edx, [rsp + 28]
    mov ecx, r13d
    mov r8d, r13d
    COLOR r9d, T_MUTED
    call ui_icon_center
    test dword ptr [rsp + 32], UB_CLICK
    jz .Ltd_next
    mov rdi, rbx
    call app_close_tab
    jmp .Ltd_done
841:
.Ltd_next:
    add r12d, [rsp + 16]
    inc rbx
    jmp .Ltd_tab
.Ltd_done:
    # clamp scroll so the strip cannot scroll past its end
    mov eax, r12d
    add eax, [rip + g_tabscroll]
    sub eax, [rsp]
    sub eax, [rsp + 8]
    jg 9f
    mov dword ptr [rip + g_tabscroll], 0
9:  call gfx_clip_pop
    EPILOGUE

# statusbar_draw(x, y, w, h)
FN statusbar_draw
    PROLOGUE 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    COLOR r8d, T_STATUS
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    # the updater's item at the right end; the rest keeps left of it
    mov edi, [rsp]
    add edi, [rsp + 8]
    sub edi, [rip + g_mt + 4*MI_12]
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    call statusbar_update
    mov [rsp + 20], eax
    # Keep branch and position glyphs out of the updater's reserved area.
    mov edx, eax
    sub edx, [rsp]
    add edx, [rip + g_mt + 4*MI_12]
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    # the branch at the left end; the file's items follow it
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 20]
    add ecx, [rip + g_mt + 4*MI_12]
    call statusbar_branch
    mov [rsp + 24], eax
    call app_image
    test rax, rax
    jz 1f
    mov rdi, [rip + g_file]
    mov esi, [rsp + 24]
    sub esi, [rip + g_mt + 4*MI_12]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 20]
    add ecx, [rip + g_mt + 4*MI_12]
    sub ecx, esi
    mov r8d, [rsp + 12]
    call iv_status
    jmp 9f
1:  mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    lea rdi, [rip + tmp_sb]
    call sb_clear
    # "Ln x, Col y"
    lea rdi, [rip + tmp_sb]
    lea rsi, [rip + .Lln]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    lea rdi, [rip + tmp_sb]
    lea rsi, [rax + 1]
    call sb_push_u64
    lea rdi, [rip + tmp_sb]
    lea rsi, [rip + .Lcol]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_col_of
    lea rdi, [rip + tmp_sb]
    lea esi, [rax + 1]
    call sb_push_u64
    mov rdi, rbx
    call vim_sel
    sub rdx, rax
    jz 1f
    mov r12, rdx
    lea rdi, [rip + tmp_sb]
    lea rsi, [rip + .Lsel_open]
    call sb_push_cstr
    lea rdi, [rip + tmp_sb]
    mov rsi, r12
    call sb_push_u64
    lea rdi, [rip + tmp_sb]
    lea rsi, [rip + .Lsel_close]
    call sb_push_cstr
1:  mov esi, [rsp + 24]
    mov [rsp + 16], esi
    # vim: the command line in place of the position, else the mode and the keys typed so far
    cmp dword ptr [rip + cfg_vim], 0
    je 11f
    cmp dword ptr [rip + g_vim_cmdline], 0
    je 10f
    mov edi, [rsp + 16]
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    call vim_cmdline_draw
    mov eax, [rsp + 20]
    mov [rsp + 28], eax        # command line occupies the available status area
    jmp 12f
10: call vim_status
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, rax
    COLOR r9d, T_ACCENT
    call ui_text_c
    add eax, [rip + g_mt + 4*MI_16]
    mov [rsp + 16], eax
11: lea rdi, [rip + g_face_small]
    mov esi, [rsp + 16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, [rip + tmp_sb + SB_ptr]
    mov r9, [rip + tmp_sb + SB_len]
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    add eax, [rip + g_mt + 4*MI_16]
    mov [rsp + 28], eax        # optional metadata must stay after the position
12: # right side: language, indentation, eol, encoding
    mov r12d, [rsp + 20]
    lea r13, [rip + .Lutf8]
    call .Lsb_item
    lea r13, [rip + .Llf]
    cmp dword ptr [rbx + DOC_crlf], 0
    je 2f
    lea r13, [rip + .Lcrlf]
2:  call .Lsb_item
    lea r13, [rip + .Ltabs]
    cmp dword ptr [rip + cfg_insert_spaces], 0
    je 3f
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lspaces]
    call cstr_copy
    mov rdi, rax
    mov esi, [rip + cfg_tab_width]
    call fmt_u64
    mov byte ptr [rdi], 0      # fmt_u64 leaves rdi after the digits
    lea r13, [rsp + 32]
3:  call .Lsb_item
    lea r13, [rip + .Lplain]
    mov rax, [rbx + DOC_lang]
    test rax, rax
    jz 4f
    mov r13, [rax + GR_name]
4:  mov r14d, r12d
    call .Lsb_item
    cmp r12d, r14d
    je 9f                     # no picker hitbox for a label that did not fit
    # the language name opens the language picker
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_12]
    mov ecx, r14d
    sub ecx, esi
    add ecx, [rip + g_mt + 4*MI_8]
    mov edi, ID_STATUS
    mov edx, [rsp + 4]
    M r8d, MI_STATUS
    call ui_btn
    test eax, UB_HOVER
    jz 5f
    mov dword ptr [rip + g_cursor], CUR_POINTER
5:  test eax, UB_CLICK
    jz 9f
    call cmd_select_language
9:  call gfx_clip_pop
    EPILOGUE
# statusbar_branch(x, y, h, right) -> eax the x where the file's items start: the branch and, in a linked
# work tree, its folder at the left end; a click opens the history
statusbar_branch:
    PROLOGUE 176                # [rsp + 16..159] text, [rsp + 160] right bound
    mov [rsp], esi              # y
    mov [rsp + 4], edx          # h
    mov [rsp + 160], ecx        # bound the hitbox before the updater
    M r12d, MI_12
    add r12d, edi               # x
    cmp byte ptr [rip + g_branch], 0
    je 9f
    # "main", or "main · worktree NAME"
    lea rdi, [rsp + 16]
    lea rsi, [rip + g_branch]
    call cstr_copy
    cmp byte ptr [rip + g_worktree], 0
    je 1f
    mov rdi, rax
    lea rsi, [rip + .Lsb_worktree]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + g_worktree]
    call cstr_copy
1:  lea rdi, [rsp + 16]
    call strlen
    mov r14, rax
    lea rdi, [rip + g_face_small]
    lea rsi, [rsp + 16]
    mov rdx, rax
    call text_width
    M r13d, MI_14               # icon size
    lea r15d, [rax + r13]
    add r15d, [rip + g_mt + 4*MI_6]   # the icon, a gap, the text
    # the button: MI_6 more on each side, inset from the bar like the updater's item
    mov eax, r15d
    add eax, [rip + g_mt + 4*MI_12]
    mov ecx, [rsp + 160]
    sub ecx, r12d
    add ecx, [rip + g_mt + 4*MI_6]
    xor edx, edx
    test ecx, ecx
    cmovl ecx, edx
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 8], eax          # w
    mov eax, [rsp + 4]
    sub eax, [rip + g_mt + 4*MI_6]
    mov [rsp + 12], eax         # h
    mov edi, ID_STATUS + 2
    mov esi, r12d
    sub esi, [rip + g_mt + 4*MI_6]
    mov edx, [rsp]
    add edx, [rip + g_mt + 4*MI_3]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call ui_btn
    mov ebx, eax
    test ebx, UB_HOVER
    jz 2f
    mov dword ptr [rip + g_cursor], CUR_POINTER
    mov edi, r12d
    sub edi, [rip + g_mt + 4*MI_6]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_3]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
2:  mov edi, ID_STATUS + 2
    mov esi, r12d
    sub esi, [rip + g_mt + 4*MI_6]
    mov edx, [rsp]
    add edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, ebx
    call tip_note
    mov edi, IC_BRANCH
    mov esi, r12d
    mov edx, [rsp + 4]
    sub edx, r13d
    sar edx, 1
    add edx, [rsp]
    mov ecx, r13d
    COLOR r8d, T_MUTED
    test ebx, UB_HOVER
    jz 3f
    COLOR r8d, T_FG
3:  call icon_draw
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    add esi, r13d
    add esi, [rip + g_mt + 4*MI_6]
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    lea r8, [rsp + 16]
    mov r9, r14
    COLOR eax, T_MUTED
    test ebx, UB_HOVER
    jz 4f
    COLOR eax, T_FG
4:  push rax
    push rax
    call ui_text_v
    add rsp, 16
    test ebx, UB_CLICK
    jz 5f
    call cmd_toggle_git
5:  add r12d, r15d
    add r12d, [rip + g_mt + 4*MI_20]
9:  mov eax, r12d
    EPILOGUE

# statusbar_update(right, y, h) -> eax the right edge left of it: the updater's item, when it has one
statusbar_update:
    PROLOGUE 16
    mov r12d, edi
    mov [rsp], esi
    mov [rsp + 4], edx
    call update_item
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, rax
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r13
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_16]
    mov r14d, eax               # w
    sub r12d, eax               # x
    mov eax, [rsp]
    add eax, [rip + g_mt + 4*MI_3]
    mov [rsp + 8], eax          # box y
    mov eax, [rsp + 4]
    sub eax, [rip + g_mt + 4*MI_6]
    mov [rsp + 12], eax         # box h
    mov edi, ID_STATUS + 1
    mov esi, r12d
    mov edx, [rsp + 8]
    mov ecx, r14d
    mov r8d, [rsp + 12]
    call ui_btn
    mov r15d, eax
    test eax, UB_HOVER
    jz 1f
    mov dword ptr [rip + g_cursor], CUR_POINTER
1:  mov edi, r12d
    mov esi, [rsp + 8]
    mov edx, r14d
    mov ecx, [rsp + 12]
    M r8d, MI_RADIUS
    COLOR r9d, T_ACCENT
    COLOR eax, T_STATUS
    test r15d, UB_HOVER
    jz 2f
    COLOR eax, T_HOVER
2:  push rax
    push rax
    call gfx_frame
    add rsp, 16
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, [rsp + 8]
    mov ecx, r14d
    mov r8d, [rsp + 12]
    mov r9, r13
    COLOR eax, T_ACCENT
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    test r15d, UB_CLICK
    jz 3f
    call update_click
3:  sub r12d, [rip + g_mt + 4*MI_20]
9:  mov eax, r12d
    EPILOGUE

# right-aligned status item: r13 cstr, r12d right edge (moves left)
.Lsb_item:
    push rbx
    mov rdi, r13
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r13
    mov rdx, rax
    call text_width
    mov edx, r12d
    sub edx, eax
    cmp edx, [rsp + 16 + 28]
    jl 9f                     # leave room for the cursor label and earlier items
    sub r12d, eax
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, [rsp + 16 + 4]
    mov ecx, [rsp + 16 + 12]
    mov r8, r13
    COLOR r9d, T_MUTED
    call ui_text_c
    sub r12d, [rip + g_mt + 4*MI_20]
9:  pop rbx
    ret

# welcome_draw(x, y, w, h)
FN welcome_draw
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    COLOR r8d, T_BG
    call gfx_fill
    # wordmark
    mov eax, [rsp + 12]
    shr eax, 1
    add eax, [rsp + 4]
    sub eax, [rip + g_mt + 4*MI_64]
    sub eax, [rip + g_mt + 4*MI_48]
    mov r12d, eax
    # the rune and "rhûn", centered together; the rune is as tall as the h
    mov eax, [rip + g_face_huge + FACE_px]
    imul eax, eax, 11
    xor edx, edx
    mov ecx, 9
    div ecx
    mov [rsp + 20], eax         # icon box
    imul eax, eax, 43
    shr eax, 7
    mov [rsp + 24], eax         # visible rune width
    lea rdi, [rip + g_face_huge]
    lea rsi, [rip + .Lrhun]
    mov edx, RHUN_LEN
    call text_width
    mov [rsp + 28], eax
    mov eax, [rsp + 20]
    shr eax, 2
    mov [rsp + 32], eax         # gap
    add eax, [rsp + 24]
    add eax, [rsp + 28]
    mov ecx, [rsp + 8]
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp]
    mov [rsp + 36], ecx         # left edge of the group
    mov esi, [rsp + 20]
    imul esi, esi, 42
    sar esi, 7
    neg esi
    add esi, ecx                # icon box x
    M eax, MI_48
    shr eax, 1
    mov edx, r12d
    sub edx, [rip + g_mt + 4*MI_20]
    add edx, eax
    mov eax, [rsp + 20]
    shr eax, 1
    sub edx, eax                # icon box y: centered on the text row,
    mov eax, [rsp + 20]
    shr eax, 5
    sub edx, eax                # then up a little to sit on the baseline
    mov edi, IC_RUNE
    mov ecx, [rsp + 20]
    COLOR r8d, T_ACCENT
    call icon_draw
    lea rdi, [rip + g_face_huge]
    mov esi, [rsp + 36]
    add esi, [rsp + 24]
    add esi, [rsp + 32]
    mov edx, r12d
    sub edx, [rip + g_mt + 4*MI_20]
    M ecx, MI_48
    lea r8, [rip + .Lrhun]
    mov r9d, RHUN_LEN
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    add r12d, [rip + g_mt + 4*MI_40]
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    mov edx, r12d
    mov ecx, [rsp + 8]
    M r8d, MI_20
    lea r9, [rip + g_version_text]
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    add r12d, [rip + g_mt + 4*MI_48]
    # shortcut rows
    lea rbx, [rip + welcome_rows]
    xor r15d, r15d
1:  mov r13, [rbx]
    test r13, r13
    jz 9f
    M r14d, MI_32
    # row: label right-aligned to the center, keys left-aligned after it
    mov eax, [rsp + 8]
    shr eax, 1
    add eax, [rsp]
    mov [rsp + 16], eax         # center x
    mov rdi, r13
    call strlen
    lea rdi, [rip + g_face_ui]
    mov rsi, r13
    mov rdx, rax
    call text_width
    mov esi, [rsp + 16]
    sub esi, eax
    sub esi, [rip + g_mt + 4*MI_12]
    # clickable
    lea edi, [r15 + ID_WELCOME]
    push rsi
    push rsi
    mov esi, [rsp + 16 + 16]
    sub esi, [rip + g_mt + 4*MI_64]
    sub esi, [rip + g_mt + 4*MI_64]
    sub esi, [rip + g_mt + 4*MI_32]
    mov edx, r12d
    M ecx, MI_64
    shl ecx, 2
    mov r8d, r14d
    call ui_btn
    mov [rsp + 40 + 16], eax
    pop rsi
    pop rsi
    COLOR r9d, T_MUTED
    test dword ptr [rsp + 40], UB_HOVER
    jz 2f
    COLOR r9d, T_FG
2:  lea rdi, [rip + g_face_ui]
    mov edx, r12d
    mov ecx, r14d
    mov r8, r13
    call ui_text_c
    # key chip
    mov r13, [rbx + 8]
    mov rdi, r13
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r13
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_16]
    mov edx, eax
    mov edi, [rsp + 16]
    add edi, [rip + g_mt + 4*MI_12]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_6]
    mov ecx, r14d
    sub ecx, [rip + g_mt + 4*MI_12]
    M r8d, MI_4
    COLOR r9d, T_HOVER
    call gfx_round_rect
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 16]
    add esi, [rip + g_mt + 4*MI_20]
    mov edx, r12d
    mov ecx, r14d
    mov r8, r13
    COLOR r9d, T_FG
    call ui_text_c
    test dword ptr [rsp + 40], UB_CLICK
    jz 3f
    call [rbx + 16]
3:  add r12d, r14d
    add rbx, 24
    inc r15d
    jmp 1b
9:  EPILOGUE

# ---------------- dialog ----------------

FN dialog_draw
    PROLOGUE 64
    cmp dword ptr [rip + dlg_kind], 0
    je .Ldd_ret
    # scrim
    xor edi, edi
    xor esi, esi
    mov edx, [rip + g_cv + CV_w]
    mov ecx, [rip + g_cv + CV_h]
    mov r8d, 0x60000000
    call gfx_fill
    mov edi, 420
    call sc
    mov r12d, eax               # w
    # Confirmation details can include model names or file paths. Size to the
    # content where space allows, and fit the line inside the visible dialog.
    cmp dword ptr [rip + dlg_kind], 4
    jne 8f
    mov rdi, [rip + dlg_text]
    call strlen
    mov rdx, rax
    mov rsi, [rip + dlg_text]
    lea rdi, [rip + g_face_small]
    call text_width
    add eax, [rip + g_mt + 4*MI_40]
    cmp eax, r12d
    cmovg r12d, eax
    mov eax, [rip + g_cv + CV_w]
    sub eax, [rip + g_mt + 4*MI_40]
    cmp r12d, eax
    cmovg r12d, eax
8:
    mov edi, 150
    call sc
    mov r13d, eax               # h
    mov eax, [rip + g_cv + CV_w]
    sub eax, r12d
    sar eax, 1
    mov r14d, eax               # x
    mov eax, [rip + g_cv + CV_h]
    sub eax, r13d
    sar eax, 1
    sub eax, [rip + g_mt + 4*MI_48]
    mov r15d, eax               # y
    mov edi, r14d
    mov esi, r15d
    mov edx, r12d
    mov ecx, r13d
    call ui_card
    # title
    lea rdi, [rip + tmp_sb]
    call sb_clear
    cmp dword ptr [rip + dlg_kind], 4
    jne 1f
    lea rdi, [rip + tmp_sb]
    mov rsi, [rip + dlg_title]
    call sb_push_cstr
    jmp 2f
1:  lea rdi, [rip + tmp_sb]
    lea rsi, [rip + .Ldlg_q]
    call sb_push_cstr
    mov rdi, [rip + dlg_tab]
    call tab_at
    mov rax, [rax + TAB_doc]
    lea rdi, [rip + tmp_sb]
    mov rsi, [rax + DOC_name]
    call sb_push_cstr
    lea rdi, [rip + tmp_sb]
    mov esi, '?'
    call sb_push_byte
2:  mov eax, r12d
    sub eax, [rip + g_mt + 4*MI_40]
    push rax
    COLOR eax, T_FG
    push rax
    lea rdi, [rip + g_face_ui]
    mov esi, r14d
    add esi, [rip + g_mt + 4*MI_20]
    mov edx, r15d
    add edx, [rip + g_mt + 4*MI_16]
    M ecx, MI_24
    mov r8, [rip + tmp_sb + SB_ptr]
    mov r9, [rip + tmp_sb + SB_len]
    call ui_text_v_fit
    add rsp, 16
    lea r8, [rip + .Ldlg_msg]
    cmp dword ptr [rip + dlg_kind], 4
    jne 3f
    mov r8, [rip + dlg_text]
3:  mov [rsp + 16], r8
    mov rdi, r8
    call strlen
    mov r9, rax
    mov eax, r12d
    sub eax, [rip + g_mt + 4*MI_40]
    push rax
    COLOR eax, T_MUTED
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, r14d
    add esi, [rip + g_mt + 4*MI_20]
    mov edx, r15d
    add edx, [rip + g_mt + 4*MI_40]
    M ecx, MI_24
    mov r8, [rsp + 32]
    call ui_text_v_fit
    add rsp, 16
    # buttons: Save (primary), Don't Save, Cancel
    M ebx, MI_32
    mov eax, r15d
    add eax, r13d
    sub eax, ebx
    sub eax, [rip + g_mt + 4*MI_16]
    mov [rsp], eax              # button y
    mov eax, r14d
    add eax, r12d
    sub eax, [rip + g_mt + 4*MI_16]
    mov [rsp + 4], eax          # right edge
    xor ecx, ecx
    mov [rsp + 8], ecx
.Ldd_btn:
    mov ecx, [rsp + 8]
    cmp ecx, 3
    jae .Ldd_ret
    lea rax, [rip + dlg_labels]
    mov r13, [rax + rcx*8]
    # a question: Cancel and its button
    cmp dword ptr [rip + dlg_kind], 4
    jne 0f
    cmp ecx, 1
    je 4f
    cmp ecx, 2
    jne 0f
    mov r13, [rip + dlg_ok]
0:  mov rdi, r13
    call strlen
    lea rdi, [rip + g_face_ui]
    mov rsi, r13
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_32]
    mov [rsp + 12], eax         # button w
    mov esi, [rsp + 4]
    sub esi, eax
    mov [rsp + 16], esi
    mov [rsp + 4], esi
    mov eax, [rip + g_mt + 4*MI_8]
    sub [rsp + 4], eax
    mov edi, [rsp + 8]
    add edi, ID_DLG
    mov edx, [rsp]
    mov ecx, [rsp + 12]
    mov r8d, ebx
    call ui_btn
    mov [rsp + 20], eax
    # style: last drawn (index 2) is the primary Save button
    mov edi, [rsp + 16]
    mov esi, [rsp]
    mov edx, [rsp + 12]
    mov ecx, ebx
    M r8d, MI_RADIUS
    cmp dword ptr [rsp + 8], 2
    jne 1f
    COLOR r9d, T_ACCENT
    COLOR eax, T_ACCENT
    jmp 2f
1:  COLOR r9d, T_BORDER
    COLOR eax, T_POPUP
    test dword ptr [rsp + 20], UB_HOVER
    jz 2f
    COLOR eax, T_HOVER
2:  push rax
    push rax
    call gfx_frame
    add rsp, 16
    COLOR eax, T_FG
    cmp dword ptr [rsp + 8], 2
    jne 3f
    COLOR eax, T_ACCENT_FG
3:  lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 16]
    mov edx, [rsp]
    mov ecx, [rsp + 12]
    mov r8d, ebx
    mov r9, r13
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    test dword ptr [rsp + 20], UB_CLICK
    jz 4f
    mov edi, [rsp + 8]
    call dialog_choose
    jmp .Ldd_ret
4:  inc dword ptr [rsp + 8]
    jmp .Ldd_btn
.Ldd_ret:
    EPILOGUE

# dialog_choose(i): 0 cancel, 1 don't save, 2 save (or app_confirm's button)
dialog_choose:
    PROLOGUE
    mov ebx, edi
    mov r12d, [rip + dlg_kind]
    mov dword ptr [rip + dlg_kind], 0
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    cmp r12d, 4
    jne 0f
    mov rax, [rip + dlg_cancel]
    mov qword ptr [rip + dlg_cancel], 0
    cmp ebx, 2
    je 5f
    test rax, rax
    jz 9f
    call rax
    jmp 9f
5:  call [rip + dlg_fn]
    jmp 9f
0:  test ebx, ebx
    jz 8f
    cmp ebx, 2
    jne 1f
    mov rdi, [rip + dlg_tab]
    call tab_at
    mov rbx, [rax + TAB_doc]
    cmp qword ptr [rbx + DOC_path], 0
    je 2f
    mov rdi, rbx
    call doc_readonly
    test eax, eax
    jnz 6f
    mov rdi, rbx
    call doc_save
    test rax, rax
    js 7f
    jmp 1f
2:  call cmd_save_as
    jmp 8f
6:  # a read-only file asks first: Overwrite saves it and goes on, Cancel stops here
    mov [rip + ro_kind], r12d
    mov rdi, rbx
    lea rsi, [rip + close_readonly_confirmed]
    call ask_readonly
    lea rax, [rip + unsaved_kept]
    mov [rip + dlg_cancel], rax
    jmp 9f
1:  mov edi, r12d
    call unsaved_done
    jmp 9f
7:  # the file stays open and modified: say why
    lea rdi, [rip + .Lsave_failed]
    call app_toast
8:  call unsaved_kept
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# unsaved_done(kind): the file asked about (dlg_tab) is saved or let go: close it and go on with what
#   asked (dlg_kind)
unsaved_done:
    push rbx
    mov ebx, edi
    mov rdi, [rip + dlg_tab]
    call app_close_tab_now
    cmp ebx, 3
    jne 1f
    pop rbx
    jmp switch_continue
1:  cmp ebx, 2
    jne 2f
    pop rbx
    jmp cmd_quit
2:  cmp ebx, 5
    jne 3f
    pop rbx
    jmp cmd_close_all
3:  pop rbx
    ret

# unsaved_kept(): not quitting after all: no restart into an update either, no other project, and the
#   session is saved again when it comes to that
unsaved_kept:
    mov dword ptr [rip + g_restart], 0
    mov dword ptr [rip + switch_pending], 0
    mov dword ptr [rip + g_session_final], 0
    ret

# close_readonly_confirmed(): Overwrite, for a close or quit that asked to save a read-only file
close_readonly_confirmed:
    PROLOGUE
    mov rdi, [rip + dlg_tab]
    call tab_at
    mov rdi, [rax + TAB_doc]
    call doc_save_readonly
    test rax, rax
    js 1f
    mov edi, [rip + ro_kind]
    call unsaved_done
    jmp 9f
1:  lea rdi, [rip + .Lsave_failed]
    call app_toast
    call unsaved_kept
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# dialog_key(keysym)
dialog_key:
    cmp edi, KEY_ESCAPE
    jne 1f
    xor edi, edi
    jmp dialog_choose
1:  cmp edi, KEY_RETURN
    jne 2f
    mov edi, 2
    jmp dialog_choose
2:  ret

# app_confirm(question cstr, line cstr, button cstr, fn): a dialog with Cancel and the button, which calls
#   fn; the strings must last while it is open
FN app_confirm
    mov [rip + dlg_title], rdi
    mov [rip + dlg_text], rsi
    mov [rip + dlg_ok], rdx
    mov [rip + dlg_fn], rcx
    mov qword ptr [rip + dlg_cancel], 0
    mov dword ptr [rip + dlg_kind], 4
    mov dword ptr [rip + g_focus], FOCUS_DIALOG
    mov dword ptr [rip + g_dirty], 1
    ret

# ---------------- tooltips (debounced hover) ----------------
# A button notes itself while it is drawn and hovered; tip_commit, once everything is drawn,
# turns the frame's note into a pending tooltip, and tip_tick shows it after TIP_DELAY. Buttons
# with a tooltip are listed in tip_table.

# tip_note(id, x, y_bottom, w, flags) -> flags: remember the button if it is hovered
FN tip_note
    test r8d, UB_HOVER
    jz 1f
    mov [rip + tip_cand], edi
    mov [rip + tip_cx], esi
    mov [rip + tip_cy], edx
    mov [rip + tip_cw], ecx
1:  mov eax, r8d
    ret

# tip_note_text(id, x, y_bottom, w, flags, cstr) -> flags: tip_note for a button whose tooltip says
#   what it does now (a git command with its file); the text is copied and needs no tip_table entry
FN tip_note_text
    test r8d, UB_HOVER
    jz 9f
    mov [rip + tip_cand], edi
    mov [rip + tip_cx], esi
    mov [rip + tip_cy], edx
    mov [rip + tip_cw], ecx
    mov [rip + tip_text_id], edi
    lea rdi, [rip + tip_text]
    mov ecx, TIP_TEXT_MAX - 1
1:  mov al, [r9]
    test al, al
    jz 2f
    mov [rdi], al
    inc rdi
    inc r9
    dec ecx
    jnz 1b
2:  mov byte ptr [rdi], 0
9:  mov eax, r8d
    ret

# tip_commit(): a new button restarts the delay, the same button keeps it, none hides at once;
# so do a press, a drag, and the setting being off
FN tip_commit
    xor eax, eax
    cmp dword ptr [rip + cfg_tooltips], 0
    je 1f
    cmp dword ptr [rip + g_mdown], 0
    jne 1f
    test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jnz 1f
    mov eax, [rip + tip_cand]
1:  cmp eax, [rip + tip_id]
    je 9f
    mov ecx, [rip + tip_state]
    mov [rip + tip_id], eax
    mov dword ptr [rip + tip_state], TIP_PENDING
    push rax
    push rcx
    call time_ms
    mov rdx, rax
    pop rcx
    pop rax
    cmp ecx, TIP_SHOWN              # leaving a shown tip: the next one within TIP_GRACE skips the delay
    jne 3f
    mov [rip + tip_left], rdx
3:  test eax, eax
    jz 9f
    cmp ecx, TIP_SHOWN
    je 4f
    mov rcx, rdx
    sub rcx, [rip + tip_left]
    cmp rcx, TIP_GRACE
    jb 4f
    mov [rip + tip_since], rdx
    ret
4:  mov dword ptr [rip + tip_state], TIP_SHOWN
9:  ret

# tip_dismiss(): a key press hides the tooltip until the pointer reaches another button
FN tip_dismiss
    cmp dword ptr [rip + tip_id], 0
    je 1f
    mov dword ptr [rip + tip_state], TIP_DISMISSED
1:  ret

# tip_timeout() -> ms until a pending tooltip shows (0 when due), or -1
FN tip_timeout
    cmp dword ptr [rip + tip_id], 0
    je 2f
    cmp dword ptr [rip + tip_state], TIP_PENDING
    jne 2f
    sub rsp, 8
    call time_ms
    add rsp, 8
    sub rax, [rip + tip_since]
    mov ecx, TIP_DELAY
    sub rcx, rax
    xor eax, eax
    test rcx, rcx
    cmovg eax, ecx             # already due: wake at once, tip_tick shows it
    ret
2:  mov eax, -1
    ret

# tip_tick(): show the pending tooltip once its delay has passed
FN tip_tick
    cmp dword ptr [rip + tip_id], 0
    je 1f
    cmp dword ptr [rip + tip_state], TIP_PENDING
    jne 1f
    sub rsp, 8
    call time_ms
    add rsp, 8
    sub rax, [rip + tip_since]
    cmp rax, TIP_DELAY
    jl 1f
    mov dword ptr [rip + tip_state], TIP_SHOWN
    mov dword ptr [rip + g_dirty], 1
1:  ret

# tip_find(id) -> rax entry of tip_table, or 0
tip_find:
    lea rax, [rip + tip_table]
1:  mov ecx, [rax]
    test ecx, ecx
    jz 2f
    cmp ecx, edi
    je 3f
    add rax, TT_SIZE
    jmp 1b
2:  xor eax, eax
3:  ret

# tip_current() -> rax the text of the tooltip on screen, or 0; rdx its tip_table entry, 0 for the
#   text of a tip_note_text button
tip_current:
    PROLOGUE
    xor ebx, ebx
    xor r12d, r12d
    cmp dword ptr [rip + tip_id], 0
    je 9f
    cmp dword ptr [rip + tip_state], TIP_SHOWN
    jne 9f
    call ctx_menu_list             # no tooltip over an open menu
    test rax, rax
    jnz 9f
    mov edi, [rip + tip_id]
    lea rbx, [rip + tip_text]
    cmp edi, [rip + tip_text_id]
    je 9f
    xor ebx, ebx
    call tip_find
    test rax, rax
    jz 9f
    mov r12, rax
    mov rbx, [rax + TT_text]
9:  mov rax, rbx
    mov rdx, r12
    EPILOGUE

# tip_print(sb): "tip=" and the text of the tooltip on screen (nothing when there is none)
FN tip_print
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ltip_eq]
    call sb_push_cstr
    call tip_current
    test rax, rax
    jz 1f
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
1:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# tip_draw(): the tooltip on top of everything: its text, then "(shortcut)" of the button's
# command as keys_for formats it (the user's binding, macOS symbols on the Mac); a text wider
# than the window is cut with "…"
FN tip_draw
    PROLOGUE 128                   # [rsp + 40] "(shortcut)", at most 2 + 63 bytes
    call tip_current
    test rax, rax
    jz 9f
    mov [rsp], rax
    mov qword ptr [rsp + 24], 0    # "(shortcut)", or 0
    test rdx, rdx
    jz 3f
    mov rdi, [rdx + TT_fn]
    test rdi, rdi
    jz 3f
    call cmd_for_fn
    test rax, rax
    jz 3f
    mov rdi, rax
    call keys_for
    test rax, rax
    jz 3f
    lea rdi, [rsp + 40]
    mov byte ptr [rdi], '('
    inc rdi
    mov rsi, rax
    call cstr_copy
    mov word ptr [rax], ')'        # ')' and the terminating zero
    lea rax, [rsp + 40]
    mov [rsp + 24], rax
3:  mov rdi, [rsp]
    call strlen
    mov [rsp + 8], rax             # text length
    lea rdi, [rip + g_face_small]
    mov rsi, [rsp]
    mov rdx, rax
    call text_width
    mov [rsp + 32], eax            # text width
    mov r12d, eax
    add r12d, [rip + g_mt + 4*MI_8]
    add r12d, [rip + g_mt + 4*MI_8]
    cmp qword ptr [rsp + 24], 0
    je 4f
    mov rdi, [rsp + 24]
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, [rsp + 24]
    mov rdx, rax
    call text_width
    add r12d, eax
    add r12d, [rip + g_mt + 4*MI_8]
4:  # no wider than the window: the text gives up what does not fit
    mov eax, [rip + g_cv + CV_w]
    sub eax, [rip + g_mt + 4*MI_8]
    mov ecx, r12d
    sub ecx, eax
    jle 41f
    sub [rsp + 32], ecx
    mov r12d, eax
41: M ebx, MI_24
    # centered under the button, kept inside the window
    mov esi, [rip + tip_cx]
    mov eax, [rip + tip_cw]
    shr eax, 1
    add esi, eax
    mov eax, r12d
    shr eax, 1
    sub esi, eax
    mov eax, [rip + g_cv + CV_w]
    sub eax, r12d
    sub eax, [rip + g_mt + 4*MI_4]
    cmp esi, eax
    cmovg esi, eax
    M eax, MI_4
    cmp esi, eax
    cmovl esi, eax
    mov [rsp + 16], esi
    mov eax, [rip + tip_cy]
    add eax, [rip + g_mt + 4*MI_4]
    # no room below (the status bar's buttons): above the button instead
    lea ecx, [rax + rbx]
    cmp ecx, [rip + g_cv + CV_h]
    jle 5f
    mov eax, [rip + tip_cy]
    sub eax, [rip + g_mt + 4*MI_STATUS]
    sub eax, [rip + g_mt + 4*MI_4]
    sub eax, ebx
5:  mov [rsp + 20], eax
    mov edi, esi
    mov esi, eax
    mov edx, r12d
    mov ecx, ebx
    M r8d, MI_4                    # a tooltip-sized shadow, corners like the buttons
    M r9d, MI_1
    M eax, MI_RADIUS
    push rax
    push rax
    call ui_card_shadow
    add rsp, 16
    mov eax, [rsp + 32]
    push rax
    COLOR eax, T_FG
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 16 + 16]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 20 + 16]
    mov ecx, ebx
    mov r8, [rsp + 16]
    mov r9, [rsp + 8 + 16]
    call ui_text_v_fit
    add rsp, 16
    cmp qword ptr [rsp + 24], 0
    je 9f
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 16]
    add esi, [rip + g_mt + 4*MI_8]
    add esi, [rsp + 32]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 20]
    mov ecx, ebx
    mov r8, [rsp + 24]
    COLOR r9d, T_MUTED
    call ui_text_c
9:  EPILOGUE

# ---------------- toast ----------------

toast_draw:
    PROLOGUE 16
    cmp qword ptr [rip + g_toast_until], 0
    je 9f
    lea rdi, [rip + g_toast]
    call strlen
    mov r13, rax
    lea rdi, [rip + g_face_small]
    lea rsi, [rip + g_toast]
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_24]
    mov r12d, eax               # w
    M ebx, MI_28                # h
    mov edi, [rip + g_editor_rect]
    add edi, [rip + g_editor_rect + 8]
    sub edi, r12d
    sub edi, [rip + g_mt + 4*MI_24]
    mov [rsp], edi
    mov esi, [rip + g_cv + CV_h]
    sub esi, [rip + g_mt + 4*MI_STATUS]
    sub esi, ebx
    sub esi, [rip + g_mt + 4*MI_12]
    mov [rsp + 4], esi
    mov edx, r12d
    mov ecx, ebx
    call ui_card
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, ebx
    lea r9, [rip + g_toast]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
9:  EPILOGUE

# ---------------- misc commands ----------------

FN cmd_toggle_sidebar
    mov eax, 1
    lea rcx, [rip + cfg_sidebar]
    jmp toggle_panel

FN cmd_toggle_agents
    mov eax, 2
    lea rcx, [rip + cfg_agents]
    jmp toggle_panel

# toggle_panel(bit eax, setting rcx): a panel hidden in this window alone comes back, and the setting
# turns on only if it was off; any other panel flips its setting
toggle_panel:
    test [rip + panels_hidden], eax
    jz 1f
    not eax
    and [rip + panels_hidden], eax
    cmp dword ptr [rcx], 0
    jne app_sync_panels
1:  xor dword ptr [rcx], 1
    mov dword ptr [rip + g_settings_changed], 1
    jmp app_sync_panels

# app_hide_panels(): a window started with files alone is for editing them: the explorer and the
# agents panel stay out of it, whatever the settings say, until shown or a folder is opened
FN app_hide_panels
    mov dword ptr [rip + panels_hidden], 3
    jmp app_sync_panels

# app_reveal_panel(bit): 1 the explorer, 2 the agents panel follows its setting again in this window
FN app_reveal_panel
    not edi
    and [rip + panels_hidden], edi
    jmp app_sync_panels

# app_sync_panels(): g_show_side and g_show_agents from the settings and panels_hidden
FN app_sync_panels
    mov eax, [rip + cfg_sidebar]
    test dword ptr [rip + panels_hidden], 1
    jz 1f
    xor eax, eax
1:  mov [rip + g_show_side], eax
    mov eax, [rip + cfg_agents]
    test dword ptr [rip + panels_hidden], 2
    jz 2f
    xor eax, eax
2:  mov [rip + g_show_agents], eax
    mov dword ptr [rip + g_dirty], 1
    ret

FN cmd_zoom_in
    mov esi, 1
    jmp zoom_focused

FN cmd_zoom_out
    mov esi, -1
    jmp zoom_focused

FN cmd_zoom_reset
    xor esi, esi
    jmp zoom_focused

# zoom_focused(dir): zoom only the focused terminal, otherwise the editor or image.
zoom_focused:
    cmp dword ptr [rip + g_focus], FOCUS_TERMINAL
    je .Lzoom_term
    call image_zoom
    jnz .Lzoom_done
    lea rdi, [rip + cfg_font_size]
    jmp .Lzoom_font
.Lzoom_term:
    lea rdi, [rip + cfg_term_font_size]
.Lzoom_font:
    mov eax, 14                # reset either font to its default size
    test esi, esi
    jz 1f
    mov eax, [rdi]
    add eax, esi
    mov edx, 8                 # both font size settings range over 8..40
    cmp eax, edx
    cmovl eax, edx
    mov edx, 40
    cmp eax, edx
    cmovg eax, edx
1:  mov [rdi], eax
    mov dword ptr [rip + g_settings_changed], 1
    mov dword ptr [rip + g_dirty], 1
.Lzoom_done:
    ret

# image_zoom(dir) -> ZF clear when an image tab took the zoom command (1 in, -1 out, 0 fit)
image_zoom:
    push rsi
    call app_image
    pop rsi
    test rax, rax
    jz 1f
    mov rdi, rax
    call iv_zoom_cmd
    or eax, 1
1:  ret

FN cmd_settings
    PROLOGUE
    # focus an existing settings tab
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 2f
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_SETTINGS
    je 3f
    inc rbx
    jmp 1b
2:  xor edi, edi
    mov esi, TAB_SETTINGS
    call app_add_tab
    jmp 4f
3:  mov rdi, rbx
    call app_activate_tab
4:  mov dword ptr [rip + g_focus], FOCUS_SETTINGS
    cmp dword ptr [rip + cfg_commit_ai], 0
    je 5f
    call cmd_ai_detect
5:  EPILOGUE

FN cmd_open_config
    PROLOGUE
    call config_path
    mov rbx, rax
    mov rdi, rax
    call file_mtime
    test rax, rax
    jnz 1f
    call config_save
1:  mov rdi, rbx
    call app_open_file
    EPILOGUE

FN cmd_toggle_whitespace
    xor dword ptr [rip + cfg_whitespace], 1
    mov dword ptr [rip + g_settings_changed], 1
    mov dword ptr [rip + g_dirty], 1
    ret

FN cmd_toggle_line_numbers
    xor dword ptr [rip + cfg_line_numbers], 1
    mov dword ptr [rip + g_settings_changed], 1
    mov dword ptr [rip + g_dirty], 1
    ret

FN cmd_newline_below
    push rbx
    mov rdi, 5
    xor esi, esi
    call ed_move
    call ed_newline
    pop rbx
    ret

FN cmd_newline_above
    READONLY_RET
    PROLOGUE 272
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    # an empty line above with the indentation of this one, the cursor at its end
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    mov r13, rax
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov r12, rax
    mov rdi, rbx
    mov rsi, r13
    call line_indent
    mov r15, rax
    cmp rax, 200
    jbe 1f
    mov eax, 200
1:  mov r14, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    lea rcx, [rsp]
    call doc_copy
    # above a closing bracket: one level more (the block's content)
    lea rsi, [r12 + r15]
    mov rdi, rbx
    call doc_byte
    cmp eax, '}'
    je 2f
    cmp eax, ')'
    je 2f
    cmp eax, ']'
    jne 4f
2:  cmp dword ptr [rip + cfg_insert_spaces], 0
    jne 3f
    mov byte ptr [rsp + r14], 9
    inc r14
    jmp 4f
3:  mov ecx, [rip + cfg_tab_width]
    cmp ecx, 16
    jbe 31f
    mov ecx, 16
31: test ecx, ecx
    jz 4f
    mov byte ptr [rsp + r14], ' '
    inc r14
    dec ecx
    jmp 31b
4:  mov byte ptr [rsp + r14], 10
    mov [rbx + DOC_cur], r12
    mov [rbx + DOC_anchor], r12
    mov rdi, rbx
    lea rsi, [rsp]
    lea rdx, [r14 + 1]
    xor ecx, ecx
    call ed_insert
    lea rax, [r12 + r14]
    mov [rbx + DOC_cur], rax
    mov [rbx + DOC_anchor], rax
9:  EPILOGUE

FN cmd_indent
    mov edi, 1
    jmp ed_indent
FN cmd_outdent
    mov edi, -1
    jmp ed_indent
FN cmd_move_line_up
    mov edi, -1
    jmp ed_move_lines
FN cmd_move_line_down
    mov edi, 1
    jmp ed_move_lines

.section .rodata
.Lrhun: .asciz "rh\303\273n"      # the name as it is written in the interface
.Lempty: .asciz ""
.Lrestart_empty: .asciz "--empty"
.Ldash: .asciz " \342\200\224 "
.Lbinary: .asciz "Binary file, not opened"
.Lopen_failed: .asciz "Could not read the file"
.Lnot_regular: .asciz "Not a regular file, not opened"
.Lsaved: .asciz "Saved"
.Lsave_failed: .asciz "Could not save the file"
.Lro_a: .asciz "Overwrite read-only "
.Lro_b: .asciz "?"
.Lro_text: .asciz "The file is read-only. Overwriting replaces it, and it stays read-only."
.Lro_button: .asciz "Overwrite"
.Lsave_as: .asciz "Save as"
.Lsettings: .asciz "Settings"
.p2align 3
# tip_table: button, text, the handler it runs (0: not a command, no shortcut); 0 ends it
tip_table:
    .quad ID_GIT_BTN, .Ltip_git, cmd_toggle_git
    .quad ID_TOG_TERM, .Ltip_term, cmd_toggle_terminal
    .quad ID_TOG_AGENTS, .Ltip_agents, cmd_toggle_agents
    .quad ID_SETTINGS_BTN, .Ltip_settings, cmd_settings
    .quad ID_TOG_SIDE, .Ltip_side, cmd_toggle_sidebar
    .quad ID_EXP_NEW, .Ltip_exp_new, 0
    .quad ID_EXP_NEW_FOLDER, .Ltip_exp_new_folder, 0
    .quad ID_EXP_REFRESH, .Ltip_exp_refresh, 0
    .quad ID_STATUS + 2, .Ltip_git, cmd_toggle_git
    .quad 0, 0, 0
.Ltip_git: .asciz "Git history"
.Ltip_term: .asciz "Terminal"
.Ltip_agents: .asciz "Agents"
.Ltip_settings: .asciz "Settings"
.Ltip_side: .asciz "File explorer"
.Ltip_exp_new: .asciz "New file"
.Ltip_exp_new_folder: .asciz "New folder"
.Ltip_exp_refresh: .asciz "Refresh explorer"
.Ltip_eq: .asciz "tip="
.Lgit_tab: .asciz "Git"
.Lln: .asciz "Ln "
.Lcol: .asciz ", Col "
.Lsel_open: .asciz "  ("
.Lsel_close: .asciz " selected)"
.Lsb_worktree: .asciz " \302\267 worktree "
.Lutf8: .asciz "UTF-8"
.Llf: .asciz "LF"
.Lcrlf: .asciz "CRLF"
.Ltabs: .asciz "Tabs"
.Lspaces: .asciz "Spaces: "
.Lplain: .asciz "Plain Text"
.Ldlg_q: .asciz "Save changes to "
.Ldlg_msg: .asciz "Your changes will be lost if you don't save them."
.Lnl: .ascii "\n"
.Lw1: .asciz "Go to file"
.Lw2: .asciz "Command palette"
.Lw3: .asciz "New file"
.Lw4: .asciz "Settings"
.Lw5: .asciz "Toggle explorer"
.Lw6: .asciz "Toggle agents"
.Lw7: .asciz "Open file"
.Lw8: .asciz "Open folder"
.ifdef MACOS
.Lk1: .asciz "\342\214\230P"
.Lk2: .asciz "\342\207\247\342\214\230P"
.Lk3: .asciz "\342\214\230N"
.Lk4: .asciz "\342\214\230,"
.Lk5: .asciz "\342\214\230B"
.Lk6: .asciz "\342\207\247\342\214\230A"
.Lk7: .asciz "\342\214\230O"
.Lk8: .asciz "\342\207\247\342\214\230O"
.else
.Lk1: .asciz "Ctrl+P"
.Lk2: .asciz "Ctrl+Shift+P"
.Lk3: .asciz "Ctrl+N"
.Lk4: .asciz "Ctrl+,"
.Lk5: .asciz "Ctrl+B"
.Lk6: .asciz "Ctrl+Shift+A"
.Lk7: .asciz "Ctrl+O"
.Lk8: .asciz "Ctrl+Shift+O"
.endif
.Lpm_folder: .asciz "Open Folder\342\200\246"
.Lnew_window_failed: .asciz "Could not open a new window"
.ifndef WINDOWS
.Lenv_new_window: .asciz "RHUN_NEW_WINDOW"
.Ldevnull: .asciz "/dev/null"
.ifndef MACOS
.Lproc_self_exe: .asciz "/proc/self/exe"
.Ldeleted: .asciz " (deleted)"
.endif
.endif
.Lpm_file: .asciz "Open File\342\200\246"
.Lpm_line: .asciz ""
.Ld0: .asciz "Cancel"
.Ld1: .asciz "Don't Save"
.Ld2: .asciz "Save"
.p2align 3
welcome_rows:
    .quad .Lw1, .Lk1, cmd_quick_open
    .quad .Lw2, .Lk2, cmd_command_palette
    .quad .Lw3, .Lk3, cmd_new_file
    .quad .Lw7, .Lk7, cmd_open_file
    .quad .Lw8, .Lk8, cmd_open_folder
    .quad .Lw4, .Lk4, cmd_settings
    .quad .Lw5, .Lk5, cmd_toggle_sidebar
    .quad .Lw6, .Lk6, cmd_toggle_agents
    .quad 0
dlg_labels: .quad .Ld0, .Ld1, .Ld2

.data
g_win_focused: .long 1
# the panels this window shows: the settings, less those panels_hidden takes away (app_sync_panels)
.globl g_show_side, g_show_agents
g_show_side: .long 1
g_show_agents: .long 1
.p2align 3
g_tab_cur: .quad -1
.bss
panels_hidden: .long 0          # 1 the explorer, 2 the agents panel: hidden in a window started with files
.globl g_settings_changed, g_started
g_settings_changed: .long 0
g_started: .long 0              # the command line is open: later folders switch the project
g_tabscroll_reveal: .long 0

.text
# app_open_path(path): folder -> project, file -> tab (relative paths use the cwd)
FN app_open_path
    PROLOGUE 16
.ifdef WINDOWS
    call win_fullpath
    test rax, rax
    jnz 91f
    EPILOGUE
91: mov rbx, rax
    mov r13d, 1
    jmp 2f
.endif
    mov rbx, rdi
    # absolute path
    PATH_ABSOLUTE rbx, 1f
    sub rsp, 4096
    mov rdi, rsp
    mov esi, 4000
    SYS SYS_getcwd
    mov rdi, rsp
    mov rsi, rbx
    call path_join
    add rsp, 4096
    mov rbx, rax
    mov r13d, 1
    jmp 2f
1:  mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov rbx, rax
    mov r13d, 1
2:  mov rdi, rbx
    call path_normalize
    mov rdi, rbx
    call file_is_dir
    test eax, eax
    jz 3f
    # once started, a folder (Finder, the Dock, :e, open) takes up the window the way Open Folder
    # does: the project's session is saved and its unsaved files are asked about first
    mov rdi, rbx
    cmp dword ptr [rip + g_started], 0
    je 21f
    call app_switch_project
    jmp 8f
21: call app_set_project
    jmp 8f
3:  mov rdi, rbx
    call app_adopt_folder
    mov rdi, rbx
    call app_open_file
8:  test r13d, r13d
    jz 9f
    mov rdi, rbx
    call mem_free
9:  EPILOGUE
