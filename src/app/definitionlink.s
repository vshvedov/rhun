# Modifier-hover navigation feedback. A definition query checks the word under the
# pointer without touching the caret or the interactive navigation query. Only a
# nonempty, valid result makes the word a link. Moving, editing or releasing the
# modifier withdraws stale requests. Rendering uses each visual row's inlay layout.
.include "rhun.inc"

.equ DN_MAX_REQS, 8

.bss
.p2align 3
dn_doc: .quad 0
dn_docid: .quad 0
dn_version: .quad 0
dn_language: .quad 0
dn_start: .quad 0
dn_end: .quad 0
dn_checked: .long 0
dn_found: .long 0
dn_reqs: .zero 16 * DN_MAX_REQS
dn_nreqs: .quad 0
dn_buf: .zero SB_SIZE

.text

reset:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + dn_nreqs]
    jae 2f
    mov rax, rbx
    shl rax, 4
    lea rcx, [rip + dn_reqs]
    mov rdi, [rcx + rax]
    mov rsi, [rcx + rax + 8]
    call query_withdraw
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + dn_nreqs], 0
    mov qword ptr [rip + dn_doc], 0
    mov dword ptr [rip + dn_checked], 0
    mov dword ptr [rip + dn_found], 0
    EPILOGUE

current:
    xor eax, eax
    cmp rdi, [rip + dn_doc]
    jne 9f
    mov rcx, [rdi + DOC_id]
    cmp rcx, [rip + dn_docid]
    jne 9f
    mov rcx, [rdi + DOC_version]
    cmp rcx, [rip + dn_version]
    jne 9f
    mov rcx, [rdi + DOC_language_revision]
    cmp rcx, [rip + dn_language]
    jne 9f
    mov eax, 1
9:  ret

FN definitionlink_tick
    PROLOGUE
    call doclinks_held
    test eax, eax
    jz 8f
    mov rbx, [rip + g_hover_doc]
    test rbx, rbx
    jz 8f
    cmp rbx, [rip + g_doc]
    jne 8f
    cmp dword ptr [rip + g_mdown], 0
    jne 8f
    mov rdi, rbx
    mov rsi, [rip + g_hover_pos]
    call word_at
    cmp rax, rdx
    jae 8f
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    call current
    test eax, eax
    jz 1f
    cmp r12, [rip + dn_start]
    jne 1f
    cmp r13, [rip + dn_end]
    jne 1f
    cmp dword ptr [rip + dn_checked], 0
    jne 9f
    jmp 2f
1:  call reset
    mov [rip + dn_doc], rbx
    mov rax, [rbx + DOC_id]
    mov [rip + dn_docid], rax
    mov rax, [rbx + DOC_version]
    mov [rip + dn_version], rax
    mov rax, [rbx + DOC_language_revision]
    mov [rip + dn_language], rax
    mov [rip + dn_start], r12
    mov [rip + dn_end], r13
2:  mov rdi, rbx
    call ask
    jmp 9f
8:  call reset
9:  EPILOGUE

# Append a number and its separator to the request line.
number:
    push rbx
    lea rdi, [rip + dn_buf]
    call sb_push_u64
    lea rdi, [rip + dn_buf]
    mov esi, ' '
    call sb_push_byte
    pop rbx
    ret

ask:
    PROLOGUE 16
    mov rbx, rdi
    lea rdi, [rip + dn_buf]
    call sb_clear
    lea rdi, [rip + dn_buf]
    lea rsi, [rip + .Ldefinition]
    call sb_push_cstr
    mov rsi, [rbx + DOC_id]
    call number
    mov rsi, [rbx + DOC_version]
    call number
    mov rdi, rbx
    mov rsi, [rip + g_hover_pos]
    call lf_line_col
    mov [rsp], rdx
    mov rsi, rax
    call number
    mov rsi, [rsp]
    call number
    lea rdi, [rip + dn_buf]
    lea rsi, [rip + .Linvoked]
    call sb_push_cstr
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    cmp qword ptr [rip + dn_nreqs], DN_MAX_REQS
    jae 9f
    imul r13, r12, EXT_SIZE
    add r13, [rip + g_exts + VEC_ptr]
    inc r12
    mov rdi, r13
    call ext_is_visible
    test eax, eax
    jz 1b
    cmp dword ptr [r13 + EXT_status], ES_RUNNING
    jne 1b
    mov rdi, r13
    mov esi, FEAT_DEFINITION
    call ext_feature
    test eax, eax
    jz 1b
    mov rdi, r13
    mov esi, EXT_pv_definition
    call ext_pv
    mov rdi, rax
    mov rsi, rbx
    call extproto_matches
    test eax, eax
    jz 1b
    mov edi, 1
    call query_room
    test eax, eax
    jz 9f
    mov rdi, r13
    mov rsi, rbx
    mov rdx, [rip + dn_buf + SB_ptr]
    mov rcx, [rip + dn_buf + SB_len]
    call extproto_host_send
    test rax, rax
    jz 1b
    mov r14, rax
    mov rdi, r13
    mov rsi, rax
    mov edx, PK_DEFINITION
    mov ecx, QO_LANGFEAT
    call query_track
    mov rax, [rip + dn_nreqs]
    shl rax, 4
    lea rcx, [rip + dn_reqs]
    mov [rcx + rax], r13
    mov [rcx + rax + 8], r14
    inc qword ptr [rip + dn_nreqs]
    mov dword ptr [rip + dn_checked], 1
    jmp 1b
