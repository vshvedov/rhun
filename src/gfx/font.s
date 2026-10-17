# TrueType (glyf) fonts: table parsing, cmap, outline decoding, glyph cache, text drawing
.include "rhun.inc"

.equ TAG_cmap, 0x70616d63
.equ TAG_glyf, 0x66796c67
.equ TAG_head, 0x64616568
.equ TAG_hhea, 0x61656868
.equ TAG_hmtx, 0x78746d68
.equ TAG_loca, 0x61636f6c
.equ TAG_maxp, 0x7078616d

.equ MAXPTS, 8192
.equ MAXCONT, 1024

.bss
.p2align 4
ol_x: .zero 4 * MAXPTS
ol_y: .zero 4 * MAXPTS
ol_on: .zero MAXPTS
ol_ends: .zero 4 * MAXCONT
ol_n: .long 0
ol_nc: .long 0
.globl g_face_gen
g_face_gen: .long 0             # counts face_init calls: what is drawn with faces is stale when it moves

.text

# font_load(ptr, len) -> FONT* or 0
FN font_load
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov qword ptr [rsp], 0
    mov edi, FONT_SIZE
    call mem_alloc
    mov rbx, rax
    mov [rbx + FONT_data], r12
    cmp r13, 12
    jb .Lfl_fail
    mov r14, r12
    cmp dword ptr [r12], 0x66637474 # ttcf, first face in a TrueType collection
    jne 1f
    cmp r13, 16
    jb .Lfl_fail
    LDBE32 eax, [r12 + 8]
    test eax, eax
    jz .Lfl_fail
    LDBE32 eax, [r12 + 12]
    lea rdx, [rax + 12]
    cmp rdx, r13
    ja .Lfl_fail
    add r14, rax
1:  LDBE16 ecx, cx, [r14 + 4]   # numTables
    add r14, 12
    mov eax, ecx
    shl rax, 4
    add rax, r14
    sub rax, r12
    cmp rax, r13
    ja .Lfl_fail
.Lfl_tab:
    test ecx, ecx
    jz .Lfl_parsed
    mov eax, [r14]
    LDBE32 edx, [r14 + 8]
    add rdx, r12                # table ptr
    cmp eax, TAG_cmap
    jne 1f
    mov [rsp], rdx
1:  cmp eax, TAG_glyf
    jne 1f
    mov [rbx + FONT_glyf], rdx
1:  cmp eax, TAG_loca
    jne 1f
    mov [rbx + FONT_loca], rdx
1:  cmp eax, TAG_hmtx
    jne 1f
    mov [rbx + FONT_hmtx], rdx
1:  cmp eax, TAG_head
    jne 1f
    LDBE16 r8d, r8w, [rdx + 18]
    mov [rbx + FONT_upem], r8d
    LDBE16S r8d, r8w, [rdx + 50]
    mov [rbx + FONT_localong], r8d
1:  cmp eax, TAG_maxp
    jne 1f
    LDBE16 r8d, r8w, [rdx + 4]
    mov [rbx + FONT_nglyphs], r8d
1:  cmp eax, TAG_hhea
    jne 1f
    LDBE16S r8d, r8w, [rdx + 4]
    mov [rbx + FONT_ascent], r8d
    LDBE16S r8d, r8w, [rdx + 6]
    mov [rbx + FONT_descent], r8d
    LDBE16S r8d, r8w, [rdx + 8]
    mov [rbx + FONT_linegap], r8d
    LDBE16 r8d, r8w, [rdx + 34]
    mov [rbx + FONT_nhmetrics], r8d
1:  add r14, 16
    dec ecx
    jmp .Lfl_tab
.Lfl_parsed:
    cmp qword ptr [rbx + FONT_glyf], 0
    je .Lfl_fail
    cmp qword ptr [rbx + FONT_loca], 0
    je .Lfl_fail
    cmp dword ptr [rbx + FONT_upem], 0
    je .Lfl_fail
    # choose cmap subtable: prefer format 12, then format 4
    mov r14, [rsp]
    test r14, r14
    jz .Lfl_fail
    LDBE16 ecx, cx, [r14 + 2]
    lea r15, [r14 + 4]
.Lfl_cmap:
    test ecx, ecx
    jz .Lfl_cmap_done
    LDBE16 eax, ax, [r15]       # platform
    LDBE16 edx, dx, [r15 + 2]   # encoding
    LDBE32 r8d, [r15 + 4]
    add r8, r14
    LDBE16 r9d, r9w, [r8]       # format
    cmp eax, 0
    je 2f
    cmp eax, 3
    jne 3f
    cmp edx, 1
    je 2f
    cmp edx, 10
    jne 3f
2:  cmp r9d, 12
    jne 4f
    mov [rbx + FONT_cmap], r8
    mov dword ptr [rbx + FONT_cmapfmt], 12
    jmp .Lfl_cmap_done
4:  cmp r9d, 4
    jne 3f
    cmp dword ptr [rbx + FONT_cmapfmt], 0
    jne 3f
    mov [rbx + FONT_cmap], r8
    mov dword ptr [rbx + FONT_cmapfmt], 4
