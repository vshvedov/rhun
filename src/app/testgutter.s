# testing: what the test model puts in the editor. Failure messages with a place become problems
# (problems.s): one source per controller ("tests:OWNER/NAME"), rebuilt from the items' last results
# after results change, so the problems and their marks (gutter dot, underline, hover) follow each
# run and go when a test passes or is removed. Gutter glyphs and coverage tints are the editor
# presentation's lanes (later).
.include "rhun.inc"

.bss
.p2align 3
.globl g_ts_marks
g_ts_marks: .long 0             # results changed: the problems are rebuilt at the next tick
.p2align 3
pr: .zero PR_SIZE
key: .zero SB_SIZE
msg: .zero SB_SIZE
path: .zero 4096

.text

# testgutter_item_gone(ext, index): an item went: its problems with it (at the next rebuild)
FN testgutter_item_gone
    mov dword ptr [rip + g_ts_marks], 1
    mov dword ptr [rip + g_ts_glyphs], 1    # and its glyph
    ret

# testgutter_item_changed(ext, index): an item's range or file changed
FN testgutter_item_changed
    mov dword ptr [rip + g_ts_glyphs], 1
    ret

# source_of(TSC*) -> PS*: the controller's problems source
source_of:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + key]
    call sb_clear
    lea rdi, [rip + key]
    lea rsi, [rip + .Lkey]
    call sb_push_cstr
    mov r12, [rbx + TSC_ext]
    lea rdi, [rip + key]
    mov rsi, [r12 + EXT_owner]
    call sb_push_cstr
    lea rdi, [rip + key]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + key]
    mov rsi, [r12 + EXT_name]
    call sb_push_cstr
    lea rdi, [rip + key]
    xor esi, esi
    call sb_push_byte
    mov rdi, rbx
    xor esi, esi
    call testmodel_item
    mov rsi, [rax + TSI_label]  # the controller's title
    mov rdi, [rip + key + SB_ptr]
    call problems_source
    EPILOGUE

# testgutter_tick(): the problems again from the results, when they changed
FN testgutter_tick
    PROLOGUE
    call testgutter_glyphs
    cmp dword ptr [rip + g_ts_marks], 0
    je 9f
    mov dword ptr [rip + g_ts_marks], 0
    lea rbx, [rip + g_ts_ctrls]
    xor r12d, r12d
1:  cmp qword ptr [rbx + TSC_ext], 0
    je 4f
    mov rdi, rbx
    call source_of
    mov r13, rax
    mov rdi, rax
    call problems_clear
    mov r14d, 1
2:  cmp r14, [rbx + TSC_items + VEC_len]
    jae 4f
    mov rdi, rbx
    mov rsi, r14
    call testmodel_item
    cmp qword ptr [rax + TSI_id], 0
    je 3f
    mov ecx, [rax + TSI_own]
    cmp ecx, TSS_FAILED
    je 21f
    cmp ecx, TSS_ERRORED
    jne 3f
21: mov rdi, rbx
    mov rsi, r14
    call testmodel_result
    test rax, rax
    jz 3f
    mov rdi, r13
    mov rsi, rax
    mov rdx, rbx
    mov rcx, r14
    call add_messages
3:  inc r14
    jmp 2b
4:  add rbx, TSC_SIZE
    inc r12d
    cmp r12d, TS_CTRL_MAX
    jb 1b
9:  EPILOGUE

# add_messages(PS*, TSE*, tsc, index): a problem per message with a place: "LABEL: first line", then
#   "Expected: …" and "Actual: …" first lines when the message has values
add_messages:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rdx
    mov [rsp + 8], rcx
    mov r12, [rsi + TSE_msgs + SB_ptr]
    mov r13, [rsi + TSE_msgs + SB_len]
    add r13, r12
