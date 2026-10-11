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
.Lv_text_end:
.Lk_n: .asciz "n"
.Lk_list: .asciz "list"
.Lv_true: .asciz "true"
.Lv_null: .asciz "null"
.Lk_empty: .asciz "empty"
