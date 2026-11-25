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

.text

# FN claude_side_action(AL* or 0, act, ptr, len) -> eax: ACT_SIDEQ -> its request + 1 (0 not written);
#   ACT_REMOTE, ACT_CHROME, ACT_HANDOFF, ACT_HANDANS -> 1 done
FN claude_side_action
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
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
    je 7f
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
    EPILOGUE
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
