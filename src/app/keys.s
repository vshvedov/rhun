# command registry and keybindings ("ctrl+shift+p" strings, overridable in [keys])
.include "rhun.inc"

STRUCT
F KB_mods, 4
F KB_key, 4
F KB_cmd, 8             # CMD*
ENDSTRUCT KB_SIZE

.bss
.p2align 3
bindings: .zero VEC_SIZE

.text

# parse_combo(ptr, len) -> eax keysym (0 if invalid), edx mods
FN parse_combo
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d              # mods
    xor r15d, r15d              # key
.Lpc_tok:
    test r13, r13
    jz .Lpc_done
    # token until '+' (a '+' right at the start of a token is the key itself)
    xor ecx, ecx
    cmp byte ptr [r12], '+'
    jne 1f
    mov ecx, 1
    jmp 2f
1:  cmp rcx, r13
    jae 2f
    cmp byte ptr [r12 + rcx], '+'
    je 2f
    inc rcx
    jmp 1b
2:  mov [rsp], rcx
    mov rdi, r12
    mov rsi, rcx
    call combo_token
    test edx, edx
    jz 3f
    or r14d, edx
    jmp 4f
3:  mov r15d, eax
4:  mov rcx, [rsp]
    add r12, rcx
    sub r13, rcx
    test r13, r13
    jz .Lpc_done
    cmp byte ptr [r12], '+'
    jne .Lpc_tok
    inc r12
    dec r13
    jmp .Lpc_tok
.Lpc_done:
    mov eax, r15d
    mov edx, r14d
    EPILOGUE

# combo_token(ptr, len) -> edx mod bit if a modifier, else eax keysym
combo_token:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + mod_names]
1:  mov rdx, [rbx]
    test rdx, rdx
    jz 2f
    mov rdi, r12
    mov rsi, r13
    call str_ieq_cstr
    test eax, eax
    jnz 3f
    add rbx, 16
    jmp 1b
3:  mov edx, [rbx + 8]
    xor eax, eax
    EPILOGUE
2:  lea rbx, [rip + key_names]
4:  mov rdx, [rbx]
    test rdx, rdx
    jz 5f
    mov rdi, r12
    mov rsi, r13
    call str_ieq_cstr
    test eax, eax
    jnz 6f
    add rbx, 16
    jmp 4b
6:  mov eax, [rbx + 8]
    xor edx, edx
    EPILOGUE
5:  # single character (lowercased), else any keysym name
    xor edx, edx
    cmp r13, 1
    jne 7f
    movzx edi, byte ptr [r12]
    call to_lower
    xor edx, edx
    EPILOGUE
7:  mov rdi, r12
    mov rsi, r13
    call keysym_value
    xor edx, edx
    EPILOGUE

# str_ieq_cstr(ptr, len, cstr) -> 1 if equal ignoring ascii case
FN str_ieq_cstr
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, rax
    call str_ieq
    pop r13
    pop r12
    pop rbx
    ret

# bind(cmd*, ptr, len)
bind:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call parse_combo
    test eax, eax
    jz 9f
    mov r12d, eax
    mov r13d, edx
    # replace an existing binding of the same keys
    xor ecx, ecx
1:  cmp rcx, [rip + bindings + VEC_len]
    jae 2f
    imul rax, rcx, KB_SIZE
    add rax, [rip + bindings + VEC_ptr]
    cmp [rax + KB_key], r12d
    jne 11f
    cmp [rax + KB_mods], r13d
    jne 11f
    mov [rax + KB_cmd], rbx
    jmp 9f
11: inc rcx
    jmp 1b
2:  lea rdi, [rip + bindings]
    mov esi, KB_SIZE
    call vec_push
    mov [rax + KB_key], r12d
    mov [rax + KB_mods], r13d
    mov [rax + KB_cmd], rbx
9:  EPILOGUE

# cmd_find(ptr, len) -> CMD* or 0
FN cmd_find
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + g_commands]
1:  mov rdx, [rbx + CMD_name]
    test rdx, rdx
    jz 2f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 3f
    add rbx, CMD_SIZE
    jmp 1b
2:  xor ebx, ebx
3:  mov rax, rbx
    EPILOGUE

# cmd_for_fn(fn) -> the command that runs fn, or 0
FN cmd_for_fn
    lea rax, [rip + g_commands]
1:  cmp qword ptr [rax + CMD_name], 0
    je 2f
    cmp [rax + CMD_fn], rdi
    je 3f
    add rax, CMD_SIZE
    jmp 1b
2:  xor eax, eax
3:  ret

