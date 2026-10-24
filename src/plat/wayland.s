# native wayland client: wire protocol over a unix socket, no libwayland
.include "rhun.inc"
.include "plat/wayland.inc"

.equ OUTSZ, 65536
.equ INSZ, 65536
.equ MAXFDQ, WCF_COUNT
.equ WCL_LIMIT, 67108864
.equ WCL_TIMEOUT, 30000

# wl_shm format
.equ WL_SHM_XRGB8888, 1

.bss
.p2align 4
out_buf: .zero OUTSZ
.globl wl_wire_input, wl_wire_input_len, wl_wire_fdqueue_len, wl_wire_next_id
wl_wire_input:
in_buf: .zero INSZ
wl_paste_wire_output_len:
out_len: .long 0
wl_wire_input_len:
in_len: .long 0
msg_start: .long 0
.globl wl_paste_wire_fd, wl_paste_wire_output_len
wl_paste_wire_fd:
wl_fd: .long 0
wl_wire_next_id:
next_id: .long 0
free_ids: .zero 4 * 256
free_n: .long 0
fdq: .zero 4 * MAXFDQ
wl_wire_fdqueue_len:
fdq_n: .long 0
.p2align 3
cmsg_buf: .zero 256
msghdr: .zero 56
iov: .zero 16
sockaddr: .zero 110

# globals (object ids / names)
id_registry: .long 0
id_compositor: .long 0
id_shm: .long 0
id_wm_base: .long 0
wl_wire_seat:
id_seat: .long 0
.globl wl_send_manager
wl_send_manager:
id_ddm: .long 0
id_deco_mgr: .long 0
id_cursor_mgr: .long 0
id_viewporter: .long 0
id_fscale_mgr: .long 0
id_activation: .long 0
activation_sent: .long 0
id_sync: .long 0
sync_done: .long 0
wl_wire_seat_version:
seat_ver: .long 0

id_surface: .long 0
id_xdg_surface: .long 0
id_toplevel: .long 0
id_deco: .long 0
id_viewport: .long 0
id_fscale: .long 0
id_pointer: .long 0
.globl wl_wire_keyboard, wl_wire_seat, wl_wire_seat_version
wl_wire_keyboard:
id_keyboard: .long 0
id_cursor_dev: .long 0
.globl wl_paste_device
wl_paste_device:
id_ddev: .long 0
id_frame_cb: .long 0
id_pool: .long 0
id_buf: .zero 8
buf_busy: .zero 8
.p2align 3
pool_mem: .quad 0
pool_size: .quad 0
buf_w: .long 0
buf_h: .long 0

configured: .long 0
pend_w: .long 0
pend_h: .long 0
pend_states: .long 0
win_w: .long 0             # logical
win_h: .long 0
scale120: .long 0          # fractional scale * 120, 0 if unused
.globl g_win_states
g_win_states: .long 0      # bit0 maximized, bit1 fullscreen, bit2 activated, bit3 tiled

last_serial: .long 0
.globl wl_send_serial_known
wl_send_serial_known:
last_serial_known: .long 0
enter_serial: .long 0
cur_shape: .long 0
ptr_x: .long 0             # fixed 24.8 logical
ptr_y: .long 0
axis_src: .long 0
.p2align 3
axis_rem: .quad 0, 0       # what is left of a pixel, vertical and horizontal

kb_group: .long 0
kb_mods: .long 0
rep_key: .long 0
.p2align 3
rep_next: .quad 0

# clipboard
.globl wl_paste_offer_new, wl_paste_offer_new_mime, wl_paste_offer, wl_paste_mime
wl_paste_offer_new:
offer_new: .long 0
wl_paste_offer_new_mime:
offer_new_text: .long 0
.globl wl_paste_offer_new_native, wl_paste_offer_native
wl_paste_offer_new_native: .long 0
wl_paste_offer:
sel_offer: .long 0
wl_paste_mime:
sel_offer_text: .long 0
wl_paste_offer_native: .long 0
.p2align 3
.globl wl_paste_offer_generation
wl_paste_offer_generation: .quad 0
.globl wl_paste_source_id
wl_paste_source_id:
id_source: .long 0
.p2align 3
.globl wl_paste_source_buffer, wl_paste_buffer, wl_paste_deadline, wl_paste_generation
wl_paste_source_buffer:
clip_sb: .zero SB_SIZE
wl_paste_buffer:
paste_sb: .zero SB_SIZE
wl_paste_deadline: .quad 0
wl_paste_generation: .quad 0
.globl wl_paste_token
wl_paste_token: .quad 0
.globl wl_paste_format, wl_paste_attempt_offer, wl_paste_attempt_generation, wl_paste_plain
wl_paste_format: .long 0
wl_paste_attempt_offer: .long 0
wl_paste_attempt_generation: .quad 0
wl_paste_plain: .long 0
.globl wl_send_sources, wl_send_jobs, wl_send_charge
wl_send_sources: .zero WCS_SIZE * WCS_COUNT
wl_send_jobs: .zero WCJ_SIZE * WCJ_COUNT
wl_send_charge: .quad 0
wl_send_generation: .quad 0
retired_keyboards: .zero 4 * WCK_COUNT

.text

# ---------------- message building ----------------

wl_new_id:
    mov ecx, [rip + free_n]
    test ecx, ecx
    jz 1f
    dec ecx
    mov [rip + free_n], ecx
    lea rax, [rip + free_ids]
    mov eax, [rax + rcx*4]
    ret
1:  mov eax, [rip + next_id]
    inc dword ptr [rip + next_id]
    ret

# wl_begin(obj, opcode)
wl_begin:
    mov eax, [rip + out_len]
    cmp eax, OUTSZ - 4096
    jb 1f
    push rdi
    push rsi
    call wl_flush
    pop rsi
    pop rdi
    mov eax, [rip + out_len]
1:  mov [rip + msg_start], eax
    lea rcx, [rip + out_buf]
    mov [rcx + rax], edi
    mov [rcx + rax + 4], esi
    add eax, 8
    mov [rip + out_len], eax
    ret

# wl_put(u32)
wl_put:
    mov eax, [rip + out_len]
    lea rcx, [rip + out_buf]
    mov [rcx + rax], edi
    add eax, 4
    mov [rip + out_len], eax
    ret

# wl_put_str(cstr)
wl_put_str:
    push rbx
    mov rbx, rdi
    call strlen
    lea edi, [rax + 1]
    push rdi
    call wl_put
    pop rdx
    mov eax, [rip + out_len]
    lea rdi, [rip + out_buf]
    add rdi, rax
    mov rsi, rbx
    mov ecx, edx
    rep movsb
    mov ecx, edx
    neg ecx
    and ecx, 3
    xor eax, eax
    rep stosb
    add edx, 3
    and edx, -4
    add [rip + out_len], edx
    pop rbx
    ret

# wl_end(): patch size into header
wl_end:
    mov eax, [rip + msg_start]
    mov ecx, [rip + out_len]
    sub ecx, eax
    shl ecx, 16
    lea rdx, [rip + out_buf]
    or [rdx + rax + 4], ecx
    ret

.macro MSG obj, op
    mov edi, \obj
    mov esi, \op
    call wl_begin
.endm
.macro ARG v
    mov edi, \v
    call wl_put
.endm
.macro SARG label
    lea rdi, [rip + \label]
    call wl_put_str
.endm
.macro END
    call wl_end
.endm

# wl_flush_fd(fd or -1): send pending bytes, optionally with one fd
wl_flush_fd:
    push rbx
    mov ebx, edi
    lea rax, [rip + out_buf]
    mov [rip + iov], rax
    mov eax, [rip + out_len]
    mov [rip + iov + 8], rax
    lea rdi, [rip + msghdr]
    xor eax, eax
    mov ecx, 56
    rep stosb
    lea rax, [rip + iov]
    mov [rip + msghdr + 16], rax
    mov qword ptr [rip + msghdr + 24], 1
    cmp ebx, -1
    je 1f
    lea rax, [rip + cmsg_buf]
    mov qword ptr [rax], 20       # cmsg_len
    mov dword ptr [rax + 8], SOL_SOCKET
    mov dword ptr [rax + 12], SCM_RIGHTS
    mov [rax + 16], ebx
    mov [rip + msghdr + 32], rax
    mov qword ptr [rip + msghdr + 40], 24
1:  cmp dword ptr [rip + out_len], 0
    je 3f
2:  mov edi, [rip + wl_fd]
    lea rsi, [rip + msghdr]
    mov edx, MSG_NOSIGNAL
    SYS SYS_sendmsg
    cmp rax, -EINTR
    je 2b
    cmp rax, -EAGAIN
    je 2b
    test rax, rax
    js 4f
    # partial sends: drop sent bytes, continue without fd
    mov ecx, [rip + out_len]
    sub ecx, eax
    mov [rip + out_len], ecx
    jz 3f
    lea rdi, [rip + out_buf]
    lea rsi, [rdi + rax]
    rep movsb
    mov qword ptr [rip + msghdr + 32], 0
    mov qword ptr [rip + msghdr + 40], 0
    mov eax, [rip + out_len]
    mov [rip + iov + 8], rax
    jmp 2b
3:  pop rbx
    ret
4:  lea rdi, [rip + .Lsend_err]
    call die

FN wl_flush
    mov edi, -1
    jmp wl_flush_fd

# ---------------- receiving ----------------

FN wl_keyboard_is_retired
    lea rax, [rip + retired_keyboards]
    mov ecx, WCK_COUNT
1:  cmp [rax], edi
    je 3f
    add rax, 4
    dec ecx
    jnz 1b
    xor eax, eax
    ret
3:  test edi, edi
    setnz al
    movzx eax, al
    ret

FN wl_keyboard_retire
    lea rax, [rip + retired_keyboards]
    mov ecx, WCK_COUNT
1:  cmp dword ptr [rax], 0
    je 2f
    add rax, 4
    dec ecx
    jnz 1b
    lea rdi, [rip + .Ldisconnected]
    jmp die
2:  mov [rax], edi
    ret

FN wl_keyboard_deleted
    lea rax, [rip + retired_keyboards]
    mov ecx, WCK_COUNT
1:  cmp [rax], edi
    je 2f
    add rax, 4
    dec ecx
    jnz 1b
    ret
2:  mov dword ptr [rax], 0
    ret

# A descriptor may arrive later than its complete message bytes.
FN wl_message_needs_fd
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    test esi, esi
    jnz 1f
    cmp edi, [rip + id_keyboard]
    je 2f
    call wl_keyboard_is_retired
    test eax, eax
    jnz 2f
1:  xor eax, eax
    cmp r12d, 1
    jne 3f
    mov edi, ebx
    call wl_source_find
    test rax, rax
    setnz al
    movzx eax, al
    jmp 3f
2:  mov eax, 1
3:  EPILOGUE

# Collect only bounded SCM_RIGHTS and close all owned descriptors if order is lost.
FN wl_collect_fds
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r15d, edx
    and r15d, 8                  # MSG_CTRUNC
.Lwcf_next:
    test r13, r13
    jz .Lwcf_done
    cmp r13, 16
    jb .Lwcf_tail
    mov r14, [r12]
    cmp r14, 16
    jb .Lwcf_bad
    cmp r14, r13
    ja .Lwcf_bad
    cmp dword ptr [r12 + 8], SOL_SOCKET
    jne .Lwcf_advance
    cmp dword ptr [r12 + 12], SCM_RIGHTS
    jne .Lwcf_advance
    mov rax, r14
    sub rax, 16
    test eax, 3
    jz 1f
    mov r15d, 1
1:  mov ebx, 16
.Lwcf_fd:
    lea rax, [rbx + 4]
    cmp rax, r14
    ja .Lwcf_advance
    mov edi, [r12 + rbx]
    mov eax, [rip + fdq_n]
    cmp eax, MAXFDQ
    jae .Lwcf_overflow
    lea rdx, [rip + fdq]
    mov [rdx + rax*4], edi
    inc dword ptr [rip + fdq_n]
    jmp .Lwcf_fd_next
.Lwcf_overflow:
    mov r15d, 1
    SYS SYS_close
.Lwcf_fd_next:
    add rbx, 4
    jmp .Lwcf_fd
.Lwcf_advance:
    add r14, 7
    and r14, -8
    cmp r14, r13
    jae .Lwcf_done
    add r12, r14
    sub r13, r14
    jmp .Lwcf_next
.Lwcf_tail:
    cmp r13, 7
    jbe .Lwcf_done
