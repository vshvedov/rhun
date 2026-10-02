# image tabs: decoded when first shown, fit or zoomed, panned; drawing copies a cached composition
#   below 100% the whole image is scaled once per zoom (bilinear from the nearest halved copy), from 100% up
#   pixels are picked; the visible part is composed over a checkerboard and kept until the view changes
.include "rhun.inc"

.equ ID_IMAGE, 0x1003
.equ ID_IVZOOM, 0x2980
.equ MAXMIP, 16
.equ IVS_NEW, 0
.equ IVS_OK, 1
.equ IVS_FAILED, 2

STRUCT
F IV_img, IMG_SIZE              # decoded image, IMG_px 0 until shown
F IV_state, 4                   # IVS_*
F IV_fit, 4                     # zoom follows the view size
F IV_zoom, 4                    # float, points per image pixel when not fitting
F IV_gen, 4                     # changes with the pixels
F IV_cx, 4                      # float, image point at the view center
F IV_cy, 4
F IV_scale, 4                   # float, screen pixels per image pixel as last drawn
F IV_pad, 4
F IV_bytes, 8                   # file size
F IV_err, 8                     # why it cannot be shown
F IV_mips, 8*MAXMIP             # halved copies: [i] is level i + 1
ENDSTRUCT IV_SIZE

# what the composed view shows
STRUCT
F K_iv, 8
F K_gen, 4
F K_scale, 4
F K_ox, 4                       # image origin on screen
F K_oy, 4
F K_x, 4                        # visible part
F K_y, 4
F K_w, 4
F K_h, 4
F K_c1, 4                       # checkerboard
F K_c2, 4
ENDSTRUCT K_SIZE

# what the scaled copy holds
STRUCT
F S_iv, 8
F S_gen, 4
F S_w, 4                        # scaled size
F S_h, 4
F S_x, 4                        # the part of it that is kept
F S_y, 4
F S_cw, 4
F S_ch, 4
F S_pad, 4
ENDSTRUCT S_SIZE

.bss
.p2align 3
sc_px: .quad 0                  # the image scaled below 100%: all of it when that is small, else what is seen
sc_cap: .quad 0                 # pixels
sc_key: .zero S_SIZE
skey: .zero S_SIZE
.p2align 3
vc_px: .quad 0                  # composed visible part
vc_cap: .quad 0                 # pixels
vc_key: .zero K_SIZE
key: .zero K_SIZE
.p2align 3
tab: .zero SB_SIZE              # per column mapping
tmp: .zero SB_SIZE
view_x: .long 0                 # the view as last drawn
view_y: .long 0
view_w: .long 0
view_h: .long 0
drag_x: .long 0
drag_y: .long 0
drag_cx: .long 0
drag_cy: .long 0
.globl g_scroll_mods
g_scroll_mods: .long 0          # modifiers held while scrolling
ratio: .long 0                  # float, source pixels per screen pixel (map, bilin)

.text

# iv_new() -> image view, fitting
FN iv_new
    mov edi, IV_SIZE
    call mem_alloc
    mov dword ptr [rax + IV_fit], 1
    mov dword ptr [rax + IV_zoom], 0x3f800000
    ret

# iv_free(iv)
FN iv_free
    test rdi, rdi
    jz 1f
    push rbx
    mov rbx, rdi
    call iv_reload
    mov rdi, rbx
    call mem_free
    pop rbx
1:  ret

# iv_reload(iv): forget the pixels; the file is decoded again when next shown (zoom and position stay)
FN iv_reload
    push rbx
    push r12
    push r13
    mov rbx, rdi
    lea rdi, [rbx + IV_img]
    call image_free
    xor r12d, r12d
1:  mov rdi, [rbx + IV_mips + r12*8]
    call mem_free
    mov qword ptr [rbx + IV_mips + r12*8], 0
    inc r12d
    cmp r12d, MAXMIP
    jb 1b
    mov dword ptr [rbx + IV_state], IVS_NEW
    inc dword ptr [rbx + IV_gen]
    call iv_cache_free
    mov dword ptr [rip + g_dirty], 1
    pop r13
    pop r12
    pop rbx
    ret

# iv_cache_free(): release the scaled and composed copies
FN iv_cache_free
    push rbx
    mov rdi, [rip + sc_px]
    call mem_free
    mov qword ptr [rip + sc_px], 0
    mov qword ptr [rip + sc_cap], 0
    mov qword ptr [rip + sc_key + S_iv], 0
    mov rdi, [rip + vc_px]
    call mem_free
    mov qword ptr [rip + vc_px], 0
    mov qword ptr [rip + vc_cap], 0
    mov qword ptr [rip + vc_key + K_iv], 0
    lea rdi, [rip + tab]
    call sb_free
    pop rbx
    ret

# iv_load(doc): read and decode the file
iv_load:
    PROLOGUE
    mov r15, rdi
    mov rbx, [rdi + DOC_img]
    mov rdi, [r15 + DOC_path]
    call file_read_all
    test rax, rax
    jz 7f
    mov r12, rax
    mov r13, rdx
    mov [rbx + IV_bytes], rdx
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [r15 + DOC_path]
    call image_sniff
    test eax, eax
    jz 6f
    mov rdi, r12
    mov rsi, r13
    mov edx, eax
    lea rcx, [rbx + IV_img]
    call image_decode
    test eax, eax
    jnz 5f
    mov dword ptr [rbx + IV_state], IVS_OK
    jmp 8f
5:  mov rax, [rip + g_img_err]
    jmp 61f
6:  lea rax, [rip + .Lnot_image]
61: mov [rbx + IV_err], rax
    mov dword ptr [rbx + IV_state], IVS_FAILED
8:  mov rdi, r12
    call mem_free
    EPILOGUE
7:  lea rax, [rip + .Lunreadable]
    mov [rbx + IV_err], rax
    mov dword ptr [rbx + IV_state], IVS_FAILED
    EPILOGUE

