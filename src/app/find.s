# find / replace bar over the editor
.include "rhun.inc"

.equ ID_FIND_TF, 0x3a00
.equ ID_REPL_TF, 0x3a01
.equ ID_FIND_CASE, 0x3a02
.equ ID_FIND_PREV, 0x3a03
.equ ID_FIND_NEXT, 0x3a04
.equ ID_FIND_CLOSE, 0x3a05
.equ ID_REPL_ONE, 0x3a06
.equ ID_REPL_ALL, 0x3a07

.bss
.globl g_find_word
g_find_word: .long 0            # * and #: matches are whole words
.p2align 3
find_open: .long 0
repl_open: .long 0
find_sub: .long 0               # 0 find field, 1 replace field
find_case: .long 0
match_count: .long 0
match_index: .long 0
.p2align 3
tf_find: .zero TF_SIZE
tf_repl: .zero TF_SIZE
buf: .zero 64

.text

FN find_field
    lea rax, [rip + tf_find]
    cmp dword ptr [rip + find_sub], 0
    je 1f
    lea rax, [rip + tf_repl]
1:  ret

# open with the selection (single line) as the query
open_bar:
    PROLOGUE
    mov dword ptr [rip + g_find_word], 0
    mov dword ptr [rip + find_open], 1
    mov dword ptr [rip + find_sub], 0
    mov dword ptr [rip + tf_find + TF_id], ID_FIND_TF
    mov dword ptr [rip + tf_repl + TF_id], ID_REPL_TF
    mov dword ptr [rip + g_focus], FOCUS_FIND
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    je 8f
    mov r12, rax
    mov r13, rdx
    sub rdx, rax
    cmp rdx, 200
    ja 8f
    mov rdi, rbx
    mov rsi, r12
    call doc_range
    mov r14, rax
    mov rdi, rax
    mov rsi, r13
    sub rsi, r12
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    test rax, rax
    jns 8f
    lea rdi, [rip + tf_find]
    mov rsi, r14
    mov rdx, r13
    sub rdx, r12
    call tf_set
8:  lea rdi, [rip + tf_find]
    call tf_select_all
    call update_matches
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

FN cmd_find_bar
    mov dword ptr [rip + repl_open], 0
    jmp open_bar
FN cmd_replace_bar
    mov dword ptr [rip + repl_open], 1
    jmp open_bar

close_bar:
    mov dword ptr [rip + find_open], 0
    mov dword ptr [rip + g_focus], FOCUS_EDITOR
    lea rdi, [rip + g_ed_find]
    call sb_clear
    mov dword ptr [rip + g_dirty], 1
    ret

# update_matches(): highlight text, counts
update_matches:
    PROLOGUE 16
    lea rdi, [rip + g_ed_find]
    call sb_clear
    mov dword ptr [rip + match_count], 0
    mov dword ptr [rip + match_index], 0
    lea rdi, [rip + tf_find]
    call tf_text
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 9f
    lea rdi, [rip + g_ed_find]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov eax, [rip + find_case]
    mov [rip + g_ed_find_case], eax
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call doc_len
    mov r15, rax
    mov rdi, rbx
    call doc_contiguous
    mov r14, rax
    mov rdi, rbx
    call ed_sel
    mov [rsp], rax              # selection start
    xor ecx, ecx
1:  mov rdi, r14
    add rdi, rcx
    mov rsi, r15
    sub rsi, rcx
    jbe 9f
    push rcx
    push rcx
    mov rdx, r12
    mov rcx, r13
    call find_raw
    pop rcx
    pop rcx
    test rax, rax
    js 9f
    add rcx, rax
    inc dword ptr [rip + match_count]
    cmp rcx, [rsp]
    jg 2f
    mov eax, [rip + match_count]
    mov [rip + match_index], eax
2:  add rcx, r13
    jmp 1b
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# find_raw(hay, hlen, needle, nlen) -> index or -1: a match as the find bar (and vim) has them
.globl find_raw
find_raw:
    cmp dword ptr [rip + g_find_word], 0
    jne find_raw_word
