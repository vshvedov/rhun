# installing an extension from GitHub, and removing one (Chrome's "Add extension" and "Remove").
# A background job (a fixed shell script, fed owner and name as arguments after rhun checked them)
# downloads the latest release's archive for this system and its sha256sums.txt, checks the
# checksum, refuses archives with links, devices or paths outside themselves, and unpacks into a
# fresh folder under the extensions folder. rhun then reads the manifest there and asks, showing
# what the extension can do; Add moves it into place and starts it, Cancel throws it away.
#   RHUN_EXT_BASE   another place than https://github.com for the releases (tests)
.include "rhun.inc"

.bss
.p2align 3
in_out: .zero SB_SIZE           # the job's output
in_sb: .zero SB_SIZE            # scratch: paths, the dialog's strings
in_owner: .zero 128
in_name: .zero 128
in_tmp: .zero 4096              # the job's folder (.install-XXXXXX)
in_title: .zero 256             # the dialog's question
in_text: .zero 1024             # its line
in_pid: .long 0
.ifdef WINDOWS
.p2align 3
ei_vars: .zero 5 * SB_SIZE      # the job's RHUN_EI_* variables
ei_envp: .quad 0
ei_shell: .quad 0
ei_argv: .zero 64
.endif
.globl g_ext_install_state
g_ext_install_state: .long 0    # 0 idle, 1 downloading, 2 asking, 3 done, 4 failed (tests wait on it)
.p2align 3
rm_ext: .quad 0                 # the extension Remove asks about
pv: .zero EXT_SIZE              # the manifest being offered: title, version, description, needs

.data
in_fd: .long -1

.text

# cmd_install_extension(): the palette asks for a repository name or GitHub URL
FN cmd_install_extension
    PROLOGUE
    lea rdi, [rip + .Lask]
    mov esi, PROMPT_EXT_INSTALL
    xor edx, edx
    xor ecx, ecx
    call palette_ext_prompt_open
    EPILOGUE

# ext_install_start(ptr, len): owner/name, github.com/owner/name or https://github.com/owner/name...
FN ext_install_start
    PROLOGUE 96
    mov r12, rdi
    mov r13, rsi
    cmp dword ptr [rip + g_ext_install_state], 1
    je .Lis_busy
    cmp dword ptr [rip + g_ext_install_state], 2
    je .Lis_busy
    # drop a URL's scheme and host
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lgh]
    mov ecx, 11
    call str_find
    test rax, rax
    js 1f
    lea r12, [r12 + rax + 11]
    sub r13, rax
    sub r13, 11
1:  # owner, then name, each [A-Za-z0-9._-], not starting with a dot
    lea rdi, [rip + in_owner]
    call take_part
    test eax, eax
    jz .Lis_bad
    cmp r13, 0
    je .Lis_bad
    cmp byte ptr [r12], '/'
    jne .Lis_bad
    inc r12
    dec r13
    lea rdi, [rip + in_name]
    call take_part
    test eax, eax
    jz .Lis_bad
    # the rest of a URL (/releases, .git) is ignored; a name ending in .git loses it
    lea rdi, [rip + in_name]
    call strlen
    cmp rax, 4
    jbe 2f
    lea rcx, [rip + in_name]
    cmp dword ptr [rcx + rax - 4], 0x7469672e   # ".git"
    jne 2f
    mov byte ptr [rcx + rax - 4], 0
2:
.ifdef WINDOWS
    call win_install_job        # rax argv, rdx envp
    test rax, rax
    jz .Lis_spawn
    mov rdi, rax
    mov rsi, rdx
    xor edx, edx
    call run_piped
    test rax, rax
    jle .Lis_spawn
    jmp 4f
.endif
    # argv: sh -c SCRIPT sh OWNER NAME TARGET ROOT BASE
    lea rax, [rip + .Lsh]
    mov [rsp], rax
    lea rax, [rip + .Ldash_c]
    mov [rsp + 8], rax
    lea rax, [rip + install_script]
    mov [rsp + 16], rax
    lea rax, [rip + .Lsh_name]
    mov [rsp + 24], rax
    lea rax, [rip + in_owner]
    mov [rsp + 32], rax
    lea rax, [rip + in_name]
    mov [rsp + 40], rax
    lea rax, [rip + ext_target]
    mov [rsp + 48], rax
    call ext_root_dir
    mov [rsp + 56], rax
    lea rdi, [rip + .Lenv_base]
    call getenv
    test rax, rax
    jnz 3f
    lea rax, [rip + .Lgithub]
