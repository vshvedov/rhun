# extension icons: the manifest's icon, a PNG in the extension's folder, read the first time a badge
# needs it (at most ICON_MAXBYTES, at most ICON_MAXDIM pixels a side, checked in its header before
# anything is decoded), then kept at up to ICON_SLOTS sizes: scaled by averaging the source pixels
# each badge pixel covers, centered when it is not square, its corners rounded as the badge's are.
# A badge draws a kept copy; an icon that cannot be shown leaves the letter in its place.
.include "rhun.inc"

.bss
.p2align 3
ic_path: .zero SB_SIZE

.text

# ext_icon(ext, size) -> premultiplied ARGB, size x size, or 0 (no icon, or it cannot be shown)
FN ext_icon
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp qword ptr [rbx + EXT_icon], 0
    je 8f
    lea eax, [r12 - 1]
    cmp eax, 1023               # a badge between 1 and 1024 pixels
    ja 8f
    mov eax, [rbx + EXT_icon_state]
    cmp eax, 2
    je 8f
    cmp eax, 1
    je 1f
    mov rdi, rbx
    call icon_read
    cmp dword ptr [rbx + EXT_icon_state], 1
    jne 8f
1:  # a kept copy at this size
    xor ecx, ecx
2:  cmp [rbx + EXT_icon_sz + rcx*4], r12d
    jne 3f
    mov rax, [rbx + EXT_icon_px + rcx*8]
    test rax, rax
    jnz 9f
3:  inc ecx
    cmp ecx, ICON_SLOTS
    jb 2b
    # a new one, in the next slot
    mov r13d, [rbx + EXT_icon_next]
    lea eax, [r13 + 1]
    xor edx, edx
    mov ecx, ICON_SLOTS
    div ecx
    mov [rbx + EXT_icon_next], edx
    mov rdi, [rbx + EXT_icon_px + r13*8]
    call mem_free
    mov qword ptr [rbx + EXT_icon_px + r13*8], 0
    mov dword ptr [rbx + EXT_icon_sz + r13*4], 0
    lea rdi, [rbx + EXT_icon_img]
    mov esi, r12d
    call icon_scale
    test rax, rax
    jz 8f
    mov [rbx + EXT_icon_px + r13*8], rax
    mov [rbx + EXT_icon_sz + r13*4], r12d
    jmp 9f
8:  xor eax, eax
9:  EPILOGUE

# ext_icon_state(ext) -> 0 no icon, 1 shown, 2 cannot be shown (reads it if it was not yet)
FN ext_icon_state
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    cmp qword ptr [rbx + EXT_icon], 0
    je 9f
    cmp dword ptr [rbx + EXT_icon_state], 0
    jne 1f
    mov rdi, rbx
    call icon_read
1:  mov eax, [rbx + EXT_icon_state]
9:  EPILOGUE

# ext_icon_free(ext): its decoded icon and the kept copies go
FN ext_icon_free
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rbx + EXT_icon_img]
    call image_free
    xor r12d, r12d
1:  mov rdi, [rbx + EXT_icon_px + r12*8]
    call mem_free
    mov qword ptr [rbx + EXT_icon_px + r12*8], 0
    mov dword ptr [rbx + EXT_icon_sz + r12*4], 0
    inc r12d
    cmp r12d, ICON_SLOTS
    jb 1b
    mov dword ptr [rbx + EXT_icon_state], 0
    EPILOGUE

# icon_read(ext): EXT_icon_state 1 with EXT_icon_img decoded, or 2
icon_read:
    PROLOGUE
    mov rbx, rdi
    mov dword ptr [rbx + EXT_icon_state], 2
    # a path inside the extension's folder: relative, without .., a drive or backslashes
    mov rsi, [rbx + EXT_icon]
    cmp byte ptr [rsi], 0
    je 9f
    cmp byte ptr [rsi], '/'
    je 9f
    mov rdi, rsi
1:  movzx eax, byte ptr [rdi]
    test eax, eax
    jz 3f
    cmp eax, 92
    je 9f
    cmp eax, ':'
    je 9f
    cmp eax, '.'
    jne 2f
    cmp byte ptr [rdi + 1], '.'
    je 9f
2:  inc rdi
    jmp 1b
3:  lea rdi, [rip + ic_path]
    call sb_clear
    lea rdi, [rip + ic_path]
    mov rsi, [rbx + EXT_dir]
    call sb_push_cstr
    lea rdi, [rip + ic_path]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + ic_path]
    mov rsi, [rbx + EXT_icon]
    call sb_push_cstr
    lea rdi, [rip + ic_path]
    xor esi, esi
    call sb_push_byte
    # its size, before anything is read
    mov rdi, [rip + ic_path + SB_ptr]
    call file_open_read
    test rax, rax
    js 9f
    mov r12d, eax               # fd
    mov edi, eax
    call file_size
    mov r13, rax
    test rax, rax
    jle 7f
    cmp rax, ICON_MAXBYTES
    ja 7f
    mov rdi, rax
    call mem_alloc
    mov r14, rax
    xor r15d, r15d              # read so far
4:  cmp r15, r13
    jae 5f
    mov edi, r12d
    lea rsi, [r14 + r15]
    mov rdx, r13
    sub rdx, r15
    SYS SYS_read
    cmp rax, -EINTR
    je 4b
    test rax, rax
    jle 6f
    add r15, rax
    jmp 4b
5:  mov edi, r12d
    SYS SYS_close
    # a PNG whose header says at most ICON_MAXDIM pixels a side
    cmp r13, 24
    jb 61f
    mov rax, 0x0a1a0a0d474e5089
    cmp [r14], rax
    jne 61f
    cmp dword ptr [r14 + 12], 0x52444849   # "IHDR"
    jne 61f
    mov eax, [r14 + 16]
    bswap eax
    lea ecx, [rax - 1]
    cmp ecx, ICON_MAXDIM - 1
    ja 61f
    mov eax, [r14 + 20]
    bswap eax
    lea ecx, [rax - 1]
    cmp ecx, ICON_MAXDIM - 1
    ja 61f
    mov rdi, r14
    mov rsi, r13
    mov edx, IMF_PNG
    lea rcx, [rbx + EXT_icon_img]
    call image_decode
    test eax, eax
    jnz 61f
    mov dword ptr [rbx + EXT_icon_state], 1
61: mov rdi, r14
    call mem_free
    jmp 9f
6:  mov rdi, r14
    call mem_free
7:  mov edi, r12d
    SYS SYS_close
9:  EPILOGUE

# icon_scale(IMG*, size) -> size x size premultiplied ARGB (mem_alloc'd), or 0: the image fitted
# and centered, each pixel the average of the source pixels it covers, corners rounded
icon_scale:
    PROLOGUE 64
    mov rbx, rdi
    mov [rsp], esi              # size
    mov eax, esi
    imul eax, esi
    shl eax, 2
    mov [rsp + 4], eax          # bytes
    mov edi, eax
    call mem_alloc
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    xor esi, esi
    mov edx, [rsp + 4]
    call memset
    # the fitted size dw x dh and its offset
    mov eax, [rbx + IMG_w]
    mov ecx, [rbx + IMG_h]
    mov edx, [rsp]
    mov [rsp + 8], edx          # dw
    mov [rsp + 12], edx         # dh
    cmp eax, ecx
    je 2f
    jb 1f
    # wider: dh = size * h / w
    mov eax, edx
    imul eax, [rbx + IMG_h]
    xor edx, edx
    div dword ptr [rbx + IMG_w]
    test eax, eax
    jnz 11f
    inc eax
11: mov [rsp + 12], eax
    jmp 2f
1:  # taller: dw = size * w / h
    mov eax, edx
    imul eax, [rbx + IMG_w]
    xor edx, edx
    div dword ptr [rbx + IMG_h]
    test eax, eax
    jnz 12f
    inc eax
