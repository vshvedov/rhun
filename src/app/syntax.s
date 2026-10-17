# syntax highlighting: grammar files (runtime/syntax/*.syn) and a per-line tokenizer
.include "rhun.inc"

STRUCT
F W_ptr, 8
F W_len, 4
F W_class, 4
ENDSTRUCT W_SIZE

STRUCT
F LR_prefix, 16
F LR_len, 4
F LR_class, 4
ENDSTRUCT LR_SIZE

.data
.p2align 3
.globl g_user_grammars
g_user_grammars: .quad 0        # grammars from ~/.config and extensions, at the front of g_grammars
ext_grammars: .quad 0           # how many of those came from extensions (the last ones of them)

.bss
.p2align 3
tk_i: .quad 0
tk_bol: .quad 0
tk_a: .quad 0
tk_b: .quad 0
tk_end: .long 0
tk_intag: .long 0
tk_c: .long 0
.p2align 3
.globl g_grammars
g_grammars: .zero VEC_SIZE      # GR* items
it: .zero INI_SIZE
.globl g_grammars_parsed, g_grammar_warnings
g_grammars_parsed: .long 0      # built-in grammars parsed so far (they are parsed when first used)
g_grammar_warnings: .long 0     # unknown keys and class names the parser met

.text

# class_by_name(ptr, len) -> class or -1
class_by_name:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp ebx, C_COUNT
    jae 2f
    lea rax, [rip + class_names]
    mov rdx, [rax + rbx*8]
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 3f
    inc ebx
    jmp 1b
2:  mov ebx, -1
3:  mov eax, ebx
    pop r13
    pop r12
    pop rbx
    ret

# word_hash(ptr, len, nocase) -> eax
word_hash:
    mov eax, 2166136261
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 3f
    movzx r8d, byte ptr [rdi + rcx]
    test edx, edx
    jz 2f
    lea r9d, [r8 - 'A']
    cmp r9d, 25
    ja 2f
    or r8d, 0x20
2:  xor eax, r8d
    imul eax, eax, 16777619
    inc rcx
    jmp 1b
3:  ret

# gr_word_slot(gr, ptr, len) -> rax slot ptr (W entry: empty or matching)
gr_word_slot:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, [rbx + GR_flags]
    and edx, GF_NOCASE
    call word_hash
    mov r14, [rbx + GR_wcap]
    dec r14
    and rax, r14
    mov r15, rax
1:  imul rax, r15, W_SIZE
    add rax, [rbx + GR_words]
    cmp qword ptr [rax + W_ptr], 0
    je 9f
    mov ecx, [rax + W_len]
    cmp rcx, r13
    jne 2f
    push rax
    mov rdi, [rax + W_ptr]
    mov rsi, r13
    mov rdx, r12
    mov rcx, r13
    test qword ptr [rbx + GR_flags], GF_NOCASE
    jz 11f
    call str_ieq
    jmp 12f
11: call str_eq
12: mov ecx, eax
    pop rax
    test ecx, ecx
    jnz 9f
2:  inc r15
    and r15, r14
    jmp 1b
9:  EPILOGUE

# gr_add_word(gr, ptr, len, class)
gr_add_word:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
    # grow at 50% load
    mov rax, [rbx + GR_wn]
    add rax, rax
    cmp rax, [rbx + GR_wcap]
    jb 1f
    call gr_grow
1:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call gr_word_slot
    mov r14, rax
    cmp qword ptr [r14 + W_ptr], 0
    jne 2f
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [r14 + W_ptr], rax
    mov [r14 + W_len], r13d
    inc qword ptr [rbx + GR_wn]
2:  mov eax, [rsp]
    mov [r14 + W_class], eax
    EPILOGUE

gr_grow:
    PROLOGUE
    mov r12, [rbx + GR_words]
    mov r13, [rbx + GR_wcap]
    lea r14, [r13 + r13]
    mov eax, 64
    cmp r14, rax
    cmovb r14, rax
    imul rdi, r14, W_SIZE
    call mem_alloc
    mov [rbx + GR_words], rax
    mov [rbx + GR_wcap], r14
    xor r15d, r15d
1:  cmp r15, r13
    jae 2f
    imul rax, r15, W_SIZE
    add rax, r12
    cmp qword ptr [rax + W_ptr], 0
    je 3f
    push rax
    push rax
    mov rdi, rbx
    mov rsi, [rax + W_ptr]
    mov edx, [rax + W_len]
    call gr_word_slot
    pop rcx
    pop rcx
    mov rdx, [rcx]
    mov [rax], rdx
    mov rdx, [rcx + 8]
    mov [rax + 8], rdx
3:  inc r15
    jmp 1b
2:  mov rdi, r12
    call mem_free
    EPILOGUE

# add_words(gr, ptr, len, class): space separated list
add_words:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
1:  test r13, r13
    jz 9f
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 9f
    mov rdi, rbx
    mov rsi, rax
    mov ecx, [rsp]
    call gr_add_word
    jmp 1b
9:  EPILOGUE

# copy_token(dst16, ptr, len) -> len clipped to 15
copy_token:
    cmp rdx, 15
    jbe 1f
    mov edx, 15
1:  mov rcx, rdx
    push rdx
    rep movsb
    mov byte ptr [rdi], 0
    pop rax
    ret

# add_region(gr, start, slen, end, elen, class, flags(esc | multi<<8 | bol<<9))
add_region:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp], r9d
    lea rdi, [rbx + GR_regions]
    mov esi, REG_SIZE
    call vec_push
    mov [rsp + 8], rax
    lea rdi, [rax + REG_start]
    mov rsi, r12
    mov rdx, r13
    call copy_token
    mov rcx, [rsp + 8]
    mov [rcx + REG_slen], al
    lea rdi, [rcx + REG_end]
    mov rsi, r14
    mov rdx, r15
    call copy_token
    mov rcx, [rsp + 8]
    mov [rcx + REG_elen], al
    mov eax, [rsp]
    mov [rcx + REG_class], al
    movzx eax, byte ptr [rcx + REG_start]
    mov byte ptr [rbx + GR_rstart + rax], 1
    mov eax, [rbp + 16]
    mov [rcx + REG_esc], al
    shr eax, 8
    mov edx, eax
    and edx, 1
    mov [rcx + REG_multi], dl
    shr eax, 1
    and eax, 1
    mov [rcx + REG_bol], al
    EPILOGUE

# grammar_parse(text, len) -> GR*
FN grammar_parse
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov edi, GR_SIZE
    call mem_alloc
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call grammar_fill
    EPILOGUE

# grammar_fill(gr, text, len) -> gr: the grammar in text, into gr
FN grammar_fill
    PROLOGUE 96
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov qword ptr [rbx + GR_flags], GF_FUNCS | GF_NUMBERS | GF_OPS
    lea rax, [rip + .Lnone]
    mov [rbx + GR_name], rax
    mov [rbx + GR_files], rax
    mov [rbx + GR_first], rax
    mov [rbx + GR_icon], rax
    mov qword ptr [rbx + GR_ficon], 0
    lea rdi, [rip + it]
    mov rsi, r12
    mov rdx, r13
    call ini_init
.Lgp_next:
    lea rdi, [rip + it]
    call ini_next
    test eax, eax
    jz .Lgp_done
    mov r14, [rip + it + INI_val]
    mov r15, [rip + it + INI_vallen]
    lea rsi, [rip + .Lk_name]
    call .Lgp_key
    jnz .Lgp_name
    lea rsi, [rip + .Lk_files]
    call .Lgp_key
    jnz .Lgp_files
    lea rsi, [rip + .Lk_first]
    call .Lgp_key
    jnz .Lgp_first
    lea rsi, [rip + .Lk_icon]
    call .Lgp_key
    jnz .Lgp_icon
    lea rsi, [rip + .Lk_comment]
    call .Lgp_key
    jnz .Lgp_comment
    lea rsi, [rip + .Lk_toggle]
    call .Lgp_key
    jnz .Lgp_toggle
    lea rsi, [rip + .Lk_block]
    call .Lgp_key
    jnz .Lgp_block
    lea rsi, [rip + .Lk_string]
    call .Lgp_key
    jnz .Lgp_string
    lea rsi, [rip + .Lk_mstring]
    call .Lgp_key
    jnz .Lgp_mstring
    lea rsi, [rip + .Lk_region]
    call .Lgp_key
    jnz .Lgp_region
    lea rsi, [rip + .Lk_line]
    call .Lgp_key
    jnz .Lgp_line
    lea rsi, [rip + .Lk_ident]
    call .Lgp_key
    jnz .Lgp_ident
    lea rsi, [rip + .Lk_prefix]
    call .Lgp_key
    jnz .Lgp_prefix
    lea rsi, [rip + .Lk_case]
    call .Lgp_key
    jz 1f
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lv_insensitive]
    call str_eq_cstr
    test eax, eax
    jz .Lgp_next
    or qword ptr [rbx + GR_flags], GF_NOCASE
    jmp .Lgp_next
1:  # boolean flags
    lea rsi, [rip + .Lk_functions]
    mov r8d, GF_FUNCS
    call .Lgp_flag
    test eax, eax
    jnz .Lgp_next
    lea rsi, [rip + .Lk_captypes]
    mov r8d, GF_CAPTYPES
    call .Lgp_flag
    test eax, eax
    jnz .Lgp_next
    lea rsi, [rip + .Lk_markup]
    mov r8d, GF_MARKUP
    call .Lgp_flag
    test eax, eax
    jnz .Lgp_next
    lea rsi, [rip + .Lk_labels]
    mov r8d, GF_LABELS
    call .Lgp_flag
    test eax, eax
    jnz .Lgp_next
    lea rsi, [rip + .Lk_numbers]
    mov r8d, GF_NUMBERS
    call .Lgp_flag
    test eax, eax
    jnz .Lgp_next
    lea rsi, [rip + .Lk_operators]
    mov r8d, GF_OPS
    call .Lgp_flag
    test eax, eax
    jnz .Lgp_next
    lea rsi, [rip + .Lk_colon]
    mov r8d, GF_COLON
    call .Lgp_flag
    test eax, eax
    jnz .Lgp_next
    # word lists: "<class>s = words" e.g. keywords, types, constants, builtins, attributes, variables, tags, preprocs
    mov rdi, [rip + it + INI_key]
    mov rsi, [rip + it + INI_keylen]
    cmp rsi, 2
    jb .Lgp_warn
    cmp byte ptr [rdi + rsi - 1], 's'
    jne .Lgp_warn
    dec rsi
    call class_by_name
    test eax, eax
    js .Lgp_warn
    mov ecx, eax
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call add_words
    jmp .Lgp_next

.Lgp_warn:
    inc dword ptr [rip + g_grammar_warnings]
    jmp .Lgp_next
.Lgp_name:
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov [rbx + GR_name], rax
    jmp .Lgp_next
.Lgp_files:
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov [rbx + GR_files], rax
    jmp .Lgp_next
.Lgp_first:
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov [rbx + GR_first], rax
    jmp .Lgp_next
.Lgp_icon:
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov [rbx + GR_icon], rax
    jmp .Lgp_next
.Lgp_toggle:
    # toggle_comment = <token> ; only the toggle-comment token, for comments that count only at a
    # line's start (colored by a bol region): no region of its own
    mov dword ptr [rsp + 16], 0
    jmp 1f
.Lgp_comment:
    # comment = <token> ; also the toggle-comment token (the first comment or toggle_comment wins)
    mov dword ptr [rsp + 16], 1
1:  mov rdi, r14
    mov rsi, r15
    call next_word
    test rdx, rdx
    jz .Lgp_next
    mov [rsp], rax
    mov [rsp + 8], rdx
    cmp qword ptr [rbx + GR_commentlen], 0
    jne 2f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rbx + GR_comment], rax
    mov rax, [rsp + 8]
    mov [rbx + GR_commentlen], rax
