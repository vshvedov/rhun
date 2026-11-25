# workspace access: files, folders, watches and programs of the project, local or on the host of a
# remote window (remote.s). Workspace code calls these instead of sys.s and proc.s; rhun's own
# config, state, themes and installed extensions keep the direct functions. Each one is the local
# function when the window is not remote.
.include "rhun.inc"

.equ VFS_CHUNK, 4194304         # a read or a write of the host's file goes in parts this big
.equ VFS_ONE_WRITE, 33554432    # files up to this size are written in one request

.bss
.p2align 3
vfs_pending: .zero SB_SIZE      # watch events from the host, waiting for vfs_tick: WD MASK LEN name
vfs_line: .zero SB_SIZE         # a request's line
vfs_body: .zero SB_SIZE         # a request's body
vfs_acc: .zero SB_SIZE          # a file read in parts
vfs_events: .zero SB_SIZE       # vfs_tick's events while it hands them on
.globl vfs_statbuf
vfs_statbuf: .zero 144          # the last vfs_stat / vfs_lstat (Linux struct stat on every system)
vfs_tmp: .zero 4200
vfs_real: .zero 4200              # vfs_write_all: the file a path's links lead to
vfs_cache: .zero SB_SIZE        # vfs_stats_prefetch: "PATH\0" + "o" stat (144) or "e" errno (4), each
vfs_cache_on: .long 0
vfs_roots_done: .byte 0
vfs_root_state: .zero 4096      # rhun's own folders: here even in a remote window
vfs_root_config: .zero 4096
.globl g_remote_strict
g_remote_strict: .long 0        # RHUN_REMOTE_STRICT=1 in a remote window (tests)

.text

# ---------------- which side ----------------

# vfs_remote_path(rdi path) -> eax 0 when the path is handled here: the window is not remote, or the
#   path is inside rhun's own state or config folder (the workspace edits' journal); 1 when it is the
#   host's. Keeps every other register
FN vfs_remote_path
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    xor eax, eax
    cmp dword ptr [rip + g_remote], 0
    je 9f
    mov eax, 1
    test rdi, rdi
    jz 9f
    push rdi
    call vfs_local_roots
    pop rdi
    lea rsi, [rip + vfs_root_state]
    call vfs_under
    test eax, eax
    jz 7f
    call vfs_host_snapshot      # the host's agents index writes there too, by the same path
    test eax, eax
    jz 8f
    jmp 9f
7:  lea rsi, [rip + vfs_root_config]
    call vfs_under
    test eax, eax
    jnz 8f
    mov eax, 1
    jmp 9f
8:  xor eax, eax
9:  pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

# vfs_remote_paths2(rdi, rsi) -> as vfs_remote_path for two paths; when one is here and the other on
#   the host, rax -EXDEV and a return from the caller is the caller's to make (vfs_rename)
vfs_remote_paths2:
    call vfs_remote_path
    xchg rdi, rsi
    push rax
    call vfs_remote_path
    pop rcx
    xchg rdi, rsi
    cmp eax, ecx
    jne 2f
    ret                         # both on one side: eax as vfs_remote_path's
2:  add rsp, 8                  # mixed: the caller returns EXDEV
    mov rax, -18
    ret

# vfs_host_snapshot(rdi path under the state folder) -> eax 1 for a transcript snapshot the host's
#   agents index made (STATE/.rhun-opencode-*): when both machines have the same state folder path
#   it is still the host's file. Keeps rdi
vfs_host_snapshot:
    push rdi
    push rdi
    lea rdi, [rip + vfs_root_state]
    call strlen
    pop rdi
    pop rdi
    add rax, rdi
    cmp byte ptr [rax], '/'
    jne 8f
    lea rsi, [rax + 1]
    lea rdx, [rip + .Lsnap_prefix]
    xor ecx, ecx
1:  movzx eax, byte ptr [rdx + rcx]
    test eax, eax
    jz 9f
    cmp al, [rsi + rcx]
    jne 8f
    inc ecx
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# vfs_under(rdi path, rsi root) -> eax 1 when path is root or inside it (root empty: no)
vfs_under:
    xor ecx, ecx
    cmp byte ptr [rsi], 0
    je 8f
1:  mov al, [rsi + rcx]
    test al, al
    jz 2f
    cmp al, [rdi + rcx]
    jne 8f
    inc rcx
    jmp 1b
2:  mov al, [rdi + rcx]
    test al, al
    jz 9f
    cmp al, '/'
    je 9f
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# vfs_local_roots(): rhun's own folders, found once
vfs_local_roots:
    cmp byte ptr [rip + vfs_roots_done], 0
    jne 9f
    push rbx
    mov byte ptr [rip + vfs_roots_done], 1
    lea rdi, [rip + vfs_acc]
    call session_state_dir
    test eax, eax
    jz 1f
    mov rsi, [rip + vfs_acc + SB_ptr]
    lea rdi, [rip + vfs_root_state]
    call vfs_copy_root
1:  call config_dir
    mov rsi, rax
    lea rdi, [rip + vfs_root_config]
    call vfs_copy_root
    pop rbx
9:  ret

# vfs_copy_root(dst 4096, src): src without a trailing slash, or nothing when too long
vfs_copy_root:
    push rdi
    push rsi
    mov rdi, rsi
    call strlen
    pop rsi
    pop rdi
    cmp rax, 4000
    jae 9f
1:  test rax, rax
    jz 2f
    cmp byte ptr [rsi + rax - 1], '/'
    jne 2f
    dec rax
    jmp 1b
2:  mov rdx, rax
    push rdi
    push rdx
    call memcpy
    pop rdx
    pop rdi
    mov byte ptr [rdi + rdx], 0
9:  ret

# ---------------- requests ----------------

# vfs_req_path(verb cstr, path) -> as remote_call: "VERB" with the path as the body
vfs_req_path:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rcx, rax
    mov rdx, r12
    mov rdi, rbx
    push rcx
    push rdx
    call strlen
    mov rsi, rax
    pop rdx
    pop rcx
    mov rdi, rbx
    call remote_call
    add rsp, 8
    pop r12
    pop rbx
    ret

# vfs_line_start(verb cstr): vfs_line = "VERB"
vfs_line_start:
    push rbx
    mov rbx, rdi
    lea rdi, [rip + vfs_line]
    call sb_clear
    lea rdi, [rip + vfs_line]
    mov rsi, rbx
    call sb_push_cstr
    pop rbx
    ret

