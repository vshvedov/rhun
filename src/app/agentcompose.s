# The prompt box's behaviour (generic): its keys before the text area's, its owner changing, the argument
# hint drawn after a command's name.
#
#   composer_key(keysym, cp, mods) -> eax 1 taken   agentext_input_key asks it first: a key in a driven box
#                                       is a writer's action (the driver's record is read), and an open
#                                       popup takes its keys first (Escape closes it before anything else)
#   composer_owner(AS* new owner)       the box changes owner: the popup closes (the text is the caller's)
#   composer_hint(TF*, kind) -> rax cstr or 0   the argument hint for the box's text: it is "/NAME " and NAME
#                                       a command with one in the driver's record (nothing is read for it)
#   composer_hint_at(TF*, x, y, w) -> eax x, edx y  where it starts: the end of the caret's row as the text
#                                       area lays it out (ta_layout, ta_row_of, ta_row_bounds)
#   composer_hint_draw(TF*, kind, x, y, w, h)  the hint in T_MUTED over the text area, inside it
#   composer_hint_dump(sb)              "hint TEXT at X Y" for the hint drawn last, nothing without one
.include "rhun.inc"

.bss
.p2align 3
hint_text: .quad 0              # as drawn last: the hint (a copy in hint_buf, or 0) and where
hint_buf: .zero 128
hint_x: .long 0
hint_y: .long 0

.text

# FN composer_key(keysym, cp, mods) -> eax 1 when the key was taken before the text area's
FN composer_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call agentext_box_owner
    test edx, edx
    jz 1f
    mov edi, edx
    call agentcfg_get
    mov rdi, rax
    call agentcfg_need
1:  call agentpop_kind
    test eax, eax
    jz 8f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call agentpop_key
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN composer_owner(AS* new owner): the box is another's now: its popup closes
FN composer_owner
    jmp agentpop_close

# FN composer_hint(TF*, kind) -> rax the hint to draw after the box's text, or 0
FN composer_hint
    PROLOGUE
    mov r12d, esi
    xor ebx, ebx
    test r12d, r12d
    jz 9f
    call tf_text
    mov r13, rax
    mov r14, rdx
    cmp r14, 3                  # "/" NAME " ", NAME without blanks
    jb 9f
    cmp byte ptr [r13], '/'
    jne 9f
    cmp byte ptr [r13 + r14 - 1], ' '
    jne 9f
    mov ecx, 1
1:  lea rax, [r14 - 1]
    cmp rcx, rax
    jae 2f
    cmp byte ptr [r13 + rcx], ' '
    jbe 9f
    inc rcx
    jmp 1b
2:  mov edi, r12d
    call agentcfg_get
    mov rdi, rax
    lea rsi, [r13 + 1]
    lea rdx, [r14 - 2]
    call agentcfg_find_cmd
    test rax, rax
    jz 9f
    mov r15, rax
    lea rdi, [r13 + 1]          # its name, not an alias
    lea rsi, [r14 - 2]
    mov rdx, [r15 + ACM_name]
    call str_eq_cstr
    test eax, eax
    jz 9f
    mov rax, [r15 + ACM_hint]
    test rax, rax
    jz 9f
    cmp byte ptr [rax], 0
    je 9f
    mov rbx, rax
9:  mov rax, rbx
    EPILOGUE

# FN composer_hint_at(TF*, x, y, w) -> eax x, edx y: the end of the caret's row in a text area drawn at x, y,
#   w wide (ui_textarea's text starts MI_10 in, its first line MI_6 down)
FN composer_hint_at
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov rdi, rbx
    mov esi, ecx
    call ta_layout
    mov rdi, [rbx + TF_cur]
    call ta_row_of
    mov r14d, eax               # the caret's row
    mov edi, eax
    call ta_row_bounds
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rbx
    call tf_text
    mov rsi, rax
    add rsi, [rsp]
    mov rdx, [rsp + 8]
    sub rdx, [rsp]
    mov rdi, [rbx + TF_face]
    test rdi, rdi
    jnz 1f
    lea rdi, [rip + g_face_ui]
1:  call text_width
    lea r15d, [r12 + rax]
    add r15d, [rip + g_mt + 4*MI_10]
    sub r15d, [rbx + TF_scroll]
    mov rdi, rbx
    call ta_line_h_of
    mov ecx, r14d
    sub ecx, [rbx + TF_top]
    imul eax, ecx
    lea edx, [r13 + rax]
    add edx, [rip + g_mt + 4*MI_6]
    mov eax, r15d
    EPILOGUE

# FN composer_hint_draw(TF*, kind, x, y, w, h): the argument hint after the box's text (drawn inside the box)
FN composer_hint_draw
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 8], r8d
    mov [rsp + 12], r9d
    mov qword ptr [rip + hint_text], 0
    call composer_hint
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call composer_hint_at
    mov r13d, eax
    mov r14d, edx
    mov rdi, r12                # a copy: the record's lists may change before a dump
    call strlen
    mov ecx, 127
    cmp rax, rcx
    cmova rax, rcx
    lea rdi, [rip + hint_buf]
    xor ecx, ecx
2:  cmp rcx, rax
    jae 3f
    mov dl, [r12 + rcx]
    mov [rdi + rcx], dl
    inc rcx
    jmp 2b
3:  mov byte ptr [rdi + rcx], 0
    mov [rip + hint_text], rdi
    mov [rip + hint_x], r13d
    mov [rip + hint_y], r14d
    mov edi, [rsp]
    add edi, [rip + g_mt + 4*MI_2]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    sub edx, [rip + g_mt + 4*MI_4]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    mov rdi, rbx
    call ta_line_h_of
    mov r15d, eax
    mov rdi, r12
    call strlen
    mov r9, rax
    mov rdi, [rbx + TF_face]
    test rdi, rdi
    jnz 1f
    lea rdi, [rip + g_face_ui]
1:  mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    mov r8, r12
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    call gfx_clip_pop
9:  EPILOGUE

# FN composer_hint_dump(sb): "hint TEXT at X Y" for the hint drawn last
FN composer_hint_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, [rip + hint_text]
    test r12, r12
    jz 9f
    lea rsi, [rip + .Ld_hint]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_at]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + hint_x]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rip + hint_y]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

.section .rodata
.Ld_hint: .asciz "hint "
.Ld_at: .asciz " at "
