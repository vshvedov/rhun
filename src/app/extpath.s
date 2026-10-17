# Files an extension may ask the host to open without a user choosing the target. Document
# access covers existing tabs; a new tab must stay within the extension's declared disk roots.
.include "rhun.inc"

.text

# ext_realpath(path, buf[4096]) -> eax 1 with the existing path resolved, else 0.
# Resolve links before comparing roots, including links in parent folders.
ext_realpath:
.ifdef MACOS
    SYS SYS_realpath
    test rax, rax
    setnz al
    movzx eax, al
    ret
.else
    PROLOGUE 48
    mov r12, rsi
.ifdef WINDOWS
    mov edx, 4096
    call win_realpath
    test rax, rax
    js 8f
.else
    mov esi, O_PATH | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 8f
    mov ebx, eax
    lea rdi, [rsp]
    lea rsi, [rip + .Lfd]
    call cstr_copy
    mov rdi, rax
    mov esi, ebx
    call fmt_u64
    mov byte ptr [rdi], 0
    mov rdi, rsp
    mov rsi, r12
    mov edx, 4095
    SYS SYS_readlink
    mov r13, rax
    mov edi, ebx
    SYS SYS_close
    mov rax, r13
    test rax, rax
    js 8f
    cmp rax, 4095
    jae 8f
.endif
    mov byte ptr [r12 + rax], 0
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
.endif

# ext_open_path(ext or 0, path) -> owned path to open, or 0 when unavailable or forbidden.
# A zero extension means a user-selected action: resolve aliases without gating disk roots.
# Already-open documents retain their spelling so app_open_file activates their existing tab.
FN ext_open_path
    PROLOGUE 8192
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call app_find_tab
    test rax, rax
    js 1f
    mov rdi, r12
    call dup_cstr
    EPILOGUE
1:  mov rdi, r12
    mov rsi, rsp
    call ext_realpath
    test eax, eax
    jz 8f
    # A tab may itself have been opened through a symbolic link or another spelling.
    # Reuse its text and version, not a second copy read from disk.
    xor r13d, r13d
3:  cmp r13, [rip + g_tabs + VEC_len]
    jae 5f
    mov rdi, r13
    inc r13
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 3b
    mov rax, [rax + TAB_doc]
    mov r14, [rax + DOC_path]
    test r14, r14
    jz 3b
    mov rdi, r14
    lea rsi, [rsp + 4096]
    call ext_realpath
    test eax, eax
    jz 3b
    mov rdi, rsp
    lea rsi, [rsp + 4096]
.ifdef WINDOWS
    call win_path_equal
.else
    call strcmp_eq
.endif
    test eax, eax
    jz 3b
    mov rdi, r14
    call dup_cstr
    EPILOGUE
5:  test rbx, rbx
    jz 7f
    # Installed files and private state are always readable by their own extension.
    mov rdi, [rbx + EXT_dir]
    call .Lroot
    test eax, eax
    jnz 7f
    mov rdi, [rbx + EXT_state]
    call .Lroot
    test eax, eax
    jnz 7f
    test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_READ | NEEDS_PROJECT_WRITE
    jz 2f
    mov rdi, [rip + g_project]
    call .Lroot
    test eax, eax
    jnz 7f
2:  test dword ptr [rbx + EXT_needs], NEEDS_HOME_READ
    jz 8f
    lea rdi, [rip + .Lhome]
    call getenv
    mov rdi, rax
    call .Lroot
    test eax, eax
    jz 8f
7:  mov rdi, rsp
    call dup_cstr
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# A helper within ext_open_path's frame. Resolve each permitted root independently.
.Lroot:
    test rdi, rdi
    jz 9f
    push rbx
    lea rsi, [rsp + 16 + 4096]
    call ext_realpath
    test eax, eax
    jz 1f
    lea rdi, [rsp + 16]
    lea rsi, [rsp + 16 + 4096]
    call app_path_inside
1:  pop rbx
    ret
9:  xor eax, eax
    ret

.section .rodata
.Lfd: .asciz "/proc/self/fd/"
.Lhome: .asciz "HOME"
