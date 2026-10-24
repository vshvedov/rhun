# language features from extensions (docs/extensions/v1.md, 12d to 12h): Go to Definition, Find All
# References, Go to Symbol, code actions, rename and format. A query asks the providers, waits for
# their answers (state only while extproto's pump runs; the tick finishes it), then shows a list in
# the palette, goes to a place, or applies a workspace edit.
.include "rhun.inc"

.equ LF_DEF, 1
.equ LF_REFS, 2
.equ LF_SYMS, 3
.equ LF_ACTS, 4
.equ LF_RENAME, 5
.equ LF_FORMAT, 6
# language features of protocol 1.1 (navigation, partial-format)
.equ LF_DECL, 7
.equ LF_TYPEDEF, 8
.equ LF_IMPL, 9
.equ LF_RANGEFMT, 10
.equ LF_MAX, 10000              # locations or symbols in one answer
.equ LF_ACTS_MAX, 1000
.equ LF_BODY_MAX, 1048576
.equ LR_MAX, 64
.equ LA_AUTO, 1                 # Auto Fix: the one preferred quick fix, applied
.equ LA_ONE, 2                  # Organize Imports: one action that comes is applied
.equ LFD_RESULTS, 1             # where a query's locations go: the Results panel (references)
.equ LFD_PEEK, 2                # the peek view
.equ LF_WORD_MAX, 100
.equ WS_BODY_MAX, 4194304       # a workspace edit (12g)

# a request rhun waits on
STRUCT
F LR_ext, 8
F LR_id, 8
F LR_session, 4
F LR_pad, 4
F LR_language_revision, 8
ENDSTRUCT LR_SIZE

# a result: a location, a symbol or an action
STRUCT
F LS_ext, 8                     # who gave it (an action's data goes back to it)
F LS_path, 8                    # offset in lf_bytes of its path, a cstr ("#ID" for a document), or -1: the asked document
F LS_l1, 4
F LS_c1, 4
F LS_l2, 4
F LS_c2, 4
F LS_label, 8                   # offset of the palette's label (cstr)
F LS_detail, 8                  # offset of the detail (cstr), or -1
F LS_edit, 8                    # an action's workspace edit: offset and length
F LS_elen, 8
F LS_data, 8                    # and the bytes it sends back
F LS_dlen, 8
F LS_rank, 4                    # the order: lower first
F LS_flags, 4                   # LSF_*: a 1.1 code action's
F LS_cmd, 8                     # its command record (offset, length), length 0 for none
F LS_clen, 8
F LS_kind, 8                    # its kind's offset (a cstr)
ENDSTRUCT LS_SIZE

.equ LSF_PREFERRED, 1
.equ LSF_DISABLED, 2            # LS_detail is the reason
.equ LSF_RESOLVE, 4             # LS_data is resolve data (code-action-resolve), not v1's action data
.equ LSF_QUICKFIX, 8

.bss
.p2align 3
lf_kind: .long 0                # the query in flight (LF_*), 0 for none
lf_session: .long 0
lf_ready: .long 0               # every provider answered: the tick finishes it
lf_truncated: .long 0           # the query's cap cut it short (query-part)
lf_partial: .long 0             # its list was shown before every provider answered
lf_show_due: .long 0            # a part came for a kind shown at its first part
lf_act_mode: .long 0            # code actions: 0 list, LA_AUTO one preferred quick fix, LA_ONE one action
lf_act_kinds: .quad 0           # the kinds asked for (cstr), 0 for any
lf_rs_ext: .quad 0              # a code action's resolve request out: its extension, id, result
lf_rs_id: .quad 0
lf_rs_index: .quad 0
lf_rs_ready: .long 0            # its answer came (1 ok, 2 failed)
lf_rs_pad: .long 0
lf_rs_body: .zero SB_SIZE
lf_pr_ext: .quad 0              # prepare-rename out: its extension and id
lf_pr_id: .quad 0
lf_pr_start: .quad 0            # its answer's range in the document
lf_pr_end: .quad 0
lf_pr_state: .long 0            # 1 out, 2 answered, 3 refused, 4 failed
lf_pr_use: .long 0              # the prompt takes the range and the placeholder (in lf_name)
lf_pr_body: .zero SB_SIZE
lf_list_kind: .long 0           # what the palette's list shows
lf_auto: .long 0                # lf_actions_line builds the lightbulb's request
lf_next_dest: .long 0           # LFD_* for the next query (set by its command), 0: the palette
lf_dest: .long 0                # and for the query in flight
lf_word: .zero LF_WORD_MAX + 4  # the word at the cursor when it was asked (the Results title)
lf_doc: .quad 0                 # the document asked about, and its id
lf_doc_id: .quad 0
lf_language_revision: .quad 0
lf_ws_ext: .quad 0
lf_reqs: .zero VEC_SIZE         # LR records
lf_res: .zero VEC_SIZE          # LS records
lf_bytes: .zero SB_SIZE         # their strings
lf_ws: .zero SB_SIZE            # a workspace edit to apply (rename, format)
lf_line: .zero SB_SIZE          # a request being built
lf_line2: .zero SB_SIZE         # a provider's own request (code-actions, a resolve)
lf_dbuf: .zero SB_SIZE          # code-actions' DIAGS
la_flags: .long 0               # lf_action_extra's findings
la_pad: .long 0
la_resolve: .quad 0
la_rlen: .quad 0
la_cmd: .quad 0
la_clen: .quad 0
la_reason: .quad 0
la_reasonlen: .quad 0
lf_name: .zero SB_SIZE          # the new name of a rename
lf_err: .zero 256               # what the rename provider said instead
lf_wcmd: .zero SB_SIZE          # an action's command waiting for its edit's confirmation (wsedit's
lf_wcmd_ext: .quad 0            # list): the record, its extension and document
lf_wcmd_doc: .quad 0
.p2align 3
.p2align 3
lf_path: .zero 4100             # a path as a cstr

.text
.globl lf_head, lf_take, lf_four, lf_tmp4, lf_pos, lf_doc_ref, lf_is_abs, lf_msort   # wsedit.s reads with them
.globl lf_pos_near, lf_open_path, lf_focused_doc, lf_active_doc, lf_line_col, lf_path_ok   # results.s, peek.s, outline.s

# ---------------- helpers ----------------

# lf_focused_doc() -> rax g_doc when a document tab's editor has the keyboard, else 0; lf_active_doc()
# the same whoever has the keyboard
lf_focused_doc:
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 8f
lf_active_doc:
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 8f
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 7f
    mov rax, [rip + g_doc]
    ret
7:  cmp qword ptr [rax + TAB_kind], TAB_NOTEBOOK  # notebooks (A3): the cell being edited
    je nb_focus_cell
8:  xor eax, eax
    ret

# lf_is_word(byte) -> eax 1 for a letter, a digit, _ or a byte of a multibyte character
lf_is_word:
    cmp edi, 0x80
    jae 1f
    cmp edi, '_'
    je 1f
    mov eax, edi
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 26
    jb 1f
    mov eax, edi
    sub eax, '0'
    cmp eax, 10
    jb 1f
    xor eax, eax
    ret
1:  mov eax, 1
    ret

# lf_pos(doc, line, col) -> rax byte offset of a 1-based line and byte column, or -1 when it is not
# in the text (or inside a character)
lf_pos:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r12, r12
    jz 8f
    test r13, r13
    jz 8f
    cmp r12, [rbx + DOC_nlines]
    ja 8f
    dec r12
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov r14, rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    lea rcx, [r14 + r13 - 1]
    cmp rcx, rax
    ja 8f
    mov r15, rcx
    cmp rcx, rax
    je 1f                       # the line's end
    mov rdi, rbx
    mov rsi, rcx
    call doc_byte
    and eax, 0xc0
    cmp eax, 0x80
    je 8f
1:  mov rax, r15
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# lf_pos_near(doc, line, col) -> rax the offset of the nearest place in the text: a line past the
# end is the last, a column past the end of its line that end, inside a character its start
lf_pos_near:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r12, r12
    jnz 1f
    mov r12d, 1
1:  cmp r12, [rbx + DOC_nlines]
    jbe 2f
    mov r12, [rbx + DOC_nlines]
2:  test r13, r13
    jnz 3f
    mov r13d, 1
3:  dec r12
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov r14, rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    lea r15, [r14 + r13 - 1]
    cmp r15, rax
    jbe 4f
    mov r15, rax
4:  cmp r15, r14
    jbe 5f
    mov rdi, rbx
    mov rsi, r15
    call doc_byte
    and eax, 0xc0
    cmp eax, 0x80
    jne 5f
    dec r15
    jmp 4b
5:  mov rax, r15
    EPILOGUE

# lf_line_col(doc, pos) -> rax 1-based line, rdx 1-based byte column
lf_line_col:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call doc_line_of
    mov r13, rax
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov rdx, r12
    sub rdx, rax
    inc rdx
    lea rax, [r13 + 1]
    pop r13
    pop r12
    pop rbx
    ret

# lf_push_num(sb, n) and lf_push_sp(sb): a number, a space
lf_push_num:
    jmp sb_push_u64
lf_push_sp:
    mov esi, ' '
    jmp sb_push_byte

# lf_str(ptr, len) -> rax the offset in lf_bytes of a copy, as a cstr
lf_str:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    # a source inside lf_bytes moves when it grows: make room first, then find it again
    mov r14, -1
    mov rax, [rip + lf_bytes + SB_ptr]
    test rax, rax
    jz 1f
    cmp r12, rax
    jb 1f
    mov rcx, rax
    add rcx, [rip + lf_bytes + SB_cap]
    cmp r12, rcx
    jae 1f
    mov r14, r12
    sub r14, rax
1:  lea rdi, [rip + lf_bytes]
    lea rsi, [r13 + 1]
    call sb_reserve
    test r14, r14
    js 2f
    mov r12, [rip + lf_bytes + SB_ptr]
    add r12, r14
2:  mov rbx, [rip + lf_bytes + SB_len]
    lea rdi, [rip + lf_bytes]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + lf_bytes]
    xor esi, esi
    call sb_push_byte
    mov rax, rbx
    EPILOGUE

# lf_cancel_all(): "0 cancel ID" for the requests still out, and forget them
lf_cancel_all:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + lf_reqs + VEC_len]
    jae 2f
    imul rax, rbx, LR_SIZE
    add rax, [rip + lf_reqs + VEC_ptr]
    inc rbx
    mov rdi, [rax + LR_ext]
    mov rsi, [rax + LR_id]
    call query_withdraw
    jmp 1b
2:  mov qword ptr [rip + lf_reqs + VEC_len], 0
    EPILOGUE

# lf_reset(): the query before goes, and the list it showed
FN langfeat_provider_cancel
lf_reset:
    push rbx
    call lf_cancel_all
    call lf_rs_withdraw         # a code action's resolve belongs to the results that go
    call palette_results_close
    mov dword ptr [rip + lf_kind], 0
    mov dword ptr [rip + lf_ready], 0
    mov dword ptr [rip + lf_truncated], 0
    mov dword ptr [rip + lf_partial], 0
    mov dword ptr [rip + lf_show_due], 0
    mov dword ptr [rip + lf_list_kind], 0
    mov qword ptr [rip + lf_res + VEC_len], 0
    lea rdi, [rip + lf_bytes]
    call sb_clear
    lea rdi, [rip + lf_ws]
    call sb_clear
    mov byte ptr [rip + lf_err], 0
    pop rbx
    ret

# May run in a protocol reply: no output or session disposal here.
lf_language_current:
    PROLOGUE
    mov rdi, [rip + lf_doc_id]
    call extproto_doc
    test rax, rax
    jz 1f
    cmp rax, [rip + lf_doc]
    jne 1f
    mov rdi, rax
    mov rsi, [rip + lf_language_revision]
    call doc_language_matches
    EPILOGUE
1:  xor eax, eax
    EPILOGUE

# Normal tick only; keep queries created under the new language.
FN langfeat_language_changed
    push rdi
    call langextra_language_changed
    pop rdi
    mov rax, [rdi + DOC_id]
    cmp [rip + lf_doc_id], rax
    jne 1f
    mov rax, [rdi + DOC_language_revision]
    cmp [rip + lf_language_revision], rax
    jne langfeat_provider_cancel
1:  ret

# ---------------- asking ----------------

# lf_start(kind, chosen extension or 0): ask the focused document
FN langfeat_provider_start
lf_start:
    PROLOGUE 32
    mov [rsp + 16], rsi
    mov r12d, edi
    call lf_focused_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rbx
    call doc_sync_grammar
    test rax, rax
    js 9f
    mov rax, [rbx + DOC_language_revision]
    test rax, rax
    jz 9f
    mov [rip + lf_language_revision], rax
    call lf_reset
    mov [rip + lf_kind], r12d
    inc dword ptr [rip + lf_session]
    mov [rip + lf_doc], rbx
    mov eax, [rip + lf_next_dest]
    mov [rip + lf_dest], eax
    mov dword ptr [rip + lf_next_dest], 0
    mov rdi, rbx
    call lf_take_word
    mov rax, [rbx + DOC_id]
    mov [rip + lf_doc_id], rax
    # the request: VERB DOC VERSION, then what the kind takes
    lea rdi, [rip + lf_line]
    call sb_clear
    lea rax, [rip + lf_verbs]
    mov rsi, [rax + r12*8]
    lea rdi, [rip + lf_line]
    call sb_push_cstr
    lea rdi, [rip + lf_line]
    call lf_push_sp
    lea rdi, [rip + lf_line]
    mov rsi, [rbx + DOC_id]
    call lf_push_num
    lea rdi, [rip + lf_line]
    call lf_push_sp
    lea rdi, [rip + lf_line]
    mov rsi, [rbx + DOC_version]
    call lf_push_num
    lea rdi, [rip + lf_line]
    call lf_push_sp
    cmp r12d, LF_ACTS
    je 3f
    cmp r12d, LF_FORMAT
    je 4f
    cmp r12d, LF_RANGEFMT
    je 3f
    # LINE COL KIND CHAR: the cursor
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call lf_line_col
    mov [rsp], rdx
    lea rdi, [rip + lf_line]
    mov rsi, rax
    call lf_push_num
    lea rdi, [rip + lf_line]
    call lf_push_sp
    lea rdi, [rip + lf_line]
    mov rsi, [rsp]
    call lf_push_num
    lea rdi, [rip + lf_line]
    lea rsi, [rip + .Linvoked]
    call sb_push_cstr
    cmp r12d, LF_RENAME
    jne 21f
    lea rdi, [rip + lf_line]
    mov rsi, [rip + lf_name + SB_ptr]
    mov rdx, [rip + lf_name + SB_len]
    call sb_push
    jmp 5f
21: lea rdi, [rip + lf_line]
    mov esi, '-'
    call sb_push_byte
    jmp 5f
