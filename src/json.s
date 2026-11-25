# json: recursive-descent parser into an arena (one document at a time), and a builder that writes
# one message at a time into an SB. Numbers stay their source text; strings come out as UTF-8 with
# escapes decoded. Callers copy what they keep before the next parse.
.include "rhun.inc"

STRUCT
F JV_type, 4
F JV_n, 4               # elements / pairs / string bytes
F JV_ptr, 8             # string bytes, or child pointers (objects: key,value pairs)
ENDSTRUCT JV_SIZE

.equ JSON_DEPTH_DEFAULT, 200

.bss
.p2align 3
arena: .quad 0
arena_cap: .quad 0
arena_top: .quad 0
stk: .zero VEC_SIZE             # pending child pointers
jp: .quad 0
jend: .quad 0
jnodes: .quad 0                 # values parsed so far in this document
jmaxnodes: .quad 0              # 0: no cap
jdepth: .long 0
jmaxdepth: .long 0
jfail: .long 0

.text

# aalloc(n) -> pointer in the arena (8-byte aligned); grows by chaining new blocks
aalloc:
    add rdi, 7
    and rdi, -8
    mov rax, [rip + arena_top]
    lea rcx, [rax + rdi]
    cmp rcx, [rip + arena_cap]
    ja 1f
    mov [rip + arena_top], rcx
    add rax, [rip + arena]
    ret
1:  # out of space: keep old blocks alive (pointers into them stay valid), start a new one
    push rdi
    push rdi
    mov rax, [rip + arena_cap]
    add rax, rax
    cmp rax, rdi
    jae 2f
    lea rax, [rdi + rdi]
2:  mov ecx, 1 << 20
    cmp rax, rcx
    cmovb rax, rcx
    mov [rip + arena_cap], rax
    mov rdi, rax
    call mem_alloc
    # link the old block for freeing
    mov rcx, [rip + arena]
    mov [rax], rcx
    mov [rip + arena], rax
    mov qword ptr [rip + arena_top], 8
    pop rdi
    pop rdi
    jmp aalloc

# json_reset(): free all blocks but the newest
json_reset:
    push rbx
    mov rax, [rip + arena]
    test rax, rax
    jz 2f
    mov rbx, [rax]
    mov qword ptr [rax], 0
1:  test rbx, rbx
    jz 2f
    mov rdi, rbx
    mov rbx, [rbx]
    call mem_free
    jmp 1b
2:  mov qword ptr [rip + arena_top], 8
    mov qword ptr [rip + stk + VEC_len], 0
    pop rbx
    ret

skip_ws:
    mov rsi, [rip + jp]
    mov rdi, [rip + jend]
1:  cmp rsi, rdi
    jae 2f
    movzx eax, byte ptr [rsi]
    cmp al, ' '
    je 3f
    cmp al, 10
    je 3f
    cmp al, 13
    je 3f
    cmp al, 9
    jne 2f
3:  inc rsi
    jmp 1b
2:  mov [rip + jp], rsi
    ret

# json_parse(ptr, len) -> JV* or 0; nesting at most 200 deep, no cap on the number of values
FN json_parse
    xor edx, edx
    mov ecx, JSON_DEPTH_DEFAULT
    jmp json_parse_lim

# json_parse_lim(ptr, len, max values (0: no cap), max depth) -> JV* or 0. A document past either
#   limit fails as a syntax error does; the arena holds at most max values x 24 bytes plus its text.
FN json_parse_lim
    push rbx
    mov [rip + jp], rdi
    add rdi, rsi
    mov [rip + jend], rdi
    mov [rip + jmaxnodes], rdx
    mov [rip + jmaxdepth], ecx
    mov qword ptr [rip + jnodes], 0
    mov dword ptr [rip + jdepth], 0
    mov dword ptr [rip + jfail], 0
    cmp qword ptr [rip + arena], 0
    jne 1f
    mov edi, 8
    call aalloc
1:  call json_reset
    call parse_value
    cmp dword ptr [rip + jfail], 0
    jne 3f
    # only blanks may follow the value
    push rax
    call skip_ws
    pop rax
    cmp rsi, rdi
    je 2f
3:  xor eax, eax
2:  pop rbx
    ret

push_child:
    push rbx
    mov rbx, rdi
    lea rdi, [rip + stk]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    pop rbx
    ret

