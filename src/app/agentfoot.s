# The bands above a driven conversation's prompt box, and its footer under it (generic: a driver gives the
# bands' texts through ev_band, agent_drv.s). Everything here is drawn in the panel's faces and metrics.
#
#   bands_h(AS* or 0, w) -> eax         the room the bands take above the box (0 with none shown)
#   bands_draw(AS* or 0, x, y, w)       each band shown: its text in the panel's small face, wrapped at
#                                       words, at most 4 lines (the 4th cut with "…"); its x ("Dismiss
#                                       error", "Dismiss warning", "Dismiss notice") takes it away until its
#                                       text changes (AL_bandoff)
#   bands_dump(sb, AS* or 0)            print-agent-bands: "band KIND lines=N close=X,Y TEXT" a line each
#                                       (KIND error, settings, auth, rate, notice; as drawn last; a line
#                                       break in the text as \n), then "room=R drawn=D" when one shows: the
#                                       room bands_h gives them at the last width, and the room drawn
#   foot_h(AS*, w) -> eax, foot_draw(AS*, x, y, w)   the footer row under the box: none yet (0)
.include "rhun.inc"

.equ BAND_LINES, 4

.bss
.p2align 3
bsb: .zero SB_SIZE              # a cut line with its "…"
band_lines: .zero 4 * BK_COUNT  # as drawn last: its lines, where its x is (its centre)
band_cx: .zero 4 * BK_COUNT
band_cy: .zero 4 * BK_COUNT
band_w: .long 0                 # the width and the room the last draw took (bands_dump checks bands_h)
band_room: .long 0

.text

# band_text(AS* or 0, kind) -> rax the band's text when it shows (it has one, not dismissed), else 0
band_text:
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rdi, [rdi + AS_live]
    test rdi, rdi
    jz 9f
    mov ecx, esi
    mov edx, 1
    shl edx, cl
    test dword ptr [rdi + AL_bandoff], edx
    jnz 9f
    mov eax, esi
    mov rax, [rdi + AL_bands + rax*8]
9:  ret

# text_w(w) -> eax the width a band's text wraps at, in a panel w wide
text_w:
    mov eax, edi
    sub eax, [rip + g_pmt + 4*MI_12]
    sub eax, [rip + g_pmt + 4*MI_12]
    sub eax, [rip + g_pmt + 4*MI_8]
    sub eax, [rip + g_pmt + 4*MI_8]
    sub eax, [rip + g_pmt + 4*MI_20]
    sub eax, [rip + g_pmt + 4*MI_4]
    cmp eax, 1
    jge 1f
    mov eax, 1
1:  ret

# band_line(ptr, len, maxw) -> rax the bytes of the first line shown, rdx the bytes it takes (with the
#   space or line break that ends it): broken after a word when it can be, else where it fits (a
#   character at least)
band_line:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r15d, edx
    xor eax, eax
    xor edx, edx
    test r13, r13
    jz 9f
    xor r14d, r14d              # the line's end: a line break, or the text's
1:  cmp r14, r13
    jae 2f
    cmp byte ptr [r12 + r14], 10
    je 2f
    inc r14
    jmp 1b
2:  mov rdi, [rip + ag_fsmall]
    mov rsi, r12
    mov rdx, r14
    mov ecx, r15d
    call text_fit
    cmp rax, r14
    jb 3f
    mov rax, r14                # it all fits
    mov rdx, r14
    cmp r14, r13
    jae 9f
    inc rdx                     # and its line break
    EPILOGUE
3:  mov rbx, rax                # what fits; a break at a space there or before
    mov rcx, rax
4:  test rcx, rcx
    jz 5f
    cmp byte ptr [r12 + rcx], ' '
    je 6f
    dec rcx
    jmp 4b
6:  mov rax, rcx
    lea rdx, [rcx + 1]
    EPILOGUE
5:  test rbx, rbx               # one word wider than the line: cut where it fits
    jnz 7f
    mov rdi, r12
    mov rsi, r13
    call utf8_decode
    mov eax, edx
    EPILOGUE
7:  mov rax, rbx
    mov rdx, rbx
9:  EPILOGUE

# band_count(text cstr, maxw) -> eax its lines (at most BAND_LINES), edx 1 when text is left past them
band_count:
    PROLOGUE
    mov r12, rdi
    call strlen
    mov r13, rax
    mov r15d, esi
    xor ebx, ebx
1:  test r13, r13
    jz 8f
    cmp ebx, BAND_LINES
    jae 7f
    mov rdi, r12
    mov rsi, r13
    mov edx, r15d
    call band_line
    test rdx, rdx
    jz 8f
    add r12, rdx
    sub r13, rdx
    inc ebx
    jmp 1b
7:  mov eax, ebx
    mov edx, 1
    EPILOGUE
8:  test ebx, ebx
    jnz 9f
    inc ebx
9:  mov eax, ebx
    xor edx, edx
    EPILOGUE

