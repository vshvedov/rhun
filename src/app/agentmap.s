# The agent map (generic, phase 7 part 3; ext-webview-ui.md 3.29, `/tasks`, `/bashes`): a dialog on the
# shell of agentdlg.s listing the conversation ("This session": the tokens in its context, Working or Idle)
# and the agents it spawned (its Agent calls: the description, "Spawned by This session", the tool calls
# counted, the state), under "N agents · click an agent for details". An agent's details: back
# arrow, "Spawned by", the state, "Prompt" (its text), "Tool calls (N)" (its children kept), "Open
# transcript" (its row in the conversation, opened), and "Stop agent" while it runs (DRV_task AGK_STOP with
# its id). Nothing here names an agent: the rows are the conversation's typed rows (AT) and its live record.
#
# Background tasks (row 3.29; the extension's bAn and yAn @5448078): the conversation's shell commands that run
# in the background and have not finished (its task records, AS_tasks: agenttask.s), under "N background
# task(s) · click a task for details", each its description and Running. A task's details: back arrow, its
# description, "Running" or "Ended", and Stop while it runs (agtask_ask AGK_STOP; refused: "The task could not
# be stopped. It may have finished already."). The output view ("Command output", get_task_output) is not
# built.
#
# It follows the conversation while it is open: agmap_tick (from agside_split, once a frame the
# conversation is drawn) makes the rows again when the rows, the live state, the context or its tasks changed
# (a signature of five numbers: nothing is walked unless one moved; the tasks' is a sum over the few records).
#
#   agmap_open(AS*) -> eax 1      the map of that conversation
#   agmap_tick(AS*)               the conversation drawn this frame
#   agmap_gone(ptr)               an AS freed (agside_gone): the map of it closes
.include "rhun.inc"

.equ MA_AGENT, 1                # its acts (DGR_arg: the agent's row)
.equ MA_BACK, 2
.equ MA_STOP, 3
.equ MA_OPEN, 4
.equ MA_TASK, 5                 # a background task's row (DGR_arg: its place in AS_tasks)
.equ MA_TSTOP, 6                # its Stop
.equ SIG_SIZE, 40
.equ PROMPT_MAX, 2000

.data
.p2align 3
map_row: .quad -1               # the agent shown in detail (its row), -1 the list
.bss
.p2align 3
map_as: .quad 0                 # the conversation it shows, 0 none
map_sig: .zero SIG_SIZE         # rows, last growth, state, context, tasks: as built last
map_task: .quad 0               # the background task shown in detail (owned cstr: its id), 0 none
msb: .zero SB_SIZE

.text

# FN agmap_open(AS*) -> eax 1: the dialog "tasks" for that conversation
FN agmap_open
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    test rbx, rbx
    jz 9f
    call agents_open_driven
    mov rdi, rax                # (the shell closes it when another conversation is opened)
    cmp rax, rbx
    je 1f
    xor edi, edi
1:  lea rsi, [rip + .Ln_tasks]
    lea rdx, [rip + .Lt_map]
    lea rcx, [rip + map_ops]
    call agentdlg_open
    mov [rip + map_as], rbx
    mov qword ptr [rip + map_row], -1
    call task_drop
    call build
    mov eax, 1
9:  EPILOGUE

# FN agmap_gone(ptr): an AS freed: the map of it closes
FN agmap_gone
    PROLOGUE
    cmp [rip + map_as], rdi
    jne 9f
    test rdi, rdi
    jz 9f
    call agentdlg_close
    mov qword ptr [rip + map_as], 0
9:  EPILOGUE

# map_free(): DGO_free
map_free:
    mov qword ptr [rip + map_as], 0
    jmp task_drop

# task_drop(): no task shown in detail
task_drop:
    sub rsp, 8
    mov rdi, [rip + map_task]
    call mem_free
    mov qword ptr [rip + map_task], 0
    add rsp, 8
    ret

# listed(AK*) -> eax 1 when the map lists it: a shell command in the background, not finished
listed:
    xor eax, eax
    cmp dword ptr [rdi + AK_kind], AKK_SHELL
    jne 1f
    cmp dword ptr [rdi + AK_bg], 0
    je 1f
    cmp dword ptr [rdi + AK_state], AKS_WAITING
    ja 1f
    inc eax
1:  ret

