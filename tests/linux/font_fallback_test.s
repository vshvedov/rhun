# Hangul through the system fallback fonts: for each character, the fallback font that has it (or
# "none") and whether the editor face draws a real glyph or the built-in font's missing-glyph box.
# Needs fonts-nanum (run.sh skips it without); DroidSansFallbackFull.ttf maps only 가, 힢 and 힣.
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
face: .zero FACE_SIZE
.text
FN main
    PROLOGUE 16
    lea rdi, [rip + font_mono]
    lea rsi, [rip + font_mono_end]
    sub rsi, rdi
    call font_load
    lea rdi, [rip + face]
    mov rsi, rax
    mov edx, 32
    call face_init
    # the box: a private-use character no font maps
    lea rdi, [rip + face]
    mov esi, 0x10fffd
    call face_glyph
    mov r15, rax
    lea r12, [rip + cases]
1:  mov r13d, [r12]
    test r13d, r13d
    jz 9f
    lea rdi, [rip + out]
    mov esi, r13d
    call sb_push_utf8
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov edi, r13d
    call fallback_glyph
    lea rsi, [rip + s_none]
    test rax, rax
    jz 3f
    xor ecx, ecx
2:  lea rdx, [rip + fallback_paths]
    mov rsi, [rdx + rcx*8]
    test rsi, rsi
    jz 31f
    lea rdx, [rip + fb_fonts]
    cmp [rdx + rcx*8], rax
    je 3f
    inc ecx
    jmp 2b
31: lea rsi, [rip + s_none]
3:  lea rdi, [rip + out]
    call sb_push_cstr
    lea rdi, [rip + face]
    mov esi, r13d
    call face_glyph
    mov rdi, rax
    mov rsi, r15
    call same_bitmap
    lea rsi, [rip + s_glyph]
    test eax, eax
    jz 4f
    lea rsi, [rip + s_box]
4:  lea rdi, [rip + out]
    call sb_push_cstr
    add r12, 4
    jmp 1b
9:  mov edi, 1
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    call write_all
    xor eax, eax
    EPILOGUE

# same_bitmap(GL*, GL*) -> 1 when both have the same size and coverage
same_bitmap:
    movzx eax, word ptr [rdi + GL_w]
    cmp ax, [rsi + GL_w]
    jne 8f
    movzx ecx, word ptr [rdi + GL_h]
    cmp cx, [rsi + GL_h]
    jne 8f
    imul ecx, eax
    mov rdi, [rdi + GL_bits]
    mov rsi, [rsi + GL_bits]
    cmp rdi, rsi
    je 7f
    test rdi, rdi
    jz 8f
    test rsi, rsi
    jz 8f
    repe cmpsb
    jne 8f
7:  mov eax, 1
    ret
8:  xor eax, eax
    ret

.section .rodata
.p2align 2
cases: .long 0xd55c, 0xae00, 0xac00, 0
s_none: .asciz "none"
s_glyph: .asciz " glyph\n"
s_box: .asciz " box\n"
