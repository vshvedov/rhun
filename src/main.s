# entry: arguments, platform selection, main loop
#   rhun [PATH...] [--wait] [--headless WxH] [--scale F] [--script FILE] [--control SOCKET]
.include "rhun.inc"

.equ TCGETS, 0x5401

.bss
.p2align 3
sigact: .zero 32
opt_headless: .long 0
opt_empty: .long 0
opt_paths: .long 0              # past a -- argument: the rest are paths
.p2align 3
opt_script: .quad 0
opt_control: .quad 0
cwd: .zero 4096
self_path: .zero 4096

.data
opt_w: .long 1280
opt_h: .long 800
.text
FN main
    PROLOGUE 16
    # ignore SIGPIPE
    mov qword ptr [rip + sigact], 1
    mov edi, 13
    lea rsi, [rip + sigact]
    xor edx, edx
    mov r10d, 8
    SYS SYS_rt_sigaction
    cmp qword ptr [rip + g_argc], 5
    jb 1f
    cmp qword ptr [rip + g_argc], 6
    ja 1f
    mov rax, [rip + g_argv]
    mov rdi, [rax + 8]
    lea rsi, [rip + .Lagent_worker]
    call strcmp_eq
    test eax, eax
    jz 1f
    call agent_index_main
    EPILOGUE
1:
    call parse_args
    call detach
    call raster_init
    call appearance_init
    call app_init
    cmp dword ptr [rip + opt_headless], 0
    jne .Lm_headless
.ifdef WINDOWS
    lea rdi, [rip + .Ltitle]
    call win_open_window
    jmp .Lm_open
.else
.ifdef MACOS
    lea rdi, [rip + .Ltitle]
    call mac_open_window
    jmp .Lm_open
.else
.ifdef VINIX
    call scale_from_env
    lea rdi, [rip + .Ltitle]
    call vinix_open_window
    jmp .Lm_open
.else
    # RHUN_BACKEND=x11 skips Wayland
    lea rdi, [rip + .Lenv_backend]
    call getenv
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 'x'
    je 2f
1:  call wl_connect
    test eax, eax
    jz 2f
    # no XSETTINGS on Wayland: the system's mode from the other sources is final
    mov edi, -1
    call linux_xsettings
    lea rdi, [rip + .Ltitle]
    call wl_open_window
    jmp .Lm_open
2:  call x_connect
    test eax, eax
    jnz 3f
    lea rdi, [rip + .Lno_display]
    call die
3:  call scale_from_env
    lea rdi, [rip + .Ltitle]
    call x_open_window
    jmp .Lm_open
.endif
.endif
.endif
.Lm_headless:
    call scale_from_env
    mov edi, [rip + opt_w]
    mov esi, [rip + opt_h]
    call headless_init
.Lm_open:
    call open_initial
    mov rdi, [rip + opt_control]
    test rdi, rdi
    jz 2f
    call control_listen
2:  mov rdi, [rip + opt_script]
    test rdi, rdi
    jz 3f
    call control_run_script
    jmp .Lm_exit
3:  call loop_run
.Lm_exit:
    call agents_shutdown
    call ai_shutdown
    call session_remember_project
    call session_save
    cmp dword ptr [rip + g_settings_changed], 0
    je 4f
    call config_save
4:  cmp dword ptr [rip + g_restart], 0
    je 5f
    call update_restart
    jmp 6f
5:  call update_discard
6:  xor eax, eax
    EPILOGUE

.section .rodata
.Lagent_worker: .asciz "--agent-index"
.text
parse_args:
    PROLOGUE
    mov r12, [rip + g_argv]
    mov r13, [rip + g_argc]
    mov ebx, 1
.Lpa_next:
    cmp rbx, r13
    jae .Lpa_done
    mov r14, [r12 + rbx*8]
    # after --, paths only (the Windows rhun:// command passes the link after it, so that a quote in
    # the link cannot start an option)
    cmp dword ptr [rip + opt_paths], 0
    jne 41f
    mov rdi, r14
    lea rsi, [rip + .Lo_dashdash]
    call strcmp_eq
    test eax, eax
    jz 0f
    mov dword ptr [rip + opt_paths], 1
    jmp 9f
