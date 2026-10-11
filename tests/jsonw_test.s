# jw_*: one message with every value kind and every escape the protocols need
.include "rhun.inc"
.bss
.p2align 3
out: .zero SB_SIZE
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
    lea rsi, [rip + .Lk_n]
    call jw_key
    mov rdi, rbx
    mov rsi, -1                 # 18446744073709551615
    call jw_u64
    mov rdi, rbx
    lea rsi, [rip + .Lk_list]
    call jw_key
    mov rdi, rbx
    call jw_arr
    mov rdi, rbx
    lea rsi, [rip + .Lv_true]
    call jw_raw
    mov rdi, rbx
    lea rsi, [rip + .Lv_false]
    call jw_raw
    mov rdi, rbx
    lea rsi, [rip + .Lv_null]
    call jw_raw
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
    mov rdi, [rbx + SB_ptr]
    mov rsi, [rbx + SB_len]
    call log_write
    xor eax, eax
    EPILOGUE
.section .rodata
.Lk_type: .asciz "type"
.Lv_user: .asciz "user"
.Lk_text: .asciz "text"
.Lv_text: .ascii "say \"hi\"\\ \n\t"
    .byte 1, 0x1f, 0x7f
    .ascii "é"
    .byte 13
.Lv_text_end:
.Lk_n: .asciz "n"
.Lk_list: .asciz "list"
.Lv_true: .asciz "true"
.Lv_false: .asciz "false"
.Lv_null: .asciz "null"
.Lk_empty: .asciz "empty"
.Lsmall: .asciz "{}"
.Lgrown: .asciz "grown="
.Ltrimmed: .asciz " cap="
