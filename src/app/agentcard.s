# Rich cards of driven sessions (CD, rhun.inc): a driver's request as a card the panel draws in its own
# faces and metrics, above the prompt box, and that the keyboard can answer. The simple card (AXK,
# agentext.s) stays for extension sessions and rhun's own cards; the bottom area (agentext.s) and the
# panel's keys (agents.s) ask here first.
#
# A card is made by its driver (agentcard_new, _text, _btn, _extra, _dest) and kept by its request
# (AQ_card: freeing the request frees the card); it shows while its request is the oldest one waiting
# (ev_card, agent_drv.s). The driver answers it (DRV_reply) from what the card holds: the action chosen
# (CD_chosen, a CBA_*), the place picked (CD_dest), the edited command (CD_edit), the reject field's text
# (CD_field).
#
# Kinds. A card's kind (CD_kind) is a row of `kinds`: measure (CD*, w) -> eax its height, draw (AS*, CD*,
# x, y, w, h), key (AS*, CD*, keysym, cp, mods) -> eax taken, dump (sb, CD*) its kind's own lines. The
# permission card, the plan card and the dialog card are button cards (bc_*: a header, the details,
# buttons, the lines under the rule button, the reject field, "Esc to cancel"); the question card has entries
# of its own (qc_*, at the end). agentcard_answer is the one way an answer leaves a card.
#
# The button card:
#   the header (CD_title, wrapped) with a fold button (folded: the header's first line only); the hint
#   (CD_hint, muted); the detail (CD_detail); the editable command (CDF_EDIT: CD_edit, a text area); the
#   description (CD_desc, a muted line per LF-separated paragraph); "A hook says:" and the hook's words
#   (CD_note); "Details" and the input as indented JSON (CD_json; CDF_JSON open); the buttons, numbered
#   (not with CDF_DEFNO), their labels wrapping, a CDBF_DEST button's label ending with the place
#   (CD_dests[CD_dest], drawn as a link that cycles it); under the rule button its lines (CD_extra); the
#   reject field (CD_field, placeholder CD_ph); "Esc to cancel". Taller than its room it scrolls, keeping
#   the focused control in view.
#   Keys (only while it has the keyboard: the focus in the panel, the panel shown, its conversation open):
#   1..N pick a button, N+1 focuses the field (not with CDF_DEFNO: focus starts on the last button then);
#   Enter or Space activates the focused button; Up and Down move between the command, the buttons and
#   the field; Left and Right on a CDBF_DEST button cycle the place; Escape is the last button's action
#   (the driver's No); in the field Enter rejects with its text (Shift+Enter a new line), Escape too. Keys
#   and clicks do nothing for g_card_lock_ms after it shows (drawn dimmed); the fold button works.
#
# Focus rule (agentcard_shown, from ev_card): a new card takes the keyboard (FOCUS_AGENTS) only when the
# focus is in the panel or its box, the panel is shown, the card's conversation is the open one, and the
# box has not had a key for g_card_keyed_ms; otherwise it shows unfocused. Keys typed in the editor, the
# terminal or the box never reach a card. After an answer from the card the box has the keys again.
#
#   agentcard_new(kind) -> rax CD*; agentcard_text(CD*, CDT_*, ptr, len); agentcard_btn(CD*, label cstr,
#     act, flags); agentcard_extra(CD*, line cstr); agentcard_dest(CD*, id, label, tip: static cstrs);
#     agentcard_free(CD*)
#   agentcard_of(AS*) -> rax CD* or 0         the session's card on show
#   agentcard_shown(AS*, CD*)                 ev_card's part: its lock starts, its focus, the focus rule
#   agentcard_h(AS*, w) -> eax                its height (0 without one)
#   agentcard_draw(AS*, x, y, w, h)
#   agentcard_key(AS*, keysym, cp, mods) -> eax 1 taken
#   agentcard_answer(AS*, act) -> eax 1 sent to the driver    a button's action, as a click
#   agentcard_pick(AS*, n) -> eax 1           button n (from 0) once its lock is over (headless)
#   agentcard_set_text(AS*, which 0 field | 1 edit, ptr, len) -> eax 1   (headless)
#   agentcard_toggle(AS*, what 0 fold | 1 details | 2 the place) -> eax 1 (headless, as a click)
#   agentcard_live(CD*) -> eax 1 when its lock is over
#   agentcard_timeout() -> eax ms or -1       the shown card's lock: one wake-up when it ends
#   agentcard_waiting(AS*) -> rax cstr or 0   "Waiting for permission…" while a card waits and the box has
#                                             text (drawn under the card)
#   agentcard_input_line(sb, AS*) -> eax 1    print-agent-input's "card=TITLE DETAIL options=A|B|C"
#   agentcard_dump(sb, AS*)                   print-agent-card
#   agentcard_fit_dump(sb)                    print-agent-card-fit: its layout at every size and width
#   g_card_lock_ms, g_card_keyed_ms           agent-timing card=, keyed=
.include "rhun.inc"

.equ CID_BTN, 0                 # ID_AGCARD + : button i (0..15)
.equ CID_DEST, 16               #   the place's link, a line each (16..23)
.equ CID_FOLD, 24
.equ CID_DETAILS, 25
.equ CID_EDIT, 26
.equ CID_FIELD, 27
.equ BTN_MAX, 16
.equ LBUF_ONE, 512              # a button's label with its place, at most
.equ LI_MAX, 200                # layout items
.equ LK_TEXT, 1                 # a line of text (LI_idx: its style)
.equ LK_FOLD, 2
.equ LK_EDIT, 3
.equ LK_BTN, 4                  # a button (LI_idx: its index)
.equ LK_BLINE, 5                # a line of a button's label (LI_idx: the button)
.equ LK_FIELD, 6
.equ LK_DETAILS, 7              # the "Details" line
.equ TS_TITLE, 0                # text styles (style_tbl)
.equ TS_BODY, 1
.equ TS_MUTED, 2
.equ TS_SMALL, 3
.equ TS_CODE, 4
.equ TS_LINK, 5
.equ TITLE_LINES, 4             # lines at most: the header, the hint and description paragraphs, the
.equ PARA_LINES, 4              #   detail, the hook's words, an extra line, the JSON, the command,
.equ DETAIL_LINES, 6            #   the field, a button's label
.equ NOTE_LINES, 8
.equ EXTRA_LINES, 8
.equ JSON_LINES, 40
.equ EDIT_ROWS, 6
.equ FIELD_ROWS, 3
.equ LABEL_LINES, 12
.equ STOPS_MAX, 20
# the question card
.equ QID_TAB, 0x200             # ID_AGCARD + : a tab (+ its question, 16)
.equ QID_CLOSE, 0x210           #   the ×
.equ QID_FOLD, 0x211
.equ QID_SUBMIT, 0x212
.equ QID_FIELD, 0x213           #   Other's field
.equ QID_OPT, 0x220             #   a row (+ the row, 17)
.equ QID_LINKS, 0x300           #   the preview's links (+ their index, to 0x4ff)
.equ LK_TAB, 16                 # its layout items (item_letters)
.equ LK_CLOSE, 17
.equ LK_OPT, 18                 #   a row (LI_idx: the row; the last one is Other)
.equ LK_OLINE, 19               #   a line in it (LI_idx: the row | its style << 8)
.equ LK_PREVIEW, 20             #   the preview (LI_idx: the row it shows)
.equ QTEXT_LINES, 6             # lines at most: the question, a label, a description
.equ OLABEL_LINES, 3
.equ ODESC_LINES, 3
.equ PREVIEW_MIN, 3             # the preview's body: this many to PREVIEW_LINES lines of the panel's text
.equ PREVIEW_LINES, 16
.equ QC_BESIDE_W, 480           # a card this wide (2 x 240) shows the preview beside the rows, else under
# plan review (task 11): the plan card's comments
.equ CID_UNC, 0x100             # ID_AGCARD + : comment i's × (0x100 + i)
.equ LK_UNC, 8                  # a comment's × (LI_idx: the comment)
.equ CMT_MAX, 16                # comments a card takes
.equ QUOTE_CHARS, 80            # a quote shown is cut to this many characters and "…"
.equ QBUF, 400                  # a quote shown, with its quotes (qbuf: one per comment)
.equ CD_UNC, -16                # CD_focus of comment i's ×: CD_UNC - i
.equ QUOTE_LINES, 2
.equ COMMENT_LINES, 4

STRUCT
F LI_kind, 4
F LI_idx, 4
F LI_x, 4
F LI_y, 4
F LI_w, 4
F LI_h, 4
F LI_ptr, 8
F LI_len, 8
ENDSTRUCT LI_SIZE

.data
.p2align 2
.globl g_card_lock_ms, g_card_keyed_ms
g_card_lock_ms: .long CARD_LOCK_MS
g_card_keyed_ms: .long CARD_KEYED_MS

.bss
.p2align 3
lis: .zero LI_SIZE * LI_MAX     # the last layout's items (bc_layout), from the card's top left
li_spare: .zero LI_SIZE         # where items past LI_MAX go
nlis: .long 0
lay_total: .long 0
lx: .long 0                     # the layout's content: left, width, the next item's top
lw: .long 0
ly: .long 0
foc_y: .long 0                  # the focused control's place in the layout
foc_h: .long 0
.p2align 3
lbuf: .zero LBUF_ONE * BTN_MAX  # each button's label with its place (a cstr each)
ldest: .zero 4 * BTN_MAX        # where its place starts in it, -1 none
stops: .zero 4 * STOPS_MAX      # the focus stops in order (CD_EDIT, buttons, CD_FIELD)
nstops: .long 0
pend_act: .long 0               # a click's answer, sent after the drawing (it frees the card)
pend_dest: .long 0              # a click on the place's link
dsb: .zero SB_SIZE              # dumps

.text

# ---------------------------------------------------------------- making and freeing

# FN agentcard_new(kind) -> rax a new card of that kind (focus on its first button, the place 0)
FN agentcard_new
    PROLOGUE
    mov ebx, edi
    mov edi, CD_SIZE
    call mem_alloc
    mov r12, rax
    mov rdi, rax
    xor esi, esi
    mov edx, CD_SIZE
    call memset
    mov [r12 + CD_kind], ebx
    mov dword ptr [r12 + CD_chosen], 0
    mov dword ptr [r12 + CD_field + TF_prefx], -1
    mov dword ptr [r12 + CD_edit + TF_prefx], -1
    mov rax, r12
    EPILOGUE

# text_slot(which) -> rax the CD offset of that text field, or -1 (CDT_EDIT has none)
text_slot:
    mov rax, -1
    cmp edi, CDT_PH
    ja 1f
    lea rcx, [rip + text_slots]
    movsxd rax, dword ptr [rcx + rdi*4]
1:  ret

# FN agentcard_text(CD*, which CDT_*, ptr, len): a text of the card (copied); CDT_EDIT is the editable
#   command's text (CDF_EDIT)
FN agentcard_text
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, CDT_EDIT
    jne 1f
    or dword ptr [rbx + CD_flags], CDF_EDIT
    lea rdi, [rbx + CD_edit]
    mov rsi, r13
    mov rdx, r14
    call tf_set
    EPILOGUE
1:  mov edi, r12d
    call text_slot
    test rax, rax
    js 9f
    mov r15, rax
    mov rdi, [rbx + r15]
    call mem_free
    mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov [rbx + r15], rax
9:  EPILOGUE

# FN agentcard_btn(CD*, label cstr, act CBA_*, flags CDBF_*): a button (copied); at most BTN_MAX
FN agentcard_btn
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    cmp qword ptr [rbx + CD_btns + VEC_len], BTN_MAX
    jae 9f
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov r15, rax
    lea rdi, [rbx + CD_btns]
    mov esi, CDB_SIZE
    call vec_push
    mov [rax + CDB_label], r15
    mov [rax + CDB_act], r13d
    mov [rax + CDB_flags], r14d
9:  EPILOGUE

# FN agentcard_extra(CD*, line cstr): a line under the rule button (copied)
FN agentcard_extra
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov r12, rsi
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov r12, rax
    lea rdi, [rbx + CD_extra]
    mov esi, 8
    call vec_push
    mov [rax], r12
    EPILOGUE

# FN agentcard_dest(CD*, id, label, tip): a place a rule can go (static cstrs, the driver's)
FN agentcard_dest
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    lea rdi, [rbx + CD_dests]
    mov esi, CDD_SIZE
    call vec_push
    mov [rax + CDD_id], r12
    mov [rax + CDD_label], r13
    mov [rax + CDD_tip], r14
    EPILOGUE

# FN agentcard_free(CD*): the card and what it owns (0: nothing)
FN agentcard_free
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    xor r12d, r12d
1:  cmp r12d, CDT_PH
    ja 2f
    mov edi, r12d
    inc r12d
    call text_slot
    test rax, rax
    js 1b
    mov rdi, [rbx + rax]
    call mem_free
    jmp 1b
2:  xor r12d, r12d
3:  cmp r12, [rbx + CD_btns + VEC_len]
    jae 4f
    mov rax, [rbx + CD_btns + VEC_ptr]
    imul rcx, r12, CDB_SIZE
    mov rdi, [rax + rcx + CDB_label]
    call mem_free
    inc r12
    jmp 3b
4:  xor r12d, r12d
5:  cmp r12, [rbx + CD_extra + VEC_len]
    jae 6f
    mov rax, [rbx + CD_extra + VEC_ptr]
    mov rdi, [rax + r12*8]
    call mem_free
    inc r12
    jmp 5b
6:  mov rdi, rbx                # the question card's questions
    call qc_free
    lea rdi, [rbx + CD_btns]
    call vec_free
    lea rdi, [rbx + CD_extra]
    call vec_free
    lea rdi, [rbx + CD_dests]
    call vec_free
    lea rdi, [rbx + CD_qs]
    call vec_free
    mov rdi, rbx                # plan review: the comments' texts
    call comments_free
    lea rdi, [rbx + CD_comments]
    call vec_free
    lea rdi, [rbx + CD_edit + TF_sb]
    call sb_free
    lea rdi, [rbx + CD_field + TF_sb]
    call sb_free
    mov rdi, rbx
    call mem_free
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# ---------------------------------------------------------------- the card on show

# FN agentcard_of(AS*) -> rax the card its oldest request shows, or 0
FN agentcard_of
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 9f
    cmp qword ptr [rcx + AL_reqs + VEC_len], 0
    je 9f
    mov rcx, [rcx + AL_reqs + VEC_ptr]
    mov rcx, [rcx]
    mov rcx, [rcx + AQ_card]
    test rcx, rcx
    jz 9f
    test dword ptr [rcx + CD_flags], CDF_SHOWN
    jz 9f
    mov rax, rcx
9:  ret

# FN agentcard_live(CD*) -> eax 1 when its lock is over (its buttons and keys work)
FN agentcard_live
    PROLOGUE
    mov rbx, rdi
    call time_ms
    sub rax, [rbx + CD_born]
    movsxd rcx, dword ptr [rip + g_card_lock_ms]
    xor edx, edx
    cmp rax, rcx
    setge dl
    mov eax, edx
    EPILOGUE

# has_keys(AS*, CD*) -> eax 1 when the card has the keyboard: the focus in the panel, the panel shown, its
#   conversation the open one, no popup taking the keys, no new conversation being written
has_keys:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    jne 9f
    cmp dword ptr [rip + g_show_agents], 0
    je 9f
    call agentext_new_active
    test rax, rax
    jnz 9f
    call agentpop_kind
    test eax, eax
    jnz 9f
    call agents_open_driven
    cmp rax, rbx
    jne 9f
    mov r12d, 1
9:  mov eax, r12d
    EPILOGUE

# FN agentcard_shown(AS*, CD*): the card shows for the first time: its lock starts, its focus is its first
#   button (the last with CDF_DEFNO), and it takes the keyboard by the focus rule (see the top)
FN agentcard_shown
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test dword ptr [r12 + CD_flags], CDF_SHOWN
    jnz 9f
    or dword ptr [r12 + CD_flags], CDF_SHOWN
    and dword ptr [r12 + CD_flags], ~CDF_LIVE
    call time_ms
    mov [r12 + CD_born], rax
    mov r13, rax
    xor eax, eax
    test dword ptr [r12 + CD_flags], CDF_DEFNO
    jz 1f
    mov rax, [r12 + CD_btns + VEC_len]
    dec eax
    jns 1f
    xor eax, eax
1:  mov [r12 + CD_focus], eax
    cmp dword ptr [r12 + CD_kind], CDK_QUESTIONS
    jne 11f
    mov dword ptr [r12 + CD_focus], CD_OPTS     # the question card: on its first row
11: mov rdi, r12                # plan review: the buttons, header and hint its comments call for
    call vis_set
    mov dword ptr [r12 + CD_scroll], 0
    or dword ptr [r12 + CD_flags], CDF_WHEEL     # its top (its header) shows first; a key brings the focus
    # the focus rule
    mov eax, [rip + g_focus]
    cmp eax, FOCUS_AGENTS
    je 2f
    cmp eax, FOCUS_AGENT_INPUT
    jne 8f
2:  cmp dword ptr [rip + g_show_agents], 0
    je 8f
    call agentext_new_active
    test rax, rax
    jnz 8f
    call agents_open_driven
    cmp rax, rbx
    jne 8f
    mov rax, [rbx + AS_live]
    test rax, rax
    jz 8f
    mov rcx, r13
    sub rcx, [rax + AL_keyed]
    movsxd rdx, dword ptr [rip + g_card_keyed_ms]
    cmp qword ptr [rax + AL_keyed], 0
    je 3f
    cmp rcx, rdx
    jl 8f                       # the box had a key just now: the keyboard stays there
3:  call agentpop_close         # a popup of the box's would take its keys first
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
8:  mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN agentcard_timeout() -> eax ms until the shown card's lock ends, 0 once when it just ended (its
#   redraw), else -1 (no card on show, its lock over, the panel hidden)
FN agentcard_timeout
    PROLOGUE
    mov eax, -1
    cmp dword ptr [rip + g_show_agents], 0
    je 9f
    call agents_open_driven
    mov rdi, rax
    call agentcard_of
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rdi, rax                # the question card's move to the next question
    call qc_advance_due
    test eax, eax
    jns 9f
    test dword ptr [rbx + CD_flags], CDF_LIVE
    jnz 8f
    call time_ms
    mov rcx, [rbx + CD_born]
    movsxd rdx, dword ptr [rip + g_card_lock_ms]
    add rcx, rdx
    sub rcx, rax
    jg 7f
    or dword ptr [rbx + CD_flags], CDF_LIVE
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE
7:  mov eax, ecx
    EPILOGUE
8:  mov eax, -1
9:  EPILOGUE

# kind_fn(CD*, slot offset) -> rax the kind's entry (0: none)
kind_fn:
    xor eax, eax
    mov ecx, [rdi + CD_kind]
    dec ecx
    cmp ecx, CDK_DIALOG - 1
    ja 1f
    imul ecx, ecx, 32
    lea rdx, [rip + kinds]
    add rdx, rcx
    mov rax, [rdx + rsi]
1:  ret

# FN agentcard_h(AS*, w) -> eax the session's card's height, 0 without one
FN agentcard_h
    PROLOGUE
    mov r12d, esi
    call agentcard_of
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rdi, rax
    xor esi, esi
    call kind_fn
    test rax, rax
    jz 8f
    mov rdi, rbx
    mov esi, r12d
    call rax
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentcard_draw(AS*, x, y, w, h): the session's card in the room it was given
FN agentcard_draw
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov [rsp], r8d
    call agentcard_of
    test rax, rax
    jz 9f
    mov r15, rax
    mov rdi, rax
    mov esi, 8
    call kind_fn
    test rax, rax
    jz 9f
    mov r10, rax
    mov rdi, rbx
    mov rsi, r15
    mov edx, r12d
    mov ecx, r13d
    mov r8d, r14d
    mov r9d, [rsp]
    call r10
9:  EPILOGUE

# FN agentcard_key(AS*, keysym, cp, mods) -> eax 1 when the session's card took the key; only while it
#   has the keyboard
FN agentcard_key
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov rdi, rbx
    call agentcard_of
    test rax, rax
    jz 8f
    mov r15, rax
    mov rdi, rbx
    mov rsi, r15
    call has_keys
    test eax, eax
    jz 8f
    mov rdi, r15
    mov esi, 16
    call kind_fn
    test rax, rax
    jz 8f
    mov r10, rax
    mov rdi, rbx
    mov rsi, r15
    mov edx, r12d
    mov ecx, r13d
    mov r8d, r14d
    call r10
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentcard_answer(AS*, act) -> eax 1 when the card's driver got the answer: CD_chosen is act, then
#   DRV_reply (which frees the card once the answer is written). Nothing while its lock lasts. An answer
#   from the card that had the keyboard gives the box the keys; when the card stays (the answer could not
#   be written) it has them again
FN agentcard_answer
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call agentcard_of
    test rax, rax
    jz 8f
    mov r13, rax
    mov rdi, rax
    call agentcard_live
    test eax, eax
    jz 8f
    cmp r12d, CBA_SUBMIT        # the question card: not before every question has an answer
    jne 0f
    mov rdi, r13
    call qc_complete
    test eax, eax
    jz 8f
0:  mov r14, [rbx + AS_live]
    mov [r13 + CD_chosen], r12d
    call time_ms
    mov [r14 + AL_used], rax
    xor r15d, r15d
    mov rdi, rbx
    mov rsi, r13
    call has_keys
    test eax, eax
    jz 1f
    mov r15d, 1
    mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
