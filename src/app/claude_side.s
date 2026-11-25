# Claude Code's part of phase 7 part 3 (claude-chat-p7c): the side question's request, the Claude in Chrome
# dialog, Remote Control, and the hand-off to the terminal. The panels themselves are generic (agentside.s,
# agentmap.s); what is Claude's goes through DRV_action (claude_action passes every act from ACT_BTW here)
# and the control requests' answers come back through h_response (claude_side_answer, acts from
# OA_SIDE_FIRST) and h_system (claude_side_system).
#
# The side question: control_request side_question {question, history?} (2.1.330, finding 100: history is
#   an array of {question, response} strings; the answer {response, synthetic}; an error answer's text is
#   shown after "Failed to get an answer: "). Read-only; recorded against the real CLI.
# Claude in Chrome (6.18): get_chrome_dialog (finding 101: {allowed, subscriber, wsl, installed, connected,
#   enabled_by_default, at_startup, urls {install, reconnect, permissions}}) as a dialog: the extension's
#   state, its links (asked before they open), and "Enabled by default" shown, not changed (changing it
#   writes Claude Code's user settings; rhun leaves that to Claude Code). The browser chooser is left out:
#   get_chrome_browsers answers "Claude in Chrome is not connected in this session" while nothing is
#   connected, and a connected answer was never seen.
# Remote Control (2.22, 4.14, /remote-control, /rc, the menu's /remote-control): remote_control {enabled} on the
#   running program, then its system/bridge_state frames {state, detail, failure_kind?} (from the CLI binary's
#   own schema; never recorded: enabling it publishes the session to the account's claude.ai/code, so it was not
#   tried). The state is the live record's (ev_remote: AL_rc, so it ends with the program and its record): the
#   footer's pill shows it (connecting, active with its link, error) as the extension's CFt does. Nothing is
#   shown as connected unless the program says so. The offer card (send_to_project_remote_control_offer,
#   claude_cards.s) asks claude_side_rc_offer to turn it on and is answered when the bridge settles
#   (claude_rc_settled).
# Remote Control for all sessions (row 1.24's Settings switch, the extension's remote-control-at-startup, which
#   2.1.330's update_settings refuses: "update_settings keys not allowed: remoteControlAtStartup"): as the
#   extension's host does, the switch writes remoteControlAtStartup into Claude Code's user settings file
#   (<claude dir>/settings.json: read, that one key set, written back with two blanks a level, as its s3 does),
#   then asks each running program apply_flag_settings {remoteControlAtStartup} and get_settings, and turns
#   that program's Remote Control on or off as the setting now says (the extension's uqe: a project or local
#   false wins, then the policy's, then the user's, then the value written). A program that starts turns it
#   on when initialize says remote_control_auto_enable (and remote_control_auto_on_by_default false, or
#   ide_rc_auto_enable_gate: the extension's cqe) and remote_control_available is not false. The switch shows
#   get_settings' effective value, else initialize's remote_control_auto_enable; it is hidden while
#   initialize said remote_control_available false (and no lock), and in a remote window. A lock
#   (get_settings' remote_control_policy_lock_reason) lets it only be turned off.
# The hand-off (4.22, 7.4): a command that only works in Claude Code's own terminal interface (/agents) gives
#   the card "Continue in Terminal to configure agents?" (1 Continue in Terminal, 2 Never mind); Continue
#   puts `claude /agents` in rhun's terminal prompt (DRV_terminal with claude_term_extra) and the card
#   becomes "Terminal opened" (1 Refresh and continue: the program ends, the next message resumes the
#   conversation with what changed; 2 Continue without refreshing).
#
#   claude_side_action(AL* or 0, act, ptr, len) -> eax   DRV_action's acts from ACT_BTW
#   claude_side_answer(AL*, control_response record, act, n)   h_response
#   claude_side_system(AL*, record)                             h_system
#   claude_side_rc_offer(AL*) -> rax cstr or 0                  the offer card's "Turn on Remote Control"
#   claude_rca_shows(AS* or 0, kind) -> eax shown, ecx APRF_ON   the switch's row (claude_session.s's menu)
#   claude_rca_read(get_settings' response object)              its value and lock, from every answer
#   claude_rca_init(AL*, initialize's response object)          Remote Control at the start
#   claude_term_extra: cstr or 0, a word cl_terminal adds after the program (taken once)
.include "rhun.inc"

.equ HO_ASK, 0                  # the hand-off card's steps
.equ HO_OPENED, 1

.bss
.p2align 3
.globl claude_term_extra
claude_term_extra: .quad 0
hist: .zero SB_SIZE
csb: .zero SB_SIZE
side_ptr: .quad 0
side_len: .quad 0
side_al: .quad 0
ho_step: .long 0
rc_want: .long 0
rpath: .zero SB_SIZE            # Remote Control for all sessions: the settings file's path,
rsb: .zero SB_SIZE              #   the file as written back (compact, then with blanks)
rsb2: .zero SB_SIZE
rmsg: .zero SB_SIZE             #   the toast's words
.p2align 3
rca_lock: .quad 0               # owned cstr: get_settings' remote_control_policy_lock_reason, or 0
.data
.p2align 2
rca_val: .long -1               # get_settings' effective remoteControlAtStartup (or as written last), -1 unknown
rca_def: .long 0                # initialize's remote_control_auto_enable (the extension's AutoEnableDefault)
rca_avail: .long 1              # initialize's remote_control_available was not false
rca_pend: .long 0               # the value the switch wrote last: the verdict's last word
.bss

.text

# FN claude_side_action(AL* or 0, act, ptr, len) -> eax: ACT_SIDEQ -> its request + 1 (0 not written);
#   ACT_REMOTE, ACT_CHROME, ACT_HANDOFF, ACT_HANDANS -> 1 done
FN claude_side_action
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, ACT_RCALL         # Remote Control for all sessions: with or without a conversation
    je .Lsa_rcall
    xor eax, eax
    test rbx, rbx
    jz 9f
    cmp r12d, ACT_SIDEQ
    je .Lsa_side
    cmp r12d, ACT_CHROME
    je .Lsa_chrome
    cmp r12d, ACT_REMOTE
    je .Lsa_remote
    cmp r12d, ACT_RC
    je .Lsa_remote
    cmp r12d, ACT_HANDOFF
    je .Lsa_handoff
    cmp r12d, ACT_HANDANS
    je .Lsa_handans
