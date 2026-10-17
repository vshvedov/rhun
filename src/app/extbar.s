# the extensions in the title bar, as in Chrome: a puzzle-piece button whose dropdown lists the
# extensions (each with a pin and a "more" menu), Manage extensions and Install from GitHub; and a
# button for each pinned extension, whose menu lists its commands.
.include "rhun.inc"
.equ ID_XB_ROW, 0x7480          # + i*4 + k: a row, its pin, its more button
.equ ID_XB_FOOT, 0x7600         # + 0 manage, + 1 install

.equ XB_NAME, 128              # bytes of a command name in a menu
.bss
.p2align 3
xb_open: .long 0                # the dropdown is open
xb_press: .long 0               # the press that opened it (not a click outside)
xb_x: .long 0                   # where it hangs: the puzzle button's right edge and the bar's bottom
xb_y: .long 0
xb_ext: .quad 0                 # the extension a menu was opened for
xb_items: .zero 16 * 72         # a menu: (label, handler) pairs, 0-ended
xb_labels: .zero 64 * 64        # the menu's labels
xb_names: .zero XB_NAME * 64     # the names of the commands its items run (looked up on the
                                # click: a registration may move the command table meanwhile)

.text

# extbar_buttons(left, bar h, size, gap) -> eax the new left edge: the puzzle button, then the pinned
# extensions' buttons to its left
FN extbar_buttons
    PROLOGUE 32
    mov r12d, edi
    mov [rsp], esi
    mov r13d, edx
    mov [rsp + 4], ecx
    sub r12d, ecx
    sub r12d, r13d              # the puzzle button's x
    mov eax, [rsp]
    sub eax, r13d
    sar eax, 1
    mov [rsp + 8], eax          # y
    mov edi, ID_XB_PUZZLE
    mov esi, r12d
    mov edx, eax
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, IC_PUZZLE
    call ui_icon_btn
    mov r8d, eax
    mov edi, ID_XB_PUZZLE
    mov esi, r12d
    mov edx, [rsp]
    mov ecx, r13d
    call tip_note
    test eax, UB_CLICK
    jz 1f
    mov eax, r12d
    add eax, r13d
    mov [rip + xb_x], eax
    mov eax, [rsp]
    mov [rip + xb_y], eax
    call extbar_toggle
1:  # pinned extensions, right to left in table order
    xor r14d, r14d
2:  cmp r14, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r14, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r14
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 2b
    cmp dword ptr [rbx + EXT_pinned], 0
    je 2b
    sub r12d, [rsp + 4]
    sub r12d, r13d
    lea edi, [r14 + ID_XB_PUZZLE]
    mov esi, r12d
    mov edx, [rsp + 8]
    mov ecx, r13d
    mov r8d, r13d
    call ui_btn
    mov r15d, eax
    test eax, UB_HOVER
    jz 3f
    mov edi, r12d
    mov esi, [rsp + 8]
    mov edx, r13d
    mov ecx, r13d
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
3:  # its badge, inset
    M eax, MI_4
    mov edi, r12d
    add edi, eax
    mov esi, [rsp + 8]
    add esi, eax
    mov edx, r13d
    sub edx, eax
    sub edx, eax
    mov rcx, rbx
    call badge
    test r15d, UB_CLICK
    jz 2b
    mov rdi, rbx
    mov esi, r12d
    mov edx, [rsp]
    call ext_action
    jmp 2b
9:  mov eax, r12d
    EPILOGUE

# extbar_count() -> how many buttons extbar_buttons draws: the puzzle and each pinned extension
FN extbar_count
    mov eax, 1
    xor ecx, ecx
1:  cmp rcx, [rip + g_exts + VEC_len]
    jae 9f
    imul rdx, rcx, EXT_SIZE
    add rdx, [rip + g_exts + VEC_ptr]
    inc rcx
    cmp dword ptr [rdx + EXT_status], ES_REMOVED
    je 1b
    cmp dword ptr [rdx + EXT_pinned], 0
    je 1b
    inc eax
    jmp 1b