1:  mov rdi, r14
    mov rsi, [r13 + CD_token]
    mov rdx, r13
    mov rax, [r14 + AL_drv]
    call [rax + DRV_reply]
    test r15d, r15d
    jz 2f
    mov rdi, rbx                # still there: the answer did not go
    call agentcard_of
    cmp rax, r13
    jne 2f
    cmp dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    jne 2f
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
2:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentcard_pick(AS*, n) -> eax 1 when button n (from 0) was answered: its lock is waited out first
#   (the loop runs meanwhile), as a click right after it
FN agentcard_pick
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
1:  call agents_open_driven     # (the loop may close the conversation meanwhile)
    cmp rax, rbx
    jne 8f
    mov rdi, rbx
    call agentcard_of
    test rax, rax
    jz 8f
    mov r13, rax
    mov rdi, rax
    call agentcard_live
    test eax, eax
    jnz 2f
    mov edi, 10
    call loop_poll
    call app_tick
    jmp 1b
2:  cmp dword ptr [r13 + CD_kind], CDK_QUESTIONS
    jne 3f
    mov rdi, r13                # the question card: row n of its question, as a click on it
    mov esi, r12d
    call qc_pick
    mov eax, 1
    EPILOGUE
3:  mov rdi, r13                # plan review: button n among those shown (CDBF_HIDE)
    mov esi, r12d
    call btn_nth
    test rax, rax
    js 8f
    mov rdi, r13
    mov rsi, rax
    call btn_act
    mov esi, eax
    mov rdi, rbx
    call agentcard_answer
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentcard_set_text(AS*, which 0 the field | 1 the command | 2 a question's Other (picked), ptr, len)
#   -> eax 1 set
FN agentcard_set_text
    PROLOGUE
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    call agentcard_of
    test rax, rax
    jz 8f
    mov rbx, rax
    cmp r12d, 2                 # the question card's Other
    jne 0f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call qc_set_other
    EPILOGUE
0:  lea rdi, [rbx + CD_field]
    test r12d, r12d
    jz 1f
    test dword ptr [rbx + CD_flags], CDF_EDIT
    jz 8f
    lea rdi, [rbx + CD_edit]
1:  mov rsi, r13
    mov rdx, r14
    call tf_set
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentcard_toggle(AS*, what 0 fold | 1 the Details | 2 the place | 3 Submit answers | 4 the ×) -> eax 1
#   done (as a click on it)
FN agentcard_toggle
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call agentcard_of
    test rax, rax
    jz 8f
    mov r13, rax
    cmp r12d, 3                 # the question card's Submit answers and ×
    jb 0f
    mov esi, CBA_SUBMIT
    je 4f
    mov esi, CBA_NO
4:  mov rdi, rbx
    call agentcard_answer
    mov eax, 1
    EPILOGUE
0:  cmp r12d, 2
    jne 1f
    mov rdi, rbx
    mov rsi, r13
    mov edx, 1
    call dest_step
    jmp 7f
1:  mov eax, CDF_FOLDED
    test r12d, r12d
    jz 2f
    mov eax, CDF_JSON
2:  xor [r13 + CD_flags], eax
7:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# dest_step(AS*, CD*, dir): the place one on (dir 1) or back (-1), round; kept as the project's last pick
#   (agentcfg AGF_DEST)
dest_step:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rcx, [r12 + CD_dests + VEC_len]
    test rcx, rcx
    jz 9f
    mov eax, [r12 + CD_dest]
    add eax, edx
    jns 1f
    add eax, ecx
1:  cmp eax, ecx
    jb 2f
    sub eax, ecx
2:  mov [r12 + CD_dest], eax
    mov edi, [rbx + AS_kind]
    call agentcfg_get
    mov r13, rax
    mov rdi, rax
    call agentcfg_need
    mov eax, [r12 + CD_dest]
    imul rax, rax, CDD_SIZE
    add rax, [r12 + CD_dests + VEC_ptr]
    mov r14, [rax + CDD_id]
    mov rdi, r14
    call strlen
    mov rdi, r13
    mov esi, AGF_DEST
    mov rdx, r14
    mov rcx, rax
    call agentcfg_set
    mov rdi, r13
    call agentcfg_save
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN agentcard_waiting(AS*) -> rax "Waiting for permission…" ("Waiting for your answer…" for a question)
#   while its card waits and the box (its own) has text, else 0
FN agentcard_waiting
    PROLOGUE
    mov rbx, rdi
    call agentcard_of
    test rax, rax
    jz 8f
    mov r12, rax
    call agentext_box_owner
    cmp rax, rbx
    jne 8f
    call agentext_box
    mov rdi, rax
    call tf_text
    test rdx, rdx
    jz 8f
    lea rax, [rip + .Lwaiting]
    cmp dword ptr [r12 + CD_kind], CDK_QUESTIONS
    jne 9f
    lea rax, [rip + .Lwaiting_q]    # the question card's
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------------------------------------------------------- the button card: layout

# st_face(style) -> rax its FACE*; st_lineh(style) -> eax a line's height; st_color(style) -> eax
st_face:
    lea rcx, [rip + style_tbl]
    shl edi, 4
    mov rax, [rcx + rdi]
    mov rax, [rax]
    ret
st_lineh:
    lea rcx, [rip + style_tbl]
    shl edi, 4
    mov rax, [rcx + rdi]
    mov rax, [rax]
    mov eax, [rax + FACE_lineh]
    mov edx, [rcx + rdi + 12]
    lea rcx, [rip + g_pmt]
    add eax, [rcx + rdx*4]
    ret
st_color:
    lea rcx, [rip + style_tbl]
    shl edi, 4
    mov edx, [rcx + rdi + 8]
    lea rcx, [rip + g_theme]
    mov eax, [rcx + rdx*4]
    ret

# li_new(kind, idx) -> rax a new layout item (its place still to fill); changes rax and rcx only
li_new:
    mov eax, [rip + nlis]
    cmp eax, LI_MAX
    jb 1f
    lea rax, [rip + li_spare]
    jmp 2f
1:  inc dword ptr [rip + nlis]
    imul eax, eax, LI_SIZE
    lea rcx, [rip + lis]
    add rax, rcx
2:  mov [rax + LI_kind], edi
    mov [rax + LI_idx], esi
    mov qword ptr [rax + LI_ptr], 0
    mov qword ptr [rax + LI_len], 0
    ret

# wrap_one(face, ptr, len, maxw) -> rax the bytes of the first line at maxw px (to a line feed, broken
#   after a word where it can be, a character at least), rdx the bytes it takes (its space or line feed too)
wrap_one:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    xor r15d, r15d
1:  cmp r15, r13
    jae 2f
    cmp byte ptr [r12 + r15], 10
    je 2f
    inc r15
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    mov ecx, r14d
    call text_fit
    cmp rax, r15
    jae 7f
    mov rcx, rax
3:  cmp byte ptr [r12 + rcx], ' '
    je 4f
    test rcx, rcx
    jz 5f
    dec rcx
    jmp 3b
4:  test rcx, rcx
    jz 5f
    mov rax, rcx
    lea rdx, [rcx + 1]
    EPILOGUE
5:  test rax, rax
    jnz 6f
    mov rdi, r12
    mov rsi, r15
    call utf8_decode
    mov eax, edx
6:  mov rdx, rax
    EPILOGUE
7:  mov rax, r15
    mov rdx, r15
    cmp r15, r13
    jae 8f
    inc rdx
8:  EPILOGUE

# lay_text(ptr, len, style, maxlines): the text's lines as items at lx, ly, lw (the last one allowed is
#   cut with "…" when drawn); ly moves under them
lay_text:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov [rsp], ecx
    xor ebx, ebx
    test r13, r13
    jz 9f
    mov edi, r14d
    call st_face
    mov r15, rax
1:  test r13, r13
    jz 9f
    inc ebx
    mov rdi, r15
    mov rsi, r12
    mov rdx, r13
    mov ecx, [rip + lw]
    call wrap_one
    mov [rsp + 8], rdx
    cmp ebx, [rsp]
    jb 2f
    mov rcx, r13                # the last line allowed: the rest of its paragraph (cut when drawn)
    xor eax, eax
11: cmp rax, rcx
    jae 2f
    cmp byte ptr [r12 + rax], 10
    je 2f
    inc rax
    jmp 11b
2:  push rax
    push rax
    mov edi, LK_TEXT
    mov esi, r14d
    call li_new
    mov rdx, rax
    pop rax
    pop rcx
    mov [rdx + LI_ptr], r12
    mov [rdx + LI_len], rax
    mov eax, [rip + lx]
    mov [rdx + LI_x], eax
    mov eax, [rip + lw]
    mov [rdx + LI_w], eax
    mov eax, [rip + ly]
    mov [rdx + LI_y], eax
    push rdx
    push rdx
    mov edi, r14d
    call st_lineh
    pop rdx
    pop rdx
    mov [rdx + LI_h], eax
    add [rip + ly], eax
    mov rdx, [rsp + 8]
    add r12, rdx
    sub r13, rdx
    cmp ebx, [rsp]
    jb 1b
9:  EPILOGUE

# lay_cstr(cstr or 0, style, maxlines)
lay_cstr:
    test rdi, rdi
    jz 1f
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    mov edx, r12d
    mov ecx, r13d
    call lay_text
    pop r13
    pop r12
    pop rbx
1:  ret

# lay_paras(cstr or 0, style, maxlines): each LF-separated paragraph, maxlines each
lay_paras:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    mov r14d, edx
    test r12, r12
    jz 9f
1:  cmp byte ptr [r12], 0
    je 9f
    xor ebx, ebx
2:  movzx eax, byte ptr [r12 + rbx]
    test eax, eax
    jz 3f
    cmp eax, 10
    je 3f
    inc ebx
    jmp 2b
3:  test ebx, ebx
    jz 4f
    mov rdi, r12
    mov esi, ebx
    mov edx, r13d
    mov ecx, r14d
    call lay_text
4:  add r12, rbx
    cmp byte ptr [r12], 10
    jne 9f
    inc r12
    jmp 1b
9:  EPILOGUE

# ta_box_h(tf, w, maxrows) -> eax a text area's height for its text at width w: its rows (1 to maxrows)
#   times its line's height and its padding (as the prompt box's)
ta_box_h:
    PROLOGUE
    mov rbx, rdi
    mov r12d, edx
    mov rax, [rip + ag_fui]
    mov [rbx + TF_face], rax
    call ta_layout
    test eax, eax
    jnz 1f
    mov eax, 1
1:  cmp eax, r12d
    cmova eax, r12d
    mov r13d, eax
    mov rdi, rbx
    call ta_line_h_of
    imul eax, r13d
    PM ecx, MI_12
    cmp ecx, [rip + g_mt + 4*MI_12]
    jge 2f
    mov ecx, [rip + g_mt + 4*MI_12]
2:  add eax, ecx
    EPILOGUE

# compose(CD*, i) -> rax lbuf's label of button i (its place appended for CDBF_DEST), rdx its length;
#   ldest[i] where the place starts, -1 none
compose:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov eax, r12d
    imul eax, eax, LBUF_ONE
    lea r13, [rip + lbuf]
    add r13, rax                # the label's room
    mov rax, [rbx + CD_btns + VEC_ptr]
    imul rcx, r12, CDB_SIZE
    add rax, rcx
    mov r14, rax                # CDB*
    mov rdi, [r14 + CDB_label]
    call strlen
    mov rdi, rax
    mov rsi, [r14 + CDB_label]
    mov edx, LBUF_ONE - 1
    call utf8_cut
    mov r15, rax
    mov rdi, r13
    mov rsi, [r14 + CDB_label]
    mov rdx, rax
    call memcpy_
    lea rcx, [rip + ldest]
    mov dword ptr [rcx + r12*4], -1
    test dword ptr [r14 + CDB_flags], CDBF_DEST
    jz 8f
    mov rcx, [rbx + CD_dests + VEC_len]
    test rcx, rcx
    jz 8f
    mov eax, [rbx + CD_dest]
    cmp rax, rcx
    jb 1f
    xor eax, eax
1:  imul rax, rax, CDD_SIZE
    add rax, [rbx + CD_dests + VEC_ptr]
    mov r14, [rax + CDD_label]
    lea rcx, [rip + ldest]
    mov [rcx + r12*4], r15d
    mov rdi, r14
    call strlen
    mov rdi, rax
    mov rsi, r14
    mov edx, LBUF_ONE - 1
    sub rdx, r15
    call utf8_cut
    lea rdi, [r13 + r15]
    mov rsi, r14
    mov rdx, rax
    add r15, rax
    call memcpy_
8:  mov byte ptr [r13 + r15], 0
    mov rax, r13
    mov rdx, r15
    EPILOGUE

# memcpy_(dst, src, n)
memcpy_:
    mov rcx, rdx
    rep movsb
    ret

# btn_inset(CD*) -> eax where a button's text starts from its left: after its number (MI_6, a digit's
#   width, MI_6), or MI_8 when the numbers are not drawn
btn_inset:
    PM eax, MI_8
    test dword ptr [rdi + CD_flags], CDF_DEFNO
    jnz 1f
    push rbx
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Ldigit]
    mov edx, 1
    call text_width
    add eax, [rip + g_pmt + 4*MI_6]
    add eax, [rip + g_pmt + 4*MI_6]
    pop rbx
1:  ret

# set_focus_rect(y, h): the focused control's place
set_focus_rect:
    mov [rip + foc_y], edi
    mov [rip + foc_h], esi
    ret

# FN bc_layout(CD*, w) -> eax the card's height at width w; lis/nlis its items from its top left, foc_y and
#   foc_h the focused control's place, stops/nstops its focus stops
bc_layout:
    PROLOGUE 48
    mov rbx, rdi
    mov r12d, esi
    mov dword ptr [rip + nlis], 0
    mov dword ptr [rip + nstops], 0
    mov dword ptr [rip + foc_y], 0
    mov dword ptr [rip + foc_h], 0
    PM eax, MI_16               # the frame MI_8 in, the content MI_8 in from it
    mov [rip + lx], eax
    mov eax, r12d
    sub eax, [rip + g_pmt + 4*MI_16]
    sub eax, [rip + g_pmt + 4*MI_16]
    cmp eax, 16
    jge 1f
    mov eax, 16
1:  mov [rip + lw], eax
    PM eax, MI_6
    add eax, [rip + g_pmt + 4*MI_10]
    mov [rip + ly], eax
    # the fold button, right of the header's first line
    mov edi, TS_TITLE
    call st_lineh
    mov r13d, eax               # the header's line
    mov edi, LK_FOLD
    xor esi, esi
    call li_new
    mov ecx, [rip + lx]
    add ecx, [rip + lw]
    sub ecx, r13d
    mov [rax + LI_x], ecx
    mov ecx, [rip + ly]
    mov [rax + LI_y], ecx
    mov [rax + LI_w], r13d
    mov [rax + LI_h], r13d
    # the header beside it
    mov eax, [rip + lw]
    mov [rsp], eax
    sub eax, r13d
    sub eax, [rip + g_pmt + 4*MI_4]
    cmp eax, 8
    jge 2f
    mov eax, 8
2:  mov [rip + lw], eax
    mov edx, TITLE_LINES
    test dword ptr [rbx + CD_flags], CDF_FOLDED
    jz 3f
    mov edx, 1
3:  mov ecx, edx
    mov rdi, [rbx + CD_title]
    mov esi, TS_TITLE
    mov edx, ecx
    call lay_cstr
    mov eax, [rsp]
    mov [rip + lw], eax
    mov eax, [rip + g_pmt + 4*MI_6]
    add eax, [rip + g_pmt + 4*MI_10]
    add eax, r13d
    cmp [rip + ly], eax
    jge 31f
    mov [rip + ly], eax         # an empty header still has its line
31: test dword ptr [rbx + CD_flags], CDF_FOLDED
    jnz .Lbl_end
    mov eax, [rip + g_pmt + 4*MI_4]
    add [rip + ly], eax
    # the hint, the detail
    mov rdi, [rbx + CD_hint]
    mov esi, TS_MUTED
    mov edx, PARA_LINES
    call lay_paras
    mov rdi, rbx                # plan review: "Comments (N)" and each comment with its ×
    call pc_layout
    mov rdi, [rbx + CD_detail]
    mov esi, TS_BODY
    mov edx, DETAIL_LINES
    call lay_paras
    # the editable command
    test dword ptr [rbx + CD_flags], CDF_EDIT
    jz 4f
    mov eax, [rip + g_pmt + 4*MI_2]
    add [rip + ly], eax
    lea rdi, [rbx + CD_edit]
    mov esi, [rip + lw]
    mov edx, EDIT_ROWS
    call ta_box_h
    mov r14d, eax
    mov edi, LK_EDIT
    xor esi, esi
    call li_new
    mov ecx, [rip + lx]
    mov [rax + LI_x], ecx
    mov ecx, [rip + lw]
    mov [rax + LI_w], ecx
    mov ecx, [rip + ly]
    mov [rax + LI_y], ecx
    mov [rax + LI_h], r14d
    mov edi, CD_EDIT
    call stop_add
    cmp dword ptr [rbx + CD_focus], CD_EDIT
    jne 41f
    mov edi, [rip + ly]
    mov esi, r14d
    call set_focus_rect
41: add [rip + ly], r14d
    mov eax, [rip + g_pmt + 4*MI_4]
    add [rip + ly], eax
4:  mov rdi, [rbx + CD_desc]
    mov esi, TS_MUTED
    mov edx, PARA_LINES
    call lay_paras
    # the hook's words
    cmp qword ptr [rbx + CD_note], 0
    je 5f
    mov eax, [rip + g_pmt + 4*MI_4]
    add [rip + ly], eax
    lea rdi, [rip + .Lhook]
    mov esi, TS_MUTED
    mov edx, 1
    call lay_cstr
    mov rdi, [rbx + CD_note]
    mov esi, TS_SMALL
    mov edx, NOTE_LINES
    call lay_paras
    # the input as JSON, behind "Details"
5:  cmp qword ptr [rbx + CD_json], 0
    je 6f
    mov edi, TS_LINK
    call st_lineh
    mov r14d, eax
    mov edi, LK_DETAILS
    xor esi, esi
    call li_new
    mov ecx, [rip + lx]
    mov [rax + LI_x], ecx
    mov ecx, [rip + lw]
    mov [rax + LI_w], ecx
    mov ecx, [rip + ly]
    mov [rax + LI_y], ecx
    mov [rax + LI_h], r14d
    add [rip + ly], r14d
    test dword ptr [rbx + CD_flags], CDF_JSON
    jz 6f
    mov rdi, [rbx + CD_json]
    mov esi, TS_CODE
    mov edx, JSON_LINES
    call lay_cstr
6:  mov eax, [rip + g_pmt + 4*MI_8]
    add [rip + ly], eax
    # the buttons. Locals: [rsp] lx and [rsp + 4] lw kept (the lines under the rule button), [rsp + 8]
    #   the label's bytes left, [rsp + 16] the button's index, [rsp + 20] its text's x, [rsp + 24] a
    #   line's height, [rsp + 28] the next line's y, [rsp + 32] the button's item, [rsp + 40] the label
    xor r14d, r14d
.Lbl_btn:
    cmp r14, [rbx + CD_btns + VEC_len]
    jae .Lbl_field
    mov rax, [rbx + CD_btns + VEC_ptr]  # plan review: a button its card does not show (CDBF_HIDE)
    imul rcx, r14, CDB_SIZE
    test dword ptr [rax + rcx + CDB_flags], CDBF_HIDE
    jnz 79f
    mov [rsp + 16], r14d
    mov rdi, rbx
    mov esi, r14d
    call compose
    mov [rsp + 40], rax
    mov [rsp + 8], rdx
    mov rdi, rbx
    call btn_inset
    mov ecx, [rip + lx]
    add ecx, eax
    mov [rsp + 20], ecx
    mov r13d, [rip + lw]        # the text's width
    sub r13d, eax
    sub r13d, [rip + g_pmt + 4*MI_6]
    cmp r13d, 8
    jge 7f
    mov r13d, 8
7:  mov edi, LK_BTN             # the button, its height to come
    mov esi, r14d
    call li_new
    mov [rsp + 32], rax
    mov ecx, [rip + lx]
    mov [rax + LI_x], ecx
    mov ecx, [rip + lw]
    mov [rax + LI_w], ecx
    mov ecx, [rip + ly]
    mov [rax + LI_y], ecx
    mov edi, r14d
    call stop_add
    mov edi, TS_SMALL
    call st_lineh
    mov [rsp + 24], eax
    mov eax, [rip + ly]
    add eax, [rip + g_pmt + 4*MI_6]
    mov [rsp + 28], eax
    xor r15d, r15d              # its lines
71: cmp qword ptr [rsp + 8], 0
    je 75f
    cmp r15d, LABEL_LINES
    jae 75f
    inc r15d
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rsp + 40]
    mov rdx, [rsp + 8]
    mov ecx, r13d
    call wrap_one
    mov r12, rdx                # (the width is not needed past here)
    mov rcx, rax
    cmp r15d, LABEL_LINES       # the last line it may have: the rest (cut when drawn)
    jb 72f
    mov rcx, [rsp + 8]
72: push rcx
    push rcx
    mov edi, LK_BLINE
    mov esi, r14d
    call li_new
    pop rcx
    pop rcx
    mov rdx, [rsp + 40]
    mov [rax + LI_ptr], rdx
    mov [rax + LI_len], rcx
    mov ecx, [rsp + 20]
    mov [rax + LI_x], ecx
    mov [rax + LI_w], r13d
    mov ecx, [rsp + 28]
    mov [rax + LI_y], ecx
    mov ecx, [rsp + 24]
    mov [rax + LI_h], ecx
    add [rsp + 28], ecx
    add [rsp + 40], r12
    sub [rsp + 8], r12
    jmp 71b
75: mov eax, [rsp + 28]         # its height: its lines and their padding, MI_32 at least
    sub eax, [rip + ly]
    add eax, [rip + g_pmt + 4*MI_6]
    cmp eax, [rip + g_pmt + 4*MI_32]
    jge 76f
    mov eax, [rip + g_pmt + 4*MI_32]
