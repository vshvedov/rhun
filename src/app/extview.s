# extension views (docs/extensions/v1.md section 12a): tabs whose pictures an extension describes.
# A picture arrives as text, one shape a line, and is compiled at once into records (VW_pic). It is
# rendered into the view's own pixels (VW_px) when it changes, when the tab's size changes and
# when the theme does; a frame only copies those pixels. Pointer events go back to the extension.
#
# A record: dword op | aux << 8, dword color, dword floats, dword text bytes, the floats, the text
# (padded to 4). A color with alpha 0 is a theme name: its low byte is 1 + T_* (T_ names) or
# 64 + i (c1 .. c8); an explicit color with alpha 0 draws nothing, so its shape is left out.
.include "rhun.inc"

.equ VO_RECT, 1
.equ VO_RRECT, 2
.equ VO_LINE, 3
.equ VO_POLY, 4
.equ VO_FILL, 5
.equ VO_CIRCLE, 6
.equ VO_RING, 7
.equ VO_PIE, 8
.equ VO_TEXT, 9
.equ VO_CLIP, 10
.equ VO_UNCLIP, 11
# op table flags
.equ OF_COLOR, 1                # a color after the fixed numbers
.equ OF_POINTS, 2               # then pairs of numbers
.equ OF_TEXT, 4                 # size and align before the color, the rest of the line after

.bss
.p2align 3
.globl g_views
g_views: .zero VW_SIZE * VW_MAX
view_seq: .long 0               # the last view id handed out
closing: .long 0                # extview_close is closing a tab: no "closed" event for it
.p2align 3
tmp_pic: .zero SB_SIZE          # a picture being compiled
evbuf: .zero SB_SIZE            # an event being written
edges: .zero VEC_SIZE           # a shape's edges: x0 y0 x1 y1, floats
mask: .quad 0                   # its coverage, bw x bh bytes
mask_cap: .quad 0
pts: .zero VEC_SIZE             # a stroke's or fill's points, physical, x y floats (8 bytes each)
nums: .zero VEC_SIZE            # the numbers of the line being compiled (4 bytes each)
bbox: .zero 16                  # x0 y0 x1 y1, floats
fbuf: .zero 64                  # numbers of the line being compiled
.p2align 2
clip_on: .long 0                # a clip of the picture is pushed
pic_points: .long 0             # points in the picture being compiled (at most 200000)
.p2align 3
rec_tmp: .zero 16
rc_aux: .long 0                 # the record being drawn: its aux byte, color, floats, text bytes
rc_color: .long 0
rc_nf: .long 0
rc_tlen: .long 0
cl_w: .long 0                  # the mask being rasterized, as floats: edges are clipped to it
cl_h: .long 0
.p2align 3
budget: .quad 0                 # pixels a rendering may still cover: a picture cannot stall the editor

.equ CLICK_SLOP, 4                # logical pixels a click may move between down and up

.text

# ---------------- the views ----------------

# extview_open(ext, title ptr, len) -> rax the view's id, or -1 when the extension has 8 already
# (or no slot is free): a tab titled so, shown at once
FN extview_open
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    # how many it has, and a free slot
    xor ecx, ecx                # its views
    mov r15, -1                 # the free slot
    xor ebx, ebx
1:  cmp ebx, VW_MAX
    jae 3f
    imul rax, rbx, VW_SIZE
    lea rdx, [rip + g_views]
    add rax, rdx
    mov rdx, [rax + VW_ext]
    test rdx, rdx
    jnz 2f
    cmp r15, -1
    jne 21f
    mov r15, rbx
    jmp 21f
2:  cmp rdx, r12
    jne 21f
    inc ecx
21: inc ebx
    jmp 1b
3:  cmp ecx, VIEWS_PER_EXT
    jae 8f
    cmp r15, -1
    je 8f
    imul rbx, r15, VW_SIZE
    lea rax, [rip + g_views]
    add rbx, rax
    mov rdi, rbx
    xor esi, esi
    mov edx, VW_SIZE
    call memset
    mov [rbx + VW_ext], r12
    inc dword ptr [rip + view_seq]
    mov eax, [rip + view_seq]
    mov [rbx + VW_id], eax
    mov dword ptr [rbx + VW_dirty], 1
    mov dword ptr [rbx + VW_lw], -1
    mov dword ptr [rbx + VW_lh], -1
    # its title: at most 80 bytes, whole characters
    mov rdi, r14
    mov rsi, r13
    mov edx, 80
    call utf8_cut
    mov rdi, r13
    mov rsi, rax
    call mem_dup
    mov [rbx + VW_title], rax
    # the tab, its slot in the flags
    xor edi, edi
    mov esi, TAB_VIEW
    call app_add_tab
    mov rdi, rax
    call tab_at
    lea rcx, [r15 + 1]
    shl rcx, TF_VIEW_SHIFT
    or [rax + TAB_flags], rcx
    mov dword ptr [rip + g_dirty], 1
    mov eax, [rbx + VW_id]
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# extview_find(ext, id) -> VW* or 0
FN extview_find
    xor ecx, ecx
    lea rax, [rip + g_views]
1:  cmp ecx, VW_MAX
    jae 8f
    cmp [rax + VW_ext], rdi
    jne 2f
    cmp [rax + VW_id], esi
    je 9f
2:  add rax, VW_SIZE
    inc ecx
    jmp 1b
8:  xor eax, eax
9:  ret

# extview_of_tab(tab flags) -> VW* or 0
FN extview_of_tab
    mov rax, rdi
    shr rax, TF_VIEW_SHIFT
    and eax, 255
    jz 8f
    dec eax
    cmp eax, VW_MAX
    jae 8f
    imul rax, rax, VW_SIZE
    lea rcx, [rip + g_views]
    add rax, rcx
    cmp qword ptr [rax + VW_ext], 0
    je 8f
    ret
8:  xor eax, eax
    ret

# extview_title(tab flags) -> cstr for the tab strip
FN extview_title
    call extview_of_tab
    test rax, rax
    jz 1f
    mov rax, [rax + VW_title]
    ret
1:  lea rax, [rip + .Lt_view]
    ret

# extview_tab_index(VW*) -> its tab's index, or -1
tab_index:
    PROLOGUE
    mov r12, rdi
    lea rax, [rip + g_views]
    sub r12, rax
    mov rax, r12
    xor edx, edx
    mov ecx, VW_SIZE
    div rcx
    lea r12, [rax + 1]          # slot + 1
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 8f
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_VIEW
    jne 2f
    mov rcx, [rax + TAB_flags]
    shr rcx, TF_VIEW_SHIFT
    and ecx, 255
    cmp rcx, r12
    jne 2f
    mov rax, rbx
    EPILOGUE
2:  inc rbx
    jmp 1b
8:  mov rax, -1
    EPILOGUE

# extview_close(VW*): its tab closes (the extension asked, or it is gone: no "closed" event)
FN extview_close
    PROLOGUE
    mov rbx, rdi
    call tab_index
    test rax, rax
    js 1f
    mov dword ptr [rip + closing], 1
    mov rdi, rax
    call app_close_tab_now      # extview_tab_closed frees the slot
    mov dword ptr [rip + closing], 0
    EPILOGUE
1:  mov rdi, rbx
    call free_slot
    EPILOGUE

# extview_tab_closed(tab flags): a view's tab is closing (app_close_tab_now): its extension hears
# "closed" unless it closed it itself, and the slot is freed
FN extview_tab_closed
    PROLOGUE
    call extview_of_tab
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp dword ptr [rip + closing], 0
    jne 1f
    mov rdi, rbx
    lea rsi, [rip + .Le_closed]
    call send_event
1:  mov rdi, rbx
    call free_slot
9:  EPILOGUE

# extview_owner_gone(ext): its views close with it
FN extview_owner_gone
    PROLOGUE
    mov r12, rdi
    xor r13d, r13d
1:  cmp r13d, VW_MAX
    jae 9f
    imul rbx, r13, VW_SIZE
    lea rax, [rip + g_views]
    add rbx, rax
    cmp [rbx + VW_ext], r12
    jne 2f
    mov rdi, rbx
    call extview_close
2:  inc r13d
    jmp 1b
9:  EPILOGUE

free_slot:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + VW_title]
    call mem_free
    mov rdi, [rbx + VW_px]
    call mem_free
    lea rdi, [rbx + VW_pic]
    call sb_free
    mov rdi, rbx
    xor esi, esi
    mov edx, VW_SIZE
    call memset
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# send_event(VW*, cstr rest): "0 view ID " + rest + LF to its extension, when it runs
send_event:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call event_head
    test eax, eax
    jz 9f
    lea rdi, [rip + evbuf]
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    call event_send
9:  EPILOGUE

