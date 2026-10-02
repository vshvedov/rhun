# scripted control: line commands from a file (--script) or a unix socket (--control)
#   key ctrl+s | type text | click x y [right|middle] | tap x y | move x y | down | up | scroll dy [ctrl]
#   open path | cmd name | shot file.ppm | wait ms | resize w h | print-doc | print-state | echo text | quit
#   wait-git | print-git | print-gitlog | print-scm | wait-update | print-update | print-project | print-palette
#   print-menu | focus 0|1
.include "rhun.inc"

.bss
.p2align 3
out: .zero SB_SIZE
cbuf: .zero SB_SIZE
oc_busy: .long 0                # running the client's lines
oc_eof: .long 0                 # the client closed meanwhile
addr: .zero 110
.globl g_headless
g_headless: .long 0

.text

# arg helpers: rbx = rest pointer, r12 = rest length
next_arg:
    mov rdi, rbx
    mov rsi, r12
    call next_word
    add rbx, rcx
    sub r12, rcx
    ret

next_int:
    call next_arg
    push rbx
    mov rdi, rax
    mov rsi, rdx
    xor ebx, ebx
    test rsi, rsi
    jz 1f
    cmp byte ptr [rdi], '-'
    jne 1f
    inc rdi
    dec rsi
    mov ebx, 1
1:  call parse_u64
    test ebx, ebx
    jz 2f
    neg rax
2:  pop rbx
    ret

# Render if needed. Headless and the Windows DIB renderer draw synchronously.
flush_frame:
.ifndef WINDOWS
    cmp dword ptr [rip + g_headless], 0
    je 1f
.endif
    cmp dword ptr [rip + g_dirty], 0
    je 1f
    PCALL P_draw
1:  ret

# emit_key(keysym, mods): derive the character like the platform does
emit_key:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    xor r13d, r13d
    cmp ebx, 0x20
    jb 1f
    cmp ebx, 0x7e
    ja 1f
    mov r13d, ebx
    # shift for letters
    test r12d, MOD_SHIFT
    jz 1f
    lea eax, [rbx - 'a']
    cmp eax, 25
    ja 1f
    sub r13d, 32
    sub ebx, 32
1:  mov edi, ebx
    mov esi, r13d
    mov edx, r12d
    call app_on_key
    pop r13
    pop r12
    pop rbx
    ret

# control_exec(line ptr, len) -> 0 ok, 1 quit, -1 unknown
FN control_exec
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
.ifdef WINDOWS
    # The script reader splits at LF; accept the CR left by Windows text editors.
    test r12, r12
    jz 8f
    cmp byte ptr [rbx + r12 - 1], 13
    jne 8f
    dec r12
8:
.endif
    lea rdi, [rip + out]
    call sb_clear
    call next_arg
    test rdx, rdx
    jz .Lce_ok
    mov r13, rax
    mov r14, rdx
    cmp byte ptr [r13], '#'
    je .Lce_ok
    # trim leading blank of the rest (for type/echo)
    mov rdi, rbx
    mov rsi, r12
    call trim
    mov rbx, rax
    mov r12, rdx
    lea r15, [rip + ctl_table]
1:  mov rdx, [r15]
    test rdx, rdx
    jz .Lce_unknown
    mov rdi, r13
    mov rsi, r14
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add r15, 16
    jmp 1b
2:  call [r15 + 8]
    push rax
    push rax
    call flush_frame
    pop rax
    pop rax
    EPILOGUE
.Lce_ok:
    xor eax, eax
    EPILOGUE
.Lce_unknown:
    lea rdi, [rip + out]
    lea rsi, [rip + .Lunknown]
    call sb_push_cstr
    mov rax, -1
    EPILOGUE

c_key:
    mov rdi, rbx
    mov rsi, r12
    call parse_combo
    test eax, eax
    jz 1f
    mov edi, eax
    mov esi, edx
    call emit_key
1:  xor eax, eax
    ret

c_type:
    push r13
    push r14
    sub rsp, 8
    xor r13d, r13d
1:  cmp r13, r12
    jae 2f
    lea rdi, [rbx + r13]
    mov rsi, r12
    sub rsi, r13
    call utf8_decode
    add r13, rdx
    mov r14d, eax
    mov edi, eax
    cmp eax, 0x7e
    jbe 3f
    or edi, 0x1000000
3:  mov esi, r14d
    xor edx, edx
    call app_on_key
    call flush_frame
    jmp 1b
2:  add rsp, 8
    pop r14
    pop r13
    xor eax, eax
    ret

c_move:
    call next_int
    push rax
    call next_int
    pop rdi
    mov esi, eax
    call app_on_motion
    xor eax, eax
    ret

c_click:
    call next_int
    push rax
    call next_int
    pop rdi
    push rdi
    push rax
    mov esi, eax
    call app_on_motion
    call flush_frame
    call next_arg
    mov r13d, BTN_LEFT
    test rdx, rdx
    jz 1f
    mov r13d, BTN_RIGHT
    cmp byte ptr [rax], 'r'
    je 1f
    mov r13d, BTN_MIDDLE
    cmp byte ptr [rax], 'm'
    je 1f
    mov r13d, BTN_LEFT
1:  mov edi, r13d
    mov esi, 1
    xor edx, edx
    call app_on_button
    call flush_frame
    mov edi, r13d
    call release
    pop rax
    pop rax
    xor eax, eax
    ret

# tap x y: a click posted at x y that leaves the pointer where it was, all before the next frame
# (a synthetic click, a mouse faster than the frames): no frame sees the pointer over x y
c_tap:
    push r13
    push r14
    push r15
    mov r13d, [rip + g_mx]
    mov r14d, [rip + g_my]
    call next_int
    mov r15d, eax
    call next_int
    mov edi, r15d
    mov esi, eax
    call app_on_motion
    mov edi, BTN_LEFT
    mov esi, 1
    xor edx, edx
    call app_on_button
    mov edi, BTN_LEFT
    xor esi, esi
    xor edx, edx
    call app_on_button
    mov edi, r13d
    mov esi, r14d
    call app_on_motion
    call flush_frame
    # the button came up before the frame: a move asked for now has no release to take
    mov dword ptr [rip + g_hl_grab], 0
    pop r15
    pop r14
    pop r13
    xor eax, eax
    ret

# release(button): unless a window move took the pointer (headless records that)
release:
    cmp dword ptr [rip + g_hl_grab], 0
    je 1f
    mov dword ptr [rip + g_hl_grab], 0
    ret
1:  xor esi, esi
    xor edx, edx
    jmp app_on_button

c_down:
    mov edi, BTN_LEFT
    mov esi, 1
    xor edx, edx
    call app_on_button
    xor eax, eax
    ret

c_up:
    mov edi, BTN_LEFT
    call release
    xor eax, eax
    ret

# print-cursor SHAPE SIZE: which cursor image the theme lookup picks
c_print_cursor:
    push r13
    push r14
    sub rsp, 8
    call next_int
    mov r13d, eax
    call next_int
    mov r14d, eax
    mov edi, r13d
    mov esi, r14d
    lea rdx, [rip + pc_xc]
    call xcursor_load
    test eax, eax
    jz 1f
    lea rdi, [rip + out]
    mov rsi, [rip + g_xcursor_found + SB_ptr]
    call sb_push_cstr
    jmp 2f
1:  mov edi, r13d
    mov esi, r14d
    lea rdx, [rip + pc_xc]
    call xcursor_builtin
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_builtin]
    call sb_push_cstr
2:  lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, [rip + pc_xc + XC_w]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 'x'
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, [rip + pc_xc + XC_h]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_hot]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + pc_xc + XC_xhot]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ','
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, [rip + pc_xc + XC_yhot]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + pc_xc + XC_file]
    call mem_free
    add rsp, 8
    pop r14
    pop r13
    xor eax, eax
    ret

# print-window: window requests seen by the headless platform
c_print_window:
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_moves]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_hl_moves]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_maximized]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_win_states]
    and esi, 1
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_minimized]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_hl_minimized]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_quit]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_quit]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_csd]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_csd]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

c_scroll:
    call next_int
    push rax
    push rax
    call next_arg
    xor ecx, ecx
    test rdx, rdx
    jz 1f
    mov ecx, MOD_CTRL
