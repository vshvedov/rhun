# ctext: X11 compound text (COMPOUND_TEXT, ISO 2022 as libX11 writes it) to UTF-8, for the strings an
# XIM server sends (xim.s). GL starts as ASCII and GR as Latin-1's right half. Designations: 94-sets
# ESC ( F and ESC ) F (ASCII, JIS X 0201), 96-sets ESC - F (ISO 8859 halves), 94x94-sets
# ESC $ ( F and ESC $ ) F (GB 2312, JIS X 0208, KS C 5601), and UTF-8 between ESC % G and ESC % @.
# A character of an unknown set is U+FFFD; controls other than tab and newline are dropped.
.include "rhun.inc"

# a set's kind, with its table in the next slot
.equ CS_ASCII, 0
.equ CS_LATIN1, 1               # GR without a designation
.equ CS_96, 2                   # 96 code points from 0xa0
.equ CS_9494, 3                 # 94x94 from row and cell 0x21
.equ CS_KANA, 4                 # JIS X 0201 katakana
.equ CS_UNKNOWN94, 5
.equ CS_UNKNOWN96, 6
.equ CS_UNKNOWN9494, 7

# frame
.equ F_cap, 0
.equ F_glk, 8                   # GL kind and table
.equ F_glt, 16
.equ F_grk, 24
.equ F_grt, 32
.equ F_utf8, 40                 # inside ESC % G
.equ F_cp, 48                   # encoded character

.text

# ct_decode(src, len, dst, cap) -> rax: UTF-8 bytes written to dst, at most cap (whole characters)
FN ct_decode
    PROLOGUE 64
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor r15d, r15d
    mov [rsp + F_cap], rcx
    mov qword ptr [rsp + F_glk], CS_ASCII
    mov qword ptr [rsp + F_grk], CS_LATIN1
    mov qword ptr [rsp + F_utf8], 0
.Lct_next:
    test r13, r13
    jz .Lct_done
    movzx eax, byte ptr [r12]
    cmp eax, 0x1b
    je .Lct_esc
    cmp qword ptr [rsp + F_utf8], 0
    jne .Lct_raw
    cmp eax, 0x9b
    je .Lct_csi
    cmp eax, 0x09
    je .Lct_one
    cmp eax, 0x0a
    je .Lct_one
    cmp eax, 0x20
    jb .Lct_skip
    je .Lct_one
    cmp eax, 0x7f
    jb .Lct_gl
    cmp eax, 0xa0
    jb .Lct_skip
    # GR: the byte's 7 bits in the set designated there
    mov rcx, [rsp + F_grk]
    mov rdx, [rsp + F_grt]
    jmp .Lct_set
.Lct_gl:
    mov rcx, [rsp + F_glk]
    mov rdx, [rsp + F_glt]
.Lct_set:
    # eax byte, ecx kind, rdx table
    cmp ecx, CS_ASCII
    je .Lct_ascii
    cmp ecx, CS_LATIN1
    je .Lct_one
    cmp ecx, CS_96
    je .Lct_96
    cmp ecx, CS_9494
    je .Lct_9494
    cmp ecx, CS_UNKNOWN9494
    je .Lct_unknown2
    cmp ecx, CS_KANA
    jne .Lct_bad1
    and eax, 0x7f
    sub eax, 0x21
    cmp eax, 0x3e
    ja .Lct_bad1
    add eax, 0xff61
    jmp .Lct_put1
.Lct_ascii:
    and eax, 0x7f
    jmp .Lct_put1
.Lct_96:
    or eax, 0x80
    sub eax, 0xa0
    movzx eax, word ptr [rdx + rax*2]
    test eax, eax
    jz .Lct_bad1
    jmp .Lct_put1
.Lct_9494:
    # two bytes, both in the same half
    cmp r13, 2
    jb .Lct_bad1
    movzx ecx, byte ptr [r12 + 1]
    mov r8d, eax
    xor r8d, ecx
    test r8d, 0x80
    jnz .Lct_bad1
    and eax, 0x7f
    and ecx, 0x7f
    sub eax, 0x21
    sub ecx, 0x21
    cmp eax, 93
    ja .Lct_bad2
    cmp ecx, 93
    ja .Lct_bad2
    imul eax, eax, 94
    add eax, ecx
    movzx eax, word ptr [rdx + rax*2]
    test eax, eax
    jz .Lct_bad2
    mov [rsp + F_cp], eax
    mov ecx, 2
    jmp .Lct_put
.Lct_unknown2:
    cmp r13, 2
    jb .Lct_bad1
.Lct_bad2:
    mov dword ptr [rsp + F_cp], 0xfffd
    mov ecx, 2
    jmp .Lct_put
.Lct_bad1:
    mov eax, 0xfffd
.Lct_put1:
    mov [rsp + F_cp], eax
    mov ecx, 1
.Lct_put:
    # [rsp + F_cp] for ecx source bytes
    add r12, rcx
    sub r13, rcx
    lea rax, [r15 + 4]
    cmp rax, [rsp + F_cap]
    jbe 1f
    # it may still fit: encode into the frame first
    mov edi, [rsp + F_cp]
    lea rsi, [rsp + F_cp + 4]
    call utf8_encode
    lea rcx, [r15 + rax]
    cmp rcx, [rsp + F_cap]
    ja .Lct_done
    lea rsi, [rsp + F_cp + 4]
    lea rdi, [r14 + r15]
    mov ecx, eax
    add r15, rax
    rep movsb
    jmp .Lct_next
