# The agents panel's dialog shell (generic): one modal dialog over the whole panel, in the panel's faces and
# metrics (ext-webview-ui.md 6.21: the extension's `ir`). Every dialog of a driver is built from it; it
# knows no agent. One dialog at a time: opening one closes the one before.
#
# How a dialog is made (a driver, or anything else of the panel's):
#   agentdlg_open(AS* or 0, name cstr, title cstr, ops*) -> eax 1   it shows at once, "loading" with no
#     text; name is what print-agent-dialog says (static); ops a static table: DGO_act (act, arg, DGR* or
#     0): a row's, a button's or the back arrow's act (acts from 1; DA_ASK (-2) when the driver should
#     send its request now: agentdlg_pend's wait is over); DGO_free (): the dialog closes (keep nothing
#     of it after). The title is copied
#   agentdlg_loading(cstr)                  loading: that text (muted), rows and buttons hidden
#   agentdlg_fail(ptr, len)                 error: that text (the error colour) above whatever rows and
#                                           buttons it has (a Retry button is the dialog's own)
#   agentdlg_begin()                        ready, rows and buttons emptied: build them again (the scroll and
#                                           the focus stay where they were, as near as the rows allow)
#   agentdlg_row(kind DGK_*, flags DGF_*, act) -> rax DGR*   a row (rhun.inc: DGR_val, DGR_act2, DGR_arg are
#     the caller's to set); agentdlg_text(DGR*, which 0..2, ptr, len) / agentdlg_ctext(DGR*, which, cstr)
#     its texts, copied. Kinds: HEAD (t1 a section's title, t3 a hint at its right), PAIR (t1 label, t2
#     value, side by side or stacked when narrow), TEXT (t1 wrapped; DGF_MUTED, DGF_ERROR, DGF_SMALL),
#     BAR (t1 label, DGR_val percent 0..100, t3 a line under the track), ITEM (t1, t2 a muted line under,
#     t3 at the right; DGF_CHECK a check mark; DGF_STATE: t3 is a pill whose click, or Space, is DGR_act2),
#     TOGGLE (t1, a switch on with DGF_ON, t2 a muted line), COLS (t1 left, t2 and t3 right-aligned
#     columns; DGF_SWATCH: DGR_val an ARGB square before t1; DGF_MUTED the table's header), LINK (t1 in
#     the link colour), GAP. ITEM, TOGGLE and LINK take the focus and the keys (not with DGF_OFF)
#   agentdlg_button(label cstr, act, flags DBF_*) -> rax DB*   a footer button (DBF_PRIMARY; DBF_NUM: the
#     footer's buttons are numbered "1 Label", and the digit keys press them)
#   agentdlg_filter(placeholder cstr)       a filter field under the title: rows with DGF_FILTER show only
#     while their t1 or t2 holds its text (case-insensitive); it keeps its text across agentdlg_begin
#   agentdlg_back(act)                      a back arrow before the title; Escape is that act (0: none)
#   agentdlg_title(cstr), agentdlg_focus(n) (the n-th focusable, from 0; -1 none)
#   A new dialog's rows: build them after agentdlg_open (agentdlg_begin first) or when the answer comes;
#   the rows' texts are copied, so a parse arena's strings may be passed. An act may rebuild the rows or
#   close the dialog: nothing of a row is touched after its act returns. Ids: ID_AGDLG (rhun.inc), to
#   0x8fff. The headless commands (aictl.s's block): agent-dialog NAME|test, agent-dialog-pick N,
#   agent-dialog-press N, agent-dialog-filter TEXT, agent-dialog-close, print-agent-dialog [fit]
#   agentdlg_set_val(DGR*, val)               a row's value changed (a switch flipped by the caller)
# Asking the driver and getting the answer later: the driver writes its request and calls
#   agentdlg_wait(AL*, n) (n: its own number for that request); its answer comes to the driver, which
#   asks agentdlg_waits(AL*, n) -> eax 1 (the open dialog was waiting for it: the wait is over) before
#   it fills the dialog. A dialog whose process is still starting calls agentdlg_pend(AL*): once the
#   driver is ready (ev_ready -> agentdlg_ready) the dialog's DGO_act gets DA_ASK. Process gone
#   (agentdlg_ended, from agent_state_set): a dialog waiting for it fails ("NAME ended before it
#   answered."), one shown for its conversation closes. Conversation gone (agentdlg_gone, freed) or no
#   longer the panel's open one: it closes.
# Keys (agentdlg_key, first in agents_key and agentext_input_key): Escape closes (or goes back); Tab and
#   Shift+Tab, Down and Up move the focus round the field, the rows and the buttons; Enter activates the
#   focused one (in the field: the first row shown); Space a row (DGF_STATE: its pill); 1..9 a numbered
#   button; Page Up, Page Down, Home, End scroll; typed text goes to the filter field. Shortcuts with
#   Ctrl, Alt or Super go on. Mouse: a row or button clicked is activated, the wheel scrolls the body, a
#   press outside the box (inside the panel) closes it, × closes. The panel under it takes no pointer.
# Focus: opening takes the keyboard (FOCUS_AGENTS); closing gives it to the prompt box when the panel
#   shows a driven conversation, else back where it was.
# Speed: nothing runs while it shows (no timer); the rows' layout is made again only when the width, the
#   panel's text size, the rows or the filter change; only the rows in view are drawn.
#
#   agentdlg_shield(), agentdlg_draw(x, y, w, h)   agents_draw: before the panel's content, after it
#   agentdlg_key(keysym, cp, mods) -> eax 1 taken
#   agentdlg_field() -> rax its filter field while it has the keys (else agentcard_field's)
#   agentdlg_paste(ptr, len)                 a paste in the panel: into the filter, else agentcard_paste
#   agentdlg_close(), agentdlg_is(name cstr) -> eax, agentdlg_as() -> rax, agentdlg_open_now() -> eax
#   agentdlg_gone(ptr), agentdlg_ended(AL*), agentdlg_ready(AL*)   the seam's hooks
#   agentdlg_pick(n) -> eax 1   the n-th focusable (from 1) as Enter; agentdlg_press(n) button n (from 1);
#   agentdlg_set_filter(ptr, len); agentdlg_dump(sb) print-agent-dialog; agentdlg_fit_dump(sb) its
#   layout at panel sizes 8, 13, 32 and widths 240 to 900 (headless)
.include "rhun.inc"

.equ DID_CLOSE, 1               # ID_AGDLG + : the ×, the back arrow, the field, the scrollbar, the overlay
.equ DID_BACK, 2
.equ DID_FIELD, 3
.equ DID_SCROLL, 4
.equ DID_OVER, 5
.equ DID_BTN, 0x10              #   a button (0x10..0x1f)
.equ DID_ROW, 0x20              #   a focusable row (0x20..0xff)
.equ DID_PILL, 0x100            #   a row's pill (0x100..0x1ff)
.equ BTN_IDS, 16
.equ ROW_IDS, 0xe0
.equ PILL_IDS, 0x100
.equ FT_FIELD, 1                # the focus list's entries: type << 24 | index
.equ FT_ROW, 2
.equ FT_BTN, 3
.equ LINES_MAX, 200             # a wrapped text's lines at most
.equ DS_LOADING, 0
.equ DS_READY, 1
.equ DS_ERROR, 2
.equ DB_SIZE, 48
.equ DB_label, 0
.equ DB_act, 8
.equ DB_flags, 12
.equ DB_x, 16
.equ DB_y, 20
.equ DB_w, 24
.equ DB_h, 28
.equ DB_row, 32                 # its footer row (fit)
.equ SIZES_N, 3
.equ TEST_ITEMS, 40             # agent-dialog test: its list's rows
.equ TA_FIRST, 1                # its acts
.equ TA_TOGGLE, 2
.equ TA_STATE, 3
.equ TA_OK, 4
.equ TA_BACK, 5

.data
.p2align 2
dg_focus: .long -1              # index in dg_foc, -1 none

.bss
.p2align 3
dg_tf: .zero TF_SIZE            # the filter field
dg_msg: .zero SB_SIZE           # the loading or error text
dg_rows: .zero VEC_SIZE         # DR
dg_btns: .zero VEC_SIZE         # DB
dg_foc: .zero VEC_SIZE          # u32: the focusable things in order (type << 24 | index)
dsb: .zero SB_SIZE              # scratch (dumps, the ended text)
dg_as: .quad 0                  # the conversation it was opened for, 0 none
dg_ops: .quad 0
dg_name: .quad 0                # static cstr
dg_title: .quad 0               # owned cstr
dg_ph: .quad 0                  # the filter's placeholder (static), 0: no filter
dg_al: .quad 0                  # the live record it waits for (agentdlg_wait / _pend), 0 none
dg_req: .quad 0                 # the request it waits for (the driver's number)
dg_fkey: .quad 0                # the focused entry, kept across a rebuild
dg_lay_rev: .quad 0             # the layout's inputs as made last
dg_rev: .quad 0                 # the rows' revision (every row, text and begin)
dg_lay_frev: .quad 0
dg_lay_face: .quad 0
dg_open: .long 0
dg_state: .long 0
dg_pend: .long 0                # 1: it waits for dg_al to be ready (DA_ASK)
dg_back: .long 0                # the back arrow's act, 0 none
dg_scroll: .long 0
dg_max: .long 0
dg_content: .long 0             # the body's whole height
dg_reveal: .long 0              # the focused row is brought into view at the next draw
dg_prev: .long 0                # the focus before it opened
dg_num: .long 0                 # its buttons are numbered
dg_lay_w: .long 0
dg_lay_px: .long 0
dg_drawn: .long 0               # it was drawn (box rect valid)
dg_acted: .long 0               # agent-dialog test: the last act
dg_test_on: .long 0             # agent-dialog test: its switch
dg_test_state: .long 0
dg_rect: .zero 16               # the box as drawn last: x, y, w, h
dg_body: .zero 16               # the body as drawn last
dg_panel: .zero 16              # the panel as drawn last
# geom's results (from the panel's x, y, w, h)
g_bx: .long 0
g_by: .long 0
g_bw: .long 0
g_bh: .long 0
g_head: .long 0                 # the title row's height
g_fh: .long 0                   # the filter field's height (0 none)
g_foot: .long 0                 # the footer's height (0 none)
g_bodyy: .long 0
g_bodyh: .long 0
g_pad: .long 0
g_tw: .long 0                   # the rows' width
g_brows: .long 0                # the footer's rows of buttons

.text

# ---- state ----

# FN agentdlg_open_now() -> eax 1 while a dialog is open
FN agentdlg_open_now
    mov eax, [rip + dg_open]
    ret

# FN agentdlg_as() -> rax the conversation the open dialog belongs to (0: none, or closed)
FN agentdlg_as
    xor eax, eax
    cmp dword ptr [rip + dg_open], 0
    je 1f
    mov rax, [rip + dg_as]
1:  ret

# FN agentdlg_is(name cstr) -> eax 1 when the open dialog is that one
FN agentdlg_is
    xor eax, eax
    cmp dword ptr [rip + dg_open], 0
    je 1f
    mov rsi, [rip + dg_name]
    test rsi, rsi
    jz 1f
    jmp strcmp_eq
1:  ret

# FN agentdlg_open(AS* or 0, name cstr, title cstr, ops*) -> eax 1: the one before closes; this one shows
#   loading, takes the keyboard
FN agentdlg_open
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    call agentdlg_close
    call agentpop_close         # a popup of the box's would sit over it
    mov [rip + dg_as], rbx
    mov [rip + dg_name], r12
    mov [rip + dg_ops], r14
    mov rdi, r13
    call cdup
    mov [rip + dg_title], rax
    mov qword ptr [rip + dg_ph], 0
    mov qword ptr [rip + dg_al], 0
    mov qword ptr [rip + dg_req], 0
    mov qword ptr [rip + dg_fkey], 0
    mov dword ptr [rip + dg_pend], 0
    mov dword ptr [rip + dg_back], 0
    mov dword ptr [rip + dg_focus], -1
    mov dword ptr [rip + dg_scroll], 0
    mov dword ptr [rip + dg_num], 0
    mov dword ptr [rip + dg_drawn], 0
    mov dword ptr [rip + dg_state], DS_LOADING
    lea rdi, [rip + dg_msg]
    call sb_clear
    lea rdi, [rip + dg_tf]
    call tf_clear
    mov dword ptr [rip + dg_tf + TF_id], ID_AGDLG + DID_FIELD
    call clear_rows
    inc qword ptr [rip + dg_rev]
    mov eax, [rip + g_focus]
    mov [rip + dg_prev], eax
    mov dword ptr [rip + dg_open], 1
    cmp dword ptr [rip + g_show_agents], 0
    je 1f
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
1:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE

# FN agentdlg_close(): the open dialog goes (its DGO_free first); the keyboard goes to the prompt box when
#   the panel shows a driven conversation, else back where it was
FN agentdlg_close
    PROLOGUE
    cmp dword ptr [rip + dg_open], 0
    je 9f
    mov dword ptr [rip + dg_open], 0
    mov rax, [rip + dg_ops]
    test rax, rax
    jz 1f
    mov rax, [rax + DGO_free]
    test rax, rax
    jz 1f
    call rax
1:  call clear_rows
    mov rdi, [rip + dg_title]
    call mem_free
    mov qword ptr [rip + dg_title], 0
    mov qword ptr [rip + dg_as], 0
    mov qword ptr [rip + dg_al], 0
    mov qword ptr [rip + dg_ops], 0
    mov dword ptr [rip + dg_pend], 0
    mov dword ptr [rip + dg_drawn], 0
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    jne 8f
    call agents_open_driven
    test rax, rax
    jz 2f
    mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT   # the extension's: focus back to the composer
    jmp 8f
2:  mov eax, [rip + dg_prev]
    cmp eax, FOCUS_AGENT_INPUT
    jne 8f
    mov [rip + g_focus], eax
8:  mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# clear_rows(): rows and buttons emptied (their strings freed)
clear_rows:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + dg_rows + VEC_len]
    jae 2f
    imul r12, rbx, DGR_SIZE
    add r12, [rip + dg_rows + VEC_ptr]
    mov rdi, [r12 + DGR_t1]
    call mem_free
    mov rdi, [r12 + DGR_t2]
    call mem_free
    mov rdi, [r12 + DGR_t3]
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + dg_rows + VEC_len], 0
    xor ebx, ebx
3:  cmp rbx, [rip + dg_btns + VEC_len]
    jae 4f
    imul r12, rbx, DB_SIZE
    add r12, [rip + dg_btns + VEC_ptr]
    mov rdi, [r12 + DB_label]
    call mem_free
    inc rbx
    jmp 3b
4:  mov qword ptr [rip + dg_btns + VEC_len], 0
    mov dword ptr [rip + dg_num], 0
    inc qword ptr [rip + dg_rev]
    EPILOGUE

# cdup(cstr or 0) -> rax an owned copy (0 for 0)
cdup:
    test rdi, rdi
    jz 1f
    push rbx
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    pop rbx
    jmp mem_dup
1:  xor eax, eax
    ret

# FN agentdlg_title(cstr): the title changes
FN agentdlg_title
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rip + dg_title]
    call mem_free
    mov rdi, rbx
    call cdup
    mov [rip + dg_title], rax
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agentdlg_loading(cstr): loading with that text; rows and buttons hidden
FN agentdlg_loading
    PROLOGUE
    mov rbx, rdi
    mov dword ptr [rip + dg_state], DS_LOADING
    lea rdi, [rip + dg_msg]
    call sb_clear
    test rbx, rbx
    jz 1f
    lea rdi, [rip + dg_msg]
    mov rsi, rbx
    call sb_push_cstr
1:  inc qword ptr [rip + dg_rev]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agentdlg_fail(ptr, len): the error state with that text (its rows and buttons stay)
FN agentdlg_fail
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov dword ptr [rip + dg_state], DS_ERROR
    lea rdi, [rip + dg_msg]
    call sb_clear
    lea rdi, [rip + dg_msg]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    inc qword ptr [rip + dg_rev]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agentdlg_begin(): ready, with no rows and no buttons yet (the scroll and the focus are kept)
FN agentdlg_begin
    PROLOGUE
    call clear_rows
    mov dword ptr [rip + dg_state], DS_READY
    lea rdi, [rip + dg_msg]
    call sb_clear
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agentdlg_row(kind, flags, act) -> rax DR* (zeroed but for those; valid until the next row)
FN agentdlg_row
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    lea rdi, [rip + dg_rows]
    mov esi, DGR_SIZE
    call vec_push
    mov [rax + DGR_kind], ebx
    mov [rax + DGR_flags], r12d
    mov [rax + DGR_act], r13d
    inc qword ptr [rip + dg_rev]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agentdlg_text(DGR*, which 0..2, ptr, len): a text of the row, copied (control characters become spaces)
FN agentdlg_text
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, 2
    ja 9f
    mov rdi, r13
    mov rsi, r14
    call mem_dup
    xor ecx, ecx
1:  cmp rcx, r14
    jae 2f
    cmp byte ptr [rax + rcx], 9
    jne 11f
    mov byte ptr [rax + rcx], ' '
11: inc rcx
    jmp 1b
2:  lea rcx, [rbx + DGR_t1 + r12*8]
    mov rdx, rax
    mov rdi, [rcx]
    mov [rcx], rdx
    call mem_free
    inc qword ptr [rip + dg_rev]
9:  EPILOGUE

# FN agentdlg_ctext(DGR*, which, cstr)
FN agentdlg_ctext
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov rcx, rax
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r13
    call agentdlg_text
    EPILOGUE

# FN agentdlg_set_val(DGR*, val): the row's value changes (a switch, a bar)
FN agentdlg_set_val
    mov [rdi + DGR_val], rsi
    inc qword ptr [rip + dg_rev]
    mov dword ptr [rip + g_dirty], 1
    ret

# FN agentdlg_button(label cstr, act, flags DBF_*) -> rax DB*
FN agentdlg_button
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    test r13d, DBF_NUM
    jz 1f
    mov dword ptr [rip + dg_num], 1
1:  lea rdi, [rip + dg_btns]
    mov esi, DB_SIZE
    call vec_push
    mov r14, rax
    mov [r14 + DB_act], r12d
    mov [r14 + DB_flags], r13d
    mov rdi, rbx
    call cdup
    mov [r14 + DB_label], rax
    inc qword ptr [rip + dg_rev]
    mov dword ptr [rip + g_dirty], 1
    mov rax, r14
    EPILOGUE

# FN agentdlg_filter(placeholder cstr): a filter field under the title (the focus starts there)
FN agentdlg_filter
    mov [rip + dg_ph], rdi
    mov dword ptr [rip + dg_focus], 0
    mov qword ptr [rip + dg_fkey], FT_FIELD << 24
    inc qword ptr [rip + dg_rev]
    mov dword ptr [rip + g_dirty], 1
    ret

# FN agentdlg_back(act): the back arrow and Escape's act (0: none, Escape closes)
FN agentdlg_back
    mov [rip + dg_back], edi
    mov dword ptr [rip + g_dirty], 1
    ret

# FN agentdlg_focus(n): the n-th focusable (from 0) has the focus (-1: none)
FN agentdlg_focus
    mov [rip + dg_focus], edi
    mov qword ptr [rip + dg_fkey], -1   # relayout keeps the index, not an entry
    mov dword ptr [rip + dg_reveal], 1
    mov dword ptr [rip + g_dirty], 1
    ret

# ---- the driver's waits ----

# FN agentdlg_wait(AL*, n): the open dialog waits for the answer to the driver's request n
FN agentdlg_wait
    cmp dword ptr [rip + dg_open], 0
    je 1f
    mov [rip + dg_al], rdi
    mov [rip + dg_req], rsi
    mov dword ptr [rip + dg_pend], 0
1:  ret

# FN agentdlg_waits(AL*, n) -> eax 1 when the open dialog waits for that answer (the wait is then over)
FN agentdlg_waits
    xor eax, eax
    cmp dword ptr [rip + dg_open], 0
    je 1f
    cmp dword ptr [rip + dg_pend], 0
    jne 1f
    cmp [rip + dg_al], rdi
    jne 1f
    test rdi, rdi
    jz 1f
    cmp [rip + dg_req], rsi
    jne 1f
    mov qword ptr [rip + dg_al], 0
    mov qword ptr [rip + dg_req], 0
    mov eax, 1
1:  ret

# FN agentdlg_pend(AL*): the open dialog waits for that driver to be ready (then DGO_act DA_ASK)
FN agentdlg_pend
    cmp dword ptr [rip + dg_open], 0
    je 1f
    mov [rip + dg_al], rdi
    mov qword ptr [rip + dg_req], 0
    mov dword ptr [rip + dg_pend], 1
1:  ret

# FN agentdlg_ready(AL*): the driver of that record is ready (ev_ready): a dialog pending on it asks now
FN agentdlg_ready
    PROLOGUE
    cmp dword ptr [rip + dg_open], 0
    je 9f
    cmp dword ptr [rip + dg_pend], 0
    je 9f
    cmp [rip + dg_al], rdi
    jne 9f
    mov dword ptr [rip + dg_pend], 0
    mov qword ptr [rip + dg_al], 0
    mov edi, DA_ASK
    xor esi, esi
    xor edx, edx
    call do_act
9:  EPILOGUE

# FN agentdlg_ended(AL*): that record's process ended (OFF or FAILED): a dialog waiting for it fails with
#   "NAME ended before it answered." (NAME its driver's: the start's report first when there is one), one
#   shown for its conversation closes
FN agentdlg_ended
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + dg_open], 0
    je 9f
    cmp [rip + dg_al], rbx
    jne 5f
    mov qword ptr [rip + dg_al], 0
    mov dword ptr [rip + dg_pend], 0
    lea rdi, [rip + dsb]
    call sb_clear
    mov rdx, [rbx + AL_report + SB_len]
    test rdx, rdx
    jz 1f
    lea rdi, [rip + dsb]        # the start failed: its own words
    mov rsi, [rbx + AL_report + SB_ptr]
    call sb_push
    jmp 3f
1:  mov rax, [rbx + AL_drv]
    lea rsi, [rip + .Lagent]
    test rax, rax
    jz 2f
    mov rsi, [rax + DRV_name]
2:  lea rdi, [rip + dsb]
    call sb_push_cstr
    lea rdi, [rip + dsb]
    lea rsi, [rip + .Lended]
    call sb_push_cstr
3:  mov rdi, [rip + dsb + SB_ptr]
    mov rsi, [rip + dsb + SB_len]
    call agentdlg_fail
    jmp 9f
5:  mov rax, [rip + dg_as]      # shown for its conversation: its process went, so does the dialog
    test rax, rax
    jz 9f
    cmp [rbx + AL_as], rax
    jne 9f
    cmp dword ptr [rip + dg_state], DS_ERROR
    je 9f                       # (an error stays to be read)
    call agentdlg_close
9:  EPILOGUE

# FN agentdlg_gone(ptr): an AS (or anything) is freed: the dialog opened for it closes
FN agentdlg_gone
    cmp dword ptr [rip + dg_open], 0
    je 1f
    test rdi, rdi
    jz 1f
    cmp [rip + dg_as], rdi
    jne 2f
    jmp agentdlg_close
2:  mov rax, [rip + dg_al]
    test rax, rax
    jz 1f
    cmp rax, rdi
    jne 1f
    mov qword ptr [rip + dg_al], 0
1:  ret

# do_act(act, arg, DR* or 0): DA_CLOSE closes, else the dialog's DGO_act
do_act:
    PROLOGUE
    mov dword ptr [rip + g_dirty], 1
    cmp edi, DA_CLOSE
    jne 1f
    call agentdlg_close
    jmp 9f
1:  mov rax, [rip + dg_ops]
    test rax, rax
    jz 9f
    mov rax, [rax + DGO_act]
    test rax, rax
    jz 9f
    call rax
9:  EPILOGUE

# ---- text helpers ----

# wrap1(face, ptr, len, w) -> rax the first line's bytes, rdx the bytes it takes (its break too)
wrap1:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    xor ecx, ecx                # the first line end
1:  cmp rcx, r13
    jae 2f
    cmp byte ptr [r12 + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov r15, rcx
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    mov ecx, r14d
    call text_fit
    cmp rax, r15
    jb 3f
    mov rax, r15                # the whole line fits
    mov rdx, r15
    cmp r15, r13
    jae 9f
    inc rdx
    jmp 9f
3:  mov rcx, rax                # the last blank inside what fits
4:  test rcx, rcx
    jz 5f
    cmp byte ptr [r12 + rcx], ' '
    je 6f
    dec rcx
    jmp 4b
6:  mov rax, rcx
    lea rdx, [rcx + 1]
    jmp 9f
5:  test rax, rax               # none: what fits, one character at least
    jnz 7f
    mov rax, 1
8:  cmp rax, r15
    jae 7f
    movzx ecx, byte ptr [r12 + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne 7f
    inc rax
    jmp 8b
7:  mov rdx, rax
9:  EPILOGUE

# lines_of(face, ptr, len, w) -> eax its lines wrapped at w (1 for an empty text)
lines_of:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    xor r15d, r15d
1:  inc r15d
    test r13, r13
    jz 9f
    cmp r15d, LINES_MAX
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, r14d
    call wrap1
    add r12, rdx
    sub r13, rdx
    test r13, r13
    jnz 1b
9:  mov eax, r15d
    EPILOGUE

# draw_wrap(face, x, y, w, ptr, len, [argb]) -> eax lines: the text wrapped at w from y down
draw_wrap:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov r12, r8
    mov r13, r9
    mov eax, [rbp + 16]
    mov [rsp + 12], eax
    xor r15d, r15d
1:  inc r15d
    test r13, r13
    jz 9f
    cmp r15d, LINES_MAX
    ja 9f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, [rsp + 8]
    call wrap1
    mov r14, rdx
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rbx + FACE_ascent]
    mov rcx, r12
    mov r8, rax
    mov r9d, [rsp + 12]
    call text_draw
    mov eax, [rbx + FACE_lineh]
    add [rsp + 4], eax
    add r12, r14
    sub r13, r14
    test r13, r13
    jnz 1b
9:  mov eax, r15d
    EPILOGUE

# cwidth(face, cstr or 0) -> eax its width
cwidth:
    test rsi, rsi
    jz 1f
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call text_width
    add rsp, 8
    pop r12
    pop rbx
    ret
1:  xor eax, eax
    ret

# ci_has(hay ptr, len, needle ptr, len) -> eax 1 when the needle is in the hay, ASCII case ignored
ci_has:
    push rbx
    mov eax, 1
    test rcx, rcx
    jz 9f
    xor r8d, r8d
1:  mov rax, rsi
    sub rax, r8
    cmp rax, rcx
    jb 8f
    xor r9d, r9d
2:  cmp r9, rcx
    jae 7f
    lea rax, [rdi + r8]
    movzx eax, byte ptr [rax + r9]
    movzx ebx, byte ptr [rdx + r9]
    lea r10d, [rax - 'A']
    cmp r10d, 25
    ja 3f
    or eax, 0x20
3:  lea r10d, [rbx - 'A']
    cmp r10d, 25
    ja 4f
    or ebx, 0x20
4:  cmp eax, ebx
    jne 5f
    inc r9
    jmp 2b
5:  inc r8
    jmp 1b
7:  mov eax, 1
    jmp 9f
8:  xor eax, eax
9:  pop rbx
    ret

# shown(DR*) -> eax 1 when the filter lets the row show
shown:
    PROLOGUE
    mov rbx, rdi
    mov eax, 1
    test dword ptr [rbx + DGR_flags], DGF_FILTER
    jz 9f
    cmp qword ptr [rip + dg_ph], 0
    je 9f
    lea rdi, [rip + dg_tf]
    call tf_text
    mov r12, rax
    mov r13, rdx
    mov eax, 1
    test r13, r13
    jz 9f
    mov r14, [rbx + DGR_t1]
    test r14, r14
    jz 1f
    mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    mov rdx, r12
    mov rcx, r13
    call ci_has
    test eax, eax
    jnz 9f
1:  mov r14, [rbx + DGR_t2]
    xor eax, eax
    test r14, r14
    jz 9f
    mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    mov rdx, r12
    mov rcx, r13
    call ci_has
9:  EPILOGUE

# focusable(DR*) -> eax 1 for a row that takes the focus
focusable:
    xor eax, eax
    test dword ptr [rdi + DGR_flags], DGF_OFF
    jnz 1f
    mov ecx, [rdi + DGR_kind]
    cmp ecx, DGK_ITEM
    je 2f
    cmp ecx, DGK_TOGGLE
    je 2f
    cmp ecx, DGK_LINK
    je 2f
    cmp ecx, DGK_FIELD          # claude-chat-p7b: the form rows (agentdlg2.s)
    jb 1f
2:  mov eax, 1
1:  ret

# row_at(i) -> rax DR*
row_at:
    imul rax, rdi, DGR_SIZE
    add rax, [rip + dg_rows + VEC_ptr]
    ret

# btn_at(i) -> rax DB*
btn_at:
    imul rax, rdi, DB_SIZE
    add rax, [rip + dg_btns + VEC_ptr]
    ret

# ---- layout ----

# geom(x, y, w, h): the box in the panel, its parts, and the rows' layout at its width (g_*)
geom:
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    PM r12d, MI_16              # the margin round it
    cmp edx, 400
    jge 1f
    PM r12d, MI_8
1:  mov eax, edx
    sub eax, r12d
    sub eax, r12d
    PM ecx, MI_64               # at most 9 x 64 (560 at 1x, as the extension's widest)
    imul ecx, ecx, 9
    cmp eax, ecx
    cmovg eax, ecx
    cmp eax, 1
    jge 2f
    mov eax, 1
2:  mov [rip + g_bw], eax
    mov ecx, [rsp + 8]
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp]
    mov [rip + g_bx], ecx
    PM ecx, MI_16               # inner padding
    cmp eax, 320
    jge 3f
    PM ecx, MI_10
3:  mov [rip + g_pad], ecx
    mov rdx, [rip + ag_fui]
    mov edx, [rdx + FACE_lineh]
    PM esi, MI_28               # the title row: the × button's size at least
    cmp edx, esi
    cmovl edx, esi
    PM esi, MI_8
    lea edx, [rdx + rsi*2]
    mov [rip + g_head], edx
    xor edx, edx
    cmp qword ptr [rip + dg_ph], 0
    je 4f
    mov rax, [rip + ag_fui]
    mov [rip + dg_tf + TF_face], rax
    lea rdi, [rip + dg_tf]
    call ta_line_h_of
    PM ecx, MI_12
    lea edx, [rax + rcx]
    PM ecx, MI_8
    add edx, ecx                # the field and a gap under it
4:  mov [rip + g_fh], edx
    mov eax, [rip + g_bw]       # the rows' width (the scrollbar's strip kept)
    sub eax, [rip + g_pad]
    sub eax, [rip + g_pad]
    sub eax, [rip + g_pmt + 4*MI_6]
    cmp eax, 1
    jge 5f
    mov eax, 1
5:  mov [rip + g_tw], eax
    call foot_layout            # the footer's buttons in rows (g_foot, g_brows)
    mov edi, [rip + g_tw]
    call layout                 # the rows (dg_content)
    mov eax, [rsp + 12]         # the body: what the panel leaves
    sub eax, r12d
    sub eax, r12d
    sub eax, [rip + g_head]
    sub eax, [rip + g_fh]
    sub eax, [rip + g_foot]
    PM ecx, MI_12
    sub eax, ecx                # the body's bottom padding
    mov ecx, [rip + dg_content]
    cmp ecx, eax
    cmovl eax, ecx
    PM ecx, MI_20               # a body of two lines at least, even in a short panel
    cmp eax, ecx
    jge 6f
    mov eax, ecx
