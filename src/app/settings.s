# settings page (opened as a tab), generated from g_settings
.include "rhun.inc"

.equ ID_SET_ROW, 0x5000         # + index*4 + part
.equ ID_SET_OPENFILE, 0x4f00
.equ ID_SET_SCROLL, 0x4f01

.bss
.p2align 3
set_scroll: .long 0
set_content_h: .long 0
.p2align 3
set_tf: .zero TF_SIZE
buf: .zero 64

.text

FN settings_field
    cmp dword ptr [rip + set_edit], 0
    jl 1f
    lea rax, [rip + set_tf]
    ret
1:  xor eax, eax
    ret

# commit the edited string setting
commit_edit:
    PROLOGUE
    mov eax, [rip + set_edit]
    test eax, eax
    js 9f
    mov dword ptr [rip + set_edit], -1
    imul rbx, rax, SET_SIZE
    lea rcx, [rip + g_settings]
    add rbx, rcx
    lea rdi, [rip + set_tf]
    call tf_text
    mov rdi, rbx
    mov rsi, rax
    call setting_assign
    mov rdi, rbx
    call setting_applied
9:  EPILOGUE

# setting_applied(SET*): side effects of a changed value
FN setting_applied
    PROLOGUE
    mov rbx, rdi
    call ai_apply
    call watch_apply_settings
    mov dword ptr [rip + g_settings_changed], 1
    mov dword ptr [rip + g_dirty], 1
    mov rax, [rbx + SET_ptr]
    lea rcx, [rip + cfg_font]
    cmp rax, rcx
    je 1f
    lea rcx, [rip + cfg_ui_font]
    cmp rax, rcx
    jne 2f
1:  call app_load_fonts
    call ui_force_metrics
    jmp 9f
2:  lea rcx, [rip + cfg_exclude]
    cmp rax, rcx
    jne 3f
    call explorer_refresh
    jmp 9f
3:  lea rcx, [rip + cfg_agent_sources]
    cmp rax, rcx
    jne 4f
    call agents_set_project
    jmp 9f
4:  lea rcx, [rip + cfg_git]
    cmp rax, rcx
    jne 5f
    call git_apply
    jmp 9f
5:  lea rcx, [rip + cfg_update_check]
    cmp rax, rcx
    jne 6f
    call update_apply
    jmp 9f
6:  lea rcx, [rip + cfg_follow_system]
    cmp rax, rcx
    jne 7f
    call theme_follow_toggled
    jmp 9f
    # a panel's setting changed here holds in this window too, even where a file launch hid it
7:  mov edi, 1
    lea rcx, [rip + cfg_sidebar]
    cmp rax, rcx
    je 71f
    mov edi, 2
    lea rcx, [rip + cfg_agents]
    cmp rax, rcx
    jne 72f
71: call app_reveal_panel
    jmp 9f
72: call vim_sync
9:  EPILOGUE

# setting_shown(SET*) -> 1 if its row is on the page: Theme without Follow system dark mode, the dark
# and light mode's themes with it
setting_shown:
    mov rax, [rdi + SET_ptr]
    mov ecx, [rip + cfg_follow_system]
    lea rdx, [rip + cfg_theme]
    cmp rax, rdx
    je 1f
    xor ecx, 1
    lea rdx, [rip + cfg_dark_theme]
    cmp rax, rdx
    je 1f
    lea rdx, [rip + cfg_light_theme]
    cmp rax, rdx
    je 1f
    mov eax, 1
    ret
1:  xor eax, eax
    test ecx, ecx
    sete al
    ret

# settings_key(keysym, cp, mods) -> 1 if handled
FN settings_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    cmp dword ptr [rip + set_edit], 0
    jl 5f
    cmp r12d, KEY_RETURN
    jne 1f
    call commit_edit
    jmp .Lsk_yes
1:  cmp r12d, KEY_ESCAPE
    jne 2f
    mov dword ptr [rip + set_edit], -1
    jmp .Lsk_yes
