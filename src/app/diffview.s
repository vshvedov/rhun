# diff view: the changes of a file as a read-only document
.include "rhun.inc"

.bss
.p2align 3
text: .zero SB_SIZE             # diff view being filled
dls: .zero VEC_SIZE             # its DL records
tmp_sb: .zero SB_SIZE
dseq: .quad 0

.text

# ---------------- diff view ----------------

# git_open_diff(rev cstr or 0, path ptr, len): a file's changes in a commit (or the work tree against HEAD)
FN git_open_diff
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    cmp dword ptr [rip + g_git_on], 0
    je 9f
    # open already: show it, fetched again
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 3f
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 2f
    mov r15, [rax + TAB_doc]
    mov rax, [r15 + DOC_diff]
    test rax, rax
    jz 2f
    mov [rsp], rax
    mov rdi, [rax + DV_path]
    call strlen
    cmp rax, r14
    jne 2f
    mov rax, [rsp]
    mov rdi, [rax + DV_path]
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jz 2f
    mov rax, [rsp]
    mov rdi, [rax + DV_rev]
    test r12, r12
    jnz 11f
    test rdi, rdi
    jnz 2f
    jmp 12f
11: test rdi, rdi
    jz 2f
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jz 2f
12: mov rdi, rbx
    call app_activate_tab
    mov rdi, r15
    call diff_fetch
    jmp 9f
2:  inc rbx
    jmp 1b
3:  call doc_new
    mov r15, rax
    or dword ptr [r15 + DOC_flags], DF_READONLY
    mov edi, DV_SIZE
    call mem_alloc
    mov rbx, rax
    mov [r15 + DOC_diff], rax
    mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov [rbx + DV_path], rax
    test r12, r12
    jz 4f
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [rbx + DV_rev], rax
4:  # "name (changes)", "name (1a2b3c4)"
    lea rdi, [rip + tmp_sb]
    call sb_clear
    mov rdi, r13
    mov rsi, r14
    call path_basename
    lea rdi, [rip + tmp_sb]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + tmp_sb]
    lea rsi, [rip + .Lparen]
    call sb_push_cstr
    test r12, r12
    jz 5f
    lea rdi, [rip + tmp_sb]
    mov rsi, r12
    mov edx, 7
    call sb_push
    jmp 6f
5:  lea rdi, [rip + tmp_sb]
    lea rsi, [rip + .Lchanges]
    call sb_push_cstr
6:  lea rdi, [rip + tmp_sb]
    mov esi, ')'
    call sb_push_byte
    mov rdi, [rip + tmp_sb + SB_ptr]
    mov rsi, [rip + tmp_sb + SB_len]
    call mem_dup
    mov [rbx + DV_name], rax
    mov [r15 + DOC_name], rax
    mov rdi, [rbx + DV_path]
    lea rsi, [rip + .Lempty]
    xor edx, edx
    call syntax_detect
    mov [r15 + DOC_lang], rax
    mov rdi, r15
    mov esi, TAB_DOC
    call app_add_tab
    mov rdi, r15
    call diff_fetch
9:  EPILOGUE

# diff_fetch(doc): ask git for the diff shown in doc
diff_fetch:
    PROLOGUE 96
    mov rbx, rdi
    mov r12, [rbx + DOC_diff]
    mov edi, 32
    call mem_alloc
    mov r13, rax
    mov qword ptr [r13], 1
    mov [r13 + 16], rbx
    inc qword ptr [rip + dseq]
    mov rax, [rip + dseq]
    mov [rbx + DOC_gseq], eax
    mov [r13 + 24], rax
    lea rax, [rip + .Lno_color]
    mov [rsp + 8], rax
    lea rax, [rip + .Lno_ext]
    mov [rsp + 16], rax
    mov rax, [r12 + DV_rev]
    test rax, rax
    jnz 3f
    # the work tree against HEAD; untracked files against nothing
    lea rax, [rip + .Ldiff]
    mov [rsp], rax
    mov rdi, [r12 + DV_path]
    call strlen
    mov rdi, [r12 + DV_path]
    mov rsi, rax
    call git_status_rel
    cmp eax, 'U'
    je 1f
    lea rax, [rip + .Lhead]
    mov [rsp + 24], rax
    mov ecx, 4
    jmp 5f
1:  lea rax, [rip + .Lno_index]
    mov [rsp + 24], rax
    lea rax, [rip + .Ldashdash]
    mov [rsp + 32], rax
    lea rax, [rip + .Ldevnull]
    mov [rsp + 40], rax
    mov rax, [r12 + DV_path]
    mov [rsp + 48], rax
    mov qword ptr [rsp + 56], 0
    jmp 6f
