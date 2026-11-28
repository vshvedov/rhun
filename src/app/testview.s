# testing: the commands (Run All Tests, Re-run Failed Tests, Run Test at Cursor ...), the selected
# item, and the headless controls that drive and print the test model (control.s calls the
# testctl_* functions with its output buffer and the command's arguments).
.include "rhun.inc"

.bss
.p2align 3
.globl g_tv_ext, g_tv_item
g_tv_ext: .quad 0               # the selected item: its controller's EXT (0: none), index, gen
g_tv_item: .quad 0
g_tv_gen: .quad 0
ids: .zero SB_SIZE              # ids collected for a run
nids: .quad 0
cur_line: .quad 0               # Run at Cursor: the cursor, one-based
cur_col: .quad 0
best_depth: .quad 0
best_item: .quad 0
cur_path: .quad 0

.text

# testview_forget(ext): the extension's tests are gone: nothing of it stays selected
FN testview_forget
    cmp [rip + g_tv_ext], rdi
    jne 1f
    mov qword ptr [rip + g_tv_ext], 0
1:  ret

# testview_selected() -> rax TSC*, rdx index of the selected item, rax 0 when nothing (still) is
FN testview_selected
    push rbx
    mov rdi, [rip + g_tv_ext]
    test rdi, rdi
    jz 8f
    call testmodel_ctrl
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rdi, rax
    mov rsi, [rip + g_tv_item]
    mov rdx, [rip + g_tv_gen]
    call testmodel_live
    test eax, eax
    jz 8f
    mov rax, rbx
    mov rdx, [rip + g_tv_item]
    pop rbx
    ret
8:  xor eax, eax
    xor edx, edx
    pop rbx
    ret

# testview_select(tsc, index): that item is the selected one (the tree's cursor too, when it shows)
FN testview_select
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rdi + TSC_ext]
    mov [rip + g_tv_ext], rax
    mov [rip + g_tv_item], rsi
    call testmodel_item
    mov eax, [rax + TSI_gen]
    mov [rip + g_tv_gen], rax
    mov dword ptr [rip + g_dirty], 1
    cmp qword ptr [rip + tv_tree], 0
    je 9f
    call testview_rebuild
    mov rdi, rbx
    mov rsi, r12
    call node_id
    mov rdi, [rip + tv_tree]
    mov rsi, [rip + tv_id + SB_ptr]
    mov rdx, [rip + tv_id + SB_len]
    call tree_find
    cmp eax, 0
    jle 9f
    mov r13d, eax
    mov rdi, [rip + tv_tree]
    call tree_cursor
    cmp eax, r13d
    je 9f                       # the tree chose it (its select callback): no change to tell
    mov rdi, [rip + tv_tree]
    mov esi, r13d
    call tree_set_cursor
    mov rdi, [rip + tv_tree]
    mov esi, r13d
    call tree_reveal
9:  EPILOGUE

# testing_sync(): every extension that declares [provides] tests has its controller row, and an
#   idle one starts (its roots come once it agreed tests)
FN testing_sync
    PROLOGUE
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    mov rdi, rbx
    mov esi, EXT_pv_tests
    call ext_pv
    test rax, rax
    jz 1b
    cmp dword ptr [rbx + EXT_manifest_ok], 0
    je 1b
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 1b
    cmp dword ptr [rbx + EXT_status], ES_DISABLED
    je 1b
    mov rdi, rbx
    call testmodel_ctrl_make
    call testview_ensure
    cmp dword ptr [rbx + EXT_status], ES_IDLE
    jne 1b
    mov rdi, rbx
    call ext_start
    jmp 1b
9:  EPILOGUE

# ---------------- running ----------------

# run_ctrl(tsc, profile): one run of everything the controller has (when it offers the profile)
run_ctrl:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, [rbx + TSC_ext]
    call offers
    test eax, eax
    jz 9f
    mov rdi, [rbx + TSC_ext]
    mov esi, r12d
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call testproto_run
9:  EPILOGUE

# offers(ext, profile) -> eax 1 when the controller offers that run kind; else a toast says so
offers:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call testproto_profiles
    bt eax, r12d
    jc 7f
    lea rdi, [rip + .Lm_no_profile]
    call app_toast
    xor eax, eax
    EPILOGUE
7:  mov eax, 1
    EPILOGUE

# run_all(profile): one run per controller
run_all:
    PROLOGUE
    mov r13d, edi
    call testing_sync
    lea rbx, [rip + g_ts_ctrls]
    xor r12d, r12d
1:  cmp qword ptr [rbx + TSC_ext], 0
    je 2f
    mov rdi, rbx
    mov esi, r13d
    call run_ctrl
2:  add rbx, TSC_SIZE
    inc r12d
    cmp r12d, TS_CTRL_MAX
    jb 1b
    EPILOGUE

# ids_begin(), ids_add(tsc, index): the list of ids a run asks for
ids_begin:
    lea rdi, [rip + ids]
    mov qword ptr [rip + nids], 0
    jmp sb_clear
ids_add:
    push rbx
    call testmodel_item
    mov rbx, rax
    lea rdi, [rip + ids]
    mov rsi, [rbx + TSI_id]
    mov edx, [rbx + TSI_idlen]
    call sb_push
    lea rdi, [rip + ids]
    mov esi, 10
    call sb_push_byte
    inc qword ptr [rip + nids]
    pop rbx
    ret

# run_ids(ext, profile): a run of the collected ids, when there are any
run_ids:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp qword ptr [rip + nids], 0
    je 9f
    mov rdi, rbx
    mov esi, r12d
    call offers
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov esi, r12d
    mov rdx, [rip + ids + SB_ptr]
    mov rcx, [rip + ids + SB_len]
    mov r8, [rip + nids]
    call testproto_run
9:  EPILOGUE

# testview_run_item(tsc, index, profile): a run of that item (its controller's row: everything)
FN testview_run_item
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    test r12, r12
    jz 0f
    cmp r13d, TSP_DEBUG
    jne 1f
    mov rdi, rbx                # an item marked nodebug is not debugged
    mov rsi, r12
    call testmodel_item
    test dword ptr [rax + TSI_flags], TSF_NODEBUG
    jz 1f
    lea rdi, [rip + .Lm_nodebug]
    call app_toast
    EPILOGUE
0:  test r12, r12
    jnz 1f
    mov rdi, rbx
    mov esi, r13d
    call run_ctrl
    EPILOGUE
1:  call ids_begin
    mov rdi, rbx
    mov rsi, r12
    call ids_add
    mov rdi, [rbx + TSC_ext]
    mov esi, r13d
    call run_ids
    EPILOGUE

FN cmd_test_run_all
    xor edi, edi
    jmp run_all

FN cmd_test_coverage_all
    mov edi, TSP_COVERAGE
    jmp run_all

# cmd_test_rerun_failed: the failed and errored leaves, a run per controller
FN cmd_test_rerun_failed
    PROLOGUE
    lea rbx, [rip + g_ts_ctrls]
    xor r12d, r12d
1:  cmp qword ptr [rbx + TSC_ext], 0
    je 4f
    call ids_begin
    mov r13d, 1
2:  cmp r13, [rbx + TSC_items + VEC_len]
    jae 3f
    mov rdi, rbx
    mov rsi, r13
    call testmodel_item
    cmp qword ptr [rax + TSI_id], 0
    je 21f
    mov ecx, [rax + TSI_own]
    cmp ecx, TSS_FAILED
    je 20f
    cmp ecx, TSS_ERRORED
    jne 21f
20: mov rdi, rbx
    mov rsi, r13
    call testmodel_leaf
    test eax, eax
    jz 21f
    mov rdi, rbx
    mov rsi, r13
    call ids_add
21: inc r13
    jmp 2b
3:  mov rdi, [rbx + TSC_ext]
    xor esi, esi
    call run_ids
4:  add rbx, TSC_SIZE
    inc r12d
    cmp r12d, TS_CTRL_MAX
    jb 1b
    EPILOGUE

# cmd_test_rerun_last: the newest run again (its controller, kind and items)
FN cmd_test_rerun_last
    PROLOGUE
    lea rcx, [rip + g_ts_runs]
    xor edx, edx
    xor ebx, ebx
1:  cmp qword ptr [rcx + TSR_ext], 0
    je 2f
    test rbx, rbx
    jz 11f
    mov rax, [rcx + TSR_num]
    cmp rax, [rbx + TSR_num]
    jbe 2f
11: mov rbx, rcx
2:  add rcx, TSR_SIZE
    inc edx
    cmp edx, TS_RUNS_MAX
    jb 1b
    test rbx, rbx
    jz 9f
    # copied first: a new run may take the old one's slot
    lea rdi, [rip + ids]
    call sb_clear
    lea rdi, [rip + ids]
    mov rsi, [rbx + TSR_ids + SB_ptr]
    mov rdx, [rbx + TSR_ids + SB_len]
    call sb_push
    mov eax, [rbx + TSR_nids]
    mov [rip + nids], rax
    mov rdi, [rbx + TSR_ext]
    mov esi, [rbx + TSR_profile]
    mov rdx, [rip + ids + SB_ptr]
    mov rcx, [rip + ids + SB_len]
    mov r8, [rip + nids]
    call testproto_run
9:  EPILOGUE

# cmd_test_cancel: every queued or running run is cancelled
FN cmd_test_cancel
    PROLOGUE
    lea rbx, [rip + g_ts_runs]
    xor r12d, r12d
1:  cmp qword ptr [rbx + TSR_ext], 0
    je 2f
    mov rdi, rbx
    call testproto_cancel
2:  add rbx, TSR_SIZE
    inc r12d
    cmp r12d, TS_RUNS_MAX
    jb 1b
    EPILOGUE

# cmd_test_run_file: the active file's items (not those whose ancestor is in it too)
FN cmd_test_run_file
    xor edi, edi
    xor esi, esi
    jmp run_doc

# cmd_test_run_cursor, cmd_test_debug_cursor: the deepest item whose range holds the cursor, else
#   the file's items
FN cmd_test_run_cursor
    mov edi, 1
    xor esi, esi
    jmp run_doc

FN cmd_test_debug_cursor
    mov edi, 1
    mov esi, TSP_DEBUG
    jmp run_doc

# run_doc(at cursor, profile): a run per controller of the active document's items
run_doc:
    PROLOGUE
    mov r14d, edi
    mov r15d, esi
    call testing_sync
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov rax, [rbx + DOC_path]
    test rax, rax
    jz 9f
    mov [rip + cur_path], rax
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    mov r12, rax
    lea rcx, [rax + 1]
    mov [rip + cur_line], rcx
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov rcx, [rbx + DOC_cur]
    sub rcx, rax
    inc rcx
    mov [rip + cur_col], rcx
    lea rbx, [rip + g_ts_ctrls]
    xor r12d, r12d
1:  cmp qword ptr [rbx + TSC_ext], 0
    je 8f
    call ids_begin
    test r14d, r14d
    jz 3f
    # at the cursor: the deepest item holding it
    mov qword ptr [rip + best_item], 0
    mov qword ptr [rip + best_depth], 0
    mov r13d, 1
2:  cmp r13, [rbx + TSC_items + VEC_len]
    jae 21f
    mov rdi, rbx
    mov rsi, r13
    call holds_cursor
    test rax, rax
    jz 20f
    cmp rax, [rip + best_depth]
    jbe 20f
    mov [rip + best_depth], rax
    mov [rip + best_item], r13
20: inc r13
    jmp 2b
21: mov rsi, [rip + best_item]
    test rsi, rsi
    jz 3f
    cmp r15d, TSP_DEBUG
    jne 22f
    mov rdi, rbx
    call testmodel_item
    test dword ptr [rax + TSI_flags], TSF_NODEBUG
    jnz 23f
    mov rsi, [rip + best_item]