.Lwcf_bad:
    mov r15d, 1
.Lwcf_done:
    test r15d, r15d
    jz .Lwcf_success
1:  call fdq_pop
    test eax, eax
    js 2f
    mov edi, eax
    SYS SYS_close
    jmp 1b
2:  xor eax, eax
    EPILOGUE
.Lwcf_success:
    mov eax, 1
    EPILOGUE

# wl_read(): recvmsg into in_buf, collect fds. returns bytes read (<=0 on error/eof)
wl_read:
    push rbx
    lea rax, [rip + in_buf]
    mov ecx, [rip + in_len]
    add rax, rcx
    mov [rip + iov], rax
    mov eax, INSZ
    sub eax, ecx
    jz .Lwr_capacity
    mov [rip + iov + 8], rax
    lea rdi, [rip + msghdr]
    xor eax, eax
    mov ecx, 56
    rep stosb
    lea rax, [rip + iov]
    mov [rip + msghdr + 16], rax
    mov qword ptr [rip + msghdr + 24], 1
    lea rax, [rip + cmsg_buf]
    mov [rip + msghdr + 32], rax
    mov qword ptr [rip + msghdr + 40], 256
    mov edi, [rip + wl_fd]
    lea rsi, [rip + msghdr]
    mov edx, MSG_DONTWAIT | 0x40000000   # MSG_CMSG_CLOEXEC
    SYS SYS_recvmsg
    mov rbx, rax
    test rax, rax
    jle 9f
    add [rip + in_len], eax
    lea rdi, [rip + cmsg_buf]
    mov rsi, [rip + msghdr + 40]
    mov edx, [rip + msghdr + 48]
    call wl_collect_fds
    test eax, eax
    jnz 9f
.Lwr_capacity:
    mov rbx, -71                # EPROTO, the stream cannot safely continue
9:  mov rax, rbx
    pop rbx
    ret

# fdq_pop() -> fd or -1
fdq_pop:
    mov ecx, [rip + fdq_n]
    test ecx, ecx
    jz 2f
    lea rsi, [rip + fdq]
    mov eax, [rsi]
    dec ecx
    mov [rip + fdq_n], ecx
    lea rdi, [rip + fdq]
    lea rsi, [rdi + 4]
    shl ecx, 2
    rep movsb
    ret
2:  mov eax, -1
    ret

# wl_on_readable(fd, revents, ctx)
FN wl_on_readable
    push rbx
    push r12
    push r13
    test esi, POLLIN
    jz 8f
    call wl_read
    test rax, rax
    jz 7f
    jns 1f
    cmp rax, -EAGAIN
    je 9f
    cmp rax, -EINTR
    je 9f
    jmp 7f
    # dispatch whole messages
1:  xor ebx, ebx                   # offset
.Lwor_message:
    mov eax, [rip + in_len]
    sub eax, ebx
    cmp eax, 8
    jb 5f
    lea r12, [rip + in_buf]
    add r12, rbx
    mov edx, [r12 + 4]
    shr edx, 16                    # size
    cmp edx, 8
    jb 7f
    test edx, 3
    jnz 7f
    cmp eax, edx
    jb 5f
    mov r13d, edx
    cmp dword ptr [rip + fdq_n], 0
    jne .Lwor_dispatch
    mov edi, [r12]
    movzx esi, word ptr [r12 + 4]
    call wl_message_needs_fd
    test eax, eax
    jnz 5f
.Lwor_dispatch:
    mov edi, [r12]                 # object
    movzx esi, word ptr [r12 + 4]  # opcode
    lea rdx, [r12 + 8]             # args
    lea ecx, [r13 - 8]
    call wl_dispatch
    add ebx, r13d
    jmp .Lwor_message
5:  # keep the partial tail
    mov ecx, [rip + in_len]
    sub ecx, ebx
    mov [rip + in_len], ecx
    lea rdi, [rip + in_buf]
    lea rsi, [rdi + rbx]
    rep movsb
9:  pop r13
    pop r12
    pop rbx
    ret
8:  test esi, POLLHUP | POLLERR
    jz 9b
7:  lea rdi, [rip + .Ldisconnected]
    call die

# wl_roundtrip(): sync and dispatch until done
wl_roundtrip:
    push rbx
    call wl_new_id
    mov [rip + id_sync], eax
    mov dword ptr [rip + sync_done], 0
    MSG 1, 0
    ARG [rip + id_sync]
    END
    call wl_flush
1:  cmp dword ptr [rip + sync_done], 0
    jne 2f
    # blocking poll on the socket
    sub rsp, 16
    mov eax, [rip + wl_fd]
    mov [rsp], eax
    mov dword ptr [rsp + 4], POLLIN
    mov rdi, rsp
    mov esi, 1
    mov edx, -1
    SYS SYS_poll
    movzx esi, word ptr [rsp + 6]
    add rsp, 16
    mov edi, [rip + wl_fd]
    call wl_on_readable
    jmp 1b
2:  pop rbx
    ret

# ---------------- dispatch ----------------

# wl_dispatch(obj, opcode, args, argument_length)
FN wl_dispatch
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp ebx, 1
    je .Ld_display
    cmp ebx, [rip + id_registry]
    je .Ld_registry
    cmp ebx, [rip + id_sync]
    je .Ld_sync
    cmp ebx, [rip + id_wm_base]
    je .Ld_wm_base
    cmp ebx, [rip + id_xdg_surface]
    je .Ld_xdg_surface
    cmp ebx, [rip + id_toplevel]
    je .Ld_toplevel
    cmp ebx, [rip + id_frame_cb]
    je .Ld_frame
    cmp ebx, [rip + id_buf]
    je .Ld_buf0
    cmp ebx, [rip + id_buf + 4]
    je .Ld_buf1
    cmp ebx, [rip + id_pointer]
    je .Ld_pointer
    cmp ebx, [rip + id_keyboard]
    je .Ld_keyboard
    cmp ebx, [rip + id_seat]
    je .Ld_seat
    cmp ebx, [rip + id_fscale]
    je .Ld_fscale
    cmp ebx, [rip + id_surface]
    je .Ld_surface
    cmp ebx, [rip + id_ddev]
    je .Ld_ddev
    mov edi, ebx
    call wl_source_find
    test rax, rax
    jnz .Ld_source
    mov edi, ebx
    call wl_keyboard_is_retired
    test eax, eax
    jnz .Ld_old_keyboard
    cmp ebx, [rip + offer_new]
    je .Ld_offer
    cmp ebx, [rip + id_deco]
    je .Ld_deco
    jmp .Ld_ret

.Ld_display:
    test r12d, r12d
    jnz 1f
    lea rdi, [rip + .Lproto_err]
    call log_cstr
    lea rdi, [r13 + 12]
    call log_cstr
    call log_nl
    mov edi, 1
    call sys_exit
1:  # delete_id
    cmp r12d, 1
    jne .Ld_ret
    cmp r14, 4
    jne .Ld_ret
    mov edi, [r13]
    call wl_source_deleted
    mov edi, [r13]
    call wl_keyboard_deleted
    mov eax, [r13]
    mov ecx, [rip + free_n]
    cmp ecx, 256
    jae .Ld_ret
    lea rdx, [rip + free_ids]
    mov [rdx + rcx*4], eax
    inc dword ptr [rip + free_n]
    cmp eax, [rip + id_frame_cb]
    jne .Ld_ret
    mov dword ptr [rip + id_frame_cb], 0
    jmp .Ld_ret

.Ld_sync:
    mov dword ptr [rip + sync_done], 1
    mov dword ptr [rip + id_sync], 0
    jmp .Ld_ret

.Ld_registry:
    test r12d, r12d
    jnz .Ld_ret
    mov rdi, r13
    call wl_on_global
    jmp .Ld_ret

.Ld_wm_base:
    MSG [rip + id_wm_base], 3     # pong
    ARG [r13]
    END
    jmp .Ld_ret

.Ld_xdg_surface:
    MSG [rip + id_xdg_surface], 4 # ack_configure
    ARG [r13]
    END
    call apply_configure
    jmp .Ld_ret

.Ld_toplevel:
    cmp r12d, 1
    je .Ld_close
    test r12d, r12d
    jnz .Ld_ret
    mov eax, [r13]
    mov [rip + pend_w], eax
    mov eax, [r13 + 4]
    mov [rip + pend_h], eax
    # states array
    xor edx, edx
    mov ecx, [r13 + 8]
    lea rsi, [r13 + 12]
1:  cmp ecx, 4
    jb 2f
    mov eax, [rsi]
    cmp eax, 1
    jne 3f
    or edx, 1
3:  cmp eax, 2
    jne 3f
    or edx, 2
3:  cmp eax, 4
    jne 3f
    or edx, 4
3:  cmp eax, 5
    jb 3f
    cmp eax, 8
    ja 3f
    or edx, 8
3:  add rsi, 4
    sub ecx, 4
    jmp 1b
2:  mov [rip + pend_states], edx
    jmp .Ld_ret
.Ld_close:
    call app_on_close
    jmp .Ld_ret

.Ld_deco:
    # mode 2 = server side
    xor eax, eax
    cmp dword ptr [r13], 2
    sete al
    xor eax, 1
    mov [rip + g_csd], eax
    mov dword ptr [rip + g_dirty], 1
    jmp .Ld_ret

.Ld_frame:
    mov dword ptr [rip + id_frame_cb], 0
    jmp .Ld_ret
.Ld_buf0:
    mov dword ptr [rip + buf_busy], 0
    jmp .Ld_ret
.Ld_buf1:
    mov dword ptr [rip + buf_busy + 4], 0
    jmp .Ld_ret

.Ld_seat:
    # capabilities: a keyboard or pointer can go away (unplugged, a KVM switch) and come back,
    # each time as a new object
    test r12d, r12d
    jnz .Ld_ret
    mov eax, [r13]
    test eax, 1
    jnz 2f
    cmp dword ptr [rip + id_pointer], 0
    je 1f
    cmp dword ptr [rip + id_cursor_dev], 0
    je 21f
    MSG [rip + id_cursor_dev], 0  # destroy
    END
    mov dword ptr [rip + id_cursor_dev], 0
21: cmp dword ptr [rip + seat_ver], 3
    jb 22f
    MSG [rip + id_pointer], 1     # release
    END
22: mov dword ptr [rip + id_pointer], 0
    jmp 1f
2:  cmp dword ptr [rip + id_pointer], 0
    jne 1f
    call wl_new_id
    mov [rip + id_pointer], eax
    MSG [rip + id_seat], 0
    ARG [rip + id_pointer]
    END
    cmp dword ptr [rip + id_cursor_mgr], 0
    je 1f
    call wl_new_id
    mov [rip + id_cursor_dev], eax
    MSG [rip + id_cursor_mgr], 1
    ARG [rip + id_cursor_dev]
    ARG [rip + id_pointer]
    END
1:  mov eax, [r13]
    test eax, 2
    jz 3f
    cmp dword ptr [rip + id_keyboard], 0
    jne .Ld_ret
    call wl_new_id
    mov [rip + id_keyboard], eax
    MSG [rip + id_seat], 1
    ARG [rip + id_keyboard]
    END
    jmp .Ld_ret
3:  cmp dword ptr [rip + id_keyboard], 0
    je .Ld_ret
    mov edi, [rip + id_keyboard]
    call wl_keyboard_retire
    cmp dword ptr [rip + seat_ver], 3
    jb 31f
    MSG [rip + id_keyboard], 0    # release
    END
31: mov dword ptr [rip + id_keyboard], 0
    mov dword ptr [rip + rep_key], 0
    jmp .Ld_ret

.Ld_fscale:
    mov eax, [r13]
    cmp eax, [rip + scale120]
    je .Ld_ret
    mov [rip + scale120], eax
    call apply_size
    jmp .Ld_ret

.Ld_surface:
    cmp r12d, 2                   # preferred_buffer_scale
    jne .Ld_ret
    cmp dword ptr [rip + id_fscale], 0
    jne .Ld_ret
    mov eax, [r13]
    cmp eax, [rip + int_scale]
    je .Ld_ret
    mov [rip + int_scale], eax
    MSG [rip + id_surface], 8
    ARG [rip + int_scale]
    END
    call apply_size
    jmp .Ld_ret

.Ld_pointer:
    mov rdi, r12
    mov rsi, r13
    call on_pointer
    jmp .Ld_ret
.Ld_keyboard:
    test r12d, r12d
    jnz 1f
    cmp r14, 8
    jne .Ld_old_keyboard
    cmp dword ptr [r13], 1       # XKB_V1 only; discard other keymap descriptors
    jne .Ld_old_keyboard
