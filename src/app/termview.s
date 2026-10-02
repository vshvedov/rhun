# terminal panel: shells on pseudo-terminals, under the editor
.include "rhun.inc"

STRUCT
F TS_term, 8
F TS_wbuf, SB_SIZE      # bytes the program has not taken yet
F TS_pid, 4
F TS_fd, 4
F TS_name, 32
ENDSTRUCT TS_SIZE

.equ ID_TSPLIT, 0x6000
.equ ID_TNEW, 0x6002
.equ ID_TKILL, 0x6003
.equ ID_THIDE, 0x6004
.equ ID_TSCROLL, 0x6005
.equ ID_TTAB, 0x6100            # + index
.equ MAX_SESS, 16
.equ RBUF, 65536
.equ MAX_ZOMB, 16

.bss
.p2align 3
sessions: .zero VEC_SIZE        # TS*
cur: .quad 0
env: .quad 0
.globl g_face_term, g_term_open
g_face_term: .zero FACE_SIZE
g_term_open: .long 0
last_px: .long 0
.p2align 3
last_font: .quad 0
tcw: .long 0                    # cell size
tlh: .long 0
tbase: .long 0
gx: .long 0                     # grid of the current session
gy: .long 0
gcols: .long 0
grows: .long 0
wheel: .long 0
rep_held: .long 0               # the program was told about a press
sel_on: .long 0
sel_drag: .long 0
sel_unit: .long 0               # 1 characters, 2 words, 3 lines
.p2align 3
sel_a: .quad 0                  # anchor: absolute line << 16 | column
sel_b: .quad 0                  # other end
sel_s: .quad 0                  # ordered and extended to the unit
sel_e: .quad 0
scroll_px: .long 0
zombies: .zero 4 * MAX_ZOMB
nzomb: .long 0
.p2align 3
tmp: .zero SB_SIZE
rbuf: .zero RBUF
blank_cell: .zero 16

.text

# ---------------- sessions ----------------

# sess(i) -> TS*
sess:
    mov rax, [rip + sessions + VEC_ptr]
    mov rax, [rax + rdi*8]
    ret

# cur_sess() -> TS* or 0
cur_sess:
    xor eax, eax
    mov rdi, [rip + cur]
    cmp rdi, [rip + sessions + VEC_len]
    jae 1f
    jmp sess
1:  ret

# term_metrics(): the terminal face at the configured size
term_metrics:
    push rbx
    cvtsi2ss xmm0, dword ptr [rip + cfg_term_font_size]
    mulss xmm0, [rip + g_s]
    cvtss2si ebx, xmm0
    cmp ebx, 4
    jge 1f
    mov ebx, 4
1:  mov rax, [rip + g_font_code]
    cmp rax, [rip + last_font]
    jne 2f
    cmp ebx, [rip + last_px]
    je 9f
2:  mov [rip + last_font], rax
    mov [rip + last_px], ebx
    lea rdi, [rip + g_face_term]
    mov rsi, rax
    mov edx, ebx
    call face_init
    mov eax, [rip + g_face_term + FACE_cellw]
    cmp eax, 1
    jge 3f
    mov eax, 1
3:  mov [rip + tcw], eax
    mov eax, [rip + g_face_term + FACE_ascent]
    mov [rip + tbase], eax
    add eax, [rip + g_face_term + FACE_descent]
    cmp eax, 2
    jge 4f
    mov eax, 2
4:  mov [rip + tlh], eax
9:  pop rbx
    ret

# term_spawn() -> 1 if a shell started
FN term_spawn
    PROLOGUE 48
    cmp qword ptr [rip + sessions + VEC_len], MAX_SESS
    jae .Lsp_fail
    cmp qword ptr [rip + env], 0
    jne 1f
    lea rdi, [rip + env_extras]
    call env_make
    mov [rip + env], rax
1:  # the shell: the setting, $SHELL, /bin/sh
    mov dword ptr [rsp + 24], 0
    mov rdi, [rip + cfg_term_shell]
    cmp byte ptr [rdi], 0
    jne 2f
.ifdef MACOS
    # a login shell, as Terminal starts it: an app from the Dock has only launchd's PATH
    mov dword ptr [rsp + 24], 1
.endif
    lea rdi, [rip + .Lshell_env]
    call getenv
    mov rdi, rax
    test rax, rax
    jz 21f
    cmp byte ptr [rax], 0
    jne 2f
21: lea rdi, [rip + .Lsh]
2:  call proc_which
    test rax, rax
    jz .Lsp_fail
    mov r12, rax                # path
    mov [rsp], rax              # argv
    mov qword ptr [rsp + 8], 0
    cmp dword ptr [rsp + 24], 0
    je .Lsp_argv
    lea rax, [rip + .Llogin]
    mov [rsp + 8], rax
    mov qword ptr [rsp + 16], 0
.Lsp_argv:
    mov edi, 80
    mov esi, 24
    call pty_open
    test eax, eax
    js .Lsp_free
    mov r13d, eax               # master
    mov r14d, edx               # slave
    lea rdi, [rsp]
    mov rsi, [rip + env]
    mov rdx, [rip + g_project]
    mov ecx, r14d
    mov r8d, r14d
    mov r9d, r14d
    push 1
    push 1
    call proc_spawn
    add rsp, 16
    mov r15, rax
    mov edi, r14d
    SYS SYS_close
    test r15, r15
    jg 3f
    mov edi, r13d
    SYS SYS_close
    jmp .Lsp_free
3:  mov edi, TS_SIZE
    call mem_alloc
    mov rbx, rax
    mov [rbx + TS_pid], r15d
    mov [rbx + TS_fd], r13d
    mov edi, 80
    mov esi, 24
    mov edx, [rip + cfg_term_scrollback]
    call term_new
    mov [rbx + TS_term], rax
    # shell name for the tab
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call path_basename
    lea rdi, [rbx + TS_name]
    mov rsi, rax
    mov ecx, 31
4:  mov al, [rsi]
    test al, al
    jz 5f
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz 4b
5:  lea rdi, [rip + sessions]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    mov rax, [rip + sessions + VEC_len]
    dec rax
    mov [rip + cur], rax
    mov edi, r13d
    mov esi, POLLIN
    lea rdx, [rip + on_pty]
    mov rcx, rbx
    call watch_add
    mov rdi, r12
    call mem_free
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lsp_free:
    mov rdi, r12
    call mem_free
.Lsp_fail:
    lea rdi, [rip + .Lno_shell]
    call app_toast
    xor eax, eax
    EPILOGUE

# on_pty(fd, revents, session): output of the shell, room to write more
on_pty:
    PROLOGUE
    mov rbx, rdx
    mov r12d, esi
    test r12d, POLLOUT
    jz 1f
    call flush_wbuf
1:  mov r13d, 16                # at most 1 MiB, then let the window draw
2:  mov edi, [rbx + TS_fd]
    lea rsi, [rip + rbuf]
    mov edx, RBUF
    SYS SYS_read
    cmp rax, -EINTR
    je 2b
    cmp rax, -EAGAIN
    je 3f
    test rax, rax
    jle .Lop_end
    mov rdi, [rbx + TS_term]
    lea rsi, [rip + rbuf]
    mov rdx, rax
    call term_feed
    dec r13d
    jnz 2b
3:  call send_replies
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
.Lop_end:
    mov rdi, rbx
    call session_end
    EPILOGUE

# send_replies(): answers of the emulator back to the program (rbx session)
send_replies:
    push r12
    mov r12, [rbx + TS_term]
    mov rdx, [r12 + TM_out + SB_len]
    test rdx, rdx
    jz 1f
    mov rsi, [r12 + TM_out + SB_ptr]
    call send
    lea rdi, [r12 + TM_out]
    call sb_clear
1:  pop r12
    ret

# send(ptr, len): bytes for the program; what it cannot take now waits (rbx session)
send:
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rdx
    cmp dword ptr [rbx + TS_fd], 0
    jl 9f
    cmp qword ptr [rbx + TS_wbuf + SB_len], 0
    jne 5f
