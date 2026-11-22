# agent_conn_test SCENARIO SCRIPT: a connection to "python3 SCRIPT SCENARIO" (src/app/agent_conn.s),
# events printed as they come. Some scenarios run another of the fake agent's: watchfull, watchlate,
# reopen and breaklast run exit; guard runs fill. The stop sequence's times are shortened through the
# globals: stop kills after 300 ms, linger stops 1 s after the end of stdout.
# breaklast never dispatches a poll: it waits for the child's exit on its stderr alone, stops the
# connection, and the tick reaps the child; reap delivers what stdout still holds, and the callback for
# the unterminated last line breaks the connection (CN_E_READ) after the child was reaped.
# watchfull and watchlate fill the watch table with dummy watches on plain numbers from 1000 (watch_add
# only stores them) so that the open's second or third watch fails, remove them, and count what is left.
.include "rhun.inc"
.bss
.p2align 3
conn: .zero CN_SIZE
line: .zero SB_SIZE
argv: .zero 8 * 4
closed: .long 0
ready: .long 0              # the "ready" line arrived (stop, linger)
ndummy: .long 0             # dummy watches registered
.p2align 3
scenario: .quad 0
child: .quad 0              # the fake agent's scenario
pfd: .zero 8
.p2align 3
guards: .zero CN_SIZE * 4
.text

noop:
    ret

# scen_is(cstr) -> eax 1 if the scenario is cstr
scen_is:
    push rdi
    mov rdi, [rip + scenario]
    call strlen
    mov rdi, [rip + scenario]
    mov rsi, rax
    pop rdx
    jmp str_eq_cstr

# emit(): the line buffer to stderr
emit:
    sub rsp, 8
    mov rdi, [rip + line + SB_ptr]
    mov rsi, [rip + line + SB_len]
    call log_write
    add rsp, 8
    ret

# report(prefix, n): "<prefix><n>"
report:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + line]
    mov rsi, r12
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, 10
    call sb_push_byte
    call emit
    EPILOGUE

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
    call emit
    cmp r13, 5
    jne 9f
    mov rdi, r12
    mov esi, 5
    lea rdx, [rip + .Lready]
    call str_eq_cstr
    test eax, eax
    jz 2f
    mov dword ptr [rip + ready], 1
2:  mov rdi, r12                # breaklast: the unterminated last line breaks the connection
    mov esi, 5
    lea rdx, [rip + .Lthree]
    call str_eq_cstr
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lbreaklast]
    call scen_is
    test eax, eax
    jz 9f
    lea rdi, [rip + conn]
    mov esi, CN_E_READ
    call conn_break
9:  EPILOGUE

on_close:                   # (conn, err): "close:<err>:<CN_exit>"
    PROLOGUE
    mov rbx, rdi
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
    mov esi, [rbx + CN_exit]
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, 10
    call sb_push_byte
    call emit
    mov dword ptr [rip + closed], 1
    EPILOGUE

# step(): one pass of the loop: poll (50 ms at most), then the ticks
step:
    sub rsp, 8
    mov edi, 50
    call loop_poll
    call agent_conn_tick
    call uproc_tick
    add rsp, 8
    ret

# pump(ms): steps for about ms milliseconds, or until closed
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
    call step
    jmp 1b
9:  EPILOGUE

# wait_ready(): steps until the "ready" line arrived (5 s at most)
wait_ready:
    PROLOGUE
    call time_ms
    lea rbx, [rax + 5000]
1:  cmp dword ptr [rip + ready], 0
    jne 9f
    cmp dword ptr [rip + closed], 0
    jne 9f
    call time_ms
    cmp rax, rbx
    jae 9f
    call step
    jmp 1b
9:  EPILOGUE

# dummies(n): n more watches on the plain numbers 1000 + ndummy
dummies:
    PROLOGUE
    mov ebx, edi
1:  test ebx, ebx
    jz 9f
    mov edi, [rip + ndummy]
    add edi, 1000
    mov esi, POLLIN
    lea rdx, [rip + noop]
    xor ecx, ecx
    call watch_add
    inc dword ptr [rip + ndummy]
    dec ebx
    jmp 1b
9:  EPILOGUE

# undummies(): every dummy watch removed
undummies:
    PROLOGUE
1:  cmp dword ptr [rip + ndummy], 0
    je 9f
    dec dword ptr [rip + ndummy]
    mov edi, [rip + ndummy]
    add edi, 1000
    call watch_remove
    jmp 1b
9:  EPILOGUE

# open_on(conn) -> conn_open's result for the fake agent in argv, with this test's callbacks
open_on:
    lea rax, [rip + on_line]
    mov [rdi + CN_on_line], rax
    lea rax, [rip + on_close]
    mov [rdi + CN_on_close], rax
    lea rsi, [rip + argv]
    mov rdx, [rip + g_envp]
    xor ecx, ecx
    jmp conn_open

# report_open(conn, result): "open=<result> err=<CN_err>"
report_open:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    lea rsi, [rip + .Lev_open]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov rsi, r12
    call sb_push_u64
    lea rdi, [rip + line]
    lea rsi, [rip + .Lev_err_eq]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov esi, [rbx + CN_err]
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, 10
    call sb_push_byte
    call emit
    EPILOGUE

