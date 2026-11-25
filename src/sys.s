# syscall wrappers, process env, logging, files, time
.include "rhun.inc"

.bss
.globl g_argc, g_argv, g_envp
g_argc: .quad 0
g_argv: .quad 0
g_envp: .quad 0
.p2align 4
ts_buf: .zero 16
stat_buf: .zero 144
tmp_path: .zero 4096
save_serial: .quad 0
fw_private: .long 0               # file_write_private: owner only

.text

# sys_init(rsp_at_start): record argc/argv/envp
FN sys_init
    mov rax, [rdi]
    mov [rip + g_argc], rax
    lea rcx, [rdi + 8]
    mov [rip + g_argv], rcx
    lea rcx, [rcx + rax*8 + 8]
    mov [rip + g_envp], rcx
    ret

# getenv(name) -> value cstr or 0
FN getenv
    push rbx
    mov rbx, [rip + g_envp]
.Lge_next:
    mov rsi, [rbx]
    test rsi, rsi
    jz .Lge_none
    mov rcx, rdi
.Lge_cmp:
    mov al, [rcx]
    test al, al
    jz .Lge_endname
    cmp al, [rsi]
    jne .Lge_skip
    inc rcx
    inc rsi
    jmp .Lge_cmp
.Lge_endname:
    cmp byte ptr [rsi], '='
    jne .Lge_skip
    lea rax, [rsi + 1]
    pop rbx
    ret
.Lge_skip:
    add rbx, 8
    jmp .Lge_next
.Lge_none:
    xor eax, eax
    pop rbx
    ret

# env_unset(name): remove an inherited entry before spawning other programs.
FN env_unset
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
    mov rdi, rbx
    call getenv
    test rax, rax
    jz 9f
    sub rax, r12
    dec rax
    mov rdx, [rip + g_envp]
1:  cmp qword ptr [rdx], 0
    je 9f
    cmp [rdx], rax
    je 2f
    add rdx, 8
    jmp 1b
2:  mov rcx, [rdx + 8]
    mov [rdx], rcx
    add rdx, 8
    test rcx, rcx
    jnz 2b
9:  EPILOGUE

FN sys_exit
    SYS SYS_exit_group

# write_all(fd, ptr, len) -> 0 or -errno
FN write_all
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
.Lwa_loop:
    test r13, r13
    jz .Lwa_ok
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    SYS SYS_write
    cmp rax, -EINTR
    je .Lwa_loop
    cmp rax, -EAGAIN
    je .Lwa_loop
    test rax, rax
    js .Lwa_ret
    add r12, rax
    sub r13, rax
    jmp .Lwa_loop
.Lwa_ok:
    xor eax, eax
.Lwa_ret:
    pop r13
    pop r12
    pop rbx
    ret

# log_write(ptr, len) -> stderr
FN log_write
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 2
    jmp write_all

# log_cstr(s)
FN log_cstr
    push rdi
    call strlen
    pop rdi
    mov rsi, rax
    jmp log_write

# log_u64(v)
FN log_u64
    sub rsp, 40
    mov rsi, rdi
    mov rdi, rsp
    call fmt_u64
    mov rdi, rsp
    mov rsi, rax
    call log_write
    add rsp, 40
    ret

FN log_nl
    push 10
    mov rdi, rsp
    mov esi, 1
    call log_write
    pop rax
    ret

# die(msg cstr)
FN die
    call log_cstr
    call log_nl
    mov edi, 1
    jmp sys_exit

# Process-local headroom for extension pipes, logs and the editor's other services. Preserve
# larger inherited limits and the hard limit. A restricted hard limit remains an OS constraint.
FN sys_file_capacity
.ifdef WINDOWS
    ret
.else
    PROLOGUE 16
    mov edi, 7                  # Linux RLIMIT_NOFILE (translated on macOS)
    mov rsi, rsp
    SYS SYS_getrlimit
    test rax, rax
    js 9f
    cmp qword ptr [rsp], 1024
    jae 9f
    mov rax, [rsp + 8]
    cmp rax, 1024
    jbe 1f
    mov eax, 1024
1:  cmp rax, [rsp]
    jbe 9f
    mov [rsp], rax
    mov edi, 7
    mov rsi, rsp
    SYS SYS_setrlimit
