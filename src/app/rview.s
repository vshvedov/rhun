# retained extension views (docs/extensions/v1.1.md "Retained views"): views an extension declares
# in its manifest ([views]) take places (places.s) when it loads; while it runs each has an instance
# whose content rhun keeps (a tree store, rtree.s) and the extension changes with patches (vpatch),
# applied whole or not at all. User state (expansion, selection, scroll) is rhun's and follows node
# ids. Events go back as "0 view VIEW ...".
.include "rhun.inc"

.equ RV_MAX, 96                  # instances, all extensions
.equ VD_PER_EXT, 16              # declared views per extension
.equ RK_TREE, 1
.equ RK_TABLE, 2
.equ RK_LOG, 3
.equ RK_FORM, 4
.equ RK_DOC, 5
.equ RK_PICTURE, 6
.equ RS_NONE, 0                  # no state yet: Loading after 300 ms until state or root kids
.equ RS_READY, 1
.equ RS_LOADING, 2
.equ RS_EMPTY, 3
.equ RS_ERROR, 4
.equ ID_RV_BTN, 0x5e0000         # + vd << 4 + i: the buttons of a view's state
.equ ID_RV_ACT, 0x5f0000         # + vd << 6 + i: its title actions
.equ ID_RV_STATE, 0x5b0000       # + slot << 4 + i: the buttons of an instance's empty or error state
.equ ID_RV_LOGBTN, 0x5a0000      # + slot << 2 + i: a log's Find, Clear, Follow
.equ ID_RV_MTITLE, 0x5a8000      # + vd << 3 + i: the extensions' manifest view_title buttons (menu.s)
.equ ID_RV_MROW, 0x5ac000        # + slot << 4 + 0|8 + i: their view_item_inline buttons on a row
.equ VML_TITLE, 7                # menu.s's MLOC_VIEW_TITLE, MLOC_VIEW_ITEM_INLINE
.equ VML_ITEM_INLINE, 9
.equ LABEL_MAX, 1000
.equ TITLE_MAX, 80
.equ TIP_MAX, 4000
.equ NODES_ALL_MAX, 400000
.equ BYTES_MAX, 16777216         # node bytes per instance
.equ BYTES_ALL_MAX, 67108864     # node bytes in all instances
.equ OVF, 0x80000000             # a patch check's reference to a node it creates (else a live node)

# a declared view
STRUCT
F VD_ext, 8             # EXT*, 0 when its extension is gone
F VD_key, 8             # cstr, owned
F VD_title, 8           # cstr, owned, or 0
F VD_name, 8            # "OWNER/NAME.KEY", owned (its place item's name)
F VD_icon, 8            # cstr, owned, or 0
F VD_when, 8            # cstr, owned, or 0
F VD_place, 4           # PLACE_*, 0 not given or unknown
F VD_kind, 4            # RK_*, 0 not given or unknown
F VD_open, 4            # open = yes
F VD_pl, 4              # its place item, -1 before rview_init gives it one
F VD_rv, 4              # its instance while the extension runs, -1
F VD_started, 4         # showing it started its extension (once per showing)
F VD_mtx, 4             # the manifest view_title buttons last drawn in its header: x, width (tests)
F VD_mtw, 4
ENDSTRUCT VD_SIZE

# an instance
STRUCT
F RV_ext, 8             # EXT*, 0 when the slot is free
F RV_tree, 8            # TR*
F RV_title, 8           # owned cstr, or 0 (the declared title shows)
F RV_message, 8         # owned cstr, or 0
F RV_stext, 8           # owned cstr: the empty or error state's text, or 0
F RV_skeys, 8           # owned cstr: its buttons' action keys, or 0
F RV_opened, 8          # time_ms
F RV_rev, 8
F RV_view, 4            # the number the extension knows it by
F RV_kind, 4
F RV_place, 4
F RV_decl, 4            # VD index, -1 for a tab instance
F RV_state, 4
F RV_busy, 4
F RV_vis, 4             # visible last said (0 or 1), -1 before
F RV_badge, 4
F RV_actions, VEC_SIZE  # RA: its actions (key, icon, where, title), also the tree's inline table
F RV_log, 8             # LG* of a log view
F RV_pl, 4              # its place item (a declared view's, or its own for a tab), -1
F RV_tabclosing, 4      # its tab is being closed by the extension: no "closed" event
F RV_prog, 4            # progress shows in it (notify.s: progress view:VIEW)
F RV_ppct, 4            # its percent, -1 indeterminate
F RV_vw, 8              # a picture view's 12a picture (extview.s), or 0
F RV_form, 8            # a form view's form (rform.s), or 0
F RV_doc, 8             # a doc view's state (rdoc.s), or 0
ENDSTRUCT RV_SIZE

# an action of a retained view: TA's layout (the tree looks inline keys up in them), TA_pad its WHERE
.equ RA_SIZE, TA_SIZE
.equ RA_where, TA_pad
.equ RAW_TITLE, 1
.equ RAW_NODE, 2
.equ RA_MAX, 32

# a request rhun waits on for an instance: vkids or vmore
STRUCT
F PQ_slot, 4            # the instance, -1 when the entry is free
F PQ_node, 4
F PQ_kind, 4            # 1 vkids, 2 vmore
F PQ_gen, 4             # the node's ND_gen: a node made again with the same id is another one
F PQ_req, 8             # its id
F PQ_sent, 8            # time_ms
F PQ_id, 8              # the node's id when asked (owned), to see it is still the same node
F PQ_idlen, 8
ENDSTRUCT PQ_SIZE
.equ PQ_MAX, 256
.equ PQ_PER_VIEW, 4
.equ PQ_WAIT_MS, 15000

# a node a patch check creates
STRUCT
F OV_id, 8
F OV_idlen, 4
F OV_parent, 4          # node, or OVF | entry
F OV_removed, 4
F OV_mark, 4
F OV_first, 4           # first entry created under it, -1
F OV_next, 4            # the next one under its parent
F OV_bytes, 4           # its record's bytes (the last given)
F OV_pad, 4
ENDSTRUCT OV_SIZE

.bss
.p2align 3
vdecls: .zero VEC_SIZE          # VD
rv_slots: .zero RV_SIZE * RV_MAX
evbuf: .zero SB_SIZE            # an event being written
errbuf: .zero 256               # the error text of the last patch that failed
rr: .zero RR_SIZE
rr2: .zero RR_SIZE
col_align: .long 0              # column_rec's column
col_min: .long 0
col_sort: .long 0
col_pad: .long 0
ov: .zero VEC_SIZE              # OV: nodes the patch being checked creates
ovh: .quad 0                    # id -> entry + 1 (u32 slots)
ovh_cap: .quad 0
ovh_n: .quad 0
ovp: .quad 0                    # live node + 1 -> first entry + 1 (u32 pairs)
ovp_cap: .quad 0
ovp_n: .quad 0
p_tree: .quad 0                 # the store the patch is checked against
p_rmark: .long 0                # live nodes the patch removes hold this mark
p_kmark: .long 0                # children listed by the kids op being checked
p_created: .quad 0              # nodes the patch creates
p_removed: .quad 0              # live nodes it removes
p_bytes: .quad 0                # record bytes it brings to live nodes (created ones: OV_bytes)
p_freed: .quad 0                # bytes of live nodes it replaces or removes
p_touched: .zero VEC_SIZE       # live nodes holding NF_PCOUNT (u32 each)
g_rv_bytes: .quad 0             # node bytes in all instances
p_op: .quad 0                   # the op being checked, from 1
p_rv: .quad 0                   # its instance
p_kind: .long 0                 # and its kind
.p2align 3
p_actions: .quad 0              # the actions it would have (their keys in p_akeys)
p_akeys: .zero 16 * RA_MAX      # ptr, len of each
g_rv_nodes: .quad 0             # nodes in all instances
idsbuf: .zero SB_SIZE           # a select event's ids
ctxbuf: .zero 104               # a node's ctx value as a cstr (menus)
pq_table: .zero PQ_SIZE * PQ_MAX
menu_items: .zero 16 * 17       # rv_menu's items (label, handler), 0-ended
menu_keys: .zero 8 * 16
menu_arena: .zero SB_SIZE       # rv_menu's labels and keys, kept while the menu is open
menu_keyp: .zero 8 * 16
menu_keyl: .zero 8 * 16
menu_node_id: .quad 0           # the node it was opened on (owned id) and where
menu_node_len: .quad 0
menu_rev: .quad 0
menu_ext: .quad 0
menu_slot: .long 0
keybuf: .zero 64
nrec: .zero 64                  # a node record: id, idlen, label, lablen, extra, xlen, kids, next

.text

# ---------------- the manifest ----------------

# vd_at(i) -> rax VD*
vd_at:
    imul rax, rdi, VD_SIZE
    add rax, [rip + vdecls + VEC_ptr]
    ret

# contributions group: FN rview_page_rows(ext): the extension page's Views rows (contribpage.s):
#   each view it declares, its title; its key, kind, place, clause, open at start
FN rview_page_rows
    PROLOGUE
    mov r15, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + vdecls + VEC_len]
    jae 9f
    mov rdi, rbx
    call vd_at
    mov r12, rax
    inc rbx
    cmp [r12 + VD_ext], r15
    jne 1b
    mov rdi, [r12 + VD_title]
    test rdi, rdi
    jnz 2f
    mov rdi, [r12 + VD_key]
2:  call contrib_page_text
    mov rdi, [r12 + VD_key]
    call contrib_page_detail
    mov eax, [r12 + VD_kind]
    dec eax
    cmp eax, RK_PICTURE
    jae 3f
    lea rcx, [rip + kind_words]
    mov r13, [rcx + rax*8]
    call contrib_page_part
    mov rdi, r13
    call contrib_page_detail
3:  mov eax, [r12 + VD_place]
    dec eax
    cmp eax, 4
    jae 4f
    lea rcx, [rip + place_words]
    mov r13, [rcx + rax*8]
    call contrib_page_part
    lea rdi, [rip + .Lpg_in]
    call contrib_page_detail
    mov rdi, r13
    call contrib_page_detail
4:  mov rdi, [r12 + VD_when]
    test rdi, rdi
    jz 5f
    mov r13, rdi
    call contrib_page_part
    lea rdi, [rip + .Lpg_when]
    call contrib_page_detail
    mov rdi, r13
    call contrib_page_detail
5:  cmp dword ptr [r12 + VD_open], 0
    je 6f
    call contrib_page_part
    lea rdi, [rip + .Lpg_open]
    call contrib_page_detail
6:  call contrib_page_end
    jmp 1b
9:  EPILOGUE

# rview_manifest_kv(ext, ini): one "KEY.FIELD = VALUE" of a manifest's [views]: title, place
#   (sidebar, panel, side), kind (tree, table, log, form, doc, picture), icon, when, open (yes)
FN rview_manifest_kv
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, [r12 + INI_key]
    mov r14, [r12 + INI_keylen]
    xor ecx, ecx                # the dot
1:  cmp rcx, r14
    jae 9f
    cmp byte ptr [r13 + rcx], '.'
    je 2f
    movzx eax, byte ptr [r13 + rcx]
    cmp eax, '_'
    je 11f
    lea edx, [rax - 'a']
    cmp edx, 25
    jbe 11f
    lea edx, [rax - '0']
    cmp edx, 9
    ja 9f
11: inc rcx
    jmp 1b
2:  test rcx, rcx
    jz 9f
    cmp rcx, 40
    ja 9f
    mov r15, rcx                # the key's length
    # its record, or a new one (16 at most per extension)
    xor ebx, ebx
    mov [rsp], rdi
    xor eax, eax
    mov [rsp + 8], rax          # this extension's views
3:  cmp rbx, [rip + vdecls + VEC_len]
    jae 5f
    mov rdi, rbx
    call vd_at
    mov rcx, [rsp]
    cmp [rax + VD_ext], rcx
    jne 4f
    inc qword ptr [rsp + 8]
    mov rdi, r13
    mov rsi, r15
    mov rdx, [rax + VD_key]
    push rax
    push rax
    call str_eq_cstr
    pop rcx
    pop rcx
    test eax, eax
    jz 4f
    mov rbx, rcx
    jmp 6f
4:  inc rbx
    jmp 3b
5:  cmp qword ptr [rsp + 8], VD_PER_EXT
    jae 9f
    lea rdi, [rip + vdecls]
    mov esi, VD_SIZE
    call vec_push
    mov rbx, rax
    mov rax, [rsp]
    mov [rbx + VD_ext], rax
    mov dword ptr [rbx + VD_pl], -1
    mov dword ptr [rbx + VD_rv], -1
    mov rdi, r13
    mov rsi, r15
    call mem_dup
    mov [rbx + VD_key], rax
6:  # the field
    lea r13, [r13 + r15 + 1]
    sub r14, r15
    dec r14
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lf_title]
    call str_eq_cstr
    test eax, eax
    jz 61f
    lea rdi, [rbx + VD_title]
    call val_take
    jmp 9f
61: mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lf_icon]
    call str_eq_cstr
    test eax, eax
    jz 62f
    lea rdi, [rbx + VD_icon]
    call val_take
    jmp 9f
62: mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lf_when]
    call str_eq_cstr
    test eax, eax
    jz 63f
    lea rdi, [rbx + VD_when]
    call val_take
    jmp 9f
63: mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lf_open]
    call str_eq_cstr
    test eax, eax
    jz 64f
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    lea rdx, [rip + .Lw_yes]
    call str_eq_cstr
    mov [rbx + VD_open], eax
    jmp 9f
64: mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lf_place]
    call str_eq_cstr
    test eax, eax
    jz 65f
    lea rdi, [rip + place_words]
    call val_word
    mov [rbx + VD_place], eax
    jmp 9f
65: mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lf_kind]
    call str_eq_cstr
    test eax, eax
    jz 9f
    lea rdi, [rip + kind_words]
    call val_word
    mov [rbx + VD_kind], eax
9:  EPILOGUE

# val_take(slot*): the value (r12 the ini) as an owned cstr into the slot, replacing what it held
val_take:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call mem_free
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    call mem_dup
    mov [rbx], rax
    pop rbx
    ret

# val_word(table) -> eax the value's index + 1 in a 0-ended table of cstrs, 0 when not there
val_word:
    push rbx
    push r13
    push r14
    mov rbx, rdi
    xor r13d, r13d
1:  mov rdx, [rbx + r13*8]
    test rdx, rdx
    jz 8f
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r13d
    jmp 1b
2:  lea eax, [r13 + 1]
    jmp 9f
8:  xor eax, eax
9:  pop r14
    pop r13
    pop rbx
    ret

# rview_init(): every declared view without a place yet takes one (rhun's start, an install). One
#   without a title or with an unknown place or kind is left out.
FN rview_init
    PROLOGUE 16
    xor ebx, ebx
1:  cmp rbx, [rip + vdecls + VEC_len]
    jae 9f
    mov rdi, rbx
    call vd_at
    mov r12, rax
    cmp qword ptr [r12 + VD_ext], 0
    je 8f
    cmp dword ptr [r12 + VD_pl], -1
    jne 8f
    cmp qword ptr [r12 + VD_title], 0
    je 8f
    cmp dword ptr [r12 + VD_place], 0
    je 8f
    cmp dword ptr [r12 + VD_kind], 0
    je 8f
    # its name: OWNER/NAME.KEY
    mov rdi, [r12 + VD_ext]
    call ext_full_name
    mov [rsp], rax
    lea rdi, [rip + evbuf]
    call sb_clear
    lea rdi, [rip + evbuf]
    mov rsi, [rsp]
    call sb_push_cstr
    lea rdi, [rip + evbuf]
    mov esi, '.'
    call sb_push_byte
    lea rdi, [rip + evbuf]
    mov rsi, [r12 + VD_key]
    call sb_push_cstr
    mov rdi, [rip + evbuf + SB_ptr]
    mov rsi, [rip + evbuf + SB_len]
    call mem_dup
    mov [r12 + VD_name], rax
    mov edi, [r12 + VD_place]
    mov rsi, rax
    mov rdx, [r12 + VD_title]
    lea rcx, [rip + rv_place_ops]
    mov r8, rbx
    call place_add
    mov r13d, eax
    mov rdi, rbx
    call vd_at
    mov r12, rax
    mov [r12 + VD_pl], r13d
    mov eax, r13d
    cmp eax, -1
    je 8f
    mov r13d, eax
    # sidebar sections stay collapsed until opened, unless open = yes
    cmp dword ptr [r12 + VD_place], PLACE_SIDEBAR
    jne 2f
    cmp dword ptr [r12 + VD_open], 0
    jne 8f
    mov edi, r13d
    mov esi, 1
    call place_set_collapsed
    jmp 8f
2:  cmp dword ptr [r12 + VD_open], 0
    je 8f
    mov edi, r13d               # open = yes: the chosen tab the first time it shows
    cmp dword ptr [r12 + VD_place], PLACE_PANEL
    jne 3f
    cmp dword ptr [rip + g_panel_cur], -1
    jne 8f
    mov [rip + g_panel_cur], edi
    jmp 8f
3:  cmp dword ptr [rip + g_side_cur], -1
    jne 8f
    mov [rip + g_side_cur], edi
8:  inc rbx
    jmp 1b
9:  EPILOGUE

# rview_ext_gone(ext): an extension removed or replaced: its views leave their places
FN rview_ext_gone
    PROLOGUE
    mov r12, rdi
    call rview_owner_gone
    xor ebx, ebx
1:  cmp rbx, [rip + vdecls + VEC_len]
    jae 9f
    mov rdi, rbx
    call vd_at
    cmp [rax + VD_ext], r12
    jne 2f
    mov qword ptr [rax + VD_ext], 0
    mov edi, [rax + VD_pl]
    mov dword ptr [rax + VD_pl], -1
    call place_remove
2:  inc rbx
    jmp 1b
9:  EPILOGUE

# ---------------- instances ----------------

# rv_at(slot) -> rax RV*
rv_at:
    imul rax, rdi, RV_SIZE
    lea rcx, [rip + rv_slots]
    add rax, rcx
    ret

# rv_open(ext, kind, place, vd) -> eax a new instance's slot, or -1 when all are taken
rv_open:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    xor r15d, r15d
1:  cmp r15d, RV_MAX
    jae 8f
    mov edi, r15d
    call rv_at
    cmp qword ptr [rax + RV_ext], 0
    je 2f
    inc r15d
    jmp 1b
2:  mov rdi, rax
    push rax
    push rax
    xor esi, esi
    mov edx, RV_SIZE
    call memset
    call extview_next_id
    pop rcx
    pop rcx
    mov [rcx + RV_view], eax
    mov [rcx + RV_ext], rbx
    mov [rcx + RV_kind], r12d
    mov [rcx + RV_place], r13d
    mov [rcx + RV_decl], r14d
    mov dword ptr [rcx + RV_vis], -1
    push rcx
    push rcx
    call time_ms
    pop rcx
    pop rcx
    mov [rcx + RV_opened], rax
    mov dword ptr [rcx + RV_pl], -1
    cmp r14d, -1
    je 3f
    push rcx
    push rcx
    mov edi, r14d
    call vd_at
    mov eax, [rax + VD_pl]
    pop rcx
    pop rcx
    mov [rcx + RV_pl], eax
3:  push rcx
    push rcx
    lea rdi, [rip + rv_tree_ops]
    mov esi, r15d
    call tree_new
    pop rcx
    pop rcx
    mov [rcx + RV_tree], rax
    FEAT_TEST rbx, FEAT_MARKDOWN    # its nodes' tooltips are Markdown
    jz 31f
    or dword ptr [rax + TR_flags], TRF_MDTIPS
31: push rcx
    push rcx
    mov rdi, rax                # the extensions' manifest inline items on rows (menu.s)
    lea rsi, [rip + rv_rowbuttons]
    call tree_set_rowbuttons
    pop rcx
    pop rcx
    cmp r12d, RK_LOG
    jne 4f
    push rcx
    push rcx
    mov edi, r15d
    call log_new
    pop rcx
    pop rcx
    mov [rcx + RV_log], rax
4:  cmp r12d, RK_FORM           # a form view: its fields
    jne 41f
    push rcx
    push rcx
    mov edi, r15d
    call form_new
    pop rcx
    pop rcx
    mov [rcx + RV_form], rax
41: cmp r12d, RK_DOC            # a doc view: its Markdown (rdoc.s)
    jne 42f
    push rcx
    push rcx
    mov edi, r15d
    mov rsi, rbx
    call mdview_new
    pop rcx
    pop rcx
    mov [rcx + RV_doc], rax
42: cmp r12d, RK_PICTURE        # a picture view: a 12a picture of its own, shown at once
    jne 5f
    push rcx
    push rcx
    mov rdi, rbx
    mov esi, [rcx + RV_view]
    call extview_open_place
    pop rcx
    pop rcx
    mov [rcx + RV_vw], rax
    mov dword ptr [rcx + RV_state], RS_READY
5:  mov eax, r15d
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# rv_close(slot): the instance ends (no event); its declared view shows its stopped state
rv_close:
    PROLOGUE
    mov ebx, edi
    call rv_at
    mov r12, rax
    cmp qword ptr [r12 + RV_ext], 0
    je 9f
    mov rdi, [r12 + RV_log]
    call log_free
    cmp dword ptr [r12 + RV_place], PLACE_TAB
    jne 11f
    mov edi, [r12 + RV_pl]      # a tab's own place item
    call place_remove
11: mov rdi, [r12 + RV_tree]
    test rdi, rdi
    jz 1f
    mov rax, [rdi + TR_count]
    sub [rip + g_rv_nodes], rax
    mov rax, [rdi + TR_bytes]
    sub [rip + g_rv_bytes], rax
    call tree_free
