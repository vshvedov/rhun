# A Markdown document of rhun's own in an editor tab (TAB_MDDOC): the plan a driver asks to review, or one it
# shows. markdown.s lays it out in the interface's faces, as an editor tab's (rdoc.s's mdview_draw is the
# model): dragging selects text, Ctrl+C copies it, Ctrl+A selects it all, the wheel, the scrollbar and the
# keys (arrows, Page Up/Down, Space, Home, End) scroll, Tab and Shift+Tab move between links, Enter follows
# one. A web link asks before it opens (links_ask_open, "This document"); "#slug" scrolls to its heading;
# others are not followed. It is not a document: never saved, not in the session, not reopened.
#
# Its owner (MDO, rhun.inc) may take comments: with a selection a **Comment** button shows at the end of the
# selection's last line (Ctrl+Enter does the same); it copies the selected text at once (md_sel_text) and
# opens the palette's prompt PROMPT_MD_COMMENT "Comment on the selection"; Enter there gives the owner
# MDO_comment(ctx, quote, text) -> eax 1 taken (refused: the selection stays), Escape drops it. Closing the
# tab tells the owner (MDO_closed); the owner dropping it (mdtab_drop) closes the tab and a comment prompt
# open for it, and tells it nothing.
#
#   mdtab_open(title cstr, ptr, len, MDO* or 0, ctx) -> rax its tab's index, -1 none (MT_MAX are open)
#     ctx (not 0) names the owner's tab: opened again it is shown; without an owner, a tab of the same
#     title and no owner shows the new text. It is shown at once unless the keyboard is in a text
#     document (the user may be typing there): then it waits behind the active tab. The keyboard stays
#     where it was either way.
#   mdtab_drop(ctx)                     its tab and its prompt close
#   mdtab_tab_closed(tab flags)         app_close_tab_now's part
#   mdtab_label(tab flags) -> rax cstr  app_tab_label's
#   mdtab_draw(tab index, x, y, w, h)   center_draw's
#   mdtab_key(keysym, cp, mods) -> eax 1 taken (app_on_key, the editor's focus, the tab active)
#   mdtab_clip(kind 0 copy, 1 cut, 2 select all) -> eax 1 taken (views_clip_command)
#   mdtab_prompt_done(ptr, len)         the comment prompt's Enter (palette.s)
#   mdtab_select(ptr, len) -> eax 1, mdtab_comment(ptr, len) -> eax 1 done, 0 nothing selected, -1 no
#     comments; mdtab_dump(sb)          headless (mdtab-select, mdtab-comment, print-mdtab): the active
#     Markdown tab, else the newest
.include "rhun.inc"

.equ MT_MAX, 8
.equ MT_SHIFT, 16               # TAB_flags >> MT_SHIFT: its slot + 1 (TAB_VIEW's way)
.equ ID_MDT_AREA, ID_MDTAB + 0xffe
.equ ID_MDT_COMMENT, ID_MDTAB + 0xffd
.equ ID_MDT_BAR, ID_MDTAB + 0xfff

STRUCT
F MT_md, 8              # MD*
F MT_title, 8           # owned cstr
F MT_mdo, 8             # MDO* or 0
F MT_ctx, 8
F MT_used, 4
F MT_scroll, 4
F MT_h, 4               # the content's height, laid out
F MT_vh, 4              # the view's, last drawn
F MT_w, 4               # the width it was laid out at, 0 never
F MT_seq, 4             # the order they were opened in
ENDSTRUCT MT_SIZE

.bss
.p2align 3
mts: .zero MT_SIZE * MT_MAX
cm_sb: .zero SB_SIZE            # the quote a Comment took
cm_ctx: .quad 0
cm_slot1: .long 0               # its tab's slot + 1, 0 none
mt_seq: .long 0
pend_comment: .long 0           # the Comment button was clicked this frame (its slot + 1)
pend_link: .long 0              # a link was clicked this frame (its index + 1)
pend_slot: .long 0

.text

# slot_ptr(slot) -> rax its MT
slot_ptr:
    movsxd rax, edi
    imul rax, rax, MT_SIZE
    lea rcx, [rip + mts]
    add rax, rcx
    ret

# flags_slot(TAB_flags) -> eax its slot, -1 none
flags_slot:
    mov rax, rdi
    shr rax, MT_SHIFT
    dec eax
    js 8f
    cmp eax, MT_MAX
    jae 8f
    push rax
    mov edi, eax
    call slot_ptr
    mov ecx, [rax + MT_used]
    pop rax
    test ecx, ecx
    jz 8f
    ret
