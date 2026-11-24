# Selection in a row's text, the thread's copy and its context menu, a reply's Copy response (phase 3 task 10).
# Generic: nothing here names a driver, a tool or a record (the seam test reads this file).
#
# One selection at a time, inside one row (open point 2: no drag over rows). A reply's, open thinking's or an
# open compaction summary's Markdown holds its own (md_select_mouse: by text items; md_sel_text says what it
# is); a plain text a row draws through agentrows.s's wrap (a prompt, a call's IN or OUT, a meta line) is
# selected by bytes of the text as drawn (sel_a to sel_b). A press in a row drops what was selected; a drag
# goes on only in the unit it began in, wherever the pointer goes; a press on a link is the link's, and a big
# IN or OUT (a button that opens its tab) is selected by a drag, whose release opens nothing (agsel_moved).
# Nothing here walks the rows: the pointer meets only the rows drawn (their own buttons), and a text is
# wrapped again only for the unit that holds the selection or is pressed.
#
#   agsel_row(AS*, row, x, y, w, h)         draw_msg: a row's area (the pointer's row, a press, a right press)
#   agsel_md(AS*, row, doc, x, y, scroll)   just before a row's Markdown is drawn: its selection by the mouse
#   agsel_plain(RW*, row, part, id, h)      agentrows.s, drawing: a plain text's selection by the mouse and its
#                                           band, before the text (RW: agentrows.s's wrap record; h shown)
#   agsel_line_add(start, end)              agentrows.s's wrap: a line laid out (while agsel_lines is set)
#   agsel_moved() -> eax                    1: this press's drag selected text (the part's click is no click)
#   agsel_rlink(cstr)                       a right press on a link outside a reply's Markdown (a call's header)
#   agsel_follow()                          thread_draw's end: a right press opens the context menu
#   agsel_key(AS*, keysym, cp, mods) -> eax Ctrl/Cmd+C, Ctrl/Cmd+A, Shift+F10 and the Menu key (th_keys)
#   agsel_cut(AS*, n)                       rows from n on go (agents_rows_cut): what pointed into them goes
#   agsel_bar_h(AS*, row) -> eax            a reply's Copy response line under it (a reply that ends its turn)
#   agsel_bar_draw(AS*, row, x, y)          drawn: shown on the pointer's row, the focused row, the last row
#   agsel_resp(AS*, row) -> eax             Copy response by the row focus (Enter) or agent-row-click
#   agsel_clear(), agsel_dump(sb), agsel_cmd_select() -> rax   print-agent-selection, agent-select
.include "rhun.inc"

.equ ID_AG_SEL, 0x620000        # + (row & 0xffff): a row's area (phase 3's 0x600000-0x63ffff)
.equ ID_AG_RESP, 0x630000       # + (row & 0xfff): a reply's Copy response
.equ LINK_MAX, 4000             # a link target is copied whole up to this (reply_click's limit)
.equ ERR_CUT, 2000              # an error's OUT is drawn cut at this many characters (agentrows.s)
.equ KEY_F10, 0xffc7
.equ KEY_MENU, 0xff67
.equ RESP_KEPT, 8
.equ HIDDEN_PASSED, 8           # agsel_bar_h: hidden calls after a reply looked past, at most

# SW: the layout of agentrows.s's RW (rw_wrap's record); keep the two alike
STRUCT
F SW_face, 8
F SW_text, 8
F SW_len, 8
F SW_x, 4
F SW_y, 4
F SW_w, 4
F SW_lh, 4
F SW_color, 4
F SW_draw, 4
F SW_top, 4
F SW_bot, 4
F SW_max, 4
F SW_pad, 4
F SW_out, 8
F SW_mute, 8
ENDSTRUCT SW_SIZE

.data
.p2align 3
sel_row: .quad -1               # the row holding the selection, -1 none
rp_row: .quad -1                # a right press in this frame: its row, -1 none
hov_row: .quad -1               # the row under the pointer when last drawn (hov_ser: th_serial then)
ub_row: .quad -1                # agsel_row's last row and its UB bits (agsel_md reads them)
menu_row: .quad -1              # the context menu's row
.bss
.p2align 3
sel_as: .quad 0
sel_a: .quad 0                  # plain: the anchor and the end, bytes of the text as drawn
sel_b: .quad 0
rp_as: .quad 0
rp_link: .quad 0                # owned cstr: the link under the right press, 0 none
hov_as: .quad 0
menu_as: .quad 0
menu_link: .quad 0              # owned cstr: what Copy Link copies
.globl agsel_lines
agsel_lines: .quad 0            # SB* while agentrows.s's wrap gives its lines (agsel_line_add)
lines: .zero SB_SIZE            # (start, end) u32 pairs of the unit wrapped last
cs: .zero SB_SIZE               # a copy's text
ws: .zero SB_SIZE               # a part's whole text
sw: .zero SW_SIZE               # a wrap's record, copied
menu_items: .zero 16 * 4 + 16
sel_part: .long 0
sel_drag: .long 0               # the press goes on: a drag extends sel_b
sel_moved: .long 0              # the press's drag (or a double click) selected text
hov_ser: .long 0
ub_bits: .long 0
rp_x: .long 0
rp_y: .long 0
resp_rows: .zero 8 * RESP_KEPT  # the Copy response buttons drawn in the frame resp_ser: their rows
resp_r: .zero 16 * RESP_KEPT    #   and x, y, w, h (print-agent-selection)
resp_n: .long 0
resp_ser: .long 0

.text

# ---------------- the selection ----------------

# sel_valid() -> rax the row's AM* when the selection is in the conversation the panel shows, else 0 (none
#   is kept)
sel_valid:
    PROLOGUE
    xor ebx, ebx
    mov r12, [rip + sel_row]
    test r12, r12
    js 9f
    call agents_viewed
    test rax, rax
    jz 8f
    cmp rax, [rip + sel_as]
    jne 8f
    cmp r12, [rax + AS_msgs + VEC_len]
    jae 8f
    imul rbx, r12, AM_SIZE
    add rbx, [rax + AS_msgs + VEC_ptr]
    jmp 9f
8:  mov qword ptr [rip + sel_row], -1
    mov dword ptr [rip + sel_drag], 0
9:  mov rax, rbx
    EPILOGUE

# FN agsel_clear(): no selection (a Markdown row's own goes too)
FN agsel_clear
    PROLOGUE
    call sel_valid
    test rax, rax
    jz 9f
    cmp dword ptr [rip + sel_part], SELP_MD
    jne 9f
    mov rdi, [rax + AM_doc]
    test rdi, rdi
    jz 9f
    call md_sel_clear