# big(n) -> rax n bytes of 'y' then a newline (n + 1 bytes, mem_alloc'd)
big:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rbx + 1]
    call mem_alloc
    mov r12, rax
    mov rdi, rax
    mov esi, 'y'
    mov rdx, rbx
    call memset
    mov byte ptr [r12 + rbx], 10
    mov rax, r12
    EPILOGUE

FN main
    PROLOGUE 16
    mov rax, [rip + g_argv]
    mov rdi, [rax + 8]
    mov [rip + scenario], rdi
    mov [rip + child], rdi
    lea rdi, [rip + .Lpython]
    call proc_which
    mov rbx, rax
    lea rdi, [rip + .Lwatchfull]
    call scen_is
    mov r12d, eax
    lea rdi, [rip + .Lwatchlate]
    call scen_is
    or r12d, eax
    lea rdi, [rip + .Lreopen]
    call scen_is
    or r12d, eax
    lea rdi, [rip + .Lbreaklast]
    call scen_is
    or r12d, eax
    jz 1f
    lea rax, [rip + .Lexit]
    mov [rip + child], rax
1:  lea rdi, [rip + .Lguard]
    call scen_is
    test eax, eax
    jz 2f
    lea rax, [rip + .Lfill]
    mov [rip + child], rax
2:  lea rdi, [rip + .Lspawnfail]
    call scen_is
    test eax, eax
    jz 3f
    lea rbx, [rip + .Lnowhere]      # a path that does not exist
3:  lea rax, [rip + argv]
    mov [rax], rbx
    mov rcx, [rip + g_argv]
    mov rdx, [rcx + 16]
    mov [rax + 8], rdx
    mov rdx, [rip + child]
    mov [rax + 16], rdx
    mov qword ptr [rax + 24], 0
    lea rdi, [rip + .Lwatchfull]
    call scen_is
    test eax, eax
    jnz .Lt_watchfull
    lea rdi, [rip + .Lwatchlate]
    call scen_is
    test eax, eax
    jnz .Lt_watchlate
    lea rdi, [rip + .Lguard]
    call scen_is
    test eax, eax
    jnz .Lt_guard
    lea rdi, [rip + .Lreopen]
    call scen_is
    test eax, eax
    jnz .Lt_reopen
    lea rdi, [rip + .Lbreaklast]
    call scen_is
    test eax, eax
    jnz .Lt_breaklast
    lea rdi, [rip + .Lstop]
    call scen_is
    test eax, eax
    jz 4f
    mov dword ptr [rip + g_conn_kill_ms], 300
4:  lea rdi, [rip + .Llinger]
    call scen_is
    test eax, eax
    jz 5f
    mov dword ptr [rip + g_conn_eof_ms], 1000
5:  lea rdi, [rip + conn]
    call open_on
    test eax, eax
    jnz 6f
    lea rdi, [rip + conn]
    xor esi, esi
    call report_open
    jmp .Lmain_done
6:  lea rdi, [rip + .Lecho]
    call scen_is
    test eax, eax
    jz .Lm_fill
    # a short line, a 200 KiB line (longer than any pipe buffer), then the end of input
    lea rdi, [rip + conn]
    lea rsi, [rip + .Lhello]
    mov edx, 6
    call conn_write
    mov edi, 204800
    call big
    lea rdi, [rip + conn]
    mov rsi, rax
    mov edx, 204801
    call conn_write
    lea rdi, [rip + conn]
    call conn_end_input
    jmp .Lm_pump
.Lm_fill:
    lea rdi, [rip + .Lfill]
    call scen_is
    test eax, eax
    jz .Lm_stop
    # 2 MiB chunks until the queue refuses; then a short stall limit
    mov edi, 2 << 20
    call mem_alloc
    mov r12, rax
    mov rdi, rax
    mov esi, 'z'
    mov edx, 2 << 20
    call memset
    xor r13d, r13d
1:  inc r13d
    lea rdi, [rip + conn]
    mov rsi, r12
    mov edx, 2 << 20
    call conn_write
    test eax, eax
    jnz 1b
    lea rdi, [rip + .Lev_refused]
    mov esi, r13d
    call report
    mov dword ptr [rip + g_conn_stall_ms], 500
    jmp .Lm_pump
.Lm_stop:
    lea rdi, [rip + .Lstop]
    call scen_is
    test eax, eax
    jz .Lm_linger
    # it ignores SIGTERM: SIGKILL follows after the shortened g_conn_kill_ms
    call wait_ready
    lea rdi, [rip + conn]
    call conn_stop
    jmp .Lm_pump
.Lm_linger:
    lea rdi, [rip + .Llinger]
    call scen_is
    test eax, eax
    jz .Lm_pump
    # stdout closes but the child runs on: still up 300 ms on, stopped after g_conn_eof_ms
    call wait_ready
    mov edi, 300
    call pump
    lea rdi, [rip + .Lev_state]
    mov esi, [rip + conn + CN_state]
    call report
