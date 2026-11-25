# extensions: what they put on documents. Edit records (the edits event, section 6a of
# docs/extensions/v1.md), diagnostic marks (section 6b: gutter dots, underlines, a count in the
# status bar, the message as a tooltip), and the hover position the pointer rests on.
# doc.s calls ext_note_* from its low-level insert and delete when g_ext_hooks is set, so the
# hot path pays one compare when no extension uses any of this.
.include "rhun.inc"

.equ MSG_KEEP, 4000              # a mark keeps its message whole up to this (filediag.s FDG_MSG_MAX); shown cut at MARK_MSG_MAX
.equ LANGS_MAX, 64

.bss
.p2align 3
.globl g_ext_hooks, g_hover_doc, g_hover_pos, g_hover_text, g_hover_since, g_hover_sent
g_ext_hooks: .long 0            # running extensions with an edits subscription, plus 1 once marks exist
g_marks_ever: .long 0
.p2align 3
g_hover_doc: .quad 0            # the document the pointer rests on, or 0
g_hover_pos: .quad 0            # and the position
g_hover_since: .quad 0          # time_ms the pointer came to rest there
g_hover_sent: .long 0           # the hover event went out for this position
g_hover_x: .long 0              # where the pointer is (the tooltip's anchor)
g_hover_y: .long 0
g_hover_text: .zero HOVER_MAX + 1   # what an extension answered for this position, or empty
hover_both: .zero MARK_MSG_MAX + 8 + DECO_TIP_MAX + 8 + HOVER_MAX + 1   # a mark's message, a decoration's tip and the answer together
tmp: .zero SB_SIZE
newmarks: .zero VEC_SIZE        # a diagnostics request's marks while its lines are parsed
target: .quad 0                 # the VEC mark_parse appends to
badpos_seen: .long 0            # mark_parse: the line parsed but a position was outside the text
rec: .zero 80
# ---- Claude chat phase 4 task 9: a generation, the languages ever marked, a message as shown ----
.p2align 3
mk_gen: .quad 0                 # extmarks_gen: moves when a document's marks are set, added or dropped
langs: .zero 8 * LANGS_MAX      # the grammars (DOC_lang, 0 plain text) of documents that ever had marks
nlangs: .quad 0
shown: .zero MARK_MSG_MAX + 8   # extmarks_shown's copy
# ---- end ----

.text

# ---------------- edit records ----------------

# ext_note_insert(doc, pos, ptr, len): a record "POS 0 LEN" + bytes; marks after pos move
FN ext_note_insert
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    cmp dword ptr [rip + g_ext_hooks], 0
    je 9f
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    mov rcx, r14
    call record
    test eax, eax
    jz 1f
    mov rdi, [rbx + DOC_xedits]
    mov rsi, r13
    mov rdx, r14
    call sb_push
1:  mov rdi, rbx                # the edit tape and what presentation keeps (edtape.s)
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call pres_note_insert
    # marks: starts at or after pos move; ends after pos move (an insert at a mark's end stays
    # out); an empty mark moves whole (the edit tape's gravities)
    mov r15, [rbx + DOC_xmarks]
    test r15, r15
    jz 9f
    xor r13d, r13d
2:  cmp r13, [r15 + VEC_len]
    jae 9f
    imul rax, r13, MK_SIZE
    add rax, [r15 + VEC_ptr]
    inc r13
    mov r10, rax
    mov r11d, GR_LEFT           # the end's gravity
    mov rdx, [rax + MK_start]
    cmp rdx, [rax + MK_end]
    jne 21f
    mov r11d, GR_RIGHT
21: mov rdi, [r10 + MK_start]
    mov rsi, r12
    xor edx, edx
    mov rcx, r14
    mov r8d, GR_RIGHT
    call tape_shift
    mov [r10 + MK_start], rax
    mov rdi, [r10 + MK_end]
    mov r8d, r11d
    call tape_shift
    mov [r10 + MK_end], rax
    jmp 2b
9:  EPILOGUE

# ext_note_delete(doc, pos, len): a record "POS LEN 0"; marks shrink or move
FN ext_note_delete
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp dword ptr [rip + g_ext_hooks], 0
    je 9f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    call record
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call pres_note_delete
    mov rdi, [rbx + DOC_xmarks]
    test rdi, rdi
    jz 9f
    lea r14, [r12 + r13]        # end of the deleted range
    xor ecx, ecx
2:  cmp rcx, [rdi + VEC_len]
    jae 9f
    imul rax, rcx, MK_SIZE
    add rax, [rdi + VEC_ptr]
    mov rdx, [rax + MK_start]
    cmp rdx, [rax + MK_end]
    jne 22f
    lea rsi, [rax + MK_start]   # empty before: it moves whole and stays
    call shift_point
    mov rdx, [rax + MK_start]
    mov [rax + MK_end], rdx
    jmp 3f
