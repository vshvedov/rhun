# extensions: separate programs that talk to rhun over their standard input and output
# (docs/extensions/v1.md). This file: manifests and discovery, the commands they add to the
# palette, starting and stopping the programs, and moving bytes to and from them within the
# frame budget. extproto.s parses the lines and acts on them.
#
# Discovery runs in app_init, before keys_init, so manifest commands have their keys from the
# first frame; programs start lazily: on a command, on a matching document, or at startup (after
# the first frame, from ext_tick).
.include "rhun.inc"

.bss
.p2align 3
.globl g_exts, g_ext_cmds, g_ext_owner, g_ext_dir
g_exts: .zero VEC_SIZE          # EXT records, in discovery order
g_ext_cmds: .zero VEC_SIZE      # CMD records for the palette and [keys] (CMD_fn = ext_cmd_run)
g_ext_owner: .zero VEC_SIZE     # per command: the index of its EXT (u64)
g_ext_dir: .quad 0              # --extensions DIR, or 0 for the config folder
ext_manifest_cmds: .quad 0      # g_ext_cmds entries from manifests; runtime commands follow them
ext_root: .zero SB_SIZE         # the folder the extensions are read from
ext_state_root: .zero SB_SIZE   # ~/.local/state/rhun/extensions
ext_startup_done: .long 0       # on = startup extensions have been started
ext_project_done: .long 0       # on = project extensions have been started for this project
.p2align 3
ext_last_doc: .quad 0           # the highest DOC_id ext_tick has seen (new documents trigger activations)
ext_ticks: .long 0              # ticks so far (the log check runs every 64th)
.p2align 3
ext_project_seen: .quad 0       # owned copy of the project at the last tick
.p2align 3
cur_ext: .quad 0                # the EXT being loaded (manifest callbacks)
cur_owner: .quad 0              # the owner folder being scanned (cstr)
cur_owner_path: .quad 0
tmp: .zero SB_SIZE
tmp2: .zero SB_SIZE
ini_it: .zero INI_SIZE          # the manifest iterator
argv_vec: .zero VEC_SIZE
env_vec: .zero VEC_SIZE
pipe_in: .zero 8                # the program's input: read end, write end
pipe_out: .zero 8               # the program's output: read end, write end
reason_buf: .zero 256
ext_ini_path: .zero SB_SIZE     # ~/.config/rhun/extensions.ini

.data
.globl g_tab_width, g_insert_spaces
g_tab_width: .long 4            # the settings for the active document: the user's, under an
g_insert_spaces: .long 1        #   extension's option override (ext_options_apply, section 6c)

.text

# ---------------- options (section 6c) and runtime commands ----------------

# ext_options_apply(): g_tab_width and g_insert_spaces for the active document (its overrides, or
# the settings); called every tick and when the active tab changes. Clobbers rax, rcx only.
FN ext_options_apply
    mov eax, [rip + cfg_tab_width]
    mov [rip + g_tab_width], eax
    mov eax, [rip + cfg_insert_spaces]
    mov [rip + g_insert_spaces], eax
    mov rcx, [rip + g_doc]
    test rcx, rcx
    jz 9f
    mov eax, [rcx + DOC_oval + 4*OPT_TAB]
    test eax, eax
    jz 1f
    mov [rip + g_tab_width], eax
1:  mov eax, [rcx + DOC_oval + 4*OPT_SPACES]
    test eax, eax
    jz 9f
    dec eax                     # 1 = no -> 0, 2 = yes -> 1
    mov [rip + g_insert_spaces], eax
9:  ret

# ext_opt_bool(doc, OPT_TRIM | OPT_FINAL) -> eax: the effective yes (1) or no (0)
FN ext_opt_bool
    mov eax, [rdi + DOC_oval + rsi*4]
    test eax, eax
    jz 1f
    dec eax
    ret
1:  cmp esi, OPT_TRIM
    jne 2f
    mov eax, [rip + cfg_trim_trailing]
    ret
2:  mov eax, [rip + cfg_final_newline]
    ret

# ext_options_clear(ext): the overrides this extension set on any open document are removed
FN ext_options_clear
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + g_tabs + VEC_len]
    jae 9f
    imul rax, r12, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    inc r12
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 1b
    mov rax, [rax + TAB_doc]
    test rax, rax
    jz 1b
    xor ecx, ecx
2:  cmp [rax + DOC_oown + rcx*8], rbx
    jne 3f
    mov qword ptr [rax + DOC_oown + rcx*8], 0
    mov dword ptr [rax + DOC_oval + rcx*4], 0
3:  inc ecx
    cmp ecx, 4
    jb 2b
    jmp 1b
9:  call ext_options_apply
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ext_cmd_register(ext, name, nlen, keys, klen, title cstr) -> 0 registered, 1 the name is in
# use, 2 too many: a command for this session, like ext_cmd_add's but owned by the process
FN ext_cmd_register
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rcx              # keys
    mov [rsp + 8], r8
    mov r14, r9                 # title
    mov eax, 2
    cmp dword ptr [rbx + EXT_rtcmds], EXT_RTCMDS_MAX
    jae .Lcr_ret
    # name: NAME.key
    push rsi
    push rdx
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, '.'
    call sb_push_byte
    pop rdx
    pop rsi
    lea rdi, [rip + tmp]
    call sb_push
    mov rdi, [rip + tmp + SB_ptr]
    mov rsi, [rip + tmp + SB_len]
    call cmd_find
    test rax, rax
    jz 1f
    mov eax, 1
    jmp .Lcr_ret
1:  mov rdi, [rip + tmp + SB_ptr]
    call dup_cstr
    mov r12, rax                # name
    # title: "TITLE (Extension)"
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, r14
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lparen]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_title]
    test rsi, rsi
    jnz 2f
    mov rsi, [rbx + EXT_name]
2:  call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, ')'
    call sb_push_byte
    mov rdi, [rip + tmp + SB_ptr]
    call dup_cstr
    mov r13, rax                # title
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call mem_dup                # keys ("-" binds nothing: parse_combo rejects it)
    mov r14, rax
    lea rdi, [rip + g_ext_cmds]
    mov esi, CMD_SIZE
    call vec_push
    mov [rax + CMD_name], r12
    mov [rax + CMD_title], r13
    lea rcx, [rip + ext_cmd_run]
    mov [rax + CMD_fn], rcx
    mov [rax + CMD_keys], r14
    lea rdi, [rip + g_ext_owner]
    mov esi, 8
    call vec_push
    mov rcx, rbx
    lea rdx, [rip + g_exts]
    sub rcx, [rdx + VEC_ptr]
    push rax
    mov rax, rcx
    xor edx, edx
    mov ecx, EXT_SIZE
    div rcx
    mov rcx, rax
    pop rax
    mov [rax], rcx
    inc dword ptr [rbx + EXT_rtcmds]
    call ext_cmds_changed
    xor eax, eax
.Lcr_ret:
    EPILOGUE

# ext_cmds_remove_runtime(ext): its runtime commands leave g_ext_cmds (the manifests' entries
# all come first, so no other extension's EXT_cmd0 moves)
FN ext_cmds_remove_runtime
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + EXT_rtcmds], 0
    je 9f
    mov rax, rbx
    lea rcx, [rip + g_exts]
    sub rax, [rcx + VEC_ptr]
    xor edx, edx
    mov ecx, EXT_SIZE
    div rcx
    mov r12, rax                # this extension's index
    mov r13, [rip + g_ext_cmds + VEC_len]
1:  cmp r13, [rip + ext_manifest_cmds]
    jbe 8f
    dec r13
    mov rax, [rip + g_ext_owner + VEC_ptr]
    cmp [rax + r13*8], r12
    jne 1b
    imul r14, r13, CMD_SIZE
    add r14, [rip + g_ext_cmds + VEC_ptr]
    mov rdi, [r14 + CMD_name]
    call mem_free
    mov rdi, [r14 + CMD_title]
    call mem_free
    mov rdi, [r14 + CMD_keys]
    call mem_free
    # close the gap in both vectors
    mov rdi, r14
    lea rsi, [r14 + CMD_SIZE]
    mov rdx, [rip + g_ext_cmds + VEC_len]
    sub rdx, r13
    dec rdx
    imul rdx, rdx, CMD_SIZE
    call memmove
    dec qword ptr [rip + g_ext_cmds + VEC_len]
    mov rdi, [rip + g_ext_owner + VEC_ptr]
    lea rdi, [rdi + r13*8]
    lea rsi, [rdi + 8]
    mov rdx, [rip + g_ext_owner + VEC_len]
    sub rdx, r13
    dec rdx
    shl rdx, 3
    call memmove
    dec qword ptr [rip + g_ext_owner + VEC_len]
    jmp 1b
8:  mov dword ptr [rbx + EXT_rtcmds], 0
    call ext_cmds_changed
9:  EPILOGUE

# ext_cmds_changed(): the bindings point into g_ext_cmds, which moved or shrank: bind again; the
# palette's shortcut labels for extension commands are per index: drop them
ext_cmds_changed:
    push rbx
    call keys_reload
    call palette_ext_keys_reset
    call palette_close_commands # an open command palette holds pointers into the vector
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# ---------------- the user's choices: ~/.config/rhun/extensions.ini ----------------
# [owner/name] sections: disabled = yes, pinned = yes, and setting.KEY = VALUE for the extension's
# own settings that differ from their defaults.

# ext_ini_file() -> cstr path of extensions.ini
ext_ini_file:
    PROLOGUE
    cmp qword ptr [rip + ext_ini_path + SB_len], 0
    jne 9f
    call config_dir
    mov rbx, rax
    lea rdi, [rip + ext_ini_path]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + ext_ini_path]
    lea rsi, [rip + .Lf_extensions_ini]
    call sb_push_cstr
    lea rdi, [rip + ext_ini_path]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rip + ext_ini_path + SB_len]
9:  mov rax, [rip + ext_ini_path + SB_ptr]
    EPILOGUE

# ext_settings_load(): the choices for every extension record
ext_settings_load:
    PROLOGUE
    call ext_ini_file
    mov rdi, rax
    call file_read_all
    test rax, rax
    jz 9f
    mov r12, rax
    lea rdi, [rip + ini_it]
    mov rsi, rax
    call ini_init
1:  lea rdi, [rip + ini_it]
    call ini_next
    test eax, eax
    jz 8f
    lea rdi, [rip + ini_it]
    call ext_by_section
    test rax, rax
    jz 1b
    mov rdi, rax
    call apply_choice
    jmp 1b
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# ext_settings_load_one(ext): the choices of one extension (after an install)
ext_settings_load_one:
    PROLOGUE
    mov r13, rdi
    call ext_ini_file
    mov rdi, rax
    call file_read_all
    test rax, rax
    jz 9f
    mov r12, rax
    lea rdi, [rip + ini_it]
    mov rsi, rax
    call ini_init
1:  lea rdi, [rip + ini_it]
    call ini_next
    test eax, eax
    jz 8f
    lea rdi, [rip + ini_it]
    call ext_by_section
    cmp rax, r13
    jne 1b
    mov rdi, rax
    call apply_choice
    jmp 1b
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# apply_choice(ext): ini_it's key and value for it
apply_choice:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + ini_it]
    lea rsi, [rip + .Lk_disabled]
    call ini_key_is
    test eax, eax
    jz 2f
    call ini_val_yes
    mov [rbx + EXT_disabled], eax
    test eax, eax
    jz 9f
    mov dword ptr [rbx + EXT_status], ES_DISABLED
    mov qword ptr [rbx + EXT_reason], 0
    jmp 9f
2:  lea rdi, [rip + ini_it]
    lea rsi, [rip + .Lk_pinned]
    call ini_key_is
    test eax, eax
    jz 3f
    call ini_val_yes
    mov [rbx + EXT_pinned], eax
    jmp 9f
3:  # setting.KEY
    mov rdi, [rip + ini_it + INI_key]
    mov rsi, [rip + ini_it + INI_keylen]
    cmp rsi, 8
    jbe 9f
    cmp dword ptr [rdi], 0x74746573         # "sett"
    jne 9f
    cmp dword ptr [rdi + 4], 0x2e676e69     # "ing."
    jne 9f
    add rdi, 8
    sub rsi, 8
    mov rdx, rbx
    call sdef_find
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, [rip + ini_it + INI_val]
    mov rsi, [rip + ini_it + INI_vallen]
    call mem_dup
    mov rdi, r12
    mov rsi, rax
    call sdef_take_value
9:  EPILOGUE

# ini_val_yes() -> 1 when ini_it's value is "yes"
ini_val_yes:
    mov rdi, [rip + ini_it + INI_val]
    mov rsi, [rip + ini_it + INI_vallen]
    lea rdx, [rip + .Lv_yes]
    jmp str_eq_cstr

# ext_by_section(it) -> the live EXT whose "owner/name" is the iterator's section, or 0
ext_by_section:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 8f
    imul r13, r12, EXT_SIZE
    add r13, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [r13 + EXT_status], ES_REMOVED
    je 1b
    mov rdi, r13
    call ext_full_name
    mov rdi, rbx
    mov rsi, rax
    call ini_sec_is
    test eax, eax
    jz 1b
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ext_full_name(ext) -> "owner/name" in tmp (until tmp is used again)
FN ext_full_name
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_owner]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + tmp + SB_ptr]
    EPILOGUE

# ext_settings_save(): the file from the records: a section for each extension with a choice
FN ext_settings_save
    PROLOGUE
    lea rdi, [rip + tmp2]
    call sb_clear
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 8f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 1b
    # anything to write?
    mov eax, [rbx + EXT_pinned]
    or eax, [rbx + EXT_disabled]
    jnz 2f
    mov rdi, rbx
    call sdefs_changed
    test eax, eax
    jz 1b
2:  lea rdi, [rip + tmp2]
    mov esi, '['
    call sb_push_byte
    mov rdi, rbx
    call ext_full_name
    lea rdi, [rip + tmp2]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + tmp2]
    lea rsi, [rip + .Lw_close_sec]
    call sb_push_cstr
    cmp dword ptr [rbx + EXT_disabled], 0
    je 3f
    lea rdi, [rip + tmp2]
    lea rsi, [rip + .Lw_disabled_yes]
    call sb_push_cstr
3:  cmp dword ptr [rbx + EXT_pinned], 0
    je 4f
    lea rdi, [rip + tmp2]
    lea rsi, [rip + .Lw_pinned_yes]
    call sb_push_cstr
4:  # the settings that differ from their defaults
    xor r13d, r13d
5:  cmp r13, [rbx + EXT_sdefs + VEC_len]
    jae 1b
    imul r14, r13, SD_SIZE
    add r14, [rbx + EXT_sdefs + VEC_ptr]
    inc r13
    mov rdi, r14
    call sdef_is_default
    test eax, eax
    jnz 5b
    lea rdi, [rip + tmp2]
    lea rsi, [rip + .Lw_setting]
    call sb_push_cstr
    lea rdi, [rip + tmp2]
    mov rsi, [r14 + SD_key]
    call sb_push_cstr
    lea rdi, [rip + tmp2]
    lea rsi, [rip + .Lw_eq]
    call sb_push_cstr
    lea rdi, [rip + tmp2]
    mov rsi, [r14 + SD_value]
    call sb_push_cstr
    lea rdi, [rip + tmp2]
    mov esi, 10
    call sb_push_byte
    jmp 5b
8:  call config_dir
    mov rdi, rax
    call mkdir_p
    call ext_ini_file
    mov rdi, rax
    mov rsi, [rip + tmp2 + SB_ptr]
    mov rdx, [rip + tmp2 + SB_len]
    call file_write_all
    EPILOGUE

# ext_set_pinned(ext, yes): its button in the title bar, remembered
FN ext_set_pinned
    PROLOGUE
    mov [rdi + EXT_pinned], esi
    call ext_settings_save
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ext_set_disabled(ext, yes): Off stops it and keeps it stopped; On starts it
FN ext_set_disabled
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 9f                       # a menu or page left open on a removed record
    mov [rbx + EXT_disabled], esi
    call ext_settings_save
    test r12d, r12d
    jz 2f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_STOPPING
    je 11f
    cmp dword ptr [rbx + EXT_status], ES_FAILED
    je 9f                       # a bad manifest keeps its reason
    mov dword ptr [rbx + EXT_status], ES_DISABLED
    mov qword ptr [rbx + EXT_reason], 0
    jmp 9f
