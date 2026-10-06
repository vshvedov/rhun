# settings: schema table, config file read/write (~/.config/rhun/config)
.include "rhun.inc"


.data
.p2align 2
.globl cfg_font_size, cfg_ui_font_size, cfg_line_height, cfg_tab_width, cfg_insert_spaces
.globl cfg_match_brackets
.globl cfg_animate_disk_changes, cfg_tooltips
.globl cfg_line_numbers, cfg_highlight_line, cfg_indent_guides, cfg_cursor_blink, cfg_whitespace
.globl cfg_sidebar, cfg_sidebar_w, cfg_agents, cfg_agents_w, cfg_ui_scale, cfg_final_newline
.globl cfg_trim_trailing, cfg_scroll_past_end, cfg_smooth_caret, cfg_theme, cfg_font, cfg_ui_font
.globl cfg_light_theme, cfg_dark_theme, cfg_theme_mode
.globl cfg_exclude, cfg_agent_sources, cfg_restore_session, cfg_auto_pairs, cfg_word_wrap, cfg_decorations
.globl cfg_vim
.globl cfg_restore_project
cfg_restore_project: .long 1
cfg_font_size: .long 14
cfg_ui_font_size: .long 13
cfg_line_height: .long 150
cfg_tab_width: .long 4
cfg_insert_spaces: .long 1
cfg_line_numbers: .long 1
cfg_highlight_line: .long 1
cfg_animate_disk_changes: .long 1
cfg_tooltips: .long 1
cfg_match_brackets: .long 1
cfg_indent_guides: .long 1
cfg_cursor_blink: .long 1
cfg_whitespace: .long 0
cfg_sidebar: .long 1
cfg_sidebar_w: .long 240
cfg_agents: .long 1
cfg_agents_w: .long 380
cfg_ui_scale: .long 100
cfg_final_newline: .long 1
cfg_trim_trailing: .long 0
cfg_scroll_past_end: .long 1
cfg_smooth_caret: .long 1
cfg_restore_session: .long 1
cfg_auto_pairs: .long 1
cfg_word_wrap: .long 0
cfg_vim: .long 0
cfg_decorations: .long 0         # 0 auto, 1 rhun draws the title bar, 2 the desktop does
cfg_theme_mode: .long 1          # 0 light, 1 dark, 2 system
.globl cfg_term_font_size, cfg_term_scrollback, cfg_term_h, cfg_term_shell, cfg_git
cfg_term_font_size: .long 14
cfg_term_scrollback: .long 10000
cfg_term_h: .long 260
cfg_git: .long 1
.globl cfg_commit_ai, cfg_commit_model
cfg_commit_ai: .long 0
.globl cfg_update_check
cfg_update_check: .long 1
.p2align 3
cfg_theme: .quad cfg_def_theme  # legacy [ui] theme key, migrated into a light/dark theme
cfg_light_theme: .quad cfg_def_light_theme
cfg_dark_theme: .quad cfg_def_dark_theme
cfg_font: .quad .Lempty
cfg_ui_font: .quad .Lempty
cfg_exclude: .quad .Ldef_exclude
cfg_agent_sources: .quad .Ldef_sources
cfg_term_shell: .quad .Lempty
cfg_commit_model: .quad .Ldefault_model
.Lcfg_strings_end:

.bss
.globl cfg_theme_seen
cfg_theme_seen: .long 0          # bit 0: mode, bit 1: light theme, bit 2: dark theme
.p2align 3
cfg_seen_mtime: .quad 0         # the config file's mtime (ns) when rhun last read or wrote it
# One owned allocation per string slot above. Theme selections can borrow registry IDs,
# so each slot also tracks its allocation separately.
.globl cfg_owned_strings
cfg_owned_strings: .zero .Lcfg_strings_end - cfg_theme
.p2align 3
cfg_path_buf: .zero 1024
cfg_dir_buf: .zero 1024
.globl g_keylines
g_keylines: .zero VEC_SIZE      # raw "combo = command" lines from [keys], as (ptr,len) pairs
it: .zero INI_SIZE
dir_cb: .quad 0
dir_ext: .quad 0
dir_path: .quad 0

.text

# config_dir() -> "~/.config/rhun" (static)
FN config_dir
    push rbx
    lea rbx, [rip + cfg_dir_buf]
    cmp byte ptr [rbx], 0
    jne 9f
    lea rdi, [rip + .Lxdg]
    call getenv
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 0
    jz 1f
    mov rdi, rbx
    mov rsi, rax
    call cstr_copy
    mov rdi, rax
    jmp 2f
