# subscription-only sign-in (spec 5.3): the environment scrub, the lock arguments, the classifiers
# of what each CLI reports, and the preflight runner. rhun reads no credential files.
.include "rhun.inc"

.section .rodata
# scrub rules per agent: (kind, name, len) where kind 1 = exact name, 2 = prefix, 3 = suffix
.p2align 3
scrub_claude:
    .quad 2, .Ls_anthropic, 10
    .quad 2, .Ls_claude_code, 12
    .quad 1, .Ls_claudecode, 10
    .quad 0, 0, 0
scrub_codex:
    .quad 2, .Ls_openai, 7
    .quad 1, .Ls_codex_key, 13
    .quad 0, 0, 0
scrub_grok:
    .quad 1, .Ls_xai_key, 11
    .quad 1, .Ls_grok_key, 21
    .quad 0, 0, 0
scrub_opencode:
    .quad 3, .Ls_api_key, 8
    .quad 3, .Ls_api_token, 10
    .quad 3, .Ls_auth_token, 11
    .quad 0, 0, 0
scrub_table: .quad 0, scrub_claude, scrub_codex, scrub_grok, scrub_opencode
.Ls_anthropic: .ascii "ANTHROPIC_"
.Ls_claude_code: .ascii "CLAUDE_CODE_"
.Ls_claudecode: .ascii "CLAUDECODE"
.Ls_openai: .ascii "OPENAI_"
.Ls_codex_key: .ascii "CODEX_API_KEY"
.Ls_xai_key: .ascii "XAI_API_KEY"
.Ls_grok_key: .ascii "GROK_CODE_XAI_API_KEY"
.Ls_api_key: .ascii "_API_KEY"
.Ls_api_token: .ascii "_API_TOKEN"
.Ls_auth_token: .ascii "_AUTH_TOKEN"
# lock arguments (spec 5.3), spliced after the program name
.p2align 3
lock_claude: .quad .Ll_settings, .Ll_settings_json, 0
lock_codex: .quad .Ll_c, .Ll_forced, .Ll_c, .Ll_provider, 0
lock_table: .quad 0, lock_claude, lock_codex, 0, 0
.Ll_settings: .asciz "--settings"
.Ll_settings_json: .asciz "{\"forceLoginMethod\":\"claudeai\"}"
.Ll_c: .asciz "-c"
.Ll_forced: .asciz "forced_login_method=\"chatgpt\""
.Ll_provider: .asciz "model_provider=\"openai\""

.text

# scrubbed(entry, rules) -> 1 if the entry's name matches a rule
scrubbed:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    # the name ends at '='
    xor ecx, ecx
1:  mov al, [rbx + rcx]
    test al, al
    jz 2f
    cmp al, '='
    je 2f
    inc rcx
    jmp 1b
2:  mov r13, rcx                # name length
3:  mov rax, [r12]
    test rax, rax
    jz 8f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, [r12 + 8]
    mov rcx, [r12 + 16]
    cmp rax, 1
    je 4f
    cmp rax, 2
    je 5f
    call str_ends
    jmp 6f
4:  call str_eq
    jmp 6f
5:  call str_starts
6:  test eax, eax
    jnz 9f
    add r12, 24
    jmp 3b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# auth_envp_from(envp, agent, extras) -> a new envp: envp minus the agent's scrubbed names, then extras
FN auth_envp_from
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    # count both lists
    xor ecx, ecx
1:  cmp qword ptr [rbx + rcx*8], 0
    je 2f
    inc rcx
    jmp 1b
2:  xor edx, edx
3:  cmp qword ptr [r13 + rdx*8], 0
    je 4f
    inc rdx
    jmp 3b
4:  lea rdi, [rcx + rdx + 1]
    shl rdi, 3
    call mem_alloc
    mov r14, rax
    xor r15d, r15d              # out index
    xor eax, eax                # no rules for a kind outside the table
    cmp r12, AG_OPENCODE
    ja 41f
    lea rax, [rip + scrub_table]
    mov rax, [rax + r12*8]
41: push rax                    # rules
    push rax
    xor ecx, ecx
5:  mov rdi, [rbx + rcx*8]
    test rdi, rdi
    jz 7f
    push rcx
    push rcx
    mov rsi, [rsp + 16]
    test rsi, rsi
    jz 51f
    call scrubbed
    jmp 52f
51: xor eax, eax
52: pop rcx
    pop rcx
    test eax, eax
    jnz 6f
    mov rax, [rbx + rcx*8]
    mov [r14 + r15*8], rax
    inc r15
6:  inc rcx
    jmp 5b
7:  pop rax
    pop rax
    xor ecx, ecx
8:  mov rax, [r13 + rcx*8]
    test rax, rax
    jz 9f
    mov [r14 + r15*8], rax
    inc r15
    inc rcx
    jmp 8b
9:  mov qword ptr [r14 + r15*8], 0
    mov rax, r14
    EPILOGUE

# auth_envp(agent, extras) -> rhun's own environment, scrubbed, plus extras
FN auth_envp
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, [rip + g_envp]
    jmp auth_envp_from

# auth_lock_args(agent) -> a NUL-terminated list of cstr arguments, or 0
FN auth_lock_args
    cmp rdi, AG_OPENCODE
    ja 1f
    lea rax, [rip + lock_table]
    mov rax, [rax + rdi*8]
    ret
1:  xor eax, eax
    ret