1:
    mov rdi, r12
    mov rsi, r13
    call on_keyboard
    jmp .Ld_ret

.Ld_ddev:
    test r12d, r12d
    jnz 1f
    cmp r14, 4
    jne .Ld_ret
    # data_offer(new id)
    mov eax, [r13]
    mov [rip + offer_new], eax
    mov dword ptr [rip + offer_new_text], 0
    mov dword ptr [rip + wl_paste_offer_new_native], 0
    jmp .Ld_ret
1:  cmp r12d, 5                   # selection
    jne 2f
    cmp r14, 4
    jne .Ld_ret
    mov eax, [r13]
    mov ecx, [rip + sel_offer]
    cmp ecx, eax
    je .Ld_ret
    test ecx, ecx
    jz 3f
    push rax
    MSG [rip + sel_offer], 2      # destroy old offer
    END
    pop rax
3:  mov [rip + sel_offer], eax
    inc qword ptr [rip + wl_paste_offer_generation]
    mov dword ptr [rip + wl_paste_offer_native], 0
    xor ecx, ecx
    cmp eax, [rip + offer_new]
    jne 4f
    mov ecx, [rip + wl_paste_offer_new_native]
    mov [rip + wl_paste_offer_native], ecx
    mov ecx, [rip + offer_new_text]
4:  mov [rip + sel_offer_text], ecx
    jmp .Ld_ret
2:  cmp r12d, 1                   # dnd enter: not supported, drop the offer
    jne .Ld_ret
    cmp r14, 20
    jne .Ld_ret
    mov eax, [r13 + 16]
    test eax, eax
    jz .Ld_ret
    MSG eax, 2
    END
    jmp .Ld_ret

.Ld_offer:
    test r12d, r12d
    jnz .Ld_ret
    mov rdi, r13
    mov rsi, r14
    call wl_paste_decode_mime
    test eax, eax
    jz .Ld_ret
    cmp eax, 4
    jne 2f
    mov dword ptr [rip + wl_paste_offer_new_native], 1
    jmp .Ld_ret
2:
    cmp dword ptr [rip + offer_new_text], 0
    je 1f
    cmp eax, [rip + offer_new_text]
    jae .Ld_ret
1:  mov [rip + offer_new_text], eax
    jmp .Ld_ret

.Ld_source:
    mov r15, rax
    cmp r12d, 1                   # send(mime, fd)
    jne 1f
    call fdq_pop
    mov ebx, eax
    test eax, eax
    js .Ld_ret
    mov rdi, r13
    mov rsi, r14
    call wl_paste_decode_mime
    mov edx, eax
    mov rdi, r15
    mov esi, ebx
    call wl_send_start
    jmp .Ld_ret
1:  cmp r12d, 2                   # cancelled
    jne .Ld_ret
    test r14, r14
    jnz .Ld_ret
    mov rdi, r15
    call wl_source_retire
    jmp .Ld_ret

.Ld_old_keyboard:
    test r12d, r12d
    jnz .Ld_ret
    call fdq_pop
    test eax, eax
    js .Ld_ret
    mov edi, eax
    SYS SYS_close
    jmp .Ld_ret

.Ld_ret:
    EPILOGUE

# Focus loss invalidates the selected offer before any application callback.
FN wl_paste_offer_clear
    PROLOGUE
    mov ebx, [rip + sel_offer]
    mov dword ptr [rip + sel_offer], 0
    mov dword ptr [rip + sel_offer_text], 0
    mov dword ptr [rip + wl_paste_offer_native], 0
    inc qword ptr [rip + wl_paste_offer_generation]
    test ebx, ebx
    jz 1f
    MSG ebx, 2
    END
1:  EPILOGUE

# Counted supported MIME name -> preference enum, zero when unsupported.
FN mime_is_text
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdx, [rip + .Lmime_utf8]
    call str_eq_cstr
    test eax, eax
    jnz .Lmime_utf8_match
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lmime_plain]
    call str_eq_cstr
    test eax, eax
    jnz .Lmime_plain_match
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lmime_utf8str]
    call str_eq_cstr
    test eax, eax
    jnz .Lmime_string_match
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lmime_native]
    call str_eq_cstr
    test eax, eax
    jz .Lmime_done
    mov eax, 4
    jmp .Lmime_done
.Lmime_string_match:
    mov eax, 3
    jmp .Lmime_done
.Lmime_plain_match:
    mov eax, 2
    jmp .Lmime_done
.Lmime_utf8_match:
    mov eax, 1
.Lmime_done:
    EPILOGUE

# One wire string argument: length includes NUL and padding occupies the complete span.
FN wl_paste_decode_mime
    xor eax, eax
    cmp rsi, 4
    jb .Lmime_invalid
    mov ecx, [rdi]
    test ecx, ecx
    jz .Lmime_invalid
    lea rdx, [rcx + 3]
    and rdx, -4
    add rdx, 4
    cmp rdx, rsi
    jne .Lmime_invalid
    cmp byte ptr [rdi + rcx + 3], 0
    jne .Lmime_invalid
    add rdi, 4
    lea esi, [rcx - 1]
    jmp mime_is_text
.Lmime_invalid:
    ret

# wl_on_global(args): name, interface, version
wl_on_global:
    PROLOGUE 16
    mov r12d, [rdi]               # name
    mov r13d, [rdi + 4]           # strlen incl NUL
    lea r14, [rdi + 8]            # interface
    lea eax, [r13 + 3]
    and eax, -4
    mov r15d, [r14 + rax]         # version
    lea rbx, [rip + global_table]
.Lg_next:
    mov rdi, [rbx]
    test rdi, rdi
    jz .Lg_ret
    mov rdx, rdi
    mov rdi, r14
    lea rsi, [r13 - 1]
    call str_eq_cstr
    test eax, eax
    jnz .Lg_found
    add rbx, 24
    jmp .Lg_next
.Lg_found:
    mov rax, [rbx + 8]            # id slot
    cmp dword ptr [rax], 0
    jne .Lg_ret
    # version = min(offered, wanted)
    mov ecx, [rbx + 16]
    cmp r15d, ecx
    cmova r15d, ecx
    mov [rsp], r15d
    call wl_new_id
    mov rcx, [rbx + 8]
    mov [rcx], eax
    mov [rsp + 4], eax
    MSG [rip + id_registry], 0
    ARG r12d
    mov rdi, [rbx]
    call wl_put_str
    ARG [rsp]
    ARG [rsp + 4]
    END
    mov rax, [rbx + 8]
    lea rcx, [rip + id_seat]
    cmp rax, rcx
    jne .Lg_ret
    mov eax, [rsp]
    mov [rip + seat_ver], eax
.Lg_ret:
    EPILOGUE

# ---------------- window / buffers ----------------

# phys = logical * scale
logical_to_phys:
    mov eax, edi
    mov ecx, [rip + scale120]
    test ecx, ecx
    jz 1f
    imul eax, ecx
    add eax, 60
    xor edx, edx
    mov ecx, 120
    div ecx
    ret
1:  imul eax, [rip + int_scale]
    ret

apply_configure:
    mov eax, [rip + pend_states]
    mov [rip + g_win_states], eax
    mov eax, [rip + pend_w]
    test eax, eax
    jnz 1f
    mov eax, [rip + win_w]
    test eax, eax
    jnz 1f
    mov eax, 1280
1:  mov [rip + win_w], eax
    mov eax, [rip + pend_h]
    test eax, eax
    jnz 2f
    mov eax, [rip + win_h]
    test eax, eax
    jnz 2f
    mov eax, 820
2:  mov [rip + win_h], eax
    mov dword ptr [rip + configured], 1
    call apply_size
    ret

# apply_size(): (re)create buffers when physical size changed
apply_size:
    PROLOGUE
    cmp dword ptr [rip + configured], 0
    je .Las_ret
    mov edi, [rip + win_w]
    call logical_to_phys
    mov r12d, eax
    mov edi, [rip + win_h]
    call logical_to_phys
    mov r13d, eax
    # ui scale for the app
    mov eax, [rip + scale120]
    test eax, eax
    jnz 1f
    mov eax, [rip + int_scale]
    imul eax, eax, 120
1:  cvtsi2ss xmm0, eax
    divss xmm0, [rip + f_120]
    movss [rip + g_dpi_scale], xmm0
    cmp dword ptr [rip + id_viewport], 0
    je 2f
    MSG [rip + id_viewport], 2    # set_destination
    ARG [rip + win_w]
    ARG [rip + win_h]
    END
2:  mov dword ptr [rip + g_dirty], 1
    cmp r12d, [rip + buf_w]
    jne 3f
    cmp r13d, [rip + buf_h]
    je .Las_notify
3:  # destroy old
    cmp dword ptr [rip + id_pool], 0
    je 4f
    MSG [rip + id_buf], 0
    END
    MSG [rip + id_buf + 4], 0
    END
    MSG [rip + id_pool], 1
    END
    mov rdi, [rip + pool_mem]
    mov rsi, [rip + pool_size]
    SYS SYS_munmap
4:  mov [rip + buf_w], r12d
    mov [rip + buf_h], r13d
    mov eax, r12d
    imul eax, r13d
    shl rax, 3                    # 2 buffers * 4 bytes
    mov [rip + pool_size], rax
    lea rdi, [rip + .Lmemfd_name]
    mov esi, 1                    # MFD_CLOEXEC
    SYS SYS_memfd_create
    test rax, rax
    js .Las_fail
    mov ebx, eax
    mov edi, ebx
    mov rsi, [rip + pool_size]
    SYS SYS_ftruncate
    xor edi, edi
    mov rsi, [rip + pool_size]
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_SHARED
    mov r8d, ebx
    xor r9d, r9d
    SYS SYS_mmap
    cmp rax, -4096
    ja .Las_fail
    mov [rip + pool_mem], rax
    call wl_new_id
    mov [rip + id_pool], eax
    MSG [rip + id_shm], 0
    ARG [rip + id_pool]
    ARG [rip + pool_size]
    END
    mov edi, ebx
    call wl_flush_fd
    mov edi, ebx
    SYS SYS_close
    xor r14d, r14d
5:  call wl_new_id
    lea rcx, [rip + id_buf]
    mov [rcx + r14*4], eax
    lea rcx, [rip + buf_busy]
    mov dword ptr [rcx + r14*4], 0
    mov r15d, eax
    MSG [rip + id_pool], 0
    ARG r15d
    mov eax, r12d
    imul eax, r13d
    shl eax, 2
    imul eax, r14d
    ARG eax
    ARG r12d
    ARG r13d
    lea eax, [r12*4]
    ARG eax
    ARG WL_SHM_XRGB8888
    END
    inc r14d
    cmp r14d, 2
    jb 5b
.Las_notify:
    mov edi, r12d
    mov esi, r13d
    call app_on_resize
.Las_ret:
    EPILOGUE
.Las_fail:
    lea rdi, [rip + .Lshm_err]
    call die

# wl_draw(): render into a free buffer and commit
wl_draw:
    PROLOGUE
    call deco_sync
    cmp dword ptr [rip + configured], 0
    je .Ldr_ret
    cmp dword ptr [rip + id_frame_cb], 0
    jne .Ldr_ret
    xor ebx, ebx
    cmp dword ptr [rip + buf_busy], 0
    je 1f
    mov ebx, 1
    cmp dword ptr [rip + buf_busy + 4], 0
    jne .Ldr_ret
1:  mov eax, [rip + buf_w]
    imul eax, [rip + buf_h]
    shl rax, 2
    imul rax, rbx
    mov rdi, [rip + pool_mem]
    add rdi, rax
    mov esi, [rip + buf_w]
    mov edx, [rip + buf_h]
    mov ecx, esi
    call gfx_set_target
    mov dword ptr [rip + g_dirty], 0
    call app_render
    lea rcx, [rip + buf_busy]
    mov dword ptr [rcx + rbx*4], 1
    lea rcx, [rip + id_buf]
    mov r12d, [rcx + rbx*4]
    MSG [rip + id_surface], 1     # attach
    ARG r12d
    ARG 0
    ARG 0
    END
    MSG [rip + id_surface], 9     # damage_buffer
    ARG 0
    ARG 0
    ARG [rip + buf_w]
    ARG [rip + buf_h]
    END
    call wl_new_id
    mov [rip + id_frame_cb], eax
    MSG [rip + id_surface], 3     # frame
    ARG [rip + id_frame_cb]
    END
    MSG [rip + id_surface], 6     # commit
    END
    call wl_activate
