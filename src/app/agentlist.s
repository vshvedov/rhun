# The session list (phase 6, checklist 5.4 to 5.12, 5.14, 5.16): the agents panel's list and the chat
# header's "Past conversations" dropdown draw the same list. Newest first, no dates; sections: the user's
# groups (in their order), "Ungrouped" (only when there are groups), "Archived sessions". A search field
# ("Search sessions…", matches marked), the status filter (needs input, working, completed; open, closed;
# active, each with its count), groups made, collapsed, renamed, deleted, sessions moved in and out (by the
# context menu, or dragged onto a group's header), archiving (by hand, or after [agents] archive_after_days
# of quiet), unread marks, inline rename, multi-selection (Cmd/Ctrl+click, Shift+click), the keyboard.
#
# The list is made again (build) only when what it shows can have changed: the sessions (agents.s calls
# aglist_touch), rhun's own marks (agst_gen), the search text, the programs' states, the panel's text size,
# the hour (an archive boundary); a frame draws the rows in view from a binary search on their places, so
# drawing, scrolling and keys cost the same with 50 sessions or 5,000. A search or a filter asks discovery
# for every session of the project once (the page grows to all of them), then filters here.
#
# Driver-neutral: a session's kind names its badge and words; what a kind keeps in its own storage (a title
# Claude Code writes into its file, who else holds a conversation) goes through agent_store.s.
.include "rhun.inc"

.equ ID_AGL, 0x740000           # + (entry & 0x7fff): a row or a header of the panel's list
.equ IDX_DROP, 0x10000          # the dropdown's ids: + this
.equ IDR_ACT, 0x8000            # + ((entry & 0xfff) << 2) + k: a row's hover actions (k 0 rename, 1 archive),
                                #   a group header's menu (k 2)
.equ IDT_FIELD, 0xf000          # the search field
.equ IDT_CLEAR, 0xf001
.equ IDT_SEARCH, 0xf003
.equ IDT_FILTER, 0xf004
.equ IDT_NEWGROUP, 0xf005
.equ IDT_RENAME, 0xf006         # the rename field
.equ IDT_UNARCH, 0xf007         # "Unarchive all N sessions"
.equ IDT_SCROLL, 0xf008
.equ IDT_REOPEN, 0xf009         # the breaker's "Open it anyway"
.equ DK_ROW, 1                  # an entry: a session's row
.equ DK_GROUP, 2                #   a group's header (DE_aux its id)
.equ DK_UNGROUPED, 3            #   "Ungrouped"
.equ DK_ARCHIVED, 4             #   "Archived sessions"
.equ DK_EMPTY, 5                #   "No sessions found" (a search or a filter left nothing)
.equ ST_IDLE, 0                 # a row's dot
.equ ST_RUN, 1
.equ ST_WAIT, 2
.equ ST_UNREAD, 3
.equ RN_SESSION, 1              # what the rename field renames
.equ RN_GROUP, 2
.equ RN_HEADER, 3               # the open conversation's title (agenthead.s)
.equ MENU_MAX, 40               # a context menu's items at most
.equ LABELS_MAX, 8192
.equ ALL_ROWS, 100000           # the page a search or a filter asks for: every session (the worker's most)
.equ DRAG_PX, 6                 # a press that moves this far drags

# an entry of the list as built
STRUCT
F DE_as, 8              # a row's session
F DE_y, 4               # its place from the list's top
F DE_h, 4
F DE_kind, 4            # DK_*
F DE_aux, 4             # a row: its index in the sessions (agents_row_at); a group header: the group's id
F DE_count, 4           # a header: the sessions in its section
F DE_flags, 4           # a header: 1 its section is shown open
ENDSTRUCT DE_SIZE

# a list: the panel's (lv_panel) and the dropdown's (lv_drop)
STRUCT
F LV_tf, TF_SIZE        # the search field
F LV_rows, VEC_SIZE     # DE
F LV_multi, VEC_SIZE    # AS*: the sessions selected together (Cmd/Ctrl+click, Shift+click)
F LV_sig, 80            # what the last build was made from (sig_make)
F LV_sel, 8             # the session the keys are on (AS*), or 0
F LV_anchor, 8          # Shift+click's other end (AS*), or 0
F LV_scroll, 4
F LV_total, 4           # the entries' height
F LV_kind, 4            # the kind it lists, 0 every kind
F LV_search, 4          # the search row shows
F LV_focus, 4           # the search field has the keys
F LV_id, 4              # its ids' base
F LV_ax, 4              # the rows' area, as drawn last
F LV_ay, 4
F LV_aw, 4
F LV_ah, 4
F LV_cnt, 32            # needs, working, completed, open, closed, active, archived, matched
F LV_reveal, 4          # the selected row is brought into view by the next frame
F LV_built, 4           # builds made (print-agent-list)
ENDSTRUCT LV_SIZE
.equ CN_NEEDS, 0
.equ CN_WORK, 4
.equ CN_DONE, 8
.equ CN_OPEN, 12
.equ CN_CLOSED, 16
.equ CN_ACTIVE, 20
.equ CN_ARCH, 24
.equ CN_MATCH, 28

# a session during a build
STRUCT
F BK_as, 8
F BK_idx, 4             # its index in the sessions
F BK_sec, 4             # its section: a group's index, then ungrouped, then archived
ENDSTRUCT BK_SIZE

.bss
.p2align 3
.globl aglist_gen
aglist_gen: .quad 0             # agents.s: the sessions changed (aglist_touch)
lv_panel: .zero LV_SIZE
lv_drop: .zero LV_SIZE
bk: .zero VEC_SIZE              # BK: the sessions a build keeps
bk2: .zero VEC_SIZE             # and in section order
secs: .zero VEC_SIZE            # dwords: a section's count, then its first place in bk2
lsb: .zero SB_SIZE              # a label
dsb: .zero SB_SIZE              # a row's meta line
ren_tf: .zero TF_SIZE           # the rename field
ren_kind: .long 0               # RN_*, 0 none
ren_gid: .long 0
ren_as: .quad 0
ren_lv: .quad 0                 # the list it belongs to (0: the header's)
menu_lv: .quad 0                # a context menu's list, session, group
menu_as: .quad 0
menu_gid: .long 0
menu_multi: .long 0             # it acts on the selection (LV_multi), not menu_as alone
menu_items: .zero 16 * (MENU_MAX + 1)
menu_n: .long 0
labels: .zero LABELS_MAX
labels_n: .long 0
drop_open: .long 0              # the dropdown shows
drop_kind: .long 0
drop_rect: .zero 16             # where it was drawn last (x, y, w, h): its pointer is its own
drop_anchor: .zero 16           # the button it hangs from (x, y, w, h)
drop_shield: .long 0
new_gid: .long 0                # "Start new session in this group": the conversation made next joins it
restored: .long 0               # the conversation open at the last quit was opened again (or will not be)
reopening: .long 0              # it is being opened again: the next poll says it finished (agst_set_tries 0)
.p2align 3
breaker: .quad 0                # it was not opened again: it did not finish opening the last times (4.21)
drag_as: .quad 0                # a row pressed: it may be dragged onto a group's header
drag_x: .long 0
drag_y: .long 0
drag_on: .long 0                # it moved far enough: a drag
pend_open: .quad 0              # a row clicked: opened once the frame is drawn
pend_menu: .long 0              # a context menu asked for this frame: opened once the frame is drawn (x, y)
pend_mx: .long 0
pend_my: .long 0
.p2align 3
held: .zero SB_SIZE             # the keys of the conversations another program holds, "\nKEY\n" each
held_new: .zero SB_SIZE

.section .rodata
.Lph_search: .asciz "Search sessions\xe2\x80\xa6"
.Lph_rename: .asciz "Rename session"
.Lph_group: .asciz "Group name"
.Luntitled: .asciz "Untitled session"
.Lungrouped: .asciz "Ungrouped"
.Larchived: .asciz "Archived sessions"
.Lnone_found: .asciz "No sessions found"
.Lnew_group: .asciz "New group"
.Ldot: .asciz "  \302\267  "
.Lmid: .asciz " \302\267 "
.Lnow: .asciz "now"
.Lmo: .asciz "mo"
.Lunarch_all1: .asciz "Unarchive all "
.Lunarch_all2: .asciz " sessions"
.Lunarch_one: .asciz "Unarchive 1 session"
.Lbr1: .asciz " was not reopened. It did not finish opening the last "
.Lbr2: .asciz " times."
.Lbr_open: .asciz "Open it anyway"
.Ld_reopen: .asciz " reopen="
.Lt_search: .asciz "Search sessions"
.Lt_clear: .asciz "Clear search"
.Lt_filter: .asciz "Filter by status"
.Lt_newgroup: .asciz "New group"
.Lt_rename: .asciz "Rename session"
.Lt_archive: .asciz "Archive session"
.Lt_unarchive: .asciz "Unarchive session"
.Lt_gmenu: .asciz "Group actions"
.Lt_unread: .asciz "Unread"
.Lt_here: .asciz "Open here"
.Lt_other: .asciz "Open in another process"
.Lt_awaiting: .asciz " \xe2\x80\x94 awaiting input"
.Lt_running: .asciz " \xe2\x80\x94 running"
.Lt_awaiting0: .asciz "Awaiting input"
.Lt_running0: .asciz "Running"
# the menus
.Lm_switch: .asciz "Switch to session"
.Lm_resume: .asciz "Resume session"
.Lm_newgroup1: .asciz "New group from session"
.Lm_newgroupn: .asciz "New group from "
.Lm_sessions: .asciz " sessions"
.Lm_addto: .asciz "Add to group \xe2\x96\xb8"
.Lm_remove: .asciz "Remove from group"
.Lm_unread: .asciz "Mark as unread"
.Lm_read: .asciz "Mark as read"
.Lm_archive1: .asciz "Archive session"
.Lm_archiven: .asciz "Archive "
.Lm_unarchive1: .asciz "Unarchive session"
.Lm_unarchiven: .asciz "Unarchive "
.Lm_rename: .asciz "Rename session"
.Lm_grename: .asciz "Rename group"
.Lm_gdelete: .asciz "Delete group"
.Lm_gstart: .asciz "Start new session in this group"
.Lm_check: .asciz "\xe2\x9c\x93 "
.Lm_needs: .asciz "Needs input \302\267 "
.Lm_working: .asciz "Working \302\267 "
.Lm_done: .asciz "Completed \302\267 "
.Lm_open: .asciz "Open \302\267 "
.Lm_closed: .asciz "Closed \302\267 "
.Lm_active: .asciz "Active \302\267 "
.Lm_clearf: .asciz "Clear filters"
.Lm_line: .asciz "-"
# dumps
.Ld_list: .asciz "list shown="
.Ld_total: .asciz " total="
.Ld_arch: .asciz " archived="
.Ld_filter: .asciz " filter="
.Ld_search: .asciz " search="
.Ld_focus: .asciz " field="
.Ld_sel: .asciz " sel="
.Ld_multi: .asciz " multi="
.Ld_counts: .asciz " counts="
.Ld_rename: .asciz " rename="
.Ld_drop: .asciz " drop="
.Ld_group: .asciz "group "
.Ld_ungrouped: .asciz "ungrouped ("
.Ld_archived: .asciz "archived ("
.Ld_closed: .asciz " closed"
.Ld_row: .asciz "  row "
.Ld_kind: .asciz " kind="
.Ld_dot: .asciz " dot="
.Ld_ring: .asciz " ring"
.Ld_match: .asciz " match="
.Ld_age: .asciz " age="
.Ld_wt: .asciz " worktree="
.Ld_selected: .asciz " selected"
.Ld_multi1: .asciz " multi"
.Ld_none: .asciz "none found"
.Ldash: .asciz "-"
dot_words: .quad .Lw_idle, .Lw_running, .Lw_waiting, .Lw_unread
.Lw_idle: .asciz "idle"
.Lw_running: .asciz "running"
.Lw_waiting: .asciz "waiting"
.Lw_unread: .asciz "unread"
.data
.p2align 2
.globl cfg_agents_archive_days
cfg_agents_archive_days: .long 14   # [agents] archive_after_days: days of quiet before a session is archived
drop_gid: .long -1              # the header a dragged row is over this frame: a group's id, 0 Ungrouped, -1 none
.text

# ---------- what agents.s and the rest tell the list ----------

# FN aglist_touch(): the sessions listed changed (a page, a new order, a session made or dropped): the list
#   is made again when next drawn
FN aglist_touch
    inc qword ptr [rip + aglist_gen]
    ret

# FN aglist_gone(AS*): a session is freed: no list, menu, rename or drag names it any more
FN aglist_gone
    PROLOGUE
    mov rbx, rdi
    inc qword ptr [rip + aglist_gen]
    lea rdi, [rip + lv_panel]
    mov rsi, rbx
    call lv_forget
    lea rdi, [rip + lv_drop]
    mov rsi, rbx
    call lv_forget
    cmp [rip + ren_as], rbx
    jne 1f
    mov qword ptr [rip + ren_as], 0
    mov dword ptr [rip + ren_kind], 0
1:  cmp [rip + menu_as], rbx
    jne 2f
    mov qword ptr [rip + menu_as], 0
    call ctx_menu_list          # its menu (it acts on menu_as) closes
    lea rcx, [rip + menu_items]
    cmp rax, rcx
    jne 2f
    call ctx_menu_close
2:  cmp [rip + drag_as], rbx
    jne 3f
    mov qword ptr [rip + drag_as], 0
    mov dword ptr [rip + drag_on], 0
3:  cmp [rip + pend_open], rbx
    jne 4f
    mov qword ptr [rip + pend_open], 0
4:  cmp [rip + breaker], rbx
    jne 5f
    mov qword ptr [rip + breaker], 0
5:  EPILOGUE

# lv_forget(LV*, AS*): the list forgets that session (its keys, its anchor, its selection)
lv_forget:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp [rbx + LV_sel], r12
    jne 1f
    mov qword ptr [rbx + LV_sel], 0
1:  cmp [rbx + LV_anchor], r12
    jne 2f
    mov qword ptr [rbx + LV_anchor], 0
2:  mov rdi, rbx
    mov rsi, r12
    call multi_drop
    mov qword ptr [rbx + LV_rows + VEC_len], 0   # its entries name it: made again before any use
    mov qword ptr [rbx + LV_sig], -1
    EPILOGUE

# FN aglist_project(): another project: its marks are read when next needed; nothing is selected, renamed or
#   restored yet
FN aglist_project
    PROLOGUE
    call agst_reset
    call aglist_reset_view
    mov dword ptr [rip + restored], 0
    mov dword ptr [rip + reopening], 0
    mov qword ptr [rip + breaker], 0
    mov dword ptr [rip + new_gid], 0
    EPILOGUE

# FN aglist_reset_view(): the lists' selections, searches and the dropdown go (a new list of sessions)
FN aglist_reset_view
    PROLOGUE
    lea rbx, [rip + lv_panel]
    call 1f
    lea rbx, [rip + lv_drop]
    call 1f
    mov dword ptr [rip + ren_kind], 0
    mov qword ptr [rip + ren_as], 0
    mov qword ptr [rip + menu_as], 0
    mov dword ptr [rip + drop_open], 0
    mov qword ptr [rip + drag_as], 0
    mov dword ptr [rip + drag_on], 0
    mov qword ptr [rip + pend_open], 0
    lea rdi, [rip + held]
    call sb_clear
    EPILOGUE
1:  mov qword ptr [rbx + LV_sel], 0
    mov qword ptr [rbx + LV_anchor], 0
    mov qword ptr [rbx + LV_multi + VEC_len], 0
    mov qword ptr [rbx + LV_rows + VEC_len], 0
    mov qword ptr [rbx + LV_sig], -1
    mov dword ptr [rbx + LV_scroll], 0
    mov dword ptr [rbx + LV_focus], 0
    ret

# FN aglist_opened(AS*): a conversation opened (agents.s open_session): it is read, the dropdown closes, and an
#   archived one is listed again (resumed). (The list's own opens make it the one a restart opens: after_frame)
FN aglist_opened
    PROLOGUE
    mov rbx, rdi
    mov dword ptr [rip + drop_open], 0
    mov dword ptr [rip + restored], 1     # (one opened now replaces what a restart would open)
    mov qword ptr [rip + breaker], 0
    xor r12d, r12d              # one archived for its age stays listed once resumed
    call days
    test eax, eax
    jz 1f
    imul rax, rax, 86400
    mov r13, rax
    call time_now
    sub rax, [rbx + AS_mtime]
    cmp rax, r13
    jle 1f
    mov r12d, SF_KEPT
1:  mov rdi, rbx
    mov esi, r12d
    mov edx, SF_UNREAD | SF_ARCH
    call agst_mark
    lea rax, [rip + lv_panel]
    mov [rax + LV_sel], rbx
    EPILOGUE

# FN aglist_closed(): the panel went back to its list: no conversation is open for a restart
FN aglist_closed
    xor edi, edi
    jmp agst_set_open

# FN aglist_grew(AS*): its file grew while the panel watched (agents_poll): unread unless it is the one open
FN aglist_grew
    PROLOGUE
    mov rbx, rdi
    call agents_viewed
    cmp rax, rbx
    je 9f
    mov rdi, rbx
    mov esi, SF_UNREAD
    xor edx, edx
    call agst_mark
9:  EPILOGUE

# FN aglist_adopted(AS*): a conversation made here joined the list: one started from a group's menu joins it
FN aglist_adopted
    PROLOGUE
    inc qword ptr [rip + aglist_gen]
    mov esi, [rip + new_gid]
    test esi, esi
    jz 9f
    mov dword ptr [rip + new_gid], 0
    call agst_put_group
9:  EPILOGUE