22: lea rsi, [rax + MK_start]
    call shift_point
    lea rsi, [rax + MK_end]
    call shift_point
    mov rdx, [rax + MK_start]
    cmp rdx, [rax + MK_end]
    jb 3f
    # emptied: drop it (the last mark takes its slot)
    mov rdi, [rbx + DOC_xmarks]
    mov r8, [rdi + VEC_len]
    dec r8
    mov [rdi + VEC_len], r8
    push rcx
    push rax
    mov rdi, [rax + MK_msg]
    call mem_free
    pop rax
    pop rcx
    mov rdi, [rbx + DOC_xmarks]
    mov r8, [rdi + VEC_len]     # (mem_free clobbered r8)
    imul rsi, r8, MK_SIZE
    add rsi, [rdi + VEC_ptr]
    mov rdi, rax
    mov edx, MK_SIZE
    push rcx
    call memcpy
    pop rcx
    mov rdi, [rbx + DOC_xmarks]
    jmp 2b
3:  inc rcx
    jmp 2b
9:  EPILOGUE
# shift_point(rsi ptr to a position): for a delete of r13 bytes at r12 (tape_shift); keeps rax,
# rcx, rdi
shift_point:
    push rax
    push rcx
    push rdi
    push rsi
    mov rdi, [rsi]
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    xor r8d, r8d
    call tape_shift
    pop rsi
    mov [rsi], rax
    pop rdi
    pop rcx
    pop rax
    ret

# record(doc, pos, del, ins) -> 1 when the record was appended ("POS DEL INS\n"; the caller
# appends the inserted bytes), 0 when the records are over their cap (resync instead)
record:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, [rbx + DOC_xedits]
    test rdi, rdi
    jnz 1f
    mov edi, SB_SIZE
    call mem_alloc
    mov [rbx + DOC_xedits], rax
    mov rdi, rax
1:  cmp dword ptr [rbx + DOC_xresync], 0
    jne 8f
    mov rax, [rdi + SB_len]
    add rax, r14
    cmp rax, EDITS_MAX
    ja 7f
    mov rdi, [rbx + DOC_xedits]
    mov rsi, r12
    call sb_push_u64
    mov rdi, [rbx + DOC_xedits]
    mov esi, ' '
    call sb_push_byte
    mov rdi, [rbx + DOC_xedits]
    mov rsi, r13
    call sb_push_u64
    mov rdi, [rbx + DOC_xedits]
    mov esi, ' '
    call sb_push_byte
    mov rdi, [rbx + DOC_xedits]
    mov rsi, r14
    call sb_push_u64
    mov rdi, [rbx + DOC_xedits]
    mov esi, 10
    call sb_push_byte
    mov eax, 1
    EPILOGUE
7:  mov rdi, rbx
    call ext_note_resync
8:  xor eax, eax
    EPILOGUE

# ext_note_resync(doc): the records cannot describe what happened (a reload, a whole-text
# replacement, too many edits): the extension is told to fetch the text
FN ext_note_resync
    cmp dword ptr [rip + g_ext_hooks], 0
    je 9f
    mov dword ptr [rdi + DOC_xresync], 1
    mov rax, [rdi + DOC_xedits]
    test rax, rax
    jz 9f
    mov qword ptr [rax + SB_len], 0
9:  ret

# ext_edits_clear(doc): the frame's records were delivered
FN ext_edits_clear
    PROLOGUE
    mov rbx, rdi
    call extproto_edits_debt
    mov dword ptr [rbx + DOC_xresync], 0
    mov r12, [rbx + DOC_xedits]
    test r12, r12
    jz 9f
    # the records every running subscriber has received go; the rest wait for the next frame
    # (a program whose reads were throttled, or one that edited after its events went out)
    mov r13, [r12 + SB_len]     # the least delivered offset, over the subscribers
    xor r14d, r14d
1:  cmp r14, [rip + g_exts + VEC_len]
    jae 5f
    imul r15, r14, EXT_SIZE
    add r15, [rip + g_exts + VEC_ptr]
    inc r14
    mov rdi, r15
    call ext_is_visible
    test eax, eax
    jz 1b
    cmp dword ptr [r15 + EXT_status], ES_RUNNING
    jne 1b
    cmp qword ptr [r15 + EXT_sub_edits], 0
    je 1b
    mov rdi, r15
    mov rsi, [rbx + DOC_id]
    call extproto_known
    test rax, rax
    jz 1b                       # not told of the document yet: its opened snapshot will be current
    cmp qword ptr [rax + XK_phase], XP_NEED_OPEN
    je 1b
    cmp qword ptr [rax + XK_phase], XP_DORMANT
    je 1b
    mov rax, [rax + XK_eoff]
    cmp rax, r13
    cmovb r13, rax
    jmp 1b
5:  test r13, r13
    jz 9f
    mov rdi, [r12 + SB_ptr]
    lea rsi, [rdi + r13]
    mov rdx, [r12 + SB_len]
    sub rdx, r13
    call memmove
    sub [r12 + SB_len], r13
    # every record's offset moves with the buffer
    xor r14d, r14d
6:  cmp r14, [rip + g_exts + VEC_len]
    jae 9f
    imul r15, r14, EXT_SIZE
    add r15, [rip + g_exts + VEC_ptr]
    inc r14
    mov rdi, r15
    mov rsi, [rbx + DOC_id]
    call extproto_known
    test rax, rax
    jz 6b
    mov rcx, [rax + XK_eoff]
    sub rcx, r13
    jns 7f
    xor ecx, ecx