2:  cmp dword ptr [rsp + 16], 0
    je .Lgp_next
    mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, C_COMMENT
    push 0
    push 0
    call add_region
    add rsp, 16
    jmp .Lgp_next
.Lgp_block:
    # block = start end [class]
    call .Lgp_words3
    mov r9d, C_COMMENT
    mov rax, [rsp + 40]
    test rax, rax
    jz 3f
    mov rdi, [rsp + 32]
    mov rsi, rax
    call class_by_name
    test eax, eax
    js 32f
    mov r9d, eax
    jmp 3f
32: inc dword ptr [rip + g_grammar_warnings]
    mov r9d, C_COMMENT
3:  mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    mov r8, [rsp + 24]
    push 0x100
    push 0x100
    call add_region
    add rsp, 16
    jmp .Lgp_next
.Lgp_string:
    xor eax, eax
    jmp 4f
.Lgp_mstring:
    mov eax, 0x100
4:  mov [rsp + 48], eax
    # string = delim [escape]
    call .Lgp_words3
    xor ecx, ecx
    cmp qword ptr [rsp + 24], 0
    je 5f
    mov rax, [rsp + 16]
    movzx ecx, byte ptr [rax]
5:  or ecx, [rsp + 48]
    mov [rsp + 56], ecx
    mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    mov rcx, [rsp]
    mov r8, [rsp + 8]
    mov r9d, C_STRING
    mov eax, [rsp + 56]
    push rax
    push rax
    call add_region
    add rsp, 16
    jmp .Lgp_next
.Lgp_region:
    # region = start end class [multiline] [bol] [escape=X]
    call .Lgp_words3
    mov rdi, [rsp + 32]
    mov rsi, [rsp + 40]
    call class_by_name
    test eax, eax
    js .Lgp_warn
    mov [rsp + 48], eax
    # flags from the rest of the value
    xor ecx, ecx
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lv_multiline]
    push rcx
    mov ecx, 9
    call str_find
    pop rcx
    test rax, rax
    js 6f
    or ecx, 0x100
6:  push rcx
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lv_bol]
    mov ecx, 3
    call str_find
    pop rcx
    test rax, rax
    js 7f
    or ecx, 0x200
7:  push rcx
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lv_escape]
    mov ecx, 7
    call str_find
    pop rcx
    test rax, rax
    js 8f
    movzx eax, byte ptr [r14 + rax + 7]
    or ecx, eax
8:  mov [rsp + 56], ecx
    # "eol" as end means end of line
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    lea rdx, [rip + .Lv_eol]
    call str_eq_cstr
    test eax, eax
    jz 9f
    mov qword ptr [rsp + 24], 0
9:  mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    mov r8, [rsp + 24]
    mov r9d, [rsp + 48]
    mov eax, [rsp + 56]
    push rax
    push rax
    call add_region
    add rsp, 16
    jmp .Lgp_next
.Lgp_line:
    # line = prefix class
    call .Lgp_words3
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    call class_by_name
    test eax, eax
    js .Lgp_warn
    mov [rsp + 48], eax
    lea rdi, [rbx + GR_lines]
    mov esi, LR_SIZE
    call vec_push
    mov [rsp + 56], rax
    lea rdi, [rax + LR_prefix]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call copy_token
    mov rcx, [rsp + 56]
    mov [rcx + LR_len], eax
    mov eax, [rsp + 48]
    mov [rcx + LR_class], eax
    jmp .Lgp_next
.Lgp_ident:
    lea rdi, [rbx + GR_identx]
    jmp 10f
.Lgp_prefix:
    lea rdi, [rbx + GR_prefixes]
10: mov rsi, r14
    mov rdx, r15
    cmp rdx, 30
    jbe 11f
    mov edx, 30
11: mov rcx, rdx
    rep movsb
    mov byte ptr [rdi], 0
    jmp .Lgp_next
.Lgp_done:
    xor ecx, ecx
1:  mov edi, ecx
    push rcx
    push rcx
    call is_ident
    pop rcx
    pop rcx
    mov [rbx + GR_wchar + rcx], al
    inc ecx
    cmp ecx, 256
    jb 1b
    lea rsi, [rbx + GR_identx]
2:  movzx eax, byte ptr [rsi]
    test eax, eax
    jz 3f
    mov byte ptr [rbx + GR_wchar + rax], 1
    inc rsi
    jmp 2b
3:  mov rax, rbx
    EPILOGUE

# helpers for grammar_parse (use caller frame: [rsp+8..] after return address)
# .Lgp_key: ZF clear (jnz) if the current key equals cstr rsi
.Lgp_key:
    lea rdi, [rip + it]
    call ini_key_is
    test eax, eax
    ret
# .Lgp_flag: key rsi -> set/clear flag r8 by boolean value
.Lgp_flag:
    push r8
    lea rdi, [rip + it]
    call ini_key_is
    pop r8
    test eax, eax
    jz 1f
    push r8
    mov rdi, r14
    mov rsi, r15
    call parse_bool
    pop r8
    test eax, eax
    jz 2f
    or [rbx + GR_flags], r8
    mov eax, 1
    ret
2:  not r8
    and [rbx + GR_flags], r8
    mov eax, 1
1:  ret
# .Lgp_words3: split value into up to 3 words -> caller [rsp+0..48) = (ptr,len) x3
.Lgp_words3:
    push r12
    push r13
    lea r12, [rsp + 24]         # caller's rsp
    xor eax, eax
    mov [r12], rax
    mov [r12 + 8], rax
    mov [r12 + 16], rax
    mov [r12 + 24], rax
    mov [r12 + 32], rax
    mov [r12 + 40], rax
    mov rdi, r14
    mov rsi, r15
    xor r13d, r13d
1:  cmp r13d, 3
    jae 2f
    push rdi
    push rsi
    call next_word
    pop rsi
    pop rdi
    add rdi, rcx
    sub rsi, rcx
    test rdx, rdx
    jz 2f
    mov rcx, r13
    shl rcx, 4
    mov [r12 + rcx], rax
    mov [r12 + rcx + 8], rdx
    inc r13d
    jmp 1b
2:  pop r13
    pop r12
    ret

# syntax_load_all(): built-in grammars (registered, parsed when first used), then
# ~/.config/rhun/syntax/*.syn (parsed; user files override by name)
FN syntax_load_all
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + syntax_count]
    jae 2f
    mov edi, GR_SIZE
    call mem_alloc
    mov r12, rax
    imul rcx, rbx, 56
    lea rax, [rip + syntax_table]
    add rcx, rax
    mov rax, [rcx + 8]
    mov [r12 + GR_src], rax
    mov rdx, [rcx + 16]
    sub rdx, rax
    mov [r12 + GR_srclen], rdx
    mov rax, [rcx + 24]
    mov [r12 + GR_name], rax
    mov rax, [rcx + 32]
    mov [r12 + GR_files], rax
    mov rax, [rcx + 40]
    mov [r12 + GR_first], rax
    mov rax, [rcx + 48]
    mov [r12 + GR_icon], rax
    lea rdi, [rip + g_grammars]
    mov esi, 8
    call vec_push
    mov [rax], r12
    inc rbx
    jmp 1b
2:  lea rdi, [rip + .Lsyntax_dir]
    lea rsi, [rip + .Lsyn_ext]
    lea rdx, [rip + load_user_grammar]
    call config_dir_each
    EPILOGUE

# syntax_add_dir(dir): the .syn files of a folder (an extension's); they go after the user's
# grammars and before the built-in ones
FN syntax_add_dir
    lea rsi, [rip + .Lsyn_ext]
    lea rdx, [rip + load_ext_grammar]
    jmp dir_each_suffix

load_ext_grammar:
    PROLOGUE
    call file_read_all
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call grammar_parse
    mov r12, rax
    # an extension's grammar of a name another extension's grammar has (the same extension
    # installed again, or updated) takes that one's place; the user's own still win
    mov r13, [rip + g_user_grammars]
    sub r13, [rip + ext_grammars]
3:  cmp r13, [rip + g_user_grammars]
    jae 4f
    mov rax, [rip + g_grammars + VEC_ptr]
    mov rax, [rax + r13*8]
    mov rdi, [rax + GR_name]
    mov rsi, [r12 + GR_name]
    inc r13
    test rdi, rdi
    jz 3b
    test rsi, rsi
    jz 3b
    call strcmp_eq
    test eax, eax
    jz 3b
    mov rax, [rip + g_grammars + VEC_ptr]
    mov [rax + r13*8 - 8], r12
    jmp 9f
4:  lea rdi, [rip + g_grammars]
    mov esi, 8
    call vec_push
    # shift the entries from the insertion point right, put the new one there
    mov rcx, [rip + g_grammars + VEC_len]
    mov rdi, [rip + g_grammars + VEC_ptr]
    mov rdx, [rip + g_user_grammars]
1:  dec rcx
    cmp rcx, rdx
    jbe 2f
    mov rax, [rdi + rcx*8 - 8]
    mov [rdi + rcx*8], rax
    jmp 1b
2:  mov [rdi + rdx*8], r12
    inc qword ptr [rip + g_user_grammars]
    inc qword ptr [rip + ext_grammars]
9:  EPILOGUE

# user grammar: inserted first so it wins detection
load_user_grammar:
    PROLOGUE
    call file_read_all
    test rax, rax
    jz 9f
    inc qword ptr [rip + g_user_grammars]
    mov rdi, rax
    mov rsi, rdx
    call grammar_parse
    mov r12, rax
    lea rdi, [rip + g_grammars]
    mov esi, 8
    call vec_push
    # shift everything right, put new at 0
    mov rcx, [rip + g_grammars + VEC_len]
    mov rdi, [rip + g_grammars + VEC_ptr]
1:  dec rcx
    jz 2f
    mov rax, [rdi + rcx*8 - 8]
    mov [rdi + rcx*8], rax
    jmp 1b
2:  mov [rdi], r12
9:  EPILOGUE

# syntax_ready(gr or 0) -> gr: a built-in grammar is parsed the first time it is used
FN syntax_ready
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    mov rsi, [rbx + GR_src]
    test rsi, rsi
    jz 9f
    mov qword ptr [rbx + GR_src], 0
    mov rdi, rbx
    mov rdx, [rbx + GR_srclen]
    call grammar_fill
    inc dword ptr [rip + g_grammars_parsed]
9:  mov rax, rbx
    EPILOGUE

# pattern_match(name, nlen, pat, plen) -> 1 if "*.ext" suffix or exact name matches
FN pattern_match
    test rcx, rcx
    jz 3f
    cmp byte ptr [rdx], '*'
    jne 2f
    inc rdx
    dec rcx
    jmp str_ends
2:  jmp str_eq
3:  xor eax, eax
    ret

# syntax_for_name(name, len) -> GR* or 0, not parsed yet, rdx SN_EXACT for an exact name: the grammar
# whose files pattern fits the file name best (an exact name, else the longest *.suffix; the first on
# a tie, so user grammars win)
FN syntax_for_name
    PROLOGUE 32
    mov [rsp], rdi
    mov [rsp + 8], rsi
    xor ebx, ebx                # the best grammar so far
    mov qword ptr [rsp + 16], -1    # its score
    xor r12d, r12d
.Lsn_gr:
    cmp r12, [rip + g_grammars + VEC_len]
    jae .Lsn_done
    mov rax, [rip + g_grammars + VEC_ptr]
    mov r13, [rax + r12*8]
    mov r14, [r13 + GR_files]
    mov rdi, r14
    call strlen
    mov r15, rax