9:  EPILOGUE
.Lsa_side:
    mov rdi, rbx                # the history first: the writer below is the only message being built
    call agside_history
    lea rdi, [rip + hist]
    mov r15, rax
    mov [rip + side_al], rdx    # (its length, for a moment)
    call sb_clear
    test r15, r15
    jz 1f
    lea rdi, [rip + hist]
    mov rsi, r15
    mov rdx, [rip + side_al]
    call sb_push
1:  mov [rip + side_ptr], r13
    mov [rip + side_len], r14
    mov rdi, rbx
    mov esi, OA_SIDE_Q
    lea rdx, [rip + .Lv_side]
    lea rcx, [rip + fill_side]
    call claude_side_req
    test eax, eax
    jz 9b
    lea eax, [rdx + 1]
    EPILOGUE
.Lsa_chrome:
    mov rdi, [rbx + AL_as]
    lea rsi, [rip + .Ln_chrome]
    lea rdx, [rip + .Lt_chrome]
    lea rcx, [rip + chrome_ops]
    call agentdlg_open
    mov rdi, rbx
    call chrome_ask
    mov eax, 1
    EPILOGUE
.Lsa_remote:
    mov rdi, rbx
    call rc_toggle
    mov eax, 1
    EPILOGUE
.Lsa_rcall:
    mov rdi, r13
    mov rsi, r14
    call rca_flip
    mov eax, 1
    EPILOGUE
.Lsa_handoff:
    mov dword ptr [rip + ho_step], HO_ASK
    lea rdi, [rip + .Lh_ask]
    call strlen
    mov rcx, rax
    mov rdi, rbx
    mov esi, AQK_HANDOFF
    lea rdx, [rip + .Lh_ask]
    lea r8, [rip + ho_opts_ask]
    mov r9d, 2
    call agent_own_card
    mov eax, 1
    EPILOGUE
.Lsa_handans:                   # (r13: the option picked; the card is gone)
    cmp dword ptr [rip + ho_step], HO_OPENED
    je 3f
    test r13, r13
    jnz 2f
    lea rax, [rip + .Lv_agents_cmd]
    mov [rip + claude_term_extra], rax
    mov rdi, rbx
    xor esi, esi
    mov rax, [rbx + AL_drv]
    call [rax + DRV_terminal]
    mov qword ptr [rip + claude_term_extra], 0
    mov dword ptr [rip + ho_step], HO_OPENED
    lea rdi, [rip + .Lh_opened]
    call strlen
    mov rcx, rax
    mov rdi, rbx
    mov esi, AQK_HANDOFF
    lea rdx, [rip + .Lh_opened]
    lea r8, [rip + ho_opts_opened]
    mov r9d, 2
    call agent_own_card
2:  mov eax, 1
    EPILOGUE
3:  mov dword ptr [rip + ho_step], HO_ASK
    test r13, r13
    jnz 2b
    mov rdi, [rbx + AL_as]      # Refresh and continue: the program ends; the next message resumes
    call agent_release
    jmp 2b

# fill_side(cw, 0): side_question's members
fill_side:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_question]
    call jw_key
    mov rdi, rbx
    mov rsi, [rip + side_ptr]
    mov rdx, [rip + side_len]
    call jw_str
    cmp qword ptr [rip + hist + SB_len], 0
    je 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_history]
    call jw_key
    mov rdi, rbx
    mov rsi, [rip + hist + SB_ptr]
    mov rdx, [rip + hist + SB_len]
    call jw_rawn
9:  EPILOGUE

# ---- Claude in Chrome ----

# chrome_ask(AL*): get_chrome_dialog now (its program up) or once it is ready (agentdlg_pend)
chrome_ask:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + .Ll_loading]
    call agentdlg_loading
    cmp dword ptr [rbx + AL_cn + CN_state], CN_UP
    jne 1f
    mov eax, [rbx + AL_state]
    cmp eax, ALS_STARTING
    je 1f
    cmp eax, ALS_HELD
    je 1f
    mov rdi, rbx
    call chrome_send
    EPILOGUE
1:  mov rdi, rbx
    call agentdlg_pend
    mov rdi, [rbx + AL_as]
    call agent_run
    EPILOGUE

# chrome_send(AL*): get_chrome_dialog, the dialog waiting for its answer
chrome_send:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    mov esi, OA_SIDE_CHROME
    lea rdx, [rip + .Lv_chrome]
    xor ecx, ecx
    call claude_side_req
    test eax, eax
    jz 2f
    mov rdi, rbx
    mov esi, edx
    call agentdlg_wait
    EPILOGUE
2:  lea rdi, [rip + .Le_unsent]
    call strlen
    lea rdi, [rip + .Le_unsent]
    mov rsi, rax
    call agentdlg_fail
    EPILOGUE

# chrome_act(act, arg, DGR*): DGO_act: DA_ASK (the program is ready), the links (DGR_arg: the URL)
chrome_act:
    PROLOGUE
    cmp edi, DA_ASK
    jne 1f
    call agentdlg_as
    test rax, rax
    jz 9f
    mov rdi, [rax + AS_live]
    test rdi, rdi
    jz 9f
    call chrome_send            # (ready: its state is not READY yet while ev_ready runs)
    EPILOGUE
1:  test rsi, rsi
    jz 9f
    mov rbx, rsi
    lea rdi, [rip + .Lwho]
    mov rsi, rbx
    call links_ask_open
9:  EPILOGUE

chrome_free:
    ret