7:  mov [rax + XK_eoff], rcx
    jmp 6b
9:  EPILOGUE

# ---------------- marks ----------------

# extmarks_set(doc, owner, body ptr, len, count) -> 0, or an error code string in rax (cstr) when
# a line is malformed; replaces the owner's marks with the body's lines "L1 C1 L2 C2 SEV MESSAGE"
FN extmarks_set
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8
    # the lines are parsed into a list of their own first: a bad line leaves the old marks as
    # they were
    mov qword ptr [rip + newmarks + VEC_len], 0
    lea rax, [rip + newmarks]
    mov [rip + target], rax
    lea r15, [r13 + r14]        # end of the body
.Lms_line:
    cmp r13, r15
    jae .Lms_ok
    # the line
    mov rax, r13
2:  cmp rax, r15
    jae 3f
    cmp byte ptr [rax], 10
    je 3f
    inc rax
    jmp 2b
3:  mov [rsp + 8], rax          # line end
    mov rdi, r13
    mov rsi, rax
    sub rsi, r13
    jz .Lms_next
    mov rdx, rbx
    mov rcx, r12
    call mark_parse
    test eax, eax
    jz .Lms_bad
.Lms_next:
    mov r13, [rsp + 8]
    inc r13
    jmp .Lms_line
.Lms_ok:
    mov rax, [rip + newmarks + VEC_len]
    cmp rax, [rsp]
    jne .Lms_count              # not the N the line announced
    cmp rax, MARKS_MAX
    ja .Lms_count
    mov rdi, rbx
    mov rsi, r12
    call marks_drop_owner
    mov rdi, [rbx + DOC_xmarks]
    test rdi, rdi
    jnz 1f
    mov edi, VEC_SIZE
    call mem_alloc
    mov [rbx + DOC_xmarks], rax
1:  mov dword ptr [rip + g_marks_ever], 1
    call ext_hooks_update
    mov rdi, rbx
    call marks_noted
    xor r13d, r13d
4:  cmp r13, [rip + newmarks + VEC_len]
    jae 5f
    mov rdi, [rbx + DOC_xmarks]
    mov esi, MK_SIZE
    call vec_push
    mov rdi, rax
    imul rsi, r13, MK_SIZE
    add rsi, [rip + newmarks + VEC_ptr]
    mov edx, MK_SIZE
    call memcpy
    inc r13
    jmp 4b
5:  xor eax, eax
    EPILOGUE
.Lms_count:
    call newmarks_free
    lea rax, [rip + .Le_count]
    EPILOGUE
.Lms_bad:
    call newmarks_free
    lea rax, [rip + .Le_badmark]
    cmp dword ptr [rip + badpos_seen], 0
    je 1f
    lea rax, [rip + .Le_badpos_mark]
1:  EPILOGUE

# newmarks_free(): the messages of the temporary list
newmarks_free:
    push rbx
    xor ebx, ebx
1:  cmp rbx, [rip + newmarks + VEC_len]
    jae 2f
    imul rax, rbx, MK_SIZE
    add rax, [rip + newmarks + VEC_ptr]
    mov rdi, [rax + MK_msg]
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + newmarks + VEC_len], 0
    pop rbx
    ret

# mark_parse(ptr, len, doc, owner) -> 1 and a mark appended, 0 when the line cannot be read
mark_parse:
    PROLOGUE 64
    mov dword ptr [rip + badpos_seen], 0
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov rbx, rdx
    mov r12, rcx
    # four numbers
    xor r15d, r15d
1:  mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call next_word
    test rdx, rdx
    jz 8f
    add [rsp], rcx
    sub [rsp + 8], rcx
    cmp rdx, 10                 # coordinates use the same bound as workspace edits
    ja 8f
    mov [rsp + 48], rdx
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    cmp rdx, [rsp + 48]
    jne 8f
    mov [rsp + 16 + r15*8], rax
    inc r15d
    cmp r15d, 4
    jb 1b
    # positions
    mov dword ptr [rip + badpos_seen], 0
    mov rdi, rbx
    mov rsi, [rsp + 16]
    mov rdx, [rsp + 24]
    call mark_pos
    test rax, rax
    js 7f
    mov r13, rax
    mov rdi, rbx
    mov rsi, [rsp + 32]
    mov rdx, [rsp + 40]
    call mark_pos
    test rax, rax
    js 7f
    mov r14, rax
    cmp r14, r13
    jb 7f
    # severity
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call next_word
    test rdx, rdx
    jz 8f
    add [rsp], rcx
    sub [rsp + 8], rcx
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    call severity_of
    test eax, eax
    js 8f
    mov r15d, eax
    mov [rsp + 56], edx         # its tags
    # the message: the rest, trimmed, kept whole up to MSG_KEEP (shown cut at MARK_MSG_MAX: extmarks_shown)
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call trim
    mov rdi, rdx
    mov rsi, rax
    mov edx, MSG_KEEP
    push rax
    push rax
    call utf8_cut
    pop rdi
    pop rdi
    mov rsi, rax
    call mem_dup
    mov rdi, [rip + target]
    mov esi, MK_SIZE
    push rax
    push rax
    call vec_push
    pop rcx
    pop rcx
    mov [rax + MK_msg], rcx
    mov [rax + MK_owner], r12
    mov [rax + MK_start], r13
    mov [rax + MK_end], r14
    mov [rax + MK_sev], r15d
    mov ecx, [rsp + 56]
    mov [rax + MK_pad], ecx
    mov eax, 1
    EPILOGUE
