# confinement of extension processes (docs/extensions/v1.md section 5; the design's section 6):
# on Linux, Landlock rules built from [needs] plus a user and network namespace for
# network = no; on macOS, sandbox_init with a profile generated from the same. The parent
# prepares everything here (rule descriptors, attributes, map strings, the profile text) before
# the fork; the child (confine_child, from proc_spawn) only issues the syscalls and, when one
# fails, records its code in a page shared with the parent and exits; ext_exited turns that into
# "not confined: reason".
.include "rhun.inc"

.bss
.p2align 3
.globl conf_pending
conf_pending: .long 0           # 1 while a prepared confinement waits for the next proc_spawn child
conf_flags: .long 0             # CF_*
conf_abi: .long 0               # the Landlock ABI (probe), -1 when unavailable
conf_userns: .long 0            # 1 when an unprivileged user namespace can be made (probe)
conf_probed: .long 0
conf_log: .byte 0               # RHUN_CONFINE_LOG set: every rule is written to the program's log
.p2align 3
logbuf: .zero 4300
.p2align 3
conf_attr: .zero 24             # struct landlock_ruleset_attr: handled_access_fs, _net, scoped
conf_attr_size: .quad 0
conf_handled: .quad 0           # the fs rights this ABI handles
conf_rules: .zero VEC_SIZE      # CR records
conf_uidmap: .zero 48           # "U U 1" and "G G 1"
conf_gidmap: .zero 48
conf_profile: .zero SB_SIZE     # macOS: the SBPL profile text
conf_reason: .quad 0            # why confinement is impossible (cstr), or 0
conf_ext: .quad 0               # the EXT being prepared (its log takes the rule list)
conf_fail: .long 0              # the child's failure code when it exits (set by the parent on the
                                #   way out of confine_child: a code to exit with)
.p2align 3
conf_page: .quad 0              # a page shared with the forked children: byte [slot] is the EXITC_*
                                #   code a child failed with before its exec. Not the exit status:
                                #   the program can exit with any code, but after exec it has no
                                #   way to this page
conf_slot: .quad 0              # the EXT being prepared, as an index into g_exts
pathbuf: .zero 4200
pathbuf2: .zero 4200
realbuf: .zero 4200             # profile_path's resolved path (never the buffer it reads from)
devbuf: .zero 4200              # the active Xcode developer folder (xcode_shim)
# macOS: xcrun's cache filled outside the sandbox (xcode_shim, prime_note, prime_start)
.p2align 3
conf_prime: .long 0             # 0 undecided, 1 a primer fills the cache, 2 none
conf_prime_n: .long 0           # tools in conf_prime_tools
conf_prime_used: .quad 0        # bytes of conf_prime_names in use
conf_prime_tools: .zero 8 * 8   # the shim tools' names, in conf_prime_names
conf_prime_argv: .zero 4 * 8    # xcrun --find TOOL
conf_prime_env: .zero 5 * 8
conf_prime_names: .zero 1024
conf_prime_xdb: .zero 4200      # "xcrun_db=" and the primer's own cache, beside the state folder
conf_prime_dst: .zero 4200      # the extension's cache, where the primer's goes when it is done
conf_primed: .zero 64 * 8       # the caches a primer was started for in this session (copies)
interpbuf: .zero 4200           # a #! interpreter's real path (profile_program)
parentbuf: .zero 4200
rustupbuf: .zero 4200
treebuf: .zero 4200             # and its install tree
elfhdr: .zero 256               # an ELF header, or a #! line (macOS reads 512 bytes of it, Linux 256)
phdr: .zero 56

.text

# rustup keeps toolchains outside HOME. The extension's HOME remains private; only a declared
# rustup proxy receives access to this installation, never the user's Cargo credentials.
FN confine_rustup_home
    PROLOGUE
    lea rdi, [rip + .Lenv_rustup]
    call getenv
    test rax, rax
    jz 1f
    cmp byte ptr [rax], '/'
    je 2f
1:  lea rdi, [rip + .Lenv_home]
    call getenv
    test rax, rax
    jz 9f
    mov rdi, rax
    lea rsi, [rip + .Lrustup_dir]
    call path_join_tmp
2:  mov rbx, rax
    mov rdi, rax
    call strlen
    cmp rax, 4096
    jae 9f
    lea rdi, [rip + rustupbuf]
    mov rsi, rbx
    lea rdx, [rax + 1]
    call memcpy
    lea rax, [rip + rustupbuf]
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# @build explicitly permits generated programs in the extension's state and writable projects.
# Compilers use these for Swift manifests, Cargo build scripts and Zig build runners.
confine_builds:
    PROLOGUE
    mov rbx, [rdi + EXT_runs]
    test rbx, rbx
    jz 8f
    mov rdi, rbx
    call strlen
    mov r12, rax
1:  test r12, r12
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call next_word
    add rbx, rcx
    sub r12, rcx
    cmp rdx, 6
    jne 1b
    mov rdi, rax
    mov esi, 6
    lea rdx, [rip + .Lbuild_token]
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- the probe ----------------

# confine_probe(): once: the Landlock ABI and whether a user namespace can be made (Linux)
confine_probe:
    PROLOGUE
    cmp dword ptr [rip + conf_probed], 0
    jne 9f
    mov dword ptr [rip + conf_probed], 1
.ifdef MACOS
    mov dword ptr [rip + conf_abi], 0
    mov dword ptr [rip + conf_userns], 0
.else
    xor edi, edi
    xor esi, esi
    mov edx, LL_VERSION
    SYS SYS_landlock_create_ruleset
    test rax, rax
    jns 1f
    mov eax, -1
1:  mov [rip + conf_abi], eax
    # the maps the namespace will need
    SYS SYS_getuid
    lea rdi, [rip + conf_uidmap]
    call map_line
    SYS SYS_getgid
    lea rdi, [rip + conf_gidmap]
    call map_line
    lea rdi, [rip + .Lenv_conflog]
    call getenv
    test rax, rax
    setnz byte ptr [rip + conf_log]
    # a throwaway child tries the whole namespace sequence: on a system that restricts
    # unprivileged user namespaces (Ubuntu's AppArmor default) unshare itself succeeds, into a
    # namespace without capabilities, and the map writes are what fail
    SYS SYS_fork
    test rax, rax
    js 9f
    jnz 2f
    mov edi, CLONE_NEWUSER | CLONE_NEWNET
    SYS SYS_unshare
    test rax, rax
    js 3f
    lea rdi, [rip + .Lp_setgroups]
    lea rsi, [rip + .Ls_deny]
    call write_proc
    test rax, rax
    js 3f
    lea rdi, [rip + .Lp_uidmap]
    lea rsi, [rip + conf_uidmap]
    call write_proc
    test rax, rax
    js 3f
    lea rdi, [rip + .Lp_gidmap]
    lea rsi, [rip + conf_gidmap]
    call write_proc
    test rax, rax
    js 3f
    xor edi, edi
    SYS SYS_exit
3:  mov edi, 1
    SYS SYS_exit
2:  mov edi, eax
    xor esi, esi
    call proc_wait
    test eax, eax
    jnz 9f
    mov dword ptr [rip + conf_userns], 1
.endif
9:  EPILOGUE

# ---------------- preparing (the parent) ----------------

# confine_prepare(ext) -> 0 when a confinement is prepared for the next proc_spawn (conf_pending),
# else a cstr saying why it cannot be: the caller decides what that means
FN confine_prepare
    PROLOGUE 16
    mov rbx, rdi
    mov [rip + conf_ext], rdi
    call slot_arm
    mov dword ptr [rbx + EXT_confined], CONFINED_NO
    mov dword ptr [rip + conf_pending], 0
    mov dword ptr [rip + conf_flags], 0
    mov qword ptr [rip + conf_reason], 0
    call confine_probe
    call rules_release
.ifdef MACOS
    call profile_build
    test rax, rax
    jnz .Lcp_fail
    or dword ptr [rip + conf_flags], CF_SANDBOX
    mov dword ptr [rbx + EXT_confined], CONFINED_FULL
.else
    mov eax, [rip + conf_abi]
    cmp eax, 0
    jge 1f
    lea rax, [rip + .Lr_no_landlock]
    jmp .Lcp_fail