1:  test r15, r15
    jz 3f
    mov rdi, r14
    mov rsi, r15
    call next_word
    add r14, rcx
    sub r15, rcx
    test rdx, rdx
    jz 3f
    push rax
    push rdx
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    mov rcx, rdx
    mov rdx, rax
    call pattern_match
    pop rdx                     # the pattern's length
    pop rcx                     # the pattern
    test eax, eax
    jz 1b
    # an exact name beats any pattern, a longer suffix a shorter one
    mov rax, rdx
    cmp byte ptr [rcx], '*'
    je 2f
    mov eax, SN_EXACT
2:  cmp rax, [rsp + 16]
    jle 1b
    mov [rsp + 16], rax
    mov rbx, r13
    jmp 1b
3:  inc r12
    jmp .Lsn_gr
.Lsn_done:
    mov rax, rbx
    mov rdx, [rsp + 16]
    EPILOGUE

# syntax_detect(path cstr, first line ptr, len) -> GR* or 0, parsed: the grammar for the file name
# (syntax_for_name), else the grammar whose first_line word found in the first line is longest (the
# first grammar on a tie)
FN syntax_detect
    PROLOGUE 48
    mov [rsp + 16], rsi
    mov [rsp + 24], rdx
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call path_basename
    mov rdi, rax
    mov rsi, rdx
    call syntax_for_name
    mov r13, rax
    test r13, r13
    jnz .Lsd_found
.Lsd_first:
    # a first_line word found anywhere in the first line ("#!/usr/bin/env python3"): the longest
    # wins (tclsh over sh), the first grammar on a tie
    xor ebx, ebx
    mov qword ptr [rsp + 32], -1
    xor r12d, r12d
4:  cmp r12, [rip + g_grammars + VEC_len]
    jae 7f
    mov rax, [rip + g_grammars + VEC_ptr]
    mov r13, [rax + r12*8]
    mov r14, [r13 + GR_first]
    mov rdi, r14
    call strlen
    mov r15, rax
5:  test r15, r15
    jz 6f
    mov rdi, r14
    mov rsi, r15
    call next_word
    add r14, rcx
    sub r15, rcx
    test rdx, rdx
    jz 6f
    mov [rsp + 40], rdx
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    mov rcx, rdx
    mov rdx, rax
    call str_find
    test rax, rax
    js 5b
    mov rax, [rsp + 40]
    cmp rax, [rsp + 32]
    jle 5b
    mov [rsp + 32], rax
    mov rbx, r13
    jmp 5b
6:  inc r12
    jmp 4b
7:  mov r13, rbx
    test r13, r13
    jz .Lsd_none
.Lsd_found:
    mov rdi, r13
    call syntax_ready
    EPILOGUE
.Lsd_none:
    xor eax, eax
    EPILOGUE

# syntax_by_name(ptr, len) -> GR* or 0 (case-insensitive), parsed
FN syntax_by_name
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, [rip + g_grammars + VEC_len]
    jae 2f
    mov rax, [rip + g_grammars + VEC_ptr]
    mov r14, [rax + rbx*8]
    mov rdi, [r14 + GR_name]
    call strlen
    mov rdi, [r14 + GR_name]
    mov rsi, rax
    mov rdx, r12
    mov rcx, r13
    call str_ieq
    test eax, eax
    jnz 3f
    inc rbx
    jmp 1b
2:  xor eax, eax
    EPILOGUE
3:  mov rdi, r14
    call syntax_ready
    EPILOGUE

# ---- tokenizer ----

# is_word_char(gr, byte) -> 1 if part of identifiers
is_word_char:
    movzx esi, sil
    movzx eax, byte ptr [rdi + GR_wchar + rsi]
    ret

# tokenize(gr, text, len, state, out or 0) -> end state ; classes written per byte to out
# state: 0, or index+1 of a multi-line region still open at the line start
FN tokenize
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, r8
    mov qword ptr [rip + tk_i], 0
    mov dword ptr [rip + tk_end], 0
    mov dword ptr [rip + tk_intag], 0
    mov [rsp], ecx
    # first non-blank
    xor ecx, ecx
1:  cmp rcx, r13
    jae 2f
    cmp byte ptr [r12 + rcx], ' '
    je 11f
    cmp byte ptr [r12 + rcx], 9
    jne 2f
11: inc rcx
    jmp 1b
2:  mov [rip + tk_bol], rcx
    mov eax, [rsp]
    test eax, eax
    jz .Ltk_linerules
    dec eax
    imul rax, rax, REG_SIZE
    add rax, [rbx + GR_regions + VEC_ptr]
    mov r15, rax
    xor esi, esi
    call scan_region_end
    jmp .Ltk_main
.Ltk_linerules:
    xor ecx, ecx
3:  cmp rcx, [rbx + GR_lines + VEC_len]
    jae .Ltk_main
    imul rax, rcx, LR_SIZE
    add rax, [rbx + GR_lines + VEC_ptr]
    push rcx
    push rax
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rax + LR_prefix]
    mov ecx, [rax + LR_len]
    call str_starts
    pop rdx
    pop rcx
    test eax, eax
    jnz 4f
    inc rcx
    jmp 3b
4:  mov eax, [rdx + LR_class]
    xor esi, esi
    mov rdx, r13
    call mark
    jmp .Ltk_ret
.Ltk_main:
    mov rsi, [rip + tk_i]
    cmp rsi, r13
    jae .Ltk_ret
    cmp dword ptr [rip + tk_end], 0
    jne .Ltk_ret
    movzx eax, byte ptr [r12 + rsi]
    mov [rip + tk_c], eax
    cmp eax, ' '
    je .Ltk_blank
    cmp eax, 9
    je .Ltk_blank
    # regions, in file order (only when this byte can start one)
    cmp byte ptr [rbx + GR_rstart + rax], 0
    je .Ltk_noreg
    xor ecx, ecx
.Ltk_reg:
    cmp rcx, [rbx + GR_regions + VEC_len]
    jae .Ltk_noreg
    imul r15, rcx, REG_SIZE
    add r15, [rbx + GR_regions + VEC_ptr]
    cmp byte ptr [r15 + REG_bol], 0
    je 5f
    cmp rsi, [rip + tk_bol]
    jne 6f