1:  mov rdi, [r12 + RV_title]
    call mem_free
    mov rdi, [r12 + RV_message]
    call mem_free
    mov rdi, [r12 + RV_stext]
    call mem_free
    mov rdi, [r12 + RV_skeys]
    call mem_free
    mov rdi, r12
    call actions_free
    mov edi, ebx
    call pq_drop_slot
    mov edi, ebx
    call notify_view_closed     # its progress shows nowhere now
    mov rdi, [r12 + RV_vw]      # a picture view's picture
    call extview_free_place
    mov rdi, [r12 + RV_form]    # a form view's form
    call form_free
    mov rdi, [r12 + RV_doc]     # a doc view's document
    call mdview_free
    movsxd rdi, dword ptr [r12 + RV_decl]
    cmp rdi, -1
    je 2f
    call vd_at
    mov dword ptr [rax + VD_rv], -1
    mov dword ptr [rax + VD_started], 0
2:  mov rdi, r12
    xor esi, esi
    mov edx, RV_SIZE
    call memset
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# rview_owner_gone(ext): its instances end with it (no events)
FN rview_owner_gone
    PROLOGUE
    mov r12, rdi
    call notify_owner_gone      # its notifications and progress go too
    mov rdi, r12
    call viewimg_owner_gone     # and its images (viewpic.s)
    mov rdi, r12
    call quick_owner_gone       # and its quick input (quick.s)
    xor ebx, ebx
1:  cmp ebx, RV_MAX
    jae 9f
    mov edi, ebx
    call rv_at
    cmp [rax + RV_ext], r12
    jne 2f
    mov edi, ebx
    cmp dword ptr [rax + RV_place], PLACE_TAB
    jne 3f
    call rv_close_tab           # its tab closes too
    jmp 2f
3:  call rv_close
2:  inc ebx
    jmp 1b
9:  EPILOGUE

# rview_slot_of(ext, view) -> eax the instance's slot, or -1 (notify.s)
FN rview_slot_of
    jmp rv_find

# rview_progress(slot, on, percent or -1): progress in the instance (a bar at its top, its section's
#   spinner); a slot that is gone or -1 is ignored
FN rview_progress
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    cmp ebx, RV_MAX
    jae 9f
    mov edi, ebx
    call rv_at
    mov r14, rax
    cmp qword ptr [r14 + RV_ext], 0
    je 9f
    mov [r14 + RV_prog], r12d
    mov [r14 + RV_ppct], r13d
    mov dword ptr [rip + g_dirty], 1
    mov edi, [r14 + RV_pl]
    cmp edi, -1
    je 9f
    mov esi, r12d
    or esi, [r14 + RV_busy]
    call place_set_busy
9:  EPILOGUE

# rv_find(ext, view) -> eax the instance's slot, or -1
rv_find:
    xor eax, eax
    lea rcx, [rip + rv_slots]
1:  cmp eax, RV_MAX
    jae 8f
    cmp [rcx + RV_ext], rdi
    jne 2f
    cmp [rcx + RV_view], esi
    je 9f
2:  inc eax
    add rcx, RV_SIZE
    jmp 1b
8:  mov eax, -1
9:  ret

# rview_ext_ready(ext): after the catch-up that follows ready: an instance for each of its declared
#   views, in manifest order ("open", then "visible")
FN rview_ext_ready
    PROLOGUE
    mov r12, rdi
    FEAT_TEST r12, FEAT_VIEW_TREE
    jz 9f
    xor ebx, ebx
1:  cmp rbx, [rip + vdecls + VEC_len]
    jae 9f
    mov rdi, rbx
    call vd_at
    mov r13, rax
    cmp [r13 + VD_ext], r12
    jne 8f
    cmp dword ptr [r13 + VD_pl], -1
    je 8f
    cmp dword ptr [r13 + VD_rv], -1
    jne 8f
    mov edi, [r13 + VD_kind]    # a kind whose feature it agreed
    mov rsi, r12
    call kind_agreed
    test eax, eax
    jz 8f
    mov rdi, r12
    mov esi, [r13 + VD_kind]
    mov edx, [r13 + VD_place]
    mov ecx, ebx
    call rv_open
    cmp eax, -1
    je 8f
    mov r14d, eax
    mov rdi, rbx
    call vd_at
    mov [rax + VD_rv], r14d
    mov edi, r14d
    call send_open
    mov rdi, rbx
    call vd_at
    mov edi, [rax + VD_pl]
    call place_visible
    mov esi, eax
    mov edi, r14d
    call send_visible
    call place_focused          # its place has the keyboard already (shown before it ran)
    mov r15d, eax
    mov rdi, rbx
    call vd_at
    cmp r15d, [rax + VD_pl]
    jne 8f
    mov edi, r14d
    mov esi, 1
    mov rdx, [rax + VD_name]
    call rv_focus_event
8:  inc rbx
    jmp 1b
9:  EPILOGUE

# ---------------- events ----------------

# ev_head(slot) -> eax 1 with "0 view VIEW " in evbuf, 0 when its extension does not run
ev_head:
    PROLOGUE
    mov ebx, edi
    call rv_at
    mov r12, rax
    mov rax, [r12 + RV_ext]
    test rax, rax
    jz 8f
    cmp dword ptr [rax + EXT_status], ES_RUNNING
    jne 8f
    lea rdi, [rip + evbuf]
    call sb_clear
    lea rdi, [rip + evbuf]
    lea rsi, [rip + .Lev_view]
    call sb_push_cstr
    lea rdi, [rip + evbuf]
    mov esi, [r12 + RV_view]
    call sb_push_u64
    lea rdi, [rip + evbuf]
    mov esi, ' '
    call sb_push_byte
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

ev_cstr:
    mov rsi, rdi
    lea rdi, [rip + evbuf]
    jmp sb_push_cstr
ev_u64:
    mov rsi, rdi
    lea rdi, [rip + evbuf]
    jmp sb_push_u64
ev_sp:
    lea rdi, [rip + evbuf]
    mov esi, ' '
    jmp sb_push_byte

# ev_rev(slot): " REV" of the instance (the content the user acted on)
ev_rev:
    call rv_at
    push rax
    push rax
    call ev_sp
    pop rax
    pop rax
    mov rdi, [rax + RV_rev]
    jmp ev_u64

# ev_send(slot, body, len): the event's line, with " LEN" LF and the body when len >= 0 (-1: a line
#   alone)
ev_send:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    js 1f
    call ev_sp
    mov rdi, r13
    call ev_u64
1:  lea rdi, [rip + evbuf]
    mov esi, 10
    call sb_push_byte
    test r13, r13
    jle 2f
    lea rdi, [rip + evbuf]
    mov rsi, r12
    mov rdx, r13
    call sb_push
2:  mov edi, ebx
    call rv_at
    mov rdi, [rax + RV_ext]
    mov rsi, [rip + evbuf + SB_ptr]
    mov rdx, [rip + evbuf + SB_len]
    call ext_send
    EPILOGUE

# send_open(slot): "open KIND PLACE NAME"
send_open:
    PROLOGUE
    mov ebx, edi
    call ev_head
    test eax, eax
    jz 9f
    mov edi, ebx
    call rv_at
    mov r12, rax
    lea rdi, [rip + .Lev_open]
    call ev_cstr
    mov eax, [r12 + RV_kind]
    lea rcx, [rip + kind_words]
    mov rdi, [rcx + rax*8 - 8]
    call ev_cstr
    call ev_sp
    mov eax, [r12 + RV_place]
    lea rcx, [rip + place_words]
    mov rdi, [rcx + rax*8 - 8]
    call ev_cstr
    call ev_sp
    movsxd rdi, dword ptr [r12 + RV_decl]
    lea rax, [rip + .Ldash]
    cmp rdi, -1
    je 1f
    call vd_at
    mov rax, [rax + VD_key]
1:  mov rdi, rax
    call ev_cstr
    mov edi, ebx
    xor esi, esi
    mov rdx, -1
    call ev_send
9:  EPILOGUE

# send_visible(slot, on): "visible 0|1" when it changed
send_visible:
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    call rv_at
    cmp [rax + RV_vis], r12d
    je 9f
    mov [rax + RV_vis], r12d
    mov edi, ebx
    call ev_head
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lev_visible]
    call ev_cstr
    mov edi, r12d
    call ev_u64
    mov edi, ebx
    xor esi, esi
    mov rdx, -1
    call ev_send
9:  EPILOGUE

# send_node(slot, what cstr, node): "WHAT REV LEN" and the node's id
send_node:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    call ev_head
    test eax, eax
    jz 9f
    mov rdi, r12
    call ev_cstr
    mov edi, ebx
    call ev_rev
    mov edi, ebx
    call rv_at
    mov rdi, [rax + RV_tree]
    mov esi, r13d
    call tree_node_id
    mov rsi, rax
    mov edi, ebx
    call ev_send
9:  EPILOGUE

# ---------------- the tree's callbacks (ctx: the slot) ----------------

# rv_activate(slot, tr, node): its open record opens the file, its command record runs the command,
#   else "activate REV LEN" + id
rv_activate:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    test r13d, r13d
    jz 9f
    mov rdi, r12
    mov esi, r13d
    lea rdx, [rip + .Lr_open]
    lea rcx, [rip + rr]
    call tree_extra_find
    test eax, eax
    jz 1f
    mov edi, ebx
    call open_record
    jmp 9f
1:  mov rdi, r12
    mov esi, r13d
    lea rdx, [rip + .Lr_command]
    lea rcx, [rip + rr]
    call tree_extra_find
    test eax, eax
    jz 2f
    mov edi, ebx
    call command_record
    jmp 9f
2:  mov edi, ebx
    lea rsi, [rip + .Lev_activate]
    mov edx, r13d
    call send_node
9:  EPILOGUE

# open_record(slot): rr holds "open LINE COL LEN" + PATH: the file opens there, as v1's open does,
#   with its permission checks (PATH absolute, or #DOC for an open document)
open_record:
    PROLOGUE 16
    mov ebx, edi
    cmp qword ptr [rip + rr + RR_n], 4
    jb 9f
    lea rdi, [rip + rr]
    mov esi, 1
    call tree_rec_num
    test edx, edx
    jz 9f
    mov r12, rax                # line
    lea rdi, [rip + rr]
    mov esi, 2
    call tree_rec_num
    test edx, edx
    jz 9f
    mov r13, rax                # col
    mov edi, ebx
    call rv_at
    mov rdi, [rax + RV_ext]
    mov rsi, [rip + rr + RR_data]
    mov rdx, [rip + rr + RR_len]
    mov rcx, r12
    mov r8, r13
    call rview_open_at
9:  EPILOGUE

# rview_open_at(ext, path, len, line, col): an extension's file opens at LINE COL (one-based, 0: as
#   it is), as v1's open does, with its permission checks; PATH is absolute, or #DOC for an open
#   document
FN rview_open_at
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    test r13, r13
    jz 9f
    cmp byte ptr [r12], '#'
    jne 1f
    lea rdi, [r12 + 1]
    lea rsi, [r13 - 1]
    call parse_u64
    lea rcx, [r13 - 1]
    cmp rdx, rcx
    jne 9f
    test rdx, rdx
    jz 9f
    mov rdi, rax
    call extproto_doc
    test rax, rax
    jz 9f
    mov [rsp], rax
    mov rdi, rax
    call doc_tab
    test rax, rax
    js 9f
    mov rdi, rax
    call app_activate_tab
    mov rbx, [rsp]
    jmp 5f
1:  mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov r12, rax
    PATH_ABSOLUTE r12, 2f
    jmp 8f
2:  mov rdi, r12
    call vfs_type
    cmp eax, 0x8000             # a regular file
    jne 8f
    mov rdi, rbx
    mov rsi, r12
    call ext_open_path
    mov rbx, rax
    mov rdi, r12
    call mem_free
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call app_open_file
    mov r12, rax
    mov rdi, rbx
    call mem_free
    test r12, r12
    js 9f
    mov rdi, r12
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 9f
    mov rbx, [rax + TAB_doc]
5:  # the position: past the last line, its end; past a line's end, the end
    test r14, r14
    jz 7f
    cmp r14, [rbx + DOC_nlines]
    jbe 51f
    mov r14, [rbx + DOC_nlines]
    mov r15, 1 << 40
51: lea rsi, [r14 - 1]
    mov rdi, rbx
    call doc_line_start
    mov r12, rax
    lea rsi, [r14 - 1]
    mov rdi, rbx
    call doc_line_end
    sub rax, r12
    lea rcx, [r15 - 1]
    test r15, r15
    jz 52f
    cmp rcx, rax
    jbe 53f
52: mov rcx, rax
53: add r12, rcx
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call ed_set_cursor
7:  mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# command_record(slot): rr holds "command NAME ARGS_LEN" + ARGS: the extension's command runs
command_record:
    PROLOGUE
    mov ebx, edi
    cmp qword ptr [rip + rr + RR_n], 3
    jb 9f
    mov edi, ebx
    call rv_at
    mov rdi, [rax + RV_ext]
    mov rsi, [rip + rr + 16]
    mov rdx, [rip + rr + 24]
    mov rcx, [rip + rr + RR_data]
    mov r8, [rip + rr + RR_len]
    call rview_run_command
9:  EPILOGUE

# rview_run_command(ext, name, nlen, args, alen): one of the extension's commands, as a command
#   reference runs it (invoke.s: FROM ref, ARGS as the body with command-args)
FN rview_run_command
    PROLOGUE
    call cmdref_new
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    xor esi, esi
    call cmdref_invoke
    mov rdi, rbx
    call cmdref_free
9:  EPILOGUE

# rv_expand(slot, tr, node, on): "expand REV LEN" + id, or collapse
rv_expand:
    test ecx, ecx
    jnz 1f
    push rdi
    push rdx
    mov esi, edx                # a collapse: a wait for its children is cancelled
    mov edx, 1
    call pq_cancel_node
    pop rdx
    pop rdi
    lea rsi, [rip + .Lev_collapse]
    jmp send_node
1:  lea rsi, [rip + .Lev_expand]
    jmp send_node

# rv_select(slot, tr): "select REV N LEN" + the ids, each ending in LF
rv_select:
    PROLOGUE 16
    mov ebx, edi
    mov r12, rsi
    call ev_head
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lev_select]
    call ev_cstr
    mov edi, ebx
    call ev_rev
    # the ids into the second buffer
    lea rdi, [rip + idsbuf]
    call sb_clear
    xor r13d, r13d              # count
1:  mov rdi, r12
    mov esi, r13d
    call tree_selected
    cmp eax, -1
    je 2f
    mov rdi, r12
    mov esi, eax
    call tree_node_id
    lea rdi, [rip + idsbuf]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + idsbuf]
    mov esi, 10
    call sb_push_byte
    inc r13d
    cmp r13d, 10000
    jb 1b
2:  call ev_sp
    mov edi, r13d
    call ev_u64
    mov edi, ebx
    mov rsi, [rip + idsbuf + SB_ptr]
    mov rdx, [rip + idsbuf + SB_len]
    call ev_send
9:  EPILOGUE

# rv_check(slot, tr, node, state): "check REV STATE LEN" + id
rv_check:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    call ev_head
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lev_check]
    call ev_cstr
    mov edi, ebx
    call ev_rev
    call ev_sp
    mov edi, r14d
    call ev_u64
    mov rdi, r12
    mov esi, r13d
    call tree_node_id
    mov rsi, rax
    mov edi, ebx
    call ev_send
9:  EPILOGUE

# rv_action(slot, tr, node, key, keylen): an inline button: "action REV KEY LEN" + id
rv_action:
    PROLOGUE 16
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    mov [rsp], rcx
    mov [rsp + 8], r8
    mov edi, ebx
    call ev_head
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lev_action]
    call ev_cstr
    mov edi, ebx
    call ev_rev
    call ev_sp
    lea rdi, [rip + evbuf]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
    mov rdi, r12
    mov esi, r13d
    call tree_node_id
    mov rsi, rax
    mov edi, ebx
    call ev_send
9:  EPILOGUE

# send_action(slot, key, keylen, id, idlen): "action REV KEY LEN" + id (empty: the view's own)
send_action:
    PROLOGUE 16
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], rcx
    mov [rsp + 8], r8
    call ev_head
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lev_action]
    call ev_cstr
    mov edi, ebx
    call ev_rev
    call ev_sp
    lea rdi, [rip + evbuf]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov edi, ebx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call ev_send
9:  EPILOGUE

# ---------------- children asked for: vkids, vmore ----------------

# pq_at(i) -> rax PQ*
pq_at:
    imul rax, rdi, PQ_SIZE
    lea rcx, [rip + pq_table]
    add rax, rcx
    ret

# pq_count(slot) -> eax the requests waiting for the instance
pq_count:
    xor eax, eax
    xor ecx, ecx
    lea rdx, [rip + pq_table]
1:  cmp ecx, PQ_MAX
    jae 9f
    cmp dword ptr [rdx + PQ_slot], edi
    jne 2f
    cmp qword ptr [rdx + PQ_req], 0
    je 2f
    inc eax
2:  add rdx, PQ_SIZE
    inc ecx
    jmp 1b
9:  ret

# pq_free(PQ*): the entry is free again
pq_free:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PQ_id]
    call mem_free
    mov rdi, rbx
    xor esi, esi
    mov edx, PQ_SIZE
    call memset
    pop rbx
    ret

# pq_drop_slot(slot): its waits end without a word (the instance ends)
pq_drop_slot:
    PROLOGUE
    mov ebx, edi
    xor r12d, r12d
1:  cmp r12d, PQ_MAX
    jae 9f
    mov edi, r12d
    call pq_at
    cmp qword ptr [rax + PQ_req], 0
    je 2f
    cmp [rax + PQ_slot], ebx
    jne 2f
    mov rdi, rax
    call pq_free
2:  inc r12d
    jmp 1b
9:  EPILOGUE

# pq_cancel_node(slot, node, kind): a wait of that kind for the node is cancelled ("0 cancel ID")
pq_cancel_node:
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    xor r14d, r14d
1:  cmp r14d, PQ_MAX
    jae 9f
    mov edi, r14d
    call pq_at
    mov r15, rax
    cmp qword ptr [r15 + PQ_req], 0
    je 2f
    cmp [r15 + PQ_slot], ebx
    jne 2f
    cmp [r15 + PQ_node], r12d
    jne 2f
    cmp [r15 + PQ_kind], r13d
    jne 2f
    mov edi, ebx
    call rv_at
    mov rdi, [rax + RV_ext]
    mov rsi, [r15 + PQ_req]
    call send_cancel
    mov rdi, r15
    call pq_free
2:  inc r14d
    jmp 1b
9:  EPILOGUE

# send_cancel(ext, id): "0 cancel ID" when it runs
send_cancel:
    cmp dword ptr [rdi + EXT_status], ES_RUNNING
    jne 1f
    jmp extproto_send_cancel
1:  ret

# rv_ask(slot, node, kind) -> eax 1 when "ID vkids VIEW REV LEN" (kind 1) or "ID vmore VIEW REV HAVE
#   LEN" (kind 2) and the node's id went out, 0 when 4 already wait (asked again on a later frame)
rv_ask:
    PROLOGUE 16
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    call pq_count
    cmp eax, PQ_PER_VIEW
    jae 8f
    mov edi, ebx
    call rv_at
    mov r14, rax
    mov r15, [r14 + RV_ext]
    cmp dword ptr [r15 + EXT_status], ES_RUNNING
    jne 8f
    # a free entry
    xor ecx, ecx
1:  cmp ecx, PQ_MAX
    jae 8f
    mov edi, ecx
    push rcx
    push rcx
    call pq_at
    pop rcx
    pop rcx
    cmp qword ptr [rax + PQ_req], 0
    je 2f
    inc ecx
    jmp 1b
2:  mov [rsp], rax
    cmp qword ptr [r15 + EXT_hreq], 2147483647
    jae 8f
    inc qword ptr [r15 + EXT_hreq]
    mov rcx, [r15 + EXT_hreq]
    mov [rax + PQ_req], rcx
    mov [rax + PQ_slot], ebx
    mov [rax + PQ_node], r12d
    mov [rax + PQ_kind], r13d
    mov rdi, [r14 + RV_tree]    # the node's generation
    mov esi, r12d
    call tree_nd
    mov ecx, [rax + ND_gen]
    mov rax, [rsp]
    mov [rax + PQ_gen], ecx
    call time_ms
    mov rcx, [rsp]
    mov [rcx + PQ_sent], rax
    mov rdi, [r14 + RV_tree]
    mov esi, r12d
    call tree_node_id
    mov [rsp + 8], rdx
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rcx, [rsp]
    mov [rcx + PQ_id], rax
    mov rdx, [rsp + 8]
    mov [rcx + PQ_idlen], rdx
    # the request
    lea rdi, [rip + evbuf]
    call sb_clear
    mov rcx, [rsp]
    lea rdi, [rip + evbuf]
    mov rsi, [rcx + PQ_req]
    call sb_push_u64
    lea rdi, [rip + evbuf]
    lea rsi, [rip + .Lq_vkids]
    cmp r13d, 1
    je 3f
    lea rsi, [rip + .Lq_vmore]
3:  call sb_push_cstr
    lea rdi, [rip + evbuf]
    mov esi, [r14 + RV_view]
    call sb_push_u64
    lea rdi, [rip + evbuf]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + evbuf]
    mov rsi, [r14 + RV_rev]
    call sb_push_u64
    cmp r13d, 2
    jne 4f
    lea rdi, [rip + evbuf]      # HAVE: the children it has
    mov esi, ' '
    call sb_push_byte
    mov rdi, [r14 + RV_tree]
    mov esi, r12d
    call tree_nd
    mov esi, [rax + ND_nkids]
    lea rdi, [rip + evbuf]
    call sb_push_u64
