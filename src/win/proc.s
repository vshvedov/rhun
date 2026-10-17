# Native child processes and Windows pseudoconsoles.
.include "win.inc"
.equ CHILD_SIZE, 24
.equ CHILD_MAX, 128
.equ PT_pc, 0
.equ PT_in, 8
.equ PT_out, 16
.equ PT_event, 24
.equ PT_thread, 32
.equ PT_head, 40
.equ PT_tail, 44
.equ PT_stop, 48
.equ PT_size, 52                # the COORD last asked for by pty_resize
.equ PT_seen, 56                # the console has produced output
.equ PT_data, 64
.equ PT_SIZE, 65600
.bss
.p2align 4
children: .zero CHILD_SIZE * CHILD_MAX

.text
# proc_which(name) -> path to run (mem_free it), or 0. Like the Unix one it searches PATH only:
# SearchPathW's default order puts the application folder and the current directory first, where a
# project could plant powershell.exe or git.exe.
FN proc_which
    PROLOGUE 8320
    call win_wide
    mov rbx, rax
    test rax, rax
    jz 8f
    lea rcx, [rip + .Lpath_var]
    xor edx, edx
    xor r8d, r8d
    API GetEnvironmentVariableW # the size PATH needs, with its NUL
    mov r13d, eax
    test eax, eax
    jz 7f
    lea rdi, [r13 + r13 + 2]
    call mem_alloc
    mov r14, rax
    mov word ptr [r14], 0
    lea rcx, [rip + .Lpath_var]
    mov rdx, r14
    mov r8d, r13d
    API GetEnvironmentVariableW
    cmp eax, r13d               # PATH changed meanwhile and no longer fits: search nothing
    jb 1f
    mov word ptr [r14], 0
1:  mov rcx, r14
    mov rdx, rbx
    lea r8, [rip + .Lexe]
    mov r9d, 4096
    lea rax, [rsp + 96]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 0
    API SearchPathW
    mov r12d, eax
    mov rdi, r14
    call mem_free
    mov rdi, rbx
    call mem_free
    test r12d, r12d
    jz 8f
    cmp r12d, 4096
    jae 8f
    lea rdi, [rsp + 96]
    call win_utf8
    test rax, rax
    jz 8f
    mov rdi, rax
    call win_slashes
    EPILOGUE
7:  mov rdi, rbx
    call mem_free
8:  xor eax, eax
    EPILOGUE

# Windows CRT command-line quoting, also understood by CommandLineToArgvW. Quote empty
# arguments and those with spaces or quotes. Quote argv[0] and use native separators:
# cmd.exe treats even quoted forward slashes in its executable path as switches.
FN win_commandline
    PROLOGUE 32
    mov r12, rdi
    mov [rsp + 24], rdi
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
    mov r13, [r12]
    test r13, r13
    jz .Lcmd_end
    jmp .Lcmd_quote
.Lcmd_arg:
    mov r13, [r12]
    test r13, r13
    jz .Lcmd_end
    cmp byte ptr [r13], 0
    je .Lcmd_quote
    mov rax, r13
.Lcmd_scan:
    mov cl, [rax]
    cmp cl, ' '
    je .Lcmd_quote
    cmp cl, 9
    je .Lcmd_quote
    cmp cl, '"'
    je .Lcmd_quote
    test cl, cl
    jz .Lcmd_bare
    inc rax
    jmp .Lcmd_scan
.Lcmd_bare:
    mov rdi, rsp
    mov rsi, r13
    call sb_push_cstr
    jmp .Lcmd_next
.Lcmd_quote:
    mov rdi, rsp
    mov esi, '"'
    call sb_push_byte
.Lcmd_char:
    xor r14d, r14d
1:  cmp byte ptr [r13], 92
    je .Lcmd_backslash
    cmp r12, [rsp + 24]
    jne 2f
    cmp byte ptr [r13], '/'
    jne 2f
.Lcmd_backslash:
    inc r14
    inc r13
    jmp 1b
2:  movzx ebx, byte ptr [r13]
    test ebx, ebx
    jz 3f
    cmp ebx, '"'
    jne 4f
