# Conversation tabs (TAB_AGENT; phase 4 task 13, open point 7's one view): a conversation opened in an editor
# tab, as the extension's editor panel. There is one view of a conversation (agents.s's thread, box, cards and
# popups): the panel hosts it, or the active conversation tab does, and the panel then shows its list. A tab
# keeps its conversation (AS*, its file's path for the session file) and the place it was scrolled to while
# another holds the view.
#
#   - The active conversation tab takes the view when it becomes active (agtab_sync, at the start of a
#     frame); a tab that stops being active gives it back (the panel's list). Two conversation tabs: the
#     active one hosts, the other draws nothing (it is not visible).
#   - The panel opening another conversation while a tab hosts (a click in its list): the view leaves the tab
#     for the panel; the tab draws "This conversation is shown when its tab has the view. Click to show it
#     here." and a press takes it back. The panel opening a conversation a tab has: that tab is activated.
#   - While a tab hosts, what the view shows is the tab's (the header's history, New session, a draft that
#     sends): the tab follows it. The view showing nothing (its conversation left the list): "This
#     conversation is no longer in the list." and Close.
#   - Closing the hosting tab gives the view back to the panel's list; nothing else closes.
#   - The label: the title cut at 24 characters and "…", or the driver's name; before it a dot: T_WARNING while
#     the conversation waits for the user (a card, a held start), the driver's colour while a turn ended that
#     no view showed in a focused window (agtab_turn_end), none otherwise.
#   - The status bar item (agents_status_item): the default driver's glyph and name, tip "Open NAME", a click
#     runs Agents: Open; a T_WARNING dot when a conversation of the window waits for the user.
#   - Commands: Agents: Open (agtab_cmd_open: where [agents] location says), Open in New Tab, Open in Side
#     Panel, New Conversation; the last two choices write [agents] location.
#
# Nothing here knows Claude: kinds, names, glyphs and colours come from the drivers' tables.
#
#   agtab_open(AS* or 0, kind) -> rax tab index or -1   a tab for that conversation (0: a new draft of kind)
#   agtab_sync()                       app.s, a frame's start: the active tab takes or gives back the view
#   agtab_has(AS*) -> eax 1            a tab has that conversation (agentlist.s: the ring, "Open in a tab")
#   agtab_hosting() -> eax 1           a tab hosts the view (the panel draws its list; Escape stops there)
#   agtab_opening(AS*, from_panel) -> eax 1 handled   open_session's first step (agents.s)
#   agtab_draw(tab index, x, y, w, h)  center_draw's
#   agtab_label(tab flags) -> cstr     app_tab_label's
#   agtab_tab_closed(tab flags)        app_close_tab_now's
#   agtab_tab_dot(TAB*, x, y, h) -> eax its width; agtab_dot_w(TAB*) -> eax   tab_draw's, tab_width's
#   agtab_turn_end(AS*)                ev_turn_end's (agent_drv.s): unseen when no view shows it
#   agtab_new_made(AS*)                agent_new's: the draft a tab hosts became that conversation
#   agents_status_item(right, y, h, min x) -> eax the right edge left of it   statusbar_draw's
#   agtab_c_print (print-agent-tabs)   headless: the tabs, then the status item
.include "rhun.inc"

.equ AGT_MAX, 16
.equ AGT_SHIFT, 16              # TAB_flags >> AGT_SHIFT: its slot + 1 (TAB_VIEW's way)
.equ AGT_CUT, 24                # characters of the title a label shows
.equ ID_AGT, 0x7c0000
.equ ID_AGT_AREA, ID_AGT + 1
.equ ID_AGT_CLOSE, ID_AGT + 2
.equ ID_AGT_STATUS, ID_AGT + 3

STRUCT
F ATB_used, 4
F ATB_kind, 4           # AG_*: the conversation's kind (a draft's too)
F ATB_as, 8             # its conversation, or 0 (a draft, or not found yet)
F ATB_path, 8           # owned cstr: the conversation's file, or 0
F ATB_ltitle, 8         # the AS_title the label was made from
F ATB_unseen, 4         # a turn ended that no view showed in a focused window
F ATB_anch, 4           # ATB_place holds a place
F ATB_place, 16         # where its thread was scrolled (agents_anchor_get)
F ATB_seq, 4            # the order they were activated in (Agents: Open takes the latest)
F ATB_pad, 4
F ATB_label, 128        # cstr
ENDSTRUCT ATB_SIZE

.bss
.p2align 3
at_recs: .zero ATB_SIZE * AGT_MAX
at_host: .quad 0                   # the record hosting the view, 0: the panel
at_last_active: .quad 0            # the record whose tab was active at the last sync, 0 none
at_busy: .long 0                   # agtab is opening a conversation itself (agtab_opening lets it through)
at_seq: .long 0
at_pend_close: .quad 0             # a record whose tab closes after the frame (its Close link), 0 none
at_restore_active: .quad 0         # session_restore: the conversation tab that was active
at_lk_pending: .long 0             # a link waits to be applied (agtab_link)
at_lk_kind: .long 0                #   its agent's kind
at_lk_has_prompt: .long 0
at_lk_id: .zero 80                 #   the conversation it names, or empty
at_lk_prompt: .zero SB_SIZE        #   the prompt for its box
at_sb: .zero SB_SIZE
at_pl: .zero SB_SIZE            # an install-plugin link's plugin (then its source, NUL-separated), its source
at_pm: .zero SB_SIZE
at_pm_has: .long 0              #   the link named a marketplace
at_tipbuf: .zero 160

.text

# rec_of(slot) -> rax its record
at_rec_of:
    movsxd rax, edi
    imul rax, rax, ATB_SIZE
    lea rcx, [rip + at_recs]
    add rax, rcx
    ret

# flags_rec(TAB_flags) -> rax its record, 0 none
at_flags_rec:
    mov rax, rdi
    shr rax, AGT_SHIFT
    dec eax
    js 8f
    cmp eax, AGT_MAX
    jae 8f
    mov edi, eax
    call at_rec_of
    cmp dword ptr [rax + ATB_used], 0
    je 8f
    ret
8:  xor eax, eax
    ret

# rec_slot(rec) -> eax its slot
at_rec_slot:
    mov rax, rdi
    lea rcx, [rip + at_recs]
    sub rax, rcx
    xor edx, edx
    mov ecx, ATB_SIZE
    div rcx
    ret

# rec_tab(rec) -> rax the index of its tab, -1 none
at_rec_tab:
    call at_rec_slot
    lea edx, [rax + 1]
    xor ecx, ecx
1:  cmp rcx, [rip + g_tabs + VEC_len]
    jae 8f
    imul rax, rcx, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    cmp qword ptr [rax + TAB_kind], TAB_AGENT
    jne 2f
    mov rax, [rax + TAB_flags]
    shr rax, AGT_SHIFT
    cmp eax, edx
    je 3f
2:  inc rcx
    jmp 1b
3:  mov rax, rcx
    ret
8:  mov rax, -1
    ret

# cur_rec() -> rax the active tab's record when it is a conversation tab, else 0
at_cur_rec:
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 8f
    cmp rdi, [rip + g_tabs + VEC_len]
    jae 8f
    imul rax, rdi, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    cmp qword ptr [rax + TAB_kind], TAB_AGENT
    jne 8f
    mov rdi, [rax + TAB_flags]
    jmp at_flags_rec
8:  xor eax, eax
    ret

# find_as(AS*) -> rax the record of that conversation, 0 none
at_find_as:
    xor eax, eax
    test rdi, rdi
    jz 9f
    xor ecx, ecx
1:  cmp ecx, AGT_MAX
    jae 8f
    movsxd rax, ecx
    imul rax, rax, ATB_SIZE
    lea rdx, [rip + at_recs]
    add rax, rdx
    cmp dword ptr [rax + ATB_used], 0
    je 2f
    cmp [rax + ATB_as], rdi
    je 9f
2:  inc ecx
    jmp 1b