22: mov rdi, rbx
    call ids_add
    jmp 7f
23: lea rdi, [rip + .Lm_nodebug]
    call app_toast
    jmp 8f
3:  # the file's items: in the file, with no ancestor in it
    mov r13d, 1
4:  cmp r13, [rbx + TSC_items + VEC_len]
    jae 7f
    mov rdi, rbx
    mov rsi, r13
    call in_file
    test eax, eax
    jz 6f
    mov rdi, rbx
    mov rsi, r13
    call testmodel_item
    movsxd r8, dword ptr [rax + TSI_parent]
5:  test r8, r8
    jle 51f
    mov rdi, rbx
    mov rsi, r8
    push r8
    push r8
    call in_file
    pop r8
    pop r8
    test eax, eax
    jnz 6f
    mov rdi, rbx
    mov rsi, r8
    call testmodel_item
    movsxd r8, dword ptr [rax + TSI_parent]
    jmp 5b
51: cmp r15d, TSP_DEBUG
    jne 52f
    mov rdi, rbx
    mov rsi, r13
    call testmodel_item
    test dword ptr [rax + TSI_flags], TSF_NODEBUG
    jnz 6f
52: mov rdi, rbx
    mov rsi, r13
    call ids_add
6:  inc r13
    jmp 4b
7:  mov rdi, [rbx + TSC_ext]
    mov esi, r15d
    call run_ids
8:  add rbx, TSC_SIZE
    inc r12d
    cmp r12d, TS_CTRL_MAX
    jb 1b
9:  EPILOGUE

# in_file(tsc, index) -> eax 1 for a live item whose file is the active document's
in_file:
    push rbx
    call testmodel_item
    cmp qword ptr [rax + TSI_id], 0
    je 8f
    mov rdi, [rax + TSI_path]
    test rdi, rdi
    jz 8f
    mov rsi, [rip + cur_path]
    call strcmp_eq
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret

# holds_cursor(tsc, index) -> rax the item's depth (1 for a root) when it is in the active file and
#   its range holds the cursor, else 0
holds_cursor:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call in_file
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    mov r13, rax
    cmp dword ptr [r13 + TSI_l1], 0
    je 8f
    # its range moved through the edits since it came
    mov rdi, [rip + g_doc]
    mov rsi, r13
    call testgutter_item_lines
    test eax, eax
    jz 8f
    mov ecx, eax
    mov r14d, edx
    mov rax, [rip + cur_line]
    cmp rax, rcx
    jb 8f
    ja 1f
    mov ecx, [r13 + TSI_c1]
    cmp [rip + cur_col], rcx
    jb 8f
1:  mov ecx, r14d
    cmp rax, rcx
    ja 8f
    jb 2f
    mov ecx, [r13 + TSI_c2]
    cmp [rip + cur_col], rcx
    ja 8f
2:  xor r14d, r14d
    mov r15, r12
3:  test r15, r15
    jle 4f
    inc r14
    mov rdi, rbx
    mov rsi, r15
    call testmodel_item
    movsxd r15, dword ptr [rax + TSI_parent]
    jmp 3b
4:  mov rax, r14
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- headless controls ----------------

# control.s's ctl_tables lists this table: each fn(out, rest, rest length) -> rax 0
.section .rodata
.p2align 3
.globl test_ctl
test_ctl:
    .quad .Lc_select, testctl_select, .Lc_expand, testctl_expand_open
    .quad .Lc_collapse, testctl_collapse, .Lc_action, testctl_action
    .quad .Lc_wait, testctl_wait, .Lc_wait_items, testctl_wait_items
    .quad .Lc_print, testctl_print, .Lc_result, testctl_result
    .quad .Lc_runs, testctl_runs, .Lc_coverage, testctl_coverage
    .quad .Lc_view, testctl_print_view, .Lc_gutter, testctl_gutter
    .quad .Lc_gutter_click, testctl_gutter_click, .Lc_status, testctl_status
    .quad .Lc_filter, testctl_filter, .Lc_failed, testctl_failed
    .quad .Lc_cov_view, testctl_cov_view
    .quad 0, 0
.Lc_select: .asciz "test-select"
.Lc_expand: .asciz "test-expand"
.Lc_collapse: .asciz "test-collapse"
.Lc_action: .asciz "test-action"
.Lc_wait: .asciz "wait-tests"
.Lc_wait_items: .asciz "wait-test-items"
.Lc_print: .asciz "print-tests"
.Lc_result: .asciz "print-test-result"
.Lc_runs: .asciz "print-test-runs"
.Lc_coverage: .asciz "print-coverage"
.Lc_view: .asciz "print-testing"
.Lc_gutter: .asciz "print-gutter"
.Lc_gutter_click: .asciz "test-gutter"
.Lc_status: .asciz "print-test-status"
.Lc_filter: .asciz "test-filter"
.Lc_failed: .asciz "test-failed-only"
.Lc_cov_view: .asciz "print-test-coverage"
.text

testctl_expand_open:
    mov ecx, 1
    jmp testctl_expand
testctl_collapse:
    xor ecx, ecx
    jmp testctl_expand

# item_arg(rest, len) -> rax TSC*, rdx index for "OWNER/NAME ID" (no ID: the controller's row), or
#   rax 0
item_arg:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov rsi, r12
    call next_word
    test rdx, rdx
    jz 8f
    add rbx, rcx
    sub r12, rcx
    mov rdi, rax
    mov rsi, rdx
    call ext_by_name
    test rax, rax
    jz 8f
    mov rdi, rax
    call testmodel_ctrl
    test rax, rax
    jz 8f
    mov r13, rax
    mov rdi, rbx
    mov rsi, r12
    call trim
    test rdx, rdx
    jz 7f
    mov rdi, r13
    mov rsi, rax
    call testmodel_find
    test rax, rax
    js 8f
    mov rdx, rax
    mov rax, r13
    EPILOGUE
7:  mov rax, r13
    xor edx, edx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# testctl_select(sb, rest, len): test-select OWNER/NAME [ID]
FN testctl_select
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call item_arg
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call testview_select
    xor eax, eax
    EPILOGUE
8:  mov rdi, rbx
    lea rsi, [rip + .Lm_no_item]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE

# testctl_expand(sb, rest, len, open): test-expand / test-collapse OWNER/NAME [ID]; expanding a lazy
#   item asks its controller for its children
FN testctl_expand
    PROLOGUE
    mov rbx, rdi
    mov r15d, ecx
    mov rdi, rsi
    mov rsi, rdx
    call item_arg
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    mov edx, r15d
    call testview_expand
    xor eax, eax
    EPILOGUE
8:  mov rdi, rbx
    lea rsi, [rip + .Lm_no_item]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE

# testview_expand(tsc, index, open): the item shows its children (or not); a lazy one is resolved
FN testview_expand
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    call testmodel_item
    and dword ptr [rax + TSI_flags], ~TSF_EXPANDED
    test r13d, r13d
    jz 9f
    or dword ptr [rax + TSI_flags], TSF_EXPANDED
    test dword ptr [rax + TSI_flags], TSF_LAZY
    jz 9f
    mov rdi, [rbx + TSC_ext]
    mov rsi, rbx
    mov rdx, r12
    call testproto_resolve
9:  mov dword ptr [rip + g_ts_dirty], 1
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# testctl_action(sb, rest, len): test-action run|debug|coverage|cancel on the selected item
FN testctl_action
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call testview_selected
    test rax, rax
    jz 8f
    mov r14, rax
    mov r15, rdx
    mov rdi, r12
    mov rsi, r13
    call trim
    mov r12, rax
    mov r13, rdx
    xor ecx, ecx
1:  lea rax, [rip + ts_profile_words]
    mov rdx, [rax + rcx*8]
    test rdx, rdx
    jz 2f
    push rcx
    push rcx
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    pop rcx
    pop rcx
    test eax, eax
    jnz 11f
    inc ecx
    jmp 1b
11: mov rdi, r14
    mov rsi, r15
    mov edx, ecx
    call testview_run_item
    xor eax, eax
    EPILOGUE
2:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .La_cancel]
    call str_eq_cstr
    test eax, eax
    jz 3f
    mov rdi, [r14 + TSC_ext]
    call cancel_ext
    xor eax, eax
    EPILOGUE
3:  mov rdi, r14
    mov rsi, r15
    mov rdx, r12
    mov rcx, r13
    call testview_action        # the view's (goto, diff, output)
    xor eax, eax
    EPILOGUE
8:  mov rdi, rbx
    lea rsi, [rip + .Lm_no_item]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE

# cancel_ext(ext): its runs are cancelled
cancel_ext:
    PROLOGUE
    mov r13, rdi
    lea rbx, [rip + g_ts_runs]
    xor r12d, r12d
1:  cmp [rbx + TSR_ext], r13
    jne 2f
    mov rdi, rbx
    call testproto_cancel
2:  add rbx, TSR_SIZE
    inc r12d
    cmp r12d, TS_RUNS_MAX
    jb 1b
    EPILOGUE

# testview_action(tsc, index, word, len): on an item, "goto" (its range), "failure" (its last
#   failure's place), "diff" (its last failure's expected and actual as a diff tab), "output" (its last
#   output in a read-only tab)
FN testview_action
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .La_goto]
    call str_eq_cstr
    test eax, eax
    jnz .Lva_goto
    mov rdi, rbx
    mov rsi, r12
    call testmodel_result
    test rax, rax
    jz 9f
    mov r15, rax
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .La_output]
    call str_eq_cstr
    test eax, eax
    jnz .Lva_output
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .La_diff]
    call str_eq_cstr
    test eax, eax
    jnz .Lva_diff
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .La_failure]
    call str_eq_cstr
    test eax, eax
    jnz .Lva_failure
9:  EPILOGUE
.Lva_goto:
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    mov rdi, [rax + TSI_path]
    test rdi, rdi
    jz 9b
    mov r14d, [rax + TSI_c1]
    lea rsi, [rax + TSI_ver]
    mov edx, [rax + TSI_l1]
    push rdi
    push rdi
    call testgutter_map_path    # its first line moved through the edits since it came
    mov r13d, eax
    pop rdi
    pop rdi
    call app_open_file
    test rax, rax
    js 9b
    mov edi, r13d
    mov esi, r14d
    call app_goto_line
    EPILOGUE
.Lva_output:
    call title_begin
    lea rsi, [rip + .Lt_output]
    call title_push
    mov rdi, rbx
    mov rsi, r12
    call title_label
    lea rdi, [rip + title]
    mov rsi, [r15 + TSE_out + SB_ptr]
    mov rdx, [r15 + TSE_out + SB_len]
    call testdiff_output
    EPILOGUE
.Lva_diff:
    mov rdi, r15
    call first_values
    test rax, rax
    jz 9b
    mov r13, rax                # the message's header
    call title_begin
    lea rsi, [rip + .Lt_diff]
    call title_push
    mov rdi, rbx
    mov rsi, r12
    call title_label
    lea rsi, [r13 + TSM_SIZE]
    mov eax, [r13 + TSM_text]
    add rsi, rax
    mov eax, [r13 + TSM_path]
    add rsi, rax                # expected
    mov edx, [r13 + TSM_exp]
    lea rcx, [rsi + rdx]        # actual
    mov r8d, [r13 + TSM_act]
    lea rdi, [rip + title]
    call testdiff_open
    EPILOGUE