# sig(AS*, out*) : the four numbers the rows follow
sig:
    mov rax, [rdi + AS_msgs + VEC_len]
    mov [rsi], rax
    mov rax, [rdi + AS_changed]
    mov [rsi + 8], rax
    xor eax, eax
    xor ecx, ecx
    mov rdx, [rdi + AS_live]
    test rdx, rdx
    jz 1f
    mov eax, [rdx + AL_state]
    mov rcx, [rdx + AL_usage + AGU_used]
1:  mov [rsi + 16], rax
    mov [rsi + 24], rcx
    mov rax, [rdi + AS_tasks + VEC_len]     # the tasks: their count, each one's kind, state and place
    shl rax, 32
    mov rcx, [rdi + AS_tasks + VEC_ptr]
    xor edx, edx
2:  cmp rdx, [rdi + AS_tasks + VEC_len]
    jae 3f
    imul r8, rdx, AK_SIZE
    mov r9d, [rcx + r8 + AK_state]
    imul r9d, r9d, 7
    add r9d, [rcx + r8 + AK_bg]
    imul r9d, r9d, 3
    add r9d, [rcx + r8 + AK_kind]
    lea r10, [rdx + 1]
    imul r9, r10
    add rax, r9
    inc rdx
    jmp 2b
3:  mov [rsi + 32], rax
    ret

# FN agmap_tick(AS*): while the map of that conversation shows, its rows follow it
FN agmap_tick
    PROLOGUE 48
    mov rbx, rdi
    cmp [rip + map_as], rbx
    jne 9f
    test rbx, rbx
    jz 9f
    lea rdi, [rip + .Ln_tasks]
    call agentdlg_is
    test eax, eax
    jz 8f
    mov rdi, rbx
    lea rsi, [rsp]
    call sig
    lea rdi, [rsp]
    lea rsi, [rip + map_sig]
    mov edx, SIG_SIZE
    call memeq
    test eax, eax
    jnz 9f
    call build
    jmp 9f
8:  mov qword ptr [rip + map_as], 0
9:  EPILOGUE

# at_of(i) -> rax the AT of the map's conversation's row i when it is an agent's call, else 0
at_of:
    mov rcx, [rip + map_as]
    xor eax, eax
    test rcx, rcx
    jz 1f
    cmp rdi, [rcx + AS_msgs + VEC_len]
    jae 1f
    imul rdx, rdi, AM_SIZE
    add rdx, [rcx + AS_msgs + VEC_ptr]
    mov rax, [rdx + AM_x]
    test rax, rax
    jz 1f
    test dword ptr [rax + AT_flags], ATF_PARENT
    jnz 1f
    xor eax, eax
1:  ret

# state_word(AT*) -> rax the agent's state as a word
state_word:
    lea rax, [rip + .Ls_failed]
    mov ecx, [rdi + AT_state]
    cmp ecx, ATS_FAILED
    je 1f
    lea rax, [rip + .Ls_stopped]
    cmp ecx, ATS_STOPPED
    je 1f
    cmp ecx, ATS_DENIED
    je 1f
    lea rax, [rip + .Ls_working]
    cmp ecx, ATS_RUNNING
    je 1f
    lea rax, [rip + .Ls_background]
    test dword ptr [rdi + AT_flags], ATF_BG
    jnz 1f
    lea rax, [rip + .Ls_done]
1:  ret

# runs(AT*) -> eax 1 while it may still run (running, or launched into the background)
runs:
    mov eax, 1
    cmp dword ptr [rdi + AT_state], ATS_RUNNING
    je 1f
    test dword ptr [rdi + AT_flags], ATF_BG
    jz 2f
    cmp dword ptr [rdi + AT_state], ATS_OK
    je 1f
2:  xor eax, eax
1:  ret

# desc(AT*) -> rax its description (or "Agent")
desc:
    mov rax, [rdi + AT_second]
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 0
    jne 2f
1:  lea rax, [rip + .Lagent]
2:  ret

# build(): the rows again (the list, or the agent shown)
build:
    PROLOGUE
    mov rbx, [rip + map_as]
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + map_sig]
    call sig
    cmp qword ptr [rip + map_task], 0
    je 0f
    call task_detail
    EPILOGUE
0:  cmp qword ptr [rip + map_row], -1
    je 1f
    mov rdi, [rip + map_row]
    call at_of
    test rax, rax
    jz 1f
    mov rdi, rax
    call detail
    EPILOGUE