1:  test r13, r13
    jz 9f
    mov edi, [rbx + TS_fd]
    mov rsi, r12
    mov rdx, r13
    SYS SYS_write
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 4f
    test rax, rax
    js 9f
    add r12, rax
    sub r13, rax
    jmp 1b
4:  mov edi, [rbx + TS_fd]
    mov esi, POLLIN | POLLOUT
    call watch_set_events
5:  lea rdi, [rbx + TS_wbuf]
    mov rsi, r12
    mov rdx, r13
    call sb_push
9:  pop r14
    pop r13
    pop r12
    ret

# flush_wbuf(): write waiting bytes (rbx session)
flush_wbuf:
    push r12
    push r13
    push r14
1:  mov r13, [rbx + TS_wbuf + SB_len]
    test r13, r13
    jz 3f
    mov edi, [rbx + TS_fd]
    mov rsi, [rbx + TS_wbuf + SB_ptr]
    mov rdx, r13
    SYS SYS_write
    cmp rax, -EINTR
    je 1b
    test rax, rax
    jle 9f
    mov r12, rax
    mov rdi, [rbx + TS_wbuf + SB_ptr]
    lea rsi, [rdi + r12]
    mov rdx, r13
    sub rdx, r12
    call memmove
    sub [rbx + TS_wbuf + SB_len], r12
    jmp 1b
3:  mov edi, [rbx + TS_fd]
    mov esi, POLLIN
    call watch_set_events
9:  pop r14
    pop r13
    pop r12
    ret

# session_end(session): the shell is gone or is being closed
session_end:
    PROLOGUE
    mov rbx, rdi
    # take it out of the list
    xor ecx, ecx