1:  lea rdi, [rip + .Lhome]
    call getenv
    test rax, rax
    jnz 3f
    lea rax, [rip + .Ltmp]
3:  mov rdi, rbx
    mov rsi, rax
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Ldotconfig]
    call cstr_copy
    mov rdi, rax
2:  lea rsi, [rip + .Lrhun]
    call cstr_copy
9:  mov rax, rbx
    pop rbx
    ret

# cstr_copy(dst, src) -> pointer to dst's terminating NUL
FN cstr_copy
1:  mov al, [rsi]
    mov [rdi], al
    test al, al
    jz 2f
    inc rdi
    inc rsi
    jmp 1b
2:  mov rax, rdi
    ret

# config_path() -> ".../rhun/config"
FN config_path
    call config_dir
    lea rdi, [rip + cfg_path_buf]
    mov rsi, rax
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Lslash_config]
    call cstr_copy
    lea rax, [rip + cfg_path_buf]
    ret

# setting_find(sec, seclen, key, keylen) -> SET* or 0
setting_find:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    lea rbx, [rip + g_settings]
1:  cmp qword ptr [rbx + SET_key], 0
    je 3f
    cmp dword ptr [rbx + SET_type], ST_ACTION
    je 2f
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rbx + SET_sec]
    call str_eq_cstr
    test eax, eax
    jz 2f
    mov rdi, r14
    mov rsi, r15
    mov rdx, [rbx + SET_key]
    call str_eq_cstr
    test eax, eax
    jnz 4f
2:  add rbx, SET_SIZE
    jmp 1b
3:  xor ebx, ebx
4:  mov rax, rbx
    EPILOGUE

# setting_assign(SET*, value ptr, len)
FN setting_assign
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, [rbx + SET_ptr]
    mov eax, [rbx + SET_type]
    cmp eax, ST_BOOL
    jne 1f
    mov rdi, r12
    mov rsi, r13
    call parse_bool
    mov [r14], eax
    jmp 9f
1:  cmp eax, ST_INT
    jne 2f
    mov rdi, r12
    mov rsi, r13
    call parse_decimal
    test edx, edx
    jz 9f
    cmp dword ptr [rbx + SET_decimal], 0
    je 10f
    # "2" means 2.0 for decimal settings
    mov r15d, eax
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Ldot]
    mov ecx, 1
    call str_find
    mov ecx, r15d
    imul r15d, r15d, 100
    test rax, rax
    cmovns r15d, ecx
    mov eax, r15d
10: cmp eax, [rbx + SET_min]
    jge 11f
    mov eax, [rbx + SET_min]
11: cmp eax, [rbx + SET_max]
    jle 12f
    mov eax, [rbx + SET_max]
12: mov [r14], eax
    jmp 9f
2:  cmp eax, ST_CHOICE
    jne 3f
    xor r15d, r15d
21: mov rdi, [rbx + SET_opts]
    mov esi, r15d
    call choice_entry
    test rax, rax
    jz 9f                       # unknown value: keep the current one
    mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    call str_ieq_cstr
    test eax, eax
    jnz 22f
    inc r15d
    jmp 21b
22: mov [r14], r15d
    jmp 9f
3:  # Copy first: the input may be the current setting's own allocation.
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov r15, rax
    lea rax, [rip + cfg_theme]
    mov rcx, r14
    sub rcx, rax
    lea r12, [rip + cfg_owned_strings]
    add r12, rcx
    mov rdi, [r12]
    call mem_free
    mov [r12], r15
    mov [r14], r15
9:  EPILOGUE

# choice_entry(opts, index) -> rax config value, rdx label (rax = 0 past the end)
FN choice_entry
    mov rax, rdi
1:  cmp byte ptr [rax], 0
    je 8f
    mov r8, rax
2:  cmp byte ptr [rax], 0
    je 3f
    inc rax
    jmp 2b
3:  inc rax
    mov rdx, rax
4:  cmp byte ptr [rax], 0
    je 5f
    inc rax
    jmp 4b
5:  inc rax
    test esi, esi
    jz 6f
    dec esi
    jmp 1b
6:  mov rax, r8
    ret
8:  xor eax, eax
    ret