9:  EPILOGUE
.endif

# time_ms() -> monotonic milliseconds
FN time_ms
    mov edi, CLOCK_MONOTONIC
    lea rsi, [rip + ts_buf]
    SYS SYS_clock_gettime
    mov rax, [rip + ts_buf]
    imul rax, rax, 1000
    mov rcx, rax
    mov rax, [rip + ts_buf + 8]
    xor edx, edx
    mov r8d, 1000000
    div r8
    add rax, rcx
    ret

# time_us() -> monotonic microseconds, for aggregate work across sub-millisecond callbacks
FN time_us
    mov edi, CLOCK_MONOTONIC
    lea rsi, [rip + ts_buf]
    SYS SYS_clock_gettime
    mov rax, [rip + ts_buf]
    imul rax, rax, 1000000
    mov rcx, rax
    mov rax, [rip + ts_buf + 8]
    xor edx, edx
    mov r8d, 1000
    div r8
    add rax, rcx
    ret

# time_now() -> unix seconds
FN time_now
    mov edi, CLOCK_REALTIME
    lea rsi, [rip + ts_buf]
    SYS SYS_clock_gettime
    mov rax, [rip + ts_buf]
    ret

# file_open_read(path) -> fd or -errno
FN file_open_read
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    ret

# file_size(fd) -> size or -errno
FN file_size
    lea rsi, [rip + stat_buf]
    SYS SYS_fstat
    test rax, rax
    js 1f
    mov rax, [rip + stat_buf + 48]
1:  ret

# file_stamp(path) -> changes whenever the file is written: mtime in nanoseconds and the size
# (0 if it is missing); follows symlinks. Also returns size in rdx, mtime_ns in rcx.
FN file_stamp
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    lea rsi, [rip + stat_buf]
    mov eax, 4                  # stat
    XSYS
    test rax, rax
    js 1f
    mov rax, [rip + stat_buf + 88]
    imul rax, rax, 1000000000
    add rax, [rip + stat_buf + 96]
    mov rcx, rax
    mov rdx, [rip + stat_buf + 48]
    rol rdx, 32
    xor rax, rdx
    ror rdx, 32
    ret
1:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    ret

# file_missing(path) -> 1 if nothing is there, not even a link (ENOENT, ENOTDIR); 0 if something is or
#   that cannot be told (EACCES: a folder on the way that cannot be searched)
FN file_missing
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
.ifdef WINDOWS
    jmp win_file_missing            # its lstat is stat: it would follow a link to a missing target
.endif
    lea rsi, [rip + stat_buf]
    SYS SYS_lstat
    xor ecx, ecx
    cmp rax, -2
    sete cl
    cmp rax, -20
    jne 1f
    mov ecx, 1
1:  mov eax, ecx
    ret

# file_mtime(path) -> unix seconds (0 on error)
FN file_mtime
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    lea rsi, [rip + stat_buf]
    SYS SYS_lstat
    test rax, rax
    js 1f
    mov rax, [rip + stat_buf + 88]
    ret
1:  xor eax, eax
    ret

# file_mtime_ns(path) -> when it was last written, in nanoseconds since the epoch (0 on error)
FN file_mtime_ns
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    lea rsi, [rip + stat_buf]
    SYS SYS_lstat
    test rax, rax
    js 1f
    mov rax, [rip + stat_buf + 88]
    imul rax, rax, 1000000000
    add rax, [rip + stat_buf + 96]
    ret
1:  xor eax, eax
    ret

# file_is_dir(path) -> 1/0
FN file_is_dir
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    lea rsi, [rip + stat_buf]
    mov eax, 4          # stat (follows symlinks)
    XSYS
    test rax, rax
    js 1f
    mov eax, [rip + stat_buf + 24]
    and eax, 0xf000
    cmp eax, 0x4000
    sete al
    movzx eax, al
    ret
1:  xor eax, eax
    ret

# file_type(path) -> the S_IFMT bits of its mode (0x8000 a regular file, 0x4000 a folder...), 0 if
# missing; follows symlinks
FN file_type
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    lea rsi, [rip + stat_buf]
    mov eax, 4          # stat (follows symlinks)
    XSYS
    test rax, rax
    js 1f
    mov eax, [rip + stat_buf + 24]
    and eax, 0xf000
    ret
