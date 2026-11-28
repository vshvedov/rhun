# Test Results: the bottom panel's tab for the logs of a run, as VS Code's Test Results shows them
# beside the sidebar's Testing tree. A run (Run All, a test's play button, Re-run Failed ...; not a
# debug run, which the Debug tab shows) opens it, reused: a toolbar (Rerun, Rerun Failed, Stop, then
# the counts and the time), then the logs at full width: the whole run's until a test or group is
# selected in the Testing tree, then that one's: its output, then its messages with their expected
# and actual values (a group: everything under it; an item the run left out: its last result). Runs
# started while others of the same start are still going belong together (Run All starts one per
# controller).
.include "rhun.inc"

.equ TRS_RUNS, 8                # runs shown together
.equ TRS_LINES_MAX, 200000      # log lines kept for the view
.equ ID_TRS, 0x5e0300           # + n: the toolbar's buttons

.data
.p2align 2
.globl g_trs_place
g_trs_place: .long -1           # the tab's place id, -1 before the first run
.p2align 3
trs_key_node: .quad -2          # what trs_text is of: the selected node, and the runs' bytes
trs_key_bytes: .quad -1

.bss
.p2align 3
.globl g_trs_picked
g_trs_picked: .long 0           # an item was selected since the runs began: the logs are its
trs_nums: .zero 8 * TRS_RUNS    # the runs shown, by number
trs_n: .quad 0
trs_show: .long 0               # a run began: the tab shows at the next tick
.p2align 3
trs_buf: .zero SB_SIZE          # scratch: the status line
trs_text: .zero SB_SIZE         # the logs shown: their bytes
trs_lines: .zero VEC_SIZE       # and their lines: offset, length, SGR color (0 the default), pad (u32 each)
trs_lg: .quad 0                 # the log the lines are drawn in (rlog.s: select, copy, find)
trs_line: .zero SB_SIZE         # scratch: a line with its color for the log
trs_cnt: .zero 4 * TSS_COUNT    # the runs' results by state
trs_esc: .long 0                # trs_put: inside an escape sequence

.text

# ---------------- the runs ----------------

# testresults_run_new(TSR*): a run was made (testmodel_run_new). A debug run is the Debug tab's.
#   Without a shown run still queued or running it starts a new set; the tab shows at the next tick.
FN testresults_run_new
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + TSR_profile], TSP_DEBUG
    je 9f
    call trs_active
    test eax, eax
    jnz 1f
    mov qword ptr [rip + trs_n], 0
    mov qword ptr [rip + trs_key_node], -2
    mov dword ptr [rip + g_trs_picked], 0   # the whole runs' logs until an item is selected
1:  mov rax, [rip + trs_n]
    cmp rax, TRS_RUNS
    jae 2f
    mov rcx, [rbx + TSR_num]
    lea rdx, [rip + trs_nums]
    mov [rdx + rax*8], rcx
    inc qword ptr [rip + trs_n]
2:  mov dword ptr [rip + trs_show], 1
    or dword ptr [rip + g_ts_dirty], 2
9:  EPILOGUE

# trs_run(i) -> rax the i-th shown run's TSR*, or 0 when it is gone
trs_run:
    lea rax, [rip + trs_nums]
    mov rdi, [rax + rdi*8]
    jmp testmodel_run_by_num

# trs_active() -> eax 1 while a shown run is queued or running
trs_active:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + trs_n]
    jae 8f
    mov rdi, rbx
    inc rbx
    call trs_run
    test rax, rax
    jz 1b
    mov ecx, [rax + TSR_state]
    cmp ecx, TSRS_QUEUED
    je 2f
    cmp ecx, TSRS_RUNNING
    jne 1b
2:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# testresults_tick(): the tab shows when a run began
FN testresults_tick
    PROLOGUE
    cmp dword ptr [rip + trs_show], 0
    je 9f
    mov dword ptr [rip + trs_show], 0
    call trs_ensure
    mov edi, [rip + g_trs_place]
    test edi, edi
    js 9f
    xor esi, esi
    call place_show
9:  EPILOGUE

