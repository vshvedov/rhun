# pictures with the keyboard (feature view-keys) and decoded images by handle (view-images) for
# section 12a's pictures: a tab view, a picture view in a place, a custom editor's view.
#
# view-keys: a picture takes the keyboard when it is pressed (a tab picture through a place item of
# its own, a picture view through its place). Keys no binding takes go to the extension as
# "0 view VIEW key MODS NAME", typed characters also as "text LEN" + UTF-8; the clipboard commands
# reach it: paste as "paste LEN" + text, select_all as "selectall", copy and cut ask "ID vcopy VIEW
# copy|cut" and put the answer on the clipboard (1 s at most). Pointer events gain MODS and
# "dblclick X Y MODS" (extview.s).
#
# view-images: "ID vimage LEN" + PNG, JPEG or GIF -> "ok ID IMG", decoded once (8 MB, 4096 px a side
# at most); "ID unimage IMG". At most 64 handles and 128 MB decoded per extension; they go with it.
#
# Built-in code (custom editors and the like): viewpic_focus(VW*) gives a picture the keyboard;
# viewpic_key(VW*, keysym, cp, mods) and viewpic_paste(VW*, ptr, len) route input to it.
.include "rhun.inc"

.equ VI_MAX, 256
.equ VI_PER_EXT, 64
.equ VI_BYTES_EXT, 134217728
.equ VI_SIDE_MAX, 4096
.equ VCOPY_MS, 1000

# a decoded image
STRUCT
F VI_ext, 8             # its extension, 0 when free
F VI_px, 8              # premultiplied ARGB
F VI_w, 4
F VI_h, 4
F VI_id, 4
F VI_pad, 4
ENDSTRUCT VI_SIZE

.bss
.p2align 3
vis: .zero VI_SIZE * VI_MAX
vb_tmp: .zero VI_SIZE           # viewimg_blit_img's image as a VI
.globl vimg_gen
vimg_gen: .long 0               # an image went: static pictures render again
vi_seq: .long 0
.p2align 3
vc_ext: .quad 0                 # the vcopy waiting for its answer: its extension, id, when, cut
vc_id: .quad 0
vc_sent: .quad 0
vc_cut: .long 0
.p2align 3
img_tmp: .zero IMG_SIZE
nbuf: .zero 32
tbuf: .zero 8

.text

# ---------------- images ----------------

# viewimg_find(ext, id) -> rax VI* of that extension's image, or 0
FN viewimg_find
    xor ecx, ecx
    lea rax, [rip + vis]
1:  cmp ecx, VI_MAX
    jae 8f
    cmp [rax + VI_ext], rdi
    jne 2f
    test rdi, rdi
    jz 2f
    cmp [rax + VI_id], esi
    je 9f
2:  add rax, VI_SIZE
    inc ecx
    jmp 1b
8:  xor eax, eax
9:  ret

# viewimg_request(ext, ptr, len) -> rax its IMG, -1 not a PNG, JPEG or GIF it can decode (or past
#   4096 px a side), -2 when the extension has 64 or 128 MB decoded
FN viewimg_request
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    # its handles and bytes, and a free slot
    xor r14d, r14d              # handles
    xor r15d, r15d              # bytes
    mov qword ptr [rip + tbuf], 0
    xor ecx, ecx
    lea rax, [rip + vis]
1:  cmp ecx, VI_MAX
    jae 3f
    cmp qword ptr [rax + VI_ext], 0
    jne 2f
    cmp qword ptr [rip + tbuf], 0
    jne 21f
    mov [rip + tbuf], rax
    jmp 21f
2:  cmp [rax + VI_ext], rbx
    jne 21f
    inc r14d
    mov edx, [rax + VI_w]
    imul edx, [rax + VI_h]
    shl rdx, 2
    add r15, rdx
21: add rax, VI_SIZE
    inc ecx
    jmp 1b
3:  cmp r14d, VI_PER_EXT
    jae 6f
    cmp qword ptr [rip + tbuf], 0
    je 6f
    # PNG, JPEG or GIF only
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    call image_sniff
    cmp eax, IMF_PNG
    je 4f
    cmp eax, IMF_JPEG
    je 4f
    cmp eax, IMF_GIF
    jne 7f