3:  add r15, 8
    dec ecx
    jmp .Lfl_cmap
.Lfl_cmap_done:
    cmp dword ptr [rbx + FONT_cmapfmt], 0
    je .Lfl_fail
    mov rax, rbx
    EPILOGUE
.Lfl_fail:
    mov rdi, rbx
    call mem_free
    xor eax, eax
    EPILOGUE

# font_glyph_index(font, cp) -> gid
FN font_glyph_index
    mov r8, [rdi + FONT_cmap]
    cmp dword ptr [rdi + FONT_cmapfmt], 12
    je .Lgi_12
    # format 4
    cmp esi, 0xffff
    ja .Lgi_none
    LDBE16 r9d, r9w, [r8 + 6]   # segCountX2
    lea r10, [r8 + 14]          # endCode
    xor ecx, ecx
.Lgi4_seg:
    cmp ecx, r9d
    jae .Lgi_none
    LDBE16 eax, ax, [r10 + rcx]
    cmp esi, eax
    jbe .Lgi4_found
    add ecx, 2
    jmp .Lgi4_seg
.Lgi4_found:
    lea r11, [r10 + r9 + 2]     # startCode
    LDBE16 eax, ax, [r11 + rcx]
    cmp esi, eax
    jb .Lgi_none
    mov edx, esi
    sub edx, eax                # cp - start
    add r11, r9                 # idDelta
    LDBE16 eax, ax, [r11 + rcx]
    mov edi, eax                # delta
    add r11, r9                 # idRangeOffset
    LDBE16 eax, ax, [r11 + rcx]
    test eax, eax
    jnz 1f
    lea eax, [rsi + rdi]
    and eax, 0xffff
    ret
1:  lea r11, [r11 + rcx]
    add r11, rax
    lea r11, [r11 + rdx*2]
    LDBE16 eax, ax, [r11]
    test eax, eax
    jz 2f
    add eax, edi
    and eax, 0xffff
2:  ret
.Lgi_12:
    LDBE32 r9d, [r8 + 12]       # nGroups
    lea r10, [r8 + 16]
    xor ecx, ecx                # lo
    mov edx, r9d                # hi
.Lgi12_bs:
    cmp ecx, edx
    jae .Lgi_none
    lea eax, [rcx + rdx]
    shr eax, 1
    imul r11d, eax, 12
    LDBE32 edi, [r10 + r11]     # start
    cmp esi, edi
    jb 1f
    LDBE32 edi, [r10 + r11 + 4] # end
    cmp esi, edi
    ja 2f
    LDBE32 edi, [r10 + r11]
    LDBE32 eax, [r10 + r11 + 8]
    sub esi, edi
    add eax, esi
    ret
1:  mov edx, eax
    jmp .Lgi12_bs
2:  lea ecx, [rax + 1]
    jmp .Lgi12_bs
.Lgi_none:
    xor eax, eax
    ret

# font_advance(font, gid) -> advance in font units
FN font_advance
    mov r8, [rdi + FONT_hmtx]
    mov ecx, [rdi + FONT_nhmetrics]
    cmp esi, ecx
    jb 1f
    lea esi, [rcx - 1]
1:  LDBE16 eax, ax, [r8 + rsi*4]
    ret

# glyph_range(font, gid) -> rax ptr to glyph data, rdx length
glyph_range:
    mov r8, [rdi + FONT_loca]
    cmp esi, [rdi + FONT_nglyphs]
    jae 3f
    cmp dword ptr [rdi + FONT_localong], 0
    jne 1f
    LDBE16 eax, ax, [r8 + rsi*2]
    LDBE16 edx, dx, [r8 + rsi*2 + 2]
    add eax, eax
    add edx, edx
    jmp 2f
1:  LDBE32 eax, [r8 + rsi*4]
    LDBE32 edx, [r8 + rsi*4 + 4]
2:  sub edx, eax
    jbe 3f
    add rax, [rdi + FONT_glyf]
    ret
3:  xor eax, eax
    xor edx, edx
    ret

# decode_glyph(font, gid, depth, xform*) : appends transformed points (font units) to ol_*
# xform: 6 floats a b c d e f ; x' = a x + c y + e ; y' = b x + d y + f
decode_glyph:
    PROLOGUE 64
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14, rcx
    call glyph_range
    test rdx, rdx
    jz .Ldg_ret
    mov r15, rax                # glyph data
    LDBE16S eax, ax, [r15]
    test eax, eax
    js .Ldg_composite
    jz .Ldg_ret
    # ---- simple glyph ----
    mov [rsp], eax              # ncont
    mov ecx, [rip + ol_nc]
    add ecx, eax
    cmp ecx, MAXCONT
    ja .Ldg_ret
    lea r8, [r15 + 10]          # endPts
    dec eax
    LDBE16 edx, dx, [r8 + rax*2]
    inc edx                     # npts
    mov [rsp + 4], edx
    mov ecx, [rip + ol_n]
    mov [rsp + 8], ecx          # base
    add ecx, edx
    cmp ecx, MAXPTS
    ja .Ldg_ret
    # contour ends
    xor ecx, ecx
    lea r9, [rip + ol_ends]
    mov r10d, [rip + ol_nc]