1:  mov rdi, rbx
    lea rsi, [rip + .Lr_turned_off]
    call ext_stop
    jmp 9f
11: # off again before the stop completed: the program is still alive, so it stays STOPPING
    # (ext_exited reaps it and makes it DISABLED); no restart
    mov dword ptr [rbx + EXT_restart], 0
    jmp 9f
2:  cmp dword ptr [rbx + EXT_status], ES_DISABLED
    je 21f
    cmp dword ptr [rbx + EXT_status], ES_STOPPING
    jne 9f
    mov dword ptr [rbx + EXT_restart], 1    # turned on again before the stop completed
    jmp 9f
21: mov dword ptr [rbx + EXT_status], ES_IDLE
    mov qword ptr [rbx + EXT_reason], 0
    mov rdi, rbx
    call ext_start
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ext_restart_now(ext): a running program stops and starts again; a stopped one starts
FN ext_restart_now
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + EXT_manifest_ok], 0
    je 9f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_DISABLED
    je 9f
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 9f
    mov dword ptr [rbx + EXT_status], ES_STOPPED
    mov rdi, rbx
    call ext_restart
    jmp 9f
1:  mov dword ptr [rbx + EXT_restart], 1
    mov rdi, rbx
    lea rsi, [rip + .Lr_settings_change]
    call ext_stop
9:  EPILOGUE

# ext_stop_user(ext): stopped by the user
FN ext_stop_user
    lea rsi, [rip + .Lr_settings_stop]
    jmp ext_stop

# ---------------- installing and removing (extinstall.s asks; these change the records) ------

# ext_root_dir() -> the folder extensions are installed in (cstr)
FN ext_root_dir
    mov rax, [rip + ext_root + SB_ptr]
    ret

# ext_preview(ptr, len, ext) -> 1 when the manifest names title, version, owner and name: those,
# the description and [needs] into the scratch record (nothing is registered)
FN ext_preview
    PROLOGUE
    mov r14, rdi
    mov r15, rsi
    mov rbx, rdx
    lea rdi, [rip + ini_it]
    mov rsi, r14
    mov rdx, r15
    call ini_init
1:  lea rdi, [rip + ini_it]
    call ini_next
    test eax, eax
    jz 8f
    lea r12, [rip + ini_it]
    cmp qword ptr [r12 + INI_seclen], 0
    jne 5f
    mov rdi, r12
    lea rsi, [rip + .Lk_title]
    call ini_key_is
    lea r13, [rbx + EXT_title]
    test eax, eax
    jnz 4f
    mov rdi, r12
    lea rsi, [rip + .Lk_version]
    call ini_key_is
    lea r13, [rbx + EXT_version]
    test eax, eax
    jnz 4f
    mov rdi, r12
    lea rsi, [rip + .Lk_description]
    call ini_key_is
    lea r13, [rbx + EXT_desc]
    test eax, eax
    jnz 4f
    mov rdi, r12
    lea rsi, [rip + .Lk_name]
    call ini_key_is
    lea r13, [rbx + EXT_mname]
    test eax, eax
    jnz 4f
    mov rdi, r12
    lea rsi, [rip + .Lk_owner]
    call ini_key_is
    lea r13, [rbx + EXT_mowner]
    test eax, eax
    jz 1b
4:  call val_dup
    mov [r13], rax
    jmp 1b
5:  mov rdi, r12
    lea rsi, [rip + .Ls_needs]
    call ini_sec_is
    test eax, eax
    jz 1b
    call parse_needs
    jmp 1b
8:  xor eax, eax
    cmp qword ptr [rbx + EXT_title], 0
    je 9f
    cmp qword ptr [rbx + EXT_version], 0
    je 9f
    cmp qword ptr [rbx + EXT_mname], 0
    je 9f
    cmp qword ptr [rbx + EXT_mowner], 0
    je 9f
    mov eax, 1
9:  EPILOGUE

# ext_install_load(dir, owner, name) -> EXT* or 0: an extension installed while rhun runs: loaded,
# its manifest commands placed with the other manifests' (before any runtime command), its choices
# read, bindings and the palette refreshed, and started
FN ext_install_load
    PROLOGUE 16
    mov rax, [rip + g_ext_cmds + VEC_len]
    mov [rsp], rax              # where its commands will start
    call ext_load
    test rax, rax
    jz 9f
    mov rbx, rax
    # its commands went to the end: the runtime ones (between the boundary and them) move up
    mov r12, [rip + ext_manifest_cmds]
    mov r13, [rsp]
    sub r13, r12                # runtime commands
    mov r14d, [rbx + EXT_ncmd]
    test r13, r13
    jz 5f
    test r14, r14
    jz 5f
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    lea rcx, [rip + g_ext_cmds]
    mov r8d, CMD_SIZE
    call rotate_entries
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    lea rcx, [rip + g_ext_owner]
    mov r8d, 8
    call rotate_entries
5:  mov [rbx + EXT_cmd0], r12d
    add [rip + ext_manifest_cmds], r14
    mov rdi, rbx
    call ext_settings_load_one
    call ext_cmds_changed
    cmp dword ptr [rbx + EXT_status], ES_FAILED
    je 7f                      # keep the validation failure; its commands must not start it
    mov dword ptr [rbx + EXT_status], ES_IDLE
    cmp dword ptr [rbx + EXT_disabled], 0
    je 6f
    mov dword ptr [rbx + EXT_status], ES_DISABLED
    jmp 7f
6:  cmp qword ptr [rbx + EXT_reason], 0
    jne 7f                      # a bad manifest stays failed
    mov rdi, rbx
    call ext_start
7:  mov rax, rbx
9:  EPILOGUE

# rotate_entries(first, a, b, vec, size): entries [first, first+a) and [first+a, first+a+b) swap
# places (the b entries come first), in a vector of size-byte entries
rotate_entries:
    PROLOGUE 32
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov rbx, rcx
    mov r15d, r8d
    # the b entries aside
    mov rdi, [rsp + 16]
    imul rdi, r15
    call mem_alloc
    mov r14, rax
    mov rax, [rsp]
    add rax, [rsp + 8]
    imul rax, r15
    mov rsi, [rbx + VEC_ptr]
    add rsi, rax
    mov rdi, r14
    mov rdx, [rsp + 16]
    imul rdx, r15
    call memcpy
    # the a entries up by b
    mov rax, [rsp]
    imul rax, r15
    mov rsi, [rbx + VEC_ptr]
    add rsi, rax
    mov rdi, [rsp + 16]
    imul rdi, r15
    add rdi, rsi
    mov rdx, [rsp + 8]
    imul rdx, r15
    call memmove
    # the b entries at first
    mov rax, [rsp]
    imul rax, r15
    mov rdi, [rbx + VEC_ptr]
    add rdi, rax
    mov rsi, r14
    mov rdx, [rsp + 16]
    imul rdx, r15
    call memcpy
    mov rdi, r14
    call mem_free
    EPILOGUE

# ext_retire(ext): removed or replaced: the program ends now, its commands go inert and leave the
# palette and the bindings
FN ext_retire
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_STOPPING
    jne 2f
1:  mov rdi, rbx
    lea rsi, [rip + .Lr_removed]
    call ext_kill
2:  mov dword ptr [rbx + EXT_status], ES_REMOVED
    mov dword ptr [rbx + EXT_restart], 0
    mov qword ptr [rbx + EXT_pending], 0
    call extpage_forget         # its details page goes back to the list (a reinstall is a new record)
    mov rdi, rbx
    call ext_icon_free
    mov rdi, rbx
    call extview_owner_gone
    mov rdi, rbx
    call complete_ext_gone
    mov rdi, rbx
    call langfeat_ext_gone
    call ext_cmds_changed
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ---------------- an extension's own settings ([settings] in the manifest) ----------------

# sdef_find(key ptr, len, ext) -> SD* or 0
FN sdef_find
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rbx, rdx
    xor r14d, r14d
1:  cmp r14, [rbx + EXT_sdefs + VEC_len]
    jae 8f
    imul r15, r14, SD_SIZE
    add r15, [rbx + EXT_sdefs + VEC_ptr]
    inc r14
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r15 + SD_key]
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# sdef_take_value(sd, value cstr owned): the value in force, after checking it fits the type (an int
# is clamped, a bool is yes or no, a choice one of its options; anything else keeps the old value)
FN sdef_take_value
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [rbx + SD_type]
    cmp eax, SDT_BOOL
    jne 2f
    mov rdi, r12
    lea rsi, [rip + .Lv_yes]
    call strcmp_eq
    test eax, eax
    jnz 8f
    mov rdi, r12
    lea rsi, [rip + .Lv_no]
    call strcmp_eq
    test eax, eax
    jnz 8f
    jmp 7f
2:  cmp eax, SDT_INT
    jne 3f
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call parse_int31
    test rdx, rdx
    jz 7f
    cmp eax, [rbx + SD_min]
    jge 21f
    mov eax, [rbx + SD_min]
21: cmp eax, [rbx + SD_max]
    jle 22f
    mov eax, [rbx + SD_max]
22: mov r13d, eax
    mov rdi, r12
    call mem_free
    lea rdi, [rip + reason_buf]
    mov esi, r13d
    call fmt_u64
    mov byte ptr [rdi], 0
    lea rdi, [rip + reason_buf]
    call dup_cstr
    mov r12, rax
    jmp 8f
3:  cmp eax, SDT_CHOICE
    jne 8f
    mov rdi, rbx
    mov rsi, r12
    call sdef_is_option
    test eax, eax
    jz 7f
8:  mov rdi, [rbx + SD_value]
    call mem_free
    mov [rbx + SD_value], r12
    EPILOGUE
7:  mov rdi, r12
    call mem_free
    EPILOGUE

# sdef_is_option(sd, cstr) -> 1 when the value is one of the choice's options
FN sdef_is_option
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + SD_opts]
    test r13, r13
    jz 8f
    mov rdi, r13
    call strlen
    mov r14, rax
1:  test r14, r14
    jz 8f
    mov rdi, r13
    mov rsi, r14
    call next_word
    add r13, rcx
    sub r14, rcx
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# sdef_is_default(sd) -> 1 when its value is its default
sdef_is_default:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + SD_value]
    mov rsi, [rbx + SD_default]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lempty]
1:  test rdi, rdi
    jnz 2f
    lea rdi, [rip + .Lempty]
2:  call strcmp_eq
    pop rbx
    ret

# sdefs_changed(ext) -> 1 when a setting differs from its default
sdefs_changed:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + EXT_sdefs + VEC_len]
    jae 8f
    imul rdi, r12, SD_SIZE
    add rdi, [rbx + EXT_sdefs + VEC_ptr]
    inc r12
    call sdef_is_default
    test eax, eax
    jnz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ext_setting_set(ext, sd, value cstr): the user changed it: kept, saved, and told to the program
FN ext_setting_set
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rdx
    call dup_cstr
    mov rdi, r12
    mov rsi, rax
    call sdef_take_value
    call ext_settings_save
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 9f
    mov rdi, rbx
    mov rsi, r12
    call extproto_send_setting
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# parse_setting(): one [settings] line of the manifest: KEY.FIELD = VALUE, FIELD one of type,
# default, title, description, min, max, options
parse_setting:
    PROLOGUE 16
    # the key up to the last dot
    mov rdi, [r12 + INI_key]
    mov rsi, [r12 + INI_keylen]
    mov rcx, rsi
1:  test rcx, rcx
    jz 9f                       # no field: ignored
    dec rcx
    cmp byte ptr [rdi + rcx], '.'
    jne 1b
    test rcx, rcx
    jz 9f
    mov [rsp], rcx              # the key's length
    lea rax, [rdi + rcx + 1]
    mov [rsp + 8], rax          # the field
    # the definition: found, or appended in manifest order
    mov rsi, rcx
    mov rdx, rbx
    call sdef_find
    test rax, rax
    jnz 2f
    lea rdi, [rbx + EXT_sdefs]
    mov esi, SD_SIZE
    call vec_push
    mov r13, rax
    mov rdi, [r12 + INI_key]
    mov rsi, [rsp]
    call mem_dup
    mov [r13 + SD_key], rax
    mov dword ptr [r13 + SD_max], 0x7fffffff
    mov rax, r13
2:  mov r13, rax
    mov r14, [rsp + 8]
    mov r15, [r12 + INI_key]
    add r15, [r12 + INI_keylen]
    sub r15, r14                # the field's length
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lsf_type]
    call str_eq_cstr
    test eax, eax
    jz 3f
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    lea rdx, [rip + .Lst_bool]
    call str_eq_cstr
    mov ecx, SDT_BOOL
    test eax, eax
    jnz 21f
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    lea rdx, [rip + .Lst_int]
    call str_eq_cstr
    mov ecx, SDT_INT
    test eax, eax
    jnz 21f
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    lea rdx, [rip + .Lst_choice]
    call str_eq_cstr
    mov ecx, SDT_CHOICE
    test eax, eax
    jnz 21f
    mov ecx, SDT_STRING
21: mov [r13 + SD_type], ecx
    jmp 9f
3:  lea r8, [r13 + SD_default]
    lea rdx, [rip + .Lsf_default]
    call field_cstr
    test eax, eax
    jnz 9f
    lea r8, [r13 + SD_title]
    lea rdx, [rip + .Lsf_title]
    call field_cstr
    test eax, eax
    jnz 9f
    lea r8, [r13 + SD_desc]
    lea rdx, [rip + .Lsf_desc]
    call field_cstr
    test eax, eax
    jnz 9f
    lea r8, [r13 + SD_opts]
    lea rdx, [rip + .Lsf_options]
    call field_cstr
    test eax, eax
    jnz 9f
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lsf_min]
    call str_eq_cstr
    test eax, eax
    jz 4f
    call val_int
    mov [r13 + SD_min], eax
    jmp 9f
4:  mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lsf_max]
    call str_eq_cstr
    test eax, eax
    jz 9f
    call val_int
    mov [r13 + SD_max], eax
9:  EPILOGUE

# field_cstr(field name in rdx, slot in r8) -> 1 when r14/r15 (the field) is that name: the value
# goes into the slot as an owned cstr
field_cstr:
    push rbx
    mov rbx, r8
    mov rdi, r14
    mov rsi, r15
    call str_eq_cstr
    test eax, eax
    jz 9f
    mov rdi, [rbx]
    call mem_free
    call val_dup
    mov [rbx], rax
    mov eax, 1
9:  pop rbx
    ret

# val_int() -> r12's value as a number (0 when it is not one)
val_int:
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    jmp parse_int31

# parse_int31(ptr, len) -> rax the number, at most 2147483647 (settings compare as 32-bit signed);
# rdx as parse_u64 leaves it
parse_int31:
    push rbx
    call parse_u64
    pop rbx
    mov ecx, 0x7fffffff
    cmp rax, rcx
    jbe 1f
    mov eax, ecx
1:  ret

# sdefs_init_values(ext): each default made to fit its type (a switch is yes or no, a number within
# its range, a choice one of its options, the first when the default is not), then the value
# starts at it
sdefs_init_values:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + EXT_sdefs + VEC_len]
    jae 9f
    imul r13, r12, SD_SIZE
    add r13, [rbx + EXT_sdefs + VEC_ptr]
    inc r12
    mov rdi, [r13 + SD_default]
    test rdi, rdi
    jnz 2f
    lea rdi, [rip + .Lempty]
2:  call dup_cstr
    mov r14, rax                # the default as given
    mov eax, [r13 + SD_type]
    cmp eax, SDT_BOOL
    jne 3f
    mov rdi, r14
    lea rsi, [rip + .Lv_yes]
    call strcmp_eq
    lea rdi, [rip + .Lv_yes]
    test eax, eax
    jnz 21f
    lea rdi, [rip + .Lv_no]
