# The agents panel's own text size ([agents] font_size): its faces, and its boxes in proportion.
# 0 follows the interface (the panel draws with the interface's faces and metrics); 1 to 7 act as 8,
# at most 32. Inside the panel every box comes from g_pmt (the PM macro) instead of g_mt: the
# interface's metrics times the panel's size / the interface's, so everything grows together.
#
#   agents_metrics()            at the top of the panel's drawing: faces and g_pmt for this frame
#   agents_font_size() -> eax   the size in effect, points (the interface's when it follows)
#   agents_font_step(v, dir) -> eax   the setting after a step: dir 1 up, -1 down, 0 reset
#   agents_font_zoom(dir)       a step of the setting, applied (the zoom keys, the commands)
.include "rhun.inc"

.data
.p2align 3
.globl ag_fui, ag_fsmall
ag_fui: .quad g_face_ui         # the panel's text face
ag_fsmall: .quad g_face_small   # and its small one

.bss
.p2align 3
.globl g_pmt
g_pmt: .zero 4 * MI_COUNT       # the panel's metrics (PM)
ag_face: .zero FACE_SIZE
ag_face_s: .zero FACE_SIZE
last_px: .long 0                # what ag_face was made for: px, small px, the interface's faces
last_spx: .long 0
last_gen: .long 0

.text

# agents_font_size() -> eax the size of the panel's text in points: the interface's when the setting
#   is 0, else the setting with 1 to 7 as 8 and at most 32
FN agents_font_size
    mov eax, [rip + cfg_agents_font_size]
    test eax, eax
    jle 1f
    mov ecx, 8
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 32
    cmp eax, ecx
    cmovg eax, ecx
    ret
1:  mov eax, [rip + cfg_ui_font_size]
    ret

# agents_metrics(): the panel's faces (made again when its size, the scale or the interface's faces
#   changed) and g_pmt, the interface's metrics scaled by the panel's size / the interface's
FN agents_metrics
    PROLOGUE
    call agents_font_size
    mov r12d, eax               # points
    mov r13d, [rip + cfg_ui_font_size]
    test r13d, r13d
    jg 1f
    mov r13d, 1
1:  cmp r12d, r13d
    jne 2f
    # the interface's size: its own faces and metrics
    lea rax, [rip + g_face_ui]
    mov [rip + ag_fui], rax
    lea rax, [rip + g_face_small]
    mov [rip + ag_fsmall], rax
    xor ecx, ecx
11: cmp ecx, MI_COUNT
    jae 9f
    lea rdx, [rip + g_mt]
    mov eax, [rdx + rcx*4]
    lea rdx, [rip + g_pmt]
    mov [rdx + rcx*4], eax
    inc ecx
    jmp 11b
2:  cmp qword ptr [rip + g_font_ui], 0
    je 9f                       # no fonts yet
    cvtsi2ss xmm0, r12d
    mulss xmm0, [rip + g_s]
    cvtss2si ebx, xmm0          # px
    cmp ebx, 4
    jge 3f
    mov ebx, 4
3:  cvtsi2ss xmm0, r12d         # small: 1.5 points less, as the interface's
    subss xmm0, [rip + f_1p5]
    mulss xmm0, [rip + g_s]
    cvtss2si r14d, xmm0
    cmp r14d, 4
    jge 4f
    mov r14d, 4
4:  cmp ebx, [rip + last_px]
    jne 5f
    cmp r14d, [rip + last_spx]
    jne 5f
    mov eax, [rip + g_ui_faces_gen]
    cmp eax, [rip + last_gen]
    je 6f
5:  mov [rip + last_px], ebx
    mov [rip + last_spx], r14d
    mov eax, [rip + g_ui_faces_gen]
    mov [rip + last_gen], eax
    lea rdi, [rip + ag_face]
    mov rsi, [rip + g_font_ui]
    mov edx, ebx
    call face_init
    lea rdi, [rip + ag_face_s]
    mov rsi, [rip + g_font_ui]
    mov edx, r14d
    call face_init
    mov eax, [rip + g_face_ui + FACE_embolden]
    mov [rip + ag_face + FACE_embolden], eax
    mov [rip + ag_face_s + FACE_embolden], eax
    mov dword ptr [rip + g_dirty], 1
6:  lea rax, [rip + ag_face]
    mov [rip + ag_fui], rax
    lea rax, [rip + ag_face_s]
    mov [rip + ag_fsmall], rax
    # every box in proportion: round(g_mt * size / the interface's size), at least 1
    xor r15d, r15d
7:  cmp r15d, MI_COUNT
    jae 9f
    lea rdx, [rip + g_mt]
    mov eax, [rdx + r15*4]
    imul eax, r12d
    mov ecx, r13d
    shr ecx, 1
    add eax, ecx
    xor edx, edx
    div r13d
    cmp eax, 1
    jge 8f
    mov eax, 1