find_raw_plain:
    cmp dword ptr [rip + find_case], 0
    je 1f
    jmp str_find
1:  jmp str_ifind

# find_raw_word(hay, hlen, needle, nlen): the first match with no letter, digit, _ or non-ASCII
# byte right before or after it in the document (* and #); keeps registers as str_find does
find_raw_word:
    push rdi
    push rsi
    push rdx
    push rcx
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    # the bounds of the text: the document's when hay lies in it
    mov [rsp], rdi
    lea rax, [rdi + rsi]
    mov [rsp + 8], rax
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    mov rcx, [rax + DOC_buf]
    mov rdx, rcx
    add rdx, [rax + DOC_gs]
    cmp r12, rcx
    jb 1f
    lea r8, [r12 + r13]
    cmp r8, rdx
    ja 1f
    mov [rsp], rcx
    mov [rsp + 8], rdx
1:  xor ebx, ebx
2:  lea rdi, [r12 + rbx]
    mov rsi, r13
    sub rsi, rbx
    jbe 8f
    mov rdx, r14
    mov rcx, r15
    call find_raw_plain
    test rax, rax
    js 8f
    lea rbx, [rax + rbx]        # the match
    lea r8, [r12 + rbx]
    cmp r8, [rsp]
    jbe 3f
    movzx edi, byte ptr [r8 - 1]
    call is_ident
    test eax, eax
    jnz 4f
3:  lea r8, [r12 + rbx]
    add r8, r15
    cmp r8, [rsp + 8]
    jae 5f
    movzx edi, byte ptr [r8]
    call is_ident
    test eax, eax
    jz 5f
4:  inc rbx
    jmp 2b
5:  mov rax, rbx
    jmp 9f
8:  mov rax, -1
9:  lea rsp, [rbp - 40]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

# goto_match(dir): select next (1) / previous (-1) match from the cursor
goto_match:
    PROLOGUE 32
    mov [rsp + 24], edi
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    lea rdi, [rip + tf_find]
    call tf_text
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 9f
    mov rdi, rbx
    call doc_len
    mov r15, rax
    mov rdi, rbx
    call doc_contiguous
    mov r14, rax
    mov rdi, rbx
    call ed_sel
    mov [rsp], rax
    mov [rsp + 8], rdx
    cmp dword ptr [rsp + 24], 0
    jl .Lgm_prev
    # forward from selection end
    mov rcx, [rsp + 8]
    mov rdi, r14
    add rdi, rcx
    mov rsi, r15
    sub rsi, rcx
    mov rdx, r12
    push rcx
    push rcx
    mov rcx, r13
    call find_raw
    pop rcx
    pop rcx
    test rax, rax
    js 1f
    add rax, rcx
    jmp .Lgm_sel
1:  # wrap
    mov rdi, r14
    mov rsi, r15
    mov rdx, r12
    mov rcx, r13
    call find_raw
    test rax, rax
    js 9f
    jmp .Lgm_sel
.Lgm_prev:
    # last match before the selection start, else the last match in the document
    mov qword ptr [rsp + 16], -1    # before
    mov r8, -1                      # last
    xor ecx, ecx
2:  mov rdi, r14
    add rdi, rcx
    mov rsi, r15
    sub rsi, rcx
    jbe 4f
    mov rdx, r12
    push rcx
    push r8
    mov rcx, r13
    call find_raw
    pop r8
    pop rcx
    test rax, rax
    js 4f
    add rcx, rax
    mov r8, rcx
    cmp rcx, [rsp]
    jae 3f
    mov [rsp + 16], rcx
3:  inc rcx
    jmp 2b
4:  mov rax, [rsp + 16]
    test rax, rax
    jns .Lgm_sel
    mov rax, r8
    test rax, rax
    js 9f
.Lgm_sel:
    mov [rbx + DOC_anchor], rax
    add rax, r13
    mov [rbx + DOC_cur], rax
    call ed_touch
    call update_matches
9:  EPILOGUE