1:  mov qword ptr [rip + map_row], -1
    call agentdlg_begin
    lea rdi, [rip + .Lt_map]
    call agentdlg_title
    xor edi, edi
    call agentdlg_back
    mov edi, DGK_ITEM           # This session
    mov esi, DGF_OFF
    xor edx, edx
    call agentdlg_row
    mov r12, rax
    mov rdi, r12
    xor esi, esi
    lea rdx, [rip + .Lt_session]
    call agentdlg_ctext
    lea rdi, [rip + msb]
    call sb_clear
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 2f
    mov rsi, [rax + AL_usage + AGU_used]
    test rsi, rsi
    jz 2f
    lea rdi, [rip + msb]
    call push_k
    lea rdi, [rip + msb]
    lea rsi, [rip + .Lt_tokens]
    call sb_push_cstr
    mov rdi, r12
    mov esi, 1
    mov rdx, [rip + msb + SB_ptr]
    mov rcx, [rip + msb + SB_len]
    call agentdlg_text
2:  lea rdx, [rip + .Ls_idle]
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 3f
    mov eax, [rax + AL_state]
    cmp eax, ALS_WORKING
    je 21f
    cmp eax, ALS_WAITING
    jne 3f
21: lea rdx, [rip + .Ls_working]
3:  mov rdi, r12
    mov esi, 2
    call agentdlg_ctext
    mov edi, DGK_HEAD           # the agents
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov r12, rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_agents]
    call agentdlg_ctext
    xor r13d, r13d              # "N agent(s) · click an agent for details"
    xor r14d, r14d
0:  cmp r13, [rbx + AS_msgs + VEC_len]
    jae 71f
    mov rdi, r13
    call at_of
    inc r13
    test rax, rax
    jz 0b
    inc r14d
    jmp 0b
71: test r14d, r14d
    jz 72f
    lea rdi, [rip + msb]
    call sb_clear
    lea rdi, [rip + msb]
    mov esi, r14d
    call sb_push_u64
    lea rsi, [rip + .Lt_nagents]
    cmp r14d, 1
    jne 73f
    lea rsi, [rip + .Lt_nagent]
73: lea rdi, [rip + msb]
    call sb_push_cstr
    lea rdi, [rip + msb]
    lea rsi, [rip + .Lt_hint]
    call sb_push_cstr
    mov edi, DGK_TEXT
    mov esi, DGF_MUTED | DGF_SMALL
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, [rip + msb + SB_ptr]
    mov rcx, [rip + msb + SB_len]
    call agentdlg_text
72: xor r13d, r13d              # the row
    xor r14d, r14d              # agents listed
4:  cmp r13, [rbx + AS_msgs + VEC_len]
    jae 6f
    mov rdi, r13
    call at_of
    test rax, rax
    jz 5f
    mov r15, rax
    inc r14d
    mov edi, DGK_ITEM
    xor esi, esi
    mov edx, MA_AGENT
    call agentdlg_row
    mov r12, rax
    mov [r12 + DGR_arg], r13
    mov rdi, r15
    call desc
    mov rdi, r12
    xor esi, esi
    mov rdx, rax
    call agentdlg_ctext
    lea rdi, [rip + msb]        # "Spawned by This session · N tool calls"
    call sb_clear
    lea rdi, [rip + msb]
    lea rsi, [rip + .Lt_spawned]
    call sb_push_cstr
    mov rdi, r15
    call calls_of
    test eax, eax
    js 41f
    mov [rsp], eax
    lea rdi, [rip + msb]
    lea rsi, [rip + .Lt_dot]
    call sb_push_cstr
    lea rdi, [rip + msb]
    mov esi, [rsp]
    call push_calls
41: mov rdi, r12
    mov esi, 1
    mov rdx, [rip + msb + SB_ptr]
    mov rcx, [rip + msb + SB_len]
    call agentdlg_text
    mov rdi, r15
    call state_word
    mov rdi, r12
    mov esi, 2
    mov rdx, rax
    call agentdlg_ctext
5:  inc r13
    jmp 4b
6:  test r14d, r14d
    jnz 7f
    mov edi, DGK_TEXT
    mov esi, DGF_MUTED
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_none]
    call agentdlg_ctext
7:  call tasks_list
9:  EPILOGUE