.Lva_failure:
    mov rax, [r15 + TSE_msgs + SB_ptr]
    test rax, rax
    jz 9b
    cmp dword ptr [rax + TSM_l1], 0
    je 9b
    mov r13, rax
    lea rdi, [rax + TSM_SIZE]
    mov ecx, [rax + TSM_text]
    add rdi, rcx
    mov esi, [rax + TSM_path]
    call mem_dup
    mov r14, rax
    mov rdi, rax                # its line moved through the edits since it came
    lea rsi, [r13 + TSM_ver]
    mov edx, [r13 + TSM_l1]
    call testgutter_map_path
    mov r12d, eax
    mov rdi, r14
    call app_open_file
    mov r15, rax
    mov rdi, r14
    call mem_free
    test r15, r15
    js 9b
    mov edi, r12d
    mov esi, [r13 + TSM_c1]
    call app_goto_line
    EPILOGUE

# first_values(TSE*) -> rax the header of its first message with both expected and actual, or 0
first_values:
    mov rax, [rdi + TSE_msgs + SB_ptr]
    mov rcx, [rdi + TSE_msgs + SB_len]
    add rcx, rax
1:  cmp rax, rcx
    jae 8f
    cmp dword ptr [rax + TSM_exp], -1
    je 2f
    cmp dword ptr [rax + TSM_act], -1
    jne 9f
2:  mov edx, TSM_SIZE
    add edx, [rax + TSM_text]
    add edx, [rax + TSM_path]
    mov r8d, [rax + TSM_exp]
    cmp r8d, -1
    je 3f
    add edx, r8d
3:  mov r8d, [rax + TSM_act]
    cmp r8d, -1
    je 4f
    add edx, r8d
4:  add rax, rdx
    jmp 1b
8:  xor eax, eax
9:  ret

# the title of a tab being opened: title_begin(), title_push(cstr in rsi), title_label(tsc, index)
.bss
title: .zero 320
title_len: .quad 0
.text
title_begin:
    mov qword ptr [rip + title_len], 0
    mov byte ptr [rip + title], 0
    ret
title_push:
    mov rax, [rip + title_len]
    lea rdx, [rip + title]
1:  movzx ecx, byte ptr [rsi]
    test ecx, ecx
    jz 2f
    cmp rax, 300
    jae 2f
    mov [rdx + rax], cl
    inc rax
    inc rsi
    jmp 1b
2:  mov byte ptr [rdx + rax], 0
    mov [rip + title_len], rax
    ret
title_label:
    push rbx
    call testmodel_item
    mov rsi, [rax + TSI_label]
    call title_push
    pop rbx
    ret

# testctl_wait(sb): wait-tests: until no run is queued or running (30 s at most), then
#   "tests=idle" (or "tests=busy")
FN testctl_wait
    PROLOGUE
    mov rbx, rdi
    call time_ms
    lea r12, [rax + 30000]
1:  xor edi, edi
    call testmodel_active
    test eax, eax
    jz 2f
    call time_ms
    cmp rax, r12
    jae 3f
    mov edi, 20
    call loop_poll
    call app_tick
    jmp 1b
2:  mov rdi, rbx
    lea rsi, [rip + .Lm_idle]
    call sb_push_cstr
    EPILOGUE
3:  mov rdi, rbx
    lea rsi, [rip + .Lm_busy]
    call sb_push_cstr
    EPILOGUE

# testctl_wait_items(sb, rest, len): wait-test-items N: until the controllers hold at least N items
#   and no tests-resolve is out (10 s at most), then "items=N"
FN testctl_wait_items
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call trim
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov r13, rax
    call time_ms
    lea r12, [rax + 10000]
1:  mov rax, [rip + g_ts_items_all]
    cmp rax, r13
    jb 2f
    call testproto_resolving
    test eax, eax
    jz 3f
2:  call time_ms
    cmp rax, r12
    jae 3f
    mov edi, 20
    call loop_poll
    call app_tick
    jmp 1b
3:  mov rdi, rbx
    lea rsi, [rip + .Lm_items]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + g_ts_items_all]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# testctl_print(sb, rest, len): print-tests [all]
FN testctl_print
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call trim
    xor ecx, ecx
    test rdx, rdx
    jz 1f
    mov ecx, 1
1:  mov rdi, rbx
    mov esi, ecx
    call testmodel_dump
    xor eax, eax
    EPILOGUE

# testctl_result(sb, rest, len): print-test-result OWNER/NAME ID
FN testctl_result
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call item_arg
    test rax, rax
    jz 8f
    mov rdi, rbx
    mov rsi, rax
    call testmodel_dump_result
    xor eax, eax
    EPILOGUE
8:  mov rdi, rbx
    lea rsi, [rip + .Lm_no_item]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE

# testctl_runs(sb): print-test-runs, then the processes
FN testctl_runs
    PROLOGUE
    mov rbx, rdi
    call testmodel_dump_runs
    mov rdi, rbx
    call testexec_dump
    xor eax, eax
    EPILOGUE

# testctl_coverage(sb, rest, len): print-coverage PATH
FN testctl_coverage
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call trim
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    call testcover_dump
    mov rdi, r12
    call mem_free
    xor eax, eax
    EPILOGUE

.section .rodata
.Lm_no_item: .asciz "no such test item\n"
.Lm_no_profile: .asciz "The test controller does not offer that kind of run"
.Lm_nodebug: .asciz "This test cannot be debugged"
.Lm_idle: .asciz "tests=idle\n"
.Lm_busy: .asciz "tests=busy\n"
.Lm_items: .asciz "items="
.La_cancel: .asciz "cancel"
.La_goto: .asciz "goto"
.La_failure: .asciz "failure"
.La_diff: .asciz "diff"
.La_output: .asciz "output"
.Lt_output: .asciz "Output: "
.Lt_diff: .asciz "Expected \342\206\224 Actual: "

.text
# cmd_testing: Testing: controllers start and show their tests in the Testing section
FN cmd_testing
    push rbx
    call testing_sync
    call testview_ensure
    mov edi, [rip + g_tv_place]
    test edi, edi
    js 1f
    mov esi, 1
    call place_show
1:  mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# cmd_test_coverage_toggle: coverage tints on or off
FN cmd_test_coverage_toggle
    xor dword ptr [rip + g_cov_on], 1
    mov dword ptr [rip + g_dirty], 1
    ret

# cmd_test_next_failure: the place of the next failed item's first message with one, in the
#   controllers' item order after the last one gone to (round, from the first again)
.bss
.p2align 3
nf_ctrl: .quad 0
nf_item: .quad 0
.text
FN cmd_test_next_failure
    PROLOGUE
    xor r15d, r15d              # 0: after the last one; 1: from the start again
1:  lea rbx, [rip + g_ts_ctrls]
    xor r12d, r12d
2:  cmp qword ptr [rbx + TSC_ext], 0
    je 6f
    mov r13d, 1
3:  cmp r13, [rbx + TSC_items + VEC_len]
    jae 6f
    test r15d, r15d
    jnz 31f
    # past the last one gone to
    cmp rbx, [rip + nf_ctrl]
    jb 5f
    ja 31f
    cmp r13, [rip + nf_item]
    jbe 5f
31: mov rdi, rbx
    mov rsi, r13
    call testmodel_item
    cmp qword ptr [rax + TSI_id], 0
    je 5f
    mov ecx, [rax + TSI_own]
    cmp ecx, TSS_FAILED
    je 4f
    cmp ecx, TSS_ERRORED
    jne 5f
4:  mov rdi, rbx
    mov rsi, r13
    call testmodel_result
    test rax, rax
    jz 5f
    mov rax, [rax + TSE_msgs + SB_ptr]
    test rax, rax
    jz 5f
    cmp dword ptr [rax + TSM_l1], 0
    je 5f
    mov [rip + nf_ctrl], rbx
    mov [rip + nf_item], r13
    mov rdi, rbx
    mov rsi, r13
    call testview_select
    mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .La_failure]
    mov ecx, 7
    call testview_action
    EPILOGUE
5:  inc r13
    jmp 3b
6:  add rbx, TSC_SIZE
    inc r12d
    cmp r12d, TS_CTRL_MAX
    jb 2b
    test r15d, r15d
    jnz 9f
    mov r15d, 1
    jmp 1b
9:  EPILOGUE

# ---------------- the Testing section ----------------
# A sidebar section (places.s) drawing the shared tree widget (rtree.s). The tree is a mirror of the
# model: rebuilt from it in a frame after the model changed (g_ts_dirty), listing the children of
# the expanded items only; a node's id is the controller's slot as two digits and the item's id.
# The model's TSF_EXPANDED is the expansion that counts: the tree's expand callback sets it, and the
# rebuild expands the tree's nodes to match.

.equ ID_TV_BTN, 0x5e8000        # + i: the section header's buttons
.equ TV_DETAILS_LINES, 40       # an inline diff's lines at most

.bss
.p2align 3
tv_tree: .quad 0
tv_stack: .zero VEC_SIZE        # rebuild: (node, TSC*, item index) still to list
tv_id: .zero SB_SIZE            # a node id being built
tv_text: .zero SB_SIZE          # a desc, tip or details line being built
tv_counts: .zero 4 * TSS_COUNT
tv_menu_x: .long 0
tv_menu_y: .long 0
.data
.p2align 2
.globl g_tv_place
g_tv_place: .long -1            # the section's place id, -1 before it exists
.text

# testview_ensure(): the section and its tree exist
FN testview_ensure
    PROLOGUE
    cmp qword ptr [rip + tv_tree], 0
    jne 1f
    lea rdi, [rip + tv_tree_ops]
    xor esi, esi
    call tree_new
    mov [rip + tv_tree], rax
1:  cmp dword ptr [rip + g_tv_place], 0
    jge 9f
    mov edi, PLACE_SIDEBAR
    lea rsi, [rip + .Ltv_name]
    lea rdx, [rip + .Ltv_title]
    lea rcx, [rip + tv_place_ops]
    xor r8d, r8d
    call place_add
    mov [rip + g_tv_place], eax
    test eax, eax
    js 9f
    mov edi, eax
    mov esi, IC_BEAKER
    call place_set_icon
    mov dword ptr [rip + g_ts_dirty], 1
9:  EPILOGUE

# node_id(tsc, index): tv_id holds the node's id: the controller's slot as two digits, the item's id
node_id:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + tv_id]
    call sb_clear
    mov rax, rbx
    lea rcx, [rip + g_ts_ctrls]
    sub rax, rcx
    xor edx, edx
    mov ecx, TSC_SIZE
    div rcx                     # the slot
    xor edx, edx
    mov ecx, 10
    div ecx
    push rdx
    push rdx
    lea esi, [rax + '0']
    lea rdi, [rip + tv_id]
    call sb_push_byte
    pop rsi
    pop rsi
    add esi, '0'
    lea rdi, [rip + tv_id]
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    lea rdi, [rip + tv_id]
    mov rsi, [rax + TSI_id]
    mov edx, [rax + TSI_idlen]
    call sb_push
    EPILOGUE

# node_item(tr, node) -> rax TSC*, rdx index of the item a node shows, rax 0 when it is gone
FN testview_node_item
    PROLOGUE
    call tree_node_id
    cmp rdx, 2
    jb 8f
    mov r12, rax
    mov r13, rdx
    movzx eax, byte ptr [r12]
    sub eax, '0'
    imul eax, eax, 10
    movzx ecx, byte ptr [r12 + 1]
    sub ecx, '0'
    add eax, ecx
    cmp eax, TS_CTRL_MAX
    jae 8f
    imul rbx, rax, TSC_SIZE
    lea rcx, [rip + g_ts_ctrls]
    add rbx, rcx
    cmp qword ptr [rbx + TSC_ext], 0
    je 8f
    xor edx, edx
    cmp r13, 2
    je 7f
    mov rdi, rbx
    lea rsi, [r12 + 2]
    lea rdx, [r13 - 2]
    call testmodel_find
    test rax, rax
    js 8f
    mov rdx, rax
7:  mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# tv_kid(tsc, index) -> eax the node listed for the item under the parent being listed, decorated
tv_kid:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call node_id
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    mov r13, rax
    # its kind of children: leaf, or children (lazy ones count), expanded as the model says
    mov r9d, KIDS_LEAF
    cmp dword ptr [r13 + TSI_first], 0
    jge 1f
    test dword ptr [r13 + TSI_flags], TSF_LAZY
    jz 2f