1:  cmp r12, r13
    jae 9f
    mov r14, r12                # the header
    lea r15, [r12 + TSM_SIZE]   # the text
    mov eax, [r14 + TSM_text]
    mov ecx, [r14 + TSM_path]
    lea rdx, [r15 + rax]        # the path
    cmp dword ptr [r14 + TSM_l1], 0
    je 8f
    test ecx, ecx
    jz 8f
    cmp ecx, 4000
    jae 8f
    lea rdi, [rip + path]
    mov rsi, rdx
    mov rdx, rcx
    call memcpy
    mov ecx, [r14 + TSM_path]
    lea rax, [rip + path]
    mov byte ptr [rax + rcx], 0
    # the message
    lea rdi, [rip + msg]
    call sb_clear
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call testmodel_item
    mov rsi, [rax + TSI_label]
    lea rdi, [rip + msg]
    call sb_push_cstr
    lea rdi, [rip + msg]
    lea rsi, [rip + .Lcolon]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [r14 + TSM_text]
    call first_line
    push rdx
    push rdx
    lea rdi, [rip + msg]
    mov rsi, rax
    call sb_push
    pop rdx
    pop rdx
    # the values' first lines
    mov eax, [r14 + TSM_text]
    add eax, [r14 + TSM_path]
    lea r15, [r15 + rax]        # expected
    cmp dword ptr [r14 + TSM_exp], -1
    je 3f
    cmp dword ptr [r14 + TSM_act], -1
    je 3f
    lea rdi, [rip + msg]
    lea rsi, [rip + .Lexpected]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [r14 + TSM_exp]
    call first_line
    lea rdi, [rip + msg]
    mov rsi, rax
    call sb_push
    mov eax, [r14 + TSM_exp]
    add r15, rax                # actual
    lea rdi, [rip + msg]
    lea rsi, [rip + .Lactual]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [r14 + TSM_act]
    call first_line
    lea rdi, [rip + msg]
    mov rsi, rax
    call sb_push
3:  lea rdi, [rip + msg]
    xor esi, esi
    call sb_push_byte
    # the problem: its place (an empty range marks the line)
    lea rdi, [rip + pr]
    xor esi, esi
    mov edx, PR_SIZE
    call memset
    lea rax, [rip + path]
    mov [rip + pr + PR_path], rax
    lea rdi, [rip + path]
    lea rsi, [r14 + TSM_ver]
    mov edx, [r14 + TSM_l1]
    call tg_map_path
    mov [rip + pr + PR_line], eax
    mov eax, [r14 + TSM_c1]
    mov [rip + pr + PR_col], eax
    mov eax, [r14 + TSM_l1]
    cmp eax, [r14 + TSM_l2]
    jne 4f
    mov eax, [r14 + TSM_c1]
    cmp eax, [r14 + TSM_c2]
    je 5f
4:  lea rdi, [rip + path]
    lea rsi, [r14 + TSM_ver]
    mov edx, [r14 + TSM_l2]
    call tg_map_path
    mov [rip + pr + PR_endline], eax
    mov eax, [r14 + TSM_c2]
    mov [rip + pr + PR_endcol], eax
5:  mov dword ptr [rip + pr + PR_sev], SEV_ERROR
    mov rax, [rip + msg + SB_ptr]
    mov [rip + pr + PR_msg], rax
    mov rdi, rbx
    lea rsi, [rip + pr]
    call problems_add
8:  # the next message
    mov eax, TSM_SIZE
    add eax, [r14 + TSM_text]
    add eax, [r14 + TSM_path]
    mov ecx, [r14 + TSM_exp]
    cmp ecx, -1
    je 81f
    add eax, ecx
81: mov ecx, [r14 + TSM_act]
    cmp ecx, -1
    je 82f
    add eax, ecx
82: add r12, rax
    jmp 1b
9:  EPILOGUE

# first_line(ptr, len) -> rax ptr, rdx the length of its first line (at most 200 bytes)
first_line:
    mov rax, rdi
    mov esi, esi
    xor edx, edx
1:  cmp rdx, rsi
    jae 9f
    cmp rdx, 200
    jae 9f
    cmp byte ptr [rax + rdx], 10
    je 9f
    inc rdx
    jmp 1b
9:  ret

# testgutter_forget(ext): its problems go (the extension is removed)
FN testgutter_forget
    PROLOGUE
    mov dword ptr [rip + g_ts_glyphs], 1    # its glyphs go too
    call testmodel_ctrl
    test rax, rax
    jz 9f
    mov rdi, rax
    call source_of
    mov rdi, rax
    call problems_clear
9:  EPILOGUE

.section .rodata
.Lkey: .asciz "tests:"
.Lcolon: .asciz ": "
.Lexpected: .asciz "\nExpected: "
.Lactual: .asciz "\nActual: "

# ---------------- glyphs and coverage tints ----------------
# A glyph in the gutter's left lane at the first line of each test or suite with a range in an open
# file: a run triangle until it ran, then its state. A click runs it, a right click opens its menu.
# The glyphs are set again from the model after it changed (at most every 100 ms), and for files
# opened since; between those they follow edits (gutter.s). Coverage tints the line numbers.