# tasks_list(): the background tasks' section of the map's conversation, when it has any
tasks_list:
    PROLOGUE
    mov rbx, [rip + map_as]
    xor r13d, r13d              # how many
    xor r12d, r12d
1:  cmp r12, [rbx + AS_tasks + VEC_len]
    jae 2f
    imul rdi, r12, AK_SIZE
    add rdi, [rbx + AS_tasks + VEC_ptr]
    inc r12
    call listed
    add r13d, eax
    jmp 1b
2:  test r13d, r13d
    jz 9f
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_tasks]
    call agentdlg_ctext
    lea rdi, [rip + msb]        # "N background task(s) · click a task for details"
    call sb_clear
    lea rdi, [rip + msb]
    mov esi, r13d
    call sb_push_u64
    lea rsi, [rip + .Lt_ntasks]
    cmp r13d, 1
    jne 3f
    lea rsi, [rip + .Lt_ntask]
3:  lea rdi, [rip + msb]
    call sb_push_cstr
    mov edi, DGK_TEXT
    mov esi, DGF_MUTED | DGF_SMALL
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, [rip + msb + SB_ptr]
    mov rcx, [rip + msb + SB_len]
    call agentdlg_text
    xor r12d, r12d
4:  cmp r12, [rbx + AS_tasks + VEC_len]
    jae 9f
    imul r14, r12, AK_SIZE
    add r14, [rbx + AS_tasks + VEC_ptr]
    mov rdi, r14
    call listed
    test eax, eax
    jz 5f
    mov edi, DGK_ITEM
    xor esi, esi
    mov edx, MA_TASK
    call agentdlg_row
    mov r15, rax
    mov [r15 + DGR_arg], r12
    mov rdi, r14
    call task_label
    mov rdi, r15
    xor esi, esi
    mov rdx, rax
    call agentdlg_ctext
    mov rdi, r15
    mov esi, 2
    lea rdx, [rip + .Ls_running]
    call agentdlg_ctext
5:  inc r12
    jmp 4b
9:  EPILOGUE

# task_label(AK*) -> rax its description, else "Background task"
task_label:
    mov rax, [rdi + AK_label]
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 0
    jne 2f
1:  lea rax, [rip + .Lt_task]
2:  ret

# task_detail(): the background task map_task names: its description, Running or Ended, Stop while it runs
task_detail:
    PROLOGUE
    mov rbx, [rip + map_as]
    mov rdi, [rip + map_task]
    call strlen
    mov rdx, rax
    mov rdi, rbx
    mov rsi, [rip + map_task]
    call agtask_find
    mov r12, rax                # its record, or 0 (gone: ended)
    call agentdlg_begin
    lea rdi, [rip + .Lt_task]
    test r12, r12
    jz 1f
    mov rdi, r12
    call task_label
    mov rdi, rax
1:  call agentdlg_title
    mov edi, MA_BACK
    call agentdlg_back
    xor r13d, r13d              # running
    test r12, r12
    jz 2f
    cmp dword ptr [r12 + AK_state], AKS_WAITING
    ja 2f
    inc r13d
2:  mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov r14, rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_state]
    call agentdlg_ctext
    lea rdx, [rip + .Ls_ended]
    test r13d, r13d
    jz 3f
    lea rdx, [rip + .Ls_running]
3:  mov rdi, r14
    mov esi, 1
    call agentdlg_ctext
    test r13d, r13d
    jz 9f
    lea rdi, [rip + .Lt_tstop]
    mov esi, MA_TSTOP
    mov edx, DBF_PRIMARY
    call agentdlg_button
9:  EPILOGUE

# calls_of(AT*) -> eax its tool calls: the count known, else those kept, -1 none known
calls_of:
    mov eax, [rdi + AT_nkids]
    test eax, eax
    jns 1f
    mov rax, [rdi + AT_kids + VEC_len]
    test rax, rax
    jnz 1f
    mov eax, -1
1:  ret

# push_calls(sb, n): "N tool call(s)"
push_calls:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov esi, r12d
    call sb_push_u64
    lea rsi, [rip + .Lt_calls]
    cmp r12d, 1
    jne 1f
    lea rsi, [rip + .Lt_call]
1:  mov rdi, rbx
    call sb_push_cstr
    EPILOGUE