9:  mov qword ptr [rip + sel_row], -1
    mov dword ptr [rip + sel_drag], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# hidden(AS*, AM*) -> eax 1 when a closed fold of focus view holds the row (its text is not shown)
hidden:
    xor eax, eax
    cmp dword ptr [rip + cfg_agents_focus_view], 0
    je 9f
    movsxd rcx, dword ptr [rsi + AM_fold]
    test rcx, rcx
    js 9f
    cmp rcx, [rdi + AS_folds + VEC_len]
    jae 9f
    imul rcx, rcx, AF_SIZE
    add rcx, [rdi + AS_folds + VEC_ptr]
    test dword ptr [rcx + AF_flags], AFF_OPEN
    jnz 9f
    mov eax, 1
9:  ret

# sel_text(sb) -> eax 1 with the selected text appended (as shown: of a part, what the row keeps of it), 0
#   when nothing is selected (a row a closed fold hides now: its selection goes)
sel_text:
    PROLOGUE
    mov r15, rdi
    call sel_valid
    test rax, rax
    jz 8f
    mov rbx, rax
    call agents_viewed
    mov rdi, rax
    mov rsi, rbx
    call hidden
    test eax, eax
    jnz 7f
    cmp dword ptr [rip + sel_part], SELP_MD
    jne 2f
    mov rdi, [rbx + AM_doc]     # a row's Markdown
    test rdi, rdi
    jz 8f
    mov r12, [r15 + SB_len]
    mov rsi, r15
    call md_sel_text
    test eax, eax
    jz 8f
    cmp [r15 + SB_len], r12
    je 8f
    mov eax, 1
    EPILOGUE
2:  mov rdi, rbx                # a plain text: its bytes, as drawn
    mov esi, [rip + sel_part]
    call plain_of
    mov r12, rax
    mov r13, rdx
    mov rax, [rip + sel_a]
    mov rcx, [rip + sel_b]
    cmp rax, rcx
    jbe 3f
    xchg rax, rcx
3:  cmp rcx, r13
    cmova rcx, r13
    cmp rax, rcx
    jae 8f
    lea rsi, [r12 + rax]
    mov rdx, rcx
    sub rdx, rax
    mov rdi, r15
    call sb_push
    mov eax, 1
    EPILOGUE
7:  call agsel_clear
8:  xor eax, eax
    EPILOGUE

# plain_of(AM*, part) -> rax ptr, rdx len: a row's plain part as it is drawn (an error's OUT up to the
#   character it is cut at: the "…" drawn after it is not its text)
plain_of:
    PROLOGUE
    mov rbx, rdi
    mov rax, [rbx + AM_text]
    mov rdx, [rbx + AM_len]
    cmp esi, SELP_PROMPT
    je 9f
    cmp esi, SELP_META
    je 9f
    mov rcx, [rbx + AM_x]
    xor eax, eax
    xor edx, edx
    test rcx, rcx
    jz 9f
    mov rax, [rcx + AT_in + SB_ptr]
    mov rdx, [rcx + AT_in + SB_len]
    cmp esi, PART_IN
    je 9f
    mov rax, [rcx + AT_out + SB_ptr]
    mov rdx, [rcx + AT_out + SB_len]
    cmp dword ptr [rcx + AT_state], ATS_FAILED
    jne 9f
    mov r12, rax                # an error: up to its 2000th character
    xor ecx, ecx
    xor r8d, r8d
1:  cmp rcx, rdx
    jae 9f
    movzx r9d, byte ptr [r12 + rcx]
    and r9d, 0xc0
    cmp r9d, 0x80
    je 2f
    cmp r8d, ERR_CUT
    je 3f
    inc r8d
2:  inc rcx
    jmp 1b
3:  mov rdx, rcx
9:  EPILOGUE

# is_mine(AS*, row, part) -> eax 1 when the selection is that unit's
is_mine:
    xor eax, eax
    cmp [rip + sel_row], rsi
    jne 9f
    cmp [rip + sel_as], rdi
    jne 9f
    cmp [rip + sel_part], edx
    jne 9f
    mov eax, 1
9:  ret

# ---------------- the rows drawn ----------------

# FN agsel_row(AS*, row, x, y, w, h): a row's area, before its parts (they take the pointer after it): the
#   pointer's row; a press drops the selection (a part that selects takes the press again); a right press is
#   kept for the menu (agsel_follow, after the frame)
FN agsel_row
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov [rip + ub_row], rsi
    mov dword ptr [rip + ub_bits], 0
    mov edi, r12d
    and edi, 0xffff
    add edi, ID_AG_SEL
    mov esi, edx
    mov edx, ecx
    mov ecx, r8d
    mov r8d, r9d
    call ui_btn
    mov [rip + ub_bits], eax
    mov r13d, eax
    test r13d, UB_HOVER
    jz 1f
    mov [rip + hov_row], r12
    mov [rip + hov_as], rbx
    mov eax, [rip + th_serial]
    mov [rip + hov_ser], eax
1:  test r13d, UB_PRESS
    jz 2f
    call agsel_clear
    mov dword ptr [rip + sel_moved], 0
2:  test r13d, UB_RPRESS
    jz 9f
    mov [rip + rp_row], r12
    mov [rip + rp_as], rbx
    mov eax, [rip + g_mx]
    mov [rip + rp_x], eax
    mov eax, [rip + g_my]
    mov [rip + rp_y], eax
    mov rdi, [rip + rp_link]
    call mem_free
    mov qword ptr [rip + rp_link], 0
9:  EPILOGUE

# FN agsel_md(AS*, row, doc, x, y, scroll): before a row's Markdown is drawn at x, y from scroll (md_draw's):
#   a press in the row anchors a selection in it unless it is on a link (the link's); the drag that began in
#   it goes on (md_select_mouse: only then, never per frame for a row nobody presses); a right press on a link
#   notes the link for Copy Link
FN agsel_md
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov [rsp + 8], r9d
    test r13, r13
    jz 9f
    xor r14d, r14d              # the row's UB bits in this frame
    cmp [rip + ub_row], r12
    jne 1f
    mov r14d, [rip + ub_bits]
1:  test r14d, UB_PRESS
    jz 3f
    mov rdi, r13                # on a link: not a selection
    mov esi, [rip + g_mx]
    sub esi, [rsp]
    mov edx, [rip + g_my]
    sub edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call md_link_at
    test eax, eax
    jns 5f
    mov rdi, r13
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, r14d
    call md_select_mouse
    mov [rip + sel_as], rbx
    mov [rip + sel_row], r12
    mov dword ptr [rip + sel_part], SELP_MD
    mov dword ptr [rip + sel_drag], 1
    test r14d, UB_DOUBLE
    jz 5f
    mov dword ptr [rip + sel_drag], 0
    jmp 5f
