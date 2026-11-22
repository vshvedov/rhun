# the driver seam: a session of the agents panel that rhun can talk to has a driver, a table of
# functions (DRV, rhun.inc). The panel's prompt box and cards (agentext.s) are the same for every
# driver; what Send, Stop and a card's pick do is the driver's. A session rhun drives itself (Claude
# Code: agent_claude.s) gets a live record (AL, AS_live) on its first use: the connection to its
# program, its state, the prompts waiting for the program to be ready, the requests it waits on. An
# extension's session keeps no record: its extension keeps the state (DRVC_SESSION).
#
#   agent_drv_of(AS*) -> rax DRV* or 0        the driver that can talk for this session now
#   agent_drv_for_kind(kind) -> rax DRV* or 0 a built-in driver, when it is available (Claude Code:
#                                             [claude] chat is on and the window is not remote)
#   agent_kind_name(kind) -> rax cstr         "claude", "codex", "grok", "opencode", or "-"
#   agent_kind_named(ptr, len) -> eax kind    the kind of such a word, or 0
#   agent_live(AS*) -> rax AL* (made on first use; 0 without a driver that keeps one)
#   agent_live_get(AS*) -> rax AL* or 0
#   agent_live_state(AS*) -> eax ALS_* (ALS_OFF without a record)
#   agent_send(AS*, ptr, len) -> eax SEND_*   the user's prompt: shown at once, then sent, or kept until
#                                             the program is ready (it is started first when it is not
#                                             running); refused while a turn runs
#   agent_stop(AS*), agent_answer(AS*, n), agent_typing(AS*) (typing starts the program),
#   agent_touch(AS*) (more typing: the idle stop waits again), agent_stop_running(AS*) -> eax (Escape:
#   Stop when a turn runs), agent_release(AS*) (the program ends politely, as the idle stop does)
#   agent_new(kind) -> rax AS* or 0           a new conversation of a built-in driver, adopted and opened
#   agent_closed(AS*)                         its row is freed: the program ends, the record is freed
#   agent_state_set(AL*, state)               keeps AS_state in step: STARTING and WORKING are
#                                             AGS_WORKING, WAITING and HELD AGS_WAITING, FAILED
#                                             AGS_ERROR, OFF and READY AGS_IDLE
#   agent_drv_tick(), agent_drv_timeout() -> eax ms or -1, agent_drv_shutdown() (quit, the project changes),
#   agent_drv_apply() (the settings changed: a driver switched off ends what it drives)
#   agent_live_dump(sb, AS* or 0)             print-agent-live
#   agent_uuid(buf)                           a v4 UUID, 36 characters and a NUL
#   events drivers call (AL* first): ev_note(al, role, ptr, len), ev_failed(al, ptr, len) (could not
#     start or broke: ALS_FAILED, an error row, the prompts that waited back in the box), ev_ready(al)
#     (handshake done: the prompts that waited go), ev_text(al, key ptr, key len, ptr, len, replace) (a
#     block's reply text), ev_tool(al, name, ptr, len) (a finished tool call: its summary),
#     ev_result_row(al, ptr, len) (a tool's output), ev_request(al, AQ*, prompt ptr, len, opts, n) (a
#     request's card: WAITING), ev_request_gone(al, AQ*) (it is answered or withdrawn: its card goes, it
#     leaves AL_reqs and is freed), ev_mode(al, ptr, len), ev_turn_end(al, TE_*, ptr, len),
#     ev_closed(al, err) (the process is gone: OFF unless FAILED, the requests it waited on go with an
#     info row, the conversation read again from its file)
#
# While a session's program runs or is about to (STARTING to HELD) its transcript is not read
# (session_update, agents.s): its rows come from the stream; ev_closed reads the file again.
#
# A program's life: it starts when the user types in the box or sends; it ends when it has been idle for
# [agents] idle_stop_minutes (the tick), when a new conversation is left before its first prompt (it goes,
# ALF_DRAFT), when the cap needs its place (the idle one used longest ago), and with its record when the
# chat is switched off, the project changes, its row is freed or rhun quits. An end rhun asked for is OFF,
# never FAILED (ALF_ENDING); one it did not ask for while a turn ran is FAILED, and the next Send starts
# it again (--resume once the file exists).
#   g_drv_idle_ms (0: [agents] idle_stop_minutes), g_drv_hold_ms: agent-timing's overrides
.include "rhun.inc"

