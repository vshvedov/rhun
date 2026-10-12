# agent_auth_test MODE ...: env AGENT prints the scrubbed environment and the lock arguments;
# classify FILE prints <basename>=<AUTH_*>[ ids], the classifier picked by the name's prefix;
# preflight AGENT [MS] runs auth_preflight in the current directory (MS sets g_auth_preflight_ms) and
# prints preflight:<agent>=<AUTH_*>[ ids]; post FILE prints <basename>=<AUTH_*>[ key path] for the after-start
# checks (grok-models-* print the names instead, then ? when the scan returns 0); lock prints the OpenCode lock for openai and xai
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
ids: .zero SB_SIZE
agent_name: .quad 0
done: .long 0
.section .rodata
.p2align 3
sample_env:
    .quad .Le1, .Le2, .Le3, .Le4, .Le5, .Le6, .Le7, .Le8, .Le9, .Le10, .Le11, .Le12, .Le13, .Le14, 0
.Le1: .asciz "HOME=/h"
.Le2: .asciz "ANTHROPIC_API_KEY=k1"
.Le3: .asciz "ANTHROPIC_API_KEY="
.Le4: .asciz "CLAUDE_CODE_ENTRYPOINT=cli"
.Le5: .asciz "CLAUDECODE=1"
.Le6: .asciz "OPENAI_API_KEY=o"
.Le7: .asciz "OPENAI_BASE_URL=u"
.Le8: .asciz "XAI_API_KEY=x"
.Le9: .asciz "GROK_CODE_XAI_API_KEY=g"
.Le10: .asciz "FOO_API_TOKEN=t"
.Le11: .asciz "BAR_AUTH_TOKEN=a"
.Le12: .asciz "ANTHROPICS=notme"
.Le13: .asciz "PATH=/bin"
.Le14: .asciz "CLAUDE_CODE_USE_BEDROCK=1"
extras: .quad .Lextra1, 0
.Lextra1: .asciz "RHUN_TEST=1"
agents: .quad .La_claude, 1, .La_codex, 2, .La_grok, 3, .La_opencode, 4, 0
.La_claude: .asciz "claude"
.La_codex: .asciz "codex"
.La_grok: .asciz "grok"
.La_opencode: .asciz "opencode"
.Lmode_env: .asciz "env"
.Lmode_classify: .asciz "classify"
.Lmode_preflight: .asciz "preflight"
.Lmode_post: .asciz "post"
.Lmode_lock: .asciz "lock"
.Lp_grok_models: .ascii "grok-models-"
.Lp_claude_init: .ascii "claude-init-"
.Lp_codex_account: .ascii "codex-account-"
.Lp_grok_init: .ascii "grok-init-"
.Lids_openai: .asciz "openai"
.Lids_two: .asciz "openai xai"
.Lsmall: .asciz "openai/gpt-5-mini"
.Ldot: .asciz "."
.Lev_preflight: .asciz "preflight:"
.Lp_claude: .ascii "claude-"
.Lp_codex: .ascii "codex-"
.Llock: .asciz "lock:"
.text

# agent_of(cstr) -> kind or 0 (also for a missing argument)
agent_of:
    PROLOGUE
    mov rbx, rdi
    test rdi, rdi
    jz 8f
    call strlen
    mov r12, rax
    lea r13, [rip + agents]
1:  mov rdx, [r13]
    test rdx, rdx
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add r13, 16
    jmp 1b
2:  mov rax, [r13 + 8]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

FN main
    PROLOGUE
    mov rax, [rip + g_argv]
    mov rdi, [rax + 16]
    call agent_of
    mov r12, rax
    mov rax, [rip + g_argv]
    mov rdi, [rax + 8]
    call strlen
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 8]
    mov rsi, rax
    lea rdx, [rip + .Lmode_env]
    call str_eq_cstr
    test eax, eax
    jz 45f
    lea rdi, [rip + sample_env]
    mov rsi, r12
    lea rdx, [rip + extras]
    call auth_envp_from
    mov rbx, rax
1:  mov rsi, [rbx]
    test rsi, rsi
    jz 2f
    lea rdi, [rip + out]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    add rbx, 8
    jmp 1b
2:  lea rdi, [rip + out]
    lea rsi, [rip + .Llock]
    call sb_push_cstr
    mov rdi, r12
    call auth_lock_args
    mov rbx, rax
3:  test rbx, rbx
    jz 4f
    mov rsi, [rbx]
    test rsi, rsi
    jz 4f
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [rbx]
    call sb_push_cstr
    add rbx, 8
    jmp 3b
4:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    jmp 9f
45: mov rcx, [rip + g_argv]
    mov rdi, [rcx + 8]
    call strlen
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 8]
    mov rsi, rax
    lea rdx, [rip + .Lmode_classify]
    call str_eq_cstr
    test eax, eax
    jnz 46f
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 8]
    call strlen
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 8]
    mov rsi, rax
    lea rdx, [rip + .Lmode_preflight]
    call str_eq_cstr
    test eax, eax
    jnz 80f
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 8]
    call strlen
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 8]
    mov rsi, rax
    lea rdx, [rip + .Lmode_post]
    call str_eq_cstr
    test eax, eax
    jnz 90f
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 8]
    call strlen
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 8]
    mov rsi, rax
    lea rdx, [rip + .Lmode_lock]
    call str_eq_cstr
    test eax, eax
    jnz 97f
    jmp 9f
