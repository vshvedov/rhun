# remembers the open files of a project (~/.local/state/rhun/<project path>.session)
.include "rhun.inc"

.equ RECENT_MAX, 9

.bss
.p2align 3
path_sb: .zero SB_SIZE
out: .zero SB_SIZE
rc_dir: .zero SB_SIZE
trust_sb: .zero SB_SIZE
last_path: .zero SB_SIZE
last_project: .zero 4096
recent_time: .zero 8 * RECENT_MAX     # when each was written, in nanoseconds
recent_n: .long 0
rc_path: .zero 4096
.globl g_session_final
g_session_final: .long 0        # saved for quitting: later saves would miss the files asked about
.globl g_recent_path, g_recent_label
g_recent_path: .zero 4096 * RECENT_MAX
g_recent_label: .zero 4096 * RECENT_MAX

.text

# state_dir(sb) -> 1 with "$XDG_STATE_HOME/rhun" (or "$HOME/.local/state/rhun") in sb, created;
# 0 without a home
FN session_state_dir
state_dir:
    PROLOGUE
    mov rbx, rdi
    call sb_clear
    lea rdi, [rip + .Lstate]
    call getenv
    test rax, rax
    jz 1f
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    jmp 2f
1:  lea rdi, [rip + .Lhome]
    call getenv
    test rax, rax
    jz 8f
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Llocal_state]
    call sb_push_cstr
2:  mov rdi, rbx
    lea rsi, [rip + .Lrhun_dir]
    call sb_push_cstr
    mov rdi, [rbx + SB_ptr]
    call mkdir_p
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# Keep the last opened project independently of the restore-open-files preference.
last_project_file:
    push rbx
    lea rdi, [rip + last_path]
    call state_dir
    test eax, eax
    jz 1f
    lea rdi, [rip + last_path]
    lea rsi, [rip + .Llast_project]
    call sb_push_cstr
    mov rax, [rip + last_path + SB_ptr]
1:  pop rbx
    ret

# trusted_file() -> cstr "$XDG_STATE_HOME/rhun/trusted-folders" (in trust_sb), or 0 without a home
trusted_file:
    push rbx
    lea rdi, [rip + trust_sb]
    call state_dir
    test eax, eax
    jz 1f
    lea rdi, [rip + trust_sb]
    lea rsi, [rip + .Ltrusted]
    call sb_push_cstr
    mov rax, [rip + trust_sb + SB_ptr]
    pop rbx
    ret
1:  xor eax, eax
    pop rbx
    ret

# session_trusted(folder) -> eax 1 when the folder is in the trusted-folders list (one path a line):
#   git runs there for a folder a rhun:// link opened
FN session_trusted
    PROLOGUE
    mov r12, rdi
    call trusted_file
    test rax, rax
    jz 8f
    mov rdi, rax
    call file_read_all
    test rax, rax
    jz 8f
    mov rbx, rax
    lea r13, [rax + rdx]        # the end
    mov rdi, r12
    call strlen
    mov r14, rax
    mov r15, rbx                # a line
1:  cmp r15, r13
    jae 7f
    mov rcx, r15
