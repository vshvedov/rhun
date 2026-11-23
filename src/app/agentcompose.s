# The prompt box's behaviour (generic): its keys before the text area's, its owner changing (drafts per
# conversation), the placeholder, the prompt suggestion, the 50,000 limit and invisible characters, the
# painted word, the argument hint drawn after a command's name.
#
#   composer_key(keysym, cp, mods) -> eax 1 taken   agentext_input_key asks it first: Ctrl+J a line break in
#                                       any agents box; then, in a built-in driver's box (a key there is a
#                                       writer's action: the driver's record is read): Shift+Tab cycles the
#                                       permission mode; an open popup takes its keys (Escape closes it before
#                                       anything else); Enter sends ([agents] ctrl_enter_sends: Ctrl+Enter or
#                                       Cmd+Enter, Enter a line break; Shift+Enter always a line break); Up
#                                       with the caret at the start recalls the previous prompt, Down with it
#                                       at the end goes forward and at last gives back the unsent text; Tab in
#                                       an empty box takes the suggestion
#   composer_owner(AS* new owner or 0, keep)   the box changes owner: the old owner's text is kept (its
#                                       AS_draft; a new conversation's, left before its first prompt for
#                                       another conversation or the list, for the next new conversation of its
#                                       kind; for a new one at once, it goes), the box empties (keep 1: the text
#                                       goes with the box), prompts that never went come back
#                                       (agentext_unsent_back), then the new owner's kept text after them; the
#                                       popup closes
#   composer_adopt(AS*)                 the box writes to that conversation now, its text with it (a send)
#   composer_row_gone(AS*)              a row is freed: what the composer kept for it goes, or, for a new
#                                       conversation that never got a prompt, its text is kept for the next one
#   composer_sent(AS* or 0)             the box's text went: the recall starts again, the notice and the
#                                       suggestion go, the window has sent with that driver
#   composer_changed()                  the box's text or caret changed: an emptied box ends the recall; a
#                                       notice about another text goes
#   composer_keyed()                    the box took a key: AL_keyed (a card's focus rule)
#   composer_placeholder(AS* or 0) -> rax cstr or 0   the suggestion (no turn runs), "Queue another message..."
#                                       (a turn runs or a card waits), the driver's first-use text (DRV_hint)
#                                       until the window's first Send of that driver; 0: the box's own
#   composer_check(ptr, len, why CW_*) -> rax ptr, rdx len, ecx removed   the text without its invisible
#                                       characters (a buffer of the composer's, valid until the next call)
#   composer_send_ok(AS*) -> eax 1      the box's text may go: none removed and within the limit; else the
#                                       box keeps the cleaned text and the notice band says why
#   composer_paste(ptr, len) -> eax 1   a paste into a built-in driver's box: refused past the limit, else its
#                                       invisible characters removed (the notice says how many)
#   composer_paint(TF*, AS* or 0)       TF_paint: the word the driver paints (AL_word), each occurrence
#   composer_hint(TF*, kind) -> rax cstr or 0   the argument hint for the box's text: it is "/NAME " and NAME
#                                       a command with one in the driver's record (nothing is read for it)
#   composer_hint_at(TF*, x, y, w) -> eax x, edx y  where it starts: the end of the caret's row as the text
#                                       area lays it out (ta_layout, ta_row_of, ta_row_bounds)
#   composer_hint_draw(TF*, kind, x, y, w, h)  the hint in T_MUTED over the text area, inside it
#   composer_hint_dump(sb)              "hint TEXT at X Y" for the hint drawn last, nothing without one
#   composer_dump(sb)                   print-agent-composer: "draft=0|1 paint=START-END|-" for a
#                                       driven conversation's box (draft 1: its text is its kept draft,
#                                       unchanged since; paint: the first painted range)
#   events (AL* first): ev_suggest(al, ptr, len) (the prompt the agent suggests; ptr 0 clears it),
#     ev_word(al, cstr) (the word the box paints, "" none)
.include "rhun.inc"

.equ HIST_MAX, 100              # prompts the recall goes back through (the extension's)
.equ SEND_UNITS, 50000        # a prompt's UTF-16 units at most (the extension's limit)
.equ MARKER_UNITS, 55           # "\n\n[Message truncated - exceeded 50,000 character limit]"
.equ PAINT_MAX, 32              # painted ranges at most
.equ KINDS_MAX, 8               # new conversations' drafts, by AS_kind
.equ SUGGEST_MAX, 1000          # a suggestion's bytes at most
.equ CW_SEND, 0
.equ CW_PASTE, 1

.bss
.p2align 3
hint_text: .quad 0              # as drawn last: the hint (a copy in hint_buf, or 0) and where
hint_buf: .zero 128
hint_x: .long 0
hint_y: .long 0
own_as: .quad 0                 # the conversation the box's text belongs to, 0: a draft of own_kind or none
own_kind: .quad 0
new_drafts: .zero 8 * KINDS_MAX # owned cstr per kind: a new conversation's text left before its first prompt
hist_draft: .quad 0             # owned cstr: the box's text when the recall began
restored: .quad 0               # 1: the box holds the kept draft given back, as given (restored_hash)
restored_hash: .quad 0
note_as: .quad 0                # the conversation whose notice band the composer set, and its box's text then
note_hash: .quad 0
sent_kinds: .quad 0             # a bit per driver kind the window has sent with
chk: .zero SB_SIZE              # composer_check's text
nsb: .zero SB_SIZE              # a notice
csb: .zero SB_SIZE              # text being put in the box
paint_buf: .zero 24 * (PAINT_MAX + 1)

.data
.p2align 2
hist_i: .long -1                # the prompt recalled (0 the newest), -1 none

.text

# box() -> rax the prompt box (TF*)
box:
    jmp agentext_box

# units(ptr, len) -> rax its UTF-16 units: a character above U+FFFF (a four-byte one) counts 2
units:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 9f
    movzx edx, byte ptr [rdi + rcx]
    inc rcx
    mov r8d, edx
    and r8d, 0xc0
    cmp r8d, 0x80
    je 1b
    inc rax
    cmp edx, 0xf0
    jb 1b
    inc rax
    jmp 1b
9:  ret

# trim(ptr, len) -> rax ptr, rdx len without the blanks (ASCII white space and controls) at both ends
trim:
    mov rax, rdi
    mov rdx, rsi
1:  test rdx, rdx
    jz 9f
    cmp byte ptr [rax], ' '
    ja 2f
    inc rax
    dec rdx
    jmp 1b
2:  cmp byte ptr [rax + rdx - 1], ' '
    ja 9f
    dec rdx
    jnz 2b
9:  ret

# fnv(ptr, len) -> rax its FNV-1a hash
fnv:
    mov rax, 0xcbf29ce484222325
    mov r8, 0x100000001b3
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 9f
    movzx edx, byte ptr [rdi + rcx]
    xor rax, rdx
    imul rax, r8
    inc rcx
    jmp 1b
9:  ret

# box_hash() -> rax the box's text's hash
box_hash:
    sub rsp, 8
    call box
    mov rdi, rax
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call fnv
    add rsp, 8
    ret

# is_draft_conv(AS*) -> eax 1 when it is a new conversation that never got a prompt (ALF_DRAFT)
is_draft_conv:
    xor eax, eax
    test rdi, rdi
    jz 1f
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 1f
    test dword ptr [rcx + AL_flags], ALF_DRAFT
    setnz al
1:  ret

# driven(AS*) -> rax its driver when it is a built-in one (not an extension's session), else 0
driven:
    test rdi, rdi
    jz 1f
    sub rsp, 8
    call agent_drv_of
    add rsp, 8
    test rax, rax
    jz 2f
    test dword ptr [rax + DRV_caps], DRVC_SESSION
    jz 2f
1:  xor eax, eax
2:  ret

# set_new_draft(kind, ptr, len): a new conversation's kept text for that kind (len 0: none)
set_new_draft:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp rbx, KINDS_MAX
    jae 9f
    lea r14, [rip + new_drafts]
    mov rdi, [r14 + rbx*8]
    call mem_free
    mov qword ptr [r14 + rbx*8], 0
    test r13, r13
    jz 9f
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [r14 + rbx*8], rax
9:  EPILOGUE

# hist_reset(): no prompt is recalled
hist_reset:
    sub rsp, 8
    mov dword ptr [rip + hist_i], -1
    mov rdi, [rip + hist_draft]
    call mem_free
    mov qword ptr [rip + hist_draft], 0
    add rsp, 8
    ret

# note_drop(): the composer's notice band goes
note_drop:
    sub rsp, 8
    mov rdi, [rip + note_as]
    test rdi, rdi
    jz 1f
    mov qword ptr [rip + note_as], 0
    call agent_live_get
    test rax, rax
    jz 1f
    mov rdi, rax
    mov esi, BK_NOTICE
    xor edx, edx
    xor ecx, ecx
    call ev_band
1:  add rsp, 8
    ret

# note_show(): the notice in nsb on the band of the box's conversation, about the box's text as it is now
note_show:
    PROLOGUE
    call note_drop
    call agentext_box_owner
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    call agent_live
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax                # a notice the user dismissed shows again: this is a new one
    mov esi, BK_NOTICE
    xor edx, edx
    xor ecx, ecx
    call ev_band
    mov rdi, r12
    mov esi, BK_NOTICE
    mov rdx, [rip + nsb + SB_ptr]
    mov rcx, [rip + nsb + SB_len]
    call ev_band
    mov [rip + note_as], rbx
    call box_hash
    mov [rip + note_hash], rax
9:  EPILOGUE

# box_put(ptr, len, caret0): the box's text becomes that (copied first: it may be the box's own), its caret at
#   the start (caret0 1) or the end; the typed command menu follows (agentext_box_changed)
box_put:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    lea rdi, [rip + csb]
    call sb_clear
    lea rdi, [rip + csb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    call box
    mov rbx, rax
    mov rdi, rax
    mov rsi, [rip + csb + SB_ptr]
    mov rdx, [rip + csb + SB_len]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lnone]
1:  call tf_set
    test r14d, r14d
    jz 2f
    mov qword ptr [rbx + TF_cur], 0
    mov qword ptr [rbx + TF_anchor], 0
2:  call agentext_box_changed
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN composer_key(keysym, cp, mods) -> eax 1 when the key was taken before the text area's (see the top)
FN composer_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov eax, r14d               # Ctrl+J: a line break in any agents box (never Toggle Panel)
    and eax, MOD_CTRL | MOD_ALT | MOD_SUPER | MOD_SHIFT
    cmp eax, MOD_CTRL
    jne 10f
    mov eax, r12d
    or eax, 0x20
    cmp eax, 'j'
    jne 10f
    call agentpop_field
    test rax, rax
    jnz 10f
    call agentext_new_active    # (a box that writes somewhere: a draft or an open conversation)
    test rax, rax
    jnz 11f
    call agents_open_driven
    test rax, rax
    jz 10f
11: jmp box_newline
10: call agentext_box_owner
    mov rbx, rax                # the conversation, or 0 (a draft)
    mov r15d, edx               # its driver's kind, 0: not a built-in driver's box
    test r15d, r15d
    jz 1f
    mov edi, edx
    call agentcfg_get
    mov rdi, rax
    call agentcfg_need
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz 1f
    cmp r12d, KEY_ISO_LEFT_TAB
    je 2f
    cmp r12d, KEY_TAB
    jne 1f
    test r14d, MOD_SHIFT
    jz 1f
2:  call agentpop_field         # the button menu's field takes its own keys
    test rax, rax
    jnz 1f
    call foot_mode_cycle
    test eax, eax
    jz 1f
    EPILOGUE
1:  call agentpop_kind
    test eax, eax
    jz 3f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call agentpop_key
    test eax, eax
    jz 3f
    EPILOGUE
3:  test r15d, r15d             # the rest are a built-in driver's box's own
    jz 8f
    call agentpop_field
    test rax, rax
    jnz 8f
    cmp r12d, KEY_RETURN
    je 4f
    cmp r12d, KEY_KP_ENTER
    jne 5f
4:  test r14d, MOD_SHIFT        # Shift+Enter: the text area's line break
    jnz 8f
    cmp dword ptr [rip + cfg_agents_ctrl_enter_sends], 0
    je 41f
    test r14d, MOD_CTRL | MOD_SUPER
    jz box_newline              # Enter: a line break
41: call agentext_send
    mov eax, 1
    EPILOGUE
5:  test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER | MOD_SHIFT
    jnz 8f
    cmp r12d, KEY_UP
    jne 6f
    mov rdi, rbx
    call hist_up
    EPILOGUE
6:  cmp r12d, KEY_DOWN
    jne 7f
    mov rdi, rbx
    call hist_down
    EPILOGUE
7:  cmp r12d, KEY_TAB
    jne 8f
    mov rdi, rbx                # an empty box takes the suggestion it shows
    call suggestion_shown
    test rax, rax
    jz 8f
    mov rdi, rax
    call strlen
    mov rdi, [rbx + AS_live]
    mov rdi, [rdi + AL_suggest]
    mov rsi, rax
    xor edx, edx
    call box_put
    call agentext_typed
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# box_newline: composer_key's tail (in its frame): a line break at the caret, as typed; taken
box_newline:
    call box
    mov rdi, rax
    call tf_text
    mov rbx, rdx
    call box
    mov rdi, rax
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call ta_insert
    mov rdi, rbx
    call agentext_box_typed
    call agentext_box_changed
    mov eax, 1
    EPILOGUE

# suggestion_shown(AS* or 0) -> rax the suggestion the empty box shows as its placeholder, or 0
suggestion_shown:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
    test rbx, rbx
    jz 9f
    call box
    mov rdi, rax
    call tf_text
    test rdx, rdx
    jnz 9f
    mov rdi, rbx
    call composer_placeholder
    test rax, rax
    jz 9f
    mov rcx, [rbx + AS_live]
    test rcx, rcx
    jz 9f
    cmp rax, [rcx + AL_suggest]
    jne 9f
    mov r12, rax
9:  mov rax, r12
    EPILOGUE

# queued_n(AS*) -> rax its messages that have not started (agent_queued)
queued_n:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  mov rdi, rbx
    mov rsi, r12
    call agent_queued
    test rax, rax
    jz 9f
    inc r12
    cmp r12, HIST_MAX
    jb 1b
9:  mov rax, r12
    EPILOGUE

# hist_entry(AS*, i) -> rax ptr, rdx len of the i-th prompt back (0 the newest; rax 0 past the last): the
#   messages that have not started, the newest first, then the conversation's own prompts, the newest first;
#   HIST_MAX in all
hist_entry:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor eax, eax
    xor edx, edx
    cmp r12, HIST_MAX
    jae 9f
    mov rdi, rbx
    call queued_n
    cmp r12, rax
    jae 1f
    sub rax, r12
    lea rsi, [rax - 1]
    mov rdi, rbx
    call agent_queued
    EPILOGUE
1:  sub r12, rax
    mov rdi, rbx
    lea rsi, [r12 + 1]
    call agents_user_nth
9:  EPILOGUE

# hist_up(AS* or 0) -> eax 1 taken: the caret at the start (no selection), the previous prompt in the box
hist_up:
    PROLOGUE
    mov rbx, rdi
    xor r15d, r15d
    test rbx, rbx
    jz 9f
    call box
    mov r14, rax
    cmp qword ptr [r14 + TF_cur], 0
    jne 9f
    cmp qword ptr [r14 + TF_anchor], 0
    jne 9f
    movsxd rsi, dword ptr [rip + hist_i]
    inc rsi
    mov rdi, rbx
    call hist_entry
    test rax, rax
    jz 9f
    mov r12, rax
    mov r13, rdx
    cmp dword ptr [rip + hist_i], -1
    jne 1f
    mov rdi, r14                # the recall begins: what the box holds comes back at its end
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + hist_draft], rax
1:  inc dword ptr [rip + hist_i]
    mov rdi, r12
    mov rsi, r13
    call trim
    mov rdi, rax
    mov rsi, rdx
    mov edx, 1
    call box_put
    mov r15d, 1
9:  mov eax, r15d
    EPILOGUE

# hist_down(AS* or 0) -> eax 1 taken: the caret at the end (no selection) while a prompt is recalled: the
#   next one, or past the newest the text the box held when the recall began
hist_down:
    PROLOGUE
    mov rbx, rdi
    xor r15d, r15d
    test rbx, rbx
    jz 9f
    cmp dword ptr [rip + hist_i], -1
    je 9f
    call box
    mov r14, rax
    mov rax, [r14 + TF_sb + SB_len]
    cmp [r14 + TF_cur], rax
    jne 9f
    cmp [r14 + TF_anchor], rax
    jne 9f
    mov r15d, 1
    dec dword ptr [rip + hist_i]
    js 2f
    movsxd rsi, dword ptr [rip + hist_i]
    mov rdi, rbx
    call hist_entry
    test rax, rax
    jz 2f                       # (the list changed under the recall)
    mov rdi, rax
    mov rsi, rdx
    call trim
    mov rdi, rax
    mov rsi, rdx
    xor edx, edx
    call box_put
    jmp 9f
2:  mov r12, [rip + hist_draft] # the text the box held
    mov qword ptr [rip + hist_draft], 0
    mov dword ptr [rip + hist_i], -1
    lea rdi, [rip + .Lnone]
    xor esi, esi
    test r12, r12
    jz 3f
    mov rdi, r12
    call strlen
    mov rsi, rax
    mov rdi, r12
3:  xor edx, edx
    call box_put
    mov rdi, r12
    call mem_free
9:  mov eax, r15d
    EPILOGUE

# FN composer_owner(AS* new owner or 0, keep): see the top
FN composer_owner
    PROLOGUE
    mov rbx, rdi
    mov r15d, esi
    test rbx, rbx
    jz 10f
    cmp rbx, [rip + own_as]
    jne 10f
    call agentpop_close         # its own already
    EPILOGUE
