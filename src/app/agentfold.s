# Focus view ([agents] focus_view; "Agents: Toggle Focus View", Ctrl+Alt+F; the command menu's switch): a run
# of consecutive thinking and tool rows is one fold line ("N tool calls · M failed", "Thought for Ns", "N hidden
# steps"; while its last call runs "Running NAME…", "Thinking…", "Waiting for permission…", "Waiting for your
# answer…" before the count), a click on it opens the fold (its rows, then a "Collapse" line). The folds are
# records of the session (AS_folds, AF), kept as rows come whether focus view is on or off: a row joins the
# fold of the row before it when that one ends a fold, a fold's counts follow its calls' states and its
# thinking's times, so a line's label costs nothing however long its run and nothing ever walks a run but a
# cut (agents_rows_cut) that ends a fold in its middle. The conversation's latest todo list (AS_todo) stays
# shown as a list alone at its row and is not one of its fold's calls; a wrapped notice (AMF_NOTICE) has no
# height in focus view and ends no run; a hidden call joins a run, counts nothing and ends nothing. A fold
# whose call waits for a permission is shown open while it waits (the extension's rule; a question's fold
# stays closed). Open folds are lost when the rows are read again. Generic: the rows' parts, never a tool's
# name, decide what is what (UI 3.16: dRe, bMt, wMt, CMt @5549084; the grouping @3648000-3650700).
#
# The engine (agents.s) asks: agfold_h for a row's height (0: hidden), agfold_parts for its estimate's parts
# (the chunks' focus aggregates, HX_ffix…, so a toggle sums nothing again), agfold_next / agfold_prev to step
# over a closed fold in one step, agfold_shown for an anchor a fold hid, agfold_key at every frame's key (the
# setting the chunks' own sums are for; the fold a waiting request holds open), agfold_draw before a row is
# drawn.
#
#   agfold_add(AS*, row)                    a row is whole: it joins a fold or starts one
#   agfold_state(AS*, row, old, new)        a call's state changed: its fold's counts follow (old is not read:
#                                           what the fold counted of it is kept in AT_fold)
#   agfold_touch(AS*, row)                  a row changed (agents_msg_changed): its counts, a notice that joins
#                                           the run before it, the todo row the counts leave out
#   agfold_h(AS*, index, w, h) -> eax       the height the engine uses for that row (0: a fold hides it)
#   agfold_parts(AS*, row, fix, lines, bytes) -> eax, edx, ecx    its estimate's parts as focus view shows it
#   agfold_next(AS*, row) -> rax, agfold_prev(AS*, row) -> rax    the next, previous row that may show
#   agfold_shown(AS*, row) -> rax           the row the view shows for it (a closed fold's first row)
#   agfold_own(AS*, row) -> eax             1 when its own parts are drawn
#   agfold_action(AS*, row) -> eax          PART_FOLD for a fold's line, -1 for a row with no action shown
#   agfold_key(AS*)                         th_key's: the chunks' own sums follow the setting and the request
#   agfold_draw(AS*, row, x, y, w, h) -> eax, edx     a fold's line, its Collapse line, a list alone; the place
#                                           and height left for the row's own parts (edx 0: none)
#   agfold_click(AS*, row), agfold_follow() a fold's line clicked: it opens or closes after the frame
#   agfold_toggle_row(AS*, row)             now (agent-fold-click)
#   agfold_cut(AS*, n)                      the rows from n on went
#   agfold_dump(sb, AS*), agfold_row_dump(sb, AS*, row), agfold_fit_dump(sb)
#   agents_toggle_focus_view()              the command; agfold_view_changed() the setting changed
#   agfold_on(AS* or 0, kind) -> eax 1, ecx APRF_ON while on    the command menu's switch (its rule)
.include "rhun.inc"

.equ FL_MAX, 64                 # fold and Collapse lines whose drawn place print-agent-row names
.equ FLK_LINE, 0                # line_lay's kinds
.equ FLK_RUN, 1                 #   the line with a running label (print-agent-folds-fit: the longest)
.equ FLK_COLLAPSE, 2
.equ FLK_BG, 3                  #   (fl_note only: a closed fold's Run in background, task 11)
.equ LL_DRAW, 0                 # line_lay's modes
.equ LL_FIT, 1
.equ MK_CALL, 1                 # kind_of: what a row is to a fold
.equ MK_THINK, 2
.equ MK_NOTICE, 3
.equ MK_HIDDEN, 4
.equ RUN_BG_LEN, 17             # task 11: "Run in background"

.bss
.p2align 3
fsb: .zero SB_SIZE              # a label being made
csb: .zero SB_SIZE
pend_as: .quad 0                # a fold's line clicked, toggled after the frame: the session, the fold's
pend_row: .quad 0               #   first row and its index (pend_fold -1: none, in .data)
fl_n: .long 0                   # the lines the frame fl_ser drew: row, kind, box, id
fl_ser: .long 0
.p2align 3
fl_row: .zero 8 * FL_MAX
fl_kind: .zero 4 * FL_MAX
fl_id: .zero 4 * FL_MAX
fl_box: .zero 16 * FL_MAX
ll_as: .quad 0                  # line_lay's arguments
ll_row: .quad 0
ll_out: .quad 0
ll_fold: .long 0
ll_x: .long 0
ll_y: .long 0
ll_w: .long 0
ll_kind: .long 0
ll_mode: .long 0

.data
pend_fold: .long -1

.text

# ---------------- records ----------------

# am_of(AS*, row) -> rax AM*
am_of:
    imul rax, rsi, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    ret

# af_of(AS*, fold) -> rax AF*
af_of:
    imul rax, rsi, AF_SIZE
    add rax, [rdi + AS_folds + VEC_ptr]
    ret

# kind_of(AM*) -> eax what a row is to a fold: MK_CALL, MK_THINK, MK_NOTICE (a wrapped notice), MK_HIDDEN (a
#   hidden call), 0 anything else (it ends a run)
kind_of:
    mov rcx, [rdi + AM_x]
    test rcx, rcx
    jz 1f
    mov eax, MK_HIDDEN
    test dword ptr [rcx + AT_flags], ATF_HIDDEN
    jnz 9f
    mov eax, MK_CALL
    ret
1:  mov eax, MK_THINK
    cmp dword ptr [rdi + AM_role], R_THINK
    je 9f
    mov eax, MK_NOTICE
    test dword ptr [rdi + AM_flags], AMF_NOTICE
    jnz 9f
    xor eax, eax
9:  ret

# chunk_dirty(AS*, row): its chunk's sums and aggregates are made again when needed
chunk_dirty:
    mov rax, rsi
    shr rax, HX_SHIFT
    cmp rax, [rdi + AS_hx + VEC_len]
    jae 9f
    imul rax, rax, HX_SIZE
    add rax, [rdi + AS_hx + VEC_ptr]
    mov dword ptr [rax + HX_flags], 0
9:  ret

# fold_dirty(AS*, fold): every chunk of its rows (it opened, closed, was cut)
fold_dirty:
    cmp rsi, [rdi + AS_folds + VEC_len]
    jae 9f
    imul rax, rsi, AF_SIZE
    add rax, [rdi + AS_folds + VEC_ptr]
    movsxd rcx, dword ptr [rax + AF_first]
    movsxd rdx, dword ptr [rax + AF_last]
    shr rcx, HX_SHIFT
    shr rdx, HX_SHIFT
1:  cmp rcx, rdx
    ja 8f
    cmp rcx, [rdi + AS_hx + VEC_len]
    jae 8f
    imul rax, rcx, HX_SIZE
    add rax, [rdi + AS_hx + VEC_ptr]
    mov dword ptr [rax + HX_flags], 0
    inc rcx
    jmp 1b
8:  mov dword ptr [rip + g_dirty], 1
9:  ret

# shows(AF*) -> eax 1 when it has a line: something of it is counted (a fold of the latest todo list alone
#   has none)
shows:
    mov eax, [rdi + AF_calls]
    add eax, [rdi + AF_thinks]
    add eax, [rdi + AF_other]
    test eax, eax
    setg al
    movzx eax, al
    ret

# is_open(AS*, fold) -> eax 1 when its rows show: opened, or held open by a waiting request
is_open:
    lea eax, [rsi + 1]
    cmp eax, [rdi + AS_fask]
    je 1f
    imul rax, rsi, AF_SIZE
    add rax, [rdi + AS_folds + VEC_ptr]
    mov eax, [rax + AF_flags]
    and eax, AFF_OPEN
    ret
1:  mov eax, 1
    ret

# todo_row(AS*) -> rax the row shown as a list alone (the latest todo list as the counts follow it), -1
todo_row:
    movsxd rax, dword ptr [rdi + AS_ftodo]
    dec rax
    ret

# live(AS*) -> eax 1 while the conversation rhun drives works or waits (a label says what runs)
live:
    xor eax, eax
    cmp qword ptr [rdi + AS_live], 0
    je 9f
    mov ecx, [rdi + AS_state]
    cmp ecx, AGS_WORKING
    je 1f
    cmp ecx, AGS_WAITING
    jne 9f
1:  mov eax, 1
9:  ret

# ---------------- counts ----------------

# refresh(AS*, row): what its fold counts of it follows the row: a call is a call unless it is the list shown
#   alone, failed when it failed, was denied or stopped; thinking adds its time once it has one
refresh:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 9f
    call am_of
    mov r13, rax
    movsxd rsi, dword ptr [r13 + AM_fold]
    test rsi, rsi
    js 9f
    cmp rsi, [rbx + AS_folds + VEC_len]
    jae 9f
    mov rdi, rbx
    call af_of
    mov r14, rax
    mov rdi, r13
    call kind_of
    cmp eax, MK_CALL
    je 1f
    cmp eax, MK_THINK
    jne 9f
    test dword ptr [r13 + AM_flags], AMF_FMS        # thinking: its time, once
    jnz 9f
    mov eax, [r13 + AM_ms]
    test eax, eax
    js 9f
    mov ecx, [r14 + AF_ms]
    test ecx, ecx
    jns 2f
    xor ecx, ecx
2:  add ecx, eax
    mov [r14 + AF_ms], ecx
    or dword ptr [r13 + AM_flags], AMF_FMS
    jmp 9f
1:  mov r15, [r13 + AM_x]       # a call: what it should count
    mov rdi, rbx
    call todo_row
    xor ecx, ecx
    cmp rax, r12
    je 3f
    mov ecx, 1
    mov eax, [r15 + AT_state]
    cmp eax, ATS_FAILED
    je 4f
    cmp eax, ATS_DENIED
    je 4f
    cmp eax, ATS_STOPPED
    jne 3f
4:  or ecx, 2
3:  mov edx, [r15 + AT_fold]
    cmp ecx, edx
    je 9f
    mov [r15 + AT_fold], ecx
    mov eax, ecx                # the calls: by the change of bit 0, the failed ones of bit 1
    and eax, 1
    mov r8d, edx
    and r8d, 1
    sub eax, r8d
    add [r14 + AF_calls], eax
    shr ecx, 1
    shr edx, 1
    sub ecx, edx
    add [r14 + AF_failed], ecx
    mov rdi, rbx                # its line may come or go
    movsxd rsi, dword ptr [r14 + AF_first]
    call chunk_dirty
9:  EPILOGUE

# join(AS*, row, fold): the row is the fold's last now; it counts what it is
join:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rdi, rbx
    mov esi, r13d
    call af_of
    mov r14, rax
    mov rdi, rbx                # the row that was its last: its Collapse line moves
    movsxd rsi, dword ptr [r14 + AF_last]
    call chunk_dirty
    mov [r14 + AF_last], r12d
    mov rdi, rbx
    mov rsi, r12
    call chunk_dirty
    mov rdi, rbx
    mov rsi, r12
    call am_of
    mov r15, rax
    mov [r15 + AM_fold], r13d
    mov rdi, r15
    call kind_of
    cmp eax, MK_CALL
    jne 1f
    mov rcx, [r15 + AM_x]
    mov dword ptr [rcx + AT_fold], 0
    jmp 8f
1:  cmp eax, MK_THINK
    jne 2f
    inc dword ptr [r14 + AF_thinks]
    and dword ptr [r15 + AM_flags], ~AMF_FMS
    jmp 7f
2:  cmp eax, MK_NOTICE
    jne 9f
    inc dword ptr [r14 + AF_other]
7:  mov rdi, rbx
    movsxd rsi, dword ptr [r14 + AF_first]
    call chunk_dirty
8:  mov rdi, rbx
    mov rsi, r12
    call refresh
9:  EPILOGUE

# FN agfold_add(AS*, row): a row is whole (add_msg for every row but a call's, agrow_ready for a call once its
#   flags are final): a thinking row, a call, a notice or a hidden call joins the fold of the row before it
#   when that one is the fold's last; else thinking and a call start a fold (only after the last fold: the
#   folds stay in the order of their rows); anything else ends the run by being in none
FN agfold_add
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 9f
    call am_of
    mov r13, rax
    cmp dword ptr [r13 + AM_fold], 0
    jl 1f
    mov rdi, rbx                # already in one: its counts follow it
    mov rsi, r12
    call refresh
    jmp 9f
1:  mov rdi, r13
    call kind_of
    mov r14d, eax
    test eax, eax
    jz 9f
    test r12, r12
    jz 3f
    movsxd rsi, dword ptr [r13 - AM_SIZE + AM_fold]     # the row before it
    test rsi, rsi
    js 3f
    cmp rsi, [rbx + AS_folds + VEC_len]
    jae 3f
    mov r15, rsi
    mov rdi, rbx
    call af_of
    movsxd rcx, dword ptr [rax + AF_last]
    inc rcx
    cmp rcx, r12
    jne 3f
    mov rdi, rbx
    mov rsi, r12
    mov edx, r15d
    call join
    jmp 9f
3:  cmp r14d, MK_CALL
    je 4f
    cmp r14d, MK_THINK
    jne 9f
4:  mov rcx, [rbx + AS_folds + VEC_len]
    test rcx, rcx
    jz 5f
    dec rcx
    imul rax, rcx, AF_SIZE
    add rax, [rbx + AS_folds + VEC_ptr]
    movsxd rcx, dword ptr [rax + AF_last]
    cmp rcx, r12
    jge 9f
5:  lea rdi, [rbx + AS_folds]
    mov esi, AF_SIZE
    call vec_push
    mov [rax + AF_first], r12d
    mov [rax + AF_last], r12d
    mov dword ptr [rax + AF_calls], 0
    mov dword ptr [rax + AF_failed], 0
    mov dword ptr [rax + AF_thinks], 0
    mov dword ptr [rax + AF_other], 0
    mov dword ptr [rax + AF_ms], -1
    mov dword ptr [rax + AF_flags], 0
    mov rdx, [rbx + AS_folds + VEC_len]
    dec rdx
    mov rdi, rbx
    mov rsi, r12
    call join
9:  EPILOGUE

# FN agfold_state(AS*, row, old ATS_*, new): a call's state changed (agrow_done, agrow_stop, a thinking row's
#   time: ev_thought_end): its fold's counts follow. What the fold counted is kept with the call (AT_fold), so
#   old is not read: a stopped call whose result still comes is counted right
FN agfold_state
    jmp refresh

# FN agfold_touch(AS*, row): a row changed (agents_msg_changed): the todo row the counts leave out follows
#   AS_todo (its fold and the one it left count again), the row's counts follow it, and a row that became a
#   wrapped notice after it was added joins the run before it
FN agfold_touch
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    movsxd rax, dword ptr [rbx + AS_todo]
    inc rax
    cmp rax, [rbx + AS_msgs + VEC_len]
    ja 3f                       # (none, or a row not there yet)
    movsxd r13, dword ptr [rbx + AS_ftodo]
    cmp eax, r13d
    je 3f
    mov [rbx + AS_ftodo], eax
    mov r14, rax
    test r13, r13
    jz 1f
    dec r13
    cmp r13, [rbx + AS_msgs + VEC_len]
    jae 1f
    mov rdi, rbx
    mov rsi, r13
    call refresh
    mov rdi, rbx
    mov rsi, r13
    call chunk_dirty
1:  test r14, r14
    jz 3f
    dec r14
    mov rdi, rbx
    mov rsi, r14
    call refresh
    mov rdi, rbx
    mov rsi, r14
    call chunk_dirty
3:  cmp r12, [rbx + AS_msgs + VEC_len]
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call am_of
    cmp dword ptr [rax + AM_fold], 0
    jl 4f
    mov rdi, rbx
    mov rsi, r12
    call refresh
    jmp 9f
4:  test dword ptr [rax + AM_flags], AMF_NOTICE
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call agfold_add
9:  EPILOGUE

# recount(AS*, fold): its counts from its rows again (a cut ended it in its middle)
recount:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call af_of
    mov r14, rax
    mov dword ptr [r14 + AF_calls], 0
    mov dword ptr [r14 + AF_failed], 0
    mov dword ptr [r14 + AF_thinks], 0
    mov dword ptr [r14 + AF_other], 0
    mov dword ptr [r14 + AF_ms], -1
    movsxd r13, dword ptr [r14 + AF_first]
    movsxd r15, dword ptr [r14 + AF_last]
    mov [r14 + AF_last], r13d   # join makes each the last again, from the first
    dec r13
1:  inc r13
    cmp r13, r15
    jg 9f
    cmp r13, [rbx + AS_msgs + VEC_len]
    jae 9f
    mov rdi, rbx
    mov rsi, r13
    call am_of
    mov dword ptr [rax + AM_fold], -1
    mov rdi, rbx
    mov rsi, r13
    mov edx, r12d
    call join
    jmp 1b
9:  EPILOGUE

# FN agfold_cut(AS*, n): the rows from n on went (agents_rows_cut): the folds that began there go, the one
#   across n ends before it and counts its rows again; what names a fold or a row that went is forgotten
FN agfold_cut
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
1:  mov rcx, [rbx + AS_folds + VEC_len]
    test rcx, rcx
    jz 3f
    dec rcx
    imul rax, rcx, AF_SIZE
    add rax, [rbx + AS_folds + VEC_ptr]
    movsxd rdx, dword ptr [rax + AF_first]
    cmp rdx, r12
    jl 2f
    mov [rbx + AS_folds + VEC_len], rcx
    jmp 1b
2:  movsxd rdx, dword ptr [rax + AF_last]
    cmp rdx, r12
    jl 3f
    lea rdx, [r12 - 1]
    mov [rax + AF_last], edx
    mov r13, rcx
    movsxd rax, dword ptr [rbx + AS_ftodo]      # the list shown alone went too: none
    cmp rax, r12
    jbe 21f
    mov dword ptr [rbx + AS_ftodo], 0
21: mov rdi, rbx
    mov esi, r13d
    call recount
    mov rdi, rbx
    mov rsi, r13
    call fold_dirty
3:  movsxd rax, dword ptr [rbx + AS_ftodo]
    cmp rax, r12
    jbe 4f
    mov dword ptr [rbx + AS_ftodo], 0
4:  movsxd rax, dword ptr [rbx + AS_fask]
    cmp rax, [rbx + AS_folds + VEC_len]
    jbe 5f
    mov dword ptr [rbx + AS_fask], 0
5:  cmp [rip + pend_as], rbx
    jne 9f
    movsxd rax, dword ptr [rip + pend_fold]
    cmp rax, [rbx + AS_folds + VEC_len]
    jb 9f
    mov dword ptr [rip + pend_fold], -1
9:  EPILOGUE

# ---------------- heights ----------------

# line_h() -> eax a fold's line and its Collapse line: the text face's line, at least MI_20, MI_4 above and
#   below it
line_h:
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    mov ecx, [rip + g_pmt + 4*MI_20]
    cmp eax, ecx
    cmovl eax, ecx
    add eax, [rip + g_pmt + 4*MI_8]
    ret

# hidden(AS*, row) -> eax 1 when focus view hides it whole: in a closed fold, not its first row, not the list
#   shown alone; a wrapped notice
hidden:
    xor eax, eax
    cmp dword ptr [rip + cfg_agents_focus_view], 0
    je 9f
    cmp rsi, [rdi + AS_msgs + VEC_len]
    jae 9f
    imul rcx, rsi, AM_SIZE
    add rcx, [rdi + AS_msgs + VEC_ptr]
    test dword ptr [rcx + AM_flags], AMF_NOTICE
    jnz 8f
    movsxd rdx, dword ptr [rcx + AM_fold]
    test rdx, rdx
    js 9f
    movsxd rcx, dword ptr [rdi + AS_ftodo]
    dec rcx
    cmp rcx, rsi
    je 9f
    imul rcx, rdx, AF_SIZE
    add rcx, [rdi + AS_folds + VEC_ptr]
    movsxd r8, dword ptr [rcx + AF_first]
    cmp r8, rsi
    je 9f
    lea r8d, [rdx + 1]
    cmp r8d, [rdi + AS_fask]
    je 9f
    test dword ptr [rcx + AF_flags], AFF_OPEN
    jnz 9f
8:  mov eax, 1
9:  ret

# FN agfold_h(AS*, index, w, h) -> eax the height the engine uses for a row whose own height is h: with focus
#   view a closed fold shows its first row as its line (and the list shown alone at its row), an open one its
#   rows under its line and a Collapse line after its last; a wrapped notice 0
FN agfold_h
    mov eax, ecx
    cmp dword ptr [rip + cfg_agents_focus_view], 0
    jne 1f
    ret
1:  PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    call am_of
    mov r15, rax
    xor eax, eax
    test dword ptr [r15 + AM_flags], AMF_NOTICE
    jnz 9f
    mov eax, r14d
    movsxd rsi, dword ptr [r15 + AM_fold]
    test rsi, rsi
    js 9f
    cmp rsi, [rbx + AS_folds + VEC_len]
    jae 9f
    mov [rsp], esi
    mov rdi, rbx
    call is_open
    mov [rsp + 4], eax
    xor ecx, ecx
    test eax, eax
    jz 1f
    mov ecx, r14d               # open: its own height
1:  mov [rsp + 8], ecx
    mov rdi, rbx
    call todo_row
    cmp rax, r12
    jne 2f
    mov rdi, [r15 + AM_x]       # the list shown alone
    test rdi, rdi
    jz 2f
    mov esi, r13d
    call agrow_todo_h
    mov [rsp + 8], eax
2:  mov rdi, rbx
    mov esi, [rsp]
    call af_of
    mov r15, rax
    mov rdi, r15
    call shows
    test eax, eax
    jz 8f
    movsxd rcx, dword ptr [r15 + AF_first]
    cmp rcx, r12
    jne 3f
    call line_h
    add [rsp + 8], eax
3:  cmp dword ptr [rsp + 4], 0
    je 8f
    movsxd rcx, dword ptr [r15 + AF_last]
    cmp rcx, r12
    jne 8f
    call line_h
    add [rsp + 8], eax
8:  mov eax, [rsp + 8]
9:  EPILOGUE

# FN agfold_parts(AS*, row, fix, lines, bytes) -> eax fix, edx lines, ecx bytes: the parts of its estimate
#   as focus view shows it (the chunks' focus aggregates; asked whether the setting is on or off)
FN agfold_parts
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 8], r8d
    call am_of
    mov r15, rax
    test dword ptr [r15 + AM_flags], AMF_NOTICE
    jnz 7f
    movsxd rsi, dword ptr [r15 + AM_fold]
    test rsi, rsi
    js 8f
    cmp rsi, [rbx + AS_folds + VEC_len]
    jae 8f
    mov [rsp + 12], esi
    mov rdi, rbx
    call is_open
    mov [rsp + 16], eax
    test eax, eax
    jnz 1f
    mov dword ptr [rsp], 0      # closed: none of its own
    mov dword ptr [rsp + 4], 0
    mov dword ptr [rsp + 8], 0
1:  mov rdi, rbx
    call todo_row
    cmp rax, r12
    jne 2f
    mov r13, [r15 + AM_x]       # the list alone: a line an item, MI_4 between and around them
    test r13, r13
    jz 2f
    mov r14, [r13 + AT_items + VEC_len]
    lea eax, [r14 + 2]
    imul eax, dword ptr [rip + g_pmt + 4*MI_4]
    mov [rsp], eax
    mov [rsp + 4], r14d
    mov dword ptr [rsp + 8], 0
    xor r15d, r15d
11: cmp r15, r14
    jae 2f
    imul rax, r15, ATI_SIZE
    add rax, [r13 + AT_items + VEC_ptr]
    mov rdi, [rax + ATI_text]
    call strlen
    add [rsp + 8], eax
    inc r15
    jmp 11b
2:  mov rdi, rbx
    mov esi, [rsp + 12]
    call af_of
    mov r15, rax
    mov rdi, r15
    call shows
    test eax, eax
    jz 8f
    movsxd rcx, dword ptr [r15 + AF_first]
    cmp rcx, r12
    jne 3f
    call line_h
    add [rsp], eax
3:  cmp dword ptr [rsp + 16], 0
    je 8f
    movsxd rcx, dword ptr [r15 + AF_last]
    cmp rcx, r12
    jne 8f
    call line_h
    add [rsp], eax
8:  mov eax, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    EPILOGUE
7:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    EPILOGUE

# FN agfold_next(AS*, row) -> rax the next row that may show: past a closed fold in one step (to the list
#   shown alone in it, else the row after it)
FN agfold_next
    lea rax, [rsi + 1]
    cmp dword ptr [rip + cfg_agents_focus_view], 0
    je 9f
    PROLOGUE
    mov rbx, rdi
    mov r12, rax
    mov rsi, rax
    call hidden
    test eax, eax
    mov rax, r12
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call am_of
    movsxd rsi, dword ptr [rax + AM_fold]
    mov rax, r12
    test rsi, rsi
    js 8f                       # (a notice)
    mov rdi, rbx
    call af_of
    movsxd r13, dword ptr [rax + AF_last]
    mov rdi, rbx
    call todo_row
    cmp rax, r12
    jl 1f
    cmp rax, r13
    jle 8f
1:  lea rax, [r13 + 1]
8:  EPILOGUE
9:  ret

