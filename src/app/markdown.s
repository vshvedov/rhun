# Markdown documents rendered natively (views design 3.9): a parser into blocks and styled runs, a
# layout at a width in the interface faces, and drawing with link hit testing. Built-in code and
# the doc views use the same API:
#
#   m = md_new(ptr, len)                    parse a copy of the text
#   h = md_layout(m, width)                 lay it out (cached for the same width and faces)
#   w = md_measure(m, max)                  the widest line laid out at max (sizing a popup)
#   i = md_draw(m, x, y, w, h, scroll, id)  draw its part in view; the link clicked, or -1 (links
#                                           are buttons id .. id + 4095)
#   md_link(m, i) -> ptr, len               a link's target; md_open_link(m, i) -> 1 when rhun
#                                           followed it (http, https: the browser; rhun://: a tab;
#                                           a file relative to the base: a tab)
#   md_set_base(m, ptr, len)                the absolute folder relative links name
#   m = md_from_body(ext, ptr, len)         a rich-document body ("doc LEN" + Markdown, "base
#                                           LEN" + folder: views design 3.8.4), or 0
#   md_free(m)
#
# Blocks: ATX and setext headings, paragraphs (soft wrap, hard breaks), bullet and ordered lists
# nested by indentation, task items, block quotes, fenced and indented code (colored with rhun's
# grammars by the info string's first word), thematic breaks, pipe tables, reference definitions,
# hidden HTML comments. Inline: emphasis, strong, strikethrough, code spans, links (inline,
# reference, autolinks, bare http(s) URLs), images (their alt text, as a link), backslash escapes
# and the entities &amp; &lt; &gt; &quot; &apos; &nbsp; &#N; &#xN;. Other HTML shows as text.
.include "rhun.inc"

.equ MDB_PARA, 1
.equ MDB_HEAD, 2
.equ MDB_CODE, 3
.equ MDB_RULE, 4
.equ MDB_TROW, 5

.equ MS_STRONG, 1
.equ MS_EM, 2
.equ MS_CODE, 4
.equ MS_STRIKE, 8
.equ MS_LINK, 16
.equ MS_IMAGE, 32
.equ MS_BREAK, 64               # a hard line break (a run without text)
.equ MS_CELL, 128               # a table cell ends here (a run without text)

.equ MDK_TEXT, 1
.equ MDK_FILL, 2
.equ MDK_DOT, 3
.equ MDK_BOX, 4                 # a task item's box; MDI_style 1 when checked
.equ MDK_LINE, 5                # a 1 px line (strikethrough, underline, rules)
.equ MDK_IMAGE, 6               # an image; MDI_style its MD_imgs entry
.equ MDK_COPY, 7                # a code block's native Copy button; MDI_link its action
.equ MDL_COPY, 0x80000000       # a link's length flag: copy code, never follow its text as a URL
.equ MD_IMG_FILE_MAX, 8388608   # an image file's bytes
.equ MD_IMG_SIDE_MAX, 4096
.equ MD_IMG_BYTES, 33554432     # decoded images per document

.equ MDF_UI, 0
.equ MDF_SMALL, 1
.equ MDF_BIG, 2
.equ MDF_HUGE, 3
.equ MDF_CODE, 4
.equ MDF_EM, 5                  # emphasis: the ui face sheared (em_face)

.equ MD_LISTS, 8                # nesting kept for lists
.equ MD_COLS, 32                # table columns
.equ MD_LINKS_MAX, 4096
.equ MD_DOC_MAX, 1048576         # a rich-document body's Markdown

# a document
STRUCT
F MD_src, SB_SIZE       # the text, LF line ends, ending with LF
F MD_text, SB_SIZE      # what runs show (escapes and entities decoded), link targets, code
F MD_blocks, VEC_SIZE   # MDB
F MD_runs, VEC_SIZE     # MDR
F MD_links, VEC_SIZE    # MDL
F MD_refs, VEC_SIZE     # MDF
F MD_items, VEC_SIZE    # MDI: the layout
F MD_width, 4           # the width laid out, -1 none yet
F MD_height, 4
F MD_maxw, 4            # the widest line laid out
F MD_gen, 4             # g_face_gen when laid out
F MD_hover, 4           # the link under the pointer last frame, -1
F MD_pad, 4
F MD_base, 8            # cstr, mem_alloc'd: the folder relative links name (md_set_base), or 0
F MD_ext, 8             # the extension whose img: handles images name (md_from_body), or 0
F MD_focus, 4           # the link the keyboard is on (drawn as hovered), -1
F MD_imgbytes, 4        # its decoded images' bytes
F MD_sa, 4              # the selection: its anchor (a text item, a byte in it) and its end
F MD_sao, 4
F MD_sb, 4
F MD_sbo, 4
F MD_sel, 4             # 1 while there is a selection (it may be empty)
F MD_drag, 4            # the left button selects
F MD_slugs, SB_SIZE     # its headings' slugs, made once (build_slugs): the bytes
F MD_slugv, VEC_SIZE    # and per heading: offset, length, block (u32 each, 16 bytes)
F MD_slugh, 8           # an open-addressing table of MD_slugv index + 1
F MD_slughcap, 4
F MD_slugdone, 4
F MD_imgs, VEC_SIZE     # MDM: images, resolved when first laid out
ENDSTRUCT MD_SIZE

# an image (MD_imgs)
STRUCT
F MDM_link, 4           # its link (the source)
F MDM_kind, 4           # 0 none (its alt text shows), 1 an img: handle, 2 a file decoded
F MDM_id, 4             # the handle
F MDM_w, 4              # its size, pixels
F MDM_h, 4
F MDM_pad, 4
F MDM_img, IMG_SIZE     # a file's pixels
ENDSTRUCT MDM_SIZE

# a block
STRUCT
F MDB_type, 4
F MDB_level, 4          # a heading's 1-6
F MDB_quote, 4          # block quote depth
F MDB_list, 4           # list depth
F MDB_marker, 4         # its list item's marker: 0 none, 1 bullet, 2 ordered, 3 task, 4 task done
F MDB_num, 4            # an ordered item's number
F MDB_run0, 4
F MDB_nrun, 4
F MDB_line, 4           # its first source line, from 0
F MDB_tbl, 4            # a table row: its header row's block
F MDB_lang, 4           # code: the info word (in MD_text), and the code
F MDB_langlen, 4
F MDB_code, 4
F MDB_codelen, 4
F MDB_ncols, 4          # a table header: its columns, and their aligns (2 bits each: 0 left 1 center 2 right)
F MDB_aligns, 4
F MDB_hdr, 4            # 1 for a table's header row
F MDB_y, 4              # its top, laid out
F MDB_copy, 4           # code: its Copy action's link index, -1 without one
ENDSTRUCT MDB_SIZE

# a run of text in one style
STRUCT
F MDR_off, 4            # in MD_text
F MDR_len, 4
F MDR_style, 4          # MS_*
F MDR_link, 4           # its link, -1
ENDSTRUCT MDR_SIZE

# a link's target
STRUCT
F MDL_off, 4            # in MD_text
F MDL_len, 4            # length, with MDL_COPY for a code block's native Copy action
ENDSTRUCT MDL_SIZE

# a reference definition
STRUCT
F MDF_label, 4          # in MD_src
F MDF_labellen, 4
F MDF_url, 4
F MDF_urllen, 4
ENDSTRUCT MDF_SIZE

# a layout item
STRUCT
F MDI_kind, 4           # MDK_*
F MDI_x, 4
F MDI_y, 4              # its top
F MDI_w, 4
F MDI_h, 4
F MDI_color, 4          # a theme slot
F MDI_face, 4           # MDF_*
F MDI_style, 4          # MS_* (a box: checked)
F MDI_off, 4            # its text in MD_text
F MDI_len, 4
F MDI_link, 4           # -1
F MDI_base, 4           # the baseline below its top
ENDSTRUCT MDI_SIZE

.bss
.p2align 3
pm: .quad 0                     # the document being parsed or laid out
body_rr: .zero RR_SIZE          # md_from_body's record
em_face: .zero FACE_SIZE        # emphasis: the ui face, oblique (em_face_init)
slug_buf: .zero SB_SIZE         # md_anchor: a heading's slug, and an earlier one's
slug_buf2: .zero SB_SIZE
hc_mem: .zero 96                # has_closer's failures: ptr, len, from, n for * _ ~
hc_from: .quad 0
rel_buf: .zero 4096             # a relative link's path
pb: .zero SB_SIZE               # a paragraph's lines, joined with LF (\x01 before a hard break)
cb: .zero SB_SIZE               # a code block's lines
line_no: .long 0
para_open: .long 0
para_line: .long 0
para_quote: .long 0
para_list: .long 0
para_marker: .long 0
para_num: .long 0
code_marker: .long 0
code_num: .long 0
code_open: .long 0              # 1 fenced, 2 indented
code_fch: .long 0               # the fence's character, length, indent
code_flen: .long 0
code_find: .long 0
code_quote: .long 0
code_list: .long 0
code_line: .long 0
code_lang: .long 0              # its info word in MD_text
code_langlen: .long 0
comment_open: .long 0
tbl_open: .long 0
tbl_hdr: .long 0                # the header row's block
tbl_quote: .long 0
skip_next: .long 0              # the table's alignment row follows
pend_marker: .long 0            # the next block's list marker and number
pend_num: .long 0
ls_n: .long 0                   # lists open: marker and content columns, for one quote depth
ls_quote: .long 0
ls_marker: .zero 4 * MD_LISTS
ls_content: .zero 4 * MD_LISTS
cur_quote: .long 0
cur_line_end: .quad 0           # the line being parsed ends here (MD_src offsets)
.p2align 3
# inline parsing
in_style: .long 0               # the style of what is emitted
in_depth: .long 0               # nested link parsing
run_floor: .long 0              # runs before this one belong to an earlier block: never extended
ref_collect: .long 0            # ref_def keeps what it finds (the first pass), else only skips it
.p2align 3
# layout
lay_y: .long 0
lay_x: .long 0
lay_x0: .long 0
lay_right: .long 0
lay_face: .long 0               # the block's face
lay_color: .long 0
lay_lineh: .long 0
lay_base: .long 0
lay_bold: .long 0
col_w: .zero 4 * MD_COLS        # a table's column widths
col_x: .zero 4 * MD_COLS
cls_buf: .zero 4096             # a code line's classes
tbuf: .zero 64

.data
.p2align 2
em_gen: .long -1                # g_face_gen when em_face was made, -1 never
in_link: .long -1

.text

# ---------------- the API ----------------

# md_new(ptr, len) -> rax a parsed document (md_free it)
FN md_new
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov edi, MD_SIZE
    call mem_alloc
    mov rbx, rax
    mov rdi, rbx
    xor esi, esi
    mov edx, MD_SIZE
    call memset
    mov dword ptr [rbx + MD_width], -1
    mov dword ptr [rbx + MD_hover], -1
    mov dword ptr [rbx + MD_focus], -1
    # the text: CR LF and CR become LF, a LF at the end
    xor r14d, r14d
1:  cmp r14, r13
    jae 3f
    movzx esi, byte ptr [r12 + r14]
    inc r14
    cmp esi, 13
    jne 2f
    mov esi, 10
    cmp r14, r13
    jae 2f
    cmp byte ptr [r12 + r14], 10
    jne 2f
    inc r14                     # CR LF: one LF
2:  lea rdi, [rbx + MD_src]
    call sb_push_byte
    jmp 1b
3:  mov rax, [rbx + MD_src + SB_len]
    test rax, rax
    jz 4f
    mov rcx, [rbx + MD_src + SB_ptr]
    cmp byte ptr [rcx + rax - 1], 10
    je 5f
4:  lea rdi, [rbx + MD_src]
    mov esi, 10
    call sb_push_byte
5:  mov rdi, rbx
    call md_parse
    mov rax, rbx
    EPILOGUE

# md_free(m)
FN md_free
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    lea rdi, [rbx + MD_src]
    call sb_free
    lea rdi, [rbx + MD_text]
    call sb_free
    lea rdi, [rbx + MD_blocks]
    call vec_free
    lea rdi, [rbx + MD_runs]
    call vec_free
    lea rdi, [rbx + MD_links]
    call vec_free
    lea rdi, [rbx + MD_refs]
    call vec_free
    lea rdi, [rbx + MD_items]
    call vec_free
    xor r12d, r12d              # decoded files
1:  cmp r12, [rbx + MD_imgs + VEC_len]
    jae 2f
    imul rdi, r12, MDM_SIZE
    add rdi, [rbx + MD_imgs + VEC_ptr]
    cmp dword ptr [rdi + MDM_kind], 2
    jne 11f
    add rdi, MDM_img
    call image_free
11: inc r12
    jmp 1b
2:  lea rdi, [rbx + MD_imgs]
    call vec_free
    lea rdi, [rbx + MD_slugs]
    call sb_free
    lea rdi, [rbx + MD_slugv]
    call vec_free
    mov rdi, [rbx + MD_slugh]
    call mem_free
    mov rdi, [rbx + MD_base]
    call mem_free
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# md_link(m, i) -> rax ptr, rdx len of the link's target (0, 0 for no such link)
FN md_link
    xor eax, eax
    xor edx, edx
    cmp rsi, [rdi + MD_links + VEC_len]
    jae 9f
    mov rax, [rdi + MD_links + VEC_ptr]
    mov ecx, [rax + rsi*8 + MDL_off]
    mov edx, [rax + rsi*8 + MDL_len]
    and edx, 0x7fffffff
    mov rax, [rdi + MD_text + SB_ptr]
    add rax, rcx
9:  ret

# md_open_link(m, i) -> eax 1 when rhun followed it: http and https in the browser, rhun:// in rhun
FN md_open_link
    PROLOGUE
    mov r14, rdi
    cmp rsi, [rdi + MD_links + VEC_len]
    jae 8f
    mov rax, [rdi + MD_links + VEC_ptr]
    test dword ptr [rax + rsi*8 + MDL_len], MDL_COPY
    jnz .Lmol_copy
    call md_link
    test rdx, rdx
    jz 8f
    cmp rdx, 500
    ja 8f
    mov r12, rax
    mov r13, rdx
    mov rdi, r12                # a cstr of it
    mov rsi, r13
    call mem_dup
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lp_http]
    call starts_with
    test eax, eax
    jnz 1f
    mov rdi, rbx
    lea rsi, [rip + .Lp_https]
    call starts_with
    test eax, eax
    jnz 1f
    mov rdi, rbx
    lea rsi, [rip + .Lp_rhun]
    call starts_with
    test eax, eax
    jz 7f
    mov rdi, rbx
    call app_open_path
    jmp 6f
1:  mov rdi, rbx
    call desktop_open
6:  mov rdi, rbx
    call mem_free
    mov eax, 1
    EPILOGUE
7:  mov rdi, r14                # a file relative to the base
    mov rsi, rbx
    call open_relative
    mov r15d, eax
    mov rdi, rbx
    call mem_free
    mov eax, r15d
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
.Lmol_copy:
    call md_link
    # A code block ends in LF for layout. Leave it off the clipboard so a command pasted
    # into a terminal remains available to review before pressing Enter.
    test rdx, rdx
    jz 1f
    cmp byte ptr [rax + rdx - 1], 10
    jne 1f
    dec rdx
1:  mov rdi, rax
    mov rsi, rdx
    xor edx, edx
    call ed_clip_set
    lea rdi, [rip + .Lcopied_code]
    test eax, eax
    jnz 2f
    lea rdi, [rip + .Lcopy_failed]
2:  call app_toast
    mov eax, 1
    EPILOGUE

# open_relative(m, target cstr) -> eax 1 when the target is a path relative to the document's base
#   naming a file, opened in a tab (#fragment and ?query left out, %XX decoded); 0 otherwise
#   (no base, a scheme, a drive, an absolute path, an anchor, a folder, nothing there)
open_relative:
    PROLOGUE
    call build_rel
    test eax, eax
    jz 8f
    lea rdi, [rip + rel_buf]
    call vfs_stat
    test eax, eax
    jnz 8f
    lea rdi, [rip + rel_buf]
    call vfs_is_dir
    test eax, eax
    jnz 8f
    lea rdi, [rip + rel_buf]
    call app_open_path
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# build_rel(m, target cstr) -> eax 1 with rel_buf the base and the target (a path relative to it:
#   #fragment and ?query left out, %XX decoded), 0 when it is not one (no base, a scheme, a drive,
#   an absolute path, an anchor)
build_rel:
    PROLOGUE
    mov rbx, rsi
    mov r12, [rdi + MD_base]
    test r12, r12
    jz 8f
    movzx eax, byte ptr [rbx]
    test eax, eax
    jz 8f
    cmp eax, '#'
    je 8f
    cmp eax, '/'
    je 8f
    cmp eax, '\\'
    je 8f
    mov rcx, rbx                # a ':' before the first '/': a scheme or a drive
1:  movzx eax, byte ptr [rcx]
    test eax, eax
    jz 3f
    cmp eax, ':'
    je 8f
    cmp eax, '/'
    je 3f
    cmp eax, '#'
    je 3f
    cmp eax, '?'
    je 3f
    inc rcx
    jmp 1b
3:  lea rdi, [rip + rel_buf]    # BASE / TARGET
    lea r13, [rdi + 4000]
    mov rsi, r12
4:  movzx eax, byte ptr [rsi]
    test eax, eax
    jz 5f
    cmp rdi, r13
    jae 8f
    mov [rdi], al
    inc rdi
    inc rsi
    jmp 4b
5:  mov byte ptr [rdi], '/'
    inc rdi
    mov rsi, rbx
6:  movzx eax, byte ptr [rsi]
    test eax, eax
    jz 7f
    cmp eax, '#'
    je 7f
    cmp eax, '?'
    je 7f
    cmp rdi, r13
    jae 8f
    cmp eax, '%'
    jne 61f
    movzx eax, byte ptr [rsi + 1]
    call hex_value
    mov r14d, eax
    test eax, eax
    js 62f
    movzx eax, byte ptr [rsi + 2]
    call hex_value
    test eax, eax
    js 62f
    shl r14d, 4
    or eax, r14d
    test eax, eax
    jz 8f                       # %00
    add rsi, 2
    jmp 61f
62: mov eax, '%'
61: mov [rdi], al
    inc rdi
    inc rsi
    jmp 6b
7:  mov byte ptr [rdi], 0
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# md_image(m, link) -> rax its MD_imgs entry, resolved the first time: an img:N handle of the
#   document's extension, or a file under the base (at most 8 MB and 4096 px a side, 32 MB decoded
#   per document); its kind 0 when it is neither (never fetched from the network)
md_image:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    xor ecx, ecx                # resolved before
1:  cmp rcx, [rbx + MD_imgs + VEC_len]
    jae 2f
    imul rax, rcx, MDM_SIZE
    add rax, [rbx + MD_imgs + VEC_ptr]
    cmp [rax + MDM_link], r12d
    je 9f
    inc rcx
    jmp 1b
2:  lea rdi, [rbx + MD_imgs]
    mov esi, MDM_SIZE
    call vec_push
    mov r13, rax
    mov [r13 + MDM_link], r12d
    mov rdi, rbx
    mov esi, r12d
    call md_link
    test rdx, rdx
    jz 8f
    cmp rdx, 1000
    ja 8f
    mov r14, rax
    mov r15, rdx
    cmp r15, 4                  # img:N
    jbe 3f
    cmp dword ptr [r14], 0x3a676d69     # "img:"
    jne 3f
    lea rdi, [r14 + 4]
    lea rsi, [r15 - 4]
    call parse_u64
    lea rcx, [r15 - 4]
    cmp rdx, rcx
    jne 8f
    cmp rax, 0x7fffffff
    ja 8f
    mov [r13 + MDM_id], eax
    mov rdi, [rbx + MD_ext]
    test rdi, rdi
    jz 8f
    mov esi, eax
    call viewimg_size
    test eax, eax
    jz 8f
    mov [r13 + MDM_w], eax
    mov [r13 + MDM_h], edx
    mov dword ptr [r13 + MDM_kind], 1
    jmp 8f
3:  mov rdi, r14                # a file under the base
    mov rsi, r15
    call mem_dup
    mov [rsp], rax
    mov rdi, rbx
    mov rsi, rax
    call build_rel
    mov [rsp + 8], eax
    mov rdi, [rsp]
    call mem_free
    cmp dword ptr [rsp + 8], 0
    je 8f
    lea rdi, [rip + rel_buf]
    call vfs_stat
    test eax, eax
    jnz 8f
    lea rdi, [rip + rel_buf]
    call vfs_is_dir
    test eax, eax
    jnz 8f
    cmp qword ptr [rip + vfs_statbuf + 48], MD_IMG_FILE_MAX     # st_size
    ja 8f
    lea rdi, [rip + rel_buf]
    call vfs_read_all
    test rax, rax
    jz 8f
    mov r14, rax
    mov r15, rdx
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + rel_buf]
    call image_sniff
    test eax, eax
    jz 7f
    mov rdi, r14
    mov rsi, r15
    mov edx, eax
    lea rcx, [r13 + MDM_img]
    call image_decode
    test eax, eax
    jnz 7f
    mov eax, [r13 + MDM_img + IMG_w]
    mov ecx, [r13 + MDM_img + IMG_h]
    cmp eax, MD_IMG_SIDE_MAX
    ja 6f
    cmp ecx, MD_IMG_SIDE_MAX
    ja 6f
    imul eax, ecx
    shl eax, 2
    add eax, [rbx + MD_imgbytes]
    cmp eax, MD_IMG_BYTES
    ja 6f
    mov [rbx + MD_imgbytes], eax
    mov eax, [r13 + MDM_img + IMG_w]
    mov [r13 + MDM_w], eax
    mov eax, [r13 + MDM_img + IMG_h]
    mov [r13 + MDM_h], eax
    mov dword ptr [r13 + MDM_kind], 2
    jmp 7f