4:  mov rdi, r12
    mov rsi, r13
    mov edx, eax
    lea rcx, [rip + img_tmp]
    call image_decode
    test eax, eax
    jnz 7f
    mov eax, [rip + img_tmp + IMG_w]
    mov ecx, [rip + img_tmp + IMG_h]
    cmp eax, VI_SIDE_MAX
    ja 5f
    cmp ecx, VI_SIDE_MAX
    ja 5f
    imul rax, rcx
    shl rax, 2
    add rax, r15
    cmp rax, VI_BYTES_EXT
    ja 51f
    mov rax, [rip + tbuf]
    mov [rax + VI_ext], rbx
    mov rcx, [rip + img_tmp + IMG_px]
    mov [rax + VI_px], rcx
    mov ecx, [rip + img_tmp + IMG_w]
    mov [rax + VI_w], ecx
    mov ecx, [rip + img_tmp + IMG_h]
    mov [rax + VI_h], ecx
    inc dword ptr [rip + vi_seq]
    mov ecx, [rip + vi_seq]
    mov [rax + VI_id], ecx
    mov eax, ecx
    EPILOGUE
5:  lea rdi, [rip + img_tmp]
    call image_free
7:  mov rax, -1
    EPILOGUE
51: lea rdi, [rip + img_tmp]
    call image_free
6:  mov rax, -2
    EPILOGUE

# vi_free(VI*): its pixels, the slot free; pictures showing it render again
vi_free:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + VI_px]
    call mem_free
    mov qword ptr [rbx + VI_ext], 0
    mov qword ptr [rbx + VI_px], 0
    call views_redraw
    pop rbx
    ret

# viewimg_unimage(ext, id) -> eax 0, 1 when it has no such image
FN viewimg_unimage
    call viewimg_find
    test rax, rax
    jz 1f
    mov rdi, rax
    call vi_free
    xor eax, eax
    ret
1:  mov eax, 1
    ret

# viewimg_owner_gone(ext): its images go
FN viewimg_owner_gone
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp ebx, VI_MAX
    jae 9f
    imul rdi, rbx, VI_SIZE
    lea rax, [rip + vis]
    add rdi, rax
    cmp [rdi + VI_ext], r12
    jne 2f
    call vi_free
2:  inc ebx
    jmp 1b
9:  cmp qword ptr [rip + vc_ext], r12
    jne 91f
    mov qword ptr [rip + vc_ext], 0
91: EPILOGUE

# views_redraw(): every picture renders again (an image went)
views_redraw:
    inc dword ptr [rip + vimg_gen]  # static pictures (extview.s pic_draw)
    xor ecx, ecx
    lea rax, [rip + g_views]
1:  cmp ecx, VW_MAX
    jae 9f
    mov dword ptr [rax + VW_dirty], 1
    add rax, VW_SIZE
    inc ecx
    jmp 1b
9:  mov dword ptr [rip + g_dirty], 1
    ret

# viewimg_size(ext, id) -> eax its width, edx its height; 0, 0 when the extension has no such image
FN viewimg_size
    sub rsp, 8
    call viewimg_find
    add rsp, 8
    test rax, rax
    jz 8f
    mov edx, [rax + VI_h]
    mov eax, [rax + VI_w]
    ret
8:  xor eax, eax
    xor edx, edx
    ret

# viewimg_blit_id(x, y, w, h, ext, id): that extension's image drawn so, when it has it
FN viewimg_blit_id
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov rdi, r8
    mov esi, r9d
    call viewimg_find
    test rax, rax
    jz 9f
    mov r8, rax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call viewimg_blit
9:  EPILOGUE

# viewimg_blit_img(x, y, w, h, IMG*): a decoded image (image.s) drawn so
FN viewimg_blit_img
    mov rax, [r8 + IMG_px]
    mov [rip + vb_tmp + VI_px], rax
    mov eax, [r8 + IMG_w]
    mov [rip + vb_tmp + VI_w], eax
    mov eax, [r8 + IMG_h]
    mov [rip + vb_tmp + VI_h], eax
    lea r8, [rip + vb_tmp]
    jmp viewimg_blit

