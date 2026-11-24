# Claude Code's dialogs that show what the CLI reports (phase 7): Status, Account & usage, Context usage,
# Output styles, the slash commands browser, Memory, Instructions. Each is the generic shell's
# (agentdlg.s) filled from the answer to one of Claude Code's control requests (README findings 60 to 66);
# nothing above the driver knows them. Reached through DRV_action (claude_action: ACT_STATUS ..
# ACT_INSTRUCT), the answers through agent_claude.s's OA_DIALOG (claude_dlg_answer).
#
# With no process running: Status, Account & usage, Context usage, Output styles, Memory and Instructions
# start one quietly for their request, as the extension's session does (launchClaude before get_status,
# get_usage, get_context_usage, get_memory_dialog; its output styles come from the started process); the
# slash commands browser starts none (getSkillsDialog({startClaude: false})): it lists the commands rhun
# keeps, and a running process adds each skill's source, size and state.
#
# The account (initialize's answer: email, organization, subscriptionType, apiProvider, apiKeySource) is
# kept in memory only while rhun runs, to show in Account & usage; it is never logged or written.
#
#   claude_dlg_open(AL*, act, ptr, len) -> eax 1    the dialog of that command (0: not one of them)
#   claude_dlg_answer(AL*, control_response's response, n)   an answer to the dialog's request n
#   claude_dlg_init(AL*, initialize's response)    the account and the output style kept
#   claude_usage_section(x, y, w, sb or 0) -> eax h   row 5.14's "Account & usage" for a list view
#   claude_usage_toggle()                   it folds or unfolds
.include "rhun.inc"

.equ K_STATUS, 0                # the dialogs (kinds, the table's rows)
.equ K_USAGE, 1
.equ K_CONTEXT, 2
.equ K_OSTYLE, 3
.equ K_SKILLS, 4
.equ K_MEMORY, 5
.equ K_INSTRUCT, 6
.equ K_COUNT, 7
.equ KT_NAME, 0                 # a row of kinds: name, title, loading text, request, start, failure's start
.equ KT_TITLE, 8
.equ KT_LOADING, 16
.equ KT_REQ, 24
.equ KT_START, 32
.equ KT_FAIL, 40
.equ KT_SIZE, 48
.equ RQ_MAIN, 1                 # what the awaited request is
.equ RQ_PICK, 2                 # update_settings: an output style picked
.equ RQ_STATE, 3                # set_skill_state
.equ RQ_SETTING, 4              # set_memory_setting
.equ CA_RETRY, 1                # the dialogs' acts
.equ CA_STYLE, 2                # arg: the style's index
.equ CA_SELECT, 3               # arg: the command's index (keep)
.equ CA_STATE, 4                # arg: the skill's index (skills)
.equ CA_TOGGLE, 5               # arg: 0 auto-memory, 1 auto-dream
.equ CA_OPEN, 6                 # arg: the file's index (keep)
.equ CA_FOLDER, 7               # arg: the folder's index (keep)
.equ CA_MANAGE, 8               # Manage usage on claude.ai
.equ SK_SIZE, 48                # a skill kept: name, handles (JSON text), state, source (owned cstrs),
.equ SK_name, 0                 #   its tokens, whether a command named it, whether it is locked
.equ SK_handles, 8
.equ SK_state, 16
.equ SK_source, 24
.equ SK_tokens, 32
.equ SK_matched, 40
.equ SK_locked, 44
.equ TOP_N, 5                   # Context usage: memory files and agents shown at most
.equ PICK_MAX, 64               # Context usage: entries looked at for the top five
.equ COLORS_N, 8
.equ METERS, 4                  # the list's Account & usage: meters kept at most
.equ METER_LABEL, 48            #   and a label's room

.data
.p2align 3
cd_kind: .quad -1

.bss
.p2align 3
fsb: .zero SB_SIZE              # a text being made
fsb2: .zero SB_SIZE
keep: .zero VEC_SIZE            # owned cstrs the rows' args name (paths, styles, commands)
labels: .zero VEC_SIZE          # owned cstrs: a file row's label (Instructions' toast)
skills: .zero VEC_SIZE          # SK
picks: .zero 16 * PICK_MAX      # {tokens, index}
cd_as: .quad 0                  # the conversation of the open dialog
cd_rq: .quad 0                  # the request asked (RQ_*)
cd_pend_rq: .quad 0             # the request to ask once the process is ready
cd_arg: .quad 0                 # the pending request's argument: a style's name, a skill's index, a setting
cd_bool: .quad 0
acct_email: .quad 0             # initialize's account, in memory only (owned cstrs or 0)
acct_org: .quad 0
acct_plan: .quad 0
acct_provider: .quad 0
acct_keysrc: .quad 0
cur_style: .quad 0              # the output style in effect (owned cstr or 0: "default")
meters: .zero 16 * METERS       # {label (meter_labels'), percent}: the last get_usage's limits
meter_labels: .zero METER_LABEL * METERS
meters_n: .quad 0
usage_open: .long 0             # the list's Account & usage is unfolded
mem_on: .long 0                 # the memory switches as shown
dream_on: .long 0

.text

# ---- initialize's answer ----

# FN claude_dlg_init(AL*, response object): the account and the output style kept (in memory only)
FN claude_dlg_init
    PROLOGUE
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Lk_account]
    call json_get
    mov rbx, rax
    lea r13, [rip + acct_keys]
1:  mov rsi, [r13]
    test rsi, rsi
    jz 2f
    mov r14, [r13 + 8]          # the slot
    mov rdi, [r14]
    call mem_free
    mov qword ptr [r14], 0
    mov rdi, rbx
    mov rsi, [r13]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 11f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [r14], rax
11: add r13, 16
    jmp 1b
2:  mov rdi, r12                # the output style in effect
    lea rsi, [rip + .Lk_output_style]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call set_style
9:  EPILOGUE

# set_style(ptr, len): cur_style
set_style:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rip + cur_style]
    call mem_free
    mov rdi, rbx
    mov rsi, r12
    call mem_dup
    mov [rip + cur_style], rax
    EPILOGUE

# ---- opening, asking ----

# FN claude_dlg_open(AL*, act, ptr, len) -> eax 1 when act is one of the dialogs': it opens over the panel
FN claude_dlg_open
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    lea ecx, [rsi - ACT_STATUS]
    cmp ecx, K_COUNT
    jae 9f
    test rbx, rbx
    jz 9f
    mov r12d, ecx               # the kind (the acts are in the kinds' order)
    call free_keeps
    mov [rip + cd_kind], r12
    mov rax, [rbx + AL_as]
    mov [rip + cd_as], rax
    imul r13, r12, KT_SIZE
    lea rax, [rip + kinds]
    add r13, rax
    mov rdi, [rbx + AL_as]
    mov rsi, [r13 + KT_NAME]
    mov rdx, [r13 + KT_TITLE]
    lea rcx, [rip + cd_ops]
    call agentdlg_open
    mov [rip + cd_kind], r12    # (the dialog before was freed by the open)
    mov rax, [rbx + AL_as]
    mov [rip + cd_as], rax
    cmp r12d, K_SKILLS
    jne 1f
    xor edi, edi                # the commands kept; a running process adds the skills
    call build_skills
    mov rdi, rbx
    call is_up
    test eax, eax
    jz 8f
    mov edi, RQ_MAIN
    call ask
    jmp 8f
1:  cmp r12d, K_USAGE
    jne 2f
    xor edi, edi                # the account at once, the usage when it comes
    xor esi, esi
    call build_usage
    jmp 3f
2:  mov rdi, [r13 + KT_LOADING]
    call agentdlg_loading
3:  mov edi, RQ_MAIN
    call ask
8:  mov eax, 1
9:  EPILOGUE

# is_up(AL*) -> eax 1 when its process is up and past its handshake
is_up:
    xor eax, eax
    test rdi, rdi
    jz 9f
    cmp dword ptr [rdi + AL_cn + CN_state], CN_UP
    jne 9f
    mov ecx, [rdi + AL_state]
    cmp ecx, ALS_READY
    je 1f
    cmp ecx, ALS_WORKING
    je 1f
    cmp ecx, ALS_WAITING
    jne 9f
1:  mov eax, 1
9:  ret

# ask(rq): the dialog's request now (the process up), once the process is ready (starting), or after
#   starting it quietly (off, for the dialogs that start one); else it says what it needs
ask:
    PROLOGUE
    mov r12d, edi
    mov rdi, [rip + cd_as]
    test rdi, rdi
    jz 9f
    call agent_live
    mov rbx, rax
    test rax, rax
    jz 9f
    mov rdi, rbx
    call is_up
    test eax, eax
    jz 1f
    mov edi, r12d
    mov rsi, rbx
    call send
    jmp 9f
1:  mov eax, [rbx + AL_state]
    cmp eax, ALS_STARTING
    je 3f
    cmp eax, ALS_HELD
    je 3f
    mov rcx, [rip + cd_kind]    # off or failed: started for its request, when the dialog does that
    imul rcx, rcx, KT_SIZE
    lea rdx, [rip + kinds]
    cmp qword ptr [rdx + rcx + KT_START], 0
    je 9f
    mov rdi, [rbx + AL_as]
    call agent_run
    mov rdi, [rip + cd_as]
    call agent_live
    mov rbx, rax
    mov rdi, rax
    call is_up
    test eax, eax
    jz 2f
    mov edi, r12d
    mov rsi, rbx
    call send
    jmp 9f
2:  mov eax, [rbx + AL_state]
    cmp eax, ALS_STARTING
    je 3f
    cmp eax, ALS_HELD
    je 3f
    lea rdi, [rip + fsb]        # it could not start: what it said, else that
    call sb_clear
    mov rdx, [rbx + AL_report + SB_len]
    lea rdi, [rip + fsb]
    mov rsi, [rbx + AL_report + SB_ptr]
    test rdx, rdx
    jnz 21f
    lea rsi, [rip + .Lno_start]
    call sb_push_cstr
    jmp 22f
21: call sb_push
22: mov rdi, [rip + fsb + SB_ptr]
    mov rsi, [rip + fsb + SB_len]
    call agentdlg_fail
    jmp 9f
3:  mov [rip + cd_pend_rq], r12
    mov rdi, rbx
    call agentdlg_pend
9:  EPILOGUE

# send(rq, AL*): the request written, the dialog waiting for its answer
send:
    PROLOGUE
    mov r12d, edi
    mov rbx, rsi
    mov [rip + cd_rq], r12
    cmp r12d, RQ_MAIN
    jne 1f
    mov rcx, [rip + cd_kind]
    imul rcx, rcx, KT_SIZE
    lea rdx, [rip + kinds]
    mov rsi, [rdx + rcx + KT_REQ]
    mov rdi, rbx
    call claude_dlg_begin
    mov r13, rax
    jmp 8f
1:  cmp r12d, RQ_PICK           # {"subtype":"update_settings","source":"localSettings","settings":{"outputStyle":NAME}}
    jne 2f
    mov rdi, rbx
    lea rsi, [rip + .Lv_update_settings]
    call claude_dlg_begin
    mov r13, rax
    call claude_dlg_cw
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .Lk_source]
    call jw_key
    mov rdi, r14
    lea rsi, [rip + .Lv_local]
    call jw_cstr
    mov rdi, r14
    lea rsi, [rip + .Lk_settings]
    call jw_key
    mov rdi, r14
    call jw_obj
    mov rdi, r14
    lea rsi, [rip + .Lk_outputStyle]
    call jw_key
    mov rdi, r14
    mov rsi, [rip + cd_arg]
    call jw_cstr
    mov rdi, r14
    call jw_end_obj
    jmp 8f
2:  cmp r12d, RQ_STATE          # {"subtype":"set_skill_state","name":N,"state":S,"handles":H}
    jne 3f
    mov rdi, rbx
    lea rsi, [rip + .Lv_set_skill]
    call claude_dlg_begin
    mov r13, rax
    call claude_dlg_cw
    mov r14, rax
    mov rax, [rip + cd_arg]
    imul r15, rax, SK_SIZE
    add r15, [rip + skills + VEC_ptr]
    mov rdi, r14
    lea rsi, [rip + .Lk_name]
    call jw_key
    mov rdi, r14
    mov rsi, [r15 + SK_name]
    call jw_cstr
    mov rdi, r14
    lea rsi, [rip + .Lk_state]
    call jw_key
    mov rdi, [r15 + SK_state]
    call next_state
    mov rsi, rax
    mov rdi, r14
    call jw_cstr
    mov rdi, r14
    lea rsi, [rip + .Lk_handles]
    call jw_key
    mov rsi, [r15 + SK_handles]
    mov rdi, rsi
    call strlen
    mov rdx, rax
    mov rdi, r14
    mov rsi, [r15 + SK_handles]
    call jw_rawn
    jmp 8f
