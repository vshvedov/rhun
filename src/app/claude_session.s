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
#   claude_modes(AS* or 0, AMD** out) -> eax n, rdx the current mode's AMD* or 0   the modes offered now
#     (ext-webview-ui.md 2.1, 2.2): default, acceptEdits, plan; dontAsk first only while it is current; auto
#     last while the model supports it (or it is current) and no policy forbids it; bypassPermissions last
#     only through rhun's gate ([claude] allow_bypass_permissions) and no policy against it. The current
#     one: the mode in effect, else the conversation's kept one, else what its start would pass
#   claude_set_mode(AL*, id) -> eax 1 asked  running: set_permission_mode (the label follows at once, the
#     answer settles it); starting: asked once initialize is answered; else kept for the next start. Bypass
#     only through the gate
#   claude_mode_answer(AL*, response, picked), claude_init_mode(AL*, ptr, len) -> rax ptr, rdx len,
#     claude_init_ask(AL*)                  set_permission_mode's answers, a pick made while it started
#   claude_set_model(AL*, value), claude_set_effort(AL*, id), claude_set_ultra(AL*, on),
#     claude_set_thinking(AL*, on) -> eax 1 taken: the project's choices (see "model, effort, Ultracode,
#     thinking" below); claude_flags_answer(AL*, response, CLF_*) their answers; claude_started(AL*) a
#     start written; claude_record(AL*, record) a system or result record (fast mode's state)
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
.equ MODES_N, 6                 # mode_tbl's entries
.equ CLP_NOAUTO, 1              # AL_cfg: get_settings' effective settings forbid auto mode,
.equ CLP_NOBYPASS, 2            #   bypassPermissions;
.equ CLP_MODEWAIT, 4            #   a mode was picked while the program started (claude_init_mode)
.equ CLP_WAITMODEL, 8           #   a model, an effort level was picked while it started (apply_kept);
.equ CLP_WAITEFFORT, 16
.equ CLP_FIRST, 32              #   its first get_settings answer has not come yet;
.equ CLP_CREDITS, 64            #   fast mode's requests were refused for want of usage credits;
.equ CLP_SUMMARIES, 128         #   the effective settings' showThinkingSummaries
.equ CLF_MODEL, 0               # what apply_flag_settings or set_max_thinking_tokens asked (cl_apply,
.equ CLF_EFFORT, 1              #   cl_thinking: agent_claude.s's OA_FLAGS + these)
.equ CLF_ULTRA, 2
.equ CLF_THINK, 3
.equ THINK_TOKENS, 31999        # thinking on (finding 14; --max-thinking-tokens=31999 at a start)

.bss
.p2align 3
fl_al: .quad 0                  # the model the user picked while the program ran: its AL and value (the pill
fl_model: .zero 64              #   once it is applied)
ul_on: .long 0                  # Ultracode asked on (1) or off: the failure's words
.p2align 3
fast_why: .zero 32              # the reason fast mode is off, kept while a record names none
credit_txt: .zero 256           # the notification that refused fast mode's requests
asb: .zero SB_SIZE              # a command's aliases, joined
effort_sfx: .zero 48            # the Effort row's "(Level)"
offered: .zero AMD_SIZE * MODES_N   # claude_modes' list
prev_al: .quad 0                # the last pick asked of a running program: its AL and the mode before it
prev_mode: .zero 32             #   (a refusal puts it back)
pend_al: .quad 0                # a pick made while the program started, asked once initialize is answered
pend_mode: .zero 32
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

# models_add(AGC*, models array or 0, extra AMOF_* flags): each model with its levels and the id the program
#   reports for it (resolvedModel: get_settings' applied.model names that)
models_add:
    PROLOGUE 48
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
    mov [rsp + 32], r14         # the model's object
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
    mov [rsp + 40], rax
    mov rdi, [rsp + 32]
    lea rsi, [rip + .Lk_resolved]
    call jdup
    mov r14, rax
    mov rdi, [rsp + 40]
    mov rsi, rax
    call agentcfg_resolved
    mov rdi, r14
    call mem_free
    mov rdi, [rsp + 40]
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
    xor r14d, r14d              # Ultracode offered, and on
    xor r15d, r15d
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
    mov r15d, eax
    mov edx, eax
    mov rdi, rbx
    mov esi, r14d
    call ev_ultra
5:  mov rdi, rbx                # the policies the modes follow (effective settings)
    mov rsi, r12
    call policies
    mov rdi, rbx                # the first answer of a process: the choices it has not taken yet
    mov esi, r14d
    mov edx, r15d
    call apply_kept
    mov rdi, r12
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

# policies(AL*, get_settings' response): AL_cfg's CLP_NOAUTO (effective.permissions.disableAutoMode or
#   effective.disableAutoMode "disable") and CLP_NOBYPASS (effective.permissions.disableBypassPermissionsMode
#   "disable"), as the extension reads them (webview index.js @3779200, @3421530)
policies:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_effective]
    call json_get
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_permissions]
    call json_get
    mov r13, rax
    and dword ptr [rbx + AL_cfg], ~(CLP_NOAUTO | CLP_NOBYPASS | CLP_SUMMARIES)
    mov rdi, r12                # showThinkingSummaries: thinking turned on again asks for summaries
    lea rsi, [rip + .Lk_summaries]
    mov edx, CLP_SUMMARIES
    call flag_of
    or [rbx + AL_cfg], eax
    mov rdi, r13
    lea rsi, [rip + .Lk_no_auto]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_disable]
    call json_is
    test eax, eax
    jnz 1f
    mov rdi, r12
    lea rsi, [rip + .Lk_no_auto]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_disable]
    call json_is
    test eax, eax
    jz 2f