8:  xor eax, eax
9:  ret

# bind(rec, AS*): the record is that conversation's: its kind, its file, its label made again
at_bind:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov [rbx + ATB_as], r12
    mov qword ptr [rbx + ATB_ltitle], -1
    mov dword ptr [rbx + ATB_anch], 0
    test r12, r12
    jz 9f
    mov eax, [r12 + AS_kind]
    mov [rbx + ATB_kind], eax
    mov rdi, [rbx + ATB_path]
    call mem_free
    mov qword ptr [rbx + ATB_path], 0
    mov rdi, [r12 + AS_path]
    test rdi, rdi
    jz 9f
    call strlen
    mov rdi, [r12 + AS_path]
    mov rsi, rax
    call mem_dup
    mov [rbx + ATB_path], rax
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# draft_kind() -> rax the built-in kind a new draft is being written for, 0 none (an extension's: 0)
at_draft_kind:
    sub rsp, 8
    call agentext_new_active
    add rsp, 8
    cmp rax, 16
    jb 1f
    xor eax, eax
1:  ret

# save(rec): the place of its thread, while the view shows its conversation
at_save:
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    call agents_viewed
    test rax, rax
    jz 9f
    cmp rax, [rbx + ATB_as]
    jne 9f
    lea rdi, [rbx + ATB_place]
    call agents_anchor_get
    mov dword ptr [rbx + ATB_anch], 1
9:  EPILOGUE

# take(rec): the record hosts the view: its conversation opened in it at its place, or its draft
at_take:
    PROLOGUE
    mov rbx, rdi
    mov dword ptr [rip + at_busy], 1
    mov rdi, [rip + at_host]
    cmp rdi, rbx
    je 1f
    call at_save
1:  mov [rip + at_host], rbx
    inc dword ptr [rip + at_seq]
    mov eax, [rip + at_seq]
    mov [rbx + ATB_seq], eax
    mov dword ptr [rbx + ATB_unseen], 0
    mov r12, [rbx + ATB_as]
    test r12, r12
    jnz 2f
    mov rdi, [rbx + ATB_path]   # restored from the session file: found once the list has it
    test rdi, rdi
    jz 5f
    call agents_by_path
    test rax, rax
    jz 4f
    mov r12, rax
    mov [rbx + ATB_as], rax
2:  mov rdi, r12
    call agents_index_of
    test rax, rax
    js 4f
    mov r13, rax
    call agents_viewed
    cmp rax, r12
    je 3f                       # (shown already: its place stays)
    mov rdi, r13
    call agents_open
    cmp dword ptr [rbx + ATB_anch], 0
    je 3f
    lea rdi, [rbx + ATB_place]
    mov rsi, r12
    call agents_anchor_set
3:  jmp 8f
4:  call agents_back            # not in the list (yet): the view shows nothing, the tab says why
    jmp 8f
5:  mov edi, [rbx + ATB_kind]   # a draft
    call at_draft_kind
    test rax, rax
    jnz 8f
    mov edi, [rbx + ATB_kind]
    call agentext_new_kind
8:  mov dword ptr [rip + at_busy], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# release(): the hosting tab gives the view back: the panel shows its list
at_release:
    PROLOGUE
    mov rdi, [rip + at_host]
    test rdi, rdi
    jz 9f
    call at_save
    mov qword ptr [rip + at_host], 0
    mov dword ptr [rip + at_busy], 1
    mov ebx, [rip + g_focus]
    call agents_back
    mov [rip + g_focus], ebx
    mov dword ptr [rip + at_busy], 0
9:  EPILOGUE

# keys_in(): the active conversation tab's box has the keys
at_keys_in:
    mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    mov dword ptr [rip + g_dirty], 1
    ret

# FN agtab_sync(): the active tab takes the view when it became active; a tab that stopped being active
#   gives it back (a frame's start, and before a tab draws)
FN agtab_sync
    PROLOGUE
    call agtab_after            # a Close link clicked in the last frame
    call at_link_apply          # a link that waited for the list
    call at_cur_rec
    mov rbx, rax
    cmp rbx, [rip + at_last_active]
    je 9f
    mov [rip + at_last_active], rbx
    mov rax, [rip + at_host]
    test rax, rax
    jz 1f
    cmp rax, rbx
    je 1f
    call at_release
1:  test rbx, rbx
    jz 9f
    mov rdi, rbx
    call at_take
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 9f
    call at_keys_in
9:  EPILOGUE

# FN agtab_has(AS*) -> eax 1 when a conversation tab of the window has that conversation (the list's ring)
FN agtab_has
    sub rsp, 8
    call at_find_as
    add rsp, 8
    test rax, rax
    setnz al
    movzx eax, al
    ret

# FN agtab_hosting() -> eax 1 when a conversation tab hosts the view
FN agtab_hosting
    xor eax, eax
    cmp qword ptr [rip + at_host], 0
    setne al
    ret

# FN agtab_opening(AS*, from_panel) -> eax 1 when the opening was handled here: a conversation a tab has is
#   shown in its tab; an opening from the panel while a tab hosts takes the view to the panel
FN agtab_opening
    PROLOGUE
    xor r13d, r13d
    cmp dword ptr [rip + at_busy], 0
    jne 9f
    mov r12d, esi
    call at_find_as
    mov rbx, rax
    test rbx, rbx
    jz 5f
    cmp rbx, [rip + at_host]
    jne 2f
    test r12d, r12d             # the host's own: from the panel its tab comes forward
    jz 9f
2:  mov rdi, rbx
    call at_rec_tab
    test rax, rax
    js 9f
    mov rdi, rax
    call app_activate_tab
    mov [rip + at_last_active], rbx
    mov rdi, rbx
    call at_take
    call at_keys_in
    mov r13d, 1
    jmp 9f
5:  test r12d, r12d
    jz 9f
    mov rdi, [rip + at_host]
    test rdi, rdi
    jz 9f
    call at_save                   # the panel takes the view: the tab keeps its place
    mov qword ptr [rip + at_host], 0
9:  mov eax, r13d
    EPILOGUE

# FN agtab_new_made(AS*): agent_new made the conversation of a draft: the hosting tab's draft is it now
FN agtab_new_made
    PROLOGUE
    mov rbx, [rip + at_host]
    test rbx, rbx
    jz 9f
    cmp qword ptr [rbx + ATB_as], 0
    jne 9f
    mov rsi, rdi
    mov rdi, rbx
    call at_bind
9:  EPILOGUE

# new_rec() -> rax a free record (zeroed, used), 0 none
at_new_rec:
    PROLOGUE
    xor ebx, ebx
1:  cmp ebx, AGT_MAX
    jae 8f
    mov edi, ebx
    call at_rec_of
    cmp dword ptr [rax + ATB_used], 0
    je 2f
    inc ebx
    jmp 1b
2:  mov r12, rax
    mov rdi, rax
    xor esi, esi
    mov edx, ATB_SIZE
    call memset
    mov dword ptr [r12 + ATB_used], 1
    mov qword ptr [r12 + ATB_ltitle], -1
    mov rax, r12
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# add_tab(rec, place) -> rax its tab's index: after the active tab (after the pinned ones), or at place
#   (>= 0: the session's order)
at_add_tab:
    PROLOGUE
    mov rbx, rdi
    mov r15, rsi
    mov rdi, rbx
    call at_rec_slot
    mov r12d, eax
    lea rdi, [rip + g_tabs]
    mov esi, TAB_SIZE
    call vec_push               # zeroed: not pinned
    mov qword ptr [rax + TAB_kind], TAB_AGENT
    mov qword ptr [rax + TAB_doc], 0
    lea ecx, [r12 + 1]
    shl rcx, AGT_SHIFT
    mov [rax + TAB_flags], rcx
    mov r13, [rip + g_tabs + VEC_len]
    dec r13
    test r15, r15
    jns 1f
    mov r14, [rip + g_tab_cur]
    inc r14
    call tabs_pinned
    cmp r14, rax
    cmovb r14, rax
    mov rdi, r13
    mov rsi, r14
    call tab_move
    mov rax, r14
    EPILOGUE