8:  mov eax, -1
    ret

# slot_tab(slot) -> rax the index of its tab, -1 none
slot_tab:
    lea edx, [rdi + 1]
    xor ecx, ecx
1:  cmp rcx, [rip + g_tabs + VEC_len]
    jae 8f
    imul rax, rcx, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    cmp qword ptr [rax + TAB_kind], TAB_MDDOC
    jne 2f
    mov rax, [rax + TAB_flags]
    shr rax, MT_SHIFT
    cmp eax, edx
    je 3f
2:  inc rcx
    jmp 1b
3:  mov rax, rcx
    ret
8:  mov rax, -1
    ret

# cur_slot() -> eax the active tab's slot when it is a Markdown tab, else -1
cur_slot:
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 8f
    cmp rdi, [rip + g_tabs + VEC_len]
    jae 8f
    imul rax, rdi, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    cmp qword ptr [rax + TAB_kind], TAB_MDDOC
    jne 8f
    mov rdi, [rax + TAB_flags]
    jmp flags_slot
8:  mov eax, -1
    ret

# target_slot() -> eax the active Markdown tab's slot, else the newest one's, -1 none
target_slot:
    call cur_slot
    test eax, eax
    jns 9f
    mov edx, -1                 # the best slot
    xor r8d, r8d                # its order
    xor ecx, ecx
1:  cmp ecx, MT_MAX
    jae 8f
    movsxd rax, ecx
    imul rax, rax, MT_SIZE
    lea r9, [rip + mts]
    add rax, r9
    cmp dword ptr [rax + MT_used], 0
    je 2f
    mov eax, [rax + MT_seq]
    cmp eax, r8d
    jbe 2f
    mov r8d, eax
    mov edx, ecx
2:  inc ecx
    jmp 1b
8:  mov eax, edx
9:  ret

# show_tab(index): the tab active; the keyboard stays where it was, but in another editor tab's own field
#   (Settings, Find, the Extensions page's search), which is the editor's then
show_tab:
    PROLOGUE
    mov ebx, [rip + g_focus]
    call app_activate_tab
    cmp ebx, FOCUS_SETTINGS
    je 9f
    cmp ebx, FOCUS_FIND
    je 9f
    cmp ebx, FOCUS_EXT_SEARCH
    je 9f
    mov [rip + g_focus], ebx
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# in_text() -> eax 1 when the keyboard is in a text document (the editor's focus on a document's tab)
in_text:
    xor eax, eax
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 1f
    cmp qword ptr [rip + g_doc], 0
    setne al
1:  ret

# FN mdtab_open(title cstr, ptr, len, MDO* or 0, ctx) -> rax its tab's index, or -1 (see the top)
FN mdtab_open
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    xor ecx, ecx                # one open already: the owner's, or the same title's without an owner
1:  cmp ecx, MT_MAX
    jae 4f
    mov [rsp], ecx
    mov edi, ecx
    call slot_ptr
    cmp dword ptr [rax + MT_used], 0
    je 3f
    test r15, r15
    jz 2f
    cmp [rax + MT_ctx], r15
    je .Lmo_show
    jmp 3f
2:  test r14, r14
    jnz 3f
    cmp qword ptr [rax + MT_mdo], 0
    jne 3f
    cmp qword ptr [rax + MT_ctx], 0
    jne 3f
    push rax
    push rax
    mov rdi, [rax + MT_title]
    mov rsi, rbx
    call strcmp_eq
    pop rcx
    pop rcx
    test eax, eax
    jz 3f
    push rcx                    # the new text in it
    push rcx
    mov rdi, [rcx + MT_md]
    call md_free
    mov rdi, r12
    mov rsi, r13
    call md_new
    pop rcx
    pop rcx
    mov [rcx + MT_md], rax
    mov dword ptr [rcx + MT_scroll], 0
    mov dword ptr [rcx + MT_w], 0
    jmp .Lmo_show
3:  mov ecx, [rsp]
    inc ecx
    jmp 1b
.Lmo_show:
    mov edi, [rsp]
    call slot_tab
    test rax, rax
    js 9f
    mov r12, rax
    call in_text
    test eax, eax
    jnz 31f
    mov rdi, r12
    call show_tab
31: mov rax, r12
    EPILOGUE