1:  xor eax, eax
    ret

# file_id(path) -> rax inode, rdx device (both 0 if it is missing); follows symlinks, so every spelling
# of one folder (through a symlink such as macOS's /tmp, or in another case) has one id
FN file_id
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    lea rsi, [rip + stat_buf]
    mov eax, 4          # stat
    XSYS
    test rax, rax
    js 1f
    mov rax, [rip + stat_buf + 8]
    mov rdx, [rip + stat_buf]
    ret
1:  xor eax, eax
    xor edx, edx
    ret

# file_read_all(path) -> rax=ptr (NUL-terminated, mem_alloc'd) rdx=len; rax=0, rdx=-errno on error
FN file_read_all
    xor esi, esi
    jmp file_read_all_extra

# file_read_all_extra(path, extra) -> as file_read_all, with room for extra bytes after the text (a
#   document's gap, which then needs no copy of the whole file to grow into)
FN file_read_all_extra
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    mov rdx, -1
    jmp .Lfr_begin

# file_read_limited(path, max): snapshot read, refusing an oversized regular file before
# allocating its contents. max must be in 0..INT64_MAX-1; errors use file_read_all's contract.
FN file_read_limited
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    mov rax, 0x7ffffffffffffffe
    cmp rsi, rax
    jbe 1f
    mov rdx, -22
    xor eax, eax
    ret
1:  mov rdx, rsi
    xor esi, esi
.Lfr_begin:
    PROLOGUE 16
    mov [rsp], rdx
    mov r15, rsi
    # without blocking: opening a FIFO to read waits for a writer (a repository's .git/HEAD can be
    # one, and a rhun:// link opens a repository); the regular-file check below then refuses it
    mov esi, O_RDONLY | O_CLOEXEC | O_NONBLOCK
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js .Lfr_fail
    mov ebx, eax
    mov edi, eax
    call file_size
    test rax, rax
    js .Lfr_close_fail
    mov ecx, [rip + stat_buf + 24]
    and ecx, 0xf000
    cmp ecx, 0x8000
    je 1f
    mov rax, -22               # EINVAL: a FIFO, a device or a socket would never end
    cmp ecx, 0x4000            # a directory can report size zero, so read would never reject it
    jne .Lfr_close_fail
    mov rax, -21               # EISDIR
    jmp .Lfr_close_fail
1:  cmp rax, [rsp]
    jbe 2f
    mov rax, -27               # EFBIG: do not allocate an oversized input
    jmp .Lfr_close_fail
2:
    mov r12, rax            # size
    lea rdi, [rax + r15 + 1]
    call mem_alloc
    mov r13, rax            # buf
    xor r14d, r14d          # read so far
.Lfr_loop:
    cmp r14, r12
    jae .Lfr_done
    mov edi, ebx
    lea rsi, [r13 + r14]
    mov rdx, r12
    sub rdx, r14
    SYS SYS_read
    cmp rax, -EINTR
    je .Lfr_loop
    test rax, rax
    js .Lfr_free_fail
    jz .Lfr_done
    add r14, rax
    jmp .Lfr_loop
.Lfr_done:
    mov byte ptr [r13 + r14], 0
    mov edi, ebx
    SYS SYS_close
    mov rax, r13
    mov rdx, r14
    EPILOGUE
.Lfr_free_fail:
    mov r15, rax
    mov rdi, r13
    call mem_free
    jmp .Lfr_close
.Lfr_close_fail:
    mov r15, rax
.Lfr_close:
    mov edi, ebx
    SYS SYS_close
    mov rax, r15
.Lfr_fail:
    mov rdx, rax
    xor eax, eax
    EPILOGUE

# file_write_private(path, ptr, len) -> 0 or -errno: file_write_all, the file readable and writable by
#   its owner alone (0600 when new; an existing one loses its group's and others' bits)
FN file_write_private
    mov dword ptr [rip + fw_private], 1
    push rbx
    call file_write_all
    mov dword ptr [rip + fw_private], 0
    pop rbx
    ret

