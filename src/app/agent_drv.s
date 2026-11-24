# the driver seam: a session of the agents panel that rhun can talk to has a driver, a table of
# functions (DRV, rhun.inc). The panel's prompt box and cards (agentext.s) are the same for every
# driver; what Send, Stop and a card's pick do is the driver's. A session rhun drives itself (Claude
# Code: agent_claude.s) gets a live record (AL, AS_live) on its first use: the connection to its
# program, its state, the prompts waiting for the program to be ready, the requests it waits on. An
# extension's session keeps no record: its extension keeps the state (DRVC_SESSION).
#
#   agent_drv_of(AS*) -> rax DRV* or 0        the driver that can talk for this session now
#   agent_drv_for_kind(kind) -> rax DRV* or 0 a built-in driver, when it is available (Claude Code:
#                                             [claude] chat is on; in a remote window too)
#   agent_drv_remote_back()                   a remote window's host answers again: conversations whose
#                                             file could not be read when their program ended are read
#   agent_kind_name(kind) -> rax cstr         "claude", "codex", "grok", "opencode", or "-"
#   agent_kind_named(ptr, len) -> eax kind    the kind of such a word, or 0
#   agent_live(AS*) -> rax AL* (made on first use; 0 without a driver that keeps one)
#   agent_live_get(AS*) -> rax AL* or 0
#   agent_live_state(AS*) -> eax ALS_* (ALS_OFF without a record)
#   agent_send(AS*, ptr, len) -> eax SEND_*   the user's prompt: shown at once, then sent, or kept until
#                                             the program is ready (it is started first when it is not
#                                             running), drawn queued meanwhile; while a turn runs written
#                                             at once and held (DRVC_QUEUE), else refused
#   agent_send_with(AS*, ptr, len, AP* or 0) -> eax SEND_*   the same with the message's parts (agentatt.s;
#                                             a driver with DRVC_PARTS): the pack is the callee's after
#                                             SEND_OK (freed once written), SEND_HELD (slimmed, kept with the
#                                             held message) and SEND_QUEUED (kept whole with the waiting
#                                             prompt), the caller's after any other answer. A waiting or held
#                                             prompt that is given back gives its pack back (agatt_return)
#   agent_queued(AS*, i) -> rax ptr, rdx len  its i-th message that has not started (drawn queued), or 0
#   agent_stop(AS*), agent_answer(AS*, n), agent_typing(AS*) (typing starts the program),
#   agent_touch(AS*) (more typing: the idle stop waits again), agent_stop_running(AS*) -> eax (Escape:
#   Stop when a turn runs), agent_release(AS*) (the program ends politely, as the idle stop does)
#   agent_new(kind) -> rax AS* or 0           a new conversation of a built-in driver, adopted and opened
#   agent_closed(AS*)                         its row is freed: the program ends, the record is freed
#   agent_retry(AS*) -> eax                   the error block's Retry: a failed one's program again, nothing sent
#   agent_state_set(AL*, state)               keeps AS_state in step: STARTING and WORKING are
#                                             AGS_WORKING, WAITING and HELD AGS_WAITING, FAILED
#                                             AGS_ERROR, OFF and READY AGS_IDLE
#   agent_drv_tick(), agent_drv_timeout() -> eax ms or -1, agent_drv_shutdown() (quit, the project changes),
#   agent_drv_apply() (the settings changed: a driver switched off ends what it drives),
#   agent_drv_unlisted() (the provider switches changed: what a provider switched off has ends)
#   agent_live_dump(sb, AS* or 0)             print-agent-live
#   agent_uuid(buf)                           a v4 UUID, 36 characters and a NUL
#   events drivers call (AL* first): ev_note(al, role, ptr, len), ev_failed(al, ptr, len) (could not
#     start or broke: ALS_FAILED, an error row, the prompts that waited back in the box), ev_ready(al)
#     (handshake done: the prompts that waited go), ev_text(al, key ptr, key len, ptr, len, replace) (a
#     block's reply text), ev_thought(al, key ptr, key len, ptr, len, replace) -> row (a block's thinking, its
#     row live while it streams), ev_thought_end(al, row, ms, tokens) (it is finished), ev_thought_tokens(al,
#     n) (the estimate of the thinking that streams), ev_request(al, AQ*, prompt ptr, len, opts, n) (a
#     request's card: WAITING), ev_request_gone(al, AQ*) (it is answered or withdrawn: its card goes, it
#     leaves AL_reqs and is freed), ev_mode(al, ptr, len), ev_turn_end(al, TE_*, ptr, len),
#     ev_closed(al, err) (the process is gone: OFF unless FAILED, the requests it waited on go with an
#     info row, the conversation read again from its file; prompts sent while it was ending start it
#     again), ev_config(al) (its lists changed: the project's record is saved, agentcfg.s),
#     ev_model(al, ptr, len), ev_effort(al, ptr, len) (what is in effect), ev_ultra(al, available, on),
#     ev_thinking(al, on), ev_fast(al, FS_*, reason ptr, len) (kept in the project's record too),
#     ev_pill(al, ptr, len) (a one-line pill row, "Switched to NAME"),
#     ev_spin(al, cstr or 0, static) (the spinner's words in place of a verb),
#     ev_band(al, BK_*, ptr, len) (a band above the box; ptr 0 takes it away; dismissed, it stays away until
#     its text changes), ev_band_link(al, BK_*, label cstr, url cstr) (a link under it, asked before it
#     opens), ev_usage(al, AGU*) (the context and prompt-cache numbers), ev_card(al, AQ*, CD*) (a request's
#     rich card, agentcard.s: WAITING), ev_started(al, uuid ptr, len) (a held message started: its row joins),
#     ev_dropped(al, uuid ptr, len) (a held message will not run: back to its own conversation's box)
#   A driver's table also has its lists and controls (DRV_modes, DRV_set_*, DRV_reply, DRV_action): the
#   extension driver's answer 0
#
#   agent_aq_free(AQ*)                        a request a driver made but never kept
#
# While a session's program runs or is about to (STARTING to HELD) its transcript is not read
# (session_update, agents.s): its rows come from the stream; ev_closed reads the file again.
#
# A start first passes rhun's own questions, each a card of rhun's (AL_own): a project the user did not open
# by hand (a rhun:// link, wfold_flags) is asked about once a window for a driver whose program reads the
# project's settings (DRVC_TRUST: Trust, Continue without); the program must be signed in (DRV_auth, asked
# in the background: not signed in is a notice with Sign In instead of the start, asked again at the next
# Send); a start that fails gets a notice with "Run claude in Terminal" (DRV_terminal).
#
# Before it continues an existing conversation (--resume) the driver says whether another program holds it
# (DRV_held: a terminal's claude, another rhun window's): the start waits up to g_drv_hold_ms, reading
# again every second, then rhun asks with a card of its own (ALS_HELD, AL_own): Open here anyway, Continue
# in a copy (a new conversation forked from it, the prompts that waited moved there), Cancel (they go back
# in the box). rhun's own programs are never holders.
#
# A program's life: it starts when the user types in the box or sends; it ends when it has been idle for
# [agents] idle_stop_minutes (the tick), when a new conversation is left before its first prompt (it goes,
# ALF_DRAFT), when the cap needs its place (the idle one used longest ago), and with its record when the
# chat is switched off, the project changes, its row is freed or rhun quits. An end rhun asked for is OFF,
# never FAILED (ALF_ENDING); one it did not ask for while a turn ran is FAILED, and the next Send starts
# it again (--resume once the file exists).
#   g_drv_idle_ms (0: [agents] idle_stop_minutes), g_drv_hold_ms: agent-timing's overrides
.include "rhun.inc"

.equ ENV_TICK_MS, 50            # a start waiting for the login environment looks again this often
.equ HOLD_MS, 10000             # how long a start waits for another holder of the conversation
.equ SEND_CHARS, 50000        # a prompt's characters at most (the extension's limit), in UTF-16 units
.equ MARKER_UNITS, 55           # .Lmarker's UTF-16 units
.equ ROWKEY_MAX, 80             # AL_rowkey's size
.equ RS_QUEUE, 1                # queue_restore's: the prompts that waited for a start
.equ RS_HELD, 2                 #   the messages held
.equ RS_ALL, 3
.equ SIGNIN_LEN, 29             # .Lq_signin's bytes

.bss
.p2align 3
lives: .zero VEC_SIZE           # AL*: every live record
jsb: .zero SB_SIZE              # the prompts that waited, joined; a new conversation's path
uuid_n: .quad 0                 # agent_uuid's counter (no /dev/urandom)
q_serial: .quad 0               # the last serial a prompt waiting for a start got (queue_dup)
trust_answered: .long 0         # the window's answer to the trust card was given (a project asks once)
.p2align 3
stx: .zero SB_SIZE              # signin_text's words in a remote window

.data
.p2align 2
.globl g_drv_idle_ms, g_drv_hold_ms
g_drv_idle_ms: .long 0
g_drv_hold_ms: .long HOLD_MS

.text

# FN agent_drv_for_kind(kind) -> rax the built-in driver of that kind when it is available, or 0
FN agent_drv_for_kind
    xor eax, eax
    cmp edi, AG_CLAUDE
    jne 1f
    cmp dword ptr [rip + cfg_claude_chat], 0
    je 1f
    lea rax, [rip + claude_drv]    # (a remote window's program runs on its host: agent_conn.s)
1:  ret

# FN agent_drv_of(AS*) -> rax the driver that can talk for this session now, or 0
FN agent_drv_of
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov ecx, [rdi + AS_kind]
    cmp ecx, AS_KIND_EXT
    jne 1f
    push rbx
    call agentext_prompts       # an extension's session: when its extension takes prompts
    pop rbx
    mov ecx, eax
    xor eax, eax
    test ecx, ecx
    jz 9f
    lea rax, [rip + ext_drv]
    ret
1:  mov edi, ecx
    jmp agent_drv_for_kind
9:  ret

# FN agent_kind_name(kind) -> rax the kind's word (agent-new, print-agent-input), or "-"
FN agent_kind_name
    lea rax, [rip + .Ldash]
    dec edi
    cmp edi, 3
    ja 1f
    lea rcx, [rip + kind_names]
    mov rax, [rcx + rdi*8]
1:  ret

# FN agent_kind_named(ptr, len) -> eax the built-in kind that word names, or 0
FN agent_kind_named
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp ebx, 4
    jae 8f
    lea rax, [rip + kind_names]
    mov rdx, [rax + rbx*8]
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    inc ebx
    test eax, eax
    jz 1b
    mov eax, ebx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---- live records ----

# FN agent_live_get(AS*) -> rax its live record, or 0
FN agent_live_get
    xor eax, eax
    test rdi, rdi
    jz 1f
    mov rax, [rdi + AS_live]
1:  ret

# FN agent_live_at(i) -> rax the i-th live record (from 0, in no order), or 0 past the last: a driver's clock
#   looks at its own
FN agent_live_at
    xor eax, eax
    cmp rdi, [rip + lives + VEC_len]
    jae 1f
    mov rax, [rip + lives + VEC_ptr]
    mov rax, [rax + rdi*8]
1:  ret

# FN agent_live(AS*) -> rax its live record, made on first use; 0 when its driver keeps none
FN agent_live
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    test rbx, rbx
    jz 9f
    mov rax, [rbx + AS_live]
    test rax, rax
    jnz 9f
    mov rdi, rbx
    call agent_drv_of
    test rax, rax
    jz 9f
    test dword ptr [rax + DRV_caps], DRVC_SESSION
    jnz 8f
    mov r12, rax
    mov edi, AL_SIZE
    call mem_alloc
    mov r13, rax
    mov [r13 + AL_as], rbx
    mov [r13 + AL_drv], r12
    mov qword ptr [r13 + AL_row], -1
    mov qword ptr [r13 + AL_next], 1
    mov dword ptr [r13 + AL_ultra], -1  # not offered until the driver says
    mov dword ptr [r13 + AL_think], 1
    mov [rbx + AS_live], r13
    lea rdi, [rip + lives]
    mov esi, 8
    call vec_push
    mov [rax], r13
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agent_live_state(AS*) -> eax its ALS_*, ALS_OFF without a live record
FN agent_live_state
    mov eax, ALS_OFF
    test rdi, rdi
    jz 1f
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 1f
    mov eax, [rcx + AL_state]
1:  ret

# FN agent_state_set(AL*, state): AL_state, and AS_state as the list and the box read it; a turn starting
#   (WORKING) takes the agent's suggestion away. OFF or FAILED ends whatever start or run there was (a Stop,
#   a failed start, a process gone, a held start given up): the driver lets go of what it kept for it
#   (DRV_ended), the one place that does
FN agent_state_set
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov [rbx + AL_state], esi
    lea rax, [rip + ags_of]
    mov eax, [rax + r12*4]
    mov rcx, [rbx + AL_as]
    mov [rcx + AS_state], eax
    mov dword ptr [rip + g_dirty], 1
    cmp r12d, ALS_WORKING       # a turn starts: the agent's suggestion goes
    jne 1f
    mov rdi, [rbx + AL_suggest]
    test rdi, rdi
    jz 9f
    call mem_free
    mov qword ptr [rbx + AL_suggest], 0
    jmp 9f
1:  cmp r12d, ALS_OFF
    je 2f
    cmp r12d, ALS_FAILED
    jne 9f
2:  mov rdi, rbx                # a dialog waiting for its process fails, one shown for it closes (agentdlg.s)
    call agentdlg_ended
    mov rdi, rbx                # p7c: a side question waiting for it fails (agentside.s)
    call agside_ended
    mov rdi, rbx
    mov rax, [rbx + AL_drv]
    call [rax + DRV_ended]
9:  EPILOGUE

# live_free(AL*): the program ends (conn_close), everything the record owns goes, AS_live is 0
live_free:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx                # phase 4 task 10: the driver lets go of what it kept for the record (DRV_ended:
    mov rax, [rbx + AL_drv]     #   Claude's waiting hook answers): nothing names it once it is freed
    call [rax + DRV_ended]
    mov rdi, [rbx + AL_as]      # a popup opened for its session closes (agentpop.s)
    call agentpop_gone
    mov rdi, rbx                # a dialog's wait on it ends (agentdlg.s)
    call agentdlg_gone
    mov rdi, rbx                # p7c: and a side question's (agentside.s)
    call agside_gone
    lea rdi, [rbx + AL_cn]
    call conn_close
    mov rdi, rbx
    call own_drop
    mov rdi, rbx
    call queue_free
    xor r12d, r12d
1:  cmp r12, [rbx + AL_reqs + VEC_len]
    jae 2f
    mov rax, [rbx + AL_reqs + VEC_ptr]
    mov rdi, [rax + r12*8]
    call aq_free
    inc r12
    jmp 1b
2:  lea rdi, [rbx + AL_reqs]
    call vec_free
    lea rdi, [rbx + AL_queue]
    call vec_free
    lea rdi, [rbx + AL_out]
    call vec_free
    lea rdi, [rbx + AL_report]
    call sb_free
    mov rdi, [rbx + AL_cdir]
    call mem_free
    mov rdi, [rbx + AL_unsent]  # prompts never given back go with their session
    call mem_free
    mov rdi, [rbx + AL_dseen]   # the driver's own block (Claude's record uuids)
    call mem_free
    mov rdi, rbx
    call live_lists_free
    mov rax, [rbx + AL_as]
    mov qword ptr [rax + AS_live], 0
    mov dword ptr [rax + AS_state], AGS_IDLE
    # out of the list of records
    xor ecx, ecx