76: mov rcx, [rsp + 32]
    mov [rcx + LI_h], eax
    mov r15d, eax
    cmp r14d, [rbx + CD_focus]
    jne 77f
    mov edi, [rip + ly]
    mov esi, r15d
    call set_focus_rect
77: add [rip + ly], r15d
    mov eax, [rip + g_pmt + 4*MI_6]
    add [rip + ly], eax
    # the lines under the rule button
    mov rax, [rbx + CD_btns + VEC_ptr]
    imul rcx, r14, CDB_SIZE
    cmp dword ptr [rax + rcx + CDB_act], CBA_RULE
    jne 79f
    mov eax, [rip + lx]
    mov [rsp], eax
    mov eax, [rip + lw]
    mov [rsp + 4], eax
    PM eax, MI_12
    add [rip + lx], eax
    sub [rip + lw], eax
    xor r15d, r15d
78: cmp r15, [rbx + CD_extra + VEC_len]
    jae 781f
    mov rax, [rbx + CD_extra + VEC_ptr]
    mov rdi, [rax + r15*8]
    mov esi, TS_MUTED
    mov edx, EXTRA_LINES
    call lay_cstr
    inc r15
    jmp 78b
781:mov eax, [rsp]
    mov [rip + lx], eax
    mov eax, [rsp + 4]
    mov [rip + lw], eax
    cmp qword ptr [rbx + CD_extra + VEC_len], 0
    je 79f
    mov eax, [rip + g_pmt + 4*MI_6]
    add [rip + ly], eax
79: inc r14
    jmp .Lbl_btn
.Lbl_field:
    lea rdi, [rbx + CD_field]
    mov esi, [rip + lw]
    mov edx, FIELD_ROWS
    call ta_box_h
    mov r14d, eax
    mov edi, LK_FIELD
    xor esi, esi
    call li_new
    mov ecx, [rip + lx]
    mov [rax + LI_x], ecx
    mov ecx, [rip + lw]
    mov [rax + LI_w], ecx
    mov ecx, [rip + ly]
    mov [rax + LI_y], ecx
    mov [rax + LI_h], r14d
    mov edi, CD_FIELD
    call stop_add
    cmp dword ptr [rbx + CD_focus], CD_FIELD
    jne 8f
    mov edi, [rip + ly]
    mov esi, r14d
    call set_focus_rect
8:  add [rip + ly], r14d
    mov eax, [rip + g_pmt + 4*MI_6]
    add [rip + ly], eax
    lea rdi, [rip + .Lesc]
    mov esi, TS_MUTED
    mov edx, 1
    call lay_cstr
.Lbl_end:
    mov eax, [rip + ly]
    add eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_2]
    mov [rip + lay_total], eax
    EPILOGUE

# stop_add(stop): one more focus stop (a button index, CD_EDIT, CD_FIELD)
stop_add:
    mov eax, [rip + nstops]
    cmp eax, STOPS_MAX
    jae 1f
    lea rcx, [rip + stops]
    mov [rcx + rax*4], edi
    inc dword ptr [rip + nstops]
1:  ret

# bc_h(CD*, w) -> eax its height
bc_h:
    jmp bc_layout

# ---------------------------------------------------------------- the button card: drawing

# bc_draw(AS*, CD*, x, y, w, h): taller than h it scrolls so the focused control shows. A click's answer
#   is sent after the drawing (it frees the card). Locals: [rsp] x, +4 y (the card's top, scrolled), +8
#   w, +12 h, +16 the room's top, +20 live, +24 keys, +28 the room's bottom, +32 to +51 an item's
bc_draw:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 16], ecx
    mov [rsp + 8], r8d
    mov [rsp + 12], r9d
    lea eax, [rcx + r9]
    mov [rsp + 28], eax
    mov [r12 + CD_room], r9d
    mov [r12 + CD_lastw], r8d
    mov dword ptr [rip + pend_act], 0
    mov dword ptr [rip + pend_dest], 0
    mov rdi, r12
    call agentcard_live
    mov [rsp + 20], eax
    mov rdi, rbx
    mov rsi, r12
    call has_keys
    mov [rsp + 24], eax
    mov rdi, r12
    mov esi, [rsp + 8]
    call bc_layout
    mov r13d, eax               # its height
    # the scroll: the wheel's over it, else the focused control in view
    xor eax, eax
    mov ecx, r13d
    sub ecx, [rsp + 12]
    jle 2f
    mov eax, [r12 + CD_scroll]
    cmp dword ptr [rip + g_scroll_y], 0
    je 10f
    push rcx
    push rax
    mov edi, [rsp + 16]
    mov esi, [rsp + 16 + 16]
    mov edx, [rsp + 16 + 8]
    mov ecx, [rsp + 16 + 12]
    call ui_in
    mov edx, eax
    pop rax
    pop rcx
    test edx, edx
    jz 10f
    add eax, [rip + g_scroll_y]
    mov dword ptr [rip + g_scroll_y], 0
    or dword ptr [r12 + CD_flags], CDF_WHEEL
    jmp 12f
10: test dword ptr [r12 + CD_flags], CDF_WHEEL
    jnz 12f
    mov r8d, [rsp + 12]         # a margin round it: MI_8, less when the room is short
    sub r8d, [rip + foc_h]
    sar r8d, 1
    cmp r8d, [rip + g_pmt + 4*MI_8]
    jle 101f
    mov r8d, [rip + g_pmt + 4*MI_8]
101:test r8d, r8d
    jns 102f
    xor r8d, r8d
102:mov edx, [rip + foc_y]      # its bottom in view, then its top (a control taller than the room: its top)
    add edx, [rip + foc_h]
    add edx, r8d
    sub edx, [rsp + 12]
    cmp edx, eax
    jle 11f
    mov eax, edx
11: mov edx, [rip + foc_y]
    sub edx, r8d
    cmp edx, eax
    jge 12f
    mov eax, edx
12: cmp eax, ecx
    cmovg eax, ecx
    test eax, eax
    jns 2f
    xor eax, eax
2:  mov [r12 + CD_scroll], eax
    sub [rsp + 4], eax
    # the frame
    PM eax, MI_8
    mov edi, [rsp]
    add edi, eax
    mov esi, [rsp + 4]
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, [rsp + 8]
    sub edx, eax
    sub edx, eax
    mov ecx, r13d
    sub ecx, [rip + g_pmt + 4*MI_8]
    PM r8d, MI_RADIUS
    COLOR r9d, T_ACCENT
    COLOR eax, T_PANEL
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    # cut: a thumb at its right edge says how much is above and below
    mov ecx, [rsp + 12]
    cmp r13d, ecx
    jle 15f
    mov eax, ecx                # its height: room * room / total, MI_16 at least
    imul eax, ecx
    xor edx, edx
    div r13d
    cmp eax, [rip + g_pmt + 4*MI_16]
    jge 13f
    mov eax, [rip + g_pmt + 4*MI_16]
13: mov [rsp + 32], eax
    mov eax, [r12 + CD_scroll]  # its top: scroll * (room - thumb) / (total - room)
    mov ecx, [rsp + 12]
    sub ecx, [rsp + 32]
    imul eax, ecx
    mov ecx, r13d
    sub ecx, [rsp + 12]
    xor edx, edx
    div ecx
    mov esi, [rsp + 16]
    add esi, eax
    mov edi, [rsp]
    add edi, [rsp + 8]
    sub edi, [rip + g_pmt + 4*MI_8]
    sub edi, [rip + g_pmt + 4*MI_6]
    PM edx, MI_3
    mov ecx, [rsp + 32]
    COLOR r8d, T_SCROLLBAR
    call gfx_fill
15: # the items
    xor r14d, r14d
.Lbd_item:
    cmp r14d, [rip + nlis]
    jae .Lbd_done
    imul eax, r14d, LI_SIZE
    lea r15, [rip + lis]
    add r15, rax
    inc r14d
    mov eax, [rsp + 4]          # in the room at all?
    add eax, [r15 + LI_y]
    cmp eax, [rsp + 28]
    jge .Lbd_item
    add eax, [r15 + LI_h]
    cmp eax, [rsp + 16]
    jle .Lbd_item
    mov eax, [r15 + LI_kind]
    cmp eax, LK_TEXT
    je .Lbd_text
    cmp eax, LK_FOLD
    je .Lbd_fold
    cmp eax, LK_EDIT
    je .Lbd_edit
    cmp eax, LK_FIELD
    je .Lbd_field
    cmp eax, LK_BTN
    je .Lbd_btn
    cmp eax, LK_BLINE
    je .Lbd_bline
    cmp eax, LK_DETAILS
    je .Lbd_details
    cmp eax, LK_UNC             # plan review: a comment's ×
    je .Lbd_unc
    jmp .Lbd_item
.Lbd_text:
    mov edi, [r15 + LI_idx]
    call st_color
    mov [rsp + 32], eax
    mov edi, [r15 + LI_idx]
    call st_face
    mov rdi, rax
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_h]
    mov r8, [r15 + LI_ptr]
    mov r9, [r15 + LI_len]
    mov eax, [r15 + LI_w]
    push rax
    mov eax, [rsp + 8 + 32]
    push rax
    call ui_text_v_fit
    add rsp, 16
    jmp .Lbd_item
.Lbd_fold:
    mov edi, ID_AGCARD + CID_FOLD
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_w]
    mov r8d, [r15 + LI_h]
    mov r9d, IC_CHEV_UP
    test dword ptr [r12 + CD_flags], CDF_FOLDED
    jz 1f
    mov r9d, IC_CHEV_D
1:  call ag_icon_btn
    test eax, UB_CLICK
    jz .Lbd_item
    xor dword ptr [r12 + CD_flags], CDF_FOLDED
    mov dword ptr [rip + g_dirty], 1
    jmp .Lbd_item
.Lbd_details:
    mov edi, ID_AGCARD + CID_DETAILS
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_w]
    mov r8d, [r15 + LI_h]
    call ui_btn
    test eax, UB_CLICK
    jz 1f
    xor dword ptr [r12 + CD_flags], CDF_JSON
    mov dword ptr [rip + g_dirty], 1
1:  lea r8, [rip + .Ldetails_shut]
    test dword ptr [r12 + CD_flags], CDF_JSON
    jz 2f
    lea r8, [rip + .Ldetails_open]
2:  mov rdi, r8
    push r8
    push r8
    call strlen
    pop r8
    pop r8
    mov r9, rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_h]
    mov eax, [r15 + LI_w]
    push rax
    COLOR eax, T_ACCENT
    push rax
    call ui_text_v_fit
    add rsp, 16
    jmp .Lbd_item
.Lbd_edit:
    lea rdi, [r12 + CD_edit]
    mov esi, ID_AGCARD + CID_EDIT
    mov edx, CD_EDIT
    xor ecx, ecx
    jmp .Lbd_area
.Lbd_field:
    lea rdi, [r12 + CD_field]
    mov esi, ID_AGCARD + CID_FIELD
    mov edx, CD_FIELD
    mov rcx, [r12 + CD_ph]
.Lbd_area:
    mov [rdi + TF_id], esi
    mov rax, [rip + ag_fui]
    mov [rdi + TF_face], rax
    mov [rsp + 36], edx
    push rcx
    push rcx
    xor r9d, r9d
    cmp [r12 + CD_focus], edx
    jne 1f
    mov r9d, [rsp + 16 + 24]    # focused when the card has the keys
1:  mov esi, [rsp + 16]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 16 + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_w]
    mov r8d, [r15 + LI_h]
    call ui_textarea
    add rsp, 16
    test eax, UB_PRESS
    jz .Lbd_item
    mov eax, [rsp + 36]
    mov [r12 + CD_focus], eax
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov dword ptr [rip + g_dirty], 1
    jmp .Lbd_item
.Lbd_btn:
    mov eax, [r15 + LI_idx]
    lea edi, [rax + ID_AGCARD + CID_BTN]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_w]
    mov r8d, [r15 + LI_h]
    call ui_btn
    mov [rsp + 32], eax
    mov ecx, [r15 + LI_idx]     # a button with the place: its tooltip names the arrows
    mov rax, [r12 + CD_btns + VEC_ptr]
    imul rcx, rcx, CDB_SIZE
    test dword ptr [rax + rcx + CDB_flags], CDBF_DEST
    jz 15f
    mov eax, [r15 + LI_idx]
    lea edi, [rax + ID_AGCARD + CID_BTN]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    add edx, [r15 + LI_h]
    mov ecx, [r15 + LI_w]
    mov r8d, [rsp + 32]
    lea r9, [rip + .Ltip_arrows]
    call tip_note_text
15: test dword ptr [rsp + 32], UB_CLICK
    jz 1f
    cmp dword ptr [rsp + 20], 0
    je 1f
    mov ecx, [r15 + LI_idx]     # its answer, after the drawing
    mov rax, [r12 + CD_btns + VEC_ptr]
    imul rcx, rcx, CDB_SIZE
    mov eax, [rax + rcx + CDB_act]
    mov [rip + pend_act], eax
1:  mov edi, [rsp]
    add edi, [r15 + LI_x]
    mov esi, [rsp + 4]
    add esi, [r15 + LI_y]
    mov edx, [r15 + LI_w]
    mov ecx, [r15 + LI_h]
    PM r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    mov eax, [r15 + LI_idx]
    cmp eax, [r12 + CD_focus]
    jne 2f
    COLOR r9d, T_ACCENT         # the focused one
2:  COLOR eax, T_INPUT
    cmp dword ptr [rsp + 20], 0
    je 3f
    test dword ptr [rsp + 32], UB_HOVER
    jz 3f
    COLOR eax, T_HOVER
3:  push rax
    push rax
    call gfx_frame
    add rsp, 16
    # its number (none with CDF_DEFNO, none past 9)
    test dword ptr [r12 + CD_flags], CDF_DEFNO
    jnz .Lbd_item
    mov rdi, r12                # plan review: its number among the buttons shown
    mov esi, [r15 + LI_idx]
    call btn_ord
    cmp eax, 9
    jae .Lbd_item
    add eax, '1'
    mov [rip + num], al
    mov edi, TS_SMALL
    call st_lineh
    mov ecx, eax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    add edx, [rip + g_pmt + 4*MI_6]
    lea r8, [rip + num]
    mov r9d, 1
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    jmp .Lbd_item
.Lbd_bline:
    # a line of a label: the part before the place, then the place as a link (a click cycles it)
    mov eax, [r15 + LI_idx]
    imul eax, eax, LBUF_ONE
    lea rcx, [rip + lbuf]
    add rcx, rax
    mov rax, [r15 + LI_ptr]
    sub rax, rcx                # the line's start in its label
    mov [rsp + 32], eax
    mov ecx, [r15 + LI_idx]
    lea rdx, [rip + ldest]
    mov ecx, [rdx + rcx*4]      # the place's start, -1 none
    mov rdx, [r15 + LI_len]     # the plain part's bytes
    test ecx, ecx
    js 1f
    sub ecx, eax
    jle 11f
    cmp rcx, rdx
    jae 1f
    mov edx, ecx
    jmp 1f
11: xor edx, edx
1:  mov [rsp + 36], edx
    COLOR eax, T_FG
    cmp dword ptr [rsp + 20], 0
    jne 2f
    COLOR eax, T_MUTED          # dimmed while locked
2:  mov [rsp + 40], eax
    test edx, edx
    jz 3f
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_h]
    mov r8, [r15 + LI_ptr]
    mov r9d, [rsp + 36]
    mov eax, [r15 + LI_w]
    push rax
    mov eax, [rsp + 8 + 40]
    push rax
    call ui_text_v_fit
    add rsp, 16
3:  mov eax, [rsp + 36]
    cmp rax, [r15 + LI_len]
    jae .Lbd_item
    mov rdi, [rip + ag_fsmall]  # the place
    mov rsi, [r15 + LI_ptr]
    mov edx, [rsp + 36]
    call text_width
    mov [rsp + 32], eax         # its x in the line
    mov rdi, [rip + ag_fsmall]
    mov rsi, [r15 + LI_ptr]
    mov eax, [rsp + 36]
    add rsi, rax
    mov rdx, [r15 + LI_len]
    sub edx, [rsp + 36]
    call text_width
    mov ecx, [r15 + LI_w]
    sub ecx, [rsp + 32]
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 44], eax         # its width
    mov edi, r14d               # a link id per line, by the item's number
    and edi, 7
    add edi, ID_AGCARD + CID_DEST
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    add esi, [rsp + 32]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [rsp + 44]
    mov r8d, [r15 + LI_h]
    call ui_btn
    mov [rsp + 48], eax
    mov ecx, [r12 + CD_dest]    # its tooltip: where the place saves
    imul rcx, rcx, CDD_SIZE
    add rcx, [r12 + CD_dests + VEC_ptr]
    mov r9, [rcx + CDD_tip]
    mov edi, r14d
    and edi, 7
    add edi, ID_AGCARD + CID_DEST
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    add esi, [rsp + 32]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    add edx, [r15 + LI_h]
    mov ecx, [rsp + 44]
    mov r8d, [rsp + 48]
    call tip_note_text
    test eax, UB_CLICK
    jz 4f
    cmp dword ptr [rsp + 20], 0
    je 4f
    mov dword ptr [rip + pend_dest], 1
    mov dword ptr [rip + pend_act], 0   # a click on the place is not one on its button
4:  COLOR eax, T_ACCENT
    cmp dword ptr [rsp + 20], 0
    jne 5f
    COLOR eax, T_MUTED
5:  mov [rsp + 40], eax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    add esi, [rsp + 32]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_h]
    mov r8, [r15 + LI_ptr]
    mov eax, [rsp + 36]
    add r8, rax
    mov r9, [r15 + LI_len]
    sub r9d, [rsp + 36]
    mov eax, [rsp + 44]
    push rax
    mov eax, [rsp + 8 + 40]
    push rax
    call ui_text_v_fit
    add rsp, 16
    mov edi, [rsp]              # underlined
    add edi, [r15 + LI_x]
    add edi, [rsp + 32]
    mov esi, [rsp + 4]
    add esi, [r15 + LI_y]
    add esi, [r15 + LI_h]
    sub esi, [rip + g_pmt + 4*MI_3]
    mov edx, [rsp + 44]
    PM ecx, MI_1
    mov r8d, [rsp + 40]
    call gfx_fill
    jmp .Lbd_item
.Lbd_done:
    mov eax, [rip + pend_unc]   # plan review: a comment's × clicked
    test eax, eax
    jz 11f
    mov dword ptr [rip + pend_unc], 0
    mov rdi, r12
    lea esi, [rax - 1]
    call agentcard_uncomment
11: cmp dword ptr [rip + pend_dest], 0
    je 1f
    mov rdi, rbx
    mov rsi, r12
    mov edx, 1
    call dest_step
1:  mov esi, [rip + pend_act]
    test esi, esi
    jz 9f
    mov rdi, rbx
    call agentcard_answer       # the card may be gone after this
9:  EPILOGUE

# ---------------------------------------------------------------- the button card: keys

# stop_at(CD*) -> eax the focused control's place among the stops (0 when it is none of them)
stop_at:
    mov edx, [rdi + CD_focus]
    xor eax, eax
1:  cmp eax, [rip + nstops]
    jae 2f
    lea rcx, [rip + stops]
    cmp [rcx + rax*4], edx
    je 3f
    inc eax
    jmp 1b
2:  xor eax, eax
3:  ret

# move_focus(CD*, dir): the next stop down (dir 1) or up (-1), round; the focused control is kept in view
#   again
move_focus:
    push rbx
    mov rbx, rdi
    and dword ptr [rdi + CD_flags], ~CDF_WHEEL
    push rsi
    call stop_at
    pop rsi
    mov ecx, [rip + nstops]
    test ecx, ecx
    jz 9f
    add eax, esi
    jns 1f
    add eax, ecx
1:  cmp eax, ecx
    jb 2f
    sub eax, ecx
2:  lea rcx, [rip + stops]
    mov eax, [rcx + rax*4]
    mov [rbx + CD_focus], eax
    mov dword ptr [rip + g_dirty], 1
9:  pop rbx
    ret

# btn_act(CD*, i) -> eax button i's action (0 past the end)
btn_act:
    xor eax, eax
    cmp rsi, [rdi + CD_btns + VEC_len]
    jae 1f
    mov rax, [rdi + CD_btns + VEC_ptr]
    imul rcx, rsi, CDB_SIZE
    mov eax, [rax + rcx + CDB_act]
1:  ret

# has_lf(TF*) -> eax 1 when its text has a line feed (Up and Down stay in it then)
has_lf:
    mov rcx, [rdi + TF_sb + SB_ptr]
    mov rdx, [rdi + TF_sb + SB_len]
    xor eax, eax
1:  test rdx, rdx
    jz 9f
    dec rdx
    cmp byte ptr [rcx + rdx], 10
    jne 1b
    mov eax, 1
9:  ret

# bc_key(AS*, CD*, keysym, cp, mods) -> eax 1 taken (see the top)
bc_key:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    test dword ptr [r12 + CD_flags], CDF_FOLDED
    jz 1f
    cmp r13d, KEY_ESCAPE        # folded: Escape is swallowed, Enter opens it
    je .Lbk_yes
    cmp r13d, KEY_RETURN
    je 12f
    cmp r13d, KEY_KP_ENTER
    jne .Lbk_no
12: and dword ptr [r12 + CD_flags], ~CDF_FOLDED
    jmp .Lbk_yes
1:  mov rdi, r12                # the stops of the width it was drawn at
    mov esi, [r12 + CD_lastw]
    test esi, esi
    jnz 11f
    mov esi, 400
11: call bc_layout
    mov rdi, r12
    call agentcard_live
    test eax, eax
    jnz 2f
    cmp r13d, KEY_TAB           # locked: nothing but Tab (out to the box)
    je .Lbk_no
    jmp .Lbk_yes
