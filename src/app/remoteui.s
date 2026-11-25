# remote windows, the window's side: what happens once connected, the bar while connecting or after
# the connection was lost, the status bar item and its menu, Connect to Host and Attach to Container,
# recent remotes, and ssh's questions (passwords, host keys), which `rhun` run as ssh's askpass
# program passes to this window through a private socket.
.include "rhun.inc"

.equ ID_RM_STATUS, 0x2e40       # the status bar item
.equ ID_RM_BAR, 0x2e41          # the bar's Reconnect / Retry button
.equ RP_HOST, 1                 # what the remote pick list picks
.equ RP_CONTAINER, 2
.equ RP_YESNO, 3                # ssh asks yes or no (a host key)
.equ RU_RECENT_MAX, 8
.equ RU_ASK_MAX, 8192

.bss
.p2align 3
ru_opened: .long 0              # the project was opened (a reconnect keeps it)
ru_pick: .long 0                # RP_* of the open pick list
ru_fw_prompt: .long 0           # 1 while the prompt asks for a port to forward (remotefwd.s)
ru_fw_msg: .zero 300
ru_ps_pid: .long 0              # docker ps / podman ps for Attach to Container
.globl g_remote_shell
g_remote_shell: .zero 256       # the user's shell on the host (its name names terminal tabs)
.globl g_remote_claude_dir
g_remote_claude_dir: .zero 4096 # CLAUDE_CONFIG_DIR of the host's login environment, or empty
ru_sb: .zero SB_SIZE            # scratch: the bar's text
ru_names: .zero SB_SIZE         # the pick list's names, NUL-terminated one after another
ru_offs: .zero VEC_SIZE         # their offsets (8 bytes each)
ru_ps_out: .zero SB_SIZE
ru_ps_kind: .zero 16            # "docker:" or "podman:"
ru_spec: .zero 512
ru_label: .zero 512             # the project's name in a remote window: "HOST: name"
ru_mask: .zero TF_SIZE          # a password's field as drawn: one * for each character
ru_menu: .zero 16 * 10
ru_recent: .zero SB_SIZE        # the recent remotes file
ru_exe: .zero 4200
ru_ap_dir: .zero 128            # askpass: the private folder and its socket
ru_ap_path: .zero 128
ru_ap_in: .zero SB_SIZE         # the question
ru_ap_out: .zero SB_SIZE        # the answer, as it goes to the askpass program
ru_ap_label: .zero 512
ru_ap_env_prog: .zero 4300      # SSH_ASKPASS=...
ru_ap_env_sock: .zero 160       # RHUN_ASKPASS=...
.p2align 3
ru_ap_env: .zero 8 * 6
ru_menu_base: .long 0
ru_recent_labels: .zero 512 * RU_RECENT_MAX
ru_key: .zero 4608
ru_saves: .zero VEC_SIZE        # DOC ids whose save waits for the reconnect

.data
ru_ps_fd: .long -1
ru_ap_listen: .long -1
ru_ap_conn: .long -1            # the askpass program waiting for an answer

.text

# ---------------- connected ----------------

# remote_connected(): the agent answered: learn the host's home and shell, open the project
FN remote_connected
    PROLOGUE
    lea rdi, [rip + .Lv_info]
    mov esi, 4
    xor edx, edx
    xor ecx, ecx
    call remote_call
    test rax, rax
    js 3f
    mov byte ptr [rip + g_remote_claude_dir], 0
    # home=... shell=... lines
    mov rbx, [rip + g_remote_reply + SB_ptr]
    mov r12, [rip + g_remote_reply + SB_len]
1:  test r12, r12
    jz 3f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    mov r13, rax                # line length
    test rax, rax
    jns 2f
    mov r13, r12
2:  mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Lk_home]
    mov ecx, 5
    call str_starts
    test eax, eax
    jz 21f
    lea rdi, [rip + g_remote_home]
    lea rsi, [rbx + 5]
    lea rdx, [r13 - 5]
    mov ecx, 4000
    call ru_copy_line
21: mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Lk_shell]
    mov ecx, 6
    call str_starts
    test eax, eax
    jz 22f
    lea rdi, [rip + g_remote_shell]
    lea rsi, [rbx + 6]
    lea rdx, [r13 - 6]
    mov ecx, 255
    call ru_copy_line
22: mov rdi, rbx                # the login environment's CLAUDE_CONFIG_DIR (claudecfg.s claude_dir)
    mov rsi, r13
    lea rdx, [rip + .Lk_cdir]
    mov ecx, 18
    call str_starts
    test eax, eax
    jz 23f
    lea rdi, [rip + g_remote_claude_dir]
    lea rsi, [rbx + 18]
    lea rdx, [r13 - 18]
    mov ecx, 4000
    call ru_copy_line
23: lea rax, [r13 + 1]
    add rbx, rax
    sub r12, rax
    jg 1b
3:  cmp dword ptr [rip + ru_opened], 0
    jne 8f
    mov dword ptr [rip + ru_opened], 1
    # the folder from the command line, else the home folder
    call remote_path
    cmp byte ptr [rax], 0
    jne 4f
    lea rax, [rip + g_remote_home]
    cmp byte ptr [rax], 0
    jne 4f
    lea rax, [rip + .Lroot]
4:  mov rbx, rax
    mov rdi, rax
    call app_set_project
    call ru_remember
    call session_restore
    call app_update_title
    jmp 9f
8:  call remote_attach          # programs that outlived the connection (remote.s)
    call vfs_reconnected        # watches again, documents compared with the host's files
    call ru_save_pending
    call agent_drv_remote_back  # conversations whose end could not be read then (agent_drv.s)
9:  call remote_ext_connected   # extensions that waited for the host (remoteext.s)
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# remote_save_later(doc): a save while the connection is down is made once it is back
FN remote_save_later
    PROLOGUE
    mov rbx, [rdi + DOC_id]
    xor ecx, ecx
