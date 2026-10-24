# scripted control: line commands from a file (--script) or a unix socket (--control)
#   key ctrl+s | type text | click x y [right|middle|shift|ctrl] | tap x y | move x y | down | up | scroll dy [ctrl]
#   open path | cmd name | shot file.ppm | wait ms | resize w h | print-doc | print-state | echo text | quit
#   wait-git | print-git | print-gitlog | print-scm | wait-update | print-update | print-project | print-palette
#   print-menu | focus out|in
#   multi-cursor: click x y alt|shift+alt (print-selections and drag are in wsctl.s)
.include "rhun.inc"

.bss
.p2align 3
out: .zero SB_SIZE
ctl_value: .zero 1024
cbuf: .zero SB_SIZE
tbuf: .zero SB_SIZE
oc_busy: .long 0                # running the client's lines
oc_eof: .long 0                 # the client closed meanwhile
.p2align 3
wait_ext_state: .quad 0         # wait-ext: the state waited for
wait_ext_state_len: .quad 0
addr: .zero 110
.globl g_headless
g_headless: .long 0
.p2align 3
.globl g_ctl_cur, g_ctl_cur_len
g_ctl_cur: .quad 0              # the control line being run
g_ctl_cur_len: .quad 0

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
.ifdef MACOS
    # Scripted Command keys use the same Ctrl flag and provenance as Cocoa events.
    xor eax, eax
    test r12d, MOD_SUPER
    jz 9f
    mov eax, 1
    test r12d, MOD_CTRL
    jz 8f
    xor eax, eax               # Command with Control stays terminal control input
8:  and r12d, ~MOD_SUPER
    or r12d, MOD_CTRL
9:  mov [rip + g_mac_cmd], eax
.endif
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
.ifdef MACOS
    mov dword ptr [rip + g_mac_cmd], 0
.endif
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
    mov [rip + g_ctl_cur], rbx  # the line being run (the frame probes log it)
    mov [rip + g_ctl_cur_len], r12
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
    jz .Lce_more
    mov rdi, r13
    mov rsi, r14
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add r15, 16
    jmp 1b
.Lce_more:
    # the other parts' tables (ctl_tables): fn(out, rest, rest len) -> rax as above
    lea rax, [rip + ctl_tables]
    mov [rsp], rax
11: mov rax, [rsp]
    mov r15, [rax]
    test r15, r15
    jz .Lce_unknown
    add qword ptr [rsp], 8
12: mov rdx, [r15]
    test rdx, rdx
    jz 11b
    mov rdi, r13
    mov rsi, r14
    call str_eq_cstr
    test eax, eax
    jnz 13f
    add r15, 16
    jmp 12b
13: lea rdi, [rip + out]
    mov rsi, rbx
    mov rdx, r12
2:  call [r15 + 8]
.Lce_done:
    push rax
3:  push rax
    push rax
    call term_frame_now         # a command ends with a frame that shows all output so far
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

c_modifiers:
    mov rdi, rbx
    mov rsi, r12
    call parse_combo
    mov edi, edx
    call app_on_modifiers
    xor eax, eax
    ret

c_key_up:
    mov rdi, rbx
    mov rsi, r12
    call parse_combo
    test eax, eax
    jz 1f
    mov edi, eax
    mov esi, edx
    call viewpic_key_up
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
    mov dword ptr [rip + click_mods], 0
    mov r13d, BTN_LEFT
    test rdx, rdx
    jz 1f
    # multi-cursor: alt, shift+alt, ctrl+alt: a left click with those held
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    call parse_combo
    mov ecx, edx
    pop rdx
    pop rax
    test ecx, MOD_ALT
    jz 20f
    mov [rip + click_mods], ecx
    jmp 1f
    # shift: a left click with Shift held, pressed and released
20: cmp byte ptr [rax], 's'
    jne 21f
    mov dword ptr [rip + click_mods], MOD_SHIFT
    jmp 1f
    # ctrl: Ctrl+click, which is Cmd+click on macOS (Command arrives as Ctrl)
21: cmp byte ptr [rax], 'c'
    jne 2f
    mov dword ptr [rip + click_mods], MOD_CTRL
    jmp 1f
2:  mov r13d, BTN_RIGHT
    cmp byte ptr [rax], 'r'
    je 1f
    mov r13d, BTN_MIDDLE
    cmp byte ptr [rax], 'm'
    je 1f
    mov r13d, BTN_LEFT
1:  mov edi, r13d
    mov esi, 1
    mov edx, [rip + click_mods]
    call app_on_button
    call flush_frame
    mov edi, r13d
    mov esi, [rip + click_mods]
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
# release(button, mods)
release:
    cmp dword ptr [rip + g_hl_grab], 0
    je 1f
    mov dword ptr [rip + g_hl_grab], 0
    ret
1:  mov edx, esi
    xor esi, esi
    jmp app_on_button

c_down:
    mov edi, BTN_LEFT
    mov esi, 1
    xor edx, edx
    call app_on_button
    xor eax, eax
    ret