1:  mov rdi, r13
    call tv_is_open
    mov r9d, KIDS_CLOSED
    test eax, eax
    jz 2f
    mov r9d, KIDS_OPEN
2:  mov r14d, r9d
    mov rdi, [rip + tv_tree]
    mov rsi, [rip + tv_id + SB_ptr]
    mov rdx, [rip + tv_id + SB_len]
    mov rcx, [r13 + TSI_label]
    push r9
    push r9
    mov rdi, rcx
    call strlen
    mov r8, rax
    pop r9
    pop r9
    mov rdi, [rip + tv_tree]
    mov rsi, [rip + tv_id + SB_ptr]
    mov rdx, [rip + tv_id + SB_len]
    mov rcx, [r13 + TSI_label]
    call tree_kid
    cmp eax, -1
    jne 3f
    # the id is elsewhere in the tree (the item moved): that node goes first
    mov rdi, [rip + tv_tree]
    mov rsi, [rip + tv_id + SB_ptr]
    mov rdx, [rip + tv_id + SB_len]
    call tree_find
    cmp eax, 0
    jle 9f
    mov rdi, [rip + tv_tree]
    mov esi, eax
    call tree_del
    mov rdi, [r13 + TSI_label]
    call strlen
    mov r8, rax
    mov rdi, [rip + tv_tree]
    mov rsi, [rip + tv_id + SB_ptr]
    mov rdx, [rip + tv_id + SB_len]
    mov rcx, [r13 + TSI_label]
    mov r9d, r14d
    call tree_kid
    cmp eax, -1
    je 9f
3:  mov r15d, eax
    cmp r14d, KIDS_LEAF
    je 31f
    mov rdi, r13
    call tv_is_open
    mov edx, eax
    mov rdi, [rip + tv_tree]
    mov esi, r15d
    call tree_expand
31: # the state's icon
    mov eax, [r13 + TSI_state]
    lea rcx, [rip + state_icons]
    mov edx, [rcx + rax*8]
    mov ecx, [rcx + rax*8 + 4]
    mov rdi, [rip + tv_tree]
    mov esi, r15d
    call tree_set_icon
    # the desc: the duration, else the item's desc
    lea rdi, [rip + tv_text]
    call sb_clear
    mov esi, [r13 + TSI_ms]
    cmp esi, -1
    je 4f
    lea rdi, [rip + tv_text]
    call sb_push_u64
    lea rdi, [rip + tv_text]
    lea rsi, [rip + .Ltv_ms]
    call sb_push_cstr
    jmp 5f
4:  mov rsi, [r13 + TSI_desc]
    test rsi, rsi
    jz 5f
    lea rdi, [rip + tv_text]
    call sb_push_cstr
5:  mov rdi, [rip + tv_tree]
    mov esi, r15d
    mov rdx, [rip + tv_text + SB_ptr]
    mov rcx, [rip + tv_text + SB_len]
    call tree_set_desc
    # the tip: a discovery problem, else the last result's message
    mov rsi, [r13 + TSI_error]
    test rsi, rsi
    jnz 6f
    mov rsi, [r13 + TSI_msg]
6:  xor ecx, ecx
    xor edx, edx
    test rsi, rsi
    jz 61f
    mov rdi, rsi
    push rsi
    push rsi
    call strlen
    mov rcx, rax
    pop rdx
    pop rdx
61: mov rdi, [rip + tv_tree]
    mov esi, r15d
    call tree_set_tip
    mov eax, r15d
    EPILOGUE
9:  mov eax, -1
    EPILOGUE

# stack_push(node, tsc, index)
stack_push:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + tv_stack]
    mov esi, 24
    call vec_push
    mov [rax], rbx
    mov [rax + 8], r12
    mov [rax + 16], r13
    pop r13
    pop r12
    pop rbx
    ret

# testview_rebuild(): the tree again from the model (only after it changed)
FN testview_rebuild
    PROLOGUE
    cmp qword ptr [rip + tv_tree], 0
    je 9f
    cmp dword ptr [rip + g_ts_dirty], 0
    je 9f
    mov dword ptr [rip + g_ts_dirty], 0
    mov qword ptr [rip + tv_stack + VEC_len], 0
    call tv_filter_marks
    mov rdi, [rip + tv_tree]
    xor esi, esi
    call tree_kids_begin
    lea rbx, [rip + g_ts_ctrls]
    xor r12d, r12d
1:  cmp qword ptr [rbx + TSC_ext], 0
    je 2f
    mov rdi, rbx
    xor esi, esi
    call tv_kid
    cmp eax, -1
    je 2f
    mov r13d, eax
    mov rdi, rbx
    xor esi, esi
    call testmodel_item
    mov rdi, rax
    call tv_is_open
    test eax, eax
    jz 2f
    mov edi, r13d
    mov rsi, rbx
    xor edx, edx
    call stack_push
2:  add rbx, TSC_SIZE
    inc r12d
    cmp r12d, TS_CTRL_MAX
    jb 1b
    mov rdi, [rip + tv_tree]
    xor esi, esi
    call tree_kids_end
    # the expanded items' children, one parent at a time
3:  mov rax, [rip + tv_stack + VEC_len]
    test rax, rax
    jz 9f
    dec rax
    mov [rip + tv_stack + VEC_len], rax
    imul rax, rax, 24
    add rax, [rip + tv_stack + VEC_ptr]
    mov r13, [rax]              # node
    mov rbx, [rax + 8]          # TSC*
    mov r12, [rax + 16]         # item
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    test dword ptr [rax + TSI_flags], TSF_LAZY
    jz 4f
    # lazy: asked for when the tree wants its children; a failed ask is an error row with Retry
    test dword ptr [rax + TSI_flags], TSF_RESOLVING
    jnz 3b
    cmp qword ptr [rax + TSI_error], 0
    je 3b
    mov rdi, [rip + tv_tree]
    mov esi, r13d
    call tree_set_error
    jmp 3b
4:  mov rdi, [rip + tv_tree]
    mov esi, r13d
    call tree_kids_begin
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    movsxd r14, dword ptr [rax + TSI_first]
5:  test r14, r14
    js 7f
    cmp dword ptr [rip + tv_fon], 0
    je 50f
    mov rdi, rbx
    mov rsi, r14
    call testmodel_item
    test dword ptr [rax + TSI_flags], TSF_SHOW
    jz 6f                       # the filter hides it
50: mov rdi, rbx
    mov rsi, r14
    call tv_kid
    cmp eax, -1
    je 6f
    mov r15d, eax
    mov rdi, rbx
    mov rsi, r14
    call testmodel_item
    push rax
    push rax
    mov rdi, rax
    call tv_is_open
    pop rcx
    pop rcx
    test eax, eax
    jz 6f
    mov rax, rcx
    cmp dword ptr [rax + TSI_first], 0
    jge 51f
    test dword ptr [rax + TSI_flags], TSF_LAZY
    jz 6f
51: mov edi, r15d
    mov rsi, rbx
    mov rdx, r14
    call stack_push
6:  mov rdi, rbx
    mov rsi, r14
    call testmodel_item
    movsxd r14, dword ptr [rax + TSI_next]
    jmp 5b
7:  mov rdi, [rip + tv_tree]
    xor esi, esi
    call tree_kids_end
    jmp 3b
9:  EPILOGUE

# ---- the tree's callbacks

# tv_activate(ctx, tr, node): Enter or a double click: go to the test
tv_activate:
    PROLOGUE
    mov rdi, rsi
    mov esi, edx
    call testview_node_item
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .La_goto]
    mov ecx, 4
    call testview_action
9:  EPILOGUE

# tv_expand(ctx, tr, node, on): the model's expansion follows (a lazy item is resolved)
tv_expand:
    PROLOGUE
    mov r12d, ecx
    mov rdi, rsi
    mov esi, edx
    call testview_node_item
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    mov edx, r12d
    call testview_expand
9:  EPILOGUE

# tv_select(ctx, tr): the cursor's item is the selected one
tv_select:
    PROLOGUE
    mov rbx, rsi
    mov rdi, rbx
    call tree_cursor
    cmp eax, -1
    je 9f
    mov rdi, rbx
    mov esi, eax
    call testview_node_item
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call testview_select
9:  EPILOGUE

# tv_load(ctx, tr, node) and tv_retry: a lazy item's children are asked for
tv_load:
    PROLOGUE
    mov rdi, rsi
    mov esi, edx
    call testview_node_item
    test rax, rax
    jz 9f
    mov rbx, rax
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    test dword ptr [rax + TSI_flags], TSF_LAZY
    jz 1f
    mov rdi, [rbx + TSC_ext]
    mov rsi, rbx
    mov rdx, r12
    call testproto_resolve
    jmp 9f
1:  mov dword ptr [rip + g_ts_dirty], 1    # given by the next rebuild
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# tv_menu(ctx, tr, node, x, y): the item's menu
tv_menu:
    PROLOGUE
    mov [rip + tv_menu_x], ecx
    mov [rip + tv_menu_y], r8d
    mov rdi, rsi
    mov esi, edx
    call testview_node_item
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call testview_select
    lea rdi, [rip + tv_menu_items]
    mov esi, [rip + tv_menu_x]
    mov edx, [rip + tv_menu_y]
    call ctx_menu_open
9:  EPILOGUE

# testview_menu_at(tsc, index, x, y): the item's menu (the gutter glyph's right click)
FN testview_menu_at
    PROLOGUE
    mov r12d, edx
    mov r13d, ecx
    call testview_select
    lea rdi, [rip + tv_menu_items]
    mov esi, r12d
    mov edx, r13d
    call ctx_menu_open
    EPILOGUE

# the menu's items act on the selected item (the gutter's play menu uses the first three, testgutter.s)
.globl tv_m_run, tv_m_debug, tv_m_coverage
tv_m_run:
    mov edi, TSP_RUN
    jmp sel_run
tv_m_debug:
    mov edi, TSP_DEBUG
    jmp sel_run
tv_m_coverage:
    mov edi, TSP_COVERAGE
sel_run:
    push rbx
    mov ebx, edi
    call testview_selected
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    mov edx, ebx
    call testview_run_item
9:  pop rbx
    ret
tv_m_goto:
    lea rdi, [rip + .La_goto]
    jmp sel_action
tv_m_failure:
    lea rdi, [rip + .La_failure]
    jmp sel_action
tv_m_diff:
    lea rdi, [rip + .La_diff]
    jmp sel_action
tv_m_output:
    lea rdi, [rip + .La_output]
sel_action:
    push rbx
    mov rbx, rdi
    call testview_selected
    test rax, rax
    jz 9f
    push rax
    push rdx
    mov rdi, rbx
    call strlen
    mov rcx, rax
    pop rsi
    pop rdi
    mov rdx, rbx
    call testview_action
9:  pop rbx
    ret

# ---- the section's callbacks

# tv_keys(ctx, keysym, cp, mods) -> eax 1 when taken: r runs, d debugs the cursor's item; the
#   tree's keys otherwise
tv_keys:
    PROLOGUE
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    cmp dword ptr [rip + tv_find], 0
    je 10f
    # the filter field: Escape clears it, then leaves it, as Enter and Down do
    cmp r12d, KEY_ESCAPE
    jne 11f
    lea rdi, [rip + tv_ftf]
    call tf_text
    test rdx, rdx
    jz 12f
    lea rdi, [rip + tv_ftf]
    call tf_clear
    mov dword ptr [rip + g_ts_dirty], 1
    mov eax, 1
    EPILOGUE
11: cmp r12d, KEY_RETURN
    je 12f
    cmp r12d, KEY_DOWN
    jne 13f