# event_head(VW*) -> eax 1 with "0 view ID " in evbuf, 0 when its extension does not run
event_head:
    PROLOGUE
    mov rbx, rdi
    mov rax, [rbx + VW_ext]
    xor ecx, ecx
    test rax, rax
    jz 8f
    cmp dword ptr [rax + EXT_status], ES_RUNNING
    jne 8f
    test dword ptr [rax + EXT_features], FEAT_VIEWS
    jz 8f
    lea rdi, [rip + evbuf]
    call sb_clear
    lea rdi, [rip + evbuf]
    lea rsi, [rip + .Lev_view]
    call sb_push_cstr
    lea rdi, [rip + evbuf]
    mov esi, [rbx + VW_id]
    call sb_push_u64
    lea rdi, [rip + evbuf]
    mov esi, ' '
    call sb_push_byte
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# event_send(VW*): evbuf and a LF to its extension
event_send:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + evbuf]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rbx + VW_ext]
    mov rsi, [rip + evbuf + SB_ptr]
    mov rdx, [rip + evbuf + SB_len]
    call ext_send
    EPILOGUE

# push_logical(int physical in edi): its value / g_s with two decimals onto evbuf, and a space
push_logical:
    PROLOGUE
    cvtsi2ss xmm0, edi
    divss xmm0, [rip + g_s]
    call push_num
    lea rdi, [rip + evbuf]
    mov esi, ' '
    call sb_push_byte
    EPILOGUE

# push_num(xmm0): a number with at most two decimals onto evbuf ("12", "12.5", "7.25")
push_num:
    PROLOGUE
    mulss xmm0, [rip + f_100]
    cvtss2si eax, xmm0
    mov ebx, eax
    test ebx, ebx
    jns 1f
    lea rdi, [rip + evbuf]
    mov esi, '-'
    call sb_push_byte
    neg ebx
1:  mov eax, ebx
    xor edx, edx
    mov ecx, 100
    div ecx
    mov r12d, edx               # hundredths
    lea rdi, [rip + evbuf]
    mov esi, eax
    call sb_push_u64
    test r12d, r12d
    jz 9f
    lea rdi, [rip + evbuf]
    mov esi, '.'
    call sb_push_byte
    mov eax, r12d
    xor edx, edx
    mov ecx, 10
    div ecx
    mov r13d, edx
    lea rdi, [rip + evbuf]
    lea esi, [rax + '0']
    call sb_push_byte
    test r13d, r13d
    jz 9f
    lea rdi, [rip + evbuf]
    lea esi, [r13 + '0']
    call sb_push_byte
9:  EPILOGUE

# ---------------- pictures ----------------

# extview_set(VW*, ptr, len) -> eax 0, or the first line (from 1) that cannot be read; the picture
# replaces the last one only when all of it can be read
FN extview_set
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], rsi              # the body
    mov [rsp + 8], rdx
    lea rdi, [rip + tmp_pic]
    call sb_clear
    mov dword ptr [rip + pic_points], 0
    mov dword ptr [rsp + 16], 0 # line number
    mov dword ptr [rsp + 20], 0 # shapes
    mov r12, [rsp]              # the line's start
    mov r15, r12
    add r15, [rsp + 8]          # the body's end
.Lps_line:
    cmp r12, r15
    jae .Lps_done
    inc dword ptr [rsp + 16]
    # the line: r12 .. r13
    mov r13, r12
1:  cmp r13, r15
    jae 2f
    cmp byte ptr [r13], 10
    je 2f
    inc r13
    jmp 1b
2:  mov [rsp + 24], r13         # where the next line starts (after the LF)
    call compile_line
    test eax, eax
    js .Lps_bad
    jz 3f
    inc dword ptr [rsp + 20]
    cmp dword ptr [rsp + 20], VIEW_SHAPES_MAX
    ja .Lps_bad
3:  mov r12, [rsp + 24]
    inc r12
    jmp .Lps_line
.Lps_done:
    # the new picture in place; the old one's memory goes to the scratch
    lea rdi, [rbx + VW_pic]
    lea rsi, [rip + tmp_pic]
    mov ecx, SB_SIZE
2:  dec ecx
    js 3f
    mov al, [rdi + rcx]
    mov dl, [rsi + rcx]
    mov [rdi + rcx], dl
    mov [rsi + rcx], al
    jmp 2b
3:  mov eax, [rsp + 20]
    mov [rbx + VW_shapes], eax
    mov dword ptr [rbx + VW_dirty], 1
    mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE
.Lps_bad:
    mov eax, [rsp + 16]
    EPILOGUE

# compile_line: the line r12 .. r13 into tmp_pic -> eax 1 a shape, 0 nothing (empty, unknown or
# invisible), -1 it cannot be read. r12 moves.
compile_line:
    PROLOGUE 32
    call tok
    test rdx, rdx
    jz 8f                       # an empty line
    # which shape
    mov r14, rax
    mov [rsp], rdx
    lea rbx, [rip + ops]
1:  mov rdi, [rbx]
    test rdi, rdi
    jz 8f                       # unknown: a later rhun may draw it
    mov rsi, [rsp]
    push rdi
    push rdi
    mov rdx, rdi
    mov rdi, r14
    call str_eq_cstr
    pop rdi
    pop rdi
    test eax, eax
    jnz 2f
    add rbx, 16
    jmp 1b
2:  # rbx: name, op, numbers before the color, flags, minimum points (bytes 8 .. 15)
    movzx eax, byte ptr [rbx + 8]
    mov [rsp + 8], eax          # op
    mov dword ptr [rsp + 12], 0 # aux
    mov dword ptr [rsp + 16], 0 # the color
    lea rdi, [rip + nums]
    mov qword ptr [rdi + VEC_len], 0
    movzx r15d, byte ptr [rbx + 9]  # fixed numbers still to read
3:  test r15d, r15d
    jz 4f
    call num
    test eax, eax
    jz 9f
    call push_float
    dec r15d
    jmp 3b
4:  test byte ptr [rbx + 10], OF_TEXT
    jz 5f
    # size and align
    call tok
    lea rdi, [rip + sizes]
    call word_index
    test eax, eax
    js 9f
    mov [rsp + 12], eax
    call tok
    lea rdi, [rip + aligns]
    call word_index
    test eax, eax
    js 9f
    shl eax, 2
    or [rsp + 12], eax
5:  test byte ptr [rbx + 10], OF_COLOR
    jz 6f
    call color
    cmp edx, 1
    jb 9f
    ja 8f                       # transparent: left out
    mov [rsp + 16], eax
6:  test byte ptr [rbx + 10], OF_POINTS
    jz 7f
    # pairs to the end of the line
61: call tok
    test rdx, rdx
    jz 62f
    mov rdi, rax
    mov rsi, rdx
    call parse_num
    test eax, eax
    jz 9f
    call push_float
    call tok
    test rdx, rdx
    jz 9f                       # an odd count
    mov rdi, rax
    mov rsi, rdx
    call parse_num
    test eax, eax
    jz 9f
    call push_float
    lea rax, [rip + nums]
    mov rax, [rax + VEC_len]
    movzx ecx, byte ptr [rbx + 9]
    sub rax, rcx                # the points' numbers, after the fixed ones
    cmp rax, VIEW_POINTS_MAX * 2
    ja 9f
    jmp 61b
62: lea rax, [rip + nums]
    mov rax, [rax + VEC_len]
    movzx ecx, byte ptr [rbx + 9]
    sub rax, rcx
    shr rax, 1                  # points
    movzx ecx, byte ptr [rbx + 11]
    cmp rax, rcx
    jb 9f
    add [rip + pic_points], eax
    cmp dword ptr [rip + pic_points], 200000
    ja 9f
7:  # the text: the rest of the line after one space
    xor r14d, r14d              # text bytes
    test byte ptr [rbx + 10], OF_TEXT
    jz 71f
    mov r14, r13
    sub r14, r12
    cmp r14, 0
    jle 71f
    cmp byte ptr [r12], ' '
    jne 71f
    inc r12
    dec r14
71: # the record
    mov eax, [rsp + 12]
    shl eax, 8
    or eax, [rsp + 8]
    call emit32
    mov eax, [rsp + 16]
    call emit32
    lea rax, [rip + nums]
    mov rax, [rax + VEC_len]
    call emit32
    mov eax, r14d
    call emit32
    lea rdi, [rip + tmp_pic]
    lea rax, [rip + nums]
    mov rsi, [rax + VEC_ptr]
    mov rdx, [rax + VEC_len]
    shl rdx, 2
    call sb_push
    test r14, r14
    jz 72f
    lea rdi, [rip + tmp_pic]
    mov rsi, r12
    mov rdx, r14
    call sb_push
    # padding to 4