# lit_is(cstr) -> 1 when the text at jp starts with the literal, within the document
lit_is:
    mov rsi, [rip + jp]
    mov rdx, [rip + jend]
1:  movzx eax, byte ptr [rdi]
    test eax, eax
    jz 2f
    cmp rsi, rdx
    jae 3f
    cmp al, [rsi]
    jne 3f
    inc rdi
    inc rsi
    jmp 1b
2:  mov [rip + jp], rsi
    mov eax, 1
    ret
3:  xor eax, eax
    ret

# parse_value() -> JV*
parse_value:
    PROLOGUE
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    inc dword ptr [rip + jdepth]
    mov eax, [rip + jdepth]
    cmp eax, [rip + jmaxdepth]
    ja .Lpv_fail
    inc qword ptr [rip + jnodes]
    mov rax, [rip + jmaxnodes]
    test rax, rax
    jz 0f
    cmp [rip + jnodes], rax
    ja .Lpv_fail
0:  mov edi, JV_SIZE
    call aalloc
    mov rbx, rax
    mov rsi, [rip + jp]
    movzx eax, byte ptr [rsi]
    cmp al, '{'
    je .Lpv_obj
    cmp al, '['
    je .Lpv_arr
    cmp al, '"'
    je .Lpv_str
    cmp al, 't'
    je .Lpv_true
    cmp al, 'f'
    je .Lpv_false
    cmp al, 'n'
    je .Lpv_null
    # number: keep the raw text
    mov dword ptr [rbx + JV_type], JT_NUM
    mov [rbx + JV_ptr], rsi
    mov rdi, [rip + jend]
    mov rcx, rsi
1:  cmp rcx, rdi
    jae 2f
    movzx eax, byte ptr [rcx]
    cmp al, '-'
    je 11f
    cmp al, '+'
    je 11f
    cmp al, '.'
    je 11f
    cmp al, 'e'
    je 11f
    cmp al, 'E'
    je 11f
    sub al, '0'
    cmp al, 9
    ja 2f
11: inc rcx
    jmp 1b
2:  cmp rcx, rsi
    je .Lpv_fail
    mov rax, rcx
    sub rax, rsi
    mov [rbx + JV_n], eax
    mov [rip + jp], rcx
    jmp .Lpv_done
.Lpv_true:
    mov dword ptr [rbx + JV_type], JT_TRUE
    lea rdi, [rip + .Ls_true]
    jmp 12f
.Lpv_false:
    mov dword ptr [rbx + JV_type], JT_FALSE
    lea rdi, [rip + .Ls_false]
    jmp 12f
.Lpv_null:
    mov dword ptr [rbx + JV_type], JT_NULL
    lea rdi, [rip + .Ls_null]
12: call lit_is
    test eax, eax
    jz .Lpv_fail
    jmp .Lpv_done
.Lpv_str:
    mov dword ptr [rbx + JV_type], JT_STR
    call parse_string
    test rax, rax
    jz .Lpv_fail
    mov [rbx + JV_ptr], rax
    mov [rbx + JV_n], edx
    jmp .Lpv_done
.Lpv_arr:
    mov dword ptr [rbx + JV_type], JT_ARR
    inc qword ptr [rip + jp]
    mov r12, [rip + stk + VEC_len]     # stack base
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    cmp byte ptr [rsi], ']'
    je 5f
3:  call parse_value                # after a comma a value must follow
    test rax, rax
    jz .Lpv_fail
    mov rdi, rax
    call push_child
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    cmp byte ptr [rsi], ']'
    je 5f
    cmp byte ptr [rsi], ','
    jne .Lpv_fail
    inc qword ptr [rip + jp]
    jmp 3b
5:  inc qword ptr [rip + jp]
    call pop_children
    jmp .Lpv_done
.Lpv_obj:
    mov dword ptr [rbx + JV_type], JT_OBJ
    inc qword ptr [rip + jp]
    mov r12, [rip + stk + VEC_len]
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    cmp byte ptr [rsi], '}'
    je 8f
6:  call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    cmp byte ptr [rsi], '"'
    jne .Lpv_fail
    call parse_value            # key (string)
    test rax, rax
    jz .Lpv_fail
    mov rdi, rax
    call push_child
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    cmp byte ptr [rsi], ':'
    jne .Lpv_fail
    inc qword ptr [rip + jp]
    call parse_value
    test rax, rax
    jz .Lpv_fail
    mov rdi, rax
    call push_child
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    cmp byte ptr [rsi], '}'
    je 8f
    cmp byte ptr [rsi], ','
    jne .Lpv_fail
    inc qword ptr [rip + jp]
    jmp 6b