# FN agfold_prev(AS*, row) -> rax the previous row that may show: before a closed fold, its line (or the list
#   shown alone in it)
FN agfold_prev
    lea rax, [rsi - 1]
    cmp dword ptr [rip + cfg_agents_focus_view], 0
    je 9f
    test rax, rax
    js 9f
    PROLOGUE
    mov rbx, rdi
    mov r12, rax
    mov rsi, rax
    call hidden
    test eax, eax
    mov rax, r12
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call am_of
    movsxd rsi, dword ptr [rax + AM_fold]
    mov rax, r12
    test rsi, rsi
    js 8f
    mov rdi, rbx
    call af_of
    movsxd r13, dword ptr [rax + AF_first]
    mov rdi, rbx
    call todo_row
    cmp rax, r12
    jg 1f
    cmp rax, r13
    jg 8f
1:  mov rax, r13
8:  EPILOGUE
9:  ret

# FN agfold_shown(AS*, row) -> rax the row the view shows in its place: a row a closed fold hides is its line
FN agfold_shown
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call hidden
    test eax, eax
    mov rax, r12
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call am_of
    movsxd rsi, dword ptr [rax + AM_fold]
    mov rax, r12
    test rsi, rsi
    js 9f
    mov rdi, rbx
    call af_of
    movsxd rax, dword ptr [rax + AF_first]
9:  EPILOGUE

# FN agfold_own(AS*, row) -> eax 1 when the row's own parts are drawn (not hidden, not a list shown alone, not
#   in a closed fold)
FN agfold_own
    mov eax, 1
    cmp dword ptr [rip + cfg_agents_focus_view], 0
    je 9f
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call todo_row
    cmp rax, r12
    je 8f
    mov rdi, rbx
    mov rsi, r12
    call am_of
    test dword ptr [rax + AM_flags], AMF_NOTICE
    jnz 8f
    movsxd rsi, dword ptr [rax + AM_fold]
    mov eax, 1
    test rsi, rsi
    js 7f
    mov rdi, rbx
    call is_open
    jmp 7f
8:  xor eax, eax
7:  EPILOGUE
9:  ret

# FN agfold_action(AS*, row) -> eax PART_FOLD on a fold's first row (its line: Enter opens or closes it), -1
#   for a row that shows nothing to act on (hidden, a list alone), 0 for the row's own actions
FN agfold_action
    xor eax, eax
    cmp dword ptr [rip + cfg_agents_focus_view], 0
    je 9f
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call hidden
    test eax, eax
    jnz 7f
    mov rdi, rbx
    mov rsi, r12
    call am_of
    movsxd rsi, dword ptr [rax + AM_fold]
    test rsi, rsi
    js 6f
    mov rdi, rbx
    call af_of
    mov r13, rax
    movsxd rcx, dword ptr [r13 + AF_first]
    cmp rcx, r12
    jne 6f
    mov rdi, r13
    call shows
    test eax, eax
    jz 6f
    mov eax, PART_FOLD
    EPILOGUE
6:  mov rdi, rbx
    call todo_row
    cmp rax, r12
    je 7f
    xor eax, eax
    EPILOGUE
7:  mov eax, -1
    EPILOGUE
9:  ret

# ask_fold(AS*) -> eax the fold of the call the oldest waiting request is for (its top-level row's), -1; edx 1
#   a permission (or a plan: its fold is shown open), 2 a question (it stays closed)
ask_fold:
    PROLOGUE
    mov rbx, rdi
    mov rcx, [rbx + AS_live]
    test rcx, rcx
    jz 8f
    cmp qword ptr [rcx + AL_reqs + VEC_len], 0
    je 8f
    mov rcx, [rcx + AL_reqs + VEC_ptr]
    mov r12, [rcx]
    mov eax, [r12 + AQ_kind]
    mov r13d, 1
    cmp eax, AQK_PERMISSION
    je 1f
    cmp eax, AQK_PLAN
    je 1f
    mov r13d, 2
    cmp eax, AQK_QUESTION
    je 1f
    cmp eax, AQK_DIALOG
    jne 8f
1:  mov rdi, [r12 + AQ_tuid]
    test rdi, rdi
    jz 8f
    call strlen
    mov rdx, rax
    mov rsi, [r12 + AQ_tuid]
    mov rdi, rbx
    call agrow_find
    test rax, rax
    jz 8f
2:  mov rcx, [rax + AT_up]      # a subagent's call: its top-level call's row
    test rcx, rcx
    jz 3f
    mov rax, rcx
    jmp 2b
3:  movsxd rsi, dword ptr [rax + AT_row]
    cmp rsi, [rbx + AS_msgs + VEC_len]
    jae 8f
    mov rdi, rbx
    call am_of
    mov eax, [rax + AM_fold]
    test eax, eax
    js 8f
    mov edx, r13d
    EPILOGUE
8:  mov eax, -1
    xor edx, edx
    EPILOGUE

# FN agfold_key(AS*): at the sums' key (th_key, every frame): when the setting changed since the chunks' own
#   sums were made they go (a step a chunk; both sets of aggregates stay); when the fold a waiting request
#   holds open changed, the chunks of the one before and of the new one are made again
FN agfold_key
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    cmp dword ptr [rip + cfg_agents_focus_view], 0
    setne al
    cmp eax, [rbx + AS_fview]
    je 2f
    mov [rbx + AS_fview], eax
    xor ecx, ecx
1:  cmp rcx, [rbx + AS_hx + VEC_len]
    jae 2f
    imul rax, rcx, HX_SIZE
    add rax, [rbx + AS_hx + VEC_ptr]
    and dword ptr [rax + HX_flags], ~HXF_ROWS
    inc rcx
    jmp 1b
2:  mov rdi, rbx
    call ask_fold
    xor r12d, r12d
    cmp edx, 1
    jne 3f
    lea r12d, [rax + 1]
3:  movsxd r13, dword ptr [rbx + AS_fask]
    cmp r12d, r13d
    je 9f
    mov [rbx + AS_fask], r12d
    test r13, r13
    jz 4f
    mov rdi, rbx
    lea rsi, [r13 - 1]
    call fold_dirty
4:  test r12d, r12d
    jz 9f
    mov rdi, rbx
    lea esi, [r12 - 1]
    call fold_dirty
9:  EPILOGUE

# ---------------- labels ----------------

# push_n(sb, n, word cstr): "N word", "N words" but for 1 (sl)
push_n:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    cmp r12d, 1
    je 9f
    mov rdi, rbx
    mov esi, 's'
    call sb_push_byte
9:  EPILOGUE

# fold_label(sb, AS*, AF*): its count (dRe): "N tool calls" and " · M failed"; thinking alone "Thinking…"
#   while its last row streams in a conversation that works, "Thought for Ns" (at least 1), "Thinking"; else
#   "N hidden steps" (at least 1)
fold_label:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov esi, [r13 + AF_calls]
    test esi, esi
    jle 2f
    mov rdi, rbx
    lea rdx, [rip + .Lw_call]
    call push_n
    mov esi, [r13 + AF_failed]
    test esi, esi
    jle 9f
    mov rdi, rbx
    lea rsi, [rip + .Lsep]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + AF_failed]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lfailed]
    call sb_push_cstr
    EPILOGUE
2:  cmp dword ptr [r13 + AF_thinks], 0
    jle 5f
    cmp dword ptr [r13 + AF_other], 0
    jg 5f
    mov rdi, r12                # thinking alone
    call live
    test eax, eax
    jz 3f
    mov rdi, r12
    movsxd rsi, dword ptr [r13 + AF_last]
    call am_of
    cmp dword ptr [rax + AM_role], R_THINK
    jne 3f
    test dword ptr [rax + AM_flags], AMF_LIVE
    jz 3f
    lea rsi, [rip + .Lthinking_live]
    jmp 8f
3:  mov eax, [r13 + AF_ms]
    test eax, eax
    js 4f
    add eax, 500
    xor edx, edx
    mov ecx, 1000
    div ecx
    cmp eax, 1
    jge 31f
    mov eax, 1
31: mov r14d, eax
    mov rdi, rbx
    lea rsi, [rip + .Lthought]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r14d
    call sb_push_u64
    mov rdi, rbx
    mov esi, 's'
    call sb_push_byte
    EPILOGUE
4:  lea rsi, [rip + .Lthinking]
    jmp 8f
5:  mov esi, [r13 + AF_thinks]
    add esi, [r13 + AF_other]
    cmp esi, 1
    jge 6f
    mov esi, 1
6:  mov rdi, rbx
    lea rdx, [rip + .Lw_step]
    call push_n
    EPILOGUE
8:  mov rdi, rbx
    call sb_push_cstr
9:  EPILOGUE

# fold_run(sb, AS*, fold) -> eax 1 when it pushed what runs in it now (bMt), only while the conversation rhun
#   drives works or waits: the waiting request's "Waiting for permission…" / "Waiting for your answer…",
#   "Running NAME…" while its last row is a call that runs, "Thinking…" while it is thinking that streams
fold_run:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rdi, r12
    call live
    mov [rsp], eax              # (not working: only a background agent's call runs, task 11)
    test eax, eax
    jz 2f
    mov rdi, r12
    call ask_fold
    cmp eax, r13d
    jne 2f
    lea rsi, [rip + .Lwait_perm]
    cmp edx, 1
    je 7f
    lea rsi, [rip + .Lwait_answer]
    jmp 7f