4:  lea rdi, [rip + evbuf]
    mov esi, ' '
    call sb_push_byte
    mov rcx, [rsp]
    lea rdi, [rip + evbuf]
    mov rsi, [rcx + PQ_idlen]
    call sb_push_u64
    lea rdi, [rip + evbuf]
    mov esi, 10
    call sb_push_byte
    mov rcx, [rsp]
    lea rdi, [rip + evbuf]
    mov rsi, [rcx + PQ_id]
    mov rdx, [rcx + PQ_idlen]
    call sb_push
    mov rdi, r15
    mov rsi, [rip + evbuf + SB_ptr]
    mov rdx, [rip + evbuf + SB_len]
    call ext_send
    mov rcx, [rsp]              # resources group: the request's kind and time
    mov rdi, r15
    mov rsi, [rcx + PQ_req]
    lea rdx, [rip + .Lq_vkids + 1]
    mov ecx, 5
    cmp r13d, 1
    je 5f
    lea rdx, [rip + .Lq_vmore + 1]
5:  call extres_req_sent
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# rv_load(slot, tr, node): its children are wanted: vkids (later when 4 already wait)
rv_load:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    mov esi, edx
    mov edx, 1
    call rv_ask
    test eax, eax
    jnz 9f
    mov rdi, r12                # not now: asked again when it is next drawn
    mov esi, r13d
    call tree_nd
    and dword ptr [rax + ND_flags], ~NF_LOADING
9:  EPILOGUE

# rv_more(slot, tr, parent): its "Load more" row is on screen: vmore
rv_more:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    mov esi, edx
    mov edx, 2
    call rv_ask
    test eax, eax
    jnz 9f
    mov rdi, r12
    mov esi, r13d
    call tree_nd
    and dword ptr [rax + ND_flags], ~NF_MOREWAIT
9:  EPILOGUE

# pq_node_alive(PQ*) -> eax 1 when the node asked about is still there with the same id
pq_node_alive:
    PROLOGUE
    mov rbx, rdi
    mov edi, [rbx + PQ_slot]
    call rv_at
    mov r12, [rax + RV_tree]
    mov rdi, r12
    mov rsi, [rbx + PQ_id]
    mov rdx, [rbx + PQ_idlen]
    call tree_find
    cmp eax, [rbx + PQ_node]
    jne 8f
    mov rdi, r12
    mov esi, eax
    call tree_nd
    mov ecx, [rax + ND_gen]
    xor eax, eax
    cmp ecx, [rbx + PQ_gen]
    sete al
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# rview_reply(ext, id, ok, body, len) -> eax 1 when the reply answers a vkids or vmore: its patch is
#   applied as vpatch's (REV + 1) unless the node is gone; an error, or a patch that cannot apply,
#   makes the node's error row
FN rview_reply
    PROLOGUE 16
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push r8
    call viewpic_reply          # a vcopy's answer (viewpic.s)
    pop r8
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    test eax, eax
    jz 11f
    EPILOGUE
11: mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov [rsp], rcx
    mov [rsp + 8], r8
    xor r14d, r14d
1:  cmp r14d, PQ_MAX
    jae 8f
    mov edi, r14d
    call pq_at
    mov r15, rax
    cmp [r15 + PQ_req], r12
    jne 2f
    mov edi, [r15 + PQ_slot]
    call rv_at
    cmp [rax + RV_ext], rbx
    je 3f
2:  inc r14d
    jmp 1b
3:  mov rdi, r15
    call pq_node_alive
    test eax, eax
    jz 7f                       # the node went: the answer is dropped
    mov edi, [r15 + PQ_slot]
    call rv_at
    mov r14, rax
    test r13d, r13d
    jz 5f
    mov edi, [r15 + PQ_slot]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call patch_check
    test eax, eax
    jnz 5f
    mov edi, [r15 + PQ_slot]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call patch_apply
    inc qword ptr [r14 + RV_rev]
    # an answer without the node's children leaves it with none; one without more ends paging
    mov rdi, [r14 + RV_tree]
    mov esi, [r15 + PQ_node]
    call tree_nd
    test dword ptr [rax + ND_flags], NF_LIVE
    jz 7f
    cmp dword ptr [r15 + PQ_kind], 1
    jne 4f
    test dword ptr [rax + ND_flags], NF_GIVEN
    jnz 7f
    mov rdi, [r14 + RV_tree]
    mov esi, [r15 + PQ_node]
    call tree_kids_begin
    mov rdi, [r14 + RV_tree]
    xor esi, esi
    call tree_kids_end
    jmp 7f
4:  test dword ptr [rax + ND_flags], NF_MOREWAIT
    jz 7f
    and dword ptr [rax + ND_flags], ~(NF_MOREWAIT | NF_MORE)
    mov rdi, [r14 + RV_tree]
    or dword ptr [rdi + TR_flags], TRF_DIRTY
    jmp 7f
5:  mov rdi, [r14 + RV_tree]
    mov esi, [r15 + PQ_node]
    call tree_set_error
7:  mov rdi, r15
    call pq_free
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# rview_timeout() -> ms until a wait for children times out, or -1
FN rview_timeout
    PROLOGUE
    mov r12d, -1
    call time_ms
    mov r13, rax
    xor ebx, ebx
1:  cmp ebx, PQ_MAX
    jae 9f
    mov edi, ebx
    call pq_at
    cmp qword ptr [rax + PQ_req], 0
    je 2f
    mov rcx, [rax + PQ_sent]
    add rcx, PQ_WAIT_MS
    sub rcx, r13
    jns 11f
    xor ecx, ecx
11: cmp r12d, -1
    je 12f
    cmp ecx, r12d
    jge 2f
12: mov r12d, ecx
2:  inc ebx
    jmp 1b
9:  mov eax, r12d
    EPILOGUE

# rview_tick(): waits past 15 s become error rows ("No answer"), their requests cancelled
FN rview_tick
    PROLOGUE
    call time_ms
    mov r13, rax
    xor ebx, ebx
1:  cmp ebx, PQ_MAX
    jae 9f
    mov edi, ebx
    call pq_at
    mov r12, rax
    cmp qword ptr [r12 + PQ_req], 0
    je 2f
    mov rcx, [r12 + PQ_sent]
    add rcx, PQ_WAIT_MS
    cmp r13, rcx
    jb 2f
    mov rdi, r12
    call pq_node_alive
    test eax, eax
    jz 3f
    mov edi, [r12 + PQ_slot]
    call rv_at
    mov r14, rax
    mov rdi, [r14 + RV_tree]
    mov esi, [r12 + PQ_node]
    call tree_set_error
    mov rdi, [r14 + RV_ext]
    mov rsi, [r12 + PQ_req]
    call send_cancel
3:  mov rdi, r12
    call pq_free
2:  inc ebx
    jmp 1b
9:  EPILOGUE

# ---------------- actions ----------------

# actions_free(RV*): its actions' bytes
actions_free:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + RV_actions + VEC_len]
    jae 2f
    imul r13, r12, RA_SIZE
    add r13, [rbx + RV_actions + VEC_ptr]
    mov rdi, [r13 + TA_key]
    call mem_free
    mov rdi, [r13 + TA_title]
    call mem_free
    inc r12
    jmp 1b
2:  lea rdi, [rbx + RV_actions]
    call vec_free
    EPILOGUE

# action_find(RV*, key, len) -> rax RA* or 0
action_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, [rbx + RV_actions + VEC_len]
    jae 8f
    imul r15, r14, RA_SIZE
    add r15, [rbx + RV_actions + VEC_ptr]
    cmp [r15 + TA_keylen], r13
    jne 2f
    mov rdi, [r15 + TA_key]
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jnz 3f
2:  inc r14
    jmp 1b
3:  mov rax, r15
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# action_set(RV*, key, keylen, icon spec, speclen, where, title, titlelen [stack]): defines or
#   replaces the action (where 0 removes it)
action_set:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov [rsp + 16], rcx
    mov [rsp + 24], r8
    mov r15d, r9d
    mov rsi, [rsp]
    call action_find
    mov r12, rax
    test r15d, r15d
    jnz 2f
    test r12, r12               # none: removed (the last one takes its place)
    jz 9f
    mov rdi, [r12 + TA_key]
    call mem_free
    mov rdi, [r12 + TA_title]
    call mem_free
    dec qword ptr [rbx + RV_actions + VEC_len]
    mov rax, [rbx + RV_actions + VEC_len]
    imul rax, rax, RA_SIZE
    add rax, [rbx + RV_actions + VEC_ptr]
    cmp rax, r12
    je 1f
    mov rdi, r12
    mov rsi, rax
    mov edx, RA_SIZE
    call memcpy
1:  jmp 8f
2:  test r12, r12
    jnz 3f
    lea rdi, [rbx + RV_actions]
    mov esi, RA_SIZE
    call vec_push
    mov r12, rax
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call mem_dup
    mov [r12 + TA_key], rax
    mov rax, [rsp + 8]
    mov [r12 + TA_keylen], rax
3:  mov [r12 + RA_where], r15d
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    call tree_icon_code
    cmp eax, -1
    je 4f
    test eax, NDI_FILE
    jz 4f
    and eax, 0xff               # a file's icon without its color
4:  mov [r12 + TA_icon], eax
    mov rdi, [r12 + TA_title]
    call mem_free
    mov rdi, [rbp + 16]
    mov rsi, [rbp + 24]
    call mem_dup
    mov [r12 + TA_title], rax
8:  # the tree looks inline keys up in them
    mov rdi, [rbx + RV_tree]
    mov rsi, [rbx + RV_actions + VEC_ptr]
    mov rdx, [rbx + RV_actions + VEC_len]
    call tree_set_actions
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# rv_place_actions(vd, right, y, h) -> eax the x left of them: the view's title actions in its
#   section's header, right to left in reverse definition order; a click is "action REV KEY 0"
rv_place_actions:
    PROLOGUE 32
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], edi
    call rv_of_vd
    mov ebx, eax
    mov eax, [rsp]
    cmp ebx, -1
    je .Lpb_done
    mov edi, ebx
    call rv_at
    mov r12, rax
    cmp dword ptr [r12 + RV_kind], RK_LOG
    jne 1f
    mov rdi, r12                # a log's own: Follow, Clear, Find
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, ebx
    call log_buttons
    mov [rsp], eax
1:  mov r13, [r12 + RV_actions + VEC_len]
.Lpb_btn:
    test r13, r13
    jz .Lpb_done
    dec r13
    imul r14, r13, RA_SIZE
    add r14, [r12 + RV_actions + VEC_ptr]
    cmp dword ptr [r14 + RA_where], RAW_TITLE
    jne .Lpb_btn
    M r15d, MI_24
    sub [rsp], r15d
    mov edi, [rsp + 12]         # an id per declared view and action
    shl edi, 6
    add edi, r13d
    add edi, ID_RV_ACT
    mov [rsp + 16], edi
    mov esi, [rsp]
    mov edx, [rsp + 8]
    sub edx, r15d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r15d
    mov r8d, r15d
    mov r9d, [r14 + TA_icon]
    cmp r9d, -1
    jne 1f
    mov r9d, IC_DOT
1:  call ui_icon_btn
    mov [rsp + 20], eax
    mov rax, [r14 + TA_title]
    test rax, rax
    jz 2f
    push rax
    push rax
    mov edi, [rsp + 16 + 16]
    mov esi, [rsp + 16]
    mov edx, [rsp + 16 + 4]
    add edx, [rsp + 16 + 8]
    mov ecx, r15d
    mov r8d, [rsp + 16 + 20]
    pop r9
    pop r9
    call tip_note_text
2:  test dword ptr [rsp + 20], UB_CLICK
    jz .Lpb_btn
    mov edi, ebx
    mov rsi, [r14 + TA_key]
    mov rdx, [r14 + TA_keylen]
    xor ecx, ecx
    xor r8d, r8d
    call send_action
    jmp .Lpb_done
.Lpb_done:
    # the extensions' manifest view_title items (menu.s), left of the view's own buttons
    mov edi, [rsp + 12]
    call vd_at
    mov rdi, [rax + VD_name]
    call menu_btn_target_view
    mov edi, VML_TITLE
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, 4
    mov r9d, [rsp + 12]
    shl r9d, 3
    add r9d, ID_RV_MTITLE
    call menu_buttons_draw
    sub [rsp], eax
    mov [rsp + 16], eax
    mov edi, [rsp + 12]
    call vd_at
    mov ecx, [rsp]
    mov [rax + VD_mtx], ecx
    mov ecx, [rsp + 16]
    mov [rax + VD_mtw], ecx
    mov eax, [rsp]
9:  EPILOGUE

# rv_view_name(slot) -> rax its view's name for menus and context keys ("OWNER/NAME.KEY", a tab's
#   "OWNER/NAME.tab"), or 0
rv_view_name:
    push rbx
    call rv_at
    mov edi, [rax + RV_pl]
    call place_at
    test rax, rax
    jz 9f
    mov rax, [rax + PL_name]
9:  pop rbx
    ret

# node_ctx_cstr(tr, node) -> rax its ctx record's value as a cstr (ctxbuf), or 0 without one
node_ctx_cstr:
    PROLOGUE
    lea rdx, [rip + .Lr_ctx]
    lea rcx, [rip + rr2]
    call tree_extra_find
    test eax, eax
    jz 8f
    mov rcx, [rip + rr2 + RR_len]
    cmp rcx, 100
    jbe 1f
    mov ecx, 100
1:  lea rdi, [rip + ctxbuf]
    mov rsi, [rip + rr2 + RR_data]
    mov rdx, rcx
    push rcx
    push rcx
    call memcpy
    pop rcx
    pop rcx
    lea rax, [rip + ctxbuf]
    mov byte ptr [rax + rcx], 0
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# rv_rowbuttons(slot, tr, node, right, y, h) -> eax the width drawn: the extensions' manifest
#   view_item_inline items for the row (tree_set_rowbuttons)
rv_rowbuttons:
    PROLOGUE 32
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov [rsp + 8], r9d
    mov edi, ebx
    call rv_view_name
    test rax, rax
    jz 8f
    mov r14, rax
    mov rdi, r12
    mov esi, r13d
    call node_ctx_cstr
    mov r15, rax
    mov rdi, r12
    mov esi, r13d
    call tree_node_id
    mov rdi, r14
    mov rsi, rax
    mov rcx, r15
    call menu_btn_target_item
    mov r9d, ebx                # its widgets: the cursor row's and the hovered row's apart
    shl r9d, 4
    add r9d, ID_RV_MROW
    cmp r13d, [r12 + TR_cursor]
    je 1f
    add r9d, 8
1:  mov edi, VML_ITEM_INLINE
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, 4
    call menu_buttons_draw
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# log_buttons(RV*, right, y, h, slot) -> eax the x left of them: a log's Find, Clear and Follow
#   (accented while following) in its header
log_buttons:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    xor r12d, r12d              # the button
1:  cmp r12d, 3
    jae 8f
    M r15d, MI_24
    sub [rsp], r15d
    mov edi, [rsp + 12]
    shl edi, 2
    add edi, r12d
    add edi, ID_RV_LOGBTN
    mov [rsp + 16], edi
    mov esi, [rsp]
    mov edx, [rsp + 8]
    sub edx, r15d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r15d
    mov r8d, r15d
    lea rax, [rip + log_icons]
    mov r9d, [rax + r12*4]
    call ui_icon_btn
    mov [rsp + 20], eax
    cmp r12d, 2                 # Follow: a line under it while following
    jne 2f
    mov rdi, [rbx + RV_log]
    call log_following
    test eax, eax
    jz 2f
    mov edi, [rsp]
    add edi, [rip + g_mt + 4*MI_4]
    mov esi, [rsp + 4]
    add esi, [rsp + 8]
    sub esi, [rip + g_mt + 4*MI_4]
    M edx, MI_16
    M ecx, MI_2
    COLOR r8d, T_ACCENT
    call gfx_fill
2:  lea rax, [rip + log_tips]
    mov rax, [rax + r12*8]
    push rax
    push rax
    mov edi, [rsp + 16 + 16]
    mov esi, [rsp + 16]
    mov edx, [rsp + 16 + 4]
    add edx, [rsp + 16 + 8]
    M ecx, MI_24
    mov r8d, [rsp + 16 + 20]
    pop r9
    pop r9
    call tip_note_text
    test dword ptr [rsp + 20], UB_CLICK
    jz 7f
    mov rdi, [rbx + RV_log]
    cmp r12d, 0
    jne 3f
    call log_open_find
    mov edi, [rsp + 12]         # and the keyboard to the view
    call rv_at
    mov edi, [rax + RV_pl]
    call place_focus
    jmp 7f
3:  cmp r12d, 1
    jne 4f
    call log_clear
    mov edi, [rsp + 12]
    call send_clear
    jmp 7f
4:  call log_toggle_follow
7:  inc r12d
    jmp 1b
8:  mov eax, [rsp]
    EPILOGUE

# send_clear(slot): "clear": the user cleared the log
send_clear:
    push rbx
    mov ebx, edi
    call ev_head
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lev_clear]
    call ev_cstr
    mov edi, ebx
    xor esi, esi
    mov rdx, -1
    call ev_send
9:  pop rbx
    ret

# kind_agreed(kind, ext) -> eax 1 when the extension agreed the kind's features
kind_agreed:
    xor eax, eax
    FEAT_TEST rsi, FEAT_VIEW_TREE
    jz 9f
    cmp edi, RK_TREE
    je 8f
    cmp edi, RK_TABLE
    jne 3f
    FEAT_TEST rsi, FEAT_VIEW_TABLE
    jz 9f
    jmp 8f
3:  cmp edi, RK_PICTURE
    jne 1f
    FEAT_TEST rsi, FEAT_VIEWS   # a picture view: section 12a's draw and events
    jz 9f
    jmp 8f
1:  cmp edi, RK_FORM
    jne 4f
    FEAT_TEST rsi, FEAT_VIEW_FORM
    jz 9f
    jmp 8f
4:  cmp edi, RK_DOC
    jne 2f
    FEAT_TEST rsi, FEAT_VIEW_DOC
    jz 9f
    jmp 8f
2:  cmp edi, RK_LOG
    jne 9f
    FEAT_TEST rsi, FEAT_VIEW_LOG
    jz 9f
8:  mov eax, 1
9:  ret

# rview_picture_of_place(place item) -> rax the picture of the picture view it holds, or 0
FN rview_picture_of_place
    PROLOGUE
    mov r12d, edi
    xor ebx, ebx
1:  cmp ebx, RV_MAX
    jae 8f
    mov edi, ebx
    call rv_at
    cmp qword ptr [rax + RV_ext], 0
    je 2f
    cmp [rax + RV_pl], r12d
    jne 2f
    cmp dword ptr [rax + RV_kind], RK_PICTURE
    jne 2f
    mov rax, [rax + RV_vw]
    EPILOGUE
2:  inc ebx
    jmp 1b
8:  xor eax, eax
    EPILOGUE

# rv_menu(slot, tr, node, x, y): the node's menu record's actions as a context menu; a pick sends
#   "action REV KEY LEN" + id, or "discarded REV action LEN" + id when the node went meanwhile
rv_menu:
    PROLOGUE 32
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov rdi, r12
    mov esi, r13d
    lea rdx, [rip + .Lr_menu]
    lea rcx, [rip + rr]
    call tree_extra_find
    test eax, eax
    jz .Lrm_manifest
    mov edi, ebx
    call rv_at
    mov r14, rax
    # remember the node by id, and the REV the user acted on
    mov rdi, [rip + menu_node_id]
    call mem_free
    mov rdi, r12
    mov esi, r13d
    call tree_node_id
    mov [rip + menu_node_len], rdx
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + menu_node_id], rax
    mov [rip + menu_slot], ebx
    mov rax, [r14 + RV_rev]
    mov [rip + menu_rev], rax
    mov rax, [r14 + RV_ext]
    mov [rip + menu_ext], rax
    # the items: up to 16 keys; their labels and keys copied (a patch may replace the actions while
    # the menu is open)
    lea rdi, [rip + menu_arena]
    call sb_clear
    mov r15, [rip + rr + RR_data]
    mov rax, r15
    add rax, [rip + rr + RR_len]
    mov [rsp + 8], rax
    xor ebx, ebx                # items
1:  cmp ebx, 16
    jae 5f
2:  cmp r15, [rsp + 8]
    jae 5f
    cmp byte ptr [r15], ' '
    jne 3f
    inc r15
    jmp 2b
3:  mov rcx, r15
4:  cmp rcx, [rsp + 8]
    jae 41f
    cmp byte ptr [rcx], ' '
    je 41f
    inc rcx
    jmp 4b
41: mov [rsp + 16], rcx
    mov rdi, r14
    mov rsi, r15
    mov rdx, rcx
    sub rdx, r15
    call action_find
    mov r15, [rsp + 16]
    test rax, rax
    jz 1b
    mov [rsp + 24], rax         # its RA: its label and key into the arena (offsets for now)
    lea rcx, [rip + menu_items]
    mov rdx, rbx
    shl rdx, 4
    mov rsi, [rip + menu_arena + SB_len]
    mov [rcx + rdx], rsi
    lea rsi, [rip + rv_menu_pick]
    mov [rcx + rdx + 8], rsi
    mov rax, [rsp + 24]
    mov rsi, [rax + TA_title]
    test rsi, rsi
    jz 42f
    lea rdi, [rip + menu_arena]
    call sb_push_cstr
    jmp 43f
42: lea rdi, [rip + menu_arena]
    mov rax, [rsp + 24]
    mov rsi, [rax + TA_key]
    mov rdx, [rax + TA_keylen]
    call sb_push
43: lea rdi, [rip + menu_arena]
    xor esi, esi
    call sb_push_byte
    mov rsi, [rip + menu_arena + SB_len]
    lea rcx, [rip + menu_keyp]
    mov [rcx + rbx*8], rsi
    mov rax, [rsp + 24]
    mov rsi, [rax + TA_keylen]
    lea rcx, [rip + menu_keyl]
    mov [rcx + rbx*8], rsi
    lea rdi, [rip + menu_arena]
    mov rax, [rsp + 24]
    mov rsi, [rax + TA_key]
    mov rdx, [rax + TA_keylen]
    call sb_push
    lea rdi, [rip + menu_arena]
    xor esi, esi
    call sb_push_byte
    inc ebx
    jmp 1b