3:  mov rdi, rbx                # {"subtype":"set_memory_setting","setting":S,"enabled":B}
    lea rsi, [rip + .Lv_set_memory]
    call claude_dlg_begin
    mov r13, rax
    call claude_dlg_cw
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .Lk_setting]
    call jw_key
    lea rsi, [rip + .Lv_auto_memory]
    cmp qword ptr [rip + cd_arg], 0
    je 31f
    lea rsi, [rip + .Lv_auto_dream]
31: mov rdi, r14
    call jw_cstr
    mov rdi, r14
    lea rsi, [rip + .Lk_enabled]
    call jw_key
    mov rdi, r14
    mov rsi, [rip + cd_bool]
    call jw_bool
8:  mov rdi, rbx
    call claude_dlg_end
    test eax, eax
    jz 7f
    mov rdi, rbx
    mov rsi, r13
    call agentdlg_wait
    EPILOGUE
7:  lea rdi, [rip + .Lnot_sent]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Lnot_sent]
    call agentdlg_fail
    EPILOGUE

# ---- the shell's calls ----

# cd_act(act, arg, DGR* or 0)
cd_act:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    cmp r12d, DA_ASK            # the handshake is done (ev_ready, before READY is set): ask now
    jne 1f
    mov rdi, [rip + cd_as]
    call agent_live
    test rax, rax
    jz 9f
    cmp dword ptr [rax + AL_cn + CN_state], CN_UP
    jne 9f
    mov rdi, [rip + cd_pend_rq]
    mov rsi, rax
    call send
    jmp 9f
1:  cmp r12d, CA_RETRY
    jne 2f
    mov rax, [rip + cd_kind]
    cmp eax, K_USAGE
    jne 11f
    xor edi, edi
    xor esi, esi
    call build_usage
    jmp 12f
11: imul rax, rax, KT_SIZE
    lea rcx, [rip + kinds]
    mov rdi, [rcx + rax + KT_LOADING]
    call agentdlg_loading
12: mov edi, RQ_MAIN
    call ask
    jmp 9f
2:  cmp r12d, CA_STYLE
    jne 3f
    mov rdi, r13                # the style's name, then update_settings
    call keep_at
    test rax, rax
    jz 9f
    mov [rip + cd_arg], rax
    mov edi, RQ_PICK
    call ask
    jmp 9f
3:  cmp r12d, CA_SELECT
    jne 4f
    mov edi, r13d               # "/name " into the box (the low half of the arg)
    call keep_at
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov r14, rax
    call agentext_box
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r14
    call tf_set
    call agentdlg_close
    call agentext_box_changed
    jmp 9f
4:  cmp r12d, CA_STATE
    jne 5f
    shr r13, 32                 # the skill: the arg's high half, from 1
    dec r13
    cmp r13, [rip + skills + VEC_len]
    jae 9f
    mov [rip + cd_arg], r13
    mov edi, RQ_STATE
    call ask
    jmp 9f
5:  cmp r12d, CA_TOGGLE
    jne 6f
    mov [rip + cd_arg], r13
    mov eax, [rip + mem_on]
    test r13, r13
    jz 51f
    mov eax, [rip + dream_on]
51: xor eax, 1
    mov [rip + cd_bool], rax
    mov edi, RQ_SETTING
    call ask
    jmp 9f
6:  cmp r12d, CA_OPEN
    jne 7f
    mov rdi, r13
    call keep_at
    test rax, rax
    jz 9f
    mov rdi, rax
    call claude_expand_home
    mov rdi, rax
    call app_open_file
    cmp qword ptr [rip + cd_kind], K_INSTRUCT
    jne 61f
    lea rdi, [rip + fsb]        # Instructions: what the extension's notification says (webview @5926026)
    call sb_clear
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Li_reads]
    call sb_push_cstr
    mov rdi, r13
    lea rsi, [rip + labels]
    call vec_cstr
    mov rsi, rax
    lea rdi, [rip + fsb]
    call sb_push_cstr
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Li_reload]
    call sb_push_cstr
    lea rdi, [rip + fsb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + fsb + SB_ptr]
    call app_toast
61: call agentdlg_close
    jmp 9f
7:  cmp r12d, CA_FOLDER
    jne 8f
    mov rdi, r13
    call keep_at
    test rax, rax
    jz 9f
    mov rdi, rax
    call claude_expand_home
    mov rdi, rax
    call desktop_open
    jmp 9f
8:  cmp r12d, CA_MANAGE
    jne 9f
    lea rsi, [rip + .Lu_settings]   # the extension's AUe: the admin page for a team or enterprise plan
    mov rdi, [rip + acct_plan]
    test rdi, rdi
    jz 81f
    lea rsi, [rip + .Lv_team]
    call strcmp_eq
    lea rsi, [rip + .Lu_admin]
    test eax, eax
    jnz 81f
    mov rdi, [rip + acct_plan]
    lea rsi, [rip + .Lv_enterprise]
    call strcmp_eq
    lea rsi, [rip + .Lu_admin]
    test eax, eax
    jnz 81f
    lea rsi, [rip + .Lu_settings]
81: lea rdi, [rip + .Lwho]
    call links_ask_open
9:  EPILOGUE

# cd_free(): the dialog closed
cd_free:
    PROLOGUE
    mov qword ptr [rip + cd_kind], -1
    mov qword ptr [rip + cd_as], 0
    mov qword ptr [rip + cd_rq], 0
    call free_keeps
    EPILOGUE

# free_keeps(): keep, labels and skills emptied
free_keeps:
    PROLOGUE
    lea rdi, [rip + keep]
    call free_cstrs
    lea rdi, [rip + labels]
    call free_cstrs
    xor ebx, ebx
1:  cmp rbx, [rip + skills + VEC_len]
    jae 2f
    imul r12, rbx, SK_SIZE
    add r12, [rip + skills + VEC_ptr]
    mov rdi, [r12 + SK_name]
    call mem_free
    mov rdi, [r12 + SK_handles]
    call mem_free
    mov rdi, [r12 + SK_state]
    call mem_free
    mov rdi, [r12 + SK_source]
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + skills + VEC_len], 0
    EPILOGUE

# free_cstrs(VEC*): its owned cstrs freed, emptied
free_cstrs:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + VEC_len]
    jae 2f
    mov rax, [rbx + VEC_ptr]
    mov rdi, [rax + r12*8]
    call mem_free
    inc r12
    jmp 1b
2:  mov qword ptr [rbx + VEC_len], 0
    EPILOGUE

# keep_add(VEC*, ptr, len) -> rax its index: an owned copy kept
keep_add:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call mem_dup
    mov r12, rax
    mov rdi, rbx
    mov esi, 8
    call vec_push
    mov [rax], r12
    mov rax, [rbx + VEC_len]
    dec rax
    EPILOGUE

# keep_at(i) -> rax keep's cstr i, or 0
keep_at:
    lea rsi, [rip + keep]
# vec_cstr(i, VEC*) -> rax its cstr i, or 0
vec_cstr:
    xor eax, eax
    cmp rdi, [rsi + VEC_len]
    jae 1f
    mov rax, [rsi + VEC_ptr]
    mov rax, [rax + rdi*8]
1:  ret

# ---- answers ----

# FN claude_dlg_answer(AL*, control_response's response, n): the answer the open dialog waits for fills it
#   (an error: its failure); any other is dropped
FN claude_dlg_answer
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov rsi, rdx
    call agentdlg_waits
    test eax, eax
    jz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_success]
    call json_is
    test eax, eax
    jz .La_error
    mov rdi, r12
    lea rsi, [rip + .Lk_response]
    call json_get
    mov r13, rax                # its answer (0 for a success without one)
    mov rax, [rip + cd_rq]
    cmp eax, RQ_PICK
    je .La_picked
    cmp eax, RQ_MAIN
    je 1f
    cmp eax, RQ_STATE
    je .La_skills
    cmp eax, RQ_SETTING
    je .La_memory
    jmp 9f
1:  mov rax, [rip + cd_kind]
    cmp eax, K_STATUS
    je .La_status
    cmp eax, K_USAGE
    je .La_usage
    cmp eax, K_CONTEXT
    je .La_context
    cmp eax, K_OSTYLE
    je .La_ostyle
    cmp eax, K_SKILLS
    je .La_skills
    jmp .La_memory
.La_status:
    mov rdi, r13
    call build_status
    jmp 9f
.La_usage:
    mov rdi, r13
    xor esi, esi
    call build_usage
    jmp 9f
.La_context:
    mov rdi, r13
    call build_context
    jmp 9f
.La_ostyle:
    mov rdi, r13
    call build_ostyle
    jmp 9f
.La_skills:
    mov rdi, r13                # set_skill_state's answer: {dialog: {skills}} (the extension's), or
    lea rsi, [rip + .Lk_dialog] #   {skills} as get_skills_dialog's (finding 64)
    call json_get
    test rax, rax
    jz 21f
    mov r13, rax
21: mov rdi, r13
    call build_skills
    jmp 9f
.La_memory:
    mov rdi, r13
    lea rsi, [rip + .Lk_dialog]
    call json_get
    test rax, rax
    jz 31f
    mov r13, rax
31: mov rdi, r13
    call build_memory
    jmp 9f
.La_picked:
    mov rdi, [rip + cd_arg]     # the style is in effect for this project: the picker closes
    call strlen
    mov rsi, rax
    mov rdi, [rip + cd_arg]
    call set_style
    call agentdlg_close
    jmp 9f
.La_error:
    mov rdi, r12
    lea rsi, [rip + .Lk_error]
    call json_get
    mov rdi, rax
    call json_str
    mov r13, rax
    mov r14, rdx
    lea rdi, [rip + fsb]
    call sb_clear
    mov rax, [rip + cd_rq]
    cmp eax, RQ_MAIN
    jne 41f
    mov rax, [rip + cd_kind]
    cmp eax, K_USAGE
    jne 40f
    xor edi, edi                # Account & usage: "Failed to load usage data" and Retry (the extension's)
    mov esi, 1
    call build_usage
    jmp 9f
40: imul rax, rax, KT_SIZE       # its own request failed: nothing but the words and Retry
    lea rcx, [rip + kinds]
    mov rsi, [rcx + rax + KT_FAIL]
    lea rdi, [rip + fsb]
    call sb_push_cstr
    call agentdlg_begin
41: lea rdi, [rip + fsb]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    mov rdi, [rip + fsb + SB_ptr]
    mov rsi, [rip + fsb + SB_len]
    call agentdlg_fail
    mov rax, [rip + cd_rq]      # a request of its own failed: Retry
    cmp eax, RQ_MAIN
    jne 9f
    lea rdi, [rip + .Lretry]
    mov esi, CA_RETRY
    mov edx, DBF_PRIMARY
    call agentdlg_button
9:  EPILOGUE

# ---- small builders ----

# row_c(kind, flags, act, t1 cstr or 0) -> rax DGR*
row_c:
    PROLOGUE
    mov rbx, rcx
    call agentdlg_row
    mov r12, rax
    test rbx, rbx
    jz 9f
    mov rdi, rax
    xor esi, esi
    mov rdx, rbx
    call agentdlg_ctext
9:  mov rax, r12
    EPILOGUE

# head(title cstr) -> rax DGR*: a section's title
head:
    mov rcx, rdi
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    jmp row_c

# text_row(cstr, flags) -> rax DGR*
text_row:
    mov rcx, rdi
    mov edi, DGK_TEXT
    xor edx, edx
    jmp row_c

# pair_s(label cstr, value ptr, len): a label and its value
pair_s:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    mov rcx, rdi
    mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    call row_c
    mov rdi, rax
    mov esi, 1
    mov rdx, r12
    mov rcx, r13
    call agentdlg_text
    EPILOGUE

# jget_str(obj, key cstr) -> rax ptr, rdx len (0, 0: not a string)
jget_str:
    PROLOGUE
    call json_get
    mov rdi, rax
    call json_str
    EPILOGUE

# jget_num(obj, key cstr) -> rax its integer part (a number's text, truncated), edx 1 when it is a number
jget_num:
    PROLOGUE
    call json_get
    mov rdi, rax
    call num_int
    EPILOGUE

# num_int(jv) -> rax a number's integer part, edx 1 when jv is a number
num_int:
    PROLOGUE
    mov rbx, rdi
    call json_type
    cmp eax, JT_NUM
    jne 8f
    mov rdi, rbx
    call json_num_text
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d              # the sign
    xor ecx, ecx
    test r13, r13
    jz 8f
    cmp byte ptr [r12], '-'
    jne 1f
    mov r14d, 1
    inc rcx
1:  xor eax, eax
2:  cmp rcx, r13
    jae 3f
    movzx edx, byte ptr [r12 + rcx]
    sub edx, '0'
    cmp edx, 9
    ja 3f
    imul rax, rax, 10
    add rax, rdx
    inc rcx
    jmp 2b