# FN aglist_poll(): the panel's second (agents_poll): who else holds a conversation (agent_store.s), and the
#   conversation open at the last quit opened again once discovery lists it ([files] restore_session)
FN aglist_poll
    PROLOGUE
    lea rdi, [rip + held_new]
    call sb_clear
    lea rdi, [rip + held_new]
    call agent_store_held       # "\nKEY\n" for each conversation another program has open
    mov rdi, [rip + held + SB_ptr]
    mov rsi, [rip + held + SB_len]
    mov rdx, [rip + held_new + SB_ptr]
    mov rcx, [rip + held_new + SB_len]
    cmp rsi, rcx
    jne 1f
    test rsi, rsi
    jz 2f
    call memcmp_eq
    test eax, eax
    jnz 2f
1:  lea rdi, [rip + held]
    call sb_clear
    lea rdi, [rip + held]
    mov rsi, [rip + held_new + SB_ptr]
    mov rdx, [rip + held_new + SB_len]
    call sb_push
    mov dword ptr [rip + g_dirty], 1
2:  cmp dword ptr [rip + reopening], 0   # the restore finished: the breaker starts again from 0
    je 3f
    mov dword ptr [rip + reopening], 0
    xor edi, edi
    call agst_set_tries
3:  call restore_open
    EPILOGUE

# memcmp_eq(a, n, b, n) -> eax 1 when the n bytes are equal
memcmp_eq:
    xor eax, eax
    xor r8d, r8d
1:  cmp r8, rsi
    jae 2f
    mov r9b, [rdi + r8]
    cmp r9b, [rdx + r8]
    jne 3f
    inc r8
    jmp 1b
2:  mov eax, 1
3:  ret

# restore_open(): once per project, when nothing is open yet and the list has the conversation open at the last
#   quit, it opens again ([files] restore_session; a restart restores the open conversation, 5.16)
restore_open:
    PROLOGUE
    cmp dword ptr [rip + restored], 0
    jne 9f
    cmp dword ptr [rip + cfg_restore_session], 0
    je 8f
    call agst_open
    test rax, rax
    jz 8f
    mov r12, rax
    call agents_viewed
    test rax, rax
    jnz 8f                      # something is open already
    xor ebx, ebx
1:  mov rdi, rbx
    call agents_row_at
    cmp rbx, rdx
    jae 9f                      # not listed yet: a later poll looks again
    inc rbx
    test rax, rax
    jz 1b
    mov r13, rax
    mov rdi, rax
    call agst_key
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov dword ptr [rip + restored], 1
    call agst_tries             # it did not finish opening twice: not again (the breaker), a notice says so
    cmp eax, 2
    jb 2f
    mov [rip + breaker], r13
    mov dword ptr [rip + g_dirty], 1
    jmp 9f
2:  lea edi, [rax + 1]
    call agst_set_tries
    mov dword ptr [rip + reopening], 1
    mov rdi, r13
    call agents_open_as
    jmp 9f
8:  mov dword ptr [rip + restored], 1
9:  EPILOGUE

# ---------- a session's facts ----------

# title_of(AS*) -> rax ptr, rdx len: the title it shows: rhun's own for a kind without a driver's rename,
#   else its own, else "Untitled session"
FN aglist_title
title_of:
    PROLOGUE
    mov rbx, rdi
    call agst_title
    test rax, rax
    jnz 1f
    mov rax, [rbx + AS_title]
    test rax, rax
    jnz 1f
    lea rax, [rip + .Luntitled]
1:  mov r12, rax
    mov rdi, rax
    call strlen
    mov rdx, rax
    mov rax, r12
    EPILOGUE

# status_of(AS*) -> eax ST_*: waiting, running, unread (rhun's mark), idle
status_of:
    PROLOGUE
    mov rbx, rdi
    mov eax, ST_WAIT
    cmp dword ptr [rbx + AS_state], AGS_WAITING
    jne 1f
    cmp dword ptr [rbx + AS_kind], AS_KIND_EXT
    je 9f
    cmp qword ptr [rbx + AS_live], 0
    jne 9f
1:  mov rdi, rbx
    call agents_session_live
    mov ecx, eax
    mov eax, ST_RUN
    test ecx, ecx
    jnz 9f
    mov rdi, rbx
    call agst_of
    xor ecx, ecx
    test eax, SF_UNREAD
    mov eax, ST_UNREAD
    cmovz eax, ecx
9:  EPILOGUE

# is_open(AS*) -> eax 1 when rhun has it open: its program runs here, or it is the conversation shown
is_open:
    PROLOGUE
    mov rbx, rdi
    mov eax, 1
    cmp qword ptr [rbx + AS_live], 0
    jne 9f
    call agents_viewed
    cmp rax, rbx
    sete al
    movzx eax, al
9:  EPILOGUE

# archived(AS*, flags SF_*) -> eax 1 when it is in the archived section: archived by hand, or quiet for
#   [agents] archive_after_days and not unarchived by hand, unread, open or running
archived:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov eax, 1
    test r12d, SF_ARCH
    jnz 9f
    xor eax, eax
    test r12d, SF_KEPT | SF_UNREAD
    jnz 9f
    call days
    test eax, eax
    jz 8f
    imul rax, rax, 86400
    mov r13, rax
    call time_now
    sub rax, [rbx + AS_mtime]
    cmp rax, r13
    jle 8f
    mov rdi, rbx
    call is_open
    test eax, eax
    jnz 8f
    mov rdi, rbx
    call agents_session_live
    xor eax, 1
    jmp 9f
8:  xor eax, eax
9:  EPILOGUE

# days() -> eax [agents] archive_after_days in days (0: never)
days:
    mov eax, [rip + cfg_agents_archive_days]
    ret

# held_by_other(AS*) -> eax 1 when another program has it open (agent_store.s, as of the last poll)
held_by_other:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    cmp qword ptr [rip + held + SB_len], 0
    je 9f
    mov rdi, rbx
    call agst_key
    test rdx, rdx
    jz 8f
    mov r12, rax
    mov r13, rdx
    lea rdi, [rip + lsb]        # "\nKEY\n"
    call sb_clear
    lea rdi, [rip + lsb]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + lsb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + lsb]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + held + SB_ptr]
    mov rsi, [rip + held + SB_len]
    mov rdx, [rip + lsb + SB_ptr]
    mov rcx, [rip + lsb + SB_len]
    call str_find
    not rax
    shr rax, 63
    jmp 9f
8:  xor eax, eax
9:  EPILOGUE

# query(LV*) -> rax ptr, rdx len: its search text without the blanks around it
query:
    PROLOGUE
    lea rdi, [rdi + LV_tf]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call trim
    EPILOGUE

# ---------- building ----------

# sig_make(LV*, out 80 bytes): what a build depends on
sig_make:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rip + agst_gen]
    mov [r12], rax
    mov rax, [rip + aglist_gen]
    mov [r12 + 8], rax
    call agents_rows_vec
    mov [r12 + 16], rax
    mov [r12 + 24], rdx
    xor r13d, r13d              # the programs' states
    xor r14d, r14d
1:  mov rdi, r14
    call agent_live_at
    test rax, rax
    jz 2f
    mov rcx, [rax + AL_as]
    imul r13, r13, 31
    add r13, rcx
    mov ecx, [rax + AL_state]
    imul r13, r13, 31
    add r13, rcx
    inc r14
    jmp 1b
2:  mov [r12 + 32], r13
    mov rax, [rbx + LV_tf + TF_revision]
    mov [r12 + 40], rax
    call days
    mov ecx, [rbx + LV_kind]
    shl rax, 8
    or rax, rcx
    mov ecx, [rip + g_pmt + 4*MI_48]
    shl rcx, 16
    or rax, rcx
    mov ecx, [rip + g_pmt + 4*MI_32]
    shl rcx, 40
    or rax, rcx
    mov [r12 + 48], rax
    call time_now
    xor edx, edx
    mov ecx, 3600
    div rcx
    mov [r12 + 56], rax
    call agents_viewed
    mov [r12 + 64], rax
    mov eax, [rip + drag_on]
    mov [r12 + 72], rax
    EPILOGUE

# ensure(LV*): built for what it shows now (only when that changed)
ensure:
    PROLOGUE 80
    mov rbx, rdi
    mov rdi, rbx
    mov rsi, rsp
    call sig_make
    xor ecx, ecx
1:  cmp ecx, 80
    jae 9f
    mov rax, [rsp + rcx]
    cmp rax, [rbx + LV_sig + rcx]
    jne 2f
    add ecx, 8
    jmp 1b
2:  xor ecx, ecx
3:  mov rax, [rsp + rcx]
    mov [rbx + LV_sig + rcx], rax
    add ecx, 8
    cmp ecx, 80
    jb 3b
    mov rdi, rbx
    call build
9:  EPILOGUE

# build(LV*): its entries (DE) from the sessions listed: its kind, the status filter and the search keep a
#   session; a section takes it; the sections are laid out in their order with their headers
build:
    PROLOGUE 64
    mov rbx, rdi
    inc dword ptr [rbx + LV_built]
    call agst_load
    mov qword ptr [rbx + LV_rows + VEC_len], 0
    mov qword ptr [rip + bk + VEC_len], 0
    lea rdi, [rbx + LV_cnt]
    xor esi, esi
    mov edx, 32
    call memset
    mov rdi, rbx
    call query
    mov [rsp], rax              # the search
    mov [rsp + 8], rdx
    call agst_filter
    mov [rsp + 16], eax
    call agst_groups
    mov rax, [rax + VEC_len]
    mov [rsp + 20], eax         # groups
    xor r12d, r12d              # the sessions
.Lb_next:
    mov rdi, r12
    call agents_row_at
    cmp r12, rdx
    jae .Lb_sections
    mov [rsp + 24], r12d
    inc r12
    test rax, rax
    jz .Lb_next
    mov r13, rax
    mov eax, [rbx + LV_kind]
    test eax, eax
    jz 1f
    cmp [r13 + AS_kind], eax
    jne .Lb_next
1:  mov rdi, r13
    call agst_of
    mov r14d, eax               # flags
    mov r15d, edx               # group
    mov rdi, r13
    mov esi, r14d
    call archived
    mov [rsp + 28], eax
    mov rdi, r13                # the counts: the sessions not archived, before the filter and the search
    call status_of
    mov [rsp + 32], eax
    mov rdi, r13
    call is_open
    mov [rsp + 36], eax
    cmp dword ptr [rsp + 28], 0
    je 2f
    inc dword ptr [rbx + LV_cnt + CN_ARCH]
    jmp 3f
2:  mov eax, [rsp + 32]
    lea rcx, [rbx + LV_cnt + CN_DONE]
    cmp eax, ST_WAIT
    jne 21f
    lea rcx, [rbx + LV_cnt + CN_NEEDS]
21: cmp eax, ST_RUN
    jne 22f
    lea rcx, [rbx + LV_cnt + CN_WORK]
22: inc dword ptr [rcx]
    lea rcx, [rbx + LV_cnt + CN_CLOSED]
    cmp dword ptr [rsp + 36], 0
    je 23f
    lea rcx, [rbx + LV_cnt + CN_OPEN]
23: inc dword ptr [rcx]
    cmp eax, ST_IDLE
    je 3f
    inc dword ptr [rbx + LV_cnt + CN_ACTIVE]
3:  mov ecx, [rsp + 16]         # the filter
    mov edi, [rsp + 32]
    mov esi, [rsp + 36]
    call filter_keeps
    test eax, eax
    jz .Lb_next
    cmp qword ptr [rsp + 8], 0  # the search: the title it shows
    je 4f
    mov rdi, r13
    call title_of
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    call str_ifind
    test rax, rax
    js .Lb_next
4:  inc dword ptr [rbx + LV_cnt + CN_MATCH]
    mov eax, [rsp + 20]         # its section
    inc eax
    cmp dword ptr [rsp + 28], 0
    jne 5f
    dec eax
    test r15d, r15d
    jz 5f
    mov edi, r15d
    call group_index
    test eax, eax
    jns 5f
    mov eax, [rsp + 20]
5:  mov [rsp + 40], eax
    lea rdi, [rip + bk]
    mov esi, BK_SIZE
    call vec_push
    mov [rax + BK_as], r13
    mov ecx, [rsp + 24]
    mov [rax + BK_idx], ecx
    mov ecx, [rsp + 40]
    mov [rax + BK_sec], ecx
    jmp .Lb_next
.Lb_sections:
    # counting sort by section (the order of the sessions stays within each)
    mov r14d, [rsp + 20]
    add r14d, 2                 # sections
    mov qword ptr [rip + secs + VEC_len], 0
    xor r12d, r12d
6:  cmp r12d, r14d
    jae 61f
    lea rdi, [rip + secs]
    mov esi, 8
    call vec_push
    inc r12d
    jmp 6b
61: mov r15, [rip + secs + VEC_ptr]
    xor r12d, r12d
62: cmp r12, [rip + bk + VEC_len]
    jae 63f
    imul rax, r12, BK_SIZE
    add rax, [rip + bk + VEC_ptr]
    mov ecx, [rax + BK_sec]
    inc dword ptr [r15 + rcx*8]
    inc r12
    jmp 62b
63: xor eax, eax                # first places
    xor r12d, r12d
64: cmp r12d, r14d
    jae 65f
    mov [r15 + r12*8 + 4], eax
    add eax, [r15 + r12*8]
    inc r12d
    jmp 64b
65: mov r13, [rip + bk + VEC_len]
    lea rdi, [rip + bk2]
    mov rsi, r13
    imul rsi, rsi, BK_SIZE
    call vec_reserve_len
    xor r12d, r12d
66: cmp r12, r13
    jae 67f
    imul rax, r12, BK_SIZE
    add rax, [rip + bk + VEC_ptr]
    mov ecx, [rax + BK_sec]
    mov edx, [r15 + rcx*8 + 4]
    inc dword ptr [r15 + rcx*8 + 4]
    imul rdx, rdx, BK_SIZE
    add rdx, [rip + bk2 + VEC_ptr]
    mov rcx, [rax]
    mov [rdx], rcx
    mov rcx, [rax + 8]
    mov [rdx + 8], rcx
    inc r12
    jmp 66b
67: # the entries, section by section
    mov dword ptr [rsp + 44], 0  # y
    xor r12d, r12d              # where a section's sessions begin in bk2
    mov dword ptr [rsp + 48], 0  # section
    mov eax, [rsp + 8]          # a search or a filter shows every section open, and no empty header
    or eax, [rsp + 16]
    mov [rsp + 52], eax
    call agst_show
    mov [rsp + 56], eax
.Lb_sec:
    mov eax, [rsp + 48]
    cmp eax, r14d
    jae .Lb_end
    mov r15, [rip + secs + VEC_ptr]
    mov r13d, [r15 + rax*8]     # its count
    mov ecx, [rsp + 20]
    cmp eax, ecx
    jae 7f
    cmp dword ptr [rsp + 52], 0  # a group: its header, also empty (not while searching or filtering)
    je 71f
    test r13d, r13d
    jz .Lb_sec_next
71: call agst_groups
    mov ecx, [rsp + 48]
    imul rcx, rcx, SGR_SIZE
    add rcx, [rax + VEC_ptr]
    mov edx, [rcx + SGR_id]
    mov eax, 1                  # open unless collapsed
    test dword ptr [rcx + SGR_flags], SGRF_COLLAPSED
    jz 72f
    xor eax, eax
72: cmp dword ptr [rsp + 52], 0
    je 73f
    mov eax, 1
73: mov esi, DK_GROUP
    jmp 8f
7:  test r13d, r13d             # Ungrouped (only with groups), Archived
    jz .Lb_sec_next
    jne 74f
74: cmp eax, ecx
    jne 75f
    cmp dword ptr [rsp + 20], 0
    je .Lb_rows_open            # no groups: the sessions without a header
    xor edx, edx
    mov eax, 1
    test dword ptr [rsp + 56], SH_UNGROUPED_SHUT
    jz 76f
    xor eax, eax
76: mov esi, DK_UNGROUPED
    jmp 77f
75: xor edx, edx
    xor eax, eax
    test dword ptr [rsp + 56], SH_ARCHIVED_OPEN
    jz 78f
    mov eax, 1
78: mov esi, DK_ARCHIVED
77: cmp dword ptr [rsp + 52], 0
    je 8f
    mov eax, 1
8:  # a header: esi kind, edx group id, eax open
    mov [rsp + 60], eax
    mov rdi, rbx
    mov ecx, r13d
    mov r8d, eax
    mov r9d, [rsp + 44]
    call add_header
    mov [rsp + 44], eax
    cmp dword ptr [rsp + 60], 0
    je .Lb_sec_next
.Lb_rows_open:
    xor r15d, r15d              # its sessions
81: cmp r15d, r13d
    jae .Lb_sec_next
    lea eax, [r12 + r15]
    imul rax, rax, BK_SIZE
    add rax, [rip + bk2 + VEC_ptr]
    mov rdi, rbx
    mov rsi, [rax + BK_as]
    mov edx, [rax + BK_idx]
    mov ecx, [rsp + 44]
    call add_row
    mov [rsp + 44], eax
    inc r15d
    jmp 81b
.Lb_sec_next:
    add r12d, r13d
    inc dword ptr [rsp + 48]
    jmp .Lb_sec
.Lb_end:
    cmp qword ptr [rbx + LV_rows + VEC_len], 0
    jne 9f
    cmp dword ptr [rsp + 52], 0  # a search or a filter that left nothing says so
    je 9f
    lea rdi, [rbx + LV_rows]
    mov esi, DE_SIZE
    call vec_push
    mov dword ptr [rax + DE_kind], DK_EMPTY
    mov ecx, [rsp + 44]
    mov [rax + DE_y], ecx
    PM edx, MI_40
    mov [rax + DE_h], edx
    add [rsp + 44], edx
9:  mov eax, [rsp + 44]
    mov [rbx + LV_total], eax
    EPILOGUE