12: mov dword ptr [rip + tv_find], 0
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
13: lea rdi, [rip + tv_ftf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
    test eax, eax
    jz 9f
    mov dword ptr [rip + g_ts_dirty], 1
    EPILOGUE
10: cmp r14d, MOD_CTRL          # ctrl+f: the filter
    jne 14f
    cmp r12d, 'f'
    jne 14f
    mov dword ptr [rip + tv_find], 1
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
14: test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz 8f
    cmp r13d, 'r'
    jne 1f
    call tv_m_run
    mov eax, 1
    EPILOGUE
1:  cmp r13d, 'd'
    jne 8f
    call tv_m_debug
    mov eax, 1
    EPILOGUE
8:  mov rdi, [rip + tv_tree]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tree_key
9:  EPILOGUE

# tv_header(ctx, right, y, h) -> eax the x left of its buttons: Run All, Run with Coverage, Re-run
#   Failed, Cancel
tv_header:
    PROLOGUE 16
    mov r12d, esi               # the right edge, moving left
    mov r13d, edx
    mov r14d, ecx
    mov ebx, 3
1:  M eax, MI_24
    sub r12d, eax
    lea edi, [rbx + ID_TV_BTN]
    mov esi, r12d
    mov edx, r13d
    M ecx, MI_24
    mov r8d, r14d
    lea rax, [rip + header_icons]
    mov r9d, [rax + rbx*4]
    call ui_icon_btn
    mov r8d, eax
    lea edi, [rbx + ID_TV_BTN]
    mov esi, r12d
    lea edx, [r13 + r14]
    M ecx, MI_24
    lea rax, [rip + header_tips]
    mov r9, [rax + rbx*8]
    call tip_note_text
    test eax, UB_CLICK
    jz 2f
    lea rax, [rip + header_cmds]
    call [rax + rbx*8]
2:  dec ebx
    jns 1b
    mov eax, r12d
    EPILOGUE

# tv_draw(ctx, x, y, w, h): a line of counts, the tree, and the selected item's last result
tv_draw:
    PROLOGUE 48
    mov [rsp], esi              # x
    mov [rsp + 4], edx          # y
    mov [rsp + 8], ecx          # w
    mov [rsp + 12], r8d         # h
    call testview_rebuild
    # the counts: "N passed  N failed  N skipped" (and "running" while runs are)
    M eax, MI_ROW
    mov [rsp + 16], eax         # the counts line's height
    lea rdi, [rip + tv_counts]
    call testmodel_tally
    lea rdi, [rip + tv_text]
    call sb_clear
    lea rdi, [rip + tv_text]
    mov esi, [rip + tv_counts + 4*TSS_PASSED]
    call sb_push_u64
    lea rdi, [rip + tv_text]
    lea rsi, [rip + .Ltv_passed]
    call sb_push_cstr
    mov eax, [rip + tv_counts + 4*TSS_FAILED]
    add eax, [rip + tv_counts + 4*TSS_ERRORED]
    lea rdi, [rip + tv_text]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rip + tv_text]
    lea rsi, [rip + .Ltv_failed]
    call sb_push_cstr
    lea rdi, [rip + tv_text]
    mov esi, [rip + tv_counts + 4*TSS_SKIPPED]
    call sb_push_u64
    lea rdi, [rip + tv_text]
    lea rsi, [rip + .Ltv_skipped]
    call sb_push_cstr
    xor edi, edi
    call testmodel_active
    test eax, eax
    jz 1f
    lea rdi, [rip + tv_text]
    lea rsi, [rip + .Ltv_running]
    call sb_push_cstr
1:  M ecx, MI_12
    mov esi, [rsp]
    add esi, ecx
    lea rdi, [rip + g_face_small]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 16]
    mov r8, [rip + tv_text + SB_ptr]
    mov r9, [rip + tv_text + SB_len]
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    # the filter row: the field and Failed only; it is part of the counts' height from here on
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rsp + 16]
    mov edx, [rsp + 8]
    call filter_row
    add [rsp + 16], eax
    # the details' height: a third of the section for an item with something to show
    call details_lines
    mov r15d, eax               # lines
    xor r14d, r14d              # the details' height
    test r15d, r15d
    jz 2f
    call dd_lh
    imul eax, r15d
    M ecx, MI_8
    add eax, ecx
    mov ecx, [rsp + 12]
    sub ecx, [rsp + 16]
    shr ecx, 1                  # at most half of what is left
    cmp eax, ecx
    cmova eax, ecx
    mov r14d, eax
2:  # the tree
    call place_focused
    xor r9d, r9d
    cmp eax, [rip + g_tv_place]
    sete r9b
    mov rdi, [rip + tv_tree]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rsp + 16]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    sub r8d, [rsp + 16]
    sub r8d, r14d
    call tree_draw
    test r14d, r14d
    jz 9f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rsp + 12]
    sub esi, r14d
    mov edx, [rsp + 8]
    mov ecx, r14d
    call details_draw
9:  EPILOGUE

# ---- the selected item's last result, under the tree

# details_lines() -> eax the lines the details want: 0 without a result with messages or output
details_lines:
    PROLOGUE
    call testview_selected
    test rax, rax
    jz 8f
    mov rbx, rax
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r12
    call testmodel_result
    test rax, rax
    jz 8f
    mov r13, rax
    mov eax, [r13 + TSE_nmsg]
    test eax, eax
    jnz 1f
    cmp qword ptr [r13 + TSE_out + SB_len], 0
    je 8f
1:  mov eax, 14
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# details_draw(x, y, w, h): "STATE · N ms · run R", the first message (its first lines, then its
#   values as a line diff), then the links Go to Failure, Open Diff, Output
.bss
.p2align 3
dd_x: .long 0
dd_y: .long 0
dd_w: .long 0
dd_bottom: .long 0
.p2align 3
dd_key: .quad 0                 # the result the cached diff is of, and its messages' length
dd_keylen: .quad 0
dd_cache: .zero SB_SIZE
.text
details_draw:
    PROLOGUE 32
    mov [rip + dd_x], edi
    mov [rip + dd_y], esi
    mov [rip + dd_w], edx
    lea eax, [rsi + rcx]
    mov [rip + dd_bottom], eax
    mov r8d, ecx
    mov ecx, edx
    mov edx, esi
    mov esi, edi
    mov edi, esi
    push r8
    push r8
    mov edi, [rip + dd_x]
    mov esi, [rip + dd_y]
    mov edx, [rip + dd_w]
    mov ecx, 1
    COLOR r8d, T_BORDER
    call gfx_fill
    pop r8
    pop r8
    mov edi, [rip + dd_x]
    mov esi, [rip + dd_y]
    mov edx, [rip + dd_w]
    mov ecx, r8d
    call gfx_clip_push
    M eax, MI_4
    add [rip + dd_y], eax
    call testview_selected
    test rax, rax
    jz 9f
    mov rbx, rax
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r12
    call testmodel_item
    mov r15, rax
    mov rdi, rbx
    mov rsi, r12
    call testmodel_result
    test rax, rax
    jz 9f
    mov r13, rax
    # the header
    lea rdi, [rip + tv_text]
    call sb_clear
    mov rsi, [r15 + TSI_label]
    lea rdi, [rip + tv_text]
    call sb_push_cstr
    lea rdi, [rip + tv_text]
    lea rsi, [rip + .Ltv_dot]
    call sb_push_cstr
    mov edi, [r15 + TSI_own]
    call testmodel_state_word
    lea rdi, [rip + tv_text]
    mov rsi, rax
    call sb_push_cstr
    mov esi, [r15 + TSI_ms]
    cmp esi, -1
    je 1f
    push rsi
    push rsi
    lea rdi, [rip + tv_text]
    lea rsi, [rip + .Ltv_dot]
    call sb_push_cstr
    pop rsi
    pop rsi
    lea rdi, [rip + tv_text]
    call sb_push_u64
    lea rdi, [rip + tv_text]
    lea rsi, [rip + .Ltv_ms]
    call sb_push_cstr
1:  mov eax, [r15 + TSI_own]
    lea rcx, [rip + state_icons]
    mov ecx, [rcx + rax*8 + 4]
    COLOR eax, T_PANEL_FG
    cmp ecx, -1
    je 11f
    lea rdx, [rip + g_theme]
    mov eax, [rdx + rcx*4]
11: mov edi, eax
    call dd_line_text
    # the first message: its lines (at most 4), then its values
    mov r14, [r13 + TSE_msgs + SB_ptr]
    test r14, r14
    jz 5f
    cmp dword ptr [r13 + TSE_nmsg], 0
    je 5f
    lea rsi, [r14 + TSM_SIZE]
    mov edx, [r14 + TSM_text]
    mov ecx, 4
    COLOR edi, T_PANEL_FG
    call dd_lines
    # the values as a diff, expected removed and actual added
    cmp dword ptr [r14 + TSM_exp], -1
    je 4f
    cmp dword ptr [r14 + TSM_act], -1
    je 4f
    # built again only when the result changed (a frame draws it again and again)
    cmp r13, [rip + dd_key]
    jne 31f
    mov rax, [r13 + TSE_msgs + SB_len]
    cmp rax, [rip + dd_keylen]
    je 32f
31: lea rdi, [r14 + TSM_SIZE]
    mov eax, [r14 + TSM_text]
    add rdi, rax
    mov eax, [r14 + TSM_path]
    add rdi, rax                # expected
    mov esi, [r14 + TSM_exp]
    lea rdx, [rdi + rsi]        # actual
    mov ecx, [r14 + TSM_act]
    call testdiff_build         # rax, rdx: the diff's text, its header first
    push rax
    push rdx
    lea rdi, [rip + dd_cache]
    call sb_clear
    pop rdx
    pop rsi
    lea rdi, [rip + dd_cache]
    call sb_push
    mov [rip + dd_key], r13
    mov rax, [r13 + TSE_msgs + SB_len]
    mov [rip + dd_keylen], rax
32: mov rdi, [rip + dd_cache + SB_ptr]
    mov rsi, [rip + dd_cache + SB_len]
    call dd_diff
4:  # links: Go to Failure, Open Diff
    mov edi, ID_TV_BTN + 8
    cmp dword ptr [r14 + TSM_l1], 0
    je 41f
    lea rsi, [rip + .Ltv_goto_failure]
    lea rdx, [rip + tv_m_failure]
    call dd_link
41: cmp dword ptr [r14 + TSM_exp], -1
    je 5f
    mov edi, ID_TV_BTN + 9
    lea rsi, [rip + .Ltv_open_diff]
    lea rdx, [rip + tv_m_diff]
    call dd_link
5:  cmp qword ptr [r13 + TSE_out + SB_len], 0
    je 6f
    mov edi, ID_TV_BTN + 10
    lea rsi, [rip + .Ltv_output]
    lea rdx, [rip + tv_m_output]
    call dd_link
6:  call dd_newline
    # the output's last lines
    cmp qword ptr [r13 + TSE_out + SB_len], 0
    je 9f
    mov rdi, [r13 + TSE_out + SB_ptr]
    mov rsi, [r13 + TSE_out + SB_len]
    call tail_lines             # rax, rdx: the last lines that fit
    mov rsi, rax
    mov ecx, 200
    COLOR edi, T_MUTED
    call dd_lines
9:  call gfx_clip_pop
    EPILOGUE

# dd_line_text(argb): tv_text as one line of the details
dd_line_text:
    mov rsi, [rip + tv_text + SB_ptr]
    mov rdx, [rip + tv_text + SB_len]
    jmp dd_line

