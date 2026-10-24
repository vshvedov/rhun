# Headless control commands of the language features (--script and --control; control.s looks
# them up in langfeat_ctl): print-langstats, print-provides, print-query and the ones later stages
# add. Each writes its answer into the control's output buffer.
.include "rhun.inc"

.bss
.p2align 3
lc_out: .quad 0                 # the SB the answer goes to
lc_rest: .quad 0                # the rest of the line after the command's name
lc_rlen: .quad 0

.text

# LCWRAP: a table entry fn(out, rest, rest len) that keeps them for lc_arg, then runs the command
.macro LCWRAP name, target
\name:
    mov [rip + lc_out], rdi
    mov [rip + lc_rest], rsi
    mov [rip + lc_rlen], rdx
    sub rsp, 8
    call \target
    add rsp, 8
    xor eax, eax
    ret
.endm
    LCWRAP w_print_langstats, c_print_langstats
    LCWRAP w_print_provides, c_print_provides
    LCWRAP w_print_query, c_print_query
    LCWRAP w_print_fd, c_print_fd
    LCWRAP w_print_results, c_print_results
    LCWRAP w_print_outline, c_print_outline
    LCWRAP w_print_peek, c_print_peek
    LCWRAP w_print_hover_card, c_print_hover_card
    LCWRAP w_hover_at, c_hover_at
    LCWRAP w_print_lightbulb, c_print_lightbulb
    LCWRAP w_print_lf_waits, c_print_lf_waits
    LCWRAP w_print_doc_links, c_print_doc_links
    LCWRAP w_print_definition_link, c_print_definition_link
    LCWRAP w_print_point, c_print_point

# lc_arg() -> rax ptr, rdx len of the next word of the rest (rdx 0 at its end)
lc_arg:
    mov rax, [rip + lc_rest]
    mov rcx, [rip + lc_rlen]
1:  test rcx, rcx
    jz 3f
    cmp byte ptr [rax], ' '
    jne 2f
    inc rax
    dec rcx
    jmp 1b
2:  xor edx, edx
21: cmp rdx, rcx
    jae 22f
    cmp byte ptr [rax + rdx], ' '
    je 22f
    inc rdx
    jmp 21b
22: lea r8, [rax + rdx]
    mov [rip + lc_rest], r8
    sub rcx, rdx
    mov [rip + lc_rlen], rcx
    ret
3:  mov [rip + lc_rest], rax
    mov qword ptr [rip + lc_rlen], 0
    xor edx, edx
    ret

# lc_ext() -> rax the EXT named by the next word, or 0 (and "no such extension" in the answer)
lc_ext:
    push rbx
    call lc_arg
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call ext_by_name
    test rax, rax
    jnz 9f
8:  mov rdi, [rip + lc_out]
    lea rsi, [rip + .Lno_ext]
    call sb_push_cstr
    xor eax, eax
9:  pop rbx
    ret

# print-langstats [OWNER/NAME]: each kind an extension was asked, with its numbers (query.s)
c_print_langstats:
    push rbx
    call lc_arg
    xor esi, esi
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call ext_by_name
    mov rsi, rax
    test rax, rax
    jnz 1f
    mov rdi, [rip + lc_out]
    lea rsi, [rip + .Lno_ext]
    call sb_push_cstr
    pop rbx
    ret
1:  mov rdi, [rip + lc_out]
    call query_dump_stats
    pop rbx
    ret

# print-provides OWNER/NAME: its [provides] values in force, "KEY = VALUES" each
c_print_provides:
    push rbx
    call lc_ext
    test rax, rax
    jz 9f
    mov rsi, rax
    mov rdi, [rip + lc_out]
    call query_dump_provides
9:  pop rbx
    ret

# print-file-diagnostics: the Problems store (problems_dump), where file-diagnostics go
c_print_fd:
    push rbx
    mov rdi, [rip + lc_out]
    call problems_dump
    pop rbx
    ret

# print-results: the Results panel's shown set and its rows (results.s)
c_print_results:
    push rbx
    mov rdi, [rip + lc_out]
    call results_dump
    pop rbx
    ret

# print-outline: the Outline section's rows (outline.s)
c_print_outline:
    push rbx
    mov rdi, [rip + lc_out]
    call outline_dump
    pop rbx
    ret

# print-peek: the peek view (peek.s)
c_print_peek:
    push rbx
    mov rdi, [rip + lc_out]
    call peek_dump
    pop rbx
    ret

# print-hover-card: the hover card (hovercard.s)
c_print_hover_card:
    push rbx
    mov rdi, [rip + lc_out]
    call hovercard_dump
    pop rbx
    ret

# hover-at LINE COL: the pointer over that place of the editor's text
c_hover_at:
    push rbx
    call lc_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov rbx, rax
    call lc_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov rsi, rax
    mov rdi, rbx
    call hovercard_point
    pop rbx
    ret

# print-lightbulb: the lightbulb (lightbulb.s)
c_print_lightbulb:
    push rbx
    mov rdi, [rip + lc_out]
    call lightbulb_dump
    pop rbx
    ret

# print-links: the document links held (doclinks.s)
c_print_doc_links:
    push rbx
    mov rdi, [rip + lc_out]
    call doclinks_dump
    pop rbx
    ret

c_print_definition_link:
    push rbx
    mov rdi, [rip + lc_out]
    call definitionlink_dump
    pop rbx
    ret

# print-point LINE COL: "point X Y", the window pixel of that place of the editor's text
c_print_point:
    push rbx
    call lc_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov rbx, rax
    call lc_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov rsi, rax
    mov rdi, rbx
    call hovercard_xy
    test eax, eax
    js 9f
    mov ebx, edx
    push rax
    push rax
    mov rdi, [rip + lc_out]
    lea rsi, [rip + .Lpoint]
    call sb_push_cstr
    pop rsi
    pop rsi
    mov rdi, [rip + lc_out]
    call sb_push_u64
    mov rdi, [rip + lc_out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, [rip + lc_out]
    mov esi, ebx
    call sb_push_u64
    mov rdi, [rip + lc_out]
    mov esi, 10
    call sb_push_byte
9:  pop rbx
    ret

# print-langfeat-waits: "outline=N hover=N lightbulb=N": the ms until each wants a tick (-1 none),
# so tests see that nothing keeps the loop polling
c_print_lf_waits:
    push rbx
    mov rdi, [rip + lc_out]
    lea rsi, [rip + .Lw_outline]
    call sb_push_cstr
    call outline_timeout
    call lc_push_int
    mov rdi, [rip + lc_out]
    lea rsi, [rip + .Lw_hover]
    call sb_push_cstr
    call hovercard_timeout
    call lc_push_int
    mov rdi, [rip + lc_out]
    lea rsi, [rip + .Lw_bulb]
    call sb_push_cstr
    call lightbulb_timeout
    call lc_push_int
    mov rdi, [rip + lc_out]
    mov esi, 10
    call sb_push_byte
    pop rbx
    ret

# lc_push_int(eax): a signed number into the answer
lc_push_int:
    push rbx
    mov ebx, eax
    test ebx, ebx
    jns 1f
    mov rdi, [rip + lc_out]
    mov esi, '-'
    call sb_push_byte
    neg ebx
1:  mov rdi, [rip + lc_out]
    mov esi, ebx
    call sb_push_u64
    pop rbx
    ret

# print-query: the requests rhun waits on, with their progress
c_print_query:
    push rbx
    mov rdi, [rip + lc_out]
    call query_dump_pending
    pop rbx
    ret

.section .rodata
.Lno_ext: .asciz "no such extension\n"
.Lc_print_langstats: .asciz "print-langstats"
.Lc_print_provides: .asciz "print-provides"
.Lc_print_query: .asciz "print-query"
.Lc_print_fd: .asciz "print-file-diagnostics"
.Lc_print_results: .asciz "print-results"
.Lc_print_outline: .asciz "print-outline"
.Lc_print_peek: .asciz "print-peek"
.Lc_print_hover_card: .asciz "print-hover-card"
.Lc_hover_at: .asciz "hover-at"
.Lc_print_lightbulb: .asciz "print-lightbulb"
.Lc_print_lf_waits: .asciz "print-langfeat-waits"
.Lw_outline: .asciz "outline="
.Lw_hover: .asciz " hover="
.Lw_bulb: .asciz " lightbulb="
.Lc_print_doc_links: .asciz "print-doc-links"
.Lc_print_definition_link: .asciz "print-definition-link"
.Lc_print_point: .asciz "print-point"
.Lpoint: .asciz "point "
.p2align 3
.globl langfeat_ctl
langfeat_ctl:
    .quad .Lc_print_langstats, w_print_langstats
    .quad .Lc_print_provides, w_print_provides
    .quad .Lc_print_query, w_print_query
    .quad .Lc_print_fd, w_print_fd
    .quad .Lc_print_results, w_print_results
    .quad .Lc_print_outline, w_print_outline
    .quad .Lc_print_peek, w_print_peek
    .quad .Lc_print_hover_card, w_print_hover_card
    .quad .Lc_hover_at, w_hover_at
    .quad .Lc_print_lightbulb, w_print_lightbulb
    .quad .Lc_print_lf_waits, w_print_lf_waits
    .quad .Lc_print_doc_links, w_print_doc_links
    .quad .Lc_print_definition_link, w_print_definition_link
    .quad .Lc_print_point, w_print_point
    .quad 0, 0