# chrome_fill(response object): the dialog's rows from get_chrome_dialog's answer
chrome_fill:
    PROLOGUE
    mov rbx, rdi
    call agentdlg_begin
    mov rdi, rbx
    lea rsi, [rip + .Lk_allowed]
    call json_get
    mov rdi, rax
    call json_bool
    test edx, edx
    jz 1f
    test eax, eax
    jnz 1f
    lea rdx, [rip + .Lc_not_allowed]
    mov edi, DGF_MUTED
    call text_row
1:  lea rsi, [rip + .Lk_installed]   # the extension
    lea rdx, [rip + .Lc_installed]
    lea rcx, [rip + .Lc_not_detected]
    lea r8, [rip + .Lc_extension]
    call pair_bool
    lea rsi, [rip + .Lk_connected]
    lea rdx, [rip + .Lc_connected]
    lea rcx, [rip + .Lc_not_connected]
    lea r8, [rip + .Lc_connection]
    call pair_bool
    mov rdi, rbx                # Enabled by default (shown; Claude Code's settings change it)
    lea rsi, [rip + .Lk_default]
    call json_get
    mov rdi, rax
    call json_bool
    mov r12d, DGF_OFF
    test eax, eax
    jz 2f
    or r12d, DGF_ON
2:  mov edi, DGK_TOGGLE
    mov esi, r12d
    xor edx, edx
    call agentdlg_row
    mov r13, rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lc_default]
    call agentdlg_ctext
    mov rdi, r13
    mov esi, 1
    lea rdx, [rip + .Lc_default_d]
    call agentdlg_ctext
    mov rdi, rbx                # the links
    lea rsi, [rip + .Lk_urls]
    call json_get
    mov r14, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_installed]
    call json_get
    mov rdi, rax
    call json_bool
    test eax, eax
    jnz 3f
    lea rsi, [rip + .Lk_install]
    lea rdx, [rip + .Lc_install]
    call link_row
3:  lea rsi, [rip + .Lk_permissions]
    lea rdx, [rip + .Lc_permissions]
    call link_row
    lea rsi, [rip + .Lk_reconnect]
    lea rdx, [rip + .Lc_reconnect]
    call link_row
    EPILOGUE

# text_row(flags edi, cstr rdx)
text_row:
    PROLOGUE
    mov rbx, rdx
    mov esi, edi
    mov edi, DGK_TEXT
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, rbx
    call agentdlg_ctext
    EPILOGUE

# pair_bool(key rsi, yes cstr rdx, no cstr rcx, label r8) in chrome_fill (rbx the answer): a PAIR row
pair_bool:
    PROLOGUE
    mov r12, rdx
    mov r13, rcx
    mov r14, r8
    mov rdi, rbx
    call json_get
    mov rdi, rax
    call json_bool
    mov r15, r13
    test eax, eax
    jz 1f
    mov r15, r12
1:  mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov r12, rax
    mov rdi, rax
    xor esi, esi
    mov rdx, r14
    call agentdlg_ctext
    mov rdi, r12
    mov esi, 1
    mov rdx, r15
    call agentdlg_ctext
    EPILOGUE

# link_row(key rsi, label rdx) in chrome_fill (r14 the urls object): a LINK row whose arg is its URL (kept
#   in csb's arena of URLs: the rows outlive the answer's parse)
link_row:
    PROLOGUE
    mov r12, rdx
    mov rdi, r14
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call url_keep
    mov r13, rax
    mov edi, DGK_LINK
    xor esi, esi
    mov edx, 1
    call agentdlg_row
    mov [rax + DGR_arg], r13
    mov rdi, rax
    xor esi, esi
    mov rdx, r12
    call agentdlg_ctext
9:  EPILOGUE

# url_keep(ptr, len) -> rax a cstr that lives on (the three URLs of the last answer: their slots reused)
url_keep:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [rip + url_n]
    inc dword ptr [rip + url_n]
    xor edx, edx
    mov ecx, 3
    div ecx
    lea r13, [rip + urls]
    lea r13, [r13 + rdx*8]
    mov rdi, [r13]
    call mem_free
    mov rdi, rbx
    mov rsi, r12
    call mem_dup
    mov [r13], rax
    EPILOGUE

# ---- Remote Control ----

# rc_toggle(AL*): /remote-control, /rc: on (remote_control {enabled: true}) while it is off, else off (enabled:
#   false: an error shown is dismissed so, as the extension's dismissRemoteControlError toggles)
rc_toggle:
    xor esi, esi
    cmp dword ptr [rdi + AL_rc], RCS_OFF
    jne rc_set
    mov esi, 1

# rc_set(AL*, want) -> eax 1 asked: remote_control {enabled: want} on the running program; asked on: the pill
#   says it connects. No program: the note says so (0)
rc_set:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp dword ptr [rbx + AL_cn + CN_state], CN_UP
    jne 7f
    cmp dword ptr [rbx + AL_state], ALS_STARTING
    jne rc_ask
    jmp 7f

# rc_req(AL*, want) -> eax 1 asked: rc_set's request on a program that is up, starting or not (the setting's)
rc_req:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
rc_ask:
    mov [rip + rc_want], r12d
    mov rdi, rbx
    mov esi, OA_SIDE_REMOTE
    test r12d, r12d
    jnz 2f
    mov esi, OA_SIDE_REMOTE_OFF
2:  lea rdx, [rip + .Lv_remote]
    lea rcx, [rip + fill_remote]
    call claude_side_req
    test eax, eax
    jz 9f
    mov r13d, 1
    test r12d, r12d
    jz 8f
    mov rdi, rbx
    mov esi, RCS_CONNECTING
    lea rdx, [rip + .Lr_connecting]
    xor ecx, ecx
    xor r8d, r8d
    call ev_remote
8:  mov eax, r13d
    EPILOGUE
9:  xor eax, eax
    EPILOGUE
7:  mov rdi, rbx                # no program: nothing to connect
    mov esi, R_INFO
    lea rdx, [rip + .Lr_noproc]
    call note
    xor eax, eax
    EPILOGUE