10:    call box
    mov rdi, rax
    call tf_text
    mov r12, rax
    mov r13, rdx
    test r15d, r15d
    jnz 3f                      # the text goes with the box
    mov r14, [rip + own_as]     # the old owner keeps what it had
    test r14, r14
    jz 2f
    cmp r14, rbx
    je 3f
    mov rdi, r14
    call is_draft_conv
    test eax, eax
    jz 1f
    test rbx, rbx               # a new conversation left before its first prompt for another new one:
    jz 3f                       #   it goes, its text with it (that one begins empty)
    mov edi, [r14 + AS_kind]    # for another conversation: its text for the next new one
    mov rsi, r12
    mov rdx, r13
    call set_new_draft
    jmp 3f
1:  mov rdi, [r14 + AS_draft]
    call mem_free
    mov qword ptr [r14 + AS_draft], 0
    test r13, r13
    jz 3f
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [r14 + AS_draft], rax
    jmp 3f
2:  mov rdi, [rip + own_kind]   # a draft's text (no conversation yet)
    test rdi, rdi
    jz 3f
    mov rsi, r12
    mov rdx, r13
    call set_new_draft
3:  call note_drop
    call hist_reset
    mov qword ptr [rip + restored], 0
    mov [rip + own_as], rbx
    mov qword ptr [rip + own_kind], 0
    test rbx, rbx
    jnz 4f
    call agentext_box_owner     # a draft: its driver's kind (agentext set it before)
    mov [rip + own_kind], rdx
4:  call agentpop_close
    test r15d, r15d
    jnz 5f
    call box
    mov rdi, rax
    call tf_clear
    mov rdi, rbx                # prompts of its that never went
    test rdi, rdi
    jz 5f
    call agentext_unsent_back
5:  xor r12d, r12d              # the new owner's kept text, after what the box holds
    test rbx, rbx
    jz 6f
    mov r12, [rbx + AS_draft]
    mov qword ptr [rbx + AS_draft], 0
    test r12, r12
    jnz 7f
    mov rdi, rbx
    call is_draft_conv
    test eax, eax
    jz 8f
    mov eax, [rbx + AS_kind]
    jmp 61f
6:  mov rax, [rip + own_kind]
    test rax, rax
    jz 8f
61: cmp rax, KINDS_MAX
    jae 8f
    lea rcx, [rip + new_drafts]
    mov r12, [rcx + rax*8]
    mov qword ptr [rcx + rax*8], 0
    test r12, r12
    jz 8f
7:  call box
    mov rdi, rax
    call tf_text
    mov r13, rax
    mov r14, rdx
    lea rdi, [rip + nsb]
    call sb_clear
    test r14, r14
    jz 71f
    lea rdi, [rip + nsb]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    lea rdi, [rip + nsb]
    lea rsi, [rip + .Lgap]
    call sb_push_cstr
71: lea rdi, [rip + nsb]
    mov rsi, r12
    call sb_push_cstr
    mov rdi, r12
    call mem_free
    call box                    # (set as it is: opening a conversation is no writer's action)
    mov rdi, rax
    mov rsi, [rip + nsb + SB_ptr]
    mov rdx, [rip + nsb + SB_len]
    call tf_set
    mov qword ptr [rip + restored], 1
    call box_hash
    mov [rip + restored_hash], rax
8:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN composer_adopt(AS*): the box writes to that conversation now, its text going with it
FN composer_adopt
    cmp [rip + own_as], rdi
    je 1f
    mov [rip + own_as], rdi
    mov qword ptr [rip + own_kind], 0
    mov qword ptr [rip + restored], 0
    jmp hist_reset
1:  ret

# FN composer_row_gone(AS*): see the top
FN composer_row_gone
    PROLOGUE
    mov rbx, rdi
    cmp [rip + note_as], rbx    # its band goes with its record
    jne 1f
    mov qword ptr [rip + note_as], 0
1:  cmp [rip + own_as], rbx
    jne 3f
    mov qword ptr [rip + own_as], 0
    mov qword ptr [rip + own_kind], 0
    mov qword ptr [rip + restored], 0
    call hist_reset
    mov rdi, rbx
    call is_draft_conv
    test eax, eax
    jz 9f
    call box                    # a new conversation that never got a prompt: its text for the next one
    mov rdi, rax
    call tf_text
    test rdx, rdx
    jz 9f
    mov edi, [rbx + AS_kind]
    mov rsi, rax
    call set_new_draft
    jmp 9f
3:  mov r12, [rbx + AS_draft]
    test r12, r12
    jz 9f
    mov rdi, rbx
    call is_draft_conv
    test eax, eax
    jz 9f
    mov rdi, r12
    call strlen
    mov edi, [rbx + AS_kind]
    mov rsi, r12
    mov rdx, rax
    call set_new_draft
9:  EPILOGUE

# FN composer_sent(AS* or 0): see the top
FN composer_sent
    PROLOGUE
    mov rbx, rdi
    call note_drop
    call hist_reset
    mov qword ptr [rip + restored], 0
    test rbx, rbx
    jz 9f
    mov [rip + own_as], rbx
    mov qword ptr [rip + own_kind], 0
    mov ecx, [rbx + AS_kind]
    cmp ecx, 63
    ja 1f
    mov eax, 1
    shl rax, cl
    or [rip + sent_kinds], rax
1:  mov rdi, [rbx + AS_live]    # a suggestion goes when the user sends
    test rdi, rdi
    jz 9f
    xor esi, esi
    xor edx, edx
    call ev_suggest
9:  EPILOGUE

# FN composer_changed(): see the top
FN composer_changed
    PROLOGUE
    call box
    mov rdi, rax
    call tf_text
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jnz 1f
    call hist_reset
1:  mov rdi, r12
    mov rsi, r13
    call fnv
    mov rbx, rax
    cmp qword ptr [rip + restored], 0
    je 2f
    cmp rbx, [rip + restored_hash]
    je 2f
    mov qword ptr [rip + restored], 0
2:  cmp qword ptr [rip + note_as], 0
    je 9f
    cmp rbx, [rip + note_hash]
    je 9f
    call note_drop
