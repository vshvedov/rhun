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
.equ ID_TAB_NEW, 0x200a           # the + after the last tab
.equ ID_TAB_END, 0x200b           # the strip's empty end
.equ ID_TRUST, 0x200c             # the trust bar's Trust folder button
.equ ID_TRUST_X, 0x200d           # and its close button
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
.equ ID_TIP_MD, 0x6b0000         # a Markdown tooltip's links (views group)
.equ TIP_TEXT_MAX, 4400          # bytes of a tip_note_text tooltip (a git command with a file's path)
.equ RHUN_LEN, 5                # bytes of "rhûn", the name on the welcome screen
.equ ID_WELCOME, 0x2a00          # + item

.bss
.p2align 3
.globl g_open_keep_tab
.globl g_focus, g_win_focused, g_tabs, g_tab_cur, g_project, g_project_name, g_branch
g_focus: .long 0
g_focus_prev: .long 0
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
tip_md_id: .long 0              # views group: the button whose tooltip is Markdown (tip_note_md) this frame
.p2align 3
tip_md: .quad 0                 # its MD* (markdown.s), noted again each frame it shows
tip_text: .zero TIP_TEXT_MAX
g_tabscroll: .long 0
tab_end_press: .long 0           # the last left press was on the tab strip's empty end
tab_drag: .long 0                # the tab held by the left button follows the pointer (tab_drag_step)
tab_grab: .long 0                # where along the tab the press took hold of it
tab_drag_x: .long 0              # where the dragged tab is drawn, and its width
tab_drag_w: .long 0
.p2align 3
tab_drag_kind: .quad 0           # the tab pressed: a drag follows it while it is the one at g_active
tab_drag_doc: .quad 0
menu_tab_kind: .quad 0           # the tab whose menu is open (tab_menu_tab)
menu_tab_doc: .quad 0
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
dlg_alt: .quad 0                 # app_confirm_alt: a middle button's label and function (AI: tools.s)
dlg_alt_fn: .quad 0
dlg_no: .quad 0                  #   and Cancel's label instead of Cancel
ro_doc: .quad 0                  # ask_readonly: the file asked about, and the question
ro_id: .quad 0
ro_save_flags: .quad 0
ro_save_kind: .quad 0
.globl app_save_epoch
app_save_epoch: .quad 0
save_prompt_id: .quad 0
save_prompt_kind: .quad 0
save_prompt_flags: .quad 0
ro_kind: .long 0                 # a close or quit that asked about it (dlg_kind), carried on after Overwrite
ro_close: .long 0                # vim's :wq asked: Overwrite closes the file too
ro_title: .zero 256
ro_path: .zero 4096              # Save As onto a read-only file: that path
ro_dir: .zero 4096
switch_pending: .long 0          # a project switch waits on unsaved files
switch_link: .long 0             # and a rhun:// link asked for it
g_open_keep_tab: .long 0         # app_open_file opens a tab of its own (ws_apply)
g_link_open: .long 0             # app_open_path is opening a rhun:// link's path (set_project notes it)
trust_closed: .long 0            # the trust bar was closed for this project
trust_sb: .zero SB_SIZE          # its text
trust_path: .zero 4096           # the repository's folder, as shown (~ for the home folder)
switch_path: .zero 4096
nw_exe: .zero 4096               # app_new_window: this program
.p2align 3
pm_items: .zero 16 * 27         # the project menu: 2 commands, a line, 9 folders, a line, Add Folder, the remote items
                                # (a line, 2 commands, 8 recent remotes; remoteui.s), the end
.globl g_shot_path
g_shot_path: .quad 0
tmp_sb: .zero SB_SIZE
split_grab: .long 0             # a divider's drag: the pointer's distance from it at the press
split_moved: .long 0            # and whether the pointer has moved since
split_reanchor: .long 0         # a double-click reset the width: the next frame takes hold anew
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
    call places_init            # the explorer is the sidebar's first section
    call notify_init            # notification cards take the keyboard through a place item
    call ext_init               # manifests: their commands take keys below
    call theme_exts_loaded      # and their themes: the one the settings name may be theirs
    call rview_init             # their declared views take their places
    call keys_init
    call vim_sync
    call watch_init
    call update_init
    call extupdate_init         # extension management: update state, crashed installs' folders
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
    # the terminal's: the editor's unless the config names another that loads
    mov qword ptr [rip + g_font_term], 0
    mov rdi, [rip + cfg_term_font]
    cmp byte ptr [rdi], 0
    je 9f
    call file_read_all
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call font_load
    mov [rip + g_font_term], rax
9:  EPILOGUE

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
    call remote_project_label   # remote hosts: "HOST: name"
    mov eax, [rip + g_link_open]
    mov [rip + g_project_link], eax
    mov dword ptr [rip + trust_closed], 0
    call workspace_reset        # resources group: the folders remembered with it (workspace.s)
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

FN cmd_new_window
    lea rdi, [rip + .Lempty_arg]
    jmp app_new_window

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
    mov eax, [rip + g_link_open]
    mov [rip + switch_link], eax
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
    call vfs_is_dir
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
    mov eax, [rip + switch_link]
    mov [rip + g_link_open], eax
    lea rdi, [rip + switch_path]
    call app_set_project
    mov dword ptr [rip + g_link_open], 0
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
2:  lea rax, [rip + .Lpm_line]  # resources group: Add Folder to Workspace (workspace.s), after the
    mov [rbx], rax              # recent folders so that they keep their places
    mov qword ptr [rbx + 8], 0
    lea rax, [rip + .Lpm_add_folder]
    mov [rbx + 16], rax
    lea rax, [rip + cmd_add_workspace_folder]
    mov [rbx + 24], rax
    add rbx, 32
    mov rdi, rbx               # remote hosts: Connect to Host, Attach to Container, recent remotes
    lea rsi, [rip + pm_items]
    call remote_menu_append
    mov rbx, rax
    mov qword ptr [rbx], 0
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
    # its session brings its tabs back, but none is saved while git is paused there: they follow it
    cmp dword ptr [rip + g_git_paused], 0
    je 4f
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
    jmp 43f
41: # while git is paused for a repository a link opened, the paths come back as links, so that git
    # stays paused after the restart (a folder with its slash)
    cmp dword ptr [rip + g_git_paused], 0
    je 43f
    mov r12d, 1
42: cmp r12, r13
    jae 43f
    mov rdi, [r14 + r12*8]
    xor esi, esi                # a file
    cmp r12, 1
    jne 44f
    cmp dword ptr [rip + g_project_adopted], 0
    jne 44f
    mov esi, 1                  # the project itself: a folder
44: call restart_link
    mov [r14 + r12*8], rax
    inc r12
    jmp 42b
43: mov qword ptr [r14 + r13*8], 0
    mov rax, r14
    EPILOGUE

# restart_link(path, folder) -> a new "rhun://file/..." link to path (with % ? # escaped), which
#   app_open_path reads back: a folder ends in a slash, and a file in :1:1, which the line and column
#   take, so that a name ending in :12 stays whole
restart_link:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [rip + tmp_sb]
    call sb_clear
    lea rdi, [rip + tmp_sb]
    lea rsi, [rip + .Lrestart_link]
    call sb_push_cstr
    cmp byte ptr [rbx], '/'
    je 1f
    lea rdi, [rip + tmp_sb]     # C:\x is rhun://file/C:\x
    mov esi, '/'
    call sb_push_byte
1:  movzx r13d, byte ptr [rbx]
    test r13d, r13d
    jz 3f
    cmp r13d, '%'
    je 2f
    cmp r13d, '?'
    je 2f
    cmp r13d, '#'
    je 2f
    lea rdi, [rip + tmp_sb]
    mov esi, r13d
    call sb_push_byte
    inc rbx
    jmp 1b
2:  lea rdi, [rip + tmp_sb]
    mov esi, '%'
    call sb_push_byte
    lea rax, [rip + hexdigits]
    mov ecx, r13d
    shr ecx, 4
    movzx esi, byte ptr [rax + rcx]
    lea rdi, [rip + tmp_sb]
    call sb_push_byte
    lea rax, [rip + hexdigits]
    mov ecx, r13d
    and ecx, 15
    movzx esi, byte ptr [rax + rcx]
    lea rdi, [rip + tmp_sb]
    call sb_push_byte
    inc rbx
    jmp 1b
3:  test r12d, r12d
    jz 31f
    lea rdi, [rip + tmp_sb]
    mov esi, '/'
    call sb_push_byte
    jmp 4f
31: lea rdi, [rip + tmp_sb]
    lea rsi, [rip + .Lline_one]
    call sb_push_cstr
4:  lea rdi, [rip + tmp_sb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + tmp_sb + SB_ptr]
    mov rsi, [rip + tmp_sb + SB_len]
    call mem_dup
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
    push rbx
    call app_sync_doc_1
    call ext_options_apply
    pop rbx
    ret
app_sync_doc_1:
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
    cmp rcx, TAB_NOTEBOOK       # notebooks: the selected cell's document
    jne 3f
    mov rdi, rdx
    call nb_active_doc
    mov [rip + g_doc], rax
    jmp 1f
3:  cmp rcx, TAB_DOC
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
    cmp dword ptr [rip + cfg_auto_save], AUTOSAVE_ON_FOCUS_CHANGE
    jne 1f
    mov rdi, [rip + g_doc]
    test rdi, rdi
    jz 1f
    call app_auto_save_doc
1:  pop rdi
    mov rax, [rip + g_doc]
    push rax
    mov [rip + g_tab_cur], rdi
    mov dword ptr [rip + g_exp_reveal], 1
    call app_sync_doc
    pop rax
    # a tab shows where it was scrolled, also away from the cursor: a reveal still asked for the
    # document shown before is that one's, for when it is shown again (only while it has a tab: it
    # may be freed already)
    cmp rax, [rip + g_doc]
    je 1f
    cmp dword ptr [rip + g_reveal], 0
    je 1f
    mov dword ptr [rip + g_reveal], 0
    test rax, rax
    jz 1f
    push rax
    mov rdi, rax
    call doc_tab
    pop rdi
    test rax, rax
    js 1f
    or dword ptr [rdi + DOC_flags], DF_REVEAL
1:  call watch_show
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    # the settings tab's keys go to its search field
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 2f
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_SETTINGS
    jne 2f
    mov dword ptr [rip + g_focus], FOCUS_SETTINGS
    call settings_focus
2:  mov dword ptr [rip + g_tabscroll_reveal], 1
    # the caret shows at once, as after a key
    call time_ms
    mov [rip + g_blink_t0], rax
    mov dword ptr [rip + g_dirty], 1
    jmp app_update_title

# app_update_title(): window title "name — project"
FN app_update_title
    PROLOGUE
    # the window takes its title once the command line or session is open: a session restoring ten
    # tabs set it ten times before the first frame (half a millisecond each on macOS)
    cmp dword ptr [rip + g_started], 0
    je 9f
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
1:  call wfold_title            # resources group: "app + lib" for two workspace folders or more
    mov rsi, rax
    test rsi, rsi
    jnz 2f
    lea rsi, [rip + .Lrhun]
2:  lea rdi, [rip + tmp_sb]
    call sb_push_cstr
    mov rdi, [rip + tmp_sb + SB_ptr]
    PCALL P_title
9:  EPILOGUE

# tab_dirty(TAB*) -> eax 1 when the tab holds unsaved changes: a document's, or a notebook's
FN tab_dirty
    mov rax, [rdi + TAB_kind]
    cmp rax, TAB_NOTEBOOK
    jne 1f
    push rbx
    mov rbx, [rdi + TAB_doc]
    mov rdi, [rbx + DOC_nb]
    call nb_sync_dirty
    pop rbx
    ret
1:  cmp rax, TAB_DOC
    je 2f
    cmp rax, TAB_VIEW           # custom editors: the document either model keeps dirty
    jne 8f
    test dword ptr [rdi + TAB_flags], TF_CUSTOM
    jz 8f
2:  mov rdi, [rdi + TAB_doc]
    jmp doc_dirty
8:  xor eax, eax
    ret

# doc_tab(doc) -> rax the index of its tab, or -1
FN doc_tab
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 2f
    mov rdi, rbx
    call tab_at
    cmp [rax + TAB_doc], r12
    je 3f
    inc rbx
    jmp 1b
2:  mov rbx, -1
3:  mov rax, rbx
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

# app_path_inside(path, dir) -> eax 1 when path is dir or names something inside it, compared as
#   app_find_tab compares paths, and rdx the length of path's part that names dir
.ifdef WINDOWS
# Windows: each part of path that ends at a separator (or all of it), after its root, against dir by
# win_path_equal: spellings that are the same without case may differ in length
FN app_path_inside
    PROLOGUE 4096
    mov r12, rdi
    mov r13, rsi
    call strlen
    mov r15, rax
    mov rdi, r12
    call path_rootlen
    mov r14, rax
    test r14, r14
    jnz 1f
    mov r14d, 1
1:  cmp r14, r15
    ja 8f
    je 2f
    movzx eax, byte ptr [r12 + r14]
    cmp eax, '/'
    je 2f
    cmp eax, 92
    je 2f
3:  inc r14
    jmp 1b