1:  cmp eax, 3
    jge 2f
    lea rax, [rip + .Lr_old_landlock]
    jmp .Lcp_fail
2:  # the handled rights of this ABI
    mov rcx, LL_EXECUTE | LL_WRITE_FILE | LL_READ_FILE | LL_READ_DIR | LL_REMOVE_DIR | LL_REMOVE_FILE | LL_MAKE_CHAR | LL_MAKE_DIR | LL_MAKE_REG | LL_MAKE_SOCK | LL_MAKE_FIFO | LL_MAKE_BLOCK | LL_MAKE_SYM | LL_REFER | LL_TRUNCATE
    cmp eax, 5
    jl 3f
    or rcx, LL_IOCTL_DEV
3:  mov [rip + conf_handled], rcx
    mov [rip + conf_attr], rcx
    mov qword ptr [rip + conf_attr + 8], 0
    mov qword ptr [rip + conf_attr + 16], 0
    mov qword ptr [rip + conf_attr_size], 8
    cmp eax, 4
    jl 4f
    mov qword ptr [rip + conf_attr_size], 16
    cmp eax, 6
    jl 4f
    mov qword ptr [rip + conf_attr_size], 24
4:  mov dword ptr [rbx + EXT_confined], CONFINED_FULL
    # network = no: a namespace when the system allows one, else TCP rules (ABI 4), else nothing
    test dword ptr [rbx + EXT_needs], NEEDS_NETWORK
    jnz 6f
    cmp dword ptr [rip + conf_userns], 0
    je 5f
    or dword ptr [rip + conf_flags], CF_NETNS
    jmp 51f
5:  cmp dword ptr [rip + conf_abi], 4
    jge 52f
    lea rax, [rip + .Lr_no_net]
    jmp .Lcp_fail
52: mov dword ptr [rbx + EXT_confined], CONFINED_TCP
51: cmp dword ptr [rip + conf_abi], 4
    jl 6f
    mov qword ptr [rip + conf_attr + 8], LL_NET_BIND_TCP | LL_NET_CONNECT_TCP
6:  # the rules (the maps were built by the probe)
    call rules_build
    test rax, rax
    jnz .Lcp_fail
    or dword ptr [rip + conf_flags], CF_LANDLOCK
.endif
    mov dword ptr [rip + conf_pending], 1
    xor eax, eax
    EPILOGUE
.Lcp_fail:
    mov r12, rax
    mov [rip + conf_reason], rax
    call rules_release
    mov dword ptr [rbx + EXT_confined], CONFINED_NO
    mov rax, r12
    EPILOGUE

# slot_arm(ext): its slot in the shared page (mapped the first time), cleared
slot_arm:
    push rbx
    mov rax, rdi
    sub rax, [rip + g_exts + VEC_ptr]
    xor edx, edx
    mov ecx, EXT_SIZE
    div rcx
    mov [rip + conf_slot], rax
    cmp qword ptr [rip + conf_page], 0
    jne 1f
    xor edi, edi
    mov esi, 4096
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_SHARED | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    SYS SYS_mmap
    cmp rax, -4096
    ja 9f                       # no page: a failed child then counts as the program's exit
    mov [rip + conf_page], rax
1:  mov rax, [rip + conf_page]
    add rax, [rip + conf_slot]
    mov byte ptr [rax], 0
9:  pop rbx
    ret

# confine_failed(ext) -> eax the EXITC_* code its child failed with before the exec, or 0 (the
# exit was the program's own); reading clears it
FN confine_failed
    xor eax, eax
    mov rcx, [rip + conf_page]
    test rcx, rcx
    jz 9f
    mov rax, rdi
    sub rax, [rip + g_exts + VEC_ptr]
    xor edx, edx
    mov esi, EXT_SIZE
    div rsi
    add rcx, rax
    movzx eax, byte ptr [rcx]
    mov byte ptr [rcx], 0
9:  ret

# map_line(buf, id in eax): "ID ID 1"
map_line:
    push rbx
    mov rbx, rdi
    mov esi, eax
    push rsi
    push rsi
    call fmt_u64
    mov byte ptr [rdi], ' '
    inc rdi
    pop rsi
    pop rsi
    call fmt_u64
    mov byte ptr [rdi], ' '
    mov byte ptr [rdi + 1], '1'
    mov byte ptr [rdi + 2], 0
    pop rbx
    ret

# confine_release(): after the spawn, the parent closes the rule descriptors and drops the rest
FN confine_release
    push rbx
    mov dword ptr [rip + conf_pending], 0
.ifdef MACOS
    call prime_start            # Xcode's shims: their cache, beside the running extension
.endif
    call rules_release
    pop rbx
    ret

rules_release:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + conf_rules + VEC_len]
    jae 2f
    imul rax, rbx, CR_SIZE
    add rax, [rip + conf_rules + VEC_ptr]
    mov edi, [rax + CR_fd]
    SYS SYS_close
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + conf_rules + VEC_len], 0
    lea rdi, [rip + conf_profile]
    call sb_clear
    EPILOGUE

.ifndef MACOS
# rules_build() -> 0, or a reason cstr: the Landlock rules for rbx (the EXT)
# audio_rule(environment name, relative path, rights): only the named audio resource.
audio_rule:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    call getenv
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, r12
    call path_join
    mov r12, rax
    mov rdi, rax
    mov rsi, r13
    call add_rule
    mov rdi, r12
    call mem_free
9:  EPILOGUE

rules_build:
    PROLOGUE
    # the system, read-only, where present
    lea r12, [rip + sys_dirs]
1:  mov rdi, [r12]
    test rdi, rdi
    jz 2f
    add r12, 8
    mov rsi, LL_RO
    call add_rule
    jmp 1b
2:  lea rdi, [rip + .Lp_devnull]
    mov rsi, LL_READ_FILE | LL_WRITE_FILE
    call add_rule
    test dword ptr [rbx + EXT_needs], NEEDS_AUDIO
    jz 21f
    lea rdi, [rip + .Lp_sound]
    mov rsi, LL_RO | LL_WRITE_FILE | LL_IOCTL_DEV
    call add_rule
    lea rdi, [rip + .Lenv_runtime]
    lea rsi, [rip + .La_pulse]
    mov rdx, LL_RO | LL_WRITE_FILE
    call audio_rule
    lea rdi, [rip + .Lenv_home]
    lea rsi, [rip + .La_cookie]
    mov rdx, LL_READ_FILE
    call audio_rule
21:
    # the extension folder, its script, its state folder
    mov rdi, [rbx + EXT_dir]
    mov rsi, LL_RO
    call add_rule
    mov rdi, [rbx + EXT_script]
    test rdi, rdi
    jz 3f
    mov rsi, LL_READ_FILE
    call add_rule
3:  mov rdi, rbx
    call confine_builds
    mov esi, LL_RW
    test eax, eax
    jz 301f
    or rsi, LL_EXECUTE
301: mov rdi, [rbx + EXT_state]
    call add_rule
    test rax, rax
    jnz 31f
    lea rax, [rip + .Lr_state]
    jmp 9f
31: # the project: every workspace folder (resources group, workspace.s)
    test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_READ | NEEDS_PROJECT_WRITE
    jz 4f
    xor r12d, r12d
33: call wfold_count
    cmp r12, rax
    jae 4f
    mov rdi, r12
    call wfold_path
    inc r12
    mov rdi, rax
    test rdi, rdi
    jz 33b
    mov rsi, LL_RO
    test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_WRITE
    jz 32f
    push rdi
    push rdi
    mov rdi, rbx
    call confine_builds
    mov esi, LL_RW
    test eax, eax
    jz 321f
    or rsi, LL_EXECUTE
321:pop rdi
    pop rdi
32: call add_rule
    jmp 33b
4:  # the user's home
    test dword ptr [rbx + EXT_needs], NEEDS_HOME_READ
    jz 5f
    lea rdi, [rip + .Lenv_home]
    call getenv
    test rax, rax
    jz 5f
    mov rdi, rax
    mov rsi, LL_RO
    call add_rule
5:  # the programs: the entry (the runtime for a script), then the run list
    mov rdi, [rbx + EXT_prog]
    call add_program
    test rax, rax
    jz 6f
    jmp 9f