1:  cmp rcx, [rip + ru_saves + VEC_len]
    jae 2f
    mov rax, [rip + ru_saves + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 3f
    inc rcx
    jmp 1b
2:  cmp qword ptr [rip + ru_saves + VEC_len], 256
    jae 3f
    lea rdi, [rip + ru_saves]
    mov esi, 8
    call vec_push
    mov [rax], rbx
3:  lea rdi, [rip + ru_sb]
    call sb_clear
    lea rdi, [rip + ru_sb]
    lea rsi, [rip + .Lsave_later]
    call sb_push_cstr
    call remote_host
    mov rsi, rax
    lea rdi, [rip + ru_sb]
    call sb_push_cstr
    lea rdi, [rip + ru_sb]
    lea rsi, [rip + .Lsave_later2]
    call sb_push_cstr
    mov rdi, [rip + ru_sb + SB_ptr]
    call app_toast
    EPILOGUE

# ru_save_pending(): connected again: the saves that waited are made (of files still open and changed)
ru_save_pending:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + ru_saves + VEC_len]
    jae 8f
    mov rax, [rip + ru_saves + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call extproto_doc
    test rax, rax
    jz 2f
    mov r12, rax
    mov rdi, rax
    call doc_dirty
    test eax, eax
    jz 2f
    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call app_save_managed
2:  inc rbx
    jmp 1b
8:  mov qword ptr [rip + ru_saves + VEC_len], 0
    EPILOGUE

# ru_copy_line(dst, ptr, len, max): a value of at most max bytes into dst with its NUL
ru_copy_line:
    test rdx, rdx
    jle 9f
    cmp rdx, rcx
    jae 9f
    push rdi
    push rdx
    call memcpy
    pop rdx
    pop rdi
    mov byte ptr [rdi + rdx], 0
9:  ret

# remote_project_label(): app_set_project in a remote window: its name reads "HOST: name"
FN remote_project_label
    cmp dword ptr [rip + g_remote], 0
    je 9f
    push rbx
    mov rbx, [rip + g_project_name]
    test rbx, rbx
    jz 8f
    call remote_host
    mov rsi, rax
    cmp byte ptr [rsi], 0
    jne 1f
    lea rsi, [rip + .Llocal_name]
1:  lea rdi, [rip + ru_label]
    call ru_copy_cap
    mov rdi, rax
    lea rsi, [rip + .Lcolon_sp]
    call cstr_copy
    mov rdi, rax
    mov rsi, rbx
    call ru_copy_cap
    lea rax, [rip + ru_label]
    mov [rip + g_project_name], rax
8:  pop rbx
9:  ret

# ru_copy_cap(dst, src) -> end: cstr_copy within ru_label's 512 bytes
ru_copy_cap:
    lea rcx, [rip + ru_label + 500]
1:  cmp rdi, rcx
    jae 2f
    mov al, [rsi]
    test al, al
    jz 2f
    mov [rdi], al
    inc rdi
    inc rsi
    jmp 1b
2:  mov byte ptr [rdi], 0
    mov rax, rdi
    ret

# remote_session_key(path) -> "SPEC" and the path (static): the name of a remote window's session file
FN remote_session_key
    push rbx
    mov rbx, rdi
    call remote_spec
    lea rdi, [rip + ru_key]
    mov rsi, rax
    call cstr_copy
    lea rcx, [rip + ru_key + 4096]
1:  cmp rax, rcx
    jae 2f
    mov dl, [rbx]
    mov [rax], dl
    test dl, dl
    jz 2f
    inc rax
    inc rbx
    jmp 1b
2:  mov byte ptr [rip + ru_key + 4096], 0
    lea rax, [rip + ru_key]
    pop rbx
    ret

# remote_session_prefix(name, len) -> the length of this window's spec at the start of a session file's
#   name (followed by its path's first %), or 0 for another remote's or a local folder's
FN remote_session_prefix
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call remote_spec
    mov r13, rax
    mov rdi, rax
    call strlen
    cmp rax, r12
    jae 8f
    cmp byte ptr [rbx + rax], '%'
    jne 8f
    push rax
    mov rdi, rbx
    mov rsi, r13
    mov rdx, rax
    call memeq
    pop rcx
    test eax, eax
    jz 8f
    mov rax, rcx
    jmp 9f
8:  xor eax, eax
9:  pop r13
    pop r12
    pop rbx
    ret

# ---------------- the bar ----------------

# remote_bar(x, y, w) -> its height (0 when connected or not remote): the connection's progress, or
#   why it failed or was lost with Retry / Reconnect
FN remote_bar
    PROLOGUE 48
    xor eax, eax
    cmp dword ptr [rip + g_remote], 0
    je 9f
    mov ebx, [rip + g_remote_state]
    cmp ebx, 6                  # RS_UP
    je 9f
    test ebx, ebx
    jz 9f
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    # the text
    lea rdi, [rip + ru_sb]
    call sb_clear
    call remote_host
    mov r12, rax
    cmp byte ptr [r12], 0
    jne 1f
    lea r12, [rip + .Llocal_name]
1:  cmp ebx, 1
    jne 2f
    lea rdi, [rip + .Lb_download]
    lea rsi, [rip + rhun_version]
    lea rdx, [rip + .Lb_download2]
    call ru_bar_text3
    jmp 6f
2:  cmp ebx, 2
    jne 3f
    lea rdi, [rip + .Lb_connect]
    mov rsi, r12
    lea rdx, [rip + .Lellipsis]
    call ru_bar_text3
    jmp 6f
3:  cmp ebx, 5
    jne 4f
    lea rdi, [rip + .Lb_start]
    mov rsi, r12
    lea rdx, [rip + .Lellipsis]
    call ru_bar_text3
    jmp 6f
4:  cmp ebx, 4
    ja 5f
    # uploading: how far
    lea rdi, [rip + .Lb_upload]
    lea rsi, [rip + rhun_version]
    lea rdx, [rip + .Lb_upload2]
    call ru_bar_text3
    lea rdi, [rip + ru_sb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + ru_sb]
    lea rsi, [rip + .Lellipsis_sp]
    call sb_push_cstr
    call remote_upload_progress
    test rdx, rdx
    jz 6f
    imul rax, rax, 100
    xor ecx, ecx
    xchg rcx, rdx
    div rcx
    lea rdi, [rip + ru_sb]
    mov rsi, rax
    call sb_push_u64
    lea rdi, [rip + ru_sb]
    mov esi, '%'
    call sb_push_byte
    jmp 6f
5:  # lost or failed: the reason, and a button
    lea rdi, [rip + ru_sb]
    call remote_error
    mov rsi, rax
    lea rdi, [rip + ru_sb]
    call sb_push_cstr
6:  M r13d, MI_28               # the bar's height
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, r13d
    COLOR r8d, T_PANEL
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, r13d
    sub esi, [rip + g_mt + 4*MI_1]
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    # the button at the right end when it ended
    mov eax, [rsp]
    add eax, [rsp + 8]
    mov [rsp + 12], eax         # where the text must end
    cmp ebx, 7                  # RS_LOST
    jb 7f
    lea r14, [rip + .Lb_reconnect]
    cmp ebx, 7
    je 61f
    lea r14, [rip + .Lb_retry]
61: lea rdi, [rip + g_face_small]
    mov rsi, r14
    mov rdi, r14
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r14
    mov rdx, rax
    call text_width
    M ecx, MI_12
    lea eax, [rax + rcx*2]
    mov [rsp + 16], eax         # button w
    mov ecx, [rsp]
    add ecx, [rsp + 8]
    sub ecx, eax
    sub ecx, [rip + g_mt + 4*MI_8]
    mov [rsp + 20], ecx         # button x
    mov [rsp + 12], ecx
    M r15d, MI_20
    mov eax, r13d
    sub eax, r15d
    sar eax, 1
    add eax, [rsp + 4]
    mov [rsp + 24], eax         # button y
    mov edi, ID_RM_BAR
    mov esi, [rsp + 20]
    mov edx, eax
    mov ecx, [rsp + 16]
    mov r8d, r15d
    call ui_btn
    mov [rsp + 28], eax
    COLOR r12d, T_ACCENT
    test eax, UB_HOVER
    jz 62f
    mov edi, r12d
    COLOR esi, T_ACCENT_FG
    mov edx, 36
    call color_mix
    mov r12d, eax
62: mov edi, [rsp + 20]
    mov esi, [rsp + 24]
    mov edx, [rsp + 16]
    mov ecx, r15d
    M r8d, MI_RADIUS
    mov r9d, r12d
    call gfx_round_rect
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 20]
    mov edx, [rsp + 24]
    mov ecx, [rsp + 16]
    mov r8d, r15d
    mov r9, r14
    COLOR eax, T_ACCENT_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    test dword ptr [rsp + 28], UB_CLICK
    jz 7f
    call remote_reconnect
7:  # the text, cut before the button
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    sub edx, edi
    sub edx, [rip + g_mt + 4*MI_8]
    mov ecx, r13d
    call gfx_clip_push
    COLOR r9d, T_FG
    cmp ebx, 7
    jb 71f
    COLOR r9d, T_WARNING
    cmp ebx, 7
    je 71f
    COLOR r9d, T_ERROR
71: lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, [rsp + 4]
    mov ecx, r13d
    mov r8, [rip + ru_sb + SB_ptr]
    call ui_text_c
    call gfx_clip_pop
    mov eax, r13d
9:  EPILOGUE

# ru_bar_text3(a, b, c): ru_sb gets the three strings
ru_bar_text3:
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r12, rdx
    mov rsi, rdi
    lea rdi, [rip + ru_sb]
    call sb_push_cstr
    lea rdi, [rip + ru_sb]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + ru_sb]
    mov rsi, r12
    call sb_push_cstr
    pop r13
    pop r12
    pop rbx
    ret

# ---------------- the status bar item ----------------

# remote_status_item(x, y, h) -> the x where the next item starts: "SSH: HOST" at the bar's left end,
#   whose click opens the remote menu
FN remote_status_item
    PROLOGUE 48
    mov eax, edi
    cmp dword ptr [rip + g_remote], 0
    je 9f
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    lea rdi, [rip + ru_sb]
    call sb_clear
    call remote_kind_name
    mov rbx, rax
    lea r13, [rip + .Lkinds]
1:  mov rsi, [r13]
    test rsi, rsi
    jz 2f
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jnz 3f
    add r13, 16
    jmp 1b
2:  lea r13, [rip + .Lkinds]
3:  mov rsi, [r13 + 8]
    lea rdi, [rip + ru_sb]
    call sb_push_cstr
    call remote_host
    cmp byte ptr [rax], 0
    je 4f
    mov rbx, rax
    lea rdi, [rip + ru_sb]
    lea rsi, [rip + .Lcolon_sp]
    call sb_push_cstr
    lea rdi, [rip + ru_sb]
    mov rsi, rbx
    call sb_push_cstr
4:  lea rdi, [rip + g_face_small]
    mov rsi, [rip + ru_sb + SB_ptr]
    mov rdx, [rip + ru_sb + SB_len]
    call text_width
    M ecx, MI_12
    lea eax, [rax + rcx*2]
    mov [rsp + 12], eax         # w
    mov edi, ID_RM_STATUS
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, eax
    mov r8d, [rsp + 8]
    call ui_btn
    mov ebx, eax
    COLOR r12d, T_ACCENT
    mov eax, [rip + g_remote_state]
    cmp eax, 6
    je 5f
    COLOR r12d, T_WARNING
    cmp eax, 7
    jb 5f
    COLOR r12d, T_ERROR
5:  test ebx, UB_HOVER
    jz 6f
    mov dword ptr [rip + g_cursor], CUR_POINTER
    mov edi, r12d
    COLOR esi, T_ACCENT_FG
    mov edx, 30
    call color_mix
    mov r12d, eax
6:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 8]
    mov r8d, r12d
    call gfx_fill
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 8]
    mov r9, [rip + ru_sb + SB_ptr]
    COLOR eax, T_ACCENT_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    test ebx, UB_CLICK
    jz 7f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    call remote_menu_open
7:  mov eax, [rsp]
    add eax, [rsp + 12]
9:  EPILOGUE

