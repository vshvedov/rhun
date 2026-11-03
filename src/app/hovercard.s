# The hover card (docs/extensions/v1.1.md, "hover-query"): when the pointer rests half a second on
# text, or for Show Hover (ctrl+i) at the cursor, rhun asks the providers that agreed hover-query
# and shows a card under the word (above it without room): the diagnostics at the position, each
# provider's text in rank order (identical ones once), a decoration's tip and a v1 hover answer,
# separated by rules, wrapped at 80 columns or 60% of the window, at most half the window high,
# scrolled with the wheel. It shows when every provider answered, or 1 s after asking with what
# came (later answers are added). A pointer card stays while the pointer is on the answered range,
# on the card, or crossing between them (400 ms of grace); ctrl+i again gives an invoked card the
# keyboard (Up/Down, PageUp/PageDown scroll; Escape closes). Typing, edits, another document and the
# completion list close it. Without an answer with text, the tooltip of extmarks.s stays as it was.
# Texts are drawn as plain text until the views group's Markdown renderer lands.
#
#   hovercard_tick(), hovercard_timeout() -> ms, hovercard_reply(ext, id, ok, body, len) -> eax 1
#   when it answered a hover-query (the pump), hovercard_draw(), hovercard_key(keysym, cp, mods)
#   -> eax taken, hovercard_covers() -> eax 1 while the card takes the tooltip's place,
#   hovercard_blocks_editor(), hovercard_asks(ext, doc) -> eax 1 when the extension gets
#   hover-query (not v1's "0 hover") for the document, hovercard_ext_gone(ext), hovercard_point(line,
#   col) (hover-at), hovercard_dump(sb), cmd_show_hover
.include "rhun.inc"

.equ HC_SHOW, 1000              # ms: show what came
.equ HC_GRACE, 400
.equ HC_TEXT_MAX, 65536         # one answer's text
.equ HC_ALL_MAX, 262144         # all of them
.equ HC_COLS, 80
.equ HC_DIAGS, 16               # diagnostics shown
.equ ID_HC_AREA, 0x6c5000       # the card's text (selecting it)
.equ ID_HC_LINKS, 0x6c6000      # + n: its links
.equ HCS_EXT, 1
.equ HCS_DIAG, 2
.equ HCS_DECO, 3
.equ HCS_V1, 4

# a request out
STRUCT
F HCR_ext, 8
F HCR_id, 8
ENDSTRUCT HCR_SIZE

# a provider's section
STRUCT
F HCX_ext, 8
F HCX_rank, 8                   # its place in g_exts
F HCX_text, 8                   # owned, line feeds only, tabs as spaces
F HCX_len, 8
ENDSTRUCT HCX_SIZE

.bss
.p2align 3
hc_state: .long 0               # 0 none, 1 asking, 2 shown
hc_kind: .long 0                # 0 pointer, 1 invoked
hc_focus: .long 0               # an invoked card has the keyboard
hc_scroll: .long 0              # its text's first pixel row shown
hc_hscroll: .long 0             # and first pixel column (code lines do not wrap)
hc_tw: .long 0                  # the text's width shown
hc_cw: .long 0                  # the text's widest line (a code line may pass the width)
hc_doc: .quad 0                 # the position: DOC*, its id and version, byte offset
hc_docid: .quad 0
hc_version: .quad 0
hc_pos: .quad 0
hc_line: .quad 0                # 1-based line and byte column
hc_col: .quad 0
hc_start: .quad 0               # when it asked
hc_leave: .quad 0               # when the pointer left it (grace), 0 while it is in
hc_rs: .quad 0                  # the answered range, rs == re for the position alone
hc_re: .quad 0
hc_ax: .long 0                  # the anchor: x, the word's row top and bottom
hc_ay0: .long 0
hc_ay: .long 0
hc_th: .long 0                  # its text's height laid out
hc_mmax: .long 0                # the width measure ran at (0: measure again)
hc_mw: .long 0                  # and the text width it gave
hc_mgen: .long 0                # at that face generation
hc_asked_doc: .quad 0           # the rest position last looked at
hc_asked_pos: .quad 0
hc_asked_since: .quad 0         # and when that rest began (g_hover_since)
hc_gen: .quad 0                 # changes when the sections do
hc_md: .quad 0                  # the card's document (markdown.s), made from hc_src
hc_bytes: .quad 0
hc_rect: .zero 16
hc_reqs: .zero VEC_SIZE         # HCR
hc_secs: .zero VEC_SIZE         # HCX, in rank order
hc_src: .zero SB_SIZE           # the card's Markdown, and the next frame's (re-parsed when it differs)
hc_new: .zero SB_SIZE
hc_parts: .zero 8 * 4 * (HC_DIAGS + 4)   # the layout's texts: offset in hc_dbuf, length, color, kind
hc_nparts: .quad 0
hc_dbuf: .zero SB_SIZE          # the diagnostics', the tip's and the v1 answer's texts, copied
hc_buf: .zero SB_SIZE           # a request line; a normalized text

.text

# ---------------- asking ----------------

# FN hovercard_asks(ext, doc) -> eax 1 when the running extension agreed hover-query and its hover
# patterns match the document
FN hovercard_asks
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call ext_is_visible
    test eax, eax
    jz 8f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 8f
    mov rdi, rbx
    mov esi, FEAT_HOVER_QUERY
    call ext_feature
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov esi, EXT_pv_hover
    call ext_pv
    test rax, rax
    jz 8f
    mov rdi, rax
    mov rsi, r12
    call extproto_matches
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# any_asks(doc) -> eax 1 when some extension gets hover-query for the document
any_asks:
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + g_exts + VEC_len]
    jae 8f
    imul rdi, rbx, EXT_SIZE
    add rdi, [rip + g_exts + VEC_ptr]
    inc rbx
    mov rsi, r12
    call hovercard_asks
    test eax, eax
    jz 1b
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# close(): no card, nothing asked
close:
    PROLOGUE
    call withdraw_all
    call free_secs
    mov dword ptr [rip + hc_state], 0
    mov dword ptr [rip + hc_focus], 0
    mov dword ptr [rip + hc_scroll], 0
    mov dword ptr [rip + hc_hscroll], 0
    mov qword ptr [rip + hc_leave], 0
    mov rdi, [rip + hc_md]      # the next card is made anew
    test rdi, rdi
    jz 1f
    call md_free
    mov qword ptr [rip + hc_md], 0
1:  mov qword ptr [rip + hc_src + SB_len], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

withdraw_all:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + hc_reqs + VEC_len]
    jae 2f
    imul rax, rbx, HCR_SIZE
    add rax, [rip + hc_reqs + VEC_ptr]
    inc rbx
    mov rdi, [rax + HCR_ext]
    mov rsi, [rax + HCR_id]
    call query_withdraw
    jmp 1b
2:  mov qword ptr [rip + hc_reqs + VEC_len], 0
    EPILOGUE

free_secs:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + hc_secs + VEC_len]
    jae 2f
    imul rax, rbx, HCX_SIZE
    add rax, [rip + hc_secs + VEC_ptr]
    inc rbx
    mov rdi, [rax + HCX_text]
    call mem_free
    jmp 1b
2:  mov qword ptr [rip + hc_secs + VEC_len], 0
    mov qword ptr [rip + hc_bytes], 0
    inc qword ptr [rip + hc_gen]
    EPILOGUE

# start(doc, pos, kind): ask every provider about the position (what was asked before goes)
start:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    call close
    mov eax, [rsp]
    mov [rip + hc_kind], eax
    mov [rip + hc_doc], rbx
    mov rax, [rbx + DOC_id]
    mov [rip + hc_docid], rax
    mov rax, [rbx + DOC_version]
    mov [rip + hc_version], rax
    mov [rip + hc_pos], r12
    mov [rip + hc_rs], r12
    mov [rip + hc_re], r12
    mov rdi, rbx
    mov rsi, r12
    call lf_line_col
    mov [rip + hc_line], rax
    mov [rip + hc_col], rdx
    call time_ms
    mov [rip + hc_start], rax
    call anchor
    # the request: "hover-query DOC VERSION LINE COL KIND -"
    lea rdi, [rip + hc_buf]
    call sb_clear
    lea rdi, [rip + hc_buf]
    lea rsi, [rip + .Lv_hover]
    call sb_push_cstr
    lea rdi, [rip + hc_buf]
    mov rsi, [rbx + DOC_id]
    call sb_push_u64
    lea rdi, [rip + hc_buf]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + hc_buf]
    mov rsi, [rbx + DOC_version]
    call sb_push_u64
    lea rdi, [rip + hc_buf]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + hc_buf]
    mov rsi, [rip + hc_line]
    call sb_push_u64
    lea rdi, [rip + hc_buf]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + hc_buf]
    mov rsi, [rip + hc_col]
    call sb_push_u64
    lea rsi, [rip + .Lk_pointer]
    cmp dword ptr [rsp], 0
    je 1f
    lea rsi, [rip + .Lk_invoked]
1:  lea rdi, [rip + hc_buf]
    call sb_push_cstr
    xor r13d, r13d
2:  cmp r13, [rip + g_exts + VEC_len]
    jae 5f
    imul r14, r13, EXT_SIZE
    add r14, [rip + g_exts + VEC_ptr]
    inc r13
    mov rdi, r14
    mov rsi, rbx
    call hovercard_asks
    test eax, eax
    jz 2b
    cmp dword ptr [rsp], 0
    jne 3f
    mov edi, 1                  # the pointer's: an automatic kind
    call query_room
    test eax, eax
    jz 5f
3:  mov rdi, r14
    mov rsi, rbx
    mov rdx, [rip + hc_buf + SB_ptr]
    mov rcx, [rip + hc_buf + SB_len]
    call extproto_host_send
    test rax, rax
    jz 2b
    mov r15, rax
    mov rdi, r14
    mov rsi, rax
    mov edx, PK_HOVER
    mov ecx, QO_LANGFEAT
    call query_track
    lea rdi, [rip + hc_reqs]
    mov esi, HCR_SIZE
    call vec_push
    mov [rax + HCR_ext], r14
    mov [rax + HCR_id], r15
    jmp 2b
5:  mov dword ptr [rip + hc_state], 1
    EPILOGUE

# anchor(): where the card goes: under the word the pointer rests on, or under the caret
anchor:
    PROLOGUE
    cmp dword ptr [rip + hc_kind], 0
    jne 2f
    mov rbx, [rip + hc_doc]
    mov eax, [rip + g_mx]
    mov [rip + hc_ax], eax
    mov rax, [rbx + DOC_scrolly]    # the row under the pointer: rows are a line high from the top
    and eax, 255
    imul eax, [rip + g_lh]
    shr eax, 8
    mov ecx, eax                # the first row's hidden part
    mov eax, [rip + g_my]
    sub eax, [rip + g_ed_y]
    add eax, ecx
    jns 1f
    xor eax, eax
1:  xor edx, edx
    div dword ptr [rip + g_lh]
    imul eax, [rip + g_lh]
    add eax, [rip + g_ed_y]
    sub eax, ecx
    mov [rip + hc_ay0], eax
    add eax, [rip + g_lh]
    mov [rip + hc_ay], eax
    EPILOGUE
2:  mov eax, [rip + g_ed_tx]
    mov ecx, [rip + g_ed_y]
    cmp dword ptr [rip + g_caret_ok], 0
    je 3f
    mov eax, [rip + g_caret_x]
    mov ecx, [rip + g_caret_y]
3:  mov [rip + hc_ax], eax
    mov [rip + hc_ay0], ecx
    add ecx, [rip + g_lh]
    mov [rip + hc_ay], ecx
    EPILOGUE

# FN cmd_show_hover(): the card at the cursor; with a card showing, the keyboard goes to it
FN cmd_show_hover
    PROLOGUE
    cmp dword ptr [rip + hc_state], 2
    jne 1f
    mov dword ptr [rip + hc_focus], 1
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
1:  call ed_single
    call lf_focused_doc
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, [rax + DOC_cur]
    mov edx, 1
    call start
    call settle                 # nobody to ask: what there is shows at once
9:  EPILOGUE

# FN hovercard_at_cursor(): an invoked card at the cursor, whatever showed (Next Problem)
FN hovercard_at_cursor
    PROLOGUE
    call lf_focused_doc
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, [rax + DOC_cur]
    mov edx, 1
    call start
    call settle
9:  EPILOGUE

# ---------------- answers ----------------

# FN hovercard_reply(ext, id, ok, body, len) -> eax 1 when it answered one of the card's requests
FN hovercard_reply
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
    xor ecx, ecx
1:  cmp rcx, [rip + hc_reqs + VEC_len]
    jae 8f
    imul rax, rcx, HCR_SIZE
    add rax, [rip + hc_reqs + VEC_ptr]
    inc rcx
    cmp [rax + HCR_ext], rbx
    jne 1b
    cmp [rax + HCR_id], r12
    jne 1b
    # its record goes (the last takes its place)
    mov rdx, [rip + hc_reqs + VEC_len]
    dec rdx
    mov [rip + hc_reqs + VEC_len], rdx
    imul rdx, rdx, HCR_SIZE
    add rdx, [rip + hc_reqs + VEC_ptr]
    mov rsi, [rdx]
    mov [rax], rsi
    mov rsi, [rdx + 8]
    mov [rax + 8], rsi
    test r13d, r13d
    jz 7f
    test r15, r15
    jz 7f                       # nothing to say
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call take_answer
    test eax, eax
    jnz 7f
    mov rdi, rbx
    mov esi, PK_HOVER
    call query_dropped
7:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# take_answer(ext, body, len) -> eax 1 when "L1 C1 L2 C2" LF + text was taken (an empty text too),
# 0 when it breaks the rules
take_answer:
    PROLOGUE 16
    mov rbx, rdi
    mov [rip + ps_ptr], rsi
    lea rax, [rsi + rdx]
    mov [rip + ps_end], rax
    call ps_line
    test eax, eax
    jz 8f
    call lf_four
    test eax, eax
    jz 8f
    call ps_eol
    test eax, eax
    jz 8f
    mov r12, [rip + ps_ptr]
    mov r13, [rip + ps_end]
    sub r13, r12                # the text
    cmp r13, HC_TEXT_MAX
    ja 8f
    # the range, when it is one in the text as asked
    lea rax, [rip + lf_tmp4]
    mov ecx, [rax]
    or ecx, [rax + 4]
    or ecx, [rax + 8]
    or ecx, [rax + 12]
    jz 3f
    mov rdi, [rip + hc_doc]
    mov esi, [rax]
    mov edx, [rax + 4]
    call lf_pos
    test rax, rax
    js 3f
    mov r14, rax
    lea rax, [rip + lf_tmp4]
    mov rdi, [rip + hc_doc]
    mov esi, [rax + 8]
    mov edx, [rax + 12]
    call lf_pos
    test rax, rax
    js 3f
    cmp rax, r14
    jb 3f
    mov rcx, [rip + hc_rs]
    cmp rcx, [rip + hc_re]
    jne 2f
    mov [rip + hc_rs], r14      # the first range
    mov [rip + hc_re], rax
    jmp 3f
