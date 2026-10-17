# Windows implementations of the small Linux syscall surface used by the editor.
.include "win.inc"

.text
FN ws_nosys
    mov rax, -38
    ret
FN ws_zero
    xor eax, eax
    ret
FN ws_exit
    sub rsp, 40
    mov ecx, edi
    API ExitProcess
FN ws_mmap
    PROLOGUE 96
    test ecx, MAP_ANONYMOUS
    jz 8f
    xor ecx, ecx
    mov rdx, rsi
    mov r8d, 0x3000
    mov r9d, 4
    API VirtualAlloc
    test rax, rax
    jnz 9f
8:  mov rax, -12
9:  EPILOGUE
FN ws_munmap
    PROLOGUE 96
    mov rcx, rdi
    xor edx, edx
    mov r8d, 0x8000
    API VirtualFree
    test eax, eax
    jz 1f
    xor eax, eax
    EPILOGUE
1:  call win_error
    EPILOGUE
FN ws_pid
    sub rsp, 40
    API GetCurrentProcessId
    add rsp, 40
    ret
FN ws_clock
    PROLOGUE 112
    mov rbx, rsi
    test edi, edi
    jz 1f
    API GetTickCount64
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [rbx], rax
    imul rdx, rdx, 1000000
    mov [rbx + 8], rdx
    jmp 9f
1:  lea rcx, [rsp + 96]
    API GetSystemTimeAsFileTime
    mov rax, [rsp + 96]
    call win_filetime
    mov [rbx], rax
    mov [rbx + 8], rdx
9:  xor eax, eax
    EPILOGUE
# FILETIME in rax -> seconds rax, nanoseconds rdx
FN win_filetime
    mov rcx, 116444736000000000
    sub rax, rcx
    xor edx, edx
    mov ecx, 10000000
    div rcx
    imul rdx, rdx, 100
    ret
FN ws_sleep
    PROLOGUE 96
    mov rcx, [rdi]
    imul rcx, rcx, 1000
    mov rax, [rdi + 8]
    xor edx, edx
    mov r8d, 1000000
    div r8
    add rcx, rax
    API Sleep
    xor eax, eax
    EPILOGUE

FN ws_open
    PROLOGUE 96
    mov r12d, esi
    # The core uses /dev/null for detached child stdio.
    mov rbx, rdi
    lea rsi, [rip + .Lnull]
    call strcmp_eq
    test eax, eax
    jz 1f
    lea rbx, [rip + .Lnul]
1:  mov rdi, rbx
    call win_file_path
    mov rbx, rax
    test rax, rax
    jz .Lopen_invalid
    mov rcx, rbx
    mov edx, 0x80000000
    mov eax, r12d
    and eax, 3
    cmp eax, 1
    jne 2f
    mov edx, 0x40000000
2:  cmp eax, 2
    jne 3f
    mov edx, 0xc0000000
3:  mov r8d, 7                 # share read/write/delete: saves may atomically replace open files
    xor r9d, r9d
    mov eax, 3                 # OPEN_EXISTING
    test r12d, O_CREAT
    jz 4f
    mov eax, 4                 # OPEN_ALWAYS
    test r12d, O_EXCL
    jz 4f
    mov eax, 1                 # CREATE_NEW
4:  test r12d, O_TRUNC
    jz 5f
    mov eax, 5                 # TRUNCATE_EXISTING
    test r12d, O_CREAT
    jz 5f
    mov eax, 2                 # CREATE_ALWAYS
5:  mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 0x02000000  # FILE_FLAG_BACKUP_SEMANTICS also permits folders
    mov qword ptr [rsp + 48], 0
    API CreateFileW
    mov r13, rax
    cmp rax, -1
    jne 6f
    call win_error
    mov r12, rax
    mov rdi, rbx
    call mem_free
    mov rax, r12
    EPILOGUE
6:  mov rcx, rbx
    API GetFileAttributesW
    mov r14d, FD_FILE
    test eax, 16
    jz 7f
    mov r14d, FD_DIR
7:  test r12d, O_DIRECTORY
    jz 71f
    cmp r14d, FD_DIR
    jne .Lopen_notdir