# parse_decimal(ptr, len) -> eax value, edx ok. "1.5" -> 150 (two implied decimals only when a dot is present)
FN parse_decimal
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    call parse_u64
    test rdx, rdx
    jz 8f
    cmp rdx, r12
    je 7f
    cmp byte ptr [rbx + rdx], '.'
    jne 7f
    # fractional: value*100 + two digits
    imul eax, eax, 100
    mov ecx, eax
    lea rdi, [rbx + rdx + 1]
    mov rsi, r12
    sub rsi, rdx
    dec rsi
    push rcx
    call parse_u64
    pop rcx
    cmp rdx, 1
    jne 1f
    imul eax, eax, 10
    jmp 2f
1:  cmp rdx, 2
    je 2f
    xor eax, eax
2:  add eax, ecx
7:  mov edx, 1
    pop r12
    pop rbx
    ret
8:  xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    ret

# config_load(): read the config file if present
FN config_load
    PROLOGUE 16
    mov dword ptr [rip + cfg_theme_seen], 0
    xor r15d, r15d              # owned input buffer, if the config exists
    # [keys] lines come from this read only
    xor ebx, ebx
1:  cmp rbx, [rip + g_keylines + VEC_len]
    jae 2f
    mov r12, rbx
    shl r12, 5
    add r12, [rip + g_keylines + VEC_ptr]
    mov rdi, [r12]
    call mem_free
    mov rdi, [r12 + 16]
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + g_keylines + VEC_len], 0
    # taken before the read: a write that lands during it still counts as a change
    call config_path
    mov rdi, rax
    call file_mtime_ns
    mov [rip + cfg_seen_mtime], rax
    call config_path
    mov rdi, rax
    call file_read_all
    test rax, rax
    jz .Lcl_ret
    mov r15, rax
    lea rdi, [rip + it]
    mov rsi, rax
    call ini_init
.Lcl_next:
    lea rdi, [rip + it]
    call ini_next
    test eax, eax
    jz .Lcl_ret
    lea rdi, [rip + it]
    lea rsi, [rip + .Lkeys]
    call ini_sec_is
    test eax, eax
    jz 1f
    # [keys]: remember "combo = command"
    lea rdi, [rip + g_keylines]
    mov esi, 32
    call vec_push
    mov rbx, rax
    mov rdi, [rip + it + INI_key]
    mov rsi, [rip + it + INI_keylen]
    call mem_dup
    mov [rbx], rax
    mov rax, [rip + it + INI_keylen]
    mov [rbx + 8], rax
    mov rdi, [rip + it + INI_val]
    mov rsi, [rip + it + INI_vallen]
    call mem_dup
    mov [rbx + 16], rax
    mov rax, [rip + it + INI_vallen]
    mov [rbx + 24], rax
    jmp .Lcl_next
1:  lea rdi, [rip + it]
    lea rsi, [rip + .Ls_ui]
    call ini_sec_is
    test eax, eax
    jz 2f
    lea rdi, [rip + it]
    lea rsi, [rip + .Ltheme]
    call ini_key_is
    test eax, eax
    jz 2f
    # Read the old single-theme key so existing configs keep their chosen theme.
    lea rdi, [rip + .Llegacy_theme_setting]
    mov rsi, [rip + it + INI_val]
    mov rdx, [rip + it + INI_vallen]
    call setting_assign
    jmp .Lcl_next
2:  mov rdi, [rip + it + INI_sec]
    mov rsi, [rip + it + INI_seclen]
    mov rdx, [rip + it + INI_key]
    mov rcx, [rip + it + INI_keylen]
    call setting_find
    test rax, rax
    jz .Lcl_next
    mov rcx, [rax + SET_ptr]
    lea rdx, [rip + cfg_theme_mode]
    cmp rcx, rdx
    jne 21f
    or dword ptr [rip + cfg_theme_seen], 1
21: lea rdx, [rip + cfg_light_theme]
    cmp rcx, rdx
    jne 22f
    or dword ptr [rip + cfg_theme_seen], 2
22: lea rdx, [rip + cfg_dark_theme]
    cmp rcx, rdx
    jne 23f
    or dword ptr [rip + cfg_theme_seen], 4
23: mov rdi, rax
    mov rsi, [rip + it + INI_val]
    mov rdx, [rip + it + INI_vallen]
    call setting_assign
    jmp .Lcl_next
