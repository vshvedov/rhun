# Claude Code's configuration and controls (agent_claude.s's driver): what the CLI reports of itself goes
# into the project's record (agentcfg.s) and the conversation's live record through the seam's events.
#
#   claude_init_answer(AL*, response)       initialize's answer (its "response" object): the models and
#     unavailable_models (value, displayName, description, supportedEffortLevels, or low/medium/high
#     when supportsEffort lists none; supportsThinkingOff, supportsAutoMode, supportsFastMode), the
#     commands (name, description, argumentHint, aliases, plugin) with the local slash table merged in,
#     claude_code_version, fast_mode_state and fast_mode_disabled_reason; then ev_config. The account
#     member is never read
#   claude_commands_changed(AL*, record)    system/commands_changed: the CLI's commands replaced
#   claude_settings_answer(AL*, response)   get_settings' control_response: applied.model, .effort,
#     .ultracodeAvailable and .ultracode (ev_model, ev_effort, ev_ultra); errors, when there are any, as
#     the settings band (the extension's text, webview index.js @5828498); none: the band goes
#   claude_lifecycle(AL*, record)           command_lifecycle: a held message started or will not run
#   claude_replay(AL*, record)              a user record with isReplay: a held message started
#   claude_start_mode(AL*) -> rax cstr|0    a start's --permission-mode, through the bypass gate
#   claude_modes, claude_set_mode, claude_set_model, claude_set_effort, claude_set_ultra,
#     claude_set_thinking: the driver table's entries for the later tasks (0 until then)
#   claude_menu(AS* or 0, APM** out) -> eax n   the command menu's actions (agentpop.s), each with its rule
#   claude_action(AL* or 0, act, ptr, len) -> eax 1 done   the driver's part of a local command: /plan,
#     fast mode (/fast as a prompt), Settings at Claude Code's rows, the help docs (asked before they open)
#
# The JSON values passed in are the parse arena's: everything kept is copied (agentcfg copies), and
# nothing here parses.
.include "rhun.inc"

.equ ERRORS_MAX, 50             # settings errors looked at
.equ R_INFO_ROW, 6              # agents.s's info row (R_INFO)
.equ R_INFO, 6                  # agents.s's info row

.bss
.p2align 3
asb: .zero SB_SIZE              # a command's aliases, joined
effort_sfx: .zero 48            # the Effort row's "(Level)"
bsb: .zero SB_SIZE              # the settings band's text

.text

# FN claude_init_answer(AL*, response object): the lists, the version and fast mode from initialize
FN claude_init_answer
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r13, rax
    mov rdi, r13
    mov esi, AGL_MODELS | AGL_CMDS
    call agentcfg_lists_begin
    mov rdi, r12
    lea rsi, [rip + .Lk_models]
    call json_get
    mov rdi, r13
    mov rsi, rax
    xor edx, edx
    call models_add
    mov rdi, r12                # unrecorded member (the CLI's schema; the fake has it)
    lea rsi, [rip + .Lk_unavailable]
    call json_get
    mov rdi, r13
    mov rsi, rax
    mov edx, AMOF_OFF
    call models_add
    mov rdi, r12
    lea rsi, [rip + .Lk_commands]
    call json_get
    mov rdi, r13
    mov rsi, rax
    call cmds_add
    mov rdi, r13
    call agentcfg_lists_end
    mov rdi, r12
    lea rsi, [rip + .Lk_version]
    call jstr
    test rdx, rdx
    jz 1f
    mov rdi, r13
    mov esi, AGF_VERSION
    mov rcx, rdx
    mov rdx, rax
    call agentcfg_set
1:  mov rdi, r12
    call fast_of
    mov r14d, eax
    mov rdi, r12
    lea rsi, [rip + .Lk_fast_why]
    call jstr
    mov rcx, rdx
    mov rdx, rax
    mov rdi, rbx
    mov esi, r14d
    call ev_fast
    mov rdi, rbx
    call ev_config
    EPILOGUE

# FN claude_commands_changed(AL*, record): system/commands_changed: its list replaces the CLI's commands
FN claude_commands_changed
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_commands]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne 9f                      # not a list: the one there stays
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r13, rax
    mov rdi, rax
    mov esi, AGL_CMDS
    call agentcfg_lists_begin
    mov rdi, r13
    mov rsi, r12
    call cmds_add
    mov rdi, r13
    call agentcfg_lists_end
    mov rdi, rbx
    call ev_config
9:  EPILOGUE

# fast_of(obj) -> eax FS_* of its fast_mode_state ("on", "cooldown"; anything else off)
fast_of:
    PROLOGUE
    lea rsi, [rip + .Lk_fast]
    call json_get
    mov rbx, rax
    mov r12d, FS_ON
    mov rdi, rax
    lea rsi, [rip + .Lv_on]
    call json_is
    test eax, eax
    jnz 9f
    mov r12d, FS_COOLDOWN
    mov rdi, rbx
    lea rsi, [rip + .Lv_cooldown]
    call json_is
    test eax, eax
    jnz 9f
    mov r12d, FS_OFF
9:  mov eax, r12d
    EPILOGUE