3:  test r14d, r14d
    jz 5f
    neg rax
5:  mov edx, 1
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# scaled(jv, digits) -> rax round(value x 10^digits) of a non-negative number (exponents read), edx 1 a number
scaled:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov rdi, rbx
    call json_type
    cmp eax, JT_NUM
    jne 8f
    mov rdi, rbx
    call json_num_text
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d              # the mantissa's digits as an integer
    xor r15d, r15d              # the decimal exponent of its last digit
    xor ecx, ecx
    xor r8d, r8d                # after the point
    xor r9d, r9d                # digits taken (at most 17)
1:  cmp rcx, r13
    jae 4f
    movzx eax, byte ptr [r12 + rcx]
    inc rcx
    cmp eax, '.'
    jne 2f
    mov r8d, 1
    jmp 1b
2:  cmp eax, 'e'
    je 3f
    cmp eax, 'E'
    je 3f
    sub eax, '0'
    cmp eax, 9
    ja 1b
    cmp r9d, 17
    jae 21f
    imul r14, r14, 10
    add r14, rax
    inc r9d
    test r8d, r8d
    jz 1b
    dec r15d
    jmp 1b
21: test r8d, r8d               # a digit past what is kept: before the point it still counts
    jnz 1b
    inc r15d
    jmp 1b
3:  xor r10d, r10d              # the exponent
    xor r11d, r11d
    cmp rcx, r13
    jae 4f
    movzx eax, byte ptr [r12 + rcx]
    cmp eax, '-'
    jne 31f
    mov r11d, 1
    inc rcx
    jmp 32f
31: cmp eax, '+'
    jne 32f
    inc rcx
32: cmp rcx, r13
    jae 33f
    movzx eax, byte ptr [r12 + rcx]
    sub eax, '0'
    cmp eax, 9
    ja 33f
    imul r10d, r10d, 10
    add r10d, eax
    inc rcx
    jmp 32b
33: test r11d, r11d
    jz 34f
    neg r10d
34: add r15d, r10d
4:  add r15d, [rsp]             # value x 10^digits = mantissa x 10^r15
    mov rax, r14
5:  test r15d, r15d
    jz 7f
    js 6f
    mov rcx, 1000000000000000
    cmp rax, rcx
    ja 7f
    imul rax, rax, 10
    dec r15d
    jmp 5b
6:  cmp r15d, -1                # dividing: the last step rounds
    jne 61f
    add rax, 5
61: xor edx, edx
    mov rcx, 10
    div rcx
    inc r15d
    jmp 5b
7:  mov edx, 1
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# put_tenths(sb, tenths, suffix cstr): "N.N" then the suffix
put_tenths:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rax, r12
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r14, rdx
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    mov esi, '.'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r14
    call sb_push_u64
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    EPILOGUE

# put_tokens(sb, n, lower): the extension's ev ("12.3k", "1.0M", "512"); lower: sE's compact form
#   ("12.3k", "1.2m": the same digits, a lower-case m)
put_tokens:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    cmp r12, 1000000
    jb 1f
    mov rax, r12
    add rax, 50000
    xor edx, edx
    mov ecx, 100000
    div rcx
    mov rsi, rax
    lea rdx, [rip + .Lsfx_M]
    test r13d, r13d
    jz 11f
    lea rdx, [rip + .Lsfx_m]
11: mov rdi, rbx
    call put_tenths
    EPILOGUE
1:  cmp r12, 1000
    jb 2f
    mov rax, r12
    add rax, 50
    xor edx, edx
    mov ecx, 100
    div rcx
    mov rsi, rax
    lea rdx, [rip + .Lsfx_k]
    mov rdi, rbx
    call put_tenths
    EPILOGUE
2:  mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    EPILOGUE

# put_pct(sb, part, whole): the extension's kAn: "<0.1%" or "N.N%"
put_pct:
    PROLOGUE
    mov rbx, rdi
    test rdx, rdx
    jz 8f
    mov rax, rsi
    imul rax, rax, 1000
    mov rcx, rdx
    shr rdx, 1
    add rax, rdx
    xor edx, edx
    div rcx
    test rax, rax
    jnz 1f
    mov rdi, rbx
    lea rsi, [rip + .Lpct_small]
    call sb_push_cstr
    EPILOGUE
1:  mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lsfx_pct]
    call put_tenths
8:  EPILOGUE

# ---- Status ----

# build_status(response): sections of rows (finding 60), the extension's label names (rzn)
build_status:
    PROLOGUE 16
    mov rdi, rdi
    lea rsi, [rip + .Lk_sections]
    call json_get
    mov rbx, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    je 1f
    lea rdi, [rip + .Ls_none]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Ls_none]
    call agentdlg_fail
    EPILOGUE
1:  call agentdlg_begin
    xor r12d, r12d
2:  mov rdi, rbx
    call json_len
    cmp r12d, eax
    jae 8f
    mov rdi, rbx
    mov esi, r12d
    call json_at
    mov r13, rax
    inc r12d
    mov rdi, r13
    lea rsi, [rip + .Lk_title]
    call jget_str
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    call agentdlg_text
    mov rdi, r13
    lea rsi, [rip + .Lk_rows]
    call json_get
    mov r14, rax
    xor r15d, r15d
3:  mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 2b
    mov rdi, r14
    mov esi, r15d
    call json_at
    inc r15d
    mov [rsp], rax
    mov rdi, rax
    lea rsi, [rip + .Lk_label]
    call jget_str
    mov rdi, rax
    mov rsi, rdx
    call status_label           # rax cstr
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    mov rcx, rdi
    mov edi, DGK_PAIR
    call row_c
    mov [rsp + 8], rax
    mov rdi, [rsp]
    lea rsi, [rip + .Lk_value]
    call jget_str
    mov rdi, [rsp + 8]
    mov esi, 1
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    jmp 3b
8:  EPILOGUE

# status_label(ptr, len) -> rax a cstr: the extension's names for some (cwd: Working folder, Peer address:
#   Messaging address, Session kind: Session type), else the label as it came (in fsb2)
status_label:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rip + label_map]
1:  mov rdx, [r13]
    test rdx, rdx
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 3f
    add r13, 16
    jmp 1b
3:  mov rax, [r13 + 8]
    EPILOGUE
2:  lea rdi, [rip + fsb2]
    call sb_clear
    test r12, r12
    jz 21f
    lea rdi, [rip + fsb2]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
21: lea rdi, [rip + fsb2]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + fsb2 + SB_ptr]
    EPILOGUE

# ---- Account & usage ----

# auth_label() -> rax the extension's "Auth method" (AOn) from initialize's account, edx 1 for a claude.ai
#   sign-in (whose email, organization and plan show)
auth_label:
    PROLOGUE
    mov rbx, [rip + acct_provider]
    test rbx, rbx
    jz 2f
    mov rdi, rbx
    lea rsi, [rip + .Lv_first_party]
    call strcmp_eq
    test eax, eax
    jnz 2f
    lea r12, [rip + provider_map]   # another provider (3p)
1:  mov rsi, [r12]
    test rsi, rsi
    jz 11f
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jnz 12f
    add r12, 16
    jmp 1b
11: lea rax, [rip + .La_third]
    xor edx, edx
    EPILOGUE
12: mov rax, [r12 + 8]
    xor edx, edx
    EPILOGUE
2:  lea rax, [rip + .La_claude]
    mov edx, 1
    cmp qword ptr [rip + acct_plan], 0
    jne 9f
    xor edx, edx
    lea rax, [rip + .La_key]
    cmp qword ptr [rip + acct_keysrc], 0
    jne 9f
    lea rax, [rip + .La_console]
    cmp qword ptr [rip + acct_email], 0
    jne 9f
    lea rax, [rip + .La_none]
9:  EPILOGUE

# build_usage(response or 0, failed): Account (initialize's), then Usage: its bars, the session's totals,
#   or why there are none; "Loading usage data…" before the answer, "Failed to load usage data" and Retry
#   after a refusal (the extension's AOt, IOn)
build_usage:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    call agentdlg_begin
    lea rdi, [rip + .Lu_account]
    call head
    call auth_label
    mov [rsp + 8], edx          # claude.ai
    mov r12, rax
    mov rdi, rax
    call strlen
    lea rdi, [rip + .Lu_auth]
    mov rsi, r12
    mov rdx, rax
    call pair_s
    cmp dword ptr [rsp + 8], 0
    je 2f
    lea r13, [rip + acct_rows]  # Email, Organization, Plan (claude.ai)
1:  mov rax, [r13]
    test rax, rax
    jz 2f
    mov r14, [rax]              # the kept value
    test r14, r14
    jz 11f
    lea rdi, [rip + fsb]
    call sb_clear
    mov rdi, r14
    cmp qword ptr [r13 + 16], 0
    je 12f
    lea rsi, [rip + fsb]        # the plan: "max" -> "Max", "team_premium" -> "Team Premium" (NOn)
    call plan_name
    jmp 13f
12: lea rdi, [rip + fsb]
    mov rsi, r14
    call sb_push_cstr
13: mov rdi, [r13 + 8]
    mov rsi, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    call pair_s
11: add r13, 24
    jmp 1b
2:  lea rdi, [rip + .Lu_usage]
    call head
    cmp dword ptr [rsp], 0
    je 3f
    lea rdi, [rip + .Lu_failed]
    mov esi, DGF_MUTED
    call text_row
    mov edi, DGK_LINK
    xor esi, esi
    mov edx, CA_RETRY
    lea rcx, [rip + .Lretry]
    call row_c
    jmp 8f
3:  test rbx, rbx
    jnz 4f
    lea rdi, [rip + .Lu_loading]
    mov esi, DGF_MUTED
    call text_row
    jmp 8f
4:  mov qword ptr [rip + meters_n], 0     # the meters kept anew from this answer
    mov rdi, rbx                # bars: rate limits available, a claude.ai sign-in, one of its windows
    lea rsi, [rip + .Lk_rl_avail]
    call json_get
    mov rdi, rax
    call json_bool
    test eax, eax
    jz 5f
    cmp dword ptr [rsp + 8], 0
    je 5f
    mov rdi, rbx
    lea rsi, [rip + .Lk_rate_limits]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne .Lu_retry
    mov rdi, rbx
    mov rsi, r12
    call bars
    test eax, eax
    jnz 8f
    jmp .Lu_retry
5:  mov rdi, rbx                # the session's totals for an API key, a console or another provider
    lea rsi, [rip + .Lk_session]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne 6f
    cmp qword ptr [rip + acct_provider], 0
    je 51f
    mov rdi, [rip + acct_provider]
    lea rsi, [rip + .Lv_first_party]
    call strcmp_eq
    test eax, eax
    jz 52f                      # another provider: the totals
51: cmp dword ptr [rsp + 8], 0
    jne 6f                      # claude.ai without bars: none
    mov rdi, rbx
    lea rsi, [rip + .Lk_behaviors]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    je 6f
    mov rdi, rbx
    lea rsi, [rip + .Lk_sub_type]
    call jget_str
    test rdx, rdx
    jnz 6f
52: mov rdi, r12
    call session_rows
    jmp 8f
6:  lea rdi, [rip + .Lu_no_limits]
    mov esi, DGF_MUTED
    call text_row
8:  cmp dword ptr [rsp + 8], 0  # a claude.ai sign-in: its usage page (asked before it opens)
    je 9f
    mov edi, DGK_LINK
    xor esi, esi
    mov edx, CA_MANAGE
    lea rcx, [rip + .Lu_manage]
    call row_c
9:  EPILOGUE
.Lu_retry:
    lea rdi, [rip + .Lu_failed]
    mov esi, DGF_MUTED
    call text_row
    mov edi, DGK_LINK
    xor esi, esi
    mov edx, CA_RETRY
    lea rcx, [rip + .Lretry]
    call row_c
    jmp 8b

# plan_name(plan cstr, sb): the extension's NOn
plan_name:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor ecx, ecx                # capitals or blanks: as it is
1:  movzx eax, byte ptr [rbx + rcx]
    test eax, eax
    jz 3f
    cmp eax, ' '
    je 2f
    lea edx, [rax - 'A']
    cmp edx, 25
    jbe 2f
    inc rcx
    jmp 1b
2:  mov rdi, r12
    mov rsi, rbx
    call sb_push_cstr
    EPILOGUE
3:  mov r13d, 1                 # words split at "_", each capitalized, the rest lower case
    xor r14d, r14d
4:  movzx eax, byte ptr [rbx + r14]
    test eax, eax
    jz 9f
    inc r14
    cmp eax, '_'
    jne 5f
    mov r13d, 1
    mov esi, ' '
    mov rdi, r12
    call sb_push_byte
    jmp 4b