71: mov rdi, r13
    mov esi, r14d
    mov edx, r12d
    call win_fd_alloc
    test rax, rax
    js .Lopen_full
    mov r15, rax
    mov edi, eax
    call win_fd
    mov [rax + FD_path], rbx
    cmp r14d, FD_DIR
    jne 8f
    mov qword ptr [rax + FD_aux], -1  # enumeration not yet started
8:  test r12d, O_APPEND
    jz 9f
    mov edi, r15d
    xor esi, esi
    mov edx, 2
    call ws_lseek
9:  mov rax, r15
    EPILOGUE
.Lopen_notdir:
    mov r15, -20
    jmp .Lopen_release
.Lopen_full:
    mov r15, rax
.Lopen_release:
    mov rcx, r13
    API CloseHandle
    mov rdi, rbx
    call mem_free
    mov rax, r15
    EPILOGUE
.Lopen_invalid:
    mov rax, -22
    EPILOGUE

FN ws_openat
    cmp edi, -100
    jne ws_nosys
    mov rdi, rsi
    mov esi, edx
    mov edx, ecx
    jmp ws_open

FN ws_close
    PROLOGUE 96
    call win_fd
    test rax, rax
    jz .Lclose_bad
    mov rbx, rax
    cmp dword ptr [rbx + FD_kind], FD_PTY
    je .Lclose_pty
    cmp dword ptr [rbx + FD_kind], FD_SLAVE
    je .Lclose_clear
    cmp dword ptr [rbx + FD_kind], FD_WATCH
    je .Lclose_clear
    cmp dword ptr [rbx + FD_kind], FD_DIR
    jne 1f
    mov rcx, [rbx + FD_aux]
    test rcx, rcx
    jz 1f
    cmp rcx, -1
    je 1f
    API FindClose
1:  mov rcx, [rbx + FD_handle]
    API CloseHandle
    mov rdi, [rbx + FD_path]
    call mem_free
.Lclose_clear:
    mov dword ptr [rbx + FD_kind], 0
    xor eax, eax
    EPILOGUE
.Lclose_pty:
    mov rdi, rbx
    call win_pty_close
    jmp .Lclose_clear
.Lclose_bad:
    mov rax, -9
    EPILOGUE

FN ws_read
    PROLOGUE 112
    mov r12, rsi
    mov r13, rdx
    call win_fd
    test rax, rax
    jz .Lread_bad
    mov rbx, rax
    cmp dword ptr [rbx + FD_kind], FD_WATCH
    jne 1f
    mov rdi, r12
    mov rsi, r13
    call win_watch_read
    EPILOGUE
1:  cmp dword ptr [rbx + FD_kind], FD_DIR
    je .Lread_dir
    test r13, r13
    jz .Lread_eof
    cmp r13, 0x7fffffff
    jbe 2f
    mov r13d, 0x7fffffff
2:  cmp dword ptr [rbx + FD_kind], FD_PTY
    je 3f
    cmp dword ptr [rbx + FD_kind], FD_PIPE
    jne 5f
    test dword ptr [rbx + FD_flags], O_NONBLOCK
    jz 5f
3:  mov rcx, [rbx + FD_handle]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    lea rax, [rsp + 96]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 0
    API PeekNamedPipe
    test eax, eax
    jz .Lread_pipe_end
    mov eax, [rsp + 96]
    test eax, eax
    jz .Lread_again
    cmp r13, rax
    cmova r13, rax
5:  mov rcx, [rbx + FD_handle]
    mov rdx, r12
    mov r8d, r13d
    lea r9, [rsp + 96]
    mov qword ptr [rsp + 32], 0
    API ReadFile
    test eax, eax
    jz .Lread_pipe_end
    mov r12d, [rsp + 96]
    cmp dword ptr [rbx + FD_kind], FD_PTY
    jne 6f
    test r12d, r12d
    jz 6f
    mov rdi, rbx
    call win_pty_output
6:  mov eax, r12d
    EPILOGUE
.Lread_pipe_end:
    API GetLastError
    cmp eax, 109               # broken pipe
    je .Lread_eof
    cmp eax, 232
    je .Lread_eof
    call win_error
    EPILOGUE
.Lread_again:
    mov rax, -11
    EPILOGUE
.Lread_eof:
    xor eax, eax
    EPILOGUE
.Lread_bad:
    mov rax, -9
    EPILOGUE
.Lread_dir:
    mov rax, -21
    EPILOGUE