# models_add(AGC*, models array or 0, extra AMOF_* flags): each model with its levels
models_add:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov [rsp + 16], edx
    xor r13d, r13d
1:  mov rdi, r12
    call json_len
    cmp r13d, eax
    jae 9f
    mov rdi, r12
    mov esi, r13d
    call json_at
    inc r13d
    mov r14, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne 1b
    mov r15d, [rsp + 16]        # the flags
    mov rdi, r14
    lea rsi, [rip + .Lk_thinkoff]
    mov edx, AMOF_THINKOFF
    call flag_of
    or r15d, eax
    mov rdi, r14
    lea rsi, [rip + .Lk_auto]
    mov edx, AMOF_AUTO
    call flag_of
    or r15d, eax
    mov rdi, r14
    lea rsi, [rip + .Lk_fastmode]
    mov edx, AMOF_FAST
    call flag_of
    or r15d, eax
    mov rdi, r14
    lea rsi, [rip + .Lk_effort]
    mov edx, AMOF_EFFORT
    call flag_of
    or r15d, eax
    mov rdi, r14
    lea rsi, [rip + .Lk_levels]
    call json_get
    mov [rsp + 24], rax         # its levels, or 0
    mov rdi, rax
    call json_len
    test eax, eax
    jz 2f
    or r15d, AMOF_EFFORT
2:  mov rdi, r14
    lea rsi, [rip + .Lk_value]
    call jdup
    mov [rsp], rax
    mov rdi, r14
    lea rsi, [rip + .Lk_display]
    call jdup
    mov [rsp + 8], rax
    cmp byte ptr [rax], 0
    jne 3f
    mov rdi, rax                # no name to show: its value
    call mem_free
    mov rdi, [rsp]
    call strlen
    mov rdi, [rsp]
    mov rsi, rax
    call mem_dup
    mov [rsp + 8], rax
3:  mov rdi, r14
    lea rsi, [rip + .Lk_desc]
    call jdup
    mov r14, rax
    mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    mov rcx, r14
    mov r8d, r15d
    call agentcfg_model
    push rax
    push rax
    mov rdi, [rsp + 16]
    call mem_free
    mov rdi, [rsp + 24]
    call mem_free
    mov rdi, r14
    call mem_free
    pop rax
    pop rax
    test rax, rax
    jz 1b
    mov rdi, rax
    mov rsi, [rsp + 24]
    mov edx, r15d
    call levels_add
    jmp 1b
9:  EPILOGUE

# levels_add(AMO*, levels array or 0, flags): its effort levels: the list's, else low, medium and high
#   when it has effort
levels_add:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r15d, edx
    mov rdi, rsi
    call json_len
    test eax, eax
    jnz 3f
    test r15d, AMOF_EFFORT
    jz 9f
    lea r13, [rip + default_levels]
1:  mov r14, [r13]
    test r14, r14
    jz 9f
    mov rdi, r14
    call effort_label
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r14
    call agentcfg_level
    add r13, 8
    jmp 1b
3:  xor r13d, r13d
4:  mov rdi, r12
    call json_len
    cmp r13d, eax
    jae 9f
    mov rdi, r12
    mov esi, r13d
    call json_at
    inc r13d
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 4b
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r14, rax
    mov rdi, rax
    call effort_label
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r14
    call agentcfg_level
    mov rdi, r14
    call mem_free
    jmp 4b
9:  EPILOGUE

# FN claude_effort_label(id cstr) -> rax its label: Low, Medium, High, Extra high, Max, anything else Auto
FN claude_effort_label
effort_label:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rip + effort_labels]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jnz 2f
    add r12, 16
    jmp 1b
2:  mov rax, [r12 + 8]
    EPILOGUE
8:  lea rax, [rip + .Le_auto]
    EPILOGUE

# flag_of(obj, key, flag) -> eax flag when the member is true, else 0
flag_of:
    PROLOGUE
    mov ebx, edx
    call json_get
    mov rdi, rax
    call json_bool
    test eax, eax
    jz 9f
    mov eax, ebx
9:  EPILOGUE

# cmds_add(AGC*, commands array or 0): each command the CLI advertises (ACMF_CLI; one of the local
#   table's names runs its target: ACMF_LOCAL with its act), then the local table's others
cmds_add:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  mov rdi, r12
    call json_len
    cmp r13d, eax
    jae 5f
    mov rdi, r12
    mov esi, r13d
    call json_at
    inc r13d
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    call jstr
    test rdx, rdx
    jz 1b
    mov [rsp + 48], rax         # the name
    mov [rsp + 56], rdx
    mov rdi, rax                # the local table's: its act
    mov rsi, rdx
    call local_of
    mov r15, rax
    mov rdi, r14
    call aliases_of
    mov [rsp + 8], rax          # owned or 0
    mov rdi, r14
    call origin_of
    mov [rsp + 16], rax         # owned or 0
    mov qword ptr [rsp + 24], ACT_SEND
    mov qword ptr [rsp + 32], ACMF_CLI
    test r15, r15
    jz 2f
    mov eax, [r15 + 24]
    mov [rsp + 24], rax
    mov qword ptr [rsp + 32], ACMF_CLI | ACMF_LOCAL