12: mov [rsp + 8], eax
2:  mov eax, [rsp]
    sub eax, [rsp + 8]
    shr eax, 1
    mov [rsp + 16], eax         # ox
    mov eax, [rsp]
    sub eax, [rsp + 12]
    shr eax, 1
    mov [rsp + 20], eax         # oy
    mov dword ptr [rsp + 24], 0 # dy
.Lis_row:
    mov eax, [rsp + 24]
    cmp eax, [rsp + 12]
    jae .Lis_round
    # source rows y0 .. y1
    imul eax, [rbx + IMG_h]
    xor edx, edx
    div dword ptr [rsp + 12]
    mov [rsp + 28], eax         # y0
    mov eax, [rsp + 24]
    inc eax
    imul eax, [rbx + IMG_h]
    xor edx, edx
    div dword ptr [rsp + 12]
    cmp eax, [rsp + 28]
    ja 3f
    mov eax, [rsp + 28]
    inc eax
3:  mov [rsp + 32], eax         # y1
    mov dword ptr [rsp + 36], 0 # dx
.Lis_col:
    mov eax, [rsp + 36]
    cmp eax, [rsp + 8]
    jae .Lis_nextrow
    imul eax, [rbx + IMG_w]
    xor edx, edx
    div dword ptr [rsp + 8]
    mov r13d, eax               # x0
    mov eax, [rsp + 36]
    inc eax
    imul eax, [rbx + IMG_w]
    xor edx, edx
    div dword ptr [rsp + 8]
    cmp eax, r13d
    ja 4f
    lea eax, [r13 + 1]
4:  mov r14d, eax               # x1
    # the sums of the four channels, and how many pixels
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    mov r15d, [rsp + 28]        # y
5:  cmp r15d, [rsp + 32]
    jae 7f
    mov eax, r15d
    imul eax, [rbx + IMG_w]
    mov rsi, [rbx + IMG_px]
    lea rsi, [rsi + rax*4]
    mov ecx, r13d
6:  cmp ecx, r14d
    jae 61f
    mov edx, [rsi + rcx*4]
    movzx eax, dl
    add r8d, eax
    mov eax, edx
    shr eax, 8
    and eax, 255
    add r9d, eax
    mov eax, edx
    shr eax, 16
    and eax, 255
    add r10d, eax
    shr edx, 24
    add r11d, edx
    inc ecx
    jmp 6b
61: inc r15d
    jmp 5b
7:  # the count: (y1 - y0) * (x1 - x0)
    mov ecx, [rsp + 32]
    sub ecx, [rsp + 28]
    mov eax, r14d
    sub eax, r13d
    imul ecx, eax
    mov [rsp + 40], ecx
    mov eax, r8d
    xor edx, edx
    div ecx
    mov r8d, eax
    mov eax, r9d
    xor edx, edx
    div dword ptr [rsp + 40]
    shl eax, 8
    or r8d, eax
    mov eax, r10d
    xor edx, edx
    div dword ptr [rsp + 40]
    shl eax, 16
    or r8d, eax
    mov eax, r11d
    xor edx, edx
    div dword ptr [rsp + 40]
    shl eax, 24
    or r8d, eax
    # into place: (oy + dy) * size + ox + dx
    mov eax, [rsp + 20]
    add eax, [rsp + 24]
    imul eax, [rsp]
    add eax, [rsp + 16]
    add eax, [rsp + 36]
    mov [r12 + rax*4], r8d
    inc dword ptr [rsp + 36]
    jmp .Lis_col
.Lis_nextrow:
    inc dword ptr [rsp + 24]
    jmp .Lis_row
.Lis_round:
    # the badge's corners: gfx_round_rect's radius for this size
    mov rdi, r12
    mov esi, [rsp]
    mov edx, esi
    shr edx, 2
    call gfx_round_mask
    mov rax, r12
9:  EPILOGUE