6:  mov r12, [rbx + EXT_runs]
    test r12, r12
    jz 8f
    mov rdi, r12
    call strlen
    mov r13, rax
7:  test r13, r13
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 8f
    cmp rdx, 4096
    jae 7b                     # cannot name a program on this platform
    lea rdi, [rip + pathbuf]
    mov rsi, rax
    mov rcx, rdx
    push rdi
    rep movsb
    mov byte ptr [rdi], 0
    pop rdi
    push rdi
    push rdi
    call uproc_login_path       # found where the extension finds it (its PATH, build_env)
    pop rdi
    pop rdi
    mov rsi, rax
    call proc_which_in
    test rax, rax
    jz 7b                       # not installed: the program will say so itself
    mov r14, rax
    mov rdi, rax
    call add_program
    mov rdi, r14
    push rax
    push rax
    call mem_free
    pop rax
    pop rax
    test rax, rax
    jnz 9f
    jmp 7b
8:  xor eax, eax
9:  EPILOGUE

# add_program(path cstr) -> 0 or a reason: read and execute on the file, its ELF loader or #!
# interpreter, and its install tree when it has one
add_program:
    PROLOGUE
    mov rbx, rdi
    mov rsi, LL_READ_FILE | LL_EXECUTE
    call add_rule
    test rax, rax
    jnz 1f
    lea rax, [rip + .Lr_program]
    EPILOGUE
1:  mov rdi, rbx
    lea rsi, [rip + pathbuf2]
    call interp_of
    test eax, eax
    jz 2f
    lea rdi, [rip + pathbuf2]
    mov rsi, LL_READ_FILE | LL_EXECUTE
    call add_rule
    # the loader's own loader (a #! interpreter is usually dynamic)
    lea rdi, [rip + pathbuf2]
    lea rsi, [rip + pathbuf]
    call interp_of
    test eax, eax
    jz 2f
    lea rdi, [rip + pathbuf]
    mov rsi, LL_READ_FILE | LL_EXECUTE
    call add_rule
2:  mov rdi, rbx
    lea rsi, [rip + pathbuf]
    call install_tree
    test eax, eax
    jz 3f
    lea rdi, [rip + pathbuf]
    mov rsi, LL_RO | LL_EXECUTE
    call add_rule
3:  mov rdi, rbx
    lea rsi, [rip + pathbuf2]
    SYS SYS_realpath
    test rax, rax
    jz 39f
    lea rdi, [rip + pathbuf2]
    call strlen
    mov rsi, rax
    lea rdi, [rip + pathbuf2]
    lea rdx, [rip + .Lrustup_exe]
    mov ecx, 7
    call str_ends
    test eax, eax
    jz 39f
    call confine_rustup_home
    test rax, rax
    jz 39f
    mov rdi, rax
    lea rsi, [rip + .Lrustup_tools]
    call path_join_tmp
    mov rdi, rax
    mov esi, LL_RO | LL_EXECUTE
    call add_rule
    call confine_rustup_home
    mov rdi, rax
    lea rsi, [rip + .Lrustup_settings]
    call path_join_tmp
    mov rdi, rax
    mov esi, LL_READ_FILE
    call add_rule
39: xor eax, eax
    EPILOGUE

# add_rule(path cstr, rights) -> 1 when a rule was added, 0 when the path does not exist (a
# missing system folder; nothing is said); the rights are cut to what the ABI handles and, on a
# file, to the file rights
add_rule:
    PROLOGUE 160
    mov rbx, rdi
    mov r12, rsi
    mov esi, O_PATH | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 8f
    mov r13d, eax
    mov edi, eax
    mov rsi, rsp
    SYS SYS_fstat
    mov eax, [rsp + 24]         # st_mode
    and eax, 0xf000
    cmp eax, 0x4000
    je 1f
    and r12, LL_FILE_RIGHTS
1:  and r12, [rip + conf_handled]
    lea rdi, [rip + conf_rules]
    mov esi, CR_SIZE
    call vec_push
    mov [rax + CR_access], r12
    mov [rax + CR_fd], r13d
    mov dword ptr [rax + CR_pad], 0
    cmp byte ptr [rip + conf_log], 0
    je 2f
    lea rdi, [rip + logbuf]
    lea rsi, [rip + .Llog_rule]
    call cstr_copy
    mov rdi, rax
    mov rsi, r12
    call fmt_u64
    mov byte ptr [rdi], ' '
    inc rdi
    mov rsi, rbx
    call cstr_copy
    mov byte ptr [rax], 10
    lea rsi, [rip + logbuf]
    lea rdx, [rax + 1]
    sub rdx, rsi
    mov rax, [rip + conf_ext]
    mov edi, [rax + EXT_log]
    SYS SYS_write
2:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
.endif

# interp_of(path, out buf) -> 1 and the path of the program's ELF interpreter (PT_INTERP) or of its
# #! interpreter in out, 0 when it has none (a static binary, a script with no #!); on macOS only
# the #! one counts (dyld comes from /usr/lib, readable to all)
interp_of:
    PROLOGUE 160
    mov rbx, rdi
    mov r12, rsi
    mov esi, O_RDONLY | O_NONBLOCK | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 8f
    mov r13d, eax
    mov edi, eax
    lea rsi, [rsp + 16]
    SYS SYS_fstat              # a regular file only: no FIFO or device to block on
    test rax, rax
    js .Lio_none
    mov eax, [rsp + 40]
    and eax, 0xf000
    cmp eax, 0x8000
    jne .Lio_none
    lea rdi, [rip + elfhdr]
    xor esi, esi
    mov edx, 256
    call memset
    mov edi, r13d
    lea rsi, [rip + elfhdr]
    mov edx, 255
    SYS SYS_read
    cmp rax, 64
    jb .Lio_shebang
    cmp dword ptr [rip + elfhdr], 0x464c457f        # "\\x7fELF"
    jne .Lio_shebang
    cmp byte ptr [rip + elfhdr + 4], 2              # ELF64
    jne .Lio_none
    # the program headers
    mov r14, [rip + elfhdr + 32]                    # e_phoff
    movzx r15d, word ptr [rip + elfhdr + 56]        # e_phnum
    movzx eax, word ptr [rip + elfhdr + 54]         # e_phentsize
    mov [rsp], rax
1:  test r15d, r15d
    jz .Lio_none
    dec r15d
    mov edi, r13d
    lea rsi, [rip + phdr]
    mov edx, 56
    mov r10, r14
    SYS SYS_pread
    cmp rax, 56
    jne .Lio_none
    add r14, [rsp]
    cmp dword ptr [rip + phdr], 3                   # PT_INTERP
    jne 1b
    mov r10, [rip + phdr + 8]                       # p_offset
    mov rdx, [rip + phdr + 32]                      # p_filesz
    test rdx, rdx
    jz .Lio_none
    cmp rdx, 4096
    ja .Lio_none
    mov edi, r13d
    mov rsi, r12
    SYS SYS_pread
    test rax, rax
    jle .Lio_none
    mov byte ptr [r12 + rax], 0
    jmp .Lio_yes
.Lio_shebang:
    cmp word ptr [rip + elfhdr], 0x2123             # "#!"
    jne .Lio_none
    # the first word after "#!" up to a space or line end (the header read has at most 255 bytes:
    # a virtual environment's interpreter path is often longer than 64)
    lea rsi, [rip + elfhdr + 2]
    mov rdi, r12
    xor ecx, ecx
2:  cmp ecx, 252
    jae 3f
    movzx eax, byte ptr [rsi + rcx]
    cmp al, ' '
    je 4f
    cmp al, 10
    je 3f
    test al, al
    jz 3f
    mov [rdi + rcx], al
    inc ecx
    jmp 2b
4:  test ecx, ecx
    jnz 3f
    inc rsi                     # "#! /bin/sh": skip the space
    jmp 2b
3:  mov byte ptr [rdi + rcx], 0
    test ecx, ecx
    jz .Lio_none
.Lio_yes:
    mov edi, r13d
    SYS SYS_close
    mov eax, 1
    EPILOGUE
.Lio_none:
    mov edi, r13d
    SYS SYS_close
8:  xor eax, eax
    EPILOGUE

