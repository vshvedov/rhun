# Claude Code's configuration and controls (agent_claude.s's driver): what the CLI reports of itself goes
# into the project's record (agentcfg.s) and the conversation's live record through the seam's events.
#
#   claude_init_answer(AL*, response)       initialize's answer (its "response" object): the models and
#     unavailable_models (value, displayName, description, supportedEffortLevels, or low/medium/high
#     when supportsEffort lists none; supportsThinkingOff, supportsAutoMode, supportsFastMode), the
#     commands (name, description, argumentHint, aliases, plugin) with the local slash table merged in,
#     claude_code_version, fast_mode_state and fast_mode_disabled_reason; then ev_config. Of the account
#     only subscriptionType is read, into a bit in memory (a Pro or Max plan: the rate band's "Get more
#     usage"); auth_conflict gives the auth band
#   claude_rate(AL*, record)                rate_limit_event: the rate-limit band (unrecorded statuses: the fake's)
#   claude_frame(AL*, record), claude_asked(AL*)   a main assistant record's usage (the context in use, the
#     prompt cache's clock), a main user record (the request the clock starts from); claude_record reads
#     a result's modelUsage (the context window) and system/compact_boundary
#   claude_commands_changed(AL*, record)    system/commands_changed: the CLI's commands replaced
#   claude_settings_answer(AL*, response)   get_settings' control_response: applied.model, .effort,
#     .ultracodeAvailable and .ultracode (ev_model, ev_effort, ev_ultra); errors, when there are any, as
#     the settings band (the extension's text, webview index.js @5828498); none: the band goes; refused:
#     the error band "Couldn't read Claude Code's settings: ERROR"
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
.equ MODES_N, 6                 # mode_tbl's entries
.equ CLP_NOAUTO, 1              # AL_cfg: get_settings' effective settings forbid auto mode,
.equ CLP_NOBYPASS, 2            #   bypassPermissions;
.equ CLP_MODEWAIT, 4            #   a mode was picked while the program started (claude_init_mode)
.equ CLP_WAITMODEL, 8           #   a model, an effort level was picked while it started (apply_kept);
.equ CLP_WAITEFFORT, 16
.equ CLP_FIRST, 32              #   its first get_settings answer has not come yet;
.equ CLP_CREDITS, 64            #   fast mode's requests were refused for want of usage credits;
.equ CLP_SUMMARIES, 128         #   the effective settings' showThinkingSummaries;
.equ CLP_PAID, 256              #   initialize's account is a Pro or Max plan's (in memory only: account_notes)
.equ CLF_MODEL, 0               # what apply_flag_settings or set_max_thinking_tokens asked (cl_apply,
.equ CLF_EFFORT, 1              #   cl_thinking: agent_claude.s's OA_FLAGS + these)
.equ CLF_ULTRA, 2
.equ CLF_THINK, 3
.equ THINK_TOKENS, 31999        # thinking on (finding 14; --max-thinking-tokens=31999 at a start)
.equ CLP_PREV, 512              # AL_cfg, per conversation (the review of 2026-11-23): AL_dprev is what a
                                #   refused pick puts back (a model asked of the running program: AL_dpicks);
.equ CLP_ULON, 4096             #   Ultracode asked on (its failure's words);
.equ CLP_WAITTHINK, 16384       #   thinking switched while it started (apply_kept); the prompts wait for its
.equ CLP_PROMPTS, 32768         #   first settings answer (prompts_go, at most g_settings_wait_ms); it started
.equ CLP_UNBYPASS, 65536        #   in bypass without rhun's gate (default is asked first); AL_dpend is a pick
.equ CLP_PEND, 131072           #   made while it started, asked once initialize is answered (claude_init_ask);
.equ CLP_PLANWAIT, 262144       #   /plan without a program: get_plan once it is up (prompts_go)
.equ CLP_SPINCOMPACT, 1024      #   the spinner's words: it compacts (system/status compacting),
.equ CLP_SPINHOOK, 2048         #   a start-up hook runs (hook_started of SessionStart or Setup, no answer yet)
.equ CLP_RUN, CLP_MODEWAIT | CLP_WAITMODEL | CLP_WAITEFFORT | CLP_FIRST | CLP_WAITTHINK | CLP_PROMPTS | CLP_UNBYPASS | CLP_PEND | CLP_PLANWAIT | CLP_PREV | CLP_SPINCOMPACT | CLP_SPINHOOK
                                # what a start or a run keeps: claude_ended lets go of it (and AL_dpicks)
.equ SETTINGS_WAIT_MS, 3000     # the prompts wait this long at most for the first get_settings answer
.equ DPICK_N, 4                 # AL_dpicks: the models asked of the running program, by request: {its
.equ DPICK_SIZE, 72             #   number 8 (0: a free slot), the value cstr 64}; a fifth pick before four
.equ DPICK_VAL, 8               #   answers takes the oldest's slot (its answer then settles nothing)

.data
.p2align 2
.globl g_settings_wait_ms
g_settings_wait_ms: .long SETTINGS_WAIT_MS  # agent-timing settings= (tests)

.bss
.p2align 3
.p2align 3
fast_why: .zero 32              # the reason fast mode is off, kept while a record names none
credit_txt: .zero 256           # the notification that refused fast mode's requests
asb: .zero SB_SIZE              # a command's aliases, joined
effort_sfx: .zero 48            # the Effort row's "(Level)"
offered: .zero AMD_SIZE * MODES_N   # claude_modes' list
bsb: .zero SB_SIZE              # the settings band's text
rsb: .zero SB_SIZE              # the rate-limit and auth bands' texts
.globl g_cache_ttl_ms
g_cache_ttl_ms: .long 0         # tests: a prompt cache's lifetime in ms in place of the CLI's (agent-timing cache=)

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
    mov rdi, rbx                # the account's plan (in memory) and the auth band
    mov rsi, r12
    call account_notes
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
#   errors as the settings band; everything is read before anything is written to the program (a write
#   that breaks the connection runs its close, which may parse: the response is gone then). The first
#   answer of a process (or its refusal) then writes the kept choices (apply_kept) and lets the prompts
#   that waited go (prompts_go)
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
    jz .Lsa_refused
    mov rdi, rbx                # read: the error band of a refusal before goes
    mov esi, BK_ERROR
    xor edx, edx
    xor ecx, ecx
    call ev_band
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
    jmp 7f
6:  mov rdi, r13
    call band_text
    mov rdi, rbx
    mov esi, BK_SETTINGS
    mov rdx, [rip + bsb + SB_ptr]
    mov rcx, [rip + bsb + SB_len]
    call ev_band
7:  mov rdi, rbx                # read: the first answer of a process writes the choices it has not taken
    mov esi, r14d               #   yet, then the prompts that waited go
    mov edx, r15d
    call apply_kept
    test eax, eax
    jz 9f                       # (a write refused: the start failed)
    mov rdi, rbx
    call prompts_go
9:  EPILOGUE
.Lsa_refused:                   # refused: the error band says so (its words cut at 300 bytes)
    lea rdi, [rip + bsb]
    call sb_clear
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Le_settings]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Lk_error]
    call jstr
    mov r13, rax
    mov rdi, rdx
    mov rsi, rax
    mov edx, 300
    call utf8_cut
    lea rdi, [rip + bsb]
    mov rsi, r13
    mov rdx, rax
    call sb_push
    mov rdi, rbx
    mov esi, BK_ERROR
    mov rdx, [rip + bsb + SB_ptr]
    mov rcx, [rip + bsb + SB_len]
    call ev_band
    mov rdi, rbx                # the choices still go (nothing says what is in effect), then the prompts
    xor esi, esi
    xor edx, edx
    call apply_kept
    test eax, eax
    jz 9f
    mov rdi, rbx
    call prompts_go
9:  EPILOGUE

# prompts_go(AL*): the prompts that waited for the first get_settings answer (CLP_PROMPTS) go now, once
#   (ev_ready), while the start is still under way and the connection up; then a /plan that started it
#   asks for the plan (CLP_PLANWAIT)
prompts_go:
    PROLOGUE
    mov rbx, rdi
    test dword ptr [rbx + AL_cfg], CLP_PROMPTS
    jz 9f
    and dword ptr [rbx + AL_cfg], ~CLP_PROMPTS
    call starting_up
    test eax, eax
    jz 9f
    mov rdi, rbx
    call ev_ready
    test dword ptr [rbx + AL_cfg], CLP_PLANWAIT
    jz 9f
    and dword ptr [rbx + AL_cfg], ~CLP_PLANWAIT
    cmp dword ptr [rbx + AL_cn + CN_state], CN_UP
    jne 9f
    mov rdi, rbx
    call claude_get_plan
9:  EPILOGUE

# FN claude_prompts_wait(AL*): initialize is answered and get_settings asked: the prompts wait for its
#   answer, g_settings_wait_ms at most (claude_settings_tick)
FN claude_prompts_wait
    PROLOGUE
    mov rbx, rdi
    or dword ptr [rbx + AL_cfg], CLP_PROMPTS
    call time_ms
    mov ecx, [rip + g_settings_wait_ms]
    add rax, rcx
    mov [rbx + AL_dwait], rax
    EPILOGUE

# FN claude_settings_tick(): a get_settings that does not answer in time: the picks made while it started
#   are written without its word and the prompts go; its answer, when it comes, still settles what needs
#   it (the project's Ultracode: CLP_FIRST stays). Only for a start still under way (starting_up)
FN claude_settings_tick
    PROLOGUE