3:  # L1 C1 L2 C2: the selection, or the cursor
    mov rdi, rbx
    call ed_sel
    mov [rsp + 8], rdx
    mov rdi, rbx
    mov rsi, rax
    call lf_line_col
    mov [rsp], rdx
    lea rdi, [rip + lf_line]
    mov rsi, rax
    call lf_push_num
    lea rdi, [rip + lf_line]
    call lf_push_sp
    lea rdi, [rip + lf_line]
    mov rsi, [rsp]
    call lf_push_num
    lea rdi, [rip + lf_line]
    call lf_push_sp
    mov rdi, rbx
    mov rsi, [rsp + 8]
    call lf_line_col
    mov [rsp], rdx
    lea rdi, [rip + lf_line]
    mov rsi, rax
    call lf_push_num
    lea rdi, [rip + lf_line]
    call lf_push_sp
    lea rdi, [rip + lf_line]
    mov rsi, [rsp]
    call lf_push_num
    cmp r12d, LF_RANGEFMT
    jne 5f
    lea rdi, [rip + lf_line]
    call lf_push_sp
4:  # TAB_WIDTH SPACES: the document's own settings
    call ext_options_apply
    lea rdi, [rip + lf_line]
    mov esi, [rip + g_tab_width]
    call lf_push_num
    lea rdi, [rip + lf_line]
    call lf_push_sp
    lea rdi, [rip + lf_line]
    lea rsi, [rip + .Lyes]
    cmp dword ptr [rip + g_insert_spaces], 0
    jne 41f
    lea rsi, [rip + .Lno]
41: call sb_push_cstr
    cmp r12d, LF_RANGEFMT
    jne 5f
    mov rdi, rbx                # partial-format: TRIM FINAL, the document's own
    call lf_push_trim_final
5:  # to every provider of it whose patterns match (the first, for one-provider kinds)
    xor r13d, r13d
    mov dword ptr [rsp + 8], 0
6:  cmp r13, [rip + g_exts + VEC_len]
    jae 8f
    imul r14, r13, EXT_SIZE
    add r14, [rip + g_exts + VEC_ptr]
    inc r13
    cmp qword ptr [rsp + 16], 0
    je 61f
    cmp r14, [rsp + 16]
    jne 6b
61: mov rdi, r14
    call ext_is_visible
    test eax, eax
    jz 6b
    cmp dword ptr [r14 + EXT_status], ES_RUNNING
    jne 6b
    lea rax, [rip + lf_feats]
    mov esi, [rax + r12*4]
    mov rdi, r14
    call ext_feature
    test eax, eax
    jnz 64f
    cmp r12d, LF_ACTS
    jne 6b
    mov rdi, r14                # code actions: the 1.1 feature alone will do
    mov esi, FEAT_CODE_ACTIONS
    call ext_feature
    test eax, eax
    jz 6b
64:
    lea rax, [rip + lf_pvs]
    mov rsi, [rax + r12*8]
    mov rdi, r14
    call ext_pv
    mov rdi, rax
    mov rsi, rbx
    call extproto_matches
    test eax, eax
    jz 6b
    cmp qword ptr [rip + lf_reqs + VEC_len], LR_MAX
    jae 8f
    mov rdx, [rip + lf_line + SB_ptr]
    mov rcx, [rip + lf_line + SB_len]
    cmp r12d, LF_ACTS
    jne 62f
    mov rdi, r14                # code-actions: a 1.1 provider's own request
    mov esi, FEAT_CODE_ACTIONS
    call ext_feature
    test eax, eax
    jz 63f
    mov rdi, r14
    mov rsi, rbx
    call lf_actions_line
    mov rdx, [rip + lf_line2 + SB_ptr]
    mov rcx, [rip + lf_line2 + SB_len]
    jmp 62f
63: cmp qword ptr [rip + lf_act_kinds], 0
    jne 6b                      # a kind asked for: v1 providers have no kinds
    mov rdx, [rip + lf_line + SB_ptr]
    mov rcx, [rip + lf_line + SB_len]
62: mov rdi, r14
    mov rsi, rbx
    call extproto_host_send
    test rax, rax
    jz 6b
    mov r15, rax
    mov rdi, r14                # its kind's limits and statistics (query.s)
    mov rsi, r15
    lea rax, [rip + lf_pks]
    mov edx, [rax + r12*4]
    mov ecx, QO_LANGFEAT
    call query_track
    lea rdi, [rip + lf_reqs]
    mov esi, LR_SIZE
    call vec_push
    mov [rax + LR_ext], r14
    mov [rax + LR_id], r15
    mov ecx, [rip + lf_session]
    mov [rax + LR_session], ecx
    mov rcx, [rbx + DOC_language_revision]
    mov [rax + LR_language_revision], rcx
    inc dword ptr [rsp + 8]
    lea rax, [rip + lf_single]
    cmp byte ptr [rax + r12], 0
    je 6b
8:  cmp dword ptr [rsp + 8], 0
    jne 9f
    # nobody to ask
    mov dword ptr [rip + lf_kind], 0
    lea rax, [rip + lf_none]
    mov rdi, [rax + r12*8]
    call app_toast
9:  EPILOGUE

FN cmd_definition
    mov edi, LF_DEF
    jmp lf_start_cmd
FN cmd_references
    mov dword ptr [rip + lf_next_dest], LFD_RESULTS   # the Results panel (language-features 1.5)
    mov edi, LF_REFS
    jmp lf_start_cmd
FN cmd_symbols
    call ed_single              # one selection (multi-cursor)
    mov edi, LF_SYMS
    xor esi, esi
    jmp ext_provider_begin
FN cmd_code_actions
    xor esi, esi
    xor edx, edx
lf_actions_cmd:                 # esi kinds cstr or 0, edx LA_* mode
    mov [rip + lf_act_kinds], rsi
    mov [rip + lf_act_mode], edx
    mov edi, LF_ACTS
    jmp lf_start_cmd
# code-actions (protocol 1.1): the actions of a kind
FN cmd_quick_fix_auto
    lea rsi, [rip + .Lk_quickfix]
    mov edx, LA_AUTO
    jmp lf_actions_cmd
FN cmd_quick_fix                # the quick fixes listed (the lightbulb's click)
    lea rsi, [rip + .Lk_quickfix]
    xor edx, edx
    jmp lf_actions_cmd
FN cmd_organize_imports
    lea rsi, [rip + .Lk_organize]
    mov edx, LA_ONE
    jmp lf_actions_cmd
FN cmd_fix_all
    lea rsi, [rip + .Lk_fixall]
    mov edx, LA_ONE
    jmp lf_actions_cmd
FN cmd_refactor
    lea rsi, [rip + .Lk_refactor]
    xor edx, edx
    jmp lf_actions_cmd
FN cmd_source_action
    lea rsi, [rip + .Lk_source]
    xor edx, edx
    jmp lf_actions_cmd
# navigation (protocol 1.1)
FN cmd_declaration
    mov edi, LF_DECL
    jmp lf_start_cmd
# the peek view (peek.s): the same queries, their locations under the cursor's line
# FN cmd_cancel_query(): the providers still searching are withdrawn ("0 cancel"); what came is
# shown as when they all answered
FN cmd_cancel_query
    cmp dword ptr [rip + lf_kind], 0
    je 1f
    push rbx
    call lf_cancel_all
    mov dword ptr [rip + lf_ready], 1
    mov dword ptr [rip + g_dirty], 1
    pop rbx
1:  ret
# FN langfeat_escape() -> eax 1 when Escape in the editor cancelled a language query still out (the
# query in flight, or a hierarchy's roots); 0 leaves Escape to the editor
FN langfeat_escape
    cmp dword ptr [rip + lf_kind], 0
    je 1f
    cmp dword ptr [rip + lf_ready], 0
    jne 1f
    push rbx
    call cmd_cancel_query
    pop rbx
    mov eax, 1
    ret
1:  jmp results_cancel_roots
FN cmd_peek_definition
    mov edi, LF_DEF
    jmp lf_peek_cmd
FN cmd_peek_declaration
    mov edi, LF_DECL
    jmp lf_peek_cmd
FN cmd_peek_type_definition
    mov edi, LF_TYPEDEF
    jmp lf_peek_cmd
FN cmd_peek_implementation
    mov edi, LF_IMPL
    jmp lf_peek_cmd
FN cmd_peek_references
    mov edi, LF_REFS
lf_peek_cmd:
    mov dword ptr [rip + lf_next_dest], LFD_PEEK
    jmp lf_start_cmd
FN cmd_type_definition
    mov edi, LF_TYPEDEF
    jmp lf_start_cmd
FN cmd_implementation
    mov edi, LF_IMPL
    jmp lf_start_cmd
# partial-format: shift+alt+f with a selection, when a range formatter exists, and the command
FN cmd_format_selection
    mov edi, LF_RANGEFMT
    xor esi, esi
    jmp ext_provider_begin
FN cmd_format_document
    call lf_range_format_first
    test eax, eax
    jnz cmd_format_selection
    mov edi, LF_FORMAT
    xor esi, esi
    jmp ext_provider_begin
lf_start_cmd:
    push rbx
    mov ebx, edi
    call ed_single              # about one place (multi-cursor)
    call ext_provider_cancel
    call palette_provider_close
    mov edi, ebx
    xor esi, esi
    call lf_start
    pop rbx
    ret

# FN langfeat_rename_start() -> eax 1 when the focused document has a rename provider: the palette
# asks for the new name, the word under the cursor filled in (F2 renames the file otherwise)
FN langfeat_rename_start
    call ed_single              # one selection (multi-cursor)
    mov edi, LF_RENAME
    xor esi, esi
    jmp ext_provider_begin

FN langfeat_rename_prompt
    PROLOGUE 16
    mov rbx, [rip + g_doc]
    cmp dword ptr [rip + lf_pr_use], 0
    je 1f
    # prepare-rename's answer: its range selected, its placeholder in the prompt
    mov dword ptr [rip + lf_pr_use], 0
    mov rax, [rip + lf_pr_start]
    mov [rbx + DOC_anchor], rax
    mov rax, [rip + lf_pr_end]
    mov [rbx + DOC_cur], rax
    call ed_touch
    mov r13, [rip + lf_name + SB_len]
    jmp 7f
1:  # the word under the cursor
    mov r12, [rbx + DOC_cur]
2:  test r12, r12
    jz 3f
    lea rsi, [r12 - 1]
    mov rdi, rbx
    call doc_byte
    mov edi, eax
    call lf_is_word
    test eax, eax
    jz 3f
    dec r12
    jmp 2b
3:  mov r13, [rbx + DOC_cur]
    mov rdi, rbx
    call doc_len
    mov r14, rax
4:  cmp r13, r14
    jae 5f
    mov rdi, rbx
    mov rsi, r13
    call doc_byte
    mov edi, eax
    call lf_is_word
    test eax, eax
    jz 5f
    inc r13
    jmp 4b
5:  sub r13, r12
    cmp r13, 200
    jbe 6f
    xor r13d, r13d              # not a word anyone renames
6:  lea rdi, [rip + lf_name]
    call sb_clear
    lea rdi, [rip + lf_name]
    mov rsi, r13
    call sb_reserve
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, rax
    call doc_copy
    mov [rip + lf_name + SB_len], r13
7:  lea rdi, [rip + .Lrename_to]
    mov esi, PROMPT_RENAME_SYMBOL
    mov rdx, [rip + lf_name + SB_ptr]
    mov rcx, r13
    call palette_ext_prompt_open
    call palette_field
    mov rdi, rax
    call tf_select_all
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- prepare-rename (protocol 1.1) ----------------

# FN langfeat_prepare_send(ext) -> eax 1 when "ID prepare-rename DOC VERSION LINE COL invoked -"
# went out about the focused document
FN langfeat_prepare_send
    PROLOGUE
    mov rbx, rdi
    mov qword ptr [rip + lf_pr_ext], 0
    mov dword ptr [rip + lf_pr_state], 0
    mov dword ptr [rip + lf_pr_use], 0
    mov r12, [rip + g_doc]
    test r12, r12
    jz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lv_prepare]
    mov rdx, r12
    lea rcx, [rip + .Lk_invoked_word]
    mov r8d, '-'
    call extproto_host_request
    test rax, rax
    jz 8f
    mov [rip + lf_pr_id], rax
    mov [rip + lf_pr_ext], rbx
    mov dword ptr [rip + lf_pr_state], 1
    mov rdi, rbx
    mov rsi, rax
    mov edx, PK_PREPARE_RENAME
    mov ecx, QO_LANGFEAT
    call query_track
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# lf_pr_reply(ext, id, ok, body, len) -> eax 1 when it answered prepare-rename (from the pump):
# ok with "L1 C1 L2 C2 PLEN" LF placeholder, ok 0 (the word at the cursor), refused TEXT
lf_pr_reply:
    cmp rdi, [rip + lf_pr_ext]
    jne 8f
    cmp rsi, [rip + lf_pr_id]
    jne 8f
    test rdi, rdi
    jz 8f
    push rbx
    push r12
    push r13
    mov ebx, edx
    mov r12, rcx
    mov r13, r8
    mov qword ptr [rip + lf_pr_ext], 0
    lea rdi, [rip + lf_pr_body]
    call sb_clear
    lea rdi, [rip + lf_pr_body]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov dword ptr [rip + lf_pr_state], 2
    test ebx, ebx
    jnz 1f
    mov dword ptr [rip + lf_pr_state], 4    # failed: the word at the cursor
    cmp r13, 8
    jb 1f
    cmp dword ptr [r12], 0x75666572         # "refu"
    jne 1f
    cmp dword ptr [r12 + 4], 0x20646573     # "sed "
    jne 1f
    mov dword ptr [rip + lf_pr_state], 3
1:  mov dword ptr [rip + g_dirty], 1
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# FN langfeat_prepare_state() -> eax 0 while prepare-rename is out, 1 when the prompt opens (with
# the answer's range selected and its placeholder, when it gave them), 2 when it refused (the
# reason is shown)
FN langfeat_prepare_state
    PROLOGUE
    mov eax, [rip + lf_pr_state]
    cmp eax, 1
    jbe 0f
    mov dword ptr [rip + lf_pr_state], 0
    cmp eax, 3
    je .Lps_refused
    cmp eax, 2
    jne 7f
    # "L1 C1 L2 C2 PLEN" LF placeholder, the range in the document as it is
    mov rax, [rip + lf_pr_body + SB_ptr]
    mov [rip + ps_ptr], rax
    add rax, [rip + lf_pr_body + SB_len]
    mov [rip + ps_end], rax
    call ps_line
    test eax, eax
    jz 7f
    call lf_four
    test eax, eax
    jz 7f
    call ps_num
    test edx, edx
    jz 7f
    cmp rax, 200
    ja 7f
    mov r12, rax
    call ps_eol
    test eax, eax
    jz 7f
    mov rax, [rip + ps_end]
    sub rax, [rip + ps_ptr]
    cmp rax, r12
    jne 7f
    mov rdi, [rip + ps_ptr]
    mov rsi, r12
    call lf_one_line
    test eax, eax
    jz 7f
    mov rbx, [rip + g_doc]
    lea rcx, [rip + lf_tmp4]
    mov rdi, rbx
    mov esi, [rcx]
    mov edx, [rcx + 4]
    call lf_pos
    test rax, rax
    js 7f
    mov r13, rax
    lea rcx, [rip + lf_tmp4]
    mov rdi, rbx
    mov esi, [rcx + 8]
    mov edx, [rcx + 12]
    call lf_pos
    test rax, rax
    js 7f
    cmp rax, r13
    jb 7f
    mov [rip + lf_pr_start], r13
    mov [rip + lf_pr_end], rax
    lea rdi, [rip + lf_name]
    call sb_clear
    lea rdi, [rip + lf_name]
    mov rsi, [rip + ps_ptr]
    mov rdx, r12
    call sb_push
    mov dword ptr [rip + lf_pr_use], 1
