# Background tasks and agents of a conversation (AS_tasks, AK records by value): their lines under the turn
# (after the spinner), Stop, Run in background, the status of an agent's call, the idle stop's hold. A
# driver's mapper feeds them from its task records (only the stream has them: a conversation read from its
# file has no task, and agtask_clear drops them with the rows); nothing here names a driver or a record.
# Generic. Only backgrounded tasks that are not finished have a line (the extension's hRe, kMt, VDn @5553847):
# at most 3 lines then "+N more agents" (iAt: 4 are shown whole), each its dot, its label ("DESC" or "DESC:
# WHAT IT DOES", nAt), its elapsed time ("12s", "1m 5s", with "34.6k tokens · 2 tools · " before it when it
# reported its use, sAt) and a Stop button. The elapsed time is redrawn through the panel's label_due (at most a
# frame a second, only while a line is drawn): no timer of its own.
#
#   agtask_get(AS*, id ptr, len) -> rax AK* (found, or made working now; 0: none can be kept). An AK* is good
#   until the next agtask_get or agtask_clear (the records move)
#   agtask_find(AS*, id ptr, len) -> rax AK* or 0; agtask_of_call(AS*, call cstr) -> rax AK* or 0
#   agtask_text(AK*, AKX_*, ptr, len), agtask_num(AK*, AKN_*, value), agtask_touch(AS*, AK*) (it changed: its
#   last record's time, a frame, its call's row measured again)
#   agtask_busy(AS*) -> rax 0, or the ms the idle stop must still wait for its unfinished tasks
#   agtask_status(AS*, call cstr) -> rax cstr or 0 (the line under an agent's call, GDn), edx AKS_*, ecx 1 when
#   Stop can be asked
#   agtask_ask(AS*, AGK_*, id cstr) -> eax 1 asked (the driver's DRV_task: Stop, Run in background),
#   agtask_driven(AS*) -> eax 1 (it can be asked now), agtask_runs(AS*, call cstr) -> eax 1 (a task of that call
#   is not finished)
#   agtask_h(AS*, w) -> eax, agtask_draw(AS*, x, y, w), agtask_follow() (a Stop clicked, after the frame),
#   agtask_click(AS*, n) -> eax (agent-task-click),
#   agtask_clear(AS*), agtask_dump(sb, AS*) (print-agent-tasks), agtask_fit_dump(sb) (print-agent-tasks-fit)
#   agtask_hold_ms (.long): agent-task-hold's override of TASK_HOLD_MS (0: TASK_HOLD_MS)
.include "rhun.inc"

.equ AK_CUT, 120                # what it does and why it failed: characters, then "…" (EMt)
.equ AK_LINES, 3                # lines shown when more than 4 have one (aLe)
.equ TL_DRAW, 1                 # tk_lay's modes
.equ TL_FIT, 2                  #   its boxes, from its left and top
.equ TL_DUMP, 3                 #   what each line shows

.data
.p2align 3
.globl agtask_hold_ms
agtask_hold_ms: .long 0
tk_gen: .long 1                 # bumped by every change: the cache below is for (tk_cas, tk_cgen)
.bss
.p2align 3
tk_cas: .quad 0                 # the conversation the cache is for
tk_cgen: .long 0
tk_n: .long 0                   # its tasks with a line
tk_idx: .zero 4 * (AK_LINES + 1)    # the first ones' places in AS_tasks
tk_on: .long 0                  # the ones from the fourth on (the overflow line's), their tokens, calls, starts
tk_ouse: .long 0
tk_otok: .quad 0
tk_ot0: .quad 0
tk_pend: .quad 0                # a Stop clicked: the task's id (owned), asked after the frame
tk_mode: .long 0                # tk_lay's
tk_pad: .long 0
tk_out: .quad 0                 # TL_FIT, TL_DUMP: the SB its lines go to
ls: .zero SB_SIZE               # a line's label
rs: .zero SB_SIZE               # its right part
tk_st: .zero SB_SIZE            # agtask_status's text

.text

# ---------------- records ----------------

# at_of(AS*, i) -> rax the AK at that place
at_of:
    imul rax, rsi, AK_SIZE
    add rax, [rdi + AS_tasks + VEC_ptr]
    ret

# ak_free(AK*): its texts
ak_free:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + AK_id]
    call mem_free
    mov rdi, [rbx + AK_call]
    call mem_free
    mov rdi, [rbx + AK_label]
    call mem_free
    mov rdi, [rbx + AK_act]
    call mem_free
    mov rdi, [rbx + AK_err]
    call mem_free
    EPILOGUE

# bump(): a task changed (the cache of lines is made again, a frame)
bump:
    inc dword ptr [rip + tk_gen]
    mov dword ptr [rip + g_dirty], 1
    ret

# FN agtask_find(AS*, id ptr, len) -> rax its task, or 0
FN agtask_find
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
    test r13, r13
    jz 8f
1:  cmp r14, [rbx + AS_tasks + VEC_len]
    jae 8f
    mov rdi, rbx
    mov rsi, r14
    call at_of
    mov r15, rax
    inc r14
    mov rdi, [r15 + AK_id]
    call strlen
    cmp rax, r13
    jne 1b
    mov rdi, [r15 + AK_id]
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jz 1b
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agtask_of_call(AS*, call cstr) -> rax the latest task that runs for that call, or 0
FN agtask_of_call
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor eax, eax
    test r12, r12
    jz 9f
    test rbx, rbx
    jz 9f
    mov r14, [rbx + AS_tasks + VEC_len]