1:  xor ebx, ebx
2:  mov edi, ebx
    call agent_live_at
    test rax, rax
    jz 9f
    inc ebx
    mov r12, rax
    test dword ptr [r12 + AL_cfg], CLP_PROMPTS
    jz 2b
    mov rdi, r12
    call starting_up
    test eax, eax
    jz 2b
    call time_ms
    cmp rax, [r12 + AL_dwait]
    jl 2b
    mov rdi, r12
    call kept_picks
    test eax, eax
    jz 1b                       # (a write refused: the start failed)
    mov rdi, r12
    call prompts_go
    jmp 1b                      # (what went may have changed the list)
9:  EPILOGUE

# FN claude_settings_timeout() -> eax ms until a get_settings answer's wait ends (0: now), -1 when none waits
#   (a start still under way: starting_up)
FN claude_settings_timeout
    PROLOGUE
    mov r13, -1
    xor ebx, ebx
1:  mov edi, ebx
    call agent_live_at
    test rax, rax
    jz 8f
    inc ebx
    mov r12, rax
    test dword ptr [r12 + AL_cfg], CLP_PROMPTS
    jz 1b
    mov rdi, r12
    call starting_up
    test eax, eax
    jz 1b
    call time_ms
    mov rcx, [r12 + AL_dwait]
    sub rcx, rax
    jns 2f
    xor ecx, ecx
2:  cmp r13, -1
    je 3f
    cmp rcx, r13
    jae 1b
3:  mov r13, rcx
    jmp 1b
8:  mov eax, r13d
    EPILOGUE

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
    mov esi, R_INFO
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
    test dword ptr [rbx + AL_cfg], CLP_PROMPTS
    jnz 2f                      # initialize answered, the prompts wait for the settings: asked now
    or dword ptr [rbx + AL_cfg], CLP_MODEWAIT   # (a process starting now is asked once it answers; its
    mov rdi, rbx                #   answer makes it the project's default: claude_mode_answer)
    call claude_sid
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call ev_mode
    mov rdi, rbx
    call agent_mode_keep
    jmp .Lsm_yes
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
    lea rdi, [rbx + AL_dprev]   # what a refusal puts back (this conversation's own)
    lea rsi, [rbx + AL_mode]
    call cstr_copy
    or dword ptr [rbx + AL_cfg], CLP_PREV
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
    test dword ptr [rbx + AL_cfg], CLP_PREV
    jz 9f
    and dword ptr [rbx + AL_cfg], ~CLP_PREV
    lea rdi, [rbx + AL_dprev]
    call strlen
    mov rdx, rax
    mov rdi, rbx
    lea rsi, [rbx + AL_dprev]
    call ev_mode
9:  EPILOGUE

# FN claude_init_mode(AL*, mode ptr or 0, len; 0: none reported) -> rax ptr, rdx len: the mode to show (rax 0:
#   nothing changes; rdx 0: the label waits for the mode's answer):
#   the mode to show once initialize is answered. A start in bypassPermissions without rhun's gate (the
#   user's own default chose it) shows nothing yet: default is asked first (claude_init_ask, CLP_UNBYPASS) and
#   its answer shows. A pick made while the program started (when it differs from the one it started in,
#   through the gate again) is asked by claude_init_ask, the mode it reported kept to put back on a refusal;
#   else the one it reports
FN claude_init_mode
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    and dword ptr [rbx + AL_cfg], ~(CLP_UNBYPASS | CLP_PEND)
    test r13, r13
    jz 1f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lv_bypass]
    call str_eq_cstr
    test eax, eax
    jz 1f
    mov rdi, rbx
    call bypass_ok
    test eax, eax
    jnz 1f
    or dword ptr [rbx + AL_cfg], CLP_UNBYPASS   # the mode it will be in once asked: default
    lea r12, [rip + .Lv_default]
    mov r13d, 7
1:  test dword ptr [rbx + AL_cfg], CLP_MODEWAIT
    jz 8f
    and dword ptr [rbx + AL_cfg], ~CLP_MODEWAIT
    lea r14, [rbx + AL_mode]    # the pick (AL_mode holds it until initialize's report)
    cmp byte ptr [r14], 0
    je 8f
    mov rdi, r14
    call mode_entry
    test rax, rax
    jz 8f
    mov rdi, r14                # bypass picked: the gate once more (the setting may have gone meanwhile)
    lea rsi, [rip + .Lv_bypass]
    call strcmp_eq
    test eax, eax
    jz 2f
    mov rdi, rbx
    call bypass_ok
    test eax, eax
    jz 7f
2:  mov rdi, r14
    call strlen
    cmp rax, r13
    jne 3f
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jnz 8f                      # it started in it (or will be in it: default)
3:  lea rdi, [rbx + AL_dpend]
    mov rsi, r14
    call cstr_copy
    or dword ptr [rbx + AL_cfg], CLP_PEND
    cmp r13, 31                 # what a refusal puts back: what it reported
    jbe 4f
    mov r13d, 31
4:  lea rdi, [rbx + AL_dprev]
    mov rsi, r12
    mov rdx, r13
    mov byte ptr [rdi + rdx], 0
    call memmove
    lea rax, [rbx + AL_dpend]
    mov rdi, rax
    call strlen
    mov rdx, rax
    lea rax, [rbx + AL_dpend]
    EPILOGUE
7:  test r13, r13                # bypass picked, the gate shut: the label shows what was reported, or
    jnz 8f                      #   nothing (it never shows a mode that was not asked for)
    lea r12, [rbx + AL_dprev]
    mov byte ptr [r12], 0
8:  mov rax, r12                # nothing picked: what it reported (nothing yet when default is asked)
    mov rdx, r13
    test dword ptr [rbx + AL_cfg], CLP_UNBYPASS
    jz 9f
    xor edx, edx
9:  EPILOGUE

# FN claude_init_ask(AL*): before any prompt: default when it started in bypass without the gate, then the
#   pick claude_init_mode kept (through the gate). A write refused fails the start (start_refused): no prompt
#   goes before them
FN claude_init_ask
    PROLOGUE
    mov rbx, rdi
    test dword ptr [rbx + AL_cfg], CLP_UNBYPASS
    jz 1f
    and dword ptr [rbx + AL_cfg], ~CLP_UNBYPASS
    mov rdi, rbx                # (its answer shows the mode: claude_mode_quiet's, claude_mode_answer)
    lea rsi, [rip + .Lv_default]
    call claude_mode_quiet
    test eax, eax
    jz 8f
1:  test dword ptr [rbx + AL_cfg], CLP_PEND
    jz 9f
    and dword ptr [rbx + AL_cfg], ~CLP_PEND
    lea rdi, [rbx + AL_dpend]
    lea rsi, [rip + .Lv_bypass]
    call strcmp_eq
    test eax, eax
    jz 2f
    mov rdi, rbx
    call bypass_ok
    test eax, eax
    jz 9f
2:  or dword ptr [rbx + AL_cfg], CLP_PREV   # a refusal puts back what it reported (AL_dprev)
    mov rdi, rbx
    lea rsi, [rbx + AL_dpend]
    call cl_set_mode
    test eax, eax
    jnz 9f
8:  mov rdi, rbx
    call start_refused
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

# dpick_add(AL*, request number, value cstr (at most 63 bytes)): a model asked of the running program with
#   that request, kept until its answer (dpick_take): a free slot, else the oldest pick's
dpick_add:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea r14, [rbx + AL_dpicks]  # the slot: a free one, else the smallest number
    xor ecx, ecx
1:  cmp ecx, DPICK_N
    jae 3f
    imul rax, rcx, DPICK_SIZE
    lea rax, [rbx + AL_dpicks + rax]
    cmp qword ptr [rax], 0
    je 2f
    mov rdx, [rax]
    cmp rdx, [r14]
    jae 11f
    mov r14, rax
11: inc ecx
    jmp 1b
2:  mov r14, rax
3:  mov [r14], r12
    lea rdi, [r14 + DPICK_VAL]
    mov rsi, r13
    call cstr_copy
    EPILOGUE

# dpick_take(AL*, request number, out (64 bytes)) -> eax 1 when a model was asked with that request: its
#   value into out, its slot free again; 0 (out untouched) for any other request
dpick_take:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor eax, eax
    test r12, r12
    jz 9f
    xor ecx, ecx
1:  cmp ecx, DPICK_N
    jae 9f
    imul r14, rcx, DPICK_SIZE
    lea r14, [rbx + AL_dpicks + r14]
    inc ecx
    cmp [r14], r12
    jne 1b
    mov qword ptr [r14], 0
    mov rdi, r13
    lea rsi, [r14 + DPICK_VAL]
    call cstr_copy
    mov eax, 1
9:  EPILOGUE

# dpicks_clear(AL*): no model pick waits for an answer any more (a process ended or begins)
dpicks_clear:
    xor ecx, ecx
1:  imul rax, rcx, DPICK_SIZE
    mov qword ptr [rdi + AL_dpicks + rax], 0
    inc ecx
    cmp ecx, DPICK_N
    jb 1b
    ret

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
    test rbx, rbx               # a draft's pick (AL* 0): nothing runs
    jz 2f
    mov rdi, rbx
    call live_up
    test eax, eax
    jnz 1f
2:  mov rdi, r13
    mov esi, AGF_MODEL
    mov rdx, r12
    mov rcx, r14
    call agentcfg_set
    mov rdi, r13
    call agentcfg_save
    test rbx, rbx               # a draft's pick (AL* 0): the project's choice only
    jz .Lsmo_yes
    jmp 3f