3:  cmp dword ptr [rip + sel_drag], 0   # the drag of this row's selection
    je 5f
    mov rdi, rbx
    mov rsi, r12
    mov edx, SELP_MD
    call is_mine
    test eax, eax
    jz 5f
    mov rdi, r13
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    xor r8d, r8d
    call md_select_mouse
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jnz 5f
    mov dword ptr [rip + sel_drag], 0
5:  cmp [rip + rp_row], r12     # a right press in this row: a link under it?
    jne 9f
    cmp [rip + rp_as], rbx
    jne 9f
    cmp qword ptr [rip + rp_link], 0
    jne 9f
    mov rdi, r13
    mov esi, [rip + rp_x]
    sub esi, [rsp]
    mov edx, [rip + rp_y]
    sub edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call md_link_at
    test eax, eax
    js 9f
    mov rdi, r13
    mov esi, eax
    call md_link
    test rdx, rdx
    jz 9f
    cmp rdx, LINK_MAX
    ja 9f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + rp_link], rax
9:  EPILOGUE

# FN agsel_plain(RW*, row, part, id, h): a plain text about to be drawn (its RW as the wrap draws it; h: its
#   height shown): with an id (-1: none) the pointer over it selects (a press anchors, a drag extends, a double
#   click takes a word; the I-beam over it), and the selected part is banded in T_SELECTION under the text
FN agsel_plain
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    test r12, r12
    js 9f
    call agents_viewed
    mov r14, rax
    test r14, r14
    jz 9f
    cmp dword ptr [rsp], 0
    jl 5f
    mov edi, [rsp]
    mov esi, [rbx + SW_x]
    mov edx, [rbx + SW_y]
    mov ecx, [rbx + SW_w]
    mov r8d, [rsp + 4]
    cmp r8d, 1
    jge 1f
    mov r8d, 1
1:  call ui_btn
    mov r15d, eax
    test r15d, UB_HOVER
    jz 2f
    mov dword ptr [rip + g_cursor], CUR_TEXT
2:  test r15d, UB_PRESS
    jz 3f
    call agsel_clear            # a press: the anchor
    mov rdi, rbx
    call wrap_lines
    mov rdi, rbx
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call hit
    mov [rip + sel_as], r14
    mov [rip + sel_row], r12
    mov [rip + sel_part], r13d
    mov [rip + sel_a], rax
    mov [rip + sel_b], rax
    mov dword ptr [rip + sel_drag], 1
    mov dword ptr [rip + sel_moved], 0
    mov dword ptr [rip + g_dirty], 1
    test r15d, UB_DOUBLE
    jz 5f
    mov rdi, [rbx + SW_text]    # a double click: the word
    mov rsi, [rbx + SW_len]
    mov rdx, rax
    call word_at
    mov dword ptr [rip + sel_drag], 0
    mov dword ptr [rip + sel_moved], 1
    jmp 5f
3:  cmp dword ptr [rip + sel_drag], 0   # the drag that began here
    je 5f
    mov rdi, r14
    mov rsi, r12
    mov edx, r13d
    call is_mine
    test eax, eax
    jz 5f
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jz 4f
    mov rdi, rbx
    call wrap_lines
    mov rdi, rbx
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call hit
    cmp rax, [rip + sel_b]
    je 5f
    mov [rip + sel_b], rax
    mov dword ptr [rip + g_dirty], 1
    cmp rax, [rip + sel_a]
    je 5f
    mov dword ptr [rip + sel_moved], 1
    jmp 5f
4:  mov dword ptr [rip + sel_drag], 0
5:  mov rdi, r14                # the band
    mov rsi, r12
    mov edx, r13d
    call is_mine
    test eax, eax
    jz 9f
    mov rax, [rip + sel_a]
    cmp rax, [rip + sel_b]
    je 9f
    mov rdi, rbx
    call wrap_lines
    mov rdi, rbx
    call paint
9:  EPILOGUE

# word_at(text, len, byte): the word at the byte selected (letters, digits, _ and any byte past ASCII), else the
#   character there alone (sel_a, sel_b)
word_at:
    mov [rip + sel_a], rdx
    mov [rip + sel_b], rdx
    test rsi, rsi
    jz 9f
    cmp rdx, rsi
    jb 1f
    lea rdx, [rsi - 1]
1:  movzx eax, byte ptr [rdi + rdx]
    cmp eax, 10                 # at a line's end: the character before it
    jne 2f
    test rdx, rdx
    jz 2f
    dec rdx
    movzx eax, byte ptr [rdi + rdx]
2:  call word_byte
    test ecx, ecx
    jnz 3f
    mov [rip + sel_a], rdx      # not a word: the one byte (ASCII)
    inc rdx
    mov [rip + sel_b], rdx
    ret
3:  mov r8, rdx                 # its start
4:  test r8, r8
    jz 5f
    movzx eax, byte ptr [rdi + r8 - 1]
    call word_byte
    test ecx, ecx
    jz 5f
    dec r8
    jmp 4b
5:  mov [rip + sel_a], r8
    mov r8, rdx                 # its end
6:  cmp r8, rsi
    jae 7f
    movzx eax, byte ptr [rdi + r8]
    call word_byte
    test ecx, ecx
    jz 7f
    inc r8
    jmp 6b
7:  mov [rip + sel_b], r8
9:  ret

# word_byte(eax byte) -> ecx 1 when it is part of a word (touches eax and ecx only)
word_byte:
    mov ecx, 1
    cmp eax, 0x80
    jae 9f
    cmp eax, '_'
    je 9f
    push rax
    sub eax, '0'
    cmp eax, 9
    pop rax
    jbe 9f
    push rax
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    pop rax
    jbe 9f
    xor ecx, ecx
9:  ret

# FN agsel_rlink(cstr): a right press on a link outside a reply's Markdown (a call's header): Copy Link copies it
FN agsel_rlink
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    cmp qword ptr [rip + rp_row], 0
    jl 9f
    mov rdi, [rip + rp_link]
    call mem_free
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov [rip + rp_link], rax
9:  EPILOGUE

# FN agsel_moved() -> eax 1 when the press being released selected text by a drag or a double click: the part
#   under it does not take that release as a click
FN agsel_moved
    mov eax, [rip + sel_moved]
    ret