5:  lea edx, [rax - 'a']
    test r13d, r13d
    jz 6f
    cmp edx, 25
    ja 6f
    sub eax, 32
6:  xor r13d, r13d
    mov esi, eax
    mov rdi, r12
    call sb_push_byte
    jmp 4b
9:  EPILOGUE

# bars(response, rate_limits) -> eax 1 when it drew one at least: Session (5hr), Weekly (7 day), Weekly
#   Sonnet (with a Max or Team plan, or none), and each model-scoped limit as "Weekly NAME" (ROn)
bars:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    xor r15d, r15d
    mov rdi, r12
    lea rsi, [rip + .Lk_five_hour]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lb_session]
    xor edx, edx
    call bar
    add r15d, eax
    mov rdi, r12
    lea rsi, [rip + .Lk_seven_day]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lb_weekly]
    mov edx, 1
    call bar
    add r15d, eax
    mov rdi, rbx                # Weekly Sonnet: max, team, or no plan named
    lea rsi, [rip + .Lk_sub_type]
    call json_get
    mov r13, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 1f
    mov rdi, r13
    lea rsi, [rip + .Lv_max]
    call json_is
    test eax, eax
    jnz 1f
    mov rdi, r13
    lea rsi, [rip + .Lv_team]
    call json_is
    test eax, eax
    jz 2f
1:  mov rdi, r12
    lea rsi, [rip + .Lk_sonnet]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lb_sonnet]
    mov edx, 1
    call bar
    add r15d, eax
2:  mov rdi, r12
    lea rsi, [rip + .Lk_model_scoped]
    call json_get
    mov r13, rax
    xor r14d, r14d
3:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae 8f
    mov rdi, r13
    mov esi, r14d
    call json_at
    inc r14d
    mov [rsp], rax
    lea rdi, [rip + fsb2]
    call sb_clear
    lea rdi, [rip + fsb2]
    lea rsi, [rip + .Lb_weekly_m]
    call sb_push_cstr
    mov rdi, [rsp]
    lea rsi, [rip + .Lk_display_name]
    call jget_str
    lea rdi, [rip + fsb2]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + fsb2]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rsp]
    mov rsi, [rip + fsb2 + SB_ptr]
    mov edx, 1
    call bar
    add r15d, eax
    jmp 3b
8:  mov eax, r15d
    EPILOGUE

# bar(window or 0, label cstr, named day) -> eax 1 when it was drawn: {utilization, resets_at}, utilization
#   not null: "N%" (floor, 0 to 100) and "Resets WHEN" (fmt_reset: claude_reset_text)
bar:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    xor eax, eax
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call json_type
    cmp eax, JT_OBJ
    jne 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_utilization]
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_NUM
    jne 8f
    mov rdi, r14
    call num_int
    test rax, rax
    jns 1f
    xor eax, eax
1:  cmp rax, 100
    jle 2f
    mov eax, 100
2:  mov r15, rax
    mov rdi, r12                # kept for the list's Account & usage (claude_usage_section)
    mov rsi, r15
    call meter_keep
    mov edi, DGK_BAR
    xor esi, esi
    xor edx, edx
    mov rcx, r12
    call row_c
    mov [rsp], rax
    mov [rax + DGR_val], r15
    mov rdi, rbx
    lea rsi, [rip + .Lk_resets_at]
    call jget_str
    test rdx, rdx
    jz 7f
    mov rdi, rax
    mov rsi, rdx
    call agtime_iso
    test rax, rax
    jz 7f
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov rdi, rax
    mov esi, r13d
    call claude_reset_text
    mov r14, rax
    mov r15, rdx
    lea rdi, [rip + fsb2]
    call sb_clear
    lea rdi, [rip + fsb2]
    lea rsi, [rip + .Lb_resets]
    call sb_push_cstr
    lea rdi, [rip + fsb2]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    mov rdi, [rsp]
    mov esi, 2
    mov rdx, [rip + fsb2 + SB_ptr]
    mov rcx, [rip + fsb2 + SB_len]
    call agentdlg_text
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# session_rows(session): the session's totals (jRe): Estimated cost, Total duration (API), Total duration
#   (wall), Total code changes, Usage by model
session_rows:
    PROLOGUE 16
    mov rbx, rdi
    lea rdi, [rip + .Lu_session]
    call head
    lea rdi, [rip + fsb]        # "$0.0045" (4 places up to $0.50, then 2)
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + .Lk_cost]
    call json_get
    mov rdi, rax
    lea rsi, [rip + fsb]
    call put_money
    lea rdi, [rip + .Lu_cost]
    mov rsi, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    call pair_s
    mov rdi, rbx
    lea rsi, [rip + .Lk_api_ms]
    lea rdx, [rip + .Lu_api]
    call duration_row
    mov rdi, rbx
    lea rsi, [rip + .Lk_wall_ms]
    lea rdx, [rip + .Lu_wall]
    call duration_row
    lea rdi, [rip + fsb]        # "N lines added, M lines removed"
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + .Lk_added]
    call jget_num
    mov rsi, rax
    lea rdi, [rip + fsb]
    lea rdx, [rip + .Lu_added]
    call put_lines
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lcomma]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_removed]
    call jget_num
    mov rsi, rax
    lea rdi, [rip + fsb]
    lea rdx, [rip + .Lu_removed]
    call put_lines
    lea rdi, [rip + .Lu_changes]
    mov rsi, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    call pair_s
    lea rdi, [rip + .Lu_by_model]   # each model's tokens and cost
    call head
    mov rdi, rbx
    lea rsi, [rip + .Lk_model_usage]
    call json_get
    mov r12, rax
    xor r13d, r13d
1:  mov rdi, r12
    mov esi, r13d
    call json_pair
    test rax, rax
    jz 8f
    inc r13d
    mov r14, rdx
    mov rdi, rax
    call json_str
    mov [rsp], rax
    mov [rsp + 8], rdx
    lea rdi, [rip + fsb]
    call sb_clear
    lea r15, [rip + model_parts]
2:  mov rsi, [r15]
    test rsi, rsi
    jz 3f
    mov rdi, r14
    call jget_num
    mov rsi, rax
    lea rdi, [rip + fsb]
    mov edx, 1
    call put_tokens
    lea rdi, [rip + fsb]
    mov rsi, [r15 + 8]
    call sb_push_cstr
    add r15, 16
    jmp 2b
3:  lea rdi, [rip + fsb]
    lea rsi, [rip + .Lopen_paren]
    call sb_push_cstr
    mov rdi, r14
    lea rsi, [rip + .Lk_costUSD]
    call json_get
    mov rdi, rax
    lea rsi, [rip + fsb]
    call put_money
    lea rdi, [rip + fsb]
    mov esi, ')'
    call sb_push_byte
    mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov r15, rax
    mov rdi, rax
    xor esi, esi
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    call agentdlg_text
    mov rdi, r15
    mov esi, 1
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    call agentdlg_text
    jmp 1b
8:  test r13d, r13d
    jnz 9f
    lea rdi, [rip + .Lu_none_yet]   # none yet: the zero line (Ppe of NOt)
    mov esi, DGF_MUTED
    call text_row
9:  EPILOGUE

# put_money(jv, sb): the extension's ej: "$" and 2 places above $0.50, else 4
put_money:
    PROLOGUE
    mov rbx, rsi
    mov esi, 4
    call scaled
    mov r12, rax
    mov rdi, rbx
    mov esi, '$'
    call sb_push_byte
    cmp r12, 5000
    jbe 1f
    mov rax, r12                # 2 places
    add rax, 50
    xor edx, edx
    mov ecx, 100
    div rcx
    xor edx, edx
    mov ecx, 100
    div rcx
    mov r13, rdx
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    mov esi, '.'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    mov edx, 2
    call put_padded
    EPILOGUE
1:  mov rax, r12
    xor edx, edx
    mov ecx, 10000
    div rcx
    mov r13, rdx
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    mov esi, '.'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    mov edx, 4
    call put_padded
    EPILOGUE

# put_padded(sb, n, digits): n with leading zeros to that many digits
put_padded:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, 1
1:  dec r13d
    jle 2f
    imul r14, r14, 10
    jmp 1b
2:  cmp r14, 1
    jbe 3f
    cmp r12, r14
    jae 3f
    mov rdi, rbx
    mov esi, '0'
    call sb_push_byte
    mov rax, r14
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r14, rax
    jmp 2b
3:  mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    EPILOGUE

# put_lines(sb, n, word cstr): "1 line WORD" / "N lines WORD"
put_lines:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lline]
    call sb_push_cstr
    cmp r12, 1
    je 1f
    mov rdi, rbx
    mov esi, 's'
    call sb_push_byte
1:  mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    EPILOGUE

# duration_row(session, key cstr, label cstr): the extension's Mpe ("0s", "12s", "3m 4s", "1h 2m 3s",
#   "2d 3h 4m")
duration_row:
    PROLOGUE 16
    mov [rsp], rdx
    call jget_num
    mov rbx, rax
    lea rdi, [rip + fsb]
    call sb_clear
    cmp rbx, 60000
    jae 2f
    mov rax, rbx
    xor edx, edx
    mov ecx, 1000
    div rcx
    lea rdi, [rip + fsb]
    mov rsi, rax
    call sb_push_u64
    lea rdi, [rip + fsb]
    mov esi, 's'
    call sb_push_byte
    jmp 8f
2:  mov rax, rbx                # days, hours, minutes, seconds (rounded, carried)
    xor edx, edx
    mov ecx, 86400000
    div rcx
    mov r12, rax                # d
    mov rax, rdx
    xor edx, edx
    mov ecx, 3600000
    div rcx
    mov r13, rax                # h
    mov rax, rdx
    xor edx, edx
    mov ecx, 60000
    div rcx
    mov r14, rax                # m
    mov rax, rdx
    add rax, 500
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov r15, rax                # s
    cmp r15, 60
    jne 3f
    xor r15d, r15d
    inc r14
3:  cmp r14, 60
    jne 4f
    xor r14d, r14d
    inc r13
4:  cmp r13, 24
    jne 5f
    xor r13d, r13d
    inc r12
5:  test r12, r12
    jz 6f
    mov rsi, r12
    mov edx, 'd'
    call put_unit
    mov rsi, r13
    mov edx, 'h'
    call put_unit_sp
    mov rsi, r14
    mov edx, 'm'
    call put_unit_sp
    jmp 8f
6:  test r13, r13
    jz 7f
    mov rsi, r13
    mov edx, 'h'
    call put_unit
    mov rsi, r14
    mov edx, 'm'
    call put_unit_sp
    mov rsi, r15
    mov edx, 's'
    call put_unit_sp
    jmp 8f
7:  mov rsi, r14
    mov edx, 'm'
    call put_unit
    mov rsi, r15
    mov edx, 's'
    call put_unit_sp
8:  mov rdi, [rsp]
    mov rsi, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    call pair_s
    EPILOGUE

# put_unit_sp(n, unit char) / put_unit(n, unit char): " N" + unit onto fsb
put_unit_sp:
    push rsi
    push rdx
    lea rdi, [rip + fsb]
    mov esi, ' '
    call sb_push_byte
    pop rdx
    pop rsi
put_unit:
    push rbx
    mov ebx, edx
    lea rdi, [rip + fsb]
    call sb_push_u64
    lea rdi, [rip + fsb]
    mov esi, ebx
    call sb_push_byte
    pop rbx
    ret

# meter_keep(label cstr, percent): the meters the list's Account & usage shows (the last get_usage's, the
#   first METERS of them; Session (5hr) and Weekly (7 day) as the extension's)
meter_keep:
    mov rax, [rip + meters_n]
    cmp rax, METERS
    jae 1f
    shl rax, 4
    lea rcx, [rip + meters]
    mov [rcx + rax], rdi        # (a static label, or fsb2's: copied below)
    mov [rcx + rax + 8], rsi
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rax
    mov r12, rcx
    lea rdi, [rip + meter_labels]
    shr rax, 4
    imul rax, rax, METER_LABEL
    add rdi, rax
    mov rsi, [r12 + rbx]
    mov edx, METER_LABEL - 1
    call cstr_ncopy
    mov rax, rbx
    shr rax, 4
    imul rax, rax, METER_LABEL
    lea rdi, [rip + meter_labels]
    add rdi, rax
    mov [r12 + rbx], rdi
    inc qword ptr [rip + meters_n]
    add rsp, 8
    pop r12
    pop rbx
1:  ret

# cstr_ncopy(dst, src cstr, n): at most n bytes and a NUL
cstr_ncopy:
    xor ecx, ecx
1:  cmp ecx, edx
    jae 2f
    mov al, [rsi + rcx]
    test al, al
    jz 2f
    mov [rdi + rcx], al
    inc ecx
    jmp 1b
