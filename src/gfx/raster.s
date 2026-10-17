# scanline coverage rasterizer (signed-area accumulation, nonzero-ish via |sum| clamp)
.include "rhun.inc"

.bss
.p2align 3
acc_buf: .quad 0
acc_cap: .quad 0                # floats
.globl g_acc_w, g_acc_h
g_acc_w: .long 0
g_acc_h: .long 0
acc_stride: .long 0             # cells a row: w and two more, where what lies right of the area lands
acc_wf: .long 0                   # w, as a float: x is clamped to it
.p2align 4
gamma_tab: .zero 256

.text

# raster_init(): build the coverage curve table
FN raster_init
    xor ecx, ecx
    lea rdi, [rip + gamma_tab]
1:  cvtsi2ss xmm0, ecx
    divss xmm0, [rip + f_255]
    movss xmm1, xmm0
    sqrtss xmm1, xmm1
    mulss xmm1, xmm0
    sqrtss xmm1, xmm1           # t^0.75
    addss xmm1, xmm0
    mulss xmm1, [rip + f_half]  # (t + t^0.75) / 2
    mulss xmm1, [rip + f_255]
    cvtss2si eax, xmm1
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, 256
    jb 1b
    ret

# raster_begin(w, h): clear accumulation buffer
FN raster_begin
    push rbx
    mov [rip + g_acc_w], edi
    mov [rip + g_acc_h], esi
    cvtsi2ss xmm0, edi
    movss [rip + acc_wf], xmm0
    add edi, 2
    mov [rip + acc_stride], edi
    mov eax, edi
    imul eax, esi
    lea ebx, [rax + rdi + 8]
    cmp rbx, [rip + acc_cap]
    jbe 1f
    lea rsi, [rbx*4]
    mov rdi, [rip + acc_buf]
    call mem_realloc
    mov [rip + acc_buf], rax
    mov [rip + acc_cap], rbx
1:  mov rdi, [rip + acc_buf]
    mov rcx, rbx
    xor eax, eax
    rep stosd
    pop rbx
    ret

# raster_line(xmm0=x0, xmm1=y0, xmm2=x1, xmm3=y1) in pixel space, y down
FN raster_line
    movss xmm4, xmm1
    subss xmm4, xmm3
    andps xmm4, [rip + abs_mask]
    comiss xmm4, [rip + f_eps]
    jb .Lrl_ret
    movss xmm15, [rip + f_one]
    comiss xmm1, xmm3
    jb 1f
    movss xmm4, xmm0
    movss xmm0, xmm2
    movss xmm2, xmm4
    movss xmm4, xmm1
    movss xmm1, xmm3
    movss xmm3, xmm4
    movss xmm15, [rip + f_mone]
1:  # clamp y range to buffer
    maxss xmm1, [rip + f_zero]
    movss xmm5, xmm2
    subss xmm5, xmm0
    movss xmm4, xmm3
    subss xmm4, xmm1
    comiss xmm4, [rip + f_eps]
    jb .Lrl_ret
    divss xmm5, xmm4            # dxdy
    movss xmm6, xmm0            # x
    cvttss2si ecx, xmm1         # y
    roundss xmm4, xmm3, 2
    cvttss2si edx, xmm4         # yend
    cmp edx, [rip + g_acc_h]
    jle 2f
    mov edx, [rip + g_acc_h]
2:  mov rdi, [rip + acc_buf]
    mov r9d, [rip + acc_stride]