# trs_ensure(): the tab exists
trs_ensure:
    PROLOGUE
    cmp dword ptr [rip + g_trs_place], 0
    jge 9f
    mov edi, PLACE_PANEL
    lea rsi, [rip + .Lname]
    lea rdx, [rip + .Ltitle]
    lea rcx, [rip + trs_ops]
    xor r8d, r8d
    call place_add
    mov [rip + g_trs_place], eax
    test eax, eax
    js 9f
    mov edi, eax
    mov esi, IC_BEAKER
    call place_set_icon
9:  EPILOGUE

# trs_close(ctx): the tab's ×: it hides (the next run shows it again); the panel goes to the
#   terminals, else another tab, else it closes
trs_close:
    PROLOGUE
    mov edi, [rip + g_trs_place]
    mov esi, 1
    call place_set_hidden
    mov eax, [rip + g_trs_place]
    cmp eax, [rip + g_panel_cur]
    jne 9f
    mov dword ptr [rip + g_panel_cur], -1
    call term_count
    test rax, rax
    jnz 9f
    call places_panel_count
    test eax, eax
    jz 1f
    xor edi, edi
    call places_panel_nth
    mov [rip + g_panel_cur], eax
    jmp 9f
1:  mov dword ptr [rip + g_term_open], 0
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ---------------- the counts ----------------

# trs_count(): trs_cnt counts the shown runs' results of tests (leaves) by state, after the model
#   changed
trs_count:
    PROLOGUE
    test dword ptr [rip + g_ts_dirty], 2
    jz 9f
    and dword ptr [rip + g_ts_dirty], ~2
    lea rdi, [rip + trs_cnt]
    xor eax, eax
    mov ecx, TSS_COUNT
    rep stosd
    xor r12d, r12d
1:  cmp r12, [rip + trs_n]
    jae 9f
    mov rdi, r12
    inc r12
    call trs_run
    test rax, rax
    jz 1b
    mov r13, rax
    mov rdi, [r13 + TSR_ext]
    call testmodel_ctrl
    test rax, rax
    jz 1b
    mov rbx, rax                # TSC*
    xor r14d, r14d
2:  cmp r14, [r13 + TSR_ents + VEC_len]
    jae 1b
    imul r15, r14, TSE_SIZE
    add r15, [r13 + TSR_ents + VEC_ptr]
    inc r14
    movsxd rsi, dword ptr [r15 + TSE_item]
    test rsi, rsi
    js 2b
    cmp rsi, [rbx + TSC_items + VEC_len]
    jae 2b
    mov rdi, rbx                # tests only, as the Testing section counts: a package's own
    call testmodel_item         #   result is not one more
    cmp dword ptr [rax + TSI_first], 0
    jge 2b
    mov ecx, [r15 + TSE_state]
    lea rdx, [rip + trs_cnt]
    inc dword ptr [rdx + rcx*4]
    jmp 2b
9:  EPILOGUE

# trs_push_ms(ms): trs_buf gets "N ms", or "N.N s" from a second
trs_push_ms:
    PROLOGUE
    mov ebx, edi
    cmp ebx, 1000
    jae 1f
    lea rdi, [rip + trs_buf]
    mov esi, ebx
    call sb_push_u64
    lea rdi, [rip + trs_buf]
    lea rsi, [rip + .Lms]
    call sb_push_cstr
    EPILOGUE
1:  mov eax, ebx
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov r12d, edx
    lea rdi, [rip + trs_buf]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rip + trs_buf]
    mov esi, '.'
    call sb_push_byte
    mov eax, r12d
    xor edx, edx
    mov ecx, 100
    div ecx
    lea rdi, [rip + trs_buf]
    mov esi, eax
    call sb_push_u64
    lea rdi, [rip + trs_buf]
    lea rsi, [rip + .Ls]
    call sb_push_cstr
    EPILOGUE

# ---------------- the logs ----------------

# trs_selected() -> rax TSC*, rdx index of the Testing tree's selected item; rax 0 for the whole
#   runs (nothing selected since they began)
trs_selected:
    PROLOGUE
    cmp dword ptr [rip + g_trs_picked], 0
    je 8f
    call testview_selected
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# trs_bytes() -> rax what the logs are made of, summed: each shown run's output, results and
#   messages (they only grow while a run goes; a new run is a new number)
trs_bytes:
    PROLOGUE
    xor r12d, r12d
    xor ebx, ebx