2:  cmp r14, 4096
    jae 8f
    mov rdi, rsp
    mov rsi, r12
    mov rcx, r14
    rep movsb
    mov byte ptr [rdi], 0
    mov rdi, rsp
    mov rsi, r13
    call win_path_equal
    test eax, eax
    jz 3b
    mov eax, 1
    mov rdx, r14
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
.else
FN app_path_inside
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, rsi
    call strlen
    mov r14, rax
    test r14, r14
    jz 8f
    cmp r14, 1                  # a folder written with its slash, but not / itself
    jbe 1f
    cmp byte ptr [r13 + r14 - 1], '/'
    jne 1f
    dec r14
1:  mov rdi, r12
    call strlen
    mov r15, rax
    cmp r15, r14
    jb 8f
    movzx eax, byte ptr [r12 + r14]
    test eax, eax
    jz 2f
    cmp eax, '/'
    je 2f
    cmp byte ptr [r13 + r14 - 1], '/'   # under a root such as /
    jne 8f
2:  mov rdi, r12
    mov rsi, r15
    mov rdx, r13
    mov rcx, r14
    call str_starts
    mov rdx, r14
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
.endif

# app_retarget_tabs(old, new): after a rename, the tabs of old, or of the files inside it when it
#   is a folder, take their paths under new
FN app_retarget_tabs
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
2:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 9f
    mov rdi, rbx
    call tab_at
    mov r15, [rax + TAB_doc]
    test r15, r15
    jz 3f
    mov rdi, [r15 + DOC_path]
    test rdi, rdi
    jz 3f
    mov rsi, r12
    call app_path_inside
    test eax, eax
    jz 3f
    mov r14, rdx                # the tab's own spelling of old ends there
    lea rdi, [rip + tmp_sb]
    call sb_clear
    mov rdi, r13                # the new name without a separator at its end ("e/" in the prompt)
    call strlen
    mov rdx, rax
4:  cmp rdx, 1
    jbe 5f
    cmp byte ptr [r13 + rdx - 1], '/'
.ifdef WINDOWS
    je 41f
    cmp byte ptr [r13 + rdx - 1], 92
.endif
    jne 5f
41: dec rdx
    jmp 4b
5:  lea rdi, [rip + tmp_sb]
    mov rsi, r13
    call sb_push
    lea rdi, [rip + tmp_sb]
    mov rsi, [r15 + DOC_path]
    add rsi, r14
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rip + tmp_sb + SB_ptr]
    call doc_set_path
3:  inc rbx
    jmp 2b
9:  call app_update_title
    mov dword ptr [rip + g_dirty], 1
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
    call vfs_type
    test eax, eax
    jz 12f
    cmp eax, 0x8000
    je 12f
    lea rdi, [rip + .Lnot_regular]
    call app_toast
    mov rax, -1
    EPILOGUE
12: # custom editors: a file an extension edits opens in its editor (customed.s)
    cmp dword ptr [rip + ce_open_text], 0
    jne 14f
    mov rdi, r12
    call ce_provider
    test rax, rax
    jz 14f
    mov rdi, r12
    mov rsi, rax
    call ce_open_tab
    EPILOGUE
14: # notebooks: a file an extension reads as a notebook opens in a notebook tab
    cmp dword ptr [rip + g_nb_open_text], 0
    jne 13f
    mov rdi, r12
    call nb_provider
    test rax, rax
    jz 13f
    mov rdi, r12
    mov rsi, rax
    call nb_open_tab
    EPILOGUE
13: mov r14d, TAB_DOC
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
    call vfs_stamp
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
    # custom editors: a binary file opens in an editor that edits it, an option one too
    mov rdi, rbx
    call doc_free
    mov rdi, r12
    call ce_provider_any
    test rax, rax
    jz 1f
    mov rdi, r12
    mov rsi, rax
    call ce_open_tab
    EPILOGUE
1:  lea rdi, [rip + .Lbinary]
    call app_toast
    mov rax, -1
    EPILOGUE
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
    # replace an untouched untitled tab, unless it is pinned (or a workspace edit opens files:
    # the untitled document may be one it changes)
    cmp dword ptr [rip + g_open_keep_tab], 0
    jne 3f
    mov rax, [rip + g_tab_cur]
    test rax, rax
    js 3f
    mov rdi, rax
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 3f
    test dword ptr [rax + TAB_flags], TF_PIN
    jnz 3f
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

# app_add_tab(doc, kind) -> index (inserted after the current tab, but after the pinned tabs, and
#   activated)
FN app_add_tab
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [rip + g_tabs]
    mov esi, TAB_SIZE
    call vec_push               # zeroed: not pinned
    mov [rax + TAB_kind], r12
    mov [rax + TAB_doc], rbx
    mov r13, [rip + g_tabs + VEC_len]
    dec r13                     # new slot index
    mov r14, [rip + g_tab_cur]
    inc r14                     # insert position
    call tabs_pinned
    cmp r14, rax
    cmovb r14, rax
    mov rdi, r13
    mov rsi, r14
    call tab_move
    mov rdi, r14
    call app_activate_tab
    mov rax, r14
    EPILOGUE

# tab_move(from, to): tab `from` moves to place `to`, the tabs between closing up behind it; the
#   active tab stays the active one wherever it goes
FN tab_move
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    cmp r12, r13
    je 9f
    mov rdi, r12
    call tab_at
    mov rcx, [rax + TAB_kind]
    mov [rsp], rcx
    mov rcx, [rax + TAB_doc]
    mov [rsp + 8], rcx
    mov rcx, [rax + TAB_flags]
    mov [rsp + 16], rcx
    cmp r12, r13
    ja 1f
    # to the right: (from, to] one place left
    mov rdi, r12
    call tab_at
    mov rdi, rax
    lea rsi, [rax + TAB_SIZE]
    mov rdx, r13
    sub rdx, r12
    imul rdx, rdx, TAB_SIZE
    call memmove
    jmp 2f
1:  # to the left: [to, from) one place right
    mov rdi, r13
    call tab_at
    mov rsi, rax
    lea rdi, [rax + TAB_SIZE]
    mov rdx, r12
    sub rdx, r13
    imul rdx, rdx, TAB_SIZE
    call memmove
2:  mov rdi, r13
    call tab_at
    mov rcx, [rsp]
    mov [rax + TAB_kind], rcx
    mov rcx, [rsp + 8]
    mov [rax + TAB_doc], rcx
    mov rcx, [rsp + 16]
    mov [rax + TAB_flags], rcx
    # the active tab: the one moved, or one of those it passed (a place toward where it was)
    mov rax, [rip + g_tab_cur]
    test rax, rax
    js 8f
    cmp rax, r12
    jne 3f
    mov [rip + g_tab_cur], r13
    jmp 8f
3:  cmp r12, r13
    ja 4f
    cmp rax, r12
    jb 8f
    cmp rax, r13
    ja 8f
    dec qword ptr [rip + g_tab_cur]
    jmp 8f
4:  cmp rax, r13
    jb 8f
    cmp rax, r12
    ja 8f
    inc qword ptr [rip + g_tab_cur]
8:  mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# tabs_pinned() -> how many tabs are pinned: the first ones in the strip
FN tabs_pinned
    xor eax, eax
    mov rcx, [rip + g_tabs + VEC_ptr]
1:  cmp rax, [rip + g_tabs + VEC_len]
    jae 2f
    test dword ptr [rcx + TAB_flags], TF_PIN
    jz 2f
    add rcx, TAB_SIZE
    inc rax
    jmp 1b
2:  ret

# tab_pinned(i) -> eax 1 when tab i is pinned
FN tab_pinned
    call tab_at
    mov eax, [rax + TAB_flags]
    and eax, TF_PIN
    ret

# app_pin_tab(i, on): pin tab i, which moves after the other pinned tabs, or unpin it, which moves
#   before the others
FN app_pin_tab
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    cmp r12, [rip + g_tabs + VEC_len]
    jae 9f
    call tabs_pinned
    mov rbx, rax
    mov rdi, r12
    call tab_at
    mov ecx, [rax + TAB_flags]
    and ecx, TF_PIN
    test r13d, r13d
    jz 1f
    test ecx, ecx
    jnz 9f
    or dword ptr [rax + TAB_flags], TF_PIN
    mov rsi, rbx
    jmp 2f
1:  test ecx, ecx
    jz 9f
    and dword ptr [rax + TAB_flags], ~TF_PIN
    lea rsi, [rbx - 1]
2:  mov rdi, r12
    call tab_move
    mov dword ptr [rip + g_tabscroll_reveal], 1
    mov dword ptr [rip + g_dirty], 1    # the pin shows also where the tab stays in its place
9:  EPILOGUE

FN cmd_pin_tab
    mov esi, 1
    jmp pin_active

FN cmd_unpin_tab
    xor esi, esi
    jmp pin_active

# pin_active(on): app_pin_tab for the active tab
pin_active:
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 1f
    jmp app_pin_tab
1:  ret

# app_place_tab(i): the active tab moves to place i in the strip (the last place at most, and among
#   the tabs pinned or not as it is), the tabs between closing up behind it
FN app_place_tab
    PROLOGUE
    mov r12, [rip + g_tab_cur]
    test r12, r12
    js 9f
    mov rbx, rdi
    call tabs_pinned
    mov r13, rax
    mov rdi, r12
    call tab_pinned
    test eax, eax
    jz 1f
    lea rcx, [r13 - 1]
    cmp rbx, rcx
    cmova rbx, rcx
    jmp 2f
1:  mov rcx, [rip + g_tabs + VEC_len]
    dec rcx
    cmp rbx, rcx
    cmova rbx, rcx
    cmp rbx, r13
    cmovb rbx, r13
2:  mov rdi, r12
    mov rsi, rbx
    call tab_move
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
2:  cmp qword ptr [rcx + TAB_kind], TAB_EXT
    jne 3f
    lea rax, [rip + .Lext_tab]
3:  cmp qword ptr [rcx + TAB_kind], TAB_VIEW
    jne 4f
    mov rdi, [rcx + TAB_flags]
    jmp extview_title
4:  ret

# app_detect_lang(doc)
FN app_detect_lang
    jmp doc_language_refresh

# cmd_new_file()
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
    mov dword ptr [rip + g_reveal], 0   # one still asked for it is not the next tab's
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
    cmp qword ptr [rax + TAB_kind], TAB_VIEW
    jne 0f
    push rax
    push rax
    mov rdi, [rax + TAB_flags]
    call extview_tab_closed     # its extension hears it, the view's slot is freed
    pop rax
    pop rax
    test dword ptr [rax + TAB_flags], TF_CUSTOM
    jz 0f
    push rax
    push rax
    mov rdi, [rax + TAB_doc]
    call ce_tab_closed          # custom editors: editor-closed, the CE goes
    pop rax
    pop rax
0:  cmp qword ptr [rax + TAB_kind], TAB_NOTEBOOK
    jne 70f
    push rax
    push rax
    mov rdi, [rax + TAB_doc]
    call nb_tab_closed          # its extension hears it, its cells go
    pop rax
    pop rax
70: mov rbx, [rax + TAB_doc]
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
    mov rdx, [rax + TAB_SIZE + TAB_flags]
    mov [rax + TAB_flags], rdx
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
    inc qword ptr [rip + app_save_epoch]
    mov rbx, rdi
    call tab_at
    mov rdi, rax
    call tab_dirty
    test eax, eax
    jz 1f
    call dlg_drop
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

# cmd_close_tab(): Ctrl+W, the palette and vim's :q close the active tab, but not a pinned one (its menu
#   does)
FN cmd_close_tab
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 1f
    push rdi
    call tab_pinned
    pop rdi
    test eax, eax
    jz app_close_tab
    jmp app_pinned_stays
1:  ret

# app_pinned_stays(): say why a pinned tab did not close
FN app_pinned_stays
    lea rdi, [rip + .Lpinned_stays]
    jmp app_toast

# cmd_close_all: close every tab but the pinned ones. The first modified doc asks, and each answer that
# closes it comes back here for the next; a cancel stops, with the tabs not closed yet still open
FN cmd_close_all
    PROLOGUE
    mov edi, 5
    call ask_unsaved
    test eax, eax
    jnz 9f
    call tabs_pinned
    mov rdi, rax
    call close_tabs_from
9:  EPILOGUE

# ask_unsaved(kind) -> eax 1 when the first modified doc asks, in dialog kind (dlg_kind), else 0. Close
#   All Tabs (kind 5) leaves the pinned tabs alone.
ask_unsaved:
    PROLOGUE
    mov r12d, edi
    xor ebx, ebx
    cmp r12d, 5
    jne 1f
    call tabs_pinned
    mov rbx, rax
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 3f
    mov rdi, rbx
    call tab_at
    mov rdi, rax
    call tab_dirty
    test eax, eax
    jz 2f
    call dlg_drop
    mov [rip + dlg_tab], rbx
    mov [rip + dlg_kind], r12d
    inc qword ptr [rip + app_save_epoch]
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
    xor edi, edi
# close_tabs_from(i): close tab i and the ones after it without asking, the last first
close_tabs_from:
    PROLOGUE
    mov rbx, rdi
