# testing: the test model. Controllers (extensions with the "tests" feature) publish trees of
# items (testproto.s); rhun keeps them here with their results, the runs and their outputs, and
# the coverage of the last coverage run. A parent's state is the highest of its own and its
# children's (TSS_* order), kept incrementally: each item counts its children per state, so a
# result walks up its ancestors in O(depth).
.include "rhun.inc"

.bss
.p2align 2
.globl g_ts_ran
g_ts_ran: .long 0             # 1 once the session had a run (the status bar item shows)
.p2align 3
.globl g_ts_ctrls, g_ts_runs, g_ts_dirty, g_ts_runnum, g_ts_items_all, g_ts_bytes
g_ts_ctrls: .zero TSC_SIZE * TS_CTRL_MAX
g_ts_runs: .zero TSR_SIZE * TS_RUNS_MAX
g_ts_items_all: .quad 0         # items of every controller
g_ts_bytes: .quad 0             # messages, values and outputs every run holds
g_ts_runnum: .quad 0            # the last run number given
g_ts_dirty: .long 0             # the tree or a result changed since the view last looked: bit 0
                                # the Testing section's, bit 1 Test Results' (testresults.s)
.p2align 3
# body parsing (tsb_*): the cursor over the body being read and the fields of its last line
bp_p: .quad 0
bp_end: .quad 0
.globl tsb_f
tsb_f: .zero 16 * 16            # ptr, len of up to 16 fields
tsb_n: .quad 0
# a items body being applied
ib_parent: .quad 0              # the parent's index
ib_tsc: .quad 0
ib_mode: .quad 0                # 1 replace, 0 add
ib_new: .quad 0                 # items the body adds (its ids not known yet), counted in pass 1
ib_moved: .zero VEC_SIZE         # replace: items pass 1 marked TSF_MOVE
stack: .zero VEC_SIZE           # item indices still to visit (subtree walks)

.text

# ---------------- body parsing ----------------

# tsb_begin(ptr, len): read this body from its start
FN tsb_begin
    mov [rip + bp_p], rdi
    add rdi, rsi
    mov [rip + bp_end], rdi
    ret

# tsb_left() -> bytes not read yet
FN tsb_left
    mov rax, [rip + bp_end]
    sub rax, [rip + bp_p]
    ret

# tsb_line() -> rax the next line (without its LF), rdx its length; rax 0 when no LF is left
FN tsb_line
    mov rax, [rip + bp_p]
    mov rcx, [rip + bp_end]
    mov rdx, rax
1:  cmp rdx, rcx
    jae 8f
    cmp byte ptr [rdx], 10
    je 2f
    inc rdx
    jmp 1b
2:  lea rcx, [rdx + 1]
    mov [rip + bp_p], rcx
    sub rdx, rax
    ret
8:  xor eax, eax
    xor edx, edx
    ret

# tsb_take(n) -> rax the next n bytes, or 0 when fewer are left (nothing is read then)
FN tsb_take
    mov rax, [rip + bp_p]
    mov rcx, [rip + bp_end]
    sub rcx, rax
    cmp rdi, rcx
    ja 8f
    add [rip + bp_p], rdi
    ret
8:  xor eax, eax
    ret

# tsb_fields(ptr, len) -> eax the number of space-separated fields (at most 16) in tsb_f
FN tsb_fields
    xor ecx, ecx
    lea r8, [rip + tsb_f]
    add rsi, rdi
1:  cmp rdi, rsi
    jae 9f
    cmp byte ptr [rdi], ' '
    jne 2f
    inc rdi
    jmp 1b
2:  cmp ecx, 16
    jae 8f
    mov rax, rcx
    shl rax, 4
    mov [r8 + rax], rdi
    mov rdx, rdi
3:  cmp rdx, rsi
    jae 4f
    cmp byte ptr [rdx], ' '
    je 4f
    inc rdx
    jmp 3b
4:  mov r9, rdx
    sub r9, rdi
    mov [r8 + rax + 8], r9
    inc ecx
    mov rdi, rdx
    jmp 1b
8:  mov ecx, 17                 # more than 16: callers that count fields refuse the line
9:  mov [rip + tsb_n], rcx
    mov eax, ecx
    ret

# tsb_num(i) -> rax the decimal number in field i, rdx 1 when it is one (digits only, below 2^62)
FN tsb_num
    cmp rdi, [rip + tsb_n]
    jae 8f
    lea r8, [rip + tsb_f]
    shl rdi, 4
    mov rsi, [r8 + rdi + 8]
    mov rdi, [r8 + rdi]
    test rsi, rsi
    jz 8f
    cmp rsi, 18
    ja 8f
    xor eax, eax
    xor ecx, ecx
1:  movzx edx, byte ptr [rdi + rcx]
    sub edx, '0'
    cmp edx, 9
    ja 8f
    imul rax, rax, 10
    add rax, rdx
    inc rcx
    cmp rcx, rsi
    jb 1b
    mov edx, 1
    ret
8:  xor eax, eax
    xor edx, edx
    ret

# tsb_is(i, cstr) -> eax 1 when field i is that word
FN tsb_is
    cmp rdi, [rip + tsb_n]
    jae 8f
    mov rdx, rsi
    lea r8, [rip + tsb_f]
    shl rdi, 4
    mov rsi, [r8 + rdi + 8]
    mov rdi, [r8 + rdi]
    jmp str_eq_cstr
8:  xor eax, eax
    ret

# tsb_field(i) -> rax ptr, rdx len of field i (0, 0 past the last)
FN tsb_field
    cmp rdi, [rip + tsb_n]
    jae 8f
    lea r8, [rip + tsb_f]
    shl rdi, 4
    mov rax, [r8 + rdi]
    mov rdx, [r8 + rdi + 8]
    ret
8:  xor eax, eax
    xor edx, edx
    ret

# tsb_oneline(ptr, len) -> eax 1 when the bytes hold no LF, CR or NUL
FN tsb_oneline
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 7f
    movzx eax, byte ptr [rdi + rcx]
    inc rcx
    cmp eax, 10
    je 8f
    cmp eax, 13
    je 8f
    test eax, eax
    jz 8f
    jmp 1b
7:  mov eax, 1
    ret
8:  xor eax, eax
    ret

# ---------------- controllers ----------------

# testmodel_ctrl(ext) -> TSC* or 0
FN testmodel_ctrl
    lea rax, [rip + g_ts_ctrls]
    lea rcx, [rax + TSC_SIZE * TS_CTRL_MAX]
1:  cmp [rax + TSC_ext], rdi
    je 9f
    add rax, TSC_SIZE
    cmp rax, rcx
    jb 1b
    xor eax, eax
9:  ret

# testmodel_ctrl_make(ext) -> TSC*, made with its row (item 0, labelled with the extension's
# title) when it had none; 0 when every slot is taken
FN testmodel_ctrl_make
    PROLOGUE
    mov rbx, rdi
    call testmodel_ctrl
    test rax, rax
    jnz 9f
    xor edi, edi
    call testmodel_ctrl
    test rax, rax
    jz 9f
    mov r12, rax
    mov [r12 + TSC_ext], rbx
    mov dword ptr [r12 + TSC_free], -1
    mov dword ptr [r12 + TSC_count], 0
    mov dword ptr [r12 + TSC_ready], 0
    lea rdi, [r12 + TSC_items]
    mov esi, TSI_SIZE
    call vec_push
    mov r13, rax
    lea rdi, [rip + .Lempty]
    xor esi, esi
    call mem_dup
    mov [r13 + TSI_id], rax
    mov rdi, [rbx + EXT_title]
    test rdi, rdi
    jnz 1f
    mov rdi, [rbx + EXT_name]
1:  call strlen
    mov rsi, rax
    mov rdi, [rbx + EXT_title]
    test rdi, rdi
    jnz 2f
    mov rdi, [rbx + EXT_name]
2:  call mem_dup
    mov [r13 + TSI_label], rax
    mov dword ptr [r13 + TSI_kind], TSK_CTRL
    mov dword ptr [r13 + TSI_flags], TSF_EXPANDED
    mov dword ptr [r13 + TSI_parent], -1
    mov dword ptr [r13 + TSI_first], -1
    mov dword ptr [r13 + TSI_last], -1
    mov dword ptr [r13 + TSI_next], -1
    mov dword ptr [r13 + TSI_prev], -1
    mov dword ptr [r13 + TSI_ms], -1
    mov dword ptr [rip + g_ts_dirty], 3
    mov rax, r12
9:  EPILOGUE

# testmodel_forget(ext): the extension is removed: its runs, processes, items and results go
FN testmodel_forget
    PROLOGUE
    mov rbx, rdi
    call testexec_ext_gone
    # its runs, whatever their state
    lea r12, [rip + g_ts_runs]
    xor r13d, r13d
1:  cmp [r12 + TSR_ext], rbx
    jne 2f
    mov rdi, r12
    call run_free
2:  add r12, TSR_SIZE
    inc r13d
    cmp r13d, TS_RUNS_MAX
    jb 1b
    mov rdi, rbx
    call testproto_forget_requests
    mov rdi, rbx
    call testgutter_forget      # its problems
    mov rdi, rbx
    call testmodel_ctrl
    test rax, rax
    jz 9f
    mov r12, rax
    # every item, row 0 included
    xor r13d, r13d
3:  cmp r13, [r12 + TSC_items + VEC_len]
    jae 4f
    imul rdi, r13, TSI_SIZE
    add rdi, [r12 + TSC_items + VEC_ptr]
    cmp qword ptr [rdi + TSI_id], 0
    je 31f
    cmp r13, 0
    je 30f
    dec qword ptr [rip + g_ts_items_all]
30: call item_strings_free
31: inc r13
    jmp 3b
4:  lea rdi, [r12 + TSC_items]
    call vec_free
    mov rdi, [r12 + TSC_map]
    call mem_free
    mov rdi, r12
    xor esi, esi
    mov edx, TSC_SIZE
    call memset
    mov rdi, rbx
    call testview_forget
    mov dword ptr [rip + g_ts_dirty], 3
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# ---------------- items ----------------

# testmodel_item(tsc, index) -> TSI*
FN testmodel_item
    imul rax, rsi, TSI_SIZE
    add rax, [rdi + TSC_items + VEC_ptr]
    ret

# testmodel_live(tsc, index, gen) -> eax 1 when that slot still holds the item with that generation
FN testmodel_live
    test esi, esi
    js 8f
    mov esi, esi
    cmp rsi, [rdi + TSC_items + VEC_len]
    jae 8f
    imul rax, rsi, TSI_SIZE
    add rax, [rdi + TSC_items + VEC_ptr]
    cmp qword ptr [rax + TSI_id], 0
    je 8f
    cmp [rax + TSI_gen], edx
    jne 8f
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# testmodel_find(tsc, id, len) -> rax the item's index, or -1
FN testmodel_find
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp qword ptr [rbx + TSC_mapcap], 0
    je 8f
    mov rdi, r12
    mov rsi, r13
    call hash_line
    mov r14, [rbx + TSC_mapcap]
    dec r14                     # mask
    and rax, r14
    mov r15, rax