3:  mov [rsp + 64], rax
    mov qword ptr [rsp + 72], 0
    mov rdi, rsp
    mov rsi, [rip + g_envp]
    xor edx, edx
    call run_piped
    test rax, rax
    jle .Lis_spawn
4:  mov [rip + in_pid], eax
    mov [rip + in_fd], edx
    lea rdi, [rip + in_out]
    call sb_clear
    mov edi, [rip + in_fd]
    mov esi, POLLIN
    lea rdx, [rip + on_install_job]
    xor ecx, ecx
    call watch_add
    mov dword ptr [rip + g_ext_install_state], 1
    lea rdi, [rip + in_sb]
    call sb_clear
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lt_getting]
    call sb_push_cstr
    call push_owner_name
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Ldots]
    call sb_push_cstr
    call in_sb_cstr
    mov rdi, rax
    call app_toast
    EPILOGUE
.Lis_busy:
    lea rdi, [rip + .Le_busy]
    call app_toast
    EPILOGUE
.Lis_bad:
    lea rdi, [rip + .Le_name]
.Lis_fail_msg:
    mov dword ptr [rip + g_ext_install_state], 4
    call app_toast
    EPILOGUE
.Lis_spawn:
    lea rdi, [rip + .Le_spawn]
    jmp .Lis_fail_msg

.ifdef WINDOWS
# win_install_job() -> rax argv, rdx envp (0 when PowerShell is not there): powershell.exe runs
# runtime/windows/extinstall.ps1 (embedded by tools/build-windows.py as ext_install_script) with
# owner, name, target, root and base in RHUN_EI_* variables
win_install_job:
    PROLOGUE 64
    mov rdi, [rip + ei_envp]
    call mem_free
    mov qword ptr [rip + ei_envp], 0
    mov rdi, [rip + ei_shell]
    call mem_free
    mov qword ptr [rip + ei_shell], 0
    lea rdi, [rip + ei_vars]
    lea rsi, [rip + .Lei_owner]
    lea rdx, [rip + in_owner]
    call ei_var
    mov [rsp], rax
    lea rdi, [rip + ei_vars + SB_SIZE]
    lea rsi, [rip + .Lei_name]
    lea rdx, [rip + in_name]
    call ei_var
    mov [rsp + 8], rax
    lea rdi, [rip + ei_vars + 2*SB_SIZE]
    lea rsi, [rip + .Lei_target]
    lea rdx, [rip + ext_target]
    call ei_var
    mov [rsp + 16], rax
    call ext_root_dir
    lea rdi, [rip + ei_vars + 3*SB_SIZE]
    lea rsi, [rip + .Lei_root]
    mov rdx, rax
    call ei_var
    mov [rsp + 24], rax
    lea rdi, [rip + .Lenv_base]
    call getenv
    test rax, rax
    jnz 1f
    lea rax, [rip + .Lgithub]
1:  lea rdi, [rip + ei_vars + 4*SB_SIZE]
    lea rsi, [rip + .Lei_base]
    mov rdx, rax
    call ei_var
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 0
    mov rdi, rsp
    call env_make
    mov [rip + ei_envp], rax
    lea rdi, [rip + .Lei_shell]
    call proc_which
    mov [rip + ei_shell], rax
    test rax, rax
    jz 9f
    lea rcx, [rip + ei_argv]
    mov [rcx], rax
    lea rax, [rip + .Lei_noprofile]
    mov [rcx + 8], rax
    lea rax, [rip + .Lei_noninteractive]
    mov [rcx + 16], rax
    lea rax, [rip + .Lei_outputformat]
    mov [rcx + 24], rax
    lea rax, [rip + .Lei_text]
    mov [rcx + 32], rax
    lea rax, [rip + .Lei_encoded]
    mov [rcx + 40], rax
    lea rax, [rip + ext_install_script]
    mov [rcx + 48], rax
    mov qword ptr [rcx + 56], 0
    mov rax, rcx
    mov rdx, [rip + ei_envp]
    EPILOGUE