1:  cmp rcx, [rip + sessions + VEC_len]
    jae 3f
    mov rax, [rip + sessions + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 2f
    inc rcx
    jmp 1b
2:  lea rdi, [rax + rcx*8]
    lea rsi, [rdi + 8]
    mov rdx, [rip + sessions + VEC_len]
    sub rdx, rcx
    dec rdx
    shl rdx, 3
    push rcx
    push rcx
    call memmove
    pop rcx
    pop rcx
    dec qword ptr [rip + sessions + VEC_len]
    mov rax, [rip + cur]
    cmp rcx, rax
    ja 3f
    jb 21f
    # the current one: the next takes its place, or the one before at the end
    cmp rax, [rip + sessions + VEC_len]
    jb 3f
21: test rax, rax
    jz 3f
    dec qword ptr [rip + cur]
3:  mov edi, [rbx + TS_fd]
    test edi, edi
    js 4f
    call watch_remove
    mov edi, [rbx + TS_fd]
    SYS SYS_close
4:  # the session's processes get SIGHUP; reap the shell now or later
    mov edi, [rbx + TS_pid]
    neg edi
    mov esi, SIGHUP
    SYS SYS_kill
    mov edi, [rbx + TS_pid]
    mov esi, SIGHUP
    SYS SYS_kill
    mov edi, [rbx + TS_pid]
    mov esi, 1
    call proc_wait
    cmp eax, -1
    jne 5f
    mov eax, [rip + nzomb]
    cmp eax, MAX_ZOMB
    jae 5f
    lea rcx, [rip + zombies]
    mov edx, [rbx + TS_pid]
    mov [rcx + rax*4], edx
    inc dword ptr [rip + nzomb]
5:  mov rdi, [rbx + TS_term]
    call term_free
    lea rdi, [rbx + TS_wbuf]
    call sb_free
    mov rdi, rbx
    call mem_free
    mov dword ptr [rip + sel_on], 0
    mov dword ptr [rip + rep_held], 0
    cmp qword ptr [rip + sessions + VEC_len], 0
    jne 6f
    mov dword ptr [rip + g_term_open], 0
    cmp dword ptr [rip + g_focus], FOCUS_TERMINAL
    jne 6f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
6:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# term_tick(): reap shells that took their time to exit
FN term_tick
    push rbx
    xor ebx, ebx
1:  cmp ebx, [rip + nzomb]
    jae 9f
    lea rax, [rip + zombies]
    mov edi, [rax + rbx*4]
    mov esi, 1
    call proc_wait
    cmp eax, -1
    jne 2f
    inc ebx
    jmp 1b
2:  # gone: last entry into this slot
    dec dword ptr [rip + nzomb]
    mov eax, [rip + nzomb]
    lea rcx, [rip + zombies]
    mov edx, [rcx + rax*4]
    mov [rcx + rbx*4], edx
    jmp 1b
9:  pop rbx
    ret

# ---------------- commands ----------------

# cmd_toggle_terminal(): show and focus the panel, hide it when it has focus
FN cmd_toggle_terminal
    cmp dword ptr [rip + g_term_open], 0
    je term_show
    cmp dword ptr [rip + g_focus], FOCUS_TERMINAL
    jne 1f
    mov dword ptr [rip + g_term_open], 0
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov dword ptr [rip + g_dirty], 1
    ret
1:  mov dword ptr [rip + g_focus], FOCUS_TERMINAL
    mov dword ptr [rip + g_dirty], 1
    ret

# term_show(): open the panel with a shell in it
term_show:
    cmp qword ptr [rip + sessions + VEC_len], 0
    jne 1f
    push rax
    call term_spawn
    pop rcx
    test eax, eax
    jz 2f
1:  mov dword ptr [rip + g_term_open], 1
    mov dword ptr [rip + g_focus], FOCUS_TERMINAL
    mov dword ptr [rip + g_dirty], 1
2:  ret

FN cmd_new_terminal
    push rax
    call term_spawn
    pop rcx
    test eax, eax
    jz 1f
    mov dword ptr [rip + g_term_open], 1
    mov dword ptr [rip + g_focus], FOCUS_TERMINAL
1:  ret

FN cmd_kill_terminal
    call cur_sess
    test rax, rax
    jz 1f
    mov rdi, rax
    jmp session_end
1:  ret

FN cmd_clear_terminal
    call cur_sess
    test rax, rax
    jz 1f
    mov rdi, [rax + TS_term]
    mov dword ptr [rip + sel_on], 0
    mov dword ptr [rip + g_dirty], 1
    jmp term_clear
1:  ret

# cmd_term_copy(): the selection to the clipboard
FN cmd_term_copy
    PROLOGUE
    call cur_sess
    test rax, rax
    jz 9f
    cmp dword ptr [rip + sel_on], 0
    je 9f
    mov rbx, [rax + TS_term]
    lea rdi, [rip + tmp]
    call sb_clear
    mov rcx, [rbx + TM_total]
    mov rdx, [rip + sel_s]
    mov r12, rdx
    shr rdx, 16
    sub rdx, rcx
    and r12d, 0xffff
    mov r8, [rip + sel_e]
    mov r9, r8
    shr r8, 16
    sub r8, rcx
    and r9d, 0xffff
    mov eax, [rbx + TM_cols]
    dec eax
    cmp r9d, eax
    cmova r9d, eax
    inc r9d
    mov rdi, rbx
    lea rsi, [rip + tmp]
    mov ecx, r12d
    call term_text
    mov rdi, [rip + tmp + SB_ptr]
    mov rsi, [rip + tmp + SB_len]
    test rsi, rsi
    jz 9f
    PCALL P_clip_set
9:  EPILOGUE

FN cmd_term_paste
    PCALL P_clip_get
    ret

# term_panel_paste(ptr, len): the clipboard arrived for the terminal
FN term_panel_paste
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call cur_sess
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, [rbx + TS_term]
    mov rsi, r12
    mov rdx, r13
    call term_paste
    call send_replies
    mov rax, [rbx + TS_term]
    mov dword ptr [rax + TM_view], 0
9:  EPILOGUE

# ---------------- keys ----------------

# term_panel_key(keysym, cp, mods) -> 1 if the terminal took the key
#   ctrl+shift combinations, ctrl+` and tab switching stay with rhun; ctrl+shift+c/v copy and paste
FN term_panel_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call cur_sess
    test rax, rax
    jz .Ltk_no
    mov rbx, rax
    test r14d, MOD_SUPER
    jnz .Ltk_no
.ifdef MACOS
    # Command copies, pastes and runs rhun's shortcuts; Control types control characters
    cmp dword ptr [rip + g_mac_cmd], 0
    je .Ltk_ctl
    test r14d, MOD_CTRL
    jz .Ltk_ctl
    cmp r12d, 0x80
    jae .Ltk_ctl
    mov eax, r12d
    or eax, 0x20
    cmp eax, 'c'
    jne .Ltk_cmd_v
    call cmd_term_copy
    jmp .Ltk_yes
.Ltk_cmd_v:
    cmp eax, 'v'
    jne .Ltk_no
    call cmd_term_paste
    jmp .Ltk_yes
.Ltk_ctl:
.endif
    mov eax, r14d
    and eax, MOD_CTRL | MOD_SHIFT
    cmp eax, MOD_CTRL | MOD_SHIFT
    jne 2f
    mov eax, r12d
    or eax, 0x20
    cmp eax, 'c'
    jne 1f
    call cmd_term_copy
    jmp .Ltk_yes
1:  cmp eax, 'v'
    jne .Ltk_no
    call cmd_term_paste
    jmp .Ltk_yes
2:  test r14d, MOD_CTRL
    jz 3f
    cmp r12d, '`'
    je .Ltk_no
    cmp r12d, KEY_TAB
    je .Ltk_no
    cmp r12d, KEY_ISO_LEFT_TAB
    je .Ltk_no
    cmp r12d, KEY_PAGEUP
    je .Ltk_no
    cmp r12d, KEY_PAGEDOWN
    je .Ltk_no
3:  test r14d, MOD_SHIFT
    jz 5f
    # shift+PageUp / PageDown scroll back; shift+Insert pastes
    mov r15, [rbx + TS_term]
    mov eax, [rip + grows]
    dec eax
    cmp r12d, KEY_PAGEUP
    je 4f
    neg eax
    cmp r12d, KEY_PAGEDOWN
    je 4f
    cmp r12d, KEY_INSERT
    jne 5f
    call cmd_term_paste
    jmp .Ltk_yes
4:  mov edi, eax
    call view_scroll
    jmp .Ltk_yes
5:  mov rdi, [rbx + TS_term]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call term_key
    test eax, eax
    jz .Ltk_yes
    call send_replies
    mov rax, [rbx + TS_term]
    mov dword ptr [rax + TM_view], 0
    mov dword ptr [rip + sel_on], 0
.Ltk_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Ltk_no:
    xor eax, eax
    EPILOGUE

# view_scroll(lines): move the view back (positive) or forward in the scrollback (rbx session)
view_scroll:
    mov rcx, [rbx + TS_term]
    mov eax, [rcx + TM_view]
    add eax, edi
    jns 1f
    xor eax, eax
1:  cmp eax, [rcx + TM_sblen]
    jle 2f
    mov eax, [rcx + TM_sblen]
2:  mov [rcx + TM_view], eax
    mov dword ptr [rip + g_dirty], 1
    ret

# ---------------- drawing ----------------

# term_panel_draw(x, y, w, h)
FN term_panel_draw
    PROLOGUE 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    call term_metrics
    COLOR r8d, T_BG
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    # the top edge sets the height
    M eax, MI_3
    mov edi, ID_TSPLIT
    mov esi, [rsp]
    mov edx, [rsp + 4]
    sub edx, eax
    mov ecx, [rsp + 8]
    lea r8d, [rax + rax + 1]
    call ui_btn
    test eax, UB_HOVER | UB_HELD
    jz 1f
    mov dword ptr [rip + g_cursor], CUR_NS
1:  test eax, UB_HELD
    jz 2f
    mov eax, [rsp + 4]
    add eax, [rsp + 12]
    sub eax, [rip + g_my]
    cvtsi2ss xmm0, eax
    divss xmm0, [rip + g_s]
    cvtss2si eax, xmm0
    cmp eax, 80
    jge 11f
    mov eax, 80
11: cmp eax, 2000
    jle 12f
    mov eax, 2000
12: mov [rip + cfg_term_h], eax
    mov dword ptr [rip + g_settings_changed], 1
    mov dword ptr [rip + g_dirty], 1
2:  call header_draw
    call cur_sess
    test rax, rax
    jz .Lpd_ret
    mov rbx, rax
    mov r12, [rbx + TS_term]
    # grid
    M eax, MI_28
    add eax, [rsp + 4]
    add eax, [rip + g_mt + 4*MI_2]
    mov [rsp + 20], eax         # grid y
    mov ecx, [rsp + 4]
    add ecx, [rsp + 12]
    sub ecx, eax
    sub ecx, [rip + g_mt + 4*MI_4]
    mov [rsp + 28], ecx         # grid h
    M eax, MI_12
    mov ecx, [rsp]
    add ecx, eax
    mov [rsp + 16], ecx         # grid x
    mov ecx, [rsp + 8]
    sub ecx, eax
    sub ecx, eax
    mov [rsp + 24], ecx         # grid w
    mov eax, [rsp + 16]
    mov [rip + gx], eax
    mov eax, [rsp + 20]
    mov [rip + gy], eax
    mov eax, [rsp + 24]
    xor edx, edx
    div dword ptr [rip + tcw]
    cmp eax, 2
    jge 3f
    mov eax, 2
3:  mov [rip + gcols], eax
    mov eax, [rsp + 28]
    xor edx, edx
    div dword ptr [rip + tlh]
    cmp eax, 1
    jge 4f
    mov eax, 1
4:  mov [rip + grows], eax
    cmp eax, [r12 + TM_rows]
    jne 5f
    mov eax, [rip + gcols]
    cmp eax, [r12 + TM_cols]
    je 6f
5:  mov rdi, r12
    mov esi, [rip + gcols]
    mov edx, [rip + grows]
    call term_resize
    mov edi, [rbx + TS_fd]
    mov esi, [rip + gcols]
    mov edx, [rip + grows]
    mov ecx, [rsp + 24]
    mov r8d, [rsp + 28]
    call pty_resize
    mov dword ptr [rip + sel_on], 0
6:  call grid_input
    mov edi, [rsp + 16]
    mov esi, [rsp + 20]
    mov edx, [rsp + 24]
    mov ecx, [rsp + 28]
    call gfx_clip_push
    mov rdi, r12
    call draw_grid
    call gfx_clip_pop
    # scrollbar over the scrollback
    mov eax, [r12 + TM_sblen]
    add eax, [r12 + TM_rows]
    imul eax, [rip + tlh]
    mov [rsp + 32], eax         # content
    mov eax, [r12 + TM_sblen]
    sub eax, [r12 + TM_view]
    imul eax, [rip + tlh]
    mov [rip + scroll_px], eax
    mov eax, [r12 + TM_rows]
    imul eax, [rip + tlh]
    push rax
    mov eax, [rsp + 32 + 8]
    push rax
    mov edi, ID_TSCROLL
    mov esi, [rsp + 16 + 16]
    add esi, [rsp + 16 + 24]
    mov edx, [rsp + 16 + 20]
    M ecx, MI_12
    mov r8d, [rsp + 16 + 28]
    lea r9, [rip + scroll_px]
    call ui_scrollbar
    add rsp, 16
    cmp dword ptr [rip + g_active], ID_TSCROLL
    jne .Lpd_ret
    mov eax, [rip + scroll_px]
    xor edx, edx
    div dword ptr [rip + tlh]
    mov ecx, [r12 + TM_sblen]
    sub ecx, eax
    jns 7f
    xor ecx, ecx
7:  mov [r12 + TM_view], ecx
.Lpd_ret:
    EPILOGUE

# header_draw(): session tabs and buttons (frame of term_panel_draw at [rsp + 8 + 8])
header_draw:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    # panel rect: [rbp + 16] x, +20 y, +24 w, +28 h
    M r15d, MI_28               # header height
    mov r12d, [rbp + 16]
    add r12d, [rip + g_mt + 4*MI_8]
    xor ebx, ebx
.Lhd_tab:
    cmp rbx, [rip + sessions + VEC_len]
    jae .Lhd_buttons
    mov rdi, rbx
    call sess
    mov r13, rax
    # title from the program, else the shell's name
    mov r14, [r13 + TS_term]
    mov rsi, [r14 + TM_title + SB_ptr]
    mov rdx, [r14 + TM_title + SB_len]
    test rdx, rdx
    jnz 1f
    lea rsi, [r13 + TS_name]
    mov rdi, rsi
    push rsi
    push rsi
    call strlen
    pop rsi
    pop rsi
    mov rdx, rax
1:  mov [rsp], rsi
    mov [rsp + 8], rdx
    lea rdi, [rip + g_face_small]
    call text_width
    mov r14d, eax
    mov edi, 200
    call sc
    cmp r14d, eax
    cmovg r14d, eax
    add r14d, [rip + g_mt + 4*MI_20]    # tab width
    lea edi, [rbx + ID_TTAB]
    mov esi, r12d
    mov edx, [rbp + 20]
    mov ecx, r14d
    mov r8d, r15d
    call ui_btn
    mov [rsp + 16], eax
    test eax, UB_PRESS
    jz 2f
    mov [rip + cur], rbx
    mov dword ptr [rip + g_focus], FOCUS_TERMINAL
    mov dword ptr [rip + sel_on], 0
2:  test dword ptr [rsp + 16], UB_HOVER
    jz 3f
    test dword ptr [rip + g_pressed], 1 << BTN_MIDDLE
    jz 3f
    mov rdi, r13
    call session_end
    jmp .Lhd_buttons
3:  # label
    COLOR r9d, T_MUTED
    cmp rbx, [rip + cur]
    jne 4f
    COLOR r9d, T_FG
    mov edi, r12d
    mov esi, [rbp + 20]
    add esi, r15d
    sub esi, [rip + g_mt + 4*MI_2]
    mov edx, r14d
    M ecx, MI_2
    COLOR r8d, T_ACCENT
    cmp dword ptr [rip + g_focus], FOCUS_TERMINAL
    je 31f
    COLOR r8d, T_MUTED
31: push r9
    push r9
    call gfx_fill
    pop r9
    pop r9
    jmp 5f
4:  test dword ptr [rsp + 16], UB_HOVER
    jz 5f
    COLOR r9d, T_FG
5:  mov eax, r15d
    sub eax, [rip + g_face_small + FACE_ascent]
    sub eax, [rip + g_face_small + FACE_descent]
    sar eax, 1
    add eax, [rbp + 20]
    add eax, [rip + g_face_small + FACE_ascent]
    mov edx, eax
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_10]
    mov eax, r14d
    sub eax, [rip + g_mt + 4*MI_20]
    push rax
    push rax
    lea rdi, [rip + g_face_small]
    mov rcx, [rsp + 16]
    mov r8, [rsp + 24]
    call text_draw_fit
    add rsp, 16
    add r12d, r14d
    inc rbx
    jmp .Lhd_tab