.equ TG_EVERY_MS, 100

.bss
.p2align 3
.globl g_ts_glyphs
g_ts_glyphs: .long 0            # items or states changed: the glyphs are set again
tg_kind: .long 0                # the gutter kind, 0 before the first tick
tg_force: .long 0               # set again now, not waiting for the 100 ms (print-gutter)
tg_cfg_seen: .long 0            # [testing] gutter as the glyphs were last set for
.p2align 3
tg_last: .quad 0                # time_ms of the last setting
tg_doc_max: .quad 0             # the newest DOC_id that has its glyphs
tg_cov_doc: .quad 0             # the tint's cache: the document, its coverage file, for which run
tg_cov_cf: .quad 0
tg_cov_run: .quad 0
tg_cov_ver: .quad 0             # the document's version it was made for
tg_cov_docid: .quad 0           # and its DOC_id (an address is used again after a tab closes)
tg_cov_map: .quad 0             # owned: a byte per line of the document now (COV_* bits), when
tg_cov_mapn: .quad 0            #   the coverage came at another version of it; 0 none
tg_tip: .zero 512

.text

# testgutter_doc_ver(path cstr or 0) -> rax the version of the file's open document, -1 when it is
#   not open: ranges, message places and coverage that came then move through the edits since
FN testgutter_doc_ver
    PROLOGUE
    test rdi, rdi
    jz 8f
    call app_find_tab
    test rax, rax
    js 8f
    mov rdi, rax
    call tab_at
    mov rdi, [rax + TAB_doc]
    test rdi, rdi
    jz 8f
    call doc_key
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# doc_key(doc) -> rax its version now with its identity: DOC_id << 40 | the version's low 40 bits
#   (a reopened file is another document, whose versions start again)
doc_key:
    mov rax, [rdi + DOC_version]
    shl rax, 24
    shr rax, 24
    mov rcx, [rdi + DOC_id]
    shl rcx, 40
    or rax, rcx
    ret

# key_ver(doc, key) -> rax the version a key names in this document, -1 for none (no key, or a key
#   of another document of the file: lines as they are)
key_ver:
    mov rax, -1
    test rsi, rsi
    js 9f
    mov rcx, rsi
    shr rcx, 40
    mov rdx, [rdi + DOC_id]
    shl rdx, 40
    shr rdx, 40
    cmp rcx, rdx
    jne 9f
    mov rax, rsi
    shl rax, 24
    shr rax, 24
9:  ret

# tg_map(doc, version, line) -> eax the one-based line in the document's text now of a one-based
#   line of its text at that version (-1: now), 0 when the edit tape no longer reaches back
tg_map:
    PROLOGUE
    mov r12d, edx
    call key_ver
    mov rsi, rax
    mov edx, r12d
    mov eax, edx
    test rsi, rsi
    js 9f
    cmp rsi, [rdi + DOC_version]
    je 9f
    test edx, edx
    jz 9f
    mov rbx, rdi
    lea edx, [rdx - 1]
    xor ecx, ecx
    mov r8d, GR_RIGHT
    call tape_map_lc
    test rax, rax
    js 8f
    mov rdi, rbx
    mov rsi, rax
    call doc_line_of
    inc eax
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# testgutter_map_path / tg_map_path(path cstr, key*, line) -> eax the line moved through the edits of
#   the file's open document since the version the key names; the line as it is when the file is
#   not open or the tape does not reach back. A key of no document or of one closed since (the file
#   was reopened) becomes this document's version now, so later edits move the line
FN testgutter_map_path
tg_map_path:
    PROLOGUE
    mov r12, rsi
    mov r13d, edx
    call app_find_tab
    test rax, rax
    js 8f
    mov rdi, rax
    call tab_at
    mov rbx, [rax + TAB_doc]
    test rbx, rbx
    jz 8f
    mov rdi, rbx
    mov rsi, [r12]
    call key_ver
    test rax, rax
    jns 1f
    mov rdi, rbx
    call doc_key
    mov [r12], rax
    jmp 8f
1:  mov rdi, rbx
    mov rsi, [r12]
    mov edx, r13d
    call tg_map
    test eax, eax
    jz 8f
    EPILOGUE
8:  mov eax, r13d
    EPILOGUE

