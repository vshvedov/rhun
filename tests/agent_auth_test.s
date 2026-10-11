# agent_auth_test MODE ...: env AGENT prints the scrubbed environment and the lock arguments;
# classify FILE prints <basename>=<AUTH_*>[ ids], the classifier picked by the name's prefix
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
ids: .zero SB_SIZE
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
.Lp_claude: .ascii "claude-"
.Lp_codex: .ascii "codex-"
.Llock: .asciz "lock:"
.text

# agent_of(cstr) -> kind or 0
agent_of:
    PROLOGUE
    mov rbx, rdi
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
    jz 9f
    # classify FILE
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
9:  mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE
