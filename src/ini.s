# line-based "key = value" reader with [sections] and # comments
.include "rhun.inc"

.text

# ini_init(it, ptr, len)
FN ini_init
    mov [rdi + INI_p], rsi
    add rsi, rdx
    mov [rdi + INI_end], rsi
    xor eax, eax
    mov [rdi + INI_sec], rax
    mov [rdi + INI_seclen], rax
    ret

# trim(ptr, len) -> rax ptr, rdx len (spaces/tabs/CR)
FN trim
    mov rax, rdi
    mov rdx, rsi
1:  test rdx, rdx
    jz 3f
    movzx ecx, byte ptr [rax]
    cmp cl, ' '
    je 2f
    cmp cl, 9
    je 2f
    cmp cl, 13
    jne 4f
2:  inc rax
    dec rdx
    jmp 1b
4:  movzx ecx, byte ptr [rax + rdx - 1]
    cmp cl, ' '
    je 5f
    cmp cl, 9
    je 5f
    cmp cl, 13
    jne 3f
5:  dec rdx
    jnz 4b
3:  ret

# ini_next(it) -> 1 when key/value filled, 0 at end; a [section] line may end in a # comment
FN ini_next
    push rbx
    push r12
    push r13
    mov rbx, rdi
.Lin_line:
    mov r12, [rbx + INI_p]
    mov r13, [rbx + INI_end]
    cmp r12, r13
    jae .Lin_end
    # find end of line
    mov rcx, r12
1:  cmp rcx, r13
    jae 2f
    cmp byte ptr [rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  lea rax, [rcx + 1]
    cmp rax, r13
    jbe 3f
    mov rax, r13
3:  mov [rbx + INI_p], rax
    mov rdi, r12
    mov rsi, rcx
    sub rsi, r12
    call trim
    test rdx, rdx
    jz .Lin_line
    movzx ecx, byte ptr [rax]
    cmp cl, '#'
    je .Lin_line
    cmp cl, ';'
    je .Lin_line
    cmp cl, '['
    jne .Lin_kv
    # a section: the first ']' outside quotes that only blanks or a # comment follow
    xor r8d, r8d                # the open quote, 0 outside one
    mov ecx, 1
6:  cmp rcx, rdx
    jae 12f
    movzx r9d, byte ptr [rax + rcx]
    test r8d, r8d
    jz 7f
    cmp r9d, r8d                # inside a quote
    jne 61f
    xor r8d, r8d
    jmp 11f
61: cmp r8d, 34
    jne 11f
    cmp r9d, 92                 # a backslash in "...": the next byte is escaped
    jne 11f
    inc rcx
    jmp 11f
7:  cmp r9d, 34
    je 71f
    cmp r9d, 39
    jne 8f
71: mov r8d, r9d
    jmp 11f
8:  cmp r9d, ']'
    jne 11f
    lea r10, [rcx + 1]
9:  cmp r10, rdx
    jae 10f
    movzx r11d, byte ptr [rax + r10]
    cmp r11d, '#'
    je 10f
    cmp r11d, ' '
    je 91f
    cmp r11d, 9
    jne 11f
91: inc r10
    jmp 9b
10: lea rdi, [rax + 1]
    lea rsi, [rcx - 1]
    jmp 13f
11: inc rcx
    jmp 6b
12: cmp byte ptr [rax + rdx - 1], ']'   # unbalanced quotes: the line's last ']' as before
    jne .Lin_kv
    lea rdi, [rax + 1]
    lea rsi, [rdx - 2]
13: call trim
    mov [rbx + INI_sec], rax
    mov [rbx + INI_seclen], rdx
    jmp .Lin_line
.Lin_kv:
    # split at first '='
    mov r12, rax
    mov r13, rdx
    xor ecx, ecx
4:  cmp rcx, r13
    jae .Lin_line
    cmp byte ptr [r12 + rcx], '='
    je 5f
    inc rcx
    jmp 4b
5:  push rcx
    mov rdi, r12
    mov rsi, rcx
    call trim
    mov [rbx + INI_key], rax
    mov [rbx + INI_keylen], rdx
    pop rcx
    lea rdi, [r12 + rcx + 1]
    mov rsi, r13
    sub rsi, rcx
    dec rsi
    call trim
    mov [rbx + INI_val], rax
    mov [rbx + INI_vallen], rdx
    mov eax, 1
    jmp .Lin_ret
.Lin_end:
    xor eax, eax
.Lin_ret:
    pop r13
    pop r12
    pop rbx
    ret

# ini_key_is(it, cstr) -> 1 if key equals
FN ini_key_is
    mov rdx, rsi
    mov rsi, [rdi + INI_keylen]
    mov rdi, [rdi + INI_key]
    jmp str_eq_cstr

# ini_sec_is(it, cstr) -> 1 if section equals
FN ini_sec_is
    mov rdx, rsi
    mov rsi, [rdi + INI_seclen]
    mov rdi, [rdi + INI_sec]
    jmp str_eq_cstr

# next_word(ptr, len) -> rax word ptr, rdx word len, rcx = bytes consumed (for iterating space separated lists)
FN next_word
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 3f
    cmp byte ptr [rdi + rcx], ' '
    je 2f
    cmp byte ptr [rdi + rcx], 9
    jne 3f
2:  inc rcx
    jmp 1b
3:  lea rax, [rdi + rcx]
    xor edx, edx
4:  cmp rcx, rsi
    jae 5f
    movzx r8d, byte ptr [rdi + rcx]
    cmp r8b, ' '
    je 5f
    cmp r8b, 9
    je 5f
    inc rcx
    inc rdx
    jmp 4b
5:  ret

# parse_color("#rrggbb" or "#rrggbbaa", len) -> eax argb, edx = 1 ok
FN parse_color
    xor edx, edx
    cmp rsi, 7
    jb 9f
    cmp byte ptr [rdi], '#'
    jne 9f
    push rsi
    inc rdi
    dec rsi
    call parse_hex
    pop rsi
    cmp rsi, 7
    je 1f
    cmp rsi, 9
    jne 9f
    # rrggbbaa -> aarrggbb
    mov ecx, eax
    shr eax, 8
    shl ecx, 24
    or eax, ecx
    mov edx, 1
    ret
1:  or eax, 0xff000000
    mov edx, 1
9:  ret

# parse_bool(ptr, len) -> 1 for yes/true/on/1
FN parse_bool
    xor eax, eax
    test rsi, rsi
    jz 1f
    movzx ecx, byte ptr [rdi]
    or ecx, 0x20
    cmp ecx, 'y'
    je 2f
    cmp ecx, 't'
    je 2f
    cmp ecx, '1'
    je 2f
    cmp ecx, 'o'
    jne 1f
    cmp rsi, 2
    jne 1f
    movzx ecx, byte ptr [rdi + 1]
    or ecx, 0x20
    cmp ecx, 'n'
    jne 1f
2:  mov eax, 1
1:  ret