2:  mov rdi, r14
    lea rsi, [rip + .Lk_hint]
    call jstr
    mov [rsp], rdx
    mov [rsp + 40], rax
    mov rdi, r14
    lea rsi, [rip + .Lk_description]
    call jstr
    mov rcx, rax
    mov r8, rdx
    mov r9, [rsp + 40]
    mov rdi, rbx
    mov rsi, [rsp + 48]
    mov rdx, [rsp + 56]
    call agentcfg_cmd
    mov rdi, [rsp + 8]
    call mem_free
    mov rdi, [rsp + 16]
    call mem_free
    jmp 1b
5:  lea r15, [rip + local_cmds]  # the local table's commands the CLI does not advertise
6:  mov r14, [r15]
    test r14, r14
    jz 9f
    mov rdi, r14
    call strlen
    mov r13, rax
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r13
    call agentcfg_find_cmd
    test rax, rax
    jz 7f
    mov rdi, [rax + ACM_name]
    mov rsi, r14
    call strcmp_eq
    test eax, eax
    jnz 8f
7:  mov rdi, [r15 + 16]
    call strlen
    mov [rsp], rax
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
    mov eax, [r15 + 24]
    mov [rsp + 24], rax
    mov qword ptr [rsp + 32], ACMF_LOCAL
    mov rdi, [r15 + 8]
    call strlen
    mov r8, rax
    mov rcx, [r15 + 8]
    mov r9, [r15 + 16]
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r13
    call agentcfg_cmd
8:  add r15, 32
    jmp 6b
9:  EPILOGUE

# local_of(ptr, len) -> rax the local table's entry of that name, or 0
local_of:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + local_cmds]
1:  mov rdx, [rbx]
    test rdx, rdx
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 9f
    add rbx, 32
    jmp 1b
8:  xor ebx, ebx
9:  mov rax, rbx
    EPILOGUE

# aliases_of(command) -> rax its aliases joined by spaces (owned), or 0
aliases_of:
    PROLOGUE
    lea rsi, [rip + .Lk_aliases]
    call json_get
    mov rbx, rax
    lea rdi, [rip + asb]
    call sb_clear
    xor r12d, r12d
1:  mov rdi, rbx
    call json_len
    cmp r12d, eax
    jae 3f
    mov rdi, rbx
    mov esi, r12d
    call json_at
    inc r12d
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 1b
    mov r13, rax
    mov r14, rdx
    cmp qword ptr [rip + asb + SB_len], 0
    je 2f
    lea rdi, [rip + asb]
    mov esi, ' '
    call sb_push_byte
2:  lea rdi, [rip + asb]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    jmp 1b
3:  xor eax, eax
    cmp qword ptr [rip + asb + SB_len], 0
    je 9f
    mov rdi, [rip + asb + SB_ptr]
    mov rsi, [rip + asb + SB_len]
    call mem_dup
9:  EPILOGUE

# origin_of(command) -> rax its plugin's name (owned: a string, or an object's "name"), or 0
origin_of:
    PROLOGUE
    lea rsi, [rip + .Lk_plugin]
    call json_get
    mov rbx, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne 1f
    mov rdi, rbx
    lea rsi, [rip + .Lk_name]
    call json_get
    mov rbx, rax
1:  mov rdi, rbx
    call json_str
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN claude_settings_answer(AL*, control_response's response): get_settings' applied values, and its
#   errors as the settings band
FN claude_settings_answer
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_success]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_response]
    call json_get
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_applied]
    call json_get
    mov r13, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne 5f
    mov rdi, r13
    lea rsi, [rip + .Lk_model]
    call jstr
    test rdx, rdx
    jz 1f
    mov rdi, rbx
    mov rsi, rax
    call ev_model
1:  mov rdi, r13
    lea rsi, [rip + .Lk_effort_applied]
    call jstr
    test rdx, rdx
    jz 2f
    mov rdi, rbx
    mov rsi, rax
    call ev_effort
2:  mov rdi, r13
    lea rsi, [rip + .Lk_ultra_ok]
    mov edx, 1
    call flag_of
    mov r14d, eax
    mov rdi, r13
    lea rsi, [rip + .Lk_ultra]
    mov edx, 1
    call flag_of
    mov edx, eax
    mov rdi, rbx
    mov esi, r14d
    call ev_ultra
5:  mov rdi, r12
    lea rsi, [rip + .Lk_errors]
    call json_get
    mov r13, rax
    mov rdi, rax
    call json_len
    test eax, eax
    jnz 6f
    mov rdi, rbx                # none: the band goes
    mov esi, BK_SETTINGS
    xor edx, edx
    xor ecx, ecx
    call ev_band
    EPILOGUE
6:  mov rdi, r13
    call band_text
    mov rdi, rbx
    mov esi, BK_SETTINGS
    mov rdx, [rip + bsb + SB_ptr]
    mov rcx, [rip + bsb + SB_len]
    call ev_band
9:  EPILOGUE

