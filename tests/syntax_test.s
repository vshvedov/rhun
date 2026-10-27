# tokenizes sample lines with built-in grammars; prints one class digit (base 36) per byte
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
cls: .zero 512
.text
# run(grammar name cstr, line cstr, state) -> end state
run:
    PROLOGUE
    mov r12, rsi
    mov r13d, edx
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call syntax_by_name
    mov r14, rax
    mov rdi, r12
    call strlen
    mov r15, rax
    mov rdi, r14
    mov rsi, r12
    mov rdx, r15
    mov ecx, r13d
    lea r8, [rip + cls]
    call tokenize
    mov r13d, eax
    lea rdi, [rip + out]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    xor ebx, ebx
1:  cmp rbx, r15
    jae 2f
    lea rax, [rip + cls]
    movzx eax, byte ptr [rax + rbx]
    lea rcx, [rip + digits]
    movzx esi, byte ptr [rcx + rax]
    lea rdi, [rip + out]
    call sb_push_byte
    inc rbx
    jmp 1b
2:  lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov eax, r13d
    EPILOGUE

.macro T lang, text, state=0
    lea rdi, [rip + 1f]
    lea rsi, [rip + 2f]
    mov edx, \state
    call run
    .pushsection .rodata
1:  .asciz "\lang"
2:  .asciz "\text"
    .popsection
.endm

FN main
    PROLOGUE
    call syntax_load_all
    T Python, "def f(self, x=1.5e-3): return 'a\\'b' # hi"
    T Python, "@dataclass class Point(Base): None"
    T Python, "s = \"\"\"doc"
    mov edx, eax
    lea rdi, [rip + py]
    lea rsi, [rip + l3]
    call run
    T C, "#include <stdio.h> /* c */ int main(void) { return 0x1F; }"
    T C, "   still in comment */ x", 1
    T Assembly, "FN main: mov rax, [rip + g_x] # c"
    T Assembly, ".Lfoo: .quad 0 ; nasm"
    T HTML, "<div class=\"x\">a &amp; b</div><!-- c -->"
    T Markdown, "# Title with `code`"
    T Shell, "echo \"$HOME\" | grep -v x # c"
    T Markdown, "`comment` and **bold** [link](x)"
    T Markdown, "```sh"
    T Markdown, "inside fence", 1
    T Shell, "if [[ $# -gt 0 ]]; then"
    T Shell, "if [[ ${#mcmx[@]} -lt 2 ]]; then"
    T Shell, "sleep 10 # sleep 10 second"
    T Python, "x=1#c"
    mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE
.section .rodata
digits: .ascii "0123456789abcdefghijklmnop"
py: .asciz "Python"
l3: .asciz "more\"\"\" x"
