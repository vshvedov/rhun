# A typed row's inline diff (AT_a to AT_b, ATF_DIFF) and a written file's coloured text (AT_b, ATF_PRE).
# Generic: nothing here names a driver, a tool or a record (the seam test reads this file).
#
# A record (AT_diff) is made once, when the row is first measured (so in view), from what the row keeps of
# its sides (a preview of 2 KiB or 12 lines from a file, up to 16 KiB from the stream): the sides' lines
# hashed and diffed (diff.s), the visual lines in order (removed, added or the same; at most AD_MAX kept, the
# counts of all), each with the grammar's state at its start (the grammar from the file's name, one tokenize
# pass a side over the lines kept). When a side was cut, what follows the last line both sides kept is not
# known (a "removed" line may only be past the other side's cut): it is not shown, and the block is cut. The
# record goes with its AT (agdiff_free) or when a side changes (agrow_set).
# Laid out per width and face: the block is as tall as its lines plus MI_20 and at most 10 x MI_20 of the
# panel (the extension's min(200, content + 20) px, ITt @5253190, scaled), then a fade and "Click to expand";
# a side longer than what is kept is cut whatever its height. Drawn for the rows in the clip only: a removed
# line's band T_GIT_DEL and an added one's T_GIT_ADD at diffview_line's strength, a "-" / "+" in the first
# cell, the text in the code face coloured T_SYN + class, wrapped at the block's width (a TAB four cells).
#
#   agdiff_h(AT*, w) -> eax                 its height at that width (0: none)
#   agdiff_est(AT*) -> eax                  an estimate without a record (agrow_est: no width part)
#   agdiff_draw(AT*, x, y, w, id) -> eax 1  clicked (the whole block is a button; id -1: none)
#   agdiff_free(AT*)                        its record goes (AT_diff)
#   agdiff_dump(sb, AT*, indent, content)   print-agent-rows' lines: "diff +A -B", then "- T", "+ T", "= T"
#                                           for the lines kept (content: as a row read from its file keeps
#                                           the sides, so stream and file give the same lines)
#   agdiff_lines(sb, AT*, x, y, w, fit)     print-agent-row's (fit 0): "diffbox X,Y,W,H lh= lines= cut=
#                                           built=", "diff N add|del|same X,Y,W syn=CLASS:BYTES,… T" a row
#                                           wholly in the block, "expand X,Y,W,H"; print-agent-rows-fit's
#                                           (fit 1): "  diff X,Y,W,H", "  expand X,Y,W,H"
.include "rhun.inc"

.equ AD_MAX, 64                 # visual lines a record keeps (more than any block shows at any size)
.equ ADK_SAME, 0                # a line's kind (DEL: AT_a's; the others: AT_b's)
.equ ADK_DEL, 1
.equ ADK_ADD, 2
.equ CLS_MAX, 4096              # a line's bytes coloured at most (the rest plain), as markdown.s
.equ TINT, 44                   # a band's strength (diffview_line's)
.equ ROW_CUT, 60                # a dumped row's text
.equ EXPAND_LEN, 15             # .Lexpand's bytes
.equ WK_MEASURE, 0              # the walker's modes
.equ WK_DRAW, 1
.equ WK_DUMP, 2
.equ AD_LBYTES, 1024            # ADL_SIZE x AD_MAX

# ADL: a visual line
STRUCT
F ADL_kind, 4
F ADL_state, 4                  # the grammar's state at its start
F ADL_off, 4                    # in its side's kept text
F ADL_len, 4
ENDSTRUCT ADL_SIZE

# AD: a row's record (mem_alloc'd, AT_diff)
STRUCT
F AD_flags, 4                   # ATF_DIFF or ATF_PRE: what it was made for
F AD_n, 4                       # visual lines kept
F AD_add, 4                     # the diff's counts, of all its lines
F AD_del, 4
F AD_more, 4                    # 1: more lines than kept, or a side longer than the row keeps: always cut
F AD_sign, 4                    # 1: a sign column (a diff)
F AD_gr, 8                      # the grammar, or 0
F AD_kfont, 8                   # the layout's key: the code face's font, px, line, cell, MI_20 and the width
F AD_kpx, 4
F AD_klh, 4
F AD_kcw, 4
F AD_kmi, 4
F AD_kw, 4
F AD_h, 4                       # the block's height for the key
F AD_cut, 4                     # cut there: a fade and "Click to expand"
F AD_pad, 4
F AD_lines, AD_LBYTES           # ADL
ENDSTRUCT AD_SIZE

.bss
.p2align 3
wk_at: .quad 0                  # the walker (ad_walk): the row, its record, the code face, the dump's sb
wk_ad: .quad 0
wk_face: .quad 0
wk_sb: .quad 0
wk_mode: .long 0
wk_x: .long 0                   # the text's left, the sign's, the block's left and width
wk_sx: .long 0
wk_bx: .long 0
wk_bw: .long 0
wk_y: .long 0                   # the first row's top
wk_tw: .long 0                  # the text's width
wk_lh: .long 0
wk_limit: .long 0               # content walked at most (px)
wk_bot: .long 0                 # dumped: the rows whose bottom is at most this
wk_cls: .long 0                 # 1: cls_buf holds the line's classes
wk_line: .long 0                # task 10: the line of the row row_draw draws (agsel_diff_row)
chip_x: .long 0                 # "Click to expand" (chip_box)
chip_y: .long 0
chip_w: .long 0
chip_h: .long 0
.globl ad_built
ad_built: .long 0               # records made (print-agent-row's built=: a diff is made once)
cls_buf: .zero CLS_MAX

.text

# ---------------- the record ----------------

# side_of(AT*, kind) -> rax the kept text of the line's side, rdx its length
side_of:
    lea rax, [rdi + AT_b]
    cmp esi, ADK_DEL
    jne 1f
    lea rax, [rdi + AT_a]
1:  mov rdx, [rax + SB_len]
    mov rax, [rax + SB_ptr]
    ret

# file_cut(ptr, len) -> rax: what a row read from a file keeps of a side (agrow_set's rule: AT_SIDE bytes or
#   AT_SIDE_LINES lines, cut at a character)
file_cut:
    mov rax, rsi
    cmp rax, AT_SIDE
    jbe 1f
    mov eax, AT_SIDE
1:  mov edx, AT_SIDE_LINES
    xor ecx, ecx
2:  cmp rcx, rax
    jae 4f
    cmp byte ptr [rdi + rcx], 10
    jne 3f
    dec edx
    jnz 3f
    mov rax, rcx
    jmp 4f
3:  inc rcx
    jmp 2b
4:  cmp rax, rsi
    jae 9f