5:  test ebx, ebx
    jz 9f
    xor ecx, ecx                # the offsets become pointers into the arena, now that it is whole
    mov rdx, [rip + menu_arena + SB_ptr]
51: cmp ecx, ebx
    jae 52f
    mov rax, rcx
    shl rax, 4
    lea r8, [rip + menu_items]
    add [r8 + rax], rdx
    lea r8, [rip + menu_keyp]
    add [r8 + rcx*8], rdx
    inc ecx
    jmp 51b
52:
    lea rcx, [rip + menu_items]
    mov rdx, rbx
    shl rdx, 4
    mov qword ptr [rcx + rdx], 0
    mov qword ptr [rcx + rdx + 8], 0
    lea rdi, [rip + menu_items]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call ctx_menu_open
9:  EPILOGUE
.Lrm_manifest:
    # no menu record: the extensions' manifest view_item items (menu.s), if any
    mov edi, ebx
    call rv_view_name
    test rax, rax
    jz 9b
    mov r14, rax
    mov rdi, r12
    mov esi, r13d
    call node_ctx_cstr
    mov r15, rax
    mov rdi, r12
    mov esi, r13d
    call tree_node_id
    mov rdi, r14
    mov rsi, rax
    mov rcx, r15
    mov r8d, [rsp]
    mov r9d, [rsp + 4]
    call menu_open_view_item
    jmp 9b

# rv_menu_pick(): the item g_menu_index of rv_menu's menu
rv_menu_pick:
    PROLOGUE 16
    mov ebx, [rip + menu_slot]
    mov edi, ebx
    call rv_at
    mov r12, rax
    mov rax, [rip + menu_ext]
    cmp [r12 + RV_ext], rax
    jne 9f                      # the instance went
    mov r13d, [rip + g_menu_index]
    lea rax, [rip + menu_keyp]
    mov r14, [rax + r13*8]      # the key (copied below: the action may have been replaced)
    lea rax, [rip + menu_keyl]
    mov r15, [rax + r13*8]
    mov rdi, [r12 + RV_tree]
    mov rsi, [rip + menu_node_id]
    mov rdx, [rip + menu_node_len]
    call tree_find
    cmp eax, -1
    jne 2f
    # the node went while the menu was open: dropped, and said so
    mov edi, ebx
    call ev_head
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lev_discarded]
    call ev_cstr
    call ev_sp
    mov rdi, [rip + menu_rev]
    call ev_u64
    lea rdi, [rip + .Lev_sp_action]
    call ev_cstr
    mov edi, ebx
    mov rsi, [rip + menu_node_id]
    mov rdx, [rip + menu_node_len]
    call ev_send
    jmp 9f
2:  mov rdi, r12
    mov rsi, r14
    mov rdx, r15
    call action_find
    test rax, rax
    jz 9f
    mov edi, ebx
    mov rsi, [rax + TA_key]
    mov rdx, [rax + TA_keylen]
    mov rcx, [rip + menu_node_id]
    mov r8, [rip + menu_node_len]
    call send_action
9:  EPILOGUE

# ---------------- vreveal ----------------

# rview_reveal(ext, view, how, howlen, id, idlen) -> eax 0, 1 no such view, 2 no such node: the
#   node's ancestors expand and it scrolls into view; HOW: "-" or a comma list of select, focus
#   (the keyboard to the view, the cursor on the node), expand (the node itself)
FN rview_reveal
    PROLOGUE 32
    mov r12, rdx
    mov r13, rcx
    mov [rsp], r8
    mov [rsp + 8], r9
    call rv_find
    cmp eax, -1
    je 7f
    mov ebx, eax
    mov edi, eax
    call rv_at
    mov r14, rax
    mov rdi, [r14 + RV_tree]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call tree_find
    cmp eax, -1
    je 8f
    test eax, eax
    jz 8f
    mov r15d, eax
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lh_expand]
    call how_has
    test eax, eax
    jz 1f
    mov rdi, [r14 + RV_tree]
    mov esi, r15d
    mov edx, 1
    call tree_expand
1:  mov rdi, [r14 + RV_tree]
    mov esi, r15d
    call tree_reveal
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lh_select]
    call how_has
    mov [rsp + 16], eax
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lh_focus]
    call how_has
    mov [rsp + 20], eax
    or eax, [rsp + 16]
    jz 2f
    mov rdi, [r14 + RV_tree]
    mov esi, r15d
    call tree_set_cursor
    mov rdi, [r14 + RV_tree]
    mov esi, r15d
    call tree_reveal
2:  movsxd rdi, dword ptr [r14 + RV_decl]
    cmp rdi, -1
    je 3f
    call vd_at
    mov edi, [rax + VD_pl]
    mov esi, [rsp + 20]
    call place_show
3:  xor eax, eax
    EPILOGUE
7:  mov eax, 1
    EPILOGUE
8:  mov eax, 2
    EPILOGUE

# how_has(ptr, len, word cstr) -> eax 1 when the comma list holds the word
how_has:
    PROLOGUE
    mov r12, rdi
    lea r13, [rdi + rsi]
    mov r14, rdx
1:  cmp r12, r13
    jae 8f
    mov rbx, r12
2:  cmp rbx, r13
    jae 3f
    cmp byte ptr [rbx], ','
    je 3f
    inc rbx
    jmp 2b
3:  mov rdi, r12
    mov rsi, rbx
    sub rsi, r12
    mov rdx, r14
    call str_eq_cstr
    test eax, eax
    jnz 9f
    lea r12, [rbx + 1]
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# ---------------- the declared views' places (ctx: the VD index) ----------------

# rv_of_vd(vd) -> eax its instance's slot, or -1
rv_of_vd:
    call vd_at
    mov eax, [rax + VD_rv]
    ret

# rv_place_draw(vd, x, y, w, h): the view in its place: its message, its state or its tree; with no
#   instance the extension's state (showing it starts an extension that has not run)
rv_place_draw:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    call vd_at
    mov r12, rax
    mov r13, [r12 + VD_ext]
    test r13, r13
    jz 9f
    movsxd rax, dword ptr [r12 + VD_rv]
    cmp rax, -1
    jne .Lpd_instance
    # no instance: the extension's state
    mov eax, [r13 + EXT_status]
    cmp eax, ES_IDLE
    jne 1f
    cmp dword ptr [r12 + VD_started], 0
    jne 2f
    mov dword ptr [r12 + VD_started], 1
    mov rdi, r13
    call ext_start              # a view shown starts its extension, as its commands do
2:  lea r8, [rip + .Lloading]
    jmp .Lpd_text
1:  cmp eax, ES_STARTING
    je 2b
    cmp eax, ES_RUNNING
    jne 3f
    lea r8, [rip + .Lunsupported]
    jmp .Lpd_text
3:  # stopped, crashed, failed, turned off: why, and Start
    mov r8, [r13 + EXT_reason]
    test r8, r8
    jnz 31f
    lea r8, [rip + .Lstopped]
31: lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_4]
    M ecx, MI_24
    COLOR r9d, T_MUTED
    call ui_text_c
    cmp dword ptr [r13 + EXT_status], ES_DISABLED
    je 9f
    cmp dword ptr [r13 + EXT_status], ES_REMOVED
    je 9f
    mov edi, ebx
    shl edi, 4
    add edi, ID_RV_BTN
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_32]
    lea rcx, [rip + .Lstart]
    call text_button
    test eax, UB_CLICK
    jz 9f
    mov rdi, r13
    call ext_restart_now
    jmp 9f
.Lpd_text:
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_4]
    M ecx, MI_24
    COLOR r9d, T_MUTED
    call ui_text_c
    jmp 9f
.Lpd_instance:
    mov edi, eax
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call rv_instance_draw
9:  EPILOGUE

# rv_instance_draw(slot, x, y, w, h): an instance's body: its message, busy bar, its state (Loading,
#   empty or error text with up to 3 action buttons) or its content (tree, log)
rv_instance_draw:
    PROLOGUE 48
    mov ebx, edi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    call rv_at
    mov r14, rax
    call place_focused
    xor ecx, ecx
    cmp eax, [r14 + RV_pl]
    sete cl
    mov [rsp + 16], ecx         # it has the keyboard
    # its message above everything
    mov rax, [r14 + RV_message]
    test rax, rax
    jz 4f
    cmp byte ptr [rax], 0
    je 4f
    mov rdi, rax
    call strlen
    mov r9, rax
    mov eax, [rsp + 8]
    sub eax, [rip + g_mt + 4*MI_32]
    COLOR ecx, T_MUTED
    push rax
    push rcx
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 16]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 16 + 4]
    M ecx, MI_24
    mov r8, [r14 + RV_message]
    call ui_text_v_fit
    add rsp, 16
    M eax, MI_24
    add [rsp + 4], eax
    sub [rsp + 12], eax
4:  # busy: a thin bar at the top; progress: a bar with its share (or a moving third)
    cmp dword ptr [r14 + RV_prog], 0
    je 41f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [r14 + RV_ppct]
    call notify_bar
    jmp 5f
41: cmp dword ptr [r14 + RV_busy], 0
    je 5f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    M ecx, MI_2
    COLOR r8d, T_ACCENT
    call gfx_fill
5:  mov eax, [r14 + RV_state]
    cmp eax, RS_EMPTY
    je .Lid_state
    cmp eax, RS_ERROR
    je .Lid_state
    cmp eax, RS_LOADING
    je .Lid_loading
    cmp eax, RS_READY
    je .Lid_content
    call time_ms                # no state yet (nor content): Loading after 300 ms
    sub rax, [r14 + RV_opened]
    cmp rax, 300
    jb 9f
.Lid_loading:
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_4]
    M ecx, MI_24
    lea r8, [rip + .Lloading]
    COLOR r9d, T_MUTED
    call ui_text_c
    jmp 9f
.Lid_state:
    mov r8, [r14 + RV_stext]
    test r8, r8
    jz 6f
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_16]
    mov ecx, [rsp + 8]
    M r9d, MI_24
    xchg r8, r9
    COLOR eax, T_MUTED
    cmp dword ptr [r14 + RV_state], RS_ERROR
    jne 51f
    COLOR eax, T_ERROR
51: push rax
    push rax
    call ui_text_center
    add rsp, 16
6:  # its keys as buttons, centered under the text: "action REV KEY 0" each
    mov r12, [r14 + RV_skeys]
    test r12, r12
    jz 9f
    mov eax, [rsp + 4]
    add eax, [rip + g_mt + 4*MI_48]
    mov [rsp + 20], eax         # y
    mov eax, [rsp]
    add eax, [rip + g_mt + 4*MI_16]
    mov [rsp + 24], eax         # x
    mov dword ptr [rsp + 28], 0 # buttons
.Lid_key:
    cmp dword ptr [rsp + 28], 3
    jae 9f
71: cmp byte ptr [r12], ' '
    jne 72f
    inc r12
    jmp 71b
72: cmp byte ptr [r12], 0
    je 9f
    mov r13, r12
73: cmp byte ptr [r13], 0
    je 74f
    cmp byte ptr [r13], ' '
    je 74f
    inc r13
    jmp 73b
74: # its title from the actions, else the key itself
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    sub rdx, r12
    call action_find
    lea rdi, [rip + keybuf]
    mov rsi, r12
    mov rcx, r13
    sub rcx, r12
    cmp rcx, 60
    jbe 75f
    mov ecx, 60
75: rep movsb
    mov byte ptr [rdi], 0
    lea rcx, [rip + keybuf]
    test rax, rax
    jz 76f
    mov rdx, [rax + TA_title]
    test rdx, rdx
    jz 76f
    cmp byte ptr [rdx], 0
    je 76f
    mov rcx, rdx
76: mov edi, ebx
    shl edi, 4
    add edi, [rsp + 28]
    add edi, ID_RV_STATE
    mov esi, [rsp + 24]
    mov edx, [rsp + 20]
    call text_button
    mov [rsp + 32], eax
    mov [rsp + 36], edx
    test dword ptr [rsp + 32], UB_CLICK
    jz 77f
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    sub rdx, r12
    xor ecx, ecx
    xor r8d, r8d
    call send_action
77: mov eax, [rsp + 36]
    add eax, [rip + g_mt + 4*MI_8]
    add [rsp + 24], eax
    inc dword ptr [rsp + 28]
    mov r12, r13
    jmp .Lid_key
.Lid_content:
    cmp dword ptr [r14 + RV_kind], RK_LOG
    je .Lid_log
    cmp dword ptr [r14 + RV_kind], RK_PICTURE
    jne 1f
    mov rdi, [r14 + RV_vw]
    test rdi, rdi
    jz 9f
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call extview_draw_vw
    jmp 9f
1:  cmp dword ptr [r14 + RV_kind], RK_DOC
    jne 12f
    mov rdi, [r14 + RV_doc]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    mov r9d, [rsp + 16]
    call mdview_draw
    jmp 9f
12: cmp dword ptr [r14 + RV_kind], RK_FORM
    jne 11f
    mov rdi, [r14 + RV_form]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    mov r9d, [rsp + 16]
    call form_draw
    jmp 9f
11:
    mov rdi, [r14 + RV_tree]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    mov r9d, [rsp + 16]
    call tree_draw
    jmp 9f
.Lid_log:
    mov rdi, [r14 + RV_log]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    mov r9d, [rsp + 16]
    call log_draw
9:  EPILOGUE

# text_button(id, x, y, label cstr) -> eax UB bits, edx its width: a small accented button
text_button:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov r12, rcx
    mov rdi, rcx
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r12
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_24]
    mov [rsp + 12], eax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, eax
    M r8d, MI_24
    call ui_btn
    mov [rsp + 16], eax
    mov edi, [rsp + 4]
    mov esi, [rsp + 8]
    mov edx, [rsp + 12]
    M ecx, MI_24
    M r8d, MI_RADIUS
    COLOR r9d, T_ACCENT
    call gfx_round_rect
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    M r8d, MI_24
    mov r9, r12
    COLOR eax, T_ACCENT_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    mov eax, [rsp + 16]
    mov edx, [rsp + 12]
    EPILOGUE

# rv_place_key(vd, keysym, cp, mods) -> eax 1 when its tree took the key
rv_place_key:
    push rsi
    push rdx
    push rcx
    call rv_of_vd
    mov edi, eax
    pop rcx
    pop rdx
    pop rsi
    cmp edi, -1
    jne rv_instance_key
    xor eax, eax
    ret

# rv_instance_key(slot, keysym, cp, mods) -> eax 1 when its content took the key
rv_instance_key:
    PROLOGUE
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    call rv_at
    cmp dword ptr [rax + RV_kind], RK_LOG
    je 1f
    cmp dword ptr [rax + RV_kind], RK_PICTURE
    je 2f
    cmp dword ptr [rax + RV_kind], RK_FORM
    je 4f
    cmp dword ptr [rax + RV_kind], RK_DOC
    je 5f
    mov rdi, [rax + RV_tree]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tree_key
    EPILOGUE
2:  mov rdi, [rax + RV_vw]      # a picture view (viewpic.s: with view-keys)
    test rdi, rdi
    jz 3f
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call viewpic_key
    EPILOGUE
3:  xor eax, eax
    EPILOGUE
1:  mov rdi, [rax + RV_log]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call log_key
    EPILOGUE
4:  mov rdi, [rax + RV_form]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call form_key
    EPILOGUE
5:  mov rdi, [rax + RV_doc]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call mdview_key
    EPILOGUE

# rv_place_focus(vd, on): "focus 0|1"; the context keys viewFocus and view follow it
rv_place_focus:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    call vd_at
    mov r13, [rax + VD_name]
    mov rdi, rbx
    call rv_of_vd
    mov edi, eax
    mov esi, r12d
    mov rdx, r13
    call rv_focus_event
    EPILOGUE

# rv_focus_event(slot or -1, on, name cstr): "focus 0|1" to the instance; viewFocus and view follow
rv_focus_event:
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov r13, rdx
    mov edi, CTX_VIEW_FOCUS
    mov esi, r12d
    call ctx_set_bool
    xor r14d, r14d
    test r12d, r12d
    jz 1f
    mov rdi, r13
    call strlen
    mov r14, rax
1:  mov edi, CTX_VIEW
    mov rsi, r13
    mov rdx, r14
    call ctx_set
    cmp ebx, -1
    je 9f
    mov edi, ebx
    call ev_head
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lev_focus]
    call ev_cstr
    mov edi, r12d
    call ev_u64
    mov edi, ebx
    xor esi, esi
    mov rdx, -1
    call ev_send
9:  EPILOGUE

# rv_place_visible(vd, on): "visible 0|1"; a view shown again may start its extension again
rv_place_visible:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    test r12d, r12d
    jnz 1f
    mov rdi, rbx
    call vd_at
    mov dword ptr [rax + VD_started], 0
1:  mov rdi, rbx
    call rv_of_vd
    cmp eax, -1
    je 9f
    mov edi, eax
    mov esi, r12d
    call send_visible
9:  EPILOGUE

# ---------------- vshow ----------------

# rview_show(ext, name, len, focus) -> eax the view's number, or -1 (no such declared view): its
#   place opens on it, focus 1 gives it the keyboard
FN rview_show
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15d, ecx
    xor ebx, ebx
1:  cmp rbx, [rip + vdecls + VEC_len]
    jae 8f
    mov rdi, rbx
    call vd_at
    cmp [rax + VD_ext], r12
    jne 2f
    mov rdi, r13
    mov rsi, r14
    mov rdx, [rax + VD_key]
    call str_eq_cstr
    test eax, eax
    jnz 3f
2:  inc rbx
    jmp 1b
3:  mov rdi, rbx
    call vd_at
    cmp dword ptr [rax + VD_pl], -1
    je 8f
    cmp dword ptr [rax + VD_rv], -1
    je 8f
    mov edi, [rax + VD_pl]
    mov esi, r15d
    call place_show
    mov rdi, rbx
    call vd_at
    mov edi, [rax + VD_rv]
    call rv_at
    mov eax, [rax + RV_view]
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

.section .rodata
.Lev_view: .asciz "0 view "
.Lev_open: .asciz "open "
.Lev_visible: .asciz "visible "
.Lev_focus: .asciz "focus "
.Lev_activate: .asciz "activate"
.Lev_expand: .asciz "expand"
.Lev_collapse: .asciz "collapse"
.Lev_select: .asciz "select"
.Lev_clear: .asciz "clear"
.Llt_find: .asciz "Find"
.Llt_clear: .asciz "Clear"
.Llt_follow: .asciz "Follow the end"
.Lev_check: .asciz "check"
.Lev_action: .asciz "action"
.Lev_discarded: .asciz "discarded"
.Lev_sp_action: .asciz " action"
.Lq_vkids: .asciz " vkids "
.Lq_vmore: .asciz " vmore "
.Lr_menu: .asciz "menu"
.Lr_ctx: .asciz "ctx"
.Ld_titlebuttons: .asciz "titlebuttons "
.Ld_x: .asciz " x="
.Ld_w: .asciz " w="
.Lh_select: .asciz "select"
.Lh_focus: .asciz "focus"
.Lh_expand: .asciz "expand"
.Ldash: .asciz "-"
.Lr_open: .asciz "open"
.Lr_command: .asciz "command"
.Lf_title: .asciz "title"
.Lf_place: .asciz "place"
.Lf_kind: .asciz "kind"
.Lf_icon: .asciz "icon"
.Lf_when: .asciz "when"
.Lf_open: .asciz "open"
.Lw_yes: .asciz "yes"
.Lw_sidebar: .asciz "sidebar"
.Lw_panel: .asciz "panel"
.Lw_side: .asciz "side"
.Lw_tab: .asciz "tab"
.Lw_tree: .asciz "tree"
.Lw_table: .asciz "table"
.Lw_log: .asciz "log"
.Lw_form: .asciz "form"
.Lw_doc: .asciz "doc"
.Lw_picture: .asciz "picture"
.Lpg_in: .asciz "in the "
.Lpg_when: .asciz "when "
.Lpg_open: .asciz "open at start"
.Lloading: .asciz "Loading\342\200\246"
.Lunsupported: .asciz "This extension does not support this kind of view."
.Lstopped: .asciz "The extension is stopped."
.Lstart: .asciz "Start"
.p2align 3
place_words: .quad .Lw_sidebar, .Lw_panel, .Lw_side, .Lw_tab, 0     # PLACE_* - 1
kind_words: .quad .Lw_tree, .Lw_table, .Lw_log, .Lw_form, .Lw_doc, .Lw_picture, 0  # RK_* - 1
log_icons: .long IC_SEARCH, IC_DISCARD, IC_ARROW_DN       # Find, Clear, Follow (right to left)
.p2align 3
log_tips: .quad .Llt_find, .Llt_clear, .Llt_follow
rv_place_ops: .quad rv_place_draw, rv_place_key, rv_place_focus, 0, rv_place_actions, rv_place_visible
rv_tree_ops: .quad rv_activate, rv_expand, rv_select, rv_check, rv_menu, rv_more, 0, rv_load, rv_action

# ---------------- patches ----------------
# A patch is checked whole first (every op and record read, every node it names looked up in the
# content as the ops before it leave it: the live nodes, the nodes it creates (OV entries), the
# ones it removes (a mark on live nodes, a flag on entries)); only then applied, op by op.

.text

# set_err(cstr): the error text
set_err:
    mov rsi, rdi
    lea rdi, [rip + errbuf]
    jmp cstr_copy

# err_syntax(): "syntax op N" (p_op)
err_syntax:
    PROLOGUE
    lea rdi, [rip + .Le_syntax_op]
    call set_err
    lea rdi, [rip + errbuf]
    call strlen
    lea rbx, [rip + errbuf]
    add rbx, rax
    mov rdi, rbx
    mov rsi, [rip + p_op]
    call fmt_u64
    mov byte ptr [rbx + rax], 0
    mov eax, 1
    EPILOGUE