1:  mov rcx, [rbx + TSC_map]
    mov eax, [rcx + r15*4]
    test eax, eax
    jz 8f
    dec eax
    imul rcx, rax, TSI_SIZE
    add rcx, [rbx + TSC_items + VEC_ptr]
    cmp [rcx + TSI_idlen], r13d
    jne 2f
    push rax
    push rax
    mov rdi, [rcx + TSI_id]
    mov rsi, r12
    mov rdx, r13
    call memeq
    mov ecx, eax
    pop rax
    pop rdx
    test ecx, ecx
    jnz 9f
2:  inc r15
    and r15, r14
    jmp 1b
8:  mov rax, -1
9:  EPILOGUE

# map_home(tsc, index) -> rax the slot the item's id hashes to
map_home:
    push rbx
    mov rbx, rdi
    imul rax, rsi, TSI_SIZE
    add rax, [rbx + TSC_items + VEC_ptr]
    mov rdi, [rax + TSI_id]
    mov esi, [rax + TSI_idlen]
    call hash_line
    mov rcx, [rbx + TSC_mapcap]
    dec rcx
    and rax, rcx
    pop rbx
    ret

# map_insert(tsc, index): the item's id goes into the map (grown at half load)
map_insert:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + TSC_mapn]
    inc rax
    add rax, rax
    cmp rax, [rbx + TSC_mapcap]
    jbe 1f
    mov rdi, rbx
    mov rsi, r12
    call map_grow
1:  mov rdi, rbx
    mov rsi, r12
    call map_home
    mov r13, [rbx + TSC_mapcap]
    dec r13
2:  mov rcx, [rbx + TSC_map]
    cmp dword ptr [rcx + rax*4], 0
    je 3f
    inc rax
    and rax, r13
    jmp 2b
3:  lea rdx, [r12 + 1]
    mov [rcx + rax*4], edx
    inc qword ptr [rbx + TSC_mapn]
    EPILOGUE

# map_grow(tsc, skip): twice the slots (64 at first), every live item but skip inserted again
map_grow:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    mov r12, [rbx + TSC_mapcap]
    add r12, r12
    mov eax, 64
    cmp r12, rax
    cmovb r12, rax
    lea rdi, [r12*4]
    call mem_alloc
    mov r13, rax
    mov rdi, rax
    xor esi, esi
    lea rdx, [r12*4]
    call memset
    mov rdi, [rbx + TSC_map]
    call mem_free
    mov [rbx + TSC_map], r13
    mov [rbx + TSC_mapcap], r12
    mov qword ptr [rbx + TSC_mapn], 0
    xor r14d, r14d
1:  cmp r14, [rbx + TSC_items + VEC_len]
    jae 9f
    imul rax, r14, TSI_SIZE
    add rax, [rbx + TSC_items + VEC_ptr]
    cmp qword ptr [rax + TSI_id], 0
    je 3f
    test r14, r14
    jz 3f                       # row 0 is never looked up
    cmp r14, [rsp]
    je 3f                       # the item being inserted
    mov rdi, rbx
    mov rsi, r14
    call map_home
    lea r15, [r12 - 1]
2:  mov rcx, [rbx + TSC_map]
    cmp dword ptr [rcx + rax*4], 0
    je 21f
    inc rax
    and rax, r15
    jmp 2b
21: lea rdx, [r14 + 1]
    mov [rcx + rax*4], edx
    inc qword ptr [rbx + TSC_mapn]
3:  inc r14
    jmp 1b
9:  EPILOGUE

# map_delete(tsc, index): its slot empties; the run after it shifts back (linear probing)
map_delete:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp qword ptr [rbx + TSC_mapcap], 0
    je 9f
    mov rdi, rbx
    mov rsi, r12
    call map_home
    mov r13, [rbx + TSC_mapcap]
    dec r13                     # mask
    lea rdx, [r12 + 1]
1:  mov rcx, [rbx + TSC_map]
    mov esi, [rcx + rax*4]
    test esi, esi
    jz 9f                       # not there
    cmp esi, edx
    je 2f
    inc rax
    and rax, r13
    jmp 1b
2:  mov r14, rax                # i: the hole
    mov r15, rax                # j
3:  inc r15
    and r15, r13
    mov rcx, [rbx + TSC_map]
    mov esi, [rcx + r15*4]
    test esi, esi
    jz 8f
    dec esi
    mov rdi, rbx
    call map_home               # k: where the entry at j belongs
    # it moves into the hole unless k lies cyclically in (i, j]
    cmp r14, r15
    ja 5f
    cmp rax, r14
    jbe 6f
    cmp rax, r15
    ja 6f
    jmp 3b
5:  cmp rax, r14
    ja 3b
    cmp rax, r15
    jbe 3b
6:  mov rcx, [rbx + TSC_map]
    mov esi, [rcx + r15*4]
    mov [rcx + r14*4], esi
    mov r14, r15
    jmp 3b
8:  mov rcx, [rbx + TSC_map]
    mov dword ptr [rcx + r14*4], 0
    dec qword ptr [rbx + TSC_mapn]
9:  EPILOGUE

# item_alloc(tsc) -> rax a fresh item's index (zeroed, links -1, generation kept); the items may
# move, so callers fetch pointers again after it
item_alloc:
    PROLOGUE
    mov rbx, rdi
    movsxd rax, dword ptr [rbx + TSC_free]
    test rax, rax
    js 1f
    mov r12, rax
    imul r13, rax, TSI_SIZE
    add r13, [rbx + TSC_items + VEC_ptr]
    mov eax, [r13 + TSI_next]
    mov [rbx + TSC_free], eax
    mov r14d, [r13 + TSI_gen]
    mov rdi, r13
    xor esi, esi
    mov edx, TSI_SIZE
    call memset
    mov [r13 + TSI_gen], r14d
    jmp 2f
1:  mov r12, [rbx + TSC_items + VEC_len]
    lea rdi, [rbx + TSC_items]
    mov esi, TSI_SIZE
    call vec_push
    mov r13, rax
2:  mov dword ptr [r13 + TSI_parent], -1
    mov dword ptr [r13 + TSI_first], -1
    mov dword ptr [r13 + TSI_last], -1
    mov dword ptr [r13 + TSI_next], -1
    mov dword ptr [r13 + TSI_prev], -1
    mov dword ptr [r13 + TSI_ms], -1
    inc dword ptr [rbx + TSC_count]
    inc qword ptr [rip + g_ts_items_all]
    mov rax, r12
    EPILOGUE

# item_strings_free(TSI*): its owned strings
item_strings_free:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + TSI_id]
    call mem_free
    mov rdi, [rbx + TSI_label]
    call mem_free
    mov rdi, [rbx + TSI_desc]
    call mem_free
    mov rdi, [rbx + TSI_error]
    call mem_free
    mov rdi, [rbx + TSI_path]
    call mem_free
    mov rdi, [rbx + TSI_msg]
    call mem_free
    xor eax, eax
    mov [rbx + TSI_id], rax
    mov [rbx + TSI_label], rax
    mov [rbx + TSI_desc], rax
    mov [rbx + TSI_error], rax
    mov [rbx + TSI_path], rax
    mov [rbx + TSI_msg], rax
    pop rbx
    ret

# item_link(tsc, index, parent): the item becomes the parent's last child, and the parent's state
# takes it in
item_link:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    mov r14, rax
    mov rdi, rbx
    mov rsi, r13
    call testmodel_item
    mov r15, rax
    mov [r14 + TSI_parent], r13d
    mov dword ptr [r14 + TSI_next], -1
    mov eax, [r15 + TSI_last]
    mov [r14 + TSI_prev], eax
    test eax, eax
    js 1f
    mov rdi, rbx
    movsxd rsi, eax
    call testmodel_item
    mov [rax + TSI_next], r12d
    jmp 2f
1:  mov [r15 + TSI_first], r12d
2:  mov [r15 + TSI_last], r12d
    mov eax, [r14 + TSI_state]
    inc dword ptr [r15 + TSI_cnt + rax*4]
    mov rdi, rbx
    mov rsi, r13
    call item_propagate
    EPILOGUE

# item_unlink(tsc, index): out of its parent's children (a no-op without a parent)
item_unlink:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call testmodel_item
    mov r14, rax
    movsxd r13, dword ptr [r14 + TSI_parent]
    test r13, r13
    js 9f
    mov rdi, rbx
    mov rsi, r13
    call testmodel_item
    mov r15, rax
    movsxd rsi, dword ptr [r14 + TSI_prev]
    mov ecx, [r14 + TSI_next]
    test rsi, rsi
    js 1f
    mov rdi, rbx
    call testmodel_item
    mov ecx, [r14 + TSI_next]
    mov [rax + TSI_next], ecx
    jmp 2f
1:  mov [r15 + TSI_first], ecx
2:  movsxd rsi, dword ptr [r14 + TSI_next]
    mov ecx, [r14 + TSI_prev]
    test rsi, rsi
    js 3f
    mov rdi, rbx
    call testmodel_item
    mov ecx, [r14 + TSI_prev]
    mov [rax + TSI_prev], ecx
    jmp 4f
3:  mov [r15 + TSI_last], ecx
4:  mov eax, [r14 + TSI_state]
    dec dword ptr [r15 + TSI_cnt + rax*4]
    mov dword ptr [r14 + TSI_parent], -1
    mov dword ptr [r14 + TSI_next], -1
    mov dword ptr [r14 + TSI_prev], -1
    mov rdi, rbx
    mov rsi, r13
    call item_propagate
9:  EPILOGUE

# item_propagate(tsc, index): its derived state again from its own and its children's counts; a
# change goes on up to the parents
item_propagate:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
1:  test r12, r12
    js 9f
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    mov r13, rax
    mov ecx, TSS_COUNT - 1
2:  cmp ecx, [r13 + TSI_own]
    jbe 3f                      # its own state is at least this high
    cmp dword ptr [r13 + TSI_cnt + rcx*4], 0
    jne 3f
    dec ecx
    jmp 2b
3:  mov edx, [r13 + TSI_state]
    cmp ecx, edx
    je 9f
    mov [r13 + TSI_state], ecx
    mov dword ptr [rip + g_ts_glyphs], 1
    movsxd r12, dword ptr [r13 + TSI_parent]
    test r12, r12
    js 9f
    mov r14d, ecx
    mov r15d, edx
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    dec dword ptr [rax + TSI_cnt + r15*4]
    inc dword ptr [rax + TSI_cnt + r14*4]
    jmp 1b