# vec_reserve_len(VEC*, bytes): its buffer holds that many bytes (its length is not kept)
vec_reserve_len:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, [rbx + VEC_cap]
    jbe 9f
    lea rsi, [r12 + 64]
    mov [rbx + VEC_cap], rsi
    mov rdi, [rbx + VEC_ptr]
    call mem_realloc
    mov [rbx + VEC_ptr], rax
9:  EPILOGUE

# add_header(LV*, kind, group id, count, open, y) -> eax y after it
add_header:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    mov [rsp], r9d
    lea rdi, [rbx + LV_rows]
    mov esi, DE_SIZE
    call vec_push
    mov [rax + DE_kind], r12d
    mov [rax + DE_aux], r13d
    mov [rax + DE_count], r14d
    mov [rax + DE_flags], r15d
    mov ecx, [rsp]
    mov [rax + DE_y], ecx
    PM edx, MI_32
    mov [rax + DE_h], edx
    lea eax, [rcx + rdx]
    EPILOGUE

# add_row(LV*, AS*, index, y) -> eax y after it
add_row:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    lea rdi, [rbx + LV_rows]
    mov esi, DE_SIZE
    call vec_push
    mov dword ptr [rax + DE_kind], DK_ROW
    mov [rax + DE_as], r12
    mov [rax + DE_aux], r13d
    mov [rax + DE_y], r14d
    call row_h
    mov ecx, r14d
    mov [rax + DE_h], edx       # (row_h leaves rax: the entry)
    lea eax, [rcx + rdx]
    EPILOGUE

# row_h() -> edx a row's height (keeps rax)
row_h:
    PM edx, MI_48
    add edx, [rip + g_pmt + 4*MI_8]
    ret

# group_index(id) -> eax its index among the groups, -1 when there is none
group_index:
    push rbx
    mov ebx, edi
    call agst_groups
    mov rcx, [rax + VEC_ptr]
    mov r8, [rax + VEC_len]
    xor eax, eax
1:  cmp rax, r8
    jae 2f
    imul rdx, rax, SGR_SIZE
    cmp [rcx + rdx + SGR_id], ebx
    je 3f
    inc rax
    jmp 1b
2:  mov eax, -1
3:  pop rbx
    ret

# filter_keeps(status ST_*, open, filter LF_* in ecx) -> eax 1 when the status filter keeps the session: a
#   status checked (needs input, working, completed: any of them) and a tab state checked (open, closed),
#   each group only when something in it is checked; Active: needs input, working or unread
filter_keeps:
    mov eax, 1
    test ecx, ecx
    jz 9f
    test ecx, LF_ACTIVE
    jz 1f
    cmp edi, ST_IDLE
    je 8f
1:  test ecx, LF_NEEDS | LF_WORKING | LF_DONE
    jz 4f
    mov edx, LF_DONE
    cmp edi, ST_WAIT
    jne 2f
    mov edx, LF_NEEDS
2:  cmp edi, ST_RUN
    jne 3f
    mov edx, LF_WORKING
3:  test ecx, edx
    jz 8f
4:  test ecx, LF_OPEN | LF_CLOSED
    jz 9f
    mov edx, LF_CLOSED
    test esi, esi
    jz 5f
    mov edx, LF_OPEN
5:  test ecx, edx
    jnz 9f
8:  xor eax, eax
9:  ret

# ---------- the whole list ----------

# FN aglist_need_all(): a search or a filter wants every session: the page grows to all of them, once
FN aglist_need_all
    PROLOGUE
    call agents_page_full
    test eax, eax
    jnz 9f
    mov edi, ALL_ROWS
    call agents_page_want
9:  EPILOGUE

# FN aglist_tools(right, y, h, left) -> eax the left edge: the list's header buttons, right to left: New group,
#   Filter by status (an accent while a filter is on), Search sessions; the ones that would cross left stay out
FN aglist_tools
    PROLOGUE 16
    mov r12d, edi               # right
    mov r13d, esi
    mov r14d, edx
    mov [rsp], ecx              # left
    PM ebx, MI_28
    mov eax, r12d
    sub eax, ebx
    cmp eax, [rsp]
    jl 9f
    mov r12d, eax
    mov edi, ID_AGL + IDT_NEWGROUP
    mov esi, r12d
    mov edx, r13d
    mov ecx, ebx
    mov r8d, ebx
    mov r9d, IC_FOLDER_PLUS
    call ag_icon_btn
    mov r15d, eax
    mov edi, ID_AGL + IDT_NEWGROUP
    mov esi, r12d
    lea edx, [r13 + rbx]
    mov ecx, ebx
    mov r8d, r15d
    lea r9, [rip + .Lt_newgroup]
    call tip_note_text
    test r15d, UB_CLICK
    jz 1f
    call new_group_rename
1:  mov eax, r12d
    sub eax, ebx
    cmp eax, [rsp]
    jl 9f
    mov r12d, eax
    call agst_filter
    test eax, eax
    jz 2f
    PM eax, MI_RADIUS           # a filter is on: the button stands out
    mov edi, r12d
    mov esi, r13d
    mov edx, ebx
    mov ecx, ebx
    mov r8d, eax
    COLOR r9d, T_SELECTION
    call gfx_round_rect
2:  mov edi, ID_AGL + IDT_FILTER
    mov esi, r12d
    mov edx, r13d
    mov ecx, ebx
    mov r8d, ebx
    mov r9d, IC_FILTER
    call ag_icon_btn
    mov r15d, eax
    mov edi, ID_AGL + IDT_FILTER
    mov esi, r12d
    lea edx, [r13 + rbx]
    mov ecx, ebx
    mov r8d, r15d
    lea r9, [rip + .Lt_filter]
    call tip_note_text
    test r15d, UB_CLICK
    jz 3f
    lea rdi, [rip + lv_panel]
    mov esi, r12d
    lea edx, [r13 + rbx]
    call filter_menu_ask
3:  mov eax, r12d
    sub eax, ebx
    cmp eax, [rsp]
    jl 9f
    mov r12d, eax
    mov edi, ID_AGL + IDT_SEARCH
    mov esi, r12d
    mov edx, r13d
    mov ecx, ebx
    mov r8d, ebx
    mov r9d, IC_SEARCH
    call ag_icon_btn
    mov r15d, eax
    mov edi, ID_AGL + IDT_SEARCH
    mov esi, r12d
    lea edx, [r13 + rbx]
    mov ecx, ebx
    mov r8d, r15d
    lea r9, [rip + .Lt_search]
    call tip_note_text
    test r15d, UB_CLICK
    jz 9f
    lea rdi, [rip + lv_panel]
    call search_show
9:  mov eax, r12d
    EPILOGUE

# search_show(LV*): its search row shows, with the keys
search_show:
    mov dword ptr [rdi + LV_search], 1
    mov dword ptr [rdi + LV_focus], 1
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov dword ptr [rip + g_dirty], 1
    ret

# FN aglist_draw(x, y, w, h): the panel's list in that area (under its header, above its footer)
FN aglist_draw
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    lea rbx, [rip + lv_panel]
    mov dword ptr [rbx + LV_kind], 0
    mov dword ptr [rbx + LV_id], ID_AGL
    cmp qword ptr [rip + breaker], 0    # the conversation a restart did not open again: why, and Open it anyway
    je 1f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    call breaker_band
    add [rsp + 4], eax
    sub [rsp + 12], eax
1:  mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call lv_draw
    EPILOGUE

# FN aglist_after(): the end of the panel's list frame (list_draw): what its clicks asked for (after_frame)
FN aglist_after
    jmp after_frame

# breaker_band(x, y, w) -> eax its height: "TITLE was not reopened. It did not finish opening the last N
#   times." and "Open it anyway"
breaker_band:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    PM eax, MI_48
    mov [rsp + 12], eax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, eax
    COLOR r8d, T_HOVER
    call gfx_fill
    lea rdi, [rip + dsb]
    call sb_clear
    mov rdi, [rip + breaker]
    call title_of
    lea rdi, [rip + dsb]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + dsb]
    lea rsi, [rip + .Lbr1]
    call sb_push_cstr
    call agst_tries
    lea rdi, [rip + dsb]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rip + dsb]
    lea rsi, [rip + .Lbr2]
    call sb_push_cstr
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_16]
    mov edx, [rsp + 4]
    PM ecx, MI_24
    mov r8, [rip + dsb + SB_ptr]
    mov r9, [rip + dsb + SB_len]
    COLOR r10d, T_FG
    mov r11d, [rsp + 8]
    sub r11d, [rip + g_pmt + 4*MI_32]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    lea rdi, [rip + .Lbr_open]
    call strlen
    mov rdx, rax
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lbr_open]
    call text_width
    add eax, [rip + g_pmt + 4*MI_16]
    mov r12d, eax
    mov edi, ID_AGL + IDT_REOPEN
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_24]
    mov ecx, r12d
    PM r8d, MI_24
    call ui_btn
    mov r13d, eax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_24]
    mov ecx, r12d
    PM r8d, MI_24
    lea r9, [rip + .Lbr_open]
    COLOR eax, T_ACCENT
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    test r13d, UB_CLICK
    jz 9f
    call reopen_anyway
9:  mov eax, [rsp + 12]
    EPILOGUE

# reopen_anyway(): "Open it anyway": the conversation the breaker kept closed opens (after the frame)
reopen_anyway:
    mov rax, [rip + breaker]
    test rax, rax
    jz 1f
    mov qword ptr [rip + breaker], 0
    mov [rip + pend_open], rax
    xor edi, edi
    jmp agst_set_tries
1:  ret

# lv_draw(LV*, x, y, w, h): a list in that area: its search row when it shows, then its entries
lv_draw:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov rdi, rbx
    call query
    test rdx, rdx
    jnz 0f
    call agst_filter
    test eax, eax
    jz 1f
0:  call aglist_need_all        # a search or a filter: every session
1:  cmp dword ptr [rbx + LV_search], 0
    je 2f
    mov rdi, rbx                # the search row
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call search_row
    add [rsp + 4], eax
    sub [rsp + 12], eax
2:  mov rdi, rbx
    call ensure
    mov eax, [rsp]
    mov [rbx + LV_ax], eax
    mov eax, [rsp + 4]
    mov [rbx + LV_ay], eax
    mov eax, [rsp + 8]
    mov [rbx + LV_aw], eax
    mov eax, [rsp + 12]
    mov [rbx + LV_ah], eax
    mov edi, [rsp]              # the wheel
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call ui_in
    test eax, eax
    jz 3f
    mov eax, [rip + g_scroll_y]
    add [rbx + LV_scroll], eax
3:  cmp dword ptr [rbx + LV_reveal], 0
    je 31f
    mov dword ptr [rbx + LV_reveal], 0
    mov rdi, rbx
    call reveal_sel
31: mov eax, [rbx + LV_total]   # the scroll within the entries
    sub eax, [rsp + 12]
    jns 4f
    xor eax, eax
4:  cmp [rbx + LV_scroll], eax
    jle 5f
    mov [rbx + LV_scroll], eax
5:  cmp dword ptr [rbx + LV_scroll], 0
    jge 6f
    mov dword ptr [rbx + LV_scroll], 0
6:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    mov rdi, rbx                # the first entry in view
    mov esi, [rbx + LV_scroll]
    call entry_at
    mov r12, rax
    mov dword ptr [rip + drop_gid], -1
.Ld_next:
    cmp r12, [rbx + LV_rows + VEC_len]
    jae .Ld_done
    imul r13, r12, DE_SIZE
    add r13, [rbx + LV_rows + VEC_ptr]
    mov eax, [r13 + DE_y]
    sub eax, [rbx + LV_scroll]
    add eax, [rsp + 4]
    mov r14d, eax               # its y on screen
    mov ecx, [rsp + 4]
    add ecx, [rsp + 12]
    cmp r14d, ecx
    jge .Ld_done
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, [rsp]
    mov r8d, r14d
    mov r9d, [rsp + 8]
    cmp dword ptr [r13 + DE_kind], DK_ROW
    jne 7f
    call draw_row
    jmp 8f
7:  call draw_header
8:  inc r12
    jmp .Ld_next
.Ld_done:
    call gfx_clip_pop
    mov eax, [rbx + LV_total]   # a scrollbar when the entries are taller than the area
    cmp eax, [rsp + 12]
    jle 9f
    PM ecx, MI_6
    mov edi, [rbx + LV_id]
    add edi, IDT_SCROLL
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, ecx
    mov edx, [rsp + 4]
    mov r8d, [rsp + 12]
    lea r9, [rbx + LV_scroll]
    mov eax, [rsp + 12]
    push rax
    push qword ptr [rbx + LV_total]
    call ui_scrollbar
    add rsp, 16
9:  EPILOGUE

# entry_at(LV*, y) -> rax the first entry whose bottom is below y (binary search; the length when none)
entry_at:
    mov r8, [rdi + LV_rows + VEC_ptr]
    xor eax, eax
    mov rcx, [rdi + LV_rows + VEC_len]
1:  cmp rax, rcx
    jae 9f
    lea rdx, [rax + rcx]
    shr rdx, 1
    imul r9, rdx, DE_SIZE
    mov r10d, [r8 + r9 + DE_y]
    add r10d, [r8 + r9 + DE_h]
    cmp r10d, esi
    jg 2f
    lea rax, [rdx + 1]
    jmp 1b
2:  mov rcx, rdx
    jmp 1b
9:  ret

# reveal_sel(LV*): the selected session's row in view
reveal_sel:
    PROLOGUE
    mov rbx, rdi
    mov rsi, [rbx + LV_sel]
    call entry_of
    test rax, rax
    js 9f
    imul rax, rax, DE_SIZE
    add rax, [rbx + LV_rows + VEC_ptr]
    mov ecx, [rax + DE_y]
    cmp ecx, [rbx + LV_scroll]
    jge 1f
    mov [rbx + LV_scroll], ecx
    jmp 9f
1:  add ecx, [rax + DE_h]
    sub ecx, [rbx + LV_ah]
    cmp ecx, [rbx + LV_scroll]
    jle 9f
    mov [rbx + LV_scroll], ecx
9:  EPILOGUE

# entry_of(LV*, AS*) -> rax its row's entry, -1 when it has none
entry_of:
    mov r8, [rdi + LV_rows + VEC_ptr]
    mov rcx, [rdi + LV_rows + VEC_len]
    xor eax, eax
    test rsi, rsi
    jz 8f
1:  cmp rax, rcx
    jae 8f
    imul rdx, rax, DE_SIZE
    cmp dword ptr [r8 + rdx + DE_kind], DK_ROW
    jne 2f
    cmp [r8 + rdx + DE_as], rsi
    je 9f
2:  inc rax
    jmp 1b
8:  mov rax, -1
9:  ret

# search_row(LV*, x, y, w) -> eax its height: the field "Search sessions…" and, with text, "Clear search"
search_row:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    PM eax, MI_40
    mov [rsp + 12], eax
    mov rax, [rip + ag_fui]
    mov [rbx + LV_tf + TF_face], rax
    mov eax, [rbx + LV_id]
    add eax, IDT_FIELD
    mov [rbx + LV_tf + TF_id], eax
    PM r12d, MI_28              # the clear button's room
    mov rdi, rbx
    call query
    mov r13d, 0
    test rdx, rdx
    jz 1f
    mov r13d, r12d
1:  mov eax, [rsp + 8]
    sub eax, [rip + g_pmt + 4*MI_16]
    sub eax, r13d
    mov [rsp + 16], eax         # the field's width
    xor r9d, r9d
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    jne 2f
    mov r9d, [rbx + LV_focus]
    cmp dword ptr [rip + ren_kind], 0
    je 2f
    xor r9d, r9d
2:  lea rdi, [rbx + LV_tf]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_4]
    mov ecx, [rsp + 16]
    mov r8d, [rsp + 12]
    sub r8d, [rip + g_pmt + 4*MI_8]
    lea rax, [rip + .Lph_search]
    push rax
    push rax
    call ui_textarea
    add rsp, 16
    test eax, UB_PRESS
    jz 3f
    mov dword ptr [rbx + LV_focus], 1
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
3:  test r13d, r13d
    jz 9f
    mov edi, [rbx + LV_id]
    add edi, IDT_CLEAR
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, r12d
    sub esi, [rip + g_pmt + 4*MI_4]
    mov edx, [rsp + 4]
    mov eax, [rsp + 12]
    sub eax, r12d
    sar eax, 1
    add edx, eax
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_CLOSE
    mov [rsp + 20], esi
    mov [rsp + 24], edx
    call ag_icon_btn
    mov r14d, eax
    mov edi, [rbx + LV_id]
    add edi, IDT_CLEAR
    mov esi, [rsp + 20]
    mov edx, [rsp + 24]
    add edx, r12d
    mov ecx, r12d
    mov r8d, r14d
    lea r9, [rip + .Lt_clear]
    call tip_note_text
    test r14d, UB_CLICK
    jz 9f
    mov rdi, rbx
    call search_clear
9:  mov eax, [rsp + 12]
    EPILOGUE

# search_clear(LV*): its search text goes (the field keeps the keys)
search_clear:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rbx + LV_tf]
    call tf_clear
    inc qword ptr [rbx + LV_tf + TF_revision]
    mov dword ptr [rbx + LV_scroll], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ---------- a row ----------