3:  # a commit against its first parent
    lea rax, [rip + .Lshow]
    mov [rsp], rax
    lea rax, [rip + .Lformat]
    mov [rsp + 24], rax
    lea rax, [rip + .Ldash_m]
    mov [rsp + 32], rax
    lea rax, [rip + .Lfirst_parent]
    mov [rsp + 40], rax
    mov rax, [r12 + DV_rev]
    mov [rsp + 48], rax
    mov ecx, 7
5:  lea rax, [rip + .Ldashdash]
    mov [rsp + rcx*8], rax
    mov rax, [r12 + DV_path]
    mov [rsp + rcx*8 + 8], rax
    mov qword ptr [rsp + rcx*8 + 16], 0
6:  mov rdi, rsp
    lea rsi, [rip + diffview_answer]
    mov rdx, r13
    xor ecx, ecx
    xor r8d, r8d
    call git_run
    EPILOGUE

# diffview_answer(ctx, ptr, len, status): unified diff into the view's text and line records
FN diffview_answer
    PROLOGUE 48
    mov rbx, [rdi + 16]
    test rbx, rbx
    jz 9f
    mov eax, [rdi + 24]
    cmp [rbx + DOC_gseq], eax
    jne 9f
    mov r12, rsi
    lea r13, [rsi + rdx]
    lea rdi, [rip + text]
    call sb_clear
    mov qword ptr [rip + dls + VEC_len], 0
    xor r14d, r14d              # old line number
    xor r15d, r15d              # new line number
    mov dword ptr [rsp], 0      # inside a hunk
    mov dword ptr [rsp + 4], 0  # binary
    mov dword ptr [rsp + 8], 0  # largest number
.Lda_line:
    cmp r12, r13
    jae .Lda_done
    mov rcx, r12
1:  cmp rcx, r13
    jae 2f
    cmp byte ptr [rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  lea rax, [rcx + 1]
    mov [rsp + 16], rax         # next line
    mov rdx, rcx
    sub rdx, r12                # length
    jz .Lda_next
    cmp byte ptr [rcx - 1], 13
    jne 3f
    dec rdx
3:  mov [rsp + 24], rdx
    movzx eax, byte ptr [r12]
    cmp eax, '@'
    jne 4f
    cmp rdx, 3
    jb 4f
    cmp word ptr [r12 + 1], 0x2040  # "@ "
    jne 4f
    call hunk_start
    mov dword ptr [rsp], 1
    mov edi, DK_HUNK
    mov rsi, r12
    mov rdx, [rsp + 24]
    xor ecx, ecx
    xor r8d, r8d
    call emit
    jmp .Lda_next
4:  cmp dword ptr [rsp], 0
    jne 5f
    # headers before the first hunk
    mov rdi, r12
    mov rsi, [rsp + 24]
    lea rdx, [rip + .Lbinary]
    mov ecx, 6
    call str_starts
    or [rsp + 4], eax
    jmp .Lda_next
5:  movzx eax, byte ptr [r12]
    lea rsi, [r12 + 1]
    mov rdx, [rsp + 24]
    dec rdx
    cmp eax, ' '
    jne 6f
    inc r14d
    inc r15d
    mov edi, DK_CTX
    mov ecx, r14d
    mov r8d, r15d
    call emit
    jmp .Lda_next
6:  cmp eax, '-'
    jne 7f
    inc r14d
    mov edi, DK_DEL
    mov ecx, r14d
    xor r8d, r8d
    call emit
    jmp .Lda_next
7:  cmp eax, '+'
    jne 8f
    inc r15d
    mov edi, DK_ADD
    xor ecx, ecx
    mov r8d, r15d
    call emit
    jmp .Lda_next
8:  cmp eax, 'd'                # "diff --git" of the next file
    jne .Lda_next
    mov dword ptr [rsp], 0
.Lda_next:
    mov r12, [rsp + 16]
    jmp .Lda_line
.Lda_done:
    cmp qword ptr [rip + dls + VEC_len], 0
    jne 1f
    lea rsi, [rip + .Lno_changes]
    cmp dword ptr [rsp + 4], 0
    je 11f
    lea rsi, [rip + .Lbinary_file]
11: mov rdi, rsi
    push rsi
    push rsi
    call strlen
    pop rsi
    pop rsi
    mov rdx, rax
    mov edi, DK_INFO
    xor ecx, ecx
    xor r8d, r8d
    call emit
1:  # the text, then the line records
    mov rdi, rbx
    mov rsi, [rip + text + SB_ptr]
    mov rdx, [rip + text + SB_len]
    call doc_replace_all
    mov r12, [rbx + DOC_diff]
    mov rdi, [r12 + DV_lines]
    call mem_free
    mov rax, [rip + dls + VEC_len]
    mov [r12 + DV_n], rax
    imul rdi, rax, DL_SIZE
    mov r13, rdi
    call mem_alloc
    mov [r12 + DV_lines], rax
    mov rdi, rax
    mov rsi, [rip + dls + VEC_ptr]
    mov rdx, r13
    call memcpy
    mov eax, [rsp + 8]
    mov [r12 + DV_maxno], eax
    mov qword ptr [rbx + DOC_svalid], 0
    mov rdi, rbx
    call doc_len
    cmp [rbx + DOC_cur], rax
    jbe 2f
    mov [rbx + DOC_cur], rax
2:  cmp [rbx + DOC_anchor], rax
    jbe 3f
    mov [rbx + DOC_anchor], rax
3:  mov rdi, rbx
    call ed_top_inside
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# hunk_start(): r14d, r15d from "@@ -a,b +c,d @@" at r12 (the line's length is the caller's [rsp + 24])
hunk_start:
    push rbx
    lea rcx, [r12 + 3]
    mov rdx, [rsp + 16 + 24]
    add rdx, r12
1:  cmp rcx, rdx
    jae 9f
    cmp byte ptr [rcx], '-'
    je 2f
    cmp byte ptr [rcx], '+'
    je 3f
    cmp byte ptr [rcx], '@'
    je 9f
    inc rcx
    jmp 1b
2:  call number
    lea r14d, [rax - 1]
    jmp 1b
3:  call number
    lea r15d, [rax - 1]
    jmp 1b
9:  # "-0,0" starts before the first line
    test r14d, r14d
    jns 4f
    xor r14d, r14d
4:  test r15d, r15d
    jns 5f
    xor r15d, r15d
5:  pop rbx
    ret
# number(): digits after [rcx] (rcx moves past them, rdx the end) -> rax
number:
    inc rcx
    xor eax, eax
1:  cmp rcx, rdx
    jae 2f
    movzx r8d, byte ptr [rcx]
    sub r8d, '0'
    cmp r8d, 9
    ja 2f
    imul eax, eax, 10
    add eax, r8d
    inc rcx
    jmp 1b
2:  ret

# emit(kind, ptr, len, old, new): one line of the view (keeps r12-r15)
emit:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    mov r15d, r8d
    cmp qword ptr [rip + dls + VEC_len], 0
    je 1f
    lea rdi, [rip + text]
    mov esi, 10
    call sb_push_byte
1:  lea rdi, [rip + text]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + dls]
    mov esi, DL_SIZE
    call vec_push
    mov [rax + DL_kind], ebx
    mov [rax + DL_old], r14d
    mov [rax + DL_new], r15d
    # the largest number sets the gutter width (caller's [rsp + 8])
    mov eax, r14d
    cmp r15d, eax
    cmovg eax, r15d
    cmp eax, [rbp + 16 + 8]
    jle 9f
    mov [rbp + 16 + 8], eax
