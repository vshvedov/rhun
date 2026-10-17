# the Extensions page (a tab, like chrome://extensions): a card per extension with its On/Off
# switch, Details and Remove; the details show what it may do in plain words, the pin, its
# commands and its own settings ([settings] in its manifest), and Remove.
.include "rhun.inc"
.equ ID_XP, 0x7100              # + 0x00 install, 0x01 back, 0x02 pin, 0x03 remove, 0x04 restart,
                                #   0x10 + i*4 + k: a card's toggle, details, remove, restart
.equ ID_XS, 0x7300              # + i*8 + k: a setting's controls (choice options k..)

.bss
.p2align 3
.globl g_xp_detail
g_xp_detail: .quad 0            # the extension whose details are shown, or 0 for the list
xp_scroll: .long 0
xp_content_h: .long 0
xp_x: .long 0                   # the column
xp_w: .long 0
xp_y: .long 0                   # the running y
xp_bx: .long 0                  # a row of buttons: the next x
xp_prompt_sd: .quad 0           # the text setting being edited
xp_line: .zero SB_SIZE
xp_buf: .zero 256

.text

# cmd_extensions(): the Extensions page, in its tab (focused if it is open)
FN cmd_extensions
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 2f
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_EXT
    je 3f
    inc rbx
    jmp 1b
2:  mov dword ptr [rip + xp_scroll], 0
    xor edi, edi
    mov esi, TAB_EXT
    call app_add_tab
    jmp 9f
3:  mov rdi, rbx
    call app_activate_tab
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# extpage_show(ext): the page with that extension's details (0: the list)
FN extpage_show
    PROLOGUE
    mov [rip + g_xp_detail], rdi
    mov dword ptr [rip + xp_scroll], 0
    call cmd_extensions
    EPILOGUE

# extpage_forget(): the extension shown in detail was removed: back to the list
FN extpage_forget
    mov rax, [rip + g_xp_detail]
    test rax, rax
    jz 1f
    cmp dword ptr [rax + EXT_status], ES_REMOVED
    jne 1f
    mov qword ptr [rip + g_xp_detail], 0
    mov dword ptr [rip + xp_scroll], 0
1:  ret

# extpage_draw(x, y, w, h)
FN extpage_draw
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    COLOR r8d, T_BG
    call gfx_fill
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    # the wheel scrolls; the scroll stays within the content
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call ui_in
    test eax, eax
    jz 1f
    mov eax, [rip + g_scroll_y]
    add [rip + xp_scroll], eax
1:  mov eax, [rip + xp_content_h]
    sub eax, [rsp + 12]
    jns 2f
    xor eax, eax
2:  cmp [rip + xp_scroll], eax
    jle 3f
    mov [rip + xp_scroll], eax
3:  cmp dword ptr [rip + xp_scroll], 0
    jge 4f
    mov dword ptr [rip + xp_scroll], 0
4:  # the column: 720 wide at most, centered
    mov edi, 720
    call sc
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_32]
    sub ecx, [rip + g_mt + 4*MI_32]
    cmp eax, ecx
    cmovg eax, ecx
    mov ecx, 1
    cmp eax, ecx
    cmovl eax, ecx
    mov [rip + xp_w], eax
    mov ecx, [rsp + 8]
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp]
    mov [rip + xp_x], ecx
    mov eax, [rsp + 4]
    add eax, [rip + g_mt + 4*MI_32]
    sub eax, [rip + xp_scroll]
    mov [rip + xp_y], eax
    mov [rsp + 16], eax         # the top, for the content's height
    mov rax, [rip + g_xp_detail]
    test rax, rax
    jz 5f
    call draw_detail
    jmp 6f
5:  call draw_list
6:  mov eax, [rip + xp_y]
    add eax, [rip + g_mt + 4*MI_48]
    sub eax, [rsp + 16]
    mov [rip + xp_content_h], eax
    call gfx_clip_pop
    EPILOGUE

# ---------------- the list ----------------

draw_list:
    PROLOGUE 16
    # "Extensions", and Install from GitHub on the right
    lea rdi, [rip + g_face_big]
    mov esi, [rip + xp_x]
    mov edx, [rip + xp_y]
    M ecx, MI_40
    lea r8, [rip + .Lt_title]
    COLOR r9d, T_FG
    call ui_text_c
    lea rdi, [rip + .Lb_install]
    call label_width
    mov esi, [rip + xp_x]
    add esi, [rip + xp_w]
    sub esi, eax
    mov edx, [rip + xp_y]
    M eax, MI_40
    sub eax, [rip + g_mt + 4*MI_32]
    sar eax, 1
    add edx, eax
    mov edi, ID_XP
    lea rcx, [rip + .Lb_install]
    mov r8d, 1                  # the accent
    call button
    test eax, UB_CLICK
    jz 1f
    call cmd_install_extension
1:  M eax, MI_40
    add [rip + xp_y], eax
    lea rdi, [rip + g_face_small]
    lea rsi, [rip + .Lt_intro]
    COLOR edx, T_MUTED
    mov ecx, MI_28
    call line_text
    M eax, MI_16
    add [rip + xp_y], eax
    # the cards
    xor r13d, r13d              # visible ones drawn
    xor r12d, r12d
2:  cmp r12, [rip + g_exts + VEC_len]
    jae 8f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 2b
    inc r13d
    lea edi, [r12 - 1]
    call draw_card
    jmp 2b
8:  test r13d, r13d
    jnz 9f
    M eax, MI_16
    add [rip + xp_y], eax
    lea rdi, [rip + g_face_ui]
    lea rsi, [rip + .Lt_none]
    COLOR edx, T_MUTED
    mov ecx, MI_28
    call line_text
9:  EPILOGUE

# draw_card(index): rbx the EXT
draw_card:
    PROLOGUE 48
    mov r15d, edi
    shl r15d, 2
    add r15d, ID_XP + 0x10      # this card's ids
    # its height: 28 badge row, 24 description, a problem line, 32 buttons, padding
    M eax, MI_16
    mov r12d, eax               # padding
    M r13d, MI_28
    add r13d, [rip + g_mt + 4*MI_4]     # under the description's lines (counted below)
    add r13d, [rip + g_mt + 4*MI_32]
    add r13d, [rip + g_mt + 4*MI_8]
    add r13d, r12d
    add r13d, r12d
    mov rdi, rbx
    call ext_problem
    mov [rsp], rax
    test rax, rax
    jz 1f
    add r13d, [rip + g_mt + 4*MI_24]
1:  # a description longer than the card is wide takes more lines
    lea rdi, [rip + g_face_small]
    mov rsi, [rbx + EXT_desc]
    test rsi, rsi
    jnz 11f
    lea rsi, [rip + .Lt_no_desc]
11: mov edx, [rip + xp_x]
    add edx, r12d
    call para_lines
    imul eax, [rip + g_mt + 4*MI_20]
    add r13d, eax
    mov eax, [rip + xp_y]
    mov [rsp + 8], eax          # the card's top
    mov edi, [rip + xp_x]
    mov esi, eax
    mov edx, [rip + xp_w]
    mov ecx, r13d
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    COLOR eax, T_PANEL
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    # badge, title, version
    mov eax, [rip + xp_x]
    add eax, r12d
    mov [rsp + 12], eax         # the inner x
    mov edi, eax
    mov esi, [rsp + 8]
    add esi, r12d
    M edx, MI_28
    mov rcx, rbx
    call badge
    mov rdi, rbx
    call ext_title
    mov r8, rax
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 12]
    add esi, [rip + g_mt + 4*MI_28]
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, [rsp + 8]
    add edx, r12d
    M ecx, MI_28
    COLOR r9d, T_FG
    call ui_text_c
    add eax, [rip + g_mt + 4*MI_12]
    mov esi, eax
    lea rdi, [rip + g_face_small]
    mov edx, [rsp + 8]
    add edx, r12d
    M ecx, MI_28
    mov r8, [rbx + EXT_version]
    test r8, r8
    jnz 2f
    lea r8, [rip + .Lempty]
2:  COLOR r9d, T_MUTED
    call ui_text_c
    # the switch on the right
    mov edi, r15d
    mov esi, [rip + xp_x]
    add esi, [rip + xp_w]
    sub esi, r12d
    sub esi, [rip + g_mt + 4*MI_20]
    sub esi, [rip + g_mt + 4*MI_14]
    mov edx, [rsp + 8]
    add edx, r12d
    add edx, [rip + g_mt + 4*MI_4]
    mov ecx, [rbx + EXT_disabled]
    xor ecx, 1
    call ui_toggle
    test eax, eax
    jz 3f
    mov rdi, rbx
    mov esi, [rbx + EXT_disabled]
    xor esi, 1
    call ext_set_disabled
3:  # the description
    mov eax, [rsp + 8]
    add eax, r12d
    add eax, [rip + g_mt + 4*MI_28]
    mov [rip + xp_y], eax
    mov eax, [rsp + 12]
    mov [rsp + 16], eax
    mov rsi, [rbx + EXT_desc]
    test rsi, rsi
    jnz 4f
    lea rsi, [rip + .Lt_no_desc]
4:  lea rdi, [rip + g_face_small]
    COLOR edx, T_MUTED
    mov ecx, MI_20
    mov r8d, [rsp + 12]
    call para
    mov eax, [rip + g_mt + 4*MI_4]
    add [rip + xp_y], eax
    # a problem, in red
    mov rsi, [rsp]
    test rsi, rsi
    jz 5f
    lea rdi, [rip + g_face_small]
    COLOR edx, T_ERROR
    mov ecx, MI_24
    mov r8d, [rsp + 12]
    call text_at
5:  # Details, Remove, and Restart after a problem
    M eax, MI_8
    add [rip + xp_y], eax
    mov eax, [rsp + 12]
    mov [rip + xp_bx], eax
    lea edi, [r15 + 1]
    lea rsi, [rip + .Lb_details]
    xor edx, edx
    call row_button
    test eax, UB_CLICK
    jz 6f
    mov [rip + g_xp_detail], rbx
    mov dword ptr [rip + xp_scroll], 0
    mov dword ptr [rip + g_dirty], 1
6:  lea edi, [r15 + 2]
    lea rsi, [rip + .Lb_remove]
    xor edx, edx
    call row_button
    test eax, UB_CLICK
    jz 7f
    mov rdi, rbx
    call ext_remove_ask
7:  cmp qword ptr [rsp], 0
    je 8f
    cmp dword ptr [rbx + EXT_disabled], 0
    jne 8f
    lea edi, [r15 + 3]
    lea rsi, [rip + .Lb_restart]
    xor edx, edx
    call row_button
    test eax, UB_CLICK
    jz 8f
    mov rdi, rbx
    call ext_restart_now
8:  mov eax, [rsp + 8]
    add eax, r13d
    add eax, [rip + g_mt + 4*MI_12]
    mov [rip + xp_y], eax
    EPILOGUE

# ---------------- the details ----------------

draw_detail:
    PROLOGUE 32
    mov rbx, [rip + g_xp_detail]
    # "← Extensions"
    lea rdi, [rip + .Lt_title]
    call label_width
    add eax, [rip + g_mt + 4*MI_28]
    mov r12d, eax
    mov edi, ID_XP + 1
    mov esi, [rip + xp_x]
    mov edx, [rip + xp_y]
    mov ecx, r12d
    M r8d, MI_28
    call ui_btn
    mov [rsp], eax
    mov edi, [rip + xp_x]
    mov esi, [rip + xp_y]
    M edx, MI_20
    M ecx, MI_28
    mov r8d, IC_BACK
    COLOR r9d, T_ACCENT
    call draw_icon
    lea rdi, [rip + g_face_ui]
    mov esi, [rip + xp_x]
    add esi, [rip + g_mt + 4*MI_24]
    mov edx, [rip + xp_y]
    M ecx, MI_28
    lea r8, [rip + .Lt_title]
    COLOR r9d, T_ACCENT
    call ui_text_c
    test dword ptr [rsp], UB_CLICK
    jz 1f
    mov qword ptr [rip + g_xp_detail], 0
    mov dword ptr [rip + xp_scroll], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
1:  M eax, MI_40
    add [rip + xp_y], eax
    # badge, title, switch
    mov edi, [rip + xp_x]
    mov esi, [rip + xp_y]
    M edx, MI_40
    mov rcx, rbx
    call badge
    mov rdi, rbx
    call ext_title
    mov r8, rax
    lea rdi, [rip + g_face_big]
    mov esi, [rip + xp_x]
    add esi, [rip + g_mt + 4*MI_40]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rip + xp_y]
    M ecx, MI_40
    COLOR r9d, T_FG
    call ui_text_c
    mov edi, ID_XP + 5
    mov esi, [rip + xp_x]
    add esi, [rip + xp_w]
    sub esi, [rip + g_mt + 4*MI_20]
    sub esi, [rip + g_mt + 4*MI_14]
    mov edx, [rip + xp_y]
    add edx, [rip + g_mt + 4*MI_8]
    mov ecx, [rbx + EXT_disabled]
    xor ecx, 1
    call ui_toggle
    test eax, eax
    jz 2f
    mov rdi, rbx
    mov esi, [rbx + EXT_disabled]
    xor esi, 1
    call ext_set_disabled