# remote_menu_open(x, y): Disconnect, Reconnect, Show Remote Log, Connect to Host, Attach to Container
FN remote_menu_open
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    lea rbx, [rip + ru_menu]
    cmp dword ptr [rip + g_remote_state], 6
    jne 1f
    lea rax, [rip + .Lm_disconnect]
    mov [rbx], rax
    lea rax, [rip + cmd_remote_disconnect]
    mov [rbx + 8], rax
    add rbx, 16
    jmp 2f
1:  lea rax, [rip + .Lm_reconnect]
    mov [rbx], rax
    lea rax, [rip + cmd_remote_reconnect]
    mov [rbx + 8], rax
    add rbx, 16
2:  lea rax, [rip + .Lm_log]
    mov [rbx], rax
    lea rax, [rip + cmd_remote_show_log]
    mov [rbx + 8], rax
    lea rax, [rip + .Lm_forward]
    mov [rbx + 16], rax
    lea rax, [rip + cmd_remote_forward_port]
    mov [rbx + 24], rax
    add rbx, 32
    call remote_forwards_count
    test eax, eax
    jz 3f
    lea rax, [rip + .Lm_unforward]
    mov [rbx], rax
    lea rax, [rip + cmd_remote_stop_forwarding]
    mov [rbx + 8], rax
    add rbx, 16
3:  lea rax, [rip + .Lm_line]
    mov [rbx], rax
    mov qword ptr [rbx + 8], 0
    lea rax, [rip + .Lm_host]
    mov [rbx + 16], rax
    lea rax, [rip + cmd_connect_to_host]
    mov [rbx + 24], rax
    lea rax, [rip + .Lm_container]
    mov [rbx + 32], rax
    lea rax, [rip + cmd_attach_to_container]
    mov [rbx + 40], rax
    mov qword ptr [rbx + 48], 0
    mov qword ptr [rbx + 56], 0
    lea rdi, [rip + ru_menu]
    mov esi, r12d
    mov edx, r13d
    call ctx_menu_open
    pop r13
    pop r12
    pop rbx
    ret

FN cmd_remote_disconnect
    jmp remote_disconnect

# cmd_remote_forward_port(): Forward a Port: its number on the host, asked in the prompt
FN cmd_remote_forward_port
    sub rsp, 8
    call remote_is_up
    test eax, eax
    jnz 1f
    lea rdi, [rip + .Lfw_down]
    call app_toast
    add rsp, 8
    ret
1:  mov dword ptr [rip + ru_fw_prompt], 1
    lea rdi, [rip + .Lfw_label]
    mov esi, PROMPT_REMOTE
    xor edx, edx
    xor ecx, ecx
    call palette_ext_prompt_open
    add rsp, 8
    ret

# cmd_remote_stop_forwarding(): every forwarded port stops
FN cmd_remote_stop_forwarding
    sub rsp, 8
    xor edi, edi
    call remote_unforward
    lea rdi, [rip + .Lfw_stopped]
    call app_toast
    add rsp, 8
    ret

# ru_fw_answer(text, len): the port typed: forwarded, and the toast says where it is reached
ru_fw_answer:
    PROLOGUE
    call trim
    mov rdi, rax
    mov rsi, rdx
    mov r12, rdx
    call parse_u64
    test rdx, rdx
    jz 8f
    cmp rdx, r12
    jne 8f
    mov r13, rax
    mov edi, eax
    call remote_forward
    test eax, eax
    jle 7f
    mov ebx, eax
    lea rdi, [rip + ru_fw_msg]
    lea rsi, [rip + .Lfw_ok1]
    call cstr_copy
    mov rdi, rax
    mov esi, ebx
    call fmt_u64                # rdi after the digits
    lea rsi, [rip + .Lfw_ok2]
    call cstr_copy
    mov rdi, rax
    mov rsi, r13
    call fmt_u64
    lea rsi, [rip + .Lfw_ok3]
    call cstr_copy
    mov rbx, rax
    call remote_host
    mov rdi, rbx
    mov rsi, rax
    call cstr_copy
    lea rdi, [rip + ru_fw_msg]
    call app_toast
    jmp 9f
7:  lea rdi, [rip + .Lfw_failed]
    call app_toast
    jmp 9f
8:  lea rdi, [rip + .Lfw_bad]
    call app_toast
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE
FN cmd_remote_reconnect
    jmp remote_reconnect

# cmd_remote_show_log(): the remote log opens in a local window of its own (this window's files are
#   the host's)
FN cmd_remote_show_log
    push rbx
    call remote_log_path
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    call file_missing
    test eax, eax
    jnz 8f
    cmp dword ptr [rip + g_remote], 0
    jne 1f
    mov rdi, rbx
    call app_open_path
    jmp 9f
1:  mov rdi, rbx
    call app_new_window
    jmp 9f
8:  lea rdi, [rip + .Lno_log]
    call app_toast
9:  pop rbx
    ret

# ---------------- Connect to Host, Attach to Container ----------------

# ru_list_reset(): an empty name list
ru_list_reset:
    sub rsp, 8
    lea rdi, [rip + ru_names]
    call sb_clear
    mov qword ptr [rip + ru_offs + VEC_len], 0
    add rsp, 8
    ret

# ru_list_add(ptr, len): a name, unless it is there already
ru_list_add:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    test r13, r13
    jz 9f
    cmp r13, 250
    ja 9f
    xor ebx, ebx
1:  cmp rbx, [rip + ru_offs + VEC_len]
    jae 2f
    mov rdi, rbx
    call ru_list_name
    mov rdi, rax
    call strlen
    mov rdi, rax
    push rdi
    push rdi
    mov rdi, rbx
    call ru_list_name
    pop rsi
    pop rsi
    mov rdi, rax
    mov rdx, r12
    mov rcx, r13
    call str_eq
    test eax, eax
    jnz 9f
    inc rbx
    jmp 1b
2:  lea rdi, [rip + ru_offs]
    mov esi, 8
    call vec_push
    mov rcx, [rip + ru_names + SB_len]
    mov [rax], rcx
    lea rdi, [rip + ru_names]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + ru_names]
    xor esi, esi
    call sb_push_byte
9:  EPILOGUE

# ru_list_name(i) -> cstr
ru_list_name:
    mov rax, [rip + ru_offs + VEC_ptr]
    mov rax, [rax + rdi*8]
    add rax, [rip + ru_names + SB_ptr]
    ret

# ru_list_show(label): the names into the remote pick list
ru_list_show:
    PROLOGUE
    call palette_remote_open
    xor ebx, ebx
1:  cmp rbx, [rip + ru_offs + VEC_len]
    jae 2f
    mov rdi, rbx
    call ru_list_name
    mov r12, rax
    mov rdi, rax
    call strlen
    mov rdi, r12
    mov rsi, rax
    mov rdx, rbx
    call palette_choose_add
    inc rbx
    jmp 1b
2:  call palette_choose_ready
    EPILOGUE

# cmd_connect_to_host(): the hosts of ~/.ssh/config and the recent ones; a name typed is taken too
FN cmd_connect_to_host
    PROLOGUE INI_SIZE
    call ru_list_reset
    # recent ssh remotes first
    call ru_recent_load
    mov rbx, [rip + ru_recent + SB_ptr]
    mov r12, [rip + ru_recent + SB_len]
1:  test rbx, rbx
    jz 3f
    test r12, r12
    jle 3f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    mov r13, rax
    test rax, rax
    jns 11f
    mov r13, r12
11: mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Ls_ssh]
    mov ecx, 4
    call str_starts
    test eax, eax
    jz 2f
    # "ssh:HOST PATH": the host
    lea rdi, [rbx + 4]
    lea rsi, [r13 - 4]
    lea rdx, [rip + .Lsp]
    mov ecx, 1
    call str_find
    mov rsi, rax
    test rax, rax
    jns 12f
    lea rsi, [r13 - 4]
12: lea rdi, [rbx + 4]
    call ru_list_add
2:  lea rax, [r13 + 1]
    add rbx, rax
    sub r12, rax
    jmp 1b
3:  # ~/.ssh/config: the names on Host lines, without patterns
    lea rdi, [rip + .Lhome]
    call getenv
    test rax, rax
    jz 8f
    mov rdi, rax
    lea rsi, [rip + .Lssh_config]
    call path_join
    mov rbx, rax
    mov rdi, rax
    call file_read_all
    mov r14, rax
    mov r15, rdx
    mov rdi, rbx
    call mem_free
    test r14, r14
    jz 8f
    mov rbx, r14                # the line
4:  mov rax, r14
    add rax, r15
    cmp rbx, rax
    jae 7f
    mov rdi, rbx
    mov rsi, rax
    sub rsi, rbx
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    mov r13, rax
    test rax, rax
    jns 41f
    mov r13, r14
    add r13, r15
    sub r13, rbx
41: mov rdi, rbx
    mov rsi, r13
    call trim
    mov r12, rax
    mov [rsp], rdx
    # "Host" (any case) and a blank
    cmp rdx, 5
    jb 6f
    mov eax, [r12]
    or eax, 0x20202020
    cmp eax, 0x74736f68         # "host"
    jne 6f
    mov al, [r12 + 4]
    cmp al, ' '
    je 42f
    cmp al, 9
    jne 6f
42: lea rdi, [r12 + 5]
    mov rsi, [rsp]
    sub rsi, 5