# band_text(errors array): bsb = "Settings file failed to parse: FILE — MESSAGE (+N more file|files).
#   Permission rules and other settings from this file|these files are not in effect." (the files
#   counted once each)
band_text:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + bsb]
    call sb_clear
    mov rdi, rbx
    xor esi, esi
    call json_at
    mov r12, rax                # the first error
    mov rdi, rbx
    call files_count
    mov r13d, eax
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lb_head]
    call sb_push_cstr
    mov rdi, r12
    call err_file
    test rdx, rdx
    jnz 1f
    lea rax, [rip + .Lb_unknown]
    mov edx, 7
1:  lea rdi, [rip + bsb]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lb_dash]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Lk_message]
    call jstr
    lea rdi, [rip + bsb]
    mov rsi, rax
    call sb_push
    cmp r13d, 1
    jbe 3f
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lb_more]
    call sb_push_cstr
    lea rdi, [rip + bsb]
    lea esi, [r13 - 1]
    call sb_push_u64
    lea rsi, [rip + .Lb_file]
    cmp r13d, 2
    je 2f
    lea rsi, [rip + .Lb_files]
2:  lea rdi, [rip + bsb]
    call sb_push_cstr
3:  lea rdi, [rip + bsb]
    lea rsi, [rip + .Lb_rules]
    call sb_push_cstr
    lea rsi, [rip + .Lb_this]
    cmp r13d, 1
    jbe 4f
    lea rsi, [rip + .Lb_these]
4:  lea rdi, [rip + bsb]
    call sb_push_cstr
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lb_tail]
    call sb_push_cstr
    EPILOGUE

# err_file(error) -> rax ptr, rdx len: its "path" (the CLI's schema), else its "file" (the extension's)
err_file:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_path]
    call jstr
    test rdx, rdx
    jnz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_file]
    call jstr
9:  EPILOGUE

# files_count(errors array) -> eax how many different files they name (the first ERRORS_MAX looked at)
files_count:
    PROLOGUE 16
    mov rbx, rdi
    call json_len
    cmp eax, ERRORS_MAX
    jbe 1f
    mov eax, ERRORS_MAX
1:  mov r12d, eax
    xor r13d, r13d              # the error
    xor r14d, r14d              # files
2:  cmp r13d, r12d
    jae 9f
    mov rdi, rbx
    mov esi, r13d
    call json_at
    mov rdi, rax
    call err_file
    mov [rsp], rax
    mov [rsp + 8], rdx
    xor r15d, r15d              # an earlier one names it
3:  cmp r15d, r13d
    jae 5f
    mov rdi, rbx
    mov esi, r15d
    call json_at
    mov rdi, rax
    call err_file
    inc r15d
    cmp rdx, [rsp + 8]
    jne 3b
    mov rdi, rax
    mov rsi, [rsp]
    call memeq
    test eax, eax
    jz 3b
    jmp 6f
5:  inc r14d
6:  inc r13d
    jmp 2b
9:  mov eax, r14d
    EPILOGUE

# jstr(obj, key) -> rax ptr, rdx len of a string member (0, 0 when it is none)
jstr:
    push rbx
    call json_get
    mov rdi, rax
    call json_str
    pop rbx
    ret

# jdup(obj, key) -> rax an owned copy of a string member ("" when it is none)
jdup:
    push rbx
    call jstr
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    pop rbx
    ret

# ---- messages during a turn (task 3) ----

# FN claude_lifecycle(AL*, record): command_lifecycle {command_uuid, state} (finding 17): started -> the held
#   message's row joins (ev_started); cancelled, discarded, refused -> it will not run (ev_dropped); queued
#   and completed say nothing new. A uuid rhun does not hold (a message shown at once, one started) is
#   nothing (the events look it up). refused and discarded have no recording (the CLI's schema has them)
FN claude_lifecycle
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    lea rsi, [rip + .Lk_command_uuid]
    call jstr
    test rdx, rdx
    jz 9f
    mov r13, rax
    mov r14, rdx
    mov rdi, r12
    lea rsi, [rip + .Lk_state]
    call json_get
    mov r15, rax
    mov rdi, rax
    lea rsi, [rip + .Lv_started]
    call json_is
    test eax, eax
    jz 1f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call ev_started
    EPILOGUE
1:  lea r12, [rip + dropped_states]
2:  mov rsi, [r12]
    test rsi, rsi
    jz 9f
    add r12, 8
    mov rdi, r15
    call json_is
    test eax, eax
    jz 2b
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call ev_dropped
9:  EPILOGUE

# FN claude_replay(AL*, record): a user record with isReplay (finding 17): the CLI echoes each message as
#   its turn starts; its uuid, when rhun holds it, says it started (as command_lifecycle's started, whichever
#   comes first)
FN claude_replay
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_uuid]
    call jstr
    test rdx, rdx
    jz 9f
    mov rdi, rbx
    mov rsi, rax
    call ev_started
9:  EPILOGUE