1:  mov rdi, rbx               # running: asked; the project's, and its pill, once its own answer says it
    mov esi, CLF_MODEL          #   applied (claude_flags_answer, by the request's number: AL_dpicks)
    lea rdx, [rip + .Lk_model]
    mov rcx, r12
    call cl_apply
    test eax, eax
    jz .Lsmo_yes                # the write broke the connection: its close says so
    mov rdi, rbx
    mov rsi, [rbx + AL_next]    # (the number req_begin gave it)
    dec rsi
    mov rdx, r12
    call dpick_add
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
    xor edi, edi                # (a draft's: AL* 0)
    test rbx, rbx
    jz 1f
    mov rdi, [rbx + AL_as]
1:  call cur_model
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
    test rbx, rbx
    jz .Lse_yes
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
    xor r14d, r14d              # (a draft's: AL* 0, nothing runs)
    test rbx, rbx
    jz 1f
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
    and dword ptr [rbx + AL_cfg], ~CLP_ULON  # this conversation's: a refusal's words
    test r12d, r12d
    jz 3f
    or dword ptr [rbx + AL_cfg], CLP_ULON
3:  mov rdi, rbx
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
    xor edi, edi                # (a draft's: AL* 0)
    test rbx, rbx
    jz 2f
    mov rdi, [rbx + AL_as]
2:  call cur_model
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
    test rbx, rbx
    jz 1f
    mov rdi, rbx
    mov esi, r12d
    call ev_thinking
    mov rdi, rbx
    call live_up
    test eax, eax
    jz 2f
    xor edx, edx
    test dword ptr [rbx + AL_cfg], CLP_SUMMARIES
    setnz dl
    mov rdi, rbx
    mov esi, r12d
    call cl_thinking
    jmp 1f
2:  cmp dword ptr [rbx + AL_state], ALS_STARTING
    jne 1f
    or dword ptr [rbx + AL_cfg], CLP_WAITTHINK     # asked once its first settings answer came (apply_kept)
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
    and dword ptr [rbx + AL_cfg], ~(CLP_WAITMODEL | CLP_WAITEFFORT | CLP_WAITTHINK | CLP_CREDITS | CLP_PREV | CLP_PROMPTS | CLP_UNBYPASS | CLP_PEND)
    or dword ptr [rbx + AL_cfg], CLP_FIRST
    call dpicks_clear           # (request numbers start again at r1)
    mov edi, AG_CLAUDE
    call agentcfg_get
    xor ecx, ecx
    cmp dword ptr [rax + AGC_think], 0
    setne cl
    mov [rbx + AL_think], ecx
    EPILOGUE

# FN claude_ended(AL*): DRV_ended: the record went OFF or FAILED (agent_state_set): a Stop during the start,
#   a start that failed, a process gone. What a start or a run kept goes (CLP_RUN: the picks waiting for
#   it, the prompts' wait for the settings, the first settings answer awaited, a /plan waiting for it, a
#   mode or a model asked and not answered): nothing is written for it later, no clock waits for it, and
#   the next start begins clean
FN claude_ended
    and dword ptr [rdi + AL_cfg], ~CLP_RUN
    jmp dpicks_clear

# starting_up(AL*) -> eax 1 while its start is under way with its program up (STARTING, connected): what
#   the start waits for may be written
starting_up:
    xor eax, eax
    cmp dword ptr [rdi + AL_state], ALS_STARTING
    jne 9f
    cmp dword ptr [rdi + AL_cn + CN_state], CN_UP
    jne 9f
    inc eax
9:  ret

# start_refused(AL*): a write the start needs before any prompt (a kept choice, the mode out of bypass) was
#   refused by a connection still up (its queue full: the program reads nothing): the start fails with
#   its words, the prompts back in the box, and the program goes (as a refused initialize does). A write
#   that broke the connection has had its close already
start_refused:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + AL_cn + CN_state], CN_UP
    jne 9f
    cmp dword ptr [rbx + AL_state], ALS_STARTING
    jne 9f
    lea rdi, [rip + .Le_refused]
    call strlen
    mov rdi, rbx
    lea rsi, [rip + .Le_refused]
    mov rdx, rax
    call ev_failed
    lea rdi, [rbx + AL_cn]
    call conn_stop
9:  EPILOGUE

# kept_picks(AL*) -> eax 1 to go on, 0 when the start failed: a model, an effort level and thinking picked
#   while it started are asked for now, before any prompt (once: their flags go). A write refused fails the
#   start (start_refused); none is written unless the start is still under way
kept_picks:
    PROLOGUE
    mov rbx, rdi
    mov r12d, [rbx + AL_cfg]
    and dword ptr [rbx + AL_cfg], ~(CLP_WAITMODEL | CLP_WAITEFFORT | CLP_WAITTHINK)
    test r12d, CLP_WAITMODEL | CLP_WAITEFFORT | CLP_WAITTHINK
    jz 8f
    mov rdi, rbx
    call starting_up
    test eax, eax
    jz 8f
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r13, rax
    test r12d, CLP_WAITMODEL
    jz 1f
    cmp byte ptr [r13 + AGC_model], 0
    je 1f
    mov rdi, rbx                # (the project's already: no slot, no pill)
    mov esi, CLF_MODEL
    lea rdx, [rip + .Lk_model]
    lea rcx, [r13 + AGC_model]
    call cl_apply
    test eax, eax
    jz 7f
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
    jz 7f
2:  test r12d, CLP_WAITTHINK    # thinking switched while it started
    jz 8f
    xor esi, esi
    cmp dword ptr [r13 + AGC_think], 0
    setne sil
    xor edx, edx
    test dword ptr [rbx + AL_cfg], CLP_SUMMARIES
    setnz dl
    mov rdi, rbx
    call cl_thinking
    test eax, eax
    jz 7f
8:  mov eax, 1
    EPILOGUE
7:  mov rdi, rbx
    call start_refused
    xor eax, eax
    EPILOGUE

# apply_kept(AL*, Ultracode offered, on) -> eax 1 to go on, 0 when the start failed: a get_settings answer
#   (or its refusal: nothing offered). The picks made while it started that are still to ask (kept_picks:
#   the wait's end may have asked them), then, on the process's first answer only (CLP_FIRST, which the
#   wait's end leaves: a late answer still settles it), the project's Ultracode when it differs from the
#   one in effect; nothing is written unless the program still starts or runs
apply_kept:
    PROLOGUE
    mov rbx, rdi
    mov r14d, esi
    mov r15d, edx
    call kept_picks
    test eax, eax
    jz 9f
    mov eax, 1
    test dword ptr [rbx + AL_cfg], CLP_FIRST
    jz 9f
    and dword ptr [rbx + AL_cfg], ~CLP_FIRST
    test r14d, r14d
    jz 9f
    mov rdi, rbx
    call starting_up
    mov r12d, eax               # (1: a refusal fails the start)
    test eax, eax
    jnz 1f
    mov rdi, rbx
    call live_up
    test eax, eax
    jz 8f
1:  mov edi, AG_CLAUDE
    call agentcfg_get
    mov r13, rax
    mov eax, [r13 + AGC_ultra]
    test eax, eax
    js 8f
    cmp eax, r15d
    je 8f
    and dword ptr [rbx + AL_cfg], ~CLP_ULON
    test eax, eax
    jz 22f
    or dword ptr [rbx + AL_cfg], CLP_ULON
22: mov r8d, [r13 + AGC_ultra]
    mov rdi, rbx
    mov esi, CLF_ULTRA
    lea rdx, [rip + .Lk_ultra]
    xor ecx, ecx
    call cl_apply
    test eax, eax
    jnz 8f
    test r12d, r12d
    jz 8f
    mov rdi, rbx
    call start_refused
    xor eax, eax
    EPILOGUE
8:  mov eax, 1
9:  EPILOGUE

# FN claude_flags_answer(AL*, control_response's response, kind CLF_*, request number): apply_flag_settings'
#   or set_max_thinking_tokens' answer. Done: a model the user picked with that request (AL_dpicks: its own
#   value, whatever was picked after it) is the project's and its pill row says so ("Switched to NAME"),
#   then what is in effect is read again (get_settings); refused: the toast says why ("Failed to set
#   model: …", "Failed to set effort: …", "Failed to turn Ultracode on: …" / "off: …", "Failed to set
#   thinking: …"), that pick is nobody's, and what is in effect is read again
FN claude_flags_answer
    PROLOGUE 80
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov [rsp], rcx
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
    mov rdi, rbx                # the pick this request asked for (its value kept: [rsp + 8])
    mov rsi, [rsp]
    lea rdx, [rsp + 8]
    call dpick_take
    test eax, eax
    jz 4f
    mov edi, AG_CLAUDE          # applied: the project's model now
    call agentcfg_get
    mov r14, rax
    lea rdi, [rsp + 8]
    call strlen
    mov r15, rax
    mov rdi, r14
    mov esi, AGF_MODEL
    lea rdx, [rsp + 8]
    mov rcx, r15
    call agentcfg_set
    mov rdi, r14
    call agentcfg_save
    lea rdi, [rip + bsb]        # "Switched to NAME" (webview index.js @5967170)
    call sb_clear
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lp_switched]
    call sb_push_cstr
    mov rdi, r14
    lea rsi, [rsp + 8]
    mov rdx, r15
    call agentcfg_find_model
    lea rsi, [rsp + 8]
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
    test dword ptr [rbx + AL_cfg], CLP_ULON
    jz 6f
    lea rsi, [rip + .Lf_ultra_on]
6:  cmp r13d, CLF_MODEL         # a refused model is not the project's, and no pill names it
    jne 61f
    mov [rsp + 72], rsi     # (the words: dpick_take keeps no register)
    mov rdi, rbx
    mov rsi, [rsp]
    lea rdx, [rsp + 8]
    call dpick_take
    mov rsi, [rsp + 72]