9:  ret

# extbar_toggle(): the dropdown opens, or closes
FN extbar_toggle
    xor dword ptr [rip + xb_open], 1
    mov eax, [rip + g_pressed]
    and eax, 1 << BTN_LEFT
    mov [rip + xb_press], eax
    mov dword ptr [rip + g_dirty], 1
    ret

# extbar_open_menu(): the dropdown, under the puzzle button (the keyboard's way: cmd)
FN extbar_open_menu
    mov eax, [rip + g_cv + CV_w]
    sub eax, [rip + g_mt + 4*MI_8]
    cmp dword ptr [rip + xb_x], 0
    jne 1f
    mov [rip + xb_x], eax
    mov eax, [rip + g_mt + 4*MI_TITLE]
    mov [rip + xb_y], eax
1:  mov dword ptr [rip + xb_open], 1
    mov dword ptr [rip + xb_press], 0
    mov dword ptr [rip + g_dirty], 1
    ret

# extbar_menu_open() -> 1 while the dropdown is open (it blocks the window under it)
FN extbar_menu_open
    mov eax, [rip + xb_open]
    ret

FN extbar_close
    mov dword ptr [rip + xb_open], 0
    mov dword ptr [rip + g_dirty], 1
    ret

# extbar_draw(): the dropdown, over everything else but menus, the palette and dialogs
FN extbar_draw
    PROLOGUE 48
    cmp dword ptr [rip + xb_open], 0
    je .Lxb_ret
    # its size: a row per extension, a line, two rows; 320 wide
    mov edi, 320
    call sc
    mov r12d, eax               # w
    M ebx, MI_32                # a row's height
    xor r13d, r13d              # rows
    xor ecx, ecx
1:  cmp rcx, [rip + g_exts + VEC_len]
    jae 2f
    imul rax, rcx, EXT_SIZE
    add rax, [rip + g_exts + VEC_ptr]
    inc rcx
    cmp dword ptr [rax + EXT_status], ES_REMOVED
    je 1b
    inc r13d
    jmp 1b
2:  mov [rsp + 40], r13d
    mov r14d, r13d
    test r14d, r14d
    jnz 21f
    inc r14d                    # "No extensions yet"
21: add r14d, 2
    imul r14d, ebx
    add r14d, [rip + g_mt + 4*MI_40]    # the header
    add r14d, [rip + g_mt + 4*MI_12]    # the line and padding
    # hanging from the button, inside the window
    mov eax, [rip + xb_x]
    sub eax, r12d
    mov ecx, [rip + g_mt + 4*MI_8]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp], eax
    mov eax, [rip + xb_y]
    add eax, [rip + g_mt + 4*MI_4]
    mov [rsp + 4], eax
    mov edi, [rsp]
    mov esi, eax
    mov edx, r12d
    mov ecx, r14d
    call ui_card
    # a click outside closes it (not the press that opened it)
    test dword ptr [rip + g_pressed], (1 << BTN_LEFT) | (1 << BTN_RIGHT)
    jz 3f
    cmp dword ptr [rip + xb_press], 0
    jne 3f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, r12d
    mov ecx, r14d
    call ui_in
    test eax, eax
    jnz 3f
    mov dword ptr [rip + xb_open], 0
    mov dword ptr [rip + g_dirty], 1
    jmp .Lxb_ret
3:  # "Extensions"
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_6]
    M ecx, MI_32
    lea r8, [rip + .Lt_extensions]
    COLOR r9d, T_FG
    call ui_text_c
    mov eax, [rsp + 4]
    add eax, [rip + g_mt + 4*MI_40]
    mov [rsp + 8], eax          # the row's y
    # the extensions
    xor r15d, r15d