3:  shl r14, 1
4:  test r14, r14
    jz 5f
    mov rdi, rsp
    mov esi, 92
    call sb_push_byte
    dec r14
    jmp 4b
5:  test ebx, ebx
    jz 7f
    cmp ebx, '"'
    jne 6f
    mov rdi, rsp
    mov esi, 92
    call sb_push_byte
6:  mov rdi, rsp
    mov esi, ebx
    call sb_push_byte
    inc r13
    jmp .Lcmd_char
7:  mov rdi, rsp
    mov esi, '"'
    call sb_push_byte
.Lcmd_next:
    add r12, 8
    cmp qword ptr [r12], 0
    je .Lcmd_end
    mov rdi, rsp
    mov esi, ' '
    call sb_push_byte
    jmp .Lcmd_arg
.Lcmd_end:
    mov rdi, [rsp]
    call win_wide
    mov rbx, rax
    mov rdi, rsp
    call sb_free
    mov rax, rbx
    EPILOGUE

# envp UTF-8 strings -> double-NUL UTF-16 block. Windows accepts an unsorted block.
FN win_environment
    PROLOGUE 32
    mov r12, rdi
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
1:  mov rdi, [r12]
    test rdi, rdi
    jz 3f
    call win_wide
    mov rbx, rax
    test rax, rax
    jz 7f
    xor edx, edx
2:  add edx, 2
    cmp word ptr [rbx + rdx - 2], 0
    jne 2b
    mov rdi, rsp
    mov rsi, rbx
    call sb_push
    mov rdi, rbx
    call mem_free
    add r12, 8
    jmp 1b
3:  mov rdi, rsp
    xor esi, esi
    call sb_push_byte
    mov rdi, rsp
    xor esi, esi
    call sb_push_byte
    mov rax, [rsp]
    EPILOGUE
7:  mov rdi, rsp
    call sb_free
    xor eax, eax
    EPILOGUE

# proc_spawn(argv, envp, cwd, in, out, err, ctty): Win32 process + owned job object.
FN proc_spawn
    PROLOGUE 608
    # locals: startup 96..207, process info 208..231, handles 232..255,
    # job limits 256..399, pointers 400+, attribute list storage 480+.
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov [rsp + 440], ecx
    mov [rsp + 444], r8d
    mov [rsp + 448], r9d
    lea rdi, [rsp + 96]
    xor esi, esi
    mov edx, 344
    call memset
    mov qword ptr [rsp + 400], 0
    mov qword ptr [rsp + 408], 0
    mov qword ptr [rsp + 416], 0
    mov qword ptr [rsp + 424], 0
    mov qword ptr [rsp + 432], 0
    mov qword ptr [rsp + 456], 0
    mov qword ptr [rsp + 464], 0
    mov rdi, r12
    call win_commandline
    mov [rsp + 400], rax
    test rax, rax
    jz .Lspawn_invalid
    mov rdi, r13
    test rdi, rdi
    jnz 1f
    mov rdi, [rip + g_envp]
1:  call win_environment
    mov [rsp + 408], rax
    test rax, rax
    jz .Lspawn_invalid
    test r14, r14
    jz 2f
    mov rdi, r14
    call win_wide
    mov [rsp + 416], rax
    test rax, rax
    jz .Lspawn_invalid
2:  mov rdi, [r12]
    call win_wide
    mov [rsp + 424], rax
    test rax, rax
    jz .Lspawn_invalid
    # reserve a child table slot before starting anything
    lea rbx, [rip + children]
    mov ecx, CHILD_MAX
3:  cmp qword ptr [rbx], 0
    je 4f
    add rbx, CHILD_SIZE
    dec ecx
    jnz 3b
    mov r15, -11
    jmp .Lspawn_cleanup
4:  mov edi, [rsp + 440]
    call win_fd
    test rax, rax
    jz .Lspawn_invalid
    cmp dword ptr [rax + FD_kind], FD_SLAVE
    jne .Lspawn_stdio
    mov rax, [rax + FD_aux]
    mov [rsp + 456], rax
    jmp .Lspawn_attrs