fill_remote:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_enabled]
    call jw_key
    mov rdi, rbx
    mov esi, [rip + rc_want]
    call jw_bool
    EPILOGUE

# note(AL*, role, cstr): ev_note with a cstr
note:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov rcx, rax
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r13
    call ev_note
    EPILOGUE

# rc_error(AL*, ptr, len): the pill's "Remote Control error: TEXT · Run /remote-control to dismiss"; an offer card
#   waiting for it is answered "failed"
rc_error:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + csb]
    call sb_clear
    lea rdi, [rip + csb]
    lea rsi, [rip + .Lr_error]
    call sb_push_cstr
    lea rdi, [rip + csb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + csb]
    lea rsi, [rip + .Lr_dismiss]
    call sb_push_cstr
    lea rdi, [rip + csb]
    xor esi, esi
    call sb_push_byte
    mov rdi, rbx
    mov esi, RCS_ERROR
    mov rdx, [rip + csb + SB_ptr]
    xor ecx, ecx
    xor r8d, r8d
    call ev_remote
    mov rdi, rbx
    lea rsi, [rip + .Lo_failed]
    call claude_rc_settled
    EPILOGUE

# rc_on(AL*): the bridge is up: the pill links to claude.ai/code; an offer card waiting is answered "turned_on"
rc_on:
    PROLOGUE
    mov rbx, rdi
    mov esi, RCS_ON
    lea rdx, [rip + .Lr_active]
    lea rcx, [rip + .Lr_url]
    xor r8d, r8d
    call ev_remote
    mov rdi, rbx
    lea rsi, [rip + .Lo_turned_on]
    call claude_rc_settled
    EPILOGUE

# FN claude_side_rc_offer(AL*) -> rax the offer card's answer now ("already_on", "failed"), or 0 when it waits
#   for the bridge (claude_rc_settled answers it): "Turn on Remote Control" (the extension's turnRemoteControlOn)
FN claude_side_rc_offer
    PROLOGUE
    mov rbx, rdi
    lea rax, [rip + .Lo_already_on]
    cmp dword ptr [rbx + AL_rc], RCS_ON
    je 9f
    xor eax, eax
    cmp dword ptr [rbx + AL_rc], RCS_CONNECTING
    je 9f
    mov rdi, rbx
    mov esi, 1
    call rc_set
    test eax, eax
    lea rax, [rip + .Lo_failed]
    jz 9f
    xor eax, eax
9:  EPILOGUE

# ---- Remote Control for all sessions ----

# rca_on() -> eax 1 while the switch shows on: locked, only a value of true; else the value Claude Code
#   reported (or rhun wrote) last, else initialize's remote_control_auto_enable (the extension's ht)
rca_on:
    mov eax, [rip + rca_val]
    cmp qword ptr [rip + rca_lock], 0
    jne 1f
    test eax, eax
    jns 9f
    mov eax, [rip + rca_def]
    ret
1:  cmp eax, 1
    sete al
    movzx eax, al
9:  ret

# FN claude_rca_shows(AS* or 0, kind) -> eax 1 shown, ecx APRF_ON while on; rdx, r8, r9 0: not in a remote
#   window (its settings file is the host's), not while initialize said remote_control_available false
#   unless a lock is in place (the extension's rule)
FN claude_rca_shows
    xor eax, eax
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    cmp dword ptr [rip + g_remote], 0
    jne 9f
    cmp qword ptr [rip + rca_lock], 0
    jne 1f
    cmp dword ptr [rip + rca_avail], 0
    je 9f
1:  call rca_on
    xor ecx, ecx
    test eax, eax
    jz 2f
    mov ecx, APRF_ON
2:  mov eax, 1
    xor edx, edx
9:  ret

# FN claude_rca_read(get_settings' response object): effective.remoteControlAtStartup (a boolean, else
#   unknown) and remote_control_policy_lock_reason (copied); a change redraws the menu's row
FN claude_rca_read
    PROLOGUE
    mov rbx, rdi
    mov r12d, [rip + rca_val]
    mov r13, [rip + rca_lock]
    mov rdi, rbx
    call json_type
    cmp eax, JT_OBJ
    jne 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_effective]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_rca]
    call json_get
    mov rdi, rax
    call json_bool
    test edx, edx
    jnz 1f
    mov eax, -1
1:  mov [rip + rca_val], eax
    cmp eax, r12d
    je 2f
    inc qword ptr [rip + g_agentcfg_gen]
    mov dword ptr [rip + g_dirty], 1
2:  mov rdi, rbx
    lea rsi, [rip + .Lk_lock]
    call json_get
    mov rdi, rax
    call json_str
    mov r14, rax
    mov r15, rdx
    test r13, r13               # the same text: kept
    jz 3f
    test rdx, rdx
    jz 4f
    mov rdi, r13
    call strlen
    cmp rax, r15
    jne 4f
    mov rdi, r13
    mov rsi, r14
    mov rdx, r15
    call memeq
    test eax, eax
    jnz 9f
4:  mov rdi, r13
    call mem_free
    mov qword ptr [rip + rca_lock], 0
    inc qword ptr [rip + g_agentcfg_gen]
    mov dword ptr [rip + g_dirty], 1
3:  test r15, r15
    jz 9f
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov [rip + rca_lock], rax
    inc qword ptr [rip + g_agentcfg_gen]
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN claude_rca_init(AL*, initialize's response object): remote_control_available and _auto_enable kept for the
#   switch; when the program says Remote Control starts on its own (remote_control_auto_enable true, and
#   remote_control_auto_on_by_default false or ide_rc_auto_enable_gate true: the extension's cqe), it is
#   available and it is off here, it is asked on (remote_control {enabled: true})
FN claude_rca_init
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call json_type
    cmp eax, JT_OBJ
    jne 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_rc_avail]
    call json_get
    mov rdi, rax
    call json_bool
    mov r13d, 1                 # available unless it says false
    test edx, edx
    jz 1f
    mov r13d, eax