FN ws_write
    PROLOGUE 112
    mov r12, rsi
    mov r13, rdx
    call win_fd
    test rax, rax
    jz 8f
    cmp dword ptr [rax + FD_kind], FD_PTY
    jne 1f
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call win_pty_write
    EPILOGUE
1:  mov rbx, rax
    mov rcx, [rax + FD_write]
    mov rdx, r12
    mov r8d, 0x7fffffff
    cmp r13, r8
    cmovb r8, r13
    lea r9, [rsp + 96]
    mov qword ptr [rsp + 32], 0
    API WriteFile
    test eax, eax
    jz 7f
    mov eax, [rsp + 96]
    cmp dword ptr [rbx + FD_wend], 0
    je 2f
    mov qword ptr [rbx + FD_full], 0
    test eax, eax
    jnz 2f
    test r13, r13
    jz 2f
    # a non-blocking pipe with no room: EAGAIN, and poll waits 10 ms before saying POLLOUT again
    API GetTickCount64
    mov [rbx + FD_full], rax
    mov rax, -11
2:  EPILOGUE
7:  API GetLastError
    cmp eax, 232                # ERROR_NO_DATA: the pipe is being closed
    je 71f
    cmp eax, 109                # ERROR_BROKEN_PIPE
    je 71f
    call win_error
    EPILOGUE
71: mov rax, -32                # EPIPE
    EPILOGUE
8:  mov rax, -9
    EPILOGUE

# ws_ftruncate(fd, length): the file cut (or grown) to length, its position there; a program that
# shares the handle (an extension's log) goes on writing at that position
FN ws_ftruncate
    PROLOGUE 112
    mov r12, rsi
    call win_fd
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rcx, [rbx + FD_handle]
    mov rdx, r12
    xor r8d, r8d
    xor r9d, r9d                # FILE_BEGIN
    API SetFilePointerEx
    test eax, eax
    jz 7f
    mov rcx, [rbx + FD_handle]
    API SetEndOfFile
    test eax, eax
    jz 7f
    xor eax, eax
    EPILOGUE
7:  call win_error
    EPILOGUE
8:  mov rax, -9
    EPILOGUE

FN ws_lseek
    PROLOGUE 112
    mov r12, rsi
    mov r13d, edx
    call win_fd
    test rax, rax
    jz 8f
    mov rcx, [rax + FD_handle]
    mov rdx, r12
    lea r8, [rsp + 96]
    mov r9d, r13d
    API SetFilePointerEx
    test eax, eax
    jz 7f
    mov rax, [rsp + 96]
    EPILOGUE
7:  call win_error
    EPILOGUE
8:  mov rax, -9
    EPILOGUE

FN ws_pread
    PROLOGUE 32
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    xor esi, esi
    mov edx, 1
    call ws_lseek
    test rax, rax
    js 9f
    mov r15, rax
    mov edi, ebx
    mov rsi, r14
    xor edx, edx
    call ws_lseek
    test rax, rax
    js 9f
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    call ws_read
    mov [rsp], rax
    mov edi, ebx
    mov rsi, r15
    xor edx, edx
    call ws_lseek
    mov rax, [rsp]
9:  EPILOGUE

FN ws_fstat
    PROLOGUE 160
    mov rbx, rsi
    call win_fd
    test rax, rax
    jz 8f
    mov rcx, [rax + FD_handle]
    lea rdx, [rsp + 96]
    API GetFileInformationByHandle
    test eax, eax
    jz 7f
    mov rdi, rbx
    xor eax, eax
    mov ecx, 18
    rep stosq
    mov eax, [rsp + 124]       # volume serial
    mov [rbx], rax
    mov eax, [rsp + 140]       # file index high
    shl rax, 32
    mov eax, [rsp + 144]       # overwritten below using separate register
    mov edx, [rsp + 140]
    shl rdx, 32
    or rax, rdx
    mov [rbx + 8], rax
    mov eax, [rsp + 136]
    mov [rbx + 16], rax
    mov eax, 0100644
    test dword ptr [rsp + 96], 16
    jz 1f
    mov eax, 0040755
1:  test dword ptr [rsp + 96], 1
    jz 2f
    and eax, ~0222
2:  mov [rbx + 24], eax
    mov eax, [rsp + 128]
    shl rax, 32
    mov edx, [rsp + 132]
    or rax, rdx
    mov [rbx + 48], rax
    mov qword ptr [rbx + 56], 4096
    mov rax, [rsp + 116]       # last-write FILETIME
    call win_filetime
    mov [rbx + 88], rax
    mov [rbx + 96], rdx
    mov rax, [rsp + 100]       # creation FILETIME
    call win_filetime
    mov [rbx + 104], rax
    mov [rbx + 112], rdx
    xor eax, eax
    EPILOGUE
7:  call win_error
    EPILOGUE
8:  mov rax, -9
    EPILOGUE

FN ws_stat
    PROLOGUE
    mov rbx, rsi
    xor esi, esi
    xor edx, edx
    call ws_open
    test rax, rax
    js 9f
    mov r12d, eax
    mov edi, eax
    mov rsi, rbx
    call ws_fstat
    mov r13, rax
    mov edi, r12d
    call ws_close
    mov rax, r13
9:  EPILOGUE

# win_file_missing(path) -> 1 if no directory entry is there, not even a link: GetFileAttributesW
#   reads a link's own attributes; 0 if one is or that cannot be told (access denied)
FN win_file_missing
    PROLOGUE 96
    call win_file_path
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rcx, rax
    API GetFileAttributesW
    xor r12d, r12d
    cmp eax, -1
    jne 2f
    call win_error
    cmp rax, -2
    je 1f
    cmp rax, -20
    jne 2f
1:  mov r12d, 1
2:  mov rdi, rbx
    call mem_free
    mov eax, r12d
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# win_file_is_real_dir(path) -> 1 for a directory without a reparse point, 0 otherwise, or -errno
FN win_file_is_real_dir
    PROLOGUE 96
    call win_file_path
    mov rbx, rax
    test rax, rax
    jz 8f
    mov rcx, rax
    API GetFileAttributesW
    cmp eax, -1
    je 7f
    and eax, 0x410             # FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT
    cmp eax, 0x10
    sete al
    movzx r12d, al
    jmp 2f
7:  call win_error
    mov r12, rax
2:  mov rdi, rbx
    call mem_free
    mov rax, r12
    EPILOGUE
8:  mov rax, -22
    EPILOGUE

# access(path, mode): W_OK fails with EACCES for a file with the read-only attribute
FN ws_access
    PROLOGUE 96
    mov r13d, esi
    call win_file_path
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rcx, rax
    API GetFileAttributesW
    mov r12, -1
    cmp eax, -1
    je 1f
    xor r12d, r12d
    test r13d, 2
    jz 2f
    and eax, 0x11               # read-only, and not a folder
    cmp eax, 1
    jne 2f
    mov r12, -13
    jmp 2f
1:  call win_error
    mov r12, rax
2:  mov rdi, rbx
    call mem_free
    mov rax, r12
    EPILOGUE
8:  mov rax, -22
    EPILOGUE

# chmod(path, mode): only the owner's write permission means anything, as the read-only attribute
FN ws_chmod
    PROLOGUE 96
    mov r13d, esi
    call win_file_path
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rcx, rax
    API GetFileAttributesW
    cmp eax, -1
    je 1f
    and eax, ~0x81              # neither read-only nor normal, which must be alone
    test r13d, 0200
    jnz 3f
    or eax, 1
3:  mov edx, 0x80
    test eax, eax
    cmovz eax, edx
    mov rcx, rbx
    mov edx, eax
    API SetFileAttributesW
    xor r12d, r12d
    test eax, eax
    jnz 2f
1:  call win_error
    mov r12, rax
2:  mov rdi, rbx
    call mem_free
    mov rax, r12
    EPILOGUE
8:  mov rax, -22
    EPILOGUE

FN ws_cwd
    PROLOGUE 8304
    mov rbx, rdi
    mov r12, rsi
    mov ecx, 4096
    lea rdx, [rsp + 96]
    API GetCurrentDirectoryW
    test eax, eax
    jz 7f
    cmp eax, 4096
    jae 8f
    lea rdi, [rsp + 96]
    call win_utf8
    mov r13, rax
    test rax, rax
    jz 8f
    mov rdi, rax
    call win_slashes
    mov rdi, r13
    call strlen
    inc rax
    cmp rax, r12
    ja 6f
    mov r12, rax
    mov rdi, rbx
    mov rsi, r13
    mov rdx, rax
    call memcpy
    jmp 5f