3:  cmp rcx, [rip + lives + VEC_len]
    jae 5f
    mov rax, [rip + lives + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 4f
    inc rcx
    jmp 3b
4:  mov rdx, [rip + lives + VEC_len]
    dec rdx
    mov [rip + lives + VEC_len], rdx
    mov rdx, [rax + rdx*8]
    mov [rax + rcx*8], rdx
5:  mov rdi, rbx
    call mem_free
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agent_aq_free(AQ*): a request and what it owns (a driver's that never joined AL_reqs)
FN agent_aq_free
    jmp aq_free

# aq_free(AQ*): a request and what it owns
aq_free:
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    mov rdi, rbx                # a popup opened for it closes (agentpop.s)
    call agentpop_gone
    mov rdi, [rbx + AQ_tab]     # plan review: its tab and a comment prompt open for it close (mdtab.s)
    call mdtab_drop
    mov rdi, rbx                # phase 4 task 11: its proposed change's tab closes, nothing is sent
    call agoffer_drop
    mov rdi, [rbx + AQ_id]
    call mem_free
    mov rdi, [rbx + AQ_tool]
    call mem_free
    mov rdi, [rbx + AQ_input]
    call mem_free
    mov rdi, [rbx + AQ_q]
    call mem_free
    mov rdi, [rbx + AQ_tuid]
    call mem_free
    lea rdi, [rbx + AQ_picks]
    call sb_free
    mov rdi, [rbx + AQ_sugg]
    call mem_free
    mov rdi, [rbx + AQ_dkind]
    call mem_free
    mov rdi, [rbx + AQ_card]    # its rich card goes with it
    call agentcard_free
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# live_lists_free(AL*): the held messages, the suggestion and the bands
live_lists_free:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + AL_held + VEC_len]
    jae 2f
    imul r13, r12, AH_SIZE
    add r13, [rbx + AL_held + VEC_ptr]
    mov rdi, [r13 + AH_text]
    call mem_free
    mov rdi, [r13 + AH_chips]   # phase 4 task 2: its chips and pack go with it
    call mem_free
    mov rdi, [r13 + AH_pack]
    call agatt_free
    inc r12
    jmp 1b
2:  lea rdi, [rbx + AL_held]
    call vec_free
    mov rdi, [rbx + AL_suggest]
    call mem_free
    mov qword ptr [rbx + AL_suggest], 0
    xor r12d, r12d
3:  mov rdi, [rbx + AL_bands + r12*8]
    call mem_free
    mov qword ptr [rbx + AL_bands + r12*8], 0
    mov rdi, [rbx + AL_blinks + r12*8]
    call mem_free
    mov qword ptr [rbx + AL_blinks + r12*8], 0
    inc r12
    cmp r12, BK_COUNT
    jb 3b
    EPILOGUE

# queue_free(AL*): the prompts that waited go
queue_free:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + AL_queue + VEC_len]
    jae 2f
    mov rax, [rbx + AL_queue + VEC_ptr]
    mov rdi, [rax + r12*8]
    call q_free
    inc r12
    jmp 1b
2:  mov qword ptr [rbx + AL_queue + VEC_len], 0
    EPILOGUE

# queue_restore(AL*, what RS_*): messages that will not go go back to their own conversation, joined by
#   blank lines, the oldest first: the held ones (RS_HELD: written, never started; a toast says so), then
#   the prompts that waited for a start (RS_QUEUE); then they go
queue_restore:
    PROLOGUE
    mov rbx, rdi
    mov r14d, esi
    lea rdi, [rip + jsb]
    call sb_clear
    xor r15d, r15d              # a held one went back
    test r14d, RS_HELD
    jz 3f
    xor r12d, r12d
1:  cmp r12, [rbx + AL_held + VEC_len]
    jae 2f
    imul r13, r12, AH_SIZE
    add r13, [rbx + AL_held + VEC_ptr]
    mov rdi, [r13 + AH_text]
    mov rsi, [r13 + AH_len]
    call jsb_add
    mov rdi, [r13 + AH_text]
    call mem_free
    mov rdi, [r13 + AH_chips]   # phase 4 task 2: its parts go back with its text
    call mem_free
    mov rdi, [rbx + AL_as]
    mov rsi, [r13 + AH_pack]
    call agatt_return
    mov r15d, 1
    inc r12
    jmp 1b
2:  mov qword ptr [rbx + AL_held + VEC_len], 0
3:  test r14d, RS_QUEUE
    jz 5f
    xor r12d, r12d
4:  cmp r12, [rbx + AL_queue + VEC_len]
    jae 41f
    mov rax, [rbx + AL_queue + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    test r13, r13
    jz 4b
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call jsb_add
    mov rdi, r13                # phase 4 task 2: its parts go back with its text
    call q_tail
    mov rsi, [rax + 8]
    mov qword ptr [rax + 8], 0
    mov rdi, [rbx + AL_as]
    call agatt_return
    jmp 4b
41: mov rdi, rbx
    call queue_free
5:  cmp qword ptr [rip + jsb + SB_len], 0
    je 9f
    mov rdi, rbx
    call jsb_keep
    test r15d, r15d
    jz 9f
    lea rdi, [rip + .Lheld_back]
    call app_toast
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# jsb_add(ptr, len): a message's text after what jsb holds, a blank line between
jsb_add:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    cmp qword ptr [rip + jsb + SB_len], 0
    je 1f
    lea rdi, [rip + jsb]
    lea rsi, [rip + .Lblank]
    call sb_push_cstr
1:  lea rdi, [rip + jsb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    EPILOGUE

# jsb_keep(AL*): the text in jsb goes back to the session: into its box when the box is the session's
#   (agentext_restore), else kept for its box (after what was kept already), given back when it is opened
#   (agent_unsent_take)
jsb_keep:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + AL_as]
    mov rsi, [rip + jsb + SB_ptr]
    mov rdx, [rip + jsb + SB_len]
    call agentext_restore
    test eax, eax
    jnz 9f
    mov rdi, [rbx + AL_unsent]
    test rdi, rdi
    jz 7f
    call strlen
    mov r12, rax
    mov rdi, [rip + jsb + SB_ptr]
    call strlen
    lea rdi, [r12 + rax + 3]
    call mem_alloc
    mov r13, rax
    mov rdi, rax
    mov rsi, [rbx + AL_unsent]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Lblank]
    call cstr_copy
    mov rdi, rax
    mov rsi, [rip + jsb + SB_ptr]
    call cstr_copy
    mov rdi, [rbx + AL_unsent]
    call mem_free
    mov [rbx + AL_unsent], r13
    jmp 9f
7:  mov rdi, [rip + jsb + SB_ptr]
    mov rsi, [rip + jsb + SB_len]
    call mem_dup
    mov [rbx + AL_unsent], rax
9:  EPILOGUE

# FN agent_unsent_take(AS* or 0) -> rax the prompts of that session that never went and could not go back
#   in its box then (queue_restore), now the caller's (mem_free it), or 0
FN agent_unsent_take
    xor eax, eax
    test rdi, rdi
    jz 1f
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 1f
    mov rax, [rcx + AL_unsent]
    mov qword ptr [rcx + AL_unsent], 0
1:  ret

# FN agent_closed(AS*): its row is freed: the box forgets it, and a live record ends with its program
FN agent_closed
    PROLOGUE
    mov rbx, rdi
    call agentext_row_gone
    mov rdi, rbx                # a dialog opened for it closes (agentdlg.s)
    call agentdlg_gone
    mov rdi, rbx                # p7c: its side questions are cancelled, its agent map closes (agentside.s)
    call agside_gone
    mov r12, [rbx + AS_live]
    test r12, r12
    jz 9f
    mov rdi, rbx
    call agentext_card_drop
    mov rdi, r12
    call live_free
9:  EPILOGUE

# ---- what the user does ----

# FN agent_send(AS*, ptr, len) -> eax SEND_*: the user's prompt to the session's driver (see the top). Every
#   prompt gets a uuid (agent_uuid) the driver writes with it. Ready, nothing held: a row at once, then
#   written (SEND_OK). Starting (or held by rhun's question): it waits for ready, drawn queued (SEND_QUEUED,
#   AL_QUEUE_MAX at most: SEND_FULL). A turn runs, a card is up or others are held: a driver that takes
#   messages during a turn (DRVC_QUEUE) has it written now and held, drawn queued until it starts
#   (ev_started; SEND_HELD, AH_MAX at most: SEND_TOOMANY with a toast, the text stays); any other refuses it
#   (SEND_REFUSED). Locals: [rsp] the uuid (40 bytes), [rsp + 48] the pack (agent_send_with)
FN agent_send
    xor ecx, ecx
    jmp agent_send_with

# FN agent_send_with(AS*, ptr, len, AP* or 0) -> eax SEND_*: agent_send with the message's parts (see the top);
#   a prompt is empty only when its text is blank and it has no part (phase 4 task 2)
FN agent_send_with
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp + 48], rcx
    call agent_drv_of
    mov r14, rax
    mov eax, SEND_FAILED
    test r14, r14
    jz 9f
    xor ecx, ecx                # only blanks and no part: nothing to send
1:  cmp rcx, r13
    jae 11f
    movzx eax, byte ptr [r12 + rcx]
    inc rcx
    cmp eax, ' '
    jbe 1b
    jmp 12f
11: mov rdi, [rsp + 48]
    call agatt_count
    mov ecx, eax
    mov eax, SEND_EMPTY
    test ecx, ecx
    jz 9f
12: test dword ptr [r14 + DRV_caps], DRVC_SESSION
    jz 2f
    mov eax, SEND_REFUSED       # (an extension's session takes no parts: the box keeps them)
    cmp qword ptr [rsp + 48], 0
    jne 9f
    mov rdi, rbx                # an extension's: its own send says
    mov rsi, r12
    mov rdx, r13
    call [r14 + DRV_send]
    jmp 9f
2:  mov rdi, r12                # at most SEND_CHARS characters, counted as the box counts them (the
    mov rsi, r13                #   extension's limit: UTF-16 units, the CLI's own marker not counted)
    call agent_over
    test rax, rax
    jz 23f
    lea rdi, [rip + .Lprompt_long]
    call app_toast
    mov eax, SEND_FAILED
    jmp 9f
23: mov rdi, rbx
    call agent_live
    mov r15, rax
    mov eax, SEND_FAILED
    test r15, r15
    jz 9f
    call time_ms
    mov [r15 + AL_used], rax
    mov eax, [r15 + AL_state]
    cmp eax, ALS_STARTING
    je .Las_queue
    cmp eax, ALS_HELD           # its start waits for the user's answer: the prompt waits with it
    je .Las_queue
    cmp eax, ALS_OFF
    je 3f
    cmp eax, ALS_FAILED
    je 3f
    cmp qword ptr [r15 + AL_held + VEC_len], 0
    jne .Las_busy               # others are held: this one goes after them
    cmp eax, ALS_READY
    je .Las_ready
.Las_busy:                      # a turn runs, or a card is up
    mov eax, SEND_REFUSED
    test dword ptr [r14 + DRV_caps], DRVC_QUEUE
    jz 9f
    mov eax, SEND_TOOMANY
    cmp qword ptr [r15 + AL_held + VEC_len], AH_MAX
    jb 4f
    lea rdi, [rip + .Ltoo_many] # the text stays in the box
    call app_toast
    mov eax, SEND_TOOMANY
    jmp 9f
4:  lea rdi, [rsp]              # written now, held until it starts
    call agent_uuid
    mov rdi, r15
    mov rsi, r12
    mov rdx, r13
    lea rcx, [rsp]
    mov r8, [rsp + 48]
    mov rax, [r15 + AL_drv]
    call [rax + DRV_send]
    mov ecx, eax
    mov eax, SEND_FAILED        # refused, or the write broke (its close reported it)
    test ecx, ecx
    jz 9f
    cmp dword ptr [r15 + AL_state], ALS_READY
    jne 41f
    mov rdi, r15                # nothing ran (the others held ended unreported): a turn runs from now
    mov esi, ALS_WORKING
    call agent_state_set
41: mov rdi, r15
    lea rsi, [rsp]
    mov rdx, r12
    mov rcx, r13
    mov r8, [rsp + 48]          # the pack goes with it, slimmed
    call held_add
    mov eax, SEND_HELD
    jmp .Las_sent
3:  mov rdi, r15                # not running: started first, the prompt waits for ready
    call agent_start
    mov ecx, eax
    mov eax, SEND_FAILED
    test ecx, ecx
    jz 9f
    cmp dword ptr [r15 + AL_state], ALS_FAILED  # the start's first write broke the connection: its
    je 9f                                       #   close reported the failure already (ev_failed)
    jmp .Las_queue
.Las_queue:                     # it waits for ready, drawn queued (agents.s): no row yet
    mov eax, SEND_FULL
    cmp qword ptr [r15 + AL_queue + VEC_len], AL_QUEUE_MAX
    jae 9f
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp + 48]         # the pack waits with it, whole
    call queue_dup
    mov r14, rax
    lea rdi, [r15 + AL_queue]
    mov esi, 8
    call vec_push
    mov [rax], r14
    and dword ptr [r15 + AL_flags], ~ALF_DRAFT     # it got a prompt: leaving it keeps it
    mov dword ptr [rip + g_dirty], 1
    mov eax, SEND_QUEUED
    jmp .Las_sent
.Las_ready:
    cmp dword ptr [r15 + AL_cn + CN_state], CN_UP
    jne .Las_restart
    cmp dword ptr [r15 + AL_cn + CN_fd_in], 0
    jge .Las_now
.Las_restart:                   # its program is ending (the idle stop, the cap) or takes no input any
    or dword ptr [r15 + AL_flags], ALF_RESTART  #   more: the prompt waits, a new start follows its end
    jmp .Las_queue              #   (ev_closed), as the next Send after it would
.Las_now:
    and dword ptr [r15 + AL_flags], ~(ALF_DRAFT | ALF_UNANSWERED)
    mov rdi, r15                # a notice of rhun's goes with the next prompt
    call own_drop
    mov rdi, r15                # WORKING before the write: a connection that breaks under it is a turn
    mov esi, ALS_WORKING        #   that failed (the driver's close reports it, FAILED)
    call agent_state_set
    lea rdi, [rsp]
    call agent_uuid
    mov rdi, r15
    mov rsi, r12
    mov rdx, r13
    lea rcx, [rsp]
    mov r8, [rsp + 48]
    mov rax, [r15 + AL_drv]
    call [rax + DRV_send]
    test eax, eax
    jz 7f
    call user_row               # written: its row (a prompt refused or lost stays in the box alone)
    mov rdi, rbx                # phase 4 task 2: the row's chips, and the pack is done with
    mov rsi, rax
    mov rdx, [rsp + 48]
    call pack_row
    mov eax, SEND_OK
    jmp .Las_sent
7:  cmp dword ptr [r15 + AL_state], ALS_WORKING
    jne 8f                      # it broke: FAILED already
    mov rdi, r15                # refused, nothing went: ready again
    mov esi, ALS_READY
    call agent_state_set
8:  mov eax, SEND_FAILED
    jmp 9f
.Las_sent:                      # it went or waits to: [agents] scroll_on_send
    mov r14d, eax
    mov rdi, rbx
    call agents_sent
    mov eax, r14d
9:  EPILOGUE

# FN agent_units(ptr, len) -> rax its UTF-16 units: a character above U+FFFF (a four-byte one) counts 2, as
#   the extension's length does
FN agent_units
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 9f
    movzx edx, byte ptr [rdi + rcx]
    inc rcx
    mov r8d, edx
    and r8d, 0xc0
    cmp r8d, 0x80
    je 1b
    inc rax
    cmp edx, 0xf0
    jb 1b
    inc rax
    jmp 1b
9:  ret

# FN agent_over(ptr, len) -> rax the UTF-16 units past SEND_CHARS (0 within it); a text ending with the
#   CLI's own truncation marker does not count it. The box (agentcompose.s) and agent_send both count so
FN agent_over
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call agent_units
    mov rbx, rax
    lea rdi, [rip + .Lmarker]
    call strlen
    cmp r13, rax
    jb 1f
    mov rdx, rax
    lea rdi, [r12 + r13]
    sub rdi, rax
    lea rsi, [rip + .Lmarker]
    call memeq
    test eax, eax
    jz 1f
    sub rbx, MARKER_UNITS
1:  xor eax, eax
    sub rbx, SEND_CHARS
    jle 9f
    mov rax, rbx
9:  EPILOGUE

# held_add(AL*, uuid cstr, ptr, len, AP* or 0): a message written during a turn joins AL_held (its text copied;
#   its pack, now the entry's, slimmed: its chips kept as text for its row; the pathless bytes of all held
#   packs at most AP_MAX_BYTES, the oldest's going first)
held_add:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8
    lea rdi, [rbx + AL_held]
    mov esi, AH_SIZE
    call vec_push
    mov r15, rax
    lea rdi, [r15 + AH_uuid]
    mov rsi, r12
    call cstr_copy
    mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov [r15 + AH_text], rax
    mov [r15 + AH_len], r14
    mov rdi, [rsp]              # phase 4 task 2: its chips, its pack slimmed
    call agatt_chips_dup
    mov [r15 + AH_chips], rax
    mov rdi, [rsp]
    call agatt_slim
    mov rax, [rsp]
    mov [r15 + AH_pack], rax
    mov rdi, rbx
    call held_cap
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# held_cap(AL*): the pathless bytes of the held packs (pasted images) at most AP_MAX_BYTES: past that the
#   oldest's go (given back, each says it could not be kept)
held_cap:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d              # the bytes held
    xor r13d, r13d
1:  cmp r13, [rbx + AL_held + VEC_len]
    jae 2f
    imul rax, r13, AH_SIZE
    add rax, [rbx + AL_held + VEC_ptr]
    mov rdi, [rax + AH_pack]
    call agatt_pathless
    add r12, rax
    inc r13
    jmp 1b
2:  xor r13d, r13d
3:  cmp r12, AP_MAX_BYTES
    jbe 9f
    cmp r13, [rbx + AL_held + VEC_len]
    jae 9f
    imul rax, r13, AH_SIZE
    add rax, [rbx + AL_held + VEC_ptr]
    mov rdi, [rax + AH_pack]
    call agatt_drop_pathless
    sub r12, rax
    inc r13
    jmp 3b
9:  EPILOGUE