.Lspawn_stdio:
    xor r12d, r12d
5:  mov edi, [rsp + 440 + r12*4]
    call win_fd
    test rax, rax
    jz .Lspawn_invalid
    mov rdx, [rax + FD_handle]
    mov rcx, -1
    mov r8, -1
    lea r9, [rsp + 232 + r12*8]
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 1
    mov qword ptr [rsp + 48], 2    # DUPLICATE_SAME_ACCESS
    API DuplicateHandle
    test eax, eax
    jz .Lspawn_error
    inc r12
    cmp r12, 3
    jb 5b
    mov rax, [rsp + 232]
    mov [rsp + 176], rax
    mov rax, [rsp + 240]
    mov [rsp + 184], rax
    mov rax, [rsp + 248]
    mov [rsp + 192], rax
.Lspawn_attrs:
    # Explicit NULL stdio for a pseudoconsole prevents Windows from duplicating the
    # parent's redirected handles into the child, even when inheritance is disabled.
    mov dword ptr [rsp + 156], 0x100  # STARTF_USESTDHANDLES
    xor ecx, ecx
    mov edx, 1
    xor r8d, r8d
    lea r9, [rsp + 464]
    API InitializeProcThreadAttributeList
    mov rdi, [rsp + 464]
    call mem_alloc
    mov [rsp + 432], rax
    mov rcx, rax
    mov edx, 1
    xor r8d, r8d
    lea r9, [rsp + 464]
    API InitializeProcThreadAttributeList
    test eax, eax
    jz .Lspawn_error
    mov rax, [rsp + 432]
    mov [rsp + 200], rax
    mov dword ptr [rsp + 96], 112
    mov rcx, rax
    xor edx, edx
    mov r8d, 0x20002             # PROC_THREAD_ATTRIBUTE_HANDLE_LIST
    lea r9, [rsp + 232]
    mov qword ptr [rsp + 32], 24
    cmp qword ptr [rsp + 456], 0
    je 6f
    mov r8d, 0x20016             # PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
    mov rax, [rsp + 456]
    mov r9, [rax + PT_pc]
    mov qword ptr [rsp + 32], 8
6:  mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0
    API UpdateProcThreadAttribute
    test eax, eax
    jz .Lspawn_error
    xor ecx, ecx
    xor edx, edx
    API CreateJobObjectW
    mov [rbx + 16], rax
    test rax, rax
    jz .Lspawn_error
    mov dword ptr [rsp + 272], 0x2000 # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    mov rcx, rax
    mov edx, 9
    lea r8, [rsp + 256]
    mov r9d, 144
    API SetInformationJobObject
    test eax, eax
    jz .Lspawn_error
    mov rcx, [rsp + 424]
    mov rdx, [rsp + 400]
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 1
    mov qword ptr [rsp + 40], 0x80404 # extended info, Unicode env, suspended
    cmp qword ptr [rsp + 456], 0
    je 7f
    mov qword ptr [rsp + 32], 0
7:  # hide console windows for non-PTY subprocesses such as git and curl
    cmp qword ptr [rsp + 456], 0
    jne 71f
    or qword ptr [rsp + 40], 0x08000000
71: mov rax, [rsp + 408]
    mov [rsp + 48], rax
    mov rax, [rsp + 416]
    mov [rsp + 56], rax
    lea rax, [rsp + 96]
    mov [rsp + 64], rax
    lea rax, [rsp + 208]
    mov [rsp + 72], rax
    API CreateProcessW
    test eax, eax
    jz .Lspawn_error
    mov rcx, [rbx + 16]
    mov rdx, [rsp + 208]
    API AssignProcessToJobObject
    test eax, eax
    jz .Lspawn_terminate
    mov rcx, [rsp + 216]
    API ResumeThread
    cmp eax, -1
    je .Lspawn_terminate
    mov rax, [rsp + 208]
    mov [rbx + 8], rax
    mov eax, [rsp + 224]
    mov [rbx], rax
    mov r15, rax
    mov rcx, [rsp + 216]
    API CloseHandle
    jmp .Lspawn_cleanup