9:  xor eax, eax
    xor edx, edx
    EPILOGUE

# ei_var(sb, "NAME=", value) -> the cstr "NAME=value" in sb
ei_var:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    mov rax, [rbx + SB_ptr]
    EPILOGUE
.endif


# take_part(buf): copy [A-Za-z0-9._-]+ from r12/r13 into buf (at most 100), advancing them -> 1 when
# something was taken and it does not start with a dot
take_part:
    xor ecx, ecx
1:  test r13, r13
    jz 3f
    movzx eax, byte ptr [r12]
    cmp al, '.'
    je 2f
    cmp al, '_'
    je 2f
    cmp al, '-'
    je 2f
    mov edx, eax
    sub edx, '0'
    cmp edx, 9
    jbe 2f
    mov edx, eax
    or edx, 0x20
    sub edx, 'a'
    cmp edx, 25
    jbe 2f
    jmp 3f
2:  cmp ecx, 100
    jae 8f
    mov [rdi + rcx], al
    inc ecx
    inc r12
    dec r13
    jmp 1b
3:  mov byte ptr [rdi + rcx], 0
    test ecx, ecx
    jz 8f
    cmp byte ptr [rdi], '.'
    je 8f
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# push_owner_name(): "owner/name" onto in_sb
push_owner_name:
    push rbx
    lea rdi, [rip + in_sb]
    lea rsi, [rip + in_owner]
    call sb_push_cstr
    lea rdi, [rip + in_sb]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + in_sb]
    lea rsi, [rip + in_name]
    call sb_push_cstr
    pop rbx
    ret

# in_sb_cstr() -> in_sb as a cstr
in_sb_cstr:
    push rbx
    lea rdi, [rip + in_sb]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rip + in_sb + SB_len]
    mov rax, [rip + in_sb + SB_ptr]
    pop rbx
    ret

# on_install_job(fd, revents, ctx): the job's output; at its end, the offer or the failure
on_install_job:
    PROLOGUE
1:  lea rdi, [rip + in_out]
    mov esi, 4096
    call sb_reserve
    mov rsi, rax
    mov edi, [rip + in_fd]
    mov edx, 4096
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 2f
    cmp qword ptr [rip + in_out + SB_len], 65536
    jae 1b
    add [rip + in_out + SB_len], rax
    jmp 1b
2:  mov edi, [rip + in_fd]
    call watch_remove
    mov edi, [rip + in_fd]
    SYS SYS_close
    mov dword ptr [rip + in_fd], -1
    mov edi, [rip + in_pid]
    xor esi, esi
    call proc_wait
    mov ebx, eax
    # the last line: "ok DIR", or why it failed
    lea rdi, [rip + in_out]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + in_out + SB_ptr]
    mov rsi, [rip + in_out + SB_len]
    dec rsi
3:  test rsi, rsi
    jz 4f
    cmp byte ptr [rdi + rsi - 1], 10
    je 31f
    cmp byte ptr [rdi + rsi - 1], 13    # PowerShell ends its lines with CR LF
    jne 4f
31: dec rsi
    mov byte ptr [rdi + rsi], 0
    jmp 3b
4:  mov rcx, rsi                # the last line starts after the last LF
5:  test rcx, rcx
    jz 6f
    cmp byte ptr [rdi + rcx - 1], 10
    je 6f
    dec rcx
    jmp 5b
6:  lea r12, [rdi + rcx]
    test ebx, ebx
    jnz .Loi_failed
    cmp word ptr [r12], 0x6b6f     # "ok"
    jne .Loi_failed
    cmp byte ptr [r12 + 2], ' '
    jne .Loi_failed
    lea rdi, [rip + in_tmp]
    lea rsi, [r12 + 3]
    call cstr_copy
    call offer
    jmp 9f
.Loi_failed:
    mov dword ptr [rip + g_ext_install_state], 4
    lea rdi, [rip + in_sb]
    call sb_clear
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lt_cannot]
    call sb_push_cstr
    call push_owner_name
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lcolon]
    call sb_push_cstr
    lea rdi, [rip + in_sb]
    mov rsi, r12
    cmp byte ptr [r12], 0
    jne 7f
    lea rsi, [rip + .Le_unknown]