# viewimg_blit(x, y, w, h, VI*): the image scaled into the box (nearest pixel) over the canvas,
#   within its clip
FN viewimg_blit
    PROLOGUE 48
    mov [rsp], edi              # x
    mov [rsp + 4], esi          # y
    mov [rsp + 8], edx          # w
    mov [rsp + 12], ecx         # h
    mov r15, r8
    cmp qword ptr [r15 + VI_px], 0
    je 9f
    # rows within the clip
    mov eax, [rsp + 4]
    mov ecx, [rip + g_cv + CV_cy0]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 16], eax         # y0
    mov eax, [rsp + 4]
    add eax, [rsp + 12]
    mov ecx, [rip + g_cv + CV_cy1]
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 20], eax         # y1
    mov eax, [rsp]
    mov ecx, [rip + g_cv + CV_cx0]
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 24], eax         # x0
    mov eax, [rsp]
    add eax, [rsp + 8]
    mov ecx, [rip + g_cv + CV_cx1]
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 28], eax         # x1
    mov ebx, [rsp + 16]
.Lvb_row:
    cmp ebx, [rsp + 20]
    jge 9f
    # the source row: (y - top) * h_src / h
    mov eax, ebx
    sub eax, [rsp + 4]
    imul eax, [r15 + VI_h]
    xor edx, edx
    div dword ptr [rsp + 12]
    imul eax, [r15 + VI_w]
    mov r12, [r15 + VI_px]
    lea r12, [r12 + rax*4]      # the source row
    mov eax, ebx                # the canvas row
    imul eax, [rip + g_cv + CV_stride]
    mov r13, [rip + g_cv + CV_pixels]
    lea r13, [r13 + rax*4]
    mov r14d, [rsp + 24]
.Lvb_px:
    cmp r14d, [rsp + 28]
    jge .Lvb_next
    mov eax, r14d
    sub eax, [rsp]
    imul eax, [r15 + VI_w]
    xor edx, edx
    div dword ptr [rsp + 8]
    mov esi, [r12 + rax*4]      # the source pixel, premultiplied
    mov eax, esi
    shr eax, 24
    jz 3f                       # transparent
    cmp eax, 255
    jne 1f
    mov [r13 + r14*4], esi
    jmp 3f
1:  # over: d = s + d * (255 - a) / 255, per channel
    mov r10d, 255
    sub r10d, eax
    mov edi, [r13 + r14*4]
    xor r8d, r8d                # the result
    xor ecx, ecx                # the shift
2:  mov eax, edi
    shr eax, cl
    and eax, 255
    imul eax, r10d
    add eax, 127
    mov edx, eax
    shr edx, 8
    add eax, edx
    shr eax, 8                  # d * (255 - a) / 255
    mov edx, esi
    shr edx, cl
    and edx, 255
    add eax, edx
    cmp eax, 255
    jbe 21f
    mov eax, 255
21: shl eax, cl
    or r8d, eax
    add ecx, 8
    cmp ecx, 32
    jb 2b
    mov [r13 + r14*4], r8d
3:  inc r14d
    jmp .Lvb_px
.Lvb_next:
    inc ebx
    jmp .Lvb_row
9:  EPILOGUE

# ---------------- the keyboard ----------------

# viewpic_push_mods(sb, mods): "-" or ctrl+shift+alt+super as [keys] writes them
FN viewpic_push_mods
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    and r12d, MOD_CTRL | MOD_SHIFT | MOD_ALT | MOD_SUPER
    jnz 1f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    EPILOGUE
1:  xor r13d, r13d              # one written
    lea r14, [rip + mod_words]
2:  mov eax, [r14]
    test eax, eax
    jz 9f
    test r12d, eax
    jz 3f
    test r13d, r13d
    jz 21f
    mov rdi, rbx
    mov esi, '+'
    call sb_push_byte
21: mov rdi, rbx
    mov rsi, [r14 + 8]
    call sb_push_cstr
    mov r13d, 1
3:  add r14, 16
    jmp 2b
9:  EPILOGUE

# key_name(keysym) -> rax cstr ("Return", "a", "F5"), 0 for a key it does not name (a modifier)
key_name:
    cmp edi, KEY_SHIFT_L
    jb 1f
    cmp edi, KEY_SUPER_R
    jbe 8f                      # modifiers alone are not keys
1:  lea rcx, [rip + key_words]
2:  mov eax, [rcx]
    test eax, eax
    jz 3f
    cmp eax, edi
    je 4f
    add rcx, 16
    jmp 2b
4:  mov rax, [rcx + 8]
    ret