# draw_row(LV*, entry, DE*, x, y, w): a session's row: its dot (ring when another program has it), its title
#   (the search's match marked) or the rename field, its badges, model and age; hovered or selected: Rename and
#   Archive (Unarchive); a click opens it, Cmd/Ctrl+click and Shift+click select, a right click asks the menu,
#   a press and a move drag it
draw_row:
    PROLOGUE 96
    mov rbx, rdi
    mov [rsp], rsi              # entry
    mov r15, rdx
    mov [rsp + 8], ecx          # x
    mov [rsp + 12], r8d         # y
    mov [rsp + 16], r9d         # w
    mov r14, [r15 + DE_as]
    mov eax, [r15 + DE_h]
    mov [rsp + 20], eax         # h
    mov eax, [rsp]
    and eax, 0x7fff
    add eax, [rbx + LV_id]
    mov [rsp + 24], eax         # its id
    mov edi, eax
    mov esi, [rsp + 8]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 16]
    mov r8d, [rsp + 20]
    call ui_btn
    mov [rsp + 28], eax
    # the background: selected, in the selection, hovered
    xor r12d, r12d
    cmp [rbx + LV_sel], r14
    jne 1f
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    jne 1f
    COLOR r12d, T_SELECTION
1:  mov rdi, rbx
    mov rsi, r14
    call in_multi
    test eax, eax
    jz 2f
    COLOR r12d, T_SELECTION
2:  test r12d, r12d
    jnz 3f
    test dword ptr [rsp + 28], UB_HOVER
    jz 4f
    COLOR r12d, T_HOVER
3:  PM eax, MI_6
    mov edi, [rsp + 8]
    add edi, eax
    mov esi, [rsp + 12]
    add esi, [rip + g_pmt + 4*MI_2]
    mov edx, [rsp + 16]
    sub edx, eax
    sub edx, eax
    mov ecx, [rsp + 20]
    sub ecx, [rip + g_pmt + 4*MI_4]
    PM r8d, MI_RADIUS
    mov r9d, r12d
    call gfx_round_rect
4:  # the dot
    mov rdi, r14
    call status_of
    mov [rsp + 32], eax
    mov rdi, r14
    call held_by_other
    mov [rsp + 36], eax
    PM ecx, MI_8
    mov edi, [rsp + 8]
    add edi, [rip + g_pmt + 4*MI_16]
    mov esi, [rsp + 12]
    add esi, [rip + g_pmt + 4*MI_16]
    mov [rsp + 40], edi
    mov [rsp + 44], esi
    cmp dword ptr [rsp + 36], 0
    je 5f
    PM eax, MI_3                # a ring around it: another program has it open
    sub edi, eax
    sub esi, eax
    lea edx, [rcx + rax*2]
    mov ecx, edx
    mov r8d, edx
    shr r8d, 1
    COLOR r9d, T_ACCENT
    call gfx_round_rect
    PM eax, MI_2
    PM ecx, MI_8
    add ecx, [rip + g_pmt + 4*MI_2]
    mov edi, [rsp + 40]
    sub edi, [rip + g_pmt + 4*MI_1]
    mov esi, [rsp + 44]
    sub esi, [rip + g_pmt + 4*MI_1]
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    COLOR r9d, T_PANEL
    call gfx_round_rect
5:  PM ecx, MI_8
    mov edi, [rsp + 40]
    mov esi, [rsp + 44]
    mov edx, ecx
    mov r8d, ecx
    shr r8d, 1
    mov rdi, rdi
    mov eax, [rsp + 32]
    COLOR r9d, T_BORDER
    cmp eax, ST_RUN
    jne 51f
    COLOR r9d, T_SUCCESS
51: cmp eax, ST_WAIT
    jne 52f
    COLOR r9d, T_WARNING
52: cmp eax, ST_UNREAD
    jne 53f
    push rdi
    push rsi
    push rdx
    push rcx
    mov edi, [r14 + AS_kind]    # the unread dot in the agent's own colour (DRV_brand), else the accent
    call agent_drv_for_kind
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    COLOR r9d, T_ACCENT
    test rax, rax
    jz 53f
    mov rax, [rax + DRV_brand]
    test eax, eax
    jz 53f
    mov r9d, eax
53: mov edx, ecx
    call gfx_round_rect
    mov rdi, r14                # the dot's tip
    mov esi, [rsp + 32]
    mov edx, [rsp + 36]
    call dot_tip
    test rax, rax
    jz 54f
    mov r9, rax
    mov edi, [rsp + 24]
    mov esi, [rsp + 8]
    mov edx, [rsp + 12]
    add edx, [rip + g_pmt + 4*MI_32]
    PM ecx, MI_32
    mov r8d, [rsp + 28]
    PM eax, MI_32               # only over the dot
    mov r10d, [rip + g_mx]
    sub r10d, [rsp + 8]
    cmp r10d, eax
    jge 54f
    call tip_note_text
54: # the hover actions' room
    xor eax, eax
    mov dword ptr [rsp + 48], 0
    test dword ptr [rsp + 28], UB_HOVER
    jnz 55f
    cmp [rbx + LV_sel], r14
    jne 56f
55: PM eax, MI_28
    add eax, eax
    mov [rsp + 48], eax
56: # the title, or the rename field
    cmp dword ptr [rip + ren_kind], RN_SESSION
    jne 6f
    cmp [rip + ren_as], r14
    jne 6f
    mov edi, [rsp + 8]
    add edi, [rip + g_pmt + 4*MI_28]
    mov esi, [rsp + 12]
    add esi, [rip + g_pmt + 4*MI_2]
    mov edx, [rsp + 16]
    sub edx, [rip + g_pmt + 4*MI_40]
    PM ecx, MI_28
    mov r8, rbx
    call rename_field
    jmp 7f
6:  mov rdi, r14
    call title_of
    mov [rsp + 56], rax
    mov [rsp + 64], rdx
    mov eax, [rsp + 16]
    sub eax, [rip + g_pmt + 4*MI_48]
    sub eax, [rsp + 48]
    mov [rsp + 72], eax         # the title's room
    mov rdi, rbx                # the matches, marked behind it
    mov rsi, [rsp + 56]
    mov rdx, [rsp + 64]
    mov ecx, [rsp + 8]
    add ecx, [rip + g_pmt + 4*MI_32]
    mov r8d, [rsp + 12]
    add r8d, [rip + g_pmt + 4*MI_8]
    mov r9d, [rsp + 72]
    call mark_matches
61: mov rdi, [rip + ag_fui]
    mov esi, [rsp + 8]
    add esi, [rip + g_pmt + 4*MI_32]
    mov edx, [rsp + 12]
    add edx, [rip + g_pmt + 4*MI_6]
    PM ecx, MI_24
    mov r8, [rsp + 56]
    mov r9, [rsp + 64]
    COLOR r10d, T_FG
    mov r11d, [rsp + 72]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
7:  # the meta line: the agent's badge, the worktree's, then model and age
    mov rdi, rbx
    mov rsi, r14
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 16]
    mov r9d, [rsp + 24]
    call meta_line
    # the hover actions: Rename, Archive or Unarchive
    cmp dword ptr [rsp + 48], 0
    je 8f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, [rsp]
    mov ecx, [rsp + 8]
    add ecx, [rsp + 16]
    sub ecx, [rip + g_pmt + 4*MI_8]
    sub ecx, [rsp + 48]
    mov r8d, [rsp + 12]
    add r8d, [rip + g_pmt + 4*MI_4]
    call row_actions
    test eax, eax
    jnz 9f                      # an action took the click
8:  mov eax, [rsp + 28]         # the pointer
    test eax, UB_RPRESS
    jz 81f
    mov rdi, rbx
    mov rsi, r14
    call menu_row_ask
    jmp 9f
81: test eax, UB_PRESS
    jz 82f
    cmp qword ptr [rip + drag_as], 0
    jne 82f
    mov [rip + drag_as], r14    # it may be dragged
    mov eax, [rip + g_mx]
    mov [rip + drag_x], eax
    mov eax, [rip + g_my]
    mov [rip + drag_y], eax
    mov dword ptr [rip + drag_on], 0
82: test dword ptr [rsp + 28], UB_CLICK
    jz 9f
    cmp dword ptr [rip + drag_on], 0
    jne 9f                      # a drag's release is the drop's
    mov rdi, rbx
    mov rsi, r14
    call row_click
9:  EPILOGUE

# mark_matches(LV*, title ptr, len, x, y, room): every match of the list's search in the title, marked behind
#   it (T_MATCH), within room pixels from x
mark_matches:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi                # the title
    mov r13, rdx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov [rsp + 8], r9d
    mov rdi, rbx
    call query
    test rdx, rdx
    jz 9f
    mov [rsp + 16], rax         # the search
    mov [rsp + 24], rdx
    xor r14d, r14d              # where to look from
1:  cmp r14, r13
    jae 9f
    lea rdi, [r12 + r14]
    mov rsi, r13
    sub rsi, r14
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    call str_ifind
    test rax, rax
    js 9f
    lea r15, [r14 + rax]        # the match's offset in the title
    mov rdi, [rip + ag_fui]
    mov rsi, r12
    mov rdx, r15
    call text_width
    mov [rsp + 32], eax
    cmp eax, [rsp + 8]
    jge 9f                      # past the room
    mov rdi, [rip + ag_fui]
    lea rsi, [r12 + r15]
    mov rdx, [rsp + 24]
    call text_width
    mov edx, eax
    mov ecx, [rsp + 32]
    add ecx, edx
    cmp ecx, [rsp + 8]
    jle 2f
    mov edx, [rsp + 8]
    sub edx, [rsp + 32]
2:  mov edi, [rsp]
    add edi, [rsp + 32]
    mov esi, [rsp + 4]
    PM ecx, MI_20
    PM r8d, MI_2
    COLOR r9d, T_MATCH
    call gfx_round_rect
    mov r14, r15
    add r14, [rsp + 24]
    jmp 1b
9:  EPILOGUE

# dot_tip(AS*, status, held) -> rax the dot's tip (in lsb), or 0: who has it, then what it does
dot_tip:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    lea rdi, [rip + lsb]
    call sb_clear
    lea rsi, [rip + .Lt_other]
    test r13d, r13d
    jnz 1f
    mov rdi, rbx
    call is_open
    lea rsi, [rip + .Lt_here]
    test eax, eax
    jnz 1f
    lea rsi, [rip + .Lt_unread]
    cmp r12d, ST_UNREAD
    je 1f
    lea rsi, [rip + .Lt_awaiting0]
    cmp r12d, ST_WAIT
    je 2f
    lea rsi, [rip + .Lt_running0]
    cmp r12d, ST_RUN
    je 2f
    xor eax, eax
    EPILOGUE
1:  lea rdi, [rip + lsb]
    call sb_push_cstr
    lea rsi, [rip + .Lt_awaiting]
    cmp r12d, ST_WAIT
    je 2f
    lea rsi, [rip + .Lt_running]
    cmp r12d, ST_RUN
    jne 3f
2:  lea rdi, [rip + lsb]
    call sb_push_cstr
3:  lea rdi, [rip + lsb]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + lsb + SB_ptr]
    EPILOGUE

# meta_line(LV*, AS*, x, y, w, id): the second line of a row: badges, then " · model · age"
meta_line:
    PROLOGUE 48
    mov rbx, rdi
    mov r14, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 8], r8d
    mov [rsp + 12], r9d
    mov edi, [r14 + AS_kind]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_32]
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_28]
    cmp edi, AS_KIND_EXT
    jne 1f
    mov rdi, r14
    call agents_ext_badge
    jmp 2f
1:  call agents_badge
2:  mov [rsp + 16], eax         # the right edge so far
    mov rdi, [r14 + AS_worktree]
    test rdi, rdi
    jz 3f
    mov esi, eax
    add esi, [rip + g_pmt + 4*MI_6]
    mov [rsp + 20], esi
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_28]
    mov ecx, [rsp]
    add ecx, [rsp + 8]
    sub ecx, esi
    sub ecx, [rip + g_pmt + 4*MI_16]
    call agents_worktree_badge
    mov [rsp + 16], eax
    mov edi, [rsp + 20]         # its whole name in a tip
    mov esi, [rsp + 4]
    add esi, [rip + g_pmt + 4*MI_28]
    mov edx, eax
    sub edx, edi
    PM ecx, MI_20
    call ui_in
    test eax, eax
    jz 3f
    mov edi, [rsp + 12]
    mov esi, [rsp + 20]
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_48]
    mov ecx, [rsp + 16]
    sub ecx, esi
    mov r8d, UB_HOVER
    mov r9, [r14 + AS_worktree]
    call tip_note_text
3:  lea rdi, [rip + dsb]
    call sb_clear
    mov rsi, [r14 + AS_model]
    test rsi, rsi
    jz 4f
    mov rdi, rsi                # (a narrow panel drops the model first)
    call strlen
    mov r12, rax
    mov rdi, [rip + ag_fsmall]
    mov rsi, [r14 + AS_model]
    mov rdx, r12
    call text_width
    add eax, [rsp + 16]
    PM ecx, MI_64
    add eax, ecx
    add eax, ecx
    mov ecx, [rsp]
    add ecx, [rsp + 8]
    cmp eax, ecx
    jg 4f
    lea rdi, [rip + dsb]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    lea rdi, [rip + dsb]
    mov rsi, [r14 + AS_model]
    call sb_push_cstr
4:  lea rdi, [rip + dsb]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    mov rdi, [r14 + AS_mtime]
    call age_text
    lea rdi, [rip + dsb]
    mov rsi, rax
    call sb_push_cstr
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 16]
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_28]
    PM ecx, MI_20
    mov r8, [rip + dsb + SB_ptr]
    mov r9, [rip + dsb + SB_len]
    COLOR r10d, T_MUTED
    mov r11d, [rsp]
    add r11d, [rsp + 8]
    sub r11d, esi
    sub r11d, [rip + g_pmt + 4*MI_16]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    EPILOGUE

# age_text(unix seconds) -> rax cstr (in a static buffer): "now", "5m", "3h", "2d", "4mo", "1y"; the panel's
#   poll redraws it when it changes (agents_label_due)
.bss
age_buf: .zero 32
.text
age_text:
    PROLOGUE
    mov rbx, rdi
    call time_now
    mov r12, rax
    sub rax, rbx
    jns 1f
    xor eax, eax
1:  mov r13, rax
    lea rdi, [rip + age_buf]
    cmp r13, 60
    jae 2f
    lea rsi, [rip + .Lnow]
    call cstr_copy
    lea rdi, [rbx + 60]
    call agents_label_due
    jmp 9f
2:  mov ecx, 60                 # the unit and its letter
    mov r14d, 'm'
    cmp r13, 3600
    jb 3f
    mov ecx, 3600
    mov r14d, 'h'
    cmp r13, 86400
    jb 3f
    mov ecx, 86400
    mov r14d, 'd'
    cmp r13, 86400 * 30
    jb 3f
    mov ecx, 86400 * 30
    mov r14d, 'o'               # months
    cmp r13, 86400 * 365
    jb 3f
    mov ecx, 86400 * 365
    mov r14d, 'y'
3:  mov rax, r13
    xor edx, edx
    div rcx
    mov r15, rax
    inc rax                     # the label changes when the next unit has passed
    imul rax, rcx
    add rax, rbx
    mov rdi, rax
    call agents_label_due
    lea rdi, [rip + age_buf]
    mov rsi, r15
    call fmt_u64
    lea rdi, [rip + age_buf]
    add rdi, rax
    cmp r14d, 'o'
    jne 4f
    lea rsi, [rip + .Lmo]
    call cstr_copy
    jmp 9f
4:  mov [rdi], r14b
    mov byte ptr [rdi + 1], 0
9:  lea rax, [rip + age_buf]
    EPILOGUE

# row_actions(LV*, AS*, entry, x, y) -> eax 1 when one took the click: Rename session, then Archive session or
#   Unarchive session
row_actions:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], ecx
    mov [rsp + 4], r8d
    and edx, 0xfff
    shl edx, 2
    add edx, [rbx + LV_id]
    add edx, IDR_ACT
    mov [rsp + 8], edx
    PM r13d, MI_28
    mov edi, edx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_EDIT
    call ag_icon_btn
    mov r14d, eax
    mov edi, [rsp + 8]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, r13d
    mov ecx, r13d
    mov r8d, r14d
    lea r9, [rip + .Lt_rename]
    call tip_note_text
    test r14d, UB_CLICK
    jz 1f
    mov rdi, rbx
    mov rsi, r12
    call rename_session_begin
    mov eax, 1
    EPILOGUE
1:  mov rdi, r12
    call agst_of
    mov rdi, r12
    mov esi, eax
    call archived
    mov [rsp + 12], eax
    mov edi, [rsp + 8]
    inc edi
    mov esi, [rsp]
    add esi, r13d
    mov edx, [rsp + 4]
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_ARROW_DN
    cmp dword ptr [rsp + 12], 0
    je 2f
    mov r9d, IC_ARROW_UP
2:  call ag_icon_btn
    mov r14d, eax
    mov edi, [rsp + 8]
    inc edi
    mov esi, [rsp]
    add esi, r13d
    mov edx, [rsp + 4]
    add edx, r13d
    mov ecx, r13d
    mov r8d, r14d
    lea r9, [rip + .Lt_archive]
    cmp dword ptr [rsp + 12], 0
    je 3f
    lea r9, [rip + .Lt_unarchive]
3:  call tip_note_text
    xor eax, eax
    test r14d, UB_CLICK
    jz 9f
    mov rdi, r12
    mov esi, [rsp + 12]
    call set_archived
    mov eax, 1
9:  EPILOGUE

# set_archived(AS*, archived now) -> archived now 1: unarchive; 0: archive
set_archived:
    PROLOGUE
    mov rbx, rdi
    test esi, esi
    jz 1f
    mov esi, SF_KEPT            # unarchived by hand: also one archived for its age
    mov edx, SF_ARCH
    call agst_mark
    EPILOGUE
1:  mov esi, SF_ARCH
    mov edx, SF_KEPT
    call agst_mark
    EPILOGUE