5:  test rsi, rsi
    jle 6f
    mov [rsp + 8], rdi
    mov [rsp + 16], rsi
    call next_word
    test rdx, rdx
    jz 6f
    mov [rsp + 24], rcx
    mov rdi, rax
    mov rsi, rdx
    call ru_is_pattern
    test eax, eax
    jnz 51f
    call ru_list_add
51: mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    mov rcx, [rsp + 24]
    add rdi, rcx
    sub rsi, rcx
    jmp 5b
6:  lea rbx, [rbx + r13 + 1]
    jmp 4b
7:  mov rdi, r14
    call mem_free
8:  mov dword ptr [rip + ru_pick], RP_HOST
    lea rdi, [rip + .Lp_host]
    call ru_list_show
    EPILOGUE

# ru_is_pattern(ptr, len) -> 1 for a Host pattern (* ? !), which names no one host; keeps rdi, rsi
ru_is_pattern:
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 8f
    mov al, [rdi + rcx]
    cmp al, '*'
    je 9f
    cmp al, '?'
    je 9f
    cmp al, '!'
    je 9f
    inc rcx
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# cmd_attach_to_container(): the running containers, from docker ps (podman ps without docker)
FN cmd_attach_to_container
    PROLOGUE 64
    cmp dword ptr [rip + ru_ps_pid], 0
    jne 9f
    lea rdi, [rip + .Ldocker]
    lea rax, [rip + .Ls_docker]
    mov [rsp + 56], rax
    call remote_which
    test rax, rax
    jnz 1f
    lea rdi, [rip + .Lpodman]
    lea rax, [rip + .Ls_podman]
    mov [rsp + 56], rax
    call remote_which
    test rax, rax
    jz 8f
1:  mov rbx, rax
    lea rdi, [rip + ru_ps_kind]
    mov rsi, [rsp + 56]
    call cstr_copy
    mov [rsp], rbx
    lea rax, [rip + .Lps]
    mov [rsp + 8], rax
    lea rax, [rip + .Lformat]
    mov [rsp + 16], rax
    lea rax, [rip + .Lformat_names]
    mov [rsp + 24], rax
    mov qword ptr [rsp + 32], 0
    lea rdi, [rsp]
    mov rsi, [rip + g_envp]
    xor edx, edx
    call run_piped
    mov r12, rax
    mov r13d, edx
    mov rdi, rbx
    call mem_free
    test r12, r12
    jle 8f
    mov [rip + ru_ps_pid], r12d
    mov [rip + ru_ps_fd], r13d
    lea rdi, [rip + ru_ps_out]
    call sb_clear
    mov edi, r13d
    mov esi, POLLIN
    lea rdx, [rip + ru_on_ps]
    xor ecx, ecx
    call watch_add
    jmp 9f
8:  lea rdi, [rip + .Lno_docker]
    call app_toast
9:  EPILOGUE

# cmd_connect_to_wsl(): Connect to WSL: the distributions `wsl.exe -l -q` lists (Windows)
FN cmd_connect_to_wsl
    PROLOGUE 48
    cmp dword ptr [rip + ru_ps_pid], 0
    jne 9f
    lea rdi, [rip + .Lwsl]
    call remote_which
    test rax, rax
    jz 8f
    mov rbx, rax
    lea rdi, [rip + ru_ps_kind]
    lea rsi, [rip + .Ls_wsl]
    call cstr_copy
    mov [rsp], rbx
    lea rax, [rip + .Ldash_l]
    mov [rsp + 8], rax
    lea rax, [rip + .Ldash_q]
    mov [rsp + 16], rax
    mov qword ptr [rsp + 24], 0
    lea rdi, [rsp]
    mov rsi, [rip + g_envp]
    xor edx, edx
    call run_piped
    mov r12, rax
    mov r13d, edx
    mov rdi, rbx
    call mem_free
    test r12, r12
    jle 8f
    mov [rip + ru_ps_pid], r12d
    mov [rip + ru_ps_fd], r13d
    lea rdi, [rip + ru_ps_out]
    call sb_clear
    mov edi, r13d
    mov esi, POLLIN
    lea rdx, [rip + ru_on_ps]
    xor ecx, ecx
    call watch_add
    jmp 9f
8:  lea rdi, [rip + .Lno_wsl]
    call app_toast
9:  EPILOGUE

# ru_on_ps(fd, revents, ctx): the containers' names; at the end, the pick list
ru_on_ps:
    PROLOGUE
1:  lea rdi, [rip + ru_ps_out]
    mov esi, 4096
    call sb_reserve
    mov rsi, rax
    mov edi, [rip + ru_ps_fd]
    mov edx, 4096
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 2f
    cmp qword ptr [rip + ru_ps_out + SB_len], 262144
    jae 1b
    add [rip + ru_ps_out + SB_len], rax
    jmp 1b
2:  mov edi, [rip + ru_ps_fd]
    call watch_remove
    mov edi, [rip + ru_ps_fd]
    SYS SYS_close
    mov dword ptr [rip + ru_ps_fd], -1
    mov edi, [rip + ru_ps_pid]
    xor esi, esi
    call proc_wait
    mov dword ptr [rip + ru_ps_pid], 0
    call ru_list_reset
    # wsl.exe answers in UTF-16: NULs and byte-order marks go (names are ASCII)
    mov rsi, [rip + ru_ps_out + SB_ptr]
    mov rcx, [rip + ru_ps_out + SB_len]
    test rsi, rsi
    jz 13f
    xor edx, edx
    xor edi, edi
11: cmp rdx, rcx
    jae 12f
    movzx eax, byte ptr [rsi + rdx]
    inc rdx
    test eax, eax
    jz 11b
    cmp eax, 0xfe
    jae 11b
    mov [rsi + rdi], al
    inc rdi
    jmp 11b
12: mov [rip + ru_ps_out + SB_len], rdi
13: mov rbx, [rip + ru_ps_out + SB_ptr]
    mov r12, [rip + ru_ps_out + SB_len]
    test rbx, rbx
    jz 5f
3:  test r12, r12
    jle 5f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    mov r13, rax
    test rax, rax
    jns 4f
    mov r13, r12
4:  mov rdi, rbx
    mov rsi, r13
    call trim
    mov rdi, rax
    mov rsi, rdx
    call ru_list_add
    lea rax, [r13 + 1]
    add rbx, rax
    sub r12, rax
    jmp 3b
5:  cmp qword ptr [rip + ru_offs + VEC_len], 0
    jne 6f
    lea rdi, [rip + .Lno_containers]
    call app_toast
    jmp 9f
6:  mov dword ptr [rip + ru_pick], RP_CONTAINER
    lea rdi, [rip + .Lp_container]
    call ru_list_show
9:  EPILOGUE

# remote_ui_accept(item or -1, text ptr, len): the remote pick list's Enter
FN remote_ui_accept
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov eax, [rip + ru_pick]
    mov r14d, eax
    mov dword ptr [rip + ru_pick], 0
    cmp eax, RP_YESNO
    je .Lua_yesno
    cmp eax, RP_HOST
    je 1f
    cmp eax, RP_CONTAINER
    jne 9f
1:  # the name: the item's, else what was typed
    test rbx, rbx
    js 2f
    cmp rbx, [rip + ru_offs + VEC_len]
    jae 9f
    mov rdi, rbx
    call ru_list_name
    mov r12, rax
    mov rdi, rax
    call strlen
    mov r13, rax
2:  mov rdi, r12
    mov rsi, r13
    call trim
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 9f
    cmp r13, 400
    ja 9f
    # the spec: ssh:NAME, docker:NAME or podman:NAME
    lea rdi, [rip + ru_spec]
    lea rsi, [rip + .Ls_ssh]
    cmp r14d, RP_CONTAINER
    jne 3f
    lea rsi, [rip + ru_ps_kind]
3:  call cstr_copy
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call memcpy
    mov byte ptr [rax + r13], 0
    lea rdi, [rip + ru_spec]
    xor esi, esi
    call remote_open
    jmp 9f
.Lua_yesno:
    # ssh's yes/no question: the item (1 yes, 0 no); typed text goes as it is
    lea rdi, [rip + ru_sb]
    call sb_clear
    test rbx, rbx
    js 4f
    lea rsi, [rip + .Lyes]
    test rbx, rbx
    jnz 5f
    lea rsi, [rip + .Lno]
5:  lea rdi, [rip + ru_sb]
    call sb_push_cstr
    jmp 6f
