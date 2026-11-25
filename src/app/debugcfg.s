# debugger configuration (docs/extensions/v1.1.md "debug", docs/guide.md "Debugging"): the
# [debugger.TYPE] sections extensions declare (g_debuggers), launch configurations in
# PROJECT/.rhun/launch.ini with their variables and types, the launch arguments they become (JSON),
# and the adapter's command line
.include "rhun.inc"

# the configuration as a tree: dotted keys build objects, numeric segments arrays
STRUCT
F CN_name, 4            # offset into cs
F CN_namelen, 4
F CN_val, 4             # a leaf's value, offset into cs
F CN_vallen, 4
F CN_kind, 4            # 0 leaf, 1 object, 2 array
F CN_lkind, 4           # a leaf: 's' string, 'n' number, 'b' true/false, 'z' null
F CN_kid, 4             # first child, -1
F CN_next, 4            # next sibling, -1
F CN_index, 8           # an array element's index (elements stay in index order)
ENDSTRUCT CN_NODE_SIZE
.equ CN_LEAVES_MAX, 4096
.equ CN_PATH_MAX, 256
.equ CN_SEGS_MAX, 16
.equ LINI_MAX, 1048576

.bss
.p2align 3
.globl g_debuggers, g_ndebuggers, g_dcfg_err, g_dcfg_code
g_debuggers: .zero DBG_SIZE * DBG_MAX
g_ndebuggers: .long 0
.p2align 3
lini: .quad 0                   # launch.ini (owned bytes), or 0
lini_len: .quad 0
lini_stamp: .quad 0
cn: .zero VEC_SIZE              # the configuration tree; node 0 is the root object
cstrs: .zero SB_SIZE               # its names and values
cn_leaves: .long 0
cur_line: .long 0               # launch.ini line of the value being read (for messages), 0 none
g_dcfg_err: .zero 1024          # why the last step failed
g_dcfg_code: .long 0            # dcfg_from_leaves: DCE_*
lvn: .long 0                    # dcfg_leaves: the leaves so far
.p2align 3
lvb: .zero SB_SIZE              # and their records
lpb: .zero SB_SIZE              # the path of the node being walked
it: .zero INI_SIZE
pathb: .zero SB_SIZE            # scratch for paths
valb: .zero SB_SIZE             # a value with its variables replaced
wordb: .zero SB_SIZE            # split_words: each word NUL-terminated
segs: .zero 16 * CN_SEGS_MAX    # cn_set: the path's segments (ptr, len)
# the prepared launch (dcfg_prepare, dcfg_adapter)
.globl g_lc_dbg, g_lc_request, g_lc_nodebug, g_lc_port, g_lc_name, g_lc_json, g_lc_args, g_lc_nargs
.globl g_lc_cmd, g_lc_before, g_lc_after, g_lc_server, g_lc_compound, g_lc_section
.data
g_lc_dbg: .long -1              # index into g_debuggers
.bss
g_lc_request: .long 0           # 0 launch, 1 attach
g_lc_nodebug: .long 0
g_lc_port: .long 0              # tcp: the port for ${port}
g_lc_nargs: .long 0
.p2align 3
g_lc_name: .zero SB_SIZE        # the configuration's name (NUL-terminated)
g_lc_section: .zero SB_SIZE     # its raw bytes in launch.ini
g_lc_json: .zero SB_SIZE        # the launch or attach arguments
g_lc_args: .zero SB_SIZE        # the adapter's argv, each NUL-terminated (the program first)
g_lc_cmd: .zero SB_SIZE         # that command as shown in the approval (NUL-terminated)
g_lc_before: .zero SB_SIZE      # before, after, server, compound values (NUL-terminated or empty)
g_lc_after: .zero SB_SIZE
g_lc_server: .zero SB_SIZE
g_lc_compound: .zero SB_SIZE

.text

# ---------------- messages ----------------

# err_set(cstr): g_dcfg_err = cstr
err_set:
    mov rsi, rdi
    lea rdi, [rip + g_dcfg_err]
    jmp cstr_copy

# err_line(): g_dcfg_err = "launch.ini line N: " (or nothing outside launch.ini) -> rax its end
err_line:
    PROLOGUE
    lea rbx, [rip + g_dcfg_err]
    mov byte ptr [rbx], 0
    mov rax, rbx
    mov ecx, [rip + cur_line]
    test ecx, ecx
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lm_line]
    call cstr_copy
    mov rbx, rax
    mov rdi, rax
    mov esi, [rip + cur_line]
    call fmt_u64
    lea rdi, [rbx + rax]
    lea rsi, [rip + .Lm_colon]
    call cstr_copy
9:  EPILOGUE

# err_add(end, cstr) -> end: appended
err_add:
    jmp cstr_copy

# err_addn(end, ptr, len) -> end: appended, cut to fit the buffer
err_addn:
    lea rax, [rip + g_dcfg_err + 900]
    sub rax, rdi
    jle 1f
    cmp rdx, rax
    cmova rdx, rax
    push rdi
    push rdx
    call memcpy
    pop rdx
    pop rdi
    add rdi, rdx
1:  mov byte ptr [rdi], 0
    mov rax, rdi
    ret

# err_key(ptr, len, cstr): "launch.ini line N: `KEY` " + cstr
err_key:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    call err_line
    mov rdi, rax
    mov esi, '`'
    mov [rdi], sil
    inc rdi
    mov rsi, r12
    mov rdx, r13
    call err_addn
    mov byte ptr [rax], '`'
    lea rdi, [rax + 1]
    mov rsi, r14
    call cstr_copy
    EPILOGUE

# ---------------- debuggers from manifests ----------------

# dbg_manifest_kv(ext, ini): one key = value of a [debugger.TYPE] section, from ext.s's manifest_kv.
#   Rows past 8 per extension or 64 in all, and types that are not [a-z0-9-]{1,32}, are ignored.
FN dbg_manifest_kv
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [r12 + INI_sec]
    add r13, 9                  # "debugger."
    mov r14, [r12 + INI_seclen]
    sub r14, 9
    jle 9f
    cmp r14, 32
    ja 9f
    xor ecx, ecx
60: movzx eax, byte ptr [r13 + rcx]
    cmp al, '-'
    je 61f
    lea edx, [rax - 'a']
    cmp edx, 25
    jbe 61f
    lea edx, [rax - '0']
    cmp edx, 9
    ja 9f
61: inc rcx
    cmp rcx, r14
    jb 60b
    # this extension's row for the type
    xor r15d, r15d
    xor edx, edx                # its rows so far
1:  cmp r15d, [rip + g_ndebuggers]
    jae 2f
    imul rax, r15, DBG_SIZE
    lea rcx, [rip + g_debuggers]
    add rax, rcx
    cmp [rax + DBG_ext], rbx
    jne 11f
    inc edx
    push rax
    push rdx
    mov rdi, [rax + DBG_type]
    call strlen
    mov rsi, rax
    pop rdx
    pop rax
    push rax
    push rdx
    mov rdi, [rax + DBG_type]
    mov rdx, r13
    mov rcx, r14
    call str_eq
    mov ecx, eax
    pop rdx
    pop rax
    test ecx, ecx
    jnz 3f
11: inc r15d
    jmp 1b
2:  cmp edx, DBG_PER_EXT
    jae 9f
    cmp dword ptr [rip + g_ndebuggers], DBG_MAX
    jae 9f
    mov eax, [rip + g_ndebuggers]
    inc dword ptr [rip + g_ndebuggers]
    imul rax, rax, DBG_SIZE
    lea rcx, [rip + g_debuggers]
    add rax, rcx
    mov r15, rax
    mov [r15 + DBG_ext], rbx
    mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov [r15 + DBG_type], rax
    mov rax, r15
3:  mov r15, rax
    # string keys
    lea r13, [rip + dbg_keys]
4:  mov rsi, [r13]
    test rsi, rsi
    jz 5f
    mov rdi, r12
    call ini_key_is
    test eax, eax
    jnz 41f
    add r13, 16
    jmp 4b
41: mov rcx, [r13 + 8]
    lea r14, [r15 + rcx]
    mov rdi, [r14]
    call mem_free
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    call mem_dup
    mov [r14], rax
    jmp 9f
5:  mov rdi, r12
    lea rsi, [rip + .Lk_transport]
    call ini_key_is
    test eax, eax
    jz 6f
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    lea rdx, [rip + .Lv_tcp]
    call str_eq_cstr
    mov [r15 + DBG_transport], eax
    jmp 9f
6:  mov rdi, r12
    lea rsi, [rip + .Lk_resolve]
    call ini_key_is
    test eax, eax
    jz 7f
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    call parse_bool
    mov [r15 + DBG_resolve], eax
    jmp 9f
7:  # program.TARGET, args.TARGET for this system
    lea rdi, [rip + .Lk_program_dot]
    lea rsi, [r15 + DBG_program_t]
    call target_key
    test eax, eax
    jnz 9f
    lea rdi, [rip + .Lk_args_dot]
    lea rsi, [r15 + DBG_args_t]
    call target_key
    test eax, eax
    jnz 9f
    # attr.NAME = TYPE
    mov rdi, [r12 + INI_key]
    mov rsi, [r12 + INI_keylen]
    lea rdx, [rip + .Lk_attr_dot]
    mov ecx, 5
    call str_starts
    test eax, eax
    jz 9f
    cmp qword ptr [r12 + INI_keylen], 5
    jbe 9f
    cmp dword ptr [r15 + DBG_nattrs], DBG_ATTRS_MAX
    jae 9f
    cmp qword ptr [r15 + DBG_attrs], 0
    jne 8f
    mov edi, SB_SIZE
    call mem_alloc
    mov qword ptr [rax + SB_ptr], 0
    mov qword ptr [rax + SB_len], 0
    mov qword ptr [rax + SB_cap], 0
    mov [r15 + DBG_attrs], rax
8:  inc dword ptr [r15 + DBG_nattrs]
    mov rdi, [r15 + DBG_attrs]
    mov rsi, [r12 + INI_key]
    add rsi, 5
    mov rdx, [r12 + INI_keylen]
    sub rdx, 5
    call sb_push
    mov rdi, [r15 + DBG_attrs]
    mov esi, 9
    call sb_push_byte
    mov rdi, [r15 + DBG_attrs]
    mov rsi, [r12 + INI_val]
    mov rdx, [r12 + INI_vallen]
    call sb_push
    mov rdi, [r15 + DBG_attrs]
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# target_key(prefix cstr, slot*) -> eax 1 when r12's key is PREFIX + this system's target: the slot
#   takes the value
target_key:
    PROLOGUE
    mov rbx, rdi
    mov r13, rsi
    call strlen
    mov r14, rax
    mov rdi, [r12 + INI_key]
    mov rsi, [r12 + INI_keylen]
    mov rdx, rbx
    mov rcx, r14
    call str_starts
    test eax, eax
    jz 9f
    mov rdi, [r12 + INI_key]
    add rdi, r14
    mov rsi, [r12 + INI_keylen]
    sub rsi, r14
    lea rdx, [rip + ext_target]
    call str_eq_cstr
    test eax, eax
    jz 9f
    mov rdi, [r13]
    call mem_free
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    call mem_dup
    mov [r13], rax
    mov eax, 1
9:  EPILOGUE