# FN agsel_line_add(start, end): a line the wrap laid out (while agsel_lines is set: wrap_lines)
FN agsel_line_add
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov rdi, [rip + agsel_lines]
    test rdi, rdi
    jz 9f
    lea rsi, [rsp]
    mov edx, 8
    call sb_push
9:  EPILOGUE

# wrap_lines(RW*): its lines into `lines`, wrapped as the text is drawn (nothing drawn)
wrap_lines:
    PROLOGUE
    mov rsi, rdi
    lea rdi, [rip + sw]
    mov edx, SW_SIZE
    call memcpy
    mov dword ptr [rip + sw + SW_draw], 0
    mov qword ptr [rip + sw + SW_out], 0
    lea rdi, [rip + lines]
    call sb_clear
    lea rax, [rip + lines]
    mov [rip + agsel_lines], rax
    lea rdi, [rip + sw]
    call agrow_wrap
    mov qword ptr [rip + agsel_lines], 0
    EPILOGUE

# seg_px(face, ptr, len) -> eax its width as the wrap draws it (a TAB four cells)
seg_px:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  test r13, r13
    jz 9f
    xor ecx, ecx                # a run up to a TAB
2:  cmp rcx, r13
    jae 3f
    cmp byte ptr [r12 + rcx], 9
    je 3f
    inc rcx
    jmp 2b
3:  mov r15, rcx
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rcx
    call text_width
    add r14d, eax
    add r12, r15
    sub r13, r15
    jz 9f
    mov eax, [rbx + FACE_cellw] # the TAB
    shl eax, 2
    add r14d, eax
    inc r12
    dec r13
    jmp 1b
9:  mov eax, r14d
    EPILOGUE

# hit(RW*, x, y) -> rax the byte of its text nearest the point (its lines: wrap_lines): above the first line
#   0, below the last laid out that line's end
hit:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov rax, [rip + lines + SB_len]
    shr rax, 3
    test rax, rax
    jz 8f
    mov [rsp + 8], rax          # lines
    mov eax, edx
    sub eax, [rbx + SW_y]
    js 8f
    mov ecx, [rbx + SW_lh]
    test ecx, ecx
    jle 8f
    xor edx, edx
    div ecx
    cmp rax, [rsp + 8]
    jb 1f
    mov rax, [rsp + 8]          # below the last: its end
    dec rax
    mov rcx, [rip + lines + SB_ptr]
    mov eax, [rcx + rax*8 + 4]
    EPILOGUE
1:  mov rcx, [rip + lines + SB_ptr]
    mov r12d, [rcx + rax*8]     # the line's start
    mov r13d, [rcx + rax*8 + 4] # its end
    mov r14d, [rsp]             # the pixels into it
    sub r14d, [rbx + SW_x]
    mov r15, [rbx + SW_text]
2:  cmp r12d, r13d              # a run at a time: a TAB is four cells
    jae 7f
    test r14d, r14d
    jle 7f
    cmp byte ptr [r15 + r12], 9
    jne 3f
    mov rax, [rbx + SW_face]
    mov eax, [rax + FACE_cellw]
    shl eax, 2
    mov ecx, eax
    shr ecx, 1
    cmp r14d, ecx
    jl 7f
    sub r14d, eax
    inc r12d
    jmp 2b
3:  mov ecx, r12d               # the run
4:  cmp ecx, r13d
    jae 5f
    cmp byte ptr [r15 + rcx], 9
    je 5f
    inc ecx
    jmp 4b
5:  mov [rsp + 16], ecx         # its end
    mov rdi, [rbx + SW_face]
    lea rsi, [r15 + r12]
    mov edx, ecx
    sub edx, r12d
    call text_width
    cmp r14d, eax
    jl 6f
    sub r14d, eax               # past it
    mov r12d, [rsp + 16]
    jmp 2b
6:  mov rdi, [rbx + SW_face]    # in it: the bytes that fit
    lea rsi, [r15 + r12]
    mov edx, [rsp + 16]
    sub edx, r12d
    mov ecx, r14d
    call text_fit
    mov [rsp + 20], eax         # (from the run's start)
    lea ecx, [r12 + rax]
    cmp ecx, [rsp + 16]
    jae 61f
    lea rdi, [r15 + rcx]        # then the nearer edge of the next character
    mov esi, [rsp + 16]
    sub esi, ecx
    call utf8_decode
    mov [rsp + 24], edx
    mov rdi, [rbx + SW_face]
    lea rsi, [r15 + r12]
    mov edx, [rsp + 20]
    call text_width
    mov [rsp + 28], eax         # to the fit
    mov rdi, [rbx + SW_face]
    lea rsi, [r15 + r12]
    mov edx, [rsp + 20]
    add edx, [rsp + 24]
    call text_width             # past the next character
    sub eax, [rsp + 28]
    mov ecx, r14d
    sub ecx, [rsp + 28]
    add ecx, ecx
    cmp ecx, eax
    jl 61f
    mov eax, [rsp + 24]
    add [rsp + 20], eax
61: add r12d, [rsp + 20]
7:  mov eax, r12d
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# paint(RW*): the selection's band behind the lines (wrap_lines) it covers; a line break inside it as a half
#   cell after its line
paint:
    PROLOGUE 48
    mov rbx, rdi
    mov rax, [rip + sel_a]
    mov rcx, [rip + sel_b]
    cmp rax, rcx
    jbe 1f
    xchg rax, rcx
1:  mov [rsp], rax              # from
    mov [rsp + 8], rcx          # to
    xor r12d, r12d              # the line
2:  mov rax, r12
    shl rax, 3
    cmp rax, [rip + lines + SB_len]
    jae 9f
    mov rcx, [rip + lines + SB_ptr]
    mov r13d, [rcx + rax]       # its start
    mov r14d, [rcx + rax + 4]   # its end
    cmp r13, [rsp + 8]
    jae 9f                      # (past the selection; a line starting at its end has none of it)
    cmp r14, [rsp]
    jb 8f                       # before it
    mov eax, r12d               # on screen?
    imul eax, [rbx + SW_lh]
    add eax, [rbx + SW_y]
    mov [rsp + 16], eax
    add eax, [rbx + SW_lh]
    cmp eax, [rip + g_cv + CV_cy0]
    jle 8f
    mov eax, [rsp + 16]
    cmp eax, [rip + g_cv + CV_cy1]
    jge 9f
    mov r15, [rsp]              # its part: from max(from, start) to min(to, end)
    cmp r15, r13
    jae 3f
    mov r15, r13
3:  mov rdi, [rbx + SW_face]
    mov rsi, [rbx + SW_text]
    add rsi, r13
    mov rdx, r15
    sub rdx, r13
    call seg_px
    mov [rsp + 20], eax         # x0
    mov rdx, [rsp + 8]
    cmp rdx, r14
    jbe 4f
    mov rdx, r14