1:  test r14, r14
    jz 8f
    dec r14
    mov rdi, rbx
    mov rsi, r14
    call at_of
    mov r15, rax
    mov rdi, [r15 + AK_call]
    test rdi, rdi
    jz 1b
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jz 1b
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agtask_get(AS*, id ptr, len) -> rax its task: found, or made now (working, started now); 0 for an id
#   that is empty or longer than 200 bytes, or when AK_MAX tasks are kept and none of them is finished
FN agtask_get
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call agtask_find
    test rax, rax
    jnz 9f
    test r13, r13
    jz 8f
    cmp r13, 200
    ja 8f
    cmp qword ptr [rbx + AS_tasks + VEC_len], AK_MAX
    jb 3f
    xor r14d, r14d              # full: the oldest finished one goes
1:  cmp r14, [rbx + AS_tasks + VEC_len]
    jae 8f
    mov rdi, rbx
    mov rsi, r14
    call at_of
    cmp dword ptr [rax + AK_state], AKS_FAILED
    jae 2f
    inc r14
    jmp 1b
2:  mov rdi, rax
    mov r15, rax
    call ak_free
    mov rcx, [rbx + AS_tasks + VEC_len]     # the ones after it move down
    dec rcx
    mov [rbx + AS_tasks + VEC_len], rcx
    sub rcx, r14
    imul rdx, rcx, AK_SIZE
    mov rdi, r15
    lea rsi, [r15 + AK_SIZE]
    call memmove
3:  lea rdi, [rbx + AS_tasks]
    mov esi, AK_SIZE
    call vec_push
    mov r15, rax
    mov rdi, r15
    xor esi, esi
    mov edx, AK_SIZE
    call memset
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [r15 + AK_id], rax
    mov dword ptr [r15 + AK_uses], -1
    call time_ms
    mov [r15 + AK_t0], rax
    mov [r15 + AK_seen], rax
    call bump
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# cut_chars(cstr) : a text of more than AK_CUT characters keeps AK_CUT - 1 of them and "…" (EMt); the
#   buffer has room for the three bytes of "…" past AK_CUT characters' bytes
cut_chars:
    xor ecx, ecx                # characters
    xor eax, eax                # bytes
1:  movzx edx, byte ptr [rdi + rax]
    test edx, edx
    jz 9f
    and edx, 0xc0
    cmp edx, 0x80
    je 2f
    inc ecx
    cmp ecx, AK_CUT
    jne 21f
    mov r8, rax                 # where the 120th character starts: "…" there if one follows
21: cmp ecx, AK_CUT
    ja 3f
2:  inc rax
    jmp 1b
3:  mov byte ptr [rdi + r8], 0xe2
    mov byte ptr [rdi + r8 + 1], 0x80
    mov byte ptr [rdi + r8 + 2], 0xa6
    mov byte ptr [rdi + r8 + 3], 0
9:  ret

# FN agtask_text(AK*, AKX_*, ptr, len): a text of it, copied (the call's id as it is; the others cleaned to
#   one line, agrow_text; what it does and why it failed cut at 120 characters); len 0 clears it
FN agtask_text
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rsi
    mov r13, rdx
    mov r14, rcx
    lea r15, [rbx + AK_call]
    cmp r12d, AKX_CALL
    je 1f
    lea r15, [rbx + AK_label]
    cmp r12d, AKX_LABEL
    je 1f
    lea r15, [rbx + AK_act]
    cmp r12d, AKX_ACT
    je 1f
    lea r15, [rbx + AK_err]
1:  mov rdi, [r15]
    call mem_free
    mov qword ptr [r15], 0
    test r14, r14
    jz 8f
    cmp r12d, AKX_CALL
    jne 2f
    cmp r14, 200
    ja 8f
    mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov [r15], rax
    jmp 8f
2:  mov rdi, r13
    mov rsi, r14
    call agrow_text
    mov [r15], rax
    test rax, rax
    jz 8f
    cmp r12d, AKX_ACT
    jb 8f
    mov rdi, rax
    call cut_chars
8:  call bump
    EPILOGUE

# FN agtask_num(AK*, AKN_*, value): its kind, state, whether it runs in the background, its calls, its tokens
FN agtask_num
    cmp esi, AKN_KIND
    jne 1f
    mov [rdi + AK_kind], edx
    jmp bump
1:  cmp esi, AKN_STATE
    jne 2f
    mov [rdi + AK_state], edx
    jmp bump
2:  cmp esi, AKN_BG
    jne 3f
    mov [rdi + AK_bg], edx
    jmp bump
3:  cmp esi, AKN_USES
    jne 4f
    mov [rdi + AK_uses], edx
    jmp bump
4:  cmp esi, AKN_TOKENS
    jne 9f
    mov edx, edx
    mov [rdi + AK_tokens], rdx
    jmp bump
9:  ret

# FN agtask_touch(AS*, AK*): it changed: its last record's time is now, a frame, and the row of the call it
#   runs for is measured again (the status line under an agent's call)
FN agtask_touch
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call time_ms
    mov [r12 + AK_seen], rax
    call bump
    mov rdi, [r12 + AK_call]
    test rdi, rdi
    jz 9f
    call strlen
    mov rdi, rbx
    mov rsi, [r12 + AK_call]
    mov rdx, rax
    call agrow_find
    test rax, rax
    jz 9f
    mov rdi, rbx
    mov rsi, rax
    call agrow_touch