6:  mov r12, -34
5:  mov rdi, r13
    call mem_free
    mov rax, r12
    EPILOGUE
7:  call win_error
    EPILOGUE
8:  mov rax, -36
    EPILOGUE

.macro PATH_API name, api
FN \name
    PROLOGUE 96
    call win_file_path
    mov rbx, rax
    test rax, rax
    jz 8f
    mov rcx, rax
    xor edx, edx
    API \api
    test eax, eax
    jz 1f
    xor r12d, r12d
    jmp 2f
1:  call win_error
    mov r12, rax
2:  mov rdi, rbx
    call mem_free
    mov rax, r12
    EPILOGUE
8:  mov rax, -22
    EPILOGUE
.endm
PATH_API ws_chdir, SetCurrentDirectoryW
PATH_API ws_mkdir, CreateDirectoryW
PATH_API ws_unlink, DeleteFileW
PATH_API ws_rmdir, RemoveDirectoryW

FN ws_fsync
    PROLOGUE 96
    call win_fd
    test rax, rax
    jz 8f
    mov rcx, [rax + FD_handle]
    API FlushFileBuffers
    test eax, eax
    jz 7f
    xor eax, eax
    EPILOGUE
7:  call win_error
    EPILOGUE
8:  mov rax, -9
    EPILOGUE

FN ws_rename
    PROLOGUE 128
    mov r14, rsi
    mov r12, rsi
    mov qword ptr [rsp + 96], 0
    mov qword ptr [rsp + 104], 0
    call win_file_path
    mov rbx, rax
    mov rdi, r12
    call win_file_path
    mov r12, rax
    test rbx, rbx
    jz 8f
    test r12, r12
    jz 8f
    mov rcx, r12
    API GetFileAttributesW
    cmp eax, -1
    je 2f
    test eax, 16
    jnz 2f
    test eax, 1
    jnz 81f
    # A private, exclusively created sibling directory reserves a backup name. ReplaceFile
    # has partial-failure states, so a failed save must always retain the original somewhere.
    mov rdi, r14
    call win_backup
    test rax, rax
    jz 8f
    mov [rsp + 96], rax
    mov [rsp + 104], rdx
    mov rcx, r12
    mov rdx, rbx
    mov r8, rax
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    API ReplaceFileW
    test eax, eax
    jnz 3f
    call win_error
    mov r13, rax
    mov rcx, [rsp + 96]
    API GetFileAttributesW
    cmp eax, -1
    je 9f                      # old destination was not moved
    mov rcx, [rsp + 96]
    mov rdx, r12
    mov r8d, 9
    API MoveFileExW
    test eax, eax
    jnz 9f                     # original is back at its original path
    lea rdi, [rip + .Lrecovery]
    call app_toast
    # Retain backup and directory if rollback itself fails. The shared caller may delete
    # the replacement temp file, but the original remains in the recovery directory.
    jmp 91f
2:  mov rcx, rbx
    mov rdx, r12
    mov r8d, 9
    API MoveFileExW
    test eax, eax
    jz 7f
3:  xor r13d, r13d
    jmp 9f
7:  call win_error
    mov r13, rax
    jmp 9f
8:  mov r13, -22
    jmp 9f
81: mov r13, -13
9:  mov rcx, [rsp + 96]
    test rcx, rcx
    jz 91f
    API DeleteFileW
    mov rcx, [rsp + 104]
    API RemoveDirectoryW
91: mov rdi, [rsp + 96]
    call mem_free
    mov rdi, [rsp + 104]
    call mem_free
    mov rdi, rbx
    call mem_free
    mov rdi, r12
    call mem_free
    mov rax, r13
    EPILOGUE

# win_backup(destination UTF-8) -> wide backup file in rax and owning directory in rdx.
win_backup:
    PROLOGUE 128
    mov r12, rdi
    call strlen
    cmp rax, 3968
    ja 8f
    mov rdi, r12
    mov rsi, rax
    call path_dirlen
    mov [rsp + 120], rax
    lea rdi, [rsp + 96]
    xor esi, esi
    mov edx, SB_SIZE
    call memset
    mov r15d, 128
