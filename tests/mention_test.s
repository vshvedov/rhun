# agentmention.s against the extension's own functions: each case of tests/data/mention-cases.txt ("text PATH
# TAB L0 TAB L1": the mention written for a path and lines; "chips PROMPT": the chip tokens of a sent prompt,
# "KIND:QUOTED:START-END:TARGET:L0:L1" each, "-" none), a line of output each. The golden,
# tests/data/mention.expected, was made by tools/mention-cases.js from the bundle (webview/index.js 2.1.328).
# \n, \t and \\ are escapes in the cases and in the output.
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
arg: .zero SB_SIZE
tgt: .zero SB_SIZE
tok: .zero 32
.text
FN main
    PROLOGUE 16
    lea rdi, [rip + .Lcases]
    call file_read_all
    test rax, rax
    jz 9f
    mov rbx, rax                # the cases
    lea r12, [rax + rdx]        # their end
1:  cmp rbx, r12
    jae 8f
    mov r13, rbx                # a line
2:  cmp rbx, r12
    jae 3f
    cmp byte ptr [rbx], 10
    je 3f
    inc rbx
    jmp 2b
3:  mov r14, rbx
    sub r14, r13                # its length
    inc rbx
    lea rdi, [rip + out]
    call sb_clear
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Ltext]
    mov ecx, 5
    call prefixed
    test eax, eax
    jnz 4f
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lchips]
    mov ecx, 6
    call prefixed
    test eax, eax
    jz 1b
    lea rdi, [r13 + 6]
    lea rsi, [r14 - 6]
    call chips
    jmp 7f
4:  lea rdi, [r13 + 5]
    lea rsi, [r14 - 5]
    call text
7:  lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    jmp 1b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# prefixed(ptr, len, word, n) -> eax 1 when the line starts with those n bytes
prefixed:
    xor eax, eax
    cmp rsi, rcx
    jb 9f
    mov rsi, rdx
    mov rdx, rcx
    jmp memeq
9:  ret

# unesc(ptr, len): arg holds the text with \n, \t and \\ made what they stand for
unesc:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rdi + rsi]
    lea rdi, [rip + arg]
    call sb_clear
1:  cmp rbx, r12
    jae 9f
    movzx esi, byte ptr [rbx]
    inc rbx
    cmp esi, '\\'
    jne 3f
    cmp rbx, r12
    jae 3f
    movzx esi, byte ptr [rbx]
    inc rbx
    cmp esi, 'n'
    jne 2f
    mov esi, 10
    jmp 3f
2:  cmp esi, 't'
    jne 21f
    mov esi, 9
    jmp 3f
21: cmp esi, '\\'
    je 3f
    push rsi                    # another: the backslash stays (as tools/mention-cases.js reads it)
    push rsi
    lea rdi, [rip + arg]
    mov esi, '\\'
    call sb_push_byte
    pop rsi
    pop rsi
3:  lea rdi, [rip + arg]
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# esc(ptr, len): appended to out with \, LF and TAB escaped
esc:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rdi + rsi]
1:  cmp rbx, r12
    jae 9f
    movzx r13d, byte ptr [rbx]
    inc rbx
    mov esi, r13d
    cmp r13d, '\\'
    je 2f
    cmp r13d, 10
    jne 3f
    mov r13d, 'n'
    jmp 2f
3:  cmp r13d, 9
    jne 4f
    mov r13d, 't'
2:  lea rdi, [rip + out]
    mov esi, '\\'
    call sb_push_byte
    mov esi, r13d
4:  lea rdi, [rip + out]
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# text(ptr, len): "PATH TAB L0 TAB L1" -> the mention, or "refused"
text:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d              # the path's end
1:  cmp r13, r12
    jae 2f
    cmp byte ptr [rbx + r13], 9
    je 2f
    inc r13
    jmp 1b
2:  lea rdi, [rbx + r13 + 1]
    mov rsi, 12
    call parse_u64
    mov r14d, eax
    lea rdi, [rbx + r13 + 1]
3:  cmp byte ptr [rdi], 9
    je 4f
    inc rdi
    jmp 3b
4:  inc rdi
    mov rsi, 12
    call parse_u64
    mov r15d, eax
    mov rdi, rbx
    mov rsi, r13
    call unesc
    lea rdi, [rip + tgt]
    call sb_clear
    lea rdi, [rip + tgt]
    mov rsi, [rip + arg + SB_ptr]
    mov rdx, [rip + arg + SB_len]
    mov ecx, r14d
    mov r8d, r15d
    call agmention_text
    test eax, eax
    jz 5f
    mov rdi, [rip + tgt + SB_ptr]
    mov rsi, [rip + tgt + SB_len]
    call esc
    EPILOGUE
5:  lea rdi, [rip + out]
    lea rsi, [rip + .Lrefused]
    call sb_push_cstr
    EPILOGUE

# chips(ptr, len): the prompt's chip tokens
chips:
    PROLOGUE 16
    call unesc
    mov rbx, [rip + arg + SB_ptr]
    mov r12, [rip + arg + SB_len]
    xor r13d, r13d              # from
    xor r14d, r14d              # found
1:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    lea rcx, [rip + tok]
    call agmention_next
    test eax, eax
    jz 8f
    test r14d, r14d
    jz 2f
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
2:  inc r14d
    lea rdi, [rip + out]
    mov esi, [rip + tok + 16]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, [rip + tok + 20]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [rip + tok]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, '-'
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [rip + tok + 8]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + tgt]
    call sb_clear
    mov rax, [rip + tok]
    lea rdi, [rbx + rax]
    mov rsi, [rip + tok + 8]
    sub rsi, rax
    lea rdx, [rip + tgt]
    call agmention_target
    mov r15d, eax
    mov [rsp], edx
    mov rdi, [rip + tgt + SB_ptr]
    mov rsi, [rip + tgt + SB_len]
    call esc
    lea rdi, [rip + out]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, r15d
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, [rsp]
    call sb_push_u64
    mov r13, [rip + tok + 8]
    jmp 1b
8:  test r14d, r14d
    jnz 9f
    lea rdi, [rip + out]
    mov esi, '-'
    call sb_push_byte
9:  EPILOGUE

.section .rodata
.Lcases: .asciz "tests/data/mention-cases.txt"
.Ltext: .ascii "text "
.Lchips: .ascii "chips "
.Lrefused: .asciz "refused"