.Lhd_buttons:
    # right side: new, close, hide
    M r13d, MI_24
    mov r12d, [rbp + 16]
    add r12d, [rbp + 24]
    sub r12d, [rip + g_mt + 4*MI_8]
    mov r14d, r15d
    sub r14d, r13d
    sar r14d, 1
    add r14d, [rbp + 20]
    sub r12d, r13d
    mov edi, ID_THIDE
    mov esi, r12d
    mov edx, r14d
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_CHEV_DN2
    call ui_icon_btn_bg
    test eax, UB_CLICK
    jz 1f
    mov dword ptr [rip + g_term_open], 0
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
1:  sub r12d, r13d
    sub r12d, [rip + g_mt + 4*MI_4]
    mov edi, ID_TKILL
    mov esi, r12d
    mov edx, r14d
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_CLOSE
    call ui_icon_btn_bg
    test eax, UB_CLICK
    jz 2f
    call cmd_kill_terminal
2:  sub r12d, r13d
    sub r12d, [rip + g_mt + 4*MI_4]
    mov edi, ID_TNEW
    mov esi, r12d
    mov edx, r14d
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_PLUS
    call ui_icon_btn_bg
    test eax, UB_CLICK
    jz 3f
    call cmd_new_terminal
3:  add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

# cell_at(): the grid cell under the pointer -> eax col, edx row (clamped)
cell_at:
    mov eax, [rip + g_mx]
    sub eax, [rip + gx]
    jns 1f
    xor eax, eax
1:  xor edx, edx
    div dword ptr [rip + tcw]
    mov ecx, [rip + gcols]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov r8d, eax
    mov eax, [rip + g_my]
    sub eax, [rip + gy]
    jns 2f
    xor eax, eax
2:  xor edx, edx
    div dword ptr [rip + tlh]
    mov ecx, [rip + grows]
    dec ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov edx, eax
    mov eax, r8d
    ret

# grid_input(): mouse on the grid (rbx session, r12 term)
grid_input:
    push r13
    push r14
    push r15
    mov edi, [rip + gx]
    mov esi, [rip + gy]
    mov edx, [rip + gcols]
    imul edx, [rip + tcw]
    mov ecx, [rip + grows]
    imul ecx, [rip + tlh]
    call ui_in
    mov r13d, eax               # pointer over the grid
    # the program asked for the mouse; shift keeps it for selecting
    xor r14d, r14d
    cmp dword ptr [r12 + TM_mouse], 0
    je 1f
    test dword ptr [rip + g_mods], MOD_SHIFT
    jnz 1f
    mov r14d, 1
1:  test r13d, r13d
    jz .Lgi_drag
    test r14d, r14d
    jnz 2f
    mov dword ptr [rip + g_cursor], CUR_TEXT
2:  # wheel
    mov eax, [rip + g_scroll_y]
    test eax, eax
    jz .Lgi_press
    add eax, [rip + wheel]
    cdq
    idiv dword ptr [rip + tlh]
    mov [rip + wheel], edx
    mov r15d, eax               # lines, positive = down
    test r15d, r15d
    jz .Lgi_press
    test r14d, r14d
    jz 3f
    # to the program: button 64 up, 65 down, once per line
31: call cell_at
    mov ecx, eax
    mov r8d, edx
    mov esi, 64
    test r15d, r15d
    js 32f
    mov esi, 65
32: mov rdi, r12
    xor edx, edx
    mov r9d, [rip + g_mods]
    call term_mouse
    test r15d, r15d
    js 33f
    dec r15d
    jnz 31b
    jmp 36f
33: inc r15d
    jnz 31b
    jmp 36f
3:  test dword ptr [r12 + TM_modes], TMM_ALT
    jz 35f
    # full-screen programs without mouse get arrow keys
34: mov rdi, r12
    mov esi, KEY_DOWN
    test r15d, r15d
    jns 341f
    mov esi, KEY_UP
341:xor edx, edx
    xor ecx, ecx
    call term_key
    test r15d, r15d
    js 342f
    dec r15d
    jnz 34b
    jmp 36f
342:inc r15d
    jnz 34b
    jmp 36f
35: mov edi, r15d
    neg edi
    call view_scroll
    jmp .Lgi_press
36: call send_replies
.Lgi_press:
    test dword ptr [rip + g_pressed], 1 << BTN_RIGHT
    jz 4f
    mov dword ptr [rip + g_focus], FOCUS_TERMINAL
    lea rdi, [rip + term_menu]
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call ctx_menu_open
    jmp .Lgi_ret