# vfs_line_num(n): " N" onto vfs_line
vfs_line_num:
    push rbx
    mov rbx, rdi
    lea rdi, [rip + vfs_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + vfs_line]
    mov rsi, rbx
    call sb_push_u64
    pop rbx
    ret

# vfs_line_call(body, len) -> as remote_call with vfs_line
vfs_line_call:
    mov rcx, rsi
    mov rdx, rdi
    mov rdi, [rip + vfs_line + SB_ptr]
    mov rsi, [rip + vfs_line + SB_len]
    jmp remote_call

# vfs_home() -> the home folder (cstr) or 0: the host's in a remote window, else $HOME
FN vfs_home
    cmp dword ptr [rip + g_remote], 0
    je 1f
    lea rax, [rip + g_remote_home]
    cmp byte ptr [rax], 0
    je 2f
    ret
1:  lea rdi, [rip + .Lhome_env]
    jmp getenv
2:  xor eax, eax
    ret

# ---------------- reading and writing ----------------

# vfs_read_all(path) -> as file_read_all: rax the text (NUL-terminated, mem_alloc'd), rdx its length;
#   rax 0 and rdx -errno on failure
FN vfs_read_all
    xor esi, esi
    jmp vfs_read_all_extra

# vfs_read_all_extra(path, extra) -> as file_read_all_extra
FN vfs_read_all_extra
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je file_read_all_extra
    mov rdx, -1
    jmp vfs_read_remote

# vfs_read_limited(path, max) -> as file_read_limited: EFBIG past max, no allocation of it
FN vfs_read_limited
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je file_read_limited
    mov rdx, rsi
    xor esi, esi
    jmp vfs_read_remote

# vfs_read_remote(path, extra, max): the host's file in VFS_CHUNK parts; a regular file only
vfs_read_remote:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi                # extra
    mov r13, rdx                # max (-1: any)
    mov rdi, rbx
    call vfs_stat
    test rax, rax
    js 8f
    mov eax, [rip + vfs_statbuf + 24]
    and eax, 0xf000
    cmp eax, 0x8000
    je 1f
    mov rax, -21                # EISDIR
    cmp eax, 0x4000
    je 8f
    mov rax, -22                # a FIFO or a device would never end
    jmp 8f
1:  mov rax, [rip + vfs_statbuf + 48]
    cmp rax, r13
    jbe 2f
    mov rax, -27                # EFBIG
    jmp 8f
2:  lea rdi, [rip + vfs_acc]
    call sb_clear
    xor r14d, r14d              # offset
3:  lea rdi, [rip + vfs_line_read]
    call vfs_line_start
    mov rdi, r14
    call vfs_line_num
    mov edi, VFS_CHUNK
    call vfs_line_num
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call vfs_line_call
    test rax, rax
    js 8f
    mov r15, [rip + g_remote_reply + SB_len]
    add r14, r15
    cmp r14, r13
    jbe 4f
    mov rax, -27
    jmp 8f
4:  lea rdi, [rip + vfs_acc]
    mov rsi, [rip + g_remote_reply + SB_ptr]
    mov rdx, r15
    call sb_push
    cmp r15, VFS_CHUNK
    je 3b
    # the text with room for extra bytes after it
    mov r14, [rip + vfs_acc + SB_len]
    lea rdi, [r14 + r12 + 1]
    call mem_alloc
    mov r15, rax
    mov rdi, rax
    mov rsi, [rip + vfs_acc + SB_ptr]
    mov rdx, r14
    call memcpy
    mov byte ptr [r15 + r14], 0
    lea rdi, [rip + vfs_acc]
    call sb_free
    mov rax, r15
    mov rdx, r14
    EPILOGUE
8:  mov rdx, rax
    xor eax, eax
    EPILOGUE

# vfs_read_at(path, offset, max) -> rax at most max bytes of the file from offset (mem_alloc'd,
#   NUL-terminated), rdx their length; rax 0 and rdx -errno on failure (the agents panel's transcripts)
FN vfs_read_at
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    jne 5f
    call file_open_read
    test rax, rax
    js 8f
    mov r14d, eax
    lea rdi, [r13 + 1]
    call mem_alloc
    mov r15, rax
    xor ebx, ebx
1:  cmp rbx, r13
    jae 3f
    mov edi, r14d
    lea rsi, [r15 + rbx]
    mov rdx, r13
    sub rdx, rbx
    lea r10, [r12 + rbx]
    mov eax, 17                 # pread64
    XSYS
    cmp rax, -EINTR
    je 1b
    test rax, rax
    js 2f
    jz 3f
    add rbx, rax
    jmp 1b
2:  mov rbx, rax
    mov edi, r14d
    SYS SYS_close
    mov rdi, r15
    call mem_free
    mov rax, rbx
    jmp 8f
3:  mov byte ptr [r15 + rbx], 0
    mov edi, r14d
    SYS SYS_close
    mov rax, r15
    mov rdx, rbx
    EPILOGUE
5:  # the host's file, in parts
    lea rdi, [rip + vfs_acc]
    call sb_clear
6:  mov rax, [rip + vfs_acc + SB_len]
    cmp rax, r13
    jae 7f
    lea rdi, [rip + vfs_line_read]
    call vfs_line_start
    mov rdi, r12
    add rdi, [rip + vfs_acc + SB_len]
    call vfs_line_num
    mov rdi, r13
    sub rdi, [rip + vfs_acc + SB_len]
    cmp rdi, VFS_CHUNK
    jbe 61f
    mov edi, VFS_CHUNK
61: call vfs_line_num
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call vfs_line_call
    test rax, rax
    js 8f
    mov r14, [rip + g_remote_reply + SB_len]
    lea rdi, [rip + vfs_acc]
    mov rsi, [rip + g_remote_reply + SB_ptr]
    mov rdx, r14
    call sb_push
    test r14, r14
    jz 7f
    cmp r14, VFS_CHUNK
    je 6b
7:  mov r14, [rip + vfs_acc + SB_len]
    lea rdi, [r14 + 1]
    call mem_alloc
    mov r15, rax
    mov rdi, rax
    mov rsi, [rip + vfs_acc + SB_ptr]
    mov rdx, r14
    call memcpy
    mov byte ptr [r15 + r14], 0
    mov rax, r15
    mov rdx, r14
    EPILOGUE
8:  mov rdx, rax
    xor eax, eax
    EPILOGUE