6:  mov [rip + g_bodyh], eax
    mov ecx, [rip + dg_content]
    sub ecx, eax
    jns 61f
    xor ecx, ecx
61: mov [rip + dg_max], ecx
    mov edx, [rip + g_head]
    add edx, [rip + g_fh]
    add edx, eax
    add edx, [rip + g_foot]
    PM ecx, MI_12
    add edx, ecx
    mov [rip + g_bh], edx
    mov eax, [rsp + 12]         # a third of what is left above it, the margin at least
    sub eax, edx
    xor edx, edx
    mov ecx, 3
    cmp eax, 0
    jge 7f
    xor eax, eax
7:  cdq
    idiv ecx
    cmp eax, r12d
    jge 8f
    mov eax, r12d
8:  add eax, [rsp + 4]
    mov [rip + g_by], eax
    add eax, [rip + g_head]
    add eax, [rip + g_fh]
    mov [rip + g_bodyy], eax
    mov eax, [rip + dg_scroll]  # the scroll within what there is
    cmp eax, [rip + dg_max]
    jle 9f
    mov eax, [rip + dg_max]
9:  test eax, eax
    jns 10f
    xor eax, eax
10: mov [rip + dg_scroll], eax
    EPILOGUE

# btn_label(DB*, i) -> rax ptr, rdx len of its label as drawn ("N Label" when numbered) in dsb
btn_label:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [rip + dsb]
    call sb_clear
    cmp dword ptr [rip + dg_num], 0
    je 1f
    cmp r12d, 9
    jae 1f
    lea rdi, [rip + dsb]
    lea esi, [r12 + 1]
    call sb_push_u64
    lea rdi, [rip + dsb]
    mov esi, ' '
    call sb_push_byte
1:  mov rsi, [rbx + DB_label]
    test rsi, rsi
    jz 2f
    lea rdi, [rip + dsb]
    call sb_push_cstr
2:  mov rax, [rip + dsb + SB_ptr]
    mov rdx, [rip + dsb + SB_len]
    EPILOGUE

# foot_layout(): the buttons' sizes and rows (from the box's inner left, row 0 first): g_foot, g_brows
foot_layout:
    PROLOGUE 16
    mov dword ptr [rip + g_foot], 0
    mov dword ptr [rip + g_brows], 0
    cmp dword ptr [rip + dg_state], DS_LOADING
    je 9f
    cmp qword ptr [rip + dg_btns + VEC_len], 0
    je 9f
    mov eax, [rip + g_bw]
    sub eax, [rip + g_pad]
    sub eax, [rip + g_pad]
    mov [rsp], eax              # the room of a row
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_10]
    mov [rsp + 4], eax          # a button's height
    xor r12d, r12d              # x in the row
    xor r13d, r13d              # the row
    xor ebx, ebx
1:  cmp rbx, [rip + dg_btns + VEC_len]
    jae 5f
    mov rdi, rbx
    call btn_at
    mov r14, rax
    mov rdi, rax
    mov esi, ebx
    call btn_label
    mov rdi, [rip + ag_fui]
    mov rsi, rax
    call text_width
    PM ecx, MI_12
    lea eax, [rax + rcx*2]
    cmp eax, [rsp]
    jle 2f
    mov eax, [rsp]              # wider than a row: cut to it
2:  mov [r14 + DB_w], eax
    mov ecx, [rsp + 4]
    mov [r14 + DB_h], ecx
    test r12d, r12d
    jz 3f
    mov ecx, r12d
    add ecx, eax
    cmp ecx, [rsp]
    jle 3f
    inc r13d                    # the next row
    xor r12d, r12d
3:  mov [r14 + DB_x], r12d
    mov [r14 + DB_row], r13d
    add r12d, eax
    add r12d, [rip + g_pmt + 4*MI_8]
    inc rbx
    jmp 1b
5:  inc r13d
    mov [rip + g_brows], r13d
    mov eax, [rsp + 4]
    imul eax, r13d
    PM ecx, MI_6
    lea edx, [r13 - 1]
    imul ecx, edx
    add eax, ecx
    PM ecx, MI_12
    add eax, ecx                # a gap above
    mov [rip + g_foot], eax
9:  EPILOGUE

# layout(tw): every row's y and height at that width (again only when an input changed); the focus list
layout:
    PROLOGUE 16
    mov [rsp], edi
    mov rax, [rip + dg_rev]
    cmp rax, [rip + dg_lay_rev]
    jne 1f
    cmp edi, [rip + dg_lay_w]
    jne 1f
    mov rax, [rip + ag_fui]
    cmp rax, [rip + dg_lay_face]
    jne 1f
    mov rax, [rip + dg_tf + TF_revision]
    cmp rax, [rip + dg_lay_frev]
    jne 1f
    mov rax, [rip + ag_fui]     # the face's size: the panel's text size may move under the same face
    mov eax, [rax + FACE_px]
    cmp eax, [rip + dg_lay_px]
    je 9f
1:  mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_px]
    mov [rip + dg_lay_px], eax
    mov rax, [rip + dg_rev]
    mov [rip + dg_lay_rev], rax
    mov [rip + dg_lay_w], edi
    mov rax, [rip + ag_fui]
    mov [rip + dg_lay_face], rax
    mov rax, [rip + dg_tf + TF_revision]
    mov [rip + dg_lay_frev], rax
    mov rax, [rip + dg_fkey]    # the focused entry before
    mov [rsp + 8], rax
    mov qword ptr [rip + dg_foc + VEC_len], 0
    cmp qword ptr [rip + dg_ph], 0
    je 2f
    lea rdi, [rip + dg_foc]
    mov esi, 4
    call vec_push
    mov dword ptr [rax], FT_FIELD << 24
2:  xor r12d, r12d              # y
    mov rdx, [rip + dg_msg + SB_len]
    test rdx, rdx
    jz 3f
    mov rdi, [rip + ag_fui]     # the loading or error text first
    mov rsi, [rip + dg_msg + SB_ptr]
    mov ecx, [rsp]
    call lines_of
    mov rcx, [rip + ag_fui]
    imul eax, [rcx + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_8]
    add r12d, eax
3:  cmp dword ptr [rip + dg_state], DS_LOADING
    je 7f
    xor ebx, ebx
    xor r15d, r15d              # rows shown so far
4:  cmp rbx, [rip + dg_rows + VEC_len]
    jae 6f
    mov rdi, rbx
    call row_at
    mov r13, rax
    mov dword ptr [r13 + DGR_h], 0
    mov [r13 + DGR_y], r12d
    mov rdi, r13
    call shown
    test eax, eax
    jz 5f
    mov dword ptr [r13 + DGR_m], 0
    cmp dword ptr [r13 + DGR_kind], DGK_HEAD
    jne 41f
    test r15d, r15d             # a section's title: a gap above all but the first
    jz 41f
    PM eax, MI_12
    mov [r13 + DGR_m], eax
41: mov rdi, r13
    mov esi, [rsp]
    call row_h
    add eax, [r13 + DGR_m]
    mov [r13 + DGR_h], eax
    add r12d, eax
    inc r15d
    mov rdi, r13
    call focusable
    test eax, eax
    jz 5f
    lea rdi, [rip + dg_foc]
    mov esi, 4
    call vec_push
    mov ecx, ebx
    or ecx, FT_ROW << 24
    mov [rax], ecx
5:  inc rbx
    jmp 4b
6:  xor ebx, ebx                # the buttons last
61: cmp rbx, [rip + dg_btns + VEC_len]
    jae 7f
    lea rdi, [rip + dg_foc]
    mov esi, 4
    call vec_push
    mov ecx, ebx
    or ecx, FT_BTN << 24
    mov [rax], ecx
    inc rbx
    jmp 61b
7:  mov [rip + dg_content], r12d
    mov rax, [rsp + 8]          # the focus follows its entry; else its index, within what there is
    cmp rax, -1
    je 74f
    xor ecx, ecx
71: cmp rcx, [rip + dg_foc + VEC_len]
    jae 74f
    mov rdx, [rip + dg_foc + VEC_ptr]
    mov edx, [rdx + rcx*4]
    cmp rdx, rax
    je 73f
    inc rcx
    jmp 71b
73: mov [rip + dg_focus], ecx
74: movsxd rax, dword ptr [rip + dg_focus]
    mov rcx, [rip + dg_foc + VEC_len]
    cmp rax, rcx
    jl 75f
    lea rax, [rcx - 1]
75: cmp rax, -1
    jge 77f
    mov rax, -1
77: mov [rip + dg_focus], eax
    call keep_fkey
9:  EPILOGUE

# keep_fkey(): dg_fkey = the focused entry (-1 none)
keep_fkey:
    mov rax, -1
    movsxd rcx, dword ptr [rip + dg_focus]
    test rcx, rcx
    js 1f
    cmp rcx, [rip + dg_foc + VEC_len]
    jae 1f
    mov rdx, [rip + dg_foc + VEC_ptr]
    mov eax, [rdx + rcx*4]
1:  mov [rip + dg_fkey], rax
    ret

# row_h(DR*, tw) -> eax its height (without its gap above)
row_h:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, [rip + ag_fui]
    mov r13d, [r13 + FACE_lineh]    # the panel's line
    mov r14, [rip + ag_fsmall]
    mov r14d, [r14 + FACE_lineh]    # its small line
    mov eax, [rbx + DGR_kind]
    cmp eax, DGK_FIELD          # claude-chat-p7b: the form rows (agentdlg2.s)
    jae .Lrh_form
    cmp eax, DGK_HEAD
    je .Lrh_head
    cmp eax, DGK_PAIR
    je .Lrh_pair
    cmp eax, DGK_TEXT
    je .Lrh_text
    cmp eax, DGK_BAR
    je .Lrh_bar
    cmp eax, DGK_ITEM
    je .Lrh_item
    cmp eax, DGK_TOGGLE
    je .Lrh_toggle
    cmp eax, DGK_COLS
    je .Lrh_cols
    cmp eax, DGK_LINK
    je .Lrh_link
    PM eax, MI_8                # GAP
    EPILOGUE
.Lrh_head:
    lea eax, [r13 + 0]
    add eax, [rip + g_pmt + 4*MI_4]
    EPILOGUE
.Lrh_pair:
    call pair_split             # eax the value's x (0: stacked), pair_vw its width
    mov r15d, eax
    mov eax, 1
    mov rsi, [rbx + DGR_t2]
    test rsi, rsi
    jz 2f
    mov [rsp], rsi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    mov rsi, [rsp]
    mov rdi, [rip + ag_fui]
    mov ecx, [rip + pair_vw]
    call lines_of
2:  imul eax, r13d
    test r15d, r15d
    jnz 3f
    add eax, r14d               # stacked: the label's small line above
3:  add eax, [rip + g_pmt + 4*MI_4]
    EPILOGUE
.Lrh_text:
    mov rdi, [rip + ag_fui]
    test dword ptr [rbx + DGR_flags], DGF_SMALL
    jz 1f
    mov rdi, [rip + ag_fsmall]
1:  mov [rsp], rdi
    mov rsi, [rbx + DGR_t1]
    mov eax, 1
    test rsi, rsi
    jz 2f
    mov r15, rsi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    mov rdi, [rsp]
    mov rsi, r15
    mov ecx, r12d
    call lines_of
2:  mov rcx, [rsp]
    imul eax, [rcx + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_6]
    EPILOGUE
.Lrh_bar:
    lea eax, [r13 + 0]
    add eax, [rip + g_pmt + 4*MI_4]
    add eax, [rip + g_pmt + 4*MI_6]
    cmp qword ptr [rbx + DGR_t3], 0
    je 1f
    add eax, [rip + g_pmt + 4*MI_2]
    add eax, r14d
1:  add eax, [rip + g_pmt + 4*MI_10]
    EPILOGUE
.Lrh_item:
    lea eax, [r13 + 0]
    cmp qword ptr [rbx + DGR_t2], 0
    je 1f
    add eax, r14d
1:  add eax, [rip + g_pmt + 4*MI_6]
    add eax, [rip + g_pmt + 4*MI_6]
    EPILOGUE
.Lrh_toggle:
    lea eax, [r13 + 0]
    PM ecx, MI_16
    cmp eax, ecx
    cmovl eax, ecx
    cmp qword ptr [rbx + DGR_t2], 0
    je 1f
    add eax, r14d
1:  add eax, [rip + g_pmt + 4*MI_6]
    add eax, [rip + g_pmt + 4*MI_6]
    EPILOGUE
.Lrh_cols:
    lea eax, [r13 + 0]
    add eax, [rip + g_pmt + 4*MI_3]
    EPILOGUE
.Lrh_link:
    lea eax, [r14 + 0]
    add eax, [rip + g_pmt + 4*MI_8]
    EPILOGUE
.Lrh_form:
    mov rdi, rbx
    mov esi, r12d
    call agentdlg2_row_h
    EPILOGUE

# pair_split() -> eax the value's x from the rows' left (0: stacked under its label), pair_vw its width
pair_split:
    mov eax, [rip + g_tw]
    PM ecx, MI_64
    shl ecx, 2                  # under 256 (at 1x): stacked
    cmp eax, ecx
    jge 1f
    mov [rip + pair_vw], eax
    xor eax, eax
    ret
1:  mov ecx, eax
    imul ecx, ecx, 2
    mov edx, 0
    push rbx
    mov ebx, 5
    mov eax, ecx
    cdq
    idiv ebx
    pop rbx
    mov ecx, eax                # the label's column: two fifths
    mov eax, [rip + g_tw]
    sub eax, ecx
    sub eax, [rip + g_pmt + 4*MI_8]
    mov [rip + pair_vw], eax
    lea eax, [rcx + 0]
    add eax, [rip + g_pmt + 4*MI_8]
    ret

.bss
pair_vw: .long 0
.text

# ---- drawing ----

# FN agentdlg_shield(): before the panel's content: the dialog's conversation must still be the panel's
#   open one (else it closes); the panel under it takes no pointer (g_block) until agentdlg_draw
FN agentdlg_shield
    PROLOGUE
    cmp dword ptr [rip + dg_open], 0
    je 9f
    mov rbx, [rip + dg_as]
    test rbx, rbx
    jz 1f
    call agentext_new_active    # a new conversation's draft hides it
    test rax, rax
    jnz 2f
    call agents_open_driven
    cmp rax, rbx
    je 1f
2:  call agentdlg_close
    jmp 9f
1:  mov dword ptr [rip + g_block], 1
9:  EPILOGUE

# FN agentdlg_draw(x, y, w, h): the open dialog over the panel x..x+w, y..y+h (drawn last)
FN agentdlg_draw
    PROLOGUE 64
    cmp dword ptr [rip + dg_open], 0
    je 9f
    mov dword ptr [rip + g_block], 0
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rip + dg_panel], edi
    mov [rip + dg_panel + 4], esi
    mov [rip + dg_panel + 8], edx
    mov [rip + dg_panel + 12], ecx
    call geom
    call reveal
    mov edi, [rsp]              # the dim over the panel; a press on it (outside the box) closes
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    mov r8d, 0x66000000
    call gfx_fill
    mov edi, ID_AGDLG + DID_OVER
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call ui_btn
    test eax, UB_PRESS
    jz 1f
    call in_box
    test eax, eax
    jnz 1f
    call agentdlg_close
    jmp 9f