1:  mov rdi, r12
    lea rsi, [rip + .Lk_rc_auto]
    call json_get
    mov rdi, rax
    call json_bool
    and eax, edx
    mov r14d, eax               # auto_enable true
    mov eax, [rip + rca_avail]
    cmp eax, r13d
    jne 2f
    mov eax, [rip + rca_def]
    cmp eax, r14d
    je 3f
2:  mov [rip + rca_avail], r13d
    mov [rip + rca_def], r14d
    inc qword ptr [rip + g_agentcfg_gen]
    mov dword ptr [rip + g_dirty], 1
3:  test r14d, r14d
    jz 9f
    test r13d, r13d
    jz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_rc_bydefault]
    call json_get
    mov rdi, rax
    call json_bool
    test edx, edx               # on_by_default === false
    jz 4f
    test eax, eax
    jz 5f
4:  mov rdi, r12
    lea rsi, [rip + .Lk_rc_gate]
    call json_get
    mov rdi, rax
    call json_bool
    and eax, edx                # gate === true
    jz 9f
5:  cmp dword ptr [rbx + AL_rc], RCS_OFF
    jne 9f
    cmp dword ptr [rbx + AL_cn + CN_state], CN_UP
    jne 9f
    mov rdi, rbx
    mov esi, 1
    call rc_req
9:  EPILOGUE

# rca_verdict(get_settings' response object) -> eax 1 when this program's Remote Control should be on now (the
#   extension's uqe): a project's or local settings' false, else the policy's value, else the user's, else
#   the value the switch wrote
rca_verdict:
    PROLOGUE 16
    lea rsi, [rip + .Lk_sources]
    call json_get
    mov rbx, rax
    xor r12d, r12d              # the item
    mov r13d, -1                # the policy's
    mov r14d, -1                # the user's
    mov dword ptr [rsp], 0      # a project's or local false
1:  mov rdi, rbx
    mov esi, r12d
    call json_at
    test rax, rax
    jz 5f
    mov r15, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_settings]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_rca]
    call json_get
    mov rdi, rax
    call json_bool
    test edx, edx
    jz 4f
    mov [rsp + 4], eax
    mov rdi, r15
    lea rsi, [rip + .Lk_source]
    call json_get
    mov [rsp + 8], rax
    mov rdi, rax
    lea rsi, [rip + .Ls_policy]
    call json_is
    test eax, eax
    jz 2f
    mov r13d, [rsp + 4]
    jmp 4f
2:  mov rdi, [rsp + 8]
    lea rsi, [rip + .Ls_user]
    call json_is
    test eax, eax
    jz 3f
    mov r14d, [rsp + 4]
    jmp 4f
3:  cmp dword ptr [rsp + 4], 0  # true there counts for nothing (the CLI ignores it); false: off
    jne 4f
    mov rdi, [rsp + 8]
    lea rsi, [rip + .Ls_project]
    call json_is
    test eax, eax
    jnz 31f
    mov rdi, [rsp + 8]
    lea rsi, [rip + .Ls_local]
    call json_is
    test eax, eax
    jz 4f
31: mov dword ptr [rsp], 1
4:  inc r12d
    jmp 1b
5:  xor eax, eax
    cmp dword ptr [rsp], 0
    jne 9f
    mov eax, r13d
    test eax, eax
    jns 9f
    mov eax, r14d
    test eax, eax
    jns 9f
    mov eax, [rip + rca_pend]
9:  EPILOGUE

# rca_follow(AL*, on): its Remote Control as the setting says: on while it is off or failed (and available),
#   off while it is not off (the extension's applyRemoteControlAtStartupToChannels)
rca_follow:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov eax, [rbx + AL_rc]
    test r12d, r12d
    jz 2f
    cmp dword ptr [rip + rca_avail], 0
    je 9f
    cmp eax, RCS_OFF
    je 1f
    cmp eax, RCS_ERROR
    jne 9f
1:  mov rdi, rbx
    mov esi, 1
    call rc_req
    EPILOGUE
2:  cmp eax, RCS_OFF
    je 9f
    mov rdi, rbx
    xor esi, esi
    call rc_req
9:  EPILOGUE

# rca_flip(arg ptr, len): the switch: "on", "off", else the state it shows flipped. Locked: only off (turning it
#   off says it stays off). The user settings file gets the value (rca_write); a failure is a toast,
#   "Failed to update "Enable Remote Control for all sessions": WHY" (the extension's). Then every running
#   program of Claude Code is told (apply_flag_settings) and asked get_settings: its answer turns its Remote
#   Control on or off (rca_follow)
rca_flip:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    cmp dword ptr [rip + g_remote], 0
    jne 9f
    call rca_on
    mov r14d, eax               # shown now
    xor ebx, ebx
    test eax, eax
    sete bl                     # flipped
    cmp r13, 2
    jne 1f
    cmp word ptr [r12], 0x6e6f  # "on"
    jne 2f
    mov ebx, 1
    jmp 2f
1:  cmp r13, 3
    jne 2f
    cmp word ptr [r12], 0x666f  # "of(f)"
    jne 2f
    cmp byte ptr [r12 + 2], 'f'
    jne 2f
    xor ebx, ebx
2:  mov r15, [rip + rca_lock]
    test r15, r15
    jz 3f
    test ebx, ebx
    jz 3f
    mov rdi, r15                # locked: never on
    call rca_fail
    jmp 9f
3:  mov edi, ebx
    call rca_write
    test rax, rax
    jz 4f
    mov rdi, rax
    call rca_fail
    jmp 9f
4:  mov [rip + rca_val], ebx
    mov [rip + rca_pend], ebx
    inc qword ptr [rip + g_agentcfg_gen]
    mov dword ptr [rip + g_dirty], 1
    test r15, r15
    jz 5f
    lea rdi, [rip + .Lrc_revoked]   # turned off under a lock
    call app_toast
5:  mov edi, AG_CLAUDE
    call agent_drv_for_kind
    mov r14, rax
    test rax, rax
    jz 9f
    xor r12d, r12d