2:  cmp rcx, r13
    jae 3f
    cmp byte ptr [rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  mov rax, rcx
    sub rax, r15
    cmp rax, r14
    jne 4f
    push rcx
    push rcx
    mov rdi, r15
    mov rsi, r12
    mov rdx, r14
    call memeq
    pop rcx
    pop rcx
    test eax, eax
    jnz 6f
4:  lea r15, [rcx + 1]
    jmp 1b
6:  mov rdi, rbx
    call mem_free
    mov eax, 1
    EPILOGUE
7:  mov rdi, rbx
    call mem_free
8:  xor eax, eax
    EPILOGUE

# session_trust(folder): add the folder to the trusted-folders list (not one whose path holds a line
#   break, which the list cannot hold: it is trusted for this run only)
FN session_trust
    PROLOGUE
    mov r12, rdi
    mov rcx, rdi
0:  movzx eax, byte ptr [rcx]
    test eax, eax
    jz 12f
    cmp eax, 10
    je 9f
    cmp eax, 13
    je 9f
    inc rcx
    jmp 0b
12: mov rdi, r12
    call session_trusted
    test eax, eax
    jnz 9f
    call trusted_file
    test rax, rax
    jz 9f
    mov r13, rax
    lea rdi, [rip + out]
    call sb_clear
    mov rdi, r13
    call file_read_all
    test rax, rax
    jz 1f
    mov rbx, rax
    mov r14, rdx
    lea rdi, [rip + out]
    mov rsi, rax
    call sb_push
    # a list whose last line has no line break of its own gets one first
    test r14, r14
    jz 11f
    cmp byte ptr [rbx + r14 - 1], 10
    je 11f
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
11: mov rdi, rbx
    call mem_free
1:  lea rdi, [rip + out]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, r13
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    call file_write_all
9:  EPILOGUE

FN session_remember_project
    PROLOGUE
    mov rbx, [rip + g_project]
    test rbx, rbx
    jz 9f
    cmp dword ptr [rip + g_remote], 0     # remote hosts: a remote folder is a recent remote instead
    jne 9f
    cmp dword ptr [rip + g_project_adopted], 0
    jne 9f
    # nor one a link opened, while git is paused there: a launch without arguments would reopen it
    # as a folder opened by hand, and git would run in it without the trust asked for
    cmp dword ptr [rip + g_git_paused], 0
    jne 9f
    call last_project_file
    test rax, rax
    jz 9f
    mov r12, rax
    # written only when it names another folder: a relaunch into the same project read it, and the
    # write (a new file, synced and renamed in place) cost half a millisecond at startup and exit
    mov rdi, rax
    call file_read_all
    test rax, rax
    jz 1f
    mov r13, rax
    mov r14, rdx
    mov rdi, rbx
    call strlen
    xor r15d, r15d
    cmp rax, r14
    jne 2f
    mov rdi, r13
    mov rsi, rbx
    mov rdx, rax
    call memeq
    mov r15d, eax
2:  mov rdi, r13
    call mem_free
    test r15d, r15d
    jnz 9f
1:  mov rdi, rbx
    call strlen
    mov rdx, rax
    mov rsi, rbx
    mov rdi, r12
    call file_write_all
9:  EPILOGUE

# session_last_project() -> existing directory in a static buffer, or 0.
FN session_last_project
    PROLOGUE
    call last_project_file
    test rax, rax
    jz 9f
    mov rdi, rax
    call file_read_all
    test rax, rax
    jz 9f
    mov rbx, rax
    test rdx, rdx
    jz 8f
    cmp rdx, 4095
    ja 8f
    lea rdi, [rip + last_project]
    mov byte ptr [rdi + rdx], 0
    mov rsi, rbx
    call memcpy
    mov rdi, rbx
    call mem_free
    lea rdi, [rip + last_project]
    call file_is_dir
    test eax, eax
    jz 9f
    lea rax, [rip + last_project]
    EPILOGUE
8:  mov rdi, rbx
    call mem_free
9:  xor eax, eax
    EPILOGUE

# session_file() -> cstr path for the current project, or 0. The name is the project's path with
# every / as % and every % as %%25: never %% otherwise, as a path has no //, so no two folders share
# a name, and a path without % keeps the name it always had
session_file:
    lea rdi, [rip + .Lext]
# session_project_file(suffix cstr) -> the state file for the current project with that suffix (a
#   static buffer), or 0: the debugger keeps PROJECT.debug next to PROJECT.session
FN session_project_file
    PROLOGUE
    mov r13, rdi
    lea rdi, [rip + path_sb]
    call sb_clear
    mov rbx, [rip + g_project]
    test rbx, rbx
    jz 8f
    lea rdi, [rip + path_sb]
    call state_dir
    test eax, eax
    jz 8f
    lea rdi, [rip + path_sb]
    mov esi, '/'
    call sb_push_byte
    # remote hosts: a remote window's files are named by the remote and the folder (ssh:HOST/path)
    cmp dword ptr [rip + g_remote], 0
    je 3f
    mov rdi, rbx
    call remote_session_key
    mov rbx, rax
3:  movzx esi, byte ptr [rbx]
.ifdef WINDOWS
    test esi, esi
    jz 4f
    cmp esi, 32
    jb 35f
    cmp esi, '%'
    je 35f
    cmp esi, ':'
    je 35f
    cmp esi, '/'
    je 35f
    cmp esi, 92
    je 35f
    cmp esi, '<'
    je 35f
    cmp esi, '>'
    je 35f
    cmp esi, '"'
    je 35f
    cmp esi, '|'
    je 35f
    cmp esi, '?'
    je 35f
    cmp esi, '*'
    jne 31f
35: mov r12d, esi
    lea rdi, [rip + path_sb]
    mov esi, '%'
    call sb_push_byte
    mov esi, r12d
    shr esi, 4
    lea rax, [rip + .Lwin_hex]
    movzx esi, byte ptr [rax + rsi]
    lea rdi, [rip + path_sb]
    call sb_push_byte
    and r12d, 15
    lea rax, [rip + .Lwin_hex]
    movzx esi, byte ptr [rax + r12]
    jmp 31f
.endif
    test esi, esi
    jz 4f
    cmp esi, '%'
    je 32f
    cmp esi, '/'
    jne 31f
    mov esi, '%'
31: lea rdi, [rip + path_sb]
    call sb_push_byte
    inc rbx
    jmp 3b
32: lea rdi, [rip + path_sb]
    lea rsi, [rip + .Lpercent]
    call sb_push_cstr
    inc rbx
    jmp 3b
4:
.ifdef WINDOWS
    mov rdi, [rip + path_sb + SB_ptr]
    mov rsi, [rip + path_sb + SB_len]
    call path_basename
    cmp rdx, 240
    jbe 41f
    lea rdi, [rip + .Lwin_long_session]
    call app_toast
    jmp 8f
41:
.endif
    lea rdi, [rip + path_sb]
    mov rsi, r13
    call sb_push_cstr
    lea rdi, [rip + path_sb]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rip + path_sb + SB_len]
    mov rax, [rip + path_sb + SB_ptr]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# session_recent() -> count: the folders of the latest sessions into g_recent_path, newest first,