2:  mov byte ptr [rdi + rcx], 0
    ret

# FN claude_usage_section(x, y, w, sb or 0) -> eax its height: row 5.14's collapsible "Account & usage"
#   for a list of conversations: its header (a click folds or unfolds it, folded at first); unfolded, the
#   email Claude Code reported, a meter per usage limit its last get_usage answer named (Session (5hr),
#   Weekly (7 day), ...), and "View details", which opens Account & usage for the box's conversation. It
#   asks nothing itself (the meters come from the dialog's answers). With an sb it draws nothing and
#   writes its lines ("usage open=0|1", "email E", "meter LABEL N%", "details"). In the panel's faces
#   (agents_metrics first); its ids are ID_AGDLG + 6 and + 7
FN claude_usage_section
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 16], rcx
    mov r15, rcx
    mov rax, [rip + ag_fsmall]
    mov r12d, [rax + FACE_lineh]
    add r12d, [rip + g_pmt + 4*MI_8]    # a row
    xor r13d, r13d              # the height
    test r15, r15
    jz 1f
    mov rdi, r15
    lea rsi, [rip + .Lus_head]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rip + usage_open]
    call sb_push_u64
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    jmp 2f
1:  mov edi, ID_AGDLG + 6       # the header: a click folds or unfolds
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, r12d
    call ui_btn
    test eax, UB_CLICK
    jz 11f
    xor dword ptr [rip + usage_open], 1
    mov dword ptr [rip + g_dirty], 1
11: mov edi, IC_CHEV_R
    cmp dword ptr [rip + usage_open], 0
    je 12f
    mov edi, IC_CHEV_D
12: mov esi, [rsp]
    mov edx, [rsp + 4]
    PM ecx, MI_16
    mov r8d, r12d
    COLOR r9d, T_MUTED
    call ui_icon_center
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_20]
    mov edx, [rsp + 4]
    mov ecx, r12d
    lea r8, [rip + .Lus_title]
    mov r9, 15
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
2:  add r13d, r12d
    cmp dword ptr [rip + usage_open], 0
    je 9f
    mov rbx, [rip + acct_email] # the email
    test rbx, rbx
    jz 3f
    test r15, r15
    jz 21f
    mov rdi, r15
    lea rsi, [rip + .Lus_email]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, rbx
    call sb_push_cstr
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    jmp 22f
21: mov rdi, rbx
    call strlen
    mov r9, rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_20]
    mov edx, [rsp + 4]
    add edx, r13d
    mov ecx, r12d
    mov r8, rbx
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
22: add r13d, r12d
3:  xor r14d, r14d              # the meters
4:  cmp r14, [rip + meters_n]
    jae 6f
    mov rax, r14
    shl rax, 4
    lea rcx, [rip + meters]
    mov rbx, [rcx + rax]
    mov rax, [rcx + rax + 8]
    mov [rsp + 24], rax
    inc r14
    test r15, r15
    jz 41f
    mov rdi, r15
    lea rsi, [rip + .Lus_meter]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, rbx
    call sb_push_cstr
    mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    mov rdi, r15
    mov rsi, [rsp + 24]
    call sb_push_u64
    mov rdi, r15
    mov esi, '%'
    call sb_push_byte
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    add r13d, r12d
    jmp 4b
41: mov rdi, rbx                # LABEL, then its track under it
    call strlen
    mov r9, rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_20]
    mov edx, [rsp + 4]
    add edx, r13d
    mov ecx, r12d
    mov r8, rbx
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    add r13d, r12d
    mov edi, [rsp]
    add edi, [rip + g_pmt + 4*MI_20]
    mov esi, [rsp + 4]
    add esi, r13d
    mov edx, [rsp + 8]
    sub edx, [rip + g_pmt + 4*MI_20]
    sub edx, [rip + g_pmt + 4*MI_8]
    mov [rsp + 28], edx
    PM ecx, MI_4
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_BORDER
    call gfx_round_rect
    mov eax, [rsp + 24]
    imul eax, [rsp + 28]
    xor edx, edx
    mov ecx, 100
    div ecx
    test eax, eax
    jz 42f
    mov edx, eax
    mov edi, [rsp]
    add edi, [rip + g_pmt + 4*MI_20]
    mov esi, [rsp + 4]
    add esi, r13d
    PM ecx, MI_4
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_ACCENT
    call gfx_round_rect
42: add r13d, [rip + g_pmt + 4*MI_8]
    jmp 4b
6:  test r15, r15               # View details
    jz 61f
    mov rdi, r15
    lea rsi, [rip + .Lus_details_line]
    call sb_push_cstr
    jmp 62f
61: mov edi, ID_AGDLG + 7
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_20]
    mov edx, [rsp + 4]
    add edx, r13d
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lus_details]
    call cwidth_s
    mov ecx, eax
    mov edi, ID_AGDLG + 7
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_20]
    mov edx, [rsp + 4]
    add edx, r13d
    mov r8d, r12d
    call ui_btn
    test eax, UB_CLICK
    jz 63f
    lea rdi, [rip + .Lus_url]
    call agentdlg_link
63: mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_20]
    mov edx, [rsp + 4]
    add edx, r13d
    mov ecx, r12d
    lea r8, [rip + .Lus_details]
    mov r9, 12
    COLOR eax, T_ACCENT
    push rax
    push rax
    call ui_text_v
    add rsp, 16
62: add r13d, r12d
9:  mov eax, r13d
    EPILOGUE

# cwidth_s(face, cstr) -> eax its width
cwidth_s:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call text_width
    add rsp, 8
    pop r12
    pop rbx
    ret

# FN claude_dlg_c_usage(out, rest, len) -> rax 0: print-agent-usage [toggle]: the list's Account & usage
#   section's lines (toggle: unfolded or folded first)
FN claude_dlg_c_usage
    PROLOGUE
    mov rbx, rdi
    test rdx, rdx
    jz 1f
    call claude_usage_toggle
1:  xor edi, edi
    xor esi, esi
    mov edx, 300
    mov rcx, rbx
    call claude_usage_section
    xor eax, eax
    EPILOGUE

# FN claude_usage_toggle(): the section folds or unfolds (headless)
FN claude_usage_toggle
    xor dword ptr [rip + usage_open], 1
    mov dword ptr [rip + g_dirty], 1
    ret

# ---- Context usage ----

# build_context(response): finding 62: the model and "N / M tokens (P%)", the used share as a bar, the
#   categories with tokens (not deferred) as a table of Category / Tokens / Usage (Free space without a
#   colour), then the five largest memory files (hint /memory) and custom agents (hint /agents) (BNt, wAn)
build_context:
    PROLOGUE 32
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Lk_categories]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    je 1f
    lea rdi, [rip + .Lc_none]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Lc_none]
    call agentdlg_fail
    EPILOGUE
1:  mov rdi, rbx
    lea rsi, [rip + .Lk_raw_max]
    call jget_num
    mov [rsp], rax              # rawMaxTokens
    call agentdlg_begin
    mov rdi, rbx                # the model at the left, "33.0k / 1.0M tokens (3%)" at the right
    lea rsi, [rip + .Lk_model]
    call jget_str
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov r13, rax
    mov rdi, rax
    xor esi, esi
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    call agentdlg_text
    lea rdi, [rip + fsb]
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + .Lk_total]
    call jget_num
    mov rsi, rax
    lea rdi, [rip + fsb]
    xor edx, edx
    call put_tokens
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lc_slash]
    call sb_push_cstr
    lea rdi, [rip + fsb]
    mov rsi, [rsp]
    xor edx, edx
    call put_tokens
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lc_tokens]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_percentage]
    call jget_num
    mov [rsp + 24], rax
    lea rdi, [rip + fsb]
    mov rsi, rax
    call sb_push_u64
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lc_close]
    call sb_push_cstr
    mov rdi, r13
    mov esi, 2
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    call agentdlg_text
    mov edi, DGK_BAR            # the used share
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call row_c
    mov rcx, [rsp + 24]
    mov [rax + DGR_val], rcx
    mov edi, DGK_COLS           # the table's header
    mov esi, DGF_MUTED
    xor edx, edx
    lea rcx, [rip + .Lc_category]
    call row_c
    mov r13, rax
    mov rdi, rax
    mov esi, 1
    lea rdx, [rip + .Lc_tok]
    call agentdlg_ctext
    mov rdi, r13
    mov esi, 2
    lea rdx, [rip + .Lc_usage]
    call agentdlg_ctext
    xor r14d, r14d              # the categories shown (their colours in order)
    xor r15d, r15d
2:  mov rdi, r12
    call json_len
    cmp r15d, eax
    jae 5f
    mov rdi, r12
    mov esi, r15d
    call json_at
    inc r15d
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_tokens]
    call jget_num
    test rax, rax
    jle 2b
    mov [rsp + 8], rax
    mov rdi, r13
    lea rsi, [rip + .Lk_deferred]
    call json_get
    mov rdi, rax
    call json_bool
    test eax, eax
    jnz 2b
    mov rdi, r13
    lea rsi, [rip + .Lk_name]
    call jget_str
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lc_free]
    call str_eq_cstr
    xor esi, esi
    test eax, eax
    jnz 3f
    mov esi, DGF_SWATCH
3:  mov edi, DGK_COLS
    xor edx, edx
    call agentdlg_row
    mov r13, rax
    test dword ptr [r13 + DGR_flags], DGF_SWATCH
    jz 4f
    mov eax, r14d               # its colour: the chart colours round
    xor edx, edx
    mov ecx, COLORS_N
    div ecx
    lea rax, [rip + chart_slots]
    mov eax, [rax + rdx*4]
    lea rcx, [rip + g_theme]
    mov eax, [rcx + rax*4]
    mov [r13 + DGR_val], rax
4:  inc r14d
    mov rdi, r13
    xor esi, esi
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    call agentdlg_text
    mov rdi, r13
    mov rsi, [rsp + 8]
    mov rdx, [rsp]
    call cols_nums
    jmp 2b
5:  mov rdi, rbx                # the five largest memory files, the five largest agents
    lea rsi, [rip + .Lk_memory_files]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lc_memory]
    lea rdx, [rip + .Lc_memory_hint]
    lea rcx, [rip + .Lk_path]
    call top_rows
    mov rdi, rbx
    lea rsi, [rip + .Lk_agents]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lc_agents]
    lea rdx, [rip + .Lc_agents_hint]
    lea rcx, [rip + .Lk_agent_type]
    call top_rows
    EPILOGUE

# cols_nums(DGR*, tokens, whole): t2 its tokens (ev), t3 its share of the whole (kAn)
cols_nums:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + fsb]
    call sb_clear
    lea rdi, [rip + fsb]
    mov rsi, r12
    xor edx, edx
    call put_tokens
    mov rdi, rbx
    mov esi, 1
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    call agentdlg_text
    test r13, r13
    jz 9f
    lea rdi, [rip + fsb]
    call sb_clear
    lea rdi, [rip + fsb]
    mov rsi, r12
    mov rdx, r13
    call put_pct
    mov rdi, rbx
    mov esi, 2
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    call agentdlg_text
9:  EPILOGUE

# top_rows(array or 0, title cstr, hint cstr, name key cstr): its five largest by tokens under a section
#   title with its hint (a path shown from "~" when it is under a home folder: SAn)
top_rows:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov [rsp + 16], rcx
    mov rdi, rbx
    call json_len
    test eax, eax
    jz 9f
    xor r12d, r12d              # picks: {tokens, index}, the first PICK_MAX
    xor r13d, r13d
1:  mov rdi, rbx
    call json_len
    cmp r13d, eax
    jae 4f
    cmp r12d, PICK_MAX
    jae 4f
    mov rdi, rbx
    mov esi, r13d
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_tokens]
    call jget_num
    lea rcx, [rip + picks]      # insertion, the largest first (a tie keeps the order)
    mov r14d, r12d
2:  test r14d, r14d
    jz 3f
    mov rdx, r14
    dec rdx
    shl rdx, 4
    cmp [rcx + rdx], rax
    jge 3f
    mov r8, [rcx + rdx]
    mov r9, [rcx + rdx + 8]
    mov [rcx + rdx + 16], r8
    mov [rcx + rdx + 24], r9
    dec r14d
    jmp 2b
3:  mov rdx, r14
    shl rdx, 4
    mov [rcx + rdx], rax
    mov [rcx + rdx + 8], r13
    inc r12d
    inc r13d
    jmp 1b
4:  mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    mov rcx, [rsp]
    call row_c
    mov rdi, rax
    mov esi, 2
    mov rdx, [rsp + 8]
    call agentdlg_ctext
    xor r13d, r13d