2:  M eax, MI_48
    add [rip + xp_y], eax
    # "Version V · by OWNER · github.com/OWNER/NAME"
    lea rdi, [rip + xp_line]
    call sb_clear
    lea rdi, [rip + xp_line]
    lea rsi, [rip + .Lt_version]
    call sb_push_cstr
    mov rsi, [rbx + EXT_version]
    test rsi, rsi
    jz 3f
    lea rdi, [rip + xp_line]
    call sb_push_cstr
3:  lea rdi, [rip + xp_line]
    lea rsi, [rip + .Lt_source]
    call sb_push_cstr
    mov rdi, rbx
    call ext_full_name
    lea rdi, [rip + xp_line]
    mov rsi, rax
    call sb_push_cstr
    call line_cstr
    mov rsi, rax
    lea rdi, [rip + g_face_small]
    COLOR edx, T_MUTED
    mov ecx, MI_24
    call line_text
    mov rsi, [rbx + EXT_desc]
    test rsi, rsi
    jz 4f
    lea rdi, [rip + g_face_ui]
    COLOR edx, T_FG
    mov ecx, MI_24
    mov r8d, [rip + xp_x]
    call para
    mov eax, [rip + g_mt + 4*MI_4]
    add [rip + xp_y], eax
4:  # a problem, with Restart
    mov rdi, rbx
    call ext_problem
    test rax, rax
    jz 5f
    mov rsi, rax
    lea rdi, [rip + g_face_ui]
    COLOR edx, T_ERROR
    mov ecx, MI_28
    call line_text
    cmp dword ptr [rbx + EXT_disabled], 0
    jne 5f
    mov eax, [rip + xp_x]
    mov [rip + xp_bx], eax
    mov edi, ID_XP + 4
    lea rsi, [rip + .Lb_restart]
    xor edx, edx
    call row_button
    test eax, UB_CLICK
    jz 41f
    mov rdi, rbx
    call ext_restart_now
41: M eax, MI_8
    add [rip + xp_y], eax
5:  # what it may do
    lea rsi, [rip + .Ls_permissions]
    call section
    mov rdi, rbx
    call draw_permissions
    # the pin
    lea rsi, [rip + .Ls_toolbar]
    call section
    lea rdi, [rip + g_face_ui]
    lea rsi, [rip + .Lt_pin]
    COLOR edx, T_FG
    mov ecx, MI_28
    mov r8d, [rip + xp_x]
    call text_at_keep
    mov edi, ID_XP + 2
    mov esi, [rip + xp_x]
    add esi, [rip + xp_w]
    sub esi, [rip + g_mt + 4*MI_20]
    sub esi, [rip + g_mt + 4*MI_14]
    mov edx, [rip + xp_y]
    add edx, [rip + g_mt + 4*MI_4]
    mov ecx, [rbx + EXT_pinned]
    call ui_toggle
    test eax, eax
    jz 6f
    mov rdi, rbx
    mov esi, [rbx + EXT_pinned]
    xor esi, 1
    call ext_set_pinned
6:  M eax, MI_28
    add [rip + xp_y], eax
    lea rdi, [rip + g_face_small]
    lea rsi, [rip + .Lt_pin_desc]
    COLOR edx, T_MUTED
    mov ecx, MI_24
    call line_text
    # its commands
    mov rdi, rbx
    call draw_commands
    # its own settings
    cmp qword ptr [rbx + EXT_sdefs + VEC_len], 0
    je 7f
    lea rsi, [rip + .Ls_settings]
    call section
    mov rdi, rbx
    call draw_settings
7:  # Remove
    M eax, MI_24
    add [rip + xp_y], eax
    mov eax, [rip + xp_x]
    mov [rip + xp_bx], eax
    mov edi, ID_XP + 3
    lea rsi, [rip + .Lb_remove_ext]
    mov edx, 2                  # in red
    call row_button
    test eax, UB_CLICK
    jz 8f
    mov rdi, rbx
    call ext_remove_ask
8:  M eax, MI_32
    add [rip + xp_y], eax
    EPILOGUE

# draw_permissions(ext): ext_needs_words split at ", " into a line each, then how rhun holds it
draw_permissions:
    PROLOGUE 16
    mov rbx, rdi
    lea rdi, [rip + xp_line]
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + xp_line]
    call ext_needs_words
    call line_cstr
    mov r12, rax
1:  cmp byte ptr [r12], 0
    je 5f
    # up to ", " or the end
    xor ecx, ecx
2:  cmp byte ptr [r12 + rcx], 0
    je 3f
    cmp byte ptr [r12 + rcx], ','
    jne 21f
    cmp byte ptr [r12 + rcx + 1], ' '
    je 3f
21: inc rcx
    jmp 2b
3:  mov r13, rcx
    mov al, [r12 + rcx]
    mov [rsp], al
    mov byte ptr [r12 + rcx], 0
    # "•  Capital first"
    lea rdi, [rip + xp_buf]
    lea rsi, [rip + .Lbullet]
    call cstr_copy
    mov rdi, rax
    mov rsi, r12
    mov rcx, 200
    call cstr_copy_cap
    lea rsi, [rip + xp_buf]
    lea rdi, [rip + g_face_ui]
    COLOR edx, T_FG
    mov ecx, MI_28
    call line_text
    mov al, [rsp]
    mov [r12 + r13], al
    lea r12, [r12 + r13]
    cmp byte ptr [r12], 0
    je 5f
    add r12, 2
    jmp 1b
5:  # rhun holds it to them, or says it cannot here
    lea rsi, [rip + .Lt_held]
.ifdef WINDOWS
    lea rsi, [rip + .Lt_windows]
.endif
    cmp qword ptr [rbx + EXT_confine_why], 0
    je 6f
    lea rsi, [rip + .Lt_not_held]
6:  lea rdi, [rip + g_face_small]
    COLOR edx, T_MUTED
    mov ecx, MI_24
    call line_text
    EPILOGUE

