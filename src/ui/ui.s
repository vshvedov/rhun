# immediate-mode ui core: metrics, input state, hit testing, basic widgets
.include "rhun.inc"

.bss
.p2align 3
.globl g_mt, g_s, g_mx, g_my, g_mdown, g_pressed, g_released, g_scroll_x, g_scroll_y
.globl g_hot, g_active, g_cursor, g_block, g_clicks, g_face_ui, g_face_small, g_face_big, g_face_code
.globl g_hole
g_mt: .zero 4 * MI_COUNT
g_s: .long 0                    # float scale
g_mdown: .long 0                # buttons held (bit per button)
g_pressed: .long 0              # pressed since last frame
g_released: .long 0
g_scroll_x: .long 0
g_scroll_y: .long 0
g_hot: .long 0
g_active: .long 0
g_cursor: .long 0
g_block: .long 0                # 1 while drawing layers under a modal
g_hole: .zero 16                # x, y, w, h: a handle drawn later owns this strip, nothing drawn
                                # before it takes the pointer there (h 0: none)
g_clicks: .long 0               # click count of the last press (1..3)
last_press_t: .quad 0
last_press_x: .long 0
last_press_y: .long 0
g_press_x: .long 0
g_press_y: .long 0
held_mx: .long 0                # a pointer move waiting for the frame of a press
held_my: .long 0
held_move: .long 0
.equ SB_MAX, 16                 # scrollbars tracked for the scroll-flash
.equ SB_SHOW_MS, 800            # ms a thumb stays visible after its offset last moved
# sb_flash slot: +0 scrollbar id, +8 last offset px (+pad), +16 show-until ms; 24B each
sb_flash: .zero SB_MAX * 24
.p2align 3
g_face_ui: .zero FACE_SIZE
g_face_small: .zero FACE_SIZE
g_face_big: .zero FACE_SIZE
g_face_code: .zero FACE_SIZE
.globl g_face_huge
g_face_huge: .zero FACE_SIZE
last_scale: .long 0
last_code_px: .long 0
last_ui_px: .long 0
.globl g_font_code, g_font_ui
g_font_code: .quad 0
g_font_ui: .quad 0
.globl g_lh, g_cw, g_base
g_lh: .long 0                   # editor line height
g_cw: .long 0                   # editor cell width
g_base: .long 0                 # baseline offset inside a line

.text

# ui_update_metrics(): recompute scaled sizes and font faces if anything changed
FN ui_update_metrics
    PROLOGUE 16
    # s = dpi * ui_scale / 100
    cvtsi2ss xmm0, dword ptr [rip + cfg_ui_scale]
    mulss xmm0, [rip + g_dpi_scale]
    divss xmm0, [rip + f_100]
    maxss xmm0, [rip + f_min_scale]     # fonts need a size of at least a few pixels
    movss [rip + g_s], xmm0
    movd eax, xmm0
    cmp eax, [rip + last_scale]
    je 2f
    mov [rip + last_scale], eax
    call icon_cache_clear
    lea rbx, [rip + metric_values]
    xor ecx, ecx
1:  cmp ecx, MI_COUNT
    jae 2f
    cvtsi2ss xmm1, dword ptr [rbx + rcx*4]
    mulss xmm1, [rip + g_s]
    cvtss2si eax, xmm1
    cmp eax, 1
    jge 11f
    mov eax, 1
11: lea rdx, [rip + g_mt]
    mov [rdx + rcx*4], eax
    inc ecx
    jmp 1b
2:  # ui faces
    cvtsi2ss xmm0, dword ptr [rip + cfg_ui_font_size]
    mulss xmm0, [rip + g_s]
    cvtss2si ebx, xmm0
    cmp ebx, [rip + last_ui_px]
    je 3f
    mov [rip + last_ui_px], ebx
    lea rdi, [rip + g_face_ui]
    mov rsi, [rip + g_font_ui]
    mov edx, ebx
    call face_init
    cvtsi2ss xmm0, dword ptr [rip + cfg_ui_font_size]
    subss xmm0, [rip + f_1p5]
    mulss xmm0, [rip + g_s]
    cvtss2si edx, xmm0
    lea rdi, [rip + g_face_small]
    mov rsi, [rip + g_font_ui]
    call face_init
    cvtsi2ss xmm0, dword ptr [rip + cfg_ui_font_size]
    mulss xmm0, [rip + f_big]
    mulss xmm0, [rip + g_s]
    cvtss2si edx, xmm0
    lea rdi, [rip + g_face_big]
    mov rsi, [rip + g_font_ui]
    call face_init
    cvtsi2ss xmm0, dword ptr [rip + cfg_ui_font_size]
    mulss xmm0, [rip + f_huge]
    mulss xmm0, [rip + g_s]
    cvtss2si edx, xmm0
    lea rdi, [rip + g_face_huge]
    mov rsi, [rip + g_font_ui]
    call face_init
3:  # code face + line metrics
    cvtsi2ss xmm0, dword ptr [rip + cfg_font_size]
    mulss xmm0, [rip + g_s]
    cvtss2si ebx, xmm0
    mov eax, ebx
    shl eax, 8
    xor eax, [rip + cfg_line_height]
    cmp eax, [rip + last_code_px]
    je 4f
    mov [rip + last_code_px], eax
    lea rdi, [rip + g_face_code]
    mov rsi, [rip + g_font_code]
    mov edx, ebx
    call face_init
    # line height = font px * line_height / 100, at least ascent+descent
    mov eax, ebx
    imul eax, [rip + cfg_line_height]
    add eax, 50
    xor edx, edx
    mov ecx, 100
    div ecx
    mov ecx, [rip + g_face_code + FACE_ascent]
    add ecx, [rip + g_face_code + FACE_descent]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rip + g_lh], eax
    sub eax, ecx
    sar eax, 1
    add eax, [rip + g_face_code + FACE_ascent]
    mov [rip + g_base], eax
    mov eax, [rip + g_face_code + FACE_cellw]
    cmp eax, 1
    jge 5f
    mov eax, 1
5:  mov [rip + g_cw], eax
4:  EPILOGUE

# ui_force_metrics(): rebuild faces on the next frame (fonts changed)
FN ui_force_metrics
    mov dword ptr [rip + last_scale], 0
    mov dword ptr [rip + last_ui_px], 0
    mov dword ptr [rip + last_code_px], 0
    mov dword ptr [rip + g_dirty], 1
    ret

# sc(v) -> round(v * scale)
FN sc
    cvtsi2ss xmm0, edi
    mulss xmm0, [rip + g_s]
    cvtss2si eax, xmm0
    ret

# ---- input (called from platform callbacks) ----

# ui_input_motion(x, y): while a press waits for its frame the pointer stays where the press was
# made, and the move lands after that frame; otherwise a synthetic click, or a mouse faster than
# the frames, has the press hit tested wherever the pointer went next
FN ui_input_motion
    cmp dword ptr [rip + g_pressed], 0
    jne 1f
    mov [rip + g_mx], edi
    mov [rip + g_my], esi
    ret
1:  mov [rip + held_mx], edi
    mov [rip + held_my], esi
    mov dword ptr [rip + held_move], 1
    ret