1:  pop rax
    pop rax
    xor edi, edi
    mov esi, eax
    mov edx, ecx
    call app_on_scroll
    xor eax, eax
    ret

c_open:
    mov rdi, rbx
    mov rsi, r12
    call mem_dup
    push rax
    push rax
    mov rdi, rax
    call app_open_path
    pop rdi
    pop rdi
    call mem_free
    xor eax, eax
    ret

c_cmd:
    mov rdi, rbx
    mov rsi, r12
    call cmd_find
    test rax, rax
    jz 1f
    call [rax + CMD_fn]
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    ret
1:  mov rax, -1
    ret

c_shot:
    mov rdi, rbx
    mov rsi, r12
    call mem_dup
    mov [rip + g_shot_path], rax
    mov dword ptr [rip + g_dirty], 1
    cmp dword ptr [rip + g_headless], 0
    je 1f
    PCALL P_draw
1:  xor eax, eax
    ret

# wait ms: run file watches, programs' output and timers for that long, drawing frames as they are
# due, as the event loop does
c_wait:
    push r13
    push r14
    push r15
    call next_int
    mov r13, rax
    call time_ms
    add r13, rax
1:  call time_ms
    mov r14, r13
    sub r14, rax
    jle 2f
    call app_timeout
    cmp eax, -1
    je 3f
    cmp rax, r14
    jae 3f
    mov r14d, eax
3:  mov edi, r14d
    call loop_poll
    call app_tick
    call flush_frame
    jmp 1b
2:  xor edi, edi
    call loop_poll
    call app_tick
    pop r15
    pop r14
    pop r13
    xor eax, eax
    ret

# wait-git: until git has answered (at most 10 s)
c_wait_git:
    push r13
    call time_ms
    lea r13, [rax + 10000]
1:  call git_busy
    test eax, eax
    jz 2f
    call time_ms
    cmp rax, r13
    jae 2f
    mov edi, 20
    call loop_poll
    call app_tick
    jmp 1b
2:  pop r13
    xor eax, eax
    ret

# wait-update: until the update check or install is done (at most 30 s)
c_wait_update:
    push r13
    call time_ms
    lea r13, [rax + 30000]
1:  call update_busy
    test eax, eax
    jz 2f
    call time_ms
    cmp rax, r13
    jae 2f
    mov edi, 20
    call loop_poll
    call app_tick
    jmp 1b
2:  pop r13
    xor eax, eax
    ret

# wait-ai: bounded test/control wait, including deferred detection.
c_wait_ai:
    push r13
    call time_ms
    lea r13, [rax + 30000]
1:  call ai_timeout
    cmp eax, -1
    je 2f
    call time_ms
    cmp rax, r13
    jae 2f
    mov edi, 20
    call loop_poll
    call app_tick
    jmp 1b
2:  pop r13
    xor eax, eax
    ret

c_print_ai:
    lea rdi, [rip + out]
    lea rsi, [rip + g_ai_desc]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

# print-frames: frames drawn since the last print-frames
c_print_frames:
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_frames]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_hl_frames]
    call sb_push_u64
    mov dword ptr [rip + g_hl_frames], 0
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

# print-update: the updater's state, the running and the latest version, the last error
c_print_update:
    lea rdi, [rip + out]
    call update_dump
    xor eax, eax
    ret

# print-git: branch, status, change marks of the current file
c_print_git:
    lea rdi, [rip + out]
    call git_dump
    xor eax, eax
    ret

# print-gitlog: the history tab's graph and the selected row's files
c_print_gitlog:
    lea rdi, [rip + out]
    call gitview_dump
    xor eax, eax
    ret

# print-scm: the source control panel: its button, the commit message, the last error, the changes
c_print_scm:
    lea rdi, [rip + out]
    call scm_dump
    xor eax, eax
    ret

# print-project: the project folder (the home folder as ~)
c_print_project:
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_project]
    call sb_push_cstr
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + pp_buf]
    call path_tilde
    lea rdi, [rip + out]
    lea rsi, [rip + pp_buf]
    call sb_push_cstr
1:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

# print-palette: the palette's field and rows
c_print_palette:
    lea rdi, [rip + out]
    call palette_print
    xor eax, eax
    ret