73: test qword ptr [rip + tmp_pic + SB_len], 3
    jz 72f
    lea rdi, [rip + tmp_pic]
    xor esi, esi
    call sb_push_byte
    jmp 73b
72: mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
9:  mov eax, -1
    EPILOGUE

# tok -> rax, rdx the next word of the line r12 .. r13 (rdx 0 at its end); r12 moves past it
tok:
    xor edx, edx
1:  cmp r12, r13
    jae 9f
    cmp byte ptr [r12], ' '
    jne 2f
    inc r12
    jmp 1b
2:  mov rax, r12
3:  cmp r12, r13
    jae 4f
    cmp byte ptr [r12], ' '
    je 4f
    inc r12
    jmp 3b
4:  mov rdx, r12
    sub rdx, rax
9:  ret

# num -> eax 1 with xmm0 the next word's number, 0 when it is not one
num:
    push rbx
    call tok
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call parse_num
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret

# parse_num(ptr, len) -> eax 1 and xmm0, or 0: [-]digits[.digits], at most 9 digits each side
parse_num:
    xor eax, eax
    test rsi, rsi
    jz 9f
    xor r8d, r8d                # negative
    cmp byte ptr [rdi], '-'
    jne 1f
    mov r8d, 1
    inc rdi
    dec rsi
    jz 9f
1:  xor ecx, ecx                # the integer part
    xor r9d, r9d                # its digits
2:  test rsi, rsi
    jz 5f
    movzx edx, byte ptr [rdi]
    cmp edx, '.'
    je 3f
    sub edx, '0'
    cmp edx, 9
    ja 9f
    imul ecx, ecx, 10
    add ecx, edx
    inc r9d
    cmp r9d, 7
    ja 9f
    inc rdi
    dec rsi
    jmp 2b
3:  # the fraction
    inc rdi
    dec rsi
    cvtsi2ss xmm0, ecx
    movss xmm1, [rip + f_one]
    xor r10d, r10d
4:  test rsi, rsi
    jz 6f
    movzx edx, byte ptr [rdi]
    sub edx, '0'
    cmp edx, 9
    ja 9f
    divss xmm1, [rip + f_ten]
    cvtsi2ss xmm2, edx
    mulss xmm2, xmm1
    addss xmm0, xmm2
    inc r10d
    cmp r10d, 9
    ja 9f
    inc rdi
    dec rsi
    jmp 4b
5:  test r9d, r9d
    jz 9f
    cvtsi2ss xmm0, ecx
6:  test r8d, r8d
    jz 7f
    xorps xmm1, xmm1
    subss xmm1, xmm0
    movss xmm0, xmm1
7:  mov eax, 1
9:  ret

# push_float(xmm0): onto nums
push_float:
    push rbx
    lea rdi, [rip + nums]
    mov esi, 4
    sub rsp, 16
    movss [rsp], xmm0
    call vec_push
    movss xmm0, [rsp]
    add rsp, 16
    movss [rax], xmm0
    pop rbx
    ret

# emit32(eax): four bytes onto tmp_pic
emit32:
    push rbx
    mov [rip + rec_tmp], eax
    lea rdi, [rip + tmp_pic]
    lea rsi, [rip + rec_tmp]
    mov edx, 4
    call sb_push
    pop rbx
    ret

# word_index(table of cstrs, 0-ended; the word in rax, rdx) -> eax its index, or -1
word_index:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rax
    mov r13, rdx
    xor ecx, ecx
1:  mov rdx, [rbx + rcx*8]
    test rdx, rdx
    jz 8f
    push rcx
    push rcx
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    pop rcx
    pop rcx
    test eax, eax
    jnz 2f
    inc ecx
    jmp 1b
2:  mov eax, ecx
    jmp 9f
8:  mov eax, -1
9:  pop r13
    pop r12
    pop rbx
    ret

# color -> edx 1 and eax the next word's color (explicit, or a theme name as described above),
# edx 2 for an explicit color with nothing visible, edx 0 when it is not a color
color:
    push rbx
    call tok
    test rdx, rdx
    jz 8f
    cmp byte ptr [rax], '#'
    jne 2f
    mov rdi, rax
    mov rsi, rdx
    call parse_color
    test edx, edx
    jz 8f
    mov edx, 1
    test eax, 0xff000000
    jnz 9f
    mov edx, 2
    jmp 9f
2:  push rax
    push rdx
    lea rdi, [rip + theme_names]
    call word_index
    pop rdx
    pop rcx
    test eax, eax
    js 3f
    lea rcx, [rip + theme_slots]
    movzx eax, byte ptr [rcx + rax]
    inc eax                     # 1 + T_*
    mov edx, 1
    jmp 9f
3:  # c1 .. c8
    cmp rdx, 2
    jne 8f
    cmp byte ptr [rcx], 'c'
    jne 8f
    movzx eax, byte ptr [rcx + 1]
    sub eax, '1'
    cmp eax, 7
    ja 8f
    add eax, 64
    mov edx, 1
    jmp 9f
8:  xor edx, edx
9:  pop rbx
    ret

# resolve(color) -> eax ARGB for drawing now
resolve:
    test edi, 0xff000000
    jz 1f
    mov eax, edi
    ret
1:  xor eax, eax
    test edi, edi
    jz 3f                       # no color: clip, unclip
    cmp edi, 64
    jae 2f
    lea eax, [rdi - 1]
    lea rcx, [rip + g_theme]
    mov eax, [rcx + rax*4]
    ret
2:  lea eax, [rdi - 64]
    and eax, 7
    lea rcx, [rip + chart_colors]
    mov eax, [rcx + rax*4]
3:  ret

# ---------------- drawing a frame ----------------

# extview_draw(x, y, w, h): the active tab's view, rendered again first when it must be; the
# pointer's moves, clicks and the wheel go to its extension
FN extview_draw
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov rdi, [rip + g_tab_cur]
    call tab_at
    mov rdi, [rax + TAB_flags]
    call extview_of_tab
    test rax, rax
    jz 9f
    mov rbx, rax
    # only the view on screen keeps its pixels
    xor ecx, ecx
    lea rax, [rip + g_views]
91: cmp ecx, VW_MAX
    jae 92f
    cmp rax, rbx
    je 93f
    mov rdi, [rax + VW_px]
    test rdi, rdi
    jz 93f
    push rax
    push rcx
    call mem_free
    pop rcx
    pop rax
    mov qword ptr [rax + VW_px], 0
    mov dword ptr [rax + VW_pw], 0
    mov dword ptr [rax + VW_ph], 0
93: add rax, VW_SIZE
    inc ecx
    jmp 91b
92: mov eax, [rsp]
    mov [rbx + VW_sx], eax
    mov eax, [rsp + 4]
    mov [rbx + VW_sy], eax
    # its size, logical, said when it changed; the font metrics when the scale did
    mov edi, [rsp + 8]
    call to_logical
    mov r12d, eax
    mov edi, [rsp + 12]
    call to_logical
    mov r13d, eax
    cmp r12d, [rbx + VW_lw]
    jne 1f
    cmp r13d, [rbx + VW_lh]
    je 2f
1:  mov [rbx + VW_lw], r12d
    mov [rbx + VW_lh], r13d
    mov rdi, rbx
    call event_head
    test eax, eax
    jz 2f
    lea rdi, [rip + evbuf]
    lea rsi, [rip + .Le_size]
    call sb_push_cstr
    lea rdi, [rip + evbuf]
    mov esi, r12d
    call sb_push_u64
    lea rdi, [rip + evbuf]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + evbuf]
    mov esi, r13d
    call sb_push_u64
    mov rdi, rbx
    call event_send
2:  mov eax, [rip + g_s]
    cmp eax, [rbx + VW_scale]
    jne 21f
    mov eax, [rip + g_face_gen]
    cmp eax, [rbx + VW_fgen]
    je 3f
21: mov rdi, rbx
    call send_metrics
3:  # pixels of the right size, rendered with this theme
    mov eax, [rsp + 8]
    cmp eax, [rbx + VW_pw]
    jne 31f
    mov eax, [rsp + 12]
    cmp eax, [rbx + VW_ph]
    jne 31f
    mov eax, [rip + g_theme_cur]
    cmp eax, [rbx + VW_theme]
    jne 32f
    COLOR eax, T_BG
    cmp eax, [rbx + VW_bg]
    jne 32f
    cmp dword ptr [rbx + VW_dirty], 0
    je 4f
    jmp 32f