# row_click(LV*, AS*): a click on a row: Cmd/Ctrl adds it to the selection or takes it out, Shift selects from
#   the anchor to it; a plain click opens it (after the frame) and ends the selection
row_click:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [rip + g_mods]
    test eax, MOD_CTRL | MOD_SUPER
    jz 1f
    mov rdi, rbx
    mov rsi, r12
    call multi_flip
    mov [rbx + LV_anchor], r12
    mov [rbx + LV_sel], r12
    jmp 9f
1:  test eax, MOD_SHIFT
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    call multi_range
    mov [rbx + LV_sel], r12
    jmp 9f
2:  mov qword ptr [rbx + LV_multi + VEC_len], 0
    mov [rbx + LV_anchor], r12
    mov [rbx + LV_sel], r12
    mov [rip + pend_open], r12
9:  mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov dword ptr [rbx + LV_focus], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# in_multi(LV*, AS*) -> eax 1 when it is in the selection
in_multi:
    mov rcx, [rdi + LV_multi + VEC_ptr]
    mov rdx, [rdi + LV_multi + VEC_len]
    xor eax, eax
1:  cmp rax, rdx
    jae 8f
    cmp [rcx + rax*8], rsi
    je 9f
    inc rax
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# multi_drop(LV*, AS*): out of the selection
multi_drop:
    mov rcx, [rdi + LV_multi + VEC_ptr]
    mov rdx, [rdi + LV_multi + VEC_len]
    xor eax, eax
1:  cmp rax, rdx
    jae 9f
    cmp [rcx + rax*8], rsi
    je 2f
    inc rax
    jmp 1b
2:  dec rdx                     # the last one takes its place
    mov r8, [rcx + rdx*8]
    mov [rcx + rax*8], r8
    mov [rdi + LV_multi + VEC_len], rdx
9:  ret

# multi_flip(LV*, AS*): in the selection, or out of it (the row with the keys joins it first)
multi_flip:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp qword ptr [rbx + LV_multi + VEC_len], 0
    jne 1f
    mov rsi, [rbx + LV_sel]     # Cmd+click after a plain one: both
    test rsi, rsi
    jz 1f
    cmp rsi, r12
    je 1f
    mov rdi, rbx
    call multi_add
1:  mov rdi, rbx
    mov rsi, r12
    call in_multi
    test eax, eax
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    call multi_drop
    EPILOGUE
2:  mov rdi, rbx
    mov rsi, r12
    call multi_add
    EPILOGUE

# multi_add(LV*, AS*)
multi_add:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call in_multi
    test eax, eax
    jnz 9f
    lea rdi, [rbx + LV_multi]
    mov esi, 8
    call vec_push
    mov [rax], r12
9:  EPILOGUE

# multi_range(LV*, AS*): the rows from the anchor (or the selected one) to it are the selection
multi_range:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov qword ptr [rbx + LV_multi + VEC_len], 0
    mov rsi, [rbx + LV_anchor]
    test rsi, rsi
    jnz 1f
    mov rsi, [rbx + LV_sel]
    mov [rbx + LV_anchor], rsi
1:  mov rdi, rbx
    call entry_of
    mov r13, rax
    mov rdi, rbx
    mov rsi, r12
    call entry_of
    mov r14, rax
    test r14, r14
    js 9f
    test r13, r13
    jns 2f
    mov r13, r14
2:  cmp r13, r14
    jle 3f
    xchg r13, r14
3:  cmp r13, r14
    jg 9f
    imul rax, r13, DE_SIZE
    add rax, [rbx + LV_rows + VEC_ptr]
    inc r13
    cmp dword ptr [rax + DE_kind], DK_ROW
    jne 3b
    mov rdi, rbx
    mov rsi, [rax + DE_as]
    call multi_add
    jmp 3b
9:  EPILOGUE

# ---------- headers ----------

# draw_header(LV*, entry, DE*, x, y, w): a section's header: a chevron, its name and count; a click opens or
#   collapses it; a group's double click renames it, its right click (or its ⋯) asks its menu; the archived
#   section's "Unarchive all N sessions"; a dragged row over a group's header or Ungrouped is dropped there;
#   "No sessions found"
draw_header:
    PROLOGUE 64
    mov rbx, rdi
    mov [rsp], rsi
    mov r15, rdx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov [rsp + 16], r9d
    mov eax, [r15 + DE_h]
    mov [rsp + 20], eax
    cmp dword ptr [r15 + DE_kind], DK_EMPTY
    jne 1f
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 8]
    add esi, [rip + g_pmt + 4*MI_16]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 20]
    lea r8, [rip + .Lnone_found]
    COLOR r9d, T_MUTED
    call ui_text_c
    EPILOGUE
1:  mov eax, [rsp]
    and eax, 0x7fff
    add eax, [rbx + LV_id]
    mov [rsp + 24], eax
    mov edi, eax
    mov esi, [rsp + 8]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 16]
    mov r8d, [rsp + 20]
    call ui_btn
    mov [rsp + 28], eax
    # a dragged row over a group's header or Ungrouped: it shows where it goes
    cmp dword ptr [rip + drag_on], 0
    je 11f
    test eax, UB_HOVER
    jz 11f
    mov ecx, [r15 + DE_kind]
    cmp ecx, DK_ARCHIVED
    je 11f
    xor edx, edx
    cmp ecx, DK_GROUP
    jne 12f
    mov edx, [r15 + DE_aux]
12: mov [rip + drop_gid], edx
    COLOR eax, T_SELECTION
    jmp 13f
11: test dword ptr [rsp + 28], UB_HOVER
    jz 14f
    COLOR eax, T_HOVER
13: PM ecx, MI_6
    mov edi, [rsp + 8]
    add edi, ecx
    mov esi, [rsp + 12]
    mov edx, [rsp + 16]
    sub edx, ecx
    sub edx, ecx
    mov ecx, [rsp + 20]
    PM r8d, MI_RADIUS
    mov r9d, eax
    call gfx_round_rect
14: # the chevron
    PM ecx, MI_16
    mov edi, [rsp + 8]
    add edi, [rip + g_pmt + 4*MI_8]
    mov esi, [rsp + 12]
    mov eax, [rsp + 20]
    sub eax, ecx
    sar eax, 1
    add esi, eax
    mov edx, ecx
    mov r8d, IC_CHEV_R
    cmp dword ptr [r15 + DE_flags], 0
    je 15f
    mov r8d, IC_CHEV_D
15: COLOR r9d, T_MUTED
    call ag_icon_draw
    # its name (or the rename field) and count
    lea rdi, [rip + lsb]
    call sb_clear
    mov eax, [r15 + DE_kind]
    cmp eax, DK_GROUP
    jne 16f
    cmp dword ptr [rip + ren_kind], RN_GROUP
    jne 161f
    mov ecx, [r15 + DE_aux]
    cmp [rip + ren_gid], ecx
    jne 161f
    mov edi, [rsp + 8]
    add edi, [rip + g_pmt + 4*MI_28]
    mov esi, [rsp + 12]
    mov edx, [rsp + 16]
    sub edx, [rip + g_pmt + 4*MI_40]
    mov ecx, [rsp + 20]
    mov r8, rbx
    call rename_field
    jmp .Lh_actions
161: mov edi, [r15 + DE_aux]
    call agst_group
    test rax, rax
    jz .Lh_ret
    lea rdi, [rip + lsb]
    mov rsi, [rax + SGR_name]
    call sb_push_cstr
    jmp 17f
16: lea rsi, [rip + .Lungrouped]
    cmp eax, DK_UNGROUPED
    je 162f
    lea rsi, [rip + .Larchived]
162: lea rdi, [rip + lsb]
    call sb_push_cstr
17: lea rdi, [rip + lsb]
    lea rsi, [rip + .Lmid]
    call sb_push_cstr
    lea rdi, [rip + lsb]
    mov esi, [r15 + DE_count]
    call sb_push_u64
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 8]
    add esi, [rip + g_pmt + 4*MI_28]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 20]
    mov r8, [rip + lsb + SB_ptr]
    mov r9, [rip + lsb + SB_len]
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 16]
    sub r11d, [rip + g_pmt + 4*MI_64]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
.Lh_actions:
    mov eax, [r15 + DE_kind]
    cmp eax, DK_ARCHIVED
    jne 2f
    test dword ptr [rsp + 28], UB_HOVER  # "Unarchive all N sessions", at the right while hovered or open
    jnz 18f
    cmp dword ptr [r15 + DE_flags], 0
    je 3f
18: mov rdi, rbx
    mov esi, [rsp + 8]
    add esi, [rsp + 16]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 20]
    mov r8d, [r15 + DE_count]
    call unarchive_all_btn
    test eax, eax
    jnz .Lh_ret
    jmp 3f
2:  cmp eax, DK_GROUP
    jne 3f
    test dword ptr [rsp + 28], UB_HOVER  # a group's ⋯: its menu
    jz 21f
    PM r13d, MI_28
    mov edi, [rsp]
    and edi, 0xfff
    shl edi, 2
    add edi, [rbx + LV_id]
    add edi, IDR_ACT + 2
    mov [rsp + 32], edi
    mov esi, [rsp + 8]
    add esi, [rsp + 16]
    sub esi, r13d
    sub esi, [rip + g_pmt + 4*MI_8]
    mov [rsp + 36], esi
    mov edx, [rsp + 12]
    mov eax, [rsp + 20]
    sub eax, r13d
    sar eax, 1
    add edx, eax
    mov [rsp + 40], edx
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_MORE
    call ag_icon_btn
    mov r14d, eax
    mov edi, [rsp + 32]
    mov esi, [rsp + 36]
    mov edx, [rsp + 40]
    add edx, r13d
    mov ecx, r13d
    mov r8d, r14d
    lea r9, [rip + .Lt_gmenu]
    call tip_note_text
    test r14d, UB_CLICK
    jz 21f
    mov edi, [r15 + DE_aux]
    mov rsi, rbx
    call menu_group_ask
    jmp .Lh_ret
21: test dword ptr [rsp + 28], UB_RPRESS
    jz 22f
    mov edi, [r15 + DE_aux]
    mov rsi, rbx
    call menu_group_ask
    jmp .Lh_ret
22: test dword ptr [rsp + 28], UB_DOUBLE
    jz 3f
    cmp dword ptr [rip + ren_kind], 0
    jne 3f
    mov edi, [r15 + DE_aux]
    mov rsi, rbx
    call rename_group_begin
    jmp .Lh_ret
3:  test dword ptr [rsp + 28], UB_CLICK
    jz .Lh_ret
    cmp dword ptr [rip + drag_on], 0
    jne .Lh_ret                 # a drag's release is the drop's
    mov eax, [r15 + DE_kind]    # open or collapse
    cmp eax, DK_GROUP
    jne 31f
    cmp dword ptr [rip + ren_kind], RN_GROUP
    je .Lh_ret
    mov edi, [r15 + DE_aux]
    call agst_group_flip
    jmp .Lh_ret
31: call agst_show
    mov ecx, SH_UNGROUPED_SHUT
    cmp dword ptr [r15 + DE_kind], DK_UNGROUPED
    je 32f
    mov ecx, SH_ARCHIVED_OPEN
32: xor eax, ecx
    mov edi, eax
    call agst_set_show
.Lh_ret:
    EPILOGUE

# ag_icon_draw(x, y, size, icon, argb): an icon in the panel's proportion (agentfont.s's icon size)
ag_icon_draw:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov ebx, r8d
    mov r15d, r9d
    mov edi, ebx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r15d
    call icon_draw
    EPILOGUE

# unarchive_all_btn(LV*, right, y, h, n) -> eax 1 clicked: "Unarchive all N sessions" ending at right
unarchive_all_btn:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    lea rdi, [rip + lsb]
    call sb_clear
    lea rdi, [rip + lsb]
    lea rsi, [rip + .Lunarch_one]
    cmp dword ptr [rsp + 12], 1
    jne 1f
    call sb_push_cstr
    jmp 2f
1:  lea rsi, [rip + .Lunarch_all1]
    call sb_push_cstr
    lea rdi, [rip + lsb]
    mov esi, [rsp + 12]
    call sb_push_u64
    lea rdi, [rip + lsb]
    lea rsi, [rip + .Lunarch_all2]
    call sb_push_cstr
2:  lea rdi, [rip + lsb]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rip + lsb + SB_len]
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rip + lsb + SB_ptr]
    mov rdx, [rip + lsb + SB_len]
    call text_width
    add eax, [rip + g_pmt + 4*MI_16]
    mov r12d, eax
    mov edi, [rbx + LV_id]
    add edi, IDT_UNARCH
    mov esi, [rsp]
    sub esi, r12d
    sub esi, [rip + g_pmt + 4*MI_8]
    mov [rsp + 16], esi
    mov edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, [rsp + 8]
    call ui_btn
    mov r13d, eax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 16]
    mov edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, [rsp + 8]
    mov r9, [rip + lsb + SB_ptr]
    COLOR eax, T_ACCENT
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    xor eax, eax
    test r13d, UB_CLICK
    jz 9f
    mov rdi, rbx
    call unarchive_all
    mov eax, 1
9:  EPILOGUE

# unarchive_all(LV*): every archived session of the list is listed again
unarchive_all:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  mov rdi, r12
    call agents_row_at
    cmp r12, rdx
    jae 9f
    inc r12
    test rax, rax
    jz 1b
    mov r13, rax
    mov eax, [rbx + LV_kind]
    test eax, eax
    jz 2f
    cmp [r13 + AS_kind], eax
    jne 1b
2:  mov rdi, r13
    call agst_of
    mov rdi, r13
    mov esi, eax
    call archived
    test eax, eax
    jz 1b
    mov rdi, r13
    mov esi, 1
    call set_archived
    jmp 1b
9:  EPILOGUE

# ---------- after the frame ----------

# after_frame(): what a click asked for while drawing, done once the frame is drawn: a row opened, a menu
#   opened, a drag dropped
after_frame:
    PROLOGUE
    cmp qword ptr [rip + drag_as], 0     # a drag: far enough from its press it is one; its release drops it
    je 3f
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jz 2f
    mov eax, [rip + g_mx]
    sub eax, [rip + drag_x]
    mov ecx, eax
    neg ecx
    cmovs ecx, eax
    mov eax, [rip + g_my]
    sub eax, [rip + drag_y]
    mov edx, eax
    neg edx
    cmovs edx, eax
    add ecx, edx
    cmp ecx, DRAG_PX
    jl 3f
    cmp dword ptr [rip + drag_on], 0
    jne 3f
    mov dword ptr [rip + drag_on], 1
    mov dword ptr [rip + g_dirty], 1
    jmp 3f
2:  cmp dword ptr [rip + drag_on], 0     # released
    je 21f
    mov edi, [rip + drop_gid]
    test edi, edi
    js 21f
    mov rsi, [rip + drag_as]
    lea rdx, [rip + lv_panel]
    call move_to_group
21: mov qword ptr [rip + drag_as], 0
    mov dword ptr [rip + drag_on], 0
    mov dword ptr [rip + g_dirty], 1
3:  mov rbx, [rip + pend_open]
    test rbx, rbx
    jz 4f
    mov qword ptr [rip + pend_open], 0
    mov rdi, rbx
    call agents_open_as
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    call agents_viewed          # opened from the list: the one a restart opens again ([files] restore_session)
    cmp rax, rbx
    jne 4f
    mov rdi, rbx
    call agst_set_open
4:  cmp dword ptr [rip + pend_menu], 0
    je 9f
    mov dword ptr [rip + pend_menu], 0
    lea rdi, [rip + menu_items]
    mov esi, [rip + pend_mx]
    mov edx, [rip + pend_my]
    call ctx_menu_open
9:  EPILOGUE

# move_to_group(gid, AS*, LV*): the session (and the selection it is in) into that group (0: none)
move_to_group:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    mov rbx, rdx
    mov rdi, rbx
    mov rsi, r13
    call in_multi
    test eax, eax
    jz 2f
    xor r14d, r14d              # the whole selection
1:  cmp r14, [rbx + LV_multi + VEC_len]
    jae 9f
    mov rax, [rbx + LV_multi + VEC_ptr]
    mov rdi, [rax + r14*8]
    mov esi, r12d
    call agst_put_group
    inc r14
    jmp 1b
2:  mov rdi, r13
    mov esi, r12d
    call agst_put_group
9:  EPILOGUE

# ---------- renaming inline ----------

# rename_field(x, y, w, h, LV* or 0): the rename field there, with the keys; a press outside it ends the rename
#   with what it holds (rename_commit), as leaving a field does
rename_field:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov rax, [rip + ag_fui]
    mov [rip + ren_tf + TF_face], rax
    mov eax, ID_AGL + IDT_RENAME
    test r8, r8
    jz 1f
    mov eax, [r8 + LV_id]
    add eax, IDT_RENAME
1:  mov [rip + ren_tf + TF_id], eax
    lea rdi, [rip + ren_tf]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    xor r9d, r9d
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    sete r9b
    lea rax, [rip + .Lph_rename]
    cmp dword ptr [rip + ren_kind], RN_GROUP
    jne 2f
    lea rax, [rip + .Lph_group]
2:  push rax
    push rax
    call ui_textarea
    add rsp, 16
    mov [rsp + 16], eax
    test eax, UB_PRESS
    jz 3f
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    jmp 9f
3:  test dword ptr [rip + g_pressed], (1 << BTN_LEFT) | (1 << BTN_RIGHT)
    jz 9f
    call rename_commit          # a press elsewhere
9:  EPILOGUE

# rename_start(kind RN_*, LV* or 0, text ptr, len): the field holds the text, all selected, with the keys
rename_start:
    PROLOGUE
    mov [rip + ren_kind], edi
    mov [rip + ren_lv], rsi
    mov r12, rdx
    mov r13, rcx
    lea rdi, [rip + ren_tf]
    mov rsi, r12
    mov rdx, r13
    call tf_set
    lea rdi, [rip + ren_tf]
    call tf_select_all
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# rename_session_begin(LV* or 0, AS*): its title in the field
rename_session_begin:
    PROLOGUE
    mov r12, rdi
    mov rbx, rsi
    mov [rip + ren_as], rbx
    xor r13d, r13d              # "Untitled session" is no title to edit: the field starts empty
    xor r14d, r14d
    mov rdi, rbx
    call agst_title
    test rax, rax
    jnz 1f
    cmp qword ptr [rbx + AS_title], 0
    je 2f
