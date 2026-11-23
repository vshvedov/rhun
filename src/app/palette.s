# palette overlay: fuzzy file finder, commands, themes, languages, go to line, find in files, one-line prompts,
# the path browser (Open File, Open Folder)
.include "rhun.inc"

.equ PM_NONE, 0
.equ PM_FILES, 1
.equ PM_COMMANDS, 2
.equ PM_THEMES, 3
.equ PM_LANGS, 4
.equ PM_GOTO, 5
.equ PM_PROMPT, 6
.equ PM_GREP, 7
.equ PM_BROWSE, 8
.equ PM_CHOOSE, 9               # an extension's pick list (choose)
.equ PM_PROVIDERS, 11
.equ PM_RESULTS, 10             # results from extensions: locations, symbols, code actions (langfeat.s)
.equ PM_KEYS, 12                # Keyboard Shortcuts: every binding (keys.s keys_list)
.equ PM_REMOTE, 40              # remote hosts: a pick list that also takes typed text (remoteui.s)
.equ PM_TASKS, 76               # tasks and terminals: Run Task and the other task commands (tasks.s)
.equ PM_WSLIST, 88              # wsedit: a workspace edit's question (wsconfirm.s)
.equ PM_LINKS, 89               # a URL from an agent's reply: Open, Copy Link, Cancel (links.s)
.equ PM_WSYM, 92                # language features: Go to Symbol in Project (wsym.s)
.equ PM_DPICK, 80               # debugger: a launch's ${pick:} or ${process} (debugask.s)
.equ PM_ICONS, 64               # contributions: Select File Icon Theme (iconth.s)

.equ ID_PAL_ROW, 0x200000         # + row: a range of its own, as results run to MAXFILES
.equ ID_PAL_FIELD, 0x3fff
.equ MAXFILES, 200000
.equ GREP_MAX, 5000             # results
.equ GREP_FILE_MAX, 8 << 20     # bytes per file
.equ GREP_TOTAL_MAX, 256 << 20
.equ GREP_BLOCK, 32 << 20        # file texts are read into mappings this big, unmapped after
.equ GREP_SLICE, 8              # ms of reading files per loop pass, so keys keep working meanwhile
.equ GL_NONE, 0                 # gload_state: nothing to read
.equ GL_SCAN, 1                 # the project's files are to be listed
.equ GL_READ, 2                 # and read, from gload_i on
.equ BRW_MAX, 20000             # entries of a folder in the path browser
.equ BRW_DIR, 1                 # IT_data of the path browser: a folder
.equ BRW_HERE, 2                # the "Open <folder>" row
.equ BRW_NEW, 4                 # and "Open <folder> in a new window" under it

STRUCT
F IT_label, 8
F IT_len, 8
F IT_detail, 8          # cstr or 0
F IT_data, 8
ENDSTRUCT IT_SIZE

STRUCT
F GF_label, 8           # relative path (in strings)
F GF_text, 8
F GF_len, 8
ENDSTRUCT GF_SIZE

STRUCT
F RS_item, 4
F RS_score, 4
ENDSTRUCT RS_SIZE

.bss
.p2align 3
gtr_query: .zero 104            # language features: Find in Files' query for the Results title
pal_mode: .long 0
pal_prompt: .long 0             # PROMPT_* when in PM_PROMPT
pal_sel: .long 0
pal_scroll: .long 0
pal_reveal: .long 0             # reveal selection after keyboard navigation/filtering only
pal_wheel: .long 0              # accumulate wheel pixels smaller than a row
pal_focus_before: .long 0       # g_focus when the palette opened
.p2align 3
pal_tf: .zero TF_SIZE
items: .zero VEC_SIZE
results: .zero VEC_SIZE
strings: .zero SB_SIZE          # label storage for file items
pal_label: .quad 0              # prompt label
pal_theme_slot: .quad 0         # the theme setting the theme list picks for (theme_slot)
pal_keys_cached: .quad 0        # 1 while keys_cache holds the built-in commands' shortcuts
pal_path: .zero 4096
scan_depth: .long 0
scan_prefix: .zero 4096         # relative dir during scan
scan_plen: .long 0
tmp: .zero SB_SIZE
gfiles: .zero VEC_SIZE          # GF: project text files in memory while searching
ghit: .quad 0                   # per file: 0 when it has no match for the query in gprev
gblocks: .zero VEC_SIZE         # mappings holding the file texts (pointers)
gblock_ptr: .quad 0             # free space in the last one
gblock_end: .quad 0
gprev: .zero 256
gprev_len: .long 0
gstr: .zero SB_SIZE             # result labels and details
gload: .zero VEC_SIZE           # IT: the files find in files reads (labels in strings)
gload_i: .quad 0                # the next one
gload_bytes: .quad 0            # read so far
gload_state: .long 0            # GL_*
gload_drawn: .long 0            # the palette has been on screen since find in files opened
grep_case: .long 0
pal_mods: .long 0               # modifiers of the key that accepts
pal_nohl: .long 0               # the row being drawn shows no matched characters
brw_kind: .long 0               # the path browser picks: 0 a file, 1 a folder
brw_dir: .zero 4096             # the folder it lists
brw_next: .zero 4096
brw_label: .zero 4096
rg_reply: .zero SB_SIZE         # remote hosts: the host's answer to rg_query (find in files)
rg_paths: .zero SB_SIZE         # its files' paths, which gfiles' labels point into
rg_query: .zero 256
rg_query_len: .quad 0
rg_asked: .zero 256             # the query out to the host
rg_asked_len: .quad 0
rg_out: .long 0                 # 1 while a query is out
rg_groups: .zero VEC_SIZE       # rg_items: each file's first record, by path

.text

FN palette_is_open
    xor eax, eax
    cmp dword ptr [rip + pal_mode], PM_NONE
    setne al
    ret

FN palette_field
    lea rax, [rip + pal_tf]
    ret

# palette_close_extensions_pure(): an extension's prompt or results close (their owner went
# away), ordinary user prompts stay. No allocation or release.
FN palette_close_extensions_pure
    mov qword ptr [rip + pal_keys_cached], 0
    mov eax, [rip + pal_mode]
    cmp eax, PM_COMMANDS
    je .Lpal_detach_borrowers_pure
    cmp eax, PM_KEYS
    je .Lpal_detach_borrowers_pure
    cmp eax, PM_THEMES
    je .Lpal_detach_borrowers_pure
    cmp eax, PM_ICONS
    je .Lpal_detach_icons_pure
    cmp eax, PM_LANGS
    je .Lpal_detach_borrowers_pure
    cmp eax, PM_PROVIDERS
    je .Lpal_detach_borrowers_pure
    cmp eax, PM_RESULTS
    je .Lpal_detach_borrowers_pure
    cmp eax, PM_CHOOSE
    je .Lpal_detach_borrowers_pure
    cmp eax, PM_PROMPT
    jne 9f
    mov eax, [rip + pal_prompt]
    cmp eax, PROMPT_ASK
    je .Lpal_detach_borrowers_pure
    cmp eax, PROMPT_TERM
    je .Lpal_detach_borrowers_pure
    cmp eax, PROMPT_EXT_SETTING
    je .Lpal_detach_borrowers_pure
    cmp eax, PROMPT_RENAME_SYMBOL
    je .Lpal_detach_borrowers_pure
9:  ret
.Lpal_detach_icons_pure:
    push rax
    mov rdi, -1
    call iconth_preview         # the setting's icons again
    pop rax
.Lpal_detach_borrowers_pure:
    push rax
    call extpage_prompt_invalidate_pure
    pop rax
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + pal_prompt], 0
    mov qword ptr [rip + pal_label], 0
    mov dword ptr [rip + pal_sel], 0
    mov dword ptr [rip + pal_scroll], 0
    mov qword ptr [rip + items + VEC_len], 0
    mov qword ptr [rip + results + VEC_len], 0
    mov dword ptr [rip + g_dirty], 1
    mov eax, [rip + g_focus]
    cmp eax, FOCUS_PALETTE
    je pal_return_focus
    cmp eax, FOCUS_PROMPT
    je pal_return_focus
    ret

# FN palette_icon_themes(): Select File Icon Theme, previewing the row under the selection
FN palette_icon_themes
    mov edi, PM_ICONS
    jmp palette_open

# palette_open(mode)
palette_open:
    PROLOGUE
    mov ebx, edi
    call extpage_prompt_invalidate_pure
    call pal_save_cancel
    call pal_remote_cancel
    call ext_provider_cancel
    call extproto_prompt_abort  # an extension's prompt that was open is cancelled
    call wslist_abort           # wsedit: and a workspace edit's question
    # from the theme list to another list (its shortcut): the settings' theme again, as on closing
    cmp dword ptr [rip + pal_mode], PM_THEMES
    jne 1f
    cmp ebx, PM_THEMES
    je 1f
    call theme_apply_config
1:  cmp dword ptr [rip + pal_mode], PM_ICONS    # the file icons the setting chooses again
    jne 1f
    mov rdi, -1
    call iconth_preview
1:  call grep_release
    mov [rip + pal_mode], ebx
    mov dword ptr [rip + pal_sel], 0
    mov dword ptr [rip + pal_scroll], 0
    mov dword ptr [rip + pal_tf + TF_id], ID_PAL_FIELD
    lea rdi, [rip + pal_tf]
    call tf_clear
    mov qword ptr [rip + items + VEC_len], 0
    # switching modes keeps the focus the palette was opened from
    mov eax, [rip + g_focus]
    cmp eax, FOCUS_PALETTE
    je 1f
    mov [rip + pal_focus_before], eax
1:  mov dword ptr [rip + g_focus], FOCUS_PALETTE
    cmp ebx, PM_FILES
    jne 1f
    call load_files
    jmp 8f
1:  cmp ebx, PM_COMMANDS
    jne 2f
    call load_commands
    jmp 8f
2:  cmp ebx, PM_THEMES
    jne 3f
    call load_themes
    jmp 8f
3:  cmp ebx, PM_LANGS
    jne 4f
    call load_langs
    jmp 8f
4:  cmp ebx, PM_KEYS
    jne 5f
    lea rdi, [rip + item_add]
    call keys_list
    jmp 8f
5:  cmp ebx, PM_ICONS
    jne 8f
    lea rdi, [rip + item_add]
    call iconth_list
    mov [rip + pal_sel], eax    # the setting's row
8:  call palette_filter
    # the theme list shows its setting's theme, which need not be the one shown (the light mode's
    # theme from Settings while the system is dark)
    cmp ebx, PM_THEMES
    jne 9f
    call preview
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

FN palette_close
    push rbx
    call extpage_prompt_invalidate_pure
    call pal_save_cancel
    call pal_remote_cancel
    call ext_provider_cancel
    call extproto_prompt_abort
    call wslist_abort           # wsedit
    # themes: the settings' theme again, after a preview or a change of the system's mode
    cmp dword ptr [rip + pal_mode], PM_THEMES
    jne 1f
    call theme_apply_config
1:  cmp dword ptr [rip + pal_mode], PM_ICONS
    jne 1f
    mov rdi, -1
    call iconth_preview
1:  call grep_release
    mov dword ptr [rip + pal_mode], PM_NONE
    call pal_return_focus
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# Accepting a prompt clears pal_mode before invoking its completion, so this handles only
# Escape, outside clicks and replacement by another palette.
pal_save_cancel:
    cmp dword ptr [rip + pal_mode], PM_PROMPT
    jne 1f
    cmp dword ptr [rip + pal_prompt], PROMPT_SAVE_AS
    jne 1f
    jmp app_save_prompt_cancel
1:  ret

# pal_remote_cancel(): remote hosts: a remote list or question closed without an answer
pal_remote_cancel:
    cmp dword ptr [rip + pal_mode], PM_REMOTE
    je 1f
    cmp dword ptr [rip + pal_mode], PM_PROMPT
    jne 2f
    cmp dword ptr [rip + pal_prompt], PROMPT_REMOTE
    je 1f
    cmp dword ptr [rip + pal_prompt], PROMPT_REMOTE_SECRET
    jne 2f
1:  mov dword ptr [rip + pal_mode], PM_NONE
    jmp remote_ui_cancel
2:  ret

# palette_remote_open(label cstr): remote hosts: a pick list (palette_choose_add, then
# palette_choose_ready); Enter gives remote_ui_accept the item or the typed text
FN palette_remote_open
    push rbx
    mov rbx, rdi
    mov edi, PM_REMOTE
    call palette_open
    mov [rip + pal_label], rbx
    pop rbx
    ret

# palette_remote_field() -> the field (remote_field_for_draw draws a password masked)
FN palette_remote_field
    lea rax, [rip + pal_tf]
    mov edx, [rip + pal_mode]
    mov ecx, [rip + pal_prompt]
    ret

# pal_return_focus(): back to the terminal the palette was opened from, otherwise to the editor,
# so a command from the palette acts where its shortcut would
pal_return_focus:
    mov eax, FOCUS_EDITOR
    cmp dword ptr [rip + pal_focus_before], FOCUS_TERMINAL
    jne 1f
    cmp dword ptr [rip + g_term_open], 0
    je 1f
    mov eax, FOCUS_TERMINAL
1:  mov [rip + g_focus], eax
    ret

FN cmd_quick_open
    mov edi, PM_FILES
    jmp palette_open
FN cmd_command_palette
    mov edi, PM_COMMANDS
    jmp palette_open
# Keyboard Shortcuts: every binding with its source and clause; Enter runs its command
FN cmd_keyboard_shortcuts
    mov edi, PM_KEYS
    jmp palette_open
# Select Color Theme picks for the setting in use: theme, or the dark or light mode's theme
# while the theme follows the system (VS Code saves it in the same place)
FN cmd_select_theme
    call theme_slot
    mov rdi, rax
    jmp cmd_select_theme_for
# cmd_select_theme_for(setting): the theme list for one theme setting (Settings' buttons)
FN cmd_select_theme_for
    mov [rip + pal_theme_slot], rdi
    mov edi, PM_THEMES
    jmp palette_open

# palette_picks_theme() -> 1 while the theme list is open
FN palette_picks_theme
    xor eax, eax
    cmp dword ptr [rip + pal_mode], PM_THEMES
    sete al
    ret
FN cmd_select_language
    cmp qword ptr [rip + g_doc], 0
    je 1f
    mov edi, PM_LANGS
    jmp palette_open
1:  ret
FN cmd_goto_line
    call ed_single              # one selection (multi-cursor)
    cmp qword ptr [rip + g_doc], 0
    je 1f
    mov edi, PM_GOTO
    jmp palette_open
1:  ret

FN cmd_open_file
    xor edi, edi
    jmp browse_open

FN cmd_open_folder
    mov edi, 1
    jmp browse_open

# find in files: the selection (one line) is the initial query
FN cmd_find_in_files
    PROLOGUE
    cmp qword ptr [rip + g_project], 0
    je 9f
    mov edi, PM_GREP
    call palette_open
    # the files are read once the field is on screen (palette_tick)
    mov dword ptr [rip + gload_state], GL_SCAN
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 8f
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    je 8f
    mov r12, rax
    mov r13, rdx
    sub r13, rax
    cmp r13, 200
    ja 8f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call doc_range
    mov r14, rax
    mov rdi, rax
    mov rsi, r13
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    test rax, rax
    jns 8f
    lea rdi, [rip + pal_tf]
    mov rsi, r14
    mov rdx, r13
    call tf_set
    lea rdi, [rip + pal_tf]
    call tf_select_all
8:  call palette_filter
9:  EPILOGUE

# FN palette_set_query(ptr, len): the open palette's field holds this text, filtered (run-command
# quick_open, command_palette, find_in_files with ARGS)
FN palette_set_query
    PROLOGUE
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + pal_tf]
    call tf_set
    call palette_filter
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# palette_timeout() -> 0 while find in files has files to read and has been drawn, else -1
FN palette_timeout
    mov eax, -1
    cmp dword ptr [rip + gload_state], GL_NONE
    je 1f
    cmp dword ptr [rip + gload_drawn], 0
    je 1f
    xor eax, eax
1:  ret