7:  call sb_push_cstr
    call in_sb_cstr
    mov rdi, rax
    call app_toast
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# offer(): read the unpacked manifest and ask
offer:
    PROLOGUE
    # the manifest's title, version, description and needs, into pv
    lea rdi, [rip + pv]
    xor esi, esi
    mov edx, EXT_SIZE
    call memset
    lea rdi, [rip + in_sb]
    call sb_clear
    lea rdi, [rip + in_sb]
    lea rsi, [rip + in_tmp]
    call sb_push_cstr
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lx_manifest]
    call sb_push_cstr
    call in_sb_cstr
    mov rdi, rax
    call file_read_all
    test rax, rax
    jz .Lof_bad
    mov rbx, rax
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + pv]
    call ext_preview
    push rax
    push rax
    mov rdi, rbx
    call mem_free
    pop rax
    pop rax
    test eax, eax
    jz .Lof_bad
    # the manifest must be the extension asked for (GitHub names ignore case: the manifest's
    # spelling names the folders)
    mov rdi, [rip + pv + EXT_mowner]
    lea rsi, [rip + in_owner]
    call same_ci
    test eax, eax
    jz .Lof_other
    mov rdi, [rip + pv + EXT_mname]
    lea rsi, [rip + in_name]
    call same_ci
    test eax, eax
    jz .Lof_other
    lea rdi, [rip + in_owner]
    mov rsi, [rip + pv + EXT_mowner]
    call cstr_copy
    lea rdi, [rip + in_name]
    mov rsi, [rip + pv + EXT_mname]
    call cstr_copy
    # "Add “Title”?"
    lea rdi, [rip + in_title]
    lea rsi, [rip + .Lq_add]
    call cstr_copy
    mov rdi, rax
    mov rsi, [rip + pv + EXT_title]
    call copy_title
    mov rdi, rax
    lea rsi, [rip + .Lq_end]
    call cstr_copy
    # "Version V from github.com/owner/name. It can: ..."
    lea rdi, [rip + in_sb]
    call sb_clear
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lt_version]
    call sb_push_cstr
    lea rdi, [rip + in_sb]
    mov rsi, [rip + pv + EXT_version]
    call sb_push_cstr
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lt_from]
    call sb_push_cstr
    call push_owner_name
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lt_it_can]
    call sb_push_cstr
    lea rdi, [rip + pv]
    lea rsi, [rip + in_sb]
    call ext_needs_words
    lea rdi, [rip + in_sb]
    mov esi, '.'
    call sb_push_byte
    call in_sb_cstr
    lea rdi, [rip + in_text]
    mov rsi, rax
    mov rcx, [rip + in_sb + SB_len]
    cmp rcx, 1000
    jbe 1f
    mov ecx, 1000
1:  mov rdx, rcx
    push rdx
    push rdx
    call memcpy
    pop rdx
    pop rdx
    lea rax, [rip + in_text]
    mov byte ptr [rax + rdx], 0
    mov dword ptr [rip + g_ext_install_state], 2
    lea rdi, [rip + in_title]
    lea rsi, [rip + in_text]
    lea rdx, [rip + .Lb_add]
    lea rcx, [rip + install_commit]
    call app_confirm
    lea rdi, [rip + install_discard]
    call app_confirm_cancel
    EPILOGUE
.Lof_bad:
    call install_discard
    mov dword ptr [rip + g_ext_install_state], 4
    lea rdi, [rip + .Le_manifest]
    call app_toast
    EPILOGUE
.Lof_other:
    call install_discard
    mov dword ptr [rip + g_ext_install_state], 4
    lea rdi, [rip + in_sb]
    call sb_clear
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lt_cannot]
    call sb_push_cstr
    call push_owner_name
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lcolon]
    call sb_push_cstr
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Le_other]
    call sb_push_cstr
    call in_sb_cstr
    mov rdi, rax
    call app_toast
    EPILOGUE

# copy_title(dst, cstr) -> rax the end (its NUL): at most TITLE_MAX bytes of a manifest's title,
# cut between characters and ended with "…" when it is longer (in_title holds the question)
.equ TITLE_MAX, 120
copy_title:
    xor ecx, ecx