21: call replace_default
    jmp 8f
3:  cmp eax, SDT_INT
    jne 4f
    mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    call parse_int31
    cmp eax, [r13 + SD_min]
    jge 31f
    mov eax, [r13 + SD_min]
31: cmp eax, [r13 + SD_max]
    jle 32f
    mov eax, [r13 + SD_max]
32: lea rdi, [rip + reason_buf]
    mov esi, eax
    call fmt_u64
    mov byte ptr [rdi], 0
    lea rdi, [rip + reason_buf]
    call replace_default
    jmp 8f
4:  cmp eax, SDT_CHOICE
    jne 8f
    mov rdi, r13
    mov rsi, r14
    call sdef_is_option
    test eax, eax
    jnz 8f
    # the first option
    mov rdi, [r13 + SD_opts]
    test rdi, rdi
    jz 8f
    call strlen
    mov rdi, [r13 + SD_opts]
    mov rsi, rax
    call next_word
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rdi, r14
    mov r14, rax
    call mem_free
8:  # the normalized default, and the value
    mov rdi, [r13 + SD_default]
    call mem_free
    mov [r13 + SD_default], r14
    mov rdi, r14
    call dup_cstr
    mov [r13 + SD_value], rax
    jmp 1b
9:  EPILOGUE

# replace_default(cstr): r14 becomes an owned copy of it
replace_default:
    push rdi
    mov rdi, r14
    call mem_free
    pop rdi
    jmp dup_cstr_r14
dup_cstr_r14:
    push rbx
    call dup_cstr
    mov r14, rax
    pop rbx
    ret

# ---------------- discovery ----------------

# ext_init(): read every OWNER/NAME/extension.ini under the extensions folder
FN ext_init
    PROLOGUE
    lea rdi, [rip + ext_root]
    call sb_clear
    mov rax, [rip + g_ext_dir]
    test rax, rax
    jz 1f
.ifdef WINDOWS
    # a drive, UNC or relative --extensions DIR, made absolute with forward slashes
    mov rdi, rax
    call win_fullpath
    test rax, rax
    jz 11f
    mov [rip + g_ext_dir], rax
    jmp 11f
.endif
    # a relative --extensions DIR becomes absolute: the folder is the programs' working directory
    cmp byte ptr [rax], '/'
    je 11f
    lea rdi, [rip + ext_root]
    mov esi, 4096
    call sb_reserve
    mov rdi, rax
    mov esi, 4096
    SYS SYS_getcwd
    test rax, rax
    jle 11f
    dec rax                     # without the NUL
    add [rip + ext_root + SB_len], rax
    lea rdi, [rip + ext_root]
    mov esi, '/'
    call sb_push_byte
11: lea rdi, [rip + ext_root]
    mov rsi, [rip + g_ext_dir]
    call sb_push_cstr
    jmp 2f
1:  call config_dir
    lea rdi, [rip + ext_root]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + ext_root]
    lea rsi, [rip + .Lsub_extensions]
    call sb_push_cstr
2:  # the state folder for all extensions
    lea rdi, [rip + ext_state_root]
    call session_state_dir
    test eax, eax
    jnz 21f
    lea rdi, [rip + ext_state_root]
    lea rsi, [rip + .Lno_home_state]
    call sb_push_cstr
21: lea rdi, [rip + ext_state_root]
    lea rsi, [rip + .Lsub_extensions]
    call sb_push_cstr
    mov rdi, [rip + ext_state_root + SB_ptr]
    call mkdir_p
3:  # room for every record up front: an install appends, and EXT* are held elsewhere
    mov edi, EXT_SIZE * EXT_CAP
    call mem_alloc
    mov [rip + g_exts + VEC_ptr], rax
    mov qword ptr [rip + g_exts + VEC_cap], EXT_CAP
    mov rdi, [rip + ext_root + SB_ptr]
    lea rsi, [rip + owner_cb]
    xor edx, edx
    call dir_each
    mov rax, [rip + g_ext_cmds + VEC_len]
    mov [rip + ext_manifest_cmds], rax
    call ext_settings_load
    EPILOGUE

# owner_cb(ctx, name, is_dir): one owner folder
owner_cb:
    PROLOGUE
    test edx, edx
    jz 9f
    cmp byte ptr [rsi], '.'
    je 9f
    mov rdi, rsi
    call strlen
    mov rdi, rsi
    mov rsi, rax
    call mem_dup
    mov [rip + cur_owner], rax
    mov rdi, [rip + ext_root + SB_ptr]
    mov rsi, rax
    call path_join
    mov [rip + cur_owner_path], rax
    mov rdi, rax
    lea rsi, [rip + name_cb]
    xor edx, edx
    call dir_each
    mov rdi, [rip + cur_owner_path]
    call mem_free
    mov rdi, [rip + cur_owner]
    call mem_free
9:  EPILOGUE

# name_cb(ctx, name, is_dir): one extension folder
name_cb:
    PROLOGUE
    test edx, edx
    jz 9f
    cmp byte ptr [rsi], '.'
    je 9f
    mov rbx, rsi
    mov rdi, [rip + cur_owner_path]
    call path_join
    mov r12, rax
    mov rdi, rax
    mov rsi, [rip + cur_owner]
    mov rdx, rbx
    call ext_load
    mov rdi, r12
    call mem_free
9:  EPILOGUE

# ext_load(dir, owner, name) -> EXT*, or 0 when the table is full: an EXT from dir/extension.ini;
# a bad manifest leaves a failed EXT with its reason, so the Extensions page can show it
FN ext_load
    PROLOGUE 64
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    xor eax, eax
    cmp qword ptr [rip + g_exts + VEC_len], EXT_CAP
    jae .Lel_full                # the table never moves: past its size nothing more is read
    lea rdi, [rip + g_exts]
    mov esi, EXT_SIZE
    call vec_push
    mov rbx, rax
    mov [rip + cur_ext], rax
    mov dword ptr [rbx + EXT_in], -1
    mov dword ptr [rbx + EXT_out], -1
    mov dword ptr [rbx + EXT_log], -1
    mov qword ptr [rbx + EXT_active], -1
    mov eax, [rip + g_ext_cmds + VEC_len]
    mov [rbx + EXT_cmd0], eax
    mov rdi, [rsp]
    call dup_cstr
    mov [rbx + EXT_dir], rax
    mov rdi, [rsp + 8]
    call dup_cstr
    mov [rbx + EXT_owner], rax
    mov rdi, [rsp + 16]
    call dup_cstr
    mov [rbx + EXT_name], rax
    # the state folder: ROOT/OWNER--NAME
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rip + ext_state_root + SB_ptr]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_owner]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Ldashdash]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    mov rdi, [rip + tmp + SB_ptr]
    call dup_cstr
    mov [rbx + EXT_state], rax
    # the manifest
    mov rdi, [rsp]
    lea rsi, [rip + .Lmanifest]
    call path_join
    mov r12, rax
    mov rdi, rax
    call file_read_all
    mov r13, rax
    mov r14, rdx
    mov rdi, r12
    call mem_free
    test r13, r13
    jnz 1f
    lea rdi, [rip + .Lr_no_manifest]
    jmp .Lel_fail
1:  lea rdi, [rip + ini_it]
    mov rsi, r13
    mov rdx, r14
    call ini_init
2:  lea rdi, [rip + ini_it]
    call ini_next
    test eax, eax
    jz 3f
    lea rdi, [rip + ini_it]
    call manifest_kv
    jmp 2b
3:  mov rdi, r13
    call mem_free
    # A run-list token is a program name or path, never more than the path buffer can hold.
    mov r12, [rbx + EXT_runs]
    test r12, r12
    jz 301f
    mov rdi, r12
    call strlen
    mov r13, rax
300:test r13, r13
    jz 301f
    mov rdi, r12
    mov rsi, r13
    call next_word
    cmp rdx, 4096
    jae .Lel_runs_long
    add r12, rcx
    sub r13, rcx
    jmp 300b
301:
    mov rdi, rbx
    call sdefs_init_values
    # required keys; name and owner must be the folder names
    mov rdi, [rbx + EXT_mname]
    test rdi, rdi
    jz 31f
    mov rsi, [rbx + EXT_name]
    call strcmp_eq
    test eax, eax
    jnz 32f
31: lea rdi, [rip + .Lr_name]
    jmp .Lel_fail
32: mov rdi, [rbx + EXT_mowner]
    test rdi, rdi
    jz 33f
    mov rsi, [rbx + EXT_owner]
    call strcmp_eq
    test eax, eax
    jnz 34f
33: lea rdi, [rip + .Lr_owner]
    jmp .Lel_fail
34: cmp qword ptr [rbx + EXT_version], 0
    jne 35f
    lea rdi, [rip + .Lr_no_version]
    jmp .Lel_fail
35: cmp qword ptr [rbx + EXT_title], 0
    jne 4f
    lea rdi, [rip + .Lr_no_title]
    jmp .Lel_fail
4:  cmp dword ptr [rbx + EXT_hello], 1   # EXT_hello holds "protocol = N" while loading
    je 5f
    cmp dword ptr [rbx + EXT_hello], 0
    jne 41f
    lea rdi, [rip + .Lr_no_protocol]
    jmp .Lel_fail
41: lea rdi, [rip + .Lr_protocol]
    jmp .Lel_fail
5:  mov dword ptr [rbx + EXT_hello], 0
    cmp qword ptr [rbx + EXT_prog], 0
    jne 6f
    lea rdi, [rip + .Lr_no_program]
    jmp .Lel_fail
6:  # a script needs its runtime on PATH
    cmp qword ptr [rbx + EXT_script], 0
    je 7f
    mov rdi, [rbx + EXT_prog]
.ifdef WINDOWS
    call win_runtime
.else
    call proc_which
.endif
    test rax, rax
    jnz 61f
    lea rdi, [rip + .Lr_no_runtime]
    jmp .Lel_fail
61: mov rdi, [rbx + EXT_prog]
    push rax
    push rax
    call mem_free
    pop rax
    pop rax
    mov [rbx + EXT_prog], rax
    jmp 8f
7:  # the program must exist and be executable
    mov rdi, [rbx + EXT_prog]
    xor esi, esi
    SYS SYS_access
    test rax, rax
    jz 71f
    lea rdi, [rip + .Lr_no_file]
    jmp .Lel_fail
71: mov rdi, [rbx + EXT_prog]
    mov esi, 1                  # X_OK
    SYS SYS_access
    test rax, rax
    jz 8f
    lea rdi, [rip + .Lr_not_exec]
    jmp .Lel_fail
8:  mov dword ptr [rbx + EXT_manifest_ok], 1
    test dword ptr [rbx + EXT_on], -1
    jnz 81f
    mov dword ptr [rbx + EXT_on], ON_STARTUP | ON_COMMAND   # installed means running
81: # completion and signature help providers
    mov rdi, rbx
    mov rsi, [rbx + EXT_pv_complete]
    call provides_merge
    mov rdi, rbx
    mov rsi, [rbx + EXT_pv_signature]
    call provides_merge
    xor r12d, r12d
82: lea rax, [rip + pv_more]
    mov rcx, [rax + r12*8]
    test rcx, rcx
    jz 83f
    mov rdi, rbx
    mov rsi, [rbx + rcx]
    call provides_merge
    inc r12d
    jmp 82b
83: # its data files: themes and grammars
    mov rdi, [rbx + EXT_dir]
    lea rsi, [rip + .Lsub_themes]
    call path_join
    mov r12, rax
    mov rdi, rax
    call theme_add_dir
    mov rdi, r12
    call mem_free
    mov rdi, [rbx + EXT_dir]
    lea rsi, [rip + .Lsub_syntax]
    call path_join
    mov r12, rax
    mov rdi, rax
    call syntax_add_dir
    mov rdi, r12
    call mem_free
9:  mov qword ptr [rip + cur_ext], 0
    mov rax, rbx
    EPILOGUE
.Lel_runs_long:
    lea rdi, [rip + .Lr_runs_long]
.Lel_fail:
    mov [rbx + EXT_reason], rdi
    mov dword ptr [rbx + EXT_status], ES_FAILED
    mov qword ptr [rip + cur_ext], 0
    mov rax, rbx
    EPILOGUE
.Lel_full:
    xor eax, eax
    EPILOGUE

# manifest_kv(ini): one key = value of the manifest being loaded (cur_ext)
manifest_kv:
    PROLOGUE
    mov r12, rdi
    mov rbx, [rip + cur_ext]
    cmp qword ptr [r12 + INI_seclen], 0
    jne .Lmk_sections
    # top level
    mov rdi, r12
    lea rsi, [rip + .Lk_title]
    call ini_key_is
    test eax, eax
    jz 0f
    call val_dup
    mov [rbx + EXT_title], rax
    jmp 9f
0:  mov rdi, r12
    lea rsi, [rip + .Lk_description]
    call ini_key_is
    test eax, eax
    jz 1f
    call val_dup
    mov [rbx + EXT_desc], rax
    jmp 9f
1:  mov rdi, r12
    lea rsi, [rip + .Lk_icon]
    call ini_key_is
    test eax, eax
    jz 13f
    call val_dup
    mov [rbx + EXT_icon], rax
    jmp 9f
13: mov rdi, r12
    lea rsi, [rip + .Lk_color]
    call ini_key_is
    test eax, eax
    jz 14f
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    call parse_color
    test edx, edx
    jz 9f                       # not a color: the hashed one stays
    or eax, 0xff000000          # a badge is opaque
    mov [rbx + EXT_color], eax
    jmp 9f
14: mov rdi, r12
    lea rsi, [rip + .Lk_name]
    call ini_key_is
    test eax, eax
    jz 11f
    call val_dup
    mov [rbx + EXT_mname], rax
    jmp 9f
11: mov rdi, r12
    lea rsi, [rip + .Lk_owner]
    call ini_key_is
    test eax, eax
    jz 12f
    call val_dup
    mov [rbx + EXT_mowner], rax
    jmp 9f
12: mov rdi, r12
    lea rsi, [rip + .Lk_version]
    call ini_key_is
    test eax, eax
    jz 2f
    call val_dup
    mov [rbx + EXT_version], rax
    jmp 9f
2:  mov rdi, r12
    lea rsi, [rip + .Lk_protocol]
    call ini_key_is
    test eax, eax
    jz 3f
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    call parse_u64
    test rdx, rdx
    jz 21f
    test rax, rax
    jnz 22f
21: mov eax, 99                 # not a number: "protocol N not supported"
22: mov [rbx + EXT_hello], eax
    jmp 9f
3:  mov rdi, r12
    lea rsi, [rip + .Lk_run_target]
    call ini_key_is
    test eax, eax
    jz 4f
    cmp qword ptr [rbx + EXT_script], 0
    jne 9f                      # runtime + run already set
    mov rdi, [rbx + EXT_dir]
    call val_join
    mov [rbx + EXT_prog], rax
    jmp 9f
4:  mov rdi, r12
    lea rsi, [rip + .Lk_runtime]
    call ini_key_is
    test eax, eax
    jz 5f
    mov rdi, [rbx + EXT_prog]
    call mem_free
    call val_dup
    mov [rbx + EXT_prog], rax
    cmp qword ptr [rbx + EXT_script], 0
    jne 9f
    lea rax, [rip + .Lempty]
    mov [rbx + EXT_script], rax
    jmp 9f
5:  mov rdi, r12
    lea rsi, [rip + .Lk_run]
    call ini_key_is
    test eax, eax
    jz 6f
    mov rdi, [rbx + EXT_dir]
    call val_join
    mov [rbx + EXT_script], rax
    jmp 9f
6:  mov rdi, r12
    lea rsi, [rip + .Lk_args]
    call ini_key_is
    test eax, eax
    jz 7f
    call val_dup
    mov [rbx + EXT_args], rax
    jmp 9f
7:  mov rdi, r12
    lea rsi, [rip + .Lk_on]
    call ini_key_is
    test eax, eax
    jz 9f
    call parse_on
    jmp 9f