# palette_tick(): find in files reads the project's text files into memory once its field has been
# drawn, GREP_SLICE ms at a time, so the field comes up at once and keys keep working; with all of
# them read, the query runs again over every file
FN palette_tick
    PROLOGUE 16
    cmp dword ptr [rip + gload_state], GL_NONE
    je 9f
    cmp dword ptr [rip + gload_drawn], 0
    je 9f
    cmp qword ptr [rip + g_project], 0
    je 8f
    call time_ms
    mov [rsp], rax
    cmp dword ptr [rip + gload_state], GL_SCAN
    jne 1f
    # remote hosts: the host searches (grep_run): nothing is read here
    cmp dword ptr [rip + g_remote], 0
    jne 8f
    # the list goes to gload, as the search keeps its results in items
    mov qword ptr [rip + items + VEC_len], 0
    mov qword ptr [rip + results + VEC_len], 0
    call load_files
    mov rax, [rip + items + VEC_ptr]
    mov rcx, [rip + gload + VEC_ptr]
    mov [rip + gload + VEC_ptr], rax
    mov [rip + items + VEC_ptr], rcx
    mov rax, [rip + items + VEC_cap]
    mov rcx, [rip + gload + VEC_cap]
    mov [rip + gload + VEC_cap], rax
    mov [rip + items + VEC_cap], rcx
    mov rax, [rip + items + VEC_len]
    mov [rip + gload + VEC_len], rax
    mov qword ptr [rip + items + VEC_len], 0
    mov qword ptr [rip + gload_i], 0
    mov qword ptr [rip + gload_bytes], 0
    mov dword ptr [rip + gload_state], GL_READ
1:  mov rbx, [rip + gload_i]
    cmp rbx, [rip + gload + VEC_len]
    jae 8f
    cmp qword ptr [rip + gload_bytes], GREP_TOTAL_MAX
    jae 8f
    inc qword ptr [rip + gload_i]
    imul r12, rbx, IT_SIZE
    add r12, [rip + gload + VEC_ptr]
    mov rdi, [r12 + IT_label]   # workspace folders: wfold_join
    call wfold_join
    mov r13, rax
    mov rdi, rax
    call grep_read
    mov r14, rax
    mov r15, rdx
    mov rdi, r13
    call mem_free
    test r14, r14
    jz 2f
    add [rip + gload_bytes], r15
    lea rdi, [rip + gfiles]
    mov esi, GF_SIZE
    call vec_push
    mov rcx, [r12 + IT_label]
    mov [rax + GF_label], rcx
    mov [rax + GF_text], r14
    mov [rax + GF_len], r15
2:  call time_ms
    sub rax, [rsp]
    cmp rax, GREP_SLICE
    jb 1b
    jmp 9f
8:  # all read: by path, and the query over every file
    mov dword ptr [rip + gload_state], GL_NONE
    mov qword ptr [rip + gload + VEC_len], 0
    call sort_gfiles
    call palette_filter
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# palette_read_all(): find in files reads the rest of the project's files now (wait-grep)
FN palette_read_all
    push rbx
1:  cmp dword ptr [rip + gload_state], GL_NONE
    je 9f
    mov dword ptr [rip + gload_drawn], 1
    call palette_tick
    jmp 1b
9:  call rg_wait_answer        # remote hosts: and the host's answer to the query
    pop rbx
    ret

# rg_wait_answer(): remote hosts: until the host has answered the field's query (10 s at most)
rg_wait_answer:
    push rbx
    cmp dword ptr [rip + g_remote], 0
    je 8f
    call time_ms
    lea rbx, [rax + 10000]
2:  cmp dword ptr [rip + pal_mode], PM_GREP
    jne 8f
    cmp dword ptr [rip + rg_out], 0
    jne 3f
    call rg_answered
    test eax, eax
    jnz 8f
    call palette_filter         # not asked yet (a short query): asks now
    cmp dword ptr [rip + rg_out], 0
    je 8f
3:  call time_ms
    cmp rax, rbx
    jae 8f
    mov edi, 20
    call loop_poll
    call app_tick
    jmp 2b
8:  pop rbx
    ret

# rg_answered() -> eax 1 when the host's answer is for the field's query
rg_answered:
    sub rsp, 8
    lea rdi, [rip + pal_tf]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + rg_query]
    mov rcx, [rip + rg_query_len]
    call str_eq
    add rsp, 8
    ret

# sort_gfiles(): by path, byte order (shell sort)
sort_gfiles:
    PROLOGUE 32
    mov r15, [rip + gfiles + VEC_len]
    mov rbx, r15
.Lsg_gap:
    shr rbx, 1
    jz .Lsg_done
    mov r12, rbx                # i
.Lsg_i:
    cmp r12, r15
    jae .Lsg_gap
    imul rax, r12, GF_SIZE
    add rax, [rip + gfiles + VEC_ptr]
    movups xmm0, [rax]
    movups [rsp], xmm0
    mov rcx, [rax + 16]
    mov [rsp + 16], rcx
    mov r13, r12                # j
.Lsg_j:
    cmp r13, rbx
    jb .Lsg_put
    mov r14, r13
    sub r14, rbx
    imul rax, r14, GF_SIZE
    add rax, [rip + gfiles + VEC_ptr]
    mov rdi, [rax + GF_label]
    mov rsi, [rsp + GF_label]
1:  movzx ecx, byte ptr [rdi]
    movzx edx, byte ptr [rsi]
    cmp ecx, edx
    jne 2f
    test ecx, ecx
    jz .Lsg_put
    inc rdi
    inc rsi
    jmp 1b
2:  jb .Lsg_put
    imul rdx, r13, GF_SIZE
    add rdx, [rip + gfiles + VEC_ptr]
    movups xmm0, [rax]
    movups [rdx], xmm0
    mov rcx, [rax + 16]
    mov [rdx + 16], rcx
    mov r13, r14
    jmp .Lsg_j
.Lsg_put:
    imul rdx, r13, GF_SIZE
    add rdx, [rip + gfiles + VEC_ptr]
    movups xmm0, [rsp]
    movups [rdx], xmm0
    mov rcx, [rsp + 16]
    mov [rdx + 16], rcx
    inc r12
    jmp .Lsg_i
.Lsg_done:
    EPILOGUE

# grep_read(path) -> rax text (NUL-terminated) or 0 for an empty, big or binary file, rdx length;
# the text goes into the current GREP_BLOCK mapping
grep_read:
    PROLOGUE
    call file_open_read
    test rax, rax
    js 8f
    mov ebx, eax
    mov edi, eax
    call file_size
    test rax, rax
    jle 7f
    cmp rax, GREP_FILE_MAX
    ja 7f
    mov r12, rax
    mov rax, [rip + gblock_ptr]
    lea rcx, [rax + r12 + 1]
    test rax, rax
    jz 1f
    cmp rcx, [rip + gblock_end]
    jbe 2f
1:  mov edi, GREP_BLOCK
    call os_map
    mov [rip + gblock_ptr], rax
    lea rcx, [rax + GREP_BLOCK]
    mov [rip + gblock_end], rcx
    mov r13, rax
    lea rdi, [rip + gblocks]
    mov esi, 8
    call vec_push
    mov [rax], r13
2:  mov r13, [rip + gblock_ptr]
    xor r14d, r14d
3:  cmp r14, r12
    jae 4f
    mov edi, ebx
    lea rsi, [r13 + r14]
    mov rdx, r12
    sub rdx, r14
    SYS SYS_read
    cmp rax, -EINTR
    je 3b
    test rax, rax
    jle 4f
    add r14, rax
    jmp 3b
4:  mov byte ptr [r13 + r14], 0
    mov edi, ebx
    SYS SYS_close
    # binary: a NUL in the first 8 KiB
    test r14, r14
    jz 8f
    mov rdi, r13
    mov rcx, r14
    cmp rcx, 8192
    jbe 5f
    mov ecx, 8192
5:  xor eax, eax
    repne scasb
    je 8f
    lea rax, [r13 + r14 + 1]
    mov [rip + gblock_ptr], rax
    mov rax, r13
    mov rdx, r14
    EPILOGUE
7:  mov edi, ebx
    SYS SYS_close
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

grep_release:
    push rbx
    # the texts go back to the system with their mappings
    xor ebx, ebx
1:  cmp rbx, [rip + gblocks + VEC_len]
    jae 2f
    mov rax, [rip + gblocks + VEC_ptr]
    mov rdi, [rax + rbx*8]
    mov esi, GREP_BLOCK
    SYS SYS_munmap
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + gblocks + VEC_len], 0
    mov qword ptr [rip + gblock_ptr], 0
    mov qword ptr [rip + gblock_end], 0
    mov qword ptr [rip + gfiles + VEC_len], 0
    mov dword ptr [rip + gload_state], GL_NONE
    mov dword ptr [rip + gload_drawn], 0
    mov qword ptr [rip + gload + VEC_len], 0
    mov rdi, [rip + ghit]
    call mem_free
    mov qword ptr [rip + ghit], 0
    mov dword ptr [rip + gprev_len], 0
    mov qword ptr [rip + rg_query_len], 0     # remote hosts: a new search asks the host again
    pop rbx
    ret

# grep_narrow() -> 1 when the query extends the previous one, so files without a match for that
# (ghit 0) can be skipped; otherwise every file is marked as a maybe. Remembers the query.
grep_narrow:
    PROLOGUE
    cmp qword ptr [rip + ghit], 0
    jne 1f
    mov rdi, [rip + gfiles + VEC_len]
    inc rdi
    call mem_alloc
    mov [rip + ghit], rax
    mov dword ptr [rip + gprev_len], 0
1:  lea rdi, [rip + pal_tf]
    call tf_text
    mov r12, rax
    mov r13, rdx
    xor ebx, ebx
    mov ecx, [rip + gprev_len]
    test ecx, ecx
    jz 3f
    cmp r13, rcx
    jb 3f
    xor edx, edx
    lea r8, [rip + gprev]
2:  cmp rdx, rcx
    jae 21f
    movzx eax, byte ptr [r12 + rdx]
    cmp al, [r8 + rdx]
    jne 3f
    inc rdx
    jmp 2b
21: mov ebx, 1
    jmp 4f
3:  mov rdi, [rip + ghit]
    mov esi, 1
    mov rdx, [rip + gfiles + VEC_len]
    call memset
4:  xor eax, eax
    cmp r13, 255
    ja 5f
    lea rdi, [rip + gprev]
    mov rsi, r12
    mov rcx, r13
    rep movsb
    mov eax, r13d
5:  mov [rip + gprev_len], eax
    mov eax, ebx
    EPILOGUE

# grep_run(): one result per line containing the query; an uppercase letter makes it case-sensitive
# IT_data = file index << 44 | line << 20 | column
grep_run:
    PROLOGUE 64
    mov qword ptr [rip + items + VEC_len], 0
    lea rdi, [rip + gstr]
    call sb_clear
    cmp dword ptr [rip + g_remote], 0
    jne .Lgr_remote
    lea rdi, [rip + pal_tf]
    call tf_text
    mov [rsp], rax              # query
    mov [rsp + 8], rdx          # query length
    cmp rdx, 2
    jb .Lgr_fix
    mov dword ptr [rip + grep_case], 0
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 2f
    movzx r8d, byte ptr [rax + rcx]
    sub r8d, 'A'
    cmp r8d, 25
    ja 11f
    mov dword ptr [rip + grep_case], 1
11: inc rcx
    jmp 1b
2:  # while files are still being read every one is searched: ghit is sized for those read
    xor eax, eax
    cmp dword ptr [rip + gload_state], GL_NONE
    jne 22f
    call grep_narrow
22: mov [rsp + 60], eax
    xor ebx, ebx                # file index
.Lgr_file:
    cmp rbx, [rip + gfiles + VEC_len]
    jae .Lgr_fix
    mov dword ptr [rsp + 56], 0 # a match in this file
    cmp dword ptr [rsp + 60], 0
    je 21f
    mov rax, [rip + ghit]
    cmp byte ptr [rax + rbx], 0
    je .Lgr_skip
21: imul r12, rbx, GF_SIZE
    add r12, [rip + gfiles + VEC_ptr]
    xor r13d, r13d              # scan position (lines counted up to here)
    xor r14d, r14d              # line
    xor r15d, r15d              # line start
.Lgr_match:
    cmp qword ptr [rip + items + VEC_len], GREP_MAX
    jae .Lgr_fix
    mov rdi, [r12 + GF_text]
    add rdi, r13
    mov rsi, [r12 + GF_len]
    sub rsi, r13
    jbe .Lgr_nextfile
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    cmp dword ptr [rip + grep_case], 0
    je 3f
    call str_find
    jmp 4f
3:  call str_ifind
4:  test rax, rax
    js .Lgr_nextfile
    add rax, r13
    mov [rsp + 16], rax         # match
    mov rdi, [r12 + GF_text]
5:  cmp r13, rax
    jae 6f
    cmp byte ptr [rdi + r13], 10
    jne 51f
    inc r14
    lea r15, [r13 + 1]
51: inc r13
    jmp 5b
6:  mov rcx, [r12 + GF_len]     # r13 = line end; the next search starts there
7:  cmp r13, rcx
    jae 8f
    cmp byte ptr [rdi + r13], 10
    je 8f
    inc r13
    jmp 7b
8:  # label: the line without its indent, starting near the match when it is far right
    mov rax, r15
9:  cmp rax, [rsp + 16]
    jae 10f
    movzx ecx, byte ptr [rdi + rax]
    cmp cl, ' '
    je 91f
    cmp cl, 9
    jne 10f
91: inc rax
    jmp 9b
10: mov rcx, [rsp + 16]
    sub rcx, rax
    cmp rcx, 60
    jbe 12f
    mov rax, [rsp + 16]
    sub rax, 40
101: movzx ecx, byte ptr [rdi + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne 12f
    inc rax
    jmp 101b
12: mov [rsp + 24], rax         # label start
    lea rcx, [rax + 240]
    cmp rcx, r13
    jbe 121f
    mov rcx, r13
    jmp 13f
121: movzx edx, byte ptr [rdi + rcx]
    and edx, 0xc0
    cmp edx, 0x80
    jne 13f
    inc rcx
    jmp 121b
13: sub rcx, rax
    mov [rsp + 32], rcx         # label length
    mov rax, [rip + gstr + SB_len]
    mov [rsp + 40], rax         # label offset
    lea rdi, [rip + gstr]
    mov rsi, [r12 + GF_text]
    add rsi, [rsp + 24]
    mov rdx, rcx
    call sb_push
    # tabs and other control bytes shown as spaces
    mov rdi, [rip + gstr + SB_ptr]
    mov rcx, [rsp + 40]
14: cmp rcx, [rip + gstr + SB_len]
    jae 15f
    cmp byte ptr [rdi + rcx], ' '
    jae 141f
    mov byte ptr [rdi + rcx], ' '
141: inc rcx
    jmp 14b
15: # detail "path:line"
    mov rax, [rip + gstr + SB_len]
    mov [rsp + 48], rax
    lea rdi, [rip + gstr]
    mov rsi, [r12 + GF_label]
    call sb_push_cstr
    lea rdi, [rip + gstr]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + gstr]
    lea rsi, [r14 + 1]
    call sb_push_u64
    lea rdi, [rip + gstr]
    xor esi, esi
    call sb_push_byte
    # data
    mov rax, [rsp + 16]
    sub rax, r15
    cmp rax, 0xfffff
    jbe 16f
    mov eax, 0xfffff
16: mov rcx, r14
    shl rcx, 20
    or rax, rcx
    mov rcx, rbx
    shl rcx, 44
    or rcx, rax
    mov rdi, [rsp + 40]
    mov rsi, [rsp + 32]
    mov rdx, [rsp + 48]
    call item_add
    mov dword ptr [rsp + 56], 1
    jmp .Lgr_match
.Lgr_nextfile:
    # searched to its end: whether it has the query (no ghit while files are still being read)
    mov rax, [rip + ghit]
    test rax, rax
    jz .Lgr_skip
    mov ecx, [rsp + 56]
    mov [rax + rbx], cl
.Lgr_skip:
    inc rbx
    jmp .Lgr_file
