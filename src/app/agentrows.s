# A conversation's typed rows, generic: nothing here names a driver, a tool or a record (the seam test reads
# this file). A tool call's row owns an AT record with neutral parts that a driver or a reader fills through
# agrow_*: a bold name, a second text that may be a link, a tail, a description line, a note line, IN and OUT
# texts, two sides of a diff or a file's text, todo items, a state, the calls that ran under it. The renderer
# draws the parts that are set and never looks at the name. Thinking, meta, compaction and unknown-block rows
# are drawn here too; the engine (agents.s) asks their heights and draws them by index.
#
#   agrow_tool(AS*, id, len, parent id or 0, len) -> rax AT*    a call (a new R_TOOL row, or a child)
#   agrow_ready(AS*, AT*), agrow_find(AS*, id, len) -> rax AT*, agrow_done(AS*, AT*)
#   agrow_set(AT*, ATX_*, ptr, len), agrow_num(AT*, ATV_*, value), agrow_item(AT*, ptr, len, TODO_*),
#   agrow_items_clear(AT*), agrow_summary(AS*, AT*, ptr, len), agrow_touch(AS*, AT*) (it changed: after
#   agrow_set / agrow_num / agrow_item on a row already made, the mapper calls it)
#   agrow_full(AS*, AT*, ATX_IN..ATX_B, sb) -> eax 1 whole, agrow_kids(AS*, AT*) -> eax
#   agrow_free(AT*), agrow_clone(AT*) -> rax AT*, agrow_cut(AS*, n) (its rows from n on go: the calls' table,
#   the waiting calls, the row focus, a pending click)
#   agrow_est(AS*, row) -> eax fix, edx lines, ecx bytes; agrow_h(AS*, row, w) -> eax;
#   agrow_draw(AS*, row, x, y, w, h); agrow_slot(row, child) -> eax; agrow_follow(); agrow_key(AS*, keysym,
#   cp, mods) -> eax; agrow_focus() -> rax; agrow_focus_set(row); agrow_think() -> eax (thinking is open);
#   agrow_think_toggle() (all thinking rows open or close: a click, Enter, Ctrl+O), agrow_think_reset() (another
#   conversation is opened), agents_toggle_thinking() ("Agents: Expand or Collapse Thinking");
#   agrow_code_face() -> rax FACE*; agrow_dump(sb, AS*, from, n, content); agrow_fit_dump(sb);
#   agrow_row_dump(sb, AS*, row)
#   the prompt (task 8): agrow_prompt_h(AM*, w) -> eax, agrow_prompt_draw(AS*, row or -1, AM*, x, y, w | h << 32),
#   agrow_prompt_fields(sb, AS*, row, AM*, x, y), agrow_prompt_est(AM*) -> eax, edx, ecx
#   the error block (task 8): agrow_err_h(AS*, w) -> eax, agrow_err_draw(AS*, x, y, w), agrow_err_at(x, y, w),
#   agrow_err_dump(sb, AS*), agrow_err_click(AS*, n) -> eax
.include "rhun.inc"

# RW: a text wrapped at a width, laid out and optionally drawn (rw_wrap)
STRUCT
F RW_face, 8
F RW_text, 8
F RW_len, 8
F RW_x, 4
F RW_y, 4
F RW_w, 4
F RW_lh, 4
F RW_color, 4
F RW_draw, 4
F RW_top, 4             # drawn only between these (the clip)
F RW_bot, 4
F RW_max, 4             # lines laid out at most, 0 all
F RW_pad, 4
F RW_out, 8             # SB*: each line laid out as its text and a line feed, or 0
F RW_mute, 8            # the byte drawn muted from, when a segment begins at or after it; -1 none
ENDSTRUCT RW_SIZE

.equ LM_MEASURE, 0              # tr_lay's modes: the height only
.equ LM_DRAW, 1                 #   drawn, its buttons live
.equ LM_DUMP, 2                 #   its parts as print-agent-row lines (where the last frame drew it)
.equ LM_FIT, 3                  #   its parts' boxes, from the row's left and top (print-agent-rows-fit)
.equ SLOTS, 256                 # agrow_slot's table
.equ TABS_KEPT, 32              # the tabs a row's text opened, remembered (found again by DOC_id)
.equ ERR_CHARS, 2000            # an error's text in the row (the extension's): then "…"
.equ BIG_UNITS, 250             # a text longer (UTF-16 units) or of more than 3 lines is a button (V7)
.equ ERR_LINES, 10
.equ ID_AG_MD, 0x480000         # agents.s's: a row's Markdown links, + (row & 255) << 12 (open thinking's too)
.equ ERR_ROW, 0xffffff         # the error block's unit for agrow_slot (no row has that index)
.equ ERR_BLOCK_LINES, 8         # the error block's text: lines drawn at most (the rest: View output logs)
.equ NO_CONV_LEN, 21            # .Lno_conv's bytes
.equ COMPACTED_FREE_LEN, 46     # .Lcompacted_free's bytes
.equ UNSUPPORTED_LEN, 26       # .Lunsupported's bytes              # an error's clip when it is a button: 10 lines of its face

.data
.p2align 3
rf_row: .quad -1                # the row focus: the row of the open conversation whose action Enter runs
pend_row: .quad -1              # a click's or a key's action, run after the frame (agrow_follow): its row,
                                #   the call's id (owned) and the part
.bss
.p2align 3
pend_id: .quad 0
pend_part: .long 0
think_open: .long 0
pend_think: .long 0             # a click on a thinking row's label: all of them open or close after the frame
code_px: .long 0
code_gen: .long 0
code_face: .zero FACE_SIZE      # agrow_code_face's
slot_key: .zero 8 * SLOTS       # agrow_slot: (row << 16 | child + 1) of the unit that has the slot
slot_ser: .zero 4 * SLOTS       #   and the frame it was drawn in last (0: free)
tab_key: .zero 8 * TABS_KEPT    # the tabs opened from a row's text: (session path, call id, part) hashed,
tab_doc: .zero 4 * TABS_KEPT    #   and the document's DOC_id
tab_next: .long 0
rw_chips: .long 0               # phase 4 task 7: rw_wrap draws a prompt's mention chips (agents_line_chips)
lr_mode: .long 0                # tr_lay's: its mode, the unit's slot, the row's left and top
lr_slot: .long 0
lr_x: .long 0
lr_y: .long 0
.p2align 3
lr_row: .quad 0
lr_at: .quad 0
lr_out: .quad 0                 # LM_DUMP, LM_FIT: the SB its lines go to
lr_w: .long 0                   # the row's width, and the top of the line small_line draws
lr_cy: .long 0
.p2align 3
ln_ptr: .quad 0                 # lay_line's text
ln_len: .quad 0
sec_ptr: .quad 0                # section's text
sec_len: .quad 0
xs: .zero SB_SIZE               # scratch: a text shown (an error cut), the whole text of a part
ys: .zero SB_SIZE
ks: .zero SB_SIZE               # task 11: the line of the calls under a call (kids_text)
kc_n: .quad 0                   #   agrow_kid_click's count
lr_key: .long 0                 #   the unit laid out: its key under its row (0 the row's own call)
lr_ux: .long 0                  #   and its left (lr_x is its row's)

.text

# ---------------- the calls by id: AS_calls, open addressing with linear probes ----------------

# call_hash(ptr, len) -> rax its id's hash, never 0 or 1 (an empty or deleted slot's)
call_hash:
    PROLOGUE
    call hash_line
    cmp rax, 2
    jae 1f
    add rax, 2
1:  EPILOGUE

# calls_slot(AS*, hash, id ptr, len) -> rax the AC of that id, or the first empty one on its probe; edx 1
#   when it is that id's
calls_slot:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15d, [rbx + AS_ccap]
    dec r15
    mov rax, r12
    and rax, r15
    mov [rsp], rax
1:  mov rax, [rsp]
    imul rcx, rax, AC_SIZE
    add rcx, [rbx + AS_calls]
    mov [rsp + 8], rcx
    mov rdx, [rcx + AC_hash]
    test rdx, rdx
    jz 8f
    cmp rdx, r12
    jne 2f
    mov rdi, [rcx + AC_at]
    mov rdi, [rdi + AT_id]
    call strlen
    cmp rax, r14
    jne 2f
    mov rcx, [rsp + 8]
    mov rdi, [rcx + AC_at]
    mov rdi, [rdi + AT_id]
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jz 2f
    mov rax, [rsp + 8]
    mov edx, 1
    EPILOGUE
2:  mov rax, [rsp]
    inc rax
    and rax, r15
    mov [rsp], rax
    jmp 1b
8:  mov rax, rcx
    xor edx, edx
    EPILOGUE

# calls_grow(AS*): twice the slots (16 at first), every call put again
calls_grow:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, [rbx + AS_calls]
    mov r13d, [rbx + AS_ccap]
    lea eax, [r13 + r13]
    cmp eax, 16
    jae 1f
    mov eax, 16
1:  mov [rbx + AS_ccap], eax
    imul rdi, rax, AC_SIZE
    call mem_alloc
    mov [rbx + AS_calls], rax
    mov dword ptr [rbx + AS_ncalls], 0
    xor r14d, r14d
2:  cmp r14d, r13d
    jae 8f
    imul r15, r14, AC_SIZE
    add r15, r12
    cmp qword ptr [r15 + AC_hash], 2
    jb 3f
    mov rdi, rbx
    mov rsi, [r15 + AC_at]
    call calls_put
3:  inc r14d
    jmp 2b
8:  mov rdi, r12
    call mem_free
    EPILOGUE

# calls_put(AS*, AT*): the call in the table by its id; a call with an id that is there replaces it (the
#   newer wins)
calls_put:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [rbx + AS_ncalls]
    inc eax
    add eax, eax
    cmp eax, [rbx + AS_ccap]
    jbe 1f
    call calls_grow
1:  mov rdi, [r12 + AT_id]
    call strlen
    mov r14, rax
    mov rdi, [r12 + AT_id]
    mov rsi, rax
    call call_hash
    mov r13, rax
    mov rdi, rbx
    mov rsi, r13
    mov rdx, [r12 + AT_id]
    mov rcx, r14
    call calls_slot
    mov [rax + AC_at], r12
    test edx, edx
    jnz 9f
    mov [rax + AC_hash], r13
    inc dword ptr [rbx + AS_ncalls]
9:  EPILOGUE

# calls_get(AS*, id ptr, len) -> rax the call of that id in the table, or 0
calls_get:
    PROLOGUE
    xor eax, eax
    cmp dword ptr [rdi + AS_ccap], 0
    je 9f
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rsi
    mov rsi, rdx
    call call_hash
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    mov rcx, r13
    call calls_slot
    test edx, edx
    jz 8f
    mov rax, [rax + AC_at]
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# calls_del(AS*, AT*): that call out of the table (when it is the one its id names): the slots after it on
#   its probe shift back, so no slot stays deleted
calls_del:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [rbx + AS_ccap], 0
    je 9f
    mov rdi, [r12 + AT_id]
    call strlen
    mov rdi, [r12 + AT_id]
    mov rsi, rax
    call call_hash
    mov r15d, [rbx + AS_ccap]
    dec r15
    and rax, r15
1:  imul rcx, rax, AC_SIZE      # find it
    add rcx, [rbx + AS_calls]
    cmp qword ptr [rcx + AC_hash], 0
    je 9f
    cmp [rcx + AC_at], r12
    je 2f
    inc rax
    and rax, r15
    jmp 1b
2:  mov r13, rax                # i: the hole
    mov r14, rax                # j
3:  inc r14
    and r14, r15
    imul rcx, r14, AC_SIZE
    add rcx, [rbx + AS_calls]
    mov rdx, [rcx + AC_hash]
    test rdx, rdx
    jz 6f
    and rdx, r15                # its home k: it stays when k is in (i, j], cyclically
    cmp r13, r14
    ja 4f
    cmp rdx, r13
    jbe 5f
    cmp rdx, r14
    jbe 3b
    jmp 5f
4:  cmp rdx, r13
    ja 3b
    cmp rdx, r14
    jbe 3b
5:  imul rdi, r13, AC_SIZE      # it moves into the hole
    add rdi, [rbx + AS_calls]
    mov rax, [rcx + AC_hash]
    mov [rdi + AC_hash], rax
    mov rax, [rcx + AC_at]
    mov [rdi + AC_at], rax
    mov r13, r14
    jmp 3b
6:  imul rdi, r13, AC_SIZE
    add rdi, [rbx + AS_calls]
    mov qword ptr [rdi + AC_hash], 0
    mov qword ptr [rdi + AC_at], 0
    dec dword ptr [rbx + AS_ncalls]
9:  EPILOGUE

# wait_del(AS*, AT*): out of the turn's waiting calls
wait_del:
    mov rcx, [rdi + AS_wait + VEC_len]
    mov rdx, [rdi + AS_wait + VEC_ptr]
1:  test rcx, rcx
    jz 9f
    dec rcx
    cmp [rdx + rcx*8], rsi
    jne 1b
    mov r8, [rdi + AS_wait + VEC_len]
    dec r8
    mov [rdi + AS_wait + VEC_len], r8
2:  cmp rcx, r8
    jae 9f
    mov rax, [rdx + rcx*8 + 8]
    mov [rdx + rcx*8], rax
    inc rcx
    jmp 2b
9:  ret

# FN agrow_cut(AS*, n): its rows from n on go: their calls leave the table and the waiting calls (at 0 the
#   table goes), and in the open conversation the row focus and a pending click on one of them
FN agrow_cut
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jnz 1f
    mov rdi, [rbx + AS_calls]
    call mem_free
    mov qword ptr [rbx + AS_calls], 0
    mov dword ptr [rbx + AS_ccap], 0
    mov dword ptr [rbx + AS_ncalls], 0
    mov qword ptr [rbx + AS_wait + VEC_len], 0
    jmp 5f
1:  mov r14, [rbx + AS_calls]   # the table made again of the calls of the rows kept
    mov r15d, [rbx + AS_ccap]
    test r14, r14
    jz 3f
    imul rdi, r15, AC_SIZE
    call mem_alloc
    mov [rbx + AS_calls], rax
    mov dword ptr [rbx + AS_ncalls], 0
    xor r13d, r13d
2:  cmp r13d, r15d
    jae 21f
    imul rcx, r13, AC_SIZE
    add rcx, r14
    cmp qword ptr [rcx + AC_hash], 2
    jb 22f
    mov rsi, [rcx + AC_at]
    movsxd rax, dword ptr [rsi + AT_row]
    cmp rax, r12
    jae 22f
    mov rdi, rbx
    call calls_put
22: inc r13d
    jmp 2b
21: mov rdi, r14
    call mem_free
3:  mov rcx, [rbx + AS_wait + VEC_len]  # the waiting calls of the rows kept
4:  test rcx, rcx
    jz 5f
    dec rcx
    mov rax, [rbx + AS_wait + VEC_ptr]
    mov rsi, [rax + rcx*8]
    movsxd rax, dword ptr [rsi + AT_row]
    cmp rax, r12
    jb 4b
    mov [rsp], rcx
    mov rdi, rbx
    call wait_del
    mov rcx, [rsp]
    jmp 4b
5:  call agents_viewed          # the open conversation: its focus and a pending click
    cmp rax, rbx
    jne 9f
    cmp [rip + rf_row], r12
    jl 6f
    mov qword ptr [rip + rf_row], -1
6:  cmp [rip + pend_open], r12  # a row to open or a chip's file: not a row of the rows cut
    jl 61f
    mov qword ptr [rip + pend_open], -1
61: cmp [rip + pend_chip], r12
    jl 62f
    mov qword ptr [rip + pend_chip], -1
62: cmp [rip + pend_row], r12
    jl 9f
    call pend_clear
9:  EPILOGUE

# pend_clear(): no click waits for the frame's end
pend_clear:
    PROLOGUE
    mov qword ptr [rip + pend_row], -1
    mov dword ptr [rip + pend_part], 0
    mov rdi, [rip + pend_id]
    call mem_free
    mov qword ptr [rip + pend_id], 0
    EPILOGUE

# ---------------- calls ----------------

# FN agrow_tool(AS*, id ptr, len, parent id ptr or 0, len) -> rax AT*: a call. A child of the call that id
#   names when that one is in AS_calls (a parent, or one still waiting), else a new R_TOOL row at the end.
#   It waits for its result (ATF_WAIT, AS_wait); its record's place is the line being read (AS_line). Past
#   AT_KIDS_MAX children or AT_DEPTH_MAX levels it is counted (the parent's AT_nkids) and not kept: rax 0
FN agrow_tool
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d              # the parent
    mov [rsp], r14d             # the depth
    test rcx, rcx
    jz 2f
    test r8, r8
    jz 2f
    mov rsi, rcx
    mov rdx, r8
    call calls_get
    mov r14, rax
    test r14, r14
    jz 2f
    mov eax, [r14 + AT_depth]
    inc eax
    mov [rsp], eax
    cmp eax, AT_DEPTH_MAX
    jae 1f
    cmp qword ptr [r14 + AT_kids + VEC_len], AT_KIDS_MAX
    jb 2f
1:  cmp dword ptr [r14 + AT_nkids], 0   # past the limits: counted only
    jge 11f
    mov rax, [r14 + AT_kids + VEC_len]
    mov [r14 + AT_nkids], eax
11: inc dword ptr [r14 + AT_nkids]
    mov rdi, rbx
    mov rsi, r14
    call agrow_touch
    xor eax, eax
    EPILOGUE
2:  mov edi, AT_SIZE
    call mem_alloc
    mov r15, rax
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [r15 + AT_id], rax
    mov [r15 + AT_up], r14
    mov eax, [rsp]
    mov [r15 + AT_depth], eax
    mov dword ptr [r15 + AT_state], ATS_RUNNING
    mov dword ptr [r15 + AT_flags], ATF_WAIT
    mov dword ptr [r15 + AT_nkids], -1
    mov dword ptr [r15 + AT_h], -1
    mov dword ptr [r15 + AT_w], -1
    mov qword ptr [r15 + AT_uoff], -1
    mov qword ptr [r15 + AT_roff], -1
    mov rax, [rbx + AS_linelen] # its record's place: the line being read, else none (the stream)
    test rax, rax
    jz 3f
    mov [r15 + AT_ulen], rax
    mov rax, [rbx + AS_line]
    mov [r15 + AT_uoff], rax
    jmp 4f
3:  call time_ms
    mov [r15 + AT_t0], rax
4:  test r14, r14
    jz 5f
    lea rdi, [r14 + AT_kids]    # a child
    mov esi, 8
    call vec_push
    mov [rax], r15
    mov eax, [r14 + AT_row]
    mov [r15 + AT_row], eax
    mov rdi, rbx
    mov rsi, r14
    call agrow_touch
    jmp 6f
5:  mov rdi, rbx                # a row of its own
    mov rsi, r15
    call agents_tool_row
    mov [r15 + AT_row], eax
6:  mov rdi, rbx
    mov rsi, r15
    call calls_put
    lea rdi, [rbx + AS_wait]
    mov esi, 8
    call vec_push
    mov [rax], r15
    mov rax, r15
    EPILOGUE

# FN agrow_ready(AS*, AT*): its input is filled and its flags are final: its fold is chosen now (a hidden
#   call joins a run and counts nothing), the latest todo row noted, its row measured again
FN agrow_ready
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp qword ptr [r12 + AT_up], 0
    jne 8f
    mov rdi, rbx                # (a hidden call too: it joins a run, counts nothing and ends none)
    movsxd rsi, dword ptr [r12 + AT_row]
    call agfold_add
    cmp qword ptr [r12 + AT_items + VEC_len], 0
    je 8f
    mov eax, [r12 + AT_row]
    mov [rbx + AS_todo], eax
8:  mov rdi, rbx
    mov rsi, r12
    call agrow_touch
    EPILOGUE

# FN agrow_find(AS*, id ptr, len) -> rax the call of that id in AS_calls (waiting, or a parent), or 0
FN agrow_find
    jmp calls_get

# FN agrow_done(AS*, AT*): its result is in: no longer waiting, its result's place the line being read; it
#   leaves AS_calls unless it may still get children (ATF_PARENT); its fold's counts follow its state
FN agrow_done
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    and dword ptr [r12 + AT_flags], ~ATF_WAIT
    mov rax, [rbx + AS_linelen]
    test rax, rax
    jz 1f
    mov [r12 + AT_rlen], rax
    mov rax, [rbx + AS_line]
    mov [r12 + AT_roff], rax
1:  test dword ptr [r12 + AT_flags], ATF_PARENT
    jnz 2f
    mov rdi, rbx
    mov rsi, r12
    call calls_del
2:  mov rdi, rbx
    mov rsi, r12
    call wait_del
    mov rax, [r12 + AT_up]      # a call under another one that failed: its parent's count of failures
    test rax, rax
    jz 21f
    cmp dword ptr [r12 + AT_state], ATS_FAILED
    jne 3f
    inc dword ptr [rax + AT_nfail]
    jmp 3f
21: cmp qword ptr [r12 + AT_up], 0
    jne 3f
    mov rdi, rbx
    movsxd rsi, dword ptr [r12 + AT_row]
    mov edx, ATS_RUNNING
    mov ecx, [r12 + AT_state]
    call agfold_state
3:  mov rdi, rbx
    mov rsi, r12
    call agrow_touch
    EPILOGUE

# FN agrow_touch(AS*, AT*): it changed: its row is measured again; a top-level call that has todo items now
#   (the task tools' list comes with their result) is the latest todo row when none later is
FN agrow_touch
    cmp qword ptr [rsi + AT_up], 0
    jne 1f
    cmp qword ptr [rsi + AT_items + VEC_len], 0
    je 1f
    mov eax, [rsi + AT_row]
    cmp eax, [rdi + AS_todo]
    jl 1f
    mov [rdi + AS_todo], eax
1:  mov dword ptr [rsi + AT_h], -1
    inc dword ptr [rsi + AT_rev]
    movsxd rsi, dword ptr [rsi + AT_row]
    jmp agents_msg_changed

# FN agrow_summary(AS*, AT*, ptr, len): a top-level row's one-line summary (print-agents, the simple draw)
FN agrow_summary
    cmp qword ptr [rsi + AT_up], 0
    jne 1f
    movsxd rsi, dword ptr [rsi + AT_row]
    jmp agents_msg_set
1:  ret

# FN agrow_tag(AS*, AT*, ptr, len): a top-level row's name as its source names the call (print-agents'
#   "tool(NAME)"; the header shows AT_name)
FN agrow_tag
    cmp qword ptr [rsi + AT_up], 0
    jne 1f
    movsxd rsi, dword ptr [rsi + AT_row]
    jmp agents_row_name
1:  ret

# FN agrow_stop(AS*): the calls of the turn that still wait for a result are stopped (a prompt read from a
#   file, a turn's end): they stay findable by id, so a result that still comes is taken. A call that ran
#   under another one only leaves the list: an agent runs on after its turn
FN agrow_stop
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + AS_wait + VEC_len]
    jae 8f
    mov rax, [rbx + AS_wait + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    cmp qword ptr [r13 + AT_up], 0
    jne 1b
    cmp dword ptr [r13 + AT_state], ATS_RUNNING
    jne 1b
    mov dword ptr [r13 + AT_state], ATS_STOPPED
    mov rdi, rbx
    movsxd rsi, dword ptr [r13 + AT_row]
    mov edx, ATS_RUNNING
    mov ecx, ATS_STOPPED
    call agfold_state
    mov rdi, rbx
    mov rsi, r13
    call agrow_touch
    jmp 1b
8:  mov qword ptr [rbx + AS_wait + VEC_len], 0
    EPILOGUE

# out_hidden(AT*) -> eax 1 when OUT is kept only for the tab its note opens (a note, a title and OUT: the
#   note is the button, OUT is not drawn)
out_hidden:
    xor eax, eax
    cmp qword ptr [rdi + AT_note], 0
    je 9f
    cmp qword ptr [rdi + AT_title], 0
    je 9f
    cmp qword ptr [rdi + AT_out + SB_len], 0
    setne al
9:  ret

# FN agrow_num(AT*, ATV_*, value): its state, flags on or off, the link's lines, the count its result gave
FN agrow_num
    cmp esi, ATV_STATE
    jne 1f
    mov [rdi + AT_state], edx
    jmp 8f
1:  cmp esi, ATV_SET
    jne 2f
    or [rdi + AT_flags], edx
    jmp 8f
2:  cmp esi, ATV_CLEAR
    jne 3f
    not edx
    and [rdi + AT_flags], edx
    jmp 8f
3:  cmp esi, ATV_L0
    jne 4f
    mov [rdi + AT_l0], edx
    jmp 8f
4:  cmp esi, ATV_L1
    jne 5f
    mov [rdi + AT_l1], edx
    jmp 8f
5:  cmp esi, ATV_NKIDS
    jne 9f
    mov [rdi + AT_nkids], edx
8:  mov dword ptr [rdi + AT_h], -1
9:  ret

# FN agrow_item(AT*, ptr, len, TODO_*): a todo item (cleaned, 400 bytes at most; AT_ITEMS_MAX items)
FN agrow_item
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
    cmp qword ptr [rbx + AT_items + VEC_len], AT_ITEMS_MAX
    jae 9f
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    call short_text
    mov r14, rax
    lea rdi, [rbx + AT_items]
    mov esi, ATI_SIZE
    call vec_push
    mov [rax + ATI_text], r14
    mov ecx, [rsp]
    mov [rax + ATI_state], ecx
    mov dword ptr [rbx + AT_h], -1
9:  EPILOGUE

# FN agrow_items_clear(AT*): its todo items go
FN agrow_items_clear
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + AT_items + VEC_len]
    jae 2f
    imul rax, r12, ATI_SIZE
    add rax, [rbx + AT_items + VEC_ptr]
    mov rdi, [rax + ATI_text]
    call mem_free
    inc r12
    jmp 1b
2:  mov qword ptr [rbx + AT_items + VEC_len], 0
    mov dword ptr [rbx + AT_h], -1
    EPILOGUE

# ---------------- texts: cleaned, counted, kept ----------------

# at_clean(dst, src, len) -> rax bytes written: what a row shows of a tool's text. CR, escape sequences (CSI to
#   its final byte; OSC, DCS, APC, PM to BEL or ST; any other with its next byte), C0 controls but LF and TAB,
#   C1 controls and the bidi controls U+202A-202E and U+2066-2069 go; an invalid UTF-8 byte is U+FFFD. dst
#   holds 3 x len
at_clean:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d              # in
    xor r15d, r15d              # out
1:  cmp r14, r13
    jae 9f
    movzx eax, byte ptr [r12 + r14]
    cmp eax, 0x80
    jae 5f
    cmp eax, 27
    je 3f
    cmp eax, 10
    je 2f
    cmp eax, 9
    je 2f
    cmp eax, 32
    jb 11f                      # a C0 control (CR among them)
    cmp eax, 127
    je 11f
2:  mov [rbx + r15], al
    inc r15
11: inc r14
    jmp 1b
3:  inc r14                     # an escape
    cmp r14, r13
    jae 9f
    movzx eax, byte ptr [r12 + r14]
    inc r14
    cmp eax, '['
    je 4f
    cmp eax, ']'
    je 41f
    cmp eax, 'P'
    je 41f
    cmp eax, '_'
    je 41f
    cmp eax, '^'
    je 41f
    jmp 1b                      # ESC and one byte
4:  cmp r14, r13                # CSI: to its final byte (0x40-0x7e)
    jae 9f
    movzx eax, byte ptr [r12 + r14]
    inc r14
    sub eax, 0x40
    cmp eax, 0x3e
    ja 4b
    jmp 1b
41: cmp r14, r13                # a string: to BEL or ESC backslash
    jae 9f
    movzx eax, byte ptr [r12 + r14]
    inc r14
    cmp eax, 7
    je 1b
    cmp eax, 27
    jne 41b
    cmp r14, r13
    jae 9f
    cmp byte ptr [r12 + r14], '\\'
    jne 41b
    inc r14
    jmp 1b
5:  lea rdi, [r12 + r14]        # a character of several bytes: whole and valid, or U+FFFD
    mov rsi, r13
    sub rsi, r14
    call utf8_valid_at
    test edx, edx
    jz 7f
    mov ecx, eax                # the code point
    cmp ecx, 0x80
    jb 6f
    cmp ecx, 0xa0
    jb 61f                      # C1
    cmp ecx, 0x202a
    jb 6f
    cmp ecx, 0x202e
    jbe 61f
    cmp ecx, 0x2066
    jb 6f
    cmp ecx, 0x2069
    jbe 61f
6:  mov ecx, edx                # kept: its bytes
62: movzx eax, byte ptr [r12 + r14]
    mov [rbx + r15], al
    inc r14
    inc r15
    dec ecx
    jnz 62b
    jmp 1b
61: add r14, rdx                # dropped
    jmp 1b
7:  mov byte ptr [rbx + r15], 0xef
    mov byte ptr [rbx + r15 + 1], 0xbf
    mov byte ptr [rbx + r15 + 2], 0xbd
    add r15, 3
    inc r14
    jmp 1b
9:  mov rax, r15
    EPILOGUE

# utf8_valid_at(ptr, len) -> eax the code point, edx its bytes (0: not a valid sequence there)
utf8_valid_at:
    xor edx, edx
    movzx eax, byte ptr [rdi]
    cmp eax, 0xc2
    jb 9f
    mov ecx, 1                  # continuation bytes
    mov r8d, eax
    and r8d, 0x1f
    mov r9d, 0x80               # the smallest code point
    cmp eax, 0xe0
    jb 1f
    mov ecx, 2
    mov r8d, eax
    and r8d, 0x0f
    mov r9d, 0x800
    cmp eax, 0xf0
    jb 1f
    cmp eax, 0xf4
    ja 9f
    mov ecx, 3
    mov r8d, eax
    and r8d, 0x07
    mov r9d, 0x10000
1:  lea r10, [rcx + 1]
    cmp r10, rsi
    ja 9f
    mov r10d, 1
2:  movzx r11d, byte ptr [rdi + r10]
    mov eax, r11d
    and eax, 0xc0
    cmp eax, 0x80
    jne 9f
    shl r8d, 6
    and r11d, 0x3f
    or r8d, r11d
    inc r10d
    cmp r10d, ecx
    jbe 2b
    cmp r8d, r9d
    jb 9f                       # overlong
    cmp r8d, 0x10ffff
    ja 9f
    mov eax, r8d
    and eax, 0xfffff800
    cmp eax, 0xd800
    je 9f                       # a surrogate
    mov eax, r8d
    lea edx, [rcx + 1]
    ret
9:  xor edx, edx
    ret

# char_cut(ptr, len) -> rax len, less a character cut at its end
char_cut:
    mov rax, rsi