2:  mov rdi, r12
    mov esi, r13d
    call af_of
    movsxd rsi, dword ptr [rax + AF_last]
    mov rdi, r12
    call am_of
    mov r14, rax
    mov rcx, [r14 + AM_x]
    test rcx, rcx
    jz 4f
    test dword ptr [rcx + AT_flags], ATF_HIDDEN
    jnz 8f
    mov r15, rcx
    cmp dword ptr [rcx + AT_state], ATS_RUNNING
    jne 20f
    cmp dword ptr [rsp], 0
    jne 21f
20: mov rdi, r12                # task 11: an agent's call has its result at once; its fold runs while the
    mov rsi, [r15 + AT_id]      #   agent works, after the turn too
    call agtask_runs
    test eax, eax
    jz 8f
21: mov rdi, rbx
    lea rsi, [rip + .Lrunning]
    call sb_push_cstr
    mov rsi, [r15 + AT_name]
    test rsi, rsi
    jnz 3f
    lea rsi, [rip + .Ltool]
3:  mov rdi, rbx
    call sb_push_cstr
    mov rax, [rbx + SB_len]     # (a name drawn with its colon, "Agent:", without it here)
    test rax, rax
    jz 31f
    mov rcx, [rbx + SB_ptr]
    cmp byte ptr [rcx + rax - 1], ':'
    jne 31f
    dec qword ptr [rbx + SB_len]
31:
    mov rdi, rbx
    lea rsi, [rip + .Lellipsis]
    call sb_push_cstr
    mov eax, 1
    EPILOGUE
4:  cmp dword ptr [rsp], 0
    je 8f
    cmp dword ptr [r14 + AM_role], R_THINK
    jne 8f
    test dword ptr [r14 + AM_flags], AMF_LIVE
    jz 8f
    lea rsi, [rip + .Lthinking_live]
7:  mov rdi, rbx
    call sb_push_cstr
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# fold_bg(AS*, fold) -> rax the call of a closed fold's last row when it can be sent to the background now
#   (agrow_canbg: its "Run in background" is on the fold's line, as the extension's AMt under a closed fold)
fold_bg:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call is_open
    test eax, eax
    jnz 8f
    mov rdi, rbx
    mov esi, r12d
    call af_of
    movsxd rsi, dword ptr [rax + AF_last]
    mov rdi, rbx
    call am_of
    mov r13, [rax + AM_x]
    test r13, r13
    jz 8f
    mov rdi, rbx
    mov rsi, r13
    call agrow_canbg
    test eax, eax
    jz 8f
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# fold_color(AS*, fold, running) -> eax its dot's colour: running the mode's, a failure T_ERROR, else
#   T_SUCCESS
fold_color:
    PROLOGUE
    test edx, edx
    jz 1f
    call agspin_color
    EPILOGUE
1:  call af_of
    COLOR ecx, T_SUCCESS
    cmp dword ptr [rax + AF_failed], 0
    jle 2f
    COLOR ecx, T_ERROR
2:  mov eax, ecx
    EPILOGUE

# ---------------- drawing ----------------

# fl_note(kind, x, y, w, h, id): a line drawn this frame, for print-agent-row (ll_row the row)
fl_note:
    mov eax, [rip + th_serial]
    cmp eax, [rip + fl_ser]
    je 1f
    mov [rip + fl_ser], eax
    mov dword ptr [rip + fl_n], 0
1:  mov eax, [rip + fl_n]
    cmp eax, FL_MAX
    jae 9f
    inc dword ptr [rip + fl_n]
    mov r10, [rip + ll_row]
    lea r11, [rip + fl_row]
    mov [r11 + rax*8], r10
    lea r11, [rip + fl_kind]
    mov [r11 + rax*4], edi
    lea r11, [rip + fl_id]
    mov [r11 + rax*4], r9d
    shl eax, 4
    lea r11, [rip + fl_box]
    add r11, rax
    mov [r11], esi
    mov [r11 + 4], edx
    mov [r11 + 8], ecx
    mov [r11 + 12], r8d
9:  ret

# fit_box(word cstr, x, y, w, h): "  WORD X,Y,W,H" into ll_out (print-agent-folds-fit)
fit_box:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov r12, [rip + ll_out]
    mov rdi, r12
    lea rsi, [rip + .Lindent]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, rbx
    call sb_push_cstr
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    xor r13d, r13d
1:  mov rdi, r12
    mov esi, [rsp + r13*4]
    call md_push_int
    inc r13d
    cmp r13d, 4
    jae 2f
    mov rdi, r12
    mov esi, ','
    call sb_push_byte
    jmp 1b
2:  mov rdi, r12
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# text_at(word cstr, sb, x, w, color): a text of the line at x, cut to w: drawn (LL_DRAW) or written out
#   (LL_FIT), in the line's text band (ll_y + MI_4, line_h - MI_8)
text_at:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov [rsp], r8d
    cmp dword ptr [rip + ll_mode], LL_FIT
    jne 1f
    call line_h
    sub eax, [rip + g_pmt + 4*MI_8]
    mov r8d, eax
    mov rdi, rbx
    mov esi, r13d
    mov edx, [rip + ll_y]
    add edx, [rip + g_pmt + 4*MI_4]
    mov ecx, r14d
    call fit_box
    EPILOGUE
1:  call line_h
    sub eax, [rip + g_pmt + 4*MI_8]
    mov ecx, eax
    mov rdi, [rip + ag_fui]
    mov esi, r13d
    mov edx, [rip + ll_y]
    add edx, [rip + g_pmt + 4*MI_4]
    mov r8, [r12 + SB_ptr]
    mov r9, [r12 + SB_len]
    mov eax, r14d
    inc eax
    push rax
    mov eax, [rsp + 8]
    push rax
    call ui_text_v_fit
    add rsp, 16
    EPILOGUE

# width_of(sb) -> eax its text's width in the panel's face
width_of:
    mov rsi, [rdi + SB_ptr]
    mov rdx, [rdi + SB_len]
    xor eax, eax
    test rdx, rdx
    jz 9f
    mov rdi, [rip + ag_fui]
    jmp text_width
9:  ret

# line_lay(): a fold's line (FLK_LINE, FLK_RUN) or its Collapse line (FLK_COLLAPSE) of fold ll_fold, row
#   ll_row of ll_as, at ll_x (the rows' text left: its dot in the pad before it), ll_y, ll_w wide, line_h
#   tall: the dot, what runs (T_FG) and the count (muted after it), or the count alone (T_FG); "Collapse";
#   a chevron after the text; the whole line a button (PART_FOLD, PART_COLLAPSE). Drawn, or its boxes written
#   out from its left and top (LL_FIT). Frame: [0] the room for texts, [4] the next x, [8] running,
#   [12] the chevron's size
line_lay:
    PROLOGUE 32
    mov rbx, [rip + ll_as]
    lea rdi, [rip + fsb]
    call sb_clear
    lea rdi, [rip + csb]
    call sb_clear
    mov dword ptr [rsp + 8], 0
    cmp dword ptr [rip + ll_kind], FLK_COLLAPSE
    jne 1f
    lea rdi, [rip + csb]
    lea rsi, [rip + .Lcollapse]
    call sb_push_cstr
    jmp 3f
1:  cmp dword ptr [rip + ll_kind], FLK_RUN
    jne 2f
    lea rdi, [rip + fsb]        # (the fit's: the longest running label)
    lea rsi, [rip + .Lwait_perm]
    call sb_push_cstr
    mov dword ptr [rsp + 8], 1
    jmp 21f
2:  lea rdi, [rip + fsb]
    mov rsi, rbx
    mov edx, [rip + ll_fold]
    call fold_run
    mov [rsp + 8], eax
21: mov rdi, rbx
    mov esi, [rip + ll_fold]
    call af_of
    mov rdx, rax
    lea rdi, [rip + csb]
    mov rsi, rbx
    call fold_label
3:  PM eax, MI_12
    mov [rsp + 12], eax
    mov eax, [rip + ll_w]       # the texts' room: the chevron and its gap after them
    sub eax, [rsp + 12]
    sub eax, [rip + g_pmt + 4*MI_4]
    jns 31f
    xor eax, eax
31: mov [rsp], eax
    mov eax, [rip + ll_x]
    mov [rsp + 4], eax
    mov dword ptr [rsp + 16], 0 # task 11: a closed fold whose last call can go to the background: "Run in
    cmp dword ptr [rip + ll_mode], LL_DRAW      #   background" before the chevron (the extension's AMt)
    jne 34f
    mov rdi, rbx
    mov esi, [rip + ll_fold]
    call fold_bg
    test rax, rax
    jz 34f
    mov [rsp + 24], rax
    mov rdi, [rip + ag_fui]
    lea rsi, [rip + .Lrun_bg]
    mov edx, RUN_BG_LEN
    call text_width
    add eax, [rip + g_pmt + 4*MI_8]
    mov ecx, [rsp]
    shr ecx, 1
    cmp eax, ecx
    jle 32f
    mov eax, ecx