1:  cmp rbx, [rip + trs_n]
    jae 9f
    mov rdi, rbx
    inc rbx
    call trs_run
    test rax, rax
    jz 1b
    add r12, [rax + TSR_out + SB_len]
    add r12, [rax + TSR_bytes]
    add r12, [rax + TSR_ents + VEC_len]
    add r12, [rax + TSR_num]
    jmp 1b
9:  mov rax, r12
    EPILOGUE

# trs_logs(): trs_text and trs_lines for the selected row, built again when it or the runs changed
trs_logs:
    PROLOGUE 32
    call trs_selected
    shl rdx, 20
    xor rax, rdx
    mov rbx, rax                # the selection, as a number (0: the whole runs)
    call trs_bytes
    mov r12, rax
    cmp rbx, [rip + trs_key_node]
    jne 2f
    cmp r12, [rip + trs_key_bytes]
    je 9f
2:  mov [rip + trs_key_node], rbx
    mov [rip + trs_key_bytes], r12
    lea rdi, [rip + trs_text]
    call sb_clear
    mov qword ptr [rip + trs_lines + VEC_len], 0
    mov dword ptr [rip + trs_esc], 0
    call trs_selected
    mov r13, rax                # TSC* or 0: all
    mov r14, rdx                # its item
    mov qword ptr [rsp + 16], 0 # results put
    xor r15d, r15d
3:  cmp r15, [rip + trs_n]
    jae 8f
    mov rdi, r15
    inc r15
    call trs_run
    test rax, rax
    jz 3b
    mov rbx, rax                # TSR*
    mov rdi, [rbx + TSR_ext]
    call testmodel_ctrl
    mov [rsp], rax              # its TSC*
    test r13, r13
    jz 4f
    cmp rax, r13
    jne 3b
    test r14, r14               # a controller's row: the run's own output too
    jnz 5f
4:  mov rdi, [rbx + TSR_out + SB_ptr]
    mov rsi, [rbx + TSR_out + SB_len]
    xor edx, edx
    call trs_put
5:  xor r12d, r12d              # its results under the selected item
6:  cmp r12, [rbx + TSR_ents + VEC_len]
    jae 3b
    imul rdi, r12, TSE_SIZE
    add rdi, [rbx + TSR_ents + VEC_ptr]
    inc r12
    mov [rsp + 8], rdi
    movsxd rsi, dword ptr [rdi + TSE_item]
    test rsi, rsi
    js 7f                       # the run's own messages: with the whole run
    test r13, r13
    jz 7f
    mov rdi, r13
    mov rdx, r14
    call testmodel_is_under
    test eax, eax
    jz 6b
    jmp 71f
7:  test r14, r14
    jnz 6b
71: mov rdi, [rsp + 8]
    call trs_put_result
    inc qword ptr [rsp + 16]
    jmp 6b
8:  test r13, r13               # an item the runs left out: its last result
    jz 81f
    cmp qword ptr [rsp + 16], 0
    jne 81f
    mov rdi, r13
    mov rsi, r14
    call testmodel_result
    test rax, rax
    jz 81f
    mov rdi, rax
    call trs_put_result
81: call trs_feed
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# trs_feed(): the log holds the lines again, each with its color (from their end, following)
trs_feed:
    PROLOGUE
    cmp qword ptr [rip + trs_lg], 0
    jne 1f
    mov edi, 250                # its instance: ui ids of its own
    call log_new
    mov [rip + trs_lg], rax
    mov rdi, rax
    lea rsi, [rip + g_face_term]
    call log_set_face
1:  mov rdi, [rip + trs_lg]
    call log_clear
    xor ebx, ebx
2:  cmp rbx, [rip + trs_lines + VEC_len]
    jae 9f
    mov r12, rbx
    shl r12, 4
    add r12, [rip + trs_lines + VEC_ptr]
    inc rbx
    lea rdi, [rip + trs_line]
    call sb_clear
    mov r13d, [r12 + 8]
    test r13d, r13d
    jz 3f
    lea rdi, [rip + trs_line]
    lea rsi, [rip + .Lcsi]
    call sb_push_cstr
    lea rdi, [rip + trs_line]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + trs_line]
    mov esi, 'm'
    call sb_push_byte