# pack_row(AS*, row index or -1, AP* or 0): a message written with its parts: its row gets their chips, and the
#   pack, written, is freed
pack_row:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz 9f
    mov rdi, r13
    call agatt_chips_dup
    mov r14, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call agatt_row_chips
    mov rdi, r14
    call mem_free
    mov rdi, r13
    call agatt_free
9:  EPILOGUE

# held_find(AL*, uuid ptr, len) -> rax the index in AL_held of the message written with that uuid, or -1
held_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, [rbx + AL_held + VEC_len]
    jae 8f
    imul r15, r14, AH_SIZE
    add r15, [rbx + AL_held + VEC_ptr]
    lea rdi, [r15 + AH_uuid]
    call strlen
    cmp rax, r13
    jne 2f
    lea rdi, [r15 + AH_uuid]
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jnz 3f
2:  inc r14
    jmp 1b
3:  mov rax, r14
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# held_take(AL*, i) -> rax its text (now the caller's), rdx its length, rcx its chips text (the caller's, or 0),
#   r8 its pack (the caller's, or 0): message i leaves AL_held, the order of the others kept
held_take:
    PROLOGUE 16
    mov rbx, rdi
    imul r12, rsi, AH_SIZE
    add r12, [rbx + AL_held + VEC_ptr]
    mov r13, [r12 + AH_text]
    mov r14, [r12 + AH_len]
    mov rax, [r12 + AH_chips]
    mov [rsp], rax
    mov rax, [r12 + AH_pack]
    mov [rsp + 8], rax
    mov rax, [rbx + AL_held + VEC_len]
    dec rax
    mov [rbx + AL_held + VEC_len], rax
    imul rdx, rax, AH_SIZE
    add rdx, [rbx + AL_held + VEC_ptr]
    sub rdx, r12                # the bytes after it
    mov rdi, r12
    lea rsi, [r12 + AH_SIZE]
    call memmove
    mov dword ptr [rip + g_dirty], 1
    mov rax, r13
    mov rdx, r14
    mov rcx, [rsp]
    mov r8, [rsp + 8]
    EPILOGUE

# queue_dup(ptr, len, AP* or 0) -> rax a prompt waiting for a start, as AL_queue keeps it: a cstr of the text,
#   and after its NUL, at the next multiple of 8 (q_tail), a serial of its own (never 0: agent_queued's id for
#   it), then its pack (now the block's, whole) and its chips text (owned, or 0)
queue_dup:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r14, rdx
    lea rdi, [rsi + 32]
    call mem_alloc
    mov r13, rax
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call memmove
    mov byte ptr [r13 + r12], 0
    inc qword ptr [rip + q_serial]
    mov rax, [rip + q_serial]
    lea r15, [r12 + 8]
    and r15, -8
    add r15, r13
    mov [r15], rax
    mov [r15 + 8], r14
    mov rdi, r14
    call agatt_chips_dup
    mov [r15 + 16], rax
    mov rax, r13
    EPILOGUE

# q_tail(block) -> rax where its serial is (its pack at + 8, its chips text at + 16)
q_tail:
    push rdi
    call strlen
    pop rdi
    add rax, 8
    and rax, -8
    add rax, rdi
    ret

# q_free(block or 0): a waiting prompt and what it owns
q_free:
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    call q_tail
    mov r12, rax
    mov rdi, [r12 + 8]
    call agatt_free
    mov rdi, [r12 + 16]
    call mem_free
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# FN agent_queued(AS* or 0, i) -> rax ptr, rdx len, rcx which message it is (a held one's: the first 8 bytes
#   of its uuid; a prompt waiting for a start: its serial, queue_dup), r8 its pack (AP* or 0, borrowed), r9
#   its chips text (cstr or 0, borrowed) of its i-th message that has not started (those that wait for a
#   start first, then those held), or rax 0 past the last: what agents.s draws queued
FN agent_queued
    PROLOGUE
    xor eax, eax
    xor edx, edx
    test rdi, rdi
    jz 9f
    mov rbx, [rdi + AS_live]
    test rbx, rbx
    jz 9f
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13, [rbx + AL_queue + VEC_len]
    jae 3f
    mov rax, [rbx + AL_queue + VEC_ptr]
    mov rax, [rax + r13*8]
    inc r13
    test rax, rax
    jz 1b                       # (one being written: ev_ready)
    test r12, r12
    jz 2f
    dec r12
    jmp 1b
2:  mov r14, rax
    mov rdi, rax
    call strlen
    mov r15, rax
    mov rdi, r14                # (its serial, after the NUL at the next multiple of 8: queue_dup)
    call q_tail
    mov rcx, [rax]
    mov r8, [rax + 8]
    mov r9, [rax + 16]
    mov rdx, r15
    mov rax, r14
    EPILOGUE
3:  xor eax, eax
    cmp r12, [rbx + AL_held + VEC_len]
    jae 9f
    imul rcx, r12, AH_SIZE
    add rcx, [rbx + AL_held + VEC_ptr]
    mov rax, [rcx + AH_text]
    mov rdx, [rcx + AH_len]
    mov r8, [rcx + AH_pack]
    mov r9, [rcx + AH_chips]
    mov rcx, [rcx + AH_uuid]    # the start of its uuid: which message it is (queued_sync)
9:  EPILOGUE

# FN agent_pending(AS* or 0, word cstr) -> eax 1 while a message that is that command (the word alone, or
#   followed by a blank and its arguments) has not ended in that conversation: it waits for a start, is
#   held, or is the turn that runs now (WORKING or WAITING, and the message that started last is it).
#   Asked each time, nothing remembered: typed or sent by a control, refused sends and freed conversations
#   need no care
FN agent_pending
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r15d, r15d
    test rbx, rbx
    jz 9f
    mov r13, [rbx + AS_live]
    test r13, r13
    jz 9f
    xor r14d, r14d              # waiting for a start
1:  cmp r14, [r13 + AL_queue + VEC_len]
    jae 2f
    mov rax, [r13 + AL_queue + VEC_ptr]
    mov rdi, [rax + r14*8]
    inc r14
    test rdi, rdi
    jz 1b
    mov rsi, -1
    mov rdx, r12
    call is_cmd
    test eax, eax
    jnz 8f
    jmp 1b
2:  xor r14d, r14d              # held
3:  cmp r14, [r13 + AL_held + VEC_len]
    jae 4f
    imul rax, r14, AH_SIZE
    add rax, [r13 + AL_held + VEC_ptr]
    inc r14
    mov rdi, [rax + AH_text]
    mov rsi, [rax + AH_len]
    mov rdx, r12
    call is_cmd
    test eax, eax
    jnz 8f
    jmp 3b
4:  mov eax, [r13 + AL_state]   # running
    cmp eax, ALS_WORKING
    je 5f
    cmp eax, ALS_WAITING
    jne 9f
5:  mov rdi, rbx
    call agents_last_user
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    call is_cmd
    test eax, eax
    jz 9f
8:  mov r15d, 1
9:  mov eax, r15d
    EPILOGUE

# is_cmd(ptr, len (-1: a cstr), word cstr) -> eax 1 when the text is the word, or the word and a blank after it
is_cmd:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
    test rbx, rbx
    jz 9f
    cmp r12, -1
    jne 1f
    call strlen
    mov r12, rax
1:  mov rdi, r13
    call strlen
    mov r15, rax
    cmp r12, r15
    jb 9f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r15
    call memeq
    test eax, eax
    jz 9f
    cmp r12, r15
    je 8f
    movzx eax, byte ptr [rbx + r15]
    cmp eax, ' '
    je 8f
    cmp eax, 9
    je 8f
    cmp eax, 10
    jne 9f
8:  mov r14d, 1
9:  mov eax, r14d
    EPILOGUE

# user_row(): agent_send's prompt (rbx AS, r12 ptr, r13 len, r15 AL*) as the user's row, shown at once
user_row:
    PROLOGUE
    mov rdi, r15
    mov rsi, r12
    mov rdx, r13
    call prompt_row
    EPILOGUE

# prompt_row(AL*, ptr, len) -> rax its index, -1: a prompt that was written, as the user's row (user_row,
#   ev_ready, ev_started). One that is a command (is_echo) is a command's echo (AMF_ECHO), drawn as the file's
#   echo of it will be (phase 3 task 8)
prompt_row:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [rbx + AL_as]
    mov esi, R_USER
    mov rdx, r12
    mov rcx, r13
    xor r8d, r8d
    call agents_msg_add
    mov r14, rax
    test rax, rax
    js 9f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call is_echo
    test eax, eax
    jz 9f
    mov rdi, [rbx + AL_as]
    mov rsi, r14
    mov edx, AMF_ECHO
    call agents_row_flag
9:  mov rax, r14
    EPILOGUE

# is_echo(AL*, ptr, len) -> eax 1 when the prompt (blanks before it skipped) is "/" and a command's name
#   (letters, digits, "-", "_", ":", ".") alone or before a blank: what the CLI answers as a command (its
#   list does not name every one: /status, finding 22), and what the file's echo of it shows (the bundle's
#   isSlashCommand); "/usr/bin" is none
is_echo:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
1:  test r13, r13
    jz 8f
    movzx ecx, byte ptr [r12]
    cmp ecx, ' '
    ja 2f
    inc r12
    dec r13
    jmp 1b
2:  cmp ecx, '/'
    jne 8f
    mov eax, 1
3:  cmp rax, r13
    jae 5f
    movzx ecx, byte ptr [r12 + rax]
    cmp ecx, ' '
    jbe 5f
    cmp ecx, '-'
    je 4f
    cmp ecx, '_'
    je 4f
    cmp ecx, ':'
    je 4f
    cmp ecx, '.'
    je 4f
    mov edx, ecx
    sub edx, '0'
    cmp edx, 9
    jbe 4f
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 25
    ja 8f
4:  inc rax
    jmp 3b
5:  cmp rax, 1
    jbe 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# agent_start(AL*) -> eax 1 when its program starts (or will, once the login environment is known), 0
#   when it failed: the reason is an error row
agent_start:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rbx + AL_report]
    call sb_clear
    mov rdi, rbx                # a card of rhun's from an earlier start goes
    call own_drop
    mov rax, [rbx + AL_as]      # the rows from here on come from the stream
    mov rax, [rax + AS_msgs + VEC_len]
    mov [rbx + AL_live_from], rax
    and dword ptr [rbx + AL_flags], ~(ALF_ENDING | ALF_STOP_ASKED | ALF_CAPWAIT | ALF_HOLDWAIT | ALF_HOLDOK | ALF_AUTHWAIT)
    or dword ptr [rbx + AL_flags], ALF_ASKAGAIN
    mov rdi, rbx
    mov esi, ALS_STARTING
    call agent_state_set
    cmp dword ptr [rip + g_remote], 0   # a remote window's program has its host's login environment
    jne 1f
    call uproc_env_ready
    test eax, eax
    jnz 1f
    or dword ptr [rbx + AL_flags], ALF_ENVWAIT     # the tick starts it
    mov eax, 1
    EPILOGUE
1:  mov rdi, rbx
    call drv_start
    EPILOGUE

# drv_start(AL*) -> eax 1 started (or waiting), 0 failed (ev_failed with the driver's report). A
#   conversation another program holds (DRV_held) waits for it to let go: read again every second for
#   g_drv_hold_ms (ALF_HOLDWAIT, the tick), then rhun asks (ALS_HELD, its card). At the cap (g_conn_max
#   programs) the idle one used longest ago is released first and the start waits for a program to end
#   (ALF_CAPWAIT, the tick starts it); with none idle it fails
drv_start:
    PROLOGUE
    mov rbx, rdi
    and dword ptr [rbx + AL_flags], ~(ALF_ENVWAIT | ALF_CAPWAIT | ALF_AUTHWAIT)
    mov rax, [rbx + AL_drv]     # a project the user did not open by hand (a rhun:// link) is asked about
    test dword ptr [rax + DRV_caps], DRVC_TRUST     #   first, once a window (design 5)
    jz 17f
    cmp dword ptr [rip + trust_answered], 0
    jne 17f
    xor edi, edi
    call wfold_flags
    and eax, WS_PRIMARY | WS_TRUSTED
    cmp eax, WS_PRIMARY         # a folder that is not trusted (no folder: nothing to trust)
    jne 17f
    mov rdi, rbx
    call ask_trust
    mov eax, 1
    EPILOGUE
17: xor esi, esi                # signed in? (asked in the background; a "no" again at the user's start)
    test dword ptr [rbx + AL_flags], ALF_ASKAGAIN
    setnz sil
    and dword ptr [rbx + AL_flags], ~ALF_ASKAGAIN
    mov rdi, rbx
    mov rax, [rbx + AL_drv]
    call [rax + DRV_auth]
    cmp eax, AUTH_WAIT
    je .Lds_auth
    cmp eax, AUTH_OUT
    je .Lds_out
    test dword ptr [rbx + AL_flags], ALF_HOLDOK
    jnz 0f
    mov rdi, rbx
    mov rax, [rbx + AL_drv]
    call [rax + DRV_held]
    cmp eax, HOLDER_OTHER       # unknown is none: the records are advisory
    je .Lds_hold
    or dword ptr [rbx + AL_flags], ALF_HOLDOK
0:  call cap_full
    test eax, eax
    jz 2f
    mov rdi, rbx
    call cap_room
    test eax, eax
    jz 1f
    or dword ptr [rbx + AL_flags], ALF_CAPWAIT
    mov eax, 1
    EPILOGUE
1:  lea rdi, [rbx + AL_report]
    call sb_clear
    lea rdi, [rbx + AL_report]
    lea rsi, [rip + .Lbusy]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rbx + AL_report + SB_ptr]
    mov rdx, [rbx + AL_report + SB_len]
    call ev_failed
    mov rdi, rbx                # it is no failure of the program's: no notice for it
    call own_drop
    xor eax, eax
    EPILOGUE
2:  mov rdi, rbx
    mov rax, [rbx + AL_drv]
    call [rax + DRV_start]
    test eax, eax
    jnz 9f
3:  mov rdi, rbx
    mov rsi, [rbx + AL_report + SB_ptr]
    mov rdx, [rbx + AL_report + SB_len]
    call ev_failed
    xor eax, eax
9:  EPILOGUE
.Lds_auth:                      # the tick looks again
    or dword ptr [rbx + AL_flags], ALF_AUTHWAIT
    mov eax, 1
    EPILOGUE
.Lds_out:                       # not signed in: the notice instead of the start
    mov rdi, rbx
    call signed_out
    xor eax, eax
    EPILOGUE
.Lds_hold:                      # held elsewhere: the tick reads the records again
    or dword ptr [rbx + AL_flags], ALF_HOLDWAIT
    call time_ms
    mov ecx, [rip + g_drv_hold_ms]
    lea rdx, [rax + rcx]
    mov [rbx + AL_hold_until], rdx
    mov rdi, rbx
    mov rsi, rax
    call hold_next
    mov eax, 1
    EPILOGUE

# hold_next(AL*, now): the holder is read again a second from now, or at the wait's end when sooner
hold_next:
    lea rax, [rsi + 1000]
    cmp rax, [rdi + AL_hold_until]
    jle 1f
    mov rax, [rdi + AL_hold_until]
1:  mov [rdi + AL_hold_at], rax
    ret

# hold_tick(AL*): ALF_HOLDWAIT's step when its time came: free now -> the start goes on; still held at
#   the wait's end -> rhun asks
hold_tick:
    PROLOGUE
    mov rbx, rdi
    call time_ms
    mov r12, rax
    cmp r12, [rbx + AL_hold_at]
    jl 9f
    mov rdi, rbx
    mov rax, [rbx + AL_drv]
    call [rax + DRV_held]
    cmp eax, HOLDER_OTHER
    je 1f
    and dword ptr [rbx + AL_flags], ~ALF_HOLDWAIT
    or dword ptr [rbx + AL_flags], ALF_HOLDOK
    mov rdi, rbx
    call drv_start
    EPILOGUE
1:  call time_ms                # the read took its time
    mov r12, rax
    cmp r12, [rbx + AL_hold_until]
    jge 2f
    mov rdi, rbx
    mov rsi, r12
    call hold_next
    EPILOGUE
2:  and dword ptr [rbx + AL_flags], ~ALF_HOLDWAIT
    mov rdi, rbx
    call ask_held
9:  EPILOGUE

# ---- rhun's own cards (AL_own) ----

# ask_held(AL*): the conversation is still open somewhere else: ALS_HELD and the card that asks
ask_held:
    PROLOGUE
    mov rbx, rdi
    mov esi, ALS_HELD
    call agent_state_set
    lea rdi, [rip + .Lq_held]
    call strlen
    mov rdi, rbx
    mov esi, AQK_HELD
    lea rdx, [rip + .Lq_held]
    mov rcx, rax
    lea r8, [rip + opts_held]
    mov r9d, 3
    call own_card
    EPILOGUE