5:  test rax, rax
    jz 9f
    movzx ecx, byte ptr [rdi + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne 9f
    dec rax
    jmp 5b
9:  ret

# line_table(ptr, len, *count) -> rax its lines as (offset, length) u32 pairs (mem_free it); a final line feed
#   ends the last line (hash_text's rule)
line_table:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov [rsp], rdx
    xor ebx, ebx
    xor ecx, ecx
1:  cmp rcx, r13
    jae 2f
    cmp byte ptr [r12 + rcx], 10
    jne 11f
    inc rbx
11: inc rcx
    jmp 1b
2:  test r13, r13
    jz 3f
    cmp byte ptr [r12 + r13 - 1], 10
    je 3f
    inc rbx
3:  mov rax, [rsp]
    mov [rax], rbx
    lea rdi, [rbx*8 + 8]
    call mem_alloc
    mov r14, rax
    xor r15d, r15d              # the line
    xor ebx, ebx                # its start
    xor ecx, ecx
4:  cmp rcx, r13
    jae 6f
    cmp byte ptr [r12 + rcx], 10
    jne 5f
    mov [r14 + r15*8], ebx
    mov edx, ecx
    sub edx, ebx
    mov [r14 + r15*8 + 4], edx
    inc r15
    lea ebx, [rcx + 1]
5:  inc rcx
    jmp 4b
6:  cmp rbx, r13
    jae 7f
    mov [r14 + r15*8], ebx
    mov edx, r13d
    sub edx, ebx
    mov [r14 + r15*8 + 4], edx
7:  mov rax, r14
    EPILOGUE

# ad_emit(AD*, kind, offset, length): a visual line: counted, kept while there is room
ad_emit:
    cmp esi, ADK_ADD
    jne 1f
    inc dword ptr [rdi + AD_add]
    jmp 2f
1:  cmp esi, ADK_DEL
    jne 2f
    inc dword ptr [rdi + AD_del]
2:  mov eax, [rdi + AD_n]
    cmp eax, AD_MAX
    jb 3f
    mov dword ptr [rdi + AD_more], 1
    ret
3:  shl eax, 4
    lea rax, [rdi + rax + AD_lines]
    mov [rax + ADL_kind], esi
    mov dword ptr [rax + ADL_state], 0
    mov [rax + ADL_off], edx
    mov [rax + ADL_len], ecx
    inc dword ptr [rdi + AD_n]
    ret

# emit_at(AD*, kind, table, index): ad_emit of the table's line
emit_at:
    mov r8, rdx
    mov edx, [r8 + rcx*8]
    mov ecx, [r8 + rcx*8 + 4]
    jmp ad_emit

# trim_tail(a marks, n, b marks, m, cut: 1 a, 2 b): after the last line the two sides share, a side cut short
#   leaves the other side's lines unknown (they may be past the cut): their marks become 2, not shown. With
#   no shared line every change stays
trim_tail:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8d
    xor ecx, ecx                # i
    xor edx, edx                # j
    mov r8, -1                  # the last pair shared
    mov r9, -1
1:  cmp rcx, r12
    jae 2f
    cmp byte ptr [rbx + rcx], 0
    je 2f
    inc rcx
    jmp 1b
2:  cmp rdx, r14
    jae 3f
    cmp byte ptr [r13 + rdx], 0
    je 3f
    inc rdx
    jmp 1b
3:  cmp rcx, r12
    jae 4f
    cmp rdx, r14
    jae 4f
    mov r8, rcx
    mov r9, rdx
    inc rcx
    inc rdx
    jmp 1b
4:  test r8, r8
    js 9f
    test dword ptr [rsp], 2     # b cut: a's lines after it went, or are past b's cut
    jz 6f
    lea rcx, [r8 + 1]
5:  cmp rcx, r12
    jae 6f
    cmp byte ptr [rbx + rcx], 1
    jne 51f
    mov byte ptr [rbx + rcx], 2
51: inc rcx
    jmp 5b
6:  test dword ptr [rsp], 1     # a cut: b's lines after it came, or are past a's cut
    jz 9f
    lea rdx, [r9 + 1]
7:  cmp rdx, r14
    jae 9f
    cmp byte ptr [r13 + rdx], 1
    jne 71f
    mov byte ptr [r13 + rdx], 2
71: inc rdx
    jmp 7b
9:  EPILOGUE

# ad_make(AT*, a length, b length, ATF_DIFF | ATF_PRE, real) -> rax AD*: a record of the first bytes of each
#   side. A diff: the sides' lines hashed and diffed (past 1000 differences, or a side empty, every line of
#   one went and every line of the other came), removed lines before the added ones of a change; a file's
#   text: B's lines, all the same. real: the grammar and its states, and AD_more for a side the row cut
ad_make:
    PROLOGUE 176
    mov r12, rdi
    mov [rsp], rsi              # a's length
    mov [rsp + 8], rdx          # b's
    mov [rsp + 80], ecx         # what for
    mov [rsp + 84], r8d         # real
    xor eax, eax
    mov [rsp + 16], rax         # a's lines
    mov [rsp + 24], rax         # b's
    mov [rsp + 32], rax         # a's table
    mov [rsp + 40], rax         # b's
    mov [rsp + 48], rax         # a's hashes
    mov [rsp + 56], rax         # b's
    mov [rsp + 64], rax         # a's marks
    mov [rsp + 72], rax         # b's
    mov edi, AD_SIZE
    call mem_alloc
    mov rbx, rax
    mov rdi, rbx
    xor esi, esi
    mov edx, AD_SIZE
    call memset
    mov eax, [rsp + 80]
    mov [rbx + AD_flags], eax
    mov dword ptr [rbx + AD_kw], -1
    mov rdi, [r12 + AT_b + SB_ptr]
    mov rsi, [rsp + 8]
    lea rdx, [rsp + 24]
    call line_table
    mov [rsp + 40], rax
    test dword ptr [rsp + 80], ATF_DIFF
    jnz .Lmk_diff
    xor r13d, r13d              # a file's text: B's lines
1:  cmp r13, [rsp + 24]
    jae .Lmk_states
    cmp dword ptr [rbx + AD_more], 0
    jne .Lmk_states
    mov rdi, rbx
    mov esi, ADK_SAME
    mov rdx, [rsp + 40]
    mov rcx, r13
    call emit_at
    inc r13
    jmp 1b
.Lmk_diff:
    mov dword ptr [rbx + AD_sign], 1
    mov rdi, [r12 + AT_a + SB_ptr]
    mov rsi, [rsp]
    lea rdx, [rsp + 16]
    call line_table
    mov [rsp + 32], rax
    mov rdi, [rsp + 16]         # the marks, a byte a line
    inc rdi
    call mem_alloc
    mov [rsp + 64], rax
    mov rdi, rax
    xor esi, esi
    mov rdx, [rsp + 16]
    inc rdx
    call memset
    mov rdi, [rsp + 24]
    inc rdi
    call mem_alloc
    mov [rsp + 72], rax
    mov rdi, rax
    xor esi, esi
    mov rdx, [rsp + 24]
    inc rdx
    call memset
    cmp qword ptr [rsp + 16], 0
    je .Lmk_alladd
    cmp qword ptr [rsp + 24], 0
    je .Lmk_alldel
    mov rdi, [r12 + AT_a + SB_ptr]
    mov rsi, [rsp]
    lea rdx, [rsp + 88]
    call hash_text
    mov [rsp + 48], rax
    mov rdi, [r12 + AT_b + SB_ptr]
    mov rsi, [rsp + 8]
    lea rdx, [rsp + 88]
    call hash_text
    mov [rsp + 56], rax
    mov rdi, [rsp + 48]
    mov rsi, [rsp + 16]
    mov rdx, [rsp + 56]
    mov rcx, [rsp + 24]
    mov r8, [rsp + 64]
    mov r9, [rsp + 72]
    call diff_lines
    test eax, eax
    jnz .Lmk_walk
    mov rdi, [rsp + 64]         # too different: all went, all came
    mov esi, 1
    mov rdx, [rsp + 16]
    call memset
.Lmk_alladd:
    mov rdi, [rsp + 72]
    mov esi, 1
    mov rdx, [rsp + 24]
    call memset
    jmp .Lmk_walk
.Lmk_alldel:
    mov rdi, [rsp + 64]
    mov esi, 1
    mov rdx, [rsp + 16]
    call memset
.Lmk_walk:
    xor r15d, r15d              # a side cut short (1 a, 2 b): what follows the last line both sides kept
    mov rax, [r12 + AT_size + 16]   #   is not known (A's whole bytes, ATX_A)
    cmp rax, [rsp]
    jbe 11f
    or r15d, 1
11: mov rax, [r12 + AT_size + 24]   # (B's, ATX_B)
    cmp rax, [rsp + 8]
    jbe 12f
    or r15d, 2
12: test r15d, r15d
    jz 13f
    mov rdi, [rsp + 64]
    mov rsi, [rsp + 16]
    mov rdx, [rsp + 72]
    mov rcx, [rsp + 24]
    mov r8d, r15d
    call trim_tail
13: xor r13d, r13d              # i in a
    xor r14d, r14d              # j in b
2:  cmp r13, [rsp + 16]         # a's line went
    jae 3f
    mov rax, [rsp + 64]
    movzx ecx, byte ptr [rax + r13]
    test ecx, ecx
    jz 3f
    cmp ecx, 2
    je 21f                      # (not known: not shown)
    mov rdi, rbx
    mov esi, ADK_DEL
    mov rdx, [rsp + 32]
    mov rcx, r13
    call emit_at
21: inc r13
    jmp 2b
3:  cmp r14, [rsp + 24]         # b's came
    jae 4f
    mov rax, [rsp + 72]
    movzx ecx, byte ptr [rax + r14]
    test ecx, ecx
    jz 4f
    cmp ecx, 2
    je 31f
    mov rdi, rbx
    mov esi, ADK_ADD
    mov rdx, [rsp + 40]
    mov rcx, r14
    call emit_at
31: inc r14
    jmp 2b
4:  cmp r13, [rsp + 16]
    jae 5f
    cmp r14, [rsp + 24]
    jae 41f
    mov rdi, rbx                # both stayed: the same line
    mov esi, ADK_SAME
    mov rdx, [rsp + 40]
    mov rcx, r14
    call emit_at
    inc r13
    inc r14
    jmp 2b
41: mov rdi, rbx
    mov esi, ADK_DEL
    mov rdx, [rsp + 32]
    mov rcx, r13
    call emit_at
    inc r13
    jmp 2b
5:  cmp r14, [rsp + 24]
    jae .Lmk_states
    mov rdi, rbx
    mov esi, ADK_ADD
    mov rdx, [rsp + 40]
    mov rcx, r14
    call emit_at
    inc r14
    jmp 2b
.Lmk_states:
    cmp dword ptr [rsp + 84], 0
    je .Lmk_done
    mov rdi, [r12 + AT_link]    # the grammar: by the file's name (the link's, else the second text)
    test rdi, rdi
    jnz 6f
    mov rdi, [r12 + AT_second]
    test rdi, rdi
    jz .Lmk_more
6:  mov r13, rdi
    call strlen
    mov rdi, r13
    mov rsi, rax
    call path_basename
    mov rdi, rax
    mov rsi, rdx
    call syntax_for_name
    test rax, rax
    jz .Lmk_more
    mov rdi, rax
    call syntax_ready
    mov [rbx + AD_gr], rax
    xor eax, eax                # a side's tokenizer: {line, table, text, state}
    mov [rsp + 96], rax
    mov rcx, [rsp + 32]
    mov [rsp + 104], rcx
    mov rcx, [r12 + AT_a + SB_ptr]
    mov [rsp + 112], rcx
    mov [rsp + 120], eax
    mov [rsp + 128], rax
    mov rcx, [rsp + 40]
    mov [rsp + 136], rcx
    mov rcx, [r12 + AT_b + SB_ptr]
    mov [rsp + 144], rcx
    mov [rsp + 152], eax
    xor r13d, r13d              # each line kept: its side read on to it
7:  cmp r13d, [rbx + AD_n]
    jae .Lmk_more
    mov eax, r13d
    shl eax, 4
    lea r14, [rbx + rax + AD_lines]
    lea r15, [rsp + 128]
    cmp dword ptr [r14 + ADL_kind], ADK_DEL
    jne 8f
    lea r15, [rsp + 96]
8:  mov rax, [r15]
    mov rcx, [r15 + 8]
    mov edx, [rcx + rax*8]
    cmp edx, [r14 + ADL_off]
    jae 9f
    mov rsi, [r15 + 16]
    add rsi, rdx
    mov edx, [rcx + rax*8 + 4]
    cmp edx, CLS_MAX
    jbe 81f
    mov edx, CLS_MAX
81: mov rdi, [rbx + AD_gr]
    mov ecx, [r15 + 24]
    xor r8d, r8d
    call tokenize
    mov [r15 + 24], eax
    inc qword ptr [r15]
    jmp 8b
9:  mov eax, [r15 + 24]
    mov [r14 + ADL_state], eax
    inc r13d
    jmp 7b
.Lmk_more:
    mov rax, [r12 + AT_size + 24]   # B's whole bytes (ATX_B)
    cmp rax, [r12 + AT_b + SB_len]
    jbe 10f
    mov dword ptr [rbx + AD_more], 1
10: test dword ptr [rsp + 80], ATF_DIFF
    jz .Lmk_done
    mov rax, [r12 + AT_size + 16]   # A's (ATX_A)
    cmp rax, [r12 + AT_a + SB_len]
    jbe .Lmk_done
    mov dword ptr [rbx + AD_more], 1
.Lmk_done:
    mov rdi, [rsp + 32]
    call mem_free
    mov rdi, [rsp + 40]
    call mem_free
    mov rdi, [rsp + 48]
    call mem_free
    mov rdi, [rsp + 56]
    call mem_free
    mov rdi, [rsp + 64]
    call mem_free
    mov rdi, [rsp + 72]
    call mem_free
    mov r13d, [rbx + AD_n]      # kept in a block as long as its lines
    shl r13d, 4
    add r13d, AD_lines
    mov edi, r13d
    call mem_alloc
    mov r14, rax
    mov rdi, rax
    mov rsi, rbx
    mov edx, r13d
    call memcpy
    mov rdi, rbx
    call mem_free
    mov rax, r14
    EPILOGUE

# ad_get(AT*) -> rax its record, made now when it has none (or one made for the other kind); 0: no diff and
#   no file's text
ad_get:
    PROLOGUE
    mov rbx, rdi
    mov r12d, [rbx + AT_flags]
    and r12d, ATF_DIFF | ATF_PRE
    jz 8f
    test r12d, ATF_DIFF
    jz 1f
    mov r12d, ATF_DIFF
1:  mov rax, [rbx + AT_diff]
    test rax, rax
    jz 2f
    cmp [rax + AD_flags], r12d
    je 9f
    mov rdi, rbx
    call agdiff_free
2:  mov rdi, rbx
    mov rsi, [rbx + AT_a + SB_len]
    mov rdx, [rbx + AT_b + SB_len]
    mov ecx, r12d
    mov r8d, 1
    call ad_make
    mov [rbx + AT_diff], rax
    inc dword ptr [rip + ad_built]
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agdiff_free(AT*): its record goes
FN agdiff_free
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    mov rdi, [rbx + AT_diff]
    call mem_free
    mov qword ptr [rbx + AT_diff], 0
9:  EPILOGUE

# ---------------- layout ----------------

# pad() -> eax the block's room above its first row
pad:
    mov eax, [rip + g_pmt + 4*MI_6]
    ret

# cap() -> eax the block's height at most: 10 x MI_20 of the panel
cap:
    mov eax, [rip + g_pmt + 4*MI_20]
    imul eax, eax, 10
    ret

# wk_setup(AT*, AD*, x, y, w): the walker's geometry for a block at x, y, w
wk_setup:
    PROLOGUE
    mov [rip + wk_at], rdi
    mov [rip + wk_ad], rsi
    mov rbx, rsi
    mov r12d, edx
    mov r13d, ecx
    mov r14d, r8d
    call agrow_code_face
    mov [rip + wk_face], rax
    mov ecx, [rax + FACE_lineh]
    mov [rip + wk_lh], ecx
    mov [rip + wk_bx], r12d
    mov [rip + wk_bw], r14d
    mov edx, r12d
    add edx, [rip + g_pmt + 4*MI_6]
    mov [rip + wk_sx], edx
    mov r15d, r14d              # the text's width: the block's less its pads and the sign column
    sub r15d, [rip + g_pmt + 4*MI_6]
    sub r15d, [rip + g_pmt + 4*MI_6]
    cmp dword ptr [rbx + AD_sign], 0
    je 1f
    mov ecx, [rax + FACE_cellw]
    add ecx, [rip + g_pmt + 4*MI_4]
    add edx, ecx
    sub r15d, ecx
1:  mov [rip + wk_x], edx
    cmp r15d, 1
    jge 2f
    mov r15d, 1
2:  mov [rip + wk_tw], r15d
    call pad
    add eax, r13d
    mov [rip + wk_y], eax
    mov dword ptr [rip + wk_cls], 0
    EPILOGUE

# ad_layout(AT*, AD*, w): its height and whether it is cut, for the width, the code face and the panel's
#   metrics (kept: nothing is done again until one of them changes). The content is walked up to the cap only
ad_layout:
    PROLOGUE 16
    mov r12, rdi
    mov rbx, rsi
    mov r13d, edx
    call agrow_code_face
    mov r14, rax
    mov rcx, [r14 + FACE_font]
    cmp rcx, [rbx + AD_kfont]
    jne 1f
    mov ecx, [r14 + FACE_px]
    cmp ecx, [rbx + AD_kpx]
    jne 1f
    mov ecx, [r14 + FACE_lineh]
    cmp ecx, [rbx + AD_klh]
    jne 1f
    mov ecx, [r14 + FACE_cellw]
    cmp ecx, [rbx + AD_kcw]
    jne 1f
    mov ecx, [rip + g_pmt + 4*MI_20]
    cmp ecx, [rbx + AD_kmi]
    jne 1f
    cmp r13d, [rbx + AD_kw]
    je 9f
1:  mov rcx, [r14 + FACE_font]
    mov [rbx + AD_kfont], rcx
    mov ecx, [r14 + FACE_px]
    mov [rbx + AD_kpx], ecx
    mov ecx, [r14 + FACE_lineh]
    mov [rbx + AD_klh], ecx
    mov ecx, [r14 + FACE_cellw]
    mov [rbx + AD_kcw], ecx
    mov ecx, [rip + g_pmt + 4*MI_20]
    mov [rbx + AD_kmi], ecx
    mov [rbx + AD_kw], r13d
    mov dword ptr [rbx + AD_h], 0
    mov dword ptr [rbx + AD_cut], 0
    cmp dword ptr [rbx + AD_n], 0
    je 9f
    mov rdi, r12
    mov rsi, rbx
    xor edx, edx
    xor ecx, ecx
    mov r8d, r13d
    call wk_setup
    call cap
    mov [rip + wk_limit], eax
    mov dword ptr [rip + wk_mode], WK_MEASURE
    call ad_walk
    mov r15d, eax               # the content (up to the cap)
    call cap
    mov ecx, eax
    lea edx, [r15 + 0]
    add edx, [rip + g_pmt + 4*MI_20]
    cmp edx, ecx
    jle 2f
    mov edx, ecx
2:  mov [rbx + AD_h], edx
    call pad
    sub edx, eax
    cmp r15d, edx
    jg 3f
    cmp dword ptr [rbx + AD_more], 0
    je 9f
3:  mov dword ptr [rbx + AD_cut], 1
9:  EPILOGUE

# ad_prep(AT*, w) -> rax its record laid out for w (rax 0, or AD_h 0: nothing to show)
ad_prep:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    call ad_get
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, r12
    mov rsi, rbx
    mov edx, r13d
    call ad_layout
    mov rax, rbx
9:  EPILOGUE

# FN agdiff_h(AT*, w) -> eax its block's height at that width (0: none)
FN agdiff_h
    PROLOGUE
    call ad_prep
    test rax, rax
    jz 9f
    mov eax, [rax + AD_h]
9:  EPILOGUE

# FN agdiff_est(AT*) -> eax its block's height estimated from its parts' whole line counts (no record, no
#   width): a diff's two sides' lines, a file's lines, up to the cap; 0 none
FN agdiff_est
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    mov ecx, [rbx + AT_flags]
    test ecx, ATF_DIFF | ATF_PRE
    jz 9f
    mov r12d, [rbx + AT_lines + 12]     # B's (ATX_B)
    test ecx, ATF_DIFF
    jz 1f
    add r12d, [rbx + AT_lines + 8]      # and A's (ATX_A)
1:  test r12d, r12d
    jz 9f
    call agrow_code_face
    mov eax, [rax + FACE_lineh]
    imul eax, r12d
    add eax, [rip + g_pmt + 4*MI_20]
    mov r12d, eax
    call cap
    cmp r12d, eax
    cmovl eax, r12d
9:  EPILOGUE

# ---------------- rows: wrapped, drawn, written out ----------------

# ad_wrap(face, ptr, len, from, width 26.6) -> rax the row's end, rdx the next row's start: at the last blank
#   when the row has one, else anywhere, one character at least (a TAB is four cells)
ad_wrap:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], rcx
    mov [rsp + 8], r8d
    xor r15d, r15d
    mov qword ptr [rsp + 16], -1    # the last blank
1:  cmp r14, r13
    jae .Lwr_all
    movzx eax, byte ptr [r12 + r14]
    cmp eax, 9
    jne 2f
    mov [rsp + 16], r14
    mov eax, [rbx + FACE_cellw]
    shl eax, 8
    mov dword ptr [rsp + 24], 1
    jmp 4f
2:  cmp eax, ' '
    jne 3f
    mov [rsp + 16], r14
3:  lea rdi, [r12 + r14]
    mov rsi, r13
    sub rsi, r14
    call utf8_decode
    mov [rsp + 24], edx
    mov rdi, rbx
    mov esi, eax
    call face_glyph
    mov eax, [rax + GL_adv]
4:  lea ecx, [r15 + rax]
    cmp ecx, [rsp + 8]
    jle 5f
    cmp r14, [rsp]
    je 5f                       # a row holds one character at least
    mov rax, [rsp + 16]
    cmp rax, [rsp]
    jle 6f
    lea rdx, [rax + 1]          # at the blank
    EPILOGUE
6:  mov rax, r14                # anywhere
    mov rdx, r14
    EPILOGUE
5:  mov r15d, ecx
    mov eax, [rsp + 24]
    add r14, rax
    jmp 1b
.Lwr_all:
    mov rax, r13
    mov rdx, r13
    EPILOGUE

# ad_adv(face, ptr, len) -> eax its width (a TAB four cells)
ad_adv:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  test r13, r13
    jz 9f
    cmp byte ptr [r12], 9
    jne 2f
    mov eax, [rbx + FACE_cellw]
    shl eax, 8
    add r14d, eax
    inc r12
    dec r13
    jmp 1b
2:  mov rdi, r12
    mov rsi, r13
    call utf8_decode
    add r12, rdx
    sub r13, rdx
    mov rdi, rbx
    mov esi, eax
    call face_glyph
    add r14d, [rax + GL_adv]
    jmp 1b
9:  lea eax, [r14 + 32]
    sar eax, 6
    EPILOGUE

# wk_tok(ptr, len, state): the line's classes into cls_buf (wk_cls 1) when its record has a grammar
wk_tok:
    PROLOGUE
    mov dword ptr [rip + wk_cls], 0
    mov rax, [rip + wk_ad]
    mov rax, [rax + AD_gr]
    test rax, rax
    jz 9f
    cmp rsi, CLS_MAX
    jbe 1f
    mov esi, CLS_MAX
1:  mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, rax
    lea r8, [rip + cls_buf]
    call tokenize
    mov dword ptr [rip + wk_cls], 1
9:  EPILOGUE

# cls_at(index) -> eax the class of the line's byte (0 plain); rcx kept
cls_at:
    xor eax, eax
    cmp dword ptr [rip + wk_cls], 0
    je 9f
    cmp rdi, CLS_MAX
    jae 9f
    lea rdx, [rip + cls_buf]
    movzx eax, byte ptr [rdx + rdi]