2:  mov eax, [r12 + CD_focus]
    cmp eax, CD_FIELD
    je .Lbk_text
    cmp eax, CD_EDIT
    je .Lbk_text
    # on a button
    test r15d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Lbk_no
    cmp r13d, KEY_ESCAPE
    je .Lbk_no_btn
    cmp r13d, KEY_RETURN
    je .Lbk_enter
    cmp r13d, KEY_KP_ENTER
    je .Lbk_enter
    cmp r13d, ' '
    je .Lbk_enter
    cmp r13d, KEY_DOWN
    je .Lbk_down
    cmp r13d, KEY_UP
    je .Lbk_up
    cmp r13d, KEY_LEFT
    je .Lbk_left
    cmp r13d, KEY_RIGHT
    je .Lbk_right
    test dword ptr [r12 + CD_flags], CDF_DEFNO
    jnz .Lbk_no                 # no numbers then
    mov eax, r14d               # the character, else the key (a digit's keysym is its character)
    test eax, eax
    jnz 21f
    mov eax, r13d
21:    sub eax, '1'
    cmp eax, 8
    ja .Lbk_no
    mov [rsp], eax              # plan review: the number among the buttons shown (CDBF_HIDE)
    mov rdi, r12
    mov esi, eax
    call btn_nth
    test rax, rax
    jns 3f
    cmp edx, [rsp]
    jne .Lbk_no
    mov dword ptr [r12 + CD_focus], CD_FIELD    # the number after the last: the field
    jmp .Lbk_yes
3:  mov rsi, rax
    mov rdi, r12
    call btn_act
    mov esi, eax
    jmp .Lbk_answer
.Lbk_enter:
    movsxd rsi, dword ptr [r12 + CD_focus]
    mov rdi, r12
    call btn_act
    test eax, eax
    jz .Lbk_yes
    mov esi, eax
    jmp .Lbk_answer
.Lbk_left:
    mov edx, -1
    jmp 4f
.Lbk_right:
    mov edx, 1
4:  movsxd rsi, dword ptr [r12 + CD_focus]
    cmp rsi, [r12 + CD_btns + VEC_len]
    jae .Lbk_no
    mov rax, [r12 + CD_btns + VEC_ptr]
    imul rcx, rsi, CDB_SIZE
    test dword ptr [rax + rcx + CDB_flags], CDBF_DEST
    jz .Lbk_no
    mov rdi, rbx
    mov rsi, r12
    call dest_step
    jmp .Lbk_yes
.Lbk_down:
    mov rdi, r12
    mov esi, 1
    call move_focus
    jmp .Lbk_yes
.Lbk_up:
    mov rdi, r12
    mov esi, -1
    call move_focus
    jmp .Lbk_yes
.Lbk_text:
    # in the command or the field
    lea rdi, [r12 + CD_field]
    cmp eax, CD_FIELD
    je 5f
    lea rdi, [r12 + CD_edit]
5:  mov [rsp], rdi
    cmp r13d, KEY_ESCAPE
    je .Lbk_no_btn
    cmp r13d, KEY_TAB
    je .Lbk_no
    cmp eax, CD_FIELD
    jne 6f
    cmp r13d, KEY_RETURN        # the field: Enter rejects with its text
    je 51f
    cmp r13d, KEY_KP_ENTER
    jne 6f
51: test r15d, MOD_SHIFT
    jz .Lbk_no_btn
6:  cmp r13d, KEY_DOWN
    je 7f
    cmp r13d, KEY_UP
    jne 8f
7:  mov rdi, [rsp]
    call has_lf
    test eax, eax
    jnz 8f
    cmp r13d, KEY_DOWN
    je .Lbk_down
    jmp .Lbk_up
8:  mov rdi, [rsp]
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    call ta_key
    test eax, eax
    jz .Lbk_no
    jmp .Lbk_yes
.Lbk_no_btn:
    mov rdi, r12                # Escape: the last button's action (the driver's No; of those shown)
    call btn_last
    mov rsi, rax
    test rsi, rsi
    js .Lbk_yes
    mov rdi, r12
    call btn_act
    mov esi, eax
.Lbk_answer:
    mov rdi, rbx
    call agentcard_answer       # (the card is gone once its answer went)
    jmp .Lbk_done
.Lbk_yes:
    and dword ptr [r12 + CD_flags], ~CDF_WHEEL  # a key: the focused control is kept in view again
.Lbk_done:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lbk_no:
    xor eax, eax
    EPILOGUE

# ---------------------------------------------------------------- dumps

# push_line(sb, word cstr, text cstr or 0): "WORD TEXT\n" (nothing without text)
push_line:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz 9f
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# push_paras(sb, word, cstr or 0): a line per LF-separated paragraph
push_paras:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz 9f
1:  cmp byte ptr [r13], 0
    je 9f
    xor r14d, r14d
2:  movzx eax, byte ptr [r13 + r14]
    test eax, eax
    jz 3f
    cmp eax, 10
    je 3f
    inc r14
    jmp 2b
3:  test r14, r14
    jz 4f
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
4:  add r13, r14
    cmp byte ptr [r13], 10
    jne 9f
    inc r13
    jmp 1b
9:  EPILOGUE

# push_tf(sb, word, TF*): "WORD TEXT\n" (line feeds as "\n")
push_tf:
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    xor r13d, r13d
1:  cmp r13, [r12 + TF_sb + SB_len]
    jae 3f
    mov rax, [r12 + TF_sb + SB_ptr]
    movzx esi, byte ptr [rax + r13]
    inc r13
    cmp esi, 10
    jne 2f
    mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
    mov esi, 'n'
2:  mov rdi, rbx
    call sb_push_byte
    jmp 1b
3:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# FN agentcard_dump(sb, AS*): print-agent-card for the session's card: "kind=K title=T live=0|1 focus=N|
#   edit|field dest=ID|- folded=0|1 keys=0|1 scroll=S room=R fy=Y fh=H" (N from 1; S the scroll, R the
#   room it was drawn in, Y and H the focused control's place in the card), then its kind's lines; nothing
#   without a card
FN agentcard_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call agentcard_of
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, rbx
    lea rsi, [rip + .Ld_kind]
    call sb_push_cstr
    mov eax, [r13 + CD_kind]
    dec eax
    cmp eax, CDK_DIALOG - 1
    jbe 1f
    xor eax, eax
1:  lea rcx, [rip + kind_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_title]
    call sb_push_cstr
    mov rsi, [r13 + CD_title]
    test rsi, rsi
    jz 2f
    mov rdi, rbx
    call sb_push_cstr
2:  mov rdi, rbx
    lea rsi, [rip + .Ld_live]
    call sb_push_cstr
    mov rdi, r13
    call agentcard_live
    mov esi, eax
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_focus]
    call sb_push_cstr
    mov eax, [r13 + CD_focus]
    lea rsi, [rip + .Lw_field]
    cmp eax, CD_FIELD
    je 3f
    lea rsi, [rip + .Lw_edit]
    cmp eax, CD_EDIT
    je 3f
    lea rsi, [rip + .Lw_options]    # the question card's rows
    cmp eax, CD_OPTS
    je 3f
    mov rdi, rbx                # plan review: a button's number among those shown, a comment's × "xN"
    mov rsi, r13
    call dump_focus
    jmp 4f
3:  mov rdi, rbx
    call sb_push_cstr
4:  mov rdi, rbx
    lea rsi, [rip + .Ld_dest]
    call sb_push_cstr
    lea rsi, [rip + .Ldash]
    mov rdi, r13                # only a card whose button names a place has one
    call dest_btn
    test eax, eax
    jz 5f
    lea rsi, [rip + .Ldash]
    mov rcx, [r13 + CD_dests + VEC_len]
    test rcx, rcx
    jz 5f
    mov eax, [r13 + CD_dest]
    cmp rax, rcx
    jae 5f
    imul rax, rax, CDD_SIZE
    add rax, [r13 + CD_dests + VEC_ptr]
    mov rsi, [rax + CDD_id]
5:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_folded]
    call sb_push_cstr
    xor esi, esi
    test dword ptr [r13 + CD_flags], CDF_FOLDED
    setnz sil
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_keys]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    call has_keys
    mov esi, eax
    mov rdi, rbx
    call sb_push_u64
    mov rdi, r13                # the focused control's place at the width it was drawn at
    mov esi, [r13 + CD_lastw]
    test esi, esi
    jnz 51f
    mov esi, 400
51: call kind_layout
    mov rdi, rbx
    lea rsi, [rip + .Ld_scroll]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + CD_scroll]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_room]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + CD_room]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_fy]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + foc_y]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_fh]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + foc_h]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, r13
    mov esi, 24
    call kind_fn
    test rax, rax
    jz 6f
    mov rdi, rbx
    mov rsi, r13
    call rax
6:  mov rdi, r12
    call agentcard_waiting
    mov rdx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lw_waiting]
    call push_line
9:  EPILOGUE

# dest_btn(CD*) -> eax 1 when one of its buttons ends with the place (CDBF_DEST)
dest_btn:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, [rdi + CD_btns + VEC_len]
    jae 9f
    imul rdx, rcx, CDB_SIZE
    add rdx, [rdi + CD_btns + VEC_ptr]
    inc rcx
    test dword ptr [rdx + CDB_flags], CDBF_DEST
    jz 1b
    mov eax, 1
9:  ret

# bc_dump(sb, CD*): the button card's lines: hint, detail, edit, desc, note, details, button N LABEL (the
#   place as [LABEL]), extra, field
bc_dump:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rsi, [rip + .Lw_hint]
    mov rdx, [r12 + CD_hint]
    call push_paras
    mov rdi, rbx
    lea rsi, [rip + .Lw_detail]
    mov rdx, [r12 + CD_detail]
    call push_paras
    test dword ptr [r12 + CD_flags], CDF_EDIT
    jz 1f
    mov rdi, rbx
    lea rsi, [rip + .Lw_edit]
    lea rdx, [r12 + CD_edit]
    call push_tf
1:  mov rdi, rbx
    lea rsi, [rip + .Lw_desc]
    mov rdx, [r12 + CD_desc]
    call push_paras
    mov rdi, rbx
    lea rsi, [rip + .Lw_note]
    mov rdx, [r12 + CD_note]
    call push_paras
    cmp qword ptr [r12 + CD_json], 0
    je 2f
    mov rdi, rbx
    lea rsi, [rip + .Lw_details]
    call sb_push_cstr
    xor esi, esi
    test dword ptr [r12 + CD_flags], CDF_JSON
    setnz sil
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
2:  xor r13d, r13d
3:  cmp r13, [r12 + CD_btns + VEC_len]
    jae 6f
    mov rax, [r12 + CD_btns + VEC_ptr]  # plan review: only the buttons shown, by their numbers there
    imul rcx, r13, CDB_SIZE
    test dword ptr [rax + rcx + CDB_flags], CDBF_HIDE
    jnz 55f
    mov rdi, r12
    mov esi, r13d
    call compose
    mov r14, rax
    mov r15, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lw_button]
    call sb_push_cstr
    mov rdi, r12
    mov esi, r13d
    call btn_ord
    lea esi, [rax + 1]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    lea rax, [rip + ldest]
    movsxd rdx, dword ptr [rax + r13*4]
    test rdx, rdx
    jns 4f
    mov rdx, r15
4:  mov [rsp], rdx
    mov rdi, rbx
    mov rsi, r14
    call sb_push
    mov rdx, [rsp]
    cmp rdx, r15
    jae 5f
    mov rdi, rbx
    mov esi, '['
    call sb_push_byte
    mov rdx, [rsp]
    mov rdi, rbx
    lea rsi, [r14 + rdx]
    neg rdx
    add rdx, r15
    call sb_push
    mov rdi, rbx
    mov esi, ']'
    call sb_push_byte
5:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, r12                # its lines
    mov esi, r13d
    call btn_act
    cmp eax, CBA_RULE
    jne 55f
    xor r14d, r14d
51: cmp r14, [r12 + CD_extra + VEC_len]
    jae 55f
    mov rax, [r12 + CD_extra + VEC_ptr]
    mov rdx, [rax + r14*8]
    mov rdi, rbx
    lea rsi, [rip + .Lw_extra]
    call push_line
    inc r14
    jmp 51b
55: inc r13
    jmp 3b
6:  mov rdi, rbx
    lea rsi, [rip + .Lw_field]
    lea rdx, [r12 + CD_field]
    call push_tf
    EPILOGUE

# FN agentcard_input_line(sb, AS*) -> eax 1 when the session has a card: "card=TITLE[ DETAIL] options=A|B"
#   (DETAIL the command's first line, else the detail's; the labels with their places)
FN agentcard_input_line
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    call agentcard_of
    test rax, rax
    jz 8f
    mov r12, rax
    cmp dword ptr [r12 + CD_kind], CDK_QUESTIONS
    jne 0f
    mov rdi, rbx                # the question card: the question shown and its rows
    mov rsi, r12
    call qc_input
    mov eax, 1
    EPILOGUE
0:  mov rdi, rbx
    lea rsi, [rip + .Ld_card]
    call sb_push_cstr
    mov rsi, [r12 + CD_title]
    test rsi, rsi
    jz 1f
    mov rdi, rbx
    call sb_push_cstr
1:  mov r13, [r12 + CD_detail]
    xor r14d, r14d
    test dword ptr [r12 + CD_flags], CDF_EDIT
    jz 11f
    mov r13, [r12 + CD_edit + TF_sb + SB_ptr]
    mov r14, [r12 + CD_edit + TF_sb + SB_len]
    jmp 12f
11: test r13, r13
    jz 3f
    mov rdi, r13
    call strlen
    mov r14, rax
12: xor ecx, ecx                # its first line
2:  cmp rcx, r14
    jae 21f
    cmp byte ptr [r13 + rcx], 10
    je 21f
    inc rcx
    jmp 2b
21: test rcx, rcx
    jz 3f
    mov [rsp], rcx
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    mov rdx, [rsp]
    call sb_push
3:  mov rdi, rbx
    lea rsi, [rip + .Ld_options]
    call sb_push_cstr
    xor r13d, r13d
    xor r14d, r14d              # labels written
4:  cmp r13, [r12 + CD_btns + VEC_len]
    jae 5f
    mov rax, [r12 + CD_btns + VEC_ptr]  # plan review: only the buttons shown (CDBF_HIDE)
    imul rcx, r13, CDB_SIZE
    test dword ptr [rax + rcx + CDB_flags], CDBF_HIDE
    jnz 42f
    test r14, r14
    jz 41f
    mov rdi, rbx
    mov esi, '|'
    call sb_push_byte
41: mov rdi, r12
    mov esi, r13d
    call compose
    mov rdi, rbx
    mov rsi, rax
    call sb_push
    inc r14
42: inc r13
    jmp 4b
5:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentcard_fit_dump(sb): print-agent-card-fit: the open conversation's card at every panel size 8 to
#   32 and width 240 to 900 in steps of 20, a line each: "size=S w=W h=H frame=X,Y,W,H items=K:X,Y,W,H;..."
#   (K: t a text line, f the fold button, e the command, b a button, l a line of a button's label (with
#   its button's number: l2), F the field, d Details; the question card's T a tab, x its ×, o a row, k a
#   line in a row (with the row's number), p the preview). The setting is the user's again after it
FN agentcard_fit_dump
    PROLOGUE 32
    mov rbx, rdi
    mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    call agents_open_driven
    mov rdi, rax
    call agentcard_of
    test rax, rax
    jz 9f
    mov r15, rax
    mov r12d, 8
1:  cmp r12d, 32
    ja 8f
    mov [rip + cfg_agents_font_size], r12d
    call agents_metrics
    mov r13d, 240
2:  cmp r13d, 900
    ja 7f
    mov rdi, r15
    mov esi, r13d
    call kind_layout
    mov r14d, eax
    mov rdi, rbx
    lea rsi, [rip + .Lbd_size]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_w]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_h]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r14d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_frame]
    call sb_push_cstr
    PM esi, MI_8
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    PM esi, MI_6
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov esi, r13d
    sub esi, [rip + g_pmt + 4*MI_8]
    sub esi, [rip + g_pmt + 4*MI_8]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov esi, r14d
    sub esi, [rip + g_pmt + 4*MI_8]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_items]
    call sb_push_cstr
    mov dword ptr [rsp + 4], 0
3:  mov ecx, [rsp + 4]
    cmp ecx, [rip + nlis]
    jae 6f
    imul eax, ecx, LI_SIZE
    lea rcx, [rip + lis]
    add rcx, rax
    mov [rsp + 8], rcx
    mov eax, [rcx + LI_kind]
    lea rdx, [rip + item_letters]
    movzx esi, byte ptr [rdx + rax]
    mov rdi, rbx
    call sb_push_byte
    mov rcx, [rsp + 8]
    cmp dword ptr [rcx + LI_kind], LK_BLINE
    je 31f
    cmp dword ptr [rcx + LI_kind], LK_BTN
    je 31f
    cmp dword ptr [rcx + LI_kind], LK_TAB       # the question card's tabs, rows and their lines
    je 31f
    cmp dword ptr [rcx + LI_kind], LK_OPT
    je 31f
    cmp dword ptr [rcx + LI_kind], LK_OLINE
    jne 32f
31: mov esi, [rcx + LI_idx]
    and esi, 0xff
    inc esi
    mov rdi, rbx
    call sb_push_u64
32: mov dword ptr [rsp + 16], 0
4:  mov rdi, rbx
    mov esi, ':'
    cmp dword ptr [rsp + 16], 0
    je 41f
    mov esi, ','
41: call sb_push_byte
    mov rcx, [rsp + 8]
    mov edx, [rsp + 16]
    mov esi, [rcx + LI_x + rdx*4]
    mov rdi, rbx
    call sb_push_u64
    inc dword ptr [rsp + 16]
    cmp dword ptr [rsp + 16], 4
    jb 4b
    mov rdi, rbx
    mov esi, ';'
    call sb_push_byte
    inc dword ptr [rsp + 4]
    jmp 3b
6:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add r13d, 20
    jmp 2b
7:  inc r12d
    jmp 1b
8:  mov eax, [rsp]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
9:  EPILOGUE

# ---------------------------------------------------------------- plan review: the plan card's comments
#
# A plan card (CDK_PLAN) takes comments on the plan's text (agentcard_comment, from its tab: mdtab.s).
# Without comments it shows its header "Accept this plan?", the hint "Select text in the preview to add
# comments" and every button but CBA_FEEDBACK; with comments: "Continue planning", "N comment(s) will be
# included as feedback", the list "Comments (N)" (each quote cut to 80 characters and "…", in quotes, the
# comment, and a × "Remove comment" that the keys reach too: Up and Down, then Enter, Space or Delete), and
# only the CBA_FEEDBACK buttons (the extension's webview index.js @5251806, @5662587). Buttons a card does
# not show carry CDBF_HIDE: the layout, the numbers, the keys and the dumps skip them.
#
#   agentcard_comment(CD*, quote ptr, len, text ptr, len) -> eax 1 added (CMT_MAX at most)
#   agentcard_uncomment(CD*, i) -> eax 1 removed (i from 0)

.bss
.p2align 3
qbuf: .zero QBUF * CMT_MAX      # the quotes as shown, one per comment (pc_layout)
cbuf: .zero 32                  # "Comments (N)"
hbuf: .zero 64                  # "N comments will be included as feedback"
pend_unc: .long 0               # a comment's × clicked while drawing (its index + 1)

.text

# FN agentcard_comment(CD*, quote ptr, len, text ptr, len) -> eax 1 when the comment was added (copied)
FN agentcard_comment
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    xor eax, eax
    test rbx, rbx
    jz 9f
    cmp qword ptr [rbx + CD_comments + VEC_len], CMT_MAX
    jae 8f
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov r12, rax
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov r14, rax
    lea rdi, [rbx + CD_comments]
    mov esi, CDC_SIZE
    call vec_push
    mov [rax + CDC_quote], r12
    mov [rax + CDC_text], r14
    mov rdi, rbx
    call vis_set
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agentcard_uncomment(CD*, i) -> eax 1 when comment i (from 0) was removed; a focus on a × that went
#   moves to the one before, the last button shown when none is left
FN agentcard_uncomment
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor eax, eax
    test rbx, rbx
    jz 9f
    test r12d, r12d
    js 9f
    movsxd r12, r12d
    cmp r12, [rbx + CD_comments + VEC_len]
    jae 9f
    imul r13, r12, CDC_SIZE
    add r13, [rbx + CD_comments + VEC_ptr]
    mov rdi, [r13 + CDC_quote]
    call mem_free
    mov rdi, [r13 + CDC_text]
    call mem_free
    mov rdx, [rbx + CD_comments + VEC_len]      # the ones after it close up
    sub rdx, r12
    dec rdx
    shl rdx, 4
    mov rdi, r13
    lea rsi, [r13 + CDC_SIZE]
    call memmove
    dec qword ptr [rbx + CD_comments + VEC_len]
    mov eax, [rbx + CD_focus]
    cmp eax, CD_UNC
    jg 2f
    mov ecx, CD_UNC             # a ×: the same place, else the last one
    sub ecx, eax
    movsxd rcx, ecx
    cmp rcx, [rbx + CD_comments + VEC_len]
    jb 2f
    mov rcx, [rbx + CD_comments + VEC_len]
    test rcx, rcx
    jz 1f
    mov eax, CD_UNC + 1
    sub eax, ecx
    mov [rbx + CD_focus], eax
    jmp 2f
1:  mov dword ptr [rbx + CD_focus], 0
2:  mov rdi, rbx
    call vis_set
    and dword ptr [rbx + CD_flags], ~CDF_WHEEL
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# comments_free(CD*): its comments' texts
comments_free:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + CD_comments + VEC_len]
    jae 9f
    imul r13, r12, CDC_SIZE
    add r13, [rbx + CD_comments + VEC_ptr]
    mov rdi, [r13 + CDC_quote]
    call mem_free
    mov rdi, [r13 + CDC_text]
    call mem_free
    inc r12
    jmp 1b