3:  mov eax, edi                # F1 .. F12
    sub eax, KEY_F1
    cmp eax, 12
    jb 5f
    cmp edi, 0x21               # printable ASCII: itself, letters lowercase
    jb 8f
    cmp edi, 0x7e
    ja 8f
    mov eax, edi
    cmp eax, 'A'
    jb 6f
    cmp eax, 'Z'
    ja 6f
    add eax, 32
6:  mov [rip + nbuf], al
    mov byte ptr [rip + nbuf + 1], 0
    lea rax, [rip + nbuf]
    ret
5:  mov byte ptr [rip + nbuf], 'F'
    inc eax
    cmp eax, 10
    jb 7f
    mov byte ptr [rip + nbuf + 1], '1'
    sub eax, 10
    add eax, '0'
    mov [rip + nbuf + 2], al
    mov byte ptr [rip + nbuf + 3], 0
    lea rax, [rip + nbuf]
    ret
7:  add eax, '0'
    mov [rip + nbuf + 1], al
    mov byte ptr [rip + nbuf + 2], 0
    lea rax, [rip + nbuf]
    ret
8:  xor eax, eax
    ret

# keys_on(VW*) -> eax 1 when its extension runs and agreed view-keys
keys_on:
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rcx, [rdi + VW_ext]
    test rcx, rcx
    jz 9f
    cmp dword ptr [rcx + EXT_status], ES_RUNNING
    jne 9f
    FEAT_TEST rcx, FEAT_VIEW_KEYS
    setnz al
    movzx eax, al
9:  ret

# Paired key releases for a focused picture. No global keyboard access.
FN viewpic_key_up
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    call views_focused_picture
    mov rbx, rax
    mov rdi, rax
    call keys_on
    test eax, eax
    jz 9f
    mov rcx, [rbx + VW_ext]
    FEAT_TEST rcx, FEAT_VIEW_KEY_STATE
    jz 9f
    mov edi, r12d
    call key_name
    test rax, rax
    jz 9f
    mov r14, rax
    mov rdi, rbx
    call extview_event_head
    test eax, eax
    jz 9f
    call extview_evbuf
    mov rdi, rax
    lea rsi, [rip + .Le_key_up]
    call sb_push_cstr
    call extview_evbuf
    mov rdi, rax
    mov esi, r13d
    call viewpic_push_mods
    call extview_evbuf
    mov rdi, rax
    mov esi, ' '
    call sb_push_byte
    call extview_evbuf
    mov rdi, rax
    mov rsi, r14
    call sb_push_cstr
    mov rdi, rbx
    call extview_event_send
9:  EPILOGUE

FN viewpic_modifiers
    PROLOGUE
    mov r12d, edi
    call views_focused_picture
    mov rbx, rax
    mov rdi, rax
    call keys_on
    test eax, eax
    jz 9f
    mov rcx, [rbx + VW_ext]
    FEAT_TEST rcx, FEAT_VIEW_KEY_STATE
    jz 9f
    mov rdi, rbx
    call extview_event_head
    test eax, eax
    jz 9f
    call extview_evbuf
    mov rdi, rax
    lea rsi, [rip + .Le_modifiers]
    call sb_push_cstr
    call extview_evbuf
    mov rdi, rax
    mov esi, r12d
    call viewpic_push_mods
    mov rdi, rbx
    call extview_event_send
9:  EPILOGUE

FN viewpic_window_focus
    PROLOGUE
    mov r12d, edi
    call views_focused_picture
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rbx
    call keys_on
    test eax, eax
    jz 9f
    mov rcx, [rbx + VW_ext]
    FEAT_TEST rcx, FEAT_VIEW_KEY_STATE
    jz 9f
    mov rdi, rbx
    mov esi, r12d
    call viewpic_focus_event
9:  EPILOGUE

# viewpic_key(VW*, keysym, cp, mods) -> eax 1 when the picture took the key: keys a binding takes
#   are left to it, except copy, cut and select_all, which reach the picture
FN viewpic_key
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    call keys_on
    test eax, eax
    jz 8f
    mov edi, r12d               # a key a binding takes: the binding runs (copy, cut, select_all and
    mov esi, r14d               # paste reach the picture through their commands, chords too)
    call keys_lookup
    test rax, rax
    jnz 8f
    # "key MODS NAME"
    mov edi, r12d
    call key_name
    test rax, rax
    jz 2f
    mov r15, rax
    mov rdi, rbx
    call extview_event_head
    test eax, eax
    jz 7f
    call extview_evbuf
    mov rdi, rax
    lea rsi, [rip + .Le_key]
    call sb_push_cstr
    call extview_evbuf
    mov rdi, rax
    mov esi, r14d
    call viewpic_push_mods
    call extview_evbuf
    mov rdi, rax
    mov esi, ' '
    call sb_push_byte
    call extview_evbuf
    mov rdi, rax
    mov rsi, r15
    call sb_push_cstr
    mov rdi, rbx
    call extview_event_send