.Lspawn_terminate:
    mov rcx, [rsp + 208]
    mov edx, 1
    API TerminateProcess
    mov rcx, [rsp + 208]
    API CloseHandle
    mov rcx, [rsp + 216]
    API CloseHandle
.Lspawn_error:
    call win_error
    mov r15, rax
    jmp .Lspawn_cleanup
.Lspawn_invalid:
    mov r15, -22
.Lspawn_cleanup:
    test r15, r15
    jns 8f
    # rbx is a child slot only after the slot search.
    lea rax, [rip + children]
    cmp rbx, rax
    jb 8f
    lea rax, [rip + children + CHILD_SIZE*CHILD_MAX]
    cmp rbx, rax
    jae 8f
    mov rcx, [rbx + 16]
    test rcx, rcx
    jz 8f
    API CloseHandle
    mov qword ptr [rbx + 16], 0
8:  mov rcx, [rsp + 200]
    test rcx, rcx
    jz 81f
    API DeleteProcThreadAttributeList
81: xor r12d, r12d
82: mov rcx, [rsp + 232 + r12*8]
    test rcx, rcx
    jz 83f
    API CloseHandle
83: inc r12
    cmp r12, 3
    jb 82b
    xor r12d, r12d
84: mov rdi, [rsp + 400 + r12*8]
    call mem_free
    inc r12
    cmp r12, 5
    jb 84b
    mov rax, r15
    EPILOGUE

FN ws_wait
    PROLOGUE 112
    mov r12, rsi
    mov r13d, edx
    lea rbx, [rip + children]
    mov ecx, CHILD_MAX
1:  cmp [rbx], rdi
    je 2f
    add rbx, CHILD_SIZE
    dec ecx
    jnz 1b
    mov rax, -10
    EPILOGUE
2:  mov rcx, [rbx + 8]
    mov edx, -1
    test r13d, 1
    jz 3f
    xor edx, edx
3:  API WaitForSingleObject
    cmp eax, 258
    je 8f
    test eax, eax
    jnz 7f
    mov rcx, [rbx + 8]
    lea rdx, [rsp + 96]
    API GetExitCodeProcess
    test eax, eax
    jz 7f
    test r12, r12
    jz 4f
    mov eax, [rsp + 96]
    and eax, 255
    shl eax, 8
    mov [r12], eax
4:  mov r12, [rbx]
    mov rcx, [rbx + 8]
    API CloseHandle
    mov rcx, [rbx + 16]
    API CloseHandle
    mov qword ptr [rbx], 0
    mov qword ptr [rbx + 16], 0
    mov rax, r12
    EPILOGUE
7:  call win_error
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

FN ws_kill
    PROLOGUE 96
    mov r12d, esi
    test edi, edi
    jns 1f
    neg edi
1:  lea rbx, [rip + children]
    mov ecx, CHILD_MAX
2:  cmp [rbx], rdi
    je 3f
    add rbx, CHILD_SIZE
    dec ecx
    jnz 2b
    mov rax, -3
    EPILOGUE
3:  test r12d, r12d
    jz 4f                       # signal 0: only whether it is there
    # the job ends with 128 + the signal as its exit code, as a shell reports a signalled program
    mov rcx, [rbx + 16]
    lea edx, [r12 + 128]
    API TerminateJobObject
4:  xor eax, eax
    EPILOGUE

