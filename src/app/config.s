# settings: schema table, config file read/write (~/.config/rhun/config)
.include "rhun.inc"


.data
.p2align 2
.globl cfg_font_size, cfg_ui_font_size, cfg_line_height, cfg_tab_width, cfg_insert_spaces
.globl cfg_match_brackets
.globl cfg_animate_disk_changes, cfg_tooltips, cfg_autohide_scrollbars
.globl cfg_line_numbers, cfg_highlight_line, cfg_indent_guides, cfg_cursor_blink, cfg_whitespace
.globl cfg_sidebar, cfg_sidebar_w, cfg_agents, cfg_agents_w, cfg_ui_scale, cfg_final_newline
.globl cfg_trim_trailing, cfg_scroll_past_end, cfg_smooth_caret, cfg_theme, cfg_font, cfg_ui_font
.globl cfg_exclude, cfg_agent_sources, cfg_restore_session, cfg_auto_pairs, cfg_word_wrap, cfg_decorations
.globl cfg_agents_claude, cfg_agents_codex, cfg_agents_grok, cfg_agents_opencode
.globl cfg_vim
.globl cfg_restore_project
.globl cfg_auto_save, cfg_auto_save_delay
.globl cfg_follow_system, cfg_dark_theme, cfg_light_theme, cfg_theme_keys
cfg_restore_project: .long 1
cfg_auto_save: .long 0
cfg_auto_save_delay: .long 1000
.globl cfg_test_gutter
cfg_test_gutter: .long 1        # testing: [testing] gutter, the tests' glyphs in the gutter
cfg_font_size: .long 14
cfg_ui_font_size: .long 13
cfg_line_height: .long 150
cfg_tab_width: .long 4
cfg_insert_spaces: .long 1
cfg_line_numbers: .long 1
cfg_highlight_line: .long 1
cfg_animate_disk_changes: .long 1
cfg_tooltips: .long 1
cfg_autohide_scrollbars: .long 1
cfg_match_brackets: .long 1
cfg_indent_guides: .long 1
.globl cfg_folding
cfg_folding: .long 1            # editor presentation: folding (fold.s)
.globl cfg_semantic_highlighting
cfg_semantic_highlighting: .long 1      # editor presentation: semantic tokens (semtok.s)
.globl cfg_inlay_hints
cfg_inlay_hints: .long 1        # editor presentation: inlay hints (inlay.s)
.globl cfg_code_lens
cfg_code_lens: .long 1          # editor presentation: code lens (lens.s)
.globl cfg_highlight_occurrences
cfg_highlight_occurrences: .long 1      # editor presentation: the caret's word's occurrences (hicolor.s)
.globl cfg_color_swatches
cfg_color_swatches: .long 1     # editor presentation: color swatches (hicolor.s)
.globl cfg_inline_complete, cfg_inline_complete_delay
cfg_inline_complete: .long 1    # editor presentation: inline completion as you type (ghost.s)
cfg_inline_complete_delay: .long 300    # its pause after typing, ms
cfg_cursor_blink: .long 1
cfg_whitespace: .long 0
cfg_sidebar: .long 1
cfg_sidebar_w: .long SIDEBAR_W_DEFAULT
cfg_agents: .long 1
cfg_agents_w: .long AGENTS_W_DEFAULT
cfg_ui_scale: .long 100
cfg_final_newline: .long 1
cfg_trim_trailing: .long 0
.globl cfg_format_on_save, cfg_format_save_timeout
cfg_format_on_save: .long 0
cfg_format_save_timeout: .long 2000
.globl cfg_save_actions_timeout
cfg_save_actions_timeout: .long 2000
cfg_scroll_past_end: .long 1
cfg_smooth_caret: .long 1
cfg_restore_session: .long 1
cfg_auto_pairs: .long 1
.globl cfg_multi_cursor_paste
cfg_multi_cursor_paste: .long 0
.globl cfg_multi_cursor_modifier
cfg_multi_cursor_modifier: .long 0  # 0 alt, 1 ctrl (Command on macOS): adds carets with the mouse
cfg_word_wrap: .long 0
# language features (query.s, complete.s, langfeat.s)
.globl cfg_complete_replace, cfg_complete_commit, cfg_lightbulb, cfg_format_on_type, cfg_format_on_paste
cfg_complete_replace: .long 0    # accepting replaces the rest of the word (the item's replace range)
cfg_complete_commit: .long 1     # an item's commit characters accept it
cfg_lightbulb: .long 1
cfg_format_on_type: .long 0
cfg_format_on_paste: .long 0
cfg_vim: .long 0
cfg_decorations: .long 0         # 0 auto, 1 rhun draws the title bar, 2 the desktop does
cfg_follow_system: .long 1       # dark_theme or light_theme as the system's dark mode is on or off
cfg_agents_claude: .long 1       # the providers the agents panel lists, in this order (settings.s)
cfg_agents_codex: .long 1
cfg_agents_grok: .long 1
cfg_agents_opencode: .long 1
.globl cfg_scroll_sens, cfg_fast_sens
cfg_scroll_sens: .long 100       # scroll_sensitivity: multiplier in hundredths
cfg_fast_sens: .long 400         # fast_scroll_sensitivity: multiplier while alt is held
.globl cfg_term_font_size, cfg_term_scrollback, cfg_term_h, cfg_term_shell, cfg_git
.globl cfg_term_line_height, cfg_term_font
cfg_term_font_size: .long 14
cfg_term_line_height: .long 100  # line_height: hundredths of the font's own line height
cfg_term_scrollback: .long 10000
cfg_term_h: .long 260
cfg_git: .long 1
.globl cfg_commit_ai, cfg_commit_model
cfg_commit_ai: .long 0
.globl cfg_update_check
cfg_update_check: .long 1
.globl cfg_secrets               # resources group: where extensions keep secrets (SB_*)
cfg_secrets: .long 0
.globl cfg_ext_updates
cfg_ext_updates: .long 0         # [updates] extensions: XM_INSTALL, XM_CHECK or XM_OFF (extension management)
.p2align 3
cfg_theme: .quad cfg_def_theme
cfg_dark_theme: .quad cfg_def_theme
cfg_light_theme: .quad cfg_def_light_theme
cfg_font: .quad .Lempty
cfg_ui_font: .quad .Lempty
.globl cfg_file_icons
cfg_file_icons: .quad .Lempty   # [ui] file_icons: rhun (empty), none or OWNER/NAME/THEME (iconth.s)
cfg_exclude: .quad .Ldef_exclude
cfg_term_shell: .quad .Lempty
cfg_term_font: .quad .Lempty
cfg_commit_model: .quad .Ldefault_model
.globl cfg_save_actions
cfg_save_actions: .quad .Lempty
.globl cfg_remote_agent_binary
cfg_remote_agent_binary: .quad .Lempty  # remote hosts: the Linux rhun to start on hosts (remote.s)
.Lcfg_strings_end:
cfg_agent_sources: .quad .Ldef_sources  # the switched-on providers' names, for the discovery worker