# and as shown (the home folder as ~) into g_recent_label. The open project and folders that are
# gone are left out.
FN session_recent
    PROLOGUE
    mov dword ptr [rip + recent_n], 0
    lea rdi, [rip + rc_dir]
    call state_dir
    test eax, eax
    jz 9f
    mov rdi, [rip + rc_dir + SB_ptr]
    lea rsi, [rip + recent_cb]
    xor edx, edx
    call dir_each
    xor ebx, ebx
1:  cmp ebx, [rip + recent_n]
    jae 9f
    mov eax, ebx
    shl eax, 12
    lea rdi, [rip + g_recent_label]
    add rdi, rax
    lea rsi, [rip + g_recent_path]
    add rsi, rax
    call path_tilde
    inc ebx
    jmp 1b
9:  mov eax, [rip + recent_n]
    EPILOGUE

# recent_cb(ctx, name, is_dir): a session file ("%home%me%project.session") ranks its folder by
# when it was written, to the nanosecond: switching folders writes several within a second
recent_cb:
    PROLOGUE
    mov r12, rsi
    test edx, edx
    jnz 9f
    mov rdi, rsi
    call strlen
    mov r13, rax
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lext]
    mov ecx, 8
    call str_ends
    test eax, eax
    jz 9f
    sub r13, 8
    jz 9f
    cmp r13, 4000
    ja 9f
.ifdef WINDOWS
    lea rdi, [rip + rc_path]
    xor ecx, ecx
    xor edx, edx
