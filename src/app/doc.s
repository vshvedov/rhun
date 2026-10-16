# document: gap buffer, line index, undo/redo, file io
.include "rhun.inc"

.equ GAP_MIN, 4096

.bss
.p2align 3
scratch: .zero SB_SIZE

.text

# doc_new() -> DOC* (empty, one line)
FN doc_new
    push rbx
    mov edi, DOC_SIZE
    call mem_alloc
    mov rbx, rax
    mov edi, GAP_MIN
    call mem_alloc
    mov [rbx + DOC_buf], rax
    mov qword ptr [rbx + DOC_cap], GAP_MIN
    mov qword ptr [rbx + DOC_gs], 0
    mov qword ptr [rbx + DOC_ge], GAP_MIN
    mov rdi, rbx
    mov esi, 64
    call lines_reserve
    mov rax, [rbx + DOC_lines]
    mov qword ptr [rax], 0
    mov qword ptr [rbx + DOC_nlines], 1
    mov qword ptr [rbx + DOC_prefx], -1
    lea rax, [rip + .Luntitled]
    mov [rbx + DOC_name], rax
    mov rax, rbx
    pop rbx
    ret

# doc_free(doc)
FN doc_free
    push rbx
    mov rbx, rdi
    cmp rdi, [rip + g_long_doc]   # its long line's classes and matched brackets go too (another doc
    jne 1f                        # may get its address)
    mov qword ptr [rip + g_long_doc], 0
1:  cmp rdi, [rip + g_br_doc]
    jne 2f
    mov qword ptr [rip + g_br_doc], 0
2:  call git_doc_free
    mov rdi, rbx
    lea rsi, [rbx + DOC_undo]
    call urec_clear
    mov rdi, rbx
    lea rsi, [rbx + DOC_redo]
    call urec_clear
    lea rdi, [rbx + DOC_undo]
    call vec_free
    lea rdi, [rbx + DOC_redo]
    call vec_free
    mov rdi, [rbx + DOC_buf]
    call mem_free
    mov rdi, [rbx + DOC_lines]
    call mem_free
    mov rdi, [rbx + DOC_states]
    call mem_free
    mov rdi, [rbx + DOC_lhash]
    call mem_free
    mov rdi, [rbx + DOC_path]
    call mem_free
    mov rdi, [rbx + DOC_real]
    call mem_free
    mov rdi, rbx
    call watch_hops_free
    mov rdi, [rbx + DOC_img]
    call iv_free
    mov rdi, rbx
    call mem_free
    pop rbx
    ret

# urec_clear(doc, vec): free texts, empty vec
urec_clear:
    push rbx
    push r12
    push r13
    mov r12, rsi
    xor ebx, ebx
1:  cmp rbx, [r12 + VEC_len]
    jae 2f
    imul rax, rbx, UR_SIZE
    add rax, [r12 + VEC_ptr]
    mov rdi, [rax + UR_text]
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [r12 + VEC_len], 0
    pop r13
    pop r12
    pop rbx
    ret

# lines_reserve(doc, n): capacity for n lines (starts, states, hashes)
lines_reserve:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    cmp r12, [rbx + DOC_lcap]
    jbe 1f
    mov rax, [rbx + DOC_lcap]
    add rax, rax
    cmp r12, rax
    cmovb r12, rax
    mov [rbx + DOC_lcap], r12
    mov rdi, [rbx + DOC_lines]
    lea rsi, [r12*8]
    call mem_realloc
    mov [rbx + DOC_lines], rax
    mov rdi, [rbx + DOC_states]
    lea rsi, [r12*4]
    call mem_realloc
    mov [rbx + DOC_states], rax
    mov rdi, [rbx + DOC_lhash]
    lea rsi, [r12*8]
    call mem_realloc
    mov [rbx + DOC_lhash], rax
1:  pop r12
    pop rbx
    ret

# doc_len(doc) -> bytes
FN doc_len
    mov rax, [rdi + DOC_cap]
    sub rax, [rdi + DOC_ge]
    add rax, [rdi + DOC_gs]
    ret

# doc_byte(doc, pos) -> eax byte (0 past end)
FN doc_byte
    cmp rsi, [rdi + DOC_gs]
    jb 1f
    add rsi, [rdi + DOC_ge]
    sub rsi, [rdi + DOC_gs]
    cmp rsi, [rdi + DOC_cap]
    jae 2f
1:  mov rax, [rdi + DOC_buf]
    movzx eax, byte ptr [rax + rsi]
    ret
2:  xor eax, eax
    ret

# doc_copy(doc, pos, len, dst)
FN doc_copy
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rax, [rbx + DOC_gs]
    cmp r12, rax
    jae 2f
    # part before the gap
    mov rcx, rax
    sub rcx, r12
    cmp rcx, r13
    cmova rcx, r13
    mov rdi, r14
    mov rsi, [rbx + DOC_buf]
    add rsi, r12
    add r14, rcx
    add r12, rcx
    sub r13, rcx
    rep movsb
2:  test r13, r13
    jz 3f
    mov rsi, r12
    add rsi, [rbx + DOC_ge]
    sub rsi, [rbx + DOC_gs]
    add rsi, [rbx + DOC_buf]
    mov rdi, r14
    mov rcx, r13
    rep movsb
3:  pop r14
    pop r13
    pop r12
    pop rbx
    ret

# doc_range(doc, pos, len) -> pointer to contiguous bytes (direct or scratch copy)
FN doc_range
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rax, [r12 + r13]
    cmp rax, [rbx + DOC_gs]
    ja 1f
    mov rax, [rbx + DOC_buf]
    add rax, r12
    jmp 9f
1:  cmp r12, [rbx + DOC_gs]
    jb 2f
    mov rax, r12
    add rax, [rbx + DOC_ge]
    sub rax, [rbx + DOC_gs]
    add rax, [rbx + DOC_buf]
    jmp 9f