9:  EPILOGUE

# diffview_free(dv)
FN diffview_free
    test rdi, rdi
    jz 9f
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + DV_lines]
    call mem_free
    mov rdi, [rbx + DV_name]
    call mem_free
    mov rdi, [rbx + DV_rev]
    call mem_free
    mov rdi, [rbx + DV_path]
    call mem_free
    mov rdi, rbx
    call mem_free
    pop rbx
9:  ret

# number_w(dv) -> eax width of a line number column
number_w:
    mov eax, [rdi + DV_maxno]
    mov ecx, 1
    mov r8d, 10
1:  cmp eax, r8d
    jb 2f
    xor edx, edx
    div r8d
    inc ecx
    jmp 1b
2:  cmp ecx, 3
    jge 3f
    mov ecx, 3
3:  imul ecx, [rip + g_cw]
    mov eax, ecx
    ret

# diffview_gutter(doc) -> eax gutter width: two line number columns and the sign
FN diffview_gutter
    mov rdi, [rdi + DOC_diff]
    call number_w
    add eax, eax
    add eax, [rip + g_mt + 4*MI_8]
    add eax, [rip + g_mt + 4*MI_12]
    add eax, [rip + g_mt + 4*MI_24]
    ret

# diffview_line(doc, line, y, h) -> 1 when the line is drawn completely (hunk headers, notes)
#   tints added and deleted lines, draws both line numbers and the sign
FN diffview_line
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov r15, [rbx + DOC_diff]
    cmp r12, [r15 + DV_n]
    jae .Ldl_no
    imul rax, r12, DL_SIZE
    add rax, [r15 + DV_lines]
    mov ecx, [rax + DL_kind]
    mov [rsp], ecx
    mov ecx, [rax + DL_old]
    mov [rsp + 4], ecx
    mov ecx, [rax + DL_new]
    mov [rsp + 8], ecx
    mov rdi, r15
    call number_w
    mov [rsp + 12], eax
    # background
    mov eax, [rsp]
    COLOR esi, T_GIT_ADD
    mov edx, 44
    cmp eax, DK_ADD
    je 1f
    COLOR esi, T_GIT_DEL
    cmp eax, DK_DEL
    je 1f
    COLOR esi, T_ACCENT
    mov edx, 22
    cmp eax, DK_HUNK
    jne 2f