1:  mov al, [rsi + rcx]
    test al, al
    jz 3f
    inc rcx
    cmp rcx, TITLE_MAX
    jb 1b
    cmp byte ptr [rsi + rcx], 0
    je 3f
    # too long: back to the start of a character, then the ellipsis
2:  mov al, [rsi + rcx]
    and al, 0xc0
    cmp al, 0x80
    jne 4f
    dec rcx
    jnz 2b
4:  push rcx
    push rcx
    mov rdx, rcx
    call memcpy                 # rax: dst (memcpy returns it)
    pop rcx
    pop rcx
    add rax, rcx
    mov byte ptr [rax], 0xe2
    mov byte ptr [rax + 1], 0x80
    mov byte ptr [rax + 2], 0xa6
    mov byte ptr [rax + 3], 0
    add rax, 3
    ret
3:  jmp cstr_copy

# same_ci(a, b) -> 1 when the cstrs are equal ignoring ASCII case
same_ci:
1:  movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    lea edx, [rax - 'A']
    cmp edx, 25
    ja 2f
    add eax, 32
2:  lea edx, [rcx - 'A']
    cmp edx, 25
    ja 3f
    add ecx, 32
3:  cmp eax, ecx
    jne 8f
    test eax, eax
    jz 9f
    inc rdi
    inc rsi
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# install_discard(): Cancel: the unpacked folder goes
install_discard:
    PROLOGUE
    lea rdi, [rip + in_tmp]
    cmp byte ptr [rdi], 0
    je 9f
    call file_remove_tree
    mov byte ptr [rip + in_tmp], 0
    cmp dword ptr [rip + g_ext_install_state], 2
    jne 9f
    mov dword ptr [rip + g_ext_install_state], 0
9:  EPILOGUE

# install_commit(): Add: into OWNER/NAME (replacing an earlier version), loaded and started
install_commit:
    PROLOGUE
    # a record for it first: nothing on disk changes when the table is full
    cmp qword ptr [rip + g_exts + VEC_len], EXT_CAP
    jb 0f
    call install_discard
    mov dword ptr [rip + g_ext_install_state], 4
    lea rdi, [rip + .Le_full]
    call app_toast
    EPILOGUE
0:  # the destination
    lea rdi, [rip + in_sb]
    call sb_clear
    call ext_root_dir
    lea rdi, [rip + in_sb]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + in_sb]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + in_sb]
    lea rsi, [rip + in_owner]
    call sb_push_cstr
    call in_sb_cstr
    mov rdi, rax
    call mkdir_p
    lea rdi, [rip + in_sb]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + in_sb]
    lea rsi, [rip + in_name]
    call sb_push_cstr
    call in_sb_cstr
    mov rdi, rax
    call dup_cstr
    mov r12, rax                # ROOT/OWNER/NAME
    # an installed version stops and leaves
    lea rdi, [rip + in_sb]
    call sb_clear
    call push_owner_name
    call in_sb_cstr
    mov rdi, rax
    mov rsi, [rip + in_sb + SB_len]
    call ext_by_name
    mov r14, rax                # the installed version's record, or 0
    test rax, rax
    jz 1f
    mov rdi, rax
    call ext_retire
1:  # ROOT/OWNER/NAME.old, then the new one in its place
    lea rdi, [rip + in_sb]
    call sb_clear
    lea rdi, [rip + in_sb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Ldot_old]
    call sb_push_cstr
    call in_sb_cstr
    mov rdi, rax
    call dup_cstr
    mov r13, rax
    mov rdi, r13
    call file_remove_tree
    mov rdi, r12
    mov rsi, r13
    SYS SYS_rename              # an older version, if any, steps aside
    lea rdi, [rip + in_sb]
    call sb_clear
    lea rdi, [rip + in_sb]
    lea rsi, [rip + in_tmp]
    call sb_push_cstr
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lx_dir]
    call sb_push_cstr
    call in_sb_cstr
    mov rdi, rax
    mov rsi, r12
    SYS SYS_rename
    test rax, rax
    js .Lic_fail
    mov rdi, r13
    call file_remove_tree
    lea rdi, [rip + in_tmp]
    call file_remove_tree
    mov byte ptr [rip + in_tmp], 0
    # loaded, its choices read, its commands in the palette, and started
    mov rdi, r12
    lea rsi, [rip + in_owner]
    lea rdx, [rip + in_name]
    call ext_install_load
    test rax, rax
    jz .Lic_full
    mov rbx, rax
    mov dword ptr [rip + g_ext_install_state], 3
    lea rdi, [rip + in_sb]
    call sb_clear
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lt_added]
    call sb_push_cstr
    lea rdi, [rip + in_sb]
    mov rsi, [rbx + EXT_title]
    test rsi, rsi
    jnz 2f
    mov rsi, [rbx + EXT_name]