.Lm_pump:
    mov edi, 20000
    call pump
    lea rdi, [rip + .Lstderr]
    call scen_is
    test eax, eax
    jz 7f
    # the stderr tail: its length and last 5 bytes
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
    call emit
7:  lea rdi, [rip + conn]
    call conn_close
.Lmain_done:
    # nothing outlives the test
    call agent_conn_shutdown
    call uproc_quit_begin
    call uproc_quit_end
    xor eax, eax
    EPILOGUE

.Lt_watchfull:
    # one free slot: stdout's watch fits, stderr's does not
    mov edi, MAX_WATCH - 1
    jmp 1f
.Lt_watchlate:
    # two free slots: stdout's and stderr's watches fit, stdin's does not
    mov edi, MAX_WATCH - 2
1:  call dummies
    lea rdi, [rip + conn]
    call open_on
    mov r12d, eax
    call undummies
    lea rdi, [rip + conn]
    mov esi, r12d
    call report_open
    call watch_count
    lea rdi, [rip + .Lev_watches]
    mov esi, eax
    call report
    lea rdi, [rip + conn]
    call conn_close
    jmp .Lmain_done

.Lt_guard:
    # g_conn_max connections, then one more: refused with CN_E_GUARD
    mov dword ptr [rip + g_conn_max], 3
    xor r12d, r12d              # connections open
1:  cmp r12d, 3
    jae 2f
    imul eax, r12d, CN_SIZE
    lea rdi, [rip + guards]
    add rdi, rax
    mov r13, rdi
    call open_on
    test eax, eax
    jz 3f
    inc r12d
    jmp 1b
3:  mov rdi, r13                # one of the first three failed: show why
    xor esi, esi
    call report_open
    jmp 4f
2:  lea rdi, [rip + guards + CN_SIZE * 3]
    call open_on
    lea rdi, [rip + guards + CN_SIZE * 3]
    mov esi, eax
    call report_open
4:  xor r13d, r13d
5:  cmp r13d, 4
    jae .Lmain_done
    imul eax, r13d, CN_SIZE
    lea rdi, [rip + guards]
    add rdi, rax
    call conn_close
    inc r13d
    jmp 5b

.Lt_reopen:
    # the child exits (CN_DEAD after on_close); conn_open again on the same struct, no conn_close between
    lea rdi, [rip + conn]
    call open_on
    test eax, eax
    jz 1f
    mov edi, 20000
    call pump
    mov dword ptr [rip + closed], 0
    lea rdi, [rip + conn]
    call open_on
    test eax, eax
    jz 1f
    mov edi, 20000
    call pump
    lea rdi, [rip + conn]
    call conn_close
    jmp .Lmain_done
1:  lea rdi, [rip + conn]
    xor esi, esi
    call report_open
    jmp .Lmain_done

.Lt_breaklast:
    lea rdi, [rip + conn]
    call open_on
    test eax, eax
    jz 3f
    # the child has exited once its stderr is at its end (it writes nothing there)
    mov eax, [rip + conn + CN_fd_err]
    mov [rip + pfd], eax
    mov dword ptr [rip + pfd + 4], POLLIN
    lea rdi, [rip + pfd]
    mov esi, 1
    mov edx, 10000
    SYS SYS_poll
    lea rdi, [rip + conn]
    call conn_stop
    call time_ms
    lea r12, [rax + 20000]
1:  cmp dword ptr [rip + closed], 0
    jne 2f
    call time_ms
    cmp rax, r12
    jae 2f
    xor edi, edi                # poll on no descriptors: a 50 ms sleep that dispatches nothing
    xor esi, esi
    mov edx, 50
    SYS SYS_poll
    call agent_conn_tick
    jmp 1b
2:  lea rdi, [rip + conn]
    call conn_close
    jmp .Lmain_done
3:  lea rdi, [rip + conn]
    xor esi, esi
    call report_open
    jmp .Lmain_done

.section .rodata
.Lpython: .asciz "python3"
.Lbreaklast: .asciz "breaklast"
.Lthree: .asciz "three"
.Lnowhere: .asciz "/nonexistent/rhun-test-agent"
.Lspawnfail: .asciz "spawnfail"
.Lstderr: .asciz "stderr"
.Lecho: .asciz "echo"
.Lfill: .asciz "fill"
.Lstop: .asciz "stop"
.Llinger: .asciz "linger"
.Lexit: .asciz "exit"
.Lwatchfull: .asciz "watchfull"
.Lwatchlate: .asciz "watchlate"
.Lguard: .asciz "guard"
.Lreopen: .asciz "reopen"
.Lready: .asciz "ready"
.Lhello: .asciz "hello\n"
.Lev_open: .asciz "open="
.Lev_err_eq: .asciz " err="
.Lev_refused: .asciz "refused_at:"
.Lev_line: .asciz "line:"
.Lev_close: .asciz "close:"
.Lev_err: .asciz "stderr:"
.Lev_state: .asciz "state:"
.Lev_watches: .asciz "watches:"