2:  lea rdi, [rip + set_tf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
    test eax, eax
    jnz .Lsk_yes
    xor eax, eax
    EPILOGUE
5:  # page navigation
    cmp r12d, KEY_DOWN
    jne 6f
    mov edi, 60
    call sc
    add [rip + set_scroll], eax
    jmp .Lsk_yes
6:  cmp r12d, KEY_UP
    jne 7f
    mov edi, 60
    call sc
    sub [rip + set_scroll], eax
    jmp .Lsk_yes
7:  cmp r12d, KEY_ESCAPE
    jne 8f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    jmp .Lsk_yes
8:  xor eax, eax
    EPILOGUE
.Lsk_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE

# section_title(sec cstr) -> display name
section_title:
    lea rax, [rip + .Lt_updates]
    cmp word ptr [rdi], 0x7075          # "up"
    je 1f
    lea rax, [rip + .Lt_appearance]
    cmp byte ptr [rdi], 'u'
    je 1f
    lea rax, [rip + .Lt_editor]
    cmp byte ptr [rdi], 'e'
    je 1f
    lea rax, [rip + .Lt_files]
    cmp byte ptr [rdi], 'f'
    je 1f
    lea rax, [rip + .Lt_terminal]
    cmp byte ptr [rdi], 't'
    je 1f
    lea rax, [rip + .Lt_git]
    cmp byte ptr [rdi], 'g'
    je 1f
    lea rax, [rip + .Lt_agents]
1:  ret

# format a value for steppers
fmt_value:
    # rdi SET* -> buf
    push rbx
    mov rbx, rdi
    mov rax, [rbx + SET_ptr]
    mov eax, [rax]
    cmp dword ptr [rbx + SET_decimal], 0
    jne 1f
    lea rdi, [rip + buf]
    mov esi, eax
    call fmt_u64
    lea rdi, [rip + buf]
    mov byte ptr [rdi + rax], 0
    pop rbx
    ret
1:  xor edx, edx
    mov ecx, 100
    div ecx
    push rdx
    lea rdi, [rip + buf]
    mov esi, eax
    call fmt_u64
    lea rdi, [rip + buf]
    add rdi, rax
    mov byte ptr [rdi], '.'
    inc rdi
    pop rax
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [rdi], al
    inc rdi
    test edx, edx
    jz 2f
    add dl, '0'
    mov [rdi], dl
    inc rdi
2:  mov byte ptr [rdi], 0
    pop rbx
    ret

# settings_draw(x, y, w, h)
FN settings_draw
    PROLOGUE 112
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
    # wheel
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call ui_in
    test eax, eax
    jz 1f
    mov eax, [rip + g_scroll_y]
    add [rip + set_scroll], eax
1:  mov eax, [rip + set_content_h]
    sub eax, [rsp + 12]
    jns 11f
    xor eax, eax
11: cmp [rip + set_scroll], eax
    jle 12f
    mov [rip + set_scroll], eax
12: cmp dword ptr [rip + set_scroll], 0
    jge 13f
    mov dword ptr [rip + set_scroll], 0
13: call update_desc_refresh
    # column
    mov edi, 720
    call sc
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_64]
    cmp eax, ecx
    cmovg eax, ecx
    mov dword ptr [rsp + 96], 0 # stacked narrow layout
    mov edi, 640
    push rax
    push rax
    call sc
    pop rcx
    pop rcx
    cmp ecx, eax
    jge 14f
    mov dword ptr [rsp + 96], 1
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_16]
14: mov eax, 1
    cmp ecx, eax
    cmovl ecx, eax
    mov [rsp + 16], ecx         # column w
    mov eax, ecx
    mov ecx, [rsp + 8]
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp]
    mov [rsp + 20], ecx         # column x
    mov eax, [rsp + 4]
    add eax, [rip + g_mt + 4*MI_32]
    sub eax, [rip + set_scroll]
    mov r12d, eax               # y cursor
    mov [rsp + 24], eax         # y at top (for content height)
    # title
    lea rdi, [rip + g_face_big]
    mov esi, [rsp + 20]
    mov edx, r12d
    M ecx, MI_40
    lea r8, [rip + .Ltitle]
    COLOR r9d, T_FG
    call ui_text_c
    add r12d, [rip + g_mt + 4*MI_40]
    # config file line (cut before the button) + button
    call config_path
    mov [rsp + 40], rax
    mov rdi, rax
    call strlen
    mov r9, rax
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 20]
    mov edx, r12d
    M ecx, MI_28
    mov r8, [rsp + 40]
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 16]
    sub r11d, [rip + g_mt + 4*MI_64]
    sub r11d, [rip + g_mt + 4*MI_64]
    sub r11d, [rip + g_mt + 4*MI_32]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    lea rdi, [rip + .Lopen_file]
    call strlen
    lea rdi, [rip + g_face_small]
    lea rsi, [rip + .Lopen_file]
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_24]
    mov r13d, eax
    mov esi, [rsp + 20]
    add esi, [rsp + 16]
    sub esi, r13d
    mov [rsp + 28], esi
    mov edi, ID_SET_OPENFILE
    mov edx, r12d
    mov ecx, r13d
    M r8d, MI_28
    call ui_btn
    mov [rsp + 32], eax
    mov edi, [rsp + 28]
    mov esi, r12d
    mov edx, r13d
    M ecx, MI_28
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    COLOR eax, T_BG
    test dword ptr [rsp + 32], UB_HOVER
    jz 2f
    COLOR eax, T_HOVER