4:  lea rdi, [rip + ru_sb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
6:  mov rdi, [rip + ru_sb + SB_ptr]
    mov rsi, [rip + ru_sb + SB_len]
    call ru_ap_answer
9:  EPILOGUE

# remote_open(spec, path): a window for the remote: this one when it is empty (no project, no tabs,
#   not remote), else a new window running `rhun --remote SPEC [PATH]`
FN remote_open
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [rip + g_remote], 0
    jne 1f
    cmp qword ptr [rip + g_project], 0
    jne 1f
    cmp qword ptr [rip + g_tabs + VEC_len], 0
    jne 1f
    mov rdi, rbx
    mov rsi, r12
    call remote_start
    EPILOGUE
1:  call ru_self_exe
    test eax, eax
    jz 8f
    lea rax, [rip + ru_exe]
    mov [rsp], rax
    lea rax, [rip + .Lo_remote]
    mov [rsp + 8], rax
    mov [rsp + 16], rbx
    mov [rsp + 24], r12
    mov qword ptr [rsp + 32], 0
    lea rdi, [rip + .Ldevnull]
    mov esi, O_RDWR | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 8f
    mov r13d, eax
    lea rdi, [rsp]
    mov rsi, [rip + g_envp]
    xor edx, edx
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, r13d
    push 1                      # a session of its own, as app_new_window starts one
    push 1
    call proc_spawn
    add rsp, 16
    mov r14, rax
    mov edi, r13d
    SYS SYS_close
    test r14, r14
    jle 8f
    mov edi, r14d
    call reap_later
    EPILOGUE
8:  lea rdi, [rip + .Lno_window]
    call app_toast
    EPILOGUE

# ru_self_exe() -> 1 with this program's path in ru_exe (RHUN_NEW_WINDOW names another, for tests;
#   without it a headless rhun starts no window)
ru_self_exe:
    PROLOGUE
    lea rdi, [rip + .Lenv_new_window]
    call getenv
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 0
    je 1f
    mov rbx, rax
    mov rdi, rax
    call strlen
    cmp rax, 4096
    jae 8f
    lea rdi, [rip + ru_exe]
    mov rsi, rbx
    call cstr_copy
    jmp 7f
1:  cmp dword ptr [rip + g_headless], 0
    jne 8f
    call ru_exe_path
    test eax, eax
    jz 8f
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ru_exe_path() -> 1 with the running program's real path in ru_exe (ssh runs it as askpass, so
#   not /proc/self/exe, which would be ssh itself)
ru_exe_path:
    PROLOGUE
.ifdef WINDOWS
    lea rdi, [rip + ru_exe]
    mov esi, 4096
    call proc_self_path
    test rax, rax
    jle 8f
.else
.ifdef MACOS
    lea rdi, [rip + ru_exe]
    mov esi, 4096
    call mac_exe_path
    test rax, rax
    js 8f
.else
    lea rdi, [rip + .Lproc_self]
    lea rsi, [rip + ru_exe]
    mov edx, 4095
    SYS SYS_readlink
    test rax, rax
    jle 8f
    lea rcx, [rip + ru_exe]
    mov byte ptr [rcx + rax], 0
    # " (deleted)": an update replaced the file
    mov rbx, rax
    lea rdi, [rip + ru_exe]
    mov rsi, rax
    lea rdx, [rip + .Ldeleted]
    mov ecx, 10
    call str_ends
    test eax, eax
    jz 7f
    lea rcx, [rip + ru_exe]
    mov byte ptr [rcx + rbx - 10], 0
.endif
.endif
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- recent remotes ----------------

# ru_recent_path() -> "$XDG_STATE_HOME/rhun/remotes" (in ru_sb) or 0
ru_recent_path:
    sub rsp, 8
    lea rdi, [rip + ru_sb]
    call session_state_dir
    test eax, eax
    jz 1f
    lea rdi, [rip + ru_sb]
    lea rsi, [rip + .Lremotes_file]
    call sb_push_cstr
    mov rax, [rip + ru_sb + SB_ptr]
    add rsp, 8
    ret
1:  xor eax, eax
    add rsp, 8
    ret

# ru_recent_load(): the file's lines "SPEC PATH" into ru_recent
ru_recent_load:
    push rbx
    lea rdi, [rip + ru_recent]
    call sb_clear
    call ru_recent_path
    test rax, rax
    jz 9f
    mov rdi, rax
    call file_read_all
    test rax, rax
    jz 9f
    mov rbx, rax
    lea rdi, [rip + ru_recent]
    mov rsi, rax
    call sb_push
    mov rdi, rbx
    call mem_free
9:  pop rbx
    ret

# ru_remember(): this remote and folder go first in the recent remotes (at most RU_RECENT_MAX)
ru_remember:
    PROLOGUE
    call ru_recent_load
    lea rdi, [rip + ru_names]
    call sb_clear
    lea rdi, [rip + ru_names]
    call remote_spec
    mov rsi, rax
    lea rdi, [rip + ru_names]
    call sb_push_cstr
    lea rdi, [rip + ru_names]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + ru_names]
    mov rsi, [rip + g_project]
    call sb_push_cstr
    lea rdi, [rip + ru_names]
    mov esi, 10
    call sb_push_byte
    mov r14, [rip + ru_names + SB_len]   # the new line's length
    mov rbx, [rip + ru_recent + SB_ptr]
    mov r12, [rip + ru_recent + SB_len]
    mov r15d, 1                 # lines
1:  test rbx, rbx
    jz 5f
    test r12, r12
    jle 5f
    cmp r15d, RU_RECENT_MAX
    jae 5f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    lea r13, [rax + 1]
    test rax, rax
    jns 2f
    mov r13, r12
2:  # the same line as the new one is dropped
    mov rdi, rbx
    mov rsi, r13
    mov rdx, [rip + ru_names + SB_ptr]
    mov rcx, r14
    call str_eq
    test eax, eax
    jnz 3f
    lea rdi, [rip + ru_names]
    mov rsi, rbx
    mov rdx, r13
    call sb_push
    cmp byte ptr [rbx + r13 - 1], 10
    je 21f
    lea rdi, [rip + ru_names]
    mov esi, 10
    call sb_push_byte
21: inc r15d
3:  add rbx, r13
    sub r12, r13
    jmp 1b
5:  call ru_recent_path
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, [rip + ru_names + SB_ptr]
    mov rdx, [rip + ru_names + SB_len]
    call file_write_all
9:  EPILOGUE

# remote_recent_count() -> eax recent remotes (the project menu lists them), loading them
FN remote_recent_count
    push rbx
    call ru_recent_load
    xor eax, eax
    mov rcx, [rip + ru_recent + SB_ptr]
    test rcx, rcx
    jz 9f
    mov rdx, [rip + ru_recent + SB_len]
    xor ebx, ebx
1:  test rdx, rdx
    jz 9f
    cmp byte ptr [rcx], 10
    jne 2f
    inc eax
2:  inc rcx
    dec rdx
    jmp 1b
9:  pop rbx
    ret

# remote_recent_label(i, dst 512) -> dst: "HOST: path" of recent remote i (after remote_recent_count)
FN remote_recent_label
    PROLOGUE
    mov rbx, rsi
    call ru_recent_line         # rax line, rdx its length
    test rax, rax
    jz 8f
    mov r12, rax
    mov r13, rdx
    # SPEC up to the blank; its part after the colon
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lsp]
    mov ecx, 1
    call str_find
    test rax, rax
    js 8f
    mov r14, rax
    mov rdi, r12
    mov rsi, r14
    lea rdx, [rip + .Lcolon]
    mov ecx, 1
    call str_find
    lea rsi, [r12 + rax + 1]
    mov rdx, r14
    sub rdx, rax
    dec rdx
    cmp rdx, 200
    ja 8f
    test rdx, rdx
    jnz 2f
    lea rsi, [rip + .Llocal_name]   # local: (tests) has no host
    mov edx, 5
2:  mov rdi, rbx
    push rdx
    push rdx
    call memcpy
    pop rdx
    pop rdx
    lea rdi, [rbx + rdx]
    lea rsi, [rip + .Lcolon_sp]
    call cstr_copy
    lea rsi, [r12 + r14 + 1]
    mov rdx, r13
    sub rdx, r14
    dec rdx
    cmp rdx, 290
    jbe 1f
    mov edx, 290
1:  mov rdi, rax
    push rdi
    push rdx
    call memcpy
    pop rdx
    pop rdi
    mov byte ptr [rdi + rdx], 0
    mov rax, rbx
    EPILOGUE
8:  mov byte ptr [rbx], 0
    mov rax, rbx
    EPILOGUE

# ru_recent_line(i) -> rax line i of ru_recent (without its LF), rdx its length; 0 when none
ru_recent_line:
    mov rax, [rip + ru_recent + SB_ptr]
    test rax, rax
    jz 8f
    mov rcx, [rip + ru_recent + SB_len]
    add rcx, rax
1:  test rdi, rdi
    jz 3f
2:  cmp rax, rcx
    jae 8f
    inc rax
    cmp byte ptr [rax - 1], 10
    jne 2b
    dec rdi
    jmp 1b
3:  mov rdx, rax
4:  cmp rdx, rcx
    jae 5f
    cmp byte ptr [rdx], 10
    je 5f
    inc rdx
    jmp 4b
5:  sub rdx, rax
    jz 8f
    ret
8:  xor eax, eax
    xor edx, edx
    ret