9:  EPILOGUE

# FN agtask_clear(AS*): its tasks go (the rows went: a reread conversation has no program, so no task)
FN agtask_clear
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + AS_tasks + VEC_len]
    jae 2f
    mov rdi, rbx
    mov rsi, r12
    call at_of
    mov rdi, rax
    call ak_free
    inc r12
    jmp 1b
2:  mov qword ptr [rbx + AS_tasks + VEC_len], 0
    call bump
    EPILOGUE

# FN agtask_busy(AS*) -> rax 0 when no unfinished task holds its program, else the ms the idle stop still
#   waits: an unfinished task holds it until TASK_HOLD_MS (agtask_hold_ms) after its last record, so a task
#   that never ends (or whose end never came) cannot keep a program forever
FN agtask_busy
    PROLOGUE
    mov rbx, rdi
    xor r13d, r13d              # the longest wait
    test rbx, rbx
    jz 8f
    cmp qword ptr [rbx + AS_tasks + VEC_len], 0
    je 8f
    call time_ms
    mov r14, rax
    mov r15d, [rip + agtask_hold_ms]
    test r15d, r15d
    jnz 0f
    mov r15d, TASK_HOLD_MS
0:  xor r12d, r12d
1:  cmp r12, [rbx + AS_tasks + VEC_len]
    jae 8f
    mov rdi, rbx
    mov rsi, r12
    call at_of
    inc r12
    cmp dword ptr [rax + AK_state], AKS_WAITING
    ja 1b
    mov rcx, [rax + AK_seen]
    add rcx, r15
    sub rcx, r14
    cmp rcx, r13
    jle 1b
    mov r13, rcx
    jmp 1b
8:  mov rax, r13
    EPILOGUE