9:  mov dword ptr [rip + g_ts_dirty], 3
    EPILOGUE

# testmodel_set_own(tsc, index, state): its own result's state, and its ancestors' derived ones
FN testmodel_set_own
    push rbx
    mov rbx, rdi
    push rsi
    call testmodel_item
    mov [rax + TSI_own], edx
    pop rsi
    mov rdi, rbx
    call item_propagate
    pop rbx
    ret

# item_remove(tsc, index): the item and its descendants go (their slots freed, generations bumped,
# their marks with them); row 0 never goes
item_remove:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call item_unlink
    mov qword ptr [rip + stack + VEC_len], 0
    lea rdi, [rip + stack]
    mov esi, 8
    call vec_push
    mov [rax], r12
1:  mov rax, [rip + stack + VEC_len]
    test rax, rax
    jz 9f
    dec rax
    mov [rip + stack + VEC_len], rax
    mov rcx, [rip + stack + VEC_ptr]
    mov r12, [rcx + rax*8]
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    mov r13, rax
    # children onto the stack
    movsxd r14, dword ptr [r13 + TSI_first]
2:  test r14, r14
    js 3f
    lea rdi, [rip + stack]
    mov esi, 8
    call vec_push
    mov [rax], r14
    mov rdi, rbx
    mov rsi, r14
    call testmodel_item
    movsxd r14, dword ptr [rax + TSI_next]
    jmp 2b
3:  mov rdi, rbx
    mov rsi, r12
    call map_delete
    mov rdi, [rbx + TSC_ext]
    mov rsi, r12
    call testgutter_item_gone   # its glyph and failure marks
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    mov r13, rax
    mov rdi, r13
    call item_strings_free
    inc dword ptr [r13 + TSI_gen]
    mov eax, [rbx + TSC_free]
    mov [r13 + TSI_next], eax
    mov [rbx + TSC_free], r12d
    dec dword ptr [rbx + TSC_count]
    dec qword ptr [rip + g_ts_items_all]
    jmp 1b
9:  mov dword ptr [rip + g_ts_dirty], 3
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# testmodel_remove_id(tsc, id, len) -> eax 1 when an item with that id was there and went
FN testmodel_remove_id
    push rbx
    mov rbx, rdi
    call testmodel_find
    test rax, rax
    js 8f
    jz 8f
    mov rdi, rbx
    mov rsi, rax
    call item_remove
    mov eax, 1
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret

# testmodel_is_under(tsc, index, ancestor) -> eax 1 when the item is the ancestor or below it
FN testmodel_is_under
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
1:  test r12, r12
    js 8f
    cmp r12, r13
    je 7f
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    movsxd r12, dword ptr [rax + TSI_parent]
    jmp 1b
7:  mov eax, 1
    jmp 9f
8:  xor eax, eax
9:  pop r13
    pop r12
    pop rbx
    ret

# ---------------- items bodies ----------------

# testmodel_items(tsc, replace, body, len, want, want_len) -> rax 0 when applied, else the error
#   reply's text ("syntax ...", "toobig ...", "refused ..."), and nothing changed. The body:
#   "PARENT_LEN N" LF PARENT, then N items "KIND L1 C1 L2 C2 FLAGS ID_LEN LABEL_LEN PATH_LEN
#   EXTRA_LEN" LF ID LABEL PATH EXTRA. want (want_len >= 0): the parent the body must be for (a
#   tests-resolve answer)
FN testmodel_items
    PROLOGUE 64
    mov rbx, rdi
    mov [rip + ib_tsc], rdi
    mov [rip + ib_mode], rsi
    mov [rsp], rdx              # the body
    mov [rsp + 8], rcx
    mov [rsp + 16], r8
    mov [rsp + 24], r9
    mov rdi, rdx
    mov rsi, rcx
    call tsb_begin
    call tsb_line
    test rax, rax
    jz .Lti_syntax
    mov rdi, rax
    mov rsi, rdx
    call tsb_fields
    cmp eax, 2
    jne .Lti_syntax
    xor edi, edi
    call tsb_num
    test edx, edx
    jz .Lti_syntax
    cmp rax, TS_ID_MAX
    ja .Lti_syntax
    mov r12, rax                # parent length
    mov edi, 1
    call tsb_num
    test edx, edx
    jz .Lti_syntax
    cmp rax, TS_ITEMS_BODY
    ja .Lti_toobig_body
    mov r13, rax                # N
    mov rdi, r12
    call tsb_take
    test rax, rax
    jz .Lti_syntax
    mov r14, rax                # parent bytes
    # a tests-resolve answer is for the parent asked about
    mov rcx, [rsp + 24]
    test rcx, rcx
    js 1f
    cmp rcx, r12
    jne .Lti_other_parent
    mov rdi, r14
    mov rsi, [rsp + 16]
    mov rdx, r12
    call memeq
    test eax, eax
    jz .Lti_other_parent
1:  xor eax, eax                # an empty parent is row 0
    test r12, r12
    jz 2f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r12
    call testmodel_find
    test rax, rax
    js .Lti_unknown_parent
2:  mov [rip + ib_parent], rax
    mov [rsp + 32], rax
    # pass 1: every item parses, the caps hold, no item would become its own ancestor
    call tsb_left
    mov [rsp + 40], rax         # where the items start, as bytes left
    mov qword ptr [rip + ib_new], 0
    mov qword ptr [rip + ib_moved + VEC_len], 0
    mov qword ptr [rsp + 48], 0 # replace: the items its removals take away
    cmp qword ptr [rip + ib_mode], 0
    je 21f
    mov rdi, rbx                # the parent's children lose their marks; pass 1 marks those kept
    mov rsi, [rsp + 32]
    call clear_marks
21: xor r15d, r15d
3:  cmp r15, r13
    jae 4f
    call item_parse
    test rax, rax
    jnz .Lti_fail_moved
    inc r15
    jmp 3b
4:  call tsb_left
    test rax, rax
    jz 40f
    lea rax, [rip + .Le_syntax_items]
    jmp .Lti_fail_moved
40:
    cmp qword ptr [rip + ib_mode], 0
    je 42f
    # replace: what goes with the children not kept counts against what comes
    mov rdi, rbx
    mov rsi, [rsp + 32]
    call testmodel_item
    movsxd r14, dword ptr [rax + TSI_first]
41: test r14, r14
    js 42f
    mov rdi, rbx
    mov rsi, r14
    call testmodel_item
    movsxd r15, dword ptr [rax + TSI_next]
    test dword ptr [rax + TSI_flags], TSF_MARK
    jnz 43f
    mov rdi, rbx
    mov rsi, r14
    call subtree_size
    add [rsp + 48], rax
43: mov r14, r15
    jmp 41b
42: mov rdi, rbx
    call clear_moved
    mov eax, [rbx + TSC_count]
    add rax, [rip + ib_new]
    sub rax, [rsp + 48]
    cmp rax, TS_ITEMS_EXT
    jg .Lti_toobig_ext
    mov rax, [rip + g_ts_items_all]
    add rax, [rip + ib_new]
    sub rax, [rsp + 48]
    cmp rax, TS_ITEMS_ALL
    jg .Lti_toobig_all
    # pass 2: apply
    mov rdi, [rsp]
    add rdi, [rsp + 8]
    sub rdi, [rsp + 40]
    mov rsi, [rsp + 40]
    call tsb_begin
    cmp qword ptr [rip + ib_mode], 0
    je 5f
    # replace: the parent's children lose their marks; each one in the body gets it back
    mov rdi, rbx
    mov rsi, [rsp + 32]
    call testmodel_item
    movsxd r14, dword ptr [rax + TSI_first]
41: test r14, r14
    js 5f
    mov rdi, rbx
    mov rsi, r14
    call testmodel_item
    and dword ptr [rax + TSI_flags], ~TSF_MARK
    movsxd r14, dword ptr [rax + TSI_next]
    jmp 41b
5:  xor r15d, r15d
6:  cmp r15, r13
    jae 7f
    call item_apply
    inc r15
    jmp 6b
7:  cmp qword ptr [rip + ib_mode], 0
    je 8f
    # replace: the children not in the body go, with their descendants
    mov rdi, rbx
    mov rsi, [rsp + 32]
    call testmodel_item
    movsxd r14, dword ptr [rax + TSI_first]
71: test r14, r14
    js 8f
    mov rdi, rbx
    mov rsi, r14
    call testmodel_item
    movsxd r15, dword ptr [rax + TSI_next]
    test dword ptr [rax + TSI_flags], TSF_MARK
    jnz 72f
    mov rdi, rbx
    mov rsi, r14
    call item_remove
    jmp 73f
72: and dword ptr [rax + TSI_flags], ~TSF_MARK
73: mov r14, r15
    jmp 71b
8:  mov dword ptr [rip + g_ts_dirty], 3
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE
.Lti_fail_moved:
    mov r14, rax                # pass 1 failed: the items it marked as moving lose the mark
    mov rdi, rbx
    call clear_moved
    mov rax, r14
.Lti_fail:
    EPILOGUE
.Lti_syntax_trailing:
.Lti_syntax:
    lea rax, [rip + .Le_syntax_items]
    EPILOGUE
.Lti_toobig_body:
    lea rax, [rip + .Le_toobig_body]
    EPILOGUE
.Lti_toobig_ext:
    lea rax, [rip + .Le_toobig_ext]
    EPILOGUE
.Lti_toobig_all:
    lea rax, [rip + .Le_toobig_all]
    EPILOGUE
.Lti_unknown_parent:
    lea rax, [rip + .Le_unknown_parent]
    EPILOGUE
.Lti_other_parent:
    lea rax, [rip + .Le_other_parent]
    EPILOGUE

# item_header() -> rax 0 with the item's header fields in tsb_f and its bytes in it_*, else the
#   error text: the shared first half of item_parse and item_apply
.bss
.p2align 3
it_kind: .quad 0
it_flags: .quad 0
it_l1: .quad 0
it_c1: .quad 0
it_l2: .quad 0
it_c2: .quad 0
it_id: .quad 0
it_idlen: .quad 0
it_label: .quad 0
it_labellen: .quad 0
it_path: .quad 0
it_pathlen: .quad 0
it_desc: .quad 0
it_desclen: .quad 0
it_err: .quad 0
it_errlen: .quad 0
it_extra: .quad 0
it_extralen: .quad 0
.text
item_header:
    PROLOGUE
    call tsb_line
    test rax, rax
    jz .Lih_syntax
    mov rdi, rax
    mov rsi, rdx
    call tsb_fields
    cmp eax, 10
    jne .Lih_syntax
    # the kind
    lea r12, [rip + kind_words]
    mov r13d, 1