# up-down: a release and the next press before one frame, as a busy event queue delivers them
c_updown:
    mov edi, BTN_LEFT
    xor esi, esi
    xor edx, edx
    call app_on_button
    mov edi, BTN_LEFT
    mov esi, 1
    xor edx, edx
    call app_on_button
    xor eax, eax
    ret

c_up:
    mov edi, BTN_LEFT
    xor esi, esi
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

c_print_shape:
    lea rdi, [rip + out]
    mov esi, [rip + g_cursor]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

# scroll dy [mods]: the wheel, with modifiers held as a key combination names them (ctrl, shift+alt)
c_scroll:
    call next_int
    push rax
    push rax
    call next_arg
    xor ecx, ecx
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call parse_combo
    mov ecx, edx
1:  pop rax
    pop rax
    xor edi, edi
    mov esi, eax
    mov edx, ecx
    call app_on_scroll
    xor eax, eax
    ret

# scroll-x dx: a sideways wheel or trackpad
c_scroll_x:
    call next_int
    mov edi, eax
    xor esi, esi
    xor edx, edx
    call app_on_scroll
    xor eax, eax
    ret

# print-settings: the rows the settings page shows, "section.key" each
c_print_settings:
    lea rdi, [rip + out]
    call settings_dump
    xor eax, eax
    ret

# print-scroll: "x=PX y=N max=PX track=X,Y,W,H", the editor's scroll (y in 1/256 lines)
c_print_scroll:
    lea rdi, [rip + out]
    call editor_scroll_dump
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
    mov dword ptr [rip + g_dirty], 1    # the frame that shows it loads it (and tells extensions)
    xor eax, eax
    ret

c_cmd:
    mov rdi, rbx
    mov rsi, r12
    call cmd_find
    test rax, rax
    jz 1f
    mov rdi, rax                # commands get their CMD* (extensions' commands share one fn)
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

# wait-term TEXT: until the current terminal's screen shows TEXT (10 s at most): a shell's prompt,
# or what a command printed, rather than a guess at how long it takes
c_wait_term:
    push r13
    push r14
    push r15
    mov r14, rbx
    mov r15, r12
    call time_ms
    lea r13, [rax + 10000]
1:  lea rdi, [rip + tbuf]
    call sb_clear
    lea rdi, [rip + tbuf]
    call term_dump_current
    mov rsi, [rip + tbuf + SB_len]
    cmp rsi, r15
    jb 3f
    mov rdi, [rip + tbuf + SB_ptr]
    mov rdx, r14
    mov rcx, r15
    call str_find
    test rax, rax
    jns 2f
3:  call time_ms
    cmp rax, r13
    jae 2f
    mov edi, 20
    call loop_poll
    call app_tick
    call flush_frame
    jmp 1b
2:  pop r15
    pop r14
    pop r13
    xor eax, eax
    ret

# wait ms: run file watches, programs' output and timers for that long, drawing frames as they are
# due, as the event loop does
c_wait:
    push r13
    push r14
    push r15
    call next_int
    mov r13, rax
    # what the step before queued (a file opened, a key typed) goes out now, as the main loop's
    # tick after an input event would, not after the first sleep
    call app_tick
    call flush_frame
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

# wait-agents: async metadata discovery, without blocking the event loop (at most 30 s).
c_wait_agents:
    push r13
    call agents_request_now
    call time_ms
    lea r13, [rax + 30000]
1:  call agents_busy
    test eax, eax
    jz 2f
    call time_ms
    cmp rax, r13
    jae 2f
    mov edi, 20
    call loop_poll
    call app_tick
    call agents_request_now
    jmp 1b
2:  pop r13
    xor eax, eax
    ret

c_agents_more:
    call agents_more
    xor eax, eax
    ret

c_agents_page:
    lea rdi, [rip + out]
    call agents_page_dump
    xor eax, eax
    ret

# print-agents-runs: "runs=N", discovery runs started so far
c_agents_runs:
    lea rdi, [rip + out]
    call agents_runs_dump
    xor eax, eax
    ret

# wait-grep: until find in files has read the project's files
c_wait_grep:
    push r13
    call palette_read_all
    pop r13
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

# print-extensions: one line per extension: OWNER/NAME state=S [reason=R] pid=P cmds=a,b [status=T]
c_print_extensions:
    lea rdi, [rip + out]
    call ext_dump
    xor eax, eax
    ret

# apply-document DOC FILE: apply a workspace-edit fixture to one existing document,
# preserving the current tab, focus, Vim mode and scroll context.
c_apply_document:
    PROLOGUE
    call next_int
    mov r13, rax
    mov rdi, rbx
    mov rsi, r12
    call trim
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r14, rax
    mov rdi, rax
    call file_read_all
    mov r15, rax
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r13
    mov ecx, 1
    call ws_apply_document
    mov rdi, r15
    call mem_free
1:  mov rdi, r14
    call mem_free
    xor eax, eax
    EPILOGUE

# provider-set KIND LANGUAGE OWNER/NAME (or - to clear). The file format also permits
# language names containing spaces; the control interface uses one word per argument.
c_provider_set:
    PROLOGUE 16
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call ext_provider_kind
    test eax, eax
    jz 8f
    mov r13d, eax
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rsp], rax
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r14, rax
    mov rdx, rax
    cmp byte ptr [rax], '-'
    jne 1f
    cmp byte ptr [rax + 1], 0
    jne 1f
    xor edx, edx