# vfs_read_head(path, buf, max) -> bytes of the file's start read into buf (at most max), or -errno
FN vfs_read_head
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    jne 5f
    call file_open_read
    test rax, rax
    js 9f
    mov r14d, eax
    mov edi, eax
    mov rsi, r12
    mov rdx, r13
    SYS SYS_read
    mov r15, rax
    mov edi, r14d
    SYS SYS_close
    mov rax, r15
    EPILOGUE
5:  lea rdi, [rip + vfs_line_read]
    call vfs_line_start
    xor edi, edi
    call vfs_line_num
    mov rdi, r13
    call vfs_line_num
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call vfs_line_call
    test rax, rax
    js 9f
    mov rdx, [rip + g_remote_reply + SB_len]
    cmp rdx, r13
    jbe 6f
    mov rdx, r13
6:  mov r14, rdx
    mov rdi, r12
    mov rsi, [rip + g_remote_reply + SB_ptr]
    call memcpy
    mov rax, r14
9:  EPILOGUE

# vfs_write_all(path, ptr, len) -> as file_write_all: 0 or -errno. On the host a file replaced keeps
#   its mode (the agent writes a temporary file and renames it over); a big one goes in parts into a
#   temporary file created exclusively next to the file its links lead to, with that file's mode,
#   and then renamed over it
FN vfs_write_all
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je file_write_all
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    call strlen
    mov r14, rax                # path length
    cmp r13, VFS_ONE_WRITE
    ja .Lvw_parts
    mov edi, 1
    mov esi, 0644
    call vfs_write_req
    EPILOGUE
.Lvw_parts:
    # the file its links lead to (a new one: the path as given), and its mode
    mov rdi, rbx
    lea rsi, [rip + vfs_real]
    call vfs_realpath
    test rax, rax
    jle 1f
    lea rbx, [rip + vfs_real]
1:  mov r15, rbx                # the file replaced
    mov dword ptr [rsp + 16], 0644
    mov dword ptr [rsp + 20], 2         # create only
    mov rdi, r15
    call vfs_stat
    test rax, rax
    js 2f
    mov eax, [rip + vfs_statbuf + 24]
    and eax, 07777
    mov [rsp + 16], eax
    mov dword ptr [rsp + 20], 2 | 16    # and that mode exactly
2:  # PATH.rhun-save, else PATH.rhun-save-N: made here, never an existing file or link
    mov qword ptr [rsp + 24], 0
3:  mov rdi, r15
    mov rsi, [rsp + 24]
    call vfs_save_tmp
    test rax, rax
    jz 8f
    lea rbx, [rip + vfs_tmp]
    mov rdi, rbx
    call strlen
    mov r14, rax
    mov rax, r13
    cmp rax, VFS_ONE_WRITE
    jbe 31f
    mov eax, VFS_ONE_WRITE
31: mov [rsp + 8], rax
    mov edi, [rsp + 20]
    mov esi, [rsp + 16]
    push r13
    push r13
    mov r13, [rsp + 24]
    call vfs_write_req
    pop r13
    pop r13
    cmp rax, -17                # EEXIST: the next name
    jne 32f
    inc qword ptr [rsp + 24]
    cmp qword ptr [rsp + 24], 100
    jb 3b
    jmp 9f
32: test rax, rax
    js 9f                       # the agent removes a file it made and could not fill (ragent.s);
                                #   an answer that never came proves no create, so nothing goes here
    mov rax, [rsp + 8]
    mov [rsp], rax              # written
4:  mov rax, r13
    sub rax, [rsp]
    jz 6f
    cmp rax, VFS_ONE_WRITE
    jbe 5f
    mov eax, VFS_ONE_WRITE
5:  mov [rsp + 8], rax
    push r12
    push r13
    add r12, [rsp + 16]
    mov r13, [rsp + 24]
    mov edi, 4                  # append
    xor esi, esi
    call vfs_write_req
    pop r13
    pop r12
    test rax, rax
    js 7f
    mov rax, [rsp + 8]
    add [rsp], rax
    jmp 4b
6:  mov rdi, rbx
    mov rsi, r15
    xor edx, edx
    call vfs_rename
    test rax, rax
    js 7f
    xor eax, eax
    EPILOGUE
7:  mov [rsp], rax
    mov rdi, rbx
    call vfs_unlink
    mov rax, [rsp]
    EPILOGUE
8:  mov rax, -36
    EPILOGUE
9:  test rax, rax
    js 91f
    mov rax, -17
91: EPILOGUE

# vfs_save_tmp(path, n) -> vfs_tmp holding PATH.rhun-save (n 0) or PATH.rhun-save-N, or 0 when too long
vfs_save_tmp:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    lea rsi, [rip + .Lsave_suffix]
    call vfs_cat_tmp
    test rax, rax
    jz 9f
    test r12, r12
    jz 9f
    lea rdi, [rip + vfs_tmp]
    call strlen
    cmp rax, 4080
    jae 8f
    lea rdi, [rip + vfs_tmp]
    add rdi, rax
    mov byte ptr [rdi], '-'
    inc rdi
    mov rsi, r12
    call fmt_u64
    mov byte ptr [rdi], 0
    lea rax, [rip + vfs_tmp]
    jmp 9f
8:  xor eax, eax
9:  add rsp, 8
    pop r12
    pop rbx
    ret

# vfs_write_req(flags, mode) with rbx path, r14 its length, r12 data, r13 its length -> as
#   remote_call: write FLAGS MODE PLEN LEN + path + data (MODE in octal)
vfs_write_req:
    push rbx
    push r15
    push rbp
    mov r15d, edi
    mov ebp, esi
    lea rdi, [rip + vfs_line_write]
    call vfs_line_start
    mov edi, r15d
    call vfs_line_num
    mov edi, ebp
    call vfs_line_octal
    mov rdi, r14
    call vfs_line_num
    lea rdi, [rip + vfs_body]
    call sb_clear
    lea rdi, [rip + vfs_body]
    mov rsi, rbx
    mov rdx, r14
    call sb_push
    lea rdi, [rip + vfs_body]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, [rip + vfs_body + SB_ptr]
    mov rsi, [rip + vfs_body + SB_len]
    call vfs_line_call
    push rax
    push rax
    lea rdi, [rip + vfs_body]
    call sb_free                # a big file's bytes are not kept around
    pop rax
    pop rax
    pop rbp
    pop r15
    pop rbx
    ret

# vfs_line_octal(mode): " OOOO" onto vfs_line (the mode's four octal digits)
vfs_line_octal:
    push rbx
    mov ebx, edi
    lea rdi, [rip + vfs_line]
    mov esi, ' '
    call sb_push_byte
    mov ecx, 9