1:  mov edi, [rsp + F_cp]
    lea rsi, [r14 + r15]
    call utf8_encode
    add r15, rax
    jmp .Lct_next
.Lct_one:
    jmp .Lct_put1
.Lct_raw:
    # inside ESC % G: UTF-8 bytes as they are
    cmp r15, [rsp + F_cap]
    jae .Lct_done
    mov [r14 + r15], al
    inc r15
.Lct_skip:
    inc r12
    dec r13
    jmp .Lct_next
.Lct_csi:
    # direction controls: CSI, parameters, a final byte
    inc r12
    dec r13
1:  test r13, r13
    jz .Lct_done
    movzx eax, byte ptr [r12]
    inc r12
    dec r13
    cmp eax, 0x40
    jb 1b
    jmp .Lct_next
.Lct_esc:
    # ESC, intermediates 0x20..0x2f, a final byte
    cmp r13, 3
    jb .Lct_done
    movzx ecx, byte ptr [r12 + 1]
    movzx edx, byte ptr [r12 + 2]
    cmp ecx, '%'
    je .Lct_esc_pct
    cmp qword ptr [rsp + F_utf8], 0
    jne .Lct_raw_esc
    cmp ecx, '('
    je .Lct_g0_94
    cmp ecx, ')'
    je .Lct_g1_94
    cmp ecx, '-'
    je .Lct_g1_96
    cmp ecx, '$'
    je .Lct_esc_dollar
.Lct_esc_skip:
    # anything else: up to its final byte
    inc r12
    dec r13
1:  test r13, r13
    jz .Lct_done
    movzx eax, byte ptr [r12]
    inc r12
    dec r13
    cmp eax, 0x30
    jb 1b
    jmp .Lct_next
.Lct_raw_esc:
    mov eax, 0x1b
    jmp .Lct_skip
.Lct_g0_94:
    mov eax, CS_ASCII
    cmp edx, 'B'
    je 1f
    cmp edx, 'J'
    je 1f
    mov eax, CS_KANA
    cmp edx, 'I'
    je 1f
    mov eax, CS_UNKNOWN94
1:  mov [rsp + F_glk], rax
    jmp .Lct_esc3
.Lct_g1_94:
    mov eax, CS_ASCII
    cmp edx, 'B'
    je 1f
    cmp edx, 'J'
    je 1f
    mov eax, CS_KANA
    cmp edx, 'I'
    je 1f
    mov eax, CS_UNKNOWN94
1:  mov [rsp + F_grk], rax
    jmp .Lct_esc3
.Lct_g1_96:
    lea rsi, [rip + ct_96]
    movzx ecx, word ptr [rip + ct_96_count]
1:  test ecx, ecx
    jz 2f
    movzx eax, word ptr [rsi]
    cmp eax, edx
    je 3f
    add rsi, 2 + 96 * 2
    dec ecx
    jmp 1b
2:  mov qword ptr [rsp + F_grk], CS_UNKNOWN96
    jmp .Lct_esc3
3:  add rsi, 2
    mov qword ptr [rsp + F_grk], CS_96
    mov [rsp + F_grt], rsi
.Lct_esc3:
    add r12, 3
    sub r13, 3
    jmp .Lct_next
.Lct_esc_dollar:
    # ESC $ ( F into GL, ESC $ ) F into GR, ESC $ F (F in @AB) into GL
    mov r8d, F_glk
    cmp edx, '('
    je 1f
    cmp edx, ')'
    jne 2f
    mov r8d, F_grk
1:  cmp r13, 4
    jb .Lct_done
    movzx edx, byte ptr [r12 + 3]
    mov r9d, 4
    jmp 3f
2:  mov r9d, 3
3:  mov eax, CS_9494
    lea rcx, [rip + ct_gb]
    cmp edx, 'A'
    je 4f
    lea rcx, [rip + ct_jis]
    cmp edx, 'B'
    je 4f
    cmp edx, '@'
    je 4f
    lea rcx, [rip + ct_ksc]
    cmp edx, 'C'
    je 4f
    mov eax, CS_UNKNOWN9494
4:  mov [rsp + r8], rax
    mov [rsp + r8 + 8], rcx
    add r12, r9
    sub r13, r9
    jmp .Lct_next
.Lct_esc_pct:
    cmp edx, 'G'
    jne 1f
    mov qword ptr [rsp + F_utf8], 1
    jmp .Lct_esc3
1:  cmp edx, '@'
    jne 2f
    mov qword ptr [rsp + F_utf8], 0
    jmp .Lct_esc3
2:  cmp qword ptr [rsp + F_utf8], 0
    jne .Lct_raw_esc
    cmp edx, '/'
    jne .Lct_esc_skip
    # ESC % / F M L: an extended segment of (M - 128) * 128 + L - 128 bytes, skipped
    cmp r13, 6
    jb .Lct_done
    movzx eax, byte ptr [r12 + 4]
    movzx ecx, byte ptr [r12 + 5]
    and eax, 0x7f
    and ecx, 0x7f
    shl eax, 7
    add eax, ecx
    add rax, 6
    cmp rax, r13
    jbe 1f
    mov rax, r13
1:  add r12, rax
    sub r13, rax
    jmp .Lct_next
.Lct_done:
    mov rax, r15
    EPILOGUE