1:  mov edi, r13d
    mov rsi, [rsp]
    mov ecx, 1
    call ext_provider_set
    mov r15, rax
    mov rdi, [rsp]
    call mem_free
    mov rdi, r14
    call mem_free
    mov rax, r15
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

c_print_ext_budget:
    push rbx
    lea rdi, [rip + out]
    call ext_budget_dump
    xor eax, eax
    pop rbx
    ret

c_print_providers:
    push rbx
    lea rdi, [rip + out]
    call ext_provider_dump
    xor eax, eax
    pop rbx
    ret

# wait-ext NAME STATE: until the extension (name or owner/name) is in that state (10 s at most);
# prints "ext=NAME state=S" at the end either way
c_wait_ext:
    PROLOGUE
    mov rdi, rbx
    mov rsi, r12
    call next_word
    mov r13, rax                # name
    mov r14, rdx
    add rbx, rcx
    sub r12, rcx
    mov rdi, rbx
    mov rsi, r12
    call next_word
    mov [rip + wait_ext_state], rax
    mov [rip + wait_ext_state_len], rdx
    mov rdi, r13
    mov rsi, r14
    call ext_by_name
    test rax, rax
    jz 8f
    mov r15, rax
    call time_ms
    lea r13, [rax + 10000]
1:  mov edi, [r15 + EXT_status]
    call ext_state_name
    mov rdi, [rip + wait_ext_state]
    mov rsi, [rip + wait_ext_state_len]
    mov rdx, rax
    call str_eq_cstr
    test eax, eax
    jnz 2f
    call time_ms
    cmp rax, r13
    jae 2f
    mov edi, 20
    call loop_poll
    call app_tick
    jmp 1b
2:  lea rdi, [rip + out]
    lea rsi, [rip + .Ls_ext]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, [r15 + EXT_name]
    call sb_push_cstr
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_state]
    call sb_push_cstr
    mov edi, [r15 + EXT_status]
    call ext_state_name
    lea rdi, [rip + out]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE
8:  lea rdi, [rip + out]
    lea rsi, [rip + .Ls_no_ext]
    call sb_push_cstr
    mov rax, -1
    EPILOGUE

# ext-set NAME unconfined|disabled 0|1, or ext-set NAME stop|restart: what the Settings buttons do
c_ext_set:
    PROLOGUE 16
    call next_arg               # rbx, r12 are the argument cursor: the extension goes to r15
    mov rdi, rax
    mov rsi, rdx
    call ext_by_name
    test rax, rax
    jz 9f
    mov r15, rax
    call next_arg
    mov r13, rax
    mov r14, rdx
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lx_stop]
    call str_eq_cstr
    test eax, eax
    jz 1f
    mov rdi, r15
    call ext_stop_user
    jmp 9f
1:  mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lx_restart]
    call str_eq_cstr
    test eax, eax
    jz 11f
    mov rdi, r15
    call ext_restart
    jmp 9f
11: mov rdi, r13                # forget: the projects it may run programs in (runallow.s)
    mov rsi, r14
    lea rdx, [rip + .Lx_forget]
    call str_eq_cstr
    test eax, eax
    jz 2f
    mov rdi, r15
    call run_forget
    jmp 9f
2:  call next_int
    mov [rsp], eax
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lx_pinned]
    call str_eq_cstr
    test eax, eax
    jz 3f
    mov rdi, r15
    mov esi, [rsp]
    call ext_set_pinned
    jmp 9f
3:  mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lx_disabled]
    call str_eq_cstr
    test eax, eax
    jz 9f
    mov rdi, r15
    mov esi, [rsp]
    call ext_set_disabled
9:  xor eax, eax
    EPILOGUE

# ext-install OWNER/NAME: as Install from GitHub with that answer
c_ext_install:
    PROLOGUE
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call ext_install_start
    xor eax, eax
    EPILOGUE

# wait-install: until the download is done (2 minutes at most), then "install=STATE"
c_wait_install:
    PROLOGUE
    call time_ms
    lea r13, [rax + 120000]
1:  cmp dword ptr [rip + g_ext_install_state], 1
    jne 2f
    call time_ms
    cmp rax, r13
    jae 2f
    mov edi, 50
    call loop_poll
    call app_tick
    call flush_frame
    jmp 1b
2:  mov eax, [rip + g_ext_install_state]
    lea rcx, [rip + .Lx_install_states]
    mov rsi, [rcx + rax*8]
    lea rdi, [rip + out]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE

# print-dialog: the confirm dialog's question, line and button, or dialog=none
c_print_dialog:
    PROLOGUE
    call flush_frame
    lea rdi, [rip + out]
    call app_dialog_dump
    xor eax, eax
    EPILOGUE

# dialog yes|no: its button, or Cancel
c_dialog:
    PROLOGUE
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lx_yes]
    call str_eq_cstr
    mov edi, eax
    call app_dialog_answer
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE

# ext-setting NAME KEY VALUE: an extension's own setting, as its page sets it (VALUE: the rest)
c_ext_setting:
    PROLOGUE
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call ext_by_name
    test rax, rax
    jz 9f
    mov r15, rax
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r15
    call sdef_find
    test rax, rax
    jz 9f
    mov r14, rax
    # the rest of the line, trimmed
    mov rdi, rbx
    mov rsi, r12
    call trim
    lea rdi, [rip + ctl_value]
    mov rsi, rax
    mov rcx, rdx
    cmp rcx, 1000
    jbe 1f
    mov ecx, 1000
1:  mov rdx, rcx
    push rdx
    push rdx
    call memcpy
    pop rdx
    pop rdx
    lea rax, [rip + ctl_value]
    mov byte ptr [rax + rdx], 0
    mov rdi, r15
    mov rsi, r14
    lea rdx, [rip + ctl_value]
    call ext_setting_set
9:  xor eax, eax
    EPILOGUE

# print-ext-page: the Extensions page's list, or the details shown
c_print_ext_page:
    PROLOGUE
    call flush_frame
    lea rdi, [rip + out]
    call extpage_dump
    xor eax, eax
    EPILOGUE

# print-extbar: the dropdown's state and the pinned extensions
# print-views: a line per extension view: "view=ID title=T shapes=N size=WxH at=X,Y"
c_print_views:
    PROLOGUE
    call flush_frame
    lea rdi, [rip + out]
    call extview_dump
    lea rdi, [rip + out]
    call rview_dump             # the retained views too (views group)
    xor eax, eax
    EPILOGUE


# print-complete: the completion list and the signature help (complete_dump)
c_print_complete:
    PROLOGUE
    call flush_frame
    lea rdi, [rip + out]
    call complete_dump
    xor eax, eax
    EPILOGUE

c_print_extbar:
    PROLOGUE
    call flush_frame
    lea rdi, [rip + out]
    call extbar_dump
    xor eax, eax
    EPILOGUE

# ext-page NAME|list: the Extensions page with that extension's details, or the list
c_ext_page:
    PROLOGUE
    call next_arg
    mov r13, rax
    mov r14, rdx
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lx_list]
    call str_eq_cstr
    xor edi, edi
    test eax, eax
    jnz 1f
    mov rdi, r13
    mov rsi, r14
    call ext_by_name
    mov rdi, rax
1:  call extpage_show
    xor eax, eax
    EPILOGUE

# ext-menu NAME: what a click on its title-bar button or its dropdown row does (a menu of its
# commands when it has several)
c_ext_menu:
    PROLOGUE
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call ext_by_name
    test rax, rax
    jz 9f
    mov rdi, rax
    mov esi, 500
    mov edx, 40
    call ext_action
9:  xor eax, eax
    EPILOGUE

# menu-pick LABEL: the open menu's item with that label runs, as a click on it would
c_menu_pick:
    PROLOGUE
    mov rdi, rbx
    mov rsi, r12
    call trim
    mov rdi, rax
    mov rsi, rdx
    call menu_pick
    xor eax, eax
    EPILOGUE

# ext-remove NAME: Remove (the dialog asks; dialog yes confirms)
c_ext_remove:
    PROLOGUE
    call next_arg
    mov rdi, rax
    mov rsi, rdx
    call ext_by_name
    test rax, rax
    jz 9f
    mov rdi, rax
    call ext_remove_ask
9:  xor eax, eax
    EPILOGUE

# print-options: "tab_width=N insert_spaces=B trim_trailing_whitespace=B final_newline=B", the
# settings in force for the active document (an extension's overrides included)
c_print_options:
    PROLOGUE
    mov rbx, [rip + g_doc]
    call ext_options_apply
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_opts]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_tab_width]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_opt_spaces]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_insert_spaces]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_opt_trim]
    call sb_push_cstr
    mov eax, [rip + cfg_trim_trailing]
    test rbx, rbx
    jz 1f
    mov rdi, rbx
    mov esi, OPT_TRIM
    call ext_opt_bool
1:  lea rdi, [rip + out]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_opt_final]
    call sb_push_cstr
    mov eax, [rip + cfg_final_newline]
    test rbx, rbx
    jz 2f
    mov rdi, rbx
    mov esi, OPT_FINAL
    call ext_opt_bool
2:  lea rdi, [rip + out]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

# print-marks: the active document's diagnostic marks, "L1 C1 L2 C2 SEVERITY owner/name MESSAGE"
# per line, in the order they are held; then "errors=N warnings=M"
c_print_marks:
    PROLOGUE
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 8f
    mov rdi, [rbx + DOC_xmarks]
    test rdi, rdi
    jz 8f
    xor r12d, r12d
1:  mov rdi, [rbx + DOC_xmarks]
    cmp r12, [rdi + VEC_len]
    jae 8f
    imul r13, r12, MK_SIZE
    add r13, [rdi + VEC_ptr]
    inc r12
    mov rdi, rbx
    mov rsi, [r13 + MK_start]
    call pm_pos
    mov rdi, rbx
    mov rsi, [r13 + MK_end]
    call pm_pos
    mov eax, [r13 + MK_sev]
    lea rcx, [rip + sev_words]
    mov rsi, [rcx + rax*8]
    lea rdi, [rip + out]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    test dword ptr [r13 + MK_pad], MKF_SOURCE
    jz 2f
    # a Problems store source's (problems.s): "problems:LABEL"
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_problems_src]
    call sb_push_cstr
    mov rax, [r13 + MK_owner]
    lea rdi, [rip + out]
    mov rsi, [rax + PS_label]
    call sb_push_cstr
    jmp 3f
2:  mov rax, [r13 + MK_owner]
    lea rdi, [rip + out]
    mov rsi, [rax + EXT_owner]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, '/'
    call sb_push_byte
    mov rax, [r13 + MK_owner]
    lea rdi, [rip + out]
    mov rsi, [rax + EXT_name]
    call sb_push_cstr
3:
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [r13 + MK_msg]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    jmp 1b
8:  mov rdi, rbx
    call extmarks_counts
    mov r12d, eax
    mov r13d, edx
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_errors]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, r12d
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_warnings]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE
# pm_pos(doc, pos): "LINE COL " into out
pm_pos:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call doc_line_of
    mov r13, rax
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    sub r12, rax
    lea rdi, [rip + out]
    lea rsi, [r13 + 1]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    lea rsi, [r12 + 1]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    EPILOGUE

# print-hover: "hover=DOC LINE COL sent=S text=T" for the position the pointer rests on, or
# "hover=none"
c_print_hover:
    PROLOGUE
    mov rbx, [rip + g_hover_doc]
    test rbx, rbx
    jz 8f
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_hover]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, [rbx + DOC_id]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [rip + g_hover_pos]
    call pm_pos
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_sent]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + g_hover_sent]
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_text]
    call sb_push_cstr
    lea rdi, [rip + out]
    lea rsi, [rip + g_hover_text]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE
8:  lea rdi, [rip + out]
    lea rsi, [rip + .Ls_hover_none]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE

# print-text-cell LINE COL: "X Y", the middle of that cell of the active document on screen
# (without word wrap)
c_print_text_cell:
    PROLOGUE
    call next_int               # (next_int reads the arguments through rbx and r12)
    mov r14, rax                # line
    call next_int
    mov r15, rax                # col
    mov dword ptr [rip + g_dirty], 1
    call flush_frame            # the layout of a frame: g_ed_y, g_ed_tx, the metrics
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 8f
    # y: rows from the first visible line
    mov rax, [rbx + DOC_scrolly]
    sar rax, 8
    lea rcx, [r14 - 1]
    sub rcx, rax
    imul ecx, [rip + g_lh]
    add ecx, [rip + g_ed_y]
    mov eax, [rip + g_lh]
    shr eax, 1
    add ecx, eax
    mov r14d, ecx
    # x: columns from the left edge
    lea rax, [r15 - 1]
    imul eax, [rip + g_cw]
    add eax, [rip + g_ed_tx]
    sub rax, [rbx + DOC_scrollx]
    mov ecx, [rip + g_cw]
    shr ecx, 1
    add eax, ecx
    lea rdi, [rip + out]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, r14d
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
8:  xor eax, eax
    EPILOGUE

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

# print-update: the updater's state, the running and the latest version, the last error, and the
# Check now row's text in Settings on a second line (desc=)
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

# print-tabs: "tabs=^a | *b | c", the tab strip in order with pinned tabs marked ^ and the active tab
#   starred
c_print_tabs:
    PROLOGUE
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_tabs]
    call sb_push_cstr
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 4f
    test rbx, rbx
    jz 2f
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_bar]
    call sb_push_cstr
2:  mov rdi, rbx
    call tab_pinned
    test eax, eax
    jz 21f
    lea rdi, [rip + out]
    mov esi, '^'
    call sb_push_byte
21: cmp rbx, [rip + g_tab_cur]
    jne 3f
    lea rdi, [rip + out]
    mov esi, '*'
    call sb_push_byte
3:  mov rdi, rbx
    call app_tab_label
    lea rdi, [rip + out]
    mov rsi, rax
    call sb_push_cstr
    inc rbx
    jmp 1b
4:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

# print-panels: whether this window shows the explorer, the agents panel and the terminal
c_print_panels:
    push rbx
    lea rbx, [rip + panel_rows]
1:  mov rsi, [rbx]
    test rsi, rsi
    jz 2f
    lea rdi, [rip + out]
    call sb_push_cstr
    mov rax, [rbx + 8]
    lea rdi, [rip + out]
    mov esi, [rax]
    call sb_push_u64
    add rbx, 16
    jmp 1b
2:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    pop rbx
    xor eax, eax
    ret

# focus out|in: the window loses or gets the keyboard, as a platform reports it
c_focus:
    call next_arg
    xor edi, edi
    test rdx, rdx
    jz 1f
    cmp byte ptr [rax], 'i'
    jne 1f
    mov edi, 1
1:  call app_on_focus
    xor eax, eax
    ret

# appearance dark|light|unknown: the system's dark mode changes, as a platform reports it
c_appearance:
    call next_arg
    mov edi, -1
    test rdx, rdx
    jz 1f
    cmp byte ptr [rax], 'u'
    je 1f
    xor edi, edi
    cmp byte ptr [rax], 'l'
    je 1f
    mov edi, 1
1:  call theme_system_changed
    xor eax, eax
    ret

# print-appearance: the system's mode, follow_system, the three theme settings and the theme shown
c_print_appearance:
    push rbx
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_system]
    call sb_push_cstr
    lea rsi, [rip + .Ls_unknown]
    lea rax, [rip + .Ls_dark]
    lea rcx, [rip + .Ls_light]
    mov edx, [rip + g_sys_dark]
    cmp edx, 1
    cmove rsi, rax
    test edx, edx
    cmovz rsi, rcx
    lea rdi, [rip + out]
    call sb_push_cstr
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_follow]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, [rip + cfg_follow_system]
    call sb_push_u64
    lea rbx, [rip + appearance_rows]
1:  mov rsi, [rbx]
    test rsi, rsi
    jz 2f
    lea rdi, [rip + out]
    call sb_push_cstr
    mov rax, [rbx + 8]
    lea rdi, [rip + out]
    mov rsi, [rax]
    call sb_push_cstr
    add rbx, 16
    jmp 1b
2:  lea rdi, [rip + out]
    lea rsi, [rip + .Ls_shown]
    call sb_push_cstr
    call theme_current_id
    lea rdi, [rip + out]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    pop rbx
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

# print-tip: the text of the tooltip on screen, "tip=" when there is none
c_print_tip:
    lea rdi, [rip + out]
    call tip_print
    xor eax, eax
    ret

# print-toast: the message on screen, "toast=" when there is none
c_print_toast:
    lea rdi, [rip + out]
    lea rsi, [rip + .Ls_toast]
    call sb_push_cstr
    call time_ms
    cmp rax, [rip + g_toast_until]
    jae 1f
    lea rdi, [rip + out]
    lea rsi, [rip + g_toast]
    call sb_push_cstr
1:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    ret

# print-term: the screen of the current terminal
c_print_term:
    lea rdi, [rip + out]
    call term_dump_current
    xor eax, eax
    ret

# print-link: the terminal's link under the pointer, "link=" when there is none
c_print_link:
    lea rdi, [rip + out]
    call term_link_dump
    xor eax, eax
    ret

# print-term-cell ROW COL: "X Y", the middle of that cell of the terminal
c_print_term_cell:
    call next_int
    push rax
    call next_int
    pop rdi
    mov esi, eax
    lea rdx, [rip + out]
    call term_cell_dump
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
    mov rdi, rbx
    lea rsi, [rip + out]
    call sel_state              # " sels=N" with several selections (multi-cursor)
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
    mov rdi, rbx
    call doc_language
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
    call c_wait_agents
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
    mov [rip + g_control_path], rdi
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
.Ls_ext: .asciz "ext="
.Ls_errors: .asciz "errors="
.Ls_problems_src: .asciz "problems:"
.Ls_warnings: .asciz " warnings="
.Ls_hover: .asciz "hover="
.Ls_sent: .asciz "sent="
.Ls_text: .asciz " text="
.Ls_hover_none: .asciz "hover=none\n"
.Lsw_error: .asciz "error"
.Lsw_warning: .asciz "warning"
.Lsw_info: .asciz "info"
.Lsw_hint: .asciz "hint"
.p2align 3
sev_words: .quad .Lsw_error, .Lsw_warning, .Lsw_info, .Lsw_hint
.Ls_state: .asciz " state="
.Ls_no_ext: .asciz "no such extension\n"
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
.Lc_key_up: .asciz "key-up"
.Lc_key: .asciz "key"
.Lc_modifiers: .asciz "modifiers"
.Lc_type: .asciz "type"
.Lc_move: .asciz "move"
.Lc_click: .asciz "click"
.Lc_tap: .asciz "tap"
.Lc_down: .asciz "down"
.Lc_updown: .asciz "up-down"
.Lc_up: .asciz "up"
.Lc_scroll: .asciz "scroll"
.Lc_open: .asciz "open"
.Lc_cmd: .asciz "cmd"
.Lc_shot: .asciz "shot"
.Lc_wait: .asciz "wait"
.Lc_resize: .asciz "resize"
.Lc_quit: .asciz "quit"
.Lc_echo: .asciz "echo"
.Lc_print_doc: .asciz "print-doc"
.Lc_print_state: .asciz "print-state"
.Lc_print_syntax: .asciz "print-syntax"
.Lc_print_agents: .asciz "print-agents"
.Lc_xkey: .asciz "xkey"
.Lc_print_window: .asciz "print-window"
.Lc_print_cursor: .asciz "print-cursor"
.Lc_print_shape: .asciz "print-shape"
.Lc_print_term: .asciz "print-term"
.Lc_print_git: .asciz "print-git"
.Lc_wait_git: .asciz "wait-git"
.Lc_wait_agents: .asciz "wait-agents"
.Lc_agents_more: .asciz "agents-more"
.Lc_agents_page: .asciz "print-agents-page"
.Lc_agents_runs: .asciz "print-agents-runs"
.Lc_wait_grep: .asciz "wait-grep"
.Lc_wait_term: .asciz "wait-term"
.Lc_print_gitlog: .asciz "print-gitlog"
.Lc_print_scm: .asciz "print-scm"
.Lc_wait_ai: .asciz "wait-ai"
.Lc_print_ai: .asciz "print-ai"
.Lc_wait_update: .asciz "wait-update"
.Lc_print_update: .asciz "print-update"
.Lc_print_frames: .asciz "print-frames"
.Lc_apply_document: .asciz "apply-document"
.Lc_provider_set: .asciz "provider-set"
.Lc_print_providers: .asciz "print-providers"
.Lc_print_ext_budget: .asciz "print-ext-budget"
.Lc_print_extensions: .asciz "print-extensions"
.Lc_wait_ext: .asciz "wait-ext"
.Lc_print_marks: .asciz "print-marks"
.Lc_print_hover: .asciz "print-hover"
.Lc_print_text_cell: .asciz "print-text-cell"
.Lc_print_options: .asciz "print-options"
.Lc_ext_set: .asciz "ext-set"
.Lc_ext_install: .asciz "ext-install"
.Lc_wait_install: .asciz "wait-install"
.Lc_print_dialog: .asciz "print-dialog"
.Lc_dialog: .asciz "dialog"
.Lc_ext_setting: .asciz "ext-setting"
.Lc_print_ext_page: .asciz "print-ext-page"
.Lc_print_extbar: .asciz "print-extbar"
.Lc_ext_page: .asciz "ext-page"
.Lc_ext_menu: .asciz "ext-menu"
.Lc_print_views: .asciz "print-views"
.Lc_print_complete: .asciz "print-complete"
.Lc_menu_pick: .asciz "menu-pick"
.Lc_ext_remove: .asciz "ext-remove"