.Lmk_sections:
    mov rdi, r12
    lea rsi, [rip + .Ls_commands]
    call ini_sec_is
    test eax, eax
    jz 1f
    mov rdi, rbx
    mov rsi, r12
    call ext_cmd_add
    jmp 9f
1:  mov rdi, r12
    lea rsi, [rip + .Ls_subscribe]
    call ini_sec_is
    test eax, eax
    jz 2f
    call parse_subscribe
    jmp 9f
2:  mov rdi, r12
    lea rsi, [rip + .Ls_needs]
    call ini_sec_is
    test eax, eax
    jz 3f
    call parse_needs
    jmp 9f
3:  mov rdi, r12
    lea rsi, [rip + .Ls_settings]
    call ini_sec_is
    test eax, eax
    jz 4f
    call parse_setting
    jmp 9f
4:  mov rdi, r12
    lea rsi, [rip + .Ls_provides]
    call ini_sec_is
    test eax, eax
    jz 9f
    lea rdi, [rip + pv_keys]
    call parse_keyed
9:  EPILOGUE

# val_dup() -> a copy of r12's value as a cstr
val_dup:
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    jmp mem_dup

# val_join(dir) -> dir joined with r12's value (relative paths are inside the extension folder)
val_join:
    push rbx
    push rbx
    mov rbx, rdi
    mov rax, [r12 + INI_val]
    cmp byte ptr [rax], '/'
    jne 1f
    call val_dup
    pop rbx
    pop rbx
    ret
1:  call val_dup
    mov rdi, rbx
    mov rsi, rax
    push rax
    push rax
    call path_join
    pop rdi
    pop rdi
    push rax
    push rax
    call mem_free
    pop rax
    pop rax
    pop rbx
    pop rbx
    ret

# parse_on(): on = startup command lang:X open:GLOB project
parse_on:
    PROLOGUE
    mov r13, [r12 + INI_val]
    mov r14, [r12 + INI_vallen]
1:  test r14, r14
    jz 9f
    mov rdi, r13
    mov rsi, r14
    call next_word
    add r13, rcx
    sub r14, rcx
    test rdx, rdx
    jz 9f
    mov r15, rax
    mov rdi, rax
    mov rsi, rdx
    push rdx
    push rdx
    lea rdx, [rip + .Lo_startup]
    call str_eq_cstr
    pop rdx
    pop rdx
    test eax, eax
    jz 2f
    or dword ptr [rbx + EXT_on], ON_STARTUP
    jmp 1b
2:  mov rdi, r15
    mov rsi, rdx
    push rdx
    push rdx
    lea rdx, [rip + .Lo_command]
    call str_eq_cstr
    pop rdx
    pop rdx
    test eax, eax
    jz 3f
    or dword ptr [rbx + EXT_on], ON_COMMAND
    jmp 1b
3:  mov rdi, r15
    mov rsi, rdx
    push rdx
    push rdx
    lea rdx, [rip + .Lo_project]
    call str_eq_cstr
    pop rdx
    pop rdx
    test eax, eax
    jz 4f
    or dword ptr [rbx + EXT_on], ON_PROJECT
    jmp 1b
4:  # lang:X and open:GLOB collect into space separated lists
    cmp rdx, 5
    jbe 1b
    mov rdi, r15
    mov rsi, rdx
    push rdx
    push rdx
    lea rdx, [rip + .Lo_lang]
    mov ecx, 5
    call str_starts
    pop rdx
    pop rdx
    test eax, eax
    jz 5f
    or dword ptr [rbx + EXT_on], ON_LANG
    lea rdi, [rbx + EXT_on_langs]
    lea rsi, [r15 + 5]
    sub rdx, 5
    call list_append
    jmp 1b
5:  mov rdi, r15
    mov rsi, rdx
    push rdx
    push rdx
    lea rdx, [rip + .Lo_open]
    mov ecx, 5
    call str_starts
    pop rdx
    pop rdx
    test eax, eax
    jz 1b
    or dword ptr [rbx + EXT_on], ON_OPEN
    lea rdi, [rbx + EXT_on_globs]
    lea rsi, [r15 + 5]
    sub rdx, 5
    call list_append
    jmp 1b
9:  EPILOGUE

# list_append(slot*, ptr, len): "a b" lists kept as owned cstrs
list_append:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + tmp]
    call sb_clear
    mov rsi, [rbx]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + tmp]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, ' '
    call sb_push_byte
1:  lea rdi, [rip + tmp]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, [rbx]
    call mem_free
    mov rdi, [rip + tmp + SB_ptr]
    call dup_cstr
    mov [rbx], rax
    EPILOGUE

# parse_subscribe(): event = patterns ("no" leaves it unsubscribed)
parse_subscribe:
    PROLOGUE
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    lea rdx, [rip + .Lno]
    call str_eq_cstr
    test eax, eax
    jnz 9f
    lea r13, [rip + sub_keys]
    xor r14d, r14d
1:  mov rsi, [r13 + r14*8]
    test rsi, rsi
    jz 9f
    mov rdi, r12
    call ini_key_is
    test eax, eax
    jnz 2f
    add r14, 2
    jmp 1b
2:  mov rcx, [r13 + r14*8 + 8]
    lea r15, [rbx + rcx]
    mov rdi, [r15]
    call mem_free
    call val_dup
    mov [r15], rax
9:  EPILOGUE

# parse_keyed(table): a key = value of the table's ("key", EXT offset, ..., 0) as an owned cstr
parse_keyed:
    PROLOGUE
    mov r13, rdi
    xor r14d, r14d
1:  mov rsi, [r13 + r14*8]
    test rsi, rsi
    jz 9f
    mov rdi, r12
    call ini_key_is
    test eax, eax
    jnz 2f
    add r14, 2
    jmp 1b
2:  mov rcx, [r13 + r14*8 + 8]
    lea r15, [rbx + rcx]
    mov rdi, [r15]
    call mem_free
    call val_dup
    mov [r15], rax
9:  EPILOGUE

# provides_merge(ext, patterns): a provider hears opened and edits for the files it provides for,
# and the first of them to open starts it (section 12b)
provides_merge:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 9f
    mov rdi, r12
    call strlen
    mov r13, rax
    lea rdi, [rbx + EXT_sub_opened]
    call merge_into
    lea rdi, [rbx + EXT_sub_edits]
    call merge_into
    lea rdi, [rbx + EXT_on_globs]
    call merge_into
    or dword ptr [rbx + EXT_on], ON_OPEN
9:  EPILOGUE

# merge_into(slot*): r12 (r13 bytes) appended to the list, unless the list is "*" (all already)
merge_into:
    mov rax, [rdi]
    test rax, rax
    jz 1f
    cmp byte ptr [rax], '*'
    jne 1f
    cmp byte ptr [rax + 1], 0
    je 9f
1:  push rbx
    mov rsi, r12
    mov rdx, r13
    call list_append
    pop rbx
9:  ret

# parse_needs(): the [needs] block into NEEDS_* bits
parse_needs:
    PROLOGUE
    mov rdi, r12
    lea rsi, [rip + .Ln_documents]
    call ini_key_is
    test eax, eax
    jz 1f
    mov edi, NEEDS_DOC_READ
    mov esi, NEEDS_DOC_WRITE
    call needs_level
    jmp 9f
1:  mov rdi, r12
    lea rsi, [rip + .Ln_project]
    call ini_key_is
    test eax, eax
    jz 2f
    mov edi, NEEDS_PROJECT_READ
    mov esi, NEEDS_PROJECT_WRITE
    call needs_level
    jmp 9f
2:  mov rdi, r12
    lea rsi, [rip + .Ln_home]
    call ini_key_is
    test eax, eax
    jz 3f
    mov edi, NEEDS_HOME_READ
    xor esi, esi
    call needs_level
    jmp 9f
3:  mov rdi, r12
    lea rsi, [rip + .Ln_network]
    call ini_key_is
    test eax, eax
    jz 4f
    mov edi, NEEDS_NETWORK
    call needs_yes
    jmp 9f
4:  mov rdi, r12
    lea rsi, [rip + .Ln_terminal]
    call ini_key_is
    test eax, eax
    jz 5f
    mov edi, NEEDS_TERMINAL
    call needs_yes
    jmp 9f
5:  mov rdi, r12
    lea rsi, [rip + .Ln_run]
    call ini_key_is
    test eax, eax
    jz 9f
    call val_dup
    mov [rbx + EXT_runs], rax
9:  EPILOGUE

# needs_level(read bit, write bit): the value is none, read or write
needs_level:
    PROLOGUE
    mov r13d, edi
    mov r14d, esi
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    lea rdx, [rip + .Lread]
    call str_eq_cstr
    test eax, eax
    jz 1f
    or [rbx + EXT_needs], r13d
    jmp 9f
1:  mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    lea rdx, [rip + .Lwrite]
    call str_eq_cstr
    test eax, eax
    jz 9f
    test r14d, r14d
    jz 9f
    or [rbx + EXT_needs], r13d
    or [rbx + EXT_needs], r14d
9:  EPILOGUE

# needs_yes(bit): the value is yes or no
needs_yes:
    PROLOGUE
    mov r13d, edi
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    lea rdx, [rip + .Lyes]
    call str_eq_cstr
    test eax, eax
    jz 9f
    or [rbx + EXT_needs], r13d
9:  EPILOGUE

# dup_cstr(cstr) -> owned copy
FN dup_cstr
    push rdi
    call strlen
    pop rdi
    mov rsi, rax
    jmp mem_dup

# ---------------- commands ----------------

# ext_cmd_add(ext, ini): "key = Title | keys" under [commands] becomes a palette command
# NAME.key titled "Title (Extension)"
FN ext_cmd_add
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    # name: NAME.key
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, '.'
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, [r12 + INI_key]
    mov rdx, [r12 + INI_keylen]
    call sb_push
    mov rdi, [rip + tmp + SB_ptr]
    call dup_cstr
    mov r13, rax                # name
    # title and keys: split the value at '|'
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    lea rdx, [rip + .Lbar]
    mov ecx, 1
    call str_find
    mov r14, rax                # index of '|' or -1
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    test rax, rax
    js 1f
    mov rsi, rax
1:  call trim
    mov [rsp], rax
    mov [rsp + 8], rdx          # title ptr, len
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lparen]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_title]
    test rsi, rsi
    jnz 2f
    mov rsi, [rbx + EXT_name]
2:  call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, ')'
    call sb_push_byte
    mov rdi, [rip + tmp + SB_ptr]
    call dup_cstr
    mov r15, rax                # title
    lea rax, [rip + .Lempty]
    test r14, r14
    js 3f
    mov rdi, [r12 + INI_val]
    lea rdi, [rdi + r14 + 1]
    mov rsi, [r12 + INI_vallen]
    sub rsi, r14
    dec rsi
    call trim
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
3:  mov r14, rax                # keys
    lea rdi, [rip + g_ext_cmds]
    mov esi, CMD_SIZE
    call vec_push
    mov [rax + CMD_name], r13
    mov [rax + CMD_title], r15
    lea rcx, [rip + ext_cmd_run]
    mov [rax + CMD_fn], rcx
    mov [rax + CMD_keys], r14
    inc dword ptr [rbx + EXT_ncmd]
    lea rdi, [rip + g_ext_owner]
    mov esi, 8
    call vec_push
    mov rcx, rbx
    lea rdx, [rip + g_exts]
    sub rcx, [rdx + VEC_ptr]
    xor edx, edx
    push rax
    mov rax, rcx
    mov ecx, EXT_SIZE
    div rcx
    mov rcx, rax
    pop rax
    mov [rax], rcx
    EPILOGUE

# ext_cmd_run(cmd*): a manifest command was invoked: tell the extension, starting it first
FN ext_cmd_run
    PROLOGUE
    mov rax, rdi
    lea rcx, [rip + g_ext_cmds]
    sub rax, [rcx + VEC_ptr]
    xor edx, edx
    mov ecx, CMD_SIZE
    div rcx
    mov r12, rax                # command index
    cmp r12, [rip + g_ext_cmds + VEC_len]
    jae 9f
    mov rax, [rip + g_ext_owner + VEC_ptr]
    mov rax, [rax + r12*8]
    imul rax, rax, EXT_SIZE
    add rax, [rip + g_exts + VEC_ptr]
    mov rbx, rax
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 9f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 1f
    mov rdi, rbx
    mov rsi, r12
    call extproto_send_run
    EPILOGUE
1:  # it cannot run now: say why, and keep nothing for later (turning it on must not run an old
    # command)
    cmp dword ptr [rbx + EXT_status], ES_FAILED
    je 8f
    cmp dword ptr [rbx + EXT_status], ES_DISABLED
    je 7f
    cmp dword ptr [rbx + EXT_status], ES_STOPPED
    je 8f                       # by the user or a limit: its page starts it again
    lea rax, [r12 + 1]
    mov [rbx + EXT_pending], rax
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    je 9f
    cmp dword ptr [rbx + EXT_status], ES_STOPPING
    je 9f
    mov rdi, rbx
    call ext_start
9:  EPILOGUE
8:  mov rdi, [rbx + EXT_reason]
    test rdi, rdi
    jnz 6f
7:  # "Title is turned off" (or stopped without a reason)
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_title]
    test rsi, rsi
    jnz 5f
    mov rsi, [rbx + EXT_name]
5:  call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lr_off_cmd]
    cmp dword ptr [rbx + EXT_status], ES_DISABLED
    je 4f
    lea rsi, [rip + .Lr_stopped_cmd]
4:  call sb_push_cstr
    lea rdi, [rip + tmp]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + tmp + SB_ptr]
6:  call app_toast
    EPILOGUE

# ext_cmd_live(index) -> 1 when the g_ext_cmds entry belongs to an extension that is not removed
FN ext_cmd_live
    mov rax, [rip + g_ext_owner + VEC_ptr]
    mov rax, [rax + rdi*8]
    imul rax, rax, EXT_SIZE
    add rax, [rip + g_exts + VEC_ptr]
    xor ecx, ecx
    cmp dword ptr [rax + EXT_status], ES_REMOVED
    setne cl
    mov eax, ecx
    ret

# ext_cmd_find(ptr, len) -> CMD* or 0, among the extensions' commands
FN ext_cmd_find
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, [rip + g_ext_cmds + VEC_len]
    jae 8f
    imul rax, rbx, CMD_SIZE
    add rax, [rip + g_ext_cmds + VEC_ptr]
    mov r14, rax
    mov rdi, rbx
    call ext_cmd_live
    inc rbx
    test eax, eax
    jz 1b
    dec rbx
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r14 + CMD_name]
    call str_eq_cstr
    test eax, eax
    jnz 9f
    inc rbx
    jmp 1b
8:  xor r14d, r14d
9:  mov rax, r14
    EPILOGUE

# ---------------- processes ----------------

# ext_running() -> how many are running or starting
FN ext_running
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, [rip + g_exts + VEC_len]
    jae 9f
    imul rdx, rcx, EXT_SIZE
    add rdx, [rip + g_exts + VEC_ptr]
    cmp dword ptr [rdx + EXT_status], ES_STARTING
    je 2f
    cmp dword ptr [rdx + EXT_status], ES_RUNNING
    je 2f
    cmp dword ptr [rdx + EXT_status], ES_STOPPING
    jne 3f
2:  inc eax
3:  inc rcx
    jmp 1b
9:  ret

# ext_start(ext): the program, with pipes on its input and output and the log on its errors
FN ext_start
    PROLOGUE 32
    mov rbx, rdi
    cmp dword ptr [rbx + EXT_manifest_ok], 0
    je 9f
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    je 9f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    je 9f
    cmp dword ptr [rbx + EXT_status], ES_STOPPING
    je 9f
    cmp dword ptr [rbx + EXT_status], ES_FAILED
    je 9f
    cmp dword ptr [rbx + EXT_disabled], 0
    jne 9f
    cmp dword ptr [rbx + EXT_status], ES_DISABLED
    je 9f
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 9f
    call ext_running
    cmp eax, EXT_MAX_RUNNING
    jb 1f
    lea rax, [rip + .Lr_slots]
    mov [rbx + EXT_reason], rax
    mov dword ptr [rbx + EXT_wait_slot], 1
    mov dword ptr [rbx + EXT_status], ES_IDLE
    jmp 9f