9:  EPILOGUE

# FN composer_keyed(): the box took a key: its conversation's AL_keyed
FN composer_keyed
    PROLOGUE
    call agentext_box_owner
    test rax, rax
    jz 9f
    mov rdi, rax
    call agent_live_get
    test rax, rax
    jz 9f
    mov rbx, rax
    call time_ms
    mov [rbx + AL_keyed], rax
9:  EPILOGUE

# FN composer_placeholder(AS* or 0) -> rax the placeholder the composer gives the box, or 0 (see the top)
FN composer_placeholder
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
    call driven
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, rbx
    call agent_live_get
    test rax, rax
    jz 3f
    mov ecx, [rax + AL_state]
    cmp ecx, ALS_WORKING
    je 2f
    cmp ecx, ALS_WAITING
    je 2f
    mov rcx, [rax + AL_suggest] # no turn runs: the suggestion
    test rcx, rcx
    jz 3f
    mov r12, rcx
    jmp 9f
2:  lea r12, [rip + .Lph_queue]
    jmp 9f
3:  mov ecx, [rbx + AS_kind]    # until the window's first Send of this driver: its first-use text
    cmp ecx, 63
    ja 9f
    mov rax, [rip + sent_kinds]
    bt rax, rcx
    jc 9f
    mov r12, [r13 + DRV_hint]
9:  mov rax, r12
    EPILOGUE

# strip_class(cp, prev, next) -> eax 1 when the character goes: the bundle's classes (IZt), its context rules
#   simplified so that emoji and scripts keep theirs: tags, bidirectional marks and the zero-width space, word
#   joiner and BOM always; the joiners U+200C, U+200D unless between two non-ASCII characters; the variation
#   selectors unless after a non-ASCII character (or a keycap's digit, #, * before U+20E3)
strip_class:
    mov eax, 1
    cmp edi, 0xe0000            # tags
    jb 1f
    cmp edi, 0xe007f
    jbe 9f
1:  cmp edi, 0x061c
    je 9f
    cmp edi, 0x200b             # zero width space
    je 9f
    cmp edi, 0x200e
    je 9f
    cmp edi, 0x200f
    je 9f
    cmp edi, 0x2060
    je 9f
    cmp edi, 0xfeff
    je 9f
    cmp edi, 0x202a
    jb 2f
    cmp edi, 0x202e
    jbe 9f
2:  cmp edi, 0x2066
    jb 3f
    cmp edi, 0x2069
    jbe 9f
3:  cmp edi, 0x200c             # the joiners
    je 4f
    cmp edi, 0x200d
    jne 5f
4:  cmp esi, 0x80
    jb 9f
    cmp edx, 0x80
    jb 9f
    xor eax, eax
    ret
5:  cmp edi, 0xfe00             # the variation selectors
    jb 6f
    cmp edi, 0xfe0f
    jbe 7f
6:  cmp edi, 0xe0100
    jb 61f
    cmp edi, 0xe01ef
    jbe 7f
61: cmp edi, 0x180b
    jb 8f
    cmp edi, 0x180d
    jbe 7f
    cmp edi, 0x180f
    je 7f
8:  xor eax, eax
    ret
7:  cmp esi, 0x80
    jae 8b
    cmp edx, 0x20e3             # a keycap: 1, FE0F, U+20E3
    jne 9f
    cmp edi, 0xfe0f
    ja 9f
    cmp esi, '#'
    je 8b
    cmp esi, '*'
    je 8b
    cmp esi, '0'
    jb 9f
    cmp esi, '9'
    jbe 8b
9:  ret

# FN composer_check(ptr, len, why) -> rax ptr, rdx len, ecx removed (see the top). Locals: [rsp] the previous
#   character (the text's, removed or not), [rsp+8] the current one's length, [rsp+16] the next character,
#   [rsp+24] its length
FN composer_check
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + chk]
    call sb_clear
    xor r14d, r14d              # where the current character is
    xor r15d, r15d              # removed
    mov qword ptr [rsp], 0
    test r13, r13
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call utf8_decode
    mov ebx, eax                # the current character
    mov [rsp + 8], rdx
1:  cmp r14, r13
    jae 8f
    mov qword ptr [rsp + 16], 0
    mov qword ptr [rsp + 24], 0
    mov rax, r14
    add rax, [rsp + 8]
    cmp rax, r13
    jae 2f
    lea rdi, [r12 + rax]
    mov rsi, r13
    sub rsi, rax
    call utf8_decode
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
2:  mov edi, ebx
    mov esi, [rsp]
    mov edx, [rsp + 16]
    call strip_class
    test eax, eax
    jz 3f
    inc r15d
    jmp 4f
3:  lea rdi, [rip + chk]
    lea rsi, [r12 + r14]
    mov rdx, [rsp + 8]
    call sb_push
4:  mov [rsp], rbx
    add r14, [rsp + 8]
    mov ebx, [rsp + 16]
    mov rax, [rsp + 24]
    mov [rsp + 8], rax
    jmp 1b
8:  mov rax, [rip + chk + SB_ptr]
    mov rdx, [rip + chk + SB_len]
    test rax, rax
    jnz 9f
    lea rax, [rip + .Lnone]
9:  mov ecx, r15d
    EPILOGUE

# over(ptr, len) -> rax the UTF-16 units past SEND_UNITS (0 within it); a text ending with the CLI's own
#   truncation marker does not count it
over:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call units
    mov rbx, rax
    lea rdi, [rip + .Lmarker]
    call strlen
    cmp r13, rax
    jb 1f
    mov rdx, rax
    lea rdi, [r12 + r13]
    sub rdi, rax
    lea rsi, [rip + .Lmarker]
    call memeq
    test eax, eax
    jz 1f
    sub rbx, MARKER_UNITS
1:  xor eax, eax
    sub rbx, SEND_UNITS
    jle 9f
    mov rax, rbx
9:  EPILOGUE

# push_count(n): n into nsb, with thousands separators from 100,000 on (the bundle's toLocaleString)
push_count:
    PROLOGUE 32
    mov rbx, rdi
    cmp rbx, 100000
    jae 1f
    lea rdi, [rip + nsb]
    mov rsi, rbx
    call sb_push_u64
    EPILOGUE