7:  mov dword ptr [rip + badpos_seen], 1
8:  xor eax, eax
    EPILOGUE

# mark_pos(doc, line, col) -> byte position, or -1 (1-based line and byte column; a column
# one past the line's end is the line feed)
FN mark_pos
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
    sub rax, r14
    lea rcx, [r13 - 1]
    cmp rcx, rax
    ja 8f
    je 7f
    # not inside a multibyte character
    mov rdi, rbx
    lea rsi, [r14 + rcx]
    push rcx
    call doc_byte
    pop rcx
    and eax, 0xc0
    cmp eax, 0x80
    je 8f
7:  lea rax, [r14 + rcx]
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# severity_of(ptr, len, owner) -> eax SEV_* or -1, edx MKT_* tags: an owner that agreed
# diagnostic-tags may write SEVERITY+TAG[+TAG] (unknown tags are left out)
severity_of:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r14d, r14d              # tags
    FEAT_TEST rdx, FEAT_DIAG_TAGS
    jz 0f
    xor ecx, ecx                # the severity ends at the first '+'
5:  cmp rcx, r12
    jae 0f
    cmp byte ptr [rbx + rcx], '+'
    je 6f
    inc rcx
    jmp 5b
6:  lea r15, [rbx + rcx + 1]    # the tags
    mov r13, r12
    sub r13, rcx
    dec r13
    mov r12, rcx
    call tags_of
    mov r14d, eax
0:  xor r13d, r13d
1:  lea rax, [rip + sev_names]
    mov rdx, [rax + r13*8]
    test rdx, rdx
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 9f
    inc r13d
    jmp 1b
8:  mov eax, -1
    EPILOGUE
9:  mov eax, r13d
    mov edx, r14d
    EPILOGUE

# tags_of(r15 ptr, r13 len) -> eax MKT_* of "TAG+TAG..." (unknown ones ignored)
tags_of:
    push rbx
    push r12
    push r14
    xor r14d, r14d
1:  test r13, r13
    jz 9f
    xor ecx, ecx
2:  cmp rcx, r13
    jae 3f
    cmp byte ptr [r15 + rcx], '+'
    je 3f
    inc rcx
    jmp 2b
3:  mov rbx, rcx
    mov rdi, r15
    mov rsi, rcx
    lea rdx, [rip + .Ltag_unnecessary]
    call str_eq_cstr
    test eax, eax
    jz 4f
    or r14d, MKT_UNNECESSARY
4:  mov rdi, r15
    mov rsi, rbx
    lea rdx, [rip + .Ltag_deprecated]
    call str_eq_cstr
    test eax, eax
    jz 5f
    or r14d, MKT_DEPRECATED
5:  add r15, rbx
    sub r13, rbx
    test r13, r13
    jz 9f
    inc r15                     # the '+'
    dec r13
    jmp 1b
9:  mov eax, r14d
    pop r14
    pop r12
    pop rbx
    ret

# marks_drop_owner(doc, owner): remove the owner's marks from one document
marks_drop_owner:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + DOC_xmarks]
    test rdi, rdi
    jz 9f
    xor ecx, ecx
1:  mov rdi, [rbx + DOC_xmarks]
    cmp rcx, [rdi + VEC_len]
    jae 9f
    imul rax, rcx, MK_SIZE
    add rax, [rdi + VEC_ptr]
    cmp [rax + MK_owner], r12
    jne 2f
    mov r13, rcx
    mov rdi, [rax + MK_msg]
    call mem_free
    mov rdi, [rbx + DOC_xmarks]
    mov r8, [rdi + VEC_len]
    dec r8
    mov [rdi + VEC_len], r8
    imul rsi, r8, MK_SIZE
    add rsi, [rdi + VEC_ptr]
    imul rdi, r13, MK_SIZE
    mov rax, [rbx + DOC_xmarks]
    add rdi, [rax + VEC_ptr]
    mov edx, MK_SIZE
    call memcpy
    mov rcx, r13
    jmp 1b
2:  inc rcx
    jmp 1b
9:  inc qword ptr [rip + mk_gen]
    EPILOGUE

# extmarks_clear_owner(owner): the extension stopped: its marks go, on every open document
FN extmarks_clear_owner
    PROLOGUE
    mov r12, rdi
    call deco_clear_owner       # and its decorations (deco.s)
    mov rdi, r12
    call present_ext_gone       # and its presentation requests and folding ranges (present.s)
    xor r13d, r13d
1:  cmp r13, [rip + g_tabs + VEC_len]
    jae 9f
    imul rax, r13, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    inc r13
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 1b
    mov rdi, [rax + TAB_doc]
    test rdi, rdi
    jz 1b
    mov rsi, r12
    call marks_drop_owner
    jmp 1b
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# Clear visual diagnostics without losing the document's pending edit history.
FN extmarks_language_changed
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + DOC_xmarks]
    test r12, r12
    jz 9f
    # the Problems store's marks stay (its sources do not resend them); extensions' marks go
    xor r13d, r13d              # read
    xor r14d, r14d              # kept