1:  mov edi, [rip + g_bx]
    mov esi, [rip + g_by]
    mov edx, [rip + g_bw]
    mov ecx, [rip + g_bh]
    mov [rip + dg_rect], edi
    mov [rip + dg_rect + 4], esi
    mov [rip + dg_rect + 8], edx
    mov [rip + dg_rect + 12], ecx
    mov dword ptr [rip + dg_drawn], 1
    call ui_card
    mov edi, [rip + g_bx]
    mov esi, [rip + g_by]
    mov edx, [rip + g_bw]
    mov ecx, [rip + g_bh]
    call gfx_clip_push
    call draw_head
    test eax, eax
    jnz 8f                      # × or Back closed it
    call draw_field
    call draw_body
    test eax, eax
    jnz 8f
    call draw_foot
8:  call gfx_clip_pop
9:  EPILOGUE

# in_box() -> eax 1 when the pointer is over the box as drawn
in_box:
    xor eax, eax
    mov ecx, [rip + g_mx]
    mov edx, [rip + g_bx]
    cmp ecx, edx
    jl 1f
    add edx, [rip + g_bw]
    cmp ecx, edx
    jge 1f
    mov ecx, [rip + g_my]
    mov edx, [rip + g_by]
    cmp ecx, edx
    jl 1f
    add edx, [rip + g_bh]
    cmp ecx, edx
    jge 1f
    mov eax, 1
1:  ret

# reveal(): the focused row brought into the body's view (once a key moved it)
reveal:
    cmp dword ptr [rip + dg_reveal], 0
    je 9f
    mov dword ptr [rip + dg_reveal], 0
    movsxd rcx, dword ptr [rip + dg_focus]
    test rcx, rcx
    js 9f
    cmp rcx, [rip + dg_foc + VEC_len]
    jae 9f
    mov rdx, [rip + dg_foc + VEC_ptr]
    mov edx, [rdx + rcx*4]
    mov eax, edx
    shr eax, 24
    cmp eax, FT_ROW
    jne 9f
    and edx, 0xffffff
    imul rdx, rdx, DGR_SIZE
    add rdx, [rip + dg_rows + VEC_ptr]
    mov eax, [rdx + DGR_y]
    add eax, [rdx + DGR_m]
    cmp eax, [rip + dg_scroll]
    jge 1f
    mov [rip + dg_scroll], eax
    jmp 9f
1:  add eax, [rdx + DGR_h]
    sub eax, [rdx + DGR_m]
    sub eax, [rip + g_bodyh]
    cmp eax, [rip + dg_scroll]
    jle 9f
    mov [rip + dg_scroll], eax
9:  ret

# draw_head() -> eax 1 when it closed: the back arrow, the title, the ×
draw_head:
    PROLOGUE 16
    PM r12d, MI_28              # the buttons' size
    mov r13d, [rip + g_head]
    sub r13d, r12d
    sar r13d, 1
    add r13d, [rip + g_by]      # their top
    mov ebx, [rip + g_bx]
    add ebx, [rip + g_pad]      # the title's x
    cmp dword ptr [rip + dg_back], 0
    je 1f
    mov edi, ID_AGDLG + DID_BACK
    mov esi, [rip + g_bx]
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, r13d
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_BACK
    call ag_icon_btn
    mov ebx, [rip + g_bx]
    add ebx, [rip + g_pmt + 4*MI_6]
    add ebx, r12d
    add ebx, [rip + g_pmt + 4*MI_4]
    test eax, UB_CLICK
    jz 1f
    mov edi, [rip + dg_back]
    xor esi, esi
    xor edx, edx
    call do_act
    mov eax, 1
    EPILOGUE
1:  mov edi, ID_AGDLG + DID_CLOSE
    mov esi, [rip + g_bx]
    add esi, [rip + g_bw]
    sub esi, r12d
    sub esi, [rip + g_pmt + 4*MI_6]
    mov [rsp], esi
    mov edx, r13d
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_CLOSE
    call ag_icon_btn
    test eax, UB_CLICK
    jz 2f
    call agentdlg_close
    mov eax, 1
    EPILOGUE
2:  mov rsi, [rip + dg_title]   # the title, cut before the ×
    test rsi, rsi
    jz 9f
    mov r14, rsi
    mov rdi, rsi
    call strlen
    mov r8, rax
    mov rdi, [rip + ag_fui]
    mov esi, ebx
    mov edx, [rip + g_head]
    mov rcx, [rip + ag_fui]
    sub edx, [rcx + FACE_lineh]
    sar edx, 1
    add edx, [rip + g_by]
    mov rcx, r14
    mov eax, [rsp]
    sub eax, ebx
    sub eax, [rip + g_pmt + 4*MI_4]
    push rax
    COLOR eax, T_FG
    push rax
    mov r9d, eax
    call fit_text_s
    add rsp, 16
9:  xor eax, eax
    EPILOGUE

# fit_text_s(face, x, top, ptr, len, argb, [maxw]): fit_text with its two stack words pushed as
#   [argb, maxw] (the caller pushes maxw, then argb)
fit_text_s:
    PROLOGUE
    mov r9d, [rbp + 16]
    mov eax, [rbp + 24]
    mov r10, rdi
    add edx, [r10 + FACE_ascent]
    push rax
    push rax
    call text_draw_fit
    add rsp, 16
    EPILOGUE

# draw_field(): the filter field
draw_field:
    PROLOGUE
    cmp qword ptr [rip + dg_ph], 0
    je 9f
    xor r9d, r9d
    call focused_entry
    shr eax, 24
    cmp eax, FT_FIELD
    sete r9b
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    je 1f
    xor r9d, r9d
1:  lea rdi, [rip + dg_tf]
    mov esi, [rip + g_bx]
    add esi, [rip + g_pad]
    mov edx, [rip + g_by]
    add edx, [rip + g_head]
    mov ecx, [rip + g_bw]
    sub ecx, [rip + g_pad]
    sub ecx, [rip + g_pad]
    mov r8d, [rip + g_fh]
    sub r8d, [rip + g_pmt + 4*MI_8]
    mov rax, [rip + dg_ph]
    push rax
    push rax
    call ui_textarea
    add rsp, 16
    test eax, UB_PRESS
    jz 9f
    mov dword ptr [rip + dg_focus], 0   # the field is the first focusable
    call keep_fkey
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
9:  EPILOGUE

# focused_entry() -> eax the focused entry (type << 24 | index), 0 none
focused_entry:
    xor eax, eax
    movsxd rcx, dword ptr [rip + dg_focus]
    test rcx, rcx
    js 1f
    cmp rcx, [rip + dg_foc + VEC_len]
    jae 1f
    mov rdx, [rip + dg_foc + VEC_ptr]
    mov eax, [rdx + rcx*4]
1:  ret

# draw_body() -> eax 1 when an act closed the dialog: the message, the rows in view, the scrollbar; the
#   wheel scrolls it
draw_body:
    PROLOGUE 48
    mov eax, [rip + g_bx]
    add eax, [rip + g_pad]
    mov [rsp], eax              # x
    mov eax, [rip + g_bodyy]
    mov [rsp + 4], eax          # y
    mov eax, [rip + g_tw]
    mov [rsp + 8], eax          # w
    mov eax, [rip + g_bodyh]
    mov [rsp + 12], eax         # h
    mov edi, [rip + g_bx]
    mov [rip + dg_body], edi
    mov esi, [rip + g_bodyy]
    mov [rip + dg_body + 4], esi
    mov edx, [rip + g_bw]
    mov [rip + dg_body + 8], edx
    mov ecx, [rip + g_bodyh]
    mov [rip + dg_body + 12], ecx
    call ui_in                  # the wheel
    test eax, eax
    jz 1f
    mov eax, [rip + g_scroll_y]
    test eax, eax
    jz 1f
    add eax, [rip + dg_scroll]
    cmp eax, [rip + dg_max]
    jle 11f
    mov eax, [rip + dg_max]
11: test eax, eax
    jns 12f
    xor eax, eax
12: mov [rip + dg_scroll], eax
    mov dword ptr [rip + g_scroll_y], 0
1:  mov edi, [rip + g_bx]
    mov esi, [rsp + 4]
    mov edx, [rip + g_bw]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    mov eax, [rsp + 4]
    sub eax, [rip + dg_scroll]
    mov [rsp + 16], eax         # the content's top on screen
    mov rdx, [rip + dg_msg + SB_len]
    test rdx, rdx
    jz 2f
    COLOR eax, T_MUTED
    cmp dword ptr [rip + dg_state], DS_ERROR
    jne 13f
    COLOR eax, T_ERROR
13: push rax
    push rax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 16]
    mov edx, [rsp + 16 + 16]
    mov ecx, [rsp + 16 + 8]
    mov r8, [rip + dg_msg + SB_ptr]
    mov r9, [rip + dg_msg + SB_len]
    call draw_wrap
    add rsp, 16
2:  cmp dword ptr [rip + dg_state], DS_LOADING
    je 7f
    xor ebx, ebx
    mov dword ptr [rsp + 20], 0 # the focusable rows passed (their index in dg_foc: + 1 with a field)
    cmp qword ptr [rip + dg_ph], 0
    je 3f
    mov dword ptr [rsp + 20], 1
3:  cmp rbx, [rip + dg_rows + VEC_len]
    jae 7f
    mov rdi, rbx
    call row_at
    mov r12, rax
    inc rbx
    mov eax, [r12 + DGR_h]
    test eax, eax
    jz 3b
    mov rdi, r12
    call focusable
    mov r13d, -1                # its focus index, -1 none
    test eax, eax
    jz 4f
    mov r13d, [rsp + 20]
    inc dword ptr [rsp + 20]
4:  mov eax, [r12 + DGR_y]       # in view?
    sub eax, [rip + dg_scroll]
    add eax, [r12 + DGR_h]
    jle 3b
    mov eax, [r12 + DGR_y]
    sub eax, [rip + dg_scroll]
    cmp eax, [rsp + 12]
    jge 3b
    mov esi, [rsp + 16]
    add esi, [r12 + DGR_y]
    add esi, [r12 + DGR_m]
    mov rdi, r12
    mov edx, [rsp]
    mov ecx, [rsp + 8]
    mov r8d, r13d
    call draw_row
    test eax, eax
    jz 3b
    call gfx_clip_pop           # an act closed it, or made the rows again
    mov eax, 1
    EPILOGUE
7:  call gfx_clip_pop
    mov eax, [rip + dg_max]     # the scrollbar
    test eax, eax
    jz 8f
    lea r9, [rip + dg_scroll]
    mov eax, [rsp + 12]
    push rax
    mov eax, [rip + dg_content]
    push rax
    mov edi, ID_AGDLG + DID_SCROLL
    mov esi, [rip + g_bx]
    add esi, [rip + g_bw]
    sub esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rsp + 16 + 4]
    PM ecx, MI_6
    mov r8d, [rsp + 16 + 12]
    call ui_scrollbar
    add rsp, 16
8:  xor eax, eax
    EPILOGUE

# draw_row(DR*, y, x, w, focus index or -1) -> eax 1 when an act ran (the rows may be gone)
draw_row:
    cmp dword ptr [rdi + DGR_kind], DGK_FIELD   # claude-chat-p7b: the form rows (agentdlg2.s)
    jae agentdlg2_draw_row
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], esi              # y (its top, below its gap)
    mov [rsp + 4], edx          # x
    mov [rsp + 8], ecx          # w
    mov [rsp + 12], r8d         # focus index
    mov eax, [rbx + DGR_h]
    sub eax, [rbx + DGR_m]
    mov [rsp + 16], eax         # h
    mov dword ptr [rsp + 20], 0 # the ui_btn bits
    cmp r8d, -1
    je 2f
    mov edi, r8d                # a focusable row: its button, the hover and the focus drawn under it
    cmp edi, ROW_IDS - 1
    jbe 1f
    mov edi, ROW_IDS - 1
1:  add edi, ID_AGDLG + DID_ROW
    mov esi, [rsp + 4]
    sub esi, [rip + g_pmt + 4*MI_4]
    mov edx, [rsp]
    mov ecx, [rsp + 8]
    add ecx, [rip + g_pmt + 4*MI_8]
    mov r8d, [rsp + 16]
    call ui_btn
    mov [rsp + 20], eax
    xor ecx, ecx
    mov eax, [rsp + 12]
    cmp eax, [rip + dg_focus]
    sete cl
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    je 11f
    xor ecx, ecx
11: mov [rsp + 24], ecx         # focused
    COLOR r9d, T_HOVER
    test ecx, ecx
    jnz 12f
    test dword ptr [rsp + 20], UB_HOVER
    jz 2f
    jmp 13f
12: COLOR r9d, T_SELECTION
13: mov edi, [rsp + 4]
    sub edi, [rip + g_pmt + 4*MI_4]
    mov esi, [rsp]
    mov edx, [rsp + 8]
    add edx, [rip + g_pmt + 4*MI_8]
    mov ecx, [rsp + 16]
    PM r8d, MI_RADIUS
    call gfx_round_rect
2:  mov eax, [rbx + DGR_kind]
    cmp eax, DGK_HEAD
    je .Ldr_head
    cmp eax, DGK_PAIR
    je .Ldr_pair
    cmp eax, DGK_TEXT
    je .Ldr_text
    cmp eax, DGK_BAR
    je .Ldr_bar
    cmp eax, DGK_ITEM
    je .Ldr_item
    cmp eax, DGK_TOGGLE
    je .Ldr_toggle
    cmp eax, DGK_COLS
    je .Ldr_cols
    cmp eax, DGK_LINK
    je .Ldr_link
    jmp .Ldr_click
.Ldr_head:
    mov r12d, [rsp + 8]         # the hint at the right, half the row at most
    mov rsi, [rbx + DGR_t3]
    test rsi, rsi
    jz 1f
    mov rdi, [rip + ag_fsmall]
    call cwidth
    mov r13d, eax
    mov eax, [rsp + 8]
    shr eax, 1
    cmp r13d, eax
    cmovg r13d, eax
    mov rcx, [rbx + DGR_t3]
    mov rdi, rcx
    call strlen
    mov r8, rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 4]
    add esi, [rsp + 8]
    sub esi, r13d
    mov edx, [rsp]
    mov rcx, [rbx + DGR_t3]
    COLOR r9d, T_MUTED
    push r13
    push r9
    call fit_text_s
    add rsp, 16
    sub r12d, r13d
    sub r12d, [rip + g_pmt + 4*MI_8]
1:  mov edi, 0
    mov rsi, [rbx + DGR_t1]
    mov r14, rsi
    test rsi, rsi
    jz .Ldr_click
    mov rdi, rsi
    call strlen
    mov r8, rax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 4]
    mov edx, [rsp]
    mov rcx, r14
    COLOR r9d, T_FG
    push r12
    push r9
    call fit_text_s
    add rsp, 16
    jmp .Ldr_click
.Ldr_pair:
    call pair_split
    mov r12d, eax               # the value's x from the left (0 stacked)
    mov r13d, [rsp]             # the value's top
    mov rsi, [rbx + DGR_t1]
    test rsi, rsi
    jz 3f
    mov r14, rsi
    mov rdi, rsi
    call strlen
    mov r8, rax
    mov rdi, [rip + ag_fui]
    mov eax, r12d
    sub eax, [rip + g_pmt + 4*MI_8]
    test r12d, r12d
    jnz 2f
    mov rdi, [rip + ag_fsmall]  # stacked: the label small, above
    mov eax, [rsp + 8]
    mov rcx, [rip + ag_fsmall]
    add r13d, [rcx + FACE_lineh]
2:  mov esi, [rsp + 4]
    mov edx, [rsp]
    mov rcx, r14
    COLOR r9d, T_MUTED
    push rax
    push r9
    call fit_text_s
    add rsp, 16
3:  mov rsi, [rbx + DGR_t2]
    test rsi, rsi
    jz .Ldr_click
    mov r14, rsi
    mov rdi, rsi
    call strlen
    mov r9, rax
    COLOR eax, T_FG
    push rax
    push rax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 16 + 4]
    add esi, r12d
    mov edx, r13d
    mov ecx, [rip + pair_vw]
    mov r8, r14
    call draw_wrap
    add rsp, 16
    jmp .Ldr_click