1:  mov dword ptr [rbx + EXT_wait_slot], 0
    mov qword ptr [rbx + EXT_reason], 0
    mov qword ptr [rbx + EXT_status_text], 0
    mov dword ptr [rbx + EXT_hello], 0
    mov dword ptr [rbx + EXT_syntax_errs], 0
    mov dword ptr [rbx + EXT_features], 0
    mov dword ptr [rbx + EXT_flood], 0
    mov dword ptr [rbx + EXT_throttled], 0
    mov dword ptr [rbx + EXT_win_hit], 0
    mov qword ptr [rbx + EXT_win_t0], 0
    mov qword ptr [rbx + EXT_win_msgs], 0
    mov qword ptr [rbx + EXT_fbytes], 0
    mov qword ptr [rbx + EXT_full_since], 0
    mov qword ptr [rbx + EXT_in_closed_at], 0
    mov qword ptr [rbx + EXT_body], 0
    mov qword ptr [rbx + EXT_wq_off], 0
    mov qword ptr [rbx + EXT_active], -1
    mov qword ptr [rbx + EXT_known + VEC_len], 0
    lea rdi, [rbx + EXT_rbuf]
    call sb_clear
    lea rdi, [rbx + EXT_wq]
    call sb_clear
    # the state folder and its tmp
    mov rdi, [rbx + EXT_state]
    call mkdir_p
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_state]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lsub_tmp]
    call sb_push_cstr
    mov rdi, [rip + tmp + SB_ptr]
    call mkdir_p
    # the log: ROOT/OWNER--NAME.log, appended
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_state]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lsuf_log]
    call sb_push_cstr
    mov rdi, [rip + tmp + SB_ptr]
    mov esi, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC
    mov edx, 0644
    SYS SYS_open
    mov [rbx + EXT_log], eax
    # pipes
    lea rdi, [rip + pipe_in]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Les_fail
    lea rdi, [rip + pipe_out]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Les_fail2
    mov rdi, rbx
    # confinement (confine.s): prepared here, applied in the child
    mov dword ptr [rbx + EXT_confined], CONFINED_NO
.ifdef WINDOWS
    lea rax, [rip + .Lr_windows]    # nothing holds it there yet: it runs, and its page says so
    mov [rbx + EXT_confine_why], rax
    jmp .Les_spawn
.endif
    cmp dword ptr [rbx + EXT_noconfine], 0
    jne .Les_spawn              # the child could not confine itself before: the reason stays
    mov qword ptr [rbx + EXT_confine_why], 0
    mov rdi, rbx
    call confine_prepare
    test rax, rax
    jz .Les_spawn
    # this system cannot hold it to its permissions: it runs, and its page says so
    mov [rbx + EXT_confine_why], rax
    jmp .Les_spawn
.Les_unconfined_fail:
    lea rdi, [rip + reason_buf]
    lea rsi, [rip + .Lr_not_confined]
    call cstr_copy
    mov r12, rax
    call confine_reason
    mov rdi, r12
    mov rsi, rax
    call cstr_copy
    lea rdi, [rip + reason_buf]
    call dup_cstr
    mov [rbx + EXT_reason], rax
    mov dword ptr [rbx + EXT_status], ES_FAILED
    mov edi, [rbx + EXT_log]
    SYS SYS_close
    mov dword ptr [rbx + EXT_log], -1
    mov edi, [rip + pipe_in]
    SYS SYS_close
    mov edi, [rip + pipe_in + 4]
    SYS SYS_close
    mov edi, [rip + pipe_out]
    SYS SYS_close
    mov edi, [rip + pipe_out + 4]
    SYS SYS_close
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
.Les_spawn:
    mov rdi, rbx
    call build_argv
    mov rdi, rbx
    call build_env
    mov rdi, [rip + argv_vec + VEC_ptr]
    mov rsi, [rip + env_vec + VEC_ptr]
    mov rdx, [rbx + EXT_dir]
    mov ecx, [rip + pipe_in]            # child reads here
    mov r8d, [rip + pipe_out + 4]       # child writes here
    mov r9d, [rbx + EXT_log]
    test r9d, r9d
    jns 2f
    lea rdi, [rip + .Ldevnull]
    mov esi, O_WRONLY | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    mov [rbx + EXT_log], eax
    mov r9d, eax
2:  mov eax, 2                          # own session, dies with rhun
    push rax
    push rax
    call proc_spawn
    mov r12, rax
.ifndef WINDOWS
    call confine_release
.endif
    mov rax, r12
    add rsp, 16
    mov r12, rax
    mov edi, [rip + pipe_in]
    SYS SYS_close
    mov edi, [rip + pipe_out + 4]
    SYS SYS_close
    test r12, r12
    jns 3f
    mov edi, [rip + pipe_in + 4]
    SYS SYS_close
    mov edi, [rip + pipe_out]
    SYS SYS_close
.ifdef WINDOWS
    lea rdi, [rip + .Lr_exec]   # CreateProcess itself refuses a file that is not a program
.else
    lea rdi, [rip + .Lr_spawn]
.endif
    jmp .Les_failed
3:  mov [rbx + EXT_pid], r12d
    mov eax, [rip + pipe_in + 4]
    mov [rbx + EXT_in], eax
    mov eax, [rip + pipe_out]
    mov [rbx + EXT_out], eax
    mov edi, eax
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov edi, [rbx + EXT_in]
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov edi, [rbx + EXT_out]
    mov esi, POLLIN
    lea rdx, [rip + ext_on_out]
    mov rcx, rbx
    call watch_add
    mov edi, [rbx + EXT_in]
    xor esi, esi                        # POLLOUT only while the queue has bytes
    lea rdx, [rip + ext_on_in]
    mov rcx, rbx
    call watch_add
    call time_ms
    mov [rbx + EXT_started], rax
    mov dword ptr [rbx + EXT_status], ES_STARTING
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE
.Les_fail2:
    mov edi, [rip + pipe_in]
    SYS SYS_close
    mov edi, [rip + pipe_in + 4]
    SYS SYS_close
.Les_fail:
    lea rdi, [rip + .Lr_pipes]
.Les_failed:
    mov [rbx + EXT_reason], rdi
    mov dword ptr [rbx + EXT_status], ES_FAILED
    mov edi, [rbx + EXT_log]
    test edi, edi
    js 91f
    SYS SYS_close
    mov dword ptr [rbx + EXT_log], -1
91: mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# build_argv(ext): argv_vec = program [script] args..., 0
build_argv:
    PROLOGUE
    mov rbx, rdi
    mov qword ptr [rip + argv_vec + VEC_len], 0
    lea rdi, [rip + argv_vec]
    mov esi, 8
    call vec_push
    mov rcx, [rbx + EXT_prog]
    mov [rax], rcx
    mov rax, [rbx + EXT_script]
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 0
    je 1f
    lea rdi, [rip + argv_vec]
    mov esi, 8
    call vec_push
    mov rcx, [rbx + EXT_script]
    mov [rax], rcx
1:  mov r12, [rbx + EXT_args]
    test r12, r12
    jz 8f
    mov rdi, r12
    call strlen
    mov r13, rax
2:  test r13, r13
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup                # leaked on purpose: argv strings live as long as the process
    mov r14, rax
    lea rdi, [rip + argv_vec]
    mov esi, 8
    call vec_push
    mov [rax], r14
    jmp 2b
8:  lea rdi, [rip + argv_vec]
    mov esi, 8
    call vec_push
    EPILOGUE

# build_env(ext): env_vec, the environment of section 4 of the spec. In a --extensions session the
# extension inherits rhun's environment as well (tests pass their settings that way).
build_env:
    PROLOGUE
    mov rbx, rdi
    mov [rip + cur_start], rbx
    mov qword ptr [rip + env_vec + VEC_len], 0
    cmp qword ptr [rip + g_ext_dir], 0
    je 1f
    # rhun's environment first; the entries below override by coming later (execve takes the
    # first match in most libcs, so inherited duplicates of these names are skipped)
    mov r12, [rip + g_envp]
2:  mov rdi, [r12]
    test rdi, rdi
    jz 1f
    call env_is_ours
    test eax, eax
    jnz 3f
    lea rdi, [rip + env_vec]
    mov esi, 8
    call vec_push
    mov rcx, [r12]
    mov [rax], rcx
3:  add r12, 8
    jmp 2b
1:  lea rdi, [rip + .Le_path]
    call getenv
    test rax, rax
    jz 4f
    lea rdi, [rip + .Le_path_eq]
    mov rsi, rax
    call env_add
4:  lea rdi, [rip + .Le_home_eq]
    mov rsi, [rbx + EXT_state]
    call env_add
    lea rdi, [rip + .Le_tmpdir_eq]
    lea rsi, [rip + .Lsub_tmp]
    call env_add_state
    lea rdi, [rip + .Le_cache_eq]
    lea rsi, [rip + .Lsub_cache]
    call env_add_state
    lea rdi, [rip + .Le_gocache_eq]
    lea rsi, [rip + .Lsub_gocache]
    call env_add_state
    lea rdi, [rip + .Le_gomod_eq]
    lea rsi, [rip + .Lsub_gomod]
    call env_add_state
    lea rdi, [rip + .Le_gopath_eq]
    lea rsi, [rip + .Lsub_gopath]
    call env_add_state
    lea rdi, [rip + .Le_npm_eq]
    lea rsi, [rip + .Lsub_npm]
    call env_add_state
    lea rdi, [rip + .Le_lang]
    lea rsi, [rip + .Le_lang_eq]
    call env_copy
    lea rdi, [rip + .Le_lc_all]
    lea rsi, [rip + .Le_lc_all_eq]
    call env_copy
    lea rdi, [rip + .Le_tz]
    lea rsi, [rip + .Le_tz_eq]
    call env_copy
.ifdef MACOS
    # Xcode's /usr/bin shims: xcrun's cache private to the extension (the user's shared cache is
    # not writable from the sandbox: an entry it wrote would run unconfined later), and the Xcode
    # the sandbox profile allowed
    mov rdi, [rbx + EXT_state]
    lea rsi, [rip + .Lsub_xcrun_db]
    call path_join
    mov r12, rax
    lea rdi, [rip + .Le_xcrun_db_eq]
    mov rsi, rax
    call env_add
    mov rdi, r12
    call mem_free
    lea rdi, [rip + .Le_devdir]
    lea rsi, [rip + .Le_devdir_eq]
    call env_copy
.endif
.ifdef WINDOWS
    # what Windows programs need to start at all (Winsock fails without SYSTEMROOT), and their
    # home, temporary and application data folders in the state folder
    lea r12, [rip + win_env_copy]
6:  mov rdi, [r12]
    test rdi, rdi
    jz 7f
    mov rsi, [r12 + 8]
    call env_copy
    add r12, 16
    jmp 6b
7:  lea rdi, [rip + .Le_temp_eq]
    lea rsi, [rip + .Lsub_tmp]
    call env_add_state
    lea rdi, [rip + .Le_tmp_eq]
    lea rsi, [rip + .Lsub_tmp]
    call env_add_state
    lea rdi, [rip + .Le_userprofile_eq]
    mov rsi, [rbx + EXT_state]
    call env_add
    lea rdi, [rip + .Le_appdata_eq]
    lea rsi, [rip + .Lsub_roaming]
    call env_add_state
    lea rdi, [rip + .Le_localappdata_eq]
    lea rsi, [rip + .Lsub_local]
    call env_add_state
.endif
    lea rdi, [rip + .Le_version_eq]
    lea rsi, [rip + rhun_version]
    call env_add
    lea rdi, [rip + .Le_protocol_eq]
    lea rsi, [rip + .Lone]
    call env_add
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_owner]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    lea rdi, [rip + .Le_extension_eq]
    mov rsi, [rip + tmp + SB_ptr]
    call env_add
    lea rdi, [rip + .Le_target_eq]
    lea rsi, [rip + ext_target]
    call env_add
    lea rdi, [rip + .Le_state_eq]
    mov rsi, [rbx + EXT_state]
    call env_add
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 5f
    lea rdi, [rip + .Le_project_eq]
    call env_add
5:  cmp qword ptr [rip + g_ext_dir], 0
    je 51f
    mov rsi, [rip + g_control_path]
    test rsi, rsi
    jz 51f
    lea rdi, [rip + .Le_socket_eq]
    call env_add
51: lea rdi, [rip + env_vec]
    mov esi, 8
    call vec_push
    EPILOGUE

# env_is_ours(entry) -> 1 when the entry's name is one build_env sets itself (or starts with RHUN_)
env_is_ours:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rip + env_names]
1:  mov r13, [r12]
    test r13, r13
    jz 8f
    mov rdi, r13
    call strlen
    mov r14, rax
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jz 2f
    cmp byte ptr [rbx + r14], '='
    je 9f
    cmp byte ptr [r13 + r14 - 1], '_'   # a prefix entry (RHUN_) matches without the =
    je 9f
2:  add r12, 8
    jmp 1b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# env_add(prefix "NAME=", value cstr): one entry
env_add:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + tmp2]
    call sb_clear
    lea rdi, [rip + tmp2]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + tmp2]
    mov rsi, r12
    call sb_push_cstr
    mov rdi, [rip + tmp2 + SB_ptr]
    call dup_cstr                # lives as long as the process; freed with the next start's vec? no: leaked
    mov r13, rax
    lea rdi, [rip + env_vec]
    mov esi, 8
    call vec_push
    mov [rax], r13
    EPILOGUE

# env_add_state(prefix, suffix): NAME=STATE/suffix, the folder created
env_add_state:
    PROLOGUE
    mov r13, rdi
    mov r14, rsi
    mov rbx, [rip + cur_start]
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_state]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, r14
    call sb_push_cstr
    mov rdi, [rip + tmp + SB_ptr]
    call mkdir_p
    mov rdi, r13
    mov rsi, [rip + tmp + SB_ptr]
    call env_add
    EPILOGUE

.ifdef WINDOWS
# win_runtime(name) -> path or 0: proc_which, except that python3 is also looked for as python and
# py (Windows installs Python as python.exe and the py launcher), and the Microsoft Store's stubs in
# WindowsApps (which only offer to install Python) are taken only when nothing else is there
win_runtime:
    PROLOGUE
    mov r12, rdi
    lea rsi, [rip + .Lpython3]
    call strcmp_eq
    test eax, eax
    jnz 1f
    mov rdi, r12
    call proc_which
    EPILOGUE
1:  xor r13d, r13d              # a stub, kept in case nothing else is found
    lea r14, [rip + .Lpython3]
    call 2f
    lea r14, [rip + .Lpython]
    call 2f
    lea r14, [rip + .Lpy]
    call 2f
    mov rax, r13
    EPILOGUE
2:  # one candidate: a real one ends the search (returns from win_runtime), a stub is kept
    push rbx
    mov rdi, r14
    call proc_which
    test rax, rax
    jz 4f
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lwinapps]
    mov ecx, 13
    call str_find
    test rax, rax
    js 3f
    test r13, r13
    jnz 31f
    mov r13, rbx
    jmp 4f
31: mov rdi, rbx
    call mem_free
4:  pop rbx
    ret
3:  # a real runtime: drop a kept stub, leave both helper and win_runtime with it
    mov rdi, r13
    call mem_free
    mov rax, rbx
    pop rbx
    add rsp, 8                  # the return address of "call 2f"
    EPILOGUE
.endif

# env_copy(name, prefix): rhun's NAME, when set
env_copy:
    PROLOGUE
    mov r12, rsi
    call getenv
    test rax, rax
    jz 9f
    mov rdi, r12
    mov rsi, rax
    call env_add
9:  EPILOGUE