1:  mov eax, ebx
    shr eax, cl
    and eax, 7
    lea esi, [rax + '0']
    push rcx
    push rcx
    lea rdi, [rip + vfs_line]
    call sb_push_byte
    pop rcx
    pop rcx
    sub ecx, 3
    jns 1b
    pop rbx
    ret

# vfs_create_new(path, mode) -> 0 or -errno: an empty file made there, EEXIST when something is there
FN vfs_create_new
    call vfs_remote_path
    test eax, eax
    jne 1f
    push rbx
    mov edx, esi
    mov esi, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
    SYS SYS_open
    test rax, rax
    js 9f
    mov edi, eax
    SYS SYS_close
    xor eax, eax
9:  pop rbx
    ret
1:  PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    call strlen
    mov r14, rax
    lea rdi, [rip + vfs_line_write]
    call vfs_line_start
    mov edi, 2                  # create only
    call vfs_line_num
    # the mode as octal digits
    lea rdi, [rip + vfs_line]
    mov esi, ' '
    call sb_push_byte
    mov eax, r12d
    shr eax, 6
    and eax, 7
    lea esi, [rax + '0']
    lea rdi, [rip + vfs_line]
    call sb_push_byte
    mov eax, r12d
    shr eax, 3
    and eax, 7
    lea esi, [rax + '0']
    lea rdi, [rip + vfs_line]
    call sb_push_byte
    mov eax, r12d
    and eax, 7
    lea esi, [rax + '0']
    lea rdi, [rip + vfs_line]
    call sb_push_byte
    mov rdi, r14
    call vfs_line_num
    mov rdi, rbx
    mov rsi, r14
    call vfs_line_call
    EPILOGUE

# vfs_cat_tmp(a, b) -> vfs_tmp holding a then b, or 0 when too long
vfs_cat_tmp:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    call strlen
    push rax
    mov rdi, r12
    call strlen
    pop rcx
    add rax, rcx
    cmp rax, 4096
    jae 8f
    lea rdi, [rip + vfs_tmp]
    mov rsi, rbx
    call cstr_copy
    mov rdi, rax
    mov rsi, r12
    call cstr_copy
    lea rax, [rip + vfs_tmp]
    jmp 9f
8:  xor eax, eax
9:  add rsp, 8
    pop r12
    pop rbx
    ret

# ---------------- what is there ----------------

# vfs_stats_prefetch(paths, n): remote hosts: the stat of n paths (an array of cstr) in one request;
#   vfs_stat answers them from that until vfs_stats_clear. Nothing locally
FN vfs_stats_prefetch
    cmp dword ptr [rip + g_remote], 0
    je 9f
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + vfs_body]
    call sb_clear
    xor ebx, ebx
1:  cmp rbx, r13
    jae 2f
    lea rdi, [rip + vfs_body]
    mov rsi, [r12 + rbx*8]
    call sb_push_cstr
    lea rdi, [rip + vfs_body]
    xor esi, esi
    call sb_push_byte
    inc rbx
    jmp 1b
2:  lea rdi, [rip + .Lv_stats]
    call vfs_line_start
    mov rdi, [rip + vfs_body + SB_ptr]
    mov rsi, [rip + vfs_body + SB_len]
    call vfs_line_call
    test rax, rax
    js 8f
    # the cache: each path with its answer
    lea rdi, [rip + vfs_cache]
    call sb_clear
    mov r14, [rip + g_remote_reply + SB_ptr]
    mov r15, [rip + g_remote_reply + SB_len]
    add r15, r14
    xor ebx, ebx
3:  cmp rbx, r13
    jae 7f
    cmp r14, r15
    jae 7f
    lea rdi, [rip + vfs_cache]
    mov rsi, [r12 + rbx*8]
    call sb_push_cstr
    lea rdi, [rip + vfs_cache]
    xor esi, esi
    call sb_push_byte
    mov edx, 145
    cmp byte ptr [r14], 'o'
    je 4f
    mov edx, 5
4:  lea rax, [r14 + rdx]
    cmp rax, r15
    ja 7f
    lea rdi, [rip + vfs_cache]
    mov rsi, r14
    push rdx
    push rdx
    call sb_push
    pop rdx
    pop rdx
    add r14, rdx
    inc rbx
    jmp 3b
7:  mov dword ptr [rip + vfs_cache_on], 1
8:  EPILOGUE
9:  ret

# vfs_stats_clear(): vfs_stat asks the host again
FN vfs_stats_clear
    mov dword ptr [rip + vfs_cache_on], 0
    ret

# vfs_cache_find(path) -> rax 1 with the cached stat in vfs_statbuf (rdx 0) or its error (rdx -errno),
#   0 when the path is not cached
vfs_cache_find:
    PROLOGUE
    xor eax, eax
    cmp dword ptr [rip + vfs_cache_on], 0
    je 9f
    mov r12, rdi
    mov rbx, [rip + vfs_cache + SB_ptr]
    mov r13, [rip + vfs_cache + SB_len]
    add r13, rbx
1:  cmp rbx, r13
    jae 8f
    mov rdi, rbx
    call strlen
    lea r14, [rbx + rax + 1]    # the answer
    mov rdi, rbx
    mov rsi, r12
    call strcmp_eq
    mov r15d, eax
    mov ecx, 145
    cmp byte ptr [r14], 'o'
    je 2f
    mov ecx, 5
2:  lea rbx, [r14 + rcx]
    test r15d, r15d
    jz 1b
    cmp byte ptr [r14], 'o'
    jne 3f
    lea rdi, [rip + vfs_statbuf]
    lea rsi, [r14 + 1]
    mov edx, 144
    call memcpy
    xor edx, edx
    mov eax, 1
    EPILOGUE
3:  mov edx, [r14 + 1]
    neg rdx
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# vfs_stat(path) / vfs_lstat(path) -> 0 or -errno, the Linux struct stat in vfs_statbuf
FN vfs_stat
    cmp dword ptr [rip + vfs_cache_on], 0
    je 1f
    push rdi
    call vfs_cache_find
    pop rdi
    test eax, eax
    jz 1f
    mov rax, rdx
    ret
1:  mov r10d, 4                 # stat
    lea rsi, [rip + .Lv_stat]
    jmp vfs_stat_common
FN vfs_lstat
    mov r10d, SYS_lstat
    lea rsi, [rip + .Lv_lstat]
vfs_stat_common:
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    jne 1f
    mov eax, r10d
    lea rsi, [rip + vfs_statbuf]
    XSYS
    ret