4:  test dword ptr [rip + g_pressed], 1 << BTN_MIDDLE
    jz 41f
    test r14d, r14d
    jz 41f
    mov esi, 1
    call report_press
41: test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz .Lgi_drag
    mov dword ptr [rip + g_focus], FOCUS_TERMINAL
    test r14d, r14d
    jz 5f
    xor esi, esi
    call report_press
    jmp .Lgi_ret
5:  # selection: characters, words or lines by click count
    call cell_at
    mov r15d, eax
    mov eax, edx
    sub eax, [r12 + TM_view]
    movsxd rax, eax
    add rax, [r12 + TM_total]
    shl rax, 16
    or rax, r15
    mov [rip + sel_a], rax
    mov [rip + sel_b], rax
    mov eax, [rip + g_clicks]
    mov [rip + sel_unit], eax
    mov dword ptr [rip + sel_drag], 1
    mov dword ptr [rip + sel_on], 0
    cmp eax, 1
    je .Lgi_ret
    call sel_update
    jmp .Lgi_ret
.Lgi_drag:
    # a reported press: motion and release go to the program
    cmp dword ptr [rip + rep_held], 0
    je 6f
    test dword ptr [rip + g_mdown], 0x0e
    jnz 51f
    call cell_at
    mov ecx, eax
    mov r8d, edx
    mov rdi, r12
    mov esi, [rip + rep_held]
    dec esi
    mov edx, 1
    mov r9d, [rip + g_mods]
    call term_mouse
    mov dword ptr [rip + rep_held], 0
    call send_replies
    jmp .Lgi_ret
51: call cell_at
    shl edx, 16
    or eax, edx
    cmp eax, [rip + rep_cell]
    je .Lgi_ret
    mov [rip + rep_cell], eax
    mov ecx, eax
    and ecx, 0xffff
    shr eax, 16
    mov r8d, eax
    mov rdi, r12
    mov esi, [rip + rep_held]
    dec esi
    mov edx, 2
    mov r9d, [rip + g_mods]
    call term_mouse
    call send_replies
    jmp .Lgi_ret
6:  cmp dword ptr [rip + sel_drag], 0
    je 7f
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jnz 61f
    mov dword ptr [rip + sel_drag], 0
    jmp .Lgi_ret
61: call cell_at
    mov r15d, eax
    mov r13d, edx
    # drag past the edges scrolls
    mov eax, [rip + g_my]
    cmp eax, [rip + gy]
    jge 62f
    mov edi, 1
    call view_scroll
    jmp 63f
62: mov ecx, [rip + grows]
    imul ecx, [rip + tlh]
    add ecx, [rip + gy]
    cmp eax, ecx
    jl 63f
    mov edi, -1
    call view_scroll
63: mov eax, r13d
    sub eax, [r12 + TM_view]
    movsxd rax, eax
    add rax, [r12 + TM_total]
    shl rax, 16
    or rax, r15
    cmp rax, [rip + sel_b]
    jne 64f
    cmp dword ptr [rip + sel_on], 0
    jne .Lgi_ret
    cmp rax, [rip + sel_a]
    je .Lgi_ret
64: mov [rip + sel_b], rax
    call sel_update
    jmp .Lgi_ret
7:  # motion without buttons (mode 1003)
    test r13d, r13d
    jz .Lgi_ret
    cmp dword ptr [r12 + TM_mouse], 1003
    jne .Lgi_ret
    test r14d, r14d
    jz .Lgi_ret
    call cell_at
    shl edx, 16
    or eax, edx
    cmp eax, [rip + rep_cell]
    je .Lgi_ret
    mov [rip + rep_cell], eax
    mov ecx, eax
    and ecx, 0xffff
    shr eax, 16
    mov r8d, eax
    mov rdi, r12
    mov esi, 3
    mov edx, 2
    mov r9d, [rip + g_mods]
    call term_mouse
    call send_replies
.Lgi_ret:
    pop r15
    pop r14
    pop r13
    ret

# report_press(button): a press the program gets (rbx session, r12 term)
report_press:
    lea eax, [rsi + 1]
    mov [rip + rep_held], eax
    push rsi
    call cell_at
    pop rsi
    mov ecx, eax
    mov r8d, edx
    shl edx, 16
    or eax, edx
    mov [rip + rep_cell], eax
    mov rdi, r12
    xor edx, edx
    mov r9d, [rip + g_mods]
    call term_mouse
    jmp send_replies

# sel_update(): ordered selection ends, widened to words or lines (r12 term)
sel_update:
    push r13
    push r14
    push r15
    mov dword ptr [rip + sel_on], 1
    mov rax, [rip + sel_a]
    mov rcx, [rip + sel_b]
    cmp rax, rcx
    jbe 1f
    xchg rax, rcx
1:  mov r13, rax
    mov r14, rcx
    mov eax, [rip + sel_unit]
    cmp eax, 3
    jne 2f
    and r13, -65536
    or r14, 0xffff
    jmp 9f
2:  cmp eax, 2
    jne 9f
    mov rdi, r13
    mov esi, -1
    call word_edge
    mov r13, rax
    mov rdi, r14
    mov esi, 1
    call word_edge
    mov r14, rax
9:  mov [rip + sel_s], r13
    mov [rip + sel_e], r14
    mov dword ptr [rip + g_dirty], 1
    pop r15
    pop r14
    pop r13
    ret

# word_edge(point, dir) -> point moved to the end of the word in that direction (r12 term)
word_edge:
    push rbx
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r13, rdi
    mov r14d, esi
    mov rax, r13
    shr rax, 16
    sub rax, [r12 + TM_total]
    mov rdi, r12
    mov esi, eax
    call term_row
    test rax, rax
    jz 9f
    mov rbx, rax
    mov r15d, r13d
    and r15d, 0xffff
    call is_word_cell
    test eax, eax
    jz 9f
1:  lea eax, [r15 + r14]
    test eax, eax
    js 8f
    cmp eax, [rbx + LN_cap]
    jge 8f
    cmp eax, [r12 + TM_cols]
    jge 8f
    push r15
    mov r15d, eax
    call is_word_cell
    pop rcx
    test eax, eax
    jnz 1b
    mov r15d, ecx
8:  and r13, -65536
    or r13, r15
9:  mov rax, r13
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop rbx
    ret
# is_word_cell(): rbx line, r15d column
is_word_cell:
    xor eax, eax
    cmp r15d, [rbx + LN_cap]
    jge 9f
    movsxd rcx, r15d
    lea rcx, [rcx + rcx*2]
    mov ecx, [rbx + rcx*4 + LN_HDR]
    and ecx, CP_MASK
    cmp ecx, ' '
    jbe 9f
    cmp ecx, 128
    jae 8f
    lea rdx, [rip + .Lword_stop]
1:  movzx r8d, byte ptr [rdx]
    test r8d, r8d
    jz 8f
    cmp ecx, r8d
    je 9f
    inc rdx
    jmp 1b
8:  mov eax, 1
9:  ret

# selected(abs line, col) -> eax 1 if inside the selection
selected:
    xor eax, eax
    cmp dword ptr [rip + sel_on], 0
    je 9f
    shl rdi, 16
    or rdi, rsi
    cmp rdi, [rip + sel_s]
    jb 9f
    cmp rdi, [rip + sel_e]
    ja 9f
    mov eax, 1
9:  ret

# tcolor(value, default) -> argb of a cell color
tcolor:
    mov eax, edi
    shr eax, 24
    jz 8f
    cmp eax, 1
    jne 7f
    movzx edi, dil
    cmp edi, 16
    jae 1f
    lea rax, [rip + g_theme]
    mov eax, [rax + rdi*4 + 4*T_TERM]
    ret
1:  cmp edi, 232
    jae 2f
    # 6x6x6 cube
    sub edi, 16
    mov eax, edi
    xor edx, edx
    mov ecx, 36
    div ecx
    mov r8d, edx
    call cube
    mov r9d, eax
    mov eax, r8d
    xor edx, edx
    mov ecx, 6
    div ecx
    mov r8d, edx
    call cube
    shl r9d, 8
    or r9d, eax
    mov eax, r8d
    call cube
    shl r9d, 8
    or eax, r9d
    or eax, 0xff000000
    ret