9:  EPILOGUE

# vis_set(CD*): a plan card's header, hint and buttons for its comments (see above); a focus on a button
#   it no longer shows moves to the first one shown
vis_set:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + CD_kind], CDK_PLAN
    jne 9f
    mov r12, [rbx + CD_comments + VEC_len]
    xor r13d, r13d
1:  cmp r13, [rbx + CD_btns + VEC_len]
    jae 3f
    imul rax, r13, CDB_SIZE
    add rax, [rbx + CD_btns + VEC_ptr]
    and dword ptr [rax + CDB_flags], ~CDBF_HIDE
    xor ecx, ecx
    cmp dword ptr [rax + CDB_act], CBA_FEEDBACK
    sete cl                     # 1: a feedback button
    xor edx, edx
    test r12, r12
    setnz dl                    # 1: comments
    cmp ecx, edx
    je 2f
    or dword ptr [rax + CDB_flags], CDBF_HIDE
2:  inc r13
    jmp 1b
3:  test r12, r12               # the header and the hint
    jnz 4f
    lea rdi, [rip + .Lpc_title]
    lea rsi, [rip + .Lpc_hint]
    jmp 6f
4:  lea rdi, [rip + hbuf]
    mov rsi, r12
    call fmt_u64
    lea rdi, [rip + hbuf]
    add rdi, rax
    lea rsi, [rip + .Lpc_one]
    cmp r12, 1
    je 5f
    lea rsi, [rip + .Lpc_many]
5:  call cstr_copy
    lea rdi, [rip + .Lpc_continue]
    lea rsi, [rip + hbuf]
6:  mov r13, rsi
    mov r14, rdi
    call strlen
    mov rdi, rbx
    mov esi, CDT_TITLE
    mov rdx, r14
    mov rcx, rax
    call agentcard_text
    mov rdi, r13
    call strlen
    mov rdi, rbx
    mov esi, CDT_HINT
    mov rdx, r13
    mov rcx, rax
    call agentcard_text
    mov eax, [rbx + CD_focus]   # the focus on a button not shown: the first one shown
    test eax, eax
    js 9f
    movsxd rax, eax
    cmp rax, [rbx + CD_btns + VEC_len]
    jae 7f
    imul rcx, rax, CDB_SIZE
    add rcx, [rbx + CD_btns + VEC_ptr]
    test dword ptr [rcx + CDB_flags], CDBF_HIDE
    jz 9f
7:  mov rdi, rbx
    xor esi, esi
    call btn_nth
    test rax, rax
    jns 8f
    xor eax, eax
8:  mov [rbx + CD_focus], eax
9:  EPILOGUE

# btn_ord(CD*, i) -> eax how many buttons before i show (its number from 0 among them); changes rax, rcx,
#   rdx, r8 only
btn_ord:
    xor eax, eax
    xor ecx, ecx
    movsxd rsi, esi
1:  cmp rcx, rsi
    jae 9f
    cmp rcx, [rdi + CD_btns + VEC_len]
    jae 9f
    imul rdx, rcx, CDB_SIZE
    add rdx, [rdi + CD_btns + VEC_ptr]
    inc rcx
    test dword ptr [rdx + CDB_flags], CDBF_HIDE
    jnz 1b
    inc eax
    jmp 1b
9:  ret

# btn_nth(CD*, n) -> rax the index of the button shown n-th (from 0), -1 none; edx how many show
btn_nth:
    mov rax, -1
    xor edx, edx
    xor ecx, ecx
1:  cmp rcx, [rdi + CD_btns + VEC_len]
    jae 9f
    imul r8, rcx, CDB_SIZE
    add r8, [rdi + CD_btns + VEC_ptr]
    test dword ptr [r8 + CDB_flags], CDBF_HIDE
    jnz 2f
    cmp edx, esi
    jne 11f
    mov rax, rcx
11: inc edx
2:  inc rcx
    jmp 1b
9:  ret

# btn_last(CD*) -> rax the index of the last button shown, -1 none
btn_last:
    mov rax, -1
    xor ecx, ecx
1:  cmp rcx, [rdi + CD_btns + VEC_len]
    jae 9f
    imul rdx, rcx, CDB_SIZE
    add rdx, [rdi + CD_btns + VEC_ptr]
    test dword ptr [rdx + CDB_flags], CDBF_HIDE
    jnz 2f
    mov rax, rcx
2:  inc rcx
    jmp 1b
9:  ret

# quote_shown(dst, quote cstr) -> rax its length: the quote in quotes, cut to QUOTE_CHARS characters
#   and "…"
quote_shown:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov byte ptr [rbx], '"'
    mov r13d, 1                 # bytes written
    xor r14d, r14d              # characters
1:  movzx eax, byte ptr [r12]
    test eax, eax
    jz 3f
    mov ecx, eax
    and ecx, 0xc0
    cmp ecx, 0x80
    je 2f
    cmp r14d, QUOTE_CHARS       # a new character past the last kept: "…"
    jae 21f
    inc r14d
2:  cmp r13d, QBUF - 8
    jae 21f
    mov [rbx + r13], al
    inc r13d
    inc r12
    jmp 1b
21: lea rsi, [rip + .Lpc_ellipsis]
    lea rdi, [rbx + r13]
    call cstr_copy
    add r13d, 3
3:  mov byte ptr [rbx + r13], '"'
    inc r13d
    mov byte ptr [rbx + r13], 0
    mov eax, r13d
    EPILOGUE

# pc_layout(CD*): bc_layout's part: under the hint "Comments (N)", then each comment's quote and text,
#   its × at the right of its first line (a focus stop); nothing without comments
pc_layout:
    PROLOGUE 16
    mov rbx, rdi
    cmp qword ptr [rbx + CD_comments + VEC_len], 0
    je 9f
    mov eax, [rip + g_pmt + 4*MI_4]
    add [rip + ly], eax
    lea rdi, [rip + cbuf]
    lea rsi, [rip + .Lpc_list]
    call cstr_copy
    mov r12, rax
    mov rdi, rax
    mov rsi, [rbx + CD_comments + VEC_len]
    call fmt_u64
    add r12, rax
    mov byte ptr [r12], ')'
    mov byte ptr [r12 + 1], 0
    lea rdi, [rip + cbuf]
    mov esi, TS_MUTED
    mov edx, 1
    call lay_cstr
    mov eax, [rip + lw]
    mov [rsp], eax              # the content's width, kept
    xor r12d, r12d
1:  cmp r12, [rbx + CD_comments + VEC_len]
    jae 8f
    mov edi, TS_SMALL           # the ×: a square of a small line's height
    call st_lineh
    mov r13d, eax
    mov edi, LK_UNC
    mov esi, r12d
    call li_new
    mov ecx, [rip + lx]
    add ecx, [rsp]
    sub ecx, r13d
    mov [rax + LI_x], ecx
    mov ecx, [rip + ly]
    mov [rax + LI_y], ecx
    mov [rax + LI_w], r13d
    mov [rax + LI_h], r13d
    mov edi, CD_UNC
    sub edi, r12d
    call stop_add
    mov eax, CD_UNC
    sub eax, r12d
    cmp eax, [rbx + CD_focus]
    jne 2f
    mov edi, [rip + ly]
    mov esi, r13d
    call set_focus_rect
2:  mov eax, [rip + ly]
    add eax, r13d
    mov [rsp + 4], eax          # the ×'s bottom
    mov eax, [rsp]              # the texts beside it
    sub eax, r13d
    sub eax, [rip + g_pmt + 4*MI_4]
    cmp eax, 16
    jge 3f
    mov eax, 16
3:  mov [rip + lw], eax
    imul r14, r12, CDC_SIZE
    add r14, [rbx + CD_comments + VEC_ptr]
    imul rdi, r12, QBUF
    lea rax, [rip + qbuf]
    add rdi, rax
    mov r15, rdi
    mov rsi, [r14 + CDC_quote]
    call quote_shown
    mov rdi, r15
    mov rsi, rax
    mov edx, TS_MUTED
    mov ecx, QUOTE_LINES
    call lay_text
    mov rdi, [r14 + CDC_text]
    mov esi, TS_BODY
    mov edx, COMMENT_LINES
    call lay_paras
    mov eax, [rsp]
    mov [rip + lw], eax
    mov eax, [rsp + 4]
    cmp [rip + ly], eax
    jge 4f
    mov [rip + ly], eax
4:  mov eax, [rip + g_pmt + 4*MI_4]
    add [rip + ly], eax
    inc r12
    jmp 1b
8:  mov eax, [rip + g_pmt + 4*MI_4]
    add [rip + ly], eax
9:  EPILOGUE

# .Lbd_unc: bc_draw's part (its frame: [rsp] x, +4 y, +20 live, +24 keys, +32 a scratch; r12 the card, r15
#   the item): a comment's ×, its tooltip; a click (once the lock is over) removes it after the drawing
.Lbd_unc:
    mov eax, CD_UNC
    sub eax, [r15 + LI_idx]
    cmp eax, [r12 + CD_focus]
    jne 1f
    cmp dword ptr [rsp + 24], 0
    je 1f
    COLOR eax, T_HOVER          # focused: ringed
    push rax
    push rax
    mov edi, [rsp + 16]
    add edi, [r15 + LI_x]
    mov esi, [rsp + 16 + 4]
    add esi, [r15 + LI_y]
    mov edx, [r15 + LI_w]
    mov ecx, [r15 + LI_h]
    PM r8d, MI_RADIUS
    COLOR r9d, T_ACCENT
    call gfx_frame
    add rsp, 16
1:  mov eax, [r15 + LI_idx]
    lea edi, [rax + ID_AGCARD + CID_UNC]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_w]
    mov r8d, [r15 + LI_h]
    mov r9d, IC_CLOSE
    call ag_icon_btn
    mov [rsp + 32], eax
    mov eax, [r15 + LI_idx]
    lea edi, [rax + ID_AGCARD + CID_UNC]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    add edx, [r15 + LI_h]
    mov ecx, [r15 + LI_w]
    mov r8d, [rsp + 32]
    lea r9, [rip + .Lpc_remove]
    call tip_note_text
    test dword ptr [rsp + 32], UB_CLICK
    jz .Lbd_item
    cmp dword ptr [rsp + 20], 0
    je .Lbd_item
    mov eax, [r15 + LI_idx]
    inc eax
    mov [rip + pend_unc], eax
    jmp .Lbd_item

# pc_key(AS*, CD*, keysym, cp, mods) -> eax 1 taken: on a comment's × Enter, Space and Delete remove it;
#   every other key is the button card's (bc_key)
pc_key:
    mov eax, [rsi + CD_focus]
    cmp eax, CD_UNC
    jg bc_key
    test r8d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz bc_key
    cmp edx, KEY_RETURN
    je 1f
    cmp edx, KEY_KP_ENTER
    je 1f
    cmp edx, ' '
    je 1f
    cmp edx, KEY_DELETE
    jne bc_key
1:  PROLOGUE
    mov rbx, rsi
    mov rdi, rsi
    call agentcard_live
    test eax, eax
    jz 9f                       # locked: the key is swallowed
    mov ecx, CD_UNC
    sub ecx, [rbx + CD_focus]
    mov rdi, rbx
    mov esi, ecx
    call agentcard_uncomment
9:  mov eax, 1
    EPILOGUE

# dump_focus(sb, CD*): print-agent-card's focus: a button's number among those shown, "xN" for comment N's ×
dump_focus:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + CD_focus]
    cmp eax, CD_UNC
    jg 1f
    mov esi, 'x'
    call sb_push_byte
    mov esi, CD_UNC + 1
    sub esi, [r12 + CD_focus]
    mov rdi, rbx
    call sb_push_u64
    EPILOGUE
1:  mov rdi, r12
    mov esi, eax
    call btn_ord
    lea esi, [rax + 1]
    mov rdi, rbx
    call sb_push_u64
    EPILOGUE

# pc_dump(sb, CD*): bc_dump's lines, then "comment N "QUOTE" TEXT" per comment (line feeds as "\n")
pc_dump:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call bc_dump
    xor r13d, r13d
1:  cmp r13, [r12 + CD_comments + VEC_len]
    jae 9f
    imul r14, r13, CDC_SIZE
    add r14, [r12 + CD_comments + VEC_ptr]
    mov rdi, rbx
    lea rsi, [rip + .Lpc_dump]
    call sb_push_cstr
    lea esi, [r13 + 1]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lpc_open]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + CDC_quote]
    call push_esc_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lpc_close]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + CDC_text]
    call push_esc_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r13
    jmp 1b
9:  EPILOGUE

# push_esc_cstr(sb, cstr): its bytes, a line feed as "\n"
push_esc_cstr:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
1:  movzx esi, byte ptr [r12]
    test esi, esi
    jz 9f
    inc r12
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

.section .rodata
.Lpc_title: .asciz "Accept this plan?"
.Lpc_hint: .asciz "Select text in the preview to add comments"
.Lpc_continue: .asciz "Continue planning"
.Lpc_one: .asciz " comment will be included as feedback"
.Lpc_many: .asciz " comments will be included as feedback"
.Lpc_list: .asciz "Comments ("
.Lpc_remove: .asciz "Remove comment"
.Lpc_ellipsis: .asciz "\342\200\246"
.Lpc_dump: .asciz "comment "
.Lpc_open: .asciz " \""
.Lpc_close: .asciz "\" "

.section .rodata
.p2align 3
# the kinds: measure, draw, key, dump (by CD_kind from 1)
kinds:
    .quad bc_h, bc_draw, bc_key, bc_dump        # CDK_PERMISSION
    .quad qc_layout, qc_draw, qc_key, qc_dump   # CDK_QUESTIONS: the question card
    .quad bc_h, bc_draw, pc_key, pc_dump        # CDK_PLAN (plan review: its comments)
    .quad bc_h, bc_draw, bc_key, bc_dump        # CDK_DIALOG
# the text styles: the face's variable, its colour's theme slot, the line's leading (a metric)
style_tbl:
    .quad ag_fui
    .long T_FG, MI_6            # TS_TITLE
    .quad ag_fui
    .long T_FG, MI_4            # TS_BODY
    .quad ag_fsmall
    .long T_MUTED, MI_4         # TS_MUTED
    .quad ag_fsmall
    .long T_FG, MI_4            # TS_SMALL
    .quad ag_fsmall
    .long T_FG, MI_2            # TS_CODE
    .quad ag_fsmall
    .long T_ACCENT, MI_6        # TS_LINK
kind_names: .quad .Lk_permission, .Lk_questions, .Lk_plan, .Lk_dialog
# agentcard_text's fields (CDT_*): their CD offsets (-1: CDT_EDIT has none)
.p2align 2
text_slots: .long CD_title, CD_hint, CD_detail, CD_desc, CD_note, CD_json, CD_link, -1, CD_ph
item_letters: .byte '?', 't', 'f', 'e', 'b', 'l', 'F', 'd', 'x'    # (x: plan review's ×)
    .byte '?', '?', '?', '?', '?', '?', '?', 'T', 'x', 'o', 'k', 'p'     # 9..15 unused; the question card's
.Lk_permission: .asciz "permission"
.Lk_questions: .asciz "questions"
.Lk_plan: .asciz "plan"
.Lk_dialog: .asciz "dialog"
.Lhook: .asciz "A hook says:"
.Lesc: .asciz "Esc to cancel"
.Ldigit: .asciz "8"
.Ltip_arrows: .asciz "Left or Right arrow changes where this is saved"
.Ldetails_shut: .asciz "Details \342\226\270"
.Ldetails_open: .asciz "Details \342\226\276"
.Lwaiting: .asciz "Waiting for permission\342\200\246"
.Ldash: .asciz "-"
.Ld_kind: .asciz "kind="
.Ld_title: .asciz " title="
.Ld_live: .asciz " live="
.Ld_focus: .asciz " focus="
.Ld_dest: .asciz " dest="
.Ld_folded: .asciz " folded="
.Ld_keys: .asciz " keys="
.Ld_scroll: .asciz " scroll="
.Ld_room: .asciz " room="
.Ld_fy: .asciz " fy="
.Ld_fh: .asciz " fh="
.Ld_card: .asciz "card="
.Ld_options: .asciz " options="
.Lw_field: .asciz "field"
.Lw_edit: .asciz "edit"
.Lw_hint: .asciz "hint"
.Lw_detail: .asciz "detail"
.Lw_desc: .asciz "desc"
.Lw_note: .asciz "note"
.Lw_details: .asciz "details "
.Lw_button: .asciz "button "
.Lw_extra: .asciz "extra"
.Lw_waiting: .asciz "waiting"
.Lbd_size: .asciz "size="
.Lbd_w: .asciz " w="
.Lbd_h: .asciz " h="
.Lbd_frame: .asciz " frame="
.Lbd_items: .asciz " items="

.bss
num: .byte 0, 0

# ---------------------------------------------------------------- the question card
#
# A CDK_QUESTIONS card (ext-webview-ui.md 4.12, 4.13; webview index.js `w8n` @5236200, its previews @5241123):
#   a tab per question (its header; an answered one with a check) with the fold button and a × (the card's
#   No) at the right; the question shown (CD_tab); its options as radio rows (a single choice) or checkbox
#   rows (multiSelect), each its label and description, then "Other", whose field ("Type your answer…",
#   CDQ_other) shows while it is picked; when an option of a single-choice question has a preview, the
#   preview of the row the keyboard is on (CDQ_sel) as Markdown at the panel's size, compact, headed
#   "Preview: LABEL" ("No preview for this option" without one), beside the rows on a card QC_BESIDE_W
#   wide or more, else under them (its body as tall as the tallest of the question's previews, 3 to 16
#   lines, so it does not jump); "1 Submit answers", enabled once every question has an answer; "Esc to
#   cancel".
#   A single choice moves to the next question after g_card_advance_ms (not from the last; one move at a
#   time); Other on a single choice clears the label picked, a label clears Other (its text is kept). An
#   answer is the labels picked in their order, joined with ", ", then Other's text ("Other" while its
#   field is empty: the extension's rule); a blank one is no answer.
#   Keys (while it has the keyboard): Left and Right the questions (from the rows); Up and Down round the
#   rows, Other's field (while Other is picked) and Submit answers; Space or Enter picks the row (on Submit
#   answers: submits); 1 submits; Escape is No; in Other's field Enter goes to the next question, Up and
#   Down (no line feed in it) leave it, Escape is No, other keys are the field's. Clicks as keys; the tabs
#   and the fold button work during the lock, the rest after it.
#   CD_focus: CD_OPTS (the rows: the row is CDQ_sel), CD_FIELD (Other's field), 0 (Submit answers).
#
#   agentcard_question(CD*, header cstr, text cstr, multi) -> rax CDQ* (copied; 0 past CDQ_MAX)
#   agentcard_option(CDQ*, label cstr, desc cstr, preview ptr, len)    (copied; past CDQ_OPTS_MAX nothing)
#   agentcard_qtext(CDQ*, sb) -> eax 1 when the answer it appends to sb is not blank
#   g_card_advance_ms                         agent-timing advance=

.text

# FN agentcard_question(CD*, header, text, multi) -> rax a new question of the card (0 past CDQ_MAX)
FN agentcard_question
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    xor eax, eax
    cmp qword ptr [rbx + CD_qs + VEC_len], CDQ_MAX
    jae 9f
    mov edi, CDQ_SIZE
    call mem_alloc
    mov r15, rax
    mov rdi, rax
    xor esi, esi
    mov edx, CDQ_SIZE
    call memset
    mov dword ptr [r15 + CDQ_other + TF_prefx], -1
    mov [r15 + CDQ_multi], r14d
    mov rdi, r12
    call q_dup
    mov [r15 + CDQ_header], rax
    mov rdi, r13
    call q_dup
    mov [r15 + CDQ_text], rax
    lea rdi, [rbx + CD_qs]
    mov esi, 8
    call vec_push
    mov [rax], r15
    mov rax, r15
9:  EPILOGUE

# q_dup(cstr or 0) -> rax its copy ("" for 0)
q_dup:
    push rbx
    lea rax, [rip + .Lq_empty]
    test rdi, rdi
    cmovz rdi, rax
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    pop rbx
    jmp mem_dup

# FN agentcard_option(CDQ*, label, desc, preview ptr, len): an option of the question; a preview that is not
#   blank becomes its Markdown (q_fence)
FN agentcard_option
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    cmp qword ptr [rbx + CDQ_opts + VEC_len], CDQ_OPTS_MAX
    jae 9f
    lea rdi, [rbx + CDQ_opts]
    mov esi, CDO_SIZE
    call vec_push
    mov rbx, rax
    mov qword ptr [rbx + CDO_preview], 0
    mov rdi, r12
    call q_dup
    mov [rbx + CDO_label], rax
    mov rdi, r13
    call q_dup
    mov [rbx + CDO_desc], rax
    mov rdi, r14
    mov rsi, r15
    call q_fence
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call md_new
    mov [rbx + CDO_preview], rax
    mov rdi, rax
    mov esi, 1
    call md_set_compact
9:  EPILOGUE

# q_fence(ptr, len) -> rax ptr, rdx len (in fsb): a preview as the extension shows it (`_8n` @5232059): its
#   trailing line feeds cut, then in a fence of one backtick more than its longest run of them (3 at least)
#   marked "text", unless a line of it opens a fence of its own (up to 3 spaces, 3 backticks or more, no
#   backtick after them); rax 0 for a blank one (it has none)
q_fence:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ecx, ecx
1:  cmp rcx, r13
    jae 8f
    movzx eax, byte ptr [r12 + rcx]
    inc rcx
    cmp eax, ' '
    je 1b
    cmp eax, 9
    je 1b
    cmp eax, 10
    je 1b
    cmp eax, 13
    je 1b
2:  cmp byte ptr [r12 + r13 - 1], 10
    jne 3f
    dec r13
    jmp 2b