# ui_input_button(btn, pressed)
FN ui_input_button
    push rbx
    mov ecx, edi
    mov eax, 1
    shl eax, cl
    test esi, esi
    jz 2f
    or [rip + g_mdown], eax
    or [rip + g_pressed], eax
    cmp edi, BTN_LEFT
    jne 9f
    mov ebx, eax
    # multi-click detection
    mov eax, [rip + g_mx]
    mov [rip + g_press_x], eax
    mov eax, [rip + g_my]
    mov [rip + g_press_y], eax
    call time_ms
    mov rcx, rax
    sub rcx, [rip + last_press_t]
    mov [rip + last_press_t], rax
    cmp rcx, 450
    ja 1f
    mov eax, [rip + g_mx]
    sub eax, [rip + last_press_x]
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, [rip + g_mt + 4*MI_4]
    jg 1f
    mov eax, [rip + g_my]
    sub eax, [rip + last_press_y]
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, [rip + g_mt + 4*MI_4]
    jg 1f
    mov eax, [rip + g_clicks]
    inc eax
    cmp eax, 3
    jbe 3f
    mov eax, 1
3:  mov [rip + g_clicks], eax
    jmp 4f
1:  mov dword ptr [rip + g_clicks], 1
4:  mov eax, [rip + g_mx]
    mov [rip + last_press_x], eax
    mov eax, [rip + g_my]
    mov [rip + last_press_y], eax
    jmp 9f
2:  not eax
    and [rip + g_mdown], eax
    not eax
    or [rip + g_released], eax
9:  pop rbx
    ret

FN ui_input_scroll
    add [rip + g_scroll_x], edi
    add [rip + g_scroll_y], esi
    ret

# ---- frame ----

FN ui_begin
    mov dword ptr [rip + g_hot], 0
    mov dword ptr [rip + g_cursor], CUR_DEFAULT
    mov dword ptr [rip + g_block], 0
    mov dword ptr [rip + g_hole + 12], 0
    ret

FN ui_end
    # clear active when left button is up
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jnz 1f
    mov dword ptr [rip + g_active], 0
1:  mov dword ptr [rip + g_pressed], 0
    mov dword ptr [rip + g_released], 0
    mov dword ptr [rip + g_scroll_x], 0
    mov dword ptr [rip + g_scroll_y], 0
    # the move held back for this frame's press, and a frame that shows it
    cmp dword ptr [rip + held_move], 0
    je 2f
    mov dword ptr [rip + held_move], 0
    mov eax, [rip + held_mx]
    mov [rip + g_mx], eax
    mov eax, [rip + held_my]
    mov [rip + g_my], eax
    mov dword ptr [rip + g_dirty], 1
2:  mov edi, [rip + g_cursor]
    PCALL P_cursor
    ret

# ui_in(x, y, w, h) -> 1 if the mouse is inside (and input not blocked)
FN ui_in
    xor eax, eax
    cmp dword ptr [rip + g_block], 0
    jne 1f
    mov r8d, [rip + g_mx]
    mov r9d, [rip + g_my]
    cmp r8d, edi
    jl 1f
    add edi, edx
    cmp r8d, edi
    jge 1f
    cmp r9d, esi
    jl 1f
    add esi, ecx
    cmp r9d, esi
    jge 1f
    cmp r8d, [rip + g_cv + CV_cx0]
    jl 1f
    cmp r8d, [rip + g_cv + CV_cx1]
    jge 1f
    cmp r9d, [rip + g_cv + CV_cy0]
    jl 1f
    cmp r9d, [rip + g_cv + CV_cy1]
    jge 1f
    # g_hole belongs to a handle drawn later (only the registers this clobbers anyway)
    mov eax, [rip + g_hole + 12]
    test eax, eax
    jz 2f
    mov esi, [rip + g_hole + 4]
    cmp r9d, esi
    jl 2f
    add esi, eax
    cmp r9d, esi
    jge 2f
    mov edi, [rip + g_hole]
    cmp r8d, edi
    jl 2f
    add edi, [rip + g_hole + 8]
    cmp r8d, edi
    jge 2f
    xor eax, eax
    ret
2:  mov eax, 1
1:  ret

# ui_btn(id, x, y, w, h) -> UB_* bits
FN ui_btn
    push rbx
    push r12
    mov ebx, edi
    mov edi, esi
    mov esi, edx
    mov edx, ecx
    mov ecx, r8d
    call ui_in
    xor r12d, r12d
    test eax, eax
    jz 2f
    or r12d, UB_HOVER
    mov [rip + g_hot], ebx
    test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz 1f
    or r12d, UB_PRESS
    mov [rip + g_active], ebx
    cmp dword ptr [rip + g_clicks], 2
    jne 1f
    or r12d, UB_DOUBLE
1:  test dword ptr [rip + g_pressed], 1 << BTN_RIGHT
    jz 11f
    or r12d, UB_RPRESS
11: test dword ptr [rip + g_released], 1 << BTN_LEFT
    jz 2f
    cmp [rip + g_active], ebx
    jne 2f
    or r12d, UB_CLICK
2:  cmp [rip + g_active], ebx
    jne 3f
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jz 3f
    or r12d, UB_HELD
3:  mov eax, r12d
    pop r12
    pop rbx
    ret

# ui_set_cursor(shape) : only when the mouse is not blocked
FN ui_set_cursor
    mov [rip + g_cursor], edi
    ret

# ---- drawing helpers ----

# ui_text_v(face, x, y, h, ptr, len, argb): text vertically centered in [y, y+h)
FN ui_text_v
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov eax, ecx
    sub eax, [rbx + FACE_ascent]
    sub eax, [rbx + FACE_descent]
    sar eax, 1
    add eax, edx
    add eax, [rbx + FACE_ascent]
    mov edx, eax
    mov rcx, r8
    mov r8, r9
    mov r9d, [rbp + 16]
    mov rdi, rbx
    mov esi, r12d
    call text_draw
    EPILOGUE

# ui_text_c(face, x, y, h, cstr, argb) -> x after
FN ui_text_c
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15, r8
    mov [rsp], r9d
    mov rdi, r8
    call strlen
    mov r9, rax
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8, r15
    mov eax, [rsp]
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    EPILOGUE

# ui_text_center(face, x, y, w, h, cstr, argb): centered both ways
FN ui_text_center
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov [rsp], r8d
    mov r15, r9
    mov eax, [rbp + 16]
    mov [rsp + 4], eax
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, [rsp]
    call gfx_clip_push
    mov rdi, r15
    call strlen
    mov [rsp + 8], rax
    mov rdi, rbx
    mov rsi, r15
    mov rdx, rax
    call text_width
    mov esi, r14d
    sub esi, eax
    sar esi, 1
    add esi, r12d
    mov rdi, rbx
    mov edx, r13d
    mov ecx, [rsp]
    mov r8, r15
    mov r9, [rsp + 8]
    mov eax, [rsp + 4]
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    mov [rsp + 16], eax
    call gfx_clip_pop
    mov eax, [rsp + 16]
    EPILOGUE

# ui_icon_center(icon, x, y, w, h, argb): icon (MI_ICON sized) centered in the box
FN ui_icon_center
    push rbx
    push r12
    mov ebx, edi
    mov r12d, r9d
    M eax, MI_ICON
    cmp eax, ecx
    cmovg eax, ecx
    cmp eax, r8d
    cmovg eax, r8d
    test eax, eax
    jle 1f
    sub ecx, eax
    sar ecx, 1
    add esi, ecx
    sub r8d, eax
    sar r8d, 1
    add edx, r8d
    mov edi, ebx
    mov ecx, eax
    mov r8d, r12d
    call icon_draw
1:  pop r12
    pop rbx
    ret

# ui_icon_btn(id, x, y, w, h, icon) -> UB bits ; hover background + muted icon
FN ui_icon_btn
    PROLOGUE 32
    mov [rsp], edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    mov ebx, r9d
    call ui_btn
    mov [rsp + 4], eax
    test eax, UB_HOVER
    jz 1f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    test dword ptr [rsp + 4], UB_HELD
    jz 11f
    COLOR r9d, T_ACTIVE
11: call gfx_round_rect
1:  mov edi, ebx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r15d
    COLOR r9d, T_MUTED
    test dword ptr [rsp + 4], UB_HOVER
    jz 2f
    COLOR r9d, T_FG
2:  call ui_icon_center
    mov eax, [rsp + 4]
    EPILOGUE

# ui_card(x, y, w, h): floating surface with soft shadow and border
FN ui_card
    PROLOGUE
    M r8d, MI_12
    M r9d, MI_4
    M eax, MI_RADIUS
    add eax, [rip + g_mt + 4*MI_2]
    push rax
    push rax
    call ui_card_shadow
    add rsp, 16
    EPILOGUE

# ui_card_shadow(x, y, w, h, spread, drop, [stack] radius): a popup with corners of radius and a
# shadow reaching spread around it and drop below it. Tooltips use a small shadow and the button
# radius; menus and dialogs take the ui_card defaults.
FN ui_card_shadow
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov [rsp], r9d
    mov eax, [rbp + 16]
    mov [rsp + 4], eax
    # shadow: a few expanding translucent rounded rects
    mov ebx, r8d
.Lcard_sh:
    test ebx, ebx
    jle .Lcard_body
    mov edi, r12d
    sub edi, ebx
    mov esi, r13d
    sub esi, ebx
    add esi, [rsp]
    lea edx, [r14 + rbx*2]
    lea ecx, [r15 + rbx*2]
    mov r8d, [rsp + 4]          # shadow corners grow with the spread, from the body's
    sub r8d, [rip + g_mt + 4*MI_2]
    add r8d, ebx
    mov r9d, 0x07000000
    cmp dword ptr [rip + g_theme_dark], 0
    jne 1f
    mov r9d, 0x04000000
1:  call gfx_round_rect
    M eax, MI_2
    sub ebx, eax
    jg .Lcard_sh
.Lcard_body:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    mov r8d, [rsp + 4]
    COLOR r9d, T_BORDER
    COLOR eax, T_POPUP
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    EPILOGUE

# ui_toggle(id, x, y, on) -> 1 if clicked ; 34x20 switch
FN ui_toggle
    PROLOGUE 16
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    M r15d, MI_20
    mov edi, ebx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    add ecx, [rip + g_mt + 4*MI_14]
    mov r8d, r15d
    call ui_btn
    mov [rsp], eax
    # track
    COLOR r9d, T_BORDER
    test r14d, r14d
    jz 1f
    COLOR r9d, T_ACCENT
1:  mov edi, r12d
    mov esi, r13d
    mov edx, r15d
    add edx, [rip + g_mt + 4*MI_14]
    mov ecx, r15d
    mov r8d, r15d
    shr r8d, 1
    call gfx_round_rect
    # knob: white, or the text-on-accent color when on
    M eax, MI_3
    mov edi, r12d
    add edi, eax
    mov r9d, 0xffffffff
    test r14d, r14d
    jz 2f
    add edi, [rip + g_mt + 4*MI_14]
    COLOR r9d, T_ACCENT_FG
2:  lea esi, [r13 + rax]
    mov edx, r15d
    sub edx, eax
    sub edx, eax
    mov ecx, edx
    mov r8d, edx
    shr r8d, 1
    call gfx_round_rect
    mov eax, [rsp]
    and eax, UB_PRESS
    shr eax, 1
    EPILOGUE

# ui_scrollbar(id, x, y, w, h, *offset(i32 px), content, view) ; vertical, draws thumb, handles drag
# args: rdi id, esi x, edx y, ecx w, r8d h, r9 offset ptr, [rbp+16] content, [rbp+24] view
FN ui_scrollbar
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rsp + 16], r8d
    mov r15, r9
    mov r12d, [rbp + 16]        # content
    mov r13d, [rbp + 24]        # view
    cmp r12d, r13d
    jle .Lsb_ret
    # thumb size = max(h * view / content, 24)
    mov eax, [rsp + 16]
    imul eax, r13d
    cdq
    idiv r12d
    M ecx, MI_24
    cmp eax, ecx
    cmovl eax, ecx
    mov r14d, eax               # thumb h
    # thumb y = y + (h - thumb) * off / (content - view)
    mov eax, [rsp + 16]
    sub eax, r14d
    movsxd rax, eax
    mov ecx, [r15]
    movsxd rcx, ecx
    imul rax, rcx               # 64 bits: a long text's offset times the track overflows 32
    mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    cqo
    idiv rcx
    add eax, [rsp + 8]
    mov ebx, eax                # thumb y
    # interaction on the whole track
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 16]
    cmp dword ptr [rip + g_block], 0
    jne .Lsb_blocked
    call ui_btn
    jmp .Lsb_input_ready
.Lsb_blocked:
    xor eax, eax
.Lsb_input_ready:
    mov [rsp + 20], eax
    mov edi, eax
    call sb_cursor
    mov eax, [rsp + 20]
    test eax, UB_PRESS
    jz 1f
    # grab offset inside thumb (or jump so the thumb centers on the mouse)
    mov eax, [rip + g_my]
    sub eax, ebx
    js 2f
    cmp eax, r14d
    jl 3f
2:  mov eax, r14d
    shr eax, 1
3:  mov [rip + grab_dy], eax
1:  test dword ptr [rsp + 20], UB_HELD
    jz 4f
    # offset = (my - grab - y) * (content - view) / (h - thumb)
    mov eax, [rip + g_my]
    sub eax, [rip + grab_dy]
    sub eax, [rsp + 8]
    movsxd rax, eax
    mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    imul rax, rcx               # in 64 bits, as the thumb's position
    mov ecx, [rsp + 16]
    sub ecx, r14d
    jle 4f
    movsxd rcx, ecx
    cqo
    idiv rcx
    test rax, rax
    jns 5f
    xor eax, eax
5:  mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    cmp rax, rcx
    cmovg rax, rcx
    mov [r15], eax
    mov dword ptr [rip + g_dirty], 1
4:  mov edi, [rsp]
    mov rsi, r15
    mov edx, [rsp + 20]
    call sb_thumb
    test eax, eax
    jz .Lsb_ret
    mov r9d, edx
    mov ecx, [rsp + 12]
    mov edx, eax
    mov edi, [rsp + 4]
    add edi, ecx
    sub edi, eax
    sub edi, [rip + g_mt + 4*MI_3]
    mov esi, ebx
    mov ecx, r14d
    mov r8d, eax
    shr r8d, 1
    call gfx_round_rect
.Lsb_ret:
    EPILOGUE