FN pty_open
    PROLOGUE 144
    mov r12d, edi
    mov r13d, esi
    xor ecx, ecx
    mov edx, PT_SIZE
    mov r8d, 0x3000
    mov r9d, 4
    API VirtualAlloc
    test rax, rax
    jz .Lpty_fail
    mov rbx, rax
    lea rcx, [rsp + 96]
    lea rdx, [rbx + PT_in]
    xor r8d, r8d
    mov r9d, 65536
    API CreatePipe
    test eax, eax
    jz .Lpty_free
    lea rcx, [rbx + PT_out]
    lea rdx, [rsp + 104]
    xor r8d, r8d
    mov r9d, 65536
    API CreatePipe
    test eax, eax
    jz .Lpty_input
    mov ecx, r13d
    shl ecx, 16
    mov cx, r12w
    mov rdx, [rsp + 96]
    mov r8, [rsp + 104]
    xor r9d, r9d
    lea rax, [rbx + PT_pc]
    mov [rsp + 32], rax
    API CreatePseudoConsole
    mov r12d, eax
    mov rcx, [rsp + 96]
    API CloseHandle
    mov rcx, [rsp + 104]
    API CloseHandle
    test r12d, r12d
    js .Lpty_handles
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    API CreateEventW
    mov [rbx + PT_event], rax
    test rax, rax
    jz .Lpty_close
    xor ecx, ecx
    xor edx, edx
    lea r8, [rip + pty_writer]
    mov r9, rbx
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    API CreateThread
    mov [rbx + PT_thread], rax
    test rax, rax
    jz .Lpty_close
    mov rdi, [rbx + PT_out]
    mov esi, FD_PTY
    mov edx, O_NONBLOCK
    call win_fd_alloc
    test rax, rax
    js .Lpty_close
    mov r12d, eax
    mov edi, eax
    call win_fd
    mov [rax + FD_aux], rbx
    mov rcx, [rbx + PT_in]
    mov [rax + FD_write], rcx
    xor edi, edi
    mov esi, FD_SLAVE
    xor edx, edx
    call win_fd_alloc
    test rax, rax
    js .Lpty_master
    mov r13d, eax
    mov edi, eax
    call win_fd
    mov [rax + FD_aux], rbx
    mov eax, r12d
    mov edx, r13d
    EPILOGUE
.Lpty_master:
    mov edi, r12d
    call ws_close
    jmp .Lpty_fail
.Lpty_close:
    # The asynchronous shutdown path also handles a partially initialized writer.
    mov edi, FD_SIZE
    call mem_alloc
    mov [rax + FD_aux], rbx
    mov r12, rax
    mov rdi, rax
    call win_pty_close
    mov rdi, r12
    call mem_free
    jmp .Lpty_fail
.Lpty_handles:
    mov rcx, [rbx + PT_out]
    API CloseHandle
    jmp .Lpty_write
.Lpty_input:
    mov rcx, [rsp + 96]
    API CloseHandle
.Lpty_write:
    mov rcx, [rbx + PT_in]
    API CloseHandle
.Lpty_free:
    mov rcx, rbx
    xor edx, edx
    mov r8d, 0x8000
    API VirtualFree
.Lpty_fail:
    mov eax, -1
    EPILOGUE

# ConPTY drops a resize made before the console's first output (it reports success all the same)
# and keeps the size it was created with: its later repaints, as after cls, then scroll the grid.
# The size is kept, and win_pty_output asks again once the console has produced output.
FN pty_resize
    PROLOGUE 96
    mov r12d, esi
    mov r13d, edx
    call win_fd
    test rax, rax
    jz 9f
    mov rax, [rax + FD_aux]
    mov rcx, [rax + PT_pc]
    mov edx, r13d
    shl edx, 16
    mov dx, r12w
    mov [rax + PT_size], edx
    API ResizePseudoConsole
9:  EPILOGUE

# win_pty_output(fd entry): the first output of a pseudoconsole; a size asked for earlier is applied now
FN win_pty_output
    PROLOGUE 32
    mov rax, [rdi + FD_aux]
    cmp dword ptr [rax + PT_seen], 0
    jne 9f
    mov dword ptr [rax + PT_seen], 1
    mov edx, [rax + PT_size]
    test edx, edx
    jz 9f
    mov rcx, [rax + PT_pc]
    API ResizePseudoConsole
9:  EPILOGUE

# The GUI is the sole producer; the writer thread is the sole consumer. Aligned x86 stores
# publish bytes after copying and consumed bytes only after WriteFile finishes.
FN win_pty_write
    PROLOGUE 96
    mov rbx, [rdi + FD_aux]
    mov r12, rsi
    mov r13, rdx
    cmp dword ptr [rbx + PT_stop], 0
    jne 8f
    mov r14d, [rbx + PT_head]
    mov eax, r14d
    sub eax, [rbx + PT_tail]
    mov r15d, 65536
    sub r15d, eax
    jz 7f
    cmp r13, r15
    cmova r13, r15
    xor r15d, r15d