5:  test qword ptr [rbx + GR_flags], GF_MARKUP
    jz 51f
    cmp byte ptr [r15 + REG_class], C_STRING
    jne 51f
    cmp dword ptr [rip + tk_intag], 0
    je 6f
51: push rcx
    push rsi
    lea rdi, [r12 + rsi]
    mov rax, r13
    sub rax, rsi
    mov rsi, rax
    lea rdx, [r15 + REG_start]
    movzx ecx, byte ptr [r15 + REG_slen]
    call str_starts
    pop rsi
    pop rcx
    test eax, eax
    jnz 7f
6:  inc rcx
    jmp .Ltk_reg
7:  movzx eax, byte ptr [r15 + REG_slen]
    add rsi, rax
    call scan_region_end
    jmp .Ltk_main
.Ltk_noreg:
    mov eax, [rip + tk_c]
    test qword ptr [rbx + GR_flags], GF_MARKUP
    jz .Ltk_prefix
    # <tag or </tag
    cmp eax, '<'
    jne 8f
    lea rcx, [rsi + 1]
    cmp rcx, r13
    jae 8f
    cmp byte ptr [r12 + rcx], '/'
    jne 81f
    inc rcx
81: mov [rip + tk_a], rcx
    mov rsi, rcx
    call word_end_dash
    cmp rdx, [rip + tk_a]
    je 82f
    mov [rip + tk_b], rdx
    mov dword ptr [rip + tk_intag], 1
    mov rsi, [rip + tk_i]
    mov rdx, [rip + tk_a]
    mov eax, C_PUNCT
    call mark
    mov rsi, [rip + tk_a]
    mov rdx, [rip + tk_b]
    mov eax, C_TAG
    call mark
    jmp .Ltk_main
82: mov eax, [rip + tk_c]
8:  cmp dword ptr [rip + tk_intag], 0
    je 85f
    cmp eax, '>'
    jne 86f
    mov dword ptr [rip + tk_intag], 0
    mov eax, C_PUNCT
    jmp .Ltk_one
86: cmp eax, '/'
    je 87f
    cmp eax, '='
    jne 88f
87: mov eax, C_PUNCT
    jmp .Ltk_one
88: mov rdi, rbx
    mov esi, eax
    call is_word_char
    test eax, eax
    jz .Ltk_text1
    mov rsi, [rip + tk_i]
    call word_end_dash
    mov rsi, [rip + tk_i]
    mov eax, C_ATTRIBUTE
    call mark
    jmp .Ltk_main
85: cmp eax, '&'
    jne .Ltk_text1
    mov rcx, rsi
89: inc rcx
    cmp rcx, r13
    jae .Ltk_text1
    cmp byte ptr [r12 + rcx], ';'
    je 891f
    cmp byte ptr [r12 + rcx], '#'
    je 89b
    push rcx
    movzx esi, byte ptr [r12 + rcx]
    mov rdi, rbx
    call is_word_char
    pop rcx
    test eax, eax
    jz .Ltk_text1
    jmp 89b
891:lea rdx, [rcx + 1]
    mov rsi, [rip + tk_i]
    mov eax, C_CONSTANT
    call mark
    jmp .Ltk_main
.Ltk_text1:
    mov eax, C_TEXT
    jmp .Ltk_one
.Ltk_prefix:
    # "prefix = $v @a #p %t" : prefix char + class letter (v variable, a attribute, p preproc at line
    # start, t tag)
    lea rdi, [rbx + GR_prefixes]
9:  movzx edx, byte ptr [rdi]
    test edx, edx
    jz .Ltk_num
    cmp edx, ' '
    jne 90f
    inc rdi
    jmp 9b
90: cmp byte ptr [rdi + 1], 0
    je .Ltk_num
    cmp edx, eax
    je 91f
    add rdi, 2
    jmp 9b
91: movzx edx, byte ptr [rdi + 1]
    mov r8d, C_VARIABLE
    cmp edx, 'a'
    jne 94f
    mov r8d, C_ATTRIBUTE
94: cmp edx, 't'
    jne 92f
    mov r8d, C_TAG
92: cmp edx, 'p'
    jne 93f
    cmp rsi, [rip + tk_bol]
    jne .Ltk_num
    mov r8d, C_PREPROC
93: lea rcx, [rsi + 1]
    cmp rcx, r13
    jae .Ltk_num
    mov [rip + tk_a], r8
    push rcx
    push rcx
    movzx esi, byte ptr [r12 + rcx]
    mov rdi, rbx
    call is_word_char
    pop rsi
    pop rsi
    test eax, eax
    jz .Ltk_num
    call word_end
    mov rsi, [rip + tk_i]
    mov eax, [rip + tk_a]
    call mark
    jmp .Ltk_main
.Ltk_num:
    mov rsi, [rip + tk_i]
    test qword ptr [rbx + GR_flags], GF_NUMBERS
    jz .Ltk_word
    mov eax, [rip + tk_c]
    lea ecx, [rax - '0']
    cmp ecx, 9
    jbe 10f
    cmp eax, '.'
    jne .Ltk_word
    lea rcx, [rsi + 1]
    cmp rcx, r13
    jae .Ltk_word
    movzx ecx, byte ptr [r12 + rcx]
    sub ecx, '0'
    cmp ecx, 9
    ja .Ltk_word
10: mov rdx, rsi
102:inc rdx
    cmp rdx, r13
    jae 103f
    movzx eax, byte ptr [r12 + rdx]
    cmp al, '.'
    je 106f
    cmp al, '_'
    je 102b
    push rdx
    push rdx
    mov edi, eax
    call is_ident
    pop rdx
    pop rdx
    test eax, eax
    jz 103f
    # exponent sign 1e-5 (not in hex literals)
    movzx eax, byte ptr [r12 + rdx]
    or eax, 0x20
    cmp eax, 'e'
    jne 102b
    lea rcx, [rdx + 1]
    cmp rcx, r13
    jae 102b
    cmp byte ptr [r12 + rcx], '-'
    je 105f
    cmp byte ptr [r12 + rcx], '+'
    jne 102b