1:  cmp ecx, [rsp]
    jae 2f
    LDBE16 eax, ax, [r8 + rcx*2]
    add eax, [rsp + 8]
    lea r11d, [r10 + rcx]
    mov [r9 + r11*4], eax
    inc ecx
    jmp 1b
2:  mov eax, [rsp]
    add [rip + ol_nc], eax
    # skip instructions
    mov eax, [rsp]
    lea r8, [r8 + rax*2]
    LDBE16 eax, ax, [r8]
    lea r8, [r8 + rax + 2]      # flags
    # flags -> ol_on[base..]
    lea r9, [rip + ol_on]
    mov r10d, [rsp + 8]
    add r9, r10
    xor ecx, ecx
.Ldg_flags:
    cmp ecx, [rsp + 4]
    jae .Ldg_flags_done
    movzx eax, byte ptr [r8]
    inc r8
    mov [r9 + rcx], al
    inc ecx
    test al, 8
    jz .Ldg_flags
    movzx edx, byte ptr [r8]
    inc r8
3:  test edx, edx
    jz .Ldg_flags
    cmp ecx, [rsp + 4]
    jae .Ldg_flags_done
    mov [r9 + rcx], al
    inc ecx
    dec edx
    jmp 3b
.Ldg_flags_done:
    # x coords (int32 into ol_x)
    lea r10, [rip + ol_x]
    mov eax, [rsp + 8]
    lea r10, [r10 + rax*4]
    xor ecx, ecx
    xor edx, edx                # running x
.Ldg_x:
    cmp ecx, [rsp + 4]
    jae .Ldg_x_done
    movzx eax, byte ptr [r9 + rcx]
    test al, 2
    jz 4f
    movzx r11d, byte ptr [r8]
    inc r8
    test al, 16
    jnz 5f
    neg r11d
5:  add edx, r11d
    jmp 6f
4:  test al, 16
    jnz 6f
    LDBE16S r11d, r11w, [r8]
    add r8, 2
    add edx, r11d
6:  mov [r10 + rcx*4], edx
    inc ecx
    jmp .Ldg_x
.Ldg_x_done:
    lea r10, [rip + ol_y]
    mov eax, [rsp + 8]
    lea r10, [r10 + rax*4]
    xor ecx, ecx
    xor edx, edx
.Ldg_y:
    cmp ecx, [rsp + 4]
    jae .Ldg_y_done
    movzx eax, byte ptr [r9 + rcx]
    test al, 4
    jz 4f
    movzx r11d, byte ptr [r8]
    inc r8
    test al, 32
    jnz 5f
    neg r11d
5:  add edx, r11d
    jmp 6f
4:  test al, 32
    jnz 6f
    LDBE16S r11d, r11w, [r8]
    add r8, 2
    add edx, r11d
6:  mov [r10 + rcx*4], edx
    and byte ptr [r9 + rcx], 1
    inc ecx
    jmp .Ldg_y
.Ldg_y_done:
    # transform to float
    lea r8, [rip + ol_x]
    lea r10, [rip + ol_y]
    mov ecx, [rsp + 8]
    mov edx, ecx
    add edx, [rsp + 4]
    movss xmm8, [r14]
    movss xmm9, [r14 + 4]
    movss xmm10, [r14 + 8]
    movss xmm11, [r14 + 12]
    movss xmm12, [r14 + 16]
    movss xmm13, [r14 + 20]
7:  cmp ecx, edx
    jae 8f
    cvtsi2ss xmm0, dword ptr [r8 + rcx*4]
    cvtsi2ss xmm1, dword ptr [r10 + rcx*4]
    movss xmm2, xmm0
    mulss xmm2, xmm8
    movss xmm3, xmm1
    mulss xmm3, xmm10
    addss xmm2, xmm3
    addss xmm2, xmm12
    mulss xmm0, xmm9
    mulss xmm1, xmm11
    addss xmm0, xmm1
    addss xmm0, xmm13
    movss [r8 + rcx*4], xmm2
    movss [r10 + rcx*4], xmm0
    inc ecx
    jmp 7b
8:  mov eax, [rsp + 4]
    add [rip + ol_n], eax
    jmp .Ldg_ret

.Ldg_composite:
    cmp r13d, 8
    jae .Ldg_ret
    add r15, 10
.Ldg_comp:
    LDBE16 eax, ax, [r15]       # flags
    mov [rsp], eax
    LDBE16 esi, si, [r15 + 2]   # component gid
    mov [rsp + 4], esi
    add r15, 4
    test eax, 1
    jz 1f
    LDBE16S ecx, cx, [r15]
    LDBE16S edx, dx, [r15 + 2]
    add r15, 4
    jmp 2f
1:  movsx ecx, byte ptr [r15]
    movsx edx, byte ptr [r15 + 1]
    add r15, 2
2:  test eax, 2
    jnz 3f
    xor ecx, ecx
    xor edx, edx
3:  cvtsi2ss xmm4, ecx          # e
    cvtsi2ss xmm5, edx          # f
    movss xmm0, [rip + f_one]   # a
    xorps xmm1, xmm1            # b
    xorps xmm2, xmm2            # c
    movss xmm3, [rip + f_one]   # d
    test eax, 8
    jz 4f
    call f2dot14
    movss xmm3, xmm0
    add r15, 2
    jmp 6f
4:  test eax, 0x40
    jz 5f
    call f2dot14
    movss xmm6, xmm0
    add r15, 2
    call f2dot14
    movss xmm3, xmm0
    movss xmm0, xmm6
    add r15, 2
    jmp 6f
5:  test eax, 0x80
    jz 6f
    call f2dot14
    movss xmm6, xmm0
    add r15, 2
    call f2dot14
    movss xmm1, xmm0
    add r15, 2
    call f2dot14
    movss xmm2, xmm0
    add r15, 2
    call f2dot14
    movss xmm3, xmm0
    movss xmm0, xmm6
    add r15, 2
6:  # child = parent * component, stored at [rsp+16..40)
    movss xmm8, [r14]           # pa
    movss xmm9, [r14 + 4]       # pb
    movss xmm10, [r14 + 8]      # pc
    movss xmm11, [r14 + 12]     # pd
    # A = pa*a + pc*b
    movss xmm6, xmm8
    mulss xmm6, xmm0
    movss xmm7, xmm10
    mulss xmm7, xmm1
    addss xmm6, xmm7
    movss [rsp + 16], xmm6
    # B = pb*a + pd*b
    movss xmm6, xmm9
    mulss xmm6, xmm0
    movss xmm7, xmm11
    mulss xmm7, xmm1
    addss xmm6, xmm7
    movss [rsp + 20], xmm6
    # C = pa*c + pc*d
    movss xmm6, xmm8
    mulss xmm6, xmm2
    movss xmm7, xmm10
    mulss xmm7, xmm3
    addss xmm6, xmm7
    movss [rsp + 24], xmm6
    # D = pb*c + pd*d
    movss xmm6, xmm9
    mulss xmm6, xmm2
    movss xmm7, xmm11
    mulss xmm7, xmm3
    addss xmm6, xmm7
    movss [rsp + 28], xmm6
    # E = pa*e + pc*f + pe
    movss xmm6, xmm8
    mulss xmm6, xmm4
    movss xmm7, xmm10
    mulss xmm7, xmm5
    addss xmm6, xmm7
    addss xmm6, [r14 + 16]
    movss [rsp + 32], xmm6
    # F = pb*e + pd*f + pf
    movss xmm6, xmm9
    mulss xmm6, xmm4
    movss xmm7, xmm11
    mulss xmm7, xmm5
    addss xmm6, xmm7
    addss xmm6, [r14 + 20]
    movss [rsp + 36], xmm6
    mov rdi, rbx
    mov esi, [rsp + 4]
    lea edx, [r13 + 1]
    lea rcx, [rsp + 16]
    call decode_glyph
    test dword ptr [rsp], 0x20
    jnz .Ldg_comp
.Ldg_ret:
    EPILOGUE

# f2dot14 at [r15] -> xmm0
f2dot14:
    LDBE16S ecx, cx, [r15]
    cvtsi2ss xmm0, ecx
    mulss xmm0, [rip + f_inv16384]
    ret

# face_init(face, font, px)
FN face_init
    inc dword ptr [rip + g_face_gen]
    push rbx
    push r12
    mov rbx, rdi
    mov [rbx + FACE_font], rsi
    mov [rbx + FACE_px], edx
    mov r12, rsi
    cvtsi2ss xmm0, edx
    cvtsi2ss xmm1, dword ptr [r12 + FONT_upem]
    divss xmm0, xmm1
    movss [rbx + FACE_scale], xmm0
    cvtsi2ss xmm1, dword ptr [r12 + FONT_ascent]
    mulss xmm1, xmm0
    roundss xmm1, xmm1, 2
    cvtss2si eax, xmm1
    mov [rbx + FACE_ascent], eax
    cvtsi2ss xmm1, dword ptr [r12 + FONT_descent]
    mulss xmm1, xmm0
    roundss xmm1, xmm1, 1
    cvtss2si ecx, xmm1
    neg ecx
    mov [rbx + FACE_descent], ecx
    add eax, ecx
    cvtsi2ss xmm1, dword ptr [r12 + FONT_linegap]
    mulss xmm1, xmm0
    cvtss2si ecx, xmm1
    add eax, ecx
    mov [rbx + FACE_lineh], eax
    mov rdi, r12
    mov esi, '0'
    call font_glyph_index
    mov rdi, r12
    mov esi, eax
    call font_advance
    cvtsi2ss xmm1, eax
    mulss xmm1, [rbx + FACE_scale]
    cvtss2si eax, xmm1
    mov [rbx + FACE_cellw], eax
    mov rdi, rbx
    call face_clear
    pop r12
    pop rbx
    ret

# face_clear(face): drop cached glyphs
FN face_clear
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, [rbx + FACE_tab]
    test r12, r12
    jz 3f
    xor r13d, r13d
1:  cmp r13d, [rbx + FACE_tabcap]
    jae 2f
    mov rdi, [r12 + r13*8]
    test rdi, rdi
    jz 4f
    push rdi
    mov rdi, [rdi + GL_bits]
    call mem_free
    pop rdi
    call mem_free
4:  inc r13d
    jmp 1b
2:  mov rdi, r12
    call mem_free
3:  mov edi, 8 * 256
    call mem_alloc
    mov [rbx + FACE_tab], rax
    mov dword ptr [rbx + FACE_tabcap], 256
    mov dword ptr [rbx + FACE_tabn], 0
    lea rdi, [rbx + FACE_ascii]
    xor eax, eax
    mov ecx, 128
    rep stosq
    pop r13
    pop r12
    pop rbx
    ret

# hash slot for cp in face table -> rax slot ptr (either matching GL* or empty)
face_slot:
    mov ecx, [rdi + FACE_tabcap]
    dec ecx
    imul eax, esi, 0x9e3779b1
    shr eax, 12
    and eax, ecx
    mov r8, [rdi + FACE_tab]
    lea edx, [rsi + 1]
1:  mov r9, [r8 + rax*8]
    test r9, r9
    jz 2f
    cmp [r9 + GL_key], edx
    je 2f
    inc eax
    and eax, ecx
    jmp 1b
2:  lea rax, [r8 + rax*8]
    ret

# face_glyph(face, cp) -> GL*
FN face_glyph
    cmp esi, 128
    jae 1f
    mov rax, [rdi + FACE_ascii + rsi*8]
    test rax, rax
    jz 1f
    ret
1:  push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    call face_slot
    mov rcx, [rax]
    test rcx, rcx
    jnz .Lfg_have
    mov r13, rax
    mov rdi, rbx
    mov esi, r12d
    call render_glyph
    mov [r13], rax
    mov rcx, rax
    inc dword ptr [rbx + FACE_tabn]
    # grow at 50% load
    mov eax, [rbx + FACE_tabn]
    add eax, eax
    cmp eax, [rbx + FACE_tabcap]
    jb .Lfg_have
    push rcx
    mov rdi, rbx
    call face_grow
    pop rcx
.Lfg_have:
    cmp r12d, 128
    jae 2f
    mov [rbx + FACE_ascii + r12*8], rcx
2:  mov rax, rcx
    pop r13
    pop r12
    pop rbx
    ret

face_grow:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, rdi
    mov r12, [rbx + FACE_tab]
    mov r13d, [rbx + FACE_tabcap]
    mov edi, r13d
    shl edi, 4
    call mem_alloc
    mov [rbx + FACE_tab], rax
    lea eax, [r13 + r13]
    mov [rbx + FACE_tabcap], eax
    xor r14d, r14d
1:  cmp r14d, r13d
    jae 2f
    mov rcx, [r12 + r14*8]
    test rcx, rcx
    jz 3f
    mov [rsp], rcx
    mov esi, [rcx + GL_key]
    dec esi
    mov rdi, rbx
    call face_slot
    mov rcx, [rsp]
    mov [rax], rcx
3:  inc r14d
    jmp 1b
2:  mov rdi, r12
    call mem_free
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# render_glyph(face, cp) -> new GL*
render_glyph:
    PROLOGUE 64
    mov rbx, rdi
    mov r12d, esi
    mov edi, GL_SIZE
    call mem_alloc
    mov r13, rax
    lea eax, [r12 + 1]
    mov [r13 + GL_key], eax
    mov r14, [rbx + FACE_font]
    mov rdi, r14
    mov esi, r12d
    call font_glyph_index
    mov r15d, eax               # gid
    movss xmm0, [rbx + FACE_scale]
    movss [rsp + 8], xmm0       # scale for this glyph's font
    test eax, eax
    jnz 1f
    cmp r12d, 0x80
    jb 1f
    mov edi, r12d
    call fallback_glyph
    test rax, rax
    jz 1f
    mov r14, rax
    mov r15d, edx
    cvtsi2ss xmm0, dword ptr [rbx + FACE_px]
    cvtsi2ss xmm1, dword ptr [r14 + FONT_upem]
    divss xmm0, xmm1
    movss [rsp + 8], xmm0