1:  cmp r15, r13
    jae 2f
    mov eax, r14d
    and eax, 65535
    mov dl, [r12 + r15]
    mov [rbx + rax + PT_data], dl
    inc r14d
    inc r15
    jmp 1b
2:  mov [rbx + PT_head], r14d
    mov rcx, [rbx + PT_event]
    API SetEvent
    mov rax, r13
    EPILOGUE
7:  mov rax, -11
    EPILOGUE
8:  mov rax, -5
    EPILOGUE

pty_writer:
    CALLBACK 16
    mov rbx, rcx
1:  cmp dword ptr [rbx + PT_stop], 0
    jne 9f
    mov r12d, [rbx + PT_tail]
    mov r13d, [rbx + PT_head]
    sub r13d, r12d
    jnz 2f
    mov rcx, [rbx + PT_event]
    mov edx, -1
    API WaitForSingleObject
    jmp 1b
2:  and r12d, 65535
    mov eax, 65536
    sub eax, r12d
    cmp r13d, eax
    cmova r13d, eax
    mov rcx, [rbx + PT_in]
    lea rdx, [rbx + r12 + PT_data]
    mov r8d, r13d
    lea r9, [rsp + 96]
    mov qword ptr [rsp + 32], 0
    API WriteFile
    test eax, eax
    jz 8f
    mov eax, [rsp + 96]
    add [rbx + PT_tail], eax
    jmp 1b
8:  mov dword ptr [rbx + PT_stop], 1
9:  xor eax, eax
    CALLBACK_END 16

# Ownership of the output pipe transfers here after watch_remove. The drainer reads while
# ClosePseudoConsole flushes its final output, so neither closing nor large output stalls the UI.
FN win_pty_close
    PROLOGUE 96
    mov rbx, [rdi + FD_aux]
    mov dword ptr [rbx + PT_stop], 1
    mov rcx, [rbx + PT_event]
    API SetEvent
    mov rcx, [rbx + PT_thread]
    test rcx, rcx
    jz 1f
    API CancelSynchronousIo
1:  xor ecx, ecx
    xor edx, edx
    lea r8, [rip + pty_shutdown]
    mov r9, rbx
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    API CreateThread
    test rax, rax
    jz 9f                       # retain resources until process exit if thread creation fails
    mov rcx, rax
    API CloseHandle
9:  EPILOGUE

pty_drain:
    CALLBACK 4112
    mov rbx, rcx
1:  mov rcx, [rbx + PT_out]
    lea rdx, [rsp + 112]
    mov r8d, 4096
    lea r9, [rsp + 96]
    mov qword ptr [rsp + 32], 0
    API ReadFile
    test eax, eax
    jnz 1b
    xor eax, eax
    CALLBACK_END 4112

pty_shutdown:
    CALLBACK
    mov rbx, rcx
    # Start draining before waiting for the input writer, which may itself be blocked by
    # a pseudoconsole whose output pipe is full.
    xor ecx, ecx
    xor edx, edx
    lea r8, [rip + pty_drain]
    mov r9, rbx
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    API CreateThread
    mov r12, rax
    test rax, rax
    jnz 1f
    mov rcx, [rbx + PT_out]
    API CloseHandle
    mov qword ptr [rbx + PT_out], 0
1:  mov rcx, [rbx + PT_thread]
    test rcx, rcx
    jz 3f
2:  mov rcx, [rbx + PT_thread]
    API CancelSynchronousIo
    mov rcx, [rbx + PT_thread]
    mov edx, 10
    API WaitForSingleObject
    cmp eax, 258
    je 2b
    mov rcx, [rbx + PT_thread]
    API CloseHandle