1:  mov rax, r13
    EPILOGUE

# FN agtab_open(AS* or 0, kind) -> rax the tab's index, -1 none: a tab for that conversation (shown when it has
#   one already), or for a new draft of that kind; it is active and hosts the view, its box has the keys
FN agtab_open
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    test r12, r12
    jz 1f
    call at_find_as
    test rax, rax
    jz 1f
    mov rbx, rax
    mov rdi, rax
    call at_rec_tab
    test rax, rax
    js 1f
    jmp 3f
1:  call at_new_rec
    test rax, rax
    jz 8f
    mov rbx, rax
    mov [rbx + ATB_kind], r13d
    mov rdi, rbx
    mov rsi, r12
    call at_bind
    mov rdi, rbx
    mov rsi, -1
    call at_add_tab
3:  mov r14, rax
    mov rdi, rax
    call app_activate_tab
    mov [rip + at_last_active], rbx
    mov rdi, rbx
    call at_take
    call at_keys_in
    mov rax, r14
    EPILOGUE
8:  lea rdi, [rip + .Lt_full]
    call app_toast
    mov rax, -1
    EPILOGUE

# FN agtab_tab_closed(tab flags): its tab closes: the view goes back to the panel when it had it
FN agtab_tab_closed
    PROLOGUE
    call at_flags_rec
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp rbx, [rip + at_host]
    jne 1f
    call at_release
1:  cmp rbx, [rip + at_last_active]
    jne 2f
    mov qword ptr [rip + at_last_active], 0
2:  cmp rbx, [rip + at_pend_close]
    jne 3f
    mov qword ptr [rip + at_pend_close], 0
3:  mov rdi, [rbx + ATB_path]
    call mem_free
    mov rdi, rbx
    xor esi, esi
    mov edx, ATB_SIZE
    call memset
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# make_label(rec) -> rax its label: the title cut at AGT_CUT characters and "…", or the driver's name; made
#   again only when the title's pointer changed
at_make_label:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + ATB_as]
    xor r13d, r13d              # the title
    test r12, r12
    jz 1f
    mov r13, [r12 + AS_title]
1:  cmp r13, [rbx + ATB_ltitle]
    je 9f
    mov [rbx + ATB_ltitle], r13
    lea r14, [rbx + ATB_label]
    test r13, r13
    jz 5f
    cmp byte ptr [r13], 0
    je 5f
    xor ecx, ecx                # bytes
    xor edx, edx                # characters
2:  movzx eax, byte ptr [r13 + rcx]
    test eax, eax
    jz 4f
    and eax, 0xc0
    cmp eax, 0x80
    je 3f                       # a continuation byte
    cmp edx, AGT_CUT
    jae 4f
    inc edx
3:  inc rcx
    cmp rcx, 120
    jb 2b
4:  mov r15, rcx
    mov rdi, r14
    mov rsi, r13
    mov rdx, rcx
    call memcpy
    cmp byte ptr [r13 + r15], 0
    je 41f
    mov byte ptr [r14 + r15], 0xe2      # "…"
    mov byte ptr [r14 + r15 + 1], 0x80
    mov byte ptr [r14 + r15 + 2], 0xa6
    add r15, 3
41: mov byte ptr [r14 + r15], 0
    jmp 9f
5:  mov edi, [rbx + ATB_kind]   # no title: the driver's name
    call agent_drv_for_kind
    lea rsi, [rip + .Lt_untitled]
    test rax, rax
    jz 6f
    mov rsi, [rax + DRV_name]
6:  mov rdi, r14
    call cstr_copy
9:  lea rax, [rbx + ATB_label]
    EPILOGUE

# FN agtab_label(tab flags) -> rax the tab's label
FN agtab_label
    push rbx
    call at_flags_rec
    test rax, rax
    jz 1f
    mov rdi, rax
    call at_make_label
    pop rbx
    ret
1:  lea rax, [rip + .Lt_untitled]
    pop rbx
    ret

# waiting(AS*) -> eax 1 while the conversation waits for the user (a card, a held start)
at_waiting:
    xor eax, eax
    test rdi, rdi
    jz 1f
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 1f
    cmp dword ptr [rcx + AL_state], ALS_WAITING
    je 2f
    cmp dword ptr [rcx + AL_state], ALS_HELD
    jne 1f
2:  mov eax, 1
1:  ret

# state(rec) -> eax 0 none, 1 waits for the user, 2 a turn ended unseen
at_state:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + ATB_as]
    call at_waiting
    test eax, eax
    jnz 1f
    cmp dword ptr [rbx + ATB_unseen], 0
    je 1f
    mov eax, 2
1:  pop rbx
    ret

# FN agtab_dot_w(TAB*) -> eax the room its dot takes before the label, 0 none
FN agtab_dot_w
    xor eax, eax
    cmp qword ptr [rdi + TAB_kind], TAB_AGENT
    jne 1f
    push rbx
    mov rdi, [rdi + TAB_flags]
    call at_flags_rec
    test rax, rax
    jz 2f
    mov rdi, rax
    call at_state
    test eax, eax
    jz 2f
    mov eax, [rip + g_mt + 4*MI_6]
    add eax, [rip + g_mt + 4*MI_6]
2:  pop rbx
1:  ret

# FN agtab_tab_dot(TAB*, x, y, h) -> eax the room it took: a conversation tab's dot before its label
FN agtab_tab_dot
    PROLOGUE
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    xor r15d, r15d
    cmp qword ptr [rdi + TAB_kind], TAB_AGENT
    jne 9f
    mov rdi, [rdi + TAB_flags]
    call at_flags_rec
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    call at_state
    test eax, eax
    jz 9f
    COLOR r9d, T_WARNING
    cmp eax, 1
    je 1f
    mov edi, [rbx + ATB_kind]   # a turn ended unseen: the driver's colour
    call agent_drv_for_kind
    COLOR r9d, T_ACCENT
    test rax, rax
    jz 1f
    mov ecx, [rax + DRV_brand]
    test ecx, ecx
    jz 1f
    mov r9d, ecx
1:  M ecx, MI_6
    mov edi, r12d
    mov esi, r14d
    sub esi, ecx
    sar esi, 1
    add esi, r13d
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    call gfx_round_rect
    mov r15d, [rip + g_mt + 4*MI_6]
    add r15d, [rip + g_mt + 4*MI_6]
9:  mov eax, r15d
    EPILOGUE

# FN agtab_turn_end(AS*): a turn of that conversation ended: unseen unless its tab hosts the view, is the
#   active tab and the window has the focus
FN agtab_turn_end
    PROLOGUE
    call at_find_as
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp rbx, [rip + at_host]
    jne 1f
    call at_cur_rec
    cmp rax, rbx
    jne 1f
    cmp dword ptr [rip + g_win_focused], 0
    jne 9f