31: mov rdi, [rbx + VW_px]
    call mem_free
    mov qword ptr [rbx + VW_px], 0
    mov eax, [rsp + 8]
    mov [rbx + VW_pw], eax
    mov eax, [rsp + 12]
    mov [rbx + VW_ph], eax
    mov eax, [rbx + VW_pw]
    imul eax, [rbx + VW_ph]
    test eax, eax
    jle 9f
    shl rax, 2
    mov rdi, rax
    call mem_alloc_try
    test rax, rax
    jz 9f
    mov [rbx + VW_px], rax
32: mov rdi, rbx
    call render
4:  mov rdx, [rbx + VW_px]
    test rdx, rdx
    jz 5f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov ecx, [rbx + VW_pw]
    mov r8d, [rbx + VW_ph]
    call gfx_blit
5:  # the pointer
    lea rax, [rbx + VW_SIZE]    # the slot, for the area's id
    lea rcx, [rip + g_views]
    sub rax, rcx
    xor edx, edx
    mov ecx, VW_SIZE
    div rcx
    lea edi, [rax + ID_VIEW - 1]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 12]
    call ui_btn
    mov [rsp + 16], eax
    # where the pointer is, logical, even outside (a drag can leave the view)
    mov edi, [rip + g_mx]
    sub edi, [rsp]
    call to_logical
    mov r12d, eax
    mov edi, [rip + g_my]
    sub edi, [rsp + 4]
    call to_logical
    mov r13d, eax
    xor r14d, r14d              # it moved
    cmp r12d, [rbx + VW_mx]
    jne 50f
    cmp r13d, [rbx + VW_my]
    je 51f
50: mov r14d, 1
    mov [rbx + VW_mx], r12d
    mov [rbx + VW_my], r13d
51: test dword ptr [rsp + 16], UB_PRESS
    jz 52f
    mov dword ptr [rbx + VW_down], 1
    mov [rbx + VW_ax], r12d
    mov [rbx + VW_ay], r13d
    lea rsi, [rip + .Le_down]
    call point_event
    test dword ptr [rip + g_released], 1 << BTN_LEFT
    jnz 53f                     # it came up in the same frame
    jmp 55f
52: cmp dword ptr [rbx + VW_down], 0
    je 54f
    # the button is down: drags, then up (and click when it came up over the view)
    test dword ptr [rip + g_released], 1 << BTN_LEFT
    jnz 53f
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jz 53f
    test r14d, r14d
    jz 55f
    lea rsi, [rip + .Le_drag]
    call point_event
    jmp 55f
53: mov dword ptr [rbx + VW_down], 0
    lea rsi, [rip + .Le_up]
    call point_event
    test dword ptr [rsp + 16], UB_CLICK
    jz 55f
    # a click is a release where the button went down, give or take a few pixels
    mov eax, [rbx + VW_mx]
    sub eax, [rbx + VW_ax]
    mov ecx, eax
    neg ecx
    cmovl ecx, eax
    cmp ecx, CLICK_SLOP
    jg 55f
    mov eax, [rbx + VW_my]
    sub eax, [rbx + VW_ay]
    mov ecx, eax
    neg ecx
    cmovl ecx, eax
    cmp ecx, CLICK_SLOP
    jg 55f
    lea rsi, [rip + .Le_click]
    call point_event
    jmp 55f
54: # no button: hover over the view, leave when it goes
    test dword ptr [rsp + 16], UB_HOVER
    jz 56f
    mov eax, [rbx + VW_in]
    mov dword ptr [rbx + VW_in], 1
    test eax, eax
    jz 541f
    test r14d, r14d
    jz 55f
541: lea rsi, [rip + .Le_hover]
    call point_event
55: # the wheel over it
    test dword ptr [rsp + 16], UB_HOVER
    jz 9f
    mov eax, [rip + g_scroll_y]
    test eax, eax
    jz 9f
    mov rdi, rbx
    call event_head
    test eax, eax
    jz 9f
    lea rdi, [rip + evbuf]
    lea rsi, [rip + .Le_wheel]
    call sb_push_cstr
    call push_xy
    mov edi, [rip + g_scroll_y]
    cvtsi2ss xmm0, edi
    divss xmm0, [rip + g_s]
    call push_num
    mov rdi, rbx
    call event_send
    jmp 9f
56: cmp dword ptr [rbx + VW_in], 0
    je 9f
    mov dword ptr [rbx + VW_in], 0
    mov rdi, rbx
    lea rsi, [rip + .Le_leave]
    call send_event
9:  EPILOGUE

# point_event(rsi "click " or "hover "): with VW_mx VW_my (rbx the view)
point_event:
    PROLOGUE
    mov r12, rsi
    mov rdi, rbx
    call event_head
    test eax, eax
    jz 9f
    lea rdi, [rip + evbuf]
    mov rsi, r12
    call sb_push_cstr
    call push_xy
    dec qword ptr [rip + evbuf + SB_len]    # the space after Y
    mov rdi, rbx
    call event_send
9:  EPILOGUE

# push_xy(): "X Y " of the pointer (rbx the view) onto evbuf
push_xy:
    PROLOGUE
    cvtsi2ss xmm0, dword ptr [rbx + VW_mx]
    call push_num
    lea rdi, [rip + evbuf]
    mov esi, ' '
    call sb_push_byte
    cvtsi2ss xmm0, dword ptr [rbx + VW_my]
    call push_num
    lea rdi, [rip + evbuf]
    mov esi, ' '
    call sb_push_byte
    EPILOGUE

# send_metrics(VW*): "metrics" and, for each size, its character advance and line height
send_metrics:
    PROLOGUE
    mov rbx, rdi
    mov eax, [rip + g_s]
    mov [rbx + VW_scale], eax
    mov eax, [rip + g_face_gen]
    mov [rbx + VW_fgen], eax
    mov dword ptr [rbx + VW_dirty], 1   # its text is drawn with other faces
    mov rdi, rbx
    call event_head
    test eax, eax
    jz 9f
    lea rdi, [rip + evbuf]
    lea rsi, [rip + .Le_metrics]
    call sb_push_cstr
    xor r12d, r12d
1:  cmp r12d, 4
    jae 2f
    lea rax, [rip + sizes]
    mov rsi, [rax + r12*8]
    lea rdi, [rip + evbuf]
    call sb_push_cstr
    lea rdi, [rip + evbuf]
    mov esi, ' '
    call sb_push_byte
    lea rax, [rip + faces]
    mov r13, [rax + r12*8]
    mov edi, [r13 + FACE_cellw]
    call push_logical
    mov edi, [r13 + FACE_lineh]
    call push_logical
    inc r12d
    jmp 1b
2:  dec qword ptr [rip + evbuf + SB_len]
    mov rdi, rbx
    call event_send
9:  EPILOGUE

# to_logical(physical) -> eax, rounded down
to_logical:
    cvtsi2ss xmm0, edi
    divss xmm0, [rip + g_s]
    cvttss2si eax, xmm0
    ret

# ---------------- rendering ----------------

# render(VW*): the picture into VW_px
render:
    PROLOGUE 48
    mov rbx, rdi
    mov dword ptr [rbx + VW_dirty], 0
    mov eax, [rip + g_theme_cur]
    mov [rbx + VW_theme], eax
    COLOR eax, T_BG
    mov [rbx + VW_bg], eax
    mov rdi, [rbx + VW_px]
    test rdi, rdi
    jz 9f
    mov esi, [rbx + VW_pw]
    mov edx, [rbx + VW_ph]
    call gfx_target_push
    xor edi, edi
    xor esi, esi
    mov edx, [rbx + VW_pw]
    mov ecx, [rbx + VW_ph]
    COLOR r8d, T_BG
    call gfx_fill
    mov dword ptr [rip + clip_on], 0
    mov eax, [rbx + VW_pw]
    mov ecx, [rbx + VW_ph]
    imul rax, rcx
    shl rax, 6                  # 64 times the view's area
    mov [rip + budget], rax
    mov r12, [rbx + VW_pic + SB_ptr]
    mov r13, r12
    add r13, [rbx + VW_pic + SB_len]
1:  cmp r12, r13
    jae 8f
    cmp qword ptr [rip + budget], 0
    jl 8f                       # spent: the rest is left out
    mov eax, [r12]
    mov [rsp], eax              # op | aux << 8
    shr eax, 8
    mov [rip + rc_aux], eax
    mov edi, [r12 + 4]
    call resolve
    mov [rip + rc_color], eax
    mov eax, [r12 + 8]
    mov [rip + rc_nf], eax
    mov eax, [r12 + 12]
    mov [rip + rc_tlen], eax
    lea r14, [r12 + 16]         # the floats
    mov eax, [rip + rc_nf]
    lea r15, [r14 + rax*4]      # the text
    # the next record
    mov eax, [rip + rc_tlen]
    add eax, 3
    and eax, -4
    lea rax, [r15 + rax]
    mov [rsp + 16], rax
    movzx eax, byte ptr [rsp]
    cmp eax, VO_UNCLIP
    ja 7f
    lea rcx, [rip + draw_ops]
    call [rcx + rax*8]
7:  mov r12, [rsp + 16]
    jmp 1b
8:  cmp dword ptr [rip + clip_on], 0
    je 81f
    call gfx_clip_pop
81: call gfx_target_pop
9:  EPILOGUE

# the draw_ops get r14 the floats and r15 the text, rc_* the rest of the record; they keep r14, r15

# p(i) -> xmm0 the i-th float times the scale
.macro P i, reg
    movss \reg, [r14 + 4*\i]
    mulss \reg, [rip + g_s]
.endm

d_none:
    ret

d_rect:
    P 0, xmm0
    P 1, xmm1
    P 2, xmm2
    P 3, xmm3
    addss xmm2, xmm0
    addss xmm3, xmm1
    cvtss2si edi, xmm0
    cvtss2si esi, xmm1
    cvtss2si edx, xmm2
    cvtss2si ecx, xmm3
    sub edx, edi
    sub ecx, esi
    call spend
    mov r8d, [rip + rc_color]
    jmp gfx_fill

# spend(edi x, esi y, edx w, ecx h): the rectangle's pixels within the target off the budget;
# keeps its arguments
spend:
    push rdi
    push rsi
    push rdx
    push rcx
    add edx, edi                # x1
    add ecx, esi                # y1
    xor eax, eax
    cmp edi, eax
    cmovl edi, eax
    cmp esi, eax
    cmovl esi, eax
    mov eax, [rip + g_cv + CV_w]
    cmp edx, eax
    cmovg edx, eax
    mov eax, [rip + g_cv + CV_h]
    cmp ecx, eax
    cmovg ecx, eax
    sub edx, edi
    jle 9f
    sub ecx, esi
    jle 9f
    imul rdx, rcx
    sub [rip + budget], rdx
9:  pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

d_rrect:
    PROLOGUE 32
    call shape_begin
    P 2, xmm2
    P 3, xmm3
    xorps xmm5, xmm5
    comiss xmm2, xmm5
    jbe 9f
    comiss xmm3, xmm5
    jbe 9f
    # r within half of each side
    P 4, xmm4
    movss xmm0, xmm2
    mulss xmm0, [rip + f_half]
    minss xmm4, xmm0
    movss xmm0, xmm3
    mulss xmm0, [rip + f_half]
    minss xmm4, xmm0
    maxss xmm4, xmm5
    movss [rsp], xmm4           # r
    P 0, xmm0
    P 1, xmm1
    movss [rsp + 4], xmm0       # x
    movss [rsp + 8], xmm1       # y
    addss xmm0, xmm2
    subss xmm0, xmm4
    movss [rsp + 12], xmm0      # x + w - r
    addss xmm1, xmm3
    subss xmm1, xmm4
    movss [rsp + 16], xmm1      # y + h - r
    movss xmm0, [rsp + 4]
    addss xmm0, xmm4
    movss [rsp + 20], xmm0      # x + r
    movss xmm1, [rsp + 8]
    addss xmm1, xmm4
    movss [rsp + 24], xmm1      # y + r
    # the corners clockwise from the top right, each a quarter turn
    movss xmm0, [rsp + 12]
    movss xmm1, [rsp + 24]
    xorps xmm3, xmm3
    call corner
    movss xmm0, [rsp + 12]
    movss xmm1, [rsp + 16]
    movss xmm3, [rip + f_90]
    call corner
    movss xmm0, [rsp + 20]
    movss xmm1, [rsp + 16]
    movss xmm3, [rip + f_180]
    call corner
    movss xmm0, [rsp + 20]
    movss xmm1, [rsp + 24]
    movss xmm3, [rip + f_270]
    call corner
    call fill_close
    mov edi, [rip + rc_color]
    call shape_end
9:  EPILOGUE

# corner(xmm0 x, xmm1 y, xmm3 from; r at [rsp + 8] of the caller): a quarter arc, or the point
# itself without a radius
corner:
    movss xmm2, [rsp + 8]
    comiss xmm2, [rip + f_half]
    jb fill_point
    movss xmm4, xmm3
    addss xmm4, [rip + f_90]
    xor edi, edi
    jmp arc_points

d_line:
    push rbx
    call shape_begin
    P 0, xmm0
    P 1, xmm1
    call stroke_point
    P 2, xmm0
    P 3, xmm1
    call stroke_point
    P 4, xmm0
    xor edi, edi
    call stroke_end
    mov edi, [rip + rc_color]
    call shape_end
    pop rbx
    ret

d_poly:
    push rbx
    call shape_begin
    mov ebx, 1
1:  mov eax, [rip + rc_nf]
    cmp ebx, eax
    jae 2f
    movss xmm0, [r14 + rbx*4]
    mulss xmm0, [rip + g_s]
    movss xmm1, [r14 + rbx*4 + 4]
    mulss xmm1, [rip + g_s]
    call stroke_point
    add ebx, 2
    jmp 1b
2:  P 0, xmm0
    xor edi, edi
    call stroke_end
    mov edi, [rip + rc_color]
    call shape_end
    pop rbx
    ret

d_fill:
    push rbx
    call shape_begin
    xor ebx, ebx
1:  mov eax, [rip + rc_nf]
    cmp ebx, eax
    jae 2f
    movss xmm0, [r14 + rbx*4]
    mulss xmm0, [rip + g_s]
    movss xmm1, [r14 + rbx*4 + 4]
    mulss xmm1, [rip + g_s]
    call fill_point
    add ebx, 2
    jmp 1b
2:  call fill_close
    mov edi, [rip + rc_color]
    call shape_end
    pop rbx
    ret

d_circle:
    push rbx
    call shape_begin
    P 0, xmm0
    P 1, xmm1
    P 2, xmm2
    xorps xmm3, xmm3            # from the top
    movss xmm4, [rip + f_360]   # all the way round
    xor edi, edi                # no center point
    call arc_points
    call fill_close
    mov edi, [rip + rc_color]
    call shape_end
    pop rbx
    ret

d_pie:
    push rbx
    call shape_begin
    P 0, xmm0
    P 1, xmm1
    call fill_point             # the center
    P 0, xmm0
    P 1, xmm1
    P 2, xmm2
    movss xmm3, [r14 + 12]
    movss xmm4, [r14 + 16]
    mov edi, 1
    call arc_points
    call fill_close
    mov edi, [rip + rc_color]
    call shape_end
    pop rbx
    ret

d_ring:
    push rbx
    call shape_begin
    # the circle's points, then stroked closed
    P 0, xmm0
    P 1, xmm1
    P 2, xmm2
    xorps xmm3, xmm3
    movss xmm4, [rip + f_360]
    mov edi, 2                  # into the stroke
    call arc_points
    P 3, xmm0
    mov edi, 1                  # closed
    call stroke_end
    mov edi, [rip + rc_color]
    call shape_end
    pop rbx
    ret

d_text:
    PROLOGUE 16
    mov eax, [rip + rc_aux]     # size, align << 2
    mov ecx, eax
    and ecx, 3
    lea rdx, [rip + faces]
    mov rbx, [rdx + rcx*8]      # the face
    shr eax, 2
    and eax, 3
    mov [rsp], eax              # align
    mov eax, [rip + rc_tlen]
    mov [rsp + 4], eax          # bytes
    P 0, xmm0
    cvtss2si r12d, xmm0         # x
    P 1, xmm1
    cvtss2si r13d, xmm1         # y
    cmp dword ptr [rsp], 0
    je 2f
    mov rdi, rbx
    mov rsi, r15
    mov edx, [rsp + 4]
    call text_width
    cmp dword ptr [rsp], 1
    jne 1f
    shr eax, 1
1:  sub r12d, eax
2:  mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, [rbx + FACE_lineh]
    mov r8, r15
    mov r9d, [rsp + 4]
    mov eax, [rip + rc_color]
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    EPILOGUE

d_clip:
    cmp dword ptr [rip + clip_on], 0
    je 1f
    call gfx_clip_pop
1:  P 0, xmm0
    P 1, xmm1
    P 2, xmm2
    P 3, xmm3
    addss xmm2, xmm0
    addss xmm3, xmm1
    cvtss2si edi, xmm0
    cvtss2si esi, xmm1
    cvtss2si edx, xmm2
    cvtss2si ecx, xmm3
    sub edx, edi
    sub ecx, esi
    mov dword ptr [rip + clip_on], 1
    jmp gfx_clip_push

d_unclip:
    cmp dword ptr [rip + clip_on], 0
    je 1f
    mov dword ptr [rip + clip_on], 0
    jmp gfx_clip_pop
1:  ret

# ---------------- shapes: edges into the rasterizer ----------------

# shape_begin(): no edges, no points, an empty box
shape_begin:
    mov qword ptr [rip + edges + VEC_len], 0
    mov qword ptr [rip + pts + VEC_len], 0
    movss xmm0, [rip + f_big]
    movss [rip + bbox], xmm0
    movss [rip + bbox + 4], xmm0
    movss xmm0, [rip + f_nbig]
    movss [rip + bbox + 8], xmm0
    movss [rip + bbox + 12], xmm0
    ret

# stroke_point(xmm0 x, xmm1 y) and fill_point: a point onto pts (physical)
stroke_point:
fill_point:
    push rbx
    sub rsp, 16
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    lea rdi, [rip + pts]
    mov esi, 8
    call vec_push
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    movss [rax], xmm0
    movss [rax + 4], xmm1
    add rsp, 16
    pop rbx
    ret

# fill_close(): pts as a closed polygon's edges
fill_close:
    PROLOGUE
    lea rax, [rip + pts]
    mov r12, [rax + VEC_ptr]
    mov r13, [rax + VEC_len]
    cmp r13, 3
    jb 9f
    xor ebx, ebx
1:  cmp rbx, r13
    jae 9f
    movss xmm0, [r12 + rbx*8]
    movss xmm1, [r12 + rbx*8 + 4]
    lea rax, [rbx + 1]
    cmp rax, r13
    jb 2f
    xor eax, eax
2:  movss xmm2, [r12 + rax*8]
    movss xmm3, [r12 + rax*8 + 4]
    call edge
    inc rbx
    jmp 1b
9:  EPILOGUE

# stroke_end(xmm0 width physical, edi 1 closed): pts as a polyline of that width, round joins and
# ends: a quad for each segment and a disc at each point, all wound the same way
stroke_end:
    PROLOGUE 32
    mov [rsp + 16], edi
    mulss xmm0, [rip + f_half]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe 9f                      # no width: nothing
    movss [rsp], xmm0           # half width
    lea rax, [rip + pts]
    mov r12, [rax + VEC_ptr]
    mov r13, [rax + VEC_len]
    test r13, r13
    jz 9f
    xor ebx, ebx
1:  cmp rbx, r13
    jae 9f
    # the disc
    movss xmm0, [r12 + rbx*8]
    movss xmm1, [r12 + rbx*8 + 4]
    movss xmm2, [rsp]
    call disc
    # the segment to the next point (and from the last to the first when closed)
    lea rax, [rbx + 1]
    cmp rax, r13
    jb 2f
    cmp dword ptr [rsp + 16], 0
    je 3f
    xor eax, eax
2:  movss xmm0, [r12 + rbx*8]
    movss xmm1, [r12 + rbx*8 + 4]
    movss xmm2, [r12 + rax*8]
    movss xmm3, [r12 + rax*8 + 4]
    movss xmm4, [rsp]
    call seg_quad
3:  inc rbx
    jmp 1b
9:  EPILOGUE

# seg_quad(xmm0..3 the segment, xmm4 half width): A B C D = p0 + n, p1 + n, p1 - n, p0 - n
seg_quad:
    PROLOGUE 64
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    movss [rsp + 12], xmm3
    subss xmm2, xmm0            # dx
    subss xmm3, xmm1            # dy
    movss xmm5, xmm2
    mulss xmm5, xmm5
    movss xmm6, xmm3
    mulss xmm6, xmm6
    addss xmm5, xmm6
    sqrtss xmm5, xmm5
    comiss xmm5, [rip + f_tiny]
    jb 9f                       # a point: its disc is enough
    divss xmm4, xmm5
    # n = (-dy, dx) * hw / len
    xorps xmm6, xmm6
    subss xmm6, xmm3
    mulss xmm6, xmm4
    movss [rsp + 16], xmm6      # nx
    mulss xmm2, xmm4
    movss [rsp + 20], xmm2      # ny
    # A B C D
    movss xmm0, [rsp]
    addss xmm0, [rsp + 16]
    movss [rsp + 24], xmm0
    movss xmm0, [rsp + 4]
    addss xmm0, [rsp + 20]
    movss [rsp + 28], xmm0
    movss xmm0, [rsp + 8]
    addss xmm0, [rsp + 16]
    movss [rsp + 32], xmm0
    movss xmm0, [rsp + 12]
    addss xmm0, [rsp + 20]
    movss [rsp + 36], xmm0
    movss xmm0, [rsp + 8]
    subss xmm0, [rsp + 16]
    movss [rsp + 40], xmm0
    movss xmm0, [rsp + 12]
    subss xmm0, [rsp + 20]
    movss [rsp + 44], xmm0
    movss xmm0, [rsp]
    subss xmm0, [rsp + 16]
    movss [rsp + 48], xmm0
    movss xmm0, [rsp + 4]
    subss xmm0, [rsp + 20]
    movss [rsp + 52], xmm0
    xor ebx, ebx
1:  cmp ebx, 4
    jae 9f
    lea eax, [rbx + 1]
    and eax, 3
    movss xmm0, [rsp + 24 + rbx*8]
    movss xmm1, [rsp + 28 + rbx*8]
    movss xmm2, [rsp + 24 + rax*8]
    movss xmm3, [rsp + 28 + rax*8]
    call edge
    inc ebx
    jmp 1b
9:  EPILOGUE

# disc(xmm0 x, xmm1 y, xmm2 r): a polygon round the point, wound as seg_quad's quads are
disc:
    PROLOGUE 32
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    call segments_for
    mov r14d, eax               # segments
    # the angle step, negative: clockwise in the maths sense, as the quads
    cvtsi2ss xmm0, r14d
    movss xmm1, [rip + f_2pi]
    divss xmm1, xmm0
    xorps xmm2, xmm2
    subss xmm2, xmm1
    movss [rsp + 12], xmm2
    xor ebx, ebx
1:  cmp ebx, r14d
    jae 9f
    cvtsi2ss xmm0, ebx
    mulss xmm0, [rsp + 12]
    call circle_at
    movss [rsp + 16], xmm0
    movss [rsp + 20], xmm1
    lea eax, [rbx + 1]
    cvtsi2ss xmm0, eax
    mulss xmm0, [rsp + 12]
    call circle_at
    movss xmm2, xmm0
    movss xmm3, xmm1
    movss xmm0, [rsp + 16]
    movss xmm1, [rsp + 20]
    call edge
    inc ebx
    jmp 1b
9:  EPILOGUE

# circle_at(xmm0 angle in radians; the circle at [rsp + 8] of the caller's frame) -> xmm0 x, xmm1 y
circle_at:
    sub rsp, 24
    movss [rsp], xmm0
    call sin_cos                # xmm0 sin, xmm1 cos
    movss xmm2, [rsp + 24 + 8 + 8]
    mulss xmm1, xmm2
    mulss xmm0, xmm2
    addss xmm1, [rsp + 24 + 8]
    addss xmm0, [rsp + 24 + 8 + 4]
    movss xmm2, xmm1
    movss xmm1, xmm0            # y = cy + r sin
    movss xmm0, xmm2            # x = cx + r cos
    add rsp, 24
    ret

# segments_for(xmm2 r physical) -> eax segments for a smooth circle: r, between 12 and 128
segments_for:
    cvtss2si eax, xmm2
    cmp eax, 12
    jge 1f
    mov eax, 12
1:  cmp eax, 128
    jle 2f
    mov eax, 128
2:  ret