6:  lea rdi, [r13 + MDM_img]
    call image_free
7:  mov rdi, r14
    call mem_free
8:  mov rax, r13
9:  EPILOGUE

# image_run(run): an image's first run lays the image out on lines of its own, scaled to the
#   width (never up past the window's scale) -> eax 1; 0 when it cannot be shown (its alt text
#   shows instead)
image_run:
    PROLOGUE 16
    mov r12, rdi
    mov rbx, [rip + pm]
    mov rdi, rbx
    mov esi, [r12 + MDR_link]
    call md_image
    cmp dword ptr [rax + MDM_kind], 0
    je 8f
    mov r13, rax
    sub rax, [rbx + MD_imgs + VEC_ptr]
    xor edx, edx
    mov ecx, MDM_SIZE
    div rcx
    mov [rsp], eax              # its entry
    mov edi, [r13 + MDM_w]      # its size on screen
    call sc
    mov r14d, eax
    mov edi, [r13 + MDM_h]
    call sc
    mov r15d, eax
    mov ecx, [rip + lay_right]
    sub ecx, [rip + lay_x0]
    test ecx, ecx
    jle 8f
    cmp r14d, ecx
    jle 1f
    mov eax, r15d               # narrower: the height in proportion
    imul eax, ecx
    xor edx, edx
    div r14d
    mov r15d, eax
    mov r14d, ecx
1:  test r14d, r14d
    jz 8f
    test r15d, r15d
    jnz 2f
    mov r15d, 1
2:  mov eax, [rip + lay_x]
    cmp eax, [rip + lay_x0]
    je 3f
    call flow_newline
3:  mov edi, MDK_IMAGE
    call item_new
    mov ecx, [rip + lay_x0]
    mov [rax + MDI_x], ecx
    mov ecx, [rip + lay_y]
    mov [rax + MDI_y], ecx
    mov [rax + MDI_w], r14d
    mov [rax + MDI_h], r15d
    mov ecx, [rsp]
    mov [rax + MDI_style], ecx
    add r15d, [rip + g_mt + 4*MI_4]
    add [rip + lay_y], r15d
    mov eax, [rip + lay_x0]
    mov [rip + lay_x], eax
    add eax, r14d
    cmp eax, [rbx + MD_maxw]
    jle 4f
    mov [rbx + MD_maxw], eax
4:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# hex_value(eax a byte) -> eax 0-15, or -1 when it is not a hex digit
hex_value:
    cmp eax, '0'
    jb 8f
    cmp eax, '9'
    jbe 1f
    or eax, 0x20
    cmp eax, 'a'
    jb 8f
    cmp eax, 'f'
    ja 8f
    sub eax, 'a' - 10
    ret
1:  sub eax, '0'
    ret
8:  mov eax, -1
    ret

# md_links(m) -> eax how many links it has
FN md_links
    mov rax, [rdi + MD_links + VEC_len]
    ret

# md_source(m) -> rax its text, a cstr (LF line ends): what it was made from
FN md_source
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + MD_src]     # NUL after the text, past its length
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rbx + MD_src + SB_len]
    mov rax, [rbx + MD_src + SB_ptr]
    pop rbx
    ret

# md_focus(m) -> eax the link the keyboard is on, -1
FN md_focus
    mov eax, [rdi + MD_focus]
    ret

# md_set_ext(m, ext): the extension whose img: handles its images name
FN md_set_ext
    mov [rdi + MD_ext], rsi
    ret

# md_set_focus(m, link or -1): the link the keyboard is on, drawn as hovered
FN md_set_focus
    mov [rdi + MD_focus], esi
    mov dword ptr [rip + g_dirty], 1
    ret

# md_link_y(m, link) -> eax the top of its first item laid out, -1 when it has none
FN md_link_y
    mov eax, -1
    xor ecx, ecx
1:  cmp rcx, [rdi + MD_items + VEC_len]
    jae 9f
    imul rdx, rcx, MDI_SIZE
    add rdx, [rdi + MD_items + VEC_ptr]
    cmp [rdx + MDI_link], esi
    je 2f
    inc rcx
    jmp 1b
2:  mov eax, [rdx + MDI_y]
9:  ret

# md_line_y(m, line from 0) -> eax the top of the block holding that source line (the last block
#   starting at or before it), 0 for none
FN md_line_y
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, [rdi + MD_blocks + VEC_len]
    jae 9f
    imul rdx, rcx, MDB_SIZE
    add rdx, [rdi + MD_blocks + VEC_ptr]
    cmp [rdx + MDB_line], esi
    jg 9f
    mov eax, [rdx + MDB_y]
    inc rcx
    jmp 1b
9:  ret

# md_y_line(m, y) -> eax the first source line of the block at y (the last one starting at or
#   above it), -1 for none
FN md_y_line
    mov eax, -1
    xor ecx, ecx
1:  cmp rcx, [rdi + MD_blocks + VEC_len]
    jae 9f
    imul rdx, rcx, MDB_SIZE
    add rdx, [rdi + MD_blocks + VEC_ptr]
    cmp [rdx + MDB_y], esi
    jg 9f
    mov eax, [rdx + MDB_line]
    inc rcx
    jmp 1b
9:  ret

# md_anchor(m, ptr, len) -> eax the top of the heading whose slug is the text (a leading # left
#   out), -1 for none. Slugs follow GitHub: lowercase, letters, digits, - and _ kept, spaces to -,
#   other ASCII left out; a slug already given (a suffixed one too) gets -1, -2, ... until it is
#   new, in document order. They are made once per document and found by hash.
FN md_anchor
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz 8f
    cmp byte ptr [r12], '#'
    jne 1f
    inc r12
    dec r13
1:  cmp dword ptr [rbx + MD_slugdone], 0
    jne 2f
    mov rdi, rbx
    call build_slugs
2:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call slug_find
    test eax, eax
    js 8f
    shl rax, 4
    add rax, [rbx + MD_slugv + VEC_ptr]
    mov eax, [rax + 8]          # its block
    imul rax, rax, MDB_SIZE
    add rax, [rbx + MD_blocks + VEC_ptr]
    mov eax, [rax + MDB_y]
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# build_slugs(m): every heading's slug, unique in document order, into MD_slugs/slugv/slugh
build_slugs:
    PROLOGUE 16
    mov rbx, rdi
    mov dword ptr [rbx + MD_slugdone], 1
    xor ecx, ecx                # headings: the table twice as big, a power of two
    xor edx, edx
1:  cmp rdx, [rbx + MD_blocks + VEC_len]
    jae 2f
    imul rax, rdx, MDB_SIZE
    add rax, [rbx + MD_blocks + VEC_ptr]
    cmp dword ptr [rax + MDB_type], MDB_HEAD
    jne 11f
    inc ecx
11: inc rdx
    jmp 1b
2:  lea ecx, [rcx + rcx + 2]
    mov eax, 16
3:  cmp eax, ecx
    jae 4f
    shl eax, 1
    jmp 3b
4:  mov [rbx + MD_slughcap], eax
    mov rdi, rax
    shl rdi, 2
    call mem_alloc
    mov [rbx + MD_slugh], rax
    mov rdi, rax
    xor esi, esi
    mov edx, [rbx + MD_slughcap]
    shl edx, 2
    call memset
    xor r14d, r14d              # block
5:  cmp r14, [rbx + MD_blocks + VEC_len]
    jae 9f
    imul rax, r14, MDB_SIZE
    add rax, [rbx + MD_blocks + VEC_ptr]
    cmp dword ptr [rax + MDB_type], MDB_HEAD
    jne 8f
    mov rdi, rbx                # its base slug
    mov esi, r14d
    lea rdx, [rip + slug_buf]
    call heading_slug
    xor r15d, r15d              # the suffix tried: none, then 1, 2, ...
6:  lea rdi, [rip + slug_buf2]
    call sb_clear
    lea rdi, [rip + slug_buf2]
    mov rsi, [rip + slug_buf + SB_ptr]
    mov rdx, [rip + slug_buf + SB_len]
    call sb_push
    test r15d, r15d
    jz 61f
    lea rdi, [rip + slug_buf2]
    mov esi, '-'
    call sb_push_byte
    lea rdi, [rip + slug_buf2]
    mov esi, r15d
    call sb_push_u64
61: mov rdi, rbx
    mov rsi, [rip + slug_buf2 + SB_ptr]
    mov rdx, [rip + slug_buf2 + SB_len]
    call slug_find
    test eax, eax
    js 7f
    inc r15d
    jmp 6b
7:  lea rdi, [rbx + MD_slugv]   # given: its entry, its bytes, its place in the table
    mov esi, 16
    call vec_push
    mov r12, rax
    mov rcx, [rbx + MD_slugs + SB_len]
    mov [r12], ecx
    mov rcx, [rip + slug_buf2 + SB_len]
    mov [r12 + 4], ecx
    mov [r12 + 8], r14d
    lea rdi, [rbx + MD_slugs]
    mov rsi, [rip + slug_buf2 + SB_ptr]
    mov rdx, [rip + slug_buf2 + SB_len]
    call sb_push
    mov rdi, [rip + slug_buf2 + SB_ptr]
    mov rsi, [rip + slug_buf2 + SB_len]
    call tree_id_hash
    mov ecx, [rbx + MD_slughcap]
    dec ecx
    and eax, ecx
    mov rdx, [rbx + MD_slugh]
71: cmp dword ptr [rdx + rax*4], 0
    je 72f
    inc eax
    and eax, ecx
    jmp 71b
72: mov rsi, [rbx + MD_slugv + VEC_len]   # its index + 1
    mov [rdx + rax*4], esi
8:  inc r14
    jmp 5b
9:  EPILOGUE

# slug_find(m, ptr, len) -> eax the MD_slugv index of that slug, or -1
slug_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp qword ptr [rbx + MD_slugh], 0
    je 8f
    mov rdi, r12
    mov rsi, r13
    call tree_id_hash
    mov r14d, [rbx + MD_slughcap]
    dec r14d
    and eax, r14d
    mov r15d, eax
1:  mov rax, [rbx + MD_slugh]
    mov eax, [rax + r15*4]
    test eax, eax
    jz 8f
    dec eax
    mov ecx, eax
    shl rax, 4
    add rax, [rbx + MD_slugv + VEC_ptr]
    mov edx, [rax + 4]
    cmp rdx, r13
    jne 2f
    mov esi, [rax]
    add rsi, [rbx + MD_slugs + SB_ptr]
    mov rdi, r12
    push rcx
    mov rcx, r13
    cmp rcx, rcx                # equal when empty
    repe cmpsb
    pop rcx
    jne 2f
    mov eax, ecx
    EPILOGUE
2:  inc r15d
    and r15d, r14d
    jmp 1b
8:  mov eax, -1
    EPILOGUE

# heading_slug(m, block, sb): the heading's slug in sb (before any -N)
heading_slug:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov rdi, r13
    call sb_clear
    imul r14, r12, MDB_SIZE
    add r14, [rbx + MD_blocks + VEC_ptr]
    xor r15d, r15d
1:  cmp r15d, [r14 + MDB_nrun]
    jae 9f
    mov eax, [r14 + MDB_run0]
    add eax, r15d
    imul rax, rax, MDR_SIZE
    add rax, [rbx + MD_runs + VEC_ptr]
    mov esi, [rax + MDR_off]
    mov edx, [rax + MDR_len]
    add rsi, [rbx + MD_text + SB_ptr]
    mov [rsp], rsi
    mov [rsp + 8], edx
    xor ecx, ecx
2:  cmp ecx, [rsp + 8]
    jae 3f
    mov rsi, [rsp]
    movzx edi, byte ptr [rsi + rcx]
    mov [rsp + 12], ecx
    mov rsi, r13
    call slug_char
    mov ecx, [rsp + 12]
    inc ecx
    jmp 2b
3:  inc r15d
    jmp 1b
9:  EPILOGUE

# slug_char(byte, sb): its part of a slug onto sb
slug_char:
    push rsi
    cmp edi, 0x80
    jae 1f                      # beyond ASCII: kept
    cmp edi, ' '
    jne 2f
    mov edi, '-'
    jmp 1f
2:  lea eax, [rdi - 'A']
    cmp eax, 25
    ja 3f
    or edi, 0x20
    jmp 1f
3:  lea eax, [rdi - 'a']
    cmp eax, 25
    jbe 1f
    lea eax, [rdi - '0']
    cmp eax, 9
    jbe 1f
    cmp edi, '-'
    je 1f
    cmp edi, '_'
    je 1f
    pop rsi
    ret                         # other ASCII: left out
1:  mov esi, edi
    pop rdi
    jmp sb_push_byte

# ---------------- selection ----------------
# Text is selected by text items (words) and bytes in them, in layout order; md_select_mouse gives
# the owner's pointer to it, md_sel_text says what is selected (spaces between words, LF between
# lines).

# md_select_mouse(m, x, y, scroll, ub): the pointer over a document drawn at x, y (md_draw's)
#   with the owner's area button's UB bits: a press anchors, a drag extends, a double click takes
#   the word
FN md_select_mouse
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    cmp qword ptr [rbx + MD_items + VEC_len], 0
    je 9f
    mov esi, [rip + g_mx]
    sub esi, r12d
    mov edx, [rip + g_my]
    sub edx, r13d
    add edx, r14d
    mov rdi, rbx
    call md_hit
    test eax, eax
    js 9f
    test r15d, UB_PRESS
    jz 2f
    mov [rbx + MD_sa], eax
    mov [rbx + MD_sao], edx
    mov [rbx + MD_sb], eax
    mov [rbx + MD_sbo], edx
    mov dword ptr [rbx + MD_sel], 1
    mov dword ptr [rbx + MD_drag], 1
    test r15d, UB_DOUBLE
    jz 1f
    mov dword ptr [rbx + MD_sao], 0     # the word
    imul rcx, rax, MDI_SIZE
    add rcx, [rbx + MD_items + VEC_ptr]
    mov ecx, [rcx + MDI_len]
    mov [rbx + MD_sbo], ecx
    mov dword ptr [rbx + MD_drag], 0
1:  mov dword ptr [rip + g_dirty], 1
    jmp 9f
2:  cmp dword ptr [rbx + MD_drag], 0
    je 9f
    test dword ptr [rip + g_mdown], 1 << BTN_LEFT
    jz 3f
    cmp eax, [rbx + MD_sb]
    jne 21f
    cmp edx, [rbx + MD_sbo]
    je 9f
21: mov [rbx + MD_sb], eax
    mov [rbx + MD_sbo], edx
    mov dword ptr [rip + g_dirty], 1
    jmp 9f
3:  mov dword ptr [rbx + MD_drag], 0
9:  EPILOGUE

# md_hit(m, x, y) -> eax the text item nearest the point (document coordinates), edx the byte in it
#   there; eax -1 without text
md_hit:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov dword ptr [rsp + 8], -1     # the best item
    mov dword ptr [rsp + 12], 0x7fffffff   # its vertical distance
    mov dword ptr [rsp + 16], 0x7fffffff   # and horizontal
    xor r12d, r12d
1:  cmp r12, [rbx + MD_items + VEC_len]
    jae 5f
    imul r13, r12, MDI_SIZE
    add r13, [rbx + MD_items + VEC_ptr]
    cmp dword ptr [r13 + MDI_kind], MDK_TEXT
    jne 4f
    xor ecx, ecx                # vertical distance
    mov eax, [r13 + MDI_y]
    sub eax, [rsp + 4]
    jle 2f
    mov ecx, eax                # below the point
    jmp 3f
2:  mov eax, [rsp + 4]
    sub eax, [r13 + MDI_y]
    sub eax, [r13 + MDI_h]
    jl 3f
    lea ecx, [rax + 1]          # above it
3:  xor edx, edx                # horizontal distance
    mov eax, [r13 + MDI_x]
    sub eax, [rsp]
    jle 31f
    mov edx, eax
    jmp 32f
31: mov eax, [rsp]
    sub eax, [r13 + MDI_x]
    sub eax, [r13 + MDI_w]
    jle 32f
    mov edx, eax
32: cmp ecx, [rsp + 12]
    jg 4f
    jl 33f
    cmp edx, [rsp + 16]
    jge 4f
33: mov [rsp + 8], r12d
    mov [rsp + 12], ecx
    mov [rsp + 16], edx
4:  inc r12
    jmp 1b
5:  mov eax, [rsp + 8]
    test eax, eax
    js 9f
    imul r13, rax, MDI_SIZE
    add r13, [rbx + MD_items + VEC_ptr]
    xor edx, edx
    mov eax, [rsp]
    sub eax, [r13 + MDI_x]
    jle 8f
    mov edx, [r13 + MDI_len]
    cmp eax, [r13 + MDI_w]
    jge 8f
    mov edi, [r13 + MDI_face]   # the bytes left of the point
    call face_of
    mov rdi, rax
    mov rsi, [rbx + MD_text + SB_ptr]
    mov ecx, [r13 + MDI_off]
    add rsi, rcx
    mov edx, [r13 + MDI_len]
    mov ecx, [rsp]
    sub ecx, [r13 + MDI_x]
    call text_fit
    mov edx, eax
8:  mov eax, [rsp + 8]
9:  EPILOGUE

# sel_range(m) -> eax the first selected item, edx its byte, ecx the last item, r8d its end byte
#   (in order); eax -1 when nothing is selected
sel_range:
    mov eax, -1
    cmp dword ptr [rdi + MD_sel], 0
    je 9f
    mov eax, [rdi + MD_sa]
    mov edx, [rdi + MD_sao]
    mov ecx, [rdi + MD_sb]
    mov r8d, [rdi + MD_sbo]
    cmp eax, ecx
    jl 2f
    jg 1f
    cmp edx, r8d
    jl 2f
    je 8f
1:  xchg eax, ecx
    xchg edx, r8d
2:  ret
8:  mov eax, -1                 # empty
9:  ret

# sel_draw(m, x, y, h, scroll): the selected parts of text items, drawn behind them
sel_draw:
    PROLOGUE 64
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov rdi, rbx
    call sel_range
    test eax, eax
    js 9f
    mov [rsp + 16], eax
    mov [rsp + 20], edx
    mov [rsp + 24], ecx
    mov [rsp + 28], r8d
    mov r12d, eax
1:  cmp r12d, [rsp + 24]
    jg 9f
    imul r13, r12, MDI_SIZE
    add r13, [rbx + MD_items + VEC_ptr]
    cmp dword ptr [r13 + MDI_kind], MDK_TEXT
    jne 8f
    mov r14d, [r13 + MDI_y]     # on screen
    sub r14d, [rsp + 12]
    add r14d, [rsp + 4]
    mov eax, r14d
    add eax, [r13 + MDI_h]
    cmp eax, [rsp + 4]
    jl 8f
    mov eax, [rsp + 4]
    add eax, [rsp + 8]
    cmp r14d, eax
    jge 8f
    xor ecx, ecx                # from
    cmp r12d, [rsp + 16]
    jne 2f
    mov ecx, [rsp + 20]
2:  mov r8d, [r13 + MDI_len]    # to
    cmp r12d, [rsp + 24]
    jne 3f
    mov r8d, [rsp + 28]
3:  mov [rsp + 32], ecx
    mov [rsp + 36], r8d
    mov edi, ecx
    call item_x                 # x of a byte in r13's item
    mov [rsp + 40], eax
    mov edi, [rsp + 36]
    call item_x
    sub eax, [rsp + 40]
    jle 8f
    mov edx, eax
    mov edi, [rsp + 40]
    add edi, [r13 + MDI_x]
    add edi, [rsp]
    mov esi, r14d
    mov ecx, [r13 + MDI_h]
    COLOR r8d, T_SELECTION
    call gfx_fill
8:  inc r12d
    jmp 1b
9:  EPILOGUE

# item_x(byte) -> eax its x within r13's text item (rbx the document)
item_x:
    test edi, edi
    jz 8f
    cmp edi, [r13 + MDI_len]
    jae 7f
    push r12
    mov r12d, edi
    mov edi, [r13 + MDI_face]
    call face_of
    mov rdi, rax
    mov rsi, [rbx + MD_text + SB_ptr]
    mov ecx, [r13 + MDI_off]
    add rsi, rcx
    mov edx, r12d
    call text_width
    pop r12
    ret
7:  mov eax, [r13 + MDI_w]
    ret
8:  xor eax, eax
    ret

# md_select_all(m): every text item selected
FN md_select_all
    mov ecx, -1                 # the first and the last text item
    mov edx, -1
    xor r8d, r8d
1:  cmp r8, [rdi + MD_items + VEC_len]
    jae 3f
    imul rax, r8, MDI_SIZE
    add rax, [rdi + MD_items + VEC_ptr]
    cmp dword ptr [rax + MDI_kind], MDK_TEXT
    jne 2f
    cmp ecx, -1
    jne 11f
    mov ecx, r8d
11: mov edx, r8d
2:  inc r8
    jmp 1b
3:  cmp ecx, -1
    je 9f
    mov [rdi + MD_sa], ecx
    mov dword ptr [rdi + MD_sao], 0
    mov [rdi + MD_sb], edx
    imul rax, rdx, MDI_SIZE
    add rax, [rdi + MD_items + VEC_ptr]
    mov eax, [rax + MDI_len]
    mov [rdi + MD_sbo], eax
    mov dword ptr [rdi + MD_sel], 1
    mov dword ptr [rdi + MD_drag], 0
    mov dword ptr [rip + g_dirty], 1
9:  ret

# md_sel_clear(m)
FN md_sel_clear
    mov dword ptr [rdi + MD_sel], 0
    mov dword ptr [rdi + MD_drag], 0
    ret