2:  cmp r14, [rip + hc_rs]
    jae 21f
    mov [rip + hc_rs], r14
21: cmp rax, [rip + hc_re]
    jbe 3f
    mov [rip + hc_re], rax
3:  # the text, normalized, unless the same text came already or all of them are too many
    mov rdi, r12
    mov rsi, r13
    call normalize
    mov r13, [rip + hc_buf + SB_len]
    test r13, r13
    jz 9f
    mov rax, [rip + hc_bytes]
    add rax, r13
    cmp rax, HC_ALL_MAX
    ja 9f
    mov rdi, rbx
    call rank_of
    mov [rsp], rax
    xor r14d, r14d
4:  cmp r14, [rip + hc_secs + VEC_len]
    jae 5f
    imul r15, r14, HCX_SIZE
    add r15, [rip + hc_secs + VEC_ptr]
    inc r14
    cmp [r15 + HCX_len], r13
    jne 4b
    mov rdi, [r15 + HCX_text]
    mov rsi, [rip + hc_buf + SB_ptr]
    mov rdx, r13
    call mem_eq
    test eax, eax
    jz 4b
    # identical: once, from the better ranked provider
    mov rax, [rsp]
    cmp rax, [r15 + HCX_rank]
    jae 9f
    mov rdi, [r15 + HCX_text]
    call mem_free
    mov rax, [r15 + HCX_len]
    sub [rip + hc_bytes], rax
    mov rdi, r15
    lea rsi, [r15 + HCX_SIZE]
    mov rdx, [rip + hc_secs + VEC_len]
    sub rdx, r14
    imul rdx, rdx, HCX_SIZE
    call memmove
    dec qword ptr [rip + hc_secs + VEC_len]
5:  add [rip + hc_bytes], r13
    mov rdi, r13
    call mem_alloc
    mov r12, rax
    mov rdi, rax
    mov rsi, [rip + hc_buf + SB_ptr]
    mov rdx, r13
    call memcpy
    # its place: by rank
    mov r14, [rsp]
    lea rdi, [rip + hc_secs]
    mov esi, HCX_SIZE
    call vec_push
    mov r15, [rip + hc_secs + VEC_len]
    dec r15                     # moved down past higher ranks
6:  test r15, r15
    jz 7f
    imul rax, r15, HCX_SIZE
    add rax, [rip + hc_secs + VEC_ptr]
    cmp [rax - HCX_SIZE + HCX_rank], r14
    jbe 7f
    mov rcx, [rax - HCX_SIZE]
    mov [rax], rcx
    mov rcx, [rax - HCX_SIZE + 8]
    mov [rax + 8], rcx
    mov rcx, [rax - HCX_SIZE + 16]
    mov [rax + 16], rcx
    mov rcx, [rax - HCX_SIZE + 24]
    mov [rax + 24], rcx
    dec r15
    jmp 6b
7:  imul rax, r15, HCX_SIZE
    add rax, [rip + hc_secs + VEC_ptr]
    mov [rax + HCX_ext], rbx
    mov [rax + HCX_rank], r14
    mov [rax + HCX_text], r12
    mov [rax + HCX_len], r13
    inc qword ptr [rip + hc_gen]
9:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# rank_of(ext) -> rax its rank, lower first: how exact its hover patterns are (a file name, then
# *.ext, then the rest), then owner/name (by its first 7 bytes)
rank_of:
    PROLOGUE
    mov rbx, rdi
    mov esi, EXT_pv_hover
    call ext_pv
    mov r12d, 2
    test rax, rax
    jz 5f
    mov rcx, rax                # each word: no wildcard 0, "*." 1
1:  movzx edx, byte ptr [rcx]
    test edx, edx
    jz 5f
    cmp edx, ' '
    jne 2f
    inc rcx
    jmp 1b
2:  xor r8d, r8d                # a wildcard in the word
    mov r9, rcx
3:  movzx edx, byte ptr [rcx]
    test edx, edx
    jz 4f
    cmp edx, ' '
    je 4f
    cmp edx, '*'
    je 31f
    cmp edx, '?'
    jne 32f
31: mov r8d, 1
32: inc rcx
    jmp 3b
4:  test r8d, r8d
    jnz 41f
    xor r12d, r12d
    jmp 1b
41: cmp byte ptr [r9], '*'
    jne 1b
    cmp byte ptr [r9 + 1], '.'
    jne 1b
    cmp r12d, 1
    jbe 1b
    mov r12d, 1
    jmp 1b
5:  mov rdi, rbx
    call ext_full_name
    xor r13d, r13d              # the name's first 7 bytes in the low 56 bits
    xor ecx, ecx
6:  cmp ecx, 7
    jae 7f
    shl r13, 8
    movzx edx, byte ptr [rax]
    test edx, edx
    jz 61f
    inc rax
61: or r13, rdx
    inc ecx
    jmp 6b
7:  shl r12, 56                 # the patterns' exactness above them
    or r13, r12
    mov rax, r13
    EPILOGUE

# mem_eq(a, b, n) -> eax 1 when the n bytes are equal
mem_eq:
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 2f
    movzx eax, byte ptr [rdi + rcx]
    cmp al, [rsi + rcx]
    jne 3f
    inc rcx
    jmp 1b
2:  mov eax, 1
    ret
3:  xor eax, eax
    ret

# normalize(ptr, len): hc_buf = the text with tabs as four spaces, CRs and other controls gone or
# spaces, and no blank lines at its end
normalize:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + hc_buf]
    call sb_clear
    xor r13d, r13d
1:  cmp r13, r12
    jae 3f
    movzx esi, byte ptr [rbx + r13]
    inc r13
    cmp esi, 13
    je 1b
    cmp esi, 9
    jne 11f
    lea rdi, [rip + hc_buf]
    lea rsi, [rip + .Lfour]
    mov edx, 4
    call sb_push
    jmp 1b
11: cmp esi, 10
    je 2f
    cmp esi, ' '
    jae 2f
    mov esi, ' '
2:  lea rdi, [rip + hc_buf]
    call sb_push_byte
    jmp 1b
3:  mov rax, [rip + hc_buf + SB_len]
    test rax, rax
    jz 9f
    mov rcx, [rip + hc_buf + SB_ptr]
    movzx edx, byte ptr [rcx + rax - 1]
    cmp edx, 10
    je 4f
    cmp edx, ' '
    jne 9f
4:  dec qword ptr [rip + hc_buf + SB_len]
    jmp 3b
9:  EPILOGUE

# ---------------- the tick ----------------

# FN hovercard_tick(): the pointer's rest asks; a query whose answers are in (or whose time is up)
# shows; a card whose document changed goes
FN hovercard_tick
    PROLOGUE
    cmp dword ptr [rip + hc_state], 0
    je 1f
    mov rdi, [rip + hc_docid]
    call extproto_doc
    cmp rax, [rip + hc_doc]
    jne 0f
    mov rcx, [rax + DOC_version]
    cmp rcx, [rip + hc_version]
    jne 0f
    cmp dword ptr [rip + hc_kind], 0
    je 1f
    cmp rax, [rip + g_doc]      # an invoked card belongs to the editor's document
    je 1f
0:  call close
1:  # the pointer came to rest somewhere new
    mov rbx, [rip + g_hover_doc]
    test rbx, rbx
    jz 3f
    mov r12, [rip + g_hover_pos]
    cmp rbx, [rip + hc_asked_doc]
    jne 2f
    cmp r12, [rip + hc_asked_pos]
    jne 2f
    mov rax, [rip + g_hover_since]
    cmp rax, [rip + hc_asked_since]
    je 3f
2:  call time_ms
    sub rax, [rip + g_hover_since]
    cmp rax, HOVER_REST_MS
    jl 3f
    mov [rip + hc_asked_doc], rbx
    mov [rip + hc_asked_pos], r12
    mov rax, [rip + g_hover_since]
    mov [rip + hc_asked_since], rax
    cmp dword ptr [rip + hc_state], 2
    jne 21f
    cmp dword ptr [rip + hc_kind], 0
    jne 21f
    mov rdi, rbx                # still on the shown card's range: it stays
    mov rsi, r12
    call on_range
    test eax, eax
    jnz 3f
21: mov rdi, rbx
    call any_asks
    test eax, eax
    jz 3f
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call start
3:  cmp dword ptr [rip + hc_state], 1
    jne 4f
    call settle
4:  mov rax, [rip + hc_leave]   # the pointer left a pointer card: gone after the grace
    test rax, rax
    jz 9f
    call time_ms
    sub rax, [rip + hc_leave]
    cmp rax, HC_GRACE
    jl 9f
    call close
9:  EPILOGUE

# settle(): an asking card shows when every provider answered (with something to show), or at 1 s
# with what came; with nothing it goes (an invoked card says so)
settle:
    PROLOGUE
    cmp qword ptr [rip + hc_reqs + VEC_len], 0
    je 2f
    cmp qword ptr [rip + hc_secs + VEC_len], 0
    je 9f
    call time_ms
    sub rax, [rip + hc_start]
    cmp rax, HC_SHOW
    jl 9f
    jmp 5f
2:  cmp qword ptr [rip + hc_secs + VEC_len], 0
    jne 5f
    cmp dword ptr [rip + hc_kind], 0
    je 4f                       # a pointer card needs a provider's text (else the tooltip shows)
    call collect                # an invoked one shows diagnostics and tips alone too
    cmp qword ptr [rip + hc_nparts], 0
    jne 5f
    call close
    lea rdi, [rip + .Lnothing]
    call app_toast
    jmp 9f
4:  call close
    jmp 9f
5:  mov dword ptr [rip + hc_state], 2
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# on_range(doc, pos) -> eax 1 when the position is on the card's answered range (its own position
# when the answers named none)
on_range:
    xor eax, eax
    cmp rdi, [rip + hc_doc]
    jne 9f
    mov rcx, [rip + hc_rs]
    cmp rcx, [rip + hc_re]
    jne 1f
    cmp rsi, [rip + hc_pos]
    sete al
    ret
1:  cmp rsi, rcx
    jb 9f
    cmp rsi, [rip + hc_re]
    jae 9f
    mov eax, 1
9:  ret

# FN hovercard_timeout() -> ms until the card wants a tick, or -1
FN hovercard_timeout
    PROLOGUE
    mov rbx, -1
    cmp dword ptr [rip + hc_state], 1
    jne 1f
    call time_ms
    mov rcx, [rip + hc_start]
    add rcx, HC_SHOW
    sub rcx, rax
    js 1f                       # past it: answers (or their expiry) wake the loop, not this
    mov rbx, rcx
1:  mov rax, [rip + hc_leave]
    test rax, rax
    jz 2f
    call time_ms
    mov rcx, [rip + hc_leave]
    add rcx, HC_GRACE
    sub rcx, rax
    jns 12f
    xor ecx, ecx
12: cmp rbx, -1
    je 13f
    cmp rcx, rbx
    jae 2f
13: mov rbx, rcx
2:  # a rest position not looked at yet, on a document a provider serves
    mov r12, [rip + g_hover_doc]
    test r12, r12
    jz 9f
    cmp r12, [rip + hc_asked_doc]
    jne 3f
    mov rax, [rip + g_hover_pos]
    cmp rax, [rip + hc_asked_pos]
    jne 3f
    mov rax, [rip + g_hover_since]
    cmp rax, [rip + hc_asked_since]
    je 9f
3:  mov rdi, r12
    call any_asks
    test eax, eax
    jz 9f
    call time_ms
    mov rcx, [rip + g_hover_since]
    add rcx, HOVER_REST_MS
    sub rcx, rax
    jns 31f
    xor ecx, ecx
31: cmp rbx, -1
    je 32f
    cmp rcx, rbx
    jae 9f
32: mov rbx, rcx
9:  mov eax, ebx
    EPILOGUE

# FN hovercard_covers() -> eax 1 while a pointer card asks or shows (the tooltip stays away)
FN hovercard_covers
    xor eax, eax
    cmp dword ptr [rip + hc_state], 0
    je 1f
    cmp dword ptr [rip + hc_kind], 0
    jne 1f
    mov eax, 1
1:  ret

# FN hovercard_ext_gone(ext): its requests are not waited for, its sections go
FN hovercard_ext_gone
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + hc_reqs + VEC_len]
    jae 3f
    imul rax, r12, HCR_SIZE
    add rax, [rip + hc_reqs + VEC_ptr]
    cmp [rax + HCR_ext], rbx
    je 2f
    inc r12
    jmp 1b
2:  mov rdx, [rip + hc_reqs + VEC_len]
    dec rdx
    mov [rip + hc_reqs + VEC_len], rdx
    imul rdx, rdx, HCR_SIZE
    add rdx, [rip + hc_reqs + VEC_ptr]
    mov rcx, [rdx]
    mov [rax], rcx
    mov rcx, [rdx + 8]
    mov [rax + 8], rcx
    jmp 1b
3:  xor r12d, r12d
4:  cmp r12, [rip + hc_secs + VEC_len]
    jae 9f
    imul r13, r12, HCX_SIZE
    add r13, [rip + hc_secs + VEC_ptr]
    cmp [r13 + HCX_ext], rbx
    je 5f
    inc r12
    jmp 4b
5:  mov rdi, [r13 + HCX_text]
    call mem_free
    mov rax, [r13 + HCX_len]
    sub [rip + hc_bytes], rax
    mov rdi, r13                # the ones after move up
    lea rsi, [r13 + HCX_SIZE]
    mov rdx, [rip + hc_secs + VEC_len]
    sub rdx, r12
    dec rdx
    imul rdx, rdx, HCX_SIZE
    call memmove
    dec qword ptr [rip + hc_secs + VEC_len]
    inc qword ptr [rip + hc_gen]
    jmp 4b
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ---------------- the layout ----------------