# keys_reload(): bindings from scratch, after the config file changed
FN keys_reload
    mov qword ptr [rip + bindings + VEC_len], 0
    jmp keys_init

# keys_init(): defaults, then [keys] overrides ("combo = command", command "none" unbinds)
FN keys_init
    PROLOGUE
    lea rbx, [rip + g_commands]
.Lki_cmd:
    cmp qword ptr [rbx + CMD_name], 0
    je .Lki_user
    mov r12, [rbx + CMD_keys]
    mov rdi, r12
    call strlen
    mov r13, rax
1:  test r13, r13
    jz 2f
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 2f
    mov rdi, rbx
    mov rsi, rax
    call bind
    jmp 1b
2:  add rbx, CMD_SIZE
    jmp .Lki_cmd
.Lki_user:
    xor r14d, r14d
3:  cmp r14, [rip + g_keylines + VEC_len]
    jae 9f
    mov r15, r14
    shl r15, 5
    add r15, [rip + g_keylines + VEC_ptr]
    mov rdi, [r15 + 16]
    mov rsi, [r15 + 24]
    call cmd_find
    mov rdi, rax
    test rax, rax
    jnz 4f
    lea rdi, [rip + none_cmd]
4:  mov rsi, [r15]
    mov rdx, [r15 + 8]
    call bind
    inc r14
    jmp 3b
9:  EPILOGUE

# keys_lookup(keysym, mods) -> handler fn or 0
FN keys_lookup
    # letters bind lowercase; shift is part of mods
    lea eax, [rdi - 'A']
    cmp eax, 25
    ja 1f
    or edi, 0x20
1:  cmp edi, KEY_ISO_LEFT_TAB
    jne 2f
    mov edi, KEY_TAB
2:  xor ecx, ecx
3:  cmp rcx, [rip + bindings + VEC_len]
    jae 5f
    imul rax, rcx, KB_SIZE
    add rax, [rip + bindings + VEC_ptr]
    cmp [rax + KB_key], edi
    jne 4f
    cmp [rax + KB_mods], esi
    jne 4f
    mov rax, [rax + KB_cmd]
    mov rax, [rax + CMD_fn]
    ret
4:  inc rcx
    jmp 3b
5:  xor eax, eax
    ret

# keys_for(cmd*) -> first binding formatted into a static buffer ("Ctrl+Shift+P"), or 0
FN keys_for
    PROLOGUE
    mov rbx, rdi
    xor ecx, ecx
1:  cmp rcx, [rip + bindings + VEC_len]
    jae 8f
    imul r12, rcx, KB_SIZE
    add r12, [rip + bindings + VEC_ptr]
    cmp [r12 + KB_cmd], rbx
    je 2f
    inc rcx
    jmp 1b
2:  lea r13, [rip + keybuf]
    mov r14d, [r12 + KB_mods]
.ifdef MACOS
    # macOS: symbols in menu order, Command for Ctrl. Tab, backtick and bare H
    # stay Control because their Command shortcuts belong to the system/menu.
    test r14d, MOD_CTRL
    jz 21f
    mov eax, [r12 + KB_key]
    cmp eax, KEY_TAB
    je 20f
    cmp eax, '`'
    je 20f
    cmp eax, 'h'
    jne 21f
    cmp r14d, MOD_CTRL
    jne 21f
20: lea rsi, [rip + .Lmac_control]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
    and r14d, ~MOD_CTRL
21: test r14d, MOD_ALT
    jz 22f
    lea rsi, [rip + .Lmac_option]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
22: test r14d, MOD_SHIFT
    jz 23f
    lea rsi, [rip + .Lmac_shift]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
23: test r14d, MOD_CTRL
    jz 24f
    lea rsi, [rip + .Lmac_command]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
24: # arrows as arrows, punctuation as itself ("⌘,")
    mov eax, [r12 + KB_key]
    lea rbx, [rip + mac_key_syms]
25: cmp qword ptr [rbx], 0
    je 6f
    cmp [rbx + 8], eax
    je 72f
    add rbx, 16
    jmp 25b
.endif
    test r14d, MOD_CTRL
    jz 3f
    lea rsi, [rip + .Lctrl]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
3:  test r14d, MOD_SHIFT
    jz 4f
    lea rsi, [rip + .Lshift]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
4:  test r14d, MOD_ALT
    jz 5f
    lea rsi, [rip + .Lalt]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
5:  test r14d, MOD_SUPER
    jz 6f
    lea rsi, [rip + .Lsuper]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
6:  # key name
    mov eax, [r12 + KB_key]
    lea rbx, [rip + key_names]