# testgutter_item_lines / item_lines(doc, TSI*) -> eax first line, edx last line (one-based) in the document now: the
#   item's range moved through the edits since it came (an item that came before the document
#   opened takes the document's version now); eax 0 when the tape does not reach back
FN testgutter_item_lines
item_lines:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx                # no key, or another document's (the file was reopened): its
    mov rsi, [r12 + TSI_ver]    #   lines are this document's as it is now
    call key_ver
    test rax, rax
    jns 1f
    mov rdi, rbx
    call doc_key
    mov [r12 + TSI_ver], rax
1:  mov rdi, rbx
    mov rsi, [r12 + TSI_ver]
    mov edx, [r12 + TSI_l2]
    call tg_map
    mov r13d, eax
    mov rdi, rbx
    mov rsi, [r12 + TSI_ver]
    mov edx, [r12 + TSI_l1]
    call tg_map
    test r13d, r13d
    jnz 2f
    mov r13d, eax
2:  mov edx, r13d
    EPILOGUE

# testgutter_glyphs(): kind and tint at the first call; glyphs set again when due
FN testgutter_glyphs
    PROLOGUE
    cmp dword ptr [rip + tg_kind], 0
    jne 1f
    mov edi, GK_PRIO_TEST
    xor esi, esi
    lea rdx, [rip + tg_click]
    lea rcx, [rip + tg_tipfn]
    xor r8d, r8d
    call gutter_kind
    mov [rip + tg_kind], eax
    lea rdi, [rip + tg_tint]
    call gutter_tint
    cmp dword ptr [rip + tg_kind], 0
    je 9f
1:  # a document opened since the last setting gets its glyphs too
    xor ebx, ebx
    xor r12d, r12d              # the newest id
2:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 3f
    mov rdi, rbx
    inc rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 2b
    mov rax, [rax + TAB_doc]
    test rax, rax
    jz 2b
    mov rcx, [rax + DOC_id]
    cmp rcx, r12
    jbe 2b
    mov r12, rcx
    jmp 2b
3:  cmp r12, [rip + tg_doc_max]
    jbe 4f
    mov dword ptr [rip + g_ts_glyphs], 1
    mov dword ptr [rip + g_ts_marks], 1     # its failures' places take its version now
4:  mov eax, [rip + cfg_test_gutter]     # [testing] gutter changed: set again (or cleared)
    cmp eax, [rip + tg_cfg_seen]
    je 40f
    mov [rip + tg_cfg_seen], eax
    mov dword ptr [rip + g_ts_glyphs], 1
    mov dword ptr [rip + tg_force], 1
40: cmp dword ptr [rip + g_ts_glyphs], 0
    je 9f
    call time_ms
    cmp dword ptr [rip + tg_force], 0
    jne 41f
    mov rcx, rax
    sub rcx, [rip + tg_last]
    cmp rcx, TG_EVERY_MS
    jb 9f
41: mov dword ptr [rip + tg_force], 0
    mov [rip + tg_last], rax
    mov [rip + tg_doc_max], r12
    mov dword ptr [rip + g_ts_glyphs], 0
    xor edi, edi
    mov esi, [rip + tg_kind]
    call gutter_glyph_clear
    cmp dword ptr [rip + cfg_test_gutter], 0
    je 9f
    xor ebx, ebx
5:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 9f
    mov rdi, rbx
    inc rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 5b
    mov rdi, [rax + TAB_doc]
    test rdi, rdi
    jz 5b
    cmp qword ptr [rdi + DOC_path], 0
    je 5b
    call doc_glyphs
    jmp 5b
9:  EPILOGUE

# doc_glyphs(doc): its tests' glyphs
doc_glyphs:
    PROLOGUE 16
    mov rbx, rdi
    mov rdi, [rbx + DOC_path]
    call strlen
    mov rsi, rax
    mov rdi, [rbx + DOC_path]
    call hash_line
    mov [rsp], rax
    lea r12, [rip + g_ts_ctrls]
    xor r13d, r13d
1:  cmp qword ptr [r12 + TSC_ext], 0
    je 4f
    mov r14d, 1
2:  cmp r14, [r12 + TSC_items + VEC_len]
    jae 4f
    mov rdi, r12
    mov rsi, r14
    call testmodel_item
    mov r15, rax
    cmp qword ptr [r15 + TSI_id], 0
    je 3f
    mov rax, [rsp]
    cmp [r15 + TSI_phash], rax
    jne 3f
    cmp dword ptr [r15 + TSI_l1], 0
    je 3f
    mov eax, [r15 + TSI_kind]
    cmp eax, TSK_TEST
    je 21f
    cmp eax, TSK_SUITE
    jne 3f