1:  lea rdi, [rsp + 96]
    call sb_clear
    lea rdi, [rsp + 96]
    mov rsi, r12
    mov rdx, [rsp + 120]
    call sb_push
    mov rax, [rsp + 120]
    test rax, rax
    je 2f
    cmp byte ptr [r12 + rax - 1], '/'
    je 2f
    lea rdi, [rsp + 96]
    mov esi, '/'
    call sb_push_byte
2:
    lea rdi, [rsp + 96]
    lea rsi, [rip + .Lbackup]
    call sb_push_cstr
    API GetCurrentProcessId
    lea rdi, [rsp + 96]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rsp + 96]
    mov esi, '-'
    call sb_push_byte
    inc qword ptr [rip + backup_serial]
    lea rdi, [rsp + 96]
    mov rsi, [rip + backup_serial]
    call sb_push_u64
    mov rdi, [rsp + 96]
    call win_file_path
    mov rbx, rax
    test rax, rax
    jz 7f
    mov rcx, rax
    xor edx, edx
    API CreateDirectoryW
    test eax, eax
    jnz 3f
    call win_error
    mov r14, rax
    mov rdi, rbx
    call mem_free
    cmp r14, -17
    jne 7f
    dec r15d
    jnz 1b
    jmp 7f
3:  lea rdi, [rsp + 96]
    lea rsi, [rip + .Loriginal]
    call sb_push_cstr
    mov rdi, [rsp + 96]
    call win_file_path
    mov r14, rax
    test rax, rax
    jnz 4f
    mov rcx, rbx
    API RemoveDirectoryW
    mov rdi, rbx
    call mem_free
    jmp 7f
4:  lea rdi, [rsp + 96]
    call sb_free
    mov rax, r14
    mov rdx, rbx
    EPILOGUE
7:  lea rdi, [rsp + 96]
    call sb_free
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# readlink resolves a final reparse point to its final opened target. An unresolved/dangling
# reparse point is an error, never permission to replace the link itself.
FN win_realpath
    PROLOGUE 8320
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    jmp .Lrl_resolve

FN ws_readlink
    PROLOGUE 8320
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rsi, [rip + .Lself]
    call strcmp_eq
    test eax, eax
    jz 1f
    xor ecx, ecx
    lea rdx, [rsp + 96]
    mov r8d, 4096
    API GetModuleFileNameW
    test eax, eax
    jz 7f
    cmp eax, 4096
    jae 8f
    jmp 4f
1:  mov rdi, rbx
    call win_file_path
    mov r14, rax
    test rax, rax
    jz 8f
    mov rcx, rax
    API GetFileAttributesW
    mov r15d, eax
    mov rdi, r14
    call mem_free
    cmp r15d, -1
    je 7f
    test r15d, 0x400
    jz 81f
.Lrl_resolve:
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call ws_open
    test rax, rax
    js 82f
    mov ebx, eax
    mov edi, eax
    call win_fd
    mov rcx, [rax + FD_handle]
    lea rdx, [rsp + 96]
    mov r8d, 4096
    xor r9d, r9d
    API GetFinalPathNameByHandleW
    mov r14d, eax
    mov edi, ebx
    call ws_close
    test r14d, r14d
    jz 82f
    cmp r14d, 4096
    jae 8f
4:  lea rdi, [rsp + 96]
    call win_utf8
    mov rbx, rax
    test rax, rax
    jz 8f
    mov rdi, rax
    call win_slashes
    mov r14, rbx
    cmp dword ptr [rbx], 0x2f3f2f2f   # //?/
    jne 5f
    add r14, 4
    cmp dword ptr [r14], 0x2f434e55   # UNC/
    jne 5f
    add r14, 2
    mov byte ptr [r14], '/'
5:  mov rdi, r14
    call strlen
    cmp rax, r13
    jae 6f
    mov r15, rax
    mov rdi, r12
    mov rsi, r14
    mov rdx, rax
    call memcpy
    jmp 61f
6:  mov r15, -36
61: mov rdi, rbx
    call mem_free
    mov rax, r15
    EPILOGUE
7:  call win_error
    EPILOGUE
8:  mov rax, -36
    EPILOGUE
81: mov rax, -22
    EPILOGUE
82: mov rax, -40               # unresolved reparse point, fail closed
    EPILOGUE