1:  mov rsi, [r12 + r13*8]
    test rsi, rsi
    jz .Lih_syntax
    xor edi, edi
    call tsb_is
    test eax, eax
    jnz 2f
    inc r13d
    jmp 1b
2:  mov [rip + it_kind], r13
    # the range: all 0, or L1 C1 at or before L2 C2, all at least 1
    mov edi, 1
    call tsb_num
    test edx, edx
    jz .Lih_syntax
    mov [rip + it_l1], rax
    mov edi, 2
    call tsb_num
    test edx, edx
    jz .Lih_syntax
    mov [rip + it_c1], rax
    mov edi, 3
    call tsb_num
    test edx, edx
    jz .Lih_syntax
    mov [rip + it_l2], rax
    mov edi, 4
    call tsb_num
    test edx, edx
    jz .Lih_syntax
    mov [rip + it_c2], rax
    mov rax, [rip + it_l1]
    or rax, [rip + it_c1]
    or rax, [rip + it_l2]
    or rax, [rip + it_c2]
    jz 3f
    mov rax, [rip + it_l1]
    test rax, rax
    jz .Lih_badpos
    cmp qword ptr [rip + it_c1], 0
    je .Lih_badpos
    cmp qword ptr [rip + it_c2], 0
    je .Lih_badpos
    mov rcx, 0x7fffffff
    cmp rax, rcx
    ja .Lih_badpos
    cmp [rip + it_l2], rcx
    ja .Lih_badpos
    cmp [rip + it_c1], rcx
    ja .Lih_badpos
    cmp [rip + it_c2], rcx
    ja .Lih_badpos
    cmp [rip + it_l2], rax
    jb .Lih_badpos
    ja 3f
    mov rax, [rip + it_c2]
    cmp rax, [rip + it_c1]
    jb .Lih_badpos
3:  # the flags: "-" or a comma list of lazy and nodebug
    mov qword ptr [rip + it_flags], 0
    mov edi, 5
    call tsb_field
    cmp rdx, 1
    jne 4f
    cmp byte ptr [rax], '-'
    je 6f
4:  mov r12, rax
    lea r13, [rax + rdx]
41: cmp r12, r13
    jae 6f
    mov rcx, r12
42: cmp rcx, r13
    jae 43f
    cmp byte ptr [rcx], ','
    je 43f
    inc rcx
    jmp 42b
43: mov r14, rcx
    mov rdi, r12
    mov rsi, rcx
    sub rsi, r12
    lea rdx, [rip + .Lf_lazy]
    call str_eq_cstr
    test eax, eax
    jz 44f
    or qword ptr [rip + it_flags], TSF_LAZY
    jmp 45f
44: mov rdi, r12
    mov rsi, r14
    sub rsi, r12
    lea rdx, [rip + .Lf_nodebug]
    call str_eq_cstr
    test eax, eax
    jz .Lih_syntax              # an unknown flag
    or qword ptr [rip + it_flags], TSF_NODEBUG
45: lea r12, [r14 + 1]
    jmp 41b
6:  # the lengths, then the bytes
    mov edi, 6
    call tsb_num
    test edx, edx
    jz .Lih_syntax
    test rax, rax
    jz .Lih_syntax
    cmp rax, TS_ID_MAX
    ja .Lih_syntax
    mov [rip + it_idlen], rax
    mov edi, 7
    call tsb_num
    test edx, edx
    jz .Lih_syntax
    cmp rax, TS_LABEL_MAX
    ja .Lih_syntax
    mov [rip + it_labellen], rax
    mov edi, 8
    call tsb_num
    test edx, edx
    jz .Lih_syntax
    cmp rax, 4096
    jae .Lih_syntax
    mov [rip + it_pathlen], rax
    mov edi, 9
    call tsb_num
    test edx, edx
    jz .Lih_syntax
    mov [rip + it_extralen], rax
    mov rdi, [rip + it_idlen]
    call tsb_take
    test rax, rax
    jz .Lih_syntax
    mov [rip + it_id], rax
    mov rdi, rax
    mov rsi, [rip + it_idlen]
    call tsb_oneline
    test eax, eax
    jz .Lih_syntax
    mov rdi, [rip + it_labellen]
    call tsb_take
    test rax, rax
    jz .Lih_syntax
    mov [rip + it_label], rax
    mov rdi, rax
    mov rsi, [rip + it_labellen]
    call tsb_oneline
    test eax, eax
    jz .Lih_syntax
    mov rdi, [rip + it_pathlen]
    call tsb_take
    test rax, rax
    jz .Lih_syntax
    mov [rip + it_path], rax
    mov rdi, rax
    mov rsi, [rip + it_pathlen]
    call tsb_oneline
    test eax, eax
    jz .Lih_syntax
    mov rdi, [rip + it_extralen]
    call tsb_take
    test rax, rax
    jz .Lih_syntax
    mov [rip + it_extra], rax
    # a range needs a file; a file is absolute or #DOC
    cmp qword ptr [rip + it_l1], 0
    je 7f
    cmp qword ptr [rip + it_pathlen], 0
    je .Lih_badpos
7:  cmp qword ptr [rip + it_pathlen], 0
    je 8f
    mov rax, [rip + it_path]
    cmp byte ptr [rax], '#'
    je 8f
    mov rdi, [rip + it_path]
    mov rsi, [rip + it_pathlen]
    call mem_dup
    mov r12, rax
    mov rdi, rax
    call path_rootlen
    mov r13, rax
    mov rdi, r12
    call mem_free
    test r13, r13
    jz .Lih_relative
8:  # the extra records: desc LEN, error LEN; others are skipped
    mov qword ptr [rip + it_desc], 0
    mov qword ptr [rip + it_desclen], 0
    mov qword ptr [rip + it_err], 0
    mov qword ptr [rip + it_errlen], 0
    mov r12, [rip + it_extra]
    mov r13, [rip + it_extralen]
    add r13, r12
9:  cmp r12, r13
    jae .Lih_ok
    mov rdi, r12
    mov rsi, r13
    call extra_record           # rax: name ptr, rdx name len, rcx body ptr, r8 body len, r9 next
    test rax, rax
    jz .Lih_syntax
    mov r12, r9
    mov r14, rcx
    mov r15, r8
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lx_desc]
    call str_eq_cstr
    pop rdx
    pop rcx
    test eax, eax
    jz 91f
    cmp r15, TS_DESC_MAX
    ja .Lih_syntax
    mov rdi, r14
    mov rsi, r15
    call tsb_oneline
    test eax, eax
    jz .Lih_syntax
    mov [rip + it_desc], r14
    mov [rip + it_desclen], r15
    jmp 9b
91: mov rdi, rcx
    mov rsi, rdx
    lea rdx, [rip + .Lx_error]
    call str_eq_cstr
    test eax, eax
    jz 9b
    cmp r15, TS_ERROR_MAX
    ja .Lih_syntax
    mov [rip + it_err], r14
    mov [rip + it_errlen], r15
    jmp 9b
.Lih_ok:
    xor eax, eax
    EPILOGUE
.Lih_syntax:
    lea rax, [rip + .Le_syntax_items]
    EPILOGUE
.Lih_badpos:
    lea rax, [rip + .Le_badpos_items]
    EPILOGUE
.Lih_relative:
    lea rax, [rip + .Le_relative]
    EPILOGUE

# FN testmodel_extra(ptr, end) -> extra_record for other bodies
FN testmodel_extra
    jmp extra_record