3:  mov esi, [r12]
    add rsi, [rip + trs_text + SB_ptr]
    mov edx, [r12 + 4]
    lea rdi, [rip + trs_line]
    call sb_push
    mov rdi, [rip + trs_lg]
    xor esi, esi                # LS_NONE: the text's own colors
    mov rdx, [rip + trs_line + SB_ptr]
    mov rcx, [rip + trs_line + SB_len]
    call log_append
    jmp 2b
9:  EPILOGUE

# trs_put_result(TSE*): its output, then each message: its text, "Expected: …" and "Actual: …"
trs_put_result:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + TSE_out + SB_ptr]
    mov rsi, [rbx + TSE_out + SB_len]
    xor edx, edx
    call trs_put
    mov r12, [rbx + TSE_msgs + SB_ptr]
    test r12, r12
    jz 9f
    mov r13, r12
    add r13, [rbx + TSE_msgs + SB_len]
1:  cmp r12, r13
    jae 9f
    lea r14, [r12 + TSM_SIZE]   # the text
    call trs_break
    mov rdi, r14
    mov esi, [r12 + TSM_text]
    mov edx, 31
    call trs_put
    call trs_break
    mov eax, [r12 + TSM_text]
    add r14, rax
    mov eax, [r12 + TSM_path]
    add r14, rax                # the expected value
    xor r15d, r15d              # the values' bytes
    mov esi, [r12 + TSM_exp]
    cmp esi, -1
    je 2f
    add r15d, esi
    lea rdi, [rip + .Lexpected]
    mov esi, 10
    mov edx, 90
    call trs_put
    mov rdi, r14
    mov esi, [r12 + TSM_exp]
    mov edx, 31
    call trs_put
    call trs_break
    mov eax, [r12 + TSM_exp]
    add r14, rax
2:  mov esi, [r12 + TSM_act]
    cmp esi, -1
    je 3f
    add r15d, esi
    lea rdi, [rip + .Lactual]
    mov esi, 10
    mov edx, 90
    call trs_put
    mov rdi, r14
    mov esi, [r12 + TSM_act]
    mov edx, 32
    call trs_put
    call trs_break
3:  mov eax, TSM_SIZE           # the next message
    add eax, [r12 + TSM_text]
    add eax, [r12 + TSM_path]
    mov ecx, [r12 + TSM_exp]
    cmp ecx, -1
    je 31f
    add eax, ecx
31: mov ecx, [r12 + TSM_act]
    cmp ecx, -1
    je 32f
    add eax, ecx
32: add r12, rax
    jmp 1b
9:  EPILOGUE

# trs_break(): the next text starts a line (when the last one has text)
trs_break:
    mov rax, [rip + trs_lines + VEC_len]
    test rax, rax
    jz 9f
    dec rax
    shl rax, 4
    add rax, [rip + trs_lines + VEC_ptr]
    cmp dword ptr [rax + 4], 0
    je 9f
    mov dword ptr [rip + trs_esc], 0
    mov rdi, 0
    jmp trs_newline
9:  ret

# trs_newline(): a new empty line, in the last line's color
trs_newline:
    PROLOGUE
    mov rax, [rip + trs_lines + VEC_len]
    cmp rax, TRS_LINES_MAX
    jae 9f
    xor ebx, ebx                # the default color
    test rax, rax
    jz 1f
    dec rax
    shl rax, 4
    add rax, [rip + trs_lines + VEC_ptr]
    mov ebx, [rax + 8]
1:  lea rdi, [rip + trs_lines]
    mov esi, 16
    call vec_push
    mov rcx, [rip + trs_text + SB_len]
    mov [rax], ecx
    mov dword ptr [rax + 4], 0
    mov [rax + 8], ebx
    mov dword ptr [rax + 12], 0
9:  EPILOGUE