# err_badpos(op cstr, id, len): "badpos OP ID" (the id cut to 100 bytes)
err_badpos:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + .Le_badpos]
    call set_err
    lea rdi, [rip + errbuf]
    call strlen
    lea r14, [rip + errbuf]
    add r14, rax
    mov rdi, r14
    mov rsi, rbx
    call cstr_copy
    mov rdi, r14
    call strlen
    add r14, rax
    mov byte ptr [r14], ' '
    inc r14
    cmp r13, 100
    jbe 1f
    mov r13d, 100
1:  mov rdi, r14
    mov rsi, r12
    mov rcx, r13
    rep movsb
    mov byte ptr [rdi], 0
    mov eax, 1
    EPILOGUE

# ---- the check's tables ----

# ov_at(e) -> rax OV*
ov_at:
    imul rax, rdi, OV_SIZE
    add rax, [rip + ov + VEC_ptr]
    ret

# tables_reset(): empty tables for a new patch (large ones from a big patch are let go)
tables_reset:
    PROLOGUE
    mov qword ptr [rip + ov + VEC_len], 0
    cmp qword ptr [rip + ovh_cap], 1024
    jbe 1f
    mov rdi, [rip + ovh]
    call mem_free
    mov qword ptr [rip + ovh], 0
    mov qword ptr [rip + ovh_cap], 0
1:  cmp qword ptr [rip + ovp_cap], 1024
    jbe 2f
    mov rdi, [rip + ovp]
    call mem_free
    mov qword ptr [rip + ovp], 0
    mov qword ptr [rip + ovp_cap], 0
2:  mov rdi, [rip + ovh]
    test rdi, rdi
    jz 3f
    xor esi, esi
    mov rdx, [rip + ovh_cap]
    shl rdx, 2
    call memset
3:  mov rdi, [rip + ovp]
    test rdi, rdi
    jz 4f
    xor esi, esi
    mov rdx, [rip + ovp_cap]
    shl rdx, 3
    call memset
4:  mov qword ptr [rip + ovh_n], 0
    mov qword ptr [rip + ovp_n], 0
    EPILOGUE

# ovh_find(ptr, len) -> eax the latest entry with that id, or -1
ovh_find:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    cmp qword ptr [rip + ovh_cap], 0
    je 8f
    call tree_id_hash
    mov r14, [rip + ovh_cap]
    dec r14
    and rax, r14
    mov rbx, rax
1:  mov rcx, [rip + ovh]
    mov eax, [rcx + rbx*4]
    test eax, eax
    jz 8f
    dec eax
    mov r15d, eax
    mov edi, eax
    call ov_at
    cmp [rax + OV_idlen], r13d
    jne 2f
    mov rdi, [rax + OV_id]
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jz 2f
    mov eax, r15d
    EPILOGUE
2:  inc rbx
    and rbx, r14
    jmp 1b
8:  mov eax, -1
    EPILOGUE

# ovh_put(e): the entry is the latest with its id
ovh_put:
    PROLOGUE
    mov r12d, edi
    mov rax, [rip + ovh_n]
    inc rax
    add rax, rax
    cmp rax, [rip + ovh_cap]
    jbe 1f
    call ovh_grow
1:  mov edi, r12d
    call ov_at
    mov r13, [rax + OV_id]
    mov r14d, [rax + OV_idlen]
    mov rdi, r13
    mov rsi, r14
    call tree_id_hash
    mov r15, [rip + ovh_cap]
    dec r15
    and rax, r15
    mov rbx, rax
2:  mov rcx, [rip + ovh]
    mov eax, [rcx + rbx*4]
    test eax, eax
    jz 4f
    dec eax
    mov edi, eax
    call ov_at
    cmp [rax + OV_idlen], r14d
    jne 3f
    mov rdi, [rax + OV_id]
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jnz 5f
3:  inc rbx
    and rbx, r15
    jmp 2b
4:  inc qword ptr [rip + ovh_n]
5:  mov rcx, [rip + ovh]
    lea eax, [r12 + 1]
    mov [rcx + rbx*4], eax
    EPILOGUE

# ovh_grow(): twice the slots (64 at least), the entries put again
ovh_grow:
    PROLOGUE
    mov rbx, [rip + ovh_cap]
    add rbx, rbx
    cmp rbx, 64
    jae 1f
    mov ebx, 64
1:  mov rdi, [rip + ovh]
    call mem_free
    lea rdi, [rbx*4]
    call mem_alloc
    mov [rip + ovh], rax
    mov [rip + ovh_cap], rbx
    mov qword ptr [rip + ovh_n], 0
    xor r12d, r12d
2:  cmp r12, [rip + ov + VEC_len]
    jae 9f
    mov edi, r12d
    call ovh_put
    inc r12
    jmp 2b
9:  EPILOGUE

# ovp_slot(node) -> rax the slot of the live node's pair (its key 0 when it has none yet)
ovp_slot:
    PROLOGUE
    mov r12d, edi
    mov rax, [rip + ovp_n]
    inc rax
    add rax, rax
    cmp rax, [rip + ovp_cap]
    jbe 1f
    call ovp_grow
1:  mov eax, r12d
    mov ecx, 0x9e3779b1
    imul eax, ecx
    mov rcx, [rip + ovp_cap]
    dec rcx
    and rax, rcx
    mov rdx, [rip + ovp]
    lea r8d, [r12 + 1]
2:  mov r9d, [rdx + rax*8]
    test r9d, r9d
    jz 3f
    cmp r9d, r8d
    je 3f
    inc rax
    and rax, rcx
    jmp 2b
3:  lea rax, [rdx + rax*8]
    EPILOGUE

# ovp_grow(): twice the slots (64 at least), the pairs put again
ovp_grow:
    PROLOGUE
    mov r12, [rip + ovp]
    mov r13, [rip + ovp_cap]
    lea rbx, [r13 + r13]
    cmp rbx, 64
    jae 1f
    mov ebx, 64
1:  lea rdi, [rbx*8]
    call mem_alloc
    mov [rip + ovp], rax
    mov [rip + ovp_cap], rbx
    mov qword ptr [rip + ovp_n], 0
    xor r14d, r14d
2:  cmp r14, r13
    jae 8f
    mov eax, [r12 + r14*8]
    test eax, eax
    jz 3f
    mov r15d, [r12 + r14*8 + 4]
    lea edi, [rax - 1]
    call ovp_slot
    mov ecx, [r12 + r14*8]
    mov [rax], ecx
    mov [rax + 4], r15d
    inc qword ptr [rip + ovp_n]
3:  inc r14
    jmp 2b
8:  mov rdi, r12
    call mem_free
    EPILOGUE

# head(ref) -> eax the first entry created under the node, or -1
head:
    test edi, OVF
    jz 1f
    and edi, ~OVF
    call ov_at
    mov eax, [rax + OV_first]
    ret
1:  cmp qword ptr [rip + ovp_cap], 0
    je 2f
    call ovp_slot
    cmp dword ptr [rax], 0
    je 2f
    mov eax, [rax + 4]
    dec eax
    ret
2:  mov eax, -1
    ret

# set_head(ref, e)
set_head:
    push rbx
    mov ebx, esi
    test edi, OVF
    jz 1f
    and edi, ~OVF
    call ov_at
    mov [rax + OV_first], ebx
    pop rbx
    ret
1:  push rdi
    call ovp_slot
    pop rdi
    cmp dword ptr [rax], 0
    jne 2f
    inc qword ptr [rip + ovp_n]
    lea ecx, [rdi + 1]
    mov [rax], ecx
2:  lea ecx, [rbx + 1]
    mov [rax + 4], ecx
    pop rbx
    ret

# ov_new(id, len, parent ref) -> eax a new entry under the parent, with the current kids mark
ov_new:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    lea rdi, [rip + ov]
    mov esi, OV_SIZE
    call vec_push
    mov [rax + OV_id], r12
    mov [rax + OV_idlen], r13d
    mov [rax + OV_parent], r14d
    mov ecx, [rip + p_kmark]
    mov [rax + OV_mark], ecx
    mov dword ptr [rax + OV_first], -1
    mov rbx, [rip + ov + VEC_len]
    dec rbx
    mov edi, r14d
    call head
    mov r15d, eax
    mov edi, ebx
    call ov_at
    mov [rax + OV_next], r15d
    mov edi, r14d
    mov esi, ebx
    call set_head
    mov edi, ebx
    call ovh_put
    inc qword ptr [rip + p_created]
    mov eax, ebx
    EPILOGUE

# live_alive(node) -> eax 1 unless the patch removed it or an ancestor
live_alive:
    mov rcx, [rip + p_tree]
    mov r8d, [rip + p_rmark]
1:  test edi, edi
    jle 8f
    mov eax, edi
    imul rax, rax, ND_SIZE
    add rax, [rcx + TR_nodes + VEC_ptr]
    cmp [rax + ND_mark], r8d
    je 9f
    mov edi, [rax + ND_parent]
    jmp 1b
8:  mov eax, 1
    ret
9:  xor eax, eax
    ret

# ov_alive(e) -> eax 1 unless it or an ancestor was removed
ov_alive:
1:  call ov_at
    cmp dword ptr [rax + OV_removed], 0
    jne 9f
    mov edi, [rax + OV_parent]
    test edi, OVF
    jz live_alive
    and edi, ~OVF
    jmp 1b
9:  xor eax, eax
    ret

# resolve(id, len) -> eax the node the id names as the patch leaves it so far (a node, or OVF | an
#   entry), or -1; the empty id is the root
resolve:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor eax, eax
    test r13, r13
    jz 9f
    call ovh_find
    cmp eax, -1
    je 2f
    mov ebx, eax
    mov edi, eax
    call ov_alive
    test eax, eax
    jz 8f
    mov eax, ebx
    or eax, OVF
    EPILOGUE
2:  mov rdi, [rip + p_tree]
    mov rsi, r12
    mov rdx, r13
    call tree_find
    cmp eax, -1
    je 9f
    mov ebx, eax
    mov edi, eax
    call live_alive
    test eax, eax
    jz 8f
    mov eax, ebx
    EPILOGUE
8:  mov eax, -1
9:  EPILOGUE

# ref_parent(ref) -> eax its parent as a ref
ref_parent:
    test edi, OVF
    jz 1f
    and edi, ~OVF
    call ov_at
    mov eax, [rax + OV_parent]
    ret
1:  mov rcx, [rip + p_tree]
    imul rax, rdi, ND_SIZE
    add rax, [rcx + TR_nodes + VEC_ptr]
    mov eax, [rax + ND_parent]
    ret

# ref_mark(ref) -> eax its kids mark; set_mark(ref, mark)
ref_mark:
    test edi, OVF
    jz 1f
    and edi, ~OVF
    call ov_at
    mov eax, [rax + OV_mark]
    ret
1:  mov rcx, [rip + p_tree]
    imul rax, rdi, ND_SIZE
    add rax, [rcx + TR_nodes + VEC_ptr]
    mov eax, [rax + ND_mark]
    ret
set_mark:
    test edi, OVF
    jz 1f
    and edi, ~OVF
    push rsi
    call ov_at
    pop rsi
    mov [rax + OV_mark], esi
    ret
1:  mov rcx, [rip + p_tree]
    imul rax, rdi, ND_SIZE
    add rax, [rcx + TR_nodes + VEC_ptr]
    mov [rax + ND_mark], esi
    ret

# remove_ref(ref): the patch removes the node (live: its subtree's nodes are counted out)
remove_ref:
    PROLOGUE
    test edi, OVF
    jz 1f
    and edi, ~OVF
    call ov_at
    mov dword ptr [rax + OV_removed], 1
    EPILOGUE
1:  mov rbx, [rip + p_tree]
    mov r12d, edi
    mov r15d, [rip + p_rmark]
    imul rax, r12, ND_SIZE
    add rax, [rbx + TR_nodes + VEC_ptr]
    mov [rax + ND_mark], r15d
    # count it and what under it was not removed before (nodes and bytes)
    inc qword ptr [rip + p_removed]
    mov edi, r12d
    call live_drop
    imul rax, r12, ND_SIZE
    add rax, [rbx + TR_nodes + VEC_ptr]
    movsxd r13, dword ptr [rax + ND_first]
2:  cmp r13, -1
    je 9f
    imul rax, r13, ND_SIZE
    add rax, [rbx + TR_nodes + VEC_ptr]
    cmp [rax + ND_mark], r15d
    je 3f
    inc qword ptr [rip + p_removed]
    mov edi, r13d
    call live_drop
    imul rax, r13, ND_SIZE
    add rax, [rbx + TR_nodes + VEC_ptr]
    movsxd rcx, dword ptr [rax + ND_first]
    cmp rcx, -1
    je 3f
    mov r13, rcx
    jmp 2b
3:  # next: the sibling, else up until one has a sibling (not past the removed node)
    imul rax, r13, ND_SIZE
    add rax, [rbx + TR_nodes + VEC_ptr]
    movsxd rcx, dword ptr [rax + ND_next]
    cmp rcx, -1
    je 4f
    mov r13, rcx
    jmp 2b
4:  movsxd r13, dword ptr [rax + ND_parent]
    cmp r13d, r12d
    je 9f
    jmp 3b
9:  EPILOGUE

# remove_kids(ref, keep mark): the node's children (live and created) not holding the mark go
remove_kids:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    test r12d, OVF
    jnz 3f
    mov rbx, [rip + p_tree]
    imul rax, r12, ND_SIZE
    add rax, [rbx + TR_nodes + VEC_ptr]
    movsxd r14, dword ptr [rax + ND_first]
1:  cmp r14, -1
    je 3f
    imul rax, r14, ND_SIZE
    add rax, [rbx + TR_nodes + VEC_ptr]
    movsxd r15, dword ptr [rax + ND_next]
    mov ecx, [rax + ND_mark]
    cmp ecx, r13d
    je 2f
    cmp ecx, [rip + p_rmark]
    je 2f
    mov edi, r14d
    call remove_ref
2:  mov r14, r15
    jmp 1b
3:  mov edi, r12d
    call head
    mov r14d, eax
4:  cmp r14d, -1
    je 9f
    mov edi, r14d
    call ov_at
    mov r15d, [rax + OV_next]
    cmp [rax + OV_mark], r13d
    je 5f
    mov dword ptr [rax + OV_removed], 1
5:  mov r14d, r15d
    jmp 4b
9:  EPILOGUE

# node_rec(q, end) -> rax the byte after it, or 0: "ID_LEN LABEL_LEN EXTRA_LEN KIDS" LF and the bytes,
#   into nrec (id, idlen, label, lablen, extra, xlen, kids)
node_rec:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rbx, rdi
    lea r14, [rip + nrec]
    xor r15d, r15d              # numbers read
1:  mov rdi, rbx
    mov rsi, r13
    sub rsi, rbx
    cmp rsi, 11
    jbe 11f
    mov esi, 11
11: call parse_u64
    test rdx, rdx
    jz 8f
    add rbx, rdx
    cmp rbx, r13
    jae 8f
    cmp byte ptr [rbx], ' '
    jne 8f
    inc rbx
    lea rcx, [rip + nrec_slots]
    mov rcx, [rcx + r15*8]
    mov [r14 + rcx], rax
    inc r15d
    cmp r15d, 3
    jb 1b
    # KIDS to the line's end
    mov rcx, rbx
2:  cmp rcx, r13
    jae 8f
    cmp byte ptr [rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  mov rdx, rcx
    sub rdx, rbx
    push rcx
    push rdx
    mov rdi, rbx
    mov rsi, rdx
    lea rdx, [rip + .Lw_leaf]
    call str_eq_cstr
    mov r15d, KIDS_LEAF
    test eax, eax
    jnz 4f
    mov rdi, rbx
    mov rsi, [rsp]
    lea rdx, [rip + .Lw_closed]
    call str_eq_cstr
    mov r15d, KIDS_CLOSED
    test eax, eax
    jnz 4f
    mov rdi, rbx
    mov rsi, [rsp]
    lea rdx, [rip + .Lw_open]
    call str_eq_cstr
    mov r15d, KIDS_OPEN
    test eax, eax
    jnz 4f
    add rsp, 16
    jmp 8f
4:  pop rdx
    pop rcx
    mov [r14 + 48], r15
    lea rbx, [rcx + 1]
    # the bytes
    mov rax, [r14 + 8]
    add rax, [r14 + 24]
    jc 8f
    add rax, [r14 + 40]
    jc 8f
    mov rcx, r13
    sub rcx, rbx
    cmp rax, rcx
    ja 8f
    mov [r14], rbx
    add rbx, [r14 + 8]
    mov [r14 + 16], rbx
    add rbx, [r14 + 24]
    mov [r14 + 32], rbx
    add rbx, [r14 + 40]
    mov [r14 + 56], rbx
    mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# nrec_check() -> eax 1 when the record in nrec is good: an id of 1 to 1000 bytes without LF or NUL,
#   a one-line label of at most 1000, extra bytes that are whole records
nrec_check:
    PROLOGUE
    lea rbx, [rip + nrec]
    mov rcx, [rbx + 8]
    test rcx, rcx
    jz 8f
    cmp rcx, LABEL_MAX
    ja 8f
    mov rdi, [rbx]
    mov esi, 10
    call has_byte
    test eax, eax
    jnz 8f
    mov rdi, [rbx]
    mov rcx, [rbx + 8]
    xor esi, esi
    call has_byte
    test eax, eax
    jnz 8f
    mov rcx, [rbx + 24]
    cmp rcx, LABEL_MAX
    ja 8f
    mov rdi, [rbx + 16]
    mov esi, 10
    call has_byte
    test eax, eax
    jnz 8f
    mov r12, [rbx + 32]
    mov r13, r12
    add r13, [rbx + 40]
1:  cmp r12, r13
    jae 9f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + rr2]
    call tree_rec_read
    test rax, rax
    jz 8f
    mov r12, rax
    jmp 1b
9:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# has_byte(ptr, byte, len in rcx) -> eax 1 when the bytes hold it
has_byte:
    xor eax, eax
    test rcx, rcx
    jz 9f
    mov eax, esi
    repne scasb
    sete al
    movzx eax, al
9:  ret

# ---- checking ----

# patch_check(slot, body, len) -> eax 0 when the patch can be applied whole, else 1 with errbuf
patch_check:
    PROLOGUE
    mov qword ptr [rip + p_touched + VEC_len], 0
    mov qword ptr [rip + p_freed], 0
    call patch_check_ops
    mov ebx, eax
    # the live nodes it counted out lose the mark
    mov r12, [rip + p_tree]
    xor r13d, r13d
1:  cmp r13, [rip + p_touched + VEC_len]
    jae 2f
    mov rax, [rip + p_touched + VEC_ptr]
    mov eax, [rax + r13*4]
    imul rax, rax, ND_SIZE
    add rax, [r12 + TR_nodes + VEC_ptr]
    and dword ptr [rax + ND_flags], ~NF_PCOUNT
    mov dword ptr [rax + ND_pend], 0
    inc r13
    jmp 1b
2:  mov eax, ebx
    EPILOGUE

# nrec_bytes() -> rax the bytes the node record in nrec keeps (id, label, extra); edi kept
nrec_bytes:
    mov rax, [rip + nrec + 8]
    add rax, [rip + nrec + 24]
    add rax, [rip + nrec + 40]
    ret

# live_free(node): the patch replaces or removes a live node: its bytes count out (once)
live_free:
    PROLOGUE
    mov rbx, [rip + p_tree]
    mov r12d, edi
    imul rax, r12, ND_SIZE
    add rax, [rbx + TR_nodes + VEC_ptr]
    test dword ptr [rax + ND_flags], NF_PCOUNT
    jnz 9f
    or dword ptr [rax + ND_flags], NF_PCOUNT
    mov ecx, [rax + ND_idlen]
    add ecx, [rax + ND_lablen]
    add ecx, [rax + ND_xlen]
    add [rip + p_freed], rcx
    lea rdi, [rip + p_touched]
    mov esi, 4
    call vec_push
    mov [rax], r12d
9:  EPILOGUE

# ref_bytes(ref, bytes): a record lands on a node: a created one keeps its bytes, a live one's
#   bytes count out and the record's in
ref_bytes:
    PROLOGUE
    mov rbx, rsi
    test edi, OVF
    jz 1f
    and edi, ~OVF
    call ov_at
    mov [rax + OV_bytes], ebx
    EPILOGUE
1:  mov r12d, edi
    call live_free
    mov rax, [rip + p_tree]     # only its last record counts: an earlier one's bytes come off
    imul rcx, r12, ND_SIZE
    add rcx, [rax + TR_nodes + VEC_ptr]
    mov eax, [rcx + ND_pend]
    sub [rip + p_bytes], rax
    mov [rcx + ND_pend], ebx
    add [rip + p_bytes], rbx
    EPILOGUE

# live_drop(node): the patch removes a live node: its bytes, and what a record brought it, count out
live_drop:
    push rbx
    mov ebx, edi
    call live_free
    mov rax, [rip + p_tree]
    imul rcx, rbx, ND_SIZE
    add rcx, [rax + TR_nodes + VEC_ptr]
    mov eax, [rcx + ND_pend]
    sub [rip + p_bytes], rax
    mov dword ptr [rcx + ND_pend], 0
    pop rbx
    ret

# patch_check_ops(slot, body, len) -> eax as patch_check (which clears the marks this leaves)
patch_check_ops:
    PROLOGUE 48
    mov [rsp], edi
    mov r12, rsi                # p
    lea r13, [rsi + rdx]        # end
    call rv_at
    mov rax, [rax + RV_tree]
    mov [rip + p_tree], rax
    call tables_reset
    call tree_mark_new
    mov [rip + p_rmark], eax
    mov dword ptr [rip + p_kmark], 0
    mov edi, [rsp]
    call rv_at
    mov [rip + p_rv], rax
    mov ecx, [rax + RV_kind]
    mov [rip + p_kind], ecx
    push rax
    push rax
    mov rdi, [rax + RV_form]    # a form counts its fields across the patch's ops
    call form_check_begin
    pop rax
    pop rax
    mov rdi, rax                # the action keys it would have, staged op by op
    call akeys_init
    xor eax, eax
    mov [rip + p_created], rax
    mov [rip + p_removed], rax
    mov [rip + p_bytes], rax
    mov [rip + p_op], rax
    # the count line
    mov rcx, r12