# ui_hscrollbar(id, x, y, w, h, *offset(i32 px), content, view): ui_scrollbar along x, its thumb at the
# bottom of the track
FN ui_hscrollbar
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rsp + 16], r8d
    mov r15, r9
    mov r12d, [rbp + 16]        # content
    mov r13d, [rbp + 24]        # view
    cmp r12d, r13d
    jle .Lhs_ret
    # thumb width = max(w * view / content, 24)
    mov eax, [rsp + 12]
    imul eax, r13d
    cdq
    idiv r12d
    M ecx, MI_24
    cmp eax, ecx
    cmovl eax, ecx
    mov r14d, eax               # thumb w
    # thumb x = x + (w - thumb) * off / (content - view)
    mov eax, [rsp + 12]
    sub eax, r14d
    movsxd rax, eax
    mov ecx, [r15]
    movsxd rcx, ecx
    imul rax, rcx               # 64 bits: a long text's offset times the track overflows 32
    mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    cqo
    idiv rcx
    add eax, [rsp + 4]
    mov ebx, eax                # thumb x
    # interaction on the whole track
    xor eax, eax
    cmp dword ptr [rip + g_block], 0
    jne 0f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 16]
    call ui_btn
0:  mov [rsp + 20], eax
    mov edi, eax
    call sb_cursor
    mov eax, [rsp + 20]
    test eax, UB_PRESS
    jz 1f
    # grab offset inside thumb (or jump so the thumb centers on the mouse)
    mov eax, [rip + g_mx]
    sub eax, ebx
    js 2f
    cmp eax, r14d
    jl 3f
2:  mov eax, r14d
    shr eax, 1
3:  mov [rip + grab_dx], eax
1:  test dword ptr [rsp + 20], UB_HELD
    jz 4f
    # offset = (mx - grab - x) * (content - view) / (w - thumb)
    mov eax, [rip + g_mx]
    sub eax, [rip + grab_dx]
    sub eax, [rsp + 4]
    movsxd rax, eax
    mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    imul rax, rcx               # in 64 bits, as the thumb's position
    mov ecx, [rsp + 12]
    sub ecx, r14d
    jle 4f
    movsxd rcx, ecx
    cqo
    idiv rcx
    test rax, rax
    jns 5f
    xor eax, eax
5:  mov ecx, r12d
    sub ecx, r13d
    movsxd rcx, ecx
    cmp rax, rcx
    cmovg rax, rcx
    mov [r15], eax
    mov dword ptr [rip + g_dirty], 1
4:  mov edi, [rsp]
    mov rsi, r15
    mov edx, [rsp + 20]
    call sb_thumb
    test eax, eax
    jz .Lhs_ret
    mov r9d, edx
    mov ecx, eax                # thickness
    mov edi, ebx
    mov esi, [rsp + 8]
    add esi, [rsp + 16]
    sub esi, eax
    sub esi, [rip + g_mt + 4*MI_3]
    mov edx, r14d
    mov r8d, eax
    shr r8d, 1
    call gfx_round_rect
.Lhs_ret:
    EPILOGUE

# sb_tick(): expire scroll-flash windows that have passed
FN sb_tick
    push rbx
    push r12
    sub rsp, 8
    call time_ms
    mov r12, rax
    lea rbx, [rip + sb_flash]
    mov ecx, SB_MAX
1:  mov rax, [rbx + 16]
    test rax, rax
    jz 2f
    cmp r12, rax
    jb 2f
    mov qword ptr [rbx + 16], 0
    mov dword ptr [rip + g_dirty], 1
2:  add rbx, 24
    dec ecx
    jnz 1b
    add rsp, 8
    pop r12
    pop rbx
    ret

# sb_timeout() -> ms until the oldest scroll-flash window closes, or -1
FN sb_timeout
    push rbx
    push r12
    sub rsp, 8
    call time_ms
    mov r12, rax
    lea rbx, [rip + sb_flash]
    mov ecx, SB_MAX
    mov edx, -1
1:  mov rax, [rbx + 16]
    test rax, rax
    jz 2f
    sub rax, r12
    jle 2f                          # already due: sb_tick clears it
    cmp edx, -1
    je 3f
    cmp eax, edx
    jge 2f
3:  mov edx, eax
2:  add rbx, 24
    dec ecx
    jnz 1b
    mov eax, edx
    add rsp, 8
    pop r12
    pop rbx
    ret

# sb_cursor(bits): the arrow over a scrollbar or while its thumb is dragged, but not over another
# widget's drag
sb_cursor:
    test edi, UB_HELD
    jnz 1f
    test edi, UB_HOVER
    jz 2f
    cmp dword ptr [rip + g_active], 0
    jne 2f
1:  mov dword ptr [rip + g_cursor], CUR_ARROW
2:  ret

# sb_thumb(id, *offset, bits) -> eax thumb thickness (0: none), edx its color. The full thumb while
# hovered or dragged, or for SB_SHOW_MS after the offset last moved; otherwise none, or a faint thin
# one when scrollbars do not auto-hide. Each scrollbar id keeps its own sb_flash slot (an offset on
# the caller's stack moves with its depth, so the id is the key).
sb_thumb:
    PROLOGUE
    mov ebx, edx
    mov r12, rsi
    mov r14d, edi
    lea r13, [rip + sb_flash]
    xor ecx, ecx
1:  cmp [r13], r14
    je 3f
    cmp qword ptr [r13], 0
    jne 2f
    mov [r13], r14
    mov eax, [r12]                  # seed, don't flash, on first sight
    mov [r13 + 8], eax
    jmp 3f
2:  add r13, 24
    inc ecx
    cmp ecx, SB_MAX
    jl 1b
    jmp 5f                          # table full: keep the thumb shown
3:  call time_ms
    mov ecx, [r12]
    cmp ecx, [r13 + 8]
    je 4f
    mov [r13 + 8], ecx
    lea rdx, [rax + SB_SHOW_MS]
    mov [r13 + 16], rdx
4:  test ebx, UB_HOVER | UB_HELD
    jnz 5f
    cmp rax, [r13 + 16]
    jl 5f
    xor eax, eax
    cmp dword ptr [rip + cfg_autohide_scrollbars], 0
    jne 9f
    COLOR edx, T_SCROLLBAR
    and edx, 0x00ffffff
    or edx, 0xa0000000
    M eax, MI_4
    jmp 9f
5:  COLOR edx, T_SCROLLBAR
    M eax, MI_6
9:  EPILOGUE

# ---- text field ----

# tf_text(tf) -> rax ptr, rdx len
FN tf_text
    mov rax, [rdi + TF_sb + SB_ptr]
    mov rdx, [rdi + TF_sb + SB_len]
    test rax, rax
    jnz 1f
    lea rax, [rip + empty_str]
1:  ret

# tf_set(tf, ptr, len): replace contents, cursor at end
FN tf_set
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rbx + TF_sb]
    call sb_clear
    lea rdi, [rbx + TF_sb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov [rbx + TF_cur], r13
    mov [rbx + TF_anchor], r13
    mov dword ptr [rbx + TF_prefx], -1
    pop r13
    pop r12
    pop rbx
    ret

# tf_clear(tf)
FN tf_clear
    xor esi, esi
    xor edx, edx
    lea rsi, [rip + empty_str]
    jmp tf_set

# tf_select_all(tf)
FN tf_select_all
    mov qword ptr [rdi + TF_anchor], 0
    mov rax, [rdi + TF_sb + SB_len]
    mov [rdi + TF_cur], rax
    ret

# tf_sel(tf) -> rax start, rdx end
tf_sel:
    mov rax, [rdi + TF_cur]
    mov rdx, [rdi + TF_anchor]
    cmp rax, rdx
    jbe 1f
    xchg rax, rdx
1:  ret

# tf_delete_sel(tf) -> 1 if something was deleted
tf_delete_sel:
    push rbx
    mov rbx, rdi
    call tf_sel
    cmp rax, rdx
    je 1f
    mov rdi, rbx
    mov rsi, rax
    sub rdx, rax
    call tf_remove
    mov eax, 1
    pop rbx
    ret
1:  xor eax, eax
    pop rbx
    ret

# tf_remove(tf, pos, n)
tf_remove:
    push rbx
    mov rbx, rdi
    mov r8, [rbx + TF_sb + SB_ptr]
    lea rdi, [r8 + rsi]
    lea r9, [rsi + rdx]
    push rsi
    lea rsi, [r8 + r9]
    mov rcx, [rbx + TF_sb + SB_len]
    sub rcx, r9
    inc rcx                     # keep NUL
    push rdx
    mov rdx, rcx
    call memmove
    pop rdx
    pop rsi
    sub [rbx + TF_sb + SB_len], rdx
    mov [rbx + TF_cur], rsi
    mov [rbx + TF_anchor], rsi
    pop rbx
    ret

# tf_insert(tf, ptr, len): replaces selection; newlines become spaces
FN tf_insert
    xor ecx, ecx
    jmp tf_insert_as
# tf_insert_raw(tf, ptr, len): tf_insert that keeps the bytes as they are
tf_insert_raw:
    mov ecx, 1
tf_insert_as:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15d, ecx
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call tf_delete_sel
    lea rdi, [rbx + TF_sb]
    mov rsi, r13
    call sb_reserve
    # shift tail
    mov r14, [rbx + TF_cur]
    mov r8, [rbx + TF_sb + SB_ptr]
    lea rsi, [r8 + r14]
    lea rdi, [rsi + r13]
    mov rdx, [rbx + TF_sb + SB_len]
    sub rdx, r14
    inc rdx
    call memmove
    mov r8, [rbx + TF_sb + SB_ptr]
    xor ecx, ecx
1:  cmp rcx, r13
    jae 2f
    movzx eax, byte ptr [r12 + rcx]
    test r15d, r15d
    jnz 12f
    cmp al, 10
    je 11f
    cmp al, 13
    je 11f
    cmp al, 9
    jne 12f
11: mov al, ' '
12: lea rdx, [r14 + rcx]
    mov [r8 + rdx], al
    inc rcx
    jmp 1b
2:  add [rbx + TF_sb + SB_len], r13
    add r14, r13
    mov [rbx + TF_cur], r14
    mov [rbx + TF_anchor], r14
    mov dword ptr [rbx + TF_prefx], -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# utf-8 steps inside the field
tf_next:
    mov rax, rsi
    cmp rax, [rdi + TF_sb + SB_len]
    jae 2f
    mov r8, [rdi + TF_sb + SB_ptr]
1:  inc rax
    cmp rax, [rdi + TF_sb + SB_len]
    jae 2f
    movzx ecx, byte ptr [r8 + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    je 1b
2:  ret
tf_prev:
    mov rax, rsi
    test rax, rax
    jz 2f
    mov r8, [rdi + TF_sb + SB_ptr]
1:  dec rax
    jz 2f
    movzx ecx, byte ptr [r8 + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    je 1b
2:  ret
tf_word_left:
    mov rax, rsi
    mov r8, [rdi + TF_sb + SB_ptr]
1:  test rax, rax
    jz 3f
    cmp byte ptr [r8 + rax - 1], ' '
    ja 2f
    dec rax
    jmp 1b
2:  test rax, rax
    jz 3f
    cmp byte ptr [r8 + rax - 1], ' '
    jbe 3f
    cmp byte ptr [r8 + rax - 1], '/'
    je 3f
    dec rax
    jmp 2b
3:  ret
tf_word_right:
    mov rax, rsi
    mov r8, [rdi + TF_sb + SB_ptr]
    mov r9, [rdi + TF_sb + SB_len]
1:  cmp rax, r9
    jae 3f
    cmp byte ptr [r8 + rax], ' '
    ja 2f
    inc rax
    jmp 1b
2:  cmp rax, r9
    jae 3f
    cmp byte ptr [r8 + rax], ' '
    jbe 3f
    cmp byte ptr [r8 + rax], '/'
    je 31f
    inc rax
    jmp 2b
31: inc rax
3:  ret

# tf_key(tf, keysym, cp, mods) -> 1 if handled (text changed or cursor moved)
FN tf_key
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    test r14d, MOD_CTRL
    jz .Ltk_nav
    cmp r12d, 'a'
    jne 1f
    mov rdi, rbx
    call tf_select_all
    jmp .Ltk_yes
1:  cmp r12d, 'c'
    je .Ltk_copy
    cmp r12d, 'x'
    je .Ltk_copy
    cmp r12d, 'v'
    jne 2f
    PCALL P_clip_get
    jmp .Ltk_yes
2:  cmp r12d, KEY_BACKSPACE
    jne .Ltk_nav
    mov rdi, rbx
    call tf_delete_sel
    test eax, eax
    jnz .Ltk_yes
    mov rdi, rbx
    mov rsi, [rbx + TF_cur]
    call tf_word_left
    mov rsi, rax
    mov rdx, [rbx + TF_cur]
    sub rdx, rax
    mov rdi, rbx
    call tf_remove
    jmp .Ltk_yes
.Ltk_copy:
    mov rdi, rbx
    call tf_sel
    cmp rax, rdx
    je .Ltk_yes
    mov rsi, rdx
    sub rsi, rax
    mov rdi, [rbx + TF_sb + SB_ptr]
    add rdi, rax
    PCALL P_clip_set
    cmp r12d, 'x'
    jne .Ltk_yes
    mov rdi, rbx
    call tf_delete_sel
    jmp .Ltk_yes
.Ltk_nav:
    mov r15, [rbx + TF_cur]
    cmp r12d, KEY_LEFT
    jne 3f
    mov rdi, rbx
    call tf_sel
    cmp rax, rdx
    je 31f
    test r14d, MOD_SHIFT
    jnz 31f
    mov r15, rax
    jmp .Ltk_move
31: mov rdi, rbx
    mov rsi, r15
    test r14d, MOD_CTRL
    jz 32f
    call tf_word_left
    jmp 33f
32: call tf_prev
33: mov r15, rax
    jmp .Ltk_move
3:  cmp r12d, KEY_RIGHT
    jne 4f
    mov rdi, rbx
    call tf_sel
    cmp rax, rdx
    je 41f
    test r14d, MOD_SHIFT
    jnz 41f
    mov r15, rdx
    jmp .Ltk_move
41: mov rdi, rbx
    mov rsi, r15
    test r14d, MOD_CTRL
    jz 42f
    call tf_word_right
    jmp 43f
42: call tf_next
43: mov r15, rax
    jmp .Ltk_move
4:  cmp r12d, KEY_HOME
    jne 5f
    xor r15d, r15d
    jmp .Ltk_move
5:  cmp r12d, KEY_END
    jne 6f
    mov r15, [rbx + TF_sb + SB_len]
    jmp .Ltk_move
6:  cmp r12d, KEY_BACKSPACE
    jne 7f
    mov rdi, rbx
    call tf_delete_sel
    test eax, eax
    jnz .Ltk_yes
    mov rdi, rbx
    mov rsi, r15
    call tf_prev
    mov rsi, rax
    mov rdx, r15
    sub rdx, rax
    jz .Ltk_yes
    mov rdi, rbx
    call tf_remove
    jmp .Ltk_yes
7:  cmp r12d, KEY_DELETE
    jne 8f
    mov rdi, rbx
    call tf_delete_sel
    test eax, eax
    jnz .Ltk_yes
    mov rdi, rbx
    mov rsi, r15
    call tf_next
    mov rdx, rax
    sub rdx, r15
    jz .Ltk_yes
    mov rdi, rbx
    mov rsi, r15
    call tf_remove
    jmp .Ltk_yes
8:  # printable text
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Ltk_no
    cmp r13d, 32
    jb .Ltk_no
    cmp r13d, 127
    je .Ltk_no
    mov edi, r13d
    lea rsi, [rsp]
    call utf8_encode
    mov rdi, rbx
    lea rsi, [rsp]
    mov rdx, rax
    call tf_insert
    jmp .Ltk_yes
.Ltk_move:
    mov [rbx + TF_cur], r15
    test r14d, MOD_SHIFT
    jnz .Ltk_yes
    mov [rbx + TF_anchor], r15
.Ltk_yes:
    mov dword ptr [rbx + TF_prefx], -1
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Ltk_no:
    xor eax, eax
    EPILOGUE

# ui_textfield(tf, x, y, w, h, focused, placeholder): draw field, mouse sets cursor. -> UB bits
FN ui_textfield
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], esi              # x
    mov [rsp + 4], edx          # y
    mov [rsp + 8], ecx          # w
    mov [rsp + 12], r8d         # h
    mov [rsp + 16], r9d         # focused
    mov rax, [rbp + 16]
    mov [rsp + 24], rax         # placeholder
    mov edi, [rbx + TF_id]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov r8d, [rsp + 12]
    call ui_btn
    mov [rsp + 20], eax
    test eax, UB_HOVER
    jz 1f
    mov dword ptr [rip + g_cursor], CUR_TEXT
1:  # background
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    cmp dword ptr [rsp + 16], 0
    je 2f
    COLOR r9d, T_ACCENT
2:  COLOR eax, T_INPUT
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    # content
    M r12d, MI_10
    add r12d, [rsp]             # text x
    mov edi, [rsp]
    add edi, [rip + g_mt + 4*MI_2]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    sub edx, [rip + g_mt + 4*MI_4]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    mov rdi, rbx
    call tf_text
    mov r14, rax
    mov r15, rdx
    # mouse: place cursor
    mov eax, [rsp + 20]
    test eax, UB_PRESS | UB_HELD
    jz 3f
    mov ecx, [rip + g_mx]
    sub ecx, r12d
    add ecx, [rbx + TF_scroll]
    js 21f
    lea rdi, [rip + g_face_ui]
    mov rsi, r14
    mov rdx, r15
    call text_fit
    jmp 22f
21: xor eax, eax
22: mov [rbx + TF_cur], rax
    test dword ptr [rsp + 20], UB_PRESS
    jz 3f
    mov [rbx + TF_anchor], rax
3:  # keep cursor visible
    lea rdi, [rip + g_face_ui]
    mov rsi, r14
    mov rdx, [rbx + TF_cur]
    call text_width
    mov r13d, eax               # cursor offset px
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_24]
    mov eax, r13d
    sub eax, [rbx + TF_scroll]
    cmp eax, ecx
    jle 4f
    mov eax, r13d
    sub eax, ecx
    mov [rbx + TF_scroll], eax
4:  cmp r13d, [rbx + TF_scroll]
    jge 5f
    mov [rbx + TF_scroll], r13d
5:  sub r12d, [rbx + TF_scroll]
    test r15, r15
    jnz 6f
    # placeholder
    mov rdi, [rsp + 24]
    test rdi, rdi
    jz 7f
    lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, [rsp + 24]
    COLOR r9d, T_MUTED
    call ui_text_c
    jmp 7f
6:  # selection
    mov rdi, rbx
    call tf_sel
    cmp rax, rdx
    je 61f
    mov [rsp + 32], rax
    mov [rsp + 40], rdx
    lea rdi, [rip + g_face_ui]
    mov rsi, r14
    mov rdx, rax
    call text_width
    mov r13d, eax
    lea rdi, [rip + g_face_ui]
    mov rsi, r14
    mov rdx, [rsp + 40]
    call text_width
    sub eax, r13d
    mov edx, eax
    lea edi, [r12 + r13]
    mov esi, [rsp + 4]
    add esi, [rip + g_mt + 4*MI_6]
    mov ecx, [rsp + 12]
    sub ecx, [rip + g_mt + 4*MI_12]
    COLOR r8d, T_SELECTION
    call gfx_fill
61: lea rdi, [rip + g_face_ui]
    mov esi, r12d
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, r14
    mov r9, r15
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
7:  # caret, blinking as the editor's
    cmp dword ptr [rsp + 16], 0
    je 8f
    call ed_caret_shown
    test eax, eax
    jz 8f
    lea rdi, [rip + g_face_ui]
    mov rsi, r14
    mov rdx, [rbx + TF_cur]
    call text_width
    lea edi, [r12 + rax]
    mov esi, [rsp + 4]
    add esi, [rip + g_mt + 4*MI_6]
    M edx, MI_2
    mov ecx, [rsp + 12]
    sub ecx, [rip + g_mt + 4*MI_12]
    COLOR r8d, T_CURSOR
    call gfx_fill
8:  call gfx_clip_pop
    mov eax, [rsp + 20]
    EPILOGUE

# ---- text area: a text field of several lines ----

# ln_start(ptr, pos) -> rax start of the line holding pos
ln_start:
    mov rax, rsi
1:  test rax, rax
    jz 2f
    cmp byte ptr [rdi + rax - 1], 10
    je 2f
    dec rax
    jmp 1b
2:  ret

# ln_end(ptr, len, pos) -> rax the line break ending the line of pos, or len
ln_end:
    mov rax, rdx
1:  cmp rax, rsi
    jae 2f
    cmp byte ptr [rdi + rax], 10
    je 2f
    inc rax
    jmp 1b
2:  ret

# ta_layout(tf, outer width) -> eax visual rows; wrapping is always on
FN ta_layout
    sub esi, [rip + g_mt + 4*MI_24]
    mov eax, 1
    cmp esi, eax
    cmovl esi, eax
    cmp esi, [rdi + TF_width]
    je 1f
    mov [rdi + TF_width], esi
    mov dword ptr [rdi + TF_prefx], -1
1:  jmp ta_lines

# ta_lines(tf) -> eax visual rows, rebuilding the shared row ranges (start, end).
# Explicit newlines separate rows; soft breaks preserve every byte of the message.
FN ta_lines
    PROLOGUE 16
    mov rbx, rdi
    mov qword ptr [rip + ta_rows + VEC_len], 0
    call tf_text
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d              # row start
.Ltl_line:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call ln_end
    mov r15, rax                # logical line end
.Ltl_row:
    lea rdi, [rip + g_face_ui]
    lea rsi, [r12 + r14]
    mov rdx, r15
    sub rdx, r14
    mov ecx, [rbx + TF_width]
    test ecx, ecx
    jnz 1f
    mov ecx, 1048576            # before the first layout, keep explicit lines
1:  call text_fit
    add rax, r14
    cmp rax, r15
    jae .Ltl_end
    cmp rax, r14
    jne 2f
    # A glyph wider than the field still occupies one row, never half a codepoint.
    lea rdi, [r12 + r14]
    mov rsi, r15
    sub rsi, r14
    call utf8_decode
    lea rax, [r14 + rdx]
    jmp .Ltl_emit
2:  # Prefer a word boundary within the prefix that fits.
    mov rcx, rax
3:  cmp rcx, r14
    jbe .Ltl_emit
    cmp byte ptr [r12 + rcx - 1], ' '
    je 4f
    dec rcx
    jmp 3b
4:  mov rax, rcx
.Ltl_emit:
    mov [rsp], rax
    lea rdi, [rip + ta_rows]
    mov esi, 16
    call vec_push
    mov [rax], r14
    mov rcx, [rsp]
    mov [rax + 8], rcx
    mov r14, rcx
    cmp r14, r15
    jb .Ltl_row
    jmp .Ltl_next
.Ltl_end:
    mov rax, r15
    jmp .Ltl_emit
.Ltl_next:
    cmp r15, r13
    jae .Ltl_done
    lea r14, [r15 + 1]
    jmp .Ltl_line
.Ltl_done:
    mov rax, [rip + ta_rows + VEC_len]
    EPILOGUE

# ta_row_of(pos) -> row in the last layout; a soft break belongs to the next row
FN ta_row_of
    mov r8, [rip + ta_rows + VEC_ptr]
    xor eax, eax
    mov rcx, [rip + ta_rows + VEC_len]
1:  mov rdx, rcx
    sub rdx, rax
    cmp rdx, 1
    jbe 3f
    lea rdx, [rax + rcx]
    shr rdx, 1
    mov r9, rdx
    shl r9, 4
    cmp [r8 + r9], rdi
    ja 2f
    mov rax, rdx
    jmp 1b
2:  mov rcx, rdx
    jmp 1b
3:  ret

# ta_row_bounds(row) -> rax start, rdx end; out-of-range rows use the last row
FN ta_row_bounds
    mov rax, [rip + ta_rows + VEC_len]
    dec rax
    cmp rdi, rax
    cmovb rax, rdi
    shl rax, 4
    add rax, [rip + ta_rows + VEC_ptr]
    mov rdx, [rax + 8]
    mov rax, [rax]
    ret

# ta_row_limit(tf, row) -> last caret position belonging to that row
FN ta_row_limit
    push rbx
    mov rbx, rdi
    mov rdi, rsi
    call ta_row_bounds
    mov rax, rdx
    inc rsi
    cmp rsi, [rip + ta_rows + VEC_len]
    jae 1f
    shl rsi, 4
    add rsi, [rip + ta_rows + VEC_ptr]
    cmp [rsi], rax
    jne 1f                     # explicit newline: its position is on this row
    mov rdi, rbx
    mov rsi, rax
    call tf_prev
1:  pop rbx
    ret

# ta_line_h() -> eax height of a line of a text area
FN ta_line_h
    mov eax, [rip + g_face_ui + FACE_lineh]
    add eax, [rip + g_mt + 4*MI_3]
    ret

# ta_insert(tf, ptr, len): replaces the selection; CR LF and CR become line breaks, tabs spaces
FN ta_insert
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + ta_buf]
    call sb_clear
    xor r14d, r14d
1:  cmp r14, r13
    jae 4f
    movzx esi, byte ptr [r12 + r14]
    inc r14
    cmp esi, 13
    jne 2f
    mov esi, 10
    cmp r14, r13
    jae 3f
    cmp byte ptr [r12 + r14], 10
    jne 3f
    inc r14                     # CR LF
    jmp 3f
2:  cmp esi, 9
    jne 3f
    mov esi, ' '
3:  lea rdi, [rip + ta_buf]
    call sb_push_byte
    jmp 1b
4:  mov rdi, rbx
    mov rsi, [rip + ta_buf + SB_ptr]
    mov rdx, [rip + ta_buf + SB_len]
    call tf_insert_raw
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ta_key(tf, keysym, cp, mods) -> 1 if handled: Up/Down cross visual rows;
# Home/End keep their logical-line behavior, and Enter inserts an explicit newline
FN ta_key
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    cmp r12d, KEY_RETURN
    je 1f
    cmp r12d, KEY_KP_ENTER
    jne 2f
1:  test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Ltak_no
    mov rdi, rbx
    lea rsi, [rip + ta_nl]
    mov edx, 1
    call tf_insert_raw
    jmp .Ltak_yes
2:  test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Ltak_tf
    mov rdi, rbx
    call tf_text
    mov r15, rax
    mov [rsp], rdx              # length
    cmp r12d, KEY_HOME
    jne 3f
    mov dword ptr [rbx + TF_prefx], -1
    mov rdi, r15
    mov rsi, [rbx + TF_cur]
    call ln_start
    jmp .Ltak_move