1:  cmp rcx, r13
    jae 2f
    mov al, [r12 + rcx]
    inc rcx
    cmp al, '%'
    jne 11f
    lea r8, [rcx + 2]
    cmp r8, r13
    ja 9f
    movzx eax, byte ptr [r12 + rcx]
    call session_unhex
    cmp eax, 15
    ja 9f
    mov r8d, eax
    shl r8d, 4
    movzx eax, byte ptr [r12 + rcx + 1]
    call session_unhex
    cmp eax, 15
    ja 9f
    or eax, r8d
    test eax, eax
    jz 9f
    add rcx, 2
11: mov [rdi + rdx], al
    inc rdx
    jmp 1b
.else
    mov rbx, r12                # the whole name
    # remote hosts: a remote window lists its remote's folders (session files named SPEC%path)
    cmp dword ptr [rip + g_remote], 0
    je 12f
    mov rdi, r12
    mov rsi, r13
    call remote_session_prefix
    test rax, rax
    jz 9f
    add r12, rax
    sub r13, rax
12: cmp byte ptr [r12], '%'
    jne 9f
    # the folder: %%25 was a %, any other % a / (see session_file); ".session" ends a match
    lea rdi, [rip + rc_path]
    xor ecx, ecx
    xor edx, edx
1:  cmp rcx, r13
    jae 2f
    mov al, [r12 + rcx]
    inc rcx
    cmp al, '%'
    jne 11f
    mov al, '/'
    cmp byte ptr [r12 + rcx], '%'
    jne 11f
    cmp byte ptr [r12 + rcx + 1], '2'
    jne 11f
    cmp byte ptr [r12 + rcx + 2], '5'
    jne 11f
    mov al, '%'
    add rcx, 3
11: mov [rdi + rdx], al
    inc rdx
    jmp 1b
.endif
2:  mov byte ptr [rdi + rdx], 0
.ifdef WINDOWS
    # remote hosts: a remote window lists its remote's folders (decoded names are SPEC/path)
    cmp dword ptr [rip + g_remote], 0
    je 21f
    call remote_spec
    mov r14, rax
    mov rdi, rax
    call strlen
    mov r15, rax
    lea rdi, [rip + rc_path]
    mov rsi, r14
    mov rdx, r15
    call memeq
    test eax, eax
    jz 9f
    lea rdi, [rip + rc_path]
    cmp byte ptr [rdi + r15], '/'
    jne 9f
    lea rsi, [rdi + r15]
    call cstr_copy
21: lea rdi, [rip + rc_path]
.endif
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 3f
    call strcmp_eq
    test eax, eax
    jnz 9f
3:  lea rdi, [rip + rc_path]
    call vfs_is_dir             # the host's folder in a remote window
    test eax, eax
    jz 9f
    mov rdi, [rip + rc_dir + SB_ptr]
.ifdef WINDOWS
    mov rsi, r12
.else
    mov rsi, rbx
.endif
    call path_join_tmp
    mov rdi, rax
    call file_mtime_ns
    mov r14, rax
    # its place: before the first older one
    mov ebx, [rip + recent_n]
    xor r15d, r15d
4:  cmp r15d, ebx
    jae 5f
    lea rdx, [rip + recent_time]
    cmp r14, [rdx + r15*8]
    ja 5f
    inc r15d
    jmp 4b
5:  cmp r15d, RECENT_MAX
    jae 9f
    lea eax, [rbx + 1]
    cmp eax, RECENT_MAX
    jbe 6f
    mov eax, RECENT_MAX
6:  mov [rip + recent_n], eax
    # the later ones move down; past RECENT_MAX the oldest falls off
    lea r13d, [rax - 1]
7:  cmp r13d, r15d
    jbe 8f
    lea rdx, [rip + recent_time]
    mov rax, [rdx + r13*8 - 8]
    mov [rdx + r13*8], rax
    mov eax, r13d
    shl eax, 12
    lea rdi, [rip + g_recent_path]
    add rdi, rax
    lea rsi, [rdi - 4096]
    mov edx, 4096
    call memcpy
    dec r13d
    jmp 7b