1:  cmp r13, [r12 + VEC_len]
    jae 2f
    imul r15, r13, MK_SIZE
    add r15, [r12 + VEC_ptr]
    inc r13
    test dword ptr [r15 + MK_pad], MKF_SOURCE
    jz 11f
    imul rdi, r14, MK_SIZE
    add rdi, [r12 + VEC_ptr]
    inc r14
    mov rsi, r15
    mov edx, MK_SIZE
    call memmove
    jmp 1b
11: mov rdi, [r15 + MK_msg]
    call mem_free
    jmp 1b
2:  mov [r12 + VEC_len], r14
    mov dword ptr [rip + g_dirty], 1
    inc qword ptr [rip + mk_gen]
9:  EPILOGUE

# extmarks_drop_all(doc): every mark goes, the store's too (the document is closing)
extmarks_drop_all:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + DOC_xmarks]
    test r12, r12
    jz 9f
    mov qword ptr [rbx + DOC_xmarks], 0
    xor r13d, r13d
1:  cmp r13, [r12 + VEC_len]
    jae 2f
    imul rax, r13, MK_SIZE
    add rax, [r12 + VEC_ptr]
    mov rdi, [rax + MK_msg]
    call mem_free
    inc r13
    jmp 1b
2:  mov rdi, r12
    call vec_free
    mov rdi, r12
    call mem_free
9:  EPILOGUE

# extmarks_free(doc): the document is closing
FN extmarks_free
    PROLOGUE
    mov rbx, rdi
    call pres_free
    mov rdi, rbx
    call extmarks_drop_all
    mov rdi, [rbx + DOC_xedits]
    test rdi, rdi
    jz 9f
    mov rdi, [rdi + SB_ptr]
    call mem_free
    mov rdi, [rbx + DOC_xedits]
    call mem_free
    mov qword ptr [rbx + DOC_xedits], 0
9:  EPILOGUE

# extmarks_line(doc, line) -> eax the worst severity of a mark touching the line (0 error ..
# 3 hint), or -1 for none; a mark ending at the next line's start touches this line's end
FN extmarks_line
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + DOC_xmarks]
    test rdi, rdi
    jz 8f
    cmp qword ptr [rdi + VEC_len], 0
    je 8f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov r13, rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    mov r14, rax                # the line's LF position (or the end): still this line
    mov r15d, -1
    mov rdi, [rbx + DOC_xmarks]
    xor ecx, ecx
1:  cmp rcx, [rdi + VEC_len]
    jae 9f
    imul rax, rcx, MK_SIZE
    add rax, [rdi + VEC_ptr]
    inc rcx
    call mark_visible_flags
    jz 1b
    mov rdx, [rax + MK_start]
    cmp rdx, r14
    ja 1b                       # starts after this line
    mov rdx, [rax + MK_end]
    cmp rdx, r13
    jb 1b                       # ends before it
    je 2f
    jmp 3f
2:  cmp qword ptr [rax + MK_start], r13   # an empty mark exactly at the line start counts
    jne 1b
3:  mov edx, [rax + MK_sev]
    cmp r15d, -1
    je 4f
    cmp edx, r15d
    jge 1b
4:  mov r15d, edx
    jmp 1b
8:  mov eax, -1
    EPILOGUE
9:  mov eax, r15d
    EPILOGUE

# extmarks_color(SEV_*) -> argb
.globl extmarks_color
extmarks_color:
    test edi, edi
    jnz 1f
    COLOR eax, T_ERROR
    ret
1:  cmp edi, SEV_WARNING
    jne 2f
    COLOR eax, T_WARNING
    ret
2:  COLOR eax, T_INFO
    cmp edi, SEV_INFO
    je 3f
    COLOR eax, T_HINT
3:  ret

# extmarks_row(doc, line, from, to, basex, y): underlines under the marks of one visual row
# (bytes [from, to) of the line, drawn from basex)
FN extmarks_row
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], rdx              # from
    mov [rsp + 8], rcx          # to
    mov [rsp + 16], r8d         # basex
    mov [rsp + 20], r9d         # y
    mov rdi, [rbx + DOC_xmarks]
    test rdi, rdi
    jz 9f
    cmp qword ptr [rdi + VEC_len], 0
    je 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov r13, rax                # line start pos
    mov rdi, rbx
    mov rsi, r12
    call doc_line_text
    mov [rsp + 24], rax         # text
    mov [rsp + 32], rdx         # length
    xor r14d, r14d
.Lmr_each:
    mov rdi, [rbx + DOC_xmarks]
    cmp r14, [rdi + VEC_len]
    jae 9f
    imul r15, r14, MK_SIZE
    add r15, [rdi + VEC_ptr]
    inc r14
    mov rdi, r15
    call mark_live
    test eax, eax
    jz .Lmr_each
    cmp dword ptr [r15 + MK_sev], SEV_HINT  # a hint tagged unnecessary is only faded (deco.s)
    jne 0f
    test dword ptr [r15 + MK_pad], MKT_UNNECESSARY
    jnz .Lmr_each