# drv_al(AS*) -> rax its live record when rhun drives it, its program runs and its driver asks for tasks;
#   rdx the driver
drv_al:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    test rbx, rbx
    jz 9f
    mov r12, [rbx + AS_live]
    test r12, r12
    jz 9f
    cmp dword ptr [r12 + AL_cn + CN_state], CN_UP
    jne 8f
    mov rdi, rbx
    call agent_drv_of
    test rax, rax
    jz 9f
    cmp qword ptr [rax + DRV_task], 0
    je 8f
    mov rdx, rax
    mov rax, r12
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agtask_driven(AS*) -> eax 1 when its driver can be asked for its tasks now (rhun drives it, its program
#   runs)
FN agtask_driven
    PROLOGUE
    call drv_al
    test rax, rax
    setnz al
    movzx eax, al
    EPILOGUE

# FN agtask_runs(AS*, call cstr) -> eax 1 when a task that runs for that call is not finished (focus view: the
#   fold of a background agent's call runs while the agent works)
FN agtask_runs
    PROLOGUE
    call agtask_of_call
    test rax, rax
    jz 9f
    cmp dword ptr [rax + AK_state], AKS_WAITING
    setbe al
    movzx eax, al
9:  EPILOGUE

# FN agtask_ask(AS*, AGK_*, id cstr) -> eax 1 asked: its driver's DRV_task (Stop a task, send a running call
#   to the background); 0 when nothing drives it
FN agtask_ask
    PROLOGUE
    mov r12d, esi
    mov r13, rdx
    call drv_al
    test rax, rax
    jz 9f
    test r13, r13
    jz 8f
    mov rdi, rax
    mov esi, r12d
    mov rcx, rdx
    mov rdx, r13
    call [rcx + DRV_task]
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agtask_status(AS*, call cstr) -> rax the line under an agent's call while it has a task (GDn
#   @5555115, without " · type /tasks to see its transcript"): "Waiting for your permission: see the request
#   below", "Working in the background[: WHAT]", "Failed: WHY", else "Finished", "Failed", "Stopped"; 0 when
#   the call runs no agent's task. edx its AKS_*, ecx 1 when Stop can be asked (working, driven)
FN agtask_status
    PROLOGUE
    mov rbx, rdi
    call agtask_of_call
    test rax, rax
    jz 8f
    mov r12, rax
    cmp dword ptr [r12 + AK_kind], AKK_AGENT
    jne 8f
    lea rdi, [rip + tk_st]
    call sb_clear
    mov eax, [r12 + AK_state]
    lea rsi, [rip + .Lwaiting]
    cmp eax, AKS_WAITING
    je 5f
    cmp eax, AKS_WORKING
    jne 2f
    lea rdi, [rip + tk_st]
    lea rsi, [rip + .Lworking]
    call sb_push_cstr
    mov rsi, [r12 + AK_act]     # what it does, when that is not its description
    test rsi, rsi
    jz 6f
    mov rdi, [r12 + AK_label]
    test rdi, rdi
    jz 1f
    call strcmp_eq
    test eax, eax
    jnz 6f
1:  lea rdi, [rip + tk_st]
    lea rsi, [rip + .Lcolon]
    call sb_push_cstr
    mov rsi, [r12 + AK_act]
    jmp 5f
2:  cmp eax, AKS_FAILED
    jne 3f
    cmp qword ptr [r12 + AK_err], 0
    je 3f
    lea rdi, [rip + tk_st]
    lea rsi, [rip + .Lfailed_c]
    call sb_push_cstr
    mov rsi, [r12 + AK_err]
    jmp 5f
3:  lea rcx, [rip + state_texts]
    mov rsi, [rcx + rax*8]
5:  lea rdi, [rip + tk_st]
    call sb_push_cstr
6:  lea rdi, [rip + tk_st]
    xor esi, esi
    call sb_push_byte
    xor r13d, r13d
    cmp dword ptr [r12 + AK_state], AKS_WAITING
    ja 7f
    mov rdi, rbx
    call drv_al
    test rax, rax
    setnz r13b
7:  mov rax, [rip + tk_st + SB_ptr]
    mov edx, [r12 + AK_state]
    mov ecx, r13d
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    EPILOGUE

# ---------------- the lines ----------------

# lines_of(AS*): the cache of its lines (tk_n, tk_idx, the overflow's sums), made again when a task changed
#   or another conversation is drawn: a frame costs nothing per task
lines_of:
    PROLOGUE
    mov rbx, rdi
    mov eax, [rip + tk_gen]
    cmp [rip + tk_cgen], eax
    jne 1f
    cmp [rip + tk_cas], rbx
    je 9f
1:  mov [rip + tk_cgen], eax
    mov [rip + tk_cas], rbx
    xor eax, eax
    mov [rip + tk_n], eax
    mov [rip + tk_on], eax
    mov [rip + tk_ouse], eax
    mov [rip + tk_otok], rax
    mov [rip + tk_ot0], rax
    xor r12d, r12d
2:  cmp r12, [rbx + AS_tasks + VEC_len]
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call at_of
    mov r13, rax
    inc r12
    cmp dword ptr [r13 + AK_bg], 0
    je 2b
    cmp dword ptr [r13 + AK_state], AKS_WAITING
    ja 2b
    mov eax, [rip + tk_n]
    inc dword ptr [rip + tk_n]
    cmp eax, AK_LINES
    ja 3f
    lea rcx, [rip + tk_idx]
    lea edx, [r12 - 1]
    mov [rcx + rax*4], edx
    jb 2b
3:  inc dword ptr [rip + tk_on]     # (the fourth one and on are the overflow's when there are 5 or more)
    mov eax, [r13 + AK_uses]
    test eax, eax
    js 31f
    add [rip + tk_ouse], eax
31: mov rax, [r13 + AK_tokens]
    add [rip + tk_otok], rax
    mov rax, [r13 + AK_t0]
    add [rip + tk_ot0], rax
    jmp 2b
9:  EPILOGUE

# shown() -> eax the lines drawn of the cached ones (all when 4 or fewer, else AK_LINES and the overflow's),
#   edx 1 with an overflow line
shown:
    mov eax, [rip + tk_n]
    xor edx, edx
    cmp eax, AK_LINES + 1
    jbe 9f
    mov eax, AK_LINES + 1
    mov edx, 1
9:  ret

# line_h() -> eax a line: the panel face's line, at least MI_20
line_h:
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    mov ecx, [rip + g_pmt + 4*MI_20]
    cmp eax, ecx
    cmovl eax, ecx
    ret

# FN agtask_h(AS*, w) -> eax the height of its lines after the spinner: a line each and MI_4 between them and
#   after them; 0 without a line
FN agtask_h
    PROLOGUE
    xor eax, eax
    test rdi, rdi
    jz 9f
    call lines_of
    call shown
    test eax, eax
    jz 9f
    mov r12d, eax
    call line_h
    add eax, [rip + g_pmt + 4*MI_4]
    imul eax, r12d
    add eax, [rip + g_pmt + 4*MI_4]
9:  EPILOGUE

# plural(sb, n, word cstr): " N WORD" / "N WORDs" (sl) onto sb, no blank before
plural:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    cmp r12d, 1
    je 9f
    mov rdi, rbx
    mov esi, 's'
    call sb_push_byte
9:  EPILOGUE

# tokens(sb, n): "1.2M", "34.6k" or N (ev: one decimal, rounded)
tokens:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, 'M'
    mov r14, 100000
    cmp r12, 1000000
    jae 1f
    mov r13d, 'k'
    mov r14d, 100
    cmp r12, 1000
    jae 1f
    mov rsi, r12
    call sb_push_u64
    EPILOGUE
1:  mov rax, r14                # tenths, rounded
    shr rax, 1
    add rax, r12
    xor edx, edx
    div r14
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r15, rdx
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    mov esi, '.'
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [r15 + '0']
    call sb_push_byte
    mov rdi, rbx
    mov esi, r13d
    call sb_push_byte
    EPILOGUE

# secs(sb, ms): "12s", "1m 5s" (J7)
secs:
    PROLOGUE
    mov rbx, rdi
    mov rax, rsi
    test rax, rax
    jns 1f
    xor eax, eax
1:  xor edx, edx
    mov ecx, 1000
    div rcx
    mov r12, rax                # seconds
    cmp r12, 60
    jb 2f
    xor edx, edx
    mov ecx, 60
    div rcx
    mov r13, rdx
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lm_]
    call sb_push_cstr
    mov r12, r13
2:  mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    mov rdi, rbx
    mov esi, 's'
    call sb_push_byte
    EPILOGUE

# combined(sb, ms): yLn: under an hour as secs, else "Hh Mm"
combined:
    PROLOGUE
    mov rbx, rdi
    mov rax, rsi
    test rax, rax
    jns 1f
    xor eax, eax