# remote_recent_open(i): recent remote i opens (remote_open)
FN remote_recent_open
    PROLOGUE
    call ru_recent_line
    test rax, rax
    jz 9f
    mov r12, rax
    mov r13, rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lsp]
    mov ecx, 1
    call str_find
    test rax, rax
    js 9f
    mov rbx, rax
    cmp rbx, 500
    jae 9f
    lea rdi, [rip + ru_spec]
    mov rsi, r12
    mov rdx, rbx
    call memcpy
    lea rcx, [rip + ru_spec]
    mov byte ptr [rcx + rbx], 0
    lea rsi, [r12 + rbx + 1]
    mov rdx, r13
    sub rdx, rbx
    dec rdx
    cmp rdx, 4000
    jae 9f
    lea rdi, [rip + ru_exe]
    push rdx
    push rdx
    call memcpy
    pop rdx
    pop rdx
    lea rcx, [rip + ru_exe]
    mov byte ptr [rcx + rdx], 0
    # ru_exe is reused by remote_open: the path goes on the stack
    sub rsp, 4096
    mov rdi, rsp
    lea rsi, [rip + ru_exe]
    call cstr_copy
    lea rdi, [rip + ru_spec]
    mov rsi, rsp
    call remote_open
    add rsp, 4096
9:  EPILOGUE

# remote_menu_append(slot, items) -> the slot after: the project menu's remote items after its own
#   (a line, Connect to Host, Attach to Container, the recent remotes); items is the menu's start
FN remote_menu_append
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rax, [rip + .Lm_line]
    mov [rbx], rax
    mov qword ptr [rbx + 8], 0
    lea rax, [rip + .Lm_host]
    mov [rbx + 16], rax
    lea rax, [rip + cmd_connect_to_host]
    mov [rbx + 24], rax
    lea rax, [rip + .Lm_container]
    mov [rbx + 32], rax
    lea rax, [rip + cmd_attach_to_container]
    mov [rbx + 40], rax
    add rbx, 48
.ifdef WINDOWS
    lea rax, [rip + .Lm_wsl]
    mov [rbx], rax
    lea rax, [rip + cmd_connect_to_wsl]
    mov [rbx + 8], rax
    add rbx, 16
.endif
    mov rax, rbx
    sub rax, r12
    shr rax, 4
    mov [rip + ru_menu_base], eax
    call remote_recent_count
    mov r13d, eax
    cmp r13d, RU_RECENT_MAX
    jbe 1f
    mov r13d, RU_RECENT_MAX
1:  xor r14d, r14d
2:  cmp r14d, r13d
    jae 9f
    mov edi, r14d
    imul esi, r14d, 512
    lea rcx, [rip + ru_recent_labels]
    add rsi, rcx
    call remote_recent_label
    mov [rbx], rax
    lea rax, [rip + ru_recent_pick]
    mov [rbx + 8], rax
    add rbx, 16
    inc r14d
    jmp 2b
9:  mov rax, rbx
    EPILOGUE

# ru_recent_pick(): a recent remote picked in the project menu
ru_recent_pick:
    mov edi, [rip + g_menu_index]
    sub edi, [rip + ru_menu_base]
    js 1f
    jmp remote_recent_open
1:  ret

# ---------------- a password's field ----------------

# remote_field_for_draw(rdi field) -> rdi the field to draw: for a password prompt a copy with a *
#   for each character, the cursor and selection where they are in the text. Keeps every other
#   register (palette_draw is between arguments)
FN remote_field_for_draw
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    call palette_remote_field
    cmp rax, rbx
    jne 9f
    cmp edx, 6                  # PM_PROMPT
    jne 9f
    cmp ecx, PROMPT_REMOTE_SECRET
    jne 9f
    # the copy: same id and state, its own text
    lea rdi, [rip + ru_mask]
    mov r12, [rdi + TF_sb + SB_ptr]
    mov rax, [rdi + TF_sb + SB_cap]
    push rax
    push r12
    lea rdi, [rip + ru_mask]
    mov rsi, rbx
    mov edx, TF_SIZE
    call memcpy
    pop r12
    pop rax
    lea rdi, [rip + ru_mask]
    mov [rdi + TF_sb + SB_ptr], r12
    mov [rdi + TF_sb + SB_cap], rax
    mov qword ptr [rdi + TF_sb + SB_len], 0
    mov rdi, rbx
    mov rsi, [rbx + TF_cur]
    call ru_chars_before
    mov [rip + ru_mask + TF_cur], rax
    mov rdi, rbx
    mov rsi, [rbx + TF_anchor]
    call ru_chars_before
    mov [rip + ru_mask + TF_anchor], rax
    mov rdi, rbx
    mov rsi, [rbx + TF_sb + SB_len]
    call ru_chars_before
    mov r12, rax
1:  test r12, r12
    jz 2f
    lea rdi, [rip + ru_mask + TF_sb]
    mov esi, '*'
    call sb_push_byte
    dec r12
    jmp 1b
2:  lea rbx, [rip + ru_mask]
9:  mov rdi, rbx
    add rsp, 8
    pop r12
    pop rbx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

# ru_chars_before(field, offset) -> characters (UTF-8 lead bytes) before offset
ru_chars_before:
    mov rdx, [rdi + TF_sb + SB_ptr]
    xor eax, eax
    test rdx, rdx
    jz 9f
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 9f
    movzx r8d, byte ptr [rdx + rcx]
    and r8d, 0xc0
    cmp r8d, 0x80
    je 2f
    inc rax
2:  inc rcx
    jmp 1b
9:  ret

# ---------------- askpass ----------------

# remote_askpass_env() -> extra environment entries for the transport (0-terminated list): ssh runs
#   this program as its askpass, which asks this window through a socket in a private folder
FN remote_askpass_env
    PROLOGUE
    lea rax, [rip + ru_ap_env]
    mov qword ptr [rax], 0
    call ru_ap_listen_start
    test eax, eax
    jz 9f
    call ru_exe_path
    test eax, eax
    jz 9f
    lea rdi, [rip + ru_ap_env_prog]
    lea rsi, [rip + .Le_askpass]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + ru_exe]
    call cstr_copy
    lea rdi, [rip + ru_ap_env_sock]
    lea rsi, [rip + .Le_rhun_askpass]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + ru_ap_path]
    call cstr_copy
    lea rbx, [rip + ru_ap_env]
    lea rax, [rip + ru_ap_env_prog]
    mov [rbx], rax
    lea rax, [rip + .Le_require]
    mov [rbx + 8], rax
    lea rax, [rip + ru_ap_env_sock]
    mov [rbx + 16], rax
    mov qword ptr [rbx + 24], 0
.ifndef WINDOWS
    # older ssh wants a display before it uses askpass
    lea rdi, [rip + .Le_display]
    call getenv
    test rax, rax
    jnz 9f
    lea rax, [rip + .Le_display_set]
    mov [rbx + 24], rax
    mov qword ptr [rbx + 32], 0
.endif
9:  lea rax, [rip + ru_ap_env]
    EPILOGUE

# ru_ap_drop(): the askpass connection ends without an answer
ru_ap_drop:
    sub rsp, 8
    mov edi, [rip + ru_ap_conn]
    test edi, edi
    js 1f
    call watch_remove
    mov edi, [rip + ru_ap_conn]
    SYS SYS_close
    mov dword ptr [rip + ru_ap_conn], -1
1:  add rsp, 8
    ret

.ifdef WINDOWS
# ru_ap_listen_start() -> 1 when the askpass pipe waits: \\.\pipe\rhun-askpass-PID-RANDOM, made
#   new by this window with only its user allowed (askpipe.s); remote_tick looks for its client
ru_ap_listen_start:
    PROLOGUE
    cmp dword ptr [rip + ru_ap_listen], 0
    jge 7f
    lea rdi, [rip + ru_ap_path]
    lea rsi, [rip + .Lap_pipe]
    call cstr_copy
    mov rbx, rax
    SYS SYS_getpid
    mov rdi, rbx
    mov rsi, rax
    call fmt_u64
    mov byte ptr [rdi], '-'
    inc rdi
    mov rbx, rdi
    call time_us
    mov r12, 0x9e3779b97f4a7c15
    imul rax, r12
    mov rdi, rbx
    mov rsi, rax
    call fmt_hex
    mov byte ptr [rbx + rax], 0
    lea rdi, [rip + ru_ap_path]
    mov esi, 1                  # a new name
    call win_pipe_server
    test rax, rax
    js 8f
    mov [rip + ru_ap_listen], eax
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# remote_askpass_poll(): Windows: ssh's askpass program connected to the waiting instance: it is
#   read as on the other systems, and the next instance waits
FN remote_askpass_poll
    PROLOGUE
    cmp dword ptr [rip + ru_ap_conn], 0
    jge 9f                      # one question at a time
    mov edi, [rip + ru_ap_listen]
    test edi, edi
    js 9f
    call win_pipe_accept
    test rax, rax
    jz 9f
    js 7f
    mov eax, [rip + ru_ap_listen]
    mov [rip + ru_ap_conn], eax
    lea rdi, [rip + ru_ap_path]
    xor esi, esi                # another instance of this window's pipe
    call win_pipe_server
    test rax, rax
    jns 1f
    mov eax, -1
1:  mov [rip + ru_ap_listen], eax
    lea rdi, [rip + ru_ap_in]
    call sb_clear
    mov edi, [rip + ru_ap_conn]
    mov esi, POLLIN
    lea rdx, [rip + ru_ap_on_conn]
    xor ecx, ecx
    call watch_add
    jmp 9f