0:  mov rdi, r14
    call help_flag
    mov rdi, r14
    lea rsi, [rip + .Lo_headless]
    call strcmp_eq
    test eax, eax
    jz 1f
    mov dword ptr [rip + opt_headless], 1
    inc rbx
    cmp rbx, r13
    jae .Lpa_done
    mov rdi, [r12 + rbx*8]
    call parse_size
    jmp 9f
1:  mov rdi, r14
    lea rsi, [rip + .Lo_script]
    call strcmp_eq
    test eax, eax
    jz 2f
    inc rbx
    mov rax, [r12 + rbx*8]
    mov [rip + opt_script], rax
    jmp 9f
2:  mov rdi, r14
    lea rsi, [rip + .Lo_control]
    call strcmp_eq
    test eax, eax
    jz 3f
    inc rbx
    mov rax, [r12 + rbx*8]
    mov [rip + opt_control], rax
    jmp 9f
3:  mov rdi, r14
    lea rsi, [rip + .Lo_wait]
    call strcmp_eq
    test eax, eax
    jz 31f
    mov dword ptr [rip + g_wait], 1
    jmp 9f
31: mov rdi, r14
    lea rsi, [rip + .Lo_scale]
    call strcmp_eq
    test eax, eax
    jz 4f
    inc rbx
    mov rdi, [r12 + rbx*8]
    call set_scale
    jmp 9f
4:  mov rdi, r14
    lea rsi, [rip + .Lo_empty]
    call strcmp_eq
    test eax, eax
    jz 41f
    mov dword ptr [rip + opt_empty], 1
    jmp 9f
41: lea rdi, [rip + g_start_paths]
    mov esi, 8
    call vec_push
    mov [rax], r14
9:  inc rbx
    jmp .Lpa_next
.Lpa_done:
    EPILOGUE

# appearance_init(): the system's dark mode before the first theme is chosen: from the platform,
# which reports its changes later, or headless from RHUN_APPEARANCE (dark or light), for tests
appearance_init:
    PROLOGUE
    cmp dword ptr [rip + opt_headless], 0
    je 1f
    lea rdi, [rip + .Lenv_appearance]
    call getenv
    test rax, rax
    jz 9f
    mov ecx, 1
    cmp byte ptr [rax], 'd'
    je 2f
    mov ecx, 0
    cmp byte ptr [rax], 'l'
    je 2f
    mov ecx, -1
2:  mov [rip + g_sys_dark], ecx
    jmp 9f
1:
.ifdef WINDOWS
    call win_appearance_init
.else
.ifdef MACOS
    call mac_appearance_init
.else
    call linux_appearance_init
.endif
.endif
9:  EPILOGUE

# detach(): started from a terminal, rhun goes on as a fresh copy in a session of its own that reads
# and writes /dev/null, and this one exits: the shell gets its prompt back, and closing the terminal
# does not close rhun. Not with --wait (EDITOR="rhun --wait" for git), not for scripting, and on
# Linux not without a display, so that the error is seen. A copy rather than a fork, because on
# macOS a forked process cannot use CoreFoundation, which the loader has already started. The
# copy's input and output are no terminal, so it stays.
detach:
    PROLOGUE 64
    mov eax, [rip + opt_headless]
    or eax, [rip + g_wait]
    jnz 9f
    cmp qword ptr [rip + opt_script], 0
    jne 9f
    cmp qword ptr [rip + opt_control], 0
    jne 9f
    .ifdef WINDOWS
    call win_detach
    jmp 9f
    .endif
    # a terminal on stdin, stdout or stderr
    xor ebx, ebx
1:  mov edi, ebx
    mov esi, TCGETS
    lea rdx, [rsp]
    SYS SYS_ioctl
    test rax, rax
    jz 2f
    inc ebx
    cmp ebx, 3
    jb 1b
    jmp 9f
2:
.ifdef MACOS
    lea rdi, [rip + self_path]
    mov esi, 4096
    call mac_exe_path
    test rax, rax
    js 9f