7:  mov eax, 1
    EPILOGUE
0:  xor eax, eax
    EPILOGUE
.Lps_refused:
    # "refused TEXT": TEXT for the user, cut at 200 bytes
    mov rsi, [rip + lf_pr_body + SB_ptr]
    mov rcx, [rip + lf_pr_body + SB_len]
    add rsi, 8
    sub rcx, 8
    cmp rcx, 200
    jbe 1f
    mov ecx, 200
1:  lea rdi, [rip + lf_err]
    mov rdx, rcx
    push rcx
    push rcx
    call memcpy
    pop rcx
    pop rcx
    lea rax, [rip + lf_err]
    mov byte ptr [rax + rcx], 0
    lea rdi, [rip + lf_err]
    cmp byte ptr [rdi], 0
    jne 2f
    lea rdi, [rip + .Lnothing_renamed]
2:  call app_toast
    mov eax, 2
    EPILOGUE

# lf_one_line(ptr, len) -> eax 1 when the bytes hold no line break
lf_one_line:
    test rsi, rsi
    jz 9f
    movzx eax, byte ptr [rdi]
    cmp eax, 10
    je 8f
    cmp eax, 13
    je 8f
    inc rdi
    dec rsi
    jmp lf_one_line
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# FN langfeat_rename_to(ptr, len): the palette's answer: the new name, then the request
FN langfeat_rename_to
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call ext_provider_rename_take
    test rax, rax
    jz 9f
    mov r14, rax
    test r13, r13
    jz 9f
    xor ecx, ecx
1:  cmp rcx, r13
    jae 2f
    movzx eax, byte ptr [r12 + rcx]
    inc rcx
    cmp eax, ' '
    ja 1b
    lea rdi, [rip + .Lname_spaces]
    call app_toast
    jmp 9f
2:  lea rdi, [rip + lf_name]
    call sb_clear
    lea rdi, [rip + lf_name]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov edi, LF_RENAME
    mov rsi, r14
    call lf_start
9:  EPILOGUE

# ---------------- answers ----------------

# FN langfeat_reply(ext, id, ok, body, len): an extension answered (from extproto's pump: state
# only; an error's body is its CODE TEXT)
FN langfeat_reply
    PROLOGUE 16
    # the askers with their own requests first: code action resolve, prepare-rename, on-type and
    # paste formatting, the Results panel's hierarchies
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push r8
    lea rax, [rip + lf_chain]
    mov [rsp + 48], rax
80: mov rax, [rsp + 48]
    mov rax, [rax]
    test rax, rax
    jz 0f
    mov rdi, [rsp + 40]
    mov rsi, [rsp + 32]
    mov rdx, [rsp + 24]
    mov rcx, [rsp + 16]
    mov r8, [rsp + 8]
    call rax
    test eax, eax
    jnz 0f
    add qword ptr [rsp + 48], 8
    jmp 80b
0:  pop r8
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    test eax, eax
    jnz 9f
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov r14, rcx
    mov r15, r8
    xor r13d, r13d
1:  cmp r13, [rip + lf_reqs + VEC_len]
    jae 9f
    imul rax, r13, LR_SIZE
    add rax, [rip + lf_reqs + VEC_ptr]
    cmp [rax + LR_ext], rbx
    jne 2f
    cmp [rax + LR_id], r12
    je 3f
2:  inc r13
    jmp 1b
3:  mov ecx, [rax + LR_session]
    mov [rsp + 4], ecx
    mov rcx, [rax + LR_language_revision]
    mov [rsp + 8], rcx
    # its record goes
    mov rax, [rip + lf_reqs + VEC_len]
    dec rax
    mov [rip + lf_reqs + VEC_len], rax
    sub rax, r13
    jz 4f
    imul rdx, rax, LR_SIZE
    imul rsi, r13, LR_SIZE
    add rsi, [rip + lf_reqs + VEC_ptr]
    mov rdi, rsi
    add rsi, LR_SIZE
    call memmove
4:  mov rdi, rbx
    call ext_is_visible
    test eax, eax
    jz 9f
    mov eax, [rsp + 4]
    cmp eax, [rip + lf_session]
    jne 9f
    mov rax, [rsp + 8]
    cmp rax, [rip + lf_language_revision]
    jne 9f
    call lf_language_current
    test eax, eax
    jz 9f
    mov eax, [rip + lf_kind]
    test eax, eax
    jz 9f
    cmp dword ptr [rsp], 0
    je 6f
    cmp eax, LF_SYMS
    je 51f
    cmp eax, LF_ACTS
    je 52f
    cmp eax, LF_RENAME
    je 53f
    cmp eax, LF_FORMAT
    je 53f
    cmp eax, LF_RANGEFMT
    je 53f
    # after parts, the query's caps count the rest too (query_final_room)
    call query_final_room
    mov [rsp + 8], rax
    test rax, rax
    js 50f
    cmp r15, rdx
    ja 54f
50: mov r13, [rip + lf_res + VEC_len]
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call lf_parse_locations
    test rax, rax
    js 54f
    mov rcx, [rsp + 8]
    test rcx, rcx
    js 7f
    cmp rax, rcx
    jbe 7f
    add r13, rcx                # what fits is kept
    mov [rip + lf_res + VEC_len], r13
    mov dword ptr [rip + lf_truncated], 1
    jmp 7f
51: mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    mov r13, [rip + lf_res + VEC_len]
    call lf_parse_symbols
    jmp 55f
52: mov r13, [rip + lf_res + VEC_len]
    mov rdi, rbx
    mov esi, FEAT_CODE_ACTIONS
    call ext_feature
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    test eax, eax
    jz 56f
    call lf_parse_actions2      # code-actions: the 1.1 grammar
    jmp 55f
56: call lf_parse_actions
55: # a body with records whose answer left none broke the rules (query.s counts it dropped)
    cmp [rip + lf_res + VEC_len], r13
    jne 7f
    mov rdi, r14
    mov rsi, r15
    call lf_body_empty
    test eax, eax
    jnz 7f
54: mov eax, [rip + lf_kind]
    lea rcx, [rip + lf_pks]
    mov esi, [rcx + rax*4]
    mov rdi, rbx
    call query_dropped
    jmp 7f
53: # rename, format: the workspace edit, applied when the query finishes
    cmp r15, WS_BODY_MAX
    ja 7f
    lea rdi, [rip + lf_ws]
    call sb_clear
    lea rdi, [rip + lf_ws]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    mov [rip + lf_ws_ext], rbx
    jmp 7f
6:  # an error: a rename's "refused TEXT" is the user's to read (other codes say nothing to them)
    cmp eax, LF_RENAME
    jne 7f
    cmp r15, 8
    jb 7f
    cmp dword ptr [r14], 0x75666572       # "refu"
    jne 7f
    cmp dword ptr [r14 + 4], 0x20646573   # "sed "
    jne 7f
62: test r15, r15
    jz 7f
    dec r15
    movzx eax, byte ptr [r14]
    inc r14
    cmp eax, ' '
    jne 62b
    mov rcx, r15
    cmp rcx, 200
    jbe 61f
    mov ecx, 200
61: lea rdi, [rip + lf_err]
    mov rsi, r14
    mov rdx, rcx
    push rcx
    push rcx
    call memcpy
    pop rcx
    pop rcx
    lea rax, [rip + lf_err]
    mov byte ptr [rax + rcx], 0
7:  # the last answer of the session: the tick finishes the query
    xor ecx, ecx
71: cmp rcx, [rip + lf_reqs + VEC_len]
    jae 72f
    imul rax, rcx, LR_SIZE
    add rax, [rip + lf_reqs + VEC_ptr]
    inc rcx
    mov edx, [rax + LR_session]
    cmp edx, [rip + lf_session]
    je 9f
    jmp 71b
72: mov dword ptr [rip + lf_ready], 1
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# lf_body_empty(body, len) -> eax 1 for no bytes or a count of 0
lf_body_empty:
    test rsi, rsi
    jz 1f
    cmp byte ptr [rdi], '0'
    jne 8f
    cmp rsi, 1
    je 1f
    cmp byte ptr [rdi + 1], 10
    je 1f
8:  xor eax, eax
    ret
1:  mov eax, 1
    ret

# FN langfeat_part(ext, id, body, len) -> rax the records taken from a part of a pending request's
# answer (query-part, from extproto's pump: state only), or -1 when it breaks the rules
FN langfeat_part
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    xor ecx, ecx
1:  cmp rcx, [rip + lf_reqs + VEC_len]
    jae 8f
    imul rax, rcx, LR_SIZE
    add rax, [rip + lf_reqs + VEC_ptr]
    inc rcx
    cmp [rax + LR_ext], rbx
    jne 1b
    cmp [rax + LR_id], r12
    jne 1b
    mov ecx, [rax + LR_session]
    cmp ecx, [rip + lf_session]
    jne 8f
    call lf_language_current
    test eax, eax
    jz 8f
    mov eax, [rip + lf_kind]
    call lf_is_locations
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call lf_parse_locations
    mov dword ptr [rip + g_dirty], 1
    test rax, rax
    jle 9f
    # a kind shown at its first part (references, implementation): the tick shows what came
    mov r12, rax
    mov eax, [rip + lf_kind]
    lea rcx, [rip + lf_pks]
    mov edi, [rcx + rax*4]
    call query_kind_first
    test eax, eax
    jz 1f
    mov dword ptr [rip + lf_show_due], 1
1:  mov rax, r12
9:  EPILOGUE
8:  mov rdi, rbx                # not ours: a hierarchy row's children (results.s)?
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call results_part
    cmp rax, -2
    jne 9b
    mov rdi, rbx                # or a symbol query's (wsym.s)
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call wsym_part
    cmp rax, -2
    jne 9b
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call definitionlink_part
    cmp rax, -2
    jne 9b
    xor eax, eax                # an answer nobody waits for any more: taken, and dropped
    EPILOGUE

# FN langfeat_truncated(ext, id): the query's cap cut that request short: what came is kept
FN langfeat_truncated
    mov dword ptr [rip + lf_truncated], 1
    ret

# lf_check_lines(body, len, n_max) -> eax N when the body starts with "N LF" (N at most n_max), with
# ps_ptr past that line; -1 otherwise
lf_head:
    PROLOGUE
    mov rbx, rdx
    mov [rip + ps_ptr], rdi
    lea rax, [rdi + rsi]
    mov [rip + ps_end], rax
    call ps_line
    test eax, eax
    jz 8f
    call ps_num
    test edx, edx
    jz 8f
    cmp rax, rbx
    ja 8f
    mov r12, rax
    call ps_eol
    test eax, eax
    jz 8f
    mov rax, r12
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# lf_take(n) -> rax ptr of the next n bytes of the body (ps_ptr moves past them), or 0 when there are
# not that many
# lf_path_ok(ptr, len) -> eax 1 for "#DOC" or an absolute path without NUL or line breaks
.globl lf_path_ok
lf_path_ok:
    test rsi, rsi
    jz 8f
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 2f
    movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz 8f
    cmp eax, 10
    je 8f
    cmp eax, 13
    je 8f
    inc rcx
    jmp 1b
2:  cmp byte ptr [rdi], '#'
    jne 3f
    cmp rsi, 2
    jb 8f
    cmp rsi, 19
    ja 8f
    mov ecx, 1
21: cmp rcx, rsi
    jae 9f
    movzx eax, byte ptr [rdi + rcx]
    sub eax, '0'
    cmp eax, 9
    ja 8f
    inc rcx
    jmp 21b
3:  cmp byte ptr [rdi], '/'
    je 9f
.ifdef WINDOWS
    cmp byte ptr [rdi], 92
    je 9f
    cmp rsi, 3
    jb 8f
    cmp byte ptr [rdi + 1], ':'
    jne 8f
    cmp byte ptr [rdi + 2], '/'
    je 9f
    cmp byte ptr [rdi + 2], 92
    je 9f
.endif
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# lf_is_abs(cstr) -> eax 1 for an absolute path
lf_is_abs:
    push rbx
    mov rbx, rdi
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call lf_path_ok
    cmp byte ptr [rbx], '#'
    jne 1f
    xor eax, eax
1:  pop rbx
    ret

# lf_doc_ref(cstr "#DIGITS") -> rax the document id, -1 when it is not one
lf_doc_ref:
    push rbx
    mov rbx, rdi
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call lf_path_ok
    test eax, eax
    jz 8f
    cmp byte ptr [rbx], '#'
    jne 8f
    xor eax, eax
    lea rcx, [rbx + 1]
1:  movzx edx, byte ptr [rcx]
    test edx, edx
    jz 9f
    sub edx, '0'
    imul rax, rax, 10
    add rax, rdx
    inc rcx
    jmp 1b
8:  mov rax, -1
9:  pop rbx
    ret

lf_take:
    mov rax, [rip + ps_end]
    sub rax, [rip + ps_ptr]
    cmp rdi, rax
    ja 8f
    mov rax, [rip + ps_ptr]
    add [rip + ps_ptr], rdi
    ret
8:  xor eax, eax
    ret

# lf_four() -> eax 1 with the next four numbers in lf_tmp4 (dwords)
lf_four:
    push rbx
    xor ebx, ebx
1:  cmp ebx, 4
    jae 2f
    call ps_num
    test edx, edx
    jz 8f
    cmp rax, 0x7fffffff
    jbe 11f
    mov eax, 0x7fffffff         # past any line or column (and not wrapped into the text)
11:
    lea rcx, [rip + lf_tmp4]
    mov [rcx + rbx*4], eax
    inc ebx
    jmp 1b
2:  mov eax, 1
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret

# lf_rollback(results, bytes): an answer that broke the rules leaves nothing behind
lf_rollback:
    mov [rip + lf_res + VEC_len], rdi
    mov [rip + lf_bytes + SB_len], rsi
    ret

# lf_parse_locations(ext, body, len) -> rax the records taken, or -1 when the body breaks the rules
# (nothing is taken): "N", then L1 C1 L2 C2 PATH_LEN TEXT_LEN and the bytes
lf_parse_locations:
    PROLOGUE 48
    mov [rsp], rdi
    mov rax, [rip + lf_res + VEC_len]
    mov [rsp + 8], rax
    mov rax, [rip + lf_bytes + SB_len]
    mov [rsp + 16], rax
    cmp rdx, LF_BODY_MAX
    ja 8f
    mov rdi, rsi
    mov rsi, rdx
    mov edx, LF_MAX
    call lf_head
    test rax, rax
    js 8f
    mov r15, rax
1:  test r15, r15
    jz 7f
    dec r15
    call ps_line
    test eax, eax
    jz 8f
    call lf_four
    test eax, eax
    jz 8f
    call ps_num
    test edx, edx
    jz 8f
    test rax, rax
    jz 8f                       # a location has a path
    cmp rax, 4096
    ja 8f
    mov r12, rax
    call ps_num
    test edx, edx
    jz 8f
    mov r13, rax
    call ps_eol
    test eax, eax
    jz 8f
    mov rdi, r12
    call lf_take
    test rax, rax
    jz 8f
    mov r14, rax                # the path
    mov rdi, r14
    mov rsi, r12
    call lf_path_ok
    test eax, eax
    jz 8f
    mov rdi, r13
    call lf_take
    test rax, rax
    jz 8f
    mov rbx, rax                # the preview
    # the record: its path, its label "name:line  preview", the folder as its detail
    mov rdi, r14
    mov rsi, r12
    call lf_str
    mov [rsp + 24], rax
    mov rdi, rbx
    mov rsi, r13
    call lf_location_label
    mov [rsp + 32], rax
    mov [rsp + 40], rdx
    lea rdi, [rip + lf_res]
    mov esi, LS_SIZE
    call vec_push
    mov rcx, [rsp]
    mov [rax + LS_ext], rcx
    mov rcx, [rsp + 24]
    mov [rax + LS_path], rcx
    lea rcx, [rip + lf_tmp4]
    mov edx, [rcx]
    mov [rax + LS_l1], edx
    mov edx, [rcx + 4]
    mov [rax + LS_c1], edx
    mov edx, [rcx + 8]
    mov [rax + LS_l2], edx
    mov edx, [rcx + 12]
    mov [rax + LS_c2], edx
    mov rcx, [rsp + 32]
    mov [rax + LS_label], rcx
    mov rcx, [rsp + 40]
    mov [rax + LS_detail], rcx
    jmp 1b
7:  # all of the body was the N records: nothing after them
    mov rax, [rip + ps_ptr]
    cmp rax, [rip + ps_end]
    jne 8f
    mov rax, [rip + lf_res + VEC_len]
    sub rax, [rsp + 8]
    EPILOGUE
8:  mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call lf_rollback
    mov rax, -1
    EPILOGUE

# lf_location_label(preview, len) -> rax the label's offset ("name:line  preview"), rdx the
# detail's (the folder) for the location whose path offset is at [rsp + 24 + 16 + 8] of the caller
# and its first line in lf_tmp4
lf_location_label:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov rax, [rbp + 16 + 24]    # the caller's path offset
    add rax, [rip + lf_bytes + SB_ptr]
    mov rbx, rax                # the path (cstr; lf_bytes does not move until the next push)
    mov rdi, rax
    call strlen
    mov r14, rax
    # the name: after the last / or \\
    mov r15, r14
1:  test r15, r15
    jz 2f
    movzx eax, byte ptr [rbx + r15 - 1]
    cmp eax, '/'
    je 2f
    cmp eax, '\\'
    je 2f
    dec r15
    jmp 1b
2:  # the label, built in lf_line then copied in (lf_bytes moves as it grows)
    lea rdi, [rip + lf_line]
    call sb_clear
    lea rdi, [rip + lf_line]
    lea rsi, [rbx + r15]
    mov rdx, r14
    sub rdx, r15
    call sb_push
    lea rdi, [rip + lf_line]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + lf_line]
    mov esi, [rip + lf_tmp4]
    call sb_push_u64
    lea rdi, [rip + lf_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + lf_line]
    mov esi, ' '
    call sb_push_byte
    # the preview without its indentation or line breaks, at most 200 bytes
30: test r13, r13
    jz 33f
    movzx eax, byte ptr [r12]
    cmp eax, ' '
    je 34f
    cmp eax, 9
    jne 33f
34: inc r12
    dec r13
    jmp 30b
33: xor ecx, ecx
3:  cmp rcx, r13
    jae 4f
    cmp rcx, 200
    jae 4f
    movzx esi, byte ptr [r12 + rcx]
    cmp esi, 10
    je 31f
    cmp esi, 13
    je 31f
    cmp esi, 9
    jne 32f
31: mov esi, ' '
32: push rcx
    push rcx
    lea rdi, [rip + lf_line]
    call sb_push_byte
    pop rcx
    pop rcx
    inc rcx
    jmp 3b
4:  # the folder, relative to the project when inside it
    mov [rsp], r15
    mov rdi, [rip + lf_line + SB_ptr]
    mov rsi, [rip + lf_line + SB_len]
    call lf_str
    mov [rsp + 8], rax
    mov rax, [rbp + 16 + 24]
    add rax, [rip + lf_bytes + SB_ptr]
    mov rbx, rax
    mov r15, [rsp]
    test r15, r15
    jz 6f
    dec r15                     # without the separator
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 5f
    call strlen
    cmp rax, r15
    ja 5f
    mov rdi, rbx
    mov rsi, [rip + g_project]
    mov rdx, rax
    push rax
    push rax
    call str_starts_raw
    pop rcx
    pop rcx
    test eax, eax
    jz 5f
    cmp rcx, r15
    je 6f                       # the project's own folder: no detail
    cmp byte ptr [rbx + rcx], '/'
    je 51f
    cmp byte ptr [rbx + rcx], '\\'
    jne 5f
51: lea rdi, [rbx + rcx + 1]
    mov rsi, r15
    sub rsi, rcx
    dec rsi
    jmp 52f
5:  mov rdi, rbx
    mov rsi, r15
52: call lf_str
    mov rdx, rax
    mov rax, [rsp + 8]
    EPILOGUE
6:  mov rax, [rsp + 8]
    mov rdx, -1
    EPILOGUE

# str_starts_raw(s, prefix, n) -> eax 1 when s begins with the n bytes of prefix
str_starts_raw:
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 9f
    movzx eax, byte ptr [rdi + rcx]
    cmp al, [rsi + rcx]
    jne 8f
    inc rcx
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# lf_parse_symbols(ext, body, len): "N", then L1 C1 L2 C2 KIND DEPTH NAME_LEN DETAIL_LEN and bytes
lf_parse_symbols:
    PROLOGUE 48
    mov [rsp], rdi
    mov rax, [rip + lf_res + VEC_len]
    mov [rsp + 8], rax
    mov rax, [rip + lf_bytes + SB_len]
    mov [rsp + 16], rax
    cmp rdx, LF_BODY_MAX
    ja 8f
    mov rdi, rsi
    mov rsi, rdx
    mov edx, LF_MAX
    call lf_head
    test rax, rax
    js 8f
    mov r15, rax
1:  test r15, r15
    jz 7f
    dec r15
    call ps_line
    test eax, eax
    jz 8f
    call lf_four
    test eax, eax
    jz 8f
    call ps_word                # the kind
    test rdx, rdx
    jz 8f
    cmp rdx, 40
    ja 8f
    mov [rsp + 24], rax
    mov [rsp + 32], rdx
    call ps_num                 # the depth
    test edx, edx
    jz 8f
    cmp rax, 40
    jbe 11f
    mov eax, 40
11: mov rbx, rax
    call ps_num
    test edx, edx
    jz 8f
    test rax, rax
    jz 8f
    cmp rax, 1000
    ja 8f
    mov r12, rax                # the name's length
    call ps_num
    test edx, edx
    jz 8f
    cmp rax, 1000
    ja 8f
    mov r13, rax                # the detail's
    call ps_eol
    test eax, eax
    jz 8f
    mov rdi, r12
    call lf_take
    test rax, rax
    jz 8f
    mov r14, rax
    mov rdi, r13
    call lf_take
    test rax, rax
    jz 8f
    mov [rsp + 40], rax
    # the label: two spaces a level, then the name; the detail: the kind and the provider's detail
    lea rdi, [rip + lf_line]
    call sb_clear
2:  test rbx, rbx
    jz 3f
    dec rbx
    lea rdi, [rip + lf_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + lf_line]
    mov esi, ' '
    call sb_push_byte
    jmp 2b
3:  lea rdi, [rip + lf_line]
    mov rsi, r14
    mov rdx, r12
    call sb_push
    mov rdi, [rip + lf_line + SB_ptr]
    mov rsi, [rip + lf_line + SB_len]
    call lf_str
    mov r14, rax                # the label's offset
    lea rdi, [rip + lf_line]
    call sb_clear
    lea rdi, [rip + lf_line]
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 32]
    call sb_push
    test r13, r13
    jz 4f
    lea rdi, [rip + lf_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + lf_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + lf_line]
    mov rsi, [rsp + 40]
    mov rdx, r13
    call sb_push
4:  mov rdi, [rip + lf_line + SB_ptr]
    mov rsi, [rip + lf_line + SB_len]
    call lf_str
    mov r12, rax
    lea rdi, [rip + lf_res]
    mov esi, LS_SIZE
    call vec_push
    mov rcx, [rsp]
    mov [rax + LS_ext], rcx
    mov qword ptr [rax + LS_path], -1
    lea rcx, [rip + lf_tmp4]
    mov edx, [rcx]
    mov [rax + LS_l1], edx
    mov edx, [rcx + 4]
    mov [rax + LS_c1], edx
    mov edx, [rcx + 8]
    mov [rax + LS_l2], edx
    mov edx, [rcx + 12]
    mov [rax + LS_c2], edx
    mov [rax + LS_label], r14
    mov [rax + LS_detail], r12
    jmp 1b
7:  # all of the body was the N records: nothing after them
    mov rax, [rip + ps_ptr]
    cmp rax, [rip + ps_end]
    je 9f
8:  mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call lf_rollback
9:  EPILOGUE

# lf_parse_actions(ext, body, len): "N", then KIND TITLE_LEN EDIT_LEN DATA_LEN and the bytes
lf_parse_actions:
    PROLOGUE 48
    mov [rsp], rdi
    mov rax, [rip + lf_res + VEC_len]
    mov [rsp + 8], rax
    mov rax, [rip + lf_bytes + SB_len]
    mov [rsp + 16], rax
    cmp rdx, WS_BODY_MAX
    ja 8f
    mov rdi, rsi
    mov rsi, rdx
    mov edx, LF_ACTS_MAX
    call lf_head
    test rax, rax
    js 8f
    mov r15, rax
1:  test r15, r15
    jz 7f
    dec r15
    call ps_line
    test eax, eax
    jz 8f
    call ps_word                # the kind
    test rdx, rdx
    jz 8f
    cmp rdx, 40
    ja 8f
    mov [rsp + 24], rax
    mov [rsp + 32], rdx
    call ps_num
    test edx, edx
    jz 8f
    test rax, rax
    jz 8f
    cmp rax, 1000
    ja 8f
    mov r12, rax                # the title's length
    call ps_num
    test edx, edx
    jz 8f
    mov r13, rax                # the edit's
    call ps_num
    test edx, edx
    jz 8f
    mov r14, rax                # the data's
    call ps_eol
    test eax, eax
    jz 8f
    mov rdi, r12
    call lf_take
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, r12
    call lf_str
    mov [rsp + 40], rax         # the title
    mov rdi, r13
    call lf_take
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, r13
    call lf_str
    mov rbx, rax                # the edit (kept whole, checked when chosen)
    mov rdi, r14
    call lf_take
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, r14
    call lf_str
    mov r12, rax                # the data
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    call lf_str
    mov [rsp + 24], rax         # the kind, its detail
    lea rdi, [rip + lf_res]
    mov esi, LS_SIZE
    call vec_push
    mov rcx, [rsp]
    mov [rax + LS_ext], rcx
    mov qword ptr [rax + LS_path], -1
    mov rcx, [rsp + 40]
    mov [rax + LS_label], rcx
    mov rcx, [rsp + 24]
    mov [rax + LS_detail], rcx
    mov [rax + LS_edit], rbx
    mov [rax + LS_elen], r13
    mov [rax + LS_data], r12
    mov [rax + LS_dlen], r14
    # quick fixes first
    mov rdx, [rsp + 24]
    add rdx, [rip + lf_bytes + SB_ptr]
    xor ecx, ecx
    cmp dword ptr [rdx], 0x63697571     # "quic"
    je 11f
    mov ecx, 1
11: mov [rax + LS_rank], ecx
    jmp 1b
7:  # all of the body was the N records: nothing after them
    mov rax, [rip + ps_ptr]
    cmp rax, [rip + ps_end]
    je 9f
8:  mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call lf_rollback
9:  EPILOGUE

# ---------------- protocol 1.1: navigation, partial-format, code-actions ----------------

# lf_is_locations(eax kind) -> eax 1 for a kind whose answer is locations
lf_is_locations:
    cmp eax, LF_DEF
    je 1f
    cmp eax, LF_REFS
    je 1f
    cmp eax, LF_DECL
    jb 8f
    cmp eax, LF_IMPL
    ja 8f
1:  mov eax, 1
    ret
8:  xor eax, eax
    ret

# lf_push_trim_final(doc): " TRIM FINAL" into lf_line, the document's trim_trailing_whitespace
# and final_newline in force (yes or no)
lf_push_trim_final:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + lf_line]
    call lf_push_sp
    mov rdi, rbx
    mov esi, OPT_TRIM
    call ext_opt_bool
    lea rsi, [rip + .Lyes]
    test eax, eax
    jnz 1f
    lea rsi, [rip + .Lno]
1:  lea rdi, [rip + lf_line]
    call sb_push_cstr
    lea rdi, [rip + lf_line]
    call lf_push_sp
    mov rdi, rbx
    mov esi, OPT_FINAL
    call ext_opt_bool
    lea rsi, [rip + .Lyes]
    test eax, eax
    jnz 2f
    lea rsi, [rip + .Lno]
2:  lea rdi, [rip + lf_line]
    call sb_push_cstr
    EPILOGUE

# lf_range_format_first() -> eax 1 when Format Document should format the selection: the focused
# document has one and an extension declares range formatting for it
lf_range_format_first:
    PROLOGUE
    call lf_focused_doc
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    je 8f
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 8f
    imul r13, r12, EXT_SIZE
    add r13, [rip + g_exts + VEC_ptr]
    inc r12
    mov rdi, r13
    call ext_is_visible
    test eax, eax
    jz 1b
    cmp dword ptr [r13 + EXT_disabled], 0
    jne 1b
    mov rdi, r13
    mov esi, EXT_pv_range_format
    call ext_pv
    test rax, rax
    jz 1b
    mov rdi, rax
    mov rsi, rbx
    call extproto_matches
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN langfeat_actions_auto(ext, doc) -> rax ptr, rdx len: the lightbulb's request (lightbulb.s), the
# line below with TRIGGER auto and KINDS quickfix
FN langfeat_actions_auto
    mov dword ptr [rip + lf_auto], 1
    push rdi
    call lf_actions_line
    pop rdi
    mov dword ptr [rip + lf_auto], 0
    mov rax, [rip + lf_line2 + SB_ptr]
    mov rdx, [rip + lf_line2 + SB_len]
    ret

# lf_actions_line(ext, doc): lf_line2 = "code-actions DOC VERSION L1 C1 L2 C2 TRIGGER KINDS DIAGS".
# Without a selection, when the extension has diagnostics on the cursor's line, the range is the
# one containing the cursor, else the line's first (a server fixes the diagnostic it is given)
lf_actions_line:
    PROLOGUE 32
    mov r14, rdi
    mov rbx, rsi
    mov rdi, rbx
    call ed_sel
    mov r12, rax
    mov r13, rdx
    cmp r12, r13
    jne 5f
    mov rcx, [rbx + DOC_xmarks]
    test rcx, rcx
    jz 5f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov [rsp], rax              # the cursor's line
    mov qword ptr [rsp + 8], -1 # the first mark on it
    xor r15d, r15d
1:  mov rcx, [rbx + DOC_xmarks]
    cmp r15, [rcx + VEC_len]
    jae 4f
    imul rax, r15, MK_SIZE
    add rax, [rcx + VEC_ptr]
    inc r15
    mov [rsp + 16], rax
    mov rdi, r14
    mov rsi, [rax + MK_owner]
    call lf_mark_mine
    test eax, eax
    jz 1b
    mov rax, [rsp + 16]
    mov rdi, rbx
    mov rsi, [rax + MK_start]
    call doc_line_of
    cmp rax, [rsp]
    jne 1b
    mov rax, [rsp + 16]
    cmp qword ptr [rsp + 8], -1
    jne 2f
    mov [rsp + 8], rax
2:  cmp r12, [rax + MK_start]
    jb 1b
    cmp r12, [rax + MK_end]
    ja 1b
    mov [rsp + 8], rax          # it contains the cursor
4:  mov rax, [rsp + 8]
    cmp rax, -1
    je 5f
    mov r12, [rax + MK_start]
    mov r13, [rax + MK_end]
5:  lea rdi, [rip + lf_line2]
    call sb_clear
    lea rdi, [rip + lf_line2]
    lea rsi, [rip + .Lv_code_actions]
    call sb_push_cstr
    lea rdi, [rip + lf_line2]
    mov rsi, [rbx + DOC_id]
    call sb_push_u64
    lea rdi, [rip + lf_line2]
    call lf_push_sp
    lea rdi, [rip + lf_line2]
    mov rsi, [rbx + DOC_version]
    call sb_push_u64
    mov rdi, rbx
    mov rsi, r12
    call lf_push_pos2
    mov rdi, rbx
    mov rsi, r13
    call lf_push_pos2
    lea rsi, [rip + .Linvoked]
    cmp dword ptr [rip + lf_auto], 0
    je 51f
    lea rsi, [rip + .Lauto_quickfix]
51: lea rdi, [rip + lf_line2]
    call sb_push_cstr
    cmp dword ptr [rip + lf_auto], 0
    jne 61f
    mov rsi, [rip + lf_act_kinds]
    test rsi, rsi
    jnz 6f
    lea rsi, [rip + .Ldash]
6:  lea rdi, [rip + lf_line2]
    call sb_push_cstr
61:
    # DIAGS: the ids of its file-diagnostics in the range
    lea rdi, [rip + lf_dbuf]
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    call lf_line_col
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rbx
    mov rsi, r13
    call lf_line_col
    lea rcx, [rip + lf_dbuf]
    push rcx
    push rcx
    mov r8, rax
    mov r9, rdx
    mov rdi, r14
    mov rsi, rbx
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    call filediag_ids
    add rsp, 16
    test eax, eax
    jz 7f
    lea rdi, [rip + lf_line2]
    call lf_push_sp
    lea rdi, [rip + lf_line2]
    mov rsi, [rip + lf_dbuf + SB_ptr]
    mov rdx, [rip + lf_dbuf + SB_len]
    call sb_push
    EPILOGUE
7:  lea rdi, [rip + lf_line2]
    lea rsi, [rip + .Lsp_dash]
    call sb_push_cstr
    EPILOGUE

# lf_mark_mine(ext, owner) -> eax 1 when a mark's owner is the extension or one of its
# file-diagnostics sources
FN langfeat_mark_mine
lf_mark_mine:
    cmp rdi, rsi
    je 1f
    mov rcx, [rdi + EXT_fdsrc + VEC_len]
    mov rdx, [rdi + EXT_fdsrc + VEC_ptr]
2:  test rcx, rcx
    jz 8f
    cmp [rdx], rsi
    je 1f
    add rdx, 8
    dec rcx
    jmp 2b
1:  mov eax, 1
    ret
8:  xor eax, eax
    ret

# lf_push_pos2(doc, pos): " LINE COL" into lf_line2
lf_push_pos2:
    PROLOGUE
    call lf_line_col
    mov rbx, rax
    mov r12, rdx
    lea rdi, [rip + lf_line2]
    call lf_push_sp
    lea rdi, [rip + lf_line2]
    mov rsi, rbx
    call sb_push_u64
    lea rdi, [rip + lf_line2]
    call lf_push_sp
    lea rdi, [rip + lf_line2]
    mov rsi, r12
    call sb_push_u64
    EPILOGUE

# lf_kind_match(kind ptr, len) -> eax 1 when the action's hierarchical kind equals or descends from
# one of the asked kinds (lf_act_kinds, comma separated), or none was asked
lf_kind_match:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rbx, [rip + lf_act_kinds]
    test rbx, rbx
    jz 7f
1:  cmp byte ptr [rbx], 0
    je 8f
    xor r14d, r14d              # this asked kind's length
2:  movzx eax, byte ptr [rbx + r14]
    test eax, eax
    jz 3f
    cmp eax, ','
    je 3f
    inc r14
    jmp 2b
3:  cmp r13, r14
    jb 4f
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r14
    call memeq
    test eax, eax
    jz 4f
    cmp r13, r14
    je 7f
    cmp byte ptr [r12 + r14], '.'
    je 7f
4:  add rbx, r14
    cmp byte ptr [rbx], ','
    jne 1b
    inc rbx
    jmp 1b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# lf_parse_actions2(ext, body, len): the code-actions grammar: "N", then KIND TITLE_LEN EDIT_LEN
# EXTRA_LEN and the bytes; EXTRA holds preferred, disabled, resolve, command and fixes records. An
# action with no edit, resolve or command is left out, as one of a kind not asked for
lf_parse_actions2:
    PROLOGUE 96
    mov [rsp], rdi
    mov rax, [rip + lf_res + VEC_len]
    mov [rsp + 8], rax
    mov rax, [rip + lf_bytes + SB_len]
    mov [rsp + 16], rax
    cmp rdx, WS_BODY_MAX
    ja 8f
    mov rdi, rsi
    mov rsi, rdx
    mov edx, LF_ACTS_MAX
    call lf_head
    test rax, rax
    js 8f
    mov r15, rax
1:  test r15, r15
    jz 7f
    dec r15
    call ps_line
    test eax, eax
    jz 8f
    call ps_word                # the kind
    test rdx, rdx
    jz 8f
    cmp rdx, 128
    ja 8f
    mov [rsp + 24], rax
    mov [rsp + 32], rdx
    call ps_num
    test edx, edx
    jz 8f
    test rax, rax
    jz 8f
    cmp rax, 1000
    ja 8f
    mov r12, rax                # the title's length
    call ps_num
    test edx, edx
    jz 8f
    mov r13, rax                # the edit's
    call ps_num
    test edx, edx
    jz 8f
    mov r14, rax                # the extra records'
    call ps_eol
    test eax, eax
    jz 8f
    mov rax, [rip + ps_end]
    sub rax, [rip + ps_ptr]
    mov rcx, r12
    add rcx, r13
    add rcx, r14
    cmp rcx, rax
    ja 8f
    mov rax, [rip + ps_ptr]
    mov [rsp + 40], rax         # the title's bytes
    add rax, r12
    mov [rsp + 48], rax         # the edit's
    add rax, r13
    mov [rsp + 56], rax         # the extra's
    add rax, r14
    mov [rip + ps_ptr], rax
    # a kind asked for?
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    call lf_kind_match
    test eax, eax
    jz 1b
    # the extra records: preferred, disabled, resolve, command (fixes is for the lightbulb)
    mov rax, [rip + ps_ptr]
    mov [rsp + 64], rax         # the parser's place, kept
    mov rax, [rip + ps_end]
    mov [rsp + 72], rax
    mov rdi, [rsp + 56]
    mov rsi, r14
    call lf_action_extra
    mov [rsp + 88], eax
    mov rax, [rsp + 64]
    mov [rip + ps_ptr], rax
    mov rax, [rsp + 72]
    mov [rip + ps_end], rax
    cmp dword ptr [rsp + 88], 0
    jl 8f
    # the record: title, kind, edit, resolve data, command, reason
    mov rdi, [rsp + 40]
    mov rsi, r12
    call lf_str
    mov [rsp + 40], rax
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    call lf_str
    mov [rsp + 24], rax
    mov rdi, [rsp + 48]
    mov rsi, r13
    call lf_str
    mov [rsp + 48], rax
    mov rdi, [rip + la_resolve]
    mov rsi, [rip + la_rlen]
    call lf_str
    mov [rsp + 64], rax
    mov rdi, [rip + la_cmd]
    mov rsi, [rip + la_clen]
    call lf_str
    mov [rsp + 72], rax
    mov rdi, [rip + la_reason]
    mov rsi, [rip + la_reasonlen]
    call lf_str
    mov [rsp + 80], rax
    # an action that does nothing is left out
    mov rax, r13
    or rax, [rip + la_rlen]
    or rax, [rip + la_clen]
    jnz 2f
    test dword ptr [rip + la_flags], LSF_DISABLED
    jz 1b
2:  lea rdi, [rip + lf_res]
    mov esi, LS_SIZE
    call vec_push
    mov rcx, [rsp]
    mov [rax + LS_ext], rcx
    mov qword ptr [rax + LS_path], -1
    mov rcx, [rsp + 40]
    mov [rax + LS_label], rcx
    mov rcx, [rsp + 24]
    mov [rax + LS_kind], rcx
    mov [rax + LS_detail], rcx
    mov rcx, [rsp + 48]
    mov [rax + LS_edit], rcx
    mov [rax + LS_elen], r13
    mov rcx, [rsp + 64]
    mov [rax + LS_data], rcx
    mov rcx, [rip + la_rlen]
    mov [rax + LS_dlen], rcx
    mov rcx, [rsp + 72]
    mov [rax + LS_cmd], rcx
    mov rcx, [rip + la_clen]
    mov [rax + LS_clen], rcx
    mov ecx, [rip + la_flags]
    mov [rax + LS_flags], ecx
    test ecx, LSF_DISABLED
    jz 21f
    mov rcx, [rsp + 80]
    mov [rax + LS_detail], rcx  # a disabled action's reason is its detail
21: cmp qword ptr [rip + la_rlen], 0
    je 22f
    or dword ptr [rax + LS_flags], LSF_RESOLVE
22: # the order: quick fixes (preferred first), refactors, source actions, others; disabled last
    mov rdx, [rsp + 24]
    add rdx, [rip + lf_bytes + SB_ptr]
    mov ecx, 4
    cmp dword ptr [rdx], 0x63697571     # "quic"
    jne 23f
    or dword ptr [rax + LS_flags], LSF_QUICKFIX
    mov ecx, 1
    test dword ptr [rax + LS_flags], LSF_PREFERRED
    jz 25f
    xor ecx, ecx
    jmp 25f
23: cmp dword ptr [rdx], 0x61666572     # "refa"
    jne 24f
    mov ecx, 2
    jmp 25f
24: cmp dword ptr [rdx], 0x72756f73     # "sour"
    jne 25f
    mov ecx, 3
25: test dword ptr [rax + LS_flags], LSF_DISABLED
    jz 26f
    add ecx, 10
26: mov [rax + LS_rank], ecx
    jmp 1b
7:  mov rax, [rip + ps_ptr]
    cmp rax, [rip + ps_end]
    je 9f
8:  mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call lf_rollback
9:  EPILOGUE

# lf_action_extra(ptr, len) -> eax 0 with la_flags, la_resolve/la_rlen, la_cmd/la_clen and
# la_reason/la_reasonlen from an action's EXTRA records, -1 when they break the rules
lf_action_extra:
    PROLOGUE
    mov dword ptr [rip + la_flags], 0
    mov qword ptr [rip + la_rlen], 0
    mov qword ptr [rip + la_clen], 0
    mov qword ptr [rip + la_reasonlen], 0
    mov [rip + ps_ptr], rdi
    lea rax, [rdi + rsi]
    mov [rip + ps_end], rax
1:  mov rax, [rip + ps_ptr]
    cmp rax, [rip + ps_end]
    jae 7f
    mov rbx, rax                # the record's start (a command record is handed over whole)
    call ps_line
    test eax, eax
    jz 8f
    # its last word is its length
    mov r12, [rip + ps_lend]
    mov rcx, r12
2:  cmp rcx, rbx
    je 8f
    cmp byte ptr [rcx - 1], ' '
    je 3f
    dec rcx
    jmp 2b
3:  mov rdi, rcx
    mov rsi, r12
    sub rsi, rcx
    jz 8f
    cmp rsi, 10
    ja 8f
    mov r13, rsi
    call parse_u64
    cmp rdx, r13
    jne 8f
    lea r13, [r12 + 1]          # its bytes
    lea r14, [r13 + rax]
    cmp r14, [rip + ps_end]
    ja 8f
    mov r15, rax
    call ps_word                # its name
    mov [rip + ps_ptr], r14     # the next record
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lx_preferred]
    push rdi
    push rsi
    call str_eq_cstr
    pop rsi
    pop rdi
    test eax, eax
    jz 4f
    or dword ptr [rip + la_flags], LSF_PREFERRED
    jmp 1b
4:  lea rdx, [rip + .Lx_disabled]
    push rdi
    push rsi
    call str_eq_cstr
    pop rsi
    pop rdi
    test eax, eax
    jz 5f
    or dword ptr [rip + la_flags], LSF_DISABLED
    cmp r15, 1000
    ja 8f
    mov [rip + la_reason], r13
    mov [rip + la_reasonlen], r15
    jmp 1b
5:  lea rdx, [rip + .Lx_resolve]
    push rdi
    push rsi
    call str_eq_cstr
    pop rsi
    pop rdi
    test eax, eax
    jz 6f
    cmp r15, 16384
    ja 8f
    mov [rip + la_resolve], r13
    mov [rip + la_rlen], r15
    jmp 1b
