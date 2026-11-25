# a driver's lists and the project's own choices, per driver kind and project (AGC, rhun.inc): the models
# with their levels and flags, the commands, the program's version and fast-mode state, the project's
# model, effort, Ultracode and thinking, the last permission destination, the user's last picked default
# mode, each conversation's mode. A driver fills the lists from what its program reports; the pickers and
# the menu read them before any program runs.
#
# They are kept in rhun's state file, one per project and driver kind: session_project_file(".agents-" +
# the kind's word), its path resolved and stored when the record is made (a project change flushes every
# record to its own file before the new project's are made). Without a project there is no file: the
# record lives in memory only (AGCF_NOFILE). The file is read only when a writer needs the record
# (agentcfg_need: a start, a popup opened, a key in the box), never for a reader; it is written only when
# something in it changed (agentcfg_save), whole, through a temporary file and a rename (file_write_all).
#
# Lines, fields separated by a tab (a tab, a line end and a backslash escaped as \t \n \\), at most 1 MiB:
#   agentcfg 1 | version V | model VALUE LABEL DESC FLAGS ID:LABEL,ID:LABEL... [RESOLVED] |
#   cmd NAME DESC HINT ALIASES ORIGIN ACT FLAGS | project MODEL EFFORT ULTRA THINK | fast STATE REASON |
#   dest D | newmode M | conv SID MODE (at most 1000, the oldest dropped)
# A number -1 is written "-". Unknown lines are skipped; a file that does not start with "agentcfg 1" is
# not read.
#
#   agentcfg_get(kind) -> rax AGC* (made empty on first use with its path; reads nothing)
#   agentcfg_need(AGC*)                     the state file read once (AGCF_READ)
#   agentcfg_lists_begin(AGC*, mask AGL_*), agentcfg_model(AGC*, value, label, desc cstrs, flags) -> rax
#     AMO* or 0, agentcfg_level(AMO*, id, label cstrs), agentcfg_cmd(AGC*, name ptr, len, desc ptr, len,
#     hint ptr, [stack] hint len, aliases cstr|0, origin cstr|0, act, flags) -> rax ACM* or 0,
#     agentcfg_lists_end(AGC*) -> eax 1 when they differ from the ones replaced (then dirty)
#   agentcfg_find_model(AGC*, ptr, len) -> rax AMO* or 0; agentcfg_find_cmd(AGC*, ptr, len) -> rax ACM*
#     or 0 (its name or an alias); agentcfg_resolved(AMO*, id) the id the program reports for a model;
#     agentcfg_model_of(AGC*, ptr, len) -> rax the model of that value or reported id, or 0
#   agentcfg_current(AS* or 0, AGC*) -> rax AMO* or 0, rdx its name: the model a conversation uses (the
#     footer's pill, the picker's check); agentcfg_effort(AS* or 0, AGC*, AMO*) -> rax AEL* or 0: the
#     level in effect
#   agentcfg_conv(AGC*, sid cstr) -> rax ACH* (made; valid until the next agentcfg_conv); agentcfg_dirty
#     (AGC*) after changing an ACH_mode; agentcfg_conv_mode(AGC*, sid cstr) -> rax its mode or 0 (makes none)
#   agentcfg_set(AGC*, field AGF_*, ptr, len) (an int field takes its value in rdx): dirty when it changed
#   agentcfg_save(AGC*) when dirty, to its stored path; agentcfg_flush() (quit, project change: every
#     record saved and freed)
#   agentcfg_dump(sb, AGC*)                 print-agent-cfg
.include "rhun.inc"

.equ FILE_MAX, 1 << 20          # the state file's bytes at most
.equ MODELS_MAX, 64             # a list past these is cut
.equ LEVELS_MAX, 16
.equ CMDS_MAX, 1000
.equ CONVS_MAX, 1000
.equ FIELDS_MAX, 8              # a line's fields
.equ VALUE_MAX, 63              # AL_model's room
.equ LEVEL_MAX, 15              # AL_effort's room
.equ LABEL_MAX, 200
.equ DESC_MAX, 500
.equ HINT_MAX, 200
.equ NAME_MAX, 100

.bss
.p2align 3
agcs: .zero VEC_SIZE            # AGC*: every record
wsb: .zero SB_SIZE              # the file's text
csb1: .zero SB_SIZE             # two lists as text, to compare
csb2: .zero SB_SIZE
fsb: .zero SB_SIZE              # a line's fields, unescaped, each NUL-terminated
nsb: .zero SB_SIZE              # a name, the suffix
foff: .zero 8 * FIELDS_MAX      # where each field starts in fsb
fcount: .quad 0
.globl g_agentcfg_gen
g_agentcfg_gen: .quad 0         # counts every change of a record's lists or choices (agentpop's rows follow it)

.text

# FN agentcfg_get(kind) -> rax the record of that driver kind for the current project, made empty on
#   first use with its state file's path (none without a project: AGCF_NOFILE). Reads nothing
FN agentcfg_get
    PROLOGUE
    mov ebx, edi
    xor r12d, r12d
1:  cmp r12, [rip + agcs + VEC_len]
    jae 2f
    mov rax, [rip + agcs + VEC_ptr]
    mov rax, [rax + r12*8]
    cmp [rax + AGC_kind], ebx
    je 9f
    inc r12
    jmp 1b
2:  mov edi, AGC_SIZE
    call mem_alloc
    mov r12, rax
    mov [r12 + AGC_kind], ebx
    mov dword ptr [r12 + AGC_ultra], -1
    mov dword ptr [r12 + AGC_think], -1
    lea rdi, [rip + nsb]
    call sb_clear
    lea rdi, [rip + nsb]
    lea rsi, [rip + .Lsuffix]
    call sb_push_cstr
    mov edi, ebx
    call agent_kind_name
    lea rdi, [rip + nsb]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + nsb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + nsb + SB_ptr]
    call session_project_file
    test rax, rax
    jz 3f
    mov r13, rax
    mov rdi, rax
    call strlen
    mov rdi, r13
    mov rsi, rax
    call mem_dup
    mov [r12 + AGC_path], rax
    jmp 4f
3:  or dword ptr [r12 + AGC_flags], AGCF_NOFILE
4:  lea rdi, [rip + agcs]
    mov esi, 8
    call vec_push
    mov [rax], r12
    mov rax, r12
9:  EPILOGUE

# FN agentcfg_need(AGC*): the state file is read, once (every writer's action calls it first)
FN agentcfg_need
    PROLOGUE
    mov rbx, rdi
    test dword ptr [rbx + AGC_flags], AGCF_READ
    jnz 9f
    or dword ptr [rbx + AGC_flags], AGCF_READ
    test dword ptr [rbx + AGC_flags], AGCF_NOFILE
    jnz 9f
    mov rdi, [rbx + AGC_path]
    mov esi, FILE_MAX
    call file_read_limited
    test rax, rax
    jz 9f
    mov r12, rax
    mov r13d, [rbx + AGC_flags]  # what the file holds is not a change
    mov rdi, rbx
    mov rsi, rax
    call parse_file
    and dword ptr [rbx + AGC_flags], ~AGCF_DIRTY
    and r13d, AGCF_DIRTY
    or [rbx + AGC_flags], r13d
    mov rdi, r12
    call mem_free
9:  EPILOGUE

# parse_file(AGC*, buf NUL-terminated, rdx len): the file's lines into the record
parse_file:
    PROLOGUE
    mov rbx, rdi
    mov r13, rsi
    lea r14, [rsi + rdx]
    xor r15d, r15d              # the first line was seen
1:  cmp r13, r14
    jae 9f
    mov rcx, r13
2:  cmp rcx, r14
    jae 3f
    cmp byte ptr [rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  lea r12, [rcx + 1]          # the next line
    mov rdi, r13
    mov rsi, rcx
    sub rsi, r13
    call split_line
    mov r13, r12
    test r15d, r15d
    jnz 4f
    mov r15d, 1                 # "agentcfg 1" first, else the file is not ours
    xor edi, edi
    call fld
    mov rdi, rax
    lea rsi, [rip + .Lw_agentcfg]
    call strcmp_eq
    test eax, eax
    jz 9f
    mov edi, 1
    call fld
    mov rdi, rax
    lea rsi, [rip + .Lw_one]
    call strcmp_eq
    test eax, eax
    jz 9f
    jmp 1b
4:  xor edi, edi
    call fld
    mov r12, rax
    lea r15, [rip + line_kinds]
5:  mov rsi, [r15]
    test rsi, rsi
    jz 6f
    mov rdi, r12
    call strcmp_eq
    test eax, eax
    jnz 7f
    add r15, 16
    jmp 5b
7:  mov rdi, rbx
    call [r15 + 8]
6:  mov r15d, 1
    jmp 1b
9:  EPILOGUE

# split_line(ptr, len): its tab-separated fields, unescaped, into fsb (foff, fcount)
split_line:
    PROLOGUE
    mov r12, rdi
    lea r13, [rdi + rsi]
    lea rdi, [rip + fsb]
    call sb_clear
    mov qword ptr [rip + foff], 0
    mov qword ptr [rip + fcount], 1
1:  cmp r12, r13
    jae 8f
    movzx esi, byte ptr [r12]
    inc r12
    cmp esi, 9
    jne 2f
    lea rdi, [rip + fsb]
    xor esi, esi
    call sb_push_byte
    mov rcx, [rip + fcount]
    cmp rcx, FIELDS_MAX
    jae 1b                      # past the last field: the rest is left out
    mov rax, [rip + fsb + SB_len]
    lea rdx, [rip + foff]
    mov [rdx + rcx*8], rax
    inc qword ptr [rip + fcount]
    jmp 1b
2:  cmp esi, 13
    je 1b
    cmp esi, 92
    jne 4f
    cmp r12, r13
    jae 4f
    movzx eax, byte ptr [r12]
    cmp eax, 't'
    jne 21f
    mov esi, 9
    inc r12
    jmp 4f
21: cmp eax, 'n'
    jne 22f
    mov esi, 10
    inc r12
    jmp 4f
22: cmp eax, 92
    jne 4f
    inc r12
4:  lea rdi, [rip + fsb]
    call sb_push_byte
    jmp 1b
8:  lea rdi, [rip + fsb]
    xor esi, esi
    call sb_push_byte
    EPILOGUE

# fld(i) -> rax field i of the line split last, "" past its fields
fld:
    lea rax, [rip + .Lempty]
    cmp rdi, [rip + fcount]
    jae 1f
    lea rax, [rip + foff]
    mov rax, [rax + rdi*8]
    add rax, [rip + fsb + SB_ptr]
1:  ret

# fld_num(i) -> rax field i as a number: "-" is -1
fld_num:
    PROLOGUE
    call fld
    mov rbx, rax
    mov rax, -1
    cmp byte ptr [rbx], '-'
    je 9f
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call parse_u64
9:  EPILOGUE

# fld_into(i, dst, cap): field i copied into a fixed cstr field of cap bytes (cut at a character)
fld_into:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    call fld
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov rdi, r12
    mov rsi, rbx
    mov rdx, rax
    mov rcx, r13
    call set_fixed
    EPILOGUE

# set_fixed(dst, ptr, len, cap) -> eax 1 when dst changed: ptr/len into a cstr field of cap bytes, cut
#   at a character's start
set_fixed:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdx, [rcx - 1]
    test r12, r12
    jnz 1f
    xor r13d, r13d
1:  mov rdi, r13
    mov rsi, r12
    call utf8_cut
    mov r13, rax
    mov rdi, rbx
    call strlen
    cmp rax, r13
    jne 2f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jz 2f
    xor eax, eax
    EPILOGUE
2:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call memmove
    mov byte ptr [rbx + r13], 0
    mov eax, 1
    EPILOGUE

# cut_dup(ptr, len, max) -> rax an owned cstr of at most max bytes, cut at a character ("" for ptr 0)
cut_dup:
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jnz 1f
    xor esi, esi
1:  mov rdi, rsi
    mov rsi, rbx
    call utf8_cut
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    EPILOGUE

# cut_dupz(cstr or 0, max) -> rax an owned copy, cut
cut_dupz:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor eax, eax
    test rdi, rdi
    jz 1f
    call strlen
1:  mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    call cut_dup
    EPILOGUE

# cut_dup0(cstr or 0, max) -> rax an owned copy, or 0 when it is empty
cut_dup0:
    xor eax, eax
    test rdi, rdi
    jz 1f
    cmp byte ptr [rdi], 0
    je 1f
    jmp cut_dupz
1:  ret

# ---- the file's lines ----

# l_version(AGC*)
l_version:
    lea rsi, [rdi + AGC_version]
    mov edi, 1
    mov edx, 24
    jmp fld_into

# l_model(AGC*): model VALUE LABEL DESC FLAGS LEVELS
l_model:
    PROLOGUE
    mov rbx, rdi
    mov edi, 1
    call fld
    mov r12, rax
    mov edi, 2
    call fld
    mov r13, rax
    mov edi, 3
    call fld
    mov r14, rax
    mov edi, 4
    call fld_num
    mov r8d, eax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call agentcfg_model
    test rax, rax
    jz 9f
    mov rbx, rax
    mov edi, 6                  # RESOLVED (later files only)
    call fld
    mov rdi, rbx
    mov rsi, rax
    call agentcfg_resolved
    mov edi, 5                  # ID:LABEL,ID:LABEL
    call fld
    mov r12, rax
1:  cmp byte ptr [r12], 0
    je 9f
    mov r13, r12                # a level's start, then its ':' and its end
2:  movzx eax, byte ptr [r12]
    test eax, eax
    jz 3f
    cmp eax, ','
    je 3f
    inc r12
    jmp 2b
3:  mov r14, r13
4:  cmp r14, r12
    jae 6f
    cmp byte ptr [r14], ':'
    je 5f
    inc r14
    jmp 4b
5:  mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    sub rdx, r13
    lea rcx, [r14 + 1]
    mov r8, r12
    sub r8, rcx
    call level_add
6:  cmp byte ptr [r12], 0
    je 9f
    inc r12
    jmp 1b
9:  EPILOGUE

# l_cmd(AGC*): cmd NAME DESC HINT ALIASES ORIGIN ACT FLAGS
l_cmd:
    PROLOGUE 64
    mov rbx, rdi
    mov edi, 1
    call fld
    mov [rsp + 48], rax
    mov edi, 2
    call fld
    mov r12, rax
    mov edi, 3
    call fld
    mov r13, rax
    mov edi, 4
    call fld
    mov [rsp + 8], rax          # aliases
    mov edi, 5
    call fld
    mov [rsp + 16], rax         # origin
    mov edi, 6
    call fld_num
    cmp rax, ACT_COUNT
    jb 1f
    xor eax, eax
1:  mov [rsp + 24], rax
    mov edi, 7
    call fld_num
    and eax, ACMF_LOCAL | ACMF_CLI
    mov [rsp + 32], rax
    mov rdi, r13
    call strlen
    mov [rsp], rax              # hint len
    mov rdi, r12
    call strlen
    mov r14, rax
    mov rdi, [rsp + 48]
    call strlen
    mov rdx, rax
    mov rdi, rbx
    mov rsi, [rsp + 48]
    mov rcx, r12
    mov r8, r14
    mov r9, r13
    call agentcfg_cmd
    EPILOGUE

# l_project(AGC*): project MODEL EFFORT ULTRA THINK
l_project:
    PROLOGUE
    mov rbx, rdi
    mov edi, 1
    lea rsi, [rbx + AGC_model]
    mov edx, 64
    call fld_into
    mov edi, 2
    lea rsi, [rbx + AGC_effort]
    mov edx, 16
    call fld_into
    mov edi, 3
    call fld_num
    call tri
    mov [rbx + AGC_ultra], eax
    mov edi, 4
    call fld_num
    call tri
    mov [rbx + AGC_think], eax
    EPILOGUE

# tri(rax) -> eax -1, 0 or 1 (anything else -1)
tri:
    cmp rax, 1
    jbe 1f
    mov eax, -1
1:  ret

# l_fast(AGC*): fast STATE REASON
l_fast:
    PROLOGUE
    mov rbx, rdi
    mov edi, 1
    call fld_num
    cmp rax, FS_COOLDOWN
    jbe 1f
    xor eax, eax
1:  mov [rbx + AGC_fast], eax
    mov edi, 2
    lea rsi, [rbx + AGC_fastwhy]
    mov edx, 32
    call fld_into
    EPILOGUE

# l_dest(AGC*), l_newmode(AGC*)
l_dest:
    lea rsi, [rdi + AGC_dest]
    mov edi, 1
    mov edx, 24
    jmp fld_into
l_newmode:
    lea rsi, [rdi + AGC_newmode]
    mov edi, 1
    mov edx, 32
    jmp fld_into

# l_conv(AGC*): conv SID MODE
l_conv:
    PROLOGUE
    mov rbx, rdi
    mov edi, 1
    call fld
    cmp byte ptr [rax], 0
    je 9f
    mov rdi, rbx
    mov rsi, rax
    call conv_find
    mov r12, rax
    mov edi, 2
    lea rsi, [r12 + ACH_mode]
    mov edx, 32
    call fld_into
9:  EPILOGUE

# ---- the lists ----

# FN agentcfg_lists_begin(AGC*, mask AGL_*): the lists named are replaced by the ones added until
#   agentcfg_lists_end (the others stay)
FN agentcfg_lists_begin
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call agentcfg_need
    lea rdi, [rbx + AGC_omodels]  # a begin without its end: what it set aside goes
    call models_free
    lea rdi, [rbx + AGC_ocmds]
    call cmds_free
    mov [rbx + AGC_lmask], r12d
    test r12d, AGL_MODELS
    jz 1f
    lea rdi, [rbx + AGC_omodels]
    lea rsi, [rbx + AGC_models]
    call vec_move
1:  test r12d, AGL_CMDS
    jz 9f
    lea rdi, [rbx + AGC_ocmds]
    lea rsi, [rbx + AGC_cmds]
    call vec_move
9:  EPILOGUE

# vec_move(dst VEC*, src VEC*): src's array becomes dst's, src is empty
vec_move:
    mov rax, [rsi + VEC_ptr]
    mov [rdi + VEC_ptr], rax
    mov rax, [rsi + VEC_len]
    mov [rdi + VEC_len], rax
    mov rax, [rsi + VEC_cap]
    mov [rdi + VEC_cap], rax
    xor eax, eax
    mov [rsi + VEC_ptr], rax
    mov [rsi + VEC_len], rax
    mov [rsi + VEC_cap], rax
    ret

# FN agentcfg_lists_end(AGC*) -> eax 1 when the new lists differ from the ones they replaced (the record
#   is then dirty)
FN agentcfg_lists_end
    PROLOGUE
    mov rbx, rdi
    xor r13d, r13d
    mov r12d, [rbx + AGC_lmask]
    test r12d, AGL_MODELS
    jz 1f
    lea rdi, [rip + csb1]
    call sb_clear
    lea rdi, [rip + csb2]
    call sb_clear
    lea rdi, [rip + csb1]
    lea rsi, [rbx + AGC_omodels]
    mov edx, -1
    call models_text
    lea rdi, [rip + csb2]
    lea rsi, [rbx + AGC_models]
    mov edx, -1
    call models_text
    call csb_differ
    or r13d, eax
1:  test r12d, AGL_CMDS
    jz 2f
    lea rdi, [rip + csb1]
    call sb_clear
    lea rdi, [rip + csb2]
    call sb_clear
    lea rdi, [rip + csb1]
    lea rsi, [rbx + AGC_ocmds]
    mov edx, -1
    call cmds_text
    lea rdi, [rip + csb2]
    lea rsi, [rbx + AGC_cmds]
    mov edx, -1
    call cmds_text
    call csb_differ
    or r13d, eax
2:  lea rdi, [rbx + AGC_omodels]
    call models_free
    lea rdi, [rbx + AGC_ocmds]
    call cmds_free
    mov dword ptr [rbx + AGC_lmask], 0
    test r13d, r13d
    jz 9f
    or dword ptr [rbx + AGC_flags], AGCF_DIRTY
9:  mov eax, r13d
    EPILOGUE

# csb_differ() -> eax 1 when csb1 and csb2 hold different text
csb_differ:
    PROLOGUE
    mov eax, 1
    mov rdx, [rip + csb1 + SB_len]
    cmp rdx, [rip + csb2 + SB_len]
    jne 9f
    xor eax, eax
    test rdx, rdx
    jz 9f
    mov rdi, [rip + csb1 + SB_ptr]
    mov rsi, [rip + csb2 + SB_ptr]
    call memeq
    xor eax, 1
9:  EPILOGUE

# FN agentcfg_model(AGC*, value, label, desc cstrs, flags) -> rax the model added, or 0 (no value, one of
#   that value already, the list is full)
FN agentcfg_model
    inc qword ptr [rip + g_agentcfg_gen]
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15d, r8d
    test r12, r12
    jz 8f
    cmp byte ptr [r12], 0
    je 8f
    cmp qword ptr [rbx + AGC_models + VEC_len], MODELS_MAX
    jae 8f
    mov rdi, r12
    call strlen
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call agentcfg_find_model
    test rax, rax
    jnz 8f
    mov edi, AMO_SIZE
    call mem_alloc
    xchg rbx, rax               # rbx the model, rax the record
    push rax
    push rax
    lea rdi, [rax + AGC_models]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    pop rax
    pop rax
    and r15d, AMOF_OFF | AMOF_THINKOFF | AMOF_AUTO | AMOF_FAST | AMOF_EFFORT
    mov [rbx + AMO_flags], r15d
    mov rdi, r12
    mov esi, VALUE_MAX
    call cut_dupz
    mov [rbx + AMO_value], rax
    mov rdi, r13
    mov esi, LABEL_MAX
    call cut_dupz
    mov [rbx + AMO_label], rax
    mov rdi, r14
    mov esi, DESC_MAX
    call cut_dupz
    mov [rbx + AMO_desc], rax
    mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentcfg_resolved(AMO* or 0, id cstr or 0): the id the program reports for the model (its
#   resolvedModel), kept beside its value
FN agentcfg_resolved
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    mov rdi, rsi
    mov esi, VALUE_MAX          # cut as a value is (AL_model's room)
    call cut_dup0
    mov r12, rax
    mov rdi, [rbx + AMO_resolved]
    call mem_free
    mov [rbx + AMO_resolved], r12
9:  EPILOGUE

# FN agentcfg_model_of(AGC*, ptr, len) -> rax the model whose value or reported id that is (the first
#   listed), or 0
FN agentcfg_model_of
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call agentcfg_find_model
    test rax, rax
    jnz 9f
    xor r14d, r14d
1:  cmp r14, [rbx + AGC_models + VEC_len]
    jae 8f
    mov rax, [rbx + AGC_models + VEC_ptr]
    mov r15, [rax + r14*8]
    inc r14
    mov rdx, [r15 + AMO_resolved]
    test rdx, rdx
    jz 1b
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# running(AS* or 0) -> rax its live record when its program runs (ready, working, waiting), else 0
running:
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rax, [rdi + AS_live]
    test rax, rax
    jz 9f
    mov ecx, [rax + AL_state]
    cmp ecx, ALS_READY
    jb 8f
    cmp ecx, ALS_WAITING
    jbe 9f
8:  xor eax, eax
9:  ret

# FN agentcfg_current(AS* or 0, AGC*) -> rax the model the conversation uses (AMO*) or 0, rdx the name to
#   show for it (its label, else the value as the program gave it) or 0. While its program runs: the
#   model in effect (AL_model); else the project's choice; else the last one in effect; else the one the
#   transcript names (AS_model). Reads nothing
FN agentcfg_current
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call running
    test rax, rax
    jz 1f
    lea r13, [rax + AL_model]
    cmp byte ptr [r13], 0
    jne 5f
1:  lea r13, [r12 + AGC_model]
    cmp byte ptr [r13], 0
    jne 5f
    test rbx, rbx
    jz 8f
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 2f
    lea r13, [rax + AL_model]
    cmp byte ptr [r13], 0
    jne 5f
2:  mov r13, [rbx + AS_model]
    test r13, r13
    jz 8f
    cmp byte ptr [r13], 0
    je 8f
5:  mov rdi, r13
    call strlen
    mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    call agentcfg_model_of
    mov rdx, r13
    test rax, rax
    jz 9f
    mov rdx, [rax + AMO_label]
    cmp byte ptr [rdx], 0
    jne 9f
    mov rdx, r13
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
9:  EPILOGUE

# FN agentcfg_effort(AS* or 0, AGC*, AMO* or 0) -> rax the effort level in effect among the model's levels
#   (AEL*) or 0: while its program runs the one it reports (AL_effort), else the project's choice, else the
#   last one in effect
FN agentcfg_effort
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r15, rdx
    test r15, r15
    jz 8f
    call running
    test rax, rax
    jz 1f
    lea r13, [rax + AL_effort]
    cmp byte ptr [r13], 0
    jne 5f
1:  lea r13, [r12 + AGC_effort]
    cmp byte ptr [r13], 0
    jne 5f
    test rbx, rbx
    jz 8f
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 8f
    lea r13, [rax + AL_effort]
    cmp byte ptr [r13], 0
    je 8f
5:  xor r14d, r14d
6:  cmp r14, [r15 + AMO_levels + VEC_len]
    jae 8f
    imul rbx, r14, AEL_SIZE
    add rbx, [r15 + AMO_levels + VEC_ptr]
    inc r14
    mov rdi, [rbx + AEL_id]
    mov rsi, r13
    call strcmp_eq
    test eax, eax
    jz 6b
    mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentcfg_level(AMO* or 0, id, label cstrs): an effort level of the model (16 at most)
FN agentcfg_level
    inc qword ptr [rip + g_agentcfg_gen]
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test rbx, rbx
    jz 9f
    test r12, r12
    jz 9f
    test r13, r13
    jnz 1f
    lea r13, [rip + .Lempty]
1:  mov rdi, r12
    call strlen
    mov r14, rax
    mov rdi, r13
    call strlen
    mov r8, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    mov rcx, r13
    call level_add
9:  EPILOGUE

# level_add(AMO*, id ptr, len, label ptr, r8 len): the level, unless it is empty or the list is full
level_add:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    test r13, r13
    jz 9f
    cmp qword ptr [rbx + AMO_levels + VEC_len], LEVELS_MAX
    jae 9f
    lea rdi, [rbx + AMO_levels]
    mov esi, AEL_SIZE
    call vec_push
    mov rbx, rax
    mov rdi, r12
    mov rsi, r13
    mov edx, LEVEL_MAX
    call cut_dup
    mov [rbx + AEL_id], rax
    mov rdi, r14
    mov rsi, r15
    mov edx, LABEL_MAX
    call cut_dup
    mov [rbx + AEL_label], rax
9:  EPILOGUE

# FN agentcfg_cmd(AGC*, name ptr, len, desc ptr, len, hint ptr, [rbp+16] hint len, [rbp+24] aliases cstr
#   or 0, [rbp+32] origin cstr or 0, [rbp+40] act, [rbp+48] flags) -> rax the command added, or 0 (no
#   name, one of that name already, the list is full). A leading "/" of the name is dropped
FN agentcfg_cmd
    inc qword ptr [rip + g_agentcfg_gen]
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp], r9
    test r13, r13
    jz 8f
    cmp byte ptr [r12], '/'
    jne 1f
    inc r12
    dec r13
    jz 8f
1:  cmp qword ptr [rbx + AGC_cmds + VEC_len], CMDS_MAX
    jae 8f
    mov rdi, r12
    mov rsi, r13
    mov edx, NAME_MAX
    call utf8_cut_rev
    mov r13, rax
    mov rdi, rbx                # one of that name already
    mov rsi, r12
    mov rdx, r13
    call name_find
    test rax, rax
    jnz 8f
    mov edi, ACM_SIZE
    call mem_alloc
    mov [rsp + 8], rax
    lea rdi, [rbx + AGC_cmds]
    mov esi, 8
    call vec_push
    mov rbx, [rsp + 8]
    mov [rax], rbx
    mov rdi, r12
    mov rsi, r13
    mov edx, NAME_MAX
    call cut_dup
    mov [rbx + ACM_name], rax
    mov rdi, r14
    mov rsi, r15
    mov edx, DESC_MAX
    call cut_dup
    mov [rbx + ACM_desc], rax
    mov rdi, rax
    call one_line
    mov rdi, [rsp]
    mov rsi, [rbp + 16]
    mov edx, HINT_MAX
    call cut_dup
    mov [rbx + ACM_hint], rax
    mov rdi, rax
    call one_line
    mov rdi, [rbp + 24]
    mov esi, HINT_MAX
    call cut_dup0
    mov [rbx + ACM_aliases], rax
    mov rdi, [rbp + 32]
    mov esi, NAME_MAX
    call cut_dup0
    mov [rbx + ACM_origin], rax
    mov rax, [rbp + 40]
    cmp rax, ACT_COUNT
    jb 2f
    xor eax, eax
2:  mov [rbx + ACM_act], eax
    mov rax, [rbp + 48]
    and eax, ACMF_LOCAL | ACMF_CLI
    mov [rbx + ACM_flags], eax
    mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# one_line(cstr or 0): its control characters (line ends, tabs) become spaces, in place: a row shows one line
#   (the real CLI's skill descriptions have line ends; the extension's row shows them as spaces)
one_line:
    test rdi, rdi
    jz 9f
1:  movzx eax, byte ptr [rdi]
    test eax, eax
    jz 9f
    cmp eax, 0x20
    jb 2f
    cmp eax, 0x7f
    jne 3f
2:  mov byte ptr [rdi], ' '
3:  inc rdi
    jmp 1b
9:  ret

# utf8_cut_rev(ptr, len, max) -> rax the length to keep (utf8_cut with the usual argument order)
utf8_cut_rev:
    xchg rdi, rsi
    jmp utf8_cut

# name_find(AGC*, ptr, len) -> rax the command of that name, or 0
name_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, [rbx + AGC_cmds + VEC_len]
    jae 8f
    mov rax, [rbx + AGC_cmds + VEC_ptr]
    mov r15, [rax + r14*8]
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r15 + ACM_name]
    call str_eq_cstr
    test eax, eax
    jnz 9f
    inc r14
    jmp 1b
8:  xor r15d, r15d
9:  mov rax, r15
    EPILOGUE

# FN agentcfg_find_model(AGC*, ptr, len) -> rax the model of that value, or 0
FN agentcfg_find_model
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, [rbx + AGC_models + VEC_len]
    jae 8f
    mov rax, [rbx + AGC_models + VEC_ptr]
    mov r15, [rax + r14*8]
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r15 + AMO_value]
    call str_eq_cstr
    test eax, eax
    jnz 9f
    inc r14
    jmp 1b
8:  xor r15d, r15d
9:  mov rax, r15
    EPILOGUE

# FN agentcfg_find_cmd(AGC*, ptr, len) -> rax the command with that name or alias, or 0
FN agentcfg_find_cmd
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call name_find
    test rax, rax
    jnz 9f
    xor r14d, r14d
1:  cmp r14, [rbx + AGC_cmds + VEC_len]
    jae 8f
    mov rax, [rbx + AGC_cmds + VEC_ptr]
    mov r15, [rax + r14*8]
    inc r14
    mov rdi, [r15 + ACM_aliases]
    test rdi, rdi
    jz 1b
    mov rsi, r12
    mov rdx, r13
    call word_in
    test eax, eax
    jz 1b
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# word_in(words cstr, ptr, len) -> eax 1 when one of the space-separated words is ptr/len
word_in:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
1:  cmp byte ptr [rbx], ' '
    jne 2f
    inc rbx
    jmp 1b
2:  cmp byte ptr [rbx], 0
    je 8f
    mov r14, rbx
3:  movzx eax, byte ptr [r14]
    test eax, eax
    jz 4f
    cmp eax, ' '
    je 4f
    inc r14
    jmp 3b
4:  mov rax, r14
    sub rax, rbx
    cmp rax, r13
    jne 5f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jnz 9f
5:  mov rbx, r14
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# models_free(VEC* of AMO*), cmds_free(VEC* of ACM*): the lists and everything they own
models_free:
    inc qword ptr [rip + g_agentcfg_gen]
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + VEC_len]
    jae 9f
    mov rax, [rbx + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    mov rdi, [r13 + AMO_value]
    call mem_free
    mov rdi, [r13 + AMO_label]
    call mem_free
    mov rdi, [r13 + AMO_desc]
    call mem_free
    mov rdi, [r13 + AMO_resolved]
    call mem_free
    xor r14d, r14d
2:  cmp r14, [r13 + AMO_levels + VEC_len]
    jae 3f
    imul rax, r14, AEL_SIZE
    add rax, [r13 + AMO_levels + VEC_ptr]
    mov r15, rax
    mov rdi, [r15 + AEL_id]
    call mem_free
    mov rdi, [r15 + AEL_label]
    call mem_free
    inc r14
    jmp 2b
3:  lea rdi, [r13 + AMO_levels]
    call vec_free
    mov rdi, r13
    call mem_free
    jmp 1b
9:  mov rdi, rbx
    call vec_free
    EPILOGUE

cmds_free:
    inc qword ptr [rip + g_agentcfg_gen]
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + VEC_len]
    jae 9f
    mov rax, [rbx + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    mov rdi, [r13 + ACM_name]
    call mem_free
    mov rdi, [r13 + ACM_desc]
    call mem_free
    mov rdi, [r13 + ACM_hint]
    call mem_free
    mov rdi, [r13 + ACM_aliases]
    call mem_free
    mov rdi, [r13 + ACM_origin]
    call mem_free
    mov rdi, r13
    call mem_free
    jmp 1b
9:  mov rdi, rbx
    call vec_free
    EPILOGUE

# ---- conversations and the project's choices ----

# FN agentcfg_conv(AGC*, sid cstr) -> rax that conversation's ACH, made when it has none (the oldest goes
#   past 1000); valid until the next agentcfg_conv
FN agentcfg_conv
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call agentcfg_need
    mov rdi, rbx
    mov rsi, r12
    call conv_find
    EPILOGUE

# conv_find(AGC*, sid cstr) -> rax its ACH, made (dirty) when it has none
conv_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13, [rbx + AGC_convs + VEC_len]
    jae 2f
    imul r14, r13, ACH_SIZE
    add r14, [rbx + AGC_convs + VEC_ptr]
    lea rdi, [r14 + ACH_sid]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 8f
    inc r13
    jmp 1b
2:  mov rcx, [rbx + AGC_convs + VEC_len]
    cmp rcx, CONVS_MAX
    jb 3f
    mov rdi, [rbx + AGC_convs + VEC_ptr]   # the oldest goes
    lea rsi, [rdi + ACH_SIZE]
    dec rcx
    mov [rbx + AGC_convs + VEC_len], rcx
    imul rdx, rcx, ACH_SIZE
    call memmove
3:  lea rdi, [rbx + AGC_convs]
    mov esi, ACH_SIZE
    call vec_push
    mov r14, rax
    mov rdi, r12
    call strlen
    lea rdi, [r14 + ACH_sid]
    mov rsi, r12
    mov rdx, rax
    mov ecx, 40
    call set_fixed
    or dword ptr [rbx + AGC_flags], AGCF_DIRTY
8:  mov rax, r14
    EPILOGUE

# FN agentcfg_conv_mode(AGC*, sid cstr) -> rax that conversation's kept mode (a cstr in the record), or 0
#   when it has none; makes nothing (a start asks it)
FN agentcfg_conv_mode
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13, [rbx + AGC_convs + VEC_len]
    jae 8f
    imul r14, r13, ACH_SIZE
    add r14, [rbx + AGC_convs + VEC_ptr]
    lea rdi, [r14 + ACH_sid]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 2f
    inc r13
    jmp 1b
2:  lea rax, [r14 + ACH_mode]
    cmp byte ptr [rax], 0
    je 8f
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentcfg_dirty(AGC*): something in it changed (an ACH_mode)
FN agentcfg_dirty
    or dword ptr [rdi + AGC_flags], AGCF_DIRTY
    ret

# FN agentcfg_set(AGC*, field AGF_*, ptr, len): a choice or a value of the program's (an int field: the
#   value in rdx); dirty when it changed
FN agentcfg_set
    inc qword ptr [rip + g_agentcfg_gen]
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    call agentcfg_need
    lea rcx, [rip + set_fields]
1:  mov eax, [rcx]
    test eax, eax
    jz 9f
    cmp eax, r12d
    je 2f
    add rcx, 16
    jmp 1b
2:  mov eax, [rcx + 4]          # offset
    lea rdi, [rbx + rax]
    mov eax, [rcx + 8]          # cap, 0: an int
    test eax, eax
    jz 3f
    mov rsi, r13
    mov rdx, r14
    mov ecx, eax
    call set_fixed
    jmp 4f
3:  xor eax, eax
    cmp [rdi], r13d
    je 4f
    mov [rdi], r13d
    mov eax, 1
4:  test eax, eax
    jz 9f
    or dword ptr [rbx + AGC_flags], AGCF_DIRTY
9:  EPILOGUE

# ---- writing ----

# FN agentcfg_save(AGC*): when something changed, the record into its state file (memory only without a
#   project)
FN agentcfg_save
    PROLOGUE
    mov rbx, rdi
    test dword ptr [rbx + AGC_flags], AGCF_DIRTY
    jz 9f
    test dword ptr [rbx + AGC_flags], AGCF_NOFILE
    jnz 8f
    mov rdi, rbx                # never over a file not read yet
    call agentcfg_need
    lea rdi, [rip + wsb]
    call sb_clear
    lea rdi, [rip + wsb]
    mov rsi, rbx
    call file_text
    mov rdi, [rbx + AGC_path]
    mov rsi, [rip + wsb + SB_ptr]
    mov rdx, [rip + wsb + SB_len]
    call file_write_all
    test rax, rax
    jnz 9f                      # not written: it stays dirty, the next save tries again
8:  and dword ptr [rbx + AGC_flags], ~AGCF_DIRTY
9:  EPILOGUE

# FN agentcfg_flush(): every record saved and freed (quit, the project changes)
FN agentcfg_flush
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + agcs + VEC_len]
    jae 2f
    mov rax, [rip + agcs + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov rdi, r12
    call agentcfg_save
    mov rdi, r12
    call agc_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + agcs + VEC_len], 0
    EPILOGUE

# agc_free(AGC*)
agc_free:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rbx + AGC_models]
    call models_free
    lea rdi, [rbx + AGC_omodels]
    call models_free
    lea rdi, [rbx + AGC_cmds]
    call cmds_free
    lea rdi, [rbx + AGC_ocmds]
    call cmds_free
    lea rdi, [rbx + AGC_convs]
    call vec_free
    mov rdi, [rbx + AGC_path]
    call mem_free
    mov rdi, rbx
    call mem_free
    EPILOGUE

# file_text(sb, AGC*): the state file's lines (the commands last: they stop where the file would pass
#   FILE_MAX)
file_text:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    lea rsi, [rip + .Lw_head]
    call sb_push_cstr
    cmp byte ptr [r12 + AGC_version], 0
    je 1f
    mov rdi, rbx
    lea rsi, [rip + .Lw_version]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r12 + AGC_version]
    call put_field
    mov rdi, rbx
    call put_nl
1:  mov rdi, rbx
    lea rsi, [rip + .Lw_project]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r12 + AGC_model]
    call put_field
    mov rdi, rbx
    lea rsi, [r12 + AGC_effort]
    call put_field
    mov rdi, rbx
    movsxd rsi, dword ptr [r12 + AGC_ultra]
    call put_num
    mov rdi, rbx
    movsxd rsi, dword ptr [r12 + AGC_think]
    call put_num
    mov rdi, rbx
    call put_nl
    mov rdi, rbx
    lea rsi, [rip + .Lw_fast]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r12 + AGC_fast]
    call put_num
    mov rdi, rbx
    lea rsi, [r12 + AGC_fastwhy]
    call put_field
    mov rdi, rbx
    call put_nl
    cmp byte ptr [r12 + AGC_dest], 0
    je 2f
    mov rdi, rbx
    lea rsi, [rip + .Lw_dest]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r12 + AGC_dest]
    call put_field
    mov rdi, rbx
    call put_nl
2:  cmp byte ptr [r12 + AGC_newmode], 0
    je 3f
    mov rdi, rbx
    lea rsi, [rip + .Lw_newmode]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r12 + AGC_newmode]
    call put_field
    mov rdi, rbx
    call put_nl
3:  xor r13d, r13d
4:  cmp r13, [r12 + AGC_convs + VEC_len]
    jae 5f
    imul r14, r13, ACH_SIZE
    add r14, [r12 + AGC_convs + VEC_ptr]
    inc r13
    mov rdi, rbx
    lea rsi, [rip + .Lw_conv]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r14 + ACH_sid]
    call put_field
    mov rdi, rbx
    lea rsi, [r14 + ACH_mode]
    call put_field
    mov rdi, rbx
    call put_nl
    jmp 4b
5:  mov rdi, rbx
    lea rsi, [r12 + AGC_models]
    mov edx, FILE_MAX - 1
    call models_text
    mov rdi, rbx
    lea rsi, [r12 + AGC_cmds]
    mov edx, FILE_MAX - 1
    call cmds_text
    EPILOGUE

# models_text(sb, VEC* of AMO*, edx max bytes of sb): their "model" lines, until sb would pass max (as
#   cmds_text)
models_text:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    movsxd r15, edx
    xor r13d, r13d
1:  cmp r13, [r12 + VEC_len]
    jae 9f
    mov rax, [r12 + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    mov rax, [rbx + SB_len]     # where this line starts: it goes again when it would pass max
    mov [rsp], rax
    mov rdi, rbx
    lea rsi, [rip + .Lw_model]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + AMO_value]
    call put_field
    mov rdi, rbx
    mov rsi, [r14 + AMO_label]
    call put_field
    mov rdi, rbx
    mov rsi, [r14 + AMO_desc]
    call put_field
    mov rdi, rbx
    mov esi, [r14 + AMO_flags]
    call put_num
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r14
    xor edx, edx
    call levels_text
    mov rsi, [r14 + AMO_resolved]   # the id the program reports, when known
    test rsi, rsi
    jz 2f
    mov rdi, rbx
    call put_field
2:  mov rdi, rbx
    call put_nl
    cmp [rbx + SB_len], r15
    jbe 1b
    mov rax, [rsp]              # past the file's room: this line and the rest are left out
    mov [rbx + SB_len], rax
9:  EPILOGUE

# levels_text(sb, AMO*, plain): "ID:LABEL,ID:LABEL" (plain 0: escaped for the file; levels whose id or
#   label hold ':' or ',' are left out)
levels_text:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r15d, edx
    xor r13d, r13d
    xor r14d, r14d              # one written
1:  cmp r13, [r12 + AMO_levels + VEC_len]
    jae 9f
    imul rax, r13, AEL_SIZE
    add rax, [r12 + AMO_levels + VEC_ptr]
    inc r13
    push rax
    push rax
    mov rdi, [rax + AEL_id]
    call level_word_ok
    mov ecx, eax
    mov rax, [rsp]
    push rcx
    push rcx
    mov rdi, [rax + AEL_label]
    call level_word_ok
    pop rcx
    pop rcx
    and ecx, eax
    pop rax
    pop rax
    test ecx, ecx
    jz 1b
    push rax
    push rax
    test r14d, r14d
    jz 2f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
2:  mov r14d, 1
    mov rax, [rsp]
    mov rdi, rbx
    mov rsi, [rax + AEL_id]
    mov edx, r15d
    call put_text
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    mov rax, [rsp]
    mov rdi, rbx
    mov rsi, [rax + AEL_label]
    mov edx, r15d
    call put_text
    pop rax
    pop rax
    jmp 1b
9:  EPILOGUE

# level_word_ok(cstr) -> eax 1 when it holds no ':' or ','
level_word_ok:
    mov eax, 1
1:  movzx ecx, byte ptr [rdi]
    test ecx, ecx
    jz 9f
    inc rdi
    cmp ecx, ':'
    je 8f
    cmp ecx, ','
    jne 1b
8:  xor eax, eax
9:  ret

# cmds_text(sb, VEC* of ACM*, edx max bytes of sb, -1 none): their "cmd" lines, until sb would pass max
cmds_text:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    movsxd r15, edx
    xor r13d, r13d
1:  cmp r13, [r12 + VEC_len]
    jae 9f
    mov rax, [r12 + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    mov rax, [rbx + SB_len]     # where this line starts: it goes again when it would pass max
    push rax
    push rax
    mov rdi, rbx
    lea rsi, [rip + .Lw_cmd]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + ACM_name]
    call put_field
    mov rdi, rbx
    mov rsi, [r14 + ACM_desc]
    call put_field
    mov rdi, rbx
    mov rsi, [r14 + ACM_hint]
    call put_field
    mov rdi, rbx
    mov rsi, [r14 + ACM_aliases]
    call put_field
    mov rdi, rbx
    mov rsi, [r14 + ACM_origin]
    call put_field
    mov rdi, rbx
    mov esi, [r14 + ACM_act]
    call put_num
    mov rdi, rbx
    mov esi, [r14 + ACM_flags]
    call put_num
    mov rdi, rbx
    call put_nl
    pop rax
    pop rax
    test r15, r15
    js 1b
    cmp [rbx + SB_len], r15
    jbe 1b
    mov [rbx + SB_len], rax     # past the file's room: this line and the rest are left out
9:  EPILOGUE

# put_field(sb, cstr or 0): a tab and the text, escaped
put_field:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call put_text
    EPILOGUE

# put_text(sb, cstr or 0, plain): the text, escaped unless plain
put_text:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    test r12, r12
    jz 9f
1:  movzx r14d, byte ptr [r12]
    test r14d, r14d
    jz 9f
    inc r12
    test r13d, r13d
    jnz 5f
    mov eax, 't'
    cmp r14d, 9
    je 4f
    mov eax, 'n'
    cmp r14d, 10
    je 4f
    mov eax, 92
    cmp r14d, 92
    jne 5f
4:  mov r14d, eax
    mov rdi, rbx
    mov esi, 92
    call sb_push_byte
5:  mov rdi, rbx
    mov esi, r14d
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# put_num(sb, signed rsi): a tab and the number ("-" for a negative one)
put_num:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov esi, 9
    call sb_push_byte
    test r12, r12
    jns 1f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    EPILOGUE
1:  mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    EPILOGUE

# put_nl(sb)
put_nl:
    mov esi, 10
    jmp sb_push_byte

# ---- print-agent-cfg ----

# FN agentcfg_dump(sb, AGC*): "kind=K read=0|1 file=0|1 dirty=0|1 path=P|-", then "version V", a
#   "model VALUE\tLABEL\tDESC\tFLAGS\tLEVELS" line per model (flags as off,thinkoff,auto,fast,effort;
#   levels as ID:LABEL,...; "-" for none), a "cmd NAME\tDESC\tHINT\tALIASES\tORIGIN\tACT\tFLAGS" line per
#   command (empty fields "-", the act as its word, flags local,cli), "project model=M effort=E ultra=U
#   think=T", "fast STATE REASON", "dest D", "newmode M", a "conv SID MODE" line per conversation
FN agentcfg_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    lea rsi, [rip + .Ld_kind]
    call sb_push_cstr
    mov edi, [r12 + AGC_kind]
    call agent_kind_name
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_read]
    mov edx, [r12 + AGC_flags]
    and edx, AGCF_READ
    call put_flag
    mov rdi, rbx
    lea rsi, [rip + .Ld_file]
    mov edx, [r12 + AGC_flags]
    not edx
    and edx, AGCF_NOFILE
    call put_flag
    mov rdi, rbx
    lea rsi, [rip + .Ld_dirty]
    mov edx, [r12 + AGC_flags]
    and edx, AGCF_DIRTY
    call put_flag
    mov rdi, rbx
    lea rsi, [rip + .Ld_path]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r12 + AGC_path]
    call put_or_dash
    mov rdi, rbx
    call put_nl
    mov rdi, rbx
    lea rsi, [rip + .Ld_version]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r12 + AGC_version]
    call put_or_dash
    mov rdi, rbx
    call put_nl
    xor r13d, r13d
1:  cmp r13, [r12 + AGC_models + VEC_len]
    jae 2f
    mov rax, [r12 + AGC_models + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    mov rdi, rbx
    lea rsi, [rip + .Ld_model]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + AMO_value]
    call put_or_dash
    mov rdi, rbx
    mov rsi, [r14 + AMO_label]
    call tab_or_dash
    mov rdi, rbx
    mov rsi, [r14 + AMO_desc]
    call tab_or_dash
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r14 + AMO_flags]
    lea rdx, [rip + model_flag_names]
    call put_flags
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    cmp qword ptr [r14 + AMO_levels + VEC_len], 0
    jne 11f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 12f
11: mov rdi, rbx
    mov rsi, r14
    mov edx, 1
    call levels_text
12: mov rdi, rbx
    call put_nl
    jmp 1b
2:  xor r13d, r13d
3:  cmp r13, [r12 + AGC_cmds + VEC_len]
    jae 4f
    mov rax, [r12 + AGC_cmds + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    mov rdi, rbx
    lea rsi, [rip + .Ld_cmd]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + ACM_name]
    call put_or_dash
    mov rdi, rbx
    mov rsi, [r14 + ACM_desc]
    call tab_or_dash
    mov rdi, rbx
    mov rsi, [r14 + ACM_hint]
    call tab_or_dash
    mov rdi, rbx
    mov rsi, [r14 + ACM_aliases]
    call tab_or_dash
    mov rdi, rbx
    mov rsi, [r14 + ACM_origin]
    call tab_or_dash
    mov eax, [r14 + ACM_act]
    lea rcx, [rip + act_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call tab_or_dash
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r14 + ACM_flags]
    lea rdx, [rip + cmd_flag_names]
    call put_flags
    mov rdi, rbx
    call put_nl
    jmp 3b
4:  mov rdi, rbx
    lea rsi, [rip + .Ld_project]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r12 + AGC_model]
    call put_or_dash
    mov rdi, rbx
    lea rsi, [rip + .Ld_effort]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r12 + AGC_effort]
    call put_or_dash
    mov rdi, rbx
    lea rsi, [rip + .Ld_ultra]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r12 + AGC_ultra]
    call put_tri
    mov rdi, rbx
    lea rsi, [rip + .Ld_think]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r12 + AGC_think]
    call put_tri
    mov rdi, rbx
    call put_nl
    mov rdi, rbx
    lea rsi, [rip + .Ld_fast]
    call sb_push_cstr
    mov eax, [r12 + AGC_fast]
    cmp eax, FS_COOLDOWN
    jbe 41f
    xor eax, eax
41: lea rcx, [rip + fast_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [r12 + AGC_fastwhy]
    call put_or_dash
    mov rdi, rbx
    call put_nl
    mov rdi, rbx
    lea rsi, [rip + .Ld_dest]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r12 + AGC_dest]
    call put_or_dash
    mov rdi, rbx
    call put_nl
    mov rdi, rbx
    lea rsi, [rip + .Ld_newmode]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r12 + AGC_newmode]
    call put_or_dash
    mov rdi, rbx
    call put_nl
    xor r13d, r13d
5:  cmp r13, [r12 + AGC_convs + VEC_len]
    jae 9f
    imul r14, r13, ACH_SIZE
    add r14, [r12 + AGC_convs + VEC_ptr]
    inc r13
    mov rdi, rbx
    lea rsi, [rip + .Ld_conv]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r14 + ACH_sid]
    call put_or_dash
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [r14 + ACH_mode]
    call put_or_dash
    mov rdi, rbx
    call put_nl
    jmp 5b
9:  EPILOGUE

# put_flag(sb, " name=" cstr, edx not 0 for 1)
put_flag:
    PROLOGUE
    mov rbx, rdi
    mov r12d, edx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, '0'
    test r12d, r12d
    jz 1f
    mov esi, '1'
1:  call sb_push_byte
    EPILOGUE

# put_or_dash(sb, cstr or 0): the text, or "-" when it is empty
put_or_dash:
    test rsi, rsi
    jz 1f
    cmp byte ptr [rsi], 0
    je 1f
    jmp sb_push_cstr
1:  mov esi, '-'
    jmp sb_push_byte

# tab_or_dash(sb, cstr or 0): a tab, then put_or_dash
tab_or_dash:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r12
    call put_or_dash
    EPILOGUE

# put_tri(sb, -1|0|1): "-", "0" or "1"
put_tri:
    mov eax, esi
    mov esi, '-'
    test eax, eax
    js 1f
    lea esi, [rax + '0']
1:  jmp sb_push_byte

# put_flags(sb, flags, names: a cstr per bit from bit 0, 0 ending): the names of the bits set, joined by
#   ",", "-" for none
put_flags:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    xor r14d, r14d              # one written
    xor r15d, r15d              # the bit
1:  mov rsi, [r13 + r15*8]
    test rsi, rsi
    jz 8f
    bt r12d, r15d
    jnc 3f
    test r14d, r14d
    jz 2f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rsi, [r13 + r15*8]
2:  mov r14d, 1
    mov rdi, rbx
    call sb_push_cstr
3:  inc r15d
    jmp 1b
8:  test r14d, r14d
    jnz 9f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
9:  EPILOGUE

.section .rodata
.p2align 3
line_kinds:
    .quad .Lw_l_version, l_version, .Lw_l_model, l_model, .Lw_l_cmd, l_cmd, .Lw_l_project, l_project
    .quad .Lw_l_fast, l_fast, .Lw_l_dest, l_dest, .Lw_l_newmode, l_newmode, .Lw_l_conv, l_conv
    .quad 0, 0
# agentcfg_set's fields: id, offset, cap (0: an int)
set_fields:
    .long AGF_MODEL, AGC_model, 64, 0
    .long AGF_EFFORT, AGC_effort, 16, 0
    .long AGF_ULTRA, AGC_ultra, 0, 0
    .long AGF_THINK, AGC_think, 0, 0
    .long AGF_DEST, AGC_dest, 24, 0
    .long AGF_NEWMODE, AGC_newmode, 32, 0
    .long AGF_VERSION, AGC_version, 24, 0
    .long AGF_FAST, AGC_fast, 0, 0
    .long AGF_FASTWHY, AGC_fastwhy, 32, 0
    .long 0, 0, 0, 0
model_flag_names:               # AMOF_* by bit
    .quad .Lf_off, .Lf_thinkoff, .Lf_auto, .Lf_fast, .Lf_bit4, .Lf_effort, 0
cmd_flag_names:                 # ACMF_* by bit
    .quad .Lf_local, .Lf_cli, 0
act_names:                      # ACT_* by value
    .quad .La_send, .La_clear, .La_new, .La_model, .La_modes, .La_thinking, .La_effort, .La_fast
    .quad .La_plan, .La_copy, .La_signin, .La_signout, .La_terminal, .La_settings, .La_help
    .quad .La_unavailable, .La_ultra
    .quad aghead_a_focusview, aghead_n_resume   # 17, 18: ACT_FOCUSVIEW's and ACT_RESUME's (agenthead.s)
    # phase 7 (claude_dlg.s; claude-chat-p7): the dialogs' commands, ACT_STATUS (19) to ACT_INSTRUCT (25)
    .quad .La_status, .La_usage, .La_context, .La_ostyle, .La_skills, .La_memory, .La_instruct
    .quad .La_attach, .La_mention   # 26, 27: phase 4 task 3's (agentatt.s)
    # claude-chat-p7b (claude_dlg2.s): the configuration dialogs, ACT_MCP (28) to ACT_PLUGINS (32)
    .quad .La_mcp, .La_hooks, .La_perms, .La_sandbox, .La_plugins
    # p7c (agentside.s, agentmap.s, claude_side.s): ACT_BTW (33) to ACT_RC (42)
    .quad .La_btw, .La_bookmarks, .La_tasks, .La_remote, .La_chrome, .La_sideq, .La_handoff, .La_handans
    .quad .La_bashes, .La_rc
    .quad .La_rewind, .La_export, .La_msgact, .La_cut, .La_opened   # p6b, ACT_REWIND (43) to ACT_OPENED (47) (claude_fork.s)
    .quad .La_plugin_link       # 48: ACT_PLUGIN_LINK (row 4.19, agenttab.s)
    .quad .La_rcall             # 49: ACT_RCALL (Remote Control for all sessions, claude_side.s)
fast_names: .quad .Lfs_off, .Lfs_on, .Lfs_cooldown
.La_btw: .asciz "btw"
.La_plugin_link: .asciz "plugin-link"
.La_bookmarks: .asciz "bookmarks"
.La_tasks: .asciz "tasks"
.La_remote: .asciz "remote"
.La_chrome: .asciz "chrome"
.La_sideq: .asciz "sideq"
.La_handoff: .asciz "handoff"
.La_handans: .asciz "handans"
.La_bashes: .asciz "bashes"
.La_rc: .asciz "rc"
.La_rcall: .asciz "remote-control-at-startup"
.La_rewind: .asciz "rewind"
.La_export: .asciz "export"
.La_msgact: .asciz "msgact"
.La_cut: .asciz "cut"
.La_opened: .asciz "opened"
.Lsuffix: .asciz ".agents-"
.Lempty: .asciz ""
.Lw_agentcfg: .asciz "agentcfg"
.Lw_one: .asciz "1"
.Lw_head: .asciz "agentcfg\t1\n"
.Lw_version: .asciz "version"
.Lw_model: .asciz "model"
.Lw_cmd: .asciz "cmd"
.Lw_project: .asciz "project"
.Lw_fast: .asciz "fast"
.Lw_dest: .asciz "dest"
.Lw_newmode: .asciz "newmode"
.Lw_conv: .asciz "conv"
.Lw_l_version: .asciz "version"
.Lw_l_model: .asciz "model"
.Lw_l_cmd: .asciz "cmd"
.Lw_l_project: .asciz "project"
.Lw_l_fast: .asciz "fast"
.Lw_l_dest: .asciz "dest"
.Lw_l_newmode: .asciz "newmode"
.Lw_l_conv: .asciz "conv"
.Ld_kind: .asciz "kind="
.Ld_read: .asciz " read="
.Ld_file: .asciz " file="
.Ld_dirty: .asciz " dirty="
.Ld_path: .asciz " path="
.Ld_version: .asciz "version "
.Ld_model: .asciz "model "
.Ld_cmd: .asciz "cmd "
.Ld_project: .asciz "project model="
.Ld_effort: .asciz " effort="
.Ld_ultra: .asciz " ultra="
.Ld_think: .asciz " think="
.Ld_fast: .asciz "fast "
.Ld_dest: .asciz "dest "
.Ld_newmode: .asciz "newmode "
.Ld_conv: .asciz "conv "
.Lf_off: .asciz "off"
.Lf_thinkoff: .asciz "thinkoff"
.Lf_auto: .asciz "auto"
.Lf_fast: .asciz "fast"
.Lf_bit4: .asciz "16"
.Lf_effort: .asciz "effort"
.Lf_local: .asciz "local"
.Lf_cli: .asciz "cli"
.La_send: .asciz "send"
.La_clear: .asciz "clear"
.La_new: .asciz "new"
.La_model: .asciz "model"
.La_modes: .asciz "modes"
.La_thinking: .asciz "thinking"
.La_effort: .asciz "effort"
.La_fast: .asciz "fast"
.La_plan: .asciz "plan"
.La_copy: .asciz "copy"
.La_signin: .asciz "signin"
.La_signout: .asciz "signout"
.La_terminal: .asciz "terminal"
.La_settings: .asciz "settings"
.La_help: .asciz "help"
.La_unavailable: .asciz "unavailable"
.La_ultra: .asciz "ultra"
.La_status: .asciz "status"
.La_attach: .asciz "attach"
.La_mention: .asciz "mention"
.La_usage: .asciz "usage"
.La_context: .asciz "context"
.La_ostyle: .asciz "output-style"
.La_skills: .asciz "skills"
.La_memory: .asciz "memory"
.La_instruct: .asciz "instructions"
.La_mcp: .asciz "mcp"                  # claude-chat-p7b
.La_hooks: .asciz "hooks"
.La_perms: .asciz "permissions"
.La_sandbox: .asciz "sandbox"
.La_plugins: .asciz "plugins"
.Lfs_off: .asciz "off"
.Lfs_on: .asciz "on"
.Lfs_cooldown: .asciz "cooldown"