21: mov rdi, [r15 + TSI_path]
    mov rsi, [rbx + DOC_path]
    call strcmp_eq
    test eax, eax
    jz 3f
    mov rdi, rbx
    mov rsi, r15
    call item_lines
    test eax, eax
    jz 3f
    lea edx, [rax - 1]
    mov eax, [r15 + TSI_state]
    lea rcx, [rip + state_glyphs]
    mov ecx, [rcx + rax*4]
    mov rdi, rbx
    mov esi, [rip + tg_kind]
    call gutter_glyph_set
3:  inc r14
    jmp 2b
4:  add r12, TSC_SIZE
    inc r13d
    cmp r13d, TS_CTRL_MAX
    jb 1b
    EPILOGUE

# at_line(doc, line) -> rax TSC*, rdx index of the test or suite whose glyph is on the line (its
#   range's first line, else the deepest range holding the line), rax 0 for none
at_line:
    PROLOGUE 48
    mov rbx, rdi
    lea rax, [rsi + 1]
    mov [rsp], rax              # one-based
    mov qword ptr [rsp + 8], 0  # the best: TSC*, index, how good (2 first line, 1 holds it)
    mov qword ptr [rsp + 16], 0
    mov qword ptr [rsp + 24], 0
    lea r12, [rip + g_ts_ctrls]
    xor r13d, r13d
1:  cmp qword ptr [r12 + TSC_ext], 0
    je 4f
    mov r14d, 1
2:  cmp r14, [r12 + TSC_items + VEC_len]
    jae 4f
    mov rdi, r12
    mov rsi, r14
    call testmodel_item
    mov r15, rax
    cmp qword ptr [r15 + TSI_id], 0
    je 3f
    cmp dword ptr [r15 + TSI_l1], 0
    je 3f
    mov rdi, [r15 + TSI_path]
    test rdi, rdi
    jz 3f
    mov rsi, [rbx + DOC_path]
    call strcmp_eq
    test eax, eax
    jz 3f
    mov rdi, rbx
    mov rsi, r15
    call item_lines
    test eax, eax
    jz 3f
    mov ecx, eax
    mov [rsp + 32], rdx
    mov rax, [rsp]
    cmp rax, rcx
    jne 31f
    mov edx, 2
    jmp 32f
31: jb 3f
    mov ecx, [rsp + 32]
    cmp rax, rcx
    ja 3f
    mov edx, 1
32: cmp rdx, [rsp + 24]
    jb 3f
    mov [rsp + 8], r12
    mov [rsp + 16], r14
    mov [rsp + 24], rdx
3:  inc r14
    jmp 2b
4:  add r12, TSC_SIZE
    inc r13d
    cmp r13d, TS_CTRL_MAX
    jb 1b
    mov rax, [rsp + 8]
    mov rdx, [rsp + 16]
    EPILOGUE

# tg_click(doc, line, button, glyph): a click opens the play menu (Run, Debug, Run with Coverage of
#   that test, by its name), a right click the test's whole menu
tg_click:
    PROLOGUE
    mov r12d, edx
    call at_line
    test rax, rax
    jz 9f
    cmp r12d, BTN_RIGHT
    je 1f
    mov rdi, rax
    mov rsi, rdx
    call tg_play_menu
    EPILOGUE
1:  mov rdi, rax
    mov rsi, rdx
    mov edx, [rip + g_mx]
    mov ecx, [rip + g_my]
    call testview_menu_at
9:  EPILOGUE

# tg_play_menu(tsc, index): the test selected; Run 'NAME', Debug 'NAME', Run 'NAME' with Coverage at
#   the pointer
tg_play_menu:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call testview_select
    mov rdi, r12
    mov rsi, r13
    call testmodel_item
    mov rbx, [rax + TSI_label]
    lea rdi, [rip + tg_mtext]
    call sb_clear
    xor r14d, r14d
1:  cmp r14d, 3
    jae 2f
    mov rax, [rip + tg_mtext + SB_len]
    lea rcx, [rip + tg_moffs]
    mov [rcx + r14*8], rax
    lea rax, [rip + tg_mpre]
    mov rsi, [rax + r14*8]
    lea rdi, [rip + tg_mtext]
    call sb_push_cstr
    lea rdi, [rip + tg_mtext]
    mov esi, 0x27
    call sb_push_byte
    lea rdi, [rip + tg_mtext]
    mov rsi, rbx
    test rsi, rsi
    jz 11f
    call sb_push_cstr