1:  xor r12d, r12d              # the groups of three, the lowest first
2:  mov rax, rbx
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [rsp + r12*4], edx
    inc r12
    mov rbx, rax
    test rax, rax
    jnz 2b
    dec r12
    lea rdi, [rip + nsb]
    mov esi, [rsp + r12*4]
    call sb_push_u64
3:  test r12, r12
    jz 9f
    dec r12
    lea rdi, [rip + nsb]
    mov esi, ','
    call sb_push_byte
    mov eax, [rsp + r12*4]
    cmp eax, 100
    jae 5f
    lea rdi, [rip + nsb]
    mov esi, '0'
    call sb_push_byte
    cmp dword ptr [rsp + r12*4], 10
    jae 5f
    lea rdi, [rip + nsb]
    mov esi, '0'
    call sb_push_byte
5:  lea rdi, [rip + nsb]
    mov esi, [rsp + r12*4]
    call sb_push_u64
    jmp 3b
9:  EPILOGUE

# over_note(head cstr, n, tail cstr): "HEAD is N character(s) over the limit of 50000 - TAIL" into nsb
over_note:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + nsb]
    call sb_clear
    lea rdi, [rip + nsb]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + nsb]
    lea rsi, [rip + .Lo_is]
    call sb_push_cstr
    mov rdi, r12
    call push_count
    lea rsi, [rip + .Lo_chars]
    cmp r12, 1
    jne 1f
    lea rsi, [rip + .Lo_char]
1:  lea rdi, [rip + nsb]
    call sb_push_cstr
    lea rdi, [rip + nsb]
    lea rsi, [rip + .Lo_over]
    call sb_push_cstr
    lea rdi, [rip + nsb]
    mov rsi, r13
    call sb_push_cstr
    EPILOGUE

# removed_note(n, tail cstr): "Removed 1 invisible character" / "Removed N invisible characters", then tail,
#   into nsb
removed_note:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + nsb]
    call sb_clear
    lea rdi, [rip + nsb]
    lea rsi, [rip + .Lr_removed]
    call sb_push_cstr
    lea rdi, [rip + nsb]
    mov rsi, rbx
    call sb_push_u64
    lea rsi, [rip + .Lr_chars]
    cmp rbx, 1
    jne 1f
    lea rsi, [rip + .Lr_char]
1:  lea rdi, [rip + nsb]
    call sb_push_cstr
    lea rdi, [rip + nsb]
    mov rsi, r12
    call sb_push_cstr
    EPILOGUE

# FN composer_send_ok(AS* or 0) -> eax 1 when the box's text may go (see the top); a built-in driver's box only
FN composer_send_ok
    PROLOGUE
    mov rbx, rdi
    mov r15d, 1
    call driven
    test rax, rax
    jz 9f
    call box
    mov rdi, rax
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call trim
    test rdx, rdx
    jz 9f
    mov r12, rax
    mov r13, rdx
    mov rdi, rax
    mov rsi, rdx
    mov edx, CW_SEND
    call composer_check
    test ecx, ecx
    jz 5f
    mov r14d, ecx               # removed: the box keeps the cleaned text, and nothing goes
    xor r15d, r15d
    mov rdi, rax
    mov rsi, rdx
    call trim
    mov r12, rax
    mov r13, rdx
    mov rdi, rax
    mov rsi, rdx
    xor edx, edx
    call box_put
    test r13, r13
    jnz 1f
    mov edi, r14d
    lea rsi, [rip + .Lr_empty]
    call removed_note
    jmp 8f
1:  mov rdi, r12
    mov rsi, r13
    call over
    test rax, rax
    jz 2f
    mov edi, r14d
    lea rsi, [rip + .Lr_long]
    call removed_note
    jmp 8f
2:  mov edi, r14d
    lea rsi, [rip + .Lr_review]
    call removed_note
    lea rsi, [rip + .Lk_enter]
    cmp dword ptr [rip + cfg_agents_ctrl_enter_sends], 0
    je 3f
    lea rsi, [rip + .Lk_ctrl_enter]
3:  lea rdi, [rip + nsb]
    call sb_push_cstr
    lea rdi, [rip + nsb]
    lea rsi, [rip + .Lr_to_send]
    call sb_push_cstr
    jmp 8f
5:  mov rdi, r12                # past the limit: nothing goes, no toast
    mov rsi, r13
    call over
    test rax, rax
    jz 9f
    xor r15d, r15d
    lea rdi, [rip + .Lo_prompt]
    mov rsi, rax
    lea rdx, [rip + .Lo_shorten]
    call over_note
8:  call note_show
9:  mov eax, r15d
    EPILOGUE

# FN composer_paste(ptr, len) -> eax 1 when the paste was a built-in driver's box's (see the top)
FN composer_paste
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor r15d, r15d
    call agentext_box_owner
    test edx, edx
    jz 9f
    mov r15d, 1
    lea rdi, [rip + csb]        # as the box would take it: CR LF and CR a line break
    call sb_clear
    xor ebx, ebx
1:  cmp rbx, r13
    jae 3f
    movzx esi, byte ptr [r12 + rbx]
    inc rbx
    cmp esi, 13
    jne 2f
    mov esi, 10
    cmp rbx, r13
    jae 2f
    cmp byte ptr [r12 + rbx], 10
    jne 2f
    inc rbx
2:  lea rdi, [rip + csb]
    call sb_push_byte
    jmp 1b
3:  mov rdi, [rip + csb + SB_ptr]
    mov rsi, [rip + csb + SB_len]
    call trim
    mov rdi, rax
    mov rsi, rdx
    call over
    test rax, rax
    jz 4f
    lea rdi, [rip + .Lo_paste]  # nothing is added
    mov rsi, rax
    lea rdx, [rip + .Lo_paste_less]
    call over_note
    call note_show
    jmp 9f