1:  mov dword ptr [rbx + ATB_unseen], 1
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN agtab_draw(tab index, x, y, w, h): the view when its tab hosts it (the text column at most 800 px wide,
#   centred), else a line that says why not. Locals: [rsp] x, +4 y, +8 w, +12 h
FN agtab_draw
    PROLOGUE 48
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    call tab_at
    mov rdi, [rax + TAB_flags]
    call at_flags_rec
    test rax, rax
    jz 99f
    mov rbx, rax
    call agtab_sync
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    COLOR r8d, T_PANEL
    call gfx_fill
    cmp rbx, [rip + at_host]
    jne .Lad_away
    # it hosts: what the view shows is the tab's (a draft hides the conversation)
    call at_draft_kind
    test rax, rax
    jnz 1f
    call agents_viewed
    test rax, rax
    jz .Lad_gone
    cmp rax, [rbx + ATB_as]
    je 3f
    mov rdi, rbx
    mov rsi, rax
    call at_bind
    jmp 3f
1:  mov r12d, eax
    cmp qword ptr [rbx + ATB_as], 0
    je 2f
    mov rdi, rbx
    xor esi, esi
    call at_bind
    mov rdi, [rbx + ATB_path]   # (a draft has no file)
    call mem_free
    mov qword ptr [rbx + ATB_path], 0
2:  mov [rbx + ATB_kind], r12d
3:  cmp dword ptr [rip + g_win_focused], 0
    je 4f
    mov dword ptr [rbx + ATB_unseen], 0
4:  test dword ptr [rip + g_pressed], (1 << BTN_LEFT) | (1 << BTN_RIGHT)
    jz 5f
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    je 5f
    cmp dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    je 5f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call ui_in
    test eax, eax
    jz 5f
    mov dword ptr [rip + g_focus], FOCUS_AGENTS     # a press in it: the view's keys (the box takes its own)
5:  mov edi, 800                # the column
    call sc
    mov ecx, [rsp + 8]
    mov edx, [rsp]
    cmp ecx, eax
    jle 6f
    sub ecx, eax
    shr ecx, 1
    add edx, ecx
    mov ecx, eax
6:  mov edi, edx
    mov esi, [rsp + 4]
    mov edx, ecx
    mov ecx, [rsp + 12]
    call agents_draw_tab
    jmp 99f
.Lad_gone:                      # the view shows nothing: its conversation left the list
    cmp qword ptr [rbx + ATB_as], 0     # (a tab the session file restored: shown once the list has it)
    jne 70f
    mov rdi, [rbx + ATB_path]
    test rdi, rdi
    jz 70f
    call agents_by_path
    test rax, rax
    jz 70f
    mov rdi, rbx
    call at_take
    jmp 99f
70: lea r12, [rip + .Lt_gone]
    call agents_loading
    test eax, eax
    jz 7f
    cmp qword ptr [rbx + ATB_as], 0
    jne 7f
    lea r12, [rip + .Lt_loading]
7:  mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    M r8d, MI_64
    COLOR eax, T_MUTED
    push rax
    push rax
    mov r9, r12
    call ui_text_center
    add rsp, 16
    M eax, MI_64                # Close, under it
    mov edi, [rsp + 8]
    sub edi, eax
    sar edi, 1
    add edi, [rsp]
    mov [rsp + 16], edi
    mov edi, ID_AGT_CLOSE
    mov esi, [rsp + 16]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_64]
    M ecx, MI_64
    M r8d, MI_28
    call ui_btn
    mov r13d, eax
    COLOR r9d, T_ACCENT
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 16]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_64]
    M ecx, MI_64
    M r8d, MI_28
    lea rax, [rip + .Lt_close]
    push r9
    push r9
    mov r9, rax
    call ui_text_center
    add rsp, 16
    test r13d, UB_CLICK
    jz 99f
    mov [rip + at_pend_close], rbx
    mov dword ptr [rip + g_dirty], 1
    jmp 99f
.Lad_away:                      # another holds the view: a press takes it back
    mov edi, ID_AGT_AREA
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call ui_btn
    mov r13d, eax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    M r8d, MI_64
    COLOR eax, T_MUTED
    push rax
    push rax
    lea r9, [rip + .Lt_away]
    call ui_text_center
    add rsp, 16
    test r13d, UB_PRESS
    jz 99f
    mov rdi, rbx
    call at_take
    call at_keys_in
99: EPILOGUE

# FN agtab_after(): after the frame: a tab's Close link closes it
FN agtab_after
    PROLOGUE
    mov rdi, [rip + at_pend_close]
    test rdi, rdi
    jz 9f
    mov qword ptr [rip + at_pend_close], 0
    call at_rec_tab
    test rax, rax
    js 9f
    mov rdi, rax
    call app_close_tab_now
9:  EPILOGUE

# ---- commands ----

# default_kind() -> eax the kind of the conversation the view shows, else the first driver that starts
#   conversations (AG_CLAUDE), 0 none
at_default_kind:
    push rbx
    call agents_viewed
    test rax, rax
    jz 1f
    mov ebx, [rax + AS_kind]
    mov edi, ebx
    call agent_drv_for_kind     # (a kind whose driver starts conversations)
    test rax, rax
    jz 1f
    test dword ptr [rax + DRV_caps], DRVC_NEW
    jz 1f
    mov eax, ebx
    pop rbx
    ret
1:  call agent_drv_default
    pop rbx
    ret

# set_location(0 panel, 1 tab): [agents] location follows the user's last choice
at_set_location:
    cmp [rip + cfg_agents_location], edi
    je 1f
    mov [rip + cfg_agents_location], edi
    mov dword ptr [rip + g_settings_changed], 1
1:  ret

# FN agtab_cmd_open_tab(): "Agents: Open in New Tab": the conversation the panel shows moves to a new tab (the
#   panel goes back to its list), else a new conversation in a new tab
FN agtab_cmd_open_tab
    PROLOGUE 16
    mov edi, 1
    call at_set_location
    cmp qword ptr [rip + at_host], 0
    jne 1f
    call agents_viewed
    test rax, rax
    jz 1f
    mov rbx, rax
    call at_find_as                # (it has a tab: that one)
    test rax, rax
    jnz 2f
    call at_new_rec
    test rax, rax
    jz 1f
    mov r12, rax
    mov rdi, r12
    mov rsi, rbx
    call at_bind
    lea rdi, [r12 + ATB_place]  # its place goes with it
    call agents_anchor_get
    mov dword ptr [r12 + ATB_anch], 1
    mov rdi, r12
    mov rsi, -1
    call at_add_tab
    mov r13, rax
    mov rdi, rax
    call app_activate_tab
    mov [rip + at_last_active], r12
    mov rdi, r12
    call at_take
    call at_keys_in
    EPILOGUE
2:  mov rdi, rbx
    xor esi, esi
    call agtab_open
    EPILOGUE
1:  call at_default_kind
    xor edi, edi
    mov esi, eax
    call agtab_open
    EPILOGUE

# FN agtab_cmd_open_panel(): "Agents: Open in Side Panel": the active conversation tab closes and the panel
#   shows its conversation
FN agtab_cmd_open_panel
    PROLOGUE
    xor edi, edi
    call at_set_location
    call at_cur_rec
    test rax, rax
    jz 5f
    mov rbx, rax
    mov r12, [rbx + ATB_as]
    mov r13d, [rbx + ATB_kind]
    mov rdi, rbx
    call at_rec_tab
    test rax, rax
    js 5f
    mov rdi, rax
    call app_close_tab_now      # (agtab_tab_closed: the view is the panel's again)
    call cmd_focus_agents
    test r12, r12
    jz 3f
    mov rdi, r12
    call agents_open_as
    EPILOGUE
3:  mov edi, r13d
    call agentext_new_kind
    EPILOGUE
5:  call cmd_focus_agents
    EPILOGUE

# latest_rec() -> rax the conversation tab activated last, 0 none
at_latest_rec:
    xor eax, eax
    xor edx, edx                # its order
    xor ecx, ecx
1:  cmp ecx, AGT_MAX
    jae 9f
    movsxd r8, ecx
    imul r8, r8, ATB_SIZE
    lea r9, [rip + at_recs]
    add r8, r9
    inc ecx
    cmp dword ptr [r8 + ATB_used], 0
    je 1b
    cmp [r8 + ATB_seq], edx
    jb 1b
    mov edx, [r8 + ATB_seq]
    mov rax, r8
    jmp 1b
9:  ret

# FN agtab_cmd_open(): "Agents: Open" (after the terminal's branch, claudeterm.s): with [agents] location =
#   tab the conversation tab used last (none: a new conversation in a tab), else the panel with the keys
FN agtab_cmd_open
    PROLOGUE
    cmp dword ptr [rip + cfg_agents_location], 0
    je 5f
    call at_latest_rec
    test rax, rax
    jz 2f
    mov rbx, rax
    mov rdi, rax
    call at_rec_tab
    test rax, rax
    js 2f
    mov rdi, rax
    call app_activate_tab
    call agtab_sync
    cmp rbx, [rip + at_host]
    je 1f
    mov rdi, rbx
    call at_take