1:  mov rdi, [rip + g_tabs + VEC_len]
    cmp rdi, rbx
    jbe 9f
    dec rdi
    call app_close_tab_now
    jmp 1b
9:  EPILOGUE

FN cmd_next_tab
    mov esi, 1
    cmp dword ptr [rip + g_focus], FOCUS_TERMINAL   # in the terminal: the next terminal
    je term_cycle
    call panel_view_focused     # in one of the panel's view tabs: the next of its tabs
    mov esi, 1
    test eax, eax
    jnz term_cycle
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
    call panel_view_focused
    mov esi, -1
    test eax, eax
    jnz term_cycle
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
    xor esi, esi
    jmp save_doc

FN cmd_save_without_formatting
    xor edi, edi
    mov esi, SAVE_BYPASS
    jmp save_doc

# app_save_close(): vim's :wq: save, and close the file once it is saved (after Overwrite, for a
#   read-only one)
FN app_save_close
    mov edi, 1
    xor esi, esi
save_doc:
    READONLY_RET
    PROLOGUE
    mov r13d, edi
    mov r14d, esi
    mov rbx, [rip + g_doc]
    call nb_active              # notebooks: the notebook, not its cell
    test rax, rax
    jz 0f
    mov rbx, [rax + NB_host]
0:  call ce_active              # custom editors: the editor's document
    test rax, rax
    jz 10f
    mov rbx, [rax + CE_doc]
10: test rbx, rbx
    jz 9f
    cmp qword ptr [rbx + DOC_path], 0
    jne 1f
    mov rdi, rbx
    mov esi, r13d
    mov rdx, r14
    call app_save_prompt
    jmp 9f
1:  mov rdi, rbx
    call doc_readonly
    test eax, eax
    jz 3f
    mov [rip + ro_close], r13d
    mov [rip + ro_save_flags], r14
    mov [rip + ro_save_kind], r13
    mov rdi, rbx
    lea rsi, [rip + save_readonly_confirmed]
    call ask_readonly
    jmp 9f
3:  mov rdi, rbx
    mov rsi, r14
    mov rdx, r13
    call app_save_managed
9:  EPILOGUE

# save_readonly_confirmed(): Overwrite, for cmd_save and :wq
save_readonly_confirmed:
    PROLOGUE
    mov rdi, [rip + ro_id]
    call app_doc_by_id
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, [rip + ro_save_flags]
    or esi, SAVE_READONLY
    mov rdx, [rip + ro_save_kind]
    call app_save_managed
9:  EPILOGUE

# app_save_managed(doc, flags, kind): kind 0 ordinary, 1 close, 8+dialog kind unsaved flow.
# A continuation owns its generation and frees it even when cancelled or superseded.
FN app_save_managed
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
    test r13, r13
    jz 1f
    inc qword ptr [rip + app_save_epoch]
    mov edi, 16
    call mem_alloc
    mov r14, rax
    mov rcx, [rip + app_save_epoch]
    mov [rax], rcx
    mov [rax + 8], r13
    or r12d, SAVE_INTENT
1:  mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    test r14, r14
    jz 2f
    lea rdx, [rip + app_save_completed]
2:  mov rcx, r14
    call app_save_start         # save_start, or a notebook's save through its extension
    mov r12, rax
    cmp rax, 1
    je 9f
    test r14, r14
    jz 9f
    mov rdi, [rbx + DOC_id]
    mov rsi, r14
    mov rdx, r12
    call app_save_completed
9:  mov rax, r12
    EPILOGUE

app_save_completed:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, [r12 + 8]
    mov r15, [r12]
    mov rdi, r12
    call mem_free
    cmp r15, [rip + app_save_epoch]
    jne 9f
    test r13, r13
    jnz 8f
    mov rdi, rbx
    call app_doc_tab
    test rax, rax
    js 8f
    cmp r14, 1
    jne 2f
    mov rbx, rax
    mov rdi, rax
    call tab_pinned
    test eax, eax
    jnz 9f
    mov rdi, rbx
    call app_close_tab
    jmp 9f
2:  mov [rip + dlg_tab], rax
    lea rdi, [r14 - 8]
    call unsaved_done
    jmp 9f
8:  cmp r14, 8
    jb 9f
    call unsaved_kept
9:  EPILOGUE

# Save As is bound to the initiating document, including an untitled :wq or unsaved dialog.
app_save_prompt:
    PROLOGUE
    mov rbx, [rdi + DOC_id]
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + .Lsave_as]
    mov esi, PROMPT_SAVE_AS
    call prompt_open
    mov [rip + save_prompt_id], rbx
    mov [rip + save_prompt_kind], r12
    mov [rip + save_prompt_flags], r13
    EPILOGUE

FN app_save_prompt_cancel
    mov rax, [rip + save_prompt_kind]
    mov qword ptr [rip + save_prompt_id], 0
    mov qword ptr [rip + save_prompt_kind], 0
    mov qword ptr [rip + save_prompt_flags], 0
    cmp rax, 8
    jae unsaved_kept
    test rax, rax
    jz 1f
    inc qword ptr [rip + app_save_epoch]
1:  ret

FN app_save_as_finish
    PROLOGUE
    mov r12, rdi
    mov rdi, [rip + save_prompt_id]
    call app_doc_by_id
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, r12
    call file_readonly
    test eax, eax
    jz 1f
    mov rax, [rip + save_prompt_kind]
    mov [rip + ro_save_kind], rax
    mov rax, [rip + save_prompt_flags]
    mov [rip + ro_save_flags], rax
    mov rax, [rbx + DOC_id]
    mov [rip + ro_id], rax
    mov rdi, r12
    call app_save_as_readonly
    jmp 9f
1:  mov rdi, rbx
    mov rsi, r12
    call doc_set_path
    mov rdi, r12
    call vfs_mkdir_parent
    mov rdi, rbx
    call app_detect_lang
    mov rdi, rbx
    mov rsi, [rip + save_prompt_flags]
    mov rdx, [rip + save_prompt_kind]
    call app_save_managed
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
    call vfs_access
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
    call vfs_access
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
    lea rdi, [rip + ro_path]
    call strlen
    lea rdi, [rip + ro_path]
    mov rsi, rax
    call path_basename
    mov rdi, rax
    lea rsi, [rip + save_as_readonly_confirmed]
    call ask_readonly_named
    cmp qword ptr [rip + ro_save_kind], 8
    jb 9f
    lea rax, [rip + unsaved_kept]
    mov [rip + dlg_cancel], rax
9:  EPILOGUE

# save_as_readonly_confirmed(): Overwrite, for Save As
save_as_readonly_confirmed:
    PROLOGUE
    mov rdi, [rip + ro_id]
    call app_doc_by_id          # notebooks, custom editors: their tab's document
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + ro_path]
    call doc_set_path
    mov rdi, rbx
    call app_detect_lang
    mov rdi, rbx
    mov rsi, [rip + ro_save_flags]
    or esi, SAVE_READONLY
    mov rdx, [rip + ro_save_kind]
    call app_save_managed
9:  EPILOGUE

# ask_readonly(doc, fn): "Overwrite read-only NAME?", whose button calls fn
ask_readonly:
    mov [rip + ro_doc], rdi
    mov rax, [rdi + DOC_id]
    mov [rip + ro_id], rax
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
    inc qword ptr [rbx + DOC_saves]
    mov rdi, rbx
    call doc_language
    test rax, rax
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

# app_after_auto_save(doc): re-detect language, config reload, explorer refresh (no toast)
FN app_after_auto_save
    PROLOGUE
    mov rbx, rdi
    cmp qword ptr [rbx + DOC_lang], 0
    jne 1f
    mov rdi, rbx
    call app_detect_lang
1:  call explorer_refresh
    mov rdi, rbx
    call git_doc_saved
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

# app_auto_save_doc(doc): save if modified, with a path, and not read-only
FN app_auto_save_doc
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    test dword ptr [rbx + DOC_flags], DF_READONLY
    jnz 9f
    cmp qword ptr [rbx + DOC_path], 0
    je 9f
    mov rdi, rbx
    call doc_dirty
    test eax, eax
    jz 9f
    mov rdi, rbx
    call doc_save
    test rax, rax
    js 9f
    mov rdi, rbx
    call app_after_auto_save
9:  EPILOGUE

# app_auto_save_all(): auto-save all open dirty tabs that have a file path
FN app_auto_save_all
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 9f
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 2f
    mov rdi, [rax + TAB_doc]
    call app_auto_save_doc
2:  inc rbx
    jmp 1b
9:  EPILOGUE

# autosave_timeout() -> ms until next after_delay save, or -1
FN autosave_timeout
    PROLOGUE
    cmp dword ptr [rip + cfg_auto_save], AUTOSAVE_AFTER_DELAY
    jne .Lat_none
    call time_ms
    mov r12, rax
    movsxd r14, dword ptr [rip + cfg_auto_save_delay]
    mov r15, -1
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae .Lat_done
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 2f
    mov r13, [rax + TAB_doc]
    test dword ptr [r13 + DOC_flags], DF_READONLY
    jnz 2f
    cmp qword ptr [r13 + DOC_path], 0
    je 2f
    mov rdi, r13
    call doc_dirty
    test eax, eax
    jz 2f
    mov rax, r12
    sub rax, [r13 + DOC_lastedit]
    cmp rax, r14
    jge .Lat_zero
    mov rcx, r14
    sub rcx, rax
    cmp r15, -1
    je 3f
    cmp rcx, r15
    jge 2f
3:  mov r15, rcx
2:  inc rbx
    jmp 1b
.Lat_zero:
    xor eax, eax
    EPILOGUE
.Lat_done:
    mov eax, r15d
    EPILOGUE
.Lat_none:
    mov eax, -1
    EPILOGUE

# autosave_tick(): handle after_delay auto-saving and focus-away transitions
FN autosave_tick
    PROLOGUE
    mov eax, [rip + g_focus]
    mov ecx, [rip + g_focus_prev]
    mov [rip + g_focus_prev], eax
    cmp ecx, FOCUS_EDITOR
    jne .Last_delay
    cmp eax, FOCUS_EDITOR
    je .Last_delay
    cmp dword ptr [rip + cfg_auto_save], AUTOSAVE_ON_FOCUS_CHANGE
    jne .Last_delay
    call app_auto_save_all
.Last_delay:
    cmp dword ptr [rip + cfg_auto_save], AUTOSAVE_AFTER_DELAY
    jne 9f
    call time_ms
    mov r12, rax
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 9f
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 2f
    mov r13, [rax + TAB_doc]
    test dword ptr [r13 + DOC_flags], DF_READONLY
    jnz 2f
    cmp qword ptr [r13 + DOC_path], 0
    je 2f
    mov rdi, r13
    call doc_dirty
    test eax, eax
    jz 2f
    mov rax, r12
    sub rax, [r13 + DOC_lastedit]
    movsxd rcx, dword ptr [rip + cfg_auto_save_delay]
    cmp rax, rcx
    jl 2f
    mov rdi, r13
    call app_auto_save_doc
2:  inc rbx
    jmp 1b
9:  EPILOGUE

FN cmd_save_as
    READONLY_RET
    call nb_active              # notebooks: the notebook's document
    test rax, rax
    jz 3f
    mov rdi, [rax + NB_host]
    jmp 2f
3:  call ce_active              # custom editors: the editor's document
    mov rdi, [rip + g_doc]
    test rax, rax
    jz 2f
    mov rdi, [rax + CE_doc]
2:  test rdi, rdi
    jz 1f
    xor esi, esi
    xor edx, edx
    jmp app_save_prompt
1:  ret

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
    call font_paths_hash
    mov r13, rax
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
    # a font named anew loads now, as from Settings
    call font_paths_hash
    cmp rax, r13
    je 9f
    call app_load_fonts
    call ui_force_metrics
9:  EPILOGUE

# font_paths_hash() -> rax: a hash of the editor's, the interface's and the terminal's font paths
font_paths_hash:
    PROLOGUE
    xor ebx, ebx
    lea r12, [rip + font_paths]
1:  mov rax, [r12]
    test rax, rax
    jz 9f
    mov r13, [rax]
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call hash_line
    rol rbx, 7
    xor rbx, rax
    add r12, 8
    jmp 1b
9:  mov rax, rbx
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

# Modifier changes must redraw even when the pointer and caret stay still.
FN app_on_modifiers
    mov [rip + g_mods], edi
    mov dword ptr [rip + g_dirty], 1
    jmp viewpic_modifiers

FN app_on_pointer_leave
    mov edi, -10000
    mov esi, -10000
    call ui_input_motion
    mov dword ptr [rip + g_dirty], 1
    ret

# app_on_button(btn, pressed, mods)
FN app_on_button
    mov [rip + g_mods], edx
    test esi, esi
    jz 1f
    push rdi
    push rsi
    push rdx
    call keys_chord_cancel      # a press ends a waiting chord
    pop rdx
    pop rsi
    pop rdi
1:
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
    test edi, edi
    jnz 0f
    mov dword ptr [rip + g_mods], 0
0:
    push rdi
    call viewpic_window_focus
    mov edi, [rsp]
    call keys_chord_cancel
    # files may have changed while away
    test edi, edi
    jz 1f
    call git_touch