.Ldr_ret:
    EPILOGUE

# ---------------- input ----------------

# fixed 24.8 logical -> physical int
fixed_to_phys:
    mov eax, edi
    mov ecx, [rip + scale120]
    test ecx, ecx
    jnz 1f
    imul eax, [rip + int_scale]
    sar eax, 8
    ret
1:  movsxd rax, edi
    movsxd rcx, ecx
    imul rax, rcx
    sar rax, 8
    cqo
    mov ecx, 120
    idiv rcx
    ret

# on_pointer(opcode, args)
on_pointer:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    cmp ebx, 0
    je .Lp_enter
    cmp ebx, 1
    je .Lp_leave
    cmp ebx, 2
    je .Lp_motion
    cmp ebx, 3
    je .Lp_button
    cmp ebx, 4
    je .Lp_axis
    cmp ebx, 6
    je .Lp_source
    jmp .Lp_ret
.Lp_enter:
    mov eax, [r12]
    mov [rip + enter_serial], eax
    mov dword ptr [rip + cur_shape], -1
    mov eax, [r12 + 8]
    mov [rip + ptr_x], eax
    mov eax, [r12 + 12]
    mov [rip + ptr_y], eax
    call send_motion
    jmp .Lp_ret
.Lp_leave:
    call app_on_pointer_leave
    jmp .Lp_ret
.Lp_motion:
    mov eax, [r12 + 4]
    mov [rip + ptr_x], eax
    mov eax, [r12 + 8]
    mov [rip + ptr_y], eax
    call send_motion
    jmp .Lp_ret
.Lp_button:
    mov eax, [r12]
    mov [rip + last_serial], eax
    mov dword ptr [rip + last_serial_known], 1
    mov eax, [r12 + 8]            # linux button code
    mov edi, BTN_LEFT
    cmp eax, 0x110
    je 1f
    mov edi, BTN_RIGHT
    cmp eax, 0x111
    je 1f
    mov edi, BTN_MIDDLE
    cmp eax, 0x112
    jne .Lp_ret
1:  mov esi, [r12 + 12]
    mov edx, [rip + kb_mods]
    call app_on_button
    jmp .Lp_ret
.Lp_axis:
    # in 1/(256 * 120) physical pixels: the wheel scrolls ~3 lines a notch, a touchpad 3x the
    # finger's travel, and what falls short of a pixel carries to the next event
    movsxd rax, dword ptr [r12 + 8]   # fixed 24.8 logical
    mov ecx, 5
    mov edx, 3
    mov esi, [rip + axis_src]
    dec esi
    cmp esi, 1                    # finger or continuous
    cmovbe ecx, edx
    imul rax, rcx
    mov ecx, [rip + scale120]
    test ecx, ecx
    jnz 1f
    imul ecx, dword ptr [rip + int_scale], 120
1:  imul rax, rcx
    mov ecx, [r12 + 4]            # 0 vertical, 1 horizontal
    and ecx, 1
    lea rsi, [rip + axis_rem]
    add rax, [rsi + rcx*8]
    cqo
    mov edi, 256 * 120
    idiv rdi
    mov [rsi + rcx*8], rdx
    mov r13d, eax
    xor edi, edi
    xor esi, esi
    cmp dword ptr [r12 + 4], 0
    jne 4f
    mov esi, r13d
    jmp 5f
4:  mov edi, r13d
5:  mov edx, [rip + kb_mods]
    call app_on_scroll
    jmp .Lp_ret
.Lp_source:
    mov eax, [r12]
    mov [rip + axis_src], eax
.Lp_ret:
    pop r13
    pop r12
    pop rbx
    ret

send_motion:
    push rbx
    mov edi, [rip + ptr_x]
    call fixed_to_phys
    mov ebx, eax
    mov edi, [rip + ptr_y]
    call fixed_to_phys
    mov edi, ebx
    mov esi, eax
    call app_on_motion
    pop rbx
    ret

# on_keyboard(opcode, args)
on_keyboard:
    PROLOGUE 16
    mov ebx, edi
    mov r12, rsi
    test ebx, ebx
    je .Lk_keymap
    cmp ebx, 1
    je .Lk_enter
    cmp ebx, 2
    je .Lk_leave
    cmp ebx, 3
    je .Lk_key
    cmp ebx, 4
    je .Lk_mods
    cmp ebx, 5
    je .Lk_repeat
    jmp .Lk_ret
.Lk_keymap:
    call fdq_pop
    mov r13d, eax
    test eax, eax
    js .Lk_ret
    mov r14d, [r12 + 4]           # size
    xor edi, edi
    mov esi, r14d
    mov edx, PROT_READ
    mov r10d, MAP_PRIVATE
    mov r8d, r13d
    xor r9d, r9d
    SYS SYS_mmap
    cmp rax, -4096
    ja 1f
    mov r15, rax
    mov rdi, rax
    mov esi, r14d
    call xkb_parse
    lea rdi, [rip + .Lkmdump]
    call getenv
    test rax, rax
    jz 11f
    mov rdi, rax
    mov rsi, r15
    lea edx, [r14 - 1]
    call file_write_all
11:
    mov rdi, r15
    mov esi, r14d
    SYS SYS_munmap
1:  mov edi, r13d
    SYS SYS_close
    jmp .Lk_ret
.Lk_enter:
    mov eax, [r12]
    mov [rip + last_serial], eax
    mov dword ptr [rip + last_serial_known], 1
    mov edi, 1
    call app_on_focus
    jmp .Lk_ret
.Lk_leave:
    mov dword ptr [rip + rep_key], 0
    call wl_paste_offer_clear
    xor edi, edi
    call app_on_focus
    jmp .Lk_ret
.Lk_key:
    mov eax, [r12]
    mov [rip + last_serial], eax
    mov dword ptr [rip + last_serial_known], 1
    mov edi, [r12 + 8]
    add edi, 8
    mov esi, [r12 + 12]
    cmp esi, 1
    jne 2f
    # press: arm repeat for non-modifier keys
    mov [rsp], edi
    call key_emit
    mov edi, [rsp]
    call is_modifier_key
    test eax, eax
    jnz .Lk_ret
    mov eax, [rsp]
    mov [rip + rep_key], eax
    call time_ms
    mov ecx, [rip + rep_delay]
    add rax, rcx
    mov [rip + rep_next], rax
    jmp .Lk_ret
2:  mov [rsp], edi
    mov esi, [rip + kb_group]
    mov edx, [rip + kb_mods]
    and edx, -4
    call xkb_keysym
    mov edi, eax
    mov esi, [rip + kb_mods]
    and esi, MOD_SHIFT | MOD_CTRL | MOD_ALT | MOD_SUPER
    call viewpic_key_up
    mov edi, [rsp]
    cmp edi, [rip + rep_key]
    jne .Lk_ret
    mov dword ptr [rip + rep_key], 0
    jmp .Lk_ret
.Lk_mods:
    mov eax, [r12 + 4]
    or eax, [r12 + 8]
    or eax, [r12 + 12]
    mov [rip + kb_mods], eax
    mov eax, [r12 + 16]
    mov [rip + kb_group], eax
    mov edi, [rip + kb_mods]
    and edi, MOD_SHIFT | MOD_CTRL | MOD_ALT | MOD_SUPER
    call app_on_modifiers
    jmp .Lk_ret
.Lk_repeat:
    mov eax, [r12]
    mov [rip + rep_rate], eax
    mov eax, [r12 + 4]
    mov [rip + rep_delay], eax
.Lk_ret:
    EPILOGUE

# key_emit(xkb keycode)
key_emit:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, [rip + kb_group]
    mov esi, r13d
    mov edx, [rip + kb_mods]
    call xkb_keysym
    mov ebx, eax
    # shortcuts on a non-latin layout: use the first layout's key
    test dword ptr [rip + kb_mods], MOD_CTRL | MOD_ALT | MOD_SUPER
    jz 1f
    cmp ebx, 0x100
    jb 1f
    cmp ebx, 0xfe00
    jae 1f
    xor r13d, r13d
    mov edi, r12d
    xor esi, esi
    mov edx, [rip + kb_mods]
    call xkb_keysym
    mov ebx, eax
1:  # the same key on the first layout, without Shift (g_key_latin: chords on any layout)
    mov edi, r12d
    xor esi, esi
    mov edx, [rip + kb_mods]
    and edx, -4
    call xkb_keysym
    mov [rip + g_key_latin], eax
    # and the key's unshifted character in that layout, neither Shift nor Caps Lock (g_key_base)
    mov edi, r12d
    mov esi, r13d
    mov edx, [rip + kb_mods]
    and edx, -4
    call xkb_keysym
    mov edi, eax
    call keysym_to_unicode
    mov [rip + g_key_base], eax
    mov edi, ebx
    call keysym_to_unicode
    mov edi, ebx
    mov esi, eax
    mov edx, [rip + kb_mods]
    and edx, MOD_SHIFT | MOD_CTRL | MOD_ALT | MOD_SUPER
    call app_on_key
    mov dword ptr [rip + g_key_base], 0
    mov dword ptr [rip + g_key_latin], 0
    pop r13
    pop r12
    pop rbx
    ret

# is_modifier_key(xkb keycode) -> 1 if its base keysym is a modifier
is_modifier_key:
    mov esi, [rip + kb_group]
    mov edx, [rip + kb_mods]
    call xkb_keysym
    lea ecx, [rax - 0xffe1]
    cmp ecx, 0xffee - 0xffe1
    jbe 1f
    lea ecx, [rax - 0xfe01]
    cmp ecx, 0x20
    jbe 1f
    lea ecx, [rax - 0xfe50]         # dead keys
    cmp ecx, 0xfe93 - 0xfe50
    jbe 1f
    cmp eax, 0xff20                 # Multi_key
    je 1f
    xor eax, eax
    ret
1:  mov eax, 1
    ret

# deco_sync(): the title bar setting changed, tell the compositor
deco_sync:
    push rbx
    mov eax, [rip + cfg_decorations]
    cmp eax, [rip + deco_applied]
    je 9f
    mov [rip + deco_applied], eax
    cmp dword ptr [rip + id_deco], 0
    je 9f
    call deco_wanted
    mov [rip + deco_mode], eax
    MSG [rip + id_deco], 1
    ARG [rip + deco_mode]
    END
9:  pop rbx
    ret

# deco_wanted() -> 1 rhun draws the title bar, 2 the compositor does.
# Auto: tiling compositors, which keep windows bare, get server side; everything else gets rhun's own
deco_wanted:
    push rbx
    mov eax, [rip + cfg_decorations]
    cmp eax, 1
    je 1f
    cmp eax, 2
    je 2f
    call tiling_desktop
    test eax, eax
    jnz 2f
1:  mov eax, 1
    pop rbx
    ret
2:  mov eax, 2
    pop rbx
    ret

# tiling_desktop() -> 1 if XDG_CURRENT_DESKTOP names a tiling compositor
tiling_desktop:
    PROLOGUE
    lea rdi, [rip + .Lenv_desktop]
    call getenv
    test rax, rax
    jz 8f
    mov r12, rax
1:  # next ':' separated name
    xor r13d, r13d
2:  movzx eax, byte ptr [r12 + r13]
    test al, al
    jz 3f
    cmp al, ':'
    je 3f
    inc r13
    jmp 2b
3:  lea rbx, [rip + .Ltiling]
4:  mov rdx, [rbx]
    test rdx, rdx
    jz 5f
    mov rdi, r12
    mov rsi, r13
    call str_ieq_cstr
    test eax, eax
    jnz 9f
    add rbx, 8
    jmp 4b
5:  cmp byte ptr [r12 + r13], 0
    je 8f
    lea r12, [r12 + r13 + 1]
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# theme_cursor(shape): the compositor cannot draw named cursors; show the theme's image on our own surface
theme_cursor:
    PROLOGUE 16
    mov ebx, edi
    cmp dword ptr [rip + id_pointer], 0
    je 9f
    # integer buffer scale: fractional outputs get the next larger image
    movss xmm0, [rip + g_dpi_scale]
    cvttss2si eax, xmm0
    cvtsi2ss xmm1, eax
    comiss xmm0, xmm1
    jbe 1f
    inc eax
1:  cmp eax, 1
    jge 2f
    mov eax, 1
2:  cmp eax, 4
    jle 3f
    mov eax, 4
3:  cmp eax, [rip + cur_bs]
    je 4f
    mov [rip + cur_bs], eax
    call cursor_drop
