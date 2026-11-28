# debugger in the editor: breakpoints and the current line in the gutter's left lane (gutter.s
# kinds), the current line's background, and clicks in the lane (toggle; right click: a menu)
.include "rhun.inc"

.equ DG_DOCS, 256

.data
dg_kind_bp: .long 0             # gutter kinds, 0 until registered
dg_kind_line: .long 0
.p2align 3
.globl g_dg_doc, g_dg_line
g_dg_doc: .quad 0               # the paused frame's document and line (zero-based), 0 / -1
g_dg_line: .quad -1
dg_line_slot: .long T_WARNING   # the arrow's color: the top frame, else another one
.bss
.p2align 3
hv_doc: .quad 0                 # the position last evaluated (or found to hold nothing)
hv_pos: .quad 0
hv_gen: .quad 0                 # stop_key when it was
hv_expr: .zero 260
hv_text: .zero 1040             # its answer, empty while none
hv_expr_sb: .zero SB_SIZE
.p2align 3
dg_docs: .zero 16 * DG_DOCS     # documents synced: DOC_id, the generation they were filled at
dg_gen: .long 0                 # the generation of what was last asked for
dg_line_gen: .long 0
tipb: .zero 512

.text

# dg_kinds(): the two gutter kinds, registered once, when a debugger is installed or a breakpoint
#   exists (the left lane is reserved for them from then on)
dg_kinds:
    PROLOGUE
    cmp dword ptr [rip + dg_kind_bp], 0
    jne 9f
    cmp dword ptr [rip + g_ndebuggers], 0
    jne 1f
    cmp dword ptr [rip + g_bp_hooks], 0
    je 9f
1:
    mov edi, GK_PRIO_BREAKPOINT
    mov esi, GK_EMPTY | GK_RESERVE
    lea rdx, [rip + dg_click]
    lea rcx, [rip + dg_tip]
    mov r8d, GS_DOT | (T_ERROR << 8) | (GF_FAINT << 16)
    call gutter_kind
    mov [rip + dg_kind_bp], eax
    mov edi, GK_PRIO_DEBUG_LINE
    xor esi, esi
    lea rdx, [rip + dg_click]
    xor ecx, ecx
    xor r8d, r8d
    call gutter_kind
    mov [rip + dg_kind_line], eax
9:  EPILOGUE

# dg_tick(): every frame: the open documents' breakpoint glyphs and the current line follow the model
FN dg_tick
    PROLOGUE
    call dg_kinds
    cmp dword ptr [rip + dg_kind_bp], 0
    je 9f
    mov eax, [rip + g_bp_gen]
    add eax, [rip + g_dap_gen]
    mov [rip + dg_gen], eax
    # each tab's document
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 5f
    imul rax, rbx, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    mov r12, [rax + TAB_doc]
    test r12, r12
    jz 4f
    cmp qword ptr [r12 + DOC_path], 0
    je 4f
    mov rdi, r12
    call doc_synced
    test eax, eax
    jnz 4f
    mov rdi, r12
    call dg_fill
4:  inc rbx
    jmp 1b
5:  call dg_current
9:  EPILOGUE

# doc_synced(doc) -> eax 1 when its glyphs are of the current generation; else it is marked so.
#   Documents are known by their id, never reused in a run (an address is, after a close)
doc_synced:
    mov rdi, [rdi + DOC_id]
    lea rcx, [rip + dg_docs]
    xor edx, edx
    mov r8d, -1                 # a free slot
1:  cmp edx, DG_DOCS
    jae 3f
    mov rax, [rcx]
    cmp rax, rdi
    je 2f
    test rax, rax
    jnz 11f
    cmp r8d, -1
    jne 11f
    mov r8d, edx
11: add rcx, 16
    inc edx
    jmp 1b
2:  mov eax, [rip + dg_gen]
    cmp [rcx + 8], eax
    mov [rcx + 8], eax
    sete al
    movzx eax, al
    ret
3:  # not seen: a slot (the first free, else the first)
    xor edx, edx
    cmp r8d, -1
    je 4f
    mov edx, r8d
4:  shl edx, 4
    lea rcx, [rip + dg_docs]
    mov [rcx + rdx], rdi
    mov eax, [rip + dg_gen]
    mov [rcx + rdx + 8], eax
    xor eax, eax
    ret

# dg_fill(doc): its breakpoint glyphs, from the breakpoints of its file
dg_fill:
    PROLOGUE
    mov r12, rdi
    mov rdi, r12
    mov esi, [rip + dg_kind_bp]
    call gutter_glyph_clear
    call bp_ensure_loaded
    xor ebx, ebx
1:  call bp_count
    cmp rbx, rax
    jae 9f
    mov rdi, rbx
    call bp_row
    mov r13, rax
    cmp dword ptr [r13 + BP_kind], 0
    jne 2f
    mov rdi, [r13 + BP_path]
    mov rsi, [r12 + DOC_path]
    call strcmp_eq
    test eax, eax
    jz 2f
    mov rdi, r13
    call bp_glyph
    mov ecx, eax
    mov edx, [r13 + BP_line]
    dec edx
    mov rdi, r12
    mov esi, [rip + dg_kind_bp]
    call gutter_glyph_set
2:  inc rbx
    jmp 1b
9:  EPILOGUE

# bp_glyph(bp) -> eax its glyph: a dot (grey when disabled or muted), a ring while the focused session has not
#   verified it, a circle with a bar for a condition or hit count, a diamond for a logpoint, a
#   warning when the adapter rejected it
bp_glyph:
    mov eax, GS_DOT | (T_ERROR << 8)
    cmp qword ptr [rdi + BP_cond], 0
    jne 1f
    cmp qword ptr [rdi + BP_hit], 0
    je 2f
1:  mov eax, GS_CIRCLE_BAR | (T_ERROR << 8)
2:  cmp qword ptr [rdi + BP_log], 0
    je 3f
    mov eax, GS_DIAMOND | (T_ERROR << 8)
3:  cmp dword ptr [rip + g_bp_muted], 0
    jne 31f                     # muted: grey, as a disabled one
    cmp dword ptr [rdi + BP_enabled], 0
    jne 4f
31: and eax, 0xff
    or eax, T_MUTED << 8
    ret
4:  mov ecx, [rip + g_dfocus]
    test ecx, ecx
    js 9f
    mov edx, [rdi + BP_ver + rcx*4]
    cmp edx, 1
    jne 5f
    and eax, 0xff00
    or eax, GS_RING
    ret
5:  cmp edx, 3
    jne 9f
    mov eax, GS_CIRCLE_TRI | (T_WARNING << 8)
9:  ret

# dg_current(): the arrow on the paused frame's line (when its file is open), its background
dg_current:
    PROLOGUE
    mov eax, [rip + g_dap_gen]
    cmp eax, [rip + dg_line_gen]
    je 9f
    mov [rip + dg_line_gen], eax
    xor edi, edi
    mov esi, [rip + dg_kind_line]
    call gutter_glyph_clear
    mov qword ptr [rip + g_dg_doc], 0
    mov qword ptr [rip + g_dg_line], -1
    call dap_focused
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    mov rdi, rbx
    call dap_frame_ptr
    test rax, rax
    jz 9f
    mov r12, rax
    cmp dword ptr [r12 + FR_pathlen], 0
    je 9f
    cmp dword ptr [r12 + FR_line], 0
    je 9f
    mov rdi, rbx
    mov esi, [r12 + FR_path]
    mov edx, [r12 + FR_pathlen]
    call dap_pool_z
    mov rdi, rax
    call app_find_tab
    test rax, rax
    js 9f
    imul rax, rax, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    mov r13, [rax + TAB_doc]
    test r13, r13
    jz 9f
    mov eax, [r12 + FR_line]
    dec eax
    mov [rip + g_dg_doc], r13
    mov [rip + g_dg_line], rax
    mov ecx, GS_ARROW | (T_WARNING << 8)
    cmp dword ptr [rbx + DS_frame], 0
    je 1f
    mov ecx, GS_ARROW | (T_SUCCESS << 8)
1:  mov [rip + dg_line_slot], ecx
    mov rdi, r13
    mov esi, [rip + dg_kind_line]
    mov edx, eax
    call gutter_glyph_set
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# dbg_line_back(doc, line, y, h): the paused frame's line gets a background (the editor's line loop,
#   beside decorations' whole-line backgrounds)
FN dbg_line_back
    cmp [rip + g_dg_doc], rdi
    jne 1f
    cmp [rip + g_dg_line], rsi
    jne 1f
    push rbx
    push r12
    push r13
    mov r12d, edx
    mov r13d, ecx
    mov eax, [rip + dg_line_slot]
    shr eax, 8
    and eax, 0xff
    lea rcx, [rip + g_theme]
    mov edi, [rcx + rax*4]
    mov esi, 0x30
    call color_alpha
    mov r8d, eax
    mov edi, [rip + g_ed_tx]
    sub edi, [rip + g_mt + 4*MI_4]
    mov edx, [rip + g_ed_x]
    add edx, [rip + g_ed_w]
    sub edx, edi
    mov esi, r12d
    mov ecx, r13d
    call gfx_fill
    pop r13
    pop r12
    pop rbx
1:  ret

# dg_click(doc, line, button, glyph): a left press toggles the line's breakpoint; a right press opens
#   the breakpoint menu
dg_click:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rsi, [rbx + DOC_path]
    test rsi, rsi
    jz 9f
    cmp r13d, BTN_RIGHT
    je 2f
    mov rdi, rsi
    lea esi, [r12 + 1]
    call bp_toggle
    jmp 9f
2:  mov rdi, rbx
    mov rsi, r12
    call dview_bp_menu
9:  EPILOGUE

# dg_tip(doc, line, glyph) -> rax the breakpoint's tooltip: its condition, hit count, log message,
#   or what the adapter said
dg_tip:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + DOC_path]
    test rdi, rdi
    jz 8f
    lea esi, [rsi + 1]
    call bp_find
    test eax, eax
    js 8f
    mov edi, eax
    call bp_row
    mov r12, rax
    lea rdi, [rip + tipb]
    lea rsi, [rip + .Lbreakpoint]
    call cstr_copy
    mov r13, rax
    lea r14, [rip + tip_parts]
1:  mov rcx, [r14]
    test rcx, rcx
    jz 3f
    mov rsi, [r12 + rcx]
    test rsi, rsi
    jz 2f
    mov rdi, r13
    mov rsi, [r14 + 8]
    call cstr_copy
    mov rdi, rax
    mov rcx, [r14]
    mov rsi, [r12 + rcx]
    lea rdx, [rip + tipb + 400]
    call copy_max_dg
    mov r13, rax
2:  add r14, 16
    jmp 1b
3:  mov ecx, [rip + g_dfocus]
    test ecx, ecx
    js 4f
    mov rsi, [r12 + BP_msg + rcx*8]
    test rsi, rsi
    jz 4f
    mov rdi, r13
    lea rsi, [rip + .Ldash]
    call cstr_copy
    mov rdi, rax
    mov ecx, [rip + g_dfocus]
    mov rsi, [r12 + BP_msg + rcx*8]
    lea rdx, [rip + tipb + 500]
    call copy_max_dg
4:  lea rax, [rip + tipb]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# copy_max_dg(dst, src, limit) -> end
copy_max_dg:
1:  cmp rdi, rdx
    jae 2f
    mov al, [rsi]
    test al, al
    jz 2f
    mov [rdi], al
    inc rdi
    inc rsi
    jmp 1b
2:  mov byte ptr [rdi], 0
    mov rax, rdi
    ret


# ---------------- hover evaluation ----------------

# dg_hover_tick(): while the focused session is paused and the pointer has rested 500 ms on an
#   identifier (or inside the selection), the expression there is evaluated in the focused frame
FN dg_hover_tick
    PROLOGUE
    mov rbx, [rip + g_hover_doc]
    test rbx, rbx
    jz 8f
    cmp [rip + hv_doc], rbx
    jne 1f
    mov rax, [rip + g_hover_pos]
    cmp [rip + hv_pos], rax
    jne 1f
    call stop_key
    cmp [rip + hv_gen], rax
    je 9f                       # asked already (or nothing to ask) for this position and stop
1:  call time_ms
    sub rax, [rip + g_hover_since]
    cmp rax, HOVER_REST_MS
    jb 9f
    mov [rip + hv_doc], rbx
    mov rax, [rip + g_hover_pos]
    mov [rip + hv_pos], rax
    call stop_key
    mov [rip + hv_gen], rax
    mov byte ptr [rip + hv_text], 0
    mov dword ptr [rip + g_hv_root], -1
    mov dword ptr [rip + g_dirty], 1
    call dap_focused
    test rax, rax
    jz 9f
    mov r12, rax
    cmp dword ptr [r12 + DS_state], DSS_PAUSED
    jne 9f
    mov rdi, rbx
    mov rsi, [rip + g_hover_pos]
    call hover_expr
    test eax, eax
    jz 9f
    mov rdi, r12
    lea rsi, [rip + hv_expr]
    call dap_hover_eval
    EPILOGUE
8:  mov qword ptr [rip + hv_doc], 0
    mov byte ptr [rip + hv_text], 0
    mov dword ptr [rip + g_hv_root], -1
9:  EPILOGUE

# dg_hover_due() -> ms until dg_hover_tick has work, or -1
FN dg_hover_due
    mov rax, [rip + g_hover_doc]
    test rax, rax
    jz 8f
    cmp [rip + hv_doc], rax
    jne 1f
    mov rax, [rip + g_hover_pos]
    cmp [rip + hv_pos], rax
    jne 1f
    push rbx
    call stop_key
    pop rbx
    cmp [rip + hv_gen], rax
    je 8f
1:  push rbx
    call dap_focused
    pop rbx
    test rax, rax
    jz 8f
    cmp dword ptr [rax + DS_state], DSS_PAUSED
    jne 8f
    push rbx
    call time_ms
    pop rbx
    mov rcx, [rip + g_hover_since]
    add rcx, HOVER_REST_MS
    sub rcx, rax
    jns 2f
    xor ecx, ecx
2:  mov eax, ecx
    ret
8:  mov eax, -1
    ret

# stop_key() -> rax which stop the focused session is at: its id << 32 | its epoch (0 without one)
stop_key:
    push rbx
    call dap_focused
    test rax, rax
    jz 1f
    mov ecx, [rax + DS_id]
    shl rcx, 32
    mov eax, [rax + DS_epoch]
    or rax, rcx
1:  pop rbx
    ret

# hover_expr(doc, pos) -> eax 1 with hv_expr (NUL-terminated): the selection when pos is inside it
#   (one line, 256 bytes at most), else the identifier at pos with the member chain to its left
#   (a.b->c)
hover_expr:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + hv_expr_sb]
    call sb_clear
    mov r13, [rbx + DOC_cur]
    mov r14, [rbx + DOC_anchor]
    cmp r13, r14
    je 2f
    jb 1f
    xchg r13, r14
1:  cmp r12, r13
    jb 2f
    cmp r12, r14
    jae 2f
    mov r15, r14
    sub r15, r13
    cmp r15, 256
    ja 2f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r15
    call doc_range
    xor ecx, ecx
11: cmp rcx, r15
    jae 12f
    cmp byte ptr [rax + rcx], 10
    je 2f
    inc rcx
    jmp 11b
12: mov rsi, rax
    mov rdx, r15
    jmp 7f
2:  # the identifier at pos
    mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov r13, rax
    mov rdi, rbx
    mov rsi, r13
    call doc_line_start
    mov r14, r12
    sub r14, rax                # the column
    mov rdi, rbx
    mov rsi, r13
    call doc_line_text
    mov r13, rax                # the line's bytes
    mov r15, rdx                # their length
    cmp r14, r15
    jae 8f
    movzx edi, byte ptr [r13 + r14]
    call hv_ident
    test eax, eax
    jz 8f
    mov rcx, r14                # end
3:  inc rcx
    cmp rcx, r15
    jae 31f
    push rcx
    push rcx
    movzx edi, byte ptr [r13 + rcx]
    call hv_ident
    pop rcx
    pop rcx
    test eax, eax
    jnz 3b
31: mov [rsp], rcx
    mov rcx, r14                # start
4:  test rcx, rcx
    jz 6f
    push rcx
    push rcx
    movzx edi, byte ptr [r13 + rcx - 1]
    call hv_ident
    pop rcx
    pop rcx
    test eax, eax
    jz 5f
    dec rcx
    jmp 4b
5:  # a member chain: "." or "->" before the identifier, then another identifier
    cmp byte ptr [r13 + rcx - 1], '.'
    jne 51f
    cmp rcx, 2
    jb 6f
    lea rdx, [rcx - 1]
    jmp 52f
51: cmp rcx, 3
    jb 6f
    cmp byte ptr [r13 + rcx - 1], '>'
    jne 6f
    cmp byte ptr [r13 + rcx - 2], '-'
    jne 6f
    lea rdx, [rcx - 2]
52: push rcx
    push rdx
    movzx edi, byte ptr [r13 + rdx - 1]
    call hv_ident
    pop rdx
    pop rcx
    test eax, eax
    jz 6f
    mov rcx, rdx
    jmp 4b
6:  lea rsi, [r13 + rcx]
    mov rdx, [rsp]
    sub rdx, rcx
7:  cmp rdx, 255
    ja 8f
    lea rdi, [rip + hv_expr]
    push rdx
    push rdx
    call memcpy
    pop rdx
    pop rdx
    lea rax, [rip + hv_expr]
    mov byte ptr [rax + rdx], 0
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# hv_ident(byte) -> eax 1 for an identifier byte (is_ident, and $ for shells and PHP)
hv_ident:
    cmp edi, '$'
    je 1f
    jmp is_ident
1:  mov eax, 1
    ret

# dg_hover_answer(ptr, len, type ptr, len): the evaluation's answer: "EXPR = VALUE  TYPE"
FN dg_hover_answer
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    lea rdi, [rip + hv_text]
    lea rsi, [rip + hv_expr]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Lhv_eq]
    call cstr_copy
    mov rdi, rax
    mov rsi, r12
    mov rcx, r13
    lea rdx, [rip + hv_text + 900]
    call memcpy_dg
    test r15, r15
    jz 1f
    mov rdi, rax
    lea rsi, [rip + .Lhv_sp]
    call cstr_copy
    mov rdi, rax
    mov rsi, r14
    mov rcx, r15
    lea rdx, [rip + hv_text + 1000]
    call memcpy_dg
1:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# memcpy_dg(dst, src, limit, n) -> end: n bytes (a newline as a space), stopping at limit, NUL
memcpy_dg:
1:  test rcx, rcx
    jz 2f
    cmp rdi, rdx
    jae 2f
    mov al, [rsi]
    cmp al, 10
    jne 11f
    mov al, ' '
11: mov [rdi], al
    inc rdi
    inc rsi
    dec rcx
    jmp 1b
2:  mov byte ptr [rdi], 0
    mov rax, rdi
    ret

# dg_hover_text() -> rax the debugger's hover for the rest position, or 0 (ext_hover_tip shows it
#   alone while paused)
FN dg_hover_text
    xor eax, eax
    mov rcx, [rip + g_hover_doc]
    test rcx, rcx
    jz 1f
    cmp [rip + hv_doc], rcx
    jne 1f
    mov rcx, [rip + g_hover_pos]
    cmp [rip + hv_pos], rcx
    jne 1f
    cmp byte ptr [rip + hv_text], 0
    je 1f
    lea rax, [rip + hv_text]
1:  ret


# ---------------- inline values ----------------

# dg_line_inlays(doc, line): while the focused session is paused, a line of the paused frame's file
#   at or above the paused line ([debug] inline_values_lines at most, 50) gets the values of the variables it names after
#   its end, as JetBrains IDEs show them: "total = 3, i = 2" (a VK_DEBUG inlay, [debug] inline_values).
#   The values are the loaded scopes' variables (Locals first); a name after "." or "->" is a member,
#   not a variable, and one in a comment or a string is prose: both are passed over. The lines stop at
#   the paused line's top-level definition (iv_outside): another function's names are not these.
.equ IV_MAX, 6                  # values on a line
.equ IV_VALUE_MAX, 40           # bytes of one value
.equ IV_TEXT_MAX, 200
FN dg_line_inlays
    PROLOGUE 48
    cmp dword ptr [rip + g_debug_inline_values], 0
    je 9f
    mov [rsp], rdi              # doc
    mov [rsp + 8], rsi          # line
    cmp rdi, [rip + g_dg_doc]
    jne 9f
    mov rax, [rip + g_dg_line]
    cmp rsi, rax
    jg 9f
    sub rax, rsi
    cmp eax, [rip + g_debug_iv_lines]
    jae 9f
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call iv_outside
    test eax, eax
    jnz 9f
    call dap_focused
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp dword ptr [rbx + DS_state], DSS_PAUSED
    jne 9f
    test dword ptr [rbx + DS_flags], DSF_STALE
    jnz 9f
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call syntax_prepare
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call doc_line_text
    cmp rdx, 2048
    ja 9f
    mov r12, rax                # the line's bytes
    mov [rsp + 16], rdx         # their length
    mov rdi, [rsp]              # their syntax classes: a name in a comment or a string is not one
    mov rsi, [rsp + 8]
    mov rdx, r12
    mov rcx, [rsp + 16]
    lea r8, [rip + iv_cls]
    call syntax_line
    mov dword ptr [rip + iv_n], 0
    lea rax, [rip + iv_text]
    mov dword ptr [rax], 0x20202020   # four spaces from the text
    mov dword ptr [rip + iv_len], 4
    xor r13d, r13d              # the scan
1:  cmp r13, [rsp + 16]
    jae 7f
    movzx edi, byte ptr [r12 + r13]
    call is_ident
    test eax, eax
    jnz 2f
    inc r13
    jmp 1b
2:  mov r14, r13                # an identifier: [r14, r13)
3:  inc r13
    cmp r13, [rsp + 16]
    jae 4f
    movzx edi, byte ptr [r12 + r13]
    call is_ident
    test eax, eax
    jnz 3b
4:  movzx eax, byte ptr [r12 + r14]
    cmp eax, '0'                # a number
    jb 41f
    cmp eax, '9'
    jbe 1b
41: test r14, r14               # a member: after "." or "->"
    jz 42f
    movzx eax, byte ptr [r12 + r14 - 1]
    cmp eax, '.'
    je 1b
    cmp eax, '>'
    jne 42f
    cmp r14, 2
    jb 42f
    cmp byte ptr [r12 + r14 - 2], '-'
    je 1b
42: lea rax, [rip + iv_cls]
    movzx eax, byte ptr [rax + r14]
    cmp eax, C_STRING
    je 1b
    cmp eax, C_COMMENT
    je 1b
    cmp eax, C_ESCAPE
    je 1b
    mov rdi, rbx
    lea rsi, [r12 + r14]
    mov rdx, r13
    sub rdx, r14
    call iv_find
    test eax, eax
    js 1b
    mov rdi, rbx
    mov esi, eax
    call iv_add
    cmp dword ptr [rip + iv_n], IV_MAX
    jb 1b
7:  cmp dword ptr [rip + iv_n], 0
    je 9f
    lea rdi, [rip + iv_vi]
    mov rax, [rsp + 16]
    mov [rdi + VI_off], rax     # after the line's text
    lea rax, [rip + iv_text]
    mov [rdi + VI_text], rax
    mov eax, [rip + iv_len]
    mov [rdi + VI_len], eax
    mov dword ptr [rdi + VI_cells], 0
    mov byte ptr [rdi + VI_side], VS_AFTER
    mov byte ptr [rdi + VI_kind], VK_DEBUG
    mov word ptr [rdi + VI_flags], 0
    mov qword ptr [rdi + VI_ref], 0
    COLOR eax, T_INLAY
    mov [rdi + VI_fg], eax
    mov dword ptr [rdi + VI_bg], 0
    mov dword ptr [rdi + VI_prio], 0
    call vt_add
9:  EPILOGUE

# iv_outside(doc, line) -> eax 1 when the line is above the paused line's top-level definition: an
#   unindented line comes between them (the paused line indented: "func", "def", "function" at the
#   left edge start what it is in; a line paused at the left edge has no such limit)
iv_outside:
    PROLOGUE 16
    mov [rsp], rdi
    mov rbx, rsi
    mov r12, [rip + g_dg_line]
    mov rsi, r12
    call iv_left
    test eax, eax
    jnz 8f
    lea r13, [rbx + 1]
1:  cmp r13, r12
    jae 8f
    mov rdi, [rsp]
    mov rsi, r13
    call iv_left
    test eax, eax
    jnz 9f
    inc r13
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# iv_left(doc, line) -> eax 1 when the line has text at its left edge (not blank, not indented)
iv_left:
    PROLOGUE
    call doc_line_text
    xor ecx, ecx
    test rdx, rdx
    jz 8f
    movzx eax, byte ptr [rax]
    cmp eax, ' '
    je 8f
    cmp eax, 9                  # a tab
    je 8f
    cmp eax, 13
    je 8f
    mov ecx, 1
8:  mov eax, ecx
    EPILOGUE

# iv_find(ds, ptr, len) -> eax the variable node of a loaded scope with that name, -1: the first
#   scope's first, so a local hides a global
iv_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, [rbx + DS_vars + VEC_len]
    jae 8f
    imul r15, r14, VN_SIZE
    add r15, [rbx + DS_vars + VEC_ptr]
    cmp dword ptr [r15 + VN_depth], 1
    jne 2f
    mov eax, [r15 + VN_namelen]
    cmp rax, r13
    jne 2f
    mov eax, [r15 + VN_parent]  # under a scope, not a watch's result
    imul rax, rax, VN_SIZE
    add rax, [rbx + DS_vars + VEC_ptr]
    test dword ptr [rax + VN_flags], VNF_WATCH
    jnz 2f
    cmp dword ptr [rax + VN_parent], -1     # a scope: a root a view lists (not the hover's value)
    jne 2f
    mov edi, [r15 + VN_name]
    add rdi, [rbx + DS_strs + SB_ptr]
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jz 2f
    mov eax, r14d
    EPILOGUE
2:  inc r14
    jmp 1b
8:  mov eax, -1
    EPILOGUE

# iv_add(ds, node): "name = value" onto iv_text, once a line and while it fits
iv_add:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    xor ecx, ecx                # listed already
    lea rdx, [rip + iv_nodes]
1:  cmp ecx, [rip + iv_n]
    jae 2f
    cmp [rdx + rcx*4], r12d
    je 9f
    inc ecx
    jmp 1b
2:  imul r13, r12, VN_SIZE
    add r13, [rbx + DS_vars + VEC_ptr]
    mov eax, [r13 + VN_valuelen]
    cmp eax, IV_VALUE_MAX
    jbe 21f
    mov eax, IV_VALUE_MAX
21: mov r14d, eax               # the value's bytes shown
    mov eax, [r13 + VN_namelen]
    add eax, r14d
    add eax, 6                  # ", ", " = ", "…"
    add eax, [rip + iv_len]
    cmp eax, IV_TEXT_MAX
    ja 9f
    mov ecx, [rip + iv_n]
    lea rdx, [rip + iv_nodes]
    mov [rdx + rcx*4], r12d
    inc dword ptr [rip + iv_n]
    test ecx, ecx
    jz 3f
    mov esi, ','
    call iv_byte
    mov esi, ' '
    call iv_byte
3:  mov edi, [r13 + VN_name]
    add rdi, [rbx + DS_strs + SB_ptr]
    mov esi, [r13 + VN_namelen]
    call iv_bytes
    mov esi, ' '
    call iv_byte
    mov esi, '='
    call iv_byte
    mov esi, ' '
    call iv_byte
    mov edi, [r13 + VN_value]
    add rdi, [rbx + DS_strs + SB_ptr]
    mov esi, r14d
    call iv_bytes
    cmp r14d, [r13 + VN_valuelen]
    jae 9f
    mov esi, 0xe2               # "…": the value goes on
    call iv_byte
    mov esi, 0x80
    call iv_byte
    mov esi, 0xa6
    call iv_byte
9:  EPILOGUE

# iv_byte(byte in esi): onto iv_text
iv_byte:
    mov eax, [rip + iv_len]
    cmp eax, IV_TEXT_MAX + 8
    jae 1f
    lea rcx, [rip + iv_text]
    mov [rcx + rax], sil
    inc dword ptr [rip + iv_len]
1:  ret

# iv_bytes(ptr, len): onto iv_text, a line break or tab as a space; a UTF-8 sequence cut at the
#   limit is not left half
iv_bytes:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    xor r13d, r13d
1:  cmp r13d, r12d
    jae 9f
    movzx esi, byte ptr [rbx + r13]
    cmp esi, 10
    je 2f
    cmp esi, 13
    je 2f
    cmp esi, 9
    jne 3f
2:  mov esi, ' '
3:  call iv_byte
    inc r13d
    jmp 1b
9:  # a sequence cut at the end: its lead and continuation bytes go
    mov eax, [rip + iv_len]
    lea rcx, [rip + iv_text]
    mov edx, eax
91: test edx, edx
    jz 99f
    movzx r8d, byte ptr [rcx + rdx - 1]
    cmp r8d, 0x80
    jb 99f                      # ASCII: whole
    cmp r8d, 0xc0
    jae 92f                     # a lead with nothing after it
    dec edx
    jmp 91b
92: dec edx                     # [edx] is the lead: is the sequence whole?
    mov r9d, 2
    cmp r8d, 0xe0
    jb 93f
    mov r9d, 3
    cmp r8d, 0xf0
    jb 93f
    mov r9d, 4
93: mov r10d, eax
    sub r10d, edx
    cmp r10d, r9d
    jae 99f
    mov [rip + iv_len], edx
99: pop r13
    pop r12
    pop rbx
    ret


# ---------------- the hover's card ----------------

# While paused, the value under the pointer shows in a card as code, as JetBrains IDEs and the
# Sublime Debugger show it: its type, then its members, "name: value", indented, two levels down
# (each loaded as the variables are: dap.s keeps the value as a root no view lists), the text in the
# code font and the theme's syntax colors (strings, numbers, constants, types). A value without
# members is one line, "EXPR = VALUE". The card stays while the pointer rests on the expression; it
# takes the place of the tooltip and of the language servers' hover card.
.equ HVC_MAX, 80                # lines
.equ HVC_VALUE_MAX, 160         # bytes of one value
.equ HVK_HEAD, 0                # line kinds: the type
.equ HVK_MEMBER, 1              # "name: value"
.equ HVK_PLAIN, 2               # "EXPR = VALUE"
.equ HVK_MUTED, 3               # loading
.equ HVK_OBJECT, 4              # "name: TYPE", its members below

# dg_hover_card_ds() -> rax the session whose value the card shows now, or 0
FN dg_hover_card_ds
    xor eax, eax
    mov rcx, [rip + g_hover_doc]
    test rcx, rcx
    jz 9f
    cmp [rip + hv_doc], rcx
    jne 9f
    mov rcx, [rip + g_hover_pos]
    cmp [rip + hv_pos], rcx
    jne 9f
    cmp byte ptr [rip + hv_text], 0
    je 9f
    cmp dword ptr [rip + g_hv_root], 0
    jl 9f
    mov edi, [rip + g_dfocus]
    test edi, edi
    js 9f
    cmp edi, [rip + g_hv_slot]
    jne 9f
    sub rsp, 8
    call dap_slot
    add rsp, 8
    cmp dword ptr [rax + DS_state], DSS_PAUSED
    jne 8f
    mov ecx, [rax + DS_epoch]
    cmp ecx, [rip + g_hv_epoch]
    jne 8f
    mov ecx, [rax + DS_vgen]
    cmp ecx, [rip + g_hv_vgen]
    jne 8f
    ret
8:  xor eax, eax
9:  ret

# hvc_push(ptr, len, max): onto hvc_text, a line break or tab as a space, at most max bytes (then "…")
hvc_push:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor ecx, ecx
1:  cmp rcx, r12
    jae 9f
    cmp rcx, r13
    jae 8f
    movzx esi, byte ptr [rbx + rcx]
    cmp esi, 10
    je 2f
    cmp esi, 13
    je 2f
    cmp esi, 9
    jne 3f
2:  mov esi, ' '
3:  push rcx
    push rcx
    lea rdi, [rip + hvc_text]
    call sb_push_byte
    pop rcx
    pop rcx
    inc rcx
    jmp 1b
8:  lea rdi, [rip + hvc_text]
    lea rsi, [rip + .Lhvc_more]
    call sb_push_cstr
9:  pop r13
    pop r12
    pop rbx
    ret

# hvc_line(kind, start): the bytes of hvc_text from start are a line
hvc_line:
    mov eax, [rip + hvc_n]
    cmp eax, HVC_MAX
    jae 1f
    inc dword ptr [rip + hvc_n]
    imul rax, rax, 12
    lea rcx, [rip + hvc_lines]
    mov [rcx + rax], esi
    mov rdx, [rip + hvc_text + SB_len]
    sub edx, esi
    mov [rcx + rax + 4], edx
    mov [rcx + rax + 8], edi
1:  ret

# hvc_str(ds, node, field offset, max): onto hvc_text, the node's string at that field (name, value,
#   type: offset and length one after the other)
hvc_str:
    push rbx
    mov rbx, rcx
    mov eax, esi
    imul rax, rax, VN_SIZE
    add rax, [rdi + DS_vars + VEC_ptr]
    mov esi, [rax + rdx + 4]    # its length
    mov ecx, [rax + rdx]
    mov rax, [rdi + DS_strs + SB_ptr]
    lea rdi, [rax + rcx]
    mov rdx, rbx
    call hvc_push
    pop rbx
    ret

# hvc_build(ds): the card's lines
hvc_build:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + hvc_text]
    call sb_clear
    mov dword ptr [rip + hvc_n], 0
    mov r12d, [rip + g_hv_root]
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    mov r13, rax
    cmp qword ptr [r13 + VN_ref], 0
    jne 2f
    lea rdi, [rip + hvc_text]   # no members: EXPR = VALUE
    lea rsi, [rip + hv_expr]
    call sb_push_cstr
    lea rdi, [rip + hvc_text]
    lea rsi, [rip + .Lhv_eq]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    mov edx, VN_value
    mov ecx, HVC_VALUE_MAX * 4
    call hvc_str
    mov edi, HVK_PLAIN
    xor esi, esi
    call hvc_line
    EPILOGUE
2:  mov edx, VN_type            # the head: its type, else its value
    cmp dword ptr [r13 + VN_typelen], 0
    jne 21f
    mov edx, VN_value
21: mov rdi, rbx
    mov esi, r12d
    mov ecx, HVC_VALUE_MAX
    call hvc_str
    mov edi, HVK_HEAD
    xor esi, esi
    call hvc_line
    mov rdi, rbx
    mov esi, r12d
    mov edx, 1
    call hvc_kids
    EPILOGUE

# hvc_kids(ds, node, depth): its members' lines, theirs under them while they are loaded
hvc_kids:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov rdi, rbx
    mov esi, r12d
    call vn_node
    mov r14d, [rax + VN_kid0]
    test r14d, r14d
    jns 1f
    mov rsi, [rip + hvc_text + SB_len]  # not loaded yet
    mov [rsp], esi
    mov edi, r13d
    call hvc_indent
    lea rdi, [rip + hvc_text]
    lea rsi, [rip + .Lhvc_more]
    call sb_push_cstr
    mov edi, HVK_MUTED
    mov esi, [rsp]
    call hvc_line
    jmp 9f
1:  mov r15d, r14d
    add r15d, [rax + VN_nkids]
2:  cmp r14d, r15d
    jae 9f
    cmp dword ptr [rip + hvc_n], HVC_MAX
    jae 9f
    mov rax, [rip + hvc_text + SB_len]
    mov [rsp], eax              # the line's start
    mov edi, r13d
    call hvc_indent
    mov rdi, rbx
    mov esi, r14d
    mov edx, VN_name
    mov ecx, HVC_VALUE_MAX
    call hvc_str
    lea rdi, [rip + hvc_text]
    lea rsi, [rip + .Lhvc_colon]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r14d
    call vn_node
    mov edx, VN_value
    cmp qword ptr [rax + VN_ref], 0
    je 3f                       # a leaf: its value
    cmp dword ptr [rax + VN_kid0], 0
    jl 3f                       # members not loaded (deeper than the card goes): its value
    cmp dword ptr [rax + VN_typelen], 0
    je 3f
    mov edx, VN_type            # members below: its type
3:  mov [rsp + 4], edx
    mov rdi, rbx
    mov esi, r14d
    mov ecx, HVC_VALUE_MAX
    call hvc_str
    mov edi, HVK_MEMBER
    cmp dword ptr [rsp + 4], VN_type
    jne 31f
    mov edi, HVK_OBJECT
31: mov esi, [rsp]
    call hvc_line
    cmp dword ptr [rsp + 4], VN_type
    jne 4f
    mov rdi, rbx
    mov esi, r14d
    lea edx, [r13 + 1]
    call hvc_kids
4:  inc r14d
    jmp 2b
9:  EPILOGUE

# hvc_indent(depth): two spaces a level
hvc_indent:
    push rbx
    mov ebx, edi
    add ebx, ebx
1:  test ebx, ebx
    jz 2f
    lea rdi, [rip + hvc_text]
    mov esi, ' '
    call sb_push_byte
    dec ebx
    jmp 1b
2:  pop rbx
    ret

# hvc_tok(ptr, len, x, y, h, argb) -> eax the x after it: a token drawn
hvc_tok:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    mov [rsp], r9d
    test r12, r12
    jz 9f
    mov edx, r15d               # the baseline: the text centred in the line
    sub edx, [rip + g_face_code + FACE_ascent]
    sub edx, [rip + g_face_code + FACE_descent]
    sar edx, 1
    add edx, r14d
    add edx, [rip + g_face_code + FACE_ascent]
    lea rdi, [rip + g_face_code]
    mov esi, r13d
    mov rcx, rbx
    mov r8, r12
    mov r9d, [rsp]
    call text_draw
    lea rdi, [rip + g_face_code]
    mov rsi, rbx
    mov rdx, r12
    call text_width
    add r13d, eax
9:  mov eax, r13d
    EPILOGUE

# hvc_word(byte) -> eax 1 for a byte of a name or a type (letters, digits, _ . / *)
hvc_word:
    mov eax, 1
    cmp edi, '_'
    je 1f
    cmp edi, '.'
    je 1f
    cmp edi, '/'
    je 1f
    cmp edi, '0'
    jb 2f
    cmp edi, '9'
    jbe 1f
    or edi, 0x20
    cmp edi, 'a'
    jb 2f
    cmp edi, 'z'
    jbe 1f
2:  xor eax, eax
1:  ret

# hvc_lex(ptr, len, x, y, h): a value drawn token by token in the syntax colors
hvc_lex:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx              # x
    mov [rsp + 4], ecx          # y
    mov [rsp + 8], r8d          # h
    xor r13d, r13d              # the token's start
1:  cmp r13, r12
    jae 9f
    movzx eax, byte ptr [rbx + r13]
    lea r14, [r13 + 1]          # its end
    COLOR r15d, T_SYN + C_PUNCT
    cmp eax, 0x27               # a string: to its closing quote
    je 2f
    cmp eax, '"'
    je 2f
    cmp eax, '`'
    je 2f
    cmp eax, ' '
    je 6f
    cmp eax, '-'
    jne 11f
    cmp r14, r12
    jae 7f
    movzx ecx, byte ptr [rbx + r14]
    sub ecx, '0'
    cmp ecx, 9
    ja 7f
    jmp 3f
11: mov ecx, eax
    sub ecx, '0'
    cmp ecx, 9
    jbe 3f
    mov edi, eax
    call hvc_word
    test eax, eax
    jnz 4f
    jmp 7f
2:  mov ecx, eax                # the quote
21: cmp r14, r12
    jae 22f
    movzx eax, byte ptr [rbx + r14]
    inc r14
    cmp eax, '\\'
    jne 23f
    cmp r14, r12
    jae 22f
    inc r14
    jmp 21b
23: cmp eax, ecx
    jne 21b
22: COLOR r15d, T_SYN + C_STRING
    jmp 7f
3:  cmp r14, r12                # a number: digits, a point, an exponent, hex
    jae 31f
    movzx edi, byte ptr [rbx + r14]
    call hvc_word
    test eax, eax
    jz 31f
    inc r14
    jmp 3b
31: COLOR r15d, T_SYN + C_NUMBER
    jmp 7f
4:  cmp r14, r12                # a word
    jae 41f
    movzx edi, byte ptr [rbx + r14]
    call hvc_word
    test eax, eax
    jz 41f
    inc r14
    jmp 4b
41: lea rdi, [rbx + r13]
    mov rsi, r14
    sub rsi, r13
    call hvc_constant
    COLOR r15d, T_SYN + C_CONSTANT
    test eax, eax
    jnz 7f
    COLOR r15d, T_FG
    movzx eax, byte ptr [rbx + r13]
    cmp eax, 'A'                # a capital or a dot: a type
    jb 42f
    cmp eax, 'Z'
    jbe 43f
42: mov rcx, r13
44: cmp rcx, r14
    jae 7f
    cmp byte ptr [rbx + rcx], '.'
    je 43f
    inc rcx
    jmp 44b
43: COLOR r15d, T_SYN + C_TYPE
    jmp 7f
6:  cmp r14, r12                # spaces
    jae 7f
    cmp byte ptr [rbx + r14], ' '
    jne 7f
    inc r14
    jmp 6b
7:  lea rdi, [rbx + r13]
    mov rsi, r14
    sub rsi, r13
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    mov r8d, [rsp + 8]
    mov r9d, r15d
    call hvc_tok
    mov [rsp], eax
    mov r13, r14
    jmp 1b
9:  mov eax, [rsp]
    EPILOGUE

# hvc_constant(ptr, len) -> eax 1 for true, false, nil, null, None, True, False, undefined
hvc_constant:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + hvc_consts]
1:  mov rdi, [rbx]
    test rdi, rdi
    jz 8f
    call strlen
    cmp rax, r13
    jne 2f
    mov rdi, r12
    mov rsi, [rbx]
    mov rdx, r13
    call memeq
    test eax, eax
    jnz 9f
2:  add rbx, 8
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# hvc_draw_line(i, x, y, h): line i, colored by its kind
hvc_draw_line:
    PROLOGUE 16
    mov r14d, esi
    mov [rsp], edx
    mov [rsp + 4], ecx
    imul rax, rdi, 12
    lea rcx, [rip + hvc_lines]
    add rcx, rax
    mov ebx, [rcx]
    add rbx, [rip + hvc_text + SB_ptr]  # its bytes
    mov r12d, [rcx + 4]
    mov r13d, [rcx + 8]         # its kind
    cmp r13d, HVK_HEAD
    jne 1f
    COLOR r9d, T_SYN + C_TYPE
    jmp 2f
1:  cmp r13d, HVK_MUTED
    jne 3f
    COLOR r9d, T_MUTED
2:  mov rdi, rbx
    mov rsi, r12
    mov edx, r14d
    mov ecx, [rsp]
    mov r8d, [rsp + 4]
    call hvc_tok
    EPILOGUE
3:  cmp r13d, HVK_MEMBER
    je 31f
    cmp r13d, HVK_OBJECT
    jne 6f
31:
    xor ecx, ecx                # a member: its indent and name, ": ", then its value
4:  cmp rcx, r12
    jae 6f
    cmp byte ptr [rbx + rcx], ':'
    jne 41f
    lea rdx, [rcx + 1]
    cmp rdx, r12
    jae 41f
    cmp byte ptr [rbx + rdx], ' '
    je 5f
41: inc rcx
    jmp 4b
5:  mov r15, rcx
    mov rdi, rbx
    mov rsi, rcx
    mov edx, r14d
    mov ecx, [rsp]
    mov r8d, [rsp + 4]
    COLOR r9d, T_FG
    call hvc_tok
    mov r14d, eax
    lea rdi, [rbx + r15]
    mov esi, 2
    mov edx, r14d
    mov ecx, [rsp]
    mov r8d, [rsp + 4]
    COLOR r9d, T_SYN + C_PUNCT
    call hvc_tok
    mov r14d, eax
    lea rbx, [rbx + r15 + 2]
    sub r12, r15
    sub r12, 2
    cmp r13d, HVK_OBJECT        # its type
    jne 6f
    mov rdi, rbx
    mov rsi, r12
    mov edx, r14d
    mov ecx, [rsp]
    mov r8d, [rsp + 4]
    COLOR r9d, T_SYN + C_TYPE
    call hvc_tok
    EPILOGUE
6:  mov rdi, rbx                # a value, or EXPR = VALUE
    mov rsi, r12
    mov edx, r14d
    mov ecx, [rsp]
    mov r8d, [rsp + 4]
    call hvc_lex
    EPILOGUE

# dg_hover_card_draw(): the card, under the pointer (over it without room), at most 60% of the
#   window wide and half of it high
FN dg_hover_card_draw
    PROLOGUE 64
    mov dword ptr [rip + hvc_shown], 0
    call dg_hover_card_ds
    test rax, rax
    jz 9f
    mov rdi, rax
    call hvc_build
    cmp dword ptr [rip + hvc_n], 0
    je 9f
    mov eax, [rip + g_lh]       # a line's height: the editor's ([editor] line_height)
    mov [rsp], eax
    xor ebx, ebx                # the widest line
    xor r12d, r12d
1:  cmp r12d, [rip + hvc_n]
    jae 2f
    imul rax, r12, 12
    lea rcx, [rip + hvc_lines]
    add rcx, rax
    mov esi, [rcx]
    add rsi, [rip + hvc_text + SB_ptr]
    mov edx, [rcx + 4]
    lea rdi, [rip + g_face_code]
    call text_width
    cmp eax, ebx
    cmovg ebx, eax
    inc r12d
    jmp 1b
2:  M r13d, MI_12               # the padding
    lea eax, [rbx + r13*2]
    mov ecx, [rip + g_cv + CV_w]
    imul ecx, ecx, 60
    xor edx, edx
    mov r8d, 100
    xchg eax, ecx
    div r8d
    xchg eax, ecx
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 4], eax          # w
    mov eax, [rip + hvc_n]      # h: the lines that fit in half the window
    imul eax, [rsp]
    lea eax, [rax + r13*2]
    mov ecx, [rip + g_cv + CV_h]
    shr ecx, 1
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 8], eax          # h
    mov eax, [rip + g_hover_x]  # x: at the pointer, inside the window
    mov ecx, [rip + g_cv + CV_w]
    sub ecx, [rsp + 4]
    sub ecx, [rip + g_mt + 4*MI_8]
    cmp eax, ecx
    cmovg eax, ecx
    M ecx, MI_8
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 12], eax
    mov eax, [rip + g_hover_y]  # y: under the pointer, else over it
    add eax, [rip + g_mt + 4*MI_16]
    mov ecx, eax
    add ecx, [rsp + 8]
    cmp ecx, [rip + g_cv + CV_h]
    jle 3f
    mov eax, [rip + g_hover_y]
    sub eax, [rip + g_mt + 4*MI_8]
    sub eax, [rsp + 8]
    M ecx, MI_8
    cmp eax, ecx
    cmovl eax, ecx
3:  mov [rsp + 16], eax
    mov edi, [rsp + 12]
    mov esi, eax
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call ui_card
    mov edi, [rsp + 12]
    mov esi, [rsp + 16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call gfx_clip_push
    xor r12d, r12d
4:  cmp r12d, [rip + hvc_n]
    jae 5f
    mov edx, [rsp]
    imul edx, r12d
    add edx, [rsp + 16]
    add edx, r13d
    mov eax, edx                # past the card's bottom: done
    add eax, [rsp]
    mov ecx, [rsp + 16]
    add ecx, [rsp + 8]
    cmp eax, ecx
    jg 5f
    mov edi, r12d
    mov esi, [rsp + 12]
    add esi, r13d
    mov ecx, [rsp]
    call hvc_draw_line
    inc r12d
    jmp 4b
5:  call gfx_clip_pop
    mov dword ptr [rip + hvc_shown], 1
9:  EPILOGUE

# dg_hover_card_dump(sb): "hover KIND TEXT" per line of the card as last built, "hover none" without
FN dg_hover_card_dump
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + hvc_shown], 0
    jne 1f
    mov rdi, rbx
    lea rsi, [rip + .Lhvc_none]
    call sb_push_cstr
    EPILOGUE
1:  xor r12d, r12d
2:  cmp r12d, [rip + hvc_n]
    jae 9f
    imul rax, r12, 12
    lea r13, [rip + hvc_lines]
    add r13, rax
    mov rdi, rbx
    lea rsi, [rip + .Lhvc_hover]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + 8]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r13]
    add rsi, [rip + hvc_text + SB_ptr]
    mov edx, [r13 + 4]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r12d
    jmp 2b
9:  EPILOGUE

.section .rodata
.Lhv_eq: .asciz " = "
.Lhv_sp: .asciz "  "
.Lbreakpoint: .asciz "Breakpoint"
.Lif: .asciz ", if "
.Lhit: .asciz ", hit count "
.Llog: .asciz ", logs "
.Ldash: .asciz " - "
.p2align 3
tip_parts: .quad BP_cond, .Lif, BP_hit, .Lhit, BP_log, .Llog, 0, 0

# the inline values being built (dg_line_inlays): vt_add keeps a pointer to the text, which stays
# until the next line's are built (vt_line builds one line at a time)
.bss
.p2align 3
iv_vi: .zero VI_SIZE
iv_nodes: .zero 4 * IV_MAX      # the variables listed on the line
iv_n: .long 0
iv_len: .long 0
iv_text: .zero IV_TEXT_MAX + 16
iv_cls: .zero 2049               # the line's syntax classes: its comments and strings name no variables

# the hover's card (above)
.bss
.p2align 3
hvc_text: .zero SB_SIZE         # its lines' bytes
hvc_lines: .zero 12 * HVC_MAX   # each one's start in hvc_text, length, kind
hvc_n: .long 0
hvc_shown: .long 0              # drawn last frame
.data
.p2align 3
hvc_consts: .quad .Lc_true, .Lc_false, .Lc_nil, .Lc_null, .Lc_None, .Lc_True, .Lc_False, .Lc_undef, 0
.section .rodata
.Lhvc_more: .asciz "\342\200\246"
.Lhvc_colon: .asciz ": "
.Lhvc_none: .asciz "hover none\n"
.Lhvc_hover: .asciz "hover "
.Lc_true: .asciz "true"
.Lc_false: .asciz "false"
.Lc_nil: .asciz "nil"
.Lc_null: .asciz "null"
.Lc_None: .asciz "None"
.Lc_True: .asciz "True"
.Lc_False: .asciz "False"
.Lc_undef: .asciz "undefined"