1:  # the caret shows at once, as after a key; the view stays where it was scrolled, also away from
    # the caret (issue 85)
    call time_ms
    mov [rip + g_blink_t0], rax
    pop rdi
    jmp 2f
1:  cmp dword ptr [rip + cfg_auto_save], AUTOSAVE_ON_WINDOW_CHANGE
    je 11f
    cmp dword ptr [rip + cfg_auto_save], AUTOSAVE_ON_FOCUS_CHANGE
    jne 2f
11: call app_auto_save_all
2:  call ed_touch
    mov dword ptr [rip + g_dirty], 1
    ret

# app_on_paste(ptr, len): route to the focused text target
FN app_on_paste
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call ed_clip_observe
    mov rdi, rbx
    mov rsi, r12
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
0:  cmp dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    jne 5f
    mov rdi, rbx                # and an agent's prompt box
    mov rsi, r12
    call agentext_paste
    jmp 9f
5:  mov rdi, rbx                # an extension's version control message box (scmpanel.s)
    mov rsi, r12
    call scmpanel_paste
    test eax, eax
    jnz 9f
    mov rdi, rbx                # a picture with the keyboard (views group, viewpic.s)
    mov rsi, r12
    call views_paste
    test eax, eax
    jnz 9f
    mov rdi, rbx
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
    call langextra_paste        # ed_paste, then format_on_paste (language features)
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# focused_field() -> TF* that has keyboard focus, or 0
FN focused_field
    mov eax, [rip + g_focus]
    cmp eax, FOCUS_VIEW
    je 1f
    cmp eax, FOCUS_QUICK
    je quick_field              # an extension's quick input (quick.s)
    cmp eax, FOCUS_SCM
    je scm_field
    cmp eax, FOCUS_PALETTE
    je palette_field
    cmp eax, FOCUS_PROMPT
    je palette_field
    cmp eax, FOCUS_FIND
    je find_field
    cmp eax, FOCUS_SETTINGS
    je settings_field
    cmp eax, FOCUS_EXT_SEARCH   # extension management: Browse's search
    je extpage_field
    cmp eax, FOCUS_EDITOR
    je vim_field
    cmp eax, FOCUS_AGENT_INPUT
    je agentext_field
    xor eax, eax
    ret
1:  sub rsp, 8                  # an extension's version control message box (scmpanel.s), else a
    call scmpanel_field         #   view's own field (views group, rview.s)
    add rsp, 8
    test rax, rax
    jz views_field
    ret

# field_changed(): notify the owner of the focused field
field_changed:
    mov eax, [rip + g_focus]
    cmp eax, FOCUS_QUICK
    je quick_changed
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
    # a chord waiting for its second stroke takes the key first (keys.s)
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call keys_chord_key
    test eax, eax
    jnz 9f
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
1:  # Esc closes a context menu, then the extensions dropdown
    cmp r12d, KEY_ESCAPE
    jne 10f
    call ext_provider_cancel
    call explorer_menu_open
    test eax, eax
    jz 11f
    call ctx_menu_close
    jmp 9f
11: call extbar_menu_open
    test eax, eax
    jz 10f
    call extbar_close
    jmp 9f
10: # focused components get the first chance
    mov eax, [rip + g_focus]
    cmp eax, FOCUS_QUICK        # an extension's quick input (quick.s)
    jne 12f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call quick_key
    test eax, eax
    jnz 9f
    jmp .Lk_bind
12: cmp eax, FOCUS_PALETTE
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
    jne 41f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call settings_key
    test eax, eax
    jnz 9f
    jmp .Lk_bind
41: cmp eax, FOCUS_EXT_SEARCH   # extension management: Browse's search
    jne 5f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call extpage_key
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
71: cmp eax, FOCUS_VIEW
    jne 73f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call place_key              # a view in a place (places.s)
    test eax, eax
    jnz 9f
    jmp .Lk_bind
73: cmp eax, FOCUS_SCM
    jne 74f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call scm_key
    test eax, eax
    jnz 9f
    jmp .Lk_bind
74: cmp eax, FOCUS_AGENT_INPUT  # AI (D4): an agent session's prompt box
    jne .Lk_bind
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call agentext_input_key
    test eax, eax
    jnz 9f
.Lk_bind:
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 1f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call hovercard_key          # language features: the hover card, when it shows (hovercard.s)
    test eax, eax
    jnz 9f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call peek_key               # language features: the peek view, when it shows (peek.s)
    test eax, eax
    jnz 9f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call complete_key           # the completion list, when it shows, takes its keys first
    test eax, eax
    jnz 9f
    cmp r12d, KEY_ESCAPE        # language features: Escape cancels a query still searching
    jne 74f
    call langfeat_escape
    test eax, eax
    jnz 9f
74: mov edi, r12d               # AI: a Review tab's keys (review.s)
    mov esi, r13d
    mov edx, r14d
    call review_key
    test eax, eax
    jnz 9f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call snippet_key
    test eax, eax
    jnz 9f
    mov edi, r12d               # editor presentation: ghost text takes Tab after them (ghost.s)
    mov esi, r13d
    mov edx, r14d
    call ghost_key
    test eax, eax
    jnz 9f
    cmp r12d, KEY_ESCAPE
    jne 72f
    mov rdi, [rip + g_doc]
    call save_cancel_key
    test eax, eax
    jnz 9f
72: mov edi, r12d                # notebooks: command and edit mode keys
    mov esi, r13d
    mov edx, r14d
    call nb_key
    test eax, eax
    jnz 9f
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
    mov rdi, rdx
    call keys_run
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
    mov edi, 10
    call langextra_typed        # language features: formatting as you type
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
    # several selections go back to the primary first (multi-cursor)
    mov rdi, [rip + g_doc]
    call sel_escape
    test eax, eax
    jnz 9f
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
    mov edi, r13d
    call complete_typed         # completion and signature help follow typing
    mov edi, r13d
    call langextra_typed        # language features: formatting as you type
9:  EPILOGUE

# ---------------- timers ----------------

FN app_timeout
    PROLOGUE
    call ed_blink_timeout
    mov ebx, eax
    call app_clip_timeout
    cmp eax, -1
    je 0f
    mov ebx, eax
0:
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
1:  lea r12, [rip + timeout_fns]   # the soonest of the parts' deadlines (-1: none)
2:  mov rax, [r12]
    test rax, rax
    jz 9f
    add r12, 8
    call rax
    cmp eax, -1
    je 2b
    cmp ebx, -1
    je 3f
    cmp eax, ebx
    jge 2b
3:  mov ebx, eax
    jmp 2b
9:  mov eax, ebx
    EPILOGUE

.section .rodata
.p2align 3
# app_timeout's parts: each fn() -> eax milliseconds until it needs a tick, or -1; 0-ended
timeout_fns:
    .quad agents_timeout
    .quad git_timeout
    .quad gitrepos_timeout      # and the other workspace folders' repositories (gitrepos.s)
    .quad scmext_timeout        # source control: quick-diff requests' time
    .quad update_timeout
    .quad ai_timeout
    .quad tools_timeout         # AI: tool calls waiting for the user (tools.s)
    .quad autosave_timeout
    .quad watch_timeout
    .quad tip_timeout
    .quad palette_timeout
    .quad editor_timeout
    .quad sb_timeout
    .quad term_timeout
    .quad ext_timeout
    .quad complete_timeout
    .quad langfeat_timeout
    .quad outline_timeout       # language features: the Outline's debounce (outline.s)
    .quad hovercard_timeout     # and the hover card's rest, show time and grace (hovercard.s)
    .quad lightbulb_timeout     # and the lightbulb's rest (lightbulb.s)
    .quad wsym_timeout          # and the symbol query's debounce (wsym.s)
    .quad ext_provider_timeout
    .quad save_timeout
    .quad uproc_timeout
    .quad termproto_timeout     # tasks: terminal output waiting for its budget (termproto.s)
    .quad query_timeout
    .quad testing_timeout
    .quad dap_timeout
    .quad remote_timeout
    .quad views_timeout         # views group: waits for children, notifications, progress
    .quad extupdate_timeout      # extension management
    .quad keys_timeout           # a chord's pause (keys.s)
    .quad ws_difftab_timeout    # wsedit: diff tabs whose sides changed
    .quad ws_linked_timeout     # wsedit: a cursor resting for linked editing
    .quad nb_timeout              # notebooks: requests waiting for their program
    .quad ce_timeout              # custom editors: requests waiting for their program
    .quad newext_timeout          # New Extension: quick input events to take (newext.s)
    .quad submitext_timeout       # and Submit to Index's (submitext.s)
    .quad 0
.text

FN app_tick
    PROLOGUE
    call query_tick             # language features: expired requests, before their askers' ticks
    call complete_tick
    call langfeat_tick
    call ws_difftab_tick        # wsedit: diff tabs follow their sides
    call ws_linked_tick         # wsedit: linked editing asks where the cursor rests
    call save_tick
    call ext_options_apply
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
    call uproc_tick
    call term_tick
    call problems_tick          # documents opened since get their problems' marks
    call termproto_tick         # extensions' terminal output
    call git_tick
    call gitrepos_tick          # resources group: the other workspace folders' repositories
    call update_tick
    call ai_tick
    call tools_tick             # AI: tool calls waiting for the user's answer (tools.s)
    call autosave_tick
    call palette_tick
    call editor_tick
    call ext_tick
    call extrec_tick            # extension management: first starts of new versions
    call extupdate_tick         # and update checks
    call ext_provider_tick
    call testing_tick           # testing (testproto.s)
    call views_tick             # views group (places.s)
    call nb_tick
    call ce_tick                # custom editors (customed.s)
    call app_clip_tick
    call dap_tick               # debugger
    call dview_context
    call dg_tick
    call remote_tick            # remote hosts
    call keys_tick              # a chord's pause (keys.s)
    call newext_tick            # New Extension's steps (newext.s)
    call submitext_tick         # Submit to Index's steps (submitext.s)
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
1:  call complete_hole          # the completion list drawn last frame keeps the pointer
    call notify_hole            # and the notification cards
    # no background: the bars, panels, dividers and the editor column cover the window, each with
    # its own color (a whole-window fill under them was a fifth of every frame). A theme with a
    # translucent color (#rrggbbaa) still gets it, so nothing blends with the frame before.
    lea rcx, [rip + g_theme]
    mov eax, -1
    xor edx, edx
0:  and eax, [rcx + rdx*4]
    inc edx
    cmp edx, T_COUNT
    jb 0b
    shr eax, 24
    cmp eax, 255
    je 0f
    xor edi, edi
    xor esi, esi
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    COLOR r8d, T_BG
    call gfx_fill
0:  # panel sizes
    mov edi, [rip + cfg_sidebar_w]
    call sc
    mov [rip + g_side_px], eax
    mov edi, [rip + cfg_agents_w]
    call sc
    mov [rip + g_agents_px], eax
    # keep the editor at least 240pt wide: the agents panel gives way first, then the sidebar, each
    # down to nothing in a window too narrow for them. The column's width never goes below zero (the
    # terminal under it made a grid of 268 million columns of a negative one).
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
2:  sub edx, ecx                # what does not fit
    jle 3f
    cmp dword ptr [rip + g_show_agents], 0
    je 21f
    mov eax, [rip + g_agents_px]
    cmp eax, edx
    cmovg eax, edx
    sub [rip + g_agents_px], eax
    sub edx, eax
21: cmp dword ptr [rip + g_show_side], 0
    je 3f
    mov eax, [rip + g_side_px]
    cmp eax, edx
    cmovg eax, edx
    sub [rip + g_side_px], eax
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
    call sidebar_draw
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
    call side_draw              # the agents panel, or a side view (places.s)
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
54: # remote hosts: the connection's bar over the column while it is not up
    mov edi, [rsp + 40]
    mov esi, [rsp + 20]
    mov edx, [rsp + 44]
    call remote_bar
    add [rsp + 20], eax
    sub [rsp + 48], eax
    # the trust bar over the column, while git is paused for a repository a link opened
    mov edi, [rsp + 40]
    mov esi, [rsp + 20]
    mov edx, [rsp + 44]
    call trust_bar
    mov edi, [rsp + 40]
    mov esi, [rsp + 20]
    add esi, eax
    mov edx, [rsp + 44]
    mov ecx, [rsp + 48]
    sub ecx, eax
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
    call notify_draw            # notification cards (notify.s), under popups, menus and dialogs
    call complete_draw
    call hovercard_draw         # language features: the hover card (hovercard.s)
    call extbar_draw
    call explorer_menu_draw
    call palette_draw
    call quick_draw             # an extension's quick input (quick.s)
    call dialog_draw
    call toast_draw
    call tip_commit             # after every button with a tooltip has been drawn
    call tip_draw
    call places_frame_end       # views hear focus and visibility changes once a frame
    mov edi, [rsp + 36]
    test edi, edi
    jz 2f
    call edge_cursor
    mov [rip + g_cursor], eax
2:  call ed_blink_frame
    call ui_end
    # scripted screenshot
    mov rdi, [rip + g_shot_path]
    test rdi, rdi
    jz 9f
    mov qword ptr [rip + g_shot_path], 0
    call shot_write
9:  EPILOGUE