8:  inc qword ptr [rip + jp]
    call pop_children
    shr dword ptr [rbx + JV_n], 1
.Lpv_done:
    dec dword ptr [rip + jdepth]
    mov rax, rbx
    EPILOGUE
.Lpv_fail:
    mov dword ptr [rip + jfail], 1
    xor eax, eax
    EPILOGUE

# pop_children(): move stack entries above r12 into the node rbx
pop_children:
    mov rcx, [rip + stk + VEC_len]
    sub rcx, r12
    mov [rbx + JV_n], ecx
    push rcx
    push rcx
    lea rdi, [rcx*8]
    call aalloc
    pop rcx
    pop rcx
    mov [rbx + JV_ptr], rax
    mov rsi, [rip + stk + VEC_ptr]
    lea rsi, [rsi + r12*8]
    mov rdi, rax
    shl rcx, 3
    rep movsb
    mov [rip + stk + VEC_len], r12
    ret

# hex4(ptr, end) -> eax the value of 4 hex digits at ptr, or -1 when there are fewer before end
hex4:
    lea rax, [rdi + 4]
    cmp rax, rsi
    ja 1f
    mov esi, 4
    call parse_hex
    cmp rdx, 4
    jne 1f
    ret
1:  mov eax, -1
    ret

# parse_string() -> rax bytes (arena), rdx length ; jp at the opening quote. A \u escape needs four
#   hex digits; a surrogate that is not half of a pair becomes U+FFFD.
parse_string:
    PROLOGUE
    mov rsi, [rip + jp]
    inc rsi
    mov rdi, [rip + jend]
    # length bound: distance to the closing quote
    mov rcx, rsi
1:  cmp rcx, rdi
    jae .Lps_fail
    movzx eax, byte ptr [rcx]
    cmp al, '"'
    je 2f
    cmp al, '\\'
    jne 11f
    inc rcx
11: inc rcx
    jmp 1b
2:  mov r12, rcx                # closing quote
    mov rdi, rcx
    sub rdi, rsi
    inc rdi
    push rsi
    push rsi
    call aalloc
    pop rsi
    pop rsi
    mov r13, rax                # out
    xor r14d, r14d              # out len
.Lps_loop:
    cmp rsi, r12
    jae .Lps_end
    movzx eax, byte ptr [rsi]
    cmp al, '\\'
    je .Lps_esc
    mov [r13 + r14], al
    inc r14
    inc rsi
    jmp .Lps_loop
.Lps_esc:
    movzx eax, byte ptr [rsi + 1]
    add rsi, 2
    mov ecx, 10
    cmp al, 'n'
    je .Lps_put
    mov ecx, 9
    cmp al, 't'
    je .Lps_put
    mov ecx, 13
    cmp al, 'r'
    je .Lps_put
    mov ecx, 8
    cmp al, 'b'
    je .Lps_put
    mov ecx, 12
    cmp al, 'f'
    je .Lps_put
    cmp al, 'u'
    je .Lps_u
    mov ecx, eax                # \" \\ \/ and anything else literally
.Lps_put:
    mov [r13 + r14], cl
    inc r14
    jmp .Lps_loop
.Lps_u:
    mov r15, rsi
    mov rdi, rsi
    mov rsi, r12
    call hex4
    test eax, eax
    js .Lps_fail
    lea rsi, [r15 + 4]
    mov r15d, eax
    lea ecx, [rax - 0xdc00]
    cmp ecx, 0x3ff
    jbe 4f                      # a low half alone
    lea ecx, [rax - 0xd800]
    cmp ecx, 0x3ff
    ja 3f
    # a high half: a low half must follow
    lea rax, [rsi + 6]
    cmp rax, r12
    ja 4f
    cmp byte ptr [rsi], '\\'
    jne 4f
    cmp byte ptr [rsi + 1], 'u'
    jne 4f
    push rsi
    push rsi
    lea rdi, [rsi + 2]
    mov rsi, r12
    call hex4
    pop rsi
    pop rsi
    lea ecx, [rax - 0xdc00]
    cmp ecx, 0x3ff
    ja 4f
    add rsi, 6
    mov eax, r15d
    sub eax, 0xd800
    shl eax, 10
    add eax, ecx
    add eax, 0x10000
    mov r15d, eax
    jmp 3f
4:  mov r15d, 0xfffd
3:  mov edi, r15d
    push rsi
    push rsi
    lea rsi, [r13 + r14]
    call utf8_encode
    pop rsi
    pop rsi
    add r14, rax
    jmp .Lps_loop
.Lps_end:
    lea rax, [r12 + 1]
    mov [rip + jp], rax
    mov byte ptr [r13 + r14], 0
    mov rax, r13
    mov rdx, r14
    EPILOGUE
.Lps_fail:
    xor eax, eax
    EPILOGUE

# json_get(obj, key cstr) -> JV* or 0
FN json_get
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    xor eax, eax
    test rdi, rdi
    jz 9f
    cmp dword ptr [rdi + JV_type], JT_OBJ
    jne 9f
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13d, [rbx + JV_n]
    jae 8f
    mov rax, [rbx + JV_ptr]
    mov rcx, r13
    shl rcx, 4
    mov r14, [rax + rcx]
    mov rdi, [r14 + JV_ptr]
    mov esi, [r14 + JV_n]
    mov rdx, r12
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r13d
    jmp 1b
2:  mov rax, [rbx + JV_ptr]
    mov rcx, r13
    shl rcx, 4
    mov rax, [rax + rcx + 8]
    jmp 9f
8:  xor eax, eax
9:  add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# json_str(jv) -> rax ptr, rdx len (0,0 unless a string)
FN json_str
    xor eax, eax
    xor edx, edx
    test rdi, rdi
    jz 1f
    cmp dword ptr [rdi + JV_type], JT_STR
    jne 1f
    mov rax, [rdi + JV_ptr]
    mov edx, [rdi + JV_n]
1:  ret

# json_is(jv, cstr) -> 1 if jv is a string equal to cstr
FN json_is
    push rsi
    call json_str
    pop rsi
    test rax, rax
    jz 1f
    mov rdi, rax
    xchg rsi, rdx
    jmp str_eq_cstr
1:  xor eax, eax
    ret

# json_at(arr, i) -> JV* or 0
FN json_at
    xor eax, eax
    test rdi, rdi
    jz 1f
    cmp dword ptr [rdi + JV_type], JT_ARR
    jne 1f
    cmp esi, [rdi + JV_n]
    jae 1f
    mov rax, [rdi + JV_ptr]
    mov rax, [rax + rsi*8]
1:  ret

# json_len(arr) -> element count (0 unless array)
FN json_len
    xor eax, eax
    test rdi, rdi
    jz 1f
    cmp dword ptr [rdi + JV_type], JT_ARR
    jne 1f
    mov eax, [rdi + JV_n]
1:  ret

# json_type(jv) -> JT_* (-1 for null pointer)
FN json_type
    mov eax, -1
    test rdi, rdi
    jz 1f
    mov eax, [rdi + JV_type]
1:  ret

# json_int(jv) -> rax value, edx 1 when jv is a number written -?[0-9]+ that fits a signed 64-bit
#   integer; 1.0, 1e3, a missing value and an overflow are not integers (edx 0, rax 0)
FN json_int
    xor eax, eax
    xor edx, edx
    test rdi, rdi
    jz 9f
    cmp dword ptr [rdi + JV_type], JT_NUM
    jne 9f
    mov rsi, [rdi + JV_ptr]
    mov ecx, [rdi + JV_n]
    xor r8d, r8d                # negative
    cmp byte ptr [rsi], '-'
    jne 1f
    mov r8d, 1
    inc rsi
    dec ecx
1:  test ecx, ecx
    jz 9f
    xor r9d, r9d                # magnitude, unsigned
    mov r11, 922337203685477580 # (2^63) / 10: above it, ten times is past every int64
2:  movzx r10d, byte ptr [rsi]
    sub r10d, '0'
    cmp r10d, 9
    ja 8f
    cmp r9, r11
    ja 8f
    imul r9, r9, 10
    add r9, r10
    inc rsi
    dec ecx
    jnz 2b
    # within int64: up to 2^63 - 1, or 2^63 when negative
    mov rax, r9
    test r8d, r8d
    jnz 3f
    test rax, rax
    js 8f
    mov edx, 1
    ret