4:  xor ecx, ecx                # a free slot
5:  cmp ecx, MT_MAX
    jae 9f
    mov [rsp], ecx
    mov edi, ecx
    call slot_ptr
    cmp dword ptr [rax + MT_used], 0
    je 6f
    mov ecx, [rsp]
    inc ecx
    jmp 5b
6:  mov [rsp + 8], rax
    mov rdi, rax
    xor esi, esi
    mov edx, MT_SIZE
    call memset
    mov rdi, r12
    mov rsi, r13
    call md_new
    mov rcx, [rsp + 8]
    mov [rcx + MT_md], rax
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov rcx, [rsp + 8]
    mov [rcx + MT_title], rax
    mov [rcx + MT_mdo], r14
    mov [rcx + MT_ctx], r15
    mov dword ptr [rcx + MT_used], 1
    inc dword ptr [rip + mt_seq]
    mov eax, [rip + mt_seq]
    mov [rcx + MT_seq], eax
    # its tab, after the active one (after the pinned ones)
    lea rdi, [rip + g_tabs]
    mov esi, TAB_SIZE
    call vec_push               # zeroed: not pinned
    mov qword ptr [rax + TAB_kind], TAB_MDDOC
    mov qword ptr [rax + TAB_doc], 0
    mov ecx, [rsp]
    inc ecx
    shl rcx, MT_SHIFT
    mov [rax + TAB_flags], rcx
    mov r13, [rip + g_tabs + VEC_len]
    dec r13
    mov r14, [rip + g_tab_cur]
    inc r14
    call tabs_pinned
    cmp r14, rax
    cmovb r14, rax
    mov rdi, r13
    mov rsi, r14
    call tab_move
    call in_text
    test eax, eax
    jnz 7f
    mov rdi, r14
    call show_tab
7:  mov dword ptr [rip + g_dirty], 1
    mov rax, r14
    EPILOGUE
9:  mov rax, -1
    EPILOGUE

# prompt_drop(slot): the comment prompt taken for that slot goes (the palette closes when it shows it)
prompt_drop:
    PROLOGUE
    lea eax, [rdi + 1]
    cmp eax, [rip + cm_slot1]
    jne 9f
    mov dword ptr [rip + cm_slot1], 0
    call palette_prompt_kind
    cmp eax, PROMPT_MD_COMMENT
    jne 9f
    call palette_close
9:  EPILOGUE

# slot_free(slot): its document and title, the slot empty
slot_free:
    PROLOGUE
    call slot_ptr
    mov rbx, rax
    mov rdi, [rbx + MT_md]
    call md_free
    mov rdi, [rbx + MT_title]
    call mem_free
    mov rdi, rbx
    xor esi, esi
    mov edx, MT_SIZE
    call memset
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN mdtab_drop(ctx): the owner's tabs close (the owner is not told) and a comment prompt open for them
FN mdtab_drop
    PROLOGUE
    mov r12, rdi
    test r12, r12
    jz 9f
    xor ebx, ebx
1:  cmp ebx, MT_MAX
    jae 9f
    mov edi, ebx
    call slot_ptr
    cmp dword ptr [rax + MT_used], 0
    je 3f
    cmp [rax + MT_ctx], r12
    jne 3f
    mov qword ptr [rax + MT_mdo], 0
    mov edi, ebx
    call prompt_drop
    mov edi, ebx
    call slot_tab
    test rax, rax
    js 2f
    mov rdi, rax
    call app_close_tab_now      # (mdtab_tab_closed frees the slot)
    jmp 3f
2:  mov edi, ebx
    call slot_free
3:  inc ebx
    jmp 1b
9:  EPILOGUE

# FN mdtab_tab_closed(tab flags): its tab closes: its prompt goes, its owner hears it, the slot is freed
FN mdtab_tab_closed
    PROLOGUE
    call flags_slot
    test eax, eax
    js 9f
    mov ebx, eax
    mov edi, eax
    call prompt_drop
    mov edi, ebx
    call slot_ptr
    mov r12, [rax + MT_mdo]
    mov r13, [rax + MT_ctx]
    mov edi, ebx
    call slot_free
    test r12, r12
    jz 9f
    mov rax, [r12 + MDO_closed]
    test rax, rax
    jz 9f
    mov rdi, r13
    call rax
9:  EPILOGUE

# FN mdtab_label(tab flags) -> rax the tab's title
FN mdtab_label
    push rbx
    call flags_slot
    test eax, eax
    js 1f
    mov edi, eax
    call slot_ptr
    mov rax, [rax + MT_title]
    pop rbx
    ret