# app_modal_open() -> 1 when a modal layer should block the base ui
FN app_modal_open
    cmp dword ptr [rip + dlg_kind], 0
    jne 1f
    call explorer_menu_open
    test eax, eax
    jnz 1f
    call extbar_menu_open
    test eax, eax
    jnz 1f
    call palette_is_open
    test eax, eax
    jnz 1f
    jmp quick_is_open
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
    and dword ptr [rip + g_mdown], ~(1 << BTN_LEFT)   # the release goes to the compositor
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
1:  test eax, UB_DOUBLE
    jz 5f
    # a double-click puts the panel back at its default width; a drag after it starts from where
    # the next frame lays the divider out (a narrow window may give the panel less than that)
    mov edi, SIDEBAR_W_DEFAULT
    lea r15, [rip + cfg_sidebar_w]
    cmp ebx, ID_SPLIT_L
    je 7f
    mov edi, AGENTS_W_DEFAULT
    lea r15, [rip + cfg_agents_w]
7:  mov [r15], edi
    mov dword ptr [rip + split_reanchor], 1
    mov dword ptr [rip + split_moved], 0
    jmp 3f
5:  test eax, UB_HELD
    jz 9f
    test eax, UB_PRESS
    jz 52f
    # the press takes hold of the divider where it is: it keeps its distance from the pointer
    mov eax, [rip + g_mx]
    sub eax, r12d
    mov [rip + split_grab], eax
    mov dword ptr [rip + split_moved], 0
    mov dword ptr [rip + split_reanchor], 0
    jmp 9f
52: cmp dword ptr [rip + split_reanchor], 0
    je 6f
    mov dword ptr [rip + split_reanchor], 0
    mov eax, [rip + g_press_x]  # the double-click's press against the divider the reset laid out
    sub eax, r12d
    mov [rip + split_grab], eax
6:  # a click that does not move leaves the width alone (even one the layout narrowed); once the
    # pointer has moved, the divider follows it back to where it was pressed too
    mov eax, [rip + g_mx]
    cmp dword ptr [rip + split_moved], 0
    jne 7f
    cmp eax, [rip + g_press_x]
    je 9f
    mov dword ptr [rip + split_moved], 1
7:  # new width in logical points
    sub eax, [rip + split_grab]
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
    jne 11f
    mov edi, [rip + g_editor_rect]
    mov esi, [rip + g_editor_rect + 4]
    mov edx, [rip + g_editor_rect + 8]
    mov ecx, [rip + g_editor_rect + 12]
    call settings_draw
    EPILOGUE
11: cmp qword ptr [rax + TAB_kind], TAB_EXT
    jne 12f
    mov edi, [rip + g_editor_rect]
    mov esi, [rip + g_editor_rect + 4]
    mov edx, [rip + g_editor_rect + 8]
    mov ecx, [rip + g_editor_rect + 12]
    call extpage_draw
    EPILOGUE
12: cmp qword ptr [rax + TAB_kind], TAB_VIEW
    jne 13f
    mov edi, [rip + g_editor_rect]  # custom editors: a stopped editor's notice instead (customed.s)
    mov esi, [rip + g_editor_rect + 4]
    mov edx, [rip + g_editor_rect + 8]
    mov ecx, [rip + g_editor_rect + 12]
    call ce_draw_tab
    test eax, eax
    jnz 14f
    mov edi, [rip + g_editor_rect]
    mov esi, [rip + g_editor_rect + 4]
    mov edx, [rip + g_editor_rect + 8]
    mov ecx, [rip + g_editor_rect + 12]
    call extview_draw
14: EPILOGUE
13: cmp qword ptr [rax + TAB_kind], TAB_NOTEBOOK
    jne 2f
    mov edi, [rip + g_editor_rect]
    mov esi, [rip + g_editor_rect + 4]
    mov edx, [rip + g_editor_rect + 8]
    mov ecx, [rip + g_editor_rect + 12]
    call nb_draw
    call find_draw
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
    call doclinks_draw             # language features: the link under ctrl, underlined (doclinks.s)
    call peek_draw              # and the peek view over the text (peek.s)
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
    call extbar_count
    mov [rsp + 60], eax         # the extensions button and the pinned ones
    imul ecx, eax, 36
    add ecx, 160
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
31: mov ecx, [rsp + 40]
    add ecx, [rsp + 48]
    imul ecx, [rsp + 60]
    add eax, ecx
    cmp dword ptr [rip + g_csd], 0
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
44: # debugger: the toolbar takes the title's place while a session lives (debugview.s)
    mov edi, r12d
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 36]
    call dview_toolbar
    test eax, eax
    jnz 6f
    # active file, centered (the branch is in the status bar)
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
8:  # the extensions button, and the pinned extensions to its left
    mov edi, r12d
    mov esi, [rsp + 12]
    mov edx, r13d
    mov ecx, [rsp + 48]
    call extbar_buttons
    mov r12d, eax
    sub r12d, r13d
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

# trust_bar(x, y, w) -> eax the height it takes: while git is paused for a repository a rhun:// link
#   opened (its config could name a program for git to run), a bar says so, with Trust folder, which
#   trusts it for good, and a close button
trust_bar:
    PROLOGUE 48
    xor eax, eax
    cmp dword ptr [rip + g_git_paused], 0
    je 9f
    cmp dword ptr [rip + trust_closed], 0
    jne 9f
    cmp dword ptr [rip + cfg_git], 0      # git is off in the settings: nothing to trust it for yet
    je 9f
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    M ebx, MI_28
    mov ecx, ebx
    COLOR r8d, T_PANEL
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, ebx
    sub esi, [rip + g_mt + 4*MI_1]
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    # the close button at the right end, Trust folder before it
    M r12d, MI_20
    mov eax, [rsp]
    add eax, [rsp + 8]
    sub eax, r12d
    sub eax, [rip + g_mt + 4*MI_4]
    mov [rsp + 12], eax         # close x
    mov eax, ebx
    sub eax, r12d
    sar eax, 1
    add eax, [rsp + 4]
    mov [rsp + 16], eax         # buttons' y
    lea rdi, [rip + g_face_small]
    lea rsi, [rip + .Ltrust_button]
    mov edx, 12
    call text_width
    M ecx, MI_12
    lea eax, [rax + rcx*2]
    mov [rsp + 20], eax         # Trust folder's width
    mov ecx, [rsp + 12]
    sub ecx, [rip + g_mt + 4*MI_6]
    sub ecx, eax
    mov [rsp + 24], ecx         # its x
    mov edi, ID_TRUST
    mov esi, ecx
    mov edx, [rsp + 16]
    mov ecx, eax
    mov r8d, r12d
    call ui_btn
    mov [rsp + 28], eax
    COLOR r13d, T_ACCENT
    COLOR r14d, T_ACCENT_FG
    test eax, UB_HOVER
    jz 1f
    mov edi, r13d
    mov esi, r14d
    mov edx, 36
    call color_mix
    mov r13d, eax
1:  mov edi, [rsp + 24]
    mov esi, [rsp + 16]
    mov edx, [rsp + 20]
    mov ecx, r12d
    M r8d, MI_RADIUS
    mov r9d, r13d
    call gfx_round_rect
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 24]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 20]
    mov r8d, r12d
    lea r9, [rip + .Ltrust_button]
    push r14
    push r14
    call ui_text_center
    add rsp, 16
    mov edi, ID_TRUST_X
    mov esi, [rsp + 12]
    mov edx, [rsp + 16]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_CLOSE
    call ui_icon_btn
    test eax, UB_CLICK
    jz 2f
    mov dword ptr [rip + trust_closed], 1
    mov dword ptr [rip + g_dirty], 1
2:  # what it says, cut short before the button
    lea rdi, [rip + trust_sb]
    call sb_clear
    lea rdi, [rip + trust_sb]
    lea rsi, [rip + .Ltrust_text]
    call sb_push_cstr
    lea rdi, [rip + trust_path]
    mov rsi, [rip + g_git_root]
    call path_tilde
    lea rdi, [rip + trust_sb]
    lea rsi, [rip + trust_path]
    call sb_push_cstr
    # too long for the room before the button: the folder's own name, which the end of a cut path
    # would lose first
    lea rdi, [rip + g_face_small]
    mov rsi, [rip + trust_sb + SB_ptr]
    mov rdx, [rip + trust_sb + SB_len]
    call text_width
    mov ecx, [rsp + 24]
    sub ecx, [rsp]
    sub ecx, [rip + g_mt + 4*MI_12]
    sub ecx, [rip + g_mt + 4*MI_8]
    cmp eax, ecx
    jle 21f
    lea rdi, [rip + trust_sb]
    call sb_clear
    lea rdi, [rip + trust_sb]
    lea rsi, [rip + .Ltrust_text]
    call sb_push_cstr
    mov rdi, [rip + g_git_root]
    mov rsi, [rip + g_git_rootlen]
    call path_basename
    lea rdi, [rip + trust_sb]
    mov rsi, rax
    call sb_push_cstr
21: mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 24]
    sub edx, edi
    sub edx, [rip + g_mt + 4*MI_8]
    mov ecx, ebx
    call gfx_clip_push
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, [rsp + 4]
    mov ecx, ebx
    mov r8, [rip + trust_sb + SB_ptr]
    COLOR r9d, T_WARNING
    call ui_text_c
    call gfx_clip_pop
    test dword ptr [rsp + 28], UB_CLICK
    jz 3f
    call git_trust
3:  mov eax, ebx
9:  EPILOGUE

# cmd_trust_folder(): Trust Folder for Git: the trust bar's button, also after the bar was closed
FN cmd_trust_folder
    cmp dword ptr [rip + g_git_paused], 0
    jne git_trust
    lea rdi, [rip + .Lnot_paused]
    jmp app_toast

# tabs_draw(x, y, w, h)
FN tabs_draw
    PROLOGUE 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    # the tabs scroll in all but a square at the strip's end: the + after them stays there when they
    # fill the strip
    mov eax, edx
    sub eax, ecx
    jns 0f
    xor eax, eax
0:  mov [rsp + 36], eax
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
    # the extensions' editor_title buttons at the strip's end; the tabs and the + keep the rest
    M ecx, MI_24
    mov eax, [rsp + 12]
    sub eax, ecx
    sar eax, 1
    mov [rsp + 48], eax         # the margin around them
    mov edi, [rsp]
    add edi, [rsp + 8]
    sub edi, eax
    mov esi, [rsp + 4]
    add esi, eax
    mov edx, ecx
    call menu_title_buttons
    test eax, eax
    jz 0f
    add eax, [rsp + 48]
    sub [rsp + 8], eax
    mov eax, [rsp + 8]
    sub eax, [rsp + 12]
    jns 9701f
    xor eax, eax
9701: mov [rsp + 36], eax
0:  mov edi, [rsp]
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
2:  # a tab dragged along the strip moves before the tabs are laid out
    mov edi, [rsp]
    mov esi, [rsp + 36]
    call tab_drag_step
    mov [rsp + 44], eax         # the dragged tab, drawn over the others, or -1
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 36]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    mov r12d, [rsp]
    sub r12d, [rip + g_tabscroll]
    xor ebx, ebx
.Ltd_tab:
    cmp rbx, [rip + g_tabs + VEC_len]
    jae .Ltd_done
    mov rdi, rbx
    call tab_width
    mov [rsp + 16], eax
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
    add edx, [rsp + 36]
    sub ecx, edx
    jle 5f
    add [rip + g_tabscroll], ecx
    mov dword ptr [rip + g_dirty], 1
5:  cmp ebx, [rsp + 44]
    je .Ltd_next                # its place stays empty under it
    mov rdi, rbx
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rsp + 16]
    mov r8d, [rsp + 12]
    xor r9d, r9d
    call tab_draw
    test eax, eax
    jnz .Ltd_closed
.Ltd_next:
    add r12d, [rsp + 16]
    inc rbx
    jmp .Ltd_tab
.Ltd_done:
    # the strip cannot scroll past its end (a wheel, a tab closed); measured as it is drawn, so a
    # change shows in the next frame
    mov eax, r12d
    add eax, [rip + g_tabscroll]
    sub eax, [rsp]
    sub eax, [rsp + 36]
    xor ecx, ecx
    cmp eax, ecx
    cmovl eax, ecx
    cmp [rip + g_tabscroll], eax
    jle 1f
    mov [rip + g_tabscroll], eax
    mov dword ptr [rip + g_dirty], 1
1:  call gfx_clip_pop
    # + right after the last tab, in the square at the strip's end when the tabs fill the strip
    mov eax, [rsp]
    add eax, [rsp + 36]
    cmp r12d, eax
    cmovg r12d, eax
    M r13d, MI_24
    mov eax, [rsp + 12]
    sub eax, r13d
    sar eax, 1
    lea esi, [r12 + rax]
    mov [rsp + 40], esi
    mov edx, [rsp + 4]
    add edx, eax
    mov edi, ID_TAB_NEW
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_PLUS
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_TAB_NEW
    mov esi, [rsp + 40]
    mov edx, [rsp + 4]
    add edx, [rsp + 12]
    mov ecx, r13d
    call tip_note               # keeps the button flags in eax
    test eax, UB_CLICK
    jnz 2f
    test eax, UB_HOVER
    jnz 9f
    # a double click on the strip after the tabs does the same
    mov edx, [rsp]
    add edx, [rsp + 8]
    sub edx, r12d
    jle 9f
    mov edi, ID_TAB_END
    mov esi, r12d
    mov ecx, edx
    mov edx, [rsp + 4]
    mov r8d, [rsp + 12]
    call ui_btn
    test eax, UB_PRESS
    jz 9f
    # both presses: after a quick click that closed the last tab, the next one lands here
    test eax, UB_DOUBLE
    jz 3f
    cmp dword ptr [rip + tab_end_press], 0
    jne 2f
