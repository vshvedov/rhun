# the Breakpoints dialog (View Breakpoints; JetBrains IDEs' Breakpoints window): a modal card over the
# window. At the left, + (a function breakpoint), - (the selected one goes) and every breakpoint with
# its checkbox (the Breakpoints section's tree, exception filters included); at the right, the
# selected one: its file and line, Enabled, its condition, hit count and log message (a logpoint: the
# program does not stop), and the lines around it. A change to a field is applied when the selection
# moves, Enter is pressed in it, or the dialog closes (Done, Escape, x). Tab and Shift+Tab move the
# keys between the list and the fields; in the list, Space turns the selected one on or off, Delete
# removes it, Enter opens its line.
#
#   bpdlg_open()                        the dialog opens (Debug: View Breakpoints)
#   bpdlg_is_open() -> eax              a modal layer (app_modal_open)
#   bpdlg_draw()                        among the overlays, under the palette (its prompts show over it)
#   bpdlg_key(keysym, cp, mods) -> eax  1: the dialog took the key (every key while it is open, but
#                                       while the palette is open over it)
#   bpdlg_field() -> rax                the field with the keys, or 0 (focused_field)
#   bpdlg_dump(sb)                      print-bp-dialog
.include "rhun.inc"

.equ ID_BPD_CLOSE, 0x5f0000
.equ ID_BPD_ADD, 0x5f0001
.equ ID_BPD_REMOVE, 0x5f0002
.equ ID_BPD_ENABLED, 0x5f0003
.equ ID_BPD_DONE, 0x5f0004
.equ ID_BPD_FIELD, 0x5f0010     # + 1 condition, 2 hit count, 3 log message
.equ BPD_PREV, 5                # lines in the preview

.bss
.p2align 3
bpd_tf: .zero TF_SIZE * 4       # the fields (1..3; 0 unused)
bpd_tmp: .zero SB_SIZE
bpd_head: .zero SB_SIZE         # the selected one's heading: its file and line, or its name
bpd_text: .zero SB_SIZE         # the preview's lines
bpd_lines: .zero 16 * BPD_PREV  # each one's offset in bpd_text, length, number
bpd_rects: .zero 16 * 8         # parts as last drawn, for tests: list, fields 1..3, Enabled, Done, -, +
.globl bpd_open
bpd_open: .long 0
bpd_focus: .long 0              # 0 the list, 1..3 a field
bpd_nlines: .long 0
bpd_bpline: .long 0             # its line, in the preview

.text

# bpdlg_open(): the dialog, on the breakpoint the list's cursor is on (else the first)
FN bpdlg_open
    PROLOGUE
    call dview_ensure
    mov edi, 3
    call dview_sync
    mov dword ptr [rip + bpd_open], 1
    mov dword ptr [rip + bpd_focus], 0
    mov dword ptr [rip + bpd_sel], -2   # loaded at the first frame
    xor ebx, ebx
1:  cmp ebx, 4
    jae 2f
    imul rax, rbx, TF_SIZE
    lea rcx, [rip + bpd_tf]
    lea edx, [rbx + ID_BPD_FIELD]
    mov [rcx + rax + TF_id], edx
    inc ebx
    jmp 1b
2:  mov edi, 3
    call dview_tree
    mov rbx, rax
    mov rdi, rbx
    call tree_cursor
    test eax, eax
    jns 9f
    mov rdi, rbx                # on the first row
    call tree_rows
    mov rdi, rbx
    call tree_rows_count
    test rax, rax
    jz 9f
    mov rdi, rbx
    xor esi, esi
    call tree_row
    mov rdi, rbx
    mov esi, eax
    call tree_set_cursor
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

FN bpdlg_is_open
    mov eax, [rip + bpd_open]
    ret

# bpdlg_close(): the fields applied, the dialog gone
bpdlg_close:
    PROLOGUE
    call bpd_apply
    mov dword ptr [rip + bpd_open], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# bpd_tfp(k) -> rax field k's TF
bpd_tfp:
    imul eax, edi, TF_SIZE
    lea rcx, [rip + bpd_tf]
    add rax, rcx
    ret