1:  test rax, rax
    jz 9f
    movzx ecx, byte ptr [rdi + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne 9f
    dec rax
    jmp 1b
9:  ret

# short_text(ptr, len, keep_lf) -> rax owned cstr or 0 (empty): a one-line part cleaned (a line feed and a
#   TAB are blanks unless keep_lf), cut at AT_SHORT_MAX bytes at a character
short_text:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov [rsp], edx
    test r13, r13
    jz 8f
    lea rdi, [r13 + r13*2 + 1]
    call mem_alloc
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call at_clean
    mov r14, rax
    cmp dword ptr [rsp], 0
    jne 2f
    xor ecx, ecx
1:  cmp rcx, r14
    jae 2f
    cmp byte ptr [rbx + rcx], 10
    je 11f
    cmp byte ptr [rbx + rcx], 9
    jne 12f
11: mov byte ptr [rbx + rcx], ' '
12: inc rcx
    jmp 1b
2:  cmp r14, AT_SHORT_MAX
    jbe 3f
    mov rdi, rbx
    mov esi, AT_SHORT_MAX
    call char_cut
    mov r14, rax
3:  mov byte ptr [rbx + r14], 0
    test r14, r14
    jnz 9f
    mov rdi, rbx
    call mem_free
8:  xor eax, eax
    EPILOGUE
9:  mov rax, rbx
    EPILOGUE

# field_of(ATX_NAME..ATX_AUX) -> rax the AT field's offset
field_of:
    lea rax, [rip + short_fields]
    mov eax, [rax + rdi*4]
    ret

# FN agrow_set(AT*, ATX_*, ptr, len): a text part, copied and cleaned (at_clean). IN, OUT, A and B: their
#   whole bytes and lines are counted and whether they are a button (V7: more than 250 UTF-16 units or more
#   than 3 lines); a call with a place in a file keeps the preview (IN, OUT: AT_PREVIEW bytes or 6 lines; A,
#   B: AT_SIDE bytes or 12 lines), one without keeps up to AT_LIVE_MAX, cut at a character. LINK: none when
#   longer than AT_LINK_MAX or with a control in it. The others: one line, cut at 400 bytes. len 0 clears it
FN agrow_set
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, ATX_IN
    jae .Lset_text
    cmp r12d, ATX_LINK
    je .Lset_link
    mov edi, r12d
    call field_of
    mov r15, rax
    mov rdi, [rbx + r15]
    call mem_free
    mov qword ptr [rbx + r15], 0
    mov rdi, r13
    mov rsi, r14
    xor edx, edx
    cmp r12d, ATX_FIND          # the text a link's file is searched for keeps its lines
    sete dl
    call short_text
    mov [rbx + r15], rax
    jmp 9f
.Lset_link:
    mov rdi, [rbx + AT_link]
    call mem_free
    mov qword ptr [rbx + AT_link], 0
    test r14, r14
    jz 9f
    cmp r14, AT_LINK_MAX
    ja 9f                       # a target cut would open the wrong place: none
    xor ecx, ecx
1:  cmp rcx, r14
    jae 2f
    cmp byte ptr [r13 + rcx], 32
    jb 9f
    cmp byte ptr [r13 + rcx], 127
    je 9f
    inc rcx
    jmp 1b
2:  mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov [rbx + AT_link], rax
    jmp 9f
.Lset_text:
    cmp r12d, ATX_A             # a diff's side: its record is made again (agentdiff.s)
    jb 0f
    mov rdi, rbx
    call agdiff_free
0:  mov eax, r12d
    sub eax, ATX_IN
    mov [rsp], eax              # the part's number
    imul r15, rax, SB_SIZE
    lea r15, [rbx + r15 + AT_in]
    mov rdi, r15
    call sb_clear
    mov ecx, [rsp]
    mov qword ptr [rbx + AT_size + rcx*8], 0
    mov dword ptr [rbx + AT_lines + rcx*4], 0
    mov eax, 1
    shl eax, cl
    not eax
    and [rbx + AT_big], eax
    test r14, r14
    jz 8f
    lea rdi, [r14 + r14*2 + 1]  # cleaned whole into a scratch block, counted, then kept in part
    call mem_alloc
    mov [rsp + 8], rax
    mov rdi, rax
    mov rsi, r13
    mov rdx, r14
    call at_clean
    mov r13, rax                # its bytes
    mov ecx, [rsp]
    mov [rbx + AT_size + rcx*8], r13
    mov rdi, [rsp + 8]
    mov rsi, r13
    call lines_of
    mov ecx, [rsp]
    mov [rbx + AT_lines + rcx*4], eax
    mov [rsp + 16], eax
    mov rdi, [rsp + 8]          # a button: more than 250 units or 3 lines
    mov rsi, r13
    call agent_units
    cmp rax, BIG_UNITS
    ja 3f
    mov rdi, [rsp + 8]
    mov rsi, r13
    call count_lfs
    cmp eax, 3
    jb 4f
3:  mov ecx, [rsp]
    mov eax, 1
    shl eax, cl
    or [rbx + AT_big], eax
4:  mov r14, r13                # what is kept
    mov eax, AT_LIVE_MAX
    xor edx, edx
    cmp qword ptr [rbx + AT_uoff], 0
    jl 5f
    mov eax, AT_PREVIEW         # a row from a file: a preview
    mov edx, AT_PREVIEW_LINES
    cmp dword ptr [rsp], ATX_A - ATX_IN
    jb 5f
    mov eax, AT_SIDE
    mov edx, AT_SIDE_LINES
5:  cmp r14, rax
    jbe 51f
    mov r14, rax
51: test edx, edx
    jz 6f
    xor ecx, ecx                # and its first lines
    mov rsi, [rsp + 8]
52: cmp rcx, r14
    jae 6f
    cmp byte ptr [rsi + rcx], 10
    jne 53f
    dec edx
    jnz 53f
    mov r14, rcx
    jmp 6f
53: inc rcx
    jmp 52b
6:  cmp r14, r13
    jae 7f
    mov rdi, [rsp + 8]
    mov rsi, r14
    call char_cut
    mov r14, rax
7:  mov rdi, r15
    mov rsi, [rsp + 8]
    mov rdx, r14
    call sb_push
    mov rdi, [rsp + 8]
    call mem_free
8:  mov dword ptr [rbx + AT_h], -1
9:  EPILOGUE

# lines_of(ptr, len) -> eax its lines (a final line feed ends the last one)
lines_of:
    xor eax, eax
    test rsi, rsi
    jz 9f
    push rsi
    push rdi
    call count_lfs
    pop rdi
    pop rsi
    cmp byte ptr [rdi + rsi - 1], 10
    je 9f
    inc eax
9:  ret

# count_lfs(ptr, len) -> eax its line feeds
count_lfs:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 9f
    cmp byte ptr [rdi + rcx], 10
    jne 2f
    inc eax
2:  inc rcx
    jmp 1b
9:  ret

# FN agrow_free(AT*): it, its texts, its items, its diff record and its children (the caller took them out of
#   AS_calls: agrow_cut, agrow_done)
FN agrow_free
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    xor r12d, r12d
1:  cmp r12d, ATX_IN
    jae 2f
    mov edi, r12d
    call field_of
    mov rdi, [rbx + rax]
    call mem_free
    inc r12d
    jmp 1b
2:  mov rdi, [rbx + AT_id]
    call mem_free
    mov rdi, [rbx + AT_file]
    call mem_free
    lea rdi, [rbx + AT_in]
    call sb_free
    lea rdi, [rbx + AT_out]
    call sb_free
    lea rdi, [rbx + AT_a]
    call sb_free
    lea rdi, [rbx + AT_b]
    call sb_free
    mov rdi, rbx
    call agrow_items_clear
    lea rdi, [rbx + AT_items]
    call vec_free
    xor r12d, r12d
3:  cmp r12, [rbx + AT_kids + VEC_len]
    jae 4f
    mov rax, [rbx + AT_kids + VEC_ptr]
    mov rdi, [rax + r12*8]
    call agrow_free
    inc r12
    jmp 3b
4:  lea rdi, [rbx + AT_kids]
    call vec_free
    mov rdi, rbx
    call agdiff_free
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# dup_cstr(cstr or 0) -> rax an owned copy, or 0
dup_cstr:
    PROLOGUE
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
9:  EPILOGUE

# FN agrow_clone(AT*) -> rax a deep copy: texts, items, children (agents_copy_rows: a fork shows what its
#   source showed); not in any table, no diff record yet
FN agrow_clone
    PROLOGUE
    mov r12, rdi
    xor eax, eax
    test r12, r12
    jz 9f
    mov edi, AT_SIZE
    call mem_alloc
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    mov edx, AT_SIZE
    call memcpy
    xor r13d, r13d
1:  cmp r13d, ATX_IN
    jae 2f
    mov edi, r13d
    call field_of
    mov r14, rax
    mov rdi, [r12 + r14]
    call dup_cstr
    mov [rbx + r14], rax
    inc r13d
    jmp 1b
2:  mov rdi, [r12 + AT_id]
    call dup_cstr
    mov [rbx + AT_id], rax
    mov rdi, [r12 + AT_file]
    call dup_cstr
    mov [rbx + AT_file], rax
    xor r13d, r13d              # the texts
3:  cmp r13d, 4
    jae 4f
    imul r14, r13, SB_SIZE
    add r14, AT_in
    xor eax, eax
    mov [rbx + r14 + SB_ptr], rax
    mov [rbx + r14 + SB_len], rax
    mov [rbx + r14 + SB_cap], rax
    mov rdx, [r12 + r14 + SB_len]
    test rdx, rdx
    jz 31f
    lea rdi, [rbx + r14]
    mov rsi, [r12 + r14 + SB_ptr]
    call sb_push
31: inc r13d
    jmp 3b
4:  xor eax, eax                # the items
    mov [rbx + AT_items + VEC_ptr], rax
    mov [rbx + AT_items + VEC_len], rax
    mov [rbx + AT_items + VEC_cap], rax
    xor r13d, r13d
5:  cmp r13, [r12 + AT_items + VEC_len]
    jae 6f
    imul r14, r13, ATI_SIZE
    add r14, [r12 + AT_items + VEC_ptr]
    mov rdi, [r14 + ATI_text]
    call dup_cstr
    mov r15, rax
    lea rdi, [rbx + AT_items]
    mov esi, ATI_SIZE
    call vec_push
    mov [rax + ATI_text], r15
    mov ecx, [r14 + ATI_state]
    mov [rax + ATI_state], ecx
    inc r13
    jmp 5b
6:  xor eax, eax                # the children
    mov [rbx + AT_kids + VEC_ptr], rax
    mov [rbx + AT_kids + VEC_len], rax
    mov [rbx + AT_kids + VEC_cap], rax
    xor r13d, r13d
7:  cmp r13, [r12 + AT_kids + VEC_len]
    jae 8f
    mov rax, [r12 + AT_kids + VEC_ptr]
    mov rdi, [rax + r13*8]
    call agrow_clone
    mov [rax + AT_up], rbx
    mov r15, rax
    lea rdi, [rbx + AT_kids]
    mov esi, 8
    call vec_push
    mov [rax], r15
    inc r13
    jmp 7b
8:  mov qword ptr [rbx + AT_diff], 0
    mov dword ptr [rbx + AT_h], -1
    mov rax, rbx
9:  EPILOGUE

# FN agrow_kids(AS*, AT*) -> eax 1 when its children are there: kept from the stream, or read now through the
#   reader's kids function (once: ATF_LOADED)
FN agrow_kids
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp qword ptr [r12 + AT_kids + VEC_len], 0
    jne 8f
    test dword ptr [r12 + AT_flags], ATF_LOADED
    jnz 7f
    cmp qword ptr [r12 + AT_t0], 0  # a call the stream gave gets its children from the stream: the file
    jne 7f                          #   would give them twice
    or dword ptr [r12 + AT_flags], ATF_LOADED
    mov edi, [rbx + AS_kind]
    mov esi, 2
    call agent_reader
    test rax, rax
    jz 7f
    mov rdi, rbx
    mov rsi, r12
    call rax
    mov rdi, rbx
    mov rsi, r12
    call agrow_touch
    cmp qword ptr [r12 + AT_kids + VEC_len], 0
    jne 8f
7:  xor eax, eax
    EPILOGUE
8:  mov eax, 1
    EPILOGUE

# ---------------- layout and drawing ----------------

# rw_wrap(RW*) -> eax lines: a text wrapped at RW_w by its glyphs' advances, at a blank when the line has
#   one, else anywhere; a line feed ends a line; a TAB is four cells. Drawn (RW_draw) line by line between
#   RW_top and RW_bot; each line laid out added to RW_out
rw_wrap:
    PROLOGUE 48
    mov rbx, rdi
    xor r15d, r15d              # lines
    xor r12d, r12d              # p
    mov eax, [rbx + RW_w]
    cmp eax, 1
    jge 0f
    mov eax, 1
0:  shl eax, 6
    mov [rsp + 24], eax         # the width, 26.6
.Lrw_line:
    cmp r12, [rbx + RW_len]
    jae .Lrw_done
    cmp dword ptr [rbx + RW_max], 0
    je 1f
    cmp r15d, [rbx + RW_max]
    jae .Lrw_done
1:  mov r13, r12                # the line's start
    xor r14d, r14d              # its width
    mov qword ptr [rsp], -1     # the last blank
    mov rax, [rbx + RW_len]
    mov [rsp + 8], rax          # its end
    mov [rsp + 16], rax         # the next line's start
.Lrw_ch:
    cmp r12, [rbx + RW_len]
    jae .Lrw_emit
    mov rax, [rbx + RW_text]
    movzx ecx, byte ptr [rax + r12]
    cmp ecx, 10
    jne 2f
    mov [rsp + 8], r12
    lea rcx, [r12 + 1]
    mov [rsp + 16], rcx
    jmp .Lrw_emit2
2:  cmp ecx, ' '
    jne 3f
    mov [rsp], r12
3:  cmp ecx, 9
    jne 4f
    mov rax, [rbx + RW_face]    # a TAB: four cells
    mov eax, [rax + FACE_cellw]
    shl eax, 8
    mov dword ptr [rsp + 32], 1
    mov [rsp], r12
    jmp 5f
4:  lea rdi, [rax + r12]
    mov rsi, [rbx + RW_len]
    sub rsi, r12
    call utf8_decode
    mov [rsp + 32], edx
    mov rdi, [rbx + RW_face]
    mov esi, eax
    call face_glyph
    mov eax, [rax + GL_adv]
5:  lea ecx, [r14 + rax]
    cmp ecx, [rsp + 24]
    jle 7f
    cmp r12, r13
    je 7f                       # a line holds one character at least
    mov rax, [rsp]
    cmp rax, r13
    jle 6f
    mov [rsp + 8], rax          # at the last blank
    inc rax
    mov [rsp + 16], rax
    jmp .Lrw_emit2
6:  mov [rsp + 8], r12          # anywhere
    mov [rsp + 16], r12
    jmp .Lrw_emit2
7:  mov r14d, ecx
    mov eax, [rsp + 32]
    add r12, rax
    jmp .Lrw_ch
.Lrw_emit:
    mov [rsp + 8], r12
    mov [rsp + 16], r12
.Lrw_emit2:
    cmp qword ptr [rip + agsel_lines], 0    # task 10: a selection wants the line's start and end (agentsel.s)
    je 85f
    mov rdi, r13
    mov rsi, [rsp + 8]
    call agsel_line_add
85: mov rdi, [rbx + RW_out]
    test rdi, rdi
    jz 8f
    mov rsi, [rbx + RW_text]
    add rsi, r13
    mov rdx, [rsp + 8]
    sub rdx, r13
    call sb_push
    mov rdi, [rbx + RW_out]
    mov esi, 10
    call sb_push_byte
8:  cmp dword ptr [rbx + RW_draw], 0
    je 9f
    mov eax, r15d
    imul eax, [rbx + RW_lh]
    add eax, [rbx + RW_y]
    mov ecx, eax
    add ecx, [rbx + RW_lh]
    cmp ecx, [rbx + RW_top]
    jle 9f
    cmp eax, [rbx + RW_bot]
    jge 9f
    cmp dword ptr [rip + rw_chips], 0   # phase 4 task 7: a prompt's mention chips behind the line (agents.s)
    je 86f
    push rax
    push rax
    mov rdi, [rbx + RW_text]
    mov rsi, r13
    mov rdx, [rsp + 16 + 8]
    mov ecx, [rbx + RW_x]
    mov r8d, eax
    mov r9d, [rbx + RW_lh]
    call agents_line_chips
    pop rax
    pop rax
86: mov rdx, [rbx + RW_face]
    add eax, [rdx + FACE_ascent]
    mov [rsp + 36], eax         # the baseline
    mov eax, [rbx + RW_x]
    mov [rsp + 40], eax         # the pen
    mov rcx, r13                # a segment at a time: a TAB moves the pen four cells
81: mov r8, rcx
82: cmp r8, [rsp + 8]
    jae 83f
    mov rax, [rbx + RW_text]
    cmp byte ptr [rax + r8], 9
    je 83f
    inc r8
    jmp 82b
83: push rcx
    push r8
    mov rdi, [rbx + RW_face]
    mov esi, [rsp + 16 + 40]
    mov edx, [rsp + 16 + 36]
    sub r8, rcx
    add rcx, [rbx + RW_text]
    mov r9d, [rbx + RW_color]
    mov rax, [rbx + RW_mute]    # muted from RW_mute on (a prompt's truncation marker)
    test rax, rax
    js 84f
    add rax, [rbx + RW_text]
    cmp rax, rcx
    ja 84f
    COLOR r9d, T_MUTED
84: call text_draw
    mov [rsp + 16 + 40], eax
    pop r8
    pop rcx
    cmp r8, [rsp + 8]
    jae 9f
    mov rax, [rbx + RW_face]
    mov eax, [rax + FACE_cellw]
    shl eax, 2
    add [rsp + 40], eax
    lea rcx, [r8 + 1]
    jmp 81b
9:  inc r15d
    mov r12, [rsp + 16]
    jmp .Lrw_line
.Lrw_done:
    test r15d, r15d
    jnz 1f
    mov r15d, 1
1:  mov eax, r15d
    EPILOGUE

# FN agrow_wrap(RW*) -> eax lines: rw_wrap for agentsel.s (task 10: a selection's lines, wrapped as drawn)
FN agrow_wrap
    jmp rw_wrap

# row_of(AS*, row) -> rax AM*
row_of:
    imul rax, rsi, AM_SIZE
    add rax, [rdi + AS_msgs + VEC_ptr]
    ret

# line_row(AM*) -> eax 1 for a row this file draws as a line (thinking, meta, compaction, unknown block)
line_row:
    xor eax, eax
    mov ecx, [rdi + AM_role]
    cmp ecx, R_THINK
    je 1f
    cmp ecx, R_META
    je 1f
    cmp ecx, R_COMPACT
    je 1f
    cmp ecx, R_UNKNOWN
    jne 9f
1:  mov eax, 1
9:  ret

# FN agrow_code_face() -> rax FACE*: code at the panel's text size in the editor's family (made when the
#   size or the editor's font changed)
FN agrow_code_face
    PROLOGUE
    mov rax, [rip + ag_fui]
    mov ebx, [rax + FACE_px]
    lea rax, [rip + g_face_code]
    cmp qword ptr [rax + FACE_font], 0
    je 9f                       # no fonts yet
    cmp ebx, [rax + FACE_px]
    je 9f                       # the editor's own face is that size
    lea rax, [rip + code_face]
    cmp ebx, [rip + code_px]
    jne 1f
    mov rcx, [rip + g_face_code + FACE_font]
    cmp rcx, [rax + FACE_font]
    je 9f
1:  mov [rip + code_px], ebx
    lea rdi, [rip + code_face]
    mov rsi, [rip + g_face_code + FACE_font]
    mov edx, ebx
    cmp edx, 4
    jge 2f
    mov edx, 4
2:  call face_init
    lea rax, [rip + code_face]
9:  EPILOGUE

# clip_of(face) -> eax a tool text's clip: 3 x MI_20 of the panel (the extension's 60 px, scaled)
clip_h:
    mov eax, [rip + g_pmt + 4*MI_20]
    imul eax, eax, 3
    ret

# FN agrow_est(AS*, row) -> eax the pixels of its height that do not depend on the width, edx its lines and
#   ecx its bytes that wrap (agents.s's estimate and chunk aggregates). A call: its parts, its texts as tall as
#   their lines up to the clip (no width part); a hidden call: 0, 0, 0
FN agrow_est
    PROLOGUE
    call row_of
    mov rbx, rax
    mov r12, [rbx + AM_x]
    test r12, r12
    jnz 2f
    cmp dword ptr [rbx + AM_role], R_COMPACT
    je 610f
    cmp dword ptr [rbx + AM_role], R_THINK
    jne 0f
610: mov rdi, rbx                # thinking, a marker: its label line; open, its text's lines too
    call think_est
    EPILOGUE
0:  mov edx, [rbx + AM_nl]      # a line row: the small face's lines
    inc edx
    mov rcx, [rbx + AM_len]
    cmp rcx, 16777216
    jbe 1f
    mov ecx, 16777216
1:  PM eax, MI_8
    EPILOGUE
2:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    test dword ptr [r12 + AT_flags], ATF_HIDDEN
    jnz 9f
    call head_h                 # header and paddings
    mov r13d, eax
    add r13d, [rip + g_pmt + 4*MI_8]
    mov rax, [rip + ag_fsmall]
    mov r14d, [rax + FACE_lineh]
    add r14d, [rip + g_pmt + 4*MI_2]
    cmp qword ptr [r12 + AT_desc], 0
    je 3f
    add r13d, r14d
3:  cmp qword ptr [r12 + AT_note], 0
    je 4f
    add r13d, r14d
4:  call agrow_code_face
    mov r14d, [rax + FACE_lineh]
    xor r15d, r15d              # the body
    lea rdi, [r12 + AT_in]
    mov esi, r14d
    call est_text
    add r15d, eax
    lea rdi, [r12 + AT_out]
    mov esi, r14d
    call est_text
    add r15d, eax
    test r15d, r15d
    jz 5f
    add r15d, [rip + g_pmt + 4*MI_6]
    add r15d, [rip + g_pmt + 4*MI_6]
    add r15d, [rip + g_pmt + 4*MI_6]
5:  mov rdi, r12                # the diff or the file's text (agentdiff.s)
    call agdiff_est
    test eax, eax
    jz 51f
    add r15d, eax
    add r15d, [rip + g_pmt + 4*MI_6]
51: mov rdi, r12                # the line of the calls under it (task 11)
    call kids_shown
    test eax, eax
    jz 52f
    call kl_h
    add r13d, eax
52: lea eax, [r13 + r15]
    xor edx, edx
    xor ecx, ecx
    mov r14, [r12 + AT_items + VEC_len]     # a todo list: a line an item at least, its texts wrap
    test r14, r14
    jz 9f
    mov r13d, eax
    mov eax, [rip + g_pmt + 4*MI_4]
    lea ecx, [r14 + 1]
    imul eax, ecx
    add r13d, eax
    xor r15d, r15d
    xor ebx, ebx
6:  cmp rbx, r14
    jae 7f
    imul rax, rbx, ATI_SIZE
    add rax, [r12 + AT_items + VEC_ptr]
    mov rdi, [rax + ATI_text]
    call strlen
    add r15, rax
    inc rbx
    jmp 6b
7:  mov eax, r13d
    mov edx, r14d
    mov ecx, r15d
9:  EPILOGUE

# think_est(AM*) -> eax, edx, ecx: a thinking row's estimate parts: closed (or without text) its label line
#   and paddings, exact; open with text also its text's lines and bytes
think_est:
    PROLOGUE
    mov rbx, rdi
    call think_line_h
    add eax, [rip + g_pmt + 4*MI_4]
    add eax, [rip + g_pmt + 4*MI_4]
    xor edx, edx
    xor ecx, ecx
    cmp dword ptr [rbx + AM_role], R_COMPACT
    jne 610f
    test dword ptr [rbx + AM_flags], AMF_OPEN  # a marker: open, its summary or the sentence
    jz 9f
    add eax, [rip + g_pmt + 4*MI_4]
    cmp qword ptr [rbx + AM_len], 0
    jne 620f
    mov rcx, [rip + ag_fsmall]
    add eax, [rcx + FACE_lineh]
    xor ecx, ecx
    jmp 9f
610: cmp dword ptr [rip + think_open], 0
    je 9f
    mov r12d, eax
    mov rdi, rbx
    call think_has_text
    test eax, eax
    mov eax, r12d
    jz 9f
620: add eax, [rip + g_pmt + 4*MI_4]
    mov edx, [rbx + AM_nl]
    inc edx
    mov rcx, [rbx + AM_len]
    cmp rcx, 16777216
    jbe 9f
    mov ecx, 16777216
9:  EPILOGUE

# think_line_h() -> eax a thinking row's label line: the text face's line, at least MI_20
think_line_h:
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    mov ecx, [rip + g_pmt + 4*MI_20]
    cmp eax, ecx
    cmovl eax, ecx
    ret

# think_has_text(AM*) -> eax 1 when a thinking row has text (more than blanks): a button that opens it
think_has_text:
    mov rdx, [rdi + AM_text]
    mov rcx, [rdi + AM_len]
    xor eax, eax
    test rdx, rdx
    jz 9f
1:  test rcx, rcx
    jz 9f
    dec rcx
    cmp byte ptr [rdx + rcx], ' '
    jbe 1b
    mov eax, 1
9:  ret

# est_text(SB*, line h) -> eax a body text's estimated height: its lines up to the clip, and a gap; 0 none
est_text:
    xor eax, eax
    mov rdx, [rdi + SB_len]
    test rdx, rdx
    jz 9f
    push rsi
    push rsi
    mov rsi, rdx
    mov rdi, [rdi + SB_ptr]
    call count_lfs
    pop rsi
    pop rsi
    inc eax
    imul eax, esi
    push rax
    call clip_h
    mov ecx, eax
    pop rax
    cmp eax, ecx
    cmova eax, ecx
    add eax, [rip + g_pmt + 4*MI_4]
9:  ret

# head_h() -> eax a call's header line: the text face's line, at least MI_20, and MI_4 above it
head_h:
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    mov ecx, [rip + g_pmt + 4*MI_20]
    cmp eax, ecx
    cmovl eax, ecx
    add eax, [rip + g_pmt + 4*MI_4]
    ret

# FN agrow_h(AS*, row, w) -> eax its height measured at the width
FN agrow_h
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    call row_of
    cmp qword ptr [rax + AM_x], 0
    jne 1f
    cmp dword ptr [rax + AM_role], R_COMPACT
    je 610f
    cmp dword ptr [rax + AM_role], R_THINK
    jne 0f
610: mov dword ptr [rip + lr_mode], LM_MEASURE
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    xor ecx, ecx
    mov r8d, r13d
    call think_lay
    EPILOGUE
0:  mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    xor ecx, ecx
    mov r8d, r13d
    mov r9d, LM_MEASURE
    call line_lay
    EPILOGUE
1:  mov dword ptr [rip + lr_mode], LM_MEASURE
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    xor ecx, ecx
    mov r8d, r13d
    call tr_lay
    EPILOGUE

# FN agrow_draw(AS*, row, x, y, w, h): drawn at x, y (x the text's left: its dot is in the pad before it)
FN agrow_draw
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    call row_of
    cmp qword ptr [rax + AM_x], 0
    jne 1f
    cmp dword ptr [rax + AM_role], R_THINK
    je 0f
    cmp dword ptr [rax + AM_role], R_COMPACT
    je 0f
    mov rdi, r12                # a line row: a wrapped notice is a button (a slot for its id)
    xor esi, esi
    call agrow_slot
    mov [rip + lr_slot], eax
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r15d
    mov r9d, LM_DRAW
    call line_lay
    jmp 2f
0:  mov rdi, r12                # thinking, a compaction marker: its label is a button (a slot for its id)
    xor esi, esi
    call agrow_slot
    mov [rip + lr_slot], eax
    mov dword ptr [rip + lr_mode], LM_DRAW
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r15d
    call think_lay
    mov dword ptr [rip + lr_mode], LM_MEASURE
    jmp 2f
1:  mov rdi, r12
    xor esi, esi
    call agrow_slot
    mov [rip + lr_slot], eax
    mov dword ptr [rip + lr_mode], LM_DRAW
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r15d
    call tr_lay
2:  mov [rsp], eax
    cmp [rip + rf_row], r12     # the row focus: a frame around it
    jne 9f
    mov rdi, rbx                # (on a fold's first row the focus is its line's: agentfold.s frames it)
    mov rsi, r12
    call agfold_action
    cmp eax, PART_FOLD
    je 9f
    mov edi, r13d
    sub edi, [rip + g_pmt + 4*MI_4]
    mov esi, r14d
    mov edx, r15d
    add edx, [rip + g_pmt + 4*MI_8]
    mov ecx, [rsp]
    call focus_frame
9:  EPILOGUE

# focus_frame(x, y, w, h): a 1 px T_ACCENT frame
focus_frame:
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    COLOR r8d, T_ACCENT
    mov ecx, 1
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rsp + 12]
    dec esi
    mov edx, [rsp + 8]
    mov ecx, 1
    COLOR r8d, T_ACCENT
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, 1
    mov ecx, [rsp + 12]
    COLOR r8d, T_ACCENT
    call gfx_fill
    mov edi, [rsp]
    add edi, [rsp + 8]
    dec edi
    mov esi, [rsp + 4]
    mov edx, 1
    mov ecx, [rsp + 12]
    COLOR r8d, T_ACCENT
    call gfx_fill
    EPILOGUE

# dot(x, y, argb): a row's dot, MI_6 across, its left at x and its top at y
dot:
    PROLOGUE
    mov r9d, edx
    PM edx, MI_6
    mov ecx, edx
    mov r8d, edx
    shr r8d, 1
    call gfx_round_rect
    EPILOGUE

# row_dot(x of the text, y of the line, line h, argb): the dot in the pad before the text, centred on the line
row_dot:
    PROLOGUE
    mov r12d, ecx
    PM eax, MI_6
    sub edx, eax
    sar edx, 1
    add esi, edx
    sub edi, [rip + g_pmt + 4*MI_10]
    mov edx, r12d
    call dot
    EPILOGUE

# line_lay(AS*, row, x, y, w, mode) -> eax its height: a thinking, meta, compaction or unknown-block row. A
#   meta line (and, until their own forms, thinking and compaction rows: their text) is the small face, muted,
#   wrapped; an unknown block "Unsupported content type: " and its type in the code face. Thinking has a
#   muted dot
line_lay:
    PROLOGUE RW_SIZE + 32
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    mov [rsp + RW_SIZE], r9d
    mov [rip + lr_row], r12
    mov qword ptr [rip + lr_at], 0
    call row_of
    mov [rsp + RW_SIZE + 8], rax
    cmp dword ptr [rax + AM_role], R_UNKNOWN
    je .Lll_unknown
    mov rcx, [rax + AM_text]
    mov [rsp + RW_text], rcx
    mov rcx, [rax + AM_len]
    mov [rsp + RW_len], rcx
    mov [rsp + RW_w], r15d
    mov rax, [rip + ag_fsmall]
    mov [rsp + RW_face], rax
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_3]
    mov [rsp + RW_lh], eax
    mov [rsp + RW_x], r13d
    mov eax, r14d
    add eax, [rip + g_pmt + 4*MI_4]
    mov [rsp + RW_y], eax
    COLOR eax, T_MUTED
    mov [rsp + RW_color], eax
    mov dword ptr [rsp + RW_max], 0
    mov rax, [rsp + RW_SIZE + 8]    # a wrapped notice: its first line (its label) until it is opened
    test dword ptr [rax + AM_flags], AMF_NOTICE
    jz 0f
    test dword ptr [rax + AM_flags], AMF_OPEN
    jnz 0f
    mov dword ptr [rsp + RW_max], 1