# ask_trust(AL*): the project is not trusted: ALS_HELD and the card that asks whether the program may use
#   its own settings, hooks and servers
ask_trust:
    PROLOGUE
    mov rbx, rdi
    mov esi, ALS_HELD
    call agent_state_set
    lea rdi, [rip + .Lq_trust]
    call strlen
    mov rdi, rbx
    mov esi, AQK_TRUST
    lea rdx, [rip + .Lq_trust]
    mov rcx, rax
    lea r8, [rip + opts_trust]
    mov r9d, 2
    call own_card
    EPILOGUE

# signed_out(AL*): its program is not signed in: no start (FAILED, the reason in AL_report, the prompts
#   back in the box) and the sign-in notice; the state is asked again at the next Send
signed_out:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rbx + AL_report]
    call sb_clear
    call signin_text
    lea rdi, [rbx + AL_report]
    mov rsi, rax
    call sb_push
    mov rdi, rbx
    mov esi, ALS_FAILED
    call agent_state_set
    mov rdi, rbx
    call start_abandon
    mov rdi, rbx
    call ev_signed_out
    EPILOGUE

# FN ev_signed_out(al): the sign-in notice (a card with Sign In): before a start, or after a turn the
#   program's credentials failed
FN ev_signed_out
    PROLOGUE
    mov rbx, rdi
    call signin_text
    mov rcx, rdx
    mov rdx, rax
    mov rdi, rbx
    mov esi, AQK_SIGNIN
    lea r8, [rip + opts_signin]
    mov r9d, 1
    call own_card
    EPILOGUE

# signin_text() -> rax ptr, rdx len: the sign-in notice's words; a remote window's name its host (its program
#   and its sign-in are there: Sign In runs in rhun's terminal, which is on the host too)
signin_text:
    cmp dword ptr [rip + g_remote], 0
    jne 1f
    lea rax, [rip + .Lq_signin]
    mov edx, SIGNIN_LEN
    ret
1:  PROLOGUE
    lea rdi, [rip + stx]
    call sb_clear
    lea rdi, [rip + stx]
    lea rsi, [rip + .Lq_signin]
    mov edx, SIGNIN_LEN - 1     # without its "."
    call sb_push
    lea rdi, [rip + stx]
    lea rsi, [rip + .Lq_on]
    call sb_push_cstr
    call remote_host
    cmp byte ptr [rax], 0
    jne 2f
    lea rax, [rip + .Lq_the_host]
2:  lea rdi, [rip + stx]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + stx]
    mov esi, '.'
    call sb_push_byte
    mov rax, [rip + stx + SB_ptr]
    mov rdx, [rip + stx + SB_len]
    EPILOGUE

# failed_notice(AL*): its start failed: the notice with "Run claude in Terminal", and the wrapper named
#   when one is set (a wrapper that does not start claude fails every start)
failed_notice:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + jsb]
    call sb_clear
    lea rdi, [rip + jsb]
    lea rsi, [rip + .Lq_failed]
    call sb_push_cstr
    mov r12, [rip + cfg_claude_wrapper]
    cmp byte ptr [r12], 0
    je 1f
    lea rdi, [rip + jsb]
    lea rsi, [rip + .Lq_wrapper]
    call sb_push_cstr
    lea rdi, [rip + jsb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + jsb]
    lea rsi, [rip + .Lq_wrapper_tail]
    call sb_push_cstr
1:  mov rdi, rbx
    mov esi, AQK_FAILED
    mov rdx, [rip + jsb + SB_ptr]
    mov rcx, [rip + jsb + SB_len]
    lea r8, [rip + opts_failed]
    mov r9d, 1
    call own_card
    EPILOGUE

# own_card(AL*, kind, prompt ptr, len, opts cstr*, n): rhun's own card on the session (an AQ of that kind
#   in AL_own; the one it had goes)
own_card:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 8], rdx
    mov [rsp + 16], rcx
    mov r14, r8
    mov r15, r9
    call own_drop
    mov edi, AQ_SIZE
    call mem_alloc
    mov r12, rax
    mov ecx, [rsp]
    mov [r12 + AQ_kind], ecx
    mov [rbx + AL_own], r12
    mov rdi, [rbx + AL_as]
    mov rsi, r12
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    mov r8, r14
    mov r9, r15
    call agentext_card
    EPILOGUE

# FN agent_own_card(AL*, kind, prompt ptr, len, opts cstr*, n): own_card for a driver (p7c: the hand-off)
FN agent_own_card
    jmp own_card

# own_drop(AL*): rhun's own card goes (from the screen when it shows), unanswered
own_drop:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AL_own]
    test r12, r12
    jz 9f
    mov qword ptr [rbx + AL_own], 0
    mov rdi, [rbx + AL_as]
    call agentext_card_token
    cmp rax, r12
    jne 1f
    mov rdi, [rbx + AL_as]
    call agentext_card_drop
1:  mov rdi, r12
    call aq_free
9:  EPILOGUE

# own_answer(AL*, kind, n): option n of rhun's own card. Held: Open here anyway, Continue in a copy, Cancel.
#   Trust: Trust (Trust Folder for Git, then the start with all setting sources), Continue without (the
#   start with the user's only). Both remembered for the window. The sign-in and failed-start notices
#   put claude in the terminal prompt and stay until the next Send
own_answer:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    cmp r12d, AQK_HANDOFF       # p7c: the hand-off card is the driver's (DRV_action ACT_HANDANS)
    jne 0f
    call own_drop
    mov rdi, rbx
    mov esi, ACT_HANDANS
    mov rdx, r13
    xor ecx, ecx
    mov rax, [rbx + AL_drv]
    call [rax + DRV_action]
    EPILOGUE
0:
    cmp r12d, AQK_SIGNIN
    je .Loa_signin
    cmp r12d, AQK_FAILED
    je .Loa_failed
    cmp r12d, AQK_TRUST
    je .Loa_trust
    cmp r12d, AQK_HELD
    jne 9f
    mov rdi, rbx
    call own_drop
    test r13, r13
    jnz 1f
    or dword ptr [rbx + AL_flags], ALF_HOLDOK  # Open here anyway
3:  mov rdi, rbx
    mov esi, ALS_STARTING
    call agent_state_set
    mov rdi, rbx
    call drv_start
    EPILOGUE
1:  cmp r13, 1
    jne 2f
    mov rdi, rbx                # Continue in a copy
    call fork_copy
    EPILOGUE
2:  mov rdi, rbx                # Cancel: the prompts go back in the box
    call start_abandon
    mov rdi, rbx
    mov esi, ALS_OFF
    call agent_state_set
9:  EPILOGUE
.Loa_trust:
    mov rdi, rbx
    call own_drop
    mov dword ptr [rip + trust_answered], 1
    test r13, r13
    jnz 3b
    call cmd_trust_folder       # the project's own settings from now on (wfold_flags)
    jmp 3b
.Loa_signin:
    mov rdi, rbx
    mov esi, 1
    mov rax, [rbx + AL_drv]
    call [rax + DRV_terminal]
    EPILOGUE
.Loa_failed:
    mov rdi, rbx
    xor esi, esi
    mov rax, [rbx + AL_drv]
    call [rax + DRV_terminal]
    EPILOGUE

# start_abandon(AL*): a start that never ran: the rows it showed go (the prompts that waited) and those
#   prompts go back in the box
start_abandon:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + AL_as]
    mov rsi, [rbx + AL_live_from]
    call agents_ext_truncate
    mov qword ptr [rbx + AL_row], -1
    mov byte ptr [rbx + AL_rowkey], 0
    mov rdi, rbx
    mov esi, RS_ALL
    call queue_restore
    EPILOGUE

# fork_copy(AL*): Continue in a copy: a new conversation (a new id, "Copy of TITLE", the original's rows
#   so far) opened, the prompts that waited moved to it, and started as a fork of the original
#   (ALF_FORK: --resume=SRC --fork-session --session-id=NEW). The original is left alone (OFF, its
#   rows as its file has them). Locals: [rsp] the new id (40 bytes)
fork_copy:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, [rbx + AL_as]
    lea rdi, [rip + jsb]        # the title
    call sb_clear
    lea rdi, [rip + jsb]
    lea rsi, [rip + .Lcopy_of]
    call sb_push_cstr
    mov rsi, [r12 + AS_title]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lconversation]
1:  lea rdi, [rip + jsb]
    call sb_push_cstr
    mov rdi, [rip + jsb + SB_ptr]
    mov rsi, [rip + jsb + SB_len]
    call mem_dup
    mov r14, rax
    lea rdi, [rsp]
    call agent_uuid
    mov edi, [r12 + AS_kind]
    mov rsi, [r12 + AS_cwd]
    test rsi, rsi
    jnz 2f
    mov rsi, [rip + g_project]
2:  mov rdx, r14
    lea rcx, [rsp]
    call new_as
    mov r15, rax
    mov rdi, r14
    call mem_free
    test r15, r15
    jz 8f
    mov rdi, r15                # what the copy holds of the original so far
    mov rsi, r12
    mov rdx, [rbx + AL_live_from]
    call agents_copy_rows
    mov rdi, r15
    call agents_adopt
    mov rdi, r15
    call agentext_open_keep
    mov rdi, r15
    call agent_live
    test rax, rax
    jz 8f
    mov r13, rax
    or dword ptr [r13 + AL_flags], ALF_NEW | ALF_FORK
    lea rdi, [r13 + AL_sid]
    lea rsi, [rsp]
    call cstr_copy
    lea rdi, [r13 + AL_fork]
    lea rsi, [rbx + AL_sid]
    call cstr_copy
    mov rdi, r13                # the copy lives where its source does
    mov rsi, rbx
    call claude_fork_dir
    mov rdi, [rbx + AL_as]      # the original: its own rows only, no prompt waiting
    mov rsi, [rbx + AL_live_from]
    call agents_ext_truncate
    mov rdi, rbx
    mov esi, ALS_OFF
    call agent_state_set
    xor r14d, r14d              # the prompts move to the copy
3:  cmp r14, [rbx + AL_queue + VEC_len]
    jae 4f
    mov rax, [rbx + AL_queue + VEC_ptr]
    mov rax, [rax + r14*8]
    mov [rsp + 40], rax
    lea rdi, [r13 + AL_queue]
    mov esi, 8
    call vec_push
    mov rcx, [rsp + 40]
    mov [rax], rcx
    inc r14
    jmp 3b
4:  mov qword ptr [rbx + AL_queue + VEC_len], 0
    mov rdi, r13                # (drawn queued there until it is ready; a start that fails puts them in
    call agent_start            #   its box: ev_failed)
9:  EPILOGUE
8:  mov rdi, rbx                # no copy: as Cancel
    call start_abandon
    mov rdi, rbx
    mov esi, ALS_OFF
    call agent_state_set
    lea rdi, [rip + .Lcopy_failed]
    call app_toast
    EPILOGUE

# cap_full() -> eax 1 when no other program may start (agent_conn_count at g_conn_max or CN_MAX)
cap_full:
    push rbx
    call agent_conn_count
    mov ecx, [rip + g_conn_max]
    cmp ecx, CN_MAX
    jbe 1f
    mov ecx, CN_MAX
1:  xor edx, edx
    cmp eax, ecx
    setae dl
    mov eax, edx
    pop rbx
    ret

# cap_room(AL*) -> eax 1 when a program will end and free a place: one is ending already, or the idle one
#   used longest ago (READY, no card, nothing queued; not this one) is released now; 0 when none is idle
cap_room:
    PROLOGUE
    mov r15, rdi
    xor r13d, r13d              # the idle one used longest ago
    xor ebx, ebx