6:  mov edi, r12d
    call agent_live_at
    test rax, rax
    jz 9f
    mov r13, rax
    inc r12d
    cmp [r13 + AL_drv], r14
    jne 6b
    cmp dword ptr [r13 + AL_cn + CN_state], CN_UP
    jne 6b
    cmp dword ptr [r13 + AL_state], ALS_STARTING
    je 6b
    mov rdi, r13
    mov esi, OA_SIDE_RCFLAG
    lea rdx, [rip + .Lv_apply_flags]
    lea rcx, [rip + fill_rca]
    call claude_side_req
    cmp dword ptr [r13 + AL_cn + CN_state], CN_UP
    jne 6b
    mov rdi, r13
    mov esi, OA_SIDE_RCGET
    lea rdx, [rip + .Lv_get_settings]
    xor ecx, ecx
    call claude_side_req
    jmp 6b
9:  EPILOGUE

fill_rca:                       # "settings": {"remoteControlAtStartup": B}
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_settings]
    call jw_key
    mov rdi, rbx
    call jw_obj
    mov rdi, rbx
    lea rsi, [rip + .Lk_rca]
    call jw_key
    mov rdi, rbx
    mov esi, [rip + rca_pend]
    call jw_bool
    mov rdi, rbx
    call jw_end_obj
    EPILOGUE

# rca_fail(why cstr): the toast "Failed to update "Enable Remote Control for all sessions": WHY"
rca_fail:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + rmsg]
    call sb_clear
    lea rdi, [rip + rmsg]
    lea rsi, [rip + .Lrc_failed]
    call sb_push_cstr
    lea rdi, [rip + rmsg]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + rmsg]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + rmsg + SB_ptr]
    call app_toast
    EPILOGUE

# rca_write(on) -> rax 0 written, else why not (cstr, in rsb2 or static): <claude dir>/settings.json read
#   (missing: {}), remoteControlAtStartup set in its place (else added last), every other member written back
#   as it was, the whole with two blanks a level and a newline (the extension's JSON.stringify(l, null, 2)),
#   through a sibling file (file_write_all). Not JSON, not an object: the extension's words
rca_write:
    PROLOGUE 16
    mov [rsp], edi
    lea rdi, [rip + rpath]
    call sb_clear
    lea rdi, [rip + rpath]
    call claude_dir
    lea rbx, [rip + .Lrc_nodir]
    test eax, eax
    jz .Lrw_ret
    lea rdi, [rip + rpath]
    lea rsi, [rip + .Lrc_file]
    call sb_push_cstr
    lea rdi, [rip + rpath]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + rpath + SB_ptr]
    call file_read_all
    mov r12, rax                # the text (mem_free it), or 0
    mov r13, rdx
    test rax, rax
    jnz 1f
    cmp rdx, -2                 # ENOENT: none yet
    je 1f
    lea rsi, [rip + .Lrc_unread]
    jmp .Lrw_why
1:  lea rdi, [rip + rsb]
    call jw_begin
    lea rdi, [rip + rsb]
    call jw_obj
    xor r15d, r15d              # the key was there
    test r12, r12
    jz 5f
    mov rdi, r12
    mov rsi, r13
    call json_parse
    mov r14, rax
    lea rsi, [rip + .Lrc_notjson]
    test rax, rax
    jz .Lrw_free
    mov rdi, rax
    call json_type
    lea rsi, [rip + .Lrc_notobj]
    cmp eax, JT_OBJ
    jne .Lrw_free
    xor ebx, ebx
2:  mov rdi, r14
    mov esi, ebx
    call json_pair
    test rax, rax
    jz 5f
    mov [rsp + 8], rdx
    mov rdi, rax
    call json_str
    mov rcx, rdx
    mov rdx, rax
    lea rdi, [rip + rsb]
    mov rsi, rdx
    mov rdx, rcx
    mov [rsp + 4], ecx          # (its length, for the comparison below)
    call jw_keyn
    mov rdi, r14                # this pair's key once more: ours?
    mov esi, ebx
    call json_pair
    mov rdi, rax
    lea rsi, [rip + .Lk_rca]
    call json_is
    test eax, eax
    jz 3f
    mov r15d, 1
    lea rdi, [rip + rsb]
    mov esi, [rsp]
    call jw_bool
    jmp 4f
3:  lea rdi, [rip + rsb]
    mov rsi, [rsp + 8]
    call jw_jv
    lea rsi, [rip + .Lrc_deep]
    test eax, eax
    jz .Lrw_free
4:  inc ebx
    jmp 2b
5:  test r15d, r15d
    jnz 6f
    lea rdi, [rip + rsb]
    lea rsi, [rip + .Lk_rca]
    call jw_key
    lea rdi, [rip + rsb]
    mov esi, [rsp]
    call jw_bool
6:  lea rdi, [rip + rsb]
    call jw_end_obj
    test r12, r12               # (its numbers were its text's: written now)
    jz 7f
    mov rdi, r12
    call mem_free
7:  mov rdi, [rip + rsb + SB_ptr]
    mov rsi, [rip + rsb + SB_len]
    call json_parse
    mov rbx, rax
    lea rdi, [rip + rsb2]
    call sb_clear
    lea rdi, [rip + rsb2]
    mov rsi, rbx
    call json_pretty
    lea rdi, [rip + rsb2]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + rpath + SB_ptr]
    call mkdir_parent
    mov rdi, [rip + rpath + SB_ptr]
    mov rsi, [rip + rsb2 + SB_ptr]
    mov rdx, [rip + rsb2 + SB_len]
    call file_write_all
    xor ebx, ebx
    test rax, rax
    jz .Lrw_ret
    lea rsi, [rip + .Lrc_unsaved]
    jmp .Lrw_why
.Lrw_free:
    mov rbx, rsi
    mov rdi, r12
    call mem_free
    mov rsi, rbx