# win_readlink_one(path, buf, size) -> length or -errno: readlink as POSIX has it, for one symlink or
#   junction: the target it names, relative or absolute, with forward slashes; -22 (EINVAL) for anything
#   else. ws_readlink gives the end of a whole chain instead.
FN win_readlink_one
    PROLOGUE 16480
    mov r12, rsi
    mov r13, rdx
    call win_file_path
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rcx, rax
    API GetFileAttributesW
    cmp eax, -1
    je 6f
    test eax, 0x400
    jz 5f
    # the reparse point itself, not what it leads to
    mov rcx, rbx
    mov edx, 0x80               # FILE_READ_ATTRIBUTES
    mov r8d, 7
    xor r9d, r9d
    mov qword ptr [rsp + 32], 3             # OPEN_EXISTING
    mov qword ptr [rsp + 40], 0x02200000    # BACKUP_SEMANTICS | OPEN_REPARSE_POINT
    mov qword ptr [rsp + 48], 0
    API CreateFileW
    mov r14, rax
    mov rdi, rbx
    call mem_free
    cmp r14, -1
    je 7f
    mov rcx, r14
    mov edx, 0x900a8            # FSCTL_GET_REPARSE_POINT
    xor r8d, r8d
    xor r9d, r9d
    lea rax, [rsp + 96]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 16384
    lea rax, [rsp + 88]
    mov [rsp + 48], rax
    mov qword ptr [rsp + 56], 0
    API DeviceIoControl
    mov r15d, eax
    mov rcx, r14
    API CloseHandle
    test r15d, r15d
    jz 81f
    lea rsi, [rsp + 96]
    lea rdx, [rsi + 20]
    cmp dword ptr [rsi], 0xa000000c         # IO_REPARSE_TAG_SYMLINK
    je 1f
    lea rdx, [rsi + 16]
    cmp dword ptr [rsi], 0xa0000003         # IO_REPARSE_TAG_MOUNT_POINT (a junction)
    jne 81f
    # the name to show, or the one the system uses
1:  movzx eax, word ptr [rsi + 12]
    movzx ecx, word ptr [rsi + 14]
    test ecx, ecx
    jnz 2f
    movzx eax, word ptr [rsi + 8]
    movzx ecx, word ptr [rsi + 10]
2:  add rax, rcx
    cmp rax, 16000
    ja 81f
    sub rax, rcx
    add rdx, rax
    mov word ptr [rdx + rcx], 0
    cmp dword ptr [rdx], 0x003f005c         # \??\ before the system's name
    jne 3f
    cmp dword ptr [rdx + 4], 0x005c003f
    jne 3f
    add rdx, 8
    cmp dword ptr [rdx], 0x004e0055         # UNC\server\share: \\server\share
    jne 3f
    cmp dword ptr [rdx + 4], 0x005c0043
    jne 3f
    add rdx, 4
    mov word ptr [rdx], 92
3:  mov rdi, rdx
    call win_utf8
    test rax, rax
    jz 81f
    mov rbx, rax
    mov rdi, rax
    call win_slashes
    mov rdi, rbx
    call strlen
    mov r15, -36
    cmp rax, r13
    jae 4f
    mov r15, rax
    mov rdi, r12
    mov rsi, rbx
    mov rdx, rax
    call memcpy
4:  mov rdi, rbx
    call mem_free
    mov rax, r15
    EPILOGUE
5:  mov rdi, rbx
    call mem_free
81: mov rax, -22
    EPILOGUE
6:  mov rdi, rbx
    call mem_free
7:  call win_error
    EPILOGUE
8:  mov rax, -22
    EPILOGUE

FN ws_pipe
    PROLOGUE 128
    mov rbx, rdi
    mov r12d, esi
    lea rcx, [rsp + 96]
    lea rdx, [rsp + 104]
    xor r8d, r8d
    mov r9d, 65536
    API CreatePipe
    test eax, eax
    jz 7f
    mov rdi, [rsp + 96]
    mov esi, FD_PIPE
    mov edx, r12d
    call win_fd_alloc
    test rax, rax
    js 6f
    mov r13d, eax
    mov [rbx], eax
    mov rdi, [rsp + 104]
    mov esi, FD_PIPE
    mov edx, r12d
    call win_fd_alloc
    test rax, rax
    js 5f
    mov dword ptr [r8 + FD_wend], 1     # win_fd_alloc leaves the slot in r8
    mov [rbx + 4], eax
    xor eax, eax
    EPILOGUE