3:  mov rcx, 1
    shl rcx, 63
    cmp rax, rcx
    ja 8f
    neg rax
    mov edx, 1
    ret
8:  xor eax, eax
    xor edx, edx
9:  ret

# json_bool(jv) -> eax 1 for true, 0 for false; edx 1 when jv is one of them
FN json_bool
    xor eax, eax
    xor edx, edx
    test rdi, rdi
    jz 9f
    cmp dword ptr [rdi + JV_type], JT_TRUE
    jne 1f
    mov eax, 1
    mov edx, 1
    ret
1:  cmp dword ptr [rdi + JV_type], JT_FALSE
    jne 9f
    mov edx, 1
9:  ret

# json_num_text(jv) -> rax ptr, rdx len of a number's source text (0,0 unless a number)
FN json_num_text
    xor eax, eax
    xor edx, edx
    test rdi, rdi
    jz 1f
    cmp dword ptr [rdi + JV_type], JT_NUM
    jne 1f
    mov rax, [rdi + JV_ptr]
    mov edx, [rdi + JV_n]
1:  ret

# json_pair(obj, i) -> rax key JV*, rdx value JV* of an object's i-th pair (0, 0 past the end)
FN json_pair
    xor eax, eax
    xor edx, edx
    test rdi, rdi
    jz 1f
    cmp dword ptr [rdi + JV_type], JT_OBJ
    jne 1f
    cmp esi, [rdi + JV_n]
    jae 1f
    mov rcx, [rdi + JV_ptr]
    mov eax, esi
    shl rax, 4
    mov rdx, [rcx + rax + 8]
    mov rax, [rcx + rax]
1:  ret

# json_npairs(obj) -> pair count (0 unless an object)
FN json_npairs
    xor eax, eax
    test rdi, rdi
    jz 1f
    cmp dword ptr [rdi + JV_type], JT_OBJ
    jne 1f
    mov eax, [rdi + JV_n]
1:  ret

.section .rodata
.Ls_true: .asciz "true"
.Ls_false: .asciz "false"
.Ls_null: .asciz "null"
.text

# ---------- builder: one message at a time, into an SB ----------
.bss
.p2align 3
# limits: nesting at most 64 deep; jw_key and jw_end_* at depth 0 are caller errors (unguarded)
jw_first: .quad 0           # bit d set: no item written yet at depth d
jw_depth: .long 0
jv_cut: .long 0             # jv_write had to cut a container (jw_jv's result)

.text
# jw_begin(sb): empty the buffer and the nesting state
FN jw_begin
    mov qword ptr [rip + jw_first], 0
    mov dword ptr [rip + jw_depth], 0
    jmp sb_clear

# jw_reset(): the nesting state only, for a message appended to bytes already in the buffer
FN jw_reset
    mov qword ptr [rip + jw_first], 0
    mov dword ptr [rip + jw_depth], 0
    ret

# jw_sep(sb): a comma before any item but the first of its container
jw_sep:
    mov ecx, [rip + jw_depth]
    test ecx, ecx
    jz 1f
    dec ecx
    bt qword ptr [rip + jw_first], rcx
    jnc 2f
    btr qword ptr [rip + jw_first], rcx
1:  ret
2:  mov esi, ','
    jmp sb_push_byte

# jw_open(sb, byte): a container; the next item at the new depth is first
jw_open:
    push rsi
    push rdi
    call jw_sep
    pop rdi
    pop rsi
    push rdi
    call sb_push_byte
    pop rdi
    mov ecx, [rip + jw_depth]
    bts qword ptr [rip + jw_first], rcx
    inc dword ptr [rip + jw_depth]
    ret

FN jw_obj
    mov esi, '{'
    jmp jw_open
FN jw_arr
    mov esi, '['
    jmp jw_open

# jw_close(sb, byte)
jw_close:
    mov ecx, [rip + jw_depth]
    dec ecx
    mov [rip + jw_depth], ecx
    btr qword ptr [rip + jw_first], rcx
    jmp sb_push_byte
FN jw_end_obj
    mov esi, '}'
    jmp jw_close
FN jw_end_arr
    mov esi, ']'
    jmp jw_close

# jw_key(sb, cstr): "key": with the separator; the value that follows is not an item
FN jw_key
    push rdi
    push rsi
    sub rsp, 8                  # strlen is called with the stack aligned
    mov rdi, rsi
    call strlen
    add rsp, 8
    mov rdx, rax
    pop rsi
    pop rdi
    jmp jw_keyn

# jw_keyn(sb, ptr, len): jw_key for a key that is not NUL-terminated (a parsed key, a question's text)
FN jw_keyn
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call jw_sep
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call jw_quote
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    # the value is written next without a separator: mark the depth as "first" again
    mov ecx, [rip + jw_depth]
    dec ecx
    bts qword ptr [rip + jw_first], rcx
    pop r13
    pop r12
    pop rbx
    ret

# jw_cstr(sb, cstr) / jw_str(sb, ptr, len): a quoted, escaped string item
FN jw_cstr
    push rdi
    push rsi
    sub rsp, 8
    mov rdi, rsi
    call strlen
    add rsp, 8
    mov rdx, rax
    pop rsi
    pop rdi
    jmp jw_str
FN jw_str
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call jw_sep
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call jw_quote
    pop r13
    pop r12
    pop rbx
    ret

# jw_quote(sb, ptr, len): "..." with \" \\ \n \r \t and \u00XX for other bytes below 0x20 and for
#   0x7f. Bytes that are not UTF-8 (a stray byte, a surrogate, past U+10FFFF) become U+FFFD: a
#   document or path may hold them, and JSON readers such as Python's reject them.
jw_quote:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    mov esi, '"'
    call sb_push_byte
1:  test r13, r13
    jz 8f
    mov r15d, 1                 # bytes this step consumes
    movzx r14d, byte ptr [r12]
    cmp r14d, 0x80
    jae 5f
    cmp r14d, '"'
    je 2f
    cmp r14d, '\\'
    je 2f
    cmp r14d, 0x20
    jb 3f
    cmp r14d, 0x7f
    je 4f
    mov rdi, rbx
    mov esi, r14d
    call sb_push_byte
    jmp 7f
2:  mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
    mov rdi, rbx
    mov esi, r14d
    call sb_push_byte
    jmp 7f
3:  cmp r14d, 10
    jne 31f
    mov esi, 'n'
    jmp 32f
31: cmp r14d, 13
    jne 33f
    mov esi, 'r'
    jmp 32f
33: cmp r14d, 9
    jne 4f
    mov esi, 't'
32: push rsi
    mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
    pop rsi
    mov rdi, rbx
    call sb_push_byte
    jmp 7f
4:  # \u00XX
    mov rdi, rbx
    lea rsi, [rip + .Ljw_u00]
    call sb_push_cstr
    lea rcx, [rip + .Ljw_hex]
    mov eax, r14d
    shr eax, 4
    movzx esi, byte ptr [rcx + rax]
    mov rdi, rbx
    call sb_push_byte
    lea rcx, [rip + .Ljw_hex]
    mov eax, r14d
    and eax, 15
    movzx esi, byte ptr [rcx + rax]
    mov rdi, rbx
    call sb_push_byte
    jmp 7f
5:  # a multibyte character: copied when it is UTF-8, else U+FFFD for its first byte
    mov rdi, r12
    mov rsi, r13
    call utf8_decode
    cmp eax, 0xfffd
    jne 51f
    cmp edx, 3
    jne 6f
51: lea ecx, [rax - 0xd800]
    cmp ecx, 0x7ff
    jbe 6f
    cmp eax, 0x10ffff
    ja 6f
    mov r15d, edx
    mov rdi, rbx
    mov rsi, r12
    call sb_push
    jmp 7f
6:  mov rdi, rbx
    lea rsi, [rip + .Ljw_fffd]
    mov edx, 3
    call sb_push
7:  add r12, r15
    sub r13, r15
    jmp 1b
8:  mov rdi, rbx
    mov esi, '"'
    call sb_push_byte
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# jw_u64(sb, n): an unsigned number item
FN jw_u64
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call jw_sep
    mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    pop r13
    pop r12
    pop rbx
    ret

# jw_int(sb, n): a signed number item
FN jw_int
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call jw_sep
    test r12, r12
    jns 1f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    neg r12
1:  mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    pop r13
    pop r12
    pop rbx
    ret

# jw_bool(sb, b): true for a nonzero b, else false
FN jw_bool
    lea rax, [rip + .Ls_true]
    test esi, esi
    jnz 1f
    lea rax, [rip + .Ls_false]