.Ldr_text:
    mov rsi, [rbx + DGR_t1]
    test rsi, rsi
    jz .Ldr_click
    mov r14, rsi
    mov rdi, rsi
    call strlen
    mov r9, rax
    COLOR eax, T_FG
    test dword ptr [rbx + DGR_flags], DGF_MUTED
    jz 1f
    COLOR eax, T_MUTED
1:  test dword ptr [rbx + DGR_flags], DGF_ERROR
    jz 2f
    COLOR eax, T_ERROR
2:  push rax
    push rax
    mov rdi, [rip + ag_fui]
    test dword ptr [rbx + DGR_flags], DGF_SMALL
    jz 3f
    mov rdi, [rip + ag_fsmall]
3:  mov esi, [rsp + 16 + 4]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 16 + 8]
    mov r8, r14
    call draw_wrap
    add rsp, 16
    jmp .Ldr_click
.Ldr_bar:
    lea rdi, [rip + dsb]        # "N%" at the right
    call sb_clear
    lea rdi, [rip + dsb]
    mov rsi, [rbx + DGR_val]
    call sb_push_u64
    lea rdi, [rip + dsb]
    mov esi, '%'
    call sb_push_byte
    mov rdi, [rip + ag_fui]
    mov rsi, [rip + dsb + SB_ptr]
    mov rdx, [rip + dsb + SB_len]
    call text_width
    mov r12d, eax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 4]
    add esi, [rsp + 8]
    sub esi, eax
    mov edx, [rsp]
    add edx, [rdi + FACE_ascent]
    mov rcx, [rip + dsb + SB_ptr]
    mov r8, [rip + dsb + SB_len]
    COLOR r9d, T_MUTED
    call text_draw
    mov rsi, [rbx + DGR_t1]
    test rsi, rsi
    jz 1f
    mov r14, rsi
    mov rdi, rsi
    call strlen
    mov r8, rax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 4]
    mov edx, [rsp]
    mov rcx, r14
    mov eax, [rsp + 8]
    sub eax, r12d
    sub eax, [rip + g_pmt + 4*MI_8]
    push rax
    COLOR r9d, T_FG
    push r9
    call fit_text_s
    add rsp, 16
1:  mov rax, [rip + ag_fui]     # the track
    mov r13d, [rsp]
    add r13d, [rax + FACE_lineh]
    add r13d, [rip + g_pmt + 4*MI_4]
    mov edi, [rsp + 4]
    mov esi, r13d
    mov edx, [rsp + 8]
    PM ecx, MI_6
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_BORDER
    call gfx_round_rect
    mov rax, [rbx + DGR_val]
    cmp rax, 100
    jbe 2f
    mov eax, 100
2:  imul eax, [rsp + 8]
    xor edx, edx
    mov ecx, 100
    div ecx
    test eax, eax
    jz 4f
    mov edx, eax
    mov edi, [rsp + 4]
    mov esi, r13d
    PM ecx, MI_6
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_ACCENT
    cmp qword ptr [rbx + DGR_val], 80        # 80 % and over: the warning colour (the extension's)
    jb 3f
    COLOR r9d, T_WARNING
3:  call gfx_round_rect
4:  mov rsi, [rbx + DGR_t3]
    test rsi, rsi
    jz .Ldr_click
    mov r14, rsi
    mov rdi, rsi
    call strlen
    mov r8, rax
    add r13d, [rip + g_pmt + 4*MI_6]
    add r13d, [rip + g_pmt + 4*MI_2]
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 4]
    mov edx, r13d
    mov rcx, r14
    mov eax, [rsp + 8]
    push rax
    COLOR r9d, T_MUTED
    push r9
    call fit_text_s
    add rsp, 16
    jmp .Ldr_click
.Ldr_item:
    mov r13d, [rsp]
    add r13d, [rip + g_pmt + 4*MI_6]    # its first line's top
    mov r12d, [rsp + 8]         # room for t1
    test dword ptr [rbx + DGR_flags], DGF_CHECK
    jz 1f
    PM ecx, MI_16               # a check mark at the right
    mov edi, IC_CHECK
    mov esi, [rsp + 4]
    add esi, [rsp + 8]
    sub esi, ecx
    mov edx, r13d
    mov rax, [rip + ag_fui]
    mov r8d, [rax + FACE_lineh]
    COLOR r9d, T_ACCENT
    call ui_icon_center
    PM ecx, MI_16
    sub r12d, ecx
    sub r12d, [rip + g_pmt + 4*MI_4]
1:  mov rsi, [rbx + DGR_t3]      # the right text, or the pill
    test rsi, rsi
    jz 5f
    mov rdi, [rip + ag_fsmall]
    call cwidth
    mov r14d, eax
    mov eax, [rsp + 8]
    shr eax, 1
    cmp r14d, eax
    jle 2f
    mov r14d, eax               # half the row at most
2:  mov r15d, [rsp + 4]
    add r15d, r12d
    sub r15d, r14d              # its x
    test dword ptr [rbx + DGR_flags], DGF_STATE
    jz 4f
    PM eax, MI_8                # a pill: its frame round it, a button of its own
    sub r15d, eax
    mov edi, [rsp + 12]
    cmp edi, PILL_IDS - 1
    jbe 3f
    mov edi, PILL_IDS - 1
3:  add edi, ID_AGDLG + DID_PILL
    mov esi, r15d
    mov edx, r13d
    lea ecx, [r14 + rax*2]
    mov r8, [rip + ag_fui]
    mov r8d, [r8 + FACE_lineh]
    call ui_btn
    mov [rsp + 28], eax
    mov edi, r15d
    mov esi, r13d
    PM eax, MI_8
    lea edx, [r14 + rax*2]
    mov rcx, [rip + ag_fui]
    mov ecx, [rcx + FACE_lineh]
    PM r8d, MI_RADIUS
    COLOR r9d, T_INPUT
    test dword ptr [rsp + 28], UB_HOVER
    jz 31f
    COLOR r9d, T_ACTIVE
31: call gfx_round_rect
    test dword ptr [rsp + 28], UB_CLICK
    jz 32f
    test dword ptr [rbx + DGR_flags], DGF_OFF
    jnz 32f
    mov edi, [rbx + DGR_act2]
    mov rsi, [rbx + DGR_arg]
    mov rdx, rbx
    call do_act
    mov eax, 1
    EPILOGUE
32: PM eax, MI_8
    add r15d, eax
    PM eax, MI_16
    sub r12d, eax
4:  mov rcx, [rbx + DGR_t3]
    mov rdi, rcx
    call strlen
    mov r8, rax
    mov rdi, [rip + ag_fsmall]
    mov esi, r15d
    mov rax, [rip + ag_fui]
    mov edx, [rax + FACE_lineh]
    sub edx, [rdi + FACE_lineh]
    sar edx, 1
    add edx, r13d
    mov rcx, [rbx + DGR_t3]
    push r14
    COLOR r9d, T_MUTED
    push r9
    call fit_text_s
    add rsp, 16
    sub r12d, r14d
    sub r12d, [rip + g_pmt + 4*MI_8]
5:  mov rsi, [rbx + DGR_t1]      # the first line
    test rsi, rsi
    jz 6f
    mov r14, rsi
    mov rdi, rsi
    call strlen
    mov r8, rax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 4]
    mov edx, r13d
    mov rcx, r14
    push r12
    COLOR r9d, T_FG
    test dword ptr [rbx + DGR_flags], DGF_OFF
    jz 51f
    COLOR r9d, T_MUTED
51: push r9
    call fit_text_s
    add rsp, 16
6:  mov rsi, [rbx + DGR_t2]      # the muted line under it
    test rsi, rsi
    jz .Ldr_click
    mov r14, rsi
    mov rdi, rsi
    call strlen
    mov r8, rax
    mov rax, [rip + ag_fui]
    add r13d, [rax + FACE_lineh]
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 4]
    mov edx, r13d
    mov rcx, r14
    mov eax, [rsp + 8]
    push rax
    COLOR r9d, T_MUTED
    push r9
    call fit_text_s
    add rsp, 16
    jmp .Ldr_click
.Ldr_toggle:
    mov r13d, [rsp]
    add r13d, [rip + g_pmt + 4*MI_6]
    PM r14d, MI_28              # the switch: 28 x 16 at 1x, at the right
    PM r15d, MI_16
    mov r12d, [rsp + 4]
    add r12d, [rsp + 8]
    sub r12d, r14d
    mov rax, [rip + ag_fui]
    mov esi, [rax + FACE_lineh]
    sub esi, r15d
    sar esi, 1
    add esi, r13d
    mov [rsp + 28], esi
    COLOR r9d, T_BORDER
    test dword ptr [rbx + DGR_flags], DGF_ON
    jz 1f
    COLOR r9d, T_ACCENT
1:  mov edi, r12d
    mov edx, r14d
    mov ecx, r15d
    mov r8d, r15d
    shr r8d, 1
    call gfx_round_rect
    mov ecx, r15d               # the knob
    sub ecx, [rip + g_pmt + 4*MI_2]
    sub ecx, [rip + g_pmt + 4*MI_2]
    jg 2f
    mov ecx, 1
2:  mov edi, r12d
    add edi, [rip + g_pmt + 4*MI_2]
    COLOR r9d, T_POPUP
    test dword ptr [rbx + DGR_flags], DGF_ON
    jz 3f
    mov edi, r12d
    add edi, r14d
    sub edi, [rip + g_pmt + 4*MI_2]
    sub edi, ecx
    COLOR r9d, T_ACCENT_FG
3:  mov esi, [rsp + 28]
    add esi, [rip + g_pmt + 4*MI_2]
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    call gfx_round_rect
    mov rsi, [rbx + DGR_t1]
    test rsi, rsi
    jz 4f
    mov r15, rsi
    mov rdi, rsi
    call strlen
    mov r8, rax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 4]
    mov edx, r13d
    mov rcx, r15
    mov eax, [rsp + 8]
    sub eax, r14d
    sub eax, [rip + g_pmt + 4*MI_8]
    push rax
    COLOR r9d, T_FG
    test dword ptr [rbx + DGR_flags], DGF_OFF
    jz 31f
    COLOR r9d, T_MUTED
31: push r9
    call fit_text_s
    add rsp, 16
4:  mov rsi, [rbx + DGR_t2]
    test rsi, rsi
    jz .Ldr_click
    mov r15, rsi
    mov rdi, rsi
    call strlen
    mov r8, rax
    mov rax, [rip + ag_fui]
    add r13d, [rax + FACE_lineh]
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 4]
    mov edx, r13d
    mov rcx, r15
    mov eax, [rsp + 8]
    push rax
    COLOR r9d, T_MUTED
    push r9
    call fit_text_s
    add rsp, 16
    jmp .Ldr_click
.Ldr_cols:
    mov r15, [rip + ag_fui]
    test dword ptr [rbx + DGR_flags], DGF_MUTED
    jz 1f
    mov r15, [rip + ag_fsmall]
1:  mov rdi, r15                # the columns: the third as wide as "100.0%", the second as "1000.0k"
    lea rsi, [rip + .Lw3]
    call cwidth
    mov r12d, eax
    mov rdi, r15
    lea rsi, [rip + .Lw2]
    call cwidth
    mov r13d, eax
    mov ecx, [rsp + 8]          # narrow: the columns shrink to their texts' widths at most
    shr ecx, 2
    cmp r12d, ecx
    cmovg r12d, ecx
    cmp r13d, ecx
    cmovg r13d, ecx
    mov r14d, [rsp + 4]         # t1's x
    test dword ptr [rbx + DGR_flags], DGF_SWATCH
    jz 2f
    PM ecx, MI_10
    mov edi, r14d
    mov rax, [rip + ag_fui]
    mov esi, [rax + FACE_lineh]
    sub esi, ecx
    sar esi, 1
    add esi, [rsp]
    mov edx, ecx
    mov r8d, [rip + g_pmt + 4*MI_2]
    mov r9, [rbx + DGR_val]
    call gfx_round_rect
    PM ecx, MI_10
    add r14d, ecx
    add r14d, [rip + g_pmt + 4*MI_6]
2:  mov rax, [rip + ag_fui]     # the line's top for a small face: centred on the panel's line
    mov eax, [rax + FACE_lineh]
    sub eax, [r15 + FACE_lineh]
    sar eax, 1
    add eax, [rsp]
    mov [rsp + 28], eax
    COLOR eax, T_FG
    test dword ptr [rbx + DGR_flags], DGF_MUTED
    jz 21f
    COLOR eax, T_MUTED
21: mov [rsp + 32], eax
    mov rsi, [rbx + DGR_t3]      # the third, right-aligned at the end
    test rsi, rsi
    jz 3f
    mov rdi, r15
    call cwidth
    cmp eax, r12d
    cmovg eax, r12d
    mov ecx, [rsp + 4]
    add ecx, [rsp + 8]
    sub ecx, eax
    mov esi, ecx
    mov rcx, [rbx + DGR_t3]
    mov rdi, rcx
    push rsi
    push rsi
    call strlen
    pop rsi
    pop rsi
    mov r8, rax
    mov rdi, r15
    mov edx, [rsp + 28]
    mov rcx, [rbx + DGR_t3]
    mov r9d, [rsp + 32]
    push r12
    push r9
    call fit_text_s
    add rsp, 16
3:  mov rsi, [rbx + DGR_t2]      # the second, right-aligned before the third
    test rsi, rsi
    jz 4f
    mov rdi, r15
    call cwidth
    cmp eax, r13d
    cmovg eax, r13d
    mov ecx, [rsp + 4]
    add ecx, [rsp + 8]
    sub ecx, r12d
    sub ecx, [rip + g_pmt + 4*MI_12]
    sub ecx, eax
    mov esi, ecx
    push rsi
    push rsi
    mov rdi, [rbx + DGR_t2]
    call strlen
    pop rsi
    pop rsi
    mov r8, rax
    mov rdi, r15
    mov edx, [rsp + 28]
    mov rcx, [rbx + DGR_t2]
    mov r9d, [rsp + 32]
    push r13
    push r9
    call fit_text_s
    add rsp, 16
4:  mov rsi, [rbx + DGR_t1]      # the first, cut before the columns
    test rsi, rsi
    jz .Ldr_click
    mov rdi, rsi
    call strlen
    mov r8, rax
    mov eax, [rsp + 4]
    add eax, [rsp + 8]
    sub eax, r12d
    sub eax, r13d
    sub eax, [rip + g_pmt + 4*MI_12]
    sub eax, [rip + g_pmt + 4*MI_12]
    sub eax, r14d
    mov rdi, r15
    mov esi, r14d
    mov edx, [rsp + 28]
    mov rcx, [rbx + DGR_t1]
    mov r9d, [rsp + 32]
    push rax
    push r9
    call fit_text_s
    add rsp, 16
    jmp .Ldr_click
.Ldr_link:
    mov rsi, [rbx + DGR_t1]
    test rsi, rsi
    jz .Ldr_click
    mov r14, rsi
    mov rdi, rsi
    call strlen
    mov r8, rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 4]
    mov edx, [rsp]
    add edx, [rip + g_pmt + 4*MI_4]
    mov rcx, r14
    mov eax, [rsp + 8]
    push rax
    COLOR r9d, T_ACCENT
    push r9
    call fit_text_s
    add rsp, 16
.Ldr_click:
    cmp dword ptr [rsp + 12], -1
    je 8f
    test dword ptr [rsp + 20], UB_CLICK
    jz 8f
    mov eax, [rsp + 12]         # clicked: it has the focus, and acts
    mov [rip + dg_focus], eax
    call keep_fkey
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov edi, [rbx + DGR_act]
    test edi, edi
    jz 8f
    mov rsi, [rbx + DGR_arg]
    mov rdx, rbx
    call do_act
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# draw_foot(): the buttons, each row right-aligned
draw_foot:
    PROLOGUE 32
    cmp dword ptr [rip + g_foot], 0
    je 9f
    mov eax, [rip + g_bodyy]    # the footer's first row's top: a gap under the body
    add eax, [rip + g_bodyh]
    add eax, [rip + g_pmt + 4*MI_12]
    mov [rsp], eax
    xor ebx, ebx
