# Claude Code's part of the session list's storage (agent_store.s):
# - a title the user gives is appended to the conversation's file as Claude Code writes one itself
#   ({"type":"custom-title","customTitle":T,"sessionId":ID}, what /rename writes and the extension's host
#   appends: ext-host-protocol 4), so claude in a terminal and the index both read it; rhun's reader takes the
#   last custom-title line as the title (ingest_line, agent_index.s)
# - the conversations another program holds: every claude that runs registers <claude dir>/sessions/<pid>.json
#   (agent_holder.s); a record of this system whose pid is alive and not one of rhun's own programs holds
#   its sessionId. Read by the panel's poll, once a second while the panel shows (agentlist.s aglist_poll)
#
#   claude_store_rename(AS*, ptr, len) -> eax 1 written
#   claude_store_held(sb)             "\nclaude:ID\n" for each conversation held elsewhere
.include "rhun.inc"

.equ RECORD_MAX, 65536

.bss
.p2align 3
lsb: .zero SB_SIZE
dsb: .zero SB_SIZE
held_sb: .quad 0

.section .rodata
.Lpre: .asciz "{\"type\":\"custom-title\",\"customTitle\":\""
.Lmid: .asciz "\",\"sessionId\":\""
.Lend: .asciz "\"}\n"
.Ljsonl: .asciz ".jsonl"
.Ljson: .asciz ".json"
.Lsessions: .asciz "/sessions"
.Lkey: .asciz "\nclaude:"
.Lk_sessionId: .asciz "sessionId"
.Lk_pid: .asciz "pid"
.Lk_pidDomain: .asciz "pidDomain"
.ifdef MACOS
.Ldomain: .asciz "darwin"
.else
.Ldomain: .asciz "linux"
.endif
.text

# FN claude_store_rename(AS*, ptr, len) -> eax 1 when the custom-title line was appended to its file (an
#   existing local file only: a remote window's conversation keeps the title in rhun's state)
FN claude_store_rename
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor eax, eax
    cmp dword ptr [rip + g_remote], 0
    jne 9f
    mov r14, [rbx + AS_path]
    test r14, r14
    jz 9f
    lea rdi, [rip + lsb]
    call sb_clear
    lea rdi, [rip + lsb]
    lea rsi, [rip + .Lpre]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    call esc
    lea rdi, [rip + lsb]
    lea rsi, [rip + .Lmid]
    call sb_push_cstr
    mov rdi, r14                # the id: the file's name without ".jsonl"
    call strlen
    mov rdi, r14
    mov rsi, rax
    call path_basename
    mov r15, rax
    mov rbx, rdx
    cmp rbx, 6
    jb 1f
    lea rdi, [r15 + rbx - 6]
    mov esi, 6
    lea rdx, [rip + .Ljsonl]
    call str_eq_cstr
    test eax, eax
    jz 1f
    sub rbx, 6
1:  mov rdi, r15
    mov rsi, rbx
    call esc
    lea rdi, [rip + lsb]
    lea rsi, [rip + .Lend]
    call sb_push_cstr
    mov rdi, r14
    mov esi, O_WRONLY | O_APPEND | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 8f
    mov ebx, eax
    mov edi, eax
    mov rsi, [rip + lsb + SB_ptr]
    mov rdx, [rip + lsb + SB_len]
    call write_all
    mov r12, rax
    mov edi, ebx
    SYS SYS_close
    xor eax, eax
    test r12, r12
    jnz 9f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# esc(ptr, len): lsb gets the bytes as a JSON string's inside (" \ and controls escaped)
esc:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, r13
    jae 9f
    movzx r14d, byte ptr [r12 + rbx]
    inc rbx
    cmp r14d, '"'
    je 2f
    cmp r14d, '\\'
    je 2f
    cmp r14d, 0x20
    jb 3f
    lea rdi, [rip + lsb]
    mov esi, r14d
    call sb_push_byte
    jmp 1b
2:  lea rdi, [rip + lsb]
    mov esi, '\\'
    call sb_push_byte
    lea rdi, [rip + lsb]
    mov esi, r14d
    call sb_push_byte
    jmp 1b
3:  lea rdi, [rip + lsb]        # \u00XX
    mov esi, '\\'
    call sb_push_byte
    lea rdi, [rip + lsb]
    mov esi, 'u'
    call sb_push_byte
    lea rdi, [rip + lsb]
    mov esi, '0'
    call sb_push_byte
    lea rdi, [rip + lsb]
    mov esi, '0'
    call sb_push_byte
    mov eax, r14d
    shr eax, 4
    add eax, '0'
    lea rdi, [rip + lsb]
    mov esi, eax
    call sb_push_byte
    mov eax, r14d
    and eax, 15
    lea esi, [rax + '0']
    cmp eax, 10
    jb 4f
    lea esi, [rax + 'a' - 10]
4:  lea rdi, [rip + lsb]
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

.ifndef WINDOWS
# FN claude_store_held(sb): "\nclaude:ID\n" for each conversation another live program of this system holds
FN claude_store_held
    PROLOGUE
    mov [rip + held_sb], rdi
    lea rdi, [rip + dsb]
    call sb_clear
    lea rdi, [rip + dsb]
    call claude_dir
    test eax, eax
    jz 9f
    lea rdi, [rip + dsb]
    lea rsi, [rip + .Lsessions]
    call sb_push_cstr
    lea rdi, [rip + dsb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + dsb + SB_ptr]
    lea rsi, [rip + one]
    xor edx, edx
    call dir_each_names
9:  EPILOGUE

# one(ctx, name): a NAME.json record judged
one:
    PROLOGUE
    mov rbx, rsi
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Ljson]
    mov ecx, 5
    call str_ends
    test eax, eax
    jz 9f
    mov rdi, [rip + dsb + SB_ptr]
    mov rsi, rbx
    call path_join_tmp
    mov rdi, rax
    mov esi, RECORD_MAX
    call file_read_limited
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    mov rsi, rdx
    call json_parse
    test rax, rax
    jz 8f
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lk_sessionId]
    call json_get
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 8f
    mov r14, rax
    mov r15, rdx
    mov rdi, r13
    lea rsi, [rip + .Lk_pid]
    call json_get
    mov rdi, rax
    call json_int
    test edx, edx
    jz 8f
    test rax, rax
    jle 8f
    cmp rax, 0x7fffffff
    ja 8f
    mov ebx, eax
    mov rdi, r13                # another system's record holds nothing here
    lea rsi, [rip + .Lk_pidDomain]
    call json_get
    test rax, rax
    jz 1f
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 1f
    mov rdi, r13
    lea rsi, [rip + .Lk_pidDomain]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Ldomain]
    call json_is
    test eax, eax
    jz 8f
1:  mov edi, ebx                # rhun's own program holds nothing
    call agent_conn_owns
    test eax, eax
    jnz 8f
    mov edi, ebx
    xor esi, esi
    SYS SYS_kill
    test rax, rax
    jz 2f
    cmp rax, -1                 # EPERM: alive
    jne 8f
2:  mov rdi, [rip + held_sb]
    lea rsi, [rip + .Lkey]
    call sb_push_cstr
    mov rdi, [rip + held_sb]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    mov rdi, [rip + held_sb]
    mov esi, 10
    call sb_push_byte
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE
.else
FN claude_store_held
    ret
.endif