2:  # a typed character: "text LEN" + UTF-8
    cmp r13d, 0x20
    jb 7f
    cmp r13d, 0x7f
    je 7f
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz 7f
    mov edi, r13d
    lea rsi, [rip + tbuf]
    call utf8_encode
    mov rsi, rax
    mov rdi, rbx
    lea rdx, [rip + tbuf]
    lea rcx, [rip + .Le_text]
    call send_body_event
7:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# send_body_event(VW*, len, ptr, what cstr): "0 view VIEW WHAT LEN" LF + the bytes
send_body_event:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    call extview_event_head
    test eax, eax
    jz 9f
    call extview_evbuf
    mov r15, rax
    mov rdi, r15
    mov rsi, r14
    call sb_push_cstr
    mov rdi, r15
    mov rsi, r12
    call sb_push_u64
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    mov rdi, r15
    mov rsi, r13
    mov rdx, r12
    call sb_push
    mov rdi, [rbx + VW_ext]
    mov rsi, [r15 + SB_ptr]
    mov rdx, [r15 + SB_len]
    call ext_send
9:  EPILOGUE

# viewpic_paste(VW*, ptr, len) -> eax 1 when the picture took the paste ("paste LEN" + text)
FN viewpic_paste
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call keys_on
    test eax, eax
    jz 9f
    mov rdi, r13                # at most 4 MB, whole characters (an extension reads no more)
    mov rsi, r12
    mov edx, 4194304
    call utf8_cut
    mov r13, rax
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r12
    lea rcx, [rip + .Le_paste]
    call send_body_event
    mov eax, 1
9:  EPILOGUE

# send_vcopy(VW*, cut): "ID vcopy VIEW copy|cut"; the answer goes to the clipboard
send_vcopy:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, [rbx + VW_ext]
    cmp qword ptr [r13 + EXT_hreq], 2147483647
    jae 9f
    inc qword ptr [r13 + EXT_hreq]
    mov r14, [r13 + EXT_hreq]
    mov [rip + vc_ext], r13
    mov [rip + vc_id], r14
    mov [rip + vc_cut], r12d
    call time_ms
    mov [rip + vc_sent], rax
    call extview_evbuf
    mov r15, rax
    mov rdi, r15
    call sb_clear
    mov rdi, r15
    mov rsi, r14
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lq_vcopy]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + VW_id]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lq_copy]
    test r12d, r12d
    jz 1f
    lea rsi, [rip + .Lq_cut]
1:  call sb_push_cstr
    mov rdi, r13
    mov rsi, [r15 + SB_ptr]
    mov rdx, [r15 + SB_len]
    call ext_send
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lq_vcopy + 1]
    mov ecx, 5
    call extres_req_sent
9:  EPILOGUE

# viewpic_reply(ext, id, ok, body, len) -> eax 1 when it answers the vcopy: within 1 s its text goes
#   to the clipboard (empty: the clipboard stays)
FN viewpic_reply
    xor eax, eax
    cmp [rip + vc_ext], rdi
    jne 9f
    test rdi, rdi
    jz 9f
    cmp [rip + vc_id], rsi
    jne 9f
    PROLOGUE
    mov qword ptr [rip + vc_ext], 0
    mov ebx, edx
    mov r12, rcx
    mov r13, r8
    test ebx, ebx
    jz 8f
    test r13, r13
    jz 8f
    call time_ms
    sub rax, [rip + vc_sent]
    cmp rax, VCOPY_MS
    ja 8f
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    call ed_clip_set
    call editor_clip_result
8:  mov eax, 1
    EPILOGUE
9:  ret

# ---------------- focus ----------------