# ext_on_out(fd, revents, ctx = EXT*): bytes from the program. Each extension has a window of
# EXT_WIN_MS with caps on messages and bytes (extproto_pump enforces them); when a cap is hit the
# rest waits in the buffer for the next window, and ext_tick resumes it.
ext_on_out:
    PROLOGUE
    mov rbx, rdx
    # a program that is not reading what rhun wrote gets nothing more read from it either, and
    # the not-reading clock runs
    mov rax, [rbx + EXT_wq + SB_len]
    sub rax, [rbx + EXT_wq_off]
    cmp rax, EXT_WQ_MAX
    jb 1f
    cmp qword ptr [rbx + EXT_full_since], 0
    jne .Loo_throttle
    call time_ms
    mov [rbx + EXT_full_since], rax
    jmp .Loo_throttle
1:  lea rdi, [rbx + EXT_rbuf]
    mov esi, EXT_READ_CHUNK
    call sb_reserve
    mov rsi, rax
    mov edi, [rbx + EXT_out]
    mov edx, EXT_READ_CHUNK
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle .Loo_eof
    add [rbx + EXT_rbuf + SB_len], rax
    mov rdi, rbx
    call extproto_pump
    # 64 KB without a line end: the program is not speaking the protocol
    cmp qword ptr [rbx + EXT_rbuf + SB_len], EXT_LINE_MAX
    jb 2f
    cmp qword ptr [rbx + EXT_body], 0
    jne 2f
    mov rdi, [rbx + EXT_rbuf + SB_ptr]
    mov esi, EXT_LINE_MAX
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    test rax, rax
    jns 2f
    mov rdi, rbx
    lea rsi, [rip + .Lr_line]
    call ext_kill
    jmp 9f
2:  cmp dword ptr [rbx + EXT_throttled], 0
    je 9f
.Loo_throttle:
    # the rest waits for the next window
    mov dword ptr [rbx + EXT_throttled], 1
    mov edi, [rbx + EXT_out]
    xor esi, esi
    call watch_set_events
9:  EPILOGUE
.Loo_eof:
    # the program closed its output (or died): a program that stops talking is gone to us
    mov rdi, rbx
    xor esi, esi
    call ext_exited
    EPILOGUE

# ext_on_in(fd, revents, ctx = EXT*): the program reads again
ext_on_in:
    test esi, POLLERR | POLLHUP
    jz 1f
    # the program closed its input (or exited: its output's end of file follows, and that exit
    # status is the reason to keep); ext_tick ends it after 300 ms if it is still there
    push rbx
    mov rbx, rdx
    cmp qword ptr [rbx + EXT_in_closed_at], 0
    jne 2f
    call time_ms
    mov [rbx + EXT_in_closed_at], rax
2:  mov edi, [rbx + EXT_in]
    xor esi, esi
    call watch_set_events
    pop rbx
    ret
1:  mov rdi, rdx
    jmp ext_flush

# ext_send(ext, ptr, len): queue bytes for the program and write what the pipe takes
FN ext_send
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_STOPPING
    jne 9f
1:  mov rax, [rbx + EXT_wq + SB_len]
    sub rax, [rbx + EXT_wq_off]
    add rax, rdx
    cmp rax, EXT_WQ_HARD
    jb 2f
    # a program that let 8 MB pile up is not reading: ext_tick ends it; nothing more is kept
    call time_ms
    sub rax, 20000
    mov [rbx + EXT_full_since], rax
    jmp 9f
2:  # the written prefix goes before more is appended (a program that drains its pipe slowly
    # must not make the queue grow behind the bytes it already took)
    mov rcx, [rbx + EXT_wq_off]
    test rcx, rcx
    jz 3f
    push rsi
    push rdx
    mov rdi, [rbx + EXT_wq + SB_ptr]
    lea rsi, [rdi + rcx]
    mov rdx, [rbx + EXT_wq + SB_len]
    sub rdx, rcx
    call memmove
    mov rcx, [rbx + EXT_wq_off]
    sub [rbx + EXT_wq + SB_len], rcx
    mov qword ptr [rbx + EXT_wq_off], 0
    pop rdx
    pop rsi
3:  lea rdi, [rbx + EXT_wq]
    call sb_push
    mov rdi, rbx
    call ext_flush
9:  EPILOGUE

# ext_flush(ext): write the queue to the program; what does not fit waits for POLLOUT
FN ext_flush
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + EXT_in], 0
    jl 9f
    cmp qword ptr [rbx + EXT_in_closed_at], 0
    jne 9f
1:  mov rdx, [rbx + EXT_wq + SB_len]
    sub rdx, [rbx + EXT_wq_off]
    jz 5f
    mov rsi, [rbx + EXT_wq + SB_ptr]
    add rsi, [rbx + EXT_wq_off]
    mov edi, [rbx + EXT_in]
    SYS SYS_write
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 6f
    test rax, rax
    jle 7f
    add [rbx + EXT_wq_off], rax
    jmp 1b
5:  # all written
    lea rdi, [rbx + EXT_wq]
    call sb_clear
    mov qword ptr [rbx + EXT_wq_off], 0
    mov qword ptr [rbx + EXT_full_since], 0
    mov edi, [rbx + EXT_in]
    xor esi, esi
    call watch_set_events
    jmp 9f
6:  # the pipe is full: wait for POLLOUT; note when the queue went over its cap
    mov edi, [rbx + EXT_in]
    mov esi, POLLOUT
    call watch_set_events
    mov rax, [rbx + EXT_wq + SB_len]
    sub rax, [rbx + EXT_wq_off]
    cmp rax, EXT_WQ_MAX
    jb 61f
    cmp qword ptr [rbx + EXT_full_since], 0
    jne 9f
    call time_ms
    mov [rbx + EXT_full_since], rax
    jmp 9f
61: mov qword ptr [rbx + EXT_full_since], 0
    jmp 9f
7:  # EPIPE: the program closed its input (macOS does not report that through poll on the
    # write end); its exit status, if it comes within 300 ms, is the reason to keep
    cmp qword ptr [rbx + EXT_in_closed_at], 0
    jne 9f
    call time_ms
    mov [rbx + EXT_in_closed_at], rax
9:  EPILOGUE

# ext_exited(ext, status): the program is gone; reap it and record why
#   status -1: not known yet (end of file on its output): the group is killed and waited for
FN ext_exited
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_STOPPING
    jne 9f
1:  mov edi, [rbx + EXT_pid]
    neg edi
    mov esi, SIGKILL
    SYS SYS_kill
    mov edi, [rbx + EXT_pid]
    xor esi, esi
    call proc_wait
    mov r12d, eax
    mov edi, [rbx + EXT_out]
    call watch_remove
    mov edi, [rbx + EXT_in]
    call watch_remove
    mov edi, [rbx + EXT_out]
    SYS SYS_close
    mov edi, [rbx + EXT_in]
    SYS SYS_close
    mov dword ptr [rbx + EXT_out], -1
    mov dword ptr [rbx + EXT_in], -1
    mov edi, [rbx + EXT_log]
    test edi, edi
    js 2f
    SYS SYS_close
    mov dword ptr [rbx + EXT_log], -1
2:  mov dword ptr [rbx + EXT_pid], 0
    mov rdi, rbx
    call extmarks_clear_owner
    mov rdi, rbx
    call ext_cmds_remove_runtime
    mov rdi, rbx
    call ext_options_clear
    mov rdi, rbx
    call extproto_prompt_owner_gone
    mov rdi, rbx
    call extview_owner_gone     # its views close with it
    mov rdi, rbx
    call complete_ext_gone      # and its completion items and signature help
    mov rdi, rbx
    call langfeat_ext_gone      # and the language queries it was asked
    xor edi, edi
    call ext_hover_forget       # its hover text, if the tooltip shows one
    mov rdi, [rbx + EXT_body]
    call mem_free
    mov qword ptr [rbx + EXT_body], 0
    mov rdi, [rbx + EXT_status_text]
    call mem_free
    mov qword ptr [rbx + EXT_status_text], 0
    mov qword ptr [rbx + EXT_known + VEC_len], 0
    lea rdi, [rbx + EXT_rbuf]
    call sb_clear
    lea rdi, [rbx + EXT_wq]
    call sb_clear
    mov qword ptr [rbx + EXT_wq_off], 0
    mov r13, [rbx + EXT_pending]    # the command that started it, for a restart without confinement
    mov qword ptr [rbx + EXT_pending], 0
    cmp qword ptr [rbx + EXT_reason], 0
    jne 5f
    # it left on its own; 127 is the child that could not exec its program; a code in the shared
    # page is the child that could not confine itself (confine.s). The exit status alone proves
    # nothing: the program may exit with the same numbers
    mov rdi, rbx
    call confine_failed
    test eax, eax
    jz 20f
    mov edi, eax
    call confine_exit_reason
    test rax, rax
    jz 20f
    cmp dword ptr [rbx + EXT_noconfine], 0
    jne 20f
    mov [rbx + EXT_confine_why], rax
    mov dword ptr [rbx + EXT_noconfine], 1
    mov dword ptr [rbx + EXT_status], ES_IDLE
    mov dword ptr [rbx + EXT_confined], CONFINED_NO
    mov [rbx + EXT_pending], r13
    mov dword ptr [rip + g_dirty], 1
    call ext_hooks_update
    mov rdi, rbx
    call ext_start
    jmp 9f
20: cmp r12d, 127
    jne 21f
    lea rax, [rip + .Lr_exec]
    mov [rbx + EXT_reason], rax
    mov dword ptr [rbx + EXT_status], ES_FAILED
    jmp 8f
21: mov dword ptr [rbx + EXT_status], ES_CRASHED
    lea rdi, [rip + reason_buf]
    lea rsi, [rip + .Lr_exited]
    call cstr_copy
    mov rdi, rax
    mov esi, r12d
    call fmt_u64
    lea rdi, [rip + reason_buf]
    call dup_cstr
    mov [rbx + EXT_reason], rax
    call time_ms
    mov rcx, rax
    sub rcx, [rbx + EXT_crash_t0]
    cmp rcx, 60000
    jb 3f
    mov [rbx + EXT_crash_t0], rax
    mov dword ptr [rbx + EXT_crashes], 0
3:  inc dword ptr [rbx + EXT_crashes]
    cmp dword ptr [rbx + EXT_crashes], 3
    jb 8f
    lea rax, [rip + .Lr_three]
    mov [rbx + EXT_reason], rax
    mov dword ptr [rbx + EXT_status], ES_STOPPED
    jmp 8f
5:  mov dword ptr [rbx + EXT_status], ES_STOPPED
    cmp dword ptr [rbx + EXT_disabled], 0
    je 51f
    mov dword ptr [rbx + EXT_status], ES_DISABLED
    lea rax, [rip + .Lr_disabled]
    mov [rbx + EXT_reason], rax
51: cmp dword ptr [rbx + EXT_restart], 0
    je 8f
    mov dword ptr [rbx + EXT_restart], 0
    cmp dword ptr [rbx + EXT_disabled], 0
    jne 8f                      # turned off again meanwhile
    mov dword ptr [rbx + EXT_status], ES_IDLE
    mov dword ptr [rip + g_dirty], 1
    call ext_hooks_update
    mov rdi, rbx
    call ext_start
    jmp 9f
8:  mov dword ptr [rip + g_dirty], 1
    call ext_hooks_update
9:  EPILOGUE

# ext_kill(ext, reason): end the program now, keeping the reason
FN ext_kill
    push rbx
    mov rbx, rdi
    mov [rbx + EXT_reason], rsi
    mov rdi, rbx
    mov esi, -1
    call ext_exited
    pop rbx
    ret

# ext_stop(ext, reason): bye, then SIGTERM after a second and SIGKILL after another (ext_tick)
FN ext_stop
    PROLOGUE
    mov rbx, rdi
    mov [rbx + EXT_reason], rsi
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    jne 9f
1:  mov rdi, rbx
    call extproto_prompt_owner_gone     # a prompt of a stopping program must not act any more
    mov rdi, rbx
    lea rsi, [rip + .Lbye]
    mov edx, 6
    call ext_send
    mov dword ptr [rbx + EXT_status], ES_STOPPING
    call time_ms
    mov [rbx + EXT_started], rax
9:  EPILOGUE

# ext_restart(ext): after a stop or a crash, by the user
FN ext_restart
    push rbx
    mov rbx, rdi
    cmp dword ptr [rbx + EXT_manifest_ok], 0
    je 9f
    mov dword ptr [rbx + EXT_crashes], 0
    cmp dword ptr [rbx + EXT_status], ES_STOPPED
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_CRASHED
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_FAILED
    jne 9f
    cmp qword ptr [rbx + EXT_prog], 0
    je 9f                       # a bad manifest stays failed
1:  mov dword ptr [rbx + EXT_status], ES_IDLE
    mov rdi, rbx
    call ext_start
9:  pop rbx
    ret

# A project name is owned here: app_set_project may reuse the old string's address. Running
# programs must restart because a sandbox and RHUN_PROJECT cannot be changed after exec.
ext_project_check:
    PROLOGUE
    mov rdi, [rip + g_project]
    mov rsi, [rip + ext_project_seen]
    cmp rdi, rsi
    je 9f
    test rdi, rdi
    jz 1f
    test rsi, rsi
    jz 1f
    call strcmp_eq
    test eax, eax
    jnz 9f
1:  mov rdi, [rip + ext_project_seen]
    call mem_free
    mov qword ptr [rip + ext_project_seen], 0
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 2f
    call dup_cstr
    mov [rip + ext_project_seen], rax
2:  mov dword ptr [rip + ext_project_done], 0
    cmp dword ptr [rip + ext_startup_done], 0
    je 9f                      # the initial project, before any activation
    call extproto_send_project_all
    xor r12d, r12d
3:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    mov eax, [rbx + EXT_status]
    cmp eax, ES_RUNNING
    je 4f
    cmp eax, ES_STARTING
    jne 3b
4:  mov dword ptr [rbx + EXT_restart], 1
    mov dword ptr [rbx + EXT_noconfine], 0
    mov rdi, rbx
    lea rsi, [rip + .Lr_project_change]
    call ext_stop
    jmp 3b
9:  EPILOGUE

# ext_tick(): once per frame: the budget, deadlines, and the events for each program
FN ext_tick
    PROLOGUE
    cmp qword ptr [rip + g_exts + VEC_len], 0
    je 9f
    inc dword ptr [rip + ext_ticks]
    call ext_project_check
    # on = startup, once; on = project when a project is open
    cmp dword ptr [rip + ext_startup_done], 0
    jne 1f
    mov dword ptr [rip + ext_startup_done], 1
    mov edi, ON_STARTUP
    call ext_start_matching
1:  cmp qword ptr [rip + g_project], 0
    je 2f
    cmp dword ptr [rip + ext_project_done], 0
    jne 2f
    mov dword ptr [rip + ext_project_done], 1
    mov edi, ON_PROJECT
    call ext_start_matching
2:  # documents opened since the last tick start the extensions whose lang:/open: lists match;
    # tabs are not in creation order, so the mark moves only after the whole scan
    mov r15, [rip + ext_last_doc]
    xor r12d, r12d
21: cmp r12, [rip + g_tabs + VEC_len]
    jae 22f
    imul rax, r12, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    inc r12
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 21b
    mov rdi, [rax + TAB_doc]
    test rdi, rdi
    jz 21b
    mov rax, [rdi + DOC_id]
    cmp rax, [rip + ext_last_doc]
    jbe 21b
    cmp rax, r15
    jbe 23f
    mov r15, rax
23: call ext_doc_opened
    jmp 21b
22: mov [rip + ext_last_doc], r15
    # extensions waiting for a slot
    xor r12d, r12d
24: cmp r12, [rip + g_exts + VEC_len]
    jae 25f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_wait_slot], 0
    je 24b
    cmp dword ptr [rbx + EXT_status], ES_IDLE
    jne 24b
    call ext_running
    cmp eax, EXT_MAX_RUNNING
    jae 25f
    mov rdi, rbx
    call ext_start
    jmp 24b
25: # the clock, after the starts above (a start sets EXT_started)
    call time_ms
    mov r14, rax
    # the pointer has rested on a position long enough: the hover event, once
    cmp qword ptr [rip + g_hover_doc], 0
    je 26f
    cmp dword ptr [rip + g_hover_sent], 0
    jne 26f
    mov rax, r14
    sub rax, [rip + g_hover_since]
    cmp rax, HOVER_REST_MS
    jl 26f
    mov dword ptr [rip + g_hover_sent], 1
    mov rdi, [rip + g_hover_doc]
    mov rsi, [rip + g_hover_pos]
    call extproto_send_hover_all