4:  lea rax, [rip + cur_ids]
    cmp dword ptr [rax + rbx*4], 0
    jne 5f
    mov edi, ebx
    call cursor_make
    lea rax, [rip + cur_ids]
    cmp dword ptr [rax + rbx*4], 0
    je 9f
5:  cmp dword ptr [rip + cur_surf], 0
    jne 6f
    call wl_new_id
    mov [rip + cur_surf], eax
    MSG [rip + id_compositor], 0  # create_surface
    ARG [rip + cur_surf]
    END
6:  MSG [rip + cur_surf], 8       # set_buffer_scale
    ARG [rip + cur_bs]
    END
    lea rax, [rip + cur_ids]
    mov r12d, [rax + rbx*4]
    MSG [rip + cur_surf], 1       # attach
    ARG r12d
    ARG 0
    ARG 0
    END
    MSG [rip + cur_surf], 2       # damage
    ARG 0
    ARG 0
    ARG 4096
    ARG 4096
    END
    MSG [rip + cur_surf], 6       # commit
    END
    lea rax, [rip + cur_hx]
    mov r12d, [rax + rbx*4]
    lea rax, [rip + cur_hy]
    mov r13d, [rax + rbx*4]
    MSG [rip + id_pointer], 0     # set_cursor
    ARG [rip + enter_serial]
    ARG [rip + cur_surf]
    ARG r12d
    ARG r13d
    END
9:  EPILOGUE

# cursor_make(shape): wl_buffer for the theme image (or the built-in one) at the current scale
cursor_make:
    PROLOGUE 32
    mov ebx, edi
    call xcursor_size
    imul eax, [rip + cur_bs]
    mov r12d, eax
    mov edi, ebx
    mov esi, r12d
    lea rdx, [rip + xcur]
    call xcursor_load
    test eax, eax
    jnz 1f
    mov edi, ebx
    mov esi, r12d
    lea rdx, [rip + xcur]
    call xcursor_builtin
1:  # buffer size must be a multiple of the scale
    mov ecx, [rip + cur_bs]
    mov eax, [rip + xcur + XC_w]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    imul eax, ecx
    mov r13d, eax               # W
    mov eax, [rip + xcur + XC_h]
    add eax, ecx
    dec eax
    xor edx, edx
    div ecx
    imul eax, ecx
    mov r14d, eax               # H
    imul eax, r13d
    shl rax, 2
    mov [rsp], rax              # bytes
    lea rdi, [rip + .Lcursor_name]
    mov esi, 1                  # MFD_CLOEXEC
    SYS SYS_memfd_create
    test rax, rax
    js 8f
    mov r15d, eax
    mov edi, r15d
    mov rsi, [rsp]
    SYS SYS_ftruncate
    xor edi, edi
    mov rsi, [rsp]
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_SHARED
    mov r8d, r15d
    xor r9d, r9d
    SYS SYS_mmap
    cmp rax, -4096
    ja 7f
    mov [rsp + 8], rax
    # rows into the (zeroed) padded buffer
    xor ecx, ecx
2:  cmp ecx, [rip + xcur + XC_h]
    jae 3f
    mov [rsp + 16], ecx
    mov eax, ecx
    imul eax, r13d
    mov rdi, [rsp + 8]
    lea rdi, [rdi + rax*4]
    mov eax, ecx
    imul eax, [rip + xcur + XC_w]
    mov rsi, [rip + xcur + XC_pixels]
    lea rsi, [rsi + rax*4]
    mov ecx, [rip + xcur + XC_w]
    shl ecx, 2
    rep movsb
    mov ecx, [rsp + 16]
    inc ecx
    jmp 2b
3:  call wl_new_id
    mov [rsp + 16], eax         # pool
    MSG [rip + id_shm], 0         # create_pool
    ARG [rsp + 16]
    ARG [rsp]
    END
    mov edi, r15d
    call wl_flush_fd
    call wl_new_id
    lea rcx, [rip + cur_ids]
    mov [rcx + rbx*4], eax
    mov [rsp + 20], eax
    MSG [rsp + 16], 0             # create_buffer
    ARG [rsp + 20]
    ARG 0
    ARG r13d
    ARG r14d
    lea eax, [r13*4]
    ARG eax
    ARG 0                         # ARGB8888
    END
    MSG [rsp + 16], 1             # pool destroy (the buffer keeps it)
    END
    # hotspot in surface coordinates
    mov eax, [rip + xcur + XC_xhot]
    xor edx, edx
    div dword ptr [rip + cur_bs]
    lea rcx, [rip + cur_hx]
    mov [rcx + rbx*4], eax
    mov eax, [rip + xcur + XC_yhot]
    xor edx, edx
    div dword ptr [rip + cur_bs]
    lea rcx, [rip + cur_hy]
    mov [rcx + rbx*4], eax
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    SYS SYS_munmap
7:  mov edi, r15d
    SYS SYS_close
8:  mov rdi, [rip + xcur + XC_file]
    call mem_free
    EPILOGUE

# cursor_drop(): forget cursor buffers (the scale changed)
cursor_drop:
    push rbx
    xor ebx, ebx
1:  lea rax, [rip + cur_ids]
    mov eax, [rax + rbx*4]
    test eax, eax
    jz 2f
    MSG eax, 0                    # wl_buffer.destroy
    END
    lea rax, [rip + cur_ids]
    mov dword ptr [rax + rbx*4], 0
2:  inc ebx
    cmp ebx, 8
    jb 1b
    pop rbx
    ret

# ---------------- vtable entries ----------------

wl_timeout:
    push rbx
    call wl_paste_timeout
    mov ebx, eax
    call wl_send_timeout
    cmp ebx, -1
    je 3f
    cmp eax, -1
    je 4f
    cmp eax, ebx
    cmova eax, ebx
3:  mov ebx, eax
4:
    call wl_repeat_timeout
    cmp ebx, -1
    je 1f
    cmp eax, -1
    je 2f
    cmp eax, ebx
    cmova eax, ebx
    jmp 1f
2:  mov eax, ebx
1:  pop rbx
    ret

wl_repeat_timeout:
    cmp dword ptr [rip + rep_key], 0
    je 1f
    cmp dword ptr [rip + rep_rate], 0
    je 1f
    call time_ms
    mov rcx, [rip + rep_next]
    sub rcx, rax
    jns 2f
    xor ecx, ecx
2:  mov eax, ecx
    ret
1:  mov eax, -1
    ret

wl_tick:
    sub rsp, 8
    call wl_paste_tick
    call wl_send_tick
    call wl_repeat_tick
    add rsp, 8
    ret

wl_repeat_tick:
    cmp dword ptr [rip + rep_key], 0
    je 1f
    cmp dword ptr [rip + rep_rate], 0
    je 1f
    call time_ms
    cmp rax, [rip + rep_next]
    jb 1f
    mov ecx, 1000
    xor edx, edx
    mov eax, ecx
    div dword ptr [rip + rep_rate]
    add [rip + rep_next], rax
    call time_ms
    cmp rax, [rip + rep_next]     # don't build a backlog
    jb 2f
    mov [rip + rep_next], rax
2:  mov edi, [rip + rep_key]
    call key_emit
1:  ret

wl_set_cursor:
    cmp edi, [rip + cur_shape]
    je 1f
    mov [rip + cur_shape], edi
    cmp dword ptr [rip + id_cursor_dev], 0
    je theme_cursor
    push rbx
    lea rax, [rip + cursor_shapes]
    movzx ebx, byte ptr [rax + rdi]
    MSG [rip + id_cursor_dev], 1
    ARG [rip + enter_serial]
    ARG ebx
    END
    pop rbx
1:  ret

wl_move:
    cmp dword ptr [rip + id_toplevel], 0
    je 1f
    mov dword ptr [rip + rep_key], 0
    MSG [rip + id_toplevel], 5
    ARG [rip + id_seat]
    ARG [rip + last_serial]
    END
1:  ret

wl_resize:
    push rbx
    mov ebx, edi
    MSG [rip + id_toplevel], 6
    ARG [rip + id_seat]
    ARG [rip + last_serial]
    ARG ebx
    END
    pop rbx
    ret

wl_minimize:
    MSG [rip + id_toplevel], 13
    END
    ret

wl_maximize:
    mov esi, 9
    test dword ptr [rip + g_win_states], 1
    jz 1f
    mov esi, 10
1:  MSG [rip + id_toplevel], esi
    END
    ret

wl_title:
    push rbx
    mov rbx, rdi
    MSG [rip + id_toplevel], 2
    mov rdi, rbx
    call wl_put_str
    END
    pop rbx
    ret

wl_menu:
    push rbx
    push r12
    sub rsp, 8
    # physical -> logical
    mov eax, edi
    mov ebx, esi
    call phys_to_logical
    mov r12d, eax
    mov eax, ebx
    call phys_to_logical
    mov ebx, eax
    MSG [rip + id_toplevel], 4
    ARG [rip + id_seat]
    ARG [rip + last_serial]
    ARG r12d
    ARG ebx
    END
    add rsp, 8
    pop r12
    pop rbx
    ret

# eax physical -> eax logical
phys_to_logical:
    mov ecx, [rip + scale120]
    test ecx, ecx
    jz 1f
    imul eax, eax, 120
    xor edx, edx
    div ecx
    ret
1:  xor edx, edx
    div dword ptr [rip + int_scale]
    ret

# An immutable source owns its bytes until server deletion and its last job release.
FN wl_source_find
    test edi, edi
    jz 4f
    lea rax, [rip + wl_send_sources]
    mov ecx, WCS_COUNT
1:  cmp dword ptr [rax + WCS_state], 1
    jb 2f
    cmp dword ptr [rax + WCS_state], 2
    ja 2f
    cmp [rax + WCS_id], edi
    je 3f
2:  add rax, WCS_SIZE
    dec ecx
    jnz 1b
4:  xor eax, eax
3:  ret

FN wl_source_create
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    cmp rsi, WCL_LIMIT
    ja .Lwsc_reject
    test rsi, rsi
    jz 1f
    test rdi, rdi
    jz .Lwsc_reject
1:  mov rax, [rip + wl_send_charge]
    add rax, r13
    cmp rax, WCS_BUDGET
    ja .Lwsc_reject
    lea rbx, [rip + wl_send_sources]
    mov ecx, WCS_COUNT
2:  cmp dword ptr [rbx + WCS_state], 0
    je 3f
    add rbx, WCS_SIZE
    dec ecx
    jnz 2b
    jmp .Lwsc_reject
3:  call snippet_utf8_valid
    test eax, eax
    jz .Lwsc_reject
    lea rdi, [r13 + 1]
    call mem_alloc_try
    test rax, rax
    jz .Lwsc_reject
    mov [rbx + WCS_ptr], rax
    mov [rbx + WCS_len], r13
    mov [rbx + WCS_charge], r13
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call memcpy
    mov dword ptr [rbx + WCS_state], 1
    add [rip + wl_send_charge], r13
    mov rax, rbx
    EPILOGUE
.Lwsc_reject:
    xor eax, eax
    EPILOGUE

# Native source owns one envelope; the text pointer borrows its interior.
FN wl_source_create_native
    PROLOGUE CWB_SIZE
    mov r12, rdi
    mov r13, rsi
    mov rdx, rsp
    call clip_wire_decode
    test eax, eax
    jz .Lwscn_fail
    mov rax, [rip + wl_send_charge]
    add rax, r13
    cmp rax, WCS_BUDGET
    ja .Lwscn_fail
    lea rbx, [rip + wl_send_sources]
    mov ecx, WCS_COUNT
1:  cmp dword ptr [rbx + WCS_state], 0
    je 2f
    add rbx, WCS_SIZE
    dec ecx
    jnz 1b
    jmp .Lwscn_fail
2:  mov r14, [rsp + CWB_text]
    sub r14, r12
    lea rdi, [r13 + 1]
    call mem_alloc_try
    test rax, rax
    jz .Lwscn_fail
    mov r15, rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call memcpy
    mov [rbx + WCS_wire], r15
    mov [rbx + WCS_wirelen], r13
    mov [rbx + WCS_charge], r13
    add r14, r15
    mov [rbx + WCS_ptr], r14
    mov rax, [rsp + CWB_len]
    mov [rbx + WCS_len], rax
    mov dword ptr [rbx + WCS_state], 1
    add [rip + wl_send_charge], r13
    mov rax, rbx
    EPILOGUE