# print-menu: the open context menu's items
c_print_menu:
    lea rdi, [rip + out]
    call menu_print
    xor eax, eax
    ret

# print-term: the screen of the current terminal
c_print_term:
    lea rdi, [rip + out]
    call term_dump_current
    xor eax, eax
    ret

c_resize:
    call next_int
    push rax
    call next_int
    pop rdi
    mov esi, eax
    call headless_resize
    xor eax, eax
    ret

# focus 0|1: the window loses or gets the focus, as the platform reports it
c_focus:
    call next_int
    mov edi, eax
    call app_on_focus
    xor eax, eax
    ret

c_quit:
    mov eax, 1
    ret

c_echo:
    lea rdi, [rip + out]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

c_print_doc:
    push rbx
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 1f
    mov rdi, rbx
    call doc_len
    push rax
    push rax
    lea rdi, [rip + out]
    mov rsi, rax
    call sb_reserve
    pop rdx
    pop rdx
    mov rcx, rax
    push rdx
    push rdx
    mov rdi, rbx
    xor esi, esi
    call doc_copy
    pop rdx
    pop rdx
    add [rip + out + SB_len], rdx
    lea rdi, [rip + out]
    lea rsi, [rip + .Leod]
    call sb_push_cstr
1:  pop rbx
    xor eax, eax
    ret

# print-state: "tabs=N active=name line=L col=C sel=S dirty=D lang=X [vim=M] focus=F theme=T" (T is omarchy:ID when following);
#   an image tab has "image=WxH format=F zoom=Z fit=0|1" in place of the cursor and language
c_print_state:
    push rbx
    push r12
    sub rsp, 8
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_tabs]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, [rip + g_tabs + VEC_len]
    call sb_push_u64
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lps_image
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_active]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, [rbx + DOC_name]
    call sb_push_cstr
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_line]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    lea rdi, [rip + out]
    lea rsi, [rax + 1]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_col]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_col_of
    lea rdi, [rip + out]
    lea esi, [rax + 1]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_sel]
    call sb_push_cstr
    mov rdi, rbx
    call vim_sel
    sub rdx, rax
    lea rdi, [rip + out]
    mov rsi, rdx
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_dirty]
    call sb_push_cstr
    mov rdi, rbx
    call doc_dirty
    lea rdi, [rip + out]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_lang]
    call sb_push_cstr
    mov rax, [rbx + DOC_lang]
    lea rsi, [rip + .Lnone]
    test rax, rax
    jz 2f
    mov rsi, [rax + GR_name]
2:  lea rdi, [rip + out]
    call sb_push_cstr
    cmp dword ptr [rip + cfg_vim], 0
    je 1f
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_vim]
    call sb_push_cstr
    call vim_mode_name
    lea rdi, [rip + out]
    mov rsi, rax
    call sb_push_cstr
    jmp 1f
.Lps_image:
    # an image tab: its size, format and zoom
    mov rbx, [rip + g_file]
    test rbx, rbx
    jz 1f
    cmp qword ptr [rbx + DOC_img], 0
    je 1f
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_active]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, [rbx + DOC_name]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + out]
    call iv_describe
1:  lea rdi, [rip + out]
    lea rsi, [rip + .Ls_focus]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_focus]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_theme]
    call sb_push_cstr
    call theme_current_id
    lea rdi, [rip + out]
    mov rsi, rax
    call sb_push_cstr
    # following Omarchy: which theme that is
    mov rax, [rip + g_theme_cur]
    cmp rax, [rip + g_follow]
    jne 2f
    lea rdi, [rip + out]
    mov esi, ':'
    call sb_push_byte
    mov rdi, [rip + g_follow_target]
    call theme_entry
    lea rdi, [rip + out]
    mov rsi, [rax + TH_id]
    call sb_push_cstr
2:  # terminals: how many, and whether the panel is hidden
    call term_count
    test rax, rax
    jz 1f
    mov rbx, rax
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_term]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, rbx
    call sb_push_u64
    cmp dword ptr [rip + g_term_open], 0
    jne 1f
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_hidden]
    call sb_push_cstr
1:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    add rsp, 8
    pop r12
    pop rbx
    xor eax, eax
    ret