1:  mov rdi, r14
    mov esi, r15d
    call font_advance
    cvtsi2ss xmm0, eax
    mulss xmm0, [rsp + 8]
    mulss xmm0, [rip + f_64]
    cvtss2si eax, xmm0
    mov [r13 + GL_adv], eax
    # outline
    mov dword ptr [rip + ol_n], 0
    mov dword ptr [rip + ol_nc], 0
    mov rdi, r14
    mov esi, r15d
    xor edx, edx
    lea rcx, [rip + xform_identity]
    call decode_glyph
    mov ecx, [rip + ol_n]
    test ecx, ecx
    jz .Lrg_done
    # scale points and find bbox (y flipped later)
    movss xmm8, [rsp + 8]
    movss xmm4, [rip + f_big]   # minx
    movss xmm5, [rip + f_nbig]  # maxx
    movss xmm6, [rip + f_big]   # miny
    movss xmm7, [rip + f_nbig]  # maxy
    lea r8, [rip + ol_x]
    lea r9, [rip + ol_y]
    xor edx, edx
1:  movss xmm0, [r8 + rdx*4]
    mulss xmm0, xmm8
    movss [r8 + rdx*4], xmm0
    minss xmm4, xmm0
    maxss xmm5, xmm0
    movss xmm1, [r9 + rdx*4]
    mulss xmm1, xmm8
    movss [r9 + rdx*4], xmm1
    minss xmm6, xmm1
    maxss xmm7, xmm1
    inc edx
    cmp edx, ecx
    jb 1b
    roundss xmm4, xmm4, 1
    roundss xmm5, xmm5, 2
    roundss xmm6, xmm6, 1
    roundss xmm7, xmm7, 2
    cvtss2si eax, xmm4
    mov [r13 + GL_left], ax
    cvtss2si edx, xmm5
    sub edx, eax
    inc edx                     # width (+1 slack column)
    cvtss2si eax, xmm7
    mov [r13 + GL_top], ax
    cvtss2si esi, xmm6
    sub eax, esi                # height
    test eax, eax
    jz .Lrg_done
    mov [r13 + GL_w], dx
    mov [r13 + GL_h], ax
    mov [rsp], edx
    mov [rsp + 4], eax
    # to pixel space: px = x - left ; py = top - y ; clamp into buffer
    cvtsi2ss xmm9, edx
    cvtsi2ss xmm10, eax
    xor edx, edx
2:  movss xmm0, [r8 + rdx*4]
    subss xmm0, xmm4
    maxss xmm0, [rip + f_zero]
    minss xmm0, xmm9
    movss [r8 + rdx*4], xmm0
    movss xmm1, xmm7
    subss xmm1, [r9 + rdx*4]
    maxss xmm1, [rip + f_zero]
    minss xmm1, xmm10
    movss [r9 + rdx*4], xmm1
    inc edx
    cmp edx, ecx
    jb 2b
    mov edi, [rsp]
    mov esi, [rsp + 4]
    call raster_begin
    call raster_contours
    mov edi, [rsp]
    imul edi, [rsp + 4]
    call mem_alloc
    mov [r13 + GL_bits], rax
    mov rdi, rax
    call raster_end
.Lrg_done:
    mov rax, r13
    EPILOGUE

# fallback_glyph(cp) -> rax FONT* and edx glyph id from the first system font that has cp, or 0
fallback_glyph:
    PROLOGUE 16
    mov r12d, edi
    xor ebx, ebx
1:  lea rax, [rip + fallback_paths]
    mov rdi, [rax + rbx*8]
    test rdi, rdi
    jz 8f
    lea rcx, [rip + fb_state]
    movzx eax, byte ptr [rcx + rbx]
    cmp eax, 2
    je 5f                       # missing
    cmp eax, 1
    je 3f
    # first use: load it
    mov byte ptr [rcx + rbx], 2
.ifdef WINDOWS
    call win_read_font
.else
    call file_read_all
.endif
    test rax, rax
    jz 5f
    mov rdi, rax
    mov rsi, rdx
    call font_load
    test rax, rax
    jz 5f
    lea rcx, [rip + fb_fonts]
    mov [rcx + rbx*8], rax
    lea rcx, [rip + fb_state]
    mov byte ptr [rcx + rbx], 1
3:  lea rcx, [rip + fb_fonts]
    mov r13, [rcx + rbx*8]
    mov rdi, r13
    mov esi, r12d
    call font_glyph_index
    test eax, eax
    jz 5f
    mov edx, eax
    mov rax, r13
    EPILOGUE
5:  inc ebx
    jmp 1b
8:  xor eax, eax
    EPILOGUE

# raster_contours(): feed ol_* (pixel space) to the rasterizer
raster_contours:
    PROLOGUE 64
    xor r12d, r12d              # contour index
    xor r13d, r13d              # start point of contour
.Lrc_cont:
    cmp r12d, [rip + ol_nc]
    jae .Lrc_ret
    lea rax, [rip + ol_ends]
    mov r14d, [rax + r12*4]     # end index
    mov ebx, r14d
    sub ebx, r13d
    inc ebx                     # n
    cmp ebx, 2
    jl .Lrc_next
    # find first on-curve point
    mov ecx, r13d
    lea r8, [rip + ol_on]
1:  cmp ecx, r14d
    ja 2f
    cmp byte ptr [r8 + rcx], 0
    jne 3f
    inc ecx
    jmp 1b