0:  mov qword ptr [rsp + RW_out], 0
    mov qword ptr [rsp + RW_mute], -1
    xor eax, eax
    cmp dword ptr [rsp + RW_SIZE], LM_DRAW
    sete al
    mov [rsp + RW_draw], eax
    mov eax, [rip + g_cv + CV_cy0]
    mov [rsp + RW_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rsp + RW_bot], eax
    cmp dword ptr [rsp + RW_draw], 0    # task 10: a meta line (not a notice) is selected by the pointer,
    je 3f                              #   banded under its text (agentsel.s): its height first
    mov rax, [rsp + RW_SIZE + 8]
    cmp dword ptr [rax + AM_role], R_META
    jne 3f
    test dword ptr [rax + AM_flags], AMF_NOTICE
    jnz 3f
    mov dword ptr [rsp + RW_draw], 0
    lea rdi, [rsp]
    call rw_wrap
    imul eax, [rsp + RW_lh]
    mov [rsp + RW_SIZE + 24], eax
    mov dword ptr [rsp + RW_draw], 1
    mov edi, SELP_META
    call part_id
    mov ecx, eax
    lea rdi, [rsp]
    mov rsi, r12
    mov edx, SELP_META
    mov r8d, [rsp + RW_SIZE + 24]
    call agsel_plain
3:  lea rdi, [rsp]
    call rw_wrap
    imul eax, [rsp + RW_lh]
    mov [rsp + RW_SIZE + 20], eax
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + RW_SIZE + 4], eax
    mov rax, [rsp + RW_SIZE + 8]    # the notice's button: its text (MI_16 high at least)
    test dword ptr [rax + AM_flags], AMF_NOTICE
    jz 1f
    cmp dword ptr [rsp + RW_SIZE], LM_DRAW
    jne 1f
    mov ecx, [rip + g_pmt + 4*MI_16]
    mov r8d, [rsp + RW_SIZE + 20]
    cmp r8d, ecx
    cmovl r8d, ecx
    mov edi, PART_TOGGLE
    mov esi, r13d
    mov edx, [rsp + RW_y]
    mov ecx, r15d
    call toggle_btn
1:
    cmp dword ptr [rsp + RW_SIZE], LM_DRAW
    jne 9f
    mov rax, [rsp + RW_SIZE + 8]
    cmp dword ptr [rax + AM_role], R_THINK
    jne 9f
    mov edi, r13d               # thinking: a muted dot
    mov esi, [rsp + RW_y]
    mov edx, [rsp + RW_lh]
    COLOR ecx, T_MUTED
    call row_dot
    jmp 9f
.Lll_unknown:
    mov rax, [rip + ag_fsmall]  # one line: the label, then the type in the code face
    mov eax, [rax + FACE_lineh]
    mov [rsp + RW_SIZE + 16], eax
    call agrow_code_face
    mov ecx, [rax + FACE_lineh]
    cmp ecx, [rsp + RW_SIZE + 16]
    jle 1f
    mov [rsp + RW_SIZE + 16], ecx   # the line's height
1:  mov eax, [rsp + RW_SIZE + 16]
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + RW_SIZE + 4], eax
    cmp dword ptr [rsp + RW_SIZE], LM_DRAW
    jne 9f
    mov rdi, [rip + ag_fsmall]
    mov esi, r13d
    mov edx, r14d
    add edx, [rip + g_pmt + 4*MI_4]
    mov ecx, [rsp + RW_SIZE + 16]
    lea r8, [rip + .Lunsupported]   # cut at the row's width
    mov r9d, UNSUPPORTED_LEN
    COLOR r10d, T_MUTED
    mov r11d, r15d
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    mov [rsp + RW_SIZE + 20], eax
    mov ecx, r13d               # the type: in the room left
    add ecx, r15d
    sub ecx, eax
    cmp ecx, [rip + g_pmt + 4*MI_8]
    jl 9f
    call agrow_code_face
    mov rdi, rax
    mov esi, [rsp + RW_SIZE + 20]
    mov edx, r14d
    add edx, [rip + g_pmt + 4*MI_4]
    mov ecx, [rsp + RW_SIZE + 16]
    mov rax, [rsp + RW_SIZE + 8]
    mov r8, [rax + AM_text]
    mov r9, [rax + AM_len]
    COLOR r10d, T_MUTED
    mov r11d, r13d
    add r11d, r15d
    sub r11d, [rsp + RW_SIZE + 20]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
9:  mov eax, [rsp + RW_SIZE + 4]
    EPILOGUE

# ---------------- thinking ----------------
#
# think_lay(AS*, row, x, y, w) -> eax a thinking row's height, laid out in lr_mode (its slot in lr_slot): the
#   label line, muted ("Thinking..." and the estimate while it streams, "Thought for Ns", "Thinking"), the dot
#   in the pad before it; with text a chevron after the label and the line a button (PART_TOGGLE: every
#   thinking row of the conversation opens or closes, after the frame); open, its text as Markdown under it
#   (compact, muted; parsed when first laid out open and again when its text changed, as a reply is).
#   Closed it is exact without any text laid out. Frame: [rsp] x, [4] y, [8] w, [12] has text, [16] the
#   line's height, [20] the label's width, [24] the chevron's x, [28] the text's height, [32] its top drawn,
#   [36] its height drawn, [40] its scroll
think_lay:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 8], r8d
    mov [rip + lr_row], r12
    mov qword ptr [rip + lr_at], 0
    mov [rip + lr_x], edx
    mov [rip + lr_y], ecx
    mov [rip + lr_w], r8d
    call row_of
    mov r14, rax
    mov rdi, rax
    call think_has_text
    mov [rsp + 12], eax
    mov eax, [rip + think_open] # open: thinking's one state, a compaction marker's own (AMF_OPEN)
    cmp dword ptr [r14 + AM_role], R_COMPACT
    jne 610f
    mov dword ptr [rsp + 12], 1 # (a marker always opens: its summary, or the sentence)
    mov eax, [r14 + AM_flags]
    shr eax, 5
    and eax, 1
610: mov [rsp + 44], eax
    call think_line_h
    mov [rsp + 16], eax
    mov r13d, [rsp + 4]         # cy
    add r13d, [rip + g_pmt + 4*MI_4]
    lea rdi, [rip + ys]         # the label
    call sb_clear
    lea rdi, [rip + ys]
    mov rsi, r14
    call think_label
    mov rax, [rip + ys + SB_ptr]
    mov [rip + ln_ptr], rax
    mov rax, [rip + ys + SB_len]
    mov [rip + ln_len], rax
    mov rdi, [rip + ag_fui]
    mov rsi, [rip + ln_ptr]
    mov rdx, [rip + ln_len]
    call text_width
    mov ecx, [rsp + 8]          # the room for it: the row less the chevron
    cmp dword ptr [rsp + 12], 0
    je 1f
    sub ecx, [rip + g_pmt + 4*MI_4]
    sub ecx, [rip + g_pmt + 4*MI_16]
1:  test ecx, ecx
    jns 11f
    xor ecx, ecx
11: cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 20], eax
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 2f
    cmp dword ptr [r14 + AM_role], R_COMPACT    # (a marker has no dot)
    je 2f
    test dword ptr [r14 + AM_flags], AMF_LIVE   # streaming in a conversation rhun drives: it blinks
    jz 12f                      #   (the one tick: on 4 ticks, off 4)
    mov rdi, rbx
    call agents_session_live
    test eax, eax
    jz 12f
    call agspin_seen
    call agspin_phase
    test eax, 4
    jnz 2f
12: mov edi, [rsp]              # the dot, muted
    mov esi, r13d
    mov edx, [rsp + 16]
    COLOR ecx, T_MUTED
    call row_dot
2:  mov rdi, [rip + ag_fui]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 16]
    mov r8, [rip + ln_ptr]
    mov r9, [rip + ln_len]
    COLOR eax, T_MUTED
    mov r10d, [rsp + 20]
    inc r10d
    push r10
    push rax
    call fit_text
    add rsp, 16
    lea rdi, [rip + .Lk_label]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 20]
    mov r8d, [rsp + 16]
    xor r9d, r9d
    call lay_line
    cmp dword ptr [rsp + 12], 0
    je 4f
    mov eax, [rsp]              # the chevron: right when closed, down when open
    add eax, [rsp + 20]
    add eax, [rip + g_pmt + 4*MI_4]
    mov [rsp + 24], eax
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 3f
    mov edi, IC_CHEV_R
    cmp dword ptr [rsp + 44], 0
    je 21f
    mov edi, IC_CHEV_D
21: mov esi, [rsp + 24]
    PM ecx, MI_16
    mov edx, [rsp + 16]
    sub edx, ecx
    sar edx, 1
    add edx, r13d
    COLOR r8d, T_MUTED
    call icon_draw
3:  mov edx, [rsp + 24]         # the button: the label and the chevron, MI_16 high at least
    add edx, [rip + g_pmt + 4*MI_16]
    sub edx, [rsp]
    mov eax, [rsp + 8]
    cmp edx, eax
    cmovg edx, eax
    mov ecx, [rsp + 16]
    mov eax, [rip + g_pmt + 4*MI_16]
    cmp ecx, eax
    cmovl ecx, eax
    mov edi, [rsp]
    mov esi, r13d
    cmp dword ptr [r14 + AM_role], R_COMPACT
    je 31f
    call think_btn
    jmp 4f
31: mov r8d, ecx                # a marker's: its own row opens or closes (after the frame)
    mov ecx, edx
    mov edx, esi
    mov esi, edi
    mov edi, PART_TOGGLE
    call toggle_btn
4:  add r13d, [rsp + 16]
    cmp dword ptr [rsp + 12], 0
    je 8f
    cmp dword ptr [rsp + 44], 0
    je 8f
    add r13d, [rip + g_pmt + 4*MI_4]    # open: the text
    cmp dword ptr [r14 + AM_role], R_COMPACT
    jne 41f
    cmp qword ptr [r14 + AM_len], 0
    jne 41f
    mov rax, [rip + ag_fsmall]  # a marker without a summary: the sentence ($Rt), one line cut to the row
    mov eax, [rax + FACE_lineh]
    mov [rsp + 28], eax
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 42f
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 28]
    lea r8, [rip + .Lcompacted_free]
    mov r9d, COMPACTED_FREE_LEN
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 8]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    jmp 7f
42: cmp dword ptr [rip + lr_mode], LM_FIT
    jne 7f
    lea rdi, [rip + .Lk_text]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 28]
    xor r9d, r9d
    call lay_line
    jmp 7f
41: mov rdi, r14
    call agents_msg_doc
    mov r15, rax
    xor esi, esi                # thinking's text muted, a summary not
    cmp dword ptr [r14 + AM_role], R_THINK
    sete sil
    mov rdi, rax
    call md_set_muted
    mov rdi, r15
    mov esi, [rsp + 8]
    call md_layout
    mov [rsp + 28], eax
    mov eax, [rip + lr_mode]
    cmp eax, LM_DRAW
    je 5f
    cmp eax, LM_DUMP
    je 6f
    cmp eax, LM_FIT
    jne 7f
    lea rdi, [rip + .Lk_text]   # the fit: its box
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 28]
    xor r9d, r9d
    call lay_line
    jmp 7f
6:  mov rdi, r15                # print-agent-row: its blocks as drawn
    mov rsi, [rip + lr_out]
    mov edx, [rsp]
    mov ecx, r13d
    call md_row_dump
    jmp 7f
5:  mov eax, r13d               # drawn: the part in view
    mov ecx, eax
    add ecx, [rsp + 28]
    mov edx, [rip + g_cv + CV_cy0]
    cmp edx, eax
    cmovl edx, eax
    mov r8d, [rip + g_cv + CV_cy1]
    cmp r8d, ecx
    cmovg r8d, ecx
    sub r8d, edx
    jle 7f
    mov [rsp + 32], edx
    mov [rsp + 36], r8d
    sub edx, eax
    mov [rsp + 40], edx
    mov rdi, rbx                # task 10: its text is selected by the pointer (agentsel.s)
    mov rsi, r12
    mov rdx, r15
    mov ecx, [rsp]
    mov r8d, [rsp + 32]
    mov r9d, [rsp + 40]
    call agsel_md
    mov eax, r12d               # its links' ids: the range a reply of its index would have
    and eax, 255
    shl eax, 12
    add eax, ID_AG_MD
    push rax
    push rax
    mov rdi, r15
    mov esi, [rsp + 16]
    mov edx, [rsp + 16 + 32]
    mov ecx, [rsp + 16 + 8]
    mov r8d, [rsp + 16 + 36]
    mov r9d, [rsp + 16 + 40]
    call md_draw
    add rsp, 16
    test eax, eax               # task 10: a link in it followed as a reply's is (agents.s)
    js 7f
    mov rdi, r14
    mov esi, eax
    mov edx, r13d
    sub edx, [rsp + 4]
    call agents_link_click
7:  add r13d, [rsp + 28]
8:  add r13d, [rip + g_pmt + 4*MI_4]
    mov eax, r13d
    sub eax, [rsp + 4]
    EPILOGUE

# think_btn(x, y, w, h): a thinking row's label as a button (PART_TOGGLE of the unit laid out): drawn, a click
#   asks for every thinking row to open or close after the frame; written out as lay_btn writes a button
think_btn:
    PROLOGUE 16
    cmp dword ptr [rip + lr_mode], LM_DRAW
    je 1f
    mov r8d, ecx
    mov ecx, edx
    mov edx, esi
    mov esi, edi
    mov edi, PART_TOGGLE
    call lay_btn
    EPILOGUE
1:  mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov edi, PART_TOGGLE
    call part_id
    test eax, eax
    js 9f
    mov edi, eax
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call ui_btn
    test eax, UB_HOVER
    jz 2f
    mov dword ptr [rip + g_cursor], CUR_POINTER
2:  test eax, UB_CLICK
    jz 9f
    mov dword ptr [rip + pend_think], 1
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN agrow_think_toggle(): the open conversation's thinking rows open or close, all of them (a click, Enter,
#   Ctrl+O, "Agents: Expand or Collapse Thinking"); every height that depends on it is measured again
FN agrow_think_toggle
    xor dword ptr [rip + think_open], 1
    jmp agents_view_changed

# FN agrow_think_reset(): closed again (another conversation is opened)
FN agrow_think_reset
    mov dword ptr [rip + pend_think], 0
    cmp dword ptr [rip + think_open], 0
    je 1f
    mov dword ptr [rip + think_open], 0
    jmp agents_view_changed
1:  ret

# FN agents_toggle_thinking(): "Agents: Expand or Collapse Thinking": with a conversation open in the panel,
#   its thinking rows open or close (the keys stay where they are)
FN agents_toggle_thinking
    PROLOGUE
    call agents_viewed
    test rax, rax
    jz 9f
    call agrow_think_toggle
9:  EPILOGUE

# ---------------- a call's row ----------------
#
# Top to bottom, each part only when it is set: the header line (the dot in the pad before it; the name bold;
# the second text, a link in T_ACCENT when AT_link is set, cut with "…"; the tail muted), the description line
# (muted, small, one line), the note line (muted, small; a button when it has a tab of its own: AT_title and
# OUT), the body on T_BG (IN, then OUT: a label in the code face, the text in the code face wrapped at the
# width and clipped at 3 x MI_20 with a fade, a button when it is long (V7); IN of a command with a Copy
# button; OUT in T_ERROR when the call failed, cut at 2000 characters, clipped at 10 lines only when it is a
# button), the diff or a file's text (agentdiff.s). tr_lay lays it out in lr_mode: measured, drawn (its
# buttons live), or its parts written out (print-agent-row, print-agent-rows-fit)

# state_color(AS*, AT*) -> eax its dot's colour: ok, failed, denied by the theme; running: the driver's own
#   colour (else the accent) in a conversation that is live, muted in one only read; stopped muted
state_color:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + AT_state]
    COLOR ecx, T_SUCCESS
    cmp eax, ATS_OK
    je 8f
    COLOR ecx, T_ERROR
    cmp eax, ATS_FAILED
    je 8f
    COLOR ecx, T_WARNING
    cmp eax, ATS_DENIED
    je 8f
    COLOR ecx, T_MUTED
    cmp eax, ATS_RUNNING
    jne 8f
    mov rdi, rbx
    call agents_session_live
    COLOR ecx, T_MUTED
    test eax, eax
    jz 8f
    mov rdi, rbx                # the spinner's: the open mode's, the driver's own in the default ones
    call agspin_color
    mov ecx, eax
8:  mov eax, ecx
    EPILOGUE

# part_id(part) -> eax the button id of that part of the unit laid out (lr_slot), -1 without a slot
part_id:
    mov eax, [rip + lr_slot]
    test eax, eax
    js 9f
    shl eax, 6
    add eax, edi
    add eax, ID_AG_PART
9:  ret

# lay_btn(part, x, y, w, h) -> eax UB_* bits: a button of the unit laid out. Drawn: live (a click kept for
#   after the frame, a pointer, the tip of a text that opens in a tab); written out: "button PART X,Y,W,H ID",
#   or for the fit "  button PART X,Y,W,H" from the row's left and top
lay_btn:
    PROLOGUE 32
    mov ebx, edi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    call part_id
    mov r12d, eax
    xor eax, eax
    test r12d, r12d
    js 9f
    mov ecx, [rip + lr_mode]
    cmp ecx, LM_DRAW
    je 1f
    cmp ecx, LM_DUMP
    jb 9f
    mov r13, [rip + lr_out]     # written out
    cmp ecx, LM_FIT
    jne 2f
    mov rdi, r13
    lea rsi, [rip + .Lfit_indent]
    call sb_push_cstr
2:  mov rdi, r13
    lea rsi, [rip + .Lk_button]
    call sb_push_cstr
    mov rdi, r13
    mov esi, ebx
    call sb_push_u64
    mov rdi, r13
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rsp]
    call lay_rect
    cmp dword ptr [rip + lr_mode], LM_FIT
    je 3f
    mov rdi, r13
    mov esi, ' '
    call sb_push_byte
    mov rdi, r13
    mov esi, r12d
    call sb_push_u64
3:  mov rdi, r13
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    jmp 9f
1:  mov edi, r12d               # drawn
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call ui_btn
    mov r13d, eax
    test eax, UB_HOVER
    jz 4f
    mov dword ptr [rip + g_cursor], CUR_POINTER
    cmp ebx, PART_IN
    je 41f
    cmp ebx, PART_OUT
    je 41f
    cmp ebx, PART_NOTE
    je 41f
    cmp ebx, PART_PRE
    jne 4f
41: mov edi, r12d               # "Press Enter to open the full text in an editor tab"
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rsp + 12]
    mov ecx, [rsp + 8]
    mov r8d, r13d
    lea r9, [rip + .Ltip_full]
    call tip_note_text
4:  test r13d, UB_RPRESS        # task 10: a right press on the header's link: Copy Link (agentsel.s); the
    jz 43f                      #   release of a drag that selected text in it is no click
    cmp ebx, PART_LINK
    jne 43f
    mov rax, [rip + lr_at]
    mov rdi, [rax + AT_link]
    call agsel_rlink
43: test r13d, UB_CLICK
    jz 5f
    call agsel_moved
    test eax, eax
    jnz 5f
    mov rdi, [rip + lr_row]
    mov rsi, [rip + lr_at]
    mov edx, ebx
    call pend_set
5:  mov eax, r13d
9:  EPILOGUE

# lay_rect(int* {x, y, w, h}): "X,Y,W,H" to lr_out (for the fit: from the row's left and top)
lay_rect:
    PROLOGUE
    mov rbx, rdi
    mov r13, [rip + lr_out]
    mov eax, [rbx]
    mov ecx, [rbx + 4]
    cmp dword ptr [rip + lr_mode], LM_FIT
    jne 1f
    sub eax, [rip + lr_x]
    sub ecx, [rip + lr_y]
1:  mov r14d, ecx
    mov rdi, r13
    mov esi, eax
    call md_push_int
    mov rdi, r13
    mov esi, ','
    call sb_push_byte
    mov rdi, r13
    mov esi, r14d
    call md_push_int
    mov rdi, r13
    mov esi, ','
    call sb_push_byte
    mov rdi, r13
    mov esi, [rbx + 8]
    call md_push_int
    mov rdi, r13
    mov esi, ','
    call sb_push_byte
    mov rdi, r13
    mov esi, [rbx + 12]
    call md_push_int
    EPILOGUE

# lay_line(kind cstr, x, y, w, h, flags) with the text in ln_ptr, ln_len: a part written out. LM_DUMP:
#   "KIND X,Y,W,H TEXT" (flags 1: "KIND TEXT", no box; 2: the link's id after the text); LM_FIT: "  KIND
#   X,Y,W,H" from the row's left and top. TEXT: its first line, 60 bytes
lay_line:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov [rsp + 16], r9d
    mov eax, [rip + lr_mode]
    cmp eax, LM_DUMP
    jb 9f
    mov r13, [rip + lr_out]
    cmp eax, LM_FIT
    jne 1f
    mov rdi, r13
    lea rsi, [rip + .Lfit_indent]
    call sb_push_cstr
1:  mov rdi, r13
    mov rsi, rbx
    call sb_push_cstr
    mov rdi, r13
    mov esi, ' '
    call sb_push_byte
    cmp dword ptr [rip + lr_mode], LM_FIT
    je 2f
    test dword ptr [rsp + 16], 1
    jnz 3f
2:  lea rdi, [rsp]
    call lay_rect
    cmp dword ptr [rip + lr_mode], LM_FIT
    je 8f
    mov rdi, r13
    mov esi, ' '
    call sb_push_byte
3:  mov rsi, [rip + ln_ptr]     # its first line
    mov rdx, [rip + ln_len]
    xor ecx, ecx
4:  cmp rcx, rdx
    jae 5f
    cmp rcx, 60
    jae 5f
    cmp byte ptr [rsi + rcx], 10
    je 5f
    inc rcx
    jmp 4b
5:  mov rdi, r13
    mov rdx, rcx
    call sb_push
    test dword ptr [rsp + 16], 2
    jz 8f
    mov rdi, r13
    mov esi, ' '
    call sb_push_byte
    mov edi, PART_LINK
    call part_id
    mov rdi, r13
    mov esi, eax
    call md_push_int
8:  mov rdi, r13
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# fit_text(face, x, y, h, ptr, len, argb, maxw) using lr_mode: drawn when drawing (ui_text_v_fit)
fit_text:
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 1f
    jmp ui_text_v_fit
1:  ret

# text_w(face, cstr) -> eax its width
text_w:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call text_width
    EPILOGUE

# fade(x, y, w, h): the clipped text's last pixels fade into the box (T_BG, more opaque downwards)
fade:
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov eax, ecx
    xor edx, edx
    mov ecx, 5
    div ecx
    test eax, eax
    jnz 1f
    mov eax, 1
1:  mov [rsp + 12], eax         # a strip's height
    xor ebx, ebx
2:  cmp ebx, 5
    jae 9f
    COLOR r8d, T_BG
    and r8d, 0x00ffffff
    lea eax, [rbx + 1]
    imul eax, eax, 51           # 20 % to 100 %
    shl eax, 24
    or r8d, eax
    mov edi, [rsp]
    mov eax, [rsp + 12]
    imul eax, ebx
    mov esi, [rsp + 4]
    add esi, eax
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_fill
    inc ebx
    jmp 2b
9:  EPILOGUE

# section(part, x, y, w, clip, argb, big, kind cstr) with the text in sec_ptr, sec_len -> eax its height: a
#   body text in the code face wrapped at w, as tall as its lines up to clip (0: all), a fade when it is
#   cut; a button over it when big (its hit area MI_16 at least)
section:
    PROLOGUE RW_SIZE + 48
    mov [rsp + RW_SIZE], edi    # part
    mov [rsp + RW_SIZE + 4], esi
    mov [rsp + RW_SIZE + 8], edx
    mov [rsp + RW_SIZE + 12], ecx
    mov [rsp + RW_SIZE + 16], r8d   # clip
    mov [rsp + RW_SIZE + 20], r9d   # colour
    mov eax, [rbp + 16]
    mov [rsp + RW_SIZE + 24], eax   # big
    mov rax, [rbp + 24]
    mov [rsp + RW_SIZE + 32], rax   # kind
    call agrow_code_face
    mov [rsp + RW_face], rax
    mov ebx, [rax + FACE_lineh] # a line
    mov [rsp + RW_lh], ebx
    mov rax, [rip + sec_ptr]
    mov [rsp + RW_text], rax
    mov rax, [rip + sec_len]
    mov [rsp + RW_len], rax
    mov eax, [rsp + RW_SIZE + 4]
    mov [rsp + RW_x], eax
    mov eax, [rsp + RW_SIZE + 8]
    mov [rsp + RW_y], eax
    mov eax, [rsp + RW_SIZE + 12]
    mov [rsp + RW_w], eax
    mov eax, [rsp + RW_SIZE + 20]
    mov [rsp + RW_color], eax
    mov dword ptr [rsp + RW_draw], 0
    mov qword ptr [rsp + RW_out], 0
    mov qword ptr [rsp + RW_mute], -1
    xor eax, eax                # the lines laid out: up to the clip and one
    mov ecx, [rsp + RW_SIZE + 16]
    test ecx, ecx
    jz 1f
    mov eax, ecx
    xor edx, edx
    div ebx
    add eax, 2
1:  mov [rsp + RW_max], eax
    cmp dword ptr [rip + lr_mode], LM_DUMP
    jne 2f
    lea rdi, [rip + ys]
    call sb_clear
    lea rax, [rip + ys]
    mov [rsp + RW_out], rax
    mov qword ptr [rsp + RW_mute], -1
2:  lea rdi, [rsp]
    call rw_wrap
    imul eax, ebx               # all its lines
    mov r12d, eax
    mov r13d, eax               # as tall as shown
    mov ecx, [rsp + RW_SIZE + 16]
    test ecx, ecx
    jz 3f
    cmp r13d, ecx
    jbe 3f
    mov r13d, ecx
3:  cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 5f
    mov edi, [rsp + RW_x]       # drawn, clipped
    mov esi, [rsp + RW_y]
    mov edx, [rsp + RW_w]
    mov ecx, r13d
    call gfx_clip_push
    mov dword ptr [rsp + RW_draw], 1
    mov qword ptr [rsp + RW_out], 0
    mov qword ptr [rsp + RW_mute], -1
    mov eax, [rip + g_cv + CV_cy0]
    mov [rsp + RW_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rsp + RW_bot], eax
    mov edi, [rsp + RW_SIZE]    # task 10: IN and OUT are selected by the pointer, banded under the text
    cmp edi, PART_IN            #   (agentsel.s): a row's own call's, not a child's
    je 31f
    cmp edi, PART_OUT
    jne 32f
31: call agents_viewed
    test rax, rax
    jz 32f
    mov rdi, rax
    mov rsi, [rip + lr_row]
    cmp rsi, [rdi + AS_msgs + VEC_len]
    jae 32f
    call row_of
    mov rcx, [rip + lr_at]
    cmp [rax + AM_x], rcx
    jne 32f
    mov edi, [rsp + RW_SIZE]
    call part_id
    mov ecx, eax
    lea rdi, [rsp]
    mov rsi, [rip + lr_row]
    mov edx, [rsp + RW_SIZE]
    mov r8d, r13d
    call agsel_plain
32: lea rdi, [rsp]
    call rw_wrap
    call gfx_clip_pop
    cmp r12d, r13d
    jbe 6f
    mov edi, [rsp + RW_x]       # cut: a fade over the last MI_10
    mov esi, [rsp + RW_y]
    add esi, r13d
    PM ecx, MI_10
    sub esi, ecx
    mov edx, [rsp + RW_w]
    call fade
    jmp 6f
5:  cmp dword ptr [rip + lr_mode], LM_DUMP
    jne 51f
    xor r14d, r14d              # written out: "KIND N TEXT", a line shown each
    mov r15, [rip + ys + SB_ptr]