1:  push rbx
    xchg rdi, rsi
    call vfs_req_path
    test rax, rax
    js 9f
    lea rdi, [rip + vfs_statbuf]
    mov rsi, [rip + g_remote_reply + SB_ptr]
    mov rdx, [rip + g_remote_reply + SB_len]
    cmp rdx, 144
    jbe 2f
    mov edx, 144
2:  call memcpy
    xor eax, eax
9:  pop rbx
    ret

# vfs_stamp(path) -> as file_stamp: mtime and size mixed (0 when missing), rdx the size, rcx the mtime
FN vfs_stamp
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je file_stamp
    sub rsp, 8
    call vfs_stat
    add rsp, 8
    test rax, rax
    js 1f
    mov rax, [rip + vfs_statbuf + 88]
    imul rax, rax, 1000000000
    add rax, [rip + vfs_statbuf + 96]
    mov rcx, rax
    mov rdx, [rip + vfs_statbuf + 48]
    rol rdx, 32
    xor rax, rdx
    ror rdx, 32
    ret
1:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    ret

# vfs_missing(path) -> as file_missing
FN vfs_missing
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je file_missing
    sub rsp, 8
    call vfs_lstat
    add rsp, 8
    xor ecx, ecx
    cmp rax, -2
    sete cl
    cmp rax, -20
    jne 1f
    mov ecx, 1
1:  mov eax, ecx
    ret

# vfs_mtime(path) -> as file_mtime (lstat, seconds)
FN vfs_mtime
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je file_mtime
    sub rsp, 8
    call vfs_lstat
    add rsp, 8
    test rax, rax
    js 1f
    mov rax, [rip + vfs_statbuf + 88]
    ret
1:  xor eax, eax
    ret

# vfs_mtime_ns(path) -> as file_mtime_ns (lstat)
FN vfs_mtime_ns
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je file_mtime_ns
    sub rsp, 8
    call vfs_lstat
    add rsp, 8
    test rax, rax
    js 1f
    mov rax, [rip + vfs_statbuf + 88]
    imul rax, rax, 1000000000
    add rax, [rip + vfs_statbuf + 96]
    ret
1:  xor eax, eax
    ret

# vfs_is_dir(path) -> as file_is_dir (follows links)
FN vfs_is_dir
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je file_is_dir
    sub rsp, 8
    call vfs_stat
    add rsp, 8
    test rax, rax
    js 1f
    mov eax, [rip + vfs_statbuf + 24]
    and eax, 0xf000
    cmp eax, 0x4000
    sete al
    movzx eax, al
    ret
1:  xor eax, eax
    ret

# vfs_type(path) -> as file_type: the S_IFMT bits, 0 when missing (follows links)
FN vfs_type
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je file_type
    sub rsp, 8
    call vfs_stat
    add rsp, 8
    test rax, rax
    js 1f
    mov eax, [rip + vfs_statbuf + 24]
    and eax, 0xf000
    ret
1:  xor eax, eax
    ret

# vfs_id(path) -> as file_id: rax inode, rdx device
FN vfs_id
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je file_id
    sub rsp, 8
    call vfs_stat
    add rsp, 8
    test rax, rax
    js 1f
    mov rax, [rip + vfs_statbuf + 8]
    mov rdx, [rip + vfs_statbuf]
    ret
1:  xor eax, eax
    xor edx, edx
    ret

# vfs_access(path, mode) -> 0 or -errno, access(2)
FN vfs_access
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    jne 1f
    SYS SYS_access
    ret
1:  push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [rip + .Lv_access]
    call vfs_line_start
    mov edi, r12d
    call vfs_line_num
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call vfs_line_call
    add rsp, 8
    pop r12
    pop rbx
    ret

# vfs_readlink(path, buf, cap) -> as readlink(2): the link's text in buf (not NUL-terminated, cut at
#   cap), its length, or -errno (-EINVAL when path is no symlink)
FN vfs_readlink
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    jne 1f
.ifdef WINDOWS
    jmp win_readlink_one
.else
    SYS SYS_readlink
    ret
.endif
1:  push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r12, rdx
    mov rsi, rdi
    lea rdi, [rip + .Lv_readlink]
    call vfs_req_path
    test rax, rax
    js 9f
    mov rdx, [rip + g_remote_reply + SB_len]
    cmp rdx, r12
    jbe 2f
    mov rdx, r12
2:  mov r13, rdx
    mov rdi, rbx
    mov rsi, [rip + g_remote_reply + SB_ptr]
    call memcpy
    mov rax, r13
9:  pop r13
    pop r12
    pop rbx
    ret

# vfs_watch(path, mask) -> the host's watch descriptor or -errno (events: vfs_remote_event)
FN vfs_watch
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [rip + .Lv_watch]
    call vfs_line_start
    mov edi, r12d
    call vfs_line_num
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call vfs_line_call
    test rax, rax
    js 9f
    mov rdi, [rip + g_remote_reply + SB_ptr]
    mov rsi, [rip + g_remote_reply + SB_len]
    call parse_u64
9:  add rsp, 8
    pop r12
    pop rbx
    ret

# vfs_unwatch(wd): the host's watch ends (nothing waits for the answer)
FN vfs_unwatch
    push rbx
    mov ebx, edi
    lea rdi, [rip + .Lv_unwatch]
    call vfs_line_start
    mov edi, ebx
    call vfs_line_num
    mov rdi, [rip + vfs_line + SB_ptr]
    call remote_request_async
    pop rbx
    ret

# vfs_realpath(path, buf 4096) -> length of the resolved path in buf (NUL-terminated), or -errno
FN vfs_realpath
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    jne 1f
# local_realpath(path, buf 4096) -> as vfs_realpath, always on this machine (remoteext.s: a linked
#   extension folder may be anywhere)
FN local_realpath
.ifdef MACOS
    push rsi
    SYS SYS_realpath
    pop rdi
    test rax, rax
    jz 7f
    jmp strlen
7:  mov rax, -2
    ret
.else
    PROLOGUE
    mov r12, rsi
.ifdef WINDOWS
    mov edx, 4096
    call win_realpath
    test rax, rax
    js 9f
    mov rdi, r12
    call strlen
    EPILOGUE
.endif
    mov esi, O_PATH | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 9f
    mov ebx, eax
    lea rdi, [rip + vfs_tmp]
    lea rsi, [rip + .Lproc_fd]
    call cstr_copy
    mov rdi, rax
    mov esi, ebx
    call fmt_u64
    mov byte ptr [rdi], 0
    lea rdi, [rip + vfs_tmp]
    mov rsi, r12
    mov edx, 4095
    SYS SYS_readlink
    mov r13, rax
    mov edi, ebx
    SYS SYS_close
    mov rax, r13
    test rax, rax
    js 9f
    mov byte ptr [r12 + rax], 0