9:  ret

# cls_color(class) -> eax its colour (T_SYN + class; 0: T_FG)
cls_color:
    COLOR eax, T_FG
    test edi, edi
    jz 9f
    cmp edi, C_COUNT
    jae 9f
    lea rax, [rip + g_theme]
    mov eax, [rax + rdi*4 + 4*T_SYN]
9:  ret

# run_end(ptr, from, end) -> rax the end of the run of one class from there (not past a TAB, never inside a
#   character)
run_end:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, r13
    call cls_at
    mov ebx, eax
    lea rcx, [r13 + 1]
1:  cmp rcx, r14
    jae 9f
    movzx eax, byte ptr [r12 + rcx]
    cmp eax, 9
    je 9f
    and eax, 0xc0
    cmp eax, 0x80
    je 2f
    mov rdi, rcx
    call cls_at
    cmp eax, ebx
    jne 9f
2:  inc rcx
    jmp 1b
9:  mov rax, rcx
    EPILOGUE

# row_draw(line ptr, from, end, top, kind, first): a row drawn: its band and sign, its text coloured
row_draw:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov ebx, ecx
    mov [rsp], r8d
    mov [rsp + 4], r9d
    cmp r8d, ADK_SAME
    je 2f
    COLOR esi, T_GIT_ADD
    cmp r8d, ADK_DEL
    jne 1f
    COLOR esi, T_GIT_DEL
1:  COLOR edi, T_BG
    mov edx, TINT
    call color_mix
    mov r8d, eax
    mov edi, [rip + wk_bx]
    mov esi, ebx
    mov edx, [rip + wk_bw]
    mov ecx, [rip + wk_lh]
    call gfx_fill
    cmp dword ptr [rsp + 4], 0
    je 2f
    lea rcx, [rip + .Lplus]     # the sign, on the line's first row
    COLOR r9d, T_GIT_ADD
    cmp dword ptr [rsp], ADK_DEL
    jne 11f
    lea rcx, [rip + .Lminus]
    COLOR r9d, T_GIT_DEL
11: mov rdi, [rip + wk_face]
    mov esi, [rip + wk_sx]
    mov edx, ebx
    add edx, [rdi + FACE_ascent]
    mov r8d, 1
    call text_draw
2:  mov rdi, r12                # task 10: a selection's band over the row's, the pointer's place in it
    mov rsi, r13                #   (agentsel.s)
    mov rdx, r14
    mov ecx, ebx
    mov r8d, [rip + wk_x]
    mov r9d, [rip + wk_line]
    call agsel_diff_row
    mov r15d, [rip + wk_x]      # the text, a run of one class at a time
3:  cmp r13, r14
    jae 9f
    cmp byte ptr [r12 + r13], 9
    jne 4f
    mov rax, [rip + wk_face]
    mov eax, [rax + FACE_cellw]
    shl eax, 2
    add r15d, eax
    inc r13
    jmp 3b
4:  mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call run_end
    mov [rsp + 8], rax
    mov rdi, r13
    call cls_at
    mov edi, eax
    call cls_color
    mov r9d, eax
    mov rdi, [rip + wk_face]
    mov esi, r15d
    mov edx, ebx
    add edx, [rdi + FACE_ascent]
    lea rcx, [r12 + r13]
    mov r8, [rsp + 8]
    sub r8, r13
    call text_draw
    mov r15d, eax
    mov r13, [rsp + 8]
    jmp 3b
9:  EPILOGUE

# push_cut(sb, ptr, len, max): at most max bytes of a text, cut at a character
push_cut:
    cmp rdx, rcx
    jbe 2f
    mov rdx, rcx
