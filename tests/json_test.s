# json: the builder (every value kind and escape, invalid UTF-8 written as U+FFFD), parsed values
# written back, the parser's checks (literals, \u digits, lone surrogates, trailing bytes, the value
# and depth caps), json_int's bounds, json_bool and json_trim
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
out2: .zero SB_SIZE
.text
FN main
    PROLOGUE
    lea rbx, [rip + out]
    mov rdi, rbx
    call jw_begin
    mov rdi, rbx
    call jw_obj
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call jw_key
    mov rdi, rbx
    lea rsi, [rip + .Lv_user]
    call jw_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_text]
    call jw_key
    mov rdi, rbx
    lea rsi, [rip + .Lv_text]
    mov edx, .Lv_text_end - .Lv_text
    call jw_str
    mov rdi, rbx
    lea rsi, [rip + .Lk_bad]
    call jw_key
    mov rdi, rbx
    lea rsi, [rip + .Lv_bad]
    mov edx, .Lv_bad_end - .Lv_bad
    call jw_str
    mov rdi, rbx
    lea rsi, [rip + .Lk_n]
    call jw_key
    mov rdi, rbx
    mov rsi, -1                 # 18446744073709551615
    call jw_u64
    mov rdi, rbx
    lea rsi, [rip + .Lk_i]
    call jw_key
    mov rdi, rbx
    mov rsi, -42
    call jw_int
    mov rdi, rbx
    lea rsi, [rip + .Lk_list]
    call jw_key
    mov rdi, rbx
    call jw_arr
    mov rdi, rbx
    mov esi, 1
    call jw_bool
    mov rdi, rbx
    xor esi, esi
    call jw_bool
    mov rdi, rbx
    call jw_null
    mov rdi, rbx
    call jw_obj
    mov rdi, rbx
    call jw_end_obj
    mov rdi, rbx
    call jw_end_arr
    mov rdi, rbx
    lea rsi, [rip + .Lk_empty]
    call jw_key
    mov rdi, rbx
    call jw_arr
    mov rdi, rbx
    call jw_end_arr
    mov rdi, rbx
    call jw_end_obj
    mov rdi, rbx
    call jw_line
    # a 3 MiB string makes the arena grow; json_trim brings it back to 1 MiB
    mov edi, 3 << 20
    add edi, 16
    call mem_alloc
    mov r12, rax
    mov byte ptr [rax], '"'
    lea rdi, [rax + 1]
    mov esi, 'x'
    mov edx, 3 << 20
    call memset
    mov byte ptr [r12 + (3 << 20) + 1], '"'
    mov rdi, r12
    mov esi, (3 << 20) + 2
    call json_parse
    call json_arena_cap
    mov r13, rax
    call json_trim
    lea rdi, [rip + .Lsmall]
    mov esi, 2
    call json_parse
    call json_arena_cap
    mov r14, rax
    lea rdi, [rip + out]
    lea rsi, [rip + .Lgrown]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 0
    cmp r13, 1 << 20
    seta sil
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Ltrimmed]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, r14
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    # a kept value as a raw item; an escaped key from bytes
    lea rdi, [rip + out2]
    call jw_begin
    lea rdi, [rip + out2]
    call jw_obj
    lea rdi, [rip + out2]
    lea rsi, [rip + .Lk_q]
    mov edx, 3
    call jw_keyn
    lea rdi, [rip + out2]
    call jw_arr
    lea rdi, [rip + out2]
    lea rsi, [rip + .Lkept]
    mov edx, .Lkept_end - .Lkept
    call jw_rawn
    lea rdi, [rip + out2]
    mov esi, 2
    call jw_u64
    lea rdi, [rip + out2]
    call jw_end_arr
    lea rdi, [rip + out2]
    call jw_end_obj
    lea rdi, [rip + out2]
    call jw_line
    mov rdi, rbx
    mov rsi, [rip + out2 + SB_ptr]
    mov rdx, [rip + out2 + SB_len]
    call sb_push
    # parser cases: "ok <the value written back> ret=<jw_jv's result>" or "fail"
    lea r12, [rip + cases]