2:  push rax
    push rax
    call gfx_frame
    add rsp, 16
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 28]
    mov edx, r12d
    mov ecx, r13d
    M r8d, MI_28
    lea r9, [rip + .Lopen_file]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    test dword ptr [rsp + 32], UB_CLICK
    jz 3f
    call cmd_open_config
    jmp .Lsd_end
3:  add r12d, [rip + g_mt + 4*MI_40]
    mov edi, 0x4f02
    mov esi, [rsp + 20]
    mov edx, r12d
    mov ecx, [rsp + 16]
    lea r8, [rip + .Lwebsite]
    call settings_link
    mov [rsp + 28], edx
    test eax, UB_CLICK
    jz 31f
    call cmd_website
31: mov edi, [rsp + 28]
    mov esi, r12d
    call link_dot
    mov [rsp + 28], eax
    mov edi, 0x4f04
    mov esi, [rsp + 28]
    mov edx, r12d
    mov ecx, [rsp + 16]
    add ecx, [rsp + 20]
    sub ecx, esi
    lea r8, [rip + .Lemail]
    call settings_link
    mov [rsp + 28], edx
    test eax, UB_CLICK
    jz 311f
    call cmd_email
311: mov edi, [rsp + 28]
    mov esi, r12d
    call link_dot
    mov [rsp + 28], eax
    mov edi, 0x4f03
    mov esi, [rsp + 28]
    mov edx, r12d
    mov ecx, [rsp + 16]
    add ecx, [rsp + 20]
    sub ecx, esi
    lea r8, [rip + .Lfeedback]
    call settings_link
    mov [rsp + 28], edx
    test eax, UB_CLICK
    jz 312f
    call cmd_feedback
312: mov edi, [rsp + 28]
    mov esi, r12d
    call link_dot
    mov [rsp + 28], eax
    mov edi, 0x4f05
    mov esi, [rsp + 28]
    mov edx, r12d
    mov ecx, [rsp + 16]
    add ecx, [rsp + 20]
    sub ecx, esi
    lea r8, [rip + .Ldiscord]
    call settings_link
    test eax, UB_CLICK
    jz 32f
    call cmd_discord
32: add r12d, [rip + g_mt + 4*MI_40]
    # rows
    lea rbx, [rip + g_settings]
    xor r15d, r15d              # index
    xor r14d, r14d              # previous section ptr
.Lsd_row:
    cmp qword ptr [rbx + SET_key], 0
    je .Lsd_rows_done
    mov rdi, rbx
    call setting_shown
    test eax, eax
    jz .Lsd_skip
    mov rax, [rbx + SET_sec]
    cmp rax, r14
    je 4f
    mov r14, rax
    # section header
    add r12d, [rip + g_mt + 4*MI_16]
    mov rdi, r14
    call section_title
    mov r8, rax
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 20]
    mov edx, r12d
    M ecx, MI_28
    COLOR r9d, T_ACCENT
    call ui_text_c
    add r12d, [rip + g_mt + 4*MI_32]
4:  # row card
    M r13d, MI_64
    cmp dword ptr [rsp + 96], 0
    je 43f
    add r13d, [rip + g_mt + 4*MI_48]
    cmp dword ptr [rbx + SET_type], ST_CHOICE
    jne 43f
    mov dword ptr [rsp + 72], 0
41: mov rdi, [rbx + SET_opts]
    mov esi, [rsp + 72]
    call choice_entry
    test rax, rax
    jz 42f
    inc dword ptr [rsp + 72]
    jmp 41b
42: mov r13d, [rsp + 72]
    imul r13d, [rip + g_mt + 4*MI_32]
    add r13d, [rip + g_mt + 4*MI_64]
    add r13d, [rip + g_mt + 4*MI_16]