.equ R_USER, 1                  # the roles of agents.s's messages
.equ R_ASSIST, 2
.equ R_TOOL, 3
.equ R_RESULT, 4
.equ R_ERROR, 5
.equ R_INFO, 6
.equ ENV_TICK_MS, 50            # a start waiting for the login environment looks again this often
.equ HOLD_MS, 10000             # how long a start waits for another holder of the conversation
.equ PROMPT_CHARS, 50000        # a prompt's characters at most (the extension's limit)
.equ ROWKEY_MAX, 80             # AL_rowkey's size

.bss
.p2align 3
lives: .zero VEC_SIZE           # AL*: every live record
jsb: .zero SB_SIZE              # the prompts that waited, joined; a new conversation's path
uuid_n: .quad 0                 # agent_uuid's counter (no /dev/urandom)

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
    cmp dword ptr [rip + g_remote], 0   # remote windows: not yet (the spawn goes through uproc.s)
    jne 1f
    lea rax, [rip + claude_drv]
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

# FN agent_state_set(AL*, state): AL_state, and AS_state as the list and the box read it
FN agent_state_set
    mov [rdi + AL_state], esi
    lea rax, [rip + ags_of]
    mov eax, [rax + rsi*4]
    mov rcx, [rdi + AL_as]
    mov [rcx + AS_state], eax
    mov dword ptr [rip + g_dirty], 1
    ret

# live_free(AL*): the program ends (conn_close), everything the record owns goes, AS_live is 0
live_free:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rbx + AL_cn]
    call conn_close
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
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# queue_free(AL*): the prompts that waited go
queue_free:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + AL_queue + VEC_len]
    jae 2f
    mov rax, [rbx + AL_queue + VEC_ptr]
    mov rdi, [rax + r12*8]
    call mem_free
    inc r12
    jmp 1b
2:  mov qword ptr [rbx + AL_queue + VEC_len], 0
    EPILOGUE

# queue_restore(AL*): the prompts that waited go back in the box, joined by blank lines, when the box is
#   the session's and empty; then they go
queue_restore:
    PROLOGUE
    mov rbx, rdi
    cmp qword ptr [rbx + AL_queue + VEC_len], 0
    je 9f
    lea rdi, [rip + jsb]
    call sb_clear
    xor r12d, r12d
1:  cmp r12, [rbx + AL_queue + VEC_len]
    jae 2f
    test r12, r12
    jz 11f
    lea rdi, [rip + jsb]
    lea rsi, [rip + .Lblank]
    call sb_push_cstr
11: mov rax, [rbx + AL_queue + VEC_ptr]
    lea rdi, [rip + jsb]
    mov rsi, [rax + r12*8]
    call sb_push_cstr
    inc r12
    jmp 1b
2:  mov rdi, [rbx + AL_as]
    mov rsi, [rip + jsb + SB_ptr]
    mov rdx, [rip + jsb + SB_len]
    call agentext_restore
    mov rdi, rbx
    call queue_free
9:  EPILOGUE

# FN agent_closed(AS*): its row is freed: the box forgets it, and a live record ends with its program
FN agent_closed
    PROLOGUE
    mov rbx, rdi
    call agentext_row_gone
    mov r12, [rbx + AS_live]
    test r12, r12
    jz 9f
    mov rdi, rbx
    call agentext_card_drop
    mov rdi, r12
    call live_free
9:  EPILOGUE

# ---- what the user does ----

# FN agent_send(AS*, ptr, len) -> eax SEND_*: the user's prompt to the session's driver (see the top)
FN agent_send
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call agent_drv_of
    mov r14, rax
    mov eax, SEND_FAILED
    test r14, r14
    jz 9f
    xor ecx, ecx                # only blanks: nothing to send