# install_tree(program path, out buf) -> 1 and the folder two above the program in out, when it
# looks like an install tree: more than two path components and a lib, libexec, pkg or
# Frameworks folder inside (…/go/bin/go -> …/go; /usr/bin/python3 -> /usr: no)
install_tree:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call strlen
    mov r13, rax
    # cut two components from the end
    mov ecx, 2
1:  test r13, r13
    jz 8f
    dec r13
    cmp byte ptr [rbx + r13], '/'
    jne 1b
    dec ecx
    jnz 1b
    test r13, r13
    jz 8f                       # the root
    # the root's components: more than two ("/a/b" has two)
    xor edx, edx
    xor ecx, ecx
2:  cmp rcx, r13
    jae 3f
    cmp byte ptr [rbx + rcx], '/'
    jne 21f
    inc edx
21: inc rcx
    jmp 2b
3:  cmp edx, 3
    jb 8f
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r13
    call memcpy
    mov byte ptr [r12 + r13], 0
    lea r14, [rip + tree_marks]
4:  mov rsi, [r14]
    test rsi, rsi
    jz 8f
    add r14, 8
    mov rdi, r12
    call path_join_tmp
    mov rdi, rax
    call file_type
    cmp eax, 0x4000
    jne 4b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

.ifdef MACOS
# profile_build() -> 0 or a reason: the SBPL profile for rbx (the EXT) in conf_profile
profile_build:
    PROLOGUE
    lea rdi, [rip + conf_profile]
    call sb_clear
    mov dword ptr [rip + conf_prime], 0
    mov dword ptr [rip + conf_prime_n], 0
    mov qword ptr [rip + conf_prime_used], 0
    lea rdi, [rip + conf_profile]
    lea rsi, [rip + .Lsb_head]
    call sb_push_cstr
    lea rdi, [rip + conf_profile]
    lea rsi, [rip + .Lsb_dns]
    call sb_push_cstr
    test dword ptr [rbx + EXT_needs], NEEDS_AUDIO
    jz 90f
    lea rdi, [rip + conf_profile]
    lea rsi, [rip + .Lsb_audio]
    call sb_push_cstr
90:
    # the extension folder, its script and its state folder
    mov rdi, [rbx + EXT_dir]
    lea rsi, [rip + .Lsb_ro]
    call profile_path
    mov rdi, [rbx + EXT_script]
    test rdi, rdi
    jz 1f
    lea rsi, [rip + .Lsb_ro_lit]
    call profile_path
1:  mov rdi, [rbx + EXT_state]
    lea rsi, [rip + .Lsb_rw]
    call profile_path
    mov rdi, rbx
    call confine_builds
    test eax, eax
    jz 11f
    mov rdi, [rbx + EXT_state]
    lea rsi, [rip + .Lsb_exec_sub]
    call profile_path
    # Build runners watch source files through the macOS filesystem event service.
    lea rdi, [rip + conf_profile]
    lea rsi, [rip + .Lsb_build_watch]
    call sb_push_cstr
    # Foundation's atomic file replacement uses this OS-managed directory even
    # when TMPDIR points into state. macOS still isolates each process's items.
    lea rdi, [rip + .Lenv_tmpdir]
    call getenv
    test rax, rax
    jz 11f
    cmp byte ptr [rax], '/'
    jne 11f
    mov rdi, rax
    lea rsi, [rip + .Ltemporary_items]
    call path_join_tmp
    mov rdi, rax
    lea rsi, [rip + .Lsb_rw]
    call profile_path
11:
    # the project (every workspace folder: resources group, workspace.s) and the home
    test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_READ | NEEDS_PROJECT_WRITE
    jz 2f
    xor r12d, r12d
22: call wfold_count
    cmp r12, rax
    jae 2f
    mov rdi, r12
    call wfold_path
    inc r12
    mov rdi, rax
    test rdi, rdi
    jz 22b
    push rdi
    push rdi
    call profile_parents
    pop rdi
    pop rdi
    lea rsi, [rip + .Lsb_ro]
    test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_WRITE
    jz 21f
    lea rsi, [rip + .Lsb_rw]
21: call profile_path
    test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_WRITE
    jz 22b
    mov rdi, rbx
    call confine_builds
    test eax, eax
    jz 22b
    lea rdi, [r12 - 1]
    call wfold_path
    mov rdi, rax
    lea rsi, [rip + .Lsb_exec_sub]
    call profile_path
    jmp 22b
2:  test dword ptr [rbx + EXT_needs], NEEDS_HOME_READ
    jz 3f
    lea rdi, [rip + .Lenv_home]
    call getenv
    test rax, rax
    jz 3f
    mov rdi, rax
    lea rsi, [rip + .Lsb_ro]
    call profile_path
3:  # network
    lea rsi, [rip + .Lsb_net_deny]
    test dword ptr [rbx + EXT_needs], NEEDS_NETWORK
    jz 31f
    lea rsi, [rip + .Lsb_net_allow]
31: lea rdi, [rip + conf_profile]
    call sb_push_cstr
    # a Unix socket in its state folder may listen whatever network says: the user's own programs
    # reach it there (AI: the MCP bridge)
    mov rdi, [rbx + EXT_state]
    lea rsi, [rip + .Lsb_sock]
    call profile_path
    # programs
    mov rdi, [rbx + EXT_prog]
    call profile_program
    mov r12, [rbx + EXT_runs]
    test r12, r12
    jz 8f
    mov rdi, r12
    call strlen
    mov r13, rax
7:  test r13, r13
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 8f
    cmp rdx, 4096
    jae 7b
    lea rdi, [rip + pathbuf]
    mov rsi, rax
    mov rcx, rdx
    push rdi
    rep movsb
    mov byte ptr [rdi], 0
    pop rdi
    push rdi
    push rdi
    call uproc_login_path       # found where the extension finds it (its PATH, build_env)
    pop rdi
    pop rdi
    mov rsi, rax
    call proc_which_in
    test rax, rax
    jz 7b
    mov r14, rax
    mov rdi, rax
    call profile_program
    mov rdi, r14
    call mem_free
    jmp 7b
8:  lea rdi, [rip + .Lenv_conflog]
    call getenv
    test rax, rax
    jz 81f
    mov edi, 2                  # RHUN_CONFINE_LOG: the profile on standard error
    mov rsi, [rip + conf_profile + SB_ptr]
    mov rdx, [rip + conf_profile + SB_len]
    call write_all
81: lea rdi, [rip + conf_profile]
    xor esi, esi
    call sb_push_byte           # the profile is a cstr
    xor eax, eax
    EPILOGUE

# A tool searching for its project root may list ancestor directories. Literal directory
# rules expose names only; sibling files and parent configuration contents remain unreadable.
profile_parents:
    PROLOGUE
    lea rsi, [rip + parentbuf]
    SYS SYS_realpath
    test rax, rax
    jz 9f
    lea rdi, [rip + parentbuf]
    call strlen
    mov rbx, rax
1:  test rbx, rbx
    jz 9f
    dec rbx
    lea rax, [rip + parentbuf]
    cmp byte ptr [rax + rbx], '/'
    jne 1b
    test rbx, rbx
    jz 9f
    mov byte ptr [rax + rbx], 0
    mov rdi, rax
    lea rsi, [rip + .Lsb_ro_lit]
    call profile_path
    jmp 1b
9:  EPILOGUE

# profile_path(path cstr, form cstr with %s): one allow line with the real path
profile_path:
    PROLOGUE
    mov rbx, rsi
    mov r14, rdi
    lea rsi, [rip + realbuf]
    SYS SYS_realpath
    lea r12, [rip + realbuf]
    test rax, rax
    jnz 1f
    mov r12, r14                # not resolvable: as given
1:  mov rdi, rbx
    call strlen
    mov r13, rax
    # the form up to %s, the path, the rest
    mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Lpct_s]
    mov ecx, 2
    call str_find
    test rax, rax
    js 9f
    lea rdi, [rip + conf_profile]
    mov rsi, rbx
    mov rdx, rax
    push rax
    push rax
    call sb_push
    mov rdi, r12
    call push_sbpl_string
    pop rax
    pop rax
    lea rdi, [rip + conf_profile]
    lea rsi, [rbx + rax + 2]
    call sb_push_cstr
9:  EPILOGUE