.Lgr_fix:
    # offsets -> pointers, results in file order
    mov qword ptr [rip + results + VEC_len], 0
    xor ebx, ebx
1:  cmp rbx, [rip + items + VEC_len]
    jae 9f
    imul r12, rbx, IT_SIZE
    add r12, [rip + items + VEC_ptr]
    mov rax, [rip + gstr + SB_ptr]
    add [r12 + IT_label], rax
    add [r12 + IT_detail], rax
    lea rdi, [rip + results]
    mov esi, RS_SIZE
    call vec_push
    mov [rax + RS_item], ebx
    mov dword ptr [rax + RS_score], 0
    inc rbx
    jmp 1b
9:  EPILOGUE

# ---- find in files on a remote host ----
# The query goes to the host (vfs_grep); its answer comes later (rg_answer) and runs the filter again,
# which then shows it. Typing never waits; while a query is out, a newer one waits for its answer.

.Lgr_remote:
    lea rdi, [rip + pal_tf]
    call tf_text
    mov [rsp], rax
    mov [rsp + 8], rdx
    cmp rdx, 2
    jb .Lgr_fix
    cmp rdx, 255
    ja .Lgr_fix
    # the answer for this query is here: its lines become the items
    cmp [rip + rg_query_len], rdx
    jne 1f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + rg_query]
    mov rcx, [rip + rg_query_len]
    call str_eq
    test eax, eax
    jz 1f
    call rg_items
    jmp .Lgr_fix
1:  # ask, unless a query is out: its answer asks again
    cmp dword ptr [rip + rg_out], 0
    jne .Lgr_fix
    call rg_ask
    jmp .Lgr_fix

# rg_ask(): the field's query to the host (case-sensitive with a capital letter, as here)
rg_ask:
    PROLOGUE
    lea rdi, [rip + pal_tf]
    call tf_text
    mov rbx, rax
    mov r12, rdx
    lea rdi, [rip + rg_asked]
    mov rsi, rbx
    mov rdx, r12
    call memcpy
    mov [rip + rg_asked_len], r12
    xor r8d, r8d
    xor ecx, ecx
1:  cmp rcx, r12
    jae 2f
    movzx eax, byte ptr [rbx + rcx]
    sub eax, 'A'
    cmp eax, 25
    ja 11f
    mov r8d, 1
11: inc rcx
    jmp 1b
2:  mov rdi, [rip + g_project]
    mov rsi, rbx
    mov rdx, r12
    mov ecx, GREP_MAX
    lea r9, [rip + rg_answer]
    push 0
    push 0
    call vfs_grep
    add rsp, 16
    test eax, eax
    jz 9f
    mov dword ptr [rip + rg_out], 1
9:  EPILOGUE

# rg_answer(ctx, status, records, len): the host's lines for rg_asked; kept, then the filter again
rg_answer:
    PROLOGUE
    mov dword ptr [rip + rg_out], 0
    mov rbx, rdx
    mov r12, rcx
    test rsi, rsi
    js 9f
    lea rdi, [rip + rg_reply]
    call sb_clear
    test r12, r12
    jz 1f
    lea rdi, [rip + rg_reply]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
1:  lea rdi, [rip + rg_query]
    lea rsi, [rip + rg_asked]
    mov rdx, [rip + rg_asked_len]
    call memcpy
    mov rax, [rip + rg_asked_len]
    mov [rip + rg_query_len], rax
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 9f
    call palette_filter
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# rg_items(): items from rg_reply ("REL\0LINE\0COL\0LABEL\0" records), one gfiles entry per file
#   (its label only: accepting opens it as for a local search)
rg_items:
    PROLOGUE 64
    mov qword ptr [rip + gfiles + VEC_len], 0
    lea rdi, [rip + rg_paths]
    call sb_clear
    mov rbx, [rip + rg_reply + SB_ptr]
    test rbx, rbx
    jz 8f
    mov r15, [rip + rg_reply + SB_len]
    add r15, rbx                # end
    # the files' groups in path order, as the local search sorts its files
    call rg_groups_sort
    mov qword ptr [rsp + 48], 0 # the next group
    mov qword ptr [rsp + 40], -1  # the file index
0:  mov rax, [rsp + 48]
    cmp rax, [rip + rg_groups + VEC_len]
    jae 7f
    inc qword ptr [rsp + 48]
    mov rcx, [rip + rg_groups + VEC_ptr]
    mov rbx, [rcx + rax*8]
    mov [rsp + 56], rbx         # the group's path
1:  cmp rbx, r15
    jae 0b
    cmp qword ptr [rip + items + VEC_len], GREP_MAX
    jae 7f
    mov rdi, rbx
    mov rsi, [rsp + 56]
    call strcmp_eq
    test eax, eax
    jz 0b                       # the group's records end
    mov r12, rbx                # REL
    mov rdi, rbx
    call strlen
    lea r13, [rbx + rax + 1]    # LINE
    mov [rsp], rax
    cmp r13, r15
    jae 0b
    # a file other than the last: a new gfiles entry (its path in rg_paths, fixed up after)
    cmp qword ptr [rsp + 40], 0
    jl 2f
    mov rdi, [rip + gfiles + VEC_ptr]
    mov rax, [rsp + 40]
    imul rax, rax, GF_SIZE
    mov rdi, [rdi + rax + GF_label]
    add rdi, [rip + rg_paths + SB_ptr]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 3f
2:  lea rdi, [rip + gfiles]
    mov esi, GF_SIZE
    call vec_push
    mov rcx, [rip + rg_paths + SB_len]
    mov [rax + GF_label], rcx
    mov qword ptr [rax + GF_text], 0
    mov qword ptr [rax + GF_len], 0
    lea rdi, [rip + rg_paths]
    mov rsi, r12
    mov rdx, [rsp]
    call sb_push
    lea rdi, [rip + rg_paths]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + gfiles + VEC_len]
    dec rax
    mov [rsp + 40], rax
3:  mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    lea r14, [r13 + rax + 1]    # COL
    call parse_u64
    mov [rsp + 8], rax          # line
    mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    lea r13, [r14 + rax + 1]    # LABEL
    call parse_u64
    cmp rax, 0xfffff
    jbe 4f
    mov eax, 0xfffff
4:  mov [rsp + 16], rax         # col
    cmp r13, r15
    jae 7f
    mov rdi, r13
    call strlen
    mov [rsp + 24], rax
    lea rbx, [r13 + rax + 1]    # the next record
    # label, then detail "REL:LINE"
    mov rax, [rip + gstr + SB_len]
    mov [rsp + 32], rax
    lea rdi, [rip + gstr]
    mov rsi, r13
    mov rdx, [rsp + 24]
    call sb_push
    mov r14, [rip + gstr + SB_len]
    lea rdi, [rip + gstr]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + gstr]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + gstr]
    mov rsi, [rsp + 8]
    inc rsi
    call sb_push_u64
    lea rdi, [rip + gstr]
    xor esi, esi
    call sb_push_byte
    mov rcx, [rsp + 8]
    shl rcx, 20
    or rcx, [rsp + 16]
    mov rax, [rsp + 40]
    shl rax, 44
    or rcx, rax
    mov rdi, [rsp + 32]
    mov rsi, [rsp + 24]
    mov rdx, r14
    call item_add
    jmp 1b
7:  # the paths' offsets -> pointers
    xor ecx, ecx
71: cmp rcx, [rip + gfiles + VEC_len]
    jae 8f
    imul rax, rcx, GF_SIZE
    add rax, [rip + gfiles + VEC_ptr]
    mov rdx, [rip + rg_paths + SB_ptr]
    add [rax + GF_label], rdx
    inc rcx
    jmp 71b
8:  EPILOGUE

# rg_groups_sort(): rg_groups = the first record of each file's run in rg_reply, by path (byte order)
rg_groups_sort:
    PROLOGUE 16
    mov qword ptr [rip + rg_groups + VEC_len], 0
    mov rbx, [rip + rg_reply + SB_ptr]
    mov r15, [rip + rg_reply + SB_len]
    add r15, rbx
    xor r14d, r14d              # the last group's path
1:  cmp rbx, r15
    jae 5f
    test r14, r14
    jz 2f
    mov rdi, rbx
    mov rsi, r14
    call strcmp_eq
    test eax, eax
    jnz 3f
2:  lea rdi, [rip + rg_groups]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    mov r14, rbx
3:  # past the record's four fields
    mov r12d, 4
4:  mov rdi, rbx
    call strlen
    lea rbx, [rbx + rax + 1]
    dec r12d
    jz 1b
    cmp rbx, r15
    jb 4b
5:  # shell sort by path
    mov r15, [rip + rg_groups + VEC_len]
    mov r12, r15
.Lrgs_gap:
    shr r12, 1
    jz 9f
    mov r13, r12                # i
.Lrgs_i:
    cmp r13, r15
    jae .Lrgs_gap
    mov rax, [rip + rg_groups + VEC_ptr]
    mov rbx, [rax + r13*8]      # the one placed
    mov r14, r13                # j
.Lrgs_j:
    cmp r14, r12
    jb .Lrgs_put
    mov rax, [rip + rg_groups + VEC_ptr]
    mov rcx, r14
    sub rcx, r12
    mov rdi, [rax + rcx*8]
    mov rsi, rbx
6:  movzx eax, byte ptr [rdi]
    movzx edx, byte ptr [rsi]
    cmp eax, edx
    jne 7f
    test eax, eax
    jz .Lrgs_put
    inc rdi
    inc rsi
    jmp 6b
7:  jb .Lrgs_put
    mov rax, [rip + rg_groups + VEC_ptr]
    mov rcx, r14
    sub rcx, r12
    mov rdx, [rax + rcx*8]
    mov [rax + r14*8], rdx
    mov r14, rcx
    jmp .Lrgs_j
.Lrgs_put:
    mov rax, [rip + rg_groups + VEC_ptr]
    mov [rax + r14*8], rbx
    inc r13
    jmp .Lrgs_i
9:  EPILOGUE

# prompt_open(label cstr, kind, [initial text in pal_path])
FN prompt_open
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    mov edi, PM_PROMPT
    call palette_open
    mov [rip + pal_label], rbx
    mov [rip + pal_prompt], r12d
    mov dword ptr [rip + g_focus], FOCUS_PROMPT
    # initial text: current path for save as / rename, project dir + / for new files
    lea rdi, [rip + tmp]
    call sb_clear
    call prompt_initial
    lea rdi, [rip + pal_tf]
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    call tf_set
    pop r13
    pop r12
    pop rbx
    ret

prompt_initial:
    PROLOGUE
    mov eax, [rip + pal_prompt]
    cmp eax, PROMPT_SAVE_AS
    je 1f
    cmp eax, PROMPT_RENAME
    je 3f
    jmp 2f
1:  mov rax, [rip + g_doc]
    test rax, rax
    jz 2f
    mov rsi, [rax + DOC_path]
    test rsi, rsi
    jz 2f
    lea rdi, [rip + tmp]
    call sb_push_cstr
    jmp 9f
3:  lea rsi, [rip + g_explorer_target]
    cmp byte ptr [rsi], 0
    je 9f
    lea rdi, [rip + tmp]
    call sb_push_cstr
    jmp 9f
2:  # directory: explorer selection dir, else project
    lea rsi, [rip + g_explorer_dir]
    cmp byte ptr [rsi], 0
    jne 4f
    mov rsi, [rip + g_project]
    test rsi, rsi
    jnz 4f
    call vfs_home               # the host's in a remote window
    mov rsi, rax
    test rsi, rsi
    jz 9f
4:  lea rdi, [rip + tmp]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, '/'
    call sb_push_byte
9:  EPILOGUE

# ---- an extension's prompts (extproto.s owns the request; the palette shows it) ----

# palette_choose_open(label cstr): an empty pick list with the label as its placeholder; items
# follow with palette_choose_add, then palette_choose_ready
FN palette_choose_open
    push rbx
    mov rbx, rdi
    mov edi, PM_CHOOSE
    call palette_open
    mov [rip + pal_label], rbx
    pop rbx
    ret

# palette_choose_add(ptr, len, n): item number n (its IT_data)
FN palette_choose_add
    xor ecx, ecx
    xchg rcx, rdx
    jmp item_add

FN palette_choose_ready
    jmp palette_filter

# custom editors: palette_reopen_open(label cstr): an empty pick list for Reopen With; rows follow
# with palette_choose_add, then palette_choose_ready; choosing row n calls ce_reopen_chosen(n)
FN palette_reopen_open
    push rbx
    mov rbx, rdi
    mov edi, PM_REOPEN
    call palette_open
    mov [rip + pal_label], rbx
    pop rbx
    ret

# debugger: palette_dpick_open(label cstr): an empty pick list for a launch's ${pick:} or ${process}
# (debugask.s), a configuration or a template; rows follow with palette_choose_add, then
# palette_choose_ready; choosing row n calls dview_dpick_chosen(n)
FN palette_dpick_open
    push rbx
    mov rbx, rdi
    mov edi, PM_DPICK
    call palette_open
    mov [rip + pal_label], rbx
    pop rbx
    ret

# wsedit: palette_wslist_open(label cstr): an empty pick list for a workspace edit's question
# (wsconfirm.s); rows follow with palette_choose_add, then palette_choose_ready; choosing row n
# calls wslist_chosen(n), closing it otherwise wslist_abort
FN palette_wslist_open
    push rbx
    mov rbx, rdi
    mov edi, PM_WSLIST
    call palette_open
    mov [rip + pal_label], rbx
    pop rbx
    ret

# palette_links_open(label cstr): an empty pick list asking before a URL opens (links_ask_open); rows follow
# with palette_choose_add, then palette_choose_ready; choosing row n calls links_chose(n)
FN palette_links_open
    push rbx
    mov rbx, rdi
    mov edi, PM_LINKS
    call palette_open
    mov [rip + pal_label], rbx
    pop rbx
    ret

# palette_results_open(label cstr), palette_results_add(ptr, len, detail cstr or 0, n),
# palette_results_ready(), palette_results_close(): a list of langfeat's results; choosing item n
# calls langfeat_chosen(n). The strings stay langfeat's until it closes the list
FN palette_results_open
    push rbx
    mov rbx, rdi
    mov edi, PM_RESULTS
    call palette_open
    mov [rip + pal_label], rbx
    pop rbx
    ret

FN palette_providers_open
    push rbx
    mov rbx, rdi
    mov edi, PM_PROVIDERS
    call palette_open
    mov [rip + pal_label], rbx
    pop rbx
    ret

FN palette_results_add
    jmp item_add

# language features: a results list refreshed as a query's parts come keeps what the user did:
# palette_results_refresh() empties it but keeps the field (then _add and _ready as before),
# palette_results_selected() -> rax the selected item's n, or -1, palette_results_select(n): the
# row of item n is selected (after _ready)
# language features: the symbol mode (wsym.s): palette_wsym_open(label cstr), _showing() -> eax 1
# while it is open, _clear() (its items go, the query stays), _add(ptr, len, detail cstr, n),
# _ready(); choosing item n calls wsym_chosen(n). The strings stay wsym.s's until the next _clear
FN palette_wsym_open
    push rbx
    mov rbx, rdi
    mov edi, PM_WSYM
    call palette_open
    mov [rip + pal_label], rbx
    pop rbx
    ret
FN palette_wsym_showing
    xor eax, eax
    cmp dword ptr [rip + pal_mode], PM_WSYM
    sete al
    ret
FN palette_wsym_clear
    mov qword ptr [rip + items + VEC_len], 0
    mov qword ptr [rip + results + VEC_len], 0
    ret
FN palette_wsym_add
    jmp item_add
FN palette_wsym_ready
    push rbx
    mov ebx, [rip + pal_sel]    # the choice stays where it was as answers come
    call palette_filter
    mov eax, [rip + results + VEC_len]
    cmp ebx, eax
    jae 1f
    mov [rip + pal_sel], ebx
1:  pop rbx
    ret

FN palette_results_refresh
    mov qword ptr [rip + items + VEC_len], 0
    mov qword ptr [rip + results + VEC_len], 0
    ret