1:  call at_keys_in
    EPILOGUE
2:  call at_default_kind
    xor edi, edi
    mov esi, eax
    call agtab_open
    EPILOGUE
5:  call cmd_focus_agents
    EPILOGUE

# FN agtab_cmd_new(): "Agents: New Conversation": in the conversation tab that hosts the view, else where
#   [agents] location says
FN agtab_cmd_new
    PROLOGUE
    call at_default_kind
    mov ebx, eax
    cmp qword ptr [rip + at_host], 0
    jne 2f
    cmp dword ptr [rip + cfg_agents_location], 0
    je 1f
    xor edi, edi
    mov esi, ebx
    call agtab_open
    EPILOGUE
1:  call cmd_focus_agents
    mov edi, ebx
    call agentext_new_kind
    EPILOGUE
2:  mov edi, ebx                # the hosting tab's: a draft now
    call agentext_new_kind
    mov r12, [rip + at_host]
    mov rdi, r12
    call at_save
    mov rdi, r12
    xor esi, esi
    call at_bind
    mov rdi, [r12 + ATB_path]
    call mem_free
    mov qword ptr [r12 + ATB_path], 0
    mov [r12 + ATB_kind], ebx
    EPILOGUE

# ---- the status bar item ----

# status_drv() -> rax the driver the item opens (one that starts conversations), 0 none
at_status_drv:
    sub rsp, 8
    call agent_drv_default
    test eax, eax
    jz 1f
    mov edi, eax
    call agent_drv_for_kind
1:  add rsp, 8
    ret

# any_waiting() -> eax 1 when a conversation of the window waits for the user (its live records: the
#   programs rhun runs)
at_any_waiting:
    PROLOGUE
    xor ebx, ebx
1:  mov rdi, rbx
    call agent_live_at
    test rax, rax
    jz 8f
    inc rbx
    cmp dword ptr [rax + AL_state], ALS_WAITING
    je 2f
    cmp dword ptr [rax + AL_state], ALS_HELD
    jne 1b
2:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agents_status_item(right, y, h, min x) -> eax the right edge left of it: the glyph and the driver's name, a
#   dot while a conversation waits for the user; a click is Agents: Open. Not drawn when it would start left of
#   min x (a narrow bar keeps its room for the cursor's label). Locals: [rsp] x, +4 y, +8 h, +12 w, +16 the text's
#   width, +20 UB bits, +24 the dot, +28 min x
FN agents_status_item
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 28], ecx
    call at_status_drv
    test rax, rax
    jz .Lsi_none
    mov rbx, rax
    mov r12, [rbx + DRV_name]
    mov rdi, r12
    call strlen
    mov r13, rax
    lea rdi, [rip + g_face_small]
    mov rsi, r12
    mov rdx, r13
    call text_width
    mov [rsp + 16], eax
    call at_any_waiting
    mov [rsp + 24], eax
    mov eax, [rsp + 16]
    add eax, [rip + g_mt + 4*MI_16]     # its margins
    add eax, [rip + g_mt + 4*MI_14]     # the glyph and its gap
    cmp dword ptr [rsp + 24], 0
    je 1f
    add eax, [rip + g_mt + 4*MI_10]     # the dot and its gap
1:  mov [rsp + 12], eax
    mov ecx, [rsp]
    sub ecx, eax
    cmp ecx, [rsp + 28]
    jl .Lsi_none
    mov [rsp], ecx              # x
    mov edi, ID_AGT_STATUS
    mov esi, ecx
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_3]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 8]
    sub r8d, [rip + g_mt + 4*MI_6]
    call ui_btn
    mov [rsp + 20], eax
    test eax, UB_HOVER
    jz 2f
    mov dword ptr [rip + g_cursor], CUR_POINTER
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rip + g_mt + 4*MI_3]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_6]
    COLOR r8d, T_HOVER
    call gfx_fill
2:  mov r14d, [rsp]
    add r14d, [rip + g_mt + 4*MI_8]
    COLOR r8d, T_FG             # the glyph in the driver's colour
    mov eax, [rbx + DRV_brand]
    test eax, eax
    jz 21f
    mov r8d, eax
21: mov edi, [rbx + DRV_glyph]
    test edi, edi
    jnz 22f
    mov edi, IC_SPARK
22: M ecx, MI_10
    mov edx, [rsp + 8]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    mov esi, r14d
    call icon_draw
    add r14d, [rip + g_mt + 4*MI_14]
    lea rdi, [rip + g_face_small]
    mov esi, r14d
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8, r12
    mov r9, r13
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    cmp dword ptr [rsp + 24], 0
    je 3f
    add r14d, [rsp + 16]
    add r14d, [rip + g_mt + 4*MI_4]
    M ecx, MI_6
    mov edi, r14d
    mov esi, [rsp + 8]
    sub esi, ecx
    sar esi, 1
    add esi, [rsp + 4]
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_WARNING
    call gfx_round_rect
3:  lea rdi, [rip + at_tipbuf]     # its tip: "Open NAME"
    lea rsi, [rip + .Lt_open]
    call cstr_copy
    lea rdi, [rip + at_tipbuf + 5]
    mov rsi, r12
    mov edx, 150
    mov rcx, r13
    cmp rcx, rdx
    cmova rcx, rdx
    mov rdx, rcx
    call memcpy
    lea rax, [rip + at_tipbuf + 5]
    add rax, r13
    cmp r13, 150
    jbe 31f
    lea rax, [rip + at_tipbuf + 155]
31: mov byte ptr [rax], 0
    mov edi, ID_AGT_STATUS
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rsp + 8]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 20]
    lea r9, [rip + at_tipbuf]
    call tip_note_text
    test dword ptr [rsp + 20], UB_CLICK
    jz 4f
    call cmd_agents_open
    mov dword ptr [rip + g_dirty], 1
4:  mov eax, [rsp]
    EPILOGUE
.Lsi_none:
    mov eax, [rsp]
    EPILOGUE

# ---- links: rhun://NAME/open?session=ID&prompt=TEXT (NAME an agent's word: config's names) ----

# FN agtab_link(cstr) -> eax 1 when it was an agent's open link (handled): the conversation ID (else a new one)
#   opens where [agents] location says, the prompt fills its box and is not sent (its @terminal: names are
#   blocked: agterm_block); a conversation shown already keeps its box. An ID is looked up once discovery has
#   listed the project's conversations (a window the link just started)
FN agtab_link
    PROLOGUE
    mov rbx, rdi
    xor r15d, r15d
    xor ecx, ecx                # "rhun://", the scheme in any case
1:  movzx eax, byte ptr [rbx + rcx]
    test eax, eax
    jz 9f
    cmp ecx, 4
    jae 2f
    or eax, 0x20
2:  lea rdx, [rip + .Lrhun]
    cmp al, [rdx + rcx]
    jne 9f
    inc ecx
    cmp ecx, 7
    jb 1b
    lea r12, [rbx + 7]          # NAME
    xor ecx, ecx
3:  movzx eax, byte ptr [r12 + rcx]
    test eax, eax
    jz 9f
    cmp eax, '/'
    je 4f
    inc rcx
    jmp 3b
4:  test rcx, rcx
    jz 9f
    mov r13, rcx
    mov rdi, r12
    mov rsi, rcx
    call agent_kind_named
    test eax, eax
    jz 9f                       # not an agent's: the other routes
    mov r14d, eax
    lea r12, [r12 + r13 + 1]    # "open", then the end, "?" or "/?"
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rip + .Linstall]
    mov ecx, 14
    call str_starts
    test eax, eax
    jnz .Lal_install
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rip + .Lopen]
    mov ecx, 4
    call str_starts
    test eax, eax
    jz 9f
    add r12, 4
    cmp byte ptr [r12], '/'
    jne 5f
    inc r12