1:  mov rdi, rbx
    call title_of
    mov r13, rax
    mov r14, rdx
2:  mov edi, RN_SESSION
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call rename_start
    EPILOGUE

# FN aglist_rename_header(AS*): the chat header's title becomes the rename field (agenthead.s)
FN aglist_rename_header
    PROLOGUE
    mov rbx, rdi
    xor edi, edi
    mov rsi, rbx
    call rename_session_begin
    mov dword ptr [rip + ren_kind], RN_HEADER
    EPILOGUE

# FN aglist_renaming(AS*) -> eax 1 while the header's rename field is that conversation's
FN aglist_renaming
    xor eax, eax
    cmp dword ptr [rip + ren_kind], RN_HEADER
    jne 1f
    cmp [rip + ren_as], rdi
    sete al
1:  ret

# FN aglist_rename_field(x, y, w, h): the header's rename field there (agenthead.s)
FN aglist_rename_field
    xor r8d, r8d
    jmp rename_field

# rename_group_begin(gid, LV*): the group's name in the field
rename_group_begin:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    call agst_group
    test rax, rax
    jz 9f
    mov [rip + ren_gid], ebx
    mov r13, [rax + SGR_name]
    mov rdi, r13
    call strlen
    mov rcx, rax
    mov rdx, r13
    mov edi, RN_GROUP
    mov rsi, r12
    call rename_start
9:  EPILOGUE

# new_group_rename(): "New group": a group named so, last, its name in the rename field
new_group_rename:
    PROLOGUE
    lea rdi, [rip + .Lnew_group]
    mov esi, 9
    call agst_group_new
    test rax, rax
    jz 9f
    mov edi, [rax + SGR_id]
    lea rsi, [rip + lv_panel]
    call rename_group_begin
9:  EPILOGUE

# rename_cancel(): the field goes, nothing renamed
rename_cancel:
    mov dword ptr [rip + ren_kind], 0
    mov qword ptr [rip + ren_as], 0
    mov dword ptr [rip + g_dirty], 1
    ret

# rename_commit(): what the field holds is the name (an empty one renames nothing)
rename_commit:
    PROLOGUE
    mov ebx, [rip + ren_kind]
    mov r14, [rip + ren_as]
    mov r15d, [rip + ren_gid]
    call rename_cancel
    test ebx, ebx
    jz 9f
    lea rdi, [rip + ren_tf]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call trim
    test rdx, rdx
    jz 9f
    mov r12, rax
    mov r13, rdx
    cmp ebx, RN_GROUP
    jne 1f
    mov edi, r15d
    mov rsi, r12
    mov rdx, r13
    call agst_group_rename
    jmp 9f
1:  test r14, r14               # the session went while it was renamed: nothing to rename
    jz 9f
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    call aglist_set_title
9:  EPILOGUE

# FN aglist_set_title(AS*, ptr, len): the title the user gave: where its kind keeps titles (agent_store.s:
#   Claude Code's custom-title line in its file, which claude in a terminal reads too), else rhun's own
FN aglist_set_title
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r13, 200
    jbe 1f
    mov r13d, 200
1:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call agent_store_rename
    test eax, eax
    jz 2f
    mov rdi, r12                # the kind's own: the row shows it now, the file says it from now on
    mov rsi, r13
    call mem_dup
    mov rdi, [rbx + AS_title]
    mov [rbx + AS_title], rax
    call mem_free
    mov dword ptr [rbx + AS_titled], 1
    mov rdi, rbx                # and no title of rhun's own hides it
    xor esi, esi
    xor edx, edx
    call agst_title
    test rax, rax
    jz 3f
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    call agst_set_title
3:  inc qword ptr [rip + aglist_gen]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
2:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call agst_set_title
    EPILOGUE

# rename_key(keysym, cp, mods) -> eax 1: the rename field's keys: Enter commits, Escape cancels, the rest edit
rename_key:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    cmp r12d, KEY_RETURN
    je 1f
    cmp r12d, KEY_KP_ENTER
    jne 2f
1:  call rename_commit
    jmp 9f
2:  cmp r12d, KEY_ESCAPE
    jne 3f
    call rename_cancel
    jmp 9f