# push_k(sb, n): n as the extension writes token counts ("850", "12.3k", "1.2M")
push_k:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, 1000
    jae 1f
    mov rsi, r12
    call sb_push_u64
    EPILOGUE
1:  mov r13d, 'k'
    mov r14, 100                # tenths of a thousand
    cmp r12, 1000000
    jb 2f
    mov r13d, 'M'
    mov r14, 100000
2:  mov rax, r12
    xor edx, edx
    div r14
    mov r15, rax                # in tenths
    xor edx, edx
    mov rcx, 10
    div rcx
    mov r12, rdx
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    test r12, r12
    jz 3f
    mov rdi, rbx
    mov esi, '.'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
3:  mov rdi, rbx
    mov esi, r13d
    call sb_push_byte
    EPILOGUE

# detail(AT*): an agent's details (map_row: its row)
detail:
    PROLOGUE
    mov rbx, rdi
    call agentdlg_begin
    mov rdi, rbx
    call desc
    mov rdi, rax
    call agentdlg_title
    mov edi, MA_BACK
    call agentdlg_back
    mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov r12, rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_by]
    call agentdlg_ctext
    mov rdi, r12
    mov esi, 1
    lea rdx, [rip + .Lt_session]
    call agentdlg_ctext
    mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov r12, rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_state]
    call agentdlg_ctext
    mov rdi, rbx
    call state_word
    mov rdi, r12
    mov esi, 1
    mov rdx, rax
    call agentdlg_ctext
    mov edi, DGK_HEAD           # Prompt
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_prompt]
    call agentdlg_ctext
    mov edi, DGK_TEXT
    mov esi, DGF_SMALL
    xor edx, edx
    call agentdlg_row
    mov r12, rax
    mov rdx, [rbx + AT_in + SB_ptr]
    mov rcx, [rbx + AT_in + SB_len]
    cmp rcx, PROMPT_MAX
    jbe 1f
    mov ecx, PROMPT_MAX
1:  mov rdi, r12
    xor esi, esi
    call agentdlg_text
    mov edi, DGK_HEAD           # Tool calls (N)
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov r12, rax
    lea rdi, [rip + msb]
    call sb_clear
    lea rdi, [rip + msb]
    lea rsi, [rip + .Lt_tools]
    call sb_push_cstr
    mov rdi, rbx
    call calls_of
    test eax, eax
    jns 2f
    xor eax, eax
2:  mov esi, eax
    lea rdi, [rip + msb]
    call sb_push_u64
    lea rdi, [rip + msb]
    mov esi, ')'
    call sb_push_byte
    mov rdi, r12
    xor esi, esi
    mov rdx, [rip + msb + SB_ptr]
    mov rcx, [rip + msb + SB_len]
    call agentdlg_text
    xor r13d, r13d
3:  cmp r13, [rbx + AT_kids + VEC_len]
    jae 4f
    mov rax, [rbx + AT_kids + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    mov edi, DGK_ITEM
    mov esi, DGF_OFF
    xor edx, edx
    call agentdlg_row
    mov r12, rax
    mov rdx, [r14 + AT_name]
    test rdx, rdx
    jz 31f
    mov rdi, r12
    xor esi, esi
    call agentdlg_ctext
31: mov rdx, [r14 + AT_second]
    test rdx, rdx
    jz 32f
    mov rdi, r12
    mov esi, 1
    call agentdlg_ctext
32: mov rdi, r14
    call state_word
    mov rdi, r12
    mov esi, 2
    mov rdx, rax
    call agentdlg_ctext
    jmp 3b
4:  mov edi, DGK_LINK
    xor esi, esi
    mov edx, MA_OPEN
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_open]
    call agentdlg_ctext
    mov rdi, rbx
    call runs
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lt_stop]
    mov esi, MA_STOP
    mov edx, DBF_PRIMARY
    call agentdlg_button
9:  EPILOGUE

# map_act(act, arg, DGR*): DGO_act
map_act:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    cmp ebx, MA_AGENT
    jne 1f
    mov [rip + map_row], r12
    call build
    EPILOGUE
1:  cmp ebx, MA_BACK
    jne 2f
    mov qword ptr [rip + map_row], -1
    call task_drop
    call build
    EPILOGUE