3:  xor r14d, r14d              # its longest run of backticks
    xor ecx, ecx
    xor edx, edx
31: cmp rcx, r13
    jae 4f
    cmp byte ptr [r12 + rcx], '`'
    jne 32f
    inc edx
    cmp edx, r14d
    cmova r14d, edx
    jmp 33f
32: xor edx, edx
33: inc rcx
    jmp 31b
4:  xor ebx, ebx                # a line's start
41: cmp rbx, r13
    jae 7f
    mov rcx, rbx
    xor edx, edx
42: cmp rcx, r13
    jae 46f
    cmp byte ptr [r12 + rcx], ' '
    jne 43f
    cmp edx, 3
    jae 46f
    inc edx
    inc rcx
    jmp 42b
43: mov rsi, rcx
44: cmp rcx, r13
    jae 45f
    cmp byte ptr [r12 + rcx], '`'
    jne 45f
    inc rcx
    jmp 44b
45: mov rax, rcx
    sub rax, rsi
    cmp rax, 3
    jb 46f
451:cmp rcx, r13
    jae 6f
    movzx eax, byte ptr [r12 + rcx]
    cmp eax, 10
    je 6f
    cmp eax, '`'
    je 46f
    inc rcx
    jmp 451b
46: cmp rcx, r13                # on to the next line
    jae 7f
    cmp byte ptr [r12 + rcx], 10
    je 47f
    inc rcx
    jmp 46b
47: lea rbx, [rcx + 1]
    jmp 41b
6:  lea rdi, [rip + fsb]        # as it is
    call sb_clear
    lea rdi, [rip + fsb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    jmp 79f
7:  cmp r14d, 2
    jge 71f
    mov r14d, 2
71: inc r14d
    lea rdi, [rip + fsb]
    call sb_clear
    mov edi, r14d
    call q_ticks
    lea rdi, [rip + fsb]
    lea rsi, [rip + .Lq_text_lf]
    call sb_push_cstr
    lea rdi, [rip + fsb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + fsb]
    mov esi, 10
    call sb_push_byte
    mov edi, r14d
    call q_ticks
79: mov rax, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# q_ticks(n): n backticks onto fsb
q_ticks:
    push rbx
    mov ebx, edi
1:  test ebx, ebx
    jz 2f
    lea rdi, [rip + fsb]
    mov esi, '`'
    call sb_push_byte
    dec ebx
    jmp 1b
2:  pop rbx
    ret

# qc_free(CD*): its questions and what they own (agentcard_free)
qc_free:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + CD_qs + VEC_len]
    jae 9f
    mov rax, [rbx + CD_qs + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    mov rdi, [r13 + CDQ_header]
    call mem_free
    mov rdi, [r13 + CDQ_text]
    call mem_free
    xor r14d, r14d
2:  cmp r14, [r13 + CDQ_opts + VEC_len]
    jae 3f
    imul r15, r14, CDO_SIZE
    add r15, [r13 + CDQ_opts + VEC_ptr]
    inc r14
    mov rdi, [r15 + CDO_label]
    call mem_free
    mov rdi, [r15 + CDO_desc]
    call mem_free
    mov rdi, [r15 + CDO_preview]
    call md_free
    jmp 2b
3:  lea rdi, [r13 + CDQ_opts]
    call vec_free
    lea rdi, [r13 + CDQ_other + TF_sb]
    call sb_free
    mov rdi, r13
    call mem_free
    jmp 1b
9:  EPILOGUE

# qc_cur(CD*) -> rax the question shown (CDQ*), 0 none
qc_cur:
    xor eax, eax
    mov ecx, [rdi + CD_tab]
    cmp rcx, [rdi + CD_qs + VEC_len]
    jae 1f
    mov rax, [rdi + CD_qs + VEC_ptr]
    mov rax, [rax + rcx*8]
1:  ret

# qc_answered(CDQ*) -> eax 1 when a row of it is picked (its tab's check)
qc_answered:
    xor eax, eax
    cmp dword ptr [rdi + CDQ_picks], 0
    jne 1f
    cmp dword ptr [rdi + CDQ_otheron], 0
    je 2f
1:  mov eax, 1
2:  ret

# qc_opt(CDQ*, row) -> rax the row's option (CDO*), 0 for Other (the row past them)
qc_opt:
    xor eax, eax
    mov esi, esi
    cmp rsi, [rdi + CDQ_opts + VEC_len]
    jae 1f
    imul rax, rsi, CDO_SIZE
    add rax, [rdi + CDQ_opts + VEC_ptr]
1:  ret

# qc_label(CDQ*, row) -> rax the row's label ("Other" for the last)
qc_label:
    call qc_opt
    test rax, rax
    jz 1f
    mov rax, [rax + CDO_label]
    ret
1:  lea rax, [rip + .Lq_other]
    ret

# qc_picked(CDQ*, row) -> eax 1 when the row is picked
qc_picked:
    xor eax, eax
    mov esi, esi
    cmp rsi, [rdi + CDQ_opts + VEC_len]
    jb 1f
    jne 2f
    cmp dword ptr [rdi + CDQ_otheron], 0
    setne al
    ret
1:  mov edx, [rdi + CDQ_picks]
    bt edx, esi
    setc al
2:  ret

# qc_has_preview(CDQ*) -> eax 1 for a single choice with an option that has a preview
qc_has_preview:
    xor eax, eax
    cmp dword ptr [rdi + CDQ_multi], 0
    jne 9f
    mov rcx, [rdi + CDQ_opts + VEC_len]
    mov rdx, [rdi + CDQ_opts + VEC_ptr]
1:  test rcx, rcx
    jz 9f
    cmp qword ptr [rdx + CDO_preview], 0
    jne 2f
    add rdx, CDO_SIZE
    dec rcx
    jmp 1b
2:  mov eax, 1
9:  ret

# FN agentcard_qtext(CDQ*, sb) -> eax 1 when the answer appended to sb is not blank: the labels picked, in
#   their order, joined with ", ", then Other's text ("Other" while it is empty)
FN agentcard_qtext
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [r12 + SB_len]
    xor r14d, r14d
    xor r15d, r15d              # labels so far
1:  cmp r14, [rbx + CDQ_opts + VEC_len]
    jae 3f
    mov eax, [rbx + CDQ_picks]
    bt eax, r14d
    jnc 2f
    test r15d, r15d
    jz 11f
    mov rdi, r12
    lea rsi, [rip + .Lq_comma]
    call sb_push_cstr
11: imul rcx, r14, CDO_SIZE
    add rcx, [rbx + CDQ_opts + VEC_ptr]
    mov rsi, [rcx + CDO_label]
    mov rdi, r12
    call sb_push_cstr
    inc r15d
2:  inc r14
    jmp 1b
3:  cmp dword ptr [rbx + CDQ_otheron], 0
    je 5f
    test r15d, r15d
    jz 31f
    mov rdi, r12
    lea rsi, [rip + .Lq_comma]
    call sb_push_cstr
31: mov rdx, [rbx + CDQ_other + TF_sb + SB_len]
    test rdx, rdx
    jnz 32f
    mov rdi, r12
    lea rsi, [rip + .Lq_other]
    call sb_push_cstr
    jmp 5f
32: mov rdi, r12
    mov rsi, [rbx + CDQ_other + TF_sb + SB_ptr]
    call sb_push
5:  xor eax, eax                # a character but white space in what it appended
    mov rcx, r13
6:  cmp rcx, [r12 + SB_len]
    jae 9f
    mov rdx, [r12 + SB_ptr]
    movzx edx, byte ptr [rdx + rcx]
    inc rcx
    cmp edx, ' '
    je 6b
    cmp edx, 9
    je 6b
    cmp edx, 10
    je 6b
    cmp edx, 13
    je 6b
    mov eax, 1
9:  EPILOGUE

# qc_complete(CD*) -> eax 1 when every question has an answer
qc_complete:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
    cmp qword ptr [rbx + CD_qs + VEC_len], 0
    je 8f
1:  cmp r12, [rbx + CD_qs + VEC_len]
    jae 7f
    lea rdi, [rip + qsb]
    call sb_clear
    mov rax, [rbx + CD_qs + VEC_ptr]
    mov rdi, [rax + r12*8]
    inc r12
    lea rsi, [rip + qsb]
    call agentcard_qtext
    test eax, eax
    jnz 1b
8:  xor eax, eax
    EPILOGUE
7:  mov eax, 1
    EPILOGUE

# qc_tab(CD*, i): question i shows, the keyboard on its first row
qc_tab:
    push rbx
    mov rbx, rdi
    mov [rbx + CD_tab], esi
    mov dword ptr [rbx + CD_focus], CD_OPTS
    and dword ptr [rbx + CD_flags], ~CDF_WHEEL
    call qc_cur
    test rax, rax
    jz 1f
    mov dword ptr [rax + CDQ_sel], 0
1:  mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# qc_pick(CD*, row): the row of the question shown, picked (as Space on it, or a click): a checkbox toggles,
#   a radio is the one picked (and the next question comes after g_card_advance_ms), Other also gives its
#   field the keyboard
qc_pick:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call qc_cur
    test rax, rax
    jz 9f
    mov r13, rax
    cmp r12, [r13 + CDQ_opts + VEC_len]
    ja 9f
    mov [r13 + CDQ_sel], r12d
    mov dword ptr [rbx + CD_focus], CD_OPTS
    and dword ptr [rbx + CD_flags], ~CDF_WHEEL
    cmp r12, [r13 + CDQ_opts + VEC_len]
    jb .Lqp_opt
    cmp dword ptr [r13 + CDQ_multi], 0  # Other
    je 1f
    xor dword ptr [r13 + CDQ_otheron], 1
    jmp 2f
1:  mov dword ptr [r13 + CDQ_picks], 0
    mov dword ptr [r13 + CDQ_otheron], 1
2:  cmp dword ptr [r13 + CDQ_otheron], 0
    je 8f
    mov dword ptr [rbx + CD_focus], CD_FIELD
    jmp 8f
.Lqp_opt:
    mov eax, 1
    mov ecx, r12d
    shl eax, cl
    cmp dword ptr [r13 + CDQ_multi], 0
    je 3f
    xor [r13 + CDQ_picks], eax
    jmp 8f
3:  mov [r13 + CDQ_picks], eax
    mov dword ptr [r13 + CDQ_otheron], 0
    mov eax, [rbx + CD_tab]
    inc eax
    cmp rax, [rbx + CD_qs + VEC_len]
    jae 8f
    cmp qword ptr [rbx + CD_advat], 0
    jne 8f
    mov [rbx + CD_advto], eax
    cmp dword ptr [rip + g_card_advance_ms], 0
    jg 4f
    mov rdi, rbx                # at once
    mov esi, eax
    call qc_tab
    jmp 8f
4:  call time_ms
    movsxd rcx, dword ptr [rip + g_card_advance_ms]
    add rax, rcx
    mov [rbx + CD_advat], rax
8:  mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# qc_advance_due(CD*) -> eax ms until a single choice's move to the next question; 0 when it was just made;
#   -1 none waiting
qc_advance_due:
    PROLOGUE
    mov rbx, rdi
    mov eax, -1
    cmp qword ptr [rbx + CD_advat], 0
    je 9f
    call time_ms
    mov rcx, [rbx + CD_advat]
    sub rcx, rax
    jle 1f
    mov eax, ecx
    EPILOGUE
1:  mov qword ptr [rbx + CD_advat], 0
    mov rdi, rbx
    mov esi, [rbx + CD_advto]
    call qc_tab
    xor eax, eax
9:  EPILOGUE

# qc_step(CD*, dir): the keyboard to the next stop down (1) or up (-1), round: the rows, Other's field
#   (while Other is picked), Submit answers
qc_step:
    push rbx
    mov rbx, rdi
    push rsi
    call qc_cur
    pop rsi
    test rax, rax
    jz 9f
    mov r8, [rax + CDQ_opts + VEC_len]  # the last row (Other)
    xor r9d, r9d
    cmp dword ptr [rax + CDQ_otheron], 0
    setne r9b                   # 1: its field is a stop
    lea r10, [r8 + r9 + 2]      # the stops
    mov ecx, [rbx + CD_focus]
    mov edx, [rax + CDQ_sel]
    cmp ecx, CD_OPTS
    je 1f
    lea rdx, [r8 + 1]
    cmp ecx, CD_FIELD
    je 1f
    lea rdx, [r8 + r9 + 1]
1:  movsxd rsi, esi
    add rdx, rsi
    jns 2f
    add rdx, r10
2:  cmp rdx, r10
    jb 3f
    sub rdx, r10
3:  cmp rdx, r8
    ja 4f
    mov [rax + CDQ_sel], edx
    mov dword ptr [rbx + CD_focus], CD_OPTS
    jmp 8f
4:  lea rcx, [r8 + 1]
    cmp rdx, rcx
    jne 5f
    test r9d, r9d
    jz 5f
    mov dword ptr [rbx + CD_focus], CD_FIELD
    jmp 8f
5:  mov dword ptr [rbx + CD_focus], 0
8:  and dword ptr [rbx + CD_flags], ~CDF_WHEEL
    mov dword ptr [rip + g_dirty], 1
9:  pop rbx
    ret

# qc_set_other(CD*, ptr, len) -> eax 1: Other of the question shown picked with that text, its field with
#   the keyboard (agent-card-text other)
qc_set_other:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call qc_cur
    test rax, rax
    jz 8f
    mov r14, rax
    cmp dword ptr [r14 + CDQ_multi], 0
    jne 1f
    mov dword ptr [r14 + CDQ_picks], 0
1:  mov dword ptr [r14 + CDQ_otheron], 1
    mov rax, [r14 + CDQ_opts + VEC_len]
    mov [r14 + CDQ_sel], eax
    mov dword ptr [rbx + CD_focus], CD_FIELD
    lea rdi, [r14 + CDQ_other]
    mov rsi, r12
    mov rdx, r13
    call tf_set
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# qc_preview_px(CD*): its previews at the panel's text size (when it changed)
qc_preview_px:
    PROLOGUE
    mov rbx, rdi
    mov rax, [rip + ag_fui]
    mov r12d, [rax + FACE_px]
    cmp r12d, [rbx + CD_qpx]
    je 9f
    mov [rbx + CD_qpx], r12d
    xor r13d, r13d
1:  cmp r13, [rbx + CD_qs + VEC_len]
    jae 9f
    mov rax, [rbx + CD_qs + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    xor r15d, r15d
2:  cmp r15, [r14 + CDQ_opts + VEC_len]
    jae 1b
    imul rax, r15, CDO_SIZE
    add rax, [r14 + CDQ_opts + VEC_ptr]
    inc r15
    mov rdi, [rax + CDO_preview]
    test rdi, rdi
    jz 2b
    mov esi, r12d
    call md_set_size
    jmp 2b
9:  EPILOGUE

# qc_body_h(CDQ*, w) -> eax the preview's body at width w: its tallest preview's height, PREVIEW_MIN to
#   PREVIEW_LINES lines of the panel's text
qc_body_h:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    xor r13d, r13d
    xor r14d, r14d
1:  cmp r14, [rbx + CDQ_opts + VEC_len]
    jae 2f
    imul rax, r14, CDO_SIZE
    add rax, [rbx + CDQ_opts + VEC_ptr]
    inc r14
    mov rdi, [rax + CDO_preview]
    test rdi, rdi
    jz 1b
    mov esi, r12d
    call md_layout
    cmp eax, r13d
    cmovg r13d, eax
    jmp 1b
2:  mov rax, [rip + ag_fui]
    mov ecx, [rax + FACE_lineh]
    imul eax, ecx, PREVIEW_MIN
    cmp r13d, eax
    cmovl r13d, eax
    imul eax, ecx, PREVIEW_LINES
    cmp r13d, eax
    cmovg r13d, eax
    mov eax, r13d
    EPILOGUE

# kind_layout(CD*, w) -> eax the card's height at width w, its layout in lis (its kind's measure)
kind_layout:
    push rsi
    xor esi, esi
    call kind_fn
    pop rsi
    test rax, rax
    jz 1f
    jmp rax
1:  ret

# qc_lay_btn(CD*): "Submit answers" (button 0) at lx, ly, lw, its label wrapping as the button card's; ly
#   moves under it. Locals as bc_layout's buttons
qc_lay_btn:
    PROLOGUE 48
    mov rbx, rdi
    xor esi, esi
    call compose
    mov [rsp + 40], rax
    mov [rsp + 8], rdx
    mov rdi, rbx
    call btn_inset
    mov ecx, [rip + lx]
    add ecx, eax
    mov [rsp + 20], ecx
    mov r13d, [rip + lw]
    sub r13d, eax
    sub r13d, [rip + g_pmt + 4*MI_6]
    cmp r13d, 8
    jge 1f
    mov r13d, 8
1:  mov edi, LK_BTN
    xor esi, esi
    call li_new
    mov [rsp + 32], rax
    mov ecx, [rip + lx]
    mov [rax + LI_x], ecx
    mov ecx, [rip + lw]
    mov [rax + LI_w], ecx
    mov ecx, [rip + ly]
    mov [rax + LI_y], ecx
    mov edi, TS_SMALL
    call st_lineh
    mov [rsp + 24], eax
    mov eax, [rip + ly]
    add eax, [rip + g_pmt + 4*MI_6]
    mov [rsp + 28], eax
    xor r15d, r15d
2:  cmp qword ptr [rsp + 8], 0
    je 5f
    cmp r15d, LABEL_LINES
    jae 5f
    inc r15d
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rsp + 40]
    mov rdx, [rsp + 8]
    mov ecx, r13d
    call wrap_one
    mov r12, rdx
    mov rcx, rax
    cmp r15d, LABEL_LINES
    jb 3f
    mov rcx, [rsp + 8]
3:  push rcx
    push rcx
    mov edi, LK_BLINE
    xor esi, esi
    call li_new
    pop rcx
    pop rcx
    mov rdx, [rsp + 40]
    mov [rax + LI_ptr], rdx
    mov [rax + LI_len], rcx
    mov ecx, [rsp + 20]
    mov [rax + LI_x], ecx
    mov [rax + LI_w], r13d
    mov ecx, [rsp + 28]
    mov [rax + LI_y], ecx
    mov ecx, [rsp + 24]
    mov [rax + LI_h], ecx
    add [rsp + 28], ecx
    add [rsp + 40], r12
    sub [rsp + 8], r12
    jmp 2b
5:  mov eax, [rsp + 28]
    sub eax, [rip + ly]
    add eax, [rip + g_pmt + 4*MI_6]
    cmp eax, [rip + g_pmt + 4*MI_32]
    jge 6f
    mov eax, [rip + g_pmt + 4*MI_32]
6:  mov rcx, [rsp + 32]
    mov [rcx + LI_h], eax
    mov r14d, eax
    cmp dword ptr [rbx + CD_focus], 0
    jne 7f
    mov edi, [rip + ly]
    mov esi, r14d
    call set_focus_rect
7:  add [rip + ly], r14d
    mov eax, [rip + g_pmt + 4*MI_6]
    add [rip + ly], eax
    EPILOGUE

# qc_layout(CD*, w) -> eax the question card's height at width w; lis/nlis its items from its top left,
#   foc_y/foc_h the focused control's place. Locals: [rsp] the × and fold buttons' size, +4 the tab row's
#   right end, +8 a tab's height, +12 a tab row's, +16 the next tab's x, +20 its row's y, +24 and +28 lx and
#   lw kept, +32 the rows' width, +36 their top, +40 a mark's size, +44 a row's top, +48 the preview's x,
#   +52 its width, +56 beside, +60 the items before a row's text, +64 a preview, +68 a row's text from its
#   left, +72 the row, +76 Other's field's width
qc_layout:
    PROLOGUE 80
    mov rbx, rdi
    mov r12d, esi
    mov dword ptr [rip + nlis], 0
    mov dword ptr [rip + nstops], 0
    mov dword ptr [rip + foc_y], 0
    mov dword ptr [rip + foc_h], 0
    PM eax, MI_16               # the frame MI_8 in, the content MI_8 in from it (as the button card's)
    mov [rip + lx], eax
    mov eax, r12d
    sub eax, [rip + g_pmt + 4*MI_16]
    sub eax, [rip + g_pmt + 4*MI_16]
    cmp eax, 16
    jge 1f
    mov eax, 16
1:  mov [rip + lw], eax
    PM eax, MI_6
    add eax, [rip + g_pmt + 4*MI_10]
    mov [rip + ly], eax
    mov rdi, rbx
    call qc_preview_px
    mov edi, TS_TITLE           # the × and the fold button at the right of the first row
    call st_lineh
    mov [rsp], eax
    mov edi, LK_CLOSE
    xor esi, esi
    call li_new
    mov ecx, [rip + lx]
    add ecx, [rip + lw]
    sub ecx, [rsp]
    mov [rax + LI_x], ecx
    mov ecx, [rip + ly]
    mov [rax + LI_y], ecx
    mov ecx, [rsp]
    mov [rax + LI_w], ecx
    mov [rax + LI_h], ecx
    mov edi, LK_FOLD
    xor esi, esi
    call li_new
    mov ecx, [rip + lx]
    add ecx, [rip + lw]
    sub ecx, [rsp]
    sub ecx, [rsp]
    sub ecx, [rip + g_pmt + 4*MI_4]
    mov [rax + LI_x], ecx
    sub ecx, [rip + g_pmt + 4*MI_4]
    mov [rsp + 4], ecx
    mov ecx, [rip + ly]
    mov [rax + LI_y], ecx
    mov ecx, [rsp]
    mov [rax + LI_w], ecx
    mov [rax + LI_h], ecx
    mov rax, [rip + ag_fsmall]  # a tab's height, a row's
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_4]
    add eax, [rip + g_pmt + 4*MI_4]
    mov [rsp + 8], eax
    mov ecx, [rsp]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 12], eax
    mov eax, [rip + lx]
    mov [rsp + 16], eax
    mov eax, [rip + ly]
    mov [rsp + 20], eax
    mov eax, [rsp + 4]          # little room beside the buttons: the tabs start under them
    sub eax, [rip + lx]
    mov ecx, [rip + g_pmt + 4*MI_16]
    imul ecx, ecx, 6
    cmp eax, ecx
    jge 2f
    mov eax, [rsp]
    add eax, [rip + g_pmt + 4*MI_4]
    add [rsp + 20], eax
    mov eax, [rip + lx]
    add eax, [rip + lw]
    mov [rsp + 4], eax