FN palette_results_selected
    push rbx
    call selected_item
    test rax, rax
    jz 1f
    mov rax, [rax + IT_data]
    pop rbx
    ret
1:  mov rax, -1
    pop rbx
    ret
FN palette_results_select
    xor ecx, ecx
1:  cmp rcx, [rip + results + VEC_len]
    jae 9f
    mov rax, [rip + results + VEC_ptr]
    mov eax, [rax + rcx*8 + RS_item]
    imul rax, rax, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    cmp [rax + IT_data], rdi
    je 2f
    inc rcx
    jmp 1b
2:  mov [rip + pal_sel], ecx
    mov dword ptr [rip + pal_reveal], 1
    mov dword ptr [rip + g_dirty], 1
9:  ret

FN palette_results_ready
    jmp palette_filter

# FN palette_results_showing() -> eax 1 while the palette shows a results list (language features:
# a list shown at a query's first part is refreshed only while it is still open)
FN palette_results_showing
    xor eax, eax
    cmp dword ptr [rip + pal_mode], PM_RESULTS
    sete al
    ret

FN palette_results_close
    cmp dword ptr [rip + pal_mode], PM_RESULTS
    jne 1f
    jmp palette_close
1:  ret

# palette_tasks_open(label cstr), palette_tasks_add(ptr, len, detail cstr, n), palette_tasks_ready():
#   a list of tasks (tasks.s); choosing item n calls tasks_chosen(n). The strings stay the tasks'
FN palette_tasks_open
    push rbx
    mov rbx, rdi
    mov edi, PM_TASKS
    call palette_open
    mov [rip + pal_label], rbx
    pop rbx
    ret

FN palette_tasks_add
    jmp item_add

FN palette_tasks_ready
    jmp palette_filter

# Close only a palette owned by the provider operation that is being abandoned.
FN palette_provider_close
    cmp dword ptr [rip + pal_mode], PM_PROVIDERS
    je 1f
    cmp dword ptr [rip + pal_mode], PM_PROMPT
    jne 2f
    cmp dword ptr [rip + pal_prompt], PROMPT_RENAME_SYMBOL
    jne 2f
1:  push rbx
    mov ebx, [rip + g_focus]
    call palette_close
    cmp ebx, FOCUS_PALETTE
    je 3f
    cmp ebx, FOCUS_PROMPT
    je 3f
    mov [rip + g_focus], ebx     # cancellation must not undo a focus change to another component
3:  pop rbx
2:  ret

# palette_ext_prompt_open(label cstr, PROMPT_ASK | PROMPT_TERM, text, len): a text prompt with
# the field preset
FN palette_ext_prompt_open
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov edi, PM_PROMPT
    call palette_open
    mov [rip + pal_label], rbx
    mov [rip + pal_prompt], r12d
    mov dword ptr [rip + g_focus], FOCUS_PROMPT
    lea rdi, [rip + pal_tf]
    mov rsi, r13
    mov rdx, r14
    call tf_set
    EPILOGUE

# palette_close_commands(): the command list holds CMD* and titles of extension commands that
# just moved or went: a palette showing it closes
FN palette_close_commands
    cmp dword ptr [rip + pal_mode], PM_COMMANDS
    je 2f
    cmp dword ptr [rip + pal_mode], PM_KEYS
    jne 1f
2:  jmp palette_close
1:  ret

# FN palette_close_keys(): the bindings were made again: the Keyboard Shortcuts list closes
FN palette_close_keys
    cmp dword ptr [rip + pal_mode], PM_KEYS
    jne 1f
    jmp palette_close
1:  ret

# palette_ext_keys_reset(): the extensions' commands changed: their shortcut labels are stale
FN palette_ext_keys_reset
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + ext_keys_cache + VEC_len]
    jae 2f
    mov rax, [rip + ext_keys_cache + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + ext_keys_cache + VEC_len], 0
    EPILOGUE

# ---- item sources ----

item_add:   # (label, len, detail, data)
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    lea rdi, [rip + items]
    mov esi, IT_SIZE
    call vec_push
    mov [rax + IT_label], rbx
    mov [rax + IT_len], r12
    mov [rax + IT_detail], r13
    mov [rax + IT_data], r14
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

load_commands:
    PROLOGUE
    cmp qword ptr [rip + pal_keys_cached], 0
    jne .Llc_cached
    call palette_ext_keys_reset
    xor ebx, ebx
.Llc_reset:
    cmp ebx, 256
    jae .Llc_reset_done
    lea rax, [rip + keys_cache]
    mov rdi, [rax + rbx*8]
    mov qword ptr [rax + rbx*8], 0
    call mem_free
    inc ebx
    jmp .Llc_reset
.Llc_reset_done:
    mov qword ptr [rip + pal_keys_cached], 1
.Llc_cached:
    lea rbx, [rip + g_commands]
1:  mov r12, [rbx + CMD_title]
    test r12, r12
    jz 9f
    cmp byte ptr [r12], 0
    je 2f
    mov rdi, r12
    call strlen
    mov r13, rax
    # shortcut label, formatted once per command
    mov rax, rbx
    lea rcx, [rip + g_commands]
    sub rax, rcx
    xor edx, edx
    mov ecx, CMD_SIZE
    div rcx
    mov r14, rax
    lea rcx, [rip + keys_cache]
    mov rax, [rcx + r14*8]
    test rax, rax
    jnz 3f
    mov rdi, rbx
    call keys_for
    test rax, rax
    jz 3f
    mov rdi, rax
    push rax
    call strlen
    pop rdi
    mov rsi, rax
    call mem_dup
    lea rcx, [rip + keys_cache]
    mov [rcx + r14*8], rax
3:  mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    mov rcx, rbx
    call item_add
2:  add rbx, CMD_SIZE
    jmp 1b
9:  # extension details carry the qualified identity and shortcut; both are cached per command
    mov edi, [rip + pal_focus_before]
    call ctx_focus_as           # [command-options] when clauses see the focus before the palette
    xor r14d, r14d
5:  cmp r14, [rip + g_ext_cmds + VEC_len]
    jae 8f
    mov rdi, r14
    call ext_cmd_live
    imul rbx, r14, CMD_SIZE
    add rbx, [rip + g_ext_cmds + VEC_ptr]
    inc r14
    test eax, eax
    jz 5b                       # an extension removed this session
    mov rdi, rbx
    call cmd_in_palette         # [command-options] palette = no, or its when is false
    test eax, eax
    jz 5b
    mov r12, [rbx + CMD_title]
    mov rdi, r12
    call strlen
    mov r13, rax
    lea rdi, [rip + ext_keys_cache]
    mov esi, 8
    call vec_ensure             # one slot per extension command
    mov rax, [rip + ext_keys_cache + VEC_ptr]
    mov rax, [rax + r14*8 - 8]
    test rax, rax
    jnz 6f
    lea rdi, [rip + tmp]
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + tmp]
    call ext_cmd_identity
    mov rdi, rbx
    call keys_for
    mov r15, rax
    test rax, rax
    jz 61f
    lea rdi, [rip + tmp]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, r15
    call sb_push_cstr
61: mov rdi, [rip + tmp + SB_ptr]
    mov rsi, [rip + tmp + SB_len]
    call mem_dup
    mov rcx, [rip + ext_keys_cache + VEC_ptr]
    mov [rcx + r14*8 - 8], rax
6:  mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    mov rcx, rbx
    call item_add
    jmp 5b
8:  mov edi, -1
    call ctx_focus_as
    EPILOGUE

# vec_ensure(vec, item size): grow vec to g_ext_cmds' length (zeroed slots)
vec_ensure:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
1:  mov rax, [rbx + VEC_len]
    cmp rax, [rip + g_ext_cmds + VEC_len]
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call vec_push
    jmp 1b
9:  EPILOGUE

load_themes:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + g_themes + VEC_len]
    jae 9f
    mov rdi, rbx
    call theme_entry
    mov r12, rax
    lea r13, [rip + .Ldark]
    cmp dword ptr [r12 + TH_dark], 0
    jne 2f
    lea r13, [rip + .Llight]
2:  cmp rbx, [rip + g_follow]
    jne 3f
    # "Follow Omarchy" shows the theme it stands for
    call omarchy_target
    mov rdi, rax
    call theme_entry
    mov r13, [rax + TH_name]
3:  mov rdi, [r12 + TH_name]
    call strlen
    mov rdi, [r12 + TH_name]
    mov rsi, rax
    mov rdx, r13
    mov rcx, rbx
    call item_add
    inc rbx
    jmp 1b
9:  # preselect the setting's theme
    mov rdi, [rip + pal_theme_slot]
    call theme_slot_index
    mov [rip + pal_sel], eax
    EPILOGUE

load_langs:
    PROLOGUE
    lea rdi, [rip + .Lautomatic]
    mov esi, 9
    xor edx, edx
    mov rcx, -1
    call item_add
    lea rdi, [rip + .Lplain]
    mov esi, 10
    xor edx, edx
    xor ecx, ecx
    call item_add
    xor ebx, ebx
1:  cmp rbx, [rip + g_grammars + VEC_len]
    jae 9f
    mov rax, [rip + g_grammars + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov rdi, [r12 + GR_name]
    call strlen
    mov rdi, [r12 + GR_name]
    mov rsi, rax
    mov rdx, [r12 + GR_files]
    mov rcx, r12
    call item_add
    inc rbx
    jmp 1b
9:  EPILOGUE

# load_files(): walk the project, relative paths
load_files:
    PROLOGUE
    lea rdi, [rip + strings]
    call sb_clear
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 9f
    cmp dword ptr [rip + g_remote], 0
    jne .Llf_remote
    call wfold_count
    cmp eax, 2
    jae .Llf_folders
    mov dword ptr [rip + scan_plen], 0
    mov dword ptr [rip + scan_depth], 0
    mov rdi, [rip + g_project]
    call scan_dir
.Llf_fix:
    # labels point into strings (stable after the scan): offsets -> pointers
    xor ebx, ebx
1:  cmp rbx, [rip + items + VEC_len]
    jae 9f
    imul rax, rbx, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    mov rcx, [rip + strings + SB_ptr]
    add [rax + IT_label], rcx
    inc rbx
    jmp 1b
9:  EPILOGUE

.Llf_folders:
    # workspace folders: each one's files, their labels starting with its name (workspace.s)
    xor ebx, ebx
1:  call wfold_count
    cmp rbx, rax
    jae .Llf_fix
    mov rdi, rbx
    call wfold_name
    lea rdi, [rip + scan_prefix]
    mov rsi, rax
    call cstr_copy
    mov byte ptr [rax], '/'
    lea rcx, [rip + scan_prefix]
    sub rax, rcx
    inc eax
    mov [rip + scan_plen], eax
    mov dword ptr [rip + scan_depth], 0
    mov rdi, rbx
    call wfold_path
    mov rdi, rax
    call scan_dir
    inc rbx
    jmp 1b
.Llf_remote:
    # remote hosts: the host walks the project in one request (vfs.s)
    mov esi, MAXFILES
    call vfs_files
    test rax, rax
    jz 9f
    mov r12, rax
    lea r13, [rax + rdx]
1:  cmp r12, r13
    jae .Llf_fix
    mov rdi, r12
    call strlen
    mov r14, rax
    test rax, rax
    jz 2f
    mov r15, [rip + strings + SB_len]
    lea rdi, [rip + strings]
    mov rsi, r12
    mov rdx, r14
    call sb_push
    lea rdi, [rip + strings]
    xor esi, esi
    call sb_push_byte
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    call item_add
2:  lea r12, [r12 + r14 + 1]
    jmp 1b
9:  EPILOGUE

# scan_dir(abs dir): recursion via dir_each callback
scan_dir:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + scan_depth], 16
    jae 9f
    inc dword ptr [rip + scan_depth]
    mov rdi, rbx
    lea rsi, [rip + scan_cb]
    mov rdx, rbx
    call dir_each
    dec dword ptr [rip + scan_depth]
9:  EPILOGUE

# scan_cb(dir, name, is_dir)
scan_cb:
    PROLOGUE 16
    mov r12, rdi                # abs dir
    mov r13, rsi                # name
    mov r14d, edx
    cmp qword ptr [rip + items + VEC_len], MAXFILES
    jae 9f
    mov rdi, r13
    call explorer_excluded
    test eax, eax
    jnz 9f
    # relative path = scan_prefix + name
    mov ebx, [rip + scan_plen]
    lea rdi, [rip + scan_prefix]
    add rdi, rbx
    mov rsi, r13
    call cstr_copy
    lea rcx, [rip + scan_prefix]
    sub rax, rcx
    mov r15, rax                # rel len
    test r14d, r14d
    jz 1f
    # directory: recurse
    cmp r15, 4000
    jae 9f
    lea rax, [rip + scan_prefix]
    mov byte ptr [rax + r15], '/'
    lea eax, [r15 + 1]
    mov [rip + scan_plen], eax
    mov rdi, r12
    mov rsi, r13
    call path_join
    mov [rsp], rax
    mov rdi, rax
    call scan_dir
    mov rdi, [rsp]
    call mem_free
    mov [rip + scan_plen], ebx
    jmp 9f
1:  # file: store offset now, pointer fixed up after the scan
    mov rax, [rip + strings + SB_len]
    mov [rsp], rax
    lea rdi, [rip + strings]
    lea rsi, [rip + scan_prefix]
    mov rdx, r15
    call sb_push
    lea rdi, [rip + strings]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rsp]
    mov rsi, r15
    xor edx, edx
    xor ecx, ecx
    call item_add
9:  EPILOGUE

# ---- path browser ----

# browse_open(folder): Open File (0) or Open Folder (1), starting in the project folder; 2 is Add
#   Folder to Workspace (workspace.s), which adds the folder picked instead of opening it
FN browse_open_kind
browse_open:
    PROLOGUE
    mov ebx, edi
    mov [rip + brw_kind], ebx
    mov byte ptr [rip + brw_dir], 0
    mov edi, PM_BROWSE
    call palette_open
    lea rax, [rip + .Lph_open_file]
    test ebx, ebx
    jz 1f
    lea rax, [rip + .Lph_open_folder]
    cmp ebx, 2
    jne 1f
    lea rax, [rip + .Lph_add_folder]
1:  mov [rip + pal_label], rax
    # the field: the project folder, the home folder as ~, and a '/'
    mov rsi, [rip + g_project]
    test rsi, rsi
    jnz 2f
    call vfs_home               # the host's in a remote window
    mov rsi, rax
    test rsi, rsi
    jnz 2f
    lea rsi, [rip + .Lroot]
2:  lea rdi, [rip + brw_label]
    call path_tilde
    cmp byte ptr [rax - 1], '/'
    je 3f
    mov byte ptr [rax], '/'
    inc rax
3:  lea rsi, [rip + brw_label]
    sub rax, rsi
    lea rdi, [rip + pal_tf]
    mov rdx, rax
    call tf_set
    call palette_changed
    EPILOGUE

# browse_split() -> rax field text, rdx its length through the last '/' (0 without one), rcx its length
browse_split:
    push rbx
    lea rdi, [rip + pal_tf]
    call tf_text
.ifdef WINDOWS
    mov rdi, rax
    call win_slashes
.endif
    mov rcx, rdx
    mov rbx, rdx
1:  test rbx, rbx
    jz 2f
    cmp byte ptr [rax + rbx - 1], '/'
    je 2f
    dec rbx
    jmp 1b
2:  mov rdx, rbx
    pop rbx
    ret

# browse_expand(dst, ptr, len): the folder a path in the field names, absolute and normalized: ~ is
# the home folder, and a path without a leading / or ~ is in the project
browse_expand:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r13, 3000
    jbe 1f
    mov r13d, 3000
1:  test r13, r13
    jz 3f
    PATH_ABSOLUTE r12, 12f
    jmp 11f
12:
    mov rdi, rbx
    jmp 5f
11: cmp byte ptr [r12], '~'
    jne 3f
    cmp r13, 1
    je 2f
    cmp byte ptr [r12 + 1], '/'
    jne 3f
2:  # ~: the home folder
    inc r12
    dec r13
    call vfs_home               # the host's in a remote window
    mov rdi, rbx
    test rax, rax
    jz 5f
    mov rsi, rax
    call cstr_copy
    mov rdi, rax
    jmp 5f