3:  mov dword ptr [rip + tab_end_press], 1
    jmp 8f
2:  call tab_new_last
    jmp 9f
.Ltd_closed:                    # a tab closed while drawn: the strip is measured again next frame
    call gfx_clip_pop
9:  test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz 8f
    mov dword ptr [rip + tab_end_press], 0
8:  # the dragged tab over the others and the +
    mov edi, [rsp + 44]
    cmp rdi, [rip + g_tabs + VEC_len]
    jae 81f
    mov esi, [rip + tab_drag_x]
    mov edx, [rsp + 4]
    mov ecx, [rip + tab_drag_w]
    mov r8d, [rsp + 12]
    mov r9d, 1
    call tab_draw
81: call gfx_clip_pop
    EPILOGUE

# tab_new_last(): a new file in a tab at the strip's end, where the + is
tab_new_last:
    call cmd_new_file
    mov rdi, [rip + g_tabs + VEC_len]
    jmp app_place_tab

# tab_width(i) -> eax: its name, and room for the button after it
tab_width:
    PROLOGUE
    call app_tab_label
    mov rbx, rax
    mov rdi, rax
    call strlen
    lea rdi, [rip + g_face_ui]
    mov rsi, rbx
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_40]
    add eax, [rip + g_mt + 4*MI_12]
    EPILOGUE

# tab_draw(i, x, y, w, h, lifted) -> eax 1 when the strip changed under it (the tab closed or was
#   unpinned): the rest shows next frame. A lifted tab is the one being dragged, drawn over the others;
#   it is not hit tested, nor are the others while it is.
tab_draw:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov [rsp + 32], r9d
    mov dword ptr [rsp + 16], 0 # UB_* of the tab
    mov dword ptr [rsp + 28], 0 # and of its button
    mov rdi, rbx
    call tab_at
    mov r15, rax
    mov rdi, rbx
    call app_tab_label
    mov r13, rax
    mov rdi, rax
    call strlen
    mov r14, rax
    cmp dword ptr [rsp + 32], 0
    jne .Ltw_bg
    cmp dword ptr [rip + tab_drag], 0
    jne .Ltw_bg
    lea edi, [rbx + ID_TAB]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call ui_btn
    mov [rsp + 16], eax
    test eax, UB_PRESS
    jz 1f
    # the press may start a drag: which tab, and where along it the press took hold
    mov eax, [rip + g_mx]
    sub eax, [rsp]
    mov [rip + tab_grab], eax
    mov rax, [r15 + TAB_kind]
    mov [rip + tab_drag_kind], rax
    mov rax, [r15 + TAB_doc]
    mov [rip + tab_drag_doc], rax
    mov rdi, rbx
    call app_activate_tab
1:  test dword ptr [rsp + 16], UB_RPRESS
    jz 2f
    mov rdi, rbx
    call tab_menu_open
2:  test dword ptr [rsp + 16], UB_HOVER
    jz .Ltw_bg
    test dword ptr [rip + g_pressed], 1 << BTN_MIDDLE
    jz .Ltw_bg
    # a middle click closes it, but not a pinned one
    test dword ptr [r15 + TAB_flags], TF_PIN
    jz 3f
    call app_pinned_stays
    jmp .Ltw_bg
3:  mov rdi, rbx
    call app_close_tab
    jmp .Ltw_changed
.Ltw_bg:
    cmp rbx, [rip + g_tab_cur]
    jne 7f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    COLOR r8d, T_TAB_ACTIVE
    call gfx_fill
    # the active tab opens into the editor: borders at both sides run the full height and join
    # the strip's bottom line (the left one is the previous tab's separator column)
    mov edi, [rsp]
    sub edi, [rip + g_mt + 4*MI_1]
    mov esi, [rsp + 4]
    M edx, MI_1
    mov ecx, [rsp + 12]
    COLOR r8d, T_BORDER
    call gfx_fill
    mov edi, [rsp]
    add edi, [rsp + 8]
    sub edi, [rip + g_mt + 4*MI_1]
    mov esi, [rsp + 4]
    M edx, MI_1
    mov ecx, [rsp + 12]
    COLOR r8d, T_BORDER
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    sub edx, [rip + g_mt + 4*MI_1]
    M ecx, MI_2
    COLOR r8d, T_ACCENT
    call gfx_fill
    jmp 86f
7:  test dword ptr [rsp + 16], UB_HOVER
    jz 8f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    sub ecx, [rip + g_mt + 4*MI_1]
    COLOR r8d, T_HOVER
    call gfx_fill
8:  # separator
    mov edi, [rsp]
    add edi, [rsp + 8]
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
    jz 87f
    mov rdi, [rax + DOC_path]
    xor eax, eax
    test rdi, rdi
    jz 87f
    call vcs_path_color         # git's, or a version control provider's (scmpanel.s)
87: mov r9d, eax
    test eax, eax
    jnz 88f
    COLOR r9d, T_MUTED
    cmp rbx, [rip + g_tab_cur]
    jne 88f
    COLOR r9d, T_FG
88: lea rdi, [rip + g_face_ui]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, r13
    push r9
    push r9
    mov r9, r14
    call ui_text_v
    add rsp, 16
    # close button, pin, modified dot
    M r12d, MI_20
    mov eax, [rsp]
    add eax, [rsp + 8]
    sub eax, r12d
    sub eax, [rip + g_mt + 4*MI_8]
    mov [rsp + 20], eax
    mov eax, [rsp + 12]
    sub eax, r12d
    sar eax, 1
    add eax, [rsp + 4]
    mov [rsp + 24], eax
    cmp dword ptr [rsp + 32], 0
    jne 89f
    cmp dword ptr [rip + tab_drag], 0
    jne 89f
    lea edi, [rbx + ID_TABX]
    mov esi, [rsp + 20]
    mov edx, [rsp + 24]
    mov ecx, r12d
    mov r8d, r12d
    call ui_btn
    mov [rsp + 28], eax
89: mov rdi, r15                # modified?
    call tab_dirty
    mov r14d, eax
82: test dword ptr [r15 + TAB_flags], TF_PIN
    jnz .Ltw_pin
    test dword ptr [rsp + 28], UB_HOVER
    jnz 84f
    test r14d, r14d
    jz 83f
    # dot
    M ecx, MI_8
    mov edi, [rsp + 20]
    mov esi, [rsp + 24]
    mov eax, r12d
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
    jmp .Ltw_done
83: cmp rbx, [rip + g_tab_cur]
    jne .Ltw_done
    test dword ptr [rsp + 16], UB_HOVER
    jz .Ltw_done
84: # x
    test dword ptr [rsp + 28], UB_HOVER
    jz 85f
    mov edi, [rsp + 20]
    mov esi, [rsp + 24]
    mov edx, r12d
    mov ecx, r12d
    M r8d, MI_4
    COLOR r9d, T_HOVER
    call gfx_round_rect
85: mov edi, IC_CLOSE
    mov esi, [rsp + 20]
    mov edx, [rsp + 24]
    mov ecx, r12d
    mov r8d, r12d
    COLOR r9d, T_MUTED
    call ui_icon_center
    test dword ptr [rsp + 28], UB_CLICK
    jz .Ltw_done
    mov rdi, rbx
    call app_close_tab
    jmp .Ltw_changed
.Ltw_pin:
    # the pin, which unpins it, with a dot at its corner while the file is modified
    test dword ptr [rsp + 28], UB_HOVER
    jz 1f
    mov edi, [rsp + 20]
    mov esi, [rsp + 24]
    mov edx, r12d
    mov ecx, r12d
    M r8d, MI_4
    COLOR r9d, T_HOVER
    call gfx_round_rect
1:  mov edi, IC_PIN
    mov esi, [rsp + 20]
    mov edx, [rsp + 24]
    mov ecx, r12d
    mov r8d, r12d
    COLOR r9d, T_MUTED
    call ui_icon_center
    test r14d, r14d
    jz 2f
    M ecx, MI_6
    mov edi, [rsp + 20]
    add edi, r12d
    sub edi, ecx
    mov esi, [rsp + 24]
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_FG
    cmp rbx, [rip + g_tab_cur]
    je 11f
    COLOR r9d, T_MUTED
11: call gfx_round_rect
2:  test dword ptr [rsp + 28], UB_CLICK
    jz .Ltw_done
    mov rdi, rbx
    xor esi, esi
    call app_pin_tab
.Ltw_changed:
    mov eax, 1
    EPILOGUE
.Ltw_done:
    xor eax, eax
    EPILOGUE

# tab_drag_step(x, w) -> eax the tab being dragged, or -1. Once the pointer has moved a few pixels, a
#   tab held by the left button follows it: the tab takes the place where the others before it end
#   nearest to its left edge, so tabs of any width trade places without flipping back. Among the
#   pinned tabs it is pinned, among the others not; at the place between them it stays as it was.
#   Taken past an end of the strip's scrolling part (x, w) it scrolls the strip. tab_drag_x and
#   tab_drag_w are where to draw it.
tab_drag_step:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jz .Lds_end
    # a dialog or menu that opened meanwhile ends it (not g_block: the window's resize border sets
    # that too, and the pointer goes there to scroll the strip)
    call app_modal_open
    test eax, eax
    jnz .Lds_end
    mov eax, [rip + g_active]
    cmp eax, ID_TAB
    jb .Lds_end
    sub eax, ID_TAB
    mov ebx, eax
    cmp rbx, [rip + g_tabs + VEC_len]
    jae .Lds_end
    # still the tab pressed, and shown (a key may have closed it, and another taken its place, or
    # shown another tab)
    cmp rbx, [rip + g_tab_cur]
    jne .Lds_end
    mov rdi, rbx
    call tab_at
    mov rcx, [rax + TAB_kind]
    cmp rcx, [rip + tab_drag_kind]
    jne .Lds_end
    mov rcx, [rax + TAB_doc]
    cmp rcx, [rip + tab_drag_doc]
    jne .Lds_end
    cmp dword ptr [rip + tab_drag], 0
    jne 1f
    mov eax, [rip + g_mx]
    sub eax, [rip + g_press_x]
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, [rip + g_mt + 4*MI_4]
    jl .Lds_none
    mov dword ptr [rip + tab_drag], 1
1:  mov rdi, rbx
    call tab_width
    mov r12d, eax
    mov [rip + tab_drag_w], eax
    # how far the strip scrolls: all the tabs, less what shows of them
    xor r13d, r13d
    xor r14d, r14d
2:  cmp r14, [rip + g_tabs + VEC_len]
    jae 3f
    mov rdi, r14
    call tab_width
    add r13d, eax
    inc r14
    jmp 2b
3:  sub r13d, [rsp + 4]
    jns 31f
    xor r13d, r13d
31: # where the pointer takes the tab's left edge; past an end the strip scrolls toward it
    mov eax, [rip + g_mx]
    sub eax, [rip + tab_grab]
    mov r14d, eax
    cmp eax, [rsp]
    jge 4f
    mov eax, [rip + g_tabscroll]
    sub eax, [rip + g_mt + 4*MI_8]
    jmp 5f
4:  add eax, r12d
    mov ecx, [rsp]
    add ecx, [rsp + 4]
    cmp eax, ecx
    jle 6f
    mov eax, [rip + g_tabscroll]
    add eax, [rip + g_mt + 4*MI_8]
5:  cmp eax, r13d
    cmovg eax, r13d
    xor ecx, ecx
    cmp eax, ecx
    cmovl eax, ecx
    cmp eax, [rip + g_tabscroll]
    je 6f
    mov [rip + g_tabscroll], eax
    mov dword ptr [rip + g_dirty], 1
6:  # the tab stays inside the strip
    mov eax, [rsp]
    add eax, [rsp + 4]
    sub eax, r12d
    cmp r14d, eax
    cmovg r14d, eax
    mov eax, [rsp]
    cmp r14d, eax
    cmovl r14d, eax
    mov [rip + tab_drag_x], r14d
    # its left edge along the tabs, and its place
    sub r14d, [rsp]
    add r14d, [rip + g_tabscroll]
    mov eax, r14d
    cdq
    xor eax, edx
    sub eax, edx
    mov [rsp + 8], eax          # how near the best place is
    mov qword ptr [rsp + 16], 0 # the best place
    xor r12d, r12d
    xor r13d, r13d              # where the other tabs so far end
    xor r15d, r15d              # how many
7:  cmp r12, [rip + g_tabs + VEC_len]
    jae 8f
    cmp r12, rbx
    je 71f
    mov rdi, r12
    call tab_width
    add r13d, eax
    inc r15
    mov eax, r13d
    sub eax, r14d
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, [rsp + 8]
    jge 71f
    mov [rsp + 8], eax
    mov [rsp + 16], r15