2:  # gray ramp
    sub edi, 232
    imul eax, edi, 10
    add eax, 8
    imul eax, eax, 0x010101
    or eax, 0xff000000
    ret
7:  mov eax, edi
    or eax, 0xff000000
    ret
8:  mov eax, esi
    ret
cube:
    test eax, eax
    jz 1f
    imul eax, eax, 40
    add eax, 55
1:  ret

# cell_colors(cell, selected) -> eax text, edx background
cell_colors:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    mov edi, [rbx + 8]
    COLOR esi, T_BG
    call tcolor
    mov r13d, eax
    mov edi, [rbx + 4]
    COLOR esi, T_FG
    call tcolor
    mov ecx, [rbx]
    test ecx, A_INVERSE
    jz 1f
    xchg eax, r13d
1:  test ecx, A_DIM
    jz 2f
    mov edi, eax
    mov esi, r13d
    mov edx, 100
    call color_mix
2:  test r12d, r12d
    jz 3f
    COLOR r13d, T_SELECTION
3:  mov edx, r13d
    pop r13
    pop r12
    pop rbx
    ret

# draw_grid(t): the visible rows and the cursor
draw_grid:
    PROLOGUE 64
    mov rbx, rdi
    xor r12d, r12d              # row on screen
.Ldg_row:
    cmp r12d, [rip + grows]
    jae .Ldg_cursor
    mov esi, r12d
    sub esi, [rbx + TM_view]
    mov [rsp + 40], esi         # term row
    mov rdi, rbx
    call term_row
    test rax, rax
    jz .Ldg_next
    mov r13, rax                # line
    movsxd rax, dword ptr [rsp + 40]
    add rax, [rbx + TM_total]
    mov [rsp + 16], rax         # absolute line
    mov eax, r12d
    imul eax, [rip + tlh]
    add eax, [rip + gy]
    mov [rsp + 24], eax         # y
    # backgrounds, in runs
    xor r14d, r14d
    mov r15d, -1
.Ldg_bg:
    cmp r14d, [rip + gcols]
    jae .Ldg_bg_end
    call row_cell
    mov rdi, rax
    push rdi
    mov rdi, [rsp + 16 + 8]
    mov esi, r14d
    call selected
    pop rdi
    mov esi, eax
    call cell_colors
    test r15d, r15d
    js 1f
    cmp edx, [rsp + 28]
    je 2f
    mov [rsp + 44], edx
    call bg_run
    mov edx, [rsp + 44]
1:  mov r15d, r14d
    mov [rsp + 28], edx
2:  inc r14d
    jmp .Ldg_bg
.Ldg_bg_end:
    test r15d, r15d
    js 3f
    call bg_run
3:  # characters
    xor r14d, r14d
.Ldg_ch:
    cmp r14d, [rip + gcols]
    jae .Ldg_next
    call row_cell
    mov r15, rax
    mov ecx, [r15]
    test ecx, A_HIDDEN | A_WIDE2
    jnz .Ldg_ch_next
    test ecx, A_UNDER | A_STRIKE
    jnz 4f
    and ecx, CP_MASK
    cmp ecx, ' '
    jbe .Ldg_ch_next
4:  mov rdi, [rsp + 16]
    mov esi, r14d
    call selected
    mov rdi, r15
    mov esi, eax
    call cell_colors
    mov [rsp + 32], eax
    mov edi, [r15]
    mov esi, r14d
    imul esi, [rip + tcw]
    add esi, [rip + gx]
    mov [rsp + 36], esi
    mov edx, [rsp + 24]
    mov ecx, eax
    call draw_char
    call char_lines
.Ldg_ch_next:
    inc r14d
    jmp .Ldg_ch
.Ldg_next:
    inc r12d
    jmp .Ldg_row
.Ldg_cursor:
    cmp dword ptr [rbx + TM_view], 0
    jne .Ldg_ret
    test dword ptr [rbx + TM_modes], TMM_HIDE
    jnz .Ldg_ret
    mov eax, [rbx + TM_cx]
    cmp eax, [rip + gcols]
    jae .Ldg_ret
    mov esi, [rbx + TM_cy]
    cmp esi, [rip + grows]
    jae .Ldg_ret
    mov rdi, rbx
    call term_row
    mov r13, rax
    mov r14d, [rbx + TM_cx]
    call row_cell
    mov r15, rax
    mov eax, r14d
    imul eax, [rip + tcw]
    add eax, [rip + gx]
    mov [rsp], eax              # x
    mov eax, [rbx + TM_cy]
    imul eax, [rip + tlh]
    add eax, [rip + gy]
    mov [rsp + 4], eax          # y
    mov eax, [rip + tcw]
    test dword ptr [r15], A_WIDE
    jz 5f
    add eax, eax
5:  mov [rsp + 8], eax          # w
    # without focus: an outline
    cmp dword ptr [rip + g_focus], FOCUS_TERMINAL
    jne 6f
    cmp dword ptr [rip + g_win_focused], 0
    jne 7f
6:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rip + tlh]
    COLOR r8d, T_CURSOR
    call outline
    jmp .Ldg_ret
7:  mov eax, [rbx + TM_cursor]
    cmp eax, 3
    jb 9f
    cmp eax, 5
    jb 8f
    # bar
    mov edi, [rsp]
    mov esi, [rsp + 4]
    M edx, MI_2
    mov ecx, [rip + tlh]
    COLOR r8d, T_CURSOR
    call gfx_fill
    jmp .Ldg_ret
8:  # underline
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rip + tlh]
    sub esi, [rip + g_mt + 4*MI_2]
    mov edx, [rsp + 8]
    M ecx, MI_2
    COLOR r8d, T_CURSOR
    call gfx_fill
    jmp .Ldg_ret
9:  # block, the character on it in the background color
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rip + tlh]
    COLOR r8d, T_CURSOR
    call gfx_fill
    mov edi, [r15]
    mov ecx, edi
    and ecx, CP_MASK
    cmp ecx, ' '
    jbe .Ldg_ret
    mov esi, [rsp]
    mov edx, [rsp + 4]
    COLOR ecx, T_BG
    call draw_char
.Ldg_ret:
    EPILOGUE
# row_cell(): r13 line, r14d column -> rax cell (a blank past the line's end)
row_cell:
    lea rax, [rip + blank_cell]
    cmp r14d, [r13 + LN_cap]
    jae 1f
    movsxd rax, r14d
    lea rax, [rax + rax*2]
    lea rax, [r13 + rax*4 + LN_HDR]
1:  ret
# bg_run(): cells [r15d, r14d) in the color at [rsp + 28 + 8] unless it is the panel's
bg_run:
    mov r8d, [rsp + 28 + 8]
    COLOR eax, T_BG
    cmp r8d, eax
    je 1f
    mov edi, r15d
    imul edi, [rip + tcw]
    add edi, [rip + gx]
    mov esi, [rsp + 24 + 8]
    mov edx, r14d
    sub edx, r15d
    imul edx, [rip + tcw]
    mov ecx, [rip + tlh]
    jmp gfx_fill
1:  ret
# char_lines(): underline and strike for the cell r15 at [rsp + 36 + 8], row y [rsp + 24 + 8]
char_lines:
    mov eax, [r15]
    test eax, A_UNDER | A_STRIKE
    jz 9f
    push rbx
    mov ebx, eax
    mov edx, [rip + tcw]
    test ebx, A_WIDE
    jz 1f
    add edx, edx
1:  test ebx, A_UNDER
    jz 2f
    push rdx
    mov edi, [rsp + 36 + 24]
    mov esi, [rsp + 24 + 24]
    add esi, [rip + tbase]
    inc esi
    M ecx, MI_1
    mov r8d, [rsp + 32 + 24]
    call gfx_fill
    pop rdx