61: lea rdi, [rip + bsb]
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
    call spin_record            # the spinner's words (MLe @5436400)
    mov rdi, rbx
    mov rsi, r12
    call usage_record           # the context window, a compaction
    mov rdi, rbx
    mov rsi, r12
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
1:  xor edi, edi                # (a draft's: AL* 0)
    test rbx, rbx
    jz 11f
    mov rdi, [rbx + AL_as]
11: call cur_model
    test rax, rax
    jz 9f
    mov r14, rax
    mov r15, [r14 + AMO_levels + VEC_len]
    test r15, r15
    jz 9f
    mov edi, AG_CLAUDE
    call agentcfg_get
    xor edi, edi
    test rbx, rbx
    jz 12f
    mov rdi, [rbx + AL_as]
12: mov rsi, rax
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
#   then TEXT as a prompt; already in it: the plan in a tab, get_plan's, or the extension's info row),
#   ACT_FAST (/fast as a prompt),
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
    cmp r12d, ACT_EFFORT        # the effort row: a step, a round, or a level's id (a draft's: AL* 0)
    je 10f
    test rbx, rbx
    jz .Lca_no
    cmp r12d, ACT_FAST
    je .Lca_fast
    jmp 11f
10: mov rdi, rbx
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
    mov eax, [rbx + AL_state]   # plan review. A start under way (its process may be up, initialize not
    cmp eax, ALS_STARTING       #   answered): get_plan goes once it is up (prompts_go), as for a /plan
    je 14f                      #   that started it
    cmp eax, ALS_HELD
    je 14f
    cmp dword ptr [rbx + AL_cn + CN_state], CN_UP   # a process: the plan in a tab (get_plan:
    je 12f                                          #   claude_plan_answer, claude_cards.s)
    cmp eax, ALS_OFF            # none (the idle stop ended it, or it failed): it starts, as for a prompt,
    je 15f                      #   and get_plan goes once it is up (the extension always has one);
    cmp eax, ALS_FAILED         #   nothing is sent
    jne 13f
15: mov rdi, [rbx + AL_as]
    call agent_run
    mov eax, [rbx + AL_state]
    cmp eax, ALS_STARTING
    je 14f
    cmp eax, ALS_HELD
    jne 13f
14: or dword ptr [rbx + AL_cfg], CLP_PLANWAIT
    jmp .Lca_yes
13: lea r15, [rip + .Lp_unshown]
    jmp .Lca_note
12: mov rdi, rbx
    call claude_get_plan
    test eax, eax
    jnz .Lca_yes
    lea r15, [rip + .Lp_unshown]
    jmp .Lca_note
1:  mov rdi, rbx
    lea rsi, [rip + .Lv_plan]
    call claude_set_mode
    test eax, eax
    jnz 2f
    lea r15, [rip + .Lp_couldnt]    # "Couldn't switch to plan mode[; not sent: TEXT]"
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
.Lca_note:                      # (r15: the note)
    mov rdi, r15
    call strlen
    mov rcx, rax
    mov rdx, r15
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

# ---- notices: the rate-limit and auth bands, the context and the prompt cache (task 8) ----

# FN claude_rate(AL*, record): rate_limit_event (finding 20): the rate-limit band says what the extension's
#   Atn (webview index.js @3896761) composes from rate_limit_info; "allowed", or a warning below 70 %, takes it
#   away. Only "allowed" was ever recorded (finding 20): the other statuses, utilization at the top,
#   surpassedThreshold, dailyCapPaused, adminRequestOffer, overageResetsAt and overageDisabledReason are the
#   CLI's schema (ext-host-protocol 2.6) and the fake's (FAKE_CLAUDE_RATE, `rate KIND`), with no recording
#   behind them. "Get more usage" (claude.ai's usage page, asked before it opens) is offered with a Pro or
#   Max plan (CLP_PAID, as the extension's nje @3674254); "View usage" and "Send request" wait for the
#   usage dialog (phase 7); the gates' notes and the grace states are never read
FN claude_rate
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_rate_info]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne 9f
    lea rdi, [rip + rsb]
    call sb_clear
    mov rdi, r12
    call rate_text
    test eax, eax
    jz 7f
    mov rdi, rbx
    mov esi, BK_RATE
    mov rdx, [rip + rsb + SB_ptr]
    mov rcx, [rip + rsb + SB_len]
    call ev_band
    test dword ptr [rbx + AL_cfg], CLP_PAID
    jz 9f
    mov rdi, rbx
    mov esi, BK_RATE
    lea rdx, [rip + .Lr_more]
    lea rcx, [rip + .Lr_more_url]
    call ev_band_link
    EPILOGUE
7:  mov rdi, rbx
    mov esi, BK_RATE
    xor edx, edx
    xor ecx, ecx
    call ev_band
9:  EPILOGUE

# rate_text(info) -> eax 1 with the band's text in rsb, 0 for none (Atn)
rate_text:
    PROLOGUE 32
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Lk_status]
    call json_get
    mov r12, rax                # the status
    mov rdi, rax
    lea rsi, [rip + .Lv_allowed]
    call json_is
    test eax, eax
    jnz .Lrt_none
    mov rdi, rbx
    lea rsi, [rip + .Lk_rate_type]
    call json_get
    mov r15, rax                # rateLimitType
    mov rdi, rax
    lea rsi, [rip + rate_words]
    call lookup
    lea r13, [rip + .Lr_usage_limit]
    test rax, rax
    cmovnz r13, rax             # the limit's words
    mov rdi, r15
    lea rsi, [rip + .Lv_five]
    call json_is
    xor eax, 1
    mov [rsp], eax              # 1: the reset names its day (all but the five-hour limit)
    mov rdi, rbx
    lea rsi, [rip + .Lk_resets]
    call json_get
    mov rdi, rax
    call num_int
    mov [rsp + 8], rax          # resetsAt, 0 none
    mov rdi, r12
    lea rsi, [rip + .Lv_rejected]
    call json_is
    test eax, eax
    jz .Lrt_warn
    mov rdi, rbx                # rejected: the organization's daily cap
    lea rsi, [rip + .Lk_paused]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_TRUE
    jne 1f
    lea rsi, [rip + .Lr_paused]
    call push_rsb
    jmp .Lrt_ok
1:  mov rdi, r15
    call json_str
    test rdx, rdx
    jz .Lrt_none                # no limit named: nothing to say
    mov rdi, rbx
    lea rsi, [rip + .Lk_admin]
    call json_get
    test rax, rax
    jz .Lrt_hit
    mov rdi, rbx                # the spend limit, with an admin to ask
    lea rsi, [rip + .Lk_ov_reason]
    call json_get
    mov rdi, rax
    lea rsi, [rip + reason_words]
    call lookup
    mov r14, rax                # the reason's words, or 0
    lea rsi, [rip + .Lr_spend]
    test rax, rax
    cmovnz rsi, rax
    call push_rsb
    mov rdi, r15
    lea rsi, [rip + .Lv_ov_type]
    call json_is
    test eax, eax
    jnz 2f
    cmp qword ptr [rsp + 8], 0
    je 2f
    lea rsi, [rip + .Lr_your]   # " · your LIMIT resets WHEN"
    call push_rsb
    mov rsi, r13
    call push_rsb
    lea rsi, [rip + .Lr_resets_w]
    call push_rsb
    mov rdi, [rsp + 8]
    mov esi, [rsp]
    call fmt_reset
    jmp .Lrt_ok
2:  test r14, r14
    jnz .Lrt_ok
    mov rdi, rbx                # " · resets WHEN" (the overage's reset, else the limit's), with its day
    lea rsi, [rip + .Lk_ov_resets]
    call json_get
    mov rdi, rax
    call num_int
    test rax, rax
    jnz 3f
    mov rax, [rsp + 8]
    test rax, rax
    jz .Lrt_ok
3:  mov rdi, rax
    mov esi, 1
    call put_resets
    jmp .Lrt_ok
.Lrt_hit:
    lea rsi, [rip + .Lr_hit]    # "You've hit your LIMIT · resets WHEN · continue with usage credits"
    call push_rsb
    mov rsi, r13
    call push_rsb
    mov rdi, [rsp + 8]
    mov esi, [rsp]
    call put_resets
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Lv_allowed]
    lea rcx, [rip + .Lv_allowed_warn]
    call credits_tail
    jmp .Lrt_ok
.Lrt_warn:
    mov rdi, rbx
    lea rsi, [rip + .Lk_util]
    call json_get
    mov rdi, rax
    call milli
    mov [rsp + 16], rax         # utilization in thousandths
    mov [rsp + 20], edx         # given
    test edx, edx
    jz 4f
    cmp rax, 700                # below 70 %: nothing to say
    jl .Lrt_none
    test rax, rax
    jz 4f
    xor edx, edx                # "You've used N% of your LIMIT · resets WHEN"
    mov ecx, 10
    cqo
    idiv rcx
    mov r14, rax
    mov rdi, r15
    lea rsi, [rip + .Lv_ov_type]
    call json_is
    test eax, eax
    jnz 5f
    cmp r14, 100
    jle 5f
    mov r14d, 100
5:  test r14, r14
    jz 4f
    lea rsi, [rip + .Lr_used]
    call push_rsb
    lea rdi, [rip + rsb]
    mov rsi, r14
    call sb_push_u64
    lea rsi, [rip + .Lr_pct_of]
    call push_rsb
    mov rsi, r13
    call push_rsb
    jmp 8f