FN cmd_find_next
    cmp qword ptr [rip + tf_find + TF_sb + SB_len], 0
    je open_bar
    mov edi, 1
    jmp goto_match
FN cmd_find_prev
    cmp qword ptr [rip + tf_find + TF_sb + SB_len], 0
    je open_bar
    mov edi, -1
    jmp goto_match

# replace_one(): replace the selection if it is a match, then go to the next one
replace_one:
    READONLY_RET
    PROLOGUE
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    lea rdi, [rip + tf_find]
    call tf_text
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 9f
    mov rdi, rbx
    call ed_sel
    mov r14, rax
    sub rdx, rax
    cmp rdx, r13
    jne 1f
    mov rdi, rbx
    mov rsi, r14
    call doc_range
    mov rdi, rax
    mov rsi, r13
    mov rdx, r12
    mov rcx, r13
    cmp dword ptr [rip + find_case], 0
    je 2f
    call str_eq
    jmp 3f
2:  call str_ieq
3:  test eax, eax
    jz 1f
    lea rdi, [rip + tf_repl]
    call tf_text
    mov rdi, rbx
    mov rsi, rax
    xor ecx, ecx
    call ed_insert
1:  mov edi, 1
    call goto_match
9:  EPILOGUE

# replace_all(): one undo step
replace_all:
    READONLY_RET
    PROLOGUE 16
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    lea rdi, [rip + tf_find]
    call tf_text
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 9f
    mov rdi, rbx
    call doc_begin_group
    xor r15d, r15d              # position
    mov dword ptr [rsp], 0      # count
1:  mov rdi, rbx
    call doc_len
    mov r14, rax
    mov rdx, r14
    sub rdx, r15
    jbe 2f
    # After a replacement the remaining text is beyond the gap. Search it directly,
    # without moving the whole suffix to the front for every match.
    cmp dword ptr [rip + g_find_word], 0
    jne .Lra_word
    mov rdi, rbx
    mov rsi, r15
    call doc_range
    mov rdi, rax
    jmp .Lra_search
.Lra_word:
    # Whole-word matching uses the contiguous document's bounds for adjacent bytes.
    mov rdi, rbx
    call doc_contiguous
    lea rdi, [rax + r15]
.Lra_search:
    mov rsi, r14
    sub rsi, r15
    jbe 2f
    mov rdx, r12
    mov rcx, r13
    call find_raw
    test rax, rax
    js 2f
    add r15, rax
    mov rdi, rbx
    mov rsi, r15
    mov rdx, r13
    xor ecx, ecx
    call doc_delete
    lea rdi, [rip + tf_repl]
    call tf_text
    mov r14, rdx
    mov rdi, rbx
    mov rsi, r15
    mov rdx, rax
    mov rcx, r14
    xor r8d, r8d
    call doc_insert
    add r15, r14
    inc dword ptr [rsp]
    jmp 1b
2:  mov rdi, rbx
    call doc_end_group
    call ed_touch
    call update_matches
9:  EPILOGUE

FN find_changed
    mov dword ptr [rip + g_find_word], 0
    cmp dword ptr [rip + find_sub], 0
    jne 1f
    call update_matches
    # incremental: jump to the first match at or after the selection start
    mov rax, [rip + g_doc]
    test rax, rax
    jz 1f
    mov rcx, [rax + DOC_cur]
    mov rdx, [rax + DOC_anchor]
    cmp rcx, rdx
    cmova rcx, rdx
    mov [rax + DOC_cur], rcx
    mov [rax + DOC_anchor], rcx
    mov edi, 1
    call goto_match
1:  ret

# find_key(keysym, cp, mods) -> 1 if handled
FN find_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    cmp r12d, KEY_ESCAPE
    jne 1f
    call close_bar
    jmp .Lfk_yes
1:  cmp r12d, KEY_RETURN
    je 2f
    cmp r12d, KEY_KP_ENTER
    jne 3f
2:  cmp dword ptr [rip + find_sub], 0
    je 21f
    test r14d, MOD_CTRL
    jz 22f
    call replace_all
    jmp .Lfk_yes