8:  lea rdx, [rip + recent_time]
    mov [rdx + r15*8], r14
    mov eax, r15d
    shl eax, 12
    lea rdi, [rip + g_recent_path]
    add rdi, rax
    lea rsi, [rip + rc_path]
    call cstr_copy
9:  EPILOGUE

# session_save(): "path<TAB>cursor" per open file, "*" marks the active one and "<TAB>pin" ends the line
#   of a pinned one (older versions read the cursor and stop there)
FN session_save
    PROLOGUE
    cmp dword ptr [rip + cfg_restore_session], 0
    je 9f
    cmp dword ptr [rip + g_project_adopted], 0
    jne 9f
    # nor for a folder a link opened while git is paused there: its session would list it among
    # the recent folders, and opening it from there runs git as in a folder opened by hand
    cmp dword ptr [rip + g_git_paused], 0
    jne 9f
    cmp dword ptr [rip + g_session_final], 0
    jne 9f
    call session_file
    test rax, rax
    jz 9f
    mov r13, rax
    lea rdi, [rip + out]
    call sb_clear
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 3f
    mov rdi, rbx
    call tab_at
    mov r12, [rax + TAB_doc]
    test r12, r12
    jz 20f
    cmp qword ptr [r12 + DOC_path], 0
    je 2f
    cmp rbx, [rip + g_tab_cur]
    jne 11f
    lea rdi, [rip + out]
    mov esi, '*'
    call sb_push_byte
11: lea rdi, [rip + out]
    mov rsi, [r12 + DOC_path]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 9
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [r12 + DOC_cur]
    call sb_push_u64
    mov rdi, rbx
    call tab_pinned
    test eax, eax
    jz 12f
    lea rdi, [rip + out]
    lea rsi, [rip + .Lpin]
    call sb_push_cstr
12: mov rdi, r12                # "<TAB>folds=H-E,..." (fold.s)
    lea rsi, [rip + out]
    call fold_session_out
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    jmp 2f
20: mov rdi, rbx                # phase 4 task 13: a conversation tab, "<TAB>agent<TAB>KIND<TAB>FILE" (agenttab.s;
    call tab_at                 #   an older rhun reads an empty path and passes over it)
    mov rdi, rax
    call agtab_line
    test rax, rax
    jz 2f
    mov r14, rax
    cmp rbx, [rip + g_tab_cur]
    jne 21f
    lea rdi, [rip + out]
    mov esi, '*'
    call sb_push_byte
21: lea rdi, [rip + out]
    lea rsi, [rip + .Lagent_line]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, r14
    call sb_push_cstr
    mov rdi, r14
    call mem_free
    mov rdi, rbx
    call tab_pinned
    test eax, eax
    jz 22f
    lea rdi, [rip + out]
    lea rsi, [rip + .Lpin]
    call sb_push_cstr
22: lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
2:  inc rbx
    jmp 1b
3:  mov rdi, r13
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    test rsi, rsi
    jnz 4f
    lea rsi, [rip + .Lempty]
4:  call file_write_all
9:  EPILOGUE

# session_restore(): reopen the files of the last session of this project
FN session_restore
    PROLOGUE 32
    cmp dword ptr [rip + cfg_restore_session], 0
    je 9f
    call session_file
    test rax, rax
    jz 9f
    mov rdi, rax
    call file_read_all
    test rax, rax
    jz 9f
    mov r12, rax
    mov r13, rdx
    mov qword ptr [rsp], 0      # the active tab's document (pinning moves tabs)
    xor r14d, r14d
1:  cmp r14, r13
    jae 8f
    mov r15, r14
2:  cmp r15, r13
    jae 3f
    cmp byte ptr [r12 + r15], 10
    je 3f
    inc r15
    jmp 2b
3:  mov byte ptr [r12 + r15], 0
    lea rbx, [r12 + r14]
    xor ecx, ecx
    cmp byte ptr [rbx], '*'
    jne 4f
    inc rbx
    mov ecx, 1