6:  lea rdx, [rip + .Lx_command]
    call str_eq_cstr
    test eax, eax
    jz 1b                       # fixes and others: skipped
    cmp r15, 8192
    ja 8f
    mov [rip + la_cmd], rbx
    mov rax, r14
    sub rax, rbx
    mov [rip + la_clen], rax
    jmp 1b
7:  xor eax, eax
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# lf_actions_auto() -> eax 1 when the finished code actions were applied without a list: Auto Fix
# takes the one enabled preferred quick fix, Organize Imports (and Fix All) the one action that
# came. Auto Fix otherwise lists the quick fixes only
lf_actions_auto:
    PROLOGUE
    mov eax, [rip + lf_act_mode]
    test eax, eax
    jz 8f
    xor ebx, ebx                # the candidates
    mov r13, -1
    xor r12d, r12d
1:  cmp r12, [rip + lf_res + VEC_len]
    jae 3f
    imul rax, r12, LS_SIZE
    add rax, [rip + lf_res + VEC_ptr]
    inc r12
    test dword ptr [rax + LS_flags], LSF_DISABLED
    jnz 1b
    cmp dword ptr [rip + lf_act_mode], LA_AUTO
    jne 2f
    test dword ptr [rax + LS_flags], LSF_PREFERRED
    jz 1b
2:  inc ebx
    lea r13, [r12 - 1]
    jmp 1b
3:  cmp ebx, 1
    jne 8f
    mov rdi, r13
    call lf_action_run
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# lf_action_run(i): action i goes ahead: a disabled one says why; its edit is applied (an action
# with resolve data and no edit is resolved first), then its command runs (v1's data goes back)
lf_action_run:
    PROLOGUE
    mov rbx, rdi
    imul r12, rbx, LS_SIZE
    add r12, [rip + lf_res + VEC_ptr]
    test dword ptr [r12 + LS_flags], LSF_DISABLED
    jz 1f
    mov rdi, [r12 + LS_detail]
    add rdi, [rip + lf_bytes + SB_ptr]
    call app_toast
    jmp 9f
1:  test dword ptr [r12 + LS_flags], LSF_RESOLVE
    jz 2f
    cmp qword ptr [r12 + LS_elen], 0
    jne 2f
    mov rdi, rbx
    call lf_action_resolve
    jmp 9f
2:  cmp qword ptr [r12 + LS_elen], 0
    je 3f
    # the edit in the extension's grammar (workspace-edits), named by the action's title; v1's
    # data goes with it when the confirmation list waits (wsedit.s)
    mov rcx, [r12 + LS_label]
    add rcx, [rip + lf_bytes + SB_ptr]
    mov rdi, [r12 + LS_edit]
    add rdi, [rip + lf_bytes + SB_ptr]
    mov rsi, [r12 + LS_elen]
    mov rdx, [r12 + LS_ext]
    xor r8d, r8d
    xor r9d, r9d
    test dword ptr [r12 + LS_flags], LSF_RESOLVE
    jnz 21f
    cmp qword ptr [r12 + LS_clen], 0
    jne 21f
    mov r8, [r12 + LS_data]     # v1 data
    add r8, [rip + lf_bytes + SB_ptr]
    mov r9, [r12 + LS_dlen]
21: call ws_apply_action
    cmp eax, 2
    jne 22f
    mov rdi, [r12 + LS_ext]     # the confirmation list waits: the command runs once it is made
    mov rsi, [r12 + LS_cmd]
    add rsi, [rip + lf_bytes + SB_ptr]
    mov rdx, [r12 + LS_clen]
    call lf_park_cmd
    jmp 9f
22: cmp eax, 1
    jne 9f                      # not made: nothing more
3:  mov rdi, rbx
    call lf_action_command
9:  EPILOGUE

# lf_action_command(i): action i's command reference runs (command-args: "0 run EXT.NAME DOC ref
# LEN" + ARGS), or v1's data goes back with "0 action"
lf_action_command:
    PROLOGUE
    imul r12, rdi, LS_SIZE
    add r12, [rip + lf_res + VEC_ptr]
    mov rbx, [r12 + LS_ext]
    test rbx, rbx
    jz 9f                       # its extension stopped since
    cmp qword ptr [r12 + LS_clen], 0
    je 2f
    mov rdi, rbx
    mov rsi, [r12 + LS_cmd]
    add rsi, [rip + lf_bytes + SB_ptr]
    mov rdx, [r12 + LS_clen]
    call cmdref_parse
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, rax
    mov rsi, [rip + lf_doc_id]
    call cmdref_invoke
    mov rdi, r13
    call cmdref_free
    jmp 9f
2:  test dword ptr [r12 + LS_flags], LSF_RESOLVE
    jnz 9f
    cmp qword ptr [r12 + LS_dlen], 0
    je 9f
    mov rdi, rbx
    mov rsi, [r12 + LS_data]
    add rsi, [rip + lf_bytes + SB_ptr]
    mov rdx, [r12 + LS_dlen]
    call extproto_send_action
9:  EPILOGUE

# lf_action_resolve(i): "ID code-action-resolve DOC VERSION LEN" + action i's resolve data
lf_action_resolve:
    PROLOGUE
    mov rbx, rdi
    imul r12, rbx, LS_SIZE
    add r12, [rip + lf_res + VEC_ptr]
    mov r13, [r12 + LS_ext]
    test r13, r13
    jz 9f
    call lf_rs_withdraw
    mov rdi, [rip + lf_doc_id]
    call extproto_doc
    test rax, rax
    jz 9f
    mov r14, rax
    lea rdi, [rip + lf_line2]
    call sb_clear
    lea rdi, [rip + lf_line2]
    lea rsi, [rip + .Lv_action_resolve]
    call sb_push_cstr
    lea rdi, [rip + lf_line2]
    mov rsi, [r14 + DOC_id]
    call sb_push_u64
    lea rdi, [rip + lf_line2]
    call lf_push_sp
    lea rdi, [rip + lf_line2]
    mov rsi, [r14 + DOC_version]
    call sb_push_u64
    lea rdi, [rip + lf_line2]
    call lf_push_sp
    lea rdi, [rip + lf_line2]
    mov rsi, [r12 + LS_dlen]
    call sb_push_u64
    mov rdi, r13
    mov rsi, r14
    mov rdx, [rip + lf_line2 + SB_ptr]
    mov rcx, [rip + lf_line2 + SB_len]
    mov r8, [r12 + LS_data]
    add r8, [rip + lf_bytes + SB_ptr]
    mov r9, [r12 + LS_dlen]
    call extproto_host_send_body
    test rax, rax
    jz 9f
    mov [rip + lf_rs_id], rax
    mov [rip + lf_rs_ext], r13
    mov [rip + lf_rs_index], rbx
    mov dword ptr [rip + lf_rs_ready], 0
    mov rdi, r13
    mov rsi, rax
    mov edx, PK_ACTION_RESOLVE
    mov ecx, QO_LANGFEAT
    call query_track
9:  EPILOGUE

# lf_park_cmd(ext, record, len): an action's command record waits for wsedit's confirmation list
# (len 0: nothing waits)
lf_park_cmd:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov qword ptr [rip + lf_wcmd_ext], 0
    test r13, r13
    jz 9f
    lea rdi, [rip + lf_wcmd]
    call sb_clear
    lea rdi, [rip + lf_wcmd]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov [rip + lf_wcmd_ext], rbx
    mov rax, [rip + lf_doc_id]
    mov [rip + lf_wcmd_doc], rax
9:  EPILOGUE

# FN langfeat_ws_resolved(made): wsedit's confirmation list was answered: with the edit made, the
# action's command that waited runs; otherwise it goes
FN langfeat_ws_resolved
    PROLOGUE
    mov rbx, [rip + lf_wcmd_ext]
    test rbx, rbx
    jz 9f
    mov qword ptr [rip + lf_wcmd_ext], 0
    test edi, edi
    jz 9f
    mov rdi, rbx
    call ext_is_visible
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, [rip + lf_wcmd + SB_ptr]
    mov rdx, [rip + lf_wcmd + SB_len]
    call cmdref_parse
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    mov rsi, [rip + lf_wcmd_doc]
    call cmdref_invoke
    mov rdi, r12
    call cmdref_free
9:  EPILOGUE

# lf_rs_withdraw(): a code action's resolve still out is not wanted any more
lf_rs_withdraw:
    push rbx
    mov rdi, [rip + lf_rs_ext]
    test rdi, rdi
    jz 9f
    mov rsi, [rip + lf_rs_id]
    mov qword ptr [rip + lf_rs_ext], 0
    mov dword ptr [rip + lf_rs_ready], 0
    call query_withdraw
9:  pop rbx
    ret

# lf_rs_reply(ext, id, ok, body, len) -> eax 1 when it answered the code action's resolve (from
# extproto's pump: state only; the tick applies it)
lf_rs_reply:
    cmp rdi, [rip + lf_rs_ext]
    jne 8f
    cmp rsi, [rip + lf_rs_id]
    jne 8f
    test rdi, rdi
    jz 8f
    push rbx
    push r12
    push r13
    mov ebx, edx
    mov r12, rcx
    mov r13, r8
    mov dword ptr [rip + lf_rs_ready], 2
    test ebx, ebx
    jz 1f
    lea rdi, [rip + lf_rs_body]
    call sb_clear
    lea rdi, [rip + lf_rs_body]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov dword ptr [rip + lf_rs_ready], 1
1:  mov dword ptr [rip + g_dirty], 1
    pop r13
    pop r12
    pop rbx
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# lf_rs_tick(): a resolved code action: "EDIT_LEN EXTRA_LEN", its edit, then its command records
lf_rs_tick:
    PROLOGUE
    mov eax, [rip + lf_rs_ready]
    test eax, eax
    jz 9f
    mov dword ptr [rip + lf_rs_ready], 0
    mov rbx, [rip + lf_rs_ext]
    mov qword ptr [rip + lf_rs_ext], 0
    cmp eax, 1
    jne 9f
    mov r12, [rip + lf_rs_index]
    cmp r12, [rip + lf_res + VEC_len]
    jae 9f
    mov rax, [rip + lf_rs_body + SB_ptr]
    mov [rip + ps_ptr], rax
    add rax, [rip + lf_rs_body + SB_len]
    mov [rip + ps_end], rax
    call ps_line
    test eax, eax
    jz 8f
    call ps_num
    test edx, edx
    jz 8f
    mov r13, rax                # EDIT_LEN
    call ps_num
    test edx, edx
    jz 8f
    mov r14, rax                # EXTRA_LEN
    call ps_eol
    test eax, eax
    jz 8f
    mov rax, [rip + ps_end]
    sub rax, [rip + ps_ptr]
    mov rcx, r13
    add rcx, r14
    cmp rcx, rax
    jne 8f
    mov r15, [rip + ps_ptr]
    test r13, r13
    jz 1f
    mov rcx, [rip + lf_res + VEC_ptr]   # in the extension's grammar, named by the action
    imul rax, r12, LS_SIZE
    mov rcx, [rcx + rax + LS_label]
    add rcx, [rip + lf_bytes + SB_ptr]
    mov rdi, r15
    mov rsi, r13
    mov rdx, rbx
    call ws_apply_from
    cmp eax, 2
    jne 11f
    mov rdi, rbx                # the confirmation list waits: the answer's command, else the action's
    lea rsi, [r15 + r13]
    mov rdx, r14
    test r14, r14
    jnz 12f
    imul rax, r12, LS_SIZE
    add rax, [rip + lf_res + VEC_ptr]
    mov rsi, [rax + LS_cmd]
    add rsi, [rip + lf_bytes + SB_ptr]
    mov rdx, [rax + LS_clen]
12: call lf_park_cmd
    jmp 9f
11: cmp eax, 1
    jne 9f
1:  # its command: the answer's, else the action's own
    test r14, r14
    jz 2f
    mov rdi, rbx
    lea rsi, [r15 + r13]
    mov rdx, r14
    call cmdref_parse
    test rax, rax
    jz 2f
    mov r13, rax
    mov rdi, rax
    mov rsi, [rip + lf_doc_id]
    call cmdref_invoke
    mov rdi, r13
    call cmdref_free
    jmp 9f
2:  mov rdi, r12
    call lf_action_command
    jmp 9f
8:  mov rdi, rbx
    mov esi, PK_ACTION_RESOLVE
    call query_dropped
9:  EPILOGUE

# ---------------- finishing ----------------

# FN langfeat_timeout() -> ms until the query in flight is given up, or -1
FN langfeat_timeout
    cmp dword ptr [rip + lf_rs_ready], 0
    jne 7f
    cmp dword ptr [rip + lf_kind], 0
    je 8f
    cmp dword ptr [rip + lf_ready], 0
    jne 7f
8:  jmp langextra_timeout        # query.s's timeout covers the requests still out
7:  xor eax, eax
    ret

# FN langfeat_tick(): a query whose answers are in, or whose time is up, is finished
FN langfeat_tick
    push rbx
    call lf_rs_tick
    call langextra_tick
    call outline_tick
    call hovercard_tick
    call lightbulb_tick
    call wsym_tick
    call doclinks_tick
    call definitionlink_tick
    cmp dword ptr [rip + lf_show_due], 0
    je 0f
    mov dword ptr [rip + lf_show_due], 0  # the first parts of a query still out, shown
    cmp dword ptr [rip + lf_kind], 0
    je 0f
    cmp qword ptr [rip + lf_res + VEC_len], 0
    je 0f
    cmp dword ptr [rip + lf_dest], 0
    jne 3f
    cmp dword ptr [rip + lf_partial], 0
    je 3f
    call palette_results_showing
    test eax, eax
    jz 0f
3:  mov dword ptr [rip + lf_partial], 1
    mov eax, [rip + lf_kind]
    mov [rip + lf_list_kind], eax
    cmp dword ptr [rip + lf_dest], LFD_RESULTS
    jne 31f
    mov edi, 1                  # still searching
    call lf_to_results
    jmp 0f
31: cmp dword ptr [rip + lf_dest], LFD_PEEK
    jne 32f
    call lf_to_peek
    jmp 0f
32: call lf_present_list
0:
    cmp dword ptr [rip + lf_kind], 0
    je 9f
    call lf_language_current
    test eax, eax
    jnz 0f
    call langfeat_provider_cancel
    jmp 9f
0:
    cmp dword ptr [rip + lf_ready], 0
    je 9f
    call lf_cancel_all
    call lf_finish
9:  pop rbx
    ret

# lf_finish(): what the answers mean for the user
lf_finish:
    PROLOGUE
    mov ebx, [rip + lf_kind]
    mov [rip + lf_list_kind], ebx
    mov dword ptr [rip + lf_kind], 0
    mov dword ptr [rip + lf_ready], 0
    mov dword ptr [rip + g_dirty], 1
    mov r12, [rip + lf_res + VEC_len]
    cmp ebx, LF_RENAME
    je .Lfn_rename
    cmp ebx, LF_FORMAT
    je .Lfn_format
    cmp ebx, LF_RANGEFMT
    je .Lfn_format
    cmp ebx, LF_ACTS
    jne 0f
    call lf_actions_auto        # Auto Fix, Organize Imports: applied when one fits
    test eax, eax
    jnz 9f
0:
    test r12, r12
    jnz 1f
    lea rax, [rip + lf_empty]
    mov rdi, [rax + rbx*8]
    call app_toast
    jmp 9f
1:  cmp dword ptr [rip + lf_dest], LFD_RESULTS
    jne 10f
    xor edi, edi                # done searching
    call lf_to_results
    jmp 9f
10: cmp dword ptr [rip + lf_dest], LFD_PEEK
    jne 101f
    call lf_to_peek
    jmp 9f
101: cmp dword ptr [rip + lf_partial], 0
    je 11f
    call palette_results_showing    # shown at its first part: refreshed while still open
    test eax, eax
    jz 9f
    jmp 2f
11: cmp ebx, LF_REFS
    je 2f
    cmp ebx, LF_SYMS
    je 2f
    cmp ebx, LF_ACTS
    je 2f
    cmp r12, 1
    jne 2f
    xor edi, edi
    call lf_goto                # one definition: there at once
    jmp 9f
2:  call lf_present_list
    jmp 9f

# lf_present_list(): the results in the palette, in their order (ebx the kind); a list already
# showing (more parts came) keeps its field and its selected result
lf_present_list:
    PROLOGUE 32
    mov ebx, [rip + lf_list_kind]
    mov qword ptr [rsp], -1     # the selected result before: its place and position
    mov dword ptr [rsp + 24], 0 # 1: refreshing
    cmp dword ptr [rip + lf_partial], 0
    je 1f
    call palette_results_showing
    test eax, eax
    jz 1f
    mov dword ptr [rsp + 24], 1
    call palette_results_selected
    cmp rax, [rip + lf_res + VEC_len]
    jae 1f
    imul rcx, rax, LS_SIZE
    add rcx, [rip + lf_res + VEC_ptr]
    mov rax, [rcx + LS_path]
    mov [rsp], rax
    mov eax, [rcx + LS_l1]
    mov [rsp + 8], eax
    mov eax, [rcx + LS_c1]
    mov [rsp + 12], eax
    mov rax, [rcx + LS_ext]
    mov [rsp + 16], rax
1:  call lf_sort
    cmp dword ptr [rsp + 24], 0
    je 2f
    call palette_results_refresh
    jmp 21f
2:  lea rax, [rip + lf_lists]
    mov rdi, [rax + rbx*8]
    call palette_results_open
21: xor r13d, r13d
3:  cmp r13, [rip + lf_res + VEC_len]
    jae 4f
    imul rax, r13, LS_SIZE
    add rax, [rip + lf_res + VEC_ptr]
    mov r14, rax
    mov rdi, [r14 + LS_label]
    add rdi, [rip + lf_bytes + SB_ptr]
    call strlen
    mov rsi, rax
    mov rdi, [r14 + LS_label]
    add rdi, [rip + lf_bytes + SB_ptr]
    xor edx, edx
    mov rax, [r14 + LS_detail]
    test rax, rax
    js 31f
    mov rdx, rax
    add rdx, [rip + lf_bytes + SB_ptr]
31: mov rcx, r13
    call palette_results_add
    inc r13
    jmp 3b
4:  call palette_results_ready
    cmp qword ptr [rsp], -1     # the result selected before, where the sort put it
    je 9f
    xor ecx, ecx
5:  cmp rcx, [rip + lf_res + VEC_len]
    jae 9f
    imul rax, rcx, LS_SIZE
    add rax, [rip + lf_res + VEC_ptr]
    inc rcx
    mov rdx, [rax + LS_path]
    cmp rdx, [rsp]
    jne 5b
    mov edx, [rax + LS_l1]
    cmp edx, [rsp + 8]
    jne 5b
    mov edx, [rax + LS_c1]
    cmp edx, [rsp + 12]
    jne 5b
    mov rdx, [rax + LS_ext]
    cmp rdx, [rsp + 16]
    jne 5b
    lea rdi, [rcx - 1]
    call palette_results_select
9:  EPILOGUE

.Lfn_rename:
    cmp byte ptr [rip + lf_err], 0
    je 5f
    lea rdi, [rip + lf_err]
    call app_toast
    jmp 9f
5:  cmp qword ptr [rip + lf_ws + SB_len], 0
    jne 6f
    lea rdi, [rip + .Lnothing_renamed]
    call app_toast
    jmp 9f
6:  mov rdi, [rip + lf_name + SB_ptr]
    mov rsi, [rip + lf_name + SB_len]
    call ws_rename_label
    mov rcx, rax
    mov rdi, [rip + lf_ws + SB_ptr]
    mov rsi, [rip + lf_ws + SB_len]
    mov rdx, [rip + lf_ws_ext]
    call ws_apply_from
    cmp eax, 1
    jne 9f                      # refused, or waiting for the confirmation list
    cmp dword ptr [rip + ws_wrote], 0
    jne 9f                      # written to disk: it said so itself
    lea rdi, [rip + .Lrenamed]
    call app_toast
    jmp 9f
.Lfn_format:
    cmp qword ptr [rip + lf_ws + SB_len], 0
    je 9f
    mov rax, [rip + lf_doc_id]
    mov [rip + ws_only], rax    # a format edit changes the document it was asked for, no other
    mov rdi, [rip + lf_ws + SB_ptr]
    mov rsi, [rip + lf_ws + SB_len]
    call ws_apply
    mov qword ptr [rip + ws_only], 0
9:  EPILOGUE

# lf_take_word(doc): lf_word = the word at the cursor (at most LF_WORD_MAX bytes), or empty
lf_take_word:
    PROLOGUE
    mov rbx, rdi
    mov byte ptr [rip + lf_word], 0
    mov rsi, [rbx + DOC_cur]
    call word_at
    mov r12, rax
    mov r13, rdx
    sub r13, r12
    jbe 9f
    cmp r13, LF_WORD_MAX
    jbe 1f
    mov r13d, LF_WORD_MAX
1:  xor r14d, r14d
2:  cmp r14, r13
    jae 3f
    lea rsi, [r12 + r14]
    mov rdi, rbx
    call doc_byte
    lea rcx, [rip + lf_word]
    mov [rcx + r14], al
    inc r14
    jmp 2b
3:  lea rcx, [rip + lf_word]
    mov byte ptr [rcx + r14], 0
9:  EPILOGUE

# lf_to_results(busy): the locations so far into the Results panel's set of this query
lf_to_results:
    PROLOGUE 16
    mov [rsp], edi
    call lf_sort
    lea rdi, [rip + lf_word]
    mov esi, [rip + lf_session]
    call results_refs_begin
    mov r12, rax
    xor ebx, ebx
1:  cmp rbx, [rip + lf_res + VEC_len]
    jae 2f
    imul r13, rbx, LS_SIZE
    add r13, [rip + lf_res + VEC_ptr]
    inc rbx
    mov rax, [r13 + LS_path]
    test rax, rax
    js 1b
    mov rdi, r13
    call lf_preview
    mov rcx, rax
    mov r8, rdx
    mov rsi, [r13 + LS_path]
    add rsi, [rip + lf_bytes + SB_ptr]
    lea rdx, [r13 + LS_l1]
    mov rdi, r12
    call results_loc
    jmp 1b
2:  mov rdi, r12
    mov esi, [rsp]
    call results_refs_end
    EPILOGUE

# lf_to_peek(): the locations so far into the peek view
lf_to_peek:
    PROLOGUE
    call lf_sort
    mov eax, [rip + lf_kind]
    test eax, eax
    jnz 1f
    mov eax, [rip + lf_list_kind]
1:  lea rcx, [rip + lf_peek_titles]
    mov rdi, [rcx + rax*8]
    mov esi, [rip + lf_session]
    call peek_begin
    xor ebx, ebx
2:  cmp rbx, [rip + lf_res + VEC_len]
    jae 3f
    imul r13, rbx, LS_SIZE
    add r13, [rip + lf_res + VEC_ptr]
    inc rbx
    cmp qword ptr [r13 + LS_path], 0
    jl 2b
    mov rdi, r13
    call lf_preview
    mov rcx, rdx
    mov rdx, rax
    mov rdi, [r13 + LS_path]
    add rdi, [rip + lf_bytes + SB_ptr]
    lea rsi, [r13 + LS_l1]
    call peek_loc
    jmp 2b
3:  call peek_end
    EPILOGUE

# lf_preview(LS*) -> rax ptr, rdx len of a location's preview: its label after "name:LINE  "
lf_preview:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + LS_path]
    add rdi, [rip + lf_bytes + SB_ptr]
    mov r12, rdi
    call strlen
    mov r13, rax                # the name's length: after the last separator
1:  test rax, rax
    jz 2f
    movzx ecx, byte ptr [r12 + rax - 1]
    cmp ecx, '/'
    je 2f
    cmp ecx, '\\'
    je 2f
    dec rax
    jmp 1b
2:  sub r13, rax
    inc r13                     # ':'
    mov eax, [rbx + LS_l1]      # the line's digits
3:  inc r13
    xor edx, edx
    mov ecx, 10
    div ecx
    test eax, eax
    jnz 3b
    add r13, 2                  # the two spaces
    mov r12, [rbx + LS_label]
    add r12, [rip + lf_bytes + SB_ptr]
    mov rdi, r12
    call strlen
    cmp r13, rax
    jbe 4f
    mov r13, rax
4:  sub rax, r13
    mov rdx, rax
    lea rax, [r12 + r13]
    EPILOGUE

# lf_sort(): the results in their order: by rank (actions), and locations of this document first
# (insertion sort; a long list keeps the providers' order)
lf_sort:
    PROLOGUE 16
    mov r12, [rip + lf_res + VEC_len]
    # the ranks of locations: 0 in the asked document, 1 elsewhere
    xor ebx, ebx
1:  cmp rbx, r12
    jae 2f
    imul r13, rbx, LS_SIZE
    add r13, [rip + lf_res + VEC_ptr]
    inc rbx
    mov rax, [r13 + LS_path]
    test rax, rax
    js 1b
    add rax, [rip + lf_bytes + SB_ptr]
    mov rdi, rax
    call lf_is_asked_doc
    xor eax, 1
    mov [r13 + LS_rank], eax
    jmp 1b
2:  mov rdi, [rip + lf_res + VEC_ptr]
    mov rsi, r12
    mov edx, LS_SIZE
    lea rcx, [rip + ls_cmp]
    call lf_msort
9:  EPILOGUE

# ls_cmp(a, b) -> eax < 0 when result a goes first: by rank, then by path, line and column
# (symbols and actions have no path: their order is the providers')
ls_cmp:
    mov eax, [rdi + LS_rank]
    cmp eax, [rsi + LS_rank]
    jl 8f
    jg 9f
    mov rax, [rdi + LS_path]
    mov rcx, [rsi + LS_path]
    test rax, rax
    js 7f
    test rcx, rcx
    js 7f
    mov rdx, [rip + lf_bytes + SB_ptr]
    add rax, rdx
    add rcx, rdx
1:  movzx edx, byte ptr [rax]
    movzx r8d, byte ptr [rcx]
    cmp edx, r8d
    jb 8f
    ja 9f
    test edx, edx
    jz 2f
    inc rax
    inc rcx
    jmp 1b
2:  mov eax, [rdi + LS_l1]
    cmp eax, [rsi + LS_l1]
    jb 8f
    ja 9f
    mov eax, [rdi + LS_c1]
    cmp eax, [rsi + LS_c1]
    jb 8f
    ja 9f
7:  xor eax, eax
    ret
8:  mov eax, -1
    ret
9:  mov eax, 1
    ret

# lf_is_asked_doc(path cstr) -> eax 1 when it names the asked document ("#ID" or its path)
lf_is_asked_doc:
    push rbx
    mov rbx, rdi
    cmp byte ptr [rbx], '#'
    jne 1f
    lea rdi, [rbx + 1]
    call strlen
    mov rsi, rax
    lea rdi, [rbx + 1]
    call parse_u64
    xor ecx, ecx
    cmp rax, [rip + lf_doc_id]
    sete cl
    mov eax, ecx
    pop rbx
    ret
1:  mov rdi, [rip + lf_doc_id]
    call extproto_doc
    test rax, rax
    jz 8f
    mov rsi, [rax + DOC_path]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call strcmp_eq
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret

# FN langfeat_chosen(i): the user chose result i of the palette's list
FN langfeat_chosen
    PROLOGUE
    cmp rdi, [rip + lf_res + VEC_len]
    jae 9f
    mov rbx, rdi
    call lf_language_current
    test eax, eax
    jz 9f
    imul r12, rbx, LS_SIZE
    add r12, [rip + lf_res + VEC_ptr]
    mov rdi, [r12 + LS_ext]
    call ext_is_visible
    test eax, eax
    jz 9f
    cmp dword ptr [rip + lf_list_kind], LF_ACTS
    je 1f
    cmp dword ptr [rip + lf_kind], 0  # chosen from a list shown early: the rest is not wanted
    je 0f
    call lf_cancel_all
    mov dword ptr [rip + lf_kind], 0
    mov dword ptr [rip + lf_partial], 0
0:  mov rdi, rbx
    call lf_goto
    jmp 9f
1:  mov rdi, rbx                # code actions: disabled, resolve, edit, command (lf_action_run)
    call lf_action_run
9:  EPILOGUE

# lf_goto(i): the editor at result i: its file open, its range selected
lf_goto:
    PROLOGUE
    imul rbx, rdi, LS_SIZE
    add rbx, [rip + lf_res + VEC_ptr]
    mov rax, [rbx + LS_path]
    test rax, rax
    js 1f
    add rax, [rip + lf_bytes + SB_ptr]
    mov rdi, rax
    call lf_open_path
    test rax, rax
    jz 9f
    mov r12, rax
    jmp 2f
1:  mov rdi, [rip + lf_doc_id]
    call extproto_doc
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    call doc_tab
    test rax, rax
    js 9f
    mov rdi, rax
    call app_activate_tab
2:  mov rdi, r12
    mov esi, [rbx + LS_l1]
    mov edx, [rbx + LS_c1]
    call lf_pos_near
    mov r13, rax
    mov rdi, r12
    mov esi, [rbx + LS_l2]
    mov edx, [rbx + LS_c2]
    call lf_pos_near
    cmp rax, r13
    jae 3f
    mov rax, r13
3:  cmp dword ptr [rip + lf_list_kind], LF_SYMS
    jne 4f
    mov rax, r13                # a symbol: the cursor at its start, nothing selected
4:  mov [r12 + DOC_anchor], r13
    mov [r12 + DOC_cur], rax
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    call ed_touch
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# lf_open_path(path cstr) -> rax the DOC of "#ID" or of the file, its tab active, or 0
lf_open_path:
    PROLOGUE
    mov rbx, rdi
    cmp byte ptr [rbx], '#'
    jne 1f
    lea rdi, [rbx + 1]
    call strlen
    mov rsi, rax
    lea rdi, [rbx + 1]
    call parse_u64
    mov rdi, rax
    call extproto_doc
    test rax, rax
    jz 8f
    mov r12, rax
    mov rdi, rax
    call doc_tab
    test rax, rax
    js 8f
    mov rdi, rax
    call app_activate_tab
    mov rax, r12
    EPILOGUE
1:  mov rdi, rbx
    call app_open_file
    test rax, rax
    js 8f
    mov rdi, rax
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 8f
    mov rax, [rax + TAB_doc]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# lf_msort(base, n, size, cmp): a stable sort of n records of size bytes; cmp(a, b) -> eax < 0
# when a goes before b (a merge sort of pointers, then the records copied in their order)
lf_msort:
    PROLOGUE 80
    mov [rsp], rdi              # base
    mov [rsp + 8], rsi          # n
    mov [rsp + 16], rdx         # size
    mov [rsp + 24], rcx         # cmp
    cmp rsi, 2
    jb 9f
    # two pointer arrays and room for the records
    mov rax, rsi
    imul rax, rdx
    lea rdi, [rax + rsi*8]
    lea rdi, [rdi + rsi*8]
    call mem_alloc
    mov [rsp + 32], rax
    mov r12, rax                # the run's pointers
    mov rcx, [rsp + 8]
    lea r13, [rax + rcx*8]      # the merged ones
    xor ecx, ecx
    mov rdx, [rsp]
1:  cmp rcx, [rsp + 8]
    jae 2f
    mov [r12 + rcx*8], rdx
    add rdx, [rsp + 16]
    inc rcx
    jmp 1b
2:  mov r14, 1                  # the width of a sorted run
3:  cmp r14, [rsp + 8]
    jae 7f
    xor r15d, r15d              # lo
4:  cmp r15, [rsp + 8]
    jae 6f
    lea rax, [r15 + r14]
    cmp rax, [rsp + 8]
    jbe 41f
    mov rax, [rsp + 8]
41: mov [rsp + 56], rax         # mid
    lea rax, [r15 + r14*2]
    cmp rax, [rsp + 8]
    jbe 42f
    mov rax, [rsp + 8]
42: mov [rsp + 64], rax         # hi
    mov [rsp + 40], r15         # i, in the left run
    mov rax, [rsp + 56]
    mov [rsp + 48], rax         # j, in the right run
    mov rbx, r15                # k
5:  cmp rbx, [rsp + 64]
    jae 59f
    mov rax, [rsp + 40]
    cmp rax, [rsp + 56]
    jae 52f                     # the left run is used up
    mov rcx, [rsp + 48]
    cmp rcx, [rsp + 64]
    jae 51f                     # the right one is
    mov rdi, [r12 + rcx*8]
    mov rsi, [r12 + rax*8]
    mov rax, [rsp + 24]
    call rax
    test eax, eax
    js 52f                      # the right one first only when it is strictly less
51: mov rax, [rsp + 40]
    mov rax, [r12 + rax*8]
    mov [r13 + rbx*8], rax
    inc qword ptr [rsp + 40]
    inc rbx
    jmp 5b
52: mov rax, [rsp + 48]
    mov rax, [r12 + rax*8]
    mov [r13 + rbx*8], rax
    inc qword ptr [rsp + 48]
    inc rbx
    jmp 5b
59: mov r15, [rsp + 64]
    jmp 4b
6:  mov rax, r12
    mov r12, r13
    mov r13, rax
    add r14, r14
    jmp 3b
7:  # the records in that order, through the room after the arrays
    mov rax, [rsp + 8]
    mov rdi, [rsp + 32]
    lea rdi, [rdi + rax*8]
    lea rdi, [rdi + rax*8]
    mov [rsp + 40], rdi
    xor ebx, ebx
71: cmp rbx, [rsp + 8]
    jae 72f
    mov rdi, [rsp + 16]
    imul rdi, rbx
    add rdi, [rsp + 40]
    mov rsi, [r12 + rbx*8]
    mov rdx, [rsp + 16]
    call memcpy
    inc rbx
    jmp 71b
72: mov rdx, [rsp + 8]
    mov rax, [rsp + 16]
    imul rdx, rax
    mov rdi, [rsp]
    mov rsi, [rsp + 40]
    call memcpy
    mov rdi, [rsp + 32]
    call mem_free
9:  EPILOGUE

# wsedit: FN langfeat_show_locations(ext, title ptr, len, body, len) -> eax 1 with the locations
# body (12d) listed in the palette under the title as Find All References lists its results, 0
# when it breaks 12d's rules (feature reveal's show-locations; the Results panel takes it over)
FN langfeat_show_locations
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], rcx
    mov [rsp + 8], r8
    call lf_reset
    mov rax, [rip + g_doc]      # choosing one checks the document asked about: the active one
    mov [rip + lf_doc], rax
    test rax, rax
    jz 1f
    mov rcx, [rax + DOC_id]
    mov [rip + lf_doc_id], rcx
    mov rcx, [rax + DOC_language_revision]
    mov [rip + lf_language_revision], rcx
1:  # the title, at most 200 bytes, as the list's placeholder
    mov rdi, r13
    mov rsi, r12
    mov edx, 200
    call utf8_cut
    mov rcx, rax
    lea rdi, [rip + lf_show_title]
    mov rsi, r12
    rep movsb
    mov byte ptr [rdi], 0
    mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call lf_parse_locations
    test rax, rax
    js 8f
    call lf_sort
    mov dword ptr [rip + lf_list_kind], LF_REFS
    lea rdi, [rip + lf_show_title]
    call palette_results_open
    xor r13d, r13d
2:  cmp r13, [rip + lf_res + VEC_len]
    jae 4f
    imul r14, r13, LS_SIZE
    add r14, [rip + lf_res + VEC_ptr]
    mov rdi, [r14 + LS_label]
    add rdi, [rip + lf_bytes + SB_ptr]
    call strlen
    mov rsi, rax
    mov rdi, [r14 + LS_label]
    add rdi, [rip + lf_bytes + SB_ptr]
    xor edx, edx
    mov rax, [r14 + LS_detail]
    test rax, rax
    js 3f
    mov rdx, rax
    add rdx, [rip + lf_bytes + SB_ptr]
3:  mov rcx, r13
    call palette_results_add
    inc r13
    jmp 2b
4:  call palette_results_ready
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN langfeat_ext_gone(ext): an extension stopped: its requests go (state only)
FN langfeat_ext_gone
    push rdi
    push rdi
    call query_ext_gone
    mov rdi, [rsp]
    call langextra_ext_gone
    mov rdi, [rsp]
    call filediag_ext_gone      # its diagnostics in the Problems store go
    mov rdi, [rsp]
    cmp rdi, [rip + lf_pr_ext]  # prepare-rename waiting on it: failed (the prompt opens as without)
    jne 83f
    mov qword ptr [rip + lf_pr_ext], 0
    cmp dword ptr [rip + lf_pr_state], 1
    jne 83f
    mov dword ptr [rip + lf_pr_state], 4
83: cmp rdi, [rip + lf_wcmd_ext]
    jne 84f
    mov qword ptr [rip + lf_wcmd_ext], 0
84: mov rdi, [rsp]
    call results_ext_gone       # hierarchy rows waiting on it
    mov rdi, [rsp]
    call outline_ext_gone
    mov rdi, [rsp]
    call hovercard_ext_gone
    mov rdi, [rsp]
    call lightbulb_ext_gone
    mov rdi, [rsp]
    call selrange_ext_gone
    mov rdi, [rsp]
    call wsym_ext_gone
    mov rdi, [rsp]
    call doclinks_ext_gone
    mov rdi, [rsp]
    call definitionlink_ext_gone
    pop rdi
    pop rdi
    xor ecx, ecx
1:  cmp rcx, [rip + lf_reqs + VEC_len]
    jae 8f
    imul rax, rcx, LR_SIZE
    add rax, [rip + lf_reqs + VEC_ptr]
    cmp [rax + LR_ext], rdi
    je 2f
    inc rcx
    jmp 1b
2:  # the last record takes its place
    mov rdx, [rip + lf_reqs + VEC_len]
    dec rdx
    mov [rip + lf_reqs + VEC_len], rdx
    imul rdx, rdx, LR_SIZE
    add rdx, [rip + lf_reqs + VEC_ptr]
    mov r8, [rdx]
    mov [rax], r8
    mov r8, [rdx + 8]
    mov [rax + 8], r8
    mov r8, [rdx + 16]
    mov [rax + 16], r8
    jmp 1b
8:  # its results on show forget it: a code action chosen later sends nothing to a restarted one
    xor ecx, ecx
81: cmp rcx, [rip + lf_res + VEC_len]
    jae 82f
    imul rax, rcx, LS_SIZE
    add rax, [rip + lf_res + VEC_ptr]
    inc rcx
    cmp [rax + LS_ext], rdi
    jne 81b
    mov qword ptr [rax + LS_ext], 0
    jmp 81b
82: # nothing more to wait for: the tick finishes the query with what came
    cmp dword ptr [rip + lf_kind], 0
    je 9f
    cmp qword ptr [rip + lf_reqs + VEC_len], 0
    jne 9f
    mov dword ptr [rip + lf_ready], 1
9:  ret

.bss
.p2align 2
lf_tmp4: .zero 16
lf_show_title: .zero 208        # wsedit: show-locations' title

.section .rodata
.p2align 3
# per kind (index LF_*): the verb, the feature, where its patterns are, its query.s kind, a
# toast when nobody provides it, a toast when nothing came, the list's placeholder; one provider?
lf_verbs: .quad 0, .Lv_definition, .Lv_references, .Lv_symbols, .Lv_actions, .Lv_rename, .Lv_format
    .quad .Lv_declaration, .Lv_typedef, .Lv_implementation, .Lv_range_format
lf_feats: .long -1, FEAT_DEFINITION, FEAT_REFERENCES, FEAT_SYMBOLS, FEAT_ACTIONS, FEAT_RENAME, FEAT_FORMAT
    .long FEAT_NAVIGATION, FEAT_NAVIGATION, FEAT_NAVIGATION, FEAT_PARTIAL_FORMAT
.p2align 3
lf_pvs: .quad 0, EXT_pv_definition, EXT_pv_references, EXT_pv_symbols, EXT_pv_actions, EXT_pv_rename, EXT_pv_format
    .quad EXT_pv_declaration, EXT_pv_type_definition, EXT_pv_implementation, EXT_pv_range_format
lf_pks: .long 0, PK_DEFINITION, PK_REFERENCES, PK_SYMBOLS, PK_ACTIONS, PK_RENAME, PK_FORMAT
    .long PK_DECLARATION, PK_TYPEDEF, PK_IMPLEMENTATION, PK_RANGE_FORMAT
.p2align 3
lf_none: .quad 0, .Ln_def, .Ln_refs, .Ln_syms, .Ln_acts, .Ln_rename, .Ln_format
    .quad .Ln_decl, .Ln_typedef, .Ln_impl, .Ln_format
lf_empty: .quad 0, .Le_def, .Le_refs, .Le_syms, .Le_acts, 0, 0
    .quad .Le_decl, .Le_typedef, .Le_impl, 0
lf_lists: .quad 0, .Ll_def, .Ll_refs, .Ll_syms, .Ll_acts, 0, 0
    .quad .Ll_decl, .Ll_typedef, .Ll_impl, 0
lf_single: .byte 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1
.p2align 3
.Lauto_quickfix: .asciz " auto quickfix"
.p2align 3
lf_peek_titles: .quad 0, .Lpk_def, .Lpk_refs, 0, 0, 0, 0, .Lpk_decl, .Lpk_typedef, .Lpk_impl, 0
.Lpk_def: .asciz "definition"
.Lpk_refs: .asciz "references"
.Lpk_decl: .asciz "declaration"
.Lpk_typedef: .asciz "type definition"
.Lpk_impl: .asciz "implementation"
.p2align 3
lf_chain: .quad lf_rs_reply, lf_pr_reply, langextra_reply, results_reply, outline_reply, hovercard_reply, lightbulb_reply, selrange_reply, wsym_reply, doclinks_reply, definitionlink_reply, 0
.Lv_definition: .asciz "definition"
.Lv_references: .asciz "references"
.Lv_symbols: .asciz "symbols"
.Lv_actions: .asciz "actions"
.Lv_rename: .asciz "rename"
.Lv_format: .asciz "format"
.Lv_declaration: .asciz "declaration"
.Lv_typedef: .asciz "type-definition"
.Lv_implementation: .asciz "implementation"
.Lv_range_format: .asciz "range-format"
.Lv_code_actions: .asciz "code-actions "
.Lv_action_resolve: .asciz "code-action-resolve "
.Lv_prepare: .asciz "prepare-rename"
.Lk_invoked_word: .asciz "invoked"
.Ldash: .asciz "-"
.Lsp_dash: .asciz " -"
.Lx_preferred: .asciz "preferred"
.Lx_disabled: .asciz "disabled"
.Lx_resolve: .asciz "resolve"
.Lx_command: .asciz "command"
.Lk_quickfix: .asciz "quickfix"
.Lk_organize: .asciz "source.organizeImports"
.Lk_fixall: .asciz "source.fixAll"
.Lk_refactor: .asciz "refactor"
.Lk_source: .asciz "source"
.Ln_decl: .asciz "No extension finds declarations in this file"
.Ln_typedef: .asciz "No extension finds type definitions in this file"
.Ln_impl: .asciz "No extension finds implementations in this file"
.Le_decl: .asciz "No declaration found"
.Le_typedef: .asciz "No type definition found"
.Le_impl: .asciz "No implementation found"
.Ll_decl: .asciz "Go to declaration"
.Ll_typedef: .asciz "Go to type definition"
.Ll_impl: .asciz "Go to implementation"
.Linvoked: .asciz " invoked "
.Lyes: .asciz "yes"
.Lno: .asciz "no"
.Ln_def: .asciz "No extension finds definitions in this file"
.Ln_refs: .asciz "No extension finds references in this file"
.Ln_syms: .asciz "No extension lists the symbols of this file"
.Ln_acts: .asciz "No extension offers code actions for this file"
.Ln_rename: .asciz "No extension renames symbols in this file"
.Ln_format: .asciz "No extension formats this file"
.Le_def: .asciz "No definition found"
.Le_refs: .asciz "No references found"
.Le_syms: .asciz "No symbols in this file"
.Le_acts: .asciz "No code actions here"
.Ll_def: .asciz "Go to definition"
.Ll_refs: .asciz "Go to reference"
.Ll_syms: .asciz "Go to symbol"
.Ll_acts: .asciz "Code action"
.Lrename_to: .asciz "New name"
.Lname_spaces: .asciz "A name cannot hold spaces"
.Lnothing_renamed: .asciz "Nothing to rename"
.Lrenamed: .asciz "Renamed: check the changed files and save them"