11: lea rdi, [rip + tg_mtext]
    mov esi, 0x27
    call sb_push_byte
    lea rax, [rip + tg_msuf]
    mov rsi, [rax + r14*8]
    lea rdi, [rip + tg_mtext]
    call sb_push_cstr
    lea rdi, [rip + tg_mtext]
    xor esi, esi
    call sb_push_byte
    inc r14d
    jmp 1b
2:  lea rdx, [rip + tg_mitems]  # the labels, now that the text no longer grows
    xor r14d, r14d
3:  cmp r14d, 3
    jae 4f
    lea rcx, [rip + tg_moffs]
    mov rax, [rcx + r14*8]
    add rax, [rip + tg_mtext + SB_ptr]
    mov rcx, r14
    shl rcx, 4
    mov [rdx + rcx], rax
    lea rax, [rip + tg_mfns]
    mov rax, [rax + r14*8]
    mov [rdx + rcx + 8], rax
    inc r14d
    jmp 3b
4:  mov qword ptr [rdx + 48], 0
    mov qword ptr [rdx + 56], 0
    lea rdi, [rip + tg_mitems]
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call ctx_menu_open
9:  EPILOGUE

# tg_tipfn(doc, line, glyph) -> rax "Run NAME", or "NAME: STATE" and its first message line
tg_tipfn:
    PROLOGUE
    call at_line
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call testmodel_item
    mov rbx, rax
    lea rdi, [rip + tg_tip]
    cmp dword ptr [rbx + TSI_state], TSS_NOTRUN
    jne 1f
    lea rsi, [rip + .Lrun]
    call cstr_copy
    mov rdi, rax
    mov rsi, [rbx + TSI_label]
    call tip_copy
    jmp 7f
1:  mov rsi, [rbx + TSI_label]
    call tip_copy
    mov rdi, rax
    lea rsi, [rip + .Lcolon]
    call cstr_copy
    mov rdi, rax
    push rax
    push rax
    mov edi, [rbx + TSI_state]
    call testmodel_state_word
    mov rsi, rax
    pop rdi
    pop rdi
    call cstr_copy
    mov rsi, [rbx + TSI_msg]
    test rsi, rsi
    jz 7f
    mov rdi, rax
    lea rsi, [rip + .Lnl]
    call cstr_copy
    mov rdi, rax
    mov rsi, [rbx + TSI_msg]
    call tip_copy
7:  lea rax, [rip + tg_tip]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# tip_copy(dst, cstr) -> dst's NUL: the text, cut where the tip buffer ends
tip_copy:
    lea rcx, [rip + tg_tip + 500]
1:  cmp rdi, rcx
    jae 2f
    movzx eax, byte ptr [rsi]
    test eax, eax
    jz 2f
    mov [rdi], al
    inc rdi
    inc rsi
    jmp 1b
2:  mov byte ptr [rdi], 0
    mov rax, rdi
    ret

# tg_tint(doc, line) -> eax argb: covered lines in the success color, missed ones in the error
#   color, partly covered ones in the warning color, at 22 % (0 elsewhere, or with coverage hidden)
tg_tint:
    PROLOGUE
    xor eax, eax
    cmp dword ptr [rip + g_cov_on], 0
    je 9f
    call cov_state
    test eax, eax
    jz 9f
    lea rcx, [rip + cov_slots]
    mov ecx, [rcx + rax*4]
    lea rdx, [rip + g_theme]
    mov eax, [rdx + rcx*4]
    and eax, 0x00ffffff
    or eax, 0x38000000          # 22 %
9:  EPILOGUE

# cov_state(doc, line) -> eax the zero-based line's coverage in the document now: 0 none, COV_*
#   bits (3 partly covered)
cov_state:
    PROLOGUE
    xor eax, eax
    cmp qword ptr [rip + g_cov_run], 0
    je 9f
    mov rbx, rdi
    mov r12, rsi
    cmp rbx, [rip + tg_cov_doc]
    jne 1f
    mov rax, [rip + g_cov_run]
    cmp rax, [rip + tg_cov_run]
    jne 1f
    mov rax, [rbx + DOC_version]
    cmp rax, [rip + tg_cov_ver]
    jne 1f
    mov rax, [rbx + DOC_id]
    cmp rax, [rip + tg_cov_docid]
    je 2f