# file_write_all(path, ptr, len) -> 0 or -errno
# Follow final symlinks, then replace the target through an exclusively created sibling.
FN file_write_all
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    PROLOGUE 8208              # target path, link text, existing-file flag
    mov r13, rsi
    mov r14, rdx
    mov r12, rdi
    call strlen
    cmp rax, 4096
    jae .Lfw_toolong
    mov rsi, r12
    mov rdi, rsp
    call cstr_copy
    mov r12, rsp
    mov ebx, 40
.Lfw_resolve:
    mov rdi, r12
    lea rsi, [rsp + 4096]
    mov edx, 4096
    SYS SYS_readlink
    cmp rax, -22               # EINVAL: not a symlink
    je .Lfw_stat
    cmp rax, -2                # ENOENT: a new file (including a dangling link's target)
    je .Lfw_stat
    test rax, rax
    js .Lfw_ret
    cmp rax, 4096
    jae .Lfw_toolong
    test ebx, ebx
    jz .Lfw_loop
    dec ebx
    mov byte ptr [rsp + rax + 4096], 0
    mov r15, rax
    lea rax, [rsp + 4096]
    PATH_ABSOLUTE rax, 1f
    # Relative link text replaces the basename, retaining its directory and any symlinks in it.
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call path_basename
    mov rdi, rax
    sub rax, r12
    add rax, r15
    cmp rax, 4096
    jae .Lfw_toolong
    jmp 2f
1:  mov rdi, r12
2:  lea rsi, [rsp + 4096]
    call cstr_copy
    jmp .Lfw_resolve
.Lfw_stat:
    mov dword ptr [rsp + 8192], 0
    mov r15d, 0644
    mov rdi, r12
    lea rsi, [rip + stat_buf]
    mov eax, 4
    XSYS
    cmp rax, -2
    je 1f
    test rax, rax
    js .Lfw_ret
    mov ecx, [rip + stat_buf + 24]
    and ecx, 0xf000
    mov rax, -21               # EISDIR
    cmp ecx, 0x4000
    je .Lfw_ret
    mov rax, -22               # EINVAL: do not replace devices, pipes or sockets
    cmp ecx, 0x8000
    jne .Lfw_ret
    mov dword ptr [rsp + 8192], 1
    mov r15d, [rip + stat_buf + 24]
    and r15d, 07777
1:  cmp dword ptr [rip + fw_private], 0
    je 2f
    and r15d, 0700              # file_write_private: the owner's bits only
2:  mov ebx, 128                # bounded retries if stale temporary files exist
.Lfw_temp:
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call path_basename
    sub rax, r12                # directory prefix, including its trailing slash
    cmp rax, 4000
    ja .Lfw_toolong
    mov rcx, rax
    lea rdi, [rip + tmp_path]
    mov rsi, r12
    rep movsb
    lea rsi, [rip + .Ltmp_prefix]
    call cstr_copy
    mov rdi, rax
    SYS SYS_getpid
    mov rsi, rax
    call fmt_u64
    mov byte ptr [rdi], '-'
    inc rdi
    inc qword ptr [rip + save_serial]
    mov rsi, [rip + save_serial]
    call fmt_u64
    lea rsi, [rip + .Ltmp_suffix]
    call cstr_copy
    lea rdi, [rip + tmp_path]
    mov esi, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
    mov edx, r15d
    SYS SYS_open
    cmp rax, -17               # EEXIST: never truncate or follow an existing entry
    jne 1f
    dec ebx
    jnz .Lfw_temp
1:  test rax, rax
    js .Lfw_ret
    mov ebx, eax
    cmp dword ptr [rsp + 8192], 0
    je 2f                      # for a new file, keep the mode limited by umask
    mov edi, ebx
    mov esi, r15d
    SYS SYS_fchmod
    test rax, rax
    js .Lfw_err_close
2:  mov edi, ebx
    mov rsi, r13
    mov rdx, r14
    call write_all
    test rax, rax
    js .Lfw_err_close
.Lfw_sync:
    mov edi, ebx
    SYS SYS_fsync
    cmp rax, -EINTR
    je .Lfw_sync
    test rax, rax
    js .Lfw_err_close
    mov edi, ebx
    SYS SYS_close
    test rax, rax
    js .Lfw_unlink
    lea rdi, [rip + tmp_path]
    mov rsi, r12
    SYS SYS_rename
    test rax, rax
    js .Lfw_unlink
    xor eax, eax
    EPILOGUE