5:  movzx eax, byte ptr [r12]
    test eax, eax
    jz 6f
    cmp eax, '?'
    jne 9f
    inc r12
6:  mov [rip + at_lk_kind], r14d
    mov byte ptr [rip + at_lk_id], 0
    lea rdi, [rip + at_lk_prompt]
    call sb_clear
    # the query's pairs
7:  cmp byte ptr [r12], 0
    je 8f
    mov rdi, r12
    lea rsi, [rip + .Lk_session]
    call at_pair
    test rax, rax
    jz 71f
    mov r12, rax
    lea rdi, [rip + at_sb]      # (decoded, then checked and kept)
    call sb_clear
    mov rdi, r12
    lea rsi, [rip + at_sb]
    call at_decode
    mov r12, rax
    call at_take_id
    jmp 7b
71: mov rdi, r12
    lea rsi, [rip + .Lk_prompt]
    call at_pair
    test rax, rax
    jz 72f
    mov r12, rax
    lea rdi, [rip + at_lk_prompt]
    call sb_clear
    mov rdi, r12
    lea rsi, [rip + at_lk_prompt]
    call at_decode
    mov r12, rax
    mov dword ptr [rip + at_lk_has_prompt], 1
    jmp 7b
72: movzx eax, byte ptr [r12]   # another pair: passed over
    test eax, eax
    jz 8f
    inc r12
    cmp eax, '&'
    jne 72b
    jmp 7b
8:  cmp dword ptr [rip + at_lk_has_prompt], 0
    jne 81f
    lea rdi, [rip + at_lk_prompt]
    call sb_clear
81: mov dword ptr [rip + at_lk_has_prompt], 0
    mov dword ptr [rip + at_lk_pending], 1
    call at_link_apply
    mov r15d, 1
9:  mov eax, r15d
    EPILOGUE
# rhun://NAME/install-plugin?plugin=P&marketplace=M (rows 4.19, U: the extension's URI handler @3525150): no
#   fragment, the plugin named (the marketplace's default, when the link names none, is the driver's); the panel
#   shows and the driver opens Manage Plugins on it (DRV_action ACT_PLUGIN_LINK: its checks, the trust question)
.Lal_install:
    add r12, 14
    cmp byte ptr [r12], '/'
    jne 1f
    inc r12
1:  movzx eax, byte ptr [r12]
    test eax, eax
    jz 2f
    cmp eax, '?'
    jne 9b
    inc r12
2:  mov r15d, 1                 # (ours from here: handled, a toast when refused)
    xor ecx, ecx                # a fragment: nothing is installed
3:  movzx eax, byte ptr [r12 + rcx]
    test eax, eax
    jz 4f
    inc rcx
    cmp eax, '#'
    jne 3b
    lea rdi, [rip + .Lpl_hash]
    call app_toast
    jmp 9b
4:  lea rdi, [rip + at_pl]
    call sb_clear
    lea rdi, [rip + at_pm]
    call sb_clear
    mov dword ptr [rip + at_pm_has], 0
5:  cmp byte ptr [r12], 0
    je 7f
    mov rdi, r12
    lea rsi, [rip + .Lk_plugin]
    call at_pair
    test rax, rax
    jz 51f
    mov r12, rax
    lea rdi, [rip + at_pl]
    call sb_clear
    mov rdi, r12
    lea rsi, [rip + at_pl]
    call at_decode
    mov r12, rax
    jmp 5b
51: mov rdi, r12
    lea rsi, [rip + .Lk_market]
    call at_pair
    test rax, rax
    jz 52f
    mov r12, rax
    lea rdi, [rip + at_pm]
    call sb_clear
    mov rdi, r12
    lea rsi, [rip + at_pm]
    call at_decode
    mov r12, rax
    mov dword ptr [rip + at_pm_has], 1
    jmp 5b
52: movzx eax, byte ptr [r12]   # another pair: passed over
    test eax, eax
    jz 7f
    inc r12
    cmp eax, '&'
    jne 52b
    jmp 5b
7:  cmp qword ptr [rip + at_pl + SB_len], 0
    jne 71f
    lea rdi, [rip + .Lpl_need]
    call app_toast
    jmp 9b
71: lea rdi, [rip + at_pl]      # "PLUGIN\0SOURCE\0", or "PLUGIN\0" when the link names no marketplace (a NUL
    xor esi, esi                #   inside either: the driver's checks refuse it)
    call sb_push_byte
    cmp dword ptr [rip + at_pm_has], 0
    je 72f
    lea rdi, [rip + at_pl]
    mov rsi, [rip + at_pm + SB_ptr]
    mov rdx, [rip + at_pm + SB_len]
    call sb_push
    lea rdi, [rip + at_pl]
    xor esi, esi
    call sb_push_byte
72:    mov edi, r14d
    call agent_drv_for_kind
    test rax, rax
    jz 9b
    mov r13, rax
    call cmd_focus_agents
    xor edi, edi
    mov esi, ACT_PLUGIN_LINK
    mov rdx, [rip + at_pl + SB_ptr]
    mov rcx, [rip + at_pl + SB_len]
    call [r13 + DRV_action]
    mov dword ptr [rip + g_dirty], 1
    jmp 9b

# at_pair(ptr, key cstr) -> rax after "KEY=" when the pair at ptr has that key, else 0
at_pair:
    xor ecx, ecx
1:  movzx eax, byte ptr [rsi + rcx]
    test eax, eax
    jz 2f
    cmp al, [rdi + rcx]
    jne 8f
    inc rcx
    jmp 1b
2:  cmp byte ptr [rdi + rcx], '='
    jne 8f
    lea rax, [rdi + rcx + 1]
    ret
8:  xor eax, eax
    ret

# at_decode(ptr, sb) -> rax after the value (past its "&"): the value percent-decoded ("+" a space) into sb
at_decode:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
1:  movzx eax, byte ptr [rbx]
    test eax, eax
    jz 9f
    inc rbx
    cmp eax, '&'
    je 9f
    cmp eax, '+'
    jne 2f
    mov eax, ' '
    jmp 5f
2:  cmp eax, '%'
    jne 5f
    movzx edi, byte ptr [rbx]
    call at_hex
    test eax, eax
    js 4f
    mov r13d, eax
    movzx edi, byte ptr [rbx + 1]
    call at_hex
    test eax, eax
    js 4f
    shl r13d, 4
    or eax, r13d
    add rbx, 2
    jmp 5f
4:  mov eax, '%'
5:  mov rdi, r12
    mov esi, eax
    call sb_push_byte
    jmp 1b
9:  mov rax, rbx
    EPILOGUE

# at_hex(char) -> eax its value, -1 not a hex digit
at_hex:
    mov eax, edi
    sub eax, '0'
    cmp eax, 10
    jb 1f
    mov eax, edi
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 6
    jae 8f
    add eax, 10
1:  ret
8:  mov eax, -1
    ret

# at_take_id(): the decoded value in at_sb is the id when it is 1 to 64 letters, digits, "-" or "_"
at_take_id:
    mov rsi, [rip + at_sb + SB_ptr]
    mov rcx, [rip + at_sb + SB_len]
    test rcx, rcx
    jz 8f
    cmp rcx, 64
    ja 8f
    xor edx, edx
1:  cmp rdx, rcx
    jae 3f
    movzx eax, byte ptr [rsi + rdx]
    inc rdx
    cmp eax, '-'
    je 1b
    cmp eax, '_'
    je 1b
    lea r8d, [rax - '0']
    cmp r8d, 10
    jb 1b
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 26
    jb 1b
    jmp 8f
3:  lea rdi, [rip + at_lk_id]
    xor edx, edx
4:  mov al, [rsi + rdx]
    mov [rdi + rdx], al
    inc rdx
    cmp rdx, rcx
    jb 4b
    mov byte ptr [rdi + rdx], 0
    ret
8:  mov byte ptr [rip + at_lk_id], 0
    ret