32: mov [rsp + 16], eax
    add eax, [rip + g_pmt + 4*MI_4]
    sub [rsp], eax
    jns 34f
    mov dword ptr [rsp], 0
34: cmp dword ptr [rip + ll_mode], LL_DRAW      # the dot
    jne 4f
    cmp dword ptr [rsp + 8], 0
    je 32f
    mov rdi, rbx                # running: it blinks where rhun drives the turn
    call agspin_blink
    test eax, eax
    jz 4f
32: mov rdi, rbx
    mov esi, [rip + ll_fold]
    mov edx, [rsp + 8]
    call fold_color
    mov r12d, eax
    call line_h
    sub eax, [rip + g_pmt + 4*MI_8]
    mov edx, eax
    mov ecx, r12d
    mov edi, [rip + ll_x]
    mov esi, [rip + ll_y]
    add esi, [rip + g_pmt + 4*MI_4]
    call agrow_dot
4:  cmp dword ptr [rsp + 8], 0  # what runs
    je 5f
    lea rdi, [rip + fsb]
    call width_of
    cmp eax, [rsp]
    jle 41f
    mov eax, [rsp]
41: mov r12d, eax
    lea rdi, [rip + .Lk_run]
    lea rsi, [rip + fsb]
    mov edx, [rsp + 4]
    mov ecx, r12d
    COLOR r8d, T_FG
    call text_at
    add r12d, [rip + g_pmt + 4*MI_8]
    add [rsp + 4], r12d
    cmp qword ptr [rip + csb + SB_len], 0
    je 6f
    cmp dword ptr [rip + ll_kind], FLK_COLLAPSE
    je 5f
    mov rdi, rbx                # the count only when there are calls (wMt)
    mov esi, [rip + ll_fold]
    call af_of
    cmp dword ptr [rax + AF_calls], 0
    jle 6f
5:  mov eax, [rip + ll_x]       # the count, or "Collapse"
    add eax, [rsp]
    sub eax, [rsp + 4]
    cmp eax, [rip + g_pmt + 4*MI_16]
    jl 6f                       # no room left for it
    mov r13d, eax
    lea rdi, [rip + csb]
    call width_of
    cmp eax, r13d
    jle 51f
    mov eax, r13d
51: mov r12d, eax
    COLOR r8d, T_FG
    cmp dword ptr [rsp + 8], 0
    je 52f
    COLOR r8d, T_MUTED
52: lea rdi, [rip + .Lk_label]
    lea rsi, [rip + csb]
    mov edx, [rsp + 4]
    mov ecx, r12d
    call text_at
    add [rsp + 4], r12d
6:  mov eax, [rsp + 4]          # the chevron
    add eax, [rip + g_pmt + 4*MI_4]
    mov ecx, [rip + ll_x]
    add ecx, [rip + ll_w]
    sub ecx, [rsp + 12]
    cmp eax, ecx
    jle 61f
    mov eax, ecx
61: mov r12d, eax
    call line_h
    sub eax, [rsp + 12]
    sar eax, 1
    add eax, [rip + ll_y]
    mov r13d, eax
    cmp dword ptr [rip + ll_mode], LL_FIT
    jne 62f
    lea rdi, [rip + .Lk_chevron]
    mov esi, r12d
    mov edx, r13d
    mov ecx, [rsp + 12]
    mov r8d, ecx
    call fit_box
    call line_h
    mov r8d, eax
    lea rdi, [rip + .Lk_button]
    mov esi, [rip + ll_x]
    mov edx, [rip + ll_y]
    mov ecx, [rip + ll_w]
    call fit_box
    EPILOGUE
62: mov edi, IC_CHEV_UP
    cmp dword ptr [rip + ll_kind], FLK_COLLAPSE
    je 63f
    mov rdi, rbx
    mov esi, [rip + ll_fold]
    call is_open
    mov ecx, eax
    mov edi, IC_CHEV_UP
    test ecx, ecx
    jnz 63f
    mov edi, IC_CHEV_D
63: mov esi, r12d
    mov edx, r13d
    mov ecx, [rsp + 12]
    COLOR r8d, T_MUTED
    call icon_draw
    mov rdi, [rip + ll_row]     # the line is a button
    xor esi, esi
    call agrow_slot
    test eax, eax
    js 9f
    shl eax, 6
    add eax, ID_AG_PART + PART_FOLD
    cmp dword ptr [rip + ll_kind], FLK_COLLAPSE
    jne 64f
    add eax, PART_COLLAPSE - PART_FOLD
64: mov r14d, eax
    call line_h
    mov r8d, eax
    mov edi, r14d
    mov esi, [rip + ll_x]
    mov edx, [rip + ll_y]
    mov ecx, [rip + ll_w]
    call ui_btn
    mov r15d, eax
    call line_h
    mov r8d, eax
    mov edi, [rip + ll_kind]
    mov esi, [rip + ll_x]
    mov edx, [rip + ll_y]
    mov ecx, [rip + ll_w]
    mov r9d, r14d
    call fl_note
    cmp dword ptr [rsp + 16], 0 # Run in background: its own button over the line's (task 11)
    je 66f
    mov eax, r12d               # after the chevron (r12d: its x)
    add eax, [rsp + 12]
    add eax, [rip + g_pmt + 4*MI_4]
    mov [rsp + 20], eax
    call line_h
    mov r8d, eax
    lea edi, [r14 - PART_FOLD + PART_BG]
    mov esi, [rsp + 20]
    mov edx, [rip + ll_y]
    mov ecx, [rsp + 16]
    call ui_btn
    mov r13d, eax
    call line_h
    mov r8d, eax
    mov edi, FLK_BG
    mov esi, [rsp + 20]
    mov edx, [rip + ll_y]
    mov ecx, [rsp + 16]
    lea r9d, [r14 - PART_FOLD + PART_BG]
    call fl_note
    test r13d, UB_HOVER         # (the button's flags, kept)
    jz 65f
    mov dword ptr [rip + g_cursor], CUR_POINTER
65: call line_h
    sub eax, [rip + g_pmt + 4*MI_8]
    mov ecx, eax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 20]
    add esi, [rip + g_pmt + 4*MI_4]
    mov edx, [rip + ll_y]
    add edx, [rip + g_pmt + 4*MI_4]
    lea r8, [rip + .Lrun_bg]
    mov r9d, RUN_BG_LEN
    COLOR eax, T_ACCENT
    mov r10d, [rsp + 16]
    sub r10d, [rip + g_pmt + 4*MI_4]
    push r10
    push rax
    call ui_text_v_fit
    add rsp, 16
    test r13d, UB_CLICK
    jz 66f
    mov rdi, [rip + ll_row]
    mov rsi, [rsp + 24]
    mov edx, PART_BG
    call agrow_pend
    jmp 9f
66: test r15d, UB_CLICK
    jz 7f
    mov rdi, rbx
    mov rsi, [rip + ll_row]
    call agfold_click
7:  cmp dword ptr [rip + ll_kind], FLK_COLLAPSE     # the row focus on the fold's line: a frame round it
    je 9f
    call agrow_focus
    cmp rax, [rip + ll_row]
    jne 9f
    call line_h
    mov r13d, eax
    mov r12d, [rip + ll_x]
    sub r12d, [rip + g_pmt + 4*MI_4]
    mov r14d, [rip + ll_w]
    add r14d, [rip + g_pmt + 4*MI_8]
    mov edi, r12d               # top, bottom, left, right
    mov esi, [rip + ll_y]
    mov edx, r14d
    mov ecx, 1
    COLOR r8d, T_ACCENT
    call gfx_fill
    mov edi, r12d
    mov esi, [rip + ll_y]
    add esi, r13d
    dec esi
    mov edx, r14d
    mov ecx, 1
    COLOR r8d, T_ACCENT
    call gfx_fill
    mov edi, r12d
    mov esi, [rip + ll_y]
    mov edx, 1
    mov ecx, r13d
    COLOR r8d, T_ACCENT
    call gfx_fill
    lea edi, [r12 + r14 - 1]
    mov esi, [rip + ll_y]
    mov edx, 1
    mov ecx, r13d
    COLOR r8d, T_ACCENT
    call gfx_fill
9:  EPILOGUE

# FN agfold_draw(AS*, row, x, y, w, h) -> eax the y and edx the height left for the row's own parts (0: they
#   are not drawn): with focus view a fold's line above its first row, its Collapse line under its last when
#   it is open, the list shown alone in place of its row (x: the rows' text left; h: what agfold_h gave)
FN agfold_draw
    cmp dword ptr [rip + cfg_agents_focus_view], 0
    jne 1f
    mov eax, ecx
    mov edx, r9d
    ret