.Lfw_err_close:
    mov r15, rax
    mov edi, ebx
    SYS SYS_close
    mov rax, r15
.Lfw_unlink:
    mov r15, rax
    lea rdi, [rip + tmp_path]
    SYS SYS_unlink
    mov rax, r15
.Lfw_ret:
    EPILOGUE
.Lfw_toolong:
    mov rax, -36               # ENAMETOOLONG
    EPILOGUE
.Lfw_loop:
    mov rax, -40               # ELOOP
    EPILOGUE

.section .rodata
.Ltmp_prefix: .asciz ".rhun-"
.Ltmp_suffix: .asciz ".tmp"
.text

# file_remove_tree(path) -> 0 or -errno. Remove links themselves, including directory links.
FN file_remove_tree
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    PROLOGUE 192               # lstat (144), collection context: path, vector, error (48)
    mov rbx, rdi
    SYS SYS_unlink
    test rax, rax
    jns .Lrm_ret
    mov rdi, rbx
    mov eax, 84                 # rmdir also removes Windows directory links and junctions
    XSYS
    test rax, rax
    jns .Lrm_ret
    mov r12, rax
    # Only descend into real directories. Never traverse a link after a failed removal.
    mov rdi, rbx
.ifdef WINDOWS
    call win_file_is_real_dir
    test rax, rax
    js .Lrm_ret
    jz .Lrm_original_error
.else
    lea rsi, [rsp]
    SYS SYS_lstat
    test rax, rax
    js .Lrm_ret
    mov eax, [rsp + 24]
    and eax, 0170000
    cmp eax, 0040000
    jne .Lrm_original_error
.endif
    mov [rsp + 144], rbx
    mov qword ptr [rsp + 152], 0
    mov qword ptr [rsp + 160], 0
    mov qword ptr [rsp + 168], 0
    mov qword ptr [rsp + 176], 0
    lea rdx, [rsp + 144]
    lea rsi, [rip + remove_collect]
    mov rdi, rbx
    call dir_each_names
    mov r12, rax
    test rax, rax
    js .Lrm_free
    mov r12, [rsp + 176]
    test r12, r12
    js .Lrm_free
    # Enumerate first, then recurse so nested calls do not retain enumeration buffers or handles.
    xor r13d, r13d
.Lrm_child:
    cmp r13, [rsp + 160]
    jae .Lrm_parent
    mov rax, [rsp + 152]
    mov rdi, [rax + r13*8]
    call file_remove_tree
    mov r12, rax
    test rax, rax
    js .Lrm_free
    inc r13
    jmp .Lrm_child
.Lrm_parent:
    mov rdi, rbx
    mov eax, 84
    XSYS
    mov r12, rax
.Lrm_free:
    xor r13d, r13d
.Lrm_free_child:
    cmp r13, [rsp + 160]
    jae .Lrm_free_vec
    mov rax, [rsp + 152]
    mov rdi, [rax + r13*8]
    call mem_free
    inc r13
    jmp .Lrm_free_child
.Lrm_free_vec:
    lea rdi, [rsp + 152]
    call vec_free
.Lrm_original_error:
    mov rax, r12
.Lrm_ret:
    EPILOGUE

# remove_collect(ctx, name): include hidden and explorer-excluded entries too
remove_collect:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp qword ptr [rbx + 32], 0
    jne 9f
    mov rdi, [rbx]
    call strlen
    mov r13, rax
    mov rdi, r12
    call strlen
    lea rax, [rax + r13 + 1]
    cmp rax, 4096
    jae 8f
    mov rdi, [rbx]
    mov rsi, r12
    call path_join
    mov r12, rax
    lea rdi, [rbx + 8]
    mov esi, 8
    call vec_push
    mov [rax], r12
9:  EPILOGUE
8:  mov qword ptr [rbx + 32], -36  # ENAMETOOLONG
    EPILOGUE

# mkdir_p(path) : creates path and parents (path buffer is modified then restored)
FN mkdir_p
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    PROLOGUE
    mov r12, rdi
    lea rbx, [rdi + 1]
.Lmk_loop:
    mov al, [rbx]
    test al, al
    jz .Lmk_last
    cmp al, '/'
    jne .Lmk_next
    mov byte ptr [rbx], 0
    mov rdi, r12
    mov esi, 0755
    SYS SYS_mkdir
    mov byte ptr [rbx], '/'