# md_sel_text(m, sb) -> eax 1 with the selected text appended (words joined by a space where the
#   layout leaves room, lines by LF), 0 when nothing is selected
FN md_sel_text
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp + 40], rsi
    mov rdi, rbx
    call sel_range
    test eax, eax
    js 8f
    mov [rsp], eax
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov dword ptr [rsp + 16], -1    # the last item taken
    mov r12d, eax
1:  cmp r12d, [rsp + 8]
    jg 7f
    imul r13, r12, MDI_SIZE
    add r13, [rbx + MD_items + VEC_ptr]
    cmp dword ptr [r13 + MDI_kind], MDK_TEXT
    jne 6f
    movsxd rax, dword ptr [rsp + 16]    # between it and the one before: LF or a space
    test rax, rax
    js 3f
    imul rax, rax, MDI_SIZE
    add rax, [rbx + MD_items + VEC_ptr]
    mov ecx, [rax + MDI_y]
    cmp ecx, [r13 + MDI_y]
    je 2f
    mov rdi, [rsp + 40]
    mov esi, 10
    call sb_push_byte
    jmp 3f
2:  mov ecx, [rax + MDI_x]
    add ecx, [rax + MDI_w]
    cmp ecx, [r13 + MDI_x]
    jge 3f
    mov rdi, [rsp + 40]
    mov esi, ' '
    call sb_push_byte
3:  xor ecx, ecx                # its bytes in the selection
    cmp r12d, [rsp]
    jne 4f
    mov ecx, [rsp + 4]
4:  mov edx, [r13 + MDI_len]
    cmp r12d, [rsp + 8]
    jne 5f
    mov edx, [rsp + 12]
5:  sub edx, ecx
    jle 51f
    mov rsi, [rbx + MD_text + SB_ptr]
    mov eax, [r13 + MDI_off]
    add rsi, rax
    add rsi, rcx
    mov rdi, [rsp + 40]
    call sb_push
51: mov [rsp + 16], r12d
6:  inc r12d
    jmp 1b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# md_set_base(m, ptr, len): the absolute folder relative links name (a trailing / left out); an
#   empty one clears it
FN md_set_base
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [rbx + MD_base]
    call mem_free
    mov qword ptr [rbx + MD_base], 0
1:  cmp r13, 1
    jbe 2f
    movzx eax, byte ptr [r12 + r13 - 1]
    cmp eax, '/'
    je 11f
    cmp eax, '\\'
    jne 2f
11: dec r13
    jmp 1b
2:  test r13, r13
    jz 9f
    cmp r13, 3000
    ja 9f
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rbx + MD_base], rax
9:  EPILOGUE

# md_from_body(ext, ptr, len) -> rax a document, or 0 when the body is not one "doc LEN" record
#   (Markdown, at most 1 MB) and at most one "base LEN" record (an absolute folder), in any order,
#   after an optional count line ("N" LF, as a patch body has): a rich-document body (views design
#   3.8.4); img: images name ext's handles
FN md_from_body
    PROLOGUE 48
    mov [rsp], rdi
    mov r12, rsi
    lea r13, [rsi + rdx]
    mov qword ptr [rsp + 8], 0  # the doc
    mov qword ptr [rsp + 16], 0
    mov qword ptr [rsp + 24], 0 # the base
    mov qword ptr [rsp + 32], 0
    mov rcx, r12                # a patch body's count line ("N" LF) first is left out
11: cmp rcx, r13
    jae 1f
    movzx eax, byte ptr [rcx]
    cmp eax, 10
    je 12f
    sub eax, '0'
    cmp eax, 9
    ja 1f
    inc rcx
    jmp 11b
12: cmp rcx, r12
    je 1f
    lea r12, [rcx + 1]
1:  cmp r12, r13
    jae 5f
    cmp byte ptr [r12], 10      # blank lines between records
    jne 2f
    inc r12
    jmp 1b
2:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + body_rr]
    call tree_rec_read
    test rax, rax
    jz 8f
    mov r12, rax
    cmp qword ptr [rip + body_rr + RR_n], 2
    jne 8f
    lea rdi, [rip + body_rr]
    xor esi, esi
    lea rdx, [rip + .Lb_doc]
    call tree_rec_is
    test eax, eax
    jz 3f
    cmp qword ptr [rsp + 8], 0
    jne 8f
    mov rax, [rip + body_rr + RR_len]
    cmp rax, MD_DOC_MAX
    ja 8f
    mov [rsp + 16], rax
    mov rax, [rip + body_rr + RR_data]
    mov [rsp + 8], rax
    jmp 1b
3:  lea rdi, [rip + body_rr]
    xor esi, esi
    lea rdx, [rip + .Lb_base]
    call tree_rec_is
    test eax, eax
    jz 8f
    cmp qword ptr [rsp + 24], 0
    jne 8f
    mov rax, [rip + body_rr + RR_data]
    mov [rsp + 24], rax
    mov rax, [rip + body_rr + RR_len]
    mov [rsp + 32], rax
    test rax, rax
    jz 8f
    jmp 1b
5:  mov rdi, [rsp + 8]
    test rdi, rdi
    jz 8f
    mov rsi, [rsp + 16]
    call md_new
    mov rbx, rax
    mov rax, [rsp]
    mov [rbx + MD_ext], rax
    cmp qword ptr [rsp + 24], 0
    je 6f
    mov rdi, rbx
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 32]
    call md_set_base
6:  mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# starts_with(cstr, prefix cstr) -> eax 1 when it does (ASCII case-insensitive)
starts_with:
1:  movzx ecx, byte ptr [rsi]
    test ecx, ecx
    jz 8f
    movzx eax, byte ptr [rdi]
    or eax, 0x20
    or ecx, 0x20
    cmp eax, ecx
    jne 9f
    inc rdi
    inc rsi
    jmp 1b
8:  mov eax, 1
    ret
9:  xor eax, eax
    ret

# ---------------- parsing: blocks ----------------

# md_parse(m): the source into blocks and runs
md_parse:
    PROLOGUE
    mov [rip + pm], rdi
    mov rbx, rdi
    xor eax, eax
    mov [rip + line_no], eax
    mov [rip + para_open], eax
    mov [rip + code_open], eax
    mov [rip + comment_open], eax
    mov [rip + tbl_open], eax
    mov [rip + skip_next], eax
    mov [rip + pend_marker], eax
    mov [rip + ls_n], eax
    mov [rip + ls_quote], eax
    lea rdi, [rip + pb]
    call sb_clear
    lea rdi, [rip + cb]
    call sb_clear
    mov r12, [rbx + MD_src + SB_ptr]
    mov r15, r12
    add r15, [rbx + MD_src + SB_len]    # the end
    call collect_refs           # reference definitions first: links before them use them
    mov r13, r12
1:  cmp r13, r15
    jae 8f
    mov r14, r13                # the line's end: its LF
2:  cmp byte ptr [r14], 10
    je 3f
    inc r14
    jmp 2b
3:  mov [rip + cur_line_end], r14
    mov rdi, r13
    mov rsi, r14
    call parse_line
    inc dword ptr [rip + line_no]
    lea r13, [r14 + 1]
    jmp 1b
8:  call close_all
    EPILOGUE

# close_all(): whatever is open ends
close_all:
    sub rsp, 8
    call close_para
    call close_code
    mov dword ptr [rip + tbl_open], 0
    mov dword ptr [rip + comment_open], 0
    add rsp, 8
    ret

# blk_new(type) -> rax a new block with the context now (its list marker taken)
blk_new:
    PROLOGUE
    mov r12d, edi
    mov rbx, [rip + pm]
    lea rdi, [rbx + MD_blocks]
    mov esi, MDB_SIZE
    call vec_push
    mov [rax + MDB_type], r12d
    mov ecx, [rip + cur_quote]
    mov [rax + MDB_quote], ecx
    mov ecx, [rip + ls_n]
    mov [rax + MDB_list], ecx
    mov ecx, [rip + pend_marker]
    mov [rax + MDB_marker], ecx
    mov ecx, [rip + pend_num]
    mov [rax + MDB_num], ecx
    mov dword ptr [rip + pend_marker], 0
    mov ecx, [rip + line_no]
    mov [rax + MDB_line], ecx
    mov dword ptr [rax + MDB_tbl], -1
    EPILOGUE

# blk_last() -> rax the last block
blk_last:
    mov rax, [rip + pm]
    mov rcx, [rax + MD_blocks + VEC_len]
    dec rcx
    imul rcx, rcx, MDB_SIZE
    mov rax, [rax + MD_blocks + VEC_ptr]
    add rax, rcx
    ret

# close_para(): an open paragraph becomes a block
close_para:
    PROLOGUE
    cmp dword ptr [rip + para_open], 0
    je 9f
    mov dword ptr [rip + para_open], 0
    mov eax, [rip + cur_quote]  # its context is the one it opened in
    push rax
    push rax
    mov eax, [rip + para_quote]
    mov [rip + cur_quote], eax
    mov r12d, [rip + ls_n]
    mov eax, [rip + para_list]
    mov [rip + ls_n], eax
    mov edi, MDB_PARA
    call blk_new
    mov rbx, rax
    mov [rip + ls_n], r12d
    pop rax
    pop rax
    mov [rip + cur_quote], eax
    mov eax, [rip + para_line]
    mov [rbx + MDB_line], eax
    mov eax, [rip + para_marker]
    mov [rbx + MDB_marker], eax
    mov eax, [rip + para_num]
    mov [rbx + MDB_num], eax
    mov rdi, [rip + pb + SB_ptr]
    mov rsi, [rip + pb + SB_len]
    call inline_runs
    mov [rbx + MDB_run0], eax
    mov [rbx + MDB_nrun], edx
    lea rdi, [rip + pb]
    call sb_clear
9:  EPILOGUE

# close_code(): an open code block becomes a block (trailing blank lines left out)
close_code:
    PROLOGUE
    cmp dword ptr [rip + code_open], 0
    je 9f
    mov dword ptr [rip + code_open], 0
    # trailing LFs off: the text ends with one
    mov rcx, [rip + cb + SB_len]
1:  cmp rcx, 1
    jb 2f
    mov rax, [rip + cb + SB_ptr]
    cmp byte ptr [rax + rcx - 1], 10
    jne 2f
    cmp rcx, 2
    jb 11f
    cmp byte ptr [rax + rcx - 2], 10
    jne 2f
11: dec rcx
    jmp 1b
2:  mov [rip + cb + SB_len], rcx
    mov eax, [rip + cur_quote]
    push rax
    push rax
    mov eax, [rip + code_quote]
    mov [rip + cur_quote], eax
    mov r12d, [rip + ls_n]
    mov eax, [rip + code_list]
    mov [rip + ls_n], eax
    mov edi, MDB_CODE
    call blk_new
    mov rbx, rax
    mov [rip + ls_n], r12d
    pop rax
    pop rax
    mov [rip + cur_quote], eax
    mov eax, [rip + code_line]
    mov [rbx + MDB_line], eax
    mov eax, [rip + code_marker]
    mov [rbx + MDB_marker], eax
    mov eax, [rip + code_num]
    mov [rbx + MDB_num], eax
    mov eax, [rip + code_lang]
    mov [rbx + MDB_lang], eax
    mov eax, [rip + code_langlen]
    mov [rbx + MDB_langlen], eax
    mov r13, [rip + pm]
    mov rax, [r13 + MD_text + SB_len]
    mov [rbx + MDB_code], eax
    mov rax, [rip + cb + SB_len]
    mov [rbx + MDB_codelen], eax
    lea rdi, [r13 + MD_text]
    mov rsi, [rip + cb + SB_ptr]
    mov rdx, [rip + cb + SB_len]
    call sb_push
    mov dword ptr [rbx + MDB_copy], -1
    cmp qword ptr [r13 + MD_links + VEC_len], MD_LINKS_MAX
    jae 3f
    cmp dword ptr [rbx + MDB_codelen], 0
    je 3f
    lea rdi, [r13 + MD_links]
    mov esi, MDL_SIZE
    call vec_push
    mov ecx, [rbx + MDB_code]
    mov [rax + MDL_off], ecx
    mov ecx, [rbx + MDB_codelen]
    or ecx, MDL_COPY
    mov [rax + MDL_len], ecx
    mov rax, [r13 + MD_links + VEC_len]
    dec eax
    mov [rbx + MDB_copy], eax
3:
    lea rdi, [rip + cb]
    call sb_clear
9:  EPILOGUE

# indent(p, end) -> eax columns of spaces (a tab to the next multiple of 4), rdx the first other byte
indent:
    xor eax, eax
    mov rdx, rdi
1:  cmp rdx, rsi
    jae 9f
    cmp byte ptr [rdx], ' '
    jne 2f
    inc eax
    inc rdx
    jmp 1b
2:  cmp byte ptr [rdx], 9
    jne 9f
    add eax, 4
    and eax, -4
    inc rdx
    jmp 1b
9:  ret

# skip_cols(p, end, n) -> rax p past n columns of spaces (fewer when the line has fewer)
skip_cols:
1:  test edx, edx
    jle 9f
    cmp rdi, rsi
    jae 9f
    cmp byte ptr [rdi], ' '
    je 2f
    cmp byte ptr [rdi], 9
    jne 9f
    sub edx, 4
    inc rdi
    jmp 1b
2:  dec edx
    inc rdi
    jmp 1b
9:  mov rax, rdi
    ret

# parse_line(start, end): one source line (end at its LF)
parse_line:
    PROLOGUE 48
    mov r13, rdi
    mov r14, rsi
    mov rbx, [rip + pm]
    cmp dword ptr [rip + skip_next], 0
    je 1f
    mov dword ptr [rip + skip_next], 0
    jmp .Lpl_ret
1:  # an HTML comment still open
    cmp dword ptr [rip + comment_open], 0
    je 2f
    mov rdi, r13
    mov rsi, r14
    call find_comment_end
    test rax, rax
    jz .Lpl_ret
    mov dword ptr [rip + comment_open], 0
    jmp .Lpl_ret
2:  # block quote markers
    xor r12d, r12d              # depth
    mov r15, r13
3:  mov rdi, r15
    mov rsi, r14
    call indent
    cmp eax, 3
    ja 4f
    cmp rdx, r14
    jae 4f
    cmp byte ptr [rdx], '>'
    jne 4f
    inc r12d
    lea r15, [rdx + 1]
    cmp r15, r14
    jae 3b
    cmp byte ptr [r15], ' '
    jne 3b
    inc r15
    jmp 3b
4:  # a fenced code block: its fence closes it (or a shallower quote does)
    cmp dword ptr [rip + code_open], 1
    jne .Lpl_noquote_change
    cmp r12d, [rip + code_quote]
    jb .Lpl_close_code_first
    mov rdi, r15
    mov rsi, r14
    call indent
    mov [rsp], rdx
    cmp eax, 3
    ja .Lpl_codeline
    mov rcx, rdx                # the closing fence: as many or more of its character, then blanks
    xor r8d, r8d
41: cmp rcx, r14
    jae 42f
    movzx eax, byte ptr [rcx]
    cmp eax, [rip + code_fch]
    jne 42f
    inc r8d
    inc rcx
    jmp 41b
42: cmp r8d, [rip + code_flen]
    jb .Lpl_codeline
43: cmp rcx, r14
    jae 44f
    cmp byte ptr [rcx], ' '
    je 431f
    cmp byte ptr [rcx], 9
    jne .Lpl_codeline
431:inc rcx
    jmp 43b
44: call close_code
    jmp .Lpl_ret
.Lpl_codeline:
    # the line's content: the fence's indent left out
    mov eax, [rip + code_list]
    test eax, eax
    jz 45f
    mov rdi, r15                # inside a list item: its content column too
    mov rsi, r14
    mov ecx, eax
    dec ecx
    lea rax, [rip + ls_content]
    mov edx, [rax + rcx*4]
    call skip_cols
    mov r15, rax
45: mov rdi, r15
    mov rsi, r14
    mov edx, [rip + code_find]
    call skip_cols
    lea rdi, [rip + cb]
    mov rsi, rax
    mov rdx, r14
    sub rdx, rax
    call sb_push
    lea rdi, [rip + cb]
    mov esi, 10
    call sb_push_byte
    jmp .Lpl_ret
.Lpl_close_code_first:
    call close_code
.Lpl_noquote_change:
    # the quote depth changed: a paragraph may continue lazily into fewer markers; lists are per depth
    mov [rip + cur_quote], r12d
    cmp r12d, [rip + ls_quote]
    je 5f
    cmp dword ptr [rip + para_open], 0
    je 51f
    cmp r12d, [rip + para_quote]
    jae 51f
    # fewer markers: lazy continuation only for a non-blank, non-block line (decided below)
51: mov [rip + ls_quote], r12d
    cmp dword ptr [rip + para_open], 0
    jne 5f
    mov dword ptr [rip + ls_n], 0
5:  cmp dword ptr [rip + para_open], 0    # a deeper quote starts its own blocks
    je 50f
    cmp r12d, [rip + para_quote]
    jbe 50f
    call close_para
50: mov rdi, r15
    mov rsi, r14
    call indent
    mov [rsp], eax              # its indent (columns)
    mov [rsp + 8], rdx          # its first other byte
    cmp rdx, r14
    jne .Lpl_nonblank
    # a blank line
    cmp dword ptr [rip + code_open], 2
    jne 52f
    lea rdi, [rip + cb]         # inside indented code (trailing ones trimmed at its end)
    mov esi, 10
    call sb_push_byte
52: call close_para
    mov dword ptr [rip + tbl_open], 0
    jmp .Lpl_ret
.Lpl_nonblank:
    # indented code goes on with 4 more columns than the content column
    call list_content_col
    mov [rsp + 16], eax         # the content column of the list item open
    cmp dword ptr [rip + code_open], 2
    jne 53f
    mov ecx, [rsp]
    sub ecx, eax
    cmp ecx, 4
    jl 531f
    mov rdi, r15
    mov rsi, r14
    lea edx, [rax + 4]
    call skip_cols
    lea rdi, [rip + cb]
    mov rsi, rax
    mov rdx, r14
    sub rdx, rax
    call sb_push
    lea rdi, [rip + cb]
    mov esi, 10
    call sb_push_byte
    jmp .Lpl_ret
531:call close_code
53: # a thematic break (before list items: "* * *")
    mov rdi, [rsp + 8]
    mov rsi, r14
    call is_rule
    mov [rsp + 24], eax
    # a list item?
    cmp dword ptr [rsp + 24], 0
    jne 54f
    mov rdi, [rsp + 8]
    mov rsi, r14
    call list_marker            # -> eax 0 none, 1 bullet, 2 ordered; edx marker width; ecx number
    test eax, eax
    jz 54f
    cmp dword ptr [rip + para_open], 0
    je 532f
    cmp dword ptr [rip + ls_n], 0   # outside lists an ordered item interrupts a paragraph only from 1
    jne 532f
    cmp eax, 2
    jne 532f
    cmp ecx, 1
    jne 54f
532:mov edi, [rsp]
    mov esi, eax
    mov r8d, ecx
    mov rcx, [rsp + 8]
    call start_item             # -> rax where its content starts
    mov [rsp + 8], rax
    mov rdi, rax
    mov rsi, r14
    call indent
    mov [rsp + 8], rdx
    xor eax, eax                # relative indent 0 in the item
    mov [rsp], eax
    cmp rdx, r14
    jne .Lpl_leaf
    jmp .Lpl_ret                # an item with nothing yet
54: # not an item: inside the list item open, or a lazy paragraph line, or the lists end
    mov eax, [rsp]
    cmp dword ptr [rip + ls_n], 0
    je 56f
    cmp eax, [rsp + 16]
    jb 55f
    sub eax, [rsp + 16]         # relative to the item's content
    mov [rsp], eax
    jmp .Lpl_leaf
55: cmp dword ptr [rip + para_open], 0
    jne .Lpl_lazy
    mov edi, eax                # the lists the line is not inside end
    call close_lists
    call list_content_col
    mov ecx, [rsp]
    sub ecx, eax
    mov [rsp], ecx
    jmp .Lpl_leaf
56:
.Lpl_leaf:
    # leaf blocks, at [rsp + 8] with the relative indent [rsp]
    cmp dword ptr [rsp], 4
    jl 61f
    cmp dword ptr [rip + para_open], 0
    jne .Lpl_para               # an indented line goes on with a paragraph
    call close_para
    mov dword ptr [rip + tbl_open], 0
    mov dword ptr [rip + code_open], 2
    call code_ctx
    mov dword ptr [rip + code_langlen], 0
    mov rdi, r15
    mov rsi, r14
    mov edx, [rsp + 16]
    add edx, 4
    call skip_cols
    lea rdi, [rip + cb]
    mov rsi, rax
    mov rdx, r14
    sub rdx, rax
    call sb_push
    lea rdi, [rip + cb]
    mov esi, 10
    call sb_push_byte
    jmp .Lpl_ret
61: mov r15, [rsp + 8]
    movzx eax, byte ptr [r15]
    # a fence
    cmp eax, '`'
    je 62f
    cmp eax, '~'
    jne 63f
62: mov rcx, r15
    xor r8d, r8d
621:cmp rcx, r14
    jae 622f
    cmp [rcx], al
    jne 622f
    inc r8d
    inc rcx
    jmp 621b
622:cmp r8d, 3
    jb 63f
    cmp eax, '`'                # a backtick fence's info has no backtick
    jne 625f
    mov rdx, rcx
623:cmp rdx, r14
    jae 625f
    cmp byte ptr [rdx], '`'
    je 63f
    inc rdx
    jmp 623b
625:mov [rsp + 32], rcx
    mov [rip + code_fch], eax
    mov [rip + code_flen], r8d
    call close_para
    mov dword ptr [rip + tbl_open], 0
    mov eax, [rsp]
    mov [rip + code_find], eax
    mov dword ptr [rip + code_open], 1
    call code_ctx
    mov rdi, [rsp + 32]         # the info string's first word: the language
    mov rsi, r14
    call indent
    mov rcx, rdx