43:
    mov edi, [rsp + 20]
    mov esi, r12d
    mov edx, [rsp + 16]
    mov ecx, r13d
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    COLOR eax, T_PANEL
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    # label + description
    mov edi, [rsp + 20]
    mov esi, r12d
    mov edx, [rsp + 16]
    M ecx, MI_64
    call gfx_clip_push
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 20]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, r12d
    add edx, [rip + g_mt + 4*MI_10]
    M ecx, MI_24
    mov r8, [rbx + SET_label]
    COLOR r9d, T_FG
    call ui_text_c
    # the description stops short of the control
    mov rdi, rbx
    call desc_room
    mov r11d, [rsp + 16]
    sub r11d, eax
    sub r11d, [rip + g_mt + 4*MI_16]
    cmp dword ptr [rsp + 96], 0
    je 44f
    mov r11d, [rsp + 16]
    sub r11d, [rip + g_mt + 4*MI_32]
44: mov [rsp + 36], r11d
    mov rdi, [rbx + SET_desc]
    call strlen
    mov r9, rax
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 20]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, r12d
    add edx, [rip + g_mt + 4*MI_32]
    M ecx, MI_20
    mov r8, [rbx + SET_desc]
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 36]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    call gfx_clip_pop
    cmp dword ptr [rsp + 96], 0
    je 45f
    add r12d, [rip + g_mt + 4*MI_64]
    sub r13d, [rip + g_mt + 4*MI_64]
45: # control on the right
    mov edi, [rsp + 20]
    mov esi, r12d
    mov edx, [rsp + 16]
    mov ecx, r13d
    call gfx_clip_push
    mov eax, [rsp + 20]
    add eax, [rsp + 16]
    sub eax, [rip + g_mt + 4*MI_16]
    mov [rsp + 36], eax         # right edge
    lea eax, [r15*4 + ID_SET_ROW]
    mov [rsp + 40], eax         # id base
    mov eax, [rbx + SET_type]
    cmp eax, ST_BOOL
    je .Lsd_bool
    cmp eax, ST_INT
    je .Lsd_int
    cmp eax, ST_THEME
    je .Lsd_theme
    cmp eax, ST_CHOICE
    je .Lsd_choice
    cmp eax, ST_ACTION
    je .Lsd_action
    jmp .Lsd_str
.Lsd_action:
    # a button, right aligned
    mov rdi, rbx
    call action_label
    mov [rsp + 64], rax
    mov rdi, rax
    call strlen
    lea rdi, [rip + g_face_ui]
    mov rsi, [rsp + 64]
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_32]
    call .Lsd_control_width
    mov [rsp + 44], eax         # w
    mov esi, [rsp + 36]
    sub esi, eax
    mov [rsp + 52], esi         # x
    M eax, MI_32
    mov edx, r13d
    sub edx, eax
    sar edx, 1
    add edx, r12d
    mov [rsp + 60], edx         # y
    mov edi, [rsp + 40]
    mov ecx, [rsp + 44]
    mov r8d, eax
    call ui_btn
    mov [rsp + 32], eax
    mov edi, [rsp + 52]
    mov esi, [rsp + 60]
    mov edx, [rsp + 44]
    M ecx, MI_32
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    COLOR eax, T_INPUT
    test dword ptr [rsp + 32], UB_HOVER
    jz 1f
    COLOR eax, T_HOVER
1:  push rax
    push rax
    call gfx_frame
    add rsp, 16
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 52]
    mov edx, [rsp + 60]
    mov ecx, [rsp + 44]
    M r8d, MI_32
    mov r9, [rsp + 64]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    test dword ptr [rsp + 32], UB_CLICK
    jz .Lsd_next
    call [rbx + SET_ptr]
    jmp .Lsd_next
.Lsd_choice:
    # segmented control, right aligned
    M eax, MI_32
    mov edx, r13d
    sub edx, eax
    sar edx, 1
    add edx, r12d
    cmp dword ptr [rsp + 96], 0
    je 11f
    mov edx, r12d
    add edx, [rip + g_mt + 4*MI_8]
11: mov [rsp + 60], edx         # y
    mov dword ptr [rsp + 44], 0 # total width
    mov dword ptr [rsp + 72], 0
1:  mov rdi, [rbx + SET_opts]
    mov esi, [rsp + 72]
    call choice_entry
    test rax, rax
    jz 2f
    call .Lseg_w
    add [rsp + 44], eax
    inc dword ptr [rsp + 72]
    jmp 1b
2:  cmp dword ptr [rsp + 96], 0
    je 21f
    mov eax, [rsp + 16]
    sub eax, [rip + g_mt + 4*MI_32]
    mov [rsp + 44], eax