# view_scale(iv) -> xmm0 screen pixels per image pixel in the current view
view_scale:
    cmp dword ptr [rdi + IV_fit], 0
    jne 1f
    movss xmm0, [rdi + IV_zoom]
    mulss xmm0, [rip + g_s]
    ret
1:  # fit inside the view less a margin, never above 100%
    M eax, MI_16
    add eax, eax
    mov esi, [rip + view_w]
    mov edx, [rip + view_h]
    sub esi, eax
    sub edx, eax
    mov eax, 1
    cmp esi, eax
    cmovl esi, eax
    cmp edx, eax
    cmovl edx, eax
    cvtsi2ss xmm0, esi
    cvtsi2ss xmm1, dword ptr [rdi + IV_img + IMG_w]
    divss xmm0, xmm1
    cvtsi2ss xmm2, edx
    cvtsi2ss xmm1, dword ptr [rdi + IV_img + IMG_h]
    divss xmm2, xmm1
    minss xmm0, xmm2
    minss xmm0, [rip + g_s]
    ret

# clamp_center(iv, xmm0 scale): an image smaller than the view is centered, a larger one covers it
clamp_center:
    cvtsi2ss xmm3, dword ptr [rip + view_w]
    cvtsi2ss xmm4, dword ptr [rip + view_h]
    mulss xmm3, [rip + f_half]
    mulss xmm4, [rip + f_half]
    divss xmm3, xmm0            # half the view, in image pixels
    divss xmm4, xmm0
    lea r8, [rdi + IV_cx]
    mov ecx, [rdi + IV_img + IMG_w]
    movss xmm5, xmm3
    call 1f
    lea r8, [rdi + IV_cy]
    mov ecx, [rdi + IV_img + IMG_h]
    movss xmm5, xmm4
1:  # r8 -> center, ecx image size, xmm5 half the view
    cvtsi2ss xmm1, ecx
    movss xmm2, xmm1
    mulss xmm2, [rip + f_half]
    movss xmm6, xmm5
    addss xmm6, xmm5
    comiss xmm6, xmm1
    jae 2f
    movss xmm6, [r8]
    maxss xmm6, xmm5
    subss xmm1, xmm5
    minss xmm6, xmm1
    movss [r8], xmm6
    ret
2:  movss [r8], xmm2
    ret

# zoom_to(iv, xmm0 zoom in points per pixel, px, py): the image point under (px, py) stays there
zoom_to:
    sub rsp, 24
    movss [rsp], xmm0
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    call view_scale
    call clamp_center
    movss [rsp + 12], xmm0      # current scale
    # distance of the point from the view center, in screen pixels
    mov eax, [rip + view_w]
    sar eax, 1
    add eax, [rip + view_x]
    mov ecx, [rsp + 4]
    sub ecx, eax
    cvtsi2ss xmm4, ecx
    mov eax, [rip + view_h]
    sar eax, 1
    add eax, [rip + view_y]
    mov ecx, [rsp + 8]
    sub ecx, eax
    cvtsi2ss xmm5, ecx
    # the image point there
    movss xmm2, xmm4
    divss xmm2, xmm0
    addss xmm2, [rdi + IV_cx]
    movss xmm3, xmm5
    divss xmm3, xmm0
    addss xmm3, [rdi + IV_cy]
    # new zoom, kept in range
    movss xmm1, [rsp]
    maxss xmm1, [rip + f_zmin]
    minss xmm1, [rip + f_zmax]
    movss [rdi + IV_zoom], xmm1
    mov dword ptr [rdi + IV_fit], 0
    mulss xmm1, [rip + g_s]
    divss xmm4, xmm1
    subss xmm2, xmm4
    movss [rdi + IV_cx], xmm2
    divss xmm5, xmm1
    subss xmm3, xmm5
    movss [rdi + IV_cy], xmm3
    mov dword ptr [rip + g_dirty], 1
    add rsp, 24
    ret

# zoom_step(iv, xmm0 factor, px, py): zoom by a factor; passing 100% stops there
zoom_step:
    sub rsp, 24
    mov [rsp], rdi
    mov [rsp + 8], esi
    mov [rsp + 12], edx
    movss [rsp + 16], xmm0
    call view_scale
    divss xmm0, [rip + g_s]     # current zoom
    movss xmm1, xmm0
    mulss xmm1, [rsp + 16]      # new zoom
    movss xmm2, [rip + f_one]
    # crossing 1 in either direction lands on 1
    comiss xmm0, xmm2
    jae 1f
    comiss xmm1, xmm2
    jbe 2f
    movss xmm1, xmm2
    jmp 2f
1:  jbe 2f
    comiss xmm1, xmm2
    jae 2f
    movss xmm1, xmm2
2:  movss xmm0, xmm1
    mov rdi, [rsp]
    mov esi, [rsp + 8]
    mov edx, [rsp + 12]
    add rsp, 24
    jmp zoom_to

# iv_draw(doc, x, y, w, h)
FN iv_draw
    PROLOGUE 64
    mov r15, rdi
    mov rbx, [rdi + DOC_img]
    mov [rip + view_x], esi
    mov [rip + view_y], edx
    mov [rip + view_w], ecx
    mov [rip + view_h], r8d
    mov edi, esi
    mov esi, edx
    mov edx, ecx
    mov ecx, r8d
    COLOR r8d, T_BG
    call gfx_fill
    cmp dword ptr [rbx + IV_state], IVS_NEW
    jne 1f
    mov rdi, r15
    call iv_load