.bss
.p2align 3
cfg_seen_mtime: .quad 0         # the config file's mtime (ns) when rhun last read or wrote it
cfg_theme_keys: .long 0         # theme keys the last read found: 1 theme, 2 dark_theme, 4 light_theme
old_sources: .long 0            # the last read found [agents] sources = claude codex, the old default
agent_sources_buf: .zero 32
# One owned allocation per string slot above. The theme slots may separately borrow
# a theme registry ID, so the current value alone does not identify its owner.
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
FN setting_find
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
    # source control (wider-parity C): commit_ai = ext:OWNER/NAME names an extension (scmext.s)
    lea rax, [rip + cfg_commit_ai]
    cmp r14, rax
    jne 20f
    mov rdi, r12
    mov rsi, r13
    call scmext_ai_config
    test eax, eax
    jnz 9f
20: xor r15d, r15d
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
    lea rax, [rip + cfg_save_actions]
    cmp r14, rax
    jne 31f
    mov rdi, r12
    mov rsi, r13
    call save_actions_config
    test rax, rax
    jz 9f                       # invalid candidate preserves the last valid setting
    jmp 32f
31:
    mov rdi, r12
    mov rsi, r13
    call mem_dup
32:
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
    xor r15d, r15d              # owned input buffer, if the config exists
    mov dword ptr [rip + cfg_theme_keys], 0
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
    mov dword ptr [rip + old_sources], 0
    call agentext_config_reset  # AI: the extension sources switched off come from this read
    call ce_config_reset        # custom editors: the [editors] choices too (customed.s)
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
1:  lea rdi, [rip + it]         # custom editors: [editors] PATTERN = OWNER/NAME | text
    lea rsi, [rip + .Leditors]
    call ini_sec_is
    test eax, eax
    jz 11f
    mov rdi, [rip + it + INI_key]
    mov rsi, [rip + it + INI_keylen]
    mov rdx, [rip + it + INI_val]
    mov rcx, [rip + it + INI_vallen]
    call ce_config_kv
    jmp .Lcl_next