21: mov eax, [rsp + 36]
    sub eax, [rsp + 44]
    mov [rsp + 52], eax         # x
    mov edi, eax
    mov esi, [rsp + 60]
    mov edx, [rsp + 44]
    M ecx, MI_32
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    COLOR eax, T_INPUT
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    mov eax, [rsp + 52]
    mov [rsp + 76], eax         # segment x
    mov dword ptr [rsp + 72], 0
3:  mov rdi, [rbx + SET_opts]
    mov esi, [rsp + 72]
    call choice_entry
    test rax, rax
    jz .Lsd_next
    mov [rsp + 80], rdx         # label
    call .Lseg_w
    cmp dword ptr [rsp + 96], 0
    je 31f
    mov eax, [rsp + 44]
31: mov [rsp + 88], eax         # w
    mov edi, [rsp + 40]
    add edi, [rsp + 72]
    mov esi, [rsp + 76]
    mov edx, [rsp + 60]
    mov ecx, eax
    M r8d, MI_32
    call ui_btn
    mov [rsp + 32], eax
    mov rax, [rbx + SET_ptr]
    mov eax, [rax]
    cmp eax, [rsp + 72]
    jne 4f
    COLOR r9d, T_ACTIVE
    jmp 5f
4:  test dword ptr [rsp + 32], UB_HOVER
    jz 6f
    COLOR r9d, T_HOVER
5:  mov edi, [rsp + 76]
    add edi, [rip + g_mt + 4*MI_2]
    mov esi, [rsp + 60]
    add esi, [rip + g_mt + 4*MI_2]
    mov edx, [rsp + 88]
    sub edx, [rip + g_mt + 4*MI_4]
    M ecx, MI_32
    sub ecx, [rip + g_mt + 4*MI_4]
    M r8d, MI_RADIUS
    call gfx_round_rect
6:  COLOR eax, T_MUTED
    mov rcx, [rbx + SET_ptr]
    mov ecx, [rcx]
    cmp ecx, [rsp + 72]
    jne 7f
    COLOR eax, T_FG
7:  lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 76]
    mov edx, [rsp + 60]
    mov ecx, [rsp + 88]
    M r8d, MI_32
    mov r9, [rsp + 80]
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    test dword ptr [rsp + 32], UB_CLICK
    jz 8f
    mov rax, [rbx + SET_ptr]
    mov ecx, [rsp + 72]
    mov [rax], ecx
    mov rdi, rbx
    call setting_applied
8:  cmp dword ptr [rsp + 96], 0
    je 81f
    M eax, MI_32
    add [rsp + 60], eax
    jmp 82f
81: mov eax, [rsp + 88]
    add [rsp + 76], eax
82: inc dword ptr [rsp + 72]
    jmp 3b
# .Lseg_w(rdx label) -> eax segment width
.Lseg_w:
    push rbx
    mov rbx, rdx
    mov rdi, rdx
    call strlen
    lea rdi, [rip + g_face_ui]
    mov rsi, rbx
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_24]
    pop rbx
    ret
.Lsd_bool:
    M eax, MI_14
    add eax, [rip + g_mt + 4*MI_20]
    mov esi, [rsp + 36]
    sub esi, eax
    mov edx, r13d
    sub edx, [rip + g_mt + 4*MI_20]
    sar edx, 1
    add edx, r12d
    mov edi, [rsp + 40]
    mov rax, [rbx + SET_ptr]
    mov ecx, [rax]
    call ui_toggle
    test eax, eax
    jz .Lsd_next
    mov rax, [rbx + SET_ptr]
    xor dword ptr [rax], 1
    mov rdi, rbx
    call setting_applied
    jmp .Lsd_next