1:  test rdx, rdx
    jz 2f
    movzx eax, byte ptr [rsi + rdx]
    and eax, 0xc0
    cmp eax, 0x80
    jne 2f
    dec rdx
    jmp 1b
2:  jmp sb_push

# push_rect(sb, x, y, w, h): "X,Y,W,H"
push_rect:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, edx
    mov r13d, ecx
    mov r14d, r8d
    call md_push_int
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, r12d
    call md_push_int
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, r13d
    call md_push_int
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, r14d
    call md_push_int
    EPILOGUE

# row_dump(line ptr, from, end, top, kind, line n): "diff N KIND X,Y,W syn=CLASS:BYTES,… T" to wk_sb
row_dump:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov [rsp + 8], r9d
    mov rbx, [rip + wk_sb]
    mov rdi, rbx
    lea rsi, [rip + .Ld_diff]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rsp + 8]
    call sb_push_u64
    mov eax, [rsp + 4]
    lea rcx, [rip + kind_words]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, [rip + wk_face]
    lea rsi, [r12 + r13]
    mov rdx, r14
    sub rdx, r13
    call ad_adv
    mov r15d, eax
    mov rdi, rbx                # "X,Y,W"
    mov esi, [rip + wk_x]
    call md_push_int
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rsp]
    call md_push_int
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, r15d
    call md_push_int
    mov rdi, rbx
    lea rsi, [rip + .Ld_syn]
    call sb_push_cstr
    mov r15, r13                # the runs of one class
    mov dword ptr [rsp + 12], 0
1:  cmp r15, r14
    jae 3f
    mov rdi, r15
    call cls_at
    mov [rsp + 16], eax
    lea rcx, [r15 + 1]
2:  cmp rcx, r14
    jae 21f
    mov rdi, rcx
    call cls_at
    cmp eax, [rsp + 16]
    jne 21f
    inc rcx
    jmp 2b
21: mov [rsp + 24], rcx
    cmp dword ptr [rsp + 12], 0
    je 22f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
22: mov dword ptr [rsp + 12], 1
    mov rdi, rbx
    mov esi, [rsp + 16]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ':'
    call sb_push_byte
    mov rsi, [rsp + 24]
    sub rsi, r15
    mov rdi, rbx
    call sb_push_u64
    mov r15, [rsp + 24]
    jmp 1b
3:  mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    lea rsi, [r12 + r13]
    mov rdx, r14
    sub rdx, r13
    mov ecx, ROW_CUT
    call push_cut
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# ad_walk() -> eax the content walked (px): the record's lines (wk_ad) row by row, wrapped at wk_tw, until
#   wk_limit; drawn (WK_DRAW: the rows in the clip), written out (WK_DUMP: the rows wholly above wk_bot) or
#   only counted (WK_MEASURE). A line is coloured (tokenized) when its first row is drawn or written
ad_walk:
    PROLOGUE 64
    xor r15d, r15d              # the content's height so far
    xor r12d, r12d              # the line
.Lw_line:
    mov rbx, [rip + wk_ad]
    cmp r12d, [rbx + AD_n]
    jae .Lw_done
    mov eax, r12d
    shl eax, 4
    lea r13, [rbx + rax + AD_lines]
    mov rdi, [rip + wk_at]
    mov esi, [r13 + ADL_kind]
    call side_of
    mov ecx, [r13 + ADL_off]
    add rax, rcx
    mov [rsp], rax              # its text
    mov ecx, [r13 + ADL_len]
    mov [rsp + 8], rcx
    mov dword ptr [rsp + 16], 0 # coloured yet
    mov dword ptr [rsp + 20], 1 # its first row
    mov dword ptr [rip + wk_cls], 0
    xor r14d, r14d              # the row's start
.Lw_row:
    mov rdi, [rip + wk_face]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    mov rcx, r14
    mov r8d, [rip + wk_tw]
    shl r8d, 6
    call ad_wrap
    mov [rsp + 24], rax
    mov [rsp + 32], rdx
    mov eax, [rip + wk_mode]
    cmp eax, WK_MEASURE
    je .Lw_next
    mov eax, [rip + wk_y]
    add eax, r15d
    mov [rsp + 40], eax         # its top
    mov ecx, eax
    add ecx, [rip + wk_lh]
    cmp dword ptr [rip + wk_mode], WK_DUMP
    je 2f
    cmp ecx, [rip + g_cv + CV_cy0]  # drawn: in the clip only
    jle .Lw_next
    cmp eax, [rip + g_cv + CV_cy1]
    jge .Lw_next
    jmp 3f
2:  cmp ecx, [rip + wk_bot]
    jg .Lw_next
3:  cmp dword ptr [rsp + 16], 0
    jne 4f
    mov dword ptr [rsp + 16], 1
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov edx, [r13 + ADL_state]
    call wk_tok
4:  mov [rip + wk_line], r12d  # (task 10: the line row_draw draws a row of, for a selection)
    mov rdi, [rsp]
    mov rsi, r14
    mov rdx, [rsp + 24]
    mov ecx, [rsp + 40]
    mov r8d, [r13 + ADL_kind]
    cmp dword ptr [rip + wk_mode], WK_DUMP
    je 5f
    mov r9d, [rsp + 20]
    call row_draw
    jmp .Lw_next
5:  mov r9d, r12d
    call row_dump
.Lw_next:
    mov dword ptr [rsp + 20], 0
    add r15d, [rip + wk_lh]
    cmp r15d, [rip + wk_limit]
    jge .Lw_done
    mov r14, [rsp + 32]
    cmp r14, [rsp + 8]
    jb .Lw_row
    inc r12d
    jmp .Lw_line
.Lw_done:
    mov eax, r15d
    EPILOGUE

# ---------------- the block ----------------

# fade(x, y, w, h): the cut block's last pixels fade into its background (T_BG, more opaque downwards)
fade:
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov eax, ecx
    xor edx, edx
    mov ecx, 5
    div ecx
    test eax, eax
    jnz 1f
    mov eax, 1
1:  mov [rsp + 12], eax
    xor ebx, ebx
2:  cmp ebx, 5
    jae 9f
    COLOR r8d, T_BG
    and r8d, 0x00ffffff
    lea eax, [rbx + 1]
    imul eax, eax, 51
    shl eax, 24
    or r8d, eax
    mov edi, [rsp]
    mov eax, [rsp + 12]
    imul eax, ebx
    mov esi, [rsp + 4]
    add esi, eax
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_fill
    inc ebx
    jmp 2b
9:  EPILOGUE

# chip_box(x, y, w, h): where "Click to expand" goes in a block there: centred at its bottom, as wide as its
#   text and narrower when the block is (chip_w 0: no room)
chip_box:
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov r12d, edx
    mov r13d, ecx
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lexpand]
    mov edx, EXPAND_LEN
    call text_width
    add eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_8]
    mov ecx, r12d               # the room
    sub ecx, [rip + g_pmt + 4*MI_4]
    sub ecx, [rip + g_pmt + 4*MI_4]
    cmp eax, ecx
    cmovg eax, ecx
    mov edx, [rip + g_pmt + 4*MI_8]
    add edx, edx
    add edx, [rip + g_pmt + 4*MI_8]
    cmp eax, edx
    jg 1f
    xor eax, eax                # not even a few letters
