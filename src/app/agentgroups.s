# The session list's own bookkeeping, per project (phase 6): the user's groups, which session is in which,
# the sessions archived and unarchived by hand, the unread marks, the status filter, the sections shown
# and the conversation that was open last. The extension keeps the same in its own storage, outside the
# CLI (ext-host-protocol 4: archive, unread, groups, list filter are host state), so rhun keeps them in its
# state folder: session_project_file(".agents-list"). Titles the user gives live where the driver keeps them
# (DRV_rename: Claude Code's own custom-title line); a kind without a driver keeps its title here.
#
# A session is named by its key (agst_key): its kind's word and its id ("claude:UUID", a Codex or Grok
# session by its file, an extension's by its id), so the marks follow a conversation across pages, folders
# of worktrees and restarts. The file is read once, when the list first needs it (drawing reads rhun's own
# state; nothing starts a process), and written whole after each change the user makes (file_write_all:
# a temporary file and a rename). Lines, tab-separated, a name's tab, line end and backslash escaped:
#   agentlist 1 | filter MASK | show BITS | tries N | open KEY | group ID FLAGS NAME | s KEY GID FLAGS TITLE
#
#   agst_load()                       the file read once (no project: memory only)
#   agst_reset()                      another project: everything goes; the next load reads its file
#   agst_key(AS*) -> rax ptr, rdx len (a static buffer; len 0: it has no key yet)
#   agst_of(AS*) -> eax flags (SF_*), edx its group's id (0 none): O(1)
#   agst_mark(AS*, set, clear)        flags on and off, saved when they changed
#   agst_put_group(AS*, gid)          its group (0: none), saved
#   agst_title(AS*) -> rax rhun's own title for it, or 0; agst_set_title(AS*, ptr, len)
#   agst_groups() -> rax VEC* of GR (in their order); agst_group(id) -> rax GR* or 0
#   agst_group_new(ptr, len) -> rax GR*; agst_group_rename(id, ptr, len); agst_group_delete(id);
#   agst_group_flip(id)               collapsed, or open again
#   agst_filter() -> eax; agst_set_filter(mask); agst_show() -> eax; agst_set_show(bits)
#   agst_open() -> rax KEY cstr or 0; agst_set_open(AS* or 0); agst_tries() -> eax, agst_set_tries(n): the
#     restores of it that did not finish
#   agst_dump(sb)                     print-agent-list-state
.include "rhun.inc"

.equ FILE_MAX, 4 << 20          # the state file's bytes at most
.equ ENTS_MAX, 200000           # sessions with a mark at most (more are not kept)
.equ GROUPS_MAX, 200
.equ NAME_MAX, 200              # a group's name, a title: bytes at most
.equ FIELDS, 6

# a session's marks
STRUCT
F EN_key, 8             # owned cstr
F EN_hash, 8
F EN_gid, 4             # its group's id, 0 none
F EN_flags, 4           # SF_*
F EN_title, 8           # owned cstr: rhun's own title (a kind without a driver's rename), or 0
ENDSTRUCT EN_SIZE

.bss
.p2align 3
.globl agst_gen
agst_gen: .quad 0               # counts every change: the list is made again
ents: .zero VEC_SIZE            # EN*: every session with a mark, in the order they came
tbl: .quad 0                    # EN* by hash (open addressing), tbl_cap slots
tbl_cap: .quad 0
groups: .zero VEC_SIZE          # GR
open_key: .quad 0               # owned cstr: the conversation open last, or 0
path: .quad 0                   # owned cstr: the state file, or 0 (no project: memory only)
next_gid: .long 0
loaded: .long 0
filter: .long 0                 # LF_* (agentlist.s)
tries: .long 0                  # restores of the open conversation that did not finish (the breaker, 4.21)
show: .long 0                   # SH_*: sections shown open
.p2align 3
ksb: .zero SB_SIZE              # agst_key's buffer
wsb: .zero SB_SIZE              # the file's text
fsb: .zero SB_SIZE              # a line's fields, unescaped, NUL-terminated each
foff: .zero 8 * FIELDS
fcount: .quad 0

.section .rodata
.Lsuffix: .asciz ".agents-list"
.Lmagic: .asciz "agentlist 1"
.Lw_filter: .asciz "filter"
.Lw_tries: .asciz "tries"
.Lw_show: .asciz "show"
.Lw_open: .asciz "open"
.Lw_group: .asciz "group"
.Lw_s: .asciz "s"
.Ld_loaded: .asciz "loaded="
.Ld_file: .asciz " file="
.Ld_filter: .asciz " filter="
.Ld_show: .asciz " show="
.Ld_tries: .asciz " tries="
.Ld_open: .asciz " open="
.Ld_group: .asciz "group "
.Ld_flags: .asciz " flags="
.Ld_s: .asciz "s "
.Ld_gid: .asciz " group="
.Ld_title: .asciz " title="
.Ldash: .asciz "-"
.text

# FN agst_key(AS*) -> rax ptr, rdx len: its key in a static buffer (valid until the next call), len 0 when
#   it has none yet (a new conversation before its file is named)
FN agst_key
    PROLOGUE
    lea rsi, [rip + ksb]        # p8: its source says (agent_drv.s)
    call agent_src_key
    mov rax, [rip + ksb + SB_ptr]
    mov rdx, [rip + ksb + SB_len]
    EPILOGUE

# find(ptr, len, hash) -> rax EN* or 0, rdx the slot it is in or would go to
find:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rbx, [rip + tbl]
    test rbx, rbx
    jz 8f
    mov r15, [rip + tbl_cap]
    dec r15
    mov rcx, r14
1:  and rcx, r15
    mov rax, [rbx + rcx*8]
    test rax, rax
    jz 7f
    cmp [rax + EN_hash], r14
    jne 2f
    push rcx
    push rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rax + EN_key]
    call str_eq_cstr
    mov ecx, eax
    pop rax
    pop rdx
    test ecx, ecx
    jnz 9f
    mov rcx, rdx
2:  inc rcx
    jmp 1b
7:  lea rdx, [rbx + rcx*8]
    xor eax, eax
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE
9:  lea rdx, [rbx + rdx*8]
    EPILOGUE

# grow(): the table holds twice the entries at least (made at 4096 slots)
grow:
    PROLOGUE
    mov rax, [rip + ents + VEC_len]
    add rax, rax
    cmp rax, [rip + tbl_cap]
    jb 9f
    mov rbx, [rip + tbl_cap]
    test rbx, rbx
    jnz 1f
    mov ebx, 2048
1:  add rbx, rbx
    lea rdi, [rbx*8]
    call mem_alloc
    mov r12, rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [rbx*8]
    call memset
    mov rdi, [rip + tbl]
    call mem_free
    mov [rip + tbl], r12
    mov [rip + tbl_cap], rbx
    dec rbx
    xor r13d, r13d              # every entry in again
2:  cmp r13, [rip + ents + VEC_len]
    jae 9f
    mov rax, [rip + ents + VEC_ptr]
    mov r14, [rax + r13*8]
    mov rcx, [r14 + EN_hash]
3:  and rcx, rbx
    cmp qword ptr [r12 + rcx*8], 0
    je 4f
    inc rcx
    jmp 3b
4:  mov [r12 + rcx*8], r14
    inc r13
    jmp 2b
9:  EPILOGUE

# ent(ptr, len, make) -> rax EN* of that key, made when make and it has none (0 when not)
ent:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r15d, edx
    test r13, r13
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call hash_line
    mov r14, rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call find
    test rax, rax
    jnz 9f
    test r15d, r15d
    jz 8f
    cmp qword ptr [rip + ents + VEC_len], ENTS_MAX
    jae 8f
    mov edi, EN_SIZE
    call mem_alloc
    mov rbx, rax
    mov rdi, rax
    xor esi, esi
    mov edx, EN_SIZE
    call memset
    mov [rbx + EN_hash], r14
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rbx + EN_key], rax
    lea rdi, [rip + ents]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    call grow                   # (a new table puts it in too)
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call find
    test rax, rax
    jnz 1f
    mov [rdx], rbx
1:  mov rax, rbx
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE

# as_ent(AS*, make) -> rax EN* or 0
as_ent:
    PROLOGUE
    mov ebx, esi
    call agst_key
    mov rdi, rax
    mov rsi, rdx
    mov edx, ebx
    call ent
    EPILOGUE

# FN agst_reset(): another project (or none): every mark goes; the next agst_load reads its file
FN agst_reset
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + ents + VEC_len]
    jae 2f
    mov rax, [rip + ents + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov rdi, [r12 + EN_key]
    call mem_free
    mov rdi, [r12 + EN_title]
    call mem_free
    mov rdi, r12
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + ents + VEC_len], 0
    mov rdi, [rip + tbl]
    test rdi, rdi
    jz 3f
    xor esi, esi
    mov rdx, [rip + tbl_cap]
    shl rdx, 3
    call memset
3:  xor ebx, ebx
4:  cmp rbx, [rip + groups + VEC_len]
    jae 5f
    imul rax, rbx, SGR_SIZE
    add rax, [rip + groups + VEC_ptr]
    mov rdi, [rax + SGR_name]
    call mem_free
    inc rbx
    jmp 4b
5:  mov qword ptr [rip + groups + VEC_len], 0
    mov rdi, [rip + open_key]
    call mem_free
    mov qword ptr [rip + open_key], 0
    mov rdi, [rip + path]
    call mem_free
    mov qword ptr [rip + path], 0
    mov dword ptr [rip + next_gid], 0
    mov dword ptr [rip + loaded], 0
    mov dword ptr [rip + filter], 0
    mov dword ptr [rip + show], 0
    mov dword ptr [rip + tries], 0
    inc qword ptr [rip + agst_gen]
    EPILOGUE

# FN agst_load(): the project's file read, once (every reader and writer calls it first; cheap after)
FN agst_load
    cmp dword ptr [rip + loaded], 0
    jne 1f
    jmp load
1:  ret

load:
    PROLOGUE
    mov dword ptr [rip + loaded], 1
    inc qword ptr [rip + agst_gen]
    lea rdi, [rip + .Lsuffix]
    call session_project_file
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov [rip + path], rax
    mov rdi, rax
    call file_read_all
    test rax, rax
    jz 9f
    mov r12, rax                # the text
    mov r13, rdx
    cmp r13, FILE_MAX
    ja 8f
    xor r14d, r14d              # where the line starts
    mov dword ptr [rsp], 0      # (first line seen)
1:  cmp r14, r13
    jae 8f
    mov r15, r14
2:  cmp r15, r13
    jae 3f
    cmp byte ptr [r12 + r15], 10
    je 3f
    inc r15
    jmp 2b
3:  lea rdi, [r12 + r14]
    mov rsi, r15
    sub rsi, r14
    cmp dword ptr [rsp], 0
    jne 4f
    mov dword ptr [rsp], 1
    lea rdx, [rip + .Lmagic]
    call str_eq_cstr
    test eax, eax
    jz 8f                       # not ours: nothing read
    jmp 5f
4:  call line_in
5:  lea r14, [r15 + 1]
    jmp 1b
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# split(ptr, len): the line's tab-separated fields, unescaped, into fsb (foff, fcount)
split:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + fsb]
    call sb_clear
    mov qword ptr [rip + fcount], 0
    xor ebx, ebx
    mov qword ptr [rip + foff], 0
    mov qword ptr [rip + fcount], 1
1:  cmp rbx, r13
    jae 8f
    movzx esi, byte ptr [r12 + rbx]
    inc rbx
    cmp esi, 9
    jne 2f
    lea rdi, [rip + fsb]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + fcount]
    cmp rax, FIELDS
    jae 8f
    lea rcx, [rip + foff]
    mov rdx, [rip + fsb + SB_len]
    mov [rcx + rax*8], rdx
    inc qword ptr [rip + fcount]
    jmp 1b
2:  cmp esi, '\\'
    jne 4f
    cmp rbx, r13
    jae 4f
    movzx esi, byte ptr [r12 + rbx]
    inc rbx
    cmp esi, 't'
    jne 3f
    mov esi, 9
    jmp 4f
3:  cmp esi, 'n'
    jne 4f
    mov esi, 10
4:  cmp esi, 13
    je 1b
    lea rdi, [rip + fsb]
    call sb_push_byte
    jmp 1b
8:  lea rdi, [rip + fsb]
    xor esi, esi
    call sb_push_byte
    EPILOGUE

# field(i) -> rax cstr (i < fcount), rdx its length
field:
    lea rcx, [rip + foff]
    mov rax, [rcx + rdi*8]
    add rax, [rip + fsb + SB_ptr]
    push rax
    mov rdi, rax
    call strlen
    mov rdx, rax
    pop rax
    ret

# num(i) -> rax the field's number
num:
    call field
    mov rdi, rax
    mov rsi, rdx
    jmp parse_u64

# line_in(ptr, len): one line of the file
line_in:
    PROLOGUE
    call split
    xor edi, edi
    call field
    mov r12, rax
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_s]
    call str_eq_cstr
    test eax, eax
    jnz .Lli_s
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_group]
    call str_eq_cstr
    test eax, eax
    jnz .Lli_group
    cmp qword ptr [rip + fcount], 2
    jb 9f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_filter]
    call str_eq_cstr
    test eax, eax
    jz 1f
    mov edi, 1
    call num
    mov [rip + filter], eax
    jmp 9f
1:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_show]
    call str_eq_cstr
    test eax, eax
    jz 2f
    mov edi, 1
    call num
    mov [rip + show], eax
    jmp 9f
2:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_tries]
    call str_eq_cstr
    test eax, eax
    jz 21f
    mov edi, 1
    call num
    mov [rip + tries], eax
    jmp 9f
21: mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_open]
    call str_eq_cstr
    test eax, eax
    jz 9f
    mov edi, 1
    call field
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rdi, [rip + open_key]
    mov [rip + open_key], rax
    call mem_free
9:  EPILOGUE
.Lli_group:                     # group ID FLAGS NAME
    cmp qword ptr [rip + fcount], 4
    jb 9b
    cmp qword ptr [rip + groups + VEC_len], GROUPS_MAX
    jae 9b
    mov edi, 1
    call num
    test eax, eax
    jz 9b
    mov rbx, rax
    lea rdi, [rip + groups]
    mov esi, SGR_SIZE
    call vec_push
    mov r14, rax
    mov [r14 + SGR_id], ebx
    cmp ebx, [rip + next_gid]
    jb 3f
    mov [rip + next_gid], ebx
3:  mov edi, 2
    call num
    mov [r14 + SGR_flags], eax
    mov edi, 3
    call field
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [r14 + SGR_name], rax
    jmp 9b
.Lli_s:                         # s KEY GID FLAGS TITLE
    cmp qword ptr [rip + fcount], 5
    jb 9b
    mov edi, 1
    call field
    mov rdi, rax
    mov rsi, rdx
    mov edx, 1
    call ent
    test rax, rax
    jz 9b
    mov r14, rax
    mov edi, 2
    call num
    mov [r14 + EN_gid], eax
    mov edi, 3
    call num
    and eax, SF_ALL
    mov [r14 + EN_flags], eax
    mov edi, 4
    call field
    test rdx, rdx
    jz 9b
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rdi, [r14 + EN_title]
    mov [r14 + EN_title], rax
    call mem_free
    jmp 9b

# put_esc(cstr): wsb gets it with its tab, line end and backslash escaped
put_esc:
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
1:  movzx esi, byte ptr [rbx]
    test esi, esi
    jz 9f
    inc rbx
    cmp esi, 9
    jne 2f
    lea rdi, [rip + wsb]
    mov esi, '\\'
    call sb_push_byte
    mov esi, 't'
    jmp 4f
2:  cmp esi, 10
    jne 3f
    lea rdi, [rip + wsb]
    mov esi, '\\'
    call sb_push_byte
    mov esi, 'n'
    jmp 4f
3:  cmp esi, '\\'
    jne 4f
    lea rdi, [rip + wsb]
    call sb_push_byte
    mov esi, '\\'
4:  lea rdi, [rip + wsb]
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# put_tab(), put_num(n), put_cstr(cstr), put_lf()
put_tab:
    lea rdi, [rip + wsb]
    mov esi, 9
    jmp sb_push_byte
put_lf:
    lea rdi, [rip + wsb]
    mov esi, 10
    jmp sb_push_byte
put_num:
    mov rsi, rdi
    lea rdi, [rip + wsb]
    jmp sb_push_u64
put_cstr:
    mov rsi, rdi
    lea rdi, [rip + wsb]
    jmp sb_push_cstr

# save(): the whole state into the file (memory only without one); the list is made again
save:
    PROLOGUE
    inc qword ptr [rip + agst_gen]
    mov dword ptr [rip + g_dirty], 1
    cmp qword ptr [rip + path], 0
    je 9f
    lea rdi, [rip + wsb]
    call sb_clear
    lea rdi, [rip + .Lmagic]
    call put_cstr
    call put_lf
    lea rdi, [rip + .Lw_filter]
    call put_cstr
    call put_tab
    mov edi, [rip + filter]
    call put_num
    call put_lf
    lea rdi, [rip + .Lw_show]
    call put_cstr
    call put_tab
    mov edi, [rip + show]
    call put_num
    call put_lf
    lea rdi, [rip + .Lw_tries]
    call put_cstr
    call put_tab
    mov edi, [rip + tries]
    call put_num
    call put_lf
    mov rbx, [rip + open_key]
    test rbx, rbx
    jz 1f
    lea rdi, [rip + .Lw_open]
    call put_cstr
    call put_tab
    mov rdi, rbx
    call put_esc
    call put_lf
1:  xor ebx, ebx
2:  cmp rbx, [rip + groups + VEC_len]
    jae 3f
    imul r12, rbx, SGR_SIZE
    add r12, [rip + groups + VEC_ptr]
    lea rdi, [rip + .Lw_group]
    call put_cstr
    call put_tab
    mov edi, [r12 + SGR_id]
    call put_num
    call put_tab
    mov edi, [r12 + SGR_flags]
    call put_num
    call put_tab
    mov rdi, [r12 + SGR_name]
    call put_esc
    call put_lf
    inc rbx
    jmp 2b
3:  xor ebx, ebx
4:  cmp rbx, [rip + ents + VEC_len]
    jae 6f
    mov rax, [rip + ents + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    cmp dword ptr [r12 + EN_flags], 0      # an entry with nothing left is not written
    jne 5f
    cmp dword ptr [r12 + EN_gid], 0
    jne 5f
    cmp qword ptr [r12 + EN_title], 0
    je 4b
5:  lea rdi, [rip + .Lw_s]
    call put_cstr
    call put_tab
    mov rdi, [r12 + EN_key]
    call put_esc
    call put_tab
    mov edi, [r12 + EN_gid]
    call put_num
    call put_tab
    mov edi, [r12 + EN_flags]
    call put_num
    call put_tab
    mov rdi, [r12 + EN_title]
    call put_esc
    call put_lf
    jmp 4b
6:  mov rdi, [rip + path]
    mov rsi, [rip + wsb + SB_ptr]
    mov rdx, [rip + wsb + SB_len]
    call file_write_all
9:  EPILOGUE

# FN agst_of(AS*) -> eax its flags (SF_*), edx its group's id (0 none)
FN agst_of
    PROLOGUE
    mov rbx, rdi
    call agst_load
    mov rdi, rbx
    xor esi, esi
    call as_ent
    xor ecx, ecx
    xor edx, edx
    test rax, rax
    jz 1f
    mov ecx, [rax + EN_flags]
    mov edx, [rax + EN_gid]
    test edx, edx               # a group that went: none
    jz 1f
    push rcx
    push rdx
    mov edi, edx
    call agst_group
    pop rdx
    pop rcx
    test rax, rax
    jnz 1f
    xor edx, edx
1:  mov eax, ecx
    EPILOGUE

# FN agst_mark(AS*, set, clear): its flags: set on, then clear off; saved when they changed
FN agst_mark
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    call agst_load
    mov rdi, rbx
    mov esi, 1
    call as_ent
    test rax, rax
    jz 9f
    mov ecx, [rax + EN_flags]
    mov edx, ecx
    or edx, r12d
    not r13d
    and edx, r13d
    cmp edx, ecx
    je 9f
    mov [rax + EN_flags], edx
    call save
9:  EPILOGUE

# FN agst_put_group(AS*, gid): its group (0 none), saved when it changed
FN agst_put_group
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call agst_load
    mov rdi, rbx
    mov esi, 1
    call as_ent
    test rax, rax
    jz 9f
    cmp [rax + EN_gid], r12d
    je 9f
    mov [rax + EN_gid], r12d
    call save
9:  EPILOGUE

# FN agst_title(AS*) -> rax rhun's own title for it (cstr), or 0
FN agst_title
    PROLOGUE
    mov rbx, rdi
    call agst_load
    mov rdi, rbx
    xor esi, esi
    call as_ent
    test rax, rax
    jz 9f
    mov rax, [rax + EN_title]
9:  EPILOGUE

# FN agst_set_title(AS*, ptr, len): rhun's own title for it (len 0: none), saved
FN agst_set_title
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call agst_load
    mov rdi, rbx
    mov esi, 1
    call as_ent
    test rax, rax
    jz 9f
    mov r14, rax
    mov rdi, [r14 + EN_title]
    call mem_free
    mov qword ptr [r14 + EN_title], 0
    test r13, r13
    jz 1f
    cmp r13, NAME_MAX
    jbe 2f
    mov r13d, NAME_MAX
2:  mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [r14 + EN_title], rax
1:  call save
9:  EPILOGUE

# FN agst_groups() -> rax the groups' VEC (GR records, in their order)
FN agst_groups
    push rbx
    call agst_load
    lea rax, [rip + groups]
    pop rbx
    ret

# FN agst_group(id) -> rax its GR, or 0
FN agst_group
    xor eax, eax
    test edi, edi
    jz 9f
    xor ecx, ecx
1:  cmp rcx, [rip + groups + VEC_len]
    jae 8f
    imul rax, rcx, SGR_SIZE
    add rax, [rip + groups + VEC_ptr]
    cmp [rax + SGR_id], edi
    je 9f
    inc rcx
    jmp 1b
8:  xor eax, eax
9:  ret

# FN agst_group_new(ptr, len) -> rax the new group (GR*), last in the order; 0 when there are too many
FN agst_group_new
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call agst_load
    xor eax, eax
    cmp qword ptr [rip + groups + VEC_len], GROUPS_MAX
    jae 9f
    cmp r13, NAME_MAX
    jbe 1f
    mov r13d, NAME_MAX
1:  lea rdi, [rip + groups]
    mov esi, SGR_SIZE
    call vec_push
    mov rbx, rax
    inc dword ptr [rip + next_gid]
    mov eax, [rip + next_gid]
    mov [rbx + SGR_id], eax
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rbx + SGR_name], rax
    call save
    mov rax, rbx
9:  EPILOGUE

# FN agst_group_rename(id, ptr, len): its name (an empty one is not taken), saved
FN agst_group_rename
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    call agst_group
    test rax, rax
    jz 9f
    test r13, r13
    jz 9f
    mov rbx, rax
    cmp r13, NAME_MAX
    jbe 1f
    mov r13d, NAME_MAX
1:  mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov rdi, [rbx + SGR_name]
    mov [rbx + SGR_name], rax
    call mem_free
    call save
9:  EPILOGUE

# FN agst_group_delete(id): the group goes; its sessions are ungrouped (their entries keep the id of a group
#   that no longer is: agst_of reads it as none, and the next save drops it)
FN agst_group_delete
    PROLOGUE
    mov ebx, edi
    call agst_group
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, [r12 + SGR_name]
    call mem_free
    mov rdi, r12                # the rest move down one
    lea rsi, [r12 + SGR_SIZE]
    mov rdx, [rip + groups + VEC_len]
    imul rdx, rdx, SGR_SIZE
    add rdx, [rip + groups + VEC_ptr]
    sub rdx, rsi
    call memmove
    dec qword ptr [rip + groups + VEC_len]
    xor ecx, ecx
1:  cmp rcx, [rip + ents + VEC_len]
    jae 2f
    mov rax, [rip + ents + VEC_ptr]
    mov rax, [rax + rcx*8]
    cmp [rax + EN_gid], ebx
    jne 11f
    mov dword ptr [rax + EN_gid], 0
11: inc rcx
    jmp 1b
2:  call save
9:  EPILOGUE

# FN agst_group_flip(id): the group collapsed, or open again; saved
FN agst_group_flip
    PROLOGUE
    call agst_group
    test rax, rax
    jz 9f
    xor dword ptr [rax + SGR_flags], SGRF_COLLAPSED
    call save
9:  EPILOGUE

# FN agst_filter() -> eax the status filter (LF_*); agst_set_filter(mask), saved
FN agst_filter
    push rbx
    call agst_load
    mov eax, [rip + filter]
    pop rbx
    ret
FN agst_set_filter
    PROLOGUE
    mov ebx, edi
    call agst_load
    cmp [rip + filter], ebx
    je 9f
    mov [rip + filter], ebx
    call save
9:  EPILOGUE

# FN agst_show() -> eax the sections shown open (SH_*); agst_set_show(bits), saved
FN agst_show
    push rbx
    call agst_load
    mov eax, [rip + show]
    pop rbx
    ret
FN agst_set_show
    PROLOGUE
    mov ebx, edi
    call agst_load
    cmp [rip + show], ebx
    je 9f
    mov [rip + show], ebx
    call save
9:  EPILOGUE

# FN agst_open() -> rax the key of the conversation open last (cstr), or 0
FN agst_open
    push rbx
    call agst_load
    mov rax, [rip + open_key]
    pop rbx
    ret

# FN agst_tries() -> eax the restores of the open conversation that did not finish; agst_set_tries(n), saved
FN agst_tries
    push rbx
    call agst_load
    mov eax, [rip + tries]
    pop rbx
    ret
FN agst_set_tries
    PROLOGUE
    mov ebx, edi
    call agst_load
    cmp [rip + tries], ebx
    je 9f
    mov [rip + tries], ebx
    call save
9:  EPILOGUE

# FN agst_set_open(AS* or 0): the conversation open now (0: the list), saved when it changed
FN agst_set_open
    PROLOGUE
    mov rbx, rdi
    call agst_load
    xor r12d, r12d
    xor r13d, r13d
    test rbx, rbx
    jz 1f
    mov rdi, rbx
    call agst_key
    mov r12, rax
    mov r13, rdx
1:  mov rdi, [rip + open_key]
    test r13, r13
    jnz 2f
    test rdi, rdi               # none, and none before
    jz 9f
    call mem_free
    mov qword ptr [rip + open_key], 0
    jmp 8f
2:  test rdi, rdi
    jz 3f
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rip + open_key]
    call str_eq_cstr
    test eax, eax
    jnz 9f
3:  mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov rdi, [rip + open_key]
    mov [rip + open_key], rax
    call mem_free
8:  call save
9:  EPILOGUE

# FN agst_dump(sb): "loaded=0|1 file=0|1 filter=N show=N tries=N open=KEY|-", a line per group "group ID NAME
#   flags=N", a line per session with a mark "s KEY group=N flags=N title=T|-" (print-agent-list-state)
FN agst_dump
    PROLOGUE
    mov r15, rdi
    call agst_load
    mov rdi, r15
    lea rsi, [rip + .Ld_loaded]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rip + loaded]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_file]
    call sb_push_cstr
    xor esi, esi
    cmp qword ptr [rip + path], 0
    setne sil
    mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_filter]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rip + filter]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_show]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rip + show]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_tries]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rip + tries]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_open]
    call sb_push_cstr
    mov rsi, [rip + open_key]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Ldash]
1:  mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    xor ebx, ebx
2:  cmp rbx, [rip + groups + VEC_len]
    jae 3f
    imul r12, rbx, SGR_SIZE
    add r12, [rip + groups + VEC_ptr]
    mov rdi, r15
    lea rsi, [rip + .Ld_group]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [r12 + SGR_id]
    call sb_push_u64
    mov rdi, r15
    mov esi, ' '
    call sb_push_byte
    mov rdi, r15
    mov rsi, [r12 + SGR_name]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_flags]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [r12 + SGR_flags]
    call sb_push_u64
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 2b
3:  xor ebx, ebx
4:  cmp rbx, [rip + ents + VEC_len]
    jae 9f
    mov rax, [rip + ents + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    mov edi, [r12 + EN_gid]     # what agst_of says: a group that went is none
    call agst_group
    xor r13d, r13d
    test rax, rax
    jz 41f
    mov r13d, [r12 + EN_gid]
41: cmp dword ptr [r12 + EN_flags], 0
    jne 5f
    test r13d, r13d
    jnz 5f
    cmp qword ptr [r12 + EN_title], 0
    je 4b
5:  mov rdi, r15
    lea rsi, [rip + .Ld_s]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [r12 + EN_key]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_gid]
    call sb_push_cstr
    mov rdi, r15
    mov esi, r13d
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_flags]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [r12 + EN_flags]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_title]
    call sb_push_cstr
    mov rsi, [r12 + EN_title]
    test rsi, rsi
    jnz 6f
    lea rsi, [rip + .Ldash]
6:  mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    jmp 4b
9:  EPILOGUE
