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
elfhdr: .zero 64
phdr: .zero 56

.text

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
    # the extension folder, its script, its state folder
    mov rdi, [rbx + EXT_dir]
    mov rsi, LL_RO
    call add_rule
    mov rdi, [rbx + EXT_script]
    test rdi, rdi
    jz 3f
    mov rsi, LL_READ_FILE
    call add_rule
3:  mov rdi, [rbx + EXT_state]
    mov rsi, LL_RW
    call add_rule
    test rax, rax
    jnz 31f
    lea rax, [rip + .Lr_state]
    jmp 9f
31: # the project
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 4f
    test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_READ | NEEDS_PROJECT_WRITE
    jz 4f
    mov rsi, LL_RO
    test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_WRITE
    jz 32f
    mov rsi, LL_RW
32: call add_rule
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
    call proc_which
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
3:  xor eax, eax
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
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    SYS SYS_open
    test rax, rax
    js 8f
    mov r13d, eax
    mov edi, eax
    lea rsi, [rip + elfhdr]
    mov edx, 64
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
    # the first word after "#!" up to a space or line end (the header read has at most 64 bytes)
    lea rsi, [rip + elfhdr + 2]
    mov rdi, r12
    xor ecx, ecx
2:  cmp ecx, 61
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
    lea rdi, [rip + conf_profile]
    lea rsi, [rip + .Lsb_head]
    call sb_push_cstr
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
    # the project and the home
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 2f
    test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_READ | NEEDS_PROJECT_WRITE
    jz 2f
    lea rsi, [rip + .Lsb_ro]
    test dword ptr [rbx + EXT_needs], NEEDS_PROJECT_WRITE
    jz 21f
    lea rsi, [rip + .Lsb_rw]
21: call profile_path
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
    call proc_which
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
    lea rdi, [rip + devbuf]
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
    mov rdi, r13
    call mem_free
9:  EPILOGUE
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
tree_marks: .quad .Lt_lib, .Lt_libexec, .Lt_pkg, .Lt_frameworks, 0
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
.Lt_lib: .asciz "lib"
.Lt_libexec: .asciz "libexec"
.Lt_pkg: .asciz "pkg"
.Lt_frameworks: .asciz "Frameworks"
.Lp_setgroups: .asciz "/proc/self/setgroups"
.Lp_uidmap: .asciz "/proc/self/uid_map"
.Lp_gidmap: .asciz "/proc/self/gid_map"
.Ls_deny: .asciz "deny"
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
.Lsb_head: .ascii "(version 1)\n(deny default)\n(import \"system.sb\")\n(allow process-fork)\n(allow file-read-metadata)\n(allow sysctl-read)\n"
    .ascii "(allow mach-lookup (global-name \"com.apple.system.logger\") (global-name \"com.apple.system.notification_center\"))\n"
    .ascii "(allow file-read* (subpath \"/usr\") (subpath \"/System\") (subpath \"/Library\") (subpath \"/private/etc\") (subpath \"/dev\") (literal \"/\") (subpath \"/opt\") (subpath \"/nix\"))\n"
    .ascii "(allow file-write* (literal \"/dev/null\") (literal \"/dev/stdout\") (literal \"/dev/stderr\"))\n"
    .asciz "(allow file-read* (literal \"/dev/null\") (literal \"/dev/urandom\") (literal \"/dev/random\") (literal \"/dev/tty\"))\n"
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
.Lsb_net_allow: .asciz "(allow network*)\n"