52: mov eax, r14d
    imul eax, ebx
    cmp eax, r13d
    jae 6f
    test r15, r15
    jz 6f
    mov rax, [rip + ys + SB_ptr]
    add rax, [rip + ys + SB_len]
    cmp r15, rax
    jae 6f
    mov rdi, r15                # its end
    mov rsi, rax
    sub rsi, r15
    mov edx, 10
    call mem_chr_n
    mov [rsp + RW_SIZE + 40], rax
    mov rdi, [rip + lr_out]
    mov rsi, [rsp + RW_SIZE + 32]
    call sb_push_cstr
    mov rdi, [rip + lr_out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, [rip + lr_out]
    mov esi, r14d
    call sb_push_u64
    mov rdi, [rip + lr_out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, [rip + lr_out]
    mov rsi, r15
    mov rdx, [rsp + RW_SIZE + 40]
    sub rdx, r15
    call sb_push
    mov rdi, [rip + lr_out]
    mov esi, 10
    call sb_push_byte
    mov r15, [rsp + RW_SIZE + 40]
    inc r15
    inc r14d
    jmp 52b
51: mov rax, [rip + sec_ptr]    # the fit: its box
    mov [rip + ln_ptr], rax
    mov rax, [rip + sec_len]
    mov [rip + ln_len], rax
    mov rdi, [rsp + RW_SIZE + 32]
    mov esi, [rsp + RW_x]
    mov edx, [rsp + RW_y]
    mov ecx, [rsp + RW_w]
    mov r8d, r13d
    xor r9d, r9d
    call lay_line
6:  mov r14d, r13d              # a button when it is long
    cmp dword ptr [rsp + RW_SIZE + 24], 0
    je 7f
    mov eax, [rip + g_pmt + 4*MI_16]
    cmp r14d, eax
    cmovl r14d, eax
    mov edi, [rsp + RW_SIZE]
    mov esi, [rsp + RW_x]
    mov edx, [rsp + RW_y]
    mov ecx, [rsp + RW_w]
    mov r8d, r14d
    call lay_btn
7:  cmp r14d, ebx
    cmovl r14d, ebx
    mov eax, r14d
    EPILOGUE

# mem_chr_n(ptr, len, byte) -> rax the address of the byte, or ptr + len
mem_chr_n:
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 2f
    cmp byte ptr [rdi + rcx], dl
    je 2f
    inc rcx
    jmp 1b
2:  lea rax, [rdi + rcx]
    ret

# body_lay(x, y, w) -> eax the body's height (lr_at's IN and OUT), in lr_mode
body_lay:
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov r15, [rip + lr_at]
    call agrow_code_face
    mov rbx, rax
    mov rdi, rbx                # the labels' column
    lea rsi, [rip + .Lout]
    call text_w
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + 12], eax
    mov dword ptr [rsp + 36], 0 # narrow: no labels' column, a command's Copy on a line of its own
    mov ecx, [rsp + 8]
    sub ecx, eax
    sub ecx, [rip + g_pmt + 4*MI_6]
    sub ecx, [rip + g_pmt + 4*MI_6]
    sub ecx, [rip + g_pmt + 4*MI_20]
    sub ecx, [rip + g_pmt + 4*MI_4]
    cmp ecx, [rip + g_pmt + 4*MI_48]
    jge 0f
    mov dword ptr [rsp + 12], 0
    mov dword ptr [rsp + 36], 1
0:
    mov eax, [rsp]
    add eax, [rip + g_pmt + 4*MI_6]
    mov [rsp + 16], eax         # the labels' x
    add eax, [rsp + 12]
    mov [rsp + 20], eax         # the texts' x
    mov eax, [rsp + 4]
    add eax, [rip + g_pmt + 4*MI_6]
    mov r13d, eax               # sy
    cmp qword ptr [r15 + AT_in + SB_len], 0
    je .Lbl_out
    test dword ptr [r15 + AT_flags], ATF_SHELL
    jz 0f
    cmp dword ptr [rsp + 36], 0
    je 0f
    call copy_btn               # narrow: the Copy above the command
    add r13d, [rip + g_pmt + 4*MI_20]
    add r13d, [rip + g_pmt + 4*MI_4]
0:  mov eax, [rsp + 8]          # IN
    sub eax, [rsp + 12]
    sub eax, [rip + g_pmt + 4*MI_6]
    sub eax, [rip + g_pmt + 4*MI_6]
    test dword ptr [r15 + AT_flags], ATF_SHELL
    jz 1f
    cmp dword ptr [rsp + 36], 0
    jne 1f
    sub eax, [rip + g_pmt + 4*MI_20]
    sub eax, [rip + g_pmt + 4*MI_4]
1:  cmp eax, 1
    jge 2f
    mov eax, 1
2:  mov r12d, eax
    mov rax, [r15 + AT_in + SB_ptr]
    mov [rip + sec_ptr], rax
    mov rax, [r15 + AT_in + SB_len]
    mov [rip + sec_len], rax
    call clip_h
    mov r8d, eax
    mov edi, PART_IN
    mov esi, [rsp + 20]
    mov edx, r13d
    mov ecx, r12d
    COLOR r9d, T_FG
    mov eax, [r15 + AT_big]
    and eax, 1
    lea r10, [rip + .Lk_in]
    push r10
    push rax
    call section
    add rsp, 16
    mov r14d, eax
    cmp dword ptr [rsp + 12], 0
    je 21f
    mov rdi, rbx                # its label
    mov esi, [rsp + 16]
    mov edx, r13d
    mov ecx, [rbx + FACE_lineh]
    lea r8, [rip + .Lin]
    mov r9d, 2
    COLOR eax, T_MUTED
    mov r10d, [rsp + 12]
    push r10
    push rax
    call fit_text
    add rsp, 16
21: test dword ptr [r15 + AT_flags], ATF_SHELL
    jz 3f
    cmp dword ptr [rsp + 36], 0
    jne 3f
    mov eax, [rsp]              # the command's Copy
    add eax, [rsp + 8]
    sub eax, [rip + g_pmt + 4*MI_6]
    sub eax, [rip + g_pmt + 4*MI_20]
    mov [rsp + 24], eax
    mov edi, PART_COPY
    mov esi, eax
    mov edx, r13d
    PM ecx, MI_20
    mov r8d, ecx
    call lay_btn
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 31f
    mov edi, IC_COPY
    mov esi, [rsp + 24]
    add esi, [rip + g_pmt + 4*MI_2]
    mov edx, r13d
    add edx, [rip + g_pmt + 4*MI_2]
    PM ecx, MI_16
    COLOR r8d, T_MUTED
    call icon_draw
31: mov eax, [rip + g_pmt + 4*MI_20]
    cmp r14d, eax
    cmovl r14d, eax
3:  add r13d, r14d
    add r13d, [rip + g_pmt + 4*MI_4]
.Lbl_out:
    mov rdi, r15
    call out_hidden
    test eax, eax
    jnz .Lbl_end
    cmp qword ptr [r15 + AT_out + SB_len], 0
    je .Lbl_end
    mov eax, [rsp + 8]          # OUT
    sub eax, [rsp + 12]
    sub eax, [rip + g_pmt + 4*MI_6]
    sub eax, [rip + g_pmt + 4*MI_6]
    cmp eax, 1
    jge 4f
    mov eax, 1
4:  mov r12d, eax
    mov rax, [r15 + AT_out + SB_ptr]
    mov [rip + sec_ptr], rax
    mov rax, [r15 + AT_out + SB_len]
    mov [rip + sec_len], rax
    call clip_h
    mov [rsp + 28], eax         # the clip
    COLOR eax, T_FG
    mov [rsp + 32], eax
    cmp dword ptr [r15 + AT_state], ATS_FAILED
    jne 5f
    COLOR eax, T_ERROR          # an error: red, cut at 2000 characters, clipped only when it is a button
    mov [rsp + 32], eax
    mov rdi, [r15 + AT_out + SB_ptr]
    mov rsi, [r15 + AT_out + SB_len]
    call err_text
    mov dword ptr [rsp + 28], 0
    test dword ptr [r15 + AT_big], 2
    jz 5f
    mov eax, [rbx + FACE_lineh]
    imul eax, eax, ERR_LINES
    mov [rsp + 28], eax
5:  mov edi, PART_OUT
    mov esi, [rsp + 20]
    mov edx, r13d
    mov ecx, r12d
    mov r8d, [rsp + 28]
    mov r9d, [rsp + 32]
    mov eax, [r15 + AT_big]
    shr eax, 1
    and eax, 1
    lea r10, [rip + .Lk_out]
    push r10
    push rax
    call section
    add rsp, 16
    mov r14d, eax
    cmp dword ptr [rsp + 12], 0
    je 51f
    mov rdi, rbx
    mov esi, [rsp + 16]
    mov edx, r13d
    mov ecx, [rbx + FACE_lineh]
    lea r8, [rip + .Lout]
    mov r9d, 3
    COLOR eax, T_MUTED
    mov r10d, [rsp + 12]
    push r10
    push rax
    call fit_text
    add rsp, 16
51: add r13d, r14d
    add r13d, [rip + g_pmt + 4*MI_4]
.Lbl_end:
    sub r13d, [rip + g_pmt + 4*MI_4]
    add r13d, [rip + g_pmt + 4*MI_6]
    mov eax, r13d
    sub eax, [rsp + 4]
    EPILOGUE

# copy_btn() using body_lay's frame (its x and w: [rbp + 16], [rbp + 24] here) and r13d: the command's Copy at
#   the body's right, at that line
copy_btn:
    PROLOGUE 16
    mov eax, [rbp + 16]         # the caller's x
    add eax, [rbp + 24]         # and w
    sub eax, [rip + g_pmt + 4*MI_6]
    sub eax, [rip + g_pmt + 4*MI_20]
    mov [rsp], eax
    mov edi, PART_COPY
    mov esi, eax
    mov edx, r13d
    PM ecx, MI_20
    mov r8d, ecx
    call lay_btn
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 9f
    mov edi, IC_COPY
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_2]
    mov edx, r13d
    add edx, [rip + g_pmt + 4*MI_2]
    PM ecx, MI_16
    COLOR r8d, T_MUTED
    call icon_draw
9:  EPILOGUE

# err_text(ptr, len): an error's text as the row shows it in sec_ptr, sec_len: whole up to 2000 characters,
#   else its first 2000 and "…" (in xs)
err_text:
    PROLOGUE
    mov [rip + sec_ptr], rdi
    mov [rip + sec_len], rsi
    mov rbx, rdi
    mov r12, rsi
    xor ecx, ecx                # the 2000th character's end
    xor edx, edx
1:  cmp rcx, r12
    jae 9f
    movzx eax, byte ptr [rbx + rcx]
    and eax, 0xc0
    cmp eax, 0x80
    je 2f
    cmp edx, ERR_CHARS
    je 3f
    inc edx
2:  inc rcx
    jmp 1b
3:  mov r13, rcx
    lea rdi, [rip + xs]
    call sb_clear
    lea rdi, [rip + xs]
    mov rsi, rbx
    mov rdx, r13
    call sb_push
    lea rdi, [rip + xs]
    lea rsi, [rip + .Lellipsis]
    call sb_push_cstr
    mov rax, [rip + xs + SB_ptr]
    mov [rip + sec_ptr], rax
    mov rax, [rip + xs + SB_len]
    mov [rip + sec_len], rax
9:  EPILOGUE

# tr_lay(AS*, row, x, y, w) -> eax the call's row's height, laid out in lr_mode (its slot in lr_slot): its
#   call's unit, the calls under it in theirs (unit_lay)
tr_lay:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    call row_of
    mov rsi, [rax + AM_x]
    mov [rip + lr_row], r12
    mov [rip + lr_x], r13d
    mov [rip + lr_y], r14d
    mov dword ptr [rip + lr_key], 0
    mov rdi, rbx
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r15d
    call unit_lay
    EPILOGUE

# unit_lay(AS*, AT*, x, y, w) -> eax the height of a call's unit laid out in lr_mode (lr_row its row, lr_slot
#   its slot): its header, description and note lines, body, diff or file, todo list, the status of the agent's
#   task it runs and Stop, Run in background, its children's line and, open, its children's units (task 11)
unit_lay:
    PROLOGUE 64
    mov rbx, rdi
    mov r15, rsi
    mov r12, [rip + lr_row]
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 8], r8d
    mov [rip + lr_at], r15
    mov [rip + lr_w], r8d
    mov [rip + lr_ux], edx
    xor eax, eax
    test dword ptr [r15 + AT_flags], ATF_HIDDEN
    jnz 9f
    mov r13d, [rsp + 4]         # cy
    add r13d, [rip + g_pmt + 4*MI_4]
    call head_h                 # the header line
    sub eax, [rip + g_pmt + 4*MI_4]
    mov [rsp + 12], eax
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 1f
    cmp dword ptr [r15 + AT_state], ATS_RUNNING
    jne 87f
    mov rdi, rbx                # a running call's dot blinks (agentspin.s's tick) where rhun drives the turn
    call agspin_blink
    test eax, eax
    jz 1f
87: mov rdi, rbx
    mov rsi, r15
    call state_color
    mov ecx, eax
    mov edi, [rsp]
    mov esi, r13d
    mov edx, [rsp + 12]
    call row_dot
1:  mov r14d, [rsp]             # nx
    mov rsi, [r15 + AT_name]
    test rsi, rsi
    jz 2f
    mov rdi, [rip + ag_fui]     # the name, bold
    call text_w
    inc eax
    cmp eax, [rsp + 8]
    jle 11f
    mov eax, [rsp + 8]
11: mov [rsp + 16], eax
    mov rdi, [r15 + AT_name]
    call strlen
    mov [rip + ln_len], rax
    mov rax, [r15 + AT_name]
    mov [rip + ln_ptr], rax
    mov ecx, 2
12: push rcx
    push rcx
    mov rdi, [rip + ag_fui]
    mov esi, r14d
    mov edx, r13d
    mov ecx, [rsp + 16 + 12]
    mov r8, [rip + ln_ptr]
    mov r9, [rip + ln_len]
    COLOR eax, T_FG
    mov r10d, [rsp + 16 + 16]
    push r10
    push rax
    call fit_text
    add rsp, 16
    pop rcx
    pop rcx
    inc r14d                    # again a pixel to the right
    dec ecx
    jnz 12b
    mov r14d, [rsp]
    lea rdi, [rip + .Lk_header]
    mov esi, r14d
    mov edx, r13d
    mov ecx, [rsp + 16]
    mov r8d, [rsp + 12]
    xor r9d, r9d
    call lay_line
    add r14d, [rsp + 16]
    add r14d, [rip + g_pmt + 4*MI_6]
2:  mov eax, [rsp]              # the room left
    add eax, [rsp + 8]
    sub eax, r14d
    jns 21f
    xor eax, eax
21: mov [rsp + 20], eax
    mov dword ptr [rsp + 24], 0 # the tail's width
    mov rsi, [r15 + AT_tail]
    test rsi, rsi
    jz 3f
    mov rdi, [rip + ag_fui]
    call text_w
    mov ecx, [rsp + 20]
    shr ecx, 1
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 24], eax
3:  mov rsi, [r15 + AT_second]  # the second text, a link when it has one
    test rsi, rsi
    jz 4f
    mov rdi, [rip + ag_fui]
    call text_w
    mov ecx, [rsp + 20]
    cmp dword ptr [rsp + 24], 0
    je 31f
    sub ecx, [rsp + 24]
    sub ecx, [rip + g_pmt + 4*MI_6]
31: test ecx, ecx
    jns 32f
    xor ecx, ecx
32: cmp eax, ecx
    cmovg eax, ecx
    test eax, eax               # no room left for it (a long name in a narrow row): none
    jz 4f
    mov [rsp + 28], eax
    mov rdi, [r15 + AT_second]
    call strlen
    mov [rip + ln_len], rax
    mov rax, [r15 + AT_second]
    mov [rip + ln_ptr], rax
    COLOR eax, T_FG
    cmp qword ptr [r15 + AT_link], 0
    je 33f
    COLOR eax, T_ACCENT
33: mov rdi, [rip + ag_fui]
    mov esi, r14d
    mov edx, r13d
    mov ecx, [rsp + 12]
    mov r8, [rip + ln_ptr]
    mov r9, [rip + ln_len]
    mov r10d, [rsp + 28]
    inc r10d
    push r10
    push rax
    call fit_text
    add rsp, 16
    cmp qword ptr [r15 + AT_link], 0
    je 34f
    lea rdi, [rip + .Lk_link]   # the link: "link X,Y,W,H T ID", and its button
    mov esi, r14d
    mov edx, r13d
    mov ecx, [rsp + 28]
    mov r8d, [rsp + 12]
    mov r9d, 2
    call lay_line
    mov edi, PART_LINK
    mov esi, r14d
    mov edx, r13d
    mov ecx, [rsp + 28]
    mov r8d, [rsp + 12]
    call lay_btn
    jmp 35f
34: lea rdi, [rip + .Lk_second]
    mov esi, r14d
    mov edx, r13d
    mov ecx, [rsp + 28]
    mov r8d, [rsp + 12]
    xor r9d, r9d
    call lay_line
35: add r14d, [rsp + 28]
    add r14d, [rip + g_pmt + 4*MI_6]
4:  mov rsi, [r15 + AT_tail]    # the tail, muted
    test rsi, rsi
    jz 5f
    mov eax, [rsp]
    add eax, [rsp + 8]
    sub eax, r14d
    jle 5f
    cmp eax, [rsp + 24]
    jle 41f
    mov eax, [rsp + 24]
41: mov [rsp + 28], eax
    mov rdi, rsi
    call strlen
    mov [rip + ln_len], rax
    mov rax, [r15 + AT_tail]
    mov [rip + ln_ptr], rax
    mov rdi, [rip + ag_fui]
    mov esi, r14d
    mov edx, r13d
    mov ecx, [rsp + 12]
    mov r8, [rip + ln_ptr]
    mov r9, [rip + ln_len]
    COLOR eax, T_MUTED
    mov r10d, [rsp + 28]
    inc r10d
    push r10
    push rax
    call fit_text
    add rsp, 16
    lea rdi, [rip + .Lk_tail]
    mov esi, r14d
    mov edx, r13d
    mov ecx, [rsp + 28]
    mov r8d, [rsp + 12]
    xor r9d, r9d
    call lay_line
5:  add r13d, [rsp + 12]
    mov rax, [rip + ag_fsmall]  # the description and note lines
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_2]
    mov [rsp + 32], eax
    mov rsi, [r15 + AT_desc]
    test rsi, rsi
    jz 6f
    mov [rip + lr_cy], r13d
    lea rdi, [rip + .Lk_desc]
    mov edx, [rsp + 32]
    xor ecx, ecx
    call small_line
    add r13d, [rsp + 32]
6:  mov rsi, [r15 + AT_note]
    test rsi, rsi
    jz 7f
    mov ecx, [rsp + 32]         # a button when it has a tab of its own: its hit area MI_16 at least
    xor eax, eax
    cmp qword ptr [r15 + AT_title], 0
    je 61f
    cmp qword ptr [r15 + AT_out + SB_len], 0
    je 61f
    mov eax, 1
    mov edx, [rip + g_pmt + 4*MI_16]
    cmp ecx, edx
    cmovl ecx, edx
61: mov [rsp + 36], ecx
    mov [rsp + 40], eax
    mov [rip + lr_cy], r13d
    lea rdi, [rip + .Lk_note]
    mov rsi, [r15 + AT_note]
    mov edx, ecx
    mov ecx, eax
    call small_line
    add r13d, [rsp + 36]
7:  cmp qword ptr [r15 + AT_in + SB_len], 0     # the body
    jne 71f
    cmp qword ptr [r15 + AT_out + SB_len], 0
    je 8f
    mov rdi, r15
    call out_hidden
    test eax, eax
    jnz 8f
71: add r13d, [rip + g_pmt + 4*MI_6]
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 72f
    mov dword ptr [rip + lr_mode], LM_MEASURE   # its box first, then its parts
    mov edi, [rsp]
    mov esi, r13d
    mov edx, [rsp + 8]
    call body_lay
    mov dword ptr [rip + lr_mode], LM_DRAW
    mov ecx, eax
    mov edi, [rsp]
    mov esi, r13d
    mov edx, [rsp + 8]
    PM r8d, MI_4
    COLOR r9d, T_BG
    call gfx_round_rect
72: mov edi, [rsp]
    mov esi, r13d
    mov edx, [rsp + 8]
    call body_lay
    add r13d, eax
8:  test dword ptr [r15 + AT_flags], ATF_DIFF | ATF_PRE     # the diff or the file's text (agentdiff.s)
    jz 82f
    mov rdi, r15
    mov esi, [rsp + 8]
    call agdiff_h
    test eax, eax
    jz 82f
    mov [rsp + 44], eax
    add r13d, [rip + g_pmt + 4*MI_6]
    cmp dword ptr [rip + lr_mode], LM_DRAW
    je 85f
    cmp dword ptr [rip + lr_mode], LM_DUMP  # written out: its button, its box and rows (agdiff_lines)
    jb 81f
    mov edi, PART_DIFF
    test dword ptr [r15 + AT_flags], ATF_DIFF
    jnz 86f
    mov edi, PART_PRE
86: mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 44]
    call lay_btn
    xor r9d, r9d
    cmp dword ptr [rip + lr_mode], LM_FIT
    sete r9b
    mov rdi, [rip + lr_out]
    mov rsi, r15
    mov edx, [rsp]
    mov ecx, r13d
    mov r8d, [rsp + 8]
    call agdiff_lines
    jmp 81f
85: mov edi, PART_DIFF
    test dword ptr [r15 + AT_flags], ATF_DIFF
    jnz 83f
    mov edi, PART_PRE
83: call part_id
    mov r8d, eax
    mov rdi, r15
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 8]
    call agdiff_draw
    test eax, eax
    jz 81f
    call agsel_moved            # task 10: a drag that selected in it is no click (agentsel.s)
    test eax, eax
    jnz 81f
    mov rdi, r12
    mov rsi, r15
    mov edx, PART_DIFF
    test dword ptr [r15 + AT_flags], ATF_DIFF
    jnz 84f
    mov edx, PART_PRE
84: call pend_set
81: add r13d, [rsp + 44]
82: mov edi, [rsp]              # the todo list
    mov esi, r13d
    mov edx, [rsp + 8]
    call todo_lay
    add r13d, eax
    mov rdi, rbx                # task 11: the agent's status, Run in background, its children
    mov rsi, r15
    mov edx, [rsp]
    mov ecx, r13d
    mov r8d, [rsp + 8]
    call kids_lay
    add r13d, eax
    add r13d, [rip + g_pmt + 4*MI_4]
    mov eax, r13d
    sub eax, [rsp + 4]
9:  EPILOGUE

# ---------------- task 11: an agent's status, Run in background, the calls under a call ----------------

# kl_h() -> eax a line of the small face under a call (status, Run in background, its children's count): its
#   line and MI_4, at least MI_16 (a button's hit area)
kl_h:
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_4]
    mov ecx, [rip + g_pmt + 4*MI_16]
    cmp eax, ecx
    cmovl eax, ecx
    ret

# kids_shown(AT*) -> eax 1 when the call has a line for the calls under it: one that may get them (an agent's),
#   one that has them, or one whose result counted them
kids_shown:
    xor eax, eax
    test dword ptr [rdi + AT_flags], ATF_HIDDEN
    jnz 9f
    mov eax, 1
    test dword ptr [rdi + AT_flags], ATF_PARENT
    jnz 9f
    cmp qword ptr [rdi + AT_kids + VEC_len], 0
    jne 9f
    cmp dword ptr [rdi + AT_nkids], 0
    jge 9f
    xor eax, eax
9:  ret

# FN agrow_canbg(AS*, AT*) -> eax 1 when the call can be sent to the background now: it may be (ATF_CANBG: a
#   foreground shell task runs it), it runs, and rhun drives its conversation (the extension's LMt, @5556700)
FN agrow_canbg
    PROLOGUE
    xor eax, eax
    test rsi, rsi
    jz 9f
    test dword ptr [rsi + AT_flags], ATF_CANBG
    jz 9f
    test dword ptr [rsi + AT_flags], ATF_HIDDEN
    jnz 9f
    cmp dword ptr [rsi + AT_state], ATS_RUNNING
    jne 9f
    call agtask_driven
9:  EPILOGUE

# kids_text(AS*, AT*): ks, the line of the calls under it: "Running NAME…" while its last one runs (where rhun
#   drives it), "N tool call(s)" and " · M failed" (" · " between them), or "Tool calls" with no count and
#   none kept (a background agent read from a file: its file has them)
kids_text:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + ks]
    call sb_clear
    xor r13d, r13d              # something before the count
    mov rax, [r12 + AT_kids + VEC_len]
    test rax, rax
    jz 2f
    mov rcx, [r12 + AT_kids + VEC_ptr]
    mov r14, [rcx + rax*8 - 8]
    cmp dword ptr [r14 + AT_state], ATS_RUNNING
    jne 2f
    mov rdi, rbx
    call agents_session_live
    test eax, eax
    jz 2f
    lea rdi, [rip + ks]
    lea rsi, [rip + .Lk11_running]
    call sb_push_cstr
    mov rsi, [r14 + AT_name]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lk11_tool]
1:  lea rdi, [rip + ks]
    call sb_push_cstr
    lea rdi, [rip + ks]
    lea rsi, [rip + .Lellipsis]
    call sb_push_cstr
    mov r13d, 1
2:  mov r14d, [r12 + AT_nkids]
    test r14d, r14d
    jns 3f
    mov r14, [r12 + AT_kids + VEC_len]
    test r14, r14
    jnz 3f
    test r13d, r13d
    jnz 9f
    lea rdi, [rip + ks]
    lea rsi, [rip + .Lk11_tool_calls]
    call sb_push_cstr
    EPILOGUE
3:  test r13d, r13d
    jz 31f
    lea rdi, [rip + ks]
    lea rsi, [rip + .Lthink_sep]
    call sb_push_cstr
31: lea rdi, [rip + ks]
    mov esi, r14d
    call sb_push_u64
    lea rdi, [rip + ks]
    lea rsi, [rip + .Lk11_tool_call]
    call sb_push_cstr
    cmp r14d, 1
    je 4f
    lea rdi, [rip + ks]
    mov esi, 's'
    call sb_push_byte
4:  cmp dword ptr [r12 + AT_nfail], 0
    jle 9f
    lea rdi, [rip + ks]
    lea rsi, [rip + .Lthink_sep]
    call sb_push_cstr
    lea rdi, [rip + ks]
    mov esi, [r12 + AT_nfail]
    call sb_push_u64
    lea rdi, [rip + ks]
    lea rsi, [rip + .Lk11_failed]
    call sb_push_cstr
9:  EPILOGUE

# kids_lay(AS*, AT*, x, y, w) -> eax the height of the lines under a call's body, laid out in lr_mode (lr_at
#   the call): the status of the agent's task it runs ("Working in the background…", agtask_status) with
#   "Stop" at its right while it works; "Run in background" while it can go there; the line of the calls under
#   it (a button: open, the calls in their own units, indented, kids_units). Frame: [0] x, [4] y, [8] w,
#   [12] a line, [16] the status's text, [24] Stop asked, [28] Stop's width, [32] the room for a text
kids_lay:
    PROLOGUE 48
    mov rbx, rdi
    mov r15, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 8], r8d
    mov r13d, ecx               # cy
    call kl_h
    mov [rsp + 12], eax
    mov rdi, rbx                # the agent's task: its status, Stop
    mov rsi, [r15 + AT_id]
    call agtask_status
    test rax, rax
    jz 2f
    mov [rsp + 16], rax
    mov [rsp + 24], ecx
    mov dword ptr [rsp + 28], 0
    mov eax, [rsp + 8]
    test ecx, ecx
    jz 1f
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lk11_stop]
    call text_w
    add eax, [rip + g_pmt + 4*MI_8]
    cmp eax, [rsp + 8]
    jle 11f
    mov eax, [rsp + 8]
11: mov [rsp + 28], eax
    mov eax, [rsp + 8]
    sub eax, [rsp + 28]
    sub eax, [rip + g_pmt + 4*MI_6]
    jns 1f
    xor eax, eax
1:  mov [rsp + 32], eax
    mov rdi, [rsp + 16]
    call strlen
    mov [rip + ln_len], rax
    mov rax, [rsp + 16]
    mov [rip + ln_ptr], rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 12]
    mov r8, [rip + ln_ptr]
    mov r9, [rip + ln_len]
    COLOR eax, T_MUTED
    mov r10d, [rsp + 32]
    inc r10d
    push r10
    push rax
    call fit_text
    add rsp, 16
    lea rdi, [rip + .Lk11_status]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 32]
    mov r8d, [rsp + 12]
    xor r9d, r9d
    call lay_line
    cmp dword ptr [rsp + 24], 0
    je 12f
    mov r14d, [rsp]             # Stop, at its right end
    add r14d, [rsp + 8]
    sub r14d, [rsp + 28]
    lea rax, [rip + .Lk11_stop]
    mov [rip + ln_ptr], rax
    mov qword ptr [rip + ln_len], 4
    mov rdi, [rip + ag_fsmall]
    mov esi, r14d
    add esi, [rip + g_pmt + 4*MI_4]
    mov edx, r13d
    mov ecx, [rsp + 12]
    mov r8, [rip + ln_ptr]
    mov r9, [rip + ln_len]
    COLOR eax, T_ACCENT
    mov r10d, [rsp + 28]
    push r10
    push rax
    call fit_text
    add rsp, 16
    mov edi, PART_STOP
    mov esi, r14d
    mov edx, r13d
    mov ecx, [rsp + 28]
    mov r8d, [rsp + 12]
    call lay_btn
12: add r13d, [rsp + 12]
2:  mov rdi, rbx                # Run in background
    mov rsi, r15
    call agrow_canbg
    test eax, eax
    jz 3f
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lk11_run_bg]
    call text_w
    add eax, [rip + g_pmt + 4*MI_8]
    cmp eax, [rsp + 8]
    jle 21f
    mov eax, [rsp + 8]
21: mov [rsp + 28], eax
    lea rdi, [rip + .Lk11_run_bg]
    mov [rip + ln_ptr], rdi
    call strlen
    mov [rip + ln_len], rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_4]
    mov edx, r13d
    mov ecx, [rsp + 12]
    mov r8, [rip + ln_ptr]
    mov r9, [rip + ln_len]
    COLOR eax, T_ACCENT
    mov r10d, [rsp + 28]
    sub r10d, [rip + g_pmt + 4*MI_4]
    push r10
    push rax
    call fit_text
    add rsp, 16
    lea rdi, [rip + .Lk11_bgline]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 28]
    mov r8d, [rsp + 12]
    xor r9d, r9d
    call lay_line
    mov edi, PART_BG
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 28]
    mov r8d, [rsp + 12]
    call lay_btn
    add r13d, [rsp + 12]
3:  mov rdi, r15                # the calls under it: their line
    call kids_shown
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov rsi, r15
    call kids_text
    PM eax, MI_12               # the chevron's room
    mov ecx, [rsp + 8]
    sub ecx, eax
    sub ecx, [rip + g_pmt + 4*MI_4]
    jns 31f
    xor ecx, ecx
31: mov [rsp + 32], ecx
    mov rax, [rip + ks + SB_ptr]
    mov [rip + ln_ptr], rax
    mov rax, [rip + ks + SB_len]
    mov [rip + ln_len], rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 12]
    mov r8, [rip + ln_ptr]
    mov r9, [rip + ln_len]
    COLOR eax, T_MUTED
    mov r10d, [rsp + 32]
    inc r10d
    push r10
    push rax
    call fit_text
    add rsp, 16
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 32f
    mov edi, IC_CHEV_D          # the chevron
    test dword ptr [r15 + AT_flags], ATF_KIDS
    jz 33f
    mov edi, IC_CHEV_UP
33: PM ecx, MI_12
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, ecx
    mov edx, [rsp + 12]
    sub edx, ecx
    sar edx, 1
    add edx, r13d
    COLOR r8d, T_MUTED
    call icon_draw
32: lea rdi, [rip + .Lk11_kids]
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 32]
    mov r8d, [rsp + 12]
    xor r9d, r9d
    call lay_line
    mov edi, PART_KIDS
    mov esi, [rsp]
    mov edx, r13d
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call lay_btn
    add r13d, [rsp + 12]
    test dword ptr [r15 + AT_flags], ATF_KIDS   # open: the calls themselves
    jz 8f
    cmp qword ptr [r15 + AT_kids + VEC_len], 0
    je 8f
    mov rdi, rbx
    mov rsi, r15
    mov edx, [rsp]
    mov ecx, r13d
    mov r8d, [rsp + 8]
    call kids_units
    add r13d, eax
8:  mov [rip + lr_at], r15      # (the units under it laid out: this one's again)
    mov eax, [rsp + 8]
    mov [rip + lr_w], eax
    mov eax, [rsp]
    mov [rip + lr_ux], eax
    mov eax, r13d
    sub eax, [rsp + 4]
    EPILOGUE