4:  mov rdi, rbx                # a threshold passed: "Over N% of your LIMIT used"
    lea rsi, [rip + .Lk_threshold]
    call json_get
    mov rdi, rax
    call milli
    test edx, edx
    jz 6f
    test rax, rax
    jle 6f
    cmp rax, 1000
    jge 6f
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r14, rax
    lea rsi, [rip + .Lr_over]
    call push_rsb
    lea rdi, [rip + rsb]
    mov rsi, r14
    call sb_push_u64
    lea rsi, [rip + .Lr_pct_of]
    call push_rsb
    mov rsi, r13
    call push_rsb
    lea rsi, [rip + .Lr_used_w]
    call push_rsb
    jmp 8f
6:  lea rsi, [rip + .Lr_near]   # "Approaching LIMIT"
    call push_rsb
    mov rsi, r13
    call push_rsb
8:  mov rdi, [rsp + 8]
    mov esi, [rsp]
    call put_resets
    mov rdi, rbx                # " · continue with usage credits" unless the overage was refused
    mov rsi, r15
    xor edx, edx
    lea rcx, [rip + .Lv_rejected]
    call credits_tail
.Lrt_ok:
    mov eax, 1
    EPILOGUE
.Lrt_none:
    xor eax, eax
    EPILOGUE

# credits_tail(info, rateLimitType jv, ok1 cstr or 0, ok2 cstr): " · continue with usage credits" for the
#   Fable limit whose overageStatus is ok1 or ok2 (ok1 0: any overageStatus but ok2)
credits_tail:
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    mov r13, rcx
    mov rdi, rsi
    lea rsi, [rip + .Lv_fable_type]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_ov_status]
    call json_get
    mov r14, rax
    test r12, r12
    jz 1f
    mov rdi, rax
    mov rsi, r12
    call json_is
    test eax, eax
    jnz 2f
    mov rdi, r14
    mov rsi, r13
    call json_is
    test eax, eax
    jz 9f
    jmp 2f
1:  mov rdi, rax
    mov rsi, r13
    call json_is
    test eax, eax
    jnz 9f
2:  lea rsi, [rip + .Lr_credits]
    call push_rsb
9:  EPILOGUE

# push_rsb(rsi cstr): rsb gains the text
push_rsb:
    lea rdi, [rip + rsb]
    jmp sb_push_cstr

# put_resets(unix seconds or 0, edi named day): " · resets WHEN" when there is a time
put_resets:
    test rdi, rdi
    jz 1f
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    lea rsi, [rip + .Lr_resets]
    call push_rsb
    mov rdi, rbx
    mov esi, r12d
    call fmt_reset
    EPILOGUE
1:  ret

# lookup(jv, table of {key cstr, value cstr} pairs ending 0) -> rax the value of the string jv is, or 0
lookup:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
1:  mov rsi, [r12]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call json_is
    test eax, eax
    jnz 2f
    add r12, 16
    jmp 1b
2:  mov rax, [r12 + 8]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# num_int(jv) -> rax a number's integer part (a whole number, or one with a fraction), 0 when it is none
num_int:
    PROLOGUE
    mov rbx, rdi
    call json_int
    test edx, edx
    jnz 9f
    mov rdi, rbx
    call milli
    test edx, edx
    jz 9f
    cqo
    mov ecx, 1000
    idiv rcx
9:  EPILOGUE

# milli(jv) -> rax the number times 1000, rounded half up, edx 1 when jv is a number (decimal, with a
#   fraction or an exponent; 18 digits counted at most)
milli:
    PROLOGUE 16
    call json_num_text
    test edx, edx
    jz 8f
    mov rsi, rax
    lea r15, [rax + rdx]        # the end
    xor r8d, r8d                # negative
    xor r9d, r9d                # digits as a whole number
    xor r10d, r10d              # its scale: a power of ten
    xor r11d, r11d              # after the point
    xor r12d, r12d              # digits taken
    xor r13d, r13d              # the exponent
    cmp byte ptr [rsi], '-'
    jne 1f
    mov r8d, 1
    inc rsi
1:  cmp rsi, r15
    jae 5f
    movzx eax, byte ptr [rsi]
    inc rsi
    cmp al, '.'
    jne 2f
    mov r11d, 1
    jmp 1b
2:  cmp al, 'e'
    je 3f
    cmp al, 'E'
    je 3f
    sub eax, '0'
    cmp eax, 9
    ja 5f
    cmp r12d, 18
    jae 21f
    imul r9, r9, 10
    add r9, rax
    inc r12d
    sub r10d, r11d              # a digit after the point
    jmp 1b
21: test r11d, r11d             # past 18 digits: only the integer part's scale counts
    jnz 1b
    inc r10d
    jmp 1b
3:  xor ecx, ecx                # the exponent: [+-]digits
    cmp rsi, r15
    jae 5f
    cmp byte ptr [rsi], '+'
    jne 31f
    inc rsi
    jmp 32f
31: cmp byte ptr [rsi], '-'
    jne 32f
    mov ecx, 1
    inc rsi
32: cmp rsi, r15
    jae 33f
    movzx eax, byte ptr [rsi]
    sub eax, '0'
    cmp eax, 9
    ja 33f
    inc rsi
    cmp r13d, 1000
    jae 32b
    imul r13d, r13d, 10
    add r13d, eax
    jmp 32b
33: test ecx, ecx
    jz 5f
    neg r13d
5:  lea ecx, [r10 + r13 + 3]    # the power of ten to apply
    mov rax, r9
    test ecx, ecx
    js 6f
7:  test ecx, ecx
    jz 9f
    mov rdx, 922337203685477580
    cmp rax, rdx
    jae 9f                      # saturates
    imul rax, rax, 10
    dec ecx
    jmp 7b
6:  neg ecx
    cmp ecx, 18
    ja 61f
    mov r10d, 1
62: imul r10, r10, 10
    dec ecx
    jnz 62b
    mov rcx, r10
    shr rcx, 1
    add rax, rcx
    xor edx, edx
    div r10
    jmp 9f
61: xor eax, eax
9:  test r8d, r8d
    jz 91f
    neg rax
91: mov edx, 1
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# ---- the spinner's words ----

# spin_record(AL*, record): the spinner's words in place of a verb, as the extension picks them (MLe
#   @5436400): "Compacting" from system/status compacting until another status; else "Running start-up hooks"
#   from a SessionStart or Setup hook's hook_started until its hook_response (2.1.330 sends those before the
#   initialize answer and during /compact without --include-hook-events, finding 32); a turn's result ends
#   both. The words go to the spinner as data (ev_spin); none: the verbs again
spin_record:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, [rbx + AL_cfg]
    mov rdi, r12
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_result]
    call json_is
    test eax, eax
    jz 1f
    and dword ptr [rbx + AL_cfg], ~(CLP_SPINCOMPACT | CLP_SPINHOOK)
    jmp 7f
1:  mov rdi, r12
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_status]
    call json_is
    test eax, eax
    jz 2f
    and dword ptr [rbx + AL_cfg], ~CLP_SPINCOMPACT
    mov rdi, r12
    lea rsi, [rip + .Lk_status]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lsp_compacting_v]
    call json_is
    test eax, eax
    jz 7f
    or dword ptr [rbx + AL_cfg], CLP_SPINCOMPACT
    jmp 7f
2:  mov rdi, r14
    lea rsi, [rip + .Lsp_started]
    call json_is
    mov r15d, eax
    mov rdi, r14
    lea rsi, [rip + .Lsp_response]
    call json_is
    or eax, r15d
    jz 9f                       # nothing of the spinner's
    mov rdi, r12
    lea rsi, [rip + .Lsp_event]
    call json_get
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lsp_start]
    call json_is
    test eax, eax
    jnz 3f
    mov rdi, r14
    lea rsi, [rip + .Lsp_setup]
    call json_is
    test eax, eax
    jz 9f
3:  and dword ptr [rbx + AL_cfg], ~CLP_SPINHOOK
    test r15d, r15d
    jz 7f
    or dword ptr [rbx + AL_cfg], CLP_SPINHOOK
7:  mov eax, [rbx + AL_cfg]     # what the words are now, when they changed
    xor eax, r13d
    test eax, CLP_SPINCOMPACT | CLP_SPINHOOK
    jz 9f
    xor esi, esi
    mov eax, [rbx + AL_cfg]
    test eax, CLP_SPINHOOK
    jz 71f
    lea rsi, [rip + .Lsp_hooks]
71: test eax, CLP_SPINCOMPACT
    jz 72f
    lea rsi, [rip + .Lsp_compacting]
72: mov rdi, rbx
    xor edx, edx
    call ev_spin
9:  EPILOGUE

# ---- times in the bundle's form (index.js @3698835 ex, @3698130 Vj, @3698516 $j) ----

# fmt_reset(unix seconds, esi named day): rsb gains "soon" within a minute, "at 3:45 PM" within a day
#   unless named day, else "Tue, Nov 24 at 3:45 PM" (", 2027" after the day in another year), local time
fmt_reset:
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    call time_now
    mov r13, rax
    mov rax, rbx
    sub rax, r13
    cmp rax, 60
    jge 1f
    lea rsi, [rip + .Lr_soon]
    call push_rsb
    EPILOGUE
1:  mov r14, rax                # seconds left
    mov rdi, r13                # this year, here
    call agtime_days
    mov rdi, rax
    call agtime_civil
    mov [rsp + 16], rax
    mov rdi, rbx
    call agtime_days
    mov r15, rax                # the day
    mov [rsp], rdx              # its second
    test r12d, r12d
    jnz 2f
    cmp r14, 86400
    jge 2f
    lea rsi, [rip + .Lr_at]
    call push_rsb
    jmp 5f