1:  cmp rbx, [rip + lives + VEC_len]
    jae 4f
    mov rax, [rip + lives + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    cmp r12, r15
    je 1b
    cmp dword ptr [r12 + AL_cn + CN_state], CN_STOPPING
    je 8f                       # its place comes free soon
    mov rdi, r12
    call is_idle
    test eax, eax
    jz 1b
    test r13, r13
    jz 2f
    mov rax, [r12 + AL_used]
    cmp rax, [r13 + AL_used]
    jae 1b
2:  mov r13, r12
    jmp 1b
4:  xor eax, eax
    test r13, r13
    jz 9f
    mov rdi, r13
    call release
8:  mov eax, 1
9:  EPILOGUE

# is_idle(AL*) -> eax 1 when its program runs with nothing to do: READY, no request, no prompt waiting,
#   none held, no turn whose end has not come, no unfinished task that holds it (agtask_busy)
is_idle:
    push rdi
    call idle_base
    pop rdi
    test eax, eax
    jz 1f
    push rdi                    # task 11: an unfinished task (a background agent outlives its turn) holds
    mov rdi, [rdi + AL_as]      #   it, for TASK_HOLD_MS after its last record at most (agtask_busy)
    call agtask_busy
    pop rdi
    test rax, rax
    setz al
    movzx eax, al
1:  ret

# idle_base(AL*) -> eax 1 when it is idle but for its tasks
idle_base:
    xor eax, eax
    cmp dword ptr [rdi + AL_state], ALS_READY
    jne 1f
    cmp dword ptr [rdi + AL_cn + CN_state], CN_UP
    jne 1f
    cmp qword ptr [rdi + AL_reqs + VEC_len], 0
    jne 1f
    cmp qword ptr [rdi + AL_queue + VEC_len], 0
    jne 1f
    cmp qword ptr [rdi + AL_held + VEC_len], 0
    jne 1f
    cmp qword ptr [rdi + AL_turns], 0
    jne 1f
    call agside_busy            # p7c: no side question waits for it (agentside.s; a leaf: eax, rcx, rdx)
    xor eax, 1
1:  ret

# release(AL*): rhun ends its program politely (the stop sequence); the end is no failure (ALF_ENDING)
release:
    cmp dword ptr [rdi + AL_cn + CN_state], CN_UP
    jne 1f
    or dword ptr [rdi + AL_flags], ALF_ENDING
    mov rax, [rdi + AL_drv]
    jmp [rax + DRV_release]
1:  ret

# FN agent_stop(AS*): Stop: the turn is interrupted
FN agent_stop
    PROLOGUE
    mov rbx, rdi
    call agent_drv_of
    test rax, rax
    jz 9f
    test dword ptr [rax + DRV_caps], DRVC_SESSION
    jz 1f
    mov rdi, rbx
    call [rax + DRV_stop]
    jmp 9f
1:  mov r12, [rbx + AS_live]
    test r12, r12
    jz 9f
    cmp dword ptr [r12 + AL_state], ALS_STARTING
    je 3f
    cmp dword ptr [r12 + AL_state], ALS_WORKING
    je 2f
    cmp dword ptr [r12 + AL_state], ALS_WAITING
    jne 9f
2:  mov rdi, r12
    mov rax, [r12 + AL_drv]
    call [rax + DRV_stop]
    jmp 9f
3:  mov rdi, r12                # a start under way: given up
    call start_cancel
9:  EPILOGUE

# start_cancel(AL*): Stop while a start is under way (STARTING: waiting for the login environment, the
#   sign-in state, another holder to let go, a place under the cap, or the handshake): no start follows.
#   The prompts that waited go back in the box (their rows go), a program already started ends with the
#   stop sequence (an end rhun asked for: no error row), the state is OFF; the next Send starts anew
start_cancel:
    PROLOGUE
    mov rbx, rdi
    and dword ptr [rbx + AL_flags], ~(ALF_ENVWAIT | ALF_CAPWAIT | ALF_HOLDWAIT | ALF_AUTHWAIT | ALF_HOLDOK | ALF_RESTART)
    mov rdi, rbx
    call start_abandon
    mov rdi, rbx
    call release                # when it runs: ALF_ENDING, the input ends (ev_ready ignores its answer)
    mov rdi, rbx
    mov esi, ALS_OFF
    call agent_state_set
    EPILOGUE

# FN agent_stop_running(AS*) -> eax 1 when a turn of a session rhun drives runs or is about to (STARTING,
#   WORKING, WAITING): Stop went (Escape's meaning then; a second Stop in the same turn does nothing), 0
#   otherwise
FN agent_stop_running
    xor eax, eax
    test rdi, rdi
    jz 1f
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 1f
    cmp dword ptr [rcx + AL_state], ALS_STARTING
    je 2f
    cmp dword ptr [rcx + AL_state], ALS_WORKING
    je 2f
    cmp dword ptr [rcx + AL_state], ALS_WAITING
    jne 1f
2:  push rbx
    call agent_stop
    pop rbx
    mov eax, 1
1:  ret

# FN agent_answer(AS*, n): option n (from 0) of the session's card, as its driver answers it
FN agent_answer
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call agent_drv_of
    test rax, rax
    jz 9f
    test dword ptr [rax + DRV_caps], DRVC_SESSION
    jz 1f
    mov rdi, rbx
    xor esi, esi
    mov rdx, r12
    call [rax + DRV_answer]
    jmp 9f
1:  mov r13, [rbx + AS_live]
    test r13, r13
    jz 9f
    mov rdi, rbx
    call agentext_card_token
    test rax, rax
    jz 9f
    mov r14, rax
    call time_ms
    mov [r13 + AL_used], rax
    cmp r14, [r13 + AL_own]
    jne 2f
    mov rdi, r13                # rhun's own card: rhun answers it
    mov esi, [r14 + AQ_kind]
    mov rdx, r12
    call own_answer
    jmp 9f
2:  mov rdi, rbx                # the card goes; the driver shows the next one
    call agentext_card_drop
    mov rdi, r13
    mov rsi, r14
    mov rdx, r12
    mov rax, [r13 + AL_drv]
    call [rax + DRV_answer]
9:  EPILOGUE

# FN agent_typing(AS*): the user typed in the session's box: its program starts when it is not running
FN agent_typing
    PROLOGUE
    mov rbx, rdi
    call agent_live
    test rax, rax
    jz 9f
    mov r12, rax
    call time_ms
    mov [r12 + AL_used], rax
    cmp dword ptr [r12 + AL_state], ALS_OFF
    jne 9f
    mov rdi, r12
    call agent_start
9:  EPILOGUE

# FN agent_run(AS*): a local command needs its program (a driver's action): it starts when it is off or
#   failed, as a Send would start it; otherwise nothing changes
FN agent_run
    PROLOGUE
    call agent_live
    test rax, rax
    jz 9f
    mov r12, rax
    call time_ms
    mov [r12 + AL_used], rax
    mov eax, [r12 + AL_state]
    cmp eax, ALS_OFF
    je 1f
    cmp eax, ALS_FAILED
    jne 9f
1:  mov rdi, r12
    call agent_start
9:  EPILOGUE

# FN agent_release(AS*): its program ends politely (the stop sequence); the record stays
FN agent_release
    mov rdi, [rdi + AS_live]
    test rdi, rdi
    jnz release
    ret

# FN agent_touch(AS*): the user typed in its box: the idle stop waits again
FN agent_touch
    PROLOGUE
    mov rbx, [rdi + AS_live]
    test rbx, rbx
    jz 9f
    call time_ms
    mov [rbx + AL_used], rax
9:  EPILOGUE

# FN agent_new(kind) -> rax AS* or 0: a new conversation of a built-in driver (the draft's first character
#   or its Send): a v4 UUID is its id, an AS of that kind whose path is the transcript Claude Code will
#   write for that id in the project's folder (AS_cwd), titled "New conversation", adopted and opened
#   (agentext.s keeps the box's text: keep_box); its live record is new (ALF_NEW) with the id in AL_sid.
#   0 when the driver is not available, or the window has no project. Locals: [rsp] the id (40 bytes)
FN agent_new
    PROLOGUE 48
    mov ebx, edi
    call agent_drv_for_kind
    test rax, rax
    jz 8f
    test dword ptr [rax + DRV_caps], DRVC_NEW
    jz 8f
    cmp ebx, AG_CLAUDE          # the one built-in driver that starts conversations: its file's place
    jne 8f
    mov r12, [rip + g_project]
    test r12, r12
    jz 8f
    lea rdi, [rsp]
    call agent_uuid
    mov edi, ebx
    mov rsi, r12
    lea rdx, [rip + .Lnew_title]
    lea rcx, [rsp]
    call new_as
    test rax, rax
    jz 8f
    mov r13, rax
    mov rdi, r13
    call agents_adopt
    mov rdi, r13
    call agents_open_as
    mov rdi, r13
    call agent_live
    test rax, rax
    jz 9f
    or dword ptr [rax + AL_flags], ALF_NEW | ALF_DRAFT
    lea rdi, [rax + AL_sid]
    lea rsi, [rsp]
    call cstr_copy
9:  mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# new_as(kind, cwd, title cstr, id cstr) -> rax a new AS of that kind, or 0: its path is the transcript
#   Claude Code writes for that id in cwd's folder, AS_cwd is cwd, now its time (not yet adopted)
new_as:
    PROLOGUE 16
    mov ebx, edi
    mov r12, rsi
    mov r14, rdx
    mov [rsp], rcx
    lea rdi, [rip + jsb]
    call sb_clear
    lea rdi, [rip + jsb]
    mov rsi, r12
    mov rdx, [rsp]
    call claude_transcript
    test eax, eax
    jz 8f
    mov edi, AS_SIZE
    call mem_alloc
    mov r13, rax
    mov [r13 + AS_kind], ebx
    mov rdi, [rip + jsb + SB_ptr]
    mov rsi, [rip + jsb + SB_len]
    call mem_dup
    mov [r13 + AS_path], rax
    mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    call mem_dup
    mov [r13 + AS_title], rax
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [r13 + AS_cwd], rax
    call time_now
    mov [r13 + AS_mtime], rax
    imul rax, rax, 1000000000
    mov [r13 + AS_recency], rax
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agent_uuid(buf): a random version 4 UUID, 36 characters and a NUL. The bytes come from /dev/urandom;
#   where that cannot be read (Windows) from the clock, the pid and a counter
FN agent_uuid
    PROLOGUE 16
    mov rbx, rdi
    lea rdi, [rip + .Lurandom]
    call file_open_read
    test rax, rax
    js 2f
    mov r12d, eax
    mov edi, eax
    lea rsi, [rsp]
    mov edx, 16
    SYS SYS_read
    mov r13, rax
    mov edi, r12d
    SYS SYS_close
    cmp r13, 16
    je 3f
2:  call time_us                # splitmix64 of the clock, the pid and a counter
    mov r12, rax
    SYS SYS_getpid
    shl rax, 32
    xor r12, rax
    inc qword ptr [rip + uuid_n]
    mov rax, [rip + uuid_n]
    mov rcx, 0x9e3779b97f4a7c15
    imul rax, rcx
    add r12, rax
    mov rdi, r12
    call mix64
    mov [rsp], rax
    lea rdi, [r12 + 1]
    call mix64
    mov [rsp + 8], rax
3:  and byte ptr [rsp + 6], 0x0f
    or byte ptr [rsp + 6], 0x40         # version 4
    and byte ptr [rsp + 8], 0x3f
    or byte ptr [rsp + 8], 0x80         # variant 10
    xor r12d, r12d                      # the byte
    xor r13d, r13d                      # where its two digits go
4:  cmp r12d, 16
    jae 6f
    cmp r12d, 4
    je 5f
    cmp r12d, 6
    je 5f
    cmp r12d, 8
    je 5f
    cmp r12d, 10
    jne 51f
5:  mov byte ptr [rbx + r13], '-'
    inc r13
51: movzx eax, byte ptr [rsp + r12]
    lea rcx, [rip + .Lhex]
    mov edx, eax
    shr edx, 4
    movzx edx, byte ptr [rcx + rdx]
    mov [rbx + r13], dl
    and eax, 15
    movzx eax, byte ptr [rcx + rax]
    mov [rbx + r13 + 1], al
    add r13, 2
    inc r12d
    jmp 4b
6:  mov byte ptr [rbx + r13], 0
    EPILOGUE

# mix64(x) -> rax splitmix64's finalizer of x
mix64:
    mov rax, rdi
    mov rcx, 0x9e3779b97f4a7c15
    add rax, rcx
    mov rcx, rax
    shr rcx, 30
    xor rax, rcx
    mov rcx, 0xbf58476d1ce4e5b9
    imul rax, rcx
    mov rcx, rax
    shr rcx, 27
    xor rax, rcx
    mov rcx, 0x94d049bb133111eb
    imul rax, rcx
    mov rcx, rax
    shr rcx, 31
    xor rax, rcx
    ret

# ---- events ----

# FN ev_note(al, role, ptr, len): a row of the agent's (R_INFO, R_ERROR)
FN ev_note
    mov rdi, [rdi + AL_as]
    xor r8d, r8d
    jmp agents_msg_add

# FN ev_ready(al): the handshake is done: the prompts that waited go, the oldest first, each with a uuid.
#   The first is a row at once (nothing runs yet); with a driver that takes messages during a turn
#   (DRVC_QUEUE) the others are held, drawn queued until each starts (ev_started), else each is a row as it
#   goes. They go WORKING: a connection that breaks under a write is a turn that failed, and its close (the
#   driver's: ev_failed, ev_closed) has put the prompts back in the box and freed them before the write
#   returns. One the driver refuses goes back in the box, with no row. Locals: [rsp] the uuid (40 bytes),
#   [rsp + 40] held or not, [rsp + 48] the block's tail (q_tail)
FN ev_ready
    PROLOGUE 64
    mov rbx, rdi
    test dword ptr [rbx + AL_flags], ALF_ENDING
    jnz 9f                      # a start given up (start_cancel): it is ending, nothing goes
    mov rdi, rbx                # a dialog that waited for the process asks it now (agentdlg.s)
    call agentdlg_ready
    mov rdi, rbx                # p7c: side questions that waited for it go (agentside.s)
    call agside_ready
    mov esi, ALS_READY
    cmp qword ptr [rbx + AL_queue + VEC_len], 0
    je 1f
    mov esi, ALS_WORKING
1:  mov rdi, rbx
    call agent_state_set
    xor r12d, r12d
    xor r13d, r13d              # one went
2:  cmp r12, [rbx + AL_queue + VEC_len]
    jae 3f
    mov rax, [rbx + AL_queue + VEC_ptr]
    mov r14, [rax + r12*8]
    test r14, r14
    jz 25f
    mov rdi, r14
    call strlen
    mov r15, rax
    lea rdi, [rsp]
    call agent_uuid
    mov dword ptr [rsp + 40], 0 # the first that goes, or each when they cannot be held: a row once
    test r13d, r13d             #   written; the others held
    jz 23f
    mov rax, [rbx + AL_drv]
    test dword ptr [rax + DRV_caps], DRVC_QUEUE
    jz 23f
    mov dword ptr [rsp + 40], 1
23: mov rdi, r14                # phase 4 task 2: its pack goes with it
    call q_tail
    mov r8, [rax + 8]
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    lea rcx, [rsp]
    mov rax, [rbx + AL_drv]
    call [rax + DRV_send]
    cmp dword ptr [rbx + AL_state], ALS_WORKING
    jne 9f                      # it broke: the queue is gone (ev_failed), the state set
    test eax, eax
    jz 25f                      # refused: it stays in the queue, back in the box below (no row)
    mov rdi, r14
    call q_tail
    mov [rsp + 48], rax
    cmp dword ptr [rsp + 40], 0
    je 22f
    mov rdi, rbx
    lea rsi, [rsp]
    mov rdx, r14
    mov rcx, r15
    mov r8, [rax + 8]           # (held: the entry's now)
    call held_add
    jmp 24f
22: mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call prompt_row
    mov rdi, [rbx + AL_as]      # phase 4 task 2: its chips; the pack, written, goes
    mov rsi, rax
    mov rax, [rsp + 48]
    mov rdx, [rax + 8]
    call pack_row
24: mov r13d, 1
    mov rax, [rsp + 48]
    mov qword ptr [rax + 8], 0
    mov rax, [rbx + AL_queue + VEC_ptr]
    mov qword ptr [rax + r12*8], 0
    mov rdi, r14
    call q_free
25: inc r12
    jmp 2b
3:  mov rdi, rbx                # what was refused goes back in the box
    mov esi, RS_QUEUE
    call queue_restore
    mov rdi, rbx
    call queue_free
    test r13d, r13d
    jnz 4f
    cmp dword ptr [rbx + AL_state], ALS_WORKING
    jne 9f
    mov rdi, rbx                # every one refused: nothing runs
    mov esi, ALS_READY
    call agent_state_set
    jmp 9f
4:  call time_ms
    mov [rbx + AL_used], rax
9:  EPILOGUE

# FN ev_started(al, uuid ptr, len): a held message started: it leaves AL_held and is the user's row now.
#   A uuid not held (a message shown as a row at once, one started already) is nothing
FN ev_started
    PROLOGUE
    mov rbx, rdi
    call held_find
    test rax, rax
    js 9f
    mov rdi, rbx
    mov rsi, rax
    call held_take
    mov r12, rax
    mov r13, rdx
    mov r14, rcx                # phase 4 task 2: its chips text and its (slimmed) pack
    mov r15, r8
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call prompt_row
    mov rdi, [rbx + AL_as]      # its row gets its chips; the pack is done with
    mov rsi, rax
    mov rdx, r14
    call agatt_row_chips
    mov rdi, r14
    call mem_free
    mov rdi, r15
    call agatt_free
    mov rdi, r12
    call mem_free
9:  EPILOGUE

# FN ev_dropped(al, uuid ptr, len): a held message will not run (the program cancelled, discarded or refused
#   it): it goes back to its own conversation (its box, or AL_unsent when the box is another's) with a
#   toast; no result comes for it, so the last turn's end may have come already (READY). A uuid not held is
#   nothing
FN ev_dropped
    PROLOGUE
    mov rbx, rdi
    call held_find
    test rax, rax
    js 9f
    mov rdi, rbx
    mov rsi, rax
    call held_take
    mov r12, rax
    mov r13, rdx
    mov r14, r8                 # phase 4 task 2: its parts go back with its text
    mov rdi, rcx
    call mem_free
    mov rdi, [rbx + AL_as]
    mov rsi, r14
    call agatt_return
    lea rdi, [rip + jsb]
    call sb_clear
    lea rdi, [rip + jsb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, r12
    call mem_free
    mov rdi, rbx
    call jsb_keep
    lea rdi, [rip + .Lheld_back]
    call app_toast
    cmp qword ptr [rbx + AL_turns], 0
    je 1f
    dec qword ptr [rbx + AL_turns]
    jnz 9f
1:  mov rdi, rbx                # every message written has ended now: as at a turn's end
    call turns_over
9:  EPILOGUE

# FN ev_text(al, key ptr, key len, ptr, len, replace) -> rax the row's index (-1 none): reply text of a
#   content block, under its item key: a new row (empty while it streams), more text for the row of that
#   key, or (replace) its finished text in place of what streamed. A finished row takes no more text: the
#   next text under the same key (a stream without partial messages) is a row of its own
FN ev_text
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp], r9
    cmp qword ptr [rbx + AL_row], 0
    jl 3f
    cmp byte ptr [rbx + AL_rowkey], 0
    je 3f
    lea rdi, [rbx + AL_rowkey]
    call strlen
    cmp rax, r13
    jne 3f
    lea rdi, [rbx + AL_rowkey]
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jz 3f
    mov rdi, [rbx + AL_as]      # the row of that key
    mov rsi, [rbx + AL_row]
    mov rdx, r14
    mov rcx, r15
    cmp qword ptr [rsp], 0
    jne 2f
    call agents_msg_append
    mov rax, [rbx + AL_row]
    EPILOGUE
2:  call agents_msg_set
    mov rax, [rbx + AL_row]
    mov qword ptr [rbx + AL_row], -1
    mov byte ptr [rbx + AL_rowkey], 0
    EPILOGUE
3:  mov rdi, [rbx + AL_as]      # a row of its own
    mov esi, R_ASSIST
    mov rdx, r14
    mov rcx, r15
    xor r8d, r8d
    call agents_msg_add
    mov [rbx + AL_row], rax
    mov byte ptr [rbx + AL_rowkey], 0
    test rax, rax
    js 8f
    cmp qword ptr [rsp], 0
    jne 8f                      # finished already
    cmp r13, ROWKEY_MAX
    jae 9f
    lea rdi, [rbx + AL_rowkey]
    mov rsi, r12
    mov rdx, r13
    mov byte ptr [rdi + rdx], 0
    call memmove
    mov rax, [rbx + AL_row]
    EPILOGUE
8:  mov qword ptr [rbx + AL_row], -1
9:  EPILOGUE

# FN ev_thought(al, key ptr, key len, ptr, len, replace) -> rax the row's index (-1 none): thinking of a
#   content block under its item key, as ev_text: a new thinking row (R_THINK; live while it streams; it may
#   have no text at all: the default display sends none), more text for the row of that key (an empty piece
#   changes nothing: no row is measured again), or (replace) its finished text in place of what streamed. A
#   finished text without a row of its key is a row of its own. ev_thought_end finishes the row
FN ev_thought
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp], r9
    mov rdi, rbx
    call thought_row
    test rax, rax
    js 3f
    mov [rsp + 8], rax
    cmp qword ptr [rsp], 0
    jne 2f
    test r15, r15
    jz 1f
    mov rdi, [rbx + AL_as]      # more text
    mov rsi, rax
    mov rdx, r14
    mov rcx, r15
    call agents_msg_append
1:  mov rax, [rsp + 8]
    EPILOGUE
2:  mov rdi, [rbx + AL_as]      # the finished text
    mov rsi, rax
    mov rdx, r14
    mov rcx, r15
    call agents_msg_set
    mov rax, [rsp + 8]
    EPILOGUE
3:  mov rdi, rbx                # a row of its own
    call ev_thought_cut
    mov rdi, [rbx + AL_as]
    mov esi, R_THINK
    mov rdx, r14
    mov rcx, r15
    xor r8d, r8d
    call agents_msg_add
    mov [rsp + 8], rax
    test rax, rax
    js 9f
    cmp qword ptr [rsp], 0
    jne 8f                      # finished already
    mov rdi, [rbx + AL_as]
    mov rsi, rax
    mov edx, AMF_LIVE
    call agents_row_flag
    mov rax, [rsp + 8]
    mov [rbx + AL_row], rax
    mov byte ptr [rbx + AL_rowkey], 0
    cmp r13, ROWKEY_MAX
    jae 8f
    lea rdi, [rbx + AL_rowkey]
    mov rsi, r12
    mov rdx, r13
    mov byte ptr [rdi + rdx], 0
    call memmove
8:  mov rax, [rsp + 8]
9:  EPILOGUE

# thought_row(al, key ptr, key len) -> rax the thinking row that streams under that key (AL_row), -1
thought_row:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rax, -1
    mov r14, [rbx + AL_row]
    test r14, r14
    js 9f
    cmp byte ptr [rbx + AL_rowkey], 0
    je 9f
    mov rdi, [rbx + AL_as]
    cmp r14, [rdi + AS_msgs + VEC_len]
    jae 9f
    imul rcx, r14, AM_SIZE
    add rcx, [rdi + AS_msgs + VEC_ptr]
    cmp dword ptr [rcx + AM_role], R_THINK
    jne 9f
    lea rdi, [rbx + AL_rowkey]
    call strlen
    mov rcx, rax
    mov rax, -1
    cmp rcx, r13
    jne 9f
    lea rdi, [rbx + AL_rowkey]
    mov rsi, r12
    mov rdx, r13
    call memeq
    mov rcx, rax
    mov rax, -1
    test ecx, ecx
    jz 9f
    mov rax, r14
9:  EPILOGUE

# FN ev_thought_end(al, row, ms, tokens): a thinking row is finished: how long it took (-1 unknown) and the
#   tokens it took (-1: as estimated); it streams no more and its fold is told
FN ev_thought_end
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov rdi, [rbx + AL_as]
    test r12, r12
    js 9f
    cmp r12, [rdi + AS_msgs + VEC_len]
    jae 9f
    imul rax, r12, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    cmp dword ptr [rax + AM_role], R_THINK
    jne 9f
    mov [rax + AM_ms], r13d
    test r14d, r14d
    js 1f
    mov [rax + AM_n], r14d
1:  and dword ptr [rax + AM_flags], ~AMF_LIVE
    cmp [rbx + AL_row], r12
    jne 2f
    mov qword ptr [rbx + AL_row], -1
    mov byte ptr [rbx + AL_rowkey], 0
2:  mov rdi, [rbx + AL_as]
    mov rsi, r12
    call agents_msg_changed
    mov rdi, [rbx + AL_as]
    mov rsi, r12
    mov edx, ATS_RUNNING
    mov ecx, ATS_OK
    call agfold_state
9:  EPILOGUE

# FN ev_thought_tokens(al, n): the estimate of the thinking that streams now (its label's "N tokens"): drawn
#   again, nothing measured again
FN ev_thought_tokens
    mov rax, [rdi + AL_row]
    test rax, rax
    js 9f
    mov rcx, [rdi + AL_as]
    cmp rax, [rcx + AS_msgs + VEC_len]
    jae 9f
    imul rax, rax, AM_SIZE
    add rax, [rcx + AS_msgs + VEC_ptr]
    cmp dword ptr [rax + AM_role], R_THINK
    jne 9f
    test dword ptr [rax + AM_flags], AMF_LIVE
    jz 9f
    mov [rax + AM_n], esi
    mov dword ptr [rip + g_dirty], 1
9:  ret

# FN ev_thought_cut(al): the thinking row that streams (a turn ended, another block began without its record)
#   is streaming no more: "Thinking", or its time if it had one
FN ev_thought_cut
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AL_row]
    test r12, r12
    js 9f
    mov rdi, [rbx + AL_as]
    cmp r12, [rdi + AS_msgs + VEC_len]
    jae 9f
    imul rax, r12, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    cmp dword ptr [rax + AM_role], R_THINK
    jne 9f
    test dword ptr [rax + AM_flags], AMF_LIVE
    jz 9f
    and dword ptr [rax + AM_flags], ~AMF_LIVE
    mov qword ptr [rbx + AL_row], -1
    mov byte ptr [rbx + AL_rowkey], 0
    mov rsi, r12
    call agents_msg_changed
9:  EPILOGUE

# FN ev_request(al, AQ*, prompt ptr, len, opts cstr*, n) -> eax 1 shown: the request's card on the
#   session (the one at the head of AL_reqs); the state is WAITING
FN ev_request
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + AL_as]
    call agentext_card
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov esi, ALS_WAITING
    call agent_state_set
    mov eax, 1
9:  EPILOGUE

# FN ev_card(al, AQ*, CD*) -> eax 1 shown: the request's rich card on the session (agentcard.s; it is the
#   one at the head of AL_reqs): AQ_card set, its lock and focus rule the first time it shows (agentcard_shown);
#   the state is WAITING
FN ev_card
    PROLOGUE
    mov rbx, rdi
    mov [rsi + AQ_card], rdx
    mov [rdx + CD_token], rsi
    mov rdi, [rbx + AL_as]
    mov rsi, rdx
    call agentcard_shown
    mov rdi, rbx
    mov esi, ALS_WAITING
    call agent_state_set
    mov eax, 1
    EPILOGUE

# FN ev_offer(al, AQ*, path cstr, old ptr, oldlen, new ptr, [rsp] newlen, [rsp + 8] flags OFF_*) -> eax 1:
#   the driver offers the change its request (the head, whose card shows) would make to one file: the file's
#   text before and after, shown in the Review tab tied to the card (agentoffer.s; the texts are copied).
#   Phase 4 task 11
FN ev_offer
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rcx
    mov [rsp + 8], r8
    mov [rsp + 16], r9
    mov rax, [rbp + 16]
    mov [rsp + 24], rax
    mov rdi, [rbx + AL_as]
    lea rcx, [rsp]              # OT: old, oldlen, new, newlen
    mov r8d, [rbp + 24]
    call agoffer_open
    EPILOGUE

# FN ev_request_gone(al, AQ*): answered or withdrawn: its card goes (when it shows), it leaves AL_reqs
#   (the others keep their order) and is freed. One that is not in AL_reqs is not touched: a write's close
#   (ev_closed) may have freed it already
FN ev_request_gone
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + AL_as]
    call agentext_card_token
    cmp rax, r12
    jne 1f
    mov rdi, [rbx + AL_as]
    call agentext_card_drop
1:  xor ecx, ecx
2:  cmp rcx, [rbx + AL_reqs + VEC_len]
    jae 5f
    mov rax, [rbx + AL_reqs + VEC_ptr]
    cmp [rax + rcx*8], r12
    je 3f
    inc rcx
    jmp 2b
3:  mov rdx, [rbx + AL_reqs + VEC_len]
    dec rdx
    mov [rbx + AL_reqs + VEC_len], rdx
4:  cmp rcx, rdx
    jae 6f
    mov r8, [rax + rcx*8 + 8]
    mov [rax + rcx*8], r8
    inc rcx
    jmp 4b
6:  mov rdi, r12
    call aq_free
5:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# reqs_drop(AL*) -> eax how many requests waited: they go unanswered, with the card
reqs_drop:
    PROLOGUE
    mov rbx, rdi
    mov r13, [rbx + AL_reqs + VEC_len]
    test r13, r13
    jz 9f
    mov rdi, [rbx + AL_as]
    call agentext_card_token
    test rax, rax
    jz 1f
    mov rdi, [rbx + AL_as]
    call agentext_card_drop
1:  xor r12d, r12d
2:  cmp r12, r13
    jae 3f
    mov rax, [rbx + AL_reqs + VEC_ptr]
    mov rdi, [rax + r12*8]
    call aq_free
    inc r12
    jmp 2b
3:  mov qword ptr [rbx + AL_reqs + VEC_len], 0
9:  mov eax, r13d
    EPILOGUE

# FN ev_mode(al, ptr, len): the permission mode in effect (the footer's mode button): the agent reports it,
#   or the user picked it. A change from a mode in effect before is the conversation's to keep
#   (agent_mode_keep); the mode a process starts in is what its start chose, not kept for it
FN ev_mode
    PROLOGUE 48
    mov rbx, rdi
    cmp rdx, 31
    jbe 1f
    mov edx, 31
1:  mov r12, rsi
    mov r13, rdx
    lea rdi, [rsp]              # the mode before
    lea rsi, [rbx + AL_mode]
    call cstr_copy
    lea rdi, [rbx + AL_mode]
    mov rsi, r12
    mov rdx, r13
    mov byte ptr [rdi + rdx], 0
    call memmove
    mov dword ptr [rip + g_dirty], 1
    cmp byte ptr [rsp], 0
    je 9f
    lea rdi, [rsp]
    lea rsi, [rbx + AL_mode]
    call strcmp_eq
    test eax, eax
    jnz 9f
    mov rdi, rbx
    call agent_mode_keep
9:  EPILOGUE

# FN agent_mode_keep(al): the mode in effect is the conversation's, passed at its next start (its driver's
#   record, agentcfg.s: saved when it changed). None known (a pick refused or kept out by the gate where the
#   program reported none): the conversation keeps none, rather than the mode that did not hold
FN agent_mode_keep
    PROLOGUE
    mov rbx, rdi
    cmp byte ptr [rbx + AL_sid], 0
    je 9f
    cmp byte ptr [rbx + AL_mode], 0
    jne 1f
    mov rdi, rbx
    call live_cfg
    mov r12, rax
    mov rdi, rax
    call agentcfg_need
    mov rdi, r12
    lea rsi, [rbx + AL_sid]
    call agentcfg_conv_mode
    test rax, rax
    jz 9f
    mov byte ptr [rax], 0
    jmp 7f
1:  mov rdi, rbx
    call live_cfg
    mov r12, rax
    mov rdi, rax
    lea rsi, [rbx + AL_sid]
    call agentcfg_conv
    lea r13, [rax + ACH_mode]
    mov rdi, r13
    lea rsi, [rbx + AL_mode]
    call strcmp_eq
    test eax, eax
    jnz 8f
    mov rdi, r13
    lea rsi, [rbx + AL_mode]
    call cstr_copy
7:  mov rdi, r12
    call agentcfg_dirty
8:  mov rdi, r12                # (a conversation new to the record is a change too)
    call agentcfg_save
9:  EPILOGUE

# FN ev_config(al): the driver's lists changed (agentcfg.s): its record is saved
FN ev_config
    PROLOGUE
    call live_cfg
    mov rdi, rax
    call agentcfg_save
    call agentpop_changed       # an open popup's rows are made again
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# live_cfg(al) -> rax the record of its driver's kind (agentcfg_get)
live_cfg:
    mov rax, [rdi + AL_drv]
    mov edi, [rax + DRV_kind]
    jmp agentcfg_get

# FN ev_model(al, ptr, len): the model in effect (AL_model)
FN ev_model
    lea rdi, [rdi + AL_model]
    mov ecx, 64
    jmp live_text

# FN ev_effort(al, ptr, len): the effort level in effect (AL_effort)
FN ev_effort
    lea rdi, [rdi + AL_effort]
    mov ecx, 16
    jmp live_text

# live_text(dst, ptr, len, cap): ptr/len into a cstr field of cap bytes, cut at a character; a redraw
live_text:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r12, r12
    jnz 1f
    xor r13d, r13d
1:  lea rdx, [rcx - 1]
    mov rdi, r13
    mov rsi, r12
    call utf8_cut
    mov r13, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call memmove
    mov byte ptr [rbx + r13], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN ev_ultra(al, available, on): Ultracode offered or not, and whether it is on (AL_ultra)
FN ev_ultra
    mov eax, -1
    test esi, esi
    jz 1f
    xor eax, eax
    test edx, edx
    setnz al
1:  mov [rdi + AL_ultra], eax
    mov dword ptr [rip + g_dirty], 1
    ret

# FN ev_thinking(al, on): thinking on or off (AL_think)
FN ev_thinking
    xor eax, eax
    test esi, esi
    setnz al
    mov [rdi + AL_think], eax
    mov dword ptr [rip + g_dirty], 1
    ret

# FN ev_fast(al, state FS_*, reason ptr, len): fast mode's state (AL_fast); the project's record keeps it
#   and the reason it is off, for the menu before a program runs
FN ev_fast
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, FS_COOLDOWN
    jbe 1f
    xor r12d, r12d
1:  mov [rbx + AL_fast], r12d
    mov rdi, rbx
    call live_cfg
    mov r15, rax
    mov rdi, rax
    mov esi, AGF_FAST
    mov edx, r12d
    call agentcfg_set
    mov rdi, r15
    mov esi, AGF_FASTWHY
    mov rdx, r13
    mov rcx, r14
    call agentcfg_set
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN ev_spin(al, cstr or 0, static): the spinner's words in place of a verb while the driver says so
#   ("Compacting", a start-up hook's); static 1: shown at once, no typewriter; 0 gives the verbs back
FN ev_spin
    mov rdi, [rdi + AL_as]
    jmp agspin_set

# FN ev_pill(al, ptr, len): a one-line pill in the conversation ("Switched to NAME"): centred, muted, in a
#   rounded frame (agents_pill)
FN ev_pill
    mov rdi, [rdi + AL_as]
    jmp agents_pill

# FN ev_band(al, kind BK_*, ptr, len): the band of that kind above the box shows the text (ptr 0: it goes);
#   the text a band the user dismissed had (AL_bandoff, agentfoot.s) keeps it away, another shows it
FN ev_band
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, BK_COUNT
    jae 9f
    mov r15, [rbx + AL_bands + r12*8]
    test r13, r13               # the same text again: a band the user dismissed stays away
    jz 2f
    test r15, r15
    jz 2f
    mov rdi, r15
    call strlen
    cmp rax, r14
    jne 2f
    mov rdi, r15
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jnz 9f
2:  mov rdi, r15
    call mem_free
    mov rdi, [rbx + AL_blinks + r12*8]  # and its link goes with it (ev_band_link gives the new one's)
    call mem_free
    mov qword ptr [rbx + AL_blinks + r12*8], 0
    mov ecx, r12d               # a new text shows, even if the old one was dismissed
    mov eax, 1
    shl eax, cl
    not eax
    and [rbx + AL_bandoff], eax
    xor eax, eax
    test r13, r13
    jz 1f
    mov rdi, r13
    mov rsi, r14
    call mem_dup
1:  mov [rbx + AL_bands + r12*8], rax
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN ev_band_link(al, kind BK_*, label cstr, url cstr): the band of that kind (shown or dismissed) offers a
#   link under its text: the label, opening the URL once the user says so (links_ask_open); label 0: none.
#   A new text (ev_band) takes the link away
FN ev_band_link
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, BK_COUNT
    jae 9f
    mov rdi, [rbx + AL_blinks + r12*8]
    call mem_free
    mov qword ptr [rbx + AL_blinks + r12*8], 0
    test r13, r13
    jz 8f
    cmp qword ptr [rbx + AL_bands + r12*8], 0
    je 8f
    mov rdi, r13
    call strlen
    mov r15, rax
    mov rdi, r14
    call strlen
    lea rdi, [r15 + rax + 2]
    call mem_alloc
    test rax, rax
    jz 8f
    mov [rbx + AL_blinks + r12*8], rax
    mov rdi, rax
    mov rsi, r13
    call cstr_copy
    mov rdi, [rbx + AL_blinks + r12*8]
    lea rdi, [rdi + r15 + 1]
    mov rsi, r14
    call cstr_copy
8:  mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN ev_usage(al, AGU*): the conversation's context and prompt-cache numbers (the footer's pie and clock
#   draw from them; nothing else follows)
FN ev_usage
    PROLOGUE
    lea rdi, [rdi + AL_usage]
    mov edx, AGU_SIZE
    call memmove
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN ev_turn_end(al, reason, ptr, len): a turn ended: TE_DONE, TE_ERROR (the agent's text as an error row)
#   or TE_INTERRUPTED (an "Interrupted" row). READY once every prompt sent has had its end
FN ev_turn_end
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    call ev_thought_cut            # thinking still streaming (an interrupt cut it) streams no more
    cmp r12d, TE_ERROR
    jne 1f
    test r14, r14
    jnz 11f
    lea r13, [rip + .Lturn_failed]
    mov rdi, r13
    call strlen
    mov r14, rax
11: mov rdi, [rbx + AL_as]
    mov esi, R_ERROR
    mov rdx, r13
    mov rcx, r14
    xor r8d, r8d
    call agents_msg_add
    jmp 2f
1:  cmp r12d, TE_INTERRUPTED
    jne 2f
    mov rdi, [rbx + AL_as]      # the stream's interrupt mark made its row already ("Interrupted", "Tool
    call last_interrupt         #   interrupted": the reader, as the file's mark gives it)
    test eax, eax
    jnz 2f
    lea rdi, [rip + .Linterrupted]
    call strlen
    mov rdi, [rbx + AL_as]
    mov esi, R_INFO
    lea rdx, [rip + .Linterrupted]
    mov rcx, rax
    xor r8d, r8d
    call agents_msg_add
2:  mov rdi, [rbx + AL_as]      # the turn's calls still waiting for a result are stopped (agentrows.s)
    call agrow_stop
    and dword ptr [rbx + AL_flags], ~ALF_STOP_ASKED
    mov qword ptr [rbx + AL_row], -1
    mov byte ptr [rbx + AL_rowkey], 0
    call time_ms
    mov [rbx + AL_used], rax
    cmp qword ptr [rbx + AL_turns], 0
    je 3f
    dec qword ptr [rbx + AL_turns]
    jnz 9f
3:  mov rdi, rbx
    call turns_over
9:  EPILOGUE

# last_interrupt(AS*) -> eax 1 when the conversation's last row is an interrupt's ("Interrupted", "Tool
#   interrupted", an info row the reader made of the stream's mark during this turn)
last_interrupt:
    PROLOGUE
    xor r12d, r12d
    mov rcx, [rdi + AS_msgs + VEC_len]
    test rcx, rcx
    jz 9f
    dec rcx
    imul rbx, rcx, AM_SIZE
    add rbx, [rdi + AS_msgs + VEC_ptr]
    cmp dword ptr [rbx + AM_role], R_INFO
    jne 9f
    mov rdi, [rbx + AM_text]
    mov rsi, [rbx + AM_len]
    lea rdx, [rip + .Linterrupted]
    call str_eq_cstr
    mov r12d, eax
    test eax, eax
    jnz 9f
    mov rdi, [rbx + AM_text]
    mov rsi, [rbx + AM_len]
    lea rdx, [rip + .Ltool_interrupted]
    call str_eq_cstr
    mov r12d, eax
9:  mov eax, r12d
    EPILOGUE

# FN ev_turn_begin(al): a turn the agent began by itself (task 11: a background task ended and the CLI answers
#   it; no prompt of the user's is out): the conversation works until that turn's end (ev_turn_end), with
#   Stop and the spinner as for any turn; a prompt sent meanwhile is held as during any turn. Nothing when a
#   turn is out already
FN ev_turn_begin
    PROLOGUE
    mov rbx, rdi
    cmp qword ptr [rbx + AL_turns], 0
    jne 9f
    cmp dword ptr [rbx + AL_state], ALS_READY
    jne 9f
    mov qword ptr [rbx + AL_turns], 1
    mov rdi, rbx
    mov esi, ALS_WORKING
    call agent_state_set
    call time_ms
    mov [rbx + AL_used], rax
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# turns_over(al): every message written has had its end (the last turn's end, or a held one the program
#   dropped: ev_turn_end, ev_dropped): one still held ran without a word that it started (a command the
#   program answers itself, without lifecycle or replay) and its row joins now; requests the turns left
#   behind go with their card; READY
turns_over:
    PROLOGUE
    mov rbx, rdi
3:  cmp qword ptr [rbx + AL_held + VEC_len], 0
    je 32f
    mov r15, [rbx + AL_held + VEC_ptr]
    lea rdi, [r15 + AH_uuid]
    call strlen
    mov rdi, rbx
    lea rsi, [r15 + AH_uuid]
    mov rdx, rax
    call ev_started
    jmp 3b
32: and dword ptr [rbx + AL_flags], ~ALF_UNANSWERED
    mov rdi, rbx                # requests the turn left behind go with their card (Claude withdraws
    call reqs_drop              #   them first; a card nobody waits for must not stay), an info row
    test eax, eax               #   saying so (again after a re-read: ALF_UNANSWERED)
    jz 31f
    or dword ptr [rbx + AL_flags], ALF_UNANSWERED
    mov edi, eax
    call closed_note
31: mov eax, [rbx + AL_state]
    cmp eax, ALS_WORKING
    je 4f
    cmp eax, ALS_WAITING
    jne 9f
4:  mov rdi, rbx
    mov esi, ALS_READY
    call agent_state_set
9:  EPILOGUE

# FN agent_retry(AS*) -> eax 1 started: the error block's Retry: a conversation whose program failed and is
#   gone starts it again and sends nothing (its prompts were put back in the box)
FN agent_retry
    PROLOGUE
    xor eax, eax
    mov rbx, [rdi + AS_live]
    test rbx, rbx
    jz 9f
    cmp dword ptr [rbx + AL_state], ALS_FAILED
    jne 9f
    cmp dword ptr [rbx + AL_cn + CN_state], CN_UP
    je 8f                       # still ending: its close comes first
    mov rdi, rbx
    call agent_start
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN ev_closed(al, err): the agent's process is gone: the state is OFF unless it FAILED, the requests it
#   waited on go with their card, and the conversation is read again from its file, which is the truth (a
#   new conversation that has no file yet keeps the rows the stream fed); an info row for the unanswered
#   requests and a failure's error row follow the file's rows
FN ev_closed
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + AL_state], ALS_FAILED
    je 1f
    mov rdi, rbx
    mov esi, ALS_OFF
    call agent_state_set
1:  mov qword ptr [rbx + AL_turns], 0
    mov qword ptr [rbx + AL_row], -1
    mov byte ptr [rbx + AL_rowkey], 0
    mov r15d, [rbx + AL_flags]  # prompts sent while it was ending: it starts again for them
    and r15d, ALF_RESTART
    and dword ptr [rbx + AL_flags], ~(ALF_STOP_ASKED | ALF_ENDING | ALF_RESTART)
    cmp qword ptr [rbx + AL_queue + VEC_len], 0
    jne 11f
    xor r15d, r15d
11: mov esi, RS_ALL             # prompts that waited for a start rhun ended go back in the box; the
    test r15d, r15d             #   messages it held and never started always do
    jz 12f
    mov esi, RS_HELD
12: mov rdi, rbx
    call queue_restore
    mov rdi, rbx                # nobody waits for an answer now: the cards go
    call reqs_drop
    mov r13d, eax
    mov r14d, [rbx + AL_flags]  # or the turn's end took them (its row goes with the re-read)
    and r14d, ALF_UNANSWERED
    and dword ptr [rbx + AL_flags], ~ALF_UNANSWERED
    mov r12, [rbx + AL_as]
    mov rdi, [r12 + AS_path]
    test rdi, rdi
    jz 8f
    call unreadable
    test eax, eax
    jnz 8f
    and dword ptr [rbx + AL_flags], ~ALF_NEW
    mov rdi, r12
    call agents_resync
    mov edi, r13d
    or edi, r14d
    call closed_note
    cmp dword ptr [rbx + AL_state], ALS_FAILED
    jne 9f
    cmp qword ptr [rbx + AL_report + SB_len], 0
    je 9f
    mov rdi, r12                # why it failed, after what the file holds (the re-read dropped its row)
    mov esi, R_ERROR
    mov rdx, [rbx + AL_report + SB_ptr]
    mov rcx, [rbx + AL_report + SB_len]
    xor r8d, r8d
    call agents_msg_add
9:  test r15d, r15d             # the start again (its prompts drawn queued until ready; a failed one
    jz 10f                      #   puts them in the box: ev_failed)
    mov rdi, rbx
    call agent_start
    jmp 10f
8:  mov edi, r13d               # no file to read again: the rows the stream fed stay
    call closed_note
    test r15d, r15d
    jz 10f
    mov rdi, rbx                # the start again
    call agent_start
10: mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# unreadable(path) -> eax 1 when the conversation's file cannot be read again now (ev_closed: rbx AL*): it is
#   not there, or it is a remote window's whose host is not connected (ALF_REREAD: agent_drv_remote_back
#   reads it once the host answers; until then the rows the stream fed stay)
unreadable:
    PROLOGUE
    mov r12, rdi
    cmp dword ptr [rip + g_remote], 0
    je 1f
    call remote_is_up
    test eax, eax
    jnz 1f
    or dword ptr [rbx + AL_flags], ALF_REREAD
    mov eax, 1
    EPILOGUE
1:  mov rdi, r12
    call vfs_missing
    EPILOGUE

# FN agent_drv_remote_back(): a remote window's host answers again (remoteui.s): each conversation whose
#   program ended while it was gone (ALF_REREAD) is read again from its file there, as ev_closed would have,
#   unless its program runs again by now
FN agent_drv_remote_back
    PROLOGUE
    xor r12d, r12d
1:  cmp r12, [rip + lives + VEC_len]
    jae 9f
    mov rax, [rip + lives + VEC_ptr]
    mov rbx, [rax + r12*8]
    inc r12
    test dword ptr [rbx + AL_flags], ALF_REREAD
    jz 1b
    and dword ptr [rbx + AL_flags], ~ALF_REREAD
    mov eax, [rbx + AL_state]
    cmp eax, ALS_OFF
    je 2f
    cmp eax, ALS_FAILED
    jne 1b
2:  mov r13, [rbx + AL_as]
    mov rdi, [r13 + AS_path]
    test rdi, rdi
    jz 1b
    call vfs_missing
    test eax, eax
    jnz 1b
    and dword ptr [rbx + AL_flags], ~ALF_NEW
    mov rdi, r13
    call agents_resync
    cmp dword ptr [rbx + AL_state], ALS_FAILED
    jne 1b
    cmp qword ptr [rbx + AL_report + SB_len], 0
    je 1b
    mov rdi, r13                # why it failed, after what the file holds (the re-read dropped its row)
    mov esi, R_ERROR
    mov rdx, [rbx + AL_report + SB_ptr]
    mov rcx, [rbx + AL_report + SB_len]
    xor r8d, r8d
    call agents_msg_add
    jmp 1b
9:  EPILOGUE

# closed_note(n): ev_closed (rbx AL*): when n requests were left unanswered, an info row says so
closed_note:
    test edi, edi
    jz 9f
    PROLOGUE
    lea rdi, [rip + .Lunanswered]
    call strlen
    mov rdi, [rbx + AL_as]
    mov esi, R_INFO
    lea rdx, [rip + .Lunanswered]
    mov rcx, rax
    xor r8d, r8d
    call agents_msg_add
    EPILOGUE
9:  ret

# FN ev_failed(al, ptr, len): it could not start or broke: ALS_FAILED, the reason in AL_report and as an
#   error row, and the prompts that waited back in the box
FN ev_failed
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r12, [rbx + AL_report + SB_ptr]
    je 1f                       # the driver's report itself
    lea rdi, [rbx + AL_report]
    call sb_clear
    lea rdi, [rbx + AL_report]
    mov rsi, r12
    mov rdx, r13
    call sb_push
1:  and dword ptr [rbx + AL_flags], ~ALF_ERRGONE    # the error block shows again (agentrows.s)
    mov r14d, [rbx + AL_state]
    mov rdi, rbx
    mov esi, ALS_FAILED
    call agent_state_set
    cmp r14d, ALS_STARTING      # its start failed: the notice that offers claude in the terminal
    jne 2f
    mov rdi, rbx
    call failed_notice
2:  mov rdi, [rbx + AL_as]
    mov esi, R_ERROR
    mov rdx, [rbx + AL_report + SB_ptr]
    mov rcx, [rbx + AL_report + SB_len]
    xor r8d, r8d
    call agents_msg_add
    mov rdi, rbx
    mov esi, RS_ALL
    call queue_restore
    EPILOGUE

# ---- the loop ----

# FN agent_drv_tick(): starts that waited for the login environment or for another program to end; a new
#   conversation left without a prompt goes (draft_left); the idle stop (idle_ms)
FN agent_drv_tick
    PROLOGUE
    call claude_auth_tick       # the sign-in question's time, with or without a record waiting
    cmp qword ptr [rip + lives + VEC_len], 0
    je 9f
    xor ebx, ebx
1:  cmp rbx, [rip + lives + VEC_len]
    jae 9f
    mov rax, [rip + lives + VEC_ptr]
    mov r12, [rax + rbx*8]
    test dword ptr [r12 + AL_flags], ALF_DRAFT
    jz 2f
    mov rdi, r12
    call draft_left
    test eax, eax
    jz 2f
    mov rdi, [r12 + AL_as]      # its row goes, its program with it (the record leaves lives: the same
    call agents_drop            #   index is looked at again)
    jmp 1b
2:  inc rbx
    test dword ptr [r12 + AL_flags], ALF_ENVWAIT
    jz 3f
    call uproc_env_ready
    test eax, eax
    jz 1b
    mov rdi, r12
    call drv_start
    jmp 1b
3:  test dword ptr [r12 + AL_flags], ALF_AUTHWAIT
    jz 30f
    mov rdi, r12
    xor esi, esi
    mov rax, [r12 + AL_drv]
    call [rax + DRV_auth]
    cmp eax, AUTH_WAIT
    je 1b
    mov rdi, r12
    call drv_start
    jmp 1b
30: test dword ptr [r12 + AL_flags], ALF_HOLDWAIT
    jz 31f
    mov rdi, r12
    call hold_tick
    jmp 1b
31: test dword ptr [r12 + AL_flags], ALF_CAPWAIT
    jz 4f
    call cap_full
    test eax, eax
    jnz 1b
    mov rdi, r12
    call drv_start
    jmp 1b
4:  mov rdi, r12
    call idle_left
    test rax, rax
    jnz 1b                      # not due yet, or none pending (-1)
    mov rdi, r12                # idle long enough: its program ends; the file is read again when it is
    call release                #   gone (ev_closed), the next Send starts it again
    jmp 1b
9:  EPILOGUE

# draft_left(AL*) -> eax 1 when the new conversation (ALF_DRAFT) is not the one the panel shows any more:
#   Back, another one opened, a new one begun, or the panel closed
draft_left:
    PROLOGUE
    mov rbx, rdi
    mov eax, 1
    cmp dword ptr [rip + g_show_agents], 0
    je 9f
    call agentext_new_active
    test rax, rax
    mov eax, 1
    jnz 9f
    call agents_open_driven
    xor ecx, ecx
    cmp rax, [rbx + AL_as]
    setne cl
    mov eax, ecx
9:  EPILOGUE

# idle_ms() -> rax the idle stop's time ([agents] idle_stop_minutes, or agent-timing's), 0: never
idle_ms:
    mov eax, [rip + g_drv_idle_ms]
    test eax, eax
    jnz 1f
    mov eax, [rip + cfg_agents_idle_stop]
    imul rax, rax, 60000
1:  ret

# idle_left(AL*) -> rax ms until its idle stop is due (0 or less: now); -1 when none is pending (its program
#   is not idle, or the idle stop is off)
idle_left:
    PROLOGUE
    mov rbx, rdi
    mov r12, -1
    call idle_base
    test eax, eax
    jz 9f
    call idle_ms
    test rax, rax
    jz 9f
    mov r12, rax
    add r12, [rbx + AL_used]
    call time_ms
    sub r12, rax
    mov rdi, [rbx + AL_as]      # an unfinished task holds it longer (agtask_busy: the hold's end is due then)
    call agtask_busy
    cmp rax, r12
    jle 1f
    mov r12, rax
1:  test r12, r12
    jg 9f
    xor r12d, r12d              # due: 0, not "none"
9:  mov rax, r12
    EPILOGUE

# FN agent_drv_timeout() -> eax ms until the tick has work, or -1: a start that waits (the login
#   environment, another program's end), an idle stop that is pending. Nothing for a record without a
#   program: an idle rhun has no timer from here
FN agent_drv_timeout
    PROLOGUE
    mov r13, -1
    xor ebx, ebx
1:  cmp rbx, [rip + lives + VEC_len]
    jae 8f
    mov rax, [rip + lives + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    mov eax, ENV_TICK_MS
    test dword ptr [r12 + AL_flags], ALF_ENVWAIT | ALF_CAPWAIT | ALF_AUTHWAIT
    jnz 2f
    test dword ptr [r12 + AL_flags], ALF_HOLDWAIT
    jz 11f
    call time_ms                # the holder's next read
    mov rcx, [r12 + AL_hold_at]
    sub rcx, rax
    xor eax, eax
    test rcx, rcx
    cmovg rax, rcx
    jmp 2f
11: mov rdi, r12
    call idle_left
    test rax, rax
    js 1b
2:  cmp r13, -1
    je 3f
    cmp rax, r13
    jae 1b
3:  mov r13, rax
    jmp 1b
8:  call claude_auth_timeout   # the sign-in question's time (none: -1)
    test eax, eax
    js 82f
    mov eax, eax
    cmp r13, -1
    je 81f
    cmp rax, r13
    jae 82f
81: mov r13, rax
82: call agentcard_timeout      # a shown card's lock (agentcard.s; none: -1)
    test eax, eax
    js 84f
    mov eax, eax
    cmp r13, -1
    je 83f
    cmp rax, r13
    jae 84f
83: mov r13, rax
84: mov rax, 0x3fffffff
    cmp r13, rax
    jbe 9f
    cmp r13, -1
    je 9f
    mov r13, rax
9:  mov eax, r13d
    EPILOGUE

# live_end(AL*): rhun stops driving the session: its card goes, its program gets the stop sequence
#   (conn_close: SIGTERM now, SIGKILL later, reaped by uproc_tick), the record is freed
live_end:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + AL_as]
    call agentext_card_drop
    mov rdi, rbx
    call live_free
    EPILOGUE