# bpd_selected() -> eax the id of the breakpoint the list's cursor is on, -1 none (an exception
#   filter, nothing)
bpd_selected:
    PROLOGUE
    mov edi, 3
    call dview_tree
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rdi, rbx
    call tree_cursor
    test eax, eax
    js 8f
    mov rdi, rbx
    mov esi, eax
    call tree_user
    test eax, eax
    jz 8f
    cmp eax, 0x40000000         # an exception filter
    jae 8f
    dec eax
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# bpd_row() -> rax the selected breakpoint's BP*, 0 when it is gone
bpd_row:
    PROLOGUE
    mov edi, [rip + bpd_sel]
    test edi, edi
    js 8f
    call bp_index_of_id
    test eax, eax
    js 8f
    mov edi, eax
    call bp_row
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# bpd_follow(): the selection moved: the old one's fields applied, the new one's loaded
bpd_follow:
    PROLOGUE
    call bpd_selected
    cmp eax, [rip + bpd_sel]
    je 9f
    mov ebx, eax
    call bpd_apply
    mov [rip + bpd_sel], ebx
    call bpd_load
9:  EPILOGUE

# bpd_apply(): the fields that differ from the selected breakpoint's options become them
bpd_apply:
    PROLOGUE
    call bpd_row
    test rax, rax
    jz 9f
    mov rbx, rax
    mov r12d, 1
1:  cmp r12d, 3
    ja 9f
    mov edi, r12d
    call bpd_tfp
    mov rdi, rax
    call tf_text
    mov r13, rax
    mov r14, rdx
    lea rdi, [rip + bpd_tmp]
    call sb_clear
    lea rdi, [rip + bpd_tmp]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    lea rdi, [rip + bpd_tmp]
    xor esi, esi
    call sb_push_byte
    lea rax, [rip + bpd_opts]   # the option as it is
    mov eax, [rax + r12*4 - 4]
    mov rsi, [rbx + rax]
    lea rax, [rip + .Lempty]
    test rsi, rsi
    cmovz rsi, rax
    mov rdi, [rip + bpd_tmp + SB_ptr]
    call strcmp_eq
    test eax, eax
    jnz 2f
    mov edi, [rip + bpd_sel]
    call bp_index_of_id
    test eax, eax
    js 9f
    mov edi, eax
    mov esi, r12d
    mov rdx, [rip + bpd_tmp + SB_ptr]
    call bp_set_option
    call bpd_row                # the row may have moved
    test rax, rax
    jz 9f
    mov rbx, rax
2:  inc r12d
    jmp 1b
9:  EPILOGUE

# bpd_load(): the selected breakpoint's options into the fields, its heading and preview
bpd_load:
    PROLOGUE
    lea rdi, [rip + bpd_head]
    call sb_clear
    mov dword ptr [rip + bpd_nlines], 0
    call bpd_row
    mov rbx, rax
    mov r12d, 1
1:  cmp r12d, 3
    ja 2f
    mov edi, r12d
    call bpd_tfp
    mov r13, rax
    xor esi, esi
    xor edx, edx
    test rbx, rbx
    jz 11f
    lea rax, [rip + bpd_opts]
    mov eax, [rax + r12*4 - 4]
    mov rsi, [rbx + rax]
    test rsi, rsi
    jz 11f
    push rsi
    push rsi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    pop rsi
    pop rsi
11: mov rdi, r13
    call tf_set
    inc r12d
    jmp 1b
2:  test rbx, rbx
    jz 9f
    mov rdi, [rbx + BP_path]    # the heading: the path in the project, and the line
    call strlen
    mov r13, rax
    mov rsi, [rbx + BP_path]
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 22f
    call strlen
    mov r14, rax
    mov rsi, [rbx + BP_path]
    cmp r13, r14
    jbe 22f
    cmp byte ptr [rsi + r14], '/'
    jne 22f
    mov rdi, rsi
    mov rsi, [rip + g_project]
    mov rdx, r14
    call memeq
    mov rsi, [rbx + BP_path]
    test eax, eax
    jz 22f
    lea rsi, [rsi + r14 + 1]
22: lea rdi, [rip + bpd_head]
    call sb_push_cstr
    cmp dword ptr [rbx + BP_kind], 0
    jne 3f
    lea rdi, [rip + bpd_head]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + bpd_head]
    mov esi, [rbx + BP_line]
    call sb_push_u64
    mov rdi, rbx
    call bpd_preview
3:  lea rdi, [rip + bpd_head]
    xor esi, esi
    call sb_push_byte
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# bpd_preview(bp): the lines around its line, from its file
bpd_preview:
    PROLOGUE 16
    mov rbx, rdi
    lea rdi, [rip + bpd_text]
    call sb_clear
    mov rdi, [rbx + BP_path]
    call file_read_all
    test rax, rax
    jz 9f
    mov [rsp], rax
    mov r12, rax                # where we are
    lea r13, [rax + rdx]        # the end
    mov eax, [rbx + BP_line]
    mov [rip + bpd_bpline], eax
    sub eax, 2
    mov ecx, 1
    cmp eax, ecx
    cmovl eax, ecx
    mov r14d, eax               # the first line shown
    mov r15d, 1                 # the line at r12
1:  cmp r15d, r14d              # on to the first line shown
    jae 3f
2:  cmp r12, r13
    jae 8f
    cmp byte ptr [r12], 10
    lea r12, [r12 + 1]
    jne 2b
    inc r15d
    jmp 1b
3:  mov ecx, [rip + bpd_nlines]
    cmp ecx, BPD_PREV
    jae 8f
    cmp r12, r13
    jae 8f
    shl ecx, 4
    lea rdx, [rip + bpd_lines]
    mov rax, [rip + bpd_text + SB_len]
    mov [rdx + rcx], eax
    mov [rdx + rcx + 8], r15d
4:  cmp r12, r13                # the line's bytes, a tab as four spaces
    jae 5f
    movzx esi, byte ptr [r12]
    inc r12
    cmp esi, 10
    je 5f
    cmp esi, 13
    je 4b
    cmp esi, 9
    jne 41f
    lea rdi, [rip + bpd_tmp]
    lea rdi, [rip + bpd_text]
    lea rsi, [rip + .Ltab]
    call sb_push_cstr
    jmp 4b
41: lea rdi, [rip + bpd_text]
    call sb_push_byte
    jmp 4b
5:  mov ecx, [rip + bpd_nlines]
    shl ecx, 4
    lea rdx, [rip + bpd_lines]
    mov rax, [rip + bpd_text + SB_len]
    sub eax, [rdx + rcx]
    mov [rdx + rcx + 4], eax
    inc dword ptr [rip + bpd_nlines]
    inc r15d
    jmp 3b
8:  mov rdi, [rsp]
    call mem_free
9:  EPILOGUE

# bpd_rect(i, x, y, w, h): a part as drawn
bpd_rect:
    shl edi, 4
    lea rax, [rip + bpd_rects]
    mov [rax + rdi], esi
    mov [rax + rdi + 4], edx
    mov [rax + rdi + 8], ecx
    mov [rax + rdi + 12], r8d
    ret

# bpd_press(focus, x, y, w, h): a press there gives that part the keys
bpd_press:
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
    mov [rip + bpd_focus], edi
9:  ret

# bpdlg_draw(): the card, over a dimmed window
FN bpdlg_draw
    PROLOGUE 96
    cmp dword ptr [rip + bpd_open], 0
    je 99f
    mov edi, 3
    call dview_sync
    call bpd_follow
    call palette_is_open        # a prompt over it (+): the card takes no input meanwhile
    mov [rsp + 88], eax
    test eax, eax
    jz 1f
    mov dword ptr [rip + g_block], 1
1:  xor edi, edi
    xor esi, esi
    mov edx, [rip + g_cv + CV_w]
    mov ecx, [rip + g_cv + CV_h]
    mov r8d, 0x40000000
    call gfx_fill
    mov edi, 900                # the card: 900 x 560 points, inside the window
    call sc
    mov ecx, [rip + g_cv + CV_w]
    sub ecx, [rip + g_mt + 4*MI_48]
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 8], eax          # w
    mov edi, 560
    call sc
    mov ecx, [rip + g_cv + CV_h]
    sub ecx, [rip + g_mt + 4*MI_48]
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 12], eax         # h
    mov eax, [rip + g_cv + CV_w]
    sub eax, [rsp + 8]
    sar eax, 1
    mov [rsp], eax              # x
    mov eax, [rip + g_cv + CV_h]
    sub eax, [rsp + 12]
    sar eax, 1
    mov [rsp + 4], eax          # y
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call ui_card
    M eax, MI_16
    mov [rsp + 16], eax         # the padding
    M eax, MI_40
    mov [rsp + 20], eax         # the title row
    # the title, the x
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp]
    add esi, [rsp + 16]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 20]
    lea r8, [rip + .Ltitle]
    COLOR r9d, T_FG
    call ui_text_c
    M ecx, MI_24
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 16]
    sub esi, ecx
    mov edx, [rsp + 20]
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 4]
    mov edi, ID_BPD_CLOSE
    mov r8d, ecx
    mov r9d, IC_CLOSE
    call ui_icon_btn
    test eax, UB_CLICK
    jz 2f
    call bpdlg_close
    jmp 98f
2:  # the footer: Done
    M eax, MI_48
    mov [rsp + 24], eax         # its height
    lea rdi, [rip + g_face_ui]
    lea rsi, [rip + .Ldone]
    mov edx, 4
    call text_width
    M ecx, MI_32
    add eax, ecx
    mov [rsp + 28], eax         # Done's width
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rsp + 16]
    sub esi, eax
    mov [rsp + 32], esi         # Done's x
    M ecx, MI_32
    mov edx, [rsp + 4]
    add edx, [rsp + 12]
    sub edx, [rsp + 24]
    mov eax, [rsp + 24]
    sub eax, ecx
    sar eax, 1
    add edx, eax
    mov [rsp + 36], edx         # its y
    mov edi, 5
    mov esi, [rsp + 32]
    mov ecx, [rsp + 28]
    M r8d, MI_32
    call bpd_rect
    mov edi, ID_BPD_DONE
    mov esi, [rsp + 32]
    mov edx, [rsp + 36]
    mov ecx, [rsp + 28]
    M r8d, MI_32
    call ui_btn
    mov [rsp + 40], eax
    mov edi, [rsp + 32]
    mov esi, [rsp + 36]
    mov edx, [rsp + 28]
    M ecx, MI_32
    M r8d, MI_RADIUS
    COLOR r9d, T_ACCENT
    call gfx_round_rect
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 32]
    mov edx, [rsp + 36]
    mov ecx, [rsp + 28]
    M r8d, MI_32
    lea r9, [rip + .Ldone]
    COLOR eax, T_ACCENT_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    test dword ptr [rsp + 40], UB_CLICK
    jz 3f
    call bpdlg_close
    jmp 98f
3:  # the body: between the title and the footer
    mov eax, [rsp + 4]
    add eax, [rsp + 20]
    mov [rsp + 44], eax         # its top
    mov ecx, [rsp + 4]
    add ecx, [rsp + 12]
    sub ecx, [rsp + 24]
    sub ecx, eax
    mov [rsp + 48], ecx         # its height
    mov eax, [rsp + 8]          # the list: 36% of the width
    imul eax, eax, 36
    xor edx, edx
    mov ecx, 100
    div ecx
    mov [rsp + 52], eax         # the list's width, padding included
    # + and -
    M eax, MI_28
    mov [rsp + 56], eax
    mov esi, [rsp]
    add esi, [rsp + 16]
    mov [rsp + 60], esi
    mov edi, 7
    mov edx, [rsp + 44]
    mov ecx, eax
    mov r8d, eax
    call bpd_rect
    mov edi, ID_BPD_ADD
    mov esi, [rsp + 60]
    mov edx, [rsp + 44]
    mov ecx, [rsp + 56]
    mov r8d, ecx
    mov r9d, IC_PLUS
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_BPD_ADD
    mov esi, [rsp + 60]
    mov edx, [rsp + 44]
    add edx, [rsp + 56]
    mov ecx, [rsp + 56]
    lea r9, [rip + .Ladd_tip]
    call tip_note_text
    test eax, UB_CLICK
    jz 31f
    call cmd_debug_add_function_breakpoint
31: mov esi, [rsp + 60]
    add esi, [rsp + 56]
    add esi, [rip + g_mt + 4*MI_4]
    mov [rsp + 60], esi
    mov edi, 6
    mov edx, [rsp + 44]
    mov ecx, [rsp + 56]
    mov r8d, ecx
    call bpd_rect
    mov edi, ID_BPD_REMOVE
    mov esi, [rsp + 60]
    mov edx, [rsp + 44]
    mov ecx, [rsp + 56]
    mov r8d, ecx
    mov r9d, IC_MINUS
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_BPD_REMOVE
    mov esi, [rsp + 60]
    mov edx, [rsp + 44]
    add edx, [rsp + 56]
    mov ecx, [rsp + 56]
    lea r9, [rip + .Lremove_tip]
    call tip_note_text
    test eax, UB_CLICK
    jz 32f
    call bpd_remove
32: # the list, framed
    mov eax, [rsp + 44]
    add eax, [rsp + 56]
    add eax, [rip + g_mt + 4*MI_4]
    mov [rsp + 64], eax         # its top
    mov ecx, [rsp + 44]
    add ecx, [rsp + 48]
    sub ecx, eax
    mov [rsp + 68], ecx         # its height
    mov edx, [rsp + 52]
    sub edx, [rsp + 16]
    mov [rsp + 72], edx         # its width
    mov edi, [rsp]
    add edi, [rsp + 16]
    mov esi, eax
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    COLOR eax, T_INPUT
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    xor edi, edi
    mov esi, [rsp]
    add esi, [rsp + 16]
    mov edx, [rsp + 64]
    mov ecx, [rsp + 72]
    mov r8d, [rsp + 68]
    call bpd_press
    xor edi, edi
    mov esi, [rsp]
    add esi, [rsp + 16]
    mov edx, [rsp + 64]
    mov ecx, [rsp + 72]
    mov r8d, [rsp + 68]
    call bpd_rect
    mov edi, 3
    call dview_tree
    mov rdi, rax
    M eax, MI_2
    mov esi, [rsp]
    add esi, [rsp + 16]
    add esi, eax
    mov edx, [rsp + 64]
    add edx, eax
    mov ecx, [rsp + 72]
    sub ecx, eax
    sub ecx, eax
    mov r8d, [rsp + 68]
    sub r8d, eax
    sub r8d, eax
    xor r9d, r9d
    cmp dword ptr [rip + bpd_focus], 0
    sete r9b
    call tree_draw
    # the details, at the right
    mov edi, [rsp]
    add edi, [rsp + 52]
    add edi, [rsp + 16]
    mov esi, [rsp + 44]
    mov edx, [rsp + 8]
    sub edx, [rsp + 52]
    sub edx, [rsp + 16]
    sub edx, [rsp + 16]
    mov ecx, [rsp + 48]
    call bpd_details
98: mov eax, [rsp + 88]
    test eax, eax
    jz 99f
    mov dword ptr [rip + g_block], 0
99: EPILOGUE

# bpd_details(x, y, w, h): the selected breakpoint's heading, Enabled, fields and preview
bpd_details:
    PROLOGUE 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    call bpd_row
    test rax, rax
    jnz 1f
    lea rdi, [rip + g_face_small]       # nothing selected, or an exception filter
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    lea r9, [rip + .Lnone_sel]
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    jmp 9f
1:  mov rbx, rax
    mov r12d, [rsp + 4]         # y as it goes down
    lea rdi, [rip + g_face_big]
    mov esi, [rsp]
    mov edx, r12d
    M ecx, MI_32
    mov r8, [rip + bpd_head + SB_ptr]
    COLOR r9d, T_FG
    call ui_text_c
    add r12d, [rip + g_mt + 4*MI_40]
    # Enabled
    M r13d, MI_28
    mov edi, 4
    mov esi, [rsp]
    mov edx, r12d
    mov ecx, [rsp + 8]
    mov r8d, r13d
    call bpd_rect
    mov edi, ID_BPD_ENABLED
    mov esi, [rsp]
    mov edx, r12d
    mov ecx, [rsp + 8]
    mov r8d, r13d
    call ui_btn
    mov [rsp + 16], eax
    mov edi, [rsp]
    mov esi, r12d
    mov edx, [rbx + BP_enabled]
    lea rcx, [rip + .Lenabled]
    call bpd_checkbox
    test dword ptr [rsp + 16], UB_CLICK
    jz 2f
    mov edi, [rip + bpd_sel]
    call bp_index_of_id
    test eax, eax
    js 2f
    mov edi, eax
    xor esi, esi
    cmp dword ptr [rbx + BP_enabled], 0
    sete sil
    call bp_enable
    call bpd_row
    test rax, rax
    jz 9f
    mov rbx, rax