71: inc r12
    jmp 7b
8:  # pinned or not, as the tabs on both sides are
    call tabs_pinned
    mov r13, rax
    mov rdi, rbx
    call tab_pinned
    sub r13, rax                # the other pinned tabs
    mov r12, [rsp + 16]
    mov rdi, rbx
    call tab_at
    cmp r12, r13
    jae 81f
    or dword ptr [rax + TAB_flags], TF_PIN
    jmp 82f
81: jbe 82f
    and dword ptr [rax + TAB_flags], ~TF_PIN
82: mov rdi, rbx
    mov rsi, r12
    call tab_move
    lea eax, [r12 + ID_TAB]
    mov [rip + g_active], eax
    mov eax, r12d
    EPILOGUE
.Lds_end:
    # let go: the tab settles in its place, in full view
    cmp dword ptr [rip + tab_drag], 0
    je .Lds_none
    mov dword ptr [rip + tab_drag], 0
    mov dword ptr [rip + g_tabscroll_reveal], 1
    mov dword ptr [rip + g_dirty], 1
.Lds_none:
    mov eax, -1
    EPILOGUE

# tab_menu_open(i): the menu of tab i, for a right click on it: pin or unpin, close, close all
tab_menu_open:
    PROLOGUE
    mov rbx, rdi
    call tab_at
    mov rcx, [rax + TAB_kind]
    mov [rip + menu_tab_kind], rcx
    mov rcx, [rax + TAB_doc]
    mov [rip + menu_tab_doc], rcx
    lea rdi, [rip + tab_menu]
    test dword ptr [rax + TAB_flags], TF_PIN
    jz 1f
    lea rdi, [rip + tab_menu_pinned]
1:  mov rsi, rbx
    call menu_open_tab          # with the extensions' items (menu.s)
    mov dword ptr [rip + g_menu_keys], 1
    EPILOGUE

# tab_menu_tab() -> the index of the tab the menu is for, or -1 once it closed
tab_menu_tab:
    xor eax, eax
    mov rcx, [rip + g_tabs + VEC_ptr]
1:  cmp rax, [rip + g_tabs + VEC_len]
    jae 3f
    mov rdx, [rcx + TAB_kind]
    cmp rdx, [rip + menu_tab_kind]
    jne 2f
    mov rdx, [rcx + TAB_doc]
    cmp rdx, [rip + menu_tab_doc]
    je 4f
2:  add rcx, TAB_SIZE
    inc rax
    jmp 1b
3:  mov rax, -1
4:  ret

tab_menu_pin:
    mov esi, 1
    jmp tab_menu_set_pin

tab_menu_unpin:
    xor esi, esi
# tab_menu_set_pin(on): app_pin_tab for the menu's tab
tab_menu_set_pin:
    push rsi
    call tab_menu_tab
    pop rsi
    test rax, rax
    js 1f
    mov rdi, rax
    jmp app_pin_tab
1:  ret

# tab_menu_close(): the menu closes its tab, pinned or not (asking when it is modified)
tab_menu_close:
    call tab_menu_tab
    test rax, rax
    js 1f
    mov rdi, rax
    jmp app_close_tab
1:  ret

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
    mov edi, eax
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    call term_tasks_status      # tasks: "▸ build" while tasks run (termview.s)
    mov edi, eax
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    call notify_status_draw     # progress (notify.s), left of the updater's item
    mov edi, eax
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 8]
    call ext_status_draw        # the extensions' status items, left of that
    mov [rsp + 20], eax
    # Keep branch and position glyphs out of the updater's reserved area.
    mov edx, eax
    sub edx, [rsp]
    add edx, [rip + g_mt + 4*MI_12]
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    # a chord waiting for its second stroke says so at the left end (keys.s); else the remote
    # host ("SSH: HOST"), the branch and the file's items
    mov edi, [rsp]
    add edi, [rip + g_mt + 4*MI_12]
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    call keys_chord_draw
    mov ecx, [rsp]
    add ecx, [rip + g_mt + 4*MI_12]
    cmp eax, ecx
    je 2f
    add eax, [rip + g_mt + 4*MI_16]
    mov [rsp + 24], eax
    jmp 3f
2:  mov edi, [rsp]                # remote hosts: "SSH: HOST" at the left end
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    call remote_status_item
    # debugger: the session's state, or the configuration F5 starts (debugview.s)
    mov edi, eax
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    call dview_status_item
    # testing: runs going on, then the tests passed and failed (testview.s)
    mov edi, eax
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    call testview_status_item
    # the branch; the file's items follow it
    mov edi, eax
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 20]
    add ecx, [rip + g_mt + 4*MI_12]
    call statusbar_branch
    mov [rsp + 24], eax
3:  mov eax, [rsp + 24]             # the left status items' room: after this ([rsp + 28]) and
    mov [rsp + 28], eax             # before the file's items ([rsp + 56])
    mov eax, [rsp + 20]
    mov [rsp + 56], eax
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
    # the image's fields take the bar: no room for the extensions' left items
    mov eax, [rsp + 56]
    mov [rsp + 28], eax
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
1:  mov rdi, rbx
    lea rsi, [rip + tmp_sb]
    call sel_status             # "  3 selections" (multi-cursor)
    mov esi, [rsp + 24]
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
    cmp dword ptr [rip + g_insert_spaces], 0
    je 3f
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lspaces]
    call cstr_copy
    mov rdi, rax
    mov esi, [rip + g_tab_width]
    call fmt_u64
    mov byte ptr [rdi], 0      # fmt_u64 leaves rdi after the digits
    lea r13, [rsp + 32]
3:  call .Lsb_item
    lea r13, [rip + .Lplain]
    mov rdi, rbx
    call doc_language
    test rax, rax
    jz 4f
    mov r13, [rax + GR_name]
4:  mov r14d, r12d
    call .Lsb_item
    mov [rsp + 56], r12d            # the left status items stop before the file's items
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
9:  # the extensions' left status items, after the position, before the file's items
    mov edi, [rsp + 28]
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 56]
    call status_items_left
    call gfx_clip_pop
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
    # A confirmation's text may have several lines (\n between them: extension management)
    mov dword ptr [rsp + 32], 1
    cmp dword ptr [rip + dlg_kind], 4
    jne 8f
    mov rdi, [rip + dlg_text]
    call dlg_text_size
    mov [rsp + 32], edx
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
    mov eax, [rsp + 32]
    dec eax
    imul eax, [rip + g_mt + 4*MI_24]
    add r13d, eax
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
    mov eax, r15d
    add eax, [rip + g_mt + 4*MI_40]
    mov [rsp + 40], eax         # the line's y
31: mov rdi, [rsp + 16]
    call dlg_line_len
    mov r9, rax
    mov eax, r12d
    sub eax, [rip + g_mt + 4*MI_40]
    push rax
    COLOR eax, T_MUTED
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, r14d
    add esi, [rip + g_mt + 4*MI_20]
    mov edx, [rsp + 56]
    M ecx, MI_24
    mov r8, [rsp + 32]
    call ui_text_v_fit
    add rsp, 16
    mov rdi, [rsp + 16]
    call dlg_line_len
    add rax, [rsp + 16]
    cmp byte ptr [rax], 10
    jne 32f
    inc rax
    mov [rsp + 16], rax
    mov eax, [rip + g_mt + 4*MI_24]
    add [rsp + 40], eax
    jmp 31b
32:
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
    # a question: Cancel and its button (and app_confirm_alt's between them)
    cmp dword ptr [rip + dlg_kind], 4
    jne 0f
    test ecx, ecx
    jnz 71f
    cmp qword ptr [rip + dlg_no], 0
    je 0f
    mov r13, [rip + dlg_no]
    jmp 0f
71: cmp ecx, 1
    jne 72f
    mov r13, [rip + dlg_alt]
    test r13, r13
    jz 4f
    jmp 0f
72: cmp ecx, 2
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

# dlg_text_size(cstr) -> eax the widest line's width in the small face, edx the lines (\n between)
dlg_text_size:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d              # widest
    xor r13d, r13d              # lines
1:  inc r13d
    mov rdi, rbx
    call dlg_line_len
    mov r14, rax
    lea rdi, [rip + g_face_small]
    mov rsi, rbx
    mov rdx, rax
    call text_width
    cmp eax, r12d
    cmovg r12d, eax
    add rbx, r14
    cmp byte ptr [rbx], 10
    jne 9f
    inc rbx
    jmp 1b
9:  mov eax, r12d
    mov edx, r13d
    EPILOGUE

# dlg_line_len(cstr) -> rax the bytes before its first \n or its end
dlg_line_len:
    xor eax, eax
1:  cmp byte ptr [rdi + rax], 0
    je 2f
    cmp byte ptr [rdi + rax], 10
    je 2f
    inc rax
    jmp 1b
2:  ret

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
    cmp ebx, 1
    jne 6f
    mov rax, [rip + dlg_alt_fn]  # app_confirm_alt's button
    mov qword ptr [rip + dlg_alt], 0
    test rax, rax
    jz 9f
    call rax
    jmp 9f
6:  test rax, rax
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
    xor esi, esi
    lea rdx, [r12 + 8]
    call app_save_managed
    jmp 9f
2:  mov rdi, rbx
    lea rsi, [r12 + 8]
    xor edx, edx
    call app_save_prompt
    jmp 9f
6:  # a read-only file asks first: Overwrite saves it and goes on, Cancel stops here
    mov [rip + ro_kind], r12d
    lea rax, [r12 + 8]
    mov [rip + ro_save_kind], rax
    mov qword ptr [rip + ro_save_flags], SAVE_READONLY
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
    inc qword ptr [rip + app_save_epoch]
    mov dword ptr [rip + g_restart], 0
    mov dword ptr [rip + switch_pending], 0
    mov dword ptr [rip + g_session_final], 0
    ret

# close_readonly_confirmed(): Overwrite, for a close or quit that asked to save a read-only file
close_readonly_confirmed:
    PROLOGUE
    mov rdi, [rip + ro_id]
    call app_doc_by_id
    test rax, rax
    jz 9f
    mov rdi, rax
    mov esi, SAVE_READONLY
    mov rdx, [rip + ro_save_kind]
    call app_save_managed
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
    push rdi
    push rsi
    push rdx
    push rcx
    sub rsp, 8
    call dlg_drop
    add rsp, 8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    mov [rip + dlg_title], rdi
    mov [rip + dlg_text], rsi
    mov [rip + dlg_ok], rdx
    mov [rip + dlg_fn], rcx
    mov qword ptr [rip + dlg_cancel], 0
    mov qword ptr [rip + dlg_alt], 0
    mov qword ptr [rip + dlg_no], 0
    mov dword ptr [rip + dlg_kind], 4
    mov dword ptr [rip + g_focus], FOCUS_DIALOG
    mov dword ptr [rip + g_dirty], 1
    ret

# dlg_drop(): a new dialog replaces an open confirmation: its Cancel runs, as if chosen (an install
# waiting for Add discards its download instead of waiting forever)
dlg_drop:
    cmp dword ptr [rip + dlg_kind], 4
    jne 1f
    mov rax, [rip + dlg_cancel]
    test rax, rax
    jz 1f
    mov qword ptr [rip + dlg_cancel], 0
    mov dword ptr [rip + dlg_kind], 0
    jmp rax
1:  ret

# app_confirm_alt(label, fn, cancel label or 0): the open app_confirm gets a second button, between
#   Cancel and its own, that calls fn; Cancel may say something else (AI: tools.s, Allow once / Allow
#   for this session / Deny)
FN app_confirm_alt
    mov [rip + dlg_alt], rdi
    mov [rip + dlg_alt_fn], rsi
    mov [rip + dlg_no], rdx
    ret

# FN app_dialog_button(i): the open dialog's button i, as if clicked (0 Cancel, 1 app_confirm_alt's,
#   2 its own)
FN app_dialog_button
    cmp dword ptr [rip + dlg_kind], 0
    je 1f
    jmp dialog_choose
1:  ret

# app_confirm_cancel(fn): the open app_confirm's Cancel calls fn
FN app_confirm_cancel
    mov [rip + dlg_cancel], rdi
    ret

# app_dialog_open() -> eax nonzero while a dialog is open (one at a time: the run approval asks only
#   when none is)
FN app_dialog_open
    mov eax, [rip + dlg_kind]
    ret

# app_confirm_revoke(fn): the open app_confirm whose button calls fn goes away unanswered (its Cancel
#   is not called: the question was withdrawn)
FN app_confirm_revoke
    cmp dword ptr [rip + dlg_kind], 4
    jne 9f
    cmp [rip + dlg_fn], rdi
    jne 9f
    mov dword ptr [rip + dlg_kind], 0
    mov qword ptr [rip + dlg_cancel], 0
    cmp dword ptr [rip + g_focus], FOCUS_DIALOG
    jne 1f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
1:  mov dword ptr [rip + g_dirty], 1
9:  ret

# app_dialog_dump(sb): "dialog=none", or "dialog=QUESTION" and its line and button (tests)
FN app_dialog_dump
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + dlg_kind], 4
    je 1f
    lea rsi, [rip + .Ldd_none]
    call sb_push_cstr
    EPILOGUE