7:  # it came and went: a fresh instance
    mov edi, [rip + ru_ap_listen]
    SYS SYS_close
    lea rdi, [rip + ru_ap_path]
    xor esi, esi
    call win_pipe_server
    test rax, rax
    jns 8f
    mov eax, -1
8:  mov [rip + ru_ap_listen], eax
9:  EPILOGUE
.else
# ru_ap_listen_start() -> 1 when the askpass socket listens: /tmp/rhun-askpass-PID-N/s, a folder
#   this window just made (0700), so only the user reaches it
ru_ap_listen_start:
    PROLOGUE 128
    cmp dword ptr [rip + ru_ap_listen], 0
    jge 7f
    xor r12d, r12d              # tries
1:  inc r12d
    cmp r12d, 20
    ja 8f
    lea rdi, [rip + ru_ap_dir]
    lea rsi, [rip + .Lap_dir]
    call cstr_copy
    mov rbx, rax
    SYS SYS_getpid
    mov rdi, rbx
    mov rsi, rax
    call fmt_u64
    mov byte ptr [rdi], '-'
    lea rbx, [rdi + 1]
    call time_us
    xor edx, edx
    mov ecx, 1000000
    div rcx
    mov rdi, rbx
    mov rsi, rdx
    call fmt_u64
    mov byte ptr [rdi], 0
    lea rdi, [rip + ru_ap_dir]
    mov esi, 0700
    SYS SYS_mkdir
    cmp rax, -17                # EEXIST: another name
    je 1b
    test rax, rax
    js 8f
    lea rdi, [rip + ru_ap_path]
    lea rsi, [rip + ru_ap_dir]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Lap_sock]
    call cstr_copy
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js 8f
    mov ebx, eax
    lea rdi, [rsp]
    xor esi, esi
    mov edx, 110
    call memset
    mov word ptr [rsp], AF_UNIX
    lea rdi, [rsp + 2]
    lea rsi, [rip + ru_ap_path]
    call cstr_copy
    mov edi, ebx
    lea rsi, [rsp]
    mov edx, 110
    SYS SYS_bind
    test rax, rax
    js 6f
    mov edi, ebx
    mov esi, 4
    SYS SYS_listen
    test rax, rax
    js 6f
    mov [rip + ru_ap_listen], ebx
    mov edi, ebx
    mov esi, POLLIN
    lea rdx, [rip + ru_ap_on_listen]
    xor ecx, ecx
    call watch_add
7:  mov eax, 1
    EPILOGUE
6:  mov edi, ebx
    SYS SYS_close
8:  xor eax, eax
    EPILOGUE

# ru_ap_on_listen(fd, revents, ctx): ssh's askpass program connects; one question at a time
ru_ap_on_listen:
    PROLOGUE
    mov edi, [rip + ru_ap_listen]
    xor esi, esi
    xor edx, edx
    mov r10d, SOCK_NONBLOCK | SOCK_CLOEXEC
    SYS SYS_accept4
    test rax, rax
    js 9f
    cmp dword ptr [rip + ru_ap_conn], 0
    jl 1f
    mov edi, eax                # one is being asked already: this one gets no answer
    SYS SYS_close
    jmp 9f
1:  mov [rip + ru_ap_conn], eax
    lea rdi, [rip + ru_ap_in]
    call sb_clear
    mov edi, [rip + ru_ap_conn]
    mov esi, POLLIN
    lea rdx, [rip + ru_ap_on_conn]
    xor ecx, ecx
    call watch_add
9:  EPILOGUE
.endif

# ru_ap_on_conn(fd, revents, ctx): the question, up to the program's end of writing or a NUL (a
#   named pipe has no half close); then it is asked
ru_ap_on_conn:
    PROLOGUE
1:  lea rdi, [rip + ru_ap_in]
    mov esi, 4096
    call sb_reserve
    mov rsi, rax
    mov edi, [rip + ru_ap_conn]
    mov edx, 4096
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    js 8f
    jz 2f
    # a NUL ends it too
    mov rdi, [rip + ru_ap_in + SB_ptr]
    add rdi, [rip + ru_ap_in + SB_len]
    xor ecx, ecx
3:  cmp rcx, rax
    jae 4f
    cmp byte ptr [rdi + rcx], 0
    je 5f
    inc rcx
    jmp 3b
5:  add [rip + ru_ap_in + SB_len], rcx
    jmp 2f
4:  add [rip + ru_ap_in + SB_len], rax
    cmp qword ptr [rip + ru_ap_in + SB_len], RU_ASK_MAX
    jb 1b
    jmp 8f
2:  # the whole question: no more reading, ask
    mov edi, [rip + ru_ap_conn]
    call watch_remove
    call ru_ap_ask
    jmp 9f
8:  call ru_ap_drop
9:  EPILOGUE

# ru_ap_ask(): the question in a prompt: yes/no as a pick list, a password masked, anything else plain
ru_ap_ask:
    PROLOGUE
    # one line for the label: line breaks become blanks, at most 400 bytes
    mov rbx, [rip + ru_ap_in + SB_ptr]
    mov r12, [rip + ru_ap_in + SB_len]
    mov rdi, rbx
    mov rsi, r12
    call trim
    mov rbx, rax
    mov r12, rdx
    cmp r12, 400
    jbe 1f
    lea rbx, [rbx + r12 - 400]  # the end says what is asked
    mov r12d, 400
1:  lea rdi, [rip + ru_ap_label]
    xor ecx, ecx
2:  cmp rcx, r12
    jae 3f
    mov al, [rbx + rcx]
    cmp al, 10
    je 21f
    cmp al, 13
    jne 22f
21: mov al, ' '
22: mov [rdi + rcx], al
    inc rcx
    jmp 2b
3:  mov byte ptr [rdi + rcx], 0
    mov r13, rcx
    # which kind
    lea rdi, [rip + ru_ap_label]
    mov rsi, r13
    lea rdx, [rip + .Lw_yesno]
    mov ecx, 6
    call str_find
    test rax, rax
    js 4f
    lea rdi, [rip + ru_ap_label]
    call palette_remote_open
    lea rdi, [rip + .Lyes_item]
    mov esi, 3
    mov edx, 1
    call palette_choose_add
    lea rdi, [rip + .Lno_item]
    mov esi, 2
    xor edx, edx
    call palette_choose_add
    call palette_choose_ready
    mov dword ptr [rip + ru_pick], RP_YESNO
    jmp 9f
4:  mov r14d, PROMPT_REMOTE
    lea rdi, [rip + ru_ap_label]
    mov rsi, r13
    lea rdx, [rip + .Lw_assword]
    mov ecx, 7
    call str_ifind
    test rax, rax
    jns 5f
    lea rdi, [rip + ru_ap_label]
    mov rsi, r13
    lea rdx, [rip + .Lw_assphrase]
    mov ecx, 10
    call str_ifind
    test rax, rax
    jns 5f
    lea rdi, [rip + ru_ap_label]
    mov rsi, r13
    lea rdx, [rip + .Lw_pin]
    mov ecx, 3
    call str_find
    test rax, rax
    js 6f
5:  mov r14d, PROMPT_REMOTE_SECRET
6:  lea rdi, [rip + ru_ap_label]
    mov esi, r14d
    xor edx, edx
    xor ecx, ecx
    call palette_ext_prompt_open
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# remote_ui_prompt_done(text, len, kind): ssh's question answered in a prompt (or the port to forward)
FN remote_ui_prompt_done
    cmp dword ptr [rip + ru_fw_prompt], 0
    je ru_ap_answer
    mov dword ptr [rip + ru_fw_prompt], 0
    jmp ru_fw_answer

# ru_ap_answer(text, len): "y" and the answer to the askpass program, which prints it for ssh
ru_ap_answer:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov ebx, [rip + ru_ap_conn]
    test ebx, ebx
    js 9f
    # its own buffer: the answer given may be in ru_sb (the yes/no list's)
    lea rdi, [rip + ru_ap_out]
    call sb_clear
    lea rdi, [rip + ru_ap_out]
    mov esi, 'y'
    call sb_push_byte
    lea rdi, [rip + ru_ap_out]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    # small and the program waits for it: blocking is fine
    mov edi, ebx
    mov esi, F_SETFL
    xor edx, edx
    SYS SYS_fcntl
    mov edi, ebx
    mov rsi, [rip + ru_ap_out + SB_ptr]
    mov rdx, [rip + ru_ap_out + SB_len]
    call write_all
.ifdef WINDOWS
    mov edi, ebx                # a pipe's close drops what its client has not read yet
    SYS SYS_fsync
.endif
    # the answer does not stay in memory
    mov rdi, [rip + ru_ap_out + SB_ptr]
    xor esi, esi
    mov rdx, [rip + ru_ap_out + SB_len]
    call memset
    call ru_ap_drop
9:  EPILOGUE

# remote_ui_cancel(): a remote pick list or question closed unanswered: ssh is told no
FN remote_ui_cancel
    sub rsp, 8
    mov dword ptr [rip + ru_pick], 0
    mov dword ptr [rip + ru_fw_prompt], 0
    mov edi, [rip + ru_ap_conn]
    test edi, edi
    js 1f
    mov esi, F_SETFL
    xor edx, edx
    SYS SYS_fcntl
    mov edi, [rip + ru_ap_conn]
    lea rsi, [rip + .Ln_answer]
    mov edx, 1
    call write_all