22: call replace_one
    jmp .Lfk_yes
21: mov edi, 1
    test r14d, MOD_SHIFT
    jz 23f
    mov edi, -1
23: call goto_match
    jmp .Lfk_yes
3:  cmp r12d, KEY_TAB
    je 31f
    cmp r12d, KEY_ISO_LEFT_TAB
    jne 4f
31: cmp dword ptr [rip + repl_open], 0
    je .Lfk_yes
    xor dword ptr [rip + find_sub], 1
    jmp .Lfk_yes
4:  cmp r12d, KEY_UP
    jne 5f
    mov edi, -1
    call goto_match
    jmp .Lfk_yes
5:  cmp r12d, KEY_DOWN
    jne 6f
    mov edi, 1
    call goto_match
    jmp .Lfk_yes
6:  call find_field
    mov rdi, rax
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
    test eax, eax
    jz 7f
    call find_changed
    jmp .Lfk_yes
7:  xor eax, eax
    EPILOGUE
.Lfk_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE

# ---- vim search ----

# find_vim_query() -> rax ptr, rdx len: the text searched for
FN find_vim_query
    lea rdi, [rip + tf_find]
    jmp tf_text

# find_vim_word(ptr, len, word): the text searched for (word: whole words only); find_vim_step marks the matches
FN find_vim_word
    mov [rip + g_find_word], edx
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + tf_find]
    jmp tf_set

# find_vim_step(pos, dir) -> the first match after pos (dir 1) or the last one before it (-1), wrapping; -1 if none
FN find_vim_step
    PROLOGUE 32
    mov r14, rdi
    mov [rsp], esi
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz .Lvs_none
    call update_matches
    lea rdi, [rip + tf_find]
    call tf_text
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz .Lvs_none
    mov rdi, rbx
    call doc_len
    mov r15, rax
    mov rdi, rbx
    call doc_contiguous
    mov [rsp + 8], rax
    cmp dword ptr [rsp], 0
    jl .Lvs_back
    # forward from pos + 1, then from the start
    lea rcx, [r14 + 1]
    cmp rcx, r15
    jae 2f
    mov [rsp + 16], rcx
    mov rdi, [rsp + 8]
    add rdi, rcx
    mov rsi, r15
    sub rsi, rcx
    mov rdx, r12
    mov rcx, r13
    call find_raw
    test rax, rax
    js 2f
    add rax, [rsp + 16]
    EPILOGUE
2:  mov rdi, [rsp + 8]
    mov rsi, r15
    mov rdx, r12
    mov rcx, r13
    call find_raw
    EPILOGUE
.Lvs_back:
    # the last match starting before pos, else the last one
    mov qword ptr [rsp + 16], -1
    mov qword ptr [rsp + 24], -1
    xor ecx, ecx
3:  mov rdi, [rsp + 8]
    add rdi, rcx
    mov rsi, r15
    sub rsi, rcx
    jbe 5f
    mov rdx, r12
    push rcx
    push rcx
    mov rcx, r13
    call find_raw
    pop rcx
    pop rcx
    test rax, rax
    js 5f
    add rcx, rax
    mov [rsp + 24], rcx
    cmp rcx, r14
    jae 4f
    mov [rsp + 16], rcx
4:  inc rcx
    jmp 3b
5:  mov rax, [rsp + 16]
    test rax, rax
    jns 6f
    mov rax, [rsp + 24]
6:  EPILOGUE
.Lvs_none:
    mov rax, -1
    EPILOGUE

# find_draw(): overlay at the top right of the editor
FN find_draw
    PROLOGUE 48
    cmp dword ptr [rip + find_open], 0
    je .Lfd_ret
    cmp qword ptr [rip + g_doc], 0
    je .Lfd_ret
    mov edi, 470
    call sc
    mov ecx, [rip + g_editor_rect + 8]
    sub ecx, [rip + g_mt + 4*MI_40]
    cmp eax, ecx
    cmovg eax, ecx
    mov r12d, eax               # w
    M r13d, MI_48               # h
    cmp dword ptr [rip + repl_open], 0
    je 1f
    add r13d, [rip + g_mt + 4*MI_40]