2:  test ebx, A_STRIKE
    jz 3f
    mov edi, [rsp + 36 + 16]
    mov esi, [rip + g_face_term + FACE_ascent]
    imul esi, esi, 3
    shr esi, 3
    neg esi
    add esi, [rsp + 24 + 16]
    add esi, [rip + tbase]
    M ecx, MI_1
    mov r8d, [rsp + 32 + 16]
    call gfx_fill
3:  pop rbx
9:  ret

# outline(x, y, w, h, argb): 1px frame
outline:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebx, r8d
    M ecx, MI_1
    call gfx_fill
    mov edi, r12d
    lea esi, [r13 + r15]
    sub esi, [rip + g_mt + 4*MI_1]
    mov edx, r14d
    M ecx, MI_1
    mov r8d, ebx
    call gfx_fill
    mov edi, r12d
    mov esi, r13d
    M edx, MI_1
    mov ecx, r15d
    mov r8d, ebx
    call gfx_fill
    lea edi, [r12 + r14]
    sub edi, [rip + g_mt + 4*MI_1]
    mov esi, r13d
    M edx, MI_1
    mov ecx, r15d
    mov r8d, ebx
    call gfx_fill
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# draw_char(cell value, x, y, argb): one character in its cell
draw_char:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15d, edi               # attributes
    mov ebx, edi
    and ebx, CP_MASK
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    cmp ebx, ' '
    jbe 9f
    # lines and blocks are drawn to fill the cell
    lea eax, [rbx - 0x2500]
    cmp eax, 0x80
    jae 1f
    lea rcx, [rip + box_table]
    movzx eax, byte ptr [rcx + rax]
    test eax, eax
    jz 3f
    mov edi, eax
    call box_char
    jmp 9f
1:  cmp eax, 0xa0
    jae 2f
    sub eax, 0x80
    mov edi, eax
    call block_char
    jmp 9f
2:  lea eax, [rbx - 0xe0b0]
    cmp eax, 2
    ja 3f
    test eax, 1
    jnz 3f
    mov edi, eax
    call powerline
    jmp 9f
3:  lea rdi, [rip + g_face_term]
    mov esi, ebx
    call face_glyph
    mov rbx, rax
    mov rdx, [rbx + GL_bits]
    test rdx, rdx
    jz 9f
    movsx edi, word ptr [rbx + GL_left]
    add edi, r12d
    mov esi, r13d
    add esi, [rip + tbase]
    movsx eax, word ptr [rbx + GL_top]
    sub esi, eax
    movzx ecx, word ptr [rbx + GL_w]
    movzx r8d, word ptr [rbx + GL_h]
    mov r9d, r14d
    push rdi
    push rsi
    call gfx_mask
    pop rsi
    pop rdi
    test r15d, A_BOLD
    jz 9f
    # bold: once more, a pixel to the right
    inc edi
    mov rdx, [rbx + GL_bits]
    movzx ecx, word ptr [rbx + GL_w]
    movzx r8d, word ptr [rbx + GL_h]
    mov r9d, r14d
    call gfx_mask
9:  pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# box_char(arms): r12d x, r13d y, r14d color; arms: 2 bits each for left, up, right, down (1 light, 2 heavy, 3 double)
box_char:
    push rbx
    push r15
    sub rsp, 24
    mov ebx, edi
    # light thickness from the cell width
    mov eax, [rip + tcw]
    shr eax, 3
    cmp eax, 1
    jge 1f
    mov eax, 1
1:  mov [rsp], eax
    xor r15d, r15d              # arm
2:  cmp r15d, 4
    jae 9f
    mov ecx, r15d
    add ecx, ecx
    mov eax, ebx
    shr eax, cl
    and eax, 3
    jz 8f
    mov [rsp + 4], eax          # weight
    cmp eax, 3
    jne 3f
    # double: two light lines apart
    mov eax, [rsp]
    neg eax
    mov [rsp + 8], eax
    mov edi, [rsp]
    call arm
    mov eax, [rsp]
    mov [rsp + 8], eax
    mov edi, [rsp]
    call arm
    jmp 8f
3:  mov edi, [rsp]
    cmp eax, 2
    jne 4f
    add edi, edi
4:  mov dword ptr [rsp + 8], 0
    call arm
8:  inc r15d
    jmp 2b
9:  add rsp, 24
    pop r15
    pop rbx
    ret
# arm(thickness): r15d 0 left, 1 up, 2 right, 3 down; offset across at box_char's [rsp + 8]
arm:
    push rbx
    mov ebx, edi
    mov r9d, [rsp + 24]
    test r15d, 1
    jnz 2f
    # horizontal, meeting the vertical line's far edge
    mov esi, [rip + tlh]
    sub esi, ebx
    sar esi, 1
    add esi, r13d
    add esi, r9d
    mov eax, [rip + tcw]
    sub eax, ebx
    sar eax, 1
    mov edi, r12d
    lea edx, [rax + rbx]
    test r15d, r15d
    jz 1f
    add edi, eax
    mov edx, [rip + tcw]
    sub edx, eax
1:  mov ecx, ebx
    mov r8d, r14d
    call gfx_fill
    pop rbx
    ret
2:  mov edi, [rip + tcw]
    sub edi, ebx
    sar edi, 1
    add edi, r12d
    add edi, r9d
    mov eax, [rip + tlh]
    sub eax, ebx
    sar eax, 1
    mov esi, r13d
    lea ecx, [rax + rbx]
    cmp r15d, 1
    je 3f
    add esi, eax
    mov ecx, [rip + tlh]
    sub ecx, eax
3:  mov edx, ebx
    mov r8d, r14d
    call gfx_fill
    pop rbx
    ret

# block_char(index from U+2580): r12d x, r13d y, r14d color
block_char:
    push rbx
    lea rax, [rip + block_table]
    mov ebx, [rax + rdi*4]
    movzx eax, bl
    cmp eax, 0xfe
    je .Lbc_quad
    cmp eax, 0xff
    je .Lbc_shade
    # rectangle in eighths: x0, y0, x1, y1
    movzx eax, bl
    imul eax, [rip + tcw]
    shr eax, 3
    lea edi, [r12 + rax]
    movzx eax, bh
    imul eax, [rip + tlh]
    shr eax, 3
    lea esi, [r13 + rax]
    mov eax, ebx
    shr eax, 16
    movzx eax, al
    imul eax, [rip + tcw]
    shr eax, 3
    add eax, r12d
    mov edx, eax
    sub edx, edi
    mov eax, ebx
    shr eax, 24
    imul eax, [rip + tlh]
    shr eax, 3
    add eax, r13d
    mov ecx, eax
    sub ecx, esi
    mov r8d, r14d
    call gfx_fill
    pop rbx
    ret
.Lbc_shade:
    movzx eax, bh
    mov edi, r14d
    mov esi, eax
    call color_alpha
    mov r8d, eax
    mov edi, r12d
    mov esi, r13d
    mov edx, [rip + tcw]
    mov ecx, [rip + tlh]
    call gfx_fill
    pop rbx
    ret
.Lbc_quad:
    # quadrants: 1 upper left, 2 upper right, 4 lower left, 8 lower right
    movzx ebx, bh
    push r15
    xor r15d, r15d
1:  cmp r15d, 4
    jae 9f
    bt ebx, r15d
    jnc 8f
    mov eax, [rip + tcw]
    shr eax, 1
    mov edi, r12d
    mov edx, eax
    test r15d, 1
    jz 2f
    add edi, eax
    mov edx, [rip + tcw]
    sub edx, eax
2:  mov eax, [rip + tlh]
    shr eax, 1
    mov esi, r13d
    mov ecx, eax
    test r15d, 2
    jz 3f
    add esi, eax
    mov ecx, [rip + tlh]
    sub ecx, eax
3:  mov r8d, r14d
    call gfx_fill
8:  inc r15d
    jmp 1b