0:  # the mark's byte range on this line, as offsets within the line, clipped to the row
    mov rax, [r15 + MK_start]
    sub rax, r13
    mov rdx, [r15 + MK_end]
    sub rdx, r13
    js .Lmr_each                # ends before this line
    cmp rax, [rsp + 32]
    jg .Lmr_each                # starts after it (an end at the line's LF underlines its last column)
    test rax, rax
    jns 1f
    xor eax, eax                # started on an earlier line
1:  cmp rdx, [rsp + 32]
    jle 2f
    mov rdx, [rsp + 32]
2:  # clip to the row's segment
    cmp rax, [rsp]
    jge 3f
    mov rax, [rsp]
3:  cmp rdx, [rsp + 8]
    jle 4f
    mov rdx, [rsp + 8]
4:  cmp rdx, rax
    jl .Lmr_each
    jne 5f
    cmp rax, [rsp + 32]
    jne .Lmr_each
    cmp rdx, [rsp + 8]
    jne .Lmr_each               # an empty mark at the line's end: one cell wide, below
    inc rdx
5:  mov [rsp + 40], rdx
    # x of both ends, by the range rule over the row's inlays (vtext.s; draw_line set the row)
    mov rdi, rax
    mov esi, VTM_RIGHT
    call vt_x
    mov r8d, eax
    mov rdi, [rsp + 40]
    mov esi, VTM_LEFT
    push r8
    push r8
    call vt_x
    pop r8
    pop r8
    sub eax, r8d
    jle .Lmr_each
    mov edi, [r15 + MK_sev]
    push rax
    push r8
    call extmarks_color
    pop r8
    pop rdx                     # width
    mov edi, r8d
    mov esi, [rsp + 20]
    add esi, [rip + g_lh]
    sub esi, [rip + g_mt + 4*MI_2]
    mov ecx, [rip + g_mt + 4*MI_1]
    mov r8d, eax
    call gfx_fill
    jmp .Lmr_each
9:  EPILOGUE

# extmarks_counts(doc) -> eax errors, edx warnings
FN extmarks_counts
    PROLOGUE
    xor r13d, r13d
    xor r14d, r14d
    test rdi, rdi
    jz 9f
    mov rbx, [rdi + DOC_xmarks]
    test rbx, rbx
    jz 9f
    xor r12d, r12d
1:  cmp r12, [rbx + VEC_len]
    jae 9f
    imul r15, r12, MK_SIZE
    add r15, [rbx + VEC_ptr]
    inc r12
    mov rdi, r15
    call mark_live
    test eax, eax
    jz 1b
    cmp dword ptr [r15 + MK_sev], SEV_ERROR
    jne 2f
    inc r13d
    jmp 1b
2:  cmp dword ptr [r15 + MK_sev], SEV_WARNING
    jne 1b
    inc r14d
    jmp 1b
9:  mov eax, r13d
    mov edx, r14d
    EPILOGUE

# extmarks_at(doc, pos) -> owned message for a visible supplier, or0.
FN extmarks_at
    PROLOGUE
    mov rbx, [rdi + DOC_xmarks]
    mov r12, rsi
    test rbx, rbx
    jz 8f
    xor r13d, r13d
1:  cmp r13, [rbx + VEC_len]
    jae 8f
    imul r14, r13, MK_SIZE
    add r14, [rbx + VEC_ptr]
    inc r13
    cmp [r14 + MK_start], r12
    ja 1b
    cmp [r14 + MK_end], r12
    jbe 1b
    mov rdi, r14
    call mark_live
    test eax, eax
    jz 1b
    mov rdi, [r14 + MK_msg]
    call extmarks_shown
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN extmarks_nth_at(doc, pos, n) -> rax the n-th (from 0) live mark covering the position, or 0
# (the hover card's diagnostics, hovercard.s)
FN extmarks_nth_at
    PROLOGUE
    mov rbx, [rdi + DOC_xmarks]
    mov r12, rsi
    mov r15, rdx
    test rbx, rbx
    jz 8f
    xor r13d, r13d
1:  cmp r13, [rbx + VEC_len]
    jae 8f
    imul r14, r13, MK_SIZE
    add r14, [rbx + VEC_ptr]
    inc r13
    cmp [r14 + MK_start], r12
    ja 1b
    cmp [r14 + MK_end], r12
    jbe 1b
    mov rdi, r14
    call mark_live
    test eax, eax
    jz 1b
    test r15, r15
    jz 2f
    dec r15
    jmp 1b
2:  mov rax, r14
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- hover ----------------

# ext_hover_track(doc, pos): the pointer is over this position of the document this frame
# (doc 0: over no text); a new position restarts the half-second rest
FN ext_hover_track
    cmp rdi, [rip + g_hover_doc]
    jne 1f
    cmp rsi, [rip + g_hover_pos]
    jne 1f
    mov eax, [rip + g_mx]
    mov [rip + g_hover_x], eax
    mov eax, [rip + g_my]
    mov [rip + g_hover_y], eax
    ret