4:  cmp r15, [rip + g_exts + VEC_len]
    jae 6f
    imul r13, r15, EXT_SIZE
    add r13, [rip + g_exts + VEC_ptr]
    inc r15
    cmp dword ptr [r13 + EXT_status], ES_REMOVED
    je 4b
    lea edi, [r15 - 1]
    mov esi, [rsp]
    mov edx, [rsp + 8]
    mov ecx, r12d
    mov r8, r13
    call row
    add [rsp + 8], ebx
    cmp dword ptr [rip + xb_open], 0
    je .Lxb_ret                 # a row's action closed it
    jmp 4b
6:  cmp dword ptr [rsp + 40], 0
    jne 7f
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 8]
    mov ecx, ebx
    lea r8, [rip + .Lt_none]
    COLOR r9d, T_MUTED
    call ui_text_c
    add [rsp + 8], ebx
7:  # a line, then Manage extensions and Install from GitHub
    mov eax, [rip + g_mt + 4*MI_6]
    add eax, [rsp + 8]
    mov esi, eax
    mov edi, [rsp]
    add edi, [rip + g_mt + 4*MI_12]
    mov edx, r12d
    sub edx, [rip + g_mt + 4*MI_24]
    M ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    mov eax, [rip + g_mt + 4*MI_12]
    add [rsp + 8], eax
    mov edi, ID_XB_FOOT
    mov esi, [rsp]
    mov edx, [rsp + 8]
    mov ecx, r12d
    mov r8d, IC_PUZZLE
    lea r9, [rip + .Lt_manage]
    call foot_row
    test eax, UB_CLICK
    jz 8f
    call extbar_close
    xor edi, edi
    call extpage_show
    jmp .Lxb_ret
8:  add [rsp + 8], ebx
    mov edi, ID_XB_FOOT + 1
    mov esi, [rsp]
    mov edx, [rsp + 8]
    mov ecx, r12d
    mov r8d, IC_PLUS
    lea r9, [rip + .Lt_install]
    call foot_row
    test eax, UB_CLICK
    jz .Lxb_ret
    call extbar_close
    call cmd_install_extension
.Lxb_ret:
    mov dword ptr [rip + xb_press], 0
    EPILOGUE

# row(index, x, y, w, ext): badge and title (its action), the pin, the more button
row:
    PROLOGUE 32
    mov ebx, edi
    shl ebx, 2
    add ebx, ID_XB_ROW
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15, r8
    M eax, MI_32
    mov [rsp], eax              # h
    # the row's hover and click (all of it but the two buttons on the right)
    mov edi, ebx
    lea esi, [r12 + 0]
    add esi, [rip + g_mt + 4*MI_6]
    mov edx, r13d
    mov ecx, r14d
    sub ecx, [rip + g_mt + 4*MI_6]
    sub ecx, [rip + g_mt + 4*MI_6]
    sub ecx, [rip + g_mt + 4*MI_64]
    mov r8d, [rsp]
    call ui_btn
    mov [rsp + 4], eax
    test eax, UB_HOVER
    jz 1f
    mov edi, r12d
    add edi, [rip + g_mt + 4*MI_6]
    mov esi, r13d
    mov edx, r14d
    sub edx, [rip + g_mt + 4*MI_6]
    sub edx, [rip + g_mt + 4*MI_6]
    mov ecx, [rsp]
    M r8d, MI_RADIUS
    COLOR r9d, T_ACTIVE
    call gfx_round_rect
1:  mov edi, r12d
    add edi, [rip + g_mt + 4*MI_16]
    mov esi, r13d
    add esi, [rip + g_mt + 4*MI_6]
    M edx, MI_20
    mov rcx, r15
    call badge
    mov rdi, r15
    call ext_title
    mov r8, rax
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_16]
    add esi, [rip + g_mt + 4*MI_20]
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, r13d
    mov ecx, [rsp]
    COLOR r9d, T_FG
    mov rax, r15
    cmp dword ptr [rax + EXT_disabled], 0
    je 11f
    COLOR r9d, T_MUTED          # off: muted
11: call ui_text_c
    # the pin
    mov esi, r12d
    add esi, r14d
    sub esi, [rip + g_mt + 4*MI_64]
    lea edi, [rbx + 1]
    mov edx, r13d
    M ecx, MI_28
    mov r8d, [rsp]
    mov r9d, IC_PIN
    call ui_icon_btn
    mov [rsp + 8], eax
    cmp dword ptr [r15 + EXT_pinned], 0
    je 2f
    # pinned: the pin in the accent color, drawn over the muted one
    mov esi, r12d
    add esi, r14d
    sub esi, [rip + g_mt + 4*MI_64]
    mov edi, IC_PIN
    mov edx, r13d
    M ecx, MI_28
    mov r8d, [rsp]
    COLOR r9d, T_ACCENT
    call ui_icon_center
2:  test dword ptr [rsp + 8], UB_CLICK
    jz 3f
    mov rdi, r15
    mov esi, [r15 + EXT_pinned]
    xor esi, 1
    call ext_set_pinned
3:  # more
    mov esi, r12d
    add esi, r14d
    sub esi, [rip + g_mt + 4*MI_32]
    sub esi, [rip + g_mt + 4*MI_6]
    lea edi, [rbx + 2]
    mov edx, r13d
    M ecx, MI_28
    mov r8d, [rsp]
    mov r9d, IC_MORE
    call ui_icon_btn
    test eax, UB_CLICK
    jz 4f
    mov rdi, r15
    mov esi, r12d
    add esi, r14d
    sub esi, [rip + g_mt + 4*MI_32]
    mov edx, r13d
    add edx, [rsp]
    call more_menu
    jmp 9f
4:  test dword ptr [rsp + 4], UB_CLICK
    jz 9f
    mov rdi, r15
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, r13d
    add edx, [rsp]
    call ext_action
9:  EPILOGUE

# foot_row(id, x, y, w, icon, label) -> UB bits: an icon and a label, the row's width
foot_row:
    PROLOGUE 32
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov [rsp], r8d
    mov r15, r9
    mov edi, ebx
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_6]
    mov edx, r13d
    mov ecx, r14d
    sub ecx, [rip + g_mt + 4*MI_12]
    M r8d, MI_32
    call ui_btn
    mov [rsp + 4], eax
    test eax, UB_HOVER
    jz 1f
    mov edi, r12d
    add edi, [rip + g_mt + 4*MI_6]
    mov esi, r13d
    mov edx, r14d
    sub edx, [rip + g_mt + 4*MI_12]
    M ecx, MI_32
    M r8d, MI_RADIUS
    COLOR r9d, T_ACTIVE
    call gfx_round_rect
1:  mov edi, [rsp]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, r13d
    M ecx, MI_20
    M r8d, MI_32
    COLOR r9d, T_MUTED
    call ui_icon_center
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_16]
    add esi, [rip + g_mt + 4*MI_20]
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, r13d
    M ecx, MI_32
    mov r8, r15
    COLOR r9d, T_FG
    call ui_text_c
    mov eax, [rsp + 4]
    EPILOGUE

# ---------------- menus ----------------

# ext_action(ext, x, y): what a click on an extension does: its only command runs; several make a
# menu of them; none opens its details
FN ext_action
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rip + xb_ext], rbx
    call extbar_close
    # its commands: manifest ones and registered ones, labels without " (Extension)"
    mov rax, rbx
    lea rcx, [rip + g_exts]
    sub rax, [rcx + VEC_ptr]
    xor edx, edx
    mov ecx, EXT_SIZE
    div rcx
    mov r14, rax                # its index
    xor r13d, r13d              # items
    xor r12d, r12d