2:  add r12d, r13d
    add r12d, [rip + g_mt + 4*MI_8]
    # the fields
    mov r14d, 1
3:  cmp r14d, 3
    ja 4f
    lea rax, [rip + bpd_labels]
    mov r8, [rax + r14*8 - 8]
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    mov edx, r12d
    M ecx, MI_24
    COLOR r9d, T_FG
    call ui_text_c
    add r12d, [rip + g_mt + 4*MI_24]
    M r13d, MI_28
    mov edi, r14d
    mov esi, [rsp]
    mov edx, r12d
    mov ecx, [rsp + 8]
    mov r8d, r13d
    call bpd_press
    mov edi, r14d
    mov esi, [rsp]
    mov edx, r12d
    mov ecx, [rsp + 8]
    mov r8d, r13d
    call bpd_rect
    mov edi, r14d
    call bpd_tfp
    mov rdi, rax
    xor r9d, r9d
    cmp r14d, [rip + bpd_focus]
    sete r9b
    mov esi, [rsp]
    mov edx, r12d
    mov ecx, [rsp + 8]
    mov r8d, r13d
    lea rax, [rip + bpd_placeholders]
    mov rax, [rax + r14*8 - 8]
    push rax
    push rax
    call ui_textfield
    add rsp, 16
    add r12d, r13d
    add r12d, [rip + g_mt + 4*MI_8]
    inc r14d
    jmp 3b
4:  # the lines around it
    cmp dword ptr [rip + bpd_nlines], 0
    je 9f
    M eax, MI_ROW
    mov ecx, [rip + bpd_nlines]
    imul eax, ecx
    add eax, [rip + g_mt + 4*MI_12]
    mov [rsp + 20], eax         # the preview's height
    mov ecx, [rsp + 4]
    add ecx, [rsp + 12]
    sub ecx, eax
    cmp ecx, r12d
    jl 9f                       # no room
    mov [rsp + 24], ecx         # its top
    mov edi, [rsp]
    mov esi, ecx
    mov edx, [rsp + 8]
    mov ecx, eax
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    COLOR eax, T_BG
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    mov edi, [rsp]
    mov esi, [rsp + 24]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 20]
    call gfx_clip_push
    M r13d, MI_ROW
    mov r12d, [rsp + 24]
    add r12d, [rip + g_mt + 4*MI_6]
    xor r14d, r14d
5:  cmp r14d, [rip + bpd_nlines]
    jae 6f
    mov eax, r14d
    shl eax, 4
    lea r15, [rip + bpd_lines]
    add r15, rax
    mov eax, [r15 + 8]
    cmp eax, [rip + bpd_bpline]
    jne 51f
    mov edi, [rsp]              # its line: tinted, a red dot in the gutter
    mov esi, r12d
    mov edx, [rsp + 8]
    mov ecx, r13d
    COLOR r8d, T_ERROR
    and r8d, 0x00ffffff
    or r8d, 0x26000000
    call gfx_fill
    M ecx, MI_12
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, r13d
    sub edx, ecx
    sar edx, 1
    add edx, r12d
    mov edi, IC_DOT
    COLOR r8d, T_ERROR
    call icon_draw
51: lea rdi, [rip + bpd_tmp]    # the text: its number, then its bytes
    call sb_clear
    lea rdi, [rip + bpd_tmp]
    mov esi, [r15 + 8]
    call sb_push_u64
    lea rdi, [rip + bpd_tmp]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rip + g_face_code]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_32]
    mov edx, r12d
    mov ecx, r13d
    mov r8, [rip + bpd_tmp + SB_ptr]
    COLOR r9d, T_LINENO
    call ui_text_c
    lea rdi, [rip + bpd_tmp]
    call sb_clear
    lea rdi, [rip + bpd_tmp]
    mov esi, [r15]
    add rsi, [rip + bpd_text + SB_ptr]
    mov edx, [r15 + 4]
    call sb_push
    lea rdi, [rip + bpd_tmp]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rip + g_face_code]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_32]
    add esi, [rip + g_mt + 4*MI_40]
    mov edx, r12d
    mov ecx, r13d
    mov r8, [rip + bpd_tmp + SB_ptr]
    COLOR r9d, T_FG
    call ui_text_c
    add r12d, r13d
    inc r14d
    jmp 5b