2:  call sb_push_cstr
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lt_added_end]
    call sb_push_cstr
    call in_sb_cstr
    mov rdi, rax
    call app_toast
    jmp 9f
.Lic_fail:
    mov rdi, r13                # the older version comes back, and runs again
    mov rsi, r12
    SYS SYS_rename
    test r14, r14
    jz 1f
    mov rdi, r12
    lea rsi, [rip + in_owner]
    lea rdx, [rip + in_name]
    call ext_install_load
1:  call install_discard
    mov dword ptr [rip + g_ext_install_state], 4
    lea rdi, [rip + .Le_move]
    call app_toast
    jmp 9f
.Lic_full:
    mov dword ptr [rip + g_ext_install_state], 4
    lea rdi, [rip + .Le_full]
    call app_toast
9:  mov rdi, r12
    call mem_free
    mov rdi, r13
    call mem_free
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ext_remove_ask(ext): Remove asks first
FN ext_remove_ask
    PROLOGUE
    mov [rip + rm_ext], rdi
    mov rbx, rdi
    lea rdi, [rip + in_title]
    lea rsi, [rip + .Lq_remove]
    call cstr_copy
    mov rdi, rax
    mov rsi, [rbx + EXT_title]
    test rsi, rsi
    jnz 1f
    mov rsi, [rbx + EXT_name]
1:  call copy_title
    mov rdi, rax
    lea rsi, [rip + .Lq_end]
    call cstr_copy
    lea rdi, [rip + in_title]
    lea rsi, [rip + .Lt_remove_line]
    lea rdx, [rip + .Lb_remove]
    lea rcx, [rip + remove_commit]
    call app_confirm
    EPILOGUE

# remove_commit(): the program stops, its folder and its saved data go
remove_commit:
    PROLOGUE
    mov rbx, [rip + rm_ext]
    test rbx, rbx
    jz 9f
    mov qword ptr [rip + rm_ext], 0
    mov rdi, rbx
    call ext_retire
    mov rdi, [rbx + EXT_dir]
    call file_remove_tree
    mov rdi, [rbx + EXT_state]
    call file_remove_tree
    call ext_settings_save
    lea rdi, [rip + in_sb]
    call sb_clear
    lea rdi, [rip + in_sb]
    lea rsi, [rip + .Lt_removed]
    call sb_push_cstr
    lea rdi, [rip + in_sb]
    mov rsi, [rbx + EXT_title]
    test rsi, rsi
    jnz 1f
    mov rsi, [rbx + EXT_name]
1:  call sb_push_cstr
    call in_sb_cstr
    mov rdi, rax
    call app_toast
    call extpage_forget
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