2:  lea rdi, [rip + scratch]
    mov qword ptr [rdi + SB_len], 0
    mov rsi, r13
    call sb_reserve
    mov rcx, rax
    push rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call doc_copy
    pop rax
9:  pop r13
    pop r12
    pop rbx
    ret

# doc_contiguous(doc) -> pointer to the whole text (moves the gap to the end)
FN doc_contiguous
    push rbx
    mov rbx, rdi
    call doc_len
    mov rdi, rbx
    mov rsi, rax
    call gb_move_gap
    mov rax, [rbx + DOC_buf]
    pop rbx
    ret

# doc_line_of(doc, pos) -> line
FN doc_line_of
    mov r8, [rdi + DOC_lines]
    xor eax, eax                # lo
    mov rcx, [rdi + DOC_nlines] # hi (exclusive)
1:  mov rdx, rcx
    sub rdx, rax
    cmp rdx, 1
    jbe 3f
    lea rdx, [rax + rcx]
    shr rdx, 1
    cmp [r8 + rdx*8], rsi
    ja 2f
    mov rax, rdx
    jmp 1b
2:  mov rcx, rdx
    jmp 1b
3:  ret

# doc_line_start(doc, line) -> pos
FN doc_line_start
    mov rax, [rdi + DOC_lines]
    mov rax, [rax + rsi*8]
    ret

# doc_line_end(doc, line) -> pos of the '\n' (or doc end)
FN doc_line_end
    lea rax, [rsi + 1]
    cmp rax, [rdi + DOC_nlines]
    jae 1f
    mov rcx, [rdi + DOC_lines]
    mov rax, [rcx + rax*8]
    dec rax
    ret
1:  jmp doc_len

# doc_line_text(doc, line) -> rax ptr, rdx len
FN doc_line_text
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call doc_line_start
    mov r13, rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    mov rdx, rax
    sub rdx, r13
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r13
    call doc_range
    mov rdx, r12
    pop r13
    pop r12
    pop rbx
    ret

# gb_move_gap(doc, pos)
gb_move_gap:
    mov rax, [rdi + DOC_gs]
    cmp rsi, rax
    je 9f
    jb 1f
    # pos > gs: move [ge, ge + (pos-gs)) down to gs
    mov rdx, rsi
    sub rdx, rax                # count
    mov r8, [rdi + DOC_buf]
    push rdi
    push rsi
    lea rdi, [r8 + rax]
    mov rsi, [rsp + 8]
    mov rsi, [rsi + DOC_ge]
    add rsi, r8
    push rdx
    call memmove
    pop rdx
    pop rsi
    pop rdi
    add [rdi + DOC_ge], rdx
    mov [rdi + DOC_gs], rsi
    ret
1:  # pos < gs: move [pos, gs) up to end at ge
    mov rdx, rax
    sub rdx, rsi                # count
    mov r8, [rdi + DOC_buf]
    push rdi
    push rsi
    mov rcx, [rdi + DOC_ge]
    sub rcx, rdx
    lea rdi, [r8 + rcx]
    lea rsi, [r8 + rsi]
    push rdx
    call memmove
    pop rdx
    pop rsi
    pop rdi
    sub [rdi + DOC_ge], rdx
    mov [rdi + DOC_gs], rsi
9:  ret

# gb_reserve(doc, need): ensure gap >= need
gb_reserve:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov rax, [rbx + DOC_ge]
    sub rax, [rbx + DOC_gs]
    cmp rax, rsi
    jae 9f
    mov r12, [rbx + DOC_cap]
    lea r13, [r12 + rsi + GAP_MIN]
    lea rax, [r12 + r12]
    cmp r13, rax
    cmovb r13, rax
    mov rdi, [rbx + DOC_buf]
    mov rsi, r13
    call mem_realloc
    mov [rbx + DOC_buf], rax
    # move tail [ge, cap) to the new end
    mov rdx, r12
    sub rdx, [rbx + DOC_ge]     # tail length
    mov rcx, r13
    sub rcx, rdx
    lea rdi, [rax + rcx]
    mov rsi, [rbx + DOC_ge]
    add rsi, rax
    mov [rbx + DOC_ge], rcx
    mov [rbx + DOC_cap], r13
    call memmove
9:  pop r13
    pop r12
    pop rbx
    ret

# raw_insert(doc, pos, ptr, len)
FN raw_insert
    PROLOGUE 16
    mov qword ptr [rsp], 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    test r14, r14
    jz .Lri_ret
    mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov r15, rax                # L
    mov rdi, rbx
    mov rsi, r14
    call gb_reserve
    mov rdi, rbx
    mov rsi, r12
    call gb_move_gap
    mov rdi, [rbx + DOC_buf]
    add rdi, [rbx + DOC_gs]
    mov rsi, r13
    mov rcx, r14
    rep movsb
    add [rbx + DOC_gs], r14
    # shift following line starts
    mov r8, [rbx + DOC_lines]
    lea rcx, [r15 + 1]
1:  cmp rcx, [rbx + DOC_nlines]
    jae 2f
    add [r8 + rcx*8], r14
    inc rcx
    jmp 1b
2:  # count newlines
    xor ecx, ecx
    xor edx, edx
3:  cmp rcx, r14
    jae 4f
    cmp byte ptr [r13 + rcx], 10
    jne 31f
    inc rdx
31: inc rcx
    jmp 3b
4:  test rdx, rdx
    jz .Lri_lines_done
    mov [rsp], rdx              # n
    mov rsi, [rbx + DOC_nlines]
    add rsi, rdx
    mov rdi, rbx
    call lines_reserve
    # open a hole of n entries after L
    mov rdx, [rbx + DOC_nlines]
    sub rdx, r15
    dec rdx                     # entries after L
    mov rcx, [rsp]
    mov rax, [rbx + DOC_lines]
    lea rsi, [rax + r15*8 + 8]
    lea rdi, [rsi + rcx*8]
    shl rdx, 3
    push rdx
    call memmove
    pop rdx
    shr rdx, 1                  # same count, 4-byte entries
    push rdx
    mov rcx, [rsp + 8]
    mov rax, [rbx + DOC_states]
    lea rsi, [rax + r15*4 + 4]
    lea rdi, [rsi + rcx*4]
    call memmove
    pop rdx
    shl rdx, 1                  # 8-byte hashes
    mov rcx, [rsp]
    mov rax, [rbx + DOC_lhash]
    lea rsi, [rax + r15*8 + 8]
    lea rdi, [rsi + rcx*8]
    call memmove
    # fill new starts
    mov r8, [rbx + DOC_lines]
    mov r9, [rbx + DOC_states]
    lea r10, [r15 + 1]
    xor ecx, ecx