2:  xor r14d, r14d
.Lql_tab:
    cmp r14, [rbx + CD_qs + VEC_len]
    jae .Lql_tabs
    mov rax, [rbx + CD_qs + VEC_ptr]
    mov r15, [rax + r14*8]
    mov rdi, [r15 + CDQ_header]
    call strlen
    mov rdi, [rip + ag_fsmall]
    mov rsi, [r15 + CDQ_header]
    mov rdx, rax
    call text_width
    mov r13d, eax
    add r13d, [rip + g_pmt + 4*MI_8]
    add r13d, [rip + g_pmt + 4*MI_8]
    mov rdi, r15
    call qc_answered
    test eax, eax
    jz 3f
    mov rax, [rip + ag_fsmall]  # its check
    add r13d, [rax + FACE_px]
    add r13d, [rip + g_pmt + 4*MI_4]
3:  mov ecx, [rsp + 16]         # past the row's end: a row more
    cmp ecx, [rip + lx]
    jle 4f
    add ecx, r13d
    cmp ecx, [rsp + 4]
    jle 4f
    mov eax, [rip + lx]
    mov [rsp + 16], eax
    mov eax, [rsp + 12]
    add eax, [rip + g_pmt + 4*MI_4]
    add [rsp + 20], eax
    mov eax, [rip + lx]
    add eax, [rip + lw]
    mov [rsp + 4], eax
4:  mov ecx, [rsp + 4]          # the row at most
    sub ecx, [rsp + 16]
    cmp r13d, ecx
    cmovg r13d, ecx
    cmp r13d, 8
    jge 5f
    mov r13d, 8
5:  mov edi, LK_TAB
    mov esi, r14d
    call li_new
    mov ecx, [rsp + 16]
    mov [rax + LI_x], ecx
    mov ecx, [rsp + 12]
    sub ecx, [rsp + 8]
    sar ecx, 1
    add ecx, [rsp + 20]
    mov [rax + LI_y], ecx
    mov [rax + LI_w], r13d
    mov ecx, [rsp + 8]
    mov [rax + LI_h], ecx
    add r13d, [rip + g_pmt + 4*MI_4]
    add [rsp + 16], r13d
    inc r14
    jmp .Lql_tab
.Lql_tabs:
    mov eax, [rsp + 20]
    add eax, [rsp + 12]
    mov [rip + ly], eax
    test dword ptr [rbx + CD_flags], CDF_FOLDED
    jnz .Lql_end
    mov rdi, rbx
    call qc_cur
    test rax, rax
    jz .Lql_end
    mov r15, rax                # the question shown
    mov eax, [rip + g_pmt + 4*MI_8]
    add [rip + ly], eax
    mov rdi, [r15 + CDQ_text]
    mov esi, TS_TITLE
    mov edx, QTEXT_LINES
    call lay_cstr
    mov eax, [rip + g_pmt + 4*MI_6]
    add [rip + ly], eax
    # the rows, and the preview beside them (a wide card) or under them
    mov eax, [rip + lx]
    mov [rsp + 24], eax
    mov [rsp + 48], eax
    mov eax, [rip + lw]
    mov [rsp + 28], eax
    mov [rsp + 32], eax
    mov [rsp + 52], eax
    mov dword ptr [rsp + 56], 0
    mov rdi, r15
    call qc_has_preview
    mov [rsp + 64], eax
    test eax, eax
    jz 6f
    cmp r12d, QC_BESIDE_W
    jl 6f
    mov dword ptr [rsp + 56], 1
    mov eax, [rip + lw]
    sub eax, [rip + g_pmt + 4*MI_12]
    sar eax, 1
    mov [rsp + 32], eax
    mov ecx, [rip + lx]
    add ecx, eax
    add ecx, [rip + g_pmt + 4*MI_12]
    mov [rsp + 48], ecx
    mov ecx, [rip + lw]
    sub ecx, eax
    sub ecx, [rip + g_pmt + 4*MI_12]
    mov [rsp + 52], ecx
6:  mov rax, [rip + ag_fui]     # a row: its mark, then its text
    mov eax, [rax + FACE_px]
    mov [rsp + 40], eax
    add eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + 68], eax
    mov eax, [rip + ly]
    mov [rsp + 36], eax
    mov dword ptr [rsp + 72], 0
.Lql_row:
    mov eax, [rsp + 72]
    cmp rax, [r15 + CDQ_opts + VEC_len]
    ja .Lql_rows
    mov eax, [rip + ly]
    mov [rsp + 44], eax
    mov edi, LK_OPT
    mov esi, [rsp + 72]
    call li_new
    mov r13, rax
    mov ecx, [rsp + 24]
    mov [rax + LI_x], ecx
    mov ecx, [rsp + 32]
    mov [rax + LI_w], ecx
    mov ecx, [rip + ly]
    mov [rax + LI_y], ecx
    mov eax, [rsp + 24]         # its text
    add eax, [rsp + 68]
    mov [rip + lx], eax
    mov eax, [rsp + 32]
    sub eax, [rsp + 68]
    sub eax, [rip + g_pmt + 4*MI_8]
    cmp eax, 8
    jge 7f
    mov eax, 8
7:  mov [rip + lw], eax
    mov eax, [rip + nlis]
    mov [rsp + 60], eax
    mov eax, [rip + g_pmt + 4*MI_6]
    add [rip + ly], eax
    mov rdi, r15
    mov esi, [rsp + 72]
    call qc_label
    mov rdi, rax
    mov esi, TS_BODY
    mov edx, OLABEL_LINES
    call lay_cstr
    mov rdi, r15
    mov esi, [rsp + 72]
    call qc_opt
    test rax, rax
    jz 8f
    mov rdi, [rax + CDO_desc]
    mov esi, TS_MUTED
    mov edx, ODESC_LINES
    call lay_cstr
8:  mov ecx, [rsp + 60]         # its lines are the row's
81: cmp ecx, [rip + nlis]
    jae 82f
    imul eax, ecx, LI_SIZE
    lea rdx, [rip + lis]
    add rdx, rax
    mov dword ptr [rdx + LI_kind], LK_OLINE
    mov eax, [rdx + LI_idx]
    shl eax, 8
    or eax, [rsp + 72]
    mov [rdx + LI_idx], eax
    inc ecx
    jmp 81b
82: mov eax, [rsp + 24]
    mov [rip + lx], eax
    mov eax, [rsp + 28]
    mov [rip + lw], eax
    mov eax, [rip + ly]         # its height: its lines and their padding, MI_32 at least
    sub eax, [rsp + 44]
    add eax, [rip + g_pmt + 4*MI_6]
    cmp eax, [rip + g_pmt + 4*MI_32]
    jge 83f
    mov eax, [rip + g_pmt + 4*MI_32]
83: mov [r13 + LI_h], eax
    mov r14d, eax
    mov ecx, [rsp + 44]
    add ecx, eax
    mov [rip + ly], ecx
    cmp dword ptr [rbx + CD_focus], CD_OPTS
    jne 84f
    mov eax, [r15 + CDQ_sel]
    cmp eax, [rsp + 72]
    jne 84f
    mov edi, [rsp + 44]
    mov esi, r14d
    call set_focus_rect
84: mov eax, [rip + g_pmt + 4*MI_4]
    add [rip + ly], eax
    mov eax, [rsp + 72]         # Other's field under it while it is picked
    cmp rax, [r15 + CDQ_opts + VEC_len]
    jne 89f
    cmp dword ptr [r15 + CDQ_otheron], 0
    je 89f
    mov esi, [rsp + 32]
    sub esi, [rsp + 68]
    cmp esi, 16
    jge 85f
    mov esi, 16
85: mov [rsp + 76], esi
    lea rdi, [r15 + CDQ_other]
    mov edx, FIELD_ROWS
    call ta_box_h
    mov r14d, eax
    mov edi, LK_FIELD
    xor esi, esi
    call li_new
    mov ecx, [rsp + 24]
    add ecx, [rsp + 68]
    mov [rax + LI_x], ecx
    mov ecx, [rsp + 76]
    mov [rax + LI_w], ecx
    mov ecx, [rip + ly]
    mov [rax + LI_y], ecx
    mov [rax + LI_h], r14d
    cmp dword ptr [rbx + CD_focus], CD_FIELD
    jne 86f
    mov edi, [rip + ly]
    mov esi, r14d
    call set_focus_rect
86: add r14d, [rip + g_pmt + 4*MI_4]
    add [rip + ly], r14d
89: inc dword ptr [rsp + 72]
    jmp .Lql_row
.Lql_rows:
    cmp dword ptr [rsp + 64], 0  # the preview
    je .Lql_btn
    mov esi, [rsp + 52]
    sub esi, [rip + g_pmt + 4*MI_8]
    sub esi, [rip + g_pmt + 4*MI_8]
    cmp esi, 16
    jge 9f
    mov esi, 16
9:  mov rdi, r15
    call qc_body_h
    add eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_4]
    add eax, [rip + g_pmt + 4*MI_8]
    mov rcx, [rip + ag_fsmall]
    add eax, [rcx + FACE_lineh]
    mov r14d, eax               # its height
    mov edi, LK_PREVIEW
    mov esi, [r15 + CDQ_sel]
    call li_new
    mov ecx, [rsp + 48]
    mov [rax + LI_x], ecx
    mov ecx, [rsp + 52]
    mov [rax + LI_w], ecx
    mov [rax + LI_h], r14d
    mov ecx, [rip + ly]
    cmp dword ptr [rsp + 56], 0
    je 91f
    mov ecx, [rsp + 36]         # beside: at the rows' top
91: mov [rax + LI_y], ecx
    add ecx, r14d
    add ecx, [rip + g_pmt + 4*MI_4]
    cmp ecx, [rip + ly]
    jle .Lql_btn
    mov [rip + ly], ecx
.Lql_btn:
    mov eax, [rip + g_pmt + 4*MI_4]
    add [rip + ly], eax
    mov rdi, rbx
    call qc_lay_btn
    lea rdi, [rip + .Lesc]
    mov esi, TS_MUTED
    mov edx, 1
    call lay_cstr
.Lql_end:
    mov eax, [rip + ly]
    add eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_2]
    mov [rip + lay_total], eax
    EPILOGUE

# qc_draw(AS*, CD*, x, y, w, h): the question card in its room, scrolled as the button card is (bc_draw).
#   Clicks act after the drawing (an answer frees the card). Locals: [rsp] x, +4 y (the card's top,
#   scrolled), +8 w, +12 h, +16 the room's top, +20 live, +24 keys, +28 the room's bottom, +32 to +47 an
#   item's, +48 the question shown, +56 Submit answers works, +60 an item's
qc_draw:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 16], ecx
    mov [rsp + 8], r8d
    mov [rsp + 12], r9d
    lea eax, [rcx + r9]
    mov [rsp + 28], eax
    mov [r12 + CD_room], r9d
    mov [r12 + CD_lastw], r8d
    mov dword ptr [rip + pend_act], 0
    mov dword ptr [rip + q_ptab], 0
    mov dword ptr [rip + q_prow], 0
    mov rdi, r12
    call agentcard_live
    mov [rsp + 20], eax
    mov rdi, rbx
    mov rsi, r12
    call has_keys
    mov [rsp + 24], eax
    mov rdi, r12
    call qc_complete
    and eax, [rsp + 20]
    mov [rsp + 56], eax
    mov rdi, r12
    call qc_cur
    mov [rsp + 48], rax
    mov rdi, r12
    mov esi, [rsp + 8]
    call qc_layout
    mov r13d, eax               # its height
    # the scroll: the wheel's over it, else the focused control in view
    xor eax, eax
    mov ecx, r13d
    sub ecx, [rsp + 12]
    jle 2f
    mov eax, [r12 + CD_scroll]
    cmp dword ptr [rip + g_scroll_y], 0
    je 10f
    push rcx
    push rax
    mov edi, [rsp + 16]
    mov esi, [rsp + 16 + 16]
    mov edx, [rsp + 16 + 8]
    mov ecx, [rsp + 16 + 12]
    call ui_in
    mov edx, eax
    pop rax
    pop rcx
    test edx, edx
    jz 10f
    add eax, [rip + g_scroll_y]
    mov dword ptr [rip + g_scroll_y], 0
    or dword ptr [r12 + CD_flags], CDF_WHEEL
    jmp 12f
10: test dword ptr [r12 + CD_flags], CDF_WHEEL
    jnz 12f
    mov r8d, [rsp + 12]         # a margin round it: MI_8, less when the room is short
    sub r8d, [rip + foc_h]
    sar r8d, 1
    cmp r8d, [rip + g_pmt + 4*MI_8]
    jle 101f
    mov r8d, [rip + g_pmt + 4*MI_8]
101:test r8d, r8d
    jns 102f
    xor r8d, r8d
102:mov edx, [rip + foc_y]      # its bottom in view, then its top
    add edx, [rip + foc_h]
    add edx, r8d
    sub edx, [rsp + 12]
    cmp edx, eax
    jle 11f
    mov eax, edx
11: mov edx, [rip + foc_y]
    sub edx, r8d
    cmp edx, eax
    jge 12f
    mov eax, edx
12: cmp eax, ecx
    cmovg eax, ecx
    test eax, eax
    jns 2f
    xor eax, eax
2:  mov [r12 + CD_scroll], eax
    sub [rsp + 4], eax
    # the frame
    PM eax, MI_8
    mov edi, [rsp]
    add edi, eax
    mov esi, [rsp + 4]
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, [rsp + 8]
    sub edx, eax
    sub edx, eax
    mov ecx, r13d
    sub ecx, [rip + g_pmt + 4*MI_8]
    PM r8d, MI_RADIUS
    COLOR r9d, T_ACCENT
    COLOR eax, T_PANEL
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    # cut: a thumb at its right edge
    mov ecx, [rsp + 12]
    cmp r13d, ecx
    jle 15f
    mov eax, ecx
    imul eax, ecx
    xor edx, edx
    div r13d
    cmp eax, [rip + g_pmt + 4*MI_16]
    jge 13f
    mov eax, [rip + g_pmt + 4*MI_16]
13: mov [rsp + 32], eax
    mov eax, [r12 + CD_scroll]
    mov ecx, [rsp + 12]
    sub ecx, [rsp + 32]
    imul eax, ecx
    mov ecx, r13d
    sub ecx, [rsp + 12]
    xor edx, edx
    div ecx
    mov esi, [rsp + 16]
    add esi, eax
    mov edi, [rsp]
    add edi, [rsp + 8]
    sub edi, [rip + g_pmt + 4*MI_8]
    sub edi, [rip + g_pmt + 4*MI_6]
    PM edx, MI_3
    mov ecx, [rsp + 32]
    COLOR r8d, T_SCROLLBAR
    call gfx_fill
15: xor r14d, r14d
.Lqd_item:
    cmp r14d, [rip + nlis]
    jae .Lqd_done
    imul eax, r14d, LI_SIZE
    lea r15, [rip + lis]
    add r15, rax
    inc r14d
    mov eax, [rsp + 4]          # in the room at all?
    add eax, [r15 + LI_y]
    cmp eax, [rsp + 28]
    jge .Lqd_item
    add eax, [r15 + LI_h]
    cmp eax, [rsp + 16]
    jle .Lqd_item
    mov eax, [r15 + LI_kind]
    cmp eax, LK_TEXT
    je .Lqd_text
    cmp eax, LK_FOLD
    je .Lqd_fold
    cmp eax, LK_CLOSE
    je .Lqd_close
    cmp eax, LK_TAB
    je .Lqd_tab
    cmp eax, LK_OPT
    je .Lqd_opt
    cmp eax, LK_OLINE
    je .Lqd_oline
    cmp eax, LK_FIELD
    je .Lqd_field
    cmp eax, LK_PREVIEW
    je .Lqd_preview
    cmp eax, LK_BTN
    je .Lqd_btn
    cmp eax, LK_BLINE
    je .Lqd_bline
    jmp .Lqd_item
.Lqd_text:
    mov edi, [r15 + LI_idx]
    call st_color
    mov [rsp + 32], eax
    mov edi, [r15 + LI_idx]
    call st_face
    mov rdi, rax
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_h]
    mov r8, [r15 + LI_ptr]
    mov r9, [r15 + LI_len]
    mov eax, [r15 + LI_w]
    push rax
    mov eax, [rsp + 8 + 32]
    push rax
    call ui_text_v_fit
    add rsp, 16
    jmp .Lqd_item
.Lqd_fold:
    mov edi, ID_AGCARD + QID_FOLD
    mov r9d, IC_CHEV_UP
    test dword ptr [r12 + CD_flags], CDF_FOLDED
    jz 1f
    mov r9d, IC_CHEV_D
1:  call qd_icon
    test eax, UB_CLICK
    jz .Lqd_item
    xor dword ptr [r12 + CD_flags], CDF_FOLDED
    mov dword ptr [rip + g_dirty], 1
    jmp .Lqd_item
.Lqd_close:
    mov edi, ID_AGCARD + QID_CLOSE
    mov r9d, IC_CLOSE
    call qd_icon
    test eax, UB_CLICK
    jz .Lqd_item
    cmp dword ptr [rsp + 20], 0
    je .Lqd_item
    mov dword ptr [rip + pend_act], CBA_NO
    jmp .Lqd_item
.Lqd_tab:
    mov eax, [r15 + LI_idx]
    lea edi, [rax + ID_AGCARD + QID_TAB]
    call qd_btn_at
    mov [rsp + 32], eax
    test eax, UB_CLICK
    jz 1f
    mov eax, [r15 + LI_idx]
    inc eax
    mov [rip + q_ptab], eax
1:  COLOR r9d, T_BORDER
    COLOR eax, T_PANEL
    test dword ptr [rsp + 32], UB_HOVER
    jz 2f
    COLOR eax, T_HOVER
2:  mov ecx, [r15 + LI_idx]
    cmp ecx, [r12 + CD_tab]
    jne 3f
    COLOR r9d, T_ACCENT         # the one shown
    COLOR eax, T_INPUT
3:  call qd_frame
    mov eax, [r15 + LI_idx]
    mov rcx, [r12 + CD_qs + VEC_ptr]
    mov rax, [rcx + rax*8]
    mov [rsp + 40], rax         # its question
    mov eax, [rsp]
    add eax, [r15 + LI_x]
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + 36], eax         # its text's x
    mov rdi, [rsp + 40]
    call qc_answered
    test eax, eax
    jz 4f
    mov rax, [rip + ag_fsmall]  # answered: a check before it
    mov ecx, [rax + FACE_px]
    mov edx, [r15 + LI_h]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov esi, [rsp + 36]
    add ecx, [rip + g_pmt + 4*MI_4]
    add [rsp + 36], ecx
    sub ecx, [rip + g_pmt + 4*MI_4]
    mov edi, IC_CHECK
    COLOR r8d, T_ACCENT
    call icon_draw
4:  COLOR eax, T_MUTED
    mov ecx, [r15 + LI_idx]
    cmp ecx, [r12 + CD_tab]
    jne 5f
    COLOR eax, T_FG
5:  mov [rsp + 32], eax
    mov eax, [rsp]              # the room left for its text
    add eax, [r15 + LI_x]
    add eax, [r15 + LI_w]
    sub eax, [rip + g_pmt + 4*MI_8]
    sub eax, [rsp + 36]
    jns 6f
    xor eax, eax
6:  mov [rsp + 60], eax
    mov rax, [rsp + 40]
    mov rdi, [rax + CDQ_header]
    call strlen
    mov r9, rax
    mov rax, [rsp + 40]
    mov r8, [rax + CDQ_header]
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 36]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_h]
    mov eax, [rsp + 60]
    push rax
    mov eax, [rsp + 8 + 32]
    push rax
    call ui_text_v_fit
    add rsp, 16
    jmp .Lqd_item
.Lqd_opt:
    mov eax, [r15 + LI_idx]
    lea edi, [rax + ID_AGCARD + QID_OPT]
    call qd_btn_at
    mov [rsp + 32], eax
    test eax, UB_CLICK
    jz 1f
    cmp dword ptr [rsp + 20], 0
    je 1f
    mov eax, [r15 + LI_idx]
    inc eax
    mov [rip + q_prow], eax
1:  mov rdi, [rsp + 48]
    mov esi, [r15 + LI_idx]
    call qc_picked
    mov [rsp + 36], eax         # picked
    xor ecx, ecx                # picked and about to move on to the next question
    test eax, eax
    jz 2f
    cmp qword ptr [r12 + CD_advat], 0
    je 2f
    mov eax, [r12 + CD_advto]
    dec eax
    cmp eax, [r12 + CD_tab]
    jne 2f
    mov ecx, 1
2:  mov [rsp + 60], ecx
    COLOR r9d, T_BORDER
    cmp dword ptr [r12 + CD_focus], CD_OPTS
    jne 3f
    mov rax, [rsp + 48]
    mov eax, [rax + CDQ_sel]
    cmp eax, [r15 + LI_idx]
    jne 3f
    COLOR r9d, T_ACCENT         # the keyboard's
3:  cmp dword ptr [rsp + 60], 0
    je 31f
    COLOR r9d, T_ACCENT
31: COLOR eax, T_INPUT
    cmp dword ptr [rsp + 60], 0
    jne 32f
    cmp dword ptr [rsp + 20], 0
    je 33f
    test dword ptr [rsp + 32], UB_HOVER
    jz 33f