2:  mov rax, r15                # "Tue, "
    add rax, 4
    xor edx, edx
    mov ecx, 7
    div rcx
    lea rax, [rip + day_names]
    lea rsi, [rax + rdx*4]
    call push_rsb
    lea rsi, [rip + .Lr_comma]
    call push_rsb
    mov rdi, r15
    call agtime_civil
    mov [rsp + 8], rax
    mov r14d, ecx
    lea rax, [rip + month_names]    # "Nov 24"
    lea rsi, [rax + rdx*4 - 4]
    call push_rsb
    lea rdi, [rip + rsb]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + rsb]
    mov esi, r14d
    call sb_push_u64
    mov rax, [rsp + 8]
    cmp rax, [rsp + 16]
    je 3f
    lea rsi, [rip + .Lr_comma]
    call push_rsb
    lea rdi, [rip + rsb]
    mov rsi, [rsp + 8]
    call sb_push_u64
3:  lea rsi, [rip + .Lr_at_sp]
    call push_rsb
5:  mov rax, [rsp]              # "3:45 PM"
    xor edx, edx
    mov ecx, 3600
    div rcx
    mov r14, rax                # the hour
    mov rax, rdx
    xor edx, edx
    mov ecx, 60
    div rcx
    mov r15, rax                # the minute
    lea rax, [r14 + 11]
    xor edx, edx
    mov ecx, 12
    div rcx
    lea rsi, [rdx + 1]
    lea rdi, [rip + rsb]
    call sb_push_u64
    lea rdi, [rip + rsb]
    mov esi, ':'
    call sb_push_byte
    cmp r15, 10
    jae 6f
    lea rdi, [rip + rsb]
    mov esi, '0'
    call sb_push_byte
6:  lea rdi, [rip + rsb]
    mov rsi, r15
    call sb_push_u64
    lea rsi, [rip + .Lr_am]
    cmp r14, 12
    jb 7f
    lea rsi, [rip + .Lr_pm]
7:  call push_rsb
    EPILOGUE

# ---- the auth conflict, the account's plan ----

# account_notes(AL*, initialize's response): CLP_PAID when its account is a Pro or Max plan's (its
#   subscriptionType; kept in memory only, nothing else of the account is read), and the auth band: the
#   extension's authConflictWarning (index.js @3777297) for an auth_conflict {token_source,
#   api_key_source}, none without one. auth_conflict has no recording (the CLI's schema; the fake has it)
account_notes:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    and dword ptr [rbx + AL_cfg], ~CLP_PAID
    mov rdi, r12
    lea rsi, [rip + .Lk_account]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_subscription]
    call jstr
    mov rdi, rax
    mov rsi, rdx
    call paid_plan
    test eax, eax
    jz 1f
    or dword ptr [rbx + AL_cfg], CLP_PAID
1:  mov rdi, r12
    lea rsi, [rip + .Lk_conflict]
    call json_get
    mov r13, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    je 2f
    mov rdi, rbx
    mov esi, BK_AUTH
    xor edx, edx
    xor ecx, ecx
    call ev_band
    EPILOGUE
2:  lea rdi, [rip + rsb]
    call sb_clear
    mov rdi, r13
    lea rsi, [rip + .Lk_token_src]
    call json_get
    mov r14, rax                # token_source
    mov rdi, r13
    lea rsi, [rip + .Lk_key_src]
    call json_get
    mov r15, rax                # api_key_source
    mov rdi, r14
    lea rsi, [rip + .Lv_profile]
    call json_is
    mov r13d, eax
    lea rsi, [rip + .La_both]
    test eax, eax
    jz 3f
    lea rsi, [rip + .La_not_using]
3:  call push_rsb
    mov rdi, r14
    call push_source
    lea rsi, [rip + .La_and]
    test r13d, r13d
    jz 4f
    lea rsi, [rip + .La_because]
4:  call push_rsb
    mov rdi, r15
    call push_source
    lea rsi, [rip + .La_expect]
    test r13d, r13d
    jz 5f
    lea rsi, [rip + .La_priority]
5:  call push_rsb
    mov rdi, r15                # a key saved by /login, beside another login: sign out of it
    lea rsi, [rip + .Lv_login_key]
    call json_is
    test eax, eax
    jz 6f
    test r13d, r13d
    jnz 6f
    mov rdi, r14
    lea rsi, [rip + .Lv_claude_ai]
    call json_is
    test eax, eax
    jnz 6f
    lea rsi, [rip + .La_only]
    call push_rsb
    mov rdi, r14
    call push_source
    lea rsi, [rip + .La_logout]
    call push_rsb
    jmp 7f
6:  lea rsi, [rip + .La_keep]
    call push_rsb
7:  mov rdi, rbx
    mov esi, BK_AUTH
    mov rdx, [rip + rsb + SB_ptr]
    mov rcx, [rip + rsb + SB_len]
    call ev_band
    EPILOGUE

# push_source(jv): rsb gains a credential's words (index.js @3899982 lZe): "your claude.ai login", …, else
#   the source as it is named (at most 100 bytes)
push_source:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + source_words]
    call lookup
    test rax, rax
    jz 1f
    mov rsi, rax
    call push_rsb
    EPILOGUE
1:  mov rdi, rbx
    call json_str
    mov rbx, rax
    mov rdi, rdx
    mov rsi, rax
    mov edx, 100
    call utf8_cut
    lea rdi, [rip + rsb]
    mov rsi, rbx
    mov rdx, rax
    call sb_push
    EPILOGUE

# paid_plan(ptr, len) -> eax 1 for a Pro or Max subscription's name ("pro", "max", "Claude Max": its last
#   word, any case). The recordings redact the account: "Claude Max" is the fake's form, "max" the
#   extension's (eje, index.js @3673355); both are taken
paid_plan:
    xor eax, eax
    cmp rsi, 3
    jb 9f
    cmp rsi, 3
    je 1f
    cmp byte ptr [rdi + rsi - 4], ' '
    jne 9f
1:  movzx ecx, byte ptr [rdi + rsi - 3]
    movzx edx, byte ptr [rdi + rsi - 2]
    movzx r8d, byte ptr [rdi + rsi - 1]
    or ecx, 0x20
    or edx, 0x20
    or r8d, 0x20
    shl edx, 8
    shl r8d, 16
    or ecx, edx
    or ecx, r8d
    cmp ecx, 0x6f7270           # "pro"
    je 2f
    cmp ecx, 0x78616d           # "max"
    jne 9f
2:  mov eax, 1
9:  ret

# ---- the context and the prompt cache (ext-webview-ui 2.15, 2.17) ----

# FN claude_frame(AL*, record): a main assistant record's message.usage (finding 21): the context in use is
#   its four token counts (as the extension's updateUsage, index.js @3886591, for every message, the CLI's
#   own "<synthetic>" ones included); the prompt cache's clock (FUe @3600060): a message other than
#   "<synthetic>" that read or wrote the cache starts it at the request that asked for the message (the
#   last user record, claude_asked) or at its arrival, for an hour or five minutes as usage.cache_creation
#   says (else the lifetime it had); one that names neither has no clock (ttl 0). Nothing is parsed
FN claude_frame
    PROLOGUE 96
    mov rbx, rdi
    mov rdi, rsi
    lea rsi, [rip + .Lk_message]
    call json_get
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_usage]
    call json_get
    mov r13, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne 9f
    lea rdi, [rsp]
    lea rsi, [rbx + AL_usage]
    mov edx, AGU_SIZE
    call memmove
    mov rdi, r13
    lea rsi, [rip + .Lk_in]
    call tokens
    mov r14, rax
    mov rdi, r13
    lea rsi, [rip + .Lk_cache_read]
    call tokens
    mov r15, rax
    mov rdi, r13
    lea rsi, [rip + .Lk_cache_made]
    call tokens
    mov [rsp + 64], rax         # written
    add r15, rax                # read and written
    mov rdi, r13
    lea rsi, [rip + .Lk_out]
    call tokens
    add rax, r14
    add rax, r15
    mov [rsp + AGU_used], rax
    mov rdi, r12
    lea rsi, [rip + .Lk_model]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_synthetic]
    call json_is
    test eax, eax
    jnz 8f                      # the CLI's own answer: no request was made
    mov rax, r14
    add rax, r15
    jz 8f                       # nothing sent: no cache frame (recacheTokens)
    mov rdi, r12
    lea rsi, [rip + .Lk_id]
    call jstr
    mov rdi, rax
    mov rsi, rdx
    call key_of
    mov [rsp + 72], rax         # the message's key
    xor ecx, ecx                # the same message as the last frame's
    test rax, rax
    jz 1f
    cmp rax, [rsp + AGU_key]
    sete cl
1:  mov [rsp + 80], ecx
    test ecx, ecx
    jz 2f
    cmp dword ptr [rsp + AGU_cold], CCOLD_COMPACTED
    je 3f                       # (still the message before the compaction: it stays compacted)
    cmp qword ptr [rsp + AGU_cache_at], 0
    jne 3f                      # its clock started with its first frame
2:  mov rax, [rsp + AGU_asked]  # from the request that asked for it, or now
    test rax, rax
    jnz 21f
    call time_ms
21: mov [rsp + AGU_cache_at], rax
    mov dword ptr [rsp + AGU_cold], CCOLD_NONE
3:  xor eax, eax                # its lifetime: only a frame that read or wrote the cache has one
    test r15, r15
    jz 5f
    mov rdi, r13
    lea rsi, [rip + .Lk_cache_split]
    call json_get
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_hour]
    call tokens
    mov ecx, eax
    mov eax, 3600000
    test rcx, rcx
    jnz 4f
    mov rdi, r14
    lea rsi, [rip + .Lk_five]
    call tokens
    mov ecx, eax
    mov eax, 300000
    test rcx, rcx
    jnz 4f
    mov rax, [rsp + AGU_cache_ttl]