.else
    lea rdi, [rip + .Lenv_wayland]
    call getenv
    test rax, rax
    jnz 3f
    lea rdi, [rip + .Lenv_display]
    call getenv
    test rax, rax
    jz 9f
3:  lea rdi, [rip + .Lself_exe]
    lea rsi, [rip + self_path]
    mov edx, 4095
    SYS SYS_readlink
    test rax, rax
    jle 9f
    lea rcx, [rip + self_path]
    mov byte ptr [rcx + rax], 0
.endif
    lea rdi, [rip + .Ldevnull]
    mov esi, O_RDWR | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 9f
    mov ebx, eax
    # a pipe whose write end the copy closes once it is in its new session (proc_spawn closes all
    # but 0-2 after setsid): this one exits only then. On macOS vfork is a fork, and a copy still in
    # the terminal's process group would go with it when the terminal signals the group.
    lea rdi, [rsp]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js 8f
    # the same arguments, run from the path of this program
    mov rax, [rip + g_argv]
    lea rcx, [rip + self_path]
    mov [rax], rcx
    mov rdi, rax
    mov rsi, [rip + g_envp]
    xor edx, edx
    mov ecx, ebx
    mov r8d, ebx
    mov r9d, ebx
    push 1                      # a new session; the terminal ioctl on /dev/null fails, so none
    push 1
    call proc_spawn
    add rsp, 16
    mov r12, rax
    mov edi, [rsp + 4]
    SYS SYS_close
    test r12, r12
    jle 7f                      # it did not start: stay
6:  mov edi, [rsp]
    lea rsi, [rsp + 8]
    mov edx, 1
    SYS SYS_read
    cmp rax, -EINTR
    je 6b
    xor edi, edi
    call sys_exit
7:  mov edi, [rsp]
    SYS SYS_close
8:  mov edi, ebx
    SYS SYS_close
9:  EPILOGUE

# help_flag(arg): -h/--help prints usage, --version the version; both exit
help_flag:
    push rbx
    mov rbx, rdi
    lea rsi, [rip + .Lo_version]
    call strcmp_eq
    test eax, eax
    jz 1f
    lea rdi, [rip + .Lversion]
    call out_cstr
    lea rdi, [rip + rhun_version]
    call out_cstr
    lea rdi, [rip + .Lnl]
    jmp 3f
1:  mov rdi, rbx
    lea rsi, [rip + .Lo_help]
    call strcmp_eq
    test eax, eax
    jnz 2f
    mov rdi, rbx
    lea rsi, [rip + .Lo_h]
    call strcmp_eq
    test eax, eax
    jz 9f
2:  lea rdi, [rip + .Lusage]
3:  call out_cstr
    xor edi, edi
    call sys_exit
9:  pop rbx
    ret

# out_cstr(s): to stdout
out_cstr:
    push rdi
    call strlen
    pop rsi
    mov rdx, rax
    mov edi, 1
    jmp write_all

# RHUN_SCALE=1.5 sets the display scale where the platform doesn't report one
scale_from_env:
    lea rdi, [rip + .Lenv_scale]
    call getenv
    test rax, rax
    jz 1f
    mov rdi, rax
    jmp set_scale
1:  ret

# set_scale(cstr): "2", "1.5" or "150" (percent); ignored outside 0.5 .. 4
set_scale:
    push rbx
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call parse_decimal
    test edx, edx
    jz 1f
    cmp eax, 10
    ja 2f
    imul eax, eax, 100              # a whole number is a factor
2:  cmp eax, 50
    jb 1f
    cmp eax, 400
    ja 1f
    cvtsi2ss xmm0, eax
    divss xmm0, [rip + .Lf100]
    movss [rip + g_dpi_scale], xmm0
1:  pop rbx
    ret

# "WxH"
parse_size:
    push rbx
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call parse_u64
    mov [rip + opt_w], eax
    lea rdi, [rbx + rdx + 1]
    push rdi
    call strlen
    pop rdi
    mov rsi, rax
    call parse_u64
    mov [rip + opt_h], eax
    pop rbx
    ret