1:  cmp dword ptr [rbx + IV_state], IVS_OK
    jne .Ldr_failed
    mov edi, [rip + view_x]
    mov esi, [rip + view_y]
    mov edx, [rip + view_w]
    mov ecx, [rip + view_h]
    call gfx_clip_push
    mov rdi, rbx
    call view_input
    # scale and placement
    mov rdi, rbx
    call view_scale
    movss [rbx + IV_scale], xmm0
    movss [rsp], xmm0
    mov rdi, rbx
    call clamp_center
    # scaled size, at least a pixel
    movss xmm0, [rsp]
    mov ecx, 1
    cvtsi2ss xmm1, dword ptr [rbx + IV_img + IMG_w]
    mulss xmm1, xmm0
    cvtss2si eax, xmm1
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 4], eax          # sw
    cvtsi2ss xmm1, dword ptr [rbx + IV_img + IMG_h]
    mulss xmm1, xmm0
    cvtss2si eax, xmm1
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 8], eax          # sh
    # origin: a smaller image is centered, a larger one placed by the center point
    mov esi, [rip + view_x]
    mov edx, [rip + view_w]
    mov ecx, [rsp + 4]
    movss xmm1, [rbx + IV_cx]
    call place
    mov [rip + key + K_ox], eax
    mov esi, [rip + view_y]
    mov edx, [rip + view_h]
    mov ecx, [rsp + 8]
    movss xmm1, [rbx + IV_cy]
    call place
    mov [rip + key + K_oy], eax
    # visible part: the image within the clip
    mov eax, [rip + key + K_ox]
    mov ecx, [rip + g_cv + CV_cx0]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rip + key + K_x], eax
    mov eax, [rip + key + K_ox]
    add eax, [rsp + 4]
    mov ecx, [rip + g_cv + CV_cx1]
    cmp eax, ecx
    cmovg eax, ecx
    sub eax, [rip + key + K_x]
    jle .Ldr_done
    mov [rip + key + K_w], eax
    mov eax, [rip + key + K_oy]
    mov ecx, [rip + g_cv + CV_cy0]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rip + key + K_y], eax
    mov eax, [rip + key + K_oy]
    add eax, [rsp + 8]
    mov ecx, [rip + g_cv + CV_cy1]
    cmp eax, ecx
    cmovg eax, ecx
    sub eax, [rip + key + K_y]
    jle .Ldr_done
    mov [rip + key + K_h], eax
    mov [rip + key + K_iv], rbx
    mov eax, [rbx + IV_gen]
    mov [rip + key + K_gen], eax
    mov eax, [rsp]
    mov [rip + key + K_scale], eax
    COLOR edi, T_BG
    COLOR esi, T_FG
    mov edx, 16
    call color_mix
    mov [rip + key + K_c1], eax
    COLOR edi, T_BG
    COLOR esi, T_FG
    mov edx, 40
    call color_mix
    mov [rip + key + K_c2], eax
    # compose unless the cache holds this very view
    cmp qword ptr [rip + vc_px], 0
    je 2f
    lea rdi, [rip + key]
    lea rsi, [rip + vc_key]
    mov edx, K_SIZE
    call memeq
    test eax, eax
    jnz 3f
2:  mov edi, [rsp + 4]
    mov esi, [rsp + 8]
    call compose
    test eax, eax
    jz .Ldr_done
3:  # copy the rows
    mov r13, [rip + vc_px]
    xor r14d, r14d
4:  cmp r14d, [rip + key + K_h]
    jae .Ldr_done
    mov eax, [rip + key + K_y]
    add eax, r14d
    imul eax, [rip + g_cv + CV_stride]
    add eax, [rip + key + K_x]
    mov rdi, [rip + g_cv + CV_pixels]
    lea rdi, [rdi + rax*4]
    mov rsi, r13
    mov ecx, [rip + key + K_w]
    rep movsd
    mov r13, rsi
    inc r14d
    jmp 4b
.Ldr_done:
    call gfx_clip_pop
    EPILOGUE
.Ldr_failed:
    # what went wrong, centered
    mov eax, [rip + view_h]
    shr eax, 1
    add eax, [rip + view_y]
    sub eax, [rip + g_mt + 4*MI_32]
    mov r12d, eax
    lea rdi, [rip + g_face_ui]
    mov esi, [rip + view_x]
    mov edx, r12d
    mov ecx, [rip + view_w]
    M r8d, MI_24
    lea r9, [rip + .Lcannot]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    add r12d, [rip + g_mt + 4*MI_28]
    lea rdi, [rip + g_face_small]
    mov esi, [rip + view_x]
    mov edx, r12d
    mov ecx, [rip + view_w]
    M r8d, MI_20
    mov r9, [rbx + IV_err]
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    EPILOGUE

# place(view pos, view size, scaled size, xmm1 center point, xmm0 scale) -> screen position of the image edge
place:
    cmp edx, ecx
    jl 1f
    sub edx, ecx
    sar edx, 1
    lea eax, [rsi + rdx]
    ret
1:  cvtsi2ss xmm2, edx
    mulss xmm2, [rip + f_half]
    mulss xmm1, xmm0
    subss xmm2, xmm1
    cvtss2si eax, xmm2
    add eax, esi
    ret

# view_input(iv): wheel, drag and double click over the view
view_input:
    PROLOGUE 16
    mov rbx, rdi
    mov edi, [rip + view_x]
    mov esi, [rip + view_y]
    mov edx, [rip + view_w]
    mov ecx, [rip + view_h]
    call ui_in
    test eax, eax
    jz .Lvi_drag
    # wheel: with ctrl it zooms at the pointer, otherwise it pans
    mov eax, [rip + g_scroll_y]
    or eax, [rip + g_scroll_x]
    jz 3f
    test dword ptr [rip + g_scroll_mods], MOD_CTRL
    jz 2f
    mov eax, [rip + g_scroll_y]
    test eax, eax
    jz 3f
    # factor 1 + |dy| / 250, dividing for a scroll down
    mov ecx, eax
    neg ecx
    cmovl ecx, eax
    cvtsi2ss xmm0, ecx
    divss xmm0, [rip + f_250]
    addss xmm0, [rip + f_one]
    test eax, eax
    jle 1f
    movss xmm1, [rip + f_one]
    divss xmm1, xmm0
    movss xmm0, xmm1