626:cmp rcx, r14
    jae 627f
    cmp byte ptr [rcx], ' '
    je 627f
    cmp byte ptr [rcx], 9
    je 627f
    inc rcx
    jmp 626b
627:mov rbx, [rip + pm]
    mov rax, [rbx + MD_text + SB_len]
    mov [rip + code_lang], eax
    sub rcx, rdx
    mov [rip + code_langlen], ecx
    lea rdi, [rbx + MD_text]
    mov rsi, rdx
    mov rdx, rcx
    call sb_push
    jmp .Lpl_ret
63: # an ATX heading
    cmp byte ptr [r15], '#'
    jne 64f
    mov rcx, r15
    xor r8d, r8d
631:cmp rcx, r14
    jae 632f
    cmp byte ptr [rcx], '#'
    jne 632f
    inc r8d
    inc rcx
    jmp 631b
632:cmp r8d, 6
    ja 64f
    cmp rcx, r14
    je 633f
    cmp byte ptr [rcx], ' '
    je 633f
    cmp byte ptr [rcx], 9
    jne 64f
633:mov [rsp + 32], r8
    mov rdi, rcx
    mov rsi, r14
    call heading_text           # -> rax start, rdx end (closing #s and blanks off)
    mov [rsp + 40], rdx
    mov r15, rax
    call close_para
    mov dword ptr [rip + tbl_open], 0
    mov edi, MDB_HEAD
    call blk_new
    mov rbx, rax
    mov rax, [rsp + 32]
    mov [rbx + MDB_level], eax
    mov rdi, r15
    mov rsi, [rsp + 40]
    sub rsi, r15
    call inline_runs
    mov [rbx + MDB_run0], eax
    mov [rbx + MDB_nrun], edx
    jmp .Lpl_ret
64: # a setext underline turns the paragraph into a heading
    cmp dword ptr [rip + para_open], 0
    je 65f
    mov rdi, r15
    mov rsi, r14
    call setext_level
    test eax, eax
    jz 65f
    mov [rsp + 32], rax
    call close_para
    call blk_last
    mov dword ptr [rax + MDB_type], MDB_HEAD
    mov rcx, [rsp + 32]
    mov [rax + MDB_level], ecx
    jmp .Lpl_ret
65: # a thematic break
    cmp dword ptr [rsp + 24], 0
    je 66f
    call close_para
    mov dword ptr [rip + tbl_open], 0
    mov edi, MDB_RULE
    call blk_new
    jmp .Lpl_ret
66: # an HTML comment
    mov rax, r14
    sub rax, r15
    cmp rax, 4
    jb 67f
    cmp dword ptr [r15], 0x2d2d213c     # "<!--"
    jne 67f
    call close_para
    lea rdi, [r15 + 4]
    mov rsi, r14
    call find_comment_end
    test rax, rax
    jnz .Lpl_ret
    mov dword ptr [rip + comment_open], 1
    jmp .Lpl_ret
67: # a table: a row with | over an alignment row, or a row of the table open
    cmp dword ptr [rip + tbl_open], 0
    je 671f
    mov eax, [rip + cur_quote]
    cmp eax, [rip + tbl_quote]
    jne 670f
    mov rdi, r15
    mov rsi, r14
    call has_pipe
    test eax, eax
    jz 670f
    mov rdi, r15
    mov rsi, r14
    xor edx, edx
    call table_row
    jmp .Lpl_ret
670:mov dword ptr [rip + tbl_open], 0
671:cmp dword ptr [rip + para_open], 0
    jne 68f
    mov rdi, r15
    mov rsi, r14
    call has_pipe
    test eax, eax
    jz 68f
    lea rdi, [r14 + 1]          # the next line: the alignment row
    call align_row              # -> eax columns (0: not one), edx aligns
    test eax, eax
    jz 68f
    mov [rsp + 32], rax
    mov [rsp + 40], rdx
    mov rdi, r15
    mov rsi, r14
    mov edx, 1
    call table_row
    call blk_last
    mov rcx, [rsp + 32]
    mov [rax + MDB_ncols], ecx
    mov rcx, [rsp + 40]
    mov [rax + MDB_aligns], ecx
    mov dword ptr [rip + skip_next], 1
    jmp .Lpl_ret
68: # a reference definition (not inside a paragraph)
    cmp dword ptr [rip + para_open], 0
    jne .Lpl_para
    mov rdi, r15
    mov rsi, r14
    call ref_def
    test eax, eax
    jnz .Lpl_ret
.Lpl_para:
    cmp dword ptr [rip + para_open], 0
    jne 69f
    mov dword ptr [rip + tbl_open], 0
    mov dword ptr [rip + para_open], 1
    mov eax, [rip + line_no]
    mov [rip + para_line], eax
    mov eax, [rip + cur_quote]
    mov [rip + para_quote], eax
    mov eax, [rip + ls_n]
    mov [rip + para_list], eax
    mov eax, [rip + pend_marker]
    mov [rip + para_marker], eax
    mov eax, [rip + pend_num]
    mov [rip + para_num], eax
    mov dword ptr [rip + pend_marker], 0
    jmp 691f
69: lea rdi, [rip + pb]
    mov esi, 10
    call sb_push_byte
691:# the line: trailing blanks off; two or more of them, or a backslash, make a hard break
    mov rcx, r14
    xor r8d, r8d
692:cmp rcx, r15
    jbe 693f
    cmp byte ptr [rcx - 1], ' '
    jne 693f
    inc r8d
    dec rcx
    jmp 692b
693:mov [rsp + 32], rcx
    mov [rsp + 40], r8
    lea rdi, [rip + pb]
    mov rsi, r15
    mov rdx, rcx
    sub rdx, r15
    call sb_push
    cmp qword ptr [rsp + 40], 2
    jb .Lpl_ret
    lea rdi, [rip + pb]
    mov esi, 1
    call sb_push_byte
    jmp .Lpl_ret
.Lpl_lazy:
    mov r15, [rsp + 8]
    jmp .Lpl_para
.Lpl_ret:
    EPILOGUE

# code_ctx(): a code block opening takes the context now (and the list marker)
code_ctx:
    mov eax, [rip + line_no]
    mov [rip + code_line], eax
    mov eax, [rip + cur_quote]
    mov [rip + code_quote], eax
    mov eax, [rip + ls_n]
    mov [rip + code_list], eax
    mov eax, [rip + pend_marker]
    mov [rip + code_marker], eax
    mov eax, [rip + pend_num]
    mov [rip + code_num], eax
    mov dword ptr [rip + pend_marker], 0
    lea rdi, [rip + cb]
    jmp sb_clear

# list_content_col() -> eax the content column of the list item open (0 outside lists)
list_content_col:
    xor eax, eax
    mov ecx, [rip + ls_n]
    test ecx, ecx
    jz 9f
    dec ecx
    lea rax, [rip + ls_content]
    mov eax, [rax + rcx*4]
9:  ret

# close_lists(indent): the lists whose marker column is past the indent end (a paragraph ends)
close_lists:
    push rbx
    mov ebx, edi
1:  mov ecx, [rip + ls_n]
    test ecx, ecx
    jz 9f
    dec ecx
    lea rax, [rip + ls_content]
    cmp ebx, [rax + rcx*4]
    jae 9f
    mov [rip + ls_n], ecx
    jmp 1b
9:  pop rbx
    ret

# list_marker(p, end) -> eax 0, 1 a bullet (- * +), 2 ordered (1-9 digits and . or )); edx the
#   marker's width; ecx the number
list_marker:
    movzx eax, byte ptr [rdi]
    cmp eax, '-'
    je 1f
    cmp eax, '*'
    je 1f
    cmp eax, '+'
    jne 3f
1:  lea rcx, [rdi + 1]
    cmp rcx, rsi
    je 2f
    cmp byte ptr [rcx], ' '
    je 2f
    cmp byte ptr [rcx], 9
    jne 8f
2:  mov eax, 1
    mov edx, 1
    xor ecx, ecx
    ret
3:  xor ecx, ecx                # digits
    xor edx, edx
4:  lea r8, [rdi + rdx]
    cmp r8, rsi
    jae 8f
    movzx eax, byte ptr [r8]
    sub eax, '0'
    cmp eax, 9
    ja 5f
    imul ecx, ecx, 10
    add ecx, eax
    inc edx
    cmp edx, 9
    ja 8f
    jmp 4b
5:  test edx, edx
    jz 8f
    movzx eax, byte ptr [r8]
    cmp eax, '.'
    je 6f
    cmp eax, ')'
    jne 8f
6:  inc r8
    inc edx
    cmp r8, rsi
    je 7f
    cmp byte ptr [r8], ' '
    je 7f
    cmp byte ptr [r8], 9
    jne 8f
7:  mov eax, 2
    ret
8:  xor eax, eax
    ret

# start_item(indent, kind, marker p, number) -> rax where the item's content starts: the lists
#   follow (a sibling, a nested item, or a new list), the next block takes the marker
start_item:
    PROLOGUE
    mov r12d, edi               # the marker's column
    mov r13d, esi               # 1 bullet, 2 ordered
    mov r14, rcx                # the marker
    mov r15d, r8d
    call close_para
    call close_code
    mov dword ptr [rip + tbl_open], 0
    # the marker's width again, and the spaces after it (1 to 4; more: 1)
    mov rdi, r14
    mov rsi, [rip + cur_line_end]
    call list_marker
    lea rbx, [r14 + rdx]        # after the marker
    mov rdi, rbx
    mov rsi, [rip + cur_line_end]
    call indent
    mov ecx, eax
    cmp ecx, 4
    jbe 1f
    mov ecx, 1                  # more: the content is indented code; one space counts
    lea rdx, [rbx + 1]
1:  cmp rdx, [rip + cur_line_end]
    jne 2f
    mov ecx, 1                  # nothing after the marker
2:  mov r8, rdx
    mov rax, rbx
    sub rax, r14
    add eax, r12d
    add eax, ecx                # the content column
    mov r9d, eax
    # the lists: pop the ones whose marker column is past this one
3:  mov ecx, [rip + ls_n]
    test ecx, ecx
    jz 5f
    dec ecx
    lea rax, [rip + ls_marker]
    cmp r12d, [rax + rcx*4]
    jae 4f
    mov [rip + ls_n], ecx
    jmp 3b
4:  lea rax, [rip + ls_content]
    cmp r12d, [rax + rcx*4]
    jae 5f                      # past its content column: nested
    mov [rip + ls_n], ecx       # a sibling: in its place
5:  mov ecx, [rip + ls_n]
    cmp ecx, MD_LISTS
    jae 6f
    lea rax, [rip + ls_marker]
    mov [rax + rcx*4], r12d
    lea rax, [rip + ls_content]
    mov [rax + rcx*4], r9d
    inc dword ptr [rip + ls_n]
6:  mov [rip + pend_marker], r13d
    mov [rip + pend_num], r15d
    # a task: "[ ] " or "[x] "
    mov rax, [rip + cur_line_end]
    sub rax, r8
    cmp rax, 3
    jb 8f
    cmp byte ptr [r8], '['
    jne 8f
    cmp byte ptr [r8 + 2], ']'
    jne 8f
    movzx ecx, byte ptr [r8 + 1]
    mov edx, 3
    cmp ecx, ' '
    je 7f
    mov edx, 4
    or ecx, 0x20
    cmp ecx, 'x'
    jne 8f
7:  cmp rax, 3
    je 71f
    cmp byte ptr [r8 + 3], ' '
    jne 8f
    mov [rip + pend_marker], edx
    lea r8, [r8 + 4]
    jmp 8f
71: mov [rip + pend_marker], edx
    lea r8, [r8 + 3]
8:  mov rax, r8
    EPILOGUE

# is_rule(p, end) -> eax 1 for a thematic break: 3 or more of - * _ (one of them), blanks between
is_rule:
    movzx ecx, byte ptr [rdi]
    cmp ecx, '-'
    je 1f
    cmp ecx, '*'
    je 1f
    cmp ecx, '_'
    jne 8f
1:  xor edx, edx
2:  cmp rdi, rsi
    jae 3f
    movzx eax, byte ptr [rdi]
    inc rdi
    cmp eax, ecx
    jne 21f
    inc edx
    jmp 2b
21: cmp eax, ' '
    je 2b
    cmp eax, 9
    je 2b
    jmp 8f
3:  cmp edx, 3
    jb 8f
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# setext_level(p, end) -> eax 1 for "===", 2 for "---" (any count, trailing blanks), else 0
setext_level:
    movzx ecx, byte ptr [rdi]
    cmp ecx, '='
    je 1f
    cmp ecx, '-'
    jne 8f
1:  cmp rdi, rsi
    jae 3f
    movzx eax, byte ptr [rdi]
    cmp eax, ecx
    jne 2f
    inc rdi
    jmp 1b
2:  cmp rdi, rsi
    jae 3f
    movzx eax, byte ptr [rdi]
    inc rdi
    cmp eax, ' '
    je 2b
    cmp eax, 9
    je 2b
    jmp 8f
3:  mov eax, 1
    cmp ecx, '='
    je 9f
    mov eax, 2
9:  ret
8:  xor eax, eax
    ret

# heading_text(p, end) -> rax, rdx the heading's text: blanks around, and a closing run of # after a
#   blank, left out
heading_text:
1:  cmp rdi, rsi
    jae 2f
    cmp byte ptr [rdi], ' '
    je 11f
    cmp byte ptr [rdi], 9
    jne 2f
11: inc rdi
    jmp 1b
2:  mov rdx, rsi                # blanks at the end
21: cmp rdx, rdi
    jbe 9f
    cmp byte ptr [rdx - 1], ' '
    je 22f
    cmp byte ptr [rdx - 1], 9
    jne 3f
22: dec rdx
    jmp 21b
3:  mov rcx, rdx                # a closing run of #
31: cmp rcx, rdi
    jbe 33f
    cmp byte ptr [rcx - 1], '#'
    jne 32f
    dec rcx
    jmp 31b
32: cmp byte ptr [rcx - 1], ' '
    je 34f
    cmp byte ptr [rcx - 1], 9
    jne 9f
34: mov rdx, rcx
    jmp 21b
33: mov rdx, rcx                # only #s: an empty heading
9:  mov rax, rdi
    ret

# find_comment_end(p, end) -> rax past "-->", or 0
find_comment_end:
1:  lea rax, [rdi + 3]
    cmp rax, rsi
    ja 8f
    cmp byte ptr [rdi], '-'
    jne 2f
    cmp byte ptr [rdi + 1], '-'
    jne 2f
    cmp byte ptr [rdi + 2], '>'
    je 9f
2:  inc rdi
    jmp 1b
8:  xor eax, eax
9:  ret

# has_pipe(p, end) -> eax 1 when the line holds an unescaped |
has_pipe:
1:  cmp rdi, rsi
    jae 8f
    movzx eax, byte ptr [rdi]
    cmp eax, '\\'
    jne 2f
    add rdi, 2
    jmp 1b
2:  cmp eax, '|'
    je 9f
    inc rdi
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# align_row(p) -> eax the columns of a table's alignment row starting at p (0 when it is not one),
#   edx their aligns (2 bits each)
align_row:
    PROLOGUE
    mov rbx, [rip + pm]
    mov r12, [rbx + MD_src + SB_ptr]
    add r12, [rbx + MD_src + SB_len]
    cmp rdi, r12
    jae 8f
    mov r13, rdi                # its end
1:  cmp byte ptr [r13], 10
    je 2f
    inc r13
    jmp 1b
2:  # quote markers as the header row had them
    mov ecx, [rip + cur_quote]
21: test ecx, ecx
    jz 22f
    mov rsi, r13
    push rcx
    push rcx
    call indent
    pop rcx
    pop rcx
    cmp rdx, r13
    jae 8f
    cmp byte ptr [rdx], '>'
    jne 8f
    lea rdi, [rdx + 1]
    dec ecx
    jmp 21b
22: mov rsi, r13
    call indent
    mov rdi, rdx
    xor r14d, r14d              # columns
    xor r15d, r15d              # aligns
    xor ebx, ebx                # a cell has dashes
    cmp rdi, r13
    jae 8f
    cmp byte ptr [rdi], '|'
    jne 3f
    inc rdi
3:  # a cell: blanks, optional :, dashes, optional :, blanks, then | or the end
    xor ecx, ecx                # left colon, dashes, right colon
    xor edx, edx
    xor r8d, r8d
31: cmp rdi, r13
    jae 4f
    movzx eax, byte ptr [rdi]
    cmp eax, ' '
    je 32f
    cmp eax, 9
    je 32f
    cmp eax, ':'
    jne 33f
    test edx, edx
    jnz 34f
    mov ecx, 1
    jmp 32f
34: mov r8d, 1
    jmp 32f
33: cmp eax, '-'
    jne 35f
    test r8d, r8d
    jnz 8f
    inc edx
    jmp 32f
35: cmp eax, '|'
    jne 8f
    inc rdi
    jmp 4f
32: inc rdi
    jmp 31b
4:  test edx, edx
    jz 41f
    # this column's align: center with both colons, right with the right one
    xor eax, eax
    test ecx, ecx
    jz 42f
    test r8d, r8d
    jz 43f
    mov eax, 1
    jmp 43f
42: test r8d, r8d
    jz 43f
    mov eax, 2
43: cmp r14d, MD_COLS
    jae 44f
    mov ecx, r14d
    add ecx, ecx
    shl eax, cl
    or r15d, eax
44: inc r14d
    jmp 45f
41: cmp rdi, r13
    jb 8f                       # an empty cell in the middle
45: cmp rdi, r13
    jb 3b
    test r14d, r14d
    jz 8f
    mov eax, r14d
    mov edx, r15d
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# table_row(p, end, header): a table row's cells as runs (MS_CELL after each); the header opens a
#   table
table_row:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov [rsp], edx
    call close_para
    mov edi, MDB_TROW
    call blk_new
    mov rbx, rax
    mov eax, [rsp]
    mov [rbx + MDB_hdr], eax
    test eax, eax
    jz 1f
    mov dword ptr [rip + tbl_open], 1
    mov eax, [rip + cur_quote]
    mov [rip + tbl_quote], eax
    mov rax, [rip + pm]
    mov rcx, [rax + MD_blocks + VEC_len]
    dec ecx
    mov [rip + tbl_hdr], ecx
1:  mov eax, [rip + tbl_hdr]
    mov [rbx + MDB_tbl], eax
    mov rax, [rip + pm]
    mov rcx, [rax + MD_runs + VEC_len]
    mov [rbx + MDB_run0], ecx
    # blanks and the outer pipes off
2:  cmp r12, r13
    jae 3f
    cmp byte ptr [r12], ' '
    je 21f
    cmp byte ptr [r12], 9
    jne 3f
21: inc r12
    jmp 2b
3:  cmp r13, r12
    jbe 4f
    cmp byte ptr [r13 - 1], ' '
    je 31f
    cmp byte ptr [r13 - 1], 9
    jne 4f
31: dec r13
    jmp 3b
4:  cmp r12, r13
    jae 5f
    cmp byte ptr [r12], '|'
    jne 41f
    inc r12
41: cmp r13, r12
    jbe 5f
    cmp byte ptr [r13 - 1], '|'
    jne 5f
    cmp r13, r12
    je 5f
    lea rax, [r13 - 2]
    cmp rax, r12
    jb 42f
    cmp byte ptr [r13 - 2], '\\'
    je 5f
42: dec r13
5:  # each cell
    mov r14, r12
51: cmp r14, r13
    jae 53f
    movzx eax, byte ptr [r14]
    cmp eax, '\\'
    jne 52f
    add r14, 2
    jmp 51b
52: cmp eax, '|'
    je 53f
    inc r14
    jmp 51b
53: mov rdi, r12                # the cell, its blanks off
    mov rsi, r14
    call heading_text
    mov rdi, rax
    mov rsi, rdx
    sub rsi, rax
    call inline_runs_more
    mov edi, MS_CELL
    call run_mark
    cmp r14, r13
    jae 6f
    lea r12, [r14 + 1]
    jmp 5b
6:  mov rax, [rip + pm]
    mov rcx, [rax + MD_runs + VEC_len]
    sub ecx, [rbx + MDB_run0]
    mov [rbx + MDB_nrun], ecx
    EPILOGUE

# ref_def(p, end) -> eax 1 when the line is a reference definition "[label]: url" (kept)
ref_def:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    cmp byte ptr [r12], '['
    jne 8f
    lea r14, [r12 + 1]
1:  cmp r14, r13
    jae 8f
    movzx eax, byte ptr [r14]
    cmp eax, ']'
    je 2f
    cmp eax, '['
    je 8f
    inc r14
    jmp 1b
2:  lea rax, [r14 + 1]
    cmp rax, r13
    jae 8f
    cmp byte ptr [r14 + 1], ':'
    jne 8f
    lea rdi, [r14 + 2]
    mov rsi, r13
    call indent
    cmp rdx, r13
    jae 8f
    mov r15, rdx                # the url: <...> or up to a blank
    mov rcx, rdx
    cmp byte ptr [rcx], '<'
    jne 3f
    inc r15
    inc rcx
31: cmp rcx, r13
    jae 8f
    cmp byte ptr [rcx], '>'
    je 4f
    inc rcx
    jmp 31b
3:  cmp rcx, r13
    jae 4f
    cmp byte ptr [rcx], ' '
    je 4f
    cmp byte ptr [rcx], 9
    je 4f
    inc rcx
    jmp 3b
