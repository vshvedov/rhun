# agent_auth_test MODE ...: env AGENT prints the scrubbed environment and the lock arguments
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
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
    jz 9f
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
9:  mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE
