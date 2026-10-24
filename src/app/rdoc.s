# doc views (views design 3.8.4, feature view-doc): a retained view of kind doc shows Markdown
# rendered by markdown.s. Ops: "doc LEN" + Markdown (the document, at most 1 MB), "base LEN" + an
# absolute folder (relative links), "follow DOC 0" (while document DOC is the active one the view
# keeps the block holding the editor's top line at its top; a double click on a block moves the
# editor there; 0 stops). Links: rhun://, http(s) and files under the base are followed by rhun,
# "#slug" scrolls to its heading, others are a "link" event. Keys: arrows, Page Up/Down, Space,
# Home, End scroll; Tab and Shift+Tab move between links, Enter follows one.
#     dc = mdview_new(slot, ext); mdview_free(dc)
#     mdview_check_op(rr) -> 1 good, 0 not, 2 too big, -1 not a doc op; mdview_apply_op(dc, rr)
#     mdview_draw(dc, x, y, w, h, focused); mdview_key(dc, keysym, cp, mods) -> taken; mdview_dump(dc, sb)
#     mdview_clip(dc, kind): Ctrl+C copies the text selected by dragging, Ctrl+A selects it all
.include "rhun.inc"

.equ DOC_MD_MAX, 1048576
.equ ID_DOC, 0x640000           # + slot * 4096: its links; + 0xffe the area, + 0xfff the scrollbar

.equ DC_md, 0                   # MD* or 0
.equ DC_base, 8                 # cstr (mem_alloc'd) or 0
.equ DC_ext, 16
.equ DC_slot, 24
.equ DC_scroll, 28
.equ DC_follow, 32              # the document followed (its number), 0 none
.equ DC_h, 36                   # the content's height, laid out
.equ DC_vh, 40                  # the view's height, last drawn
.equ DC_line, 44                # the editor's top line last followed, -1
.equ DC_tx, 48                  # where its text was last drawn (headless)
.equ DC_ty, 52
.equ DC_SIZE, 56

.text

# mdview_new(slot, ext) -> rax a doc view's state
FN mdview_new
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov edi, DC_SIZE
    call mem_alloc
    mov r13, rax
    mov rdi, r13
    xor esi, esi
    mov edx, DC_SIZE
    call memset
    mov [r13 + DC_slot], ebx
    mov [r13 + DC_ext], r12
    mov dword ptr [r13 + DC_line], -1
    mov rax, r13
    EPILOGUE

# mdview_free(dc or 0)
FN mdview_free
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    mov rdi, [rbx + DC_md]
    call md_free
    mov rdi, [rbx + DC_base]
    call mem_free
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# mdview_check_op(rr) -> eax 1 a good doc op, 0 one rhun cannot read, 2 past 1 MB, -1 not a doc op
FN mdview_check_op
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_doc]
    call tree_rec_is
    test eax, eax
    jz 2f
    cmp qword ptr [rbx + RR_n], 2
    jne 8f
    cmp qword ptr [rbx + RR_len], DOC_MD_MAX
    ja 7f
    mov eax, 1
    EPILOGUE
2:  mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_base]
    call tree_rec_is
    test eax, eax
    jz 4f
    cmp qword ptr [rbx + RR_n], 2
    jne 8f
    mov rcx, [rbx + RR_len]
    test rcx, rcx
    jz 8f
    cmp rcx, 4096
    ja 8f
    mov rdi, [rbx + RR_data]
    xor edx, edx
3:  cmp rdx, rcx                # one line, no NUL
    jae 31f
    movzx eax, byte ptr [rdi + rdx]
    cmp eax, 10
    je 8f
    test eax, eax
    jz 8f
    inc rdx
    jmp 3b
31: movzx eax, byte ptr [rdi]   # absolute: "/" or a drive "X:/" "X:\"
    cmp eax, '/'
    je 6f
    cmp rcx, 3
    jb 8f
    cmp byte ptr [rdi + 1], ':'
    jne 8f
    movzx eax, byte ptr [rdi + 2]
    cmp eax, '/'
    je 6f
    cmp eax, '\\'
    je 6f
    jmp 8f
4:  mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + .Lo_follow]
    call tree_rec_is
    test eax, eax
    jz 9f
    cmp qword ptr [rbx + RR_n], 3
    jne 8f
    cmp qword ptr [rbx + RR_len], 0
    jne 8f
    mov rdi, rbx
    mov esi, 1
    call tree_rec_num
    test edx, edx
    jz 8f
    cmp rax, 0x7fffffff
    ja 8f
6:  mov eax, 1
    EPILOGUE
7:  mov eax, 2
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
9:  mov eax, -1
    EPILOGUE

# mdview_apply_op(dc, rr): a doc op doc_check_op passed
FN mdview_apply_op
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    xor esi, esi
    lea rdx, [rip + .Lo_doc]
    call tree_rec_is
    test eax, eax
    jz 2f
    mov rdi, [rbx + DC_md]      # the document again; its base and the extension stay
    call md_free
    mov rdi, [r12 + RR_data]
    mov rsi, [r12 + RR_len]
    call md_new
    mov [rbx + DC_md], rax
    mov rdi, rax
    mov rsi, [rbx + DC_ext]
    call md_set_ext
    mov rsi, [rbx + DC_base]
    test rsi, rsi
    jz 1f
    mov rdi, rsi
    call strlen
    mov rdx, rax
    mov rdi, [rbx + DC_md]
    mov rsi, [rbx + DC_base]
    call md_set_base
1:  mov dword ptr [rbx + DC_line], -1   # followed again from the editor's line
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
2:  mov rdi, r12
    xor esi, esi
    lea rdx, [rip + .Lo_base]
    call tree_rec_is
    test eax, eax
    jz 3f
    mov rdi, [rbx + DC_base]
    call mem_free
    mov rdi, [r12 + RR_data]
    mov rsi, [r12 + RR_len]
    call mem_dup
    mov [rbx + DC_base], rax
    mov rdi, [rbx + DC_md]
    test rdi, rdi
    jz 9f
    mov rsi, [r12 + RR_data]
    mov rdx, [r12 + RR_len]
    call md_set_base
    EPILOGUE
3:  mov rdi, r12
    mov esi, 1
    call tree_rec_num
    mov [rbx + DC_follow], eax
    mov dword ptr [rbx + DC_line], -1
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# mdview_draw(dc, x, y, w, h, focused): the document with a margin, scrolled (the wheel, the scrollbar,
#   following the editor); a link clicked is followed; a double click moves a followed editor
FN mdview_draw
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov [rbx + DC_vh], r8d
    mov r12, [rbx + DC_md]
    test r12, r12
    jz 9f
    M eax, MI_16
    mov ecx, [rsp + 8]
    sub ecx, eax
    sub ecx, eax
    sub ecx, [rip + g_mt + 4*MI_12]
    mov ecx, ecx
    cmp ecx, 1
    jge 1f
    mov ecx, 1
1:  mov [rsp + 16], ecx         # the text's width
    mov rdi, r12
    mov esi, ecx
    call md_layout
    add eax, [rip + g_mt + 4*MI_16]
    mov [rbx + DC_h], eax
    # the area: a double click; the wheel
    mov edi, [rbx + DC_slot]
    shl edi, 12
    add edi, ID_DOC + 0xffe
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    sub ecx, [rip + g_mt + 4*MI_12]
    mov r8d, [rsp + 12]
    call ui_btn
    mov [rsp + 20], eax
    test eax, UB_HOVER
    jz 2f
    mov eax, [rip + g_scroll_y]
    add [rbx + DC_scroll], eax
2:  mov rdi, r12                # dragging selects text
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 4]
    add edx, [rip + g_mt + 4*MI_8]
    mov [rbx + DC_tx], esi
    mov [rbx + DC_ty], edx
    mov ecx, [rbx + DC_scroll]
    mov r8d, [rsp + 20]
    call md_select_mouse
    # following the editor's top line
    mov rdi, rbx
    call follow_editor
    mov rdi, rbx
    call clamp
    test dword ptr [rsp + 20], UB_DOUBLE
    jz 3f
    mov eax, [rbx + DC_follow]  # only while the followed document is the active one
    test eax, eax
    jz 3f
    mov rcx, [rip + g_doc]
    test rcx, rcx
    jz 3f
    cmp [rcx + DOC_id], rax
    jne 3f
    mov esi, [rip + g_my]       # the block there: the editor goes to its line
    sub esi, [rsp + 4]
    sub esi, [rip + g_mt + 4*MI_8]
    add esi, [rbx + DC_scroll]
    mov rdi, r12
    call md_y_line
    test eax, eax
    js 3f
    mov [rbx + DC_line], eax    # the view stays where it is
    lea edi, [rax + 1]
    mov esi, 1
    call follow_goto
3:  # the document
    mov edi, [rbx + DC_slot]
    shl edi, 12
    add edi, ID_DOC
    push rdi
    push rdi
    mov rdi, r12
    mov esi, [rsp + 16]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 16 + 4]
    add edx, [rip + g_mt + 4*MI_8]
    mov ecx, [rsp + 16 + 16]
    mov r8d, [rsp + 16 + 12]
    sub r8d, [rip + g_mt + 4*MI_8]
    mov r9d, [rbx + DC_scroll]
    call md_draw
    add rsp, 16
    test eax, eax
    js 4f
    mov rdi, rbx
    mov esi, eax
    call mdview_link
4:  # the scrollbar
    mov eax, [rsp + 12]
    push rax
    mov eax, [rbx + DC_h]
    push rax
    mov edi, [rbx + DC_slot]
    shl edi, 12
    add edi, ID_DOC + 0xfff
    mov esi, [rsp + 16]
    add esi, [rsp + 16 + 8]
    M eax, MI_12
    sub esi, eax
    mov edx, [rsp + 16 + 4]
    mov ecx, eax
    mov r8d, [rsp + 16 + 12]
    lea r9, [rbx + DC_scroll]
    call ui_scrollbar
    add rsp, 16
9:  EPILOGUE

# follow_goto(line, col): the editor to that line (app_goto_line), kept apart for the tests
follow_goto:
    jmp app_goto_line

# follow_editor(dc): while its followed document is the active one, the block holding the editor's
#   top line goes to the top when that line changed
follow_editor:
    mov eax, [rdi + DC_follow]
    test eax, eax
    jz 9f
    mov rcx, [rip + g_doc]
    test rcx, rcx
    jz 9f
    cmp [rcx + DOC_id], rax
    jne 9f
    mov rax, [rcx + DOC_scrolly]
    sar rax, 8
    cmp eax, [rdi + DC_line]
    je 9f
    mov [rdi + DC_line], eax
    push rdi
    mov esi, eax
    mov rdi, [rdi + DC_md]
    call md_line_y
    pop rdi
    mov [rdi + DC_scroll], eax
    mov dword ptr [rip + g_dirty], 1
9:  ret

# mdview_follow_due(dc) -> eax 1 when it follows the active document and the editor's top line is
#   not the one it last followed
FN mdview_follow_due
    xor eax, eax
    mov ecx, [rdi + DC_follow]
    test ecx, ecx
    jz 9f
    mov rdx, [rip + g_doc]
    test rdx, rdx
    jz 9f
    cmp [rdx + DOC_id], rcx
    jne 9f
    mov rdx, [rdx + DOC_scrolly]
    sar rdx, 8
    cmp edx, [rdi + DC_line]
    je 9f
    mov eax, 1
9:  ret

# clamp(dc): the scroll within the content
clamp:
    mov eax, [rdi + DC_h]
    sub eax, [rdi + DC_vh]
    jns 1f
    xor eax, eax
1:  cmp [rdi + DC_scroll], eax
    jle 2f
    mov [rdi + DC_scroll], eax
2:  cmp dword ptr [rdi + DC_scroll], 0
    jge 9f
    mov dword ptr [rdi + DC_scroll], 0
9:  ret

# mdview_link(dc, link): followed: "#slug" scrolls to its heading; rhun follows what md_open_link
#   does; anything else is a "link REV LEN" + target event
FN mdview_link
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, [rbx + DC_md]
    test rdi, rdi
    jz 9f
    mov esi, r12d
    call md_open_link          # native code-copy actions must run before testing anchor text
    test eax, eax
    jnz 9f
    mov rdi, [rbx + DC_md]
    mov esi, r12d
    call md_link
    test rdx, rdx
    jz 9f
    mov r13, rax
    mov r14, rdx
    cmp byte ptr [r13], '#'
    jne 1f
    mov rdi, [rbx + DC_md]
    mov rsi, r13
    mov rdx, r14
    call md_anchor
    test eax, eax
    js 9f
    mov [rbx + DC_scroll], eax
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
1:  mov edi, [rbx + DC_slot]
    mov rsi, r13
    mov rdx, r14
    call rview_link_event
9:  EPILOGUE

# mdview_key(dc, keysym, cp, mods) -> eax 1 when it took the key
FN mdview_key
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r14d, ecx
    mov r13, [rbx + DC_md]
    test r13, r13
    jz 8f
    M ecx, MI_20                # a line
    mov eax, [rbx + DC_vh]      # a page
    sub eax, [rip + g_mt + 4*MI_32]
    cmp eax, ecx
    cmovl eax, ecx
    cmp r12d, KEY_DOWN
    je 10f
    cmp r12d, KEY_UP
    je 11f
    cmp r12d, KEY_PAGEDOWN
    je 12f
    cmp r12d, KEY_PAGEUP
    je 13f
    cmp r12d, ' '
    jne 1f
    test r14d, MOD_SHIFT
    jnz 13f
    jmp 12f
1:  cmp r12d, KEY_HOME
    je 14f
    cmp r12d, KEY_END
    je 15f
    cmp r12d, KEY_TAB
    je 16f
    cmp r12d, KEY_RETURN
    je 17f
    cmp r12d, KEY_KP_ENTER
    je 17f
8:  xor eax, eax
    EPILOGUE
10: add [rbx + DC_scroll], ecx
    jmp 7f
11: sub [rbx + DC_scroll], ecx
    jmp 7f
12: add [rbx + DC_scroll], eax
    jmp 7f
13: sub [rbx + DC_scroll], eax
    jmp 7f
14: mov dword ptr [rbx + DC_scroll], 0
    jmp 7f
15: mov eax, [rbx + DC_h]
    mov [rbx + DC_scroll], eax
    jmp 7f
16: # the next link (Shift: the one before), into view
    mov rdi, r13
    call md_links
    test eax, eax
    jz 7f
    mov r15d, eax
    mov rdi, r13
    call md_focus
    mov ecx, r15d
    test r14d, MOD_SHIFT
    jnz 161f
    inc eax
    cmp eax, ecx
    jl 162f
    xor eax, eax
    jmp 162f
161:dec eax
    jns 162f
    lea eax, [rcx - 1]
162:mov r15d, eax
    mov rdi, r13
    mov esi, eax
    call md_set_focus
    mov rdi, r13
    mov esi, r15d
    call md_link_y
    test eax, eax
    js 7f
    cmp eax, [rbx + DC_scroll]
    jl 163f
    mov ecx, [rbx + DC_scroll]
    add ecx, [rbx + DC_vh]
    sub ecx, [rip + g_mt + 4*MI_32]
    cmp eax, ecx
    jl 7f
    sub eax, [rbx + DC_vh]
    add eax, [rip + g_mt + 4*MI_48]
163:mov [rbx + DC_scroll], eax
    jmp 7f
17: mov rdi, r13
    call md_focus
    test eax, eax
    js 7f
    mov rdi, rbx
    mov esi, eax
    call mdview_link
7:  mov rdi, rbx
    call clamp
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE

# mdview_clip(dc, kind 0 copy, 1 cut, 2 select all): the selected text to the clipboard, or all of
#   it selected
FN mdview_clip
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    mov rdi, [rbx + DC_md]
    test rdi, rdi
    jz 9f
    cmp r12d, 2
    jne 1f
    call md_select_all
    jmp 9f
1:  lea rdi, [rsp]
    xor esi, esi
    mov edx, SB_SIZE
    call memset
    mov rdi, [rbx + DC_md]
    lea rsi, [rsp]
    call md_sel_text
    test eax, eax
    jz 8f
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    xor edx, edx
    call ed_clip_set
8:  lea rdi, [rsp]
    call sb_free
9:  EPILOGUE

# mdview_dump(dc, sb): "doc scroll=S height=H follow=N line=E at=X,Y focus=L" LF (E the editor line followed), then md_dump's lines
FN mdview_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Ld_doc]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + DC_scroll]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_height]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + DC_h]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_follow]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + DC_follow]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_line]
    call sb_push_cstr
    mov esi, [rbx + DC_line]
    test esi, esi
    jns 11f
    mov rdi, r12
    mov esi, '-'
    call sb_push_byte
    jmp 12f
11: mov rdi, r12
    call sb_push_u64
12: mov rdi, r12
    lea rsi, [rip + .Ld_at]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + DC_tx]
    call sb_push_u64
    mov rdi, r12
    mov esi, ','
    call sb_push_byte
    mov rdi, r12
    mov esi, [rbx + DC_ty]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_focus]
    call sb_push_cstr
    mov esi, -1
    mov rdi, [rbx + DC_md]
    test rdi, rdi
    jz 1f
    call md_focus
    mov esi, eax
1:  test esi, esi
    jns 2f
    mov rdi, r12
    mov esi, '-'
    call sb_push_byte
    jmp 3f
2:  mov rdi, r12
    call sb_push_u64
3:  mov rdi, r12
    mov esi, 10
    call sb_push_byte
    mov rdi, [rbx + DC_md]
    test rdi, rdi
    jz 9f
    mov rsi, r12
    call md_dump
9:  EPILOGUE

.section .rodata
.Lo_doc: .asciz "doc"
.Lo_base: .asciz "base"
.Lo_follow: .asciz "follow"
.Ld_doc: .asciz "doc scroll="
.Ld_height: .asciz " height="
.Ld_follow: .asciz " follow="
.Ld_focus: .asciz " focus="
.Ld_line: .asciz " line="
.Ld_at: .asciz " at="