1:  mov r14d, [rip + g_editor_rect]
    add r14d, [rip + g_editor_rect + 8]
    sub r14d, r12d
    sub r14d, [rip + g_mt + 4*MI_24]      # x
    mov r15d, [rip + g_editor_rect + 4]
    add r15d, [rip + g_mt + 4*MI_8]       # y
    mov edi, r14d
    mov esi, r15d
    mov edx, r12d
    mov ecx, r13d
    call ui_card
    # layout: field | count | Aa | up | down | close
    M ebx, MI_32                # button size
    mov eax, r12d
    sub eax, ebx
    sub eax, ebx
    sub eax, ebx
    sub eax, ebx
    sub eax, [rip + g_mt + 4*MI_64]
    sub eax, [rip + g_mt + 4*MI_20]
    mov [rsp], eax              # field w
    M eax, MI_8
    lea esi, [r14 + rax]
    mov [rsp + 4], esi          # field x
    lea edx, [r15 + rax]
    mov [rsp + 8], edx          # row y
    lea rdi, [rip + tf_find]
    mov ecx, [rsp]
    mov r8d, ebx
    xor r9d, r9d
    cmp dword ptr [rip + find_sub], 0
    jne 2f
    cmp dword ptr [rip + g_focus], FOCUS_FIND
    jne 2f
    mov r9d, 1
2:  lea rax, [rip + .Lfind_ph]
    push rax
    push rax
    call ui_textfield
    add rsp, 16
    test eax, UB_PRESS
    jz 3f
    mov dword ptr [rip + find_sub], 0
    mov dword ptr [rip + g_focus], FOCUS_FIND
3:  # count "n of m" / "No results"
    mov eax, [rsp + 4]
    add eax, [rsp]
    add eax, [rip + g_mt + 4*MI_8]
    mov [rsp + 12], eax         # x after field
    mov byte ptr [rip + buf], 0
    cmp qword ptr [rip + tf_find + TF_sb + SB_len], 0
    je 5f
    cmp dword ptr [rip + match_count], 0
    jne 4f
    lea rdi, [rip + buf]
    lea rsi, [rip + .Lnone]
    call cstr_copy
    jmp 5f
4:  lea rdi, [rip + buf]
    mov esi, [rip + match_index]
    call fmt_u64
    lea rsi, [rip + .Lof]
    call cstr_copy
    mov rdi, rax
    mov esi, [rip + match_count]
    call fmt_u64
    mov byte ptr [rdi], 0
5:
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 12]
    mov edx, [rsp + 8]
    mov ecx, ebx
    lea r8, [rip + buf]
    COLOR r9d, T_UI_MUTED
    call ui_text_c
    # toggles and arrows after the count
    mov r12d, [rsp + 12]
    add r12d, [rip + g_mt + 4*MI_64]
    add r12d, [rip + g_mt + 4*MI_4]
    # Aa toggle
    mov edi, ID_FIND_CASE
    mov esi, r12d
    mov edx, [rsp + 8]
    mov ecx, ebx
    mov r8d, ebx
    call ui_btn
    mov [rsp + 16], eax
    cmp dword ptr [rip + find_case], 0
    je 6f
    mov edi, r12d
    mov esi, [rsp + 8]
    mov edx, ebx
    mov ecx, ebx
    M r8d, MI_RADIUS
    COLOR r9d, T_ACTIVE
    call gfx_round_rect
    jmp 7f
6:  test dword ptr [rsp + 16], UB_HOVER
    jz 7f
    mov edi, r12d
    mov esi, [rsp + 8]
    mov edx, ebx
    mov ecx, ebx
    M r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
7:  lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, [rsp + 8]
    mov ecx, ebx
    mov r8d, ebx
    lea r9, [rip + .Laa]
    COLOR eax, T_UI_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    test dword ptr [rsp + 16], UB_CLICK
    jz 8f
    xor dword ptr [rip + find_case], 1
    call update_matches