4:  cmp dword ptr [rip + ref_collect], 0
    je 41f
    mov rbx, [rip + pm]
    push rcx
    push rcx
    lea rdi, [rbx + MD_refs]
    mov esi, MDF_SIZE
    call vec_push
    pop rcx
    pop rcx
    mov rdx, [rbx + MD_src + SB_ptr]
    lea rsi, [r12 + 1]
    sub rsi, rdx
    mov [rax + MDF_label], esi
    mov rsi, r14
    sub rsi, r12
    dec esi
    mov [rax + MDF_labellen], esi
    mov rsi, r15
    sub rsi, rdx
    mov [rax + MDF_url], esi
    sub rcx, r15
    mov [rax + MDF_urllen], ecx
41: mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# collect_refs(): a first pass over the lines for reference definitions (outside fenced code; quote
#   markers skipped)
collect_refs:
    PROLOGUE 16
    mov dword ptr [rip + ref_collect], 1
    mov rbx, [rip + pm]
    mov r12, [rbx + MD_src + SB_ptr]
    mov r15, r12
    add r15, [rbx + MD_src + SB_len]
    xor r14d, r14d              # inside a fence: its character
1:  cmp r12, r15
    jae 9f
    mov r13, r12
2:  cmp byte ptr [r13], 10
    je 3f
    inc r13
    jmp 2b
3:  mov rdi, r12                # quote markers and indent off
31: mov rsi, r13
    call indent
    cmp rdx, r13
    jae 8f
    cmp byte ptr [rdx], '>'
    jne 32f
    lea rdi, [rdx + 1]
    jmp 31b
32: cmp eax, 3
    ja 8f
    mov rdi, rdx
    movzx eax, byte ptr [rdi]   # a fence opens or closes
    cmp eax, '`'
    je 33f
    cmp eax, '~'
    jne 34f
33: lea rcx, [rdi + 2]
    cmp rcx, r13
    jae 34f
    cmp [rdi + 1], al
    jne 34f
    cmp [rdi + 2], al
    jne 34f
    test r14d, r14d
    jz 331f
    cmp r14d, eax
    jne 8f
    xor r14d, r14d
    jmp 8f
331:mov r14d, eax
    jmp 8f
34: test r14d, r14d
    jnz 8f
    mov rsi, r13
    call ref_def
8:  lea r12, [r13 + 1]
    jmp 1b
9:  mov dword ptr [rip + ref_collect], 0
    EPILOGUE

# ---------------- parsing: inline ----------------

# inline_runs(ptr, len) -> eax the first run, edx how many: a block's text as runs
inline_runs:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rbx, [rip + pm]
    mov r14, [rbx + MD_runs + VEC_len]
    mov [rip + run_floor], r14d
    mov dword ptr [rip + in_style], 0
    mov dword ptr [rip + in_link], -1
    mov dword ptr [rip + in_depth], 0
    mov qword ptr [rip + hc_mem], 0         # has_closer's memory is for one text
    mov qword ptr [rip + hc_mem + 32], 0
    mov qword ptr [rip + hc_mem + 64], 0
    mov rdi, r12
    mov rsi, r13
    call inline_parse
    mov edx, [rbx + MD_runs + VEC_len]
    sub edx, r14d
    mov eax, r14d
    EPILOGUE

# inline_runs_more(ptr, len): the same, runs counted by the caller (table cells)
inline_runs_more:
    mov rax, [rip + pm]
    mov rax, [rax + MD_runs + VEC_len]
    mov [rip + run_floor], eax
    mov dword ptr [rip + in_style], 0
    mov dword ptr [rip + in_link], -1
    mov dword ptr [rip + in_depth], 0
    mov qword ptr [rip + hc_mem], 0         # has_closer's memory is for one text
    mov qword ptr [rip + hc_mem + 32], 0
    mov qword ptr [rip + hc_mem + 64], 0
    jmp inline_parse

# run_mark(style): a run without text (a hard break, a cell's end)
run_mark:
    PROLOGUE
    mov r12d, edi
    mov rbx, [rip + pm]
    lea rdi, [rbx + MD_runs]
    mov esi, MDR_SIZE
    call vec_push
    mov rcx, [rbx + MD_text + SB_len]
    mov [rax + MDR_off], ecx
    mov dword ptr [rax + MDR_len], 0
    mov [rax + MDR_style], r12d
    mov dword ptr [rax + MDR_link], -1
    EPILOGUE

# emit(ptr, len, style): text in a style (the current link): it extends the last run when that run
#   ends where the text does and has the same style and link
emit:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    test r13, r13
    jz 9f
    mov rbx, [rip + pm]
    mov r15, [rbx + MD_text + SB_len]
    mov rcx, [rbx + MD_runs + VEC_len]
    cmp ecx, [rip + run_floor]
    jbe 1f
    dec rcx
    imul rcx, rcx, MDR_SIZE
    add rcx, [rbx + MD_runs + VEC_ptr]
    cmp [rcx + MDR_style], r14d
    jne 1f
    mov eax, [rip + in_link]
    cmp [rcx + MDR_link], eax
    jne 1f
    mov eax, [rcx + MDR_off]
    add eax, [rcx + MDR_len]
    cmp rax, r15
    jne 1f
    test r14d, MS_BREAK | MS_CELL
    jnz 1f
    add [rcx + MDR_len], r13d
    jmp 2f
1:  lea rdi, [rbx + MD_runs]
    mov esi, MDR_SIZE
    call vec_push
    mov [rax + MDR_off], r15d
    mov [rax + MDR_len], r13d
    mov [rax + MDR_style], r14d
    mov ecx, [rip + in_link]
    mov [rax + MDR_link], ecx
2:  lea rdi, [rbx + MD_text]
    mov rsi, r12
    mov rdx, r13
    call sb_push
9:  EPILOGUE

# emit_byte(c): one byte in the current style
emit_byte:
    sub rsp, 8
    mov [rsp], dil
    mov rdi, rsp
    mov esi, 1
    mov edx, [rip + in_style]
    call emit
    add rsp, 8
    ret

# add_link(ptr, len) -> eax its index (-1 past 4096 links): the target kept in MD_text
add_link:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rbx, [rip + pm]
    cmp qword ptr [rbx + MD_links + VEC_len], MD_LINKS_MAX
    jae 8f
    lea rdi, [rbx + MD_links]
    mov esi, MDL_SIZE
    call vec_push
    mov rcx, [rbx + MD_text + SB_len]
    mov [rax + MDL_off], ecx
    mov [rax + MDL_len], r13d
    lea rdi, [rbx + MD_text]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rax, [rbx + MD_links + VEC_len]
    dec eax
    EPILOGUE
8:  mov eax, -1
    EPILOGUE

# is_space(c) -> eax 1 for blank, LF, the hard-break mark
is_space:
    xor eax, eax
    cmp edi, ' '
    je 1f
    cmp edi, 9
    je 1f
    cmp edi, 10
    je 1f
    cmp edi, 1
    je 1f
    ret
1:  mov eax, 1
    ret

# is_alnum(c) -> eax 1 for an ASCII letter or digit (or a byte of a UTF-8 character)
is_alnum:
    mov eax, 1
    cmp edi, 0x80
    jae 9f
    lea ecx, [rdi - '0']
    cmp ecx, 10
    jb 9f
    mov ecx, edi
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 26
    jb 9f
    xor eax, eax
9:  ret

# is_punct(c) -> eax 1 for ASCII punctuation (what a backslash escapes)
is_punct:
    xor eax, eax
    cmp edi, 0x21
    jb 9f
    cmp edi, 0x7e
    ja 9f
    push rdi
    push rdi
    call is_alnum
    pop rdi
    pop rdi
    xor eax, 1
9:  ret

# inline_parse(ptr, len): text into runs, in in_style and in_link
inline_parse:
    PROLOGUE 48
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d              # i
.Lip_loop:
    cmp r14, r13
    jae .Lip_done
    movzx r15d, byte ptr [r12 + r14]
    cmp r15d, '\\'
    je .Lip_escape
    cmp r15d, 1
    je .Lip_hard
    cmp r15d, 10
    je .Lip_soft
    cmp r15d, '`'
    je .Lip_code
    cmp r15d, '*'
    je .Lip_delim
    cmp r15d, '_'
    je .Lip_delim
    cmp r15d, '~'
    je .Lip_delim
    cmp r15d, '!'
    je .Lip_bang
    cmp r15d, '['
    je .Lip_bracket
    cmp r15d, '<'
    je .Lip_angle
    cmp r15d, '&'
    je .Lip_entity
    cmp r15d, 'h'
    je .Lip_bare
.Lip_plain:
    # a stretch of ordinary bytes at once
    lea rbx, [r14 + 1]
1:  cmp rbx, r13
    jae 2f
    movzx eax, byte ptr [r12 + rbx]
    cmp eax, 'h'
    je 2f
    lea rcx, [rip + special]
    cmp byte ptr [rcx + rax], 0
    jne 2f
    inc rbx
    jmp 1b
2:  lea rdi, [r12 + r14]
    mov rsi, rbx
    sub rsi, r14
    mov edx, [rip + in_style]
    call emit
    mov r14, rbx
    jmp .Lip_loop
.Lip_escape:
    lea rax, [r14 + 1]
    cmp rax, r13
    jae .Lip_plain
    movzx edi, byte ptr [r12 + rax]
    cmp edi, 10
    je 1f
    cmp edi, 1
    je 1f
    call is_punct
    test eax, eax
    jz .Lip_plain
    movzx edi, byte ptr [r12 + r14 + 1]
    call emit_byte
    add r14, 2
    jmp .Lip_loop
1:  mov edi, MS_BREAK           # a backslash at the line's end: a hard break
    call run_mark
    add r14, 2
    cmp byte ptr [r12 + r14 - 1], 1
    jne .Lip_loop
    inc r14                     # its LF too
    jmp .Lip_loop
.Lip_hard:
    mov edi, MS_BREAK
    call run_mark
    inc r14
    cmp r14, r13
    jae .Lip_loop
    cmp byte ptr [r12 + r14], 10
    jne .Lip_loop
    inc r14
    jmp .Lip_loop
.Lip_soft:
    mov edi, ' '
    call emit_byte
    inc r14
    jmp .Lip_loop
.Lip_code:
    # a code span: as many backticks close it
    mov rbx, r14
1:  cmp rbx, r13
    jae 2f
    cmp byte ptr [r12 + rbx], '`'
    jne 2f
    inc rbx
    jmp 1b
2:  mov rcx, rbx
    sub rcx, r14                # n
    mov [rsp], rcx
    mov [rsp + 8], rbx          # the content's start
    mov rdx, rbx
3:  cmp rdx, r13
    jae .Lip_code_literal
    cmp byte ptr [r12 + rdx], '`'
    je 4f
    inc rdx
    jmp 3b
4:  mov r8, rdx                 # a run of backticks: as long?
5:  cmp r8, r13
    jae 6f
    cmp byte ptr [r12 + r8], '`'
    jne 6f
    inc r8
    jmp 5b
6:  mov rax, r8
    sub rax, rdx
    cmp rax, [rsp]
    je 7f
    mov rdx, r8
    jmp 3b
7:  mov [rsp + 16], rdx         # the content's end
    mov [rsp + 24], r8          # past the closing run
    # its text: line ends as spaces; one space off each end when both have one
    mov rsi, [rsp + 8]
    mov rdi, [rsp + 16]
    mov rax, rdi
    sub rax, rsi
    cmp rax, 2
    jb 71f
    movzx eax, byte ptr [r12 + rsi]
    cmp eax, ' '
    je 70f
    cmp eax, 10
    jne 71f
70: movzx eax, byte ptr [r12 + rdi - 1]
    cmp eax, ' '
    je 701f
    cmp eax, 10
    jne 71f
701:inc qword ptr [rsp + 8]
    dec qword ptr [rsp + 16]
71: mov rbx, [rsp + 8]
72: cmp rbx, [rsp + 16]
    jae 73f
    movzx edi, byte ptr [r12 + rbx]
    cmp edi, 10
    je 721f
    cmp edi, 1
    je 722f
    jmp 723f
721:mov edi, ' '
723:mov [rsp + 32], dil
    lea rdi, [rsp + 32]
    mov esi, 1
    mov edx, [rip + in_style]
    or edx, MS_CODE
    call emit
722:inc rbx
    jmp 72b
73: mov r14, [rsp + 24]
    jmp .Lip_loop
.Lip_code_literal:
    lea rdi, [r12 + r14]
    mov rsi, [rsp]
    mov edx, [rip + in_style]
    call emit
    add r14, [rsp]
    jmp .Lip_loop
.Lip_delim:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call delim                  # -> rax bytes consumed (0: plain)
    test rax, rax
    jz .Lip_plain1
    add r14, rax
    jmp .Lip_loop
.Lip_plain1:
    mov edi, r15d
    call emit_byte
    inc r14
    jmp .Lip_loop
.Lip_bang:
    lea rax, [r14 + 1]
    cmp rax, r13
    jae .Lip_plain1
    cmp byte ptr [r12 + rax], '['
    jne .Lip_plain1
    mov rdi, r12
    mov rsi, r13
    lea rdx, [r14 + 1]
    mov ecx, 1
    call link_at                # -> rax past it, or 0
    test rax, rax
    jz .Lip_plain1
    mov r14, rax
    jmp .Lip_loop
.Lip_bracket:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    xor ecx, ecx
    call link_at
    test rax, rax
    jz .Lip_plain1
    mov r14, rax
    jmp .Lip_loop
.Lip_angle:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call autolink
    test rax, rax
    jz .Lip_plain1
    mov r14, rax
    jmp .Lip_loop
.Lip_entity:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call entity
    test rax, rax
    jz .Lip_plain1
    mov r14, rax
    jmp .Lip_loop
.Lip_bare:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call bare_url
    test rax, rax
    jz .Lip_plain1
    mov r14, rax
    jmp .Lip_loop
.Lip_done:
    EPILOGUE

# delim(ptr, len, i) -> rax bytes consumed as an emphasis, strong or strikethrough delimiter (its
#   style toggled), 0 when the byte is plain text
delim:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    movzx r15d, byte ptr [r12 + r14]
    mov rbx, r14                # the run of it
1:  cmp rbx, r13
    jae 2f
    movzx eax, byte ptr [r12 + rbx]
    cmp eax, r15d
    jne 2f
    inc rbx
    jmp 1b
2:  mov rax, rbx
    sub rax, r14
    mov [rsp], rax              # n
    # which style, and how many it takes
    cmp r15d, '~'
    jne 3f
    cmp rax, 2
    jne 8f
    mov dword ptr [rsp + 8], MS_STRIKE
    mov qword ptr [rsp + 16], 2
    jmp 4f
3:  mov dword ptr [rsp + 8], MS_EM
    mov qword ptr [rsp + 16], 1
    cmp rax, 2
    jb 4f
    mov dword ptr [rsp + 8], MS_STRONG
    mov qword ptr [rsp + 16], 2
    # three or more: an em closes first when one is open, else strong first
    cmp rax, 3
    jb 4f
    test dword ptr [rip + in_style], MS_EM
    jz 4f
    test dword ptr [rip + in_style], MS_STRONG
    jnz 4f
    mov dword ptr [rsp + 8], MS_EM
    mov qword ptr [rsp + 16], 1
4:  # flanking: the byte before and after the run
    mov edi, ' '
    test r14, r14
    jz 41f
    movzx edi, byte ptr [r12 + r14 - 1]
41: mov [rsp + 24], edi         # before
    mov edi, ' '
    cmp rbx, r13
    jae 42f
    movzx edi, byte ptr [r12 + rbx]
42: mov [rsp + 28], edi         # after
    # closing: the style is on and the byte before is not blank (an underscore: none after)
    mov eax, [rsp + 8]
    test [rip + in_style], eax
    jz 5f
    mov edi, [rsp + 24]
    call is_space
    test eax, eax
    jnz 5f
    cmp r15d, '_'
    jne 43f
    mov edi, [rsp + 28]
    call is_alnum
    test eax, eax
    jnz 5f
43: mov eax, [rsp + 8]
    not eax
    and [rip + in_style], eax
    mov rax, [rsp + 16]
    EPILOGUE
5:  # opening: the byte after is not blank (an underscore: none before), and a closer comes
    mov edi, [rsp + 28]
    call is_space
    test eax, eax
    jnz 8f
    cmp r15d, '_'
    jne 51f
    mov edi, [rsp + 24]
    call is_alnum
    test eax, eax
    jnz 8f
51: mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    add rdx, [rsp + 16]
    mov ecx, r15d
    mov r8, [rsp + 16]
    call has_closer
    test eax, eax
    jz 8f
    mov eax, [rsp + 8]
    or [rip + in_style], eax
    mov rax, [rsp + 16]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# has_closer(ptr, len, from, c, n) -> eax 1 when a run of at least n of c that can close follows.
#   A search that failed is remembered (per delimiter, for the same text): a later one from further
#   on needing as long a run fails at once, so unmatched openers cost linear time, not quadratic
has_closer:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15d, ecx
    mov rbx, r8
    mov [rip + hc_from], rdx
    call hc_slot                # rax the delimiter's memory, or 0
    test rax, rax
    jz 1f
    cmp [rax], r12              # the same text, from at or past a failure, a run as long
    jne 1f
    cmp [rax + 8], r13
    jne 1f
    cmp r14, [rax + 16]
    jb 1f
    cmp rbx, [rax + 24]
    jae 8f
1:  cmp r14, r13
    jae 8f
    movzx eax, byte ptr [r12 + r14]
    cmp eax, '\\'
    jne 2f
    add r14, 2
    jmp 1b
2:  cmp eax, r15d
    jne 7f
    # a run: its length, the byte before it
    mov rcx, r14
3:  cmp rcx, r13
    jae 4f
    movzx eax, byte ptr [r12 + rcx]
    cmp eax, r15d
    jne 4f
    inc rcx
    jmp 3b
4:  mov rax, rcx
    sub rax, r14
    cmp rax, rbx
    jb 6f
    movzx edi, byte ptr [r12 + r14 - 1]
    push rcx
    push rcx
    call is_space
    pop rcx
    pop rcx
    test eax, eax
    jnz 6f
    cmp r15d, '_'
    jne 9f
    mov edi, ' '
    cmp rcx, r13
    jae 5f
    movzx edi, byte ptr [r12 + rcx]
5:  push rcx
    push rcx
    call is_alnum
    pop rcx
    pop rcx
    test eax, eax
    jz 9f
6:  mov r14, rcx
    jmp 1b
7:  inc r14
    jmp 1b
8:  call hc_slot                # remember the failure: from the search's start
    test rax, rax
    jz 81f
    mov [rax], r12
    mov [rax + 8], r13
    mov rcx, [rip + hc_from]
    mov [rax + 16], rcx
    mov [rax + 24], rbx
81: xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# hc_slot() -> rax has_closer's memory for the delimiter r15d ('*', '_', '~'), else 0
hc_slot:
    lea rax, [rip + hc_mem]
    cmp r15d, '*'
    je 9f
    add rax, 32
    cmp r15d, '_'
    je 9f
    add rax, 32
    cmp r15d, '~'
    je 9f
    xor eax, eax
9:  ret

# link_at(ptr, len, i at '[', image) -> rax past the link (its text emitted as a link; an image's
#   alt text), or 0 when it is not one
link_at:
    PROLOGUE 64
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov [rsp + 56], ecx
    # the matching ]
    lea rbx, [r14 + 1]
    xor ecx, ecx                # depth
1:  cmp rbx, r13
    jae 8f
    movzx eax, byte ptr [r12 + rbx]
    cmp eax, '\\'
    jne 2f
    add rbx, 2
    jmp 1b
2:  cmp eax, '['
    jne 3f
    inc ecx
    jmp 4f
3:  cmp eax, ']'
    jne 4f
    test ecx, ecx
    jz 5f
    dec ecx
4:  inc rbx
    jmp 1b
5:  mov [rsp], rbx              # the ]
    lea r15, [rbx + 1]
    cmp r15, r13
    jae .Lla_short
    cmp byte ptr [r12 + r15], '('
    je .Lla_inline
    cmp byte ptr [r12 + r15], '['
    je .Lla_full
.Lla_short:
    # [text]: the text names a reference
    lea rdi, [r12 + r14 + 1]
    mov rsi, [rsp]
    sub rsi, r14
    dec rsi
    call find_ref               # -> rax url ptr, rdx len, or rax 0
    test rax, rax
    jz 8f
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    mov rax, [rsp]
    inc rax
    mov [rsp + 24], rax         # past it
    jmp .Lla_emit
.Lla_full:
    lea rcx, [r15 + 1]          # [text][label]
    mov rdx, rcx
6:  cmp rdx, r13
    jae 8f
    cmp byte ptr [r12 + rdx], ']'
    je 61f
    inc rdx
    jmp 6b
61: lea rax, [rdx + 1]
    mov [rsp + 24], rax
    lea rdi, [r12 + rcx]
    mov rsi, rdx
    sub rsi, rcx
    jnz 62f
    lea rdi, [r12 + r14 + 1]    # []: the text is the label
    mov rsi, [rsp]
    sub rsi, r14
    dec rsi
62: call find_ref
    test rax, rax
    jz 8f
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    jmp .Lla_emit
.Lla_inline:
    # (destination "title")
    lea rdi, [r12 + r15 + 1]
    lea rsi, [r12 + r13]
    call skip_blank
    sub rax, r12
    mov rbx, rax
    cmp rbx, r13
    jae 8f
    cmp byte ptr [r12 + rbx], '<'
    jne 7f
    inc rbx
    mov [rsp + 8], rbx
71: cmp rbx, r13
    jae 8f
    movzx eax, byte ptr [r12 + rbx]
    cmp eax, 10
    je 8f
    cmp eax, '>'
    je 72f
    inc rbx
    jmp 71b
72: mov rax, rbx
    sub rax, [rsp + 8]
    mov [rsp + 16], rax
    inc rbx
    jmp 75f
7:  mov [rsp + 8], rbx
    xor ecx, ecx                # parentheses inside