4:  mov [rsp + 8], ecx
    cmp byte ptr [rbx], 9       # phase 4 task 13: a conversation tab's line (agenttab.s)
    jne 41f
    lea rdi, [rbx + 1]
    call strlen
    lea rdi, [rbx + 1]
    mov rsi, rax
    lea rdx, [rip + .Lagent_word]
    mov ecx, 6
    call str_starts
    test eax, eax
    jz 41f
    lea rdi, [rbx + 7]
    mov esi, [rsp + 8]
    call agtab_restore_line
    jmp 7f
41: # split at the tab
    mov rdi, rbx
5:  mov al, [rdi]
    test al, al
    jz 6f
    cmp al, 9
    je 6f
    inc rdi
    jmp 5b
6:  mov byte ptr [rdi], 0
    lea rsi, [rdi + 1]
    push rsi
    push rsi
    mov rdi, rbx
    call file_mtime
    pop rsi
    pop rsi
    test rax, rax
    jz 7f
    push rsi
    push rsi
    mov rdi, rbx
    call app_open_file
    pop rsi
    pop rsi
    test rax, rax
    js 7f
    mov [rsp + 16], rax
    mov [rsp + 24], rsi
    cmp dword ptr [rsp + 8], 0
    je 61f
    mov rdi, rax
    call tab_at
    mov rax, [rax + TAB_doc]
    mov [rsp], rax
61: mov rdi, [rsp + 24]
    call strlen
    mov rdi, [rsp + 24]
    mov rsi, rax
    call parse_u64
    # "<TAB>pin" after the cursor
    mov rcx, [rsp + 24]
    cmp byte ptr [rcx + rdx], 9
    jne 62f
    cmp byte ptr [rcx + rdx + 1], 'p'
    jne 62f
    push rax
    push rax
    mov rdi, [rsp + 32]
    mov esi, 1
    call app_pin_tab
    pop rax
    pop rax
62: mov rcx, [rip + g_doc]
    test rcx, rcx
    jz 7f                       # an image
    push rax
    mov rdi, rcx
    call doc_len
    pop rcx
    cmp rcx, rax
    cmova rcx, rax
    mov rax, [rip + g_doc]
    mov [rax + DOC_cur], rcx
    mov [rax + DOC_anchor], rcx
    or dword ptr [rax + DOC_flags], DF_REVEAL
    mov rdi, rax                # its folds (fold.s)
    mov rsi, [rsp + 24]
    call fold_session_in
7:  lea r14, [r15 + 1]
    jmp 1b
8:  mov rdi, r12
    call mem_free
    mov rdi, [rsp]              # phase 4 task 13: no file was active: the conversation tab that was
    call agtab_restored
    mov rdi, [rsp]
    test rdi, rdi
    jz 9f
    call doc_tab
    test rax, rax
    js 9f
    mov rdi, rax
    call app_activate_tab
9:  EPILOGUE

.section .rodata
.Lstate: .asciz "XDG_STATE_HOME"
.Lhome: .asciz "HOME"
.Llocal_state: .asciz "/.local/state"
.Lrhun_dir: .asciz "/rhun"
.Lext: .asciz ".session"
.Llast_project: .asciz "/last-project"
.Ltrusted: .asciz "/trusted-folders"
.Lpercent: .asciz "%%25"
.Lempty: .asciz ""
.Lpin: .asciz "\tpin"
.Lagent_line: .asciz "\tagent\t"     # phase 4 task 13
.Lagent_word: .asciz "agent\t"

.ifdef WINDOWS
.text
session_unhex:
    cmp al, '0'
    jb 9f
    cmp al, '9'
    jbe 1f
    or al, 32
    sub eax, 'a' - 10
    cmp eax, 10
    jb 9f
    ret
1:  sub eax, '0'
    ret
9:  mov eax, -1
    ret
CSTR .Lwin_hex, "0123456789ABCDEF"
CSTR .Lwin_long_session, "This project path is too long to save its session"
.endif