1:  mov r12, rax
    xor edx, edx
    mov ecx, 60000
    div rcx                     # minutes
    cmp rax, 60
    jae 2f
    mov rdi, rbx
    mov rsi, r12
    call secs
    EPILOGUE
2:  xor edx, edx
    mov ecx, 60
    div rcx
    mov r13, rdx
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lh_]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    call sb_push_u64
    mov rdi, rbx
    mov esi, 'm'
    call sb_push_byte
    EPILOGUE

# stats(sb, tokens, uses): "34.6k tokens · 2 tools · " when it reported tokens (tAt), else nothing
stats:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    test r12, r12
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call tokens
    mov rdi, rbx
    lea rsi, [rip + .Ltokens]
    call sb_push_cstr
    mov eax, r13d
    test eax, eax
    jns 1f
    xor eax, eax
1:  mov rdi, rbx
    mov esi, eax
    lea rdx, [rip + .Ltool]
    call plural
    mov rdi, rbx
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
9:  EPILOGUE

# texts(AS*, line, now, full) : ls and rs for that line of the cache: a task's label (nAt: "DESC", or "DESC:
#   WHAT" when what it does is not its description) and its right part (sAt; full 0: the time alone); the
#   overflow's "+N more agents" and "N tokens · M tools · T combined" (rAt)
texts:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r15d, ecx
    lea rdi, [rip + ls]
    call sb_clear
    lea rdi, [rip + rs]
    call sb_clear
    call shown
    test edx, edx
    jz 1f
    cmp r12d, AK_LINES
    jb 1f
    lea rdi, [rip + ls]         # the overflow
    mov esi, '+'
    call sb_push_byte
    lea rdi, [rip + ls]
    mov esi, [rip + tk_on]
    lea rdx, [rip + .Lmore]
    call plural
    test r15d, r15d
    jz 11f
    lea rdi, [rip + rs]
    mov rsi, [rip + tk_otok]
    mov edx, [rip + tk_ouse]
    call stats
11: mov eax, [rip + tk_on]      # the time they ran, added
    imul rax, r13
    sub rax, [rip + tk_ot0]
    lea rdi, [rip + rs]
    mov rsi, rax
    call combined
    lea rdi, [rip + rs]
    lea rsi, [rip + .Lcombined]
    call sb_push_cstr
    EPILOGUE
1:  lea rax, [rip + tk_idx]
    movsxd rsi, dword ptr [rax + r12*4]
    mov rdi, rbx
    call at_of
    mov r14, rax
    mov rsi, [r14 + AK_label]
    test rsi, rsi
    jnz 2f
    lea rsi, [rip + .Ltask]
    cmp dword ptr [r14 + AK_kind], AKK_AGENT
    jne 2f
    lea rsi, [rip + .Lagent]
2:  lea rdi, [rip + ls]
    call sb_push_cstr
    mov rsi, [r14 + AK_act]
    test rsi, rsi
    jz 3f
    mov rdi, [r14 + AK_label]
    test rdi, rdi
    jz 21f
    call strcmp_eq
    test eax, eax
    jnz 3f
21: lea rdi, [rip + ls]
    lea rsi, [rip + .Lcolon]
    call sb_push_cstr
    lea rdi, [rip + ls]
    mov rsi, [r14 + AK_act]
    call sb_push_cstr
3:  test r15d, r15d
    jz 4f
    lea rdi, [rip + rs]
    mov rsi, [r14 + AK_tokens]
    mov edx, [r14 + AK_uses]
    call stats
4:  mov rsi, r13
    sub rsi, [r14 + AK_t0]
    lea rdi, [rip + rs]
    call secs
    EPILOGUE

# width(sb) -> eax its text's width in the panel's face
width:
    mov rsi, [rdi + SB_ptr]
    mov rdx, [rdi + SB_len]
    xor eax, eax
    test rdx, rdx
    jz 9f
    mov rdi, [rip + ag_fui]
    jmp text_width
9:  ret

# box(kind cstr, x, y, w, h, text sb or 0): TL_FIT: "  KIND X,Y,W,H" from the lines' left and top (tk_fx,
#   tk_fy); TL_DUMP: "KIND TEXT" (a button: "button X,Y,W,H ID")
box:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov [rsp + 16], r9
    mov r12, [rip + tk_out]
    cmp dword ptr [rip + tk_mode], TL_DUMP
    jne 2f
    mov rdi, r12
    mov rsi, rbx
    call sb_push_cstr
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rsi, [rsp + 16]
    test rsi, rsi
    jz 9f
    mov rdi, r12
    mov rdx, [rsi + SB_len]
    mov rsi, [rsi + SB_ptr]
    call sb_push
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    EPILOGUE
2:  mov rdi, r12
    lea rsi, [rip + .Lindent]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, rbx
    call sb_push_cstr
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    xor r13d, r13d
3:  mov rdi, r12
    mov esi, [rsp + r13*4]
    call md_push_int
    inc r13d
    cmp r13d, 4
    jae 4f
    mov rdi, r12
    mov esi, ','
    call sb_push_byte
    jmp 3b
4:  mov rdi, r12
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# tk_lay(AS*, x, y, w): its lines laid out in tk_mode (lines_of done): each its dot in the pad before x, its
#   label (cut) and its right part (the time, and the tokens and calls when there is room for them), a Stop
#   button at its right end; the overflow line without a button. Frame: [0] x, [4] y, [8] w, [12] the line,
#   [16] the button's size, [20] the line's index, [24] the label's room, [28] the right part's width,
#   [32] now (time_ms), [40] the right part's x, [44] the button's id, [48] the texts' room, [52] the most
#   the right part may take
tk_lay:
    PROLOGUE 64
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    call line_h
    mov [rsp + 12], eax
    mov [rsp + 16], eax         # the button: as tall as the line, square
    call time_ms
    mov [rsp + 32], rax
    mov dword ptr [rsp + 20], 0