7:  cmp qword ptr [rbx], 0
    je 71f
    cmp [rbx + 8], eax
    je 72f
    add rbx, 16
    jmp 7b
72: mov rsi, [rbx]
    mov rdi, r13
    call cstr_copy
    # capitalize first letter
    lea rdi, [rip + keybuf]
    jmp 73f
71: lea ecx, [rax - 'a']
    cmp ecx, 25
    ja 74f
    sub eax, 32
74: mov [r13], al
    mov byte ptr [r13 + 1], 0
73: # capitalize the key name after the last '+'
    lea rax, [rip + keybuf]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

FN cmd_none
    ret

.section .rodata
.p2align 3
none_cmd: .quad .Lnone, .Lnone, cmd_none, .Lnone
.Lnone: .asciz ""
.ifdef MACOS
.Lmac_control: .asciz "\342\214\203"
.Lmac_option: .asciz "\342\214\245"
.Lmac_shift: .asciz "\342\207\247"
.Lmac_command: .asciz "\342\214\230"
.Lmac_up: .asciz "\342\206\221"
.Lmac_down: .asciz "\342\206\223"
.Lmac_left: .asciz "\342\206\220"
.Lmac_right: .asciz "\342\206\222"
.Lmac_comma: .asciz ","
.Lmac_plus: .asciz "+"
.p2align 3
mac_key_syms:
    .quad .Lmac_up, KEY_UP, .Lmac_down, KEY_DOWN, .Lmac_left, KEY_LEFT, .Lmac_right, KEY_RIGHT
    .quad .Lmac_comma, ',', .Lmac_plus, '+', 0, 0
.endif
.Lctrl: .asciz "Ctrl+"
.Lshift: .asciz "Shift+"
.Lalt: .asciz "Alt+"
.Lsuper: .asciz "Super+"
mod_names:
    .quad .Lm_ctrl, MOD_CTRL, .Lm_control, MOD_CTRL, .Lm_shift, MOD_SHIFT, .Lm_alt, MOD_ALT
    .quad .Lm_super, MOD_SUPER, .Lm_cmd, MOD_SUPER, .Lm_meta, MOD_SUPER, 0, 0
.Lm_ctrl: .asciz "ctrl"
.Lm_control: .asciz "control"
.Lm_shift: .asciz "shift"
.Lm_alt: .asciz "alt"
.Lm_super: .asciz "super"
.Lm_cmd: .asciz "cmd"
.Lm_meta: .asciz "meta"
key_names:
    .quad .Lk_enter, KEY_RETURN, .Lk_return, KEY_RETURN, .Lk_tab, KEY_TAB, .Lk_esc, KEY_ESCAPE
    .quad .Lk_escape, KEY_ESCAPE, .Lk_bs, KEY_BACKSPACE, .Lk_del, KEY_DELETE, .Lk_delete, KEY_DELETE
    .quad .Lk_up, KEY_UP, .Lk_down, KEY_DOWN, .Lk_left, KEY_LEFT, .Lk_right, KEY_RIGHT
    .quad .Lk_home, KEY_HOME, .Lk_end, KEY_END, .Lk_pgup, KEY_PAGEUP, .Lk_pgdn, KEY_PAGEDOWN
    .quad .Lk_ins, KEY_INSERT, .Lk_space, ' ', .Lk_plus, '+', .Lk_comma, ','
    .quad .Lk_f1, KEY_F1, .Lk_f2, KEY_F1 + 1, .Lk_f3, KEY_F1 + 2, .Lk_f4, KEY_F1 + 3
    .quad .Lk_f5, KEY_F1 + 4, .Lk_f6, KEY_F1 + 5, .Lk_f7, KEY_F1 + 6, .Lk_f8, KEY_F1 + 7
    .quad .Lk_f9, KEY_F1 + 8, .Lk_f10, KEY_F1 + 9, .Lk_f11, KEY_F1 + 10, .Lk_f12, KEY_F1 + 11
    .quad 0, 0