1:  mov [rip + g_hover_doc], rdi
    mov [rip + g_hover_pos], rsi
    mov dword ptr [rip + g_hover_sent], 0
    mov byte ptr [rip + g_hover_text], 0
    mov eax, [rip + g_mx]
    mov [rip + g_hover_x], eax
    mov eax, [rip + g_my]
    mov [rip + g_hover_y], eax
    push rdi
    call time_ms
    pop rdi
    mov [rip + g_hover_since], rax
    test rdi, rdi
    jz 2f
    mov dword ptr [rip + g_dirty], 1    # the tooltip, if one shows, goes away
2:  ret

# ext_hover_tip(): the frame's tooltip for the rest position: a mark's message, or what an
# extension answered (called by editor_draw while the pointer is over the text)
FN ext_hover_tip
    PROLOGUE
    mov rbx, [rip + g_hover_doc]
    test rbx, rbx
    jz 9f
    call hovercard_covers       # the hover card shows (or is about to) what the tooltip would
    test eax, eax
    jnz 9f
    # a mark's message, a decoration's tip and an extension's answer, as "A · B · C" so none
    # hides another
    lea r12, [rip + hover_both]
    mov byte ptr [r12], 0
    call dg_hover_text          # debugger: while paused, the value under the pointer wins
    test rax, rax
    jnz 1f
    mov rdi, rbx
    mov rsi, [rip + g_hover_pos]
    call extmarks_at
    mov rdi, rax
    call hover_part
    mov rdi, rbx
    mov rsi, [rip + g_hover_pos]
    call deco_tip_at
    mov rdi, rax
    call hover_part
    lea rdi, [rip + g_hover_text]
    call hover_part
    lea rax, [rip + hover_both]
    cmp byte ptr [rax], 0
    je 9f
1:  mov r9, rax
    mov edi, ID_EXT_HOVER
    mov esi, [rip + g_hover_x]
    mov edx, [rip + g_hover_y]
    add edx, [rip + g_mt + 4*MI_8]
    mov ecx, 1
    mov r8d, UB_HOVER
    call tip_note_text
9:  EPILOGUE

# hover_part(cstr or 0): appended to hover_both at r12 (the end), after a dot when not the first
hover_part:
    test rdi, rdi
    jz 9f
    cmp byte ptr [rdi], 0
    je 9f
    push rdi
    lea rax, [rip + hover_both]
    cmp r12, rax
    je 1f
    mov rdi, r12
    lea rsi, [rip + .Lhover_dot]
    call cstr_copy
    mov r12, rax
1:  pop rsi
    mov rdi, r12
    call cstr_copy
    mov r12, rax
9:  ret

# ext_hover_due() -> ms until the hover event is due for the rest position, or -1
FN ext_hover_due
    PROLOGUE
    cmp qword ptr [rip + g_hover_doc], 0
    je 8f
    cmp dword ptr [rip + g_hover_sent], 0
    jne 8f
    xor ebx, ebx
7:  cmp rbx, [rip + g_exts + VEC_len]
    jae 8f
    imul r12, rbx, EXT_SIZE
    add r12, [rip + g_exts + VEC_ptr]
    inc rbx
    mov rdi, r12
    call ext_is_visible
    test eax, eax
    jz 7b
    cmp dword ptr [r12 + EXT_status], ES_RUNNING
    jne 7b
    cmp qword ptr [r12 + EXT_sub_hover], 0
    je 7b
    call time_ms
    mov rcx, [rip + g_hover_since]
    add rcx, HOVER_REST_MS
    sub rcx, rax
    jns 1f
    xor ecx, ecx
1:  mov eax, ecx
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# ext_hover_forget(doc): the document is going away (or an extension did): nothing rests on it
FN ext_hover_forget
    cmp rdi, [rip + g_hover_doc]
    jne 1f
    mov qword ptr [rip + g_hover_doc], 0
    mov qword ptr [rip + g_hover_pos], 0
    mov dword ptr [rip + g_hover_sent], 0
1:  mov byte ptr [rip + g_hover_text], 0
    ret

# ext_hover_text_set(doc, pos, ptr, len) -> 1 when it is for the position the pointer rests on
FN ext_hover_text_set
    cmp rdi, [rip + g_hover_doc]
    jne 8f
    cmp rsi, [rip + g_hover_pos]
    jne 8f
    cmp rcx, HOVER_MAX
    jbe 1f
    mov ecx, HOVER_MAX
1:  lea rdi, [rip + g_hover_text]
    mov rsi, rdx
    push rcx
    push rcx
    mov rdx, rcx
    call memcpy
    pop rcx
    pop rcx
    lea rdi, [rip + g_hover_text]
    mov byte ptr [rdi + rcx], 0
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# ext_hooks_update(): g_ext_hooks from the running extensions' edits subscriptions and the marks
FN ext_hooks_update
    PROLOGUE
    xor r12d, r12d
    xor ebx, ebx
1:  cmp rbx, [rip + g_exts + VEC_len]
    jae 2f
    imul r13, rbx, EXT_SIZE
    add r13, [rip + g_exts + VEC_ptr]
    inc rbx
    mov rdi, r13
    call ext_is_visible
    test eax, eax
    jz 1b
    cmp dword ptr [r13 + EXT_status], ES_RUNNING
    jne 1b
    cmp qword ptr [r13 + EXT_sub_edits], 0
    je 1b
    inc r12d
    jmp 1b