1:  mov rdi, [r12]
    test rdi, rdi
    jz 2f
    mov rsi, [r12 + 8]
    mov rdx, [r12 + 16]
    mov rcx, [r12 + 24]
    call parse_line
    add r12, 32
    jmp 1b
2:  # json_int and json_bool
    lea r12, [rip + ints]
3:  mov rdi, [r12]
    test rdi, rdi
    jz 4f
    call strlen
    mov rdi, [r12]
    mov rsi, rax
    call json_parse
    mov rdi, rax
    call json_int
    mov r13, rax
    mov r14d, edx
    mov rdi, rbx
    mov rsi, [r12]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    test r14d, r14d
    jz 31f
    lea rdi, [rip + out2]
    call jw_begin
    lea rdi, [rip + out2]
    mov rsi, r13
    call jw_int
    mov rdi, rbx
    mov rsi, [rip + out2 + SB_ptr]
    mov rdx, [rip + out2 + SB_len]
    call sb_push
    jmp 32f
31: mov rdi, rbx
    lea rsi, [rip + .Lno]
    call sb_push_cstr
32: mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add r12, 8
    jmp 3b
4:  lea rdi, [rip + .Lbools]
    mov esi, .Lbools_end - .Lbools
    call json_parse
    mov r12, rax
    xor r13d, r13d
5:  cmp r13d, 3
    jae 6f
    mov rdi, r12
    mov esi, r13d
    call json_at
    mov rdi, rax
    call json_bool
    lea esi, [rax + '0']
    lea r14d, [rdx + '0']
    mov rdi, rbx
    call sb_push_byte
    mov rdi, rbx
    mov esi, r14d
    call sb_push_byte
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    inc r13d
    jmp 5b
6:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    # json_pretty: as JSON.stringify(v, null, 2); deeper than 64 levels "…"
    lea r12, [rip + pretty_cases]
7:  mov rdi, [r12]
    test rdi, rdi
    jz 8f
    call strlen
    mov rdi, [r12]
    mov rsi, rax
    call json_parse
    mov rsi, rax
    mov rdi, rbx
    call json_pretty
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add r12, 8
    jmp 7b
8:  mov edi, 1
    mov rsi, [rbx + SB_ptr]
    mov rdx, [rbx + SB_len]
    call write_all
    xor eax, eax
    EPILOGUE

# parse_line(cstr, unused, max values, max depth): out gains the case's result
parse_line:
    PROLOGUE
    mov r12, rdi
    mov r14, rdx
    mov r15, rcx
    call strlen
    mov rdi, r12
    mov rsi, rax
    mov rdx, r14
    mov rcx, r15
    call json_parse_lim
    test rax, rax
    jnz 1f
    lea rdi, [rip + out]
    lea rsi, [rip + .Lfail]
    call sb_push_cstr
    EPILOGUE
1:  mov r12, rax
    lea rdi, [rip + out2]
    call jw_begin
    lea rdi, [rip + out2]
    mov rsi, r12
    call jw_jv
    mov r13d, eax
    lea rdi, [rip + out]
    lea rsi, [rip + .Lok]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, [rip + out2 + SB_ptr]
    mov rdx, [rip + out2 + SB_len]
    call sb_push
    lea rdi, [rip + out]
    lea rsi, [rip + .Lret]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Lk_type: .asciz "type"
.Lv_user: .asciz "user"
.Lk_text: .asciz "text"
.Lv_text: .ascii "say \"hi\"\\ \n\t"
    .byte 1, 0x1f, 0x7f
    .ascii "é😀"
    .byte 13
.Lv_text_end:
.Lk_bad: .asciz "bad"
    # a stray continuation byte, a cut two-byte character, an encoded surrogate, past U+10FFFF