# FN claude_start_mode(AL*) -> rax the --permission-mode value of a start (a cstr), or 0 for the CLI's own:
#   the conversation's kept mode, else (initial_mode empty) the project's remembered default, else
#   initial_mode. bypassPermissions only with [claude] allow_bypass_permissions: without it default, and an
#   info row says why
FN claude_start_mode
    PROLOGUE
    mov rbx, rdi
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r12, rax
    mov rdi, rax
    lea rsi, [rbx + AL_sid]
    call agentcfg_conv_mode
    test rax, rax
    jnz 5f
    cmp dword ptr [rip + cfg_claude_initial_mode], 0
    jne 2f
    lea rax, [r12 + AGC_newmode]
    cmp byte ptr [rax], 0
    jne 5f
2:  call claude_mode_gated
    test eax, eax
    jnz 7f
    call claude_mode
    EPILOGUE
5:  mov r13, rax                # a kept mode: through the gate too
    mov rdi, rax
    lea rsi, [rip + .Lv_bypass]
    call strcmp_eq
    test eax, eax
    jz 6f
    cmp dword ptr [rip + cfg_claude_allow_bypass], 0
    je 7f
6:  mov rax, r13
    EPILOGUE
7:  lea rdi, [rip + .Lbypass_off]
    call strlen
    mov rdi, rbx
    mov esi, R_INFO_ROW
    lea rdx, [rip + .Lbypass_off]
    mov rcx, rax
    call ev_note
    lea rax, [rip + .Lv_default]
    EPILOGUE

# ---- the driver table's entries for later tasks ----

# FN claude_modes(AS*, AMD** out) -> eax 0; claude_set_mode(AL*, id), claude_set_model(AL*, value),
#   claude_set_effort(AL*, id), claude_set_ultra(AL*, on), claude_set_thinking(AL*, on), claude_action(AL*,
#   act, ptr, len) -> eax 0: nothing asked yet
FN claude_modes
    xor eax, eax
    ret
FN claude_set_mode
    xor eax, eax
    ret
FN claude_set_model
    xor eax, eax
    ret
FN claude_set_effort
    xor eax, eax
    ret
FN claude_set_ultra
    xor eax, eax
    ret
FN claude_set_thinking
    xor eax, eax
    ret

# ---- the command menu (agentpop.s) and local commands ----

# FN claude_menu(AS* or 0, APM** out) -> eax n: the command menu's actions (menu_tbl)
FN claude_menu
    lea rax, [rip + menu_tbl]
    mov [rsi], rax
    lea rax, [rip + menu_end]
    lea rcx, [rip + menu_tbl]
    sub rax, rcx
    xor edx, edx
    mov ecx, APM_SIZE
    div ecx
    ret

# cur_model(AS* or 0) -> rax the model the menu names (AMO*): the project's choice, else the one in effect,
#   else the first listed; 0 without a list
cur_model:
    PROLOGUE
    mov rbx, rdi
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r12, rax
    lea r13, [r12 + AGC_model]
    cmp byte ptr [r13], 0
    jne 1f
    xor r13d, r13d
    test rbx, rbx
    jz 2f
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 2f
    lea r13, [rax + AL_model]
    cmp byte ptr [r13], 0
    je 2f
1:  mov rdi, r13
    call strlen
    mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    call agentcfg_find_model
    test rax, rax
    jnz 9f
2:  xor eax, eax
    cmp qword ptr [r12 + AGC_models + VEC_len], 0
    je 9f
    mov rax, [r12 + AGC_models + VEC_ptr]
    mov rax, [rax]
9:  EPILOGUE

# shows_model(AS* or 0, kind) -> eax 1, rdx the current model's name (its label, else the value in effect)
shows_model:
    PROLOGUE
    mov rbx, rdi
    call cur_model
    xor edx, edx
    test rax, rax
    jz 1f
    mov rdx, [rax + AMO_label]
    jmp 9f
1:  test rbx, rbx
    jz 9f
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 9f
    cmp byte ptr [rax + AL_model], 0
    je 9f
    lea rdx, [rax + AL_model]
9:  xor ecx, ecx
    xor r8d, r8d
    mov eax, 1
    EPILOGUE

# shows_thinking(AS* or 0, kind) -> eax 1 when the model lets thinking be switched off (supportsThinkingOff),
#   ecx APRF_ON while it is on
shows_thinking:
    PROLOGUE
    mov rbx, rdi
    call cur_model
    xor r12d, r12d
    test rax, rax
    jz 9f
    test dword ptr [rax + AMO_flags], AMOF_THINKOFF
    jz 9f
    mov r12d, 1
    mov ecx, APRF_ON            # on unless the conversation or the project has it off
    test rbx, rbx
    jz 1f
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 1f
    cmp dword ptr [rax + AL_think], 0
    jne 8f
    xor ecx, ecx
    jmp 8f
1:  mov edi, AG_CLAUDE
    call agentcfg_get
    mov ecx, APRF_ON
    cmp dword ptr [rax + AGC_think], 0
    jne 8f
    xor ecx, ecx
    jmp 8f
9:  xor ecx, ecx
8:  xor edx, edx
    xor r8d, r8d
    mov eax, r12d
    EPILOGUE