1:  cmp r12, [rip + g_ext_cmds + VEC_len]
    jae 3f
    cmp r13d, 60
    jae 3f
    mov rax, [rip + g_ext_owner + VEC_ptr]
    cmp [rax + r12*8], r14
    jne 2f
    imul r15, r12, CMD_SIZE
    add r15, [rip + g_ext_cmds + VEC_ptr]
    mov [rsp + 8], r15          # the last one: run at once when it is the only one
    mov rdi, r13
    imul rdi, rdi, XB_NAME
    lea rax, [rip + xb_names]
    add rdi, rax
    mov rsi, [r15 + CMD_name]
    call copy_name
    mov rdi, r13
    shl rdi, 6
    lea rax, [rip + xb_labels]
    add rdi, rax
    mov rsi, [r15 + CMD_title]
    call copy_title_short
    mov rax, r13
    shl rax, 4
    lea rcx, [rip + xb_items]
    mov rdx, r13
    shl rdx, 6
    lea r8, [rip + xb_labels]
    add rdx, r8
    mov [rcx + rax], rdx
    lea rdx, [rip + run_item]
    mov [rcx + rax + 8], rdx
    inc r13d
2:  inc r12
    jmp 1b
3:  test r13d, r13d
    jnz 4f
    mov rdi, rbx
    call extpage_show
    EPILOGUE
4:  cmp r13d, 1
    jne 5f
    mov rdi, [rsp + 8]
    call [rdi + CMD_fn]
    EPILOGUE
5:  # a line, then its settings
    mov rax, r13
    shl rax, 4
    lea rcx, [rip + xb_items]
    lea rdx, [rip + .Lline]
    mov [rcx + rax], rdx
    mov qword ptr [rcx + rax + 8], 0
    lea rdx, [rip + .Lm_settings]
    mov [rcx + rax + 16], rdx
    lea rdx, [rip + open_details]
    mov [rcx + rax + 24], rdx
    mov qword ptr [rcx + rax + 32], 0
    mov qword ptr [rcx + rax + 40], 0
    lea rdi, [rip + xb_items]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    call ctx_menu_open
    EPILOGUE

# more_menu(ext, x, y): Settings, Pin or Unpin, Turn off or on, Remove
more_menu:
    PROLOGUE
    mov [rip + xb_ext], rdi
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    call extbar_close
    lea rcx, [rip + xb_items]
    lea rax, [rip + .Lm_settings]
    mov [rcx], rax
    lea rax, [rip + open_details]
    mov [rcx + 8], rax
    lea rax, [rip + .Lm_pin]
    cmp dword ptr [rbx + EXT_pinned], 0
    je 1f
    lea rax, [rip + .Lm_unpin]
1:  mov [rcx + 16], rax
    lea rax, [rip + toggle_pin]
    mov [rcx + 24], rax
    lea rax, [rip + .Lm_off]
    cmp dword ptr [rbx + EXT_disabled], 0
    je 2f
    lea rax, [rip + .Lm_on]
2:  mov [rcx + 32], rax
    lea rax, [rip + toggle_on]
    mov [rcx + 40], rax
    lea rax, [rip + .Lline]
    mov [rcx + 48], rax
    mov qword ptr [rcx + 56], 0
    lea rax, [rip + .Lm_remove]
    mov [rcx + 64], rax
    lea rax, [rip + remove_item]
    mov [rcx + 72], rax
    mov qword ptr [rcx + 80], 0
    mov qword ptr [rcx + 88], 0
    lea rdi, [rip + xb_items]
    mov esi, r12d
    mov edx, r13d
    call ctx_menu_open
    EPILOGUE

# copy_title_short(dst, title): up to the last " (", at most 60 bytes
copy_title_short:
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
2:  mov rcx, rax
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

