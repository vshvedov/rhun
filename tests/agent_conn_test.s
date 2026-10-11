# agent_conn_test SCENARIO SCRIPT: a connection to "python3 SCRIPT SCENARIO", events printed as they come
.include "rhun.inc"
.bss
.p2align 3
conn: .zero CN_SIZE
line: .zero SB_SIZE
argv: .zero 8 * 4
closed: .long 0
scenario: .quad 0
ready: .long 0              # the "ready" line arrived (stop, linger)
.text

# scen_is(cstr) -> 1 if the scenario is cstr
scen_is:
    push rdi
    mov rdi, [rip + scenario]
    call strlen
    mov rdi, [rip + scenario]
    mov rsi, rax
    pop rdx
    jmp str_eq_cstr

on_line:                    # (conn, ptr, len)
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    lea rsi, [rip + .Lev_line]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov rsi, r13
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, ':'
    call sb_push_byte
    mov rdx, r13
    cmp rdx, 40
    jbe 1f
    mov edx, 40
1:  lea rdi, [rip + line]
    mov rsi, r12
    call sb_push
    lea rdi, [rip + line]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + line + SB_ptr]
    mov rsi, [rip + line + SB_len]
    call log_write
    # "ready" wakes the stop and linger scenarios
    cmp r13, 5
    jne 9f
    mov rdi, r12
    mov esi, 5
    lea rdx, [rip + .Lready]
    call str_eq_cstr
    mov [rip + ready], eax
9:  EPILOGUE

on_close:                   # (conn, err)
    PROLOGUE
    mov r12d, esi
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    lea rsi, [rip + .Lev_close]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov esi, r12d
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + line]
    mov esi, [rip + conn + CN_exit]
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + line + SB_ptr]
    mov rsi, [rip + line + SB_len]
    call log_write
    mov dword ptr [rip + closed], 1
    EPILOGUE

# pump(ms): poll and tick for about ms milliseconds, or until closed
pump:
    PROLOGUE
    mov r12, rdi
    call time_ms
    lea rbx, [rax + r12]
1:  cmp dword ptr [rip + closed], 0
    jne 9f
    call time_ms
    cmp rax, rbx
    jae 9f
    mov edi, 50
    call loop_poll
    call time_ms
    mov rdi, rax
    call agent_conn_tick
    jmp 1b
9:  EPILOGUE

FN main
    PROLOGUE 16
    mov rax, [rip + g_argv]
    mov rdi, [rax + 8]
    mov [rip + scenario], rdi
    lea rdi, [rip + .Lpython]
    call proc_which
    mov rbx, rax
    lea rdi, [rip + .Lspawnfail]
    call scen_is
    test eax, eax
    jz 1f
    lea rbx, [rip + .Lnowhere]      # a path that does not exist
1:  lea rax, [rip + argv]
    mov [rax], rbx
    mov rcx, [rip + g_argv]
    mov rdx, [rcx + 16]
    mov [rax + 8], rdx
    mov rdx, [rip + scenario]
    mov [rax + 16], rdx
    mov qword ptr [rax + 24], 0
    lea rdi, [rip + conn]
    lea rax, [rip + on_line]
    mov [rdi + CN_on_line], rax
    lea rax, [rip + on_close]
    mov [rdi + CN_on_close], rax
    lea rsi, [rip + argv]
    mov rdx, [rip + g_envp]
    xor ecx, ecx
    call conn_open
    test eax, eax
    jnz 2f
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    lea rsi, [rip + .Lev_open0]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov esi, [rip + conn + CN_err]
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + line + SB_ptr]
    mov rsi, [rip + line + SB_len]
    call log_write
    jmp 8f
2:  # scenario stimulus (Tasks 6 and 7 add cases here)
    mov edi, 20000
    call pump
    # the stderr tail: its length and last 5 bytes
    lea rdi, [rip + .Lstderr]
    call scen_is
    test eax, eax
    jz 3f
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    lea rsi, [rip + .Lev_err]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov rsi, [rip + conn + CN_ebuf + SB_len]
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, ':'
    call sb_push_byte
    mov rsi, [rip + conn + CN_ebuf + SB_ptr]
    add rsi, [rip + conn + CN_ebuf + SB_len]
    sub rsi, 5
    lea rdi, [rip + line]
    mov edx, 5
    call sb_push
    mov rdi, [rip + line + SB_ptr]
    mov rsi, [rip + line + SB_len]
    call log_write
3:  lea rdi, [rip + conn]
    call conn_close
8:  xor eax, eax
    EPILOGUE
.section .rodata
.Lpython: .asciz "python3"
.Lnowhere: .asciz "/nonexistent/rhun-test-agent"
.Lspawnfail: .asciz "spawnfail"
.Lstderr: .asciz "stderr"
.Lready: .asciz "ready"
.Lev_line: .asciz "line:"
.Lev_close: .asciz "close:"
.Lev_open0: .asciz "open=0 err="
.Lev_err: .asciz "stderr:"