1:  mov eax, SEND_EMPTY
    cmp rcx, r13
    jae 9f
    movzx eax, byte ptr [r12 + rcx]
    inc rcx
    cmp eax, ' '
    jbe 1b
    test dword ptr [r14 + DRV_caps], DRVC_SESSION
    jz 2f
    mov rdi, rbx                # an extension's: its own send says
    mov rsi, r12
    mov rdx, r13
    call [r14 + DRV_send]
    jmp 9f
2:  xor ecx, ecx                # at most PROMPT_CHARS characters (the extension's limit)
    xor edx, edx
21: cmp rcx, r13
    jae 22f
    movzx eax, byte ptr [r12 + rcx]
    inc rcx
    and eax, 0xc0
    cmp eax, 0x80
    je 21b
    inc rdx
    jmp 21b
22: cmp rdx, PROMPT_CHARS
    jbe 23f
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
    cmp eax, ALS_READY
    je .Las_now
    cmp eax, ALS_STARTING
    je .Las_queue
    cmp eax, ALS_OFF
    je 3f
    cmp eax, ALS_FAILED
    je 3f
    mov eax, SEND_REFUSED       # a turn runs, a card is up, or it waits for another holder
    jmp 9f
3:  mov rdi, r15                # not running: started first, the prompt waits for ready
    call agent_start
    test eax, eax
    jnz .Las_queue
    mov eax, SEND_FAILED
    jmp 9f
.Las_queue:
    mov eax, SEND_FULL
    cmp qword ptr [r15 + AL_queue + VEC_len], AL_QUEUE_MAX
    jae 9f
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov r14, rax
    lea rdi, [r15 + AL_queue]
    mov esi, 8
    call vec_push
    mov [rax], r14
    and dword ptr [r15 + AL_flags], ~ALF_DRAFT     # it got a prompt: leaving it keeps it
    call user_row
    mov eax, SEND_QUEUED
    jmp 9f
.Las_now:
    and dword ptr [r15 + AL_flags], ~(ALF_DRAFT | ALF_UNANSWERED)
    call user_row
    mov rdi, r15
    mov rsi, r12
    mov rdx, r13
    mov rax, [r15 + AL_drv]
    call [rax + DRV_send]
    test eax, eax
    mov eax, SEND_FAILED
    jz 9f
    mov rdi, r15
    mov esi, ALS_WORKING
    call agent_state_set
    mov eax, SEND_OK
9:  EPILOGUE

# user_row(): agent_send's prompt (rbx AS, r12 ptr, r13 len) as the user's row, shown at once
user_row:
    PROLOGUE
    mov rdi, rbx
    mov esi, R_USER
    mov rdx, r12
    mov rcx, r13
    xor r8d, r8d
    call agents_msg_add
    EPILOGUE

# agent_start(AL*) -> eax 1 when its program starts (or will, once the login environment is known), 0
#   when it failed: the reason is an error row
agent_start:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rbx + AL_report]
    call sb_clear
    mov rax, [rbx + AL_as]      # the rows from here on come from the stream
    mov rax, [rax + AS_msgs + VEC_len]
    mov [rbx + AL_live_from], rax
    and dword ptr [rbx + AL_flags], ~(ALF_ENDING | ALF_STOP_ASKED | ALF_CAPWAIT)
    mov rdi, rbx
    mov esi, ALS_STARTING
    call agent_state_set
    call uproc_env_ready
    test eax, eax
    jnz 1f
    or dword ptr [rbx + AL_flags], ALF_ENVWAIT     # the tick starts it
    mov eax, 1
    EPILOGUE
1:  mov rdi, rbx
    call drv_start
    EPILOGUE

# drv_start(AL*) -> eax 1 started (or waiting for another program to end), 0 failed (ev_failed with the
#   driver's report). At the cap (g_conn_max programs) the idle one used longest ago is released first and
#   the start waits for a program to end (ALF_CAPWAIT, the tick starts it); with none idle it fails
drv_start:
    PROLOGUE
    mov rbx, rdi
    and dword ptr [rbx + AL_flags], ~(ALF_ENVWAIT | ALF_CAPWAIT)
    call cap_full
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
    jmp 3f
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