# trs_put(ptr, len, sgr): text added to the logs in that SGR color (0 default, 31 red, 32 green, 90
#   grey): lines at LF, CR dropped, a tab as
#   four spaces, escape sequences (colors) left out
trs_put:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    test r13, r13
    jz 9f
    cmp qword ptr [rip + trs_lines + VEC_len], 0
    jne 1f
    call trs_newline
1:  call trs_last
    mov [rax + 8], r14d         # the line takes the color of its newest text
    xor r15d, r15d
2:  cmp r15, r13
    jae 9f
    movzx ebx, byte ptr [r12 + r15]
    inc r15
    cmp dword ptr [rip + trs_esc], 0
    je 3f
    cmp ebx, 0x40               # a sequence ends at its final byte (@ to ~), after "["
    jb 2b
    cmp ebx, '['
    je 2b
    mov dword ptr [rip + trs_esc], 0
    jmp 2b
3:  cmp ebx, 27
    jne 4f
    mov dword ptr [rip + trs_esc], 1
    jmp 2b
4:  cmp ebx, 13
    je 2b
    cmp ebx, 10
    jne 5f
    call trs_newline
    call trs_last
    mov [rax + 8], r14d
    jmp 2b
5:  cmp ebx, 9
    jne 6f
    mov ebx, ' '
    lea rdi, [rip + trs_text]
    mov esi, ebx
    call sb_push_byte
    lea rdi, [rip + trs_text]
    mov esi, ebx
    call sb_push_byte
    lea rdi, [rip + trs_text]
    mov esi, ebx
    call sb_push_byte
    call trs_last
    add dword ptr [rax + 4], 3
6:  lea rdi, [rip + trs_text]
    mov esi, ebx
    call sb_push_byte
    call trs_last
    inc dword ptr [rax + 4]
    jmp 2b
9:  EPILOGUE

# trs_last() -> rax the last line's record
trs_last:
    mov rax, [rip + trs_lines + VEC_len]
    dec rax
    shl rax, 4
    add rax, [rip + trs_lines + VEC_ptr]
    ret

# trs_logs_draw(x, y, w, h): the lines in the log (the terminal's face; a click or a drag selects
#   lines, Ctrl+C copies them, Ctrl+F finds; it follows new lines at its end), or "No output"
trs_logs_draw:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    COLOR r8d, T_PANEL
    call gfx_fill
    call trs_logs
    call term_line_metrics      # the terminal's face at its size
    mov [rsp + 16], eax
    cmp qword ptr [rip + trs_lines + VEC_len], 0
    je 1f
    cmp qword ptr [rip + trs_lg], 0
    je 1f
    call place_focused
    xor r9d, r9d
    cmp eax, [rip + g_trs_place]
    sete r9b
    mov rdi, [rip + trs_lg]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call log_draw
    jmp 9f
1:  lea r8, [rip + .Lnone]      # nothing yet
    call trs_running_now
    test eax, eax
    jz 2f
    lea r8, [rip + .Lwaiting]
2:  mov rdi, r8
    push r8
    push r8
    call strlen
    pop r8
    pop r8
    mov r9, rax
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_6]
    mov ecx, [rsp + 16]
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
9:  EPILOGUE

# trs_key(ctx, keysym, cp, mods) -> eax 1 when taken: the log's keys (lines, Ctrl+C, Ctrl+F)
trs_key:
    mov rdi, [rip + trs_lg]
    test rdi, rdi
    jz 1f
    jmp log_key
1:  xor eax, eax
    ret

# trs_running_now() -> eax 1 while a shown run is queued or running (keeps the other registers)
trs_running_now:
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push r9
    sub rsp, 8
    call trs_active
    add rsp, 8
    pop r9
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

# ---------------- the tab ----------------

# trs_button(id, x, y, size, icon, enabled) -> eax 1 when clicked: a toolbar button with its tooltip
#   (trs_tips by id); a disabled one is faint
trs_button:
    PROLOGUE 32
    mov [rsp], edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov [rsp + 4], r8d
    mov [rsp + 8], r9d
    mov edi, [rsp]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r14d
    call ui_btn
    mov r15d, eax
    cmp dword ptr [rsp + 8], 0
    je 1f
    test r15d, UB_HOVER
    jz 1f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r14d
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    test r15d, UB_HELD
    jz 11f
    COLOR r9d, T_ACTIVE