2:  cmp ebx, MA_TASK            # a background task: its details (its id kept: the records move)
    jne 21f
    mov r13, [rip + map_as]
    test r13, r13
    jz 9f
    cmp r12, [r13 + AS_tasks + VEC_len]
    jae 9f
    imul rax, r12, AK_SIZE
    add rax, [r13 + AS_tasks + VEC_ptr]
    mov r14, [rax + AK_id]
    test r14, r14
    jz 9f
    call task_drop
    mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    call mem_dup
    mov [rip + map_task], rax
    call build
    EPILOGUE
21: cmp ebx, MA_TSTOP           # its Stop
    jne 22f
    mov rdi, [rip + map_as]
    mov rdx, [rip + map_task]
    test rdi, rdi
    jz 9f
    test rdx, rdx
    jz 9f
    mov esi, AGK_STOP
    call agtask_ask
    test eax, eax
    jnz 9f
    lea rdi, [rip + .Le_tstop]
    call app_toast
    EPILOGUE
22: mov r13, [rip + map_as]
    test r13, r13
    jz 9f
    mov rdi, [rip + map_row]
    call at_of
    test rax, rax
    jz 9f
    mov r14, rax
    cmp ebx, MA_OPEN
    jne 3f
    mov r15, [rip + map_row]    # "Open transcript": its row in view, its calls shown
    call agentdlg_close
    mov rdi, r13
    mov rsi, r15
    call agents_reveal
    test dword ptr [r14 + AT_flags], ATF_KIDS
    jnz 9f
    mov rdi, r13
    mov esi, r15d
    mov edx, PART_KIDS
    call agrow_click
    EPILOGUE
3:  cmp ebx, MA_STOP
    jne 9f
    mov rdi, [r13 + AS_live]    # "Stop agent": DRV_task with its id (the first word of AT_aux)
    test rdi, rdi
    jz 7f
    mov rsi, [r14 + AT_aux]
    test rsi, rsi
    jz 7f
    lea rdi, [rip + msb]
    call sb_clear
    mov rsi, [r14 + AT_aux]
    xor ecx, ecx
5:  movzx eax, byte ptr [rsi + rcx]
    cmp eax, ' '
    jbe 6f
    inc rcx
    jmp 5b
6:  mov rdx, rcx
    lea rdi, [rip + msb]
    call sb_push
    lea rdi, [rip + msb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [r13 + AS_live]
    mov esi, AGK_STOP
    mov rdx, [rip + msb + SB_ptr]
    mov rax, [rdi + AL_drv]
    call [rax + DRV_task]
    test eax, eax
    jnz 9f
7:  lea rdi, [rip + .Le_stop]
    call app_toast
9:  EPILOGUE

.section .rodata
.p2align 3
map_ops: .quad map_act, map_free
.Ln_tasks: .asciz "tasks"
.Lt_map: .asciz "Agent map"
.Lt_session: .asciz "This session"
.Lt_tokens: .asciz " tokens in context"
.Lt_agents: .asciz "Agents"
.Lt_hint: .asciz " \302\267 click an agent for details"
.Lt_nagents: .asciz " agents"
.Lt_nagent: .asciz " agent"
.Lt_spawned: .asciz "Spawned by This session"
.Lt_dot: .asciz " \302\267 "
.Lt_calls: .asciz " tool calls"
.Lt_call: .asciz " tool call"
.Lt_none: .asciz "No agents in this conversation."
.Lt_by: .asciz "Spawned by"
.Lt_state: .asciz "State"
.Lt_prompt: .asciz "Prompt"
.Lt_tools: .asciz "Tool calls ("
.Lt_open: .asciz "Open transcript"
.Lt_stop: .asciz "Stop agent"
.Lagent: .asciz "Agent"
.Ls_working: .asciz "Working"
.Ls_idle: .asciz "Idle"
.Ls_done: .asciz "Done"
.Ls_failed: .asciz "Failed"
.Ls_stopped: .asciz "Stopped"
.Ls_background: .asciz "In the background"
.Le_stop: .asciz "Could not stop the agent."
.Lt_tasks: .asciz "Background tasks"
.Lt_ntasks: .asciz " background tasks \302\267 click a task for details"
.Lt_ntask: .asciz " background task \302\267 click a task for details"
.Lt_task: .asciz "Background task"
.Lt_tstop: .asciz "Stop"
.Ls_running: .asciz "Running"
.Ls_ended: .asciz "Ended"
.Le_tstop: .asciz "The task could not be stopped. It may have finished already."
