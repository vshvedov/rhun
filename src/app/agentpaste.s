# What the clipboard and a drop bring to the agents' box (generic; phase 4 tasks 4 and 5). Nothing here knows
# which agent takes the parts: a driver with DRVC_PARTS gets files and images, every other box gets text.
#
# The clipboard (the extension's ar() WV@5822560): a paste into the box of a driver with parts asks the
# platform for files, an image and text, and takes the best the clipboard has: files win over an image, an
# image over text. Files go through agatt_attach_paths (every file looked at before it is read; a folder a
# mention; the unsupported names one band; the limits' toasts). An image's bytes are attached as "Image" by
# what they are (PNG, JPEG, GIF, WebP); bytes that are no image rhun takes paste nothing (the extension's
# guard: never an image's bytes as text). An image larger than the request reads was never read whole: a
# toast. A long paste (the extension's cqe WV@3707999: at least 20 characters once trimmed and more than 800,
# or more than 2 line feeds) is remembered while the box keeps its text (at most 100, the newest last, as
# XD); at Send those the prompt still holds go with it as parts (MPK_PASTE, MPF_AUTO), which a driver may
# send beside the text (Claude: inline_pastes, finding 43); the text itself goes as typed.
#
# A drop (drop.s): a conversation's area of a driver with parts claims a drag with files while it draws: a
# veil with "Drop to attach as context" while one is over it; dropped files are attached as the clipboard's
# are, the box gets the keys. rhun's own drags of paths (an explorer row, a file's tab) become mentions at the
# box's caret: "@PATH" relative to the conversation's checkout (else the project) when inside it, else
# absolute; quoted when it holds white space; a folder with a "/" after it. (The mention's final syntax is
# agentmention.s's, phase 4 task 7.)
#
#   agpaste_kinds() -> eax CLIPK_*      what a paste into the focused place takes (app_clip_request)
#   agpaste_take(CLIPK_*, ptr, len)     the platform's answer of files or an image (app_clip_complete_kind)
#   agpaste_remember(ptr, len)          composer_paste: the text it put in the box (cleaned)
#   agpaste_parts(AS*, AP*, ptr, len)   agentext_send's hook: the remembered pastes the prompt holds
#   agpaste_forget()                    the box's text went (composer_sent) or changed owner (composer_owner)
#   agpaste_area(x, y, w, h)            agents_draw: a conversation's area claims a drop, shows the veil
#   agpaste_dump(sb)                    print-agent-pastes: "pastes=N" then a line a paste "N units=U lines=L"
.include "rhun.inc"

.equ PASTE_MIN, 20              # the extension's: trimmed units at least (TZt)
.equ PASTE_LONG, 800            #   more units than this (LZt), or more line feeds than PASTE_LINES (RZt)
.equ PASTE_LINES, 2
.equ PASTES_MAX, 100            #   remembered at most (Vje)

.bss
.p2align 3
pastes: .zero VEC_SIZE          # owned cstr per long paste, the oldest first (8 bytes each)
psb: .zero SB_SIZE
va_x: .long 0                   # the conversation's area as agpaste_area saw it last, and its veil then
va_y: .long 0
va_w: .long 0
va_h: .long 0
va_veil: .long 0
va_lines: .long 0
va_wmax: .long 0                #   its widest line
.text

# FN agpaste_kinds() -> eax CLIPK_*: see the top. The box of a driver with parts (its command menu's filter
#   not holding the keys) takes all three kinds; anything else text
FN agpaste_kinds
    sub rsp, 8
    cmp dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    jne 8f
    call agentpop_field
    test rax, rax
    jnz 8f
    call agatt_caps
    test eax, DRVC_PARTS
    jz 8f
    mov eax, CLIPK_ALL
    add rsp, 8
    ret
8:  mov eax, CLIPK_TEXT
    add rsp, 8
    ret

# parts_box() -> eax 1 when the box has the keys and its driver takes parts
parts_box:
    sub rsp, 8
    xor eax, eax
    cmp dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    jne 9f
    call agatt_caps
    and eax, DRVC_PARTS
    shr eax, 12
9:  add rsp, 8
    ret

# image_refused(ATT_*): an image's refusal in words (rhun's, as agentatt.s says them for a file)
image_refused:
    PROLOGUE
    mov ebx, edi
    lea rdi, [rip + psb]
    call sb_clear
    lea rsi, [rip + .Lw_total]
    cmp ebx, ATT_TOTAL
    je 1f
    lea rsi, [rip + .Lw_full]
    cmp ebx, ATT_FULL
    je 1f
    lea rsi, [rip + .Lw_big]    # ATT_BIG (what the request reads makes it rare)
    cmp ebx, ATT_BIG
    jne 9f
    lea rdi, [rip + psb]
    call sb_push_cstr
    jmp 8f
1:  lea rdi, [rip + psb]
    call sb_push_cstr
    lea rdi, [rip + psb]
    lea rsi, [rip + .Lw_image_was_not]
    call sb_push_cstr
8:  lea rdi, [rip + psb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + psb + SB_ptr]
    call app_toast
9:  EPILOGUE

# FN agpaste_take(CLIPK_*, ptr, len): see the top
FN agpaste_take
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    call parts_box
    test eax, eax
    jz 9f
    cmp ebx, CLIPK_FILES
    jne 2f
    test r12, r12
    jz 9f
    mov rdi, r12                # (a NUL after each path: agatt_attach_paths stops at the end)
    mov rsi, r13
    call agatt_attach_paths
    jmp 8f
2:  cmp ebx, CLIPK_IMAGE
    jne 9f
    test r12, r12
    jnz 3f
    lea rdi, [rip + .Lw_clip_big]
    cmp r13, CLIP_TOO_BIG
    je 31f
    lea rdi, [rip + .Lw_clip_form]
    cmp r13, CLIP_NOT_TAKEN
    jne 9f
31: call app_toast
    jmp 8f
3:  call agatt_box_make
    mov rdi, rax
    mov esi, MPK_IMAGE
    lea rdx, [rip + .Lw_image]
    xor ecx, ecx
    mov r8, r12
    mov r9, r13
    call agatt_add_bytes
    cmp eax, ATT_UNSUPPORTED    # not an image rhun takes: nothing (never its bytes as text)
    je 7f
    cmp eax, ATT_EMPTY
    je 7f
    mov edi, eax
    call image_refused
7:  call agatt_tidy
    inc qword ptr [rip + g_att_gen]
8:  mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# units_lf(ptr, len) -> rax UTF-16 units, rdx line feeds
units_lf:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call agent_units
    mov r13, rax
    xor edx, edx
    xor ecx, ecx
1:  cmp rcx, r12
    jae 2f
    cmp byte ptr [rbx + rcx], 10
    jne 11f
    inc rdx
11: inc rcx
    jmp 1b
2:  mov rax, r13
    EPILOGUE

# trim(ptr, len) -> rax ptr, rdx len without ASCII blanks and controls at both ends
trim:
    mov rax, rdi
    mov rdx, rsi
1:  test rdx, rdx
    jz 9f
    cmp byte ptr [rax], ' '
    ja 2f
    inc rax
    dec rdx
    jmp 1b
2:  cmp byte ptr [rax + rdx - 1], ' '
    ja 9f
    dec rdx
    jnz 2b
9:  ret

# is_long(ptr, len) -> eax 1: more than PASTE_LONG units or more than PASTE_LINES line feeds (hqe)
is_long:
    sub rsp, 8
    call units_lf
    add rsp, 8
    xor ecx, ecx
    cmp rax, PASTE_LONG
    seta cl
    cmp rdx, PASTE_LINES
    jbe 1f
    mov ecx, 1
1:  mov eax, ecx
    ret

# paste_at(i) -> rax the i-th remembered paste (cstr)
paste_at:
    mov rax, [rip + pastes + VEC_ptr]
    mov rax, [rax + rdi*8]
    ret

# paste_drop(i): the i-th remembered paste goes, the later ones move up
paste_drop:
    PROLOGUE
    mov rbx, rdi
    call paste_at
    mov rdi, rax
    call mem_free
    mov rdi, [rip + pastes + VEC_ptr]
    lea rdi, [rdi + rbx*8]
    lea rsi, [rdi + 8]
    mov rdx, [rip + pastes + VEC_len]
    sub rdx, rbx
    dec rdx
    shl rdx, 3
    call memmove
    dec qword ptr [rip + pastes + VEC_len]
    EPILOGUE