.Lsd_int:
    # [-] value [+]
    M eax, MI_28
    mov [rsp + 44], eax
    mov esi, [rsp + 36]
    sub esi, eax
    mov [rsp + 48], esi         # plus x
    sub esi, [rip + g_mt + 4*MI_64]
    mov [rsp + 52], esi         # value x (64 wide)
    sub esi, eax
    mov [rsp + 56], esi         # minus x
    mov edx, r13d
    sub edx, eax
    sar edx, 1
    add edx, r12d
    mov [rsp + 60], edx         # y
    # value box
    mov edi, [rsp + 52]
    mov esi, edx
    M edx, MI_64
    mov ecx, [rsp + 44]
    M r8d, MI_4
    COLOR r9d, T_INPUT
    call gfx_round_rect
    mov rdi, rbx
    call fmt_value
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 52]
    mov edx, [rsp + 60]
    M ecx, MI_64
    mov r8d, [rsp + 44]
    lea r9, [rip + buf]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    # minus
    mov edi, [rsp + 40]
    mov esi, [rsp + 56]
    mov edx, [rsp + 60]
    mov ecx, [rsp + 44]
    mov r8d, ecx
    mov r9d, IC_MIN
    call ui_icon_btn
    test eax, UB_PRESS
    jz 5f
    mov rax, [rbx + SET_ptr]
    mov ecx, [rax]
    sub ecx, [rbx + SET_step]
    cmp ecx, [rbx + SET_min]
    jge 41f
    mov ecx, [rbx + SET_min]
41: mov [rax], ecx
    mov rdi, rbx
    call setting_applied
5:  mov edi, [rsp + 40]
    inc edi
    mov esi, [rsp + 48]
    mov edx, [rsp + 60]
    mov ecx, [rsp + 44]
    mov r8d, ecx
    mov r9d, IC_PLUS
    call ui_icon_btn
    test eax, UB_PRESS
    jz .Lsd_next
    mov rax, [rbx + SET_ptr]
    mov ecx, [rax]
    add ecx, [rbx + SET_step]
    cmp ecx, [rbx + SET_max]
    jle 51f
    mov ecx, [rbx + SET_max]
51: mov [rax], ecx
    mov rdi, rbx
    call setting_applied
    jmp .Lsd_next
.Lsd_theme:
    # button showing the setting's theme, opens the theme list for it
    mov rdi, [rbx + SET_ptr]
    call theme_slot_index
    mov rdi, rax
    call theme_entry
    mov r8, [rax + TH_name]
    mov [rsp + 64], r8
    mov rdi, r8
    call strlen
    lea rdi, [rip + g_face_ui]
    mov rsi, [rsp + 64]
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_48]
    call .Lsd_control_width
    mov [rsp + 44], eax         # w
    mov esi, [rsp + 36]
    sub esi, eax
    mov [rsp + 52], esi
    M eax, MI_32
    mov edx, r13d
    sub edx, eax
    sar edx, 1
    add edx, r12d
    mov [rsp + 60], edx
    mov edi, [rsp + 40]
    mov ecx, [rsp + 44]
    mov r8d, eax
    call ui_btn
    mov [rsp + 32], eax
    mov edi, [rsp + 52]
    mov esi, [rsp + 60]
    mov edx, [rsp + 44]
    M ecx, MI_32
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    COLOR eax, T_INPUT
    test dword ptr [rsp + 32], UB_HOVER
    jz 6f
    COLOR eax, T_HOVER
6:  push rax
    push rax
    call gfx_frame
    add rsp, 16
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp + 52]
    add esi, [rip + g_mt + 4*MI_12]
    mov edx, [rsp + 60]
    M ecx, MI_32
    mov r8, [rsp + 64]
    COLOR r9d, T_FG
    call ui_text_c
    mov edi, IC_CHEV_DN2
    mov esi, [rsp + 52]
    add esi, [rsp + 44]
    sub esi, [rip + g_mt + 4*MI_32]
    mov edx, [rsp + 60]
    M ecx, MI_32
    mov r8d, ecx
    COLOR r9d, T_MUTED
    call ui_icon_center
    test dword ptr [rsp + 32], UB_CLICK
    jz .Lsd_next
    mov rdi, [rbx + SET_ptr]
    call cmd_select_theme_for
    jmp .Lsd_next
.Lsd_str:
    mov edi, 300
    call sc
    call .Lsd_control_width
    mov [rsp + 44], eax
    mov esi, [rsp + 36]
    sub esi, eax
    mov [rsp + 52], esi
    M eax, MI_32
    mov edx, r13d
    sub edx, eax
    sar edx, 1
    add edx, r12d
    mov [rsp + 60], edx
    cmp r15d, [rip + set_edit]
    je 7f
    # show the current value in a field-looking box; click to edit
    mov edi, [rsp + 40]
    mov ecx, [rsp + 44]
    mov r8d, eax
    call ui_btn
    mov [rsp + 32], eax
    mov edi, [rsp + 52]
    mov esi, [rsp + 60]
    mov edx, [rsp + 44]
    M ecx, MI_32
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    test dword ptr [rsp + 32], UB_HOVER
    jz 61f
    COLOR r9d, T_MUTED