# print-syntax N: class digit per byte of line N
c_print_syntax:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call next_int
    mov r14, rax
    dec r14
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    cmp r14, [rbx + DOC_nlines]
    jae 9f
    mov rdi, rbx
    mov rsi, r14
    call syntax_prepare
    mov rdi, rbx
    mov rsi, r14
    call doc_line_text
    mov r12, rax
    mov r13, rdx
    lea rdi, [rip + out]
    lea rsi, [r13 + r13 + 2]
    call sb_reserve
    mov r15, rax
    # text line, then classes
    mov rdi, r15
    mov rsi, r12
    mov rcx, r13
    rep movsb
    mov byte ptr [rdi], 10
    lea r8, [r15 + r13 + 1]
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r12
    mov rcx, r13
    push r8
    push r8
    call syntax_line
    pop r8
    pop r8
    xor ecx, ecx
1:  cmp rcx, r13
    jae 2f
    movzx eax, byte ptr [r8 + rcx]
    lea rdx, [rip + .Ldigits]
    mov al, [rdx + rax]
    mov [r8 + rcx], al
    inc rcx
    jmp 1b
2:  lea rax, [r13 + r13 + 1]
    add [rip + out + SB_len], rax
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
9:  pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret

# print-agents [open N]: sessions and the open thread
c_print_agents:
    call next_int
    test rdx, rdx
    jz 1f
    dec rax
    js 1f
    mov rdi, rax
    call agents_open
1:  lea rdi, [rip + out]
    call agents_dump
    xor eax, eax
    ret

# xkey KEYCODE STATE: X11 only, runs a keycode through the server's keymap
c_xkey:
    call next_int
    push rax
    call next_int
    pop rdi
    mov esi, eax
    call x_key_test
    xor eax, eax
    ret

# control_run_script(path): execute every line, print outputs to stdout
FN control_run_script
    PROLOGUE
    call file_read_all
    test rax, rax
    jz .Lrs_fail
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d
.Lrs_line:
    cmp r14, r13
    jae .Lrs_done
    mov r15, r14
1:  cmp r15, r13
    jae 2f
    cmp byte ptr [r12 + r15], 10
    je 2f
    inc r15
    jmp 1b
2:  lea rdi, [r12 + r14]
    mov rsi, r15
    sub rsi, r14
    call control_exec
    mov rbx, rax
    mov rdi, 1
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    test rdx, rdx
    jz 3f
    call write_all
3:  cmp rbx, 1
    je .Lrs_done
    lea r14, [r15 + 1]
    jmp .Lrs_line
.Lrs_done:
    xor eax, eax
    EPILOGUE
.Lrs_fail:
    mov eax, 1
    EPILOGUE

# control_listen(path): accept connections, one command per line, reply "ok"/"error"
FN control_listen
.ifdef WINDOWS
    lea rdi, [rip + .Lwindows_control]
    jmp die
.endif
    PROLOGUE
    mov rbx, rdi
    # sun_path holds 104 bytes on macOS, 108 on Linux
    call strlen
    cmp rax, 103
    jbe 1f
    lea rdi, [rip + .Llong_path]
    call die
1:  mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js 9f
    mov [rip + lsock], eax
    mov rdi, rbx
    SYS SYS_unlink
    lea rdi, [rip + addr]
    mov word ptr [rdi], AF_UNIX
    add rdi, 2
    mov rsi, rbx
    call cstr_copy
    mov edi, [rip + lsock]
    lea rsi, [rip + addr]
    mov edx, 110
    SYS SYS_bind
    test rax, rax
    jns 2f
    lea rdi, [rip + .Lno_listen]
    call die
2:  mov edi, [rip + lsock]
    mov esi, 4
    SYS SYS_listen
    mov edi, [rip + lsock]
    mov esi, POLLIN
    lea rdx, [rip + on_accept]
    xor ecx, ecx
    call watch_add
9:  EPILOGUE

on_accept:
    push rbx
    mov edi, [rip + lsock]
    xor esi, esi
    xor edx, edx
    mov r10d, SOCK_CLOEXEC
    SYS SYS_accept4
    test rax, rax
    js 9f
    mov ebx, eax
    # while the client's command waits, the new one waits for it to finish
    cmp dword ptr [rip + oc_busy], 0
    je 2f
    mov edi, [rip + oc_next]
    mov [rip + oc_next], ebx
    test edi, edi
    js 9f
    SYS SYS_close
    jmp 9f