1:  lea rsi, [rip + .Ldd_head]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + dlg_title]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [rip + .Ldd_text]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + dlg_text]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [rip + .Ldd_button]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + dlg_ok]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# app_dialog_answer(yes): the open dialog's button (1) or Cancel (0)
FN app_dialog_answer
    cmp dword ptr [rip + dlg_kind], 0
    je 1f
    test edi, edi
    jz 2f
    mov edi, 2
2:  jmp dialog_choose
1:  ret

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

# tip_note_md(id, x, y_bottom, w, flags, MD*) -> flags: tip_note_text for a tooltip drawn as Markdown
#   (views group: node tooltips with markdown agreed); its source is the plain text print-tip shows.
#   The owner keeps the document and notes it each frame the button shows.
FN tip_note_md
    test r8d, UB_HOVER
    jz 9f
    mov [rip + tip_md], r9
    mov [rip + tip_md_id], edi
    push r8
    push r8
    push rdi
    push rsi
    push rdx
    push rcx
    sub rsp, 8
    mov rdi, r9
    call md_source              # rax its text (a cstr)
    mov r9, rax
    add rsp, 8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop r8
    pop r8
    jmp tip_note_text
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
    mov rcx, [rip + tip_md]        # a Markdown tooltip noted this frame (views group)
    test rcx, rcx
    jz 1f
    mov ecx, [rip + tip_id]
    cmp ecx, [rip + tip_md_id]
    jne 1f
    call tip_draw_md
    jmp 9f
1:
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
9:  mov qword ptr [rip + tip_md], 0
    EPILOGUE

# tip_draw_md(): the Markdown tooltip (tip_md): at most 70 columns wide and half the window high,
#   placed as a text tooltip is
tip_draw_md:
    PROLOGUE 32
    mov rbx, [rip + tip_md]
    mov eax, [rip + g_face_ui + FACE_cellw]
    imul eax, eax, 70
    mov ecx, [rip + g_cv + CV_w]
    sub ecx, [rip + g_mt + 4*MI_24]
    cmp eax, ecx
    cmovg eax, ecx
    mov ecx, 1
    cmp eax, ecx
    cmovl eax, ecx
    mov r12d, eax               # the most it may take
    mov rdi, rbx
    mov esi, eax
    call md_measure
    add eax, [rip + g_mt + 4*MI_4]  # laid out again at its widest line, nothing wraps anew
    cmp eax, r12d
    cmovg eax, r12d
    mov ecx, 1
    cmp eax, ecx
    cmovl eax, ecx
    mov r12d, eax               # the text's width
    mov rdi, rbx
    mov esi, eax
    call md_layout
    mov ecx, [rip + g_cv + CV_h]
    sar ecx, 1
    cmp eax, ecx
    cmovg eax, ecx
    mov r13d, eax               # its height
    mov r14d, r12d              # the card: padding around
    add r14d, [rip + g_mt + 4*MI_16]
    mov r15d, r13d
    add r15d, [rip + g_mt + 4*MI_12]
    mov esi, [rip + tip_cx]     # centered under the button, inside the window
    mov eax, [rip + tip_cw]
    shr eax, 1
    add esi, eax
    mov eax, r14d
    shr eax, 1
    sub esi, eax
    mov eax, [rip + g_cv + CV_w]
    sub eax, r14d
    sub eax, [rip + g_mt + 4*MI_4]
    cmp esi, eax
    cmovg esi, eax
    M eax, MI_4
    cmp esi, eax
    cmovl esi, eax
    mov [rsp], esi
    mov eax, [rip + tip_cy]
    add eax, [rip + g_mt + 4*MI_4]
    lea ecx, [rax + r15]
    cmp ecx, [rip + g_cv + CV_h]
    jle 1f
    mov eax, [rip + tip_cy]     # no room below: above the button
    sub eax, [rip + g_mt + 4*MI_STATUS]
    sub eax, [rip + g_mt + 4*MI_4]
    sub eax, r15d
    xor ecx, ecx
    cmp eax, ecx
    cmovl eax, ecx
1:  mov [rsp + 4], eax
    mov edi, [rsp]
    mov esi, eax
    mov edx, r14d
    mov ecx, r15d
    M r8d, MI_4
    M r9d, MI_1
    M eax, MI_RADIUS
    push rax
    push rax
    call ui_card_shadow
    add rsp, 16
    mov eax, ID_TIP_MD
    push rax
    push rax
    mov rdi, rbx
    mov esi, [rsp + 16]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 16 + 4]
    add edx, [rip + g_mt + 4*MI_6]
    mov ecx, r12d
    mov r8d, r13d
    xor r9d, r9d
    call md_draw
    add rsp, 16
    EPILOGUE

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
2:  call settings_reset            # a new settings tab: no query
    xor edi, edi
    mov esi, TAB_SETTINGS
    call app_add_tab
    jmp 4f
3:  mov rdi, rbx
    call app_activate_tab
4:  mov dword ptr [rip + g_focus], FOCUS_SETTINGS
    call settings_focus
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
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    cmp qword ptr [rax + DOC_selections], 0
    jne lines_newline_above              # several selections (editorlines.s)
1:  PROLOGUE 272
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
2:  cmp dword ptr [rip + g_insert_spaces], 0
    jne 3f
    mov byte ptr [rsp + r14], 9
    inc r14
    jmp 4f
3:  mov ecx, [rip + g_tab_width]
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
.Lpinned_stays: .asciz "The tab is pinned: unpin it to close it"
.Lrestart_link: .asciz "rhun://file"
.Lline_one: .asciz ":1:1"
.Lbad_link: .asciz "Not a rhun://file/ link"
.Ltrust_text: .asciz "Opened from a link: git is paused for "
.Ltrust_button: .asciz "Trust folder"
.Lnot_paused: .asciz "Git is not paused for this folder"
.Ltm_pin: .asciz "Pin Tab"
.Ltm_unpin: .asciz "Unpin Tab"
.Ltm_close: .asciz "Close Tab"
.Ltm_close_all: .asciz "Close All Tabs"
.p2align 3
# the menus of a tab and of a pinned tab
tab_menu:
    .quad .Ltm_pin, tab_menu_pin, .Lpm_line, 0
    .quad .Ltm_close, tab_menu_close, .Ltm_close_all, cmd_close_all, 0, 0
tab_menu_pinned:
    .quad .Ltm_unpin, tab_menu_unpin, .Lpm_line, 0
    .quad .Ltm_close, tab_menu_close, .Ltm_close_all, cmd_close_all, 0, 0
# font_paths: the settings that name font files (font_paths_hash); 0 ends it
font_paths:
    .quad cfg_font, cfg_ui_font, cfg_term_font, 0
# tip_table: button, text, the handler it runs (0: not a command, no shortcut); 0 ends it
tip_table:
    .quad ID_GIT_BTN, .Ltip_git, cmd_toggle_git
    .quad ID_TOG_TERM, .Ltip_term, cmd_toggle_terminal
    .quad ID_TOG_AGENTS, .Ltip_agents, cmd_toggle_agents
    .quad ID_SETTINGS_BTN, .Ltip_settings, cmd_settings
    .quad ID_XB_PUZZLE, .Ltip_extensions, 0
    .quad ID_TOG_SIDE, .Ltip_side, cmd_toggle_sidebar
    .quad ID_EXP_NEW, .Ltip_exp_new, 0
    .quad ID_EXP_NEW_FOLDER, .Ltip_exp_new_folder, 0
    .quad ID_EXP_REFRESH, .Ltip_exp_refresh, 0
    .quad ID_TAB_NEW, .Ltip_tab_new, cmd_new_file
    .quad ID_STATUS + 2, .Ltip_git, cmd_toggle_git
    .quad 0, 0, 0
.Ltip_git: .asciz "Git history"
.Ltip_term: .asciz "Terminal"
.Ltip_agents: .asciz "Agents"
.Ltip_settings: .asciz "Settings"
.Ldd_none: .asciz "dialog=none\n"
.Ldd_head: .asciz "dialog="
.Ldd_text: .asciz "text="
.Ldd_button: .asciz "button="
.Ltip_extensions: .asciz "Extensions"
.Lext_tab: .asciz "Extensions"
.Ltip_side: .asciz "File explorer"
.Ltip_exp_new: .asciz "New file"
.Ltip_exp_new_folder: .asciz "New folder"
.Ltip_exp_refresh: .asciz "Refresh explorer"
.Ltip_tab_new: .asciz "New file"
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
.Lempty_arg: .asciz "--empty"
.ifndef WINDOWS
.Lenv_new_window: .asciz "RHUN_NEW_WINDOW"
.Ldevnull: .asciz "/dev/null"
.ifndef MACOS
.Lproc_self_exe: .asciz "/proc/self/exe"
.Ldeleted: .asciz " (deleted)"
.endif
.endif
.Lpm_file: .asciz "Open File\342\200\246"
.Lpm_add_folder: .asciz "Add Folder to Workspace\342\200\246"
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
url_path: .zero 4096           # the path of a rhun:// link (app_open_path)

.text
# app_open_path(path): folder -> project, file -> tab (relative paths use the cwd). A rhun://file/
#   link opens its path, a file at its :LINE:COL; another rhun: link only says it is not one (unless
#   a file has that name)
FN app_open_path
    PROLOGUE 16
    mov rbx, rdi
    call links_open_path        # resources group: a rhun://ext/ link goes to its extension (links.s)
    test eax, eax
    jnz 9f
    mov rdi, rbx
    lea rsi, [rip + url_path]
    mov edx, 4096
    call rhun_url
    cmp rax, -1
    je .Lop_path
    cmp rax, -2
    jne 1f
    mov rdi, rbx
    call vfs_type
    test eax, eax
    jnz .Lop_path
    mov rdi, rbx
    call ext_link_open          # extension management: rhun://extension/OWNER/NAME[@VERSION]
    test eax, eax
    jnz 9f
    lea rdi, [rip + .Lbad_link]
    call app_toast
    EPILOGUE
1:  mov [rsp], edx
    mov [rsp + 4], ecx
    lea rdi, [rip + url_path]
    call path_normalize
    # a project it makes runs git once trusted (git_set_project)
    mov dword ptr [rip + g_link_open], 1
    lea rdi, [rip + url_path]
    call app_open_path
    mov dword ptr [rip + g_link_open], 0
    cmp dword ptr [rsp], 0
    je 9f
    # at its line, when the file opened (as the tab shown)
    lea rdi, [rip + url_path]
    call app_find_tab
    test rax, rax
    js 9f
    cmp rax, [rip + g_tab_cur]
    jne 9f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    call app_goto_line
    jmp 9f
.Lop_path:
    mov rdi, rbx
.ifdef WINDOWS
    cmp dword ptr [rip + g_remote], 0   # remote hosts: the host's paths stay POSIX (vfs.s)
    je 90f
    cmp byte ptr [rbx], '/'
    je .Lop_posix
90: call win_fullpath
    test rax, rax
    jnz 91f
    EPILOGUE
91: mov rbx, rax
    mov r13d, 1
    jmp 2f
.endif
.Lop_posix:
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
    mov rdi, rbx                # resources group: a workspace file opens its folders (workspace.s)
    call workspace_open_file
    test eax, eax
    jnz 8f
    mov rdi, rbx
    call vfs_is_dir
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

# app_path_is_dir(path) -> eax 1 for a folder, also one a rhun://file/ link names
FN app_path_is_dir
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + url_path]
    mov edx, 4096
    call rhun_url
    lea rdi, [rip + url_path]
    test rax, rax
    jns 1f
    mov rdi, rbx
1:  call vfs_is_dir
    EPILOGUE

# app_goto_line(line, col): the cursor of the text file shown to LINE and COL (counted from 1; COL in
#   source characters, as in rustc diagnostics: tabs and wide glyphs each count once, and the position
#   lands on a UTF-8 character boundary), with that line in the middle of the view
FN app_goto_line
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    test r12d, r12d
    jz 9f
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    cmp qword ptr [rbx + DOC_img], 0
    jne 9f
    lea rsi, [r12 - 1]
    mov rax, [rbx + DOC_nlines]
    dec rax
    cmp rsi, rax
    cmova rsi, rax
    mov r14, rsi
    lea edx, [r13 - 1]
    test edx, edx
    jns 2f
    xor edx, edx
2:  mov rdi, rbx
    mov rsi, r14
    call doc_pos_at_char
    mov rdi, rbx
    mov rsi, rax
    xor edx, edx
    call ed_set_cursor
    # before the editor's first frame (a link that started rhun) its height is not known: the
    # reveal when this file is first drawn centers the line
    mov ecx, [rip + g_ed_h_lines]
    test ecx, ecx
    jnz 31f
    or dword ptr [rbx + DOC_flags], DF_REVEAL | DF_CENTER
    jmp 4f
31:
    shr ecx, 1
    mov rax, r14
    sub rax, rcx
    jns 3f
    xor eax, eax
3:  shl rax, 8
    mov [rbx + DOC_scrolly], rax
4:  mov dword ptr [rip + g_reveal], 1
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE
