# debug view: the sidebar's Variables, Watch, Call Stack and Breakpoints sections and the bottom
# panel's Debug Console tab (places.s, rtree.s), filled from the session model (dap.s, bp.s), and
# the debugger's commands (F5 and friends, keys.s)
.include "rhun.inc"

.equ DV_SECTIONS, 4
.equ DV_HISTORY_MAX, 100
.equ ID_DCON_INPUT, 0x5e0001
.equ ID_DCON_SCROLL, 0x5e0002
.equ ID_DV_ADDWATCH, 0x5e0003
.equ ID_DV_COLLAPSE, 0x5e0004

.bss
.p2align 3
trees: .zero 8 * DV_SECTIONS    # TR* of Variables, Watch, Call Stack, Breakpoints
synced: .zero 4 * DV_SECTIONS   # the generation each was filled at
idb: .zero SB_SIZE              # a node's id
lab: .zero SB_SIZE              # its label
desc: .zero SB_SIZE
dv_made: .long 0
dv_shown: .long 0               # the user's Show/Hide (debug_show)
.p2align 3
cin: .zero TF_SIZE              # the console's input line
history: .zero SB_SIZE          # its entries, one per line, oldest first
cscroll: .long 0                # console: pixels scrolled up from the end
.globl g_dsel
g_dsel: .zero SB_SIZE           # the selected configuration's name (NUL-terminated), empty: the first
prompt_kind: .long 0            # DP_* while the palette asks for the debugger
prompt_bp: .long 0              # the breakpoint (id) a prompt edits
prompt_var: .long 0             # Set Value: the variable node
prompt_var_sid: .long 0         # and its session
prompt_var_gen: .long 0         # and its variable pool's generation
.globl g_dpick_kind
g_dpick_kind: .long 0           # the debugger's pick list: 1 a launch's question, 2 a configuration, 3 a template
.p2align 3
pickb: .zero SB_SIZE            # Select Configuration's names; Add Configuration's launch.ini text
tplb: .zero SB_SIZE             # Add Configuration: the templates' sections
tplidx: .zero SB_SIZE           # and each one's start and end in tplb (two qwords)
tpllab: .zero SB_SIZE           # and each one's row, LF separated
pathb_dv: .zero SB_SIZE
.p2align 3
prompt_path: .zero SB_SIZE
cfg_first: .zero SB_SIZE        # launch.ini's names, for the status bar
cfg_prev: .zero SB_SIZE         # the names before the last read
cfg_proj: .quad 0               # the project and the open files' saves at the last read
cfg_saves: .quad 0
tb_rects: .zero 16 * 8          # the toolbar's buttons as last drawn: icon, x, y, size
tb_n: .long 0
cfg_checked: .quad 0
menu_line: .long 0              # a line for the next cursor_line (the gutter menu), 0 none
menu_target: .long 0
ctx_gen: .long 0

.data
.globl g_dv_places, g_debug_show_on_start, g_debug_keys_in_terminal
g_debug_keys_in_terminal: .long 1   # [debug] keys_in_terminal
g_dv_places: .long -1, -1, -1, -1, -1, -1   # the four sections, the console tab, the Debugger tab
.globl g_debug_layout
g_debug_layout: .long 0         # [debug] layout: 0 the sidebar's sections, 1 the Debugger tab
.globl g_debug_inline_values
g_debug_inline_values: .long 1  # [debug] inline_values
.globl g_debug_iv_lines
g_debug_iv_lines: .long 50      # [debug] inline_values_lines
.globl g_debug_frames_pct
g_debug_frames_pct: .long 30    # [debug] frames_width: the Debug tab's frames, % of its width
g_debug_show_on_start: .long 1  # [debug] show_on_start
hist_at: .long -1               # console history: Up/Down position, -1 at the input

.equ DP_COND, 1
.equ DP_HIT, 2
.equ DP_LOG, 3
.equ DP_WATCH, 4
.equ DP_FUNCTION, 5
.equ DP_LAUNCH, 6               # a launch's ${ask:} (debugask.s)
.equ DP_SETVAR, 7               # a variable's new value
.equ DP_EVAL, 8                 # Evaluate Expression

.text

# ---------------- registration ----------------

# dview_ensure(): the sections and the console tab exist (once)
FN dview_ensure
    PROLOGUE
    cmp dword ptr [rip + dv_made], 0
    jne 9f
    mov dword ptr [rip + dv_made], 1
    xor ebx, ebx
1:  cmp ebx, DV_SECTIONS
    jae 2f
    lea rax, [rip + tree_ops]
    mov rdi, [rax + rbx*8]
    mov esi, ebx                # ctx: the section
    call tree_new
    lea rcx, [rip + trees]
    mov [rcx + rbx*8], rax
    mov edi, PLACE_SIDEBAR
    lea rax, [rip + section_names]
    mov rsi, [rax + rbx*8]
    lea rax, [rip + section_titles]
    mov rdx, [rax + rbx*8]
    lea rcx, [rip + section_ops]
    mov r8d, ebx
    call place_add
    lea rcx, [rip + g_dv_places]
    mov [rcx + rbx*4], eax
    inc ebx
    jmp 1b
2:  mov edi, PLACE_PANEL         # the Debugger tab first: the panel shows its tabs in that order
    lea rsi, [rip + .Ln_debugger]
    lea rdx, [rip + .Lt_debugger]
    lea rcx, [rip + tw_ops]
    xor r8d, r8d
    call place_add
    mov [rip + g_dv_places + 20], eax
    mov edi, eax
    mov esi, IC_DBG_BUG
    call place_set_icon
    lea rdi, [rip + stack_tree_ops]     # its frames: Enter or a click focuses one, as Call Stack's
    mov esi, 2
    call tree_new
    mov [rip + frames_tr], rax
    mov dword ptr [rip + tw_eval + TF_id], ID_TW_EVAL
    mov edi, PLACE_PANEL
    lea rsi, [rip + .Ln_console]
    lea rdx, [rip + .Lt_console]
    lea rcx, [rip + console_ops]
    xor r8d, r8d
    call place_add
    mov [rip + g_dv_places + 16], eax
    mov edi, eax
    mov esi, IC_TERMINAL
    call place_set_icon
    mov dword ptr [rip + cin + TF_id], ID_DCON_INPUT
    # they start hidden; dview_show shows them (on start, or Ctrl+Shift+Y)
    xor ebx, ebx
3:  lea rax, [rip + g_dv_places]
    mov edi, [rax + rbx*4]
    mov esi, 1
    call place_set_hidden
    inc ebx
    cmp ebx, 6
    jb 3b
    mov dword ptr [rip + dv_shown], 0
9:  EPILOGUE

# dview_session_started(ds): a session began: the view shows ([debug] show_on_start)
FN dview_session_started
    PROLOGUE
    xor eax, eax                # the Debug tab: a run without debugging on its Console (its output)
    cmp dword ptr [rdi + DS_nodebug], 0
    setne al
    mov [rip + tw_sub], eax
    call dview_ensure
    cmp dword ptr [rip + g_debug_show_on_start], 0
    je 9f
    mov dword ptr [rip + dv_shown], 0
    call dview_show
9:  EPILOGUE

# dview_show(): Show/Hide the debug view (Ctrl+Shift+Y): the sections and the console, or with
#   [debug] layout = toolwindow the Debugger tab and the console
FN dview_show
    PROLOGUE
    call dview_ensure
    xor eax, eax
    cmp dword ptr [rip + dv_shown], 0
    sete al
    mov [rip + dv_shown], eax
    mov r12d, eax
    xor ebx, ebx
1:  cmp ebx, 6
    jae 2f
    mov esi, 1
    test r12d, r12d
    jz 11f
    xor esi, esi
    cmp dword ptr [rip + g_debug_layout], 0
    jne 12f
    cmp ebx, 5                  # the sections: the Debugger tab stays hidden
    sete sil
    jmp 11f
12: cmp ebx, 5                  # the Debug tab: the sections and the console tab stay hidden
    setb sil
11: lea rax, [rip + g_dv_places]
    mov edi, [rax + rbx*4]
    call place_set_hidden
    inc ebx
    jmp 1b
2:  test r12d, r12d
    jnz 3f
    call dv_leave_panel
    # hidden: a section, a tab with the keyboard gives it back to the editor
    cmp dword ptr [rip + g_focus], FOCUS_VIEW
    jne 9f
    call place_focused
    xor ebx, ebx
21: lea rcx, [rip + g_dv_places]
    cmp eax, [rcx + rbx*4]
    je 22f
    inc ebx
    cmp ebx, 6
    jb 21b
    jmp 9f
22: mov dword ptr [rip + g_focus], FOCUS_EDITOR
    jmp 9f
3:  cmp dword ptr [rip + g_debug_layout], 0
    je 31f
    mov edi, [rip + g_dv_places + 20]
    xor esi, esi
    call place_show
    jmp 9f
31: mov edi, [rip + g_dv_places]
    xor esi, esi
    call place_show
    mov edi, [rip + g_dv_places + 16]
    xor esi, esi
    call place_show
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# dv_leave_panel(): the view hid while the panel was on one of its tabs: the panel goes to the
#   terminals, or without any to its first other tab, or with nothing left it closes (not an empty panel)
dv_leave_panel:
    PROLOGUE
    mov eax, [rip + g_panel_cur]
    xor ecx, ecx
    lea rdx, [rip + g_dv_places]
1:  cmp ecx, 6
    jae 9f
    cmp eax, [rdx + rcx*4]
    je 2f
    inc ecx
    jmp 1b
2:  mov dword ptr [rip + g_panel_cur], -1
    call term_count
    test rax, rax
    jnz 9f
    call places_panel_count
    test eax, eax
    jz 3f
    xor edi, edi
    call places_panel_nth
    mov [rip + g_panel_cur], eax
    jmp 9f
3:  mov dword ptr [rip + g_term_open], 0
9:  EPILOGUE

# dv_close(ctx): the x on the Debug tab or the Debug Console's: the debug view hides (Debug: Show or
#   Hide brings it back, as a session's start does)
dv_close:
    PROLOGUE
    cmp dword ptr [rip + dv_shown], 0
    je 9f
    call dview_show
9:  EPILOGUE

# dview_sync(section): its tree filled now (the Breakpoints dialog's list, bpdialog.s)
FN dview_sync
    jmp sync

# dview_tree(section) -> rax its TR*, or 0 before the view exists (tests)
FN dview_tree
    xor eax, eax
    cmp edi, DV_SECTIONS
    jae 1f
    lea rax, [rip + trees]
    mov rax, [rax + rdi*8]
1:  ret

# dview_sync_all(): every tree filled now (tests look at them without drawing)
FN dview_sync_all
    PROLOGUE
    cmp dword ptr [rip + dv_made], 0
    je 9f
    xor ebx, ebx
1:  cmp ebx, DV_SECTIONS
    jae 9f
    mov edi, ebx
    call sync
    inc ebx
    jmp 1b
9:  EPILOGUE

# ---------------- sections ----------------

# section_draw(ctx = section, x, y, w, h)
section_draw:
    PROLOGUE 16
    mov ebx, edi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov edi, ebx
    call sync
    call place_focused
    lea rcx, [rip + g_dv_places]
    xor r9d, r9d
    cmp eax, [rcx + rbx*4]
    sete r9b
    lea rax, [rip + trees]
    mov rdi, [rax + rbx*8]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call tree_draw
    EPILOGUE

# section_key(ctx, keysym, cp, mods) -> eax: the tree's keys; Delete removes a watch or breakpoint
section_key:
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    cmp r12d, KEY_DELETE
    jne 1f
    mov edi, ebx
    call delete_cursor
    test eax, eax
    jnz 9f
1:  cmp r12d, KEY_F1 + 1        # F2 on a variable: Set Value
    jne 2f
    test ebx, ebx
    jnz 2f
    call set_value_prompt
    test eax, eax
    jnz 9f
2:  lea rax, [rip + trees]
    mov rdi, [rax + rbx*8]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tree_key
9:  EPILOGUE

# section_actions(ctx, right, y, h) -> eax the x left of its header buttons: Watch has + (add),
#   Variables a collapse-all
section_actions:
    PROLOGUE 16
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov eax, r12d
    cmp ebx, 1
    jne 9f
    M ecx, MI_24
    sub r12d, ecx
    mov edi, ID_DV_ADDWATCH
    mov esi, r12d
    mov edx, r13d
    mov r8d, r14d
    mov r9d, IC_PLUS
    call ui_icon_btn
    test eax, UB_CLICK
    jz 1f
    call cmd_debug_add_watch
1:  mov eax, r12d
9:  EPILOGUE

# set_value_prompt() -> eax 1 when the Variables cursor is on a variable: the prompt for its new
#   value, its current one filled in
set_value_prompt:
    PROLOGUE
    call dap_focused
    test rax, rax
    jz 8f
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 8f
    lea rax, [rip + trees]
    mov r12, [rax]
    mov rdi, r12
    call tree_cursor
    test eax, eax
    js 8f
    mov rdi, r12
    mov esi, eax
    call tree_user
    test eax, eax
    jz 8f
    dec eax
    mov r13d, eax
    mov [rip + prompt_var], eax
    mov eax, [rbx + DS_id]
    mov [rip + prompt_var_sid], eax
    mov eax, [rbx + DS_vgen]
    mov [rip + prompt_var_gen], eax
    mov rdi, rbx
    mov esi, r13d
    call vn_node
    mov r14, rax
    lea rdi, [rip + lab]
    call sb_clear
    mov esi, [r14 + VN_value]
    add rsi, [rbx + DS_strs + SB_ptr]
    mov edx, [r14 + VN_valuelen]
    lea rdi, [rip + lab]
    call sb_push
    lea rdi, [rip + lab]
    xor esi, esi
    call sb_push_byte
    mov edi, DP_SETVAR
    lea rsi, [rip + .Lp_setvar]
    mov rdx, [rip + lab + SB_ptr]
    call ask
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# delete_cursor(section) -> eax 1 when Delete removed the watch or breakpoint under the cursor
delete_cursor:
    PROLOGUE
    mov ebx, edi
    lea rax, [rip + trees]
    mov r12, [rax + rbx*8]
    mov rdi, r12
    call tree_cursor
    test eax, eax
    js 8f
    mov r13d, eax
    mov rdi, r12
    mov esi, r13d
    call tree_node_id
    mov r14, rax
    mov r15, rdx
    cmp ebx, 1
    jne 2f
    # a watch root: "watch:EXPR"
    cmp r15, 6
    jbe 8f
    mov rdi, r14
    mov esi, 6
    lea rdx, [rip + .Lwatch_prefix]
    call str_eq_cstr
    test eax, eax
    jz 8f
    xor ecx, ecx
1:  lea rax, [r14 + 6 + rcx]
    cmp rcx, r15
    jae 11f
    inc rcx
    jmp 1b
11: lea rdi, [r14 + 6]
    lea rsi, [r15 - 6]
    call dap_watch_remove
    call bp_save_soon
    mov eax, 1
    EPILOGUE
2:  cmp ebx, 3
    jne 8f
    mov rdi, r12
    mov esi, r13d
    call tree_user
    test eax, eax
    jz 8f
    cmp eax, 0x40000000
    jae 8f                      # an exception filter
    lea edi, [rax - 1]
    call bp_index_of_id
    test eax, eax
    js 8f
    mov edi, eax
    call bp_remove
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# sync(section): the tree filled from the model when it changed
sync:
    PROLOGUE
    mov ebx, edi
    mov eax, [rip + g_dap_gen]
    add eax, [rip + g_bp_gen]
    lea rcx, [rip + synced]
    cmp [rcx + rbx*4], eax
    je 9f
    mov [rcx + rbx*4], eax
    lea rax, [rip + trees]
    mov r12, [rax + rbx*8]
    lea rax, [rip + sync_fns]
    mov rdi, r12
    call [rax + rbx*8]
9:  EPILOGUE

# ---------------- Variables and Watch ----------------

# sync_vars(tr): the focused session's scopes and the variables opened under them
sync_vars:
    xor esi, esi
    jmp sync_roots
# sync_watch(tr): the watch expressions; their values and children while paused
sync_watch:
    mov esi, 1
sync_roots:
    PROLOGUE 16
    mov r12, rdi
    mov [rsp], esi              # 1: watch roots
    call dap_focused
    mov rbx, rax
    mov rdi, r12
    xor esi, esi
    call tree_kids_begin
    test rbx, rbx
    jz 5f
    cmp dword ptr [rsp], 0
    je 1f
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    je 1f
    test dword ptr [rbx + DS_flags], DSF_STALE
    jz 5f
1:  xor r13d, r13d
2:  cmp r13, [rbx + DS_vars + VEC_len]
    jae 3f
    mov rdi, rbx
    mov esi, r13d
    call root_kind
    cmp eax, [rsp]
    jne 21f
    mov rdi, r12
    mov rsi, rbx
    mov edx, r13d
    call list_vn
21: inc r13
    jmp 2b
3:  mov rdi, r12
    xor esi, esi
    call tree_kids_end
    xor r13d, r13d
4:  cmp r13, [rbx + DS_vars + VEC_len]
    jae 9f
    mov rdi, rbx
    mov esi, r13d
    call root_kind
    cmp eax, [rsp]
    jne 41f
    mov rdi, r12
    mov rsi, rbx
    mov edx, r13d
    call list_children
41: inc r13
    jmp 4b
5:  # no values to show: the watch expressions alone
    cmp dword ptr [rsp], 0
    je 8f
    xor r13d, r13d
6:  mov edi, r13d
    call dap_watch_text
    test rax, rax
    jz 8f
    mov r14, rax
    mov r15, rdx
    lea rdi, [rip + idb]
    lea rsi, [rip + .Lwatch_prefix]
    call sb_setc
    lea rdi, [rip + idb]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    mov rdi, r12
    mov rsi, [rip + idb + SB_ptr]
    mov rdx, [rip + idb + SB_len]
    mov rcx, r14
    mov r8, r15
    mov r9d, KIDS_LEAF
    call tree_kid
    test eax, eax
    js 7f
    mov rdi, r12
    mov esi, eax
    lea rdx, [rip + .Lnot_available]
    mov ecx, .Lnot_available_end - .Lnot_available
    call tree_set_desc
7:  inc r13d
    jmp 6b
8:  mov rdi, r12
    xor esi, esi
    call tree_kids_end
9:  EPILOGUE

# root_kind(ds, node) -> eax 0 a scope, 1 a watch result, -1 not a root
root_kind:
    push rbx
    call vn_node
    mov rcx, rax
    mov eax, -1
    cmp dword ptr [rcx + VN_parent], -1
    jne 1f
    mov eax, [rcx + VN_flags]
    and eax, VNF_WATCH
    setnz al
    movzx eax, al
1:  pop rbx
    ret

# list_vn(tr, ds, node): one tree_kid for a variable node: id its path, label "name = value", desc its
#   type; children open as the model has them
list_vn:
    PROLOGUE 16
    mov r12, rdi
    mov rbx, rsi
    mov r13d, edx
    mov rdi, rbx
    mov esi, r13d
    call dap_node_path
    lea rdi, [rip + idb]
    mov rsi, [rip + g_nodep + SB_ptr]
    mov rdx, [rip + g_nodep + SB_len]
    call sb_set
    mov rdi, rbx
    mov esi, r13d
    call vn_node
    mov r14, rax
    # label
    lea rdi, [rip + lab]
    call sb_clear
    mov ecx, [r14 + VN_name]
    mov rsi, [rbx + DS_strs + SB_ptr]
    add rsi, rcx
    mov edx, [r14 + VN_namelen]
    lea rdi, [rip + lab]
    call sb_push
    cmp dword ptr [r14 + VN_valuelen], 0
    je 1f
    lea rdi, [rip + lab]
    lea rsi, [rip + .Leq]
    call sb_push_cstr
    mov ecx, [r14 + VN_value]
    mov rsi, [rbx + DS_strs + SB_ptr]
    add rsi, rcx
    mov edx, [r14 + VN_valuelen]
    lea rdi, [rip + lab]
    call sb_push
1:  mov r9d, KIDS_LEAF
    cmp qword ptr [r14 + VN_ref], 0
    je 2f
    mov r9d, KIDS_CLOSED
    test dword ptr [r14 + VN_flags], VNF_EXPANDED
    jz 2f
    mov r9d, KIDS_OPEN
2:  mov rdi, r12
    mov rsi, [rip + idb + SB_ptr]
    mov rdx, [rip + idb + SB_len]
    mov rcx, [rip + lab + SB_ptr]
    mov r8, [rip + lab + SB_len]
    call tree_kid
    test eax, eax
    js 9f
    mov r15d, eax
    mov rdi, r12
    mov esi, r15d
    lea edx, [r13 + 1]
    call tree_set_user
    mov ecx, [r14 + VN_type]
    mov rdx, [rbx + DS_strs + SB_ptr]
    add rdx, rcx
    mov ecx, [r14 + VN_typelen]
    mov rdi, r12
    mov esi, r15d
    call tree_set_desc
    mov edx, -1
    test dword ptr [r14 + VN_flags], VNF_CHANGED
    jz 21f
    mov edx, T_WARNING          # changed since the last stop
21: test dword ptr [rbx + DS_flags], DSF_STALE
    jz 3f
    mov edx, T_MUTED
3:  test dword ptr [r14 + VN_flags], VNF_ERROR
    jz 4f
    mov edx, T_ERROR
4:  mov rdi, r12
    mov esi, r15d
    call tree_set_color
9:  EPILOGUE

# list_children(tr, ds, node): the open node's children listed under it, and theirs
list_children:
    PROLOGUE 16
    mov r12, rdi
    mov rbx, rsi
    mov r13d, edx
    mov rdi, rbx
    mov esi, r13d
    call vn_node
    test dword ptr [rax + VN_flags], VNF_EXPANDED
    jz 9f
    mov r14d, [rax + VN_kid0]
    test r14d, r14d
    js 9f
    mov r15d, [rax + VN_nkids]
    add r15d, r14d
    mov rdi, rbx
    mov esi, r13d
    call dap_node_path
    mov rdi, r12
    mov rsi, [rip + g_nodep + SB_ptr]
    mov rdx, [rip + g_nodep + SB_len]
    call tree_find
    test eax, eax
    js 9f
    mov rdi, r12
    mov esi, eax
    call tree_kids_begin
    mov [rsp], r14d
1:  cmp r14d, r15d
    jae 2f
    mov rdi, r12
    mov rsi, rbx
    mov edx, r14d
    call list_vn
    inc r14d
    jmp 1b
2:  mov rdi, r12
    xor esi, esi
    call tree_kids_end
    mov r14d, [rsp]
3:  cmp r14d, r15d
    jae 9f
    mov rdi, r12
    mov rsi, rbx
    mov edx, r14d
    call list_children
    inc r14d
    jmp 3b
9:  EPILOGUE

# vars_expand(ctx, tr, node, on): the user opened or closed a variable
vars_expand:
    PROLOGUE
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    call dap_focused
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, r12
    mov esi, r13d
    call tree_user
    test eax, eax
    jz 9f
    lea esi, [rax - 1]
    cmp rsi, [rbx + DS_vars + VEC_len]
    jae 9f
    mov rdi, rbx
    test r14d, r14d
    jz 1f
    call vn_expand
    jmp 9f
1:  call vn_collapse
9:  EPILOGUE

# vars_load(ctx, tr, node): an open node on screen wants its children
vars_load:
    mov ecx, 1
    jmp vars_expand

# ---------------- Call Stack ----------------

# sync_stack(tr): sessions, the focused session's threads, the focused thread's frames
sync_stack:
    PROLOGUE 32
    mov r12, rdi
    mov rdi, r12
    xor esi, esi
    call tree_kids_begin
    xor r13d, r13d
1:  cmp r13d, DS_MAX
    jae 3f
    mov edi, r13d
    call dap_slot
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_FREE
    je 2f
    # id s<ID>, label the name, desc the state
    lea rdi, [rip + idb]
    call sb_clear
    lea rdi, [rip + idb]
    mov esi, 's'
    call sb_push_byte
    lea rdi, [rip + idb]
    mov esi, [rbx + DS_id]
    call sb_push_u64
    mov rcx, [rbx + DS_name]
    test rcx, rcx
    jnz 11f
    lea rcx, [rip + .Lunnamed]
11: mov rdi, rcx
    call strlen
    mov r8, rax
    mov rcx, [rbx + DS_name]
    test rcx, rcx
    jnz 12f
    lea rcx, [rip + .Lunnamed]
12: mov r9d, KIDS_OPEN
    cmp qword ptr [rbx + DS_threads + VEC_len], 0
    jne 13f
    cmp qword ptr [rbx + DS_frames + VEC_len], 0
    jne 13f
    mov r9d, KIDS_LEAF
13: mov rdi, r12
    mov rsi, [rip + idb + SB_ptr]
    mov rdx, [rip + idb + SB_len]
    call tree_kid
    test eax, eax
    js 2f
    mov r14d, eax
    mov rdi, r12
    mov esi, eax
    lea edx, [r13 + 1]
    call tree_set_user
    mov rdi, rbx
    call session_desc
    mov rdi, r12
    mov esi, r14d
    mov rdx, [rip + desc + SB_ptr]
    mov rcx, [rip + desc + SB_len]
    call tree_set_desc
2:  inc r13d
    jmp 1b
3:  mov rdi, r12
    xor esi, esi
    call tree_kids_end
    # under each session: its threads (the stopped one with its frames)
    xor r13d, r13d
4:  cmp r13d, DS_MAX
    jae 9f
    mov edi, r13d
    call dap_slot
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_FREE
    je 5f
    mov rdi, r12
    mov rsi, rbx
    call list_threads
5:  inc r13d
    jmp 4b
9:  EPILOGUE

# session_desc(ds): desc = its state (and why it stopped)
session_desc:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + desc]
    call sb_clear
    mov edi, [rbx + DS_state]
    call dap_state_name
    lea rdi, [rip + desc]
    mov rsi, rax
    call sb_push_cstr
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    mov rsi, [rbx + DS_reason]
    test rsi, rsi
    jz 9f
    lea rdi, [rip + desc]
    lea rsi, [rip + .Lon]
    call sb_push_cstr
    lea rdi, [rip + desc]
    mov rsi, [rbx + DS_reason]
    call sb_push_cstr
9:  EPILOGUE

# list_threads(tr, ds)
list_threads:
    PROLOGUE 16
    mov r12, rdi
    mov rbx, rsi
    lea rdi, [rip + idb]
    call sb_clear
    lea rdi, [rip + idb]
    mov esi, 's'
    call sb_push_byte
    lea rdi, [rip + idb]
    mov esi, [rbx + DS_id]
    call sb_push_u64
    mov rdi, r12
    mov rsi, [rip + idb + SB_ptr]
    mov rdx, [rip + idb + SB_len]
    call tree_find
    test eax, eax
    js 9f
    mov [rsp], eax
    mov rdi, r12
    mov esi, eax
    call tree_kids_begin
    xor r13d, r13d
1:  cmp r13, [rbx + DS_threads + VEC_len]
    jae 2f
    imul r14, r13, THR_SIZE
    add r14, [rbx + DS_threads + VEC_ptr]
    call thread_id
    mov ecx, [r14 + THR_name]
    add rcx, [rbx + DS_strs + SB_ptr]
    mov r8d, [r14 + THR_namelen]
    mov r9d, KIDS_LEAF
    mov rax, [r14 + THR_id]
    cmp rax, [rbx + DS_thread]
    jne 11f
    mov r9d, KIDS_OPEN
11: mov rdi, r12
    mov rsi, [rip + idb + SB_ptr]
    mov rdx, [rip + idb + SB_len]
    call tree_kid
    test eax, eax
    js 12f
    mov rdi, r12                # activating it focuses the thread
    mov esi, eax
    mov edx, 1
    call tree_set_user
12: inc r13
    jmp 1b
2:  # frames without a thread list yet: directly under the session
    cmp qword ptr [rbx + DS_threads + VEC_len], 0
    jne 3f
    mov rdi, r12
    xor esi, esi
    call tree_kids_end
    mov rdi, r12
    mov esi, [rsp]
    mov rdx, rbx
    call list_frames
    EPILOGUE
3:  mov rdi, r12
    xor esi, esi
    call tree_kids_end
    # the focused thread's frames
    xor r13d, r13d
4:  cmp r13, [rbx + DS_threads + VEC_len]
    jae 9f
    imul r14, r13, THR_SIZE
    add r14, [rbx + DS_threads + VEC_ptr]
    mov rax, [r14 + THR_id]
    cmp rax, [rbx + DS_thread]
    jne 5f
    call thread_id
    mov rdi, r12
    mov rsi, [rip + idb + SB_ptr]
    mov rdx, [rip + idb + SB_len]
    call tree_find
    test eax, eax
    js 9f
    mov rdi, r12
    mov esi, eax
    mov rdx, rbx
    call list_frames
    jmp 9f
5:  inc r13
    jmp 4b
9:  EPILOGUE
# thread_id: idb = "s<ID>/t<thread id>" for thread r14 of session rbx
thread_id:
    lea rdi, [rip + idb]
    call sb_clear
    lea rdi, [rip + idb]
    mov esi, 's'
    call sb_push_byte
    lea rdi, [rip + idb]
    mov esi, [rbx + DS_id]
    call sb_push_u64
    lea rdi, [rip + idb]
    lea rsi, [rip + .Lslash_t]
    call sb_push_cstr
    lea rdi, [rip + idb]
    mov rsi, [r14 + THR_id]
    jmp sb_push_u64

# list_frames(tr, parent node, ds): frame nodes "s<ID>/f<I>", label the function, desc file:line;
#   the focused one marked
list_frames:
    PROLOGUE 16
    mov r12, rdi
    mov [rsp], esi
    mov rbx, rdx
    mov rdi, r12
    mov esi, [rsp]
    call tree_kids_begin
    xor r13d, r13d
1:  cmp r13, [rbx + DS_frames + VEC_len]
    jae 8f
    imul r14, r13, FR_SIZE
    add r14, [rbx + DS_frames + VEC_ptr]
    lea rdi, [rip + idb]
    call sb_clear
    lea rdi, [rip + idb]
    mov esi, 's'
    call sb_push_byte
    lea rdi, [rip + idb]
    mov esi, [rbx + DS_id]
    call sb_push_u64
    lea rdi, [rip + idb]
    lea rsi, [rip + .Lslash_f]
    call sb_push_cstr
    lea rdi, [rip + idb]
    mov rsi, r13
    call sb_push_u64
    mov ecx, [r14 + FR_name]
    add rcx, [rbx + DS_strs + SB_ptr]
    mov r8d, [r14 + FR_namelen]
    mov rdi, r12
    mov rsi, [rip + idb + SB_ptr]
    mov rdx, [rip + idb + SB_len]
    mov r9d, KIDS_LEAF
    call tree_kid
    test eax, eax
    js 7f
    mov r15d, eax
    mov rdi, r12
    mov esi, r15d
    lea rdx, [r13 + 1]
    call tree_set_user
    # desc: basename:line
    lea rdi, [rip + desc]
    call sb_clear
    mov ecx, [r14 + FR_path]
    mov rdi, [rbx + DS_strs + SB_ptr]
    add rdi, rcx
    mov esi, [r14 + FR_pathlen]
    call path_basename
    lea rdi, [rip + desc]
    mov rsi, rax
    call sb_push
    cmp dword ptr [r14 + FR_line], 0
    je 2f
    lea rdi, [rip + desc]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + desc]
    mov esi, [r14 + FR_line]
    call sb_push_u64
2:  mov rdi, r12
    mov esi, r15d
    mov rdx, [rip + desc + SB_ptr]
    mov rcx, [rip + desc + SB_len]
    call tree_set_desc
    mov edx, -1
    cmp r13d, [rbx + DS_frame]
    jne 3f
    mov rdi, r12
    mov esi, r15d
    mov edx, IC_ARROW_UP + 0     # the focused frame
    mov edx, IC_CHEV_R
    mov ecx, T_WARNING
    call tree_set_icon
    jmp 7f
3:  cmp dword ptr [r14 + FR_hint], 0
    je 7f
    mov rdi, r12
    mov esi, r15d
    mov edx, T_MUTED
    call tree_set_color
7:  inc r13
    jmp 1b
8:  mov rdi, r12
    xor esi, esi
    call tree_kids_end
    EPILOGUE

# stack_activate(ctx, tr, node): a session node focuses that session; a thread node the thread; a
#   frame node the frame
stack_activate:
    PROLOGUE 16
    mov r12, rsi
    mov r13d, edx
    mov rdi, r12
    mov esi, r13d
    call tree_node_id
    mov r14, rax
    mov r15, rdx
    mov rdi, r12
    mov esi, r13d
    call tree_user
    test eax, eax
    jz 9f
    mov ebx, eax
    # "s<ID>" alone: a session; "s<ID>/f<I>": a frame of that session (focused first)
    mov rcx, r15
1:  test rcx, rcx
    jz 2f
    cmp byte ptr [r14 + rcx - 1], '/'
    je 3f
    dec rcx
    jmp 1b
2:  lea edi, [rbx - 1]
    call dap_focus_slot
    jmp 9f
3:  cmp byte ptr [r14 + rcx], 'f'
    je 31f
    cmp byte ptr [r14 + rcx], 't'
    jne 9f
    # "s<ID>/t<thread id>": that thread
    lea rdi, [r14 + rcx + 1]
    mov rsi, r15
    sub rsi, rcx
    dec rsi
    mov [rsp], rcx
    call parse_u64
    test edx, edx
    jz 9f
    mov rbx, rax
    mov rcx, [rsp]
    xor edi, edi
    mov rdx, 1
32: cmp rdx, rcx
    jae 33f
    movzx eax, byte ptr [r14 + rdx]
    sub eax, '0'
    cmp eax, 9
    ja 33f
    imul edi, edi, 10
    add edi, eax
    inc rdx
    jmp 32b
33: call dap_slot_of_id
    test rax, rax
    jz 9f
    mov r15, rax
    mov rdi, rax
    call dap_focus_ds
    mov rdi, r15
    mov rsi, rbx
    call dap_focus_thread
    jmp 9f
31: # the session's id: the digits after the leading s
    xor edi, edi
    mov rdx, 1
4:  cmp rdx, rcx
    jae 5f
    movzx eax, byte ptr [r14 + rdx]
    sub eax, '0'
    cmp eax, 9
    ja 5f
    imul edi, edi, 10
    add edi, eax
    inc rdx
    jmp 4b
5:  call dap_slot_of_id
    test rax, rax
    jz 9f
    mov r15, rax
    mov rdi, rax
    call dap_focus_ds
    mov rdi, r15
    lea esi, [rbx - 1]
    call dap_focus_frame
9:  EPILOGUE

# ---------------- Breakpoints ----------------

# sync_bps(tr): a node per breakpoint (checkbox: enabled; desc: its condition, hit count or log
#   message; icon: as the focused session reports it), then the exception filters
sync_bps:
    PROLOGUE 16
    mov r12, rdi
    call bp_ensure_loaded
    mov rdi, r12
    xor esi, esi
    call tree_kids_begin
    mov eax, [rip + g_dfocus]
    mov [rsp], eax
    xor r13d, r13d
1:  call bp_count
    cmp r13, rax
    jae 5f
    mov rdi, r13
    call bp_row
    mov rbx, rax
    lea rdi, [rip + idb]
    call sb_clear
    lea rdi, [rip + idb]
    mov esi, 'b'
    call sb_push_byte
    lea rdi, [rip + idb]
    mov esi, [rbx + BP_id]
    call sb_push_u64
    # label: file:line, or the function's name()
    lea rdi, [rip + lab]
    call sb_clear
    mov rdi, [rbx + BP_path]
    call strlen
    cmp dword ptr [rbx + BP_kind], 0
    jne 11f
    mov rdi, [rbx + BP_path]
    mov rsi, rax
    call path_basename
    lea rdi, [rip + lab]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + lab]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + lab]
    mov esi, [rbx + BP_line]
    call sb_push_u64
    jmp 12f
11: lea rdi, [rip + lab]
    mov rsi, [rbx + BP_path]
    call sb_push_cstr
    lea rdi, [rip + lab]
    lea rsi, [rip + .Lparens]
    call sb_push_cstr
12: mov rdi, r12
    mov rsi, [rip + idb + SB_ptr]
    mov rdx, [rip + idb + SB_len]
    mov rcx, [rip + lab + SB_ptr]
    mov r8, [rip + lab + SB_len]
    mov r9d, KIDS_LEAF
    call tree_kid
    test eax, eax
    js 4f
    mov r14d, eax
    mov rdi, r12
    mov esi, r14d
    mov edx, [rbx + BP_id]
    inc edx
    call tree_set_user
    mov rdi, r12
    mov esi, r14d
    mov edx, [rbx + BP_enabled]
    call tree_set_check
    # desc
    lea rdi, [rip + desc]
    call sb_clear
    lea rsi, [rip + .Lif]
    mov rdx, [rbx + BP_cond]
    call desc_opt
    lea rsi, [rip + .Lhits]
    mov rdx, [rbx + BP_hit]
    call desc_opt
    lea rsi, [rip + .Llog]
    mov rdx, [rbx + BP_log]
    call desc_opt
    mov ecx, [rsp]
    test ecx, ecx
    js 2f
    mov rsi, [rbx + BP_msg + rcx*8]
    test rsi, rsi
    jz 2f
    lea rsi, [rip + .Lsep]
    mov rdx, [rbx + BP_msg + rcx*8]
    call desc_opt
2:  mov rdi, r12
    mov esi, r14d
    mov rdx, [rip + desc + SB_ptr]
    mov rcx, [rip + desc + SB_len]
    call tree_set_desc
    # icon: red dot; hollow (muted) when unverified, a warning color when rejected, grey disabled
    mov ecx, T_ERROR
    cmp dword ptr [rbx + BP_enabled], 0
    jne 21f
    mov ecx, T_MUTED
    jmp 3f
21: mov eax, [rsp]
    test eax, eax
    js 3f
    mov eax, [rbx + BP_ver + rax*4]
    cmp eax, 1
    jne 22f
    mov ecx, T_MUTED
    jmp 3f
22: cmp eax, 3
    jne 3f
    mov ecx, T_WARNING
3:  mov rdi, r12
    mov esi, r14d
    mov edx, IC_DOT
    call tree_set_icon
4:  inc r13
    jmp 1b
5:  # the focused session's exception filters
    call dap_focused
    test rax, rax
    jz 8f
    mov rbx, rax
    mov r13, [rbx + DS_filters + SB_ptr]
    mov r15, [rbx + DS_filters + SB_len]
    add r15, r13
    xor r14d, r14d              # filter index
6:  cmp r13, r15
    jae 8f
    # FILTER \t LABEL \t DEFAULT \n
    mov rcx, r13
61: cmp byte ptr [rcx], 9
    je 62f
    inc rcx
    jmp 61b
62: mov [rsp + 8], rcx
    lea rdi, [rip + idb]
    lea rsi, [rip + .Lx_prefix]
    call sb_setc
    lea rdi, [rip + idb]
    mov rsi, r13
    mov rdx, [rsp + 8]
    sub rdx, r13
    call sb_push
    mov rcx, [rsp + 8]
    inc rcx
    mov rdx, rcx
63: cmp byte ptr [rdx], 9
    je 64f
    inc rdx
    jmp 63b
64: mov r8, rdx
    sub r8, rcx
    push rdx
    push rdx
    mov rdi, r12
    mov rsi, [rip + idb + SB_ptr]
    mov rdx, [rip + idb + SB_len]
    mov r9d, KIDS_LEAF
    call tree_kid
    pop rdx
    pop rdx
    movzx ecx, byte ptr [rdx + 1]
    sub ecx, '0'
    lea r13, [rdx + 3]          # past "\tD\n"
    test eax, eax
    js 66f
    push rcx
    push rax
    mov rdi, r12
    mov esi, eax
    lea edx, [r14 + 0x40000001]
    call tree_set_user
    # checked: the user's choice, else the adapter's default
    mov rdi, rbx
    mov rsi, [rip + idb + SB_ptr]
    add rsi, 2
    mov rdx, [rip + idb + SB_len]
    sub rdx, 2
    call exc_enabled
    pop rsi
    pop rcx
    cmp eax, -1
    jne 65f
    mov eax, ecx
65: mov edx, eax
    mov rdi, r12
    call tree_set_check
66: inc r14d
    jmp 6b
8:  mov rdi, r12
    xor esi, esi
    call tree_kids_end
    EPILOGUE
# desc_opt: rdx (cstr or 0) appended to desc after the label rsi
desc_opt:
    test rdx, rdx
    jz 1f
    push rdx
    push rdx
    cmp qword ptr [rip + desc + SB_len], 0
    je 2f
    push rsi
    push rsi
    lea rdi, [rip + desc]
    mov esi, ' '
    call sb_push_byte
    pop rsi
    pop rsi
2:  lea rdi, [rip + desc]
    call sb_push_cstr
    pop rsi
    pop rsi
    lea rdi, [rip + desc]
    jmp sb_push_cstr
1:  ret

# bps_check(ctx, tr, node, state): a checkbox: a breakpoint enabled or not, an exception filter on
#   or off for the focused session's debugger type
bps_check:
    PROLOGUE
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov rdi, r12
    mov esi, r13d
    call tree_user
    test eax, eax
    jz 9f
    cmp eax, 0x40000000
    jae 2f
    lea edi, [rax - 1]
    call bp_index_of_id
    test eax, eax
    js 9f
    mov edi, eax
    mov esi, r14d
    call bp_enable
    jmp 9f
2:  call dap_focused
    test rax, rax
    jz 9f
    mov edi, [rax + DS_dbg]
    call dbg_row
    mov rbx, [rax + DBG_type]
    mov rdi, r12
    mov esi, r13d
    call tree_node_id
    lea rsi, [rax + 2]          # "x:FILTER"
    lea rdx, [rdx - 2]
    mov rdi, rbx
    mov ecx, r14d
    call bp_exc_set
9:  EPILOGUE

# bps_activate(ctx, tr, node): a line breakpoint's file opens at its line
bps_activate:
    PROLOGUE
    mov rdi, rsi
    mov esi, edx
    call tree_user
    test eax, eax
    jz 9f
    cmp eax, 0x40000000
    jae 9f
    lea edi, [rax - 1]
    call bp_index_of_id
    test eax, eax
    js 9f
    mov edi, eax
    call bp_row
    mov rbx, rax
    cmp dword ptr [rbx + BP_kind], 0
    jne 9f
    mov rdi, [rbx + BP_path]
    call app_open_file
    test rax, rax
    js 9f
    mov edi, [rbx + BP_line]
    mov esi, 1
    call app_goto_line
9:  EPILOGUE

# ---------------- the console ----------------

# console_draw(ctx, x, y, w, h): the lines (the last at the bottom, colored by category; the terminal's
#   font, size and line height) and the input line
console_draw:
    PROLOGUE 48
    mov [rsp], esi              # x
    mov [rsp + 4], edx          # y
    mov [rsp + 8], ecx          # w
    mov [rsp + 12], r8d         # h
    mov edi, esi
    mov esi, edx
    mov edx, ecx
    mov ecx, r8d
    COLOR r8d, T_PANEL
    call gfx_fill
    # the input line at the bottom
    M eax, MI_ROW
    mov [rsp + 16], eax         # row height
    mov ecx, [rsp + 4]
    add ecx, [rsp + 12]
    sub ecx, eax
    sub ecx, [rip + g_mt + 4*MI_6]      # a little room under it
    mov [rsp + 20], ecx         # input y
    call place_focused
    xor r9d, r9d
    cmp eax, [rip + g_dv_places + 16]
    sete r9b
    cmp eax, [rip + g_dv_places + 20]   # or the Debug tab's Console
    jne 1f
    cmp dword ptr [rip + tw_sub], 1
    jne 1f
    mov r9d, 1
1:  lea rdi, [rip + cin]
    mov esi, [rsp]
    M eax, MI_8
    add esi, eax
    mov edx, [rsp + 20]
    mov ecx, [rsp + 8]
    M eax, MI_16
    sub ecx, eax
    mov r8d, [rsp + 16]
    lea rax, [rip + .Lph_eval]
    push rax
    push rax
    call ui_textfield
    add rsp, 16
    # the lines, from the last up
    call term_line_metrics      # the terminal's font, size and line height
    mov [rsp + 24], eax         # line height
    # scrolled up into history: the newest lines move down, below the view (clipped)
    call dcon_count
    imul eax, [rsp + 24]
    mov ecx, [rsp + 20]
    sub ecx, [rsp + 4]          # the lines' room
    sub eax, ecx
    jns 61f
    xor eax, eax
61: cmp [rip + cscroll], eax
    jle 62f
    mov [rip + cscroll], eax    # no further than the oldest line
62: call dcon_count            # fewer lines than the room: from the top, as a console reads
    imul eax, [rsp + 24]
    mov ecx, [rsp + 20]
    sub ecx, [rsp + 4]
    sub ecx, [rip + g_mt + 4*MI_6]
    cmp eax, ecx
    jge 63f
    mov ecx, [rsp + 4]
    add ecx, [rip + g_mt + 4*MI_6]
    add ecx, eax
    jmp 64f
63: mov ecx, [rsp + 20]         # else the newest at the bottom, scrolled up into the history
    add ecx, [rip + cscroll]
64: mov [rsp + 28], ecx         # bottom of the next line up
    mov esi, [rsp + 4]
    mov ecx, [rsp + 20]
    sub ecx, esi
    mov edi, [rsp]
    mov edx, [rsp + 8]
    call gfx_clip_push
    call dcon_count
    mov r12, rax                # lines
1:  test r12, r12
    jz 4f
    mov eax, [rsp + 28]
    cmp eax, [rsp + 4]
    jle 4f
    dec r12
    mov rdi, r12
    call dcon_get
    mov r13, rax
    mov r14, rdx
    mov edi, ecx
    call cat_color
    mov r15d, eax
    mov eax, [rsp + 28]
    sub eax, [rsp + 24]
    mov [rsp + 28], eax
    # the category of an input line shows as "> "
    mov edi, [rsp]
    M eax, MI_8
    add edi, eax
    mov [rsp + 32], edi
    mov rdi, r12
    call dcon_get
    cmp ecx, DCON_INPUT
    jne 2f
    lea rdi, [rip + g_face_term]
    mov esi, [rsp + 32]
    mov edx, [rsp + 28]
    mov ecx, [rsp + 24]
    lea r8, [rip + .Lgt]
    mov r9d, r15d
    call ui_text_c
    mov [rsp + 32], eax
2:  lea rdi, [rip + g_face_term]
    mov esi, [rsp + 32]
    mov edx, [rsp + 28]
    mov ecx, [rsp + 24]
    mov r8, r13
    mov r9, r14
    push r15
    push r15
    call ui_text_v
    add rsp, 16
    jmp 1b
4:  call gfx_clip_pop
    # the wheel scrolls the lines
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call ui_in
    test eax, eax
    jz 9f
    mov eax, [rip + g_scroll_y]
    test eax, eax
    jz 9f
    neg eax                     # pixels, as the terminal takes them
    add eax, [rip + cscroll]
    jns 5f
    xor eax, eax
5:  mov [rip + cscroll], eax
    mov dword ptr [rip + g_scroll_y], 0
9:  EPILOGUE

# cmd_debug_clear_console (Debug: Clear Console, the bin): the console's lines go
FN cmd_debug_clear_console
    sub rsp, 8
    call dcon_clear
    add rsp, 8
    mov dword ptr [rip + cscroll], 0
    mov dword ptr [rip + g_dirty], 1
    ret

# console_actions(ctx, right, y, h) -> eax the x left of its button: Clear, on the console tab's row
.equ ID_DCON_CLEAR, 0x5e0005
console_actions:
    PROLOGUE 16
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    M ecx, MI_24
    sub r12d, ecx
    mov [rsp], ecx
    mov edi, ID_DCON_CLEAR
    mov esi, r12d
    mov edx, r14d
    sub edx, ecx
    sar edx, 1
    add edx, r13d
    mov [rsp + 4], edx
    mov r8d, ecx
    mov r9d, IC_DBG_TRASH
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_DCON_CLEAR
    mov esi, r12d
    mov edx, [rsp + 4]
    add edx, [rsp]
    mov ecx, [rsp]
    lea r9, [rip + .Ltw_clear]
    call tip_note_text
    test eax, UB_CLICK
    jz 1f
    call cmd_debug_clear_console
1:  mov eax, r12d
    EPILOGUE

# cat_color(category) -> eax argb
cat_color:
    lea rax, [rip + cat_slots]
    cmp edi, DCON_RESULT
    jbe 1f
    xor edi, edi
1:  movzx ecx, byte ptr [rax + rdi]
    lea rax, [rip + g_theme]
    mov eax, [rax + rcx*4]
    ret

# dview_console_field() -> rax the Debug Console's input field when the console has the keyboard,
#   else 0 (focused_field: paste and the clipboard reach it)
FN dview_console_field
    sub rsp, 8
    call place_focused
    add rsp, 8
    cmp dword ptr [rip + g_dv_places + 16], 0
    jl 1f                       # the console was never made
    cmp eax, [rip + g_dv_places + 16]
    jne 1f
    lea rax, [rip + cin]
    ret
1:  jmp dview_tw_field          # the Debug tab's field, or 0

# console_key(ctx, keysym, cp, mods) -> eax: the input line; Enter evaluates, Up/Down history
console_key:
    PROLOGUE
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    cmp r12d, KEY_RETURN
    je 1f
    cmp r12d, KEY_KP_ENTER
    je 1f
    cmp r12d, KEY_UP
    je 2f
    cmp r12d, KEY_DOWN
    je 3f
    lea rdi, [rip + cin]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE                    # what the field did not take (F5, F10, Escape) goes on to the keys
1:  lea rdi, [rip + cin]
    call tf_text
    test rdx, rdx
    jz 8f
    mov rbx, rax
    mov r15, rdx
    mov rdi, rbx
    mov rsi, r15
    call history_add
    lea rdi, [rip + cin]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call dap_eval
    lea rdi, [rip + cin]
    call tf_clear
    mov dword ptr [rip + hist_at], -1
    mov dword ptr [rip + cscroll], 0
    jmp 8f
2:  mov edi, 1
    call history_move
    jmp 8f
3:  mov edi, -1
    call history_move
8:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE

# history_add(ptr, len): an entry (newline-free), the oldest dropped past 100
history_add:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + history]
    mov rsi, r12
    mov rdx, r13
    call sb_push_clean_bp
    lea rdi, [rip + history]
    mov esi, 10
    call sb_push_byte
    # count
    mov rdi, [rip + history + SB_ptr]
    mov rsi, [rip + history + SB_len]
    xor ecx, ecx
    xor edx, edx
1:  cmp rcx, rsi
    jae 2f
    cmp byte ptr [rdi + rcx], 10
    jne 11f
    inc edx
11: inc rcx
    jmp 1b
2:  cmp edx, DV_HISTORY_MAX
    jbe 9f
    xor ecx, ecx
3:  cmp byte ptr [rdi + rcx], 10
    je 4f
    inc rcx
    jmp 3b
4:  inc rcx
    sub rsi, rcx
    mov [rip + history + SB_len], rsi
    mov rdx, rsi
    lea rsi, [rdi + rcx]
    call memmove
9:  EPILOGUE

# history_move(dir): Up (1) the older entry, Down (-1) the newer one, into the input line
history_move:
    PROLOGUE
    mov ebx, edi
    # entries
    mov rdi, [rip + history + SB_ptr]
    mov rsi, [rip + history + SB_len]
    xor ecx, ecx
    xor r12d, r12d
1:  cmp rcx, rsi
    jae 2f
    cmp byte ptr [rdi + rcx], 10
    jne 11f
    inc r12d
11: inc rcx
    jmp 1b
2:  test r12d, r12d
    jz 9f
    mov eax, [rip + hist_at]
    cmp eax, -1
    jne 3f
    mov eax, r12d               # one past the newest
3:  sub eax, ebx
    js 9f
    cmp eax, r12d
    jb 4f
    mov dword ptr [rip + hist_at], -1
    lea rdi, [rip + cin]
    call tf_clear
    jmp 9f
4:  mov [rip + hist_at], eax
    # entry eax
    mov rdi, [rip + history + SB_ptr]
    xor ecx, ecx
5:  test eax, eax
    jz 6f
    cmp byte ptr [rdi + rcx], 10
    jne 51f
    dec eax
51: inc rcx
    jmp 5b
6:  lea rsi, [rdi + rcx]
    xor edx, edx
7:  cmp byte ptr [rsi + rdx], 10
    je 8f
    inc rdx
    jmp 7b
8:  lea rdi, [rip + cin]
    call tf_set
9:  EPILOGUE

# ---------------- prompts ----------------

# dview_ask_launch(label cstr): the text prompt for a launch's ${ask:PROMPT} (debugask.s)
FN dview_ask_launch
    mov rsi, rdi
    mov edi, DP_LAUNCH
    xor edx, edx
    jmp ask

# ask(kind, label cstr, initial cstr or 0): the palette's text prompt for the debugger
ask:
    PROLOGUE
    mov [rip + prompt_kind], edi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    mov esi, PROMPT_DEBUG
    call prompt_open
    test r13, r13
    jnz 1f
    call palette_field
    mov rdi, rax
    call tf_clear
    jmp 9f
1:  call palette_field
    mov r14, rax
    mov rdi, r13
    call strlen
    mov rdx, rax
    mov rdi, r14
    mov rsi, r13
    call tf_set
9:  EPILOGUE

# dview_prompt_done(ptr, len): the palette's prompt for the debugger was accepted
FN dview_prompt_done
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + lab]
    mov rsi, r12
    mov rdx, r13
    call sb_set
    mov eax, [rip + prompt_kind]
    mov dword ptr [rip + prompt_kind], 0
    cmp eax, DP_LAUNCH
    jne 10f
    mov rdi, r12
    mov rsi, r13
    call dask_answer
    jmp 9f
10: cmp eax, DP_SETVAR
    jne 11f
    mov edi, [rip + prompt_var_sid]
    call dap_slot_of_id
    test rax, rax
    jz 9f
    mov ecx, [rax + DS_vgen]
    cmp ecx, [rip + prompt_var_gen]
    jne 9f                      # it stopped elsewhere meanwhile: that variable is gone
    mov rdi, rax
    mov esi, [rip + prompt_var]
    mov rdx, r12
    mov rcx, r13
    call dap_set_variable
    jmp 9f
11: cmp eax, DP_EVAL
    jne 12f
    mov rdi, r12
    mov rsi, r13
    call dview_eval
    jmp 9f
12: cmp eax, DP_WATCH
    jne 1f
    mov rdi, r12
    mov rsi, r13
    call eval_promote           # the evaluation's text: kept as a watch now
    test eax, eax
    jnz 9f
    mov rdi, r12
    mov rsi, r13
    call dap_watch_add
    call bp_save_soon
    jmp 9f
1:  cmp eax, DP_FUNCTION
    jne 2f
    test r13, r13
    jz 9f
    mov rdi, [rip + lab + SB_ptr]
    xor esi, esi
    call bp_function
    jmp 9f
2:  # a breakpoint's condition, hit count or log message: empty removes it
    mov ebx, eax
    mov rdi, [rip + prompt_path + SB_ptr]
    test rdi, rdi
    jz 9f
    mov esi, [rip + prompt_bp]
    call bp_find
    test eax, eax
    jns 3f
    mov rdi, [rip + prompt_path + SB_ptr]
    mov esi, [rip + prompt_bp]
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call bp_set
    test eax, eax
    js 9f
3:  mov edi, eax
    mov esi, ebx
    mov rdx, [rip + lab + SB_ptr]
    call bp_set_option
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# prompt_on_line(kind, label, option offset): asks for a breakpoint option on the cursor's line
prompt_on_line:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
    call cursor_line
    test eax, eax
    jz 9f
    mov [rip + prompt_bp], eax
    xor r14d, r14d              # initial text
    mov rdi, [rip + prompt_path + SB_ptr]
    mov esi, eax
    call bp_find
    test eax, eax
    js 1f
    mov edi, eax
    call bp_row
    mov r14, [rax + r13]
1:  mov edi, ebx
    mov rsi, r12
    mov rdx, r14
    call ask
9:  EPILOGUE

# cursor_line() -> eax the active document's cursor line (one-based) with prompt_path its path, or
#   0 without a file
cursor_line:
    PROLOGUE
    mov eax, [rip + menu_line]
    test eax, eax
    jz 1f
    mov dword ptr [rip + menu_line], 0     # the gutter menu's line (prompt_path is set)
    EPILOGUE
1:  mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 8f
    mov rsi, [rbx + DOC_path]
    test rsi, rsi
    jz 8f
    lea rdi, [rip + prompt_path]
    call sb_setc
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_line_of
    inc eax
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# sb_setc(sb, cstr): exactly the cstr, NUL-terminated
sb_setc:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rbx + SB_len]
    add rsp, 8
    pop r12
    pop rbx
    ret

# sb_set(sb, ptr, len): exactly these bytes, NUL-terminated
sb_set:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rbx + SB_len]
    pop r13
    pop r12
    pop rbx
    ret

# ---------------- commands ----------------

# dview_bp_menu(doc, line): the gutter's right-click menu for a line (zero-based): add a breakpoint,
#   a conditional one or a logpoint there, or edit, disable or remove the one there
FN dview_bp_menu
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rsi, [rbx + DOC_path]
    test rsi, rsi
    jz 9f
    lea rdi, [rip + prompt_path]
    call sb_setc
    lea eax, [r12 + 1]
    mov [rip + menu_target], eax
    mov rdi, [rip + prompt_path + SB_ptr]
    mov esi, eax
    call bp_find
    lea rdi, [rip + menu_add]
    test eax, eax
    js 1f
    lea rdi, [rip + menu_edit]
1:  mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call ctx_menu_open
9:  EPILOGUE

# the menu's items: each acts on the menu's line (menu_line is consumed by cursor_line)
mi_target:
    mov eax, [rip + menu_target]
    mov [rip + menu_line], eax
    ret
mi_add:
    call mi_target
    jmp cmd_debug_toggle_breakpoint
mi_condition:
    call mi_target
    jmp cmd_debug_condition
mi_hit:
    call mi_target
    jmp cmd_debug_hit_count
mi_log:
    call mi_target
    jmp cmd_debug_logpoint
mi_disable:
    call mi_target
    jmp cmd_debug_disable_breakpoint
mi_remove:
    call mi_target
    jmp cmd_debug_toggle_breakpoint

mi_rtc:
    call mi_target
    jmp cmd_debug_run_to_cursor

# cmd_debug_run_to_cursor (Run to Cursor, Alt+F9 in JetBrains IDEs): the focused paused session runs
#   on to the cursor's line. A breakpoint is put there for the time it takes, unless one is there
#   already, and goes again at the next stop (that one or another) or when the session ends.
FN cmd_debug_run_to_cursor
    PROLOGUE
    call dap_focused
    test rax, rax
    jz 9f
    cmp dword ptr [rax + DS_state], DSS_PAUSED
    jne 9f
    call dview_rtc_clear
    call cursor_line
    test eax, eax
    jz 9f
    mov r12d, eax
    mov rdi, [rip + prompt_path + SB_ptr]
    mov esi, r12d
    call bp_find
    test eax, eax
    jns 1f                      # a breakpoint is there: it stops there anyway
    mov rdi, [rip + prompt_path + SB_ptr]
    mov esi, r12d
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call bp_set
    lea rdi, [rip + rtc_path]
    mov rsi, [rip + prompt_path + SB_ptr]
    mov rdx, [rip + prompt_path + SB_len]
    call sb_set
    mov [rip + rtc_line], r12d
    mov dword ptr [rip + rtc_on], 1
1:  xor edi, edi                # continue (the breakpoint reaches the adapter first)
    call dap_resume
9:  EPILOGUE

# dview_rtc_clear(): Run to Cursor's breakpoint goes (a stop, a session's end, another Run to Cursor)
FN dview_rtc_clear
    PROLOGUE
    cmp dword ptr [rip + rtc_on], 0
    je 9f
    mov dword ptr [rip + rtc_on], 0
    mov rdi, [rip + rtc_path + SB_ptr]
    mov esi, [rip + rtc_line]
    call bp_find
    test eax, eax
    js 9f
    mov edi, eax
    call bp_remove
9:  EPILOGUE

# cmd_debug_start (F5): continue the focused paused session, else start the selected configuration
#   (the first in launch.ini until one is selected)
FN cmd_debug_start
    PROLOGUE
    call dap_focused
    test rax, rax
    jz 1f
    cmp dword ptr [rax + DS_state], DSS_PAUSED
    jne 1f
    xor edi, edi
    call dap_resume
    EPILOGUE
1:  xor edi, edi
    call start_selected
    EPILOGUE

# cmd_debug_run (Ctrl+F5): the selected configuration without debugging
FN cmd_debug_run
    mov edi, 1
    jmp start_selected

# start_selected(nodebug)
start_selected:
    PROLOGUE
    mov ebx, edi
    # the selection stands while launch.ini (this project's) still has it
    lea rdi, [rip + lab]
    call sb_clear
    lea rdi, [rip + lab]
    call dcfg_names
    mov r12, [rip + g_dsel + SB_len]
    test r12, r12
    jz 4f
    mov r13, [rip + lab + SB_ptr]
    mov r14, r13
    add r14, [rip + lab + SB_len]
5:  cmp r13, r14
    jae 4f                      # gone: the first one instead
    mov rcx, r13
51: cmp byte ptr [rcx], 10
    je 52f
    inc rcx
    jmp 51b
52: mov r15, rcx
    sub rcx, r13
    cmp rcx, r12
    jne 53f
    mov rdi, r13
    mov rsi, [rip + g_dsel + SB_ptr]
    mov rdx, r12
    call memeq
    test eax, eax
    jnz 2f
53: lea r13, [r15 + 1]
    jmp 5b
4:  # the first configuration
    mov rsi, [rip + lab + SB_ptr]
    mov rcx, [rip + lab + SB_len]
    test rcx, rcx
    jz 3f
    xor edx, edx
1:  cmp byte ptr [rsi + rdx], 10
    je 11f
    inc rdx
    jmp 1b
11: lea rdi, [rip + g_dsel]
    call sb_set
2:  mov rdi, [rip + g_dsel + SB_ptr]
    mov rsi, [rip + g_dsel + SB_len]
    mov edx, ebx
    call dap_start
    EPILOGUE
3:  # no launch.ini: dap_start says so
    lea rdi, [rip + .Lnone]
    xor esi, esi
    mov edx, ebx
    call dap_start
    EPILOGUE

FN cmd_debug_stop
    jmp dap_stop

FN cmd_debug_pause
    jmp dap_pause

FN cmd_debug_step_over
    mov edi, 1
    jmp dap_resume
FN cmd_debug_step_into
    mov edi, 2
    jmp dap_resume
FN cmd_debug_step_out
    mov edi, 3
    jmp dap_resume
FN cmd_debug_continue
    xor edi, edi
    jmp dap_resume

# cmd_debug_restart: Stop, then the same configuration again once it ended
FN cmd_debug_restart
    jmp dap_restart

FN cmd_debug_show
    jmp dview_show

# cmd_debug_toggle_breakpoint (F9): on the cursor's line
FN cmd_debug_toggle_breakpoint
    PROLOGUE
    call cursor_line
    test eax, eax
    jz 9f
    mov rdi, [rip + prompt_path + SB_ptr]
    mov esi, eax
    call bp_toggle
9:  EPILOGUE

FN cmd_debug_condition
    mov edi, DP_COND
    lea rsi, [rip + .Lq_cond]
    mov edx, BP_cond
    jmp prompt_on_line
FN cmd_debug_hit_count
    mov edi, DP_HIT
    lea rsi, [rip + .Lq_hit]
    mov edx, BP_hit
    jmp prompt_on_line
FN cmd_debug_logpoint
    mov edi, DP_LOG
    lea rsi, [rip + .Lq_log]
    mov edx, BP_log
    jmp prompt_on_line

# cmd_debug_disable_breakpoint: the cursor line's breakpoint on or off
FN cmd_debug_disable_breakpoint
    PROLOGUE
    call cursor_line
    test eax, eax
    jz 9f
    mov rdi, [rip + prompt_path + SB_ptr]
    mov esi, eax
    call bp_find
    test eax, eax
    js 9f
    mov ebx, eax
    mov edi, eax
    call bp_row
    mov esi, [rax + BP_enabled]
    xor esi, 1
    mov edi, ebx
    call bp_enable
9:  EPILOGUE

FN cmd_debug_remove_all_breakpoints
    jmp bp_clear_all

FN cmd_debug_add_function_breakpoint
    mov edi, DP_FUNCTION
    lea rsi, [rip + .Lq_function]
    xor edx, edx
    jmp ask

FN cmd_debug_add_watch
    mov edi, DP_WATCH
    lea rsi, [rip + .Lq_watch]
    xor edx, edx
    jmp ask

# cmd_debug_evaluate_selection: the selection (or the word at the cursor) into the console
FN cmd_debug_evaluate_selection
    PROLOGUE
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov r12, [rbx + DOC_cur]
    mov r13, [rbx + DOC_anchor]
    cmp r12, r13
    jbe 1f
    xchg r12, r13
1:  mov r14, r13
    sub r14, r12
    jz 9f
    cmp r14, 4096
    ja 9f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call doc_range
    mov rdi, rax
    mov rsi, r14
    call dap_eval
9:  EPILOGUE

FN cmd_debug_focus_console
    PROLOGUE
    call dview_ensure
    cmp dword ptr [rip + g_debug_layout], 0
    je 1f
    mov dword ptr [rip + tw_sub], 1     # the Debug tab's Console
    mov edi, [rip + g_dv_places + 20]
    mov esi, 1
    call place_show
    EPILOGUE
1:  mov edi, [rip + g_dv_places + 16]
    mov esi, 1
    call place_show
    EPILOGUE

# cmd_debug_open_configurations: PROJECT/.rhun/launch.ini in a tab (created with a template comment)
FN cmd_debug_open_configurations
    PROLOGUE
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 9f
    lea rdi, [rip + lab]
    call sb_setc
    lea rdi, [rip + lab]
    lea rsi, [rip + .Lf_launch]
    call sb_push_cstr
    lea rdi, [rip + lab]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + lab + SB_ptr]
    call vfs_missing            # the host's in a remote window
    test eax, eax
    jz 1f
    mov rdi, [rip + lab + SB_ptr]
    call vfs_mkdir_parent
    mov rdi, [rip + lab + SB_ptr]
    lea rsi, [rip + .Ltemplate]
    mov edx, .Ltemplate_end - .Ltemplate
    call vfs_write_all
1:  mov rdi, [rip + lab + SB_ptr]
    call app_open_file
9:  EPILOGUE


# ---------------- the configuration picker and Add Configuration ----------------

# dview_dpick_chosen(row): the debugger's pick list chose a row: a launch's question (debugask.s), a
#   configuration (Select Configuration) or a template (Add Configuration)
FN dview_dpick_chosen
    mov eax, [rip + g_dpick_kind]
    mov dword ptr [rip + g_dpick_kind], 0
    cmp eax, 1
    je dask_chosen
    cmp eax, 2
    je select_chosen
    cmp eax, 3
    je addcfg_chosen
    ret

# cmd_debug_select_configuration: launch.ini's configurations; the one chosen is what F5 starts
FN cmd_debug_select_configuration
    PROLOGUE
    lea rdi, [rip + pickb]
    call sb_clear
    lea rdi, [rip + pickb]
    call dcfg_names
    mov dword ptr [rip + g_dpick_kind], 2
    lea rdi, [rip + .Lp_select]
    call palette_dpick_open
    mov r12, [rip + pickb + SB_ptr]
    mov r14, r12
    add r14, [rip + pickb + SB_len]
    xor ebx, ebx
1:  cmp r12, r14
    jae 3f
    mov r13, r12
2:  cmp byte ptr [r13], 10
    je 21f
    inc r13
    jmp 2b
21: mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    mov edx, ebx
    call palette_choose_add
    inc ebx
    lea r12, [r13 + 1]
    jmp 1b
3:  call palette_choose_ready
    EPILOGUE

# select_chosen(row): that configuration is the selected one
select_chosen:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rip + pickb + SB_ptr]
    mov r14, r12
    add r14, [rip + pickb + SB_len]
1:  cmp r12, r14
    jae 9f
    mov r13, r12
2:  cmp byte ptr [r13], 10
    je 3f
    inc r13
    jmp 2b
3:  test rbx, rbx
    jz 4f
    dec rbx
    lea r12, [r13 + 1]
    jmp 1b
4:  lea rdi, [rip + g_dsel]
    mov rsi, r12
    mov rdx, r13
    sub rdx, r12
    call sb_set
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# cmd_debug_add_configuration: every installed debugger's templates (launch.ini sections in its
#   extension's folder); the one chosen is appended to PROJECT/.rhun/launch.ini, which opens
FN cmd_debug_add_configuration
    PROLOGUE 16
    cmp qword ptr [rip + g_project], 0
    je 9f
    lea rdi, [rip + tplb]
    call sb_clear
    lea rdi, [rip + tplidx]
    call sb_clear
    lea rdi, [rip + tpllab]
    call sb_clear
    mov dword ptr [rip + g_dpick_kind], 3
    lea rdi, [rip + .Lp_add]
    call palette_dpick_open
    xor ebx, ebx                # debugger
    xor r15d, r15d              # rows
1:  cmp ebx, [rip + g_ndebuggers]
    jae 8f
    mov edi, ebx
    call dbg_live
    test eax, eax
    jz 7f
    mov edi, ebx
    call dbg_row
    mov r12, rax
    mov r13, [r12 + DBG_templates]
    test r13, r13
    jz 7f
2:  # each file named
    movzx eax, byte ptr [r13]
    test eax, eax
    jz 7f
    cmp eax, ' '
    jne 3f
    inc r13
    jmp 2b
3:  mov r14, r13
31: movzx eax, byte ptr [r13]
    test eax, eax
    jz 32f
    cmp eax, ' '
    je 32f
    inc r13
    jmp 31b
32: lea rdi, [rip + pathb_dv]
    mov rax, [r12 + DBG_ext]
    mov rdi, [rax + EXT_dir]
    lea rsi, [rip + pathb_dv]
    xchg rdi, rsi
    call sb_setc
    lea rdi, [rip + pathb_dv]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + pathb_dv]
    mov rsi, r14
    mov rdx, r13
    sub rdx, r14
    call sb_push
    lea rdi, [rip + pathb_dv]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + pathb_dv + SB_ptr]
    mov esi, 65536
    call file_read_limited
    test rax, rax
    jz 2b
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rsp + 8]
    mov ecx, r15d
    call tpl_sections
    add r15d, eax
    mov rdi, [rsp]
    call mem_free
    jmp 2b
7:  inc ebx
    jmp 1b
8:  # the rows, one per label line
    mov r12, [rip + tpllab + SB_ptr]
    mov r14, r12
    add r14, [rip + tpllab + SB_len]
    xor ebx, ebx
81: cmp r12, r14
    jae 83f
    mov r13, r12
82: cmp byte ptr [r13], 10
    je 84f
    inc r13
    jmp 82b
84: mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    mov edx, ebx
    call palette_choose_add
    inc ebx
    lea r12, [r13 + 1]
    jmp 81b
83: call palette_choose_ready
9:  EPILOGUE

# tpl_sections(DBG*, text, len, first row) -> eax the rows added: each [Section] of a template, its
#   text kept in tplb and (start, end) in tplidx, offered as "TITLE: Section"
tpl_sections:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rsi + rdx]
    mov [rsp], ecx              # the next row
    xor r15d, r15d              # added
    mov qword ptr [rsp + 8], -1 # the open section's start in tplb
1:  cmp r12, r13
    jae 8f
    mov r14, r12                # this line
2:  cmp r12, r13
    jae 3f
    cmp byte ptr [r12], 10
    je 3f
    inc r12
    jmp 2b
3:  # a section header starts the next entry
    cmp byte ptr [r14], '['
    jne 5f
    call tpl_close
    mov rax, [rip + tplb + SB_len]
    mov [rsp + 8], rax
    # its row: TITLE: NAME
    lea rdi, [rip + lab]
    mov rsi, [rbx + DBG_title]
    test rsi, rsi
    jnz 4f
    mov rsi, [rbx + DBG_type]
4:  call sb_setc
    lea rdi, [rip + lab]
    lea rsi, [rip + .Lcolon_sp]
    call sb_push_cstr
    lea rsi, [r14 + 1]
    mov rdx, r12
    sub rdx, rsi
    jz 41f
    cmp byte ptr [rsi + rdx - 1], ']'
    jne 41f
    dec rdx
41: lea rdi, [rip + lab]
    call sb_push
    # its label kept (the list's rows point into tpllab, so they are added once it is complete)
    lea rdi, [rip + tpllab]
    mov rsi, [rip + lab + SB_ptr]
    mov rdx, [rip + lab + SB_len]
    call sb_push
    lea rdi, [rip + tpllab]
    mov esi, 10
    call sb_push_byte
    inc r15d
5:  cmp qword ptr [rsp + 8], 0
    jl 6f                       # before the first section: comments
    lea rdi, [rip + tplb]
    mov rsi, r14
    mov rdx, r12
    sub rdx, r14
    call sb_push
    lea rdi, [rip + tplb]
    mov esi, 10
    call sb_push_byte
6:  inc r12
    jmp 1b
8:  call tpl_close
    mov eax, r15d
    EPILOGUE
# tpl_close: the open section (start at [rsp + 8] of tpl_sections' frame) ends: its range kept
tpl_close:
    mov rax, [rsp + 8 + 8]
    test rax, rax
    js 1f
    push rax
    push rax
    lea rdi, [rip + tplidx]
    lea rsi, [rsp]
    mov edx, 8
    call sb_push
    pop rax
    pop rax
    mov rax, [rip + tplb + SB_len]
    push rax
    push rax
    lea rdi, [rip + tplidx]
    lea rsi, [rsp]
    mov edx, 8
    call sb_push
    pop rax
    pop rax
1:  ret

# addcfg_chosen(row): that template's section appended to launch.ini (made when missing), the file
#   open, the section the selected configuration
addcfg_chosen:
    PROLOGUE 32
    mov rax, rdi
    shl rax, 4
    cmp rax, [rip + tplidx + SB_len]
    jae 9f
    add rax, [rip + tplidx + SB_ptr]
    mov rcx, [rax]
    mov rdx, [rax + 8]
    mov [rsp], rcx
    mov [rsp + 8], rdx
    # the file's text so far, or the header
    mov rsi, [rip + g_project]
    lea rdi, [rip + lab]
    call sb_setc
    lea rdi, [rip + lab]
    lea rsi, [rip + .Lf_launch]
    call sb_push_cstr
    lea rdi, [rip + lab]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rip + pickb]
    call sb_clear
    # the project's file: the host's in a remote window
    mov rdi, [rip + lab + SB_ptr]
    mov esi, 1048576
    call vfs_read_limited
    test rax, rax
    jz 1f
    mov r12, rax
    lea rdi, [rip + pickb]
    mov rsi, rax
    call sb_push
    mov rdi, r12
    call mem_free
    jmp 2f
1:  cmp rdx, -2                 # ENOENT: a new file; any other failure leaves it as it is
    je 11f
    lea rdi, [rip + .Lm_cfg_unread]
    call dap_error
    EPILOGUE
11: mov rdi, [rip + lab + SB_ptr]
    call vfs_mkdir_parent
    lea rdi, [rip + pickb]
    lea rsi, [rip + .Ltemplate]
    mov edx, .Ltemplate_end - .Ltemplate
    call sb_push
2:  # a blank line, then the section
    mov rax, [rip + pickb + SB_len]
    test rax, rax
    jz 3f
    mov rcx, [rip + pickb + SB_ptr]
    cmp byte ptr [rcx + rax - 1], 10
    je 21f
    lea rdi, [rip + pickb]
    mov esi, 10
    call sb_push_byte
21: lea rdi, [rip + pickb]
    mov esi, 10
    call sb_push_byte
3:  mov rsi, [rip + tplb + SB_ptr]
    add rsi, [rsp]
    mov rdx, [rsp + 8]
    sub rdx, [rsp]
    lea rdi, [rip + pickb]
    call sb_push
    mov rdi, [rip + lab + SB_ptr]
    mov rsi, [rip + pickb + SB_ptr]
    mov rdx, [rip + pickb + SB_len]
    call vfs_write_all
    test rax, rax
    jz 31f
    lea rdi, [rip + .Lm_cfg_unwritten]
    call dap_error
    EPILOGUE
31: # the section's name becomes the selection
    mov rsi, [rip + tplb + SB_ptr]
    add rsi, [rsp]
    inc rsi                     # after [
    mov rdx, rsi
4:  cmp byte ptr [rdx], ']'
    je 5f
    cmp byte ptr [rdx], 10
    je 5f
    inc rdx
    jmp 4b
5:  sub rdx, rsi
    lea rdi, [rip + g_dsel]
    call sb_set
    mov rdi, [rip + lab + SB_ptr]
    call app_open_file
9:  EPILOGUE

# ---------------- the title bar's toolbar and the status bar's item ----------------

.equ ID_DBG_TB, 0x5e0100        # + button

# dview_toolbar(left, y, width, h, right) -> eax 1 when the toolbar took the title's place: a session
#   picker (with more than one session), Continue or Pause, Step Over, Into and Out, Restart, Stop;
#   a session without debugging has Restart and Stop only. With [debug] layout = toolwindow the
#   Debugger tab has them instead.
FN dview_toolbar
    PROLOGUE 64
    mov dword ptr [rip + tb_n], 0
    mov [rsp], edi              # left limit
    mov [rsp + 4], esi          # y
    mov [rsp + 8], edx          # the title bar's width
    mov [rsp + 12], ecx         # h
    mov [rsp + 16], r8d         # right limit
    cmp dword ptr [rip + g_debug_layout], 0
    jne 8f                      # the Debugger tab has the buttons
    call dap_focused
    test rax, rax
    jz 8f
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_ENDED
    je 8f
    # the buttons for this session
    lea r12, [rip + tb_debug]
    cmp dword ptr [rbx + DS_nodebug], 0
    je 1f
    lea r12, [rip + tb_nodebug]
1:  xor r13d, r13d              # count
2:  cmp qword ptr [r12 + r13*8], 0
    je 3f
    inc r13d
    jmp 2b
3:  M eax, MI_28
    mov [rsp + 20], eax         # button size
    M ecx, MI_2
    add eax, ecx
    imul eax, r13d
    mov [rsp + 24], eax         # buttons' width
    # the picker: the session's name, when there are several
    mov dword ptr [rsp + 28], 0
    call dap_live_count
    cmp eax, 1
    jbe 4f
    mov rsi, [rbx + DS_name]
    test rsi, rsi
    jz 4f
    mov rdi, rsi
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, [rbx + DS_name]
    mov rdx, rax
    call text_width
    M ecx, MI_16
    add eax, ecx
    mov [rsp + 28], eax
4:  mov eax, [rsp + 24]
    add eax, [rsp + 28]
    mov [rsp + 32], eax         # total
    mov ecx, [rsp + 8]
    sub ecx, eax
    sar ecx, 1                  # centered
    cmp ecx, [rsp]
    jge 41f
    mov ecx, [rsp]
41: mov edx, ecx
    add edx, eax
    cmp edx, [rsp + 16]
    jle 42f
    mov ecx, [rsp + 16]         # off center, left of what is at the right (the run widget)
    sub ecx, eax
    cmp ecx, [rsp]
    jl 8f                       # no room: the title stays
42: mov r14d, ecx               # x
    # the picker cycles the focused session
    cmp dword ptr [rsp + 28], 0
    je 5f
    mov edi, ID_DBG_TB + 15
    mov esi, r14d
    mov edx, [rsp + 4]
    mov ecx, [rsp + 28]
    mov r8d, [rsp + 12]
    call ui_btn
    mov r15d, eax
    lea rdi, [rip + g_face_small]
    mov esi, r14d
    M eax, MI_8
    add esi, eax
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, [rbx + DS_name]
    COLOR r9d, T_FG
    call ui_text_c
    test r15d, UB_CLICK
    jz 42f
    call focus_next_session
42: add r14d, [rsp + 28]
5:  xor r15d, r15d
6:  cmp r15d, r13d
    jae 7f
    mov rax, [r12 + r15*8]      # the button's entry: icon, command, tooltip
    mov [rsp + 40], rax
    mov eax, [rax]              # icon
    # Continue becomes Pause while the program runs
    cmp eax, IC_DBG_RESUME
    jne 61f
    cmp dword ptr [rbx + DS_state], DSS_RUNNING
    jne 61f
    lea rcx, [rip + tbe_pause]
    mov [rsp + 40], rcx
    mov eax, IC_DBG_PAUSE
61: lea edi, [r15 + ID_DBG_TB]
    mov esi, r14d
    mov edx, [rsp + 12]
    sub edx, [rsp + 20]
    sar edx, 1
    add edx, [rsp + 4]
    mov [rsp + 36], edx
    mov ecx, [rsp + 20]
    mov r8d, [rsp + 20]
    mov r9d, eax
    # where it is, for tests (print-debug-toolbar)
    push rax
    push rdx
    mov ecx, [rip + tb_n]
    cmp ecx, 8
    jae 63f
    inc dword ptr [rip + tb_n]
    shl ecx, 4
    lea r8, [rip + tb_rects]
    mov [r8 + rcx], eax
    mov [r8 + rcx + 4], r14d
    mov [r8 + rcx + 8], edx
    mov eax, [rsp + 16 + 20]
    mov [r8 + rcx + 12], eax
63: pop rdx
    pop rax
    mov ecx, [rsp + 20]
    mov r8d, [rsp + 20]
    mov r9d, eax
    call ui_icon_btn
    mov r8d, eax
    lea edi, [r15 + ID_DBG_TB]
    mov esi, r14d
    mov edx, [rsp + 36]
    add edx, [rsp + 20]
    mov ecx, [rsp + 20]
    mov rax, [rsp + 40]
    mov r9, [rax + 16]
    call tip_note_text
    test eax, UB_CLICK
    jz 62f
    mov rax, [rsp + 40]
    call [rax + 8]
62: add r14d, [rsp + 20]
    M eax, MI_2
    add r14d, eax
    inc r15d
    jmp 6b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# dview_toolbar_dump(sb): "button ICON x y size" for each toolbar button as last drawn, then the run
#   widget's "widget ICON x y w" lines
FN dview_toolbar_dump
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12d, [rip + tb_n]
    jae 9f
    mov r13d, r12d
    shl r13d, 4
    lea r14, [rip + tb_rects]
    add r14, r13
    mov rdi, rbx
    lea rsi, [rip + .Lbutton]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r14]
    call sb_push_u64
    xor r15d, r15d
2:  mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r14 + 4 + r15*4]
    call sb_push_u64
    inc r15d
    cmp r15d, 3
    jb 2b
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r12d
    jmp 1b
9:  mov rdi, rbx                # and the run widget's parts, and the Debugger tab's
    call dview_run_widget_dump
    mov rdi, rbx
    call dview_tw_dump
    EPILOGUE

# focus_next_session(): the toolbar's picker: the next live session is focused
focus_next_session:
    PROLOGUE
    mov ebx, [rip + g_dfocus]
    mov r12d, DS_MAX
1:  inc ebx
    cmp ebx, DS_MAX
    jb 2f
    xor ebx, ebx
2:  mov edi, ebx
    call dap_slot
    mov ecx, [rax + DS_state]
    test ecx, ecx
    jz 3f
    cmp ecx, DSS_ENDED
    je 3f
    mov edi, ebx
    call dap_focus_slot
    EPILOGUE
3:  dec r12d
    jnz 1b
    EPILOGUE

# dview_status_item(x, y, h) -> eax the x after it: the focused session's state ("Run: paused
#   (breakpoint) a.c:3"), else "▶ CONFIG" for the configuration F5 starts; a click shows the debug view,
#   or starts it
.equ ID_DBG_STATUS, 0x5e0110
FN dview_status_item
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov ebx, edi
    call rw_starting            # a session getting ready: its progress
    test rax, rax
    jz 0f
    mov rcx, rax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    call rw_progress
    EPILOGUE
0:  mov edi, 1
    call status_label
    test eax, eax
    jz 9f
7:  lea rdi, [rip + lab]
    call sb_z_dv
    lea rdi, [rip + g_face_small]
    mov rsi, rax
    mov rdx, [rip + lab + SB_len]
    call text_width
    M ecx, MI_16
    add eax, ecx
    mov r14d, eax               # its width
    mov edi, ID_DBG_STATUS
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, r14d
    mov r8d, [rsp + 8]
    call ui_btn
    mov r15d, eax
    test eax, UB_HOVER
    jz 71f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, r14d
    mov ecx, [rsp + 8]
    COLOR r8d, T_HOVER
    call gfx_fill
71: lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    M eax, MI_8
    add esi, eax
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8, [rip + lab + SB_ptr]
    COLOR r9d, T_ACCENT
    call ui_text_c
    test r15d, UB_CLICK
    jz 8f
    call dap_focused
    test rax, rax
    jz 72f
    call dview_show_on
    jmp 8f
72: call cmd_debug_start
8:  mov eax, [rsp]
    add eax, r14d
    EPILOGUE
9:  mov eax, [rsp]
    EPILOGUE

# rw_progress(x, y, h, ds) -> eax the x after it: "Compiling..." (Go: Delve builds the program
#   first) or "Starting...", a bar that moves, and x to stop the session, as JetBrains IDEs show it
.equ ID_DBG_PROG, 0x5e0111
rw_progress:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov rbx, rcx
    lea r12, [rip + .Lw_starting2]
    mov edi, [rbx + DS_dbg]
    call dbg_row
    mov rdi, [rax + DBG_type]
    test rdi, rdi
    jz 1f
    lea rsi, [rip + .Ls_go]
    call strcmp_eq
    test eax, eax
    jz 1f
    lea r12, [rip + .Lw_compiling]
1:  lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8, r12
    COLOR r9d, T_FG
    call ui_text_c
    add eax, [rip + g_mt + 4*MI_8]
    mov r13d, eax               # the bar: 100 points, a third of it moving
    mov edi, 100
    call sc
    mov r14d, eax
    M ecx, MI_4
    mov edx, [rsp + 8]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    mov [rsp + 12], edx
    mov edi, r13d
    mov esi, edx
    mov edx, r14d
    mov r8d, ecx
    sar r8d, 1
    COLOR r9d, T_BORDER
    call gfx_round_rect
    call rw_spin_step           # it moves with the spinner
    mov ecx, r14d
    imul ecx, eax
    shr ecx, 4                  # sixteen steps across
    mov eax, r14d
    xor edx, edx
    mov r8d, 3
    div r8d
    mov r15d, eax               # its length
    lea edi, [r13 + rcx]
    mov edx, r15d
    mov eax, r13d
    add eax, r14d
    sub eax, edi
    cmp edx, eax
    cmovg edx, eax
    mov esi, [rsp + 12]
    M ecx, MI_4
    mov r8d, ecx
    sar r8d, 1
    COLOR r9d, T_ACCENT
    call gfx_round_rect
    add r13d, r14d
    add r13d, [rip + g_mt + 4*MI_6]
    M ecx, MI_16                # x: the session stops
    mov edx, [rsp + 8]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    mov edi, ID_DBG_PROG
    mov esi, r13d
    mov r8d, ecx
    mov r9d, IC_CLOSE
    call ui_icon_btn
    test eax, UB_CLICK
    jz 2f
    mov rdi, rbx
    call slot_of_ds_dv
    mov edi, eax
    call dap_focus_slot
    call dap_stop
2:  add r13d, [rip + g_mt + 4*MI_16]
    add r13d, [rip + g_mt + 4*MI_8]
    mov eax, r13d
    EPILOGUE

# slot_of_ds_dv(ds) -> eax its slot
slot_of_ds_dv:
    xor eax, eax
1:  cmp eax, DS_MAX
    jae 2f
    imul rcx, rax, DS_SIZE
    lea rdx, [rip + g_dsess]
    add rcx, rdx
    cmp rcx, rdi
    je 2f
    inc eax
    jmp 1b
2:  ret

# status_label(fallback) -> eax 1 with lab the focused session's state ("Run: paused (breakpoint)
#   a.c:3"), else with fallback 1 "▶ CONFIG" for the configuration F5 starts; 0 when there is neither
status_label:
    PROLOGUE
    mov ebx, edi
    lea rdi, [rip + lab]
    call sb_clear
    call dap_focused
    test rax, rax
    jz 5f
    mov r12, rax
    mov rsi, [r12 + DS_name]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + lab]
    call sb_push_cstr
    lea rdi, [rip + lab]
    lea rsi, [rip + .Lcolon_sp]
    call sb_push_cstr
1:  mov edi, [r12 + DS_state]
    call status_word
    lea rdi, [rip + lab]
    mov rsi, rax
    call sb_push_cstr
    cmp dword ptr [r12 + DS_state], DSS_PAUSED
    jne 2f
    mov rsi, [r12 + DS_reason]
    test rsi, rsi
    jz 11f
    lea rdi, [rip + lab]
    lea rsi, [rip + .Lparen_open]
    call sb_push_cstr
    lea rdi, [rip + lab]
    mov rsi, [r12 + DS_reason]
    call sb_push_cstr
    lea rdi, [rip + lab]
    mov esi, ')'
    call sb_push_byte
11: mov rdi, r12
    call dap_frame_ptr
    test rax, rax
    jz 2f
    mov r13, rax
    cmp dword ptr [r13 + FR_pathlen], 0
    je 2f
    lea rdi, [rip + lab]
    mov esi, ' '
    call sb_push_byte
    mov ecx, [r13 + FR_path]
    mov rdi, [r12 + DS_strs + SB_ptr]
    add rdi, rcx
    mov esi, [r13 + FR_pathlen]
    call path_basename
    lea rdi, [rip + lab]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + lab]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + lab]
    mov esi, [r13 + FR_line]
    call sb_push_u64
2:  mov eax, 1
    EPILOGUE
5:  xor eax, eax
    test ebx, ebx
    jz 9f
    call status_config  # no session: the configuration F5 starts, when the project has some
9:  EPILOGUE

# status_word(state) -> cstr as the status bar says it
status_word:
    lea rax, [rip + .Lw_starting]
    cmp edi, DSS_RUNNING
    jne 1f
    lea rax, [rip + .Lw_running]
1:  cmp edi, DSS_PAUSED
    jne 2f
    lea rax, [rip + .Lw_paused]
2:  cmp edi, DSS_TERMINATING
    jne 3f
    lea rax, [rip + .Lw_stopping]
3:  cmp edi, DSS_ENDED
    jne 4f
    lea rax, [rip + .Lw_ended]
4:  cmp edi, DSS_APPROVAL
    jne 5f
    lea rax, [rip + .Lw_waiting]
5:  ret

# status_config() -> eax 1 with lab = "▶ CONFIG": the selected configuration, else launch.ini's
#   first (read again at most every 2 s)
status_config:
    PROLOGUE
    mov rsi, [rip + g_dsel + SB_ptr]
    mov rdx, [rip + g_dsel + SB_len]
    test rdx, rdx
    jnz 2f
    mov rsi, [rip + cfg_first + SB_ptr]
    mov rcx, [rip + cfg_first + SB_len]
    test rcx, rcx
    jz 8f
    xor edx, edx
11: cmp byte ptr [rsi + rdx], 10
    je 2f
    inc rdx
    jmp 11b
2:  push rsi
    push rdx
    lea rdi, [rip + lab]
    lea rsi, [rip + .Lplay]
    call sb_push_cstr
    pop rdx
    pop rsi
    lea rdi, [rip + lab]
    call sb_push
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# dview_status_config_dump(sb): "status=LABEL" LF: the configuration the status bar offers (print-configs)
FN dview_status_config_dump
    PROLOGUE
    mov rbx, rdi
    call cfg_refresh
    lea rdi, [rip + lab]
    call sb_clear
    call status_config
    mov rdi, rbx
    lea rsi, [rip + .Ls_status_eq]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + lab + SB_ptr]
    mov rdx, [rip + lab + SB_len]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# cfg_refresh(): launch.ini's names for the status bar, read again only when the project changed or a
#   file was saved in rhun (never from drawing, nor on a timer: in a remote window a read is a round
#   trip to the host)
cfg_refresh:
    PROLOGUE
    # the saves of the open files, summed: no file system access
    xor r12d, r12d
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 2f
    imul rax, rbx, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    mov rax, [rax + TAB_doc]
    test rax, rax
    jz 11f
    add r12, [rax + DOC_saves]
11: inc rbx
    jmp 1b
2:  mov rax, [rip + g_project]
    cmp dword ptr [rip + cfg_checked], 0
    je 3f
    cmp rax, [rip + cfg_proj]
    jne 3f
    cmp r12, [rip + cfg_saves]
    je 9f
3:  mov dword ptr [rip + cfg_checked], 1
    mov [rip + cfg_proj], rax
    mov [rip + cfg_saves], r12
    lea rdi, [rip + cfg_prev]
    lea rsi, [rip + cfg_first]
    call sb_copy_dv
    lea rdi, [rip + cfg_first]
    call sb_clear
    lea rdi, [rip + cfg_first]
    call dcfg_names
    mov rdx, [rip + cfg_first + SB_len]
    cmp rdx, [rip + cfg_prev + SB_len]
    jne 4f
    mov rdi, [rip + cfg_first + SB_ptr]
    mov rsi, [rip + cfg_prev + SB_ptr]
    test rdx, rdx
    jz 9f
    call memeq
    test eax, eax
    jnz 9f
4:  mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# sb_copy_dv(dst, src)
sb_copy_dv:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    call sb_clear
    mov rdi, rbx
    mov rsi, [r12 + SB_ptr]
    mov rdx, [r12 + SB_len]
    call sb_push
    add rsp, 8
    pop r12
    pop rbx
    ret

# sb_z_dv(sb) -> its bytes NUL-terminated
sb_z_dv:
    push rbx
    mov rbx, rdi
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rbx + SB_len]
    mov rax, [rbx + SB_ptr]
    pop rbx
    ret

# dview_show_on(): the debug view shown (not toggled)
FN dview_show_on
    PROLOGUE
    call dview_ensure
    mov dword ptr [rip + dv_shown], 0
    call dview_show
    EPILOGUE

# ---------------- context keys and the terminal ----------------

# dview_context(): debugState, inDebugMode and debugType for when clauses, from the focused session
FN dview_context
    PROLOGUE
    call cfg_refresh
    mov eax, [rip + g_dap_gen]
    cmp eax, [rip + ctx_gen]
    je 9f
    mov [rip + ctx_gen], eax
    lea r12, [rip + .Ls_inactive]
    xor r13d, r13d              # in debug mode
    lea r14, [rip + .Lnone]     # type
    call dap_focused
    test rax, rax
    jz 5f
    mov rbx, rax
    mov eax, [rbx + DS_state]
    cmp eax, DSS_ENDED
    je 5f
    mov r13d, 1
    mov edi, [rbx + DS_dbg]
    call dbg_row
    mov r14, [rax + DBG_type]
    lea r12, [rip + .Ls_initializing]
    mov eax, [rbx + DS_state]
    cmp eax, DSS_RUNNING
    jne 1f
    lea r12, [rip + .Ls_running]
1:  cmp eax, DSS_PAUSED
    jne 5f
    lea r12, [rip + .Ls_stopped]
5:  mov rdi, r12
    call strlen
    mov edi, CTX_DEBUG_STATE
    mov rsi, r12
    mov rdx, rax
    call ctx_set
    mov edi, CTX_IN_DEBUG_MODE
    mov esi, r13d
    call ctx_set_bool
    mov rdi, r14
    call strlen
    mov edi, CTX_DEBUG_TYPE
    mov rsi, r14
    mov rdx, rax
    call ctx_set
9:  EPILOGUE

# dview_terminal_key(keysym, mods) -> eax 1 when the key is the debugger's now: while a session
#   lives, Continue, Pause, Stop, Restart and the steps reach rhun even from the terminal
#   ([debug] keys_in_terminal)
FN dview_terminal_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    cmp dword ptr [rip + g_debug_keys_in_terminal], 0
    je 8f
    call dap_live_count
    test eax, eax
    jz 8f
    mov edi, r12d
    mov esi, r13d
    call keys_lookup
    test rax, rax
    jz 8f
    lea rcx, [rip + term_cmds]
1:  mov rdx, [rcx]
    test rdx, rdx
    jz 8f
    cmp rax, rdx
    je 9f
    add rcx, 8
    jmp 1b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE


# ---------------- the title bar's run widget ----------------

# The run widget at the title bar's right, as JetBrains IDEs have it: the configuration F5 starts (a
# click lists launch.ini's configurations to choose another, Edit Configurations and Add
# Configuration), Run, Debug, and Stop while a session lives. It shows when launch.ini has
# configurations.

.equ ID_DBG_RW, 0x5e0120        # + 0 the configuration, 1 Run, 2 Debug, 3 Stop
.equ RW_MAX, 32                 # the configurations the menu lists

# rw_name() -> eax 1 with rwlab the configuration F5 starts (the selected one, else launch.ini's
#   first), 0 when launch.ini has none
rw_name:
    PROLOGUE
    cmp qword ptr [rip + cfg_first + SB_len], 0
    je 8f
    mov rsi, [rip + g_dsel + SB_ptr]
    mov rdx, [rip + g_dsel + SB_len]
    test rdx, rdx
    jnz 2f
    mov rsi, [rip + cfg_first + SB_ptr]
    xor edx, edx
1:  cmp byte ptr [rsi + rdx], 10
    je 2f
    inc rdx
    jmp 1b
2:  lea rdi, [rip + rwlab]
    call sb_set
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# dview_run_widget_width() -> eax the run widget's width, 0 when it does not show
FN dview_run_widget_width
    PROLOGUE
    call rw_name
    test eax, eax
    jz 9f
    lea rdi, [rip + g_face_small]
    mov rsi, [rip + rwlab + SB_ptr]
    mov rdx, [rip + rwlab + SB_len]
    call text_width
    M ecx, MI_8
    add eax, ecx
    add eax, ecx
    M ecx, MI_12
    add eax, ecx
    add eax, ecx                # the configuration's icon before its name
    M ecx, MI_6
    add eax, ecx
    M ecx, MI_4
    add eax, ecx
    M ecx, MI_28                # a long name is cut
    shl ecx, 3
    cmp eax, ecx
    cmovg eax, ecx
    mov [rip + rw_lw], eax
    mov ebx, 3
    call dap_live_count
    test eax, eax
    jz 1f
    mov ebx, 4
1:  M eax, MI_28
    M ecx, MI_2
    add eax, ecx
    imul eax, ebx
    add eax, [rip + rw_lw]
    M ecx, MI_4
    add eax, ecx
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# rw_rect(icon, x, y, w): a part as drawn, for print-debug-toolbar
rw_rect:
    mov eax, [rip + rw_n]
    cmp eax, 8
    jae 1f
    inc dword ptr [rip + rw_n]
    shl eax, 4
    lea r8, [rip + rw_rects]
    mov [r8 + rax], edi
    mov [r8 + rax + 4], esi
    mov [r8 + rax + 8], edx
    mov [r8 + rax + 12], ecx
1:  ret

# dview_run_widget(x, y, h): the run widget drawn from x, at the width dview_run_widget_width gave
FN dview_run_widget
    PROLOGUE 48
    mov dword ptr [rip + rw_n], 0
    mov [rsp], edi              # x
    mov [rsp + 4], esi          # y
    mov [rsp + 8], edx          # h
    call dview_run_widget_width
    test eax, eax
    jz 9f
    M eax, MI_28
    mov [rsp + 12], eax         # a button's size
    mov ecx, [rsp + 8]
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp + 4]
    mov [rsp + 16], ecx         # the buttons' y
    # the configuration, and its menu
    mov r14d, [rsp]
    xor edi, edi
    mov esi, r14d
    mov edx, ecx
    mov ecx, [rip + rw_lw]
    call rw_rect
    mov edi, ID_DBG_RW
    mov esi, r14d
    mov edx, [rsp + 16]
    mov ecx, [rip + rw_lw]
    mov r8d, [rsp + 12]
    call ui_btn
    mov r15d, eax
    test r15d, UB_HOVER
    jnz 1f
    call ctx_menu_list          # its menu open
    lea rcx, [rip + rw_items]
    cmp rax, rcx
    jne 2f
1:  mov edi, r14d
    mov esi, [rsp + 16]
    mov edx, [rip + rw_lw]
    mov ecx, [rsp + 12]
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
2:  mov edi, r14d
    mov esi, [rsp + 4]
    mov edx, [rip + rw_lw]
    mov ecx, [rsp + 8]
    call gfx_clip_push
    M ecx, MI_12                # the configuration's icon, as JetBrains IDEs show its type
    mov esi, r14d
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 8]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    mov edi, IC_PLAY
    COLOR r8d, T_SUCCESS
    call icon_draw
    lea rdi, [rip + g_face_small]
    M esi, MI_8
    add esi, r14d
    add esi, [rip + g_mt + 4*MI_12]
    add esi, [rip + g_mt + 4*MI_6]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8, [rip + rwlab + SB_ptr]
    COLOR r9d, T_FG
    call ui_text_c
    call gfx_clip_pop
    M ecx, MI_12                # the chevron at its right
    mov esi, r14d
    add esi, [rip + rw_lw]
    sub esi, ecx
    M eax, MI_4
    sub esi, eax
    mov edx, [rsp + 8]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    mov edi, IC_CHEV_D
    COLOR r8d, T_MUTED
    test r15d, UB_HOVER
    jz 21f
    COLOR r8d, T_FG
21: call icon_draw
    mov edi, ID_DBG_RW
    mov esi, r14d
    mov edx, [rsp + 16]
    add edx, [rsp + 12]
    mov ecx, [rip + rw_lw]
    mov r8d, r15d
    lea r9, [rip + .Lrw_tip_cfg]
    call tip_note_text
    test r15d, UB_CLICK
    jz 3f
    mov edi, r14d
    mov esi, [rsp + 4]
    add esi, [rsp + 8]
    call rw_menu_open
3:  add r14d, [rip + rw_lw]
    M eax, MI_4
    add r14d, eax
    # Run, Debug, and Stop while a session lives
    xor r13d, r13d
4:  cmp r13d, 4
    jae 9f
    cmp r13d, 2
    jne 41f
    call dap_live_count
    test eax, eax
    jz 46f                      # Stop only while a session lives
41: imul eax, r13d, 24
    lea rcx, [rip + rw_parts]
    add rax, rcx
    mov [rsp + 24], rax         # icon, color, command, tooltip
    # the tooltip names the configuration: Run 'NAME'
    lea rdi, [rip + rwtip]
    call sb_clear
    lea rdi, [rip + rwtip]
    mov rax, [rsp + 24]
    mov rsi, [rax + 16]
    call sb_push_cstr
    cmp r13d, 2
    jae 42f                     # Stop, More: no name
    lea rdi, [rip + rwtip]
    mov esi, 0x27
    call sb_push_byte
    lea rdi, [rip + rwtip]
    mov rsi, [rip + rwlab + SB_ptr]
    mov rdx, [rip + rwlab + SB_len]
    call sb_push
    lea rdi, [rip + rwtip]
    mov esi, 0x27
    call sb_push_byte
42: lea rdi, [rip + rwtip]
    xor esi, esi
    call sb_push_byte
    mov rax, [rsp + 24]
    mov edi, [rax]
    mov esi, r14d
    mov edx, [rsp + 16]
    mov ecx, [rsp + 12]
    call rw_rect
    lea edi, [r13 + ID_DBG_RW + 1]
    mov esi, r14d
    mov edx, [rsp + 16]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 12]
    call ui_btn
    mov r15d, eax
    cmp r13d, 1                 # Debug, the main action: on a tinted ground
    jne 431f
    mov edi, r14d
    mov esi, [rsp + 16]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 12]
    M r8d, MI_RADIUS
    COLOR r9d, T_SELECTION
    call gfx_round_rect
431: test r15d, UB_HOVER
    jz 44f
    mov edi, r14d
    mov esi, [rsp + 16]
    mov edx, [rsp + 12]
    mov ecx, [rsp + 12]
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    test r15d, UB_HELD
    jz 43f
    COLOR r9d, T_ACTIVE
43: call gfx_round_rect
44: mov rax, [rsp + 24]
    mov edi, [rax]
    cmp r13d, 2                 # Run or Debug: a spinner while a session of that kind gets ready
    jae 441f
    mov esi, r13d
    call rw_spin_icon
    mov edi, eax
441: mov [rsp + 32], edi
    mov eax, [rip + rw_n]       # the icon as drawn, for tests (a spinner's frame)
    test eax, eax
    jz 4411f
    dec eax
    shl eax, 4
    lea rcx, [rip + rw_rects]
    mov [rcx + rax], edi
4411:
    mov rax, [rsp + 24]
    mov ecx, [rax + 4]          # its color's theme slot
    lea rdx, [rip + g_theme]
    mov r9d, [rdx + rcx*4]
    cmp dword ptr [rsp + 32], IC_SPINA0
    jb 442f
    COLOR r9d, T_MUTED
442: mov edi, [rsp + 32]
    mov esi, r14d
    mov edx, [rsp + 16]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 12]
    call ui_icon_center
    cmp r13d, 2                 # Run or Debug: a green dot while a session of that kind runs
    jae 443f
    xor edi, edi
    test r13d, r13d
    sete dil
    call rw_running_kind
    test eax, eax
    jz 443f
    M ecx, MI_8
    mov edi, r14d
    add edi, [rsp + 12]
    sub edi, ecx
    sub edi, [rip + g_mt + 4*MI_2]
    mov esi, [rsp + 16]
    add esi, [rsp + 12]
    sub esi, ecx
    sub esi, [rip + g_mt + 4*MI_2]
    mov edx, ecx
    mov r8d, ecx
    sar r8d, 1
    COLOR r9d, T_SUCCESS
    call gfx_round_rect
443:
    lea edi, [r13 + ID_DBG_RW + 1]
    mov esi, r14d
    mov edx, [rsp + 16]
    add edx, [rsp + 12]
    mov ecx, [rsp + 12]
    mov r8d, r15d
    mov r9, [rip + rwtip + SB_ptr]
    call tip_note_text
    test r15d, UB_CLICK
    jz 45f
    mov [rip + rw_more_x], r14d     # More's menu opens under it
    mov eax, [rsp + 16]
    add eax, [rsp + 12]
    mov [rip + rw_more_y], eax
    mov rax, [rsp + 24]
    call [rax + 8]
45: add r14d, [rsp + 12]
    M eax, MI_2
    add r14d, eax
46: inc r13d
    jmp 4b
9:  EPILOGUE

# rw_running_kind(nodebug) -> eax 1 while a session of that kind runs or is paused (Run's: without
#   debugging; Debug's: debugging)
FN rw_running_kind
    PROLOGUE
    mov r12d, edi
    xor ebx, ebx
1:  cmp ebx, DS_MAX
    jae 8f
    mov edi, ebx
    call dap_slot
    mov ecx, [rax + DS_state]
    cmp ecx, DSS_RUNNING
    je 2f
    cmp ecx, DSS_PAUSED
    jne 3f
2:  xor ecx, ecx
    cmp dword ptr [rax + DS_nodebug], 0
    setne cl
    cmp ecx, r12d
    jne 3f
    mov eax, 1
    EPILOGUE
3:  inc ebx
    jmp 1b
8:  xor eax, eax
    EPILOGUE

# rw_starting() -> rax a session getting ready (its adapter starting, the program building), the
#   focused one first, or 0
FN rw_starting
    PROLOGUE
    call dap_focused
    test rax, rax
    jz 1f
    mov rdi, rax
    call rw_getting_ready
    test eax, eax
    jz 1f
    call dap_focused
    EPILOGUE
1:  xor ebx, ebx
2:  cmp ebx, DS_MAX
    jae 8f
    mov edi, ebx
    call dap_slot
    mov r12, rax
    mov rdi, rax
    call rw_getting_ready
    test eax, eax
    jz 3f
    mov rax, r12
    EPILOGUE
3:  inc ebx
    jmp 2b
8:  xor eax, eax
    EPILOGUE

# rw_getting_ready(ds) -> eax 1 while it starts: initializing, configuring, connecting
rw_getting_ready:
    xor eax, eax
    mov ecx, [rdi + DS_state]
    cmp ecx, DSS_INITIALIZING
    je 1f
    cmp ecx, DSS_CONFIGURING
    je 1f
    cmp ecx, DSS_CONNECTING
    jne 2f
1:  mov eax, 1
2:  ret

# rw_spin_icon(icon, part) -> eax the icon, or the spinner's frame while a session of the part's kind
#   gets ready (Run: one without debugging; Debug: one debugging); it then moves (dview_anim_due)
rw_spin_icon:
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    call rw_starting
    test rax, rax
    jz 8f
    xor ecx, ecx
    cmp dword ptr [rax + DS_nodebug], 0
    setne cl
    xor edx, edx
    test r12d, r12d
    sete dl
    cmp ecx, edx
    jne 8f                      # the other button's
    call rw_spin_frame
    EPILOGUE
8:  mov eax, ebx
    EPILOGUE

# rw_spin_step() -> eax the spinner's step now, 0 to 15 (one every RW_SPIN_MS); it moves
FN rw_spin_step
    sub rsp, 8
    call time_ms
    add rsp, 8
    xor edx, edx
    mov ecx, RW_SPIN_MS
    div rcx
    and eax, 15
    mov dword ptr [rip + rw_spin], 1
    ret

# rw_spin_frame() -> eax the spinner's frame now: sixteen steps round, a quarter of a right angle
#   each (the even ones IC_SPINA0..7, the odd ones IC_SPINA8..15)
.equ RW_SPIN_MS, 40
FN rw_spin_frame
    sub rsp, 8
    call rw_spin_step
    add rsp, 8
    mov ecx, eax
    shr eax, 1
    add eax, IC_SPINA0
    test ecx, 1
    jz 1f
    add eax, IC_SPINA8 - IC_SPINA0
1:  ret

# dview_anim_due() -> eax ms to the spinner's next step, -1 when none was drawn last frame (dap.s's
#   timeout)
FN dview_anim_due
    mov eax, -1
    cmp dword ptr [rip + rw_spin_shown], 0
    je 1f
    mov eax, RW_SPIN_MS
1:  ret

# dview_anim_tick(): every frame (dap_tick): the frame's spinners noted, a frame asked for while one
#   moves
FN dview_anim_tick
    mov eax, [rip + rw_spin]
    mov [rip + rw_spin_shown], eax
    mov dword ptr [rip + rw_spin], 0
    test eax, eax
    jz 1f
    sub rsp, 8
    call time_ms
    add rsp, 8
    mov rcx, rax
    sub rcx, [rip + rw_spin_last]
    cmp rcx, RW_SPIN_MS
    jb 1f
    mov [rip + rw_spin_last], rax
    mov dword ptr [rip + g_dirty], 1
1:  ret

# rw_more(): the widget's More: Run, Debug, Stop while a session lives, Edit and Add Configuration
rw_more:
    PROLOGUE
    lea rbx, [rip + rw_more_items]
    lea rax, [rip + rw_more_run]
    mov [rbx], rax
    lea rax, [rip + cmd_debug_run]
    mov [rbx + 8], rax
    lea rax, [rip + rw_more_debug]
    mov [rbx + 16], rax
    lea rax, [rip + rw_debug]
    mov [rbx + 24], rax
    add rbx, 32
    call dap_live_count
    test eax, eax
    jz 1f
    lea rax, [rip + .Lrw_stop]
    mov [rbx], rax
    lea rax, [rip + cmd_debug_stop]
    mov [rbx + 8], rax
    add rbx, 16
1:  lea rax, [rip + .Lrw_line]
    mov [rbx], rax
    mov qword ptr [rbx + 8], 0
    lea rax, [rip + .Lrw_edit]
    mov [rbx + 16], rax
    lea rax, [rip + cmd_debug_open_configurations]
    mov [rbx + 24], rax
    lea rax, [rip + .Lrw_add]
    mov [rbx + 32], rax
    lea rax, [rip + cmd_debug_add_configuration]
    mov [rbx + 40], rax
    lea rax, [rip + .Lrw_viewbps2]
    mov [rbx + 48], rax
    lea rax, [rip + cmd_debug_view_breakpoints]
    mov [rbx + 56], rax
    mov qword ptr [rbx + 64], 0
    mov qword ptr [rbx + 72], 0
    lea rdi, [rip + rw_more_run]    # the labels name the configuration
    call sb_clear
    lea rdi, [rip + rw_more_run]
    lea rsi, [rip + .Lrw_run]
    call sb_push_cstr
    lea rdi, [rip + rw_more_debug]
    call sb_clear
    lea rdi, [rip + rw_more_debug]
    lea rsi, [rip + .Lrw_debug]
    call sb_push_cstr
    lea rdi, [rip + rw_more_run]
    call rw_more_name
    lea rdi, [rip + rw_more_debug]
    call rw_more_name
    lea rax, [rip + rw_more_items]
    mov rcx, [rip + rw_more_run + SB_ptr]
    mov [rax], rcx
    mov rcx, [rip + rw_more_debug + SB_ptr]
    mov [rax + 16], rcx
    mov edi, [rip + rw_more_x]
    mov esi, [rip + rw_more_y]
    lea rdi, [rip + rw_more_items]
    mov esi, [rip + rw_more_x]
    mov edx, [rip + rw_more_y]
    call ctx_menu_open
    EPILOGUE

# rw_more_name(sb): 'NAME' and a NUL after what it holds
rw_more_name:
    PROLOGUE
    mov rbx, rdi
    mov esi, 0x27
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [rip + rwlab + SB_ptr]
    mov rdx, [rip + rwlab + SB_len]
    call sb_push
    mov rdi, rbx
    mov esi, 0x27
    call sb_push_byte
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    EPILOGUE

# rw_debug(): the widget's Debug: the configuration starts, also while another session is paused
rw_debug:
    xor edi, edi
    jmp start_selected

# rw_menu_open(x, y): launch.ini's configurations, the one F5 starts with a check after it, then Edit
#   Configurations and Add Configuration
rw_menu_open:
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    lea rdi, [rip + rwall]
    call sb_clear
    lea rdi, [rip + rwall]
    call dcfg_names
    lea rdi, [rip + rwnames]
    call sb_clear
    mov r12, [rip + rwall + SB_ptr]
    mov r14, r12
    add r14, [rip + rwall + SB_len]
    xor r13d, r13d
1:  cmp r12, r14
    jae 5f
    cmp r13d, RW_MAX
    jae 5f
    mov r15, r12
2:  cmp r15, r14
    jae 3f
    cmp byte ptr [r15], 10
    je 3f
    inc r15
    jmp 2b
3:  mov rax, [rip + rwnames + SB_len]
    lea rcx, [rip + rw_offs]
    mov [rcx + r13*8], rax
    # checked: the one rwlab names
    lea rbx, [rip + .Lrw_line]
    mov rdx, r15
    sub rdx, r12
    cmp rdx, [rip + rwlab + SB_len]
    jne 4f
    mov rdi, r12
    mov rsi, [rip + rwlab + SB_ptr]
    call memeq
    test eax, eax
    jz 4f
    lea rbx, [rip + .Lrw_checked]
4:  lea rdi, [rip + rwnames]
    mov rsi, r12
    mov rdx, r15
    sub rdx, r12
    call sb_push
    lea rdi, [rip + rwnames]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + rwnames]
    xor esi, esi
    call sb_push_byte
    lea r12, [r15 + 1]
    inc r13d
    jmp 1b
5:  mov [rip + rw_count], r13d
    # the items: the labels are in rwnames, which no longer grows
    lea rbx, [rip + rw_items]
    xor r12d, r12d
6:  cmp r12d, r13d
    jae 7f
    lea rcx, [rip + rw_offs]
    mov rax, [rcx + r12*8]
    add rax, [rip + rwnames + SB_ptr]
    mov [rbx], rax
    lea rax, [rip + rw_pick]
    mov [rbx + 8], rax
    add rbx, 16
    inc r12d
    jmp 6b
7:  test r13d, r13d
    jz 71f
    lea rax, [rip + .Lrw_line]
    mov [rbx], rax
    mov qword ptr [rbx + 8], 0
    add rbx, 16
71: lea rax, [rip + .Lrw_edit]
    mov [rbx], rax
    lea rax, [rip + cmd_debug_open_configurations]
    mov [rbx + 8], rax
    lea rax, [rip + .Lrw_add]
    mov [rbx + 16], rax
    lea rax, [rip + cmd_debug_add_configuration]
    mov [rbx + 24], rax
    mov qword ptr [rbx + 32], 0
    mov qword ptr [rbx + 40], 0
    lea rdi, [rip + rw_items]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call ctx_menu_open
    EPILOGUE

# rw_pick(): the configuration picked in the widget's menu is the one F5 starts
rw_pick:
    PROLOGUE
    mov ebx, [rip + g_menu_index]
    cmp ebx, [rip + rw_count]
    jae 9f
    mov r12, [rip + rwall + SB_ptr]
    mov r14, r12
    add r14, [rip + rwall + SB_len]
1:  mov r13, r12
2:  cmp r13, r14
    jae 3f
    cmp byte ptr [r13], 10
    je 3f
    inc r13
    jmp 2b
3:  test ebx, ebx
    jz 4f
    dec ebx
    lea r12, [r13 + 1]
    cmp r12, r14
    jb 1b
    jmp 9f
4:  lea rdi, [rip + g_dsel]
    mov rsi, r12
    mov rdx, r13
    sub rdx, r12
    call sb_set
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# dview_run_widget_dump(sb): "widget ICON x y w" for each part of the run widget as last drawn
#   (ICON 0: the configuration)
FN dview_run_widget_dump
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12d, [rip + rw_n]
    jae 9f
    mov r13d, r12d
    shl r13d, 4
    lea r14, [rip + rw_rects]
    add r14, r13
    mov rdi, rbx
    lea rsi, [rip + .Lrw_widget]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r14]
    call sb_push_u64
    xor r15d, r15d
2:  mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r14 + 4 + r15*4]
    call sb_push_u64
    inc r15d
    cmp r15d, 3
    jb 2b
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r12d
    jmp 1b
9:  EPILOGUE




# ---------------- Evaluate Expression, View and Mute Breakpoints ----------------

# cmd_debug_evaluate (Evaluate Expression, Alt+F8 in JetBrains IDEs): the selection, or the identifier
#   at the cursor, in the Debug tab's field (in a prompt with the sidebar layout); its result shows at
#   the top of the watches (dview_eval)
FN cmd_debug_evaluate
    PROLOGUE
    lea rdi, [rip + evalinit]
    call sb_clear
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 5f
    mov r12, [rbx + DOC_cur]
    mov r13, [rbx + DOC_anchor]
    cmp r12, r13
    je 3f
    jb 1f
    xchg r12, r13
1:  mov r14, r13
    sub r14, r12
    cmp r14, 1024
    ja 5f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call doc_range
    lea rdi, [rip + evalinit]
    mov rsi, rax
    mov rdx, r14
    call sb_push_clean_bp
    jmp 5f
3:  # the identifier at the cursor
    mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov r14, rax
    mov rdi, rbx
    mov rsi, r14
    call doc_line_start
    mov r15, r12
    sub r15, rax                # the column
    mov rdi, rbx
    mov rsi, r14
    call doc_line_text
    mov r13, rax
    mov r14, rdx
    cmp r15, r14
    ja 5f
    mov rbx, r15                # its start
31: test rbx, rbx
    jz 32f
    movzx edi, byte ptr [r13 + rbx - 1]
    call is_ident
    test eax, eax
    jz 32f
    dec rbx
    jmp 31b
32: mov r12, r15                # its end
33: cmp r12, r14
    jae 34f
    movzx edi, byte ptr [r13 + r12]
    call is_ident
    test eax, eax
    jz 34f
    inc r12
    jmp 33b
34: cmp r12, rbx
    jbe 5f
    lea rdi, [rip + evalinit]
    lea rsi, [r13 + rbx]
    mov rdx, r12
    sub rdx, rbx
    call sb_push
5:  lea rdi, [rip + evalinit]
    xor esi, esi
    call sb_push_byte
    cmp dword ptr [rip + g_debug_layout], 0
    jne 7f
    xor edx, edx
    cmp qword ptr [rip + evalinit + SB_len], 1
    jbe 6f
    mov rdx, [rip + evalinit + SB_ptr]
6:  mov edi, DP_EVAL
    lea rsi, [rip + .Lq_eval]
    call ask
    EPILOGUE
7:  call dview_ensure               # the Debug tab: its field takes the text and the keys
    cmp dword ptr [rip + dv_shown], 0
    jne 71f
    call dview_show
71: lea rdi, [rip + tw_eval]
    mov rsi, [rip + evalinit + SB_ptr]
    mov rdx, [rip + evalinit + SB_len]
    dec rdx
    call tf_set
    lea rdi, [rip + tw_eval]
    call tf_select_all
    mov dword ptr [rip + tw_sub], 0
    mov dword ptr [rip + tw_cur], 1
    mov edi, [rip + g_dv_places + 20]
    mov esi, 1
    call place_show
    EPILOGUE

# dview_eval(ptr, len): the evaluation at the top of Watches, in place of the one before; it is
#   evaluated in the focused frame at every stop, like a watch, until the next one, and is not kept
#   with the watches (Add to Watches with its text keeps it). The Watches pane shows with the keys.
FN dview_eval
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    test r13, r13
    jz 9f
    call bp_ensure_loaded
    cmp dword ptr [rip + eval_on], 0
    je 1f
    mov dword ptr [rip + eval_on], 0
    mov rdi, [rip + evalsb + SB_ptr]
    mov rsi, [rip + evalsb + SB_len]
    call dap_watch_remove
1:  xor ebx, ebx                # a watch already: it shows as it is
2:  mov edi, ebx
    call dap_watch_text
    test rax, rax
    jz 4f
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    mov rcx, r13
    call str_eq
    test eax, eax
    jnz 7f
    inc ebx
    jmp 2b
4:  lea rdi, [rip + evaltmp]    # the expression, then the watches as they were
    call sb_clear
    lea rdi, [rip + evaltmp]
    mov rsi, r12
    mov rdx, r13
    call sb_push_clean_bp
    lea rdi, [rip + evaltmp]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + evaltmp]
    mov rsi, [rip + g_watches + SB_ptr]
    mov rdx, [rip + g_watches + SB_len]
    call sb_push
    lea rdi, [rip + g_watches]
    call sb_clear
    lea rdi, [rip + g_watches]
    mov rsi, [rip + evaltmp + SB_ptr]
    mov rdx, [rip + evaltmp + SB_len]
    call sb_push
    xor edi, edi                # its text as the list has it
    call dap_watch_text
    lea rdi, [rip + evalsb]
    mov rsi, rax
    call sb_set
    mov dword ptr [rip + eval_on], 1
    call dap_watches_changed
7:  call dview_ensure
    cmp dword ptr [rip + dv_shown], 0
    jne 71f
    call dview_show
71: cmp dword ptr [rip + g_debug_layout], 0
    je 72f
    mov dword ptr [rip + tw_cur], 2
    mov edi, [rip + g_dv_places + 20]
    mov esi, 1
    call place_show
    jmp 9f
72: mov edi, [rip + g_dv_places + 4]
    mov esi, 1
    call place_show
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# dview_is_eval(ptr, len) -> eax 1 when that watch is the evaluation (not kept, bp.s)
FN dview_is_eval
    xor eax, eax
    cmp dword ptr [rip + eval_on], 0
    je 1f
    mov rdx, [rip + evalsb + SB_ptr]
    mov rcx, [rip + evalsb + SB_len]
    jmp str_eq
1:  ret

# eval_promote(ptr, len) -> eax 1 when the text is the evaluation's: it is a watch from now on
eval_promote:
    PROLOGUE
    call dview_is_eval
    test eax, eax
    jz 9f
    mov dword ptr [rip + eval_on], 0
    call bp_save_soon
    mov eax, 1
9:  EPILOGUE

# cmd_debug_view_breakpoints (View Breakpoints, Shift+Cmd+F8 in JetBrains IDEs on macOS): the
#   Breakpoints dialog (bpdialog.s)
FN cmd_debug_view_breakpoints
    jmp bpdlg_open

# cmd_debug_mute_breakpoints (Mute Breakpoints): no breakpoint reaches the sessions until it is
#   turned off again; they stay as they are, grey in the gutter
FN cmd_debug_mute_breakpoints
    jmp bp_mute_toggle


# ---------------- the Debug tab ([debug] layout = toolwindow) ----------------

# The bottom panel's Debug tab, laid out as JetBrains IDEs lay out their debug tool window: a row of
# session chips (a click focuses the session; its x stops it, or puts away the chip of one that
# ended), a toolbar (Rerun, Stop | Resume, Pause, Step Over, Into, Out, Run to Cursor | View
# Breakpoints, Mute Breakpoints) with the Threads & Variables and Console tabs after it. Threads &
# Variables has the thread picker above the focused thread's frames at the left, and at the right a
# field that evaluates an expression (Enter) or adds it as a watch (Shift+Ctrl+Enter, Shift+Cmd+Enter
# on macOS), the watches, then the variables. Tab and Shift+Tab move the keys between the frames, the
# field, the watches and the variables. The trees are the sidebar sections' (their keys, menus and
# prompts), the frames a list of the focused thread's own.

.equ ID_TW, 0x5e0200            # + toolbar entry
.equ ID_TW_SUB, 0x5e0230        # + 0 Threads & Variables, 1 Console
.equ ID_TW_THREAD, 0x5e0234
.equ ID_TW_EVAL, 0x5e0235
.equ ID_TW_CHIP, 0x5e0240       # + slot: a session's chip; + DS_MAX + slot: its x
.equ TWB_MAX, 16
.equ TWC_ANY, 0                 # a button acts: always
.equ TWC_LIVE, 1                # while the focused session lives
.equ TWC_PAUSED, 2              # while it is paused
.equ TWC_RUNNING, 3             # while it runs
.equ TWC_MUTE, 4                # always; on while breakpoints are muted
.equ TW_BAR, 12                 # toolbar entries, the separators (icon 0) among them
.equ TW_THR_MAX, 32             # threads the picker lists

# tw_can(cond) -> eax 1 when a button with that condition acts now
tw_can:
    mov eax, 1
    cmp edi, TWC_ANY
    je 9f
    cmp edi, TWC_MUTE
    je 9f
    push rdi
    call dap_focused
    pop rdi
    test rax, rax
    jz 8f
    mov ecx, [rax + DS_state]
    cmp ecx, DSS_ENDED
    je 8f
    mov eax, 1
    cmp edi, TWC_LIVE
    je 9f
    cmp edi, TWC_PAUSED
    jne 1f
    cmp ecx, DSS_PAUSED
    je 9f
    jmp 8f
1:  cmp ecx, DSS_RUNNING
    je 9f
8:  xor eax, eax
9:  ret

# tw_color(icon) -> eax its color: the text's, Stop red (as the Sublime Debugger's bar)
tw_color:
    COLOR eax, T_FG
    cmp edi, IC_DBG_STOP2
    jne 1f
    COLOR eax, T_ERROR
1:  ret

# tw_button(id, x, y, size, entry): a toolbar button; entry: icon, condition, command, tooltip. One
#   that cannot act now is drawn faint and does nothing; Mute Breakpoints looks pressed while on.
tw_button:
    PROLOGUE 32
    mov [rsp], edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov rbx, r8
    mov edi, [rbx + 4]
    call tw_can
    mov [rsp + 4], eax
    mov eax, [rip + twb_n]      # where it is, for tests
    cmp eax, TWB_MAX
    jae 2f
    inc dword ptr [rip + twb_n]
    shl eax, 4
    lea rcx, [rip + twb_rects]
    mov edx, [rbx]
    mov [rcx + rax], edx
    mov [rcx + rax + 4], r12d
    mov [rcx + rax + 8], r13d
    mov [rcx + rax + 12], r14d
2:  mov edi, [rsp]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r14d
    call ui_btn
    mov r15d, eax
    cmp dword ptr [rbx + 4], TWC_MUTE
    jne 3f
    cmp dword ptr [rip + g_bp_muted], 0
    je 3f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r14d
    M r8d, MI_RADIUS
    COLOR r9d, T_SELECTION
    call gfx_round_rect
3:  cmp dword ptr [rsp + 4], 0
    je 4f
    test r15d, UB_HOVER
    jz 4f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r14d
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    test r15d, UB_HELD
    jz 31f
    COLOR r9d, T_ACTIVE
31: call gfx_round_rect
4:  mov edi, [rbx]
    call tw_color
    mov r9d, eax
    cmp dword ptr [rsp + 4], 0
    jne 5f
    COLOR r9d, T_MUTED          # faint: the muted color at half strength
    and r9d, 0x00ffffff
    or r9d, 0x80000000
5:  mov edi, [rbx]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r14d
    call ui_icon_center
    mov edi, [rsp]
    mov esi, r12d
    mov edx, r13d
    add edx, r14d
    mov ecx, r14d
    mov r8d, r15d
    mov r9, [rbx + 16]
    call tip_note_text
    cmp dword ptr [rsp + 4], 0
    je 9f
    test r15d, UB_CLICK
    jz 9f
    call [rbx + 8]
9:  EPILOGUE

# tw_rerun(): Rerun: the focused session again, or the configuration F5 starts when none lives
tw_rerun:
    PROLOGUE
    mov edi, TWC_LIVE
    call tw_can
    test eax, eax
    jz 1f
    call cmd_debug_restart
    EPILOGUE
1:  xor edi, edi
    call start_selected
    EPILOGUE

# tw_focus(pane) -> eax 1 when the tab has the keys and the pane is the current one
tw_focus:
    push rdi
    call place_focused
    pop rdi
    xor ecx, ecx
    cmp eax, [rip + g_dv_places + 20]
    jne 1f
    cmp edi, [rip + tw_cur]
    jne 1f
    mov ecx, 1
1:  mov eax, ecx
    ret

# tw_press(pane, x, y, w, h): a press there makes the pane the current one
tw_press:
    test dword ptr [rip + g_pressed], (1 << BTN_LEFT) | (1 << BTN_RIGHT)
    jz 9f
    push rdi
    mov edi, esi
    mov esi, edx
    mov edx, ecx
    mov ecx, r8d
    call ui_in
    pop rdi
    test eax, eax
    jz 9f
    mov [rip + tw_cur], edi
9:  ret

# tw_rect(pane, x, y, w, h): where the pane is, for tests (w 0: not drawn)
tw_rect:
    shl edi, 4
    lea rax, [rip + tw_rects]
    mov [rax + rdi], esi
    mov [rax + rdi + 4], edx
    mov [rax + rdi + 8], ecx
    mov [rax + rdi + 12], r8d
    ret

# tw_draw(ctx, x, y, w, h)
tw_draw:
    PROLOGUE 64
    mov [rsp], esi              # x
    mov [rsp + 4], edx          # y
    mov [rsp + 8], ecx          # w
    mov [rsp + 12], r8d         # h
    mov dword ptr [rip + twb_n], 0
    mov dword ptr [rip + tw_nchips], 0
    lea rdi, [rip + tw_rects]   # the panes: none drawn yet
    xor eax, eax
    mov ecx, 8
    rep stosq
    M eax, MI_32
    mov [rsp + 16], eax         # a bar's height
    M eax, MI_28
    mov [rsp + 20], eax         # a button's size
    mov ecx, [rsp + 16]
    sub ecx, eax
    sar ecx, 1
    mov [rsp + 24], ecx         # a button's inset in its bar
    # the sessions
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 16]
    call tw_chips
    # the toolbar
    mov eax, [rsp + 4]
    add eax, [rsp + 16]
    mov [rsp + 28], eax         # its top
    mov r14d, [rsp]
    add r14d, [rip + g_mt + 4*MI_6]
    xor ebx, ebx
1:  cmp ebx, TW_BAR
    jae 2f
    imul r8, rbx, 24
    lea rax, [rip + tw_bar]
    add r8, rax
    cmp dword ptr [r8], 0
    jne 11f
    add r14d, [rip + g_mt + 4*MI_6]     # a separator
    mov edi, r14d
    mov esi, [rsp + 28]
    add esi, [rip + g_mt + 4*MI_8]
    M edx, MI_1
    mov ecx, [rsp + 16]
    sub ecx, [rip + g_mt + 4*MI_16]
    COLOR r8d, T_BORDER
    call gfx_fill
    add r14d, [rip + g_mt + 4*MI_6]
    add r14d, [rip + g_mt + 4*MI_1]
    jmp 12f
11: lea edi, [rbx + ID_TW]
    mov esi, r14d
    mov edx, [rsp + 28]
    add edx, [rsp + 24]
    mov ecx, [rsp + 20]
    call tw_button
    add r14d, [rsp + 20]
    add r14d, [rip + g_mt + 4*MI_2]
12: inc ebx
    jmp 1b
2:  add r14d, [rip + g_mt + 4*MI_16]    # the tabs
    mov edi, r14d
    mov esi, [rsp + 28]
    mov edx, [rsp + 16]
    call tw_subtabs
    cmp dword ptr [rip + tw_sub], 1     # Console: Clear at the right end
    jne 21f
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 20]
    sub esi, [rip + g_mt + 4*MI_8]
    lea r8, [rip + tw_clear]
    mov edi, ID_TW + 15
    mov edx, [rsp + 28]
    add edx, [rsp + 24]
    mov ecx, [rsp + 20]
    call tw_button
21:
    mov esi, [rsp + 28]         # a line under the bars
    add esi, [rsp + 16]
    mov [rsp + 32], esi
    mov edi, [rsp]
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    mov eax, [rsp + 32]
    add eax, [rip + g_mt + 4*MI_1]
    mov [rsp + 32], eax         # the body's top
    mov ecx, [rsp + 4]
    add ecx, [rsp + 12]
    sub ecx, eax
    mov [rsp + 36], ecx         # its height
    test ecx, ecx
    jle 9f
    cmp dword ptr [rip + tw_sub], 1
    jne 3f
    xor edi, edi                # Console
    mov esi, [rsp]
    mov edx, [rsp + 32]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 36]
    call console_draw
    jmp 9f
3:  mov eax, [rsp + 8]          # Threads & Variables: the frames [debug] frames_width % (at least 120)
    mov ecx, [rip + g_debug_frames_pct]
    imul eax, ecx
    xor edx, edx
    mov ecx, 100
    div ecx
    mov ecx, 120
    call sc_dv
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, [rsp + 8]
    sub ecx, 120
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 40], eax
    mov edi, [rsp]              # the divider: a drag sets that share
    mov esi, [rsp + 32]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 36]
    mov r8d, eax
    call tw_divider
    mov eax, [rsp + 40]
    mov edi, [rsp]
    mov esi, [rsp + 32]
    mov edx, eax
    mov ecx, [rsp + 36]
    call tw_frames
    mov edi, [rsp]
    add edi, [rsp + 40]
    mov esi, [rsp + 32]
    M edx, MI_1
    mov ecx, [rsp + 36]
    COLOR r8d, T_BORDER
    call gfx_fill
    mov edi, [rsp]
    add edi, [rsp + 40]
    add edi, [rip + g_mt + 4*MI_1]
    mov esi, [rsp + 32]
    mov edx, [rsp + 8]
    sub edx, [rsp + 40]
    sub edx, [rip + g_mt + 4*MI_1]
    mov ecx, [rsp + 36]
    call tw_values
9:  EPILOGUE

# tw_divider(x, y, w, h, frames width): the line between the frames and the values as a handle: the
#   pointer over it shows the resize cursor, a drag sets [debug] frames_width (10 to 80% of the tab),
#   a double click gives back 30%
.equ ID_TW_SPLIT, 0x5e0236
tw_divider:
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    lea r12d, [rdi + r8]        # its x
    M eax, MI_3
    mov edi, ID_TW_SPLIT
    mov esi, r12d
    sub esi, eax
    mov edx, [rsp + 4]
    lea ecx, [rax + rax + 1]
    mov r8d, [rsp + 12]
    call ui_btn
    mov r13d, eax
    test r13d, UB_PRESS
    jz 1f
    and dword ptr [rip + g_pressed], ~(1 << BTN_LEFT)   # the press is the drag's
1:  test r13d, UB_HOVER | UB_HELD
    jz 9f
    mov dword ptr [rip + g_cursor], CUR_EW
    mov edi, r12d
    sub edi, [rip + g_mt + 4*MI_1]
    mov esi, [rsp + 4]
    M edx, MI_2
    mov ecx, [rsp + 12]
    COLOR r8d, T_ACCENT
    call gfx_fill
    mov eax, 30
    test r13d, UB_DOUBLE
    jnz 3f
    test r13d, UB_HELD
    jz 9f
    mov eax, [rip + g_mx]       # the share where the pointer is
    sub eax, [rsp]
    imul eax, eax, 100
    cdq
    mov ecx, [rsp + 8]
    test ecx, ecx
    jz 9f
    idiv ecx
    mov ecx, 10
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 80
    cmp eax, ecx
    cmovg eax, ecx
3:  cmp eax, [rip + g_debug_frames_pct]
    je 9f
    mov [rip + g_debug_frames_pct], eax
    mov dword ptr [rip + g_dirty], 1
    mov dword ptr [rip + g_settings_changed], 1
9:  EPILOGUE

# sc_dv(ecx points) -> ecx at the interface's scale (keeps eax)
sc_dv:
    push rax
    mov edi, ecx
    call sc
    mov ecx, eax
    pop rax
    ret

# tw_chips(x, y, w, h): a chip per session not put away: its bug (green while it lives), its name, x
tw_chips:
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov r14d, edi
    add r14d, [rip + g_mt + 4*MI_8]
    M eax, MI_24
    mov ecx, [rsp + 12]
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp + 4]
    mov [rsp + 24], ecx         # a chip's top
    xor ebx, ebx
1:  cmp ebx, DS_MAX
    jae 7f
    mov edi, ebx
    call dap_slot
    mov r12, rax
    cmp dword ptr [r12 + DS_state], DSS_FREE
    je 6f
    lea rcx, [rip + tw_closed]  # put away
    mov eax, [r12 + DS_id]
    cmp eax, [rcx + rbx*4]
    je 6f
    mov rsi, [r12 + DS_name]
    test rsi, rsi
    jnz 2f
    lea rsi, [rip + .Ltw_session]
2:  mov [rsp + 16], rsi
    mov rdi, rsi
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, [rsp + 16]
    mov rdx, rax
    call text_width
    mov r13d, eax               # the chip's width: 8, bug 16, 6, name, 6, x 16, 6
    add r13d, [rip + g_mt + 4*MI_8]
    add r13d, [rip + g_mt + 4*MI_16]
    add r13d, [rip + g_mt + 4*MI_16]
    add r13d, [rip + g_mt + 4*MI_6]
    add r13d, [rip + g_mt + 4*MI_6]
    add r13d, [rip + g_mt + 4*MI_6]
    lea edi, [rbx + ID_TW_CHIP]
    mov esi, r14d
    mov edx, [rsp + 24]
    mov ecx, r13d
    M r8d, MI_24
    call ui_btn
    mov [rsp + 28], eax
    cmp ebx, [rip + g_dfocus]
    jne 21f
    COLOR r9d, T_SELECTION
    jmp 22f
21: test dword ptr [rsp + 28], UB_HOVER
    jz 23f
    COLOR r9d, T_HOVER
22: mov edi, r14d
    mov esi, [rsp + 24]
    mov edx, r13d
    M ecx, MI_24
    M r8d, MI_RADIUS
    call gfx_round_rect
23: COLOR r8d, T_SUCCESS
    cmp dword ptr [r12 + DS_state], DSS_ENDED
    jne 24f
    COLOR r8d, T_MUTED
24: M ecx, MI_16
    mov esi, r14d
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, [rip + g_mt + 4*MI_24]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 24]
    mov edi, IC_DBG_BUG
    cmp dword ptr [r12 + DS_nodebug], 0
    je 25f
    mov edi, IC_RUN_OUTLINE     # a run without debugging: the run icon
25: call icon_draw
    lea rdi, [rip + g_face_small]
    mov esi, r14d
    add esi, [rip + g_mt + 4*MI_8]
    add esi, [rip + g_mt + 4*MI_16]
    add esi, [rip + g_mt + 4*MI_6]
    mov edx, [rsp + 24]
    M ecx, MI_24
    mov r8, [rsp + 16]
    COLOR r9d, T_FG
    call ui_text_c
    mov esi, r14d               # its x
    add esi, r13d
    sub esi, [rip + g_mt + 4*MI_6]
    sub esi, [rip + g_mt + 4*MI_16]
    M ecx, MI_16
    mov edx, [rip + g_mt + 4*MI_24]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 24]
    lea edi, [rbx + ID_TW_CHIP + DS_MAX]
    mov r8d, ecx
    mov r9d, IC_CLOSE
    call ui_icon_btn
    test eax, UB_CLICK
    jz 3f
    mov edi, ebx
    call tw_close_session
    jmp 4f
3:  test dword ptr [rsp + 28], UB_CLICK
    jz 4f
    mov edi, ebx
    call dap_focus_slot
4:  mov eax, [rip + tw_nchips]  # where it is, for tests
    cmp eax, DS_MAX
    jae 5f
    inc dword ptr [rip + tw_nchips]
    shl eax, 4
    lea rcx, [rip + tw_chip_rects]
    mov [rcx + rax], ebx
    mov [rcx + rax + 4], r14d
    mov edx, [rsp + 24]
    mov [rcx + rax + 8], edx
    mov [rcx + rax + 12], r13d
5:  add r14d, r13d
    add r14d, [rip + g_mt + 4*MI_4]
6:  inc ebx
    jmp 1b
7:  cmp dword ptr [rip + tw_nchips], 0
    jne 9f
    lea rdi, [rip + g_face_small]       # no session: what the tab is for
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    lea r8, [rip + .Ltw_idle]
    COLOR r9d, T_MUTED
    call ui_text_c
9:  EPILOGUE

# tw_close_session(slot): a chip's x: the session stops when it lives; its chip goes either way
tw_close_session:
    PROLOGUE
    mov ebx, edi
    call dap_slot
    mov r12, rax
    mov eax, [r12 + DS_id]
    lea rcx, [rip + tw_closed]
    mov [rcx + rbx*4], eax
    cmp dword ptr [r12 + DS_state], DSS_ENDED
    je 9f
    mov edi, ebx
    call dap_focus_slot
    call dap_stop
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# tw_subtabs(x, y, h): Threads & Variables and Console, the chosen one filled
tw_subtabs:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov r14d, edi
    xor ebx, ebx
1:  cmp ebx, 2
    jae 9f
    lea rax, [rip + tw_subnames]
    mov r12, [rax + rbx*8]
    mov rdi, r12
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r12
    mov rdx, rax
    call text_width
    M ecx, MI_12
    lea r13d, [rax + rcx*2]     # its width
    M eax, MI_24
    mov ecx, [rsp + 8]
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp + 4]
    mov r15d, ecx               # its top
    lea edi, [rbx + ID_TW_SUB]
    mov esi, r14d
    mov edx, r15d
    mov ecx, r13d
    M r8d, MI_24
    call ui_btn
    mov [rsp + 12], eax
    cmp ebx, [rip + tw_sub]
    jne 2f
    COLOR r9d, T_SELECTION
    jmp 3f
2:  test dword ptr [rsp + 12], UB_HOVER
    jz 4f
    COLOR r9d, T_HOVER
3:  mov edi, r14d
    mov esi, r15d
    mov edx, r13d
    M ecx, MI_24
    M r8d, MI_RADIUS
    call gfx_round_rect
4:  COLOR r9d, T_MUTED
    cmp ebx, [rip + tw_sub]
    jne 41f
    COLOR r9d, T_FG
41: lea rdi, [rip + g_face_small]
    mov esi, r14d
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, r15d
    M ecx, MI_24
    mov r8, r12
    call ui_text_c
    mov eax, ebx                # where it is, for tests
    shl eax, 4
    lea rcx, [rip + tw_sub_rects]
    mov [rcx + rax], r14d
    mov [rcx + rax + 4], r15d
    mov [rcx + rax + 8], r13d
    test dword ptr [rsp + 12], UB_CLICK
    jz 5f
    mov [rip + tw_sub], ebx
    mov dword ptr [rip + g_dirty], 1
5:  add r14d, r13d
    add r14d, [rip + g_mt + 4*MI_4]
    inc ebx
    jmp 1b
9:  EPILOGUE

# tw_frames(x, y, w, h): the thread picker, then the focused thread's frames
tw_frames:
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    call tw_sync_frames
    M eax, MI_28
    mov [rsp + 16], eax         # the picker's height
    xor edi, edi
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call tw_press
    xor edi, edi
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call tw_rect
    call dap_focused
    test rax, rax
    jz 5f
    mov r12, rax
    cmp dword ptr [r12 + DS_state], DSS_ENDED
    je 5f
    mov rdi, r12                # the focused thread's name
    call tw_thread_name
    test eax, eax
    jz 5f
    mov edi, ID_TW_THREAD
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 16]
    call ui_btn
    mov [rsp + 20], eax
    test eax, UB_HOVER
    jz 1f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 16]
    COLOR r8d, T_HOVER
    call gfx_fill
1:  M ecx, MI_12                # a check while it is suspended, as JetBrains IDEs mark it
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 16]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    mov edi, IC_CHECK
    COLOR r8d, T_SUCCESS
    cmp dword ptr [r12 + DS_state], DSS_PAUSED
    je 2f
    mov edi, IC_DBG_RESUME
    COLOR r8d, T_MUTED
2:  call icon_draw
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_8]
    add esi, [rip + g_mt + 4*MI_12]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 16]
    mov r8, [rip + twlab + SB_ptr]
    COLOR r9d, T_FG
    call ui_text_c
    mov esi, eax
    add esi, [rip + g_mt + 4*MI_6]
    M ecx, MI_12
    mov edx, [rsp + 16]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    mov edi, IC_CHEV_D
    COLOR r8d, T_MUTED
    call icon_draw
    mov edi, ID_TW_THREAD
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rsp + 16]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 20]
    lea r9, [rip + .Ltw_thread_tip]
    call tip_note_text
    test dword ptr [rsp + 20], UB_CLICK
    jz 5f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rsp + 16]
    call tw_thread_menu
5:  xor edi, edi
    call tw_focus
    mov r9d, eax
    mov rdi, [rip + frames_tr]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rsp + 16]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    sub r8d, [rsp + 16]
    test r8d, r8d
    jle 9f
    call tree_draw
9:  EPILOGUE

# tw_thread_name(ds) -> eax 1 with twlab the focused thread's name (NUL-terminated)
tw_thread_name:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + DS_threads + VEC_len]
    jae 8f
    imul r13, r12, THR_SIZE
    add r13, [rbx + DS_threads + VEC_ptr]
    mov rax, [r13 + THR_id]
    cmp rax, [rbx + DS_thread]
    je 2f
    inc r12
    jmp 1b
2:  mov esi, [r13 + THR_name]
    add rsi, [rbx + DS_strs + SB_ptr]
    mov edx, [r13 + THR_namelen]
    lea rdi, [rip + twlab]
    call sb_set
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# tw_sync_frames(): the frames list follows the focused session (its generation)
tw_sync_frames:
    PROLOGUE
    mov eax, [rip + g_dap_gen]
    cmp eax, [rip + tw_fgen]
    je 9f
    mov [rip + tw_fgen], eax
    call dap_focused
    mov rbx, rax
    mov rdi, [rip + frames_tr]
    test rbx, rbx
    jz 1f
    cmp dword ptr [rbx + DS_state], DSS_ENDED
    je 1f
    xor esi, esi
    mov rdx, rbx
    call list_frames
    jmp 9f
1:  xor esi, esi
    call tree_kids_begin
    mov rdi, [rip + frames_tr]
    xor esi, esi
    call tree_kids_end
9:  EPILOGUE

# tw_thread_menu(x, y): the focused session's threads, the focused one checked; a pick focuses it
tw_thread_menu:
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    call dap_focused
    test rax, rax
    jz 9f
    mov rbx, rax
    lea rdi, [rip + twthr]
    call sb_clear
    xor r12d, r12d
1:  cmp r12, [rbx + DS_threads + VEC_len]
    jae 3f
    cmp r12d, TW_THR_MAX
    jae 3f
    mov rax, [rip + twthr + SB_len]
    lea rcx, [rip + tw_thr_offs]
    mov [rcx + r12*8], rax
    imul r13, r12, THR_SIZE
    add r13, [rbx + DS_threads + VEC_ptr]
    lea rdi, [rip + twthr]
    mov esi, [r13 + THR_name]
    add rsi, [rbx + DS_strs + SB_ptr]
    mov edx, [r13 + THR_namelen]
    call sb_push
    mov rax, [r13 + THR_id]
    cmp rax, [rbx + DS_thread]
    jne 2f
    lea rdi, [rip + twthr]
    lea rsi, [rip + .Lrw_checked]
    call sb_push_cstr
2:  lea rdi, [rip + twthr]
    xor esi, esi
    call sb_push_byte
    inc r12
    jmp 1b
3:  mov [rip + tw_thr_n], r12d
    lea r13, [rip + tw_thr_items]
    xor r14d, r14d
4:  cmp r14d, r12d
    jae 5f
    lea rcx, [rip + tw_thr_offs]
    mov rax, [rcx + r14*8]
    add rax, [rip + twthr + SB_ptr]
    mov [r13], rax
    lea rax, [rip + tw_pick_thread]
    mov [r13 + 8], rax
    add r13, 16
    inc r14d
    jmp 4b
5:  mov qword ptr [r13], 0
    mov qword ptr [r13 + 8], 0
    lea rdi, [rip + tw_thr_items]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call ctx_menu_open
9:  EPILOGUE

# tw_pick_thread(): the thread picked in the menu is the focused one
tw_pick_thread:
    PROLOGUE
    mov ebx, [rip + g_menu_index]
    cmp ebx, [rip + tw_thr_n]
    jae 9f
    call dap_focused
    test rax, rax
    jz 9f
    cmp rbx, [rax + DS_threads + VEC_len]
    jae 9f
    mov rdi, rax
    imul rcx, rbx, THR_SIZE
    add rcx, [rax + DS_threads + VEC_ptr]
    mov rsi, [rcx + THR_id]
    call dap_focus_thread
9:  EPILOGUE

# tw_values(x, y, w, h): the field, then the watches and the variables, or a word that there are none
tw_values:
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    M eax, MI_32
    mov [rsp + 16], eax         # the field's row
    mov edi, 1
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 16]
    call tw_press
    mov edi, 1
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 16]
    call tw_rect
    mov edi, 1
    call tw_focus
    mov r9d, eax
    lea rdi, [rip + tw_eval]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_6]
    M eax, MI_24
    mov edx, [rsp + 16]
    sub edx, eax
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_12]
    mov r8d, eax
    lea rax, [rip + .Ltw_eval_ph]
    push rax
    push rax
    mov dword ptr [rip + g_tf_flat], 1  # flat, as JetBrains IDEs draw it: the lines around it frame it
    call ui_textfield
    mov dword ptr [rip + g_tf_flat], 0
    add rsp, 16
    mov edi, [rsp]              # a line under it
    mov esi, [rsp + 4]
    add esi, [rsp + 16]
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    mov eax, [rsp + 4]
    add eax, [rsp + 16]
    add eax, [rip + g_mt + 4*MI_1]
    mov [rsp + 20], eax         # the values' top
    mov ecx, [rsp + 4]
    add ecx, [rsp + 12]
    sub ecx, eax
    mov [rsp + 24], ecx         # their height
    test ecx, ecx
    jle 9f
    call dap_focused            # paused: values to show
    test rax, rax
    jz 1f
    cmp dword ptr [rax + DS_state], DSS_PAUSED
    je 2f
1:  lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    mov edx, [rsp + 20]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 24]
    lea r9, [rip + .Ltw_novalues]
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    jmp 9f
2:  mov edi, 1                  # the watches: as tall as their rows, half the height at most
    call sync
    mov rdi, [rip + trees + 8]
    call tree_rows
    mov rdi, [rip + trees + 8]
    call tree_rows_count
    M ecx, MI_ROW
    imul eax, ecx
    mov ecx, [rsp + 24]
    shr ecx, 1
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 28], eax
    test eax, eax
    jz 3f
    mov edi, 2
    mov esi, [rsp]
    mov edx, [rsp + 20]
    mov ecx, [rsp + 8]
    mov r8d, eax
    call tw_press
    mov edi, 2
    mov esi, [rsp]
    mov edx, [rsp + 20]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 28]
    call tw_rect
    mov edi, 2
    call tw_focus
    mov r9d, eax
    mov rdi, [rip + trees + 8]
    mov esi, [rsp]
    mov edx, [rsp + 20]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 28]
    call tree_draw
    mov edi, [rsp]
    mov esi, [rsp + 20]
    add esi, [rsp + 28]
    mov edx, [rsp + 8]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    mov eax, [rsp + 28]
    add eax, [rip + g_mt + 4*MI_1]
    mov [rsp + 28], eax
3:  xor edi, edi                # the variables
    call sync
    mov eax, [rsp + 20]
    add eax, [rsp + 28]
    mov [rsp + 32], eax
    mov ecx, [rsp + 24]
    sub ecx, [rsp + 28]
    mov [rsp + 36], ecx
    test ecx, ecx
    jle 9f
    mov edi, 3
    mov esi, [rsp]
    mov edx, eax
    mov r8d, ecx
    mov ecx, [rsp + 8]
    call tw_press
    mov edi, 3
    mov esi, [rsp]
    mov edx, [rsp + 32]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 36]
    call tw_rect
    mov edi, 3
    call tw_focus
    mov r9d, eax
    mov rdi, [rip + trees]
    mov esi, [rsp]
    mov edx, [rsp + 32]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 36]
    call tree_draw
9:  EPILOGUE

# tw_key(ctx, keysym, cp, mods) -> eax
tw_key:
    PROLOGUE
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    cmp dword ptr [rip + tw_sub], 1
    jne 1f
    call console_key            # Console: its input line
    EPILOGUE
1:  cmp r12d, KEY_TAB
    je 2f
    cmp r12d, KEY_ISO_LEFT_TAB
    jne 4f
    mov ebx, 3                  # back: three on, of four
    jmp 3f
2:  mov ebx, 1
    test r14d, MOD_SHIFT
    jz 3f
    mov ebx, 3
3:  mov eax, [rip + tw_cur]
    mov ecx, 4
31: add eax, ebx
    and eax, 3
    dec ecx
    jz 32f
    mov edx, eax                # passed over: a pane not drawn (no watches, nothing paused)
    shl edx, 4
    lea r8, [rip + tw_rects]
    cmp dword ptr [r8 + rdx + 8], 0
    je 31b
32: mov [rip + tw_cur], eax
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
4:  mov eax, [rip + tw_cur]
    cmp eax, 1
    jne 6f
    cmp r12d, KEY_RETURN        # the field
    je 41f
    cmp r12d, KEY_KP_ENTER
    jne 5f
41: lea rdi, [rip + tw_eval]
    call tf_text
    test rdx, rdx
    jz 48f
    mov rbx, rax
    mov r15, rdx
    mov eax, r14d
    and eax, MOD_SHIFT | MOD_CTRL
    cmp eax, MOD_SHIFT | MOD_CTRL
    jne 42f
    mov rdi, rbx                # Shift+Ctrl+Enter: a watch
    mov rsi, r15
    call eval_promote
    test eax, eax
    jnz 43f
    mov rdi, rbx
    mov rsi, r15
    call dap_watch_add
    call bp_save_soon
    jmp 43f
42: mov rdi, rbx
    mov rsi, r15
    call dview_eval
43: lea rdi, [rip + tw_eval]
    call tf_clear
48: mov eax, 1
    EPILOGUE
5:  cmp r12d, KEY_ESCAPE
    jne 51f
    mov dword ptr [rip + tw_cur], 3
    mov eax, 1
    EPILOGUE
51: lea rdi, [rip + tw_eval]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
    EPILOGUE
6:  test eax, eax
    jnz 7f
    mov rdi, [rip + frames_tr]  # the frames
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tree_key
    EPILOGUE
7:  mov edi, 1                  # the watches' section, the variables'
    cmp eax, 2
    je 71f
    xor edi, edi
71: mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call section_key
    EPILOGUE

# dview_tw_field() -> rax the Debug tab's field with the keys (the evaluation's, the console's), or 0
FN dview_tw_field
    sub rsp, 8
    call place_focused
    add rsp, 8
    cmp dword ptr [rip + g_dv_places + 20], 0
    jl 8f
    cmp eax, [rip + g_dv_places + 20]
    jne 8f
    lea rax, [rip + cin]
    cmp dword ptr [rip + tw_sub], 1
    je 9f
    cmp dword ptr [rip + tw_cur], 1
    jne 8f
    lea rax, [rip + tw_eval]
9:  ret
8:  xor eax, eax
    ret

# dview_tw_dump(sb): the Debug tab as last drawn: "twbutton ICON x y size", "chip SLOT x y w",
#   "sub N x y w", "pane N x y w h" (w 0: not drawn), "twpane=N", "twsub=N"
FN dview_tw_dump
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12d, [rip + twb_n]
    jae 2f
    mov edi, r12d
    lea rsi, [rip + twb_rects]
    lea rdx, [rip + .Ltw_button]
    mov ecx, 4
    call tw_dump_row
    inc r12d
    jmp 1b
2:  xor r12d, r12d
21: cmp r12d, [rip + tw_nchips]
    jae 3f
    mov edi, r12d
    lea rsi, [rip + tw_chip_rects]
    lea rdx, [rip + .Ltw_chip]
    mov ecx, 4
    call tw_dump_row
    inc r12d
    jmp 21b
3:  xor r12d, r12d
31: cmp r12d, 2
    jae 4f
    mov rdi, rbx
    lea rsi, [rip + .Ltw_subl]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov edi, r12d
    lea rsi, [rip + tw_sub_rects]
    xor edx, edx
    mov ecx, 3
    call tw_dump_row
    inc r12d
    jmp 31b
4:  xor r12d, r12d
41: cmp r12d, 4
    jae 6f
    mov rdi, rbx
    lea rsi, [rip + .Ltw_pane]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov edi, r12d
    lea rsi, [rip + tw_rects]
    xor edx, edx
    mov ecx, 4
    call tw_dump_row
    inc r12d
    jmp 41b
6:  mov rdi, rbx
    lea rsi, [rip + .Ltw_cur]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + tw_cur]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ltw_subeq]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + tw_sub]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# tw_dump_row(i, table, prefix or 0, n): onto rbx's SB, the prefix, then n numbers of the table's
#   16-byte row i (space before each but a first with a prefix), a line's end
tw_dump_row:
    PROLOGUE
    mov r12d, edi
    shl r12d, 4
    add r12, rsi
    mov r13d, ecx
    xor r14d, r14d
    test rdx, rdx
    jz 1f
    mov rdi, rbx
    mov rsi, rdx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r12]
    call sb_push_u64
    inc r14d
1:  cmp r14d, r13d
    jae 2f
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r12 + r14*4]
    call sb_push_u64
    inc r14d
    jmp 1b
2:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE


.section .rodata
.Ln_variables: .asciz "debug.variables"
.Ln_watch: .asciz "debug.watch"
.Ln_stack: .asciz "debug.callstack"
.Ln_breakpoints: .asciz "debug.breakpoints"
.Ln_console: .asciz "debug.console"
.Lt_variables: .asciz "Variables"
.Lt_watch: .asciz "Watch"
.Lt_stack: .asciz "Call Stack"
.Lt_breakpoints: .asciz "Breakpoints"
.Lt_console: .asciz "Debug Console"
.Lwatch_prefix: .asciz "watch:"
.Lx_prefix: .asciz "x:"
.Lnot_available: .ascii "not available"
.Lnot_available_end:
.Leq: .asciz " = "
.Lon: .asciz " on "
.Lunnamed: .asciz "session"
.Lslash_t: .asciz "/t"
.Lslash_f: .asciz "/f"
.Lparens: .asciz "()"
.Lif: .asciz "if "
.Lhits: .asciz "hit "
.Llog: .asciz "log "
.Lsep: .asciz "-"
.Lgt: .asciz "> "
.Lph_eval: .asciz "Evaluate in the paused frame"
.Lnone: .asciz ""
.Lq_cond: .asciz "Break when (expression)"
.Lq_hit: .asciz "Break when the hit count is (e.g. >= 5; the debugger's syntax)"
.Lq_log: .asciz "Log message ({expression} is replaced)"
.Lq_function: .asciz "Break on function (name)"
.Lq_watch: .asciz "Watch expression"
.Lf_launch: .asciz "/.rhun/launch.ini"
.Lm_cfg_unread: .asciz "Add Configuration: .rhun/launch.ini could not be read (over 1 MB, or not a file), so it was left as it is"
.Lm_cfg_unwritten: .asciz "Add Configuration: .rhun/launch.ini could not be written"
.Ltemplate: .ascii "# Launch configurations for rhun's debugger: one section per configuration.\n"
    .ascii "# type names a debugger an installed extension provides; other keys are its launch\n"
    .ascii "# arguments. See the guide's Debugging chapter.\n"
    .ascii "#\n# [Run]\n# type = go\n# program = ${project}\n"
.Ltemplate_end:
.Lbutton: .asciz "button "
.Lcolon_sp: .asciz ": "
.Lparen_open: .asciz " ("
.Lplay: .byte 0xe2, 0x96, 0xb6, 0x20, 0
.Lw_starting: .asciz "starting"
.Lw_running: .asciz "running"
.Lw_paused: .asciz "paused"
.Lw_stopping: .asciz "stopping"
.Lw_ended: .asciz "ended"
.Lw_waiting: .asciz "waiting for your answer"
.Ls_inactive: .asciz "inactive"
.Ls_initializing: .asciz "initializing"
.Ls_running: .asciz "running"
.Ls_stopped: .asciz "stopped"
.Lt_continue: .asciz "Continue (F5)"
.Lt_pause: .asciz "Pause (F6)"
.Lt_over: .asciz "Step Over (F10)"
.Lt_into: .asciz "Step Into (F11)"
.Lt_out: .asciz "Step Out (Shift+F11)"
.Lt_restart: .asciz "Restart (Ctrl+Shift+F5)"
.Lt_stop: .asciz "Stop (Shift+F5)"
.p2align 3
# toolbar entries: icon (qword), command, tooltip
tbe_continue: .quad IC_DBG_RESUME, cmd_debug_continue, .Lt_continue
tbe_pause: .quad IC_DBG_PAUSE2, cmd_debug_pause, .Lt_pause
tbe_over: .quad IC_DBG_STEP_OVER, cmd_debug_step_over, .Lt_over
tbe_into: .quad IC_DBG_STEP_INTO, cmd_debug_step_into, .Lt_into
tbe_out: .quad IC_DBG_STEP_OUT, cmd_debug_step_out, .Lt_out
tbe_restart: .quad IC_DBG_RERUN, cmd_debug_restart, .Lt_restart
tbe_stop: .quad IC_DBG_STOP2, cmd_debug_stop, .Lt_stop
.Lp_setvar: .asciz "New value"
.Ls_status_eq: .asciz "status="
.Lp_select: .asciz "Debug configuration"
.Lp_add: .asciz "Add a configuration"
.Lm_add: .asciz "Add Breakpoint"
.Lm_cond: .asciz "Add Conditional Breakpoint..."
.Lm_log: .asciz "Add Logpoint..."
.Lm_editcond: .asciz "Edit Condition..."
.Lm_edithit: .asciz "Edit Hit Count..."
.Lm_editlog: .asciz "Edit Log Message..."
.Lm_disable: .asciz "Enable or Disable Breakpoint"
.Lm_remove: .asciz "Remove Breakpoint"
.p2align 3
menu_add: .quad .Lm_add, mi_add, .Lm_cond, mi_condition, .Lm_log, mi_log, .Lrw_line, 0, .Lm_rtc, mi_rtc, 0
menu_edit: .quad .Lm_editcond, mi_condition, .Lm_edithit, mi_hit, .Lm_editlog, mi_log
    .quad .Lm_disable, mi_disable, .Lm_remove, mi_remove, .Lrw_line, 0, .Lm_rtc, mi_rtc, 0
tb_debug: .quad tbe_continue, tbe_over, tbe_into, tbe_out, tbe_restart, tbe_stop, 0
tb_nodebug: .quad tbe_restart, tbe_stop, 0
term_cmds: .quad cmd_debug_start, cmd_debug_stop, cmd_debug_pause, cmd_debug_continue
    .quad cmd_debug_step_over, cmd_debug_step_into, cmd_debug_step_out, cmd_debug_restart, 0
cat_slots:
    .byte T_FG, T_ERROR, T_MUTED, T_WARNING, T_MUTED, T_ERROR, T_MUTED, T_ACCENT, T_FG
.p2align 3
section_names: .quad .Ln_variables, .Ln_watch, .Ln_stack, .Ln_breakpoints
section_titles: .quad .Lt_variables, .Lt_watch, .Lt_stack, .Lt_breakpoints
sync_fns: .quad sync_vars, sync_watch, sync_stack, sync_bps
section_ops: .quad section_draw, section_key, 0, 0, section_actions, 0
console_ops: .quad console_draw, console_key, 0, dv_close, console_actions, 0
vars_tree_ops: .quad 0, vars_expand, 0, 0, 0, 0, 0, vars_load
stack_tree_ops: .quad stack_activate, 0, 0, 0, 0, 0, 0, 0
bps_tree_ops: .quad bps_activate, 0, 0, bps_check, 0, 0, 0, 0
tree_ops: .quad vars_tree_ops, vars_tree_ops, stack_tree_ops, bps_tree_ops

# the run widget's state (the title bar's run widget, above)
.bss
.p2align 3
rwlab: .zero SB_SIZE            # the configuration F5 starts, NUL-terminated
rwtip: .zero SB_SIZE            # a button's tooltip
rwall: .zero SB_SIZE            # the menu's configurations, one per line
rwnames: .zero SB_SIZE          # its labels, NUL-terminated one after another
rw_offs: .zero 8 * RW_MAX       # each label's offset in rwnames
rw_items: .zero 16 * (RW_MAX + 4)
rw_rects: .zero 16 * 8          # icon (0: the configuration), x, y, w, as last drawn
rw_more_items: .zero 16 * 10
rw_more_run: .zero SB_SIZE
rw_more_debug: .zero SB_SIZE
rw_spin_last: .quad 0
rw_spin: .long 0                # a spinner was drawn this frame
rw_spin_shown: .long 0          # and last frame
rw_more_x: .long 0
rw_more_y: .long 0
rw_n: .long 0
rw_lw: .long 0                  # the configuration's width
rw_count: .long 0               # the configurations the menu lists

.data
.p2align 3
.p2align 3
rw_parts:                       # icon, color (theme slot), command, tooltip
    .long IC_RUN_OUTLINE, T_FG
    .quad cmd_debug_run, .Lrw_run
    .long IC_DBG_BUG, T_FG
    .quad rw_debug, .Lrw_debug
    .long IC_DBG_STOP2, T_ERROR
    .quad cmd_debug_stop, .Lrw_stop
    .long IC_MORE, T_FG
    .quad rw_more, .Lrw_more

.section .rodata
.Lrw_tip_cfg: .asciz "Select Run/Debug Configuration"
.Lrw_run: .asciz "Run "
.Lrw_debug: .asciz "Debug "
.Lrw_stop: .asciz "Stop"
.Lrw_more: .asciz "More"
.Lw_compiling: .asciz "Compiling\342\200\246"
.Lw_starting2: .asciz "Starting\342\200\246"
.Ls_go: .asciz "go"
.Lrw_viewbps2: .asciz "View Breakpoints\342\200\246"
.Lrw_checked: .asciz "  \342\234\223"
.Lrw_line: .asciz ""
.Lrw_edit: .asciz "Edit Configurations\342\200\246"
.Lrw_add: .asciz "Add Configuration\342\200\246"
.Lrw_widget: .asciz "widget "

# the Debug tab's state (above)
.bss
.p2align 3
twb_rects: .zero 16 * TWB_MAX   # its buttons as last drawn: icon, x, y, size
tw_rects: .zero 16 * 4          # its panes: x, y, w, h (frames, the field, watches, variables)
tw_chip_rects: .zero 16 * DS_MAX    # the chips: slot, x, y, w
tw_sub_rects: .zero 16 * 2      # Threads & Variables, Console: x, y, w
tw_closed: .zero 4 * DS_MAX     # the id of the session whose chip each slot's x put away
tw_thr_offs: .zero 8 * TW_THR_MAX
tw_thr_items: .zero 16 * (TW_THR_MAX + 1)
twlab: .zero SB_SIZE            # the focused thread's name
twthr: .zero SB_SIZE            # the thread menu's labels
tw_eval: .zero TF_SIZE          # Evaluate expression or add a watch
frames_tr: .quad 0              # the focused thread's frames
twb_n: .long 0
tw_nchips: .long 0
tw_cur: .long 0                 # the pane with the keys: 0 frames, 1 the field, 2 watches, 3 variables
tw_sub: .long 0                 # 0 Threads & Variables, 1 Console
tw_fgen: .long 0                # the generation the frames were listed at
tw_thr_n: .long 0
rtc_on: .long 0                 # Run to Cursor put a breakpoint at rtc_path:rtc_line
rtc_line: .long 0
eval_on: .long 0                # the first watch is Evaluate Expression's
.p2align 3
rtc_path: .zero SB_SIZE
evalsb: .zero SB_SIZE           # its text
evalinit: .zero SB_SIZE         # the prompt's initial text
evaltmp: .zero SB_SIZE

.data
.p2align 3
tw_ops: .quad tw_draw, tw_key, 0, dv_close, 0, 0
tw_subnames: .quad .Ltw_sub0, .Ltw_sub1
.p2align 3                      # entries of 24 bytes: the quads must not be padded
tw_bar:                         # icon (0: a separator), condition, command, tooltip
    .long IC_DBG_RERUN, TWC_ANY
    .quad tw_rerun, .Ltw_rerun
    .long IC_DBG_STOP2, TWC_LIVE
    .quad cmd_debug_stop, .Lrw_stop
    .long 0, 0
    .quad 0, 0
    .long IC_DBG_RESUME, TWC_PAUSED
    .quad cmd_debug_continue, .Ltw_resume
    .long IC_DBG_PAUSE2, TWC_RUNNING
    .quad cmd_debug_pause, .Ltw_pause
    .long IC_DBG_STEP_OVER, TWC_PAUSED
    .quad cmd_debug_step_over, .Ltw_over
    .long IC_DBG_STEP_INTO, TWC_PAUSED
    .quad cmd_debug_step_into, .Ltw_into
    .long IC_DBG_STEP_OUT, TWC_PAUSED
    .quad cmd_debug_step_out, .Ltw_out
    .long IC_DBG_RUN_CURSOR, TWC_PAUSED
    .quad cmd_debug_run_to_cursor, .Ltw_rtc
    .long 0, 0
    .quad 0, 0
    .long IC_DBG_BPS, TWC_ANY
    .quad cmd_debug_view_breakpoints, .Ltw_viewbps
    .long IC_DBG_MUTE, TWC_MUTE
    .quad cmd_debug_mute_breakpoints, .Ltw_mute
tw_clear:                       # the Console's Clear (not in the bar's loop)
    .long IC_DBG_TRASH, TWC_ANY
    .quad cmd_debug_clear_console, .Ltw_clear

.section .rodata
.Ln_debugger: .asciz "debug.debugger"
.Lt_debugger: .asciz "Debug"
.Ltw_idle: .asciz "No debug sessions"
.Ltw_session: .asciz "Session"
.Ltw_sub0: .asciz "Threads & Variables"
.Ltw_sub1: .asciz "Console"
.Ltw_novalues: .asciz "Variables are not available"
.Ltw_thread_tip: .asciz "Threads"
.ifdef MACOS
.Ltw_eval_ph: .asciz "Evaluate expression (\342\206\251) or add a watch (\342\207\247\342\214\230\342\206\251)"
.else
.Ltw_eval_ph: .asciz "Evaluate expression (Enter) or add a watch (Shift+Ctrl+Enter)"
.endif
.Ltw_rerun: .asciz "Rerun"
.Ltw_resume: .asciz "Resume Program"
.Ltw_pause: .asciz "Pause Program"
.Ltw_over: .asciz "Step Over"
.Ltw_into: .asciz "Step Into"
.Ltw_out: .asciz "Step Out"
.Ltw_rtc: .asciz "Run to Cursor"
.Ltw_viewbps: .asciz "View Breakpoints\342\200\246"
.Ltw_mute: .asciz "Mute Breakpoints"
.Ltw_clear: .asciz "Clear Console"
.Lq_eval: .asciz "Evaluate expression"
.Ltw_button: .asciz "twbutton "
.Ltw_chip: .asciz "chip "
.Ltw_subl: .asciz "sub "
.Ltw_pane: .asciz "pane "
.Ltw_cur: .asciz "twpane="
.Ltw_subeq: .asciz "\ntwsub="
.Lm_rtc: .asciz "Run to Line"