5:  cmp rcx, r14
    jae 6f
    cmp byte ptr [r13 + rcx], 10
    jne 51f
    lea rax, [r12 + rcx + 1]
    mov [r8 + r10*8], rax
    mov dword ptr [r9 + r10*4], 0
    inc r10
51: inc rcx
    jmp 5b
6:  mov rax, [rsp]
    add [rbx + DOC_nlines], rax
.Lri_lines_done:
    # the edited line and the new ones need hashing again
    mov rax, [rbx + DOC_lhash]
    lea rdi, [rax + r15*8]
    mov rcx, [rsp]
    inc rcx
    xor eax, eax
    rep stosq
    mov rdi, rbx
    mov rsi, r15
    mov rdx, [rsp]
    call states_after_insert
7:  # markers
    cmp [rbx + DOC_cur], r12
    jbe 8f
    add [rbx + DOC_cur], r14
8:  cmp [rbx + DOC_anchor], r12
    jbe 81f
    add [rbx + DOC_anchor], r14
81: inc qword ptr [rbx + DOC_version]
.Lri_ret:
    EPILOGUE

# raw_delete(doc, pos, len)
FN raw_delete
    PROLOGUE 16
    mov qword ptr [rsp], 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz .Lrd_ret
    mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov r15, rax                # L
    mov rdi, rbx
    mov rsi, r12
    call gb_move_gap
    add [rbx + DOC_ge], r13
    lea r14, [r12 + r13]        # end
    # m = lines after L starting within (pos, end]
    mov r8, [rbx + DOC_lines]
    lea rcx, [r15 + 1]
1:  cmp rcx, [rbx + DOC_nlines]
    jae 2f
    cmp [r8 + rcx*8], r14
    ja 2f
    inc rcx
    jmp 1b
2:  mov rax, rcx
    sub rax, r15
    dec rax                     # m
    mov [rsp], rax
    test rax, rax
    jz 3f
    push rax
    # lines[L+1..] <- lines[L+1+m..]
    mov rdx, [rbx + DOC_nlines]
    sub rdx, rcx                # remaining after removed
    push rdx
    lea rdi, [r8 + r15*8 + 8]
    lea rsi, [r8 + rcx*8]
    shl rdx, 3
    call memmove
    pop rdx
    mov rax, [rsp]
    mov r9, [rbx + DOC_states]
    lea rdi, [r9 + r15*4 + 4]
    lea rcx, [r15 + 1]
    add rcx, rax
    lea rsi, [r9 + rcx*4]
    shl rdx, 2
    call memmove
    mov rax, [rsp]
    mov rdx, [rbx + DOC_nlines]
    lea rcx, [r15 + rax + 1]
    sub rdx, rcx
    mov r9, [rbx + DOC_lhash]
    lea rdi, [r9 + r15*8 + 8]
    lea rsi, [r9 + rcx*8]
    shl rdx, 3
    call memmove
    pop rax
    sub [rbx + DOC_nlines], rax
3:  mov r8, [rbx + DOC_lines]
    lea rcx, [r15 + 1]
4:  cmp rcx, [rbx + DOC_nlines]
    jae 5f
    sub [r8 + rcx*8], r13
    inc rcx
    jmp 4b
5:  mov rax, [rbx + DOC_lhash]
    mov qword ptr [rax + r15*8], 0
    mov rdi, rbx
    mov rsi, r15
    mov rdx, [rsp]
    call states_after_delete
6:  # markers
    lea rdi, [rbx + DOC_cur]
    call .Lrd_marker
    lea rdi, [rbx + DOC_anchor]
    call .Lrd_marker
    inc qword ptr [rbx + DOC_version]
.Lrd_ret:
    EPILOGUE
.Lrd_marker:
    mov rax, [rdi]
    cmp rax, r14
    jb 1f
    sub rax, r13
    mov [rdi], rax
    ret
1:  cmp rax, r12
    jbe 2f
    mov [rdi], r12
2:  ret

# syntax state bookkeeping after an edit at line L (n lines added / m removed)
# states_after_insert(doc, L, n)
states_after_insert:
    call states_begin
    lea rax, [rsi + 1]
    cmp [rdi + DOC_sold], rax
    jbe 1f
    add [rdi + DOC_sold], rdx
1:  mov rax, [rdi + DOC_ehi]
    cmp rax, rsi
    jle 2f
    add rax, rdx
2:  lea rcx, [rsi + rdx]
    cmp rax, rcx
    cmovl rax, rcx
    mov [rdi + DOC_ehi], rax
    jmp states_end

# states_after_delete(doc, L, m)
states_after_delete:
    call states_begin
    lea rax, [rsi + 1]
    cmp [rdi + DOC_sold], rax
    jbe 1f
    mov rcx, [rdi + DOC_sold]
    sub rcx, rdx
    cmp rcx, rax
    cmovl rcx, rax
    mov [rdi + DOC_sold], rcx
1:  mov rax, [rdi + DOC_ehi]
    cmp rax, rsi
    jle 2f
    sub rax, rdx
    cmp rax, rsi
    cmovl rax, rsi
2:  cmp rax, rsi
    cmovl rax, rsi
    mov [rdi + DOC_ehi], rax
    jmp states_end

# The stored states past svalid must form one chain computed for unchanged text.
# No old region, or an edit before svalid (which would leave two chains):
# the current states become the old region and the edit range restarts.
states_begin:
    mov rax, [rdi + DOC_svalid]
    cmp rax, [rdi + DOC_sold]
    jae 1f
    lea rcx, [rsi + 1]
    cmp rcx, rax
    jae 2f
1:  mov qword ptr [rdi + DOC_ehi], -1
    mov [rdi + DOC_sold], rax
2:  ret

states_end:
    lea rax, [rsi + 1]
    cmp rax, [rdi + DOC_svalid]
    jae 1f
    mov [rdi + DOC_svalid], rax
1:  ret

# new_record(doc, kind, pos, len, text, editkind) -> UR*  (handles grouping and redo reset)
new_record:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rsi              # kind
    mov [rsp + 8], rdx          # pos
    mov [rsp + 16], rcx         # len
    mov r12, r8                 # text (owned)
    mov r13d, r9d               # edit kind
    # drop redo
    mov rdi, rbx
    lea rsi, [rbx + DOC_redo]
    call urec_clear
    # saved state unreachable?
    mov rax, [rbx + DOC_undo + VEC_len]
    cmp [rbx + DOC_savepoint], rax
    jle 1f
    mov qword ptr [rbx + DOC_savepoint], -1
1:  call time_ms
    mov r14, rax
    test dword ptr [rbx + DOC_flags], 1
    jnz .Lnr_same                   # explicit group open
    test r13d, r13d
    jz .Lnr_new
    cmp r13, [rbx + DOC_lastkind]
    jne .Lnr_new
    mov rax, r14
    sub rax, [rbx + DOC_lastedit]
    cmp rax, 1500
    ja .Lnr_new
    mov rax, [rbx + DOC_undo + VEC_len]
    test rax, rax
    jz .Lnr_new
    dec rax
    imul rax, rax, UR_SIZE
    add rax, [rbx + DOC_undo + VEC_ptr]
    mov rcx, [rsp + 8]
    cmp r13d, EK_TYPE
    jne 2f
    # contiguous typing, break after whitespace/newline
    mov rdx, [rax + UR_pos]
    add rdx, [rax + UR_len]
    cmp rcx, rdx
    jne .Lnr_new
    cmp byte ptr [r12], 10
    je .Lnr_new
    mov rdx, [rax + UR_text]
    mov rsi, [rax + UR_len]
    cmp byte ptr [rdx + rsi - 1], ' '
    jne .Lnr_same
    cmp byte ptr [r12], ' '
    je .Lnr_same
    jmp .Lnr_new
2:  cmp r13d, EK_BACK
    jne 3f
    add rcx, [rsp + 16]
    cmp rcx, [rax + UR_pos]
    je .Lnr_same
    jmp .Lnr_new
3:  cmp rcx, [rax + UR_pos]
    je .Lnr_same
.Lnr_new:
    inc qword ptr [rbx + DOC_group]
.Lnr_same:
    mov [rbx + DOC_lastkind], r13
    mov [rbx + DOC_lastedit], r14
    lea rdi, [rbx + DOC_undo]
    mov esi, UR_SIZE
    call vec_push
    mov rcx, [rsp]
    mov [rax + UR_kind], rcx
    mov rcx, [rsp + 8]
    mov [rax + UR_pos], rcx
    mov rcx, [rsp + 16]
    mov [rax + UR_len], rcx
    mov [rax + UR_text], r12
    mov rcx, [rbx + DOC_group]
    mov [rax + UR_group], rcx
    mov rcx, [rbx + DOC_cur]
    mov [rax + UR_cur], rcx
    mov rcx, [rbx + DOC_anchor]
    mov [rax + UR_anchor], rcx
    EPILOGUE

# doc_insert(doc, pos, ptr, len, editkind)
FN doc_insert
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15d, r8d
    test r14, r14
    jz 9f
    mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov r8, rax
    mov rdi, rbx
    mov esi, 1
    mov rdx, r12
    mov rcx, r14
    mov r9d, r15d
    call new_record
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call raw_insert
9:  EPILOGUE

# doc_delete(doc, pos, len, editkind)
FN doc_delete
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r15d, ecx
    test r13, r13
    jz 9f
    lea rdi, [r13 + 1]
    call mem_alloc
    mov r14, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call doc_copy
    mov rdi, rbx
    mov esi, 2
    mov rdx, r12
    mov rcx, r13
    mov r8, r14
    mov r9d, r15d
    call new_record
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call raw_delete
9:  EPILOGUE

# doc_begin_group(doc) / doc_end_group(doc): edits in between undo as one step
FN doc_begin_group
    inc qword ptr [rdi + DOC_group]
    or dword ptr [rdi + DOC_flags], 1
    ret
FN doc_end_group
    and dword ptr [rdi + DOC_flags], -2
    mov qword ptr [rdi + DOC_lastkind], EK_OTHER
    ret

# doc_undo(doc) -> 1 if something was undone
FN doc_undo
    PROLOGUE 16
    mov rbx, rdi
    mov rax, [rbx + DOC_undo + VEC_len]
    test rax, rax
    jz .Lu_none
    dec rax
    imul rax, rax, UR_SIZE
    add rax, [rbx + DOC_undo + VEC_ptr]
    mov r12, [rax + UR_group]
.Lu_loop:
    mov rax, [rbx + DOC_undo + VEC_len]
    test rax, rax
    jz .Lu_done
    dec rax
    imul r13, rax, UR_SIZE
    add r13, [rbx + DOC_undo + VEC_ptr]
    cmp [r13 + UR_group], r12
    jne .Lu_done
    dec qword ptr [rbx + DOC_undo + VEC_len]
    mov rax, [r13 + UR_cur]
    mov [rsp], rax
    mov rax, [r13 + UR_anchor]
    mov [rsp + 8], rax
    cmp qword ptr [r13 + UR_kind], 1
    jne 1f
    mov rdi, rbx
    mov rsi, [r13 + UR_pos]
    mov rdx, [r13 + UR_len]
    call raw_delete
    jmp 2f
