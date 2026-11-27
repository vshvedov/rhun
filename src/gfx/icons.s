# vector icons: small stroke/fill programs (icondata.s) rasterized and cached per size
.include "rhun.inc"

.equ ICACHE, 96
.equ ICON_MAX, 2048             # px: the largest size icon_draw draws (a mask is size * size bytes)

.bss
.p2align 4
pts: .zero 8 * 256
cache_key: .zero 4 * ICACHE      # icon | size << 8
cache_ptr: .zero 8 * ICACHE
cache_n: .long 0
.p2align 2
f_scale: .long 0
f_hw: .long 0
prev_x: .long 0
prev_y: .long 0

.text

# emit_poly(n, dir): canonical (>0), reversed (<0), or original (=0) winding
emit_poly:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov r13d, 1
    test r12d, r12d
    jz .Lep_points             # preserve the winding of filled SVG contours
    # signed area
    xorps xmm7, xmm7
    xor ecx, ecx
    lea r8, [rip + pts]
1:  cmp ecx, ebx
    jae 2f
    lea edx, [rcx + 1]
    cmp edx, ebx
    jb 11f
    xor edx, edx
11: movss xmm0, [r8 + rcx*8]
    mulss xmm0, [r8 + rdx*8 + 4]
    movss xmm1, [r8 + rdx*8]
    mulss xmm1, [r8 + rcx*8 + 4]
    subss xmm0, xmm1
    addss xmm7, xmm0
    inc ecx
    jmp 1b
2:  xor eax, eax
    comiss xmm7, [rip + f_zero]
    seta al                     # 1 if positive
    xor edx, edx
    test r12d, r12d
    setns dl
    cmp eax, edx
    sete r13b                   # forward if orientation matches
.Lep_points:
    xor ecx, ecx
3:  cmp ecx, ebx
    jae 9f
    lea r8, [rip + pts]
    mov eax, ecx
    lea edx, [rcx + 1]
    cmp edx, ebx
    jb 4f
    xor edx, edx
4:  test r13b, r13b
    jnz 5f
    xchg eax, edx
5:  push rcx
    movss xmm0, [r8 + rax*8]
    movss xmm1, [r8 + rax*8 + 4]
    movss xmm2, [r8 + rdx*8]
    movss xmm3, [r8 + rdx*8 + 4]
    call raster_line
    pop rcx
    inc ecx
    jmp 3b
9:  pop r13
    pop r12
    pop rbx
    ret

# circle_poly(xmm0=cx, xmm1=cy, xmm2=r, step) -> n points in pts
circle_poly:
    lea r8, [rip + circle_tab]
    lea r9, [rip + pts]
    xor ecx, ecx
    xor eax, eax
1:  cmp ecx, 32
    jae 2f
    movss xmm3, [r8 + rcx*8]
    mulss xmm3, xmm2
    addss xmm3, xmm0
    movss [r9 + rax*8], xmm3
    movss xmm3, [r8 + rcx*8 + 4]
    mulss xmm3, xmm2
    addss xmm3, xmm1
    movss [r9 + rax*8 + 4], xmm3
    inc eax
    add ecx, edi
    jmp 1b
2:  ret

# disc(xmm0 cx, xmm1 cy, xmm2 r, dir)
disc:
    push rbx
    mov ebx, edi
    mov edi, 1
    call circle_poly
    mov edi, eax
    mov esi, ebx
    call emit_poly
    pop rbx
    ret

# segment(xmm0 x0, xmm1 y0, xmm2 x1, xmm3 y1): quad of half width f_hw
segment:
    movss xmm4, xmm2
    subss xmm4, xmm0            # dx
    movss xmm5, xmm3
    subss xmm5, xmm1            # dy
    movss xmm6, xmm4
    mulss xmm6, xmm4
    movss xmm7, xmm5
    mulss xmm7, xmm5
    addss xmm6, xmm7
    sqrtss xmm6, xmm6
    comiss xmm6, [rip + f_eps]
    jbe 9f
    movss xmm7, [rip + f_hw]
    divss xmm7, xmm6
    mulss xmm4, xmm7            # dx * hw/len
    mulss xmm5, xmm7            # dy * hw/len
    # n = (-dy, dx)
    lea r8, [rip + pts]
    movss xmm6, xmm0
    subss xmm6, xmm5
    movss [r8], xmm6
    movss xmm6, xmm1
    addss xmm6, xmm4
    movss [r8 + 4], xmm6
    movss xmm6, xmm2
    subss xmm6, xmm5
    movss [r8 + 8], xmm6
    movss xmm6, xmm3
    addss xmm6, xmm4
    movss [r8 + 12], xmm6
    movss xmm6, xmm2
    addss xmm6, xmm5
    movss [r8 + 16], xmm6
    movss xmm6, xmm3
    subss xmm6, xmm4
    movss [r8 + 20], xmm6
    movss xmm6, xmm0
    addss xmm6, xmm5
    movss [r8 + 24], xmm6
    movss xmm6, xmm1
    subss xmm6, xmm4
    movss [r8 + 28], xmm6
    mov edi, 4
    mov esi, 1
    jmp emit_poly
9:  ret

# cap at (xmm0, xmm1): small disc of radius f_hw
cap:
    movss xmm2, [rip + f_hw]
    push rbx
    mov edi, 2
    call circle_poly
    mov edi, eax
    mov esi, 1
    call emit_poly
    pop rbx
    ret

# coord(byte) -> xmm0 = byte * scale
.macro COORD reg, src
    movzx eax, byte ptr \src
    cvtsi2ss \reg, eax
    mulss \reg, [rip + f_scale]
.endm