.Ltl_line:
    call shown
    cmp [rsp + 20], eax
    jae .Ltl_done
    mov r15d, edx               # an overflow line
    xor r14d, r14d              # the room the button takes
    test edx, edx
    jz 1f
    mov eax, [rsp + 20]
    cmp eax, AK_LINES
    je 2f
1:  mov r14d, [rsp + 16]
    add r14d, [rip + g_pmt + 4*MI_4]
2:  mov eax, [rsp + 8]          # the texts' room: the label keeps its width or half of it at least; the
    sub eax, r14d               #   right part whole (tokens, calls, time) when it fits beside that, else the
    jns 21f                     #   time alone, cut to what is left (none under MI_8)
    xor eax, eax
21: mov [rsp + 48], eax
    mov rdi, rbx
    mov esi, [rsp + 20]
    mov rdx, [rsp + 32]
    mov ecx, 1
    call texts
    lea rdi, [rip + ls]
    call width
    mov ecx, [rsp + 48]
    shr ecx, 1
    cmp eax, ecx
    cmovg eax, ecx
    mov ecx, [rsp + 48]
    sub ecx, eax
    sub ecx, [rip + g_pmt + 4*MI_8]
    jns 22f
    xor ecx, ecx
22: mov [rsp + 52], ecx         # the most the right part may take
    lea rdi, [rip + rs]
    call width
    mov r12d, eax
    cmp r12d, [rsp + 52]
    jle 3f
    mov rdi, rbx
    mov esi, [rsp + 20]
    mov rdx, [rsp + 32]
    xor ecx, ecx
    call texts
    lea rdi, [rip + rs]
    call width
    mov r12d, eax
3:  cmp r12d, [rsp + 52]
    jle 31f
    mov r12d, [rsp + 52]
31: cmp r12d, [rip + g_pmt + 4*MI_8]
    jge 32f
    xor r12d, r12d
32: mov [rsp + 28], r12d
    mov eax, [rsp]
    add eax, [rsp + 8]
    sub eax, r14d
    sub eax, r12d
    mov [rsp + 40], eax
    mov eax, [rsp + 48]
    sub eax, r12d
    test r12d, r12d
    jz 33f
    sub eax, [rip + g_pmt + 4*MI_8]
33: cmp eax, [rip + g_pmt + 4*MI_8]
    jge 34f
    xor eax, eax
34: mov [rsp + 24], eax
    cmp dword ptr [rip + tk_mode], TL_DRAW
    jne .Ltl_out
    mov rdi, rbx                # the dot: still (no tick for it), the running colour
    call agspin_color
    mov ecx, eax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    call agrow_dot
    cmp dword ptr [rsp + 24], 0
    je 35f
    mov rdi, [rip + ag_fui]     # the label
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, [rip + ls + SB_ptr]
    mov r9, [rip + ls + SB_len]
    COLOR eax, T_FG
    mov r10d, [rsp + 24]
    inc r10d
    push r10
    push rax
    call ui_text_v_fit
    add rsp, 16
35: cmp dword ptr [rsp + 28], 0
    je 36f
    mov rdi, [rip + ag_fui]     # the right part, muted
    mov esi, [rsp + 40]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, [rip + rs + SB_ptr]
    mov r9, [rip + rs + SB_len]
    COLOR eax, T_MUTED
    mov r10d, [rsp + 28]
    inc r10d
    push r10
    push rax
    call ui_text_v_fit
    add rsp, 16
36: test r14d, r14d
    jz .Ltl_next
    mov eax, [rsp + 20]         # Stop
    shl eax, 2
    add eax, ID_AG_TASK + 1
    mov [rsp + 44], eax
    mov edi, eax
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 16]
    mov r8d, ecx
    call ui_btn
    mov r13d, eax
    PM ecx, MI_14               # its icon, centred
    mov eax, [rsp + 16]
    sub eax, ecx
    sar eax, 1
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 16]
    add esi, eax
    mov edx, [rsp + 4]
    add edx, eax
    COLOR r8d, T_MUTED
    test r13d, UB_HOVER
    jz 4f
    COLOR r8d, T_FG
    mov dword ptr [rip + g_cursor], CUR_POINTER
4:  mov edi, IC_STOP
    call icon_draw
    test r13d, UB_HOVER
    jz 5f
    mov edi, [rsp + 44]         # its tip: "Stop"
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 16]
    mov edx, [rsp + 4]
    add edx, [rsp + 16]
    mov ecx, [rsp + 16]
    mov r8d, r13d
    lea r9, [rip + .Lstop]
    call tip_note_text
5:  test r13d, UB_CLICK
    jz .Ltl_next
    lea rax, [rip + tk_idx]     # asked after the frame, by its id
    mov ecx, [rsp + 20]
    movsxd rsi, dword ptr [rax + rcx*4]
    mov rdi, rbx
    call at_of
    mov r13, [rax + AK_id]
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call mem_dup
    mov rdi, [rip + tk_pend]
    mov [rip + tk_pend], rax
    call mem_free
    mov dword ptr [rip + g_dirty], 1
    jmp .Ltl_next