6:  call gfx_clip_pop
9:  EPILOGUE

# bpd_checkbox(x, y, on, label cstr): a box (filled with a check when on) and its label, MI_28 high
bpd_checkbox:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15, rcx
    M ebx, MI_16
    mov edi, r12d
    M eax, MI_28
    sub eax, ebx
    sar eax, 1
    lea esi, [r13 + rax]
    mov [rsp], esi
    mov edx, ebx
    mov ecx, ebx
    M r8d, MI_4
    COLOR r9d, T_BORDER
    COLOR eax, T_INPUT
    test r14d, r14d
    jz 1f
    COLOR r9d, T_ACCENT
    COLOR eax, T_ACCENT
1:  push rax
    push rax
    call gfx_frame
    add rsp, 16
    test r14d, r14d
    jz 2f
    mov edi, IC_CHECK
    mov esi, r12d
    mov edx, [rsp]
    mov ecx, ebx
    COLOR r8d, T_ACCENT_FG
    call icon_draw
2:  lea rdi, [rip + g_face_small]
    lea esi, [r12 + rbx]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, r13d
    M ecx, MI_28
    mov r8, r15
    COLOR r9d, T_FG
    call ui_text_c
    EPILOGUE

# bpd_remove(): the selected breakpoint goes; the cursor moves on as the tree moves it
bpd_remove:
    PROLOGUE
    mov edi, [rip + bpd_sel]
    test edi, edi
    js 9f
    call bp_index_of_id
    test eax, eax
    js 9f
    mov dword ptr [rip + bpd_sel], -1   # its fields are not applied
    mov edi, eax
    call bp_remove
    mov edi, 3
    call dview_sync
9:  EPILOGUE

# bpdlg_key(keysym, cp, mods) -> eax
FN bpdlg_key
    PROLOGUE
    xor eax, eax
    cmp dword ptr [rip + bpd_open], 0
    je 9f
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call palette_is_open        # the palette's prompt over it takes its keys
    test eax, eax
    jnz 8f
    cmp r12d, KEY_ESCAPE
    jne 1f
    call bpdlg_close
    jmp 7f
1:  cmp r12d, KEY_TAB
    je 2f
    cmp r12d, KEY_ISO_LEFT_TAB
    jne 3f
    mov eax, 3
    jmp 21f
2:  mov eax, 1
    test r14d, MOD_SHIFT
    jz 21f
    mov eax, 3
21: mov ebx, eax
    call bpd_follow
    call bpd_apply
    mov eax, ebx
    add eax, [rip + bpd_focus]
    and eax, 3
    mov [rip + bpd_focus], eax
    jmp 7f
3:  mov eax, [rip + bpd_focus]
    test eax, eax
    jnz 5f
    cmp r12d, KEY_DELETE        # the list
    je 31f
    cmp r12d, KEY_BACKSPACE
    jne 32f
31: call bpd_remove
    jmp 7f
32: cmp r12d, ' '
    jne 34f
    call bpd_row
    test rax, rax
    jz 7f
    mov rbx, rax
    mov edi, [rip + bpd_sel]
    call bp_index_of_id
    test eax, eax
    js 7f
    mov edi, eax
    xor esi, esi
    cmp dword ptr [rbx + BP_enabled], 0
    sete sil
    call bp_enable
    jmp 7f
34: cmp r12d, KEY_RETURN        # its line: the dialog closes, the file opens there
    jne 35f
    call bpd_row
    test rax, rax
    jz 7f
    mov rbx, rax
    call bpdlg_close
    cmp dword ptr [rbx + BP_kind], 0
    jne 7f
    mov rdi, [rbx + BP_path]
    call app_open_file
    test rax, rax
    js 7f
    mov edi, [rbx + BP_line]
    mov esi, 1
    call app_goto_line
    jmp 7f