26: xor r12d, r12d
.Let_each:
    cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    mov eax, [rbx + EXT_status]
    cmp eax, ES_STARTING
    je .Let_starting
    cmp eax, ES_RUNNING
    je .Let_running
    cmp eax, ES_STOPPING
    je .Let_stopping
    jmp .Let_each
.Let_starting:
    mov rax, r14
    sub rax, [rbx + EXT_started]
    cmp rax, EXT_HELLO_MS
    jl .Let_common
    mov rdi, rbx
    lea rsi, [rip + .Lr_no_hello]
    call ext_kill
    jmp .Let_each
.Let_stopping:
    mov rax, r14
    sub rax, [rbx + EXT_started]
    cmp rax, 1000
    jl .Let_common
    mov edi, [rbx + EXT_pid]
    neg edi
    mov esi, SIGTERM
    cmp rax, 2000
    jl 3f
    mov rdi, rbx
    mov esi, -1
    call ext_exited
    jmp .Let_each
3:  SYS SYS_kill
    jmp .Let_common
.Let_running:
    mov rdi, rbx
    call extproto_events
.Let_common:
    # a program that closed its input and is still there 300 ms later
    mov rax, [rbx + EXT_in_closed_at]
    test rax, rax
    jz 40f
    mov rcx, r14
    sub rcx, rax
    cmp rcx, 300
    jl 40f
    mov rdi, rbx
    lea rsi, [rip + .Lr_closed_in]
    call ext_kill
    jmp .Let_each
40: # a program that does not read for 10 s
    mov rax, [rbx + EXT_full_since]
    test rax, rax
    jz 4f
    mov rcx, r14
    sub rcx, rax
    cmp rcx, 10000
    jl 4f
    mov rdi, rbx
    lea rsi, [rip + .Lr_not_reading]
    call ext_kill
    jmp .Let_each
4:  # its error log stays under its cap (the program keeps its descriptor, so it is cut, not rotated)
    mov edi, [rbx + EXT_log]
    test edi, edi
    js 42f
    xor esi, esi
    mov edx, 2                  # SEEK_END
    SYS SYS_lseek
    cmp rax, EXT_LOG_MAX
    jbe 42f
    mov edi, [rbx + EXT_log]
    xor esi, esi
    SYS SYS_ftruncate
42: # a program throttled for a window resumes when the window has passed; EXT_flood counts
    # windows in a row that hit a cap (extproto_pump keeps it)
    cmp dword ptr [rbx + EXT_throttled], 0
    je .Let_each
    mov rax, r14
    sub rax, [rbx + EXT_win_t0]
    cmp rax, EXT_WIN_MS
    jl .Let_each
    cmp dword ptr [rbx + EXT_flood], EXT_FLOOD_FRAMES
    jb 43f
    mov rdi, rbx
    lea rsi, [rip + .Lr_flooding]
    call ext_kill
    jmp .Let_each
43: mov dword ptr [rbx + EXT_throttled], 0
    mov rdi, rbx
    call extproto_pump          # what is buffered already; it may throttle again
    cmp dword ptr [rbx + EXT_throttled], 0
    jne .Let_each
    cmp dword ptr [rbx + EXT_out], 0
    jl .Let_each
    mov edi, [rbx + EXT_out]
    mov esi, POLLIN
    call watch_set_events
    jmp .Let_each
9:  # the frame's edit records have been delivered to every extension: clear them
    cmp dword ptr [rip + g_ext_hooks], 0
    je 91f
    xor r12d, r12d
90: cmp r12, [rip + g_tabs + VEC_len]
    jae 91f
    imul rax, r12, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    inc r12
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 90b
    mov rdi, [rax + TAB_doc]
    test rdi, rdi
    jz 90b
    call ext_edits_clear
    jmp 90b
91: EPILOGUE

# ext_timeout() -> ms until the loop should come back for the extensions, or -1: 16 while a
# program's buffered lines wait for the next frame's budget; the time left to a hello deadline, a
# stop escalation or a full-queue deadline (so they are enforced without any other event)
FN ext_timeout
    PROLOGUE
    mov r12, -1                 # the earliest deadline, as a time
    xor r13d, r13d
1:  cmp r13, [rip + g_exts + VEC_len]
    jae 8f
    imul rbx, r13, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r13
    cmp dword ptr [rbx + EXT_throttled], 0
    je 11f
    mov rax, [rbx + EXT_win_t0]
    add rax, EXT_WIN_MS
    call deadline
11: mov eax, [rbx + EXT_status]
    cmp eax, ES_STARTING
    jne 2f
    mov rax, [rbx + EXT_started]
    add rax, EXT_HELLO_MS
    call deadline
    jmp 3f
2:  cmp eax, ES_STOPPING
    jne 3f
    mov rax, [rbx + EXT_started]
    add rax, 1000
    call deadline
    mov rax, [rbx + EXT_started]
    add rax, 2000
    call deadline
3:  mov rax, [rbx + EXT_full_since]
    test rax, rax
    jz 1b
    add rax, 10000
    call deadline
    jmp 1b
8:  # the hover rest, when one is pending, is a deadline too
    call ext_hover_due
    cmp eax, -1
    je 82f
    movsxd r13, eax
    cmp r12, -1
    je 83f
    call time_ms
    sub r12, rax
    jns 84f
    xor r12d, r12d
84: cmp r13, r12
    jae 85f
    mov r12, r13
85: mov rax, r12
    EPILOGUE
83: mov rax, r13
    EPILOGUE
82: cmp r12, -1
    je 9f
    call time_ms
    sub r12, rax
    jns 81f
    xor r12d, r12d
81: mov rax, r12
    EPILOGUE
9:  mov eax, -1
    EPILOGUE
# deadline(rax time): keep the earliest in r12
deadline:
    cmp r12, -1
    je 1f
    cmp rax, r12
    jae 2f
1:  mov r12, rax
2:  ret

# ext_start_matching(ON_ bit): start idle extensions with that activation
FN ext_start_matching
    PROLOGUE
    mov r12d, edi
    xor r13d, r13d
1:  cmp r13, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r13, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r13
    test [rbx + EXT_on], r12d
    jz 1b
    cmp dword ptr [rbx + EXT_status], ES_IDLE
    jne 1b
    mov rdi, rbx
    call ext_start
    jmp 1b
9:  EPILOGUE

# ext_doc_opened(doc): a document appeared: on = lang:X / open:GLOB extensions that match start
FN ext_doc_opened
    PROLOGUE
    mov r12, rdi
    xor r13d, r13d
1:  cmp r13, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r13, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r13
    cmp dword ptr [rbx + EXT_status], ES_IDLE
    jne 1b
    test dword ptr [rbx + EXT_on], ON_LANG | ON_OPEN
    jz 1b
    mov rdi, rbx
    mov rsi, r12
    call ext_activation_matches
    test eax, eax
    jz 1b
    mov rdi, rbx
    call ext_start
    jmp 1b
9:  EPILOGUE

# ext_activation_matches(ext, doc) -> 1 when the document's grammar or name is in the lists
FN ext_activation_matches
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rax, [r12 + DOC_lang]
    test rax, rax
    jz 1f
    mov rdi, [rax + GR_name]
    mov rsi, [rbx + EXT_on_langs]
    call list_has_word
    test eax, eax
    jnz 9f
1:  mov rdi, [r12 + DOC_path]
    test rdi, rdi
    jz 8f
    mov rsi, [rbx + EXT_on_globs]
    call ext_path_matches
    test eax, eax
    jnz 9f
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# list_has_word(word cstr, list cstr or 0) -> 1 when the space separated list has the word
FN list_has_word
    PROLOGUE
    test rsi, rsi
    jz 8f
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov r13, rax
1:  test r13, r13
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    mov rdx, rbx
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ext_path_matches(path cstr, patterns cstr or 0) -> 1 when the file's name matches a pattern
# ("*" matches every name; "*.ext" a suffix; anything else the exact name)
FN ext_path_matches
    PROLOGUE
    test rsi, rsi
    jz 8f
    mov r12, rsi
    call strlen
    mov rsi, rax
    call path_basename
    mov rbx, rax                # name
    mov r14, rdx                # len
    mov rdi, r12
    call strlen
    mov r13, rax
1:  test r13, r13
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 8f
    cmp rdx, 1
    jne 2f
    cmp byte ptr [rax], '*'
    je 9f
2:  mov rcx, rdx
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r14
    call pattern_match
    test eax, eax
    jz 1b
9:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ext_shutdown(): rhun quits: bye to every program, up to 300 ms for them to leave on their own,
# SIGTERM to the rest (on Linux they die with rhun regardless)
FN ext_shutdown
    PROLOGUE
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 2f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 1b
    mov rdi, rbx
    lea rsi, [rip + .Lbye]
    mov edx, 6
    call ext_send
    jmp 1b
2:  call time_ms
    lea r13, [rax + 300]
3:  # any still running?
    xor r12d, r12d
    xor r14d, r14d
4:  cmp r12, [rip + g_exts + VEC_len]
    jae 5f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    mov eax, [rbx + EXT_status]
    cmp eax, ES_RUNNING
    je 41f
    cmp eax, ES_STARTING
    je 41f
    cmp eax, ES_STOPPING
    jne 4b
41: mov edi, [rbx + EXT_pid]
    mov esi, 1
    call proc_wait
    cmp eax, -1
    jne 42f
    inc r14d                    # still there
    jmp 4b
42: mov dword ptr [rbx + EXT_status], ES_STOPPED
    jmp 4b
5:  test r14d, r14d
    jz 9f
    call time_ms
    cmp rax, r13
    jae 6f
    mov edi, 10
    call loop_poll              # drains what they write, flushes bye
    jmp 3b
6:  xor r12d, r12d
7:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    mov eax, [rbx + EXT_status]
    cmp eax, ES_RUNNING
    je 71f
    cmp eax, ES_STARTING
    je 71f
    cmp eax, ES_STOPPING
    jne 7b
71: mov edi, [rbx + EXT_pid]
    neg edi
    mov esi, SIGTERM
    SYS SYS_kill
    jmp 7b
9:  EPILOGUE

# ext_status_draw(right, y, h) -> eax the right edge left of the texts drawn: each running
# extension's status text, right-aligned in the small face
FN ext_status_draw
    PROLOGUE 16
    mov r14d, edi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], edi
    # "N errors, M warnings" of the document on screen
    mov rdi, [rip + g_doc]
    call extmarks_counts
    test eax, eax
    jnz 10f
    test edx, edx
    jz 11f
10: mov r12d, eax
    mov r13d, edx
    lea rdi, [rip + tmp]
    call sb_clear
    test r12d, r12d
    jz 12f
    lea rdi, [rip + tmp]
    mov esi, r12d
    call sb_push_u64
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Ld_errors]
    cmp r12d, 1
    jne 13f
    lea rsi, [rip + .Ld_error]
13: call sb_push_cstr
    test r13d, r13d
    jz 14f
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Ld_comma]
    call sb_push_cstr
12: test r13d, r13d
    jz 14f
    lea rdi, [rip + tmp]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Ld_warnings]
    cmp r13d, 1
    jne 15f
    lea rsi, [rip + .Ld_warning]
15: call sb_push_cstr
14: lea rdi, [rip + g_face_small]
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    call text_width
    sub r14d, [rip + g_mt + 4*MI_12]
    sub r14d, eax
    lea rdi, [rip + g_face_small]
    mov esi, r14d
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR eax, T_MUTED
    test r12d, r12d
    jz 16f
    COLOR eax, T_ERROR
16: push rax
    push rax
    call ui_text_v
    add rsp, 16
11: xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 1b
    mov r13, [rbx + EXT_status_text]
    test r13, r13
    jz 1b
    mov rdi, r13
    call strlen
    mov r15, rax
    lea rdi, [rip + g_face_small]
    mov rsi, r13
    mov rdx, r15
    call text_width
    sub r14d, [rip + g_mt + 4*MI_12]
    sub r14d, eax
    lea rdi, [rip + g_face_small]
    mov esi, r14d
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    mov r8, r13
    mov r9, r15
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    jmp 1b
9:  mov eax, r14d
    cmp eax, [rsp + 8]
    je 8f
    sub eax, [rip + g_mt + 4*MI_20]   # the file's items keep their gap from the last text
8:  EPILOGUE

# ext_state_name(ES_*) -> cstr
FN ext_state_name
    cmp edi, ES_REMOVED
    ja 1f
    mov eax, edi
    lea rcx, [rip + state_names]
    mov rax, [rcx + rax*8]
    ret
1:  lea rax, [rip + .Lst_unknown]
    ret

# ext_dump(sb): one line per extension, for print-extensions:
#   OWNER/NAME state=S [reason=R] pid=P cmds=a,b [status=T]
FN ext_dump
    PROLOGUE
    mov r12, rdi
    xor r13d, r13d
1:  cmp r13, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r13, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r13
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 1b
    mov rdi, r12
    mov rsi, [rbx + EXT_owner]
    call sb_push_cstr
    mov rdi, r12
    mov esi, '/'
    call sb_push_byte
    mov rdi, r12
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    mov edi, [rbx + EXT_status]
    call ext_state_name
    mov rdi, r12
    mov rsi, rax
    call sb_push_cstr
    mov rsi, [rbx + EXT_reason]
    test rsi, rsi
    jz 2f
    mov rdi, r12
    lea rsi, [rip + .Ld_reason]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + EXT_reason]
    call sb_push_cstr
2:  mov rdi, r12
    lea rsi, [rip + .Ld_pid]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + EXT_pid]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_cmds]
    call sb_push_cstr
    mov r14d, [rbx + EXT_cmd0]
    mov r15d, [rbx + EXT_ncmd]
    add r15d, r14d
3:  cmp r14d, r15d
    jae 4f
    imul rax, r14, CMD_SIZE
    add rax, [rip + g_ext_cmds + VEC_ptr]
    mov rdi, r12
    mov rsi, [rax + CMD_name]
    call sb_push_cstr
    inc r14d
    cmp r14d, r15d
    jae 4f
    mov rdi, r12
    mov esi, ','
    call sb_push_byte
    jmp 3b
4:  # the commands it registered at runtime
    mov r14, [rip + ext_manifest_cmds]
31: cmp r14, [rip + g_ext_cmds + VEC_len]
    jae 32f
    mov rax, [rip + g_ext_owner + VEC_ptr]
    mov rax, [rax + r14*8]
    inc r14
    inc rax
    cmp rax, r13
    jne 31b                     # r13 is this extension's index + 1 after the inc above
    lea r15, [r14 - 1]
    imul r15, r15, CMD_SIZE
    add r15, [rip + g_ext_cmds + VEC_ptr]
    mov rdi, r12
    mov esi, ','
    call sb_push_byte
    mov rdi, r12
    mov rsi, [r15 + CMD_name]
    call sb_push_cstr
    jmp 31b
32: # how it is confined, and the user's choices
    mov rdi, r12
    lea rsi, [rip + .Ld_confined]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + EXT_confined]
    call sb_push_u64
    cmp dword ptr [rbx + EXT_pinned], 0
    je 42f
    mov rdi, r12
    lea rsi, [rip + .Ld_pinned]
    call sb_push_cstr
42: cmp dword ptr [rbx + EXT_disabled], 0
    je 43f
    mov rdi, r12
    lea rsi, [rip + .Ld_disabled]
    call sb_push_cstr
43: cmp dword ptr [rbx + EXT_flood], 0
    je 41f
    mov rdi, r12
    lea rsi, [rip + .Ld_flood]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + EXT_flood]
    call sb_push_u64
41: mov rsi, [rbx + EXT_confine_why]
    test rsi, rsi
    jz 44f
    mov rdi, r12
    lea rsi, [rip + .Ld_why]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + EXT_confine_why]
    call sb_push_cstr