# extra_record(ptr, end) -> rax the record's name, rdx its length, rcx its body, r8 the body's
#   length, r9 where the next record starts; rax 0 when it is malformed. A record is a line "NAME
#   ARGS... LEN" and LEN bytes; tsb_f holds the line's fields after it
extra_record:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rcx, r12
1:  cmp rcx, r13
    jae 8f
    cmp byte ptr [rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov r14, rcx                # the LF
    mov rdi, r12
    mov rsi, rcx
    sub rsi, r12
    call tsb_fields
    cmp eax, 2
    jb 8f
    cmp eax, 16
    ja 8f
    lea rdi, [rax - 1]
    call tsb_num
    test edx, edx
    jz 8f
    lea rcx, [r14 + 1]
    mov rdx, r13
    sub rdx, rcx
    cmp rax, rdx
    ja 8f
    mov r8, rax
    lea r9, [rcx + rax]
    mov rax, [rip + tsb_f]
    mov rdx, [rip + tsb_f + 8]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# item_parse() -> rax 0 or the error text: pass 1 for one item (counts the new ids, refuses a
#   move under itself)
item_parse:
    PROLOGUE
    call item_header
    test rax, rax
    jnz 9f
    mov rbx, [rip + ib_tsc]
    mov rdi, rbx
    mov rsi, [rip + it_id]
    mov rdx, [rip + it_idlen]
    call testmodel_find
    test rax, rax
    jns 1f
    inc qword ptr [rip + ib_new]
    xor eax, eax
    jmp 9f
1:  # an item that exists moves under the parent: not when the parent is the item or below it
    mov r12, rax
    mov rdi, rbx
    mov rsi, [rip + ib_parent]
    mov rdx, rax
    call testmodel_is_under
    test eax, eax
    jnz 11f
    mov rdi, rbx                # a child kept by a replace
    mov rsi, r12
    call testmodel_item
    movsxd rcx, dword ptr [rax + TSI_parent]
    cmp rcx, [rip + ib_parent]
    jne 12f
    or dword ptr [rax + TSI_flags], TSF_MARK
    jmp 2f
12: # one a replace moves here from elsewhere keeps its subtree: not counted as removed
    cmp qword ptr [rip + ib_mode], 0
    je 2f
    test dword ptr [rax + TSI_flags], TSF_MOVE
    jnz 2f
    or dword ptr [rax + TSI_flags], TSF_MOVE
    lea rdi, [rip + ib_moved]
    mov esi, 8
    call vec_push
    mov [rax], r12
    jmp 2f
11:
    lea rax, [rip + .Le_cycle]
    jmp 9f
2:  # a #DOC path names an open document with a file
    xor eax, eax
    cmp qword ptr [rip + it_pathlen], 0
    je 9f
9:  EPILOGUE

# item_apply(): pass 2 for one item (it parsed in pass 1)
item_apply:
    PROLOGUE
    call item_header
    mov rbx, [rip + ib_tsc]
    mov rdi, rbx
    mov rsi, [rip + it_id]
    mov rdx, [rip + it_idlen]
    call testmodel_find
    mov r12, rax
    test rax, rax
    jns 1f
    mov rdi, rbx
    call item_alloc
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    mov r13, rax
    mov rdi, [rip + it_id]
    mov rsi, [rip + it_idlen]
    call mem_dup
    mov [r13 + TSI_id], rax
    mov rax, [rip + it_idlen]
    mov [r13 + TSI_idlen], eax
    mov rdi, rbx
    mov rsi, r12
    call map_insert
    jmp 2f
1:  # it exists: out of its old place (replace puts the body's items in its order)
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    movsxd rcx, dword ptr [rax + TSI_parent]
    cmp qword ptr [rip + ib_mode], 0
    jne 11f
    cmp rcx, [rip + ib_parent]
    je 3f                       # add keeps an item where it is
11: mov rdi, rbx
    mov rsi, r12
    call item_unlink
2:  mov rdi, rbx
    mov rsi, r12
    mov rdx, [rip + ib_parent]
    call item_link
3:  mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    mov r13, rax
    or dword ptr [r13 + TSI_flags], TSF_MARK
    mov rax, [rip + it_kind]
    mov [r13 + TSI_kind], eax
    mov eax, [r13 + TSI_flags]
    and eax, ~(TSF_LAZY | TSF_NODEBUG)
    or rax, [rip + it_flags]
    mov [r13 + TSI_flags], eax
    mov rax, [rip + it_l1]
    mov [r13 + TSI_l1], eax
    mov rax, [rip + it_c1]
    mov [r13 + TSI_c1], eax
    mov rax, [rip + it_l2]
    mov [r13 + TSI_l2], eax
    mov rax, [rip + it_c2]
    mov [r13 + TSI_c2], eax
    lea rdi, [r13 + TSI_label]
    mov rsi, [rip + it_label]
    mov rdx, [rip + it_labellen]
    call set_str
    lea rdi, [r13 + TSI_desc]
    mov rsi, [rip + it_desc]
    mov rdx, [rip + it_desclen]
    call set_str_opt
    lea rdi, [r13 + TSI_error]
    mov rsi, [rip + it_err]
    mov rdx, [rip + it_errlen]
    call set_str_opt
    # the file: absolute, or #DOC for an open document's file (none when it has none)
    mov rsi, [rip + it_path]
    mov rdx, [rip + it_pathlen]
    test rdx, rdx
    jz 5f
    cmp byte ptr [rsi], '#'
    jne 5f
    lea rdi, [rsi + 1]
    lea rsi, [rdx - 1]
    call parse_u64
    test rdx, rdx
    jz 50f
    mov rdi, rax
    call extproto_doc
    test rax, rax
    jz 50f
    mov rsi, [rax + DOC_path]
    test rsi, rsi
    jz 50f
    mov rdi, rsi
    push rsi
    push rsi
    call strlen
    mov rdx, rax
    pop rsi
    pop rsi
    jmp 5f
50: xor esi, esi                # a document without a file: no file
    xor edx, edx
5:  lea rdi, [r13 + TSI_path]
    call set_str_opt
    mov qword ptr [r13 + TSI_phash], 0
    mov rdi, [r13 + TSI_path]
    test rdi, rdi
    jz 6f
    call strlen
    mov rsi, rax
    mov rdi, [r13 + TSI_path]
    call hash_line
    mov [r13 + TSI_phash], rax
6:  mov rdi, [r13 + TSI_path]
    call testgutter_doc_ver
    mov [r13 + TSI_ver], rax
    mov dword ptr [rip + g_ts_glyphs], 1
    mov rdi, [rbx + TSC_ext]
    mov rsi, r12
    call testgutter_item_changed
    EPILOGUE

# clear_marks(tsc, index): the item's children lose TSF_MARK
clear_marks:
    PROLOGUE
    mov rbx, rdi
    call testmodel_item
    movsxd r12, dword ptr [rax + TSI_first]
1:  test r12, r12
    js 9f
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    and dword ptr [rax + TSI_flags], ~TSF_MARK
    movsxd r12, dword ptr [rax + TSI_next]
    jmp 1b
9:  EPILOGUE

# clear_moved(tsc): the items pass 1 marked TSF_MOVE lose the mark
clear_moved:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + ib_moved + VEC_len]
    jae 9f
    mov rax, [rip + ib_moved + VEC_ptr]
    mov rsi, [rax + r12*8]
    mov rdi, rbx
    call testmodel_item
    and dword ptr [rax + TSI_flags], ~TSF_MOVE
    inc r12
    jmp 1b
9:  mov qword ptr [rip + ib_moved + VEC_len], 0
    EPILOGUE

# subtree_size(tsc, index) -> rax the item and its descendants, leaving out the subtrees a replace
#   moves elsewhere (TSF_MOVE)
subtree_size:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
    mov qword ptr [rip + stack + VEC_len], 0
    lea rdi, [rip + stack]
    mov esi, 8
    call vec_push
    mov [rax], r12
1:  mov rax, [rip + stack + VEC_len]
    test rax, rax
    jz 9f
    dec rax
    mov [rip + stack + VEC_len], rax
    mov rcx, [rip + stack + VEC_ptr]
    mov r12, [rcx + rax*8]
    inc r13
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    movsxd r14, dword ptr [rax + TSI_first]
2:  test r14, r14
    js 1b
    mov rdi, rbx
    mov rsi, r14
    call testmodel_item
    test dword ptr [rax + TSI_flags], TSF_MOVE
    jnz 3f
    lea rdi, [rip + stack]
    mov esi, 8
    call vec_push
    mov [rax], r14
3:  mov rdi, rbx
    mov rsi, r14
    call testmodel_item
    movsxd r14, dword ptr [rax + TSI_next]
    jmp 2b
9:  mov rax, r13
    EPILOGUE

# set_str(slot*, ptr, len): an owned copy replaces the slot's string
set_str:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [rbx]
    call mem_free
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rbx], rax
    pop r13
    pop r12
    pop rbx
    ret

# set_str_opt(slot*, ptr, len): as set_str, and 0 for no bytes
set_str_opt:
    test rdx, rdx
    jnz set_str
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call mem_free
    mov qword ptr [rbx], 0
    pop rbx
    ret

# testmodel_resolving(tsc, index, on): the item's tests-resolve is out (or no longer)
FN testmodel_resolving
    push rbx
    mov ebx, edx
    call testmodel_item
    and dword ptr [rax + TSI_flags], ~TSF_RESOLVING
    test ebx, ebx
    jz 1f
    or dword ptr [rax + TSI_flags], TSF_RESOLVING
1:  mov dword ptr [rip + g_ts_dirty], 3
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# testmodel_set_error(tsc, index, ptr, len): the problem shown on the item's row (len 0: none)
FN testmodel_set_error
    push rbx
    push r12
    push r13
    mov r12, rdx
    mov r13, rcx
    call testmodel_item
    lea rdi, [rax + TSI_error]
    mov rsi, r12
    mov rdx, r13
    cmp rdx, TS_ERROR_MAX
    jbe 1f
    mov edx, TS_ERROR_MAX
1:  call set_str_opt
    mov dword ptr [rip + g_ts_dirty], 3
    mov dword ptr [rip + g_dirty], 1
    pop r13
    pop r12
    pop rbx
    ret

# ---------------- runs ----------------

# testmodel_run_by_num(num) -> TSR* or 0
FN testmodel_run_by_num
    lea rax, [rip + g_ts_runs]
    lea rcx, [rax + TSR_SIZE * TS_RUNS_MAX]
1:  cmp qword ptr [rax + TSR_ext], 0
    je 2f
    cmp [rax + TSR_num], rdi
    je 9f
2:  add rax, TSR_SIZE
    cmp rax, rcx
    jb 1b
    xor eax, eax
9:  ret

# testmodel_run_new(ext, profile) -> TSR*, a queued run with the next number; the oldest finished
#   run makes room when every slot is taken (0 when they are all active or queued)
FN testmodel_run_new
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    lea r13, [rip + g_ts_runs]
    xor ecx, ecx
1:  cmp qword ptr [r13 + TSR_ext], 0
    je 3f
    add r13, TSR_SIZE
    inc ecx
    cmp ecx, TS_RUNS_MAX
    jb 1b
    call oldest_ended
    test rax, rax
    jz 9f
    mov r13, rax
    mov rdi, rax
    call run_free
3:  mov dword ptr [rip + g_ts_ran], 1
    mov [r13 + TSR_ext], rbx
    inc qword ptr [rip + g_ts_runnum]
    mov rax, [rip + g_ts_runnum]
    mov [r13 + TSR_num], rax
    mov dword ptr [r13 + TSR_state], TSRS_QUEUED
    mov [r13 + TSR_profile], r12d
    mov dword ptr [rip + g_ts_dirty], 3
    mov rdi, r13
    call testresults_run_new    # the Test Results tab shows it
    mov rax, r13
9:  EPILOGUE

# oldest_ended() -> TSR* of the finished run with the lowest number, or 0
oldest_ended:
    lea rcx, [rip + g_ts_runs]
    lea rdx, [rcx + TSR_SIZE * TS_RUNS_MAX]
    xor eax, eax
1:  cmp qword ptr [rcx + TSR_ext], 0
    je 2f
    cmp dword ptr [rcx + TSR_state], TSRS_ENDED
    jne 2f
    test rax, rax
    jz 11f
    mov r8, [rcx + TSR_num]
    cmp r8, [rax + TSR_num]
    jae 2f
11: mov rax, rcx
2:  add rcx, TSR_SIZE
    cmp rcx, rdx
    jb 1b
    ret

# run_free(TSR*): its results and outputs go; items whose last result was in it keep their state,
#   duration and first message line
run_free:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + TSR_ext]
    call testmodel_ctrl
    mov r12, rax
    xor r13d, r13d
1:  cmp r13, [rbx + TSR_ents + VEC_len]
    jae 3f
    imul r14, r13, TSE_SIZE
    add r14, [rbx + TSR_ents + VEC_ptr]
    test r12, r12
    jz 2f
    mov rdi, r12
    mov esi, [r14 + TSE_item]
    mov edx, [r14 + TSE_gen]
    call testmodel_live
    test eax, eax
    jz 2f
    mov rdi, r12
    mov esi, [r14 + TSE_item]
    call testmodel_item
    mov ecx, [rbx + TSR_num]
    cmp [rax + TSI_run], ecx
    jne 2f
    mov dword ptr [rax + TSI_run], 0
2:  lea rdi, [r14 + TSE_msgs]
    call sb_free
    lea rdi, [r14 + TSE_out]
    call sb_free
    mov rdi, [r14 + TSE_prev_msg]
    call mem_free
    inc r13
    jmp 1b