.Lx_yes: .asciz "yes"
.Lx_list: .asciz "list"
.Lx_install_states: .quad .Lxi_idle, .Lxi_busy, .Lxi_asking, .Lxi_done, .Lxi_failed
.Lxi_idle: .asciz "install=idle\n"
.Lxi_busy: .asciz "install=downloading\n"
.Lxi_asking: .asciz "install=asking\n"
.Lxi_done: .asciz "install=done\n"
.Lxi_failed: .asciz "install=failed\n"
.Lx_pinned: .asciz "pinned"
.Lx_disabled: .asciz "disabled"
.Lx_stop: .asciz "stop"
.Lx_restart: .asciz "restart"
.Lx_forget: .asciz "forget"
.Ls_opts: .asciz "tab_width="
.Ls_opt_spaces: .asciz " insert_spaces="
.Ls_opt_trim: .asciz " trim_trailing_whitespace="
.Ls_opt_final: .asciz " final_newline="
.Lc_print_project: .asciz "print-project"
.Lc_print_panels: .asciz "print-panels"
.Lc_print_tabs: .asciz "print-tabs"
.Lc_print_palette: .asciz "print-palette"
.Lc_print_menu: .asciz "print-menu"
.Lc_print_tip: .asciz "print-tip"
.Lc_print_toast: .asciz "print-toast"
.Lc_print_link: .asciz "print-link"
.Lc_print_scroll: .asciz "print-scroll"
.Lc_print_settings: .asciz "print-settings"
.Lc_scroll_x: .asciz "scroll-x"
.Lc_appearance: .asciz "appearance"
.Lc_focus: .asciz "focus"
.Lc_print_appearance: .asciz "print-appearance"
.Lc_print_term_cell: .asciz "print-term-cell"
.Ls_project: .asciz "project="
.Ls_bar: .asciz " | "
.Ls_explorer_eq: .asciz "explorer="
.Ls_agents_eq: .asciz " agents="
.Ls_toast: .asciz "toast="
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
.Ls_system: .asciz "system="
.Ls_unknown: .asciz "unknown"
.Ls_dark: .asciz "dark"
.Ls_light: .asciz "light"
.Ls_follow: .asciz " follow="
.Ls_theme_eq: .asciz " theme="
.Ls_dark_eq: .asciz " dark="
.Ls_light_eq: .asciz " light="
.Ls_shown: .asciz " shown="
.Ldigits: .ascii "0123456789abcdefghijk"
.p2align 3
# other parts' control commands: tables of (name, fn(out, rest, rest len)) pairs, 0-ended
ctl_tables:
    .quad contrib_ctl           # contributions and commands (contribctl.s)
    .quad scm_ctl               # source control (scmctl.s)
    .quad langfeat_ctl          # language features (lfcontrol.s)
    .quad debug_ctl             # debugger (debugctl.s)
    .quad tasks_ctl             # tasks and terminals (runctl.s)
    .quad test_ctl              # testing (testview.s)
    .quad ai_ctl                # AI: agent sessions, the Review tab, tools (aictl.s)
    .quad md_ctl                # Markdown rendering (views group: mdctl.s)
    .quad views_ctl             # views group: places and retained views (viewsctl.s)
    .quad nb_ctl                # notebooks (nbctl.s)
    .quad ce_ctl                # custom editors (customed.s)
    .quad wasm_ctl              # WebAssembly extensions (extwasm.s)
    .quad remote_ctl            # remote hosts (remotectl.s)
    .quad pres_ctl              # editor presentation (presctl.s)
    .quad extmgr_ctl            # extension management (extmgrctl.s)
    .quad ws_ctl                # workspace edits and the editor model (wsctl.s)
    .quad res_commands          # resources, workspaces, secrets and lifecycle (extres.s)
    .quad newext_ctl            # New Extension (newext.s)
    .quad submitext_ctl         # Submit to Index (submitext.s)
    .quad 0