# kid_key(w) -> eax what a child's cached height (AT_h) is for: its width, the panel's text size, the code's line
kid_key:
    PROLOGUE
    mov ebx, edi
    call agrow_code_face
    mov ecx, [rax + FACE_lineh]
    shl ecx, 24
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_px]
    shl eax, 16
    add eax, ebx
    xor eax, ecx
    EPILOGUE

# kids_units(AS*, AT*, x, y, w) -> eax the height of the calls under a call, each its own unit indented MI_16
#   with a 1 px T_BORDER rule at its left, laid out in lr_mode. A unit's height is kept in its AT_h for a width
#   and text size (kid_key), so a frame lays out only the units inside the clip and adds the others' kept
#   heights (at most AT_KIDS_MAX a call). Each unit has its own slot for its ids, by (row, its key: its place
#   under its parent's key). Written out (LM_DUMP) each unit's lines follow "kid N ID". Frame: [0] x, [4] y,
#   [8] w, [12] the units' x, [16] their w, [20] the parent's slot, [24] the parent's key, [28] the key, [32]
#   the key's height key, [40] the child
kids_units:
    PROLOGUE 48
    mov rbx, rdi
    mov r15, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 8], r8d
    mov eax, [rip + lr_slot]
    mov [rsp + 20], eax
    mov eax, [rip + lr_key]
    mov [rsp + 24], eax
    PM eax, MI_16               # indented, unless that leaves too little room
    mov ecx, [rsp + 8]
    sub ecx, eax
    PM edx, MI_64
    cmp ecx, edx
    jge 1f
    xor eax, eax
    mov ecx, [rsp + 8]
1:  add eax, [rsp]
    mov [rsp + 12], eax
    mov [rsp + 16], ecx
    mov edi, ecx
    call kid_key
    mov [rsp + 32], eax
    mov r13d, [rsp + 4]         # cy
    xor r14d, r14d
.Lku_next:
    cmp r14, [r15 + AT_kids + VEC_len]
    jae .Lku_done
    mov rax, [r15 + AT_kids + VEC_ptr]
    mov r12, [rax + r14*8]
    mov [rsp + 40], r12
    inc r14
    mov eax, [rsp + 24]         # its key
    imul eax, eax, 1009
    add eax, r14d
    xor edx, edx
    mov ecx, 0xfffe
    div ecx
    lea eax, [rdx + 1]
    mov [rsp + 28], eax
    mov eax, [r12 + AT_h]       # its height: kept, or measured now
    test eax, eax
    js 2f
    mov ecx, [rsp + 32]
    cmp [r12 + AT_w], ecx
    je 3f
2:  mov eax, [rip + lr_mode]
    push rax
    push rax
    mov dword ptr [rip + lr_mode], LM_MEASURE
    mov eax, [rsp + 16 + 28]
    mov [rip + lr_key], eax
    mov rdi, rbx
    mov rsi, r12
    mov edx, [rsp + 16 + 12]
    xor ecx, ecx
    mov r8d, [rsp + 16 + 16]
    call unit_lay
    mov r12, [rsp + 16 + 40]
    mov [r12 + AT_h], eax
    mov ecx, [rsp + 16 + 32]
    mov [r12 + AT_w], ecx
    pop rcx
    pop rcx
    mov [rip + lr_mode], ecx
3:  test eax, eax
    jz .Lku_next
    mov r12, rax                # its height
    mov ecx, [rip + lr_mode]
    cmp ecx, LM_MEASURE
    je .Lku_add
    cmp ecx, LM_DRAW
    jne 5f
    cmp r13d, [rip + g_cv + CV_cy1]   # drawn: only inside the clip
    jge .Lku_add
    lea eax, [r13 + r12]
    cmp eax, [rip + g_cv + CV_cy0]
    jle .Lku_add
    mov rdi, [rip + lr_row]
    mov esi, [rsp + 28]
    call agrow_slot
    mov [rip + lr_slot], eax
    mov edi, [rsp]              # its rule
    add edi, [rip + g_pmt + 4*MI_6]
    mov esi, r13d
    mov edx, 1
    mov ecx, r12d
    COLOR r8d, T_BORDER
    call gfx_fill
    jmp 6f
5:  cmp ecx, LM_DUMP
    jne 6f
    mov rdi, [rip + lr_row]
    mov esi, [rsp + 28]
    call slot_kid
    mov [rip + lr_slot], eax
    mov rdi, [rip + lr_out]     # "kid N ID"
    lea rsi, [rip + .Lk11_kid]
    call sb_push_cstr
    mov rdi, [rip + lr_out]
    mov rsi, r14
    call sb_push_u64
    mov rdi, [rip + lr_out]
    mov esi, ' '
    call sb_push_byte
    mov rax, [rsp + 40]
    mov rdi, [rip + lr_out]
    mov rsi, [rax + AT_id]
    call sb_push_cstr
    mov rdi, [rip + lr_out]
    mov esi, 10
    call sb_push_byte
6:  mov eax, [rsp + 28]
    mov [rip + lr_key], eax
    mov rdi, rbx
    mov rsi, [rsp + 40]
    mov edx, [rsp + 12]
    mov ecx, r13d
    mov r8d, [rsp + 16]
    call unit_lay
.Lku_add:
    add r13d, r12d
    jmp .Lku_next
.Lku_done:
    mov eax, [rsp + 20]
    mov [rip + lr_slot], eax
    mov eax, [rsp + 24]
    mov [rip + lr_key], eax
    mov eax, r13d
    sub eax, [rsp + 4]
    EPILOGUE

# slot_kid(row, key) -> eax the slot that unit had in the last frame, -1 (print-agent-row reads ids)
slot_kid:
    shl rdi, 16
    mov esi, esi
    lea rdi, [rdi + rsi + 1]
    lea r9, [rip + slot_key]
    lea r10, [rip + slot_ser]
    xor eax, eax
1:  cmp eax, SLOTS
    jae 8f
    cmp dword ptr [r10 + rax*4], 0
    je 2f
    cmp [r9 + rax*8], rdi
    je 9f
2:  inc eax
    jmp 1b
8:  mov eax, -1
9:  ret

# tree_find(AT*, id cstr) -> rax the call of that id among the calls under it (depth first), or 0
tree_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13, [rbx + AT_kids + VEC_len]
    jae 8f
    mov rax, [rbx + AT_kids + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    mov rdi, [r14 + AT_id]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 7f
    mov rdi, r14
    mov rsi, r12
    call tree_find
    test rax, rax
    jz 1b
    EPILOGUE
7:  mov rax, r14
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agrow_pend(row, AT*, part): a click on a part of that call (agentfold.s's Run in background on a fold's
#   line), followed after the frame
FN agrow_pend
    jmp pend_set

# FN agrow_text(ptr, len) -> rax an owned copy as a row shows a one-line part (cleaned, 400 bytes at most), or 0
FN agrow_text
    xor edx, edx
    jmp short_text

# FN agrow_kid_click(AS*, row, n, part) -> eax 1: as a click on that part of the n-th unit (from 1, depth
#   first) under the call of row (agent-kid-click)
FN agrow_kid_click
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    xor eax, eax
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call row_of
    mov rdi, [rax + AM_x]
    test rdi, rdi
    jz 8f
    mov [rip + kc_n], r13
    call kid_nth
    test rax, rax
    jz 8f
    mov rdi, r12
    mov rsi, rax
    mov edx, r14d
    call pend_set
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# kid_nth(AT*) -> rax the kc_n-th unit under it (depth first, counting down kc_n), or 0
kid_nth:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + AT_kids + VEC_len]
    jae 8f
    mov rax, [rbx + AT_kids + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    dec qword ptr [rip + kc_n]
    jz 7f
    mov rdi, r13
    call kid_nth
    test rax, rax
    jz 1b
    EPILOGUE
7:  mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# todo_lay(x, y, w) -> eax the height of lr_at's todo list (0 without items), laid out in lr_mode (DTt): a
#   line an item, a box of MI_14 (empty; a dash for the active item; a check for a done one, its text muted
#   and struck through), the text in the panel's face wrapped at the room left; MI_4 above and between
#   them. Written out: "todo [ ]|[-]|[x] X,Y,W,H TEXT" and "check X,Y,W,H" an item. Frame after the RW:
#   [0] x, [4] y, [8] w, [12] the box, [16] the texts' x, [20] their width, [24] a line, [28] cy, [32] the
#   box's y, [36] its state, [40] its lines, [48] its text
todo_lay:
    PROLOGUE RW_SIZE + 64
    mov [rsp + RW_SIZE], edi
    mov [rsp + RW_SIZE + 4], esi
    mov [rsp + RW_SIZE + 8], edx
    mov r15, [rip + lr_at]
    xor eax, eax
    cmp qword ptr [r15 + AT_items + VEC_len], 0
    je 9f
    mov eax, [rip + g_pmt + 4*MI_14]
    mov [rsp + RW_SIZE + 12], eax
    add eax, [rip + g_pmt + 4*MI_8]
    mov ecx, [rsp + RW_SIZE]
    add ecx, eax
    mov [rsp + RW_SIZE + 16], ecx
    mov ecx, edx
    sub ecx, eax
    cmp ecx, 1
    jge 1f
    mov ecx, 1
1:  mov [rsp + RW_SIZE + 20], ecx
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    mov [rsp + RW_SIZE + 24], eax
    mov eax, [rsp + RW_SIZE + 4]
    add eax, [rip + g_pmt + 4*MI_4]
    mov [rsp + RW_SIZE + 28], eax
    xor ebx, ebx
.Ltd_item:
    cmp rbx, [r15 + AT_items + VEC_len]
    jae .Ltd_end
    imul rax, rbx, ATI_SIZE
    add rax, [r15 + AT_items + VEC_ptr]
    mov ecx, [rax + ATI_state]
    cmp ecx, TODO_DONE
    jbe 2f
    xor ecx, ecx
2:  mov [rsp + RW_SIZE + 36], ecx
    mov rax, [rax + ATI_text]
    mov [rsp + RW_SIZE + 48], rax
    mov [rsp + RW_text], rax
    mov rdi, rax
    call strlen
    mov [rsp + RW_len], rax
    mov rax, [rip + ag_fui]     # its text: measured first
    mov [rsp + RW_face], rax
    mov eax, [rsp + RW_SIZE + 16]
    mov [rsp + RW_x], eax
    mov eax, [rsp + RW_SIZE + 28]
    mov [rsp + RW_y], eax
    mov eax, [rsp + RW_SIZE + 20]
    mov [rsp + RW_w], eax
    mov eax, [rsp + RW_SIZE + 24]
    mov [rsp + RW_lh], eax
    COLOR eax, T_FG
    cmp dword ptr [rsp + RW_SIZE + 36], TODO_DONE
    jne 3f
    COLOR eax, T_MUTED
3:  mov [rsp + RW_color], eax
    mov dword ptr [rsp + RW_draw], 0
    mov dword ptr [rsp + RW_max], 0
    mov qword ptr [rsp + RW_out], 0
    mov qword ptr [rsp + RW_mute], -1
    mov eax, [rip + g_cv + CV_cy0]
    mov [rsp + RW_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rsp + RW_bot], eax
    lea rdi, [rsp]
    call rw_wrap
    mov [rsp + RW_SIZE + 40], eax
    mov eax, [rsp + RW_SIZE + 24]   # the box: centred on the first line
    sub eax, [rsp + RW_SIZE + 12]
    sar eax, 1
    add eax, [rsp + RW_SIZE + 28]
    mov [rsp + RW_SIZE + 32], eax
    mov eax, [rip + lr_mode]
    cmp eax, LM_DRAW
    je .Ltd_draw
    cmp eax, LM_DUMP
    jb .Ltd_next
    mov rax, [rsp + RW_SIZE + 48]   # written out
    mov [rip + ln_ptr], rax
    mov rax, [rsp + RW_len]
    mov [rip + ln_len], rax
    mov eax, [rsp + RW_SIZE + 36]
    lea rcx, [rip + todo_kinds]
    mov rdi, [rcx + rax*8]
    mov esi, [rsp + RW_SIZE + 16]
    mov edx, [rsp + RW_SIZE + 28]
    mov ecx, [rsp + RW_SIZE + 20]
    mov r8d, [rsp + RW_SIZE + 40]
    imul r8d, [rsp + RW_SIZE + 24]
    xor r9d, r9d
    call lay_line
    mov qword ptr [rip + ln_len], 0
    lea rdi, [rip + .Lk_check]
    mov esi, [rsp + RW_SIZE]
    mov edx, [rsp + RW_SIZE + 32]
    mov ecx, [rsp + RW_SIZE + 12]
    mov r8d, ecx
    xor r9d, r9d
    call lay_line
    jmp .Ltd_next
.Ltd_draw:
    COLOR eax, T_BG             # the box (the extension's checkbox: a 1 px frame, 2 px corners)
    push rax
    push rax
    mov edi, [rsp + 16 + RW_SIZE]
    mov esi, [rsp + 16 + RW_SIZE + 32]
    mov edx, [rsp + 16 + RW_SIZE + 12]
    mov ecx, edx
    PM r8d, MI_2
    COLOR r9d, T_MUTED
    call gfx_frame
    add rsp, 16
    mov eax, [rsp + RW_SIZE + 36]
    cmp eax, TODO_DONE
    je 4f
    cmp eax, TODO_ACTIVE
    jne 5f
    mov eax, [rsp + RW_SIZE + 12]   # active: a dash across its middle
    mov ecx, eax
    shr ecx, 3
    cmp ecx, 1
    jge 31f
    mov ecx, 1
31: mov edi, eax
    shr edi, 2
    add edi, [rsp + RW_SIZE]
    mov esi, eax
    sub esi, ecx
    sar esi, 1
    add esi, [rsp + RW_SIZE + 32]
    mov edx, eax
    shr edx, 1
    COLOR r8d, T_FG
    call gfx_fill
    jmp 5f
4:  mov edi, IC_CHECK           # done: a check
    mov esi, [rsp + RW_SIZE]
    mov edx, [rsp + RW_SIZE + 32]
    mov ecx, [rsp + RW_SIZE + 12]
    COLOR r8d, T_MUTED
    call icon_draw
5:  mov dword ptr [rsp + RW_draw], 1    # its text, drawn (a done one's lines kept to strike them)
    cmp dword ptr [rsp + RW_SIZE + 36], TODO_DONE
    jne 51f
    lea rdi, [rip + ys]
    call sb_clear
    lea rax, [rip + ys]
    mov [rsp + RW_out], rax
    mov qword ptr [rsp + RW_mute], -1
51: lea rdi, [rsp]
    call rw_wrap
    cmp dword ptr [rsp + RW_SIZE + 36], TODO_DONE
    jne .Ltd_next
    mov r12, [rip + ys + SB_ptr]    # struck through: a line over each line's text
    mov r13, r12
    add r13, [rip + ys + SB_len]
    mov r14d, [rsp + RW_SIZE + 28]
6:  cmp r12, r13
    jae .Ltd_next
    mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    mov edx, 10
    call mem_chr_n
    mov [rsp + RW_SIZE + 56], rax
    mov rdi, [rip + ag_fui]
    mov rsi, r12
    mov rdx, rax
    sub rdx, r12
    call text_width
    mov edx, eax
    mov rax, [rip + ag_fui]
    mov esi, [rax + FACE_ascent]
    imul esi, esi, 2
    mov ecx, 3
    push rdx
    mov eax, esi
    xor edx, edx
    div ecx
    pop rdx
    lea esi, [r14 + rax]
    mov edi, [rsp + RW_SIZE + 16]
    mov rax, [rip + ag_fui]
    mov ecx, [rax + FACE_px]
    shr ecx, 4
    cmp ecx, 1
    jge 61f
    mov ecx, 1
61: COLOR r8d, T_MUTED
    call gfx_fill
    add r14d, [rsp + RW_SIZE + 24]
    mov r12, [rsp + RW_SIZE + 56]
    inc r12
    jmp 6b
.Ltd_next:
    mov eax, [rsp + RW_SIZE + 40]
    imul eax, [rsp + RW_SIZE + 24]
    cmp eax, [rsp + RW_SIZE + 12]
    jge 7f
    mov eax, [rsp + RW_SIZE + 12]
7:  add eax, [rip + g_pmt + 4*MI_4]
    add [rsp + RW_SIZE + 28], eax
    inc rbx
    jmp .Ltd_item
.Ltd_end:
    mov eax, [rsp + RW_SIZE + 28]
    sub eax, [rsp + RW_SIZE + 4]
    sub eax, [rip + g_pmt + 4*MI_4]     # the last gap: the row's own pad follows
9:  EPILOGUE

# FN agrow_todo_h(AT*, w) -> eax its todo list alone at width w (focus view's latest list, agentfold.s): the
#   list and MI_4 above and below it; 0 without items
FN agrow_todo_h
    PROLOGUE 16
    mov rax, [rip + lr_at]
    mov [rsp], rax
    mov eax, [rip + lr_mode]
    mov [rsp + 8], eax
    mov [rip + lr_at], rdi
    mov dword ptr [rip + lr_mode], LM_MEASURE
    xor edi, edi
    mov edx, esi
    xor esi, esi
    call todo_lay
    test eax, eax
    jz 1f
    add eax, [rip + g_pmt + 4*MI_4]
    add eax, [rip + g_pmt + 4*MI_4]
1:  mov rcx, [rsp]
    mov [rip + lr_at], rcx
    mov ecx, [rsp + 8]
    mov [rip + lr_mode], ecx
    EPILOGUE

# FN agrow_todo_draw(AS*, row, x, y, w): its call's todo list alone at x, y (agrow_todo_h tall), the call's
#   dot before its first line
FN agrow_todo_draw
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    call row_of
    mov rax, [rax + AM_x]
    test rax, rax
    jz 9f
    mov [rsp], rax
    mov rdi, rbx
    mov rsi, rax
    call state_color
    mov ecx, eax
    mov rax, [rip + ag_fui]
    mov edx, [rax + FACE_lineh]
    mov edi, r13d
    mov esi, r14d
    add esi, [rip + g_pmt + 4*MI_4]
    call row_dot
    mov rax, [rip + lr_at]
    mov [rsp + 8], rax
    mov rax, [rsp]
    mov [rip + lr_at], rax
    mov eax, [rip + lr_mode]
    push rax
    push rax
    mov dword ptr [rip + lr_mode], LM_DRAW
    mov edi, r13d
    mov esi, r14d
    add esi, [rip + g_pmt + 4*MI_4]
    mov edx, r15d
    call todo_lay
    pop rax
    pop rax
    mov [rip + lr_mode], eax
    mov rax, [rsp + 8]
    mov [rip + lr_at], rax
9:  EPILOGUE

# small_line(kind cstr, text cstr, h, button): a muted line of the small face at lr_ux, lr_cy, cut at the
#   unit's width (lr_w); a button (PART_NOTE) when asked
small_line:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r14d, edx
    mov [rsp], ecx
    mov rdi, rsi
    call strlen
    mov [rip + ln_len], rax
    mov [rip + ln_ptr], r12
    mov rdi, [rip + ag_fsmall]
    mov esi, [rip + lr_ux]
    mov edx, [rip + lr_cy]
    mov ecx, r14d
    mov r8, r12
    mov r9, [rip + ln_len]
    COLOR eax, T_MUTED
    mov r10d, [rip + lr_w]
    inc r10d
    push r10
    push rax
    call fit_text
    add rsp, 16
    mov rdi, rbx
    mov esi, [rip + lr_ux]
    mov edx, [rip + lr_cy]
    mov ecx, [rip + lr_w]
    mov r8d, r14d
    mov r9d, 1
    call lay_line
    cmp dword ptr [rsp], 0
    je 9f
    mov edi, PART_NOTE
    mov esi, [rip + lr_ux]
    mov edx, [rip + lr_cy]
    mov ecx, [rip + lr_w]
    mov r8d, r14d
    call lay_btn
9:  EPILOGUE

# ---------------- ids, clicks, keys ----------------

# FN agrow_slot(row, child) -> eax the unit's slot for its ids (0..255): the same unit keeps its slot while it
#   is drawn frame after frame, two units never share one; a slot not drawn in the last frame is free again.
#   -1: all taken (the unit draws without buttons)
FN agrow_slot
    shl rdi, 16
    lea rdi, [rdi + rsi + 1]
    mov r8d, [rip + th_serial]
    lea r9, [rip + slot_key]
    lea r10, [rip + slot_ser]
    xor eax, eax
1:  cmp eax, SLOTS
    jae 2f
    cmp dword ptr [r10 + rax*4], 0
    je 11f
    cmp [r9 + rax*8], rdi
    je 4f
11: inc eax
    jmp 1b
2:  xor eax, eax                # a free one
3:  cmp eax, SLOTS
    jae 8f
    mov ecx, [r10 + rax*4]
    test ecx, ecx
    jz 31f
    inc ecx
    cmp ecx, r8d
    jb 31f
    inc eax
    jmp 3b
31: mov [r9 + rax*8], rdi
4:  mov [r10 + rax*4], r8d
    ret
8:  mov eax, -1
    ret

# slot_find(row) -> eax the slot a row had in the last frame, -1 (print-agent-row reads ids)
slot_find:
    shl rdi, 16
    inc rdi
    lea r9, [rip + slot_key]
    lea r10, [rip + slot_ser]
    xor eax, eax
1:  cmp eax, SLOTS
    jae 8f
    cmp dword ptr [r10 + rax*4], 0
    je 2f
    cmp [r9 + rax*8], rdi
    je 9f
2:  inc eax
    jmp 1b
8:  mov eax, -1
9:  ret

# pend_set(row, AT*, part): a click or a key's action, kept for after the frame as the row, the call's id and
#   the part (never a pointer: a reread in between finds nothing)
pend_set:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    call pend_clear
    mov [rip + pend_row], rbx
    mov [rip + pend_part], r13d
    mov rdi, [r12 + AT_id]
    call dup_cstr
    mov [rip + pend_id], rax
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# pend_at(AS*) -> rax the call pend_row and pend_id name, or 0 (the rows changed)
pend_at:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    test rbx, rbx
    jz 9f
    mov rsi, [rip + pend_row]
    test rsi, rsi
    js 9f
    cmp rsi, [rbx + AS_msgs + VEC_len]
    jae 8f
    call row_of
    mov r12, [rax + AM_x]
    test r12, r12
    jz 8f
    mov rdi, [r12 + AT_id]
    mov rsi, [rip + pend_id]
    test rsi, rsi
    jz 8f
    call strcmp_eq
    test eax, eax
    jz 1f
    mov rax, r12
    EPILOGUE
1:  mov rdi, r12                # a call under it (task 11)
    mov rsi, [rip + pend_id]
    call tree_find
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agrow_follow(): the action a click or a key asked for, now that nothing drawn is in use (thread_draw's
#   end): a text opens in a tab or its tab is found again, a link is followed, a command is copied
FN agrow_follow
    PROLOGUE 16
    call agtask_follow          # a task line's Stop (agenttask.s)
    call agfold_follow          # a fold's line clicked: it opens or closes (agentfold.s)
    cmp dword ptr [rip + pend_think], 0
    je 0f
    mov dword ptr [rip + pend_think], 0     # a thinking row's label: all of them open or close
    call agrow_think_toggle
0:  call agents_viewed          # a row's own open state, a chip's file, the error block's link
    mov rbx, rax
    mov rdi, rax
    call open_follow
    cmp dword ptr [rip + pend_err], 0
    je 610f
    mov rdi, rbx
    call err_follow
610: cmp dword ptr [rip + pend_part], 0
    je 9f
    call agents_viewed
    mov rbx, rax
    mov rdi, rbx
    call pend_at
    mov r12, rax
    mov r13d, [rip + pend_part]
    test r12, r12
    jz 8f
    cmp r13d, PART_LINK
    je 3f
    cmp r13d, PART_COPY
    je 4f
    cmp r13d, PART_DIFF
    je 5f
    cmp r13d, PART_KIDS         # task 11: the calls under it, Stop, Run in background
    je 6f
    cmp r13d, PART_STOP
    je 7f
    cmp r13d, PART_BG
    je 71f
    mov esi, ATX_IN             # a text in a tab
    cmp r13d, PART_IN
    je 2f
    mov esi, ATX_B
    cmp r13d, PART_PRE
    je 2f
    mov esi, ATX_OUT
    cmp r13d, PART_OUT
    je 2f
    cmp r13d, PART_NOTE
    jne 8f
2:  mov rdi, rbx
    mov rdx, r12
    mov ecx, r13d
    call open_text
    jmp 8f
3:  mov rdi, rbx                # the header's link
    mov rsi, r12
    call follow_link
    jmp 8f
4:  lea rdi, [rip + xs]         # Copy: the whole command
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    mov edx, ATX_IN
    lea rcx, [rip + xs]
    call agrow_full
    mov rdi, [rip + xs + SB_ptr]
    mov rsi, [rip + xs + SB_len]
    xor edx, edx
    call ed_clip_set
    lea rdi, [rip + .Lcopied]
    call app_toast
    jmp 8f
5:  mov rdi, rbx                # a diff in a diff tab
    mov rsi, r12
    call open_diff
    jmp 8f
6:  xor dword ptr [r12 + AT_flags], ATF_KIDS    # the calls under it listed or not; read from their file
    test dword ptr [r12 + AT_flags], ATF_KIDS   #   the first time (agrow_kids)
    jz 61f
    mov rdi, rbx
    mov rsi, r12
    call agrow_kids
61: mov rdi, rbx
    mov rsi, r12
    call agrow_touch
    jmp 8f
7:  mov rdi, rbx                # Stop: the agent's task it runs
    mov rsi, [r12 + AT_id]
    call agtask_of_call
    test rax, rax
    jz 8f
    mov rdi, rbx
    mov esi, AGK_STOP
    mov rdx, [rax + AK_id]
    call agtask_ask
    jmp 8f
71: mov rdi, rbx                # Run in background
    mov rsi, r12
    call agrow_canbg
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov esi, AGK_BG
    mov rdx, [r12 + AT_id]
    call agtask_ask
8:  call pend_clear
9:  EPILOGUE

# tab_key_of(AS*, AT*, part) -> rax the key a tab opened from that text is remembered by: the session's path,
#   the call's id and the part, hashed
tab_key_of:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    lea rdi, [rip + ys]
    call sb_clear
    mov rsi, [rbx + AS_path]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + ys]
    call sb_push_cstr
1:  lea rdi, [rip + ys]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + ys]
    mov rsi, [r12 + AT_id]
    call sb_push_cstr
    lea rdi, [rip + ys]
    mov esi, r13d
    add esi, 'A'
    call sb_push_byte
    mov rdi, [rip + ys + SB_ptr]
    mov rsi, [rip + ys + SB_len]
    call hash_line
    EPILOGUE

# tab_find(key) -> eax 1 when a tab that text opened is still open: it is shown again
tab_find:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12d, TABS_KEPT
    jae 8f
    lea rax, [rip + tab_key]
    cmp [rax + r12*8], rbx
    jne 4f
    lea rax, [rip + tab_doc]
    mov r13d, [rax + r12*4]     # its document's id among the tabs open
    xor r14d, r14d
2:  cmp r14, [rip + g_tabs + VEC_len]
    jae 4f
    mov rdi, r14
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 3f
    mov rcx, [rax + TAB_doc]
    test rcx, rcx
    jz 3f
    cmp [rcx + DOC_id], r13d
    jne 3f
    mov rdi, r14
    call app_activate_tab
    mov eax, 1
    EPILOGUE
3:  inc r14
    jmp 2b
4:  inc r12d
    jmp 1b
8:  xor eax, eax
    EPILOGUE

# tab_keep(key, DOC*): a tab a text opened, remembered (the last TABS_KEPT)
tab_keep:
    mov eax, [rip + tab_next]
    lea rcx, [rip + tab_key]
    mov [rcx + rax*8], rdi
    mov edx, [rsi + DOC_id]
    lea rcx, [rip + tab_doc]
    mov [rcx + rax*4], edx
    inc eax
    and eax, TABS_KEPT - 1
    mov [rip + tab_next], eax
    ret

# open_text(AS*, ATX_*, AT*, part): its whole text (agrow_full) in a read-only tab titled as the call says
#   (AT_title, else NAME and " tool input" / " tool output"); IN that is Markdown in a Markdown tab (no owner,
#   no Comment). A second time the tab it opened, while it is open
open_text:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rdx
    mov r13d, esi
    mov [rsp], ecx
    mov rdi, rbx
    mov rsi, r12
    mov edx, ecx
    call tab_key_of
    mov r14, rax
    mov rdi, rax
    call tab_find
    test eax, eax
    jnz 9f
    lea rdi, [rip + xs]
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    lea rcx, [rip + xs]
    call agrow_full
    lea rdi, [rip + ys]         # the title
    call sb_clear
    mov rsi, [r12 + AT_title]
    test rsi, rsi
    jnz 1f
    mov rsi, [r12 + AT_name]
    test rsi, rsi
    jnz 2f
    lea rsi, [rip + .Ltool]
2:  lea rdi, [rip + ys]
    call sb_push_cstr
    lea rsi, [rip + .Lt_input]
    cmp r13d, ATX_IN
    je 1f
    lea rsi, [rip + .Lt_output]
1:  lea rdi, [rip + ys]
    call sb_push_cstr
    mov rdx, [rip + xs + SB_len]
    mov rsi, [rip + xs + SB_ptr]
    test rsi, rsi
    jnz 3f
    lea rsi, [rip + .Lnothing]
3:  cmp r13d, ATX_IN
    jne 4f
    test dword ptr [r12 + AT_flags], ATF_MD
    jz 4f
    mov rdi, [rip + ys + SB_ptr]    # Markdown: a Markdown tab (it finds a tab of its title itself)
    xor ecx, ecx
    xor r8d, r8d
    call mdtab_open
    jmp 9f
4:  mov rdi, [rip + ys + SB_ptr]
    call testdiff_output
    test rax, rax
    jz 9f
    mov rdi, r14
    mov rsi, rax
    call tab_keep
9:  EPILOGUE

# open_diff(AS*, AT*): its two sides, whole, in a diff tab ("Diff View: NAME"), found again a second time
open_diff:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov rsi, r12
    mov edx, PART_DIFF
    call tab_key_of
    mov r14, rax
    mov rdi, rax
    call tab_find
    test eax, eax
    jnz 9f
    lea rdi, [rip + xs]
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    mov edx, ATX_A
    lea rcx, [rip + xs]
    call agrow_full
    mov rdi, [rip + xs + SB_len]    # the old side kept apart
    inc rdi
    call mem_alloc
    mov r13, rax
    mov rdi, rax
    mov rsi, [rip + xs + SB_ptr]
    mov rdx, [rip + xs + SB_len]
    call memcpy
    mov r15, [rip + xs + SB_len]
    lea rdi, [rip + xs]
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    mov edx, ATX_B
    lea rcx, [rip + xs]
    call agrow_full
    lea rdi, [rip + ys]
    call sb_clear
    lea rdi, [rip + ys]
    lea rsi, [rip + .Ldiff_view]
    call sb_push_cstr
    mov rsi, [r12 + AT_second]  # the file's name ("Diff View: NAME"), else the call's
    test rsi, rsi
    jnz 0f
    mov rsi, [r12 + AT_name]
    test rsi, rsi
    jz 1f
0:
    lea rdi, [rip + ys]
    call sb_push_cstr
1:  mov rdi, [rip + ys + SB_ptr]
    mov rsi, r13
    mov rdx, r15
    mov rcx, [rip + xs + SB_ptr]
    test rcx, rcx
    jnz 2f
    lea rcx, [rip + .Lnothing]
2:  mov r8, [rip + xs + SB_len]
    call testdiff_open
    mov [rsp], rax
    mov rdi, r13
    call mem_free
    mov rsi, [rsp]
    test rsi, rsi
    jz 9f
    mov rdi, r14
    call tab_keep
9:  EPILOGUE

# follow_link(AS*, AT*): the header's link: an http(s) URL asked before it opens (the driver names who asks,
#   else "This reply"), a file at its lines (PATH:L0-L1) and then its find text looked for; nothing else
follow_link:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rsi, [r12 + AT_link]
    test rsi, rsi
    jz 9f
    lea rdi, [rip + ys]
    call sb_clear
    lea rdi, [rip + ys]
    mov rsi, [r12 + AT_link]
    call sb_push_cstr
    mov esi, [r12 + AT_l0]
    test esi, esi
    jz 1f
    lea rdi, [rip + ys]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + ys]
    mov esi, [r12 + AT_l0]
    call sb_push_u64
    mov esi, [r12 + AT_l1]
    test esi, esi
    jz 1f
    lea rdi, [rip + ys]
    mov esi, '-'
    call sb_push_byte
    lea rdi, [rip + ys]
    mov esi, [r12 + AT_l1]
    call sb_push_u64