# part(offset, len, color, kind): one text of the layout, in hc_dbuf
part:
    mov rax, [rip + hc_nparts]
    cmp rax, HC_DIAGS + 4
    jae 1f
    shl rax, 5
    lea r8, [rip + hc_parts]
    mov [r8 + rax], rdi
    mov [r8 + rax + 8], rsi
    mov [r8 + rax + 16], rdx
    mov [r8 + rax + 24], rcx
    inc qword ptr [rip + hc_nparts]
1:  ret

# dbuf_add(cstr or 0, prefix cstr or 0) -> rax offset, rdx length of the copy (0 for none)
dbuf_add:
    PROLOGUE
    mov rbx, rdi
    mov r13, rsi
    mov r12, [rip + hc_dbuf + SB_len]
    test rbx, rbx
    jz 8f
    cmp byte ptr [rbx], 0
    je 8f
    test r13, r13
    jz 1f
    lea rdi, [rip + hc_dbuf]
    mov rsi, r13
    call sb_push_cstr
1:  mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call normalize
    lea rdi, [rip + hc_dbuf]
    mov rsi, [rip + hc_buf + SB_ptr]
    mov rdx, [rip + hc_buf + SB_len]
    call sb_push
    mov rax, r12
    mov rdx, [rip + hc_dbuf + SB_len]
    sub rdx, r12
    EPILOGUE
8:  mov rax, r12
    xor edx, edx
    EPILOGUE

# collect(): the layout's texts in order: the diagnostics at the position, the providers' texts, a
# decoration's tip, the v1 answer (for the pointer's position)
collect:
    PROLOGUE
    mov qword ptr [rip + hc_nparts], 0
    lea rdi, [rip + hc_dbuf]
    call sb_clear
    mov rdi, [rip + hc_docid]
    call extproto_doc
    cmp rax, [rip + hc_doc]
    jne 9f
    mov rbx, rax
    xor r12d, r12d
1:  cmp r12, HC_DIAGS
    jae 2f
    mov rdi, rbx
    mov rsi, [rip + hc_pos]
    mov rdx, r12
    call extmarks_nth_at
    test rax, rax
    jz 2f
    inc r12
    mov r13, rax
    mov eax, [r13 + MK_sev]
    and eax, 3
    lea rcx, [rip + sev_words]
    mov rsi, [rcx + rax*8]
    mov rdi, [r13 + MK_msg]
    call dbuf_add
    test rdx, rdx
    jz 1b
    mov rdi, rax
    mov rsi, rdx
    mov eax, [r13 + MK_sev]
    and eax, 3
    lea rcx, [rip + sev_colors]
    mov edx, [rcx + rax*4]
    mov ecx, HCS_DIAG
    call part
    jmp 1b
2:  # the providers' texts are in hc_secs (marked by kind HCS_EXT with offset -1 - index)
    xor r12d, r12d
3:  cmp r12, [rip + hc_secs + VEC_len]
    jae 4f
    mov rdi, r12
    not rdi                     # -1 - index: a section, not hc_dbuf
    xor esi, esi
    mov edx, T_FG
    mov ecx, HCS_EXT
    call part
    inc r12
    jmp 3b
4:  mov rdi, rbx
    mov rsi, [rip + hc_pos]
    call deco_tip_at
    mov rdi, rax
    xor esi, esi
    call dbuf_add
    test rdx, rdx
    jz 5f
    mov rdi, rax
    mov rsi, rdx
    mov edx, T_FG
    mov ecx, HCS_DECO
    call part
5:  cmp dword ptr [rip + hc_kind], 0
    jne 9f
    cmp rbx, [rip + g_hover_doc]
    jne 9f
    mov rax, [rip + g_hover_pos]
    cmp rax, [rip + hc_pos]
    jne 9f
    lea rdi, [rip + g_hover_text]
    xor esi, esi
    call dbuf_add
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    mov edx, T_FG
    mov ecx, HCS_V1
    call part
9:  EPILOGUE

# part_text(i) -> rax ptr, rdx len, ecx color of part i
part_text:
    mov rax, rdi
    shl rax, 5
    lea r8, [rip + hc_parts]
    add r8, rax
    mov ecx, [r8 + 16]
    mov rax, [r8]
    test rax, rax
    js 1f
    add rax, [rip + hc_dbuf + SB_ptr]
    mov rdx, [r8 + 8]
    ret
1:  not rax
    imul rax, rax, HCX_SIZE
    add rax, [rip + hc_secs + VEC_ptr]
    mov rdx, [rax + HCX_len]
    mov rax, [rax + HCX_text]
    ret

# compose(): hc_new = the card's Markdown from the parts, separated by rules: a diagnostic as
# "**error:** message", a provider's text as it is when it agreed markdown, other texts escaped
# (their line breaks kept, leading spaces as no-break spaces)
compose:
    PROLOGUE 16
    call collect
    lea rdi, [rip + hc_new]
    call sb_clear
    xor ebx, ebx
1:  cmp rbx, [rip + hc_nparts]
    jae 9f
    test rbx, rbx
    jz 2f
    lea rdi, [rip + hc_new]
    lea rsi, [rip + .Lrule]
    call sb_push_cstr
2:  mov rax, rbx
    shl rax, 5
    lea rcx, [rip + hc_parts]
    mov r14, [rcx + rax + 24]   # its kind
    mov r15, [rcx + rax]        # its offset (a section: -1 - index)
    mov rdi, rbx
    call part_text
    mov r12, rax
    mov r13, rdx
    cmp r14, HCS_DIAG
    jne 3f
    xor ecx, ecx                # "word: " bold
4:  cmp rcx, r13
    jae 5f
    cmp rcx, 12
    jae 5f
    cmp byte ptr [r12 + rcx], ':'
    je 41f
    inc rcx
    jmp 4b
41: inc rcx
    mov [rsp], rcx
    lea rdi, [rip + hc_new]
    lea rsi, [rip + .Lstrong]
    call sb_push_cstr
    lea rdi, [rip + hc_new]
    mov rsi, r12
    mov rdx, [rsp]
    call push_plain
    lea rdi, [rip + hc_new]
    lea rsi, [rip + .Lstrong]
    call sb_push_cstr
    mov rcx, [rsp]
    add r12, rcx
    sub r13, rcx
    jmp 5f
3:  cmp r14, HCS_EXT
    jne 5f
    mov rax, r15
    not rax
    imul rax, rax, HCX_SIZE
    add rax, [rip + hc_secs + VEC_ptr]
    mov rdi, [rax + HCX_ext]
    mov esi, FEAT_MARKDOWN
    call ext_feature
    test eax, eax
    jz 5f
    lea rdi, [rip + hc_new]     # Markdown as it came
    mov rsi, r12
    mov rdx, r13
    call sb_push
    jmp 6f
5:  lea rdi, [rip + hc_new]
    mov rsi, r12
    mov rdx, r13
    call push_plain
6:  inc rbx
    jmp 1b
9:  EPILOGUE

# push_plain(sb, ptr, len): text as Markdown that shows it as it is: punctuation escaped, a line
# break kept (a hard break inside a paragraph), leading spaces as no-break spaces
push_plain:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rsi + rdx]
    mov r14d, 1                 # at a line's start
1:  cmp r12, r13
    jae 9f
    movzx r15d, byte ptr [r12]
    inc r12
    cmp r15d, 10
    jne 3f
    test r14d, r14d             # a line with text, followed by one: a hard break
    jnz 2f
    cmp r12, r13
    jae 2f
    cmp byte ptr [r12], 10
    je 2f
    mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
2:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov r14d, 1
    jmp 1b
3:  test r14d, r14d
    jz 4f
    cmp r15d, ' '
    jne 4f
    mov rdi, rbx
    lea rsi, [rip + .Lnbsp]
    call sb_push_cstr
    jmp 1b
4:  xor r14d, r14d
    lea rdi, [rip + .Lescaped]
    mov esi, r15d
    call strchr_byte
    test eax, eax
    jz 5f
    mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
5:  mov rdi, rbx
    mov esi, r15d
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# strchr_byte(cstr, byte) -> eax 1 when the byte is in the cstr
strchr_byte:
1:  movzx eax, byte ptr [rdi]
    test eax, eax
    jz 8f
    cmp eax, esi
    je 2f
    inc rdi
    jmp 1b
2:  mov eax, 1
    ret
8:  xor eax, eax
    ret

# build() -> eax 1 with hc_md the card's document (parsed again only when its Markdown changed),
# 0 when there is nothing to show
build:
    PROLOGUE
    call compose
    cmp qword ptr [rip + hc_nparts], 0
    je 8f
    mov rdi, [rip + hc_md]
    test rdi, rdi
    jz 1f
    mov rdx, [rip + hc_new + SB_len]
    cmp rdx, [rip + hc_src + SB_len]
    jne 1f
    mov rdi, [rip + hc_new + SB_ptr]
    mov rsi, [rip + hc_src + SB_ptr]
    call mem_eq
    test eax, eax
    jnz 7f
1:  lea rdi, [rip + hc_src]
    call sb_clear
    lea rdi, [rip + hc_src]
    mov rsi, [rip + hc_new + SB_ptr]
    mov rdx, [rip + hc_new + SB_len]
    call sb_push
    mov rdi, [rip + hc_md]
    test rdi, rdi
    jz 2f
    call md_free
2:  mov rdi, [rip + hc_src + SB_ptr]
    mov rsi, [rip + hc_src + SB_len]
    call md_new
    mov [rip + hc_md], rax
    mov rdi, rax
    call md_set_flat
    mov dword ptr [rip + hc_mmax], 0    # a new document: measure it again
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- drawing and input ----------------

# FN hovercard_blocks_editor() -> eax 1 while the pointer is over the card
FN hovercard_blocks_editor
    xor eax, eax
    cmp dword ptr [rip + hc_state], 2
    jne 1f
    mov edi, [rip + hc_rect]
    mov esi, [rip + hc_rect + 4]
    mov edx, [rip + hc_rect + 8]
    mov ecx, [rip + hc_rect + 12]
    jmp ui_in
1:  ret

# FN hovercard_draw(): the card, on top of the editor (after the completion list's turn): its
# Markdown laid out at most 80 columns or 60% of the window wide and half the window high; dragging
# selects text, a link opens (http(s) in the browser, rhun:// and files in rhun)
FN hovercard_draw
    PROLOGUE 48
    cmp dword ptr [rip + hc_state], 2
    jne .Lhd_ret
    cmp dword ptr [rip + cp_open], 0
    je 0f
    call close                  # the completion list hides it
    jmp .Lhd_ret
0:  cmp dword ptr [rip + hc_kind], 0
    je 91f
    call anchor                 # an invoked card follows the caret (it may have moved there)
91: call build                  # (a pointer card's v1 answer may come any time)
    test eax, eax
    jz .Lhd_close
    # the size: the text's widest line, at most half the window high
    M ecx, MI_8
    mov eax, [rip + g_cv + CV_w]
    imul eax, eax, 60
    xor edx, edx
    mov r8d, 100
    div r8d
    mov edx, [rip + g_cw]
    imul edx, edx, HC_COLS
    cmp eax, edx
    jbe 1f
    mov eax, edx
1:  sub eax, ecx
    sub eax, ecx
    cmp eax, 80
    jge 11f
    mov eax, 80
11: mov [rsp + 40], eax         # the most it may take
    # measuring lays the text out at the most, which drops a selection: measure once per
    # document, size and faces, so the layout below keeps its width from frame to frame
    cmp [rip + hc_mmax], eax
    jne 13f
    mov ecx, [rip + g_face_gen]
    cmp ecx, [rip + hc_mgen]
    jne 13f
    mov eax, [rip + hc_mw]
    jmp 12f
13: mov [rip + hc_mmax], eax
    mov ecx, [rip + g_face_gen]
    mov [rip + hc_mgen], ecx
    mov rdi, [rip + hc_md]
    mov esi, eax
    call md_measure
    add eax, [rip + g_mt + 4*MI_4]   # a little room: laid out at its own widest line, a line's
    mov [rip + hc_cw], eax           # last word could wrap
    cmp eax, [rsp + 40]
    jbe 14f
    mov eax, [rsp + 40]
14: mov [rip + hc_mw], eax
12: mov [rsp + 20], eax         # the text's width
    mov [rip + hc_tw], eax
    mov rdi, [rip + hc_md]
    mov esi, eax
    call md_layout
    mov [rip + hc_th], eax
    M ecx, MI_8
    mov edx, [rip + g_cv + CV_h]
    shr edx, 1
    sub edx, ecx
    sub edx, ecx
    cmp eax, edx
    jbe 2f
    mov eax, edx
2:  test eax, eax
    jg 21f
    mov eax, 1
21: mov [rsp + 24], eax         # the text's height shown
    mov eax, [rsp + 20]
    lea eax, [rax + rcx*2]
    mov [rsp + 8], eax          # w
    mov eax, [rsp + 24]
    lea eax, [rax + rcx*2]
    mov [rsp + 12], eax         # h
    xor edi, edi                # the scroll within the text
    call scroll_px
    xor edi, edi
    call hscroll_px
    # the place: under the word, above it without room, inside the window
    mov eax, [rip + hc_ax]
    mov ecx, [rip + g_cv + CV_w]
    sub ecx, [rsp + 8]
    cmp eax, ecx
    jle 4f
    mov eax, ecx
4:  test eax, eax
    jns 41f
    xor eax, eax
41: mov [rsp], eax
    mov eax, [rip + hc_ay]
    mov ecx, eax
    add ecx, [rsp + 12]
    mov edx, [rip + g_cv + CV_h]
    sub edx, [rip + g_mt + 4*MI_STATUS]
    cmp ecx, edx
    jle 5f
    mov ecx, [rip + hc_ay0]
    sub ecx, [rsp + 12]
    js 5f
    mov eax, ecx
5:  mov [rsp + 4], eax
    lea rax, [rip + hc_rect]
    mov ecx, [rsp]
    mov [rax], ecx
    mov ecx, [rsp + 4]
    mov [rax + 4], ecx
    mov ecx, [rsp + 8]
    mov [rax + 8], ecx
    mov ecx, [rsp + 12]
    mov [rax + 12], ecx
    # a pointer card stays while the pointer is on it or on its range, and 400 ms after
    cmp dword ptr [rip + hc_kind], 0
    jne 6f
    call pointer_in
    test eax, eax
    jz 51f
    mov qword ptr [rip + hc_leave], 0
    jmp 6f
51: cmp qword ptr [rip + hc_leave], 0
    jne 52f
    call time_ms
    mov [rip + hc_leave], rax
    jmp 6f
52: call time_ms
    sub rax, [rip + hc_leave]
    cmp rax, HC_GRACE
    jge .Lhd_close