# dd_line(argb, ptr, len): one line at the next y (none past the bottom)
.bss
dd_link_x: .long 0
.text
dd_line:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    mov eax, [rip + dd_y]
    cmp eax, [rip + dd_bottom]
    jge 9f
    M ecx, MI_12
    mov esi, [rip + dd_x]
    add esi, ecx
    mov edx, [rip + dd_y]
    lea rdi, [rip + g_face_small]
    call dd_lh
    mov ecx, eax
    lea rdi, [rip + g_face_small]
    mov r8, r13
    mov r9, r14
    push r12
    push r12
    call ui_text_v
    add rsp, 16
    call dd_lh
    add [rip + dd_y], eax
    mov dword ptr [rip + dd_link_x], 0
9:  EPILOGUE

# dd_lh() -> eax a details line's height: the small face's line and 4 points
dd_lh:
    mov eax, [rip + g_face_small + FACE_lineh]
    add eax, [rip + g_mt + 4*MI_4]
    ret

# dd_newline(): the links' line ends
dd_newline:
    cmp dword ptr [rip + dd_link_x], 0
    je 1f
    call dd_lh
    add [rip + dd_y], eax
    mov dword ptr [rip + dd_link_x], 0
1:  ret

# dd_lines(argb, ptr, len, max lines): the text's lines, each its own line of the details
dd_lines:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    lea r14, [rsi + rdx]
    mov r15d, ecx
1:  test r15d, r15d
    jz 9f
    cmp r13, r14
    jae 9f
    mov rcx, r13
2:  cmp rcx, r14
    jae 3f
    cmp byte ptr [rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  mov rbx, rcx
    mov edi, r12d
    mov rsi, r13
    mov rdx, rcx
    sub rdx, r13
    call dd_line
    lea r13, [rbx + 1]
    dec r15d
    jmp 1b
9:  EPILOGUE

# dd_diff(ptr, len): a unified diff's lines (past its header), removed in the error color and added
#   in the success color, at most TV_DETAILS_LINES
dd_diff:
    PROLOGUE
    mov r13, rsi
    lea r14, [rdi + rsi]
    mov r13, rdi
    xor r15d, r15d              # lines drawn, the header not counted
    xor ebx, ebx                # 1 past the header
1:  cmp r13, r14
    jae 9f
    cmp r15d, TV_DETAILS_LINES
    jae 9f
    mov rcx, r13
2:  cmp rcx, r14
    jae 3f
    cmp byte ptr [rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  mov r12, rcx
    test ebx, ebx
    jnz 4f
    mov ebx, 1
    jmp 6f
4:  COLOR edi, T_MUTED
    cmp byte ptr [r13], '-'
    jne 41f
    COLOR edi, T_ERROR
41: cmp byte ptr [r13], '+'
    jne 42f
    COLOR edi, T_SUCCESS
42: mov rsi, r13
    mov rdx, r12
    sub rdx, r13
    call dd_line
    inc r15d
6:  lea r13, [r12 + 1]
    jmp 1b
9:  EPILOGUE

# dd_link(id, label cstr, fn): a link on the links' line; a click calls fn
dd_link:
    PROLOGUE 16
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov eax, [rip + dd_y]
    cmp eax, [rip + dd_bottom]
    jge 9f
    mov eax, [rip + dd_link_x]
    test eax, eax
    jnz 1f
    M eax, MI_12
    add eax, [rip + dd_x]
    mov [rip + dd_link_x], eax
1:  mov rdi, r12
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r12
    mov rdx, rax
    call text_width
    mov r14d, eax
    call dd_lh
    mov r8d, eax
    mov edi, ebx
    mov esi, [rip + dd_link_x]
    mov edx, [rip + dd_y]
    mov ecx, r14d
    call ui_btn
    mov r15d, eax
    COLOR r9d, T_ACCENT
    push r9
    push r9
    call dd_lh
    mov ecx, eax
    pop r9
    pop r9
    lea rdi, [rip + g_face_small]
    mov esi, [rip + dd_link_x]
    mov edx, [rip + dd_y]
    mov r8, r12
    call ui_text_c
    M eax, MI_12
    add eax, r14d
    add [rip + dd_link_x], eax
    test r15d, UB_HOVER
    jz 2f
    mov edi, CUR_POINTER
    call ui_set_cursor
2:  test r15d, UB_CLICK
    jz 9f
    call r13
9:  EPILOGUE

# tail_lines(ptr, len) -> rax, rdx: the last 8 lines of the text (a final LF left out)
tail_lines:
    lea rcx, [rdi + rsi]
    test rsi, rsi
    jz 9f
    cmp byte ptr [rcx - 1], 10
    jne 1f
    dec rcx
1:  mov rdx, rcx
    mov r8d, 8
2:  cmp rdx, rdi
    jbe 8f
    cmp byte ptr [rdx - 1], 10
    jne 3f
    dec r8d
    jz 8f
3:  dec rdx
    jmp 2b
8:  mov rax, rdx
    sub rcx, rdx
    mov rdx, rcx
    ret
9:  mov rax, rdi
    xor edx, edx
    ret

# testctl_print_view(sb, rest, len): print-testing: the section's tree rows (tree_dump)
FN testctl_print_view
    PROLOGUE
    mov rbx, rdi
    call testview_ensure
    call testview_rebuild
    mov rdi, [rip + tv_tree]
    mov rsi, rbx
    call tree_dump
    xor eax, eax
    EPILOGUE

.section .rodata
.Ltv_name: .asciz "testing"
.Ltv_title: .asciz "Testing"
.Ltv_ms: .asciz " ms"
.Ltv_dot: .asciz " \302\267 "
.Ltv_passed: .asciz " passed  "
.Ltv_failed: .asciz " failed  "
.Ltv_skipped: .asciz " skipped"
.Ltv_running: .asciz "  \302\267 running"
.Ltv_goto_failure: .asciz "Go to Failure"
.Ltv_open_diff: .asciz "Open Diff"
.Ltv_output: .asciz "Output"
.Ltm_run: .asciz "Run"
.Ltm_debug: .asciz "Debug"
.Ltm_coverage: .asciz "Run with Coverage"
.Ltm_goto: .asciz "Go to Test"
.Ltm_failure: .asciz "Go to Failure"
.Ltm_diff: .asciz "Open Diff"
.Ltm_output: .asciz "Show Output"
.p2align 3
# per state: icon, color slot (-1 muted)
state_icons:
    .long IC_DOT, T_MUTED           # not run
    .long IC_SLASH, T_MUTED         # skipped
    .long IC_CHECK, T_SUCCESS       # passed
    .long IC_CLOSE, T_ERROR         # failed
    .long IC_WARNING, T_ERROR          # errored
    .long IC_RING, T_MUTED          # queued
    .long IC_RING, T_ACCENT         # running
header_icons: .long IC_PLAY, IC_BEAKER, IC_REFRESH, IC_STOP
.p2align 3
header_cmds: .quad cmd_test_run_all, cmd_test_coverage_all, cmd_test_rerun_failed, cmd_test_cancel
header_tips: .quad .Lht_run, .Lht_coverage, .Lht_rerun, .Lht_cancel
tv_menu_items:
    .quad .Ltm_run, tv_m_run, .Ltm_debug, tv_m_debug, .Ltm_coverage, tv_m_coverage
    .quad .Ltm_goto, tv_m_goto, .Ltm_failure, tv_m_failure, .Ltm_diff, tv_m_diff
    .quad .Ltm_output, tv_m_output, 0, 0
tv_place_ops: .quad tv_draw, tv_keys, 0, 0, tv_header, 0
tv_tree_ops: .quad tv_activate, tv_expand, tv_select, 0, tv_menu, 0, tv_load, tv_load

# ---------------- the status bar item ----------------
# "Testing N/M" while runs are active (N of their M results finished), then the passed and failed
# tests of every controller (a check and a cross with their counts); nothing before the session's
# first run. A click shows Testing.

.equ ID_TV_STATUS, 0x5e8010

.bss
.p2align 3
st_lab: .zero SB_SIZE           # the text drawn ("Testing 3/5"), or the counts as text for print
st_cnt: .zero 4*TSS_COUNT
st_run: .zero 4*TSS_COUNT
st_x: .long 0                   # where it was drawn last (print-test-status), w 0 for not drawn
st_y: .long 0
st_w: .long 0
st_h: .long 0
st_pass: .long 0
st_fail: .long 0
.text

# st_text(): st_lab for the state now: eax 1 while runs are active, 0 after, -1 before the first run
st_text:
    PROLOGUE
    lea rdi, [rip + st_lab]
    call sb_clear
    cmp dword ptr [rip + g_ts_ran], 0
    je 8f
    xor r12d, r12d              # finished
    xor r13d, r13d              # all
    xor r14d, r14d              # active runs
    lea rbx, [rip + g_ts_runs]
    xor r15d, r15d
1:  cmp qword ptr [rbx + TSR_ext], 0
    je 3f
    cmp dword ptr [rbx + TSR_state], TSRS_QUEUED
    je 2f
    cmp dword ptr [rbx + TSR_state], TSRS_RUNNING
    jne 3f
2:  inc r14d
    mov rdi, rbx
    lea rsi, [rip + st_run]
    call testmodel_counts
    lea rcx, [rip + st_run]
    xor edx, edx
21: mov eax, [rcx + rdx*4]
    add r13d, eax
    cmp edx, TSS_SKIPPED
    jb 22f
    cmp edx, TSS_ERRORED
    ja 22f
    add r12d, eax
22: inc edx
    cmp edx, TSS_COUNT
    jb 21b
3:  add rbx, TSR_SIZE
    inc r15d
    cmp r15d, TS_RUNS_MAX
    jb 1b
    test r14d, r14d
    jz 5f
    lea rdi, [rip + st_lab]
    lea rsi, [rip + .Ls_testing]
    call sb_push_cstr
    lea rdi, [rip + st_lab]
    mov esi, r12d
    call sb_push_u64
    lea rdi, [rip + st_lab]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + st_lab]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + st_lab]
    xor esi, esi
    call sb_push_byte
    mov eax, 1
    EPILOGUE
5:  lea rdi, [rip + st_cnt]
    call testmodel_tally
    lea rcx, [rip + st_cnt]
    mov eax, [rcx + 4*TSS_PASSED]
    mov [rip + st_pass], eax
    mov eax, [rcx + 4*TSS_FAILED]
    add eax, [rcx + 4*TSS_ERRORED]
    mov [rip + st_fail], eax
    xor eax, eax
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# testview_status_item(x, y, h) -> eax the x after it (the status bar calls it)
FN testview_status_item
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov dword ptr [rip + st_w], 0
    call st_text
    test eax, eax
    js 9f
    mov [rsp + 12], eax
    M ebx, MI_8                 # the padding
    lea r15d, [rbx + rbx]       # the width
    test eax, eax
    jz 1f
    lea rdi, [rip + g_face_small]
    mov rsi, [rip + st_lab + SB_ptr]
    mov rdx, [rip + st_lab + SB_len]
    dec rdx
    call text_width
    add r15d, eax
    jmp 2f
1:  # two icons and their counts
    lea rdi, [rip + st_lab]
    mov esi, [rip + st_pass]
    call sb_push_u64
    lea rdi, [rip + st_lab]
    call sb_z_tv
    lea rdi, [rip + g_face_small]
    mov rsi, rax
    mov rdx, [rip + st_lab + SB_len]
    call text_width
    add r15d, eax
    lea rdi, [rip + st_lab]
    call sb_clear
    lea rdi, [rip + st_lab]
    mov esi, [rip + st_fail]
    call sb_push_u64
    lea rdi, [rip + st_lab]
    call sb_z_tv
    lea rdi, [rip + g_face_small]
    mov rsi, rax
    mov rdx, [rip + st_lab + SB_len]
    call text_width
    add r15d, eax
    M eax, MI_ICON
    lea r15d, [r15 + rax*2]
    M eax, MI_4
    lea r15d, [r15 + rax*2]     # icon to count
    add r15d, ebx               # between the two