73: cmp rbx, r13
    jae 74f
    movzx eax, byte ptr [r12 + rbx]
    cmp eax, ' '
    jbe 74f
    cmp eax, '('
    jne 731f
    inc ecx
    jmp 733f
731:cmp eax, ')'
    jne 732f
    test ecx, ecx
    jz 74f
    dec ecx
    jmp 733f
732:cmp eax, '\\'
    jne 733f
    inc rbx
733:inc rbx
    jmp 73b
74: mov rax, rbx
    sub rax, [rsp + 8]
    mov [rsp + 16], rax
75: # an optional title
    lea rdi, [r12 + rbx]
    lea rsi, [r12 + r13]
    call skip_blank
    sub rax, r12
    mov rbx, rax
    cmp rbx, r13
    jae 8f
    movzx ecx, byte ptr [r12 + rbx]
    cmp ecx, '"'
    je 76f
    cmp ecx, 0x27
    je 76f
    cmp ecx, '('
    jne 78f
    mov ecx, ')'
76: inc rbx
77: cmp rbx, r13
    jae 8f
    movzx eax, byte ptr [r12 + rbx]
    inc rbx
    cmp eax, '\\'
    jne 771f
    inc rbx
    jmp 77b
771:cmp eax, ecx
    jne 77b
    lea rdi, [r12 + rbx]
    lea rsi, [r12 + r13]
    call skip_blank
    sub rax, r12
    mov rbx, rax
    cmp rbx, r13
    jae 8f
78: cmp byte ptr [r12 + rbx], ')'
    jne 8f
    inc rbx
    mov [rsp + 24], rbx
    mov rax, [rsp + 8]
    add rax, r12
    mov [rsp + 8], rax
.Lla_emit:
    # the target kept, the text parsed as a link (inside a link: plain text)
    mov eax, [rip + in_link]
    mov [rsp + 32], eax
    mov eax, [rip + in_style]
    mov [rsp + 36], eax
    cmp dword ptr [rip + in_link], -1
    jne 81f
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call add_link
    mov [rip + in_link], eax
    or dword ptr [rip + in_style], MS_LINK
    cmp dword ptr [rsp + 56], 0
    je 81f
    or dword ptr [rip + in_style], MS_IMAGE
81: lea rdi, [r12 + r14 + 1]
    mov rsi, [rsp]
    sub rsi, r14
    dec rsi
    call inline_parse
    mov eax, [rsp + 32]
    mov [rip + in_link], eax
    mov eax, [rsp + 36]
    mov [rip + in_style], eax
    mov rax, [rsp + 24]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# skip_blank(p, end) -> rax past blanks and line ends
skip_blank:
1:  cmp rdi, rsi
    jae 9f
    movzx eax, byte ptr [rdi]
    cmp eax, ' '
    je 2f
    cmp eax, 9
    je 2f
    cmp eax, 10
    je 2f
    cmp eax, 1
    jne 9f
2:  inc rdi
    jmp 1b
9:  mov rax, rdi
    ret

# find_ref(label, len) -> rax, rdx its reference's target, or rax 0 (labels compare without case)
find_ref:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rbx, [rip + pm]
    xor r14d, r14d
1:  cmp r14, [rbx + MD_refs + VEC_len]
    jae 8f
    imul r15, r14, MDF_SIZE
    add r15, [rbx + MD_refs + VEC_ptr]
    mov eax, [r15 + MDF_labellen]
    cmp rax, r13
    jne 3f
    mov rsi, [rbx + MD_src + SB_ptr]
    mov eax, [r15 + MDF_label]
    add rsi, rax
    xor ecx, ecx
2:  cmp rcx, r13
    jae 4f
    movzx eax, byte ptr [r12 + rcx]
    movzx edx, byte ptr [rsi + rcx]
    or eax, 0x20
    or edx, 0x20
    cmp eax, edx
    jne 3f
    inc rcx
    jmp 2b
3:  inc r14
    jmp 1b
4:  mov rax, [rbx + MD_src + SB_ptr]
    mov ecx, [r15 + MDF_url]
    add rax, rcx
    mov edx, [r15 + MDF_urllen]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# autolink(ptr, len, i at '<') -> rax past "<scheme:...>" or "<a@b>" (emitted as a link), or 0
autolink:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    lea rbx, [r14 + 1]
    mov rcx, rbx                # the end: '>' before any blank or '<'
1:  cmp rcx, r13
    jae 8f
    movzx eax, byte ptr [r12 + rcx]
    cmp eax, '>'
    je 2f
    cmp eax, ' '
    jbe 8f
    cmp eax, '<'
    je 8f
    inc rcx
    jmp 1b
2:  mov r15, rcx
    # a scheme: a letter, then letters, digits, + . - up to the colon (2 to 32 bytes)
    mov rcx, rbx
    movzx eax, byte ptr [r12 + rcx]
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 26
    jae 5f
3:  inc rcx
    cmp rcx, r15
    jae 5f
    movzx edi, byte ptr [r12 + rcx]
    cmp edi, ':'
    je 4f
    cmp edi, '+'
    je 3b
    cmp edi, '.'
    je 3b
    cmp edi, '-'
    je 3b
    push rcx
    push rcx
    call is_alnum
    pop rcx
    pop rcx
    test eax, eax
    jnz 3b
    jmp 5f
4:  mov rax, rcx
    sub rax, rbx
    cmp rax, 2
    jb 5f
    cmp rax, 32
    ja 5f
    lea rdi, [r12 + rbx]
    mov rsi, r15
    sub rsi, rbx
    call link_text
    lea rax, [r15 + 1]
    EPILOGUE
5:  # an email address: something @ something with a dot after
    mov rcx, rbx
    xor edx, edx
6:  cmp rcx, r15
    jae 7f
    cmp byte ptr [r12 + rcx], '@'
    jne 61f
    mov rdx, rcx
61: inc rcx
    jmp 6b
7:  test rdx, rdx
    jz 8f
    cmp rdx, rbx
    je 8f
    lea rdi, [r12 + rbx]
    mov rsi, r15
    sub rsi, rbx
    mov edx, 1
    call link_mailto
    lea rax, [r15 + 1]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# link_text(ptr, len): text that is its own target, emitted as a link
link_text:
    xor edx, edx
link_mailto:                    # (ptr, len, mailto): the target "mailto:" + it
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov eax, [rip + in_link]
    mov [rsp], eax
    mov eax, [rip + in_style]
    mov [rsp + 4], eax
    cmp dword ptr [rip + in_link], -1
    jne 2f
    test edx, edx
    jz 1f
    lea rdi, [rip + tbuf]       # "mailto:" + the address (an address over 56 bytes: none)
    cmp r13, 56
    ja 1f
    mov rax, 0x3a6f746c69616d   # "mailto:"
    mov [rdi], rax
    lea rdi, [rip + tbuf + 7]
    mov rsi, r12
    mov rdx, r13
    call memcpy
    lea rdi, [rip + tbuf]
    lea rsi, [r13 + 7]
    call add_link
    jmp 11f
1:  mov rdi, r12
    mov rsi, r13
    call add_link
11: mov [rip + in_link], eax
    or dword ptr [rip + in_style], MS_LINK
2:  mov rdi, r12
    mov rsi, r13
    mov edx, [rip + in_style]
    call emit
    mov eax, [rsp]
    mov [rip + in_link], eax
    mov eax, [rsp + 4]
    mov [rip + in_style], eax
    EPILOGUE

# bare_url(ptr, len, i at 'h') -> rax past an http:// or https:// URL (emitted as a link), or 0:
#   only after a blank, ( * _ ~ or the start; trailing punctuation left out
bare_url:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    test r14, r14
    jz 1f
    movzx eax, byte ptr [r12 + r14 - 1]
    lea rcx, [rip + url_before]
21: movzx edx, byte ptr [rcx]
    test edx, edx
    jz 8f
    cmp eax, edx
    je 1f
    inc rcx
    jmp 21b
1:  mov rax, r13
    sub rax, r14
    cmp rax, 8
    jb 8f
    lea rbx, [r12 + r14]
    cmp dword ptr [rbx], 0x70747468     # "http"
    jne 8f
    cmp dword ptr [rbx + 4], 0x2f2f3a73 # "s://"
    je 2f
    cmp word ptr [rbx + 4], 0x2f3a      # "://" after "http"
    jne 8f
    cmp byte ptr [rbx + 6], '/'
    jne 8f
2:  mov r15, r14                # to a blank or '<'
3:  cmp r15, r13
    jae 4f
    movzx eax, byte ptr [r12 + r15]
    cmp eax, ' '
    jbe 4f
    cmp eax, '<'
    je 4f
    inc r15
    jmp 3b
4:  cmp r15, r14
    jbe 8f
    movzx eax, byte ptr [r12 + r15 - 1]
    lea rcx, [rip + url_trail]
5:  movzx edx, byte ptr [rcx]
    test edx, edx
    jz 6f
    cmp eax, edx
    je 51f
    inc rcx
    jmp 5b
51: dec r15
    jmp 4b
6:  mov rax, r15
    sub rax, r14
    cmp rax, 8
    jb 8f
    lea rdi, [r12 + r14]
    mov rsi, rax
    call link_text
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# entity(ptr, len, i at '&') -> rax past a known entity (its character emitted), or 0
entity:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    lea rbx, [r14 + 1]          # the ';' within 10 bytes
    mov rcx, rbx
1:  cmp rcx, r13
    jae 8f
    mov rax, rcx
    sub rax, rbx
    cmp rax, 10
    ja 8f
    cmp byte ptr [r12 + rcx], ';'
    je 2f
    inc rcx
    jmp 1b
2:  mov r15, rcx
    cmp rcx, rbx
    je 8f
    cmp byte ptr [r12 + rbx], '#'
    je 5f
    # named
    lea r8, [rip + entities]
3:  mov rdi, [r8]
    test rdi, rdi
    jz 8f
    push r8
    push r8
    lea rdi, [r12 + rbx]
    mov rsi, r15
    sub rsi, rbx
    mov rdx, [r8]
    call str_eq_cstr
    pop r8
    pop r8
    test eax, eax
    jnz 4f
    add r8, 16
    jmp 3b
4:  mov edi, [r8 + 8]
    jmp 7f
5:  # numeric: &#N; or &#xN;
    lea rcx, [rbx + 1]
    xor edi, edi
    xor edx, edx                # digits
    cmp rcx, r15
    jae 8f
    movzx eax, byte ptr [r12 + rcx]
    or eax, 0x20
    cmp eax, 'x'
    je 6f
51: cmp rcx, r15
    jae 52f
    movzx eax, byte ptr [r12 + rcx]
    sub eax, '0'
    cmp eax, 9
    ja 8f
    imul edi, edi, 10
    add edi, eax
    cmp edi, 0x10ffff
    ja 8f
    inc rcx
    inc edx
    jmp 51b
52: test edx, edx
    jz 8f
    jmp 7f
6:  inc rcx
61: cmp rcx, r15
    jae 52b
    movzx eax, byte ptr [r12 + rcx]
    lea r8d, [rax - '0']
    cmp r8d, 9
    jbe 62f
    or eax, 0x20
    lea r8d, [rax - 'a' + 10]
    cmp eax, 'a'
    jb 8f
    cmp eax, 'f'
    ja 8f
62: shl edi, 4
    add edi, r8d
    cmp edi, 0x10ffff
    ja 8f
    inc rcx
    inc edx
    jmp 61b
7:  test edi, edi
    jnz 71f
    mov edi, 0xfffd
71: lea rsi, [rsp]
    call utf8_encode
    mov rsi, rax
    lea rdi, [rsp]
    mov edx, [rip + in_style]
    call emit
    lea rax, [r15 + 1]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- layout ----------------

# face_of(MDF_*) -> rax FACE* (the emphasis face made again when the ui face changed)
face_of:
    cmp edi, MDF_EM
    jne 1f
    mov eax, [rip + g_face_gen]
    cmp eax, [rip + em_gen]
    je 1f
    push rdi
    call em_face_init
    pop rdi
1:  lea rax, [rip + md_faces]
    mov rax, [rax + rdi*8]
    ret

# em_face_init(): em_face is the ui face's font and size, sheared; g_face_gen stays (it is ours)
em_face_init:
    push rbx
    mov ebx, [rip + g_face_gen]
    lea rdi, [rip + em_face]
    mov rsi, [rip + g_face_ui + FACE_font]
    mov edx, [rip + g_face_ui + FACE_px]
    test rsi, rsi
    jz 1f
    call face_init
    mov dword ptr [rip + em_face + FACE_oblique], 1
    mov eax, [rip + g_face_ui + FACE_embolden]
    mov [rip + em_face + FACE_embolden], eax
1:  mov [rip + g_face_gen], ebx
    mov [rip + em_gen], ebx
    pop rbx
    ret

# item_new(kind) -> rax a new layout item (link -1)
item_new:
    PROLOGUE
    mov r12d, edi
    mov rbx, [rip + pm]
    lea rdi, [rbx + MD_items]
    mov esi, MDI_SIZE
    call vec_push
    mov [rax + MDI_kind], r12d
    mov dword ptr [rax + MDI_link], -1
    EPILOGUE

# fill_item(x, y, w, h, slot)
fill_item:
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    mov edi, MDK_FILL
    call item_new
    mov [rax + MDI_x], ebx
    mov [rax + MDI_y], r12d
    mov [rax + MDI_w], r13d
    mov [rax + MDI_h], r14d
    mov [rax + MDI_color], r15d
    EPILOGUE

# md_layout(m, width) -> eax the height: blocks into items at that width (nothing to do when the
#   width and the faces are the same as last time)
FN md_layout
    PROLOGUE 48
    mov rbx, rdi
    mov [rip + pm], rdi
    cmp [rbx + MD_width], esi
    jne 1f
    mov eax, [rip + g_face_gen]
    cmp eax, [rbx + MD_gen]
    jne 1f
    mov eax, [rbx + MD_height]
    EPILOGUE
1:  mov [rbx + MD_width], esi
    mov eax, [rip + g_face_gen]
    mov [rbx + MD_gen], eax
    mov dword ptr [rbx + MD_sel], 0     # the items change: no selection
    mov dword ptr [rbx + MD_drag], 0
    mov qword ptr [rbx + MD_items + VEC_len], 0
    mov dword ptr [rbx + MD_maxw], 0
    mov dword ptr [rip + lay_y], 0
    xor r12d, r12d              # block
.Lml_block:
    cmp r12, [rbx + MD_blocks + VEC_len]
    jae .Lml_done
    imul r13, r12, MDB_SIZE
    add r13, [rbx + MD_blocks + VEC_ptr]
    # the gap before it
    test r12, r12
    jz 2f
    cmp dword ptr [r13 + MDB_type], MDB_TROW
    jne 11f
    cmp dword ptr [r13 + MDB_hdr], 0
    je 2f                       # rows of a table touch
11: M eax, MI_10
    cmp dword ptr [r13 + MDB_list], 0
    je 12f
    cmp dword ptr [r13 + MDB_marker], 0
    jne 13f
    cmp dword ptr [r13 + MDB_type], MDB_PARA
    jne 12f
13: lea rcx, [r13 - MDB_SIZE]   # items of a list come closer
    cmp dword ptr [rcx + MDB_list], 0
    je 12f
    M eax, MI_4
12: add [rip + lay_y], eax
2:  mov eax, [rip + lay_y]
    mov [rsp], eax              # the block's top
    mov [r13 + MDB_y], eax
    # its left: quotes and lists indent it
    mov eax, [r13 + MDB_quote]
    imul eax, [rip + g_mt + 4*MI_16]
    mov ecx, [r13 + MDB_list]
    imul ecx, [rip + g_mt + 4*MI_24]
    add eax, ecx
    mov [rip + lay_x0], eax
    mov eax, [rbx + MD_width]
    sub eax, [rip + g_mt + 4*MI_2]
    mov [rip + lay_right], eax
    mov eax, [rip + lay_x0]
    add eax, [rip + g_mt + 4*MI_24]
    cmp eax, [rip + lay_right]
    jle 21f
    mov [rip + lay_right], eax  # never narrower than a little
21: mov dword ptr [rip + lay_color], T_FG
    cmp dword ptr [r13 + MDB_quote], 0
    je 22f
    mov dword ptr [rip + lay_color], T_MUTED
22: mov eax, [r13 + MDB_type]
    cmp eax, MDB_CODE
    je .Lml_code
    cmp eax, MDB_RULE
    je .Lml_rule
    cmp eax, MDB_TROW
    je .Lml_trow
    # a paragraph or a heading: its face
    mov dword ptr [rip + lay_face], MDF_UI
    mov dword ptr [rip + lay_bold], 0
    cmp eax, MDB_HEAD
    jne 3f
    mov dword ptr [rip + lay_bold], 1
    mov ecx, [r13 + MDB_level]
    cmp ecx, 1
    jne 23f
    mov dword ptr [rip + lay_face], MDF_HUGE
    mov dword ptr [rip + lay_bold], 0
    jmp 3f
23: cmp ecx, 2
    jne 3f
    mov dword ptr [rip + lay_face], MDF_BIG
3:  mov edi, [rip + lay_face]
    call face_of
    mov ecx, [rax + FACE_lineh]
    mov [rip + lay_lineh], ecx
    mov ecx, [rax + FACE_ascent]
    mov [rip + lay_base], ecx
    mov rdi, r13
    call marker_items
    mov edi, [r13 + MDB_run0]
    mov esi, [r13 + MDB_nrun]
    call flow
    # a level 1 or 2 heading: a line under it
    cmp dword ptr [r13 + MDB_type], MDB_HEAD
    jne .Lml_quotes
    cmp dword ptr [r13 + MDB_level], 2
    ja .Lml_quotes
    M eax, MI_4
    add [rip + lay_y], eax
    mov edi, [rip + lay_x0]
    mov esi, [rip + lay_y]
    mov edx, [rip + lay_right]
    sub edx, edi
    M ecx, MI_1
    mov r8d, T_BORDER
    call fill_item
    M eax, MI_2
    add [rip + lay_y], eax
    jmp .Lml_quotes
.Lml_rule:
    M eax, MI_6
    add eax, [rip + lay_y]
    mov edi, [rip + lay_x0]
    mov esi, eax
    mov edx, [rip + lay_right]
    sub edx, edi
    M ecx, MI_1
    mov r8d, T_BORDER
    call fill_item
    M eax, MI_12
    add [rip + lay_y], eax
    jmp .Lml_quotes
.Lml_code:
    mov rdi, r13
    call marker_items
    mov rdi, r13
    call code_items
    jmp .Lml_quotes
.Lml_trow:
    mov rdi, r13
    mov rsi, r12
    call row_items
.Lml_quotes:
    # quote bars down its height
    mov r14d, [r13 + MDB_quote]
4:  test r14d, r14d
    jz 5f
    dec r14d
    mov edi, r14d
    imul edi, [rip + g_mt + 4*MI_16]
    add edi, [rip + g_mt + 4*MI_4]
    mov esi, [rsp]
    M edx, MI_3
    mov ecx, [rip + lay_y]
    sub ecx, esi
    mov r8d, T_BORDER
    call fill_item
    jmp 4b
5:  inc r12
    jmp .Lml_block
.Lml_done:
    mov eax, [rip + lay_y]
    mov [rbx + MD_height], eax
    EPILOGUE

# marker_items(block): its list item's marker left of it: a dot, "N." or a task's box
marker_items:
    PROLOGUE 16
    mov rbx, rdi
    mov eax, [rbx + MDB_marker]
    test eax, eax
    jz 9f
    mov edi, MDF_UI
    call face_of
    mov r12, rax
    cmp dword ptr [rbx + MDB_marker], 1
    jne 2f
    mov edi, MDK_DOT            # a bullet: a dot, a ring one level in
    call item_new
    M ecx, MI_6
    mov [rax + MDI_w], ecx
    mov [rax + MDI_h], ecx
    mov edx, [rip + lay_x0]
    sub edx, [rip + g_mt + 4*MI_14]
    mov [rax + MDI_x], edx
    mov edx, [r12 + FACE_lineh]
    sub edx, ecx
    sar edx, 1
    add edx, [rip + lay_y]
    mov [rax + MDI_y], edx
    mov dword ptr [rax + MDI_color], T_MUTED
    mov ecx, [rbx + MDB_list]
    and ecx, 1
    xor ecx, 1
    mov [rax + MDI_style], ecx  # 1: filled
    jmp 9f
2:  cmp dword ptr [rbx + MDB_marker], 2
    jne 3f
    # "N." right-aligned before the text: its digits in MD_text
    mov r13, [rip + pm]
    lea rdi, [rsp]
    mov esi, [rbx + MDB_num]
    call fmt_u64
    mov byte ptr [rsp + rax], '.'
    inc rax
    mov r14, rax
    mov r15, [r13 + MD_text + SB_len]
    lea rdi, [r13 + MD_text]
    lea rsi, [rsp]
    mov rdx, r14
    call sb_push
    mov rdi, r12
    mov rsi, [r13 + MD_text + SB_ptr]
    add rsi, r15
    mov rdx, r14
    call text_width
    mov ecx, eax
    push rcx
    push rcx
    mov edi, MDK_TEXT
    call item_new
    pop rcx
    pop rcx
    mov [rax + MDI_w], ecx
    mov edx, [rip + lay_x0]
    sub edx, [rip + g_mt + 4*MI_6]
    sub edx, ecx
    mov [rax + MDI_x], edx
    mov edx, [rip + lay_y]
    mov [rax + MDI_y], edx
    mov edx, [r12 + FACE_lineh]
    mov [rax + MDI_h], edx
    mov edx, [r12 + FACE_ascent]
    mov [rax + MDI_base], edx
    mov dword ptr [rax + MDI_color], T_MUTED
    mov dword ptr [rax + MDI_face], MDF_UI
    mov [rax + MDI_off], r15d
    mov [rax + MDI_len], r14d
    jmp 9f