1:  PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    mov [rsp], r9d              # h
    mov [rsp + 4], ecx          # the own parts' y
    mov [rsp + 8], r9d          #   and height
    mov dword ptr [rsp + 12], 0 # something drawn
    call am_of
    movsxd rsi, dword ptr [rax + AM_fold]
    test rsi, rsi
    js 8f
    cmp rsi, [rbx + AS_folds + VEC_len]
    jae 8f
    mov [rsp + 16], esi
    mov rdi, rbx
    call is_open
    mov [rsp + 20], eax
    mov rdi, rbx
    mov esi, [rsp + 16]
    call af_of
    mov rdi, rax
    mov [rsp + 24], rax
    call shows
    test eax, eax
    jz 3f
    mov [rip + ll_as], rbx
    mov [rip + ll_row], r12
    mov eax, [rsp + 16]
    mov [rip + ll_fold], eax
    mov [rip + ll_x], r13d
    mov [rip + ll_w], r15d
    mov dword ptr [rip + ll_mode], LL_DRAW
    mov rax, [rsp + 24]
    movsxd rcx, dword ptr [rax + AF_first]
    cmp rcx, r12
    jne 2f
    mov [rip + ll_y], r14d      # its line
    mov dword ptr [rip + ll_kind], FLK_LINE
    call line_lay
    call line_h
    add [rsp + 4], eax
    sub [rsp + 8], eax
    mov dword ptr [rsp + 12], 1
2:  cmp dword ptr [rsp + 20], 0
    je 3f
    mov rax, [rsp + 24]
    movsxd rcx, dword ptr [rax + AF_last]
    cmp rcx, r12
    jne 3f
    call line_h                 # its Collapse line, at the bottom
    sub [rsp + 8], eax
    mov ecx, r14d
    add ecx, [rsp]
    sub ecx, eax
    mov [rip + ll_y], ecx
    mov dword ptr [rip + ll_kind], FLK_COLLAPSE
    call line_lay
    mov dword ptr [rsp + 12], 1
3:  mov rdi, rbx
    call todo_row
    cmp rax, r12
    jne 4f
    mov rdi, rbx                # the list alone
    mov rsi, r12
    mov edx, r13d
    mov ecx, [rsp + 4]
    mov r8d, r15d
    call agrow_todo_draw
    mov dword ptr [rsp + 8], 0
    mov dword ptr [rsp + 12], 1
    jmp 5f
4:  cmp dword ptr [rsp + 20], 0
    jne 5f
    mov dword ptr [rsp + 8], 0  # closed: none of its own
5:  cmp dword ptr [rsp + 12], 0
    je 8f
    mov rdi, rbx                # where it was drawn (its own parts' draw moves y below its line)
    mov rsi, r12
    call am_of
    mov [rax + AM_dx], r13d
    mov [rax + AM_dy], r14d
    mov ecx, [rip + th_serial]
    mov [rax + AM_dser], ecx
8:  mov eax, [rsp + 4]
    mov edx, [rsp + 8]
    test edx, edx
    jns 9f
    xor edx, edx
9:  EPILOGUE

# ---------------- opening ----------------

# FN agfold_click(AS*, row): a click on a fold's line or Collapse line (or Enter on the line): the row's fold
#   opens or closes after the frame
FN agfold_click
    cmp rsi, [rdi + AS_msgs + VEC_len]
    jae 9f
    imul rax, rsi, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    movsxd rcx, dword ptr [rax + AM_fold]
    test rcx, rcx
    js 9f
    cmp rcx, [rdi + AS_folds + VEC_len]
    jae 9f
    mov [rip + pend_as], rdi
    mov [rip + pend_fold], ecx
    imul rax, rcx, AF_SIZE
    add rax, [rdi + AS_folds + VEC_ptr]
    movsxd rax, dword ptr [rax + AF_first]
    mov [rip + pend_row], rax
    mov dword ptr [rip + g_dirty], 1
9:  ret

# FN agfold_follow(): the fold clicked in the frame opens or closes, now that nothing drawn is in use (its
#   session still open and the fold still beginning at that row)
FN agfold_follow
    movsxd rsi, dword ptr [rip + pend_fold]
    test rsi, rsi
    js 9f
    PROLOGUE
    mov dword ptr [rip + pend_fold], -1
    mov r12, rsi
    call agents_viewed
    mov rbx, rax
    cmp rbx, [rip + pend_as]
    jne 8f
    cmp r12, [rbx + AS_folds + VEC_len]
    jae 8f
    mov rdi, rbx
    mov rsi, r12
    call af_of
    movsxd rcx, dword ptr [rax + AF_first]
    cmp rcx, [rip + pend_row]
    jne 8f
    mov rdi, rbx
    mov esi, r12d
    call toggle
8:  EPILOGUE
9:  ret

# toggle(AS*, fold): opened or closed; its chunks are made again; a row focus it hides goes to its line
toggle:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call af_of
    xor dword ptr [rax + AF_flags], AFF_OPEN
    mov rdi, rbx
    mov esi, r12d
    call fold_dirty
    mov rdi, rbx
    call focus_shown
    EPILOGUE

# focus_shown(AS*): the row focus of the open conversation, when focus view hides its row, on the row shown
#   in its place
focus_shown:
    PROLOGUE
    mov rbx, rdi
    call agents_viewed
    cmp rax, rbx
    jne 9f
    call agrow_focus
    test rax, rax
    js 9f
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    call agfold_shown
    cmp rax, r12
    je 9f
    mov rdi, rax
    call agrow_focus_set
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agfold_toggle_row(AS*, row): the fold of that row opened or closed now (agent-fold-click)
FN agfold_toggle_row
    cmp rsi, [rdi + AS_msgs + VEC_len]
    jae 9f
    imul rax, rsi, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    movsxd rsi, dword ptr [rax + AM_fold]
    test rsi, rsi
    js 9f
    cmp rsi, [rdi + AS_folds + VEC_len]
    jae 9f
    jmp toggle
9:  ret

# ---------------- the setting ----------------

# FN agfold_view_changed(): [agents] focus_view changed (the settings page, a reload): the chunks' own sums
#   follow at the next frame (agfold_key), a hidden row focus goes to its line, the menu's switch is drawn
#   again
FN agfold_view_changed
    PROLOGUE
    call agents_viewed
    test rax, rax
    jz 1f
    mov rdi, rax
    call focus_shown
1:  call agentpop_changed
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agents_toggle_focus_view(): "Agents: Toggle Focus View" (Ctrl+Alt+F): the setting flipped and saved
FN agents_toggle_focus_view
    xor dword ptr [rip + cfg_agents_focus_view], 1
    mov dword ptr [rip + g_settings_changed], 1
    jmp agfold_view_changed

# FN agfold_set(on): the command menu's switch: on 1, off 0, else flipped
FN agfold_set
    cmp edi, 1
    ja agents_toggle_focus_view
    cmp edi, [rip + cfg_agents_focus_view]
    je 9f
    mov [rip + cfg_agents_focus_view], edi
    mov dword ptr [rip + g_settings_changed], 1
    jmp agfold_view_changed
9:  ret

# FN agfold_on(AS* or 0, kind) -> eax 1 (the command menu's switch always shows), ecx APRF_ON while focus
#   view is on; rdx, r8, r9 0 (an action's rule, agentpop.s apm_tmpl)
FN agfold_on
    xor ecx, ecx
    cmp dword ptr [rip + cfg_agents_focus_view], 0
    je 1f
    mov ecx, APRF_ON
1:  xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov eax, 1
    ret

# ---------------- dumps ----------------