2:  mov edi, ebx
    call oc_install
9:  pop rbx
    ret

# oc_install(fd): the client from now on; one at a time, the previous one is dropped
oc_install:
    push rbx
    mov ebx, edi
    mov edi, [rip + csock]
    test edi, edi
    js 1f
    call watch_remove
    mov edi, [rip + csock]
    SYS SYS_close
1:  mov [rip + csock], ebx
    lea rdi, [rip + cbuf]
    call sb_clear
    mov edi, ebx
    mov esi, POLLIN
    lea rdx, [rip + on_client]
    xor ecx, ecx
    call watch_add
9:  pop rbx
    ret

on_client:
    PROLOGUE
    mov ebx, edi
    lea rdi, [rip + cbuf]
    mov esi, 4096
    call sb_reserve
    mov edi, ebx
    mov rsi, rax
    mov edx, 4096
    SYS SYS_read
    test rax, rax
    jle 7f
    add [rip + cbuf + SB_len], rax
    # a command that waits (wait-git) runs the loop, which comes back here: the lines after it
    # are only read now and run when it is done
    cmp dword ptr [rip + oc_busy], 0
    jne 9f
    mov dword ptr [rip + oc_busy], 1
.Loc_lines:
    mov edi, [rip + oc_next]
    test edi, edi
    jns .Loc_next
    mov r12, [rip + cbuf + SB_ptr]
    mov r13, [rip + cbuf + SB_len]
    xor ecx, ecx