61: COLOR eax, T_INPUT
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    mov rax, [rbx + SET_ptr]
    mov r8, [rax]
    mov [rsp + 64], r8
    mov rdi, r8
    call strlen
    mov r9, rax
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 52]
    add esi, [rip + g_mt + 4*MI_10]
    mov edx, [rsp + 60]
    M ecx, MI_32
    mov r8, [rsp + 64]
    COLOR eax, T_FG
    test r9, r9
    jnz 62f
    lea r8, [rip + .Lbuiltin]
    mov r9d, 8
    COLOR eax, T_MUTED
62: mov r11d, [rsp + 44]
    sub r11d, [rip + g_mt + 4*MI_20]
    push r11
    push rax
    call ui_text_v_fit
    add rsp, 16
    test dword ptr [rsp + 32], UB_PRESS
    jz .Lsd_next
    call commit_edit
    mov [rip + set_edit], r15d
    mov dword ptr [rip + g_focus], FOCUS_SETTINGS
    mov eax, [rsp + 40]
    mov [rip + set_tf + TF_id], eax
    mov rax, [rbx + SET_ptr]
    mov rsi, [rax]
    mov rdi, rsi
    push rsi
    push rsi
    call strlen
    pop rsi
    pop rsi
    lea rdi, [rip + set_tf]
    mov rdx, rax
    call tf_set
    lea rdi, [rip + set_tf]
    call tf_select_all
    jmp .Lsd_next
7:  lea rdi, [rip + set_tf]
    mov esi, [rsp + 52]
    mov edx, [rsp + 60]
    mov ecx, [rsp + 44]
    M r8d, MI_32
    xor r9d, r9d                # focused while keys come to it
    cmp dword ptr [rip + g_focus], FOCUS_SETTINGS
    jne 71f
    mov r9d, 1
71: lea rax, [rip + .Lbuiltin]
    push rax
    push rax
    call ui_textfield
    add rsp, 16
.Lsd_next:
    call gfx_clip_pop
    add r12d, r13d
    add r12d, [rip + g_mt + 4*MI_8]
.Lsd_skip:
    add rbx, SET_SIZE
    inc r15d
    jmp .Lsd_row
.Lsd_rows_done:
    add r12d, [rip + g_mt + 4*MI_48]
    sub r12d, [rsp + 24]
    mov [rip + set_content_h], r12d
    # clicking elsewhere ends string editing
    test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz .Lsd_end
    cmp dword ptr [rip + set_edit], 0
    jl .Lsd_end
    mov eax, [rip + g_active]
    cmp eax, [rip + set_tf + TF_id]
    je .Lsd_end
    call commit_edit
.Lsd_end:
    call gfx_clip_pop
    # scrollbar on the view's right edge
    mov eax, [rip + set_content_h]
    mov ecx, [rsp + 12]
    push rcx
    push rax
    mov edi, ID_SET_SCROLL
    mov esi, [rsp + 16]
    add esi, [rsp + 16 + 8]
    M eax, MI_12
    sub esi, eax
    mov edx, [rsp + 16 + 4]
    mov ecx, eax
    mov r8d, [rsp + 16 + 12]
    lea r9, [rip + set_scroll]
    call ui_scrollbar
    add rsp, 16
    EPILOGUE

# eax requested control width -> bounded width inside the column.
.Lsd_control_width:
    mov ecx, [rsp + 8 + 16]
    sub ecx, [rip + g_mt + 4*MI_32]
    mov edx, 1
    cmp ecx, edx
    cmovl ecx, edx
    cmp eax, ecx
    cmovg eax, ecx
    ret

# link_dot(x, y) -> eax the next link's x: a muted dot between the header's links
link_dot:
    PROLOGUE
    mov edx, esi
    mov esi, edi
    add esi, [rip + g_mt + 4*MI_10]
    lea rdi, [rip + g_face_small]
    M ecx, MI_28
    lea r8, [rip + .Llink_dot]
    COLOR r9d, T_MUTED
    call ui_text_c
    add eax, [rip + g_mt + 4*MI_10]
    EPILOGUE

# settings_link(id, x, y, max_width, label) -> eax button flags, edx right edge
settings_link:
    PROLOGUE 32
    xor eax, eax
    test ecx, ecx
    cmovs ecx, eax
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov rbx, r8
    mov rdi, r8
    call strlen
    mov r12, rax
    lea rdi, [rip + g_face_small]
    mov rsi, rbx
    mov rdx, r12
    call text_width
    cmp eax, [rsp + 12]
    cmovg eax, [rsp + 12]
    mov ecx, eax
    add eax, [rsp + 4]
    mov [rsp + 16], eax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    M r8d, MI_28
    call ui_btn
    mov r13d, eax
    test eax, UB_HOVER
    jz 1f
    mov edi, CUR_POINTER
    call ui_set_cursor