1:  mov rdi, rbx
    mov rsi, [rip + ys + SB_ptr]
    mov rdx, [rip + ys + SB_len]
    call agents_open_link
    test eax, eax
    jz 9f                       # a web link, or nothing opened
    mov rsi, [r12 + AT_find]    # a file opened: the caret on the first line of its find text
    test rsi, rsi
    jz 9f
    mov rdi, [rip + g_doc]
    test rdi, rdi
    jz 9f
    mov rdi, rsi
    call strlen
    mov rcx, rax
    mov rsi, [r12 + AT_find]
    xor edx, edx
2:  cmp rdx, rcx
    jae 3f
    cmp byte ptr [rsi + rdx], 10
    je 3f
    inc rdx
    jmp 2b
3:  mov rdi, [rip + g_doc]
    xor ecx, ecx
    mov r8d, 1
    call doc_search
    test rax, rax
    js 9f
    mov rdi, [rip + g_doc]
    mov rsi, rax
    xor edx, edx
    call ed_set_cursor
9:  EPILOGUE

# FN agrow_full(AS*, AT*, ATX_IN..ATX_B, sb) -> eax 1 the whole text, 0 only what was kept. A call with a place
#   in a file: its line read again (at most AT_REREAD_MAX), checked to be a whole line that names the call's
#   id, parsed and given to the reader's text function; a file changed underneath gives what was kept and the
#   toast. Else, and when the reader has nothing, what was kept and, when that was cut, "… N more lines"
FN agrow_full
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov rax, [r12 + AT_uoff]    # the line: the call's, or for OUT its result's
    mov rcx, [r12 + AT_ulen]
    cmp r13d, ATX_OUT
    jne 1f
    mov rax, [r12 + AT_roff]
    mov rcx, [r12 + AT_rlen]
1:  mov [rsp], rax
    mov [rsp + 8], rcx
    test rax, rax
    js .Lfull_kept
    test rcx, rcx
    jz .Lfull_kept
    cmp rcx, AT_REREAD_MAX
    ja .Lfull_kept
    mov rdi, [r12 + AT_file]
    test rdi, rdi
    jnz 2f
    mov rdi, [rbx + AS_path]
    test rdi, rdi
    jz .Lfull_kept
2:  mov rdx, [rsp]              # the line and the bytes around it: a line feed before (or the file's
    xor eax, eax                #   start) and after
    test rdx, rdx
    jz 21f
    dec rdx
    mov eax, 1
21: mov [rsp + 16], eax
    mov rsi, [rsp + 8]
    add rsi, rax
    inc rsi
    call agent_read_window
    mov [rsp + 24], rax
    test rax, rax
    jz .Lfull_changed
    mov ecx, [rsp + 16]
    mov r8, [rsp + 8]
    lea r9, [r8 + rcx + 1]
    cmp rdx, r9
    jb .Lfull_freed_changed     # the file is shorter now
    test ecx, ecx
    jz 22f
    cmp byte ptr [rax], 10
    jne .Lfull_freed_changed
22: add rax, rcx
    cmp byte ptr [rax + r8], 10
    jne .Lfull_freed_changed
    mov [rsp + 32], rax         # the line
    mov rdi, rax                # it names the call
    mov rsi, r8
    mov rdx, [r12 + AT_id]
    push rdx
    push rdx
    mov rdi, rdx
    call strlen
    mov rcx, rax
    pop rdx
    pop rdx
    mov rdi, [rsp + 32]
    mov rsi, [rsp + 8]
    call str_find
    test rax, rax
    js .Lfull_freed_changed
    mov rdi, [rsp + 32]
    mov rsi, [rsp + 8]
    call json_parse
    test rax, rax
    jz .Lfull_freed_changed
    mov r15, rax
    mov edi, [rbx + AS_kind]    # the reader gives the part's whole text
    mov esi, 1
    call agent_reader
    test rax, rax
    jz .Lfull_freed_kept
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov rcx, r15
    mov r8, r14
    call rax
    test eax, eax
    jz .Lfull_freed_kept
    mov rdi, [rsp + 24]
    call mem_free
    mov eax, 1
    EPILOGUE
.Lfull_freed_changed:
    mov rdi, [rsp + 24]
    call mem_free
.Lfull_changed:
    lea rdi, [rip + .Lchanged]
    call app_toast
    jmp .Lfull_kept
.Lfull_freed_kept:
    mov rdi, [rsp + 24]
    call mem_free
.Lfull_kept:
    mov eax, r13d               # what is kept
    sub eax, ATX_IN
    mov [rsp + 40], eax
    imul rax, rax, SB_SIZE
    lea r15, [r12 + rax + AT_in]
    mov rdx, [r15 + SB_len]
    test rdx, rdx
    jz 3f
    mov rdi, r14
    mov rsi, [r15 + SB_ptr]
    call sb_push
3:  mov ecx, [rsp + 40]
    mov rax, [r12 + AT_size + rcx*8]
    cmp [r15 + SB_len], rax
    jae 8f
    mov rdi, [r15 + SB_ptr]     # cut: "… N more lines"
    mov rsi, [r15 + SB_len]
    call lines_of
    mov ecx, [rsp + 40]
    mov edx, [r12 + AT_lines + rcx*4]
    sub edx, eax
    jle 8f
    mov [rsp + 44], edx
    mov rdi, r14
    lea rsi, [rip + .Lmore_lines]
    call sb_push_cstr
    mov rdi, r14
    mov esi, [rsp + 44]
    call sb_push_u64
    mov rdi, r14
    lea rsi, [rip + .Lmore_lines2]
    call sb_push_cstr
8:  xor eax, eax
    EPILOGUE

# has_action(AS*, row) -> eax the part Enter runs on that row (0: none): a long IN, a long OUT, a note with a
#   tab, a written file's text, a diff, the header's link; thinking and a compaction marker (their own forms
#   come later: PART_TOGGLE); with focus view a fold's line (PART_FOLD) and none for what it hides
has_action:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call agfold_action          # focus view: a fold's line, or nothing shown to act on
    test eax, eax
    jz 0f
    jns 9f
    xor eax, eax
    EPILOGUE
0:  mov rdi, rbx
    mov rsi, r12
    call row_of
    mov r12, [rax + AM_x]
    test r12, r12
    jnz 1f
    mov ecx, [rax + AM_role]
    cmp ecx, R_THINK
    jne 0f
    mov rdi, rax                # thinking: only one with text opens
    call think_has_text
    test eax, eax
    jz 9f
    mov eax, PART_TOGGLE
    EPILOGUE
0:  mov rdx, rax                # a compaction marker, a wrapped notice: they open
    mov eax, PART_TOGGLE
    cmp ecx, R_COMPACT
    je 9f
    cmp ecx, R_META
    jne 610f
    test dword ptr [rdx + AM_flags], AMF_NOTICE
    jnz 9f
    xor eax, eax
    EPILOGUE
610: cmp ecx, R_USER             # a prompt longer than its clip: Show more, Show less
    jne 620f
    mov eax, PART_MORE
    cmp dword ptr [rdx + AM_n], 0
    jne 9f
620: xor eax, eax
    EPILOGUE
1:  xor eax, eax
    test dword ptr [r12 + AT_flags], ATF_HIDDEN
    jnz 9f
    mov rdi, r12                # the calls under it, listed or not (task 11)
    call kids_shown
    test eax, eax
    mov eax, PART_KIDS
    jnz 9f
    mov eax, PART_IN
    test dword ptr [r12 + AT_big], 1
    jz 2f
    cmp qword ptr [r12 + AT_in + SB_len], 0
    jne 9f
2:  mov eax, PART_OUT
    test dword ptr [r12 + AT_big], 2
    jz 3f
    cmp qword ptr [r12 + AT_out + SB_len], 0
    jne 9f
3:  mov eax, PART_NOTE
    cmp qword ptr [r12 + AT_note], 0
    je 4f
    cmp qword ptr [r12 + AT_title], 0
    je 4f
    cmp qword ptr [r12 + AT_out + SB_len], 0
    jne 9f
4:  mov eax, PART_DIFF
    test dword ptr [r12 + AT_flags], ATF_DIFF
    jnz 9f
    mov eax, PART_PRE
    test dword ptr [r12 + AT_flags], ATF_PRE
    jnz 9f
    mov eax, PART_LINK
    cmp qword ptr [r12 + AT_link], 0
    jne 9f
    xor eax, eax
9:  EPILOGUE

# FN agrow_key(AS*, keysym, cp, mods) -> eax 1 taken: Up, Down: the row focus to the previous, next row that
#   has an action, brought into view; Enter, Space: the focused row's action; Escape: the focus goes
FN agrow_key
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    xor eax, eax
    test ecx, MOD_CTRL | MOD_ALT | MOD_SUPER | MOD_SHIFT
    jnz 9f
    cmp r12d, KEY_ESCAPE
    je .Lk_escape
    cmp r12d, KEY_UP
    je .Lk_up
    cmp r12d, KEY_DOWN
    je .Lk_down
    cmp r12d, KEY_RETURN
    je .Lk_enter
    cmp r12d, KEY_KP_ENTER
    je .Lk_enter
    cmp r12d, ' '
    je .Lk_enter
    xor eax, eax
    EPILOGUE
.Lk_escape:
    xor eax, eax
    cmp qword ptr [rip + rf_row], 0
    jl 9f
    mov qword ptr [rip + rf_row], -1
    jmp 8f
.Lk_enter:
    xor eax, eax
    mov r13, [rip + rf_row]
    test r13, r13
    js 9f
    cmp r13, [rbx + AS_msgs + VEC_len]
    jae 9f
    mov rdi, rbx                # (a row focus focus view hides: its fold's line)
    mov rsi, r13
    call agfold_shown
    mov r13, rax
    mov [rip + rf_row], rax
    mov rdi, rbx
    mov rsi, r13
    call has_action
    test eax, eax
    jnz 612f
    mov rdi, rbx                # task 10: a reply that ends its turn (Focus Last Message reaches one, Up and
    mov rsi, r13                #   Down do not stop there): its Copy response (agentsel.s)
    call agsel_resp
    jmp 8f
612: cmp eax, PART_MORE
    je 610f
    cmp eax, PART_FOLD          # a fold's line: it opens or closes (agentfold.s)
    jne .Lk_enter_act
    mov rdi, rbx
    mov rsi, r13
    call agfold_click
    jmp 8f
.Lk_enter_act:
    cmp eax, PART_TOGGLE
    jne 0f
    mov rdi, rbx                # thinking: all of them open or close; a marker, a notice, a long prompt:
    mov rsi, r13                #   its own row (after the frame)
    call row_of
    cmp dword ptr [rax + AM_role], R_THINK
    jne 610f
    call agrow_think_toggle
    jmp 8f
610: mov [rip + pend_open], r13
    jmp 8f
0:  mov r14d, eax
    mov rdi, rbx
    mov rsi, r13
    call row_of
    mov rdi, r13
    mov rsi, [rax + AM_x]
    mov edx, r14d
    call pend_set
    jmp 8f
.Lk_up:
    mov r13, [rip + rf_row]
    test r13, r13
    jns 1f
    call agents_view_last       # no focus yet: from the last row shown
    lea r13, [rax + 1]
1:  mov rdi, rbx                # the previous row that may show (over a closed fold in one step)
    mov rsi, r13
    call agfold_prev
    mov r13, rax
    test r13, r13
    js 7f
    cmp r13, [rbx + AS_msgs + VEC_len]
    jae 1b
    mov rdi, rbx
    mov rsi, r13
    call has_action
    test eax, eax
    jz 1b
    jmp 6f
.Lk_down:
    mov r13, [rip + rf_row]
    test r13, r13
    jns 2f
    call agents_view_first      # no focus yet: from the first row shown
    lea r13, [rax - 1]
2:  mov rdi, rbx
    mov rsi, r13
    call agfold_next
    mov r13, rax
    cmp r13, [rbx + AS_msgs + VEC_len]
    jae 7f
    mov rdi, rbx
    mov rsi, r13
    call has_action
    test eax, eax
    jz 2b
6:  mov [rip + rf_row], r13
    mov rdi, rbx
    mov rsi, r13
    call agents_reveal
    jmp 8f
7:  cmp qword ptr [rip + rf_row], 0     # none further: the key is still the thread's
    jl 9f
8:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# FN agrow_focus() -> rax the focused row of the open conversation, -1
FN agrow_focus
    mov rax, [rip + rf_row]
    ret

# FN agrow_focus_set(row or -1): the row focus (Focus Last Message, a conversation opened)
FN agrow_focus_set
    mov [rip + rf_row], rdi
    mov dword ptr [rip + g_dirty], 1
    ret

# FN agrow_think() -> eax 1 when the open conversation's thinking rows are open
FN agrow_think
    mov eax, [rip + think_open]
    ret

# FN agrow_click(AS*, row, part or 0) -> eax 1: as a click on that part of a call's row (0: the part Enter
#   runs), followed after the frame (agent-row-click)
FN agrow_click
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    xor eax, eax
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 9f
    cmp r13d, PART_RESP         # task 10: a reply's Copy response (agentsel.s)
    jne 0f
    mov rdi, rbx
    mov rsi, r12
    call agsel_resp
    EPILOGUE
0:  test r13d, r13d
    jnz 1f
    mov rdi, rbx
    mov rsi, r12
    call has_action
    mov r13d, eax
    test eax, eax
    jz 9f
1:  cmp r13d, PART_FOLD         # a fold's line (agentfold.s)
    jne 11f
    mov rdi, rbx
    mov rsi, r12
    call agfold_click
    mov eax, 1
    EPILOGUE
11: mov rdi, rbx
    mov rsi, r12
    call row_of
    mov rsi, [rax + AM_x]
    test rsi, rsi
    jnz 2f
    cmp dword ptr [rax + AM_role], R_THINK
    je 11f
    mov rcx, rax                # a marker, a notice, a long prompt: its own row opens or closes
    mov rdi, rbx
    mov rsi, r12
    call has_action
    test eax, eax
    jz 8f
    cmp eax, r13d
    jne 8f
    mov [rip + pend_open], r12
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
11: cmp r13d, PART_TOGGLE       # a thinking row with text: as a click on its label
    jne 8f
    mov rdi, rax
    call think_has_text
    test eax, eax
    jz 9f
    mov dword ptr [rip + pend_think], 1
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
2:  mov rdi, r12
    mov edx, r13d
    call pend_set
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agrow_by_id(AS*, id ptr, len) -> rax a call of the conversation by its id: in AS_calls, else a row's
#   (the newest first; tests: agent-test-tool changes a call that has its result)
FN agrow_by_id
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call calls_get
    test rax, rax
    jnz 9f
    mov r14, [rbx + AS_msgs + VEC_len]
1:  test r14, r14
    jz 8f
    dec r14
    mov rdi, rbx
    mov rsi, r14
    call row_of
    mov r15, [rax + AM_x]
    test r15, r15
    jz 1b
    mov rdi, [r15 + AT_id]
    call strlen
    cmp rax, r13
    jne 1b
    mov rdi, [r15 + AT_id]
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jz 1b
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agrow_place(AT*, file ptr, len, offset, length): where its records are (agent-test-tool src=): the file
#   (0: the session's), the call's line and its result's
FN agrow_place
    PROLOGUE
    mov rbx, rdi
    mov r12, rcx
    mov r13, r8
    mov rdi, [rbx + AT_file]
    push rsi
    push rdx
    call mem_free
    pop rsi
    pop rdi
    mov qword ptr [rbx + AT_file], 0
    test rdi, rdi
    jz 1f
    test rsi, rsi
    jz 1f
    call mem_dup
    mov [rbx + AT_file], rax
1:  mov [rbx + AT_uoff], r12
    mov [rbx + AT_ulen], r13
    mov [rbx + AT_roff], r12
    mov [rbx + AT_rlen], r13
    EPILOGUE

# ---------------- dumps ----------------

# FN agrow_row_dump(sb, AS*, row): print-agent-row's lines of a typed row as the last frame drew it: a call's
#   "header X,Y,W,H T", "link X,Y,W,H T ID", "desc T", "note T", "in N T" and "out N T" a drawn line each,
#   "button PART X,Y,W,H ID"; a line row's "plain TEXT"
FN agrow_row_dump
    PROLOGUE 16
    mov r15, rdi
    mov rbx, rsi
    mov r12, rdx
    mov rdi, rbx                # its own parts are not drawn (focus view): none
    mov rsi, r12
    call agfold_own
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call row_of
    mov r13, rax
    cmp qword ptr [r13 + AM_x], 0
    jne 4f
    cmp dword ptr [r13 + AM_role], R_COMPACT
    je 610f
    cmp dword ptr [r13 + AM_role], R_THINK
    jne 5f
610: mov eax, [r13 + AM_dser]    # thinking, a marker: "label X,Y,W,H T", its button, its text when open
    cmp eax, [rip + th_serial]
    jne 9f
    mov rdi, r12
    call slot_find
    mov [rip + lr_slot], eax
    mov [rip + lr_out], r15
    mov dword ptr [rip + lr_mode], LM_DUMP
    mov rdi, rbx
    mov rsi, r12
    mov edx, [r13 + AM_dx]
    mov ecx, [r13 + AM_dy]
    mov r8d, [rip + th_textw]
    call think_lay
    mov dword ptr [rip + lr_mode], LM_MEASURE
    jmp 9f
4:  mov eax, [r13 + AM_dser]
    cmp eax, [rip + th_serial]
    jne 9f                      # not drawn in the last frame
    mov rdi, r12
    call slot_find
    mov [rip + lr_slot], eax
    mov [rip + lr_out], r15
    mov dword ptr [rip + lr_mode], LM_DUMP
    mov rdi, rbx
    mov rsi, r12
    mov edx, [r13 + AM_dx]
    mov ecx, [r13 + AM_dy]
    mov r8d, [rip + th_textw]
    call tr_lay
    mov dword ptr [rip + lr_mode], LM_MEASURE
    jmp 9f
5:  mov rdi, r15
    lea rsi, [rip + .Lplain]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [r13 + AM_text]
    mov rdx, [r13 + AM_len]
    call push_line
9:  EPILOGUE

# push_line(sb, ptr, len): the first line of a text, 60 bytes at most, and a line feed
push_line:
    PROLOGUE
    mov rbx, rdi
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 2f
    cmp rcx, 60
    jae 2f
    cmp byte ptr [rsi + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov rdx, rcx
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# push_word(sb, label cstr, cstr or 0): "LABEL TEXT" a line when the text is set (its first line, 60 bytes)
push_word:
    PROLOGUE
    test rdx, rdx
    jz 9f
    mov rbx, rdi
    mov r12, rdx
    call sb_push_cstr
    mov rdi, r12
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call push_line
9:  EPILOGUE

# push_flags(sb, flags, names table {word, flag}, open: 0 leaves the word "open" out) -> " flags=WORDS" (a
#   comma between, "-" none)
push_flags:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r15d, ecx
    lea rsi, [rip + .Ld_flags]
    call sb_push_cstr
    xor r14d, r14d              # words written
1:  mov rsi, [r13]
    test rsi, rsi
    jz 8f
    mov eax, [r13 + 8]
    test r12d, eax
    jz 3f
    test r15d, r15d
    jnz 12f
    lea rcx, [rip + .Lw_open]
    cmp rsi, rcx
    je 3f
12: test r14d, r14d
    jz 2f
    push rsi
    push rsi
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    pop rsi
    pop rsi
2:  mov rdi, rbx
    call sb_push_cstr
    inc r14d
3:  add r13, 16
    jmp 1b
8:  test r14d, r14d
    jnz 9f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
9:  EPILOGUE

# push_part(sb, indent cstr, label cstr, AT*, part n, content): "  in LINES/BYTES kept=BYTES T" when it is set
push_part:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8d
    mov [rsp + 4], r9d
    imul rax, r8, SB_SIZE
    lea r15, [r14 + rax + AT_in]
    cmp qword ptr [r15 + SB_len], 0
    je 9f
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov ecx, [rsp]
    mov rdi, rbx
    mov esi, [r14 + AT_lines + rcx*4]
    call sb_push_u64
    mov rdi, rbx
    mov esi, '/'
    call sb_push_byte
    mov ecx, [rsp]
    mov rdi, rbx
    mov rsi, [r14 + AT_size + rcx*8]
    call sb_push_u64
    cmp dword ptr [rsp + 4], 0
    jne 1f
    mov rdi, rbx
    lea rsi, [rip + .Ld_kept]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r15 + SB_len]
    call sb_push_u64
1:  mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r15 + SB_ptr]
    mov rdx, [r15 + SB_len]
    call push_line
9:  EPILOGUE

# call_dump(sb, AT*, indent cstr, content): a call's state and parts, its children indented two more
call_dump:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
    mov rdi, rbx
    lea rsi, [rip + .Ld_name]
    call sb_push_cstr
    mov rsi, [r12 + AT_name]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Ldash]
1:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    mov eax, [r12 + AT_state]
    cmp eax, ATS_STOPPED
    jbe 2f
    xor eax, eax
2:  lea rcx, [rip + state_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov esi, [r12 + AT_flags]   # (content: whether its children are listed or were read is the view's)
    cmp dword ptr [rsp], 0
    je 21f
    and esi, ~(ATF_KIDS | ATF_LOADED)
21: mov rdi, rbx
    lea rdx, [rip + at_names]
    mov ecx, 1
    call push_flags
    mov rdi, rbx
    lea rsi, [rip + .Ld_kids]
    call sb_push_cstr
    mov eax, [r12 + AT_nkids]
    test eax, eax
    jns 3f
    mov rax, [r12 + AT_kids + VEC_len]
    test rax, rax
    jnz 3f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 4f
3:  mov rdi, rbx
    mov esi, eax
    call sb_push_u64
4:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    lea r14, [rip + ys]         # the indent and the parts
    mov rdi, r14
    call sb_clear
    mov rdi, r14
    mov rsi, r13
    call sb_push_cstr
    mov rdi, r14
    lea rsi, [rip + .Ltwo]
    call sb_push_cstr
    mov rdi, [r14 + SB_ptr]     # (owned for the children's turn: ys is reused)
    mov rsi, [r14 + SB_len]
    call mem_dup
    mov r15, rax
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Ld_second]
    mov rcx, [r12 + AT_second]
    call push_word2
    cmp qword ptr [r12 + AT_link], 0
    je 5f
    mov rdi, rbx
    mov rsi, r15
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_link]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r12 + AT_link]
    call sb_push_cstr
    cmp dword ptr [r12 + AT_l0], 0
    je 41f
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r12 + AT_l0]
    call sb_push_u64
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r12 + AT_l1]
    call sb_push_u64
41: mov rdi, rbx
    mov esi, 10
    call sb_push_byte
5:  mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Ld_tail]
    mov rcx, [r12 + AT_tail]
    call push_word2
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Ld_desc]
    mov rcx, [r12 + AT_desc]
    call push_word2
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Ld_note]
    mov rcx, [r12 + AT_note]
    call push_word2
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Ld_in]
    mov rcx, r12
    xor r8d, r8d
    mov r9d, [rsp]
    call push_part
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Ld_out]
    mov rcx, r12
    mov r8d, 1
    mov r9d, [rsp]
    call push_part
    test dword ptr [r12 + AT_flags], ATF_DIFF
    jz 6f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    mov ecx, [rsp]
    call agdiff_dump
6:  test dword ptr [r12 + AT_flags], ATF_PRE
    jz 7f
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Ld_pre]
    mov rcx, r12
    mov r8d, 3
    mov r9d, 1                  # (no kept= on pre)
    call push_part
7:  xor r14d, r14d              # the todo items
71: cmp r14, [r12 + AT_items + VEC_len]
    jae 72f
    mov rdi, rbx
    mov rsi, r15
    call sb_push_cstr
    imul rax, r14, ATI_SIZE
    add rax, [r12 + AT_items + VEC_ptr]
    mov [rsp + 8], rax
    mov ecx, [rax + ATI_state]
    cmp ecx, TODO_DONE
    jbe 73f
    xor ecx, ecx
73: lea rax, [rip + todo_marks]
    mov rsi, [rax + rcx*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rax, [rsp + 8]
    mov rdi, [rax + ATI_text]
    call strlen
    mov rcx, [rsp + 8]
    mov rdi, rbx
    mov rsi, [rcx + ATI_text]
    mov rdx, rax
    call push_line
    inc r14
    jmp 71b
72: mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Ld_find]
    mov rcx, [r12 + AT_find]
    call push_word2
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Ld_title]
    mov rcx, [r12 + AT_title]
    call push_word2
    xor r14d, r14d              # the children that are there
8:  cmp r14, [r12 + AT_kids + VEC_len]
    jae 9f
    mov rdi, rbx
    mov rsi, r15
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_call]
    call sb_push_cstr
    mov rax, [r12 + AT_kids + VEC_ptr]
    mov rax, [rax + r14*8]
    mov [rsp + 8], rax
    mov rdi, rbx
    mov rsi, [rax + AT_id]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [rsp + 8]
    mov rdx, r15
    mov ecx, [rsp]
    call call_dump
    inc r14
    jmp 8b
9:  mov rdi, r15
    call mem_free
    EPILOGUE

# push_word2(sb, indent cstr, label cstr, cstr or 0): "INDENTLABEL TEXT" when the text is set
push_word2:
    PROLOGUE
    test rcx, rcx
    jz 9f
    mov rbx, rdi
    mov r12, rdx
    mov r13, rcx
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call push_word
9:  EPILOGUE

# FN agrow_dump(sb, AS*, from, n, content): print-agent-rows: a row a line, "N KIND h=H est=0|1 live=0|1
#   t=UNIXMS|- day=0|1 turn=N fold=N|-" and its kind's fields and lines (content 1: what a reread must give
#   again: no h=, est=, live=, t=, day=, open=, kept=, tokens=, no live thinking's label, no flag "open")
FN agrow_dump
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], rcx              # n
    mov [rsp + 8], r8d          # content
    test r12, r12
    jz 9f
    mov rax, r13
    add rax, rcx
    jc 1f
    cmp rax, [r12 + AS_msgs + VEC_len]
    jbe 2f
1:  mov rax, [r12 + AS_msgs + VEC_len]
2:  mov [rsp + 16], rax         # the end
.Ldmp_row:
    cmp r13, [rsp + 16]
    jae 9f
    mov rdi, r12
    mov rsi, r13
    call row_of
    mov r14, rax
    mov r15, [r14 + AM_x]
    mov rdi, rbx
    mov rsi, r13
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov eax, [r14 + AM_role]
    cmp eax, R_UNKNOWN
    jbe 3f
    xor eax, eax
3:  lea rcx, [rip + kind_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    cmp dword ptr [rsp + 8], 0
    jne 4f
    mov rdi, r12                # the layout's and the time's
    mov rsi, r13
    mov edx, [rip + th_textw]
    call agents_row_peek
    mov [rsp + 24], edx
    mov [rsp + 28], eax
    mov rdi, rbx
    lea rsi, [rip + .Ld_h]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rsp + 28]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_est]
    call sb_push_cstr
    mov esi, [rsp + 24]
    xor esi, 1
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_live]
    call sb_push_cstr
    mov esi, [r14 + AM_flags]
    shr esi, 3                  # AMF_LIVE
    and esi, 1
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_t]
    call sb_push_cstr
    mov rsi, [r14 + AM_t]
    test rsi, rsi
    jnz 31f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 32f
31: mov rdi, rbx
    call sb_push_u64
32: mov rdi, rbx
    lea rsi, [rip + .Ld_day]
    call sb_push_cstr
    mov esi, [r14 + AM_flags]
    shr esi, 4                  # AMF_DAY
    and esi, 1
    mov rdi, rbx
    call sb_push_u64
4:  mov rdi, rbx
    lea rsi, [rip + .Ld_turn]
    call sb_push_cstr
    mov esi, [r14 + AM_turn]
    call push_opt
    mov rdi, rbx
    lea rsi, [rip + .Ld_fold]
    call sb_push_cstr
    mov esi, [r14 + AM_fold]
    call push_opt
    test r15, r15               # a call
    jz 5f
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Lempty_s]
    mov ecx, [rsp + 8]
    call call_dump
    jmp 8f
5:  mov eax, [r14 + AM_role]
    cmp eax, R_THINK
    je .Ldmp_think
    cmp eax, R_COMPACT
    je .Ldmp_compact
    cmp eax, R_UNKNOWN
    je .Ldmp_unknown
    mov rdi, rbx                # meta, user, agent, info, error, result: flags and text
    mov esi, [r14 + AM_flags]
    lea rdx, [rip + am_names]
    mov ecx, [rsp + 8]
    xor ecx, 1
    call push_flags
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [rip + .Ld_text]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + AM_text]
    mov rdx, [r14 + AM_len]
    call push_line
    test dword ptr [r14 + AM_flags], AMF_CHIPS  # a prompt's chips: "  chip LABEL" each
    jz 8f
    mov r15, [r14 + AM_name]
    test r15, r15
    jz 8f
71: cmp byte ptr [r15], 0
    je 8f
    mov rdi, rbx
    lea rsi, [rip + .Ld_chip]
    call sb_push_cstr
    xor ecx, ecx
72: movzx eax, byte ptr [r15 + rcx]
    test eax, eax
    jz 73f
    cmp eax, 9
    je 73f
    cmp eax, 10
    je 73f
    inc rcx
    jmp 72b