1:  mov rsi, rax
    jmp jw_raw

# jw_null(sb)
FN jw_null
    lea rsi, [rip + .Ls_null]
    jmp jw_raw

# jw_raw(sb, cstr): true, false, null or a number already formatted
FN jw_raw
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call jw_sep
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    pop r13
    pop r12
    pop rbx
    ret

# jw_rawn(sb, ptr, len): an item already formatted as JSON (a value kept from an earlier message)
FN jw_rawn
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call jw_sep
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    pop r13
    pop r12
    pop rbx
    ret

# jw_jv(sb, jv) -> eax 1, or 0 when the value could not be written back unchanged: a parsed value written
#   back, strings escaped again, numbers as their source text (so the parsed line must still be in memory),
#   arrays and objects item by item. A null pointer writes null. A container that would open at builder
#   depth 60 or deeper is written as null (the output stays balanced) and the result is 0: a caller that
#   echoes a value (a tool's input) must treat 0 as "cannot echo" and fail closed.
FN jw_jv
    push rbx
    mov dword ptr [rip + jv_cut], 0
    call jv_write
    xor eax, eax
    cmp dword ptr [rip + jv_cut], 0
    sete al
    pop rbx
    ret

# jv_write(sb, jv): jw_jv's recursion; a cut sets jv_cut
jv_write:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz .Ljv_null
    mov eax, [r12 + JV_type]
    cmp eax, JT_STR
    je .Ljv_str
    cmp eax, JT_NUM
    je .Ljv_num
    cmp eax, JT_TRUE
    je .Ljv_true
    cmp eax, JT_FALSE
    je .Ljv_false
    cmp eax, JT_ARR
    je .Ljv_arr
    cmp eax, JT_OBJ
    je .Ljv_obj
    jmp .Ljv_null
.Ljv_cut:
    mov dword ptr [rip + jv_cut], 1
.Ljv_null:
    lea rsi, [rip + .Ls_null]
    jmp 1f
.Ljv_true:
    lea rsi, [rip + .Ls_true]
    jmp 1f
.Ljv_false:
    lea rsi, [rip + .Ls_false]
1:  mov rdi, rbx
    call jw_raw
    EPILOGUE
.Ljv_str:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, [r12 + JV_n]
    call jw_str
    EPILOGUE
.Ljv_num:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, [r12 + JV_n]
    call jw_rawn
    EPILOGUE
.Ljv_arr:
    cmp dword ptr [rip + jw_depth], 60
    jae .Ljv_cut
    mov rdi, rbx
    call jw_arr
    xor r13d, r13d
2:  cmp r13d, [r12 + JV_n]
    jae 3f
    mov rax, [r12 + JV_ptr]
    mov rsi, [rax + r13*8]
    mov rdi, rbx
    call jv_write
    inc r13d
    jmp 2b
3:  mov rdi, rbx
    call jw_end_arr
    EPILOGUE
.Ljv_obj:
    cmp dword ptr [rip + jw_depth], 60
    jae .Ljv_cut
    mov rdi, rbx
    call jw_obj
    xor r13d, r13d
4:  cmp r13d, [r12 + JV_n]
    jae 5f
    mov rax, [r12 + JV_ptr]
    mov rcx, r13
    shl rcx, 4
    mov r14, [rax + rcx]        # the key (a string node)
    mov r15, [rax + rcx + 8]    # the value
    mov rdi, rbx
    mov rsi, [r14 + JV_ptr]
    mov edx, [r14 + JV_n]
    call jw_keyn
    mov rdi, rbx
    mov rsi, r15
    call jv_write
    inc r13d
    jmp 4b
5:  mov rdi, rbx
    call jw_end_obj
    EPILOGUE

# FN json_pretty(sb, jv): the value appended as JSON.stringify(v, null, 2) writes it: a member or an item a
#   line, two blanks a level, ": " after a key, "[]" and "{}" for empty ones; a container more than 64
#   levels deep is "…". Strings are escaped as jw_quote escapes them. It does not touch the builder's state
FN json_pretty
    xor edx, edx
    jmp jp_write