11: call gfx_round_rect
1:  COLOR r9d, T_FG
    cmp dword ptr [rsp + 4], IC_STOP
    jne 2f
    COLOR r9d, T_ERROR
2:  cmp dword ptr [rsp + 8], 0
    jne 3f
    COLOR r9d, T_MUTED
    and r9d, 0x00ffffff
    or r9d, 0x80000000
3:  mov edi, [rsp + 4]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r14d
    call ui_icon_center
    mov eax, [rsp]
    sub eax, ID_TRS
    lea rcx, [rip + trs_tips]
    mov r9, [rcx + rax*8]
    mov edi, [rsp]
    mov esi, r12d
    lea edx, [r13 + r14]
    mov ecx, r14d
    mov r8d, r15d
    call tip_note_text
    xor eax, eax
    cmp dword ptr [rsp + 8], 0
    je 9f
    test r15d, UB_CLICK
    jz 9f
    mov eax, 1
9:  EPILOGUE

# trs_status(): trs_buf gets "Running…" or the counts ("2 failed, 10 passed, 1 skipped"), then the
#   time the runs took -> eax its color
trs_status:
    PROLOGUE
    lea rdi, [rip + trs_buf]
    call sb_clear
    mov eax, [rip + trs_cnt + 4*TSS_FAILED]
    add eax, [rip + trs_cnt + 4*TSS_ERRORED]
    mov r12d, eax               # failed
    COLOR r13d, T_SUCCESS
    call trs_active
    test eax, eax
    jz 1f
    lea rdi, [rip + trs_buf]
    lea rsi, [rip + .Lrunning]
    call sb_push_cstr
    COLOR r13d, T_MUTED
1:  test r12d, r12d
    jz 2f
    COLOR r13d, T_ERROR
    lea rdi, [rip + trs_buf]
    mov esi, r12d
    call sb_push_u64
    lea rdi, [rip + trs_buf]
    lea rsi, [rip + .Lfailed]
    call sb_push_cstr
2:  lea rdi, [rip + trs_buf]
    mov esi, [rip + trs_cnt + 4*TSS_PASSED]
    call sb_push_u64
    lea rdi, [rip + trs_buf]
    lea rsi, [rip + .Lpassed]
    call sb_push_cstr
    mov esi, [rip + trs_cnt + 4*TSS_SKIPPED]
    test esi, esi
    jz 3f
    lea rdi, [rip + trs_buf]
    lea rsi, [rip + .Lcomma]
    call sb_push_cstr
    lea rdi, [rip + trs_buf]
    mov esi, [rip + trs_cnt + 4*TSS_SKIPPED]
    call sb_push_u64
    lea rdi, [rip + trs_buf]
    lea rsi, [rip + .Lskipped]
    call sb_push_cstr
3:  call trs_elapsed
    test eax, eax
    js 4f
    push rax
    push rax
    lea rdi, [rip + trs_buf]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    pop rdi
    pop rdi
    call trs_push_ms
4:  call trs_selected           # whose logs show
    test rax, rax
    jz 5f
    mov rdi, rax
    mov rsi, rdx
    call testmodel_item
    mov rbx, rax
    lea rdi, [rip + trs_buf]
    lea rsi, [rip + .Ldash]
    call sb_push_cstr
    lea rdi, [rip + trs_buf]
    mov rsi, [rbx + TSI_label]
    call sb_push_cstr
5:  mov eax, r13d
    EPILOGUE

# trs_elapsed() -> eax ms from the first shown run's start to the last one's end (now while one
#   goes), -1 before any started
trs_elapsed:
    PROLOGUE
    mov r12, -1                 # the first start
    xor r13d, r13d              # the last end
    xor ebx, ebx
1:  cmp rbx, [rip + trs_n]
    jae 5f
    mov rdi, rbx
    inc rbx
    call trs_run
    test rax, rax
    jz 1b
    mov rcx, [rax + TSR_t0]
    test rcx, rcx
    jz 1b
    cmp rcx, r12
    jae 2f
    mov r12, rcx