.section .rodata
.Lask: .asciz "Install from GitHub: owner/repo or GitHub URL"
.Lgh: .asciz "github.com/"
.Lsh: .asciz "/bin/sh"
.Ldash_c: .asciz "-c"
.Lsh_name: .asciz "rhun-install"
.Lenv_base: .asciz "RHUN_EXT_BASE"
.Lgithub: .asciz "https://github.com"
.Lx_manifest: .asciz "/x/extension.ini"
.Lx_dir: .asciz "/x"
.Ldot_old: .asciz ".old"
.Ldots: .asciz "\342\200\246"
.Lcolon: .asciz ": "
.Lq_add: .asciz "Add \342\200\234"
.Lq_remove: .asciz "Remove \342\200\234"
.Lq_end: .asciz "\342\200\235?"
.Lb_add: .asciz "Add extension"
.Lb_remove: .asciz "Remove"
.Lt_getting: .asciz "Getting "
.Lt_cannot: .asciz "Could not install "
.Lt_version: .asciz "Version "
.Lt_from: .asciz " from github.com/"
.Lt_it_can: .asciz ". It can "
.Lt_added: .asciz "Added "
.Lt_added_end: .asciz ". Its commands are in the command palette."
.Lt_removed: .asciz "Removed "
.Lt_remove_line: .asciz "Its settings and the data it saved go too."
.Le_busy: .asciz "An extension is already being installed"
.Le_name: .asciz "Enter owner/repo or a GitHub repository URL"
.Le_spawn: .asciz "Could not start the download"
.Le_unknown: .asciz "the download failed"
.Le_manifest: .asciz "The download has no readable extension.ini"
.Le_other: .asciz "its extension.ini names a different extension"
.Le_move: .asciz "Could not put the extension in place"
.Le_full: .asciz "Too many extensions are installed"
.ifdef WINDOWS
.Lei_owner: .asciz "RHUN_EI_OWNER="
.Lei_name: .asciz "RHUN_EI_NAME="
.Lei_target: .asciz "RHUN_EI_TARGET="
.Lei_root: .asciz "RHUN_EI_ROOT="
.Lei_base: .asciz "RHUN_EI_BASE="
.Lei_shell: .asciz "powershell.exe"
.Lei_noprofile: .asciz "-NoProfile"
.Lei_noninteractive: .asciz "-NonInteractive"
.Lei_outputformat: .asciz "-OutputFormat"
.Lei_text: .asciz "Text"
.Lei_encoded: .asciz "-EncodedCommand"
.endif
# the job: fixed text; owner, name, target, root and base come as $1..$5
install_script:
    .ascii "set -u\n"
    .ascii "owner=$1 name=$2 target=$3 root=$4 base=$5\n"
    .ascii "mkdir -p \"$root\" || { echo \"cannot create $root\"; exit 1; }\n"
    .ascii "tmp=$(mktemp -d \"$root/.install-XXXXXX\") || { echo \"cannot create a folder in $root\"; exit 1; }\n"
    .ascii "fail() { rm -rf \"$tmp\"; echo \"$1\"; exit 1; }\n"
    .ascii "get() {\n"
    .ascii "  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 120 --max-filesize 67108864 -o \"$2\" \"$1\"\n"
    .ascii "  elif command -v wget >/dev/null 2>&1; then wget -q -T 120 -O \"$2\" \"$1\"\n"
    .ascii "  else fail \"neither curl nor wget is installed\"; fi\n"
    .ascii "}\n"
    .ascii "url=$base/$owner/$name/releases/latest/download\n"
    .ascii "asset=$name-$target.tar.gz\n"
    .ascii "get \"$url/$asset\" \"$tmp/a.tgz\" || fail \"no release of $owner/$name for $target\"\n"
    .ascii "get \"$url/sha256sums.txt\" \"$tmp/sums\" || fail \"the release has no sha256sums.txt\"\n"
    .ascii "want=$(awk -v f=\"$asset\" '$2 == f || $2 == \"*\" f { print $1 }' \"$tmp/sums\")\n"
    .ascii "if command -v sha256sum >/dev/null 2>&1; then have=$(sha256sum \"$tmp/a.tgz\"); else have=$(shasum -a 256 \"$tmp/a.tgz\"); fi\n"
    .ascii "have=${have%% *}\n"
    .ascii "[ -n \"$want\" ] && [ \"$want\" = \"$have\" ] || fail \"the download does not match its checksum\"\n"
    .ascii "tar -tvzf \"$tmp/a.tgz\" > \"$tmp/list\" 2>/dev/null || fail \"the archive cannot be read\"\n"
    .ascii "grep -q '^[^-d]' \"$tmp/list\" && fail \"the archive holds links or devices\"\n"
    .ascii "tar -tzf \"$tmp/a.tgz\" | grep -Eq '(^/|(^|/)[.][.](/|$))' && fail \"the archive reaches outside itself\"\n"
    .ascii "mkdir \"$tmp/x\" && tar -xzf \"$tmp/a.tgz\" -C \"$tmp/x\" 2>/dev/null || fail \"the archive cannot be unpacked\"\n"
    .ascii "[ -f \"$tmp/x/extension.ini\" ] || fail \"the archive has no extension.ini\"\n"
    .ascii "rm -f \"$tmp/a.tgz\" \"$tmp/sums\" \"$tmp/list\"\n"
    .asciz "echo \"ok $tmp\"\n"