3:  cmp r12d, KEY_TAB           # one line: no tab, no line break
    je 9f
    lea rdi, [rip + ren_tf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
    mov dword ptr [rip + g_dirty], 1
9:  mov eax, 1
    EPILOGUE

# ---------- menus ----------

# lab_reset(), lab_cstr(cstr), lab_num(n), lab_end() -> rax the label made (in labels, kept while the menu is)
lab_reset:
    mov dword ptr [rip + labels_n], 0
    mov dword ptr [rip + menu_n], 0
    lea rdi, [rip + lsb]
    jmp sb_clear
lab_cstr:
    mov rsi, rdi
    lea rdi, [rip + lsb]
    jmp sb_push_cstr
lab_num:
    mov rsi, rdi
    lea rdi, [rip + lsb]
    jmp sb_push_u64
lab_end:
    PROLOGUE
    lea rdi, [rip + lsb]
    xor esi, esi
    call sb_push_byte
    mov eax, [rip + labels_n]
    mov rdx, [rip + lsb + SB_len]
    lea rcx, [rax + rdx]
    cmp rcx, LABELS_MAX
    jbe 1f
    lea rax, [rip + .Lm_line]   # (never: the labels are short)
    jmp 9f
1:  mov [rip + labels_n], ecx
    lea rdi, [rip + labels]
    add rdi, rax
    mov rbx, rdi
    mov rsi, [rip + lsb + SB_ptr]
    call memmove
    lea rdi, [rip + lsb]
    call sb_clear
    mov rax, rbx
9:  EPILOGUE

# item(label, fn 0 for a line): the menu's next item
item:
    mov eax, [rip + menu_n]
    cmp eax, MENU_MAX
    jae 9f
    shl eax, 4
    lea rcx, [rip + menu_items]
    mov [rcx + rax], rdi
    mov [rcx + rax + 8], rsi
    mov qword ptr [rcx + rax + 16], 0
    inc dword ptr [rip + menu_n]
9:  ret

# line(): a line between items
line:
    lea rdi, [rip + .Lm_line]
    xor esi, esi
    jmp item

# menu_at_pointer(): the menu opens at the pointer once the frame is drawn
menu_at_pointer:
    mov eax, [rip + g_mx]
    mov [rip + pend_mx], eax
    mov eax, [rip + g_my]
    mov [rip + pend_my], eax
    mov dword ptr [rip + pend_menu], 1
    mov dword ptr [rip + g_dirty], 1
    ret

# targets() -> eax how many sessions a menu's action takes: the selection when it was asked on one of it
targets:
    mov eax, 1
    cmp dword ptr [rip + menu_multi], 0
    je 1f
    mov rcx, [rip + menu_lv]
    mov eax, [rcx + LV_multi + VEC_len]
1:  ret

# target(i) -> rax the i-th session a menu's action takes (0 when it went)
target:
    mov rax, [rip + menu_as]
    cmp dword ptr [rip + menu_multi], 0
    je 1f
    mov rcx, [rip + menu_lv]
    xor eax, eax
    cmp rdi, [rcx + LV_multi + VEC_len]
    jae 1f
    mov rax, [rcx + LV_multi + VEC_ptr]
    mov rax, [rax + rdi*8]
1:  ret

# menu_row_ask(LV*, AS*): a session's menu (asked on a row of the selection: the selection's)
menu_row_ask:
    PROLOGUE
    mov [rip + menu_lv], rdi
    mov [rip + menu_as], rsi
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov rsi, r12
    call in_multi
    xor ecx, ecx
    test eax, eax
    jz 1f
    cmp qword ptr [rbx + LV_multi + VEC_len], 1
    seta cl
1:  mov [rip + menu_multi], ecx
    test ecx, ecx
    jnz 2f
    mov qword ptr [rbx + LV_multi + VEC_len], 0   # a row outside the selection: it alone
    mov [rbx + LV_sel], r12
2:  call lab_reset
    call targets
    mov r13d, eax               # n
    mov rdi, r12
    call agst_of
    mov r14d, eax               # its flags
    mov r15d, edx               # its group
    mov rdi, r12
    mov esi, r14d
    call archived
    test eax, eax
    jz 3f
    lea rdi, [rip + .Lm_resume] # an archived row: Resume, Unarchive
    lea rsi, [rip + m_open]
    call item
    lea rdi, [rip + .Lm_unarchive1]
    cmp r13d, 1
    je 21f
    lea rdi, [rip + .Lm_unarchiven]
    call lab_cstr
    mov edi, r13d
    call lab_num
    lea rdi, [rip + .Lm_sessions]
    call lab_cstr
    call lab_end
    mov rdi, rax
21: lea rsi, [rip + m_unarchive]
    call item
    jmp 8f
3:  mov rdi, r12
    call is_open
    lea rdi, [rip + .Lm_resume]
    test eax, eax
    jz 31f
    lea rdi, [rip + .Lm_switch]
31: lea rsi, [rip + m_open]
    call item
    lea rdi, [rip + .Lm_rename]
    lea rsi, [rip + m_rename]
    call item
    call line
    lea rdi, [rip + .Lm_newgroup1]
    cmp r13d, 1
    je 32f
    lea rdi, [rip + .Lm_newgroupn]
    call lab_cstr
    mov edi, r13d
    call lab_num
    lea rdi, [rip + .Lm_sessions]
    call lab_cstr
    call lab_end
    mov rdi, rax
32: lea rsi, [rip + m_newgroup]
    call item
    call agst_groups
    cmp qword ptr [rax + VEC_len], 0
    je 33f
    lea rdi, [rip + .Lm_addto]
    lea rsi, [rip + m_addto]
    call item
33: test r15d, r15d
    jz 34f
    lea rdi, [rip + .Lm_remove]
    lea rsi, [rip + m_remove]
    call item
34: call line
    lea rdi, [rip + .Lm_unread]
    lea rsi, [rip + m_unread]
    test r14d, SF_UNREAD
    jz 35f
    lea rdi, [rip + .Lm_read]
    lea rsi, [rip + m_read]
35: call item
    lea rdi, [rip + .Lm_archive1]
    cmp r13d, 1
    je 36f
    lea rdi, [rip + .Lm_archiven]
    call lab_cstr
    mov edi, r13d
    call lab_num
    lea rdi, [rip + .Lm_sessions]
    call lab_cstr
    call lab_end
    mov rdi, rax
36: lea rsi, [rip + m_archive]
    call item
8:  call menu_at_pointer
    EPILOGUE

m_open:
    mov rdi, [rip + menu_as]
    test rdi, rdi
    jz 1f
    mov [rip + pend_open], rdi
    jmp after_frame
1:  ret

m_rename:
    mov rsi, [rip + menu_as]
    test rsi, rsi
    jz 1f
    mov rdi, [rip + menu_lv]
    jmp rename_session_begin
1:  ret

m_newgroup:
    PROLOGUE
    lea rdi, [rip + .Lnew_group]
    mov esi, 9
    call agst_group_new
    test rax, rax
    jz 9f
    mov ebx, [rax + SGR_id]
    mov edi, ebx
    call put_targets
    mov edi, ebx
    mov rsi, [rip + menu_lv]
    call rename_group_begin
9:  EPILOGUE

# put_targets(gid): the menu's sessions into that group (0: none)
put_targets:
    PROLOGUE
    mov ebx, edi
    call targets
    mov r12d, eax
    xor r13d, r13d
1:  cmp r13d, r12d
    jae 9f
    mov edi, r13d
    call target
    inc r13d
    test rax, rax
    jz 1b
    mov rdi, rax
    mov esi, ebx
    call agst_put_group
    jmp 1b
9:  EPILOGUE

# mark_targets(set, clear): the menu's sessions' flags
mark_targets:
    PROLOGUE
    mov ebx, edi
    mov r14d, esi
    call targets
    mov r12d, eax
    xor r13d, r13d
1:  cmp r13d, r12d
    jae 9f
    mov edi, r13d
    call target
    inc r13d
    test rax, rax
    jz 1b
    mov rdi, rax
    mov esi, ebx
    mov edx, r14d
    call agst_mark
    jmp 1b
9:  EPILOGUE

m_addto:                        # a second menu: the groups
    PROLOGUE
    call lab_reset
    call agst_groups
    mov rbx, rax
    xor r12d, r12d
1:  cmp r12, [rbx + VEC_len]
    jae 2f
    cmp r12d, MENU_MAX
    jae 2f
    imul rax, r12, SGR_SIZE
    add rax, [rbx + VEC_ptr]
    mov rdi, [rax + SGR_name]
    lea rsi, [rip + m_addto_pick]
    call item
    inc r12
    jmp 1b
2:  call menu_at_pointer
    call after_frame
    EPILOGUE

m_addto_pick:
    PROLOGUE
    call agst_groups
    mov ecx, [rip + g_menu_index]
    cmp rcx, [rax + VEC_len]
    jae 9f
    imul rcx, rcx, SGR_SIZE
    add rcx, [rax + VEC_ptr]
    mov edi, [rcx + SGR_id]
    call put_targets
9:  EPILOGUE

m_remove:
    xor edi, edi
    jmp put_targets
m_unread:
    mov edi, SF_UNREAD
    xor esi, esi
    jmp mark_targets
m_read:
    xor edi, edi
    mov esi, SF_UNREAD
    jmp mark_targets
m_archive:
    mov edi, SF_ARCH
    mov esi, SF_KEPT
    jmp mark_targets
m_unarchive:
    mov edi, SF_KEPT
    mov esi, SF_ARCH
    jmp mark_targets

# menu_group_ask(gid, LV*): a group's menu: Rename group, Delete group, Start new session in this group
menu_group_ask:
    PROLOGUE
    mov [rip + menu_gid], edi
    mov [rip + menu_lv], rsi
    call lab_reset
    lea rdi, [rip + .Lm_grename]
    lea rsi, [rip + m_grename]
    call item
    lea rdi, [rip + .Lm_gdelete]
    lea rsi, [rip + m_gdelete]
    call item
    call line
    lea rdi, [rip + .Lm_gstart]
    lea rsi, [rip + m_gstart]
    call item
    call menu_at_pointer
    EPILOGUE

m_grename:
    mov edi, [rip + menu_gid]
    mov rsi, [rip + menu_lv]
    jmp rename_group_begin
m_gdelete:
    mov edi, [rip + menu_gid]
    jmp agst_group_delete
m_gstart:                       # a new conversation of the first agent rhun can drive; it joins the group
    PROLOGUE
    mov ebx, 1
1:  cmp ebx, 4
    ja 9f
    mov edi, ebx
    call agent_drv_for_kind
    inc ebx
    test rax, rax
    jz 1b
    dec ebx
    mov edi, ebx
    call agentext_new_kind
    test eax, eax
    jz 9f
    mov eax, [rip + menu_gid]
    mov [rip + new_gid], eax
9:  EPILOGUE

# filter_menu_ask(LV*, x, y): "Filter by status": Needs input · N, Working · N, Completed · N; Open · N,
#   Closed · N; Active · N (needs input, working or unread); the checked ones marked; Clear filters
filter_menu_ask:
    PROLOGUE
    mov rbx, rdi
    mov [rip + menu_lv], rdi
    mov [rip + pend_mx], esi
    mov [rip + pend_my], edx
    mov rdi, rbx
    call ensure
    call lab_reset
    call agst_filter
    mov r12d, eax
    lea r13, [rip + filter_rows]
1:  mov rdi, [r13]
    test rdi, rdi
    jz 3f
    cmp rdi, 1
    jne 2f
    call line
    add r13, 32
    jmp 1b
2:  mov eax, [r13 + 16]         # its bit
    test r12d, eax
    jz 21f
    lea rdi, [rip + .Lm_check]
    call lab_cstr
21: mov rdi, [r13]
    call lab_cstr
    mov eax, [r13 + 20]         # its count
    mov edi, [rbx + LV_cnt + rax]
    call lab_num
    call lab_end
    mov rdi, rax
    mov rsi, [r13 + 8]
    call item
    add r13, 32
    jmp 1b
3:  test r12d, r12d
    jz 4f
    call line
    lea rdi, [rip + .Lm_clearf]
    lea rsi, [rip + m_f_clear]
    call item
4:  mov dword ptr [rip + pend_menu], 1
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

.section .rodata
.p2align 3
filter_rows:                    # label, handler, bit, count's offset; 1: a line; 0 the end
    .quad .Lm_needs, m_f_needs
    .long LF_NEEDS, CN_NEEDS
    .quad 0
    .quad .Lm_working, m_f_working
    .long LF_WORKING, CN_WORK
    .quad 0
    .quad .Lm_done, m_f_done
    .long LF_DONE, CN_DONE
    .quad 0
    .quad 1, 0, 0, 0
    .quad .Lm_open, m_f_open
    .long LF_OPEN, CN_OPEN
    .quad 0
    .quad .Lm_closed, m_f_closed
    .long LF_CLOSED, CN_CLOSED
    .quad 0
    .quad 1, 0, 0, 0
    .quad .Lm_active, m_f_active
    .long LF_ACTIVE, CN_ACTIVE
    .quad 0
    .quad 0
.text

m_f_needs:
    mov edi, LF_NEEDS
    jmp f_flip
m_f_working:
    mov edi, LF_WORKING
    jmp f_flip
m_f_done:
    mov edi, LF_DONE
    jmp f_flip
m_f_open:
    mov edi, LF_OPEN
    jmp f_flip
m_f_closed:
    mov edi, LF_CLOSED
    jmp f_flip
m_f_active:
    mov edi, LF_ACTIVE
f_flip:
    push rbx
    mov ebx, edi
    call agst_filter
    xor eax, ebx
    mov edi, eax
    call agst_set_filter
    pop rbx
    ret
m_f_clear:
    xor edi, edi
    jmp agst_set_filter

# ---------- keys ----------

# FN aglist_key(keysym, cp, mods) -> eax 1 when the list took the key: the rename field's first, then the
#   dropdown's list, then the panel's list while it shows (no conversation open, no draft)
FN aglist_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    cmp dword ptr [rip + ren_kind], 0
    je 1f
    call rename_key
    EPILOGUE
1:  cmp dword ptr [rip + drop_open], 0
    je 2f
    cmp r12d, KEY_ESCAPE        # Escape clears its search, else closes it
    jne 11f
    lea rdi, [rip + lv_drop]
    call query
    test rdx, rdx
    jz 12f
    lea rdi, [rip + lv_drop]
    call search_clear
    mov eax, 1
    EPILOGUE
12: call aglist_drop_close
    mov eax, 1
    EPILOGUE
11: lea rdi, [rip + lv_drop]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call lv_key
    test eax, eax
    jnz 9f
    jmp 8f
2:  call agents_viewed
    test rax, rax
    jnz 8f
    call agentext_new_active
    test rax, rax
    jnz 8f
    lea rdi, [rip + lv_panel]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call lv_key
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# lv_key(LV*, keysym, cp, mods) -> eax 1 taken: ↑/↓ move among the rows, PageUp/PageDown a page, Enter opens
#   (Cmd/Ctrl/Shift+Enter too), F2 renames, Escape clears the search, then hides it, then the selection; a
#   character starts a search; the search field, when it has the keys, edits with the rest
lv_key:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov rdi, rbx
    call ensure
    cmp r12d, KEY_DOWN
    jne 1f
    mov rdi, rbx
    mov esi, 1
    call sel_step
    jmp 8f
1:  cmp r12d, KEY_UP
    jne 2f
    mov rdi, rbx
    mov esi, -1
    call sel_step
    jmp 8f
2:  cmp r12d, KEY_PAGEDOWN
    jne 21f
    mov rdi, rbx
    mov esi, 1
    call sel_page
    jmp 8f
21: cmp r12d, KEY_PAGEUP
    jne 22f
    mov rdi, rbx
    mov esi, -1
    call sel_page
    jmp 8f
22: cmp r12d, KEY_RETURN
    je 23f
    cmp r12d, KEY_KP_ENTER
    jne 3f
23: mov rdi, rbx                # the selected row when the list shows it, else the first
    mov rsi, [rbx + LV_sel]
    call entry_of
    mov rcx, rax
    mov rax, [rbx + LV_sel]
    test rcx, rcx
    jns 24f
    mov rdi, rbx
    xor esi, esi
    call sel_step
    mov rax, [rbx + LV_sel]
    test rax, rax
    jz 8f
24: mov [rip + pend_open], rax
    mov qword ptr [rbx + LV_multi + VEC_len], 0
    call after_frame
    jmp 8f
3:  cmp r12d, KEY_F1 + 1        # F2
    jne 4f
    mov rsi, [rbx + LV_sel]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call rename_session_begin
    jmp 8f
4:  cmp r12d, KEY_ESCAPE
    jne 5f
    mov rdi, rbx
    call query
    test rdx, rdx
    jz 41f
    mov rdi, rbx
    call search_clear
    jmp 8f
41: cmp dword ptr [rbx + LV_search], 0
    je 42f
    lea rax, [rip + lv_drop]
    cmp rbx, rax
    je 42f                      # (the dropdown's search row always shows)
    mov dword ptr [rbx + LV_search], 0
    mov dword ptr [rbx + LV_focus], 0
    jmp 7f
42: cmp qword ptr [rbx + LV_multi + VEC_len], 0
    jne 43f
    cmp qword ptr [rbx + LV_sel], 0
    je 9f                       # nothing left: the panel's own Escape
43: mov qword ptr [rbx + LV_multi + VEC_len], 0
    mov qword ptr [rbx + LV_sel], 0
    jmp 7f
5:  cmp dword ptr [rbx + LV_focus], 0
    je 6f
    cmp r12d, KEY_TAB           # the field's keys: Tab leaves it for the rows
    jne 51f
    mov dword ptr [rbx + LV_focus], 0
    jmp 7f
51: lea rdi, [rbx + LV_tf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call ta_key
    test eax, eax
    jz 9f
    jmp 62f
6:  test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER   # a character starts a search
    jnz 9f
    cmp r13d, 33
    jb 9f
    cmp r12d, 0xff00
    jae 9f
    mov rdi, rbx
    call search_show
    lea rdi, [rbx + LV_tf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call ta_key
62: inc qword ptr [rbx + LV_tf + TF_revision]
    mov dword ptr [rbx + LV_scroll], 0
7:  mov dword ptr [rip + g_dirty], 1
8:  mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# sel_step(LV*, dir -1, 1, or 0 for the first row): the keys move to the next row that way (from none: the first
#   or the last)
sel_step:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rsi, [rbx + LV_sel]
    call entry_of
    mov r13, rax
    test r12d, r12d
    jnz 1f
    mov r13, -1
    mov r12d, 1
1:  test r13, r13
    jns 2f
    mov r13, -1                 # none: from before the first, or after the last
    cmp r12d, 0
    jg 2f
    mov r13, [rbx + LV_rows + VEC_len]
2:  movsxd rax, r12d
    add r13, rax
    test r13, r13
    js 9f
    cmp r13, [rbx + LV_rows + VEC_len]
    jae 9f
    imul rax, r13, DE_SIZE
    add rax, [rbx + LV_rows + VEC_ptr]
    cmp dword ptr [rax + DE_kind], DK_ROW
    jne 2b
    mov rax, [rax + DE_as]
    mov [rbx + LV_sel], rax
    mov [rbx + LV_anchor], rax
    mov dword ptr [rbx + LV_reveal], 1
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# sel_page(LV*, dir): a page of rows that way
sel_page:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call row_h
    mov eax, [rbx + LV_ah]
    test edx, edx
    jz 9f
    push rdx
    xor edx, edx
    pop rcx
    div ecx
    mov r13d, eax
    cmp r13d, 1
    jge 1f
    mov r13d, 1
1:  mov rdi, rbx
    mov esi, r12d
    call sel_step
    dec r13d
    jnz 1b
9:  EPILOGUE

# FN aglist_paste(ptr, len) -> eax 1 when the rename field or a list's search field took it
FN aglist_paste
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call aglist_field
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call tf_insert              # one line: line breaks are spaces
    inc qword ptr [rbx + TF_revision]
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# FN aglist_field() -> rax the list's field with the keys (the rename field, a search field), or 0
FN aglist_field
    PROLOGUE
    lea rax, [rip + ren_tf]
    cmp dword ptr [rip + ren_kind], 0
    jne 9f
    lea rbx, [rip + lv_drop]
    cmp dword ptr [rip + drop_open], 0
    jne 1f
    call agents_viewed
    test rax, rax
    jnz 8f
    lea rbx, [rip + lv_panel]
    cmp dword ptr [rbx + LV_search], 0
    je 8f
1:  cmp dword ptr [rbx + LV_focus], 0
    je 8f
    lea rax, [rbx + LV_tf]
    jmp 9f
8:  xor eax, eax
9:  EPILOGUE

# ---------- the "Past conversations" dropdown (5.2) ----------

# FN aglist_drop_open(kind, x, y, w, h): the dropdown of that kind's conversations, hanging from the button
#   there, its search with the keys; open already: it closes
FN aglist_drop_open
    PROLOGUE
    cmp dword ptr [rip + drop_open], 0
    jne 8f
    mov [rip + drop_kind], edi
    mov [rip + drop_anchor], esi
    mov [rip + drop_anchor + 4], edx
    mov [rip + drop_anchor + 8], ecx
    mov [rip + drop_anchor + 12], r8d
    mov dword ptr [rip + drop_open], 1
    mov dword ptr [rip + drop_rect + 12], 0
    lea rbx, [rip + lv_drop]
    mov [rbx + LV_kind], edi
    mov dword ptr [rbx + LV_id], ID_AGL + IDX_DROP
    mov dword ptr [rbx + LV_search], 1
    mov dword ptr [rbx + LV_focus], 1
    mov dword ptr [rbx + LV_scroll], 0
    mov qword ptr [rbx + LV_multi + VEC_len], 0
    call agents_viewed
    mov [rbx + LV_sel], rax
    mov dword ptr [rbx + LV_reveal], 1
    lea rdi, [rbx + LV_tf]
    call tf_clear
    inc qword ptr [rbx + LV_tf + TF_revision]
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
8:  call aglist_drop_close
    EPILOGUE

# FN aglist_drop_close()
FN aglist_drop_close
    mov dword ptr [rip + drop_open], 0
    mov dword ptr [rip + drop_rect + 12], 0
    mov dword ptr [rip + g_dirty], 1
    ret

# FN aglist_drop_is_open() -> eax 1 while it shows
FN aglist_drop_is_open
    mov eax, [rip + drop_open]
    ret

# FN aglist_shield(): before what is drawn under the dropdown: the pointer over last frame's dropdown is its
#   own (g_block) until aglist_unshield
FN aglist_shield
    mov dword ptr [rip + drop_shield], 0
    cmp dword ptr [rip + drop_open], 0
    je 9f
    cmp dword ptr [rip + drop_rect + 12], 0
    je 9f
    cmp dword ptr [rip + g_block], 0
    jne 9f
    mov eax, [rip + g_mx]
    mov ecx, [rip + drop_rect]
    cmp eax, ecx
    jl 9f
    add ecx, [rip + drop_rect + 8]
    cmp eax, ecx
    jge 9f
    mov eax, [rip + g_my]
    mov ecx, [rip + drop_rect + 4]
    cmp eax, ecx
    jl 9f
    add ecx, [rip + drop_rect + 12]
    cmp eax, ecx
    jge 9f
    mov dword ptr [rip + g_block], 1
    mov dword ptr [rip + drop_shield], 1
9:  ret

# FN aglist_unshield()
FN aglist_unshield
    cmp dword ptr [rip + drop_shield], 0
    je 1f
    mov dword ptr [rip + g_block], 0
    mov dword ptr [rip + drop_shield], 0
1:  ret

# FN aglist_drop_draw(x, y, w, h): the panel's area; the dropdown, when open, under its button and right-aligned
#   to it, at most 420 points wide and two thirds of the area high: its search field, then the list. A press
#   outside it (not on its button) closes it
FN aglist_drop_draw
    PROLOGUE 48
    cmp dword ptr [rip + drop_open], 0
    je 9f
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    PM eax, MI_64               # its width: 420 points in the panel's proportion, at most the panel less a margin
    imul eax, eax, 420
    sar eax, 6
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_pmt + 4*MI_16]
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 24], eax         # w
    mov ecx, [rip + drop_anchor]
    add ecx, [rip + drop_anchor + 8]
    sub ecx, eax
    mov edx, [rsp]
    add edx, [rip + g_pmt + 4*MI_8]
    cmp ecx, edx
    cmovl ecx, edx
    mov [rsp + 16], ecx         # x
    mov eax, [rip + drop_anchor + 4]
    add eax, [rip + drop_anchor + 12]
    add eax, [rip + g_pmt + 4*MI_2]
    mov [rsp + 20], eax         # y
    mov eax, [rsp + 12]         # h: two thirds of the area, within it
    add eax, eax
    xor edx, edx
    mov ecx, 3
    div ecx
    mov ecx, [rsp + 4]
    add ecx, [rsp + 12]
    sub ecx, [rsp + 20]
    sub ecx, [rip + g_pmt + 4*MI_8]
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 28], eax
    lea rbx, [rip + lv_drop]    # no taller than what it shows
    mov rdi, rbx
    call ensure
    mov eax, [rsp + 28]
    mov ecx, [rbx + LV_total]
    add ecx, [rip + g_pmt + 4*MI_40]
    add ecx, [rip + g_pmt + 4*MI_8]
    PM edx, MI_64
    add edx, edx
    cmp ecx, edx
    cmovl ecx, edx
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 28], eax         # h
    mov eax, [rsp + 16]
    mov [rip + drop_rect], eax
    mov eax, [rsp + 20]
    mov [rip + drop_rect + 4], eax
    mov eax, [rsp + 24]
    mov [rip + drop_rect + 8], eax
    mov eax, [rsp + 28]
    mov [rip + drop_rect + 12], eax
    # a press outside, not on its button: it closes
    test dword ptr [rip + g_pressed], (1 << BTN_LEFT) | (1 << BTN_RIGHT)
    jz 2f
    call ctx_menu_list          # (a menu of its own over it is not outside)
    test rax, rax
    jnz 2f
    mov edi, [rsp + 16]
    mov esi, [rsp + 20]
    mov edx, [rsp + 24]
    mov ecx, [rsp + 28]
    call in_rect
    test eax, eax
    jnz 2f
    mov edi, [rip + drop_anchor]
    mov esi, [rip + drop_anchor + 4]
    mov edx, [rip + drop_anchor + 8]
    mov ecx, [rip + drop_anchor + 12]
    call in_rect
    test eax, eax
    jnz 2f
    call aglist_drop_close
    jmp 9f
2:  mov edi, [rsp + 16]
    mov esi, [rsp + 20]
    mov edx, [rsp + 24]
    mov ecx, [rsp + 28]
    PM r8d, MI_12
    PM r9d, MI_4
    PM eax, MI_RADIUS
    add eax, [rip + g_pmt + 4*MI_2]
    push rax
    push rax
    call ui_card_shadow
    add rsp, 16
    mov edi, [rsp + 16]
    mov esi, [rsp + 20]
    mov edx, [rsp + 24]
    mov ecx, [rsp + 28]
    call gfx_clip_push
    mov rdi, rbx
    mov esi, [rsp + 16]
    mov edx, [rsp + 20]
    add edx, [rip + g_pmt + 4*MI_4]
    mov ecx, [rsp + 24]
    mov r8d, [rsp + 28]
    sub r8d, [rip + g_pmt + 4*MI_8]
    call lv_draw
    call gfx_clip_pop
    call after_frame
9:  EPILOGUE

# in_rect(x, y, w, h) -> eax 1 when the pointer is in it (whatever blocks it)
in_rect:
    xor eax, eax
    mov r8d, [rip + g_mx]
    mov r9d, [rip + g_my]
    cmp r8d, edi
    jl 9f
    add edi, edx
    cmp r8d, edi
    jge 9f
    cmp r9d, esi
    jl 9f
    add esi, ecx
    cmp r9d, esi
    jge 9f
    mov eax, 1
9:  ret

# ---------- headless: print-agent-list, print-agent-list-state, agent-list ----------

# lv_of(ptr, len) -> rax the list a word names: "drop" the dropdown's, else the panel's
lv_of:
    PROLOGUE
    lea rbx, [rip + lv_panel]
    lea rdx, [rip + .Lw_drop]
    call str_eq_cstr
    test eax, eax
    jz 1f
    lea rbx, [rip + lv_drop]
1:  mov rax, rbx
    EPILOGUE

# FN aglist_print(out, rest, len): print-agent-list [drop]: the list as built now (lv_dump)
FN aglist_print
    PROLOGUE
    mov r15, rdi
    mov rdi, rsi
    mov rsi, rdx
    call trim
    mov rdi, rax
    mov rsi, rdx
    call lv_of
    mov rbx, rax
    call agents_metrics         # (the panel's metrics: rows have its heights)
    mov rdi, rbx
    call ensure
    mov rdi, r15
    mov rsi, rbx
    call lv_dump
    xor eax, eax
    EPILOGUE

# FN aglist_print_state(out, rest, len): print-agent-list-state (agst_dump)
FN aglist_print_state
    PROLOGUE
    call agst_dump
    xor eax, eax
    EPILOGUE

# lv_dump(sb, LV*): "list shown=N total=N archived=N filter=F search=Q field=0|1 sel=T|- multi=N
#   counts=NEEDS,WORKING,DONE,OPEN,CLOSED,ACTIVE rename=T|- drop=0|1 built=N", then each entry: "group NAME (N)
#   [closed]", "ungrouped (N) [closed]", "archived (N) [closed]", "  row TITLE kind=K dot=D [ring] [match=S-E]
#   age=A [worktree=W] [selected] [multi]", "none found"
lv_dump:
    PROLOGUE 16
    mov r15, rdi
    mov rbx, rsi
    xor r12d, r12d              # rows
    xor ecx, ecx
1:  cmp rcx, [rbx + LV_rows + VEC_len]
    jae 2f
    imul rax, rcx, DE_SIZE
    add rax, [rbx + LV_rows + VEC_ptr]
    cmp dword ptr [rax + DE_kind], DK_ROW
    jne 11f
    inc r12d
11: inc rcx
    jmp 1b
2:  mov rdi, r15
    lea rsi, [rip + .Ld_list]
    call sb_push_cstr
    mov rdi, r15
    mov esi, r12d
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_total]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + LV_cnt + CN_MATCH]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_arch]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + LV_cnt + CN_ARCH]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_filter]
    call sb_push_cstr
    call agst_filter
    mov rdi, r15
    mov esi, eax
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_search]
    call sb_push_cstr
    mov rdi, rbx
    call query
    mov rdi, r15
    mov rsi, rax
    call dump_word
    mov rdi, r15
    lea rsi, [rip + .Ld_focus]
    call sb_push_cstr
    xor esi, esi
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    jne 3f
    mov esi, [rbx + LV_focus]