2:  mov eax, [rsp]
    mov [rip + st_x], eax
    mov eax, [rsp + 4]
    mov [rip + st_y], eax
    mov [rip + st_w], r15d
    mov eax, [rsp + 8]
    mov [rip + st_h], eax
    mov edi, ID_TV_STATUS
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, r15d
    mov r8d, [rsp + 8]
    call ui_btn
    mov [rsp + 16], eax
    test eax, UB_HOVER
    jz 3f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, r15d
    mov ecx, [rsp + 8]
    COLOR r8d, T_HOVER
    call gfx_fill
3:  mov r12d, [rsp]
    add r12d, ebx               # the pen
    cmp dword ptr [rsp + 12], 0
    je 4f
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8, [rip + st_lab + SB_ptr]
    COLOR r9d, T_ACCENT
    call ui_text_c
    jmp 7f
4:  mov edi, IC_CHECK
    mov esi, r12d
    mov edx, [rip + st_pass]
    COLOR ecx, T_SUCCESS
    call st_icon_count
    lea r12d, [rax + rbx]
    mov edi, IC_CLOSE
    mov esi, r12d
    mov edx, [rip + st_fail]
    COLOR ecx, T_ERROR
    call st_icon_count
7:  test dword ptr [rsp + 16], UB_CLICK
    jz 8f
    call cmd_testing
8:  mov eax, [rsp]
    add eax, r15d
    EPILOGUE
9:  mov eax, [rsp]
    EPILOGUE

# st_icon_count(icon, x, count, argb) -> eax the x after them: the icon in that color, then the count
st_icon_count:
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    M eax, MI_ICON
    mov ecx, [rip + st_h]
    sub ecx, eax
    sar ecx, 1
    mov edx, [rip + st_y]
    add edx, ecx
    mov edi, ebx
    mov esi, r12d
    mov ecx, eax
    mov r8d, r14d
    call icon_draw
    M eax, MI_ICON
    add r12d, eax
    M eax, MI_4
    add r12d, eax
    lea rdi, [rip + st_lab]
    call sb_clear
    lea rdi, [rip + st_lab]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + st_lab]
    call sb_z_tv
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, [rip + st_y]
    mov ecx, [rip + st_h]
    mov r8, rax
    COLOR r9d, T_FG
    call ui_text_c
    EPILOGUE

# sb_z_tv(sb) -> rax its bytes with a NUL after them (not counted)
sb_z_tv:
    push rbx
    mov rbx, rdi
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rbx + SB_len]
    mov rax, [rbx + SB_ptr]
    pop rbx
    ret

# testctl_status(sb, rest, len): print-test-status: "test-status none", or "test-status x= y= w= h=
#   text=Testing N/M" / "text=passed=P failed=F" as the bar drew it last
testctl_status:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ls_status]
    call sb_push_cstr
    cmp dword ptr [rip + st_w], 0
    jne 1f
    mov rdi, rbx
    lea rsi, [rip + .Ls_none]
    call sb_push_cstr
    jmp 8f
1:  lea r12, [rip + .Ls_fields]
    lea r13, [rip + st_x]
    xor r14d, r14d
2:  mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + r14*4]
    call sb_push_u64
    mov rdi, r12
    call strlen
    lea r12, [r12 + rax + 1]
    inc r14d
    cmp r14d, 4
    jb 2b
    call st_text
    mov r12d, eax
    mov rdi, rbx
    lea rsi, [rip + .Ls_text]
    call sb_push_cstr
    test r12d, r12d
    jz 3f
    mov rdi, rbx
    mov rsi, [rip + st_lab + SB_ptr]
    call sb_push_cstr
    jmp 8f
3:  mov rdi, rbx
    lea rsi, [rip + .Ls_passed]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + st_pass]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ls_failed]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + st_fail]
    call sb_push_u64
8:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

.section .rodata
.Ls_testing: .asciz "Testing "
.Ls_status: .asciz "test-status"
.Ls_none: .asciz " none"
.Ls_fields: .asciz " x="
            .asciz " y="
            .asciz " w="
            .asciz " h="
.Ls_text: .asciz " text="
.Ls_passed: .asciz "passed="
.Ls_failed: .asciz " failed="
.text

# ---------------- the filter ----------------
# A field above the tree keeps the rows whose label words start with each typed word (a capital
# after a small letter starts a word: "add" finds TestAdd), with everything under them, plus their
# ancestors, opened; Failed only keeps the failed and errored tests (and their ancestors).

.equ ID_TV_FILTER, ID_TV_BTN + 12
.equ ID_TV_FAILED, ID_TV_BTN + 13

.bss
.p2align 3
tv_ftf: .zero TF_SIZE           # the filter's text
tv_find: .long 0                # the field has the keys
tv_failed: .long 0              # Failed only
tv_fon: .long 0                 # the last rebuild filtered
.text

# tv_is_open(TSI*) -> eax nonzero when its children are listed: the filter opens the ancestors of
#   what it keeps, else the item's own expansion counts
tv_is_open:
    mov eax, [rdi + TSI_flags]
    cmp dword ptr [rip + tv_fon], 0
    je 1f
    and eax, TSF_FOPEN
    ret
1:  and eax, TSF_EXPANDED
    ret

# filter_row(x, y, w) -> eax its height: the field, and Failed only at its right
filter_row:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    M ebx, MI_24                # the field's height
    M r12d, MI_8
    mov dword ptr [rip + tv_ftf + TF_id], ID_TV_FILTER
    # a press elsewhere takes the keys from the field
    test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz 1f
    cmp dword ptr [rip + g_active], ID_TV_FILTER
    je 1f
    mov dword ptr [rip + tv_find], 0
1:  xor r9d, r9d
    cmp dword ptr [rip + tv_find], 0
    je 2f
    call place_focused
    xor r9d, r9d
    cmp eax, [rip + g_tv_place]
    sete r9b
2:  lea rdi, [rip + tv_ftf]
    mov esi, [rsp]
    add esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    sub ecx, r12d
    sub ecx, r12d
    sub ecx, ebx
    M eax, MI_4
    sub ecx, eax
    mov r8d, ebx
    lea rax, [rip + .Ltv_filter]
    push rax
    push rax
    call ui_textfield
    add rsp, 16
    test eax, UB_PRESS
    jz 3f
    mov dword ptr [rip + tv_find], 1
    mov edi, [rip + g_tv_place]
    call place_focus
3:  # Failed only: a cross, on a selected background while it filters
    mov r13d, [rsp]
    add r13d, [rsp + 8]
    sub r13d, r12d
    sub r13d, ebx
    cmp dword ptr [rip + tv_failed], 0
    je 4f
    mov edi, r13d
    mov esi, [rsp + 4]
    mov edx, ebx
    mov ecx, ebx
    COLOR r8d, T_SELECTION
    call gfx_fill
4:  mov edi, ID_TV_FAILED
    mov esi, r13d
    mov edx, [rsp + 4]
    mov ecx, ebx
    mov r8d, ebx
    mov r9d, IC_ERROR
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_TV_FAILED
    mov esi, r13d
    mov edx, [rsp + 4]
    add edx, ebx
    mov ecx, ebx
    lea r9, [rip + .Ltv_failed_only]
    call tip_note_text
    test eax, UB_CLICK
    jz 5f
    xor dword ptr [rip + tv_failed], 1
    mov dword ptr [rip + g_ts_dirty], 1
    mov dword ptr [rip + g_dirty], 1
5:  M eax, MI_4
    add eax, ebx
    EPILOGUE

# tv_filter_marks(): tv_fon, and with a filter the items' TSF_SHOW, TSF_FOPEN and TSF_HIT
tv_filter_marks:
    PROLOGUE
    lea rdi, [rip + tv_ftf]
    call tf_text
    xor eax, eax
    test rdx, rdx
    setnz al
    or eax, [rip + tv_failed]
    mov [rip + tv_fon], eax
    test eax, eax
    jz 9f
    lea rbx, [rip + g_ts_ctrls]
    xor r12d, r12d
1:  cmp qword ptr [rbx + TSC_ext], 0
    je 8f
    mov rdi, rbx
    xor esi, esi
    call testmodel_item
    and dword ptr [rax + TSI_flags], ~(TSF_SHOW | TSF_FOPEN | TSF_HIT)
    or dword ptr [rax + TSI_flags], TSF_SHOW    # the controller's row stays
    xor r13d, r13d
2:  mov rdi, rbx
    mov rsi, r13
    mov edx, 1
    call testmodel_next
    test rax, rax
    js 8f
    mov r13, rax
    mov rdi, rbx
    mov rsi, r13
    call testmodel_item
    mov r14, rax
    and dword ptr [r14 + TSI_flags], ~(TSF_SHOW | TSF_FOPEN | TSF_HIT)
    # the text: its label, or an ancestor's
    movsxd rsi, dword ptr [r14 + TSI_parent]
    test rsi, rsi
    jle 3f
    mov rdi, rbx
    call testmodel_item
    test dword ptr [rax + TSI_flags], TSF_HIT
    jnz 4f
3:  mov rdi, [r14 + TSI_label]
    call tv_text_ok
    test eax, eax
    jz 2b
4:  or dword ptr [r14 + TSI_flags], TSF_HIT
    # Failed only: a test that failed or errored, with no children
    cmp dword ptr [rip + tv_failed], 0
    je 5f
    cmp dword ptr [r14 + TSI_first], 0
    jge 2b
    test dword ptr [r14 + TSI_flags], TSF_LAZY
    jnz 2b
    mov eax, [r14 + TSI_state]
    cmp eax, TSS_FAILED
    je 5f
    cmp eax, TSS_ERRORED
    jne 2b
5:  or dword ptr [r14 + TSI_flags], TSF_SHOW
    movsxd r15, dword ptr [r14 + TSI_parent]
6:  test r15, r15
    js 2b
    mov rdi, rbx
    mov rsi, r15
    call testmodel_item
    mov ecx, [rax + TSI_flags]
    and ecx, TSF_SHOW | TSF_FOPEN
    cmp ecx, TSF_SHOW | TSF_FOPEN
    je 2b
    or dword ptr [rax + TSI_flags], TSF_SHOW | TSF_FOPEN
    movsxd r15, dword ptr [rax + TSI_parent]
    jmp 6b
8:  add rbx, TSC_SIZE
    inc r12d
    cmp r12d, TS_CTRL_MAX
    jb 1b
9:  EPILOGUE

# tv_text_ok(label) -> eax 1 when the filter's text finds the label (no text finds every label)
tv_text_ok:
    push rbx
    mov rbx, rdi
    lea rdi, [rip + tv_ftf]
    call tf_text
    mov rdi, rbx
    mov rsi, rax
    pop rbx
    test rdx, rdx
    jz 1f
    test rdi, rdi
    jz 2f
    jmp tv_match
1:  mov eax, 1
    ret
2:  xor eax, eax
    ret

# tv_match(label cstr, text, len) -> eax 1 when each word of the text starts a word of the label,
#   ignoring case
FN tv_match
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call strlen
    mov [rsp], rax
    xor r14d, r14d              # where the next word of the text starts
1:  cmp r14, r13
    jae 8f
    cmp byte ptr [r12 + r14], ' '
    jne 2f
    inc r14
    jmp 1b
2:  mov r15, r14                # the word: r15 up to r14
3:  inc r14
    cmp r14, r13
    jae 4f
    cmp byte ptr [r12 + r14], ' '
    jne 3b
4:  xor ecx, ecx                # where it may start in the label
5:  mov rdx, r14
    sub rdx, r15
    add rdx, rcx
    cmp rdx, [rsp]
    ja 9f
    mov [rsp + 8], rcx
    mov rdi, rbx
    mov rsi, rcx
    call tv_wstart
    mov rcx, [rsp + 8]
    test eax, eax
    jz 7f
    xor edx, edx
