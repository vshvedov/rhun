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
#   claude_modes, claude_set_mode, claude_set_model, claude_set_effort, claude_set_ultra,
#     claude_set_thinking, claude_action: the driver table's entries for the later tasks (0 until then)
#
# The JSON values passed in are the parse arena's: everything kept is copied (agentcfg copies), and
# nothing here parses.
.include "rhun.inc"

.equ ERRORS_MAX, 50             # settings errors looked at

.bss
.p2align 3
asb: .zero SB_SIZE              # a command's aliases, joined
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
FN claude_action
    xor eax, eax
    ret

.section .rodata
.p2align 3
default_levels: .quad .Le_low_id, .Le_medium_id, .Le_high_id, 0
effort_labels:
    .quad .Le_low_id, .Le_low, .Le_medium_id, .Le_medium, .Le_high_id, .Le_high
    .quad .Le_xhigh_id, .Le_xhigh, .Le_max_id, .Le_max, 0, 0
# the local slash table (ext-webview-ui.md 1.24, 1.25): name, description, argument hint, act
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