1:  or dword ptr [rbx + AL_cfg], CLP_NOAUTO
2:  mov rdi, r13
    lea rsi, [rip + .Lk_no_bypass]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_disable]
    call json_is
    test eax, eax
    jz 3f
    or dword ptr [rbx + AL_cfg], CLP_NOBYPASS
3:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

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

# ---- permission modes (task 5) ----

# mode_entry(id cstr) -> rax its mode_tbl entry (AMD), or 0 for an unknown id
mode_entry:
    PROLOGUE
    mov r12, rdi
    lea rbx, [rip + mode_tbl]
    xor r13d, r13d
    test r12, r12
    jz 8f
1:  cmp r13d, MODES_N
    jae 8f
    mov rdi, r12
    mov rsi, [rbx + AMD_id]
    call strcmp_eq
    test eax, eax
    jnz 9f
    add rbx, AMD_SIZE
    inc r13d
    jmp 1b
8:  xor ebx, ebx
9:  mov rax, rbx
    EPILOGUE

# bypass_ok(AL* or 0) -> eax 1 when bypassPermissions may be offered, passed or asked for: rhun's gate
#   ([claude] allow_bypass_permissions) and no policy against it
bypass_ok:
    xor eax, eax
    cmp dword ptr [rip + cfg_claude_allow_bypass], 0
    je 9f
    mov eax, 1
    test rdi, rdi
    jz 9f
    test dword ptr [rdi + AL_cfg], CLP_NOBYPASS
    jz 9f
    xor eax, eax
9:  ret

# gated(mode cstr) -> rax the mode, or default for bypassPermissions without the gate
gated:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lv_bypass]
    call strcmp_eq
    test eax, eax
    jz 9f
    xor edi, edi
    call bypass_ok
    test eax, eax
    jnz 9f
    lea rbx, [rip + .Lv_default]
9:  mov rax, rbx
    EPILOGUE

# cur_mode(AS* or 0) -> rax the conversation's mode (a cstr), or 0 when nothing says: the mode in effect
#   (AL_mode: the program's report or the user's pick), else the conversation's kept one (once the record is
#   read; nothing is read for it), else what a start would pass (the project's remembered default when
#   initial_mode is empty, else initial_mode); a kept bypassPermissions without the gate is default, as a
#   start passes it
cur_mode:
    PROLOGUE
    mov rbx, rdi
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r13, rax
    test rbx, rbx
    jz 3f
    mov r12, [rbx + AS_live]
    test r12, r12
    jz 3f
    lea rax, [r12 + AL_mode]
    cmp byte ptr [rax], 0
    jne 9f
    cmp byte ptr [r12 + AL_sid], 0
    je 3f
    mov rdi, r13
    lea rsi, [r12 + AL_sid]
    call agentcfg_conv_mode
    test rax, rax
    jnz 5f
3:  cmp dword ptr [rip + cfg_claude_initial_mode], 0
    jne 4f
    lea rax, [r13 + AGC_newmode]
    cmp byte ptr [rax], 0
    jne 5f
4:  call claude_mode
    EPILOGUE
5:  mov rdi, rax
    call gated
9:  EPILOGUE

# FN claude_modes(AS* or 0, AMD** out) -> eax how many modes are offered now (in Shift+Tab's order, the
#   current one flagged AMDF_CURRENT), rdx the current mode's entry (shown even when it is not offered) or 0
FN claude_modes
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    call cur_mode
    mov r12, rax                # the current mode's id, or 0
    xor r14d, r14d              # its entry
    test rax, rax
    jz 1f
    mov rdi, rax
    call mode_entry
    mov r14, rax
1:  xor r13d, r13d              # offered
    mov rdi, r12
    lea rsi, [rip + .Lv_dont_ask]
    call is_mode
    test eax, eax
    jz 2f
    lea rdi, [rip + .Lv_dont_ask]
    call offer
2:  lea rdi, [rip + .Lv_default]
    call offer
    lea rdi, [rip + .Lv_accept]
    call offer
    lea rdi, [rip + .Lv_plan]
    call offer
    xor eax, eax                # auto: no policy against it, and the model has it or it is current
    test rbx, rbx
    jz 3f
    mov rax, [rbx + AS_live]
3:  test rax, rax
    jz 4f
    test dword ptr [rax + AL_cfg], CLP_NOAUTO
    jnz 6f
4:  mov rdi, r12
    lea rsi, [rip + .Lv_auto]
    call is_mode
    test eax, eax
    jnz 5f
    mov rdi, rbx
    call cur_model
    test rax, rax
    jz 6f
    test dword ptr [rax + AMO_flags], AMOF_AUTO
    jz 6f
5:  lea rdi, [rip + .Lv_auto]
    call offer
6:  xor edi, edi                # bypassPermissions: rhun's gate, and no policy against it
    test rbx, rbx
    jz 7f
    mov rdi, [rbx + AS_live]
7:  call bypass_ok
    test eax, eax
    jz 8f
    lea rdi, [rip + .Lv_bypass]
    call offer
8:  mov rax, [rsp]
    lea rcx, [rip + offered]
    mov [rax], rcx
    mov eax, r13d
    mov rdx, r14
    EPILOGUE

# is_mode(id cstr or 0, mode cstr) -> eax 1 when they are the same
is_mode:
    xor eax, eax
    test rdi, rdi
    jz 1f
    jmp strcmp_eq