1:  cmp rcx, r13
    jae .Lpc_syntax
    cmp byte ptr [rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov rdi, r12
    mov rsi, rcx
    sub rsi, r12
    mov [rsp + 8], rsi
    push rcx
    push rcx
    call parse_u64
    pop rcx
    pop rcx
    cmp rdx, [rsp + 8]
    jne .Lpc_syntax
    test rdx, rdx
    jz .Lpc_syntax
    cmp rax, 100000
    ja .Lpc_toobig
    mov [rsp + 16], rax         # ops
    lea r12, [rcx + 1]
.Lpc_op:
    mov rax, [rip + p_op]
    cmp rax, [rsp + 16]
    jae .Lpc_end
    inc qword ptr [rip + p_op]
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + rr]
    call tree_rec_read
    test rax, rax
    jz .Lpc_syntax
    mov r12, rax
    lea rbx, [rip + rr]
    # title LEN
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_title]
    call tree_rec_is
    test eax, eax
    jz 3f
    cmp qword ptr [rbx + RR_len], TITLE_MAX
    ja .Lpc_syntax
    call data_one_line
    test eax, eax
    jz .Lpc_syntax
    jmp .Lpc_op
3:  mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_message]
    call tree_rec_is
    test eax, eax
    jz 4f
    cmp qword ptr [rbx + RR_len], LABEL_MAX
    ja .Lpc_syntax
    call data_one_line
    test eax, eax
    jz .Lpc_syntax
    jmp .Lpc_op
4:  mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_badge]
    call tree_rec_is
    test eax, eax
    jz 5f
    cmp qword ptr [rbx + RR_n], 3
    jne .Lpc_syntax
    mov rdi, rbx
    mov esi, 1
    call tree_rec_num
    test edx, edx
    jz .Lpc_syntax
    jmp .Lpc_op
5:  mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_busy]
    call tree_rec_is
    test eax, eax
    jz 6f
    cmp qword ptr [rbx + RR_n], 3
    jne .Lpc_syntax
    mov rdi, rbx
    mov esi, 1
    call tree_rec_num
    test edx, edx
    jz .Lpc_syntax
    cmp rax, 1
    ja .Lpc_syntax
    jmp .Lpc_op
6:  mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_state]
    call tree_rec_is
    test eax, eax
    jz 7f
    cmp qword ptr [rbx + RR_n], 4
    jne .Lpc_syntax
    call state_word
    test eax, eax
    jz .Lpc_syntax
    mov rdi, rbx
    mov esi, 2
    call tree_rec_num
    test edx, edx
    jz .Lpc_syntax
    cmp rax, [rbx + RR_len]
    ja .Lpc_syntax
    cmp rax, LABEL_MAX
    ja .Lpc_syntax
    jmp .Lpc_op
7:  mov rdi, rbx                # a doc's: doc LEN, base LEN, follow DOC 0 (rdoc.s)
    call mdview_check_op
    cmp eax, -1
    je 704f
    cmp dword ptr [rip + p_kind], RK_DOC
    jne .Lpc_kind
    test eax, eax
    jz .Lpc_syntax
    cmp eax, 2
    je .Lpc_toobig_doc
    jmp .Lpc_op
704:mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_log]
    call tree_rec_is
    test eax, eax
    jz 701f
    cmp dword ptr [rip + p_kind], RK_LOG
    jne .Lpc_kind
    call check_log_op
    test eax, eax
    jz .Lpc_syntax
    jmp .Lpc_op
701:mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_clear]
    call tree_rec_is
    test eax, eax
    jz 703f
    cmp dword ptr [rip + p_kind], RK_LOG
    jne .Lpc_kind
    jmp .Lpc_op
703:mov rdi, rbx                # a form's: form N LEN, field LEN (rform.s checks the records)
    call form_op_count
    cmp eax, -2
    je 702f
    cmp dword ptr [rip + p_kind], RK_FORM
    jne .Lpc_kind
    cmp eax, -3
    je .Lpc_syntax
    mov ecx, eax
    mov rax, [rip + p_rv]
    mov rdi, [rax + RV_form]
    mov rsi, [rbx + RR_data]
    mov rdx, [rbx + RR_len]
    call form_check
    cmp eax, 1
    je .Lpc_syntax
    cmp eax, 2
    je .Lpc_toobig_form
    jmp .Lpc_op
702:mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_action]
    call tree_rec_is
    test eax, eax
    jz 71f
    call check_action_op
    test eax, eax
    jz .Lpc_syntax
    js .Lpc_toobig_actions
    jmp .Lpc_op
71: mov rdi, rbx                # a table's: columns N LEN, sorted COL DIR 0
    xor esi, esi
    lea rdx, [rip + .Lo_columns]
    call tree_rec_is
    test eax, eax
    jz 711f
    cmp dword ptr [rip + p_kind], RK_TABLE
    jne .Lpc_kind
    call check_columns_op
    test eax, eax
    jz .Lpc_syntax
    jmp .Lpc_op
711:mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_sorted]
    call tree_rec_is
    test eax, eax
    jz 712f
    cmp dword ptr [rip + p_kind], RK_TABLE
    jne .Lpc_kind
    call sorted_args
    test eax, eax
    js .Lpc_syntax
    jmp .Lpc_op
712:cmp dword ptr [rip + p_kind], RK_TREE  # the tree's own ops (a table's too)
    je 713f
    cmp dword ptr [rip + p_kind], RK_TABLE
    jne .Lpc_tree_ops_other_kind
713:mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_select_mode]
    call tree_rec_is
    test eax, eax
    jz 72f
    cmp qword ptr [rbx + RR_n], 3
    jne .Lpc_syntax
    call select_mode_word
    test eax, eax
    jz .Lpc_syntax
    jmp .Lpc_op
72: mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_kids]
    call tree_rec_is
    mov r14d, 1                 # kids
    test eax, eax
    jnz .Lpc_kids
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_add]
    call tree_rec_is
    xor r14d, r14d              # add
    test eax, eax
    jnz .Lpc_kids
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_set]
    call tree_rec_is
    test eax, eax
    jnz .Lpc_set
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_del]
    call tree_rec_is
    test eax, eax
    jnz .Lpc_del
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_expand]
    call tree_rec_is
    test eax, eax
    jnz .Lpc_exists
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_collapse]
    call tree_rec_is
    test eax, eax
    jnz .Lpc_exists
    jmp .Lpc_op                 # an op rhun does not know is skipped
.Lpc_exists:
    # expand / collapse ID: a node that exists
    mov rdi, [rbx + RR_data]
    mov rsi, [rbx + RR_len]
    call resolve
    cmp eax, -1
    jne .Lpc_op
    lea rdi, [rip + .Lo_expand]
    jmp .Lpc_badpos_data
.Lpc_del:
    mov rdi, [rbx + RR_data]
    mov rsi, [rbx + RR_len]
    call resolve
    cmp eax, -1
    je 71f
    test eax, eax
    jz 71f                      # not the root
    mov edi, eax
    call remove_ref
    jmp .Lpc_op
71: lea rdi, [rip + .Lo_del]
    jmp .Lpc_badpos_data
.Lpc_set:
    mov rdi, [rbx + RR_data]
    mov rsi, [rbx + RR_data]
    add rsi, [rbx + RR_len]
    call node_rec
    test rax, rax
    jz .Lpc_syntax
    mov rcx, [rbx + RR_data]
    add rcx, [rbx + RR_len]
    cmp rax, rcx
    jne .Lpc_syntax
    call nrec_check
    test eax, eax
    jz .Lpc_syntax
    mov rdi, [rip + nrec]
    mov rsi, [rip + nrec + 8]
    call resolve
    cmp eax, -1
    je 72f
    test eax, eax
    jz 72f
    mov [rsp + 8], eax
    mov edi, eax
    call nrec_bytes
    mov rsi, rax
    call ref_bytes
    mov eax, [rsp + 8]
    cmp qword ptr [rip + nrec + 48], KIDS_LEAF
    jne .Lpc_op
    mov edi, eax
    mov esi, -1                 # a leaf: its children go
    call remove_kids
    jmp .Lpc_op
72: lea rdi, [rip + .Lo_set]
    mov rsi, [rip + nrec]
    mov rdx, [rip + nrec + 8]
    call err_badpos
    jmp .Lpc_fail
.Lpc_kids:
    # kids|add PARENT_LEN N MORE LEN
    cmp qword ptr [rbx + RR_n], 5
    jne .Lpc_syntax
    mov rdi, rbx
    mov esi, 1
    call tree_rec_num
    test edx, edx
    jz .Lpc_syntax
    cmp rax, [rbx + RR_len]
    ja .Lpc_syntax
    mov [rsp + 24], rax         # parent's length
    mov rdi, rbx
    mov esi, 2
    call tree_rec_num
    test edx, edx
    jz .Lpc_syntax
    mov [rsp + 32], rax         # records
    mov rdi, rbx
    mov esi, 3
    call tree_rec_num
    test edx, edx
    jz .Lpc_syntax
    cmp rax, 1
    ja .Lpc_syntax
    mov rdi, [rbx + RR_data]
    mov rsi, [rsp + 24]
    call resolve
    cmp eax, -1
    jne 73f
    lea rdi, [rip + .Lo_kids]
    test r14d, r14d
    jnz 731f
    lea rdi, [rip + .Lo_add]
731:mov rsi, [rbx + RR_data]
    mov rdx, [rsp + 24]
    call err_badpos
    jmp .Lpc_fail
73: mov [rsp + 40], eax         # the parent's ref
    call tree_mark_new
    mov [rip + p_kmark], eax
    mov r15, [rbx + RR_data]
    add r15, [rsp + 24]         # q
.Lpc_rec:
    cmp qword ptr [rsp + 32], 0
    je .Lpc_recs_done
    dec qword ptr [rsp + 32]
    mov rdi, r15
    mov rsi, [rbx + RR_data]
    add rsi, [rbx + RR_len]
    call node_rec
    test rax, rax
    jz .Lpc_syntax
    mov r15, rax
    call nrec_check
    test eax, eax
    jz .Lpc_syntax
    mov rdi, [rip + nrec]
    mov rsi, [rip + nrec + 8]
    call resolve
    cmp eax, -1
    je .Lpc_new
    # it exists: under this parent, listed once (kids); add takes new ids only
    test r14d, r14d
    jz .Lpc_rec_bad
    mov [rsp + 8], eax
    mov edi, eax
    call ref_parent
    cmp eax, [rsp + 40]
    jne .Lpc_rec_bad
    mov edi, [rsp + 8]
    call ref_mark
    cmp eax, [rip + p_kmark]
    je .Lpc_rec_bad
    mov edi, [rsp + 8]
    mov esi, [rip + p_kmark]
    call set_mark
    mov edi, [rsp + 8]
    call nrec_bytes
    mov rsi, rax
    call ref_bytes
    cmp qword ptr [rip + nrec + 48], KIDS_LEAF
    jne .Lpc_rec
    mov edi, [rsp + 8]          # a leaf now: its children go
    mov esi, -1
    call remove_kids
    jmp .Lpc_rec
.Lpc_new:
    mov rdi, [rip + nrec]
    mov rsi, [rip + nrec + 8]
    mov edx, [rsp + 40]
    call ov_new
    or eax, OVF
    mov edi, eax
    call nrec_bytes
    mov rsi, rax
    call ref_bytes
    jmp .Lpc_rec
.Lpc_rec_bad:
    lea rdi, [rip + .Lo_kids]
    test r14d, r14d
    jnz 74f
    lea rdi, [rip + .Lo_add]
74: mov rsi, [rip + nrec]
    mov rdx, [rip + nrec + 8]
    call err_badpos
    jmp .Lpc_fail
.Lpc_recs_done:
    mov rax, [rbx + RR_data]
    add rax, [rbx + RR_len]
    cmp r15, rax
    jne .Lpc_syntax             # the records take the op's bytes exactly
    test r14d, r14d
    jz .Lpc_op
    mov edi, [rsp + 40]         # kids: the children not listed go
    mov esi, [rip + p_kmark]
    call remove_kids
    jmp .Lpc_op
.Lpc_badpos_data:
    mov rsi, [rbx + RR_data]
    mov rdx, [rbx + RR_len]
    call err_badpos
    jmp .Lpc_fail
.Lpc_end:
    cmp r12, r13
    jne .Lpc_syntax_end
    # the limits, from the counts
    mov rax, [rip + p_tree]
    mov rcx, [rax + TR_count]
    add rcx, [rip + p_created]
    sub rcx, [rip + p_removed]
    cmp rcx, TREE_NODES_MAX
    jg .Lpc_toobig
    mov rdx, [rip + g_rv_nodes]
    add rdx, [rip + p_created]
    sub rdx, [rip + p_removed]
    cmp rdx, NODES_ALL_MAX
    jg .Lpc_toobig
    # the bytes it leaves: kept, less what it replaces or removes, plus what it brings
    mov r14, [rax + TR_bytes]
    sub r14, [rip + p_freed]
    add r14, [rip + p_bytes]
    xor ebx, ebx
86: cmp rbx, [rip + ov + VEC_len]
    jae 87f
    mov edi, ebx
    call ov_alive
    test eax, eax
    jz 861f
    mov edi, ebx
    call ov_at
    mov eax, [rax + OV_bytes]
    add r14, rax
861:inc ebx
    jmp 86b
87: cmp r14, BYTES_MAX
    jg .Lpc_toobig
    mov rax, [rip + p_tree]
    mov rcx, [rip + g_rv_bytes]
    sub rcx, [rax + TR_bytes]
    add rcx, r14
    cmp rcx, BYTES_ALL_MAX
    jg .Lpc_toobig
    xor eax, eax
    EPILOGUE
.Lpc_syntax_end:
    inc qword ptr [rip + p_op]
.Lpc_syntax:
    call err_syntax
    mov eax, 1
    EPILOGUE
.Lpc_tree_ops_other_kind:
    # a tree op on another kind of view is noview; anything else unknown is skipped
    lea r14, [rip + tree_ops]
1:  mov rdx, [r14]
    test rdx, rdx
    jz .Lpc_op
    mov rdi, rbx
    xor esi, esi
    call tree_rec_is
    test eax, eax
    jnz .Lpc_kind
    add r14, 8
    jmp 1b
.Lpc_kind:
    lea rdi, [rip + .Le_noview_kind]
    call set_err
    mov eax, 1
    EPILOGUE
.Lpc_toobig_actions:
    lea rdi, [rip + .Le_toobig_actions]
    call set_err
    mov eax, 1
    EPILOGUE
.Lpc_toobig_form:
    lea rdi, [rip + .Le_toobig_form]
    call set_err
    mov eax, 1
    EPILOGUE
.Lpc_toobig_doc:
    lea rdi, [rip + .Le_toobig_doc]
    call set_err
    mov eax, 1
    EPILOGUE
.Lpc_toobig:
    lea rdi, [rip + .Le_toobig]
    call set_err
.Lpc_fail:
    mov eax, 1
    EPILOGUE

# form_op_count(rr) -> eax N for "form N LEN", -1 for "field LEN", -2 for neither, -3 for a form op
#   that cannot be read
form_op_count:
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_form]
    call tree_rec_is
    test eax, eax
    jz 2f
    cmp qword ptr [rbx + RR_n], 3
    jne 7f
    mov rdi, rbx
    mov esi, 1
    call tree_rec_num
    test edx, edx
    jz 7f
    EPILOGUE
2:  mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_field]
    call tree_rec_is
    test eax, eax
    jz 8f
    cmp qword ptr [rbx + RR_n], 2
    jne 7f
    mov eax, -1
    EPILOGUE
7:  mov eax, -3
    EPILOGUE
8:  mov eax, -2
    EPILOGUE

# check_log_op() -> eax 1 when rr is "log N LEN" with N lines "SEV TEXT" LF, SEV a severity word
check_log_op:
    PROLOGUE
    cmp qword ptr [rip + rr + RR_n], 3
    jne 8f
    lea rdi, [rip + rr]
    mov esi, 1
    call tree_rec_num
    test edx, edx
    jz 8f
    mov r15, rax                # lines
    mov r12, [rip + rr + RR_data]
    mov r13, r12
    add r13, [rip + rr + RR_len]
1:  cmp r12, r13
    jae 7f
    test r15, r15
    jz 8f                       # more lines than N
    dec r15
    mov rbx, r12                # the severity: up to a space
2:  cmp rbx, r13
    jae 8f
    cmp byte ptr [rbx], ' '
    je 3f
    cmp byte ptr [rbx], 10
    je 8f
    inc rbx
    jmp 2b
3:  mov rdi, r12
    mov rsi, rbx
    sub rsi, r12
    call log_sev_word
    test eax, eax
    jz 8f
4:  cmp rbx, r13                # the text: up to its LF
    jae 8f
    cmp byte ptr [rbx], 10
    je 5f
    inc rbx
    jmp 4b
5:  lea r12, [rbx + 1]
    jmp 1b
7:  test r15, r15
    jnz 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# check_action_op() -> eax 1 when rr is a good "action KEY ICON WHERE LEN" + TITLE, 0 a syntax
#   error, -1 when it would make more than 32 actions
check_action_op:
    PROLOGUE
    cmp qword ptr [rip + rr + RR_n], 5
    jne 8f
    mov rdi, [rip + rr + 16]    # KEY: [a-z0-9_]{1,40}
    mov rsi, [rip + rr + 24]
    call key_ok
    test eax, eax
    jz 8f
    call where_word
    cmp eax, -1
    je 8f
    mov ebx, eax
    cmp qword ptr [rip + rr + RR_len], 200
    ja 8f
    call data_one_line
    test eax, eax
    jz 8f
    mov rdi, [rip + rr + 16]    # against the keys as the ops before it leave them
    mov rsi, [rip + rr + 24]
    call akeys_find
    test ebx, ebx
    jnz 1f
    cmp eax, -1                 # none: the key goes (when it is there)
    je 7f
    mov ecx, [rip + p_actions]
    dec ecx
    mov [rip + p_actions], rcx
    lea rdx, [rip + p_akeys]    # the last one in its place
    shl rcx, 4
    mov r8, [rdx + rcx]
    mov r9, [rdx + rcx + 8]
    shl rax, 4
    mov [rdx + rax], r8
    mov [rdx + rax + 8], r9
    jmp 7f
1:  cmp eax, -1
    jne 7f                      # defined again: no more of them
    mov rcx, [rip + p_actions]
    cmp rcx, RA_MAX
    jae 6f
    lea rdx, [rip + p_akeys]
    shl rcx, 4
    mov rax, [rip + rr + 16]
    mov [rdx + rcx], rax
    mov rax, [rip + rr + 24]
    mov [rdx + rcx + 8], rax
    inc qword ptr [rip + p_actions]
    jmp 7f
6:  mov eax, -1
    EPILOGUE
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# akeys_init(RV*): the staged keys are its actions' keys
akeys_init:
    xor ecx, ecx
    lea rdx, [rip + p_akeys]
1:  cmp rcx, [rdi + RV_actions + VEC_len]
    jae 2f
    cmp ecx, RA_MAX
    jae 2f
    imul rax, rcx, RA_SIZE
    add rax, [rdi + RV_actions + VEC_ptr]
    mov r8, [rax + TA_key]
    mov [rdx], r8
    mov r8, [rax + TA_keylen]
    mov [rdx + 8], r8
    add rdx, 16
    inc ecx
    jmp 1b
2:  mov [rip + p_actions], rcx
    ret

# akeys_find(ptr, len) -> eax the staged key's index, or -1
akeys_find:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, [rip + p_actions]
    jae 8f
    mov rax, rbx
    shl rax, 4
    lea rcx, [rip + p_akeys]
    add rax, rcx
    cmp [rax + 8], r13
    jne 2f
    mov rdi, [rax]
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jz 2f
    mov eax, ebx
    EPILOGUE
2:  inc ebx
    jmp 1b
8:  mov eax, -1
    EPILOGUE

# key_ok(ptr, len) -> eax 1 for 1 to 40 bytes of [a-z0-9_]
key_ok:
    xor eax, eax
    test rsi, rsi
    jz 9f
    cmp rsi, 40
    ja 9f
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 8f
    movzx edx, byte ptr [rdi + rcx]
    inc rcx
    cmp edx, '_'
    je 1b
    lea r8d, [rdx - 'a']
    cmp r8d, 25
    jbe 1b
    lea r8d, [rdx - '0']
    cmp r8d, 9
    jbe 1b
    ret
8:  mov eax, 1
9:  ret

# where_word() -> eax RAW_TITLE, RAW_NODE, 0 for none (rr's fourth field), -1 for another word
where_word:
    lea rdi, [rip + rr]
    mov esi, 3
    lea rdx, [rip + .Lw_title]
    call tree_rec_is
    mov ecx, RAW_TITLE
    test eax, eax
    jnz 1f
    lea rdi, [rip + rr]
    mov esi, 3
    lea rdx, [rip + .Lw_node]
    call tree_rec_is
    mov ecx, RAW_NODE
    test eax, eax
    jnz 1f
    lea rdi, [rip + rr]
    mov esi, 3
    lea rdx, [rip + .Lw_none]
    call tree_rec_is
    xor ecx, ecx
    test eax, eax
    jnz 1f
    mov ecx, -1
1:  mov eax, ecx
    ret

# select_mode_word() -> eax 1 single, 2 multi (rr's second field), 0 another word
select_mode_word:
    lea rdi, [rip + rr]
    mov esi, 1
    lea rdx, [rip + .Lw_single]
    call tree_rec_is
    test eax, eax
    jnz 1f
    lea rdi, [rip + rr]
    mov esi, 1
    lea rdx, [rip + .Lw_multi]
    call tree_rec_is
    add eax, eax