.Lcl_ret:
    mov rdi, r15
    call mem_free
    EPILOGUE

# config_save(): write every setting (and custom keys) back to the file
FN config_save
    PROLOGUE 32
    lea rdi, [rsp]
    xor esi, esi
    mov edx, SB_SIZE
    call memset
    lea rdi, [rsp]
    lea rsi, [rip + .Lheader]
    call sb_push_cstr
    lea rbx, [rip + g_settings]
    xor r12d, r12d              # previous section
.Lcs_next:
    cmp qword ptr [rbx + SET_key], 0
    je .Lcs_keys
    cmp dword ptr [rbx + SET_type], ST_ACTION
    je .Lcs_skip
    mov rax, [rbx + SET_sec]
    cmp rax, r12
    je 1f
    mov r12, rax
    lea rdi, [rsp]
    lea rsi, [rip + .Lnl_bracket]
    call sb_push_cstr
    lea rdi, [rsp]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rsp]
    lea rsi, [rip + .Lbracket_nl]
    call sb_push_cstr
1:  lea rdi, [rsp]
    mov rsi, [rbx + SET_key]
    call sb_push_cstr
    lea rdi, [rsp]
    lea rsi, [rip + .Leq]
    call sb_push_cstr
    mov r13, [rbx + SET_ptr]
    mov eax, [rbx + SET_type]
    cmp eax, ST_BOOL
    jne 2f
    lea rsi, [rip + .Lfalse]
    lea rcx, [rip + .Ltrue]
    cmp dword ptr [r13], 0
    cmovne rsi, rcx
    lea rdi, [rsp]
    call sb_push_cstr
    jmp 5f
2:  cmp eax, ST_INT
    jne 4f
    cmp dword ptr [rbx + SET_decimal], 0
    jne 3f
    lea rdi, [rsp]
    mov esi, [r13]
    call sb_push_u64
    jmp 5f
3:  mov eax, [r13]
    xor edx, edx
    mov ecx, 100
    div ecx
    mov r14d, edx
    lea rdi, [rsp]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rsp]
    mov esi, '.'
    call sb_push_byte
    mov eax, r14d
    xor edx, edx
    mov ecx, 10
    div ecx
    mov r14d, edx
    lea rdi, [rsp]
    lea esi, [rax + '0']
    call sb_push_byte
    test r14d, r14d
    jz 5f
    lea rdi, [rsp]
    lea esi, [r14 + '0']
    call sb_push_byte
    jmp 5f
4:  cmp eax, ST_CHOICE
    jne 41f
    mov rdi, [rbx + SET_opts]
    mov esi, [r13]
    call choice_entry
    test rax, rax
    jz 5f
    lea rdi, [rsp]
    mov rsi, rax
    call sb_push_cstr
    jmp 5f
41: lea rdi, [rsp]
    mov rsi, [r13]
    call sb_push_cstr
5:  lea rdi, [rsp]
    mov esi, 10
    call sb_push_byte
.Lcs_skip:
    add rbx, SET_SIZE
    jmp .Lcs_next
.Lcs_keys:
    lea rdi, [rsp]
    lea rsi, [rip + .Lkeys_hdr]
    call sb_push_cstr
    xor ebx, ebx
6:  cmp rbx, [rip + g_keylines + VEC_len]
    jae 7f
    mov r13, rbx
    shl r13, 5
    add r13, [rip + g_keylines + VEC_ptr]
    lea rdi, [rsp]
    mov rsi, [r13]
    mov rdx, [r13 + 8]
    call sb_push
    lea rdi, [rsp]
    lea rsi, [rip + .Leq]
    call sb_push_cstr
    lea rdi, [rsp]
    mov rsi, [r13 + 16]
    mov rdx, [r13 + 24]
    call sb_push
    lea rdi, [rsp]
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 6b
7:  call config_dir
    lea rdi, [rip + cfg_dir_buf]
    call mkdir_p
    call config_path
    mov rdi, rax
    mov rsi, [rsp + SB_ptr]
    mov rdx, [rsp + SB_len]
    call file_write_all
    mov rbx, rax
    call config_path
    mov rdi, rax
    call file_mtime_ns
    mov [rip + cfg_seen_mtime], rax
    lea rdi, [rsp]
    call sb_free
    mov rax, rbx
    EPILOGUE