.Ltl_out:                       # written out
    lea rdi, [rip + .Lk_label]
    test r15d, r15d
    jz 6f
    mov eax, [rsp + 20]
    cmp eax, AK_LINES
    jne 6f
    lea rdi, [rip + .Lk_more]
6:  cmp dword ptr [rsp + 24], 0
    je 61f
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 24]
    mov r8d, [rsp + 12]
    lea r9, [rip + ls]
    call box
61: cmp dword ptr [rsp + 28], 0
    je 62f
    lea rdi, [rip + .Lk_right]
    mov esi, [rsp + 40]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 28]
    mov r8d, [rsp + 12]
    lea r9, [rip + rs]
    call box
62: test r14d, r14d
    jz .Ltl_next
    lea rdi, [rip + .Lk_button]
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 16]
    mov r8d, ecx
    xor r9d, r9d
    cmp dword ptr [rip + tk_mode], TL_FIT
    je 7f
    lea r9, [rip + rs]          # (dump: "button ID")
    mov rdi, r9
    call sb_clear
    mov eax, [rsp + 20]
    shl eax, 2
    add eax, ID_AG_TASK + 1
    lea rdi, [rip + rs]
    mov esi, eax
    call sb_push_u64
    lea r9, [rip + rs]
    lea rdi, [rip + .Lk_button]
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 16]
    mov r8d, ecx
7:  call box
.Ltl_next:
    mov eax, [rsp + 12]
    add eax, [rip + g_pmt + 4*MI_4]
    add [rsp + 4], eax
    inc dword ptr [rsp + 20]
    jmp .Ltl_line
.Ltl_done:
    EPILOGUE

# FN agtask_draw(AS*, x, y, w): its lines at y (x: the rows' text left), when they are inside the clip; the
#   panel draws again the second their time changes (label_due), no timer of its own
FN agtask_draw
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    test rbx, rbx
    jz 9f
    call lines_of
    call shown
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov esi, [rsp + 8]
    call agtask_h
    mov ecx, [rsp + 4]          # in view?
    cmp ecx, [rip + g_cv + CV_cy1]
    jge 9f
    add ecx, eax
    cmp ecx, [rip + g_cv + CV_cy0]
    jle 9f
    call time_now               # the times change next second
    lea rdi, [rax + 1]
    call agents_label_due
    mov dword ptr [rip + tk_mode], TL_DRAW
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_4]
    mov ecx, [rsp + 8]
    call tk_lay
9:  EPILOGUE

# FN agtask_follow(): a Stop clicked on a task's line is asked now that nothing drawn is in use (agrow_follow)
FN agtask_follow
    PROLOGUE
    mov rbx, [rip + tk_pend]
    test rbx, rbx
    jz 9f
    mov qword ptr [rip + tk_pend], 0
    call agents_viewed
    mov rdi, rax
    mov esi, AGK_STOP
    mov rdx, rbx
    call agtask_ask
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# FN agtask_click(AS*, n) -> eax 1: as a click on the Stop of its n-th line (from 1; agent-task-click), asked
#   after the frame; 0: no such line (the overflow line has no Stop)
FN agtask_click
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor eax, eax
    test rbx, rbx
    jz 9f
    call lines_of
    call shown
    test r12, r12
    jz 8f
    mov ecx, eax                # (the whole number: one past 32 bits is no line)
    cmp r12, rcx
    ja 8f
    test edx, edx
    jz 1f
    cmp r12, AK_LINES + 1
    je 8f
1:  lea rax, [rip + tk_idx]
    movsxd rsi, dword ptr [rax + r12*4 - 4]
    mov rdi, rbx
    call at_of
    mov r13, [rax + AK_id]
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call mem_dup
    mov rdi, [rip + tk_pend]
    mov [rip + tk_pend], rax
    call mem_free
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# ---------------- dumps ----------------

# FN agtask_dump(sb, AS*): print-agent-tasks: "tasks lines=N more=M", a line a task "task ID kind=agent|shell
#   state=S bg=0|1 uses=N|- call=ID|- label=T elapsed=S", then what each line shows: "label T", "right T",
#   "button ID" ("more T" for the overflow's label) at the panel's width
FN agtask_dump
    PROLOGUE 16
    mov r15, rdi
    mov rbx, rsi
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call lines_of
    mov rdi, r15
    lea rsi, [rip + .Ld_tasks]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rip + tk_n]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_more]
    call sb_push_cstr
    call shown
    xor esi, esi
    test edx, edx
    jz 0f
    mov esi, [rip + tk_on]
0:  mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    call time_ms
    mov [rsp], rax
    xor r12d, r12d
1:  cmp r12, [rbx + AS_tasks + VEC_len]
    jae 5f
    mov rdi, rbx
    mov rsi, r12
    call at_of
    mov r13, rax
    inc r12
    mov rdi, r15
    lea rsi, [rip + .Ld_task]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [r13 + AK_id]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_kind]
    call sb_push_cstr
    lea rsi, [rip + .Lagent_w]
    cmp dword ptr [r13 + AK_kind], AKK_AGENT
    je 2f
    lea rsi, [rip + .Lshell_w]
2:  mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    mov eax, [r13 + AK_state]
    cmp eax, AKS_STOPPED
    jbe 21f
    xor eax, eax