32: COLOR eax, T_HOVER
33: call qd_frame
    mov rax, [rip + ag_fui]     # its mark, as tall as the text, beside its first line
    mov eax, [rax + FACE_px]
    mov [rsp + 40], eax
    mov edi, TS_BODY
    call st_lineh
    sub eax, [rsp + 40]
    sar eax, 1
    add eax, [rip + g_pmt + 4*MI_6]
    add eax, [rsp + 4]
    add eax, [r15 + LI_y]
    mov [rsp + 44], eax
    mov eax, [rsp]
    add eax, [r15 + LI_x]
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + 32], eax
    COLOR r9d, T_MUTED
    cmp dword ptr [rsp + 36], 0
    je 4f
    COLOR r9d, T_ACCENT
4:  mov rax, [rsp + 48]
    cmp dword ptr [rax + CDQ_multi], 0
    je .Lqd_radio
    COLOR eax, T_PANEL          # a checkbox
    cmp dword ptr [rsp + 36], 0
    je 5f
    COLOR eax, T_ACCENT
5:  push rax
    push rax
    mov edi, [rsp + 16 + 32]
    mov esi, [rsp + 16 + 44]
    mov edx, [rsp + 16 + 40]
    mov ecx, edx
    PM r8d, MI_3
    call gfx_frame
    add rsp, 16
    cmp dword ptr [rsp + 36], 0
    je .Lqd_item
    mov edi, IC_CHECK
    mov esi, [rsp + 32]
    mov edx, [rsp + 44]
    mov ecx, [rsp + 40]
    COLOR r8d, T_ACCENT_FG
    call icon_draw
    jmp .Lqd_item
.Lqd_radio:
    COLOR eax, T_PANEL
    push rax
    push rax
    mov edi, [rsp + 16 + 32]
    mov esi, [rsp + 16 + 44]
    mov edx, [rsp + 16 + 40]
    mov ecx, edx
    mov r8d, edx
    sar r8d, 1
    call gfx_frame
    add rsp, 16
    cmp dword ptr [rsp + 36], 0
    je .Lqd_item
    mov eax, [rsp + 40]         # picked: a dot in it
    sar eax, 2
    jnz 6f
    mov eax, 1
6:  mov edi, [rsp + 32]
    add edi, eax
    mov esi, [rsp + 44]
    add esi, eax
    mov edx, [rsp + 40]
    sub edx, eax
    sub edx, eax
    mov ecx, edx
    mov r8d, edx
    sar r8d, 1
    COLOR r9d, T_ACCENT
    COLOR eax, T_ACCENT
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    jmp .Lqd_item
.Lqd_oline:
    mov edi, [r15 + LI_idx]
    shr edi, 8
    mov [rsp + 36], edi
    call st_color
    cmp dword ptr [rsp + 20], 0
    jne 1f
    COLOR eax, T_MUTED          # dimmed while locked
1:  mov [rsp + 32], eax
    mov edi, [rsp + 36]
    call st_face
    mov rdi, rax
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_h]
    mov r8, [r15 + LI_ptr]
    mov r9, [r15 + LI_len]
    mov eax, [r15 + LI_w]
    push rax
    mov eax, [rsp + 8 + 32]
    push rax
    call ui_text_v_fit
    add rsp, 16
    jmp .Lqd_item
.Lqd_field:
    mov rdi, [rsp + 48]
    test rdi, rdi
    jz .Lqd_item
    lea rdi, [rdi + CDQ_other]
    mov dword ptr [rdi + TF_id], ID_AGCARD + QID_FIELD
    mov rax, [rip + ag_fui]
    mov [rdi + TF_face], rax
    xor r9d, r9d
    cmp dword ptr [r12 + CD_focus], CD_FIELD
    jne 1f
    mov r9d, [rsp + 24]         # focused when the card has the keys
1:  lea rax, [rip + .Lq_ph]
    push rax
    push rax
    mov esi, [rsp + 16]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 16 + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_w]
    mov r8d, [r15 + LI_h]
    call ui_textarea
    add rsp, 16
    test eax, UB_PRESS
    jz .Lqd_item
    mov dword ptr [r12 + CD_focus], CD_FIELD
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov dword ptr [rip + g_dirty], 1
    jmp .Lqd_item
.Lqd_preview:
    COLOR r9d, T_BORDER
    COLOR eax, T_INPUT
    call qd_frame
    lea rdi, [rip + qsb]        # "Preview: LABEL"
    call sb_clear
    lea rdi, [rip + qsb]
    lea rsi, [rip + .Lq_preview]
    call sb_push_cstr
    mov rdi, [rsp + 48]
    mov esi, [r15 + LI_idx]
    call qc_label
    lea rdi, [rip + qsb]
    mov rsi, rax
    call sb_push_cstr
    mov eax, [r15 + LI_w]
    sub eax, [rip + g_pmt + 4*MI_8]
    sub eax, [rip + g_pmt + 4*MI_8]
    cmp eax, 16
    jge 1f
    mov eax, 16
1:  mov [rsp + 60], eax         # its body's width
    mov rax, [rip + ag_fsmall]
    mov ecx, [rax + FACE_lineh]
    mov eax, [rsp + 4]
    add eax, [r15 + LI_y]
    add eax, [rip + g_pmt + 4*MI_8]
    lea edx, [rax + rcx]
    add edx, [rip + g_pmt + 4*MI_4]
    mov [rsp + 36], edx         # its body's y
    mov edx, [r15 + LI_h]
    sub edx, [rip + g_pmt + 4*MI_8]
    sub edx, ecx
    sub edx, [rip + g_pmt + 4*MI_4]
    sub edx, [rip + g_pmt + 4*MI_8]
    mov [rsp + 32], edx         # its body's height
    mov edx, eax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    add esi, [rip + g_pmt + 4*MI_8]
    mov r8, [rip + qsb + SB_ptr]
    mov r9, [rip + qsb + SB_len]
    mov eax, [rsp + 60]
    push rax
    COLOR eax, T_MUTED
    push rax
    call ui_text_v_fit
    add rsp, 16
    mov rdi, [rsp + 48]
    mov esi, [r15 + LI_idx]
    call qc_opt
    test rax, rax
    jz 2f
    mov rax, [rax + CDO_preview]
    test rax, rax
    jz 2f
    mov [rsp + 40], rax
    mov rdi, rax
    mov esi, [rsp + 60]
    call md_layout
    mov edi, [rsp]
    add edi, [r15 + LI_x]
    add edi, [rip + g_pmt + 4*MI_8]
    mov esi, [rsp + 36]
    mov edx, [rsp + 60]
    mov ecx, [rsp + 32]
    call gfx_clip_push
    mov eax, ID_AGCARD + QID_LINKS
    push rax
    push rax
    mov rdi, [rsp + 16 + 40]
    mov esi, [rsp + 16]
    add esi, [r15 + LI_x]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rsp + 16 + 36]
    mov ecx, [rsp + 16 + 60]
    mov r8d, [rsp + 16 + 32]
    xor r9d, r9d
    call md_draw
    add rsp, 16
    call gfx_clip_pop
    jmp .Lqd_item
2:  lea rdi, [rip + .Lq_nopreview]
    call strlen
    mov r9, rax
    lea r8, [rip + .Lq_nopreview]
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rsp + 36]
    mov rax, [rip + ag_fsmall]
    mov ecx, [rax + FACE_lineh]
    mov eax, [rsp + 60]
    push rax
    COLOR eax, T_MUTED
    push rax
    call ui_text_v_fit
    add rsp, 16
    jmp .Lqd_item
.Lqd_btn:
    mov edi, ID_AGCARD + QID_SUBMIT
    call qd_btn_at
    mov [rsp + 32], eax
    test eax, UB_CLICK
    jz 1f
    cmp dword ptr [rsp + 56], 0
    je 1f
    mov dword ptr [rip + pend_act], CBA_SUBMIT
1:  COLOR r9d, T_BORDER
    cmp dword ptr [r12 + CD_focus], 0
    jne 2f
    COLOR r9d, T_ACCENT
2:  COLOR eax, T_INPUT
    cmp dword ptr [rsp + 56], 0
    je 3f
    test dword ptr [rsp + 32], UB_HOVER
    jz 3f
    COLOR eax, T_HOVER
3:  call qd_frame
    mov byte ptr [rip + num], '1'
    mov edi, TS_SMALL
    call st_lineh
    mov ecx, eax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    add edx, [rip + g_pmt + 4*MI_6]
    lea r8, [rip + num]
    mov r9d, 1
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    jmp .Lqd_item
.Lqd_bline:
    COLOR eax, T_MUTED
    cmp dword ptr [rsp + 56], 0
    je 1f
    COLOR eax, T_FG
1:  mov [rsp + 32], eax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_h]
    mov r8, [r15 + LI_ptr]
    mov r9, [r15 + LI_len]
    mov eax, [r15 + LI_w]
    push rax
    mov eax, [rsp + 8 + 32]
    push rax
    call ui_text_v_fit
    add rsp, 16
    jmp .Lqd_item
.Lqd_done:
    mov eax, [rip + q_ptab]     # a tab clicked (it opens a folded card)
    test eax, eax
    jz 1f
    and dword ptr [r12 + CD_flags], ~CDF_FOLDED
    mov rdi, r12
    lea esi, [rax - 1]
    call qc_tab
1:  mov eax, [rip + q_prow]
    test eax, eax
    jz 2f
    mov rdi, r12
    lea esi, [rax - 1]
    call qc_pick
2:  mov esi, [rip + pend_act]
    test esi, esi
    jz 9f
    mov rdi, rbx
    call agentcard_answer       # the card may be gone after this
9:  EPILOGUE

# qc_draw's item helpers, called inside its frame (its locals 8 bytes further up): qd_btn_at(edi id) -> eax
#   ui_btn over the item r15; qd_icon(edi id, r9d icon) -> eax ag_icon_btn there; qd_frame(r9d border, eax
#   fill) the item's rounded frame
qd_btn_at:
    mov esi, [rsp + 8]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 8 + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_w]
    mov r8d, [r15 + LI_h]
    jmp ui_btn
qd_icon:
    mov esi, [rsp + 8]
    add esi, [r15 + LI_x]
    mov edx, [rsp + 8 + 4]
    add edx, [r15 + LI_y]
    mov ecx, [r15 + LI_w]
    mov r8d, [r15 + LI_h]
    jmp ag_icon_btn
qd_frame:
    sub rsp, 8
    push rax
    push rax
    mov edi, [rsp + 32]
    add edi, [r15 + LI_x]
    mov esi, [rsp + 32 + 4]
    add esi, [r15 + LI_y]
    mov edx, [r15 + LI_w]
    mov ecx, [r15 + LI_h]
    PM r8d, MI_RADIUS
    call gfx_frame
    add rsp, 24
    ret

# qc_key(AS*, CD*, keysym, cp, mods) -> eax 1 taken (see "the question card" above)
qc_key:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    test dword ptr [r12 + CD_flags], CDF_FOLDED
    jz 1f
    cmp r13d, KEY_ESCAPE        # folded: Escape is swallowed, Enter opens it
    je .Lqk_yes
    cmp r13d, KEY_RETURN
    je 11f
    cmp r13d, KEY_KP_ENTER
    jne .Lqk_no
11: and dword ptr [r12 + CD_flags], ~CDF_FOLDED
    jmp .Lqk_yes
1:  mov rdi, r12
    call agentcard_live
    test eax, eax
    jnz 2f
    cmp r13d, KEY_TAB           # locked: nothing but Tab (out to the box)
    je .Lqk_no
    jmp .Lqk_yes
2:  mov rdi, r12
    call qc_cur
    test rax, rax
    jz .Lqk_no
    cmp dword ptr [r12 + CD_focus], CD_FIELD
    jne .Lqk_rows
    lea rdi, [rax + CDQ_other]  # in Other's field
    mov [rsp], rdi
    cmp r13d, KEY_ESCAPE
    je .Lqk_no_answer
    cmp r13d, KEY_TAB
    je .Lqk_no
    cmp r13d, KEY_RETURN
    je 3f
    cmp r13d, KEY_KP_ENTER
    jne 4f
3:  test r15d, MOD_SHIFT
    jnz 6f
    mov eax, [r12 + CD_tab]     # Enter: the next question
    inc eax
    cmp rax, [r12 + CD_qs + VEC_len]
    jae .Lqk_yes
    mov rdi, r12
    mov esi, eax
    call qc_tab
    jmp .Lqk_yes
4:  cmp r13d, KEY_DOWN
    je 5f
    cmp r13d, KEY_UP
    jne 6f
5:  mov rdi, [rsp]
    call has_lf
    test eax, eax
    jnz 6f
    mov esi, 1
    cmp r13d, KEY_DOWN
    je 51f
    mov esi, -1
51: mov rdi, r12
    call qc_step
    jmp .Lqk_yes
6:  mov rdi, [rsp]
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    call ta_key
    test eax, eax
    jz .Lqk_no
    jmp .Lqk_yes
.Lqk_rows:
    test r15d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Lqk_no
    cmp r13d, KEY_ESCAPE
    je .Lqk_no_answer
    cmp r13d, KEY_DOWN
    je 7f
    cmp r13d, KEY_UP
    je 71f
    cmp r13d, KEY_LEFT
    je 72f
    cmp r13d, KEY_RIGHT
    je 73f
    cmp r13d, KEY_RETURN
    je 74f
    cmp r13d, KEY_KP_ENTER
    je 74f
    cmp r13d, ' '
    je 74f
    mov eax, r14d               # the character, else the key
    test eax, eax
    jnz 75f
    mov eax, r13d
75: cmp eax, '1'
    jne .Lqk_no
    jmp .Lqk_submit
7:  mov esi, 1
    jmp 76f
71: mov esi, -1
76: mov rdi, r12
    call qc_step
    jmp .Lqk_yes
72: cmp dword ptr [r12 + CD_focus], CD_OPTS
    jne .Lqk_no
    mov eax, [r12 + CD_tab]
    test eax, eax
    jz .Lqk_yes
    dec eax
    mov rdi, r12
    mov esi, eax
    call qc_tab
    jmp .Lqk_yes
73: cmp dword ptr [r12 + CD_focus], CD_OPTS
    jne .Lqk_no
    mov eax, [r12 + CD_tab]
    inc eax
    cmp rax, [r12 + CD_qs + VEC_len]
    jae .Lqk_yes
    mov rdi, r12
    mov esi, eax
    call qc_tab
    jmp .Lqk_yes
74: cmp dword ptr [r12 + CD_focus], CD_OPTS
    jne .Lqk_submit
    mov rdi, r12
    call qc_cur
    mov esi, [rax + CDQ_sel]
    mov rdi, r12
    call qc_pick
    jmp .Lqk_yes
.Lqk_submit:
    mov rdi, r12
    call qc_complete
    test eax, eax
    jz .Lqk_yes                 # not every question has an answer: nothing
    mov esi, CBA_SUBMIT
    jmp .Lqk_answer
.Lqk_no_answer:
    mov esi, CBA_NO
.Lqk_answer:
    mov rdi, rbx
    call agentcard_answer       # (the card is gone once its answer went)
    jmp .Lqk_done
.Lqk_yes:
    and dword ptr [r12 + CD_flags], ~CDF_WHEEL
.Lqk_done:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lqk_no:
    xor eax, eax
    EPILOGUE

# q_push_esc(sb, cstr): the text, its line feeds as "\n"
q_push_esc:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
1:  movzx esi, byte ptr [r12]
    test esi, esi
    jz 9f
    inc r12
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

# q_word(sb, cstr word, value): " WORD=VALUE" (WORD with its "=")
q_word:
    PROLOGUE
    mov rbx, rdi
    mov r12d, edx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    EPILOGUE

# qc_dump(sb, CD*): print-agent-card's lines of a question card: "tab N HEADER answered=0|1 current=0|1" per
#   question; for the one shown "question TEXT", "option N LABEL picked=0|1 sel=0|1" per row (Other last; sel:
#   the row the keyboard and the preview are on), "other TEXT" while Other is picked, "preview none" or
#   "preview beside|under<TAB>Preview: LABEL<TAB>BODY" (BODY the preview's Markdown, "No preview for this
#   option"; its place at the width the card was drawn at), "submit enabled=0|1"
qc_dump:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13, [r12 + CD_qs + VEC_len]
    jae 2f
    mov rax, [r12 + CD_qs + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    mov rdi, rbx
    lea rsi, [rip + .Lqw_tab]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r14 + CDQ_header]
    call sb_push_cstr
    mov rdi, r14
    call qc_answered
    mov edx, eax
    mov rdi, rbx
    lea rsi, [rip + .Lqw_answered]
    call q_word
    xor edx, edx
    lea eax, [r13 - 1]
    cmp eax, [r12 + CD_tab]
    sete dl
    mov rdi, rbx
    lea rsi, [rip + .Lqw_current]
    call q_word
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    jmp 1b
2:  mov rdi, r12
    call qc_cur
    test rax, rax
    jz 9f
    mov r14, rax
    mov rdi, rbx
    lea rsi, [rip + .Lqw_question]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + CDQ_text]
    call q_push_esc
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor r13d, r13d
3:  cmp r13, [r14 + CDQ_opts + VEC_len]
    ja 4f
    mov rdi, rbx
    lea rsi, [rip + .Lqw_option]
    call sb_push_cstr
    lea esi, [r13 + 1]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, r14
    mov esi, r13d
    call qc_label
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r14
    mov esi, r13d
    call qc_picked
    mov edx, eax
    mov rdi, rbx
    lea rsi, [rip + .Lqw_picked]
    call q_word
    xor edx, edx
    cmp r13d, [r14 + CDQ_sel]
    sete dl
    mov rdi, rbx
    lea rsi, [rip + .Lqw_sel]
    call q_word
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r13
    jmp 3b
4:  cmp dword ptr [r14 + CDQ_otheron], 0
    je 5f
    mov rdi, rbx
    lea rsi, [rip + .Lq_other_w]
    lea rdx, [r14 + CDQ_other]
    call push_tf
5:  mov rdi, rbx
    lea rsi, [rip + .Lqw_preview]
    call sb_push_cstr
    mov rdi, r14
    call qc_has_preview
    test eax, eax
    jnz 6f
    mov rdi, rbx
    lea rsi, [rip + .Lqw_none]
    call sb_push_cstr
    jmp 8f
6:  lea rsi, [rip + .Lqw_under]
    mov eax, [r12 + CD_lastw]
    test eax, eax
    jnz 61f
    mov eax, 400
61: cmp eax, QC_BESIDE_W
    jl 62f
    lea rsi, [rip + .Lqw_beside]
62: mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [rip + .Lq_preview]
    call sb_push_cstr
    mov rdi, r14
    mov esi, [r14 + CDQ_sel]
    call qc_label
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    lea r15, [rip + .Lq_nopreview]
    mov rdi, r14
    mov esi, [r14 + CDQ_sel]
    call qc_opt
    test rax, rax
    jz 7f
    mov rdi, [rax + CDO_preview]
    test rdi, rdi
    jz 7f
    call md_source
    mov r15, rax
7:  mov rdi, rbx
    mov rsi, r15
    call q_push_esc
    mov rcx, [rbx + SB_len]     # without the line feed the Markdown ends with
    cmp rcx, 2
    jb 8f
    mov rax, [rbx + SB_ptr]
    cmp word ptr [rax + rcx - 2], 0x6e5c
    jne 8f
    sub qword ptr [rbx + SB_len], 2
8:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, r12
    call qc_complete
    mov edx, eax
    mov rdi, rbx
    lea rsi, [rip + .Lqw_submit]
    call q_word
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# qc_input(sb, CD*): print-agent-input's line for a question card: "card=QUESTION options=A|B|Other"
qc_input:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rsi, [rip + .Ld_card]
    call sb_push_cstr
    mov rdi, r12
    call qc_cur
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, rbx
    mov rsi, [r13 + CDQ_text]
    call q_push_esc
    mov rdi, rbx
    lea rsi, [rip + .Ld_options]
    call sb_push_cstr
    xor r14d, r14d
1:  cmp r14, [r13 + CDQ_opts + VEC_len]
    ja 9f
    test r14, r14
    jz 2f
    mov rdi, rbx
    mov esi, '|'
    call sb_push_byte
2:  mov rdi, r13
    mov esi, r14d
    call qc_label
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    inc r14
    jmp 1b
9:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Lq_empty: .asciz ""
.Lq_other: .asciz "Other"
.Lq_other_w: .asciz "other"
.Lq_comma: .asciz ", "
.Lq_text_lf: .asciz "text\n"
.Lq_ph: .asciz "Type your answer\342\200\246"
.Lq_preview: .asciz "Preview: "
.Lq_nopreview: .asciz "No preview for this option"
.Lwaiting_q: .asciz "Waiting for your answer\342\200\246"
.Lw_options: .asciz "options"
.Lqw_tab: .asciz "tab "
.Lqw_answered: .asciz " answered="
.Lqw_current: .asciz " current="
.Lqw_question: .asciz "question "
.Lqw_option: .asciz "option "
.Lqw_picked: .asciz " picked="
.Lqw_sel: .asciz " sel="
.Lqw_preview: .asciz "preview "
.Lqw_none: .asciz "none"
.Lqw_beside: .asciz "beside"
.Lqw_under: .asciz "under"
.Lqw_submit: .asciz "submit enabled="

.data
.p2align 2
.globl g_card_advance_ms
g_card_advance_ms: .long CARD_ADVANCE_MS

.bss
.p2align 3
qsb: .zero SB_SIZE              # an answer (qc_complete), a caption
fsb: .zero SB_SIZE              # a preview as it is shown (q_fence)
q_ptab: .long 0                 # a click on a tab (its question + 1), on a row (the row + 1), after the drawing
q_prow: .long 0