# shows_effort(AS* or 0, kind) -> eax 1 when the model has effort levels; rdx "(Level)" of the level in
#   effect (the conversation's, else the project's) or 0, r8 its id
shows_effort:
    PROLOGUE
    mov rbx, rdi
    call cur_model
    xor r12d, r12d
    xor r13d, r13d              # the suffix
    xor r14d, r14d              # the id
    test rax, rax
    jz 9f
    cmp qword ptr [rax + AMO_levels + VEC_len], 0
    je 9f
    mov r15, rax
    mov r12d, 1
    test rbx, rbx
    jz 1f
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 1f
    lea r14, [rax + AL_effort]
    cmp byte ptr [r14], 0
    jne 2f
1:  mov edi, AG_CLAUDE
    call agentcfg_get
    lea r14, [rax + AGC_effort]
    cmp byte ptr [r14], 0
    jne 2f
    xor r14d, r14d
    jmp 9f
2:  xor ebx, ebx                # its label among the model's levels, else the usual words
3:  cmp rbx, [r15 + AMO_levels + VEC_len]
    jae 4f
    imul rax, rbx, AEL_SIZE
    add rax, [r15 + AMO_levels + VEC_ptr]
    inc rbx
    mov r13, [rax + AEL_label]
    mov rdi, [rax + AEL_id]
    mov rsi, r14
    call strcmp_eq
    test eax, eax
    jnz 5f
    jmp 3b
4:  mov rdi, r14
    call effort_label
    mov r13, rax
5:  lea rdi, [rip + effort_sfx]
    mov byte ptr [rdi], '('
    inc rdi
    xor ecx, ecx
6:  movzx eax, byte ptr [r13 + rcx]
    test eax, eax
    jz 7f
    cmp ecx, 40
    jae 7f
    mov [rdi + rcx], al
    inc ecx
    jmp 6b
7:  mov byte ptr [rdi + rcx], ')'
    mov byte ptr [rdi + rcx + 1], 0
    lea r13, [rip + effort_sfx]
9:  mov rdx, r13
    mov r8, r14
    xor ecx, ecx
    mov eax, r12d
    EPILOGUE

# shows_ultra(AS* or 0, kind) -> eax 1 when the conversation's program offers Ultracode, ecx APRF_ON while on
shows_ultra:
    xor eax, eax
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    test rdi, rdi
    jz 9f
    mov rdi, [rdi + AS_live]
    test rdi, rdi
    jz 9f
    mov esi, [rdi + AL_ultra]
    test esi, esi
    js 9f
    mov eax, 1
    cmp esi, 1
    jne 9f
    mov ecx, APRF_ON
9:  ret

# shows_fast(AS* or 0, kind) -> eax 1 when the model has fast mode and the program does not say an SDK must
#   opt in first (fast_mode_disabled_reason sdk_opt_in_required, as 2.1.330 reports: then it is left out)
shows_fast:
    PROLOGUE
    call cur_model
    xor ebx, ebx
    test rax, rax
    jz 9f
    test dword ptr [rax + AMO_flags], AMOF_FAST
    jz 9f
    mov edi, AG_CLAUDE
    call agentcfg_get
    lea rdi, [rax + AGC_fastwhy]
    lea rsi, [rip + .Lv_opt_in]
    call strcmp_eq
    test eax, eax
    jnz 9f
    mov ebx, 1
9:  mov eax, ebx
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    EPILOGUE

# FN claude_action(AL* or 0, act, ptr, len) -> eax 1 when it was done: ACT_PLAN (/plan [TEXT]: plan mode,
#   then TEXT as a prompt; already in it: the extension's info row), ACT_FAST (/fast as a prompt),
#   ACT_SETTINGS (Settings at Claude Code's rows), ACT_HELP (the extension's help docs, open_help in
#   extension.js @3355805, asked before they open); anything else 0
FN claude_action
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, ACT_SETTINGS
    je .Lca_settings
    cmp r12d, ACT_HELP
    je .Lca_help
    test rbx, rbx
    jz .Lca_no
    cmp r12d, ACT_FAST
    je .Lca_fast
    cmp r12d, ACT_PLAN
    jne .Lca_no
    lea rdi, [rbx + AL_mode]    # /plan
    lea rsi, [rip + .Lv_plan]
    call strcmp_eq
    test eax, eax
    jz 1f
    lea rdx, [rip + .Lp_already]
    jmp .Lca_note
1:  mov rdi, rbx
    lea rsi, [rip + .Lv_plan]
    call claude_set_mode
    test eax, eax
    jnz 2f
    lea rdx, [rip + .Lp_couldnt]    # "Couldn't switch to plan mode[; not sent: TEXT]"
    test r14, r14
    jz .Lca_note
    lea rdi, [rip + bsb]
    call sb_clear
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lp_couldnt]
    call sb_push_cstr
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lp_not_sent]
    call sb_push_cstr
    lea rdi, [rip + bsb]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    mov rdi, rbx
    mov esi, R_INFO
    mov rdx, [rip + bsb + SB_ptr]
    mov rcx, [rip + bsb + SB_len]
    call ev_note
    jmp .Lca_yes
2:  test r14, r14               # a description goes as a prompt ("open" and "share" do not)
    jz .Lca_yes
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lv_open]
    call str_eq_cstr
    test eax, eax
    jnz .Lca_yes
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lv_share]
    call str_eq_cstr
    test eax, eax
    jnz .Lca_yes
    mov rdi, [rbx + AL_as]
    mov rsi, r13
    mov rdx, r14
    call agent_send
    jmp .Lca_yes