73: mov rdi, rbx
    mov rsi, r15
    mov rdx, rcx
    call push_line
74: movzx eax, byte ptr [r15]
    test eax, eax
    jz 8f
    inc r15
    cmp eax, 10
    jne 74b
    jmp 71b
.Ldmp_think:
    test dword ptr [r14 + AM_flags], AMF_LIVE
    jz 51f
    cmp dword ptr [rsp + 8], 0
    jne 52f
51: mov rdi, rbx
    lea rsi, [rip + .Ld_label]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r14
    call think_label
52: cmp dword ptr [rsp + 8], 0
    jne 53f
    mov rdi, rbx
    lea rsi, [rip + .Ld_open]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + think_open]
    call sb_push_u64
53: mov rdi, rbx
    lea rsi, [rip + .Ld_ms]
    call sb_push_cstr
    mov esi, [r14 + AM_ms]
    call push_opt
    cmp dword ptr [rsp + 8], 0
    jne 54f
    mov rdi, rbx
    lea rsi, [rip + .Ld_tokens]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r14 + AM_n]
    call sb_push_u64
54: mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, r14                # its text (summarized thinking), the first line
    call think_has_text
    test eax, eax
    jz 8f
    mov rdi, rbx
    lea rsi, [rip + .Ld_text]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + AM_text]
    mov rdx, [r14 + AM_len]
    call push_line
    jmp 8f
.Ldmp_compact:
    mov rdi, rbx
    lea rsi, [rip + .Ld_trigger]
    call sb_push_cstr
    lea rsi, [rip + .Lw_auto]
    test dword ptr [r14 + AM_flags], AMF_MANUAL
    jz 55f
    lea rsi, [rip + .Lw_manual]
55: mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_freed]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r14 + AM_n]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 'k'
    call sb_push_byte
    cmp dword ptr [rsp + 8], 0
    jne 56f
    mov rdi, rbx
    lea rsi, [rip + .Ld_open]
    call sb_push_cstr
    mov esi, [r14 + AM_flags]
    shr esi, 5                  # AMF_OPEN
    and esi, 1
    mov rdi, rbx
    call sb_push_u64
56: mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    cmp qword ptr [r14 + AM_len], 0    # its summary's first line
    je 8f
    mov rdi, rbx
    lea rsi, [rip + .Ld_text]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + AM_text]
    mov rdx, [r14 + AM_len]
    call push_line
    jmp 8f
.Ldmp_unknown:
    mov rdi, rbx
    lea rsi, [rip + .Ld_type]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + AM_text]
    mov rdx, [r14 + AM_len]
    call push_line
8:  inc r13
    jmp .Ldmp_row
9:  EPILOGUE

# push_opt(esi n) using rbx = sb: N, or "-" when negative
push_opt:
    mov rdi, rbx
    test esi, esi
    js 1f
    jmp sb_push_u64
1:  mov esi, '-'
    jmp sb_push_byte

# think_label(sb, AM*): a thinking row's label (aTt): "Thinking..." while it streams, with " · " and the
#   estimate when there is one ("N tokens", from 1000 on "N.Nk tokens": AGe); "Thought for Ns" with its time
#   (rounded, as Math.round), else "Thinking"
think_label:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp dword ptr [r12 + AM_role], R_COMPACT
    je .Ltl_compact
    test dword ptr [r12 + AM_flags], AMF_LIVE
    jz 1f
    lea rsi, [rip + .Lthinking_live]
    call sb_push_cstr
    mov eax, [r12 + AM_n]
    test eax, eax
    jle 9f
    mov rdi, rbx
    lea rsi, [rip + .Lthink_sep]
    call sb_push_cstr
    mov r13d, [r12 + AM_n]
    cmp r13d, 1000
    jae 2f
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    jmp 3f
2:  lea eax, [r13 + 50]         # tenths of thousands, rounded (toFixed(1))
    xor edx, edx
    mov ecx, 100
    div ecx
    mov r13d, eax
    xor edx, edx
    mov ecx, 10
    div ecx
    mov r14d, edx
    mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    mov rdi, rbx
    mov esi, '.'
    call sb_push_byte
    mov rdi, rbx
    mov esi, r14d
    call sb_push_u64
    mov rdi, rbx
    mov esi, 'k'
    call sb_push_byte
3:  mov rdi, rbx
    lea rsi, [rip + .Lthink_tokens]
    call sb_push_cstr
9:  EPILOGUE
1:  mov eax, [r12 + AM_ms]
    test eax, eax
    js 7f
    lea rsi, [rip + .Lthought]
    call sb_push_cstr
    mov eax, [r12 + AM_ms]
    add eax, 500
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    mov rdi, rbx
    mov esi, 's'
    call sb_push_byte
    EPILOGUE
7:  lea rsi, [rip + .Lthinking]
8:  mov rdi, rbx
    call sb_push_cstr
    EPILOGUE
.Ltl_compact:                   # "Compacted chat · auto|manual · Nk tokens freed" ($Rt @5376317)
    lea rsi, [rip + .Lcompacted]
    call sb_push_cstr
    lea rsi, [rip + .Lw_auto]
    test dword ptr [r12 + AM_flags], AMF_MANUAL
    jz 1f
    lea rsi, [rip + .Lw_manual]
1:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lthink_sep]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r12 + AM_n]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lk_freed]
    call sb_push_cstr
    EPILOGUE

# FN agrow_fit_dump(sb): print-agent-rows-fit: the open conversation's typed rows laid out at every panel size
#   8 to 32 and width 240 to 900 by 20: "size=S w=W row=N tw=TW h=H", then a line a part, "  KIND X,Y,W,H"
#   and "  button PART X,Y,W,H", from the row's left and top (TW the rows' width). The setting is the user's
#   again after it
FN agrow_fit_dump
    PROLOGUE 48
    mov rbx, rdi
    call agents_viewed
    mov r15, rax
    test r15, r15
    jz 9f
    mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    mov [rip + lr_out], rbx
    mov dword ptr [rip + lr_slot], 0
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
    mov [rsp + 4], eax
    xor r14d, r14d
3:  cmp r14, [r15 + AS_msgs + VEC_len]
    jae 6f
    mov rdi, r15
    mov rsi, r14
    call row_of
    mov [rsp + 8], rax
    cmp qword ptr [rax + AM_x], 0
    jne 4f
    mov rdi, rax
    call line_row
    test eax, eax
    jnz 4f
    mov rax, [rsp + 8]          # and a prompt
    cmp dword ptr [rax + AM_role], R_USER
    jne 5f
4:  mov rdi, rbx
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
    lea rsi, [rip + .Lf_row]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r14
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_tw]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rsp + 4]
    call md_push_int
    lea rdi, [rip + xs]         # the parts first, then the height before them
    call sb_clear
    lea rax, [rip + xs]
    mov [rip + lr_out], rax
    mov rax, [rsp + 8]
    cmp qword ptr [rax + AM_x], 0
    je 41f
    mov dword ptr [rip + lr_mode], LM_FIT
    mov dword ptr [rip + lr_x], 0
    mov dword ptr [rip + lr_y], 0
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    mov r8d, [rsp + 4]
    call tr_lay
    jmp 42f
41: cmp dword ptr [rax + AM_role], R_USER
    je 44f
    cmp dword ptr [rax + AM_role], R_COMPACT
    je 45f
    cmp dword ptr [rax + AM_role], R_THINK
    jne 43f
45: mov dword ptr [rip + lr_mode], LM_FIT   # thinking, a marker: its label, its button, its text when open
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    mov r8d, [rsp + 4]
    call think_lay
    jmp 42f
44: mov dword ptr [rip + lr_mode], LM_FIT   # a prompt: its chips, its bubble, Show more
    mov rdx, rax
    mov rdi, r15
    mov rsi, r14
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, [rsp + 4]
    call prompt_lay
    jmp 42f
43: mov rdi, r15                # a line row: its one box
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    mov r8d, [rsp + 4]
    mov r9d, LM_MEASURE
    call line_lay
    mov [rsp + 12], eax
    lea rdi, [rip + xs]
    lea rsi, [rip + .Lf_text]
    call sb_push_cstr
    lea rdi, [rip + xs]
    mov esi, [rsp + 4]
    call sb_push_u64
    lea rdi, [rip + xs]
    mov esi, ','
    call sb_push_byte
    lea rdi, [rip + xs]
    mov esi, [rsp + 12]
    call sb_push_u64
    lea rdi, [rip + xs]
    mov esi, 10
    call sb_push_byte
    mov eax, [rsp + 12]
42: mov dword ptr [rip + lr_mode], LM_MEASURE
    mov [rip + lr_out], rbx
    mov [rsp + 12], eax
    mov rdi, rbx
    lea rsi, [rip + .Lf_h]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rsp + 12]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdx, [rip + xs + SB_len]
    test rdx, rdx
    jz 5f
    mov rdi, rbx
    mov rsi, [rip + xs + SB_ptr]
    call sb_push
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
9:  EPILOGUE

.section .rodata
.Lplain: .asciz "plain "
.Lunsupported: .asciz "Unsupported content type: "
.Ltip_full: .asciz "Press Enter to open the full text in an editor tab"
.Lfit_indent: .asciz "  "
.Lk_button: .asciz "button "
.Lk_header: .asciz "header"
.Lk_link: .asciz "link"
.Lk_second: .asciz "second"
.Lk_tail: .asciz "tail"
.Lk_desc: .asciz "desc"
.Lk_note: .asciz "note"
.Lk_in: .asciz "in"
.Lk_out: .asciz "out"
.Lin: .asciz "IN"
.Lout: .asciz "OUT"
.Lellipsis: .asciz "\342\200\246"
.Lcopied: .asciz "Copied."
.Ltool: .asciz "Tool"
.Lt_input: .asciz " tool input"
.Lt_output: .asciz " tool output"
.Lnothing: .asciz ""
.Lempty_s: .asciz ""
.Ldiff_view: .asciz "Diff View: "
.Lchanged: .asciz "The conversation's file changed: showing what was kept."
.Lmore_lines: .asciz "\n\342\200\246 "
.Lmore_lines2: .asciz " more lines"
.Ldash: .asciz "-"
.Ltwo: .asciz "  "
.Ld_flags: .asciz " flags="
.Ld_kept: .asciz " kept="
.Ld_name: .asciz "name="
.Ld_state: .asciz " state="
.Ld_kids: .asciz " kids="
.Ld_second: .asciz "second "
.Ld_link: .asciz "link "
.Ld_tail: .asciz "tail "
.Ld_desc: .asciz "desc "
.Ld_note: .asciz "note "
.Ld_in: .asciz "in"
.Ld_out: .asciz "out"
.Ld_pre: .asciz "pre"
.Ld_find: .asciz "find "
.Ld_title: .asciz "title "
.Ld_call: .asciz "call "
.Ld_h: .asciz " h="
.Ld_est: .asciz " est="
.Ld_live: .asciz " live="
.Ld_t: .asciz " t="
.Ld_day: .asciz " day="
.Ld_turn: .asciz " turn="
.Ld_fold: .asciz " fold="
.Ld_text: .asciz "  text "
.Ld_chip: .asciz "  chip "
.Ld_label: .asciz " label="
.Ld_open: .asciz " open="
.Ld_ms: .asciz " ms="
.Ld_tokens: .asciz " tokens="
.Ld_trigger: .asciz " trigger="
.Ld_freed: .asciz " freed="
.Ld_type: .asciz " type="
.Lw_auto: .asciz "auto"
.Lw_manual: .asciz "manual"
.Lthinking_live: .asciz "Thinking..."
.Lthought: .asciz "Thought for "
.Lthinking: .asciz "Thinking"
.Lthink_sep: .asciz " \302\267 "
.Lthink_tokens: .asciz " tokens"
.Lcompacted: .asciz "Compacted chat \302\267 "
.Lk_freed: .asciz "k tokens freed"
.Lcompacted_free: .asciz "Conversation was compacted to free up context."
.Lk11_running: .asciz "Running "      # task 11: the lines under a call
.Lk11_tool: .asciz "tool"
.Lk11_tool_calls: .asciz "Tool calls"
.Lk11_tool_call: .asciz " tool call"
.Lk11_failed: .asciz " failed"
.Lk11_stop: .asciz "Stop"
.Lk11_run_bg: .asciz "Run in background"
.Lk11_status: .asciz "status"
.Lk11_bgline: .asciz "background"
.Lk11_kids: .asciz "kids"
.Lk11_kid: .asciz "kid "
.Lk_label: .asciz "label"
.Lk_text: .asciz "text"
.Lk_check: .asciz "check"
.Lk_todo0: .asciz "todo [ ]"
.Lk_todo1: .asciz "todo [-]"
.Lk_todo2: .asciz "todo [x]"
.Lf_size: .asciz "size="
.Lf_w: .asciz " w="
.Lf_row: .asciz " row="
.Lf_tw: .asciz " tw="
.Lf_h: .asciz " h="
.Lf_text: .asciz "  text 0,0,"
.Ls_running: .asciz "running"
.Ls_ok: .asciz "ok"
.Ls_failed: .asciz "failed"
.Ls_denied: .asciz "denied"
.Ls_stopped: .asciz "stopped"
.Lr_unknown: .asciz "?"
.Lr_user: .asciz "user"
.Lr_agent: .asciz "agent"
.Lr_tool: .asciz "tool"
.Lr_result: .asciz "result"
.Lr_error: .asciz "error"
.Lr_info: .asciz "info"
.Lr_thinking: .asciz "thinking"
.Lr_meta: .asciz "meta"
.Lr_compact: .asciz "compact"
.Lr_unknown_k: .asciz "unknown"
.Lw_pill: .asciz "pill"
.Lw_queued: .asciz "queued"
.Lw_failed: .asciz "failed"
.Lw_notice: .asciz "notice"
.Lw_echo: .asciz "echo"
.Lw_chips: .asciz "chips"
.Lw_open: .asciz "open"
.Lw_hidden: .asciz "hidden"
.Lw_shell: .asciz "shell"
.Lw_pre: .asciz "pre"
.Lw_diff: .asciz "diff"
.Lw_wait: .asciz "wait"
.Lw_bg: .asciz "bg"
.Lw_canbg: .asciz "canbg"
.Lw_kids: .asciz "kids"
.Lw_md: .asciz "md"
.Lw_parent: .asciz "parent"
.Lw_loaded: .asciz "loaded"
.Lt_todo0: .asciz "todo [ ] "
.Lt_todo1: .asciz "todo [-] "
.Lt_todo2: .asciz "todo [x] "
.p2align 3
state_names: .quad .Ls_running, .Ls_ok, .Ls_failed, .Ls_denied, .Ls_stopped
kind_names: .quad .Lr_unknown, .Lr_user, .Lr_agent, .Lr_tool, .Lr_result, .Lr_error, .Lr_info, .Lr_thinking
    .quad .Lr_meta, .Lr_compact, .Lr_unknown_k
todo_marks: .quad .Lt_todo0, .Lt_todo1, .Lt_todo2
todo_kinds: .quad .Lk_todo0, .Lk_todo1, .Lk_todo2
am_names:                       # print-agent-rows' flag words: {word, flag}
    .quad .Lw_pill, AMF_PILL, .Lw_queued, AMF_QUEUED, .Lw_failed, AMF_FAILED, .Lw_notice, AMF_NOTICE
    .quad .Lw_echo, AMF_ECHO, .Lw_chips, AMF_CHIPS, .Lw_open, AMF_OPEN, 0, 0
at_names:
    .quad .Lw_hidden, ATF_HIDDEN, .Lw_shell, ATF_SHELL, .Lw_pre, ATF_PRE, .Lw_diff, ATF_DIFF
    .quad .Lw_wait, ATF_WAIT, .Lw_bg, ATF_BG, .Lw_canbg, ATF_CANBG, .Lw_kids, ATF_KIDS, .Lw_md, ATF_MD
    .quad .Lw_parent, ATF_PARENT, .Lw_loaded, ATF_LOADED, 0, 0
short_fields: .long AT_name, AT_second, AT_link, AT_tail, AT_desc, AT_note, AT_find, AT_title, AT_aux
.text

# FN agrow_dot(x of the text, y of the line, line h, argb): a row's dot in the pad before its text (a reply's)
FN agrow_dot
    jmp row_dot

# ---------------- the user's prompt, toggles, the error block (phase 3 task 8) ----------------

.data
.p2align 3
pend_open: .quad -1             # a row whose AMF_OPEN flips after the frame (a prompt's Show more, a
                                #   compaction marker, a wrapped notice)
pend_chip: .quad -1             # a prompt's chip clicked: its row, and pend_chipn its place
chip_name: .asciz "chip00"      # a dump's field name of a chip's button
.bss
.p2align 3
pend_chipn: .long 0
pend_err: .long 0               # the error block's link clicked: 1 Retry, 2 new, 3 logs, 4 dismiss
err_n: .long 0                  # err_lay's links laid out
err_pad: .long 0
.text

# nat_w(face, ptr, len, max px) -> eax the widest line's pixels, at most max (the first 64 KiB looked at: a
#   bubble hugs its text)
nat_w:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rsi + rdx]        # its end
    cmp rdx, 65536
    jbe 0f
    lea r13, [rsi + 65536]
0:  mov eax, ecx
    shl eax, 6
    mov [rsp], eax
    xor r14d, r14d              # the widest
    xor r15d, r15d              # this line's
1:  cmp r12, r13
    jae 8f
    movzx eax, byte ptr [r12]
    cmp eax, 10
    jne 2f
    cmp r15d, r14d
    cmova r14d, r15d
    xor r15d, r15d
    inc r12
    jmp 1b
2:  cmp eax, 9
    jne 3f
    mov eax, [rbx + FACE_cellw]
    shl eax, 8
    inc r12
    jmp 4f
3:  mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    call utf8_decode
    add r12, rdx
    mov rdi, rbx
    mov esi, eax
    call face_glyph
    mov eax, [rax + GL_adv]
4:  add r15d, eax
    cmp r15d, [rsp]
    jl 1b
    mov eax, [rsp]
    shr eax, 6
    EPILOGUE
8:  cmp r15d, r14d
    cmova r14d, r15d
    lea eax, [r14 + 63]
    shr eax, 6
    EPILOGUE

# line_len(ptr, len) -> rax the bytes of its first line
line_len:
    xor eax, eax
1:  cmp rax, rsi
    jae 9f
    cmp byte ptr [rdi + rax], 10
    je 9f
    inc rax
    jmp 1b
9:  ret

# fade_c(x, y, w, h, argb): the last pixels of a clipped text fade into the colour under it
fade_c:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    and r8d, 0x00ffffff
    mov [rsp + 16], r8d
    mov eax, ecx
    xor edx, edx
    mov ecx, 5
    div ecx
    test eax, eax
    jnz 1f
    mov eax, 1
1:  mov [rsp + 12], eax
    xor ebx, ebx
2:  cmp ebx, 5
    jae 9f
    lea eax, [rbx + 1]
    imul eax, eax, 51
    shl eax, 24
    mov r8d, [rsp + 16]
    or r8d, eax
    mov edi, [rsp]
    mov eax, [rsp + 12]
    imul eax, ebx
    mov esi, [rsp + 4]
    add esi, eax
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_fill
    inc ebx
    jmp 2b
9:  EPILOGUE

# field_rect(name cstr, x, y, w, h): " NAME=X,Y,W,H" to lr_out (print-agent-row's prompt fields)
field_rect:
    PROLOGUE 16
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov rbx, rdi
    mov rdi, [rip + lr_out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, [rip + lr_out]
    mov rsi, rbx
    call sb_push_cstr
    mov rdi, [rip + lr_out]
    mov esi, '='
    call sb_push_byte
    lea rdi, [rsp]
    call lay_rect
    EPILOGUE

# toggle_btn(part, x, y, w, h): a button of the unit laid out that acts on its row, not on a call: drawn, a
#   click keeps the row for after the frame (PART_MORE, PART_TOGGLE: its AMF_OPEN flips; PART_CHIP + n: the
#   chip's file opens); written out as lay_btn writes a button
toggle_btn:
    PROLOGUE 32
    mov eax, [rip + lr_mode]
    cmp eax, LM_DRAW
    je 1f
    call lay_btn
    EPILOGUE
1:  mov ebx, edi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    call part_id
    test eax, eax
    js 9f
    mov edi, eax
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call ui_btn
    test eax, UB_HOVER
    jz 2f
    mov dword ptr [rip + g_cursor], CUR_POINTER
2:  test eax, UB_CLICK
    jz 9f
    mov rax, [rip + lr_row]
    cmp ebx, PART_CHIP
    jb 3f
    cmp ebx, PART_CHIP + 16
    jae 3f
    mov [rip + pend_chip], rax
    lea ecx, [rbx - PART_CHIP]
    mov [rip + pend_chipn], ecx
    jmp 4f
3:  mov [rip + pend_open], rax
4:  mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# prompt_lay(AS* or 0, row or -1, AM*, x, y, w | h << 32) -> eax a prompt row's height below its time line,
#   in lr_mode (its unit's slot in lr_slot): the extension's user message (UI 3.2, 3.3; $Bt @5962500, cRe
#   @5547616). From its top: "queued" at the right for a message that has not started; its chips (an image,
#   a document, a selection, an opened file, a terminal, a browser tab: "LABEL\tTARGET" lines of AM_name),
#   right-aligned, a chip with a target a button that opens it; the bubble at the right, T_HOVER, as wide as
#   its text up to 85 % of the row; its text wrapped in it, clipped at 3 x MI_20 (the extension's 60 px,
#   scaled) with a fade and "Show more" under it, "Show less" when open (AMF_OPEN); a command's echo
#   (AMF_ECHO) one muted line. AM_n is 1 when the text is longer than the clip (measured). h (drawing an
#   open one) is the row's height below its time line: its text is not wrapped again to the end. Frame: [0]
#   x [4] y [8] w [12] h [16] the top of what comes next [20] line h [24] pad x [28] pad y [32] the text's
#   room [36] its natural width [40] the bubble's x [44] the text's height [48] clipped [52] a chip's h
#   [56] the next chip's right [60] chips [64] a chip's w [68] its label's w [72] its x [76] the label's w
#   [80] a small line's h [84] the bubble's w
prompt_lay:
    PROLOGUE 96 + RW_SIZE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov [rsp + 8], r9d
    mov rax, r9
    shr rax, 32
    mov [rsp + 12], eax
    mov [rip + lr_row], r12
    mov qword ptr [rip + lr_at], 0
    mov [rip + lr_x], ecx
    mov [rip + lr_y], r8d
    mov [rip + lr_w], r9d
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_3]
    mov [rsp + 20], eax
    PM eax, MI_10
    mov [rsp + 24], eax
    PM eax, MI_6
    mov [rsp + 28], eax
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    mov ecx, [rip + g_pmt + 4*MI_16]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 80], eax
    mov eax, [rsp + 8]          # the text's room: 85 % of the row less the bubble's pads
    imul eax, eax, 85
    cdq
    mov ecx, 100
    idiv ecx
    sub eax, [rsp + 24]
    sub eax, [rsp + 24]
    cmp eax, 1
    jge 1f
    mov eax, 1
1:  mov [rsp + 32], eax
    mov eax, [rsp + 4]
    add eax, [rip + g_pmt + 4*MI_4]
    mov [rsp + 16], eax
    mov dword ptr [rsp + 60], 0
    test dword ptr [r13 + AM_flags], AMF_QUEUED     # "queued", at the right
    jz .Lpl_chips
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lqueued_w]
    call text_w
    mov [rsp + 76], eax
    mov eax, [rip + lr_mode]
    cmp eax, LM_DRAW
    jne 2f
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 76]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 80]
    lea r8, [rip + .Lqueued_w]
    mov r9d, 6
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 76]
    inc r11d
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    jmp 3f
2:  cmp eax, LM_FIT
    jne 3f
    lea rdi, [rip + .Lk_queued]
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 76]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 76]
    mov r8d, [rsp + 80]
    xor r9d, r9d
    call lay_line
3:  mov eax, [rsp + 80]
    add eax, [rip + g_pmt + 4*MI_2]
    add [rsp + 16], eax
.Lpl_chips:
    test dword ptr [r13 + AM_flags], AMF_CHIPS
    jz .Lpl_bubble
    mov r14, [r13 + AM_name]
    test r14, r14
    jz .Lpl_bubble
    cmp byte ptr [r14], 0
    je .Lpl_bubble
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_6]
    mov ecx, [rip + g_pmt + 4*MI_20]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 52], eax
    mov eax, [rsp]
    add eax, [rsp + 8]
    mov [rsp + 56], eax
.Lpl_chip:
    cmp byte ptr [r14], 0
    je .Lpl_chips_end
    xor r15d, r15d              # its label: to a TAB, a line feed or the end
4:  movzx eax, byte ptr [r14 + r15]
    test eax, eax
    jz 5f
    cmp eax, 9
    je 5f
    cmp eax, 10
    je 5f
    inc r15
    jmp 4b
5:  mov rdi, [rip + ag_fsmall]
    mov rsi, r14
    mov rdx, r15
    call text_width
    mov [rsp + 68], eax
    add eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_8]
    cmp eax, [rsp + 8]
    jle 6f
    mov eax, [rsp + 8]
6:  mov [rsp + 64], eax
    mov ecx, [rsp + 56]
    sub ecx, eax
    cmp ecx, [rsp]
    jge 7f
    mov edx, [rsp]              # it does not fit beside the others: a row of chips under them (the
    add edx, [rsp + 8]          #   first of a row always fits: cut)
    cmp [rsp + 56], edx
    je 7f
    mov eax, [rsp + 52]
    add eax, [rip + g_pmt + 4*MI_4]
    add [rsp + 16], eax
    mov [rsp + 56], edx
    mov ecx, edx
    sub ecx, [rsp + 64]
7:  mov [rsp + 72], ecx
    mov eax, [rip + lr_mode]
    cmp eax, LM_DRAW
    jne 8f
    COLOR r9d, T_BORDER
    COLOR eax, T_PANEL
    mov edi, [rsp + 72]
    mov esi, [rsp + 16]
    mov edx, [rsp + 64]
    mov ecx, [rsp + 52]
    PM r8d, MI_RADIUS
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 72]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 52]
    mov r8, r14
    mov r9, r15
    COLOR r10d, T_FG
    mov r11d, [rsp + 64]
    sub r11d, [rip + g_pmt + 4*MI_8]
    sub r11d, [rip + g_pmt + 4*MI_8]
    jg 71f
    mov r11d, 1
71: push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    jmp 81f
8:  cmp eax, LM_FIT
    jne 81f
    lea rdi, [rip + .Lk_chip]
    mov esi, [rsp + 72]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 64]
    mov r8d, [rsp + 52]
    xor r9d, r9d
    call lay_line
81: cmp byte ptr [r14 + r15], 9 # a chip with a target: a button that opens it (a dump: " chipN=X,Y,W,H")
    jne 82f
    movzx eax, byte ptr [r14 + r15 + 1]
    test eax, eax
    jz 82f
    cmp eax, 10
    je 82f
    mov edi, [rsp + 60]
    cmp edi, 16
    jae 82f
    cmp dword ptr [rip + lr_mode], LM_DUMP
    jne 811f
    mov eax, [rsp + 60]         # its name: "chip" and its place
    xor edx, edx
    mov ecx, 10
    div ecx
    add eax, '0'
    add edx, '0'
    mov byte ptr [rip + chip_name + 4], al
    mov byte ptr [rip + chip_name + 5], dl
    lea rdi, [rip + chip_name]
    mov esi, [rsp + 72]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 64]
    mov r8d, [rsp + 52]
    call field_rect
    jmp 82f
811: add edi, PART_CHIP
    mov esi, [rsp + 72]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 64]
    mov r8d, [rsp + 52]
    call toggle_btn
82: mov eax, [rsp + 72]
    sub eax, [rip + g_pmt + 4*MI_4]
    mov [rsp + 56], eax
    inc dword ptr [rsp + 60]
83: movzx eax, byte ptr [r14 + r15]  # the next chip's line
    test eax, eax
    jz .Lpl_chips_end
    inc r15
    cmp eax, 10
    jne 83b
    add r14, r15
    jmp .Lpl_chip
.Lpl_chips_end:
    mov eax, [rsp + 52]
    add eax, [rip + g_pmt + 4*MI_4]
    add [rsp + 16], eax
.Lpl_bubble:
    mov dword ptr [rsp + 48], 0
    mov rsi, [r13 + AM_text]
    mov rdx, [r13 + AM_len]
    test dword ptr [r13 + AM_flags], AMF_ECHO
    jz 1f
    mov rdi, rsi                # an echo: its first line
    mov rsi, rdx
    call line_len
    mov rdx, rax
    mov rsi, [r13 + AM_text]
    mov rdi, [rip + ag_fui]
    mov ecx, [rsp + 32]
    call nat_w
    mov [rsp + 36], eax
    mov eax, [rsp + 20]
    mov [rsp + 44], eax
    jmp .Lpl_box
1:  mov rdi, [rip + ag_fui]
    mov ecx, [rsp + 32]
    call nat_w
    mov [rsp + 36], eax
    call clip_h                 # (the extension's 60 px, scaled)
    mov r14d, eax
    test dword ptr [r13 + AM_flags], AMF_OPEN
    jz 2f
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 2f
    cmp dword ptr [r13 + AM_n], 0
    je 2f
    mov dword ptr [rsp + 48], 1 # an open long one drawn: its height from the row's, wrapped no further
    mov eax, [rsp + 12]
    sub eax, [rsp + 16]
    add eax, [rsp + 4]
    sub eax, [rsp + 28]
    sub eax, [rsp + 28]
    sub eax, [rip + g_pmt + 4*MI_2]
    sub eax, [rsp + 80]
    sub eax, [rip + g_pmt + 4*MI_4]
    cmp eax, [rsp + 20]
    jge 11f
    mov eax, [rsp + 20]
11: mov [rsp + 44], eax
    jmp .Lpl_box
2:  lea rdi, [rsp + 96]         # its lines (collapsed: only as many as tell it is longer than the clip)
    mov rax, [rip + ag_fui]
    mov [rdi + RW_face], rax
    mov rax, [r13 + AM_text]
    mov [rdi + RW_text], rax
    mov rax, [r13 + AM_len]
    mov [rdi + RW_len], rax
    mov eax, [rsp + 32]
    mov [rdi + RW_w], eax
    mov eax, [rsp + 20]
    mov [rdi + RW_lh], eax
    mov dword ptr [rdi + RW_draw], 0
    mov qword ptr [rdi + RW_out], 0
    mov qword ptr [rdi + RW_mute], -1
    mov dword ptr [rdi + RW_max], 0
    test dword ptr [r13 + AM_flags], AMF_OPEN
    jnz 3f
    mov eax, r14d
    xor edx, edx
    div dword ptr [rsp + 20]
    add eax, 2
    mov [rdi + RW_max], eax
