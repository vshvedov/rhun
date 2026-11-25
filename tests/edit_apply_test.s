# edit_apply (claude_cards.s, phase 4 task 11): an Edit applied as Claude Code applies it, a case a line:
#   "NAME found=0|1 TEXT" with the text after (LF as \n, CR as \r). The cases marked "recorded" are the real
#   CLI's bytes of finding 49 (tests/data/claude-shapes/README.txt): a file it read with CR LF is read as LF and
#   the strings sent back are LF; the others are the extension's rules (_ne, oQe, PSr EXT@3192347), not recorded
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
res: .zero SB_SIZE
.text
FN main
    PROLOGUE 16
    lea r12, [rip + cases]
1:  mov rbx, [r12]
    test rbx, rbx
    jz 9f
    lea rdi, [rip + out]
    mov rsi, rbx
    call sb_push_cstr
    # text, old, new: cstrs; replace_all
    mov rdi, [r12 + 8]
    call strlen
    mov r13, rax
    mov rdi, [r12 + 16]
    call strlen
    mov r14, rax
    mov rdi, [r12 + 24]
    call strlen
    mov r15, rax
    mov rdi, [r12 + 8]
    mov rsi, r13
    mov rdx, [r12 + 16]
    mov rcx, r14
    mov r8, [r12 + 24]
    mov r9, r15
    lea rax, [rip + res]
    push rax
    push qword ptr [r12 + 32]
    call edit_apply
    add rsp, 16
    mov r13d, eax
    lea rdi, [rip + out]
    lea rsi, [rip + .Lfound]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    xor r14d, r14d
2:  cmp r14, [rip + res + SB_len]
    jae 4f
    mov rax, [rip + res + SB_ptr]
    movzx esi, byte ptr [rax + r14]
    inc r14
    cmp esi, 10
    je 21f
    cmp esi, 13
    je 22f
    lea rdi, [rip + out]
    call sb_push_byte
    jmp 2b
21: lea rdi, [rip + out]
    lea rsi, [rip + .Llf]
    call sb_push_cstr
    jmp 2b
22: lea rdi, [rip + out]
    lea rsi, [rip + .Lcr]
    call sb_push_cstr
    jmp 2b
4:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    add r12, 40
    jmp 1b
9:  mov rdi, 1
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    call write_all
    xor eax, eax
    EPILOGUE

.section .rodata
.Lfound: .asciz " found="
.Llf: .asciz "\\n"
.Lcr: .asciz "\\r"
n1: .asciz "lf(recorded)"
t1: .asciz "alpha\nbravo\ncharlie\ndelta\necho\n"
o1: .asciz "bravo"
w1: .asciz "BRAVO"
n2: .asciz "crlf-lf-strings(recorded)"
t2: .asciz "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n"
o2: .asciz "two"
w2: .asciz "TWO"
n3: .asciz "crlf-whole-file-lf(recorded)"
t3: .asciz "one\r\nTWO\r\nthree\r\nfour\r\nfive\r\n"
o3: .asciz "one\nTWO\nthree\nfour\nfive\n"
w3: .asciz "one\nTWO\nTHREE\nfour\nfive\n"
n4: .asciz "crlf-crlf-strings(not-recorded)"
o4: .asciz "two\r\nthree"
w4: .asciz "TWO\r\nTHREE"
n5: .asciz "replace-all(not-recorded)"
t5: .asciz "a x\nb x\nc x\n"
o5: .asciz "x"
w5: .asciz "y"
n6: .asciz "replace-first(not-recorded)"
n7: .asciz "no-final-lf(not-recorded)"
t7: .asciz "x\ny"
o7: .asciz "y"
w7: .asciz "z"
n8: .asciz "not-there(not-recorded)"
o8: .asciz "delta"
w8: .asciz "DELTA"
n9: .asciz "removed-line-takes-its-lf(not-recorded)"
t9: .asciz "a\nb\nc\n"
o9: .asciz "b"
e0: .asciz ""
n10: .asciz "no-old-text(not-recorded)"
w10: .asciz "whole\n"
n11: .asciz "removed-with-its-lf-already(not-recorded)"
o11: .asciz "b\n"
.p2align 3
cases:
    .quad n1, t1, o1, w1, 0
    .quad n2, t2, o2, w2, 0
    .quad n3, t3, o3, w3, 0
    .quad n4, t2, o4, w4, 0
    .quad n5, t5, o5, w5, 1
    .quad n6, t5, o5, w5, 0
    .quad n7, t7, o7, w7, 0
    .quad n8, t9, o8, w8, 0
    .quad n9, t9, o9, e0, 0
    .quad n10, t9, e0, w10, 0
    .quad n11, t9, o11, e0, 0
    .quad 0