1:  COLOR edi, T_BG
    call color_mix
    mov r8d, eax
    mov edi, [rip + g_ed_x]
    mov esi, r13d
    mov edx, [rip + g_ed_w]
    mov ecx, r14d
    call gfx_fill
2:  # line numbers
    mov edi, [rsp + 4]
    mov esi, [rip + g_ed_x]
    add esi, [rip + g_mt + 4*MI_8]
    add esi, [rsp + 12]
    call .Ldl_number
    mov edi, [rsp + 8]
    mov esi, [rip + g_ed_x]
    add esi, [rip + g_mt + 4*MI_8]
    add esi, [rip + g_mt + 4*MI_12]
    add esi, [rsp + 12]
    add esi, [rsp + 12]
    call .Ldl_number
    # sign
    mov eax, [rsp]
    lea rcx, [rip + .Lplus]
    COLOR r9d, T_GIT_ADD
    cmp eax, DK_ADD
    je 3f
    lea rcx, [rip + .Lminus]
    COLOR r9d, T_GIT_DEL
    cmp eax, DK_DEL
    jne 4f
3:  lea rdi, [rip + g_face_code]
    mov esi, [rip + g_ed_tx]
    sub esi, [rip + g_mt + 4*MI_16]
    mov edx, r13d
    add edx, [rip + g_base]
    mov r8d, 1
    call text_draw
4:  cmp dword ptr [rsp], DK_HUNK
    jb .Ldl_no
    # headers and notes: plain muted text
    mov edi, [rip + g_ed_tx]
    sub edi, [rip + g_mt + 4*MI_4]
    mov esi, [rip + g_ed_y]
    mov edx, [rip + g_ed_x]
    add edx, [rip + g_ed_w]
    sub edx, edi
    mov ecx, [rip + g_ed_h]
    call gfx_clip_push
    mov rdi, rbx
    mov rsi, r12
    call doc_line_text
    mov rcx, rax
    mov r8, rdx
    lea rdi, [rip + g_face_code]
    mov esi, [rip + g_ed_tx]
    sub esi, [rbx + DOC_scrollx]
    mov edx, r13d
    add edx, [rip + g_base]
    COLOR r9d, T_MUTED
    call text_draw
    call gfx_clip_pop
    mov eax, 1
    EPILOGUE
.Ldl_no:
    xor eax, eax
    EPILOGUE
# number edi (none when 0) right-aligned at esi
.Ldl_number:
    test edi, edi
    jz 9f
    push rbx
    push r12
    sub rsp, 40
    mov r12d, esi
    mov esi, edi
    lea rdi, [rsp]
    call fmt_u64
    mov rbx, rax
    lea rdi, [rip + g_face_code]
    lea rsi, [rsp]
    mov rdx, rbx
    call text_width
    mov esi, r12d
    sub esi, eax
    lea rdi, [rip + g_face_code]
    mov edx, r13d
    add edx, [rip + g_base]
    lea rcx, [rsp]
    mov r8, rbx
    COLOR r9d, T_LINENO
    call text_draw
    add rsp, 40
    pop r12
    pop rbx
9:  ret

# cmd_git_changes(): the changes of the current file (text or image)
FN cmd_git_changes
    PROLOGUE
    mov rbx, [rip + g_file]
    test rbx, rbx
    jz 9f
    mov rdi, [rbx + DOC_path]
    test rdi, rdi
    jz 9f
    call git_rel
    test rax, rax
    jz 9f
    xor edi, edi
    mov rsi, rax
    call git_open_diff
9:  EPILOGUE


.section .rodata
.Lparen: .asciz " ("
.Lchanges: .asciz "changes"
.Lempty: .asciz ""
.Ldiff: .asciz "diff"
.Lshow: .asciz "show"
.Lno_color: .asciz "--no-color"
.Lno_ext: .asciz "--no-ext-diff"
.Lhead: .asciz "HEAD"
.Lno_index: .asciz "--no-index"
.Ldashdash: .asciz "--"
.Ldevnull: .asciz "/dev/null"
.Lformat: .asciz "--format="
.Ldash_m: .asciz "-m"
.Lfirst_parent: .asciz "--first-parent"
.Lbinary: .ascii "Binary"
.Lbinary_file: .asciz "Binary file"
.Lno_changes: .asciz "No changes"
.Lplus: .ascii "+"
.Lminus: .ascii "-"