1:  cmp rbx, [rip + dg_btns + VEC_len]
    jae 9f
    mov rdi, rbx
    call btn_at
    mov r12, rax
    mov edi, [r12 + DB_row]     # the row's right end: its last button's right
    call row_right
    mov ecx, [rip + g_bx]
    add ecx, [rip + g_bw]
    sub ecx, [rip + g_pad]
    sub ecx, eax                # the row's left: right-aligned in the box
    add ecx, [r12 + DB_x]
    mov [rsp + 4], ecx          # its x
    mov eax, [r12 + DB_h]
    add eax, [rip + g_pmt + 4*MI_6]
    imul eax, [r12 + DB_row]
    add eax, [rsp]
    mov [rsp + 8], eax          # its y
    lea edi, [rbx + ID_AGDLG + DID_BTN]
    cmp ebx, BTN_IDS - 1
    jbe 2f
    mov edi, ID_AGDLG + DID_BTN + BTN_IDS - 1
2:  mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [r12 + DB_w]
    mov r8d, [r12 + DB_h]
    mov [r12 + DB_y], edx
    call ui_btn
    mov [rsp + 12], eax
    mov eax, T_FG
    mov [rsp + 16], eax
    test dword ptr [r12 + DB_flags], DBF_PRIMARY
    jz 3f
    COLOR r9d, T_ACCENT         # the primary one filled
    mov dword ptr [rsp + 16], T_ACCENT_FG
    mov edi, [rsp + 4]
    mov esi, [rsp + 8]
    mov edx, [r12 + DB_w]
    mov ecx, [r12 + DB_h]
    PM r8d, MI_RADIUS
    call gfx_round_rect
    jmp 41f
3:  COLOR eax, T_INPUT          # the others framed
    test dword ptr [rsp + 12], UB_HOVER
    jz 31f
    COLOR eax, T_HOVER
31: push rax
    push rax
    mov edi, [rsp + 16 + 4]
    mov esi, [rsp + 16 + 8]
    mov edx, [r12 + DB_w]
    mov ecx, [r12 + DB_h]
    PM r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    call gfx_frame
    add rsp, 16
41:
    call focused_entry          # the focus ring
    mov ecx, ebx
    or ecx, FT_BTN << 24
    cmp eax, ecx
    jne 5f
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    jne 5f
    mov edi, [rsp + 4]
    mov esi, [rsp + 8]
    mov edx, [r12 + DB_w]
    mov ecx, [r12 + DB_h]
    call ring
5:  mov rdi, r12
    mov esi, ebx
    call btn_label
    mov r8, rdx
    mov rcx, rax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 4]
    add esi, [rip + g_pmt + 4*MI_12]
    mov edx, [r12 + DB_h]
    sub edx, [rdi + FACE_lineh]
    sar edx, 1
    add edx, [rsp + 8]
    mov eax, [rsp + 16]
    lea r9, [rip + g_theme]
    mov r9d, [r9 + 4*rax]
    mov eax, [r12 + DB_w]
    sub eax, [rip + g_pmt + 4*MI_12]
    sub eax, [rip + g_pmt + 4*MI_12]
    push rax
    push r9
    call fit_text_s
    add rsp, 16
    test dword ptr [rsp + 12], UB_CLICK
    jz 6f
    mov ecx, ebx                # clicked: focus, act
    or ecx, FT_BTN << 24
    call focus_entry
    mov edi, [r12 + DB_act]
    xor esi, esi
    xor edx, edx
    call do_act
    jmp 9f
6:  inc rbx
    jmp 1b
9:  EPILOGUE

# row_right(row) -> eax the right end of that footer row (from the inner left)
row_right:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, [rip + dg_btns + VEC_len]
    jae 9f
    imul rdx, rcx, DB_SIZE
    add rdx, [rip + dg_btns + VEC_ptr]
    inc rcx
    cmp [rdx + DB_row], edi
    jne 1b
    mov r8d, [rdx + DB_x]
    add r8d, [rdx + DB_w]
    cmp r8d, eax
    cmovg eax, r8d
    jmp 1b
9:  ret

# ring(x, y, w, h): the focus ring (an accent frame, PM MI_1 wide... two at 2x)
ring:
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    PM ebx, MI_2
    COLOR r12d, T_ACCENT
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, ebx
    mov r8d, r12d
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rsp + 12]
    sub esi, ebx
    mov edx, [rsp + 8]
    mov ecx, ebx
    mov r8d, r12d
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, ebx
    mov ecx, [rsp + 12]
    mov r8d, r12d
    call gfx_fill
    mov edi, [rsp]
    add edi, [rsp + 8]
    sub edi, ebx
    mov esi, [rsp + 4]
    mov edx, ebx
    mov ecx, [rsp + 12]
    mov r8d, r12d
    call gfx_fill
    EPILOGUE

# focus_entry(entry in ecx): the focus on that entry (when it is in the list)
focus_entry:
    xor eax, eax
1:  cmp rax, [rip + dg_foc + VEC_len]
    jae 9f
    mov rdx, [rip + dg_foc + VEC_ptr]
    cmp [rdx + rax*4], ecx
    je 2f
    inc rax
    jmp 1b
2:  mov [rip + dg_focus], eax
    mov [rip + dg_fkey], rcx
    mov dword ptr [rip + dg_reveal], 1
9:  ret

# ---- keys ----

# FN agentdlg_key(keysym, cp, mods) -> eax 1 when the dialog took the key (every plain key while it is
#   open and the panel shows; shortcuts with Ctrl, Alt or Super go on unless its field takes them)
FN agentdlg_key
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    cmp dword ptr [rip + dg_open], 0
    je .Lk_no
    cmp dword ptr [rip + g_show_agents], 0
    je .Lk_no
    call sync_layout
    mov dword ptr [rip + g_dirty], 1
    call focused_entry
    mov ebx, eax                # the focused entry
    cmp r12d, KEY_ESCAPE
    jne 1f
    mov edi, [rip + dg_back]
    test edi, edi
    jnz 11f
    call agentdlg_close
    jmp .Lk_yes
11: xor esi, esi
    xor edx, edx
    call do_act
    jmp .Lk_yes
1:  mov edi, ebx                # claude-chat-p7b: a form row that has the focus takes its keys first
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call agentdlg2_key
    test eax, eax
    jnz .Lk_yes
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Lk_field
    cmp r12d, KEY_TAB
    jne 2f
    mov edi, 1
    test r14d, MOD_SHIFT
    jz 12f
    mov edi, -1
12: call move
    jmp .Lk_yes
2:  cmp r12d, KEY_ISO_LEFT_TAB
    jne 3f
    mov edi, -1
    call move
    jmp .Lk_yes
3:  cmp r12d, KEY_DOWN
    jne 4f
    mov edi, 1
    call move
    jmp .Lk_yes
4:  cmp r12d, KEY_UP
    jne 5f
    mov edi, -1
    call move
    jmp .Lk_yes
5:  cmp r12d, KEY_RETURN
    je 51f
    cmp r12d, KEY_KP_ENTER
    jne 6f
51: test r14d, MOD_SHIFT
    jnz .Lk_yes
    mov edi, ebx
    xor esi, esi
    call activate
    jmp .Lk_yes
6:  cmp r12d, KEY_PAGEUP
    je 61f
    cmp r12d, KEY_PAGEDOWN
    jne 62f
61: mov eax, [rip + g_bodyh]
    sub eax, [rip + g_pmt + 4*MI_20]
    cmp eax, 1
    jge 611f
    mov eax, 1
611:cmp r12d, KEY_PAGEUP
    jne 612f
    neg eax
612:add eax, [rip + dg_scroll]
    call set_scroll
    jmp .Lk_yes
62: mov eax, ebx
    shr eax, 24
    cmp eax, FT_FIELD
    je .Lk_field                # the field: Home, End, Space, the digits are its own
    cmp r12d, KEY_HOME
    jne 63f
    xor eax, eax
    call set_scroll
    jmp .Lk_yes
63: cmp r12d, KEY_END
    jne 64f
    mov eax, [rip + dg_max]
    call set_scroll
    jmp .Lk_yes
64: cmp r13d, ' '
    jne 65f
    mov edi, ebx
    mov esi, 1
    call activate
    jmp .Lk_yes
65: lea eax, [r13 - '1']        # 1..9: a numbered button
    cmp eax, 8
    ja 66f
    cmp dword ptr [rip + dg_num], 0
    je 66f
    cmp rax, [rip + dg_btns + VEC_len]
    jae .Lk_yes
    mov ecx, eax
    or ecx, FT_BTN << 24
    mov ebx, ecx
    call focus_entry
    mov edi, ebx
    xor esi, esi
    call activate
    jmp .Lk_yes
66: cmp r13d, ' '               # typed text goes to the filter (it takes the focus)
    jb .Lk_yes
    cmp qword ptr [rip + dg_ph], 0
    je .Lk_yes
    mov ecx, FT_FIELD << 24
    call focus_entry