4:  test rax, rax
    jz 5f
    mov ecx, [rip + g_cache_ttl_ms]     # tests: a shorter lifetime (agent-timing cache=MS)
    test ecx, ecx
    jz 5f
    mov eax, ecx
5:  mov [rsp + AGU_cache_ttl], rax
    mov rax, [rsp + 72]
    cmp dword ptr [rsp + 80], 0
    jne 6f
    mov qword ptr [rsp + AGU_asked], 0  # a new message: the next one waits for its own request
6:  mov [rsp + AGU_key], rax
8:  mov rdi, rbx
    lea rsi, [rsp]
    call ev_usage
9:  EPILOGUE

# tokens(obj, key) -> rax a member's count of tokens, 0 when it is not a whole number at least 0
tokens:
    push rbx
    call json_get
    mov rdi, rax
    call json_int
    test edx, edx
    jz 1f
    test rax, rax
    jns 2f
1:  xor eax, eax
2:  pop rbx
    ret

# key_of(ptr, len) -> rax a message id's key (FNV-1a; never 0), 0 for no id
key_of:
    xor eax, eax
    test rsi, rsi
    jz 9f
    mov rax, 0xcbf29ce484222325
    mov r8, 0x100000001b3
1:  movzx ecx, byte ptr [rdi]
    xor rax, rcx
    imul rax, r8
    inc rdi
    dec rsi
    jnz 1b
    test rax, rax
    jnz 9f
    inc rax
9:  ret

# FN claude_asked(AL*): a main user record came (a prompt's replay, a tool's result): the request that asks
#   for the next message goes out now (the prompt cache's clock starts there: notePromptCacheRequest)
FN claude_asked
    push rbx
    mov rbx, rdi
    call time_ms
    mov [rbx + AL_usage + AGU_asked], rax
    pop rbx
    ret

# usage_record(AL*, record): a result's modelUsage gives the context window (that of the model in effect, as
#   AL_model names it with or without "[1m]", else the first that has one), as the extension reads it
#   (@3879508, only when total_cost_usd is there): contextWindow − min(maxOutputTokens, 20000) − 13000 (tFt
#   @5739500); system/compact_boundary empties the context and the prompt cache no longer covers it
usage_record:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rsp]
    lea rsi, [rbx + AL_usage]
    mov edx, AGU_SIZE
    call memmove
    mov rdi, r12
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_result]
    call json_is
    test eax, eax
    jz 5f
    mov rdi, r12
    lea rsi, [rip + .Lk_cost]
    call json_get
    test rax, rax
    jz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_model_usage]
    call json_get
    mov rdi, rax
    lea rsi, [rbx + AL_model]
    call model_usage
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_window]
    call tokens
    mov r14, rax
    mov rdi, r13
    lea rsi, [rip + .Lk_max_out]
    call tokens
    cmp rax, 20000
    jbe 1f
    mov eax, 20000
1:  sub r14, rax
    sub r14, 13000
    jns 2f
    xor r14d, r14d
2:  mov [rsp + AGU_window], r14
    jmp 8f
5:  mov rdi, r12
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_boundary]
    call json_is
    test eax, eax
    jz 9f
    mov qword ptr [rsp + AGU_used], 0
    mov dword ptr [rsp + AGU_cold], CCOLD_COMPACTED
    call time_ms
    mov [rsp + AGU_cache_at], rax
8:  mov rdi, rbx
    lea rsi, [rsp]
    call ev_usage
9:  EPILOGUE

# model_usage(modelUsage object, model cstr) -> rax the entry of that model (its name, or its name and "[…]")
#   that has a contextWindow, else the first that has one, else 0
model_usage:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov r13, rax
    xor r14d, r14d              # the pair
    mov qword ptr [rsp], 0      # the first with a window
1:  mov rdi, rbx
    mov esi, r14d
    call json_pair
    test rax, rax
    jz 7f
    inc r14d
    mov r15, rdx
    mov [rsp + 8], rax
    mov rdi, rdx
    lea rsi, [rip + .Lk_window]
    call json_get
    mov rdi, rax
    call json_int
    test edx, edx
    jz 1b
    cmp qword ptr [rsp], 0
    jne 2f
    mov [rsp], r15
2:  test r13, r13
    jz 1b
    mov rdi, [rsp + 8]
    call json_str
    cmp rdx, r13
    jb 1b
    mov [rsp + 8], rax
    mov rdi, rax
    mov rsi, rdx
    push rdx
    push rdx
    mov rdx, r12
    mov rcx, r13
    call str_starts
    pop rdx
    pop rdx
    test eax, eax
    jz 1b
    cmp rdx, r13
    je 3f
    mov rax, [rsp + 8]
    cmp byte ptr [rax + r13], '['
    jne 1b
3:  mov rax, r15
    EPILOGUE
7:  mov rax, [rsp]
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
.Lp_unshown: .asciz "Couldn't show the plan"     # plan review
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
.Le_settings: .asciz "Couldn't read Claude Code's settings: "
.Le_refused: .asciz "Claude Code took no more input before the conversation's settings went to it; nothing was sent."
.Lk_rate_info: .asciz "rate_limit_info"
.Lk_status: .asciz "status"
.Lsp_compacting_v: .asciz "compacting"
.Lsp_compacting: .asciz "Compacting"
.Lsp_hooks: .asciz "Running start-up hooks"
.Lsp_started: .asciz "hook_started"
.Lsp_response: .asciz "hook_response"
.Lsp_event: .asciz "hook_event"
.Lsp_start: .asciz "SessionStart"
.Lsp_setup: .asciz "Setup"
.Lk_rate_type: .asciz "rateLimitType"
.Lk_resets: .asciz "resetsAt"
.Lk_paused: .asciz "dailyCapPaused"
.Lk_admin: .asciz "adminRequestOffer"
.Lk_ov_reason: .asciz "overageDisabledReason"
.Lk_ov_resets: .asciz "overageResetsAt"
.Lk_ov_status: .asciz "overageStatus"
.Lk_util: .asciz "utilization"
.Lk_threshold: .asciz "surpassedThreshold"
.Lv_allowed: .asciz "allowed"
.Lv_allowed_warn: .asciz "allowed_warning"
.Lv_rejected: .asciz "rejected"
.Lv_five: .asciz "five_hour"
.Lv_ov_type: .asciz "overage"
.Lv_fable_type: .asciz "seven_day_overage_included"
# the rate-limit band's words (webview index.js @3896761 Atn, @3894104 qq, @3586464 sUe, the Rtn table)
.Lr_usage_limit: .asciz "usage limit"
.Lr_five: .asciz "5-hour limit"
.Lr_week: .asciz "weekly limit"
.Lr_week_opus: .asciz "weekly Opus limit"
.Lr_week_sonnet: .asciz "weekly Sonnet limit"
.Lr_fable: .asciz "Fable limit"
.Lr_credit_limit: .asciz "usage credit limit"
.Lk_t_seven: .asciz "seven_day"
.Lk_t_opus: .asciz "seven_day_opus"
.Lk_t_sonnet: .asciz "seven_day_sonnet"
.Lr_paused: .asciz "Usage is paused for your organization. For help, please contact support."
.Lr_spend: .asciz "You've hit your spend limit"
.Lr_hit: .asciz "You've hit your "
.Lr_used: .asciz "You've used "
.Lr_pct_of: .asciz "% of your "
.Lr_over: .asciz "Over "
.Lr_used_w: .asciz " used"
.Lr_near: .asciz "Approaching "
.Lr_resets: .asciz " \302\267 resets "
.Lr_your: .asciz " \302\267 your "
.Lr_resets_w: .asciz " resets "
.Lr_credits: .asciz " \302\267 continue with usage credits"
.Lr_seat: .asciz "Your seat type doesn't include usage credits"
.Lr_member: .asciz "Your usage allocation has been disabled by your admin"
.Lr_group: .asciz "Your group's usage limit is set to $0"
.Lk_seat1: .asciz "seat_tier_level_disabled"
.Lk_seat2: .asciz "seat_tier_zero_credit_limit"
.Lk_member1: .asciz "member_level_disabled"
.Lk_member2: .asciz "member_zero_credit_limit"
.Lk_group: .asciz "group_zero_credit_limit"
.Lr_more: .asciz "Get more usage"
.Lr_more_url: .asciz "https://claude.ai/settings/usage"
.Lr_soon: .asciz "soon"
.Lr_at: .asciz "at "
.Lr_at_sp: .asciz " at "
.Lr_comma: .asciz ", "
.Lr_am: .asciz " AM"
.Lr_pm: .asciz " PM"
# the auth band's words (webview index.js @3777297 authConflictWarning, @3899982 lZe); rhun is not VS Code:
#   a key saved by /login is signed out of in a terminal
.Lk_account: .asciz "account"
.Lk_subscription: .asciz "subscriptionType"
.Lk_conflict: .asciz "auth_conflict"
.Lk_token_src: .asciz "token_source"
.Lk_key_src: .asciz "api_key_source"
.Lv_profile: .asciz "profile"
.Lv_claude_ai: .asciz "claude.ai"
.Lv_login_key: .asciz "/login managed key"
.Lv_helper: .asciz "apiKeyHelper"
.Ls_claude_ai: .asciz "your claude.ai login"
.Ls_profile: .asciz "your Anthropic profile"
.Ls_login_key: .asciz "an API key saved by /login"
.Ls_helper: .asciz "an apiKeyHelper setting"
.La_both: .asciz "Claude Code has both "
.La_not_using: .asciz "Claude Code is not using "
.La_and: .asciz " and "
.La_because: .asciz ", because "
.La_expect: .asciz ", so it may not use the credential you expect."
.La_priority: .asciz " takes priority."
.La_keep: .asciz " Keep one and remove the other, then start a new conversation (restart your editor if you removed one from your shell)."
.La_only: .asciz " To use only "
.La_logout: .asciz ", run \"claude auth logout\" in a terminal to remove the saved key, then start a new conversation."
# the context and the cache (finding 21)
.Lk_type: .asciz "type"
.Lk_id: .asciz "id"
.Lk_usage: .asciz "usage"
.Lk_in: .asciz "input_tokens"
.Lk_out: .asciz "output_tokens"
.Lk_cache_read: .asciz "cache_read_input_tokens"
.Lk_cache_made: .asciz "cache_creation_input_tokens"
.Lk_cache_split: .asciz "cache_creation"
.Lk_hour: .asciz "ephemeral_1h_input_tokens"
.Lk_five: .asciz "ephemeral_5m_input_tokens"
.Lk_cost: .asciz "total_cost_usd"
.Lk_model_usage: .asciz "modelUsage"
.Lk_window: .asciz "contextWindow"
.Lk_max_out: .asciz "maxOutputTokens"
.Lv_result: .asciz "result"
.Lv_boundary: .asciz "compact_boundary"
.Lv_synthetic: .asciz "<synthetic>"
.p2align 3
rate_words: .quad .Lv_five, .Lr_five, .Lk_t_seven, .Lr_week, .Lk_t_opus, .Lr_week_opus
    .quad .Lk_t_sonnet, .Lr_week_sonnet, .Lv_fable_type, .Lr_fable, .Lv_ov_type, .Lr_credit_limit, 0, 0