2:  add r12d, [rip + g_marks_ever]
    add r12d, [rip + g_pres_ever]   # documents keep an edit tape (edtape.s)
    mov [rip + g_ext_hooks], r12d
    EPILOGUE

# mark_live(MK*) -> eax 1 when it is shown: a problems source's always (problems.s), an extension's
#   while the extension is
.globl mark_live
mark_live:
    test dword ptr [rdi + MK_pad], MKF_SOURCE
    jnz 1f
    mov rdi, [rdi + MK_owner]
    jmp ext_is_visible
1:  mov eax, 1
    ret

# extmarks_add_source(doc, source, start, end, SEV_*, message cstr): a mark of the Problems store
#   (problems.s), its message copied whole (up to MSG_KEEP bytes; shown cut at MARK_MSG_MAX)
FN extmarks_add_source
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8d
    mov [rsp + 8], r9
    mov rdi, [rbx + DOC_xmarks]
    test rdi, rdi
    jnz 1f
    mov edi, VEC_SIZE
    call mem_alloc
    mov [rbx + DOC_xmarks], rax
1:  mov rax, [rbx + DOC_xmarks]
    cmp qword ptr [rax + VEC_len], MARKS_MAX * 4
    jae 9f
    mov dword ptr [rip + g_marks_ever], 1
    call ext_hooks_update
    mov rdi, rbx
    call marks_noted
    mov rdi, [rsp + 8]
    call strlen
    mov rdi, rax
    mov rsi, [rsp + 8]
    mov edx, MSG_KEEP
    call utf8_cut
2:  mov rdi, [rsp + 8]
    mov rsi, rax
    call mem_dup
    mov r15, rax
    mov rdi, [rbx + DOC_xmarks]
    mov esi, MK_SIZE
    call vec_push
    mov [rax + MK_owner], r12
    mov [rax + MK_start], r13
    mov [rax + MK_end], r14
    mov ecx, [rsp]
    mov [rax + MK_sev], ecx
    mov dword ptr [rax + MK_pad], MKF_SOURCE
    mov [rax + MK_msg], r15
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# RAX mark -> ZF1 when unavailable. Preserve every caller register for the range scan.
mark_visible_flags:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov rdi, rax
    call mark_live
    test eax, eax
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

.section .rodata
.Lhover_dot: .asciz "  \302\267  "
.p2align 3
sev_names: .quad .Lsv_error, .Lsv_warning, .Lsv_info, .Lsv_hint, 0
.Lsv_error: .asciz "error"
.Lsv_warning: .asciz "warning"
.Lsv_info: .asciz "info"
.Lsv_hint: .asciz "hint"
.Ltag_unnecessary: .asciz "unnecessary"
.Ltag_deprecated: .asciz "deprecated"
.Le_badmark: .asciz "syntax a diagnostics line is not L1 C1 L2 C2 SEVERITY MESSAGE"
.Le_badpos_mark: .asciz "badpos a diagnostics range is outside the document or inside a character"
.Le_count: .asciz "syntax the body does not have N lines"

# ---- Claude chat phase 4 task 9: a generation, the languages ever marked, a message as shown ----
.text
# marks_noted(doc): marks were set or added on it: the generation moves, its language is remembered
marks_noted:
    inc qword ptr [rip + mk_gen]
    mov rax, [rdi + DOC_lang]
    xor ecx, ecx
1:  cmp rcx, [rip + nlangs]
    jae 2f
    lea rdx, [rip + langs]
    cmp [rdx + rcx*8], rax
    je 9f
    inc rcx
    jmp 1b
2:  cmp rcx, LANGS_MAX
    jae 9f
    lea rdx, [rip + langs]
    mov [rdx + rcx*8], rax
    inc qword ptr [rip + nlangs]
9:  ret

# FN extmarks_gen() -> rax a number that moves whenever a document's marks are set, added or dropped
FN extmarks_gen
    mov rax, [rip + mk_gen]
    ret

# FN extmarks_lang_marked(doc) -> eax 1 when a document of its language (DOC_lang) ever had marks
FN extmarks_lang_marked
    mov rax, [rdi + DOC_lang]
    xor ecx, ecx
1:  cmp rcx, [rip + nlangs]
    jae 8f
    lea rdx, [rip + langs]
    cmp [rdx + rcx*8], rax
    je 9f
    inc rcx
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# FN extmarks_shown(msg cstr or 0) -> rax the message as a tooltip, the hover card, the status text and the
#   dumps show it: itself, or (longer than MARK_MSG_MAX bytes) a copy cut there at a character's start,
#   valid until the next call
FN extmarks_shown
    PROLOGUE
    mov rbx, rdi
    test rdi, rdi
    jz 8f
    call strlen
    cmp rax, MARK_MSG_MAX
    jbe 8f
    mov rdi, rax
    mov rsi, rbx
    mov edx, MARK_MSG_MAX
    call utf8_cut
    mov r12, rax
    lea rdi, [rip + shown]
    mov rsi, rbx
    mov rdx, r12
    call memcpy
    lea rax, [rip + shown]
    mov byte ptr [rax + r12], 0
    EPILOGUE
8:  mov rax, rbx
    EPILOGUE
# ---- end ----