9:  EPILOGUE
.endif
1:  push rbx
    mov rbx, rsi
    mov rsi, rdi
    lea rdi, [rip + .Lv_realpath]
    call vfs_req_path
    test rax, rax
    js 9f
    mov rdx, [rip + g_remote_reply + SB_len]
    cmp rdx, 4095
    jae 8f
    mov rdi, rbx
    mov rsi, [rip + g_remote_reply + SB_ptr]
    push rdx
    push rdx
    call memcpy
    pop rax
    pop rax
    mov byte ptr [rbx + rax], 0
    jmp 9f
8:  mov rax, -36
9:  pop rbx
    ret

# ---------------- folders ----------------

# vfs_dir_each(path, cb, ctx) -> as dir_each: cb(ctx, name, is_dir) for each entry, folders through
#   links counting as folders
FN vfs_dir_each
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je dir_each
    xor ecx, ecx
    jmp vfs_list

# vfs_dir_each_names(path, cb, ctx) -> as dir_each_names
FN vfs_dir_each_names
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je dir_each_names
    mov ecx, 1
vfs_list:
    PROLOGUE 16
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
    mov rsi, rdi
    lea rdi, [rip + .Lv_list]
    call vfs_req_path
    test rax, rax
    js 9f
    # the answer is copied: a callback may make requests of its own
    mov rdi, [rip + g_remote_reply + SB_ptr]
    mov rsi, [rip + g_remote_reply + SB_len]
    call mem_dup
    mov r14, rax
    mov r15, [rip + g_remote_reply + SB_len]
    add r15, rax                # end
    mov rbx, rax
1:  cmp rbx, r15
    jae 8f
    lea rsi, [rbx + 2]          # "T NAME\0"
    movzx edx, byte ptr [rbx]
    xor eax, eax
    cmp edx, 'd'
    sete al
    cmp edx, 'L'
    jne 2f
    mov eax, 1
2:  mov edx, eax
    cmp dword ptr [rsp], 0
    je 3f
    xor edx, edx
3:  mov rdi, rsi
    push rsi
    push rdx
    call strlen
    pop rdx
    pop rsi
    lea rbx, [rsi + rax + 1]
    mov rdi, r13
    call r12
    jmp 1b
8:  mov rdi, r14
    call mem_free
    xor eax, eax
9:  EPILOGUE

# vfs_walk_body(root, query or 0, query len): vfs_body = "ROOT\0EXCLUDES[\0QUERY]" for files and grep
vfs_walk_body:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + vfs_body]
    call sb_clear
    lea rdi, [rip + vfs_body]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + vfs_body]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rip + vfs_body]
    mov rsi, [rip + cfg_exclude]
    call sb_push_cstr
    test r12, r12
    jz 1f
    lea rdi, [rip + vfs_body]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rip + vfs_body]
    mov rsi, r12
    mov rdx, r13
    call sb_push
1:  pop r13
    pop r12
    pop rbx
    ret

# vfs_files(root, max) -> rax the host's files under root relative to it, each with a NUL (in
#   g_remote_reply, valid until the next request), rdx their bytes; rax 0 on failure. Go to File in a
#   remote window: one request, the host walks the project as quick open does here
FN vfs_files
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    xor esi, esi
    xor edx, edx
    call vfs_walk_body
    lea rdi, [rip + .Lv_files]
    call vfs_line_start
    mov rdi, r12
    call vfs_line_num
    mov rdi, [rip + vfs_body + SB_ptr]
    mov rsi, [rip + vfs_body + SB_len]
    call vfs_line_call
    test rax, rax
    js 8f
    mov rax, [rip + g_remote_reply + SB_ptr]
    mov rdx, [rip + g_remote_reply + SB_len]
    test rax, rax
    jnz 9f
8:  xor eax, eax
    xor edx, edx
9:  add rsp, 8
    pop r12
    pop rbx
    ret

# vfs_grep(root, query, len, max, case, cb, ctx) -> request id or 0: find in files on the host; cb(ctx,
#   status, records, len) later with "REL\0LINE\0COL\0LABEL\0" for each line (remote_request_cb)
FN vfs_grep
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15d, r8d
    mov [rsp], r9
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call vfs_walk_body
    lea rdi, [rip + .Lv_grep]
    call vfs_line_start
    mov rdi, r14
    call vfs_line_num
    mov edi, r15d
    call vfs_line_num
    mov rdi, [rip + vfs_line + SB_ptr]
    mov rsi, [rip + vfs_line + SB_len]
    mov rdx, [rip + vfs_body + SB_ptr]
    mov rcx, [rip + vfs_body + SB_len]
    mov r8, [rsp]
    mov r9, [rbp + 16]
    call remote_request_cb
    EPILOGUE

# vfs_mkdir(path, mode) -> 0 or -errno
FN vfs_mkdir
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    jne 1f
    SYS SYS_mkdir
    ret
1:  xor esi, esi
    jmp vfs_mkdir_req

# vfs_mkdir_p(path): the folder and those on the way (as mkdir_p)
FN vfs_mkdir_p
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je mkdir_p
    mov esi, 1
vfs_mkdir_req:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [rip + .Lv_mkdir]
    call vfs_line_start
    mov edi, r12d
    call vfs_line_num
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call vfs_line_call
    add rsp, 8
    pop r12
    pop rbx
    ret

# vfs_mkdir_parent(path): the folders a file's path lives in (as mkdir_parent)
FN vfs_mkdir_parent
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je mkdir_parent
    push rbx
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call path_dirlen
    test rax, rax
    jz 9f
    cmp rax, 4095
    jae 9f
    lea rdi, [rip + vfs_tmp]
    mov rsi, rbx
    mov rdx, rax
    push rax
    push rax
    call memcpy
    pop rax
    pop rax
    lea rdi, [rip + vfs_tmp]
    mov byte ptr [rdi + rax], 0
    call vfs_mkdir_p
9:  pop rbx
    ret

# vfs_remove_tree(path) -> as file_remove_tree
FN vfs_remove_tree
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    je file_remove_tree
    mov esi, 1
    jmp vfs_remove_req

# vfs_unlink(path) / vfs_rmdir(path) -> 0 or -errno (the host's remove does either)
FN vfs_unlink
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    jne 1f
    SYS SYS_unlink
    ret