# cstr_copy_cap(dst, src, max): src with its first letter upper case, at most max bytes
cstr_copy_cap:
    xor edx, edx
1:  cmp rdx, rcx
    jae 2f
    mov al, [rsi + rdx]
    test al, al
    jz 2f
    test edx, edx
    jnz 11f
    cmp al, 'a'
    jb 11f
    cmp al, 'z'
    ja 11f
    sub al, 32
11: mov [rdi + rdx], al
    inc rdx
    jmp 1b
2:  mov byte ptr [rdi + rdx], 0
    ret

# draw_commands(ext): "Commands": each title and its keys
draw_commands:
    PROLOGUE 16
    mov rbx, rdi
    mov rax, rbx
    lea rcx, [rip + g_exts]
    sub rax, [rcx + VEC_ptr]
    xor edx, edx
    mov ecx, EXT_SIZE
    div rcx
    mov r14, rax                # its index
    xor r13d, r13d              # shown
    xor r12d, r12d
1:  cmp r12, [rip + g_ext_cmds + VEC_len]
    jae 8f
    mov rax, [rip + g_ext_owner + VEC_ptr]
    cmp [rax + r12*8], r14
    jne 7f
    test r13d, r13d
    jnz 2f
    lea rsi, [rip + .Ls_commands]
    call section
2:  inc r13d
    imul r15, r12, CMD_SIZE
    add r15, [rip + g_ext_cmds + VEC_ptr]
    # the title without " (Extension)"
    mov rsi, [r15 + CMD_title]
    lea rdi, [rip + xp_buf]
    call copy_title
    lea rdi, [rip + g_face_ui]
    lea rsi, [rip + xp_buf]
    COLOR edx, T_FG
    mov ecx, MI_28
    mov r8d, [rip + xp_x]
    call text_at_keep
    mov rdi, r15
    call keys_for
    test rax, rax
    jz 3f
    mov [rsp], rax
    mov rdi, rax
    call label_width_small
    mov esi, [rip + xp_x]
    add esi, [rip + xp_w]
    sub esi, eax
    lea rdi, [rip + g_face_small]
    mov edx, [rip + xp_y]
    M ecx, MI_28
    mov r8, [rsp]
    COLOR r9d, T_MUTED
    call ui_text_c
3:  M eax, MI_28
    add [rip + xp_y], eax
7:  inc r12
    jmp 1b
8:  EPILOGUE

# copy_title(dst, title): up to the last " (" (the extension's name that the palette adds)
copy_title:
    push rbx
    mov rbx, rdi
    mov rdi, rsi
    push rsi
    call strlen
    pop rsi
    mov rcx, rax
1:  cmp rcx, 2
    jb 2f
    cmp byte ptr [rsi + rcx - 2], ' '
    jne 11f
    cmp byte ptr [rsi + rcx - 1], '('
    je 3f
11: dec rcx
    jmp 1b
2:  mov rcx, rax                # no suffix: the whole title
    jmp 4f
3:  sub rcx, 2
4:  cmp rcx, 60
    jbe 5f
    mov ecx, 60
5:  mov rdi, rbx
    mov rdx, rcx
    push rdx
    push rdx
    call memcpy
    pop rdx
    pop rdx
    mov byte ptr [rbx + rdx], 0
    pop rbx
    ret

# draw_settings(ext): a row per setting: its title and description, its control on the right
draw_settings:
    PROLOGUE 48
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + EXT_sdefs + VEC_len]
    jae 9f
    imul r13, r12, SD_SIZE
    add r13, [rbx + EXT_sdefs + VEC_ptr]
    mov r15d, r12d
    shl r15d, 3
    add r15d, ID_XS             # this row's ids
    inc r12
    mov eax, [rip + xp_y]
    mov [rsp], eax              # the row's top
    # the title (or the key) and the description under it
    mov rsi, [r13 + SD_title]
    test rsi, rsi
    jnz 2f
    mov rsi, [r13 + SD_key]
2:  lea rdi, [rip + g_face_ui]
    COLOR edx, T_FG
    mov ecx, MI_28
    mov r8d, [rip + xp_x]
    call text_at_keep
    mov rsi, [r13 + SD_desc]
    test rsi, rsi
    jz 3f
    M eax, MI_24
    add [rip + xp_y], eax
    lea rdi, [rip + g_face_small]
    COLOR edx, T_MUTED
    mov ecx, MI_24
    mov r8d, [rip + xp_x]
    call text_at_keep
    M eax, MI_4
    sub [rip + xp_y], eax
3:  # the control, on the first line's right
    mov eax, [rip + xp_y]
    mov [rsp + 4], eax
    mov eax, [rsp]
    mov [rip + xp_y], eax
    mov eax, [r13 + SD_type]
    cmp eax, SDT_BOOL
    je .Lds_bool
    cmp eax, SDT_INT
    je .Lds_int
    cmp eax, SDT_CHOICE
    je .Lds_choice
    jmp .Lds_string
.Lds_bool:
    mov rdi, [r13 + SD_value]
    lea rsi, [rip + .Lyes]
    call strcmp_eq
    mov [rsp + 8], eax
    mov edi, r15d
    mov esi, [rip + xp_x]
    add esi, [rip + xp_w]
    sub esi, [rip + g_mt + 4*MI_20]
    sub esi, [rip + g_mt + 4*MI_14]
    mov edx, [rip + xp_y]
    add edx, [rip + g_mt + 4*MI_4]
    mov ecx, [rsp + 8]
    call ui_toggle
    test eax, eax
    jz .Lds_next
    lea rdx, [rip + .Lyes]
    cmp dword ptr [rsp + 8], 0
    je 4f
    lea rdx, [rip + .Lno]
4:  mov rdi, rbx
    mov rsi, r13
    call ext_setting_set
    jmp .Lds_next
.Lds_int:
    # [-] value [+]
    mov rdi, [r13 + SD_value]
    call strlen
    mov rdi, [r13 + SD_value]
    mov rsi, rax
    call parse_u64
    mov [rsp + 8], eax
    M eax, MI_28
    mov ecx, [rip + xp_x]
    add ecx, [rip + xp_w]
    sub ecx, eax
    mov [rsp + 12], ecx         # the + button's x
    sub ecx, [rip + g_mt + 4*MI_48]
    mov [rsp + 16], ecx         # the value's x
    sub ecx, eax
    mov [rsp + 20], ecx         # the - button's x
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 16]
    mov edx, [rip + xp_y]
    M ecx, MI_48
    M r8d, MI_28
    mov r9, [r13 + SD_value]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    lea edi, [r15 + 1]
    mov esi, [rsp + 20]
    mov edx, IC_MINUS
    call icon_button
    test eax, UB_CLICK
    jz 5f
    mov eax, [rsp + 8]
    dec eax
    jmp 6f
5:  lea edi, [r15 + 2]
    mov esi, [rsp + 12]
    mov edx, IC_PLUS
    call icon_button
    test eax, UB_CLICK
    jz .Lds_next
    mov eax, [rsp + 8]
    inc eax
6:  cmp eax, [r13 + SD_min]
    jge 61f
    mov eax, [r13 + SD_min]
61: cmp eax, [r13 + SD_max]
    jle 62f
    mov eax, [r13 + SD_max]
62: lea rdi, [rip + xp_buf]
    mov esi, eax
    call fmt_u64
    mov byte ptr [rdi], 0
    mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + xp_buf]
    call ext_setting_set
    jmp .Lds_next
.Lds_choice:
    # the options as a row of buttons, right-aligned; the chosen one highlighted
    mov rdi, r13
    call choice_width
    mov ecx, [rip + xp_x]
    add ecx, [rip + xp_w]
    sub ecx, eax
    mov [rip + xp_bx], ecx
    mov r14, [r13 + SD_opts]
    mov dword ptr [rsp + 8], 0  # the option's number
7:  test r14, r14
    jz .Lds_next
    cmp byte ptr [r14], 0
    je .Lds_next
    mov rdi, r14
    call word_cstr              # the option into xp_buf, r14 after it
    mov r14, rdx
    mov rdi, [r13 + SD_value]
    lea rsi, [rip + xp_buf]
    call strcmp_eq
    mov edx, 3                  # chosen
    test eax, eax
    jnz 71f
    xor edx, edx
71: mov edi, r15d
    add edi, 3
    add edi, [rsp + 8]
    inc dword ptr [rsp + 8]
    lea rsi, [rip + xp_buf]
    call row_button
    test eax, UB_CLICK
    jz 7b
    mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + xp_buf]
    call ext_setting_set
    jmp 7b
.Lds_string:
    # the value, and Change
    lea rdi, [rip + .Lb_change]
    call label_width
    mov ecx, [rip + xp_x]
    add ecx, [rip + xp_w]
    sub ecx, eax
    mov [rip + xp_bx], ecx
    mov [rsp + 8], ecx
    # the value, right-aligned before the button, at most a third of the column
    mov rdi, [r13 + SD_value]
    call label_width
    mov ecx, [rip + xp_w]
    mov r8d, 3
    push rax
    mov eax, ecx
    xor edx, edx
    div r8d
    mov ecx, eax
    pop rax
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 12], eax
    mov edi, [rsp + 8]
    sub edi, eax
    sub edi, [rip + g_mt + 4*MI_8]
    mov [rsp + 16], edi
    mov esi, [rip + xp_y]
    mov edx, eax
    M ecx, MI_28
    call gfx_clip_push
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 16]
    mov edx, [rip + xp_y]
    M ecx, MI_28
    mov r8, [r13 + SD_value]
    COLOR r9d, T_MUTED
    call ui_text_c
    call gfx_clip_pop
    mov edi, r15d
    lea rsi, [rip + .Lb_change]
    xor edx, edx
    call row_button
    test eax, UB_CLICK
    jz .Lds_next
    mov [rip + xp_prompt_sd], r13
    mov rdi, [r13 + SD_title]
    test rdi, rdi
    jnz 8f
    mov rdi, [r13 + SD_key]
8:  push rdi
    push rdi
    mov rdi, [r13 + SD_value]
    call strlen
    mov rcx, rax
    pop rdi
    pop rdi
    mov esi, PROMPT_EXT_SETTING
    mov rdx, [r13 + SD_value]
    call palette_ext_prompt_open
.Lds_next:
    # the row ends below its description
    mov eax, [rsp + 4]
    add eax, [rip + g_mt + 4*MI_28]
    add eax, [rip + g_mt + 4*MI_8]
    mov [rip + xp_y], eax
    jmp 1b
9:  EPILOGUE

# extpage_prompt_done(ptr, len): the text setting's new value
FN extpage_prompt_done
    PROLOGUE
    mov rbx, [rip + g_xp_detail]
    mov r12, [rip + xp_prompt_sd]
    test rbx, rbx
    jz 9f
    test r12, r12
    jz 9f
    mov qword ptr [rip + xp_prompt_sd], 0
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + xp_line]
    push rsi
    push rdx
    call sb_clear
    pop rdx
    pop rsi
    lea rdi, [rip + xp_line]
    call sb_push
    call line_cstr
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call ext_setting_set
9:  EPILOGUE

# word_cstr(ptr) -> rax xp_buf with the word at ptr (spaces skipped), rdx after it
word_cstr:
1:  cmp byte ptr [rdi], ' '
    jne 2f
    inc rdi
    jmp 1b
2:  xor ecx, ecx
3:  mov al, [rdi + rcx]
    test al, al
    jz 4f
    cmp al, ' '
    je 4f
    cmp ecx, 60
    jae 4f
    lea rdx, [rip + xp_buf]
    mov [rdx + rcx], al
    inc ecx
    jmp 3b
4:  lea rax, [rip + xp_buf]
    mov byte ptr [rax + rcx], 0
    lea rdx, [rdi + rcx]
    ret

# choice_width(sd) -> the width of its row of option buttons
choice_width:
    PROLOGUE
    mov r12, [rdi + SD_opts]
    xor r13d, r13d
    test r12, r12
    jz 9f
1:  cmp byte ptr [r12], 0
    je 9f
    mov rdi, r12
    call word_cstr
    mov r12, rdx
    cmp byte ptr [rax], 0
    je 9f
    mov rdi, rax
    call label_width
    add r13d, eax
    add r13d, [rip + g_mt + 4*MI_6]
    jmp 1b
9:  mov eax, r13d
    EPILOGUE

# ---------------- pieces ----------------

# ext_title(ext) -> its title, or its name
FN ext_title
    mov rax, [rdi + EXT_title]
    test rax, rax
    jnz 1f
    mov rax, [rdi + EXT_name]
1:  ret

# ext_problem(ext) -> what is wrong, in words, or 0 (a stop the user asked for is not a problem)
FN ext_problem
    mov eax, [rdi + EXT_status]
    cmp eax, ES_FAILED
    je 1f
    cmp eax, ES_CRASHED
    je 1f
    cmp eax, ES_STOPPED
    je 1f
    xor eax, eax
    ret
1:  mov rax, [rdi + EXT_reason]
    test rax, rax
    jnz 2f
    lea rax, [rip + .Lt_stopped]
2:  ret

# badge(x, y, size, ext): a rounded square in a color of its own with the title's first letter
FN badge
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov rbx, rcx
    # its icon, on the manifest's color when it names one
    mov rdi, rbx
    mov esi, r14d
    call ext_icon
    test rax, rax
    jz 4f
    mov [rsp + 8], rax
    mov r9d, [rbx + EXT_color]
    test r9d, r9d
    jz 5f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r14d
    mov r8d, r14d
    shr r8d, 2
    call gfx_round_rect
5:  mov edi, r12d
    mov esi, r13d
    mov rdx, [rsp + 8]
    mov ecx, r14d
    mov r8d, r14d
    call gfx_blit
    EPILOGUE
4:  # no icon: the manifest's color, or one of eight a hash of the name picks, and the letter
    mov r15d, [rbx + EXT_color]
    test r15d, r15d
    jnz 21f
    mov rsi, [rbx + EXT_name]
    xor eax, eax
1:  movzx ecx, byte ptr [rsi]
    test ecx, ecx
    jz 2f
    imul eax, eax, 31
    add eax, ecx
    inc rsi
    jmp 1b
2:  and eax, 7
    lea rcx, [rip + badge_colors]
    mov r15d, [rcx + rax*4]
21: mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r14d
    mov r8d, r14d
    shr r8d, 2
    mov r9d, r15d
    call gfx_round_rect
    # the letter
    mov rdi, rbx
    call ext_title
    movzx eax, byte ptr [rax]
    cmp al, 'a'
    jb 3f
    cmp al, 'z'
    ja 3f
    sub al, 32
3:  mov [rsp], al
    mov byte ptr [rsp + 1], 0
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r14d
    lea r9, [rsp]
    mov eax, 0xffffffff
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    EPILOGUE

# draw_icon(x, y, w, h, icon, argb): an icon centered in the box
draw_icon:
    PROLOGUE
    mov eax, edi
    mov edi, r8d
    mov r8d, ecx
    mov ecx, edx
    mov edx, esi
    mov esi, eax
    call ui_icon_center
    EPILOGUE

# section(title cstr in rsi): a gap and a header in the accent color
section:
    PROLOGUE
    M eax, MI_24
    add [rip + xp_y], eax
    lea rdi, [rip + g_face_ui]
    COLOR edx, T_ACCENT
    mov ecx, MI_28
    call line_text
    M eax, MI_4
    add [rip + xp_y], eax
    EPILOGUE

# line_text(face, cstr, argb, height index): at the column's left, xp_y moves down
line_text:
    mov r8d, [rip + xp_x]
# para(face, cstr, argb, height index, x): the text wrapped at spaces to fit between x and the
# column's right edge less as much as x is in from its left edge (a card's padding), a line each
# at xp_y, which moves down
para:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx              # color
    mov r13d, ecx               # height index
    mov [rsp + 4], r8d          # x
    call para_width
    mov r14d, eax
1:  test r12, r12
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    mov edx, r14d
    call wrap_next
    mov r15, rdx                # where the next line starts, or 0
    mov [rsp + 8], rax          # its bytes
    mov edi, [rsp + 4]          # a word wider than the line stays inside it
    mov esi, [rip + xp_y]
    mov edx, r14d
    lea rcx, [rip + g_mt]
    mov ecx, [rcx + r13*4]
    call gfx_clip_push
    mov rdi, rbx
    mov esi, [rsp + 4]
    mov edx, [rip + xp_y]
    lea rcx, [rip + g_mt]
    mov ecx, [rcx + r13*4]
    mov r9, [rsp + 8]
    mov r8, r12
    mov eax, [rsp]
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    call gfx_clip_pop
    lea rax, [rip + g_mt]
    mov eax, [rax + r13*4]
    add [rip + xp_y], eax
    mov r12, r15
    jmp 1b
9:  EPILOGUE

# para_lines(face, cstr, x) -> how many lines para draws the text in (at least 1)
para_lines:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r8d, edx
    call para_width
    mov r14d, eax
    xor r13d, r13d
1:  inc r13d
    mov rdi, rbx
    mov rsi, r12
    mov edx, r14d
    call wrap_next
    mov r12, rdx
    test r12, r12
    jnz 1b
    mov eax, r13d
    EPILOGUE

# para_width(x in r8d) -> eax the width para wraps to: the column less 2 * (x - its left edge)
para_width:
    mov eax, r8d
    sub eax, [rip + xp_x]
    shl eax, 1
    neg eax
    add eax, [rip + xp_w]
    cmp eax, 16
    jge 1f
    mov eax, 16
1:  ret

# wrap_next(face, cstr, width) -> rax the bytes of the first line that fit (whole words; a word
# wider than the line on its own), rdx the next line's start, 0 after the last
wrap_next:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    xor r14d, r14d              # the bytes that fit so far
    xor r15d, r15d              # the next word's start
1:  mov rcx, r15                # its end
2:  movzx eax, byte ptr [r12 + rcx]
    test eax, eax
    jz 3f
    cmp eax, ' '
    je 3f
    inc rcx
    jmp 2b
3:  push rcx
    push rcx
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rcx
    call text_width
    pop rcx
    pop rcx
    cmp eax, r13d
    jle 4f
    test r14, r14
    jnz 5f                      # this word goes to the next line
4:  mov r14, rcx
    cmp byte ptr [r12 + rcx], 0
    je 5f
    lea r15, [rcx + 1]
    cmp eax, r13d
    jle 1b                      # a word wider than the line ends it on its own
5:  # the next line: after the spaces
    mov rdx, r14
6:  cmp byte ptr [r12 + rdx], ' '
    jne 7f
    inc rdx
    jmp 6b
7:  cmp byte ptr [r12 + rdx], 0
    je 8f
    add rdx, r12
    mov rax, r14
    EPILOGUE
8:  xor edx, edx
    mov rax, r14
    EPILOGUE