.Lmk_next:
    inc rbx
    jmp .Lmk_loop
.Lmk_last:
    mov rdi, r12
    mov esi, 0755
    SYS SYS_mkdir
    EPILOGUE

# mkdir_parent(path): create the directories a file path lives in (the path is restored)
FN mkdir_parent
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    push rbx
    push r12
    push r13
    mov r12, rdi
    call strlen
    lea rbx, [r12 + rax]
1:  cmp rbx, r12
    jbe 9f
    dec rbx
    cmp byte ptr [rbx], '/'
    jne 1b
    cmp rbx, r12
    je 9f
    mov byte ptr [rbx], 0
    mov rdi, r12
    call mkdir_p
    mov byte ptr [rbx], '/'
9:  pop r13
    pop r12
    pop rbx
    ret

# dir_each(path, cb, ctx): cb(ctx, name cstr, is_dir) for every entry except . and ..
# returns 0 or -errno
FN dir_each
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    xor ecx, ecx
    jmp .Lde_start

# dir_each_names(path, cb, ctx): cb(ctx, name cstr), without resolving entry types or links
FN dir_each_names
    call remote_strict_check    # remote hosts: tests catch workspace paths here (vfs.s)
    mov ecx, 1
.Lde_start:
    PROLOGUE 48
    mov [rsp + 32], ecx
    mov r12, rsi                # cb
    mov r13, rdx                # ctx
    mov r15, rdi                # path
    mov esi, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js .Lde_ret
    mov ebx, eax
    mov edi, 32768
    call mem_alloc
    mov r14, rax
.Lde_read:
    mov edi, ebx
    mov rsi, r14
    mov edx, 32768
    SYS SYS_getdents64
    test rax, rax
    jle .Lde_done
    mov [rsp], rax              # bytes
    mov qword ptr [rsp + 8], 0  # offset
.Lde_ent:
    mov rax, [rsp + 8]
    cmp rax, [rsp]
    jae .Lde_read
    lea rcx, [r14 + rax]
    movzx edx, word ptr [rcx + 16]
    add [rsp + 8], rdx
    lea rsi, [rcx + 19]         # name
    cmp byte ptr [rsi], '.'
    jne 1f
    cmp byte ptr [rsi + 1], 0
    je .Lde_ent
    cmp byte ptr [rsi + 1], '.'
    jne 1f
    cmp byte ptr [rsi + 2], 0
    je .Lde_ent
1:  cmp dword ptr [rsp + 32], 0
    jne .Lde_callback
    movzx edx, byte ptr [rcx + 18]
    cmp edx, 4                  # DT_DIR
    sete al
    cmp edx, 0                  # DT_UNKNOWN
    je 2f
    cmp edx, 10                 # DT_LNK
    jne 3f
2:  # stat to resolve
    mov [rsp + 16], rsi
    mov rdi, r15
    call path_join_tmp
    mov rdi, rax
    call file_is_dir
    mov rsi, [rsp + 16]
3:  movzx edx, al
.Lde_callback:
    mov rdi, r13
    call r12
    jmp .Lde_ent
.Lde_done:
    mov [rsp + 24], rax
    mov rdi, r14
    call mem_free
    mov edi, ebx
    SYS SYS_close
    mov rax, [rsp + 24]
.Lde_ret:
    EPILOGUE

# path_join_tmp(dir, name) -> static buffer "dir/name"
FN path_join_tmp
    push rbx
    lea rbx, [rip + tmp_path]
    mov rax, rbx
.ifdef WINDOWS
    PATH_ABSOLUTE rsi, 3f
.endif
1:  mov cl, [rdi]
    test cl, cl
    jz 2f
    mov [rax], cl
    inc rax
    inc rdi
    jmp 1b
2:  cmp rax, rbx
    je 3f
    cmp byte ptr [rax - 1], '/'
    je 3f
    mov byte ptr [rax], '/'
    inc rax
3:  mov cl, [rsi]
    mov [rax], cl
    inc rax
    inc rsi
    test cl, cl
    jnz 3b
    mov rax, rbx
    pop rbx
    ret