3:  lea rdi, [rbx + TSR_ents]
    call vec_free
    lea rdi, [rbx + TSR_ids]
    call sb_free
    lea rdi, [rbx + TSR_out]
    call sb_free
    mov rax, [rbx + TSR_bytes]
    sub [rip + g_ts_bytes], rax
    mov rdi, rbx
    xor esi, esi
    mov edx, TSR_SIZE
    call memset
    mov dword ptr [rip + g_ts_dirty], 3
    mov dword ptr [rip + g_ts_marks], 1
    EPILOGUE

# sb_free(sb): its bytes, and it is empty
sb_free:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + SB_ptr]
    call mem_free
    xor eax, eax
    mov [rbx + SB_ptr], rax
    mov [rbx + SB_len], rax
    mov [rbx + SB_cap], rax
    pop rbx
    ret

# testmodel_budget(): the oldest finished runs go whole while all runs hold more than the budget;
#   runs beyond the ten newest finished ones go too
FN testmodel_budget
    PROLOGUE
1:  # finished runs past TS_RUNS_KEPT
    xor ebx, ebx
    lea rcx, [rip + g_ts_runs]
    xor edx, edx
2:  cmp qword ptr [rcx + TSR_ext], 0
    je 3f
    cmp dword ptr [rcx + TSR_state], TSRS_ENDED
    jne 3f
    inc ebx
3:  add rcx, TSR_SIZE
    inc edx
    cmp edx, TS_RUNS_MAX
    jb 2b
    cmp ebx, TS_RUNS_KEPT
    ja 4f
    cmp qword ptr [rip + g_ts_bytes], TS_BUDGET
    jbe 9f
    test ebx, ebx
    jz 9f
4:  call oldest_ended
    test rax, rax
    jz 9f
    mov rdi, rax
    call run_free
    jmp 1b
9:  EPILOGUE

# testmodel_entry(run, tsc, index) -> TSE* of the item's result in this run, made when it has none
#   (it remembers the item's result before the run touched it)
FN testmodel_entry
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    call testmodel_item
    mov r14, rax
    mov eax, [rbx + TSR_num]
    cmp [r14 + TSI_run], eax
    jne 1f
    mov eax, [r14 + TSI_rent]
    cmp rax, [rbx + TSR_ents + VEC_len]
    jae 1f
    imul rax, rax, TSE_SIZE
    add rax, [rbx + TSR_ents + VEC_ptr]
    cmp [rax + TSE_item], r13d
    je 9f
1:  # another run reported it since: look for its entry here, newest first
    mov rcx, [rbx + TSR_ents + VEC_len]
2:  test rcx, rcx
    jz 3f
    dec rcx
    imul rax, rcx, TSE_SIZE
    add rax, [rbx + TSR_ents + VEC_ptr]
    cmp [rax + TSE_item], r13d
    jne 2b
    mov edx, [r14 + TSI_gen]
    cmp [rax + TSE_gen], edx
    jne 2b
    mov [r14 + TSI_rent], ecx
    jmp 4f
3:  mov r15, [rbx + TSR_ents + VEC_len]
    lea rdi, [rbx + TSR_ents]
    mov esi, TSE_SIZE
    call vec_push
    mov [rax + TSE_item], r13d
    mov ecx, [r14 + TSI_gen]
    mov [rax + TSE_gen], ecx
    mov dword ptr [rax + TSE_state], TSS_NOTRUN
    mov dword ptr [rax + TSE_ms], -1
    mov ecx, [r14 + TSI_own]
    mov [rax + TSE_prev_own], ecx
    mov ecx, [r14 + TSI_ms]
    mov [rax + TSE_prev_ms], ecx
    mov ecx, [r14 + TSI_run]
    mov [rax + TSE_prev_run], ecx
    mov ecx, [r14 + TSI_rent]
    mov [rax + TSE_prev_rent], ecx
    mov [r14 + TSI_rent], r15d
    mov rdi, [r14 + TSI_msg]    # the summary, to come back if the run leaves it unfinished
    test rdi, rdi
    jz 4f
    push rax
    push rax
    call strlen
    mov rsi, rax
    mov rdi, [r14 + TSI_msg]
    call mem_dup
    mov rcx, rax
    pop rax
    pop rax
    mov [rax + TSE_prev_msg], rcx
4:  mov ecx, [rbx + TSR_num]
    mov [r14 + TSI_run], ecx
9:  EPILOGUE

# testmodel_run_entry(run) -> TSE* of the run's own result (item -1), made when it has none
FN testmodel_run_entry
    PROLOGUE
    mov rbx, rdi
    xor ecx, ecx
1:  cmp rcx, [rbx + TSR_ents + VEC_len]
    jae 2f
    imul rax, rcx, TSE_SIZE
    add rax, [rbx + TSR_ents + VEC_ptr]
    cmp dword ptr [rax + TSE_item], -1
    je 9f
    inc rcx
    jmp 1b
2:  lea rdi, [rbx + TSR_ents]
    mov esi, TSE_SIZE
    call vec_push
    mov dword ptr [rax + TSE_item], -1
    mov dword ptr [rax + TSE_ms], -1
9:  EPILOGUE

# testmodel_run_end(run, errored): the run is over: its items still queued or running go back to the
#   result they had before it; errored marks the run itself
FN testmodel_run_end
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + TSR_state], TSRS_ENDED
    je 9f
    test esi, esi
    jz 1f
    mov dword ptr [rbx + TSR_err], 1
1:  mov dword ptr [rbx + TSR_state], TSRS_ENDED
    call time_ms
    mov [rbx + TSR_t1], rax
    mov rdi, [rbx + TSR_ext]
    call testmodel_ctrl
    mov r12, rax
    xor r13d, r13d
2:  cmp r13, [rbx + TSR_ents + VEC_len]
    jae 8f
    imul r14, r13, TSE_SIZE
    add r14, [rbx + TSR_ents + VEC_ptr]
    mov eax, [r14 + TSE_state]
    cmp eax, TSS_QUEUED
    jb 7f
    mov dword ptr [r14 + TSE_state], TSS_NOTRUN
    test r12, r12
    jz 7f
    mov rdi, r12
    mov esi, [r14 + TSE_item]
    mov edx, [r14 + TSE_gen]
    call testmodel_live
    test eax, eax
    jz 7f
    mov rdi, r12
    mov esi, [r14 + TSE_item]
    call testmodel_item
    mov ecx, [rbx + TSR_num]
    cmp [rax + TSI_run], ecx
    jne 7f                      # a later run reported it since
    cmp [rax + TSI_rent], r13d
    jne 7f
    mov r15, rax
    mov rdi, r14
    call prev_result            # the result before this run, followed while it moved on
    mov [r15 + TSI_ms], edx
    mov [r15 + TSI_run], ecx
    mov [r15 + TSI_rent], r8d
    push rax
    push rax
    mov rdi, [r15 + TSI_msg]    # its summary comes back too
    call mem_free
    mov rax, [r14 + TSE_prev_msg]
    mov [r15 + TSI_msg], rax
    mov qword ptr [r14 + TSE_prev_msg], 0
    pop rdx
    pop rdx
    mov rdi, r12
    mov esi, [r14 + TSE_item]
    call testmodel_set_own
7:  inc r13
    jmp 2b
8:  mov rdi, rbx
    call testexec_run_over      # its processes stop
    call testmodel_budget
    mov dword ptr [rip + g_ts_marks], 1
    mov dword ptr [rip + g_ts_dirty], 3
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# prev_result(TSE*) -> eax state, edx ms, ecx run, r8d entry: the item's result before this run.
#   When that was a live state of another run (queued, running), it is followed: still live there
#   (that run runs on), or that run's own outcome for it, or what that run had found before it
prev_result:
    PROLOGUE
    mov rbx, rdi
    mov eax, [rbx + TSE_prev_own]
    mov edx, [rbx + TSE_prev_ms]
    mov ecx, [rbx + TSE_prev_run]
    mov r8d, [rbx + TSE_prev_rent]
    cmp eax, TSS_QUEUED
    jb 9f
    # another run's live state: where does it stand now
    mov edi, ecx
    call testmodel_run_by_num
    test rax, rax
    jz 8f
    mov r12, rax
    mov ecx, [rbx + TSE_prev_rent]
    cmp rcx, [r12 + TSR_ents + VEC_len]
    jae 8f
    imul r13, rcx, TSE_SIZE
    add r13, [r12 + TSR_ents + VEC_ptr]
    mov eax, [r13 + TSE_item]
    cmp eax, [rbx + TSE_item]
    jne 8f
    mov eax, [r13 + TSE_gen]
    cmp eax, [rbx + TSE_gen]
    jne 8f
    mov eax, [r13 + TSE_state]
    cmp eax, TSS_NOTRUN
    jne 1f
    # that run ended without an outcome for it: what it had before that run, unless live too
    mov eax, [r13 + TSE_prev_own]
    cmp eax, TSS_QUEUED
    jae 8f
    mov edx, [r13 + TSE_prev_ms]
    mov ecx, [r13 + TSE_prev_run]
    mov r8d, [r13 + TSE_prev_rent]
    jmp 9f
1:  cmp eax, TSS_QUEUED
    jb 2f
    cmp dword ptr [r12 + TSR_state], TSRS_RUNNING
    jne 8f                      # live in a run that is over: nothing
2:  mov edx, [r13 + TSE_ms]
    mov ecx, [rbx + TSE_prev_run]
    mov r8d, [rbx + TSE_prev_rent]
    jmp 9f
8:  mov eax, TSS_NOTRUN
    mov edx, -1
    xor ecx, ecx
    xor r8d, r8d
9:  EPILOGUE

# testmodel_counts(run, out[TSS_COUNT] u32): the run's results per state (its own entry left out)
FN testmodel_counts
    push rbx
    mov rbx, rdi
    xor eax, eax
    mov ecx, TSS_COUNT
1:  dec ecx
    mov dword ptr [rsi + rcx*4], 0
    jnz 1b
    xor ecx, ecx
2:  cmp rcx, [rbx + TSR_ents + VEC_len]
    jae 9f
    imul rax, rcx, TSE_SIZE
    add rax, [rbx + TSR_ents + VEC_ptr]
    inc rcx
    cmp dword ptr [rax + TSE_item], -1
    je 2b
    mov edx, [rax + TSE_state]
    inc dword ptr [rsi + rdx*4]
    jmp 2b
9:  pop rbx
    ret

# testmodel_active(ext) -> eax runs queued or running (ext 0: every controller's)
FN testmodel_active
    xor eax, eax
    lea rcx, [rip + g_ts_runs]
    xor edx, edx
1:  cmp qword ptr [rcx + TSR_ext], 0
    je 3f
    test rdi, rdi
    jz 2f
    cmp [rcx + TSR_ext], rdi
    jne 3f
2:  cmp dword ptr [rcx + TSR_state], TSRS_QUEUED
    je 21f
    cmp dword ptr [rcx + TSR_state], TSRS_RUNNING
    jne 3f