3:  cmp r12d, KEY_END
    jne 4f
    mov dword ptr [rbx + TF_prefx], -1
    mov rdi, r15
    mov rsi, [rsp]
    mov rdx, [rbx + TF_cur]
    call ln_end
    jmp .Ltak_move
4:  cmp r12d, KEY_UP
    je 5f
    cmp r12d, KEY_DOWN
    jne .Ltak_tf
5:  mov rdi, rbx
    call ta_lines
    mov rdi, [rbx + TF_cur]
    call ta_row_of
    mov [rsp + 24], rax         # current visual row
    mov rdi, rax
    call ta_row_bounds
    mov [rsp + 16], rax
    cmp dword ptr [rbx + TF_prefx], -1
    jne 51f
    lea rdi, [rip + g_face_ui]
    lea rsi, [r15 + rax]
    mov rdx, [rbx + TF_cur]
    sub rdx, rax
    call text_width
    mov [rbx + TF_prefx], eax
51: mov r13d, [rbx + TF_prefx]
    mov rsi, [rsp + 24]
    cmp r12d, KEY_UP
    jne 6f
    test rsi, rsi
    jz 8f
    dec rsi
    jmp 7f
6:  inc rsi
    cmp rsi, [rip + ta_rows + VEC_len]
    jae 9f
7:  mov [rsp + 24], rsi
    mov rdi, rbx
    call ta_row_limit
    mov [rsp + 8], rax
    mov rdi, [rsp + 24]
    call ta_row_bounds
    mov [rsp + 16], rax
    lea rdi, [rip + g_face_ui]
    lea rsi, [r15 + rax]
    mov rdx, [rsp + 8]
    sub rdx, rax
    mov ecx, r13d
    call text_fit
    add rax, [rsp + 16]
    jmp .Ltak_move
8:  xor eax, eax               # above the first row: to the message start
    jmp .Ltak_move
9:  mov rax, [rsp]             # below the last row: to the message end
.Ltak_move:
    mov [rbx + TF_cur], rax
    test r14d, MOD_SHIFT
    jnz .Ltak_yes
    mov [rbx + TF_anchor], rax
.Ltak_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Ltak_tf:
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
    EPILOGUE
.Ltak_no:
    xor eax, eax
    EPILOGUE

# ui_textarea(tf, x, y, w, h, focused, placeholder): always wrap at the available
# width, keeping the caret's visual row in view; the mouse places the cursor -> UB bits
FN ui_textarea
    PROLOGUE 96
    mov rbx, rdi
    mov [rsp], esi              # x
    mov [rsp + 4], edx          # y
    mov [rsp + 8], ecx          # w
    mov [rsp + 12], r8d         # h
    mov [rsp + 16], r9d         # focused
    mov rax, [rbp + 16]
    mov [rsp + 24], rax         # placeholder
    mov rdi, rbx
    mov esi, [rsp + 8]
    call ta_layout
    mov [rsp + 80], eax         # total visual rows
    mov dword ptr [rbx + TF_scroll], 0
    call ta_line_h
    mov [rsp + 32], eax         # line h
    M eax, MI_10
    add eax, [rsp]
    mov [rsp + 36], eax         # text x
    M eax, MI_6
    add eax, [rsp + 4]
    mov [rsp + 40], eax         # first line y
    mov eax, [rsp + 12]
    sub eax, [rip + g_mt + 4*MI_12]
    mov ecx, 1
    jle 1f
    xor edx, edx
    div dword ptr [rsp + 32]
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, eax
1:  mov [rsp + 44], ecx         # lines shown
    mov edi, [rbx + TF_id]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call ui_btn
    mov [rsp + 20], eax
    test eax, UB_HOVER
    jz 2f
    mov dword ptr [rip + g_cursor], CUR_TEXT
2:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    cmp dword ptr [rsp + 16], 0
    je 3f
    COLOR r9d, T_ACCENT
3:  COLOR eax, T_INPUT
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    mov rdi, rbx
    call tf_text
    mov r14, rax
    mov r15, rdx
    # the mouse places the cursor
    test dword ptr [rsp + 20], UB_PRESS | UB_HELD
    jz 5f
    mov eax, [rip + g_my]
    sub eax, [rsp + 40]
    jns 41f
    xor eax, eax
41: xor edx, edx
    div dword ptr [rsp + 32]
    add eax, [rbx + TF_top]
    mov [rsp + 48], eax
    mov esi, eax
    mov rdi, rbx
    call ta_row_limit
    mov r13, rax
    mov edi, [rsp + 48]
    call ta_row_bounds
    mov r12, rax
    mov ecx, [rip + g_mx]
    sub ecx, [rsp + 36]
    add ecx, [rbx + TF_scroll]
    mov eax, 0
    js 42f
    lea rdi, [rip + g_face_ui]
    lea rsi, [r14 + r12]
    mov rdx, r13
    sub rdx, r12
    call text_fit
42: add rax, r12
    mov [rbx + TF_cur], rax
    mov dword ptr [rbx + TF_prefx], -1
    test dword ptr [rsp + 20], UB_PRESS
    jz 5f
    mov [rbx + TF_anchor], rax
5:  # the cursor's line and x
    mov rdi, [rbx + TF_cur]
    call ta_row_of
    mov [rsp + 72], eax
    mov rdi, rax
    call ta_row_bounds
    lea rdi, [rip + g_face_ui]
    lea rsi, [r14 + rax]
    mov rdx, [rbx + TF_cur]
    sub rdx, rax
    call text_width
    mov [rsp + 52], eax
    # Keep the caret's visual row in view, with no empty rows below the text.
    mov eax, [rsp + 72]
    cmp eax, [rbx + TF_top]
    jge 53f
    mov [rbx + TF_top], eax
53: sub eax, [rsp + 44]
    inc eax
    cmp eax, [rbx + TF_top]
    jle 54f
    mov [rbx + TF_top], eax
54: mov eax, [rsp + 80]
    sub eax, [rsp + 44]
    jns 55f
    xor eax, eax
55: cmp [rbx + TF_top], eax
    jle 56f
    mov [rbx + TF_top], eax
56: mov edi, [rsp]
    add edi, [rip + g_mt + 4*MI_2]
    mov esi, [rsp + 4]
    add esi, [rip + g_mt + 4*MI_2]
    mov edx, [rsp + 8]
    sub edx, [rip + g_mt + 4*MI_4]
    mov ecx, [rsp + 12]
    sub ecx, [rip + g_mt + 4*MI_4]
    call gfx_clip_push
    mov eax, [rsp + 36]
    sub eax, [rbx + TF_scroll]
    mov [rsp + 36], eax
    test r15, r15
    jnz 6f
    # placeholder
    mov r8, [rsp + 24]
    test r8, r8
    jz .Lta_caret
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 36]
    mov edx, [rsp + 40]
    mov ecx, [rsp + 32]
    COLOR r9d, T_MUTED
    call ui_text_c
    jmp .Lta_caret
6:  mov rdi, rbx
    call tf_sel
    mov [rsp + 56], rax
    mov [rsp + 64], rdx
    mov eax, [rbx + TF_top]
    mov [rsp + 48], eax
    mov eax, [rsp + 40]
    mov [rsp + 76], eax         # line y
.Lta_line:
    mov eax, [rsp + 48]
    sub eax, [rbx + TF_top]
    cmp eax, [rsp + 44]
    jge .Lta_caret
    mov eax, [rsp + 48]
    cmp eax, [rsp + 80]
    jae .Lta_caret
    mov edi, eax
    call ta_row_bounds
    mov r12, rax                # row start
    mov r13, rdx                # row end
    # the selection on this line, and a little more when it goes on past the break
    mov rax, [rsp + 56]
    cmp rax, [rsp + 64]
    je 8f
    cmp [rsp + 64], r12
    jbe 8f
    cmp rax, r13
    ja 8f
    cmp rax, r12
    cmovb rax, r12
    lea rdi, [rip + g_face_ui]
    lea rsi, [r14 + r12]
    mov rdx, rax
    sub rdx, r12
    call text_width
    mov [rsp + 88], eax
    mov rdx, [rsp + 64]
    cmp rdx, r13
    cmova rdx, r13
    lea rdi, [rip + g_face_ui]
    lea rsi, [r14 + r12]
    sub rdx, r12
    call text_width
    cmp [rsp + 64], r13
    jbe 71f
    cmp r13, r15
    jae 71f
    cmp byte ptr [r14 + r13], 10
    jne 71f
    add eax, [rip + g_face_ui + FACE_cellw]
71: sub eax, [rsp + 88]
    jle 8f
    mov edx, eax
    mov edi, [rsp + 36]
    add edi, [rsp + 88]
    mov esi, [rsp + 76]
    mov ecx, [rsp + 32]
    COLOR r8d, T_SELECTION
    call gfx_fill
8:  mov r9, r13
    sub r9, r12
    jz 81f
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 36]
    mov edx, [rsp + 76]
    mov ecx, [rsp + 32]
    lea r8, [r14 + r12]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
81: cmp r13, r15
    jae .Lta_caret
    inc dword ptr [rsp + 48]
    mov eax, [rsp + 32]
    add [rsp + 76], eax
    jmp .Lta_line
.Lta_caret:
    cmp dword ptr [rsp + 16], 0
    je 9f
    call ed_caret_shown          # blinking as the editor's
    test eax, eax
    jz 9f
    mov eax, [rsp + 72]
    sub eax, [rbx + TF_top]
    imul eax, [rsp + 32]
    add eax, [rsp + 40]
    mov esi, eax
    mov edi, [rsp + 36]
    add edi, [rsp + 52]
    M edx, MI_2
    mov ecx, [rsp + 32]
    COLOR r8d, T_CURSOR
    call gfx_fill
9:  call gfx_clip_pop
    mov eax, [rsp + 20]
    EPILOGUE

.section .rodata
.p2align 2
f_100: .float 100.0
f_min_scale: .float 0.5
f_big: .float 1.55
f_huge: .float 3.4
# logical sizes for MI_* indices
metric_values:
    .long 1, 2, 3, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40, 48
    .long 40, 36, 26, 28, 16, 6, 64, 5
.globl empty_str
empty_str: .byte 0
ta_nl: .ascii "\n"
.bss
grab_dy: .long 0
grab_dx: .long 0
.p2align 3
ta_buf: .zero SB_SIZE
ta_rows: .zero VEC_SIZE
.data
g_mx: .long -10000
g_my: .long -10000