1:  ret

# offer(id cstr) using claude_modes' r12 (the current id) and r13 (the count): its entry next in offered,
#   AMDF_CURRENT when it is the current one
offer:
    push rbx
    push r14
    push r15
    mov r15, rdi
    call mode_entry
    mov rbx, rax
    imul r14, r13, AMD_SIZE
    lea rcx, [rip + offered]
    add r14, rcx
    mov rax, [rbx + AMD_id]
    mov [r14 + AMD_id], rax
    mov rax, [rbx + AMD_label]
    mov [r14 + AMD_label], rax
    mov rax, [rbx + AMD_desc]
    mov [r14 + AMD_desc], rax
    mov eax, [rbx + AMD_color]
    mov [r14 + AMD_color], eax
    mov dword ptr [r14 + AMD_flags], 0
    mov rdi, r12
    mov rsi, r15
    call is_mode
    test eax, eax
    jz 1f
    mov dword ptr [r14 + AMD_flags], AMDF_CURRENT
1:  inc r13d
    pop r15
    pop r14
    pop rbx
    ret

# FN claude_set_mode(AL*, id cstr) -> eax 1 when it was asked for or kept: running, set_permission_mode
#   (cl_set_mode; the label follows at once, the answer settles it: claude_mode_answer); starting, kept and
#   asked once initialize is answered; else kept for the conversation's next start (nothing starts). An
#   unknown id, and bypassPermissions without the gate, are refused (0)
FN claude_set_mode
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call mode_entry
    test rax, rax
    jz .Lsm_no
    mov rdi, r12
    lea rsi, [rip + .Lv_bypass]
    call strcmp_eq
    test eax, eax
    jz 1f
    mov rdi, rbx
    call bypass_ok
    test eax, eax
    jz .Lsm_no
1:  mov rdi, r12
    call strlen
    mov r13, rax
    mov eax, [rbx + AL_state]
    cmp eax, ALS_READY
    je 2f
    cmp eax, ALS_WORKING
    je 2f
    cmp eax, ALS_WAITING
    je 2f
    cmp eax, ALS_STARTING       # not running: kept for its start (the start passes it), and the label
    jne 3f
    or dword ptr [rbx + AL_cfg], CLP_MODEWAIT   # (a process starting now is asked once it answers)
3:  mov rdi, rbx
    call claude_sid
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call ev_mode
    mov rdi, rbx                # the user's pick is the conversation's
    call agent_mode_keep
    mov rdi, r12
    call picked_default
    jmp .Lsm_yes
2:  cmp dword ptr [rbx + AL_cn + CN_state], CN_UP
    jne 3b
    mov [rip + prev_al], rbx    # what a refusal puts back
    lea rdi, [rip + prev_mode]
    lea rsi, [rbx + AL_mode]
    call cstr_copy
    mov rdi, rbx
    mov rsi, r12
    call cl_set_mode
    test eax, eax
    jz .Lsm_no
    mov rdi, rbx                # the label follows at once (Shift+Tab goes on from it)
    mov rsi, r12
    mov rdx, r13
    call ev_mode
    mov rdi, rbx
    call agent_mode_keep
.Lsm_yes:
    mov eax, 1
    EPILOGUE
.Lsm_no:
    xor eax, eax
    EPILOGUE

# picked_default(id cstr): a mode the user picked among default, auto and acceptEdits is the project's
#   default for new conversations when [claude] initial_mode is empty (agentcfg's newmode)
picked_default:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + cfg_claude_initial_mode], 0
    jne 9f
    lea r12, [rip + default_modes]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 9f
    add r12, 8
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jz 1b
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r12, rax
    mov rdi, rbx
    call strlen
    mov rcx, rax
    mov rdi, r12
    mov esi, AGF_NEWMODE
    mov rdx, rbx
    call agentcfg_set
    mov rdi, r12
    call agentcfg_save
9:  EPILOGUE

# FN claude_mode_answer(AL*, control_response's response, picked): set_permission_mode's answer {"mode": M}
#   is the mode in effect (a request for the mode in force gets no status line: finding 10); a pick
#   also becomes the project's default (picked_default). Refused, a pick's toast says why ("Failed to set
#   mode: …") and the mode before it comes back
FN claude_mode_answer
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r15d, edx
    mov rdi, rsi
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_success]
    call json_is
    test eax, eax
    jz 5f
    mov rdi, r12
    lea rsi, [rip + .Lk_response]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_mode]
    call jstr
    test rdx, rdx
    jz 9f
    cmp rdx, 31
    ja 9f
    mov r13, rax
    mov r14, rdx
    mov rdi, rbx
    mov rsi, rax
    call ev_mode
    test r15d, r15d
    jz 9f
    lea rdi, [rbx + AL_mode]    # (ev_mode's copy, not the parse arena's text)
    call picked_default
    EPILOGUE
5:  test r15d, r15d
    jz 9f
    lea rdi, [rip + bsb]
    call sb_clear
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lm_failed]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Lk_error]
    call jstr
    lea rdi, [rip + bsb]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + bsb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + bsb + SB_ptr]
    call app_toast
    cmp [rip + prev_al], rbx
    jne 9f
    mov qword ptr [rip + prev_al], 0
    lea rdi, [rip + prev_mode]
    call strlen
    mov rdx, rax
    mov rdi, rbx
    lea rsi, [rip + prev_mode]
    call ev_mode
9:  EPILOGUE

