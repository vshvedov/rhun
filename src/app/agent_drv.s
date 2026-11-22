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
#   agent_release(AS*) (the program ends politely, as the idle stop does)
#   agent_new(kind) -> rax AS* or 0           a new conversation of a built-in driver, adopted and opened
#   agent_closed(AS*)                         its row is freed: the program ends, the record is freed
#   agent_state_set(AL*, state)               keeps AS_state in step: STARTING and WORKING are
#                                             AGS_WORKING, WAITING and HELD AGS_WAITING, FAILED
#                                             AGS_ERROR, OFF and READY AGS_IDLE
#   agent_drv_tick(), agent_drv_timeout() -> eax ms or -1, agent_drv_shutdown()
#   agent_live_dump(sb, AS* or 0)             print-agent-live
#   events drivers call (AL* first): ev_note(al, role, ptr, len), ev_failed(al, ptr, len) (could not
#     start or broke: ALS_FAILED, an error row, the prompts that waited back in the box)
#   g_drv_idle_ms (0: [agents] idle_stop_minutes), g_drv_hold_ms: agent-timing's overrides
.include "rhun.inc"

.equ R_USER, 1                  # the roles of agents.s's messages
.equ R_ERROR, 5
.equ ENV_TICK_MS, 50            # a start waiting for the login environment looks again this often
.equ HOLD_MS, 10000             # how long a start waits for another holder of the conversation

.bss
.p2align 3
lives: .zero VEC_SIZE           # AL*: every live record
jsb: .zero SB_SIZE              # the prompts that waited, joined

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
2:  mov rdi, rbx
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
    call user_row
    mov eax, SEND_QUEUED
    jmp 9f
.Las_now:
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

# drv_start(AL*) -> eax 1 started, 0 failed (ev_failed with the driver's report)
drv_start:
    PROLOGUE
    mov rbx, rdi
    and dword ptr [rbx + AL_flags], ~ALF_ENVWAIT
    mov rax, [rbx + AL_drv]
    call [rax + DRV_start]
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, [rbx + AL_report + SB_ptr]
    mov rdx, [rbx + AL_report + SB_len]
    call ev_failed
    xor eax, eax
9:  EPILOGUE

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
    PROLOGUE
    mov rbx, [rdi + AS_live]
    test rbx, rbx
    jz 9f
    mov eax, [rbx + AL_cn + CN_state]
    cmp eax, CN_UP
    jne 9f
    mov rdi, rbx
    mov rax, [rbx + AL_drv]
    call [rax + DRV_release]
9:  EPILOGUE

# FN agent_new(kind) -> rax AS* or 0: a new conversation of a built-in driver, adopted and opened. Its
#   session (an id, a transcript path, the project's folder) is the driver's to make: none yet
FN agent_new
    xor eax, eax
    ret

# ---- events ----

# FN ev_note(al, role, ptr, len): a row of the agent's (R_INFO, R_ERROR)
FN ev_note
    mov rdi, [rdi + AL_as]
    xor r8d, r8d
    jmp agents_msg_add

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

# FN agent_drv_tick(): starts that waited for the login environment
FN agent_drv_tick
    PROLOGUE
    cmp qword ptr [rip + lives + VEC_len], 0
    je 9f
    xor ebx, ebx
1:  cmp rbx, [rip + lives + VEC_len]
    jae 9f
    mov rax, [rip + lives + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    test dword ptr [r12 + AL_flags], ALF_ENVWAIT
    jz 1b
    call uproc_env_ready
    test eax, eax
    jz 9f
    mov rdi, r12
    call drv_start
    jmp 1b
9:  EPILOGUE

# FN agent_drv_timeout() -> eax ms until the tick has work, or -1
FN agent_drv_timeout
    xor ecx, ecx
1:  cmp rcx, [rip + lives + VEC_len]
    jae 8f
    mov rax, [rip + lives + VEC_ptr]
    mov rax, [rax + rcx*8]
    inc rcx
    test dword ptr [rax + AL_flags], ALF_ENVWAIT
    jz 1b
    mov eax, ENV_TICK_MS
    ret
8:  mov eax, -1
    ret

# FN agent_drv_shutdown(): every live record ends with its program (conn_close: SIGTERM now, SIGKILL
#   at uproc's deadline, never a longer wait than uproc_quit_end's)
FN agent_drv_shutdown
    PROLOGUE
1:  mov rcx, [rip + lives + VEC_len]
    test rcx, rcx
    jz 9f
    mov rax, [rip + lives + VEC_ptr]
    mov rdi, [rax + rcx*8 - 8]
    call live_free
    jmp 1b
9:  lea rdi, [rip + lives]
    call vec_free
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
.Ld_state: .asciz "state="
.Ld_pid: .asciz " pid="
.Ld_sid: .asciz " sid="
.Ld_mode: .asciz " mode="
.Ld_queued: .asciz " queued="
.Ld_requests: .asciz " requests="
.Ld_new: .asciz " new="
.Ld_report: .asciz "report="