1:
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    M ecx, MI_28
    mov r8, rbx
    mov r9, r12
    COLOR eax, T_ACCENT
    mov r10d, [rsp + 12]
    push r10
    push rax
    call ui_text_v_fit
    add rsp, 16
    mov eax, r13d
    mov edx, [rsp + 16]
    EPILOGUE

# action_label(setting): cached state only; no detection during drawing.
action_label:
    lea rax, [rip + .Lcheck_now]
    lea rcx, [rip + cmd_ai_model_files]
    cmp [rdi + SET_ptr], rcx
    jne 1f
    lea rax, [rip + .Lsetup_now]
    cmp dword ptr [rip + cfg_commit_ai], 3
    jne 1f
    lea rax, [rip + .Lcancel_ai]
    cmp dword ptr [rip + g_ai_kind], 2
    je 1f
    lea rax, [rip + .Ldeleting_model]
    cmp dword ptr [rip + g_ai_kind], 4
    je 1f
    lea rax, [rip + .Lchecking_model]
    cmp dword ptr [rip + g_ai_kind], 1
    je 1f
    lea rax, [rip + .Ldelete_model]
    cmp dword ptr [rip + g_ai_model_ready], 1
    je 1f
    lea rax, [rip + .Lsetup_now]
1:  ret

# desc_room(setting) -> eax: the width of its control with the gaps around it
desc_room:
    PROLOGUE
    mov rbx, rdi
    mov eax, [rbx + SET_type]
    cmp eax, ST_CHOICE
    je 2f
    cmp eax, ST_ACTION
    je 5f
    cmp eax, ST_BOOL
    je 1f
    cmp eax, ST_INT
    je 1f
    cmp eax, ST_THEME
    je 1f
    # a text field
    mov edi, 300
    call sc
    add eax, [rip + g_mt + 4*MI_32]
    EPILOGUE
1:  mov eax, [rip + g_mt + 4*MI_64]
    imul eax, eax, 3
    sub eax, [rip + g_mt + 4*MI_16]
    EPILOGUE
2:  xor r12d, r12d
    xor r13d, r13d
3:  mov rdi, [rbx + SET_opts]
    mov esi, r13d
    call choice_entry
    test rax, rax
    jz 4f
    call .Lseg_w
    add r12d, eax
    inc r13d
    jmp 3b
4:  mov eax, r12d
    add eax, [rip + g_mt + 4*MI_32]
    EPILOGUE
5:  mov rdi, rbx
    call action_label
    mov r12, rax
    mov rdi, rax
    call strlen
    lea rdi, [rip + g_face_ui]
    mov rsi, r12
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_64]
    EPILOGUE

# ui_text_v_fit(face, x, y, h, ptr, len, argb, maxw): text centered vertically, cut with "…"
FN ui_text_v_fit
    PROLOGUE 16
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
    mov eax, [rbp + 24]
    push rax
    push rax
    mov rdi, rbx
    mov esi, r12d
    call text_draw_fit
    add rsp, 16
    EPILOGUE

.section .rodata
.Ltitle: .asciz "Settings"
.Lopen_file: .asciz "Open settings file"
.Lbuiltin: .asciz "built-in"
.Lt_appearance: .asciz "Appearance"
.Lt_editor: .asciz "Editor"
.Lt_files: .asciz "Files"
.Lt_agents: .asciz "Agents"
.Lt_terminal: .asciz "Terminal"
.Lt_git: .asciz "Git"
.Lt_updates: .asciz "Updates"
.Lwebsite: .asciz "https://rhun.app"
.Lemail: .asciz "hi@rhun.app"
.Lfeedback: .asciz "Feedback and issues: GitHub"
.Ldiscord: .asciz "Discord"
.Llink_dot: .asciz "\302\267"
.Lcheck_now: .asciz "Check now"

.data
set_edit: .long -1

.Lsetup_now: .asciz "Download"
.Ldelete_model: .asciz "Delete"
.Ldeleting_model: .asciz "Deleting..."
.Lchecking_model: .asciz "Checking..."
.Lcancel_ai: .asciz "Cancel"