1:  xor esi, esi
    jmp vfs_remove_req
FN vfs_rmdir
    call vfs_remote_path        # 0: this path is here (not remote, or rhun's own)
    test eax, eax
    jne 1f
    mov eax, 84                 # rmdir
    XSYS
    ret
1:  xor esi, esi
vfs_remove_req:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [rip + .Lv_remove]
    call vfs_line_start
    mov edi, r12d
    call vfs_line_num
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call vfs_line_call
    add rsp, 8
    pop r12
    pop rbx
    ret

# vfs_rename(old, new, flags) -> 0 or -errno; flags 1 refuses an existing destination (on the host
#   with renameat2; here it looks first)
FN vfs_rename
    call vfs_remote_paths2      # 0: both here; -EXDEV when one is here and one on the host
    test eax, eax
    jne 1f
    test edx, 1
    jz 2f
    push rdi
    push rsi
    mov rdi, rsi
    call file_missing
    pop rsi
    pop rdi
    test eax, eax
    jnz 2f
    mov rax, -17                # EEXIST
    ret
2:  SYS SYS_rename
    ret
1:  PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    lea rdi, [rip + .Lv_rename]
    call vfs_line_start
    mov edi, r13d
    call vfs_line_num
    mov rdi, rbx
    call strlen
    mov r14, rax
    mov rdi, rax
    call vfs_line_num
    lea rdi, [rip + vfs_body]
    call sb_clear
    lea rdi, [rip + vfs_body]
    mov rsi, rbx
    mov rdx, r14
    call sb_push
    lea rdi, [rip + vfs_body]
    mov rsi, r12
    call sb_push_cstr
    mov rdi, [rip + vfs_body + SB_ptr]
    mov rsi, [rip + vfs_body + SB_len]
    call vfs_line_call
    EPILOGUE

# ---------------- programs ----------------

# vfs_run_piped(argv, envp, cwd) -> as run_piped
FN vfs_run_piped
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    jmp vfs_run_piped_input

# vfs_run_piped_input(argv, envp, cwd, ptr, len, errors) -> as run_piped_input: rax pid or -errno,
#   edx the descriptor to read the program's output from. In a remote window the program runs on
#   the host, found by its name in the host's PATH.
FN vfs_run_piped_input
    cmp dword ptr [rip + g_remote], 0
    je run_piped_input
    push rbx
    mov rbx, r8                 # input length
    mov r10d, r9d               # errors: 1 merges them with the output, else /dev/null
    mov r9, rcx                 # input
    mov r8d, -1
    test r10d, 1
    jz 1f
    mov r8d, -2
1:  xor ecx, ecx                # flags: a pipe, argv[0] by name
    push rbx
    push rbx
    call remote_spawn
    add rsp, 16
    pop rbx
    ret

# vfs_pty_spawn(argv, envp, cwd, cols, rows) -> rax pid (or -errno), edx the master (nonblocking).
#   In a remote window an empty argv (argv[0] == 0 or "") is the user's shell on the host.
FN vfs_pty_spawn
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    cmp dword ptr [rip + g_remote], 0
    jne 5f
.ifdef WINDOWS
    mov rax, -38
    EPILOGUE
.else
    mov edi, ecx
    mov esi, r8d
    call pty_open
    test eax, eax
    js 8f
    mov ebx, eax                # master
    mov r15d, edx               # slave
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov ecx, r15d
    mov r8d, r15d
    mov r9d, r15d
    push 1
    push 1
    call proc_spawn
    add rsp, 16
    mov [rsp + 8], rax
    mov edi, r15d
    SYS SYS_close
    mov rax, [rsp + 8]
    test rax, rax
    jg 2f
    mov edi, ebx
    SYS SYS_close
    mov rax, [rsp + 8]
    test rax, rax
    jnz 9f
    mov rax, -5
    EPILOGUE
2:  mov edx, ebx
    EPILOGUE
8:  mov rax, -5
    EPILOGUE
.endif
5:  # flags: a pty, columns in bits 8-23, rows from bit 24
    mov ecx, [rsp]
    and ecx, 0xffff
    shl ecx, 8
    mov eax, [rsp + 4]
    and eax, 0xff
    shl eax, 24
    or ecx, eax
    or ecx, 1
    test r12, r12               # argv[0] with a "/" is a path on the host, kept as given (a configured
    jz 7f                       #   program's, such as Claude: Open in Terminal's); a name is looked up
    mov rax, [r12]              #   in the host's PATH
    test rax, rax
    jz 7f
6:  movzx edx, byte ptr [rax]
    inc rax
    test edx, edx
    jz 7f
    cmp edx, '/'
    jne 6b
    or ecx, 2
7:  mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov r8d, -1
    xor r9d, r9d
    push 0
    push 0
    call remote_spawn
    add rsp, 16
9:  EPILOGUE

# vfs_uproc_spawn(argv, envp, cwd, cols, rows, flags) -> as uproc_spawn, on the host: rax the pid (or
#   -errno), edx the descriptor (the pty's master, or the program's input and output), ecx its error
#   output's (flags 2) or -1. flags: 1 a pty of cols x rows, 2 the error output apart, 4 the program
#   is uproc's from then on (uproc_signal, uproc_wait, uproc_end); without 4 the caller waits for it
#   with proc_wait and signals it with proc_kill; 8 argv[0] is a path on the host (else its name is
#   looked up in the host's PATH)
FN vfs_uproc_spawn
    PROLOGUE 16
    mov eax, [rbp + 16]
    mov [rsp], eax              # flags
    test eax, 1
    jz 1f
    and ecx, 0xffff
    shl ecx, 8
    and r8d, 0xff
    shl r8d, 24
    or ecx, r8d
    or ecx, 1
    mov r8d, -1
    jmp 2f
1:  xor ecx, ecx
    mov r8d, -2                 # merged with the output
    test eax, 2
    jz 2f
    mov r8d, -3                 # a socket of its own
2:  test eax, 8
    jz 3f
    or ecx, 2                   # argv[0] a path on the host, kept as given
3:  xor r9d, r9d
    push 0
    push 0
    call remote_spawn
    add rsp, 16
    mov rbx, rax
    mov r12d, edx
    mov r13d, ecx
    test rax, rax
    jle 9f
    test dword ptr [rsp], 4
    jz 9f
    mov edi, eax
    call uproc_adopt
9:  mov rax, rbx
    mov edx, r12d
    mov ecx, r13d
    test dword ptr [rsp], 2
    jnz 8f
    mov ecx, -1