1:  mov rdi, rbx
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call zoom_step
    jmp 3f
2:  mov rdi, rbx
    call view_scale
    cvtsi2ss xmm1, dword ptr [rip + g_scroll_y]
    divss xmm1, xmm0
    addss xmm1, [rbx + IV_cy]
    movss [rbx + IV_cy], xmm1
    cvtsi2ss xmm1, dword ptr [rip + g_scroll_x]
    divss xmm1, xmm0
    addss xmm1, [rbx + IV_cx]
    movss [rbx + IV_cx], xmm1
    mov dword ptr [rip + g_dirty], 1
3:  test dword ptr [rip + g_pressed], 1 << BTN_LEFT
    jz .Lvi_drag
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    cmp dword ptr [rip + g_clicks], 2
    jne 5f
    # double click: fit <-> 100% at the pointer
    mov dword ptr [rip + g_active], 0
    cmp dword ptr [rbx + IV_fit], 0
    je 4f
    mov rdi, rbx
    movss xmm0, [rip + f_one]
    mov esi, [rip + g_mx]
    mov edx, [rip + g_my]
    call zoom_to
    jmp .Lvi_ret
4:  mov dword ptr [rbx + IV_fit], 1
    mov dword ptr [rip + g_dirty], 1
    jmp .Lvi_ret
5:  mov dword ptr [rip + g_active], ID_IMAGE
    mov eax, [rip + g_mx]
    mov [rip + drag_x], eax
    mov eax, [rip + g_my]
    mov [rip + drag_y], eax
    mov rdi, rbx
    call view_scale
    call clamp_center
    mov eax, [rbx + IV_cx]
    mov [rip + drag_cx], eax
    mov eax, [rbx + IV_cy]
    mov [rip + drag_cy], eax
.Lvi_drag:
    cmp dword ptr [rip + g_active], ID_IMAGE
    jne .Lvi_ret
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jz .Lvi_ret
    mov rdi, rbx
    call view_scale
    mov eax, [rip + drag_x]
    sub eax, [rip + g_mx]
    cvtsi2ss xmm1, eax
    divss xmm1, xmm0
    addss xmm1, [rip + drag_cx]
    movss [rbx + IV_cx], xmm1
    mov eax, [rip + drag_y]
    sub eax, [rip + g_my]
    cvtsi2ss xmm1, eax
    divss xmm1, xmm0
    addss xmm1, [rip + drag_cy]
    movss [rbx + IV_cy], xmm1
    mov dword ptr [rip + g_dirty], 1
.Lvi_ret:
    EPILOGUE


# compose(sw, sh) -> 1, or 0 without memory: the view described by key into vc_px
compose:
    PROLOGUE 48
    mov [rsp], edi              # scaled size
    mov [rsp + 4], esi
    mov rbx, [rip + key + K_iv]
    mov eax, [rbx + IV_img + IMG_opaque]
    mov [rsp + 16], eax
    movss xmm0, [rip + key + K_scale]
    comiss xmm0, [rip + f_one]
    jae 1f
    # below 100%: from the scaled copy, 1:1
    mov [rip + skey + S_iv], rbx
    mov eax, [rbx + IV_gen]
    mov [rip + skey + S_gen], eax
    mov eax, [rsp]
    mov [rip + skey + S_w], eax
    mov ecx, [rsp + 4]
    mov [rip + skey + S_h], ecx
    # all of it when it is at most twice the view, so panning is free; else only the visible part
    imul rax, rcx
    mov ecx, [rip + view_w]
    imul ecx, [rip + view_h]
    add rcx, rcx
    cmp rax, rcx
    ja 11f
    xor eax, eax
    mov [rip + skey + S_x], eax
    mov [rip + skey + S_y], eax
    mov eax, [rsp]
    mov [rip + skey + S_cw], eax
    mov eax, [rsp + 4]
    mov [rip + skey + S_ch], eax
    jmp 12f
11: mov eax, [rip + key + K_x]
    sub eax, [rip + key + K_ox]
    mov [rip + skey + S_x], eax
    mov eax, [rip + key + K_y]
    sub eax, [rip + key + K_oy]
    mov [rip + skey + S_y], eax
    mov eax, [rip + key + K_w]
    mov [rip + skey + S_cw], eax
    mov eax, [rip + key + K_h]
    mov [rip + skey + S_ch], eax
12: call scaled
    test rax, rax
    jz .Lco_fail
    mov r12, rax
    mov eax, [rip + skey + S_cw]
    mov [rsp + 8], eax          # source w
    mov eax, [rip + skey + S_ch]
    mov [rsp + 12], eax         # source h
    mov eax, [rip + skey + S_x]
    mov [rsp + 24], eax         # source offset
    mov eax, [rip + skey + S_y]
    mov [rsp + 28], eax
    movss xmm0, [rip + f_one]
    movss [rsp + 32], xmm0      # source pixels per screen pixel
    movss [rsp + 36], xmm0
    jmp 2f
1:  # from 100% up: pick from the image
    mov r12, [rbx + IV_img + IMG_px]
    mov eax, [rbx + IV_img + IMG_w]
    mov [rsp + 8], eax
    mov eax, [rbx + IV_img + IMG_h]
    mov [rsp + 12], eax
    mov qword ptr [rsp + 24], 0
    cvtsi2ss xmm0, dword ptr [rsp + 8]
    cvtsi2ss xmm1, dword ptr [rsp]
    divss xmm0, xmm1
    movss [rsp + 32], xmm0
    cvtsi2ss xmm0, dword ptr [rsp + 12]
    cvtsi2ss xmm1, dword ptr [rsp + 4]
    divss xmm0, xmm1
    movss [rsp + 36], xmm0
2:  # room for the view
    mov eax, [rip + key + K_w]
    imul eax, [rip + key + K_h]
    cmp rax, [rip + vc_cap]
    jbe 3f
    mov r13, rax
    mov rdi, [rip + vc_px]
    call mem_free
    lea rdi, [r13*4]
    call mem_alloc_try
    mov [rip + vc_px], rax
    mov qword ptr [rip + vc_cap], 0
    test rax, rax
    jz .Lco_fail
    mov [rip + vc_cap], r13