.Lwscn_fail:
    xor eax, eax
    EPILOGUE

# Clear only the current borrowed view. It never owns an allocation.
wl_source_detach:
    mov eax, [rdi + WCS_id]
    cmp eax, [rip + id_source]
    jne 1f
    mov dword ptr [rip + id_source], 0
    mov qword ptr [rip + clip_sb + SB_ptr], 0
    mov qword ptr [rip + clip_sb + SB_len], 0
    mov qword ptr [rip + clip_sb + SB_cap], 0
1:  ret

FN wl_source_release
    cmp dword ptr [rdi + WCS_state], 3
    jne 1f
    cmp dword ptr [rdi + WCS_refs], 0
    jne 1f
    push rbx
    mov rbx, rdi
    mov rax, [rbx + WCS_charge]
    sub [rip + wl_send_charge], rax
    mov rdi, [rbx + WCS_wire]
    test rdi, rdi
    cmovz rdi, [rbx + WCS_ptr]
    mov dword ptr [rbx + WCS_state], 0
    call mem_free
    mov rdi, rbx
    xor esi, esi
    mov edx, WCS_SIZE
    call memset
    pop rbx
1:  ret

FN wl_source_retire
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + WCS_state], 1
    jne 1f
    mov dword ptr [rbx + WCS_state], 2
    call wl_source_detach
    MSG [rbx + WCS_id], 1
    END
1:  EPILOGUE

FN wl_source_deleted
    sub rsp, 8
    call wl_source_find
    test rax, rax
    jz 1f
    mov rdi, rax
    call wl_source_detach
    mov dword ptr [rdi + WCS_state], 3
    call wl_source_release
1:  add rsp, 8
    ret

# clipboard: accept the new source before changing the old one.
FN wl_clip_set
    cmp dword ptr [rip + id_ddm], 0
    je .Lwc_unavailable
    cmp dword ptr [rip + id_ddev], 0
    je .Lwc_unavailable
    cmp dword ptr [rip + last_serial_known], 0
    je .Lwc_unavailable
    PROLOGUE
    call wl_source_create
    test rax, rax
    jz .Lwc_reject
    mov rdi, rax
    call wl_clip_publish
    EPILOGUE
.Lwc_reject:
    xor eax, eax
    EPILOGUE
.Lwc_unavailable:
    xor eax, eax
    ret

FN wl_clip_write
    cmp dword ptr [rip + id_ddm], 0
    je .Lwc_unavailable
    cmp dword ptr [rip + id_ddev], 0
    je .Lwc_unavailable
    cmp dword ptr [rip + last_serial_known], 0
    je .Lwc_unavailable
    PROLOGUE
    call wl_source_create_native
    test rax, rax
    jz .Lwc_reject
    mov rdi, rax
    call wl_clip_publish
    EPILOGUE

wl_clip_publish:
    PROLOGUE
    mov rax, rdi
    mov rbx, rax
    mov edi, [rip + id_source]
    call wl_source_find
    test rax, rax
    jz 1f
    mov rdi, rax
    call wl_source_retire
1:  call wl_new_id
    mov [rbx + WCS_id], eax
    mov [rip + id_source], eax
    mov rax, [rbx + WCS_ptr]
    mov [rip + clip_sb + SB_ptr], rax
    mov rax, [rbx + WCS_len]
    mov [rip + clip_sb + SB_len], rax
    inc rax
    mov [rip + clip_sb + SB_cap], rax
    MSG [rip + id_ddm], 0
    ARG [rip + id_source]
    END
    MSG [rip + id_source], 0
    SARG .Lmime_utf8
    END
    MSG [rip + id_source], 0
    SARG .Lmime_plain
    END
    MSG [rip + id_source], 0
    SARG .Lmime_utf8str
    END
    cmp qword ptr [rbx + WCS_wire], 0
    je 2f
    MSG [rip + id_source], 0
    SARG .Lmime_native
    END
2:  MSG [rip + id_ddev], 1
    ARG [rip + id_source]
    ARG [rip + last_serial]
    END
    mov eax, 1
    EPILOGUE
# Detached counted storage, never a borrowed source across delivery callbacks.
wl_clip_snapshot:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rsi + 1]
    call mem_alloc_try
    mov r13, rax
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call memcpy
1:  mov rax, r13
    EPILOGUE

# clipboard: one counted receive for the currently submitted shared request.
FN wl_clip_get
    PROLOGUE 32
    mov rax, [rip + app_clip_active_token]
    mov [rsp + 8], rax
    call wl_paste_tick
    mov rax, [rsp + 8]
    cmp rax, [rip + app_clip_active_token]
    jne .Lwpg_done
    cmp dword ptr [rip + paste_fd], -1
    jne .Lwpg_rejected
    cmp dword ptr [rip + id_source], 0
    je .Lwpg_foreign
    mov edi, [rip + id_source]
    call wl_source_find
    test rax, rax
    jz .Lwpg_self_plain
    cmp qword ptr [rax + WCS_wire], 0
    je .Lwpg_self_plain
    mov rdi, [rax + WCS_wire]
    mov rsi, [rax + WCS_wirelen]
    mov [rsp + 16], rsi
    call wl_clip_snapshot
    test rax, rax
    jz .Lwpg_self_plain
    mov r13, rax
    mov rdi, [rsp + 8]
    mov rsi, rax
    mov rdx, [rsp + 16]
    call app_clip_complete_native
    mov r12d, eax
    mov rdi, r13
    call mem_free
    test r12d, r12d
    jnz .Lwpg_done
.Lwpg_self_plain:
    mov r12, [rip + clip_sb + SB_len]
    mov rdi, [rip + clip_sb + SB_ptr]
    mov rsi, r12
    call wl_clip_snapshot
    test rax, rax
    jz .Lwpg_rejected
    mov r13, rax
    mov rdi, [rsp + 8]
    mov rsi, r13
    mov rdx, r12
    mov ecx, 1
    call app_clip_complete
    mov rdi, r13
    call mem_free
    jmp .Lwpg_done
.Lwpg_foreign:
    mov r12d, [rip + sel_offer]
    mov r13d, [rip + sel_offer_text]
    mov r14, [rip + wl_paste_offer_generation]
    mov r15d, r13d
    cmp dword ptr [rip + wl_paste_offer_native], 0
    je 1f
    mov r15d, 4
1:  mov rdi, [rsp + 8]
    mov esi, r12d
    mov edx, r15d
    mov ecx, r13d
    mov r8, r14
    call wl_paste_start
    test eax, eax
    jnz .Lwpg_done
    cmp r15d, 4
    jne .Lwpg_rejected
    mov rdi, [rsp + 8]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r13d
    mov r8, r14
    call wl_paste_start
    test eax, eax
    jnz .Lwpg_done
.Lwpg_rejected:
    mov rdi, [rsp + 8]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call app_clip_complete
.Lwpg_done:
    EPILOGUE

# One format attempt on a still-current offer; no completion on setup failure.
# (token, offer, format, plain preference, offer generation) -> accepted.
FN wl_paste_start
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15, r8
    cmp rbx, [rip + app_clip_active_token]
    jne .Lwps_fail
    test r12d, r12d
    jz .Lwps_fail
    cmp r12d, [rip + sel_offer]
    jne .Lwps_fail
    cmp r15, [rip + wl_paste_offer_generation]
    jne .Lwps_fail
    lea eax, [r13 - 1]
    cmp eax, 3
    ja .Lwps_fail
    mov rdi, rsp
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Lwps_fail
    mov edi, [rsp]
    mov rsi, rbx
    call wl_paste_receive_fd_tagged
    test eax, eax
    jz .Lwps_close_fail
    mov [rip + wl_paste_format], r13d
    mov [rip + wl_paste_attempt_offer], r12d
    mov [rip + wl_paste_attempt_generation], r15
    mov [rip + wl_paste_plain], r14d
    MSG r12d, 1
    cmp r13d, 4
    je .Lwps_native
    cmp r13d, 2
    je .Lwps_plain
    cmp r13d, 3
    je .Lwps_string
    SARG .Lmime_utf8
    jmp .Lwps_send
.Lwps_native:
    SARG .Lmime_native
    jmp .Lwps_send
.Lwps_plain:
    SARG .Lmime_plain
    jmp .Lwps_send
.Lwps_string:
    SARG .Lmime_utf8str
.Lwps_send:
    END
    mov edi, [rsp + 4]
    call wl_flush_fd
    mov edi, [rsp + 4]
    SYS SYS_close
    mov eax, 1
    EPILOGUE
.Lwps_close_fail:
    mov edi, [rsp + 4]
    SYS SYS_close
.Lwps_fail:
    xor eax, eax
    EPILOGUE

# Takes ownership of a fresh read descriptor. Busy alias of the active fd is never closed.
FN wl_paste_receive_fd
    mov rsi, [rip + app_clip_active_token]
    jmp wl_paste_receive_fd_tagged

wl_paste_receive_fd_tagged:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    test ebx, ebx
    js .Lwpr_no_close
    cmp ebx, [rip + paste_fd]
    je .Lwpr_no_close
    call wl_paste_tick
    cmp r12, [rip + app_clip_active_token]
    jne .Lwpr_close
    cmp dword ptr [rip + paste_fd], -1
    je .Lwpr_setup
    cmp ebx, [rip + paste_fd]
    je .Lwpr_no_close
    jmp .Lwpr_close
.Lwpr_setup:
    mov edi, ebx
    mov esi, 3                  # F_GETFL
    SYS SYS_fcntl
    test rax, rax
    js .Lwpr_close
    mov rdx, rax
    or edx, O_NONBLOCK
    mov edi, ebx
    mov esi, F_SETFL
    SYS SYS_fcntl
    test rax, rax
    js .Lwpr_close
    call time_ms
    add rax, WCL_TIMEOUT
    mov [rip + wl_paste_deadline], rax
    inc qword ptr [rip + wl_paste_generation]
    mov [rip + wl_paste_token], r12
    mov [rip + paste_fd], ebx
    mov dword ptr [rip + wl_paste_format], 0
    mov dword ptr [rip + wl_paste_attempt_offer], 0
    mov qword ptr [rip + wl_paste_attempt_generation], 0
    mov dword ptr [rip + wl_paste_plain], 0
    mov edi, ebx
    mov esi, POLLIN
    lea rdx, [rip + on_paste_readable]
    mov rcx, [rip + wl_paste_generation]
    call watch_try_add
    test eax, eax
    jz .Lwpr_cancel
    mov eax, 1
    EPILOGUE
.Lwpr_cancel:
    call wl_paste_dispose
    jmp .Lwpr_no_close
.Lwpr_close:
    mov edi, ebx
    SYS SYS_close
.Lwpr_no_close:
    xor eax, eax
    EPILOGUE

# Retire global state before any cleanup or delivery can start another receive.
wl_paste_retire:
    mov dword ptr [rip + paste_fd], -1
    mov qword ptr [rip + wl_paste_deadline], 0
    mov qword ptr [rip + wl_paste_token], 0
    mov dword ptr [rip + wl_paste_format], 0
    mov dword ptr [rip + wl_paste_attempt_offer], 0
    mov qword ptr [rip + wl_paste_attempt_generation], 0
    mov dword ptr [rip + wl_paste_plain], 0
    mov qword ptr [rip + paste_sb + SB_ptr], 0
    mov qword ptr [rip + paste_sb + SB_len], 0
    mov qword ptr [rip + paste_sb + SB_cap], 0
    inc qword ptr [rip + wl_paste_generation]
    ret

FN wl_paste_cancel
    PROLOGUE
    mov r12, [rip + wl_paste_token]
    mov r13d, [rip + paste_fd]
    call wl_paste_dispose
    test r13d, r13d
    js 1f
    mov rdi, r12
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call app_clip_complete
1:  EPILOGUE

wl_paste_dispose:
    PROLOGUE
    mov ebx, [rip + paste_fd]
    cmp ebx, -1
    je 1f
    mov r12, [rip + paste_sb + SB_ptr]
    call wl_paste_retire
    mov edi, ebx
    call watch_remove
    mov edi, ebx
    SYS SYS_close
    mov rdi, r12
    call mem_free
1:  EPILOGUE