# text_at(face, cstr, argb, height index, x): at x, clipped to the column; xp_y moves down
text_at:
    PROLOGUE
    mov r12d, ecx
    call text_at_keep
    lea rax, [rip + g_mt]
    mov eax, [rax + r12*4]
    add [rip + xp_y], eax
    EPILOGUE

# text_at_keep(face, cstr, argb, height index, x): as text_at, xp_y stays (r13 the height index)
text_at_keep:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r14d, edx
    mov r13d, ecx
    mov r15d, r8d
    mov edi, r15d
    mov esi, [rip + xp_y]
    mov edx, [rip + xp_x]
    add edx, [rip + xp_w]
    sub edx, r15d
    lea rax, [rip + g_mt]
    mov ecx, [rax + r13*4]
    mov [rsp], ecx
    call gfx_clip_push
    mov rdi, rbx
    mov esi, r15d
    mov edx, [rip + xp_y]
    mov ecx, [rsp]
    mov r8, r12
    mov r9d, r14d
    call ui_text_c
    call gfx_clip_pop
    EPILOGUE

# label_width(cstr) -> its width in the ui face plus a button's padding
label_width:
    PROLOGUE
    mov rbx, rdi
    call strlen
    lea rdi, [rip + g_face_ui]
    mov rsi, rbx
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_24]
    EPILOGUE

# label_width_small(cstr) -> its width in the small face
label_width_small:
    PROLOGUE
    mov rbx, rdi
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, rbx
    mov rdx, rax
    call text_width
    EPILOGUE

# button(id, x, y, label, style) -> UB bits: a framed button 32 high, style 0 plain, 1 the accent,
# 2 red text, 3 chosen (a choice's selected option)
button:
    PROLOGUE 32
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14, rcx
    mov [rsp], r8d
    mov rdi, rcx
    call label_width
    mov r15d, eax
    mov edi, ebx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    M r8d, MI_32
    call ui_btn
    mov [rsp + 4], eax
    COLOR eax, T_PANEL
    COLOR r9d, T_BORDER
    cmp dword ptr [rsp], 1
    jne 1f
    COLOR eax, T_ACCENT
    mov r9d, eax
1:  cmp dword ptr [rsp], 3
    jne 2f
    COLOR eax, T_ACTIVE
2:  test dword ptr [rsp + 4], UB_HOVER
    jz 3f
    cmp dword ptr [rsp], 1
    je 3f
    COLOR eax, T_HOVER
3:  push rax
    push rax
    mov edi, r12d
    mov esi, r13d
    mov edx, r15d
    M ecx, MI_32
    M r8d, MI_RADIUS
    call gfx_frame
    add rsp, 16
    COLOR eax, T_FG
    cmp dword ptr [rsp], 1
    jne 4f
    COLOR eax, T_BG
4:  cmp dword ptr [rsp], 2
    jne 5f
    COLOR eax, T_ERROR
5:  push rax
    push rax
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    M r8d, MI_32
    mov r9, r14
    call ui_text_center
    add rsp, 16
    test dword ptr [rsp + 4], UB_CLICK
    jz 6f
    mov dword ptr [rip + g_dirty], 1
6:  mov eax, [rsp + 4]
    mov edx, r15d
    EPILOGUE

# row_button(id, label, style) -> UB bits: a button at xp_bx, xp_y; xp_bx moves right
row_button:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    mov r14d, edx
    mov edi, r12d
    mov esi, [rip + xp_bx]
    mov edx, [rip + xp_y]
    mov rcx, r13
    mov r8d, r14d
    call button
    add edx, [rip + g_mt + 4*MI_6]
    add [rip + xp_bx], edx
    EPILOGUE

# icon_button(id, x, icon) -> UB bits: a 28 px square button with an icon, at xp_y
icon_button:
    PROLOGUE 16
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov edi, ebx
    mov esi, r12d
    mov edx, [rip + xp_y]
    M ecx, MI_28
    M r8d, MI_28
    mov r9d, r13d
    call ui_icon_btn
    mov [rsp], eax
    test eax, UB_CLICK
    jz 1f
    mov dword ptr [rip + g_dirty], 1
1:  mov eax, [rsp]
    EPILOGUE

# line_cstr() -> xp_line as a cstr
line_cstr:
    push rbx
    lea rdi, [rip + xp_line]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rip + xp_line + SB_len]
    mov rax, [rip + xp_line + SB_ptr]
    pop rbx
    ret

# ext_needs_words(ext, sb): what it may do, in plain words joined by ", " ("read and change the
# files you have open, read the files in your project, run gofmt"), for the page and the install
# dialog
FN ext_needs_words
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, [rbx + EXT_needs]
    xor r14d, r14d              # items so far
    lea rsi, [rip + .Ln_docs_write]
    test r13d, NEEDS_DOC_WRITE
    jnz 1f
    lea rsi, [rip + .Ln_docs_read]
    test r13d, NEEDS_DOC_READ
    jz 2f
1:  call item
2:  lea rsi, [rip + .Ln_proj_write]
    test r13d, NEEDS_PROJECT_WRITE
    jnz 3f
    lea rsi, [rip + .Ln_proj_read]
    test r13d, NEEDS_PROJECT_READ
    jz 4f
3:  call item
4:  lea rsi, [rip + .Ln_home]
    test r13d, NEEDS_HOME_READ
    jz 5f
    call item
5:  lea rsi, [rip + .Ln_net]
    test r13d, NEEDS_NETWORK
    jz 6f
    call item
6:  lea rsi, [rip + .Ln_terminal]
    test r13d, NEEDS_TERMINAL
    jz 7f
    call item
7:  mov rsi, [rbx + EXT_runs]
    test rsi, rsi
    jz 8f
    cmp byte ptr [rsi], 0
    je 8f
    lea rsi, [rip + .Ln_runs]
    call item
    mov rdi, r12
    mov rsi, [rbx + EXT_runs]
    call sb_push_cstr
8:  test r14d, r14d
    jnz 9f
    lea rsi, [rip + .Ln_nothing]
    call item
9:  EPILOGUE

# item(cstr): onto r12, after ", " when it is not the first (r14 counts)
item:
    push rsi
    push rsi
    test r14d, r14d
    jz 1f
    mov rdi, r12
    lea rsi, [rip + .Ln_sep]
    call sb_push_cstr
1:  pop rsi
    pop rsi
    inc r14d
    mov rdi, r12
    jmp sb_push_cstr

# ---------------- for the tests: print-ext-page ----------------