11: mov rdi, [rip + it + INI_sec]
    mov rsi, [rip + it + INI_seclen]
    mov rdx, [rip + it + INI_key]
    mov rcx, [rip + it + INI_keylen]
    call setting_find
    test rax, rax
    jnz 3f
    mov rdi, [rip + it + INI_sec]   # AI: [agents] OWNER/NAME = false (agentext.s)
    mov rsi, [rip + it + INI_seclen]
    mov rdx, [rip + it + INI_key]
    mov rcx, [rip + it + INI_keylen]
    mov r8, [rip + it + INI_val]
    mov r9, [rip + it + INI_vallen]
    call agentext_config_key
    call legacy_sources
    jmp .Lcl_next
3:  # which theme keys the file has: a file from before dark_theme and light_theme has theme only
    mov rcx, [rax + SET_ptr]
    lea rdx, [rip + cfg_theme]
    sub rcx, rdx
    shr rcx, 3
    cmp rcx, 2
    ja 2f
    mov edx, 1
    shl edx, cl
    or [rip + cfg_theme_keys], edx
2:  mov rdi, rax
    mov rsi, [rip + it + INI_val]
    mov rdx, [rip + it + INI_vallen]
    call setting_assign
    jmp .Lcl_next
.Lcl_ret:
    # Grok Build came with dark_theme: a file from before that has the old default sources gets it too,
    # while one written since keeps what is set
    test dword ptr [rip + cfg_theme_keys], 2
    jnz 1f
    cmp dword ptr [rip + old_sources], 0
    je 1f
    mov dword ptr [rip + cfg_agents_grok], 1
1:  call config_agent_sources
    call agentext_config_done   # AI: the extension sources' switches from this read
    mov rdi, r15
    call mem_free
    EPILOGUE

# legacy_sources(): [agents] sources from before the switches names the providers listed. OpenCode came
#   with the switches: no such line turns it off. config_save writes the switches in its place.
legacy_sources:
    PROLOGUE
    lea rdi, [rip + .Ls_agents]
    mov rsi, [rip + it + INI_sec]
    mov rdx, [rip + it + INI_seclen]
    mov ecx, 6
    call ini_field_is
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lsources_key]
    mov rsi, [rip + it + INI_key]
    mov rdx, [rip + it + INI_keylen]
    mov ecx, 7
    call ini_field_is
    test eax, eax
    jz 9f
    mov rdi, [rip + it + INI_val]
    mov rsi, [rip + it + INI_vallen]
    call mem_dup
    mov r12, rax
    lea rdi, [rip + .Lold_sources]
    mov rsi, r12
    call strcmp_eq
    mov [rip + old_sources], eax
    lea rbx, [rip + legacy_names]
1:  mov r13, [rbx]
    test r13, r13
    jz 2f
    mov rdi, r13
    call strlen
    mov r14, rax
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    mov rdx, r13
    mov rcx, r14
    call str_find
    not rax
    shr rax, 63
    mov rcx, [rbx + 8]
    mov [rcx], eax
    add rbx, 16
    jmp 1b
2:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# ini_field_is(name, ptr, len, name length) -> 1 when the ini field is that name
ini_field_is:
    xor eax, eax
    cmp rdx, rcx
    jne 1f
    mov rdx, rcx
    jmp memeq
1:  ret

# config_agent_sources(): cfg_agent_sources names the providers switched on, as the worker takes them
FN config_agent_sources
    PROLOGUE
    lea rbx, [rip + agent_sources_buf]
    mov rax, rbx
    lea r12, [rip + agent_names]
1:  mov rcx, [r12 + 8]
    test rcx, rcx
    jz 3f
    cmp dword ptr [rcx], 0
    je 2f
    cmp rax, rbx
    je 11f
    mov byte ptr [rax], ' '
    inc rax
11: mov rdi, rax
    mov rsi, [r12]
    call cstr_copy
2:  add r12, 16
    jmp 1b