21: inc eax
3:  add rcx, TSR_SIZE
    inc edx
    cmp edx, TS_RUNS_MAX
    jb 1b
    ret

# testmodel_running(ext) -> eax runs whose test-run went out and that are not over (ext 0: all)
FN testmodel_running
    xor eax, eax
    lea rcx, [rip + g_ts_runs]
    xor edx, edx
1:  cmp qword ptr [rcx + TSR_ext], 0
    je 3f
    test rdi, rdi
    jz 2f
    cmp [rcx + TSR_ext], rdi
    jne 3f
2:  cmp dword ptr [rcx + TSR_state], TSRS_RUNNING
    jne 3f
    inc eax
3:  add rcx, TSR_SIZE
    inc edx
    cmp edx, TS_RUNS_MAX
    jb 1b
    ret

# ---------------- dumps (print-tests, print-test-result, print-test-runs) ----------------

# testmodel_escape(sb, ptr, len): the bytes with \n, \r, \t, \\ and \xNN for other control bytes
FN testmodel_escape
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rsi + rdx]
1:  cmp r12, r13
    jae 9f
    movzx r14d, byte ptr [r12]
    inc r12
    cmp r14d, 10
    jne 2f
    mov r15d, 'n'
    jmp 6f
2:  cmp r14d, 13
    jne 3f
    mov r15d, 'r'
    jmp 6f
3:  cmp r14d, 9
    jne 4f
    mov r15d, 't'
    jmp 6f
4:  cmp r14d, 92
    jne 5f
    mov r15d, 92
    jmp 6f
5:  cmp r14d, 32
    jb 7f
    cmp r14d, 127
    je 7f
    mov rdi, rbx
    mov esi, r14d
    call sb_push_byte
    jmp 1b
6:  mov rdi, rbx
    mov esi, 92
    call sb_push_byte
    mov rdi, rbx
    mov esi, r15d
    call sb_push_byte
    jmp 1b
7:  mov rdi, rbx
    mov esi, 92
    call sb_push_byte
    mov rdi, rbx
    mov esi, 'x'
    call sb_push_byte
    lea rcx, [rip + hexdigits]
    mov eax, r14d
    shr eax, 4
    movzx esi, byte ptr [rcx + rax]
    mov rdi, rbx
    call sb_push_byte
    lea rcx, [rip + hexdigits]
    mov eax, r14d
    and eax, 15
    movzx esi, byte ptr [rcx + rax]
    mov rdi, rbx
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# testmodel_escape_cstr(sb, cstr or 0)
FN testmodel_escape_cstr
    test rsi, rsi
    jz 9f
    push rdi
    push rsi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    pop rsi
    pop rdi
    jmp testmodel_escape
9:  ret

# testmodel_state_word(state) -> cstr
FN testmodel_state_word
    lea rax, [rip + state_words]
    mov rax, [rax + rdi*8]
    ret

# testmodel_kind_word(kind) -> cstr
FN testmodel_kind_word
    lea rax, [rip + kind_words]
    mov rax, [rax + rdi*8]
    ret

# push_ext_name(sb, ext): "OWNER/NAME"
push_ext_name:
    push rbx
    push r12
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rsi, [r12 + EXT_owner]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, '/'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r12 + EXT_name]
    call sb_push_cstr
    pop r12
    pop r12
    pop rbx
    ret

# testmodel_next(tsc, index, all) -> rax the next item in display order (into an expanded item's
#   children, into every item's with all), -1 after the last; rdx the change in depth
FN testmodel_next
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    cmp dword ptr [rax + TSI_first], 0
    jl 2f
    test r13d, r13d
    jnz 1f
    test dword ptr [rax + TSI_flags], TSF_EXPANDED
    jz 2f
1:  movsxd rax, dword ptr [rax + TSI_first]
    mov edx, 1
    EPILOGUE
2:  xor r14d, r14d              # the depth change
3:  test r12, r12
    jz 8f                       # back at the controller's row: its tree is done
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    movsxd rcx, dword ptr [rax + TSI_next]
    test rcx, rcx
    jns 4f
    movsxd r12, dword ptr [rax + TSI_parent]
    dec r14
    test r12, r12
    jns 3b
8:  mov rax, -1
    xor edx, edx
    EPILOGUE
4:  mov rax, rcx
    mov rdx, r14
    EPILOGUE

# testmodel_leaf(tsc, index) -> eax 1 for a test item with no test children (what counts)
FN testmodel_leaf
    push rbx
    mov rbx, rdi
    call testmodel_item
    cmp dword ptr [rax + TSI_kind], TSK_TEST
    jne 8f
    movsxd rcx, dword ptr [rax + TSI_first]
1:  test rcx, rcx
    js 7f
    mov rdi, rbx
    mov rsi, rcx
    call testmodel_item
    cmp dword ptr [rax + TSI_kind], TSK_TEST
    je 8f
    movsxd rcx, dword ptr [rax + TSI_next]
    jmp 1b
7:  mov eax, 1
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret

# testmodel_tally(out[TSS_COUNT] u32): the leaves of every controller per state
FN testmodel_tally
    PROLOGUE
    mov r15, rdi
    xor esi, esi
    mov edx, 4 * TSS_COUNT
    call memset
    lea rbx, [rip + g_ts_ctrls]
    xor r12d, r12d
1:  cmp qword ptr [rbx + TSC_ext], 0
    je 4f
    mov r13d, 1
2:  cmp r13, [rbx + TSC_items + VEC_len]
    jae 4f
    mov rdi, rbx
    mov rsi, r13
    call testmodel_item
    cmp qword ptr [rax + TSI_id], 0
    je 3f
    mov r14d, [rax + TSI_state]
    mov rdi, rbx
    mov rsi, r13
    call testmodel_leaf
    test eax, eax
    jz 3f
    inc dword ptr [r15 + r14*4]
3:  inc r13
    jmp 2b
4:  add rbx, TSC_SIZE
    inc r12d
    cmp r12d, TS_CTRL_MAX
    jb 1b
    EPILOGUE

# testmodel_dump(sb, all): print-tests: a line per visible item (all: every item), indented two
#   spaces a level: "STATE LABEL id=ID kind=K ms=N [range=L1:C1-L2:C2] [lazy] [nodebug]
#   [resolving] [desc=D] [error=E]" (the controller's row has its OWNER/NAME as id), then
#   "passed=N failed=N errored=N skipped=N notrun=N" over the test items with no test children
.bss
.p2align 3
dump_counts: .zero 4 * TSS_COUNT
.text
FN testmodel_dump
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    lea r12, [rip + g_ts_ctrls]
    xor r13d, r13d
1:  cmp qword ptr [r12 + TSC_ext], 0
    je 3f
    xor r14d, r14d              # the item
    xor r15d, r15d              # its depth
2:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    mov rcx, r15
    call dump_line
    mov rdi, r12
    mov rsi, r14
    mov rdx, [rsp]
    call testmodel_next
    test rax, rax
    js 3f
    mov r14, rax
    add r15, rdx
    jmp 2b
3:  add r12, TSC_SIZE
    inc r13d
    cmp r13d, TS_CTRL_MAX
    jb 1b
    lea rdi, [rip + dump_counts]
    call testmodel_tally
    mov rdi, rbx
    lea rsi, [rip + dump_counts]
    call testmodel_push_counts
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# testmodel_push_counts(sb, counts[TSS_COUNT] u32): "passed=N failed=N errored=N skipped=N notrun=N"
FN testmodel_push_counts
    PROLOGUE
    mov rbx, rdi
    mov r14, rsi
    lea r12, [rip + count_words]
    xor r13d, r13d
1:  test r13d, r13d
    jz 2f
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
2:  mov rdi, rbx
    mov rsi, [r12 + r13*8]
    call sb_push_cstr
    lea rax, [rip + count_states]
    mov eax, [rax + r13*4]
    mov esi, [r14 + rax*4]
    mov rdi, rbx
    call sb_push_u64
    inc r13d
    cmp r13d, 5
    jb 1b
    EPILOGUE

# dump_line(sb, tsc, index, depth): one item's print-tests line
dump_line:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, r12
    mov rsi, r13
    call testmodel_item
    mov r15, rax
    xor ecx, ecx
3:  cmp rcx, r14
    jae 4f
    push rcx
    push rcx
    mov rdi, rbx
    lea rsi, [rip + .Lindent]
    call sb_push_cstr
    pop rcx
    pop rcx
    inc rcx
    jmp 3b
4:  mov edi, [r15 + TSI_state]
    call testmodel_state_word
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r15 + TSI_label]
    call testmodel_escape_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lp_id]
    call sb_push_cstr
    cmp r13, 0
    jne 41f
    mov rdi, rbx
    mov rsi, [r12 + TSC_ext]
    call push_ext_name
    jmp 42f
41: mov rdi, rbx
    mov rsi, [r15 + TSI_id]
    mov edx, [r15 + TSI_idlen]
    call testmodel_escape
42: mov rdi, rbx
    lea rsi, [rip + .Lp_kind]
    call sb_push_cstr
    mov edi, [r15 + TSI_kind]
    call testmodel_kind_word
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lp_ms]
    call sb_push_cstr
    mov esi, [r15 + TSI_ms]
    cmp esi, -1
    jne 43f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 44f
43: mov rdi, rbx
    call sb_push_u64
44: cmp dword ptr [r15 + TSI_l1], 0
    je 5f
    mov rdi, rbx
    lea rsi, [rip + .Lp_range]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r15 + TSI_l1]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r15 + TSI_c1]
    call sb_push_u64
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r15 + TSI_l2]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r15 + TSI_c2]
    call sb_push_u64
5:  test dword ptr [r15 + TSI_flags], TSF_LAZY
    jz 51f
    mov rdi, rbx
    lea rsi, [rip + .Lp_lazy]
    call sb_push_cstr
51: test dword ptr [r15 + TSI_flags], TSF_NODEBUG
    jz 52f
    mov rdi, rbx
    lea rsi, [rip + .Lp_nodebug]
    call sb_push_cstr
52: test dword ptr [r15 + TSI_flags], TSF_RESOLVING
    jz 53f
    mov rdi, rbx
    lea rsi, [rip + .Lp_resolving]
    call sb_push_cstr
53: cmp qword ptr [r15 + TSI_desc], 0
    je 54f
    mov rdi, rbx
    lea rsi, [rip + .Lp_desc]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r15 + TSI_desc]
    call testmodel_escape_cstr
54: cmp qword ptr [r15 + TSI_error], 0
    je 55f
    mov rdi, rbx
    lea rsi, [rip + .Lp_error]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r15 + TSI_error]
    call testmodel_escape_cstr