1:  call cov_cache
2:  xor eax, eax
    mov rdi, [rip + tg_cov_cf]
    test rdi, rdi
    jz 9f
    mov rcx, [rip + tg_cov_map]
    test rcx, rcx
    jz 21f
    cmp r12, [rip + tg_cov_mapn]
    jae 9f
    movzx eax, byte ptr [rcx + r12]
    jmp 9f
21: lea rsi, [r12 + 1]
    call testcover_line
9:  EPILOGUE

# cov_cache(): the tint's cache for document rbx (tg_tint's): its coverage file, and when that
#   came at another version of the document, its lines moved through the edits since (a line the
#   tape no longer reaches is not tinted)
cov_cache:
    PROLOGUE
    mov [rip + tg_cov_doc], rbx
    mov rax, [rip + g_cov_run]
    mov [rip + tg_cov_run], rax
    mov rax, [rbx + DOC_version]
    mov [rip + tg_cov_ver], rax
    mov rax, [rbx + DOC_id]
    mov [rip + tg_cov_docid], rax
    mov qword ptr [rip + tg_cov_cf], 0
    mov rdi, [rip + tg_cov_map]
    call mem_free
    mov qword ptr [rip + tg_cov_map], 0
    mov rdi, [rbx + DOC_path]
    test rdi, rdi
    jz 9f
    call testcover_file
    mov [rip + tg_cov_cf], rax
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    call testcover_ver
    mov rdi, rbx
    mov rsi, rax
    call key_ver
    mov r13, rax
    test rax, rax
    jns 21f
    mov rdi, rbx                # first seen in this document (or the file was reopened): its
    call doc_key                #   lines are the document's now, and later edits move them
    mov rsi, rax
    mov rdi, r12
    call testcover_set_ver
    jmp 9f
21:
    cmp rax, [rbx + DOC_version]
    je 9f
    mov rdi, [rbx + DOC_nlines]
    mov [rip + tg_cov_mapn], rdi
    inc rdi
    call mem_alloc
    mov [rip + tg_cov_map], rax
    mov rdi, rax
    xor esi, esi
    mov rdx, [rip + tg_cov_mapn]
    inc rdx
    call memset
    mov rdi, r12
    call testcover_count
    mov r14, rax                # lines of the coverage
    xor r15d, r15d              # the line, zero-based
1:  cmp r15, r14
    jae 9f
    mov rdi, r12
    lea rsi, [r15 + 1]
    call testcover_line
    test eax, eax
    jz 3f
    push rax
    push rax
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r15
    xor ecx, ecx
    mov r8d, GR_RIGHT
    call tape_map_lc
    mov rsi, rax
    pop rcx
    pop rcx
    test rsi, rsi
    js 3f
    push rcx
    push rcx
    mov rdi, rbx
    call doc_line_of
    pop rcx
    pop rcx
    cmp rax, [rip + tg_cov_mapn]
    jae 3f
    mov rdx, [rip + tg_cov_map]
    or [rdx + rax], cl
3:  inc r15
    jmp 1b
9:  EPILOGUE

# testgutter_cov_changed(): the tint cache forgets (coverage replaced or cleared)
FN testgutter_cov_changed
    mov qword ptr [rip + tg_cov_doc], 0
    mov dword ptr [rip + g_tcv_dirty], 1      # the Coverage section lists the files again
    ret

.section .rodata
.Lrun: .asciz "Run "
.Lnl: .asciz "\n"
.p2align 2
# per state: the glyph (GS_* | theme slot << 8 | GF_* << 16)
state_glyphs:
    .long GS_TRIANGLE | (T_SUCCESS << 8)        # not run: run it (green, as JetBrains IDEs and the Sublime Debugger)
    .long GS_MINUS | (T_MUTED << 8)             # skipped
    .long GS_CHECK | (T_SUCCESS << 8)           # passed
    .long GS_CROSS | (T_ERROR << 8)             # failed
    .long GS_CIRCLE_TRI | (T_ERROR << 8)        # errored
    .long GS_RING | (T_MUTED << 8)              # queued
    .long GS_RING | (T_ACCENT << 8)             # running
cov_slots: .long 0, T_SUCCESS, T_ERROR, T_WARNING