1:  mov [rip + chip_w], eax
    mov ecx, r12d
    sub ecx, eax
    sar ecx, 1
    add ecx, [rsp]
    mov [rip + chip_x], ecx
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_6]
    cmp eax, r13d
    cmovg eax, r13d
    mov [rip + chip_h], eax
    mov ecx, [rsp + 4]
    add ecx, r13d
    sub ecx, eax
    sub ecx, [rip + g_pmt + 4*MI_6]
    cmp ecx, [rsp + 4]
    jge 2f
    mov ecx, [rsp + 4]
2:  mov [rip + chip_y], ecx
    EPILOGUE

# chip_draw(): "Click to expand" on the menu's background where chip_box put it
chip_draw:
    PROLOGUE
    cmp dword ptr [rip + chip_w], 0
    je 9f
    mov edi, [rip + chip_x]
    mov esi, [rip + chip_y]
    mov edx, [rip + chip_w]
    mov ecx, [rip + chip_h]
    PM r8d, MI_4
    COLOR r9d, T_BORDER         # a 1 px edge, then the menu's background
    call gfx_round_rect
    mov edi, [rip + chip_x]
    inc edi
    mov esi, [rip + chip_y]
    inc esi
    mov edx, [rip + chip_w]
    sub edx, 2
    mov ecx, [rip + chip_h]
    sub ecx, 2
    PM r8d, MI_4
    COLOR r9d, T_POPUP
    call gfx_round_rect
    mov rdi, [rip + ag_fsmall]
    mov esi, [rip + chip_x]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rip + chip_y]
    mov ecx, [rip + chip_h]
    lea r8, [rip + .Lexpand]
    mov r9d, EXPAND_LEN
    COLOR eax, T_FG
    mov r10d, [rip + chip_w]
    sub r10d, [rip + g_pmt + 4*MI_8]
    sub r10d, [rip + g_pmt + 4*MI_8]
    push r10
    push rax
    call ui_text_v_fit
    add rsp, 16
9:  EPILOGUE

# FN agdiff_draw(AT*, x, y, w, id) -> eax 1 when it was clicked: the block on T_BG, its rows in the clip, cut:
#   the fade and "Click to expand" (shown too while the pointer is over it); the whole block a button (id -1:
#   none)
FN agdiff_draw
    PROLOGUE 32
    mov r12, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov dword ptr [rsp + 20], 0
    mov esi, ecx
    call ad_prep
    test rax, rax
    jz 8f
    mov rbx, rax
    mov eax, [rbx + AD_h]
    test eax, eax
    jz 8f
    mov [rsp + 16], eax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 16]
    PM r8d, MI_4
    COLOR r9d, T_BG
    call gfx_round_rect
    mov edi, [rsp + 12]
    test edi, edi
    js 1f
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 16]
    call ui_btn
    mov [rsp + 20], eax
    test eax, UB_HOVER
    jz 1f
    mov dword ptr [rip + g_cursor], CUR_POINTER
1:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 16]
    call gfx_clip_push
    mov rdi, r12
    mov rsi, rbx
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    mov r8d, [rsp + 8]
    call wk_setup
    call pad
    mov ecx, [rsp + 16]
    sub ecx, eax
    mov [rip + wk_limit], ecx
    mov rdi, r12                # task 10: its rows select (agentsel.s): a press, a drag
    mov esi, [rsp + 20]
    call agsel_diff_begin
    mov dword ptr [rip + wk_mode], WK_DRAW
    call ad_walk
    mov dword ptr [rip + wk_mode], WK_MEASURE
    mov rdi, r12
    call agsel_diff_end
    call gfx_clip_pop
    cmp dword ptr [rbx + AD_cut], 0
    je 2f
    mov edi, [rsp]              # cut: the fade over its last MI_10
    mov esi, [rsp + 4]
    add esi, [rsp + 16]
    PM ecx, MI_10
    sub esi, ecx
    mov edx, [rsp + 8]
    call fade
    jmp 3f
2:  test dword ptr [rsp + 20], UB_HOVER
    jz 8f
3:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 16]
    call chip_box
    call chip_draw
8:  xor eax, eax
    test dword ptr [rsp + 20], UB_CLICK
    setnz al
    EPILOGUE

# FN agdiff_text(AT*, from, to, sb) -> eax 1: the text its block shows from one place to another (a place: its
#   line << 32 | a byte of it), the lines' text without their signs, a line feed between lines; 0 without a
#   record (phase 3 task 10: a selection's copy, agentsel.s)
FN agdiff_text
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov r15, rcx
    xor eax, eax
    mov r14, [rbx + AT_diff]
    test r14, r14
    jz 9f
    mov r12, [rsp]
    shr r12, 32                 # the line
1:  mov rax, [rsp + 8]
    shr rax, 32
    cmp r12, rax
    ja 8f
    cmp r12d, [r14 + AD_n]
    jae 8f
    mov eax, r12d
    shl eax, 4
    lea r13, [r14 + rax + AD_lines]
    mov rdi, rbx
    mov esi, [r13 + ADL_kind]
    call side_of
    mov ecx, [r13 + ADL_off]
    add rax, rcx
    mov [rsp + 16], rax         # its text
    mov ecx, [r13 + ADL_len]
    mov rdx, rcx                # to
    mov rax, [rsp + 8]
    shr rax, 32
    cmp r12, rax
    jne 2f
    mov eax, [rsp + 8]
    cmp rax, rdx
    cmova rax, rdx
    mov rdx, rax
2:  xor eax, eax                # from
    mov rcx, [rsp]
    shr rcx, 32
    cmp r12, rcx
    jne 3f
    mov eax, [rsp]
3:  cmp rax, rdx
    jae 4f
    mov rsi, [rsp + 16]
    add rsi, rax
    sub rdx, rax
    mov rdi, r15
    call sb_push
4:  mov rax, [rsp + 8]
    shr rax, 32
    cmp r12, rax
    jae 5f
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
5:  inc r12
    jmp 1b
8:  mov eax, 1
9:  EPILOGUE

# ---------------- dumps ----------------

# FN agdiff_dump(sb, AT*, indent cstr, content): a diff's lines for print-agent-rows: "INDENTdiff +A -B", then
#   a line each "INDENT- T", "INDENT+ T", "INDENT= T" (60 bytes) for the lines the record keeps. content: the
#   record of the sides as a row read from its file keeps them (a streamed row keeps more): what stream and
#   file both give
FN agdiff_dump
    PROLOGUE 32
    mov r14, rdi
    mov r12, rsi
    mov r15, rdx
    mov [rsp], ecx
    mov dword ptr [rsp + 4], 0  # a record of its own, freed after
    test dword ptr [r12 + AT_flags], ATF_DIFF
    jz 9f
    cmp dword ptr [rsp], 0
    jne 1f
    mov rdi, r12
    call ad_get
    mov rbx, rax
    jmp 2f