3:  mov byte ptr [rax], 0
    mov [rip + cfg_agent_sources], rbx
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
    lea rax, [rip + cfg_agents_opencode]
    cmp [rbx + SET_ptr], rax
    jne .Lcs_skip
    lea rdi, [rsp]              # AI: the extension sources switched off (agentext.s)
    call agentext_config_save
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
7:  lea rdi, [rsp]              # custom editors: [editors] (customed.s)
    call ce_config_write
    call config_dir
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
    mov r12, rsi
    mov r13, rdx
    mov rbx, rdi
    call config_dir
    mov rdi, rax
    mov rsi, rbx
    call path_join
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call dir_each_suffix
    mov rdi, rbx
    call mem_free
    EPILOGUE

# dir_each_suffix(path, ext, cb): cb(path, name) for every entry of the folder ending in ext
FN dir_each_suffix
    PROLOGUE
    mov [rip + dir_ext], rsi
    mov [rip + dir_cb], rdx
    mov [rip + dir_path], rdi
    lea rsi, [rip + dir_each_cb]
    xor edx, edx
    call dir_each
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
.globl cfg_def_theme, cfg_def_light_theme
cfg_def_theme: .asciz "rhun-dark"
cfg_def_light_theme: .asciz "rhun-light"
.Lempty: .asciz ""
.Ldef_exclude: .asciz ".git node_modules target build .cache __pycache__ .venv .idea .DS_Store"
.Ldef_sources: .asciz "claude codex grok opencode"
.Lold_sources: .asciz "claude codex"
.Lsources_key: .ascii "sources"
.Ln_claude: .asciz "claude"
.Ln_codex: .asciz "codex"
.Ln_grok: .asciz "grok"
.Ln_opencode: .asciz "opencode"
.p2align 3
agent_names: .quad .Ln_claude, cfg_agents_claude, .Ln_codex, cfg_agents_codex, .Ln_grok, cfg_agents_grok
    .quad .Ln_opencode, cfg_agents_opencode, 0, 0