.Lrl_row:
    cmp ecx, edx
    jge .Lrl_ret
    mov r8d, ecx
    imul r8d, r9d               # linestart
    cvtsi2ss xmm7, ecx
    movss xmm8, xmm7
    addss xmm8, [rip + f_one]
    minss xmm8, xmm3
    maxss xmm7, xmm1
    subss xmm8, xmm7            # dy
    movss xmm9, xmm5
    mulss xmm9, xmm8
    addss xmm9, xmm6            # xnext
    movss xmm10, xmm8
    mulss xmm10, xmm15          # d
    movss xmm11, xmm6
    minss xmm11, xmm9           # xa
    movss xmm12, xmm6
    maxss xmm12, xmm9           # xb
    maxss xmm11, [rip + f_zero]
    maxss xmm12, [rip + f_zero]
    minss xmm11, [rip + acc_wf]     # right of the area: into the row's spare cells
    minss xmm12, [rip + acc_wf]
    roundss xmm13, xmm11, 1     # floor(xa)
    cvttss2si r10d, xmm13       # xai
    roundss xmm14, xmm12, 2     # ceil(xb)
    cvttss2si r11d, xmm14       # xbi
    add r10d, r8d               # absolute index of xai
    add r11d, r8d               # absolute index of xbi
    lea eax, [r10 + 1]
    cmp r11d, eax
    jg .Lrl_wide
    # single cell
    movss xmm0, xmm6
    addss xmm0, xmm9
    mulss xmm0, [rip + f_half]
    subss xmm0, xmm13           # xmf
    maxss xmm0, [rip + f_zero]
    minss xmm0, [rip + f_one]
    movss xmm2, xmm10
    mulss xmm2, xmm0            # d*xmf
    movss xmm4, xmm10
    subss xmm4, xmm2
    addss xmm4, [rdi + r10*4]
    movss [rdi + r10*4], xmm4
    addss xmm2, [rdi + r10*4 + 4]
    movss [rdi + r10*4 + 4], xmm2
    jmp .Lrl_next
.Lrl_wide:
    movss xmm0, xmm12
    subss xmm0, xmm11
    movss xmm2, [rip + f_one]
    divss xmm2, xmm0            # s
    movss xmm0, xmm11
    subss xmm0, xmm13           # x0f
    movss xmm4, [rip + f_one]
    subss xmm4, xmm0
    mulss xmm4, xmm4
    mulss xmm4, xmm2
    mulss xmm4, [rip + f_half]  # a0
    movss xmm7, xmm12
    subss xmm7, xmm14
    addss xmm7, [rip + f_one]   # x1f
    mulss xmm7, xmm7
    mulss xmm7, xmm2
    mulss xmm7, [rip + f_half]  # am
    # a[xai] += d*a0
    movss xmm8, xmm4
    mulss xmm8, xmm10
    addss xmm8, [rdi + r10*4]
    movss [rdi + r10*4], xmm8
    lea eax, [r10 + 2]
    cmp r11d, eax
    jne .Lrl_long
    movss xmm8, [rip + f_one]
    subss xmm8, xmm4
    subss xmm8, xmm7
    mulss xmm8, xmm10
    addss xmm8, [rdi + r10*4 + 4]
    movss [rdi + r10*4 + 4], xmm8
    jmp .Lrl_last
.Lrl_long:
    movss xmm8, [rip + f_1p5]
    subss xmm8, xmm0
    mulss xmm8, xmm2            # a1
    movss xmm13, xmm8
    subss xmm13, xmm4
    mulss xmm13, xmm10
    addss xmm13, [rdi + r10*4 + 4]
    movss [rdi + r10*4 + 4], xmm13
    movss xmm13, xmm2
    mulss xmm13, xmm10          # d*s
    lea eax, [r10 + 2]
    lea esi, [r11 - 1]
3:  cmp eax, esi
    jge 4f
    movss xmm14, [rdi + rax*4]
    addss xmm14, xmm13
    movss [rdi + rax*4], xmm14
    inc eax
    jmp 3b
4:  # a2 = a1 + (xbi - xai - 3) * s
    mov eax, r11d
    sub eax, r10d
    sub eax, 3
    cvtsi2ss xmm13, eax
    mulss xmm13, xmm2
    addss xmm13, xmm8
    movss xmm14, [rip + f_one]
    subss xmm14, xmm13
    subss xmm14, xmm7
    mulss xmm14, xmm10
    addss xmm14, [rdi + r11*4 - 4]
    movss [rdi + r11*4 - 4], xmm14
.Lrl_last:
    mulss xmm7, xmm10
    addss xmm7, [rdi + r11*4]
    movss [rdi + r11*4], xmm7
.Lrl_next:
    movss xmm6, xmm9
    inc ecx
    jmp .Lrl_row
.Lrl_ret:
    ret

