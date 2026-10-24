# Document links and ctrl+click (docs/extensions/v1.1.md, "document-links"): ctrl+click (cmd+click on
# macOS; alt+click when ctrl adds carets) on a link opens it (a URL in the browser, a path in rhun),
# on other text goes to the definition. The links are asked of every matching provider the first
# time the modifier is held over the document, or at the first such click, and kept for that
# version; a click that came before the answer acts on it when it comes. While the modifier is held
# the link under the pointer is underlined.
#
#   doclinks_click(doc, pos) -> eax 1 when the editor's click was the modifier's (editor.s),
#   doclinks_draw() (after the editor), doclinks_tick(), doclinks_reply(ext, id, ok, body, len) -> eax 1 when
#   it answered, doclinks_ext_gone(ext), doclinks_dump(sb)
.include "rhun.inc"

.equ LK_REQS, 8
.equ LK_MAX, 10000
.equ ID_LINK, 0x6c4000

# a link
STRUCT
F LKR_start, 8                  # byte positions in the document as asked
F LKR_end, 8
F LKR_target, 8                 # offsets in lk_bytes, cstrs
F LKR_tip, 8
ENDSTRUCT LKR_SIZE

.bss
.p2align 3
lk_doc: .quad 0                 # the links' document: DOC*, id, version (lk_have: they came)
lk_docid: .quad 0
lk_version: .quad 0
lk_have: .long 0
lk_click: .long 0               # a click waits for the answer: its position in lk_click_pos
lk_click_pos: .quad 0
lk_click_def: .quad 0           # and whether it goes to the definition without a link
lk_reqs: .zero 16 * LK_REQS
lk_nreqs: .quad 0
lk_links: .zero VEC_SIZE        # LKR
lk_bytes: .zero SB_SIZE
lk_line: .zero SB_SIZE
lk_path: .zero 4200
.ifdef MACOS
.globl g_mac_control_click
g_mac_control_click: .long 0    # physical Control makes a context click in AppKit
.endif

.text

# modifier() -> eax the modifier of link clicks: ctrl, or alt when ctrl adds carets
modifier:
    mov eax, MOD_CTRL
    cmp dword ptr [rip + cfg_multi_cursor_modifier], 0
    je 1f
    mov eax, MOD_ALT
1:  ret

# held() -> eax 1 while the modifier is down (as the last key or button said), without shift
FN doclinks_held
held:
    call modifier
.ifdef MACOS
    cmp dword ptr [rip + g_mac_control_click], 0
    jne 8f
.endif
    mov ecx, [rip + g_mods]
    test ecx, MOD_SHIFT
    jnz 8f
    test ecx, eax
    jz 8f
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# current(doc) -> eax 1 when the links held are about the document as it is
current:
    xor eax, eax
    cmp dword ptr [rip + lk_have], 0
    je 9f
    cmp rdi, [rip + lk_doc]
    jne 9f
    mov rcx, [rdi + DOC_id]
    cmp rcx, [rip + lk_docid]
    jne 9f
    mov rcx, [rdi + DOC_version]
    cmp rcx, [rip + lk_version]
    jne 9f
    mov eax, 1
9:  ret

# asking(doc) -> eax 1 when the links of the document as it is were asked for and are coming
asking:
    xor eax, eax
    cmp qword ptr [rip + lk_nreqs], 0
    je 9f
    cmp rdi, [rip + lk_doc]
    jne 9f
    mov rcx, [rdi + DOC_version]
    cmp rcx, [rip + lk_version]
    jne 9f
    mov eax, 1
9:  ret

# ask(doc) -> eax 1 when some provider was asked "document-links DOC VERSION"
ask:
    PROLOGUE
    mov rbx, rdi
    call withdraw
    mov [rip + lk_doc], rbx
    mov rax, [rbx + DOC_id]
    mov [rip + lk_docid], rax
    mov rax, [rbx + DOC_version]
    mov [rip + lk_version], rax
    mov dword ptr [rip + lk_have], 0
    mov qword ptr [rip + lk_links + VEC_len], 0
    lea rdi, [rip + lk_bytes]
    call sb_clear
    lea rdi, [rip + lk_line]
    call sb_clear
    lea rdi, [rip + lk_line]
    lea rsi, [rip + .Lv_links]
    call sb_push_cstr
    lea rdi, [rip + lk_line]
    mov rsi, [rbx + DOC_id]
    call sb_push_u64
    lea rdi, [rip + lk_line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + lk_line]
    mov rsi, [rbx + DOC_version]
    call sb_push_u64
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 8f
    imul r13, r12, EXT_SIZE
    add r13, [rip + g_exts + VEC_ptr]
    inc r12
    cmp qword ptr [rip + lk_nreqs], LK_REQS
    jae 8f
    mov rdi, r13
    call ext_is_visible
    test eax, eax
    jz 1b
    cmp dword ptr [r13 + EXT_status], ES_RUNNING
    jne 1b
    mov rdi, r13
    mov esi, FEAT_DOCUMENT_LINKS
    call ext_feature
    test eax, eax
    jz 1b
    mov rdi, r13
    mov esi, EXT_pv_document_links
    call ext_pv
    mov rdi, rax
    mov rsi, rbx
    call extproto_matches
    test eax, eax
    jz 1b
    mov edi, 1
    call query_room
    test eax, eax
    jz 8f
    mov rdi, r13
    mov rsi, rbx
    mov rdx, [rip + lk_line + SB_ptr]
    mov rcx, [rip + lk_line + SB_len]
    call extproto_host_send
    test rax, rax
    jz 1b
    mov r14, rax
    mov rdi, r13
    mov rsi, rax
    mov edx, PK_LINKS
    mov ecx, QO_LANGFEAT
    call query_track
    mov rax, [rip + lk_nreqs]
    shl rax, 4
    lea rcx, [rip + lk_reqs]
    mov [rcx + rax], r13
    mov [rcx + rax + 8], r14
    inc qword ptr [rip + lk_nreqs]
    jmp 1b
8:  xor eax, eax
    cmp qword ptr [rip + lk_nreqs], 0
    setne al
    jnz 9f
    mov dword ptr [rip + lk_have], 1     # nobody to ask: no links for this version
9:  EPILOGUE

withdraw:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + lk_nreqs]
    jae 2f
    mov rax, rbx
    shl rax, 4
    lea rcx, [rip + lk_reqs]
    mov rdi, [rcx + rax]
    mov rsi, [rcx + rax + 8]
    call query_withdraw
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + lk_nreqs], 0
    mov dword ptr [rip + lk_click], 0
    EPILOGUE

# FN doclinks_click(doc, pos) -> eax 1 when the click came with the modifier: a link there opens, other
# text goes to its definition (a click before the links came waits for them)
FN doclinks_click
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call held
    test eax, eax
    jz 8f
    mov rdi, rbx
    call current
    test eax, eax
    jnz 1f
    mov rdi, rbx
    call asking
    test eax, eax
    jnz 2f
    mov rdi, rbx
    call ask
    test eax, eax
    jz 1f                       # nobody to ask: the definition
2:  mov dword ptr [rip + lk_click], 1
    mov [rip + lk_click_pos], r12
    mov qword ptr [rip + lk_click_def], 1
    mov eax, 1
    EPILOGUE
1:  mov rdi, rbx
    mov rsi, r12
    mov edx, 1
    call act
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN cmd_open_link(): the link at the cursor opens (asked for first when needed)
FN cmd_open_link
    PROLOGUE
    call lf_focused_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov r12, [rbx + DOC_cur]
    mov rdi, rbx
    call current
    test eax, eax
    jnz 1f
    mov rdi, rbx
    call asking
    test eax, eax
    jnz 2f
    mov rdi, rbx
    call ask
    test eax, eax
    jz 1f
2:  mov dword ptr [rip + lk_click], 1
    mov [rip + lk_click_pos], r12
    mov qword ptr [rip + lk_click_def], 0
    jmp 9f
1:  mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call act
9:  EPILOGUE

# act(doc, pos, definition) -> eax 1: the link at the position opens; elsewhere (when definition is
# 1) the cursor goes there and Go to Definition runs; 0 when nothing happened ("No link here")
act:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rdi, r12
    call link_at
    test rax, rax
    jz 1f
    mov rdi, rax
    call open_link
    mov eax, 1
    EPILOGUE
1:  test r13d, r13d
    jnz 2f
    lea rdi, [rip + .Lno_link]
    call app_toast
    xor eax, eax
    EPILOGUE
2:  mov rdi, rbx
    mov rsi, r12
    call word_at
    cmp rax, rdx
    jae 8f
    mov [rbx + DOC_cur], r12
    mov [rbx + DOC_anchor], r12
    call ed_touch
    call cmd_definition
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# link_at(pos) -> rax the LKR whose range holds the position, or 0
link_at:
    xor ecx, ecx
1:  cmp rcx, [rip + lk_links + VEC_len]
    jae 8f
    imul rax, rcx, LKR_SIZE
    add rax, [rip + lk_links + VEC_ptr]
    inc rcx
    cmp rdi, [rax + LKR_start]
    jb 1b
    cmp rdi, [rax + LKR_end]
    jae 1b
    ret
8:  xor eax, eax
    ret

# open_link(LKR*): a URL in the browser; "#DOC" its tab; a path (with :LINE or :LINE:COL) in rhun
open_link:
    PROLOGUE
    mov rbx, [rdi + LKR_target]
    add rbx, [rip + lk_bytes + SB_ptr]
    lea rdi, [rip + .Lhttp]
    mov rsi, rbx
    call starts_cstr
    test eax, eax
    jnz 1f
    lea rdi, [rip + .Lhttps]
    mov rsi, rbx
    call starts_cstr
    test eax, eax
    jz 2f
1:  mov rdi, rbx
    call desktop_open
    EPILOGUE
2:  # a path: :LINE[:COL] at its end, when they are digits
    lea rdi, [rip + lk_path]
    mov rsi, rbx
    call cstr_copy
    lea r12, [rip + lk_path]
    xor r13d, r13d              # line
    xor r14d, r14d              # column
    mov rdi, r12
    call split_num
    test rax, rax
    js 3f
    mov r13, rax
    mov rdi, r12
    call split_num
    test rax, rax
    js 3f
    mov r14, r13                # PATH:LINE:COL: the first number split off was the column
    mov r13, rax
3:  mov rdi, r12
    call lf_open_path
    test rax, rax
    jz 9f
    test r13, r13
    jz 9f
    mov r15, rax
    mov rdi, r15
    mov rsi, r13
    mov rdx, r14
    test rdx, rdx
    jnz 4f
    mov edx, 1
4:  call lf_pos_near
    mov [r15 + DOC_cur], rax
    mov [r15 + DOC_anchor], rax
    call ed_touch
9:  mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# split_num(cstr) -> rax the number after its last ':' (cut off there), or -1 when it does not end
# in ":DIGITS"
split_num:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov rcx, rax
    xor edx, edx                # digits
1:  test rcx, rcx
    jz 8f
    movzx eax, byte ptr [rbx + rcx - 1]
    cmp eax, ':'
    je 2f
    sub eax, '0'
    cmp eax, 9
    ja 8f
    inc edx
    dec rcx
    jmp 1b
2:  test edx, edx
    jz 8f
    cmp edx, 9
    ja 8f
    cmp rcx, 1
    jbe 8f
    lea rdi, [rbx + rcx]
    mov esi, edx
    mov byte ptr [rbx + rcx - 1], 0
    call parse_u64
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# starts_cstr(prefix, s) -> eax 1 when s starts with prefix
starts_cstr:
1:  movzx eax, byte ptr [rdi]
    test eax, eax
    jz 2f
    cmp al, [rsi]
    jne 3f
    inc rdi
    inc rsi
    jmp 1b
2:  mov eax, 1
    ret
3:  xor eax, eax
    ret

# FN doclinks_reply(ext, id, ok, body, len) -> eax 1 when it answered one of the links' requests
FN doclinks_reply
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
    xor ecx, ecx
1:  cmp rcx, [rip + lk_nreqs]
    jae 8f
    mov rax, rcx
    shl rax, 4
    lea rdx, [rip + lk_reqs]
    add rax, rdx
    inc rcx
    cmp [rax], rbx
    jne 1b
    cmp [rax + 8], r12
    jne 1b
    mov rdx, [rip + lk_nreqs]
    dec rdx
    mov [rip + lk_nreqs], rdx
    shl rdx, 4
    lea rcx, [rip + lk_reqs]
    mov rsi, [rcx + rdx]
    mov [rax], rsi
    mov rsi, [rcx + rdx + 8]
    mov [rax + 8], rsi
    mov rdi, [rip + lk_docid]
    call extproto_doc
    cmp rax, [rip + lk_doc]
    jne 6f
    mov rcx, [rax + DOC_version]
    cmp rcx, [rip + lk_version]
    jne 6f
    test r13d, r13d
    jz 5f
    mov rdi, rax
    mov rsi, r14
    mov rdx, r15
    call take
    test eax, eax
    jnz 5f
    mov rdi, rbx
    mov esi, PK_LINKS
    call query_dropped
5:  cmp qword ptr [rip + lk_nreqs], 0
    jne 7f
    mov dword ptr [rip + lk_have], 1
    cmp dword ptr [rip + lk_click], 0
    je 7f
    mov dword ptr [rip + lk_click], 0     # the click that waited
    mov rdi, [rip + lk_doc]
    cmp rdi, [rip + g_doc]
    jne 7f
    mov rsi, [rip + lk_click_pos]
    mov rdx, [rip + lk_click_def]
    call act
    jmp 7f
6:  mov dword ptr [rip + lk_click], 0
7:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# take(doc, body, len) -> eax 1 with its links added, 0 when the body breaks the rules: "N", then L1
# C1 L2 C2 TARGET_LEN TIP_LEN and the bytes
take:
    PROLOGUE 32
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    mov edx, LK_MAX
    call lf_head
    test rax, rax
    js 8f
    mov r15, rax
    mov rax, [rip + lk_links + VEC_len]
    mov [rsp], rax
1:  test r15, r15
    jz 6f
    dec r15
    call ps_line
    test eax, eax
    jz 7f
    call lf_four
    test eax, eax
    jz 7f
    call ps_num
    test edx, edx
    jz 7f
    test rax, rax
    jz 7f
    cmp rax, 4200
    ja 7f
    mov r12, rax
    call ps_num
    test edx, edx
    jz 7f
    cmp rax, 1000
    ja 7f
    mov r13, rax
    call ps_eol
    test eax, eax
    jz 7f
    mov rdi, r12
    call lf_take
    test rax, rax
    jz 7f
    mov [rsp + 8], rax
    mov rdi, r13
    call lf_take
    test rax, rax
    jz 7f
    mov [rsp + 16], rax
    lea rax, [rip + lf_tmp4]
    mov rdi, rbx
    mov esi, [rax]
    mov edx, [rax + 4]
    call lf_pos
    test rax, rax
    js 1b                       # outside the text: left out
    mov r14, rax
    lea rax, [rip + lf_tmp4]
    mov rdi, rbx
    mov esi, [rax + 8]
    mov edx, [rax + 12]
    call lf_pos
    test rax, rax
    js 1b
    cmp rax, r14
    jbe 1b
    mov [rsp + 24], rax
    mov rdi, [rsp + 8]
    mov rsi, r12
    call bytes_in
    push rax
    push rax
    mov rdi, [rsp + 16 + 16]
    mov rsi, r13
    call bytes_in
    mov rcx, rax
    pop rdx
    pop rdx
    push rcx
    push rdx
    lea rdi, [rip + lk_links]
    mov esi, LKR_SIZE
    call vec_push
    pop rdx
    pop rcx
    mov [rax + LKR_target], rdx
    mov [rax + LKR_tip], rcx
    mov [rax + LKR_start], r14
    mov rcx, [rsp + 24]
    mov [rax + LKR_end], rcx
    jmp 1b
6:  mov rax, [rip + ps_ptr]
    cmp rax, [rip + ps_end]
    jne 7f
    mov eax, 1
    EPILOGUE
7:  mov rax, [rsp]
    mov [rip + lk_links + VEC_len], rax
8:  xor eax, eax
    EPILOGUE

# bytes_in(ptr, len) -> rax the offset of a one-line copy in lk_bytes
bytes_in:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rip + lk_bytes + SB_len]
    xor r14d, r14d
1:  cmp r14, r12
    jae 2f
    movzx esi, byte ptr [rbx + r14]
    cmp esi, ' '
    jae 11f
    mov esi, ' '
11: lea rdi, [rip + lk_bytes]
    call sb_push_byte
    inc r14
    jmp 1b
2:  lea rdi, [rip + lk_bytes]
    xor esi, esi
    call sb_push_byte
    mov rax, r13
    EPILOGUE

# FN doclinks_tick(): the modifier held over the editor's text asks for its links (once a version)
FN doclinks_tick
    PROLOGUE
    call held
    test eax, eax
    jz 9f
    mov rbx, [rip + g_hover_doc]
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call current
    test eax, eax
    jnz 9f
    mov rdi, rbx
    call asking
    test eax, eax
    jnz 9f
    mov rdi, rbx
    call ask
9:  EPILOGUE

# FN doclinks_draw(): while the modifier is held, the link under the pointer is underlined (lines that
# do not wrap)
FN doclinks_draw
    PROLOGUE 32
    call held
    test eax, eax
    jz 9f
    mov rbx, [rip + g_hover_doc]
    test rbx, rbx
    jz 9f
    cmp rbx, [rip + g_doc]
    jne 9f
    cmp dword ptr [rip + cfg_word_wrap], 0
    jne 9f
    mov rdi, rbx
    call current
    test eax, eax
    jz 9f
    mov rdi, [rip + g_hover_pos]
    call link_at
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rbx
    mov rsi, [r12 + LKR_start]
    call doc_line_of
    mov r13, rax                # its line
    mov rdi, rbx
    mov rsi, r13
    call doc_line_start
    mov r14, rax
    mov rdi, rbx
    mov rsi, r13
    call doc_line_text
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdx, [r12 + LKR_start]
    sub rdx, r14
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call cols_to
    mov [rsp + 16], eax
    mov rdx, [r12 + LKR_end]
    sub rdx, r14
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call cols_to
    sub eax, [rsp + 16]
    jle 9f
    imul eax, [rip + g_cw]
    mov [rsp + 20], eax         # its width
    mov rax, [rbx + DOC_scrolly]
    mov rcx, rax
    shr rax, 8
    and ecx, 255
    imul ecx, [rip + g_lh]
    shr ecx, 8
    mov rdx, r13
    sub rdx, rax
    js 9f
    imul edx, [rip + g_lh]
    add edx, [rip + g_ed_y]
    sub edx, ecx
    add edx, [rip + g_lh]
    sub edx, [rip + g_mt + 4*MI_2]
    mov esi, edx
    mov edi, [rsp + 16]
    imul edi, [rip + g_cw]
    add edi, [rip + g_ed_tx]
    sub edi, [rbx + DOC_scrollx]
    mov edx, [rsp + 20]
    M ecx, MI_1
    COLOR r8d, T_ACCENT
    call gfx_fill
    mov dword ptr [rip + g_cursor], CUR_POINTER
