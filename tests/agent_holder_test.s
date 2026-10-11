# agent_holder_test KIND SID [OWNPID]: the holder answer for a session
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
.section .rodata
.Lclaude: .asciz "claude"
.Lholder: .asciz "holder="
.text
FN main
    PROLOGUE
    mov rax, [rip + g_argv]
    mov rdi, [rax + 24]
    test rdi, rdi
    jz 1f
    call strlen
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 24]
    mov rsi, rax
    call parse_u64
    mov edi, eax
    call holder_own_add
1:  mov rax, [rip + g_argv]
    mov rdi, [rax + 8]
    call strlen
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 8]
    mov rsi, rax
    lea rdx, [rip + .Lclaude]
    call str_eq_cstr
    mov rcx, [rip + g_argv]
    mov rdi, [rcx + 16]
    test eax, eax
    jz 2f
    call holder_claude
    jmp 3f
2:  call holder_grok
3:  mov ebx, eax
    lea rdi, [rip + out]
    lea rsi, [rip + .Lholder]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, ebx
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE
