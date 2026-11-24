# the Problems store: problems in any file, from any source (DECISIONS.md: the tasks group owns it;
# language features adds extensions' file-diagnostics to it). A source is an opaque record: a task
# run's matchers, a term-run with --matcher. A problem: absolute path, line and column (bytes, or
# characters when its matcher counts them so), an optional exclusive end, severity, message, code.
# Open documents show them as marks (extmarks.s: gutter dot, underline, tooltip, status counts); a
# file opened later gets its marks then, from the problem's line and column.
#
#   problems_source(key cstr, label cstr) -> PS*: the source with that key, made when new (kept)
#   problems_clear(PS*)            its problems go, and their marks
#   problems_add(PS*, PR*) -> 1 kept, 0 a duplicate of one of its own or past the caps (2000 per
#                                  source, 10000 in all): PR's strings are copied
#   problems_tick()                documents opened since get the marks of their problems; the
#                                  Problems tab is rebuilt after a change
#   problems_dump(sb)              print-problems
# The Problems tab (a bottom panel tab, places.s) lists them as a tree (rtree.s): a node per file, its
# problems under it; Enter or a click goes to one. It appears with the first problem, or with
# toggle_problems (ctrl+shift+m).
.include "rhun.inc"

.equ PER_SOURCE, 2000
.equ ALL_MAX, 10000

.data
tab_id: .long -1                # the Problems tab's place, -1 before it is made

.bss
.p2align 3
sources: .zero VEC_SIZE         # PS*
probs: .zero VEC_SIZE           # PR records, in the order they came
last_doc: .quad 0               # the newest DOC_id problems_tick has seen
seq: .quad 0                    # the last problem's id
ptree: .quad 0                  # the Problems tab's tree
tab_dirty: .long 0              # rebuilt at the next tick
files: .zero VEC_SIZE           # rebuild: the paths, each once, in the order they came
lbuf: .zero SB_SIZE             # a row's label or description
doc_tmp: .zero 4096

.text

# ---- Claude chat phase 5: the store read by the bridge's getDiagnostics (edtools.s) ----
# FN problems_count() -> rax how many problems the store holds
FN problems_count
    mov rax, [rip + probs + VEC_len]
    ret

# FN problems_at(i) -> rax the i-th problem (PR*, in the order they came; valid until the store changes)
FN problems_at
    imul rax, rdi, PR_SIZE
    add rax, [rip + probs + VEC_ptr]
    ret
# ---- end ----

# problems_source(key, label) -> PS*
FN problems_source
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, [rip + sources + VEC_len]
    jae 2f
    mov rax, [rip + sources + VEC_ptr]
    mov r14, [rax + rbx*8]
    inc rbx
    mov rdi, [r14 + PS_key]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jz 1b
    mov rax, r14
    EPILOGUE
2:  mov edi, PS_SIZE
    call mem_alloc
    mov r14, rax
    mov rdi, r12
    call dup
    mov [r14 + PS_key], rax
    mov rdi, r13
    call dup
    mov [r14 + PS_label], rax
    lea rdi, [rip + sources]
    mov esi, 8
    call vec_push
    mov [rax], r14
    mov rax, r14
    EPILOGUE

# dup(cstr) -> an owned copy ("" for 0)
dup:
    push rbx
    mov rbx, rdi
    test rbx, rbx
    jnz 1f
    lea rbx, [rip + .Lempty]
1:  mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    pop rbx
    ret

# problems_clear(PS*): its problems and their marks go
FN problems_clear
    PROLOGUE
    mov r12, rdi
    mov rbx, [rip + probs + VEC_len]
1:  test rbx, rbx
    jz 2f
    dec rbx
    imul r13, rbx, PR_SIZE
    add r13, [rip + probs + VEC_ptr]
    cmp [r13 + PR_src], r12
    jne 1b
    mov rdi, [r13 + PR_path]
    call mem_free
    mov rdi, [r13 + PR_msg]
    call mem_free
    mov rdi, [r13 + PR_code]
    call mem_free
    # the later ones move up: the order stays
    mov rdi, r13
    lea rsi, [r13 + PR_SIZE]
    mov rdx, [rip + probs + VEC_len]
    sub rdx, rbx
    dec rdx
    imul rdx, rdx, PR_SIZE
    call memmove
    dec qword ptr [rip + probs + VEC_len]
    jmp 1b
2:  mov dword ptr [rip + tab_dirty], 1
    mov dword ptr [r12 + PS_count], 0
    mov dword ptr [r12 + PS_errors], 0
    mov dword ptr [r12 + PS_warnings], 0
    mov dword ptr [r12 + PS_dropped], 0
    mov rdi, r12
    call extmarks_clear_owner
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# problems_add(PS*, PR*) -> 1 kept, 0 not
FN problems_add
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call problems_tick          # documents opened before it get the ones before it, and not this twice
    cmp dword ptr [r12 + PS_count], PER_SOURCE
    jae .Lpa_drop
    cmp qword ptr [rip + probs + VEC_len], ALL_MAX
    jae .Lpa_drop
    # one of its own the same: kept once
    xor ebx, ebx
1:  cmp rbx, [rip + probs + VEC_len]
    jae 2f
    imul r14, rbx, PR_SIZE
    add r14, [rip + probs + VEC_ptr]
    inc rbx
    cmp [r14 + PR_src], r12
    jne 1b
    mov eax, [r14 + PR_line]
    cmp eax, [r13 + PR_line]
    jne 1b
    mov eax, [r14 + PR_col]
    cmp eax, [r13 + PR_col]
    jne 1b
    mov eax, [r14 + PR_sev]
    cmp eax, [r13 + PR_sev]
    jne 1b
    mov rdi, [r14 + PR_path]
    mov rsi, [r13 + PR_path]
    call strcmp_eq
    test eax, eax
    jz 1b
    mov rdi, [r14 + PR_msg]
    mov rsi, [r13 + PR_msg]
    call strcmp_eq
    test eax, eax
    jz 1b
    xor eax, eax
    EPILOGUE
2:  lea rdi, [rip + probs]
    mov esi, PR_SIZE
    call vec_push
    mov r14, rax
    mov rdi, r14
    mov rsi, r13
    mov edx, PR_SIZE
    call memcpy
    mov [r14 + PR_src], r12
    mov rdi, [r13 + PR_path]
    call dup
    mov [r14 + PR_path], rax
    mov rdi, [r13 + PR_msg]
    call dup
    mov [r14 + PR_msg], rax
    mov rdi, [r13 + PR_code]
    call dup
    mov [r14 + PR_code], rax
    inc qword ptr [rip + seq]
    mov rax, [rip + seq]
    mov [r14 + PR_seq], rax
    mov dword ptr [rip + tab_dirty], 1
    inc dword ptr [r12 + PS_count]
    mov eax, [r14 + PR_sev]
    cmp eax, SEV_ERROR
    jne 3f
    inc dword ptr [r12 + PS_errors]
3:  cmp eax, SEV_WARNING
    jne 4f
    inc dword ptr [r12 + PS_warnings]
4:  # an open document shows it at once
    mov rdi, [r14 + PR_path]
    call doc_by_path
    test rax, rax
    jz 5f
    mov rdi, rax
    mov rsi, r14
    call mark_problem
5:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lpa_drop:
    inc dword ptr [r12 + PS_dropped]
    xor eax, eax
    EPILOGUE

# doc_by_path(path) -> the open document of that file, or 0
doc_by_path:
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 8f
    imul rax, rbx, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    inc rbx
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 1b
    mov r13, [rax + TAB_doc]
    test r13, r13
    jz 1b
    mov rdi, [r13 + DOC_path]
    test rdi, rdi
    jz 1b
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jz 1b
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# mark_problem(doc, PR*): the problem as a mark on the document: from its line and column (a column in
#   characters counted on the line), to its end, else the word at the column, else one character;
#   past the text it is not shown
mark_problem:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call doc_len
    mov r15, rax                # the text's length
    mov esi, [r12 + PR_line]
    test esi, esi
    jnz 1f
    mov esi, 1
1:  mov edx, [r12 + PR_col]
    mov ecx, [r12 + PR_flags]
    mov rdi, rbx
    call point_of
    test rax, rax
    js 9f
    mov r13, rax                # start
    mov esi, [r12 + PR_endline]
    test esi, esi
    jz 3f
    mov edx, [r12 + PR_endcol]
    test edx, edx
    jz 3f
    mov ecx, [r12 + PR_flags]
    mov rdi, rbx
    call point_of
    test rax, rax
    js 3f
    cmp rax, r13
    ja 4f
3:  # the word at the column (letters, digits, _, and the bytes of other characters), else one byte
    mov r14, r13
2:  cmp r14, r15
    jae 21f
    mov rdi, rbx
    mov rsi, r14
    call doc_byte
    cmp eax, 0x80
    jae 22f
    mov edi, eax
    call is_ident
    test eax, eax
    jz 21f
22: inc r14
    jmp 2b
21: mov rax, r14
    cmp rax, r13
    ja 4f
    lea rax, [r13 + 1]          # one character (a line feed, at a line's end)
    cmp rax, r15
    jbe 4f
    mov rax, r13
4:  mov rdi, rbx
    mov rsi, [r12 + PR_src]
    mov rdx, r13
    mov rcx, rax
    mov r8d, [r12 + PR_sev]
    mov r9, [r12 + PR_msg]
    call extmarks_add_source
9:  EPILOGUE

# point_of(doc, line, col, flags) -> byte position of a 1-based line and column (bytes, or characters
#   with PRF_CHARS; 0 the line's first non-blank), or -1 past the text
point_of:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    cmp r12, [rbx + DOC_nlines]
    ja 8f
    lea rsi, [r12 - 1]
    mov rdi, rbx
    call doc_line_start
    mov r15, rax
    lea rsi, [r12 - 1]
    mov rdi, rbx
    call doc_line_end
    mov r12, rax                # the line's end
    test r13d, r13d
    jnz 2f
    # no column: the first non-blank
1:  cmp r15, r12
    jae 7f
    mov rdi, rbx
    mov rsi, r15
    call doc_byte
    cmp eax, ' '
    je 11f
    cmp eax, 9
    jne 7f
11: inc r15
    jmp 1b
2:  test r14d, PRF_CHARS
    jnz 3f
    lea rax, [r15 + r13 - 1]
    cmp rax, r12
    ja 8f
    mov r15, rax
    jmp 7f
3:  # characters: each lead byte counts
    dec r13d
4:  test r13d, r13d
    jz 7f
    cmp r15, r12
    jae 8f
    inc r15
5:  cmp r15, r12
    jae 6f
    mov rdi, rbx
    mov rsi, r15
    call doc_byte
    and eax, 0xc0
    cmp eax, 0x80
    jne 6f
    inc r15
    jmp 5b
6:  dec r13d
    jmp 4b
7:  mov rax, r15
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# problems_tick(): documents opened since the last tick get their problems' marks; a frame only when
#   marks came (or the tab changed: tab_rebuild)
FN problems_tick
    PROLOGUE 16
    mov qword ptr [rsp], 0      # marks added
    cmp dword ptr [rip + tab_dirty], 0
    je 0f
    call tab_rebuild
0:  cmp qword ptr [rip + probs + VEC_len], 0
    je 9f
    mov r15, [rip + last_doc]
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 8f
    imul rax, rbx, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    inc rbx
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 1b
    mov r12, [rax + TAB_doc]
    test r12, r12
    jz 1b
    mov rax, [r12 + DOC_id]
    cmp rax, [rip + last_doc]
    jbe 1b
    cmp rax, r15
    cmova r15, rax
    mov rdi, [r12 + DOC_path]
    test rdi, rdi
    jz 1b
    # its problems, from every source
    xor r13d, r13d
2:  cmp r13, [rip + probs + VEC_len]
    jae 1b
    imul r14, r13, PR_SIZE
    add r14, [rip + probs + VEC_ptr]
    inc r13
    mov rdi, [r14 + PR_path]
    mov rsi, [r12 + DOC_path]
    call strcmp_eq
    test eax, eax
    jz 2b
    mov rdi, r12
    mov rsi, r14
    call mark_problem
    mov qword ptr [rsp], 1
    jmp 2b
8:  mov [rip + last_doc], r15
    cmp qword ptr [rsp], 0
    je 81f
    mov dword ptr [rip + g_dirty], 1
81: EPILOGUE
9:  # with none, documents opened meanwhile have nothing to show
    call newest_doc
    mov [rip + last_doc], rax
    EPILOGUE

# newest_doc() -> the highest DOC_id of the open documents
newest_doc:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, [rip + g_tabs + VEC_len]
    jae 9f
    imul rdx, rcx, TAB_SIZE
    add rdx, [rip + g_tabs + VEC_ptr]
    inc rcx
    cmp qword ptr [rdx + TAB_kind], TAB_DOC
    jne 1b
    mov rdx, [rdx + TAB_doc]
    test rdx, rdx
    jz 1b
    mov rdx, [rdx + DOC_id]
    cmp rdx, rax
    cmova rax, rdx
    jmp 1b
9:  ret

# ---------------- the Problems tab ----------------

# tab_ensure(): the tab and its tree, made once
tab_ensure:
    PROLOGUE
    cmp dword ptr [rip + tab_id], 0
    jge 9f
    lea rdi, [rip + tab_tree_ops]
    xor esi, esi
    call tree_new
    mov [rip + ptree], rax
    mov edi, PLACE_PANEL
    lea rsi, [rip + .Ltab_name]
    lea rdx, [rip + .Ltab_title]
    lea rcx, [rip + tab_place_ops]
    xor r8d, r8d
    call place_add
    mov [rip + tab_id], eax
    test eax, eax
    js 9f
    mov edi, eax
    mov esi, -1
    call place_set_icon
    mov dword ptr [rip + tab_dirty], 1
9:  EPILOGUE

# cmd_toggle_problems(): the panel opens on the Problems tab, with the keyboard; again, it closes
FN cmd_toggle_problems
    PROLOGUE
    call tab_ensure
    mov edi, [rip + tab_id]
    test edi, edi
    js 9f
    call place_focused
    cmp eax, [rip + tab_id]
    jne 1f
    call cmd_toggle_panel
    jmp 9f
1:  call tab_rebuild
    mov edi, [rip + tab_id]
    mov esi, 1
    call place_show
9:  EPILOGUE

# tab_rebuild(): the tree from the store: the files in the order their first problem came, each with
#   its problems; the tab's badge is the count
tab_rebuild:
    PROLOGUE 16
    mov dword ptr [rip + tab_dirty], 0
    cmp qword ptr [rip + probs + VEC_len], 0
    je 1f
    call tab_ensure
1:  mov rbx, [rip + ptree]
    test rbx, rbx
    jz 9f
    # the files, each once
    mov qword ptr [rip + files + VEC_len], 0
    xor r12d, r12d
2:  cmp r12, [rip + probs + VEC_len]
    jae 4f
    imul r13, r12, PR_SIZE
    add r13, [rip + probs + VEC_ptr]
    inc r12
    xor r14d, r14d
3:  cmp r14, [rip + files + VEC_len]
    jae 31f
    mov rax, [rip + files + VEC_ptr]
    mov rdi, [rax + r14*8]
    mov rsi, [r13 + PR_path]
    call strcmp_eq
    test eax, eax
    jnz 2b
    inc r14
    jmp 3b
31: lea rdi, [rip + files]
    mov esi, 8
    call vec_push
    mov rcx, [r13 + PR_path]
    mov [rax], rcx
    jmp 2b
4:  mov rdi, rbx
    xor esi, esi
    call tree_kids_begin
    xor r12d, r12d
5:  cmp r12, [rip + files + VEC_len]
    jae 6f
    mov rax, [rip + files + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    mov rdi, r13
    call file_label
    mov rdi, r13
    call strlen
    mov rdi, rbx
    mov rsi, r13
    mov rdx, rax
    mov rcx, [rip + lbuf + SB_ptr]
    mov r8, [rip + lbuf + SB_len]
    mov r9d, KIDS_OPEN
    call tree_kid
    jmp 5b
6:  mov rdi, rbx
    xor esi, esi
    call tree_kids_end
    # each file's problems
    xor r12d, r12d
7:  cmp r12, [rip + files + VEC_len]
    jae 8f
    mov rax, [rip + files + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    mov rdi, r13
    call strlen
    mov rdi, rbx
    mov rsi, r13
    mov rdx, rax
    call tree_find
    mov [rsp], eax              # the file's node
    mov rdi, rbx
    mov esi, eax
    call tree_kids_begin
    xor r14d, r14d
    xor r15d, r15d              # its count
71: cmp r14, [rip + probs + VEC_len]
    jae 72f
    imul rax, r14, PR_SIZE
    add rax, [rip + probs + VEC_ptr]
    inc r14
    mov [rsp + 8], rax
    mov rdi, [rax + PR_path]
    mov rsi, r13
    call strcmp_eq
    test eax, eax
    jz 71b
    inc r15d
    mov rdi, [rsp + 8]
    call problem_row
    jmp 71b
72: mov rdi, rbx
    xor esi, esi
    call tree_kids_end
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, r15d
    call tree_set_badge
    jmp 7b
8:  mov edi, [rip + tab_id]
    mov esi, [rip + probs + VEC_len]
    call place_set_badge
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# problem_row(PR*): its row under its file (rbx the tree): severity icon, message, then code, source
#   and place
problem_row:
    PROLOGUE 32
    mov r12, rdi
    # the id: #SEQ
    lea rdi, [rsp]
    mov byte ptr [rdi], '#'
    inc rdi
    mov rsi, [r12 + PR_seq]
    call fmt_u64
    lea rcx, [rsp]
    sub rdi, rcx
    mov r13, rdi                # its length
    mov rdi, [r12 + PR_msg]
    call strlen
    mov rdi, rbx
    lea rsi, [rsp]
    mov rdx, r13
    mov rcx, [r12 + PR_msg]
    mov r8, rax
    mov r9d, KIDS_LEAF
    call tree_kid
    test eax, eax
    js 9f
    mov r13d, eax
    mov rdi, rbx
    mov esi, r13d
    mov rdx, [r12 + PR_seq]
    call tree_set_user
    mov edx, IC_CLOSE
    mov ecx, T_ERROR
    mov eax, [r12 + PR_sev]
    cmp eax, SEV_ERROR
    je 1f
    mov edx, IC_DOT
    mov ecx, T_WARNING
    cmp eax, SEV_WARNING
    je 1f
    mov ecx, T_MUTED
1:  mov rdi, rbx
    mov esi, r13d
    call tree_set_icon
    # "E0425  build  3:20"
    lea rdi, [rip + lbuf]
    call sb_clear
    mov rsi, [r12 + PR_code]
    cmp byte ptr [rsi], 0
    je 2f
    lea rdi, [rip + lbuf]
    call sb_push_cstr
    lea rdi, [rip + lbuf]
    lea rsi, [rip + .Lgap]
    call sb_push_cstr
2:  mov rax, [r12 + PR_src]
    lea rdi, [rip + lbuf]
    mov rsi, [rax + PS_label]
    call sb_push_cstr
    lea rdi, [rip + lbuf]
    lea rsi, [rip + .Lgap]
    call sb_push_cstr
    lea rdi, [rip + lbuf]
    mov esi, [r12 + PR_line]
    call sb_push_u64
    cmp dword ptr [r12 + PR_col], 0
    je 3f
    lea rdi, [rip + lbuf]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + lbuf]
    mov esi, [r12 + PR_col]
    call sb_push_u64
3:  mov rdi, rbx
    mov esi, r13d
    mov rdx, [rip + lbuf + SB_ptr]
    mov rcx, [rip + lbuf + SB_len]
    call tree_set_desc
9:  EPILOGUE

# file_label(path): into lbuf, the file as the Problems tab names it: from the project when inside it,
#   else with ~ for the home folder
file_label:
    PROLOGUE 4096
    mov rbx, rdi
    lea rdi, [rip + lbuf]
    call sb_clear
    mov r12, [rip + g_project]
    test r12, r12
    jz 2f
    mov rdi, r12
    call strlen
    mov r13, rax
    test r13, r13
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jz 2f
    cmp byte ptr [rbx + r13], '/'
    jne 2f
    lea rdi, [rip + lbuf]
    lea rsi, [rbx + r13 + 1]
    call sb_push_cstr
    EPILOGUE
2:  mov rdi, rbx
    call strlen
    cmp rax, 4000
    jae 3f
    lea rdi, [rsp]
    mov rsi, rbx
    call path_tilde
    lea rdi, [rip + lbuf]
    lea rsi, [rsp]
    call sb_push_cstr
    EPILOGUE
3:  lea rdi, [rip + lbuf]
    mov rsi, rbx
    call sb_push_cstr
    EPILOGUE

# tab_draw(ctx, x, y, w, h): the tree, or "No problems"
tab_draw:
    PROLOGUE 16
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    cmp qword ptr [rip + probs + VEC_len], 0
    jne 1f
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, [rsp + 4]
    M ecx, MI_28
    lea r8, [rip + .Lnone]
    COLOR r9d, T_MUTED
    call ui_text_c
    EPILOGUE
1:  call place_focused
    xor r9d, r9d
    cmp eax, [rip + tab_id]
    sete r9b
    mov rdi, [rip + ptree]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call tree_draw
    EPILOGUE

# tab_key(ctx, keysym, cp, mods) -> eax taken
tab_key:
    mov rdi, [rip + ptree]
    jmp tree_key

# tab_activate(ctx, tr, node): a problem's row: its file opens at its place (a file's row folds)
tab_activate:
    PROLOGUE
    mov rdi, rsi
    mov esi, edx
    call tree_user
    test rax, rax
    jz 9f
    mov r12, rax
    xor ebx, ebx
1:  cmp rbx, [rip + probs + VEC_len]
    jae 9f
    imul r13, rbx, PR_SIZE
    add r13, [rip + probs + VEC_ptr]
    inc rbx
    cmp [r13 + PR_seq], r12
    jne 1b
    mov rdi, r13
    call goto_problem
9:  EPILOGUE

# goto_problem(PR*): its file in a tab, the cursor at its place
goto_problem:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + PR_path]
    call app_open_file
    test rax, rax
    js 9f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov r12d, [rbx + PR_line]
    test r12d, r12d
    jnz 1f
    mov r12d, 1
1:  mov r13d, [rbx + PR_col]
    test dword ptr [rbx + PR_flags], PRF_CHARS
    jnz 5f
    test r13d, r13d
    jz 5f
    # a column in bytes: app_goto_line counts characters
    mov r14, [rip + g_doc]
    test r14, r14
    jz 5f
    mov rdi, r14
    mov esi, r12d
    mov edx, r13d
    xor ecx, ecx
    call point_of
    test rax, rax
    js 5f
    mov r15, rax
    lea rsi, [r12 - 1]
    mov rdi, r14
    call doc_line_start
    mov r13d, 1
2:  cmp rax, r15
    jae 5f
    push rax
    push rax
    mov rdi, r14
    mov rsi, rax
    call doc_byte
    pop rcx
    pop rcx
    and eax, 0xc0
    cmp eax, 0x80
    je 3f
    inc r13d
3:  lea rax, [rcx + 1]
    jmp 2b
5:  mov edi, r12d
    mov esi, r13d
    call app_goto_line
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# problems_tab_dump(sb): the Problems tab's rows (print-problems-tab), "tab=none" before it exists
FN problems_tab_dump
    PROLOGUE
    mov r12, rdi
    mov rdi, [rip + ptree]
    test rdi, rdi
    jnz 1f
    mov rdi, r12
    lea rsi, [rip + .Ltab_none]
    call sb_push_cstr
    EPILOGUE
1:  mov rsi, r12
    call tree_dump
    EPILOGUE

# problems_counts(PS*) -> eax errors, edx warnings, ecx not kept (past the caps)
FN problems_counts
    mov eax, [rdi + PS_errors]
    mov edx, [rdi + PS_warnings]
    mov ecx, [rdi + PS_dropped]
    ret

# problems_dump(sb): a line per problem (print-problems): "problem path=PATH line=L col=C end=L:C|-
#   severity=S code=CODE|- source=LABEL message=MESSAGE"
FN problems_dump
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + probs + VEC_len]
    jae 9f
    imul r13, rbx, PR_SIZE
    add r13, [rip + probs + VEC_ptr]
    inc rbx
    mov rdi, r12
    lea rsi, [rip + .Ld_path]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [r13 + PR_path]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ld_line]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [r13 + PR_line]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_col]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [r13 + PR_col]
    call sb_push_u64
    test dword ptr [r13 + PR_flags], PRF_CHARS
    jz 2f
    mov rdi, r12
    mov esi, 'c'
    call sb_push_byte
2:  mov rdi, r12
    lea rsi, [rip + .Ld_end]
    call sb_push_cstr
    cmp dword ptr [r13 + PR_endline], 0
    jne 3f
    mov rdi, r12
    mov esi, '-'
    call sb_push_byte
    jmp 4f
3:  mov rdi, r12
    mov esi, [r13 + PR_endline]
    call sb_push_u64
    mov rdi, r12
    mov esi, ':'
    call sb_push_byte
    mov rdi, r12
    mov esi, [r13 + PR_endcol]
    call sb_push_u64
4:  mov rdi, r12
    lea rsi, [rip + .Ld_sev]
    call sb_push_cstr
    mov eax, [r13 + PR_sev]
    lea rcx, [rip + .Ld_sevs]
    mov rsi, [rcx + rax*8]
    mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ld_code]
    call sb_push_cstr
    mov rsi, [r13 + PR_code]
    cmp byte ptr [rsi], 0
    jne 5f
    lea rsi, [rip + .Ld_dash]
5:  mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ld_source]
    call sb_push_cstr
    mov rax, [r13 + PR_src]
    mov rsi, [rax + PS_label]
    mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ld_message]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [r13 + PR_msg]
    call sb_push_cstr
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

.section .rodata
.Ltab_name: .asciz "problems"
.Ltab_title: .asciz "Problems"
.Ltab_none: .asciz "tab=none\n"
.Lnone: .asciz "No problems have been found."
.Lgap: .asciz "  "
.p2align 3
# the tab's callbacks (places.s: draw, key, focus, close, actions, visible) and its tree's (rtree.s)
tab_place_ops: .quad tab_draw, tab_key, 0, 0, 0, 0
tab_tree_ops: .quad tab_activate, 0, 0, 0, 0, 0, 0, 0
.Lempty: .asciz ""
.Ld_path: .asciz "problem path="
.Ld_line: .asciz " line="
.Ld_col: .asciz " col="
.Ld_end: .asciz " end="
.Ld_sev: .asciz " severity="
.Ld_code: .asciz " code="
.Ld_dash: .asciz "-"
.Ld_source: .asciz " source="
.Ld_message: .asciz " message="
.Ld_error: .asciz "error"
.Ld_warning: .asciz "warning"
.Ld_info: .asciz "info"
.Ld_hint: .asciz "hint"
.p2align 3
.Ld_sevs: .quad .Ld_error, .Ld_warning, .Ld_info, .Ld_hint