# is_idle(AL*) -> eax 1 when its program runs with nothing to do: READY, no request, no prompt waiting
is_idle:
    xor eax, eax
    cmp dword ptr [rdi + AL_state], ALS_READY
    jne 1f
    cmp dword ptr [rdi + AL_cn + CN_state], CN_UP
    jne 1f
    cmp qword ptr [rdi + AL_reqs + VEC_len], 0
    jne 1f
    cmp qword ptr [rdi + AL_queue + VEC_len], 0
    jne 1f
    inc eax
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
    cmp dword ptr [r12 + AL_state], ALS_WORKING
    je 2f
    cmp dword ptr [r12 + AL_state], ALS_WAITING
    jne 9f
2:  mov rdi, r12
    mov rax, [r12 + AL_drv]
    call [rax + DRV_stop]
9:  EPILOGUE

# FN agent_stop_running(AS*) -> eax 1 when a turn of a session rhun drives runs (WORKING, WAITING): Stop
#   went (Escape's meaning then; a second Stop in the same turn does nothing), 0 otherwise
FN agent_stop_running
    xor eax, eax
    test rdi, rdi
    jz 1f
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 1f
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
    mov rdi, rbx                # the card goes; the driver shows the next one
    call agentext_card_drop
    call time_ms
    mov [r13 + AL_used], rax
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
    lea rdi, [rip + jsb]
    call sb_clear
    lea rdi, [rip + jsb]
    mov rsi, r12
    lea rdx, [rsp]
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
    lea rdi, [rip + .Lnew_title]
    call strlen
    lea rdi, [rip + .Lnew_title]
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

# FN ev_ready(al): the handshake is done: the prompts that waited go, the oldest first
FN ev_ready
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    mov esi, ALS_READY
    call agent_state_set
    xor r12d, r12d
    xor r13d, r13d              # one went
1:  cmp r12, [rbx + AL_queue + VEC_len]
    jae 2f
    mov rax, [rbx + AL_queue + VEC_ptr]
    mov r14, [rax + r12*8]
    inc r12
    mov rdi, r14
    call strlen
    mov rdi, rbx
    mov rsi, r14
    mov rdx, rax
    mov rax, [rbx + AL_drv]
    call [rax + DRV_send]
    or r13d, eax
    jmp 1b
2:  mov rdi, rbx
    call queue_free
    test r13d, r13d
    jz 9f
    call time_ms
    mov [rbx + AL_used], rax
    mov rdi, rbx
    mov esi, ALS_WORKING
    call agent_state_set
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

# FN ev_tool(al, name cstr or 0, ptr, len): a finished tool call: its row (the name, "tool" without one),
#   the summary of its input as the file reader shows it
FN ev_tool
    mov rdi, [rdi + AL_as]
    mov r8, rsi
    test r8, r8
    jnz 1f
    lea r8, [rip + .Ltool]
1:  mov esi, R_TOOL
    jmp agents_msg_add

# FN ev_result_row(al, ptr, len): a tool's output, as a result row (none when it is empty: the file
#   reader shows none)
FN ev_result_row
    PROLOGUE
    mov rbx, [rdi + AL_as]
    mov r12, rsi
    mov r13, rdx
    mov rdi, rsi
    mov rsi, rdx
    call trim
    test rdx, rdx
    jz 9f
    mov rdi, rbx
    mov esi, R_RESULT
    mov rdx, r12
    mov rcx, r13
    xor r8d, r8d
    call agents_msg_add
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

# FN ev_request_gone(al, AQ*): answered or withdrawn: its card goes (when it shows), it leaves AL_reqs
#   (the others keep their order) and is freed
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
    jae 5f
    mov r8, [rax + rcx*8 + 8]
    mov [rax + rcx*8], r8
    inc rcx
    jmp 4b
5:  mov rdi, r12
    call aq_free
    mov dword ptr [rip + g_dirty], 1
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

# FN ev_mode(al, ptr, len): the permission mode the agent reports (the label by the box)
FN ev_mode
    cmp rdx, 31
    jbe 1f
    mov edx, 31
1:  lea rdi, [rdi + AL_mode]
    mov byte ptr [rdi + rdx], 0
    mov dword ptr [rip + g_dirty], 1
    jmp memmove