46: # classify FILE
    mov rax, [rip + g_argv]
    mov rdi, [rax + 16]
    mov r13, rdi
    call file_read_all
    test rax, rax
    jz 9f
    mov r14, rax
    mov r15, rdx
    # basename
    mov rdi, r13
    call strlen
    mov rbx, r13
    add rbx, rax
6:  cmp rbx, r13
    jbe 7f
    cmp byte ptr [rbx - 1], '/'
    je 7f
    dec rbx
    jmp 6b
7:  lea rdi, [rip + out]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, '='
    call sb_push_byte
    lea rdi, [rip + ids]
    call sb_clear
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lp_claude]
    mov ecx, 7
    call str_starts
    test eax, eax
    jz 71f
    mov rdi, r14
    mov rsi, r15
    call auth_claude_status
    jmp 75f
71: mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lp_codex]
    mov ecx, 6
    call str_starts
    test eax, eax
    jz 72f
    mov rdi, r14
    mov rsi, r15
    call auth_codex_login
    jmp 75f
72: mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + ids]
    call auth_opencode_creds
75: lea rdi, [rip + out]
    mov esi, eax
    call sb_push_u64
    cmp qword ptr [rip + ids + SB_len], 0
    je 76f
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [rip + ids + SB_ptr]
    mov rdx, [rip + ids + SB_len]
    call sb_push
76: lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    jmp 9f
80: # preflight AGENT [MS]
    mov rax, [rip + g_argv]
    mov rdi, [rax + 24]
    test rdi, rdi
    jz 81f
    call strlen
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 24]
    mov rsi, rax
    call parse_u64
    mov [rip + g_auth_preflight_ms], eax
81: mov rax, [rip + g_argv]
    mov rdi, [rax + 16]
    mov [rip + agent_name], rdi
    call agent_of
    mov edi, eax
    lea rsi, [rip + .Ldot]
    lea rdx, [rip + pf_done]
    xor ecx, ecx
    call auth_preflight
    call time_ms
    mov rbx, rax
    add rbx, 15000
82: cmp dword ptr [rip + done], 0
    jne 9f
    call time_ms
    cmp rax, rbx
    jae 9f
    mov edi, 50
    call loop_poll
    call time_ms
    mov rdi, rax
    push rdi
    push rdi
    call agent_conn_tick
    pop rdi
    pop rdi
    call agent_auth_tick
    jmp 82b
90: # post FILE
    mov rax, [rip + g_argv]
    mov rdi, [rax + 16]
    mov r13, rdi
    call file_read_all
    test rax, rax
    jz 9f
    mov r14, rax
    mov r15, rdx
    # basename
    mov rdi, r13
    call strlen
    mov rbx, r13
    add rbx, rax
86: cmp rbx, r13
    jbe 87f
    cmp byte ptr [rbx - 1], '/'
    je 87f
    dec rbx
    jmp 86b
87: lea rdi, [rip + out]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, '='
    call sb_push_byte
    lea rdi, [rip + ids]
    call sb_clear
    # dispatch by prefix: rbx basename, r14/r15 file bytes
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lp_grok_models]
    mov ecx, 12
    call str_starts
    test eax, eax
    jz 91f
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + ids]
    call auth_grok_models
    mov r13, rax
    lea rdi, [rip + out]
    mov rsi, [rip + ids + SB_ptr]
    mov rdx, [rip + ids + SB_len]
    call sb_push
    test r13, r13
    jnz 96f
    cmp qword ptr [rip + ids + SB_len], 0   # not classified: "?" after the names
    je 89f
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
89: lea rdi, [rip + out]
    mov esi, '?'
    call sb_push_byte
    jmp 96f
91: mov rdi, r14
    mov rsi, r15
    call json_parse
    mov r13, rax
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lp_claude_init]
    mov ecx, 12
    call str_starts
    test eax, eax
    jz 92f
    mov rdi, r13
    call auth_claude_init
    jmp 95f
92: mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lp_codex_account]
    mov ecx, 14
    call str_starts
    test eax, eax
    jz 93f
    mov rdi, r13
    call auth_codex_account
    jmp 95f
93: mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lp_grok_init]
    mov ecx, 10
    call str_starts
    test eax, eax
    jz 94f
    mov rdi, r13
    call auth_grok_init
    jmp 95f
94: mov rdi, r13
    lea rsi, [rip + .Lids_openai]
    lea rdx, [rip + .Lsmall]
    lea rcx, [rip + ids]
    call auth_opencode_config
95: lea rdi, [rip + out]
    mov esi, eax
    call sb_push_u64
    cmp qword ptr [rip + ids + SB_len], 0
    je 96f
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [rip + ids + SB_ptr]
    mov rdx, [rip + ids + SB_len]
    call sb_push
96: lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    jmp 9f
97: # lock
    lea rdi, [rip + out]
    lea rsi, [rip + .Lids_two]
    lea rdx, [rip + .Lsmall]
    call auth_opencode_lock
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
9:  mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE

# pf_done(ctx, result, ptr, len)
pf_done:
    PROLOGUE
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    lea rdi, [rip + out]
    lea rsi, [rip + .Lev_preflight]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, [rip + agent_name]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, '='
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, r12d
    call sb_push_u64
    lea rdi, [rip + ids]
    mov rsi, [rip + g_auth_ids + SB_ptr]
    mov rdx, [rip + g_auth_ids + SB_len]
    call sb_push
    cmp qword ptr [rip + ids + SB_len], 0
    je 1f
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [rip + ids + SB_ptr]
    mov rdx, [rip + ids + SB_len]
    call sb_push
1:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov dword ptr [rip + done], 1
    EPILOGUE