4:  mov rdi, [rbx + SW_face]
    mov rsi, [rbx + SW_text]
    add rsi, r13
    sub rdx, r13
    call seg_px
    mov [rsp + 24], eax         # x1
    cmp [rsp + 8], r14          # its break selected too: half a cell more
    jbe 5f
    mov rax, [rbx + SW_face]
    mov eax, [rax + FACE_cellw]
    shr eax, 1
    jnz 41f
    mov eax, 1
41: add [rsp + 24], eax
5:  mov edx, [rsp + 24]
    sub edx, [rsp + 20]
    jle 8f
    mov edi, [rbx + SW_x]
    add edi, [rsp + 20]
    mov esi, [rsp + 16]
    mov ecx, [rbx + SW_lh]
    COLOR r8d, T_SELECTION
    call gfx_fill
8:  inc r12
    jmp 2b
9:  EPILOGUE

# ---------------- copy ----------------

# FN agsel_copy() -> eax 1 when the selected text went to the clipboard
FN agsel_copy
    PROLOGUE
    lea rdi, [rip + cs]
    call sb_clear
    lea rdi, [rip + cs]
    call sel_text
    test eax, eax
    jz 9f
    mov rdi, [rip + cs + SB_ptr]
    mov rsi, [rip + cs + SB_len]
    xor edx, edx
    call ed_clip_set
    mov eax, 1
9:  EPILOGUE

# sel_any() -> eax 1 when something is selected (Copy in the menu)
sel_any:
    PROLOGUE
    lea rdi, [rip + cs]
    call sb_clear
    lea rdi, [rip + cs]
    call sel_text
    EPILOGUE

# message_of(AS*, row, sb): a row's whole text as Copy Message gives it: a prompt as sent, a reply's Markdown
#   source, a call as "NAME SECOND", its IN and its OUT whole (agrow_full: read again from its record where
#   the row keeps a preview), blank lines between them; any other row its text
message_of:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r15, rdx
    imul r13, r12, AM_SIZE
    add r13, [rbx + AS_msgs + VEC_ptr]
    mov r14, [r13 + AM_x]
    test r14, r14
    jnz 1f
    mov rdi, r15
    mov rsi, [r13 + AM_text]
    mov rdx, [r13 + AM_len]
    test rsi, rsi
    jz 9f
    call sb_push
    EPILOGUE
1:  mov rsi, [r14 + AT_name]
    test rsi, rsi
    jz 11f
    mov rdi, r15
    call sb_push_cstr
11: mov rsi, [r14 + AT_second]
    test rsi, rsi
    jz 2f
    cmp qword ptr [r15 + SB_len], 0
    je 12f
    mov rdi, r15
    mov esi, ' '
    call sb_push_byte
12: mov rdi, r15
    mov rsi, [r14 + AT_second]
    call sb_push_cstr
2:  mov r13d, ATX_IN
3:  lea rdi, [rip + ws]
    call sb_clear
    mov rdi, rbx
    mov rsi, r14
    mov edx, r13d
    lea rcx, [rip + ws]
    call agrow_full
    cmp qword ptr [rip + ws + SB_len], 0
    je 4f
    cmp qword ptr [r15 + SB_len], 0
    je 31f
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
31: mov rdi, r15
    mov rsi, [rip + ws + SB_ptr]
    mov rdx, [rip + ws + SB_len]
    call sb_push
4:  inc r13d
    cmp r13d, ATX_OUT
    jbe 3b
9:  EPILOGUE

# copy_message(AS*, row): Copy Message
copy_message:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz 9f
    test r12, r12
    js 9f
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 9f
    lea rdi, [rip + cs]
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + cs]
    call message_of
    mov rdi, [rip + cs + SB_ptr]
    mov rsi, [rip + cs + SB_len]
    xor edx, edx
    call ed_clip_set
9:  EPILOGUE

# ---------------- the context menu ----------------

# FN agsel_follow(): after the frame: a right press on a row opens its menu where it was pressed
FN agsel_follow
    PROLOGUE
    mov rbx, [rip + rp_row]
    test rbx, rbx
    js 9f
    mov qword ptr [rip + rp_row], -1
    call agents_viewed
    test rax, rax
    jz 8f
    cmp rax, [rip + rp_as]
    jne 8f
    mov rdi, rax
    mov rsi, rbx
    mov rdx, [rip + rp_link]
    mov qword ptr [rip + rp_link], 0
    mov ecx, [rip + rp_x]
    mov r8d, [rip + rp_y]
    call menu_open_at
    jmp 9f
8:  mov rdi, [rip + rp_link]
    call mem_free
    mov qword ptr [rip + rp_link], 0
9:  EPILOGUE

# menu_open_at(AS*, row, link owned cstr or 0, x, y): the row's menu: "Copy" (with a selection), "Copy
#   Message", "Copy Link" (on a link)
menu_open_at:
    PROLOGUE 16
    mov [rip + menu_as], rdi
    mov [rip + menu_row], rsi
    mov rbx, rdx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov rdi, [rip + menu_link]
    call mem_free
    mov [rip + menu_link], rbx
    lea r12, [rip + menu_items]
    call sel_any
    test eax, eax
    jz 1f
    lea rax, [rip + .Lm_copy]
    mov [r12], rax
    lea rax, [rip + m_copy]
    mov [r12 + 8], rax
    add r12, 16
1:  lea rax, [rip + .Lm_message]
    mov [r12], rax
    lea rax, [rip + m_message]
    mov [r12 + 8], rax
    add r12, 16
    test rbx, rbx
    jz 2f
    lea rax, [rip + .Lm_link]
    mov [r12], rax
    lea rax, [rip + m_link]
    mov [r12 + 8], rax
    add r12, 16
2:  mov qword ptr [r12], 0
    mov qword ptr [r12 + 8], 0
    lea rdi, [rip + menu_items]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call ctx_menu_open
    EPILOGUE

# m_copy(), m_message(), m_link(): the menu's items
m_copy:
    sub rsp, 8
    call agsel_copy
    add rsp, 8
    ret
m_message:
    PROLOGUE
    call agents_viewed
    cmp rax, [rip + menu_as]
    jne 9f
    mov rdi, rax
    mov rsi, [rip + menu_row]
    call copy_message
9:  EPILOGUE
m_link:
    PROLOGUE
    mov rbx, [rip + menu_link]
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    xor edx, edx
    call ed_clip_set
9:  EPILOGUE