# push_sbpl_string(cstr): the bytes into the profile with the quote and the backslash escaped,
# so a path can never end the literal it sits in
push_sbpl_string:
    PROLOGUE
    mov rbx, rdi
1:  movzx r12d, byte ptr [rbx]
    test r12d, r12d
    jz 9f
    inc rbx
    cmp r12d, '"'
    je 2f
    cmp r12d, '\\'
    jne 3f
2:  lea rdi, [rip + conf_profile]
    mov esi, '\\'
    call sb_push_byte
3:  lea rdi, [rip + conf_profile]
    mov esi, r12d
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# profile_program(path cstr): exec and read on the program's real path, and on its install tree
profile_program:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + pathbuf2]
    SYS SYS_realpath
    lea r12, [rip + pathbuf2]
    test rax, rax
    jnz 1f
    mov r12, rbx
1:  mov rdi, r12
    lea rsi, [rip + .Lsb_exec_lit]
    call profile_path
    # A directly launched /bin/sh selects the same native shell as a script interpreter.
    mov rdi, r12
    lea rsi, [rip + .Lbin_sh]
    call strcmp_eq
    test eax, eax
    jz 11f
    lea rdi, [rip + .Lselect_sh]
    lea rsi, [rip + .Lsb_exec_lit]
    call profile_path
11:
    # a script: its #! interpreter runs it (an ELF loader cannot be one here)
    mov rdi, r12
    lea rsi, [rip + pathbuf]
    call interp_of
    test eax, eax
    jz 2f
    cmp dword ptr [rip + elfhdr], 0x464c457f
    je 2f
    lea rdi, [rip + pathbuf]
    lea rsi, [rip + .Lsb_exec_lit]
    call profile_path
    # the interpreter's install tree too: a framework Python (Homebrew's, python.org's) runs
    # itself again from Resources/Python.app inside it, so a virtual environment's script works
    lea rdi, [rip + pathbuf]
    lea rsi, [rip + interpbuf]
    SYS SYS_realpath
    test rax, rax
    jz 12f
    lea rdi, [rip + interpbuf]
    lea rsi, [rip + treebuf]
    call install_tree
    test eax, eax
    jz 12f
    lea rdi, [rip + treebuf]
    lea rsi, [rip + .Lsb_exec_sub]
    call profile_path
12:
    # macOS's /bin/sh runs the shell /var/select/sh names (bash, dash or zsh) in its place
    lea rdi, [rip + pathbuf]
    lea rsi, [rip + .Lbin_sh]
    call strcmp_eq
    test eax, eax
    jz 2f
    lea rdi, [rip + .Lselect_sh]
    lea rsi, [rip + .Lsb_exec_lit]
    call profile_path
2:  mov rdi, r12
    lea rsi, [rip + pathbuf]
    call install_tree
    test eax, eax
    jz 8f
    lea rdi, [rip + pathbuf]
    lea rsi, [rip + .Lsb_exec_sub]
    call profile_path
8:  mov rdi, r12
    call strlen
    mov rsi, rax
    mov rdi, r12
    lea rdx, [rip + .Lrustup_exe]
    mov ecx, 7
    call str_ends
    test eax, eax
    jz 81f
    call confine_rustup_home
    test rax, rax
    jz 81f
    mov rdi, rax
    lea rsi, [rip + .Lrustup_tools]
    call path_join_tmp
    mov rdi, rax
    lea rsi, [rip + .Lsb_exec_sub]
    call profile_path
    call confine_rustup_home
    mov rdi, rax
    lea rsi, [rip + .Lrustup_settings]
    call path_join_tmp
    mov rdi, rax
    lea rsi, [rip + .Lsb_ro_lit]
    call profile_path
81: mov rdi, r12
    call xcode_shim
9:  EPILOGUE

# xcode_shim(path cstr): a tool in /usr/bin that Xcode provides (clangd, clang, swift…) is a shim:
# it loads libxcrun from the active developer folder, finds the tool through xcrun's cache and runs
# it from there. Then the folder is readable (the tool's SDK headers are in it), the cache and
# xcode-select's link too, and the tool itself may run. (A tool missing from the cache would need
# xcodebuild and much of Xcode: the shim says so, as it would for a tool that is not installed.)
xcode_shim:
    PROLOGUE 16
    mov rbx, rdi
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    lea rdx, [rip + .Lusr_bin]
    mov ecx, 9
    call str_starts
    test eax, eax
    jz 9f
    lea r12, [rbx + 9]          # the tool's name
    cmp byte ptr [r12], 0
    je 9f
    # the developer folder, found as xcode-select finds it: DEVELOPER_DIR, its link, Xcode in
    # Applications, the command line tools
    lea rdi, [rip + .Lenv_devdir]
    call getenv
    test rax, rax
    jz 11f
    mov rdi, rax
    lea rsi, [rip + devbuf]
    SYS SYS_realpath
    test rax, rax
    jz 11f
    # the bundle (Xcode.app) stands for its Contents/Developer, as for the shims
    lea rdi, [rip + devbuf]
    lea rsi, [rip + .Lcontents_dev + 1]
    call path_join
    mov r13, rax
    mov rdi, rax
    call file_type
    cmp eax, 0x4000
    jne 13f
    mov rdi, r13
    call strlen
    cmp rax, 4096
    jae 13f
    lea rdi, [rip + devbuf]
    mov rsi, r13
    lea rcx, [rax + 1]
    rep movsb
13: mov rdi, r13
    call mem_free
    jmp 1f
11: lea r13, [rip + .Ldev_dirs]
12: mov rdi, [r13]
    test rdi, rdi
    jz 9f
    add r13, 8
    lea rsi, [rip + devbuf]
    SYS SYS_realpath
    test rax, rax
    jz 12b
    lea rdi, [rip + devbuf]
    call file_type
    cmp eax, 0x4000
    jne 12b
1:  # the tool in the default toolchain, else in the folder's own usr/bin
    xor r14d, r14d
2:  cmp r14d, 2
    jae 9f
    lea rax, [rip + .Lshim_dirs]
    mov rsi, [rax + r14*8]
    inc r14d
    lea rdi, [rip + devbuf]
    call path_join
    mov r15, rax
    mov rdi, rax
    mov rsi, r12
    call path_join
    mov r13, rax
    mov rdi, r15
    call mem_free
    mov rdi, r13
    call file_type
    cmp eax, 0x8000
    je 3f
    mov rdi, r13
    call mem_free
    jmp 2b
3:  # read: the developer folder, or the whole Xcode bundle it is in (xcodebuild, which xcrun runs
    # when its cache does not have the tool for this HOME, loads Xcode's shared frameworks)
    lea rdi, [rip + devbuf]
    call strlen
    mov r15, rax
    lea rdi, [rip + devbuf]
    mov rsi, rax
    lea rdx, [rip + .Lcontents_dev]
    mov ecx, .Lcontents_dev_end - .Lcontents_dev - 1
    call str_ends
    test eax, eax
    jz 31f
    lea rax, [rip + devbuf]
    sub r15, .Lcontents_dev_end - .Lcontents_dev - 1
    mov byte ptr [rax + r15], 0  # the bundle, for its rule, then the folder again
    lea rdi, [rip + devbuf]
    lea rsi, [rip + .Lsb_ro]
    call profile_path
    lea rax, [rip + devbuf]
    mov byte ptr [rax + r15], '/'
    jmp 32f
31: lea rdi, [rip + devbuf]
    lea rsi, [rip + .Lsb_ro]
    call profile_path
32: mov rdi, r13
    lea rsi, [rip + .Lsb_exec_lit]
    call profile_path
    # The real tool's packaged helpers as for any other declared program (git's
    # libexec/git-core, Swift's compiler drivers and SourceKit's service).
    mov rdi, r13
    lea rsi, [rip + treebuf]
    call install_tree
    test eax, eax
    jz 321f
    lea rdi, [rip + treebuf]
    lea rsi, [rip + .Lsb_exec_sub]
    call profile_path
321: lea rdi, [rip + devbuf]
    lea rsi, [rip + .Lxcodebuild]
    call path_join
    mov r15, rax
    mov rdi, rax
    call file_type
    cmp eax, 0x8000
    jne 33f
    mov rdi, r15
    lea rsi, [rip + .Lsb_exec_lit]
    call profile_path