# open_initial(): project folder and files from the command line

open_initial:
    PROLOGUE
    xor r12d, r12d              # got a directory
    xor ebx, ebx
1:  cmp rbx, [rip + g_start_paths + VEC_len]
    jae 2f
    mov rax, [rip + g_start_paths + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call app_path_is_dir        # a rhun:// link to a folder too
    test eax, eax
    jz 11f
    mov r12d, 1
11: inc rbx
    jmp 1b
2:  test r12d, r12d
    jnz 3f
    # With no paths, optionally reopen the last project; explicit paths always win.
    cmp qword ptr [rip + g_start_paths + VEC_len], 0
    je 20f
    # explicit files are ordinary tabs without a project, and a quick edit: no explorer or agents
    call app_hide_panels
    jmp 3f
20: cmp dword ptr [rip + opt_empty], 0
    jne 3f
    cmp dword ptr [rip + cfg_restore_project], 0
    je 21f
    call session_last_project
    test rax, rax
    jz 21f
    mov rdi, rax
    call app_set_project
    jmp 3f
21: # bare launch: the current directory is the project
    lea rdi, [rip + cwd]
    mov esi, 4096
    SYS SYS_getcwd
    test rax, rax
    js 3f
    lea rdi, [rip + cwd]
    call app_set_project
3:  xor ebx, ebx
4:  cmp rbx, [rip + g_start_paths + VEC_len]
    jae 5f
    mov rax, [rip + g_start_paths + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call app_open_path
    inc rbx
    jmp 4b
5:  # nothing opened: bring back the last session
    cmp dword ptr [rip + opt_empty], 0
    jne 6f
    test r12d, r12d
    jnz 51f
    cmp qword ptr [rip + g_start_paths + VEC_len], 0
    jne 6f                    # file-only launches never restore a project session
51:
    cmp qword ptr [rip + g_tabs + VEC_len], 0
    jne 6f
    call session_restore
6:  mov dword ptr [rip + g_started], 1
    call app_update_title
.ifdef WINDOWS
    cmp dword ptr [rip + opt_headless], 0
    jne 7f
    cmp qword ptr [rip + g_start_paths + VEC_len], 0
    je 7f
    call win_activate
7:
.endif
    EPILOGUE

.section .rodata
.Ltitle: .asciz "rhun"
.Lno_display: .asciz "rhun: no Wayland or X11 display found"
.Lenv_backend: .asciz "RHUN_BACKEND"
.Lenv_scale: .asciz "RHUN_SCALE"
.Lo_headless: .asciz "--headless"
.Lo_script: .asciz "--script"
.Lo_control: .asciz "--control"
.Lo_scale: .asciz "--scale"
.Lo_wait: .asciz "--wait"
.Lo_empty: .asciz "--empty"
.Lo_dashdash: .asciz "--"
.Ldevnull: .asciz "/dev/null"
.Lself_exe: .asciz "/proc/self/exe"
.Lenv_wayland: .asciz "WAYLAND_DISPLAY"
.Lenv_appearance: .asciz "RHUN_APPEARANCE"
.Lenv_display: .asciz "DISPLAY"
.Lo_help: .asciz "--help"
.Lo_h: .asciz "-h"
.Lo_version: .asciz "--version"
.Lversion: .asciz "rhun "
.Lnl: .asciz "\n"
.Lusage: .ascii "usage: rhun [folder] [files...]\n"
    .ascii "  --wait           stay in the terminal until rhun is closed (for EDITOR)\n"
    .ascii "  --empty          start without restoring a project or tabs\n"
    .ascii "  --headless WxH   no display; use with --script or --control\n"
    .ascii "  --script FILE    run control commands from FILE and exit\n"
    .ascii "  --control PATH   accept control commands on a unix socket\n"
    .ascii "  --scale F        display scale where the platform has none\n"
    .ascii "  --               the arguments after it are paths (rhun://file/ links too)\n"
    .asciz "  --version        print the version\n"
.p2align 2
.Lf100: .float 100.0