# key_menu(AS*) -> eax 1: Shift+F10 or the Menu key: the menu of the row with the selection, else of the row
#   focus, where the row was drawn last, taking the keys (Up, Down, Enter: ctx_menu_keys); on a call's row its
#   header's link, on a reply the link the keyboard is on, for Copy Link
key_menu:
    PROLOGUE
    mov rbx, rdi
    call sel_valid
    mov r12, [rip + sel_row]
    test rax, rax
    jnz 1f
    call agrow_focus
    mov r12, rax
1:  xor eax, eax
    test r12, r12
    js 9f
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 9f
    imul r13, r12, AM_SIZE
    add r13, [rbx + AS_msgs + VEC_ptr]
    xor r14d, r14d              # the link
    mov rcx, [r13 + AM_x]
    test rcx, rcx
    jz 2f
    mov rdi, [rcx + AT_link]
    test rdi, rdi
    jz 3f
    mov r15, rdi
    call strlen
    mov rdi, r15
    mov rsi, rax
    call mem_dup
    mov r14, rax
    jmp 3f
2:  mov rdi, [r13 + AM_doc]
    test rdi, rdi
    jz 3f
    call md_focus
    test eax, eax
    js 3f
    mov rdi, [r13 + AM_doc]
    mov esi, eax
    call md_link
    test rdx, rdx
    jz 3f
    cmp rdx, LINK_MAX
    ja 3f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r14, rax
3:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    mov ecx, [r13 + AM_dx]
    mov r8d, [r13 + AM_dy]
    add r8d, [rip + g_pmt + 4*MI_20]
    call menu_open_at
    call ctx_menu_keys
    mov eax, 1
9:  EPILOGUE

# ---------------- keys ----------------

# FN agsel_key(AS*, keysym, cp, mods) -> eax 1 taken: Ctrl/Cmd+C copies the selection (nothing selected: the
#   key goes on); Ctrl/Cmd+A selects the text of the row with the selection, the row focus or the pointer;
#   Shift+F10 and the Menu key open the context menu
FN agsel_key
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r14d, ecx
    mov eax, r14d
    and eax, MOD_CTRL | MOD_SUPER
    jz 5f
    test r14d, MOD_ALT | MOD_SHIFT
    jnz 8f
    mov eax, r12d
    or eax, 0x20
    cmp eax, 'c'
    jne 1f
    call agsel_copy
    EPILOGUE
1:  cmp eax, 'a'
    jne 8f
    mov rdi, rbx
    call select_row
    EPILOGUE
5:  cmp r12d, KEY_MENU
    jne 6f
    test r14d, r14d
    jnz 8f
    jmp 7f
6:  cmp r12d, KEY_F10
    jne 8f
    cmp r14d, MOD_SHIFT
    jne 8f
7:  mov rdi, rbx
    call key_menu
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# select_row(AS*) -> eax 1: Ctrl/Cmd+A: the whole text of the row with the selection, else the focused row,
#   else the row under the pointer: a Markdown row's (a reply, open thinking, an open summary) its document's,
#   a prompt's or a meta line's its text, a call's its IN (else its OUT). A row whose text is not shown: none
select_row:
    PROLOGUE
    mov rbx, rdi
    call sel_valid
    mov r12, [rip + sel_row]
    test rax, rax
    jnz 2f
    call agrow_focus
    mov r12, rax
    test r12, r12
    jns 2f
    mov r12, [rip + hov_row]    # the pointer's row, in the last frame drawn
    cmp [rip + hov_as], rbx
    jne 8f
    mov eax, [rip + hov_ser]
    cmp eax, [rip + th_serial]
    jne 8f
2:  test r12, r12
    js 8f
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 8f
    imul r13, r12, AM_SIZE
    add r13, [rbx + AS_msgs + VEC_ptr]
    mov rdi, rbx
    mov rsi, r13
    call hidden
    test eax, eax
    jnz 8f
    mov eax, [r13 + AM_role]
    cmp qword ptr [r13 + AM_x], 0
    jne .Lsr_call
    cmp eax, R_USER
    je .Lsr_prompt
    cmp eax, R_META
    je .Lsr_meta
    cmp eax, R_ASSIST
    je .Lsr_md
    cmp eax, R_THINK
    jne 3f
    call agrow_think            # thinking: open
    test eax, eax
    jz 8f
    jmp .Lsr_md
3:  cmp eax, R_COMPACT
    jne 8f
    test dword ptr [r13 + AM_flags], AMF_OPEN
    jz 8f
.Lsr_md:
    mov rdi, [r13 + AM_doc]
    test rdi, rdi
    jz 8f
    call agsel_clear
    mov rdi, [r13 + AM_doc]
    call md_select_all
    mov [rip + sel_as], rbx
    mov [rip + sel_row], r12
    mov dword ptr [rip + sel_part], SELP_MD
    jmp 7f
.Lsr_prompt:
    mov r14d, SELP_PROMPT
    mov r15, [r13 + AM_len]
    jmp 6f
.Lsr_meta:
    mov r14d, SELP_META
    mov r15, [r13 + AM_len]
    jmp 6f
.Lsr_call:
    mov rcx, [r13 + AM_x]
    mov r14d, PART_IN
    mov r15, [rcx + AT_in + SB_len]
    test r15, r15
    jnz 6f
    mov r14d, PART_OUT
    mov rdi, r13
    mov esi, PART_OUT
    call plain_of
    mov r15, rdx
6:  test r15, r15
    jz 8f
    call agsel_clear
    mov [rip + sel_as], rbx
    mov [rip + sel_row], r12
    mov [rip + sel_part], r14d
    mov qword ptr [rip + sel_a], 0
    mov [rip + sel_b], r15
7:  mov dword ptr [rip + sel_drag], 0
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agsel_cut(AS*, n): its rows from n on go: a selection, a right press, the pointer's row in them go
FN agsel_cut
    cmp [rip + sel_as], rdi
    jne 1f
    cmp [rip + sel_row], rsi
    jl 1f
    mov qword ptr [rip + sel_row], -1
    mov dword ptr [rip + sel_drag], 0
1:  cmp [rip + rp_row], rsi
    jl 2f
    mov qword ptr [rip + rp_row], -1
2:  cmp [rip + hov_row], rsi
    jl 3f
    mov qword ptr [rip + hov_row], -1
3:  mov dword ptr [rip + resp_n], 0
    ret

# ---------------- Copy response (UI 3.9) ----------------