9:  EPILOGUE

# cols_to(text, len, to) -> eax the columns of text's first `to` bytes
cols_to:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r13, r12
    jbe 1f
    mov r13, r12
1:  xor r14d, r14d
    xor r15d, r15d
2:  cmp r14, r13
    jae 9f
    movzx eax, byte ptr [rbx + r14]
    cmp eax, 9
    jne 3f
    mov eax, r15d
    xor edx, edx
    div dword ptr [rip + g_tab_width]
    mov eax, [rip + g_tab_width]
    sub eax, edx
    add r15d, eax
    inc r14
    jmp 2b
3:  cmp eax, 0x80
    jae 4f
    inc r15d
    inc r14
    jmp 2b
4:  lea rdi, [rbx + r14]
    mov rsi, r12
    sub rsi, r14
    call utf8_decode
    push rdx
    push rdx
    mov edi, eax
    call cp_width
    add r15d, eax
    pop rdx
    pop rdx
    test edx, edx
    jnz 5f
    mov edx, 1
5:  add r14, rdx
    jmp 2b
9:  mov eax, r15d
    EPILOGUE

# FN doclinks_ext_gone(ext): its request is not waited for
FN doclinks_ext_gone
    xor ecx, ecx
1:  cmp rcx, [rip + lk_nreqs]
    jae 9f
    mov rax, rcx
    shl rax, 4
    lea rdx, [rip + lk_reqs]
    add rax, rdx
    cmp [rax], rdi
    je 2f
    inc rcx
    jmp 1b
2:  mov rdx, [rip + lk_nreqs]
    dec rdx
    mov [rip + lk_nreqs], rdx
    shl rdx, 4
    lea r8, [rip + lk_reqs]
    mov rsi, [r8 + rdx]
    mov [rax], rsi
    mov rsi, [r8 + rdx + 8]
    mov [rax + 8], rsi
    jmp 1b
9:  ret

# FN doclinks_dump(sb): print-links: "links=none" or "links doc=ID version=V n=N" and a line per link
# "L1 C1 L2 C2 TARGET"
FN doclinks_dump
    PROLOGUE
    mov r12, rdi
    cmp dword ptr [rip + lk_have], 0
    jne 1f
    mov rdi, r12
    lea rsi, [rip + .Ld_none]
    call sb_push_cstr
    EPILOGUE
1:  mov rdi, r12
    lea rsi, [rip + .Ld_doc]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rip + lk_docid]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_n]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rip + lk_links + VEC_len]
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + lk_docid]
    call extproto_doc
    mov r14, rax
    xor ebx, ebx
2:  cmp rbx, [rip + lk_links + VEC_len]
    jae 9f
    test r14, r14
    jz 9f
    imul r13, rbx, LKR_SIZE
    add r13, [rip + lk_links + VEC_ptr]
    inc rbx
    mov rdi, r14
    mov rsi, [r13 + LKR_start]
    call lf_line_col
    mov r15, rdx
    mov rdi, r12
    mov rsi, rax
    call sb_push_u64
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rdi, r12
    mov rsi, r15
    call sb_push_u64
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rdi, r14
    mov rsi, [r13 + LKR_end]
    call lf_line_col
    mov r15, rdx
    mov rdi, r12
    mov rsi, rax
    call sb_push_u64
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rdi, r12
    mov rsi, r15
    call sb_push_u64
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rsi, [r13 + LKR_target]
    add rsi, [rip + lk_bytes + SB_ptr]
    mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    jmp 2b
9:  EPILOGUE

.section .rodata
.Lv_links: .asciz "document-links "
.Lhttp: .asciz "http://"
.Lhttps: .asciz "https://"
.Lno_link: .asciz "No link here"
.Ld_none: .asciz "links=none\n"
.Ld_doc: .asciz "links doc="
.Ld_n: .asciz " n="