1:  lea rax, [rip + .Lmd_untitled]
    pop rbx
    ret

# clamp(MT*): the scroll within the content
clamp:
    mov eax, [rdi + MT_h]
    sub eax, [rdi + MT_vh]
    jns 1f
    xor eax, eax
1:  cmp [rdi + MT_scroll], eax
    jle 2f
    mov [rdi + MT_scroll], eax
2:  cmp dword ptr [rdi + MT_scroll], 0
    jge 9f
    mov dword ptr [rdi + MT_scroll], 0
9:  ret

# takes_comments(MT*) -> eax 1 when its owner takes comments
takes_comments:
    xor eax, eax
    mov rcx, [rdi + MT_mdo]
    test rcx, rcx
    jz 1f
    cmp qword ptr [rcx + MDO_comment], 0
    setne al
1:  ret

# FN mdtab_draw(tab index, x, y, w, h): the document with a margin, scrolled; the Comment button after the
#   selection's last line; a link clicked and the button are acted on after the drawing. Locals: [rsp] x, +4 y, +8 w,
#   +12 h, +16 the text's width, +20 the area's UB bits, +24 the button shows, +28..+40 its x, y, w, h, +44
#   the pointer is over it
FN mdtab_draw
    PROLOGUE 48
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov dword ptr [rsp + 24], 0
    mov dword ptr [rsp + 44], 0
    mov dword ptr [rip + pend_comment], 0
    mov dword ptr [rip + pend_link], 0
    call tab_at
    mov rdi, [rax + TAB_flags]
    call flags_slot
    test eax, eax
    js 9f
    mov [rip + pend_slot], eax
    mov edi, eax
    call slot_ptr
    mov rbx, rax
    mov r12, [rbx + MT_md]
    mov edi, [rsp]              # the editor's background
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    COLOR r8d, T_BG
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    mov eax, [rsp + 12]
    mov [rbx + MT_vh], eax
    M eax, MI_16                # the text's width: a margin each side and the scrollbar's
    mov ecx, [rsp + 8]
    sub ecx, eax
    sub ecx, eax
    sub ecx, [rip + g_mt + 4*MI_12]
    cmp ecx, 1
    jge 1f
    mov ecx, 1
1:  mov [rsp + 16], ecx
    mov [rbx + MT_w], ecx
    mov rdi, r12
    mov esi, ecx
    call md_layout
    add eax, [rip + g_mt + 4*MI_16]
    mov [rbx + MT_h], eax
    # the area: the wheel, a press gives the editor the keyboard
    mov edi, ID_MDT_AREA
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_12]
    mov r8d, [rsp + 12]
    call ui_btn
    mov [rsp + 20], eax
    test eax, UB_HOVER
    jz 2f
    mov eax, [rip + g_scroll_y]
    add [rbx + MT_scroll], eax
2:  test dword ptr [rsp + 20], UB_PRESS
    jz 3f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
3:  mov rdi, rbx
    call clamp
    # the Comment button, beside the selection's last line
    mov rdi, rbx
    call takes_comments
    test eax, eax
    jz 5f
    mov rdi, r12
    call md_sel_end
    test eax, eax
    js 5f
    mov r13d, eax               # its x, y, line's height in the document
    mov r14d, edx
    mov r15d, ecx
    lea rdi, [rip + g_face_ui]
    lea rsi, [rip + .Lmd_comment]
    mov edx, 7
    call text_width
    add eax, [rip + g_mt + 4*MI_12]
    add eax, [rip + g_mt + 4*MI_12]
    mov [rsp + 36], eax         # w
    M eax, MI_24
    mov ecx, [rip + g_face_ui + FACE_lineh]
    add ecx, [rip + g_mt + 4*MI_6]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 40], eax         # h
    mov eax, [rsp]
    add eax, [rip + g_mt + 4*MI_16]
    add eax, r13d
    add eax, [rip + g_mt + 4*MI_8]
    mov ecx, [rsp]              # within the view, left of the scrollbar
    add ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_12]
    sub ecx, [rip + g_mt + 4*MI_4]
    sub ecx, [rsp + 36]
    cmp eax, ecx
    cmovg eax, ecx
    cmp eax, [rsp]
    cmovl eax, [rsp]
    mov [rsp + 28], eax         # x
    mov eax, r15d
    sub eax, [rsp + 40]
    sar eax, 1
    add eax, r14d
    add eax, [rsp + 4]
    add eax, [rip + g_mt + 4*MI_8]
    sub eax, [rbx + MT_scroll]
    mov [rsp + 32], eax         # y
    cmp eax, [rsp + 4]
    jl 5f
    add eax, [rsp + 40]
    mov ecx, [rsp + 4]
    add ecx, [rsp + 12]
    cmp eax, ecx
    jg 5f
    mov dword ptr [rsp + 24], 1
    mov edi, [rsp + 28]
    mov esi, [rsp + 32]
    mov edx, [rsp + 36]
    mov ecx, [rsp + 40]
    call ui_in
    mov [rsp + 44], eax