# FN agent_drv_shutdown(): every live record ends with its program (live_end: never a longer wait than
#   uproc_quit_end's). Quitting, and the project changing (agents_set_project)
FN agent_drv_shutdown
    PROLOGUE
    call agentpop_close         # a popup reads those records: it closes first (agentpop.s)
    call agentcfg_flush         # each driver's lists and choices to their project's file (agentcfg.s)
    call agside_flush           # p7c: the bookmarks and side questions to theirs (agentside.s)
    call claude_auth_end        # the sign-in question, if it runs
    mov dword ptr [rip + trust_answered], 0     # another project is asked again
1:  mov rcx, [rip + lives + VEC_len]
    test rcx, rcx
    jz 9f
    mov rax, [rip + lives + VEC_ptr]
    mov rdi, [rax + rcx*8 - 8]
    call live_end
    jmp 1b
9:  call agatt_reset            # phase 4 task 2: the box's pack and new conversations' go too
    call filelist_reset         # phase 4 task 7: the project's file list (filelist.s)
    EPILOGUE

# FN agent_drv_unlisted(): the provider switches changed (agents_sources_changed): a session rhun drives
#   whose provider the list does not show any more ([agents] claude off) ends with its program; the others
#   go on
FN agent_drv_unlisted
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + lives + VEC_len]
    jae 9f
    mov rax, [rip + lives + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov rax, [r12 + AL_as]
    mov eax, [rax + AS_kind]
    dec eax
    cmp eax, 3                  # a built-in source's: [agents] claude, codex, grok, opencode in order
    ja 2f
    lea rcx, [rip + cfg_agents_claude]
    cmp dword ptr [rcx + rax*4], 0
    jne 2f
    mov rdi, r12                # it leaves lives: the same index is looked at again
    call live_end
    jmp 1b
2:  inc rbx
    jmp 1b
9:  EPILOGUE

# FN agent_drv_apply(): the settings changed: a session whose driver is not available any more ([claude]
#   chat switched off) ends with its program; its conversation is read again from its file (a new one
#   that never got a prompt goes), and a new conversation being begun for that driver is left
FN agent_drv_apply
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + lives + VEC_len]
    jae 8f
    mov rax, [rip + lives + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov r13, [r12 + AL_as]
    mov rdi, r13
    call agent_drv_of
    cmp rax, [r12 + AL_drv]
    jne 2f
    inc rbx
    jmp 1b
2:  test dword ptr [r12 + AL_flags], ALF_DRAFT
    jz 3f
    mov rdi, r13                # its row goes, the record with it
    call agents_drop
    jmp 1b
3:  mov rdi, r12
    call live_end
    mov rdi, [r13 + AS_path]    # the file is the truth now (none yet: the rows the stream fed stay)
    test rdi, rdi
    jz 1b
    call vfs_missing            # (a remote window's: the host's file)
    test eax, eax
    jnz 1b
    mov rdi, r13
    call agents_resync
    jmp 1b
8:  mov edi, AG_CLAUDE           # chat with Claude Code off: its sign-in question, if it runs, ends
    call agent_drv_for_kind
    test rax, rax
    jnz 9f
    call claude_auth_end
9:  call agentext_drivers_changed
    EPILOGUE

# FN agent_live_dump(sb, AS* or 0): "state=… pid=0|1 sid=… mode=… queued=N requests=N new=0|1 scroll=N
#   max=N follow=0|1" (the open thread: agents_scroll_dump), then
#   "report=TEXT" when it failed with one (print-agent-live)
FN agent_live_dump
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
    test rsi, rsi
    jz 1f
    mov r12, [rsi + AS_live]
1:  mov rdi, rbx
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    mov eax, ALS_OFF
    test r12, r12
    jz 2f
    mov eax, [r12 + AL_state]
2:  lea rcx, [rip + state_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_pid]
    call sb_push_cstr
    xor esi, esi
    test r12, r12
    jz 3f
    mov eax, [r12 + AL_cn + CN_state]
    cmp eax, CN_UP
    sete sil
    cmp eax, CN_STOPPING
    jne 3f
    mov esi, 1
3:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_sid]
    call sb_push_cstr
    test r12, r12
    jz 4f
    mov rdi, rbx
    lea rsi, [r12 + AL_sid]
    call sb_push_cstr
4:  mov rdi, rbx
    lea rsi, [rip + .Ld_mode]
    call sb_push_cstr
    test r12, r12
    jz 5f
    mov rdi, rbx
    lea rsi, [r12 + AL_mode]
    call sb_push_cstr
5:  mov rdi, rbx
    lea rsi, [rip + .Ld_queued]
    call sb_push_cstr
    xor esi, esi
    test r12, r12
    jz 6f
    mov rsi, [r12 + AL_queue + VEC_len]
6:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_requests]
    call sb_push_cstr
    xor esi, esi
    test r12, r12
    jz 7f
    mov rsi, [r12 + AL_reqs + VEC_len]
7:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_new]
    call sb_push_cstr
    xor esi, esi
    test r12, r12
    jz 8f
    test dword ptr [r12 + AL_flags], ALF_NEW
    setnz sil
8:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx                # what the driver reported of its controls
    mov rsi, r12
    call live_controls_dump
    mov rdi, rbx                # where the open thread is scrolled, whether it follows the stream
    call agents_scroll_dump
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    test r12, r12
    jz 9f
    cmp qword ptr [r12 + AL_report + SB_len], 0
    je 9f
    mov rdi, rbx
    lea rsi, [rip + .Ld_report]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r12 + AL_report + SB_ptr]
    mov rdx, [r12 + AL_report + SB_len]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# live_controls_dump(sb, AL* or 0): " model=V effort=E ultra=0|1|- think=0|1 fast=off|on|cooldown held=N
#   ctx=N|- cache=Nm|cold|- suggest=0|1 wake=MS|-" ("-" for what is not known; wake: the drivers' next
#   wake-up of the loop, agent_drv_timeout, whichever record it is for)
live_controls_dump:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    lea rsi, [rip + .Ld_model]
    call sb_push_cstr
    xor esi, esi
    test r12, r12
    jz 1f
    lea rsi, [r12 + AL_model]
1:  mov rdi, rbx
    call push_or_dash
    mov rdi, rbx
    lea rsi, [rip + .Ld_effort]
    call sb_push_cstr
    xor esi, esi
    test r12, r12
    jz 2f
    lea rsi, [r12 + AL_effort]
2:  mov rdi, rbx
    call push_or_dash
    mov rdi, rbx
    lea rsi, [rip + .Ld_ultra]
    call sb_push_cstr
    mov eax, -1
    test r12, r12
    jz 3f
    mov eax, [r12 + AL_ultra]
3:  mov rdi, rbx
    mov esi, eax
    call push_tri
    mov rdi, rbx
    lea rsi, [rip + .Ld_think]
    call sb_push_cstr
    mov eax, -1
    test r12, r12
    jz 4f
    mov eax, [r12 + AL_think]
4:  mov rdi, rbx
    mov esi, eax
    call push_tri
    mov rdi, rbx
    lea rsi, [rip + .Ld_fast]
    call sb_push_cstr
    xor eax, eax
    test r12, r12
    jz 5f
    mov eax, [r12 + AL_fast]
    cmp eax, FS_COOLDOWN
    jbe 5f
    xor eax, eax
5:  lea rcx, [rip + fast_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_held]
    call sb_push_cstr
    xor esi, esi
    test r12, r12
    jz 6f
    mov rsi, [r12 + AL_held + VEC_len]
6:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_ctx]
    call sb_push_cstr
    test r12, r12
    jz 7f
    lea rdi, [r12 + AL_usage]   # the share of the window in use, in percent
    call agent_ctx_used
    test edx, edx
    jz 7f
    mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    jmp 71f
7:  mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
71: mov rdi, rbx
    lea rsi, [rip + .Ld_cache]
    call sb_push_cstr
    test r12, r12
    jz 81f
    lea rdi, [r12 + AL_usage]
    call agent_cache_state
    cmp eax, CACHE_NONE
    je 81f
    cmp eax, CACHE_WARM
    jne 82f
    lea rax, [rdx + 59999]      # minutes left, rounded up
    xor edx, edx
    mov ecx, 60000
    div rcx
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    mov esi, 'm'
    call sb_push_byte
    jmp 83f
81: mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 83f
82: mov rdi, rbx
    lea rsi, [rip + .Ld_cold]
    call sb_push_cstr
83: mov rdi, rbx
    lea rsi, [rip + .Ld_suggest]
    call sb_push_cstr
    xor esi, esi
    test r12, r12
    jz 84f
    cmp qword ptr [r12 + AL_suggest], 0
    setne sil
84: mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx                # the drivers' next wake-up of the loop (agent_drv_timeout), "-" none
    lea rsi, [rip + .Ld_wake]
    call sb_push_cstr
    call agent_drv_timeout
    test eax, eax
    jns 85f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    EPILOGUE
85: mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    EPILOGUE

# push_or_dash(sb, cstr or 0): the text, or "-" when it is empty
push_or_dash:
    test rsi, rsi
    jz 1f
    cmp byte ptr [rsi], 0
    je 1f
    jmp sb_push_cstr
1:  mov esi, '-'
    jmp sb_push_byte

# push_tri(sb, -1|0|1): "-", "0" or "1"
push_tri:
    mov eax, esi
    mov esi, '-'
    test eax, eax
    js 1f
    mov esi, '0'
    jz 1f
    mov esi, '1'
1:  jmp sb_push_byte

# ---- the extension driver: the extension keeps the session's state (agentext.s) ----

# ext_start(AS*) -> eax 1: an extension's session needs no start
ext_start:
    mov eax, 1
    ret

# ext_answer(AS*, token, n) -> eax 1: the pick goes to the extension's agent-ask
ext_answer:
    mov rsi, rdx
    jmp agentext_ext_pick

# ext_release(AS*): nothing to end
ext_release:
    ret

# ext_held(AS*) -> eax HOLDER_NONE
ext_held:
    mov eax, HOLDER_NONE
    ret

# FN agent_ingest(AS*, record jv, ING_*) -> eax 1 taken: a record of a conversation (a line of its file, or a
#   record of the stream) given to its kind's reader (readers: no driver needed, so it works with the chat off
#   and in a remote window); 0: the kind has no reader or it left the record to the caller
FN agent_ingest
    push rbx
    mov rbx, rsi
    mov eax, [rdi + AS_kind]
    push rdi
    push rdx
    mov edi, eax
    xor esi, esi
    call agent_reader
    pop rdx
    pop rdi
    test rax, rax
    jz 9f
    mov rsi, rbx
    call rax
    jmp 8f
9:  xor eax, eax
8:  pop rbx
    ret

# FN agent_reader(kind, n) -> rax the kind's n-th reader function (0 ingest, 1 a part's whole text, 2 a
#   call's children, 3 an image's bytes: phase 4 task 6) or 0
FN agent_reader
    lea rax, [rip + readers]
1:  mov rcx, [rax]
    test rcx, rcx
    jz 8f
    cmp ecx, edi
    je 2f
    add rax, 40
    jmp 1b
2:  cmp esi, 3
    ja 8f
    mov rax, [rax + 8 + rsi*8]
    ret
8:  xor eax, eax
    ret

# ext_auth(AS*, again) -> eax AUTH_IN: the extension signs its agent in itself
ext_auth:
    mov eax, AUTH_IN
    ret

# ext_none() -> eax 0: what an extension's session does not have (modes, models, rich cards, actions)
ext_none:
    xor eax, eax
    ret

.section .rodata
.p2align 3
ext_drv:
    .long AS_KIND_EXT, DRVC_SESSION | DRVC_NEW | DRVC_RESUME
    .quad .Lext_name, ext_start, agentext_ext_send, agentext_stop, ext_answer, ext_release, ext_held
    .quad ext_auth, ext_release
    .quad ext_none, ext_none, ext_none, ext_none, ext_none, ext_none, ext_none, ext_none
    .quad ext_none              # DRV_menu: no command menu (agentpop.s)
    .quad 0                     # DRV_hint: the box's own placeholder
    .quad ext_none              # DRV_ended: it keeps nothing per start
    .quad 0                     # DRV_brand: no colour of its own
    .quad 0                     # DRV_verbs: no spinner line
    .quad 0                     # DRV_tips
    .quad ext_none              # DRV_task: no tasks
    .quad 0                     # DRV_words: the generic words (phase 4)
    .long 0, 0                  # DRV_glyph: none
# the readers of the kinds that have one, by AS_kind: {kind, ingest, text, kids, image}, then 0 (agent_ingest,
#   agent_reader; the one place above the drivers that names a kind's reader)
readers:
    .quad AG_CLAUDE, claude_ingest, claude_text, claude_kids, claude_image
    .quad 0
kind_names: .quad .Lk_claude, .Lk_codex, .Lk_grok, .Lk_opencode
fast_names: .quad .Lfs_off, .Lfs_on, .Lfs_cooldown
state_names: .quad .Ls_off, .Ls_starting, .Ls_ready, .Ls_working, .Ls_waiting, .Ls_held, .Ls_failed
ags_of: .long AGS_IDLE, AGS_WORKING, AGS_IDLE, AGS_WORKING, AGS_WAITING, AGS_WAITING, AGS_ERROR
opts_held: .quad .Lo_here, .Lo_copy, .Lo_cancel
opts_trust: .quad .Lo_trust, .Lo_without
opts_signin: .quad .Lo_signin
opts_failed: .quad .Lo_terminal
.Lq_trust: .asciz "Trust this folder? Claude Code would then use the project's own settings, hooks and servers."
.Lo_trust: .asciz "Trust"
.Lo_without: .asciz "Continue without"
.Lq_signin: .asciz "Claude Code is not signed in."
.Lq_on: .asciz " on "
.Lq_the_host: .asciz "the host"
.Lo_signin: .asciz "Sign In"
.Lq_failed: .asciz "Claude Code could not start."
.Lq_wrapper: .asciz " The wrapper "
.Lq_wrapper_tail: .asciz " is set in Settings > Claude Code."
.Lo_terminal: .asciz "Run claude in Terminal"
.Lq_held: .asciz "This conversation is still open somewhere else."
.Lo_here: .asciz "Open here anyway"
.Lo_copy: .asciz "Continue in a copy"
.Lo_cancel: .asciz "Cancel"
.Lcopy_of: .asciz "Copy of "
.Lconversation: .asciz "conversation"
.Lcopy_failed: .asciz "The copy could not be made."
.Lext_name: .asciz "extension"
.Lk_claude: .asciz "claude"
.Lk_codex: .asciz "codex"
.Lk_grok: .asciz "grok"
.Lk_opencode: .asciz "opencode"
.Ls_off: .asciz "off"
.Ls_starting: .asciz "starting"
.Ls_ready: .asciz "ready"
.Ls_working: .asciz "working"
.Ls_waiting: .asciz "waiting"
.Ls_held: .asciz "held"
.Ls_failed: .asciz "failed"
.Ldash: .asciz "-"
.Lblank: .asciz "\n\n"
.Lnew_title: .asciz "New conversation"
.Lurandom: .asciz "/dev/urandom"
.Lhex: .ascii "0123456789abcdef"
.Lprompt_long: .asciz "The prompt is longer than 50,000 characters."
.Lmarker: .asciz "\n\n[Message truncated - exceeded 50,000 character limit]"
.Ltoo_many: .asciz "Sixteen messages are already waiting."
.Lheld_back: .asciz "A queued message was not sent."
.Lturn_failed: .asciz "The turn failed."
.Linterrupted: .asciz "Interrupted"
.Ltool_interrupted: .asciz "Tool interrupted"
.Ltool: .asciz "tool"
.Lunanswered: .asciz "Claude Code ended before the request was answered."
.Lbusy: .asciz "Too many agents are running. Stop one and send again."
.Ld_state: .asciz "state="
.Ld_pid: .asciz " pid="
.Ld_sid: .asciz " sid="
.Ld_mode: .asciz " mode="
.Ld_queued: .asciz " queued="
.Ld_requests: .asciz " requests="
.Ld_new: .asciz " new="
.Ld_report: .asciz "report="
.Ld_model: .asciz " model="
.Ld_effort: .asciz " effort="
.Ld_ultra: .asciz " ultra="
.Ld_think: .asciz " think="
.Ld_fast: .asciz " fast="
.Ld_held: .asciz " held="
.Ld_ctx: .asciz " ctx="
.Ld_cache: .asciz " cache="
.Ld_cold: .asciz "cold"
.Ld_suggest: .asciz " suggest="
.Ld_wake: .asciz " wake="
.Lfs_off: .asciz "off"
.Lfs_on: .asciz "on"
.Lfs_cooldown: .asciz "cooldown"