.Lk_enter: .asciz "Enter"
.Lk_return: .asciz "Return"
.Lk_tab: .asciz "Tab"
.Lk_esc: .asciz "Esc"
.Lk_escape: .asciz "Escape"
.Lk_bs: .asciz "Backspace"
.Lk_del: .asciz "Del"
.Lk_delete: .asciz "Delete"
.Lk_up: .asciz "Up"
.Lk_down: .asciz "Down"
.Lk_left: .asciz "Left"
.Lk_right: .asciz "Right"
.Lk_home: .asciz "Home"
.Lk_end: .asciz "End"
.Lk_pgup: .asciz "PageUp"
.Lk_pgdn: .asciz "PageDown"
.Lk_ins: .asciz "Insert"
.Lk_space: .asciz "Space"
.Lk_plus: .asciz "Plus"
.Lk_comma: .asciz "Comma"
.Lk_f1: .asciz "F1"
.Lk_f2: .asciz "F2"
.Lk_f3: .asciz "F3"
.Lk_f4: .asciz "F4"
.Lk_f5: .asciz "F5"
.Lk_f6: .asciz "F6"
.Lk_f7: .asciz "F7"
.Lk_f8: .asciz "F8"
.Lk_f9: .asciz "F9"
.Lk_f10: .asciz "F10"
.Lk_f11: .asciz "F11"
.Lk_f12: .asciz "F12"

.macro COMMAND name, title, fn, keys
    .quad 1f, 2f, \fn, 3f
    .pushsection .rodata.str, "aMS", @progbits, 1
1:  .asciz "\name"
2:  .asciz "\title"
3:  .asciz "\keys"
    .popsection
.endm