# viewpic_pressed(VW*): a press on the picture: with view-keys it takes the keyboard (a picture
#   view's place gives it already)
FN viewpic_pressed
    PROLOGUE
    mov rbx, rdi
    call keys_on
    test eax, eax
    jz 9f
    cmp dword ptr [rbx + VW_inplace], 1
    je 9f
    mov rdi, rbx
    call viewpic_focus
9:  EPILOGUE

# viewpic_focus(VW*): the keyboard to a tab's picture, through a place item of its own (made once)
FN viewpic_focus
    PROLOGUE
    mov rbx, rdi
    mov eax, [rbx + VW_pl]
    test eax, eax
    jnz 1f
    lea rax, [rip + g_views]    # its slot is the item's context
    mov rcx, rbx
    sub rcx, rax
    mov rax, rcx
    xor edx, edx
    mov ecx, VW_SIZE
    div rcx
    mov r8, rax
    mov edi, PLACE_TAB
    lea rsi, [rip + .Lpl_name]
    mov rdx, [rbx + VW_title]
    lea rcx, [rip + pic_tab_ops]
    call place_add
    cmp eax, -1
    je 9f
    inc eax
    mov [rbx + VW_pl], eax
1:  lea edi, [rax - 1]
    call place_focus
9:  EPILOGUE

# slot_vw(slot) -> rax VW*
slot_vw:
    imul rax, rdi, VW_SIZE
    lea rcx, [rip + g_views]
    add rax, rcx
    ret

# pt_key(slot, keysym, cp, mods), pt_focus(slot, on): a tab picture's place item
pt_key:
    push rsi
    push rdx
    push rcx
    call slot_vw
    pop rcx
    pop rdx
    pop rsi
    mov rdi, rax
    jmp viewpic_key

pt_focus:
    PROLOGUE
    mov r12d, esi
    call slot_vw
    mov rdi, rax
    mov esi, r12d
    call viewpic_focus_event
    EPILOGUE

# viewpic_focus_event(VW*, on): "focus 0|1" with view-keys
FN viewpic_focus_event
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call keys_on
    test eax, eax
    jz 9f
    mov rdi, rbx
    call extview_event_head
    test eax, eax
    jz 9f
    call extview_evbuf
    mov rdi, rax
    lea rsi, [rip + .Le_focus]
    call sb_push_cstr
    call extview_evbuf
    mov rdi, rax
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    call extview_event_send
9:  EPILOGUE

# views_focused_picture() -> rax the picture with the keyboard (a tab's or a picture view's), or 0
FN views_focused_picture
    PROLOGUE
    call place_focused
    cmp eax, -1
    je 8f
    mov ebx, eax
    mov edi, eax
    call place_at
    test rax, rax
    jz 8f
    lea rcx, [rip + pic_tab_ops]
    cmp [rax + PL_ops], rcx
    jne 1f
    mov rdi, [rax + PL_ctx]
    call slot_vw
    EPILOGUE
1:  mov edi, ebx
    call rview_picture_of_place
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# views_paste_target() -> rax the picture with the keyboard that takes pastes (view-keys), or 0
#   (clippaste.s: a paste's destination)
FN views_paste_target
    PROLOGUE
    call views_focused_picture
    mov rbx, rax
    mov rdi, rax
    call keys_on
    test eax, eax
    jz 8f
    mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# views_clip_command(kind) -> eax 1 when a view took the command (cmd_copy, cmd_cut, cmd_select_all:
#   keys and chords alike): a doc view with the keyboard copies its selected text or selects it
#   all; Copy with the pointer over a notification's selected Markdown copies that; a picture with
#   the keyboard is asked (0 copy and 1 cut: vcopy; 2 select_all: selectall)
FN views_clip_command
    PROLOGUE
    mov r12d, edi
    call mdtab_clip             # plan review: the active Markdown tab's selection (mdtab.s)
    test eax, eax
    jnz 9f
    mov edi, r12d
    call rview_focused_doc      # a doc view: its selected text, or all of it selected
    test rax, rax
    jz 2f
    mov rdi, rax
    mov esi, r12d
    call mdview_clip
    jmp 9f
2:  test r12d, r12d             # Copy with the pointer over a notification's selected text
    jnz 3f
    call notify_copy_selection
    test eax, eax
    jnz 9f
3:  call views_paste_target
    test rax, rax
    jz 8f
    mov rbx, rax
    cmp r12d, 2
    je 1f
    mov rdi, rbx
    mov esi, r12d
    call send_vcopy
    jmp 9f