.Lca_note:
    mov rdi, rdx
    call strlen
    mov rcx, rax
    mov rdx, rdi
    mov rdi, rbx
    mov esi, R_INFO
    call ev_note
    jmp .Lca_yes
.Lca_fast:
    mov rdi, [rbx + AL_as]
    lea rsi, [rip + .Lv_fast_cmd]
    mov edx, 5
    call agent_send
    jmp .Lca_yes
.Lca_settings:
    lea rdi, [rip + .Lv_section]
    mov esi, 7
    call settings_open_search
    jmp .Lca_yes
.Lca_help:
    lea rdi, [rip + .Lv_who]
    lea rsi, [rip + .Lv_help_url]
    call links_ask_open
.Lca_yes:
    mov eax, 1
    EPILOGUE
.Lca_no:
    xor eax, eax
    EPILOGUE

.section .rodata
.p2align 3
default_levels: .quad .Le_low_id, .Le_medium_id, .Le_high_id, 0
dropped_states: .quad .Lv_cancelled, .Lv_discarded, .Lv_refused, 0     # a held message will not run
effort_labels:
    .quad .Le_low_id, .Le_low, .Le_medium_id, .Le_medium, .Le_high_id, .Le_high
    .quad .Le_xhigh_id, .Le_xhigh, .Le_max_id, .Le_max, 0, 0
# the local slash table (ext-webview-ui.md 1.24, 1.25): name, description, argument hint, act
# the command menu's actions (ext-webview-ui.md 1.24): section, act, label, description, kind, flags, rule
menu_tbl:
    .long APS_CONTEXT, ACT_CLEAR
    .quad .Lm_clear, .Lm_clear_d
    .long APK_ROW, 0
    .quad 0
    .long APS_CONTEXT, ACT_NEW
    .quad .Lm_new, .Lm_new_d
    .long APK_ROW, APRF_FILTERONLY
    .quad 0
    .long APS_MODEL, ACT_MODEL
    .quad .Lm_model, .Ld_model
    .long APK_ROW, 0
    .quad shows_model
    .long APS_MODEL, ACT_MODES
    .quad .Lm_modes, .Lm_modes_d
    .long APK_ROW, 0
    .quad 0
    .long APS_MODEL, ACT_THINKING
    .quad .Lm_think, .Lm_think_d
    .long APK_SWITCH, 0
    .quad shows_thinking
    .long APS_MODEL, ACT_EFFORT
    .quad .Lm_effort, .Lm_effort_d
    .long APK_LEVELS, 0
    .quad shows_effort
    .long APS_MODEL, ACT_ULTRA
    .quad .Lm_ultra, .Lm_ultra_d
    .long APK_SWITCH, 0
    .quad shows_ultra
    .long APS_MODEL, ACT_FAST
    .quad .Lm_fast, .Lm_fast_d
    .long APK_ROW, 0
    .quad shows_fast
    .long APS_CUSTOMIZE, ACT_TERMINAL
    .quad .Lm_term, .Lm_term_d
    .long APK_ROW, 0
    .quad 0
    .long APS_SETTINGS, ACT_SETTINGS
    .quad .Lm_settings, .Lm_settings_d
    .long APK_ROW, 0
    .quad 0
    .long APS_SETTINGS, ACT_SIGNIN
    .quad .Lm_signin, .Ld_login
    .long APK_ROW, 0
    .quad 0
    .long APS_SETTINGS, ACT_SIGNOUT
    .quad .Lm_signout, .Ld_logout
    .long APK_ROW, 0
    .quad 0
    .long APS_SUPPORT, ACT_HELP
    .quad .Lm_help, .Lm_help_d
    .long APK_ROW, 0
    .quad 0
menu_end:
local_cmds:
    .quad .Ln_clear, .Ld_clear, .Lempty, ACT_CLEAR
    .quad .Ln_model, .Ld_model, .Lempty, ACT_MODEL
    .quad .Ln_plan, .Ld_plan, .Lh_plan, ACT_PLAN
    .quad .Ln_copy, .Ld_copy, .Lh_copy, ACT_COPY
    .quad .Ln_login, .Ld_login, .Lempty, ACT_SIGNIN
    .quad .Ln_logout, .Ld_logout, .Lempty, ACT_SIGNOUT
    .quad 0, 0, 0, 0