ctl_table:
    .quad .Lc_key_up, c_key_up, .Lc_key, c_key, .Lc_modifiers, c_modifiers, .Lc_type, c_type, .Lc_move, c_move, .Lc_click, c_click, .Lc_tap, c_tap
    .quad .Lc_down, c_down, .Lc_up, c_up, .Lc_updown, c_updown, .Lc_scroll, c_scroll, .Lc_open, c_open
    .quad .Lc_cmd, c_cmd, .Lc_shot, c_shot, .Lc_wait, c_wait, .Lc_resize, c_resize
    .quad .Lc_quit, c_quit, .Lc_echo, c_echo, .Lc_print_doc, c_print_doc
    .quad .Lc_print_state, c_print_state, .Lc_print_syntax, c_print_syntax, .Lc_print_agents, c_print_agents, .Lc_xkey, c_xkey
    .quad .Lc_print_shape, c_print_shape
    .quad .Lc_print_window, c_print_window, .Lc_print_cursor, c_print_cursor, .Lc_print_term, c_print_term
    .quad .Lc_print_git, c_print_git, .Lc_wait_git, c_wait_git, .Lc_print_gitlog, c_print_gitlog
    .quad .Lc_wait_grep, c_wait_grep
    .quad .Lc_wait_agents, c_wait_agents, .Lc_agents_more, c_agents_more, .Lc_agents_page, c_agents_page
    .quad .Lc_agents_runs, c_agents_runs
    .quad .Lc_wait_term, c_wait_term
    .quad .Lc_print_scm, c_print_scm
    .quad .Lc_wait_ai, c_wait_ai, .Lc_print_ai, c_print_ai
    .quad .Lc_wait_update, c_wait_update, .Lc_print_update, c_print_update
    .quad .Lc_print_frames, c_print_frames, .Lc_print_project, c_print_project
    .quad .Lc_print_panels, c_print_panels, .Lc_print_tabs, c_print_tabs
    .quad .Lc_print_palette, c_print_palette, .Lc_print_menu, c_print_menu
    .quad .Lc_print_tip, c_print_tip, .Lc_print_toast, c_print_toast, .Lc_print_link, c_print_link
    .quad .Lc_print_term_cell, c_print_term_cell, .Lc_print_scroll, c_print_scroll
    .quad .Lc_print_settings, c_print_settings
    .quad .Lc_scroll_x, c_scroll_x
    .quad .Lc_appearance, c_appearance, .Lc_print_appearance, c_print_appearance
    .quad .Lc_print_ext_budget, c_print_ext_budget
    .quad .Lc_apply_document, c_apply_document
    .quad .Lc_provider_set, c_provider_set, .Lc_print_providers, c_print_providers
    .quad .Lc_print_extensions, c_print_extensions, .Lc_wait_ext, c_wait_ext
    .quad .Lc_print_marks, c_print_marks, .Lc_print_hover, c_print_hover, .Lc_print_text_cell, c_print_text_cell
    .quad .Lc_print_options, c_print_options, .Lc_ext_set, c_ext_set
    .quad .Lc_ext_install, c_ext_install, .Lc_wait_install, c_wait_install
    .quad .Lc_print_dialog, c_print_dialog, .Lc_dialog, c_dialog
    .quad .Lc_ext_setting, c_ext_setting, .Lc_print_ext_page, c_print_ext_page
    .quad .Lc_print_extbar, c_print_extbar, .Lc_ext_page, c_ext_page, .Lc_ext_remove, c_ext_remove
    .quad .Lc_ext_menu, c_ext_menu, .Lc_menu_pick, c_menu_pick, .Lc_print_views, c_print_views
    .quad .Lc_focus, c_focus, .Lc_print_complete, c_print_complete
    .quad 0, 0
appearance_rows:
    .quad .Ls_theme_eq, cfg_theme, .Ls_dark_eq, cfg_dark_theme, .Ls_light_eq, cfg_light_theme, 0
panel_rows:
    .quad .Ls_explorer_eq, g_show_side, .Ls_agents_eq, g_show_agents, .Ls_term, g_term_open, 0

.data
lsock: .long -1
.p2align 3
.globl g_control_path
g_control_path: .quad 0         # --control PATH while listening
csock: .long -1
oc_next: .long -1               # a client that came while oc_busy
.bss
.p2align 3
pc_xc: .zero XC_SIZE
click_mods: .long 0             # c_click: the modifiers its press and release carry
pp_buf: .zero 4096

CSTR .Lwindows_control, "rhun: --control is unavailable on Windows; use --script FILE"
