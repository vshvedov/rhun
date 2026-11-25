# Repeated configuration reads must release their input and replace custom keys.
.include "rhun.inc"
.text
FN main
    PROLOGUE
    call config_load
    mov r12, [rip + g_mem_live]
    mov r13d, 64
1:  call config_load
    cmp [rip + g_mem_live], r12
    jne .Lfail
    cmp dword ptr [rip + cfg_tab_width], 3
    jne .Lfail
    cmp dword ptr [rip + cfg_multi_cursor_paste], 1
    jne .Lfail
    cmp qword ptr [rip + g_keylines + VEC_len], 1
    jne .Lfail
    mov rax, [rip + g_keylines + VEC_ptr]
    mov rdi, [rax]
    mov rsi, [rax + 8]
    lea rdx, [rip + key]
    call str_eq_cstr
    test eax, eax
    jz .Lfail
    mov rax, [rip + g_keylines + VEC_ptr]
    mov rdi, [rax + 16]
    mov rsi, [rax + 24]
    lea rdx, [rip + command]
    call str_eq_cstr
    test eax, eax
    jz .Lfail
    call claude_check
    test eax, eax
    jz .Lfail
    dec r13d
    jnz 1b
    lea rdi, [rip + ok]
    call log_cstr
    xor eax, eax
    EPILOGUE
.Lfail:
    mov eax, 1
    EPILOGUE

# claude_check() -> eax 1 when [claude] and [agents] idle_stop_minutes read as the file says; what it
#   allocates it frees, so the next read's count still holds
claude_check:
    PROLOGUE 32
    xor ebx, ebx
    cmp dword ptr [rip + cfg_claude_chat], 0
    jne 9f
    cmp dword ptr [rip + cfg_claude_initial_mode], 1      # manual is default
    jne 9f
    cmp dword ptr [rip + cfg_agents_idle_stop], 15
    jne 9f
    mov rdi, [rip + cfg_claude_executable]
    lea rsi, [rip + executable]
    call strcmp_eq
    test eax, eax
    jz 9f
    mov rdi, [rip + cfg_claude_wrapper]
    lea rsi, [rip + wrapper]
    call strcmp_eq
    test eax, eax
    jz 9f
    lea rdi, [rsp]
    xor esi, esi
    mov edx, SB_SIZE
    call memset
    lea rdi, [rsp]
    call claudecfg_dump
    lea rdi, [rsp]
    call claudecfg_save
    lea rdi, [rsp]
    call claude_dir
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    lea rdx, [rip + pairs]
    call str_eq_cstr
    mov ebx, eax
    lea rdi, [rsp]
    call sb_free
9:  mov eax, ebx
    EPILOGUE

.section .rodata
executable: .asciz "/opt/claude/bin/claude"
wrapper: .asciz "/usr/bin/env"
pairs: .ascii "claude.env.FOO=(set)\nclaude.env.CLAUDE_CONFIG_DIR=(set)\n"
       .ascii "env.FOO = replaced\nenv.CLAUDE_CONFIG_DIR = /tmp/claude-config\n"
       .asciz "/tmp/claude-config"
key: .asciz "ctrl+q"
command: .asciz "quit"
ok: .asciz "ok\n"