# raster_quad(xmm0..5 = x0,y0,x1,y1,x2,y2)
FN raster_quad
    PROLOGUE 64
    movss [rsp], xmm0
    movss [rsp + 4], xmm1
    movss [rsp + 8], xmm2
    movss [rsp + 12], xmm3
    movss [rsp + 16], xmm4
    movss [rsp + 20], xmm5
    # dd = |p0 - 2p1 + p2|
    movss xmm6, xmm2
    addss xmm6, xmm6
    movss xmm7, xmm0
    subss xmm7, xmm6
    addss xmm7, xmm4
    movss xmm6, xmm3
    addss xmm6, xmm6
    movss xmm8, xmm1
    subss xmm8, xmm6
    addss xmm8, xmm5
    mulss xmm7, xmm7
    mulss xmm8, xmm8
    addss xmm7, xmm8
    sqrtss xmm7, xmm7
    mulss xmm7, [rip + f_1p5]
    sqrtss xmm7, xmm7
    cvttss2si ebx, xmm7
    inc ebx
    cmp ebx, 48
    jle 1f
    mov ebx, 48
1:  cvtsi2ss xmm0, ebx
    movss xmm1, [rip + f_one]
    divss xmm1, xmm0
    movss [rsp + 24], xmm1      # 1/n
    movss xmm0, [rsp]
    movss [rsp + 28], xmm0      # prev x
    movss xmm0, [rsp + 4]
    movss [rsp + 32], xmm0      # prev y
    mov r12d, 1
.Lrq_loop:
    cmp r12d, ebx
    jg .Lrq_ret
    cvtsi2ss xmm0, r12d
    mulss xmm0, [rsp + 24]      # t
    movss xmm1, [rip + f_one]
    subss xmm1, xmm0            # mt
    movss xmm2, xmm1
    mulss xmm2, xmm1            # mt^2
    movss xmm3, xmm1
    mulss xmm3, xmm0
    addss xmm3, xmm3            # 2 mt t
    movss xmm4, xmm0
    mulss xmm4, xmm0            # t^2
    movss xmm5, [rsp]
    mulss xmm5, xmm2
    movss xmm6, [rsp + 8]
    mulss xmm6, xmm3
    addss xmm5, xmm6
    movss xmm6, [rsp + 16]
    mulss xmm6, xmm4
    addss xmm5, xmm6            # x
    movss xmm7, [rsp + 4]
    mulss xmm7, xmm2
    movss xmm6, [rsp + 12]
    mulss xmm6, xmm3
    addss xmm7, xmm6
    movss xmm6, [rsp + 20]
    mulss xmm6, xmm4
    addss xmm7, xmm6            # y
    movss [rsp + 36], xmm5
    movss [rsp + 40], xmm7
    movss xmm0, [rsp + 28]
    movss xmm1, [rsp + 32]
    movss xmm2, xmm5
    movss xmm3, xmm7
    call raster_line
    movss xmm0, [rsp + 36]
    movss [rsp + 28], xmm0
    movss xmm0, [rsp + 40]
    movss [rsp + 32], xmm0
    inc r12d
    jmp .Lrq_loop
.Lrq_ret:
    EPILOGUE

# raster_end(out): accumulate coverage into w*h alpha bytes (a row's spare cells count toward the
# running sum but are not written)
FN raster_end
    mov rsi, [rip + acc_buf]
    mov r9d, [rip + g_acc_w]
    mov r10d, [rip + acc_stride]
    mov r11d, [rip + g_acc_h]
    lea r8, [rip + gamma_tab]
    xorps xmm0, xmm0
    movss xmm2, [rip + f_one]
    movss xmm3, [rip + f_255]
    movss xmm4, [rip + abs_mask]
    xor ecx, ecx                # the row
1:  cmp ecx, r11d
    jge 9f
    xor edx, edx                # the cell
2:  cmp edx, r10d
    jge 5f
    addss xmm0, [rsi + rdx*4]
    cmp edx, r9d
    jge 3f
    movss xmm1, xmm0
    andps xmm1, xmm4
    minss xmm1, xmm2
    mulss xmm1, xmm3
    cvtss2si eax, xmm1
    movzx eax, byte ptr [r8 + rax]
    mov [rdi + rdx], al
3:  inc edx
    jmp 2b
5:  movsxd rax, r10d
    lea rsi, [rsi + rax*4]
    movsxd rax, r9d
    add rdi, rax
    inc ecx
    jmp 1b
9:  ret

.section .rodata
.p2align 4
.globl abs_mask
abs_mask: .long 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff
.globl f_eps, f_mone, f_1p5
f_eps: .float 0.0001
f_mone: .float -1.0
f_1p5: .float 1.5