33: mov rdi, r15
    call mem_free
    lea rdi, [rip + conf_profile]
    lea rsi, [rip + .Lsb_xcrun]
    call sb_push_cstr
    # xcrun looks a tool up the first time (its cache is the extension's own, xcrun_db in the
    # state folder) through popen: /bin/sh and the shell it starts
    lea rdi, [rip + .Lbin_sh]
    lea rsi, [rip + .Lsb_exec_lit]
    call profile_path
    lea rdi, [rip + .Lselect_sh]
    lea rsi, [rip + .Lsb_exec_lit]
    call profile_path
    mov rdi, r12
    call prime_note
    mov rdi, r13
    call mem_free
9:  EPILOGUE

# prime_note(tool cstr): a primer looks the shim tool up outside the sandbox (prime_start) when
# the extension has no xcrun cache yet. Inside the sandbox that first lookup runs xcodebuild twice,
# which cannot read its plug-in cache or the Xcode preferences there: seconds of work each time,
# long enough for an extension's own timeout to kill git first, and then the cache is never
# written. Outside it is a second or so, once; the cache then answers every later lookup. The
# primer writes its cache beside the state folder (STATE.xcrun_db.PID: two windows' primers never
# share one), where the extension cannot reach, and renames it into the state folder when done, so
# xcrun outside never reads what the extension wrote; HOME is /var/empty, so nothing in the state
# folder steers xcodebuild. Priming starts at rhun's start for every extension that is on
# (confine_prime), so the cache is there before an extension that starts later uses a shim, and
# beside the spawn (prime_start) for one that has none yet when it starts.
prime_note:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + conf_prime], 0
    jne 5f
    mov dword ptr [rip + conf_prime], 2
    mov rax, [rip + conf_ext]
    mov rdi, [rax + EXT_state]
    lea rsi, [rip + .Lpx_db]
    call path_join
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    call strlen
    cmp rax, 4096
    jae 4f
    mov rdi, r12
    xor esi, esi                # F_OK
    SYS SYS_access
    test rax, rax
    jz 4f                       # there is one
    mov rdi, r12
    lea rsi, [rip + conf_prime_xdb]
    mov edx, 16
    SYS SYS_readlink
    test rax, rax
    jns 4f                      # a link, even one that leads nowhere
    lea rdi, [rip + conf_prime_dst]
    mov rsi, r12
    call cstr_copy
    # its own: the state folder's path with ".xcrun_db" (as the log is "STATE.log")
    lea rdi, [rip + conf_prime_xdb]
    lea rsi, [rip + .Lpx_db_eq]
    call cstr_copy
    mov rdi, rax
    mov rax, [rip + conf_ext]
    mov rsi, [rax + EXT_state]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Lpx_db_ext]
    call cstr_copy
    lea rax, [rip + .Lpx_arg0]
    mov [rip + conf_prime_argv], rax
    lea rax, [rip + .Lpx_find]
    mov [rip + conf_prime_argv + 8], rax
    mov qword ptr [rip + conf_prime_argv + 24], 0
    lea rax, [rip + .Lpx_home]
    mov [rip + conf_prime_env], rax
    lea rax, [rip + .Lpx_path]
    mov [rip + conf_prime_env + 8], rax
    lea rax, [rip + conf_prime_xdb]
    mov [rip + conf_prime_env + 16], rax
    # the developer folder the extension's xcrun uses (build_env passes DEVELOPER_DIR on)
    lea rdi, [rip + .Lenv_devdir]
    call getenv
    test rax, rax
    jz 3f
    sub rax, 14                 # back to the whole entry: "DEVELOPER_DIR=" is 14 bytes
3:  mov [rip + conf_prime_env + 24], rax
    mov qword ptr [rip + conf_prime_env + 32], 0
    mov dword ptr [rip + conf_prime], 1
4:  mov rdi, r12
    call mem_free
5:  cmp dword ptr [rip + conf_prime], 1
    jne 9f
    cmp dword ptr [rip + conf_prime_n], 8
    jae 9f
    mov rdi, rbx
    call strlen
    mov r13, rax
    mov rcx, [rip + conf_prime_used]
    lea rdx, [rcx + r13 + 1]
    cmp rdx, 1024
    ja 9f
    mov [rip + conf_prime_used], rdx
    lea rdi, [rip + conf_prime_names]
    add rdi, rcx
    mov eax, [rip + conf_prime_n]
    lea rdx, [rip + conf_prime_tools]
    mov [rdx + rax*8], rdi
    inc dword ptr [rip + conf_prime_n]
    mov rsi, rbx
    lea rcx, [r13 + 1]
    rep movsb
9:  EPILOGUE

# prime_start(): a primer process, which delays nothing: it runs xcrun --find for each tool
# prime_note kept, one after another, 30 s at most in all (a lookup still running then is killed
# with its session: the shell and xcodebuild it started), moves its cache into the state folder
# and ends. rhun reaps it (reap_later). One per cache in a session.
prime_start:
    PROLOGUE
    cmp dword ptr [rip + conf_prime], 1
    jne 9f
    mov dword ptr [rip + conf_prime], 2
    lea rbx, [rip + conf_primed]
    xor r12d, r12d
2:  cmp r12d, 64
    jae 9f                      # the list is full: no more primers this session
    mov rdi, [rbx + r12*8]
    test rdi, rdi
    jz 3f
    lea rsi, [rip + conf_prime_dst]
    call strcmp_eq
    test eax, eax
    jnz 9f                      # one was started for this cache already
    inc r12d
    jmp 2b
3:  lea rdi, [rip + conf_prime_dst]
    call dup_cstr
    mov [rbx + r12*8], rax
    SYS SYS_fork
    test rax, rax
    js 9f
    jz 1f
    mov edi, eax
    call reap_later
9:  EPILOGUE
1:  # the primer: no terminal, none of rhun's descriptors (the extension's pipes among them)
    SYS SYS_setsid
    call prime_quiet
    # its own cache: STATE.xcrun_db.PID
    lea rdi, [rip + conf_prime_xdb]
    call strlen
    lea rbx, [rip + conf_prime_xdb]
    add rbx, rax
    mov byte ptr [rbx], '.'
    SYS SYS_getpid
    lea rdi, [rbx + 1]
    mov esi, eax
    call fmt_u64
    mov byte ptr [rdi], 0
    call prime_xcrun
    lea rdi, [rip + conf_prime_xdb + 9]     # past "xcrun_db="
    lea rsi, [rip + conf_prime_dst]
    SYS SYS_rename              # rename never follows a link the extension may have put there
    lea rdi, [rip + conf_prime_xdb + 9]
    SYS SYS_unlink              # when the rename failed
    # the end, without the exit handlers of the program it was forked from
    SYS SYS_getpid
    mov edi, eax
    mov esi, SIGKILL
    SYS SYS_kill
    mov edi, 127
    SYS SYS_exit

# confine_prime(ext): at rhun's start, for an extension that is on: a primer for the Xcode shims
# its run list names, when its xcrun cache is missing (prime_note), so the cache is there by its
# first use. Its state folder is made for the primer's cache to go in.
FN confine_prime
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + EXT_manifest_ok], 0
    je 9f
    cmp dword ptr [rbx + EXT_disabled], 0
    jne 9f
    cmp qword ptr [rbx + EXT_prog], 0
    je 9f
    cmp qword ptr [rbx + EXT_state], 0
    je 9f
    mov [rip + conf_ext], rbx
    call profile_build          # finds the shims as for a start (the profile is not used)
    cmp dword ptr [rip + conf_prime], 1
    jne 8f
    mov rdi, [rbx + EXT_state]
    call mkdir_p
    call prime_start
8:  mov dword ptr [rip + conf_prime], 2
    lea rdi, [rip + conf_profile]
    call sb_clear
9:  EPILOGUE

# prime_quiet(): standard input, output and error on /dev/null, every other descriptor closed
prime_quiet:
    PROLOGUE
    lea rdi, [rip + .Lp_devnull]
    mov esi, O_RDWR
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 9f
    mov ebx, eax
    xor r12d, r12d
1:  mov edi, ebx
    mov esi, r12d
    SYS SYS_dup2
    inc r12d
    cmp r12d, 3
    jb 1b
    mov ebx, 3
2:  mov edi, ebx
    SYS SYS_close
    inc ebx
    cmp ebx, 1024
    jb 2b
9:  EPILOGUE

# prime_xcrun(): in the primer, the lookups
prime_xcrun:
    PROLOGUE 16
    call time_ms
    lea r15, [rax + 30000]
    xor r14d, r14d
1:  cmp r14d, [rip + conf_prime_n]
    jae 9f
    lea rax, [rip + conf_prime_tools]
    mov rax, [rax + r14*8]
    mov [rip + conf_prime_argv + 16], rax
    inc r14d
    SYS SYS_fork
    test rax, rax
    js 9f
    jz .Lpx_child
    mov r12, rax
2:  mov rdi, r12
    mov rsi, rsp
    mov edx, WNOHANG
    xor r10d, r10d
    SYS SYS_wait4
    cmp rax, -EINTR
    je 2b
    test rax, rax
    jnz 1b                      # it ended (or is gone)
    call time_ms
    cmp rax, r15
    jge 3f
    lea rdi, [rip + .Lpx_tick]
    xor esi, esi
    SYS 35                      # nanosleep
    jmp 2b
3:  mov edi, r12d
    neg edi
    mov esi, SIGKILL
    SYS SYS_kill
    mov edi, r12d
    mov esi, SIGKILL
    SYS SYS_kill
4:  mov rdi, r12
    mov rsi, rsp
    xor edx, edx
    xor r10d, r10d
    SYS SYS_wait4
    cmp rax, -EINTR
    je 4b
9:  EPILOGUE
.Lpx_child:
    SYS SYS_setsid              # a session of its own, for the kill above
    lea rdi, [rip + .Lpx_xcrun]
    lea rsi, [rip + conf_prime_argv]
    lea rdx, [rip + conf_prime_env]
    SYS SYS_execve
    mov edi, 127
    SYS SYS_exit
.endif

# ---------------- the child ----------------

# confine_child(): in the forked child, before dup2 and close_range (the rule descriptors are
# still open): what confine_prepare set up. Exits with EXITC_* when a step fails.
FN confine_child
    PROLOGUE                    # proc_spawn keeps argv, envp and cwd in r12-r14 across this call
    cmp dword ptr [rip + conf_pending], 0
    je 9f
.ifdef MACOS
    test dword ptr [rip + conf_flags], CF_SANDBOX
    jz 9f
    lea rdi, [rip + conf_profile]
    mov rdi, [rdi + SB_ptr]
    xor esi, esi
    lea rdx, [rip + pathbuf]    # char **errorbuf
    SYS SYS_sandbox_init
    test eax, eax
    jnz .Lcc_sandbox
9:  EPILOGUE
.Lcc_sandbox:
    mov rax, [rip + conf_page]
    test rax, rax
    jz 1f
    add rax, [rip + conf_slot]
    mov byte ptr [rax], EXITC_SANDBOX
1:  mov edi, EXITC_SANDBOX
    SYS SYS_exit
.else
    mov edi, PR_SET_NO_NEW_PRIVS
    mov esi, 1
    xor edx, edx
    xor r10d, r10d
    xor r8d, r8d
    SYS SYS_prctl
    lea rdi, [rip + .Lstep_nnp]
    test rax, rax
    js .Lcc_nnp
    test dword ptr [rip + conf_flags], CF_NETNS
    jz 2f
    mov edi, CLONE_NEWUSER | CLONE_NEWNET
    SYS SYS_unshare
    lea rdi, [rip + .Lstep_unshare]
    test rax, rax
    js .Lcc_netns
    lea rdi, [rip + .Lp_setgroups]
    lea rsi, [rip + .Ls_deny]
    call write_proc
    lea rdi, [rip + .Lp_setgroups]
    test rax, rax
    js .Lcc_netns
    lea rdi, [rip + .Lp_uidmap]
    lea rsi, [rip + conf_uidmap]
    call write_proc
    lea rdi, [rip + .Lp_uidmap]
    test rax, rax
    js .Lcc_netns
    lea rdi, [rip + .Lp_gidmap]
    lea rsi, [rip + conf_gidmap]
    call write_proc
    lea rdi, [rip + .Lp_gidmap]
    test rax, rax
    js .Lcc_netns
2:  test dword ptr [rip + conf_flags], CF_LANDLOCK
    jz 9f
    lea rdi, [rip + conf_attr]
    mov rsi, [rip + conf_attr_size]
    xor edx, edx
    SYS SYS_landlock_create_ruleset
    lea rdi, [rip + .Lstep_ruleset]
    test rax, rax
    js .Lcc_landlock
    mov ebx, eax                # the ruleset
    xor r12d, r12d
3:  cmp r12, [rip + conf_rules + VEC_len]
    jae 4f
    imul rdx, r12, CR_SIZE
    add rdx, [rip + conf_rules + VEC_ptr]
    cmp qword ptr [rdx + CR_access], 0
    je 31f                      # nothing this ABI handles: nothing to add
    mov edi, ebx
    mov esi, LL_RULE_PATH_BENEATH
    xor r10d, r10d
    SYS SYS_landlock_add_rule
    lea rdi, [rip + .Lstep_rule]
    test rax, rax
    js .Lcc_rule
31: inc r12
    jmp 3b
4:  mov edi, ebx
    xor esi, esi
    SYS SYS_landlock_restrict_self
    lea rdi, [rip + .Lstep_restrict]
    test rax, rax
    js .Lcc_restrict
    mov edi, ebx
    SYS SYS_close
9:  EPILOGUE
.Lcc_nnp:
    mov esi, EXITC_NNP
    jmp fail_exit
.Lcc_netns:
    mov esi, EXITC_NETNS
    jmp fail_exit
.Lcc_landlock:
    mov esi, EXITC_LANDLOCK
    jmp fail_exit
.Lcc_rule:
    mov esi, EXITC_RULE
    jmp fail_exit
.Lcc_restrict:
    mov esi, EXITC_RESTRICT
    jmp fail_exit

# fail_exit(step cstr, code) with -errno in rax: "rhun: not confined: STEP failed, errno N" on
# the program's standard error (its log), then the exit code
fail_exit:
    mov rbx, rdi
    mov r12d, esi
    neg rax
    mov r13, rax
    lea rdi, [rip + pathbuf]
    lea rsi, [rip + .Lnote_head]
    call cstr_copy
    mov rdi, rax
    mov rsi, rbx
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Lnote_errno]
    call cstr_copy
    mov rdi, rax
    mov rsi, r13
    call fmt_u64
    mov byte ptr [rdi], 10
    inc rdi
    lea rsi, [rip + pathbuf]
    mov rdx, rdi
    sub rdx, rsi
    mov edi, 2
    SYS SYS_write
    mov rax, [rip + conf_page]
    test rax, rax
    jz 1f
    add rax, [rip + conf_slot]
    mov ecx, r12d
    mov [rax], cl
1:  mov edi, r12d
    SYS SYS_exit

# write_proc(path, cstr) -> bytes written, or -errno
write_proc:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov esi, 1                  # O_WRONLY
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 9f
    mov ebx, eax
    mov rdi, r12
    call strlen
    mov edi, ebx
    mov rsi, r12
    mov rdx, rax
    SYS SYS_write
    mov r13, rax
    mov edi, ebx
    SYS SYS_close
    mov rax, r13
9:  pop r13
    pop r12
    pop rbx
    ret
.endif

# confine_reason() -> the cstr confine_prepare left, or 0
FN confine_reason
    mov rax, [rip + conf_reason]
    ret

# confine_exit_reason(code) -> a cstr for an EXITC_* code, or 0 for other exit codes
FN confine_exit_reason
    lea rax, [rip + .Lx_nnp]
    cmp edi, EXITC_NNP
    je 9f
    lea rax, [rip + .Lx_netns]
    cmp edi, EXITC_NETNS
    je 9f
    lea rax, [rip + .Lx_landlock]
    cmp edi, EXITC_LANDLOCK
    je 9f
    lea rax, [rip + .Lx_rule]
    cmp edi, EXITC_RULE
    je 9f
    lea rax, [rip + .Lx_restrict]
    cmp edi, EXITC_RESTRICT
    je 9f
    lea rax, [rip + .Lx_sandbox]
    cmp edi, EXITC_SANDBOX
    je 9f
    xor eax, eax