5:  # dragging selects text (not on the button)
    mov r8d, [rsp + 20]
    cmp dword ptr [rsp + 44], 0
    je 51f
    xor r8d, r8d
51: mov rdi, r12
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_8]
    mov ecx, [rbx + MT_scroll]
    call md_select_mouse
    # the document
    mov eax, ID_MDTAB
    push rax
    push rax
    mov rdi, r12
    mov esi, [rsp + 16]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 16 + 4]
    add edx, [rip + g_mt + 4*MI_8]
    mov ecx, [rsp + 16 + 16]
    mov r8d, [rsp + 16 + 12]
    sub r8d, [rip + g_mt + 4*MI_8]
    mov r9d, [rbx + MT_scroll]
    call md_draw
    add rsp, 16
    test eax, eax
    js 6f
    inc eax
    mov [rip + pend_link], eax
6:  cmp dword ptr [rsp + 24], 0
    je 7f
    mov edi, ID_MDT_COMMENT
    mov esi, [rsp + 28]
    mov edx, [rsp + 32]
    mov ecx, [rsp + 36]
    mov r8d, [rsp + 40]
    call ui_btn
    mov r13d, eax
    test eax, UB_CLICK
    jz 61f
    mov eax, [rip + pend_slot]
    inc eax
    mov [rip + pend_comment], eax
61: COLOR eax, T_ACCENT
    test r13d, UB_HOVER
    jz 62f
    COLOR eax, T_ACTIVE
62: push rax
    push rax
    mov edi, [rsp + 16 + 28]
    mov esi, [rsp + 16 + 32]
    mov edx, [rsp + 16 + 36]
    mov ecx, [rsp + 16 + 40]
    M r8d, MI_RADIUS
    COLOR r9d, T_ACCENT
    call gfx_frame
    add rsp, 16
    COLOR eax, T_ACCENT_FG
    push rax
    push rax
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 16 + 28]
    mov edx, [rsp + 16 + 32]
    mov ecx, [rsp + 16 + 36]
    mov r8d, [rsp + 16 + 40]
    lea r9, [rip + .Lmd_comment]
    call ui_text_center
    add rsp, 16
7:  # the scrollbar
    mov eax, [rsp + 12]
    push rax
    mov eax, [rbx + MT_h]
    push rax
    mov edi, ID_MDT_BAR
    mov esi, [rsp + 16]
    add esi, [rsp + 16 + 8]
    M eax, MI_12
    sub esi, eax
    mov edx, [rsp + 16 + 4]
    mov ecx, eax
    mov r8d, [rsp + 16 + 12]
    lea r9, [rbx + MT_scroll]
    call ui_scrollbar
    add rsp, 16
    call gfx_clip_pop
    # after the drawing: the link, the button
    mov eax, [rip + pend_link]
    test eax, eax
    jz 8f
    mov dword ptr [rip + pend_link], 0
    lea esi, [rax - 1]
    mov rdi, rbx
    call follow
8:  mov eax, [rip + pend_comment]
    test eax, eax
    jz 9f
    mov dword ptr [rip + pend_comment], 0
    lea edi, [rax - 1]
    call comment_begin
9:  EPILOGUE

# follow(MT*, link): "#slug" scrolls to its heading, a code block's Copy copies, a web link asks first
follow:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, [rbx + MT_md]
    mov esi, r12d
    call md_is_copy
    test eax, eax
    jz 1f
    mov rdi, [rbx + MT_md]
    mov esi, r12d
    call md_open_link
    jmp 9f
1:  mov rdi, [rbx + MT_md]
    mov esi, r12d
    call md_link
    test rdx, rdx
    jz 9f
    mov r13, rax
    mov r14, rdx
    cmp byte ptr [r13], '#'
    jne 2f
    mov rdi, [rbx + MT_md]
    mov rsi, r13
    mov rdx, r14
    call md_anchor
    test eax, eax
    js 9f
    mov [rbx + MT_scroll], eax
    mov dword ptr [rip + g_dirty], 1
    jmp 9f
