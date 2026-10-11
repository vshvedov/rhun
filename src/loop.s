# event loop: fd watchers + platform/app timers
.include "rhun.inc"

.bss
.p2align 3
watches: .zero PW_SIZE * MAX_WATCH
nwatch: .long 0
.p2align 3
pollfds: .zero 8 * MAX_WATCH
.globl g_plat, g_quit, g_dirty
g_plat: .zero PLAT_SIZE
g_quit: .long 0
g_dirty: .long 0

.text

# watch_add(fd, events, handler, ctx) -> 1, or 0 when the table is full
FN watch_add
    mov eax, [rip + nwatch]
    cmp eax, MAX_WATCH
    jae 1f
    imul eax, eax, PW_SIZE
    lea r9, [rip + watches]
    add r9, rax
    mov [r9 + PW_fd], edi
    mov [r9 + PW_events], esi
    mov [r9 + PW_handler], rdx
    mov [r9 + PW_ctx], rcx
    inc dword ptr [rip + nwatch]
    mov eax, 1
    ret
1:  xor eax, eax
    ret

# watch_remove(fd)
FN watch_remove
    lea r8, [rip + watches]
    xor ecx, ecx
1:  cmp ecx, [rip + nwatch]
    jae 3f
    imul eax, ecx, PW_SIZE
    cmp [r8 + rax + PW_fd], edi
    je 2f
    inc ecx
    jmp 1b
2:  # move last into this slot
    dec dword ptr [rip + nwatch]
    mov edx, [rip + nwatch]
    imul edx, edx, PW_SIZE
    mov r9, [r8 + rdx]
    mov [r8 + rax], r9
    mov r9, [r8 + rdx + 8]
    mov [r8 + rax + 8], r9
    mov r9, [r8 + rdx + 16]
    mov [r8 + rax + 16], r9
3:  ret

# watch_set_events(fd, events)
FN watch_set_events
    lea r8, [rip + watches]
    xor ecx, ecx
1:  cmp ecx, [rip + nwatch]
    jae 2f
    imul eax, ecx, PW_SIZE
    cmp [r8 + rax + PW_fd], edi
    jne 3f
    mov [r8 + rax + PW_events], esi
3:  inc ecx
    jmp 1b
2:  ret

FN loop_run
    PROLOGUE 16
.Llr_loop:
    cmp dword ptr [rip + g_quit], 0
    jne .Llr_ret
    cmp dword ptr [rip + g_dirty], 0
    je 1f
    PCALL P_draw
1:  PCALL P_flush
    # timeout = min(plat, app)
    PCALL P_timeout
    mov ebx, eax
    call app_timeout
    cmp ebx, -1
    je 2f
    cmp eax, -1
    je 3f
    cmp eax, ebx
    jl 2f
3:  mov eax, ebx
2:  mov edi, eax
    call loop_poll
    PCALL P_tick
    call app_tick
    jmp .Llr_loop
.Llr_ret:
    EPILOGUE

# loop_poll(timeout_ms): wait for watched fds (-1 forever, 0 not at all), run their handlers
FN loop_poll
    PROLOGUE
    mov r15d, edi
    # pollfd array
    xor ecx, ecx
    lea r8, [rip + watches]
    lea r9, [rip + pollfds]
4:  cmp ecx, [rip + nwatch]
    jae 5f
    imul eax, ecx, PW_SIZE
    mov edx, [r8 + rax + PW_fd]
    mov [r9 + rcx*8], edx
    mov edx, [r8 + rax + PW_events]
    mov [r9 + rcx*8 + 4], edx
    inc ecx
    jmp 4b
5:  lea rdi, [rip + pollfds]
    mov esi, [rip + nwatch]
    movsxd rdx, r15d
    SYS SYS_poll
    test rax, rax
    js .Llp_ret
    # dispatch; iterate backwards so removals during handlers are safe
    mov r12d, [rip + nwatch]
.Llp_disp:
    dec r12d
    js .Llp_ret
    lea r9, [rip + pollfds]
    movzx esi, word ptr [r9 + r12*8 + 6]
    test esi, esi
    jz .Llp_disp
    mov edi, [r9 + r12*8]
    # find watch by fd (array may have changed)
    lea r8, [rip + watches]
    xor ecx, ecx
6:  cmp ecx, [rip + nwatch]
    jae .Llp_disp
    imul eax, ecx, PW_SIZE
    cmp [r8 + rax + PW_fd], edi
    je 7f
    inc ecx
    jmp 6b
7:  mov rdx, [r8 + rax + PW_ctx]
    call [r8 + rax + PW_handler]
    jmp .Llp_disp
.Llp_ret:
    EPILOGUE