6:  lea r8, [r15 + rdx]
    cmp r8, r14
    jae 1b                      # this word is found: the next
    lea r9, [rcx + rdx]
    movzx eax, byte ptr [rbx + r9]
    movzx r9d, byte ptr [r12 + r8]
    lea r10d, [rax - 'A']
    cmp r10d, 25
    ja 61f
    add eax, 32
61: lea r10d, [r9 - 'A']
    cmp r10d, 25
    ja 62f
    add r9d, 32
62: cmp eax, r9d
    jne 7f
    inc rdx
    jmp 6b
7:  inc rcx
    jmp 5b
8:  mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# tv_wstart(label, i) -> eax 1 when a word starts at byte i: the first byte, after a byte that is
#   not a letter or a digit, a capital after a small letter, a digit after a non-digit
tv_wstart:
    mov eax, 1
    test rsi, rsi
    jz 9f
    movzx ecx, byte ptr [rdi + rsi - 1]   # the byte before
    movzx edx, byte ptr [rdi + rsi]       # the byte
    # before is not a letter or a digit (UTF-8 bytes count as letters)
    lea r8d, [rcx - '0']
    cmp r8d, 9
    jbe 2f
    lea r8d, [rcx - 'A']
    cmp r8d, 25
    jbe 3f
    lea r8d, [rcx - 'a']
    cmp r8d, 25
    jbe 4f
    cmp ecx, 0x80
    jb 9f
    jmp 8f
2:  # after a digit: never a new word
    jmp 8f
3:  # after a capital: a digit starts one
    lea r8d, [rdx - '0']
    cmp r8d, 9
    jbe 9f
    jmp 8f
4:  # after a small letter: a capital or a digit starts one
    lea r8d, [rdx - 'A']
    cmp r8d, 25
    jbe 9f
    lea r8d, [rdx - '0']
    cmp r8d, 9
    jbe 9f
8:  xor eax, eax
9:  ret

# testctl_filter(sb, rest, len): test-filter TEXT: the filter's text (none clears it)
testctl_filter:
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call trim
    lea rdi, [rip + tv_ftf]
    mov rsi, rax
    call tf_set
    mov dword ptr [rip + g_ts_dirty], 1
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE

# testctl_failed(sb, rest, len): test-failed-only on|off
testctl_failed:
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call trim
    xor ecx, ecx
    cmp rdx, 2
    jne 1f
    cmp byte ptr [rax], 'o'
    jne 1f
    cmp byte ptr [rax + 1], 'n'
    jne 1f
    mov ecx, 1
1:  mov [rip + tv_failed], ecx
    mov dword ptr [rip + g_ts_dirty], 1
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE

.section .rodata
.Ltv_filter: .asciz "Filter tests"
.Ltv_failed_only: .asciz "Show only failed tests"
.Lht_run: .asciz "Run All Tests"
.Lht_coverage: .asciz "Run All Tests with Coverage"
.Lht_rerun: .asciz "Re-run Failed Tests"
.Lht_cancel: .asciz "Cancel Test Runs"
.text

# ---------------- the Coverage section ----------------
# A sidebar section once coverage exists: a row per file with its covered and total lines and the
# percentage, the least covered first; a click opens the file. It goes when the coverage does.

.bss
.p2align 3
.globl g_tcv_dirty
tcv_tree: .quad 0
tcv_keys: .zero VEC_SIZE        # u64 sort keys: per mille << 32 | the file's index
g_tcv_dirty: .long 0            # the files changed: listed again
.data
.p2align 2
tcv_place: .long -1
tcv_hidden: .long -1            # what tcv_hide last set (-1: nothing yet)
.text

# testview_cov_tick(): the section shows with coverage, hides without; its rows follow the files
FN testview_cov_tick
    PROLOGUE
    cmp qword ptr [rip + g_cov_run], 0
    jne 1f
    mov edi, 1
    call tcv_hide
    EPILOGUE
1:  cmp dword ptr [rip + tcv_place], 0
    jge 2f
    lea rdi, [rip + tcv_tree_ops]
    xor esi, esi
    call tree_new
    mov [rip + tcv_tree], rax
    mov edi, PLACE_SIDEBAR
    lea rsi, [rip + .Ltcv_name]
    lea rdx, [rip + .Ltcv_title]
    lea rcx, [rip + tcv_place_ops]
    xor r8d, r8d
    call place_add
    mov [rip + tcv_place], eax
    test eax, eax
    js 9f
    mov edi, eax
    mov esi, IC_BEAKER
    call place_set_icon
    mov dword ptr [rip + g_tcv_dirty], 1
2:  xor edi, edi
    call tcv_hide
    cmp dword ptr [rip + g_tcv_dirty], 0
    je 9f
    mov dword ptr [rip + g_tcv_dirty], 0
    call tcv_rebuild
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# tcv_hide(on): the section hidden or shown, only when that changes (setting it repaints)
tcv_hide:
    mov esi, edi
    mov edi, [rip + tcv_place]
    test edi, edi
    js 9f
    cmp esi, [rip + tcv_hidden]
    je 9f
    mov [rip + tcv_hidden], esi
    jmp place_set_hidden
9:  ret

# tcv_rebuild(): the rows, least covered first
tcv_rebuild:
    PROLOGUE
    mov qword ptr [rip + tcv_keys + VEC_len], 0
    call testcover_files
    mov r12, rax
    xor ebx, ebx
1:  cmp rbx, r12
    jae 2f
    mov rdi, rbx
    call testcover_file_at
    mov rdi, rax
    call testcover_stats
    xor ecx, ecx
    test edx, edx
    jz 11f
    imul eax, eax, 1000
    mov ecx, edx
    xor edx, edx
    div ecx
    mov ecx, eax
11: shl rcx, 32
    or rcx, rbx
    push rcx
    push rcx
    lea rdi, [rip + tcv_keys]
    mov esi, 8
    call vec_push
    pop rcx
    pop rcx
    mov [rax], rcx
    inc rbx
    jmp 1b
2:  mov rdi, [rip + tcv_keys + VEC_ptr]
    mov rsi, [rip + tcv_keys + VEC_len]
    call sort_u64
    mov rdi, [rip + tcv_tree]
    xor esi, esi
    call tree_kids_begin
    xor r13d, r13d
3:  cmp r13, [rip + tcv_keys + VEC_len]
    jae 8f
    mov rax, [rip + tcv_keys + VEC_ptr]
    mov eax, [rax + r13*8]      # the file's index (the key's low half)
    mov rdi, rax
    call testcover_file_at
    mov r14, rax
    mov rdi, r14
    call testcover_path
    mov r15, rax
    # the label: the path inside the project, else the whole path
    mov rdi, r15
    call tcv_rel
    mov rbx, rax
    mov rdi, rbx
    call strlen
    mov r8, rax
    push r8
    push r8
    mov rdi, r15
    call strlen
    mov rdx, rax
    pop r8
    pop r8
    mov rdi, [rip + tcv_tree]
    mov rsi, r15
    mov rcx, rbx
    mov r9d, KIDS_LEAF
    call tree_kid
    cmp eax, -1
    je 7f
    mov ebx, eax
    # "C/T · N%"
    lea rdi, [rip + tv_text]
    call sb_clear
    mov rdi, r14
    call testcover_stats
    push rax
    push rdx
    lea rdi, [rip + tv_text]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rip + tv_text]
    mov esi, '/'
    call sb_push_byte
    mov rsi, [rsp]
    lea rdi, [rip + tv_text]
    call sb_push_u64
    lea rdi, [rip + tv_text]
    lea rsi, [rip + .Ltcv_dot]
    call sb_push_cstr
    pop rcx
    pop rax
    xor esi, esi
    test ecx, ecx
    jz 4f
    imul eax, eax, 100
    xor edx, edx
    div ecx
    mov esi, eax
4:  lea rdi, [rip + tv_text]
    call sb_push_u64
    lea rdi, [rip + tv_text]
    mov esi, '%'
    call sb_push_byte
    mov rdi, [rip + tcv_tree]
    mov esi, ebx
    mov rdx, [rip + tv_text + SB_ptr]
    mov rcx, [rip + tv_text + SB_len]
    call tree_set_desc
7:  inc r13
    jmp 3b
8:  mov rdi, [rip + tcv_tree]
    xor esi, esi
    call tree_kids_end
    EPILOGUE

# tcv_rel(path) -> rax the part after the project's folder and a slash, else the path
tcv_rel:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rip + g_project]
    test r12, r12
    jz 8f
    mov rdi, r12
    call strlen
    mov r13, rax
    mov rdi, rbx
    call strlen
    cmp rax, r13
    jbe 8f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jz 8f
    cmp byte ptr [rbx + r13], '/'
    jne 8f
    lea rax, [rbx + r13 + 1]
    EPILOGUE
8:  mov rax, rbx
    EPILOGUE

# tcv_draw(ctx, x, y, w, h): the rows
tcv_draw:
    PROLOGUE 16
    mov [rsp], esi
    mov [rsp + 4], edx
    mov ebx, ecx
    mov r12d, r8d
    call place_focused
    xor r9d, r9d
    cmp eax, [rip + tcv_place]
    sete r9b
    mov rdi, [rip + tcv_tree]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, ebx
    mov r8d, r12d
    call tree_draw
    EPILOGUE

# tcv_key(ctx, keysym, cp, mods) -> eax 1 when taken
tcv_key:
    mov rdi, [rip + tcv_tree]
    jmp tree_key

# tcv_activate(ctx, tr, node): the row's file opens
tcv_activate:
    PROLOGUE
    mov rdi, rsi
    mov esi, edx
    call tree_node_id
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rbx, rax
    mov rdi, rbx
    call app_open_file
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# testctl_cov_view(sb, rest, len): print-test-coverage: the Coverage section's rows, "file=LABEL
#   desc=C/T · N%" each (the shown order), or "coverage-section none"
testctl_cov_view:
    PROLOGUE
    mov rbx, rdi
    mov edi, [rip + tcv_place]
    test edi, edi
    js 8f
    call place_at
    test rax, rax
    jz 8f
    mov rdi, [rip + tcv_tree]
    call tree_rows_count
    mov r12, rax
    xor r13d, r13d
1:  cmp r13, r12
    jae 9f
    mov rdi, [rip + tcv_tree]
    mov rsi, r13
    call tree_row
    mov r14d, eax               # the node
    mov rdi, rbx
    lea rsi, [rip + .Ltcv_file]
    call sb_push_cstr
    mov rdi, [rip + tcv_tree]
    mov esi, r14d
    call tree_node_label
    mov rdi, rbx
    mov rsi, rax
    call sb_push
    mov rdi, rbx
    lea rsi, [rip + .Ltcv_desc]
    call sb_push_cstr
    mov rdi, [rip + tcv_tree]
    imul rax, r14, ND_SIZE
    add rax, [rdi + TR_nodes + VEC_ptr]
    mov rsi, [rax + ND_desc]
    test rsi, rsi
    jz 2f
    mov rdi, rbx
    call sb_push_cstr
2:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r13
    jmp 1b
8:  mov rdi, rbx
    lea rsi, [rip + .Ltcv_none]
    call sb_push_cstr
9:  xor eax, eax
    EPILOGUE

.section .rodata
.Ltcv_name: .asciz "coverage"
.Ltcv_title: .asciz "Coverage"
.Ltcv_dot: .asciz " \302\267 "
.Ltcv_file: .asciz "file="
.Ltcv_desc: .asciz " desc="
.Ltcv_none: .asciz "coverage-section none\n"
.p2align 3
tcv_place_ops: .quad tcv_draw, tcv_key, 0, 0, 0, 0
tcv_tree_ops: .quad tcv_activate, 0, 0, 0, 0, 0, 0, 0, 0
.text