4:  mov rdi, [rip + csb + SB_ptr]
    mov rsi, [rip + csb + SB_len]
    mov edx, CW_PASTE
    call composer_check
    mov r12, rax
    mov r13, rdx
    mov r14d, ecx
    call box
    mov rdi, rax
    call tf_text
    mov rbx, rdx
    call box
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call ta_insert
    mov rdi, rbx
    call agentext_box_typed
    call agentext_box_changed
    test r14d, r14d
    jz 9f
    mov edi, r14d
    lea rsi, [rip + .Lr_pasted]
    call removed_note
    call note_show
9:  mov eax, r15d
    EPILOGUE

# word_byte(byte) -> eax 1 for a byte of a word as a regular expression's \b sees it: [A-Za-z0-9_]
word_byte:
    xor eax, eax
    cmp edi, '_'
    je 1f
    cmp edi, '0'
    jb 9f
    cmp edi, '9'
    jbe 1f
    or edi, 0x20
    cmp edi, 'a'
    jb 9f
    cmp edi, 'z'
    ja 9f
1:  mov eax, 1
9:  ret

# paint_find(ptr, len, word cstr) -> eax ranges in paint_buf (ending start -1): each occurrence of the word, any
#   case, as a word of its own: not after "/", "\" or "-", not before "/", "\", "-", "?" or a "." that a word
#   follows; none in a command (the text starts with "/") or past the limit (the bundle's rules)
paint_find:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov [rsp], rdx
    xor r15d, r15d              # ranges
    mov rdi, rdx
    call strlen
    mov rbx, rax                # the word's length
    test rbx, rbx
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call trim
    test rdx, rdx
    jz 8f
    cmp byte ptr [rax], '/'
    je 8f
    mov rdi, r12
    mov rsi, r13
    call units
    cmp rax, SEND_UNITS
    ja 8f
    xor r14d, r14d              # where
1:  lea rax, [r14 + rbx]
    cmp rax, r13
    ja 8f
    cmp r15d, PAINT_MAX
    jae 8f
    xor ecx, ecx                # the word here, any case?
2:  cmp rcx, rbx
    jae 3f
    lea rax, [r12 + r14]
    movzx eax, byte ptr [rax + rcx]
    mov rdx, [rsp]
    movzx edx, byte ptr [rdx + rcx]
    cmp eax, 'A'
    jb 21f
    cmp eax, 'Z'
    ja 21f
    or eax, 0x20
21: cmp eax, edx
    jne 7f
    inc rcx
    jmp 2b
3:  xor edi, edi                # the byte before
    test r14, r14
    jz 31f
    movzx edi, byte ptr [r12 + r14 - 1]
    cmp edi, '/'
    je 7f
    cmp edi, '\\'
    je 7f
    cmp edi, '-'
    je 7f
    call word_byte
    test eax, eax
    jnz 7f
31: lea rax, [r14 + rbx]        # the byte after
    cmp rax, r13
    jae 4f
    movzx edi, byte ptr [r12 + rax]
    cmp edi, '/'
    je 7f
    cmp edi, '\\'
    je 7f
    cmp edi, '-'
    je 7f
    cmp edi, '?'
    je 7f
    cmp edi, '.'
    jne 32f
    lea rcx, [rax + 1]
    cmp rcx, r13
    jae 4f
    movzx edi, byte ptr [r12 + rcx]
    call word_byte
    test eax, eax
    jnz 7f
    jmp 4f
32: call word_byte
    test eax, eax
    jnz 7f
4:  imul rax, r15, 24
    lea rcx, [rip + paint_buf]
    add rax, rcx
    mov [rax], r14
    lea rcx, [r14 + rbx]
    mov [rax + 8], rcx
    mov dword ptr [rax + 16], PAINT_RAINBOW
    inc r15d
    add r14, rbx
    jmp 1b
7:  inc r14
    jmp 1b
8:  imul rax, r15, 24
    lea rcx, [rip + paint_buf]
    mov qword ptr [rcx + rax], -1
    mov eax, r15d
    EPILOGUE

# FN composer_paint(TF*, AS* or 0): see the top
FN composer_paint
    PROLOGUE
    mov rbx, rdi
    mov qword ptr [rbx + TF_paint], 0
    test rsi, rsi
    jz 9f
    mov r12, [rsi + AS_live]
    test r12, r12
    jz 9f
    cmp byte ptr [r12 + AL_word], 0
    je 9f
    mov rdi, rbx
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [r12 + AL_word]
    call paint_find
    test eax, eax
    jz 9f
    lea rax, [rip + paint_buf]
    mov [rbx + TF_paint], rax
9:  EPILOGUE

# FN composer_dump(sb): see the top
FN composer_dump
    PROLOGUE
    mov rbx, rdi
    call agentext_box_owner
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    call driven
    test rax, rax
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + .Ld_draft]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + restored]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_paint]
    call sb_push_cstr
    call box
    mov rdi, rax
    mov rsi, r12
    call composer_paint
    call box
    cmp qword ptr [rax + TF_paint], 0
    jne 1f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 2f
1:  mov rdi, rbx
    mov rsi, [rip + paint_buf]
    call sb_push_u64
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [rip + paint_buf + 8]
    call sb_push_u64
2:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# FN ev_suggest(al, ptr, len): the prompt the agent suggests next (AL_suggest, at most SUGGEST_MAX bytes cut at a
#   character); ptr 0 or len 0: none
FN ev_suggest
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [rbx + AL_suggest]
    call mem_free
    mov qword ptr [rbx + AL_suggest], 0
    test r12, r12
    jz 9f
    mov rdi, r12
    mov rsi, r13
    call trim
    test rdx, rdx
    jz 9f
    mov r12, rax
    mov rdi, rdx
    mov rsi, rax
    mov edx, SUGGEST_MAX
    call utf8_cut
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [rbx + AL_suggest], rax
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN ev_word(al, cstr): the word the box paints (AL_word, at most 15 bytes), "" none
FN ev_word
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdi, rax
    mov rsi, r12
    mov edx, 15
    call utf8_cut
    mov r13, rax
    lea rdi, [rbx + AL_word]
    mov rsi, r12
    mov rdx, r13
    call memmove
    mov byte ptr [rbx + AL_word + r13], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN composer_hint(TF*, kind) -> rax the hint to draw after the box's text, or 0