1:  mov rdi, rbx
    call extview_event_head
    test eax, eax
    jz 9f
    call extview_evbuf
    mov rdi, rax
    lea rsi, [rip + .Le_selectall]
    call sb_push_cstr
    mov rdi, rbx
    call extview_event_send
9:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# views_paste(ptr, len) -> eax 1 when a picture or a form field with the keyboard took the paste
#   (app_on_paste)
FN views_paste
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call rview_focused_form
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call form_paste
    test eax, eax
    jnz 9f
1:  call views_focused_picture
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call viewpic_paste
9:  EPILOGUE

# views_features_agreed(ext): after hello: the views group's features only with what they need
#   (view-log with view-tree; view-keys with views; view-images with views or view-doc)
FN views_features_agreed
    FEAT_TEST rdi, FEAT_VIEW_TREE
    jnz 1f
    FEAT_CLEAR rdi, FEAT_VIEW_LOG
    FEAT_CLEAR rdi, FEAT_VIEW_FORM
    FEAT_CLEAR rdi, FEAT_VIEW_TABLE
    FEAT_CLEAR rdi, FEAT_VIEW_DOC
1:  FEAT_TEST rdi, FEAT_VIEWS
    jnz 2f
    FEAT_CLEAR rdi, FEAT_VIEW_KEYS
    FEAT_CLEAR rdi, FEAT_VIEW_IMAGES
2:  FEAT_TEST rdi, FEAT_VIEW_KEYS
    jnz 3f
    FEAT_CLEAR rdi, FEAT_VIEW_KEY_STATE
3:  cmp dword ptr [rip + g_view_key_state_available], 0
    jne 4f
    FEAT_CLEAR rdi, FEAT_VIEW_KEY_STATE
4:  ret

.data
.globl g_view_key_state_available
g_view_key_state_available: .long 1  # headless, macOS, Wayland and Windows have paired releases

.section .rodata
.Le_key_up: .asciz "key-up "
.Le_modifiers: .asciz "mods "
.Le_key: .asciz "key "
.Le_text: .asciz "text "
.Le_paste: .asciz "paste "
.Le_selectall: .asciz "selectall"
.Le_focus: .asciz "focus "
.Lq_vcopy: .asciz " vcopy "
.Lq_copy: .asciz " copy\n"
.Lq_cut: .asciz " cut\n"
.Lpl_name: .asciz "picture"
.Lm_ctrl: .asciz "ctrl"
.Lm_shift: .asciz "shift"
.Lm_alt: .asciz "alt"
.Lm_super: .asciz "super"
.Lk_return: .asciz "Return"
.Lk_tab: .asciz "Tab"
.Lk_escape: .asciz "Escape"
.Lk_bs: .asciz "Backspace"
.Lk_delete: .asciz "Delete"
.Lk_up: .asciz "Up"
.Lk_down: .asciz "Down"
.Lk_left: .asciz "Left"
.Lk_right: .asciz "Right"
.Lk_home: .asciz "Home"
.Lk_end: .asciz "End"
.Lk_pgup: .asciz "PageUp"
.Lk_pgdn: .asciz "PageDown"
.Lk_insert: .asciz "Insert"
.Lk_space: .asciz "Space"
.p2align 3
mod_words: .quad MOD_CTRL, .Lm_ctrl, MOD_SHIFT, .Lm_shift, MOD_ALT, .Lm_alt, MOD_SUPER, .Lm_super, 0, 0
key_words:
    .quad KEY_RETURN, .Lk_return, KEY_KP_ENTER, .Lk_return, KEY_TAB, .Lk_tab
    .quad KEY_ISO_LEFT_TAB, .Lk_tab, KEY_ESCAPE, .Lk_escape, KEY_BACKSPACE, .Lk_bs
    .quad KEY_DELETE, .Lk_delete, KEY_UP, .Lk_up, KEY_DOWN, .Lk_down, KEY_LEFT, .Lk_left
    .quad KEY_RIGHT, .Lk_right, KEY_HOME, .Lk_home, KEY_END, .Lk_end, KEY_PAGEUP, .Lk_pgup
    .quad KEY_PAGEDOWN, .Lk_pgdn, KEY_INSERT, .Lk_insert, ' ', .Lk_space, 0, 0
pic_tab_ops: .quad 0, pt_key, pt_focus, 0, 0, 0