# path_join(dir, name) -> new allocated cstr, as path_join_tmp joins them but of any length (a name
# from file contents or a terminal line can be longer than tmp_path)
FN path_join
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
.ifdef WINDOWS
    PATH_ABSOLUTE rsi, 3f
.endif
    call strlen
    mov r14, rax                # dir bytes
    mov rdi, r13
    call strlen
    mov r15, rax                # name bytes
    lea rdi, [r14 + r15 + 2]
    call mem_alloc
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    mov rcx, r14
    rep movsb
    test r14, r14
    jz 1f
    cmp byte ptr [r12 + r14 - 1], '/'
    je 1f
    mov byte ptr [rdi], '/'
    inc rdi
1:  mov rsi, r13
    lea rcx, [r15 + 1]          # and its NUL
    rep movsb
    mov rax, rbx
    EPILOGUE
.ifdef WINDOWS
3:  mov rdi, r13                # a rooted name stands alone
    call strlen
    mov rdi, r13
    mov rsi, rax
    call mem_dup
    EPILOGUE
.endif

# path_normalize(path): in place, absolute paths only: drops "." and "//", resolves ".."
FN path_normalize
.ifdef WINDOWS
    jmp win_path_normalize
.endif
    cmp byte ptr [rdi], '/'
    jne 9f
    mov rsi, rdi                # read
    mov rdx, rdi                # write (after the leading '/')
    inc rdx
    inc rsi
1:  # skip slashes
    cmp byte ptr [rsi], '/'
    jne 2f
    inc rsi
    jmp 1b
2:  cmp byte ptr [rsi], 0
    je 8f
    # component [rsi, rcx)
    mov rcx, rsi
3:  mov al, [rcx]
    test al, al
    jz 4f
    cmp al, '/'
    je 4f
    inc rcx
    jmp 3b
4:  mov rax, rcx
    sub rax, rsi
    cmp rax, 1
    jne 5f
    cmp byte ptr [rsi], '.'
    jne 6f
    mov rsi, rcx
    jmp 1b
5:  cmp rax, 2
    jne 6f
    cmp word ptr [rsi], 0x2e2e  # ".."
    jne 6f
    # pop last written component
    lea r8, [rdi + 1]
    cmp rdx, r8
    jbe 51f
    dec rdx                     # drop trailing '/'
52: cmp rdx, r8
    jbe 51f
    cmp byte ptr [rdx - 1], '/'
    je 51f
    dec rdx
    jmp 52b
51: mov rsi, rcx
    jmp 1b
6:  # copy component, then '/' only when the path goes on: with nothing dropped the write position
    # is the read position, and a '/' there would overwrite the terminating NUL and have the
    # bytes after the path read as more of it
    mov al, [rsi]
    mov [rdx], al
    inc rsi
    inc rdx
    cmp rsi, rcx
    jb 6b
    cmp byte ptr [rsi], 0
    je 81f
    mov byte ptr [rdx], '/'
    inc rdx
    jmp 1b
8:  # drop the trailing '/' (keep "/")
    lea r8, [rdi + 1]
    cmp rdx, r8
    jbe 81f
    dec rdx
81: mov byte ptr [rdx], 0
9:  ret

# path_tilde(dst, src) -> end of dst (its NUL): src, with the home folder at its start written as ~
FN path_tilde
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov r13, rax
    call vfs_home               # a remote window's paths are the host's (vfs.s)
    test rax, rax
    jz 8f
    mov r14, rax
    mov rdi, rax
    call strlen
    mov r15, rax
    test r15, r15
    jz 8f
    cmp byte ptr [r14 + r15 - 1], '/'
    jne 1f
    dec r15
1:  # a home of "/" is no shorter as ~
    test r15, r15
    jz 8f
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    call str_starts
    test eax, eax
    jz 8f
    # the whole home: the path ends there or goes on with a '/'
    movzx eax, byte ptr [r12 + r15]
    test eax, eax
    jz 2f
    cmp eax, '/'
    jne 8f
2:  mov byte ptr [rbx], '~'
    lea rdi, [rbx + 1]
    lea rsi, [r12 + r15]
    call cstr_copy
    EPILOGUE
8:  mov rdi, rbx
    mov rsi, r12
    call cstr_copy
    EPILOGUE

.section .rodata
.Lhome_env: .asciz "HOME"
