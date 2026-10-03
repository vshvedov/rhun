# Embedded update helper. The detached apply process must outlive the editor's job objects.
.include "win.inc"
.bss
.p2align 3
wu_fields: .zero SB_SIZE * 6
wu_env: .quad 0
wu_shell: .quad 0
wu_argv: .zero 64
.text

# win_update_command(action, version, executable, release URL) -> argv, envp in rdx.
FN win_update_command
    PROLOGUE 96
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov [rsp + 24], rcx
    mov rdi, [rip + wu_env]
    call mem_free
    mov rdi, [rip + wu_shell]
    call mem_free
    xor r12d, r12d
1:  lea rbx, [rip + wu_fields]
    imul rax, r12, SB_SIZE
    add rbx, rax
    mov rdi, rbx
    call sb_clear
    lea rax, [rip + .Lprefixes]
    mov rsi, [rax + r12*8]
    mov rdi, rbx
    call sb_push_cstr
    cmp r12d, 4
    je 2f
    cmp r12d, 5
    je 3f
    mov rsi, [rsp + r12*8]
    jmp 4f
2:  SYS SYS_getpid
    mov rsi, rax
    mov rdi, rbx
    call sb_push_u64
    jmp 5f
3:  mov rsi, [rip + g_project]
4:  mov rdi, rbx
    call sb_push_cstr
5:  mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    mov rax, [rbx + SB_ptr]
    mov [rsp + 32 + r12*8], rax
    inc r12
    cmp r12d, 6
    jb 1b
    mov qword ptr [rsp + 80], 0
    lea rdi, [rsp + 32]
    call env_make
    mov [rip + wu_env], rax
    lea rdi, [rip + .Lshell]
    call proc_which
    mov [rip + wu_shell], rax
    test rax, rax
    jz 9f
    lea rbx, [rip + wu_argv]
    mov [rbx], rax
    lea rax, [rip + .Lnoprofile]
    mov [rbx + 8], rax
    lea rax, [rip + .Lnoninteractive]
    mov [rbx + 16], rax
    lea rax, [rip + .Loutputformat]
    mov [rbx + 24], rax
    lea rax, [rip + .Ltext]
    mov [rbx + 32], rax
    lea rax, [rip + windows_helper_flag]
    mov [rbx + 40], rax
    lea rax, [rip + windows_update_script]
    mov [rbx + 48], rax
    mov qword ptr [rbx + 56], 0
    mov rdx, [rip + wu_env]
    mov rax, rbx
9:  EPILOGUE

# win_update_launch(argv, envp) -> 1 if the detached updater started, 0 otherwise.
FN win_update_launch
    PROLOGUE 256
    mov r12, rdi
    mov r13, rsi
    call win_commandline
    mov r14, rax
    test rax, rax
    jz 8f
    mov rdi, r13
    call win_environment
    mov r13, rax
    test rax, rax
    jz 7f
    mov rdi, [r12]
    call win_wide
    mov r12, rax
    test rax, rax
    jz 6f
    lea rdi, [rsp + 96]
    xor esi, esi
    mov edx, 136
    call memset
    mov dword ptr [rsp + 96], 104
    mov rcx, r12
    mov rdx, r14
    xor r8d, r8d
    xor r9d, r9d
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0x08000400 # CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT
    mov [rsp + 48], r13
    mov qword ptr [rsp + 56], 0
    lea rax, [rsp + 96]
    mov [rsp + 64], rax
    lea rax, [rsp + 208]
    mov [rsp + 72], rax
    API CreateProcessW
    mov ebx, eax
    test eax, eax
    jz 5f
    mov rcx, [rsp + 208]
    API CloseHandle
    mov rcx, [rsp + 216]
    API CloseHandle
5:  mov rdi, r12
    call mem_free
    mov rdi, r13
    call mem_free
    mov rdi, r14
    call mem_free
    mov eax, ebx
    EPILOGUE
6:  mov rdi, r13
    call mem_free
7:  mov rdi, r14
    call mem_free
8:  xor eax, eax
    EPILOGUE

FN win_update_error
    PROLOGUE 96
    xor ecx, ecx
    lea rdx, [rip + .Lfailed]
    lea r8, [rip + .Ltitle]
    mov r9d, 0x10
    API MessageBoxW
    EPILOGUE

.section .rdata,"dr"
.Lshell: .asciz "powershell.exe"
.Lnoprofile: .asciz "-NoProfile"
.Lnoninteractive: .asciz "-NonInteractive"
.Loutputformat: .asciz "-OutputFormat"
.Ltext: .asciz "Text"
.Laction: .asciz "RHUN_UP_ACTION="
.Lversion: .asciz "RHUN_UP_VERSION="
.Lexe: .asciz "RHUN_UP_EXE="
.Lurl: .asciz "RHUN_UP_URL="
.Lpid: .asciz "RHUN_UP_PID="
.Lproject: .asciz "RHUN_UP_PROJECT="
.Ltitle: .short 'r', 'h', 'u', 'n', 0
.Lfailed: .short 'T', 'h', 'e', ' ', 'u', 'p', 'd', 'a', 't', 'e', 'r', ' ', 'c', 'o', 'u', 'l', 'd', ' ', 'n', 'o', 't', ' ', 's', 't', 'a', 'r', 't', '.', ' ', 'R', 'e', 'o', 'p', 'e', 'n', ' ', 'r', 'h', 'u', 'n', ' ', 'a', 'n', 'd', ' ', 't', 'r', 'y', ' ', 'a', 'g', 'a', 'i', 'n', '.', 0
.p2align 3
.Lprefixes: .quad .Laction, .Lversion, .Lexe, .Lurl, .Lpid, .Lproject