105:mov rax, [rip + tk_i]
    movzx eax, byte ptr [r12 + rax + 1]
    or eax, 0x20
    cmp eax, 'x'
    je 102b
    inc rdx
    jmp 102b
106:# a dot continues the number only when a digit follows (keeps 1..10 and x.0.foo sane)
    lea rcx, [rdx + 1]
    cmp rcx, r13
    jae 103f
    movzx eax, byte ptr [r12 + rcx]
    sub eax, '0'
    cmp eax, 9
    jbe 102b
103:mov rsi, [rip + tk_i]
    mov eax, C_NUMBER
    call mark
    jmp .Ltk_main
.Ltk_word:
    mov rdi, rbx
    mov esi, [rip + tk_c]
    call is_word_char
    test eax, eax
    jz .Ltk_op
    mov rsi, [rip + tk_i]
    call word_end
    mov [rip + tk_b], rdx
    mov rdi, rbx
    mov rsi, r12
    add rsi, [rip + tk_i]
    sub rdx, [rip + tk_i]
    mov [rip + tk_a], rdx       # word length
    cmp qword ptr [rbx + GR_wcap], 0
    je 11f
    call gr_word_slot
    cmp qword ptr [rax + W_ptr], 0
    je 11f
    mov eax, [rax + W_class]
    jmp .Ltk_wmark
11: mov rdx, [rip + tk_b]
    test qword ptr [rbx + GR_flags], GF_LABELS
    jz 12f
    mov rax, [rip + tk_i]
    cmp rax, [rip + tk_bol]
    jne 12f
    cmp rdx, r13
    jae 12f
    cmp byte ptr [r12 + rdx], ':'
    jne 12f
    mov eax, C_FUNCTION
    jmp .Ltk_wmark
12: test qword ptr [rbx + GR_flags], GF_FUNCS
    jz 14f
    mov rcx, rdx
13: cmp rcx, r13
    jae 14f
    cmp byte ptr [r12 + rcx], ' '
    jne 131f
    inc rcx
    jmp 13b
131:cmp byte ptr [r12 + rcx], '('
    jne 14f
    mov eax, C_FUNCTION
    jmp .Ltk_wmark
14: test qword ptr [rbx + GR_flags], GF_CAPTYPES
    jz 16f
    mov rax, [rip + tk_i]
    movzx ecx, byte ptr [r12 + rax]
    sub ecx, 'A'
    cmp ecx, 25
    ja 16f
    mov rcx, [rip + tk_i]
15: cmp rcx, [rip + tk_b]
    jae 151f
    movzx edx, byte ptr [r12 + rcx]
    sub edx, 'a'
    cmp edx, 25
    jbe 152f
    inc rcx
    jmp 15b
151:mov eax, C_CONSTANT
    cmp qword ptr [rip + tk_a], 1
    ja .Ltk_wmark
    jmp 16f
152:mov eax, C_TYPE
    jmp .Ltk_wmark
16: mov eax, C_TEXT
.Ltk_wmark:
    mov rsi, [rip + tk_i]
    mov rdx, [rip + tk_b]
    call mark
    jmp .Ltk_main
.Ltk_op:
    test qword ptr [rbx + GR_flags], GF_OPS
    jz .Ltk_text1
    mov eax, [rip + tk_c]
    lea rdi, [rip + op_chars]
    mov ecx, 15
    repne scasb
    jne 17f
    mov eax, C_OPERATOR
    jmp .Ltk_one
17: mov eax, [rip + tk_c]
    lea rdi, [rip + punct_chars]
    mov ecx, 9
    repne scasb
    jne .Ltk_text1
    mov eax, C_PUNCT
    jmp .Ltk_one
.Ltk_blank:
    mov eax, C_TEXT
.Ltk_one:
    mov rsi, [rip + tk_i]
    lea rdx, [rsi + 1]
    call mark
    jmp .Ltk_main
.Ltk_ret:
    mov eax, [rip + tk_end]
    EPILOGUE

# mark(eax class, rsi from, rdx to): out[from..to) = class, tk_i = to
mark:
    cmp rdx, r13
    jbe 1f
    mov rdx, r13
1:  mov [rip + tk_i], rdx
    test r14, r14
    jz 3f
2:  cmp rsi, rdx
    jae 3f
    mov [r14 + rsi], al
    inc rsi
    jmp 2b
3:  ret

# word_end(rsi start) -> rdx end of identifier chars
word_end:
    mov rdx, rsi
1:  cmp rdx, r13
    jae 2f
    movzx eax, byte ptr [r12 + rdx]
    cmp byte ptr [rbx + GR_wchar + rax], 0
    je 2f
    inc rdx
    jmp 1b
2:  ret

# word_end_dash: identifier chars plus '-' and ':' (markup names)
word_end_dash:
    mov rdx, rsi
1:  cmp rdx, r13
    jae 2f
    cmp byte ptr [r12 + rdx], '-'
    je 3f
    cmp byte ptr [r12 + rdx], ':'
    je 3f
    push rdx
    push rdx
    movzx esi, byte ptr [r12 + rdx]
    mov rdi, rbx
    call is_word_char
    pop rdx
    pop rdx
    test eax, eax
    jz 2f
3:  inc rdx
    jmp 1b
2:  ret

# scan_region_end: r15 = region, rsi = scan start (after the opener); the region began at tk_i
scan_region_end:
    movzx r9d, byte ptr [r15 + REG_elen]
    movzx r10d, byte ptr [r15 + REG_esc]
    mov r11, rsi
1:  cmp r11, r13
    jae 5f
    test r9d, r9d
    jz 4f
    test r10d, r10d
    jz 2f
    movzx eax, byte ptr [r12 + r11]
    cmp eax, r10d
    jne 2f
    # an escape that is the end doubles: only a second one right after it escapes
    movzx ecx, byte ptr [r15 + REG_end]
    cmp eax, ecx
    jne 7f
    lea rax, [r11 + 1]
    cmp rax, r13
    jae 2f
    movzx ecx, byte ptr [r12 + rax]
    cmp ecx, r10d
    jne 2f