3:  mov rcx, [rbx + PT_in]
    API CloseHandle
    mov rcx, [rbx + PT_pc]
    API ClosePseudoConsole
    test r12, r12
    jz 4f
    mov rcx, r12
    mov edx, -1
    API WaitForSingleObject
    mov rcx, r12
    API CloseHandle
    mov rcx, [rbx + PT_out]
    API CloseHandle
4:  mov rcx, [rbx + PT_event]
    API CloseHandle
    mov rcx, rbx
    xor edx, edx
    mov r8d, 0x8000
    API VirtualFree
    xor eax, eax
    CALLBACK_END

.section .rdata,"dr"
.Lexe: .short '.', 'e', 'x', 'e', 0
.Lpath_var: .short 'P', 'A', 'T', 'H', 0

# win_new_window(folder) -> 1 when started: rhun.exe opens the folder in a window of its own. Not
# through proc_spawn, whose job object would close it with this one.
FN win_new_window
    PROLOGUE 8464
    # locals: startup 96..199, process info 208..231, this program 240..8431, argv 8440..8463
    mov [rsp + 8432], rdi
    xor ecx, ecx
    lea rdx, [rsp + 240]
    mov r8d, 4096
    API GetModuleFileNameW
    test eax, eax
    jz 8f
    cmp eax, 4096
    jae 8f
    cmp eax, 4
    jb 8f
    lea rbx, [rsp + 240]
    # the console rhun.com starts the window's rhun.exe
    lea rdx, [rbx + rax*2 - 6]
    mov word ptr [rdx], 'e'
    mov word ptr [rdx + 2], 'x'
    mov word ptr [rdx + 4], 'e'
    mov rax, [rip + g_argv]
    mov rax, [rax]
    mov [rsp + 8440], rax
    mov rax, [rsp + 8432]
    mov [rsp + 8448], rax
    mov qword ptr [rsp + 8456], 0
    lea rdi, [rsp + 8440]
    call win_commandline
    mov r12, rax
    test rax, rax
    jz 8f
    lea rdi, [rsp + 96]
    xor esi, esi
    mov edx, 136
    call memset
    mov dword ptr [rsp + 96], 104
    mov rcx, rbx
    mov rdx, r12
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 8   # DETACHED_PROCESS
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    lea rax, [rsp + 96]
    mov [rsp + 64], rax
    lea rax, [rsp + 208]
    mov [rsp + 72], rax
    API CreateProcessW
    mov r13d, eax
    mov rdi, r12
    call mem_free
    test r13d, r13d
    jz 8f
    mov rcx, [rsp + 208]
    API CloseHandle
    mov rcx, [rsp + 216]
    API CloseHandle
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# Console entry launches the GUI sibling unless --wait or scripting kept it attached.
FN win_detach
    PROLOGUE 8432
    API GetConsoleWindow
    test rax, rax
    jz 9f
    xor ecx, ecx
    lea rdx, [rsp + 240]
    mov r8d, 4096
    API GetModuleFileNameW
    test eax, eax
    jz 9f
    cmp eax, 4096
    jae 9f
    cmp eax, 4
    jb 9f
    lea rbx, [rsp + 240]
    lea rdx, [rbx + rax*2 - 6]
    mov word ptr [rdx], 'e'
    mov word ptr [rdx + 2], 'x'
    mov word ptr [rdx + 4], 'e'
    mov rdi, [rip + g_argv]
    call win_commandline
    mov r12, rax
    test rax, rax
    jz 9f
    lea rdi, [rsp + 96]
    xor esi, esi
    mov edx, 136
    call memset
    mov dword ptr [rsp + 96], 104
    mov rcx, rbx
    mov rdx, r12
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 8   # DETACHED_PROCESS
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    lea rax, [rsp + 96]
    mov [rsp + 64], rax
    lea rax, [rsp + 208]
    mov [rsp + 72], rax
    API CreateProcessW
    mov r13d, eax
    mov rdi, r12
    call mem_free
    test r13d, r13d
    jz 9f
    mov rcx, [rsp + 208]
    API CloseHandle
    mov rcx, [rsp + 216]
    API CloseHandle
    xor edi, edi
    call sys_exit
9:  EPILOGUE