5:  cmp r13d, r12d
    jae 9f
    cmp r13d, TOP_N
    jae 9f
    lea rcx, [rip + picks]
    mov rdx, r13
    shl rdx, 4
    mov rax, [rcx + rdx]
    mov [rsp + 24], rax
    mov rsi, [rcx + rdx + 8]
    inc r13d
    mov rdi, rbx
    call json_at
    mov rdi, rax
    mov rsi, [rsp + 16]
    call jget_str
    mov rdi, rax
    mov rsi, rdx
    call home_short
    mov r14, rax
    mov r15, rdx
    mov edi, DGK_COLS
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov [rsp + 32], rax
    mov rdi, rax
    xor esi, esi
    mov rdx, r14
    mov rcx, r15
    call agentdlg_text
    mov rdi, [rsp + 32]
    mov rsi, [rsp + 24]
    xor edx, edx
    call cols_nums
    jmp 5b
9:  EPILOGUE

# home_short(ptr, len) -> rax ptr, rdx len: "~/rest" for "/Users/NAME/rest" or "/home/NAME/rest" (in fsb2)
home_short:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rip + .Lh_users]
    mov ecx, 7
    cmp r12, rcx
    jb 8f
    mov rdi, rbx
    mov rsi, rcx
    mov rdx, r13
    call str_eq_cstr
    mov r14d, 7
    test eax, eax
    jnz 1f
    lea r13, [rip + .Lh_home]
    mov rdi, rbx
    mov esi, 6
    mov rdx, r13
    call str_eq_cstr
    mov r14d, 6
    test eax, eax
    jz 8f
1:  mov rcx, r14                # past the user's name
2:  cmp rcx, r12
    jae 8f
    cmp byte ptr [rbx + rcx], '/'
    je 3f
    inc rcx
    jmp 2b
3:  cmp rcx, r14
    je 8f
    mov r15, rcx
    lea rdi, [rip + fsb2]
    call sb_clear
    lea rdi, [rip + fsb2]
    mov esi, '~'
    call sb_push_byte
    lea rdi, [rip + fsb2]
    lea rsi, [rbx + r15]
    mov rdx, r12
    sub rdx, r15
    call sb_push
    mov rax, [rip + fsb2 + SB_ptr]
    mov rdx, [rip + fsb2 + SB_len]
    EPILOGUE
8:  mov rax, rbx
    mov rdx, r12
    EPILOGUE

# ---- Output styles ----

# build_ostyle(response): "Select an output style", a row per style (a check on the one in effect),
#   "No output styles available" for none (zFt); a pick asks update_settings localSettings outputStyle
build_ostyle:
    PROLOGUE 16
    mov rdi, rdi
    lea rsi, [rip + .Lk_available]
    call json_get
    mov rbx, rax
    call agentdlg_begin
    lea rdi, [rip + keep]
    call free_cstrs
    mov rdi, rbx
    call json_len
    test eax, eax
    jnz 1f
    lea rdi, [rip + .Lo_none]
    mov esi, DGF_MUTED
    call text_row
    EPILOGUE
1:  lea rdi, [rip + .Lo_select]
    call head
    mov dword ptr [rsp], -1     # the current one's focus index
    xor r12d, r12d
2:  mov rdi, rbx
    call json_len
    cmp r12d, eax
    jae 8f
    mov rdi, rbx
    mov esi, r12d
    call json_at
    mov rdi, rax
    call json_str
    mov r13, rax
    mov r14, rdx
    lea rdi, [rip + keep]
    mov rsi, r13
    mov rdx, r14
    call keep_add
    mov r15, rax                # its index
    lea rdx, [rip + .Lv_default]    # the one in effect ("default" when none was said)
    mov rax, [rip + cur_style]
    test rax, rax
    cmovnz rdx, rax
    mov rdi, r13
    mov rsi, r14
    call str_eq_cstr
    xor esi, esi
    test eax, eax
    jz 3f
    mov esi, DGF_CHECK
    mov [rsp], r12d
3:  mov edi, DGK_ITEM
    mov edx, CA_STYLE
    call agentdlg_row
    mov [rax + DGR_arg], r15
    mov rdi, rax
    xor esi, esi
    mov rdx, r13
    mov rcx, r14
    call agentdlg_text
    inc r12d
    jmp 2b
8:  mov edi, [rsp]
    call agentdlg_focus
    EPILOGUE

# ---- the slash commands browser ----

# build_skills(response or 0): "Filter commands…", a row per command Claude Code offers ("/name", its
#   description; Enter puts "/name " in the box), each one that is a skill with "SOURCE · ~N tokens" and its
#   state (On, Name only, User only, Off: Space or a click on it cycles it with set_skill_state; locked: "STATE
#   · locked"), then the skills no command names (HBt, nzn); "No slash commands available." for none. A row's
#   arg: the box's text's index in keep, and (skill + 1) << 32
build_skills:
    PROLOGUE 48
    mov rbx, rdi
    call agentdlg_begin
    lea rdi, [rip + .Lk_filter_ph]
    call agentdlg_filter
    call free_keeps
    test rbx, rbx
    jz 1f
    mov rdi, rbx                # the skills kept
    lea rsi, [rip + .Lk_skills]
    call json_get
    mov rbx, rax
    xor r12d, r12d
11: mov rdi, rbx
    call json_len
    cmp r12d, eax
    jae 1f
    mov rdi, rbx
    mov esi, r12d
    call json_at
    inc r12d
    mov rdi, rax
    call skill_keep
    jmp 11b
1:  mov edi, AG_CLAUDE          # the commands Claude Code offers (the menu's Slash Commands)
    call agentcfg_get
    mov r15, rax
    xor r12d, r12d
2:  cmp r12, [r15 + AGC_cmds + VEC_len]
    jae 5f
    mov rax, [r15 + AGC_cmds + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    lea rdi, [rip + fsb]        # "/name " for the box
    call sb_clear
    lea rdi, [rip + fsb]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + fsb]
    mov rsi, [r13 + ACM_name]
    call sb_push_cstr
    lea rdi, [rip + fsb]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + keep]
    mov rsi, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    call keep_add
    mov [rsp], rax
    mov edi, DGK_ITEM
    mov esi, DGF_FILTER
    mov edx, CA_SELECT
    call agentdlg_row
    mov r14, rax
    mov rcx, [rsp]
    mov [r14 + DGR_arg], rcx
    mov rdi, r14                # "/name" (without the blank)
    xor esi, esi
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    dec rcx
    call agentdlg_text
    mov rdx, [r13 + ACM_desc]
    test rdx, rdx
    jz 3f
    mov rdi, r14
    mov esi, 1
    call agentdlg_ctext
3:  mov rdi, r13                # a skill it names: its source, size and state
    call skill_of
    test rax, rax
    js 2b
    mov rdi, r14
    mov rsi, rax
    call skill_parts
    jmp 2b
5:  xor r12d, r12d              # the skills no command named (rows to read, their state to switch)
6:  cmp r12, [rip + skills + VEC_len]
    jae 7f
    imul r13, r12, SK_SIZE
    add r13, [rip + skills + VEC_ptr]
    inc r12
    cmp dword ptr [r13 + SK_matched], 0
    jne 6b
    mov edi, DGK_ITEM
    mov esi, DGF_FILTER
    xor edx, edx
    call agentdlg_row
    mov r14, rax
    lea rdi, [rip + fsb]
    call sb_clear
    lea rdi, [rip + fsb]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + fsb]
    mov rsi, [r13 + SK_name]
    call sb_push_cstr
    mov rdi, r14
    xor esi, esi
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    call agentdlg_text
    lea rsi, [r12 - 1]
    mov rdi, r14
    call skill_parts
    jmp 6b
7:  cmp qword ptr [r15 + AGC_cmds + VEC_len], 0
    jne 8f
    cmp qword ptr [rip + skills + VEC_len], 0
    jne 8f
    lea rdi, [rip + .Lk_no_cmds]
    mov esi, DGF_MUTED
    call text_row
8:  EPILOGUE

# skill_keep(skill object): its name, state, source, tokens, locked_by and handles (as JSON text, written
#   back as they came) kept
skill_keep:
    PROLOGUE
    mov r13, rdi
    lea rdi, [rip + skills]
    mov esi, SK_SIZE
    call vec_push
    mov r14, rax
    lea r12, [rip + skill_strs]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 2f
    mov rdi, r13
    call jget_str
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rcx, [r12 + 8]
    mov [r14 + rcx], rax
    add r12, 16
    jmp 1b
2:  mov rdi, r13
    lea rsi, [rip + .Lk_tokens]
    call jget_num
    mov [r14 + SK_tokens], rax
    mov rdi, r13
    lea rsi, [rip + .Lk_locked_by]
    call jget_str
    xor eax, eax
    test rdx, rdx
    setnz al
    mov [r14 + SK_locked], eax
    mov rdi, r13
    lea rsi, [rip + .Lk_handles]
    call json_get
    mov r15, rax
    lea rdi, [rip + fsb2]
    call sb_clear
    test r15, r15
    jz 3f
    lea rdi, [rip + fsb2]
    call jw_begin
    lea rdi, [rip + fsb2]
    mov rsi, r15
    call jw_jv
3:  cmp qword ptr [rip + fsb2 + SB_len], 0
    jne 4f
    lea rdi, [rip + fsb2]
    lea rsi, [rip + .Lempty_obj]
    call sb_push_cstr
4:  mov rdi, [rip + fsb2 + SB_ptr]
    mov rsi, [rip + fsb2 + SB_len]
    call mem_dup
    mov [r14 + SK_handles], rax
    EPILOGUE

# skill_of(ACM*) -> rax the index of the skill the command names (its name, or one of its aliases), -1 none
#   (the extension's QBn, the first that fits); it is marked matched
skill_of:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + skills + VEC_len]
    jae 8f
    imul r13, r12, SK_SIZE
    add r13, [rip + skills + VEC_ptr]
    mov rdi, [r13 + SK_name]
    mov rsi, [rbx + ACM_name]
    call strcmp_eq
    test eax, eax
    jnz 9f
    mov rdi, [rbx + ACM_aliases]
    test rdi, rdi
    jz 2f
    mov rsi, [r13 + SK_name]
    call word_in
    test eax, eax
    jnz 9f
2:  inc r12
    jmp 1b
8:  mov rax, -1
    EPILOGUE
9:  mov dword ptr [r13 + SK_matched], 1
    mov rax, r12
    EPILOGUE

# word_in(words cstr (blank-separated), word cstr) -> eax 1 when it is one of them
word_in:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call strlen
    mov r13, rax
1:  cmp byte ptr [rbx], 0
    je 8f
    xor ecx, ecx
2:  movzx eax, byte ptr [rbx + rcx]
    test eax, eax
    jz 3f
    cmp eax, ' '
    je 3f
    inc rcx
    jmp 2b
3:  mov r14, rcx
    cmp rcx, r13
    jne 4f
    mov rdi, rbx
    mov rsi, rcx
    mov rdx, r12
    call str_eq_cstr
    test eax, eax
    jnz 9f
4:  add rbx, r14
    cmp byte ptr [rbx], 0
    je 8f
    inc rbx
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# skill_parts(DGR*, skill index): t2 "SOURCE · ~N tokens" (HAe, kUe), t3 its state as a pill (DGF_STATE,
#   act2 CA_STATE), or "STATE · locked" (no pill); its arg gains (skill + 1) << 32
skill_parts:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    imul r13, r12, SK_SIZE
    add r13, [rip + skills + VEC_ptr]
    lea rax, [r12 + 1]
    shl rax, 32
    or [rbx + DGR_arg], rax
    mov dword ptr [rbx + DGR_act2], CA_STATE
    lea rdi, [rip + fsb2]       # "SOURCE · ~N tokens"
    call sb_clear
    mov rsi, [r13 + SK_source]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + fsb2]
    call sb_push_cstr
1:  lea rdi, [rip + fsb2]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    mov rax, [r13 + SK_tokens]
    cmp rax, 20
    jae 2f
    lea rdi, [rip + fsb2]
    lea rsi, [rip + .Lsk_lt20]
    call sb_push_cstr
    jmp 4f
2:  lea rdi, [rip + fsb2]
    mov esi, '~'
    call sb_push_byte
    mov rax, [r13 + SK_tokens]  # round(N / 10) x 10, then sE without ".0"
    add rax, 5
    xor edx, edx
    mov ecx, 10
    div rcx
    imul rax, rax, 10
    cmp rax, 1000
    jae 3f
    lea rdi, [rip + fsb2]
    mov rsi, rax
    call sb_push_u64
    jmp 4f
3:  add rax, 50
    xor edx, edx
    mov ecx, 100
    div rcx                     # tenths of a thousand
    mov r14, rax
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r15, rdx
    lea rdi, [rip + fsb2]
    mov rsi, rax
    call sb_push_u64
    test r15, r15
    jz 31f
    lea rdi, [rip + fsb2]
    mov esi, '.'
    call sb_push_byte
    lea rdi, [rip + fsb2]
    mov rsi, r15
    call sb_push_u64