3:  mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_sel]
    call sb_push_cstr
    mov rdi, [rbx + LV_sel]
    xor eax, eax
    xor edx, edx
    test rdi, rdi
    jz 4f
    call title_of
4:  mov rdi, r15
    mov rsi, rax
    call dump_word
    mov rdi, r15
    lea rsi, [rip + .Ld_multi]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + LV_multi + VEC_len]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_counts]
    call sb_push_cstr
    xor r12d, r12d
5:  mov rdi, r15
    mov esi, [rbx + LV_cnt + r12*4]
    call sb_push_u64
    inc r12d
    cmp r12d, 6
    jae 51f
    mov rdi, r15
    mov esi, ','
    call sb_push_byte
    jmp 5b
51: mov rdi, r15
    lea rsi, [rip + .Ld_rename]
    call sb_push_cstr
    xor eax, eax
    xor edx, edx
    cmp dword ptr [rip + ren_kind], 0
    je 52f
    lea rdi, [rip + ren_tf]
    call tf_text
52: mov rdi, r15
    mov rsi, rax
    call dump_word
    mov rdi, [rip + breaker]    # the conversation the breaker kept closed
    test rdi, rdi
    jz 56f
    call title_of
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, r15
    lea rsi, [rip + .Ld_reopen]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call dump_word
56: mov rdi, r15
    lea rsi, [rip + .Ld_drop]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rip + drop_open]
    call sb_push_u64
    lea rax, [rip + lv_drop]    # the dropdown's: where it was drawn last
    cmp rbx, rax
    jne 53f
    xor r12d, r12d
54: mov rdi, r15
    mov esi, ','
    test r12d, r12d
    jnz 55f
    mov esi, '@'
55: call sb_push_byte
    lea rax, [rip + drop_rect]
    mov esi, [rax + r12*4]
    mov rdi, r15
    call sb_push_u64
    inc r12d
    cmp r12d, 4
    jb 54b
53: mov rdi, r15
    mov esi, 10
    call sb_push_byte
    xor r12d, r12d              # the entries
.Ldm_next:
    cmp r12, [rbx + LV_rows + VEC_len]
    jae .Ldm_done
    imul r13, r12, DE_SIZE
    add r13, [rbx + LV_rows + VEC_ptr]
    inc r12
    mov eax, [r13 + DE_kind]
    cmp eax, DK_ROW
    je .Ldm_row
    cmp eax, DK_EMPTY
    jne 6f
    mov rdi, r15
    lea rsi, [rip + .Ld_none]
    call sb_push_cstr
    jmp .Ldm_lf
6:  cmp eax, DK_GROUP
    jne 61f
    mov rdi, r15
    lea rsi, [rip + .Ld_group]
    call sb_push_cstr
    mov edi, [r13 + DE_aux]
    call agst_group
    test rax, rax
    jz .Ldm_lf
    mov rdi, r15
    mov rsi, [rax + SGR_name]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_paren]
    call sb_push_cstr
    jmp 62f
61: lea rsi, [rip + .Ld_ungrouped]
    cmp eax, DK_UNGROUPED
    je 611f
    lea rsi, [rip + .Ld_archived]
611: mov rdi, r15
    call sb_push_cstr
62: mov rdi, r15
    mov esi, [r13 + DE_count]
    call sb_push_u64
    mov rdi, r15
    mov esi, ')'
    call sb_push_byte
    cmp dword ptr [r13 + DE_flags], 0
    jne .Ldm_lf
    mov rdi, r15
    lea rsi, [rip + .Ld_closed]
    call sb_push_cstr
    jmp .Ldm_lf
.Ldm_row:
    mov r14, [r13 + DE_as]
    mov rdi, r15
    lea rsi, [rip + .Ld_row]
    call sb_push_cstr
    mov rdi, r14
    call title_of
    mov rdi, r15
    mov rsi, rax
    call sb_push
    mov rdi, r15
    lea rsi, [rip + .Ld_kind]
    call sb_push_cstr
    mov edi, [r14 + AS_kind]
    call agent_kind_name
    cmp dword ptr [r14 + AS_kind], AS_KIND_EXT
    jne 7f
    lea rax, [rip + .Lw_ext]
7:  mov rdi, r15
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_dot]
    call sb_push_cstr
    mov rdi, r14
    call status_of
    lea rcx, [rip + dot_words]
    mov rsi, [rcx + rax*8]
    mov rdi, r15
    call sb_push_cstr
    mov rdi, r14
    call held_by_other
    test eax, eax
    jz 71f
    mov rdi, r15
    lea rsi, [rip + .Ld_ring]
    call sb_push_cstr
71: mov rdi, rbx                # the match
    call query
    test rdx, rdx
    jz 72f
    mov [rsp], rdx
    mov rcx, rdx
    mov rdx, rax
    push rcx
    push rdx
    mov rdi, r14
    call title_of
    pop rdx
    pop rcx
    mov rdi, rax
    mov rsi, rdx
    call str_ifind
    test rax, rax
    js 72f
    mov [rsp + 8], rax
    mov rdi, r15
    lea rsi, [rip + .Ld_match]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rsp + 8]
    call sb_push_u64
    mov rdi, r15
    mov esi, '-'
    call sb_push_byte
    mov rsi, [rsp + 8]
    add rsi, [rsp]
    mov rdi, r15
    call sb_push_u64
72: mov rdi, r15
    lea rsi, [rip + .Ld_age]
    call sb_push_cstr
    mov rdi, [r14 + AS_mtime]
    call age_text
    mov rdi, r15
    mov rsi, rax
    call sb_push_cstr
    mov rsi, [r14 + AS_worktree]
    test rsi, rsi
    jz 73f
    mov rdi, r15
    lea rsi, [rip + .Ld_wt]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [r14 + AS_worktree]
    call sb_push_cstr
73: cmp [rbx + LV_sel], r14
    jne 74f
    mov rdi, r15
    lea rsi, [rip + .Ld_selected]
    call sb_push_cstr
74: mov rdi, rbx
    mov rsi, r14
    call in_multi
    test eax, eax
    jz .Ldm_lf
    mov rdi, r15
    lea rsi, [rip + .Ld_multi1]
    call sb_push_cstr
.Ldm_lf:
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    jmp .Ldm_next
.Ldm_done:
    EPILOGUE

# dump_word(sb, ptr, len): the text with blanks as "_", "-" when empty
dump_word:
    PROLOGUE
    mov r15, rdi
    mov r12, rsi
    mov r13, rdx
    test r12, r12
    jz 8f
    test r13, r13
    jz 8f
    xor ebx, ebx
1:  cmp rbx, r13
    jae 9f
    movzx esi, byte ptr [r12 + rbx]
    cmp esi, ' '
    jne 2f
    mov esi, '_'
2:  mov rdi, r15
    call sb_push_byte
    inc rbx
    jmp 1b
8:  mov rdi, r15
    mov esi, '-'
    call sb_push_byte
9:  EPILOGUE

# find_row(LV*, title ptr, len) -> rax the session of its first row with that title, 0 none; rdx its entry
find_row:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call ensure
    xor r14d, r14d
1:  cmp r14, [rbx + LV_rows + VEC_len]
    jae 8f
    imul r15, r14, DE_SIZE
    add r15, [rbx + LV_rows + VEC_ptr]
    inc r14
    cmp dword ptr [r15 + DE_kind], DK_ROW
    jne 1b
    mov rdi, [r15 + DE_as]
    call title_of
    mov rdi, r12
    mov rsi, r13
    cmp rdx, rsi
    jne 1b
    mov rdx, rax
    call memcmp_eq3
    test eax, eax
    jz 1b
    mov rax, [r15 + DE_as]
    lea rdx, [r14 - 1]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# memcmp_eq3(a, n, b) -> eax 1 when n bytes are equal
memcmp_eq3:
    mov rcx, rsi
    mov rsi, rcx
    jmp memcmp_eq

# find_group(ptr, len) -> eax the id of the group with that name, 0 none
find_group:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call agst_groups
    mov rbx, rax
    xor r14d, r14d
1:  cmp r14, [rbx + VEC_len]
    jae 8f
    imul r15, r14, SGR_SIZE
    add r15, [rbx + VEC_ptr]
    inc r14
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r15 + SGR_name]
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov eax, [r15 + SGR_id]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN aglist_ctl(out, rest, len): agent-list WORD ARGS, the list as the mouse and the keys use it:
#   search TEXT | drop-search TEXT | open TITLE | select TITLE [ctrl|shift] | menu TITLE | drop-menu TITLE |
#   group-menu NAME | filter-menu | rename TITLE | rename-group NAME | new-group | toggle NAME|ungrouped|archived
#   | drag TITLE -> NAME|ungrouped | unarchive-all | drop-open | drop-close | grew TITLE
FN aglist_ctl
    PROLOGUE 32
    mov r15, rdi
    mov rdi, rsi
    mov rsi, rdx
    call trim
    mov rdi, rax
    mov rsi, rdx
    call next_word
    mov [rsp], rax              # the word
    mov [rsp + 8], rdx
    lea rcx, [rip + ctl_words]
    mov [rsp + 16], rcx
    call agents_metrics
1:  mov rcx, [rsp + 16]
    mov rdx, [rcx]
    test rdx, rdx
    jz 8f
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add qword ptr [rsp + 16], 16
    jmp 1b
2:  mov rdi, [rsp]              # the rest of the line after the word
    add rdi, [rsp + 8]
    mov rsi, rdi
    call ctl_rest
    mov rdi, rax
    mov rsi, rdx
    mov rcx, [rsp + 16]
    call [rcx + 8]
    test rax, rax
    js 8f
    call after_frame
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# ctl_rest(after the word) -> rax ptr, rdx len: the line's rest, trimmed (args_rest of this command)
.bss
ctl_line: .quad 0
ctl_end: .quad 0
.text
ctl_rest:
    mov rsi, [rip + ctl_end]
    sub rsi, rdi
    jns 1f
    xor esi, esi
1:  jmp trim

.section .rodata
.p2align 3
ctl_words:
    .quad .Lc_search, c_search, .Lc_drop_search, c_drop_search, .Lc_open, c_open, .Lc_select, c_select
    .quad .Lc_menu, c_menu, .Lc_drop_menu, c_drop_menu, .Lc_group_menu, c_group_menu
    .quad .Lc_filter_menu, c_filter_menu, .Lc_rename, c_rename, .Lc_rename_group, c_rename_group
    .quad .Lc_new_group, c_new_group, .Lc_toggle, c_toggle, .Lc_drag, c_drag
    .quad .Lc_unarchive_all, c_unarchive_all, .Lc_drop_open, c_drop_open, .Lc_drop_close, c_drop_close
    .quad .Lc_grew, c_grew, .Lc_reopen, c_reopen
    .quad 0, 0
.Lc_search: .asciz "search"
.Lc_drop_search: .asciz "drop-search"
.Lc_open: .asciz "open"
.Lc_select: .asciz "select"
.Lc_menu: .asciz "menu"
.Lc_drop_menu: .asciz "drop-menu"
.Lc_group_menu: .asciz "group-menu"
.Lc_filter_menu: .asciz "filter-menu"
.Lc_rename: .asciz "rename"
.Lc_rename_group: .asciz "rename-group"
.Lc_new_group: .asciz "new-group"
.Lc_toggle: .asciz "toggle"
.Lc_drag: .asciz "drag"
.Lc_unarchive_all: .asciz "unarchive-all"
.Lc_drop_open: .asciz "drop-open"
.Lc_drop_close: .asciz "drop-close"
.Lc_grew: .asciz "grew"
.Lc_reopen: .asciz "reopen"
.Lw_drop: .asciz "drop"
.Lw_ext: .asciz "ext"
.Lw_ctrl: .asciz "ctrl"
.Lw_shift: .asciz "shift"
.Lw_ungrouped: .asciz "ungrouped"
.Lw_arrow: .ascii " -> "
.Lw_archived: .asciz "archived"
.Ld_paren: .asciz " ("
.globl aglist_n_print, aglist_n_state, aglist_n_list
aglist_n_print: .asciz "print-agent-list"
aglist_n_state: .asciz "print-agent-list-state"
aglist_n_list: .asciz "agent-list"
.text

# set_search(LV*, ptr, len): its search text, with the keys
set_search:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call search_show
    lea rdi, [rbx + LV_tf]
    mov rsi, r12
    mov rdx, r13
    call tf_set
    inc qword ptr [rbx + LV_tf + TF_revision]
    mov dword ptr [rbx + LV_scroll], 0
    xor eax, eax
    EPILOGUE

c_search:
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + lv_panel]
    jmp set_search
c_drop_search:
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + lv_drop]
    jmp set_search

# row_arg(LV*, ptr, len) -> rax the session of the row titled so (its title is the text up to a last word of
#   ctrl or shift, when there is one), 0 none
c_open:
    PROLOGUE
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + lv_panel]
    call find_row
    test rax, rax
    jz 8f
    lea rdi, [rip + lv_panel]
    mov rsi, rax
    mov dword ptr [rip + g_mods], 0
    call row_click
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

c_select:                       # select TITLE [ctrl|shift]: as Cmd/Ctrl+click or Shift+click on it
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_ctrl]
    mov ecx, 4
    call str_ends
    test eax, eax
    jz 1f
    mov ebx, MOD_CTRL
    sub r13, 5
    jmp 2f
1:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_shift]
    mov ecx, 5
    call str_ends
    test eax, eax
    jz 2f
    mov ebx, MOD_SHIFT
    sub r13, 6
2:  lea rdi, [rip + lv_panel]
    mov rsi, r12
    mov rdx, r13
    call find_row
    test rax, rax
    jz 8f
    mov [rip + g_mods], ebx
    lea rdi, [rip + lv_panel]
    mov rsi, rax
    call row_click
    mov dword ptr [rip + g_mods], 0
    mov qword ptr [rip + pend_open], 0
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

c_menu:
    lea rdx, [rip + lv_panel]
    jmp menu_cmd
c_drop_menu:
    lea rdx, [rip + lv_drop]
menu_cmd:                       # (title ptr, len, LV*)
    PROLOGUE
    mov rbx, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, rbx
    call find_row
    test rax, rax
    jz 8f
    mov rdi, rbx
    mov rsi, rax
    call menu_row_ask
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

c_group_menu:
    PROLOGUE
    call find_group
    test eax, eax
    jz 8f
    mov edi, eax
    lea rsi, [rip + lv_panel]
    call menu_group_ask
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

c_filter_menu:
    PROLOGUE
    lea rdi, [rip + lv_panel]
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call filter_menu_ask
    xor eax, eax
    EPILOGUE

c_rename:
    PROLOGUE
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + lv_panel]
    call find_row
    test rax, rax
    jz 8f
    lea rdi, [rip + lv_panel]
    mov rsi, rax
    call rename_session_begin
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

c_rename_group:
    PROLOGUE
    call find_group
    test eax, eax
    jz 8f
    mov edi, eax
    lea rsi, [rip + lv_panel]
    call rename_group_begin
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

c_new_group:
    PROLOGUE
    call new_group_rename
    xor eax, eax
    EPILOGUE

c_toggle:                       # toggle NAME|ungrouped|archived: as a click on its header
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rdx, [rip + .Lw_ungrouped]
    call str_eq_cstr
    mov ecx, SH_UNGROUPED_SHUT
    test eax, eax
    jnz 2f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_archived]
    call str_eq_cstr
    mov ecx, SH_ARCHIVED_OPEN
    test eax, eax
    jnz 2f
    mov rdi, r12
    mov rsi, r13
    call find_group
    test eax, eax
    jz 8f
    mov edi, eax
    call agst_group_flip
    xor eax, eax
    EPILOGUE
2:  mov ebx, ecx
    call agst_show
    xor eax, ebx
    mov edi, eax
    call agst_set_show
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

c_drag:                         # drag TITLE -> NAME|ungrouped: the row dropped on that header
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_arrow]
    mov ecx, 4
    call str_find
    test rax, rax
    js 8f
    mov rbx, rax                # the title ends there, the name begins 4 further
    lea rdi, [r12 + rax + 4]
    mov rsi, r13
    sub rsi, rax
    sub rsi, 4
    mov [rsp], rdi
    mov [rsp + 8], rsi
    lea rdx, [rip + .Lw_ungrouped]
    call str_eq_cstr
    xor r14d, r14d
    test eax, eax
    jnz 3f
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call find_group
    test eax, eax
    jz 8f
    mov r14d, eax
3:  lea rdi, [rip + lv_panel]
    mov rsi, r12
    mov rdx, rbx
    call find_row
    test rax, rax
    jz 8f
    mov edi, r14d
    mov rsi, rax
    lea rdx, [rip + lv_panel]
    call move_to_group
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

c_unarchive_all:
    PROLOGUE
    lea rdi, [rip + lv_panel]
    call unarchive_all
    xor eax, eax
    EPILOGUE

c_drop_open:                    # the open conversation's header's history button, as clicked
    PROLOGUE
    call agents_viewed
    test rax, rax
    jz 8f
    mov rdi, rax
    call aghead_history
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

c_drop_close:
    call aglist_drop_close
    xor eax, eax
    ret

c_reopen:                       # reopen: the breaker's "Open it anyway"
    PROLOGUE
    call reopen_anyway
    xor eax, eax
    EPILOGUE

c_grew:                         # grew TITLE: as agents_poll seeing its file grow
    PROLOGUE
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + lv_panel]
    call find_row
    test rax, rax
    jz 8f
    mov rdi, rax
    call aglist_grew
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# FN aglist_ctl_entry(out, rest, len): agent-list (aictl.s's table names it, with aglist_print for
#   print-agent-list and aglist_print_state for print-agent-list-state); the line's end kept for ctl_rest
FN aglist_ctl_entry
    lea rax, [rsi + rdx]
    mov [rip + ctl_end], rax
    jmp aglist_ctl