3:  # in the project, or the home folder without one
    mov rsi, [rip + g_project]
    test rsi, rsi
    jnz 4f
    call vfs_home               # the host's in a remote window
    mov rsi, rax
    test rsi, rsi
    jnz 4f
    lea rsi, [rip + .Lempty]
4:  mov rdi, rbx
    call cstr_copy
    mov byte ptr [rax], '/'
    lea rdi, [rax + 1]
5:  mov rsi, r12
    mov rcx, r13
    rep movsb
    mov byte ptr [rdi], 0
    # a relative home: taken as from the root
    PATH_ABSOLUTE rbx, 6f
    lea rdi, [rip + brw_label]
    mov rsi, rbx
    call cstr_copy
    mov byte ptr [rbx], '/'
    lea rdi, [rbx + 1]
    lea rsi, [rip + brw_label]
    call cstr_copy
6:  mov rdi, rbx
    call path_normalize
    EPILOGUE

# browse_filter(): the folder the field names is listed (again when it changed); the rows are the
# entries matching what follows the last '/', best first. Hidden entries need a query starting
# with '.'. Picking a folder, "Open <folder>" always leads.
browse_filter:
    PROLOGUE 16
    call browse_split
    mov r12, rax
    mov r13, rdx
    mov r14, rcx
    lea rdi, [rip + brw_next]
    mov rsi, r12
    mov rdx, r13
    call browse_expand
    lea rdi, [rip + brw_next]
    lea rsi, [rip + brw_dir]
    call strcmp_eq
    test eax, eax
    jnz 1f
    lea rdi, [rip + brw_dir]
    lea rsi, [rip + brw_next]
    call cstr_copy
    call browse_load
1:  lea r15, [r12 + r13]        # query
    sub r14, r13
    xor ebx, ebx
21: cmp rbx, [rip + items + VEC_len]
    jae 2f
    imul rax, rbx, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    test qword ptr [rax + IT_data], BRW_HERE | BRW_NEW
    jz 2f
    lea rdi, [rip + results]
    mov esi, RS_SIZE
    call vec_push
    mov [rax + RS_item], ebx
    mov dword ptr [rax + RS_score], 0
    inc ebx
    jmp 21b
2:  mov [rsp], rbx              # leading rows
3:  cmp rbx, [rip + items + VEC_len]
    jae 5f
    imul r12, rbx, IT_SIZE
    add r12, [rip + items + VEC_ptr]
    mov rdi, [r12 + IT_label]
    cmp byte ptr [rdi], '.'
    jne 31f
    test r14, r14
    jz 4f
    cmp byte ptr [r15], '.'
    jne 4f
31: mov rsi, [r12 + IT_len]
    mov rdx, r15
    mov rcx, r14
    call fuzzy
    test eax, eax
    js 4f
    mov r13d, eax
    lea rdi, [rip + results]
    mov esi, RS_SIZE
    call vec_push
    mov [rax + RS_item], ebx
    mov [rax + RS_score], r13d
4:  inc rbx
    jmp 3b
5:  test r14, r14
    jz 6f
    mov rax, [rsp]
    mov rdi, [rip + results + VEC_ptr]
    lea rdi, [rdi + rax*8]
    mov rsi, [rip + results + VEC_len]
    sub rsi, rax
    mov [rsp + 8], rdi
    mov rbx, rsi
    call rs_flip
    mov rdi, [rsp + 8]
    mov rsi, rbx
    call sort_u64
    mov rdi, [rsp + 8]
    mov rsi, rbx
    call rs_flip
6:  # the selection: the leading row, or the best match of a query; a query that matches nothing
    # leaves no rows, so Enter can't open the folder above a typo
    xor eax, eax
    test r14, r14
    jz 7f
    mov rcx, [rsp]
    cmp [rip + results + VEC_len], rcx
    ja 61f
    mov qword ptr [rip + results + VEC_len], 0
    jmp 7f
61: mov eax, ecx
7:  mov [rip + pal_sel], eax
    EPILOGUE

# browse_load(): the entries of brw_dir, folders first ("name/"), then files (none when picking a
# folder), by name; picking a folder, the "Open <folder>" and "... in a new window" rows first
browse_load:
    PROLOGUE
    mov qword ptr [rip + items + VEC_len], 0
    lea rdi, [rip + strings]
    call sb_clear
    lea rdi, [rip + brw_dir]
    call vfs_is_dir
    test eax, eax
    jz 9f
    xor ebx, ebx                # items before the sorted ones
    cmp dword ptr [rip + brw_kind], 0
    je 1f
    lea rdi, [rip + strings]
    lea rsi, [rip + .Lopen_here]
    cmp dword ptr [rip + brw_kind], 2
    jne 88f
    lea rsi, [rip + .Ladd_here]
88: call sb_push_cstr
    lea rdi, [rip + brw_label]
    lea rsi, [rip + brw_dir]
    call path_tilde
    lea rdi, [rip + strings]
    lea rsi, [rip + brw_label]
    call sb_push_cstr
    mov r12, [rip + strings + SB_len]
    lea rdi, [rip + strings]
    xor esi, esi
    call sb_push_byte
    xor edi, edi
    mov rsi, r12
    xor edx, edx
    mov ecx, BRW_HERE
    call item_add
    mov ebx, 1
    cmp dword ptr [rip + brw_kind], 2  # adding: no new window
    je 1f
    lea r13, [r12 + 1]
    lea rdi, [rip + strings]
    lea rsi, [rip + .Lopen_here]
    call sb_push_cstr
    lea rdi, [rip + strings]
    lea rsi, [rip + brw_label]
    call sb_push_cstr
    lea rdi, [rip + strings]
    lea rsi, [rip + .Lopen_new]
    call sb_push_cstr
    mov rsi, [rip + strings + SB_len]
    sub rsi, r13
    lea rdi, [rip + strings]
    push rsi
    push rsi
    xor esi, esi
    call sb_push_byte
    pop rsi
    pop rsi
    mov rdi, r13
    xor edx, edx
    mov ecx, BRW_NEW
    call item_add
    mov ebx, 2
1:  lea rdi, [rip + brw_dir]
    lea rsi, [rip + browse_cb]
    xor edx, edx
    call vfs_dir_each
    # labels point into strings (stable now): offsets -> pointers
    xor ecx, ecx
2:  cmp rcx, [rip + items + VEC_len]
    jae 3f
    imul rax, rcx, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    mov rdx, [rip + strings + SB_ptr]
    add [rax + IT_label], rdx
    inc rcx
    jmp 2b
3:  mov rdi, rbx
    call browse_sort
9:  EPILOGUE

# browse_cb(ctx, name, is_dir)
browse_cb:
    PROLOGUE 16
    mov r12, rsi
    mov r13d, edx
    cmp qword ptr [rip + items + VEC_len], BRW_MAX
    jae 9f
    test r13d, r13d
    jnz 1f
    cmp dword ptr [rip + brw_kind], 0
    jne 9f
1:  mov rax, [rip + strings + SB_len]
    mov [rsp], rax
    lea rdi, [rip + strings]
    mov rsi, r12
    call sb_push_cstr
    test r13d, r13d
    jz 2f
    lea rdi, [rip + strings]
    mov esi, '/'
    call sb_push_byte
2:  mov rax, [rip + strings + SB_len]
    sub rax, [rsp]
    mov [rsp + 8], rax
    lea rdi, [rip + strings]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    xor edx, edx
    mov ecx, r13d
    call item_add
9:  EPILOGUE

# browse_sort(first): the items from first on, folders first, then by name ignoring case (shell sort)
browse_sort:
    PROLOGUE 48
    mov r15, [rip + items + VEC_len]
    cmp r15, rdi
    jbe 9f
    sub r15, rdi                # n
    imul rax, rdi, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    mov [rsp + 32], rax         # a
    mov rbx, r15                # gap
.Lbs_gap:
    shr rbx, 1
    jz 9f
    mov r12, rbx                # i
.Lbs_i:
    cmp r12, r15
    jae .Lbs_gap
    imul rax, r12, IT_SIZE
    add rax, [rsp + 32]
    movups xmm0, [rax]
    movups xmm1, [rax + 16]
    movups [rsp], xmm0
    movups [rsp + 16], xmm1
    mov r13, r12                # j
.Lbs_j:
    cmp r13, rbx
    jb .Lbs_put
    mov r14, r13
    sub r14, rbx
    imul rsi, r14, IT_SIZE
    add rsi, [rsp + 32]
    lea rdi, [rsp]
    call it_less
    test eax, eax
    jz .Lbs_put
    imul rax, r14, IT_SIZE
    add rax, [rsp + 32]
    imul rdx, r13, IT_SIZE
    add rdx, [rsp + 32]
    movups xmm0, [rax]
    movups xmm1, [rax + 16]
    movups [rdx], xmm0
    movups [rdx + 16], xmm1
    mov r13, r14
    jmp .Lbs_j
.Lbs_put:
    imul rdx, r13, IT_SIZE
    add rdx, [rsp + 32]
    movups xmm0, [rsp]
    movups xmm1, [rsp + 16]
    movups [rdx], xmm0
    movups [rdx + 16], xmm1
    inc r12
    jmp .Lbs_i
9:  EPILOGUE

# it_less(a, b) -> 1 if item a sorts before item b: folders first, then by name ignoring case
it_less:
    mov eax, [rdi + IT_data]
    and eax, BRW_DIR
    mov ecx, [rsi + IT_data]
    and ecx, BRW_DIR
    cmp eax, ecx
    je 1f
    seta al
    movzx eax, al
    ret
1:  mov rdi, [rdi + IT_label]
    mov rsi, [rsi + IT_label]
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

# browse_complete(item): the field becomes the listed folder (written plainly) and the item's name;
# for a folder that goes into it
browse_complete:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + brw_label]
    lea rsi, [rip + brw_dir]
    call path_tilde
    cmp byte ptr [rax - 1], '/'
    je 1f
    mov byte ptr [rax], '/'
    mov byte ptr [rax + 1], 0
1:  lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + brw_label]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rbx + IT_label]
    mov rdx, [rbx + IT_len]
    call sb_push
    lea rdi, [rip + pal_tf]
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    call tf_set
    call palette_changed
    EPILOGUE

# pal_query() -> rax, rdx: what the items are matched against (the path browser: after the last '/')
pal_query:
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    je 1f
    lea rdi, [rip + pal_tf]
    jmp tf_text
1:  call browse_split
    add rax, rdx
    sub rcx, rdx
    mov rdx, rcx
    ret

# palette_print(sb): the field, then the rows ("> " marks the selected one), or "none"
FN palette_print
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + pal_mode], PM_NONE
    jne 1f
    lea rsi, [rip + .Lpp_none]
    call sb_push_cstr
    EPILOGUE
1:  cmp dword ptr [rip + pal_mode], PM_PROMPT
    je 10f
    cmp dword ptr [rip + pal_mode], PM_CHOOSE
    je 13f
    cmp dword ptr [rip + pal_mode], PM_WSLIST
    je 13f
    cmp dword ptr [rip + pal_mode], PM_LINKS
    je 13f
    cmp dword ptr [rip + pal_mode], PM_REOPEN   # custom editors
    je 13f
    cmp dword ptr [rip + pal_mode], PM_DPICK      # debugger
    je 13f
    cmp dword ptr [rip + pal_mode], PM_PROVIDERS
    je 13f
    cmp dword ptr [rip + pal_mode], PM_WSYM
    je 13f
    cmp dword ptr [rip + pal_mode], PM_RESULTS
    jne 11f
13: lea rsi, [rip + .Lpp_choose]
    jmp 12f
10: lea rsi, [rip + .Lpp_prompt]
12: call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + pal_label]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
11: lea rsi, [rip + .Lpp_field]
    call sb_push_cstr
    lea rdi, [rip + pal_tf]
    call tf_text
    mov rdi, rbx
    mov rsi, rax
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    cmp dword ptr [rip + gload_state], GL_NONE
    je 12f
    mov rdi, rbx
    lea rsi, [rip + .Lpp_reading]
    call sb_push_cstr
12: xor r12d, r12d
2:  cmp r12, [rip + results + VEC_len]
    jae 9f
    cmp r12, 20
    jae 9f
    lea rsi, [rip + .Lpp_row]
    cmp r12d, [rip + pal_sel]
    jne 3f
    lea rsi, [rip + .Lpp_sel]
3:  mov rdi, rbx
    call sb_push_cstr
    mov rax, [rip + results + VEC_ptr]
    mov eax, [rax + r12*8 + RS_item]
    imul rax, rax, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    mov rdi, rbx
    mov rsi, [rax + IT_label]
    mov rdx, [rax + IT_len]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r12
    jmp 2b
9:  EPILOGUE

# ---- fuzzy matching ----

# fuzzy(label, len, query, qlen) -> score (-1 when not a subsequence)
FN fuzzy
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    test r15, r15
    jz .Lfz_empty
    xor ebx, ebx                # score
    xor ecx, ecx                # label index
    xor edx, edx                # query index
    mov dword ptr [rsp], -2     # last match index
    # the basename part starts after the last '/'
    mov r8, r13
1:  test r8, r8
    jz 2f
    cmp byte ptr [r12 + r8 - 1], '/'
    je 2f
    dec r8
    jmp 1b
2:  mov [rsp + 8], r8
.Lfz_loop:
    cmp rdx, r15
    jae .Lfz_done
    cmp rcx, r13
    jae .Lfz_fail
    movzx eax, byte ptr [r12 + rcx]
    movzx r9d, byte ptr [r14 + rdx]
    lea r10d, [rax - 'A']
    cmp r10d, 25
    ja 3f
    or eax, 0x20
3:  lea r10d, [r9 - 'A']
    cmp r10d, 25
    ja 4f
    or r9d, 0x20
4:  cmp eax, r9d
    jne .Lfz_next
    add ebx, 10
    # consecutive
    mov eax, [rsp]
    inc eax
    cmp eax, ecx
    jne 5f
    add ebx, 15
5:  # word start
    test rcx, rcx
    jz 6f
    movzx eax, byte ptr [r12 + rcx - 1]
    cmp al, '/'
    je 6f
    cmp al, '_'
    je 6f
    cmp al, '-'
    je 6f
    cmp al, '.'
    je 6f
    cmp al, ' '
    je 6f
    # camelCase hump
    movzx r10d, byte ptr [r12 + rcx]
    sub r10d, 'A'
    cmp r10d, 25
    ja 7f
    sub eax, 'a'
    cmp eax, 25
    ja 7f
6:  add ebx, 12
7:  cmp rcx, [rsp + 8]
    jb 8f
    add ebx, 6                  # inside the file name
8:  mov [rsp], ecx
    inc rdx
.Lfz_next:
    inc rcx
    jmp .Lfz_loop
.Lfz_done:
    # prefer shorter labels
    mov eax, 200
    sub eax, r13d
    sar eax, 3
    add ebx, eax
    # the query is a prefix of the label (or all of it)
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    cmp rsi, rcx
    jb 1f
    mov rsi, rcx
    call str_ieq
    test eax, eax
    jz 1f
    add ebx, 40
    cmp r13, r15
    jne 1f
    add ebx, 100
1:  mov eax, ebx
    EPILOGUE
.Lfz_fail:
    mov eax, -1
    EPILOGUE
.Lfz_empty:
    xor eax, eax
    EPILOGUE

# palette_filter(): results = items matching the query, best first
FN palette_filter
    PROLOGUE 16
    mov dword ptr [rip + pal_reveal], 1
    mov dword ptr [rip + pal_wheel], 0
    mov qword ptr [rip + results + VEC_len], 0
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    jne .Lpf_grep
    call browse_filter
    jmp 5f
.Lpf_grep:
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 0f
    call grep_run
    jmp 5f