3:  # column table: source x, the checkerboard column parity in bit 31
    mov edi, [rip + key + K_w]
    shl edi, 2
    call tab_get
    mov r13, rax
    movss xmm0, [rsp + 32]
    movss [rip + ratio], xmm0
    M r14d, MI_8                # checker square
    xor ebx, ebx
4:  cmp ebx, [rip + key + K_w]
    jae 5f
    mov eax, [rip + key + K_x]
    sub eax, [rip + key + K_ox]
    add eax, ebx
    sub eax, [rsp + 24]
    mov edx, [rsp + 8]
    call map
    mov ecx, eax
    mov eax, [rip + key + K_x]
    sub eax, [rip + key + K_ox]
    add eax, ebx
    xor edx, edx
    div r14d
    shl eax, 31
    or eax, ecx
    mov [r13 + rbx*4], eax
    inc ebx
    jmp 4b
5:  movss xmm0, [rsp + 36]
    movss [rip + ratio], xmm0
    mov rdi, [rip + vc_px]
    xor r15d, r15d
.Lco_row:
    cmp r15d, [rip + key + K_h]
    jae .Lco_done
    mov eax, [rip + key + K_y]
    sub eax, [rip + key + K_oy]
    add eax, r15d
    sub eax, [rsp + 28]
    mov edx, [rsp + 12]
    call map
    mov ecx, [rsp + 8]
    imul rax, rcx
    lea rsi, [r12 + rax*4]      # source row
    mov eax, [rip + key + K_y]
    sub eax, [rip + key + K_oy]
    add eax, r15d
    xor edx, edx
    div r14d
    mov r10d, [rip + key + K_c1]    # even squares
    mov r11d, [rip + key + K_c2]    # odd squares
    test eax, 1
    jz 6f
    xchg r10d, r11d
6:  mov r8, r13
    mov r9d, [rip + key + K_w]
    cmp dword ptr [rsp + 16], 0
    jne .Lco_opaque
.Lco_px:
    mov ecx, [r8]
    mov edx, ecx
    and edx, 0x7fffffff
    mov edx, [rsi + rdx*4]
    mov eax, edx
    shr eax, 24
    cmp eax, 255
    je 8f
    # p + square * (255 - a) / 255
    xor eax, 255
    mov ebx, eax
    shr ebx, 7
    add eax, ebx
    mov ebx, r10d
    test ecx, ecx
    cmovs ebx, r11d
    mov ecx, ebx
    and ebx, 0xff00ff
    imul ebx, eax
    shr ebx, 8
    and ebx, 0xff00ff
    and ecx, 0xff00
    imul ecx, eax
    shr ecx, 8
    and ecx, 0xff00
    add edx, ebx
    add edx, ecx
8:  or edx, 0xff000000
    mov [rdi], edx
    add rdi, 4
    add r8, 4
    dec r9d
    jnz .Lco_px
    inc r15d
    jmp .Lco_row
.Lco_opaque:
    mov edx, [r8]
    and edx, 0x7fffffff
    mov eax, [rsi + rdx*4]
    mov [rdi], eax
    add rdi, 4
    add r8, 4
    dec r9d
    jnz .Lco_opaque
    inc r15d
    jmp .Lco_row
.Lco_done:
    lea rdi, [rip + vc_key]
    lea rsi, [rip + key]
    mov ecx, K_SIZE
    rep movsb
    mov eax, 1
    EPILOGUE
.Lco_fail:
    xor eax, eax
    EPILOGUE

# map(eax offset, edx size) -> eax index of the source pixel under a screen pixel (ratio: source per screen)
map:
    cvtsi2ss xmm0, eax
    addss xmm0, [rip + f_half]
    mulss xmm0, [rip + ratio]
    cvttss2si eax, xmm0
    test eax, eax
    jns 1f
    xor eax, eax
1:  cmp eax, edx
    jl 2f
    lea eax, [rdx - 1]
2:  ret

# bilin(eax offset, edx size) -> eax i0, edx i1, ecx weight of i1 (0..256), for sampling between two pixels (clobbers r8)
bilin:
    cvtsi2ss xmm0, eax
    addss xmm0, [rip + f_half]
    mulss xmm0, [rip + ratio]
    subss xmm0, [rip + f_half]
    xor ecx, ecx
    comiss xmm0, [rip + f_zero]
    jbe 2f
    cvttss2si eax, xmm0
    lea r8d, [rdx - 1]
    cmp eax, r8d
    jge 1f
    cvtsi2ss xmm1, eax
    subss xmm0, xmm1
    mulss xmm0, [rip + f_256]
    cvtss2si ecx, xmm0
    lea edx, [rax + 1]
    ret
1:  mov eax, r8d
    mov edx, r8d
    ret
2:  xor eax, eax
    xor edx, edx
    ret

# tab_get(bytes) -> scratch table
tab_get:
    push rbx
    mov ebx, edi
    lea rdi, [rip + tab]
    call sb_clear
    lea rdi, [rip + tab]
    mov esi, ebx
    call sb_reserve
    pop rbx
    ret

# scaled() -> the part of the scaled image skey asks for, or 0 without memory
scaled:
    cmp qword ptr [rip + sc_px], 0
    je build_scaled
    lea rdi, [rip + skey]
    lea rsi, [rip + sc_key]
    mov edx, S_SIZE
    call memeq
    test eax, eax
    jz build_scaled
    mov rax, [rip + sc_px]
    ret

# build_scaled() -> pixels or 0: skey's part, bilinear from the smallest halved copy still larger than the scale
build_scaled:
    PROLOGUE 64
    mov qword ptr [rip + sc_key + S_iv], 0
    mov r15, [rip + skey + S_iv]
    mov eax, [r15 + IV_img + IMG_w]
    mov ecx, [r15 + IV_img + IMG_h]
    xor esi, esi