7:  add r11, 2
    jmp 1b
2:  push r9
    push r10
    push r11
    push r11
    lea rdi, [r12 + r11]
    mov rsi, r13
    sub rsi, r11
    lea rdx, [r15 + REG_end]
    mov ecx, r9d
    call str_starts
    pop r11
    pop r11
    pop r10
    pop r9
    test eax, eax
    jnz 3f
    inc r11
    jmp 1b
3:  lea rdx, [r11 + r9]
    jmp 6f
4:  mov r11, r13
5:  mov rdx, r13
    test r9d, r9d
    jz 6f
    cmp byte ptr [r15 + REG_multi], 0
    je 6f
    # still open at the end of the line
    mov rax, r15
    sub rax, [rbx + GR_regions + VEC_ptr]
    xor edx, edx
    mov ecx, REG_SIZE
    div rcx
    inc eax
    mov [rip + tk_end], eax
    mov rdx, r13
6:  movzx eax, byte ptr [r15 + REG_class]
    mov rsi, [rip + tk_i]
    jmp mark

# ---- document integration ----

# syntax_prepare(doc, upto_line): make states valid for lines <= upto
FN syntax_prepare
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + DOC_lang]
    test r13, r13
    jz 9f
    cmp r12, [rbx + DOC_nlines]
    jb 1f
    mov r12, [rbx + DOC_nlines]
    dec r12
1:  cmp qword ptr [rbx + DOC_svalid], 0
    jne 2f
    mov rax, [rbx + DOC_states]
    mov dword ptr [rax], 0
    mov qword ptr [rbx + DOC_svalid], 1
2:  mov r14, [rbx + DOC_svalid]
    cmp r14, r12
    ja 9f
    # tokenize line svalid-1 to get the state of line svalid
    lea r15, [r14 - 1]
    mov rdi, rbx
    mov rsi, r15
    call doc_line_text
    mov rcx, [rbx + DOC_states]
    mov ecx, [rcx + r15*4]
    mov rdi, r13
    mov rsi, rax
    xor r8d, r8d
    call tokenize
    mov rcx, [rbx + DOC_states]
    mov edx, [rcx + r14*4]      # state stored before the edits
    mov [rcx + r14*4], eax
    inc qword ptr [rbx + DOC_svalid]
    # past every edit and equal to the old state: the rest is still valid
    cmp r14, [rbx + DOC_sold]
    jae 2b
    mov rcx, [rbx + DOC_ehi]
    inc rcx
    cmp r14, rcx
    jbe 2b
    cmp eax, edx
    jne 2b
    mov rax, [rbx + DOC_sold]
    mov [rbx + DOC_svalid], rax
    jmp 2b
9:  EPILOGUE

# syntax_line(doc, line, text, len, out): classes for one line (states must be prepared)
FN syntax_line
    push rbx
    mov rbx, [rdi + DOC_lang]
    test rbx, rbx
    jz 2f
    cmp rsi, [rdi + DOC_svalid]
    jae 2f
    mov rax, [rdi + DOC_states]
    mov eax, [rax + rsi*4]
    mov rdi, rbx
    mov rsi, rdx
    mov rdx, rcx
    mov ecx, eax
    call tokenize
    pop rbx
    ret
2:  # plain text
    mov rdi, r8
    xor eax, eax
    rep stosb
    pop rbx
    ret

.section .rodata
op_chars: .ascii "+-*/%=<>!&|^~?:"
punct_chars: .ascii "()[]{},;."
class_names:
    .quad .Lc0, .Lc1, .Lc2, .Lc3, .Lc4, .Lc5, .Lc6, .Lc7, .Lc8, .Lc9
    .quad .Lc10, .Lc11, .Lc12, .Lc13, .Lc14, .Lc15, .Lc16, .Lc17, .Lc18, .Lc19
.Lc0: .asciz "text"
.Lc1: .asciz "keyword"
.Lc2: .asciz "type"
.Lc3: .asciz "function"
.Lc4: .asciz "string"
.Lc5: .asciz "number"
.Lc6: .asciz "comment"
.Lc7: .asciz "constant"
.Lc8: .asciz "operator"
.Lc9: .asciz "punctuation"
.Lc10: .asciz "preproc"
.Lc11: .asciz "variable"
.Lc12: .asciz "builtin"
.Lc13: .asciz "attribute"
.Lc14: .asciz "tag"
.Lc15: .asciz "heading"
.Lc16: .asciz "inserted"
.Lc17: .asciz "deleted"
.Lc18: .asciz "escape"
.Lc19: .asciz "link"
.Lnone: .asciz ""
.Lk_name: .asciz "name"
.Lk_files: .asciz "files"
.Lk_first: .asciz "first_line"
.Lk_icon: .asciz "icon"
.Lk_comment: .asciz "comment"
.Lk_toggle: .asciz "toggle_comment"
.Lk_block: .asciz "block"
.Lk_string: .asciz "string"
.Lk_mstring: .asciz "mstring"
.Lk_region: .asciz "region"
.Lk_line: .asciz "line"
.Lk_ident: .asciz "ident"
.Lk_prefix: .asciz "prefix"
.Lk_case: .asciz "case"
.Lk_functions: .asciz "functions"
.Lk_captypes: .asciz "captypes"
.Lk_markup: .asciz "markup"
.Lk_labels: .asciz "labels"
.Lk_numbers: .asciz "numbers"
.Lk_operators: .asciz "operators"
.Lk_colon: .asciz "colon_indent"
.Lv_insensitive: .asciz "insensitive"
.Lv_multiline: .ascii "multiline"
.Lv_bol: .ascii "bol"
.Lv_escape: .ascii "escape="
.Lv_eol: .asciz "eol"
.Lsyntax_dir: .asciz "syntax"
.Lsyn_ext: .asciz ".syn"