31: lea rdi, [rip + fsb2]
    lea rsi, [rip + .Lsfx_k]
    call sb_push_cstr
4:  lea rdi, [rip + fsb2]
    lea rsi, [rip + .Lsk_tokens]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 1
    mov rdx, [rip + fsb2 + SB_ptr]
    mov rcx, [rip + fsb2 + SB_len]
    call agentdlg_text
    mov rdi, [r13 + SK_state]   # the state
    call state_label
    lea rdi, [rip + fsb2]
    mov rsi, rax
    push rsi
    push rsi
    call sb_clear
    pop rsi
    pop rsi
    lea rdi, [rip + fsb2]
    call sb_push_cstr
    cmp dword ptr [r13 + SK_locked], 0
    je 5f
    lea rdi, [rip + fsb2]
    lea rsi, [rip + .Lsk_locked]
    call sb_push_cstr
    jmp 6f
5:  or dword ptr [rbx + DGR_flags], DGF_STATE
6:  mov rdi, rbx
    mov esi, 2
    mov rdx, [rip + fsb2 + SB_ptr]
    mov rcx, [rip + fsb2 + SB_len]
    call agentdlg_text
    EPILOGUE

# state_label(state cstr) -> rax On, Name only, User only, Off (DU); anything else as it came
state_label:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rip + state_map]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jnz 2f
    add r12, 24
    jmp 1b
2:  mov rax, [r12 + 8]
    EPILOGUE
8:  mov rax, rbx
    EPILOGUE

# next_state(state cstr) -> rax the next one round (FBt: on, name-only, user-invocable-only, off)
next_state:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rip + state_map]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jnz 2f
    add r12, 24
    jmp 1b
2:  mov rax, [r12 + 16]
    EPILOGUE
8:  lea rax, [rip + .Lst_on]
    EPILOGUE

# ---- Memory and Instructions ----

# build_memory(dialog): finding 65's shape, checked as the extension checks it; Memory: the auto-memory
#   switches (Auto-dream only when shown), the memories with their type and age, the folders; Instructions:
#   the CLAUDE.md files with where they are (_Pt, yPt)
build_memory:
    PROLOGUE 32
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Lk_files]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne .Lm_bad
    mov rdi, rbx
    lea rsi, [rip + .Lk_folders]
    call json_get
    mov r13, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne .Lm_bad
    mov rdi, rbx
    lea rsi, [rip + .Lk_auto_memory]
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne .Lm_bad
    mov rdi, rbx
    lea rsi, [rip + .Lk_auto_dream]
    call json_get
    mov r15, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne .Lm_bad
    call agentdlg_begin
    call free_keeps
    cmp qword ptr [rip + cd_kind], K_INSTRUCT
    je .Lm_files
    mov rdi, r14                # Auto-memory
    lea rsi, [rip + .Lm_auto_memory]
    xor edx, edx
    call mem_toggle
    mov [rip + mem_on], eax
    mov dword ptr [rsp], 1      # switches shown
    mov rdi, r15
    lea rsi, [rip + .Lk_shown]
    call json_get
    mov rdi, rax
    call json_bool
    test eax, eax
    jz 1f
    mov rdi, r15
    lea rsi, [rip + .Lm_auto_dream]
    mov edx, 1
    call mem_toggle
    mov [rip + dream_on], eax
    inc dword ptr [rsp]
1:  mov rdi, rbx                # the memories
    lea rsi, [rip + .Lk_memories]
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne 4f
    xor r15d, r15d
2:  mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 3f
    mov rdi, r14
    mov esi, r15d
    call json_at
    inc r15d
    mov rdi, rax
    call memory_row
    jmp 2b
3:  test r15d, r15d
    jnz 4f
    lea rdi, [rip + .Lm_none]
    mov esi, DGF_MUTED
    call text_row
4:  xor r15d, r15d              # the folders
5:  mov rdi, r13
    call json_len
    cmp r15d, eax
    jae 6f
    mov rdi, r13
    mov esi, r15d
    call json_at
    inc r15d
    mov rdi, rax
    mov esi, CA_FOLDER
    call path_row
    jmp 5b
6:  lea rdi, [rip + .Lm_keys]
    mov esi, DGF_MUTED | DGF_SMALL
    call text_row
    mov edi, [rsp]              # the focus on the first memory (after the switches)
    call agentdlg_focus
    EPILOGUE
.Lm_files:
    xor r15d, r15d
7:  mov rdi, r12
    call json_len
    cmp r15d, eax
    jae 8f
    mov rdi, r12
    mov esi, r15d
    call json_at
    inc r15d
    mov rdi, rax
    mov esi, CA_OPEN
    call path_row
    jmp 7b
8:  lea rdi, [rip + .Lm_keys]
    mov esi, DGF_MUTED | DGF_SMALL
    call text_row
    xor edi, edi
    call agentdlg_focus
    EPILOGUE
.Lm_bad:
    lea rdi, [rip + .Lm_bad_shape]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Lm_bad_shape]
    call agentdlg_fail
    EPILOGUE

# mem_toggle(obj, label cstr, which) -> eax on: a switch row; one that cannot be switched is greyed with its
#   status; Auto-dream's detail under it
mem_toggle:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov rdi, rbx
    lea rsi, [rip + .Lk_enabled]
    call json_get
    mov rdi, rax
    call json_bool
    mov r13d, eax
    mov rdi, rbx
    lea rsi, [rip + .Lk_toggleable]
    call json_get
    mov rdi, rax
    call json_bool
    mov r14d, eax
    xor esi, esi
    test r13d, r13d
    jz 1f
    mov esi, DGF_ON
1:  test r14d, r14d
    jnz 2f
    or esi, DGF_OFF
2:  mov edi, DGK_TOGGLE
    mov edx, CA_TOGGLE
    mov rcx, r12
    call row_c
    mov r15, rax
    mov ecx, [rsp]
    mov [r15 + DGR_arg], rcx
    lea rsi, [rip + .Lk_status]
    test r14d, r14d
    jz 3f
    lea rsi, [rip + .Lk_detail]
3:  mov rdi, rbx
    call jget_str
    test rdx, rdx
    jz 9f
    mov rdi, r15
    mov esi, 1
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
9:  mov eax, r13d
    EPILOGUE

# memory_row(memory): its name, "TYPE · AGE" under it (wRe), Enter opens its file
memory_row:
    PROLOGUE 16
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Lk_path]
    call jget_str
    lea rdi, [rip + keep]
    mov rsi, rax
    call keep_add
    mov r12, rax
    mov edi, DGK_ITEM
    xor esi, esi
    mov edx, CA_OPEN
    xor ecx, ecx
    call row_c
    mov r13, rax
    mov [r13 + DGR_arg], r12
    mov rdi, rbx
    lea rsi, [rip + .Lk_name]
    call jget_str
    mov rdi, r13
    xor esi, esi
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    lea rdi, [rip + fsb]
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call jget_str
    test rdx, rdx
    jz 1f
    lea rdi, [rip + fsb]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
1:  mov rdi, rbx
    lea rsi, [rip + .Lk_modified]
    call jget_num
    mov rdi, rax
    call put_age
    mov rdi, r13
    mov esi, 1
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    call agentdlg_text
    EPILOGUE

# put_age(ms): fsb gains the extension's wRe: today, yesterday, N days ago (to 13), N weeks ago (to 59
#   days), N months ago, 1 year ago, N years ago
put_age:
    PROLOGUE
    mov rbx, rdi
    call time_now
    imul rax, rax, 1000
    sub rax, rbx
    jns 1f
    xor eax, eax
1:  xor edx, edx
    mov ecx, 86400000
    div rcx
    mov r12, rax                # days
    lea rsi, [rip + .Lg_today]
    test r12, r12
    jz 8f
    lea rsi, [rip + .Lg_yesterday]
    cmp r12, 1
    je 8f
    lea r13, [rip + .Lg_days]
    mov rax, r12
    cmp r12, 14
    jb 5f
    lea r13, [rip + .Lg_weeks]
    xor edx, edx
    mov ecx, 7
    div rcx
    cmp r12, 60
    jb 5f
    lea r13, [rip + .Lg_months]
    mov rax, r12
    xor edx, edx
    mov ecx, 30
    div rcx
    cmp r12, 365
    jb 5f
    mov rax, r12
    xor edx, edx
    mov ecx, 365
    div rcx
    lea rsi, [rip + .Lg_year]
    cmp rax, 1
    je 8f
    lea r13, [rip + .Lg_years]
5:  lea rdi, [rip + fsb]
    mov rsi, rax
    call sb_push_u64
    lea rdi, [rip + fsb]
    mov rsi, r13
    call sb_push_cstr
    EPILOGUE
8:  lea rdi, [rip + fsb]
    call sb_push_cstr
    EPILOGUE

# path_row(file or folder, act): its label, under it its description (a file's kind: "Alternate project
#   file", "Local, not checked in", else its description: ZMn), Enter opens it
path_row:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov rdi, rbx
    lea rsi, [rip + .Lk_path]
    call jget_str
    lea rdi, [rip + keep]
    mov rsi, rax
    call keep_add
    mov r12, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_label]
    call jget_str
    mov r14, rax
    mov r15, rdx
    lea rdi, [rip + labels]     # its label, for the toast (an index the same as keep's)
    mov rsi, r14
    mov rdx, r15
    call keep_add_at
    mov edi, DGK_ITEM
    xor esi, esi
    mov edx, [rsp]
    xor ecx, ecx
    call row_c
    mov r13, rax
    mov [r13 + DGR_arg], r12
    mov rdi, r13
    xor esi, esi
    mov rdx, r14
    mov rcx, r15
    call agentdlg_text
    mov rdi, rbx
    lea rsi, [rip + .Lk_kind]
    call jget_str
    lea rcx, [rip + .Lf_alt]
    mov r14, rax
    mov r15, rdx
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lv_project_alt]
    call str_eq_cstr
    lea rdx, [rip + .Lf_alt]
    test eax, eax
    jnz 2f
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lv_kind_local]
    call str_eq_cstr
    lea rdx, [rip + .Lf_local]
    test eax, eax
    jnz 2f
    mov rdi, rbx
    lea rsi, [rip + .Lk_description]
    call jget_str
    test rdx, rdx
    jz 9f
    mov rdi, r13
    mov esi, 1
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    EPILOGUE
2:  mov rdi, r13
    mov esi, 1
    call agentdlg_ctext
9:  EPILOGUE

# keep_add_at(VEC*, ptr, len): an owned copy at the index keep's last entry has (labels follow keep)
keep_add_at:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
1:  mov rax, [rbx + VEC_len]    # (empty entries up to keep's)
    inc rax
    cmp rax, [rip + keep + VEC_len]
    jae 2f
    mov rdi, rbx
    mov esi, 8
    call vec_push
    mov qword ptr [rax], 0
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call keep_add
    EPILOGUE

.section .rodata
.p2align 3
cd_ops: .quad cd_act, cd_free
kinds:                          # name, title, loading, request, start, failure's start
    .quad .Ln_status, .Lt_status, .Ll_status, .Lr_status, 1, .Lf_status
    .quad .Ln_usage, .Lt_usage, .Ll_usage, .Lr_usage, 1, .Lf_usage
    .quad .Ln_context, .Lt_context, .Ll_context, .Lr_context, 1, .Lf_context
    .quad .Ln_ostyle, .Lt_ostyle, .Ll_ostyle, .Lr_ostyle, 1, .Lf_ostyle
    .quad .Ln_skills, .Lt_skills, .Ll_skills, .Lr_skills, 0, .Lf_skills
    .quad .Ln_memory, .Lt_memory, .Ll_memory, .Lr_memory, 1, .Lf_memory
    .quad .Ln_instruct, .Lt_instruct, .Ll_memory, .Lr_memory, 1, .Lf_memory
acct_keys:                      # initialize's account: its key, the slot it is kept in
    .quad .Lk_email, acct_email, .Lk_organization, acct_org, .Lk_subscription, acct_plan
    .quad .Lk_api_provider, acct_provider, .Lk_api_key_source, acct_keysrc, 0, 0
acct_rows:                      # the slot, its label, 1: a plan's name
    .quad acct_email, .Lu_email, 0, acct_org, .Lu_org, 0, acct_plan, .Lu_plan, 1, 0, 0, 0
label_map:
    .quad .Lsl_cwd, .Lsl_folder, .Lsl_peer, .Lsl_messaging, .Lsl_kind, .Lsl_type, 0, 0
provider_map:
    .quad .Lv_bedrock, .La_bedrock, .Lv_vertex, .La_vertex, .Lv_foundry, .La_foundry
    .quad .Lv_gateway, .La_gateway, 0, 0