# arc_points(xmm0 x, xmm1 y, xmm2 r, xmm3 from, xmm4 to: degrees from the top, clockwise on
# screen; edi 0 into pts as a fill, 1 the same, 2 into pts for a stroke): the arc's points
arc_points:
    PROLOGUE 48
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    movss [rsp + 16], xmm3
    movss [rsp + 20], xmm4
    call segments_for
    mov r14d, eax
    # the sweep in radians, its step
    movss xmm0, [rsp + 20]
    subss xmm0, [rsp + 16]
    mulss xmm0, [rip + f_deg]
    cvtsi2ss xmm1, r14d
    divss xmm0, xmm1
    movss [rsp + 24], xmm0
    # 0 degrees at the top: angle - 90
    movss xmm0, [rsp + 16]
    subss xmm0, [rip + f_90]
    mulss xmm0, [rip + f_deg]
    movss [rsp + 28], xmm0
    xor ebx, ebx
1:  cmp ebx, r14d
    ja 9f
    cvtsi2ss xmm0, ebx
    mulss xmm0, [rsp + 24]
    addss xmm0, [rsp + 28]
    call circle_at
    call fill_point
    inc ebx
    jmp 1b
9:  EPILOGUE

# sin_cos(xmm0 radians) -> xmm0 sin, xmm1 cos (Taylor series after reducing to [-pi, pi])
sin_cos:
    movss xmm1, xmm0
    divss xmm1, [rip + f_2pi]
    cvtss2si eax, xmm1
    cvtsi2ss xmm1, eax
    mulss xmm1, [rip + f_2pi]
    subss xmm0, xmm1            # x in about [-pi, pi]
    # sin = x - x^3/6 + x^5/120 - x^7/5040 + x^9/362880
    movss xmm2, xmm0
    mulss xmm2, xmm2            # x^2
    movss xmm3, [rip + f_s9]
    mulss xmm3, xmm2
    addss xmm3, [rip + f_s7]
    mulss xmm3, xmm2
    addss xmm3, [rip + f_s5]
    mulss xmm3, xmm2
    addss xmm3, [rip + f_s3]
    mulss xmm3, xmm2
    addss xmm3, [rip + f_one]
    mulss xmm3, xmm0            # sin
    # cos = 1 - x^2/2 + x^4/24 - x^6/720 + x^8/40320 - x^10/3628800
    movss xmm1, [rip + f_c10]
    mulss xmm1, xmm2
    addss xmm1, [rip + f_c8]
    mulss xmm1, xmm2
    addss xmm1, [rip + f_c6]
    mulss xmm1, xmm2
    addss xmm1, [rip + f_c4]
    mulss xmm1, xmm2
    addss xmm1, [rip + f_c2]
    mulss xmm1, xmm2
    addss xmm1, [rip + f_one]
    movss xmm0, xmm3
    ret

# edge(xmm0..3): onto edges, the box grown
edge:
    push rbx
    sub rsp, 16
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    movss [rsp + 12], xmm3
    lea rdi, [rip + edges]
    mov esi, 16
    call vec_push
    movups xmm0, [rsp]
    movups [rax], xmm0
    # the box
    movss xmm0, [rsp]
    movss xmm1, [rsp + 8]
    call grow_x
    movss xmm0, [rsp + 4]
    movss xmm1, [rsp + 12]
    call grow_y
    add rsp, 16
    pop rbx
    ret
grow_x:
    movss xmm2, [rip + bbox]
    minss xmm2, xmm0
    minss xmm2, xmm1
    movss [rip + bbox], xmm2
    movss xmm2, [rip + bbox + 8]
    maxss xmm2, xmm0
    maxss xmm2, xmm1
    movss [rip + bbox + 8], xmm2
    ret
grow_y:
    movss xmm2, [rip + bbox + 4]
    minss xmm2, xmm0
    minss xmm2, xmm1
    movss [rip + bbox + 4], xmm2
    movss xmm2, [rip + bbox + 12]
    maxss xmm2, xmm0
    maxss xmm2, xmm1
    movss [rip + bbox + 12], xmm2
    ret

# shape_end(edi color): the edges rasterized within their box (inside the target) and drawn
shape_end:
    PROLOGUE 32
    mov [rsp], edi
    cmp qword ptr [rip + edges + VEC_len], 0
    je 9f
    # the box, whole pixels, within the target
    movss xmm0, [rip + bbox]
    cvttss2si eax, xmm0
    dec eax
    xor ecx, ecx
    cmp eax, ecx
    cmovl eax, ecx
    mov r12d, eax               # bx
    movss xmm0, [rip + bbox + 4]
    cvttss2si eax, xmm0
    dec eax
    cmp eax, ecx
    cmovl eax, ecx
    mov r13d, eax               # by
    movss xmm0, [rip + bbox + 8]
    cvttss2si eax, xmm0
    add eax, 2
    mov ecx, [rip + g_cv + CV_w]
    cmp eax, ecx
    cmovg eax, ecx
    sub eax, r12d
    jle 9f
    mov r14d, eax               # bw
    movss xmm0, [rip + bbox + 12]
    cvttss2si eax, xmm0
    add eax, 2
    mov ecx, [rip + g_cv + CV_h]
    cmp eax, ecx
    cmovg eax, ecx
    sub eax, r13d
    jle 9f
    mov r15d, eax               # bh
    # the mask
    mov eax, r14d
    imul eax, r15d
    mov [rsp + 4], eax
    sub [rip + budget], rax
    jl 9f
    cmp rax, [rip + mask_cap]
    jbe 1f
    mov edi, [rsp + 4]
    call mem_alloc_try
    test rax, rax
    jz 9f                       # the old mask stays as it was
    mov [rsp + 16], rax
    mov rdi, [rip + mask]
    call mem_free
    mov rax, [rsp + 16]
    mov [rip + mask], rax
    mov eax, [rsp + 4]
    mov [rip + mask_cap], rax
1:  mov edi, r14d
    mov esi, r15d
    call raster_begin
    cvtsi2ss xmm0, r14d
    movss [rip + cl_w], xmm0
    cvtsi2ss xmm0, r15d
    movss [rip + cl_h], xmm0
    cvtsi2ss xmm4, r12d
    cvtsi2ss xmm5, r13d
    movss [rsp + 8], xmm4
    movss [rsp + 12], xmm5
    mov rbx, [rip + edges + VEC_ptr]
    mov rax, [rip + edges + VEC_len]
    mov [rsp + 16], rax
    xor eax, eax
    mov [rsp + 24], rax
2:  mov rax, [rsp + 24]
    cmp rax, [rsp + 16]
    jae 3f
    shl rax, 4
    movss xmm0, [rbx + rax]
    subss xmm0, [rsp + 8]
    movss xmm1, [rbx + rax + 4]
    subss xmm1, [rsp + 12]
    movss xmm2, [rbx + rax + 8]
    subss xmm2, [rsp + 8]
    movss xmm3, [rbx + rax + 12]
    subss xmm3, [rsp + 12]
    call clip_line
    inc qword ptr [rsp + 24]
    jmp 2b
3:  mov rdi, [rip + mask]
    call raster_end
    # coverage a hair under full is full: a fill is its exact color inside
    mov rdi, [rip + mask]
    mov ecx, [rsp + 4]
4:  dec ecx
    js 5f
    cmp byte ptr [rdi + rcx], 252
    jb 4b
    mov byte ptr [rdi + rcx], 255
    jmp 4b
5:  mov edi, r12d
    mov esi, r13d
    mov rdx, [rip + mask]
    mov ecx, r14d
    mov r8d, r15d
    mov r9d, [rsp]
    call gfx_mask_exact
9:  EPILOGUE

# clip_line(xmm0 x0, xmm1 y0, xmm2 x1, xmm3 y1), in the mask's pixels: raster_line for the part
# within its rows; the part left of it moved onto its left side (it covers the whole row to its
# right), the part right of it left out (it covers nothing in the mask). The edge keeps its
# direction, so its winding.
clip_line:
    PROLOGUE 48
    subss xmm2, xmm0
    subss xmm3, xmm1
    movss [rsp], xmm0           # x0
    movss [rsp + 4], xmm1       # y0
    movss [rsp + 8], xmm2       # dx
    movss [rsp + 12], xmm3      # dy
    movss xmm4, xmm3
    mulss xmm4, xmm4
    comiss xmm4, [rip + f_eps2]
    jb 9f                       # level: it adds nothing
    # t where it meets the rows' top and bottom, within 0 .. 1
    xorps xmm4, xmm4
    subss xmm4, xmm1
    divss xmm4, xmm3
    movss xmm5, [rip + cl_h]
    subss xmm5, xmm1
    divss xmm5, xmm3
    movss xmm6, xmm4
    minss xmm6, xmm5            # from
    maxss xmm4, xmm5            # to
    xorps xmm7, xmm7
    maxss xmm6, xmm7
    minss xmm4, [rip + f_one]
    comiss xmm6, xmm4
    jae 9f                      # it misses them
    movss [rsp + 16], xmm6
    movss [rsp + 28], xmm4
    # t where it crosses x 0 and x w: two cuts between from and to
    movss xmm0, xmm4
    movss xmm1, xmm4
    movss xmm5, xmm2
    mulss xmm5, xmm5
    comiss xmm5, [rip + f_eps2]
    jb 1f                       # upright: no cuts
    xorps xmm0, xmm0
    subss xmm0, [rsp]
    divss xmm0, xmm2
    movss xmm1, [rip + cl_w]
    subss xmm1, [rsp]
    divss xmm1, xmm2
    movss xmm5, xmm0
    minss xmm0, xmm1
    maxss xmm1, xmm5