0:  cmp dword ptr [rip + pal_mode], PM_GOTO
    je 9f
    cmp dword ptr [rip + pal_mode], PM_PROMPT
    je 9f
    lea rdi, [rip + pal_tf]
    call tf_text
    mov r14, rax
    mov r15, rdx
    mov qword ptr [rsp], 0     # an exact qualified command takes precedence over fuzzy matches
    cmp dword ptr [rip + pal_mode], PM_COMMANDS
    jne .Lpf_command_query_ready
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lcommand_slash]
    mov ecx, 1
    call str_find
    test rax, rax
    js .Lpf_command_query_ready
    mov rdi, r14
    mov rsi, r15
    call ext_cmd_find
    mov [rsp], rax
.Lpf_command_query_ready:
    xor ebx, ebx
1:  cmp rbx, [rip + items + VEC_len]
    jae 45f
    imul r12, rbx, IT_SIZE
    add r12, [rip + items + VEC_ptr]
    mov rax, [rsp]
    test rax, rax
    jz 11f
    cmp [r12 + IT_data], rax
    jne 4f
    xor eax, eax
    jmp 12f
11:
    mov rdi, [r12 + IT_label]
    mov rsi, [r12 + IT_len]
    mov rdx, r14
    mov rcx, r15
    call fuzzy
    test eax, eax
    jns 12f
    cmp dword ptr [rip + pal_mode], PM_COMMANDS
    je 13f
    cmp dword ptr [rip + pal_mode], PM_KEYS
    jne 4f
13: mov rdi, [r12 + IT_detail]
    test rdi, rdi
    jz 4f
    call strlen
    mov rsi, rax
    mov rdi, [r12 + IT_detail]
    mov rdx, r14
    mov rcx, r15
    call fuzzy
    test eax, eax
    js 4f
12:
    mov r13d, eax
    lea rdi, [rip + results]
    mov esi, RS_SIZE
    call vec_push
    mov [rax + RS_item], ebx
    mov [rax + RS_score], r13d
4:  inc rbx
    jmp 1b
45: # best score first, ties in item order: sort (~score << 32 | item) ascending
    test r15, r15
    jz 5f
    mov rdi, [rip + results + VEC_ptr]
    mov rsi, [rip + results + VEC_len]
    call rs_flip
    mov rdi, [rip + results + VEC_ptr]
    mov rsi, [rip + results + VEC_len]
    call sort_u64
    mov rdi, [rip + results + VEC_ptr]
    mov rsi, [rip + results + VEC_len]
    call rs_flip
5:  # keep selection in range
    mov eax, [rip + pal_sel]
    mov rcx, [rip + results + VEC_len]
    cmp rax, rcx
    jb 9f
    xor eax, eax
    mov [rip + pal_sel], eax
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# rs_flip(ptr, n): complement the scores of RS records (their high halves)
rs_flip:
    mov rax, 0xffffffff00000000
1:  test rsi, rsi
    jz 2f
    xor [rdi], rax
    add rdi, 8
    dec rsi
    jmp 1b
2:  ret

FN palette_changed
    cmp dword ptr [rip + pal_mode], PM_THEMES
    je 1f
    mov dword ptr [rip + pal_sel], 0
    mov dword ptr [rip + pal_scroll], 0
1:  # '>' switches files -> commands
    cmp dword ptr [rip + pal_mode], PM_FILES
    jne 2f
    mov rax, [rip + pal_tf + TF_sb + SB_ptr]
    test rax, rax
    jz 2f
    cmp byte ptr [rax], '>'
    jne 3f
    push rbx
    call cmd_command_palette
    pop rbx
    ret
3:  cmp byte ptr [rax], ':'
    jne 4f
    cmp qword ptr [rip + g_doc], 0
    je 2f
    mov dword ptr [rip + pal_mode], PM_GOTO
    lea rdi, [rip + pal_tf]
    lea rsi, [rax + 1]
    mov rdx, [rip + pal_tf + TF_sb + SB_len]
    dec rdx
    call tf_set
    jmp 2f
4:  cmp byte ptr [rax], '#'     # language features: '#' switches files -> symbols in the project
    jne 2f
    push rbx
    call cmd_workspace_symbols
    pop rbx
2:  cmp dword ptr [rip + pal_mode], PM_WSYM
    jne 5f
    push rbx
    lea rdi, [rip + pal_tf]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call wsym_changed
    pop rbx
5:  jmp palette_filter

# selected item -> IT* or 0
selected_item:
    mov eax, [rip + pal_sel]
    cmp rax, [rip + results + VEC_len]
    jae 1f
    mov rcx, [rip + results + VEC_ptr]
    mov eax, [rcx + rax*8 + RS_item]
    imul rax, rax, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    ret
1:  xor eax, eax
    ret

# preview selection (themes)
preview:
    cmp dword ptr [rip + pal_mode], PM_ICONS
    jne 0f
    call selected_item
    test rax, rax
    jz 1f
    mov rdi, [rax + IT_data]
    jmp iconth_preview
0:  cmp dword ptr [rip + pal_mode], PM_THEMES
    jne 1f
    call selected_item
    test rax, rax
    jz 1f
    mov rdi, [rax + IT_data]
    cmp rdi, [rip + g_theme_cur]
    je 1f
    jmp theme_apply
1:  ret

# palette_key(keysym, cp, mods) -> 1 if handled
FN palette_key
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov [rip + pal_mods], edx
    cmp r12d, KEY_ESCAPE
    jne 1f
    call palette_close
    jmp .Lpk_yes
1:  cmp r12d, KEY_RETURN        # language features: ctrl+Enter in Find in Files moves its results
    jne 10f                     # to the Results panel (results.s)
    test r14d, MOD_CTRL
    jz 10f
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 10f
    call grep_to_results
    jmp .Lpk_yes
10: # remote hosts: moving in Find in Files' results waits for the host's answer they belong to
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 11f
    cmp dword ptr [rip + g_remote], 0
    je 11f
    mov eax, r12d
    cmp eax, KEY_UP
    je 12f
    cmp eax, KEY_DOWN
    je 12f
    cmp eax, KEY_PAGEUP
    je 12f
    cmp eax, KEY_PAGEDOWN
    jne 11f
12: call rg_wait_answer
11: cmp r12d, KEY_UP
    jne 2f
    mov dword ptr [rip + pal_reveal], 1
    mov dword ptr [rip + pal_wheel], 0
    mov eax, [rip + pal_sel]
    test eax, eax
    jz .Lpk_yes
    dec dword ptr [rip + pal_sel]
    call preview
    jmp .Lpk_yes
2:  cmp r12d, KEY_DOWN
    jne 3f
    mov dword ptr [rip + pal_reveal], 1
    mov dword ptr [rip + pal_wheel], 0
    mov eax, [rip + pal_sel]
    inc eax
    cmp rax, [rip + results + VEC_len]
    jae .Lpk_yes
    mov [rip + pal_sel], eax
    call preview
    jmp .Lpk_yes
3:  cmp r12d, KEY_PAGEDOWN
    jne 31f
    mov dword ptr [rip + pal_reveal], 1
    mov dword ptr [rip + pal_wheel], 0
    mov eax, [rip + pal_sel]
    add eax, 10
    mov rcx, [rip + results + VEC_len]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    test eax, eax
    jns 32f
    xor eax, eax
32: mov [rip + pal_sel], eax
    call preview
    jmp .Lpk_yes
31: cmp r12d, KEY_PAGEUP
    jne 33f
    mov dword ptr [rip + pal_reveal], 1
    mov dword ptr [rip + pal_wheel], 0
    mov eax, [rip + pal_sel]
    sub eax, 10
    jns 34f
    xor eax, eax
34: mov [rip + pal_sel], eax
    call preview
    jmp .Lpk_yes
33: cmp r12d, KEY_RETURN
    je 4f
    cmp r12d, KEY_KP_ENTER
    jne 5f
4:  call palette_accept
    jmp .Lpk_yes
5:  # text editing keys go to the field
    mov edi, r12d
    cmp edi, KEY_TAB
    jne 51f
    # the path browser: Tab takes the selected name
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    jne .Lpk_no
    call selected_item
    test rax, rax
    jz .Lpk_yes
    test qword ptr [rax + IT_data], BRW_HERE | BRW_NEW
    jnz .Lpk_yes
    mov rdi, rax
    call browse_complete
    jmp .Lpk_yes