# FN claude_init_mode(AL*, mode ptr, len) -> rax ptr, rdx len: the mode to show once initialize is answered:
#   a pick made while the program started (when it differs from the one it started in: it is asked for by
#   claude_init_ask), else the one it reports
FN claude_init_mode
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test dword ptr [rbx + AL_cfg], CLP_MODEWAIT
    jz 9f
    and dword ptr [rbx + AL_cfg], ~CLP_MODEWAIT
    lea r14, [rbx + AL_mode]    # the pick (AL_mode holds it until initialize's report)
    cmp byte ptr [r14], 0
    je 9f
    mov rdi, r14
    call strlen
    cmp rax, r13
    jne 1f
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jnz 9f                      # it started in it
1:  mov rdi, r14
    call mode_entry
    test rax, rax
    jz 9f
    mov [rip + pend_al], rbx
    lea rdi, [rip + pend_mode]
    mov rsi, r14
    call cstr_copy
    lea r12, [rip + pend_mode]
    mov rdi, r12
    call strlen
    mov r13, rax
9:  mov rax, r12
    mov rdx, r13
    EPILOGUE

# FN claude_init_ask(AL*): the pick claude_init_mode kept is asked for (through the gate), before any prompt
FN claude_init_ask
    PROLOGUE
    mov rbx, rdi
    cmp [rip + pend_al], rbx
    jne 9f
    mov qword ptr [rip + pend_al], 0
    lea rdi, [rip + pend_mode]
    lea rsi, [rip + .Lv_bypass]
    call strcmp_eq
    test eax, eax
    jz 1f
    mov rdi, rbx
    call bypass_ok
    test eax, eax
    jz 9f
1:  mov qword ptr [rip + prev_al], 0
    mov rdi, rbx
    lea rsi, [rip + pend_mode]
    call cl_set_mode
9:  EPILOGUE

# ---- model, effort, Ultracode, thinking (task 6) ----
#
# Each is the project's own choice (agentcfg: kept in rhun's state file, never in Claude Code's settings),
# taken at once. A program that runs is asked with apply_flag_settings (model, effortLevel, ultracode:
# this process only, finding 13) or set_max_thinking_tokens (finding 14), then get_settings reads what is
# in effect; one that starts is asked once its first get_settings answer came (apply_kept); otherwise the
# next start passes them (--model, --effort, --thinking=disabled: cl_start). update_settings is never sent.
# Other conversations of the project take a choice at their next start.

# live_up(AL*) -> eax 1 when its program runs and can be asked (ready, working, waiting, connected)
live_up:
    xor eax, eax
    mov ecx, [rdi + AL_state]
    cmp ecx, ALS_READY
    jb 9f
    cmp ecx, ALS_WAITING
    ja 9f
    cmp dword ptr [rdi + AL_cn + CN_state], CN_UP
    jne 9f
    mov eax, 1
9:  ret

# record() -> rax the project's record, read (every pick is a writer's action)
record:
    PROLOGUE
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov rbx, rax
    mov rdi, rax
    call agentcfg_need
    mov rax, rbx
    EPILOGUE

# FN claude_set_model(AL*, value cstr) -> eax 1 when it is the project's model now: one of the listed,
#   not unavailable. Running: asked at once (the pill follows it, "Switched to NAME" once applied)
FN claude_set_model
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call record
    mov r13, rax
    mov rdi, r12
    call strlen
    mov r14, rax
    test rax, rax
    jz .Lsmo_no
    cmp rax, 63
    ja .Lsmo_no
    mov rdi, r13
    mov rsi, r12
    mov rdx, r14
    call agentcfg_find_model
    test rax, rax
    jz .Lsmo_no
    test dword ptr [rax + AMO_flags], AMOF_OFF
    jnz .Lsmo_no
    mov rdi, r13
    mov esi, AGF_MODEL
    mov rdx, r12
    mov rcx, r14
    call agentcfg_set
    mov rdi, r13
    call agentcfg_save
    mov rdi, rbx
    call live_up
    test eax, eax
    jz 3f
    mov [rip + fl_al], rbx      # the pill once it is applied
    lea rdi, [rip + fl_model]
    mov rsi, r12
    call cstr_copy
    mov rdi, rbx
    mov esi, CLF_MODEL
    lea rdx, [rip + .Lk_model]
    mov rcx, r12
    call cl_apply
    test eax, eax
    jz .Lsmo_yes                # the write broke the connection: its close says so
    mov rdi, rbx                # the footer follows the pick at once; get_settings settles it
    mov rsi, r12
    mov rdx, r14
    call ev_model
    jmp .Lsmo_yes
3:  cmp dword ptr [rbx + AL_state], ALS_STARTING
    jne .Lsmo_yes
    or dword ptr [rbx + AL_cfg], CLP_WAITMODEL
.Lsmo_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lsmo_no:
    xor eax, eax
    EPILOGUE

# FN claude_set_effort(AL*, id cstr) -> eax 1 when it is the project's effort level now: one of the
#   conversation's model's levels. Running: asked at once, shown at once
FN claude_set_effort
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call record
    mov r13, rax
    mov rdi, r12
    call strlen
    mov r14, rax
    test rax, rax
    jz .Lse_no
    cmp rax, 15
    ja .Lse_no
    mov rdi, [rbx + AL_as]
    call cur_model
    test rax, rax
    jz .Lse_no
    mov rdi, rax
    mov rsi, r12
    call level_index
    test eax, eax
    js .Lse_no
    mov rdi, r13
    mov esi, AGF_EFFORT
    mov rdx, r12
    mov rcx, r14
    call agentcfg_set
    mov rdi, r13
    call agentcfg_save
    mov rdi, rbx
    call live_up
    test eax, eax
    jz 3f
    mov rdi, rbx
    mov esi, CLF_EFFORT
    lea rdx, [rip + .Lk_effort_level]
    mov rcx, r12
    call cl_apply
    test eax, eax
    jz .Lse_yes
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call ev_effort
    jmp .Lse_yes