# FN agpaste_remember(ptr, len): see the top
FN agpaste_remember
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call is_long
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call trim
    mov r12, rax
    mov r13, rdx
    mov rdi, rax
    mov rsi, rdx
    call agent_units
    cmp rax, PASTE_MIN
    jb 9f
    mov rax, [rip + pastes + VEC_len]   # the newest already: nothing
    test rax, rax
    jz 3f
    lea rdi, [rax - 1]
    call paste_at
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call str_eq_cstr_n
    test eax, eax
    jnz 9f
    xor r14d, r14d              # an equal older one goes
1:  cmp r14, [rip + pastes + VEC_len]
    jae 3f
    mov rdi, r14
    call paste_at
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call str_eq_cstr_n
    test eax, eax
    jz 2f
    mov rdi, r14
    call paste_drop
    jmp 1b
2:  inc r14
    jmp 1b
3:  cmp qword ptr [rip + pastes + VEC_len], PASTES_MAX
    jb 4f
    xor edi, edi
    call paste_drop
    jmp 3b
4:  mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov rbx, rax
    lea rdi, [rip + pastes]
    mov esi, 8
    call vec_push
    mov [rax], rbx
9:  EPILOGUE

# str_eq_cstr_n(cstr, ptr, len) -> eax 1 when the cstr is those bytes
str_eq_cstr_n:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call strlen
    cmp rax, r13
    jne 8f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call memeq
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# contains(hay, hay len, needle cstr) -> eax 1 when the needle is in the hay
contains:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov r14, rax
    xor r15d, r15d
1:  mov rax, r15
    add rax, r14
    cmp rax, r12
    ja 8f
    mov al, [r13]
    cmp [rbx + r15], al
    jne 2f
    lea rdi, [rbx + r15]
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jnz 9f
2:  inc r15
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# FN agpaste_parts(AS*, AP*, ptr, len): see the top. A paste goes when the prompt holds it, unless the prompt
#   is a command that begins with it and it is not long by itself (pqe WV@3708700). It is a part the Send's
#   hooks added (MPF_AUTO): a prompt that was not taken gives it back to nobody; the list stays until the box's
#   text goes. A pack that is full leaves the rest in the text alone
FN agpaste_parts
    PROLOGUE 16
    mov rbx, rsi
    mov r12, rdx
    mov r13, rcx
    test rbx, rbx
    jz 9f
    mov rdi, r12                # the prompt as the extension's ne: its start trimmed
    mov rsi, r13
    call trim
    mov [rsp], rax
    mov [rsp + 8], rdx
    xor r14d, r14d
1:  cmp r14, [rip + pastes + VEC_len]
    jae 9f
    mov rdi, r14
    call paste_at
    mov r15, rax
    inc r14
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    call contains
    test eax, eax
    jz 1b
    mov rcx, [rsp + 8]          # "/..." beginning with it, and it short: not sent
    test rcx, rcx
    jz 3f
    mov rax, [rsp]
    cmp byte ptr [rax], '/'
    jne 3f
    mov rdi, r15
    call strlen
    cmp rax, [rsp + 8]
    ja 3f
    mov rdi, [rsp]
    mov rsi, r15
    mov rdx, rax
    call memeq
    test eax, eax
    jz 3f
    mov rdi, r15
    call strlen
    mov rdi, r15
    mov rsi, rax
    call is_long
    test eax, eax
    jz 1b
3:  mov rdi, r15
    call strlen
    push 0
    push 0
    mov rdi, rbx
    mov esi, MPK_PASTE
    lea rdx, [rip + .Lw_paste]
    xor ecx, ecx
    mov r8, r15
    mov r9, rax
    call agatt_add_text
    add rsp, 16
    test eax, eax
    jnz 9f                      # full: the rest go as the text alone
    mov rdi, rbx
    call agatt_count
    lea rsi, [rax - 1]
    mov rdi, rbx
    call agatt_part
    or dword ptr [rax + MP_flags], MPF_AUTO
    jmp 1b
9:  EPILOGUE

# FN agpaste_forget(): see the top
FN agpaste_forget
    PROLOGUE
1:  cmp qword ptr [rip + pastes + VEC_len], 0
    je 9f
    mov rdi, [rip + pastes + VEC_len]
    dec rdi
    call paste_drop
    jmp 1b
9:  EPILOGUE