# icon_render(icon, size) -> mask (size*size bytes)
icon_render:
    PROLOGUE 32
    mov ebx, esi                # size
    lea rax, [rip + icon_table]
    mov r12, [rax + rdi*8]      # program
    cvtsi2ss xmm0, ebx
    divss xmm0, [rip + f_128]
    movss [rip + f_scale], xmm0
    movss xmm1, xmm0
    mulss xmm1, [rip + f_5]     # default width 10 units
    movss [rip + f_hw], xmm1
    mov edi, ebx
    mov esi, ebx
    call raster_begin
.Lir_op:
    movzx eax, byte ptr [r12]
    inc r12
    test eax, eax
    jz .Lir_done
    cmp al, 'W'
    je .Lir_w
    cmp al, 'M'
    je .Lir_m
    cmp al, 'L'
    je .Lir_l
    cmp al, 'O'
    je .Lir_o
    cmp al, 'D'
    je .Lir_d
    cmp al, 'P'
    je .Lir_p
    cmp al, 'F'
    je .Lir_f
    jmp .Lir_done
.Lir_w:
    COORD xmm0, [r12]
    mulss xmm0, [rip + f_half]
    movss [rip + f_hw], xmm0
    inc r12
    jmp .Lir_op
.Lir_m:
    COORD xmm0, [r12]
    COORD xmm1, [r12 + 1]
    add r12, 2
    movss [rip + prev_x], xmm0
    movss [rip + prev_y], xmm1
    call cap
    jmp .Lir_op
.Lir_l:
    COORD xmm2, [r12]
    COORD xmm3, [r12 + 1]
    add r12, 2
    movss [rsp], xmm2
    movss [rsp + 4], xmm3
    movss xmm0, [rip + prev_x]
    movss xmm1, [rip + prev_y]
    call segment
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    movss [rip + prev_x], xmm0
    movss [rip + prev_y], xmm1
    call cap
    jmp .Lir_op
.Lir_o:
    COORD xmm0, [r12]
    COORD xmm1, [r12 + 1]
    COORD xmm2, [r12 + 2]
    add r12, 3
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    addss xmm2, [rip + f_hw]
    mov edi, 1
    call disc
    movss xmm0, [rsp]
    movss xmm1, [rsp + 4]
    movss xmm2, [rsp + 8]
    subss xmm2, [rip + f_hw]
    mov edi, -1
    call disc
    jmp .Lir_op
.Lir_d:
    COORD xmm0, [r12]
    COORD xmm1, [r12 + 1]
    COORD xmm2, [r12 + 2]
    add r12, 3
    mov edi, 1
    call disc
    jmp .Lir_op
.Lir_p:
    mov dword ptr [rsp + 12], 1
    jmp .Lir_poly
.Lir_f:
    mov dword ptr [rsp + 12], 0
.Lir_poly:
    movzx r13d, byte ptr [r12]
    inc r12
    lea r8, [rip + pts]
    xor ecx, ecx
1:  cmp ecx, r13d
    jae 2f
    COORD xmm0, [r12]
    COORD xmm1, [r12 + 1]
    movss [r8 + rcx*8], xmm0
    movss [r8 + rcx*8 + 4], xmm1
    add r12, 2
    inc ecx
    jmp 1b
2:  mov edi, r13d
    mov esi, [rsp + 12]
    call emit_poly
    jmp .Lir_op
.Lir_done:
    mov edi, ebx
    imul edi, ebx
    call mem_alloc
    mov r13, rax
    mov rdi, rax
    call raster_end
    mov rax, r13
    EPILOGUE

# icon_mask(icon, size) -> cached mask
FN icon_mask
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    mov eax, esi
    shl eax, 8
    or eax, edi
    mov r13d, eax               # key
    lea r8, [rip + cache_key]
    xor ecx, ecx
1:  cmp ecx, [rip + cache_n]
    jae 2f
    cmp [r8 + rcx*4], r13d
    je 3f
    inc ecx
    jmp 1b
3:  lea r8, [rip + cache_ptr]
    mov rax, [r8 + rcx*8]
    jmp 9f
2:  mov edi, ebx
    mov esi, r12d
    call icon_render
    mov ecx, [rip + cache_n]
    cmp ecx, ICACHE
    jb 4f
    push rax
    push rax
    call icon_cache_clear
    pop rax
    pop rax
    xor ecx, ecx
4:  lea r8, [rip + cache_key]
    mov [r8 + rcx*4], r13d
    lea r8, [rip + cache_ptr]
    mov [r8 + rcx*8], rax
    inc dword ptr [rip + cache_n]
9:  pop r13
    pop r12
    pop rbx
    ret

# icon_draw(icon, x, y, size, argb): nothing for a size outside 1 to ICON_MAX, which only a caller's bad
#   size register gives (raster_begin's w * h wraps far above it: a buffer too small, then a crash)
FN icon_draw
    lea eax, [rcx - 1]
    cmp eax, ICON_MAX
    jb 1f
    ret
1:  push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, esi
    mov r12d, edx
    mov r13d, ecx
    mov r14d, r8d
    mov esi, ecx
    call icon_mask
    mov edi, ebx
    mov esi, r12d
    mov rdx, rax
    mov ecx, r13d
    mov r8d, r13d
    mov r9d, r14d
    call gfx_mask
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# icon_cache_clear(): forget cached masks (after a scale change)
FN icon_cache_clear
    push rbx
    xor ebx, ebx
1:  cmp ebx, [rip + cache_n]
    jae 2f
    lea rax, [rip + cache_ptr]
    mov rdi, [rax + rbx*8]
    call mem_free
    inc ebx
    jmp 1b
2:  mov dword ptr [rip + cache_n], 0
    pop rbx
    ret

.section .rodata
.p2align 2
f_128: .float 128.0
f_5: .float 5.0