# dbg_row(index) -> DBG*
FN dbg_row
    imul rax, rdi, DBG_SIZE
    lea rcx, [rip + g_debuggers]
    add rax, rcx
    ret

# dbg_ext_declares(EXT*) -> eax 1 when the extension declares a debugger (ext.s: such an extension
#   needs no program of its own); clobbers rax, rcx, rdx only
FN dbg_ext_declares
    xor ecx, ecx
    lea rdx, [rip + g_debuggers]
1:  cmp ecx, [rip + g_ndebuggers]
    jae 2f
    cmp [rdx + DBG_ext], rdi
    je 3f
    add rdx, DBG_SIZE
    inc ecx
    jmp 1b
2:  xor eax, eax
    ret
3:  mov eax, 1
    ret

# dbg_live(index) -> eax 1 when the debugger's extension is installed and usable
FN dbg_live
    call dbg_row
    mov rax, [rax + DBG_ext]
    mov ecx, [rax + EXT_status]
    xor eax, eax
    cmp ecx, ES_REMOVED
    je 1f
    cmp ecx, ES_DISABLED
    je 1f
    cmp ecx, ES_FAILED
    je 1f
    mov eax, 1
1:  ret

# dbg_by_type(ptr, len) -> eax index of a live debugger of that type, or -1
FN dbg_by_type
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp ebx, [rip + g_ndebuggers]
    jae 8f
    mov edi, ebx
    call dbg_live
    test eax, eax
    jz 2f
    mov edi, ebx
    call dbg_row
    mov rdi, [rax + DBG_type]
    mov rsi, r12
    mov rdx, r13
    call cstr_eq_n
    test eax, eax
    jnz 9f
2:  inc ebx
    jmp 1b
8:  mov ebx, -1
9:  mov eax, ebx
    EPILOGUE

# cstr_eq_n(cstr, ptr, len) -> eax 1 if equal
cstr_eq_n:
    mov rax, rdi
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rax
    jmp str_eq_cstr

# dbg_attr(index, name ptr, len) -> rax the declared type's text, rdx its length (0, 0 undeclared)
FN dbg_attr
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    call dbg_row
    mov rax, [rax + DBG_attrs]
    test rax, rax
    jz 8f
    mov rbx, [rax + SB_ptr]
    mov r14, [rax + SB_len]
    add r14, rbx                # end
1:  cmp rbx, r14
    jae 8f
    # NAME \t TYPE \n
    mov rcx, rbx
2:  cmp byte ptr [rcx], 9
    je 3f
    inc rcx
    jmp 2b
3:  mov r15, rcx                # the tab
    mov rdi, rbx
    mov rsi, rcx
    sub rsi, rbx
    mov rdx, r12
    mov rcx, r13
    call str_eq
    lea rdx, [r15 + 1]
    mov rcx, rdx
4:  cmp byte ptr [rcx], 10
    je 5f
    inc rcx
    jmp 4b
5:  lea rbx, [rcx + 1]
    test eax, eax
    jz 1b
    mov rax, rdx
    sub rcx, rdx
    mov rdx, rcx
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# ---------------- launch.ini ----------------

# lini_path(sb) -> eax 1 with PROJECT/.rhun/launch.ini in sb (NUL-terminated), 0 without a project
lini_path:
    PROLOGUE
    mov rbx, rdi
    call sb_clear
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lf_launch]
    call sb_push_cstr
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rbx + SB_len]
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# dcfg_read() -> eax 1 when the project's launch.ini is loaded (read again when it changed on disk)
FN dcfg_read
    PROLOGUE
    lea rdi, [rip + pathb]
    call lini_path
    test eax, eax
    jz 7f
    mov rdi, [rip + pathb + SB_ptr]
    call vfs_stamp              # remote hosts: the host's launch.ini in a remote window (vfs.s)
    test rax, rax
    jz 7f
    mov rbx, rax
    cmp qword ptr [rip + lini], 0
    je 1f
    cmp rbx, [rip + lini_stamp]
    je 6f
1:  call lini_free
    mov rdi, [rip + pathb + SB_ptr]
    mov esi, LINI_MAX
    call vfs_read_limited
    test rax, rax
    jz 7f
    mov [rip + lini], rax
    mov [rip + lini_len], rdx
    mov [rip + lini_stamp], rbx
6:  mov eax, 1
    EPILOGUE
7:  call lini_free
    xor eax, eax
    EPILOGUE

lini_free:
    push rbx
    mov rdi, [rip + lini]
    mov qword ptr [rip + lini], 0
    mov qword ptr [rip + lini_len], 0
    mov qword ptr [rip + lini_stamp], 0
    test rdi, rdi
    jz 1f
    call mem_free
1:  pop rbx
    ret

# line_of(ptr) -> eax the launch.ini line (one-based) ptr is on
line_of:
    mov rcx, [rip + lini]
    mov eax, 1
1:  cmp rcx, rdi
    jae 2f
    cmp byte ptr [rcx], 10
    jne 3f
    inc eax
3:  inc rcx
    jmp 1b
2:  ret

# dcfg_names(sb): the configurations' names, one per line, in file order (hidden ones left out)
FN dcfg_names
    PROLOGUE
    mov rbx, rdi
    call dcfg_read
    test eax, eax
    jz 9f
    # sections in order: a section starts where its first key is
    xor r12d, r12d              # the last section written (ptr)
    lea rdi, [rip + it]
    mov rsi, [rip + lini]
    mov rdx, [rip + lini_len]
    call ini_init
1:  lea rdi, [rip + it]
    call ini_next
    test eax, eax
    jz 9f
    mov rax, [rip + it + INI_sec]
    test rax, rax
    jz 1b
    cmp rax, r12
    je 1b
    mov r12, rax
    mov rdi, rax
    mov rsi, [rip + it + INI_seclen]
    call section_hidden
    test eax, eax
    jnz 1b
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rip + it + INI_seclen]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# section_hidden(name ptr, len) -> eax 1 when the section says hidden = yes
section_hidden:
    PROLOGUE 64
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rsp]
    mov rsi, [rip + lini]
    mov rdx, [rip + lini_len]
    call ini_init
1:  lea rdi, [rsp]
    call ini_next
    test eax, eax
    jz 8f
    mov rdi, [rsp + INI_sec]
    mov rsi, [rsp + INI_seclen]
    mov rdx, r12
    mov rcx, r13
    call str_eq
    test eax, eax
    jz 1b
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_hidden]
    call ini_key_is
    test eax, eax
    jz 1b
    mov rdi, [rsp + INI_val]
    mov rsi, [rsp + INI_vallen]
    call parse_bool
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# sb_z(sb) -> its bytes, NUL-terminated (the length is unchanged)
sb_z:
    push rbx
    mov rbx, rdi
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rbx + SB_len]
    mov rax, [rbx + SB_ptr]
    pop rbx
    ret

# sb_set(sb, ptr, len): the buffer holds exactly these bytes, NUL-terminated
sb_set:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, rbx
    call sb_z
    pop r13
    pop r12
    pop rbx
    ret

# dcfg_prepare(name ptr, len, nodebug) -> eax 1 with g_lc_* filled, 0 with g_dcfg_err. The section's
#   type picks the debugger; every key but type, request, before, after, server, compound and hidden
#   becomes a launch argument of its declared type, with its variables replaced.
FN dcfg_prepare
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov [rsp], edx
    mov dword ptr [rip + g_dcfg_code], 0
    mov dword ptr [rip + cur_line], 0
    mov dword ptr [rip + g_lc_dbg], -1
    mov dword ptr [rip + g_lc_request], 0
    mov eax, [rsp]
    mov [rip + g_lc_nodebug], eax
    lea rdi, [rip + g_lc_name]
    mov rsi, r12
    mov rdx, r13
    call sb_set
    lea rdi, [rip + g_lc_section]
    call sb_clear
    lea rdi, [rip + g_lc_before]
    call sb_clear
    lea rdi, [rip + g_lc_after]
    call sb_clear
    lea rdi, [rip + g_lc_server]
    call sb_clear
    lea rdi, [rip + g_lc_compound]
    call sb_clear
    call cn_reset
    call dcfg_read
    test eax, eax
    jnz 1f
    lea rdi, [rip + .Lm_no_file]
    call err_set
    jmp .Ldp_fail
1:  # pass 1: the keys rhun keeps
    xor r14d, r14d              # found the section
    xor r15d, r15d              # type value ptr
    mov qword ptr [rsp + 8], 0  # its length
    lea rdi, [rip + it]
    mov rsi, [rip + lini]
    mov rdx, [rip + lini_len]
    call ini_init
2:  lea rdi, [rip + it]
    call ini_next
    test eax, eax
    jz 3f
    call it_in_section
    test eax, eax
    jz 2b
    mov r14d, 1
    mov rdi, [rip + it + INI_key]
    call line_of
    mov [rip + cur_line], eax
    # the section's raw bytes (kept to show, and for "Save as a configuration")
    lea rdi, [rip + g_lc_section]
    mov rsi, [rip + it + INI_key]
    mov rdx, [rip + it + INI_val]
    add rdx, [rip + it + INI_vallen]
    sub rdx, rsi
    call sb_push
    lea rdi, [rip + g_lc_section]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + it]
    lea rsi, [rip + .Lk_type]
    call ini_key_is
    test eax, eax
    jz 21f
    mov r15, [rip + it + INI_val]
    mov rax, [rip + it + INI_vallen]
    mov [rsp + 8], rax
    jmp 2b
21: lea rdi, [rip + it]
    lea rsi, [rip + .Lk_request]
    call ini_key_is
    test eax, eax
    jz 23f
    mov rdi, [rip + it + INI_val]
    mov rsi, [rip + it + INI_vallen]
    lea rdx, [rip + .Lv_launch]
    call str_eq_cstr
    test eax, eax
    jnz 2b
    mov rdi, [rip + it + INI_val]
    mov rsi, [rip + it + INI_vallen]
    lea rdx, [rip + .Lv_attach]
    call str_eq_cstr
    test eax, eax
    jz 22f
    mov dword ptr [rip + g_lc_request], 1
    jmp 2b
22: lea rdi, [rip + .Lk_request]
    mov esi, 7
    lea rdx, [rip + .Lm_request]
    call err_key
    jmp .Ldp_fail
23: lea rbx, [rip + kept_keys]
24: mov rsi, [rbx]
    test rsi, rsi
    jz 2b
    lea rdi, [rip + it]
    call ini_key_is
    test eax, eax
    jnz 25f
    add rbx, 16
    jmp 24b
25: mov rdi, [rbx + 8]
    test rdi, rdi
    jz 2b                       # hidden: only the picker reads it
    mov rsi, [rip + it + INI_val]
    mov rdx, [rip + it + INI_vallen]
    call sb_set
    jmp 2b
3:  test r14d, r14d
    jnz 31f
    call err_line
    mov rdi, rax
    lea rsi, [rip + .Lm_no_config]
    call cstr_copy
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call err_addn
    mov byte ptr [rax], 0
    jmp .Ldp_fail
31: mov dword ptr [rip + cur_line], 0
    cmp qword ptr [rip + g_lc_compound + SB_len], 0
    jne .Ldp_ok                 # a compound starts the configurations it names
    test r15, r15
    jnz 32f
    call err_line
    mov rdi, rax
    lea rsi, [rip + .Lm_no_type]
    call cstr_copy
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call err_addn
    jmp .Ldp_fail
32: mov rdi, r15
    mov rsi, [rsp + 8]
    call dbg_by_type
    mov [rip + g_lc_dbg], eax
    test eax, eax
    jns 33f
    lea rdi, [rip + g_dcfg_err]
    lea rsi, [rip + .Lm_no_debugger]
    call cstr_copy
    mov rdi, rax
    mov rsi, r15
    mov rdx, [rsp + 8]
    call err_addn
    mov rdi, rax
    lea rsi, [rip + .Lm_no_debugger2]
    call cstr_copy
    jmp .Ldp_fail
33: # type, request and name go into the arguments too (debugpy checks request)
    lea rdi, [rip + .Lk_type]
    mov esi, 4
    mov edx, 's'
    mov rcx, r15
    mov r8, [rsp + 8]
    call cn_put
    lea rcx, [rip + .Lv_launch]
    mov r8d, 6
    cmp dword ptr [rip + g_lc_request], 0
    je 34f
    lea rcx, [rip + .Lv_attach]
34: lea rdi, [rip + .Lk_request]
    mov esi, 7
    mov edx, 's'
    call cn_put
    lea rdi, [rip + .Lk_name]
    mov esi, 4
    mov edx, 's'
    mov rcx, r12
    mov r8, r13
    call cn_put
    cmp dword ptr [rip + g_lc_nodebug], 0
    je 35f
    lea rdi, [rip + .Lk_nodebug]
    mov esi, 7
    mov edx, 'b'
    lea rcx, [rip + .Lv_true]
    mov r8d, 4
    call cn_put
35: # pass 2: the launch arguments
    lea rdi, [rip + it]
    mov rsi, [rip + lini]
    mov rdx, [rip + lini_len]
    call ini_init
4:  lea rdi, [rip + it]
    call ini_next
    test eax, eax
    jz 5f
    call it_in_section
    test eax, eax
    jz 4b
    lea rdi, [rip + it]
    lea rsi, [rip + .Lk_type]
    call ini_key_is
    test eax, eax
    jnz 4b
    lea rdi, [rip + it]
    lea rsi, [rip + .Lk_request]
    call ini_key_is
    test eax, eax
    jnz 4b
    lea rbx, [rip + kept_keys]
41: mov rsi, [rbx]
    test rsi, rsi
    jz 42f
    lea rdi, [rip + it]
    call ini_key_is
    test eax, eax
    jnz 4b
    add rbx, 16
    jmp 41b
42: mov rdi, [rip + it + INI_key]
    call line_of
    mov [rip + cur_line], eax
    call arg_value
    test eax, eax
    jz .Ldp_fail
    jmp 4b
5:  mov dword ptr [rip + cur_line], 0
    lea rdi, [rip + g_lc_json]
    call jw_begin
    lea rdi, [rip + g_lc_json]
    xor esi, esi
    call cn_write
.Ldp_ok:
    mov eax, 1
    EPILOGUE
.Ldp_fail:
    xor eax, eax
    EPILOGUE

# it_in_section() -> eax 1 when it's key is in the section named g_lc_name
it_in_section:
    mov rdi, [rip + it + INI_sec]
    mov rsi, [rip + it + INI_seclen]
    mov rdx, [rip + g_lc_name + SB_ptr]
    mov rcx, [rip + g_lc_name + SB_len]
    jmp str_eq

# arg_value() -> eax 1 when it's key and value went into the tree, 0 with g_dcfg_err
arg_value:
    PROLOGUE 32
    mov r12, [rip + it + INI_key]
    mov r13, [rip + it + INI_keylen]
    # the value, variables replaced
    mov rdi, [rip + it + INI_val]
    mov rsi, [rip + it + INI_vallen]
    lea rdx, [rip + valb]
    xor ecx, ecx
    call dcfg_subst
    test eax, eax
    jz .Lav_fail
    # the declared type: of the whole key, else of its first segment (a map's KEY.NAME)
    mov r14, r13                # the key part typed
    mov edi, [rip + g_lc_dbg]
    mov rsi, r12
    mov rdx, r13
    call dbg_attr
    test rdx, rdx
    jnz 2f
    xor ecx, ecx
1:  cmp rcx, r13
    jae 15f
    cmp byte ptr [r12 + rcx], '.'
    je 11f
    inc rcx
    jmp 1b
11: mov r14, rcx
    mov edi, [rip + g_lc_dbg]
    mov rsi, r12
    mov rdx, rcx
    call dbg_attr
    test rdx, rdx
    jz 15f
    # only a map is written KEY.NAME
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lt_map]
    call str_eq_cstr
    test eax, eax
    jz 15f
    # KEY.NAME: NAME is one object key, dots and all
    mov rdi, r12
    mov rsi, r13
    mov edx, 1
    mov ecx, 's'
    mov r8, [rip + valb + SB_ptr]
    mov r9, [rip + valb + SB_len]
    call cn_set
    jmp .Lav_set
15: # undeclared: a string; dotted keys nest
    mov rdi, r12
    mov rsi, r13
    mov edx, CN_SEGS_MAX
    mov ecx, 's'
    mov r8, [rip + valb + SB_ptr]
    mov r9, [rip + valb + SB_len]
    call cn_set
    jmp .Lav_set
2:  mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lt_string]
    call str_eq_cstr
    test eax, eax
    jnz 15b
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rip + .Lt_path]
    call str_eq_cstr
    test eax, eax
    jnz .Lav_path
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rip + .Lt_int]
    call str_eq_cstr
    test eax, eax
    jnz .Lav_int
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rip + .Lt_bool]
    call str_eq_cstr
    test eax, eax
    jnz .Lav_bool
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rip + .Lt_list]
    call str_eq_cstr
    test eax, eax
    jnz .Lav_list
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rip + .Lt_map]
    call str_eq_cstr
    test eax, eax
    jnz .Lav_map
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    lea rdx, [rip + .Lt_choice]
    mov ecx, 7
    call str_starts
    test eax, eax
    jnz .Lav_choice
    jmp 15b                     # an unknown type: a string
.Lav_path:
    lea rdi, [rip + pathb]
    mov rsi, [rip + valb + SB_ptr]
    mov rdx, [rip + valb + SB_len]
    call dcfg_path
    mov rdi, r12
    mov rsi, r13
    mov edx, 1
    mov ecx, 's'
    mov r8, [rip + pathb + SB_ptr]
    mov r9, [rip + pathb + SB_len]
    call cn_set
    jmp .Lav_set
.Lav_int:
    mov rdi, [rip + valb + SB_ptr]
    mov rsi, [rip + valb + SB_len]
    call int_text
    test eax, eax
    jnz 3f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lm_int]
    call err_key
    jmp .Lav_fail
3:  call int_normalize           # 007 is 7: JSON numbers have no leading zeros
    mov rdi, r12
    mov rsi, r13
    mov edx, 1
    mov ecx, 'n'
    mov r8, [rip + valb + SB_ptr]
    mov r9, [rip + valb + SB_len]
    call cn_set
    jmp .Lav_set
.Lav_bool:
    mov rdi, [rip + valb + SB_ptr]
    mov rsi, [rip + valb + SB_len]
    lea rdx, [rip + .Lv_true]
    call str_eq_cstr
    test eax, eax
    jnz 41f
    mov rdi, [rip + valb + SB_ptr]
    mov rsi, [rip + valb + SB_len]
    lea rdx, [rip + .Lv_yes]
    call str_eq_cstr
    test eax, eax
    jnz 41f
    mov rdi, [rip + valb + SB_ptr]
    mov rsi, [rip + valb + SB_len]
    lea rdx, [rip + .Lv_false]
    call str_eq_cstr
    test eax, eax
    jnz 42f
    mov rdi, [rip + valb + SB_ptr]
    mov rsi, [rip + valb + SB_len]
    lea rdx, [rip + .Lv_no]
    call str_eq_cstr
    test eax, eax
    jnz 42f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lm_bool]
    call err_key
    jmp .Lav_fail
41: lea r8, [rip + .Lv_true]
    mov r9d, 4
    jmp 43f
42: lea r8, [rip + .Lv_false]
    mov r9d, 5
43: mov rdi, r12
    mov rsi, r13
    mov edx, 1
    mov ecx, 'b'
    call cn_set
    jmp .Lav_set
.Lav_list:
    # words; each line appends to the list
    mov rdi, [rip + valb + SB_ptr]
    mov rsi, [rip + valb + SB_len]
    call split_words
    test eax, eax
    js .Lav_quote
    mov [rsp + 16], eax         # words
    mov rdi, r12
    mov rsi, r13
    call cn_count
    mov r15, rax                # the next index
    mov rbx, [rip + wordb + SB_ptr]
5:  cmp dword ptr [rsp + 16], 0
    je .Lav_ok
    dec dword ptr [rsp + 16]
    # KEY.N
    lea rdi, [rip + pathb]
    mov rsi, r12
    mov rdx, r13
    call sb_set
    lea rdi, [rip + pathb]
    mov esi, '.'
    call sb_push_byte
    lea rdi, [rip + pathb]
    mov rsi, r15
    call sb_push_u64
    inc r15
    mov rdi, rbx
    call strlen
    mov r14, rax
    mov rdi, [rip + pathb + SB_ptr]
    mov rsi, [rip + pathb + SB_len]
    mov edx, 2
    mov ecx, 's'
    mov r8, rbx
    mov r9, r14
    call cn_set
    test eax, eax
    jz .Lav_conflict
    lea rbx, [rbx + r14 + 1]
    jmp 5b
.Lav_map:
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lm_map]
    call err_key
    jmp .Lav_fail
.Lav_choice:
    # one of the listed words
    mov rbx, [rsp]
    add rbx, 7
    mov r15, [rsp + 8]
    sub r15, 7
6:  test r15, r15
    jz 61f
    mov rdi, rbx
    mov rsi, r15
    call next_word
    add rbx, rcx
    sub r15, rcx
    test rdx, rdx
    jz 61f
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + valb + SB_ptr]
    mov rcx, [rip + valb + SB_len]
    call str_eq
    test eax, eax
    jz 6b
    jmp 15b
61: mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lm_choice]
    call err_key
    mov rdi, rax
    mov rsi, [rsp]
    add rsi, 7
    mov rdx, [rsp + 8]
    sub rdx, 7
    call err_addn
    jmp .Lav_fail
.Lav_quote:
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lm_quote]
    call err_key
    jmp .Lav_fail
.Lav_set:
    test eax, eax
    jnz .Lav_ok
.Lav_conflict:
    cmp dword ptr [rip + cn_leaves], CN_LEAVES_MAX
    jb 7f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lm_toomany]
    call err_key
    jmp .Lav_fail
7:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lm_conflict]
    call err_key
.Lav_fail:
    xor eax, eax
    EPILOGUE
.Lav_ok:
    mov eax, 1
    EPILOGUE

# int_normalize(): valb (an int_text) without leading zeros, and -0 as 0, in place
int_normalize:
    mov rdi, [rip + valb + SB_ptr]
    mov rsi, [rip + valb + SB_len]
    xor ecx, ecx                # the digits' start
    cmp byte ptr [rdi], '-'
    jne 1f
    mov ecx, 1
1:  mov rdx, rcx                # the first digit kept
2:  lea rax, [rdx + 1]
    cmp rax, rsi
    jae 3f
    cmp byte ptr [rdi + rdx], '0'
    jne 3f
    inc rdx
    jmp 2b
3:  # write: the sign (unless the number is 0), then the digits from rdx
    mov r8, rcx                 # out
    lea rax, [rdx + 1]
    cmp rax, rsi
    jne 4f
    cmp byte ptr [rdi + rdx], '0'
    jne 4f
    xor r8d, r8d                # -0: no sign
4:  mov al, [rdi + rdx]
    mov [rdi + r8], al
    inc r8
    inc rdx
    cmp rdx, rsi
    jb 4b
    mov [rip + valb + SB_len], r8
    mov byte ptr [rdi + r8], 0
    ret

# int_text(ptr, len) -> eax 1 for -?[0-9]+ (at most 18 digits)
int_text:
    xor eax, eax
    test rsi, rsi
    jz 9f
    cmp byte ptr [rdi], '-'
    jne 1f
    inc rdi
    dec rsi
    jz 9f
1:  cmp rsi, 18
    ja 9f
2:  movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja 9f
    inc rdi
    dec rsi
    jnz 2b
    mov eax, 1
9:  ret

# leaf_num(ptr, len) -> eax 1 for a leaf's integer: -?(0|[1-9][0-9]*), not -0, |v| < 2^53 (it goes
#   into the launch JSON as it is)
leaf_num:
    xor eax, eax
    xor r8d, r8d
    test rsi, rsi
    jz 9f
    cmp byte ptr [rdi], '-'
    jne 1f
    mov r8d, 1
    inc rdi
    dec rsi
    jz 9f
1:  cmp rsi, 16
    ja 9f
    cmp byte ptr [rdi], '0'
    jne 2f
    cmp rsi, 1
    jne 9f                      # a leading zero
    test r8d, r8d
    jnz 9f                      # -0
    mov eax, 1
    ret
2:  xor r9d, r9d
3:  movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja 9f
    imul r9, r9, 10
    add r9, rcx
    inc rdi
    dec rsi
    jnz 3b
    mov rcx, 1 << 53
    cmp r9, rcx
    jae 9f
    mov eax, 1
9:  ret

# dcfg_path(sb, ptr, len): a path value: ~ is the home, a relative path is inside the project
FN dcfg_path
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call sb_clear
    test r13, r13
    jz 8f
    cmp byte ptr [r12], '~'
    jne 2f
    cmp r13, 1
    je 1f
    cmp byte ptr [r12 + 1], '/'
    jne 2f
1:  lea rdi, [rip + .Lenv_home]
    call getenv
    test rax, rax
    jz 2f
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    inc r12
    dec r13
    jmp 8f
2:  PATH_ABSOLUTE r12, 8f
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, '/'
    call sb_push_byte
8:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, rbx
    call sb_z
    EPILOGUE

# split_words(ptr, len) -> eax the number of shell-like words, each NUL-terminated in wordb; "a b"
#   and 'a b' keep their spaces, \" and \\ inside double quotes; -1 for an unclosed quote
FN split_words
    PROLOGUE
    mov r12, rdi
    lea r13, [rdi + rsi]        # end
    xor r14d, r14d              # words
    lea rdi, [rip + wordb]
    call sb_clear
1:  # blanks
    cmp r12, r13
    jae 9f
    movzx eax, byte ptr [r12]
    cmp al, ' '
    je 11f
    cmp al, 9
    jne 2f
11: inc r12
    jmp 1b
2:  inc r14d
3:  cmp r12, r13
    jae 8f
    movzx eax, byte ptr [r12]
    cmp al, ' '
    je 8f
    cmp al, 9
    je 8f
    cmp al, '"'
    je 4f
    cmp al, 39
    je 6f
    lea rdi, [rip + wordb]
    mov esi, eax
    call sb_push_byte
    inc r12
    jmp 3b
4:  inc r12
41: cmp r12, r13
    jae .Lsw_open
    movzx eax, byte ptr [r12]
    cmp al, '"'
    je 43f
    cmp al, 92
    jne 42f
    lea rcx, [r12 + 1]
    cmp rcx, r13
    jae 42f
    movzx ecx, byte ptr [r12 + 1]
    cmp cl, '"'
    je 44f
    cmp cl, 92
    jne 42f
44: inc r12
    mov eax, ecx
42: lea rdi, [rip + wordb]
    mov esi, eax
    call sb_push_byte
    inc r12
    jmp 41b
43: inc r12
    jmp 3b
6:  inc r12
61: cmp r12, r13
    jae .Lsw_open
    movzx eax, byte ptr [r12]
    cmp al, 39
    je 43b
    lea rdi, [rip + wordb]
    mov esi, eax
    call sb_push_byte
    inc r12
    jmp 61b
8:  lea rdi, [rip + wordb]
    xor esi, esi
    call sb_push_byte
    jmp 1b
9:  mov eax, r14d
    EPILOGUE
.Lsw_open:
    mov eax, -1
    EPILOGUE

# ---------------- variables ----------------

# dcfg_subst(ptr, len, out sb, adapter) -> eax 1 with the text in out (NUL-terminated), its ${...}
#   variables replaced; 0 with g_dcfg_err. adapter 0: launch.ini's variables; 1: the adapter
#   command's (${port} ${extension} ${state} ${project} ${config:KEY|DEFAULT}).
FN dcfg_subst
    PROLOGUE 16
    mov r12, rdi
    lea r13, [rdi + rsi]
    mov rbx, rdx
    mov [rsp], ecx
    mov rdi, rbx
    call sb_clear
1:  cmp r12, r13
    jae 8f
    movzx eax, byte ptr [r12]
    cmp al, '$'
    jne 2f
    lea rcx, [r12 + 1]
    cmp rcx, r13
    jae 2f
    cmp byte ptr [r12 + 1], '$'
    jne 3f
    add r12, 2
    mov rdi, rbx
    mov esi, '$'
    call sb_push_byte
    jmp 1b
3:  cmp byte ptr [r12 + 1], '{'
    jne 2f
    # ${NAME}
    lea r14, [r12 + 2]
    mov rcx, r14
4:  cmp rcx, r13
    jae .Lsu_open
    cmp byte ptr [rcx], '}'
    je 5f
    inc rcx
    jmp 4b
5:  lea r12, [rcx + 1]
    mov r15, rcx
    sub r15, r14                # name length
    mov rdi, r14
    mov rsi, r15
    mov rdx, rbx
    mov ecx, [rsp]
    call subst_one
    test eax, eax
    jz .Lsu_fail
    jmp 1b
2:  mov rdi, rbx
    mov esi, eax
    call sb_push_byte
    inc r12
    jmp 1b
8:  mov rdi, rbx
    call sb_z
    mov eax, 1
    EPILOGUE
.Lsu_open:
    call err_line
    mov rdi, rax
    lea rsi, [rip + .Lm_unclosed]
    call cstr_copy
.Lsu_fail:
    xor eax, eax
    EPILOGUE

# subst_one(name ptr, len, out sb, adapter) -> eax 1 with the value appended, 0 with g_dcfg_err
subst_one:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov rbx, rdx
    mov [rsp], ecx
    # both kinds
    lea rdi, [rip + .Lvar_project]
    call var_is
    jz 10f
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz .Lso_noproject
    mov rdi, rbx
    call sb_push_cstr
    jmp .Lso_ok
10: lea rdi, [rip + .Lvar_home]
    call var_is
    jz 11f
    lea rdi, [rip + .Lenv_home]
    call getenv
    test rax, rax
    jz .Lso_ok
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    jmp .Lso_ok
11: cmp r13, 4
    jbe 12f
    cmp dword ptr [r12], 0x3a766e65     # "env:"
    jne 12f
    lea rdi, [rip + pathb]
    lea rsi, [r12 + 4]
    lea rdx, [r13 - 4]
    call sb_set
    mov rdi, [rip + pathb + SB_ptr]
    call getenv
    test rax, rax
    jz .Lso_ok
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    jmp .Lso_ok
12: cmp dword ptr [rsp], 0
    jne .Lso_adapter
    # launch.ini's
    lea rdi, [rip + .Lvar_projectname]
    call var_is
    jz 20f
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz .Lso_noproject
    call strlen
    mov rdi, [rip + g_project]
    mov rsi, rax
    call path_basename
    mov rdi, rbx
    mov rsi, rax
    call sb_push
    jmp .Lso_ok
20: # ${ask:PROMPT}, ${pick:PROMPT|A|B}, ${process}: the user's answer (debugask.s), else the
    # launch stops here and asks
    mov rdi, r12
    mov rsi, r13
    mov rdx, rbx
    call dask_value
    cmp eax, 1
    je .Lso_ok
    test eax, eax
    jz 23f
    mov dword ptr [rip + g_dcfg_code], DCE_ASK
    lea rdi, [rip + g_dcfg_err]
    lea rsi, [rip + .Lm_asking]
    call cstr_copy
    xor eax, eax
    EPILOGUE
23: # the active file's
    lea r14, [rip + file_vars]
21: mov rdi, [r14]
    test rdi, rdi
    jz .Lso_unknown
    call var_is
    jnz 22f
    add r14, 16
    jmp 21b
22: mov r15, [rip + g_doc]
    test r15, r15
    jz .Lso_nofile
    mov rdi, rbx
    mov rsi, r15
    call [r14 + 8]
    test eax, eax
    jz .Lso_nofile
    jmp .Lso_ok
.Lso_adapter:
    lea rdi, [rip + .Lvar_port]
    call var_is
    jz 30f
    mov rdi, rbx
    mov esi, [rip + g_lc_port]
    call sb_push_u64
    jmp .Lso_ok
30: lea rdi, [rip + .Lvar_extension]
    call var_is
    jz 31f
    mov edi, [rip + g_lc_dbg]
    call dbg_row
    mov rax, [rax + DBG_ext]
    mov rsi, [rax + EXT_dir]
    mov rdi, rbx
    call sb_push_cstr
    jmp .Lso_ok
31: lea rdi, [rip + .Lvar_state]
    call var_is
    jz 32f
    mov edi, [rip + g_lc_dbg]
    call dbg_row
    mov rax, [rax + DBG_ext]
    mov rsi, [rax + EXT_state]
    mov rdi, rbx
    call sb_push_cstr
    jmp .Lso_ok
32: cmp r13, 7
    jbe .Lso_unknown
    mov rdi, r12
    mov rsi, 7
    lea rdx, [rip + .Lvar_config]
    call str_eq_cstr
    test eax, eax
    jz .Lso_unknown
    # config:KEY|DEFAULT
    lea r14, [r12 + 7]
    lea r15, [r13 - 7]
    xor ecx, ecx
33: cmp rcx, r15
    jae 34f
    cmp byte ptr [r14 + rcx], '|'
    je 34f
    inc rcx
    jmp 33b
34: mov [rsp + 8], rcx
    mov rdi, r14
    mov rsi, rcx
    call cn_find
    test eax, eax
    js 35f
    mov edi, eax
    call cn_node
    cmp dword ptr [rax + CN_kind], 0
    jne 35f
    mov ecx, [rax + CN_val]
    mov rsi, [rip + cstrs + SB_ptr]
    add rsi, rcx
    mov edx, [rax + CN_vallen]
    mov rdi, rbx
    call sb_push
    jmp .Lso_ok
35: mov rcx, [rsp + 8]
    cmp rcx, r15
    jae .Lso_ok                 # no default: empty
    lea rsi, [r14 + rcx + 1]
    mov rdx, r15
    sub rdx, rcx
    dec rdx
    mov rdi, rbx
    call sb_push
.Lso_ok:
    mov eax, 1
    EPILOGUE
.Lso_noproject:
    call err_line
    mov rdi, rax
    lea rsi, [rip + .Lm_noproject]
    call cstr_copy
    xor eax, eax
    EPILOGUE
.Lso_nofile:
    call err_line
    mov rdi, rax
    lea rsi, [rip + .Lm_dollar]
    call cstr_copy
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call err_addn
    mov rdi, rax
    lea rsi, [rip + .Lm_nofile]
    call cstr_copy
    xor eax, eax
    EPILOGUE
.Lso_unknown:
    call err_line
    mov rdi, rax
    lea rsi, [rip + .Lm_unknown_var]
    call cstr_copy
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call err_addn
    mov byte ptr [rax], '}'
    mov byte ptr [rax + 1], 0
    xor eax, eax
    EPILOGUE

# var_is(cstr) -> ZF clear (jnz) when the name r12 (r13 bytes) is cstr
var_is:
    mov rdx, rdi
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    ret

# file variables: fv_*(out sb, doc) -> eax 1, 0 when the document has no file
fv_path:
    mov rax, [rsi + DOC_path]
    test rax, rax
    ret

fv_file:
    PROLOGUE
    mov rbx, rdi
    call fv_path
    jz 8f
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov eax, 1
8:  EPILOGUE

fv_dir:
    PROLOGUE
    mov rbx, rdi
    call fv_path
    jz 8f
    mov r12, rax
    mov rdi, rax
    call strlen
    mov rdi, r12
    mov rsi, rax
    call path_dirlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call sb_push
    mov eax, 1
8:  EPILOGUE

# fv_base: rax ptr, rdx len of the basename (ZF set without a file)
fv_base:
    push rbx
    call fv_path
    jz 8f
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call path_basename
    or ecx, 1                   # ZF clear
8:  pop rbx
    ret

fv_name:
    PROLOGUE
    mov rbx, rdi
    call fv_base
    jz 8f
    mov rdi, rbx
    mov rsi, rax
    call sb_push
    mov eax, 1
8:  EPILOGUE

fv_stem:
    PROLOGUE
    mov rbx, rdi
    call fv_base
    jz 8f
    mov r12, rax
    mov r13, rdx
    mov rcx, r13
1:  test rcx, rcx
    jz 2f
    cmp byte ptr [r12 + rcx - 1], '.'
    je 3f
    dec rcx
    jmp 1b
3:  cmp rcx, 1
    je 2f                       # .profile: all stem
    lea r13, [rcx - 1]
2:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov eax, 1
8:  EPILOGUE

fv_ext:
    PROLOGUE
    mov rbx, rdi
    call fv_base
    jz 8f
    mov r12, rax
    mov r13, rdx
    mov rcx, r13
1:  test rcx, rcx
    jz 7f
    cmp byte ptr [r12 + rcx - 1], '.'
    je 3f
    dec rcx
    jmp 1b
3:  cmp rcx, 1
    je 7f
    lea rsi, [r12 + rcx - 1]
    mov rdx, r13
    sub rdx, rcx
    inc rdx
    mov rdi, rbx
    call sb_push
7:  mov eax, 1
8:  EPILOGUE

fv_relative:
    PROLOGUE
    mov rbx, rdi
    call fv_path
    jz 8f
    mov r12, rax
    mov r13, [rip + g_project]
    test r13, r13
    jz 5f
    mov rdi, r13
    call strlen
    mov r14, rax
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    mov rdx, r13
    mov rcx, r14
    call str_starts
    test eax, eax
    jz 5f
    cmp byte ptr [r12 + r14], '/'
    jne 5f
    lea r12, [r12 + r14 + 1]
5:  mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov eax, 1
8:  EPILOGUE

fv_line:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    mov rsi, [r12 + DOC_cur]
    call doc_line_of
    lea rsi, [rax + 1]
    mov rdi, rbx
    call sb_push_u64
    mov eax, 1
    EPILOGUE

fv_column:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    mov rsi, [r12 + DOC_cur]
    call doc_line_of
    mov rdi, r12
    mov rsi, rax
    call doc_line_start
    mov rsi, [r12 + DOC_cur]
    sub rsi, rax
    inc rsi
    mov rdi, rbx
    call sb_push_u64
    mov eax, 1
    EPILOGUE

fv_selection:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [r12 + DOC_cur]
    mov r14, [r12 + DOC_anchor]
    cmp r13, r14
    jbe 1f
    xchg r13, r14
1:  mov r15, r14
    sub r15, r13
    jz 7f
    cmp r15, 65536
    jbe 2f
    mov r15d, 65536
2:  mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    call doc_range
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r15
    call sb_push
7:  mov eax, 1
    EPILOGUE

# ---------------- the configuration tree ----------------

FN cn_reset
    push rbx
    mov qword ptr [rip + cn + VEC_len], 0
    lea rdi, [rip + cstrs]
    call sb_clear
    lea rdi, [rip + cstrs]         # offset 0 stays unused
    xor esi, esi
    call sb_push_byte
    mov dword ptr [rip + cn_leaves], 0
    lea rdi, [rip + cn]
    mov esi, CN_NODE_SIZE
    call vec_push
    mov dword ptr [rax + CN_kind], 1
    mov dword ptr [rax + CN_kid], -1
    mov dword ptr [rax + CN_next], -1
    pop rbx
    ret

# cn_node(index) -> CN*
cn_node:
    mov eax, edi
    imul rax, rax, CN_NODE_SIZE
    add rax, [rip + cn + VEC_ptr]
    ret

# cs_add(ptr, len) -> eax the offset of a copy in cs
cs_add:
    push rbx
    mov rbx, [rip + cstrs + SB_len]
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + cstrs]
    call sb_push
    mov eax, ebx
    pop rbx
    ret

# is_index(ptr, len) -> eax 1 for a decimal segment (an array index), with rdx its value
is_index:
    xor eax, eax
    xor edx, edx
    test rsi, rsi
    jz 9f
    cmp rsi, 9
    ja 9f
1:  movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja 8f
    imul rdx, rdx, 10
    add rdx, rcx
    inc rdi
    dec rsi
    jnz 1b
    mov eax, 1
    ret
8:  xor edx, edx
9:  ret

# cn_child(parent, seg ptr, len, create kind) -> eax the child's index, -1 if missing (create 0) or
#   if it exists with another kind; create: 1 object, 2 array, 3 leaf. Arrays keep elements ordered.
cn_child:
    PROLOGUE 32
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
    mov edi, ebx
    call cn_node
    mov r15d, [rax + CN_kind]   # the parent's kind
    mov dword ptr [rsp + 4], -1 # the child to insert after (arrays)
    mov r14d, [rax + CN_kid]
    cmp r15d, 2
    jne 1f
    mov rdi, r12
    mov rsi, r13
    call is_index
    test eax, eax
    jz .Lcc_miss
    mov [rsp + 8], rdx
1:  test r14d, r14d
    js 5f
    mov edi, r14d
    call cn_node
    cmp r15d, 2
    jne 2f
    mov rcx, [rax + CN_index]
    cmp rcx, [rsp + 8]
    je 4f
    ja 5f                       # past it: insert before
    mov [rsp + 4], r14d
    jmp 3f
2:  mov [rsp + 4], r14d
    push rax
    push rax
    mov ecx, [rax + CN_name]
    mov rdi, [rip + cstrs + SB_ptr]
    add rdi, rcx
    mov esi, [rax + CN_namelen]
    mov rdx, r12
    mov rcx, r13
    call str_eq
    mov ecx, eax
    pop rax
    pop rax
    test ecx, ecx
    jnz 4f
3:  mov r14d, [rax + CN_next]
    jmp 1b
4:  # found: the kind must agree
    mov ecx, [rsp]
    test ecx, ecx
    jz 41f
    cmp ecx, 3
    jne 42f
    xor ecx, ecx
42: cmp ecx, [rax + CN_kind]
    jne .Lcc_miss
41: mov eax, r14d
    EPILOGUE
5:  cmp dword ptr [rsp], 0
    je .Lcc_miss
    # a new node after [rsp+4] (or first)
    mov rdi, r12
    mov rsi, r13
    call cs_add
    mov [rsp + 16], eax
    lea rdi, [rip + cn]
    mov esi, CN_NODE_SIZE
    call vec_push
    mov ecx, [rsp + 16]
    mov [rax + CN_name], ecx
    mov [rax + CN_namelen], r13d
    mov ecx, [rsp]
    cmp ecx, 3
    jne 51f
    xor ecx, ecx
51: mov [rax + CN_kind], ecx
    mov dword ptr [rax + CN_kid], -1
    mov rcx, [rsp + 8]
    mov [rax + CN_index], rcx
    mov rcx, [rip + cn + VEC_len]
    dec rcx
    mov [rsp + 20], ecx         # the new index
    mov ecx, [rsp + 4]
    test ecx, ecx
    js 52f
    mov edi, ecx
    push rax
    push rax
    call cn_node
    mov rdx, rax
    pop rax
    pop rax
    mov ecx, [rdx + CN_next]
    mov [rax + CN_next], ecx
    mov ecx, [rsp + 20]
    mov [rdx + CN_next], ecx
    jmp 53f
52: mov edi, ebx
    push rax
    push rax
    call cn_node
    mov rdx, rax
    pop rax
    pop rax
    mov ecx, [rdx + CN_kid]
    mov [rax + CN_next], ecx
    mov ecx, [rsp + 20]
    mov [rdx + CN_kid], ecx
53: mov eax, [rsp + 20]
    EPILOGUE
.Lcc_miss:
    mov eax, -1
    EPILOGUE

# cn_set(path ptr, len, splits, lkind, val ptr, len) -> eax 1, 0 when the path conflicts with an
#   earlier one (used both as an object and an array, or as a value and a container) or is too long.
#   The path splits at its first `splits` dots; a numeric segment under an array is an index.
FN cn_set
    PROLOGUE 48
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], edx
    mov [rsp + 20], ecx
    mov [rsp + 24], r8
    mov [rsp + 32], r9
    cmp rsi, CN_PATH_MAX
    ja .Lcs_fail
    # segments
    xor r12d, r12d              # count
    mov r13, rdi                # segment start
    lea r14, [rdi + rsi]        # end
    mov rcx, rdi
1:  cmp rcx, r14
    jae 2f
    cmp byte ptr [rcx], '.'
    jne 11f
    cmp r12d, [rsp + 16]
    jae 11f
    cmp r12d, CN_SEGS_MAX - 1
    jae .Lcs_fail
    lea rax, [rip + segs]
    mov rdx, r12
    shl rdx, 4
    mov [rax + rdx], r13
    mov r8, rcx
    sub r8, r13
    jz .Lcs_fail                # an empty segment
    mov [rax + rdx + 8], r8
    inc r12d
    lea r13, [rcx + 1]
11: inc rcx
    jmp 1b
2:  lea rax, [rip + segs]
    mov rdx, r12
    shl rdx, 4
    mov [rax + rdx], r13
    mov r8, r14
    sub r8, r13
    jz .Lcs_fail
    mov [rax + rdx + 8], r8
    inc r12d                    # segments
    # walk: each segment's kind comes from the one after it
    xor ebx, ebx                # node
    xor r15d, r15d              # segment index
3:  lea rax, [rip + segs]
    mov rdx, r15
    shl rdx, 4
    mov rsi, [rax + rdx]
    mov r13, [rax + rdx + 8]
    mov ecx, 3                  # the last: a leaf
    lea r8d, [r15 + 1]
    cmp r8d, r12d
    jae 4f
    push rsi
    push rsi
    mov rdi, [rax + rdx + 16]
    mov rsi, [rax + rdx + 24]
    call is_index
    pop rsi
    pop rsi
    mov ecx, 1
    add ecx, eax                # 2 when the next is an index
4:  cmp ecx, 3
    jne 41f
    # a leaf: replace an existing one, else count it
    push rsi
    push rcx
    mov edi, ebx
    mov rdx, r13
    xor ecx, ecx
    call cn_child
    pop rcx
    pop rsi
    test eax, eax
    jns 42f
    cmp dword ptr [rip + cn_leaves], CN_LEAVES_MAX
    jae .Lcs_fail
    inc dword ptr [rip + cn_leaves]
41: mov edi, ebx
    mov rdx, r13
    call cn_child
    test eax, eax
    js .Lcs_fail
42: mov ebx, eax
    inc r15d
    cmp r15d, r12d
    jb 3b
    # the leaf's value
    mov edi, ebx
    call cn_node
    cmp dword ptr [rax + CN_kind], 0
    jne .Lcs_fail
    mov ecx, [rsp + 20]
    mov [rax + CN_lkind], ecx
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    call cs_add
    mov r12d, eax
    mov edi, ebx
    call cn_node
    mov [rax + CN_val], r12d
    mov rcx, [rsp + 32]
    mov [rax + CN_vallen], ecx
    mov eax, 1
    EPILOGUE
.Lcs_fail:
    xor eax, eax
    EPILOGUE

# cn_put(name ptr, len, lkind, val ptr, len): a top-level leaf
cn_put:
    mov r9, r8
    mov r8, rcx
    mov ecx, edx
    xor edx, edx
    jmp cn_set

# cn_find(path ptr, len) -> eax the node at a dotted path, -1
FN cn_find
    PROLOGUE
    mov r12, rdi
    lea r13, [rdi + rsi]
    xor ebx, ebx
    cmp qword ptr [rip + cn + VEC_len], 0
    je 8f
1:  mov rcx, r12
2:  cmp rcx, r13
    jae 3f
    cmp byte ptr [rcx], '.'
    je 3f
    inc rcx
    jmp 2b
3:  mov r14, rcx
    mov edi, ebx
    mov rsi, r12
    mov rdx, rcx
    sub rdx, r12
    xor ecx, ecx
    call cn_child
    test eax, eax
    js 8f
    mov ebx, eax
    lea r12, [r14 + 1]
    cmp r14, r13
    jb 1b
    mov eax, ebx
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# cn_count(path ptr, len) -> rax the next index of the array there (0 when it does not exist)
cn_count:
    PROLOGUE
    call cn_find
    test eax, eax
    js 8f
    mov edi, eax
    call cn_node
    cmp dword ptr [rax + CN_kind], 2
    jne 8f
    xor ebx, ebx
    mov r12d, [rax + CN_kid]
1:  test r12d, r12d
    js 9f
    mov edi, r12d
    call cn_node
    mov rbx, [rax + CN_index]
    inc rbx
    mov r12d, [rax + CN_next]
    jmp 1b
9:  mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# cn_write(sb, node): the node as JSON (the root as an object)
FN cn_write
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov edi, r12d
    call cn_node
    mov r13, rax
    mov eax, [r13 + CN_kind]
    cmp eax, 1
    je 1f
    cmp eax, 2
    je 2f
    # a leaf
    mov ecx, [r13 + CN_val]
    mov rsi, [rip + cstrs + SB_ptr]
    add rsi, rcx
    mov edx, [r13 + CN_vallen]
    mov rdi, rbx
    mov eax, [r13 + CN_lkind]
    cmp eax, 's'
    jne 11f
    call jw_str
    EPILOGUE
11: cmp eax, 'z'
    jne 12f
    call jw_null
    EPILOGUE
12: call jw_rawn                # numbers, true and false as written
    EPILOGUE
1:  mov rdi, rbx
    call jw_obj
    mov r14d, [r13 + CN_kid]
3:  test r14d, r14d
    js 4f
    mov edi, r14d
    call cn_node
    mov r15, rax
    mov ecx, [r15 + CN_name]
    mov rsi, [rip + cstrs + SB_ptr]
    add rsi, rcx
    mov edx, [r15 + CN_namelen]
    mov rdi, rbx
    call jw_keyn
    mov rdi, rbx
    mov esi, r14d
    call cn_write
    mov edi, r14d
    call cn_node
    mov r14d, [rax + CN_next]
    jmp 3b
4:  mov rdi, rbx
    call jw_end_obj
    EPILOGUE
2:  mov rdi, rbx
    call jw_arr
    mov r14d, [r13 + CN_kid]
5:  test r14d, r14d
    js 6f
    mov rdi, rbx
    mov esi, r14d
    call cn_write
    mov edi, r14d
    call cn_node
    mov r14d, [rax + CN_next]
    jmp 5b
6:  mov rdi, rbx
    call jw_end_arr
    EPILOGUE

# ---------------- configuration bodies (feature debug) ----------------

# dcfg_from_leaves(name ptr, len, body ptr, len, EXT*) -> eax 1 with g_lc_* filled as dcfg_prepare
#   fills them, 0 with g_dcfg_err and g_dcfg_code (DCE_SYNTAX: the body does not parse; DCE_REFUSED:
#   its type is not one of this extension's debuggers). The body is a configuration body ("N" LF,
#   then N leaves "KIND PATH_LEN VALUE_LEN" LF + PATH + VALUE; extra records after them are not
#   read): `type` picks the extension's own debugger, `request` is launch (the default) or attach,
#   `noDebug` true runs without debugging, every other leaf is an argument as it is
FN dcfg_from_leaves
    PROLOGUE 64
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov r12, rdx                # the body
    lea r13, [rdx + rcx]        # its end
    mov r14, r8                 # EXT*
    mov qword ptr [rsp + 16], 0 # type ptr
    mov qword ptr [rsp + 24], 0 # type len
    mov dword ptr [rip + g_dcfg_code], DCE_SYNTAX
    mov dword ptr [rip + cur_line], 0
    mov dword ptr [rip + g_lc_dbg], -1
    mov dword ptr [rip + g_lc_request], 0
    mov dword ptr [rip + g_lc_nodebug], 0
    lea rdi, [rip + g_lc_name]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_set
    lea rdi, [rip + g_lc_section]
    call sb_clear
    lea rdi, [rip + g_lc_before]
    call sb_clear
    lea rdi, [rip + g_lc_after]
    call sb_clear
    lea rdi, [rip + g_lc_server]
    call sb_clear
    lea rdi, [rip + g_lc_compound]
    call sb_clear
    call cn_reset
    # N LF
    mov rdi, r12
    mov rsi, r13
    call dec_at
    test rdx, rdx
    jz .Lfl_syntax
    cmp rax, CN_LEAVES_MAX
    ja .Lfl_syntax
    mov r15, rax                # leaves left
    cmp rdx, r13
    jae .Lfl_syntax
    cmp byte ptr [rdx], 10
    jne .Lfl_syntax
    lea r12, [rdx + 1]
1:  test r15, r15
    jz 5f
    # KIND PATH_LEN VALUE_LEN LF
    lea rax, [r12 + 2]
    cmp rax, r13
    jae .Lfl_syntax
    movzx ebx, byte ptr [r12]
    cmp byte ptr [r12 + 1], ' '
    jne .Lfl_syntax
    lea rdi, [r12 + 2]
    mov rsi, r13
    call dec_at
    test rdx, rdx
    jz .Lfl_syntax
    test rax, rax
    jz .Lfl_syntax              # an empty path
    cmp rax, CN_PATH_MAX
    ja .Lfl_syntax
    mov [rsp + 32], rax         # PATH_LEN
    cmp rdx, r13
    jae .Lfl_syntax
    cmp byte ptr [rdx], ' '
    jne .Lfl_syntax
    lea rdi, [rdx + 1]
    mov rsi, r13
    call dec_at
    test rdx, rdx
    jz .Lfl_syntax
    cmp rax, 65536
    ja .Lfl_syntax
    mov [rsp + 40], rax         # VALUE_LEN
    cmp rdx, r13
    jae .Lfl_syntax
    cmp byte ptr [rdx], 10
    jne .Lfl_syntax
    lea r12, [rdx + 1]          # the path
    mov rax, r12
    add rax, [rsp + 32]
    mov [rsp + 48], rax         # the value
    add rax, [rsp + 40]
    cmp rax, r13
    ja .Lfl_syntax
    mov [rsp + 56], rax         # the next record
    # the kind and its value
    cmp ebx, 's'
    je 3f
    cmp ebx, 'n'
    jne 21f
    mov rdi, [rsp + 48]
    mov rsi, [rsp + 40]
    call leaf_num
    test eax, eax
    jz .Lfl_syntax
    jmp 3f
21: cmp ebx, 'b'
    jne 22f
    mov rdi, [rsp + 48]
    mov rsi, [rsp + 40]
    lea rdx, [rip + .Lv_true]
    call str_eq_cstr
    test eax, eax
    jnz 3f
    mov rdi, [rsp + 48]
    mov rsi, [rsp + 40]
    lea rdx, [rip + .Lv_false]
    call str_eq_cstr
    test eax, eax
    jnz 3f
    jmp .Lfl_syntax
22: cmp ebx, 'z'
    jne .Lfl_syntax
    cmp qword ptr [rsp + 40], 0
    jne .Lfl_syntax
3:  # type, request and noDebug are rhun's; name comes from NAME
    mov rdi, r12
    mov rsi, [rsp + 32]
    lea rdx, [rip + .Lk_type]
    call str_eq_cstr
    test eax, eax
    jz 31f
    cmp ebx, 's'
    jne .Lfl_syntax
    mov rax, [rsp + 48]
    mov [rsp + 16], rax
    mov rax, [rsp + 40]
    mov [rsp + 24], rax
    jmp 4f
31: mov rdi, r12
    mov rsi, [rsp + 32]
    lea rdx, [rip + .Lk_request]
    call str_eq_cstr
    test eax, eax
    jz 33f
    mov rdi, [rsp + 48]
    mov rsi, [rsp + 40]
    lea rdx, [rip + .Lv_launch]
    call str_eq_cstr
    test eax, eax
    jnz 4f
    mov rdi, [rsp + 48]
    mov rsi, [rsp + 40]
    lea rdx, [rip + .Lv_attach]
    call str_eq_cstr
    test eax, eax
    jz .Lfl_syntax
    mov dword ptr [rip + g_lc_request], 1
    jmp 4f
33: mov rdi, r12
    mov rsi, [rsp + 32]
    lea rdx, [rip + .Lk_name]
    call str_eq_cstr
    test eax, eax
    jnz 4f
    mov rdi, r12
    mov rsi, [rsp + 32]
    lea rdx, [rip + .Lk_nodebug]
    call str_eq_cstr
    test eax, eax
    jz 34f
    cmp ebx, 'b'
    jne .Lfl_syntax
    mov rdi, [rsp + 48]
    mov rsi, [rsp + 40]
    lea rdx, [rip + .Lv_true]
    call str_eq_cstr
    mov [rip + g_lc_nodebug], eax
    jmp 4f
34: mov rdi, r12
    mov rsi, [rsp + 32]
    mov edx, CN_SEGS_MAX
    mov ecx, ebx
    mov r8, [rsp + 48]
    mov r9, [rsp + 40]
    call cn_set
    test eax, eax
    jz .Lfl_syntax              # a path used two ways, or too many leaves
4:  mov r12, [rsp + 56]
    dec r15
    jmp 1b
5:  # arrays as the body gives them: indices 0, 1, 2 ... without gaps
    cmp qword ptr [rip + cn + VEC_len], 0
    je 50f
    xor edi, edi
    call cn_dense
    test eax, eax
    jz .Lfl_syntax
50: # the debugger: one of this extension's types
    mov rsi, [rsp + 16]
    test rsi, rsi
    jz .Lfl_notype
    mov rdi, r14
    mov rdx, [rsp + 24]
    call dbg_by_type_ext
    mov [rip + g_lc_dbg], eax
    test eax, eax
    js .Lfl_notype
    lea rdi, [rip + .Lk_type]
    mov esi, 4
    mov edx, 's'
    mov rcx, [rsp + 16]
    mov r8, [rsp + 24]
    call cn_put
    lea rcx, [rip + .Lv_launch]
    mov r8d, 6
    cmp dword ptr [rip + g_lc_request], 0
    je 51f
    lea rcx, [rip + .Lv_attach]
51: lea rdi, [rip + .Lk_request]
    mov esi, 7
    mov edx, 's'
    call cn_put
    lea rdi, [rip + .Lk_name]
    mov esi, 4
    mov edx, 's'
    mov rcx, [rsp]
    mov r8, [rsp + 8]
    call cn_put
    cmp dword ptr [rip + g_lc_nodebug], 0
    je 52f
    lea rdi, [rip + .Lk_nodebug]
    mov esi, 7
    mov edx, 'b'
    lea rcx, [rip + .Lv_true]
    mov r8d, 4
    call cn_put
52: lea rdi, [rip + g_lc_json]
    call jw_begin
    lea rdi, [rip + g_lc_json]
    xor esi, esi
    call cn_write
    mov eax, 1
    EPILOGUE
.Lfl_syntax:
    lea rdi, [rip + .Lm_body]
    call err_set
    xor eax, eax
    EPILOGUE
.Lfl_notype:
    mov dword ptr [rip + g_dcfg_code], DCE_REFUSED
    lea rdi, [rip + .Lm_nottype]
    call err_set
    xor eax, eax
    EPILOGUE

# dcfg_leaves(sb): the prepared configuration (the tree dcfg_prepare built) as a configuration
#   body: "N" LF and its leaves, appended to sb
FN dcfg_leaves
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + lvb]
    call sb_clear
    lea rdi, [rip + lpb]
    call sb_clear
    mov dword ptr [rip + lvn], 0
    cmp qword ptr [rip + cn + VEC_len], 0
    je 1f
    xor edi, edi
    call cl_walk
1:  mov rdi, rbx
    mov esi, [rip + lvn]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [rip + lvb + SB_ptr]
    mov rdx, [rip + lvb + SB_len]
    call sb_push
    EPILOGUE

# cl_walk(node): its leaves into lvb with lpb as the path so far
cl_walk:
    PROLOGUE
    mov r12d, edi
    mov edi, r12d
    call cn_node
    mov r13, rax
    mov eax, [r13 + CN_kind]
    test eax, eax
    jnz 3f
    # a leaf: KIND PATH_LEN VALUE_LEN LF PATH VALUE
    lea rdi, [rip + lvb]
    mov esi, [r13 + CN_lkind]
    call sb_push_byte
    lea rdi, [rip + lvb]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + lvb]
    mov rsi, [rip + lpb + SB_len]
    call sb_push_u64
    lea rdi, [rip + lvb]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + lvb]
    mov esi, [r13 + CN_vallen]
    call sb_push_u64
    lea rdi, [rip + lvb]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + lvb]
    mov rsi, [rip + lpb + SB_ptr]
    mov rdx, [rip + lpb + SB_len]
    call sb_push
    mov edi, r12d
    call cn_node
    mov ecx, [rax + CN_val]
    mov rsi, [rip + cstrs + SB_ptr]
    add rsi, rcx
    mov edx, [rax + CN_vallen]
    lea rdi, [rip + lvb]
    call sb_push
    inc dword ptr [rip + lvn]
    EPILOGUE
3:  mov r15d, eax               # 1 object, 2 array
    mov r14d, [r13 + CN_kid]
    mov rbx, [rip + lpb + SB_len]   # this node's path length
4:  test r14d, r14d
    js 9f
    mov [rip + lpb + SB_len], rbx
    test rbx, rbx
    jz 41f
    lea rdi, [rip + lpb]
    mov esi, '.'
    call sb_push_byte
41: mov edi, r14d
    call cn_node
    cmp r15d, 2
    je 42f
    mov ecx, [rax + CN_name]
    mov rsi, [rip + cstrs + SB_ptr]
    add rsi, rcx
    mov edx, [rax + CN_namelen]
    lea rdi, [rip + lpb]
    call sb_push
    jmp 43f
42: mov rsi, [rax + CN_index]
    lea rdi, [rip + lpb]
    call sb_push_u64
43: mov edi, r14d
    call cl_walk
    mov edi, r14d
    call cn_node
    mov r14d, [rax + CN_next]
    jmp 4b
9:  mov [rip + lpb + SB_len], rbx
    EPILOGUE

# cn_dense(node) -> eax 1 when every array at or under the node holds the indices 0..n-1 (a
#   configuration body's rule; launch.ini may skip indices)
cn_dense:
    PROLOGUE
    mov r12d, edi
    call cn_node
    mov r13d, [rax + CN_kind]
    test r13d, r13d
    jz 8f                       # a leaf
    mov r14d, [rax + CN_kid]
    xor r15d, r15d              # the index expected next
1:  test r14d, r14d
    js 8f
    mov edi, r14d
    call cn_node
    cmp r13d, 2
    jne 2f
    cmp [rax + CN_index], r15
    jne 9f
    inc r15
2:  mov edi, r14d
    call cn_dense
    test eax, eax
    jz 9f
    mov edi, r14d
    call cn_node
    mov r14d, [rax + CN_next]
    jmp 1b
8:  mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# dec_at(ptr, end) -> rax a decimal number there, rdx the byte after its digits (0 without a digit
#   or past 15 digits)
dec_at:
    xor eax, eax
    xor ecx, ecx
1:  cmp rdi, rsi
    jae 2f
    movzx edx, byte ptr [rdi]
    sub edx, '0'
    cmp edx, 9
    ja 2f
    imul rax, rax, 10
    add rax, rdx
    inc rdi
    inc ecx
    cmp ecx, 15
    ja 3f
    jmp 1b
2:  test ecx, ecx
    jz 3f
    mov rdx, rdi
    ret
3:  xor edx, edx
    ret

# dbg_by_type_ext(EXT*, ptr, len) -> eax index of that extension's debugger of that type, or -1
FN dbg_by_type_ext
    PROLOGUE
    mov r14, rdi
    mov r12, rsi
    mov r13, rdx
    xor ebx, ebx
1:  cmp ebx, [rip + g_ndebuggers]
    jae 8f
    mov edi, ebx
    call dbg_row
    cmp [rax + DBG_ext], r14
    jne 2f
    mov rdi, [rax + DBG_type]
    mov rsi, r12
    mov rdx, r13
    call cstr_eq_n
    test eax, eax
    jz 2f
    mov edi, ebx
    call dbg_live
    test eax, eax
    jz 2f
    mov eax, ebx
    EPILOGUE
2:  inc ebx
    jmp 1b
8:  mov eax, -1
    EPILOGUE

# ---------------- the adapter's command ----------------

# dcfg_adapter() -> eax 1 with g_lc_args (argv words, the program found) and g_lc_cmd, 0 with
#   g_dcfg_err. The program is the first of its names found on PATH or in `paths`, or a path inside
#   the extension; the arguments are words with variables.
FN dcfg_adapter
    PROLOGUE 16
    mov dword ptr [rip + cur_line], 0
    lea rdi, [rip + g_lc_args]
    call sb_clear
    mov dword ptr [rip + g_lc_nargs], 0
    mov edi, [rip + g_lc_dbg]
    call dbg_row
    mov rbx, rax
    mov r12, [rbx + DBG_program_t]
    test r12, r12
    jnz 1f
    mov r12, [rbx + DBG_program]
    test r12, r12
    jz .Lda_noprog
1:  # candidates, variables replaced first (program = ${config:python|python3})
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rip + valb]
    mov ecx, 1
    call dcfg_subst
    test eax, eax
    jz .Lda_fail
    mov r12, [rip + valb + SB_ptr]
    mov r13, [rip + valb + SB_len]
2:  test r13, r13
    jz .Lda_missing
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz .Lda_missing
    mov rdi, rax
    mov rsi, rdx
    call find_program
    test rax, rax
    jz 2b
    mov r14, rax
    lea rdi, [rip + g_lc_args]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + g_lc_args]
    xor esi, esi
    call sb_push_byte
    inc dword ptr [rip + g_lc_nargs]
    mov rdi, r14
    call mem_free
    # the arguments
    mov r12, [rbx + DBG_args_t]
    test r12, r12
    jnz 3f
    mov r12, [rbx + DBG_args]
    test r12, r12
    jz 7f
3:  mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call split_words
    test eax, eax
    js .Lda_quote
    mov r13d, eax
    # the words are substituted one by one (a project path may hold spaces); wordb is reused, so copy
    lea rdi, [rip + argw]
    mov rsi, [rip + wordb + SB_ptr]
    mov rdx, [rip + wordb + SB_len]
    call sb_set
    xor r15d, r15d              # offset into argw
4:  test r13d, r13d
    jz 7f
    dec r13d
    mov rdi, [rip + argw + SB_ptr]
    add rdi, r15
    call strlen
    mov r14, rax
    mov rdi, [rip + argw + SB_ptr]
    add rdi, r15
    mov rsi, rax
    lea rdx, [rip + valb]
    mov ecx, 1
    call dcfg_subst_keep
    test eax, eax
    jz .Lda_fail
    lea rdi, [rip + g_lc_args]
    mov rsi, [rip + valb + SB_ptr]
    mov rdx, [rip + valb + SB_len]
    call sb_push
    lea rdi, [rip + g_lc_args]
    xor esi, esi
    call sb_push_byte
    inc dword ptr [rip + g_lc_nargs]
    lea r15, [r15 + r14 + 1]
    jmp 4b
7:  call make_cmd
    mov eax, 1
    EPILOGUE
.Lda_noprog:
    lea rdi, [rip + .Lm_noprog]
    call err_set
    jmp .Lda_fail
.Lda_quote:
    lea rdi, [rip + .Lm_args_quote]
    call err_set
    jmp .Lda_fail
.Lda_missing:
    # "Delve (dlv) is not installed."
    lea rdi, [rip + g_dcfg_err]
    mov rsi, [rbx + DBG_title]
    test rsi, rsi
    jnz 81f
    mov rsi, [rbx + DBG_type]
81: call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Lm_paren]
    call cstr_copy
    mov rsi, [rbx + DBG_program_t]
    test rsi, rsi
    jnz 82f
    mov rsi, [rbx + DBG_program]
82: mov rdi, rax
    call err_add
    mov rdi, rax
    lea rsi, [rip + .Lm_not_installed]
    call cstr_copy
    mov rsi, [rbx + DBG_install]
    test rsi, rsi
    jz .Lda_fail
    mov rdi, rax
    lea rsi, [rip + .Lm_install]
    call cstr_copy
    mov rdi, rax
    mov rsi, [rbx + DBG_install]
    call err_add
.Lda_fail:
    xor eax, eax
    EPILOGUE

# dcfg_subst_keep: dcfg_subst on a private copy of the text (it may lie in a buffer the
#   substitution reuses)
dcfg_subst_keep:
    PROLOGUE 16
    mov [rsp], rdx
    mov [rsp + 8], ecx
    # a private copy: subst_one may use pathb for ${env:NAME}
    lea r12, [rip + keepb]
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, r12
    call sb_set
    mov rdi, [r12 + SB_ptr]
    mov rsi, [r12 + SB_len]
    mov rdx, [rsp]
    mov ecx, [rsp + 8]
    call dcfg_subst
    EPILOGUE

# find_program(name ptr, len) -> rax path to run (mem_free it), or 0. A name with a / is a path
#   inside the extension (or absolute, or ~/); else PATH, then the debugger's `paths`.
find_program:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + keepb]
    mov rsi, r12
    mov rdx, r13
    call sb_set
    mov rbx, [rip + keepb + SB_ptr]
    # a path?
    xor ecx, ecx
1:  cmp rcx, r13
    jae 3f
    cmp byte ptr [rbx + rcx], '/'
    je 2f
    inc rcx
    jmp 1b
2:  cmp byte ptr [rbx], '~'
    je 21f
    PATH_ABSOLUTE rbx, 22f
    mov edi, [rip + g_lc_dbg]
    call dbg_row
    mov rax, [rax + DBG_ext]
    mov rdi, [rax + EXT_dir]
    mov rsi, rbx
    call path_join
    jmp 25f
21: lea rdi, [rip + pathb2]
    mov rsi, rbx
    mov rdx, r13
    call dcfg_path
    mov rdi, [rip + pathb2 + SB_ptr]
    call dup_cstr
    jmp 25f
22: mov rdi, rbx
    call dup_cstr
25: mov r14, rax
    mov rdi, rax
    mov esi, 1                  # X_OK
    SYS SYS_access
    test rax, rax
    jnz 26f
    mov rax, r14
    EPILOGUE
26: mov rdi, r14
    call mem_free
    xor eax, eax
    EPILOGUE
3:
.ifdef WINDOWS
    mov rdi, rbx
    call win_runtime
.else
    # the login environment's PATH (an app started from the Dock lacks ~/go/bin and friends)
    xor edi, edi
    xor esi, esi
    xor edx, edx
    call uproc_env_make
    mov r14, rax
    mov rdi, rbx
    mov rsi, rax
    call uproc_which
    push rax
    push rax
    mov rdi, r14
    call mem_free
    pop rax
    pop rax
.endif
    test rax, rax
    jnz 9f
    # the debugger's paths
    mov edi, [rip + g_lc_dbg]
    call dbg_row
    mov r14, [rax + DBG_paths]
    test r14, r14
    jz 8f
    mov rdi, r14
    call strlen
    mov r15, rax
4:  test r15, r15
    jz 8f
    mov rdi, r14
    mov rsi, r15
    call next_word
    add r14, rcx
    sub r15, rcx
    test rdx, rdx
    jz 8f
    lea rdi, [rip + pathb2]
    mov rsi, rax
    call dcfg_path
    lea rdi, [rip + pathb2]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + pathb2]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + pathb2]
    call sb_z
    mov rdi, rax
    mov esi, 1
    SYS SYS_access
    test rax, rax
    jnz 4b
    mov rdi, [rip + pathb2 + SB_ptr]
    call dup_cstr
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# make_cmd(): g_lc_cmd = the argv words joined by spaces, a word with blanks or quotes in '...'
make_cmd:
    PROLOGUE
    lea rdi, [rip + g_lc_cmd]
    call sb_clear
    mov rbx, [rip + g_lc_args + SB_ptr]
    mov r12d, [rip + g_lc_nargs]
1:  test r12d, r12d
    jz 8f
    dec r12d
    mov rdi, rbx
    call strlen
    mov r13, rax
    cmp qword ptr [rip + g_lc_cmd + SB_len], 0
    je 2f
    lea rdi, [rip + g_lc_cmd]
    mov esi, ' '
    call sb_push_byte
2:  xor ecx, ecx
    xor r14d, r14d              # needs quotes
3:  cmp rcx, r13
    jae 4f
    movzx eax, byte ptr [rbx + rcx]
    cmp al, ' '
    je 31f
    cmp al, '"'
    je 31f
    cmp al, 39
    je 31f
    cmp al, 9
    jne 32f
31: mov r14d, 1
32: inc rcx
    jmp 3b
4:  test r13, r13
    jnz 41f
    mov r14d, 1
41: test r14d, r14d
    jz 5f
    lea rdi, [rip + g_lc_cmd]
    mov esi, 39
    call sb_push_byte
5:  lea rdi, [rip + g_lc_cmd]
    mov rsi, rbx
    mov rdx, r13
    call sb_push
    test r14d, r14d
    jz 6f
    lea rdi, [rip + g_lc_cmd]
    mov esi, 39
    call sb_push_byte
6:  lea rbx, [rbx + r13 + 1]
    jmp 1b
8:  lea rdi, [rip + g_lc_cmd]
    call sb_z
    EPILOGUE

.bss
.p2align 3
keepb: .zero SB_SIZE
pathb2: .zero SB_SIZE
argw: .zero SB_SIZE

.section .rodata
.Lm_line: .asciz "launch.ini line "
.Lm_colon: .asciz ": "
.Lm_no_file: .asciz "no launch configurations: add .rhun/launch.ini to the project"
.Lm_no_config: .asciz "no configuration named "
.Lm_no_type: .asciz "the configuration has no type: "
.Lm_body: .asciz "the configuration body does not parse"
.Lm_asking: .asciz "the configuration asks the user first"
.Lm_nottype: .asciz "the configuration's type is not one of your debuggers"
.Lm_no_debugger: .asciz "no installed extension provides a debugger of type "
.Lm_no_debugger2: .asciz ""
.Lm_request: .asciz " must be launch or attach"
.Lm_int: .asciz " must be a whole number"
.Lm_bool: .asciz " must be true or false"
.Lm_map: .asciz " is written as KEY.NAME = value"
.Lm_choice: .asciz " must be one of: "
.Lm_quote: .asciz " has an unclosed quote"
.Lm_conflict: .asciz " conflicts with another key (a value, an object and a list at once)"
.Lm_toomany: .asciz ": too many values (4096 at most)"
.Lm_unclosed: .asciz "a ${ without its }"
.Lm_noproject: .asciz "${project} needs an open folder"
.Lm_dollar: .asciz "${"
.Lm_nofile: .asciz "} needs an open file"
.Lm_unknown_var: .asciz "unknown variable ${"
.Lm_noprog: .asciz "the debugger names no program"
.Lm_args_quote: .asciz "the debugger's args have an unclosed quote"
.Lm_paren: .asciz " ("
.Lm_not_installed: .asciz ") is not installed."
.Lm_install: .asciz " Install it with: "
.Lf_launch: .asciz "/.rhun/launch.ini"
.Lk_transport: .asciz "transport"
.Lk_resolve: .asciz "resolve"
.Lk_program_dot: .asciz "program."
.Lk_args_dot: .asciz "args."
.Lk_attr_dot: .ascii "attr."
.Lk_title: .asciz "title"
.Lk_languages: .asciz "languages"
.Lk_program: .asciz "program"
.Lk_paths: .asciz "paths"
.Lk_args: .asciz "args"
.Lk_requests: .asciz "requests"
.Lk_templates: .asciz "templates"
.Lk_install: .asciz "install"
.Lk_type: .asciz "type"
.Lk_request: .asciz "request"
.Lk_name: .asciz "name"
.Lk_nodebug: .asciz "noDebug"
.Lk_before: .asciz "before"
.Lk_after: .asciz "after"
.Lk_server: .asciz "server"
.Lk_compound: .asciz "compound"
.Lk_hidden: .asciz "hidden"
.Lv_tcp: .asciz "tcp"
.Lv_launch: .asciz "launch"
.Lv_attach: .asciz "attach"
.Lv_true: .asciz "true"
.Lv_false: .asciz "false"
.Lv_yes: .asciz "yes"
.Lv_no: .asciz "no"
.Lt_string: .asciz "string"
.Lt_path: .asciz "path"
.Lt_int: .asciz "int"
.Lt_bool: .asciz "bool"
.Lt_list: .asciz "list"
.Lt_map: .asciz "map"
.Lt_choice: .asciz "choice "
.Lenv_home: .asciz "HOME"
.Lvar_project: .asciz "project"
.Lvar_projectname: .asciz "projectName"
.Lvar_home: .asciz "home"
.Lvar_port: .asciz "port"
.Lvar_extension: .asciz "extension"
.Lvar_state: .asciz "state"
.Lvar_config: .asciz "config:"
.Lvar_file: .asciz "file"
.Lvar_filedir: .asciz "fileDir"
.Lvar_filename: .asciz "fileName"
.Lvar_filestem: .asciz "fileStem"
.Lvar_fileext: .asciz "fileExt"
.Lvar_relativefile: .asciz "relativeFile"
.Lvar_line: .asciz "line"
.Lvar_column: .asciz "column"
.Lvar_selection: .asciz "selection"
.p2align 3
dbg_keys:
    .quad .Lk_title, DBG_title, .Lk_languages, DBG_languages, .Lk_program, DBG_program
    .quad .Lk_paths, DBG_paths, .Lk_args, DBG_args, .Lk_requests, DBG_requests
    .quad .Lk_templates, DBG_templates, .Lk_install, DBG_install, 0, 0
kept_keys:
    .quad .Lk_before, g_lc_before, .Lk_after, g_lc_after, .Lk_server, g_lc_server
    .quad .Lk_compound, g_lc_compound, .Lk_hidden, 0, 0, 0
file_vars:
    .quad .Lvar_file, fv_file, .Lvar_filedir, fv_dir, .Lvar_filename, fv_name
    .quad .Lvar_filestem, fv_stem, .Lvar_fileext, fv_ext, .Lvar_relativefile, fv_relative
    .quad .Lvar_line, fv_line, .Lvar_column, fv_column, .Lvar_selection, fv_selection, 0, 0