# FN agpaste_dump(sb): see the top
FN agpaste_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_pastes]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + pastes + VEC_len]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor r12d, r12d
1:  cmp r12, [rip + pastes + VEC_len]
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    mov rdi, r12
    call paste_at
    mov r13, rax
    mov rdi, rax
    call strlen
    mov rdi, r13
    mov rsi, rax
    call units_lf
    mov r13, rax
    mov r14, rdx
    mov rdi, rbx
    lea rsi, [rip + .Ld_units]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_lines]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r14
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r12
    jmp 1b
9:  EPILOGUE

# ---- drops ----

# mention_path(path cstr): the box gets "@PATH " for a path dragged in from rhun itself
mention_path:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
1:  cmp r12, 1                  # its trailing slashes off
    jbe 2f
    cmp byte ptr [rbx + r12 - 1], '/'
    jne 2f
    dec r12
    jmp 1b
2:  mov rdi, rbx
    call vfs_type
    xor r15d, r15d
    cmp eax, 0x4000
    sete r15b                   # a folder: "/" after it
    call agentext_box_owner
    xor r13d, r13d
    test rax, rax
    jz 3f
    mov r13, [rax + AS_cwd]
3:  test r13, r13
    jnz 4f
    mov r13, [rip + g_project]
4:  test r13, r13
    jz 5f
    mov rdi, r13
    call strlen
    mov r14, rax
    cmp r14, r12
    jae 5f
    cmp byte ptr [rbx + r14], '/'
    jne 5f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jz 5f
    lea rbx, [rbx + r14 + 1]    # relative
    sub r12, r14
    dec r12
5:  xor r14d, r14d              # white space in it: quoted
    xor ecx, ecx
6:  cmp rcx, r12
    jae 7f
    cmp byte ptr [rbx + rcx], ' '
    jbe 61f
    inc rcx
    jmp 6b
61: mov r14d, 1
7:  lea rdi, [rip + psb]
    call sb_clear
    lea rdi, [rip + psb]
    mov esi, '@'
    call sb_push_byte
    test r14d, r14d
    jz 71f
    lea rdi, [rip + psb]
    mov esi, '"'
    call sb_push_byte
71: lea rdi, [rip + psb]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    test r15d, r15d
    jz 72f
    lea rdi, [rip + psb]
    mov esi, '/'
    call sb_push_byte
72: test r14d, r14d
    jz 73f
    lea rdi, [rip + psb]
    mov esi, '"'
    call sb_push_byte
73: mov rdi, [rip + psb + SB_ptr]
    mov rsi, [rip + psb + SB_len]
    mov edx, 1
    call composer_insert
    EPILOGUE

# FN agpaste_area(x, y, w, h): see the top. Locals: [rsp] x, y, w, h
FN agpaste_area
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rip + va_x], edi
    mov [rip + va_y], esi
    mov [rip + va_w], edx
    mov [rip + va_h], ecx
    mov dword ptr [rip + va_veil], 0
    call agatt_caps             # a driver without parts claims nothing: the files open
    test eax, DRVC_PARTS
    jz 9f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call drop_take
    test rax, rax
    jz 5f
    mov rbx, rax
    lea r12, [rax + rdx]
    mov r13d, ecx
    mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    test r13d, r13d
    jnz 2f
    mov rdi, rbx                # files from the system: attached (folders become mentions)
    mov rsi, rdx
    call agatt_attach_paths
    jmp 4f
2:  cmp rbx, r12                # rhun's own: mentions
    jae 4f
    mov rdi, rbx
    call strlen
    mov r14, rbx
    lea rbx, [rbx + rax + 1]
    test rax, rax
    jz 2b
    mov rdi, r14
    call mention_path
    jmp 2b
4:  mov dword ptr [rip + g_dirty], 1
5:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call drop_over
    test eax, eax
    jz 9f
    mov dword ptr [rip + va_veil], 1
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call veil
9:  EPILOGUE

# FN agpaste_veil_dump(sb): print-agent-veil: "veil=0|1 area=X,Y,W,H lines=N wmax=PX" as the last frame drew it
FN agpaste_veil_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_veil]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + va_veil]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_area]
    call sb_push_cstr
    xor r12d, r12d
1:  lea rax, [rip + va_x]
    mov esi, [rax + r12*4]
    mov rdi, rbx
    call sb_push_u64
    inc r12d
    cmp r12d, 4
    jae 2f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    jmp 1b