1:  maxss xmm0, xmm6
    minss xmm0, xmm4
    maxss xmm1, xmm6
    minss xmm1, xmm4
    movss [rsp + 20], xmm0
    movss [rsp + 24], xmm1
    # the three pieces
    xor ebx, ebx
2:  cmp ebx, 3
    jae 9f
    movss xmm6, [rsp + 16 + rbx*4]
    movss xmm7, [rsp + 20 + rbx*4]
    inc ebx
    comiss xmm6, xmm7
    jae 2b
    movss xmm0, [rsp + 8]
    mulss xmm0, xmm6
    addss xmm0, [rsp]
    movss xmm1, [rsp + 12]
    mulss xmm1, xmm6
    addss xmm1, [rsp + 4]
    movss xmm2, [rsp + 8]
    mulss xmm2, xmm7
    addss xmm2, [rsp]
    movss xmm3, [rsp + 12]
    mulss xmm3, xmm7
    addss xmm3, [rsp + 4]
    # its side, by its middle
    movss xmm4, xmm0
    addss xmm4, xmm2
    mulss xmm4, [rip + f_half]
    xorps xmm5, xmm5
    comiss xmm4, xmm5
    jae 3f
    xorps xmm0, xmm0
    xorps xmm2, xmm2
    jmp 4f
3:  comiss xmm4, [rip + cl_w]
    ja 2b
    maxss xmm0, xmm5
    minss xmm0, [rip + cl_w]
    maxss xmm2, xmm5
    minss xmm2, [rip + cl_w]
4:  call raster_line
    jmp 2b
9:  EPILOGUE

# ---------------- for the tests ----------------

# extview_dump(sb): a line per open view: "view=ID title=T shapes=N size=WxH at=X,Y" (logical size,
# physical position)
FN extview_dump
    PROLOGUE
    mov r12, rdi
    xor r13d, r13d
1:  cmp r13d, VW_MAX
    jae 9f
    imul rbx, r13, VW_SIZE
    lea rax, [rip + g_views]
    add rbx, rax
    inc r13d
    cmp qword ptr [rbx + VW_ext], 0
    je 1b
    mov rdi, r12
    lea rsi, [rip + .Ld_view]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + VW_id]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_title]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + VW_title]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ld_shapes]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + VW_shapes]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_size]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + VW_lw]
    call sb_push_u64
    mov rdi, r12
    mov esi, 'x'
    call sb_push_byte
    mov rdi, r12
    mov esi, [rbx + VW_lh]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_at]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + VW_sx]
    call sb_push_u64
    mov rdi, r12
    mov esi, ','
    call sb_push_byte
    mov rdi, r12
    mov esi, [rbx + VW_sy]
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

.section .rodata
.p2align 3
# shapes: name, then bytes: op, fixed numbers, flags, minimum points (pairs after the color)
ops:
    .quad .Lo_rect
    .byte VO_RECT, 4, OF_COLOR, 0, 0, 0, 0, 0
    .quad .Lo_rrect
    .byte VO_RRECT, 5, OF_COLOR, 0, 0, 0, 0, 0
    .quad .Lo_line
    .byte VO_LINE, 5, OF_COLOR, 0, 0, 0, 0, 0
    .quad .Lo_poly
    .byte VO_POLY, 1, OF_COLOR | OF_POINTS, 2, 0, 0, 0, 0
    .quad .Lo_fill
    .byte VO_FILL, 0, OF_COLOR | OF_POINTS, 3, 0, 0, 0, 0
    .quad .Lo_circle
    .byte VO_CIRCLE, 3, OF_COLOR, 0, 0, 0, 0, 0
    .quad .Lo_ring
    .byte VO_RING, 4, OF_COLOR, 0, 0, 0, 0, 0
    .quad .Lo_pie
    .byte VO_PIE, 5, OF_COLOR, 0, 0, 0, 0, 0
    .quad .Lo_text
    .byte VO_TEXT, 2, OF_COLOR | OF_TEXT, 0, 0, 0, 0, 0
    .quad .Lo_clip
    .byte VO_CLIP, 4, 0, 0, 0, 0, 0, 0
    .quad .Lo_unclip
    .byte VO_UNCLIP, 0, 0, 0, 0, 0, 0, 0
    .quad 0, 0
draw_ops: .quad d_none, d_rect, d_rrect, d_line, d_poly, d_fill, d_circle, d_ring, d_pie, d_text
    .quad d_clip, d_unclip
sizes: .quad .Ls_small, .Ls_normal, .Ls_large, .Ls_mono, 0
faces: .quad g_face_small, g_face_ui, g_face_big, g_face_code
aligns: .quad .La_left, .La_center, .La_right, 0
theme_names: .quad .Lc_fg, .Lc_muted, .Lc_bg, .Lc_panel, .Lc_border, .Lc_accent, .Lc_error
    .quad .Lc_warning, .Lc_success, 0
theme_slots: .byte T_FG, T_MUTED, T_BG, T_PANEL, T_BORDER, T_ACCENT, T_ERROR, T_WARNING, T_SUCCESS
.p2align 2
chart_colors: .long 0xff4f7fd9, 0xffd9803f, 0xff3f9f6f, 0xffcf5050, 0xff9a6ad6, 0xff2f9fae, 0xffb88a2a, 0xffc0508f
f_100: .float 100.0
f_one: .float 1.0
f_ten: .float 10.0
f_half: .float 0.5
f_tiny: .float 0.001
f_big: .float 1.0e9
f_nbig: .float -1.0e9
f_360: .float 360.0
f_90: .float 90.0
f_180: .float 180.0
f_270: .float 270.0
f_eps2: .float 1.0e-12
f_deg: .float 0.017453292519943295
f_2pi: .float 6.283185307179586
f_s3: .float -0.16666666666666666
f_s5: .float 0.008333333333333333
f_s7: .float -0.0001984126984126984
f_s9: .float 0.0000027557319223985893
f_c2: .float -0.5
f_c4: .float 0.041666666666666664
f_c6: .float -0.001388888888888889
f_c8: .float 0.0000248015873015873
f_c10: .float -0.0000002755731922398589
.Lo_rect: .asciz "rect"
.Lo_rrect: .asciz "rrect"
.Lo_line: .asciz "line"
.Lo_poly: .asciz "poly"
.Lo_fill: .asciz "fill"
.Lo_circle: .asciz "circle"
.Lo_ring: .asciz "ring"
.Lo_pie: .asciz "pie"
.Lo_text: .asciz "text"
.Lo_clip: .asciz "clip"
.Lo_unclip: .asciz "unclip"
.Ls_small: .asciz "small"
.Ls_normal: .asciz "normal"
.Ls_large: .asciz "large"
.Ls_mono: .asciz "mono"
.La_left: .asciz "left"
.La_center: .asciz "center"
.La_right: .asciz "right"
.Lc_fg: .asciz "fg"
.Lc_muted: .asciz "muted"
.Lc_bg: .asciz "bg"
.Lc_panel: .asciz "panel"
.Lc_border: .asciz "border"
.Lc_accent: .asciz "accent"
.Lc_error: .asciz "error"
.Lc_warning: .asciz "warning"
.Lc_success: .asciz "success"
.Lev_view: .asciz "0 view "
.Le_closed: .asciz "closed"
.Le_size: .asciz "size "
.Le_hover: .asciz "hover "
.Le_click: .asciz "click "
.Le_wheel: .asciz "wheel "
.Le_leave: .asciz "leave"
.Le_down: .asciz "down "
.Le_up: .asciz "up "
.Le_drag: .asciz "drag "
.Le_metrics: .asciz "metrics "
.Lt_view: .asciz "View"
.Ld_view: .asciz "view="
.Ld_title: .asciz " title="
.Ld_shapes: .asciz " shapes="
.Ld_size: .asciz " size="
.Ld_at: .asciz " at="