3:  cmp dword ptr [rbx + AL_state], ALS_STARTING
    jne .Lse_yes
    or dword ptr [rbx + AL_cfg], CLP_WAITEFFORT
.Lse_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lse_no:
    xor eax, eax
    EPILOGUE

# level_index(AMO*, id cstr) -> eax the level's index among the model's, -1 when it has none of that id
level_index:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13, [rbx + AMO_levels + VEC_len]
    jae 8f
    imul rax, r13, AEL_SIZE
    add rax, [rbx + AMO_levels + VEC_ptr]
    mov rdi, [rax + AEL_id]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 9f
    inc r13
    jmp 1b
8:  mov r13d, -1
9:  mov eax, r13d
    EPILOGUE

# FN claude_set_ultra(AL*, on) -> eax 1 when it is the project's choice now. A program that runs and does
#   not offer it (get_settings' applied.ultracodeAvailable) refuses it; one that offers it is asked at once
FN claude_set_ultra
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
    test esi, esi
    setnz r12b
    call record
    mov r13, rax
    mov rdi, rbx
    call live_up
    mov r14d, eax
    test eax, eax
    jz 1f
    cmp dword ptr [rbx + AL_ultra], 0
    jl .Lsu_no
1:  mov rdi, r13
    mov esi, AGF_ULTRA
    mov edx, r12d
    call agentcfg_set
    mov rdi, r13
    call agentcfg_save
    test r14d, r14d
    jz .Lsu_yes
    mov [rip + ul_on], r12d
    mov rdi, rbx
    mov esi, CLF_ULTRA
    lea rdx, [rip + .Lk_ultra]
    xor ecx, ecx
    mov r8d, r12d
    call cl_apply
    test eax, eax
    jz .Lsu_yes
    mov rdi, rbx
    mov esi, 1
    mov edx, r12d
    call ev_ultra
.Lsu_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lsu_no:
    xor eax, eax
    EPILOGUE

# FN claude_set_thinking(AL*, on) -> eax 1 when it is the project's choice now: only for a model that lets
#   thinking be switched off (supportsThinkingOff). Running: set_max_thinking_tokens, 31999 (with
#   thinking_display "summarized", or null, as showThinkingSummaries says) or 0
FN claude_set_thinking
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
    test esi, esi
    setnz r12b
    call record
    mov r13, rax
    mov rdi, [rbx + AL_as]
    call cur_model
    test rax, rax
    jz .Lst_no
    test dword ptr [rax + AMO_flags], AMOF_THINKOFF
    jz .Lst_no
    mov rdi, r13
    mov esi, AGF_THINK
    mov edx, r12d
    call agentcfg_set
    mov rdi, r13
    call agentcfg_save
    mov rdi, rbx
    mov esi, r12d
    call ev_thinking
    mov rdi, rbx
    call live_up
    test eax, eax
    jz 1f
    xor edx, edx
    test dword ptr [rbx + AL_cfg], CLP_SUMMARIES
    setnz dl
    mov rdi, rbx
    mov esi, r12d
    call cl_thinking
1:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lst_no:
    xor eax, eax
    EPILOGUE

# FN claude_started(AL*): a start of the program was written: what its first answers must settle (the
#   picks made while it starts, the project's Ultracode), its thinking as the start passed it
FN claude_started
    PROLOGUE
    mov rbx, rdi
    and dword ptr [rbx + AL_cfg], ~(CLP_WAITMODEL | CLP_WAITEFFORT | CLP_CREDITS)
    or dword ptr [rbx + AL_cfg], CLP_FIRST
    mov edi, AG_CLAUDE
    call agentcfg_get
    xor ecx, ecx
    cmp dword ptr [rax + AGC_think], 0
    setne cl
    mov [rbx + AL_think], ecx
    EPILOGUE

# apply_kept(AL*, Ultracode offered, on): the first get_settings answer of a process: a model and an effort
#   level picked while it started are asked for now, and the project's Ultracode when it differs from the
#   one in effect
apply_kept:
    PROLOGUE
    mov rbx, rdi
    mov r14d, esi
    mov r15d, edx
    test dword ptr [rbx + AL_cfg], CLP_FIRST
    jz 9f
    mov r12d, [rbx + AL_cfg]
    and dword ptr [rbx + AL_cfg], ~(CLP_FIRST | CLP_WAITMODEL | CLP_WAITEFFORT)
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r13, rax
    test r12d, CLP_WAITMODEL
    jz 1f
    cmp byte ptr [r13 + AGC_model], 0
    je 1f
    mov qword ptr [rip + fl_al], 0
    mov rdi, rbx
    mov esi, CLF_MODEL
    lea rdx, [rip + .Lk_model]
    lea rcx, [r13 + AGC_model]
    call cl_apply
    test eax, eax
    jz 9f