3:  call rw_wrap
    imul eax, [rsp + 20]
    xor ecx, ecx
    cmp eax, r14d
    setg cl
    mov [rsp + 48], ecx
    cmp dword ptr [rip + lr_mode], LM_MEASURE
    jne 4f
    mov [r13 + AM_n], ecx       # (has_action: a long prompt has Show more)
4:  test ecx, ecx
    jz 5f
    test dword ptr [r13 + AM_flags], AMF_OPEN
    jnz 5f
    mov eax, r14d
5:  mov [rsp + 44], eax
.Lpl_box:
    mov eax, [rsp + 36]         # the bubble: at the right, as wide as its text
    cmp eax, [rsp + 32]
    jle 1f
    mov eax, [rsp + 32]
1:  add eax, [rsp + 24]
    add eax, [rsp + 24]
    cmp eax, [rsp + 8]
    jle 2f
    mov eax, [rsp + 8]
2:  mov [rsp + 84], eax
    mov ecx, [rsp]
    add ecx, [rsp + 8]
    sub ecx, eax
    mov [rsp + 40], ecx
    mov r14d, [rsp + 44]        # its height
    add r14d, [rsp + 28]
    add r14d, [rsp + 28]
    mov eax, [rip + lr_mode]
    cmp eax, LM_DRAW
    je .Lpl_draw
    cmp eax, LM_FIT
    jne 3f
    lea rdi, [rip + .Lk_bubble]
    mov esi, [rsp + 40]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 84]
    mov r8d, r14d
    xor r9d, r9d
    call lay_line
    jmp .Lpl_more
3:  cmp eax, LM_DUMP
    jne .Lpl_more
    lea rdi, [rip + .Lk_bubble]
    mov esi, [rsp + 40]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 84]
    mov r8d, r14d
    call field_rect
    jmp .Lpl_more
.Lpl_draw:
    mov edi, [rsp + 40]
    mov esi, [rsp + 16]
    mov edx, [rsp + 84]
    mov ecx, r14d
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
    COLOR r15d, T_FG
    test dword ptr [r13 + AM_flags], AMF_QUEUED | AMF_ECHO
    jz 1f
    COLOR r15d, T_MUTED
1:  test dword ptr [r13 + AM_flags], AMF_ECHO
    jz 2f
    mov rdi, [r13 + AM_text]    # an echo: one line, cut with "…"
    mov rsi, [r13 + AM_len]
    call line_len
    mov r9, rax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 40]
    add esi, [rsp + 24]
    mov edx, [rsp + 16]
    add edx, [rsp + 28]
    mov ecx, [rsp + 20]
    mov r8, [r13 + AM_text]
    mov r11d, [rsp + 32]
    inc r11d
    push r11
    push r15
    call ui_text_v_fit
    add rsp, 16
    jmp .Lpl_more
2:  mov edi, [rsp + 40]         # the text, inside the bubble's text area
    mov esi, [rsp + 16]
    add esi, [rsp + 28]
    mov edx, [rsp + 84]
    mov ecx, [rsp + 44]
    call gfx_clip_push
    lea rdi, [rsp + 96]
    mov rax, [rip + ag_fui]
    mov [rdi + RW_face], rax
    mov rax, [r13 + AM_text]
    mov [rdi + RW_text], rax
    mov rax, [r13 + AM_len]
    mov [rdi + RW_len], rax
    mov eax, [rsp + 40]
    add eax, [rsp + 24]
    mov [rdi + RW_x], eax
    mov eax, [rsp + 16]
    add eax, [rsp + 28]
    mov [rdi + RW_y], eax
    mov eax, [rsp + 32]
    mov [rdi + RW_w], eax
    mov eax, [rsp + 20]
    mov [rdi + RW_lh], eax
    mov [rdi + RW_color], r15d
    mov dword ptr [rdi + RW_draw], 1
    mov qword ptr [rdi + RW_out], 0
    mov rax, [r13 + AM_mute]
    mov [rdi + RW_mute], rax
    mov eax, [rip + g_cv + CV_cy0]
    mov [rdi + RW_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rdi + RW_bot], eax
    sub eax, [rdi + RW_y]       # lines to the clip's bottom, no more (a long open one: not to its end)
    jg 3f
    mov eax, 0
3:  xor edx, edx
    div dword ptr [rsp + 20]
    add eax, 1
    mov [rdi + RW_max], eax
    mov edi, SELP_PROMPT        # task 10: its text is selected by the pointer, banded under it (agentsel.s)
    call part_id
    mov ecx, eax
    lea rdi, [rsp + 96]
    mov rsi, r12
    mov edx, SELP_PROMPT
    mov r8d, [rsp + 44]
    call agsel_plain
    test r12, r12               # phase 4 task 7: its mentions as chips (a queued one's drawn as text)
    js 41f
    mov rdi, r12
    call agents_chips_begin
    mov dword ptr [rip + rw_chips], 1
41: lea rdi, [rsp + 96]
    call rw_wrap
    mov dword ptr [rip + rw_chips], 0
    cmp dword ptr [rsp + 48], 0 # cut: a fade over its last pixels
    je 4f
    test dword ptr [r13 + AM_flags], AMF_OPEN
    jnz 4f
    mov edi, [rsp + 40]
    mov esi, [rsp + 16]
    add esi, [rsp + 28]
    add esi, [rsp + 44]
    PM ecx, MI_10
    sub esi, ecx
    mov edx, [rsp + 84]
    COLOR r8d, T_HOVER
    call fade_c
4:  call gfx_clip_pop
.Lpl_more:
    add [rsp + 16], r14d
    cmp dword ptr [rsp + 48], 0
    je .Lpl_nomore
    mov eax, [rip + g_pmt + 4*MI_2]
    add [rsp + 16], eax
    lea r14, [rip + .Lshow_more]
    test dword ptr [r13 + AM_flags], AMF_OPEN
    jz 1f
    lea r14, [rip + .Lshow_less]
1:  mov rdi, [rip + ag_fsmall]
    mov rsi, r14
    call text_w
    cmp eax, [rsp + 8]          # (cut to the row: a narrow panel at a large size)
    jle 11f
    mov eax, [rsp + 8]
11: mov [rsp + 76], eax
    mov ecx, [rsp]
    add ecx, [rsp + 8]
    sub ecx, eax
    mov [rsp + 72], ecx
    mov eax, [rip + lr_mode]
    cmp eax, LM_DUMP
    jne 2f
    lea rdi, [rip + .Lk_more]
    mov esi, [rsp + 72]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 76]
    mov r8d, [rsp + 80]
    call field_rect
    jmp 4f
2:  cmp eax, LM_DRAW
    jne 3f
    mov rdi, r14
    call strlen
    mov r9, rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 72]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 80]
    mov r8, r14
    COLOR r10d, T_ACCENT
    mov r11d, [rsp + 76]
    inc r11d
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
3:  mov edi, PART_MORE
    mov esi, [rsp + 72]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 76]
    mov r8d, [rsp + 80]
    call toggle_btn
4:  mov eax, [rsp + 80]
    add [rsp + 16], eax
    jmp .Lpl_end
.Lpl_nomore:
    cmp dword ptr [rip + lr_mode], LM_DUMP
    jne .Lpl_end
    mov rdi, [rip + lr_out]
    lea rsi, [rip + .Lf_nomore]
    call sb_push_cstr
.Lpl_end:
    cmp dword ptr [rip + lr_mode], LM_DUMP
    jne 1f
    mov rdi, [rip + lr_out]
    lea rsi, [rip + .Lf_chips]
    call sb_push_cstr
    mov rdi, [rip + lr_out]
    mov esi, [rsp + 60]
    call sb_push_u64
    mov rdi, [rip + lr_out]
    lea rsi, [rip + .Lf_clipped]
    call sb_push_cstr
    mov rdi, [rip + lr_out]
    mov esi, [r13 + AM_n]
    call sb_push_u64
1:  mov eax, [rsp + 16]
    add eax, [rip + g_pmt + 4*MI_4]
    sub eax, [rsp + 4]
    EPILOGUE

# FN agrow_prompt_h(AM*, w) -> eax a prompt row's height below its time line (agents.s msg_height); notes in
#   AM_n whether its text is longer than the clip
FN agrow_prompt_h
    PROLOGUE
    mov dword ptr [rip + lr_mode], LM_MEASURE
    mov r9d, esi
    mov rdx, rdi
    xor edi, edi
    mov rsi, -1
    xor ecx, ecx
    xor r8d, r8d
    call prompt_lay
    EPILOGUE

# FN agrow_prompt_draw(AS* or 0, row or -1, AM*, x, y, w | h << 32): a prompt row drawn below its time line
#   (a queued one, row -1, without buttons); its row focus framed
FN agrow_prompt_draw
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov r14, r9
    mov dword ptr [rip + lr_slot], -1
    test r12, r12
    js 1f
    mov rdi, r12
    xor esi, esi
    call agrow_slot
    mov [rip + lr_slot], eax
1:  mov dword ptr [rip + lr_mode], LM_DRAW
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, [rsp]
    mov r8d, [rsp + 4]
    mov r9, r14
    call prompt_lay
    mov [rsp + 8], eax
    mov dword ptr [rip + lr_mode], LM_MEASURE
    test r12, r12
    js 9f
    cmp [rip + rf_row], r12
    jne 9f
    mov edi, [rsp]
    sub edi, [rip + g_pmt + 4*MI_4]
    mov esi, [rsp + 4]
    mov edx, r14d
    add edx, [rip + g_pmt + 4*MI_8]
    mov ecx, [rsp + 8]
    call focus_frame
9:  EPILOGUE

# FN agrow_prompt_fields(sb, AS*, row, AM*, x, y): print-agent-row's fields of a prompt row as the last frame
#   drew it: " left=X tw=W chipNN=X,Y,W,H… bubble=X,Y,W,H more=X,Y,W,H|- chips=N clipped=0|1"
FN agrow_prompt_fields
    PROLOGUE 16
    mov [rip + lr_out], rdi
    mov rbx, rsi
    mov r12, rdx
    mov r13, rcx
    mov [rsp], r8d
    mov [rsp + 4], r9d
    mov rdi, [rip + lr_out]     # the row's left and width
    lea rsi, [rip + .Lf_left]
    call sb_push_cstr
    mov rdi, [rip + lr_out]
    mov esi, [rsp]
    call md_push_int
    mov rdi, [rip + lr_out]
    lea rsi, [rip + .Lf_tw]
    call sb_push_cstr
    mov rdi, [rip + lr_out]
    mov esi, [rip + th_textw]
    call md_push_int
    mov rdi, r12
    call slot_find
    mov [rip + lr_slot], eax
    mov dword ptr [rip + lr_mode], LM_DUMP
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, [rsp]
    mov r8d, [rsp + 4]
    mov r9d, [rip + th_textw]
    call prompt_lay
    mov dword ptr [rip + lr_mode], LM_MEASURE
    EPILOGUE

# FN agrow_prompt_est(AM*) -> eax, edx, ecx: a prompt row's estimate parts (agents.s row_parts): a collapsed
#   prompt's text at most the clip (no width part), an open one's lines and bytes, an echo one line
FN agrow_prompt_est
    PROLOGUE
    mov rbx, rdi
    PM r12d, MI_4               # its pads and the bubble's
    add r12d, [rip + g_pmt + 4*MI_4]
    add r12d, [rip + g_pmt + 4*MI_6]
    add r12d, [rip + g_pmt + 4*MI_6]
    mov rax, [rip + ag_fsmall]
    mov r14d, [rax + FACE_lineh]
    mov eax, [rip + g_pmt + 4*MI_16]
    cmp r14d, eax
    cmovl r14d, eax             # a small line
    test dword ptr [rbx + AM_flags], AMF_QUEUED
    jz 1f
    add r12d, r14d
    add r12d, [rip + g_pmt + 4*MI_2]
1:  test dword ptr [rbx + AM_flags], AMF_CHIPS
    jz 2f
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_6]
    mov ecx, [rip + g_pmt + 4*MI_20]
    cmp eax, ecx
    cmovl eax, ecx
    add r12d, eax
    add r12d, [rip + g_pmt + 4*MI_4]
2:  mov rax, [rip + ag_fui]
    mov r13d, [rax + FACE_lineh]
    add r13d, [rip + g_pmt + 4*MI_3]
    test dword ptr [rbx + AM_flags], AMF_ECHO
    jz 3f
    lea eax, [r12 + r13]
    xor edx, edx
    xor ecx, ecx
    EPILOGUE
3:  test dword ptr [rbx + AM_flags], AMF_OPEN
    jz 4f
    lea eax, [r12 + r14]        # open: its "Show less" and its lines
    add eax, [rip + g_pmt + 4*MI_2]
    mov edx, [rbx + AM_nl]
    inc edx
    mov rcx, [rbx + AM_len]
    cmp rcx, 16777216
    jbe 9f
    mov ecx, 16777216
    jmp 9f
4:  mov eax, [rbx + AM_nl]      # collapsed: its lines up to the clip, and "Show more" past it
    inc eax
    imul eax, r13d
    push rax
    push rax
    call clip_h
    mov ecx, eax
    pop rax
    pop rax
    cmp eax, ecx
    jle 5f
    mov eax, ecx
    add r12d, r14d
    add r12d, [rip + g_pmt + 4*MI_2]
5:  add eax, r12d
    xor edx, edx
    xor ecx, ecx
9:  EPILOGUE

# ---------------- the error block (UI 3.22: iPt @5594295) ----------------
#
# While a conversation rhun drives is FAILED its reason (AL_report) is pinned at the top of the thread:
#   the text (cut at 2000 characters and "…"; an unknown conversation's id: "Couldn't load this
#   conversation's saved history, so it can't be continued."), then the links "Retry", "Start a new
#   conversation" (a driver that starts conversations) and "View output logs", and "×" ("Dismiss error":
#   ALF_ERRGONE, until the next failure). It is a unit of its own for agrow_slot (row ERR_ROW).

# err_live(AS*) -> rax its AL* when the block shows, else 0
err_live:
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 9f
    cmp dword ptr [rcx + AL_state], ALS_FAILED
    jne 9f
    test dword ptr [rcx + AL_flags], ALF_ERRGONE
    jnz 9f
    cmp qword ptr [rcx + AL_report + SB_len], 0
    je 9f
    mov rax, rcx
9:  ret

# err_says(AL*): ys holds the block's text
err_says:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + ys]
    call sb_clear
    mov rdi, [rbx + AL_report + SB_ptr]
    mov rsi, [rbx + AL_report + SB_len]
    lea rdx, [rip + .Lno_conv]
    mov ecx, NO_CONV_LEN
    call str_find
    test rax, rax
    js 1f
    lea rdi, [rip + ys]
    lea rsi, [rip + .Lnot_found]
    call sb_push_cstr
    EPILOGUE
1:  mov r12, [rbx + AL_report + SB_ptr]  # 2000 characters, "…" when cut
    mov r13, [rbx + AL_report + SB_len]
    xor ecx, ecx
    xor edx, edx
2:  cmp rcx, r13
    jae 4f
    movzx eax, byte ptr [r12 + rcx]
    and eax, 0xc0
    cmp eax, 0x80
    je 3f
    cmp edx, ERR_CHARS
    je 5f
    inc edx
3:  inc rcx
    jmp 2b
4:  lea rdi, [rip + ys]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    EPILOGUE
5:  lea rdi, [rip + ys]
    mov rsi, r12
    mov rdx, rcx
    call sb_push
    lea rdi, [rip + ys]
    lea rsi, [rip + .Lellipsis]
    call sb_push_cstr
    EPILOGUE

# err_lay(AS*, x, y, w) -> eax the block's height (0: none), in lr_mode. Frame: [0] x [4] y [8] w [12] pad
#   [16] the text's room [20] line h [24] cy [28] the links' x [32] the text's lines [36] a link's w
#   [40] link [44] a link h [48] the × size; RW at [64]
err_lay:
    PROLOGUE 64 + RW_SIZE
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    call err_live
    mov r12, rax
    test rax, rax
    jz 8f
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 0f
    mov dword ptr [rip + lr_mode], LM_MEASURE  # drawn: its box first, as tall as it is laid out
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call err_lay
    mov dword ptr [rip + lr_mode], LM_DRAW
    COLOR r9d, T_ERROR
    COLOR r10d, T_BG
    mov ecx, eax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    PM r8d, MI_RADIUS
    push r10
    push r10
    call gfx_frame
    add rsp, 16
0:  mov qword ptr [rip + lr_row], ERR_ROW
    mov qword ptr [rip + lr_at], 0
    mov eax, [rsp]
    mov [rip + lr_x], eax
    mov eax, [rsp + 4]
    mov [rip + lr_y], eax
    PM eax, MI_8
    mov [rsp + 12], eax
    PM eax, MI_20               # the ×: MI_20 square at the top right
    mov [rsp + 48], eax
    mov eax, [rsp + 8]
    sub eax, [rsp + 12]
    sub eax, [rsp + 12]
    sub eax, [rsp + 48]
    cmp eax, 1
    jge 1f
    mov eax, 1
1:  mov [rsp + 16], eax
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_3]
    mov [rsp + 20], eax
    mov ecx, [rip + g_pmt + 4*MI_16]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 44], eax
    mov rdi, r12
    call err_says
    lea rdi, [rsp + 64]         # its lines (8 at most: the rest is in View output logs)
    mov rax, [rip + ag_fsmall]
    mov [rdi + RW_face], rax
    mov rax, [rip + ys + SB_ptr]
    mov [rdi + RW_text], rax
    mov rax, [rip + ys + SB_len]
    mov [rdi + RW_len], rax
    mov eax, [rsp]
    add eax, [rsp + 12]
    mov [rdi + RW_x], eax
    mov eax, [rsp + 4]
    add eax, [rsp + 12]
    mov [rdi + RW_y], eax
    mov eax, [rsp + 16]
    mov [rdi + RW_w], eax
    mov eax, [rsp + 20]
    mov [rdi + RW_lh], eax
    COLOR eax, T_ERROR
    mov [rdi + RW_color], eax
    mov eax, [rip + err_maxh]   # its lines: 8 at most, as many as half the area holds beside the links
    sub eax, [rsp + 12]
    sub eax, [rsp + 12]
    sub eax, [rip + g_pmt + 4*MI_4]
    sub eax, [rsp + 44]
    sub eax, [rsp + 44]
    cdq
    idiv dword ptr [rsp + 20]
    cmp eax, ERR_BLOCK_LINES
    jle 1f
    mov eax, ERR_BLOCK_LINES
1:  cmp eax, 1
    jge 2f
    mov eax, 1
2:  lea rdi, [rsp + 64]
    mov [rdi + RW_max], eax
    mov qword ptr [rdi + RW_out], 0
    mov qword ptr [rdi + RW_mute], -1
    xor eax, eax
    cmp dword ptr [rip + lr_mode], LM_DRAW
    sete al
    mov [rdi + RW_draw], eax
    mov eax, [rip + g_cv + CV_cy0]
    mov [rdi + RW_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rdi + RW_bot], eax
    call rw_wrap
    mov [rsp + 32], eax
    mov eax, [rsp + 4]          # the links' first line
    add eax, [rsp + 12]
    mov ecx, [rsp + 32]
    imul ecx, [rsp + 20]
    add eax, ecx
    add eax, [rip + g_pmt + 4*MI_4]
    mov [rsp + 24], eax
    mov eax, [rsp]
    add eax, [rsp + 12]
    mov [rsp + 28], eax
    mov dword ptr [rsp + 40], 0
    mov dword ptr [rip + err_n], 0
.Lel_link:
    mov eax, [rsp + 40]
    cmp eax, 3
    jae .Lel_links_end
    cmp eax, 1                  # "Start a new conversation": a driver that starts them
    jne 1f
    mov rax, [r12 + AL_drv]
    test dword ptr [rax + DRV_caps], DRVC_NEW
    jz .Lel_next
1:  mov eax, [rsp + 40]
    lea rcx, [rip + err_links]
    mov r13, [rcx + rax*8]
    cmp dword ptr [rip + err_n], 0  # " · " before every link but the first
    je 2f
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lmiddot_sp]
    call text_w
    mov [rsp + 36], eax
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 11f
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 28]
    mov edx, [rsp + 24]
    mov ecx, [rsp + 44]
    lea r8, [rip + .Lmiddot_sp]
    mov r9d, 4
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 36]
    inc r11d
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
11: mov eax, [rsp + 36]
    add [rsp + 28], eax
2:  mov rdi, [rip + ag_fsmall]
    mov rsi, r13
    call text_w
    mov [rsp + 36], eax
    mov ecx, [rsp]              # past the room: on a line of its own
    add ecx, [rsp + 12]
    add ecx, [rsp + 16]
    mov edx, [rsp + 28]
    add edx, eax
    cmp edx, ecx
    jle 3f
    mov edx, [rsp]
    add edx, [rsp + 12]
    cmp [rsp + 28], edx
    jle 3f
    mov [rsp + 28], edx
    mov eax, [rsp + 44]
    add [rsp + 24], eax
3:  mov eax, [rsp + 36]         # a link wider than the room is cut to it
    mov ecx, [rsp]
    add ecx, [rsp + 12]
    add ecx, [rsp + 16]
    sub ecx, [rsp + 28]
    cmp eax, ecx
    jle 31f
    mov eax, ecx
31: mov [rsp + 36], eax
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 4f
    mov rdi, r13
    call strlen
    mov r9, rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 28]
    mov edx, [rsp + 24]
    mov ecx, [rsp + 44]
    mov r8, r13
    COLOR r10d, T_ACCENT
    mov r11d, [rsp + 36]
    inc r11d
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
4:  mov edi, [rsp + 40]
    add edi, PART_ERR
    mov esi, [rsp + 28]
    mov edx, [rsp + 24]
    mov ecx, [rsp + 36]
    mov r8d, [rsp + 44]
    call err_btn
    mov eax, [rsp + 36]
    add [rsp + 28], eax
    inc dword ptr [rip + err_n]
.Lel_next:
    inc dword ptr [rsp + 40]
    jmp .Lel_link
.Lel_links_end:
    mov eax, [rsp + 24]         # its height
    add eax, [rsp + 44]
    add eax, [rsp + 12]
    sub eax, [rsp + 4]
    mov r14d, eax
    cmp dword ptr [rip + lr_mode], LM_DUMP     # print-agent-error: the text
    jne 7f
    mov rax, [rip + ys + SB_ptr]
    mov [rip + ln_ptr], rax
    mov rax, [rip + ys + SB_len]
    mov [rip + ln_len], rax
    lea rdi, [rip + .Lk_text]
    mov esi, [rsp]
    add esi, [rsp + 12]
    mov edx, [rsp + 4]
    add edx, [rsp + 12]
    mov ecx, [rsp + 16]
    mov r8d, [rsp + 32]
    imul r8d, [rsp + 20]
    xor r9d, r9d
    call lay_line
7:  mov edi, PART_ERR + 3       # "×", "Dismiss error"
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 48]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 48]
    mov r8d, ecx
    call err_btn
    cmp dword ptr [rip + lr_mode], LM_DRAW
    jne 71f
    mov rdi, [rip + ag_fui]
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 48]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 48]
    mov r8d, ecx
    lea r9, [rip + .Ltimes]
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_center
    add rsp, 16
71: mov eax, r14d
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# err_btn(part, x, y, w, h): a link of the error block: drawn, a click keeps it for after the frame
#   (pend_err; "×" has the tip "Dismiss error"); written out as lay_btn writes a button
err_btn:
    PROLOGUE 32
    cmp dword ptr [rip + lr_mode], LM_DRAW
    je 1f
    call lay_btn
    EPILOGUE
1:  mov ebx, edi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    call part_id
    test eax, eax
    js 9f
    mov [rsp + 16], eax
    mov edi, eax
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call ui_btn
    mov [rsp + 20], eax
    test eax, UB_HOVER
    jz 2f
    mov dword ptr [rip + g_cursor], CUR_POINTER
    cmp ebx, PART_ERR + 3
    jne 2f
    mov edi, [rsp + 16]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rsp + 12]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 20]
    lea r9, [rip + .Ldismiss]
    call tip_note_text
2:  test dword ptr [rsp + 20], UB_CLICK
    jz 9f
    lea eax, [rbx - PART_ERR + 1]
    mov [rip + pend_err], eax
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN agrow_err_h(AS*, w, max h) -> eax the error block's height at that width (0: it does not show); its text
#   has as many lines as max h holds beside its links (8 at most, 1 at least)
FN agrow_err_h
    PROLOGUE
    mov [rip + err_maxh], edx
    mov dword ptr [rip + lr_mode], LM_MEASURE
    mov ecx, esi
    xor esi, esi
    xor edx, edx
    call err_lay
    EPILOGUE

# FN agrow_err_draw(AS*, x, y, w): the error block drawn
FN agrow_err_draw
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov edi, ERR_ROW
    xor esi, esi
    call agrow_slot
    mov [rip + lr_slot], eax
    mov dword ptr [rip + lr_mode], LM_DRAW
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call err_lay
    mov dword ptr [rip + lr_mode], LM_MEASURE
    EPILOGUE

# FN agrow_err_dump(sb, AS*): print-agent-error: the block as the last frame drew it ("text X,Y,W,H T", a
#   "button PART X,Y,W,H ID" a link: 32 Retry, 33 new, 34 logs, 35 ×), "none" when it does not show
FN agrow_err_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call err_live
    test rax, rax
    jnz 1f
    mov rdi, rbx
    lea rsi, [rip + .Lnone_nl]
    call sb_push_cstr
    EPILOGUE
1:  mov edi, ERR_ROW
    call slot_find
    mov [rip + lr_slot], eax
    mov [rip + lr_out], rbx
    mov dword ptr [rip + lr_mode], LM_DUMP
    mov rdi, r12
    mov esi, [rip + err_x]
    mov edx, [rip + err_y]
    mov ecx, [rip + err_w]
    call err_lay
    mov dword ptr [rip + lr_mode], LM_MEASURE
    EPILOGUE

# FN agrow_err_at(x, y, w): where the block was drawn last (thread_draw; agrow_err_dump lays it out there)
FN agrow_err_at
    mov [rip + err_x], edi
    mov [rip + err_y], esi
    mov [rip + err_w], edx
    ret

# err_follow(AS*): the error block's link clicked, after the frame: Retry (its program starts again, nothing
#   is sent), a new conversation of its kind, its output logs in a read-only tab (the reason and the
#   program's last error output: AL_report), or "×"
err_follow:
    PROLOGUE
    mov rbx, rdi
    mov r12d, [rip + pend_err]
    mov dword ptr [rip + pend_err], 0
    test rbx, rbx
    jz 9f
    mov r13, [rbx + AS_live]
    test r13, r13
    jz 9f
    cmp r12d, 1
    jne 1f
    mov rdi, rbx
    call agent_retry
    jmp 9f
1:  cmp r12d, 2
    jne 2f
    mov edi, [rbx + AS_kind]
    call agent_new
    jmp 9f
2:  cmp r12d, 3
    jne 3f
    lea rdi, [rip + xs]         # its title: "NAME output"
    call sb_clear
    mov rax, [r13 + AL_drv]
    mov rsi, [rax + DRV_name]
    lea rdi, [rip + xs]
    call sb_push_cstr
    lea rdi, [rip + xs]
    lea rsi, [rip + .Loutput_sp]
    call sb_push_cstr
    lea rdi, [rip + xs]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + xs + SB_ptr]
    mov rsi, [r13 + AL_report + SB_ptr]
    mov rdx, [r13 + AL_report + SB_len]
    call testdiff_output
    jmp 9f
3:  cmp r12d, 4
    jne 9f
    or dword ptr [r13 + AL_flags], ALF_ERRGONE
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN agrow_err_click(AS*, n) -> eax 1: as a click on the block's link n (0 Retry, 1 new, 2 logs, 3 ×),
#   followed after the frame (agent-error-click)
FN agrow_err_click
    PROLOGUE
    call err_live
    test rax, rax
    jz 9f
    lea eax, [rsi + 1]
    mov [rip + pend_err], eax
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# open_follow(AS*): a row's AMF_OPEN flipped (pend_open) or a chip's file opened (pend_chip), after the frame
open_follow:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rip + pend_open]
    mov qword ptr [rip + pend_open], -1
    test rbx, rbx
    jz 5f
    test r12, r12
    js 5f
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 5f
    mov rdi, rbx
    mov rsi, r12
    call row_of
    xor dword ptr [rax + AM_flags], AMF_OPEN
    mov rdi, rbx
    mov rsi, r12
    call agents_msg_changed
5:  mov r12, [rip + pend_chip]
    mov qword ptr [rip + pend_chip], -1
    test rbx, rbx
    jz 9f
    test r12, r12
    js 9f
    cmp r12, [rbx + AS_msgs + VEC_len]
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call row_of
    test dword ptr [rax + AM_flags], AMF_CHIPS
    jz 9f
    mov r13, [rax + AM_name]    # its chip's line, then the target after its TAB
    test r13, r13
    jz 9f
    mov r14d, [rip + pend_chipn]
1:  test r14d, r14d
    jz 3f
2:  movzx eax, byte ptr [r13]
    test eax, eax
    jz 9f
    inc r13
    cmp eax, 10
    jne 2b
    dec r14d
    jmp 1b
3:  movzx eax, byte ptr [r13]
    test eax, eax
    jz 9f
    cmp eax, 10
    je 9f
    inc r13
    cmp eax, 9
    jne 3b
    xor r14d, r14d
4:  movzx eax, byte ptr [r13 + r14]
    test eax, eax
    jz 5f
    cmp eax, 10
    je 5f
    inc r14
    jmp 4b
5:  test r14, r14
    jz 9f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call agents_open_link
9:  EPILOGUE

.section .rodata
.Lqueued_w: .asciz "queued"
.Lk_queued: .asciz "queued"
.Lk_chip: .asciz "chip"
.Lk_bubble: .asciz "bubble"
.Lk_more: .asciz "more"
.Lshow_more: .asciz "Show more"
.Lshow_less: .asciz "Show less"
.Lf_nomore: .asciz " more=-"
.Lf_chips: .asciz " chips="
.Lf_clipped: .asciz " clipped="
.Lf_left: .asciz " left="
.Lno_conv: .ascii "No conversation found"
.Lnot_found: .asciz "Couldn't load this conversation's saved history, so it can't be continued."
.Lretry: .asciz "Retry"
.Lnew_conv: .asciz "Start a new conversation"
.Llogs: .asciz "View output logs"
.Lmiddot_sp: .asciz " \302\267 "
.Ltimes: .asciz "\303\227"
.Ldismiss: .asciz "Dismiss error"
.Lnone_nl: .asciz "none\n"
.Loutput_sp: .asciz " output"
.p2align 3
err_links: .quad .Lretry, .Lnew_conv, .Llogs
.bss
.p2align 2
err_x: .long 0
err_y: .long 0
err_w: .long 0
err_maxh: .long 0               # the block's height at most (agrow_err_h)
.text