9:  EPILOGUE

find:
    xor ecx, ecx
1:  cmp rcx, [rip + dn_nreqs]
    jae 8f
    mov rax, rcx
    shl rax, 4
    lea rdx, [rip + dn_reqs]
    add rax, rdx
    inc rcx
    cmp [rax], rdi
    jne 1b
    cmp [rax + 8], rsi
    jne 1b
    ret
8:  xor eax, eax
    ret

# Validate locations without opening files or modifying the interactive result list.
parse:
    PROLOGUE 16
    cmp rsi, 1048576
    ja 8f
    mov edx, 10000
    call lf_head
    test rax, rax
    js 8f
    mov [rsp], rax
    mov r15, rax
1:  test r15, r15
    jz 7f
    dec r15
    call ps_line
    test eax, eax
    jz 8f
    call lf_four
    test eax, eax
    jz 8f
    call ps_num
    test edx, edx
    jz 8f
    test rax, rax
    jz 8f
    cmp rax, 4096
    ja 8f
    mov r12, rax
    call ps_num
    test edx, edx
    jz 8f
    mov r13, rax
    call ps_eol
    test eax, eax
    jz 8f
    mov rdi, r12
    call lf_take
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, r12
    call lf_path_ok
    test eax, eax
    jz 8f
    mov rdi, r13
    call lf_take
    test rax, rax
    jz 8f
    jmp 1b
7:  mov rax, [rip + ps_ptr]
    cmp rax, [rip + ps_end]
    jne 8f
    mov rax, [rsp]
    test rax, rax
    jz 9f
    mov dword ptr [rip + dn_found], 1
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE
8:  mov rax, -1
    EPILOGUE

FN definitionlink_reply
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], edx
    mov [rsp + 8], rcx
    mov [rsp + 16], r8
    call find
    test rax, rax
    jz 8f
    dec qword ptr [rip + dn_nreqs]
    mov rcx, [rip + dn_nreqs]
    shl rcx, 4
    lea rdx, [rip + dn_reqs]
    mov rsi, [rdx + rcx]
    mov [rax], rsi
    mov rsi, [rdx + rcx + 8]
    mov [rax + 8], rsi
    cmp dword ptr [rsp], 0
    je 7f
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call parse
    test rax, rax
    jns 7f
    mov rdi, rbx
    mov esi, PK_DEFINITION
    call query_dropped
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

FN definitionlink_part
    PROLOGUE 16
    mov [rsp], rdx
    mov [rsp + 8], rcx
    call find
    test rax, rax
    jz 8f
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call parse
    EPILOGUE
8:  mov rax, -2
    EPILOGUE

FN definitionlink_ext_gone
    # A cached confirmation must not outlive the provider that supplied it.
    jmp reset

# Same arguments as extmarks_row. vt_x accounts for tabs, inlays and wrapped rows.
FN definitionlink_row
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], rdx
    mov [rsp + 8], rcx
    mov [rsp + 16], r9d
    cmp dword ptr [rip + dn_found], 0
    je 9f
    cmp rbx, [rip + g_hover_doc]
    jne 9f
    call doclinks_held
    test eax, eax
    jz 9f
    mov rdi, rbx
    call current
    test eax, eax
    jz 9f
    mov rax, [rip + g_hover_pos]
    cmp rax, [rip + dn_start]
    jb 9f
    cmp rax, [rip + dn_end]
    ja 9f
    mov eax, [rip + g_my]
    sub eax, [rsp + 16]
    js 9f
    cmp eax, [rip + g_lh]
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov rdx, [rip + dn_end]
    sub rdx, rax
    js 9f
    mov rcx, [rip + dn_start]
    sub rcx, rax
    cmp rcx, [rsp]
    jge 1f
    mov rcx, [rsp]
1:  cmp rdx, [rsp + 8]
    jle 2f
    mov rdx, [rsp + 8]
2:  cmp rcx, rdx
    jge 9f
    mov [rsp + 24], rdx
    mov rdi, rcx
    mov esi, VTM_RIGHT
    call vt_x
    mov [rsp + 32], eax
    mov rdi, [rsp + 24]
    mov esi, VTM_LEFT
    call vt_x
    mov edi, [rsp + 32]
    cmp [rip + g_mx], edi
    jl 9f
    cmp [rip + g_mx], eax
    jge 9f
    sub eax, edi
    jle 9f
    mov edx, eax
    mov esi, [rsp + 16]
    add esi, [rip + g_lh]
    sub esi, [rip + g_mt + 4*MI_2]
    M ecx, MI_1
    COLOR r8d, T_ACCENT
    call gfx_fill
    mov dword ptr [rip + g_cursor], CUR_POINTER
9:  EPILOGUE

FN definitionlink_dump
    PROLOGUE
    mov r12, rdi
    lea rsi, [rip + .Lnone]
    cmp dword ptr [rip + dn_found], 0
    je 1f
    lea rsi, [rip + .Lfound]
1:  call sb_push_cstr
    EPILOGUE

.section .rodata
.Ldefinition: .asciz "definition "
.Linvoked: .asciz "invoked -"
.Lnone: .asciz "definition-link=none\n"
.Lfound: .asciz "definition-link=found\n"