2:  mov rdi, rbx
    lea rsi, [rip + .Ld_lines]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + va_lines]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_wmax]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + va_wmax]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# veil(x, y, w, h): over the area: the panel's colour at 80 %, "Drop to attach as context" centred, its words
#   wrapped at 240 px (the panel's metrics)
veil:
    PROLOGUE 64
    mov dword ptr [rip + va_wmax], 0
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    mov r8d, [rip + g_theme + 4*T_PANEL]
    and r8d, 0x00ffffff
    or r8d, 0xcc000000
    call gfx_fill
    PM eax, MI_16               # the widest line: 240 px at the panel's size, less than the area
    imul eax, eax, 15
    mov ecx, [rsp + 8]
    PM edx, MI_16
    sub ecx, edx
    sub ecx, edx
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 16], eax
    mov rax, [rip + ag_fui]     # the lines: count them first
    mov eax, [rax + FACE_lineh]
    mov [rsp + 20], eax
    mov dword ptr [rsp + 24], 0 # pass 0 counts, pass 1 draws
    mov dword ptr [rsp + 28], 0
.Lv_pass:
    lea rbx, [rip + .Lveil]     # the line starts at rbx, its last word's end r12
    xor r15d, r15d              # lines
.Lv_line:
    cmp byte ptr [rbx], 0
    je .Lv_done
    mov r12, rbx
    mov r13, rbx                # the end of the words that fit
.Lv_word:
    mov r14, r12                # the next word
    cmp r14, rbx
    je 1f
    inc r14                     # (past the space)
1:  cmp byte ptr [r14], 0
    je 2f
    cmp byte ptr [r14], ' '
    je 2f
    inc r14
    jmp 1b
2:  mov rdi, [rip + ag_fui]
    mov rsi, rbx
    mov rdx, r14
    sub rdx, rbx
    call text_width
    cmp eax, [rsp + 16]
    jle 3f
    cmp r13, rbx                # one word wider than the line: it is the line
    jne 4f
    mov r13, r14
    jmp 4f
3:  mov r13, r14
    mov r12, r14
    cmp byte ptr [r14], 0
    jne .Lv_word
4:  cmp dword ptr [rsp + 24], 0
    je 5f
    mov rdi, [rip + ag_fui]     # this line, centred
    mov rsi, rbx
    mov rdx, r13
    sub rdx, rbx
    call text_width
    cmp eax, [rip + va_wmax]
    jbe 41f
    mov [rip + va_wmax], eax
41:
    mov edi, [rsp + 8]
    sub edi, eax
    sar edi, 1
    add edi, [rsp]
    mov [rsp + 32], edi
    mov eax, r15d
    imul eax, [rsp + 20]
    add eax, [rsp + 28]
    mov [rsp + 36], eax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp + 32]
    mov edx, [rsp + 36]
    mov ecx, [rsp + 20]
    mov r8, rbx
    mov r9, r13
    sub r9, rbx
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
5:  inc r15d
    mov rbx, r13
    cmp byte ptr [rbx], ' '
    jne .Lv_line
    inc rbx
    jmp .Lv_line
.Lv_done:
    mov [rip + va_lines], r15d
    cmp dword ptr [rsp + 24], 0
    jne 9f
    mov dword ptr [rsp + 24], 1
    mov eax, r15d               # the block's top: centred in the area
    imul eax, [rsp + 20]
    mov ecx, [rsp + 12]
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp + 4]
    mov [rsp + 28], ecx
    jmp .Lv_pass
9:  EPILOGUE

.section .rodata
.Lveil: .asciz "Drop to attach as context"
.Lw_image: .asciz "Image"
.Lw_paste: .asciz "Paste"
.Lw_clip_big: .asciz "The image on the clipboard is larger than 10 MB \xc2\xb7 not attached"
.Lw_clip_form: .asciz "The image on the clipboard is in a format rhun cannot attach."
.Lw_big: .asciz "Image is larger than 10 MB \xc2\xb7 not attached"
.Lw_total: .asciz "These files are more than 10 MB together \xc2\xb7 "
.Lw_full: .asciz "A message takes 20 attachments \xc2\xb7 "
.Lw_image_was_not: .asciz "Image was not attached"
.Ld_pastes: .asciz "pastes="
.Ld_units: .asciz " units="
.Ld_lines: .asciz " lines="
.Ld_veil: .asciz "veil="
.Ld_area: .asciz " area="
.Ld_wmax: .asciz " wmax="