1:  test r12d, CLP_WAITEFFORT
    jz 2f
    cmp byte ptr [r13 + AGC_effort], 0
    je 2f
    mov rdi, rbx
    mov esi, CLF_EFFORT
    lea rdx, [rip + .Lk_effort_level]
    lea rcx, [r13 + AGC_effort]
    call cl_apply
    test eax, eax
    jz 9f
2:  test r14d, r14d
    jz 9f
    mov eax, [r13 + AGC_ultra]
    test eax, eax
    js 9f
    cmp eax, r15d
    je 9f
    mov [rip + ul_on], eax
    mov rdi, rbx
    mov esi, CLF_ULTRA
    lea rdx, [rip + .Lk_ultra]
    xor ecx, ecx
    mov r8d, eax
    call cl_apply
9:  EPILOGUE

# FN claude_flags_answer(AL*, control_response's response, kind CLF_*): apply_flag_settings' or
#   set_max_thinking_tokens' answer. Done: a picked model's pill row ("Switched to NAME"), then what is in
#   effect is read again (get_settings); refused: the toast says why ("Failed to set model: …", "Failed to
#   set effort: …", "Failed to turn Ultracode on: …" / "off: …", "Failed to set thinking: …") and what is
#   in effect is read again
FN claude_flags_answer
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rdi, rsi
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_success]
    call json_is
    test eax, eax
    jz 5f
    cmp r13d, CLF_MODEL
    jne 4f
    cmp [rip + fl_al], rbx
    jne 4f
    mov qword ptr [rip + fl_al], 0
    lea rdi, [rip + bsb]        # "Switched to NAME" (webview index.js @5967170)
    call sb_clear
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lp_switched]
    call sb_push_cstr
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r14, rax
    lea rdi, [rip + fl_model]
    call strlen
    mov rdi, r14
    lea rsi, [rip + fl_model]
    mov rdx, rax
    call agentcfg_find_model
    lea rsi, [rip + fl_model]
    test rax, rax
    jz 3f
    mov rsi, [rax + AMO_label]
3:  lea rdi, [rip + bsb]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + bsb + SB_ptr]
    mov rdx, [rip + bsb + SB_len]
    call ev_pill
4:  cmp r13d, CLF_THINK
    je 9f
    mov rdi, rbx
    call claude_get_settings
    EPILOGUE
5:  lea rdi, [rip + bsb]
    call sb_clear
    lea rax, [rip + fail_words]
    mov rsi, [rax + r13*8]
    cmp r13d, CLF_ULTRA
    jne 6f
    lea rsi, [rip + .Lf_ultra_off]
    cmp dword ptr [rip + ul_on], 0
    je 6f
    lea rsi, [rip + .Lf_ultra_on]
6:  lea rdi, [rip + bsb]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Lk_error]
    call jstr
    lea rdi, [rip + bsb]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + bsb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + bsb + SB_ptr]
    call app_toast
    cmp r13d, CLF_THINK
    je 9f
    mov rdi, rbx                # what is in effect comes back
    call claude_get_settings
9:  EPILOGUE

# FN claude_record(AL*, record): a system or result record: its fast_mode_state (and reason when it names
#   one) is fast mode's state; system/notification "fast-mode-overage-rejected" (usage credits are
#   unavailable) is noted, and when fast mode then turns off the toast of the extension says why (webview
#   index.js @3762100; rhun never turns it off itself: it sends no "/fast off" the user did not type). The
#   notification has no recording (the CLI binary's text)
FN claude_record
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_notification]
    call json_is
    test eax, eax
    jz 2f
    mov rdi, r12
    lea rsi, [rip + .Lk_key]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_overage]
    call json_is
    test eax, eax
    jz 9f
    or dword ptr [rbx + AL_cfg], CLP_CREDITS
    mov byte ptr [rip + credit_txt], 0
    mov rdi, r12
    lea rsi, [rip + .Lk_text]
    call jstr
    test rdx, rdx
    jz 9f
    mov r13, rax
    mov rdi, rdx                # at most 200 bytes, cut at a character
    mov rsi, rax
    mov edx, 200
    call utf8_cut
    lea rdi, [rip + credit_txt]
    mov rsi, r13
    mov rdx, rax
    mov byte ptr [rdi + rdx], 0
    call memmove
    jmp 9f
2:  mov rdi, r12
    lea rsi, [rip + .Lk_fast]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 9f                       # no state named: nothing changes
    mov rdi, r12
    call fast_of
    mov r13d, eax
    mov edi, AG_CLAUDE          # its reason: the record's when it names one, else the one kept
    call agentcfg_get
    lea rdi, [rip + fast_why]
    lea rsi, [rax + AGC_fastwhy]
    call cstr_copy
    mov rdi, r12
    lea rsi, [rip + .Lk_fast_why]
    call json_get
    test rax, rax               # absent: the one kept; null: none
    jz 3f
    mov byte ptr [rip + fast_why], 0
    mov rdi, r12
    lea rsi, [rip + .Lk_fast_why]
    call jstr
    cmp rdx, 31
    ja 3f
    lea rdi, [rip + fast_why]
    mov rsi, rax
    mov byte ptr [rdi + rdx], 0
    call memmove
3:  cmp r13d, FS_OFF            # it turned off after usage credits ran out: the toast
    jne 4f
    cmp dword ptr [rbx + AL_fast], FS_OFF
    je 4f
    test dword ptr [rbx + AL_cfg], CLP_CREDITS
    jz 4f
    and dword ptr [rbx + AL_cfg], ~CLP_CREDITS
    lea rdi, [rip + bsb]
    call sb_clear
    lea rsi, [rip + .Lfast_off]
    lea rdi, [rip + credit_txt]
    cmp byte ptr [rdi], 0
    je 31f
    call credit_head            # "TEXT. Type /fast on …" (the text without its last ".")
    lea rsi, [rip + .Lfast_back]
31: lea rdi, [rip + bsb]
    call sb_push_cstr
    lea rdi, [rip + bsb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + bsb + SB_ptr]
    call app_toast
4:  lea rdi, [rip + fast_why]
    call strlen
    mov rcx, rax
    mov rdi, rbx
    mov esi, r13d
    lea rdx, [rip + fast_why]
    call ev_fast
9:  EPILOGUE

# credit_head(): bsb = the refusal's text, trimmed, without a last "." and with ". " after it
credit_head:
    PROLOGUE
    lea rdi, [rip + credit_txt]
    call strlen
    mov rbx, rax
    lea rdi, [rip + credit_txt]
    mov rsi, rax
    call trim
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 1f
    cmp byte ptr [r12 + r13 - 1], '.'
    jne 1f
    dec r13
1:  lea rdi, [rip + bsb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lp_dot_sp]
    call sb_push_cstr
    EPILOGUE

# think_on(AS* or 0) -> eax 1 when thinking is on: the program's (AL_think) while it runs, else the
#   project's choice (unset: on)
think_on:
    PROLOGUE
    test rdi, rdi
    jz 1f
    mov rbx, [rdi + AS_live]
    test rbx, rbx
    jz 1f
    mov rdi, rbx
    call live_up
    test eax, eax
    jz 1f
    mov eax, [rbx + AL_think]
    EPILOGUE
1:  mov edi, AG_CLAUDE
    call agentcfg_get
    xor ecx, ecx
    cmp dword ptr [rax + AGC_think], 0
    setne cl
    mov eax, ecx
    EPILOGUE

# effort_step(AL*, how ptr, len): the effort level "+" one up, "-" one down (each stops at the end), "~" the
#   next one round (the row's label: "Click to cycle effort level"), anything else that level's id
effort_step:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r13, 1
    je 1f
    cmp r13, 15                 # an id
    ja 9f
    lea rdi, [rsp]
    mov rsi, r12
    mov rdx, r13
    mov byte ptr [rdi + rdx], 0
    call memmove
    mov rdi, rbx
    lea rsi, [rsp]
    call claude_set_effort
    EPILOGUE
1:  mov rdi, [rbx + AL_as]
    call cur_model
    test rax, rax
    jz 9f
    mov r14, rax
    mov r15, [r14 + AMO_levels + VEC_len]
    test r15, r15
    jz 9f
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov rdi, [rbx + AL_as]
    mov rsi, rax
    mov rdx, r14
    call agentcfg_effort
    mov ecx, -1                 # its index, -1 none
    test rax, rax
    jz 2f
    sub rax, [r14 + AMO_levels + VEC_ptr]
    xor edx, edx
    mov ecx, AEL_SIZE
    div rcx
    mov ecx, eax
2:  movzx eax, byte ptr [r12]
    mov edx, ecx
    cmp eax, '+'
    jne 3f
    inc edx
    cmp edx, r15d
    jb 5f
    lea edx, [r15 - 1]
    jmp 5f
3:  cmp eax, '-'
    jne 4f
    dec edx
    jns 5f
    xor edx, edx
    jmp 5f
4:  inc edx                     # "~": round
    cmp edx, r15d
    jb 5f
    xor edx, edx
5:  cmp edx, ecx
    je 9f
    imul rax, rdx, AEL_SIZE
    add rax, [r14 + AMO_levels + VEC_ptr]
    mov rdi, rbx
    mov rsi, [rax + AEL_id]
    call claude_set_effort
9:  EPILOGUE

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

# cur_model(AS* or 0) -> rax the model the conversation uses (AMO*: agentcfg_current, the footer's pill),
#   else the first listed; 0 without a list
cur_model:
    PROLOGUE
    mov rbx, rdi
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r12, rax
    mov rdi, rbx
    mov rsi, rax
    call agentcfg_current
    test rax, rax
    jnz 9f
    cmp qword ptr [r12 + AGC_models + VEC_len], 0
    je 9f
    mov rax, [r12 + AGC_models + VEC_ptr]
    mov rax, [rax]
9:  EPILOGUE

# shows_model(AS* or 0, kind) -> eax 1, rdx the current model's name (its label, else the value in effect)
shows_model:
    PROLOGUE
    mov rbx, rdi
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov rdi, rbx
    mov rsi, rax
    call agentcfg_current
    test rdx, rdx
    jnz 9f
    mov rdi, rbx
    call cur_model
    xor edx, edx
    test rax, rax
    jz 9f
    mov rdx, [rax + AMO_label]
9:  xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    mov eax, 1
    EPILOGUE

# shows_thinking(AS* or 0, kind) -> eax 1 when the model lets thinking be switched off (supportsThinkingOff),
#   ecx APRF_ON while it is on (think_on)
shows_thinking:
    PROLOGUE
    mov rbx, rdi
    call cur_model
    xor r12d, r12d
    xor r13d, r13d
    test rax, rax
    jz 9f
    test dword ptr [rax + AMO_flags], AMOF_THINKOFF
    jz 9f
    mov r12d, 1
    mov rdi, rbx
    call think_on
    test eax, eax
    jz 9f
    mov r13d, APRF_ON
9:  mov ecx, r13d
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov eax, r12d
    EPILOGUE