1:  shr eax, 1
    shr ecx, 1
    cmp eax, [rip + skey + S_w]
    jl 2f
    cmp ecx, [rip + skey + S_h]
    jl 2f
    cmp esi, MAXMIP
    jae 2f
    inc esi
    jmp 1b
2:  mov rdi, r15
    call mip
    test rax, rax
    jz .Lbs_fail
    mov [rsp + 32], rax         # source
    mov [rsp + 8], edx          # its w
    mov [rsp + 12], ecx         # its h
    mov eax, [rip + skey + S_cw]
    imul eax, [rip + skey + S_ch]
    cmp rax, [rip + sc_cap]
    jbe 21f
    mov r12, rax
    mov rdi, [rip + sc_px]
    call mem_free
    lea rdi, [r12*4]
    call mem_alloc_try
    mov [rip + sc_px], rax
    mov qword ptr [rip + sc_cap], 0
    test rax, rax
    jz .Lbs_fail
    mov [rip + sc_cap], r12
21: # columns: x0, x1, then the weights as 16-bit lanes: 256 - w four times, w four times
    mov edi, [rip + skey + S_cw]
    shl edi, 5
    call tab_get
    mov r13, rax
    cvtsi2ss xmm0, dword ptr [rsp + 8]
    cvtsi2ss xmm1, dword ptr [rip + skey + S_w]
    divss xmm0, xmm1
    movss [rip + ratio], xmm0
    xor ebx, ebx
3:  cmp ebx, [rip + skey + S_cw]
    jae 4f
    mov eax, ebx
    add eax, [rip + skey + S_x]
    mov edx, [rsp + 8]
    call bilin
    mov r8, rbx
    shl r8, 5
    mov [r13 + r8], eax
    mov [r13 + r8 + 4], edx
    movd xmm1, ecx
    pshuflw xmm1, xmm1, 0
    neg ecx
    add ecx, 256
    movd xmm0, ecx
    pshuflw xmm0, xmm0, 0
    punpcklqdq xmm0, xmm1
    movdqu [r13 + r8 + 16], xmm0
    inc ebx
    jmp 3b
4:  mov eax, [rip + skey + S_cw]
    shl rax, 5
    add rax, r13
    mov [rsp + 40], rax         # table end
    cvtsi2ss xmm0, dword ptr [rsp + 12]
    cvtsi2ss xmm1, dword ptr [rip + skey + S_h]
    divss xmm0, xmm1
    movss [rip + ratio], xmm0
    pxor xmm7, xmm7
    mov eax, 128
    movd xmm4, eax
    pshuflw xmm4, xmm4, 0
    punpcklqdq xmm4, xmm4       # rounding
    mov rdi, [rip + sc_px]
    mov dword ptr [rsp + 16], 0 # row
5:  mov eax, [rsp + 16]
    cmp eax, [rip + skey + S_ch]
    jae 8f
    add eax, [rip + skey + S_y]
    mov edx, [rsp + 12]
    call bilin
    movd xmm5, ecx
    pshuflw xmm5, xmm5, 0
    punpcklqdq xmm5, xmm5       # weight of the lower row
    neg ecx
    add ecx, 256
    movd xmm6, ecx
    pshuflw xmm6, xmm6, 0
    punpcklqdq xmm6, xmm6       # of the upper
    mov ecx, [rsp + 8]
    imul rax, rcx
    imul rdx, rcx
    mov rcx, [rsp + 32]
    lea r14, [rcx + rdx*4]      # lower row
    lea r13, [rcx + rax*4]      # upper row
    mov rsi, [rip + tab + SB_ptr]
    mov r11, [rsp + 40]
6:  # both columns' pixels as 16-bit lanes: rows blended first, then the columns
    mov r8d, [rsi]
    mov r9d, [rsi + 4]
    movd xmm0, [r13 + r8*4]
    movd xmm1, [r13 + r9*4]
    movd xmm2, [r14 + r8*4]
    movd xmm3, [r14 + r9*4]
    punpckldq xmm0, xmm1
    punpckldq xmm2, xmm3
    punpcklbw xmm0, xmm7
    punpcklbw xmm2, xmm7
    pmullw xmm0, xmm6
    pmullw xmm2, xmm5
    paddw xmm0, xmm2
    paddw xmm0, xmm4
    psrlw xmm0, 8
    movdqu xmm1, [rsi + 16]
    pmullw xmm0, xmm1
    pshufd xmm1, xmm0, 0x4e
    paddw xmm0, xmm1
    paddw xmm0, xmm4
    psrlw xmm0, 8
    packuswb xmm0, xmm0
    movd [rdi], xmm0
    add rdi, 4
    add rsi, 32
    cmp rsi, r11
    jb 6b
    inc dword ptr [rsp + 16]
    jmp 5b
8:  lea rdi, [rip + sc_key]
    lea rsi, [rip + skey]
    mov ecx, S_SIZE
    rep movsb
    mov rax, [rip + sc_px]
    EPILOGUE
.Lbs_fail:
    xor eax, eax
    EPILOGUE

# mip(iv, level) -> rax pixels, edx w, ecx h of the image halved level times (made on demand), rax 0 without memory
mip:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov r13, [rbx + IV_img + IMG_px]
    mov r14d, [rbx + IV_img + IMG_w]
    mov r15d, [rbx + IV_img + IMG_h]
    xor r12d, r12d
1:  cmp r12d, [rsp]
    jae 8f
    mov rax, [rbx + IV_mips + r12*8]
    test rax, rax
    jnz 2f
    mov eax, r14d
    shr eax, 1
    mov ecx, 1
    cmp eax, ecx
    cmovl eax, ecx
    mov edx, r15d
    shr edx, 1
    cmp edx, ecx
    cmovl edx, ecx
    imul eax, edx
    lea rdi, [rax*4]
    call mem_alloc_try
    test rax, rax
    jz 9f
    mov [rbx + IV_mips + r12*8], rax
    mov rdi, r13
    mov esi, r14d
    mov edx, r15d
    mov rcx, rax
    call halve
    mov rax, [rbx + IV_mips + r12*8]
2:  mov r13, rax
    shr r14d, 1
    mov eax, 1
    cmp r14d, eax
    cmovl r14d, eax
    shr r15d, 1
    cmp r15d, eax
    cmovl r15d, eax
    inc r12d
    jmp 1b
8:  mov rax, r13
    mov edx, r14d
    mov ecx, r15d
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# halve(src, w, h, dst): 2x2 box average, rounding
halve:
    PROLOGUE 16
    mov r12, rdi
    mov r13d, esi
    mov r14d, edx
    mov r15, rcx
    mov eax, r13d
    shr eax, 1
    mov ecx, 1
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp], eax              # dw
    mov eax, r14d
    shr eax, 1
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 4], eax          # dh
    xor ebx, ebx                # y
1:  cmp ebx, [rsp + 4]
    jae 9f
    lea eax, [rbx + rbx]
    mov ecx, r13d
    imul rax, rcx
    lea rsi, [r12 + rax*4]      # upper source row
    lea eax, [rbx + rbx + 1]
    lea edx, [r14 - 1]
    cmp eax, edx
    cmova eax, edx
    imul rax, rcx
    lea rdi, [r12 + rax*4]      # lower
    lea r11d, [r13 - 1]         # last column
    xor r10d, r10d              # x
2:  cmp r10d, [rsp]
    jae 4f
    lea r8d, [r10 + r10]
    lea r9d, [r10 + r10 + 1]
    cmp r9d, r11d
    cmova r9d, r11d
    mov eax, [rsi + r8*4]
    mov edx, [rsi + r9*4]
    mov ecx, [rdi + r8*4]
    mov r9d, [rdi + r9*4]
    # red and blue
    mov r8d, eax
    and r8d, 0xff00ff
    push rax
    mov eax, edx
    and eax, 0xff00ff
    add r8d, eax
    mov eax, ecx
    and eax, 0xff00ff
    add r8d, eax
    mov eax, r9d
    and eax, 0xff00ff
    add r8d, eax
    add r8d, 0x20002
    shr r8d, 2
    and r8d, 0xff00ff
    pop rax
    # alpha and green
    shr eax, 8
    and eax, 0xff00ff
    shr edx, 8
    and edx, 0xff00ff
    add eax, edx
    shr ecx, 8
    and ecx, 0xff00ff
    add eax, ecx
    shr r9d, 8
    and r9d, 0xff00ff
    add eax, r9d
    add eax, 0x20002
    shl eax, 6
    and eax, 0xff00ff00
    or eax, r8d
    mov [r15], eax
    add r15, 4
    inc r10d
    jmp 2b
4:  inc ebx
    jmp 1b
9:  EPILOGUE

# ---- keys, commands, status ----

# iv_key(iv, keysym, cp, mods) -> 1 when used
FN iv_key
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    xor eax, eax
    cmp dword ptr [rbx + IV_state], IVS_OK
    jne 9f
    test ecx, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz 9f
    cmp r13d, '+'
    je 1f
    cmp r13d, '='
    jne 2f
1:  mov esi, 1
    jmp 5f
2:  cmp r13d, '-'
    je 3f
    cmp r13d, '_'
    jne 4f
3:  mov esi, -1
    jmp 5f
4:  cmp r13d, '0'
    jne 41f
    xor esi, esi
5:  mov rdi, rbx
    call iv_zoom_cmd
    jmp 8f
41: cmp r13d, '1'
    jne 6f
    movss xmm0, [rip + f_one]
    call center_point
    mov rdi, rbx
    call zoom_to
    jmp 8f
6:  # arrows move by an eighth of the view
    xor r14d, r14d              # dx
    xor r15d, r15d              # dy
    mov eax, [rip + view_w]
    sar eax, 3
    mov ecx, [rip + view_h]
    sar ecx, 3
    cmp r12d, KEY_LEFT
    jne 61f
    neg eax
    mov r14d, eax
    jmp 7f
61: cmp r12d, KEY_RIGHT
    jne 62f
    mov r14d, eax
    jmp 7f
62: cmp r12d, KEY_UP
    jne 63f
    neg ecx
    mov r15d, ecx
    jmp 7f
63: cmp r12d, KEY_DOWN
    jne 9f
    mov r15d, ecx
7:  mov rdi, rbx
    call view_scale
    call clamp_center
    cvtsi2ss xmm1, r14d
    divss xmm1, xmm0
    addss xmm1, [rbx + IV_cx]
    movss [rbx + IV_cx], xmm1
    cvtsi2ss xmm1, r15d
    divss xmm1, xmm0
    addss xmm1, [rbx + IV_cy]
    movss [rbx + IV_cy], xmm1
8:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# center_point() -> esi, edx the middle of the view
center_point:
    mov esi, [rip + view_w]
    sar esi, 1
    add esi, [rip + view_x]
    mov edx, [rip + view_h]
    sar edx, 1
    add edx, [rip + view_y]
    ret

# iv_zoom_cmd(iv, dir): 1 zoom in, -1 out, 0 fit
FN iv_zoom_cmd
    cmp dword ptr [rdi + IV_state], IVS_OK
    jne 9f
    test esi, esi
    jnz 1f
    mov dword ptr [rdi + IV_fit], 1
    mov dword ptr [rip + g_dirty], 1
    ret
1:  movss xmm0, [rip + f_step]
    test esi, esi
    jg 2f
    movss xmm0, [rip + f_one]
    divss xmm0, [rip + f_step]
2:  push rdi
    call center_point
    pop rdi
    jmp zoom_step
9:  ret