# config_changed() -> 1 when the config file is not the one rhun last read or wrote. A watcher can
# report a write late, after rhun has started and read it (macOS FSEvents does); reloading then
# would undo settings changed since.
FN config_changed
    PROLOGUE
    call config_path
    mov rdi, rax
    call file_mtime_ns
    xor ecx, ecx
    cmp rax, [rip + cfg_seen_mtime]
    setne cl
    mov eax, ecx
    EPILOGUE

# config_dir_each(subdir, ext, cb): cb(path, name) for ~/.config/rhun/<subdir>/*<ext>
FN config_dir_each
    PROLOGUE 16
    mov [rip + dir_ext], rsi
    mov [rip + dir_cb], rdx
    mov rbx, rdi
    call config_dir
    mov rdi, rax
    mov rsi, rbx
    call path_join
    mov [rip + dir_path], rax
    mov rdi, rax
    lea rsi, [rip + dir_each_cb]
    xor edx, edx
    call dir_each
    mov rdi, [rip + dir_path]
    call mem_free
    EPILOGUE

dir_each_cb:
    PROLOGUE
    test edx, edx
    jnz 9f
    mov rbx, rsi
    mov rdi, rsi
    call strlen
    mov r12, rax
    mov rdi, [rip + dir_ext]
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rip + dir_ext]
    mov rcx, rax
    call str_ends
    test eax, eax
    jz 9f
    mov rdi, [rip + dir_path]
    mov rsi, rbx
    call path_join
    mov r12, rax
    mov rdi, rax
    mov rsi, rbx
    call [rip + dir_cb]
    mov rdi, r12
    call mem_free
9:  EPILOGUE

.section .rodata
.globl cfg_def_theme, cfg_def_light_theme, cfg_def_dark_theme
cfg_def_theme: .asciz "rhun-dark"
cfg_def_light_theme: .asciz "rhun-light"
cfg_def_dark_theme: .asciz "rhun-dark"
.p2align 3
.Llegacy_theme_setting:
    .quad 0, 0, cfg_theme, 0, 0
    .long ST_STR, 0, 0, 0, 0, 0
    .quad 0
.Lempty: .asciz ""
.Ldef_exclude: .asciz ".git node_modules target build .cache __pycache__ .venv .idea .DS_Store"
.Ldef_sources: .asciz "claude codex"
.Lxdg: .asciz "XDG_CONFIG_HOME"
.Lhome: .asciz "HOME"
.Ltmp: .asciz "/tmp"
.Ldotconfig: .asciz "/.config"
.Lrhun: .asciz "/rhun"
.Lslash_config: .asciz "/config"
.Lkeys: .asciz "keys"
.Lheader: .ascii "# rhun configuration. Also editable from Settings (ctrl+,).\n"
          .asciz "# Changes are picked up while rhun is running.\n"
.Lnl_bracket: .asciz "\n["
.Lbracket_nl: .asciz "]\n"
.Leq: .asciz " = "
.Ldot: .ascii "."
.Ltrue: .asciz "true"
.Lfalse: .asciz "false"
.Lkeys_hdr: .asciz "\n[keys]\n# ctrl+shift+d = duplicate_line\n"

.Ls_editor: .asciz "editor"
.Ls_ui: .asciz "ui"
.Ltheme: .asciz "theme"
.Ls_files: .asciz "files"
.Ls_agents: .asciz "agents"
.Ls_terminal: .asciz "terminal"
.Ls_git: .asciz "git"
.Ls_updates: .asciz "updates"

.macro SETTING sec, key, type, ptr, min, max, step, dec, label, desc, opts=0, live_desc=0
    .quad \sec, 1f, \ptr, 2f
.ifc \live_desc,0
    .quad 3f
.else
    .quad \live_desc
.endif
    .long \type, \min, \max, \step, \dec, 0
    .quad \opts
    .pushsection .rodata.str, "aMS", @progbits, 1
1:  .asciz "\key"
2:  .asciz "\label"
3:  .asciz "\desc"
    .popsection
.endm

# a button row: fn runs on a click; label and desc point at text that may change
.macro SETTING_ACTION sec, key, fn, label, desc
    .quad \sec, 1f, \fn, \label, \desc
    .long ST_ACTION, 0, 0, 0, 0, 0
    .quad 0
    .pushsection .rodata.str, "aMS", @progbits, 1
1:  .asciz "\key"
    .popsection
.endm