2:  mov rdi, r13                # links_ask_open takes web links only
    mov rsi, r14
    call mem_dup
    mov r15, rax
    lea rdi, [rip + .Lmd_who]
    mov rsi, r15
    call links_ask_open
    mov rdi, r15
    call mem_free
9:  EPILOGUE

# comment_begin(slot) -> eax 1 when the prompt opened: the selected text is the quote from now on
comment_begin:
    PROLOGUE
    mov ebx, edi
    call slot_ptr
    mov r12, rax
    xor r13d, r13d
    cmp dword ptr [r12 + MT_used], 0
    je 9f
    mov rdi, r12
    call takes_comments
    test eax, eax
    jz 9f
    lea rdi, [rip + cm_sb]
    call sb_clear
    mov rdi, [r12 + MT_md]
    lea rsi, [rip + cm_sb]
    call md_sel_text
    test eax, eax
    jz 9f
    cmp qword ptr [rip + cm_sb + SB_len], 0
    je 9f
    lea eax, [rbx + 1]
    mov [rip + cm_slot1], eax
    mov rax, [r12 + MT_ctx]
    mov [rip + cm_ctx], rax
    lea rdi, [rip + .Lmd_prompt]
    mov esi, PROMPT_MD_COMMENT
    lea rdx, [rip + .Lmd_empty]
    xor ecx, ecx
    call palette_ext_prompt_open
    lea eax, [rbx + 1]          # (opening the palette may have dropped an earlier prompt's)
    mov [rip + cm_slot1], eax
    mov r13d, 1
9:  mov eax, r13d
    EPILOGUE

# give(slot, text ptr, len) -> eax 1 when the owner took the comment (the quote in cm_sb): the selection
#   goes; one it refused (a card full of comments says why) keeps its selection
give:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    call trim
    mov r12, rax
    mov r13, rdx
    xor r15d, r15d
    test r13, r13
    jz 9f
    mov edi, ebx
    call slot_ptr
    mov r14, rax
    cmp dword ptr [r14 + MT_used], 0
    je 9f
    mov rdi, r14
    call takes_comments
    test eax, eax
    jz 9f
    mov rax, [r14 + MT_mdo]
    mov r10, [rax + MDO_comment]
    mov rdi, [r14 + MT_ctx]
    mov rsi, [rip + cm_sb + SB_ptr]
    mov rdx, [rip + cm_sb + SB_len]
    mov rcx, r12
    mov r8, r13
    call r10
    mov dword ptr [rip + g_dirty], 1
    test eax, eax
    jz 9f
    mov r15d, 1
    mov rdi, [r14 + MT_md]
    call md_sel_clear
9:  mov eax, r15d
    EPILOGUE

# FN mdtab_prompt_done(ptr, len): Enter in the comment prompt: the comment goes to the tab's owner with the
#   quote taken when Comment was pressed (nothing when its tab or owner went meanwhile, or it is empty)
FN mdtab_prompt_done
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov eax, [rip + cm_slot1]
    mov dword ptr [rip + cm_slot1], 0
    dec eax
    js 9f
    mov ebx, eax
    mov edi, eax
    call slot_ptr
    cmp dword ptr [rax + MT_used], 0
    je 9f
    mov rcx, [rax + MT_ctx]
    cmp rcx, [rip + cm_ctx]
    jne 9f
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    call give
9:  EPILOGUE

# FN mdtab_key(keysym, cp, mods) -> eax 1 when the active Markdown tab took the key: Ctrl+Enter is Comment
#   (a tab that takes comments); without Ctrl, Alt or Super the arrows, Page Up/Down, Space, Home, End
#   scroll, Tab and Shift+Tab move between links, Enter follows the focused one (none: not taken)
FN mdtab_key
    PROLOGUE
    mov r12d, edi
    mov r14d, edx
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 8f
    call cur_slot
    test eax, eax
    js 8f
    mov ebx, eax
    mov edi, eax
    call slot_ptr
    mov r15, rax
    mov r13, [r15 + MT_md]
    cmp r12d, KEY_RETURN
    je 1f
    cmp r12d, KEY_KP_ENTER
    jne 2f