FN composer_hint
    PROLOGUE
    mov r12d, esi
    xor ebx, ebx
    test r12d, r12d
    jz 9f
    call tf_text
    mov r13, rax
    mov r14, rdx
    cmp r14, 3                  # "/" NAME " ", NAME without blanks
    jb 9f
    cmp byte ptr [r13], '/'
    jne 9f
    cmp byte ptr [r13 + r14 - 1], ' '
    jne 9f
    mov ecx, 1
1:  lea rax, [r14 - 1]
    cmp rcx, rax
    jae 2f
    cmp byte ptr [r13 + rcx], ' '
    jbe 9f
    inc rcx
    jmp 1b
2:  mov edi, r12d
    call agentcfg_get
    mov rdi, rax
    lea rsi, [r13 + 1]
    lea rdx, [r14 - 2]
    call agentcfg_find_cmd
    test rax, rax
    jz 9f
    mov r15, rax
    lea rdi, [r13 + 1]          # its name, not an alias
    lea rsi, [r14 - 2]
    mov rdx, [r15 + ACM_name]
    call str_eq_cstr
    test eax, eax
    jz 9f
    mov rax, [r15 + ACM_hint]
    test rax, rax
    jz 9f
    cmp byte ptr [rax], 0
    je 9f
    mov rbx, rax
9:  mov rax, rbx
    EPILOGUE

# FN composer_hint_at(TF*, x, y, w) -> eax x, edx y: the end of the caret's row in a text area drawn at x, y,
#   w wide (ui_textarea's text starts MI_10 in, its first line MI_6 down)
FN composer_hint_at
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov rdi, rbx
    mov esi, ecx
    call ta_layout
    mov rdi, [rbx + TF_cur]
    call ta_row_of
    mov r14d, eax               # the caret's row
    mov edi, eax
    call ta_row_bounds
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rbx
    call tf_text
    mov rsi, rax
    add rsi, [rsp]
    mov rdx, [rsp + 8]
    sub rdx, [rsp]
    mov rdi, [rbx + TF_face]
    test rdi, rdi
    jnz 1f
    lea rdi, [rip + g_face_ui]
1:  call text_width
    lea r15d, [r12 + rax]
    add r15d, [rip + g_mt + 4*MI_10]
    sub r15d, [rbx + TF_scroll]
    mov rdi, rbx
    call ta_line_h_of
    mov ecx, r14d
    sub ecx, [rbx + TF_top]
    imul eax, ecx
    lea edx, [r13 + rax]
    add edx, [rip + g_mt + 4*MI_6]
    mov eax, r15d
    EPILOGUE

# FN composer_hint_draw(TF*, kind, x, y, w, h): the argument hint after the box's text (drawn inside the box)
FN composer_hint_draw
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 8], r8d
    mov [rsp + 12], r9d
    mov qword ptr [rip + hint_text], 0
    call composer_hint
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call composer_hint_at
    mov r13d, eax
    mov r14d, edx
    mov rdi, r12                # a copy: the record's lists may change before a dump
    call strlen
    mov ecx, 127
    cmp rax, rcx
    cmova rax, rcx
    lea rdi, [rip + hint_buf]
    xor ecx, ecx
2:  cmp rcx, rax
    jae 3f
    mov dl, [r12 + rcx]
    mov [rdi + rcx], dl
    inc rcx
    jmp 2b
3:  mov byte ptr [rdi + rcx], 0
    mov [rip + hint_text], rdi
    mov [rip + hint_x], r13d
    mov [rip + hint_y], r14d
    mov edi, [rsp]
    add edi, [rip + g_mt + 4*MI_2]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    sub edx, [rip + g_mt + 4*MI_4]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    mov rdi, rbx
    call ta_line_h_of
    mov r15d, eax
    mov rdi, r12
    call strlen
    mov r9, rax
    mov rdi, [rbx + TF_face]
    test rdi, rdi
    jnz 1f
    lea rdi, [rip + g_face_ui]
1:  mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    mov r8, r12
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    call gfx_clip_pop
9:  EPILOGUE

# FN composer_hint_dump(sb): "hint TEXT at X Y" for the hint drawn last
FN composer_hint_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, [rip + hint_text]
    test r12, r12
    jz 9f
    lea rsi, [rip + .Ld_hint]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_at]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + hint_x]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rip + hint_y]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

.section .rodata
.Ld_hint: .asciz "hint "
.Ld_at: .asciz " at "
.Ld_draft: .asciz "draft="
.Ld_paint: .asciz " paint="
.Lnone: .byte 0
.Lnl: .ascii "\n"
.Lgap: .asciz "\n\n"
.Lph_queue: .asciz "Queue another message\xe2\x80\xa6"
.Lmarker: .asciz "\n\n[Message truncated - exceeded 50,000 character limit]"
.Lo_prompt: .asciz "Your prompt"
.Lo_paste: .asciz "That paste"
.Lo_is: .asciz " is "
.Lo_char: .asciz " character"
.Lo_chars: .asciz " characters"
.Lo_over: .asciz " over the limit of 50000 \xc2\xb7 "
.Lo_shorten: .asciz "shorten it to send"
.Lo_paste_less: .asciz "nothing was added, paste less of it"
.Lr_removed: .asciz "Removed "
.Lr_char: .asciz " invisible character"
.Lr_chars: .asciz " invisible characters"
.Lr_review: .asciz " \xc2\xb7 review and press "
.Lr_to_send: .asciz " to send"
.Lr_empty: .asciz " \xc2\xb7 nothing left to send"
.Lr_long: .asciz " from your prompt \xc2\xb7 still over the limit of 50000 characters \xc2\xb7 shorten it to send"
.Lr_pasted: .asciz " from the pasted text"
.Lk_enter: .asciz "Enter"
.ifdef MACOS
.Lk_ctrl_enter: .asciz "\xe2\x8c\x98 Enter"
.else
.Lk_ctrl_enter: .asciz "Ctrl+Enter"
.endif