8:  EPILOGUE

# ---------------- watch events from the host ----------------

# vfs_remote_event(wd, mask, name ptr, len): an inotify event of a remote watch; kept for vfs_tick
#   (it comes in the middle of the stream's parsing, where nothing else may run)
FN vfs_remote_event
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    cmp qword ptr [rip + vfs_pending + SB_len], 4194304
    jae 9f                      # nobody takes them: drop
    lea rdi, [rip + vfs_pending]
    mov esi, 16
    call sb_reserve
    mov [rax], ebx
    mov [rax + 4], r12d
    mov [rax + 8], r14
    add qword ptr [rip + vfs_pending + SB_len], 16
    lea rdi, [rip + vfs_pending]
    mov rsi, r13
    mov rdx, r14
    call sb_push
9:  EPILOGUE

# vfs_pending_events() -> eax 1 while watch events wait for vfs_tick
FN vfs_pending_events
    xor eax, eax
    cmp qword ptr [rip + vfs_pending + SB_len], 0
    setne al
    ret

# vfs_remote_lost(): the connection went: pending events are stale
FN vfs_remote_lost
    sub rsp, 8
    lea rdi, [rip + vfs_pending]
    call sb_clear
    add rsp, 8
    ret

# vfs_reconnected(): connected again after a loss: the watches are made again on the host and open
#   files compared with it
FN vfs_reconnected
    jmp watch_remote_renew

# vfs_tick(): the watch events that came from the host go to watch.s, as inotify events with their
#   descriptors tagged (struct inotify_event: wd, mask, cookie, len, the name padded with NULs)
FN vfs_tick
    PROLOGUE
    cmp qword ptr [rip + vfs_pending + SB_len], 0
    je 9f
    # taken out first: the handlers make requests, during which more events arrive
    lea rdi, [rip + vfs_events]
    call sb_free
    lea rsi, [rip + vfs_pending]
    lea rdi, [rip + vfs_events]
    mov edx, SB_SIZE
    call memcpy
    lea rdi, [rip + vfs_pending]
    xor esi, esi
    mov edx, SB_SIZE
    call memset
    call watch_evbuf
    mov r15, rax
    xor r12d, r12d              # read position in vfs_pending
1:  xor r13d, r13d              # bytes in the buffer
2:  mov rax, [rip + vfs_events + SB_len]
    sub rax, r12
    cmp rax, 16
    jb 5f
    mov rbx, [rip + vfs_events + SB_ptr]
    add rbx, r12
    mov r14, [rbx + 8]          # the name's length
    cmp r14, 255
    jbe 3f
    mov r14d, 255
3:  lea rax, [r14 + 4]
    and rax, -4                 # the name, its NUL and padding
    lea rcx, [rax + 16]
    lea rdx, [r13 + rcx]
    cmp rdx, 16384
    ja 4f                       # full: this batch goes first
    mov ecx, [rbx]
    or ecx, 0x40000000          # WD_REMOTE
    mov [r15 + r13], ecx
    mov ecx, [rbx + 4]
    mov [r15 + r13 + 4], ecx
    mov dword ptr [r15 + r13 + 8], 0
    mov [r15 + r13 + 12], eax
    lea rdi, [r15 + r13 + 16]
    push rax
    push rax
    mov rdx, rax
    xor esi, esi
    call memset
    lea rdi, [r15 + r13 + 16]
    lea rsi, [rbx + 16]
    mov rdx, r14
    call memcpy
    pop rax
    pop rax
    lea r13, [r13 + rax + 16]
    mov rax, [rbx + 8]
    lea r12, [r12 + rax + 16]
    jmp 2b
4:  mov edi, r13d
    call watch_remote_events
    test r13, r13
    jnz 1b
5:  mov edi, r13d
    call watch_remote_events
    lea rdi, [rip + vfs_events]
    call sb_clear
9:  EPILOGUE

.section .rodata
.Lv_stat: .asciz "stat"
.Lhome_env: .asciz "HOME"
.Lv_lstat: .asciz "lstat"
.Lv_list: .asciz "list"
.Lv_access: .asciz "access"
.Lv_realpath: .asciz "realpath"
.Lv_mkdir: .asciz "mkdir"
.Lv_remove: .asciz "remove"
.Lv_rename: .asciz "rename"
.Lv_readlink: .asciz "readlink"
.Lv_watch: .asciz "watch"
.Lv_files: .asciz "files"
.Lv_stats: .asciz "stats"
.Lv_grep: .asciz "grep"
.Lv_unwatch: .asciz "unwatch"
vfs_line_read: .asciz "read"
vfs_line_write: .asciz "write"
.Lsave_suffix: .asciz ".rhun-save"
.Lsnap_prefix: .asciz ".rhun-opencode-"
.Lproc_fd: .asciz "/proc/self/fd/"
.text

# remote_strict_check(rdi path): with RHUN_REMOTE_STRICT=1, a local file function (sys.s) given a path
#   inside a remote window's project stops rhun with the path and the caller's address (for
#   addr2line): a call site that should use vfs. Keeps every register.
FN remote_strict_check
    cmp dword ptr [rip + g_remote_strict], 0
    jne 1f
    ret
1:  push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rbx
    push rbp
    mov rbp, rsp
    and rsp, -16
    mov rbx, rdi
    cmp dword ptr [rip + g_remote], 0
    je 9f
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 9f
    test rbx, rbx
    jz 9f
    xor ecx, ecx
2:  mov al, [rsi + rcx]
    test al, al
    jz 3f
    cmp al, [rbx + rcx]
    jne 9f
    inc rcx
    jmp 2b
3:  mov al, [rbx + rcx]
    test al, al
    jz 4f
    cmp al, '/'
    jne 9f
4:  lea rdi, [rip + .Lstrict_msg]
    call log_cstr
    mov rdi, rbx
    call log_cstr
    lea rdi, [rip + .Lstrict_from]
    call log_cstr
    mov rsi, [rbp + 96]         # the file function's caller
    lea rdi, [rip + vfs_tmp]
    call fmt_hex
    lea rdi, [rip + vfs_tmp]
    mov rsi, rax
    call log_write
    call log_nl
    mov edi, 99
    call sys_exit
9:  mov rsp, rbp
    pop rbp
    pop rbx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

.section .rodata
.Lstrict_msg: .asciz "rhun: RHUN_REMOTE_STRICT: a local file function got the workspace path "
.Lstrict_from: .asciz " from 0x"
.text