2:  # none on-curve: start = mid(p0, p1)
    lea r8, [rip + ol_x]
    lea r9, [rip + ol_y]
    movss xmm0, [r8 + r13*4]
    addss xmm0, [r8 + r13*4 + 4]
    mulss xmm0, [rip + f_half]
    movss xmm1, [r9 + r13*4]
    addss xmm1, [r9 + r13*4 + 4]
    mulss xmm1, [rip + f_half]
    mov ecx, r13d
    jmp 4f
3:  lea r8, [rip + ol_x]
    lea r9, [rip + ol_y]
    movss xmm0, [r8 + rcx*4]
    movss xmm1, [r9 + rcx*4]
4:  mov r15d, ecx               # i0
    movss [rsp], xmm0           # start
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm0       # prev
    movss [rsp + 12], xmm1
    mov dword ptr [rsp + 24], 0 # have ctrl
    mov dword ptr [rsp + 28], 1 # k
.Lrc_pt:
    mov eax, [rsp + 28]
    cmp eax, ebx
    jg .Lrc_close
    # idx = start + ((i0 - start + k) mod n)
    mov eax, r15d
    sub eax, r13d
    add eax, [rsp + 28]
    xor edx, edx
    div ebx
    lea eax, [r13 + rdx]
    lea r8, [rip + ol_x]
    lea r9, [rip + ol_y]
    lea r10, [rip + ol_on]
    movss xmm4, [r8 + rax*4]    # p
    movss xmm5, [r9 + rax*4]
    cmp byte ptr [r10 + rax], 0
    je .Lrc_off
    cmp dword ptr [rsp + 24], 0
    je 5f
    movss xmm0, [rsp + 8]
    movss xmm1, [rsp + 12]
    movss xmm2, [rsp + 16]
    movss xmm3, [rsp + 20]
    movss [rsp + 8], xmm4
    movss [rsp + 12], xmm5
    call raster_quad
    jmp 6f
5:  movss xmm0, [rsp + 8]
    movss xmm1, [rsp + 12]
    movss xmm2, xmm4
    movss xmm3, xmm5
    movss [rsp + 8], xmm4
    movss [rsp + 12], xmm5
    call raster_line
6:  mov dword ptr [rsp + 24], 0
    jmp .Lrc_adv
.Lrc_off:
    cmp dword ptr [rsp + 24], 0
    je 7f
    # mid = (ctrl + p) / 2 ; quad(prev, ctrl, mid)
    movss xmm2, [rsp + 16]
    movss xmm3, [rsp + 20]
    movss xmm6, xmm2
    addss xmm6, xmm4
    mulss xmm6, [rip + f_half]
    movss xmm7, xmm3
    addss xmm7, xmm5
    mulss xmm7, [rip + f_half]
    movss [rsp + 16], xmm4      # new ctrl = p
    movss [rsp + 20], xmm5
    movss xmm0, [rsp + 8]
    movss xmm1, [rsp + 12]
    movss [rsp + 8], xmm6
    movss [rsp + 12], xmm7
    movss xmm4, xmm6
    movss xmm5, xmm7
    call raster_quad
    jmp .Lrc_adv
7:  movss [rsp + 16], xmm4
    movss [rsp + 20], xmm5
    mov dword ptr [rsp + 24], 1
.Lrc_adv:
    inc dword ptr [rsp + 28]
    jmp .Lrc_pt
.Lrc_close:
    cmp dword ptr [rsp + 24], 0
    je .Lrc_next
    movss xmm0, [rsp + 8]
    movss xmm1, [rsp + 12]
    movss xmm2, [rsp + 16]
    movss xmm3, [rsp + 20]
    movss xmm4, [rsp]
    movss xmm5, [rsp + 4]
    call raster_quad
.Lrc_next:
    lea r13d, [r14 + 1]
    inc r12d
    jmp .Lrc_cont
.Lrc_ret:
    EPILOGUE

# ---- text ----

# text_draw(face, x, baseline, ptr, len, argb) -> x after last glyph
FN text_draw
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    shl r12d, 6                 # pen 26.6
    mov [rsp], edx              # baseline
    mov r13, rcx
    mov r14, r8
    mov [rsp + 4], r9d          # color
    mov eax, [rip + g_cv + CV_cx1]
    shl eax, 6
    mov [rsp + 8], eax          # stop when pen passes clip right
.Ltd_loop:
    test r14, r14
    jz .Ltd_done
    cmp r12d, [rsp + 8]
    jge .Ltd_done
    mov rdi, r13
    mov rsi, r14
    call utf8_decode
    add r13, rdx
    sub r14, rdx
    mov rdi, rbx
    mov esi, eax
    call face_glyph
    mov r15, rax
    mov rdx, [r15 + GL_bits]
    test rdx, rdx
    jz 1f
    lea edi, [r12 + 32]
    sar edi, 6
    movsx eax, word ptr [r15 + GL_left]
    add edi, eax
    mov esi, [rsp]
    movsx eax, word ptr [r15 + GL_top]
    sub esi, eax
    movzx ecx, word ptr [r15 + GL_w]
    movzx r8d, word ptr [r15 + GL_h]
    mov r9d, [rsp + 4]
    call gfx_mask