44: mov rsi, [rbx + EXT_status_text]
    test rsi, rsi
    jz 5f
    mov rdi, r12
    lea rsi, [rip + .Ld_status]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + EXT_status_text]
    call sb_push_cstr
5:  mov rdi, r12
    mov esi, 10
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# ext_by_name(ptr, len) -> EXT* or 0: "name" or "owner/name"
FN ext_by_name
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
1:  cmp r14, [rip + g_exts + VEC_len]
    jae 8f
    imul rbx, r14, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r14
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 1b
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rbx + EXT_name]
    call str_eq_cstr
    test eax, eax
    jnz 9f
    # owner/name
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_owner]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rip + tmp + SB_ptr]
    call str_eq_cstr
    test eax, eax
    jnz 9f
    jmp 1b
8:  xor ebx, ebx
9:  mov rax, rbx
    EPILOGUE

.data
.p2align 3
cur_start: .quad 0              # the EXT being started (env_add_state)

.section .rodata
.p2align 3
state_names: .quad .Lst_idle, .Lst_starting, .Lst_running, .Lst_stopping, .Lst_stopped, .Lst_crashed, .Lst_failed, .Lst_disabled, .Lst_removed
pv_more: .quad EXT_pv_definition, EXT_pv_references, EXT_pv_symbols, EXT_pv_actions, EXT_pv_rename
    .quad EXT_pv_format, 0
pv_keys: .quad .Lpv_complete, EXT_pv_complete, .Lpv_ctrig, EXT_pv_ctrig
    .quad .Lpv_signature, EXT_pv_signature, .Lpv_strig, EXT_pv_strig
    .quad .Lpv_definition, EXT_pv_definition, .Lpv_references, EXT_pv_references
    .quad .Lpv_symbols, EXT_pv_symbols, .Lpv_actions, EXT_pv_actions
    .quad .Lpv_rename, EXT_pv_rename, .Lpv_format, EXT_pv_format, 0, 0
sub_keys: .quad .Lsk_opened, EXT_sub_opened, .Lsk_saved, EXT_sub_saved, .Lsk_changed, EXT_sub_changed
    .quad .Lsk_cursor, EXT_sub_cursor, .Lsk_selection, EXT_sub_selection
    .quad .Lsk_edits, EXT_sub_edits, .Lsk_hover, EXT_sub_hover, 0, 0
env_names: .quad .Le_path, .Le_home, .Le_tmpdir, .Le_cache, .Le_gocache, .Le_gomod, .Le_gopath, .Le_npm
.ifdef MACOS
    .quad .Le_xcrun_db, .Le_devdir
.endif
.ifdef WINDOWS
    .quad .Le_temp, .Le_tmp, .Le_userprofile, .Le_appdata, .Le_localappdata
.endif
    .quad .Le_rhun_prefix, 0
.ifdef WINDOWS
win_env_copy:
    .quad .Lwe_0, .Lwe_0_eq
    .quad .Lwe_1, .Lwe_1_eq
    .quad .Lwe_2, .Lwe_2_eq
    .quad .Lwe_3, .Lwe_3_eq
    .quad .Lwe_4, .Lwe_4_eq
    .quad .Lwe_5, .Lwe_5_eq
    .quad .Lwe_6, .Lwe_6_eq
    .quad .Lwe_7, .Lwe_7_eq
    .quad .Lwe_8, .Lwe_8_eq
    .quad .Lwe_9, .Lwe_9_eq
    .quad .Lwe_10, .Lwe_10_eq
    .quad .Lwe_11, .Lwe_11_eq
    .quad .Lwe_12, .Lwe_12_eq
    .quad .Lwe_13, .Lwe_13_eq
    .quad .Lwe_14, .Lwe_14_eq
    .quad 0, 0
.endif
.globl ext_target
.ifdef WINDOWS
.globl ext_target
ext_target: .asciz "windows-x64"
.Lk_run_target: .asciz "run.windows-x64"
.else
.ifdef MACOS
.globl ext_target
ext_target: .asciz "macos-arm64"
.Lk_run_target: .asciz "run.macos-arm64"
.else
.globl ext_target
ext_target: .asciz "linux-x86_64"
.Lk_run_target: .asciz "run.linux-x86_64"
.endif
.endif
.Lsub_extensions: .asciz "/extensions"
.Lsub_tmp: .asciz "/tmp"
.Lsub_cache: .asciz "/cache"
.Lsub_gocache: .asciz "/gocache"
.Lsub_gomod: .asciz "/gomod"
.Lsub_gopath: .asciz "/gopath"
.Lsub_npm: .asciz "/npm"
.Lsuf_log: .asciz ".log"
.Lmanifest: .asciz "extension.ini"
.Lsub_themes: .asciz "themes"
.Lsub_syntax: .asciz "syntax"
.ifdef WINDOWS
.Ldevnull: .asciz "NUL"
.else
.Ldevnull: .asciz "/dev/null"
.endif
.Lnl: .asciz "\n"
.Lno_home_state: .asciz "/tmp/rhun-state"
.Lk_name: .asciz "name"
.Lk_owner: .asciz "owner"
.Le_socket_eq: .asciz "RHUN_SOCKET="
.Ldashdash: .asciz "--"
.Lempty: .asciz ""
.Lone: .asciz "1"
.Lno: .asciz "no"
.Lyes: .asciz "yes"
.Lread: .asciz "read"
.Lwrite: .asciz "write"
.Lbar: .asciz "|"
.Lparen: .asciz " ("
.Lbye: .asciz "0 bye\n"
.Lk_title: .asciz "title"
.Lk_version: .asciz "version"
.Lk_protocol: .asciz "protocol"
.Lk_runtime: .asciz "runtime"
.Lk_icon: .asciz "icon"
.Lk_color: .asciz "color"
.Lk_run: .asciz "run"
.Lk_args: .asciz "args"
.Lk_on: .asciz "on"
.Ls_commands: .asciz "commands"
.Ls_subscribe: .asciz "subscribe"
.Ls_provides: .asciz "provides"
.Lpv_complete: .asciz "complete"
.Lpv_ctrig: .asciz "complete.triggers"
.Lpv_signature: .asciz "signature"
.Lpv_strig: .asciz "signature.triggers"
.Lpv_definition: .asciz "definition"
.Lpv_references: .asciz "references"
.Lpv_symbols: .asciz "symbols"
.Lpv_actions: .asciz "actions"
.Lpv_rename: .asciz "rename"
.Lpv_format: .asciz "format"
.Ls_needs: .asciz "needs"
.Lsk_opened: .asciz "opened"
.Lsk_saved: .asciz "saved"
.Lsk_changed: .asciz "changed"
.Lsk_cursor: .asciz "cursor"
.Lsk_selection: .asciz "selection"
.Lsk_edits: .asciz "edits"
.Lsk_hover: .asciz "hover"
.Ln_documents: .asciz "documents"
.Ln_project: .asciz "project"
.Ln_home: .asciz "home"
.Ln_network: .asciz "network"
.Ln_terminal: .asciz "terminal"
.Ln_run: .asciz "run"
.Lo_startup: .asciz "startup"
.Lo_command: .asciz "command"
.Lo_project: .asciz "project"
.Lo_lang: .asciz "lang:"
.Lo_open: .asciz "open:"
.Le_path: .asciz "PATH"
.Le_path_eq: .asciz "PATH="
.Le_home: .asciz "HOME"
.Le_home_eq: .asciz "HOME="
.Le_tmpdir: .asciz "TMPDIR"
.Le_tmpdir_eq: .asciz "TMPDIR="
.Le_cache: .asciz "XDG_CACHE_HOME"
.Le_cache_eq: .asciz "XDG_CACHE_HOME="
.Le_gocache: .asciz "GOCACHE"
.Le_gocache_eq: .asciz "GOCACHE="
.Le_gomod: .asciz "GOMODCACHE"
.Le_gomod_eq: .asciz "GOMODCACHE="
.Le_gopath: .asciz "GOPATH"
.Le_gopath_eq: .asciz "GOPATH="
.Le_npm: .asciz "npm_config_cache"
.Le_npm_eq: .asciz "npm_config_cache="
.Le_lang: .asciz "LANG"
.Le_xcrun_db: .asciz "xcrun_db"
.Le_xcrun_db_eq: .asciz "xcrun_db="
.Lsub_xcrun_db: .asciz "xcrun_db"
.Le_devdir: .asciz "DEVELOPER_DIR"
.Le_devdir_eq: .asciz "DEVELOPER_DIR="
.Le_lang_eq: .asciz "LANG="
.Le_lc_all: .asciz "LC_ALL"
.Le_lc_all_eq: .asciz "LC_ALL="
.Le_tz: .asciz "TZ"
.Le_tz_eq: .asciz "TZ="
.ifdef WINDOWS
.Lwe_0: .asciz "SYSTEMROOT"
.Lwe_0_eq: .asciz "SYSTEMROOT="
.Lwe_1: .asciz "WINDIR"
.Lwe_1_eq: .asciz "WINDIR="
.Lwe_2: .asciz "COMSPEC"
.Lwe_2_eq: .asciz "COMSPEC="
.Lwe_3: .asciz "PATHEXT"
.Lwe_3_eq: .asciz "PATHEXT="
.Lwe_4: .asciz "SYSTEMDRIVE"
.Lwe_4_eq: .asciz "SYSTEMDRIVE="
.Lwe_5: .asciz "PROGRAMDATA"
.Lwe_5_eq: .asciz "PROGRAMDATA="
.Lwe_6: .asciz "PROGRAMFILES"
.Lwe_6_eq: .asciz "PROGRAMFILES="
.Lwe_7: .asciz "PROGRAMFILES(X86)"
.Lwe_7_eq: .asciz "PROGRAMFILES(X86)="
.Lwe_8: .asciz "PROGRAMW6432"
.Lwe_8_eq: .asciz "PROGRAMW6432="
.Lwe_9: .asciz "COMMONPROGRAMFILES"
.Lwe_9_eq: .asciz "COMMONPROGRAMFILES="
.Lwe_10: .asciz "COMMONPROGRAMFILES(X86)"
.Lwe_10_eq: .asciz "COMMONPROGRAMFILES(X86)="
.Lwe_11: .asciz "COMMONPROGRAMW6432"
.Lwe_11_eq: .asciz "COMMONPROGRAMW6432="
.Lwe_12: .asciz "NUMBER_OF_PROCESSORS"
.Lwe_12_eq: .asciz "NUMBER_OF_PROCESSORS="
.Lwe_13: .asciz "PROCESSOR_ARCHITECTURE"
.Lwe_13_eq: .asciz "PROCESSOR_ARCHITECTURE="
.Lwe_14: .asciz "OS"
.Lwe_14_eq: .asciz "OS="
.Le_temp: .asciz "TEMP"
.Le_temp_eq: .asciz "TEMP="
.Le_tmp: .asciz "TMP"
.Le_tmp_eq: .asciz "TMP="
.Le_userprofile: .asciz "USERPROFILE"
.Le_userprofile_eq: .asciz "USERPROFILE="
.Le_appdata: .asciz "APPDATA"
.Le_appdata_eq: .asciz "APPDATA="
.Le_localappdata: .asciz "LOCALAPPDATA"
.Le_localappdata_eq: .asciz "LOCALAPPDATA="
.Lsub_roaming: .asciz "/appdata"
.Lsub_local: .asciz "/localappdata"
.Lpython3: .asciz "python3"
.Lpython: .asciz "python"
.Lpy: .asciz "py"
.Lwinapps: .asciz "/WindowsApps/"
.endif
.Le_rhun_prefix: .asciz "RHUN_"
.Le_version_eq: .asciz "RHUN_VERSION="
.Le_protocol_eq: .asciz "RHUN_PROTOCOL="
.Le_extension_eq: .asciz "RHUN_EXTENSION="
.Le_target_eq: .asciz "RHUN_TARGET="
.Le_state_eq: .asciz "RHUN_STATE="
.Le_project_eq: .asciz "RHUN_PROJECT="
.Lr_no_manifest: .asciz "no extension.ini"
.Lr_no_title: .asciz "extension.ini has no title"
.Lr_no_protocol: .asciz "extension.ini has no protocol"
.Lr_protocol: .asciz "protocol version not supported (rhun speaks 1)"
.Lr_no_program: .asciz "no program for this target in extension.ini"
.Lr_no_runtime: .asciz "runtime not found on PATH"
.Lr_no_file: .asciz "program file missing"
.Lr_not_exec: .asciz "program is not executable"
.Lr_name: .asciz "extension.ini name does not match the folder"
.Lr_off_cmd: .asciz " is turned off. Turn it on in Extensions to use its commands."
.Lr_stopped_cmd: .asciz " is stopped. Turn it off and on in Extensions to start it again."
.Lr_owner: .asciz "extension.ini owner does not match the folder"
.Lr_no_version: .asciz "extension.ini has no version"
.Lr_exec: .asciz "failed to start: the program could not be executed"
.Lr_closed_in: .asciz "closed its input"
.Lr_slots: .asciz "16 extensions already running"
.Lr_pipes: .asciz "cannot create pipes"
.Lr_spawn: .asciz "cannot start the program"
.Lr_windows: .asciz "Windows cannot hold an extension to its permissions yet"
.Lr_line: .asciz "a line over 64 KB without an end"
.Lr_exited: .asciz "exited with status "
.Lr_three: .asciz "crashed three times within a minute"
.Lr_no_hello: .asciz "no hello within 5 s"
.Lr_runs_long: .asciz "a run permission names a program path that is too long"
.Lr_project_change: .asciz "restarting after a project change"
.Lr_not_reading: .asciz "not reading for 10 s"
.Lr_flooding: .asciz "flooding: at the message or byte cap 30 windows in a row"
.Lst_idle: .asciz "idle"
.Lst_starting: .asciz "starting"
.Lst_running: .asciz "running"
.Lst_stopping: .asciz "stopping"
.Lst_stopped: .asciz "stopped"
.Lst_crashed: .asciz "crashed"
.Lst_failed: .asciz "failed"
.Lst_disabled: .asciz "disabled"
.Lst_unknown: .asciz "?"
.Ld_state: .asciz " state="
.Ld_reason: .asciz " reason="
.Ld_pid: .asciz " pid="
.Ld_cmds: .asciz " cmds="
.Ld_confined: .asciz " confined="
.Ld_pinned: .asciz " pinned=1"
.Ld_disabled: .asciz " disabled=1"
.Ld_why: .asciz " why="
.Lr_not_confined: .asciz "not confined: "
.Lr_disabled: .asciz "turned off"
.Lr_settings_stop: .asciz "stopped on its page"
.Lr_settings_change: .asciz "restarting after a settings change"
.Lf_extensions_ini: .asciz "/extensions.ini"
.Lk_pinned: .asciz "pinned"
.Lk_description: .asciz "description"
.Ls_settings: .asciz "settings"
.Lsf_type: .asciz "type"
.Lsf_default: .asciz "default"
.Lsf_title: .asciz "title"
.Lsf_desc: .asciz "description"
.Lsf_options: .asciz "options"
.Lsf_min: .asciz "min"
.Lsf_max: .asciz "max"
.Lst_bool: .asciz "bool"
.Lst_int: .asciz "int"
.Lst_choice: .asciz "choice"
.Lv_no: .asciz "no"
.Lw_close_sec: .asciz "]\n"
.Lw_pinned_yes: .asciz "pinned = yes\n"
.Lw_setting: .asciz "setting."
.Lw_eq: .asciz " = "
.Lr_turned_off: .asciz "turned off"
.Lst_removed: .asciz "removed"
.Lr_removed: .asciz "removed"
.Lk_disabled: .asciz "disabled"
.Lv_yes: .asciz "yes"
.Lw_disabled_yes: .asciz "disabled = yes\n"
.Ld_status: .asciz " status="
.Ld_flood: .asciz " flood="
.Ld_errors: .asciz " errors"
.Ld_error: .asciz " error"
.Ld_warnings: .asciz " warnings"
.Ld_warning: .asciz " warning"
.Ld_comma: .asciz ", "