9:  ret

.section .rodata
.p2align 3
sys_dirs: .quad .Lp_usr, .Lp_lib, .Lp_lib64, .Lp_bin, .Lp_sbin, .Lp_etc, .Lp_proc, .Lp_sys, .Lp_dev, .Lp_opt, .Lp_nix, .Lp_snap, 0
tree_marks: .quad .Lt_lib, .Lt_libexec, .Lt_pkg, .Lt_frameworks, .Lt_flutter, 0
.Lenv_tmpdir: .asciz "TMPDIR"
.Ltemporary_items: .asciz "/TemporaryItems"
.Lbuild_token: .asciz "@build"
.Lt_flutter: .asciz "bin/cache/dart-sdk"
.Lp_usr: .asciz "/usr"
.Lp_lib: .asciz "/lib"
.Lp_lib64: .asciz "/lib64"
.Lp_bin: .asciz "/bin"
.Lp_sbin: .asciz "/sbin"
.Lp_etc: .asciz "/etc"
.Lp_proc: .asciz "/proc"
.Lp_sys: .asciz "/sys"
.Lp_dev: .asciz "/dev"
.Lp_opt: .asciz "/opt"
.Lp_nix: .asciz "/nix"
.Lp_snap: .asciz "/snap"
.Lp_devnull: .asciz "/dev/null"
.Lp_sound: .asciz "/dev/snd"
.Lenv_runtime: .asciz "XDG_RUNTIME_DIR"
.La_pulse: .asciz "pulse"
.La_cookie: .asciz ".config/pulse/cookie"
.Lt_lib: .asciz "lib"
.Lt_libexec: .asciz "libexec"
.Lt_pkg: .asciz "pkg"
.Lt_frameworks: .asciz "Frameworks"
.Lp_setgroups: .asciz "/proc/self/setgroups"
.Lp_uidmap: .asciz "/proc/self/uid_map"
.Lp_gidmap: .asciz "/proc/self/gid_map"
.Ls_deny: .asciz "deny"
.Lenv_rustup: .asciz "RUSTUP_HOME"
.Lrustup_dir: .asciz ".rustup"
.Lrustup_exe: .asciz "/rustup"
.Lrustup_tools: .asciz "toolchains"
.Lrustup_settings: .asciz "settings.toml"
.Lenv_home: .asciz "HOME"
.Lenv_conflog: .asciz "RHUN_CONFINE_LOG"
.Llog_rule: .asciz "confine: rule "
.Lpct_s: .asciz "%s"
.Lr_no_landlock: .asciz "Landlock is not available in this kernel"
.Lr_old_landlock: .asciz "Landlock ABI below 3 (Linux 6.2 or later is needed)"
.Lr_no_net: .asciz "the network cannot be cut off: no user namespaces and Landlock ABI below 4"
.Lr_state: .asciz "the state folder cannot be opened"
.Lr_program: .asciz "the program cannot be opened"
.Lx_nnp: .asciz "no_new_privs was refused"
.Lx_netns: .asciz "the user namespace could not be made"
.Lx_landlock: .asciz "the Landlock ruleset could not be made"
.Lx_rule: .asciz "a Landlock rule was refused"
.Lx_restrict: .asciz "landlock_restrict_self was refused"
.Lx_sandbox: .asciz "sandbox_init refused the profile"
.Lnote_head: .asciz "rhun: not confined: "
.Lnote_errno: .asciz " failed, errno "
.Lstep_nnp: .asciz "no_new_privs"
.Lstep_unshare: .asciz "unshare(CLONE_NEWUSER | CLONE_NEWNET)"
.Lstep_ruleset: .asciz "landlock_create_ruleset"
.Lstep_rule: .asciz "landlock_add_rule"
.Lstep_restrict: .asciz "landlock_restrict_self"
.Lsb_head: .ascii "(version 1)\n(deny default)\n(import \"system.sb\")\n(allow process-fork)\n(allow signal (target same-sandbox))\n(allow file-read-metadata)\n(allow sysctl-read)\n"
    .ascii "(allow mach-lookup (global-name \"com.apple.system.logger\") (global-name \"com.apple.system.notification_center\"))\n"
    .ascii "(allow file-read* (subpath \"/usr\") (subpath \"/System\") (subpath \"/Library\") (subpath \"/private/etc\") (subpath \"/dev\") (literal \"/\") (subpath \"/opt\") (subpath \"/nix\"))\n"
    .ascii "(allow file-write* (literal \"/dev/null\") (literal \"/dev/stdout\") (literal \"/dev/stderr\"))\n"
    .asciz "(allow file-read* (literal \"/dev/null\") (literal \"/dev/urandom\") (literal \"/dev/random\") (literal \"/dev/tty\"))\n"
.Lsb_dns: .asciz "(allow file-read* (literal \"/private/var/run/resolv.conf\"))\n"
.Lsb_build_watch: .asciz "(allow mach-lookup (global-name \"com.apple.FSEvents\"))\n"
.Lsb_audio: .asciz "(allow mach-lookup (global-name \"com.apple.audio.AudioComponentPrefs\") (global-name \"com.apple.audio.AudioComponentRegistrar\") (global-name \"com.apple.audio.AudioSession\") (global-name \"com.apple.audio.audiohald\") (global-name \"com.apple.audio.coreaudiod\") (global-name \"com.apple.mediaexperience.endpoint.xpc\"))\n(allow ipc-posix-shm-read* ipc-posix-shm-write-data (ipc-posix-name-prefix \"AudioIO\"))\n(allow iokit-open-user-client (require-all (iokit-connection \"AppleHDAEngineOutput\") (iokit-user-client-class \"IOAudioControlUserClient\" \"IOAudioEngineUserClient\")))\n"
.Lsb_ro: .asciz "(allow file-read* (subpath \"%s\"))\n"
.Lsb_ro_lit: .asciz "(allow file-read* (literal \"%s\"))\n"
.Lsb_rw: .asciz "(allow file-read* file-write* (subpath \"%s\"))\n"
.Lsb_exec_lit: .asciz "(allow process-exec file-read* (literal \"%s\"))\n"
.Lsb_exec_sub: .asciz "(allow process-exec file-read* (subpath \"%s\"))\n"
.Lsb_net_deny: .asciz "(deny network*)\n"
.Lusr_bin: .asciz "/usr/bin/"
.Lbin_sh: .asciz "/bin/sh"
.Lselect_sh: .asciz "/private/var/select/sh"
.Lxcode_link: .asciz "/var/db/xcode_select_link"
.Lclt: .asciz "/Library/Developer/CommandLineTools"
.Lxcode_app: .asciz "/Applications/Xcode.app/Contents/Developer"
.Lenv_devdir: .asciz "DEVELOPER_DIR"
.Lxcodebuild: .asciz "usr/bin/xcodebuild"
.Lcontents_dev: .asciz "/Contents/Developer"
.Lcontents_dev_end:
.Ltc_bin: .asciz "Toolchains/XcodeDefault.xctoolchain/usr/bin"
.Ldev_bin: .asciz "usr/bin"
.p2align 3
.Lshim_dirs: .quad .Ltc_bin, .Ldev_bin
.Ldev_dirs: .quad .Lxcode_link, .Lxcode_app, .Lclt, 0
.Lsb_xcrun: .asciz "(allow file-read* (literal \"/private/var/db/xcode_select_link\"))\n"
.Lpx_xcrun: .asciz "/usr/bin/xcrun"
.Lpx_arg0: .asciz "xcrun"
.Lpx_find: .asciz "--find"
.Lpx_db: .asciz "xcrun_db"
.Lpx_db_eq: .asciz "xcrun_db="
.Lpx_db_ext: .asciz ".xcrun_db"
.Lpx_home: .asciz "HOME=/var/empty"
.Lpx_path: .asciz "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
.p2align 3
.Lpx_tick: .quad 0, 10000000    # 10 ms
.Lsb_net_allow: .asciz "(allow network*)\n"
.Lsb_sock: .asciz "(allow network-bind network-inbound (local unix-socket (subpath \"%s\")))\n"