1:  cmp rcx, r13
    jae 8f
    cmp byte ptr [r12 + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov r14, rcx
    mov rdi, r12
    mov rsi, rcx
    call control_exec
    mov r15, rax
    # reply: output then ok / error
    mov edi, ebx
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    test rdx, rdx
    jz 3f
    call write_all
3:  lea rsi, [rip + .Lok]
    mov edx, 3
    test r15, r15
    jns 4f
    lea rsi, [rip + .Lerror]
    mov edx, 6
4:  mov edi, ebx
    call write_all
    cmp r15, 1
    jne 5f
    mov dword ptr [rip + g_quit], 1
5:  # drop the processed line
    mov rdi, [rip + cbuf + SB_ptr]
    lea rsi, [rdi + r14 + 1]
    mov rdx, [rip + cbuf + SB_len]
    sub rdx, r14
    dec rdx
    mov [rip + cbuf + SB_len], rdx
    call memmove
    jmp .Loc_lines
8:  mov dword ptr [rip + oc_busy], 0
    cmp dword ptr [rip + oc_eof], 0
    je 9f
    mov dword ptr [rip + oc_eof], 0
    jmp .Loc_close
7:  cmp dword ptr [rip + oc_busy], 0
    je .Loc_close
    # the client left while a command waits: close when it is done
    mov dword ptr [rip + oc_eof], 1
    mov edi, ebx
    call watch_remove
    jmp 9f
.Loc_close:
    mov edi, ebx
    call watch_remove
    mov edi, ebx
    SYS SYS_close
    mov dword ptr [rip + csock], -1
9:  EPILOGUE
    # a client came while a command waited: it replaces this one
.Loc_next:
    mov dword ptr [rip + oc_next], -1
    mov dword ptr [rip + oc_busy], 0
    mov dword ptr [rip + oc_eof], 0
    call oc_install
    EPILOGUE

.section .rodata
.Llong_path: .asciz "rhun: the control socket path is too long (at most 103 bytes)"
.Lno_listen: .asciz "rhun: cannot create the control socket"
.Lunknown: .asciz "unknown command\n"
.Leod: .asciz "\n<eod>\n"
.Lok: .ascii "ok\n"
.Lerror: .ascii "error\n"
.Lnone: .asciz "none"
.Ls_tabs: .asciz "tabs="
.Ls_active: .asciz " active="
.Ls_line: .asciz " line="
.Ls_col: .asciz " col="
.Ls_sel: .asciz " sel="
.Ls_dirty: .asciz " dirty="
.Ls_lang: .asciz " lang="
.Ls_focus: .asciz " focus="
.Ls_vim: .asciz " vim="
.Ls_theme: .asciz " theme="
.Lc_key: .asciz "key"
.Lc_type: .asciz "type"
.Lc_move: .asciz "move"
.Lc_click: .asciz "click"
.Lc_tap: .asciz "tap"
.Lc_down: .asciz "down"
.Lc_up: .asciz "up"
.Lc_scroll: .asciz "scroll"
.Lc_open: .asciz "open"
.Lc_cmd: .asciz "cmd"
.Lc_shot: .asciz "shot"
.Lc_wait: .asciz "wait"
.Lc_resize: .asciz "resize"
.Lc_focus: .asciz "focus"
.Lc_quit: .asciz "quit"
.Lc_echo: .asciz "echo"
.Lc_print_doc: .asciz "print-doc"
.Lc_print_state: .asciz "print-state"
.Lc_print_syntax: .asciz "print-syntax"
.Lc_print_agents: .asciz "print-agents"
.Lc_xkey: .asciz "xkey"
.Lc_print_window: .asciz "print-window"
.Lc_print_cursor: .asciz "print-cursor"
.Lc_print_term: .asciz "print-term"
.Lc_print_git: .asciz "print-git"
.Lc_wait_git: .asciz "wait-git"
.Lc_print_gitlog: .asciz "print-gitlog"
.Lc_print_scm: .asciz "print-scm"
.Lc_wait_ai: .asciz "wait-ai"
.Lc_print_ai: .asciz "print-ai"
.Lc_wait_update: .asciz "wait-update"
.Lc_print_update: .asciz "print-update"
.Lc_print_frames: .asciz "print-frames"
.Lc_print_project: .asciz "print-project"
.Lc_print_palette: .asciz "print-palette"
.Lc_print_menu: .asciz "print-menu"
.Ls_project: .asciz "project="
.Ls_frames: .asciz "frames="
.Ls_term: .asciz " term="
.Ls_hidden: .asciz " hidden"
.Ls_builtin: .asciz "built-in"
.Ls_hot: .asciz " hot "
.Ls_moves: .asciz "moves="
.Ls_maximized: .asciz " maximized="
.Ls_minimized: .asciz " minimized="
.Ls_quit: .asciz " quit="
.Ls_csd: .asciz " csd="
.Ldigits: .ascii "0123456789abcdefghijk"
.p2align 3
ctl_table:
    .quad .Lc_key, c_key, .Lc_type, c_type, .Lc_move, c_move, .Lc_click, c_click, .Lc_tap, c_tap
    .quad .Lc_down, c_down, .Lc_up, c_up, .Lc_scroll, c_scroll, .Lc_open, c_open
    .quad .Lc_cmd, c_cmd, .Lc_shot, c_shot, .Lc_wait, c_wait, .Lc_resize, c_resize
    .quad .Lc_quit, c_quit, .Lc_echo, c_echo, .Lc_print_doc, c_print_doc
    .quad .Lc_print_state, c_print_state, .Lc_print_syntax, c_print_syntax, .Lc_print_agents, c_print_agents, .Lc_xkey, c_xkey
    .quad .Lc_print_window, c_print_window, .Lc_print_cursor, c_print_cursor, .Lc_print_term, c_print_term
    .quad .Lc_print_git, c_print_git, .Lc_wait_git, c_wait_git, .Lc_print_gitlog, c_print_gitlog
    .quad .Lc_print_scm, c_print_scm
    .quad .Lc_wait_ai, c_wait_ai, .Lc_print_ai, c_print_ai
    .quad .Lc_wait_update, c_wait_update, .Lc_print_update, c_print_update
    .quad .Lc_print_frames, c_print_frames, .Lc_print_project, c_print_project
    .quad .Lc_print_palette, c_print_palette, .Lc_print_menu, c_print_menu, .Lc_focus, c_focus, 0, 0

.data
lsock: .long -1
csock: .long -1
oc_next: .long -1               # a client that came while oc_busy
.bss
.p2align 3
pc_xc: .zero XC_SIZE
pp_buf: .zero 4096

CSTR .Lwindows_control, "rhun: --control is unavailable on Windows; use --script FILE"