# jp_write(sb, jv, depth): json_pretty's recursion
jp_write:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    test r12, r12
    jz .Ljp_null
    mov eax, [r12 + JV_type]
    cmp eax, JT_STR
    je .Ljp_str
    cmp eax, JT_NUM
    je .Ljp_num
    cmp eax, JT_TRUE
    je .Ljp_true
    cmp eax, JT_FALSE
    je .Ljp_false
    cmp eax, JT_ARR
    je .Ljp_cont
    cmp eax, JT_OBJ
    je .Ljp_cont
.Ljp_null:
    lea rsi, [rip + .Ls_null]
    jmp 1f
.Ljp_true:
    lea rsi, [rip + .Ls_true]
    jmp 1f
.Ljp_false:
    lea rsi, [rip + .Ls_false]
1:  mov rdi, rbx
    call sb_push_cstr
    EPILOGUE
.Ljp_str:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, [r12 + JV_n]
    call jw_quote
    EPILOGUE
.Ljp_num:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, [r12 + JV_n]
    call sb_push
    EPILOGUE
.Ljp_cont:
    mov r15d, '['
    cmp eax, JT_ARR
    je 2f
    mov r15d, '{'
2:  cmp dword ptr [r12 + JV_n], 0
    jne 3f
    mov rdi, rbx                # empty: "[]", "{}"
    mov esi, r15d
    call sb_push_byte
    mov rdi, rbx
    lea esi, [r15 + 2]
    call sb_push_byte
    EPILOGUE
3:  cmp r13d, 64
    jb 4f
    mov rdi, rbx
    lea rsi, [rip + .Ljp_cut]
    call sb_push_cstr
    EPILOGUE
4:  mov rdi, rbx
    mov esi, r15d
    call sb_push_byte
    xor r14d, r14d
5:  cmp r14d, [r12 + JV_n]
    jae 8f
    test r14d, r14d
    jz 51f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
51: lea esi, [r13 + 1]
    mov rdi, rbx
    call jp_indent
    mov rax, [r12 + JV_ptr]
    cmp r15d, '['
    jne 6f
    mov rsi, [rax + r14*8]
    jmp 7f
6:  mov rcx, r14                # a member: its key, ": ", its value
    shl rcx, 4
    mov rdx, [rax + rcx]
    mov rcx, [rax + rcx + 8]
    mov [rsp], rcx
    mov rdi, rbx
    mov rsi, [rdx + JV_ptr]
    mov edx, [rdx + JV_n]
    call jw_quote
    mov rdi, rbx
    lea rsi, [rip + .Ljp_colon]
    call sb_push_cstr
    mov rsi, [rsp]
7:  mov rdi, rbx
    lea edx, [r13 + 1]
    call jp_write
    inc r14d
    jmp 5b
8:  mov rdi, rbx
    mov esi, r13d
    call jp_indent
    mov rdi, rbx
    lea esi, [r15 + 2]
    call sb_push_byte
    EPILOGUE

# jp_indent(sb, depth): a line feed and two blanks a level
jp_indent:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov esi, 10
    call sb_push_byte
    add r12d, r12d
1:  test r12d, r12d
    jz 9f
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    dec r12d
    jmp 1b
9:  EPILOGUE

.section .rodata
.Ljp_cut: .asciz "…"
.Ljp_colon: .asciz ": "
.text

# jw_line(sb): the record terminator
FN jw_line
    mov esi, 10
    jmp sb_push_byte

.section .rodata
.Ljw_u00: .asciz "\\u00"
.Ljw_hex: .ascii "0123456789abcdef"
.Ljw_fffd: .byte 0xef, 0xbf, 0xbd
.text

# json_trim(): after a large parse, drop the oversized newest block for a fresh 1 MiB one.
# Every JV* from the last parse is invalid afterwards, as after the next json_parse.
FN json_trim
    push rbx
    call json_reset             # older blocks go in any case
    mov rax, [rip + arena]
    test rax, rax
    jz 9f
    cmp qword ptr [rip + arena_cap], 1 << 20
    jbe 9f
    mov rdi, rax
    call mem_free
    mov edi, 1 << 20
    call mem_alloc
    mov qword ptr [rax], 0
    mov [rip + arena], rax
    mov qword ptr [rip + arena_cap], 1 << 20
    mov qword ptr [rip + arena_top], 8
9:  pop rbx
    ret

# json_arena_cap() -> the newest block's capacity (tests)
FN json_arena_cap
    mov rax, [rip + arena_cap]
    ret