8:  add r12d, ebx
    mov edi, ID_FIND_PREV
    mov esi, r12d
    mov edx, [rsp + 8]
    mov ecx, ebx
    mov r8d, ebx
    mov r9d, IC_CHEV_UP
    call ui_icon_btn
    test eax, UB_CLICK
    jz 9f
    mov edi, -1
    call goto_match
9:  add r12d, ebx
    mov edi, ID_FIND_NEXT
    mov esi, r12d
    mov edx, [rsp + 8]
    mov ecx, ebx
    mov r8d, ebx
    mov r9d, IC_CHEV_DN2
    call ui_icon_btn
    test eax, UB_CLICK
    jz 10f
    mov edi, 1
    call goto_match
10: add r12d, ebx
    mov edi, ID_FIND_CLOSE
    mov esi, r12d
    mov edx, [rsp + 8]
    mov ecx, ebx
    mov r8d, ebx
    mov r9d, IC_CLOSE
    call ui_icon_btn
    test eax, UB_CLICK
    jz 11f
    call close_bar
    jmp .Lfd_ret
11: cmp dword ptr [rip + repl_open], 0
    je .Lfd_ret
    # replace row
    mov eax, [rsp + 8]
    add eax, [rip + g_mt + 4*MI_40]
    mov [rsp + 8], eax
    lea rdi, [rip + tf_repl]
    mov esi, [rsp + 4]
    mov edx, eax
    mov ecx, [rsp]
    mov r8d, ebx
    xor r9d, r9d
    cmp dword ptr [rip + find_sub], 1
    jne 12f
    cmp dword ptr [rip + g_focus], FOCUS_FIND
    jne 12f
    mov r9d, 1
12: lea rax, [rip + .Lrepl_ph]
    push rax
    push rax
    call ui_textfield
    add rsp, 16
    test eax, UB_PRESS
    jz 13f
    mov dword ptr [rip + find_sub], 1
    mov dword ptr [rip + g_focus], FOCUS_FIND
13: mov r12d, [rsp + 12]
    mov edi, ID_REPL_ONE
    lea r8, [rip + .Lrepl]
    call text_button
    mov [rsp + 20], edx
    test eax, UB_CLICK
    jz 14f
    call replace_one
14: add r12d, [rsp + 20]
    add r12d, [rip + g_mt + 4*MI_8]
    mov edi, ID_REPL_ALL
    lea r8, [rip + .Lrepl_all]
    call text_button
    test eax, UB_CLICK
    jz .Lfd_ret
    call replace_all
.Lfd_ret:
    EPILOGUE

# text_button: edi id, r12d x, [rsp+8+8] y of caller, ebx h, r8 label -> eax UB bits
text_button:
    PROLOGUE 16
    mov r13d, edi
    mov r14, r8
    mov rdi, r8
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, r14
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_20]
    mov r15d, eax
    mov edi, r13d
    mov esi, r12d
    mov edx, [rbp + 16 + 8]
    mov ecx, r15d
    mov r8d, ebx
    call ui_btn
    mov [rsp], eax
    mov edi, r12d
    mov esi, [rbp + 16 + 8]
    mov edx, r15d
    mov ecx, ebx
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    COLOR eax, T_INPUT
    test dword ptr [rsp], UB_HOVER
    jz 1f
    COLOR eax, T_HOVER
1:  push rax
    push rax
    call gfx_frame
    add rsp, 16
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, [rbp + 16 + 8]
    mov ecx, r15d
    mov r8d, ebx
    mov r9, r14
    COLOR eax, T_UI_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    mov eax, [rsp]
    mov edx, r15d
    EPILOGUE

.section .rodata
.Lnl: .ascii "\n"
.Lnone: .asciz "No results"
.Lof: .asciz " of "
.Laa: .asciz "Aa"
.Lfind_ph: .asciz "Find"
.Lrepl_ph: .asciz "Replace"
.Lrepl: .asciz "Replace"
.Lrepl_all: .asciz "All"