1:  test r14d, MOD_CTRL | MOD_SUPER
    jz 2f
    mov rdi, r15                # Comment: only a tab that takes comments has it, else the key goes on
    call takes_comments
    test eax, eax
    jz 8f
    mov edi, ebx
    call comment_begin
    jmp 7f
2:  test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz 8f
    M ecx, MI_20                # a line
    mov eax, [r15 + MT_vh]      # a page
    sub eax, [rip + g_mt + 4*MI_32]
    cmp eax, ecx
    cmovl eax, ecx
    cmp r12d, KEY_DOWN
    je 10f
    cmp r12d, KEY_UP
    je 11f
    cmp r12d, KEY_PAGEDOWN
    je 12f
    cmp r12d, KEY_PAGEUP
    je 13f
    cmp r12d, ' '
    jne 3f
    test r14d, MOD_SHIFT
    jnz 13f
    jmp 12f
3:  cmp r12d, KEY_HOME
    je 14f
    cmp r12d, KEY_END
    je 15f
    cmp r12d, KEY_TAB
    je 16f
    cmp r12d, KEY_ISO_LEFT_TAB
    je 16f
    cmp r12d, KEY_RETURN
    je 17f
    cmp r12d, KEY_KP_ENTER
    je 17f
8:  xor eax, eax
    EPILOGUE
10: add [r15 + MT_scroll], ecx
    jmp 7f
11: sub [r15 + MT_scroll], ecx
    jmp 7f
12: add [r15 + MT_scroll], eax
    jmp 7f
13: sub [r15 + MT_scroll], eax
    jmp 7f
14: mov dword ptr [r15 + MT_scroll], 0
    jmp 7f
15: mov eax, [r15 + MT_h]
    mov [r15 + MT_scroll], eax
    jmp 7f
16: mov rdi, r13                # the next link (Shift: the one before), into view
    call md_links
    test eax, eax
    jz 7f
    mov ebx, eax
    mov rdi, r13
    call md_focus
    mov ecx, ebx
    cmp r12d, KEY_ISO_LEFT_TAB
    je 161f
    test r14d, MOD_SHIFT
    jnz 161f
    inc eax
    cmp eax, ecx
    jl 162f
    xor eax, eax
    jmp 162f
161:dec eax
    jns 162f
    lea eax, [rcx - 1]
162:mov ebx, eax
    mov rdi, r13
    mov esi, eax
    call md_set_focus
    mov rdi, r13
    mov esi, ebx
    call md_link_y
    test eax, eax
    js 7f
    cmp eax, [r15 + MT_scroll]
    jl 163f
    mov ecx, [r15 + MT_scroll]
    add ecx, [r15 + MT_vh]
    sub ecx, [rip + g_mt + 4*MI_32]
    cmp eax, ecx
    jl 7f
    sub eax, [r15 + MT_vh]
    add eax, [rip + g_mt + 4*MI_48]
163:mov [r15 + MT_scroll], eax
    jmp 7f
17: mov rdi, r13                # Enter follows the focused link; without one it goes on
    call md_focus
    test eax, eax
    js 8b
    mov rdi, r15
    mov esi, eax
    call follow
7:  mov rdi, r15
    call clamp
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE

# FN mdtab_clip(kind 0 copy, 1 cut, 2 select all) -> eax 1 when the active Markdown tab took it: the
#   selected text to the clipboard (a cut copies: nothing is removed), or all of it selected
FN mdtab_clip
    PROLOGUE 32
    mov r12d, edi
    xor r13d, r13d
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 9f
    call cur_slot
    test eax, eax
    js 9f
    mov edi, eax
    call slot_ptr
    mov rbx, [rax + MT_md]
    mov r13d, 1
    cmp r12d, 2
    jne 1f
    mov rdi, rbx
    call md_select_all
    jmp 9f
1:  lea rdi, [rsp]
    xor esi, esi
    mov edx, SB_SIZE
    call memset
    mov rdi, rbx
    lea rsi, [rsp]
    call md_sel_text
    test eax, eax
    jz 2f
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    xor edx, edx
    call ed_clip_set
2:  lea rdi, [rsp]
    call sb_free
9:  mov eax, r13d
    EPILOGUE

# lay(MT*): laid out at the width it was drawn at (a tab never drawn: 800)
lay:
    mov esi, [rdi + MT_w]
    test esi, esi
    jnz 1f
    mov esi, 800
1:  mov rdi, [rdi + MT_md]
    jmp md_layout