35: mov edi, 3
    call dview_tree
    mov rdi, rax
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tree_key
    call bpd_follow
    jmp 7f
5:  cmp r12d, KEY_RETURN        # a field: Enter applies it
    je 51f
    cmp r12d, KEY_KP_ENTER
    jne 52f
51: call bpd_apply
    jmp 7f
52: mov edi, eax
    call bpd_tfp
    mov rdi, rax
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
7:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE

# bpdlg_field() -> rax the field with the keys, or 0
FN bpdlg_field
    xor eax, eax
    cmp dword ptr [rip + bpd_open], 0
    je 1f
    mov edi, [rip + bpd_focus]
    test edi, edi
    jz 1f
    jmp bpd_tfp
1:  ret

# bpdlg_dump(sb): "bpdialog open=N focus=N sel=ID", "head=TEXT", "field N TEXT" for 1..3,
#   "part N x y w h" for the parts as last drawn, "preview N TEXT" for its lines
FN bpdlg_dump
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Ld_open]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + bpd_open]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_focus]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + bpd_focus]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_sel]
    call sb_push_cstr
    mov esi, [rip + bpd_sel]
    test esi, esi
    jns 0f
    mov rdi, rbx                # none: -1
    mov esi, '-'
    call sb_push_byte
    mov esi, 1
0:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_head]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + bpd_head + SB_ptr]
    test rsi, rsi
    jz 1f
    call sb_push_cstr
1:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov r12d, 1
2:  cmp r12d, 3
    ja 3f
    mov rdi, rbx
    lea rsi, [rip + .Ld_field]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov edi, r12d
    call bpd_tfp
    mov rdi, rax
    call tf_text
    mov rdi, rbx
    mov rsi, rax
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r12d
    jmp 2b
3:  xor r12d, r12d
4:  cmp r12d, 8
    jae 6f
    mov rdi, rbx
    lea rsi, [rip + .Ld_part]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov r13d, r12d
    shl r13d, 4
    lea r14, [rip + bpd_rects]
    add r14, r13
    xor r15d, r15d
5:  mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r14 + r15*4]
    call sb_push_u64
    inc r15d
    cmp r15d, 4
    jb 5b
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r12d
    jmp 4b
6:  xor r12d, r12d
7:  cmp r12d, [rip + bpd_nlines]
    jae 9f
    mov eax, r12d
    shl eax, 4
    lea r13, [rip + bpd_lines]
    add r13, rax
    mov rdi, rbx
    lea rsi, [rip + .Ld_prev]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r13 + 8]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r13]
    add rsi, [rip + bpd_text + SB_ptr]
    mov edx, [r13 + 4]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r12d
    jmp 7b
9:  EPILOGUE

.data
.p2align 2
bpd_sel: .long -1               # the selected breakpoint's id, -1 none
.p2align 3
bpd_opts: .long BP_cond, BP_hit, BP_log     # the fields' options in BP
.p2align 3
bpd_labels: .quad .Lcond, .Lhit, .Llog
bpd_placeholders: .quad .Lcond_ph, .Lhit_ph, .Llog_ph

.section .rodata
.Ltitle: .asciz "Breakpoints"
.Ldone: .asciz "Done"
.Lenabled: .asciz "Enabled"
.Lcond: .asciz "Condition:"
.Lhit: .asciz "Hit count:"
.Llog: .asciz "Evaluate and log (the program does not stop):"
.Lcond_ph: .asciz "An expression; it stops only when this is true"
.Lhit_ph: .asciz "A count, or an expression such as >= 3"
.Llog_ph: .asciz "A message; {expressions} in braces are evaluated"
.Lnone_sel: .asciz "Select a breakpoint to see its settings"
.Ladd_tip: .asciz "Add a function breakpoint"
.Lremove_tip: .asciz "Remove the breakpoint"
.Lempty: .asciz ""
.Ltab: .asciz "    "
.Ld_open: .asciz "bpdialog open="
.Ld_focus: .asciz " focus="
.Ld_sel: .asciz " sel="
.Ld_head: .asciz "\nhead="
.Ld_field: .asciz "field "
.Ld_part: .asciz "part "
.Ld_prev: .asciz "preview "