.Lv_bad: .byte 'a', 0x80, 'b', 0xc3, 'c', 0xed, 0xa0, 0x80, 'd', 0xf4, 0x90, 0x80, 0x80, 'e'
.Lv_bad_end:
.Lk_n: .asciz "n"
.Lk_i: .asciz "i"
.Lk_list: .asciz "list"
.Lk_empty: .asciz "empty"
.Lsmall: .asciz "{}"
.Lgrown: .asciz "grown="
.Ltrimmed: .asciz " cap="
.Lkept: .ascii "{\"z\":1}"
.Lkept_end:
.Lk_q: .ascii "k\"q"
.Lok: .asciz "ok "
.Lfail: .asciz "fail\n"
.Lret: .asciz " ret="
.Lno: .asciz "no"
.Lbools: .ascii "[true,false,1]"
.Lbools_end:
c_all: .asciz "{\"a\":[1,-2.5e3,\"x\\\"y\",true,false,null,{},[]],\"b\":{\"c\":\"\\n\"},\"k\\\"q\":0,\"u\":\"é\\ud83d\\ude00😀\"}"
c_deep70: .asciz "[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[1]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]"
c_deep10: .asciz "[[[[[[[[[[1]]]]]]]]]]"
c_tru: .asciz "[tru]"
c_trux: .asciz "[trux]"
c_nul: .asciz "nul"
c_fals: .asciz "fals"
c_u3: .asciz "\"\\u12\""
c_ug: .asciz "\"\\u12g4\""
c_lonehi: .asciz "\"a\\ud83db\""
c_lonelo: .asciz "\"a\\ude00b\""
c_hihi: .asciz "\"\\ud83d\\ud83d\\ude00\""
c_trail: .asciz "{} x"
c_blank: .asciz " [1 , 2] \r\n"
c_comma: .asciz "[1,]"
c_nocomma: .asciz "[1 2]"
c_objcomma: .asciz "{\"a\":1 \"b\":2}"
c_four: .asciz "[1,2,3]"
c_unterminated: .asciz "\"abc"
c_escend: .asciz "\"abc\\\""
c_pretty: .asciz "{\"a\":[1,{\"b\":\"x\\\"y\\n\"}],\"e\":{},\"f\":[],\"n\":null,\"t\":true,\"u\":\"é😀\",\"x\":-2.5e3}"
c_scalar: .asciz "\"plain\""
.p2align 3
pretty_cases: .quad c_pretty, c_scalar, c_deep10, c_deep70, c_four, 0
cases:
    .quad c_all, 0, 0, 200
    .quad c_deep70, 0, 0, 200
    .quad c_deep10, 0, 0, 200
    .quad c_deep10, 0, 0, 11
    .quad c_deep10, 0, 0, 10
    .quad c_tru, 0, 0, 64
    .quad c_trux, 0, 0, 64
    .quad c_nul, 0, 0, 64
    .quad c_fals, 0, 0, 64
    .quad c_u3, 0, 0, 64
    .quad c_ug, 0, 0, 64
    .quad c_lonehi, 0, 0, 64
    .quad c_lonelo, 0, 0, 64
    .quad c_hihi, 0, 0, 64
    .quad c_trail, 0, 0, 64
    .quad c_blank, 0, 0, 64
    .quad c_comma, 0, 0, 64
    .quad c_nocomma, 0, 0, 64
    .quad c_objcomma, 0, 0, 64
    .quad c_four, 0, 4, 64
    .quad c_four, 0, 3, 64
    .quad c_unterminated, 0, 0, 64
    .quad c_escend, 0, 0, 64
    .quad 0, 0, 0, 0
i0: .asciz "0"
i1: .asciz "-17"
i2: .asciz "9223372036854775807"
i3: .asciz "9223372036854775808"
i4: .asciz "-9223372036854775808"
i5: .asciz "-9223372036854775809"
i6: .asciz "1.0"
i7: .asciz "1e3"
i8: .asciz "99999999999999999999999"
i9: .asciz "\"5\""
i10: .asciz "-"
.p2align 3
ints:
    .quad i0, i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, 0