# extpage_dump(sb): the list ("Title version on|off [problem]") or the details of one extension
FN extpage_dump
    PROLOGUE
    mov r12, rdi
    mov rbx, [rip + g_xp_detail]
    test rbx, rbx
    jnz .Lxd_detail
    xor r13d, r13d
1:  cmp r13, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r13, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r13
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 1b
    call dump_head
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    jmp 1b
.Lxd_detail:
    call dump_head
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    mov rdi, r12
    lea rsi, [rip + .Ld_pinned]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + EXT_pinned]
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    # "badge=letter|icon|unreadable color=#rrggbb|-"
    mov rdi, rbx
    call ext_icon_state
    lea rsi, [rip + .Ld_badge_letter]
    cmp eax, 1
    jne 1f
    lea rsi, [rip + .Ld_badge_icon]
1:  cmp eax, 2
    jne 2f
    lea rsi, [rip + .Ld_badge_bad]
2:  mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ld_color]
    call sb_push_cstr
    mov eax, [rbx + EXT_color]
    test eax, eax
    jnz 3f
    mov rdi, r12
    mov esi, '-'
    call sb_push_byte
    jmp 5f
3:  mov rdi, r12
    mov esi, '#'
    call sb_push_byte
    mov r13d, 20                # the six hex digits, high to low
4:  mov eax, [rbx + EXT_color]
    mov ecx, r13d
    shr eax, cl
    and eax, 15
    lea rcx, [rip + .Ld_hex]
    movzx esi, byte ptr [rcx + rax]
    mov rdi, r12
    call sb_push_byte
    sub r13d, 4
    jns 4b
5:  mov rdi, r12
    mov esi, 10
    call sb_push_byte
    # permissions, a line each
    lea rdi, [rip + xp_line]
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + xp_line]
    call ext_needs_words
    mov rdi, r12
    lea rsi, [rip + .Ld_can]
    call sb_push_cstr
    call line_cstr
    mov rdi, r12
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    mov rdi, r12
    lea rsi, [rip + .Ld_held]
    call sb_push_cstr
    mov rdi, r12
    xor esi, esi
    cmp qword ptr [rbx + EXT_confine_why], 0
    sete sil
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    # settings
    xor r13d, r13d
2:  cmp r13, [rbx + EXT_sdefs + VEC_len]
    jae 9f
    imul r14, r13, SD_SIZE
    add r14, [rbx + EXT_sdefs + VEC_ptr]
    inc r13
    mov rdi, r12
    lea rsi, [rip + .Ld_setting]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [r14 + SD_key]
    call sb_push_cstr
    mov rdi, r12
    mov esi, '='
    call sb_push_byte
    mov rdi, r12
    mov rsi, [r14 + SD_value]
    call sb_push_cstr
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    jmp 2b
9:  EPILOGUE

# dump_head(): rbx's "Title version on|off [problem]" onto r12
dump_head:
    PROLOGUE
    mov rdi, rbx
    call ext_title
    mov rdi, r12
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rsi, [rbx + EXT_version]
    test rsi, rsi
    jz 1f
    mov rdi, r12
    call sb_push_cstr
1:  lea rsi, [rip + .Ld_on]
    cmp dword ptr [rbx + EXT_disabled], 0
    je 2f
    lea rsi, [rip + .Ld_off]
2:  mov rdi, r12
    call sb_push_cstr
    mov rdi, rbx
    call ext_problem
    test rax, rax
    jz 9f
    push rax
    push rax
    mov rdi, r12
    lea rsi, [rip + .Ld_problem]
    call sb_push_cstr
    pop rsi
    pop rsi
    mov rdi, r12
    call sb_push_cstr
9:  EPILOGUE

.section .rodata
.p2align 2
badge_colors: .long 0xff4f7fd9, 0xff3f9f6f, 0xffd9803f, 0xff9a6ad6, 0xffcf5050, 0xff2f9fae, 0xffb88a2a, 0xffc0508f
.Lt_title: .asciz "Extensions"
.Ln_docs_read: .asciz "read the files you have open"
.Ln_docs_write: .asciz "read and change the files you have open"
.Ln_proj_read: .asciz "read the files in your project"
.Ln_proj_write: .asciz "read and change the files in your project"
.Ln_home: .asciz "read the files in your home folder"
.Ln_net: .asciz "use the internet"
.Ln_terminal: .asciz "suggest terminal commands for you to run"
.Ln_runs: .asciz "run "
.Ln_nothing: .asciz "only use its own commands and settings"
.Ln_sep: .asciz ", "
.Lt_intro: .asciz "Extensions add commands, marks and tools to rhun. Each one gets only the access it asks for."
.Lt_none: .asciz "No extensions yet. Install one from GitHub, for example rhun-editor/showcase."
.Lt_no_desc: .asciz "No description"
.Lt_stopped: .asciz "Stopped"
.Lt_version: .asciz "Version "
.Lt_source: .asciz "  \302\267  github.com/"
.Lt_pin: .asciz "Pin to the title bar"
.Lt_pin_desc: .asciz "Its button sits next to the extensions button and lists its commands."
.Lt_held: .asciz "rhun holds it to these permissions."
.Lt_not_held: .asciz "This system cannot hold it to these permissions; it runs with yours."
.Lt_windows: .asciz "Windows cannot hold it to these permissions; it runs with yours."
.Ls_permissions: .asciz "It can"
.Ls_toolbar: .asciz "Title bar"
.Ls_commands: .asciz "Commands"
.Ls_settings: .asciz "Settings"
.Lb_install: .asciz "Install from GitHub"
.Lb_details: .asciz "Details"
.Lb_remove: .asciz "Remove"
.Lb_remove_ext: .asciz "Remove extension"
.Lb_restart: .asciz "Restart"
.Lb_change: .asciz "Change"
.Lbullet: .asciz "\342\200\242  "
.Lyes: .asciz "yes"
.Lno: .asciz "no"
.Lempty: .asciz ""
.Ld_on: .asciz " on"
.Ld_off: .asciz " off"
.Ld_problem: .asciz " problem="
.Ld_pinned: .asciz "pinned="
.Ld_badge_letter: .asciz "badge=letter"
.Ld_badge_icon: .asciz "badge=icon"
.Ld_badge_bad: .asciz "badge=unreadable"
.Ld_color: .asciz " color="
.Ld_hex: .ascii "0123456789abcdef"
.Ld_can: .asciz "can: "
.Ld_held: .asciz "held="
.Ld_setting: .asciz "setting "
