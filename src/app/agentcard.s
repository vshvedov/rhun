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
# buttons, the lines under the rule button, the reject field, "Esc to cancel"); the question card (task 10)
# gets entries of its own in the same row. agentcard_answer is the one way an answer leaves a card.
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
6:  lea rdi, [rbx + CD_btns]
    call vec_free
    lea rdi, [rbx + CD_extra]
    call vec_free
    lea rdi, [rbx + CD_dests]
    call vec_free
    lea rdi, [rbx + CD_qs]
    call vec_free
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
    mov r14, [rbx + AS_live]
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
2:  cmp r12, [r13 + CD_btns + VEC_len]
    jae 8f
    mov rax, [r13 + CD_btns + VEC_ptr]
    imul rcx, r12, CDB_SIZE
    mov esi, [rax + rcx + CDB_act]
    mov rdi, rbx
    call agentcard_answer
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agentcard_set_text(AS*, which 0 the field | 1 the command, ptr, len) -> eax 1 set
FN agentcard_set_text
    PROLOGUE
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    call agentcard_of
    test rax, rax
    jz 8f
    mov rbx, rax
    lea rdi, [rbx + CD_field]
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

# FN agentcard_toggle(AS*, what 0 fold | 1 the Details | 2 the place) -> eax 1 done (as a click on it)
FN agentcard_toggle
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call agentcard_of
    test rax, rax
    jz 8f
    mov r13, rax
    cmp r12d, 2
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

# FN agentcard_waiting(AS*) -> rax "Waiting for permission…" while its card waits and the box (its own)
#   has text, else 0
FN agentcard_waiting
    PROLOGUE
    mov rbx, rdi
    call agentcard_of
    test rax, rax
    jz 8f
    call agentext_box_owner
    cmp rax, rbx
    jne 8f
    call agentext_box
    mov rdi, rax
    call tf_text
    test rdx, rdx
    jz 8f
    lea rax, [rip + .Lwaiting]
    EPILOGUE
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
    mov eax, [r15 + LI_idx]
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
    cmp dword ptr [rip + pend_dest], 0
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
    movsxd rsi, eax
    cmp rsi, [r12 + CD_btns + VEC_len]
    jb 3f
    jne .Lbk_no
    mov dword ptr [r12 + CD_focus], CD_FIELD    # the number after the last: the field
    jmp .Lbk_yes
3:  mov rdi, r12
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
    mov rdi, r12                # Escape: the last button's action (the driver's No)
    mov rsi, [r12 + CD_btns + VEC_len]
    dec rsi
    js .Lbk_yes
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
    lea esi, [rax + 1]
    mov rdi, rbx
    call sb_push_u64
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
51: call bc_layout
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
    mov rdi, r12
    mov esi, r13d
    call compose
    mov r14, rax
    mov r15, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lw_button]
    call sb_push_cstr
    lea esi, [r13 + 1]
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
    mov rdi, rbx
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
4:  cmp r13, [r12 + CD_btns + VEC_len]
    jae 5f
    test r13, r13
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
    inc r13
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
#   its button's number: l2), F the field, d Details). The setting is the user's again after it
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
    call bc_layout
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
    jne 32f
31: mov esi, [rcx + LI_idx]
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

.section .rodata
.p2align 3
# the kinds: measure, draw, key, dump (by CD_kind from 1)
kinds:
    .quad bc_h, bc_draw, bc_key, bc_dump        # CDK_PERMISSION
    .quad bc_h, bc_draw, bc_key, bc_dump        # CDK_QUESTIONS (task 10: its own)
    .quad bc_h, bc_draw, bc_key, bc_dump        # CDK_PLAN
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
item_letters: .byte '?', 't', 'f', 'e', 'b', 'l', 'F', 'd'
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