.Lk_field:
    cmp qword ptr [rip + dg_ph], 0
    je 7f
    call focused_entry
    shr eax, 24
    cmp eax, FT_FIELD
    jne 7f
    lea rdi, [rip + dg_tf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call ta_key
    test eax, eax
    jnz 71f
7:  test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Lk_no                  # a shortcut nothing here took goes on
    jmp .Lk_yes
71: mov dword ptr [rip + dg_scroll], 0  # a new filter: from the top
.Lk_yes:
    mov eax, 1
    EPILOGUE
.Lk_no:
    xor eax, eax
    EPILOGUE

# set_scroll(eax): the body's scroll, within what there is
set_scroll:
    cmp eax, [rip + dg_max]
    jle 1f
    mov eax, [rip + dg_max]
1:  test eax, eax
    jns 2f
    xor eax, eax
2:  mov [rip + dg_scroll], eax
    ret

# sync_layout(): the layout of the last frame's panel, made again if its inputs changed (keys between frames)
sync_layout:
    cmp dword ptr [rip + dg_drawn], 0
    je 1f
    mov edi, [rip + dg_panel]
    mov esi, [rip + dg_panel + 4]
    mov edx, [rip + dg_panel + 8]
    mov ecx, [rip + dg_panel + 12]
    jmp geom
1:  mov edi, [rip + g_tw]
    test edi, edi
    jnz 2f
    mov edi, 300
2:  jmp layout

# move(dir): the focus one on, round the list
move:
    mov rcx, [rip + dg_foc + VEC_len]
    test rcx, rcx
    jz 9f
    movsxd rax, dword ptr [rip + dg_focus]
    test rax, rax
    jns 1f
    xor eax, eax
    test edi, edi
    jns 3f
    lea rax, [rcx - 1]
    jmp 3f
1:  movsxd rdx, edi
    add rax, rdx
    jns 2f
    lea rax, [rcx - 1]
2:  cmp rax, rcx
    jb 3f
    xor eax, eax
3:  mov [rip + dg_focus], eax
    mov rdx, [rip + dg_foc + VEC_ptr]
    mov edx, [rdx + rax*4]
    mov [rip + dg_fkey], rdx
    mov dword ptr [rip + dg_reveal], 1
9:  ret

# activate(entry, space): a row's act (Space on a DGF_STATE row: its pill's), a button's; the field: the
#   first row shown (Enter)
activate:
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov eax, ebx
    shr eax, 24
    cmp eax, FT_BTN
    je 3f
    cmp eax, FT_ROW
    je 2f
    cmp eax, FT_FIELD
    jne 9f
    test r12d, r12d
    jnz 9f
    cmp qword ptr [rip + dg_foc + VEC_len], 1   # the field: the first row the filter kept, else the
    jbe 9f                                      #   first thing after it
    mov ecx, 1
11: cmp rcx, [rip + dg_foc + VEC_len]
    jae 13f
    mov rax, [rip + dg_foc + VEC_ptr]
    mov ebx, [rax + rcx*4]
    inc rcx
    mov eax, ebx
    shr eax, 24
    cmp eax, FT_ROW
    jne 11b
    mov edi, ebx
    and edi, 0xffffff
    push rcx
    push rcx
    call row_at
    pop rcx
    pop rcx
    test dword ptr [rax + DGR_flags], DGF_FILTER
    jz 11b
    jmp 2f
13: mov rax, [rip + dg_foc + VEC_ptr]
    mov ebx, [rax + 4]
    mov eax, ebx
    shr eax, 24
    cmp eax, FT_ROW
    je 2f
    cmp eax, FT_BTN
    jne 9f
3:  mov edi, ebx
    and edi, 0xffffff
    call btn_at
    mov edi, [rax + DB_act]
    xor esi, esi
    xor edx, edx
    call do_act
    jmp 9f
2:  mov edi, ebx
    and edi, 0xffffff
    call row_at
    mov rdx, rax
    mov edi, [rax + DGR_act]
    test r12d, r12d
    jz 21f
    test dword ptr [rax + DGR_flags], DGF_STATE
    jz 21f
    mov edi, [rax + DGR_act2]
21: test edi, edi
    jz 9f
    mov rsi, [rdx + DGR_arg]
    call do_act
9:  EPILOGUE

# FN agentdlg_field() -> rax the dialog's filter field while it has the keys, else agentcard_field's
FN agentdlg_field
    cmp dword ptr [rip + dg_open], 0
    je under_field
    cmp qword ptr [rip + dg_ph], 0
    je 1f
    push rbx
    call focused_entry
    pop rbx
    shr eax, 24
    cmp eax, FT_FIELD
    jne 1f
    lea rax, [rip + dg_tf]
    ret
1:  push rbx                    # claude-chat-p7b: a form field that has the focus (agentdlg2.s)
    call focused_entry
    mov edi, eax
    call agentdlg2_field
    pop rbx
    ret

# FN agentdlg_paste(ptr, len): a paste while the panel has the keys: the dialog's field (one line), else
#   agentcard_paste's
FN agentdlg_paste
    cmp dword ptr [rip + dg_open], 0
    je under_paste
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call focused_entry          # claude-chat-p7b: into a form field (agentdlg2.s)
    mov edi, eax
    mov rsi, rbx
    mov rdx, r12
    call agentdlg2_paste
    test eax, eax
    jnz 9f
    call agentdlg_field
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call tf_insert
    mov dword ptr [rip + dg_scroll], 0
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# under_field() -> rax: no dialog: the session list's rename or search field (agentlist.s), else the card's
#   field with the keyboard (agentcard.s)
under_field:
    sub rsp, 8
    call aglist_field
    add rsp, 8
    test rax, rax
    jz agentcard_field
    ret

# under_paste(ptr, len): no dialog: the session list's field, else the card's (agentcard_paste)
under_paste:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call aglist_paste
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, r12
    call agentcard_paste
9:  EPILOGUE

# ---- claude-chat-p7b: what agentdlg2.s (the form rows) uses of the shell; nothing here changes it ----

# FN agentdlg_x_focus() -> eax the focus index (-1 none), edx its entry (type << 24 | index, 0 none), ecx 1
#   while the panel has the keys
FN agentdlg_x_focus
    call focused_entry
    mov edx, eax
    mov eax, [rip + dg_focus]
    xor ecx, ecx
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    sete cl
    ret

# FN agentdlg_x_set_focus(index): the focus on that focusable (from 0), the panel takes the keys
FN agentdlg_x_set_focus
    mov [rip + dg_focus], edi
    call keep_fkey
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov dword ptr [rip + g_dirty], 1
    ret

# FN agentdlg_x_move(dir): the focus one on (Tab), revealed
FN agentdlg_x_move
    jmp move

# FN agentdlg_x_act(act, arg, DR* or 0): a row's act, as a click does it
FN agentdlg_x_act
    jmp do_act

# FN agentdlg_x_row(i) -> rax the i-th row (DR*); agentdlg_x_nrows() -> rax the rows (0 closed)
FN agentdlg_x_row
    jmp row_at
FN agentdlg_x_nrows
    xor eax, eax
    cmp dword ptr [rip + dg_open], 0
    je 1f
    mov rax, [rip + dg_rows + VEC_len]
1:  ret

# FN agentdlg_x_touch(): the rows changed (laid out again)
FN agentdlg_x_touch
    inc qword ptr [rip + dg_rev]
    mov dword ptr [rip + g_dirty], 1
    ret

# FN agentdlg_x_lines(face, ptr, len, w) -> eax lines wrapped; agentdlg_x_wrap(face, x, y, w, ptr, len,
#   [argb]) -> eax lines drawn; agentdlg_x_fit(face, x, top, ptr, len, argb, [maxw]) one line cut;
#   agentdlg_x_ring(x, y, w, h) the focus ring; agentdlg_x_field_h() -> eax a one-line field's height
FN agentdlg_x_lines
    jmp lines_of
FN agentdlg_x_wrap
    jmp draw_wrap
FN agentdlg_x_fit
    jmp fit_text_s
FN agentdlg_x_ring
    jmp ring
FN agentdlg_x_field_h
    push rbx
    mov rax, [rip + ag_fui]
    mov [rip + dg_tf + TF_face], rax
    lea rdi, [rip + dg_tf]
    call ta_line_h_of
    PM ecx, MI_12
    add eax, ecx
    pop rbx
    ret

# ---- headless ----

# FN agentdlg_pick(n) -> eax 1: the n-th focusable (from 1) has the focus and acts, as Enter
FN agentdlg_pick
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    cmp dword ptr [rip + dg_open], 0
    je 9f
    call sync_layout
    xor eax, eax
    dec rbx
    js 9f
    cmp rbx, [rip + dg_foc + VEC_len]
    jae 9f
    mov [rip + dg_focus], ebx
    call keep_fkey
    call focused_entry
    mov edi, eax
    xor esi, esi
    call activate
    mov eax, 1
9:  EPILOGUE

# FN agentdlg_press(n) -> eax 1: button n (from 1) as a click
FN agentdlg_press
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    cmp dword ptr [rip + dg_open], 0
    je 9f
    dec rbx
    js 9f
    cmp rbx, [rip + dg_btns + VEC_len]
    jae 9f
    mov rdi, rbx
    call btn_at
    mov edi, [rax + DB_act]
    xor esi, esi
    xor edx, edx
    call do_act
    mov eax, 1
9:  EPILOGUE

# FN agentdlg_set_filter(ptr, len) -> eax 1: the filter's text
FN agentdlg_set_filter
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor eax, eax
    cmp dword ptr [rip + dg_open], 0
    je 9f
    cmp qword ptr [rip + dg_ph], 0
    je 9f
    lea rdi, [rip + dg_tf]
    mov rsi, rbx
    mov rdx, r12
    call tf_set
    inc qword ptr [rip + dg_tf + TF_revision]
    mov dword ptr [rip + dg_scroll], 0
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# FN agentdlg_dump(sb): print-agent-dialog: "dialog=NAME title=T state=loading|ready|error focus=N scroll=N
#   max=N filter=T back=0|1 acted=N" (focus from 1, 0 none; max the body's scroll range as last laid out),
#   "msg T", then the rows shown ("head T [hint H]", "pair L\tV", "text T", "bar L N% R", "item[N] T1\tT2\tT3
#   flags", "toggle[N] T on|off\tT2", "cols T1\tT2\tT3", "link[N] T", "gap"; [N] its focus index), "button N
#   LABEL [primary]", "box X,Y,W,H panel PX,PY,PW,PH" as drawn last (the box from the panel's left and top, the
#   panel in the window); "dialog=none" closed
FN agentdlg_dump
    PROLOGUE 16
    mov rbx, rdi
    cmp dword ptr [rip + dg_open], 0
    jne 1f
    lea rsi, [rip + .Ld_none]
    call sb_push_cstr
    EPILOGUE
1:  call sync_layout
    mov rdi, rbx
    lea rsi, [rip + .Ld_dialog]
    call sb_push_cstr
    mov rsi, [rip + dg_name]
    call push_or_dash
    lea rsi, [rip + .Ld_title]
    call push_lit
    mov rsi, [rip + dg_title]
    call push_or_dash
    lea rsi, [rip + .Ld_state]
    call push_lit
    mov eax, [rip + dg_state]
    lea rcx, [rip + state_names]
    mov rsi, [rcx + rax*8]
    call push_lit
    lea rsi, [rip + .Ld_focus]
    call push_lit
    mov eax, [rip + dg_focus]
    lea esi, [rax + 1]
    call push_num
    lea rsi, [rip + .Ld_scroll]
    call push_lit
    mov esi, [rip + dg_scroll]
    call push_num
    lea rsi, [rip + .Ld_max]
    call push_lit
    mov esi, [rip + dg_max]
    call push_num
    lea rsi, [rip + .Ld_filter]
    call push_lit
    lea rdi, [rip + dg_tf]
    call tf_text
    mov rdi, rbx
    mov rsi, rax
    call sb_push
    lea rsi, [rip + .Ld_back]
    call push_lit
    xor esi, esi
    cmp dword ptr [rip + dg_back], 0
    setne sil
    call push_num
    lea rsi, [rip + .Ld_acted]
    call push_lit
    mov esi, [rip + dg_acted]
    call push_num
    mov esi, 10
    mov rdi, rbx
    call sb_push_byte
    cmp qword ptr [rip + dg_msg + SB_len], 0
    je 2f
    lea rsi, [rip + .Ld_msg]
    call push_lit
    mov rdi, rbx
    mov rsi, [rip + dg_msg + SB_ptr]
    mov rdx, [rip + dg_msg + SB_len]
    call sb_push
    mov esi, 10
    mov rdi, rbx
    call sb_push_byte
2:  cmp dword ptr [rip + dg_state], DS_LOADING
    je 6f
    xor r12d, r12d
    xor r14d, r14d              # focus index of the rows (after a field)
    cmp qword ptr [rip + dg_ph], 0
    je 3f
    mov r14d, 1
3:  cmp r12, [rip + dg_rows + VEC_len]
    jae 6f
    mov rdi, r12
    call row_at
    mov r13, rax
    inc r12
    cmp dword ptr [r13 + DGR_h], 0
    je 3b
    mov ecx, [r13 + DGR_kind]
    lea rax, [rip + kind_names]
    mov rsi, [rax + rcx*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, r13
    call focusable
    test eax, eax
    jz 4f
    inc r14d
    mov rdi, rbx
    mov esi, '['
    call sb_push_byte
    mov esi, r14d
    call push_num
    mov rdi, rbx
    mov esi, ']'
    call sb_push_byte
4:  mov rdi, rbx
    mov rsi, r13
    call dump_row
    jmp 3b
6:  xor r12d, r12d
7:  cmp r12, [rip + dg_btns + VEC_len]
    jae 8f
    cmp dword ptr [rip + dg_state], DS_LOADING
    je 8f
    mov rdi, r12
    call btn_at
    mov r13, rax
    lea rsi, [rip + .Ld_button]
    call push_lit
    lea esi, [r12 + 1]
    call push_num
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rsi, [r13 + DB_label]
    call push_or_dash
    test dword ptr [r13 + DB_flags], DBF_PRIMARY
    jz 71f
    lea rsi, [rip + .Ld_primary]
    call push_lit
71: mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r12
    jmp 7b
8:  cmp dword ptr [rip + dg_drawn], 0
    je 9f
    lea rsi, [rip + .Ld_box]
    call push_lit
    mov esi, [rip + dg_rect]
    sub esi, [rip + dg_panel]
    call push_num
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov esi, [rip + dg_rect + 4]
    sub esi, [rip + dg_panel + 4]
    call push_num
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov esi, [rip + dg_rect + 8]
    call push_num
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov esi, [rip + dg_rect + 12]
    call push_num
    lea rsi, [rip + .Ld_panel]  # " panel X,Y,W,H": the panel in the window
    call push_lit
    lea r12, [rip + dg_panel]
    xor r13d, r13d
81: mov esi, [r12 + r13*4]
    call push_num
    inc r13d
    cmp r13d, 4
    jae 82f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    jmp 81b
82: mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# push_lit(rsi cstr), push_or_dash(rsi cstr or 0), push_num(esi signed) onto agentdlg_dump's rbx
push_lit:
    mov rdi, rbx
    jmp sb_push_cstr
push_or_dash:
    mov rdi, rbx
    test rsi, rsi
    jnz sb_push_cstr
    lea rsi, [rip + .Ldash]
    jmp sb_push_cstr
push_num:
    push r12
    mov r12d, esi
    test r12d, r12d
    jns 1f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    neg r12d
1:  mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    pop r12
    ret

# dump_row(sb, DR*): " T1\tT2\tT3" as its kind shows them, its flags, a line feed
dump_row:
    cmp dword ptr [rsi + DGR_kind], DGK_FIELD   # claude-chat-p7b: the form rows (agentdlg2.s)
    jae agentdlg2_dump_row
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + DGR_kind]
    cmp eax, DGK_GAP
    je 8f
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rsi, [r12 + DGR_t1]
    call push_or_empty
    mov eax, [r12 + DGR_kind]
    cmp eax, DGK_BAR
    jne 1f
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rsi, [r12 + DGR_val]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, '%'
    call sb_push_byte
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rsi, [r12 + DGR_t3]
    call push_or_empty
    jmp 8f
1:  cmp eax, DGK_TOGGLE
    jne 2f
    lea rsi, [rip + .Ld_on]
    test dword ptr [r12 + DGR_flags], DGF_ON
    jnz 11f
    lea rsi, [rip + .Ld_off]
11: mov rdi, rbx
    call sb_push_cstr
    cmp qword ptr [r12 + DGR_t2], 0
    je 8f
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rsi, [r12 + DGR_t2]
    call push_or_empty
    jmp 8f
2:  cmp eax, DGK_HEAD
    jne 3f
    cmp qword ptr [r12 + DGR_t3], 0
    je 8f
    lea rsi, [rip + .Ld_hint]
    mov rdi, rbx
    call sb_push_cstr
    mov rsi, [r12 + DGR_t3]
    call push_or_empty
    jmp 8f
3:  cmp eax, DGK_TEXT
    je 7f
    cmp eax, DGK_LINK
    je 7f
    mov rdi, rbx                # pair, item, cols: the other two
    mov esi, 9
    call sb_push_byte
    mov rsi, [r12 + DGR_t2]
    call push_or_empty
    cmp dword ptr [r12 + DGR_kind], DGK_PAIR
    je 7f
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rsi, [r12 + DGR_t3]
    call push_or_empty
7:  mov eax, [r12 + DGR_flags]   # the flags that show
    test eax, DGF_CHECK
    jz 71f
    lea rsi, [rip + .Ld_check]
    mov rdi, rbx
    call sb_push_cstr
71: test dword ptr [r12 + DGR_flags], DGF_OFF
    jz 72f
    lea rsi, [rip + .Ld_disabled]
    mov rdi, rbx
    call sb_push_cstr
72: test dword ptr [r12 + DGR_flags], DGF_ERROR
    jz 73f
    lea rsi, [rip + .Ld_error]
    mov rdi, rbx
    call sb_push_cstr
73: test dword ptr [r12 + DGR_flags], DGF_STATE
    jz 8f
    lea rsi, [rip + .Ld_pill]
    mov rdi, rbx
    call sb_push_cstr
8:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# push_or_empty(rsi cstr or 0) onto dump_row's rbx
push_or_empty:
    test rsi, rsi
    jz 1f
    mov rdi, rbx
    jmp sb_push_cstr
1:  ret

# FN agentdlg_fit_dump(sb): the open dialog's layout at panel sizes 8, 13, 32 and widths 240 to 900 (step
#   60), a line each: "size=S w=W box=X,W,H head=H field=F body=B content=C foot=F rows=R in=0|1" (X from the
#   panel's left; in 1 when the box and its buttons lie inside the panel); the setting is the user's again
#   after it
FN agentdlg_fit_dump
    PROLOGUE 16
    mov rbx, rdi
    cmp dword ptr [rip + dg_open], 0
    jne 1f
    lea rsi, [rip + .Ld_none]
    call sb_push_cstr
    EPILOGUE
1:  mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    mov eax, [rip + dg_scroll]
    mov [rsp + 4], eax
    xor r12d, r12d
2:  cmp r12d, SIZES_N
    jae 8f
    lea rax, [rip + fit_sizes]
    mov eax, [rax + r12*4]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    mov r13d, 240
3:  cmp r13d, 900
    ja 7f
    xor edi, edi
    xor esi, esi
    mov edx, r13d
    mov ecx, 700
    call geom
    lea rsi, [rip + .Lf_size]
    call push_lit
    mov esi, [rip + cfg_agents_font_size]
    call push_num
    lea rsi, [rip + .Lf_w]
    call push_lit
    mov esi, r13d
    call push_num
    lea rsi, [rip + .Lf_box]
    call push_lit
    mov esi, [rip + g_bx]
    call push_num
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov esi, [rip + g_bw]
    call push_num
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov esi, [rip + g_bh]
    call push_num
    lea rsi, [rip + .Lf_head]
    call push_lit
    mov esi, [rip + g_head]
    call push_num
    lea rsi, [rip + .Lf_field]
    call push_lit
    mov esi, [rip + g_fh]
    call push_num
    lea rsi, [rip + .Lf_body]
    call push_lit
    mov esi, [rip + g_bodyh]
    call push_num
    lea rsi, [rip + .Lf_content]
    call push_lit
    mov esi, [rip + dg_content]
    call push_num
    lea rsi, [rip + .Lf_foot]
    call push_lit
    mov esi, [rip + g_foot]
    call push_num
    lea rsi, [rip + .Lf_rows]
    call push_lit
    mov esi, [rip + g_brows]
    call push_num
    lea rsi, [rip + .Lf_in]
    call push_lit
    call fits
    mov esi, eax
    call push_num
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add r13d, 60
    jmp 3b
7:  inc r12d
    jmp 2b
8:  mov eax, [rsp]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    mov eax, [rsp + 4]
    mov [rip + dg_scroll], eax
    mov dword ptr [rip + dg_lay_w], 0       # laid out again at the panel's own size
    EPILOGUE

# fits() -> eax 1 when the box (from x 0, panel width r13d, height 700) and every button lie inside it
fits:
    xor eax, eax
    cmp dword ptr [rip + g_bx], 0
    jl 9f
    mov ecx, [rip + g_bx]
    add ecx, [rip + g_bw]
    cmp ecx, r13d
    jg 9f
    xor ecx, ecx
1:  cmp rcx, [rip + dg_btns + VEC_len]
    jae 8f
    imul rdx, rcx, DB_SIZE
    add rdx, [rip + dg_btns + VEC_ptr]
    inc rcx
    mov r8d, [rdx + DB_x]
    add r8d, [rdx + DB_w]
    mov r9d, [rip + g_bw]
    sub r9d, [rip + g_pad]
    sub r9d, [rip + g_pad]
    cmp r8d, r9d
    jg 9f
    jmp 1b
8:  mov eax, 1
9:  ret

# ---- agent-dialog test: the shell alone (every kind of row, a list to filter, a switch, two buttons) ----

# FN agentdlg_test() -> eax 1: the test dialog over the panel (no driver)
FN agentdlg_test
    PROLOGUE 16
    xor edi, edi
    lea rsi, [rip + .Lt_name]
    lea rdx, [rip + .Lt_title]
    lea rcx, [rip + test_ops]
    call agentdlg_open
    mov dword ptr [rip + dg_acted], 0
    lea rdi, [rip + .Lt_filter]
    call agentdlg_filter
    call test_build
    mov eax, 1
    EPILOGUE

# test_build(): the test dialog's rows
test_build:
    PROLOGUE 16
    call agentdlg_begin
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_section]
    call agentdlg_ctext
    mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov rbx, rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_label]
    call agentdlg_ctext
    mov rdi, rbx
    mov esi, 1
    lea rdx, [rip + .Lt_value]
    call agentdlg_ctext
    mov edi, DGK_TEXT
    mov esi, DGF_MUTED
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_para]
    call agentdlg_ctext
    mov edi, DGK_BAR
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov rbx, rax
    mov qword ptr [rax + DGR_val], 42
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_bar]
    call agentdlg_ctext
    mov rdi, rbx
    mov esi, 2
    lea rdx, [rip + .Lt_resets]
    call agentdlg_ctext
    mov esi, 0                  # the switch
    cmp dword ptr [rip + dg_test_on], 0
    je 1f
    mov esi, DGF_ON