# at_by_id(id cstr) -> rax the listed conversation whose file's name, less its extension, is the id; 0 none
at_by_id:
    PROLOGUE
    mov r12, rdi
    call strlen
    mov r13, rax
    call agents_rows_vec
    mov r14, rax
    mov r15, rdx
    xor ebx, ebx
1:  cmp rbx, r15
    jae 8f
    mov rax, [r14 + rbx*8]
    inc rbx
    mov rdi, [rax + AS_path]
    test rdi, rdi
    jz 1b
    push rax
    push rax
    call at_base
    mov rdi, rax
    mov rsi, rdx
    pop rax
    pop rax
    cmp rsi, r13
    jne 1b
    push rax
    push rax
    mov rdx, r12
    mov rcx, r13
    call str_starts
    mov ecx, eax
    pop rax
    pop rax
    test ecx, ecx
    jz 1b
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# at_base(path cstr) -> rax its file's name, rdx its length less the extension
at_base:
    mov rax, rdi
    mov rcx, rdi
1:  movzx edx, byte ptr [rcx]
    test edx, edx
    jz 2f
    inc rcx
    cmp edx, '/'
    jne 1b
    mov rax, rcx
    jmp 1b
2:  mov rdx, rcx                # the end; back to the last "."
3:  cmp rdx, rax
    jbe 4f
    dec rdx
    cmp byte ptr [rdx], '.'
    jne 3b
    sub rdx, rax
    ret
4:  sub rcx, rax
    mov rdx, rcx
    ret

# at_link_apply(): a link waiting: applied once the list is there when it names a conversation
at_link_apply:
    PROLOGUE
    cmp dword ptr [rip + at_lk_pending], 0
    je 9f
    cmp byte ptr [rip + at_lk_id], 0
    je 1f
    call agents_loading
    test eax, eax
    jnz 9f
1:  mov dword ptr [rip + at_lk_pending], 0
    xor ebx, ebx
    cmp byte ptr [rip + at_lk_id], 0
    je 2f
    lea rdi, [rip + at_lk_id]
    call at_by_id
    mov rbx, rax
2:  test rbx, rbx
    jz 4f
    call agents_viewed          # shown already: it keeps its box
    cmp rax, rbx
    jne 3f
    mov rdi, rbx
    call at_find_as
    test rax, rax
    jz 21f
    mov rdi, rax
    call at_rec_tab
    test rax, rax
    js 21f
    mov rdi, rax
    call app_activate_tab
    call agtab_sync
    jmp 22f
21: call cmd_focus_agents
22: lea rdi, [rip + .Lt_shown]
    call app_toast
    jmp 9f
3:  cmp dword ptr [rip + cfg_agents_location], 0
    je 31f
    mov rdi, rbx
    mov esi, [rbx + AS_kind]
    call agtab_open
    jmp 6f
31: call at_release             # (the panel's: a tab's view comes back to it)
    call cmd_focus_agents
    mov rdi, rbx
    call agents_open_as
    jmp 6f
4:  cmp dword ptr [rip + cfg_agents_location], 0
    je 41f
    xor edi, edi
    mov esi, [rip + at_lk_kind]
    call agtab_open
    jmp 6f
41: call at_release
    call cmd_focus_agents
    mov edi, [rip + at_lk_kind]
    call agentext_new_kind
6:  mov rdx, [rip + at_lk_prompt + SB_len]  # the prompt in its box, not sent
    test rdx, rdx
    jz 7f
    call agentext_box
    mov rdi, rax
    mov rsi, [rip + at_lk_prompt + SB_ptr]
    mov rdx, [rip + at_lk_prompt + SB_len]
    call tf_set
    mov rdi, [rip + at_lk_prompt + SB_ptr]
    mov rsi, [rip + at_lk_prompt + SB_len]
    call agterm_block
    call agentext_box_changed
7:  call at_keys_in
9:  EPILOGUE

# FN agtab_cmd_open_window(): "Agents: Open in New Window": another rhun on the project, given the link to the
#   conversation the view shows (none: a new conversation)
FN agtab_cmd_open_window
    PROLOGUE
    mov r12, [rip + g_project]
    test r12, r12
    jz 8f
    call agents_viewed
    mov rbx, rax
    call at_default_kind
    test rbx, rbx
    jz 1f
    mov eax, [rbx + AS_kind]
1:  mov edi, eax
    call agent_kind_name
    mov r13, rax
    lea rdi, [rip + at_sb]
    call sb_clear
    lea rdi, [rip + at_sb]
    lea rsi, [rip + .Lrhun]
    call sb_push_cstr
    lea rdi, [rip + at_sb]
    mov rsi, r13
    call sb_push_cstr
    lea rdi, [rip + at_sb]
    lea rsi, [rip + .Lslash_open]
    call sb_push_cstr
    test rbx, rbx
    jz 2f
    mov rdi, [rbx + AS_path]
    test rdi, rdi
    jz 2f
    call at_base
    mov r14, rax
    mov r15, rdx
    lea rdi, [rip + at_sb]
    lea rsi, [rip + .Lq_session]
    call sb_push_cstr
    lea rdi, [rip + at_sb]
    mov rsi, r14
    mov rdx, r15
    call sb_push
2:  lea rdi, [rip + at_sb]
    xor esi, esi
    call sb_push_byte
    mov rdi, r12
    mov rsi, [rip + at_sb + SB_ptr]
    call app_new_window_link
    EPILOGUE
8:  lea rdi, [rip + .Lt_noproject]
    call app_toast
    EPILOGUE

# ---- the session file and Reopen Closed Tab: a tab as "KIND<TAB>FILE" ----

# FN agtab_line(TAB*) -> rax "KIND<TAB>FILE" (owned) for a conversation tab whose conversation has a file, else 0
FN agtab_line
    PROLOGUE
    xor eax, eax
    cmp qword ptr [rdi + TAB_kind], TAB_AGENT
    jne 9f
    mov rdi, [rdi + TAB_flags]
    call at_flags_rec
    test rax, rax
    jz 9f
    mov rbx, rax
    xor eax, eax
    cmp qword ptr [rbx + ATB_path], 0
    je 9f
    lea rdi, [rip + at_sb]
    call sb_clear
    mov edi, [rbx + ATB_kind]
    call agent_kind_name
    lea rdi, [rip + at_sb]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + at_sb]
    mov esi, 9
    call sb_push_byte
    lea rdi, [rip + at_sb]
    mov rsi, [rbx + ATB_path]
    call sb_push_cstr
    mov rdi, [rip + at_sb + SB_ptr]
    mov rsi, [rip + at_sb + SB_len]
    call mem_dup
9:  EPILOGUE

# parse(cstr) -> eax the kind (0: not a line of this kind), rdx the file (in the string), ecx 1 when "<TAB>pin"
#   ends it (cut off: the string is changed)
at_parse:
    PROLOGUE
    mov rbx, rdi
    xor r13d, r13d
    xor ecx, ecx
1:  movzx eax, byte ptr [rbx + rcx]
    test eax, eax
    jz 8f
    cmp eax, 9
    je 2f
    inc rcx
    jmp 1b
2:  mov r12, rcx
    mov rdi, rbx
    mov rsi, rcx
    call agent_kind_named
    test eax, eax
    jz 8f
    mov r14d, eax
    lea r15, [rbx + r12 + 1]    # the file
    cmp byte ptr [r15], 0
    je 8f
    mov rcx, r15
3:  movzx eax, byte ptr [rcx]
    test eax, eax
    jz 5f
    cmp eax, 9
    je 4f
    inc rcx
    jmp 3b
4:  mov byte ptr [rcx], 0
    cmp byte ptr [rcx + 1], 'p'
    jne 5f
    mov r13d, 1
5:  mov eax, r14d
    mov rdx, r15
    mov ecx, r13d
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    EPILOGUE