2:  mov rcx, [rax + TSR_t1]
    cmp dword ptr [rax + TSR_state], TSRS_ENDED
    je 3f
    push rax
    push rax
    call time_ms
    mov rcx, rax
    pop rax
    pop rax
3:  cmp rcx, r13
    jbe 1b
    mov r13, rcx
    jmp 1b
5:  mov eax, -1
    cmp r12, -1
    je 9f
    mov rax, r13
    sub rax, r12
    jns 9f
    xor eax, eax
9:  EPILOGUE

# trs_draw(ctx, x, y, w, h): the toolbar, then the logs
trs_draw:
    PROLOGUE 48
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    call trs_ensure
    call trs_count
    M eax, MI_32
    mov [rsp + 16], eax         # the bar
    M eax, MI_28
    mov [rsp + 20], eax         # a button
    mov ecx, [rsp + 16]
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp + 4]
    mov [rsp + 24], ecx         # a button's y
    # Rerun, Rerun Failed, Stop
    mov r14d, [rsp]
    add r14d, [rip + g_mt + 4*MI_6]
    call trs_active
    mov [rsp + 28], eax         # running
    xor r9d, r9d
    test eax, eax
    sete r9b
    cmp qword ptr [rip + trs_n], 0
    jne 1f
    xor r9d, r9d
1:  mov [rsp + 32], r9d         # can rerun
    mov edi, ID_TRS
    mov esi, r14d
    mov edx, [rsp + 24]
    mov ecx, [rsp + 20]
    mov r8d, IC_PLAY
    call trs_button
    test eax, eax
    jz 2f
    call trs_rerun
2:  add r14d, [rsp + 20]
    add r14d, [rip + g_mt + 4*MI_2]
    mov r9d, [rsp + 32]
    mov eax, [rip + trs_cnt + 4*TSS_FAILED]
    add eax, [rip + trs_cnt + 4*TSS_ERRORED]
    test eax, eax
    jnz 21f
    xor r9d, r9d
21: mov edi, ID_TRS + 1
    mov esi, r14d
    mov edx, [rsp + 24]
    mov ecx, [rsp + 20]
    mov r8d, IC_REFRESH
    call trs_button
    test eax, eax
    jz 3f
    call cmd_test_rerun_failed
3:  add r14d, [rsp + 20]
    add r14d, [rip + g_mt + 4*MI_2]
    mov edi, ID_TRS + 2
    mov esi, r14d
    mov edx, [rsp + 24]
    mov ecx, [rsp + 20]
    mov r8d, IC_STOP
    mov r9d, [rsp + 28]
    call trs_button
    test eax, eax
    jz 4f
    call trs_stop
4:  add r14d, [rsp + 20]
    add r14d, [rip + g_mt + 4*MI_16]
    call trs_status             # the counts and the time
    push rax
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, r14d
    mov edx, [rsp + 16 + 4]
    mov ecx, [rsp + 16 + 16]
    mov r8, [rip + trs_buf + SB_ptr]
    mov r9, [rip + trs_buf + SB_len]
    call ui_text_v
    add rsp, 16
    # a line under the bar
    mov esi, [rsp + 4]
    add esi, [rsp + 16]
    mov [rsp + 36], esi
    mov edi, [rsp]
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    mov eax, [rsp + 36]
    add eax, [rip + g_mt + 4*MI_1]
    mov [rsp + 36], eax         # the body's top
    mov ecx, [rsp + 4]
    add ecx, [rsp + 12]
    sub ecx, eax
    mov [rsp + 40], ecx         # its height
    test ecx, ecx
    jle 9f
    mov edi, [rsp]
    mov esi, [rsp + 36]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 40]
    call trs_logs_draw
9:  EPILOGUE

# trs_rerun(): the shown runs again, each with its kind and items (not the newest run, which may be a
#   debug run of the Debug tab's); their numbers are copied first, as the new runs replace them
.bss
.p2align 3
rr_nums: .zero 8 * TRS_RUNS
.text
trs_rerun:
    PROLOGUE
    mov r12, [rip + trs_n]
    xor ebx, ebx