.Lrw_why:                       # rsi: the words before the path
    lea rdi, [rip + rsb2]
    mov rbx, rsi
    call sb_clear
    lea rdi, [rip + rsb2]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + rsb2]
    mov rsi, [rip + rpath + SB_ptr]
    call sb_push_cstr
    lea rdi, [rip + rsb2]
    xor esi, esi
    call sb_push_byte
    mov rbx, [rip + rsb2 + SB_ptr]
.Lrw_ret:
    mov rax, rbx
    EPILOGUE

# ---- answers ----

# FN claude_side_answer(AL*, control_response record, act, n): an answer to one of this file's requests
FN claude_side_answer
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov rdi, r12
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_success]
    call json_is
    mov r15d, eax               # 1 success
    cmp r13d, OA_SIDE_Q
    je .Lan_side
    cmp r13d, OA_SIDE_CHROME
    je .Lan_chrome
    cmp r13d, OA_SIDE_REMOTE
    je .Lan_remote
    cmp r13d, OA_SIDE_REMOTE_OFF
    je .Lan_remote_off
    cmp r13d, OA_SIDE_RCGET
    je .Lan_rcget
    EPILOGUE                    # (OA_SIDE_RCFLAG: nothing; get_settings follows it)
.Lan_rcget:
    test r15d, r15d
    jz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_response]
    call json_get
    mov r13, rax
    mov rdi, rax
    call claude_rca_read
    mov rdi, r13
    call rca_verdict
    mov esi, eax
    mov rdi, rbx
    call rca_follow
9:  EPILOGUE
.Lan_side:
    test r15d, r15d
    jnz 1f
    call err_text
    mov rcx, rdx
    mov rdx, rax
    mov rdi, rbx
    mov esi, r14d
    mov r8d, 1                  # SA_ERROR
    call ev_side_answer
    EPILOGUE
1:  mov rdi, r12
    lea rsi, [rip + .Lk_response]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_response]
    call json_get
    mov rdi, rax
    call json_str
    mov rcx, rdx
    mov rdx, rax
    mov rdi, rbx
    mov esi, r14d
    xor r8d, r8d                # SA_ANSWER (an empty one: SA_EMPTY)
    test rcx, rcx
    jnz 2f
    mov r8d, 2
2:  call ev_side_answer
    EPILOGUE
.Lan_chrome:
    mov rdi, rbx
    mov rsi, r14
    call agentdlg_waits
    test eax, eax
    jz 9f
    test r15d, r15d
    jnz 3f
    call err_text
    mov rdi, rax
    mov rsi, rdx
    call agentdlg_fail
    EPILOGUE
3:  mov rdi, r12
    lea rsi, [rip + .Lk_response]
    call json_get
    mov rdi, rax
    call chrome_fill
9:  EPILOGUE
.Lan_remote:
    test r15d, r15d
    jnz 9b                      # on: bridge_state says when it is up
    call err_text
    mov rdi, rbx
    mov rsi, rax
    call rc_error
    EPILOGUE
.Lan_remote_off:
    test r15d, r15d
    jz 4f
    mov rdi, rbx                # off: no pill; an offer card still waiting is answered "declined"
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call ev_remote
    mov rdi, rbx
    lea rsi, [rip + .Lo_declined]
    call claude_rc_settled
    EPILOGUE
4:  call err_text
    mov rdi, rbx
    mov rsi, rax
    call rc_error
    EPILOGUE

# err_text() -> rax ptr, rdx len: the error answer's text (r12: the record), or a word when it has none
err_text:
    PROLOGUE
    mov rdi, r12
    lea rsi, [rip + .Lk_error]
    call json_get
    test rax, rax
    jnz 1f
    mov rdi, r12
    lea rsi, [rip + .Lk_response]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_error]
    call json_get
1:  mov rdi, rax
    call json_str
    test rdx, rdx
    jnz 9f
    lea rax, [rip + .Le_unknown]
    mov edx, 13
9:  EPILOGUE

# FN claude_side_system(AL*, record): system/bridge_state: Remote Control's state on its pill
FN claude_side_system
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_bridge]
    call json_is
    test eax, eax
    jz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_state]
    call json_get
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lv_connected]
    call json_is
    test eax, eax
    jnz 1f
    mov rdi, r13
    lea rsi, [rip + .Lv_ready]
    call json_is
    test eax, eax
    jnz 1f
    mov rdi, r13
    lea rsi, [rip + .Lv_failed]
    call json_is
    test eax, eax
    jnz 2f
    mov rdi, r13
    lea rsi, [rip + .Lv_policy]
    call json_is
    test eax, eax
    jnz 2f
    jmp 9f
1:  mov rdi, rbx
    call rc_on
    jmp 9f
2:  mov rdi, r12
    lea rsi, [rip + .Lk_detail]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jnz 3f
    mov rdi, r13
    call json_str
3:  mov rdi, rbx
    mov rsi, rax
    call rc_error
9:  EPILOGUE

# FN claude_side_dump(sb): print-agent-remote: "remote=off|connecting|on|error" for the open conversation's
#   program, then, while its footer pill was drawn last, " pill=X,Y" (its centre) and "\ttip=TOOLTIP"
FN claude_side_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_remote]
    call sb_push_cstr
    xor r12d, r12d              # no live record: no pill (a stale one of a frame before is not read)
    call agents_open_driven
    xor ecx, ecx
    test rax, rax
    jz 1f
    mov r12, [rax + AS_live]
    test r12, r12
    jz 1f
    mov ecx, [r12 + AL_rc]
    cmp ecx, RCS_ERROR
    jbe 1f
    xor ecx, ecx
1:  lea rax, [rip + rc_words]
    mov rsi, [rax + rcx*8]
    mov rdi, rbx
    call sb_push_cstr
    test r12, r12
    jz 2f
    call foot_rc_at
    test eax, eax
    jz 2f
    mov r13d, edx
    mov r14d, eax
    mov rdi, rbx
    lea rsi, [rip + .Ld_pill]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r14d
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    mov rsi, [r12 + AL_rctip]
    test rsi, rsi
    jz 2f
    mov rdi, rbx
    lea rsi, [rip + .Ld_tip]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r12 + AL_rctip]
    call sb_push_cstr
2:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# FN claude_side_c_print(out, rest, len): print-agent-remote
FN claude_side_c_print
    PROLOGUE
    call claude_side_dump
    xor eax, eax
    EPILOGUE

.bss
.p2align 3
urls: .zero 24
url_n: .long 0

.section .rodata
.p2align 3
chrome_ops: .quad chrome_act, chrome_free
ho_opts_ask: .quad .Lh_continue, .Lh_never
ho_opts_opened: .quad .Lh_refresh, .Lh_without
rc_words: .quad .Lw_off, .Lw_connecting, .Lw_on, .Lw_error
.globl claude_side_n_print
claude_side_n_print: .asciz "print-agent-remote"
.Lv_side: .asciz "side_question"
.Lv_chrome: .asciz "get_chrome_dialog"
.Lv_remote: .asciz "remote_control"
.Lv_bridge: .asciz "bridge_state"
.Lv_connected: .asciz "connected"
.Lv_ready: .asciz "ready"
.Lv_failed: .asciz "failed"
.Lv_policy: .asciz "policy_disabled"
.Lv_success: .asciz "success"
.Lv_agents_cmd: .asciz "/agents"
.Lk_subtype: .asciz "subtype"
.Lk_question: .asciz "question"
.Lk_history: .asciz "history"
.Lk_response: .asciz "response"
.Lk_error: .asciz "error"
.Lk_enabled: .asciz "enabled"
.Lk_state: .asciz "state"
.Lk_detail: .asciz "detail"
.Lk_allowed: .asciz "allowed"
.Lk_installed: .asciz "installed"
.Lk_connected: .asciz "connected"
.Lk_default: .asciz "enabled_by_default"
.Lk_urls: .asciz "urls"
.Lk_install: .asciz "install"
.Lk_permissions: .asciz "permissions"
.Lk_reconnect: .asciz "reconnect"
.Ln_chrome: .asciz "chrome"
.Lt_chrome: .asciz "Claude in Chrome"
.Ll_loading: .asciz "Loading Claude in Chrome\342\200\246"
.Lc_not_allowed: .asciz "Claude in Chrome isn't available for this account."
.Lc_extension: .asciz "Chrome extension"
.Lc_installed: .asciz "Installed"
.Lc_not_detected: .asciz "Not detected"
.Lc_connection: .asciz "This session"
.Lc_connected: .asciz "Connected"
.Lc_not_connected: .asciz "Not connected"
.Lc_default: .asciz "Enabled by default"
.Lc_default_d: .asciz "Claude Code's setting: change it with /chrome in Claude Code's terminal"
.Lc_install: .asciz "Install Chrome extension"
.Lc_permissions: .asciz "Manage permissions"
.Lc_reconnect: .asciz "Reconnect extension"
.Lwho: .asciz "Claude Code"
.Le_unsent: .asciz "Couldn't ask Claude Code."
.Le_unknown: .asciz "unknown error"
.Lr_connecting: .asciz "Connecting to claude.ai/code\342\200\246"
.Lr_active: .asciz "Remote Control is active \302\267 Click to open claude.ai/code \302\267 Run /remote-control to turn off"
.Lr_url: .asciz "https://claude.ai/code"
.Lr_error: .asciz "Remote Control error: "
.Lr_dismiss: .asciz " \302\267 Run /remote-control to dismiss"
.Lr_noproc: .asciz "Remote Control needs Claude Code running: send a message first."
.Lh_ask: .asciz "Continue in Terminal to configure agents?"
.Lh_opened: .asciz "Terminal opened"
.Lh_continue: .asciz "Continue in Terminal"
.Lh_never: .asciz "Never mind"
.Lh_refresh: .asciz "Refresh and continue"
.Lh_without: .asciz "Continue without refreshing"
.Lw_off: .asciz "off"
.Lw_connecting: .asciz "connecting"
.Lw_error: .asciz "error"
.Ld_pill: .asciz " pill="
.Ld_tip: .asciz "\ttip="
.Lo_already_on: .asciz "already_on"
.Lo_turned_on: .asciz "turned_on"
.Lo_failed: .asciz "failed"
.Lo_declined: .asciz "declined"
.Lw_on: .asciz "on"
.Ld_remote: .asciz "remote="
.Lv_apply_flags: .asciz "apply_flag_settings"
.Lv_get_settings: .asciz "get_settings"
.Lk_settings: .asciz "settings"
.Lk_rca: .asciz "remoteControlAtStartup"
.Lk_effective: .asciz "effective"
.Lk_lock: .asciz "remote_control_policy_lock_reason"
.Lk_sources: .asciz "sources"
.Lk_source: .asciz "source"
.Lk_rc_avail: .asciz "remote_control_available"
.Lk_rc_auto: .asciz "remote_control_auto_enable"
.Lk_rc_bydefault: .asciz "remote_control_auto_on_by_default"
.Lk_rc_gate: .asciz "ide_rc_auto_enable_gate"
.Ls_policy: .asciz "policySettings"
.Ls_user: .asciz "userSettings"
.Ls_project: .asciz "projectSettings"
.Ls_local: .asciz "localSettings"
.Lrc_file: .asciz "/settings.json"
.Lrc_failed: .asciz "Failed to update \"Enable Remote Control for all sessions\": "
.Lrc_revoked: .asciz "Remote Control turned off. It can't be turned back on while your organization's lock is in place."
.Lrc_nodir: .asciz "Claude Code's settings folder is not known."
.Lrc_unread: .asciz "Couldn't read "
.Lrc_notjson: .asciz "Settings file is not valid JSON: "
.Lrc_notobj: .asciz "Settings file is not a JSON object: "
.Lrc_deep: .asciz "Settings file is nested too deeply to be written back: "
.Lrc_unsaved: .asciz "Your settings change was not saved: "

