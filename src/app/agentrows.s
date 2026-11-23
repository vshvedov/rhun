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
#   cp, mods) -> eax; agrow_focus() -> rax; agrow_focus_set(row); agrow_think() -> eax;
#   agrow_code_face() -> rax FACE*; agrow_dump(sb, AS*, from, n, content); agrow_fit_dump(sb);
#   agrow_row_dump(sb, AS*, row)
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
F RW_pad2, 8
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
.equ UNSUPPORTED_LEN, 26        # .Lunsupported's bytes              # an error's clip when it is a button: 10 lines of its face

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
code_px: .long 0
code_gen: .long 0
code_face: .zero FACE_SIZE      # agrow_code_face's
slot_key: .zero 8 * SLOTS       # agrow_slot: (row << 16 | child + 1) of the unit that has the slot
slot_ser: .zero 4 * SLOTS       #   and the frame it was drawn in last (0: free)
tab_key: .zero 8 * TABS_KEPT    # the tabs opened from a row's text: (session path, call id, part) hashed,
tab_doc: .zero 4 * TABS_KEPT    #   and the document's DOC_id
tab_next: .long 0
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
6:  cmp [rip + pend_row], r12
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
#   call: none), the latest todo row noted, its row measured again
FN agrow_ready
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp qword ptr [r12 + AT_up], 0
    jne 8f
    test dword ptr [r12 + AT_flags], ATF_HIDDEN
    jnz 1f
    mov rdi, rbx
    movsxd rsi, dword ptr [r12 + AT_row]
    call agfold_add
1:  cmp qword ptr [r12 + AT_items + VEC_len], 0
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
    cmp qword ptr [r12 + AT_up], 0
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

# FN agrow_touch(AS*, AT*): it changed: its row is measured again
FN agrow_touch
    mov dword ptr [rsi + AT_h], -1
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
    mov eax, r12d
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
    mov rdi, [rbx + RW_out]
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
    mov rdx, [rbx + RW_face]
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
    call text_draw
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
    mov edx, [rbx + AM_nl]      # a line row: the small face's lines
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
5:  lea eax, [r13 + r15]
    xor edx, edx
    xor ecx, ecx
9:  EPILOGUE

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
    mov rdi, rbx
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
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r15d
    mov r9d, LM_DRAW
    call line_lay
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
    mov qword ptr [rsp + RW_out], 0
    xor eax, eax
    cmp dword ptr [rsp + RW_SIZE], LM_DRAW
    sete al
    mov [rsp + RW_draw], eax
    mov eax, [rip + g_cv + CV_cy0]
    mov [rsp + RW_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rsp + RW_bot], eax
    lea rdi, [rsp]
    call rw_wrap
    imul eax, [rsp + RW_lh]
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + RW_SIZE + 4], eax
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
    mov rdi, rbx
    call agent_drv_of
    COLOR ecx, T_ACCENT
    test rax, rax
    jz 8f
    mov rdx, [rax + DRV_brand]
    test edx, edx
    jz 8f
    mov ecx, edx
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
4:  test r13d, UB_CLICK
    jz 5f
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
    mov eax, [rip + g_cv + CV_cy0]
    mov [rsp + RW_top], eax
    mov eax, [rip + g_cv + CV_cy1]
    mov [rsp + RW_bot], eax
    lea rdi, [rsp]
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

# tr_lay(AS*, row, x, y, w) -> eax the call's row's height, laid out in lr_mode (its slot in lr_slot)
tr_lay:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 8], r8d
    call row_of
    mov r15, [rax + AM_x]
    mov [rip + lr_row], r12
    mov [rip + lr_at], r15
    mov eax, [rsp]
    mov [rip + lr_x], eax
    mov eax, [rsp + 4]
    mov [rip + lr_y], eax
    mov eax, [rsp + 8]
    mov [rip + lr_w], eax
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
    mov rdi, rbx
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
    jne 81f
    mov edi, PART_DIFF
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
    mov rdi, r12
    mov rsi, r15
    mov edx, PART_DIFF
    test dword ptr [r15 + AT_flags], ATF_DIFF
    jnz 84f
    mov edx, PART_PRE
84: call pend_set
81: add r13d, [rsp + 44]
82: add r13d, [rip + g_pmt + 4*MI_4]
    mov eax, r13d
    sub eax, [rsp + 4]
9:  EPILOGUE

# small_line(kind cstr, text cstr, h, button): a muted line of the small face at lr_x, lr_cy, cut at the
#   row's width (lr_w); a button (PART_NOTE) when asked
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
    mov esi, [rip + lr_x]
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
    mov esi, [rip + lr_x]
    mov edx, [rip + lr_cy]
    mov ecx, [rip + lr_w]
    mov r8d, r14d
    mov r9d, 1
    call lay_line
    cmp dword ptr [rsp], 0
    je 9f
    mov edi, PART_NOTE
    mov esi, [rip + lr_x]
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
    jz 8f
    mov rax, r12
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agrow_follow(): the action a click or a key asked for, now that nothing drawn is in use (thread_draw's
#   end): a text opens in a tab or its tab is found again, a link is followed, a command is copied
FN agrow_follow
    PROLOGUE 16
    cmp dword ptr [rip + pend_part], 0
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
    mov rsi, [r12 + AT_name]
    test rsi, rsi
    jz 1f
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
#   come later: PART_TOGGLE)
has_action:
    PROLOGUE
    call row_of
    mov r12, [rax + AM_x]
    test r12, r12
    jnz 1f
    mov ecx, [rax + AM_role]
    mov eax, PART_TOGGLE
    cmp ecx, R_THINK
    je 9f
    cmp ecx, R_COMPACT
    je 9f
    xor eax, eax
    EPILOGUE
1:  xor eax, eax
    test dword ptr [r12 + AT_flags], ATF_HIDDEN
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
    mov rdi, rbx
    mov rsi, r13
    call has_action
    test eax, eax
    jz 8f
    cmp eax, PART_TOGGLE
    je 8f                       # (thinking and compaction rows open in their own tasks)
    mov r14d, eax
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
1:  dec r13
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
2:  inc r13
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
    test r13d, r13d
    jnz 1f
    mov rdi, rbx
    mov rsi, r12
    call has_action
    mov r13d, eax
    test eax, eax
    jz 9f
1:  mov rdi, rbx
    mov rsi, r12
    call row_of
    mov rsi, [rax + AM_x]
    xor eax, eax
    test rsi, rsi
    jz 9f
    mov rdi, r12
    mov edx, r13d
    call pend_set
    mov eax, 1
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
    mov rdi, rbx
    mov rsi, r12
    call row_of
    mov r13, rax
    cmp qword ptr [r13 + AM_x], 0
    je 5f
    mov eax, [r13 + AM_dser]
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
    mov rdi, rbx
    mov esi, [r12 + AT_flags]
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
    jmp 8f
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

# think_label(sb, AM*): a thinking row's label: "Thinking..." while it streams, "Thought for Ns" with its time,
#   else "Thinking"
think_label:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rsi, [rip + .Lthinking_live]
    test dword ptr [r12 + AM_flags], AMF_LIVE
    jnz 8f
    mov eax, [r12 + AM_ms]
    test eax, eax
    js 7f
    lea rsi, [rip + .Lthought]
    call sb_push_cstr
    mov eax, [r12 + AM_ms]
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
    jz 5f
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
41: mov rdi, r15                # a line row: its one box
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