.ifdef WINDOWS
    mov edi, [rip + ru_ap_conn]
    SYS SYS_fsync
.endif
    call ru_ap_drop
1:  add rsp, 8
    ret

# remote_shutdown(): the askpass socket and its folder go
FN remote_shutdown
    sub rsp, 8
    call remote_quit            # the session on the host ends with the window (remote.s)
    cmp dword ptr [rip + ru_ap_listen], 0
    jl 1f
    mov edi, [rip + ru_ap_listen]
    SYS SYS_close
    mov dword ptr [rip + ru_ap_listen], -1
.ifndef WINDOWS
    lea rdi, [rip + ru_ap_path]
    SYS SYS_unlink
    lea rdi, [rip + ru_ap_dir]
    mov eax, 84                 # rmdir
    XSYS
.endif
1:  add rsp, 8
    ret

# remote_askpass_main(prompt): `rhun` run by ssh as SSH_ASKPASS with RHUN_ASKPASS naming the window's
#   socket: the question goes to the window, its answer to standard output; exits 0, or 1 when the
#   user cancelled or the window is gone
FN remote_askpass_main
.ifdef WINDOWS
    # the window's pipe (RHUN_ASKPASS): the question and a NUL, then its answer until it closes
    PROLOGUE 16
    mov r12, rdi
    lea rdi, [rip + .Lenv_rhun_askpass]
    call getenv
    test rax, rax
    jz 8f
    mov rdi, rax
    call win_pipe_open
    test rax, rax
    js 8f
    mov ebx, eax
    test r12, r12
    jz 1f
    mov rdi, r12
    call strlen
    mov edi, ebx
    mov rsi, r12
    mov rdx, rax
    call write_all
1:  mov edi, ebx
    lea rsi, [rip + .Lnul]
    mov edx, 1
    call write_all
    jmp .Lap_read
.else
    PROLOGUE 256
    mov r12, rdi
    lea rdi, [rip + .Lenv_rhun_askpass]
    call getenv
    test rax, rax
    jz 8f
    mov r13, rax
    mov rdi, rax
    call strlen
    cmp rax, 100
    jae 8f
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js 8f
    mov ebx, eax
    lea rdi, [rsp]
    xor esi, esi
    mov edx, 110
    call memset
    mov word ptr [rsp], AF_UNIX
    lea rdi, [rsp + 2]
    mov rsi, r13
    call cstr_copy
    mov edi, ebx
    lea rsi, [rsp]
    mov edx, 110
    SYS SYS_connect
    test rax, rax
    js 8f
    test r12, r12
    jz 1f
    mov rdi, r12
    call strlen
    mov edi, ebx
    mov rsi, r12
    mov rdx, rax
    call write_all
1:  mov edi, ebx
    mov esi, 1                  # SHUT_WR: the question is complete
    SYS SYS_shutdown
.endif
.Lap_read:
    lea rdi, [rip + ru_ap_in]
    call sb_clear
2:  lea rdi, [rip + ru_ap_in]
    mov esi, 4096
    call sb_reserve
    mov rsi, rax
    mov edi, ebx
    mov edx, 4096
    SYS SYS_read
    cmp rax, -EINTR
    je 2b
    test rax, rax
    jle 3f
    add [rip + ru_ap_in + SB_len], rax
    cmp qword ptr [rip + ru_ap_in + SB_len], RU_ASK_MAX
    jb 2b
3:  mov rsi, [rip + ru_ap_in + SB_ptr]
    test rsi, rsi
    jz 8f
    cmp qword ptr [rip + ru_ap_in + SB_len], 0
    je 8f
    cmp byte ptr [rsi], 'y'
    jne 8f
    inc rsi
    mov rdx, [rip + ru_ap_in + SB_len]
    dec rdx
    mov edi, 1
    call write_all
    mov edi, 1
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
    xor edi, edi
    call sys_exit
8:  mov edi, 1
    call sys_exit

.section .rodata
.p2align 3
.Lkinds:
    .quad .Lk_ssh, .Ln_ssh, .Lk_docker, .Ln_docker, .Lk_podman, .Ln_podman, .Lk_wsl, .Ln_wsl
    .quad .Lk_local, .Ln_local, 0, 0
.Lk_ssh: .asciz "ssh"
.Lk_docker: .asciz "docker"
.Lk_podman: .asciz "podman"
.Lk_wsl: .asciz "wsl"
.Lk_local: .asciz "local"
.Ln_ssh: .asciz "SSH"
.Ln_docker: .asciz "Docker"
.Ln_podman: .asciz "Podman"
.Ln_wsl: .asciz "WSL"
.Ln_local: .asciz "Local"
.Lv_info: .asciz "info"
.Lnl: .ascii "\n"
.Lsp: .ascii " "
.Lcolon: .ascii ":"
.Lk_home: .ascii "home="
.Lk_shell: .ascii "shell="
.Lk_cdir: .ascii "claude_config_dir="
.Lroot: .asciz "/"
.Llocal_name: .asciz "local"
.Lcolon_sp: .asciz ": "
.Lellipsis: .asciz "\xe2\x80\xa6"
.Lellipsis_sp: .asciz "\xe2\x80\xa6 "
.Lb_download: .asciz "Downloading rhun "
.Lb_download2: .asciz " for Linux\xe2\x80\xa6"
.Lb_connect: .asciz "Connecting to "
.Lb_start: .asciz "Starting rhun on "
.Lb_upload: .asciz "Uploading rhun "
.Lb_upload2: .asciz " to "
.Lb_reconnect: .asciz "Reconnect"
.Lb_retry: .asciz "Retry"
.Lm_disconnect: .asciz "Disconnect"
.Lm_reconnect: .asciz "Reconnect"
.Lm_log: .asciz "Show Remote Log"
.Lm_forward: .asciz "Forward a Port..."
.Lm_unforward: .asciz "Stop Forwarding Ports"
.Lfw_label: .asciz "Port on the host to forward"
.Lfw_down: .asciz "Not connected to the host"
.Lfw_stopped: .asciz "Forwarded ports stopped"
.Lfw_bad: .asciz "Not a port number"
.Lfw_failed: .asciz "That port could not be forwarded"
.Lfw_ok1: .asciz "localhost:"
.Lfw_ok2: .asciz " reaches port "
.Lfw_ok3: .asciz " on "
.Lm_line: .asciz "-"
.Lm_host: .asciz "Connect to Host\xe2\x80\xa6"
.Lm_container: .asciz "Attach to Container\xe2\x80\xa6"
.Lp_host: .asciz "Connect to host: a name from ~/.ssh/config, or user@host"
.Lp_container: .asciz "Attach to container"
.Lno_log: .asciz "No remote log yet"
.Lsave_later: .asciz "Not connected: saved when "
.Lsave_later2: .asciz " is back"
.Lno_docker: .asciz "Neither docker nor podman was found"
.Lno_wsl: .asciz "WSL was not found"
.Lwsl: .asciz "wsl.exe"
.Ls_wsl: .asciz "wsl:"
.Ldash_l: .asciz "-l"
.Ldash_q: .asciz "-q"
.Lm_wsl: .asciz "Connect to WSL\xe2\x80\xa6"
.Lno_containers: .asciz "No running containers"
.Lno_window: .asciz "Could not open a new window"
.Lhome: .asciz "HOME"
.Lssh_config: .asciz ".ssh/config"
.Ls_ssh: .asciz "ssh:"
.Ls_docker: .asciz "docker:"
.Ls_podman: .asciz "podman:"
.Ldocker: .asciz "docker"
.Lpodman: .asciz "podman"
.Lps: .asciz "ps"
.Lformat: .asciz "--format"
.Lformat_names: .asciz "{{.Names}}"
.Lo_remote: .asciz "--remote"
.Ldevnull: .asciz "/dev/null"
.Lenv_new_window: .asciz "RHUN_NEW_WINDOW"
.Lproc_self: .asciz "/proc/self/exe"
.Ldeleted: .ascii " (deleted)"
.Lremotes_file: .asciz "/remotes"
.Lyes: .asciz "yes"
.Lno: .asciz "no"
.Lyes_item: .ascii "Yes"
.Lno_item: .ascii "No"
.Ln_answer: .ascii "n"
.Lw_yesno: .ascii "yes/no"
.Lw_assword: .ascii "assword"
.Lw_assphrase: .ascii "passphrase"
.Lw_pin: .ascii "PIN"
.Le_askpass: .asciz "SSH_ASKPASS="
.Le_require: .asciz "SSH_ASKPASS_REQUIRE=force"
.Le_rhun_askpass: .asciz "RHUN_ASKPASS="
.Le_display: .asciz "DISPLAY"
.Le_display_set: .asciz "DISPLAY=rhun"
.Lenv_rhun_askpass: .asciz "RHUN_ASKPASS"
.Lap_dir: .asciz "/tmp/rhun-askpass-"
.Lap_pipe: .asciz "\\\\.\\pipe\\rhun-askpass-"
.Lnul: .byte 0
.Lap_sock: .asciz "/s"
.text