# FN ev_turn_end(al, reason, ptr, len): a turn ended: TE_DONE, TE_ERROR (the agent's text as an error row)
#   or TE_INTERRUPTED (an "Interrupted" row). READY once every prompt sent has had its end
FN ev_turn_end
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
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
    lea rdi, [rip + .Linterrupted]
    call strlen
    mov rdi, [rbx + AL_as]
    mov esi, R_INFO
    lea rdx, [rip + .Linterrupted]
    mov rcx, rax
    xor r8d, r8d
    call agents_msg_add
2:  and dword ptr [rbx + AL_flags], ~ALF_STOP_ASKED
    mov qword ptr [rbx + AL_row], -1
    mov byte ptr [rbx + AL_rowkey], 0
    call time_ms
    mov [rbx + AL_used], rax
    cmp qword ptr [rbx + AL_turns], 0
    je 3f
    dec qword ptr [rbx + AL_turns]
    jnz 9f
3:  and dword ptr [rbx + AL_flags], ~ALF_UNANSWERED
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
    and dword ptr [rbx + AL_flags], ~(ALF_STOP_ASKED | ALF_ENDING)
    mov rdi, rbx                # prompts that waited for a start rhun ended go back in the box
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
    call file_missing
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
    jmp 9f
8:  mov edi, r13d               # no file to read again: the rows the stream fed stay
    call closed_note
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

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
1:  mov rdi, rbx
    mov esi, ALS_FAILED
    call agent_state_set
    mov rdi, [rbx + AL_as]
    mov esi, R_ERROR
    mov rdx, [rbx + AL_report + SB_ptr]
    mov rcx, [rbx + AL_report + SB_len]
    xor r8d, r8d
    call agents_msg_add
    mov rdi, rbx
    call queue_restore
    EPILOGUE

# ---- the loop ----

# FN agent_drv_tick(): starts that waited for the login environment or for another program to end; a new
#   conversation left without a prompt goes (draft_left); the idle stop (idle_ms)
FN agent_drv_tick
    PROLOGUE
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
3:  test dword ptr [r12 + AL_flags], ALF_CAPWAIT
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
    call is_idle
    test eax, eax
    jz 9f
    call idle_ms
    test rax, rax
    jz 9f
    mov r12, rax
    add r12, [rbx + AL_used]
    call time_ms
    sub r12, rax
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
    test dword ptr [r12 + AL_flags], ALF_ENVWAIT | ALF_CAPWAIT
    jnz 2f
    mov rdi, r12
    call idle_left
    test rax, rax
    js 1b
2:  cmp r13, -1
    je 3f
    cmp rax, r13
    jae 1b
3:  mov r13, rax
    jmp 1b
8:  mov rax, 0x3fffffff
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
1:  mov rcx, [rip + lives + VEC_len]
    test rcx, rcx
    jz 9f
    mov rax, [rip + lives + VEC_ptr]
    mov rdi, [rax + rcx*8 - 8]
    call live_end
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
    call file_missing
    test eax, eax
    jnz 1b
    mov rdi, r13
    call agents_resync
    jmp 1b
8:  call agentext_drivers_changed
    EPILOGUE

# FN agent_live_dump(sb, AS* or 0): "state=… pid=0|1 sid=… mode=… queued=N requests=N new=0|1", then
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

.section .rodata
.p2align 3
ext_drv:
    .long AS_KIND_EXT, DRVC_SESSION | DRVC_NEW | DRVC_RESUME
    .quad .Lext_name, ext_start, agentext_ext_send, agentext_stop, ext_answer, ext_release, ext_held
kind_names: .quad .Lk_claude, .Lk_codex, .Lk_grok, .Lk_opencode
state_names: .quad .Ls_off, .Ls_starting, .Ls_ready, .Ls_working, .Ls_waiting, .Ls_held, .Ls_failed
ags_of: .long AGS_IDLE, AGS_WORKING, AGS_IDLE, AGS_WORKING, AGS_WAITING, AGS_WAITING, AGS_ERROR
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
.Lturn_failed: .asciz "The turn failed."
.Linterrupted: .asciz "Interrupted"
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