1:  mov rdi, rbx
    mov rsi, [r13 + UR_pos]
    mov rdx, [r13 + UR_text]
    mov rcx, [r13 + UR_len]
    call raw_insert
2:  # move record to redo
    lea rdi, [rbx + DOC_redo]
    mov esi, UR_SIZE
    call vec_push
    mov rdi, rax
    mov rsi, r13
    mov ecx, UR_SIZE
    rep movsb
    jmp .Lu_loop
.Lu_done:
    mov rax, [rsp]
    mov [rbx + DOC_cur], rax
    mov rax, [rsp + 8]
    mov [rbx + DOC_anchor], rax
    mov qword ptr [rbx + DOC_lastkind], EK_OTHER
    mov qword ptr [rbx + DOC_prefx], -1
    mov rdi, rbx
    call watch_doc_clean
    mov eax, 1
    EPILOGUE
.Lu_none:
    xor eax, eax
    EPILOGUE

# doc_redo(doc) -> 1 if something was redone
FN doc_redo
    PROLOGUE 16
    mov rbx, rdi
    mov rax, [rbx + DOC_redo + VEC_len]
    test rax, rax
    jz .Lr_none
    dec rax
    imul rax, rax, UR_SIZE
    add rax, [rbx + DOC_redo + VEC_ptr]
    mov r12, [rax + UR_group]
.Lr_loop:
    mov rax, [rbx + DOC_redo + VEC_len]
    test rax, rax
    jz .Lr_done
    dec rax
    imul r13, rax, UR_SIZE
    add r13, [rbx + DOC_redo + VEC_ptr]
    cmp [r13 + UR_group], r12
    jne .Lr_done
    dec qword ptr [rbx + DOC_redo + VEC_len]
    cmp qword ptr [r13 + UR_kind], 1
    jne 1f
    mov rdi, rbx
    mov rsi, [r13 + UR_pos]
    mov rdx, [r13 + UR_text]
    mov rcx, [r13 + UR_len]
    call raw_insert
    mov rax, [r13 + UR_pos]
    add rax, [r13 + UR_len]
    jmp 2f
1:  mov rdi, rbx
    mov rsi, [r13 + UR_pos]
    mov rdx, [r13 + UR_len]
    call raw_delete
    mov rax, [r13 + UR_pos]
2:  mov [rsp], rax
    lea rdi, [rbx + DOC_undo]
    mov esi, UR_SIZE
    call vec_push
    mov rdi, rax
    mov rsi, r13
    mov ecx, UR_SIZE
    rep movsb
    jmp .Lr_loop
.Lr_done:
    mov rax, [rsp]
    mov [rbx + DOC_cur], rax
    mov [rbx + DOC_anchor], rax
    mov qword ptr [rbx + DOC_lastkind], EK_OTHER
    mov qword ptr [rbx + DOC_prefx], -1
    mov rdi, rbx
    call watch_doc_clean
    mov eax, 1
    EPILOGUE
.Lr_none:
    xor eax, eax
    EPILOGUE

# doc_dirty(doc) -> 1 if modified since load/save
FN doc_dirty
    mov rax, [rdi + DOC_undo + VEC_len]
    cmp rax, [rdi + DOC_savepoint]
    setne al
    movzx eax, al
    ret

# doc_set_path(doc, path cstr)
FN doc_set_path
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + DOC_path]
    call mem_free
    mov rdi, rsi
    push rsi
    call strlen
    pop rdi
    mov rsi, rax
    push rax
    call mem_dup
    mov [rbx + DOC_path], rax
    pop rsi
    mov rdi, rax
    call path_basename
    mov [rbx + DOC_name], rax
    mov qword ptr [rbx + DOC_reload_at], 0
    mov qword ptr [rbx + DOC_disk_seen], 0
    mov qword ptr [rbx + DOC_disk_until], 0
.ifdef VINIX
    mov qword ptr [rbx + DOC_empty_since], 0
.endif
    and dword ptr [rbx + DOC_flags], ~DF_DISK_CHANGED
    # Every path assignment participates: explorer, pickers, restored tabs, images and rename.
    mov rdi, rbx
    call watch_doc
    pop rbx
    ret

# doc_note_eol(doc): DF_EOL as the text ends now (read from or written to the file)
FN doc_note_eol
    and dword ptr [rdi + DOC_flags], ~DF_EOL
    push rbx
    mov rbx, rdi
    call doc_len
    test rax, rax
    jz 1f
    lea rsi, [rax - 1]
    mov rdi, rbx
    call doc_byte
    cmp eax, 10
    jne 1f
    or dword ptr [rbx + DOC_flags], DF_EOL
1:  pop rbx
    ret

# doc_normalize_eol(doc, text, len) -> normalized length; only CRs followed by LF are removed
FN doc_normalize_eol
    mov dword ptr [rdi + DOC_crlf], 0
    mov r9, rdx
    # the text up to the first CR stays as it is: found 16 bytes at a time, and with no CR at all
    # nothing is written
    mov eax, 0x0d0d0d0d
    movd xmm1, eax
    pshufd xmm1, xmm1, 0
    xor ecx, ecx
1:  lea r8, [rcx + 16]
    cmp r8, r9
    ja 2f
    movdqu xmm0, [rsi + rcx]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    test eax, eax
    jnz 21f
    mov rcx, r8
    jmp 1b
21: bsf eax, eax
    add rcx, rax
    jmp 22f
2:  cmp rcx, r9
    jae 5f
    cmp byte ptr [rsi + rcx], 13
    je 22f
    inc rcx
    jmp 2b
22: mov rdx, rcx                # write index
3:  cmp rcx, r9
    jae 5f
    movzx eax, byte ptr [rsi + rcx]
    cmp al, 13
    jne 4f
    lea r8, [rcx + 1]
    cmp r8, r9
    jae 4f
    cmp byte ptr [rsi + r8], 10
    jne 4f
    mov dword ptr [rdi + DOC_crlf], 1
    inc rcx
    jmp 3b