# Invalid native data can retry plain only on the same still-valid offer.
FN wl_paste_reject
    PROLOGUE 16
    mov ebx, [rip + paste_fd]
    mov r12, [rip + wl_paste_token]
    mov rax, [rip + wl_paste_generation]
    mov [rsp], rax
    call wl_paste_tick
    mov rax, [rsp]
    cmp rax, [rip + wl_paste_generation]
    jne .Lwpre_done
    cmp ebx, [rip + paste_fd]
    jne .Lwpre_done
    cmp r12, [rip + wl_paste_token]
    jne .Lwpre_done
    test ebx, ebx
    js .Lwpre_done
    cmp dword ptr [rip + wl_paste_format], 4
    jne .Lwpre_cancel
    mov r13d, [rip + wl_paste_attempt_offer]
    mov r14, [rip + wl_paste_attempt_generation]
    mov r15d, [rip + wl_paste_plain]
    call wl_paste_dispose
    mov rdi, r12
    mov esi, r13d
    mov edx, r15d
    mov ecx, r15d
    mov r8, r14
    # Reject unsupported plain enums, including a second native attempt.
    lea eax, [r15 - 1]
    cmp eax, 2
    ja .Lwpre_failed
    call wl_paste_start
    test eax, eax
    jnz .Lwpre_done
.Lwpre_failed:
    mov rdi, r12
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call app_clip_complete
    jmp .Lwpre_done
.Lwpre_cancel:
    call wl_paste_cancel
.Lwpre_done:
    EPILOGUE

FN wl_paste_complete
    PROLOGUE CWB_SIZE + 16
    mov ebx, [rip + paste_fd]
    test ebx, ebx
    js .Lwpc_done
    mov r12, [rip + paste_sb + SB_ptr]
    mov r13, [rip + paste_sb + SB_len]
    mov r14, [rip + wl_paste_generation]
    mov r15, [rip + wl_paste_token]
    mov eax, [rip + wl_paste_format]
    mov [rsp + CWB_SIZE], eax
    mov rdi, r12
    mov rsi, r13
    cmp eax, 4
    jne 1f
    mov rdx, rsp
    call clip_wire_decode
    jmp 2f
1:  call snippet_utf8_valid
2:  mov [rsp + CWB_SIZE + 8], eax
    # Validation time counts against the attempt deadline, even for invalid wire.
    call wl_paste_tick
    cmp r14, [rip + wl_paste_generation]
    jne .Lwpc_done
    cmp r15, [rip + wl_paste_token]
    jne .Lwpc_done
    cmp ebx, [rip + paste_fd]
    jne .Lwpc_done
    cmp dword ptr [rsp + CWB_SIZE + 8], 0
    je .Lwpc_reject
    test r12, r12
    jnz 3f
    mov edi, 1
    call mem_alloc
    mov r12, rax
3:  call wl_paste_retire
    mov edi, ebx
    call watch_remove
    mov edi, ebx
    SYS SYS_close
    mov rdi, r15
    mov rsi, r12
    mov rdx, r13
    cmp dword ptr [rsp + CWB_SIZE], 4
    jne 4f
    call app_clip_complete_native
    jmp 5f
4:  mov ecx, 1
    call app_clip_complete
5:  mov rdi, r12
    call mem_free
    jmp .Lwpc_done
.Lwpc_reject:
    call wl_paste_reject
.Lwpc_done:
    EPILOGUE

# Counted cap depends on the selected MIME, never on untrusted payload fields.
FN wl_paste_limit
    mov eax, WCL_LIMIT
    cmp dword ptr [rip + wl_paste_format], 4
    jne 1f
    mov eax, CLW_MAX
1:  ret

# Bounded send jobs retain the source record, not the current clipboard view.
FN wl_send_find
    test edi, edi
    js 3f
    lea rax, [rip + wl_send_jobs]
    mov ecx, WCJ_COUNT
1:  cmp dword ptr [rax + WCJ_active], 0
    je 2f
    cmp [rax + WCJ_fd], edi
    je 4f
2:  add rax, WCJ_SIZE
    dec ecx
    jnz 1b
3:  xor eax, eax
4:  ret

FN wl_send_cancel
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + WCJ_active], 0
    je 1f
    mov r12d, [rbx + WCJ_fd]
    mov r13, [rbx + WCJ_source]
    mov dword ptr [rbx + WCJ_active], 0
    mov qword ptr [rbx + WCJ_deadline], 0
    mov qword ptr [rbx + WCJ_source], 0
    mov qword ptr [rbx + WCJ_ptr], 0
    mov qword ptr [rbx + WCJ_len], 0
    mov edi, r12d
    call watch_remove
    mov edi, r12d
    SYS SYS_close
    dec dword ptr [r13 + WCS_refs]
    mov rdi, r13
    call wl_source_release
1:  EPILOGUE

# wl_send_start(source, fresh_fd, mime_enum) -> accepted, owns the fresh fd.
FN wl_send_start
    PROLOGUE 16
    mov r12, rdi
    mov r13d, esi
    mov r14d, edx
    call wl_send_tick
    mov edi, r13d
    call wl_send_find
    test rax, rax
    jnz .Lwss_no_close
    test r13d, r13d
    js .Lwss_no_close
    lea eax, [r14 - 1]
    cmp eax, 3
    ja .Lwss_close
    test r12, r12
    jz .Lwss_close
    mov eax, [r12 + WCS_state]
    dec eax
    cmp eax, 1
    ja .Lwss_close
    mov rax, [r12 + WCS_ptr]
    mov rcx, [r12 + WCS_len]
    cmp r14d, 4
    jne 3f
    mov rax, [r12 + WCS_wire]
    mov rcx, [r12 + WCS_wirelen]
    test rax, rax
    jz .Lwss_close
3:  mov [rsp], rax
    mov [rsp + 8], rcx
    lea rbx, [rip + wl_send_jobs]
    mov ecx, WCJ_COUNT
1:  cmp dword ptr [rbx + WCJ_active], 0
    je 2f
    add rbx, WCJ_SIZE
    dec ecx
    jnz 1b
    jmp .Lwss_close
2:  mov edi, r13d
    mov esi, 3
    SYS SYS_fcntl
    test rax, rax
    js .Lwss_close
    mov rdx, rax
    or edx, O_NONBLOCK
    mov edi, r13d
    mov esi, F_SETFL
    SYS SYS_fcntl
    test rax, rax
    js .Lwss_close
    cmp qword ptr [rsp + 8], 0
    je .Lwss_empty
    call time_ms
    add rax, WCL_TIMEOUT
    mov [rbx + WCJ_deadline], rax
    inc qword ptr [rip + wl_send_generation]
    mov rcx, [rip + wl_send_generation]
    mov [rbx + WCJ_generation], rcx
    mov rax, [rsp]
    mov [rbx + WCJ_ptr], rax
    mov rax, [rsp + 8]
    mov [rbx + WCJ_len], rax
    mov [rbx + WCJ_source], r12
    mov [rbx + WCJ_fd], r13d
    mov qword ptr [rbx + WCJ_offset], 0
    inc dword ptr [r12 + WCS_refs]
    mov dword ptr [rbx + WCJ_active], 1
    mov edi, r13d
    mov esi, POLLOUT
    lea rdx, [rip + on_clip_writable]
    call watch_try_add
    test eax, eax
    jnz .Lwss_accepted
    mov rdi, rbx
    call wl_send_cancel
    jmp .Lwss_no_close
.Lwss_empty:
    mov edi, r13d
    SYS SYS_close
.Lwss_accepted:
    mov eax, 1
    EPILOGUE
.Lwss_close:
    mov edi, r13d
    SYS SYS_close
.Lwss_no_close:
    xor eax, eax
    EPILOGUE

FN on_clip_writable
    PROLOGUE
    mov ebx, edi
    mov r12, rdx
    call wl_send_tick
    mov edi, ebx
    call wl_send_find
    test rax, rax
    jz 1f
    cmp r12, [rax + WCJ_generation]
    jne 1f
    mov r9, [rax + WCJ_offset]
    mov rsi, [rax + WCJ_ptr]
    add rsi, r9
    mov rdx, [rax + WCJ_len]
    sub rdx, r9
    mov eax, 65536
    cmp rdx, rax
    cmova rdx, rax
    mov edi, ebx
    SYS SYS_write
    mov rdx, rax
    mov edi, ebx
    mov rsi, r12
    call wl_send_write_result
1:  EPILOGUE

# Actual callback and injected syscall outcomes share deadline/result handling.
FN wl_send_write_result
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    call wl_send_find
    test rax, rax
    jz .Lwsr_done
    mov rbx, rax
    cmp r12, [rbx + WCJ_generation]
    jne .Lwsr_done
    call time_ms
    cmp rax, [rbx + WCJ_deadline]
    jae .Lwsr_cancel
    test r13, r13
    jg .Lwsr_positive
    cmp r13, -EAGAIN
    je .Lwsr_done
    cmp r13, -EINTR
    je .Lwsr_done
    jmp .Lwsr_cancel
.Lwsr_positive:
    cmp r13, 65536
    ja .Lwsr_cancel
    mov r9, [rbx + WCJ_len]
    sub r9, [rbx + WCJ_offset]
    cmp r13, r9
    ja .Lwsr_cancel
    add [rbx + WCJ_offset], r13
    cmp r13, r9
    je .Lwsr_cancel
    add rax, WCL_TIMEOUT
    mov [rbx + WCJ_deadline], rax
    jmp .Lwsr_done
.Lwsr_cancel:
    mov rdi, rbx
    call wl_send_cancel
.Lwsr_done:
    EPILOGUE

FN wl_send_tick
    PROLOGUE
    call time_ms
    mov r12, rax
    lea rbx, [rip + wl_send_jobs]
    mov r13d, WCJ_COUNT
1:  cmp dword ptr [rbx + WCJ_active], 0
    je 2f
    cmp r12, [rbx + WCJ_deadline]
    jb 2f
    mov rdi, rbx
    call wl_send_cancel
2:  add rbx, WCJ_SIZE
    dec r13d
    jnz 1b
    EPILOGUE

FN wl_send_timeout
    sub rsp, 8
    call time_ms
    mov r8, rax
    lea r9, [rip + wl_send_jobs]
    mov ecx, WCJ_COUNT
    mov r10, -1
1:  cmp dword ptr [r9 + WCJ_active], 0
    je 2f
    mov rdx, [r9 + WCJ_deadline]
    sub rdx, r8
    jns 3f
    xor edx, edx
3:  cmp r10, -1
    je 4f
    cmp rdx, r10
    jae 2f
4:  mov r10, rdx
2:  add r9, WCJ_SIZE
    dec ecx
    jnz 1b
    mov eax, r10d
    add rsp, 8
    ret

# ---------------- setup ----------------

# wl_connect() -> 1 on success, 0 if no wayland display
FN wl_connect
    PROLOGUE 16
    lea rdi, [rip + .Lenv_display]
    call getenv
    mov rbx, rax
    test rax, rax
    jnz 1f
    lea rbx, [rip + .Ldefault_display]
1:  # sockaddr_un
    lea rdi, [rip + sockaddr]
    mov word ptr [rdi], AF_UNIX
    add rdi, 2
    cmp byte ptr [rbx], '/'
    je 2f
    push rdi
    lea rdi, [rip + .Lenv_runtime]
    call getenv
    pop rdi
    test rax, rax
    jz .Lwc_fail
    mov rsi, rax
3:  lodsb
    test al, al
    jz 4f
    stosb
    jmp 3b
4:  mov byte ptr [rdi], '/'
    inc rdi
2:  mov rsi, rbx
5:  lodsb
    stosb
    test al, al
    jnz 5b
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js .Lwc_fail
    mov [rip + wl_fd], eax
    mov edi, eax
    lea rsi, [rip + sockaddr]
    mov edx, 110
    SYS SYS_connect
    test rax, rax
    js .Lwc_close
    mov dword ptr [rip + next_id], 2
    # registry
    call wl_new_id
    mov [rip + id_registry], eax
    MSG 1, 1
    ARG [rip + id_registry]
    END
    call wl_roundtrip
    cmp dword ptr [rip + id_compositor], 0
    je .Lwc_close
    cmp dword ptr [rip + id_shm], 0
    je .Lwc_close
    cmp dword ptr [rip + id_wm_base], 0
    je .Lwc_close
    mov eax, 1
    EPILOGUE
.Lwc_close:
    mov edi, [rip + wl_fd]
    SYS SYS_close
.Lwc_fail:
    xor eax, eax
    EPILOGUE