.p2align 3
.globl g_settings
g_settings:
    SETTING .Ls_ui, light_theme, ST_THEME, cfg_light_theme, 0, 0, 0, 0, "Light theme", "Theme used in light mode."
    SETTING .Ls_ui, dark_theme, ST_THEME, cfg_dark_theme, 0, 0, 0, 0, "Dark theme", "Theme used in dark mode."
    SETTING .Ls_ui, theme_mode, ST_CHOICE, cfg_theme_mode, 0, 2, 1, 0, "Theme mode", "Choose light, dark, or the system appearance.", .Ltheme_mode_opts
    SETTING .Ls_ui, scale, ST_INT, cfg_ui_scale, 50, 300, 10, 1, "Interface zoom", "Scales everything on top of the display scale."
    SETTING .Ls_ui, font_size, ST_INT, cfg_ui_font_size, 9, 24, 1, 0, "Interface font size", "Font size of panels, tabs and menus."
    SETTING .Ls_ui, font, ST_STR, cfg_ui_font, 0, 0, 0, 0, "Interface font", "Path to a .ttf file. Empty uses the built-in Iosevka."
    SETTING .Ls_ui, sidebar, ST_BOOL, cfg_sidebar, 0, 1, 1, 0, "Show file explorer", "Project tree on the left (ctrl+b)."
    SETTING .Ls_ui, sidebar_width, ST_INT, cfg_sidebar_w, 140, 600, 10, 0, "Explorer width", "Width of the file explorer in points."
    SETTING .Ls_ui, agents_panel, ST_BOOL, cfg_agents, 0, 1, 1, 0, "Show agents panel", "Agent sessions on the right (ctrl+shift+a)."
    SETTING .Ls_ui, agents_width, ST_INT, cfg_agents_w, 240, 900, 10, 0, "Agents panel width", "Width of the agents panel in points."
    SETTING .Ls_ui, tooltips, ST_BOOL, cfg_tooltips, 0, 1, 1, 0, "Tooltips", "Show a button's name and shortcut on hover."
    SETTING .Ls_ui, decorations, ST_CHOICE, cfg_decorations, 0, 2, 1, 0, "Title bar", "Who draws window buttons on Wayland. Auto leaves tiling desktops bare.", .Ldeco_opts
    SETTING .Ls_editor, font_size, ST_INT, cfg_font_size, 8, 40, 1, 0, "Editor font size", "Font size of the text you edit."
    SETTING .Ls_editor, font, ST_STR, cfg_font, 0, 0, 0, 0, "Editor font", "Path to a monospace .ttf file. Empty uses the built-in Iosevka."
    SETTING .Ls_editor, line_height, ST_INT, cfg_line_height, 100, 250, 5, 1, "Line height", "Multiple of the font size."
    SETTING .Ls_editor, tab_width, ST_INT, cfg_tab_width, 1, 16, 1, 0, "Tab width", "Columns per tab stop."
    SETTING .Ls_editor, insert_spaces, ST_BOOL, cfg_insert_spaces, 0, 1, 1, 0, "Indent with spaces", "Tab key inserts spaces instead of a tab character."
    SETTING .Ls_editor, line_numbers, ST_BOOL, cfg_line_numbers, 0, 1, 1, 0, "Line numbers", "Show line numbers in the gutter."
    SETTING .Ls_editor, highlight_line, ST_BOOL, cfg_highlight_line, 0, 1, 1, 0, "Highlight current line", "Tint the line under the cursor."
    SETTING .Ls_editor, animate_disk_changes, ST_BOOL, cfg_animate_disk_changes, 0, 1, 1, 0, "Animate changed text", "Briefly highlight text changed on disk by agents or other tools."
    SETTING .Ls_editor, match_brackets, ST_BOOL, cfg_match_brackets, 0, 1, 1, 0, "Match brackets", "Outline the bracket at the cursor and its partner."
    SETTING .Ls_editor, indent_guides, ST_BOOL, cfg_indent_guides, 0, 1, 1, 0, "Indent guides", "Thin vertical lines at indentation levels."
    SETTING .Ls_editor, word_wrap, ST_BOOL, cfg_word_wrap, 0, 1, 1, 0, "Word wrap", "Wrap long lines at the edge of the editor (alt+z)."
    SETTING .Ls_editor, whitespace, ST_BOOL, cfg_whitespace, 0, 1, 1, 0, "Show whitespace", "Draw dots for spaces and arrows for tabs."
    SETTING .Ls_editor, cursor_blink, ST_BOOL, cfg_cursor_blink, 0, 1, 1, 0, "Blinking cursor", "Blink the text cursor while idle."
    SETTING .Ls_editor, smooth_caret, ST_BOOL, cfg_smooth_caret, 0, 1, 1, 0, "Wide caret", "Draw a 2 point caret instead of a hairline."
    SETTING .Ls_editor, auto_pairs, ST_BOOL, cfg_auto_pairs, 0, 1, 1, 0, "Auto-close brackets", "Insert the closing bracket or quote."
    SETTING .Ls_editor, scroll_past_end, ST_BOOL, cfg_scroll_past_end, 0, 1, 1, 0, "Scroll past end", "Allow scrolling the last line to the top."
    SETTING .Ls_editor, vim_mode, ST_BOOL, cfg_vim, 0, 1, 1, 0, "Vim mode", "Normal, insert and visual modes with vim keys."
    SETTING .Ls_files, trim_trailing_whitespace, ST_BOOL, cfg_trim_trailing, 0, 1, 1, 0, "Trim trailing whitespace", "Remove spaces at line ends when saving."
    SETTING .Ls_files, final_newline, ST_BOOL, cfg_final_newline, 0, 1, 1, 0, "Final newline", "Make sure saved files end with a newline."
    SETTING .Ls_files, restore_session, ST_BOOL, cfg_restore_session, 0, 1, 1, 0, "Restore open files", "Reopen the files from the last session of a project."
    SETTING .Ls_files, restore_project, ST_BOOL, cfg_restore_project, 0, 1, 1, 0, "Reopen last project", "Reopen the project you closed with when no file or folder is given."
    SETTING .Ls_files, exclude, ST_STR, cfg_exclude, 0, 0, 0, 0, "Hidden in explorer", "Space separated names the explorer skips."
    SETTING .Ls_agents, sources, ST_STR, cfg_agent_sources, 0, 0, 0, 0, "Agent sources", "Which agents to show: claude, codex."
    SETTING .Ls_terminal, shell, ST_STR, cfg_term_shell, 0, 0, 0, 0, "Shell", "Program the terminal runs. Empty uses $SHELL."
    SETTING .Ls_terminal, font_size, ST_INT, cfg_term_font_size, 8, 40, 1, 0, "Terminal font size", "Font size of the terminal panel."
    SETTING .Ls_terminal, scrollback, ST_INT, cfg_term_scrollback, 0, 100000, 1000, 0, "Scrollback", "Lines each terminal keeps above its screen."
    SETTING .Ls_terminal, height, ST_INT, cfg_term_h, 80, 2000, 10, 0, "Terminal height", "Height of the terminal panel in points."
    SETTING .Ls_git, enabled, ST_BOOL, cfg_git, 0, 1, 1, 0, "Git", "Changes in the gutter, tabs and explorer, and the history view."
    SETTING .Ls_git, commit_ai, ST_CHOICE, cfg_commit_ai, 0, 3, 1, 0, "Commit message AI", "Optional. Cloud providers use your subscription.", .Lai_opts, g_ai_provider_desc
    SETTING .Ls_git, commit_model, ST_STR, cfg_commit_model, 0, 0, 0, 0, "Local model", "Ollama model name. Default download: about 1 GB."
    SETTING_ACTION .Ls_git, ai_setup, cmd_ai_model_files, .Lai_setup, g_ai_local_desc
    SETTING .Ls_updates, check, ST_BOOL, cfg_update_check, 0, 1, 1, 0, "Check for updates", "Look for a new version at startup and once a day."
    SETTING_ACTION .Ls_updates, check_now, cmd_check_for_updates, g_version_text, g_update_desc
    .quad 0, 0, 0, 0, 0
    .long 0, 0, 0, 0, 0, 0
.Ldeco_opts: .asciz "auto", "Auto", "client", "rhun", "server", "Desktop", ""
.Ltheme_mode_opts: .asciz "light", "Light", "dark", "Dark", "system", "System (Auto)", ""

.Ldefault_model: .asciz "qwen2.5-coder:1.5b"
.Lai_opts: .asciz "off", "Off", "claude", "Claude Code", "codex", "Codex", "ollama", "Local (Ollama)", ""
.Lai_setup: .asciz "Local model files"