1:  mov rdi, [r12 + AT_a + SB_ptr]
    mov rsi, [r12 + AT_a + SB_len]
    call file_cut
    mov r13, rax
    mov rdi, [r12 + AT_b + SB_ptr]
    mov rsi, [r12 + AT_b + SB_len]
    call file_cut
    mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    mov ecx, ATF_DIFF
    xor r8d, r8d
    call ad_make
    mov rbx, rax
    mov dword ptr [rsp + 4], 1
2:  test rbx, rbx
    jz 9f
    mov rdi, r14
    mov rsi, r15
    call sb_push_cstr
    mov rdi, r14
    lea rsi, [rip + .Ld_counts]
    call sb_push_cstr
    mov rdi, r14
    mov esi, [rbx + AD_add]
    call sb_push_u64
    mov rdi, r14
    lea rsi, [rip + .Ld_minus]
    call sb_push_cstr
    mov rdi, r14
    mov esi, [rbx + AD_del]
    call sb_push_u64
    mov rdi, r14
    mov esi, 10
    call sb_push_byte
    xor r13d, r13d
3:  cmp r13d, [rbx + AD_n]
    jae 8f
    mov eax, r13d
    shl eax, 4
    lea rax, [rbx + rax + AD_lines]
    mov [rsp + 8], rax
    mov rdi, r14
    mov rsi, r15
    call sb_push_cstr
    mov rax, [rsp + 8]
    mov eax, [rax + ADL_kind]
    lea rcx, [rip + sign_words]
    mov rsi, [rcx + rax*8]
    mov rdi, r14
    call sb_push_cstr
    mov rax, [rsp + 8]
    mov rdi, r12
    mov esi, [rax + ADL_kind]
    call side_of
    mov rcx, [rsp + 8]
    mov edx, [rcx + ADL_off]
    lea rsi, [rax + rdx]
    mov edx, [rcx + ADL_len]
    mov rdi, r14
    mov ecx, ROW_CUT
    call push_cut
    mov rdi, r14
    mov esi, 10
    call sb_push_byte
    inc r13d
    jmp 3b
8:  cmp dword ptr [rsp + 4], 0
    je 9f
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# FN agdiff_lines(sb, AT*, x, y, w, fit): the block as laid out at x, y, w. print-agent-row (fit 0):
#   "diffbox X,Y,W,H lh=LH lines=N cut=0|1 built=B", "diff N add|del|same X,Y,W syn=… T" for each row
#   wholly in the block, "expand X,Y,W,H" when cut; print-agent-rows-fit (fit 1): "  diff X,Y,W,H" and
#   "  expand X,Y,W,H"
FN agdiff_lines
    PROLOGUE 32
    mov r14, rdi
    mov r12, rsi
    mov [rsp], edx
    mov [rsp + 4], ecx
    mov [rsp + 8], r8d
    mov [rsp + 12], r9d
    mov rdi, rsi
    mov esi, r8d
    call ad_prep
    test rax, rax
    jz 9f
    mov rbx, rax
    mov eax, [rbx + AD_h]
    test eax, eax
    jz 9f
    mov [rsp + 16], eax
    cmp dword ptr [rsp + 12], 0
    je 2f
    mov rdi, r14                # the fit: the block, the chip
    lea rsi, [rip + .Lf_diff]
    call sb_push_cstr
    mov rdi, r14
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 16]
    call push_rect
    mov rdi, r14
    mov esi, 10
    call sb_push_byte
    lea r15, [rip + .Lf_expand]
    jmp 5f
2:  mov rdi, r14
    lea rsi, [rip + .Ld_box]
    call sb_push_cstr
    mov rdi, r14
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 16]
    call push_rect
    mov rdi, r14
    lea rsi, [rip + .Ld_lh]
    call sb_push_cstr
    call agrow_code_face
    mov esi, [rax + FACE_lineh]
    mov rdi, r14
    call sb_push_u64
    mov rdi, r14
    lea rsi, [rip + .Ld_lines]
    call sb_push_cstr
    mov rdi, r14
    mov esi, [rbx + AD_n]
    call sb_push_u64
    mov rdi, r14
    lea rsi, [rip + .Ld_cut]
    call sb_push_cstr
    mov rdi, r14
    mov esi, [rbx + AD_cut]
    call sb_push_u64
    mov rdi, r14
    lea rsi, [rip + .Ld_built]
    call sb_push_cstr
    mov rdi, r14
    mov esi, [rip + ad_built]
    call sb_push_u64
    mov rdi, r14
    mov esi, 10
    call sb_push_byte
    mov rdi, r12                # its rows
    mov rsi, rbx
    mov edx, [rsp]
    mov ecx, [rsp + 4]
    mov r8d, [rsp + 8]
    call wk_setup
    call pad
    mov ecx, [rsp + 16]
    sub ecx, eax
    mov [rip + wk_limit], ecx
    mov eax, [rsp + 4]
    add eax, [rsp + 16]
    mov [rip + wk_bot], eax
    mov [rip + wk_sb], r14
    mov dword ptr [rip + wk_mode], WK_DUMP
    call ad_walk
    mov dword ptr [rip + wk_mode], WK_MEASURE
    lea r15, [rip + .Ld_expand]
5:  cmp dword ptr [rbx + AD_cut], 0
    je 9f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 16]
    call chip_box
    cmp dword ptr [rip + chip_w], 0
    je 9f
    mov rdi, r14
    mov rsi, r15
    call sb_push_cstr
    mov rdi, r14
    mov esi, [rip + chip_x]
    mov edx, [rip + chip_y]
    mov ecx, [rip + chip_w]
    mov r8d, [rip + chip_h]
    call push_rect
    mov rdi, r14
    mov esi, 10
    call sb_push_byte
9:  EPILOGUE

.section .rodata
.p2align 3
kind_words: .quad .Lk_same, .Lk_del, .Lk_add
sign_words: .quad .Ls_same, .Ls_del, .Ls_add
.Lk_same: .asciz " same "
.Lk_del: .asciz " del "
.Lk_add: .asciz " add "
.Ls_same: .asciz "= "
.Ls_del: .asciz "- "
.Ls_add: .asciz "+ "
.Lplus: .asciz "+"
.Lminus: .asciz "-"
.Lexpand: .asciz "Click to expand"
.Ld_diff: .asciz "diff "
.Ld_syn: .asciz " syn="
.Ld_counts: .asciz "diff +"
.Ld_minus: .asciz " -"
.Ld_box: .asciz "diffbox "
.Ld_lh: .asciz " lh="
.Ld_lines: .asciz " lines="
.Ld_cut: .asciz " cut="
.Ld_built: .asciz " built="
.Ld_expand: .asciz "expand "
.Lf_diff: .asciz "  diff "
.Lf_expand: .asciz "  expand "
