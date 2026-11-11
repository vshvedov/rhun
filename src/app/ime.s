# ime: the text an input method composes (preedit) and commits, for backends whose protocol hands
# rhun the strings: Wayland's text-input-v3 and X11's XIM. Committed text is typed like keys; the
# composition is drawn at the editor's caret, over the text after it, until the method commits.
.include "rhun.inc"

.equ PREEDIT_MAX, 256

.bss
.globl g_preedit_len
g_preedit_len: .long 0
preedit: .zero PREEDIT_MAX

.text

# ime_commit(ptr, len): each character as a typed key, controls left out
FN ime_commit
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
1:  test r12, r12
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    call utf8_decode
    add rbx, rdx
    sub r12, rdx
    cmp eax, 0x20
    jb 1b
    cmp eax, 0x7f
    jb 2f
    cmp eax, 0xa0
    jb 1b
2:  mov esi, eax
    mov edi, eax
    cmp eax, 0x100
    jb 3f
    or edi, 0x1000000           # Unicode keysym
3:  xor edx, edx
    call app_on_key
    jmp 1b
9:  EPILOGUE

# ime_preedit(ptr, len): the composition now (len 0: none). Longer than PREEDIT_MAX bytes, it is
# cut at a character boundary.
FN ime_preedit
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, PREEDIT_MAX
    jbe 2f
    mov r12d, PREEDIT_MAX
1:  test r12, r12
    jz 2f
    movzx eax, byte ptr [rbx + r12]
    and eax, 0xc0
    cmp eax, 0x80
    jne 2f
    dec r12
    jmp 1b
2:  cmp r12d, [rip + g_preedit_len]
    jne 3f
    test r12, r12
    jz 9f
3:  lea rdi, [rip + preedit]
    mov rsi, rbx
    mov rdx, r12
    call memcpy
    mov [rip + g_preedit_len], r12d
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# ime_preedit_text() -> rax bytes, rdx length: the composition now
FN ime_preedit_text
    lea rax, [rip + preedit]
    mov edx, [rip + g_preedit_len]
    ret

# ime_preedit_draw() -> eax: the composition at the editor's caret, underlined on the background
# it covers; the x after it, where the caret goes
FN ime_preedit_draw
    PROLOGUE 16
    lea rdi, [rip + g_face_code]
    lea rsi, [rip + preedit]
    mov edx, [rip + g_preedit_len]
    call text_width
    mov ebx, eax
    mov edi, [rip + g_caret_x]
    mov esi, [rip + g_caret_y]
    mov edx, ebx
    mov ecx, [rip + g_lh]
    COLOR r8d, T_BG
    call gfx_fill
    lea rdi, [rip + g_face_code]
    mov esi, [rip + g_caret_x]
    mov edx, [rip + g_caret_y]
    add edx, [rip + g_base]
    lea rcx, [rip + preedit]
    mov r8d, [rip + g_preedit_len]
    COLOR r9d, T_FG
    call text_draw
    M ecx, MI_1
    mov edi, [rip + g_caret_x]
    mov esi, [rip + g_caret_y]
    add esi, [rip + g_lh]
    sub esi, ecx
    mov edx, ebx
    COLOR r8d, T_FG
    call gfx_fill
    mov eax, [rip + g_caret_x]
    add eax, ebx
    EPILOGUE