1:  add r12d, [r15 + GL_adv]
    jmp .Ltd_loop
.Ltd_done:
    lea eax, [r12 + 32]
    sar eax, 6
    EPILOGUE

# text_width(face, ptr, len) -> px
FN text_width
    PROLOGUE
    mov rbx, rdi
    mov r13, rsi
    mov r14, rdx
    xor r12d, r12d
1:  test r14, r14
    jz 2f
    mov rdi, r13
    mov rsi, r14
    call utf8_decode
    add r13, rdx
    sub r14, rdx
    mov rdi, rbx
    mov esi, eax
    call face_glyph
    add r12d, [rax + GL_adv]
    jmp 1b
2:  lea eax, [r12 + 32]
    sar eax, 6
    EPILOGUE

# text_fit(face, ptr, len, maxw) -> bytes that fit within maxw px
FN text_fit
    PROLOGUE 16
    mov rbx, rdi
    mov r13, rsi
    mov r14, rdx
    shl ecx, 6
    mov [rsp], ecx
    xor r12d, r12d
    xor r15d, r15d              # bytes
1:  cmp r15, r14
    jae 2f
    lea rdi, [r13 + r15]
    mov rsi, r14
    sub rsi, r15
    call utf8_decode
    mov [rsp + 4], edx
    mov rdi, rbx
    mov esi, eax
    call face_glyph
    add r12d, [rax + GL_adv]
    cmp r12d, [rsp]
    jg 2f
    mov eax, [rsp + 4]
    add r15, rax
    jmp 1b
2:  mov rax, r15
    EPILOGUE

# text_draw_fit(face, x, baseline, ptr, len, argb, maxw): draws text, cutting with "…" if wider than maxw
FN text_draw_fit
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov r12, rcx
    mov r13, r8
    mov [rsp + 8], r9d
    mov eax, [rbp + 16]
    mov [rsp + 12], eax         # maxw
    mov rsi, rcx
    mov rdx, r8
    call text_width
    cmp eax, [rsp + 12]
    jle .Ltdf_plain
    mov rdi, rbx
    lea rsi, [rip + ellipsis]
    mov edx, 3
    call text_width
    mov ecx, [rsp + 12]
    sub ecx, eax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call text_fit
    mov r13, rax
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov rcx, r12
    mov r8, r13
    mov r9d, [rsp + 8]
    call text_draw
    mov rdi, rbx
    mov esi, eax
    mov edx, [rsp + 4]
    lea rcx, [rip + ellipsis]
    mov r8d, 3
    mov r9d, [rsp + 8]
    call text_draw
    EPILOGUE
.Ltdf_plain:
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov rcx, r12
    mov r8, r13
    mov r9d, [rsp + 8]
    call text_draw
    EPILOGUE

.bss
.p2align 3
fb_fonts: .zero 8 * 16
fb_state: .zero 16

.section .rodata
.p2align 3
fallback_paths:
.ifdef WINDOWS
    .quad .Lfw1, .Lfw2, .Lfw3, .Lfw4, .Lfw5, 0
.Lfw1: .asciz "Fonts/segoeui.ttf"
.Lfw2: .asciz "Fonts/seguisym.ttf"
.Lfw3: .asciz "Fonts/seguiemj.ttf"
.Lfw4: .asciz "Fonts/msgothic.ttc"
.Lfw5: .asciz "Fonts/msyh.ttc"
.else
.ifdef MACOS
    .quad .Lfm1, .Lfm2, .Lfm3, .Lfm4, 0
.Lfm1: .asciz "/System/Library/Fonts/SFNSMono.ttf"
.Lfm2: .asciz "/System/Library/Fonts/Apple Symbols.ttf"
.Lfm3: .asciz "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"
.Lfm4: .asciz "/Library/Fonts/Arial Unicode.ttf"
.else
    .quad .Lfb1, .Lfb2, .Lfb3, .Lfb4, .Lfb5, .Lfb6, .Lfb7, .Lfb8, .Lfb9, 0
.endif
.endif
.Lfb1: .asciz "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
.Lfb2: .asciz "/usr/share/fonts/TTF/DejaVuSansMono.ttf"
.Lfb3: .asciz "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
.Lfb4: .asciz "/usr/share/fonts/TTF/DejaVuSans.ttf"
.Lfb5: .asciz "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf"
.Lfb6: .asciz "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf"
.Lfb7: .asciz "/usr/share/fonts/truetype/noto/NotoSansSymbols-Regular.ttf"
.Lfb8: .asciz "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf"
.Lfb9: .asciz "/usr/share/fonts/wenquanyi/wqy-microhei/wqy-microhei.ttc"
.p2align 2
xform_identity: .float 1.0, 0.0, 0.0, 1.0, 0.0, 0.0
f_inv16384: .float 0.00006103515625
f_big: .float 1.0e9
f_nbig: .float -1.0e9
.globl ellipsis
ellipsis: .ascii "\342\200\246"