4:  mov [rsi + rdx], al
    inc rcx
    inc rdx
    jmp 3b
5:  mov rax, rdx
    ret

# doc_is_binary(text, len) -> 1 if the first 8 KiB contains a NUL
FN doc_is_binary
    mov rcx, rsi
    cmp rcx, 8192
    jbe 1f
    mov ecx, 8192
1:  xor eax, eax
    test rcx, rcx
    jz 2f
    repne scasb
    sete al
2:  ret

# doc_load(doc, path) -> 0 ok, -2 missing (doc keeps path), -1000 binary, other -errno
FN doc_load
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov rsi, r12
    call doc_set_path
    mov rdi, r12
    call file_stamp
    mov [rbx + DOC_mtime], rax
    mov rdi, r12
    mov esi, GAP_MIN * 4
    call file_read_all_extra
    test rax, rax
    jz .Ldl_error
    mov r13, rax
    mov r14, rdx
    mov rdi, r13
    mov rsi, r14
    call doc_is_binary
    test eax, eax
    jnz .Ldl_binary
.ifdef VINIX
    mov rdi, r13
    mov rsi, r14
    call hash_line
    mov [rbx + DOC_disk_hash], rax
.endif
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call doc_normalize_eol
    mov r14, rax
    # install as buffer with the gap at the end
    mov rdi, [rbx + DOC_buf]
    call mem_free
    lea r15, [r14 + GAP_MIN * 4]
    mov rdi, r13
    mov rsi, r15
    call mem_realloc
    mov [rbx + DOC_buf], rax
    mov [rbx + DOC_cap], r15
    mov [rbx + DOC_gs], r14
    mov [rbx + DOC_ge], r15
    # line index: newlines counted 16 bytes at a time (a mask's bits added up), then the rest
    mov ecx, 0x0a0a0a0a
    movd xmm1, ecx
    pshufd xmm1, xmm1, 0
    xor ecx, ecx
    mov edx, 1
6:  lea r8, [rcx + 16]
    cmp r8, r14
    ja 62f
    movdqu xmm0, [rax + rcx]
    pcmpeqb xmm0, xmm1
    pmovmskb r9d, xmm0
    mov rcx, r8
    test r9d, r9d
    jz 6b
    mov r10d, r9d
    shr r10d, 1
    and r10d, 0x5555
    sub r9d, r10d
    mov r10d, r9d
    shr r10d, 2
    and r9d, 0x3333
    and r10d, 0x3333
    add r9d, r10d
    mov r10d, r9d
    shr r10d, 4
    add r9d, r10d
    and r9d, 0x0f0f
    mov r10d, r9d
    shr r10d, 8
    add r9d, r10d
    and r9d, 0x1f
    add rdx, r9
    jmp 6b
62: cmp rcx, r14
    jae 7f
    cmp byte ptr [rax + rcx], 10
    jne 61f
    inc rdx
61: inc rcx
    jmp 62b
7:  mov [rsp], rdx
    mov rdi, rbx
    mov rsi, rdx
    call lines_reserve
    mov r8, [rbx + DOC_lines]
    mov r9, [rbx + DOC_buf]
    mov qword ptr [r8], 0
    mov edx, 1
    xor ecx, ecx
8:  lea r10, [rcx + 16]         # each newline of a block in turn, the lowest bit of its mask
    cmp r10, r14
    ja 82f
    movdqu xmm0, [r9 + rcx]
    pcmpeqb xmm0, xmm1
    pmovmskb r11d, xmm0
83: test r11d, r11d
    jz 84f
    bsf eax, r11d
    lea rax, [rcx + rax + 1]
    mov [r8 + rdx*8], rax
    inc rdx
    lea eax, [r11 - 1]
    and r11d, eax
    jmp 83b
84: add rcx, 16
    jmp 8b
82: cmp rcx, r14
    jae 9f
    cmp byte ptr [r9 + rcx], 10
    jne 81f
    lea rax, [rcx + 1]
    mov [r8 + rdx*8], rax
    inc rdx
81: inc rcx
    jmp 82b
9:  mov [rbx + DOC_nlines], rdx
    mov rdi, [rbx + DOC_lhash]
    mov rcx, rdx
    xor eax, eax
    rep stosq
    mov qword ptr [rbx + DOC_svalid], 0
    mov qword ptr [rbx + DOC_savepoint], 0
    mov rdi, rbx
    call doc_note_eol
    xor eax, eax
    EPILOGUE
.Ldl_error:
    mov rax, rdx
    EPILOGUE
.Ldl_binary:
    mov rdi, r13
    call mem_free
    mov rax, -1000
    EPILOGUE

# doc_save(doc) -> 0 or -errno
FN doc_save
    PROLOGUE 32
    mov rbx, rdi
    cmp qword ptr [rbx + DOC_path], 0
    je .Lds_nopath
    mov rdi, rbx
    call doc_begin_group
    cmp dword ptr [rip + cfg_trim_trailing], 0
    je .Lds_final
    # trim trailing blanks on every line (last to first)
    mov r12, [rbx + DOC_nlines]
.Lds_trim:
    test r12, r12
    jz .Lds_final
    dec r12
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    mov r13, rax                # end
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov r14, rax
    mov r15, r13
1:  cmp r15, r14
    jbe 2f
    lea rsi, [r15 - 1]
    mov rdi, rbx
    call doc_byte
    cmp al, ' '
    je 11f
    cmp al, 9
    jne 2f
11: dec r15
    jmp 1b
2:  cmp r15, r13
    je .Lds_trim
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r13
    sub rdx, r15
    xor ecx, ecx
    call doc_delete
    jmp .Lds_trim
.Lds_final:
    cmp dword ptr [rip + cfg_final_newline], 0
    je .Lds_write
    mov rdi, rbx
    call doc_len
    test rax, rax
    jz .Lds_write
    mov r12, rax
    mov rdi, rbx
    lea rsi, [rax - 1]
    call doc_byte
    cmp al, 10
    je .Lds_write
    mov rax, [rbx + DOC_cur]
    mov [rsp], rax
    mov rax, [rbx + DOC_anchor]
    mov [rsp + 8], rax
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    xor r8d, r8d
    call doc_insert
    mov rax, [rsp]
    mov [rbx + DOC_cur], rax
    mov rax, [rsp + 8]
    mov [rbx + DOC_anchor], rax
.Lds_write:
    mov rdi, rbx
    call doc_end_group
    # contiguous copy, CRLF if the file had it
    lea rdi, [rsp]
    xor esi, esi
    mov edx, SB_SIZE
    call memset
    mov rdi, rbx
    call doc_len
    mov r12, rax
    lea rdi, [rsp]
    mov rsi, rax
    cmp dword ptr [rbx + DOC_crlf], 0
    je 1f
    add rsi, rax
1:
    call sb_reserve
    mov r13, rax
    mov rdi, rbx
    xor esi, esi
    mov rdx, r12
    mov rcx, r13
    call doc_copy
    mov [rsp + SB_len], r12
    cmp dword ptr [rbx + DOC_crlf], 0
    je 5f
    # expand \n to \r\n from the back
    xor ecx, ecx
    xor edx, edx
3:  cmp rcx, r12
    jae 4f
    cmp byte ptr [r13 + rcx], 10
    jne 31f
    inc rdx
31: inc rcx
    jmp 3b
4:  lea r8, [r12 + rdx]         # new length
    mov [rsp + SB_len], r8
    mov rcx, r12
6:  test rcx, rcx
    jz 5f
    dec rcx
    dec r8
    movzx eax, byte ptr [r13 + rcx]
    mov [r13 + r8], al
    cmp al, 10
    jne 6b
    dec r8
    mov byte ptr [r13 + r8], 13
    jmp 6b
5:  mov rdi, [rbx + DOC_path]
    mov rsi, [rsp + SB_ptr]
    mov rdx, [rsp + SB_len]
    call file_write_all
    mov r12, rax
.ifdef VINIX
    test r12, r12
    js 51f
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call hash_line
    mov [rbx + DOC_disk_hash], rax
51:
.endif
    lea rdi, [rsp]
    call sb_free
    test r12, r12
    js 7f
    mov rax, [rbx + DOC_undo + VEC_len]
    mov [rbx + DOC_savepoint], rax
    mov rdi, [rbx + DOC_path]
    call file_stamp
    mov [rbx + DOC_mtime], rax
    mov rdi, rbx
    call doc_note_eol
    and dword ptr [rbx + DOC_flags], ~DF_DISK_CHANGED
    mov qword ptr [rbx + DOC_disk_seen], 0
    # Save As can create a directory that did not exist when the path was assigned.
    mov rdi, rbx
    call watch_doc
7:  mov rax, r12
    EPILOGUE
.Lds_nopath:
    mov rax, -2
    EPILOGUE

# doc_set_text(doc, ptr, len): replace everything (one undo step)
FN doc_set_text
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call doc_begin_group
    mov rdi, rbx
    call doc_len
    mov rdx, rax
    mov rdi, rbx
    xor esi, esi
    xor ecx, ecx
    call doc_delete
    mov rdi, rbx
    xor esi, esi
    mov rdx, r12
    mov rcx, r13
    xor r8d, r8d
    call doc_insert
    mov rdi, rbx
    call doc_end_group
    pop r13
    pop r12
    pop rbx
    ret

# doc_replace_all(doc, ptr, len): new contents with no undo history, not modified
FN doc_replace_all
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov eax, [rbx + DOC_flags]
    push rax
    push rax
    and dword ptr [rbx + DOC_flags], ~DF_READONLY
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call doc_set_text
    pop rax
    pop rax
    mov [rbx + DOC_flags], eax
    mov rdi, rbx
    lea rsi, [rbx + DOC_undo]
    call urec_clear
    mov rdi, rbx
    lea rsi, [rbx + DOC_redo]
    call urec_clear
    mov qword ptr [rbx + DOC_savepoint], 0
    pop r13
    pop r12
    pop rbx
    ret

# ---- motion helpers ----

# doc_next_char(doc, pos) -> pos after one utf-8 character
FN doc_next_char
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    call doc_len
    cmp r12, rax
    jae 9f
    push rax
    mov rdi, rbx
    mov rsi, r12
    call doc_byte
    pop rcx
    mov edx, 1
    cmp eax, 0xc0
    jb 1f
    mov edx, 2
    cmp eax, 0xe0
    jb 1f
    mov edx, 3
    cmp eax, 0xf0
    jb 1f
    mov edx, 4
1:  lea rax, [r12 + rdx]
    cmp rax, rcx
    cmova rax, rcx
    pop r12
    pop rbx
    ret
9:  mov rax, r12
    pop r12
    pop rbx
    ret

# doc_prev_char(doc, pos) -> start of the previous character
FN doc_prev_char
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 9f
    lea r13, [r12 - 1]
1:  test r13, r13
    jz 8f
    mov rax, r12
    sub rax, r13
    cmp rax, 4
    jae 8f
    mov rdi, rbx
    mov rsi, r13
    call doc_byte
    and eax, 0xc0
    cmp eax, 0x80
    jne 8f
    dec r13
    jmp 1b
8:  mov r12, r13
9:  mov rax, r12
    pop r13
    pop r12
    pop rbx
    ret

# char_class(byte) -> 0 blank, 1 newline, 2 word, 3 punctuation
char_class:
    cmp dil, 10
    je 1f
    cmp dil, ' '
    je 2f
    cmp dil, 9
    je 2f
    call is_ident
    test eax, eax
    jz 3f
    mov eax, 2
    ret
1:  mov eax, 1
    ret
2:  xor eax, eax
    ret
3:  mov eax, 3
    ret

# doc_word_right(doc, pos) -> pos
FN doc_word_right
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call doc_len
    mov r13, rax
    cmp r12, r13
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_byte
    cmp al, 10
    jne 1f
    inc r12
    jmp 9f
1:  # skip blanks
    cmp r12, r13
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_byte
    mov edi, eax
    call char_class
    test eax, eax
    jnz 2f
    inc r12
    jmp 1b
2:  cmp eax, 1
    je 9f
    mov r14d, eax
3:  inc r12
    cmp r12, r13
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_byte
    mov edi, eax
    call char_class
    cmp eax, r14d
    je 3b
9:  mov rax, r12
    EPILOGUE

# doc_word_left(doc, pos) -> pos
FN doc_word_left
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 9f
    lea rsi, [r12 - 1]
    call doc_byte
    cmp al, 10
    jne 1f
    dec r12
    jmp 9f
1:  test r12, r12
    jz 9f
    mov rdi, rbx
    lea rsi, [r12 - 1]
    call doc_byte
    mov edi, eax
    call char_class
    test eax, eax
    jnz 2f
    dec r12
    jmp 1b
2:  cmp eax, 1
    je 9f
    mov r14d, eax
3:  dec r12
    jz 9f
    mov rdi, rbx
    lea rsi, [r12 - 1]
    call doc_byte
    mov edi, eax
    call char_class
    cmp eax, r14d
    je 3b
9:  mov rax, r12
    EPILOGUE

# cp_width(cp) -> 1 or 2 columns
FN cp_width
    mov eax, 1
    cmp edi, 0x1100
    jb 9f
    lea rsi, [rip + wide_ranges]
1:  mov ecx, [rsi]
    test ecx, ecx
    jz 9f
    cmp edi, ecx
    jb 2f
    cmp edi, [rsi + 4]
    ja 2f
    mov eax, 2
    ret
2:  add rsi, 8
    jmp 1b
9:  ret

# doc_col_of(doc, pos) -> visual column (tabs expanded)
FN doc_col_of
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    call doc_line_of
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov r13, rax                # p
    mov rdx, r12
    sub rdx, r13
    mov rdi, rbx
    mov rsi, r13
    call doc_range
    mov r14, rax                # bytes
    mov r15, r12
    sub r15, r13                # len
    xor ebx, ebx                # col
    xor r13d, r13d              # i
1:  cmp r13, r15
    jae 9f
    movzx eax, byte ptr [r14 + r13]
    cmp al, 9
    jne 2f
    mov eax, ebx
    xor edx, edx
    div dword ptr [rip + cfg_tab_width]
    mov eax, [rip + cfg_tab_width]
    sub eax, edx
    add ebx, eax
    inc r13
    jmp 1b
2:  lea rdi, [r14 + r13]
    mov rsi, r15
    sub rsi, r13
    call utf8_decode
    add r13, rdx
    mov edi, eax
    call cp_width
    add ebx, eax
    jmp 1b
9:  mov eax, ebx
    EPILOGUE

# doc_pos_at_char(doc, line, index) -> byte position at a zero-based source character, clamped to
# the line end. Tabs, combining marks and wide glyphs each count once, independent of display width.
FN doc_pos_at_char
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rdx
    mov r12, rsi
    call doc_line_start
    mov [rsp + 8], rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_text
    mov r14, rax
    mov r15, rdx
    xor r13d, r13d
1:  cmp qword ptr [rsp], 0
    je 9f
    cmp r13, r15
    jae 9f
    lea rdi, [r14 + r13]
    mov rsi, r15
    sub rsi, r13
    call utf8_decode
    add r13, rdx
    dec qword ptr [rsp]
    jmp 1b
9:  mov rax, [rsp + 8]
    add rax, r13
    EPILOGUE

# doc_pos_at_col(doc, line, col) -> pos nearest to visual column
FN doc_pos_at_col
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], edx              # target col
    mov r12, rsi
    call doc_line_start
    mov [rsp + 8], rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_text
    mov r14, rax
    mov r15, rdx
    xor r12d, r12d              # col
    xor r13d, r13d              # i
1:  cmp r13, r15
    jae 9f
    movzx eax, byte ptr [r14 + r13]
    cmp al, 9
    jne 2f
    mov eax, r12d
    xor edx, edx
    div dword ptr [rip + cfg_tab_width]
    mov eax, [rip + cfg_tab_width]
    sub eax, edx
    mov ecx, 1
    jmp 3f
2:  lea rdi, [r14 + r13]
    mov rsi, r15
    sub rsi, r13
    call utf8_decode
    mov ecx, edx
    push rcx
    mov edi, eax
    call cp_width
    pop rcx
3:  # stop if the target lies within this character (round to nearest edge)
    lea edx, [r12 + rax]
    cmp edx, [rsp]
    jle 4f
    mov edx, [rsp]
    sub edx, r12d
    add edx, edx
    cmp edx, eax
    jl 9f
    add r13, rcx
    jmp 9f
4:  add r12d, eax
    add r13, rcx
    jmp 1b
9:  mov rax, [rsp + 8]
    add rax, r13
    EPILOGUE

.section .rodata
.Luntitled: .asciz "untitled"
.Lnl: .ascii "\n"
.p2align 2
wide_ranges:
    .long 0x1100, 0x115f, 0x2e80, 0x303e, 0x3041, 0x33ff, 0x3400, 0x4dbf, 0x4e00, 0x9fff
    .long 0xa000, 0xa4cf, 0xac00, 0xd7a3, 0xf900, 0xfaff, 0xfe30, 0xfe4f, 0xff00, 0xff60
    .long 0xffe0, 0xffe6, 0x1f300, 0x1f64f, 0x1f900, 0x1f9ff, 0x20000, 0x3fffd, 0x1f680, 0x1f6ff
    .long 0x1fa70, 0x1faff, 0x231a, 0x231b, 0x26a1, 0x26a1, 0x2705, 0x2705, 0x2728, 0x2728
    .long 0x274c, 0x274c, 0x2b50, 0x2b50, 0, 0