6:  # the wheel over it scrolls
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call ui_in
    test eax, eax
    jz 7f
    call wheel_xy               # (sideways with Shift, or a sideways wheel: a long code line)
    push rax
    push rax
    mov edi, edx
    test edi, edi
    jz 61f
    call scroll_px
61: pop rdi
    pop rax
    test edi, edi
    jz 7f
    call hscroll_px
7:  # the frame
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    cmp dword ptr [rip + hc_focus], 0
    je 71f
    COLOR r9d, T_ACCENT
71: COLOR eax, T_POPUP
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    M ecx, MI_8
    mov eax, [rsp]
    add eax, ecx
    mov [rsp + 28], eax         # the text's x, y
    mov eax, [rsp + 4]
    add eax, ecx
    mov [rsp + 32], eax
    # dragging over the text selects it
    mov edi, ID_HC_AREA
    mov esi, [rsp + 28]
    mov edx, [rsp + 32]
    mov ecx, [rsp + 20]
    mov r8d, [rsp + 24]
    call ui_btn
    mov r8d, eax
    mov rdi, [rip + hc_md]
    mov esi, [rsp + 28]
    sub esi, [rip + hc_hscroll]
    mov edx, [rsp + 32]
    mov ecx, [rip + hc_scroll]
    call md_select_mouse
    mov edi, [rsp + 28]
    mov esi, [rsp + 32]
    mov edx, [rsp + 20]
    mov ecx, [rsp + 24]
    call gfx_clip_push
    mov eax, ID_HC_LINKS
    push rax
    push rax
    mov rdi, [rip + hc_md]      # moved left by the sideways scroll (the clip keeps the card)
    mov esi, [rsp + 16 + 28]
    sub esi, [rip + hc_hscroll]
    mov edx, [rsp + 16 + 32]
    mov ecx, [rsp + 16 + 20]
    add ecx, [rip + hc_hscroll]
    mov r8d, [rsp + 16 + 24]
    mov r9d, [rip + hc_scroll]
    call md_draw
    add rsp, 16
    mov [rsp + 36], eax
    call gfx_clip_pop
    mov esi, [rsp + 36]
    test esi, esi
    js .Lhd_ret
    mov rdi, [rip + hc_md]      # a link: rhun follows it (others are left alone in a card)
    call md_open_link
    jmp .Lhd_ret
.Lhd_close:
    call close
.Lhd_ret:
    EPILOGUE

# pointer_in() -> eax 1 when the pointer is over the card or rests on its range
pointer_in:
    mov edi, [rip + hc_rect]
    mov esi, [rip + hc_rect + 4]
    mov edx, [rip + hc_rect + 8]
    mov ecx, [rip + hc_rect + 12]
    push rbx
    call ui_in
    pop rbx
    test eax, eax
    jnz 1f
    mov rdi, [rip + g_hover_doc]
    mov rsi, [rip + g_hover_pos]
    jmp on_range
1:  ret

# scroll_px(n): the card's text moves by n pixels, within it (0: kept within after a new layout)
scroll_px:
    mov eax, [rip + hc_scroll]
    add eax, edi
    mov ecx, [rip + hc_th]      # at most its height less what shows (half the window, its padding)
    mov edx, [rip + g_cv + CV_h]
    shr edx, 1
    sub edx, [rip + g_mt + 4*MI_8]
    sub edx, [rip + g_mt + 4*MI_8]
    sub ecx, edx
    cmp eax, ecx
    jle 1f
    mov eax, ecx
1:  test eax, eax
    jns 2f
    xor eax, eax
2:  cmp eax, [rip + hc_scroll]
    je 3f
    mov [rip + hc_scroll], eax
    mov dword ptr [rip + g_dirty], 1
3:  ret

# hscroll_px(n): the card's text moves sideways by n pixels, within its widest line
hscroll_px:
    mov eax, [rip + hc_hscroll]
    add eax, edi
    mov ecx, [rip + hc_cw]
    sub ecx, [rip + hc_tw]
    cmp eax, ecx
    jle 1f
    mov eax, ecx
1:  test eax, eax
    jns 2f
    xor eax, eax
2:  cmp eax, [rip + hc_hscroll]
    je 3f
    mov [rip + hc_hscroll], eax
    mov dword ptr [rip + g_dirty], 1
3:  ret

# FN hovercard_key(keysym, cp, mods) -> eax 1 when the card took the key (the editor's keyboard):
# a focused card scrolls with the arrows and pages and closes with Escape; otherwise Escape closes
# it and any other key (but ctrl+i, which focuses it) closes it and goes on
FN hovercard_key
    cmp dword ptr [rip + hc_state], 0
    jne 1f
    xor eax, eax
    ret
1:  PROLOGUE
    mov r12d, edi
    mov r13d, edx
    cmp r12d, 0xffe1            # modifiers alone
    jb 2f
    cmp r12d, 0xffee
    jbe 8f
2:  cmp r12d, KEY_ESCAPE
    jne 3f
    call close
    jmp 7f
3:  cmp dword ptr [rip + hc_focus], 0
    je 5f
    test r13d, MOD_CTRL
    jz 31f
    cmp r12d, 'c'               # ctrl+c: the selected text to the clipboard
    jne 32f
    call copy_selection
    jmp 7f
32: cmp r12d, 'a'               # ctrl+a: all of it selected
    jne 31f
    mov rdi, [rip + hc_md]
    test rdi, rdi
    jz 7f
    call md_select_all
    jmp 7f
31: mov edi, [rip + g_lh]
    cmp r12d, KEY_DOWN
    je 4f
    neg edi
    cmp r12d, KEY_UP
    je 4f
    mov edi, [rip + g_cv + CV_h]
    shr edi, 2
    cmp r12d, KEY_PAGEDOWN
    je 4f
    neg edi
    cmp r12d, KEY_PAGEUP
    je 4f
    mov edi, [rip + g_cw]       # Left/Right: sideways, four columns at a time
    shl edi, 2
    cmp r12d, KEY_RIGHT
    je 41f
    neg edi
    cmp r12d, KEY_LEFT
    je 41f
    jmp 6f
41: call hscroll_px
    jmp 7f
4:  call scroll_px
    jmp 7f
5:  cmp r12d, 'i'               # ctrl+i: Show Hover again focuses the card
    jne 6f
    test r13d, MOD_CTRL
    jnz 8f
6:  call close
8:  xor eax, eax
    EPILOGUE
7:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE

# sel_text(sb) -> eax 1 with the card's selected text pushed to sb, as copied: the no-break spaces
#   that keep plain text's indentation (push_plain) are ordinary spaces again
sel_text:
    push rbx
    mov rbx, rdi
    mov rsi, rdi
    mov rdi, [rip + hc_md]
    call md_sel_text
    test eax, eax
    jz 9f
    mov rdi, [rbx + SB_ptr]     # in place: C2 A0 -> ' '
    mov rcx, [rbx + SB_len]
    xor esi, esi                # read
    xor edx, edx                # write
1:  cmp rsi, rcx
    jae 3f
    movzx eax, byte ptr [rdi + rsi]
    inc rsi
    cmp eax, 0xc2
    jne 2f
    cmp rsi, rcx
    jae 2f
    cmp byte ptr [rdi + rsi], 0xa0
    jne 2f
    inc rsi
    mov eax, ' '
