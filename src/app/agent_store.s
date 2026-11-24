# What a kind of agent keeps in its own storage that the session list (agentlist.s) uses: a title the user
# gives (written where the agent's own program reads it, so the agent in a terminal shows the same), and
# who else has a conversation open. The one place above the agents that names whose storage is whose, as
# agent_drv.s's readers table is for transcripts; a kind with no entry keeps its titles in rhun's own state
# (agentgroups.s) and has no holders.
#
#   agent_store_rename(AS*, ptr, len) -> eax 1 when the kind's own storage took the title (0: rhun keeps it)
#   agent_store_held(sb)              "\nKEY\n" (agst_key's) for each conversation another program has open
.include "rhun.inc"

.section .rodata
.p2align 3
stores:                         # {kind, rename(AS*, ptr, len) -> eax, held(sb)}, then 0
    .quad AG_CLAUDE, claude_store_rename, claude_store_held
    .quad 0
.text

# store_of(kind) -> rax the entry, or 0
store_of:
    lea rax, [rip + stores]
1:  mov rcx, [rax]
    test rcx, rcx
    jz 8f
    cmp ecx, edi
    je 9f
    add rax, 24
    jmp 1b
8:  xor eax, eax
9:  ret

# FN agent_store_rename(AS*, ptr, len) -> eax 1 when its kind's own storage took the title
FN agent_store_rename
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov edi, [rbx + AS_kind]
    call store_of
    test rax, rax
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call [rax + 8]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agent_store_held(sb): the keys of the conversations other programs have open, each "\nKEY\n"
FN agent_store_held
    PROLOGUE
    mov rbx, rdi
    lea r12, [rip + stores]
1:  cmp qword ptr [r12], 0
    je 9f
    mov rdi, rbx
    call [r12 + 16]
    add r12, 24
    jmp 1b
9:  EPILOGUE