21: lea rcx, [rip + state_words]
    mov rsi, [rcx + rax*8]
    mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_bg]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [r13 + AK_bg]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_uses]
    call sb_push_cstr
    mov eax, [r13 + AK_uses]
    test eax, eax
    js 22f
    mov rdi, r15
    mov esi, eax
    call sb_push_u64
    jmp 23f
22: mov rdi, r15
    mov esi, '-'
    call sb_push_byte
23: mov rdi, r15
    lea rsi, [rip + .Ld_call]
    call sb_push_cstr
    mov rsi, [r13 + AK_call]
    test rsi, rsi
    jnz 24f
    lea rsi, [rip + .Ldash]
24: mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_label]
    call sb_push_cstr
    mov rsi, [r13 + AK_label]
    test rsi, rsi
    jz 25f
    mov rdi, r15
    call sb_push_cstr
25: mov rdi, r15
    lea rsi, [rip + .Ld_elapsed]
    call sb_push_cstr
    mov rax, [rsp]
    sub rax, [r13 + AK_t0]
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov rdi, r15
    mov rsi, rax
    call sb_push_u64
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    jmp 1b
5:  mov [rip + tk_out], r15     # what the lines show, at the panel's text width
    mov dword ptr [rip + tk_mode], TL_DUMP
    call th_textw_now
    mov ecx, eax
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call tk_lay
9:  EPILOGUE

# th_textw_now() -> eax the rows' text width of the last frame (240 when none was drawn)
th_textw_now:
    mov eax, [rip + th_textw]
    cmp eax, 16
    jge 1f
    mov eax, 240
1:  ret

# FN agtask_fit_dump(sb): print-agent-tasks-fit: the open conversation's lines laid out at panel font sizes 8
#   to 32 and panel widths 240 to 900 (step 20): "size=N w=N tw=N h=N" and a line a box ("  label X,Y,W,H",
#   "  right …", "  more …", "  button …") from the lines' left and top
FN agtask_fit_dump
    PROLOGUE 16
    mov r15, rdi
    call agents_viewed
    mov rbx, rax
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call lines_of
    mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    mov [rip + tk_out], r15
    mov dword ptr [rip + tk_mode], TL_FIT
    mov r12d, 8
1:  cmp r12d, 32
    ja 8f
    mov [rip + cfg_agents_font_size], r12d
    call agents_metrics
    mov r13d, 240
2:  cmp r13d, 900
    ja 7f
    mov r14d, r13d              # the rows' width in a panel that wide (as print-agent-rows-fit)
    sub r14d, [rip + g_pmt + 4*MI_16]
    sub r14d, [rip + g_pmt + 4*MI_16]
    sub r14d, [rip + g_pmt + 4*MI_24]
    mov rdi, r15
    lea rsi, [rip + .Lf_size]
    call sb_push_cstr
    mov rdi, r15
    mov esi, r12d
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lf_w]
    call sb_push_cstr
    mov rdi, r15
    mov esi, r13d
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lf_tw]
    call sb_push_cstr
    mov rdi, r15
    mov esi, r14d
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lf_h]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r14d
    call agtask_h
    mov rdi, r15
    mov esi, eax
    call sb_push_u64
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, r14d
    call tk_lay
    add r13d, 20
    jmp 2b
7:  inc r12d
    jmp 1b
8:  mov eax, [rsp]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
9:  EPILOGUE

.section .rodata
.Lwaiting: .asciz "Waiting for your permission: see the request below"
.Lworking: .asciz "Working in the background"
.Lcolon: .asciz ": "
.Lfailed_c: .asciz "Failed: "
.Lfinished: .asciz "Finished"
.Lfailed: .asciz "Failed"
.Lstopped: .asciz "Stopped"
.Lworking1: .asciz "Working"
.Lstop: .asciz "Stop"
.Lmore: .asciz "more agent"
.Ltokens: .asciz " tokens · "
.Ltool: .asciz "tool"
.Ldot: .asciz " · "
.Lcombined: .asciz " combined"
.Lm_: .asciz "m "
.Lh_: .asciz "h "
.Ltask: .asciz "task"
.Lagent: .asciz "Agent"
.Lindent: .asciz "  "
.Lk_label: .asciz "label"
.Lk_more: .asciz "more"
.Lk_right: .asciz "right"
.Lk_button: .asciz "button"
.Ld_tasks: .asciz "tasks lines="
.Ld_more: .asciz " more="
.Ld_task: .asciz "task "
.Ld_kind: .asciz " kind="
.Ld_state: .asciz " state="
.Ld_bg: .asciz " bg="
.Ld_uses: .asciz " uses="
.Ld_call: .asciz " call="
.Ld_label: .asciz " label="
.Ld_elapsed: .asciz " elapsed="
.Ldash: .asciz "-"
.Lagent_w: .asciz "agent"
.Lshell_w: .asciz "shell"
.Lw_working: .asciz "working"
.Lw_waiting: .asciz "waiting"
.Lw_failed: .asciz "failed"
.Lw_finished: .asciz "finished"
.Lw_stopped: .asciz "stopped"
.Lf_size: .asciz "size="
.Lf_w: .asciz " w="
.Lf_tw: .asciz " tw="
.Lf_h: .asciz " h="
.p2align 3
state_texts: .quad .Lworking1, .Lwaiting, .Lfailed, .Lfinished, .Lstopped
state_words: .quad .Lw_working, .Lw_waiting, .Lw_failed, .Lw_finished, .Lw_stopped