model_parts:                    # Ppe: each count's key and what follows it
    .quad .Lk_in_tok, .Lmp_in, .Lk_out_tok, .Lmp_out, .Lk_cache_read, .Lmp_read
    .quad .Lk_cache_write, .Lmp_write, 0, 0
skill_strs:                     # a skill's strings kept: its key, the field
    .quad .Lk_name, SK_name, .Lk_state, SK_state, .Lk_source, SK_source, 0, 0
state_map:                      # a state, its label, the next one (DU, FBt)
    .quad .Lst_on, .Lsl_on, .Lst_name_only
    .quad .Lst_name_only, .Lsl_name_only, .Lst_user_only
    .quad .Lst_user_only, .Lsl_user_only, .Lst_off
    .quad .Lst_off, .Lsl_off, .Lst_on
    .quad 0, 0, 0
chart_slots: .long T_ACCENT, T_SUCCESS, T_WARNING, T_ERROR, T_INFO, T_ICON + 4, T_ICON + 5, T_ICON + 7
.Ln_status: .asciz "status"
.Ln_usage: .asciz "usage"
.Ln_context: .asciz "context"
.Ln_ostyle: .asciz "output-style"
.Ln_skills: .asciz "skills"
.Ln_memory: .asciz "memory"
.Ln_instruct: .asciz "instructions"
.Lt_status: .asciz "Status"
.Lt_usage: .asciz "Account & Usage"
.Lt_context: .asciz "Context usage"
.Lt_ostyle: .asciz "Output styles"
.Lt_skills: .asciz "Slash commands"
.Lt_memory: .asciz "Memory"
.Lt_instruct: .asciz "Instructions"
.Ll_status: .asciz "Loading status\342\200\246"
.Ll_usage: .asciz "Loading usage data\342\200\246"
.Ll_context: .asciz "Loading context usage\342\200\246"
.Ll_ostyle: .asciz "Loading output styles\342\200\246"
.Ll_skills: .asciz ""
.Ll_memory: .asciz "Loading\342\200\246"
.Lr_status: .asciz "get_status"
.Lr_usage: .asciz "get_usage"
.Lr_context: .asciz "get_context_usage"
.Lr_ostyle: .asciz "reload_output_styles"
.Lr_skills: .asciz "get_skills_dialog"
.Lr_memory: .asciz "get_memory_dialog"
.Lf_status: .asciz "Could not load status: "
.Lf_usage: .asciz "Failed to load usage data: "
.Lf_context: .asciz "Failed to load context usage: "
.Lf_ostyle: .asciz "Couldn't load the output styles: "
.Lf_skills: .asciz ""
.Lf_memory: .asciz ""
.Lno_start: .asciz "Claude Code could not start."
.Lnot_sent: .asciz "Claude Code is not taking requests now."
.Lretry: .asciz "Retry"
.Lwho: .asciz "Claude Code"
.Ls_none: .asciz "No status was returned"
.Lc_none: .asciz "Failed to load context usage: no categories were returned"
.Lsl_cwd: .asciz "cwd"
.Lsl_folder: .asciz "Working folder"
.Lsl_peer: .asciz "Peer address"
.Lsl_messaging: .asciz "Messaging address"
.Lsl_kind: .asciz "Session kind"
.Lsl_type: .asciz "Session type"
.Lu_account: .asciz "Account"
.Lu_auth: .asciz "Auth method"
.Lu_email: .asciz "Email"
.Lu_org: .asciz "Organization"
.Lu_plan: .asciz "Plan"
.Lu_usage: .asciz "Usage"
.Lu_loading: .asciz "Loading usage data\342\200\246"
.Lu_failed: .asciz "Failed to load usage data"
.Lu_no_limits: .asciz "Plan limits aren't available for this login method."
.Lu_manage: .asciz "Manage usage on claude.ai"
.Lu_settings: .asciz "https://claude.ai/settings/usage"
.Lu_admin: .asciz "https://claude.ai/admin-settings/usage"
.Lu_session: .asciz "Session"
.Lu_cost: .asciz "Estimated cost"
.Lu_api: .asciz "Total duration (API)"
.Lu_wall: .asciz "Total duration (wall)"
.Lu_changes: .asciz "Total code changes"
.Lu_added: .asciz " added"
.Lu_removed: .asciz " removed"
.Lu_by_model: .asciz "Usage by model"
.Lu_none_yet: .asciz "0 input, 0 output, 0 cache read, 0 cache write"
.Lb_session: .asciz "Session (5hr)"
.Lb_weekly: .asciz "Weekly (7 day)"
.Lb_sonnet: .asciz "Weekly Sonnet"
.Lb_weekly_m: .asciz "Weekly "
.Lb_resets: .asciz "Resets "
.La_claude: .asciz "Claude AI"
.La_console: .asciz "Anthropic Console"
.La_key: .asciz "API Key"
.La_third: .asciz "Third Party"
.La_none: .asciz "Not authenticated"
.La_bedrock: .asciz "Amazon Bedrock"
.La_vertex: .asciz "Google Vertex AI"
.La_foundry: .asciz "Microsoft Foundry"
.La_gateway: .asciz "Cloud gateway"
.Lv_bedrock: .asciz "bedrock"
.Lv_vertex: .asciz "vertex"
.Lv_foundry: .asciz "foundry"
.Lv_gateway: .asciz "gateway"
.Lv_first_party: .asciz "firstParty"
.Lv_max: .asciz "max"
.Lv_team: .asciz "team"
.Lv_enterprise: .asciz "enterprise"
.Lv_default: .asciz "default"
.Lv_success: .asciz "success"
.Lv_update_settings: .asciz "update_settings"
.Lv_set_skill: .asciz "set_skill_state"
.Lv_set_memory: .asciz "set_memory_setting"
.Lv_local: .asciz "localSettings"
.Lv_auto_memory: .asciz "autoMemoryEnabled"
.Lv_auto_dream: .asciz "autoDreamEnabled"
.Lv_project_alt: .asciz "project-alt"
.Lv_kind_local: .asciz "local"
.Lc_slash: .asciz " / "
.Lc_tokens: .asciz " tokens ("
.Lc_close: .asciz "%)"
.Lc_category: .asciz "Category"
.Lc_tok: .asciz "Tokens"
.Lc_usage: .asciz "Usage"
.Lc_free: .asciz "Free space"
.Lc_memory: .asciz "Memory files"
.Lc_memory_hint: .asciz "/memory"
.Lc_agents: .asciz "Custom agents"
.Lc_agents_hint: .asciz "/agents"
.Lo_select: .asciz "Select an output style"
.Lo_none: .asciz "No output styles available"
.Lk_filter_ph: .asciz "Filter commands\342\200\246"
.Lk_no_cmds: .asciz "No slash commands available."
.Lsk_locked: .asciz " \302\267 locked"
.Lsk_lt20: .asciz "< 20"
.Lsk_tokens: .asciz " tokens"
.Lk_locked_by: .asciz "locked_by"
.Lst_on: .asciz "on"
.Lst_name_only: .asciz "name-only"
.Lst_user_only: .asciz "user-invocable-only"
.Lst_off: .asciz "off"
.Lsl_on: .asciz "On"
.Lsl_name_only: .asciz "Name only"
.Lsl_user_only: .asciz "User only"
.Lsl_off: .asciz "Off"
.Lm_auto_memory: .asciz "Auto-memory"
.Lm_auto_dream: .asciz "Auto-dream"
.Lm_none: .asciz "No memories saved for this project yet."
.Lm_keys: .asciz "\342\206\221 \342\206\223 to navigate \302\267 Enter to select \302\267 Esc to close"
.Lm_bad_shape: .asciz "The memory dialog reply was not in the expected shape"
.Lf_alt: .asciz "Alternate project file"
.Lf_local: .asciz "Local, not checked in"
.Li_reads: .asciz "Claude reads "
.Li_reload: .asciz " when a session starts. After editing, reload to apply changes to the current session."
.Lg_today: .asciz "today"
.Lg_yesterday: .asciz "yesterday"
.Lg_days: .asciz " days ago"
.Lg_weeks: .asciz " weeks ago"
.Lg_months: .asciz " months ago"
.Lg_year: .asciz "1 year ago"
.Lg_years: .asciz " years ago"
.Ldot: .asciz " \302\267 "
.Lline: .asciz " line"
.Lcomma: .asciz ", "
.Lopen_paren: .asciz " ("
.Lmp_in: .asciz " input, "
.Lmp_out: .asciz " output, "
.Lmp_read: .asciz " cache read, "
.Lmp_write: .asciz " cache write"
.Lsfx_k: .asciz "k"
.Lsfx_M: .asciz "M"
.Lsfx_m: .asciz "m"
.Lsfx_pct: .asciz "%"
.Lpct_small: .asciz "<0.1%"
.Lempty_obj: .asciz "{}"
.Lh_users: .asciz "/Users/"
.Lh_home: .asciz "/home/"
.Lk_account: .asciz "account"
.Lk_output_style: .asciz "output_style"
.Lk_email: .asciz "email"
.Lk_organization: .asciz "organization"
.Lk_subscription: .asciz "subscriptionType"
.Lk_api_provider: .asciz "apiProvider"
.Lk_api_key_source: .asciz "apiKeySource"
.Lk_subtype: .asciz "subtype"
.Lk_response: .asciz "response"
.Lk_error: .asciz "error"
.Lk_dialog: .asciz "dialog"
.Lk_sections: .asciz "sections"
.Lk_title: .asciz "title"
.Lk_rows: .asciz "rows"
.Lk_label: .asciz "label"
.Lk_value: .asciz "value"
.Lk_rl_avail: .asciz "rate_limits_available"
.Lk_rate_limits: .asciz "rate_limits"
.Lk_session: .asciz "session"
.Lk_behaviors: .asciz "behaviors"
.Lk_sub_type: .asciz "subscription_type"
.Lk_five_hour: .asciz "five_hour"
.Lk_seven_day: .asciz "seven_day"
.Lk_sonnet: .asciz "seven_day_sonnet"
.Lk_model_scoped: .asciz "model_scoped"
.Lk_display_name: .asciz "display_name"
.Lk_utilization: .asciz "utilization"
.Lk_resets_at: .asciz "resets_at"
.Lk_cost: .asciz "total_cost_usd"
.Lk_api_ms: .asciz "total_api_duration_ms"
.Lk_wall_ms: .asciz "total_duration_ms"
.Lk_added: .asciz "total_lines_added"
.Lk_removed: .asciz "total_lines_removed"
.Lk_model_usage: .asciz "model_usage"
.Lk_costUSD: .asciz "costUSD"
.Lk_in_tok: .asciz "inputTokens"
.Lk_out_tok: .asciz "outputTokens"
.Lk_cache_read: .asciz "cacheReadInputTokens"
.Lk_cache_write: .asciz "cacheCreationInputTokens"
.Lk_categories: .asciz "categories"
.Lk_raw_max: .asciz "rawMaxTokens"
.Lk_model: .asciz "model"
.Lk_total: .asciz "totalTokens"
.Lk_percentage: .asciz "percentage"
.Lk_tokens: .asciz "tokens"
.Lk_deferred: .asciz "isDeferred"
.Lk_name: .asciz "name"
.Lk_memory_files: .asciz "memoryFiles"
.Lk_agents: .asciz "agents"
.Lk_path: .asciz "path"
.Lk_agent_type: .asciz "agentType"
.Lk_available: .asciz "available_output_styles"
.Lk_skills: .asciz "skills"
.Lk_state: .asciz "state"
.Lk_handles: .asciz "handles"
.Lk_files: .asciz "files"
.Lk_folders: .asciz "folders"
.Lk_auto_memory: .asciz "auto_memory"
.Lk_auto_dream: .asciz "auto_dream"
.Lk_shown: .asciz "shown"
.Lk_memories: .asciz "memories"
.Lk_enabled: .asciz "enabled"
.Lk_toggleable: .asciz "toggleable"
.Lk_status: .asciz "status"
.Lk_detail: .asciz "detail"
.Lk_type: .asciz "type"
.Lk_modified: .asciz "modified_ms"
.Lk_kind: .asciz "kind"
.Lk_description: .asciz "description"
.Lk_source: .asciz "source"
.Lk_settings: .asciz "settings"
.Lk_outputStyle: .asciz "outputStyle"
.Lk_setting: .asciz "setting"
.Lus_title: .asciz "Account & usage"
.globl claude_dlg_n_usage
claude_dlg_n_usage: .asciz "print-agent-usage"
.Lus_details: .asciz "View details"
.Lus_url: .asciz "dialog:usage"
.Lus_head: .asciz "usage open="
.Lus_email: .asciz "email "
.Lus_meter: .asciz "meter "
.Lus_details_line: .asciz "details\n"