# the menus' handlers (g_menu_index is the item clicked)
run_item:
    PROLOGUE
    call menu_ext
    jz 9f
    # the menu's extension, as an index (two owners may both have an extension called NAME)
    mov rax, rdi
    sub rax, [rip + g_exts + VEC_ptr]
    xor edx, edx
    mov ecx, EXT_SIZE
    div rcx
    mov r13, rax
    mov eax, [rip + g_menu_index]
    imul rax, rax, XB_NAME
    lea r14, [rip + xb_names]
    add r14, rax
    cmp byte ptr [r14], 0
    je 9f
    # its command of that name; gone meanwhile (removed, unregistered): nothing runs
    xor r12d, r12d
1:  cmp r12, [rip + g_ext_cmds + VEC_len]
    jae 9f
    mov rax, [rip + g_ext_owner + VEC_ptr]
    cmp [rax + r12*8], r13
    jne 2f
    imul rbx, r12, CMD_SIZE
    add rbx, [rip + g_ext_cmds + VEC_ptr]
    mov rdi, [rbx + CMD_name]
    test rdi, rdi
    jz 2f
    mov rsi, r14
    call strcmp_eq
    test eax, eax
    jnz 3f
2:  inc r12
    jmp 1b
3:  mov rdi, rbx
    call [rbx + CMD_fn]
9:  EPILOGUE
open_details:
    call menu_ext
    jz 1f
    jmp extpage_show
toggle_pin:
    call menu_ext
    jz 1f
    mov esi, [rdi + EXT_pinned]
    xor esi, 1
    jmp ext_set_pinned
toggle_on:
    call menu_ext
    jz 1f
    mov esi, [rdi + EXT_disabled]
    xor esi, 1
    jmp ext_set_disabled
remove_item:
    call menu_ext
    jz 1f
    jmp ext_remove_ask
1:  ret

# menu_ext() -> rdi the extension the menu was opened for; ZF when it was removed meanwhile
menu_ext:
    mov rdi, [rip + xb_ext]
    cmp dword ptr [rdi + EXT_status], ES_REMOVED
    ret

# copy_name(dst, cstr): the command name into an XB_NAME slot, empty when it does not fit
copy_name:
    push rdi
    push rsi
    mov rdi, rsi
    call strlen
    pop rsi
    pop rdi
    cmp rax, XB_NAME - 1
    jb 1f
    mov byte ptr [rdi], 0
    ret
1:  lea rdx, [rax + 1]
    jmp memcpy

# ---------------- for the tests: print-extbar ----------------

# extbar_dump(sb): "menu=open|closed", then "pinned=a,b" and a line per extension in the dropdown
FN extbar_dump
    PROLOGUE
    mov r12, rdi
    lea rsi, [rip + .Ld_closed]
    cmp dword ptr [rip + xb_open], 0
    je 1f
    lea rsi, [rip + .Ld_open]
1:  mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ld_pinned]
    call sb_push_cstr
    xor r14d, r14d              # written
    xor r13d, r13d
2:  cmp r13, [rip + g_exts + VEC_len]
    jae 4f
    imul rbx, r13, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r13
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 2b
    cmp dword ptr [rbx + EXT_pinned], 0
    je 2b
    test r14d, r14d
    jz 3f
    mov rdi, r12
    mov esi, ','
    call sb_push_byte
3:  inc r14d
    mov rdi, r12
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    jmp 2b
4:  mov rdi, r12
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Lt_extensions: .asciz "Extensions"
.Lt_none: .asciz "No extensions yet"
.Lt_manage: .asciz "Manage extensions"
.Lt_install: .asciz "Install from GitHub\342\200\246"
.Lline: .asciz "-"
.Lm_settings: .asciz "Settings and details"
.Lm_pin: .asciz "Pin to the title bar"
.Lm_unpin: .asciz "Unpin from the title bar"
.Lm_off: .asciz "Turn off"
.Lm_on: .asciz "Turn on"
.Lm_remove: .asciz "Remove\342\200\246"
.Ld_open: .asciz "menu=open\n"
.Ld_closed: .asciz "menu=closed\n"
.Ld_pinned: .asciz "pinned="