# shows_effort(AS* or 0, kind) -> eax 1 when the model has effort levels; rdx "(Level)" of the level in
#   effect (agentcfg_effort) or 0, r8 its id, r9 the model (its levels: the row's track)
shows_effort:
    PROLOGUE
    mov rbx, rdi
    call cur_model
    xor r12d, r12d
    xor r13d, r13d              # the suffix
    xor r14d, r14d              # the id
    mov r15, rax
    test rax, rax
    jz 9f
    cmp qword ptr [rax + AMO_levels + VEC_len], 0
    je 9f
    mov r12d, 1
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r15
    call agentcfg_effort
    test rax, rax
    jz 9f
    mov r14, [rax + AEL_id]
    mov r13, [rax + AEL_label]
    cmp byte ptr [r13], 0
    jne 5f
    mov rdi, r14
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
    mov r9, r15
    xor ecx, ecx
    mov eax, r12d
    EPILOGUE

# shows_ultra(AS* or 0, kind) -> eax 1 when the conversation's program offers Ultracode, ecx APRF_ON while on
shows_ultra:
    xor eax, eax
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
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
    xor r9d, r9d
    EPILOGUE

# FN claude_action(AL* or 0, act, ptr, len) -> eax 1 when it was done: ACT_PLAN (/plan [TEXT]: plan mode,
#   then TEXT as a prompt; already in it: the extension's info row), ACT_FAST (/fast as a prompt),
#   ACT_EFFORT (the effort row: "+", "-", "~" or a level's id, effort_step),
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
    cmp r12d, ACT_EFFORT        # the effort row: a step, a round, or a level's id
    jne 11f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call effort_step
    jmp .Lca_yes
11: cmp r12d, ACT_PLAN
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
default_modes: .quad .Lv_default, .Lv_auto, .Lv_accept, 0    # a pick of these is the project's default
# the permission modes (ext-webview-ui.md 2.1; webview index.js @5779560): id, label, description, the box
#   frame's colour (index.css's data-permission-mode focus rings: the claude-orange default is rhun's accent,
#   acceptEdits the foreground, plan VS Code's focus border (rhun's info blue: the accent is default's),
#   auto and bypassPermissions the error colour), flags
mode_tbl:
    .quad .Lv_dont_ask, .Lml_dont_ask, .Lmd_dont_ask
    .long T_ACCENT, 0
    .quad .Lv_default, .Lml_default, .Lmd_default
    .long T_ACCENT, 0
    .quad .Lv_accept, .Lml_accept, .Lmd_accept
    .long T_FG, 0
    .quad .Lv_plan, .Lml_plan, .Lmd_plan
    .long T_INFO, 0
    .quad .Lv_auto, .Lml_auto, .Lmd_auto
    .long T_ERROR, 0
    .quad .Lv_bypass, .Lml_bypass, .Lmd_bypass
    .long T_ERROR, 0
.Lv_dont_ask: .asciz "dontAsk"
.Lv_accept: .asciz "acceptEdits"
.Lv_auto: .asciz "auto"
.Lml_dont_ask: .asciz "Don't ask"
.Lmd_dont_ask: .asciz "Claude will deny actions that need approval instead of asking"
.Lml_default: .asciz "Manual"
.Lmd_default: .asciz "Claude will ask for approval before making each edit"
.Lml_accept: .asciz "Edit automatically"
.Lmd_accept: .asciz "Claude will edit your selected text or the whole file"
.Lml_plan: .asciz "Plan"
.Lmd_plan: .asciz "Claude will explore the code and present a plan before editing"
.Lml_auto: .asciz "Auto"
.Lmd_auto: .asciz "Claude will approve actions that pass a safety check and pause for anything risky"
.Lml_bypass: .asciz "Bypass permissions"
.Lmd_bypass: .asciz "Claude will not ask for approval before running potentially dangerous commands"
.Lm_failed: .asciz "Failed to set mode: "
.Lk_effective: .asciz "effective"
.Lk_permissions: .asciz "permissions"
.Lk_no_auto: .asciz "disableAutoMode"
.Lk_no_bypass: .asciz "disableBypassPermissionsMode"
.Lv_disable: .asciz "disable"
.Lk_mode: .asciz "mode"
.Lk_error: .asciz "error"
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
.Lk_resolved: .asciz "resolvedModel"
.Lk_effort_level: .asciz "effortLevel"
.Lk_summaries: .asciz "showThinkingSummaries"
.Lk_key: .asciz "key"
.Lk_text: .asciz "text"
.Lv_notification: .asciz "notification"
.Lv_overage: .asciz "fast-mode-overage-rejected"
.Lp_switched: .asciz "Switched to "
.Lp_dot_sp: .asciz ". "
# fast mode turned off for want of usage credits (webview index.js @3762100: Xen, and Yen after the
#   notification's own text)
.Lfast_off: .asciz "Fast mode was turned off because usage credits are unavailable. Type /fast on in the chat to turn it back on once they are available again."
.Lfast_back: .asciz "Type /fast on in the chat to turn it back on once usage credits are available again."
.Lf_model: .asciz "Failed to set model: "
.Lf_effort: .asciz "Failed to set effort: "
.Lf_ultra_on: .asciz "Failed to turn Ultracode on: "
.Lf_ultra_off: .asciz "Failed to turn Ultracode off: "
.Lf_think: .asciz "Failed to set thinking: "
.p2align 3
fail_words: .quad .Lf_model, .Lf_effort, .Lf_ultra_on, .Lf_think     # by CLF_*