# Use the desktop launcher's token once the surface is mapped, then remove it
# from the environment so terminals and other children cannot reuse it.
wl_activate:
    PROLOGUE
    cmp dword ptr [rip + activation_sent], 0
    jne 9f
    mov dword ptr [rip + activation_sent], 1
    lea rdi, [rip + .Lenv_activation]
    call getenv
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp byte ptr [rbx], 0
    je 8f
    cmp dword ptr [rip + id_activation], 0
    je 8f
    MSG [rip + id_activation], 2
    mov rdi, rbx
    call wl_put_str
    ARG [rip + id_surface]
    END
8:  lea rdi, [rip + .Lenv_activation]
    call env_unset
9:  EPILOGUE

# wl_open_window(title cstr): create the toplevel and install the vtable
FN wl_open_window
    PROLOGUE 16
    mov rbx, rdi
    call wl_new_id
    mov [rip + id_surface], eax
    MSG [rip + id_compositor], 0
    ARG [rip + id_surface]
    END
    cmp dword ptr [rip + id_fscale_mgr], 0
    je 1f
    cmp dword ptr [rip + id_viewporter], 0
    je 1f
    call wl_new_id
    mov [rip + id_fscale], eax
    MSG [rip + id_fscale_mgr], 1
    ARG [rip + id_fscale]
    ARG [rip + id_surface]
    END
    call wl_new_id
    mov [rip + id_viewport], eax
    MSG [rip + id_viewporter], 1
    ARG [rip + id_viewport]
    ARG [rip + id_surface]
    END
    mov dword ptr [rip + scale120], 120
1:  call wl_new_id
    mov [rip + id_xdg_surface], eax
    MSG [rip + id_wm_base], 2
    ARG [rip + id_xdg_surface]
    ARG [rip + id_surface]
    END
    call wl_new_id
    mov [rip + id_toplevel], eax
    MSG [rip + id_xdg_surface], 1
    ARG [rip + id_toplevel]
    END
    MSG [rip + id_toplevel], 2
    mov rdi, rbx
    call wl_put_str
    END
    MSG [rip + id_toplevel], 3
    SARG .Lapp_id
    END
    MSG [rip + id_toplevel], 8    # min size
    ARG 560
    ARG 360
    END
    mov dword ptr [rip + g_csd], 1
    cmp dword ptr [rip + id_deco_mgr], 0
    je 2f
    call wl_new_id
    mov [rip + id_deco], eax
    MSG [rip + id_deco_mgr], 1
    ARG [rip + id_deco]
    ARG [rip + id_toplevel]
    END
    mov eax, [rip + cfg_decorations]
    mov [rip + deco_applied], eax
    call deco_wanted
    mov [rip + deco_mode], eax
    MSG [rip + id_deco], 1        # set_mode
    ARG [rip + deco_mode]
    END
2:  cmp dword ptr [rip + id_ddm], 0
    je 3f
    cmp dword ptr [rip + id_seat], 0
    je 3f
    call wl_new_id
    mov [rip + id_ddev], eax
    MSG [rip + id_ddm], 1
    ARG [rip + id_ddev]
    ARG [rip + id_seat]
    END
3:  MSG [rip + id_surface], 6     # initial commit
    END
    mov dword ptr [rip + g_wayland], 1   # the isWayland context key (when.s)
    # vtable
    lea rax, [rip + wl_flush]
    mov [rip + g_plat + P_flush], rax
    lea rax, [rip + wl_timeout]
    mov [rip + g_plat + P_timeout], rax
    lea rax, [rip + wl_tick]
    mov [rip + g_plat + P_tick], rax
    lea rax, [rip + wl_draw]
    mov [rip + g_plat + P_draw], rax
    lea rax, [rip + wl_set_cursor]
    mov [rip + g_plat + P_cursor], rax
    lea rax, [rip + wl_clip_set]
    mov [rip + g_plat + P_clip_set], rax
    lea rax, [rip + wl_clip_get]
    mov [rip + g_plat + P_clip_get], rax
    lea rax, [rip + wl_move]
    mov [rip + g_plat + P_move], rax
    lea rax, [rip + wl_resize]
    mov [rip + g_plat + P_resize], rax
    lea rax, [rip + wl_minimize]
    mov [rip + g_plat + P_minimize], rax
    lea rax, [rip + wl_maximize]
    mov [rip + g_plat + P_maximize], rax
    lea rax, [rip + wl_title]
    mov [rip + g_plat + P_title], rax
    lea rax, [rip + wl_menu]
    mov [rip + g_plat + P_menu], rax
    lea rax, [rip + wl_clip_write]
    mov [rip + g_plat + P_clip_write], rax
    mov edi, [rip + wl_fd]
    mov esi, POLLIN
    lea rdx, [rip + wl_on_readable]
    xor ecx, ecx
    call watch_add
    call wl_roundtrip
    EPILOGUE

.section .rodata
.p2align 3
# interface name, id slot, max version
global_table:
    .quad .Li_compositor, id_compositor, 6
    .quad .Li_shm, id_shm, 1
    .quad .Li_wm_base, id_wm_base, 2
    .quad .Li_seat, id_seat, 5
    .quad .Li_ddm, id_ddm, 3
    .quad .Li_deco, id_deco_mgr, 1
    .quad .Li_cursor, id_cursor_mgr, 1
    .quad .Li_viewporter, id_viewporter, 1
    .quad .Li_fscale, id_fscale_mgr, 1
    .quad .Li_activation, id_activation, 1
    .quad 0, 0, 0
.Li_compositor: .asciz "wl_compositor"
.Li_shm: .asciz "wl_shm"
.Li_wm_base: .asciz "xdg_wm_base"
.Li_seat: .asciz "wl_seat"
.Li_ddm: .asciz "wl_data_device_manager"
.Li_deco: .asciz "zxdg_decoration_manager_v1"
.Li_cursor: .asciz "wp_cursor_shape_manager_v1"
.Li_viewporter: .asciz "wp_viewporter"
.Li_fscale: .asciz "wp_fractional_scale_manager_v1"
.Li_activation: .asciz "xdg_activation_v1"
.p2align 3
.Ltiling: .quad .Lt_hypr, .Lt_sway, .Lt_niri, .Lt_river, .Lt_dwl, .Lt_qtile, 0
.Lt_hypr: .asciz "Hyprland"
.Lt_sway: .asciz "sway"
.Lt_niri: .asciz "niri"
.Lt_river: .asciz "river"
.Lt_dwl: .asciz "dwl"
.Lt_qtile: .asciz "qtile"
.Lenv_desktop: .asciz "XDG_CURRENT_DESKTOP"
.Lenv_display: .asciz "WAYLAND_DISPLAY"
.Lenv_runtime: .asciz "XDG_RUNTIME_DIR"
.Lenv_activation: .asciz "XDG_ACTIVATION_TOKEN"
.Ldefault_display: .asciz "wayland-0"
.Lmemfd_name: .asciz "rhun-shm"
.Lcursor_name: .asciz "rhun-cursor"
.Lapp_id: .asciz "rhun"
.Lkmdump: .asciz "RHUN_DUMP_KEYMAP"
.Lmime_utf8: .asciz "text/plain;charset=utf-8"
.Lmime_native: .asciz "application/x-rhun-clipboard-v1"
.Lmime_plain: .asciz "text/plain"
.Lmime_utf8str: .asciz "UTF8_STRING"
.Lproto_err: .asciz "wayland protocol error: "
.Ldisconnected: .asciz "rhun: wayland connection closed"
.Lsend_err: .asciz "rhun: wayland send failed"
.Lshm_err: .asciz "rhun: shm buffer allocation failed"
# CUR_* -> wp_cursor_shape_device_v1 shapes
cursor_shapes: .byte 1, 9, 4, 26, 27, 29, 28, 1
.p2align 2
f_120: .float 120.0

.data
int_scale: .long 1
rep_rate: .long 25
rep_delay: .long 400
.globl wl_paste_fd
wl_paste_fd:
paste_fd: .long -1
.globl g_csd, g_dpi_scale
g_csd: .long 1
deco_applied: .long -1
cur_bs: .long 0
cur_surf: .long 0
cur_ids: .zero 4 * 8
cur_hx: .zero 4 * 8
cur_hy: .zero 4 * 8
.p2align 3
xcur: .zero XC_SIZE
deco_mode: .long 0
g_dpi_scale: .float 1.0

.text
FN on_paste_readable
    PROLOGUE 16
    mov ebx, edi
    mov r15, rdx
    mov rax, [rip + wl_paste_token]
    mov [rsp + 8], rax
    test ebx, ebx
    js .Lwread_done
    cmp ebx, [rip + paste_fd]
    jne .Lwread_done
    cmp rdx, [rip + wl_paste_generation]
    jne .Lwread_done
    call wl_paste_tick
    cmp r15, [rip + wl_paste_generation]
    jne .Lwread_done
    mov rax, [rsp + 8]
    cmp rax, [rip + wl_paste_token]
    jne .Lwread_done
    cmp ebx, [rip + paste_fd]
    jne .Lwread_done
    call wl_paste_limit
    mov r14, rax
    sub r14, [rip + paste_sb + SB_len]
    jc .Lwread_cancel
    xor r13d, r13d
    test r14, r14
    jz .Lwread_probe
    cmp r14, 65536
    jbe 1f
    mov r14d, 65536
1:  lea rdi, [rip + paste_sb]
    mov rsi, r14
    call sb_reserve
    mov r12, rax
    jmp .Lwread_read
.Lwread_probe:
    mov r13d, 1
    mov r12, rsp
    mov r14d, 1
.Lwread_read:
    call wl_paste_tick
    cmp r15, [rip + wl_paste_generation]
    jne .Lwread_done
    mov rax, [rsp + 8]
    cmp rax, [rip + wl_paste_token]
    jne .Lwread_done
    cmp ebx, [rip + paste_fd]
    jne .Lwread_done
    mov edi, ebx
    mov rsi, r12
    mov rdx, r14
    SYS SYS_read
    mov rdi, rbx
    mov rsi, rax
    mov edx, r13d
    call wl_paste_read_result
    jmp .Lwread_done
.Lwread_cancel:
    call wl_paste_reject
.Lwread_done:
    EPILOGUE

# Signed syscall result. Positive bytes already occupy the reserved tail, except a limit probe.
FN wl_paste_read_result
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    mov r14, [rip + wl_paste_generation]
    mov r15, [rip + wl_paste_token]
    test ebx, ebx
    js .Lwresult_done
    cmp ebx, [rip + paste_fd]
    jne .Lwresult_done
    call wl_paste_tick
    cmp r14, [rip + wl_paste_generation]
    jne .Lwresult_done
    cmp r15, [rip + wl_paste_token]
    jne .Lwresult_done
    cmp ebx, [rip + paste_fd]
    jne .Lwresult_done
    test r12, r12
    js .Lwresult_error
    jz .Lwresult_eof
    test r13d, r13d
    jnz .Lwresult_cancel
    call wl_paste_limit
    sub rax, [rip + paste_sb + SB_len]
    jc .Lwresult_cancel
    cmp r12, rax
    ja .Lwresult_cancel
    mov rax, [rip + paste_sb + SB_ptr]
    test rax, rax
    jz .Lwresult_cancel
    add [rip + paste_sb + SB_len], r12
    mov rcx, [rip + paste_sb + SB_len]
    mov byte ptr [rax + rcx], 0
    call time_ms
    cmp rax, [rip + wl_paste_deadline]
    jae .Lwresult_expired
    add rax, WCL_TIMEOUT
    mov [rip + wl_paste_deadline], rax
    jmp .Lwresult_done
.Lwresult_error:
    cmp r12, -EINTR
    je .Lwresult_done
    cmp r12, -EAGAIN
    je .Lwresult_done
.Lwresult_cancel:
    call wl_paste_reject
    jmp .Lwresult_done
.Lwresult_expired:
    call wl_paste_cancel
    jmp .Lwresult_done
.Lwresult_eof:
    call wl_paste_complete
.Lwresult_done:
    EPILOGUE

FN wl_paste_tick
    cmp dword ptr [rip + paste_fd], -1
    je 1f
    sub rsp, 8
    call time_ms
    add rsp, 8
    cmp rax, [rip + wl_paste_deadline]
    jae wl_paste_cancel
1:  ret

FN wl_paste_timeout
    cmp dword ptr [rip + paste_fd], -1
    jne 1f
    mov eax, -1
    ret
1:  sub rsp, 8
    call time_ms
    add rsp, 8
    mov rcx, [rip + wl_paste_deadline]
    cmp rcx, rax
    jbe 2f
    sub rcx, rax
    cmp rcx, WCL_TIMEOUT
    ja 2f
    mov eax, ecx
    ret
2:  xor eax, eax
    ret