# zoom_percent(iv) -> eax zoom as last drawn, in percent
zoom_percent:
    movss xmm0, [rdi + IV_scale]
    divss xmm0, [rip + g_s]
    mulss xmm0, [rip + f_100]
    cvtss2si eax, xmm0
    ret

# iv_status(doc, x, y, w, h): dimensions and file size on the left; format and zoom on the right
FN iv_status
    PROLOGUE 48
    mov rbx, [rdi + DOC_img]
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    cmp dword ptr [rbx + IV_state], IVS_OK
    jne 9f
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov esi, [rbx + IV_img + IMG_w]
    call sb_push_u64
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Ltimes]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, [rbx + IV_img + IMG_h]
    call sb_push_u64
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lgap]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rbx + IV_bytes]
    call push_size
    lea rdi, [rip + g_face_small]
    M esi, MI_12
    add esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR eax, T_UI_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    # right side
    mov r12d, [rsp]
    add r12d, [rsp + 8]
    sub r12d, [rip + g_mt + 4*MI_12]
    mov edi, [rbx + IV_img + IMG_fmt]
    call image_format_name
    mov rdi, rax
    call status_item
    # zoom, a click switches between fit and 100%
    lea rdi, [rsp + 16]
    cmp dword ptr [rbx + IV_fit], 0
    je 1f
    lea rsi, [rip + .Lfit]
    call cstr_copy
    mov rdi, rax
1:  push rdi
    push rdi
    mov rdi, rbx
    call zoom_percent
    pop rdi
    pop rdi
    mov esi, eax
    call fmt_u64                # leaves rdi after the digits
    mov byte ptr [rdi], '%'
    mov byte ptr [rdi + 1], 0
    mov r13d, r12d
    lea rdi, [rsp + 16]
    call status_item
    mov esi, r12d
    add esi, [rip + g_mt + 4*MI_12]
    mov ecx, r13d
    sub ecx, esi
    add ecx, [rip + g_mt + 4*MI_8]
    mov edi, ID_IVZOOM
    mov edx, [rsp + 4]
    mov r8d, [rsp + 12]
    call ui_btn
    test eax, UB_HOVER
    jz 2f
    mov dword ptr [rip + g_cursor], CUR_POINTER
2:  test eax, UB_CLICK
    jz 9f
    cmp dword ptr [rbx + IV_fit], 0
    je 3f
    movss xmm0, [rip + f_one]
    call center_point
    mov rdi, rbx
    call zoom_to
    jmp 9f
3:  mov dword ptr [rbx + IV_fit], 1
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# status_item(cstr): right-aligned at r12d, which moves left past it (iv_status's frame: [rsp + 8] y, h)
status_item:
    push rbx
    push r13
    sub rsp, 8
    mov r13, rdi
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r13
    mov rdx, rax
    call text_width
    sub r12d, eax
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, [rsp + 32 + 4]
    mov ecx, [rsp + 32 + 12]
    mov r8, r13
    COLOR r9d, T_UI_MUTED
    call ui_text_c
    sub r12d, [rip + g_mt + 4*MI_20]
    add rsp, 8
    pop r13
    pop rbx
    ret

# push_size(sb, bytes): "812 B", "4.2 KB", "1.3 MB"
push_size:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, 1024
    jae 1f
    mov rsi, r12
    call sb_push_u64
    lea r13, [rip + .Lbytes]
    jmp 8f
1:  lea r13, [rip + .Lkb]
    mov ecx, 10
    cmp r12, 1024 * 1024
    jb 2f
    lea r13, [rip + .Lmb]
    mov ecx, 20
2:  mov rax, r12
    imul rax, rax, 10
    shr rax, cl
    xor edx, edx
    mov ecx, 10
    div rcx
    mov r14, rdx
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    mov esi, '.'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r14
    call sb_push_u64
8:  mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    EPILOGUE

# iv_describe(doc, sb): " image=WxH format=F zoom=Z fit=0|1", " image=error", or " image=pending" before it is shown (print-state)
FN iv_describe
    PROLOGUE
    mov rbx, [rdi + DOC_img]
    mov r12, rsi
    cmp dword ptr [rbx + IV_state], IVS_OK
    je 1f
    lea rsi, [rip + .Ld_error]
    cmp dword ptr [rbx + IV_state], IVS_FAILED
    je 2f
    lea rsi, [rip + .Ld_pending]
2:  mov rdi, r12
    call sb_push_cstr
    EPILOGUE
1:  mov rdi, r12
    lea rsi, [rip + .Ld_image]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + IV_img + IMG_w]
    call sb_push_u64
    mov rdi, r12
    mov esi, 'x'
    call sb_push_byte
    mov rdi, r12
    mov esi, [rbx + IV_img + IMG_h]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_format]
    call sb_push_cstr
    mov edi, [rbx + IV_img + IMG_fmt]
    call image_format_name
    mov rdi, r12
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ld_zoom]
    call sb_push_cstr
    mov rdi, rbx
    call zoom_percent
    mov rdi, r12
    mov esi, eax
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_fit]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + IV_fit]
    call sb_push_u64
    EPILOGUE

.section .rodata
.p2align 2
f_250: .float 250.0
f_256: .float 256.0
f_100: .float 100.0
f_step: .float 1.25
f_zmin: .float 0.0078125
f_zmax: .float 64.0
.Lnot_image: .asciz "The file is not an image rhun can read"
.Lunreadable: .asciz "The file could not be read"
.Lcannot: .asciz "Cannot show this image"
.Ltimes: .asciz " \303\227 "
.Lgap: .asciz "   "
.Lbytes: .asciz " B"
.Lkb: .asciz " KB"
.Lmb: .asciz " MB"
.Lfit: .asciz "Fit "
.Ld_error: .asciz " image=error"
.Ld_pending: .asciz " image=pending"
.Ld_image: .asciz " image="
.Ld_format: .asciz " format="
.Ld_zoom: .asciz " zoom="
.Ld_fit: .asciz " fit="