.Lempty: .asciz ""
.Ln_clear: .asciz "clear"
.Ld_clear: .asciz "Start a new conversation"
.Ln_model: .asciz "model"
.Ld_model: .asciz "Change the AI model"
.Ln_plan: .asciz "plan"
.Ld_plan: .asciz "Turn on plan mode or view the plan"
.Lh_plan: .asciz "[open|<description>]"
.Ln_copy: .asciz "copy"
.Ld_copy: .asciz "Copy the last response to clipboard (/copy 2 for the one before)"
.Lh_copy: .asciz "[N]"
.Ln_login: .asciz "login"
.Ld_login: .asciz "Log in with a different account"
.Ln_logout: .asciz "logout"
.Ld_logout: .asciz "Sign out of Claude on this computer"
.Lm_clear: .asciz "Clear conversation"
.Lm_clear_d: .asciz "Start a new conversation"
.Lm_new: .asciz "New conversation"
.Lm_new_d: .asciz "Open a new conversation in a new tab or the sidebar"
.Lm_model: .asciz "Switch model\342\200\246"
.Lm_modes: .asciz "Switch mode\342\200\246"
.Lm_modes_d: .asciz "Change the permission mode"
.Lm_think: .asciz "Thinking"
.Lm_think_d: .asciz "Toggle extended thinking mode"
.Lm_effort: .asciz "Effort"
.Lm_effort_d: .asciz "Set how hard the model tries"
.Lm_ultra: .asciz "Ultracode"
.Lm_ultra_d: .asciz "Run dynamic workflows on every task (this session only)"
.Lm_fast: .asciz "Toggle fast mode"
.Lm_fast_d: .asciz "Toggle fast mode for faster responses"
.Lm_term: .asciz "Open Claude in Terminal"
.Lm_term_d: .asciz "Open a new Claude instance in the Terminal"
.Lm_settings: .asciz "General config\342\200\246"
.Lm_settings_d: .asciz "Open Claude Code's settings"
.Lm_signin: .asciz "Switch account"
.Lm_signout: .asciz "Sign out"
.Lm_help: .asciz "View help docs"
.Lm_help_d: .asciz "Open help documentation"
.Lp_already: .asciz "Already in plan mode. No plan written yet."
.Lp_couldnt: .asciz "Couldn't switch to plan mode"
.Lp_not_sent: .asciz "; not sent: "
.Lv_plan: .asciz "plan"
.Lv_open: .asciz "open"
.Lv_share: .asciz "share"
.Lv_fast_cmd: .asciz "/fast"
.Lv_opt_in: .asciz "sdk_opt_in_required"
.Lv_section: .asciz "claude."
.Lv_who: .asciz "Claude Code"
.Lv_help_url: .asciz "https://code.claude.com/docs/en/vs-code"
.Le_low_id: .asciz "low"
.Le_medium_id: .asciz "medium"
.Le_high_id: .asciz "high"
.Le_xhigh_id: .asciz "xhigh"
.Le_max_id: .asciz "max"
.Le_low: .asciz "Low"
.Le_medium: .asciz "Medium"
.Le_high: .asciz "High"
.Le_xhigh: .asciz "Extra high"
.Le_max: .asciz "Max"
.Le_auto: .asciz "Auto"
.Lk_models: .asciz "models"
.Lk_unavailable: .asciz "unavailable_models"
.Lk_commands: .asciz "commands"
.Lk_version: .asciz "claude_code_version"
.Lk_fast: .asciz "fast_mode_state"
.Lk_fast_why: .asciz "fast_mode_disabled_reason"
.Lk_thinkoff: .asciz "supportsThinkingOff"
.Lk_auto: .asciz "supportsAutoMode"
.Lk_fastmode: .asciz "supportsFastMode"
.Lk_effort: .asciz "supportsEffort"
.Lk_levels: .asciz "supportedEffortLevels"
.Lk_value: .asciz "value"
.Lk_display: .asciz "displayName"
.Lk_desc: .asciz "description"
.Lk_description: .asciz "description"
.Lk_name: .asciz "name"
.Lk_hint: .asciz "argumentHint"
.Lk_aliases: .asciz "aliases"
.Lk_plugin: .asciz "plugin"
.Lk_subtype: .asciz "subtype"
.Lk_response: .asciz "response"
.Lk_applied: .asciz "applied"
.Lk_model: .asciz "model"
.Lk_effort_applied: .asciz "effort"
.Lk_ultra_ok: .asciz "ultracodeAvailable"
.Lk_ultra: .asciz "ultracode"
.Lk_errors: .asciz "errors"
.Lk_message: .asciz "message"
.Lk_path: .asciz "path"
.Lk_file: .asciz "file"
.Lk_command_uuid: .asciz "command_uuid"
.Lk_state: .asciz "state"
.Lk_uuid: .asciz "uuid"
.Lv_started: .asciz "started"
.Lv_cancelled: .asciz "cancelled"
.Lv_discarded: .asciz "discarded"
.Lv_refused: .asciz "refused"
.Lv_bypass: .asciz "bypassPermissions"
.Lv_default: .asciz "default"
.Lbypass_off: .asciz "Bypass permissions is off in Settings > Claude Code."
.Lv_success: .asciz "success"
.Lv_on: .asciz "on"
.Lv_cooldown: .asciz "cooldown"
.Lb_head: .asciz "Settings file failed to parse: "
.Lb_unknown: .asciz "unknown"
.Lb_dash: .asciz " \342\200\224 "
.Lb_more: .asciz " (+"
.Lb_file: .asciz " more file)"
.Lb_files: .asciz " more files)"
.Lb_rules: .asciz ". Permission rules and other settings from "
.Lb_this: .asciz "this file"
.Lb_these: .asciz "these files"
.Lb_tail: .asciz " are not in effect."