.text
# testctl_gutter(sb, rest, len): print-gutter: the active document's test glyphs, "line=N glyph=NAME
#   item=ID" per glyph (N one-based), then "cov=L:C,L:M,L:P..." for its tinted lines
FN testctl_gutter
    PROLOGUE 16
    mov rbx, rdi
    mov dword ptr [rip + tg_force], 1
    call testgutter_glyphs
    mov r12, [rip + g_doc]
    test r12, r12
    jz 9f
    cmp dword ptr [rip + tg_kind], 0
    je 6f
    xor r13d, r13d              # the line to look from
1:  mov rdi, r12
    mov esi, [rip + tg_kind]
    mov rdx, r13
    call gutter_glyph_next
    test rax, rax
    js 6f
    mov r13, rax
    mov rdi, r12
    mov esi, [rip + tg_kind]
    mov rdx, r13
    call gutter_glyph_get
    mov r14d, eax
    mov rdi, rbx
    lea rsi, [rip + .Lp_line]
    call sb_push_cstr
    lea rsi, [r13 + 1]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lp_glyph]
    call sb_push_cstr
    # its name: the state whose glyph it is
    xor ecx, ecx
2:  cmp ecx, TSS_COUNT
    jae 3f
    lea rax, [rip + state_glyphs]
    cmp [rax + rcx*4], r14d
    je 3f
    inc ecx
    jmp 2b
3:  lea rsi, [rip + .Lg_play]
    test ecx, ecx
    jz 31f
    cmp ecx, TSS_COUNT
    jae 31f
    mov edi, ecx
    call testmodel_state_word
    mov rsi, rax
31: mov rdi, rbx
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    call at_line
    test rax, rax
    jz 4f
    mov r15, rax
    mov rdi, rax
    mov rsi, rdx
    call testmodel_item
    mov r14, rax
    mov rdi, rbx
    lea rsi, [rip + .Lp_item]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + TSI_id]
    mov edx, [r14 + TSI_idlen]
    call testmodel_escape
4:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r13
    jmp 1b
6:  # coverage
    mov rdi, rbx
    lea rsi, [rip + .Lp_cov]
    call sb_push_cstr
    xor r13d, r13d
    xor r15d, r15d              # 1 after the first
7:  cmp r13, [r12 + DOC_nlines]
    jae 8f
    mov rdi, r12
    mov rsi, r13
    call tg_tint
    test eax, eax
    jz 71f
    mov rdi, r12
    mov rsi, r13
    call cov_state
    mov r14d, eax
    test r15d, r15d
    jz 72f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
72: mov r15d, 1
    lea rsi, [r13 + 1]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    lea rax, [rip + .Lcov_letters]
    movzx esi, byte ptr [rax + r14]
    mov rdi, rbx
    call sb_push_byte
71: inc r13
    jmp 7b
8:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  xor eax, eax
    EPILOGUE

.section .rodata
.Lp_line: .asciz "line="
.Lp_glyph: .asciz " glyph="
.Lp_item: .asciz " item="
.Lp_cov: .asciz "cov="
.Lg_play: .asciz "play"
.Lcov_letters: .ascii "-CMP"

.text
# testctl_gutter_click(sb, rest, len): test-gutter LINE [right]: a click (or right click) on the active
#   document's test glyph at that one-based line, as the gutter would pass it
FN testctl_gutter_click
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test rax, rax
    jz 9f
    lea r14, [rax - 1]
    mov r15d, BTN_LEFT
    mov rdi, r12
    mov rsi, r13
    call trim
    test rdx, rdx
    jz 1f
    mov r15d, BTN_RIGHT
1:  mov rdi, [rip + g_doc]
    test rdi, rdi
    jz 9f
    mov rsi, r14
    mov edx, r15d
    xor ecx, ecx
    call tg_click
9:  xor eax, eax
    EPILOGUE

# the play menu (tg_play_menu)
.bss
.p2align 3
tg_mtext: .zero SB_SIZE
tg_moffs: .zero 8 * 3
tg_mitems: .zero 16 * 4
.data
.p2align 3
tg_mpre: .quad .Ltg_run, .Ltg_debug, .Ltg_run
tg_msuf: .quad .Ltg_none, .Ltg_none, .Ltg_cov
tg_mfns: .quad tv_m_run, tv_m_debug, tv_m_coverage
.section .rodata
.Ltg_run: .asciz "Run "
.Ltg_debug: .asciz "Debug "
.Ltg_cov: .asciz " with Coverage"
.Ltg_none: .asciz ""