51:
    lea rdi, [rip + pal_tf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
    test eax, eax
    jz .Lpk_no
    # ctrl+c / ctrl+a etc. don't change text; filtering is cheap anyway
    call palette_changed
    jmp .Lpk_yes
.Lpk_no:
    xor eax, eax
    EPILOGUE
.Lpk_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE

# grep_to_results(): Find in Files' results (as filtered now) become a Results set, the palette
# closes (language features, results.s)
grep_to_results:
    PROLOGUE 48
    lea rdi, [rip + pal_tf]
    call tf_text
    mov r15, rdx                # the query's length: each match's
    cmp rdx, 100
    jbe 1f
    mov edx, 100
1:  mov [rsp + 8], rdx
    lea rdi, [rip + gtr_query]
    mov rsi, rax
    call memcpy
    lea rax, [rip + gtr_query]
    mov rcx, [rsp + 8]
    mov byte ptr [rax + rcx], 0
    lea rdi, [rip + gtr_query]
    call results_find_begin
    mov [rsp], rax
    xor ebx, ebx
3:  cmp rbx, [rip + results + VEC_len]
    jae 8f
    mov rax, [rip + results + VEC_ptr]
    mov eax, [rax + rbx*8 + RS_item]
    imul r12, rax, IT_SIZE
    add r12, [rip + items + VEC_ptr]
    inc rbx
    mov r13, [r12 + IT_data]
    mov rax, r13
    shr rax, 44
    cmp rax, [rip + gfiles + VEC_len]
    jae 3b
    imul rax, rax, GF_SIZE
    add rax, [rip + gfiles + VEC_ptr]
    mov rdi, [rip + g_project]
    mov rsi, [rax + GF_label]
    call path_join
    mov r14, rax
    mov rax, r13                # the range: LINE COL to COL + the query's length
    shr rax, 20
    and eax, 0xffffff
    inc eax
    mov [rsp + 16], eax
    mov [rsp + 24], eax
    mov eax, r13d
    and eax, 0xfffff
    inc eax
    mov [rsp + 20], eax
    add eax, r15d
    mov [rsp + 28], eax
    mov rdi, [rsp]
    mov rsi, r14
    lea rdx, [rsp + 16]
    mov rcx, [r12 + IT_label]
    mov r8, [r12 + IT_len]
    call results_loc
    mov rdi, r14
    call mem_free
    jmp 3b
8:  call grep_release
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov rdi, [rsp]
    xor esi, esi
    call results_refs_end
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# palette_accept(): act on the selection / input
palette_accept:
    PROLOGUE 16
    mov ebx, [rip + pal_mode]
    cmp ebx, PM_REMOTE
    je .Lpa_remote
    cmp ebx, PM_GREP            # remote hosts: Enter right after typing waits for the host's answer
    jne 1f
    cmp dword ptr [rip + g_remote], 0
    je 1f
    call rg_wait_answer
1:
    cmp ebx, PM_GOTO
    je .Lpa_goto
    cmp ebx, PM_PROMPT
    je .Lpa_prompt
    cmp ebx, PM_BROWSE
    je .Lpa_browse
    call selected_item
    test rax, rax
    jz .Lpa_close
    mov r12, rax
    cmp ebx, PM_GREP
    je .Lpa_grep
    cmp ebx, PM_FILES
    jne 1f
    mov rdi, [r12 + IT_label]   # with two folders or more a label starts with its folder's name
    call wfold_join
    mov r13, rax
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov rdi, r13
    call app_open_file
    mov rdi, r13
    call mem_free
    jmp .Lpa_ret
1:  cmp ebx, PM_COMMANDS
    je 11f
    cmp ebx, PM_KEYS
    jne 2f
11: mov dword ptr [rip + pal_mode], PM_NONE
    call pal_return_focus
    mov rax, [r12 + IT_data]
    mov rdi, rax
    call [rax + CMD_fn]
    jmp .Lpa_ret
2:  cmp ebx, PM_ICONS
    jne 21f
    mov rdi, [r12 + IT_data]
    call iconth_choose
    jmp .Lpa_close
21: cmp ebx, PM_THEMES
    jne 3f
    # Keep the confirmed choice on screen. Picking for the inactive system mode also makes it
    # the fixed theme, otherwise closing would immediately replace it with the active mode's.
    mov rdi, [rip + pal_theme_slot]
    mov rsi, [r12 + IT_data]
    call theme_set
    call theme_slot
    cmp rax, [rip + pal_theme_slot]
    je .Lpa_close
    mov dword ptr [rip + cfg_follow_system], 0
    lea rdi, [rip + cfg_theme]
    mov rsi, [r12 + IT_data]
    call theme_set
    jmp .Lpa_close
3:  cmp ebx, PM_LANGS
    jne 31f
    cmp qword ptr [rip + g_doc], 0
    je .Lpa_close
    mov rdi, [rip + g_doc]
    mov rdx, [r12 + IT_data]
    mov esi, DL_AUTO
    cmp rdx, -1
    je .Lpa_language_set
    mov esi, DL_PLAIN
    test rdx, rdx
    jz .Lpa_language_set
    mov esi, DL_NAMED
    mov rdx, [rdx + GR_name]
.Lpa_language_set:
    call doc_language_set
    jmp .Lpa_close
31: cmp ebx, PM_RESULTS
    jne 32f
    mov dword ptr [rip + pal_mode], PM_NONE
    call pal_return_focus
    mov rdi, [r12 + IT_data]
    call langfeat_chosen
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
32: cmp ebx, PM_PROVIDERS
    jne 33f
    mov dword ptr [rip + pal_mode], PM_NONE
    call pal_return_focus
    mov rdi, [r12 + IT_data]
    call ext_provider_chosen
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
33: cmp ebx, PM_TASKS
    jne 332f
    mov dword ptr [rip + pal_mode], PM_NONE
    call pal_return_focus
    mov rdi, [r12 + IT_data]
    call tasks_chosen
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
332: cmp ebx, PM_REOPEN          # custom editors: Reopen With (customed.s)
    jne 331f
    mov dword ptr [rip + pal_mode], PM_NONE
    call pal_return_focus
    mov rdi, [r12 + IT_data]
    call ce_reopen_chosen
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
331: cmp ebx, PM_WSYM            # language features: a symbol in the project
    jne 335f
    mov dword ptr [rip + pal_mode], PM_NONE
    call pal_return_focus
    mov rdi, [r12 + IT_data]
    call wsym_chosen
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
335: cmp ebx, PM_WSLIST          # wsedit
    jne 34f
    mov dword ptr [rip + pal_mode], PM_NONE
    call pal_return_focus
    mov rdi, [r12 + IT_data]
    call wslist_chosen
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
34: cmp ebx, PM_DPICK            # debugger: a launch variable's answer (debugask.s)
    jne 35f
    mov dword ptr [rip + pal_mode], PM_NONE
    call pal_return_focus
    mov rdi, [r12 + IT_data]
    call dview_dpick_chosen
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
35: cmp ebx, PM_LINKS            # a reply's URL: the user's answer (links.s)
    jne 36f
    mov dword ptr [rip + pal_mode], PM_NONE
    call pal_return_focus
    mov rdi, [r12 + IT_data]
    call links_chose
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
36: cmp ebx, PM_CHOOSE
    jne .Lpa_close
    # the extension's pick: the item's number, with the palette closed first (the reply may
    # open another prompt)
    mov dword ptr [rip + pal_mode], PM_NONE
    call pal_return_focus
    mov rdi, [r12 + IT_data]
    call extproto_prompt_chose
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
.Lpa_remote:
    # remote hosts: the item picked, or the text typed when it matches none
    call selected_item
    mov rbx, -1
    test rax, rax
    jz 1f
    mov rbx, [rax + IT_data]
1:  lea rdi, [rip + pal_tf]
    call tf_text
    mov dword ptr [rip + pal_mode], PM_NONE
    push rax
    push rdx
    call pal_return_focus
    pop rdx
    pop rsi
    mov rdi, rbx
    call remote_ui_accept
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
.Lpa_goto:
    lea rdi, [rip + pal_tf]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test rdx, rdx
    jz .Lpa_close
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lpa_close
    dec rax
    jns 4f
    xor eax, eax
4:  cmp rax, [rbx + DOC_nlines]
    jb 5f
    mov rax, [rbx + DOC_nlines]
    dec rax
5:  mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov rdi, rbx
    mov rsi, rax
    xor edx, edx
    call ed_set_cursor
    # center it
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    mov ecx, [rip + g_ed_h_lines]
    shr ecx, 1
    sub rax, rcx
    jns 6f
    xor eax, eax
6:  shl rax, 8
    mov [rbx + DOC_scrolly], rax
    mov dword ptr [rip + g_reveal], 0
    jmp .Lpa_close
.Lpa_prompt:
    cmp dword ptr [rip + pal_prompt], PROMPT_WS_SAVE  # resources group: Save Workspace As
    jne 66f
    lea rdi, [rip + pal_tf]
    call tf_text
    mov dword ptr [rip + pal_mode], PM_NONE
    push rax
    push rdx
    call pal_return_focus
    pop rsi
    pop rdi
    call workspace_save_as
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
66: # extension management: the folder or archive to install
    mov ecx, [rip + pal_prompt]
    cmp ecx, PROMPT_EXT_FOLDER
    jb 67f
    cmp ecx, PROMPT_EXT_ARCHIVE
    ja 67f
    lea rdi, [rip + pal_tf]
    call tf_text
    mov dword ptr [rip + pal_mode], PM_NONE
    mov ecx, [rip + pal_prompt]
    push rax
    push rdx
    push rcx
    push rcx
    call pal_return_focus
    pop rdx
    pop rdx
    pop rsi
    pop rdi
    call ext_install_prompt_done
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
67: cmp dword ptr [rip + pal_prompt], PROMPT_EXT_INSTALL
    jne 68f
    lea rdi, [rip + pal_tf]
    call tf_text
    mov dword ptr [rip + pal_mode], PM_NONE
    push rax
    push rdx
    call pal_return_focus
    pop rsi
    pop rdi
    call ext_install_start
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
68: cmp dword ptr [rip + pal_prompt], PROMPT_EXT_SETTING
    jne 69f
    lea rdi, [rip + pal_tf]
    call tf_text
    mov dword ptr [rip + pal_mode], PM_NONE
    push rax
    push rdx
    call pal_return_focus
    pop rsi
    pop rdi
    call extpage_prompt_done
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
69: cmp dword ptr [rip + pal_prompt], PROMPT_RENAME_SYMBOL
    jne 691f
    lea rdi, [rip + pal_tf]
    call tf_text
    mov dword ptr [rip + pal_mode], PM_NONE
    push rax
    push rdx
    call pal_return_focus
    pop rsi
    pop rdi
    call langfeat_rename_to
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
691: cmp dword ptr [rip + pal_prompt], PROMPT_DEBUG    # debugger (debugview.s)
    jne 693f
    lea rdi, [rip + pal_tf]
    call tf_text
    mov dword ptr [rip + pal_mode], PM_NONE
    push rax
    push rdx
    call pal_return_focus
    pop rsi
    pop rdi
    call dview_prompt_done
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
693: cmp dword ptr [rip + pal_prompt], PROMPT_COLOR    # editor presentation: a swatch's color (hicolor.s)
    jne 690f
    lea rdi, [rip + pal_tf]
    call tf_text
    mov dword ptr [rip + pal_mode], PM_NONE
    push rax
    push rdx
    call pal_return_focus
    pop rsi
    pop rdi
    call color_prompt_done
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
690: cmp dword ptr [rip + pal_prompt], PROMPT_REMOTE
    je 693f
    cmp dword ptr [rip + pal_prompt], PROMPT_REMOTE_SECRET
    jne 692f
693: # remote hosts: ssh's question answered (or the port to forward)
    lea rdi, [rip + pal_tf]
    call tf_text
    mov ebx, [rip + pal_prompt]
    mov dword ptr [rip + pal_mode], PM_NONE
    push rax
    push rdx
    call pal_return_focus
    pop rsi
    pop rdi
    mov edx, ebx
    call remote_ui_prompt_done
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
692: cmp dword ptr [rip + pal_prompt], PROMPT_ASK
    jb 70f
    # an extension's prompt: the field's text goes back to it. A terminal command's prompt that
    # just appeared ignores Enter: a keystroke meant for the editor must not run it
    call extproto_prompt_fresh
    test eax, eax
    jnz .Lpa_ret
    lea rdi, [rip + pal_tf]
    call tf_text
    mov ebx, [rip + pal_prompt]
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov rdi, rax
    mov rsi, rdx
    mov edx, ebx
    call extproto_prompt_text
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_ret
70: lea rdi, [rip + pal_tf]
    call tf_text
    test rdx, rdx
    jz .Lpa_close
    # absolute path: relative input is taken from the project root
.ifdef WINDOWS
    mov rdi, rax
    call win_slashes
.endif
    lea rdi, [rip + pal_path]
    PATH_ABSOLUTE rax, 7f
    cmp byte ptr [rax], '~'
    jne 71f
    push rax
    push rdx
    call vfs_home               # the host's in a remote window
    mov rsi, rax
    lea rdi, [rip + pal_path]
    call cstr_copy
    mov rdi, rax
    pop rdx
    pop rax
    inc rax
    dec rdx
    jmp 7f
71: mov rsi, [rip + g_project]
    test rsi, rsi
    jz 7f
    push rax
    push rdx
    call cstr_copy
    mov byte ptr [rax], '/'
    lea rdi, [rax + 1]
    pop rdx
    pop rax
7:  mov rsi, rax
    mov rcx, rdx
    cmp rcx, 3000
    jbe 72f
    mov ecx, 3000
72: rep movsb
    mov byte ptr [rdi], 0
.ifdef WINDOWS
    lea rdi, [rip + pal_path]
    call path_normalize
.endif
    mov ebx, [rip + pal_prompt]
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    lea rdi, [rip + pal_path]
    mov esi, ebx
    call prompt_done
    jmp .Lpa_ret
.Lpa_grep:
    # open the file and select the match
    mov r13, [r12 + IT_data]
    mov rax, r13
    shr rax, 44
    imul rax, rax, GF_SIZE
    add rax, [rip + gfiles + VEC_ptr]
    mov rdi, [rax + GF_label]   # workspace folders: wfold_join
    call wfold_join
    mov r14, rax
    call grep_release
    mov dword ptr [rip + pal_mode], PM_NONE
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov rdi, r14
    call app_open_file
    mov rdi, r14
    call mem_free
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lpa_ret
    mov rsi, r13
    shr rsi, 20
    and esi, 0xffffff
    mov rax, [rbx + DOC_nlines]
    dec rax
    cmp rsi, rax
    cmova rsi, rax
    mov [rsp], rsi              # line
    mov rdi, rbx
    call doc_line_start
    mov r14, rax
    mov rdi, rbx
    mov rsi, [rsp]
    call doc_line_end
    mov r15, rax
    mov eax, r13d
    and eax, 0xfffff
    add rax, r14
    cmp rax, r15
    cmova rax, r15
    mov r14, rax
    mov rdi, rbx
    mov rsi, rax
    xor edx, edx
    call ed_set_cursor
    lea rdi, [rip + pal_tf]
    call tf_text
    lea rsi, [r14 + rdx]
    cmp rsi, r15
    cmova rsi, r15
    mov rdi, rbx
    mov edx, 1
    call ed_set_cursor
    mov rax, [rsp]
    mov ecx, [rip + g_ed_h_lines]
    shr ecx, 1
    sub rax, rcx
    jns 1f
    xor eax, eax
1:  shl rax, 8
    mov [rbx + DOC_scrolly], rax
    mov dword ptr [rip + g_reveal], 1
    jmp .Lpa_ret
.Lpa_browse:
    call selected_item
    test rax, rax
    jz .Lpa_ret
    mov r12, rax
    mov rax, [r12 + IT_data]
    test eax, BRW_HERE
    jnz .Lpa_here
    test eax, BRW_NEW
    jnz .Lpa_new
    test eax, BRW_DIR
    jz .Lpa_file
    # a folder: the browser goes into it; picking a folder, Ctrl+Enter opens it
    cmp dword ptr [rip + brw_kind], 0
    je 1f
    test dword ptr [rip + pal_mods], MOD_CTRL
    jnz 2f
1:  mov rdi, r12
    call browse_complete
    jmp .Lpa_ret
2:  lea rdi, [rip + brw_dir]
    mov rsi, [r12 + IT_label]
    call path_join_tmp
    lea rdi, [rip + brw_next]
    mov rsi, rax
    call cstr_copy
    lea rdi, [rip + brw_next]
    call path_normalize
    jmp .Lpa_switch
.Lpa_here:
    lea rdi, [rip + brw_next]
    lea rsi, [rip + brw_dir]
    call cstr_copy
.Lpa_switch:
    call palette_close
    lea rdi, [rip + brw_next]
    cmp dword ptr [rip + brw_kind], 2
    jne 1f
    call workspace_add_ui       # Add Folder to Workspace (workspace.s)
    jmp .Lpa_ret
1:  call app_switch_project
    jmp .Lpa_ret
.Lpa_new:
    # another rhun opens it; this window keeps its project
    lea rdi, [rip + brw_next]
    lea rsi, [rip + brw_dir]
    call cstr_copy
    call palette_close
    lea rdi, [rip + brw_next]
    call app_new_window
    jmp .Lpa_ret
.Lpa_file:
    lea rdi, [rip + brw_dir]
    mov rsi, [r12 + IT_label]
    call path_join
    mov r13, rax
    call palette_close
    mov rdi, r13
    call app_open_path
    mov rdi, r13
    call mem_free
    jmp .Lpa_ret
.Lpa_close:
    call palette_close
.Lpa_ret:
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# prompt_done(path, kind)
prompt_done:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp r12d, PROMPT_SAVE_AS
    jne 1f
    mov rdi, rbx
    call app_save_as_finish
    jmp 9f
1:  cmp r12d, PROMPT_NEW_FILE
    jne 2f
    # create the file (and its folders) if missing, then open it
    mov rdi, rbx
    call vfs_mtime
    test rax, rax
    jnz 11f
    mov rdi, rbx
    call vfs_mkdir_parent
    mov rdi, rbx
    lea rsi, [rip + .Lempty]
    xor edx, edx
    call vfs_write_all
11: mov rdi, rbx
    call app_open_file
    call explorer_refresh
    jmp 9f
2:  cmp r12d, PROMPT_NEW_FOLDER
    jne 3f
    mov rdi, rbx
    call vfs_mkdir_p
    call explorer_refresh
    jmp 9f
3:  cmp r12d, PROMPT_RENAME
    jne 9f
    mov edi, WK_RENAME          # wsedit: a workspace edit of its own, undoable
    lea rsi, [rip + g_explorer_target]
    mov rdx, rbx
    call ws_user_op
    test eax, eax
    jns 9f                      # made, or refused with a toast
    lea rdi, [rip + g_explorer_target]
    mov rsi, rbx
    xor edx, edx
    call vfs_rename
    test rax, rax
    js 8f
    # open tabs follow it: the file's, or those of the files inside a folder
    lea rdi, [rip + g_explorer_target]
    mov rsi, rbx
    call app_retarget_tabs
    call explorer_refresh
    jmp 9f
8:  lea rdi, [rip + .Lfailed]
    call app_toast
9:  EPILOGUE

# ---- drawing ----

FN palette_draw
    PROLOGUE 64
    cmp dword ptr [rip + pal_mode], PM_NONE
    je .Lpd_ret
    # find in files reads its files once this frame is on screen
    cmp dword ptr [rip + gload_state], GL_NONE
    je 98f
    mov dword ptr [rip + gload_drawn], 1
98:
    # scrim + card
    xor edi, edi
    xor esi, esi
    mov edx, [rip + g_cv + CV_w]
    mov ecx, [rip + g_cv + CV_h]
    mov r8d, 0x30000000
    call gfx_fill
    mov edi, 640
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 0f
    mov edi, 820
0:  call sc
    mov ecx, [rip + g_cv + CV_w]
    sub ecx, [rip + g_mt + 4*MI_64]
    cmp eax, ecx
    jle 24f
    mov eax, [rip + g_cv + CV_w]
    sub eax, [rip + g_mt + 4*MI_16]
24: mov ecx, 1
    cmp eax, ecx
    cmovl eax, ecx
    mov r12d, eax               # w
    mov eax, [rip + g_cv + CV_w]
    sub eax, r12d
    sar eax, 1
    mov r13d, eax               # x
    M r14d, MI_TITLE
    add r14d, [rip + g_mt + 4*MI_8]   # y
    M ebx, MI_32                # row height
    # visible rows
    mov rax, [rip + results + VEC_len]
    cmp rax, 12
    jbe 1f
    mov eax, 12
1:  mov [rsp], eax              # rows shown
    # Keep the card in the viewport and reveal selection in the fitted rows.
    mov eax, [rip + g_cv + CV_h]
    sub eax, r14d
    sub eax, [rip + g_mt + 4*MI_8]
    sub eax, [rip + g_mt + 4*MI_48]
    sub eax, [rip + g_mt + 4*MI_12]
    cdq
    idiv ebx
    mov ecx, 1
    cmp eax, ecx
    cmovl eax, ecx
    cmp eax, [rsp]
    jge 25f
    mov [rsp], eax
25: mov eax, [rsp]
    imul eax, ebx
    M ecx, MI_48
    add eax, ecx
    cmp dword ptr [rsp], 0
    je 2f
    add eax, [rip + g_mt + 4*MI_12]
2:  cmp dword ptr [rip + pal_mode], PM_PROMPT
    je 21f
    cmp dword ptr [rip + pal_mode], PM_GOTO
    je 21f
    cmp dword ptr [rip + pal_mode], PM_GREP
    je 20f
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    jne 22f
20: cmp dword ptr [rsp], 0
    jne 22f
21: add eax, [rip + g_mt + 4*MI_20]
22: cmp dword ptr [rip + pal_mode], PM_PROMPT
    jne 23f
    add eax, [rip + g_mt + 4*MI_32]   # the title
23: mov [rsp + 4], eax          # card h
    mov ecx, [rip + g_cv + CV_h]
    sub ecx, [rip + g_mt + 4*MI_8]
    sub ecx, eax
    cmp r14d, ecx
    cmovg r14d, ecx
    xor ecx, ecx
    cmp r14d, ecx
    cmovl r14d, ecx
    mov edi, r13d
    mov esi, r14d
    mov edx, r12d
    mov ecx, eax
    call ui_card
    # click outside closes
    test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz 3f
    mov edi, r13d
    mov esi, r14d
    mov edx, r12d
    mov ecx, [rsp + 4]
    call ui_in
    test eax, eax
    jnz 3f
    call palette_close
    jmp .Lpd_ret
3:  # a prompt says what the path is for above the field
    cmp dword ptr [rip + pal_mode], PM_PROMPT
    jne 31f
    mov edi, r13d
    mov esi, r14d
    call prompt_title
    add r14d, [rip + g_mt + 4*MI_32]
31: # input field
    call placeholder_text
    mov r10, rax
    M eax, MI_8
    mov [rsp + 8], eax
    lea rdi, [rip + pal_tf]
    lea esi, [r13 + rax]
    lea edx, [r14 + rax]
    mov ecx, r12d
    sub ecx, eax
    sub ecx, eax
    M r8d, MI_32
    xor r9d, r9d                # focused while keys come to it
    cmp dword ptr [rip + g_focus], FOCUS_PALETTE
    je .Lpd_focused
    cmp dword ptr [rip + g_focus], FOCUS_PROMPT
    jne .Lpd_field
.Lpd_focused:
    mov r9d, 1
.Lpd_field:
    push r10
    push r10
    call remote_field_for_draw  # remote hosts: a password's field is drawn masked
    call ui_textfield
    add rsp, 16
    # hint under the field for prompts / goto
    M r15d, MI_48
    add r15d, r14d
    mov eax, [rip + pal_mode]
    cmp eax, PM_PROMPT
    je 4f
    cmp eax, PM_GOTO
    je 4f
    cmp eax, PM_GREP
    je 41f
    cmp eax, PM_BROWSE
    jne 5f
41: cmp qword ptr [rip + results + VEC_len], 0
    jne 5f
4:  lea rdi, [rip + g_face_small]
    mov esi, r13d
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, r15d
    sub edx, [rip + g_mt + 4*MI_4]
    M ecx, MI_20
    call hint_text
    mov r8, rax
    COLOR r9d, T_MUTED
    call ui_text_c
    jmp .Lpd_ret
5:  # Mouse scrolling owns the viewport until selection changes explicitly.
    cmp dword ptr [rip + pal_reveal], 0
    je .Lpd_wheel
    mov dword ptr [rip + pal_reveal], 0
    mov eax, [rip + pal_sel]
    cmp eax, [rip + pal_scroll]
    jge 6f
    mov [rip + pal_scroll], eax
6:  mov ecx, [rip + pal_scroll]
    add ecx, [rsp]
    cmp eax, ecx
    jl 7f
    sub eax, [rsp]
    inc eax
    mov [rip + pal_scroll], eax
7:
.Lpd_wheel:
    movsxd rax, dword ptr [rip + g_scroll_y]
    test rax, rax
    jz .Lpd_clamp
    movsxd rdx, dword ptr [rip + pal_wheel]
    add rax, rdx
    cqo
    idiv rbx
    mov [rip + pal_wheel], edx
    add [rip + pal_scroll], eax
.Lpd_clamp:
    # Clamp on every frame, including after filtering shrinks the result list.
    mov eax, [rip + pal_scroll]
    mov rcx, [rip + results + VEC_len]
    sub ecx, [rsp]
    cmp eax, ecx
    jle .Lpd_top
    mov eax, ecx
    mov dword ptr [rip + pal_wheel], 0
.Lpd_top:
    test eax, eax
    jns .Lpd_edge_remainder
    xor eax, eax
    mov dword ptr [rip + pal_wheel], 0
.Lpd_edge_remainder:
    # Do not retain outward wheel motion at an edge: reversing responds at once.
    test eax, eax
    jnz .Lpd_bottom_remainder
    cmp dword ptr [rip + pal_wheel], 0
    jge .Lpd_bottom_remainder
    mov dword ptr [rip + pal_wheel], 0
.Lpd_bottom_remainder:
    cmp eax, ecx
    jne .Lpd_scroll_ready
    cmp dword ptr [rip + pal_wheel], 0
    jle .Lpd_scroll_ready
    mov dword ptr [rip + pal_wheel], 0
.Lpd_scroll_ready:
    mov [rip + pal_scroll], eax
    xor ecx, ecx
    mov [rsp + 12], ecx         # row i
.Lpd_row:
    mov ecx, [rsp + 12]
    cmp ecx, [rsp]
    jae .Lpd_ret
    mov eax, [rip + pal_scroll]
    add eax, ecx
    mov [rsp + 16], eax         # result index
    mov rdx, [rip + results + VEC_ptr]
    mov eax, [rdx + rax*8 + RS_item]
    imul rax, rax, IT_SIZE
    add rax, [rip + items + VEC_ptr]
    mov [rsp + 24], rax         # item
    mov eax, ecx
    imul eax, ebx
    add eax, r15d
    mov [rsp + 20], eax         # row y
    lea edi, [rcx + ID_PAL_ROW]
    M eax, MI_6
    lea esi, [r13 + rax]
    mov edx, [rsp + 20]
    mov ecx, r12d
    sub ecx, eax
    sub ecx, eax
    mov r8d, ebx
    call ui_btn
    mov [rsp + 32], eax
    test eax, UB_HOVER
    jz 8f
    # mouse moved over a row selects it (only on real movement / press)
    test eax, UB_PRESS
    jz 8f
    mov eax, [rsp + 16]
    mov [rip + pal_sel], eax
    call preview
8:  mov eax, [rsp + 16]
    cmp eax, [rip + pal_sel]
    jne 9f
    M eax, MI_6
    lea edi, [r13 + rax]
    mov esi, [rsp + 20]
    mov edx, r12d
    sub edx, eax
    sub edx, eax
    mov ecx, ebx
    M r8d, MI_RADIUS
    COLOR r9d, T_ACTIVE
    call gfx_round_rect
    jmp 10f
9:  test dword ptr [rsp + 32], UB_HOVER
    jz 10f
    M eax, MI_6
    lea edi, [r13 + rax]
    mov esi, [rsp + 20]
    mov edx, r12d
    sub edx, eax
    sub edx, eax
    mov ecx, ebx
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
10: # detail width
    mov dword ptr [rsp + 56], 0
    mov rax, [rsp + 24]
    mov rdi, [rax + IT_detail]
    test rdi, rdi
    jz 101f
    mov [rsp + 40], rdi
    call strlen
    mov [rsp + 48], rax
    lea rdi, [rip + g_face_small]
    mov rsi, [rsp + 40]
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_16]
    mov [rsp + 60], eax
    # at most 2/5 of the row: a longer one (a deep folder) shows its end
    lea ecx, [r12 + r12]
    push rax
    mov eax, ecx
    xor edx, edx
    mov ecx, 5
    div ecx
    mov ecx, eax
    pop rax
    cmp eax, ecx
    jbe 103f
    mov eax, ecx