2:  mov [rdi + rdx], al
    inc rdx
    jmp 1b
3:  mov [rbx + SB_len], rdx
    mov eax, 1
9:  pop rbx
    ret

# copy_selection(): the card's selected text to the clipboard
copy_selection:
    PROLOGUE 32
    mov rdi, [rip + hc_md]
    test rdi, rdi
    jz 9f
    lea rdi, [rsp]
    xor esi, esi
    mov edx, SB_SIZE
    call memset
    lea rdi, [rsp]
    call sel_text
    test eax, eax
    jz 8f
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    xor edx, edx
    call ed_clip_set
8:  lea rdi, [rsp]
    call sb_free
9:  EPILOGUE

# FN hovercard_point(line, col): the pointer moves over that place of the editor's text (hover-at;
# columns as bytes on a line without tabs); hovercard_xy(line, col) -> eax x, edx y of it
FN hovercard_point
    PROLOGUE
    call hovercard_xy
    test eax, eax
    js 9f
    mov edi, eax
    mov esi, edx
    call app_on_motion
9:  EPILOGUE

FN hovercard_xy
    PROLOGUE
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov r12, rdi
    mov r13, rsi
    mov rax, [rbx + DOC_scrolly]
    mov rcx, rax
    shr rax, 8                  # the first line shown
    and ecx, 255
    imul ecx, [rip + g_lh]
    shr ecx, 8
    lea rdx, [r12 - 1]
    sub rdx, rax
    imul edx, [rip + g_lh]
    add edx, [rip + g_ed_y]
    sub edx, ecx
    mov eax, [rip + g_lh]
    shr eax, 1
    add edx, eax
    mov r14d, edx               # y
    lea rax, [r13 - 1]
    imul eax, [rip + g_cw]
    add eax, [rip + g_ed_tx]
    sub eax, [rbx + DOC_scrollx]
    mov ecx, [rip + g_cw]
    shr ecx, 1
    add eax, ecx
    mov edx, r14d
    EPILOGUE
9:  mov eax, -1
    EPILOGUE

# FN hovercard_dump(sb): print-hover-card: "card=none", "card=asking ..." or "card=shown ..." and
# a line per text: "section diag|ext OWNER/NAME|deco|v1: TEXT" (line feeds as \n)
FN hovercard_dump
    PROLOGUE
    mov r12, rdi
    cmp dword ptr [rip + hc_state], 0
    jne 1f
    mov rdi, r12
    lea rsi, [rip + .Ld_none]
    call sb_push_cstr
    EPILOGUE
1:  mov rdi, r12
    lea rsi, [rip + .Ld_asking]
    cmp dword ptr [rip + hc_state], 1
    je 2f
    lea rsi, [rip + .Ld_shown]
2:  call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ld_pointer]
    cmp dword ptr [rip + hc_kind], 0
    je 3f
    lea rsi, [rip + .Ld_invoked]
3:  call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ld_line]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rip + hc_line]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_col]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rip + hc_col]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_focused]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rip + hc_focus]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_waiting]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rip + hc_reqs + VEC_len]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_range]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rip + hc_re]
    sub rsi, [rip + hc_rs]
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    mov eax, [rip + hc_cw]      # "sideways=N/MAX" while a line is wider than the card
    sub eax, [rip + hc_tw]
    jle 30f
    cmp dword ptr [rip + hc_state], 0
    je 30f
    mov [rsp], eax
    mov rdi, r12
    lea rsi, [rip + .Ld_sideways]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rip + hc_hscroll]
    call sb_push_u64
    mov rdi, r12
    mov esi, '/'
    call sb_push_byte
    mov rdi, r12
    mov esi, [rsp]
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
30: mov rdi, [rip + hc_md]      # the selected text, when there is one
    test rdi, rdi
    jz 31f
    lea rdi, [rip + hc_new]
    call sb_clear
    lea rdi, [rip + hc_new]
    call sel_text
    test eax, eax
    jz 31f
    mov rdi, r12
    lea rsi, [rip + .Ld_selected]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rip + hc_new + SB_ptr]
    mov rdx, [rip + hc_new + SB_len]
    call sb_push
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
31: call collect
    xor ebx, ebx
4:  cmp rbx, [rip + hc_nparts]
    jae 9f
    mov rax, rbx
    shl rax, 5
    lea rcx, [rip + hc_parts]
    mov r13, [rcx + rax + 24]   # its kind
    mov r14, [rcx + rax]
    lea rax, [rip + part_words]
    mov rsi, [rax + r13*8]
    mov rdi, r12
    call sb_push_cstr
    cmp r13, HCS_EXT
    jne 5f
    mov rax, r14
    not rax
    imul rax, rax, HCX_SIZE
    add rax, [rip + hc_secs + VEC_ptr]
    mov rdi, [rax + HCX_ext]
    call ext_full_name
    mov r15, rax
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rdi, r12
    mov rsi, r15
    call sb_push_cstr
5:  mov rdi, r12
    lea rsi, [rip + .Ld_colon]
    call sb_push_cstr
    mov rdi, rbx
    call part_text
    mov r13, rax
    lea r14, [rax + rdx]
6:  cmp r13, r14
    jae 7f
    movzx esi, byte ptr [r13]
    inc r13
    cmp esi, 10
    jne 61f
    mov rdi, r12
    mov esi, '\\'
    call sb_push_byte
    mov esi, 'n'
61: mov rdi, r12
    call sb_push_byte
    jmp 6b
7:  mov rdi, r12
    mov esi, 10
    call sb_push_byte
    inc rbx
    jmp 4b
9:  EPILOGUE

.section .rodata
.p2align 3
sev_words: .quad .Ls_error, .Ls_warning, .Ls_info, .Ls_hint
part_words: .quad 0, .Lp_ext, .Lp_diag, .Lp_deco, .Lp_v1
.p2align 2
sev_colors: .long T_ERROR, T_WARNING, T_ACCENT, T_MUTED
.Ls_error: .asciz "error: "
.Ls_warning: .asciz "warning: "
.Ls_info: .asciz "info: "
.Ls_hint: .asciz "hint: "
.Lp_ext: .asciz "section ext"
.Lp_diag: .asciz "section diag"
.Lp_deco: .asciz "section deco"
.Lp_v1: .asciz "section v1"
.Lv_hover: .asciz "hover-query "
.Lk_pointer: .asciz " pointer -"
.Lk_invoked: .asciz " invoked -"
.Lfour: .ascii "    "
.Lnothing: .asciz "No hover information here"
.Ld_none: .asciz "card=none\n"
.Ld_selected: .asciz "selected: "
.Ld_sideways: .asciz "sideways="
.Lrule: .asciz "\n\n---\n\n"
.Lstrong: .asciz "**"
.Lnbsp: .asciz "&nbsp;"
.Lescaped: .asciz "\\`*_{}[]<>()#+-.!|~&:"   # (: as well: no bare URL link)

.Ld_asking: .asciz "card=asking"
.Ld_shown: .asciz "card=shown"
.Ld_pointer: .asciz " kind=pointer"
.Ld_invoked: .asciz " kind=invoked"
.Ld_line: .asciz " line="
.Ld_col: .asciz " col="
.Ld_focused: .asciz " focused="
.Ld_waiting: .asciz " waiting="
.Ld_range: .asciz " range="
.Ld_colon: .asciz ": "