# FN agsel_bar_h(AS*, row) -> eax the line under a reply that ends its turn (the next row begins another, or
#   there is none; calls without a row of their own, ATF_HIDDEN, are passed over, 8 at most): MI_28, where
#   its Copy response shows; 0 for any other row. O(1)
FN agsel_bar_h
    xor eax, eax
    cmp rsi, [rdi + AS_msgs + VEC_len]
    jae 9f
    imul rcx, rsi, AM_SIZE
    add rcx, [rdi + AS_msgs + VEC_ptr]
    cmp dword ptr [rcx + AM_role], R_ASSIST
    jne 9f
    test dword ptr [rcx + AM_flags], AMF_QUEUED | AMF_PILL
    jnz 9f
    lea rdx, [rsi + 1]
    mov r8d, HIDDEN_PASSED
1:  cmp rdx, [rdi + AS_msgs + VEC_len]
    jae 8f
    imul r9, rdx, AM_SIZE
    add r9, [rdi + AS_msgs + VEC_ptr]
    cmp [r9 + AM_turn], edx     # a prompt: another turn
    je 8f
    mov r10, [r9 + AM_x]
    test r10, r10
    jz 9f
    test dword ptr [r10 + AT_flags], ATF_HIDDEN
    jz 9f
    inc rdx
    dec r8d
    jnz 1b
    jmp 9f
8:  mov eax, [rip + g_pmt + 4*MI_28]
9:  ret

# works(AS*) -> eax 1 while its turn runs (a conversation rhun drives with a prompt whose turn has not ended)
works:
    xor eax, eax
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 9f
    cmp qword ptr [rcx + AL_turns], 0
    je 9f
    mov eax, 1
9:  ret

# FN agsel_bar_draw(AS*, row, x, y): a reply's Copy response at the left of its line (agsel_bar_h): on the
#   pointer's row and the focused row, always on the conversation's last row once its turn is over (not while
#   it runs); a click copies the turn's replies
FN agsel_bar_draw
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    lea rax, [r12 + 1]
    cmp rax, [rbx + AS_msgs + VEC_len]
    jne 1f
    mov rdi, rbx                # the last row: once the turn is over
    call works
    test eax, eax
    jnz 9f
    jmp 3f
1:  call agrow_focus
    cmp rax, r12
    je 3f
    cmp [rip + hov_row], r12
    jne 9f
    cmp [rip + hov_as], rbx
    jne 9f
    mov eax, [rip + hov_ser]
    cmp eax, [rip + th_serial]
    jne 9f
3:  mov eax, [rsp + 4]
    add eax, [rip + g_pmt + 4*MI_4]
    mov [rsp + 4], eax
    mov eax, [rip + th_serial]  # noted for print-agent-selection
    cmp eax, [rip + resp_ser]
    je 31f
    mov [rip + resp_ser], eax
    mov dword ptr [rip + resp_n], 0
31: mov ecx, [rip + resp_n]
    cmp ecx, RESP_KEPT
    jae 32f
    inc dword ptr [rip + resp_n]
    lea rax, [rip + resp_rows]
    mov [rax + rcx*8], r12
    shl ecx, 4
    lea rax, [rip + resp_r]
    add rax, rcx
    mov edx, [rsp]
    mov [rax], edx
    mov edx, [rsp + 4]
    mov [rax + 4], edx
    PM edx, MI_20
    mov [rax + 8], edx
    mov [rax + 12], edx
32: PM eax, MI_20
    mov edi, r12d
    and edi, 0xfff
    add edi, ID_AG_RESP
    mov [rsp + 8], edi
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, eax
    mov r8d, eax
    mov r9d, IC_COPY
    call ag_icon_btn
    mov r13d, eax
    mov edi, [rsp + 8]          # its tip
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_20]
    PM ecx, MI_20
    mov r8d, r13d
    lea r9, [rip + .Lcopy_resp]
    call tip_note_text
    call agrow_focus            # the row focus: a frame around it
    cmp rax, r12
    jne 4f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    PM edx, MI_20
    call frame
4:  test r13d, UB_CLICK
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call copy_response
9:  EPILOGUE

# frame(x, y, size): a 1 px T_ACCENT square frame
frame:
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov ecx, 1
    COLOR r8d, T_ACCENT
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rsp + 8]
    dec esi
    mov edx, [rsp + 8]
    mov ecx, 1
    COLOR r8d, T_ACCENT
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, 1
    mov ecx, [rsp + 8]
    COLOR r8d, T_ACCENT
    call gfx_fill
    mov edi, [rsp]
    add edi, [rsp + 8]
    dec edi
    mov esi, [rsp + 4]
    mov edx, 1
    mov ecx, [rsp + 8]
    COLOR r8d, T_ACCENT
    call gfx_fill
    EPILOGUE

# copy_response(AS*, row): the replies of the row's turn, its prompt's next row to this one, joined by blank
#   lines, to the clipboard; the toast "Copied."
copy_response:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + cs]
    call sb_clear
    imul rax, r12, AM_SIZE
    add rax, [rbx + AS_msgs + VEC_ptr]
    movsxd r13, dword ptr [rax + AM_turn]
    inc r13                     # (-1: from the first row)
1:  cmp r13, r12
    ja 5f
    imul r14, r13, AM_SIZE
    add r14, [rbx + AS_msgs + VEC_ptr]
    inc r13
    cmp dword ptr [r14 + AM_role], R_ASSIST
    jne 1b
    test dword ptr [r14 + AM_flags], AMF_QUEUED | AMF_PILL
    jnz 1b
    cmp qword ptr [r14 + AM_len], 0
    je 1b
    cmp qword ptr [rip + cs + SB_len], 0
    je 2f
    lea rdi, [rip + cs]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + cs]
    mov esi, 10
    call sb_push_byte
2:  lea rdi, [rip + cs]
    mov rsi, [r14 + AM_text]
    mov rdx, [r14 + AM_len]
    call sb_push
    jmp 1b
5:  mov rdi, [rip + cs + SB_ptr]
    mov rsi, [rip + cs + SB_len]
    xor edx, edx
    call ed_clip_set
    lea rdi, [rip + .Lcopied]
    call app_toast
    EPILOGUE

# FN agsel_resp(AS*, row) -> eax 1: Copy response of a reply that ends its turn (the row focus's Enter,
#   agent-row-click N resp), 0 for any other row or while its turn runs
FN agsel_resp
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call agsel_bar_h
    test eax, eax
    jz 9f
    lea rax, [r12 + 1]
    cmp rax, [rbx + AS_msgs + VEC_len]
    jne 1f
    mov rdi, rbx
    call works
    test eax, eax
    jnz 8f
1:  mov rdi, rbx
    mov rsi, r12
    call copy_response
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# ---------------- tests ----------------