9:  pop r15
    pop rbx
    ret

# powerline(index from U+E0B0): the solid arrows, r12d x, r13d y, r14d color
powerline:
    push rbx
    push r15
    sub rsp, 8
    mov ebx, edi
    mov edi, [rip + tcw]
    mov esi, [rip + tlh]
    call raster_begin
    cvtsi2ss xmm8, dword ptr [rip + tcw]
    cvtsi2ss xmm9, dword ptr [rip + tlh]
    movss xmm10, xmm9
    mulss xmm10, [rip + f_half]
    xorps xmm11, xmm11
    # solid triangle pointing right (0) or left (2)
    cmp ebx, 0
    jne 1f
    movss xmm0, xmm11
    movss xmm1, xmm11
    movss xmm2, xmm8
    movss xmm3, xmm10
    call pl_edge
    movss xmm0, xmm8
    movss xmm1, xmm10
    movss xmm2, xmm11
    movss xmm3, xmm9
    call pl_edge
    movss xmm0, xmm11
    movss xmm1, xmm9
    movss xmm2, xmm11
    movss xmm3, xmm11
    call pl_edge
    jmp .Lpl_done
1:  movss xmm0, xmm8
    movss xmm1, xmm11
    movss xmm2, xmm8
    movss xmm3, xmm9
    call pl_edge
    movss xmm0, xmm8
    movss xmm1, xmm9
    movss xmm2, xmm11
    movss xmm3, xmm10
    call pl_edge
    movss xmm0, xmm11
    movss xmm1, xmm10
    movss xmm2, xmm8
    movss xmm3, xmm11
    call pl_edge
    jmp .Lpl_done
.Lpl_done:
    mov edi, [rip + tcw]
    imul edi, [rip + tlh]
    call mem_alloc
    mov rbx, rax
    mov rdi, rax
    call raster_end
    mov edi, r12d
    mov esi, r13d
    mov rdx, rbx
    mov ecx, [rip + tcw]
    mov r8d, [rip + tlh]
    mov r9d, r14d
    call gfx_mask
    mov rdi, rbx
    call mem_free
    add rsp, 8
    pop r15
    pop rbx
    ret
# pl_edge(xmm0..3): raster_line keeping xmm8-xmm15
pl_edge:
    sub rsp, 136
    movdqu [rsp], xmm8
    movdqu [rsp + 16], xmm9
    movdqu [rsp + 32], xmm10
    movdqu [rsp + 48], xmm11
    movdqu [rsp + 64], xmm12
    movdqu [rsp + 80], xmm13
    movdqu [rsp + 96], xmm14
    movdqu [rsp + 112], xmm15
    call raster_line
    movdqu xmm8, [rsp]
    movdqu xmm9, [rsp + 16]
    movdqu xmm10, [rsp + 32]
    movdqu xmm11, [rsp + 48]
    movdqu xmm12, [rsp + 64]
    movdqu xmm13, [rsp + 80]
    movdqu xmm14, [rsp + 96]
    movdqu xmm15, [rsp + 112]
    add rsp, 136
    ret

# term_dump_current(sb): the current terminal's screen, for scripts
FN term_dump_current
    push rbx
    mov rbx, rdi
    call cur_sess
    test rax, rax
    jz 1f
    mov rdi, [rax + TS_term]
    mov rsi, rbx
    call term_dump
1:  pop rbx
    ret

# term_count() -> sessions
FN term_count
    mov rax, [rip + sessions + VEC_len]
    ret

.data
rep_cell: .long -1

.section .rodata
.Lshell_env: .asciz "SHELL"
.Llogin: .asciz "-l"
.ifdef WINDOWS
.Lsh: .asciz "powershell.exe"
.else
.Lsh: .asciz "/bin/sh"
.endif
.Lno_shell: .asciz "Could not start a shell"
.Lword_stop: .asciz "()[]{}<>'\"`,;|&"
.Lenv_term: .asciz "TERM=xterm-256color"
.Lenv_color: .asciz "COLORTERM=truecolor"
.Lenv_prog: .asciz "TERM_PROGRAM=rhun"
.Lm_copy: .asciz "Copy"
.Lm_paste: .asciz "Paste"
.Lm_clear: .asciz "Clear"
.Lm_kill: .asciz "Kill Terminal"
.p2align 3
env_extras: .quad .Lenv_term, .Lenv_color, .Lenv_prog, 0
term_menu:
    .quad .Lm_copy, cmd_term_copy, .Lm_paste, cmd_term_paste, .Lm_clear, cmd_clear_terminal
    .quad .Lm_kill, cmd_kill_terminal, 0, 0

# U+2500..257F: arms left, up, right, down (2 bits each: 1 light, 2 heavy, 3 double); 0 uses the font
box_table:
    .byte 0x11, 0x22, 0x44, 0x88, 0x11, 0x22, 0x44, 0x88, 0x11, 0x22, 0x44, 0x88, 0x50, 0x60, 0x90, 0xa0
    .byte 0x41, 0x42, 0x81, 0x82, 0x14, 0x24, 0x18, 0x28, 0x05, 0x06, 0x09, 0x0a, 0x54, 0x64, 0x58, 0x94
    .byte 0x98, 0x68, 0xa4, 0xa8, 0x45, 0x46, 0x49, 0x85, 0x89, 0x4a, 0x86, 0x8a, 0x51, 0x52, 0x61, 0x62
    .byte 0x91, 0x92, 0xa1, 0xa2, 0x15, 0x16, 0x25, 0x26, 0x19, 0x1a, 0x29, 0x2a, 0x55, 0x56, 0x65, 0x66
    .byte 0x59, 0x95, 0x99, 0x5a, 0x69, 0x96, 0xa5, 0x6a, 0xa6, 0x9a, 0xa9, 0xaa, 0x11, 0x22, 0x44, 0x88
    .byte 0x33, 0xcc, 0x70, 0xd0, 0xf0, 0x43, 0xc1, 0xc3, 0x34, 0x1c, 0x3c, 0x07, 0x0d, 0x0f, 0x74, 0xdc
    .byte 0xfc, 0x47, 0xcd, 0xcf, 0x73, 0xd1, 0xf3, 0x37, 0x1d, 0x3f, 0x77, 0xdd, 0xff, 0x50, 0x41, 0x05
    .byte 0x14, 0x00, 0x00, 0x00, 0x01, 0x04, 0x10, 0x40, 0x02, 0x08, 0x20, 0x80, 0x21, 0x84, 0x12, 0x48
# U+2580..259F: x0, y0, x1, y1 in eighths of the cell; 0xff shade (alpha), 0xfe quadrants (mask)
.p2align 2
block_table:
    .byte 0, 0, 8, 4
    .byte 0, 7, 8, 8
    .byte 0, 6, 8, 8
    .byte 0, 5, 8, 8
    .byte 0, 4, 8, 8
    .byte 0, 3, 8, 8
    .byte 0, 2, 8, 8
    .byte 0, 1, 8, 8
    .byte 0, 0, 8, 8
    .byte 0, 0, 7, 8
    .byte 0, 0, 6, 8
    .byte 0, 0, 5, 8
    .byte 0, 0, 4, 8
    .byte 0, 0, 3, 8
    .byte 0, 0, 2, 8
    .byte 0, 0, 1, 8
    .byte 4, 0, 8, 8
    .byte 255, 64, 0, 0
    .byte 255, 128, 0, 0
    .byte 255, 192, 0, 0
    .byte 0, 0, 8, 1
    .byte 7, 0, 8, 8
    .byte 254, 4, 0, 0
    .byte 254, 8, 0, 0
    .byte 254, 1, 0, 0
    .byte 254, 13, 0, 0
    .byte 254, 9, 0, 0
    .byte 254, 7, 0, 0
    .byte 254, 11, 0, 0
    .byte 254, 2, 0, 0
    .byte 254, 6, 0, 0
    .byte 254, 14, 0, 0