55: mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# testmodel_dump_runs(sb): print-test-runs: "run=N ext=O/N profile=P state=S passed=N failed=N
#   errored=N skipped=N notrun=N dropped=N procs=N" per run, oldest first
.bss
.p2align 3
run_counts: .zero 4 * TSS_COUNT
.text
FN testmodel_dump_runs
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d              # the last number printed
1:  # the run with the lowest number above r12
    lea rcx, [rip + g_ts_runs]
    xor edx, edx
    xor r13d, r13d
2:  cmp qword ptr [rcx + TSR_ext], 0
    je 3f
    mov rax, [rcx + TSR_num]
    cmp rax, r12
    jbe 3f
    test r13, r13
    jz 21f
    cmp rax, [r13 + TSR_num]
    jae 3f
21: mov r13, rcx
3:  add rcx, TSR_SIZE
    inc edx
    cmp edx, TS_RUNS_MAX
    jb 2b
    test r13, r13
    jz 9f
    mov r12, [r13 + TSR_num]
    mov rdi, rbx
    lea rsi, [rip + .Lr_run]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lr_ext]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r13 + TSR_ext]
    call push_ext_name
    mov rdi, rbx
    lea rsi, [rip + .Lr_profile]
    call sb_push_cstr
    mov eax, [r13 + TSR_profile]
    lea rcx, [rip + profile_words]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lr_state]
    call sb_push_cstr
    mov eax, [r13 + TSR_state]
    lea rcx, [rip + run_state_words]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    cmp dword ptr [r13 + TSR_err], 0
    je 4f
    mov rdi, rbx
    lea rsi, [rip + .Lr_errored]
    call sb_push_cstr
4:  cmp dword ptr [r13 + TSR_state], TSRS_ENDED
    je 41f
    mov rdi, [r13 + TSR_ext]
    call testproto_debug_window
    test eax, eax
    jz 41f
    mov rdi, rbx
    lea rsi, [rip + .Lr_debug_window]
    call sb_push_cstr
41: mov rdi, r13
    lea rsi, [rip + run_counts]
    call testmodel_counts
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [rip + run_counts]
    call testmodel_push_counts
    mov rdi, rbx
    lea rsi, [rip + .Lr_dropped]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + TSR_dropped]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lr_procs]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + TSR_procs]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lr_bytes]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r13 + TSR_bytes]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    # the run's own messages (a problem that belongs to no item)
    xor ecx, ecx
7:  cmp rcx, [r13 + TSR_ents + VEC_len]
    jae 1b
    imul rax, rcx, TSE_SIZE
    add rax, [r13 + TSR_ents + VEC_ptr]
    inc rcx
    cmp dword ptr [rax + TSE_item], -1
    jne 7b
    mov rdi, rbx
    mov rsi, rax
    call testmodel_dump_messages
    jmp 1b
9:  EPILOGUE

# testmodel_dump_result(sb, tsc, index): print-test-result: "state=S ms=N run=N", then a line per
#   message "message=T at=PATH:L1:C1 expected=E actual=A" (each part only when there is one), then
#   "output=O" (the output kept in its last run)
FN testmodel_dump_result
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    call testmodel_item
    mov r14, rax
    mov rdi, rbx
    lea rsi, [rip + .Lp_state]
    call sb_push_cstr
    mov edi, [r14 + TSI_own]
    call testmodel_state_word
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lp_ms]
    call sb_push_cstr
    mov esi, [r14 + TSI_ms]
    cmp esi, -1
    jne 1f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 2f
1:  mov rdi, rbx
    call sb_push_u64
2:  mov rdi, rbx
    lea rsi, [rip + .Lp_run]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r14 + TSI_run]
    call sb_push_u64
    cmp qword ptr [r14 + TSI_msg], 0
    je 21f
    mov rdi, rbx
    lea rsi, [rip + .Lp_msg1]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + TSI_msg]
    call testmodel_escape_cstr
21: mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, r12
    mov rsi, r13
    call testmodel_result
    test rax, rax
    jz 9f
    mov r15, rax
    mov rdi, rbx
    mov rsi, r15
    call testmodel_dump_messages
    mov rdi, rbx
    lea rsi, [rip + .Lp_output]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r15 + TSE_out + SB_ptr]
    mov rdx, [r15 + TSE_out + SB_len]
    call testmodel_escape
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

# testmodel_dump_messages(sb, TSE*): a line per message
FN testmodel_dump_messages
    PROLOGUE
    mov rbx, rdi
    mov r12, [rsi + TSE_msgs + SB_ptr]
    mov r13, [rsi + TSE_msgs + SB_len]
    add r13, r12
1:  cmp r12, r13
    jae 9f
    mov r14, r12                # the header
    lea r15, [r12 + TSM_SIZE]   # the text
    mov rdi, rbx
    lea rsi, [rip + .Lp_message]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r15
    mov edx, [r14 + TSM_text]
    call testmodel_escape
    mov eax, [r14 + TSM_text]
    add r15, rax                # the path
    cmp dword ptr [r14 + TSM_l1], 0
    je 2f
    mov rdi, rbx
    lea rsi, [rip + .Lp_at]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r15
    mov edx, [r14 + TSM_path]
    call testmodel_escape
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r14 + TSM_l1]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r14 + TSM_c1]
    call sb_push_u64
2:  mov eax, [r14 + TSM_path]
    add r15, rax                # expected
    cmp dword ptr [r14 + TSM_exp], -1
    je 3f
    mov rdi, rbx
    lea rsi, [rip + .Lp_expected]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r15
    mov edx, [r14 + TSM_exp]
    call testmodel_escape
    mov eax, [r14 + TSM_exp]
    add r15, rax
3:  cmp dword ptr [r14 + TSM_act], -1
    je 4f
    mov rdi, rbx
    lea rsi, [rip + .Lp_actual]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r15
    mov edx, [r14 + TSM_act]
    call testmodel_escape
    mov eax, [r14 + TSM_act]
    add r15, rax
4:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov r12, r15
    jmp 1b
9:  EPILOGUE

# testmodel_result(tsc, index) -> TSE* of the item's last result, or 0 when its run is gone
FN testmodel_result
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call testmodel_item
    mov r13, rax
    mov edi, [r13 + TSI_run]
    test edi, edi
    jz 8f
    call testmodel_run_by_num
    test rax, rax
    jz 8f
    mov ecx, [r13 + TSI_rent]
    cmp rcx, [rax + TSR_ents + VEC_len]
    jae 8f
    imul rcx, rcx, TSE_SIZE
    add rcx, [rax + TSR_ents + VEC_ptr]
    cmp [rcx + TSE_item], r12d
    jne 8f
    mov edx, [r13 + TSI_gen]
    cmp [rcx + TSE_gen], edx
    jne 8f
    mov rax, rcx
    jmp 9f
8:  xor eax, eax
9:  pop r13
    pop r12
    pop rbx
    ret

.section .rodata
.Lempty: .asciz ""
.Lindent: .asciz "  "
.Lf_lazy: .asciz "lazy"
.Lf_nodebug: .asciz "nodebug"
.Lx_desc: .asciz "desc"
.Lx_error: .asciz "error"
.Lk_ctrl: .asciz "controller"
.Lk_group: .asciz "group"
.Lk_file: .asciz "file"
.Lk_suite: .asciz "suite"
.Lk_test: .asciz "test"
.Ls_notrun: .asciz "notrun"
.Ls_skipped: .asciz "skipped"
.Ls_passed: .asciz "passed"
.Ls_failed: .asciz "failed"
.Ls_errored: .asciz "errored"
.Ls_queued: .asciz "queued"
.Ls_running: .asciz "running"
.Lc_passed: .asciz "passed="
.Lc_failed: .asciz "failed="
.Lc_errored: .asciz "errored="
.Lc_skipped: .asciz "skipped="
.Lc_notrun: .asciz "notrun="
.Lpr_run: .asciz "run"
.Lpr_debug: .asciz "debug"
.Lpr_coverage: .asciz "coverage"
.Lrs_free: .asciz "free"
.Lrs_queued: .asciz "queued"
.Lrs_running: .asciz "running"
.Lrs_ended: .asciz "ended"
.Lp_id: .asciz " id="
.Lp_kind: .asciz " kind="
.Lp_ms: .asciz " ms="
.Lp_range: .asciz " range="
.Lp_lazy: .asciz " lazy"
.Lp_nodebug: .asciz " nodebug"
.Lp_resolving: .asciz " resolving"
.Lp_desc: .asciz " desc="
.Lp_error: .asciz " error="
.Lp_state: .asciz "state="
.Lp_run: .asciz " run="
.Lp_msg1: .asciz " first="
.Lp_message: .asciz "message="
.Lp_at: .asciz " at="
.Lp_expected: .asciz " expected="
.Lp_actual: .asciz " actual="
.Lp_output: .asciz "output="
.Lr_run: .asciz "run="
.Lr_ext: .asciz " ext="
.Lr_profile: .asciz " profile="
.Lr_state: .asciz " state="
.Lr_debug_window: .asciz " debug-window"
.Lr_errored: .asciz " errored-run"
.Lr_dropped: .asciz " dropped="
.Lr_procs: .asciz " procs="
.Lr_bytes: .asciz " bytes="
.Le_syntax_items: .asciz "syntax bad items body"
.Le_badpos_items: .asciz "badpos bad range"
.Le_relative: .asciz "syntax a file must be an absolute path or #DOC"
.Le_toobig_body: .asciz "toobig 10000 items per body"
.Le_toobig_ext: .asciz "toobig 50000 items per extension"
.Le_toobig_all: .asciz "toobig 100000 items in all"
.Le_unknown_parent: .asciz "refused unknown parent"
.Le_other_parent: .asciz "syntax the answer is for another parent"
.Le_cycle: .asciz "refused an item cannot move below itself"
hexdigits: .ascii "0123456789abcdef"
.p2align 3
kind_words: .quad .Lk_ctrl, .Lk_group, .Lk_file, .Lk_suite, .Lk_test, 0
state_words: .quad .Ls_notrun, .Ls_skipped, .Ls_passed, .Ls_failed, .Ls_errored, .Ls_queued, .Ls_running, 0
count_words: .quad .Lc_passed, .Lc_failed, .Lc_errored, .Lc_skipped, .Lc_notrun
count_states: .long TSS_PASSED, TSS_FAILED, TSS_ERRORED, TSS_SKIPPED, TSS_NOTRUN
.p2align 3
profile_words: .quad .Lpr_run, .Lpr_debug, .Lpr_coverage
run_state_words: .quad .Lrs_free, .Lrs_queued, .Lrs_running, .Lrs_ended
.globl ts_profile_words
ts_profile_words: .quad .Lpr_run, .Lpr_debug, .Lpr_coverage, 0