.p2align 3
.globl g_commands
g_commands:
    COMMAND quick_open, "Go to File", cmd_quick_open, "ctrl+p ctrl+e"
    COMMAND command_palette, "Command Palette", cmd_command_palette, "ctrl+shift+p F1"
    COMMAND new_file, "New File", cmd_new_file, "ctrl+n"
    COMMAND save, "Save", cmd_save, "ctrl+s"
    COMMAND save_as, "Save As", cmd_save_as, "ctrl+shift+s"
    COMMAND close_tab, "Close Tab", cmd_close_tab, "ctrl+w ctrl+F4"
    COMMAND close_all_tabs, "Close All Tabs", cmd_close_all, "ctrl+shift+w"
    COMMAND reopen_closed_tab, "Reopen Closed Tab", cmd_reopen_closed_tab, "ctrl+shift+t"
    COMMAND next_tab, "Next Tab", cmd_next_tab, "ctrl+Tab ctrl+PageDown"
    COMMAND prev_tab, "Previous Tab", cmd_prev_tab, "ctrl+shift+Tab ctrl+PageUp"
    COMMAND quit, "Quit", cmd_quit, "ctrl+q"
    COMMAND undo, "Undo", cmd_undo, "ctrl+z"
    COMMAND redo, "Redo", cmd_redo, "ctrl+shift+z ctrl+y"
    COMMAND cut, "Cut", cmd_cut, "ctrl+x shift+Delete"
    COMMAND copy, "Copy", cmd_copy, "ctrl+c ctrl+Insert"
    COMMAND paste, "Paste", cmd_paste, "ctrl+v shift+Insert"
    COMMAND select_all, "Select All", cmd_select_all, "ctrl+a"
    COMMAND select_line, "Select Line", cmd_select_line, "ctrl+l"
    COMMAND select_next, "Select Word or Next Match", cmd_select_next, "ctrl+d"
    COMMAND duplicate_line, "Duplicate Line", cmd_duplicate_line, "ctrl+shift+d"
    COMMAND delete_line, "Delete Line", cmd_delete_line, "ctrl+shift+k"
    COMMAND move_line_up, "Move Line Up", cmd_move_line_up, "alt+Up"
    COMMAND move_line_down, "Move Line Down", cmd_move_line_down, "alt+Down"
    COMMAND indent, "Indent", cmd_indent, "ctrl+]"
    COMMAND outdent, "Outdent", cmd_outdent, "ctrl+["
    COMMAND toggle_comment, "Toggle Comment", cmd_toggle_comment, "ctrl+/"
    COMMAND newline_below, "Insert Line Below", cmd_newline_below, "ctrl+Enter"
    COMMAND newline_above, "Insert Line Above", cmd_newline_above, "ctrl+shift+Enter"
    COMMAND find, "Find", cmd_find_bar, "ctrl+f"
    COMMAND replace, "Replace", cmd_replace_bar, "ctrl+h"
    COMMAND find_next, "Find Next", cmd_find_next, "F3"
    COMMAND find_prev, "Find Previous", cmd_find_prev, "shift+F3"
    COMMAND find_in_files, "Find in Files", cmd_find_in_files, "ctrl+shift+f"
    COMMAND goto_line, "Go to Line", cmd_goto_line, "ctrl+g"
    COMMAND settings, "Open Settings", cmd_settings, "ctrl+,"
    COMMAND open_config, "Open Settings File", cmd_open_config, ""
    COMMAND select_theme, "Select Color Theme", cmd_select_theme, "ctrl+k"
    COMMAND toggle_light_dark_theme, "Toggle Light/Dark Theme", cmd_toggle_light_dark, ""
    COMMAND select_language, "Change Language Mode", cmd_select_language, ""
    COMMAND toggle_sidebar, "Toggle File Explorer", cmd_toggle_sidebar, "ctrl+b"
    COMMAND toggle_agents, "Toggle Agents Panel", cmd_toggle_agents, "ctrl+shift+a"
    COMMAND focus_explorer, "Focus File Explorer", cmd_focus_explorer, "ctrl+shift+e"
    COMMAND reveal_file, "Show File in System File Manager", cmd_reveal_file, ""
    COMMAND website, "Open rhun Website", cmd_website, ""
    COMMAND email, "Email rhun", cmd_email, ""
    COMMAND feedback, "Send Feedback or Report a Bug", cmd_feedback, ""
    COMMAND focus_agents, "Focus Agents Panel", cmd_focus_agents, ""
    COMMAND open_file, "Open File", cmd_open_file, "ctrl+o"
    COMMAND open_folder, "Open Folder", cmd_open_folder, "ctrl+shift+o"
    COMMAND new_folder, "New Folder", cmd_new_folder, ""
    COMMAND rename_file, "Rename File", cmd_rename_file, "F2"
    COMMAND delete_file, "Delete File", cmd_delete_file, ""
    COMMAND zoom_in, "Zoom In", cmd_zoom_in, "ctrl+= ctrl++ ctrl+shift+= ctrl+shift++"
    COMMAND zoom_out, "Zoom Out", cmd_zoom_out, "ctrl+-"
    COMMAND zoom_reset, "Reset Zoom", cmd_zoom_reset, "ctrl+0"
    COMMAND toggle_word_wrap, "Toggle Word Wrap", cmd_toggle_word_wrap, "alt+z"
    COMMAND toggle_whitespace, "Toggle Whitespace", cmd_toggle_whitespace, ""
    COMMAND toggle_line_numbers, "Toggle Line Numbers", cmd_toggle_line_numbers, ""
    COMMAND toggle_vim, "Toggle Vim Mode", cmd_toggle_vim, ""
    COMMAND reload_file, "Revert File", cmd_reload_file, ""
    COMMAND toggle_terminal, "Toggle Terminal", cmd_toggle_terminal, "ctrl+`"
    COMMAND new_terminal, "New Terminal", cmd_new_terminal, "ctrl+shift+` ctrl+shift+~"
    COMMAND kill_terminal, "Kill Terminal", cmd_kill_terminal, ""
    COMMAND clear_terminal, "Clear Terminal", cmd_clear_terminal, ""
    COMMAND git_history, "Git: Show History", cmd_git_history, ""
    COMMAND toggle_git_history, "Toggle Git History", cmd_toggle_git, "ctrl+shift+g"
    COMMAND git_changes, "Git: Open Changes", cmd_git_changes, ""
    COMMAND git_commit, "Git: Commit", cmd_git_commit, ""
    COMMAND git_generate_message, "Git: Generate Commit Message", cmd_git_generate_message, ""
    COMMAND ai_detect, "Git: Check AI Provider", cmd_ai_detect, ""
    COMMAND ai_setup, "Git: Download Local Model", cmd_ai_setup, ""
    COMMAND ai_delete, "Git: Delete Local Model", cmd_ai_delete, ""
    COMMAND ai_cancel, "Git: Cancel AI Operation", cmd_ai_cancel, ""
    COMMAND git_commit_amend, "Git: Commit (Amend)", cmd_git_commit_amend, ""
    COMMAND git_pull, "Git: Pull", cmd_git_pull, ""
    COMMAND git_push, "Git: Push", cmd_git_push, ""
    COMMAND git_sync, "Git: Sync", cmd_git_sync, ""
    COMMAND git_fetch, "Git: Fetch", cmd_git_fetch, ""
    COMMAND git_stage_all, "Git: Stage All Changes", cmd_git_stage_all, ""
    COMMAND git_unstage_all, "Git: Unstage All Changes", cmd_git_unstage_all, ""
    COMMAND git_discard_all, "Git: Discard All Changes", cmd_git_discard_all, ""
    COMMAND git_reset_all, "Git: Reset All Changes", cmd_git_reset_all, ""
    COMMAND check_for_updates, "Check for Updates", cmd_check_for_updates, ""
    COMMAND install_update, "Install Update", cmd_install_update, ""
    COMMAND restart_to_update, "Restart to Update", cmd_restart_to_update, ""
    .quad 0, 0, 0, 0

.bss
keybuf: .zero 64