3:  mov edi, MDK_BOX            # a task's box, checked or not
    call item_new
    M ecx, MI_12
    mov [rax + MDI_w], ecx
    mov [rax + MDI_h], ecx
    mov edx, [rip + lay_x0]
    sub edx, [rip + g_mt + 4*MI_16]
    mov [rax + MDI_x], edx
    mov edx, [r12 + FACE_lineh]
    sub edx, ecx
    sar edx, 1
    add edx, [rip + lay_y]
    mov [rax + MDI_y], edx
    mov dword ptr [rax + MDI_color], T_MUTED
    xor ecx, ecx
    cmp dword ptr [rbx + MDB_marker], 4
    sete cl
    mov [rax + MDI_style], ecx
9:  EPILOGUE

# flow(run0, n): runs into lines from lay_x0 to lay_right in lay_face, from lay_y (moved past them)
flow:
    PROLOGUE 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov rbx, [rip + pm]
    mov eax, [rip + lay_x0]
    mov [rip + lay_x], eax
    mov dword ptr [rsp + 40], -1    # the image last laid out (its link): its other runs go
    xor r12d, r12d              # the run
.Lfl_run:
    cmp r12d, [rsp + 4]
    jae .Lfl_end
    mov eax, [rsp]
    add eax, r12d
    imul r13, rax, MDR_SIZE
    add r13, [rbx + MD_runs + VEC_ptr]
    test dword ptr [r13 + MDR_style], MS_BREAK
    jz 1f
    call flow_newline
    jmp .Lfl_next
1:  test dword ptr [r13 + MDR_style], MS_IMAGE  # an image shown in place of its alt text
    jz 11f
    mov eax, [r13 + MDR_link]
    cmp eax, [rsp + 40]
    je .Lfl_next
    mov rdi, r13
    call image_run
    test eax, eax
    jz 11f
    mov eax, [r13 + MDR_link]
    mov [rsp + 40], eax
    jmp .Lfl_next
11: mov eax, [rip + lay_face]   # its face: code spans in the code face, emphasis sheared
    test dword ptr [r13 + MDR_style], MS_CODE
    jz 21f
    mov eax, MDF_CODE
    jmp 2f
21: test dword ptr [r13 + MDR_style], MS_EM
    jz 2f
    cmp eax, MDF_UI
    jne 2f
    mov eax, MDF_EM
2:  mov [rsp + 8], eax
    mov edi, eax
    call face_of
    mov [rsp + 16], rax
    xor r14d, r14d              # i within the run
.Lfl_piece:
    cmp r14d, [r13 + MDR_len]
    jae .Lfl_next
    mov rsi, [rbx + MD_text + SB_ptr]
    mov eax, [r13 + MDR_off]
    add rsi, rax
    mov [rsp + 24], rsi         # the run's text
    cmp byte ptr [rsi + r14], ' '
    jne 3f
    # a space: none at a line's start; else its width
    inc r14d
    mov eax, [rip + lay_x]
    cmp eax, [rip + lay_x0]
    je .Lfl_piece
    mov rdi, [rsp + 16]
    lea rsi, [rip + .Lsp]
    mov edx, 1
    call text_width
    add [rip + lay_x], eax
    jmp .Lfl_piece
3:  mov r15d, r14d              # the word: to the next space
31: cmp r15d, [r13 + MDR_len]
    jae 32f
    mov rsi, [rsp + 24]
    cmp byte ptr [rsi + r15], ' '
    je 32f
    inc r15d
    jmp 31b
32: mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    add rsi, r14
    mov edx, r15d
    sub edx, r14d
    call text_width
    mov [rsp + 32], eax         # its width
    add eax, [rip + lay_x]
    cmp eax, [rip + lay_right]
    jle 4f
    mov eax, [rip + lay_x]
    cmp eax, [rip + lay_x0]
    je 33f
    call flow_newline           # it goes on the next line
    mov eax, [rsp + 32]
    add eax, [rip + lay_x]
    cmp eax, [rip + lay_right]
    jle 4f
33: # wider than the line: as much as fits (one character at least), the rest after
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    add rsi, r14
    mov edx, r15d
    sub edx, r14d
    mov ecx, [rip + lay_right]
    sub ecx, [rip + lay_x]
    call text_fit
    test eax, eax
    jnz 34f
    mov rsi, [rsp + 24]         # one character
    movzx ecx, byte ptr [rsi + r14]
    mov eax, 1
    cmp ecx, 0xc0
    jb 34f
    inc eax
    cmp ecx, 0xe0
    jb 34f
    inc eax
    cmp ecx, 0xf0
    jb 34f
    inc eax
34: lea r15d, [r14 + rax]
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    add rsi, r14
    mov edx, eax
    call text_width
    mov [rsp + 32], eax
4:  # the word as an item (a code span over its tint)
    test dword ptr [r13 + MDR_style], MS_CODE
    jz 41f
    mov edi, [rip + lay_x]
    sub edi, [rip + g_mt + 4*MI_2]
    mov esi, [rip + lay_y]
    mov edx, [rsp + 32]
    add edx, [rip + g_mt + 4*MI_4]
    mov ecx, [rip + lay_lineh]
    mov r8d, T_HOVER
    call fill_item
41: mov edi, MDK_TEXT
    call item_new
    mov ecx, [rip + lay_x]
    mov [rax + MDI_x], ecx
    mov ecx, [rip + lay_y]
    mov [rax + MDI_y], ecx
    mov ecx, [rsp + 32]
    mov [rax + MDI_w], ecx
    mov ecx, [rip + lay_lineh]
    mov [rax + MDI_h], ecx
    mov ecx, [rip + lay_base]
    mov [rax + MDI_base], ecx
    mov ecx, [rsp + 8]
    mov [rax + MDI_face], ecx
    mov ecx, [r13 + MDR_style]
    cmp dword ptr [rip + lay_bold], 0
    je 42f
    or ecx, MS_STRONG
42: mov [rax + MDI_style], ecx
    mov ecx, [r13 + MDR_link]
    mov [rax + MDI_link], ecx
    mov ecx, [rip + lay_color]
    test dword ptr [r13 + MDR_style], MS_LINK
    jz 43f
    mov ecx, T_ACCENT
43: mov [rax + MDI_color], ecx
    mov ecx, [r13 + MDR_off]
    add ecx, r14d
    mov [rax + MDI_off], ecx
    mov ecx, r15d
    sub ecx, r14d
    mov [rax + MDI_len], ecx
    mov eax, [rsp + 32]
    add [rip + lay_x], eax
    mov eax, [rip + lay_x]
    cmp eax, [rbx + MD_maxw]
    jle 44f
    mov [rbx + MD_maxw], eax
44: mov r14d, r15d
    jmp .Lfl_piece
.Lfl_next:
    inc r12d
    jmp .Lfl_run
.Lfl_end:
    mov eax, [rip + lay_lineh]
    add [rip + lay_y], eax
    EPILOGUE

# flow_newline(): the next line
flow_newline:
    mov eax, [rip + lay_lineh]
    add [rip + lay_y], eax
    mov eax, [rip + lay_x0]
    mov [rip + lay_x], eax
    ret

# code_items(block): a code block's lines over a tint, colored by the grammar its info names
code_items:
    PROLOGUE 64
    mov rbx, rdi
    mov r15, [rip + pm]
    # the grammar: by name, else by a file "x.WORD"
    mov qword ptr [rsp + 40], 0
    mov ecx, [rbx + MDB_langlen]
    test ecx, ecx
    jz 2f
    cmp ecx, 40
    ja 2f
    mov rdi, [r15 + MD_text + SB_ptr]
    mov eax, [rbx + MDB_lang]
    add rdi, rax
    mov esi, ecx
    push rdi
    push rdi
    call syntax_by_name
    pop rdi
    pop rdi
    test rax, rax
    jnz 1f
    mov word ptr [rip + tbuf], 0x2e78     # "x."
    mov rsi, rdi
    lea rdi, [rip + tbuf + 2]
    mov edx, [rbx + MDB_langlen]
    call memcpy
    lea rdi, [rip + tbuf]
    mov esi, [rbx + MDB_langlen]
    add esi, 2
    call syntax_for_name
    test rax, rax
    jz 2f
    mov rdi, rax
    call syntax_ready
1:  mov [rsp + 40], rax
2:  mov edi, MDF_CODE
    call face_of
    mov [rsp + 48], rax
    mov ecx, [rax + FACE_lineh]
    mov [rsp + 56], ecx
    # the lines: their count for the tint's height
    mov rsi, [r15 + MD_text + SB_ptr]
    mov eax, [rbx + MDB_code]
    add rsi, rax
    mov [rsp], rsi              # the code
    mov ecx, [rbx + MDB_codelen]
    mov [rsp + 8], ecx
    mov edx, 1
    xor eax, eax
3:  cmp eax, ecx
    jae 4f
    cmp byte ptr [rsi + rax], 10
    jne 31f
    inc edx
31: inc eax
    jmp 3b
4:  imul edx, [rsp + 56]
    add edx, [rip + g_mt + 4*MI_8]
    add edx, [rip + g_mt + 4*MI_8]
    mov dword ptr [rsp + 60], 0 # Copy button's header height
    cmp dword ptr [rbx + MDB_copy], -1
    je 41f
    mov r12d, edx
    mov edi, MDF_SMALL
    call face_of
    mov ecx, [rax + FACE_lineh]
    add ecx, [rip + g_mt + 4*MI_8]
    mov [rsp + 60], ecx
    lea edx, [r12 + rcx]
41:
    mov edi, [rip + lay_x0]
    mov esi, [rip + lay_y]
    mov r12d, edx
    mov edx, [rip + lay_right]
    sub edx, edi
    mov ecx, r12d
    mov r8d, T_HOVER
    call fill_item
    cmp dword ptr [rbx + MDB_copy], -1
    je 42f
    mov edi, MDF_SMALL
    call face_of
    mov rdi, rax
    lea rsi, [rip + .Lcopy_code]
    mov edx, 4
    call text_width
    add eax, [rip + g_mt + 4*MI_16]
    mov r12d, eax
    mov edi, MDK_COPY
    call item_new
    mov ecx, [rip + lay_right]
    sub ecx, r12d
    sub ecx, [rip + g_mt + 4*MI_8]
    mov edx, [rip + lay_x0]
    add edx, [rip + g_mt + 4*MI_8]
    cmp ecx, edx
    cmovl ecx, edx
    mov [rax + MDI_x], ecx
    mov ecx, [rip + lay_y]
    add ecx, [rip + g_mt + 4*MI_4]
    mov [rax + MDI_y], ecx
    mov [rax + MDI_w], r12d
    mov ecx, [rsp + 60]
    mov [rax + MDI_h], ecx
    mov ecx, [rbx + MDB_copy]
    mov [rax + MDI_link], ecx
    mov dword ptr [rax + MDI_color], T_MUTED
42: mov eax, [rsp + 60]
    add [rip + lay_y], eax
    M eax, MI_8
    add [rip + lay_y], eax
    mov dword ptr [rsp + 16], 0 # the line's start
    mov dword ptr [rsp + 20], 0 # the grammar's state
.Lci_line:
    mov ecx, [rsp + 16]
    cmp ecx, [rsp + 8]
    ja .Lci_done
    mov rsi, [rsp]
    mov eax, ecx                # its end
5:  cmp eax, [rsp + 8]
    jae 51f
    cmp byte ptr [rsi + rax], 10
    je 51f
    inc eax
    jmp 5b
51: mov [rsp + 24], eax
    sub eax, ecx
    mov [rsp + 28], eax         # its length
    # classes for at most 4096 bytes of it (the rest plain)
    cmp qword ptr [rsp + 40], 0
    je 6f
    mov r8d, eax
    cmp r8d, 4096
    jbe 52f
    mov r8d, 4096
52: mov rdi, [rsp + 40]
    mov rsi, [rsp]
    mov ecx, [rsp + 16]
    add rsi, rcx
    mov edx, r8d
    mov ecx, [rsp + 20]
    lea r8, [rip + cls_buf]
    call tokenize
    mov [rsp + 20], eax
6:  # segments of one class
    xor r13d, r13d              # from
    mov eax, [rip + lay_x0]
    add eax, [rip + g_mt + 4*MI_8]
    mov [rsp + 32], eax         # x
.Lci_seg:
    cmp r13d, [rsp + 28]
    jae .Lci_next
    xor r14d, r14d              # its class
    cmp qword ptr [rsp + 40], 0
    je 61f
    cmp r13d, 4096
    jae 61f
    lea rax, [rip + cls_buf]
    movzx r14d, byte ptr [rax + r13]
61: lea r12d, [r13 + 1]
62: cmp r12d, [rsp + 28]
    jae 63f
    xor eax, eax
    cmp qword ptr [rsp + 40], 0
    je 621f
    cmp r12d, 4096
    jae 621f
    lea rax, [rip + cls_buf]
    movzx eax, byte ptr [rax + r12]
621:cmp eax, r14d
    jne 63f
    inc r12d
    jmp 62b
63: mov rdi, [rsp + 48]
    mov rsi, [rsp]
    mov eax, [rsp + 16]
    add rsi, rax
    add rsi, r13
    mov edx, r12d
    sub edx, r13d
    call text_width
    mov [rsp + 36], eax
    mov edi, MDK_TEXT
    call item_new
    mov ecx, [rsp + 32]
    mov [rax + MDI_x], ecx
    mov ecx, [rip + lay_y]
    mov [rax + MDI_y], ecx
    mov ecx, [rsp + 36]
    mov [rax + MDI_w], ecx
    mov ecx, [rsp + 56]
    mov [rax + MDI_h], ecx
    mov rcx, [rsp + 48]
    mov ecx, [rcx + FACE_ascent]
    mov [rax + MDI_base], ecx
    mov dword ptr [rax + MDI_face], MDF_CODE
    lea ecx, [r14 + T_SYN]
    test r14d, r14d
    jnz 64f
    mov ecx, T_FG
64: mov [rax + MDI_color], ecx
    mov ecx, [rbx + MDB_code]
    add ecx, [rsp + 16]
    add ecx, r13d
    mov [rax + MDI_off], ecx
    mov ecx, r12d
    sub ecx, r13d
    mov [rax + MDI_len], ecx
    mov eax, [rsp + 36]
    add [rsp + 32], eax
    mov eax, [rsp + 32]
    cmp eax, [r15 + MD_maxw]
    jle 65f
    mov [r15 + MD_maxw], eax
65: mov r13d, r12d
    jmp .Lci_seg
.Lci_next:
    mov eax, [rsp + 56]
    add [rip + lay_y], eax
    mov eax, [rsp + 24]
    inc eax
    mov [rsp + 16], eax
    jmp .Lci_line
.Lci_done:
    M eax, MI_8
    add [rip + lay_y], eax
    EPILOGUE

# cell_width(run, run end, header) -> eax the natural width of a cell's runs
cell_width:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov rbx, [rip + pm]
    xor r15d, r15d
1:  cmp r12d, r13d
    jae 9f
    imul rcx, r12, MDR_SIZE
    add rcx, [rbx + MD_runs + VEC_ptr]
    mov edi, MDF_UI
    test dword ptr [rcx + MDR_style], MS_CODE
    jz 2f
    mov edi, MDF_CODE
2:  push rcx
    push rcx
    call face_of
    pop rcx
    pop rcx
    mov rdi, rax
    mov rsi, [rbx + MD_text + SB_ptr]
    mov eax, [rcx + MDR_off]
    add rsi, rax
    mov edx, [rcx + MDR_len]
    call text_width
    add r15d, eax
    inc r12d
    jmp 1b
9:  mov eax, r15d
    test r14d, r14d
    jz 91f
    inc eax                     # bold is a pixel wider
91: EPILOGUE

# row_items(block, index): a table row: the header measures the table's columns first
row_items:
    PROLOGUE 64
    mov rbx, rdi
    mov [rsp + 56], esi
    mov r15, [rip + pm]
    cmp dword ptr [rbx + MDB_hdr], 0
    je .Lri_row
    # the columns: the widest cell of each over the table's rows, padding included
    lea rdi, [rip + col_w]
    xor esi, esi
    mov edx, 4 * MD_COLS
    call memset
    mov r12d, [rsp + 56]        # its rows: the blocks after it naming it
.Lri_mrow:
    cmp r12, [r15 + MD_blocks + VEC_len]
    jae .Lri_measured
    imul r13, r12, MDB_SIZE
    add r13, [r15 + MD_blocks + VEC_ptr]
    cmp dword ptr [r13 + MDB_type], MDB_TROW
    jne .Lri_measured
    mov eax, [r13 + MDB_tbl]
    cmp eax, [rsp + 56]
    jne .Lri_measured
    mov r14d, [r13 + MDB_run0]  # cells: runs up to each MS_CELL
    mov eax, r14d
    add eax, [r13 + MDB_nrun]
    mov [rsp], eax
    xor ecx, ecx                # the column
    mov [rsp + 4], ecx
    mov [rsp + 8], r14d         # the cell's first run
1:  cmp r14d, [rsp]
    jae 3f
    imul rax, r14, MDR_SIZE
    add rax, [r15 + MD_runs + VEC_ptr]
    test dword ptr [rax + MDR_style], MS_CELL
    jz 2f
    mov edi, [rsp + 8]
    mov esi, r14d
    mov edx, [r13 + MDB_hdr]
    call cell_width
    add eax, [rip + g_mt + 4*MI_16]
    mov ecx, [rsp + 4]
    cmp ecx, MD_COLS
    jae 11f
    lea rdx, [rip + col_w]
    cmp eax, [rdx + rcx*4]
    jle 11f
    mov [rdx + rcx*4], eax
11: inc dword ptr [rsp + 4]
    lea eax, [r14 + 1]
    mov [rsp + 8], eax
2:  inc r14d
    jmp 1b
3:  inc r12
    jmp .Lri_mrow
.Lri_measured:
    # columns past the header's count go; too wide: each shrinks in proportion (32 px at least)
    mov ecx, [rbx + MDB_ncols]
    cmp ecx, MD_COLS
    jbe 4f
    mov ecx, MD_COLS
4:  mov [rsp + 12], ecx         # columns
    xor eax, eax                # their sum
    xor edx, edx
41: cmp edx, ecx
    jae 42f
    lea r8, [rip + col_w]
    add eax, [r8 + rdx*4]
    inc edx
    jmp 41b
42: mov r9d, [rip + lay_right]
    sub r9d, [rip + lay_x0]
    cmp eax, r9d
    jle 45f
    test eax, eax
    jz 45f
    mov r10d, eax
    xor edx, edx
43: cmp edx, ecx
    jae 45f
    lea r8, [rip + col_w]
    mov eax, [r8 + rdx*4]
    imul eax, r9d
    push rdx
    xor edx, edx
    div r10d
    pop rdx
    M r11d, MI_32
    cmp eax, r11d
    cmovl eax, r11d
    mov [r8 + rdx*4], eax
    inc edx
    jmp 43b
45: mov eax, [rip + lay_x0]     # their left edges
    xor edx, edx
46: cmp edx, ecx
    jae .Lri_row
    lea r8, [rip + col_x]
    mov [r8 + rdx*4], eax
    lea r8, [rip + col_w]
    add eax, [r8 + rdx*4]
    inc edx
    jmp 46b
.Lri_row:
    # the row: a tint under the header, a line under each row, its cells cut to their columns
    mov edi, MDF_UI
    call face_of
    mov ecx, [rax + FACE_lineh]
    add ecx, [rip + g_mt + 4*MI_8]
    mov [rsp + 16], ecx         # its height
    mov ecx, [rax + FACE_ascent]
    mov [rip + lay_base], ecx
    mov ecx, [rax + FACE_lineh]
    mov [rip + lay_lineh], ecx
    mov eax, [rbx + MDB_tbl]    # the table's columns (its header's)
    imul rax, rax, MDB_SIZE
    add rax, [r15 + MD_blocks + VEC_ptr]
    mov ecx, [rax + MDB_ncols]
    cmp ecx, MD_COLS
    jbe 5f
    mov ecx, MD_COLS
5:  mov [rsp + 12], ecx
    mov eax, [rax + MDB_aligns]
    mov [rsp + 20], eax
    lea r8, [rip + col_x]       # the table's width
    mov eax, [r8 + rcx*4 - 4]
    lea r8, [rip + col_w]
    add eax, [r8 + rcx*4 - 4]
    sub eax, [rip + lay_x0]
    mov [rsp + 24], eax
    cmp dword ptr [rbx + MDB_hdr], 0
    je 51f
    mov edi, [rip + lay_x0]
    mov esi, [rip + lay_y]
    mov edx, [rsp + 24]
    mov ecx, [rsp + 16]
    mov r8d, T_HOVER
    call fill_item
51: mov edi, [rip + lay_x0]
    mov esi, [rip + lay_y]
    add esi, [rsp + 16]
    M ecx, MI_1
    sub esi, ecx
    mov edx, [rsp + 24]
    mov r8d, T_BORDER
    call fill_item
    # its cells
    mov r12d, [rbx + MDB_run0]
    mov eax, r12d
    add eax, [rbx + MDB_nrun]
    mov [rsp], eax
    mov dword ptr [rsp + 4], 0  # the column
    mov [rsp + 8], r12d
6:  cmp r12d, [rsp]
    jae .Lri_done
    imul rax, r12, MDR_SIZE
    add rax, [r15 + MD_runs + VEC_ptr]
    test dword ptr [rax + MDR_style], MS_CELL
    jz 7f
    mov ecx, [rsp + 4]
    cmp ecx, [rsp + 12]
    jae 61f
    mov edi, [rsp + 8]
    mov esi, r12d
    mov edx, ecx
    mov ecx, [rbx + MDB_hdr]
    mov r8d, [rsp + 20]
    call cell_items
61: inc dword ptr [rsp + 4]
    lea eax, [r12 + 1]
    mov [rsp + 8], eax
7:  inc r12d
    jmp 6b
.Lri_done:
    mov eax, [rsp + 16]
    add [rip + lay_y], eax
    mov eax, [rsp + 24]
    add eax, [rip + lay_x0]
    cmp eax, [r15 + MD_maxw]
    jle 8f
    mov [r15 + MD_maxw], eax
8:  EPILOGUE

# cell_items(run, run end, column, header, aligns): a cell's runs on one line in its column, aligned,
#   the last one cut where the column ends
cell_items:
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rsp + 16], r8d
    mov rbx, [rip + pm]
    # where it starts: its column's left (centered or right: by its natural width)
    lea rax, [rip + col_x]
    mov r12d, [rax + rdx*4]
    add r12d, [rip + g_mt + 4*MI_8]
    lea rax, [rip + col_w]
    mov r13d, [rax + rdx*4]
    sub r13d, [rip + g_mt + 4*MI_16]   # its room
    lea r14d, [r12 + r13]       # its right
    mov ecx, edx
    add ecx, ecx
    mov eax, [rsp + 16]
    shr eax, cl
    and eax, 3
    jz 2f
    push rax
    push rax
    mov edi, [rsp + 16]
    mov esi, [rsp + 16 + 4]
    mov edx, [rsp + 16 + 12]
    call cell_width
    mov ecx, eax
    pop rax
    pop rax
    cmp ecx, r13d
    jge 2f
    mov edx, r13d
    sub edx, ecx
    cmp eax, 1
    jne 1f
    sar edx, 1
1:  add r12d, edx
2:  mov r15d, [rsp]
.Lce_run:
    cmp r15d, [rsp + 4]
    jae .Lce_done
    cmp r12d, r14d
    jge .Lce_done
    imul rax, r15, MDR_SIZE
    add rax, [rbx + MD_runs + VEC_ptr]
    mov [rsp + 24], rax
    cmp dword ptr [rax + MDR_len], 0
    je .Lce_next
    mov edi, MDF_UI
    test dword ptr [rax + MDR_style], MS_CODE
    jz 3f
    mov edi, MDF_CODE
3:  mov [rsp + 32], edi
    call face_of
    mov [rsp + 40], rax
    mov rcx, [rsp + 24]
    mov rdi, rax
    mov rsi, [rbx + MD_text + SB_ptr]
    mov eax, [rcx + MDR_off]
    add rsi, rax
    mov edx, [rcx + MDR_len]
    mov ecx, r14d
    sub ecx, r12d
    call text_fit
    test eax, eax
    jz .Lce_done
    mov [rsp + 20], eax         # the bytes that fit
    mov rcx, [rsp + 24]
    mov rdi, [rsp + 40]
    mov rsi, [rbx + MD_text + SB_ptr]
    mov edx, [rcx + MDR_off]
    add rsi, rdx
    mov edx, [rsp + 20]
    call text_width
    mov r13d, eax
    mov edi, MDK_TEXT
    call item_new
    mov rcx, [rsp + 24]
    mov [rax + MDI_x], r12d
    mov edx, [rip + lay_y]
    add edx, [rip + g_mt + 4*MI_4]
    mov [rax + MDI_y], edx
    mov [rax + MDI_w], r13d
    mov edx, [rip + lay_lineh]
    mov [rax + MDI_h], edx
    mov edx, [rip + lay_base]
    mov [rax + MDI_base], edx
    mov edx, [rsp + 32]
    mov [rax + MDI_face], edx
    mov edx, [rcx + MDR_style]
    cmp dword ptr [rsp + 12], 0
    je 4f
    or edx, MS_STRONG
4:  mov [rax + MDI_style], edx
    mov edx, [rcx + MDR_link]
    mov [rax + MDI_link], edx
    mov edx, T_FG
    test dword ptr [rcx + MDR_style], MS_LINK
    jz 5f
    mov edx, T_ACCENT
5:  mov [rax + MDI_color], edx
    mov edx, [rcx + MDR_off]
    mov [rax + MDI_off], edx
    mov edx, [rsp + 20]
    mov [rax + MDI_len], edx
    add r12d, r13d
    cmp edx, [rcx + MDR_len]
    jb .Lce_done                # cut: the rest left out
.Lce_next:
    inc r15d
    jmp .Lce_run
.Lce_done:
    EPILOGUE

# md_measure(m, max) -> eax the widest line when laid out at max
FN md_measure
    push rbx
    mov rbx, rdi
    call md_layout
    mov eax, [rbx + MD_maxw]
    pop rbx
    ret

# ---------------- drawing ----------------

# md_draw(m, x, y, w, h, scroll, [stack] id) -> eax the link clicked, or -1: the part of the laid-out
#   document in view (lay it out at w first); links are buttons id + their index
FN md_draw
    PROLOGUE 64
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    mov [rsp + 16], r9d
    mov eax, [rbp + 16]
    mov [rsp + 20], eax         # the first id
    mov dword ptr [rsp + 24], -1    # clicked
    mov dword ptr [rsp + 28], -1    # hovered
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call gfx_clip_push
    mov rdi, rbx                # the selection behind the text
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 12]
    mov r8d, [rsp + 16]
    call sel_draw
    xor r12d, r12d
.Lmd_item:
    cmp r12, [rbx + MD_items + VEC_len]
    jae .Lmd_done
    imul r13, r12, MDI_SIZE
    add r13, [rbx + MD_items + VEC_ptr]
    mov r14d, [r13 + MDI_y]
    sub r14d, [rsp + 16]
    add r14d, [rsp + 4]         # its top on screen
    mov eax, r14d
    add eax, [r13 + MDI_h]
    cmp eax, [rsp + 4]
    jl .Lmd_next
    mov eax, [rsp + 4]
    add eax, [rsp + 12]
    cmp r14d, eax
    jge .Lmd_next
    mov r15d, [r13 + MDI_x]
    add r15d, [rsp]             # its left on screen
    mov eax, [r13 + MDI_color]
    lea rcx, [rip + g_theme]
    mov eax, [rcx + rax*4]
    mov [rsp + 32], eax         # its color
    mov eax, [r13 + MDI_kind]
    cmp eax, MDK_TEXT
    je .Lmd_text
    cmp eax, MDK_FILL
    je .Lmd_fill
    cmp eax, MDK_DOT
    je .Lmd_dot
    cmp eax, MDK_BOX
    je .Lmd_box
    cmp eax, MDK_IMAGE
    je .Lmd_image
    cmp eax, MDK_COPY
    je .Lmd_copy
    jmp .Lmd_next
.Lmd_copy:
    mov edi, [r13 + MDI_link]
    add edi, [rsp + 20]
    mov esi, r15d
    mov edx, r14d
    mov ecx, [r13 + MDI_w]
    mov r8d, [r13 + MDI_h]
    call ui_btn
    mov [rsp + 56], eax
    test eax, UB_HOVER
    jz 1f
    mov ecx, [r13 + MDI_link]
    mov [rsp + 28], ecx
    mov dword ptr [rip + g_cursor], CUR_POINTER
1:  test eax, UB_CLICK
    jz 2f
    mov ecx, [r13 + MDI_link]
    mov [rsp + 24], ecx
2:  mov edi, r15d
    mov esi, r14d
    mov edx, [r13 + MDI_w]
    mov ecx, [r13 + MDI_h]
    M r8d, MI_3
    COLOR r9d, T_BORDER
    mov eax, [r13 + MDI_link]
    cmp eax, [rbx + MD_focus]
    je 3f
    test dword ptr [rsp + 56], UB_HOVER
    jz 4f
3:  COLOR r9d, T_ACCENT
4:  COLOR eax, T_PANEL
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    mov edi, MDF_SMALL
    call face_of
    mov rdi, rax
    mov esi, r15d
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, r14d
    add edx, [rip + g_mt + 4*MI_4]
    add edx, [rax + FACE_ascent]
    lea rcx, [rip + .Lcopy_code]
    mov r8d, 4
    COLOR r9d, T_FG
    call text_draw
    jmp .Lmd_next
.Lmd_image:
    mov eax, [r13 + MDI_style]
    imul r8, rax, MDM_SIZE
    add r8, [rbx + MD_imgs + VEC_ptr]
    mov edi, r15d
    mov esi, r14d
    mov edx, [r13 + MDI_w]
    mov ecx, [r13 + MDI_h]
    cmp dword ptr [r8 + MDM_kind], 1
    jne 1f
    mov r9d, [r8 + MDM_id]
    mov r8, [rbx + MD_ext]
    call viewimg_blit_id
    jmp .Lmd_next
1:  add r8, MDM_img
    call viewimg_blit_img
    jmp .Lmd_next
.Lmd_fill:
    mov edi, r15d
    mov esi, r14d
    mov edx, [r13 + MDI_w]
    mov ecx, [r13 + MDI_h]
    M r8d, MI_3
    cmp ecx, r8d
    jg 1f
    xor r8d, r8d                # thin: square
1:  mov r9d, [rsp + 32]
    call gfx_round_rect
    jmp .Lmd_next
.Lmd_dot:
    mov edi, r15d
    mov esi, r14d
    mov edx, [r13 + MDI_w]
    mov ecx, [r13 + MDI_h]
    mov r8d, edx
    sar r8d, 1
    cmp dword ptr [r13 + MDI_style], 0
    jne 1f
    mov r9d, [rsp + 32]         # a ring: the color round the background
    COLOR eax, T_BG
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    jmp .Lmd_next
1:  mov r9d, [rsp + 32]
    call gfx_round_rect
    jmp .Lmd_next
.Lmd_box:
    mov edi, r15d
    mov esi, r14d
    mov edx, [r13 + MDI_w]
    mov ecx, [r13 + MDI_h]
    M r8d, MI_2
    mov r9d, [rsp + 32]
    COLOR eax, T_BG
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    cmp dword ptr [r13 + MDI_style], 0
    je .Lmd_next
    mov edi, IC_CHECK
    mov esi, r15d
    mov edx, r14d
    mov ecx, [r13 + MDI_w]
    COLOR r8d, T_ACCENT
    call icon_draw
    jmp .Lmd_next
.Lmd_text:
    mov edi, [r13 + MDI_face]
    call face_of
    mov [rsp + 40], rax
    mov rsi, [rbx + MD_text + SB_ptr]
    mov eax, [r13 + MDI_off]
    add rsi, rax
    mov [rsp + 48], rsi
    # a link: a button, underlined while the pointer is on it
    mov eax, [r13 + MDI_link]
    test eax, eax
    js 2f
    and eax, MD_LINKS_MAX - 1
    add eax, [rsp + 20]
    mov edi, eax
    mov esi, r15d
    mov edx, r14d
    mov ecx, [r13 + MDI_w]
    mov r8d, [r13 + MDI_h]
    call ui_btn
    test eax, UB_HOVER
    jz 1f
    mov ecx, [r13 + MDI_link]
    mov [rsp + 28], ecx
    mov dword ptr [rip + g_cursor], CUR_POINTER
1:  test eax, UB_CLICK
    jz 2f
    mov ecx, [r13 + MDI_link]
    mov [rsp + 24], ecx
2:  mov rdi, [rsp + 40]
    mov esi, r15d
    mov edx, r14d
    add edx, [r13 + MDI_base]
    mov rcx, [rsp + 48]
    mov r8d, [r13 + MDI_len]
    mov r9d, [rsp + 32]
    call text_draw
    test dword ptr [r13 + MDI_style], MS_STRONG
    jz 3f
    mov rdi, [rsp + 40]         # bold: again a pixel to the right
    lea esi, [r15 + 1]
    mov edx, r14d
    add edx, [r13 + MDI_base]
    mov rcx, [rsp + 48]
    mov r8d, [r13 + MDI_len]
    mov r9d, [rsp + 32]
    call text_draw
3:  test dword ptr [r13 + MDI_style], MS_STRIKE
    jz 4f
    mov rax, [rsp + 40]         # a line through its middle
    mov esi, [rax + FACE_ascent]
    imul esi, esi, 2
    mov eax, esi
    xor edx, edx
    mov ecx, 3
    div ecx
    mov esi, [r13 + MDI_base]
    sub esi, eax
    add esi, r14d
    mov edi, r15d
    mov edx, [r13 + MDI_w]
    M ecx, MI_1
    mov r8d, [rsp + 32]
    call gfx_fill
4:  mov eax, [r13 + MDI_link]
    test eax, eax
    js .Lmd_next
    cmp eax, [rbx + MD_focus]
    je 41f
    cmp eax, [rbx + MD_hover]
    jne .Lmd_next
41: mov edi, r15d               # the link under the pointer or the keyboard: underlined
    mov esi, r14d
    add esi, [r13 + MDI_base]
    add esi, [rip + g_mt + 4*MI_2]
    mov edx, [r13 + MDI_w]
    M ecx, MI_1
    mov r8d, [rsp + 32]
    call gfx_fill
.Lmd_next:
    inc r12
    jmp .Lmd_item
.Lmd_done:
    call gfx_clip_pop
    mov eax, [rsp + 28]
    cmp eax, [rbx + MD_hover]
    je 1f
    mov [rbx + MD_hover], eax
    mov dword ptr [rip + g_dirty], 1
1:  mov eax, [rsp + 24]
    EPILOGUE

.section .rodata
.Lp_http: .asciz "http://"
.Lp_https: .asciz "https://"
.Lp_rhun: .asciz "rhun://"
.Lcopy_code: .asciz "Copy"
.Lcopied_code: .asciz "Code copied"
.Lcopy_failed: .asciz "Could not copy code"
.Lb_doc: .asciz "doc"
.Ld_base: .asciz "base "
.Ld_sel: .asciz "sel"
.p2align 2
sel_fields: .long MD_sa, MD_sao, MD_sb, MD_sbo, -1
.Lb_base: .asciz "base"
.Lsp: .asciz " "
url_before: .asciz " \t\n(*_~"
url_trail: .asciz ".,:;!?\"')"
.Le_amp: .asciz "amp"
.Le_lt: .asciz "lt"
.Le_gt: .asciz "gt"
.Le_quot: .asciz "quot"
.Le_apos: .asciz "apos"
.Le_nbsp: .asciz "nbsp"
.Le_copy: .asciz "copy"
.Le_mdash: .asciz "mdash"
.Le_ndash: .asciz "ndash"
.Le_hellip: .asciz "hellip"
.p2align 3
entities: .quad .Le_amp, '&', .Le_lt, '<', .Le_gt, '>', .Le_quot, '"', .Le_apos, 0x27
    .quad .Le_nbsp, 0xa0, .Le_copy, 0xa9, .Le_mdash, 0x2014, .Le_ndash, 0x2013, .Le_hellip, 0x2026, 0, 0
md_faces: .quad g_face_ui, g_face_small, g_face_big, g_face_huge, g_face_code, em_face
# bytes that end a stretch of plain text in inline parsing
special:
    .byte 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0     # 0x00: \x01, LF
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0     # 0x20: ! & *
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0     # 0x30: <
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1     # 0x50: [ \ _
    .byte 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0     # 0x60: `
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0     # 0x70: ~
    .zero 128

# ---------------- for the tests ----------------

.text
# md_dump(m, sb): "blocks=N height=H maxw=W", a line per block ("block I type=T level=L quote=Q
#   list=D marker=M num=N line=K"), per layout item ("item KIND x=X y=Y w=W h=H face=F style=S
#   color=C link=L [text=T]") and per link ("link I TARGET")
FN md_dump
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Ld_blocks]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + MD_blocks + VEC_len]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_height]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + MD_height]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_maxw]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rbx + MD_maxw]
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    cmp dword ptr [rbx + MD_sel], 0     # the selection: "sel A AO B BO"
    je 10f
    mov rdi, r12
    lea rsi, [rip + .Ld_sel]
    call sb_push_cstr
    lea r13, [rip + sel_fields]
101:mov eax, [r13]
    cmp eax, -1
    je 102f
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov eax, [r13]
    mov esi, [rbx + rax]
    mov rdi, r12
    call sb_push_u64
    add r13, 4
    jmp 101b
102:mov rdi, r12
    mov esi, 10
    call sb_push_byte
10: cmp qword ptr [rbx + MD_base], 0
    je 11f
    mov rdi, r12
    lea rsi, [rip + .Ld_base]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + MD_base]
    call sb_push_cstr
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
11: xor r13d, r13d
1:  cmp r13, [rbx + MD_blocks + VEC_len]
    jae 2f
    imul r14, r13, MDB_SIZE
    add r14, [rbx + MD_blocks + VEC_ptr]
    mov rdi, r12
    lea rsi, [rip + .Ld_block]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_type]
    call sb_push_cstr
    mov eax, [r14 + MDB_type]
    lea rcx, [rip + type_names]
    mov rsi, [rcx + rax*8 - 8]
    mov rdi, r12
    call sb_push_cstr
    lea r15, [rip + block_fields]
11: mov rsi, [r15]
    test rsi, rsi
    jz 12f
    mov rdi, r12
    call sb_push_cstr
    mov eax, [r15 + 8]
    mov esi, [r14 + rax]
    mov rdi, r12
    call sb_push_u64
    add r15, 16
    jmp 11b
12: mov rdi, r12
    mov esi, 10
    call sb_push_byte
    inc r13
    jmp 1b
2:  xor r13d, r13d
3:  cmp r13, [rbx + MD_items + VEC_len]
    jae 5f
    imul r14, r13, MDI_SIZE
    add r14, [rbx + MD_items + VEC_ptr]
    mov rdi, r12
    lea rsi, [rip + .Ld_item]
    call sb_push_cstr
    mov eax, [r14 + MDI_kind]
    lea rcx, [rip + kind_names]
    mov rsi, [rcx + rax*8 - 8]
    mov rdi, r12
    call sb_push_cstr
    lea r15, [rip + item_fields]
31: mov rsi, [r15]
    test rsi, rsi
    jz 32f
    mov rdi, r12
    call sb_push_cstr
    mov eax, [r15 + 8]
    movsxd rsi, dword ptr [r14 + rax]
    test rsi, rsi
    jns 311f
    mov rdi, r12
    mov esi, '-'
    call sb_push_byte
    mov eax, [r15 + 8]
    movsxd rsi, dword ptr [r14 + rax]
    neg rsi
311:mov rdi, r12
    call sb_push_u64
    add r15, 16
    jmp 31b
32: cmp dword ptr [r14 + MDI_kind], MDK_TEXT
    jne 33f
    mov rdi, r12
    lea rsi, [rip + .Ld_text]
    call sb_push_cstr
    mov rsi, [rbx + MD_text + SB_ptr]
    mov eax, [r14 + MDI_off]
    add rsi, rax
    mov edx, [r14 + MDI_len]
    mov rdi, r12
    call sb_push
33: mov rdi, r12
    mov esi, 10
    call sb_push_byte
    inc r13
    jmp 3b
5:  xor r13d, r13d
6:  cmp r13, [rbx + MD_links + VEC_len]
    jae 9f
    mov rax, [rbx + MD_links + VEC_ptr]
    test dword ptr [rax + r13*8 + MDL_len], MDL_COPY
    jnz 7f
    mov rdi, r12
    lea rsi, [rip + .Ld_link]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    call sb_push_u64
    mov rdi, r12
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    call md_link
    mov rsi, rax
    mov rdi, r12
    call sb_push
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    jmp 8f
7:  mov rdi, r12
    lea rsi, [rip + .Ld_copy]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    call sb_push_u64
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
8:
    inc r13
    jmp 6b
9:  EPILOGUE

.section .rodata
.Ld_blocks: .asciz "blocks="
.Ld_height: .asciz " height="
.Ld_maxw: .asciz " maxw="
.Ld_block: .asciz "block "
.Ld_type: .asciz " type="
.Ld_item: .asciz "item "
.Ld_text: .asciz " text="
.Ld_link: .asciz "link "
.Ld_copy: .asciz "copy-action "
.Lt_para: .asciz "para"
.Lt_head: .asciz "head"
.Lt_code: .asciz "code"
.Lt_rule: .asciz "rule"
.Lt_row: .asciz "row"
.Lk_text: .asciz "text"
.Lk_fill: .asciz "fill"
.Lk_dot: .asciz "dot"
.Lk_box: .asciz "box"
.Lk_line: .asciz "line"
.Lk_image: .asciz "image"
.Lf_level: .asciz " level="
.Lf_quote: .asciz " quote="
.Lf_list: .asciz " list="
.Lf_marker: .asciz " marker="
.Lf_num: .asciz " num="
.Lf_line: .asciz " line="
.Lf_runs: .asciz " runs="
.Lf_x: .asciz " x="
.Lf_y: .asciz " y="
.Lf_w: .asciz " w="
.Lf_h: .asciz " h="
.Lf_face: .asciz " face="
.Lf_style: .asciz " style="
.Lf_color: .asciz " color="
.Lf_link: .asciz " link="
.p2align 3
type_names: .quad .Lt_para, .Lt_head, .Lt_code, .Lt_rule, .Lt_row
.Lk_copy: .asciz "copy"
.p2align 3
kind_names: .quad .Lk_text, .Lk_fill, .Lk_dot, .Lk_box, .Lk_line, .Lk_image, .Lk_copy
block_fields: .quad .Lf_level, MDB_level, .Lf_quote, MDB_quote, .Lf_list, MDB_list, .Lf_marker, MDB_marker
    .quad .Lf_num, MDB_num, .Lf_line, MDB_line, .Lf_runs, MDB_nrun, 0, 0
item_fields: .quad .Lf_x, MDI_x, .Lf_y, MDI_y, .Lf_w, MDI_w, .Lf_h, MDI_h, .Lf_face, MDI_face
    .quad .Lf_style, MDI_style, .Lf_color, MDI_color, .Lf_link, MDI_link, 0, 0