# FN mdtab_select(ptr, len) -> eax 1 when the text was found in the tab (headless) and is selected
FN mdtab_select
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call target_slot
    test eax, eax
    js 8f
    mov edi, eax
    call slot_ptr
    mov rbx, rax
    mov rdi, rax
    call lay
    mov rdi, [rbx + MT_md]
    mov rsi, r12
    mov rdx, r13
    call md_select_text
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN mdtab_comment(ptr, len) -> eax as Comment pressed (headless): without text the prompt opens; with
#   text the comment goes as the prompt's Enter would send it. 1 done, 0 nothing selected, -1 the tab takes
#   no comments (or there is none)
FN mdtab_comment
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call target_slot
    test eax, eax
    js 8f
    mov ebx, eax
    mov edi, eax
    call slot_ptr
    mov r14, rax
    mov rdi, rax
    call takes_comments
    test eax, eax
    jz 8f
    test r13, r13
    jnz 1f
    mov edi, ebx
    call comment_begin
    EPILOGUE
1:  lea rdi, [rip + cm_sb]
    call sb_clear
    mov rdi, [r14 + MT_md]
    lea rsi, [rip + cm_sb]
    call md_sel_text
    test eax, eax
    jz 9f
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    call give
    EPILOGUE
8:  mov eax, -1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# push_esc(sb, ptr, len): the bytes, a line feed as "\n"
push_esc:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, r13
    jae 9f
    movzx esi, byte ptr [r12 + r14]
    inc r14
    cmp esi, 10
    jne 2f
    mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
    mov esi, 'n'
2:  mov rdi, rbx
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# FN mdtab_dump(sb): print-mdtab: a line per Markdown tab in the strip, "mdtab tab=I title=T active=0|1
#   comment=0|1 selected=TEXT|-" (TEXT's line feeds as "\n"), then its source, "text LINE" a line
FN mdtab_dump
    PROLOGUE 32
    mov rbx, rdi
    xor r12d, r12d
.Lmdd_tab:
    cmp r12, [rip + g_tabs + VEC_len]
    jae .Lmdd_end
    mov rdi, r12
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_MDDOC
    jne .Lmdd_next
    mov rdi, [rax + TAB_flags]
    call flags_slot
    test eax, eax
    js .Lmdd_next
    mov edi, eax
    call slot_ptr
    mov r13, rax
    mov rdi, rbx
    lea rsi, [rip + .Ldm_tab]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ldm_title]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r13 + MT_title]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ldm_active]
    call sb_push_cstr
    xor esi, esi
    cmp r12, [rip + g_tab_cur]
    sete sil
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ldm_comment]
    call sb_push_cstr
    mov rdi, r13
    call takes_comments
    mov esi, eax
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ldm_selected]
    call sb_push_cstr
    lea rdi, [rsp]
    xor esi, esi
    mov edx, SB_SIZE
    call memset
    mov rdi, [r13 + MT_md]
    lea rsi, [rsp]
    call md_sel_text
    test eax, eax
    jz 1f
    cmp qword ptr [rsp + SB_len], 0
    je 1f
    mov rdi, rbx
    mov rsi, [rsp + SB_ptr]
    mov rdx, [rsp + SB_len]
    call push_esc
    jmp 2f
1:  mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
2:  lea rdi, [rsp]
    call sb_free
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, [r13 + MT_md]      # its text, a line each
    call md_source
    mov r14, rax
3:  cmp byte ptr [r14], 0
    je .Lmdd_next
    xor r15d, r15d
4:  movzx eax, byte ptr [r14 + r15]
    test eax, eax
    jz 5f
    cmp eax, 10
    je 5f
    inc r15
    jmp 4b
5:  mov rdi, rbx
    lea rsi, [rip + .Ldm_text]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add r14, r15
    cmp byte ptr [r14], 10
    jne .Lmdd_next
    inc r14
    jmp 3b
.Lmdd_next:
    inc r12
    jmp .Lmdd_tab
.Lmdd_end:
    EPILOGUE

.section .rodata
.Lmd_untitled: .asciz "Markdown"
.Lmd_comment: .asciz "Comment"
.Lmd_prompt: .asciz "Comment on the selection"
.Lmd_who: .asciz "This document"
.Lmd_empty: .asciz ""
.Ldm_tab: .asciz "mdtab tab="
.Ldm_title: .asciz " title="
.Ldm_active: .asciz " active="
.Ldm_comment: .asciz " comment="
.Ldm_selected: .asciz " selected="
.Ldm_text: .asciz "text "