# FN agsel_dump(sb): print-agent-selection: "row=N part=md|in|out|prompt|meta from=A|- to=B|- text=T" (T one
#   line: LF as \n, TAB as \t) or "none"; then "resp row=N X,Y,W,H" when a reply's Copy response was drawn in
#   the last frame of the conversation
FN agsel_dump
    PROLOGUE
    mov r15, rdi
    lea rdi, [rip + cs]
    call sb_clear
    lea rdi, [rip + cs]
    call sel_text
    test eax, eax
    jnz 1f
    mov rdi, r15
    lea rsi, [rip + .Ld_none]
    call sb_push_cstr
    jmp 5f
1:  mov rdi, r15
    lea rsi, [rip + .Ld_row]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rip + sel_row]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_part]
    call sb_push_cstr
    mov eax, [rip + sel_part]
    lea rsi, [rip + .Lp_md]
    cmp eax, SELP_MD
    je 2f
    lea rsi, [rip + .Lp_in]
    cmp eax, PART_IN
    je 2f
    lea rsi, [rip + .Lp_out]
    cmp eax, PART_OUT
    je 2f
    lea rsi, [rip + .Lp_prompt]
    cmp eax, SELP_PROMPT
    je 2f
    lea rsi, [rip + .Lp_meta]
2:  mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_from]
    call sb_push_cstr
    cmp dword ptr [rip + sel_part], SELP_MD
    jne 3f
    mov rdi, r15
    lea rsi, [rip + .Ld_nopos]
    call sb_push_cstr
    jmp 4f
3:  mov rax, [rip + sel_a]
    mov rbx, [rip + sel_b]
    cmp rax, rbx
    jbe 31f
    xchg rax, rbx
31: mov rdi, r15
    mov rsi, rax
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_to]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, rbx
    call sb_push_u64
4:  mov rdi, r15
    lea rsi, [rip + .Ld_text]
    call sb_push_cstr
    xor r12d, r12d              # its text, on one line
41: cmp r12, [rip + cs + SB_len]
    jae 44f
    mov rax, [rip + cs + SB_ptr]
    movzx esi, byte ptr [rax + r12]
    inc r12
    cmp esi, 10
    je 42f
    cmp esi, 9
    je 43f
    mov rdi, r15
    call sb_push_byte
    jmp 41b
42: mov rdi, r15
    lea rsi, [rip + .Ld_lf]
    call sb_push_cstr
    jmp 41b
43: mov rdi, r15
    lea rsi, [rip + .Ld_tab]
    call sb_push_cstr
    jmp 41b
44: mov rdi, r15
    mov esi, 10
    call sb_push_byte
5:  mov eax, [rip + resp_ser]   # the Copy response buttons drawn in the last frame
    cmp eax, [rip + th_serial]
    jne 9f
    xor r12d, r12d
6:  cmp r12d, [rip + resp_n]
    jae 9f
    mov rdi, r15
    lea rsi, [rip + .Ld_resp]
    call sb_push_cstr
    lea rax, [rip + resp_rows]
    mov rsi, [rax + r12*8]
    mov rdi, r15
    call sb_push_u64
    xor ebx, ebx
7:  mov rdi, r15
    mov esi, ' '
    test ebx, ebx
    jz 71f
    mov esi, ','
71: call sb_push_byte
    mov eax, r12d
    shl eax, 4
    lea rcx, [rip + resp_r]
    add rcx, rax
    mov esi, [rcx + rbx*4]
    mov rdi, r15
    call md_push_int
    inc ebx
    cmp ebx, 4
    jb 7b
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    inc r12d
    jmp 6b
9:  EPILOGUE

# FN agsel_cmd_select() -> rax 0, -1 a wrong row: agent-select N FROM TO [in|out] (its arguments: ai_arg): row N
#   (from 0) of the open conversation selected from byte FROM to TO of its plain text (a prompt, a meta line, a
#   call's IN or OUT), or all of a Markdown row's (FROM and TO are not read then)
FN agsel_cmd_select
    PROLOGUE 16
    call agents_viewed
    test rax, rax
    jz 8f
    mov rbx, rax
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov r12, rax
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 8f
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov [rsp], rax
    call ai_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov [rsp + 8], rax
    call ai_arg
    mov r14d, PART_IN           # a call's part
    test rdx, rdx
    jz 1f
    cmp byte ptr [rax], 'o'
    jne 1f
    mov r14d, PART_OUT
1:  imul r13, r12, AM_SIZE
    add r13, [rbx + AS_msgs + VEC_ptr]
    cmp qword ptr [r13 + AM_x], 0
    jne 3f
    mov r14d, SELP_PROMPT
    mov eax, [r13 + AM_role]
    cmp eax, R_USER
    je 3f
    mov r14d, SELP_META
    cmp eax, R_META
    je 3f
    mov rdi, [r13 + AM_doc]     # a Markdown row: all of it
    test rdi, rdi
    jz 8f
    call agsel_clear
    mov rdi, [r13 + AM_doc]
    call md_select_all
    mov [rip + sel_as], rbx
    mov [rip + sel_row], r12
    mov dword ptr [rip + sel_part], SELP_MD
    jmp 7f
3:  call agsel_clear
    mov rdi, r13
    mov esi, r14d
    call plain_of
    mov rax, [rsp]
    cmp rax, rdx
    cmova rax, rdx
    mov rcx, [rsp + 8]
    cmp rcx, rdx
    cmova rcx, rdx
    mov [rip + sel_a], rax
    mov [rip + sel_b], rcx
    mov [rip + sel_as], rbx
    mov [rip + sel_row], r12
    mov [rip + sel_part], r14d
7:  mov dword ptr [rip + sel_drag], 0
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

.section .rodata
.Lm_copy: .asciz "Copy"
.Lm_message: .asciz "Copy Message"
.Lm_link: .asciz "Copy Link"
.Lcopy_resp: .asciz "Copy response"
.Lcopied: .asciz "Copied."
.Ld_none: .asciz "none\n"
.Ld_row: .asciz "row="
.Ld_part: .asciz " part="
.Ld_from: .asciz " from="
.Ld_to: .asciz " to="
.Ld_nopos: .asciz "- to=-"
.Ld_text: .asciz " text="
.Ld_lf: .asciz "\\n"
.Ld_tab: .asciz "\\t"
.Ld_resp: .asciz "resp row="
.Lp_md: .asciz "md"
.Lp_in: .asciz "in"
.Lp_out: .asciz "out"
.Lp_prompt: .asciz "prompt"
.Lp_meta: .asciz "meta"