8:  lea rdx, [rip + g_pmt]
    mov [rdx + r15*4], eax
    inc r15d
    jmp 7b
9:  EPILOGUE

# ag_icon_btn(id, x, y, w, h, icon) -> UB bits: ui_icon_btn with its icon in proportion to the panel's
#   text (the interface's icon size times the panel's size / the interface's)
FN ag_icon_btn
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
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    test dword ptr [rsp + 4], UB_HELD
    jz 11f
    COLOR r9d, T_ACTIVE
11: call gfx_round_rect
1:  PM eax, MI_ICON             # the icon, in the middle
    cmp eax, r14d
    cmovg eax, r14d
    cmp eax, r15d
    cmovg eax, r15d
    test eax, eax
    jle 3f
    mov ecx, r14d
    sub ecx, eax
    sar ecx, 1
    lea esi, [r12 + rcx]
    mov ecx, r15d
    sub ecx, eax
    sar ecx, 1
    lea edx, [r13 + rcx]
    mov edi, ebx
    mov ecx, eax
    COLOR r8d, T_MUTED
    test dword ptr [rsp + 4], UB_HOVER
    jz 2f
    COLOR r8d, T_FG
2:  call icon_draw
3:  mov eax, [rsp + 4]
    EPILOGUE

# agents_font_step(value, dir) -> eax the setting after one step: dir 0 resets it to 0 (the
#   interface's size); 1 from 0 goes to 8 or to the interface's size + 1 when that is larger, else
#   one more up to 32; -1 from 8 goes back to 0, from 0 to the interface's size - 1 (0 when that is
#   below 8), else one less
FN agents_font_step
    xor eax, eax
    test esi, esi
    jz 9f
    mov eax, edi
    test eax, eax
    jle 5f
    mov ecx, 8                  # 1 to 7 act as 8
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 32
    cmp eax, ecx
    cmovg eax, ecx
    test esi, esi
    js 2f
    inc eax
    cmp eax, ecx
    cmovg eax, ecx
    ret
2:  cmp eax, 8
    jle 3f
    dec eax
    ret
3:  xor eax, eax
    ret
5:  mov eax, [rip + cfg_ui_font_size]   # following the interface
    test esi, esi
    js 6f
    inc eax
    mov ecx, 8
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, 32
    cmp eax, ecx
    cmovg eax, ecx
    ret
6:  dec eax
    cmp eax, 8
    jge 7f
    xor eax, eax
7:  mov ecx, 32
    cmp eax, ecx
    cmovg eax, ecx
9:  ret

# agents_font_zoom(dir): the panel's size one step up (1), down (-1) or back to the interface's (0)
FN agents_font_zoom
    mov esi, edi
    mov edi, [rip + cfg_agents_font_size]
    call agents_font_step
    mov [rip + cfg_agents_font_size], eax
    mov dword ptr [rip + g_settings_changed], 1
    mov dword ptr [rip + g_dirty], 1
    ret

FN cmd_agents_font_inc
    mov edi, 1
    jmp agents_font_zoom

FN cmd_agents_font_dec
    mov edi, -1
    jmp agents_font_zoom

FN cmd_agents_font_reset
    xor edi, edi
    jmp agents_font_zoom

# agents_metrics_dump(sb): "size=N px=P small=S line=L row=R" (the setting, the text's pixels, the
#   small text's, a line of a reply, a session row)
FN agents_metrics_dump
    PROLOGUE
    mov rbx, rdi
    call agents_metrics
    mov rdi, rbx
    lea rsi, [rip + .Lm_size]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + cfg_agents_font_size]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lm_pt]
    call sb_push_cstr
    call agents_font_size
    mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lm_px]
    call sb_push_cstr
    mov rax, [rip + ag_fui]
    mov rdi, rbx
    mov esi, [rax + FACE_px]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lm_small]
    call sb_push_cstr
    mov rax, [rip + ag_fsmall]
    mov rdi, rbx
    mov esi, [rax + FACE_px]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lm_line]
    call sb_push_cstr
    mov rax, [rip + ag_fui]
    mov esi, [rax + FACE_lineh]
    add esi, [rip + g_pmt + 4*MI_3]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lm_row]
    call sb_push_cstr
    mov esi, [rip + g_pmt + 4*MI_48]
    add esi, [rip + g_pmt + 4*MI_8]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.p2align 2
f_1p5: .float 1.5
.Lm_size: .asciz "size="
.Lm_pt: .asciz " points="
.Lm_px: .asciz " px="
.Lm_small: .asciz " small="
.Lm_line: .asciz " line="
.Lm_row: .asciz " row="