legacy_names: .quad .Ln_claude, cfg_agents_claude, .Ln_codex, cfg_agents_codex, .Ln_grok, cfg_agents_grok, 0, 0
.Lxdg: .asciz "XDG_CONFIG_HOME"
.Lhome: .asciz "HOME"
.Ltmp: .asciz "/tmp"
.Ldotconfig: .asciz "/.config"
.Lrhun: .asciz "/rhun"
.Lslash_config: .asciz "/config"
.Lkeys: .asciz "keys"
.Leditors: .asciz "editors"
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
.Ls_files: .asciz "files"
.Ls_agents: .asciz "agents"
.Ls_terminal: .asciz "terminal"
.Ls_git: .asciz "git"
.Ls_updates: .asciz "updates"
.Ls_remote: .asciz "remote"
.Ls_testing: .asciz "testing"
.Ls_debug: .asciz "debug"
.Ls_extensions: .asciz "extensions"

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
    SETTING .Ls_ui, follow_system, ST_BOOL, cfg_follow_system, 0, 1, 1, 0, "Follow system dark mode", "Switch themes with the system's dark mode."
    SETTING .Ls_ui, theme, ST_THEME, cfg_theme, 0, 0, 0, 0, "Theme", "Color theme for the editor and the interface."
    SETTING .Ls_ui, dark_theme, ST_THEME, cfg_dark_theme, 0, 0, 0, 0, "Dark theme", "Theme while the system is in dark mode."
    SETTING .Ls_ui, light_theme, ST_THEME, cfg_light_theme, 0, 0, 0, 0, "Light theme", "Theme while the system is in light mode."
    SETTING .Ls_ui, scale, ST_INT, cfg_ui_scale, 50, 300, 10, 1, "Interface zoom", "Scales everything on top of the display scale."
    SETTING .Ls_ui, font_size, ST_INT, cfg_ui_font_size, 9, 24, 1, 0, "Interface font size", "Font size of panels, tabs and menus."
    SETTING .Ls_ui, font, ST_STR, cfg_ui_font, 0, 0, 0, 0, "Interface font", "Path to a .ttf file. Empty uses the built-in Iosevka."
    SETTING .Ls_ui, file_icons, ST_STR, cfg_file_icons, 0, 0, 0, 0, "File icons", "rhun, none, or an extension's icon theme as OWNER/NAME/THEME (Select File Icon Theme)."
    SETTING .Ls_ui, sidebar, ST_BOOL, cfg_sidebar, 0, 1, 1, 0, "Show file explorer", "Project tree on the left (ctrl+b)."
    SETTING .Ls_ui, sidebar_width, ST_INT, cfg_sidebar_w, 140, 600, 10, 0, "Explorer width", "Width of the file explorer in points."
    SETTING .Ls_ui, agents_panel, ST_BOOL, cfg_agents, 0, 1, 1, 0, "Show agents panel", "Agent sessions on the right (ctrl+shift+a)."
    SETTING .Ls_ui, agents_width, ST_INT, cfg_agents_w, 240, 900, 10, 0, "Agents panel width", "Width of the agents panel in points."
    SETTING .Ls_ui, tooltips, ST_BOOL, cfg_tooltips, 0, 1, 1, 0, "Tooltips", "Show a button's name and shortcut on hover."
    SETTING .Ls_ui, auto_hide_scrollbars, ST_BOOL, cfg_autohide_scrollbars, 0, 1, 1, 0, "Auto-hide scrollbars", "Show scrollbars only while scrolling or under the pointer."
    SETTING .Ls_ui, decorations, ST_CHOICE, cfg_decorations, 0, 2, 1, 0, "Title bar", "Who draws window buttons on Wayland. Auto leaves tiling desktops bare.", .Ldeco_opts
    SETTING .Ls_ui, scroll_sensitivity, ST_INT, cfg_scroll_sens, 10, 1000, 10, 1, "Scroll sensitivity", "Scroll speed multiplier. 1.0 is the default."
    SETTING .Ls_ui, fast_scroll_sensitivity, ST_INT, cfg_fast_sens, 10, 1000, 10, 1, "Fast scroll sensitivity", "Multiplier used while alt is held during a scroll."
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
    SETTING .Ls_editor, multi_cursor_paste, ST_CHOICE, cfg_multi_cursor_paste, 0, 1, 1, 0, "Paste at multiple cursors", "Keep copied selections paired. Choose how other multiline text is pasted.", .Lpaste_opts
    SETTING .Ls_editor, multi_cursor_modifier, ST_CHOICE, cfg_multi_cursor_modifier, 0, 1, 1, 0, "Multi-cursor modifier", "Held with a click to add a caret, with a drag to add a selection.", .Lmodifier_opts
    SETTING .Ls_editor, scroll_past_end, ST_BOOL, cfg_scroll_past_end, 0, 1, 1, 0, "Scroll past end", "Allow scrolling the last line to the top."
    SETTING .Ls_editor, vim_mode, ST_BOOL, cfg_vim, 0, 1, 1, 0, "Vim mode", "Normal, insert and visual modes with vim keys."
    # language features
    SETTING .Ls_editor, complete_replace, ST_BOOL, cfg_complete_replace, 0, 1, 1, 0, "Completion replaces the word", "Accepting a completion replaces the rest of the word after the cursor (shift+Enter does the other)."
    SETTING .Ls_editor, complete_commit_characters, ST_BOOL, cfg_complete_commit, 0, 1, 1, 0, "Commit characters", "Typing a character the selected completion lists, such as a dot, accepts it first."
    SETTING .Ls_editor, lightbulb, ST_BOOL, cfg_lightbulb, 0, 1, 1, 0, "Quick fix lightbulb", "Show a lightbulb in the gutter where a quick fix is available."
    SETTING .Ls_editor, format_on_type, ST_BOOL, cfg_format_on_type, 0, 1, 1, 0, "Format as you type", "Ask the formatter after typing one of its trigger characters, such as Enter."
    SETTING .Ls_editor, format_on_paste, ST_BOOL, cfg_format_on_paste, 0, 1, 1, 0, "Format pasted text", "Format the pasted lines with the formatter's range formatting."
    # editor presentation
    SETTING .Ls_editor, folding, ST_BOOL, cfg_folding, 0, 1, 1, 0, "Folding", "Fold regions from the gutter's chevrons (ctrl+shift+[ and ctrl+shift+])."
    SETTING .Ls_editor, inline_complete, ST_BOOL, cfg_inline_complete, 0, 1, 1, 0, "Inline suggestions", "Show what an extension suggests after the cursor as you type; Tab takes it."
    SETTING .Ls_editor, inline_complete_delay, ST_INT, cfg_inline_complete_delay, 0, 2000, 50, 0, "Inline suggestion delay (ms)", "The pause after typing before suggestions are asked for."
    SETTING .Ls_editor, color_swatches, ST_BOOL, cfg_color_swatches, 0, 1, 1, 0, "Color swatches", "Show a small square before colors a language server finds; click it to change the color."
    SETTING .Ls_editor, highlight_occurrences, ST_BOOL, cfg_highlight_occurrences, 0, 1, 1, 0, "Highlight occurrences", "Mark the other places of the word or symbol under the cursor."
    SETTING .Ls_editor, code_lens, ST_BOOL, cfg_code_lens, 0, 1, 1, 0, "Code lens", "Show a row of actions and counts above lines a language server marks: references, tests."
    SETTING .Ls_editor, inlay_hints, ST_BOOL, cfg_inlay_hints, 0, 1, 1, 0, "Inlay hints", "Show what a language server adds inside the code: types, parameter names."
    SETTING .Ls_editor, semantic_highlighting, ST_BOOL, cfg_semantic_highlighting, 0, 1, 1, 0, "Semantic highlighting", "Color code by what a language server knows of it: types, functions, variables."
    SETTING .Ls_files, trim_trailing_whitespace, ST_BOOL, cfg_trim_trailing, 0, 1, 1, 0, "Trim trailing whitespace", "Remove spaces at line ends when saving."
    SETTING .Ls_files, final_newline, ST_BOOL, cfg_final_newline, 0, 1, 1, 0, "Final newline", "Make sure saved files end with a newline."
    SETTING .Ls_files, format_on_save, ST_BOOL, cfg_format_on_save, 0, 1, 1, 0, "Format before saving", "Use the default formatter before writing a file."
    SETTING .Ls_files, format_on_save_timeout, ST_INT, cfg_format_save_timeout, 250, 30000, 250, 0, "Formatting wait (ms)", "Save without formatting when this wait expires."
    SETTING .Ls_files, code_actions_on_save, ST_STR, cfg_save_actions, 0, 0, 0, 0, "Code actions before saving", "Source kinds, such as source.organizeImports source.fixAll. Empty disables them."
    SETTING .Ls_files, code_actions_on_save_timeout, ST_INT, cfg_save_actions_timeout, 250, 30000, 250, 0, "Code actions wait (ms)", "Total wait for source actions before continuing to formatting and saving."
    SETTING .Ls_files, restore_session, ST_BOOL, cfg_restore_session, 0, 1, 1, 0, "Restore open files", "Reopen the files from the last session of a project."
    SETTING .Ls_files, restore_project, ST_BOOL, cfg_restore_project, 0, 1, 1, 0, "Reopen last project", "Reopen the project you closed with when no file or folder is given."
    SETTING .Ls_files, auto_save, ST_CHOICE, cfg_auto_save, 0, 3, 1, 0, "Auto save", "Automatically save modified files.", .Lautosave_opts
    SETTING .Ls_files, auto_save_delay, ST_INT, cfg_auto_save_delay, 200, 60000, 100, 0, "Auto save delay", "Delay in milliseconds before saving modified files."
    SETTING .Ls_files, exclude, ST_STR, cfg_exclude, 0, 0, 0, 0, "Hidden in explorer", "Space separated names the explorer skips."
    SETTING .Ls_agents, claude, ST_BOOL, cfg_agents_claude, 0, 1, 1, 0, "Claude Code", "Show Claude Code sessions in the agents panel."
    SETTING .Ls_agents, codex, ST_BOOL, cfg_agents_codex, 0, 1, 1, 0, "Codex", "Show Codex sessions in the agents panel."
    SETTING .Ls_agents, grok, ST_BOOL, cfg_agents_grok, 0, 1, 1, 0, "Grok Build", "Show Grok Build sessions in the agents panel."
    SETTING .Ls_agents, opencode, ST_BOOL, cfg_agents_opencode, 0, 1, 1, 0, "OpenCode", "Show OpenCode sessions in the agents panel."
    SETTING .Ls_terminal, shell, ST_STR, cfg_term_shell, 0, 0, 0, 0, "Shell", "Program the terminal runs. Empty uses $SHELL."
    SETTING .Ls_terminal, font_size, ST_INT, cfg_term_font_size, 8, 40, 1, 0, "Terminal font size", "Font size of the terminal panel."
    SETTING .Ls_terminal, font, ST_STR, cfg_term_font, 0, 0, 0, 0, "Terminal font", "Path to a monospace .ttf file. Empty uses the editor font."
    SETTING .Ls_terminal, line_height, ST_INT, cfg_term_line_height, 100, 250, 5, 1, "Terminal line height", "Multiple of the font's own line height."
    SETTING .Ls_terminal, scrollback, ST_INT, cfg_term_scrollback, 0, 100000, 1000, 0, "Scrollback", "Lines each terminal keeps above its screen."
    SETTING .Ls_terminal, height, ST_INT, cfg_term_h, 80, 2000, 10, 0, "Terminal height", "Height of the terminal panel in points."
    SETTING .Ls_git, enabled, ST_BOOL, cfg_git, 0, 1, 1, 0, "Git", "Changes in the gutter, tabs and explorer, and the history view."
    SETTING .Ls_git, commit_ai, ST_CHOICE, cfg_commit_ai, 0, 3, 1, 0, "Commit message AI", "Optional. Cloud providers use your subscription.", g_ai_opts, g_ai_provider_desc
    SETTING .Ls_git, commit_model, ST_STR, cfg_commit_model, 0, 0, 0, 0, "Local model", "Ollama model name. Default download: about 1 GB."
    SETTING_ACTION .Ls_git, ai_setup, cmd_ai_model_files, .Lai_setup, g_ai_local_desc
    SETTING .Ls_extensions, secrets, ST_CHOICE, cfg_secrets, 0, 2, 1, 0, "Extension secrets", "Where extensions keep passwords and tokens. A file is as safe as any file only you can read.", .Lsecrets_opts
    SETTING .Ls_updates, check, ST_BOOL, cfg_update_check, 0, 1, 1, 0, "Check for updates", "Look for a new version at startup and once a day."
    SETTING_ACTION .Ls_updates, check_now, cmd_check_for_updates, g_version_text, g_update_desc
    # extension management
    SETTING .Ls_updates, extensions, ST_CHOICE, cfg_ext_updates, 0, 2, 1, 0, "Extension updates", "Install reviewed versions by themselves, or only show updates.", .Lextup_opts
    SETTING_ACTION .Ls_updates, check_extensions, cmd_check_extensions, .Lextup_label, g_extup_desc
    # debugger (debugview.s, debugconsole.s)
    SETTING .Ls_debug, show_on_start, ST_BOOL, g_debug_show_on_start, 0, 1, 1, 0, "Show the debug view on start", "Open the Variables, Watch, Call Stack and Breakpoints sections and the Debug Console when a session starts."
    SETTING .Ls_debug, keys_in_terminal, ST_BOOL, g_debug_keys_in_terminal, 0, 1, 1, 0, "Debug keys in the terminal", "While a session runs, F5, F6, F10, F11 and Shift+F5 reach the debugger even when the terminal has focus."
    SETTING .Ls_debug, console_lines, ST_INT, g_dcon_max, 1000, 100000, 1000, 0, "Debug console lines", "Lines the Debug Console keeps; older ones go."
    SETTING .Ls_remote, agent_binary, ST_STR, cfg_remote_agent_binary, 0, 0, 0, 0, "Remote agent binary", "A Linux rhun to start on remote hosts. Empty uses this release's own."
    # testing (testgutter.s)
    SETTING .Ls_testing, gutter, ST_BOOL, cfg_test_gutter, 0, 1, 1, 0, "Test buttons in the gutter", "A run button and the result at each test's first line."
    .quad 0, 0, 0, 0, 0
    .long 0, 0, 0, 0, 0, 0
.Lextup_opts: .asciz "install", "Install", "check", "Show only", "off", "Off", ""
.Lextup_label: .asciz "Check extensions now"
.Lpaste_opts: .asciz "spread", "Spread lines", "full", "Full text", ""
.Lmodifier_opts: .asciz "alt", "Alt", "ctrl", "Ctrl", ""
.Ldeco_opts: .asciz "auto", "Auto", "client", "rhun", "server", "Desktop", ""

.Ldefault_model: .asciz "qwen2.5-coder:1.5b"
.Lsecrets_opts: .asciz "system", "Keychain", "memory", "Memory", "file", "File", ""

.Lai_setup: .asciz "Local model files"
.Lautosave_opts: .asciz "off", "Off", "after_delay", "After Delay", "on_focus_change", "On Focus Change", "on_window_change", "On Window Change", ""