# band_h(lines) -> eax a band's height: its lines (the x's room at least) and its padding
band_h:
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    imul eax, edi
    mov ecx, [rip + g_pmt + 4*MI_20]
    cmp eax, ecx
    cmovl eax, ecx
    add eax, [rip + g_pmt + 4*MI_6]
    add eax, [rip + g_pmt + 4*MI_6]
    ret

# FN bands_h(AS* or 0, w) -> eax the bands' room: MI_8 above each band shown, and the band
FN bands_h
    PROLOGUE
    mov rbx, rdi
    mov edi, esi
    call text_w
    mov r14d, eax
    xor r12d, r12d              # kind
    xor r13d, r13d              # height
1:  cmp r12d, BK_COUNT
    jae 9f
    mov rdi, rbx
    mov esi, r12d
    call band_text
    inc r12d
    test rax, rax
    jz 1b
    mov rdi, rax
    mov esi, r14d
    call band_count
    mov edi, eax
    call band_h
    add r13d, eax
    add r13d, [rip + g_pmt + 4*MI_8]
    jmp 1b
9:  mov eax, r13d
    EPILOGUE

# FN bands_draw(AS* or 0, x, y, w): the bands, one under the other from y
FN bands_draw
    PROLOGUE 64
    mov rbx, rdi
    mov [rsp], esi              # x
    mov [rsp + 4], edx          # y cursor
    mov [rsp + 8], ecx          # w
    mov [rip + band_w], ecx
    mov edi, ecx
    call text_w
    mov [rsp + 12], eax         # text width
    mov eax, [rsp + 4]
    mov [rsp + 28], eax         # where it starts
    xor r12d, r12d
.Lbd_band:
    cmp r12d, BK_COUNT
    jae .Lbd_done
    lea r10, [rip + band_lines]
    mov dword ptr [r10 + r12*4], 0
    mov rdi, rbx
    mov esi, r12d
    call band_text
    test rax, rax
    jz .Lbd_next
    mov r13, rax                # the text
    mov rdi, rax
    mov esi, [rsp + 12]
    call band_count
    mov [rsp + 16], eax         # lines
    mov [rsp + 20], edx         # cut
    lea r10, [rip + band_lines]
    mov [r10 + r12*4], eax
    mov edi, eax
    call band_h
    mov [rsp + 24], eax         # h
    mov eax, [rsp + 4]
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + 4], eax          # its top
    lea rcx, [rip + band_colors]
    mov eax, [rcx + r12*4]
    lea rcx, [rip + g_theme]
    mov r14d, [rcx + rax*4]     # its colour
    COLOR edi, T_PANEL
    mov esi, r14d
    mov edx, 40
    call color_mix
    mov edi, [rsp]
    add edi, [rip + g_pmt + 4*MI_12]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    sub edx, [rip + g_pmt + 4*MI_12]
    sub edx, [rip + g_pmt + 4*MI_12]
    mov ecx, [rsp + 24]
    PM r8d, MI_RADIUS
    mov r9d, r14d
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    # its lines
    mov rdi, r13
    call strlen
    mov r14, rax                # bytes left
    xor r15d, r15d              # line
.Lbd_line:
    cmp r15d, [rsp + 16]
    jae .Lbd_x
    mov rdi, r13
    mov rsi, r14
    mov edx, [rsp + 12]
    call band_line
    mov [rsp + 32], rdx         # what it takes
    mov [rsp + 48], r13         # what it shows
    mov [rsp + 56], rax
    lea eax, [r15 + 1]
    cmp eax, [rsp + 16]
    jne 2f
    cmp dword ptr [rsp + 20], 0
    je 2f
    mov rdi, r13                # the last line, more after it: cut with "…"
    mov esi, [rsp + 12]
    call cut_line
    mov rax, [rip + bsb + SB_ptr]
    mov [rsp + 48], rax
    mov rax, [rip + bsb + SB_len]
    mov [rsp + 56], rax
2:  mov rdi, [rip + ag_fsmall]  # ui_text_v(face, x, y, h, ptr, len, argb)
    mov ecx, [rdi + FACE_lineh]
    mov edx, ecx
    imul edx, r15d
    add edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_6]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_12]
    add esi, [rip + g_pmt + 4*MI_8]
    mov r8, [rsp + 48]
    mov r9, [rsp + 56]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    add r13, [rsp + 32]
    sub r14, [rsp + 32]
    inc r15d
    jmp .Lbd_line
.Lbd_x:
    PM ecx, MI_20               # the x, at the top right
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rip + g_pmt + 4*MI_12]
    sub esi, [rip + g_pmt + 4*MI_4]
    sub esi, ecx
    mov edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_6]
    mov [rsp + 36], esi
    mov [rsp + 40], edx
    mov eax, ecx
    shr eax, 1
    lea r8d, [rsi + rax]
    lea r10, [rip + band_cx]
    mov [r10 + r12*4], r8d
    lea r8d, [rdx + rax]
    lea r10, [rip + band_cy]
    mov [r10 + r12*4], r8d
    lea edi, [r12 + ID_AGBAND]
    mov r8d, ecx
    mov r9d, IC_CLOSE
    call ag_icon_btn
    mov r15d, eax
    lea edi, [r12 + ID_AGBAND]
    mov esi, [rsp + 36]
    mov edx, [rsp + 40]
    add edx, [rip + g_pmt + 4*MI_20]
    PM ecx, MI_20
    mov r8d, r15d
    lea rax, [rip + band_tips]
    mov r9, [rax + r12*8]
    call tip_note_text
    test r15d, UB_CLICK
    jz 3f
    mov rax, [rbx + AS_live]    # dismissed: until its text changes
    mov ecx, r12d
    mov edx, 1
    shl edx, cl
    or [rax + AL_bandoff], edx
    mov dword ptr [rip + g_dirty], 1
3:  mov eax, [rsp + 24]
    add [rsp + 4], eax
.Lbd_next:
    inc r12d
    jmp .Lbd_band
.Lbd_done:
    mov eax, [rsp + 4]
    sub eax, [rsp + 28]
    mov [rip + band_room], eax
    EPILOGUE

# cut_line(ptr, maxw): bsb = as much of the text as fits at maxw with "…" after it
cut_line:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    lea rdi, [rip + bsb]
    call sb_clear
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lellipsis]
    mov edx, 3
    call text_width
    sub r13d, eax
    jns 1f
    xor r13d, r13d
1:  mov rdi, r12
    call strlen
    mov rcx, rax                # up to a line break
    xor edx, edx
2:  cmp rdx, rcx
    jae 3f
    cmp byte ptr [r12 + rdx], 10
    je 3f
    inc rdx
    jmp 2b
3:  mov rdi, [rip + ag_fsmall]
    mov rsi, r12
    mov ecx, r13d
    call text_fit
    lea rdi, [rip + bsb]
    mov rsi, r12
    mov rdx, rax
    call sb_push
    lea rdi, [rip + bsb]
    lea rsi, [rip + .Lellipsis]
    mov edx, 3
    call sb_push
    EPILOGUE

# FN bands_dump(sb, AS* or 0): "band KIND lines=N close=X,Y TEXT" for each band shown, as drawn last
FN bands_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
    xor r15d, r15d              # bands shown
1:  cmp r13d, BK_COUNT
    jae 9f
    mov rdi, r12
    mov esi, r13d
    call band_text
    test rax, rax
    jz 7f
    mov r14, rax
    mov rdi, rbx
    lea rsi, [rip + .Ld_band]
    call sb_push_cstr
    lea rax, [rip + band_names]
    mov rsi, [rax + r13*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_lines]
    call sb_push_cstr
    mov rdi, rbx
    lea r10, [rip + band_lines]
    mov esi, [r10 + r13*4]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_close]
    call sb_push_cstr
    mov rdi, rbx
    lea r10, [rip + band_cx]
    mov esi, [r10 + r13*4]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    lea r10, [rip + band_cy]
    mov esi, [r10 + r13*4]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
2:  movzx esi, byte ptr [r14]   # the text, a line break as \n
    test esi, esi
    jz 4f
    inc r14
    cmp esi, 10
    jne 3f
    mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
    mov esi, 'n'
3:  mov rdi, rbx
    call sb_push_byte
    jmp 2b
4:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r15d
7:  inc r13d
    jmp 1b
9:  test r15d, r15d
    jz 10f
    mov rdi, rbx
    lea rsi, [rip + .Ld_room]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rip + band_w]
    call bands_h
    mov esi, eax
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_drawn]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + band_room]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
10: EPILOGUE

# FN foot_h(AS*, w) -> eax 0: no footer yet
FN foot_h
    xor eax, eax
    ret

# FN foot_draw(AS*, x, y, w): nothing yet
FN foot_draw
    ret

.section .rodata
.p2align 3
band_colors: .long T_ERROR, T_WARNING, T_WARNING, T_WARNING, T_INFO
band_names: .quad .Lk_error, .Lk_settings, .Lk_auth, .Lk_rate, .Lk_notice
band_tips: .quad .Lt_error, .Lt_warning, .Lt_warning, .Lt_warning, .Lt_notice
.Lk_error: .asciz "error"
.Lk_settings: .asciz "settings"
.Lk_auth: .asciz "auth"
.Lk_rate: .asciz "rate"
.Lk_notice: .asciz "notice"
.Lt_error: .asciz "Dismiss error"
.Lt_warning: .asciz "Dismiss warning"
.Lt_notice: .asciz "Dismiss notice"
.Ld_band: .asciz "band "
.Ld_lines: .asciz " lines="
.Ld_close: .asciz " close="
.Ld_room: .asciz "room="
.Ld_drawn: .asciz " drawn="
.Lellipsis: .ascii "\342\200\246"