1:  mov edi, DGK_TOGGLE
    mov edx, TA_TOGGLE
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_switch]
    call agentdlg_ctext
    mov edi, DGK_COLS
    mov esi, DGF_MUTED
    xor edx, edx
    call agentdlg_row
    mov rbx, rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_c1]
    call agentdlg_ctext
    mov rdi, rbx
    mov esi, 1
    lea rdx, [rip + .Lt_c2]
    call agentdlg_ctext
    mov rdi, rbx
    mov esi, 2
    lea rdx, [rip + .Lt_c3]
    call agentdlg_ctext
    mov edi, DGK_COLS
    mov esi, DGF_SWATCH
    xor edx, edx
    call agentdlg_row
    mov rbx, rax
    COLOR eax, T_ACCENT
    mov [rbx + DGR_val], rax
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lt_c4]
    call agentdlg_ctext
    mov rdi, rbx
    mov esi, 1
    lea rdx, [rip + .Lt_c5]
    call agentdlg_ctext
    mov rdi, rbx
    mov esi, 2
    lea rdx, [rip + .Lt_c6]
    call agentdlg_ctext
    mov edi, DGK_LINK
    xor esi, esi
    mov edx, TA_FIRST
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_link]
    call agentdlg_ctext
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov rbx, rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_list]
    call agentdlg_ctext
    mov rdi, rbx
    mov esi, 2
    lea rdx, [rip + .Lt_hint]
    call agentdlg_ctext
    xor r12d, r12d              # the list: "Item N", every third with a pill, the second checked
2:  cmp r12d, TEST_ITEMS
    jae 4f
    xor esi, esi
    mov eax, r12d
    xor edx, edx
    mov ecx, 3
    div ecx
    or esi, DGF_FILTER
    test edx, edx
    jnz 21f
    or esi, DGF_STATE
21: cmp r12d, 1
    jne 22f
    or esi, DGF_CHECK
22: mov edi, DGK_ITEM
    lea edx, [r12 + 100]
    call agentdlg_row
    mov rbx, rax
    mov dword ptr [rbx + DGR_act2], TA_STATE
    mov [rbx + DGR_arg], r12
    lea rdi, [rip + dsb]
    call sb_clear
    lea rdi, [rip + dsb]
    lea rsi, [rip + .Lt_item]
    call sb_push_cstr
    lea rdi, [rip + dsb]
    lea esi, [r12 + 1]
    call sb_push_u64
    mov rdi, rbx
    xor esi, esi
    mov rdx, [rip + dsb + SB_ptr]
    mov rcx, [rip + dsb + SB_len]
    call agentdlg_text
    mov rdi, rbx
    mov esi, 1
    lea rdx, [rip + .Lt_desc]
    test r12d, 1
    jz 23f
    lea rdx, [rip + .Lt_desc2]
23: call agentdlg_ctext
    mov rdi, rbx
    mov esi, 2
    lea rdx, [rip + .Lt_trail]
    test dword ptr [rbx + DGR_flags], DGF_STATE
    jz 24f
    lea rdx, [rip + .Lt_on]
    cmp dword ptr [rip + dg_test_state], 0
    je 24f
    lea rdx, [rip + .Lt_off]
24: call agentdlg_ctext
    inc r12d
    jmp 2b
4:  lea rdi, [rip + .Lt_cancel]
    mov esi, DA_CLOSE
    mov edx, DBF_NUM
    call agentdlg_button
    lea rdi, [rip + .Lt_ok]
    mov esi, TA_OK
    mov edx, DBF_NUM | DBF_PRIMARY
    call agentdlg_button
    EPILOGUE

# test_act(act, arg, DR*): agent-dialog test's acts: noted (acted=); the switch flips, a pill's state flips,
#   OK shows "Saved." on a second page with Back
test_act:
    PROLOGUE
    mov [rip + dg_acted], edi
    cmp edi, TA_TOGGLE
    jne 1f
    xor dword ptr [rip + dg_test_on], 1
    call test_build
    jmp 9f
1:  cmp edi, TA_STATE
    jne 2f
    xor dword ptr [rip + dg_test_state], 1
    call test_build
    jmp 9f
2:  cmp edi, TA_OK
    jne 3f
    call agentdlg_begin
    mov edi, DGK_TEXT
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    lea rdx, [rip + .Lt_saved]
    call agentdlg_ctext
    mov edi, TA_BACK
    call agentdlg_back
    jmp 9f
3:  cmp edi, TA_BACK
    jne 9f
    xor edi, edi
    call agentdlg_back
    call test_build
9:  EPILOGUE

# ---- headless commands (aictl.s's table: one block) ----

# cargs(rest ptr, len) -> rax the first word's ptr, rdx its len; cmd_rest/cmd_len: what follows (trimmed)
cargs:
    xor ecx, ecx
1:  cmp rcx, rsi                # the blanks before it
    jae 2f
    cmp byte ptr [rdi + rcx], ' '
    jne 2f
    inc rcx
    jmp 1b
2:  lea rax, [rdi + rcx]
    mov r8, rcx
3:  cmp rcx, rsi
    jae 4f
    cmp byte ptr [rdi + rcx], ' '
    je 4f
    inc rcx
    jmp 3b
4:  mov rdx, rcx
    sub rdx, r8
5:  cmp rcx, rsi
    jae 6f
    cmp byte ptr [rdi + rcx], ' '
    jne 6f
    inc rcx
    jmp 5b
6:  lea r9, [rdi + rcx]
    mov [rip + cmd_rest], r9
    sub rsi, rcx
    mov [rip + cmd_len], rsi
    ret

# FN agentdlg_c_open(out, rest, len) -> rax 0, -1: agent-dialog NAME [ARG]: test (the shell alone), else a
#   command's dialog as the command menu runs it for the box's conversation (status, usage, context,
#   output-style, skills, memory, instructions)
FN agentdlg_c_open
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call cargs
    mov rbx, rax
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lt_name]
    call str_eq_cstr
    test eax, eax
    jz 1f
    call agentdlg_test
    xor eax, eax
    EPILOGUE
1:  lea r13, [rip + dlg_names]
2:  mov rdx, [r13]
    test rdx, rdx
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 3f
    add r13, 16
    jmp 2b
3:  call agentext_box_owner     # the box's conversation (0: its draft), its driver's kind
    test edx, edx
    jz 8f
    mov rdi, rax
    mov esi, edx
    mov edx, [r13 + 8]
    mov rcx, [rip + cmd_rest]
    mov r8, [rip + cmd_len]
    call agentpop_run
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# FN agentdlg_link(url cstr) -> eax 1 when it is "dialog:NAME" (a band's link): that dialog's command runs
#   for the box's conversation, as agent-dialog NAME
FN agentdlg_link
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    mov rdi, rbx
    mov esi, 7
    lea rdx, [rip + .Ldlg_scheme]
    call str_eq_cstr
    test eax, eax
    jz 9f
    lea rdi, [rbx + 7]
    call strlen
    lea rsi, [rbx + 7]
    mov rdx, rax
    lea rdi, [rip + dsb]
    call sb_clear
    lea rdi, [rip + dsb]
    call sb_push
    lea rdi, [rip + dsb]
    xor esi, esi
    mov rdx, [rip + dsb + SB_ptr]
    mov rcx, [rip + dsb + SB_len]
    xor edi, edi
    mov rsi, rdx
    mov rdx, rcx
    call agentdlg_c_open
    mov eax, 1
9:  EPILOGUE

# FN agentdlg_c_pick(out, rest, len): agent-dialog-pick N (the N-th focusable, from 1, as Enter)
FN agentdlg_c_pick
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call cargs
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov rdi, rax
    call agentdlg_pick
    jmp c_result

# FN agentdlg_c_press(out, rest, len): agent-dialog-press N (button N, from 1, as a click)
FN agentdlg_c_press
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call cargs
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov rdi, rax
    call agentdlg_press
    jmp c_result

# FN agentdlg_c_filter(out, rest, len): agent-dialog-filter [TEXT] (the filter's text, the rest of the line)
FN agentdlg_c_filter
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call agentdlg_set_filter
    jmp c_result

# FN agentdlg_c_close(out, rest, len): agent-dialog-close (error when none is open)
FN agentdlg_c_close
    PROLOGUE
    xor eax, eax
    cmp dword ptr [rip + dg_open], 0
    je c_result
    call agentdlg_close
    mov eax, 1
    jmp c_result

# FN agentdlg_c_print(out, rest, len): print-agent-dialog [fit]
FN agentdlg_c_print
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call cargs
    mov rdi, rbx
    test rdx, rdx
    jnz 1f
    call agentdlg_dump
    xor eax, eax
    EPILOGUE
1:  call agentdlg_fit_dump
    xor eax, eax
    EPILOGUE

# c_result: a command's end, inside its PROLOGUE: eax 1 -> rax 0 (ok), else -1
c_result:
    test eax, eax
    jz 1f
    xor eax, eax
    EPILOGUE
1:  mov rax, -1
    EPILOGUE

.bss
.p2align 3
cmd_rest: .quad 0
cmd_len: .quad 0
.text

.section .rodata
.p2align 3
test_ops: .quad test_act, 0
state_names: .quad .Ls_loading, .Ls_ready, .Ls_error
kind_names: .quad .Ldash, .Lk_head, .Lk_pair, .Lk_text, .Lk_bar, .Lk_item, .Lk_toggle, .Lk_cols, .Lk_link
    .quad .Lk_gap
    .quad agentdlg2_n_field, agentdlg2_n_option, agentdlg2_n_tabs  # claude-chat-p7b (agentdlg2.s)
fit_sizes: .long 8, 13, 32
.p2align 3
dlg_names:                      # agent-dialog's names and their commands
    .quad .Ln_status, ACT_STATUS, .Ln_usage, ACT_USAGE, .Ln_context, ACT_CONTEXT
    .quad .Ln_ostyle, ACT_OSTYLE, .Ln_skills, ACT_SKILLS, .Ln_memory, ACT_MEMORY
    .quad .Ln_instruct, ACT_INSTRUCT
    .quad .Ln2_mcp, ACT_MCP, .Ln2_hooks, ACT_HOOKS, .Ln2_perms, ACT_PERMS   # claude-chat-p7b (claude_dlg2.s)
    .quad .Ln2_sandbox, ACT_SANDBOX, .Ln2_plugins, ACT_PLUGINS, 0, 0
.globl agentdlg_n_open, agentdlg_n_pick, agentdlg_n_press, agentdlg_n_filter, agentdlg_n_close
.globl agentdlg_n_print
agentdlg_n_open: .asciz "agent-dialog"
agentdlg_n_pick: .asciz "agent-dialog-pick"
agentdlg_n_press: .asciz "agent-dialog-press"
agentdlg_n_filter: .asciz "agent-dialog-filter"
agentdlg_n_close: .asciz "agent-dialog-close"
agentdlg_n_print: .asciz "print-agent-dialog"
.Ldlg_scheme: .asciz "dialog:"
.Ln_status: .asciz "status"
.Ln_usage: .asciz "usage"
.Ln_context: .asciz "context"
.Ln_ostyle: .asciz "output-style"
.Ln_skills: .asciz "skills"
.Ln_memory: .asciz "memory"
.Ln_instruct: .asciz "instructions"
.Ln2_mcp: .asciz "mcp"                 # claude-chat-p7b
.Ln2_hooks: .asciz "hooks"
.Ln2_perms: .asciz "permissions"
.Ln2_sandbox: .asciz "sandbox"
.Ln2_plugins: .asciz "plugins"
.Ls_loading: .asciz "loading"
.Ls_ready: .asciz "ready"
.Ls_error: .asciz "error"
.Lk_head: .asciz "head"
.Lk_pair: .asciz "pair"
.Lk_text: .asciz "text"
.Lk_bar: .asciz "bar"
.Lk_item: .asciz "item"
.Lk_toggle: .asciz "toggle"
.Lk_cols: .asciz "cols"
.Lk_link: .asciz "link"
.Lk_gap: .asciz "gap"
.Ldash: .asciz "-"
.Ld_none: .asciz "dialog=none\n"
.Ld_dialog: .asciz "dialog="
.Ld_title: .asciz " title="
.Ld_state: .asciz " state="
.Ld_focus: .asciz " focus="
.Ld_scroll: .asciz " scroll="
.Ld_max: .asciz " max="
.Ld_filter: .asciz " filter="
.Ld_back: .asciz " back="
.Ld_acted: .asciz " acted="
.Ld_msg: .asciz "msg "
.Ld_button: .asciz "button "
.Ld_primary: .asciz " primary"
.Ld_box: .asciz "box "
.Ld_panel: .asciz " panel "
.Ld_on: .asciz " on"
.Ld_off: .asciz " off"
.Ld_hint: .asciz " hint "
.Ld_check: .asciz " check"
.Ld_disabled: .asciz " disabled"
.Ld_error: .asciz " error"
.Ld_pill: .asciz " pill"
.Lf_size: .asciz "size="
.Lf_w: .asciz " w="
.Lf_box: .asciz " box="
.Lf_head: .asciz " head="
.Lf_field: .asciz " field="
.Lf_body: .asciz " body="
.Lf_content: .asciz " content="
.Lf_foot: .asciz " foot="
.Lf_rows: .asciz " rows="
.Lf_in: .asciz " in="
.Lw3: .asciz "100.0%"
.Lw2: .asciz "1000.0k"
.Lagent: .asciz "The agent"
.Lended: .asciz " ended before it answered."
.Lt_name: .asciz "test"
.Lt_title: .asciz "Dialog shell"
.Lt_filter: .asciz "Filter items\342\200\246"
.Lt_section: .asciz "Section"
.Lt_label: .asciz "Working folder"
.Lt_value: .asciz "/a/rather/long/path/to/a/project/that/wraps/at/narrow/widths"
.Lt_para: .asciz "A muted paragraph that wraps at the box's width, as the extension's dialogs say what they show."
.Lt_bar: .asciz "Weekly (7 day)"
.Lt_resets: .asciz "Resets Tue at 21:00"
.Lt_switch: .asciz "A switch"
.Lt_c1: .asciz "Category"
.Lt_c2: .asciz "Tokens"
.Lt_c3: .asciz "Usage"
.Lt_c4: .asciz "System prompt"
.Lt_c5: .asciz "3.6k"
.Lt_c6: .asciz "0.4%"
.Lt_link: .asciz "A link"
.Lt_list: .asciz "List"
.Lt_hint: .asciz "/hint"
.Lt_item: .asciz "Item "
.Lt_desc: .asciz "Its description, muted under it"
.Lt_desc2: .asciz "Another description"
.Lt_trail: .asciz "1.2k"
.Lt_on: .asciz "On"
.Lt_off: .asciz "Off"
.Lt_cancel: .asciz "Cancel"
.Lt_ok: .asciz "OK"
.Lt_saved: .asciz "Saved."