5:  mov edi, r13d
    call ws_close
    jmp 61f
6:  mov rcx, [rsp + 96]
    API CloseHandle
61: mov rcx, [rsp + 104]
    API CloseHandle
    mov rax, -24
    EPILOGUE
7:  call win_error
    EPILOGUE

FN ws_fcntl
    PROLOGUE 112
    call win_fd
    test rax, rax
    jz 8f
    cmp esi, 4
    jne 1f
    mov [rax + FD_flags], edx
    cmp dword ptr [rax + FD_kind], FD_PIPE
    jne 1f
    cmp dword ptr [rax + FD_wend], 0
    je 1f
    # a pipe's write end: O_NONBLOCK makes WriteFile return at once when the reader is behind
    # (PIPE_NOWAIT on this end only; the child's reads keep waiting)
    xor ecx, ecx
    test edx, O_NONBLOCK
    setnz cl
    mov [rsp + 96], ecx
    mov rcx, [rax + FD_handle]
    lea rdx, [rsp + 96]
    xor r8d, r8d
    xor r9d, r9d
    API SetNamedPipeHandleState
1:  xor eax, eax
    EPILOGUE
8:  mov rax, -9
    EPILOGUE

FN ws_getdents
    PROLOGUE 9120
    mov r12, rsi
    mov r13, rdx
    call win_fd
    test rax, rax
    jz .Ldent_bad
    mov rbx, rax
    cmp dword ptr [rbx + FD_kind], FD_DIR
    jne .Ldent_bad
    xor r14d, r14d
    cmp qword ptr [rbx + FD_aux], 0
    je .Ldent_done
.Ldent_next:
    lea rax, [r14 + 1056]
    cmp rax, r13
    ja .Ldent_done
    cmp qword ptr [rbx + FD_aux], -1
    jne .Ldent_more
    mov rsi, [rbx + FD_path]
    lea rdi, [rsp + 800]
    xor ecx, ecx
1:  mov ax, [rsi + rcx*2]
    mov [rdi + rcx*2], ax
    test ax, ax
    jz 2f
    inc ecx
    cmp ecx, 4093
    jb 1b
    mov rax, -36
    EPILOGUE
2:  mov word ptr [rdi + rcx*2], 92
    mov word ptr [rdi + rcx*2 + 2], '*'
    mov word ptr [rdi + rcx*2 + 4], 0
    mov rcx, rdi
    lea rdx, [rsp + 96]
    API FindFirstFileW
    cmp rax, -1
    je .Ldent_end
    mov [rbx + FD_aux], rax
    jmp .Ldent_emit
.Ldent_more:
    mov rcx, [rbx + FD_aux]
    lea rdx, [rsp + 96]
    API FindNextFileW
    test eax, eax
    jz .Ldent_end
.Ldent_emit:
    lea rdi, [rsp + 140]        # WIN32_FIND_DATAW.cFileName
    call win_utf8
    mov r15, rax
    test rax, rax
    jz .Ldent_next
    mov rdi, rax
    call strlen
    lea rax, [rax + 27]
    and rax, -8
    lea rdx, [r12 + r14]
    mov [rdx + 16], ax
    add r14, rax
    mov qword ptr [rdx], 1
    mov [rdx + 8], r14
    mov byte ptr [rdx + 18], 8
    test dword ptr [rsp + 96], 16
    jz 3f
    mov byte ptr [rdx + 18], 4
3:  lea rdi, [rdx + 19]
    mov rsi, r15
    call cstr_copy
    mov rdi, r15
    call mem_free
    jmp .Ldent_next
.Ldent_end:
    mov rcx, [rbx + FD_aux]
    cmp rcx, -1
    je 4f
    API FindClose
4:  mov qword ptr [rbx + FD_aux], 0
.Ldent_done:
    mov rax, r14
    EPILOGUE
.Ldent_bad:
    mov rax, -20
    EPILOGUE

CSTR .Lnull, "/dev/null"
CSTR .Lnul, "NUL"
CSTR .Lself, "/proc/self/exe"

.bss
.p2align 3
backup_serial: .quad 0
CSTR .Lbackup, ".rhun-backup-"
CSTR .Loriginal, "/original"
CSTR .Lrecovery, "Save failed. The original is in the .rhun-backup folder beside the file"