103:mov [rsp + 56], eax
101: # label with matched characters highlighted, clipped before the detail; not the path
    # browser's "Open <folder>" rows
    mov rax, [rsp + 24]
    xor ecx, ecx
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    jne 102f
    test qword ptr [rax + IT_data], BRW_HERE | BRW_NEW
    setnz cl
102:mov [rip + pal_nohl], ecx
    M eax, MI_16
    lea edi, [r13 + rax]
    mov esi, [rsp + 20]
    mov edx, r12d
    sub edx, eax
    sub edx, eax
    sub edx, [rsp + 56]
    mov ecx, ebx
    call gfx_clip_push
    mov rax, [rsp + 24]
    mov rdi, [rax + IT_label]
    mov rsi, [rax + IT_len]
    M edx, MI_16
    add edx, r13d
    mov ecx, [rsp + 20]
    mov r8d, ebx
    call draw_highlighted
    call gfx_clip_pop
    # detail on the right
    cmp dword ptr [rsp + 56], 0
    je 11f
    mov edi, r13d
    add edi, r12d
    sub edi, [rsp + 56]
    mov esi, [rsp + 20]
    mov edx, [rsp + 56]
    mov ecx, ebx
    call gfx_clip_push
    mov esi, r13d
    add esi, r12d
    sub esi, [rsp + 60]
    lea rdi, [rip + g_face_small]
    mov edx, [rsp + 20]
    mov ecx, ebx
    mov r8, [rsp + 40]
    mov r9, [rsp + 48]
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    call gfx_clip_pop
11: test dword ptr [rsp + 32], UB_CLICK
    jz 12f
    mov eax, [rsp + 16]
    mov [rip + pal_sel], eax
    mov dword ptr [rip + pal_mods], 0
    call palette_accept
    jmp .Lpd_ret
12: inc dword ptr [rsp + 12]
    jmp .Lpd_row
.Lpd_ret:
    EPILOGUE

# prompt_title(x, y): the prompt's label ("New file", "New folder", ...) with its icon, in the top
# MI_32 of the card
prompt_title:
    PROLOGUE
    mov r12d, edi
    M r13d, MI_8
    add r13d, esi               # box y
    M r14d, MI_24               # box h
    mov eax, [rip + pal_prompt]
    mov edi, IC_FILE
    cmp eax, PROMPT_NEW_FILE
    jne 1f
    mov edi, IC_FILE_PLUS
1:  cmp eax, PROMPT_NEW_FOLDER
    jne 21f
    mov edi, IC_FOLDER_PLUS
21: cmp eax, PROMPT_RENAME_SYMBOL
    jne 2f
    mov edi, IC_F_CODE
2:  M ecx, MI_16
    mov esi, r12d
    add esi, ecx
    mov edx, r14d
    sub edx, ecx
    sar edx, 1
    add edx, r13d
    COLOR r8d, T_ACCENT
    call icon_draw
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_16]
    add esi, [rip + g_mt + 4*MI_16]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, r13d
    mov ecx, r14d
    mov r8, [rip + pal_label]
    COLOR r9d, T_FG
    call ui_text_c
    EPILOGUE

# draw_highlighted(label, len, x, y, h): label with query characters in accent
draw_highlighted:
    PROLOGUE 64
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx               # x
    mov [rsp], ecx              # y
    mov [rsp + 4], r8d          # h
    call pal_query
    mov [rsp + 8], rax          # query
    mov [rsp + 16], rdx
    cmp dword ptr [rip + pal_nohl], 0
    je .Ldh_query
    mov qword ptr [rsp + 16], 0
.Ldh_query:
    lea rax, [rip + g_face_ui]
    mov [rsp + 48], rax         # face
    mov qword ptr [rsp + 40], -1
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 0f
    # find in files: code font, the literal match highlighted
    lea rax, [rip + g_face_code]
    mov [rsp + 48], rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    cmp dword ptr [rip + grep_case], 0
    je 7f
    call str_find
    jmp 8f
7:  call str_ifind
8:  mov [rsp + 40], rax
0:  mov rcx, [rsp + 48]
    mov eax, [rsp + 4]
    sub eax, [rcx + FACE_ascent]
    sub eax, [rcx + FACE_descent]
    sar eax, 1
    add eax, [rsp]
    add eax, [rcx + FACE_ascent]
    mov [rsp + 24], eax         # baseline
    xor ebx, ebx                # label index
    xor r15d, r15d              # query index
1:  cmp rbx, r13
    jae 9f
    lea rdi, [r12 + rbx]
    mov rsi, r13
    sub rsi, rbx
    call utf8_decode
    mov [rsp + 32], edx
    COLOR r9d, T_FG
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 3f
    mov rax, [rsp + 40]
    cmp rbx, rax
    jb 2f
    add rax, [rsp + 16]
    cmp rbx, rax
    jae 2f
    COLOR r9d, T_ACCENT
    jmp 2f
3:  cmp r15, [rsp + 16]
    jae 2f
    mov rcx, [rsp + 8]
    movzx ecx, byte ptr [rcx + r15]
    movzx edx, byte ptr [r12 + rbx]
    mov edi, ecx
    push rdx
    call to_lower
    pop rdi
    mov ecx, eax
    push rcx
    call to_lower
    pop rcx
    cmp eax, ecx
    jne 2f
    inc r15
    COLOR r9d, T_ACCENT
2:  mov rdi, [rsp + 48]
    mov esi, r14d
    mov edx, [rsp + 24]
    lea rcx, [r12 + rbx]
    mov r8d, [rsp + 32]
    call text_draw
    mov r14d, eax
    mov eax, [rsp + 32]
    add rbx, rax
    jmp 1b
9:  EPILOGUE

placeholder_text:
    mov eax, [rip + pal_mode]
    lea rcx, [rip + .Lph_files]
    cmp eax, PM_FILES
    je 1f
    lea rcx, [rip + .Lph_cmds]
    cmp eax, PM_COMMANDS
    je 1f
    lea rcx, [rip + .Lph_keys]
    cmp eax, PM_KEYS
    je 1f
    lea rcx, [rip + .Lph_icons]
    cmp eax, PM_ICONS
    je 1f
    cmp eax, PM_THEMES
    jne 2f
    lea rcx, [rip + .Lph_dark]
    lea rax, [rip + cfg_dark_theme]
    cmp [rip + pal_theme_slot], rax
    je 1f
    lea rcx, [rip + .Lph_light]
    lea rax, [rip + cfg_light_theme]
    cmp [rip + pal_theme_slot], rax
    je 1f
    lea rcx, [rip + .Lph_themes]
    jmp 1f
2:
    lea rcx, [rip + .Lph_langs]
    cmp eax, PM_LANGS
    je 1f
    lea rcx, [rip + .Lph_goto]
    cmp eax, PM_GOTO
    je 1f
    lea rcx, [rip + .Lph_grep]
    cmp eax, PM_GREP
    je 1f
    mov rcx, [rip + pal_label]
1:  mov rax, rcx
    ret

hint_text:
    lea rax, [rip + .Lhint_nomatch]
    cmp dword ptr [rip + pal_mode], PM_BROWSE
    je 1f
    cmp dword ptr [rip + pal_mode], PM_GREP
    jne 2f
    lea rax, [rip + .Lhint_grep]
    cmp qword ptr [rip + pal_tf + TF_sb + SB_len], 2
    jb 1f
    lea rax, [rip + .Lhint_reading]
    cmp dword ptr [rip + gload_state], GL_NONE
    jne 1f
    lea rax, [rip + .Lhint_nomatch]
    ret
2:  lea rax, [rip + .Lhint_goto]
    cmp dword ptr [rip + pal_mode], PM_GOTO
    je 1f
    # prompts: what Enter does (only rax changes: the caller has the hint's box in the others)
    lea rax, [rip + .Lhint_new_file]
    cmp dword ptr [rip + pal_prompt], PROMPT_NEW_FILE
    je 1f
    lea rax, [rip + .Lhint_new_folder]
    cmp dword ptr [rip + pal_prompt], PROMPT_NEW_FOLDER
    je 1f
    lea rax, [rip + .Lhint_rename]
    cmp dword ptr [rip + pal_prompt], PROMPT_RENAME
    je 1f
    cmp dword ptr [rip + pal_prompt], PROMPT_RENAME_SYMBOL
    je 1f
    lea rax, [rip + .Lhint_ext_install]
    cmp dword ptr [rip + pal_prompt], PROMPT_EXT_INSTALL
    je 1f
    cmp dword ptr [rip + pal_prompt], PROMPT_REMOTE     # remote hosts: ssh's questions
    jae 1f
    lea rax, [rip + .Lhint_path]
1:  ret

.section .rodata
.Lcommand_slash: .asciz "/"
.Lhome: .asciz "HOME"
.Ldark: .asciz "dark"
.Llight: .asciz "light"
.Lplain: .asciz "Plain Text"
.Lautomatic: .asciz "Automatic"
.Lempty: .asciz ""
.Lfailed: .asciz "That didn't work"
.Lph_files: .asciz "Search files by name  (> commands, : line)"
.Lph_cmds: .asciz "Type a command"
.Lph_keys: .asciz "Search keyboard shortcuts"
.Lph_icons: .asciz "Select a file icon theme"
.Lph_themes: .asciz "Select a color theme"
.Lph_dark: .asciz "Select a theme for dark mode"
.Lph_light: .asciz "Select a theme for light mode"
.Lph_langs: .asciz "Select a language"
.Lph_goto: .asciz "Line number"
.Lph_grep: .asciz "Search in files"
.Lhint_grep: .asciz "Case-insensitive unless the text has capitals"
.Lhint_nomatch: .asciz "No matches"
.Lhint_reading: .asciz "Reading files..."
.Lnl: .ascii "\n"
.Lhint_goto: .asciz "Enter a line number and press Enter"
.Lhint_path: .asciz "Enter a path and press Enter, Esc to cancel"
.Lhint_ext_install: .asciz "Enter continues, Esc cancels"
.Lhint_new_file: .asciz "Enter creates the file, Esc cancels"
.Lhint_new_folder: .asciz "Enter creates the folder, Esc cancels"
.Lhint_rename: .asciz "Enter renames, Esc cancels"
.Lph_open_file: .asciz "Open a file"
.Lph_open_folder: .asciz "Open a folder"
.Lopen_here: .asciz "Open "
.Ladd_here: .asciz "Add "
.Lph_add_folder: .asciz "Add a folder to the workspace"
.Lopen_new: .asciz " in a new window"
.Lroot: .asciz "/"
.Lpp_none: .asciz "none\n"
.Lpp_field: .asciz "field="
.Lpp_reading: .asciz "reading\n"
.Lpp_prompt: .asciz "prompt="
.Lpp_choose: .asciz "choose="
.Lpp_row: .asciz "  "
.Lpp_sel: .asciz "> "
.bss
.p2align 3
keys_cache: .zero 8 * 256
ext_keys_cache: .zero VEC_SIZE  # the extensions' shortcut labels, one slot per command
.globl g_ed_h_lines
g_ed_h_lines: .long 0