# from(kind, file cstr, place) -> rax its tab's index, -1 none: a tab for the conversation of that file (found
#   once the list has it; nothing starts)
at_from:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    call at_new_rec
    test rax, rax
    jz 8f
    mov rbx, rax
    mov [rbx + ATB_kind], r12d
    mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call mem_dup
    mov [rbx + ATB_path], rax
    mov rdi, r13                # the list has it already
    call agents_by_path
    mov [rbx + ATB_as], rax
    mov rdi, rbx
    mov rsi, r14
    call at_add_tab
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# FN agtab_restore_line(cstr, active): session_restore's: a conversation tab of the last session
FN agtab_restore_line
    PROLOGUE
    mov r12d, esi
    call at_parse
    test eax, eax
    jz 9f
    mov r13d, ecx
    mov edi, eax
    mov rsi, rdx
    xor edx, edx
    call at_from
    test rax, rax
    js 9f
    mov rbx, rax
    test r12d, r12d
    jz 1f
    mov rdi, rax
    call tab_at
    mov rdi, [rax + TAB_flags]
    call at_flags_rec
    mov [rip + at_restore_active], rax
1:  test r13d, r13d
    jz 9f
    mov rdi, rbx
    mov esi, 1
    call app_pin_tab
9:  EPILOGUE

# FN agtab_restored(active DOC* or 0): session_restore's end: no file was active: the conversation tab that was
FN agtab_restored
    PROLOGUE
    mov rbx, [rip + at_restore_active]
    mov qword ptr [rip + at_restore_active], 0
    test rdi, rdi
    jnz 9f
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call at_rec_tab
    test rax, rax
    js 9f
    mov rdi, rax
    call app_activate_tab
9:  EPILOGUE

# FN agtab_find_line(cstr) -> rax the index of the tab of that line's conversation, -1 none (the line unchanged)
FN agtab_find_line
    PROLOGUE
    mov r12, rdi
1:  movzx eax, byte ptr [r12]   # the file, after the kind
    inc r12
    test eax, eax
    jz 8f
    cmp eax, 9
    jne 1b
    xor ebx, ebx
2:  cmp ebx, AGT_MAX
    jae 8f
    mov edi, ebx
    inc ebx
    call at_rec_of
    cmp dword ptr [rax + ATB_used], 0
    je 2b
    mov r13, rax
    mov rdi, [rax + ATB_path]
    test rdi, rdi
    jz 2b
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jz 2b
    mov rdi, r13
    call at_rec_tab
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# FN agtab_reopen_line(cstr) -> rax its tab's index (active, after the active tab), -1 none: Reopen Closed Tab's
FN agtab_reopen_line
    PROLOGUE
    call at_parse
    test eax, eax
    jz 8f
    mov edi, eax
    mov rsi, rdx
    mov rdx, -1
    call at_from
    test rax, rax
    js 8f
    mov rbx, rax
    mov rdi, rax
    call app_activate_tab
    mov rax, rbx
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# ---- headless ----

# FN agtab_c_print(out, rest, len): print-agent-tabs: a line per conversation tab, in the strip's order:
#   "tab N label=LABEL host=0|1 active=0|1 dot=none|wait|unseen sid=FILE|-" (spaces in the label as _), then
#   "status=NAME tip=TIP dot=0|1" or "status=none", then "location=panel|tab hosting=0|1"
FN agtab_c_print
    PROLOGUE
    mov r15, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 5f
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_AGENT
    jne 4f
    mov rdi, [rax + TAB_flags]
    call at_flags_rec
    test rax, rax
    jz 4f
    mov r12, rax
    mov rdi, r15
    lea rsi, [rip + .Ld_tab]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, rbx
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_label]
    call sb_push_cstr
    mov rdi, r12
    call at_make_label
    mov r13, rax
2:  movzx esi, byte ptr [r13]
    test esi, esi
    jz 3f
    cmp esi, ' '
    jne 21f
    mov esi, '_'
21: mov rdi, r15
    call sb_push_byte
    inc r13
    jmp 2b
3:  mov rdi, r15
    lea rsi, [rip + .Ld_host]
    call sb_push_cstr
    xor esi, esi
    cmp r12, [rip + at_host]
    sete sil
    mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_active]
    call sb_push_cstr
    xor esi, esi
    cmp rbx, [rip + g_tab_cur]
    sete sil
    mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_dot]
    call sb_push_cstr
    mov rdi, r12
    call at_state
    lea rcx, [rip + dot_names]
    mov rsi, [rcx + rax*8]
    mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_file]
    call sb_push_cstr
    lea rsi, [rip + .Ldash]
    mov rax, [r12 + ATB_path]
    test rax, rax
    jz 31f
    mov rsi, rax                # its name, without the folder
32: movzx ecx, byte ptr [rax]
    inc rax
    test ecx, ecx
    jz 31f
    cmp ecx, '/'
    jne 32b
    mov rsi, rax
    jmp 32b
31: mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
4:  inc rbx
    jmp 1b
5:  call at_status_drv
    test rax, rax
    jnz 6f
    mov rdi, r15
    lea rsi, [rip + .Ld_nostatus]
    call sb_push_cstr
    jmp 7f
6:  mov rbx, rax
    mov rdi, r15
    lea rsi, [rip + .Ld_status]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + DRV_name]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_tip]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + DRV_name]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_sdot]
    call sb_push_cstr
    call at_any_waiting
    mov rdi, r15
    mov esi, eax
    call sb_push_u64
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
7:  mov rdi, r15
    lea rsi, [rip + .Ld_loc]
    call sb_push_cstr
    lea rsi, [rip + .Lw_panel]
    cmp dword ptr [rip + cfg_agents_location], 0
    je 71f
    lea rsi, [rip + .Lw_tab]
71: mov rdi, r15
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_hosting]
    call sb_push_cstr
    call agtab_hosting
    mov rdi, r15
    mov esi, eax
    call sb_push_u64
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

.section .rodata
.globl agtab_n_print, agtab_loc_opts
agtab_n_print: .asciz "print-agent-tabs"
agtab_loc_opts: .asciz "panel", "Side panel", "tab", "Editor tab", ""
.Lt_full: .asciz "Close a conversation tab first."
.Lt_shown: .asciz "Session is already open. Your prompt was not applied — enter it manually."
.Lt_noproject: .asciz "Open a folder first."
.Lrhun: .asciz "rhun://"
.Lopen: .asciz "open"
.Linstall: .asciz "install-plugin"
.Lk_plugin: .asciz "plugin"
.Lk_market: .asciz "marketplace"
.Lpl_hash: .asciz "Invalid plugin installation URL. The link contains a '#', so nothing was installed."
.Lpl_need: .asciz "Invalid plugin installation URL. The plugin parameter is required."
.Lslash_open: .asciz "/open"
.Lq_session: .asciz "?session="
.Lk_session: .asciz "session"
.Lk_prompt: .asciz "prompt"
.Lt_untitled: .asciz "Conversation"
.Lt_gone: .asciz "This conversation is no longer in the list."
.Lt_loading: .asciz "Loading..."
.Lt_away: .asciz "This conversation is shown when its tab has the view. Click to show it here."
.Lt_close: .asciz "Close"
.Lt_open: .asciz "Open "
.Ld_tab: .asciz "tab "
.Ld_label: .asciz " label="
.Ld_host: .asciz " host="
.Ld_active: .asciz " active="
.Ld_dot: .asciz " dot="
.Ld_file: .asciz " file="
.Ldash: .asciz "-"
.Ld_nostatus: .asciz "status=none\n"
.Ld_status: .asciz "status="
.Ld_tip: .asciz " tip=Open_"
.Ld_sdot: .asciz " dot="
.Ld_loc: .asciz "location="
.Lw_panel: .asciz "panel"
.Lw_tab: .asciz "tab"
.Ld_hosting: .asciz " hosting="
.Ld_none: .asciz "none"
.Ld_wait: .asciz "wait"
.Ld_unseen: .asciz "unseen"
.p2align 3
dot_names: .quad .Ld_none, .Ld_wait, .Ld_unseen