reason_words: .quad .Lk_seat1, .Lr_seat, .Lk_seat2, .Lr_seat, .Lk_member1, .Lr_member, .Lk_member2, .Lr_member
    .quad .Lk_group, .Lr_group, 0, 0
source_words: .quad .Lv_claude_ai, .Ls_claude_ai, .Lv_profile, .Ls_profile, .Lv_login_key, .Ls_login_key
    .quad .Lv_helper, .Ls_helper, 0, 0
fail_words: .quad .Lf_model, .Lf_effort, .Lf_ultra_on, .Lf_think     # by CLF_*

# the spinner's verbs (index.js @5437454 ALe, 82): DRV_verbs is claudecfg.s's list, these with the
#   [claude] spinner_verb lines added or in their place ([claude] spinner_verbs)
.p2align 3
.globl claude_verbs
claude_verbs:
    .quad .Lverb_Accomplishing, .Lverb_Actioning, .Lverb_Actualizing, .Lverb_Baking, .Lverb_Booping
    .quad .Lverb_Brewing, .Lverb_Calculating, .Lverb_Cerebrating, .Lverb_Channeling, .Lverb_Churning
    .quad .Lverb_Clauding, .Lverb_Coalescing, .Lverb_Cogitating, .Lverb_Computing, .Lverb_Combobulating
    .quad .Lverb_Concocting, .Lverb_Considering, .Lverb_Contemplating, .Lverb_Cooking, .Lverb_Crafting
    .quad .Lverb_Creating, .Lverb_Crunching, .Lverb_Deciphering, .Lverb_Deliberating, .Lverb_Determining
    .quad .Lverb_Discombobulating, .Lverb_Doing, .Lverb_Effecting, .Lverb_Elucidating, .Lverb_Enchanting
    .quad .Lverb_Envisioning, .Lverb_Finagling, .Lverb_Flibbertigibbeting, .Lverb_Forging, .Lverb_Forming
    .quad .Lverb_Frolicking, .Lverb_Generating, .Lverb_Germinating, .Lverb_Hatching, .Lverb_Herding
    .quad .Lverb_Honking, .Lverb_Ideating, .Lverb_Imagining, .Lverb_Incubating, .Lverb_Inferring
    .quad .Lverb_Manifesting, .Lverb_Marinating, .Lverb_Meandering, .Lverb_Moseying, .Lverb_Mulling
    .quad .Lverb_Mustering, .Lverb_Noodling, .Lverb_Percolating, .Lverb_Perusing, .Lverb_Philosophizing
    .quad .Lverb_Pontificating, .Lverb_Pondering, .Lverb_Processing, .Lverb_Puttering, .Lverb_Puzzling
    .quad .Lverb_Reticulating, .Lverb_Ruminating, .Lverb_Schlepping, .Lverb_Shimmying, .Lverb_Simmering
    .quad .Lverb_Smooshing, .Lverb_Spelunking, .Lverb_Spinning, .Lverb_Stewing, .Lverb_Sussing
    .quad .Lverb_Synthesizing, .Lverb_Thinking, .Lverb_Tinkering, .Lverb_Transmuting, .Lverb_Unfurling
    .quad .Lverb_Unraveling, .Lverb_Vibing, .Lverb_Wandering, .Lverb_Whirring, .Lverb_Wibbling
    .quad .Lverb_Working, .Lverb_Wrangling
    .quad 0
.Lverb_Accomplishing: .asciz "Accomplishing"
.Lverb_Actioning: .asciz "Actioning"
.Lverb_Actualizing: .asciz "Actualizing"
.Lverb_Baking: .asciz "Baking"
.Lverb_Booping: .asciz "Booping"
.Lverb_Brewing: .asciz "Brewing"
.Lverb_Calculating: .asciz "Calculating"
.Lverb_Cerebrating: .asciz "Cerebrating"
.Lverb_Channeling: .asciz "Channeling"
.Lverb_Churning: .asciz "Churning"
.Lverb_Clauding: .asciz "Clauding"
.Lverb_Coalescing: .asciz "Coalescing"
.Lverb_Cogitating: .asciz "Cogitating"
.Lverb_Computing: .asciz "Computing"
.Lverb_Combobulating: .asciz "Combobulating"
.Lverb_Concocting: .asciz "Concocting"
.Lverb_Considering: .asciz "Considering"
.Lverb_Contemplating: .asciz "Contemplating"
.Lverb_Cooking: .asciz "Cooking"
.Lverb_Crafting: .asciz "Crafting"
.Lverb_Creating: .asciz "Creating"
.Lverb_Crunching: .asciz "Crunching"
.Lverb_Deciphering: .asciz "Deciphering"
.Lverb_Deliberating: .asciz "Deliberating"
.Lverb_Determining: .asciz "Determining"
.Lverb_Discombobulating: .asciz "Discombobulating"
.Lverb_Doing: .asciz "Doing"
.Lverb_Effecting: .asciz "Effecting"
.Lverb_Elucidating: .asciz "Elucidating"
.Lverb_Enchanting: .asciz "Enchanting"
.Lverb_Envisioning: .asciz "Envisioning"
.Lverb_Finagling: .asciz "Finagling"
.Lverb_Flibbertigibbeting: .asciz "Flibbertigibbeting"
.Lverb_Forging: .asciz "Forging"
.Lverb_Forming: .asciz "Forming"
.Lverb_Frolicking: .asciz "Frolicking"
.Lverb_Generating: .asciz "Generating"
.Lverb_Germinating: .asciz "Germinating"
.Lverb_Hatching: .asciz "Hatching"
.Lverb_Herding: .asciz "Herding"
.Lverb_Honking: .asciz "Honking"
.Lverb_Ideating: .asciz "Ideating"
.Lverb_Imagining: .asciz "Imagining"
.Lverb_Incubating: .asciz "Incubating"
.Lverb_Inferring: .asciz "Inferring"
.Lverb_Manifesting: .asciz "Manifesting"
.Lverb_Marinating: .asciz "Marinating"
.Lverb_Meandering: .asciz "Meandering"
.Lverb_Moseying: .asciz "Moseying"
.Lverb_Mulling: .asciz "Mulling"
.Lverb_Mustering: .asciz "Mustering"
.Lverb_Noodling: .asciz "Noodling"
.Lverb_Percolating: .asciz "Percolating"
.Lverb_Perusing: .asciz "Perusing"
.Lverb_Philosophizing: .asciz "Philosophizing"
.Lverb_Pontificating: .asciz "Pontificating"
.Lverb_Pondering: .asciz "Pondering"
.Lverb_Processing: .asciz "Processing"
.Lverb_Puttering: .asciz "Puttering"
.Lverb_Puzzling: .asciz "Puzzling"
.Lverb_Reticulating: .asciz "Reticulating"
.Lverb_Ruminating: .asciz "Ruminating"
.Lverb_Schlepping: .asciz "Schlepping"
.Lverb_Shimmying: .asciz "Shimmying"
.Lverb_Simmering: .asciz "Simmering"
.Lverb_Smooshing: .asciz "Smooshing"
.Lverb_Spelunking: .asciz "Spelunking"
.Lverb_Spinning: .asciz "Spinning"
.Lverb_Stewing: .asciz "Stewing"
.Lverb_Sussing: .asciz "Sussing"
.Lverb_Synthesizing: .asciz "Synthesizing"
.Lverb_Thinking: .asciz "Thinking"
.Lverb_Tinkering: .asciz "Tinkering"
.Lverb_Transmuting: .asciz "Transmuting"
.Lverb_Unfurling: .asciz "Unfurling"
.Lverb_Unraveling: .asciz "Unraveling"
.Lverb_Vibing: .asciz "Vibing"
.Lverb_Wandering: .asciz "Wandering"
.Lverb_Whirring: .asciz "Whirring"
.Lverb_Wibbling: .asciz "Wibbling"
.Lverb_Working: .asciz "Working"
.Lverb_Wrangling: .asciz "Wrangling"