1:  ret

# data_one_line() -> eax 1 when rr's bytes hold no LF and no NUL
data_one_line:
    mov rdi, [rip + rr + RR_data]
    mov rcx, [rip + rr + RR_len]
    mov esi, 10
    push rdi
    push rcx
    call has_byte
    pop rcx
    pop rdi
    test eax, eax
    jnz 8f
    xor esi, esi
    call has_byte
    xor eax, 1
    ret
8:  xor eax, eax
    ret

# state_word() -> eax RS_* for rr's second field, 0 when it is not a state
state_word:
    push rbx
    xor ebx, ebx
1:  lea rax, [rip + state_words]
    mov rdx, [rax + rbx*8]
    test rdx, rdx
    jz 8f
    lea rdi, [rip + rr]
    mov esi, 1
    call tree_rec_is
    test eax, eax
    jnz 2f
    inc ebx
    jmp 1b
2:  lea eax, [rbx + 1]
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret

# ---- applying ----

# apply_log_op(RV*): rr's lines appended to the log; a log given lines is ready
apply_log_op:
    PROLOGUE
    mov rbx, rdi
    mov dword ptr [rbx + RV_state], RS_READY
    mov r12, [rip + rr + RR_data]
    mov r13, r12
    add r13, [rip + rr + RR_len]
2:  cmp r12, r13
    jae 9f
    mov r14, r12
3:  cmp byte ptr [r14], ' '
    je 4f
    inc r14
    jmp 3b
4:  mov rdi, r12
    mov rsi, r14
    sub rsi, r12
    call log_sev_word
    lea r15d, [rax - 1]         # LS_*
    inc r14
    mov r12, r14
5:  cmp byte ptr [r14], 10
    je 6f
    inc r14
    jmp 5b
6:  mov rdi, [rbx + RV_log]
    mov esi, r15d
    mov rdx, r12
    mov rcx, r14
    sub rcx, r12
    call log_append
    lea r12, [r14 + 1]
    jmp 2b
9:  EPILOGUE

# take_text(slot*, ptr, len): the bytes as an owned cstr in the slot (len 0: none)
take_text:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [rbx]
    call mem_free
    xor eax, eax
    test r13, r13
    jz 1f
    mov rdi, r12
    mov rsi, r13
    call mem_dup
1:  mov [rbx], rax
    pop r13
    pop r12
    pop rbx
    ret

# check_columns_op() -> eax 1 when rr is "columns N LEN" with N (1-16) records "ALIGN WIDTH SORT
#   TITLE_LEN" LF + TITLE: ALIGN left or right, WIDTH 0-200, SORT sort or -, a one-line title of at
#   most 200 bytes
check_columns_op:
    PROLOGUE
    cmp qword ptr [rip + rr + RR_n], 3
    jne 8f
    lea rdi, [rip + rr]
    mov esi, 1
    call tree_rec_num
    test edx, edx
    jz 8f
    test rax, rax
    jz 8f
    cmp rax, TBC_MAX
    ja 8f
    mov r14d, eax               # records still to read
    mov r12, [rip + rr + RR_data]
    mov r13, r12
    add r13, [rip + rr + RR_len]
1:  test r14d, r14d
    jz 7f
    mov rdi, r12
    mov rsi, r13
    call column_rec
    test rax, rax
    jz 8f
    mov r12, rax
    dec r14d
    jmp 1b
7:  cmp r12, r13
    jne 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# column_rec(p, end) -> rax past the column record there, 0 when it is not one: its parts in col_*
column_rec:
    PROLOGUE
    lea rdx, [rip + rr2]
    call tree_rec_read
    test rax, rax
    jz 8f
    mov rbx, rax
    cmp qword ptr [rip + rr2 + RR_n], 4
    jne 8f
    mov dword ptr [rip + col_align], 0
    lea rdi, [rip + rr2]
    xor esi, esi
    lea rdx, [rip + .Lw_left]
    call tree_rec_is
    test eax, eax
    jnz 1f
    mov dword ptr [rip + col_align], 1
    lea rdi, [rip + rr2]
    xor esi, esi
    lea rdx, [rip + .Lw_right]
    call tree_rec_is
    test eax, eax
    jz 8f
1:  lea rdi, [rip + rr2]
    mov esi, 1
    call tree_rec_num
    test edx, edx
    jz 8f
    cmp rax, 200
    ja 8f
    mov [rip + col_min], eax
    mov dword ptr [rip + col_sort], 1
    lea rdi, [rip + rr2]
    mov esi, 2
    lea rdx, [rip + .Lw_sort]
    call tree_rec_is
    test eax, eax
    jnz 2f
    mov dword ptr [rip + col_sort], 0
    lea rdi, [rip + rr2]
    mov esi, 2
    lea rdx, [rip + .Ldash]
    call tree_rec_is
    test eax, eax
    jz 8f
2:  mov rcx, [rip + rr2 + RR_len]
    cmp rcx, 200
    ja 8f
    mov rdi, [rip + rr2 + RR_data]
    mov esi, 10
    call has_byte
    test eax, eax
    jnz 8f
    mov rdi, [rip + rr2 + RR_data]
    mov rcx, [rip + rr2 + RR_len]
    xor esi, esi
    call has_byte
    test eax, eax
    jnz 8f
    mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# apply_columns_op(tr): rr's columns (check_columns_op passed) become the table's
apply_columns_op:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + rr]
    mov esi, 1
    call tree_rec_num
    mov r15d, eax               # columns
    imul edi, eax, TBC_SIZE
    call mem_alloc
    mov r14, rax
    mov rdi, r14
    xor esi, esi
    imul edx, r15d, TBC_SIZE
    call memset
    mov r12, [rip + rr + RR_data]
    mov r13, r12
    add r13, [rip + rr + RR_len]
    xor ecx, ecx
1:  cmp ecx, r15d
    jae 2f
    push rcx
    push rcx
    mov rdi, r12
    mov rsi, r13
    call column_rec
    mov r12, rax
    mov rdi, [rip + rr2 + RR_data]
    mov rsi, [rip + rr2 + RR_len]
    call mem_dup
    pop rcx
    pop rcx
    imul edx, ecx, TBC_SIZE
    mov [r14 + rdx + TBC_title], rax
    mov eax, [rip + col_align]
    mov [r14 + rdx + TBC_align], eax
    mov eax, [rip + col_min]
    mov [r14 + rdx + TBC_min], eax
    mov eax, [rip + col_sort]
    mov [r14 + rdx + TBC_sort], eax
    inc ecx
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r14
    mov edx, r15d
    lea rcx, [rip + rv_sort]
    call tree_set_columns
    EPILOGUE

# sorted_args() -> eax COL | DESC << 8 for rr "sorted COL DIR 0" (COL 1-16 or - for none, DIR asc,
#   desc or -), -1 when it is not one
sorted_args:
    PROLOGUE
    cmp qword ptr [rip + rr + RR_n], 4
    jne 8f
    cmp qword ptr [rip + rr + RR_len], 0
    jne 8f
    xor r12d, r12d              # the column
    lea rdi, [rip + rr]
    mov esi, 1
    lea rdx, [rip + .Ldash]
    call tree_rec_is
    test eax, eax
    jnz 1f
    lea rdi, [rip + rr]
    mov esi, 1
    call tree_rec_num
    test edx, edx
    jz 8f
    test rax, rax
    jz 8f
    cmp rax, TBC_MAX
    ja 8f
    mov r12d, eax
1:  lea rdi, [rip + rr]
    mov esi, 2
    lea rdx, [rip + .Lw_desc]
    call tree_rec_is
    test eax, eax
    jz 2f
    or r12d, 1 << 8
    jmp 3f
2:  lea rdi, [rip + rr]
    mov esi, 2
    lea rdx, [rip + .Lw_asc]
    call tree_rec_is
    test eax, eax
    jnz 3f
    lea rdi, [rip + rr]
    mov esi, 2
    lea rdx, [rip + .Ldash]
    call tree_rec_is
    test eax, eax
    jz 8f
3:  mov eax, r12d
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# rv_sort(slot, tr, col, desc): a table's header was sorted while its children are paged: "sort REV
#   COL asc|desc"
rv_sort:
    PROLOGUE
    mov ebx, edi
    mov r12d, edx
    mov r13d, ecx
    call ev_head
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lev_sort]
    call ev_cstr
    mov edi, ebx
    call ev_rev
    call ev_sp
    mov edi, r12d
    call ev_u64
    call ev_sp
    lea rdi, [rip + .Lw_asc]
    test r13d, r13d
    jz 1f
    lea rdi, [rip + .Lw_desc]
1:  call ev_cstr
    mov edi, ebx
    xor esi, esi
    mov rdx, -1
    call ev_send
9:  EPILOGUE

# patch_apply(slot, body, len): every op, in order (patch_check passed)
patch_apply:
    PROLOGUE 48
    mov [rsp], edi
    mov r12, rsi
    lea r13, [rsi + rdx]
    call rv_at
    mov r14, rax                # RV*
    mov rax, [r14 + RV_tree]
    mov rcx, [rax + TR_count]
    sub [rip + g_rv_nodes], rcx
    mov rcx, [rax + TR_bytes]
    sub [rip + g_rv_bytes], rcx
    # past the count line
1:  cmp byte ptr [r12], 10
    je 2f
    inc r12
    jmp 1b
2:  inc r12
.Lpa_op:
    cmp r12, r13
    jae .Lpa_done
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + rr]
    call tree_rec_read
    test rax, rax
    jz .Lpa_done
    mov r12, rax
    lea rbx, [rip + rr]
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_title]
    call tree_rec_is
    test eax, eax
    jz 3f
    lea rdi, [r14 + RV_title]
    mov rsi, [rbx + RR_data]
    mov rdx, [rbx + RR_len]
    call take_text
    movsxd rdi, dword ptr [r14 + RV_decl]
    cmp rdi, -1
    je .Lpa_op
    call vd_at
    mov edi, [rax + VD_pl]
    mov rsi, [rbx + RR_data]
    mov rdx, [rbx + RR_len]
    test rdx, rdx
    jnz 21f
    mov rsi, [rax + VD_title]   # empty: the declared title again
    mov rdi, rsi
    push rax
    push rax
    call strlen
    mov rdx, rax
    pop rax
    pop rax
    mov rsi, [rax + VD_title]
    mov edi, [rax + VD_pl]
21: call place_set_title
    jmp .Lpa_op
3:  mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_message]
    call tree_rec_is
    test eax, eax
    jz 4f
    lea rdi, [r14 + RV_message]
    mov rsi, [rbx + RR_data]
    mov rdx, [rbx + RR_len]
    call take_text
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_op
4:  mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_badge]
    call tree_rec_is
    test eax, eax
    jz 5f
    mov rdi, rbx
    mov esi, 1
    call tree_rec_num
    mov [r14 + RV_badge], eax
    movsxd rdi, dword ptr [r14 + RV_decl]
    cmp rdi, -1
    je .Lpa_op
    mov r15d, eax
    call vd_at
    mov edi, [rax + VD_pl]
    mov esi, r15d
    call place_set_badge
    jmp .Lpa_op
5:  mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_busy]
    call tree_rec_is
    test eax, eax
    jz 6f
    mov rdi, rbx
    mov esi, 1
    call tree_rec_num
    mov [r14 + RV_busy], eax
    mov dword ptr [rip + g_dirty], 1
    movsxd rdi, dword ptr [r14 + RV_decl]
    cmp rdi, -1
    je .Lpa_op
    mov r15d, eax
    call vd_at
    mov edi, [rax + VD_pl]
    mov esi, r15d
    call place_set_busy
    jmp .Lpa_op
6:  mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_state]
    call tree_rec_is
    test eax, eax
    jz 7f
    call state_word
    mov [r14 + RV_state], eax
    mov rdi, rbx
    mov esi, 2
    call tree_rec_num
    mov r15, rax                # text bytes
    lea rdi, [r14 + RV_stext]
    mov rsi, [rbx + RR_data]
    mov rdx, r15
    call take_text
    lea rdi, [r14 + RV_skeys]
    mov rsi, [rbx + RR_data]
    add rsi, r15
    mov rdx, [rbx + RR_len]
    sub rdx, r15
    call take_text
    mov dword ptr [rip + g_dirty], 1
    jmp .Lpa_op
7:  cmp dword ptr [r14 + RV_kind], RK_DOC     # a doc's ops; given a document it is ready
    jne 704f
    mov rdi, rbx
    call mdview_check_op
    cmp eax, -1
    je 704f
    mov rdi, [r14 + RV_doc]
    mov rsi, rbx
    call mdview_apply_op
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_doc]
    call tree_rec_is
    test eax, eax
    jz .Lpa_op
    mov dword ptr [r14 + RV_state], RS_READY
    jmp .Lpa_op
704:mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_log]
    call tree_rec_is
    test eax, eax
    jz 701f
    mov rdi, r14
    call apply_log_op
    jmp .Lpa_op
701:mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_clear]
    call tree_rec_is
    test eax, eax
    jz 703f
    mov rdi, [r14 + RV_log]
    call log_clear
    jmp .Lpa_op
703:mov rdi, rbx                # form, field: the records into the form, which is ready then
    call form_op_count
    cmp eax, -2
    je 702f
    mov ecx, eax
    mov rdi, [r14 + RV_form]
    mov rsi, [rbx + RR_data]
    mov rdx, [rbx + RR_len]
    call form_apply
    mov dword ptr [r14 + RV_state], RS_READY
    jmp .Lpa_op
702:mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_action]
    call tree_rec_is
    test eax, eax
    jz 71f
    call where_word
    mov r9d, eax
    mov rax, [rbx + RR_data]
    push qword ptr [rbx + RR_len]
    push rax
    mov rdi, r14
    mov rsi, [rbx + 16]
    mov rdx, [rbx + 24]
    mov rcx, [rbx + 32]
    mov r8, [rbx + 40]
    call action_set
    add rsp, 16
    jmp .Lpa_op
71: mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_columns]
    call tree_rec_is
    test eax, eax
    jz 711f
    mov rdi, [r14 + RV_tree]
    call apply_columns_op
    jmp .Lpa_op
711:mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_sorted]
    call tree_rec_is
    test eax, eax
    jz 712f
    call sorted_args
    mov rdi, [r14 + RV_tree]
    mov esi, eax
    mov edx, eax
    shr edx, 8
    mov ecx, 1
    call tree_set_sorted
    jmp .Lpa_op
712:mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_select_mode]
    call tree_rec_is
    test eax, eax
    jz 72f
    call select_mode_word
    xor esi, esi
    cmp eax, 2
    sete sil
    mov rdi, [r14 + RV_tree]
    call tree_set_multi
    jmp .Lpa_op
72: mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_kids]
    call tree_rec_is
    test eax, eax
    jnz .Lpa_kids
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_add]
    call tree_rec_is
    test eax, eax
    jnz .Lpa_add
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_set]
    call tree_rec_is
    test eax, eax
    jnz .Lpa_set
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_del]
    call tree_rec_is
    test eax, eax
    jnz .Lpa_del
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_expand]
    call tree_rec_is
    mov r15d, 1
    test eax, eax
    jnz .Lpa_expand
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_collapse]
    call tree_rec_is
    xor r15d, r15d
    test eax, eax
    jnz .Lpa_expand
    jmp .Lpa_op
.Lpa_expand:
    mov rdi, [r14 + RV_tree]
    mov rsi, [rbx + RR_data]
    mov rdx, [rbx + RR_len]
    call tree_find
    mov rdi, [r14 + RV_tree]
    mov esi, eax
    mov edx, r15d
    call tree_expand
    jmp .Lpa_op
.Lpa_del:
    mov rdi, [r14 + RV_tree]
    mov rsi, [rbx + RR_data]
    mov rdx, [rbx + RR_len]
    call tree_find
    mov rdi, [r14 + RV_tree]
    mov esi, eax
    call tree_del
    jmp .Lpa_op
.Lpa_set:
    mov rdi, [rbx + RR_data]
    mov rsi, [rbx + RR_data]
    add rsi, [rbx + RR_len]
    call node_rec
    mov rdi, [r14 + RV_tree]
    mov rsi, [rip + nrec]
    mov rdx, [rip + nrec + 8]
    call tree_find
    mov rdi, [r14 + RV_tree]
    mov esi, eax
    mov rdx, [rip + nrec + 16]
    mov rcx, [rip + nrec + 24]
    mov r8d, [rip + nrec + 48]
    push qword ptr [rip + nrec + 40]
    push qword ptr [rip + nrec + 32]
    call tree_set
    add rsp, 16
    jmp .Lpa_op
.Lpa_add:
    mov r15d, 1                 # append
    jmp 8f
.Lpa_kids:
    xor r15d, r15d
8:  mov rdi, rbx
    mov esi, 1
    call tree_rec_num
    mov [rsp + 8], rax          # parent's length
    mov rdi, rbx
    mov esi, 2
    call tree_rec_num
    mov [rsp + 16], rax         # records
    mov rdi, rbx
    mov esi, 3
    call tree_rec_num
    mov [rsp + 24], eax         # more
    mov rdi, [r14 + RV_tree]
    mov rsi, [rbx + RR_data]
    mov rdx, [rsp + 8]
    call tree_find
    mov [rsp + 28], eax         # the parent
    test eax, eax
    jnz 81f
    test r15d, r15d
    jnz 81f
    mov dword ptr [r14 + RV_state], RS_READY    # the root's children: the tree shows, whatever the state was
81: mov rdi, [r14 + RV_tree]
    mov esi, eax
    test r15d, r15d
    jnz 82f
    call tree_kids_begin
    jmp 83f
82: call tree_add_begin
83: mov rax, [rbx + RR_data]
    add rax, [rsp + 8]
    mov [rsp + 32], rax         # q
84: cmp qword ptr [rsp + 16], 0
    je 85f
    dec qword ptr [rsp + 16]
    mov rdi, [rsp + 32]
    mov rsi, [rbx + RR_data]
    add rsi, [rbx + RR_len]
    call node_rec
    mov [rsp + 32], rax
    mov rdi, [r14 + RV_tree]
    mov rsi, [rip + nrec]
    mov rdx, [rip + nrec + 8]
    mov rcx, [rip + nrec + 16]
    mov r8, [rip + nrec + 24]
    mov r9d, [rip + nrec + 48]
    push qword ptr [rip + nrec + 40]
    push qword ptr [rip + nrec + 32]
    call tree_kid_x
    add rsp, 16
    jmp 84b
85: mov rdi, [r14 + RV_tree]
    mov esi, [rsp + 24]
    call tree_kids_end
    jmp .Lpa_op
.Lpa_done:
    cmp dword ptr [r14 + RV_kind], RK_TABLE     # a table rhun sorts keeps its order
    jne 1f
    mov rdi, [r14 + RV_tree]
    call tree_sort
1:  mov rax, [r14 + RV_tree]
    mov rcx, [rax + TR_count]
    add [rip + g_rv_nodes], rcx
    mov rcx, [rax + TR_bytes]
    add [rip + g_rv_bytes], rcx
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# rview_patch(ext, view, body, len) -> rax the instance's new REV, or -1 with the error text in
#   errbuf (rview_error): applied whole or not at all
FN rview_patch
    PROLOGUE
    mov r12, rdx
    mov r13, rcx
    call rv_find
    cmp eax, -1
    je 7f
    mov ebx, eax
    mov edi, eax
    call rv_at
    cmp dword ptr [rax + RV_kind], RK_TREE
    je 1f
    cmp dword ptr [rax + RV_kind], RK_TABLE
    je 1f
    cmp dword ptr [rax + RV_kind], RK_DOC
    je 1f
    cmp dword ptr [rax + RV_kind], RK_PICTURE   # its common ops (title, badge, message, busy...)
    je 1f
    cmp dword ptr [rax + RV_kind], RK_FORM
    je 1f
    cmp dword ptr [rax + RV_kind], RK_LOG
    jne 7f
1:  mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    call patch_check
    test eax, eax
    jnz 8f
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    call patch_apply
    mov edi, ebx
    call rv_at
    inc qword ptr [rax + RV_rev]
    mov rax, [rax + RV_rev]
    EPILOGUE
7:  lea rdi, [rip + .Le_noview]
    call set_err
8:  mov rax, -1
    EPILOGUE

# rview_error() -> rax the last failed patch's error text ("CODE TEXT")
FN rview_error
    lea rax, [rip + errbuf]
    ret

# rview_dump(sb, ext or 0): a line per instance: "view=ID kind=K place=P name=N rev=R state=S busy=B
#   title=T badge=N visible=V nodes=N"
FN rview_dump
    PROLOGUE 16
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12d, RV_MAX
    jae 9f
    mov edi, r12d
    call rv_at
    mov r13, rax
    cmp qword ptr [r13 + RV_ext], 0
    je 8f
    mov rdi, rbx
    lea rsi, [rip + .Ld_view]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + RV_view]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_kind]
    call sb_push_cstr
    mov eax, [r13 + RV_kind]
    lea rcx, [rip + kind_words]
    mov rsi, [rcx + rax*8 - 8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_place]
    call sb_push_cstr
    mov eax, [r13 + RV_place]
    lea rcx, [rip + place_words]
    mov rsi, [rcx + rax*8 - 8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_name]
    call sb_push_cstr
    lea rsi, [rip + .Ldash]
    movsxd rdi, dword ptr [r13 + RV_decl]
    cmp rdi, -1
    je 2f
    call vd_at
    mov rsi, [rax + VD_key]
2:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_rev]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r13 + RV_rev]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    lea rsi, [rip + .Ld_none]
    mov eax, [r13 + RV_state]
    test eax, eax
    jz 3f
    lea rcx, [rip + state_words]
    mov rsi, [rcx + rax*8 - 8]
3:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_busy]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + RV_busy]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_title]
    call sb_push_cstr
    mov rsi, [r13 + RV_title]
    test rsi, rsi
    jnz 4f
    lea rsi, [rip + .Ldash]
    movsxd rdi, dword ptr [r13 + RV_decl]
    cmp rdi, -1
    je 4f
    call vd_at
    mov rsi, [rax + VD_title]
4:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_badge]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + RV_badge]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_visible]
    call sb_push_cstr
    mov esi, [r13 + RV_vis]
    cmp esi, -1
    jne 5f
    xor esi, esi
5:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_nodes]
    call sb_push_cstr
    mov rax, [r13 + RV_tree]
    mov rsi, [rax + TR_count]
    mov rdi, rbx
    call sb_push_u64
    mov rax, [r13 + RV_message]
    test rax, rax
    jz 6f
    mov rdi, rbx
    lea rsi, [rip + .Ld_message]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r13 + RV_message]
    call sb_push_cstr
6:  cmp dword ptr [r13 + RV_prog], 0     # progress shown in it: " progress=PERCENT|-"
    je 61f
    mov rdi, rbx
    lea rsi, [rip + .Ld_progress]
    call sb_push_cstr
    mov esi, [r13 + RV_ppct]
    cmp esi, -1
    jne 62f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 61f
62: mov rdi, rbx
    call sb_push_u64
61: mov rdi, rbx
    mov esi, 10
    call sb_push_byte
8:  inc r12d
    jmp 1b
9:  xor r12d, r12d              # "titlebuttons NAME x=X w=W": the manifest view_title buttons drawn
91: cmp r12, [rip + vdecls + VEC_len]
    jae 99f
    mov rdi, r12
    call vd_at
    mov r13, rax
    cmp dword ptr [r13 + VD_mtw], 0
    je 92f
    mov rdi, rbx
    lea rsi, [rip + .Ld_titlebuttons]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r13 + VD_name]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_x]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + VD_mtx]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_w]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + VD_mtw]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
92: inc r12
    jmp 91b
99: EPILOGUE

# rview_tree_of(ptr, len) -> rax the TR* of the instance with that number, or of the declared view
#   with that key (KEY or OWNER/NAME.KEY), or 0 (tests)
FN rview_tree_of
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call parse_u64
    cmp rdx, r13
    jne 3f
    test rdx, rdx
    jz 3f
    mov r14d, eax
    xor ebx, ebx
1:  cmp ebx, RV_MAX
    jae 8f
    mov edi, ebx
    call rv_at
    cmp qword ptr [rax + RV_ext], 0
    je 2f
    cmp [rax + RV_view], r14d
    jne 2f
    mov rax, [rax + RV_tree]
    EPILOGUE
2:  inc ebx
    jmp 1b
3:  xor ebx, ebx
4:  cmp rbx, [rip + vdecls + VEC_len]
    jae 8f
    mov rdi, rbx
    call vd_at
    mov r14, rax
    cmp qword ptr [r14 + VD_ext], 0
    je 5f
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r14 + VD_key]
    call str_eq_cstr
    test eax, eax
    jnz 6f
    mov rdx, [r14 + VD_name]
    test rdx, rdx
    jz 5f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 6f
5:  inc rbx
    jmp 4b
6:  movsxd rdi, dword ptr [r14 + VD_rv]
    cmp rdi, -1
    je 8f
    call rv_at
    mov rax, [rax + RV_tree]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

.section .rodata
.Le_syntax_op: .asciz "syntax op "
.Le_badpos: .asciz "badpos "
.Le_toobig: .asciz "toobig nodes"
.Le_toobig_actions: .asciz "toobig actions"
.Le_noview_kind: .asciz "noview an op for another kind of view"
.Lo_log: .asciz "log"
.Lo_form: .asciz "form"
.Lo_field: .asciz "field"
.Le_toobig_form: .asciz "toobig form"
.Le_toobig_doc: .asciz "toobig doc"
.Lo_clear: .asciz "clear"
.Lo_action: .asciz "action"
.Lo_select_mode: .asciz "select-mode"
.Lo_columns: .asciz "columns"
.Lo_doc: .asciz "doc"
.Lo_sorted: .asciz "sorted"
.Lw_left: .asciz "left"
.Lw_right: .asciz "right"
.Lw_sort: .asciz "sort"
.Lw_asc: .asciz "asc"
.Lw_desc: .asciz "desc"
.Lev_sort: .asciz "sort"
.Lev_link: .asciz "link"
.Lw_title: .asciz "title"
.Lw_node: .asciz "node"
.Lw_none: .asciz "none"
.Lw_single: .asciz "single"
.Lw_multi: .asciz "multi"
.Le_noview: .asciz "noview"
.Lo_title: .asciz "title"
.Lo_message: .asciz "message"
.Lo_badge: .asciz "badge"
.Lo_busy: .asciz "busy"
.Lo_state: .asciz "state"
.Lo_kids: .asciz "kids"
.Lo_add: .asciz "add"
.Lo_set: .asciz "set"
.Lo_del: .asciz "del"
.Lo_expand: .asciz "expand"
.Lo_collapse: .asciz "collapse"
.Lw_leaf: .asciz "leaf"
.Lw_closed: .asciz "closed"
.Lw_open: .asciz "open"
.Ls_ready: .asciz "ready"
.Ls_loading: .asciz "loading"
.Ls_empty: .asciz "empty"
.Ls_error: .asciz "error"
.Ld_view: .asciz "view="
.Ld_kind: .asciz " kind="
.Ld_place: .asciz " place="
.Ld_name: .asciz " name="
.Ld_rev: .asciz " rev="
.Ld_state: .asciz " state="
.Ld_none: .asciz "none"
.Ld_busy: .asciz " busy="
.Ld_title: .asciz " title="
.Ld_badge: .asciz " badge="
.Ld_visible: .asciz " visible="
.Ld_progress: .asciz " progress="
.Ld_nodes: .asciz " nodes="
.Ld_message: .asciz " message="
.p2align 3
tree_ops: .quad .Lo_kids, .Lo_add, .Lo_set, .Lo_del, .Lo_expand, .Lo_collapse, .Lo_select_mode, .Lo_columns, .Lo_sorted, 0
state_words: .quad .Ls_ready, .Ls_loading, .Ls_empty, .Ls_error, 0     # RS_* - 1
nrec_slots: .quad 8, 24, 40     # nrec offsets of ID_LEN, LABEL_LEN, EXTRA_LEN

# ---------------- tab instances: vtab ----------------
.text

# rview_tab(ext, kind, kindlen, title, titlelen) -> rax the new view's number, -1 for a kind it
#   did not agree, -2 when it has 8 tabs and 12a views: a retained view in an editor tab of its
#   own, shown at once (its title at most 80 bytes)
FN rview_tab
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], rcx
    mov [rsp + 8], r8
    xor r14d, r14d              # the kind
1:  lea rax, [rip + kind_words]
    mov rdx, [rax + r14*8]
    test rdx, rdx
    jz 7f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r14d
    jmp 1b
2:  inc r14d                    # RK_*
    mov edi, r14d
    mov rsi, rbx
    call kind_agreed
    test eax, eax
    jz 7f
    # 8 tabs and 12a views at most
    mov rdi, rbx
    call extview_count
    mov r15d, eax
    xor ecx, ecx
3:  cmp ecx, RV_MAX
    jae 4f
    mov edi, ecx
    push rcx
    push rcx
    call rv_at
    pop rcx
    pop rcx
    inc ecx
    cmp [rax + RV_ext], rbx
    jne 3b
    cmp dword ptr [rax + RV_place], PLACE_TAB
    jne 3b
    inc r15d
    jmp 3b
4:  cmp r15d, VIEWS_PER_EXT
    jae 6f
    mov rdi, rbx
    mov esi, r14d
    mov edx, PLACE_TAB
    mov ecx, -1
    call rv_open
    cmp eax, -1
    je 6f
    mov r15d, eax
    # its title, its place item (for the keyboard), its tab
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov edx, TITLE_MAX
    xchg rdi, rsi
    call utf8_cut
    mov rsi, rax
    mov rdi, [rsp]
    call mem_dup
    mov r12, rax
    mov edi, r15d
    call rv_at
    mov [rax + RV_title], r12
    mov rdi, rbx
    call ext_full_name
    lea rdi, [rip + evbuf]
    mov rsi, rax
    call rv_tab_name
    mov edi, PLACE_TAB
    lea rsi, [rip + evbuf]
    mov rsi, [rsi + SB_ptr]
    mov rdx, r12
    lea rcx, [rip + rv_tab_ops]
    mov r8d, r15d
    call place_add
    mov r12d, eax
    mov edi, r15d
    call rv_at
    mov [rax + RV_pl], r12d
    xor edi, edi
    mov esi, TAB_VIEW
    call app_add_tab
    mov rdi, rax
    call tab_at
    lea rcx, [r15 + 1]
    shl rcx, TF_VIEW_SHIFT
    or rcx, TF_RVIEW
    or [rax + TAB_flags], rcx
    # app_add_tab activated it before the retained-view flags existed. Give the new
    # view the keyboard now, so Tab and Enter work without an extra pointer click.
    mov edi, r12d
    call place_focus
    mov edi, r15d
    call send_open
    mov edi, r15d
    call rv_at
    mov eax, [rax + RV_view]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
6:  mov rax, -2
    EPILOGUE
7:  mov rax, -1
    EPILOGUE

# rv_tab_name(sb, full name cstr): "OWNER/NAME.tab" into the buffer, NUL-ended
rv_tab_name:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ltab_suffix]
    call sb_push_cstr
    add rsp, 8
    pop r12
    pop rbx
    ret

# rv_of_tab(tab flags) -> eax the tab instance's slot, or -1
FN rv_of_tab
    mov eax, -1
    test rdi, TF_RVIEW
    jz 9f
    mov rcx, rdi
    shr rcx, TF_VIEW_SHIFT
    and ecx, 255
    jz 9f
    dec ecx
    cmp ecx, RV_MAX
    jae 9f
    imul rdx, rcx, RV_SIZE
    lea r8, [rip + rv_slots]
    cmp qword ptr [r8 + rdx + RV_ext], 0
    je 9f
    mov eax, ecx
9:  ret

# rview_tab_title(tab flags) -> rax cstr for the tab strip
FN rview_tab_title
    call rv_of_tab
    cmp eax, -1
    je 1f
    mov edi, eax
    call rv_at
    mov rax, [rax + RV_title]
    test rax, rax
    jnz 2f
1:  lea rax, [rip + .Ltab_title]
2:  ret

# rview_tab_draw(tab flags, x, y, w, h): its body in the editor's place
FN rview_tab_draw
    PROLOGUE 16
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    call rv_of_tab
    cmp eax, -1
    je 9f
    mov edi, eax
    call rv_at
    mov edi, [rax + RV_pl]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call place_body
9:  EPILOGUE

# rview_tab_closed(tab flags): its tab is closing: "closed" unless the extension closed it, and the
#   instance ends
FN rview_tab_closed
    PROLOGUE
    call rv_of_tab
    cmp eax, -1
    je 9f
    mov ebx, eax
    mov edi, ebx
    call rv_at
    cmp dword ptr [rax + RV_tabclosing], 0
    jne 1f
    mov edi, ebx
    call ev_head
    test eax, eax
    jz 1f
    lea rdi, [rip + .Lev_closed]
    call ev_cstr
    mov edi, ebx
    xor esi, esi
    mov rdx, -1
    call ev_send
1:  mov edi, ebx
    call rv_close
9:  EPILOGUE

# rv_close_tab(slot): the extension or its end closes a tab instance (no event)
rv_close_tab:
    PROLOGUE
    mov ebx, edi
    call rv_at
    mov dword ptr [rax + RV_tabclosing], 1
    lea r12, [rbx + 1]
    shl r12, TF_VIEW_SHIFT
    or r12, TF_RVIEW
    xor r13d, r13d
1:  cmp r13, [rip + g_tabs + VEC_len]
    jae 8f
    mov rdi, r13
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_VIEW
    jne 2f
    mov rcx, [rax + TAB_flags]
    and rcx, (255 << TF_VIEW_SHIFT) | TF_RVIEW
    cmp rcx, r12
    jne 2f
    mov rdi, r13
    call app_close_tab_now      # rview_tab_closed ends the instance
    EPILOGUE
2:  inc r13
    jmp 1b
8:  mov edi, ebx
    call rv_close
    EPILOGUE

# rview_unview(ext, view) -> eax 0 closed, 1 no such view, 2 a declared view (the user hides those)
FN rview_unview
    PROLOGUE
    call rv_find
    cmp eax, -1
    je 7f
    mov ebx, eax
    mov edi, eax
    call rv_at
    cmp dword ptr [rax + RV_place], PLACE_TAB
    jne 8f
    mov edi, ebx
    call rv_close_tab
    xor eax, eax
    EPILOGUE
7:  mov eax, 1
    EPILOGUE
8:  mov eax, 2
    EPILOGUE

# rv_tab_* : a tab instance's place callbacks (ctx: its slot)
rv_tab_draw_cb:
    jmp rv_instance_draw
rv_tab_key_cb:
    jmp rv_instance_key
rv_tab_focus_cb:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    call rv_at
    mov rdi, [rax + RV_ext]
    call ext_full_name
    lea rdi, [rip + idsbuf]
    mov rsi, rax
    call rv_tab_name
    mov edi, ebx
    mov esi, r12d
    mov rdx, [rip + idsbuf + SB_ptr]
    call rv_focus_event
    pop r13
    pop r12
    pop rbx
    ret
rv_tab_visible_cb:
    jmp send_visible

# views_field() -> rax the text field of the view that has the keyboard (a log's find field), or 0
FN views_field
    push rbx
    call place_focused
    mov edi, eax
    call place_at
    test rax, rax
    jz 8f
    mov rcx, [rax + PL_ops]
    lea rdx, [rip + rv_place_ops]
    cmp rcx, rdx
    je 1f
    lea rdx, [rip + rv_tab_ops]
    cmp rcx, rdx
    jne 8f
    mov edi, [rax + PL_ctx]     # a tab: its slot
    jmp 2f
1:  mov rdi, [rax + PL_ctx]     # a declared view: its instance
    call rv_of_vd
    cmp eax, -1
    je 8f
    mov edi, eax
2:  call rv_at
    cmp qword ptr [rax + RV_ext], 0
    je 8f
    cmp dword ptr [rax + RV_kind], RK_FORM
    je 3f
    cmp dword ptr [rax + RV_kind], RK_LOG
    jne 8f
    mov rdi, [rax + RV_log]
    call log_field
    pop rbx
    ret
3:  mov rdi, [rax + RV_form]
    call form_field
    pop rbx
    ret
8:  pop rbx
    jmp dview_console_field     # debugger: the Debug Console's input (debugview.s), or 0

# rview_docs_frame_end(): a doc view following the active document whose top line moved after the
#   view was drawn asks for one more frame
FN rview_docs_frame_end
    PROLOGUE
    xor ebx, ebx
1:  cmp ebx, RV_MAX
    jae 9f
    mov edi, ebx
    call rv_at
    cmp qword ptr [rax + RV_ext], 0
    je 2f
    cmp dword ptr [rax + RV_kind], RK_DOC
    jne 2f
    cmp dword ptr [rax + RV_vis], 1     # shown: a hidden view catches up when shown
    jne 2f
    mov rdi, [rax + RV_doc]
    test rdi, rdi
    jz 2f
    call mdview_follow_due
    test eax, eax
    jz 2f
    mov dword ptr [rip + g_dirty], 1
2:  inc ebx
    jmp 1b
9:  EPILOGUE

# rview_link_event(slot, ptr, len): a doc view's link rhun does not follow: "link REV LEN" + target
FN rview_link_event
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    call ev_head
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lev_link]
    call ev_cstr
    mov edi, ebx
    call ev_rev
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    call ev_send
9:  EPILOGUE

# focused_rv() -> rax the instance (RV*) whose place item or tab has the keyboard, or 0
focused_rv:
    push rbx
    call place_focused
    mov edi, eax
    call place_at
    test rax, rax
    jz 8f
    mov rcx, [rax + PL_ops]
    lea rdx, [rip + rv_place_ops]
    cmp rcx, rdx
    je 1f
    lea rdx, [rip + rv_tab_ops]
    cmp rcx, rdx
    jne 8f
    mov edi, [rax + PL_ctx]     # a tab: its slot
    jmp 2f
1:  mov rdi, [rax + PL_ctx]     # a declared view: its instance
    call rv_of_vd
    cmp eax, -1
    je 8f
    mov edi, eax
2:  call rv_at
    cmp qword ptr [rax + RV_ext], 0
    je 8f
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret

# rview_focused_doc() -> rax the state of the doc view with the keyboard, or 0
FN rview_focused_doc
    sub rsp, 8
    call focused_rv
    add rsp, 8
    test rax, rax
    jz 9f
    cmp dword ptr [rax + RV_kind], RK_DOC
    jne 8f
    mov rax, [rax + RV_doc]
    ret
8:  xor eax, eax
9:  ret

# rview_focused_form() -> rax the form of the form view with the keyboard, or 0
FN rview_focused_form
    sub rsp, 8
    call focused_rv
    add rsp, 8
    test rax, rax
    jz 9f
    cmp dword ptr [rax + RV_kind], RK_FORM
    jne 8f
    mov rax, [rax + RV_form]
    ret
8:  xor eax, eax
9:  ret

# rview_form_event(slot, what cstr, key cstr, seq or -1, body, len): "0 view VIEW WHAT REV KEY",
#   with a sequence " SEQ LEN" and the body (change); without: nothing more (press, submit)
FN rview_form_event
    PROLOGUE 16
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8
    mov [rsp + 8], r9
    mov edi, ebx
    call ev_head
    test eax, eax
    jz 9f
    mov rdi, r12
    call ev_cstr
    call ev_sp
    mov edi, ebx
    call rv_at
    mov rdi, [rax + RV_rev]
    call ev_u64
    call ev_sp
    mov rdi, r13
    call ev_cstr
    cmp r14, -1
    je 1f
    call ev_sp
    mov rdi, r14
    call ev_u64
    mov edi, ebx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call ev_send
    EPILOGUE
1:  mov edi, ebx
    xor esi, esi
    mov rdx, -1
    call ev_send
9:  EPILOGUE

# rview_form_of(ptr, len) -> rax the form of a form view named so (key or number), or 0
FN rview_form_of
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call parse_u64
    cmp rdx, r13
    jne 3f
    test rdx, rdx
    jz 3f
    mov r14d, eax
    xor ebx, ebx
1:  cmp ebx, RV_MAX
    jae 8f
    mov edi, ebx
    call rv_at
    cmp qword ptr [rax + RV_ext], 0
    je 2f
    cmp [rax + RV_view], r14d
    jne 2f
    mov rax, [rax + RV_form]
    EPILOGUE
2:  inc ebx
    jmp 1b
3:  xor ebx, ebx
4:  cmp rbx, [rip + vdecls + VEC_len]
    jae 8f
    mov rdi, rbx
    call vd_at
    mov r14, rax
    cmp qword ptr [r14 + VD_ext], 0
    je 5f
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r14 + VD_key]
    call str_eq_cstr
    test eax, eax
    jnz 6f
5:  inc rbx
    jmp 4b
6:  movsxd rdi, dword ptr [r14 + VD_rv]
    cmp rdi, -1
    je 8f
    call rv_at
    mov rax, [rax + RV_form]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# rview_doc_of(ptr, len) -> rax the doc view state named so (key or number), or 0
FN rview_doc_of
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call parse_u64
    cmp rdx, r13
    jne 3f
    test rdx, rdx
    jz 3f
    mov r14d, eax
    xor ebx, ebx
1:  cmp ebx, RV_MAX
    jae 8f
    mov edi, ebx
    call rv_at
    cmp qword ptr [rax + RV_ext], 0
    je 2f
    cmp [rax + RV_view], r14d
    jne 2f
    mov rax, [rax + RV_doc]
    EPILOGUE
2:  inc ebx
    jmp 1b
3:  xor ebx, ebx
4:  cmp rbx, [rip + vdecls + VEC_len]
    jae 8f
    mov rdi, rbx
    call vd_at
    mov r14, rax
    cmp qword ptr [r14 + VD_ext], 0
    je 5f
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r14 + VD_key]
    call str_eq_cstr
    test eax, eax
    jnz 6f
5:  inc rbx
    jmp 4b
6:  movsxd rdi, dword ptr [r14 + VD_rv]
    cmp rdi, -1
    je 8f
    call rv_at
    mov rax, [rax + RV_doc]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# rview_log_of(ptr, len) -> rax the LG* of a log view named so (key, place name or number), or 0
FN rview_log_of
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call parse_u64
    cmp rdx, r13
    jne 3f
    test rdx, rdx
    jz 3f
    mov r14d, eax
    xor ebx, ebx
1:  cmp ebx, RV_MAX
    jae 8f
    mov edi, ebx
    call rv_at
    cmp qword ptr [rax + RV_ext], 0
    je 2f
    cmp [rax + RV_view], r14d
    jne 2f
    mov rax, [rax + RV_log]
    EPILOGUE
2:  inc ebx
    jmp 1b
3:  xor ebx, ebx
4:  cmp rbx, [rip + vdecls + VEC_len]
    jae 8f
    mov rdi, rbx
    call vd_at
    mov r14, rax
    cmp qword ptr [r14 + VD_ext], 0
    je 5f
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r14 + VD_key]
    call str_eq_cstr
    test eax, eax
    jnz 6f
5:  inc rbx
    jmp 4b
6:  movsxd rdi, dword ptr [r14 + VD_rv]
    cmp rdi, -1
    je 8f
    call rv_at
    mov rax, [rax + RV_log]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

.section .rodata
.Ltab_suffix: .asciz ".tab"
.Ltab_title: .asciz "View"
.Lev_closed: .asciz "closed"
.p2align 3
rv_tab_ops: .quad rv_tab_draw_cb, rv_tab_key_cb, rv_tab_focus_cb, 0, 0, rv_tab_visible_cb