# FN agfold_dump(sb, AS*): print-agent-folds: "focus=0|1 folds=N held=N|- todo=N|-", then a line a fold:
#   "fold N FIRST-LAST calls=N failed=N thinks=N other=N ms=N|- open=0|1 held=0|1 line=0|1 run=T|- label=T"
#   (held: a waiting request shows it open; line: it has one; run: what runs, spaces as "_")
FN agfold_dump
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    lea rsi, [rip + .Ld_focus]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + cfg_agents_focus_view]
    call sb_push_u64
    test r12, r12
    jz 8f
    mov rdi, rbx
    lea rsi, [rip + .Ld_folds]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r12 + AS_folds + VEC_len]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_held]
    call sb_push_cstr
    mov esi, [r12 + AS_fask]
    dec esi
    call push_opt
    mov rdi, rbx
    lea rsi, [rip + .Ld_todo]
    call sb_push_cstr
    mov esi, [r12 + AS_ftodo]
    dec esi
    call push_opt
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor r13d, r13d
1:  cmp r13, [r12 + AS_folds + VEC_len]
    jae 9f
    mov rdi, r12
    mov rsi, r13
    call af_of
    mov r14, rax
    mov rdi, rbx
    lea rsi, [rip + .Ld_fold]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r14 + AF_first]
    call sb_push_u64
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r14 + AF_last]
    call sb_push_u64
    lea rsi, [rip + .Ld_calls]
    mov edx, [r14 + AF_calls]
    call dump_num
    lea rsi, [rip + .Ld_failed]
    mov edx, [r14 + AF_failed]
    call dump_num
    lea rsi, [rip + .Ld_thinks]
    mov edx, [r14 + AF_thinks]
    call dump_num
    lea rsi, [rip + .Ld_other]
    mov edx, [r14 + AF_other]
    call dump_num
    mov rdi, rbx
    lea rsi, [rip + .Ld_ms]
    call sb_push_cstr
    mov esi, [r14 + AF_ms]
    call push_opt
    lea rsi, [rip + .Ld_open]
    mov edx, [r14 + AF_flags]
    and edx, AFF_OPEN
    call dump_num
    xor edx, edx
    lea eax, [r13 + 1]
    cmp eax, [r12 + AS_fask]
    sete dl
    lea rsi, [rip + .Ld_heldf]
    call dump_num
    mov rdi, r14
    call shows
    mov edx, eax
    lea rsi, [rip + .Ld_line]
    call dump_num
    lea rdi, [rip + fsb]
    call sb_clear
    lea rdi, [rip + fsb]
    mov rsi, r12
    mov edx, r13d
    call fold_run
    mov rdi, rbx
    lea rsi, [rip + .Ld_run]
    call sb_push_cstr
    cmp qword ptr [rip + fsb + SB_len], 0
    jne 2f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 4f
2:  xor r15d, r15d              # its spaces as "_"
3:  cmp r15, [rip + fsb + SB_len]
    jae 4f
    mov rax, [rip + fsb + SB_ptr]
    movzx esi, byte ptr [rax + r15]
    cmp esi, ' '
    jne 31f
    mov esi, '_'
31: mov rdi, rbx
    call sb_push_byte
    inc r15
    jmp 3b
4:  mov rdi, rbx
    lea rsi, [rip + .Ld_label]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call fold_label
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r13
    jmp 1b
8:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# dump_num(rsi label, edx n) using rbx = sb: " LABEL=N" (the label holds its blank and "=")
dump_num:
    PROLOGUE
    mov r12d, edx
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call md_push_int
    EPILOGUE

# push_opt(esi n) using rbx = sb: N, or "-" when negative
push_opt:
    mov rdi, rbx
    test esi, esi
    js 1f
    jmp sb_push_u64
1:  mov esi, '-'
    jmp sb_push_byte

# FN agfold_row_dump(sb, AS*, row): print-agent-row's lines of a fold's lines the last frame drew on that row:
#   "fold X,Y,W,H ID", "collapse X,Y,W,H ID"
FN agfold_row_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    mov eax, [rip + fl_ser]
    cmp eax, [rip + th_serial]
    jne 9f
    xor r13d, r13d
1:  cmp r13d, [rip + fl_n]
    jae 9f
    lea rax, [rip + fl_row]
    cmp [rax + r13*8], r12
    jne 5f
    lea rsi, [rip + .Lk_fold]
    lea rax, [rip + fl_kind]
    cmp dword ptr [rax + r13*4], FLK_COLLAPSE
    jne 21f
    lea rsi, [rip + .Lk_collapse]
21: cmp dword ptr [rax + r13*4], FLK_BG
    jne 2f
    lea rsi, [rip + .Lk_bgfold]
2:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    xor r14d, r14d
3:  mov eax, r13d
    shl eax, 4
    lea rcx, [rip + fl_box]
    add rcx, rax
    mov esi, [rcx + r14*4]
    mov rdi, rbx
    call md_push_int
    inc r14d
    cmp r14d, 4
    jae 4f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    jmp 3b
4:  mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    lea rax, [rip + fl_id]
    mov esi, [rax + r13*4]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
5:  inc r13d
    jmp 1b
9:  EPILOGUE

# FN agfold_fit_dump(sb): print-agent-folds-fit: every fold of the open conversation that has a line, laid out
#   at every panel size 8 to 32 and width 240 to 900 by 20, as its line, as its line with the longest running
#   label and as its Collapse line: "size=S w=W fold=N kind=line|run|collapse tw=TW h=H", then a line a part,
#   "  KIND X,Y,W,H" (run, label, chevron, button), from the line's left and top. The setting is the user's
#   again after it
FN agfold_fit_dump
    PROLOGUE 32
    mov rbx, rdi
    mov [rip + ll_out], rdi
    call agents_viewed
    mov r15, rax
    test r15, r15
    jz 9f
    mov [rip + ll_as], r15
    mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    mov dword ptr [rip + ll_mode], LL_FIT
    mov dword ptr [rip + ll_x], 0
    mov dword ptr [rip + ll_y], 0
    mov r12d, 8
1:  cmp r12d, 32
    ja 8f
    mov [rip + cfg_agents_font_size], r12d
    call agents_metrics
    mov r13d, 240
2:  cmp r13d, 900
    ja 7f
    mov eax, r13d               # the rows' width in a panel that wide
    sub eax, [rip + g_pmt + 4*MI_16]
    sub eax, [rip + g_pmt + 4*MI_16]
    sub eax, [rip + g_pmt + 4*MI_24]
    mov [rip + ll_w], eax
    xor r14d, r14d
3:  cmp r14, [r15 + AS_folds + VEC_len]
    jae 6f
    mov rdi, r15
    mov rsi, r14
    call af_of
    mov rdi, rax
    call shows
    test eax, eax
    jz 5f
    mov [rip + ll_fold], r14d
    mov rdi, r15
    mov rsi, r14
    call af_of
    movsxd rcx, dword ptr [rax + AF_first]
    mov [rip + ll_row], rcx
    mov dword ptr [rsp + 4], FLK_LINE
4:  mov eax, [rsp + 4]
    mov [rip + ll_kind], eax
    mov rdi, rbx
    lea rsi, [rip + .Lf_size]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_w]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_fold]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r14
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_kind]
    call sb_push_cstr
    mov eax, [rsp + 4]
    lea rcx, [rip + fit_kinds]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lf_tw]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + ll_w]
    call md_push_int
    mov rdi, rbx
    lea rsi, [rip + .Lf_h]
    call sb_push_cstr
    call line_h
    mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    call line_lay
    inc dword ptr [rsp + 4]
    cmp dword ptr [rsp + 4], FLK_COLLAPSE
    jbe 4b
5:  inc r14
    jmp 3b
6:  add r13d, 20
    jmp 2b
7:  inc r12d
    jmp 1b
8:  mov eax, [rsp]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    call agents_view_changed    # the rows measured again at the user's size
9:  mov dword ptr [rip + ll_mode], LL_DRAW
    EPILOGUE

.section .rodata
.p2align 3
fit_kinds: .quad .Lw_line, .Lw_run, .Lw_collapse
.Lw_call: .asciz "tool call"
.Lw_step: .asciz "hidden step"
.Lsep: .asciz " \302\267 "
.Lfailed: .asciz " failed"
.Lthought: .asciz "Thought for "
.Lthinking: .asciz "Thinking"
.Lthinking_live: .asciz "Thinking\342\200\246"
.Lwait_perm: .asciz "Waiting for permission\342\200\246"
.Lwait_answer: .asciz "Waiting for your answer\342\200\246"
.Lrun_bg: .asciz "Run in background"     # task 11 (RUN_BG_LEN bytes)
.Lk_bgfold: .asciz "background"
.Lrunning: .asciz "Running "
.Ltool: .asciz "tool"
.Lellipsis: .asciz "\342\200\246"
.Lcollapse: .asciz "Collapse"
.Lindent: .asciz "  "
.Lk_run: .asciz "run"
.Lk_label: .asciz "label"
.Lk_chevron: .asciz "chevron"
.Lk_button: .asciz "button"
.Lk_fold: .asciz "fold"
.Lk_collapse: .asciz "collapse"
.Lw_line: .asciz "line"
.Lw_run: .asciz "run"
.Lw_collapse: .asciz "collapse"
.Ld_focus: .asciz "focus="
.Ld_folds: .asciz " folds="
.Ld_held: .asciz " held="
.Ld_todo: .asciz " todo="
.Ld_fold: .asciz "fold "
.Ld_calls: .asciz " calls="
.Ld_failed: .asciz " failed="
.Ld_thinks: .asciz " thinks="
.Ld_other: .asciz " other="
.Ld_ms: .asciz " ms="
.Ld_open: .asciz " open="
.Ld_heldf: .asciz " held="
.Ld_line: .asciz " line="
.Ld_run: .asciz " run="
.Ld_label: .asciz " label="
.Lf_size: .asciz "size="
.Lf_w: .asciz " w="
.Lf_fold: .asciz " fold="
.Lf_kind: .asciz " kind="
.Lf_tw: .asciz " tw="
.Lf_h: .asciz " h="