1:  cmp rbx, r12
    jae 2f
    lea rax, [rip + trs_nums]
    mov rcx, [rax + rbx*8]
    lea rax, [rip + rr_nums]
    mov [rax + rbx*8], rcx
    inc rbx
    jmp 1b
2:  xor ebx, ebx
3:  cmp rbx, r12
    jae 9f
    lea rax, [rip + rr_nums]
    mov rdi, [rax + rbx*8]
    inc rbx
    call testmodel_run_by_num
    test rax, rax
    jz 3b
    mov rdi, rax
    call testview_rerun_run
    jmp 3b
9:  EPILOGUE

# trs_stop(): the shown runs still going are cancelled (a debug session is the Debug tab's to stop)
trs_stop:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + trs_n]
    jae 9f
    mov rdi, rbx
    inc rbx
    call trs_run
    test rax, rax
    jz 1b
    mov rdi, rax
    call testproto_cancel
    jmp 1b
9:  EPILOGUE

# ---------------- headless ----------------

# testresults_rerun_ctl(sb, rest, len): results-rerun: the tab's Rerun button
FN testresults_rerun_ctl
    sub rsp, 8
    call trs_rerun
    add rsp, 8
    xor eax, eax
    ret

# testresults_print(sb, rest, len): print-results-view: "test-results hidden" before a run, else
#   "status=TEXT", "shown=0|1", then "log LINE" per log line
FN testresults_print
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + g_trs_place], 0
    jge 1f
    mov rdi, rbx
    lea rsi, [rip + .Lp_hidden]
    call sb_push_cstr
    jmp 9f
1:  call trs_count
    call trs_status
    mov rdi, rbx
    lea rsi, [rip + .Lp_status]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + trs_buf + SB_ptr]
    mov rdx, [rip + trs_buf + SB_len]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov edi, [rip + g_trs_place]
    call place_visible
    mov rdi, rbx
    lea rsi, [rip + .Lp_shown]
    test eax, eax
    jnz 11f
    lea rsi, [rip + .Lp_notshown]
11: call sb_push_cstr
    call trs_logs
    mov rdi, [rip + trs_lg]     # where the lines are (a click there selects one)
    test rdi, rdi
    jz 12f
    mov rsi, rbx
    lea rdx, [rip + .Lp_rect]
    call log_print_rect
12: xor r12d, r12d
2:  cmp r12, [rip + trs_lines + VEC_len]
    jae 9f
    mov rax, r12
    shl rax, 4
    add rax, [rip + trs_lines + VEC_ptr]
    mov r13, rax
    mov rdi, rbx
    lea rsi, [rip + .Lp_log]
    call sb_push_cstr
    mov esi, [r13]
    add rsi, [rip + trs_text + SB_ptr]
    mov edx, [r13 + 4]
    mov rdi, rbx
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r12
    jmp 2b
9:  xor eax, eax
    EPILOGUE

.section .rodata
.p2align 3
trs_ops: .quad trs_draw, trs_key, 0, trs_close, 0, 0
trs_tips: .quad .Lt_rerun, .Lt_failed, .Lt_stop
.Lname: .asciz "test.results"
.Ltitle: .asciz "Test Results"
.Lt_rerun: .asciz "Rerun"
.Lt_failed: .asciz "Rerun Failed Tests"
.Lt_stop: .asciz "Stop"
.Lms: .asciz " ms"
.Ls: .asciz " s"
.Lrunning: .asciz "Running\342\200\246 "
.Lfailed: .asciz " failed, "
.Lpassed: .asciz " passed"
.Lskipped: .asciz " skipped"
.Lcomma: .asciz ", "
.Ldot: .asciz " \302\267 "
.Lexpected: .ascii "Expected: "
.Lactual: .ascii "Actual:   "
.Lnone: .asciz "No output"
.Lcsi: .asciz "\033["
.Lwaiting: .asciz "Waiting for output\342\200\246"
.Ldash: .asciz "  \342\200\224  "
.Lp_hidden: .asciz "test-results hidden\n"
.Lp_status: .asciz "status="
.Lp_shown: .asciz "shown=1\n"
.Lp_notshown: .asciz "shown=0\n"
.Lp_log: .asciz "log "
.Lp_rect: .asciz "logrect"
.text
