# A message's parts (generic: nothing here knows which agent takes them). A pack (AP, rhun.inc) holds the
# parts (MP) that go with a prompt: files the user attached (an image, a PDF, a text file) and what a Send's
# hooks add (the editor's selection or open file, a terminal's text). A driver that takes parts (DRVC_PARTS)
# writes them in its own shapes; nothing above the driver names those shapes.
#
# Who owns a pack, one at a time: the box (the conversation the box writes to; parked in AS_parts while the
# box is another's, or per kind for a new conversation left before its first prompt, as the box's text is),
# then agent_send_with (agent_drv.s): written at once it is freed; waiting for a start it is kept whole in the
# queued block; written during a turn (held) it is slimmed (agatt_slim) into AH_pack until its turn starts. A
# waiting or held prompt that will not go gives its pack back with its text (agatt_return). A conversation
# that closes frees what it holds (agatt_row_gone, agent_drv.s's live_free).
#
# A file is looked at before a byte of it is read: vfs_stat (a folder becomes a mention, anything but a
# regular file is refused, so a FIFO or a device is never opened), then its first 8 KiB and its name give
# its kind, then its size is judged against its kind's limit and the pack's room, and only then it is read,
# capped at the limit (vfs_read_limited: a file that grew past it meanwhile is refused too).
#
#   agatt_new() -> rax AP*;  agatt_free(AP* or 0)
#   agatt_count(AP* or 0) -> rax n;  agatt_part(AP*, i) -> rax MP*
#   agatt_add_file(AP*, path cstr) -> eax ATT_*      (the name is the path's last part)
#   agatt_add_bytes(AP*, MPK_*, name cstr, mime cstr or 0, ptr, len) -> eax ATT_*   (copied; a pasted image)
#   agatt_add_text(AP*, MPK_*, name cstr, path cstr or 0, ptr, len, [rsp] l0, [rsp+8] l1) -> eax ATT_*
#                                       (copied; MPF_AUTO for the selection, the open file and a terminal)
#   agatt_remove(AP*, i);  agatt_slim(AP*);  agatt_drop_auto(AP*)
#   agatt_pathless(AP*) -> rax bytes;  agatt_drop_pathless(AP*) -> rax bytes freed   (the held cap)
#   agatt_return(AS*, AP*)              a waiting or held prompt that will not go: its parts join that
#                                       conversation's box (a slimmed part read again from its path; context
#                                       and terminal parts dropped); the pack is freed
#   agatt_box() -> rax AP* or 0;  agatt_box_make() -> rax AP*;  agatt_take() -> rax AP* or 0 (the box gives
#   it up: the caller owns it);  agatt_keep(AP*) (a refused Send gives it back);  agatt_tidy()
#   agatt_park(AS*), agatt_park_kind(kind), agatt_drop_box(), agatt_unpark(AS* or 0, kind),
#   agatt_row_gone(AS*, was the box's owner)   composer_owner's and composer_row_gone's: the pack follows the
#                                       box's text (a conversation that goes takes its pack with it)
#   agatt_reset()                       quit, the project changes (agent_drv_shutdown): every pack the box keeps
#   agatt_caps() -> eax DRVC_* of the box's driver (agent-test-caps overrides them for the UI's questions);
#   agatt_caps_of(AS* or 0, kind) -> eax
#   agatt_attach_paths(list, len) -> eax n   NUL-ended paths into the box's pack: folders become mentions, the
#                                       unsupported names one band, each refusal a toast
#   agatt_chip_line(sb, kind byte, label ptr, len, target ptr, len)   one chip of a row's chips text (AM_name
#                                       with AMF_CHIPS): KIND TAB LABEL TAB TARGET, TABs and line feeds made
#                                       spaces; agatt_chips(AP*, sb) a pack's, LF between them;
#                                       agatt_chips_dup(AP*) -> rax owned cstr or 0
#   agatt_row_chips(AS*, row index, chips cstr or 0)   a row gets that chips text (AMF_CHIPS)
#   agatt_live(sb) "live=N bytes=N";  agatt_dump(sb) print-agent-attachments
#   agterm_parts(AS* or 0, AP*, ptr, len), agterm_block(ptr, len), agterm_unblock(name ptr, len)   hooks of
#                                       later tasks (task 7: a part per @terminal: mention): nothing yet
#   g_att_wait_ms (agent-timing attach=): a wait between the look at a file and its read, for a test
.include "rhun.inc"

.equ HEAD_MAX, 8192             # what is read of a file to know its kind
.equ NAME_MAX, 255              # a part's name at most, cut at a character
.equ MPF_DROPPED, 4             # a held prompt's pathless bytes went (the held cap): it cannot come back
.equ KINDS, 8                   # new conversations' packs, by AS_kind
.equ TX_COUNT, 125              # the extension's text extensions (Eje, WV@3688316)
.equ MB, 1048576
.equ CH_ROWS, 3                 # the chips' rows shown at most (more scroll inside them)

.bss
.p2align 3
bx_pack: .quad 0                # the box's pack (the conversation the box writes to), or 0
kind_packs: .zero 8 * KINDS     # a new conversation's pack left before its first prompt, by kind
live_n: .quad 0                 # packs alive in the window
live_bytes: .quad 0             #   and the bytes their parts hold
last_limit: .quad 0             # the limit the last ATT_BIG was about
head: .zero HEAD_MAX + 16
lname: .zero NAME_MAX + 16
wsb: .zero SB_SIZE              # words being made
usb: .zero SB_SIZE              # the unsupported names of one attach
unsup_n: .quad 0
.globl g_att_gen
g_att_gen: .quad 0              # moves whenever the box's pack changes (the chips' layout, task 3)
ch_pack: .quad 0                # the chips' layout (task 3): for which pack, generation, width, size, face
ch_gen: .quad 0
ch_face: .quad 0
ch_measures: .quad 0            #   the layouts made since start
ch_w: .long 0
ch_px: .long 0
ch_n: .long 0                   #   the chips laid out, their rows, the scroll (a wheel over them)
ch_rows: .long 0
ch_scroll: .long 0
ch_drawn: .long 0               #   the chips drawn last (at_*, xb_*)
ch_x: .zero 4 * AP_MAX_PARTS    #   each chip's place in the area, its width, its label in ch_lsb
ch_y: .zero 4 * AP_MAX_PARTS
ch_cw: .zero 4 * AP_MAX_PARTS
ch_lo: .zero 4 * AP_MAX_PARTS
ch_ll: .zero 4 * AP_MAX_PARTS
at_x: .zero 4 * AP_MAX_PARTS    #   as drawn last: each chip's place on screen, its x's
at_y: .zero 4 * AP_MAX_PARTS
xb_x: .zero 4 * AP_MAX_PARTS
xb_y: .zero 4 * AP_MAX_PARTS
.p2align 3
ch_lsb: .zero SB_SIZE

.data
.p2align 2
.globl g_att_wait_ms, g_att_test_caps
g_att_wait_ms: .long 0
g_att_test_caps: .long -1       # agent-test-caps: the DRVC_* bits the UI is told, -1 the driver's own

.text

# ---- a pack and its parts ----

# FN agatt_new() -> rax an empty pack (the caller owns it)
FN agatt_new
    sub rsp, 8
    mov edi, AP_SIZE
    call mem_alloc
    inc qword ptr [rip + live_n]
    add rsp, 8
    ret

# part_drop(MP*): what the part owns goes (its bytes counted off), the part zeroed
part_drop:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + MP_name]
    call mem_free
    mov rdi, [rbx + MP_path]
    call mem_free
    mov rdi, [rbx + MP_data]
    test rdi, rdi
    jz 1f
    mov rax, [rbx + MP_len]
    sub [rip + live_bytes], rax
    call mem_free
1:  mov rdi, rbx
    xor esi, esi
    mov edx, MP_SIZE
    call memset
    EPILOGUE

# FN agatt_free(AP* or 0): a pack and everything it owns
FN agatt_free
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    xor r12d, r12d
1:  cmp r12, [rbx + AP_parts + VEC_len]
    jae 2f
    imul rdi, r12, MP_SIZE
    add rdi, [rbx + AP_parts + VEC_ptr]
    call part_drop
    inc r12
    jmp 1b
2:  lea rdi, [rbx + AP_parts]
    call vec_free
    mov rdi, rbx
    call mem_free
    dec qword ptr [rip + live_n]
9:  EPILOGUE

# FN agatt_count(AP* or 0) -> rax its parts
FN agatt_count
    xor eax, eax
    test rdi, rdi
    jz 1f
    mov rax, [rdi + AP_parts + VEC_len]
1:  ret

# FN agatt_part(AP*, i) -> rax its i-th part (MP*)
FN agatt_part
    imul rax, rsi, MP_SIZE
    add rax, [rdi + AP_parts + VEC_ptr]
    ret

# is_file(kind) -> eax 1 for a file's part (image, PDF, text): counted in AP_bytes
is_file:
    xor eax, eax
    cmp edi, MPK_IMAGE
    jb 1f
    cmp edi, MPK_TEXT
    ja 1f
    inc eax
1:  ret

# kind_limit(kind) -> rax the most bytes a part of that kind may have
kind_limit:
    mov eax, MP_IMAGE_MAX
    cmp edi, MPK_IMAGE
    je 1f
    mov eax, MP_PDF_MAX
    cmp edi, MPK_PDF
    je 1f
    mov eax, MP_TEXT_MAX
    cmp edi, MPK_TEXT
    je 1f
    mov eax, MP_SEL_MAX
1:  ret

# clean_name(ptr, len) -> rax an owned cstr of it: control characters made spaces, at most NAME_MAX bytes
#   (cut before a character that would cross the limit)
clean_name:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, NAME_MAX
    jbe 2f
    mov r12, NAME_MAX
1:  test r12, r12               # the byte at the cut continues a character: the cut goes before it
    jz 2f
    movzx eax, byte ptr [rbx + r12]
    and eax, 0xc0
    cmp eax, 0x80
    jne 2f
    dec r12
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r12
    call mem_dup
    xor ecx, ecx
3:  cmp rcx, r12
    jae 9f
    movzx edx, byte ptr [rax + rcx]
    cmp edx, ' '
    jb 4f
    cmp edx, 0x7f
    jne 5f
4:  mov byte ptr [rax + rcx], ' '
5:  inc rcx
    jmp 3b
9:  EPILOGUE

# base_of(path cstr) -> rax its last part, rdx its length
base_of:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
    mov rcx, rax
1:  test rcx, rcx
    jz 2f
    cmp byte ptr [rbx + rcx - 1], '/'
    je 2f
    dec rcx
    jmp 1b
2:  lea rax, [rbx + rcx]
    mov rdx, r12
    sub rdx, rcx
    EPILOGUE

# sniff(ptr, len) -> rax the image's media type when the bytes are a PNG, a JPEG, a GIF or a WebP, else 0
sniff:
    xor eax, eax
    cmp rsi, 12
    jb 9f
    cmp dword ptr [rdi], 0x474e5089             # \x89PNG\r\n\x1a\n
    jne 1f
    cmp dword ptr [rdi + 4], 0x0a1a0a0d
    jne 1f
    lea rax, [rip + .Lm_png]
    ret
1:  cmp word ptr [rdi], 0xd8ff                  # FF D8 FF
    jne 2f
    cmp byte ptr [rdi + 2], 0xff
    jne 2f
    lea rax, [rip + .Lm_jpeg]
    ret
2:  cmp dword ptr [rdi], 0x38464947             # GIF8 7a / 9a
    jne 3f
    cmp byte ptr [rdi + 5], 'a'
    jne 3f
    lea rax, [rip + .Lm_gif]
    ret
3:  cmp dword ptr [rdi], 0x46464952             # RIFF .... WEBP
    jne 9f
    cmp dword ptr [rdi + 8], 0x50424557
    jne 9f
    lea rax, [rip + .Lm_webp]
9:  ret

# tx_cmp(ptr, len, cstr) -> eax < 0, 0, > 0: the bytes against the cstr, as Python sorts them
tx_cmp:
    xor ecx, ecx
1:  movzx r8d, byte ptr [rdx + rcx]
    cmp rcx, rsi
    jae 3f
    test r8d, r8d
    jz 4f
    movzx eax, byte ptr [rdi + rcx]
    sub eax, r8d
    jnz 9f
    inc rcx
    jmp 1b
3:  xor eax, eax                # the key ended: equal when the cstr did too
    test r8d, r8d
    jz 9f
    mov eax, -1
    ret
4:  mov eax, 1
9:  ret

# tx_has(ptr, len) -> eax 1 when the (lower-case) word is in the extension's list of text names
tx_has:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d              # lo
    mov r14d, TX_COUNT          # hi
1:  cmp r13, r14
    jae 8f
    lea r15, [r13 + r14]
    shr r15, 1
    lea rax, [rip + tx_names]
    mov rdx, [rax + r15*8]
    mov rdi, rbx
    mov rsi, r12
    call tx_cmp
    test eax, eax
    jz 7f
    js 2f
    lea r13, [r15 + 1]
    jmp 1b
2:  mov r14, r15
    jmp 1b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# name_is_text(ptr, len) -> eax 1 when the file's name says text (the extension's zGt: its extension, or the
#   whole name, in the list, or the whole name one of six), compared in lower case
name_is_text:
    PROLOGUE
    xor r15d, r15d
    test rsi, rsi
    jz 9f
    cmp rsi, NAME_MAX
    ja 9f
    mov rbx, rsi
    lea rdx, [rip + lname]
    xor ecx, ecx
1:  movzx eax, byte ptr [rdi + rcx]
    lea r8d, [rax - 'A']
    cmp r8d, 25
    ja 2f
    add eax, 32
2:  mov [rdx + rcx], al
    inc rcx
    cmp rcx, rbx
    jb 1b
    mov rcx, rbx                # the part after the last ".", or the whole name without one
3:  test rcx, rcx
    jz 4f
    cmp byte ptr [rdx + rcx - 1], '.'
    je 4f
    dec rcx
    jmp 3b
4:  lea rdi, [rdx + rcx]
    mov rsi, rbx
    sub rsi, rcx
    jz 5f                       # ends with ".": no extension
    call tx_has
    test eax, eax
    jnz 8f
5:  lea rdi, [rip + lname]
    mov rsi, rbx
    call tx_has
    test eax, eax
    jnz 8f
    lea r12, [rip + tx_bare]
6:  mov rdx, [r12]
    test rdx, rdx
    jz 9f
    lea rdi, [rip + lname]
    mov rsi, rbx
    call str_eq_cstr
    test eax, eax
    jnz 8f
    add r12, 8
    jmp 6b
8:  mov r15d, 1
9:  mov eax, r15d
    EPILOGUE

# head_is_text(n, whole) -> eax 1 when the first n bytes in head hold no NUL and are valid UTF-8 (whole 0: a
#   character the end of the head cut is left out)
head_is_text:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rip + head]
    test esi, esi
    jnz 3f
    mov rcx, rbx                # the last character's first byte, among the last four
    mov r8d, 4
1:  test rcx, rcx
    jz 3f
    test r8d, r8d
    jz 3f
    dec rcx
    dec r8d
    movzx eax, byte ptr [r12 + rcx]
    mov edx, eax
    and edx, 0xc0
    cmp edx, 0x80
    je 1b
    mov edx, 1                  # its length by its first byte
    cmp eax, 0xc0
    jb 2f
    mov edx, 2
    cmp eax, 0xe0
    jb 2f
    mov edx, 3
    cmp eax, 0xf0
    jb 2f
    mov edx, 4
2:  lea rax, [rcx + rdx]
    cmp rax, rbx
    jbe 3f
    mov rbx, rcx                # cut: it is left out
3:  xor ecx, ecx
4:  cmp rcx, rbx
    jae 5f
    cmp byte ptr [r12 + rcx], 0
    je 8f
    inc rcx
    jmp 4b
5:  mov rdi, r12
    mov rsi, rbx
    call snippet_utf8_valid
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# push_part(AP*) -> rax a new zeroed part at the end
push_part:
    lea rdi, [rdi + AP_parts]
    mov esi, MP_SIZE
    jmp vec_push

# wait_test(): agent-timing attach=MS: the wait between a file's look and its read
wait_test:
    mov eax, [rip + g_att_wait_ms]
    test eax, eax
    jz 9f
    sub rsp, 24
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov [rsp], rax              # seconds
    imul edx, edx, 1000000
    mov [rsp + 8], rdx          # nanoseconds
    mov rdi, rsp
    xor esi, esi
    SYS 35                      # nanosleep
    add rsp, 24
9:  ret

# FN agatt_add_file(AP*, path cstr) -> eax ATT_*: see the top. Locals: [rsp] media type, [rsp + 8] size
FN agatt_add_file
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call vfs_stat
    test rax, rax
    mov eax, ATT_READ
    js 9f
    mov ecx, [rip + vfs_statbuf + 24]
    and ecx, 0xf000
    mov eax, ATT_FOLDER
    cmp ecx, 0x4000
    je 9f
    mov eax, ATT_NOTFILE        # a FIFO, a device, a socket: never opened
    cmp ecx, 0x8000
    jne 9f
    mov r13, [rip + vfs_statbuf + 48]
    mov [rsp + 8], r13
    mov eax, ATT_EMPTY
    test r13, r13
    jz 9f
    mov qword ptr [rip + last_limit], AP_MAX_BYTES
    mov eax, ATT_BIG            # past every kind's limit: not opened
    cmp r13, AP_MAX_BYTES
    ja 9f
    mov rdi, r12                # its kind: the first bytes, then the name
    lea rsi, [rip + head]
    mov edx, HEAD_MAX
    call vfs_read_head
    test rax, rax
    mov ecx, ATT_READ
    cmovs eax, ecx
    js 9f
    mov r14, rax
    lea rdi, [rip + head]
    mov rsi, r14
    call sniff
    mov [rsp], rax
    mov r15d, MPK_IMAGE
    test rax, rax
    jnz 3f
    lea rax, [rip + .Lm_pdf]
    mov [rsp], rax
    mov r15d, MPK_PDF
    cmp r14, 5
    jb 1f
    cmp dword ptr [rip + head], 0x46445025      # %PDF-
    jne 1f
    cmp byte ptr [rip + head + 4], '-'
    je 3f
1:  lea rax, [rip + .Lm_text]
    mov [rsp], rax
    mov r15d, MPK_TEXT
    mov rdi, r12
    call base_of
    mov rdi, rax
    mov rsi, rdx
    call name_is_text
    test eax, eax
    jnz 3f
    mov rdi, r14                # a name the list does not know: text when it looks like text
    xor esi, esi
    cmp r14, [rsp + 8]
    setae sil
    call head_is_text
    test eax, eax
    mov eax, ATT_UNSUPPORTED
    jz 9f
3:  mov edi, r15d               # its kind's limit, the pack's room
    call kind_limit
    mov [rip + last_limit], rax
    mov r14, rax
    mov eax, ATT_BIG
    cmp r13, r14
    ja 9f
    mov eax, ATT_FULL
    cmp qword ptr [rbx + AP_parts + VEC_len], AP_MAX_PARTS
    jae 9f
    mov rax, [rbx + AP_bytes]
    add rax, r13
    cmp rax, AP_MAX_BYTES
    mov eax, ATT_TOTAL
    ja 9f
    call wait_test
    mov rdi, r12                # read, at most its limit (a file that grew past it is refused)
    mov rsi, r14
    call vfs_read_limited
    test rax, rax
    jnz 4f
    mov eax, ATT_BIG
    cmp rdx, -27
    je 9f
    mov eax, ATT_FOLDER
    cmp rdx, -21
    je 9f
    mov eax, ATT_READ
    jmp 9f
4:  mov r13, rax
    mov r14, rdx
    mov eax, ATT_EMPTY
    test r14, r14
    jz 8f
    cmp r15d, MPK_TEXT          # a text must be valid UTF-8
    jne 5f
    mov rdi, r13
    mov rsi, r14
    call snippet_utf8_valid
    test eax, eax
    mov eax, ATT_UNSUPPORTED
    jz 8f
5:  mov rax, [rbx + AP_bytes]
    add rax, r14
    cmp rax, AP_MAX_BYTES
    mov eax, ATT_TOTAL
    ja 8f
    mov rdi, rbx
    call push_part
    mov [rsp + 16], rax
    mov [rax + MP_kind], r15d
    mov rcx, [rsp]
    mov [rax + MP_mime], rcx
    mov [rax + MP_data], r13
    mov [rax + MP_len], r14
    add [rbx + AP_bytes], r14
    add [rip + live_bytes], r14
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov rcx, [rsp + 16]
    mov [rcx + MP_path], rax
    mov rdi, r12
    call base_of
    mov rdi, rax
    mov rsi, rdx
    call clean_name
    mov rcx, [rsp + 16]
    mov [rcx + MP_name], rax
    inc qword ptr [rip + g_att_gen]
    xor eax, eax
    jmp 9f
8:  mov r15d, eax               # refused after the read: the bytes go
    mov rdi, r13
    call mem_free
    mov eax, r15d
9:  EPILOGUE

# FN agatt_add_bytes(AP*, MPK_*, name cstr, mime cstr or 0, ptr, len) -> eax ATT_*: bytes without a file (a
#   pasted image: its kind by its bytes), copied
FN agatt_add_bytes
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp], r9
    mov eax, ATT_FULL
    cmp qword ptr [rbx + AP_parts + VEC_len], AP_MAX_PARTS
    jae 9f
    mov eax, ATT_EMPTY
    test r9, r9
    jz 9f
    cmp r12d, MPK_IMAGE         # an image: what its bytes are, whatever it was called
    jne 1f
    mov rdi, r15
    mov rsi, r9
    call sniff
    mov r14, rax
    test rax, rax
    mov eax, ATT_UNSUPPORTED
    jz 9f
1:  mov edi, r12d
    call kind_limit
    mov [rip + last_limit], rax
    mov rcx, [rsp]
    cmp rcx, rax
    mov eax, ATT_BIG
    ja 9f
    mov edi, r12d
    call is_file
    test eax, eax
    jz 2f
    mov rax, [rbx + AP_bytes]
    add rax, [rsp]
    cmp rax, AP_MAX_BYTES
    mov eax, ATT_TOTAL
    ja 9f
2:  mov rdi, r15
    mov rsi, [rsp]
    call mem_dup
    mov r15, rax
    mov rdi, rbx
    call push_part
    mov [rsp + 8], rax
    mov [rax + MP_kind], r12d
    mov dword ptr [rax + MP_flags], MPF_PASTED
    mov [rax + MP_mime], r14
    mov [rax + MP_data], r15
    mov rcx, [rsp]
    mov [rax + MP_len], rcx
    add [rip + live_bytes], rcx
    mov edi, r12d
    call is_file
    test eax, eax
    jz 3f
    mov rcx, [rsp]
    add [rbx + AP_bytes], rcx
3:  mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call clean_name
    mov rcx, [rsp + 8]
    mov [rcx + MP_name], rax
    inc qword ptr [rip + g_att_gen]
    xor eax, eax
9:  EPILOGUE

# FN agatt_add_text(AP*, MPK_*, name cstr, path cstr or 0, ptr, len, [rsp] l0, [rsp+8] l1) -> eax ATT_*: a
#   text a Send's hook adds (the selection, the open file: len 0, a terminal's) or a long paste (MPK_PASTE)
FN agatt_add_text
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp], r9
    mov eax, ATT_FULL
    cmp qword ptr [rbx + AP_parts + VEC_len], AP_MAX_PARTS
    jae 9f
    mov eax, ATT_BIG
    mov qword ptr [rip + last_limit], MP_SEL_MAX
    cmp r9, MP_SEL_MAX
    ja 9f
    xor eax, eax
    test r9, r9
    jz 1f
    mov rdi, r15
    mov rsi, r9
    call mem_dup
1:  mov r15, rax
    mov rdi, rbx
    call push_part
    mov [rsp + 8], rax
    mov [rax + MP_kind], r12d
    mov ecx, MPF_AUTO
    cmp r12d, MPK_PASTE
    jne 2f
    xor ecx, ecx
2:  mov [rax + MP_flags], ecx
    mov [rax + MP_data], r15
    xor ecx, ecx
    test r15, r15
    jz 3f
    mov rcx, [rsp]
3:  mov [rax + MP_len], rcx
    add [rip + live_bytes], rcx
    mov ecx, [rbp + 16]
    mov [rax + MP_l0], ecx
    mov ecx, [rbp + 24]
    mov [rax + MP_l1], ecx
    test r14, r14
    jz 4f
    mov rdi, r14
    call strlen
    mov rdi, r14
    mov rsi, rax
    call mem_dup
    mov rcx, [rsp + 8]
    mov [rcx + MP_path], rax
4:  mov rdi, r13
    call strlen
    mov rdi, r13
    mov rsi, rax
    call clean_name
    mov rcx, [rsp + 8]
    mov [rcx + MP_name], rax
    xor eax, eax
9:  EPILOGUE

# FN agatt_remove(AP*, i): part i goes, the others keep their order
FN agatt_remove
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, [rbx + AP_parts + VEC_len]
    jae 9f
    imul r13, r12, MP_SIZE
    add r13, [rbx + AP_parts + VEC_ptr]
    mov edi, [r13 + MP_kind]
    call is_file
    test eax, eax
    jz 1f
    mov rax, [r13 + MP_len]
    sub [rbx + AP_bytes], rax
1:  mov rdi, r13
    call part_drop
    mov rax, [rbx + AP_parts + VEC_len]
    dec rax
    mov [rbx + AP_parts + VEC_len], rax
    sub rax, r12
    imul rdx, rax, MP_SIZE
    mov rdi, r13
    lea rsi, [r13 + MP_SIZE]
    call memmove
    inc qword ptr [rip + g_att_gen]
9:  EPILOGUE

# FN agatt_drop_auto(AP*): the parts a Send's hooks added go (they are decided again at the next Send)
FN agatt_drop_auto
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    mov r12, [rbx + AP_parts + VEC_len]
1:  test r12, r12
    jz 9f
    dec r12
    imul rax, r12, MP_SIZE
    add rax, [rbx + AP_parts + VEC_ptr]
    test dword ptr [rax + MP_flags], MPF_AUTO
    jz 1b
    mov rdi, rbx
    mov rsi, r12
    call agatt_remove
    jmp 1b
9:  EPILOGUE

# FN agatt_slim(AP*): a held prompt's pack: the parts a hook added go, the bytes of every part with a path go
#   (it is read again if it comes back); a pathless part (a pasted image) keeps its bytes
FN agatt_slim
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call agatt_drop_auto
    xor r12d, r12d
1:  cmp r12, [rbx + AP_parts + VEC_len]
    jae 8f
    imul r13, r12, MP_SIZE
    add r13, [rbx + AP_parts + VEC_ptr]
    inc r12
    cmp qword ptr [r13 + MP_path], 0
    je 1b
    mov rdi, [r13 + MP_data]
    test rdi, rdi
    jz 1b
    mov rax, [r13 + MP_len]
    sub [rip + live_bytes], rax
    call mem_free
    mov qword ptr [r13 + MP_data], 0
    jmp 1b
8:  or dword ptr [rbx + AP_flags], APF_SLIM
9:  EPILOGUE

# FN agatt_pathless(AP* or 0) -> rax the bytes its pathless parts hold
FN agatt_pathless
    xor eax, eax
    test rdi, rdi
    jz 9f
    xor ecx, ecx
1:  cmp rcx, [rdi + AP_parts + VEC_len]
    jae 9f
    imul rdx, rcx, MP_SIZE
    add rdx, [rdi + AP_parts + VEC_ptr]
    inc rcx
    cmp qword ptr [rdx + MP_path], 0
    jne 1b
    cmp qword ptr [rdx + MP_data], 0
    je 1b
    add rax, [rdx + MP_len]
    jmp 1b
9:  ret

# FN agatt_drop_pathless(AP* or 0) -> rax the bytes freed: its pathless parts' bytes go (MPF_DROPPED: given
#   back, each says it could not be kept)
FN agatt_drop_pathless
    PROLOGUE
    xor r13d, r13d
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    xor r12d, r12d
1:  cmp r12, [rbx + AP_parts + VEC_len]
    jae 9f
    imul r14, r12, MP_SIZE
    add r14, [rbx + AP_parts + VEC_ptr]
    inc r12
    cmp qword ptr [r14 + MP_path], 0
    jne 1b
    mov rdi, [r14 + MP_data]
    test rdi, rdi
    jz 1b
    mov rax, [r14 + MP_len]
    add r13, rax
    sub [rip + live_bytes], rax
    call mem_free
    mov qword ptr [r14 + MP_data], 0
    or dword ptr [r14 + MP_flags], MPF_DROPPED
    jmp 1b
9:  mov rax, r13
    EPILOGUE

# merge(dst AP*, src AP*) -> eax the parts dropped: src's parts move to dst while dst has room (its count and
#   its bytes); src is freed
merge:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r15d, r15d
    test r12, r12
    jz 9f
    xor r13d, r13d
1:  cmp r13, [r12 + AP_parts + VEC_len]
    jae 8f
    imul r14, r13, MP_SIZE
    add r14, [r12 + AP_parts + VEC_ptr]
    inc r13
    cmp qword ptr [rbx + AP_parts + VEC_len], AP_MAX_PARTS
    jae 3f
    mov edi, [r14 + MP_kind]
    call is_file
    test eax, eax
    jz 2f
    mov rax, [rbx + AP_bytes]
    add rax, [r14 + MP_len]
    cmp rax, AP_MAX_BYTES
    ja 3f
    mov rax, [r14 + MP_len]
    add [rbx + AP_bytes], rax
2:  mov rdi, rbx
    call push_part
    mov rdi, rax
    mov rsi, r14
    mov edx, MP_SIZE
    call memmove
    mov rdi, r14                # moved: nothing left to free there
    xor esi, esi
    mov edx, MP_SIZE
    call memset
    jmp 1b
3:  mov rdi, r14
    call part_drop
    inc r15d
    jmp 1b
8:  mov rdi, r12
    call agatt_free
    inc qword ptr [rip + g_att_gen]
9:  mov eax, r15d
    EPILOGUE

# FN agatt_return(AS*, AP* or 0): see the top. Its box is the one the conversation's text would go back to
#   (agentext_box_as); else the pack waits in AS_parts for its box
FN agatt_return
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 9f
    call agatt_new
    mov r13, rax                # what comes back
    xor r14d, r14d
1:  cmp r14, [r12 + AP_parts + VEC_len]
    jae 5f
    imul r15, r14, MP_SIZE
    add r15, [r12 + AP_parts + VEC_ptr]
    inc r14
    mov eax, [r15 + MP_kind]
    cmp eax, MPK_SELECTION      # the context, a terminal's text, a paste: decided again at the next Send
    jae 1b
    test dword ptr [r15 + MP_flags], MPF_DROPPED
    jz 2f
    lea rdi, [rip + .Lt_pasted_gone]
    call app_toast
    jmp 1b
2:  cmp qword ptr [r15 + MP_data], 0
    jne 3f
    mov rsi, [r15 + MP_path]    # slimmed: read again from its path
    test rsi, rsi
    jz 1b
    mov rdi, r13
    call agatt_add_file
    test eax, eax
    jz 1b
    lea rdi, [rip + wsb]
    call sb_clear
    lea rdi, [rip + wsb]
    mov rsi, [r15 + MP_name]
    call sb_push_cstr
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Lt_unread_again]
    call sb_push_cstr
    mov rdi, [rip + wsb + SB_ptr]
    call app_toast
    jmp 1b
3:  mov edi, [r15 + MP_kind]    # its bytes move
    call is_file
    test eax, eax
    jz 4f
    mov rax, [r15 + MP_len]
    add [r13 + AP_bytes], rax
4:  mov rdi, r13
    call push_part
    mov rdi, rax
    mov rsi, r15
    mov edx, MP_SIZE
    call memmove
    mov rdi, r15
    xor esi, esi
    mov edx, MP_SIZE
    call memset
    jmp 1b
5:  mov rdi, r12
    call agatt_free
    mov rdi, r13
    call agatt_count
    test rax, rax
    jnz 6f
    mov rdi, r13
    call agatt_free
    jmp 9f
6:  call agentext_box_as        # into its box, or parked for it
    cmp rax, rbx
    jne 7f
    call agatt_box_make
    mov rdi, rax
    mov rsi, r13
    call merge
    jmp 8f
7:  mov rdi, [rbx + AS_parts]
    test rdi, rdi
    jnz 71f
    mov [rbx + AS_parts], r13
    xor eax, eax
    jmp 8f
71: mov rsi, r13
    call merge
8:  test eax, eax
    jz 81f
    lea rdi, [rip + .Lt_dropped]
    call app_toast
81: inc qword ptr [rip + g_att_gen]
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# ---- the box's pack ----

# FN agatt_box() -> rax the box's pack, or 0
FN agatt_box
    mov rax, [rip + bx_pack]
    ret

# FN agatt_box_make() -> rax the box's pack, made when there is none
FN agatt_box_make
    mov rax, [rip + bx_pack]
    test rax, rax
    jnz 1f
    sub rsp, 8
    call agatt_new
    add rsp, 8
    mov [rip + bx_pack], rax
    inc qword ptr [rip + g_att_gen]
1:  ret

# FN agatt_tidy(): an empty box's pack goes
FN agatt_tidy
    mov rdi, [rip + bx_pack]
    test rdi, rdi
    jz 1f
    cmp qword ptr [rdi + AP_parts + VEC_len], 0
    jne 1f
    mov qword ptr [rip + bx_pack], 0
    inc qword ptr [rip + g_att_gen]
    jmp agatt_free
1:  ret

# FN agatt_take() -> rax the box's pack (now the caller's), 0 when it has none or it is empty
FN agatt_take
    sub rsp, 8
    call agatt_tidy
    add rsp, 8
    mov rax, [rip + bx_pack]
    mov qword ptr [rip + bx_pack], 0
    inc qword ptr [rip + g_att_gen]
    ret

# FN agatt_keep(AP* or 0): a pack goes back to the box (after what the box holds)
FN agatt_keep
    test rdi, rdi
    jz 9f
    sub rsp, 8
    mov rsi, rdi
    mov rdi, [rip + bx_pack]
    test rdi, rdi
    jnz 1f
    mov [rip + bx_pack], rsi
    jmp 2f
1:  call merge
2:  call agatt_tidy
    inc qword ptr [rip + g_att_gen]
    mov dword ptr [rip + g_dirty], 1
    add rsp, 8
9:  ret

# FN agatt_drop_box(): the box's pack goes (its text goes too: nobody keeps it)
FN agatt_drop_box
    mov rdi, [rip + bx_pack]
    mov qword ptr [rip + bx_pack], 0
    inc qword ptr [rip + g_att_gen]
    jmp agatt_free

# FN agatt_park(AS*): the box changes owner: its pack waits in that conversation (AS_parts)
FN agatt_park
    PROLOGUE
    mov rbx, rdi
    mov rsi, [rip + bx_pack]
    test rsi, rsi
    jz 9f
    mov qword ptr [rip + bx_pack], 0
    inc qword ptr [rip + g_att_gen]
    mov rdi, [rbx + AS_parts]
    test rdi, rdi
    jz 1f
    call merge
    jmp 9f
1:  mov [rbx + AS_parts], rsi
9:  EPILOGUE

# FN agatt_park_kind(kind): a new conversation left before its first prompt: its pack waits for the next new
#   conversation of its kind (as its text does)
FN agatt_park_kind
    PROLOGUE
    mov rbx, rdi
    cmp rbx, KINDS
    jae 8f
    lea r12, [rip + kind_packs]
    mov rdi, [r12 + rbx*8]
    call agatt_free
    mov rax, [rip + bx_pack]
    mov [r12 + rbx*8], rax
    mov qword ptr [rip + bx_pack], 0
    inc qword ptr [rip + g_att_gen]
    EPILOGUE
8:  call agatt_drop_box
    EPILOGUE

# is_draft(AS*) -> eax 1 when it is a new conversation that never got a prompt (ALF_DRAFT)
is_draft:
    xor eax, eax
    mov rcx, [rdi + AS_live]
    test rcx, rcx
    jz 1f
    test dword ptr [rcx + AL_flags], ALF_DRAFT
    setnz al
1:  ret

# FN agatt_unpark(AS* or 0, kind): the box is that conversation's now (or a new conversation's of that kind):
#   what waited for it comes back (after what the box holds)
FN agatt_unpark
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz 2f
    mov rdi, [rbx + AS_parts]
    mov qword ptr [rbx + AS_parts], 0
    call agatt_keep
    mov rdi, rbx
    call is_draft
    test eax, eax
    jz 9f
    mov r12d, [rbx + AS_kind]
2:  cmp r12, KINDS
    jae 9f
    lea rax, [rip + kind_packs]
    mov rdi, [rax + r12*8]
    mov qword ptr [rax + r12*8], 0
    call agatt_keep
9:  EPILOGUE

# FN agatt_row_gone(AS*, owner): a conversation is freed: what it kept goes, or, for a new conversation that
#   never got a prompt, waits for the next of its kind (owner 1: the box was its: the box's pack too)
FN agatt_row_gone
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    call is_draft
    mov r13d, eax
    mov r14, [rbx + AS_parts]
    mov qword ptr [rbx + AS_parts], 0
    test r14, r14
    jz 2f
    test r13d, r13d
    jz 1f
    mov eax, [rbx + AS_kind]
    cmp rax, KINDS
    jae 1f
    lea r15, [rip + kind_packs]
    mov rdi, [r15 + rax*8]
    call agatt_free
    mov eax, [rbx + AS_kind]
    mov [r15 + rax*8], r14
    jmp 2f
1:  mov rdi, r14
    call agatt_free
2:  test r12d, r12d
    jz 9f
    test r13d, r13d
    jz 8f
    mov edi, [rbx + AS_kind]
    call agatt_park_kind
    EPILOGUE
8:  call agatt_drop_box         # the box was its: nobody keeps its pack now
9:  EPILOGUE

# FN agatt_reset(): quit, or the project changes: the box's pack and every new conversation's kept pack go
FN agatt_reset
    PROLOGUE
    call agatt_drop_box
    xor ebx, ebx
    lea r12, [rip + kind_packs]
1:  mov rdi, [r12 + rbx*8]
    mov qword ptr [r12 + rbx*8], 0
    call agatt_free
    inc ebx
    cmp ebx, KINDS
    jb 1b
    EPILOGUE

# FN agatt_caps_of(AS* or 0, kind) -> eax the DRVC_* bits of that conversation's driver (0: a new one of that
#   kind), as the UI is told them (agent-test-caps)
FN agatt_caps_of
    sub rsp, 8
    test rdi, rdi
    jz 1f
    call agent_drv_of
    jmp 2f
1:  mov edi, esi
    call agent_drv_for_kind
2:  add rsp, 8
    test rax, rax
    jz 8f
    mov eax, [rax + DRV_caps]
    mov ecx, [rip + g_att_test_caps]
    cmp ecx, -1
    cmovne eax, ecx
    ret
8:  xor eax, eax
    ret

# FN agatt_caps() -> eax the DRVC_* bits of the driver the box writes to (0 none)
FN agatt_caps
    sub rsp, 8
    call agentext_box_owner
    mov rdi, rax
    mov esi, edx
    test rax, rax
    jnz 1f
    test edx, edx
    jz 8f
1:  call agatt_caps_of
    add rsp, 8
    ret
8:  xor eax, eax
    add rsp, 8
    ret

# ---- attaching (the path browser, agent-attach; tasks 4 and 5: the clipboard, drops) ----

# fmt_limit(sb, bytes): "N MB", or "N KB" for a limit under a megabyte's multiple
fmt_limit:
    PROLOGUE
    mov rbx, rdi
    mov rax, rsi
    xor edx, edx
    mov ecx, MB
    div rcx
    test rdx, rdx
    jnz 1f
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    lea rsi, [rip + .Lw_mb]
    jmp 2f
1:  mov rax, rsi
    shr rax, 10
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    lea rsi, [rip + .Lw_kb]
2:  mov rdi, rbx
    call sb_push_cstr
    EPILOGUE

# refusal(ATT_*, path cstr): its toast (the words are rhun's; a name's control characters made spaces)
refusal:
    PROLOGUE
    mov r12d, edi
    mov rdi, rsi
    call base_of
    mov rdi, rax
    mov rsi, rdx
    call clean_name
    mov r13, rax
    lea rdi, [rip + wsb]
    call sb_clear
    cmp r12d, ATT_TOTAL
    je 3f
    cmp r12d, ATT_FULL
    je 4f
    lea rdi, [rip + wsb]
    mov rsi, r13
    call sb_push_cstr
    lea rsi, [rip + .Lw_unread]
    cmp r12d, ATT_READ
    je 2f
    lea rsi, [rip + .Lw_notfile]
    cmp r12d, ATT_NOTFILE
    je 2f
    lea rdi, [rip + wsb]        # ATT_BIG
    lea rsi, [rip + .Lw_larger]
    call sb_push_cstr
    lea rdi, [rip + wsb]
    mov rsi, [rip + last_limit]
    call fmt_limit
    lea rsi, [rip + .Lw_not_attached]
2:  lea rdi, [rip + wsb]
    call sb_push_cstr
    jmp 8f
3:  lea rsi, [rip + .Lw_total]
    jmp 5f
4:  lea rsi, [rip + .Lw_full]
5:  lea rdi, [rip + wsb]
    call sb_push_cstr
    lea rdi, [rip + wsb]
    mov rsi, r13
    call sb_push_cstr
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Lw_was_not]
    call sb_push_cstr
8:  mov rdi, [rip + wsb + SB_ptr]
    call app_toast
    mov rdi, r13
    call mem_free
    EPILOGUE

# unsupported(path cstr): its name joins the band's list (the first three are named)
unsupported:
    PROLOGUE
    mov rbx, rdi
    inc qword ptr [rip + unsup_n]
    cmp qword ptr [rip + unsup_n], 3
    ja 9f
    cmp qword ptr [rip + unsup_n], 1
    je 1f
    lea rdi, [rip + usb]
    lea rsi, [rip + .Lw_comma]
    call sb_push_cstr
1:  mov rdi, rbx
    call base_of
    mov rdi, rax
    mov rsi, rdx
    call clean_name
    mov r12, rax
    lea rdi, [rip + usb]
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r12
    call mem_free
9:  EPILOGUE

# band(): the unsupported names' notice (the extension's words, WV@5933734): on the band of the box's
#   conversation, a toast for a draft
band:
    PROLOGUE
    lea rdi, [rip + wsb]
    call sb_clear
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Lb_head]
    call sb_push_cstr
    cmp qword ptr [rip + unsup_n], 1
    je 1f
    lea rdi, [rip + wsb]
    mov esi, 's'
    call sb_push_byte
1:  lea rdi, [rip + wsb]
    lea rsi, [rip + .Lb_colon]
    call sb_push_cstr
    lea rdi, [rip + wsb]
    mov rsi, [rip + usb + SB_ptr]
    mov rdx, [rip + usb + SB_len]
    call sb_push
    mov rbx, [rip + unsup_n]
    cmp rbx, 3
    jbe 2f
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Lb_and]
    call sb_push_cstr
    lea rdi, [rip + wsb]
    lea rsi, [rbx - 3]
    call sb_push_u64
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Lb_more]
    call sb_push_cstr
2:  lea rdi, [rip + wsb]
    lea rsi, [rip + .Lb_tail]
    call sb_push_cstr
    call agentext_box_owner
    test rax, rax
    jz 7f
    mov rdi, rax
    call agent_live
    test rax, rax
    jz 7f
    mov rbx, rax
    mov rdi, rax                # shown again even when an earlier one was dismissed
    mov esi, BK_NOTICE
    xor edx, edx
    xor ecx, ecx
    call ev_band
    mov rdi, rbx
    mov esi, BK_NOTICE
    mov rdx, [rip + wsb + SB_ptr]
    mov rcx, [rip + wsb + SB_len]
    call ev_band
    EPILOGUE
7:  mov rdi, [rip + wsb + SB_ptr]
    call app_toast
    EPILOGUE

# mention(path cstr): a folder becomes a mention at the box's caret: "@REL/" (relative to the conversation's
#   checkout, else the project, when inside it; else absolute), quoted when it holds white space
mention:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
1:  cmp r12, 1                  # its trailing slashes off
    jbe 2f
    cmp byte ptr [rbx + r12 - 1], '/'
    jne 2f
    dec r12
    jmp 1b
2:  call agentext_box_owner
    xor r13d, r13d
    test rax, rax
    jz 3f
    mov r13, [rax + AS_cwd]
3:  test r13, r13
    jnz 4f
    mov r13, [rip + g_project]
4:  test r13, r13
    jz 5f
    mov rdi, r13
    call strlen
    mov r14, rax
    cmp r14, r12
    jae 5f
    cmp byte ptr [rbx + r14], '/'
    jne 5f
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jz 5f
    lea rbx, [rbx + r14 + 1]    # relative
    sub r12, r14
    dec r12
5:  xor r15d, r15d              # white space in it: quoted
    xor ecx, ecx
6:  cmp rcx, r12
    jae 7f
    cmp byte ptr [rbx + rcx], ' '
    jbe 61f
    inc rcx
    jmp 6b
61: mov r15d, 1
7:  lea rdi, [rip + wsb]
    call sb_clear
    lea rdi, [rip + wsb]
    mov esi, '@'
    call sb_push_byte
    test r15d, r15d
    jz 71f
    lea rdi, [rip + wsb]
    mov esi, '"'
    call sb_push_byte
71: lea rdi, [rip + wsb]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    lea rdi, [rip + wsb]
    mov esi, '/'
    call sb_push_byte
    test r15d, r15d
    jz 72f
    lea rdi, [rip + wsb]
    mov esi, '"'
    call sb_push_byte
72: mov rdi, [rip + wsb + SB_ptr]
    mov rsi, [rip + wsb + SB_len]
    mov edx, 1
    call composer_insert
    EPILOGUE

# FN agatt_attach_paths(list, len) -> eax the files attached: see the top
FN agatt_attach_paths
    PROLOGUE
    mov rbx, rdi
    lea r12, [rdi + rsi]
    xor r13d, r13d
    lea rdi, [rip + usb]
    call sb_clear
    mov qword ptr [rip + unsup_n], 0
1:  cmp rbx, r12
    jae 8f
    mov rdi, rbx
    call strlen
    mov r14, rbx
    lea rbx, [rbx + rax + 1]
    test rax, rax
    jz 1b
    call agatt_box_make
    mov rdi, rax
    mov rsi, r14
    call agatt_add_file
    test eax, eax
    jnz 2f
    inc r13d
    jmp 1b
2:  cmp eax, ATT_EMPTY          # an empty file is skipped, as the extension does
    je 1b
    cmp eax, ATT_FOLDER
    jne 3f
    mov rdi, r14
    call mention
    jmp 1b
3:  cmp eax, ATT_UNSUPPORTED
    jne 4f
    mov rdi, r14
    call unsupported
    jmp 1b
4:  mov edi, eax
    mov rsi, r14
    call refusal
    jmp 1b
8:  cmp qword ptr [rip + unsup_n], 0
    je 9f
    call band
9:  call agatt_tidy
    inc qword ptr [rip + g_att_gen]
    mov dword ptr [rip + g_dirty], 1
    mov eax, r13d
    EPILOGUE

# ---- a row's chips ----

# push_clean(sb, ptr, len): the bytes with TAB, LF and every other control character made spaces
push_clean:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov r14, [rbx + SB_len]
    call sb_push
    mov rax, [rbx + SB_ptr]
    add rax, r14
    xor ecx, ecx
1:  cmp rcx, r13
    jae 9f
    movzx edx, byte ptr [rax + rcx]
    cmp edx, ' '
    jb 2f
    cmp edx, 0x7f
    jne 3f
2:  mov byte ptr [rax + rcx], ' '
3:  inc rcx
    jmp 1b
9:  EPILOGUE

# FN agatt_chip_line(sb, kind byte, label ptr, len, target ptr, len): one chip: KIND TAB LABEL TAB TARGET (no
#   line feed: the caller puts one between chips)
FN agatt_chip_line
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    mov r13, rcx
    mov r14, r8
    mov r15, r9
    call sb_push_byte
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call push_clean
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call push_clean
    EPILOGUE

# FN agatt_chips(AP*, sb): the pack's chips text: a line a part, KIND i (image) d (document) s (selection)
#   f (open file) t (terminal) p (paste); TARGET its path (":L0-L1" after a selection's), "#ID" an image's
#   thumbnail when it has one, "-" none
FN agatt_chips
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz 9f
    xor r13d, r13d
1:  cmp r13, [rbx + AP_parts + VEC_len]
    jae 9f
    imul r14, r13, MP_SIZE
    add r14, [rbx + AP_parts + VEC_ptr]
    test r13, r13
    jz 2f
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
2:  inc r13
    mov eax, [r14 + MP_kind]
    lea rcx, [rip + chip_kinds]
    movzx r15d, byte ptr [rcx + rax]
    mov rdi, [r14 + MP_name]
    call strlen
    mov [rsp + 32], rax
    lea rdi, [rip + wsb]
    call sb_clear
    cmp dword ptr [r14 + MP_kind], MPK_IMAGE
    jne 3f
    cmp qword ptr [r14 + MP_thumb], 0
    je 3f
    lea rdi, [rip + wsb]
    mov esi, '#'
    call sb_push_byte
    lea rdi, [rip + wsb]
    mov rsi, [r14 + MP_thumb]
    call sb_push_u64
    jmp 5f
3:  mov rsi, [r14 + MP_path]
    test rsi, rsi
    jnz 4f
    lea rdi, [rip + wsb]
    mov esi, '-'
    call sb_push_byte
    jmp 5f
4:  lea rdi, [rip + wsb]
    call sb_push_cstr
    cmp dword ptr [r14 + MP_kind], MPK_SELECTION
    jne 5f
    lea rdi, [rip + wsb]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + wsb]
    mov esi, [r14 + MP_l0]
    call sb_push_u64
    lea rdi, [rip + wsb]
    mov esi, '-'
    call sb_push_byte
    lea rdi, [rip + wsb]
    mov esi, [r14 + MP_l1]
    call sb_push_u64
5:  mov rdi, r12
    mov esi, r15d
    mov rdx, [r14 + MP_name]
    mov rcx, [rsp + 32]
    mov r8, [rip + wsb + SB_ptr]
    mov r9, [rip + wsb + SB_len]
    call agatt_chip_line
    jmp 1b
9:  EPILOGUE

# FN agatt_chips_dup(AP* or 0) -> rax its chips text as an owned cstr, 0 when it has no parts
FN agatt_chips_dup
    PROLOGUE 32
    xor eax, eax
    mov rbx, rdi
    call agatt_count
    test rax, rax
    jz 9f
    xorps xmm0, xmm0
    movups [rsp], xmm0
    mov qword ptr [rsp + 16], 0
    mov rdi, rbx
    lea rsi, [rsp]
    call agatt_chips
    mov rax, [rsp + SB_ptr]
9:  EPILOGUE

# FN agatt_row_chips(AS*, index, chips cstr or 0): the row gets that chips text (AMF_CHIPS); nothing for a
#   row that was not made (-1) or without chips
FN agatt_row_chips
    PROLOGUE
    test rdx, rdx
    jz 9f
    test rsi, rsi
    js 9f
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, rax
    call agents_row_name
    mov rdi, rbx
    mov rsi, r12
    mov edx, AMF_CHIPS
    call agents_row_flag
9:  EPILOGUE

# ---- dumps ----

# FN agatt_live(sb): "live=N bytes=N": every pack alive in the window and the bytes their parts hold
FN agatt_live
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_live]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + live_n]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_bytes]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + live_bytes]
    call sb_push_u64
    EPILOGUE

# FN agatt_dump(sb): print-agent-attachments: "parts=N bytes=N" (the box's pack), a line a part "N KIND
#   name=T mime=M bytes=N", then "live=N bytes=N encoded=N measures=N"
FN agatt_dump
    PROLOGUE
    mov rbx, rdi
    mov r12, [rip + bx_pack]
    lea rsi, [rip + .Ld_parts]
    call sb_push_cstr
    mov rdi, r12
    call agatt_count
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_bytes]
    call sb_push_cstr
    xor esi, esi
    test r12, r12
    jz 1f
    mov rsi, [r12 + AP_bytes]
1:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor r13d, r13d
2:  mov rdi, r12
    call agatt_count
    cmp r13, rax
    jae 8f
    imul r14, r13, MP_SIZE
    add r14, [r12 + AP_parts + VEC_ptr]
    mov rdi, rbx
    mov rsi, r13
    call sb_push_u64
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov eax, [r14 + MP_kind]
    lea rcx, [rip + kind_words]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_name]
    call sb_push_cstr
    mov rdi, [r14 + MP_name]
    call strlen
    mov rdi, rbx
    mov rsi, [r14 + MP_name]
    mov rdx, rax
    call push_clean
    mov rdi, rbx
    lea rsi, [rip + .Ld_mime]
    call sb_push_cstr
    mov rsi, [r14 + MP_mime]
    test rsi, rsi
    jnz 3f
    lea rsi, [rip + .Ld_dash]
3:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_bytes]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + MP_len]
    call sb_push_u64
    mov rdi, rbx
    mov rsi, r13
    call agatt_dump_geom         # task 3: where its chip is drawn
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r13
    jmp 2b
8:  mov rdi, rbx
    call agatt_live
    mov rdi, rbx
    lea rsi, [rip + .Ld_encoded]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + g_b64_out]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_measures]
    call sb_push_cstr
    call agatt_measures
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# ---- the chips row (task 3) ----

# FN agatt_measures() -> rax the chips' layouts since start
FN agatt_measures
    xor eax, eax
    ret

# agatt_dump_geom(sb, i): " at=X,Y,W,H x=X,Y,W,H" of chip i as drawn last (task 3)
agatt_dump_geom:
    ret

# ---- later tasks' hooks (agentext_send calls them; they fill them in their own files) ----

# FN agterm_parts(AS* or 0, AP*, ptr, len): a part per @terminal: mention of the prompt (task 7): nothing yet
FN agterm_parts
    ret

# FN agterm_block(ptr, len): a link's prompt was put in the box: its @terminal: names are blocked (task 7)
FN agterm_block
    ret

# FN agterm_unblock(name ptr, len): the user picked that terminal from the menu (task 7)
FN agterm_unblock
    ret

.section .rodata
.Lm_png: .asciz "image/png"
.Lm_jpeg: .asciz "image/jpeg"
.Lm_gif: .asciz "image/gif"
.Lm_webp: .asciz "image/webp"
.Lm_pdf: .asciz "application/pdf"
.Lm_text: .asciz "text/plain"
.Lw_mb: .asciz " MB"
.Lw_kb: .asciz " KB"
.Lw_larger: .asciz " is larger than "
.Lw_not_attached: .asciz " \xc2\xb7 not attached"
.Lw_unread: .asciz " could not be read \xc2\xb7 not attached"
.Lw_notfile: .asciz " is not a file \xc2\xb7 not attached"
.Lw_total: .asciz "These files are more than 10 MB together \xc2\xb7 "
.Lw_full: .asciz "A message takes 20 attachments \xc2\xb7 "
.Lw_was_not: .asciz " was not attached"
.Lw_comma: .asciz ", "
.Lt_unread_again: .asciz " could not be read again \xc2\xb7 not attached"
.Lt_pasted_gone: .asciz "A pasted image could not be kept \xc2\xb7 attach it again"
.Lt_dropped: .asciz "Some attachments were dropped."
.Lb_head: .asciz "Unsupported file type"
.Lb_colon: .asciz ": "
.Lb_and: .asciz " and "
.Lb_more: .asciz " more"
.Lb_tail: .asciz ". Supported types: images (PNG, JPG, GIF, WebP), text files, and PDFs. To reference unsupported files, please include its absolute file path in your prompt (using @ for paths inside your working directory, and entering the path for files outside)."
.Lellipsis: .asciz "\xe2\x80\xa6"
.Lt_remove: .asciz "Remove"
.Ld_at: .asciz " at="
.Ld_x: .asciz " x="
.Lf_size: .asciz "size="
.Lf_w: .asciz " w="
.Lf_n: .asciz " n="
.Lf_h: .asciz " h="
.Lf_rows: .asciz " rows="
.Lf_mi16: .asciz " mi16="
.Lf_c: .asciz " c="
.Lfit_byte: .asciz "x"
.Lfit0: .asciz "a.png"
.Lfit1: .asciz "Screenshot 2026-11-23 at 10.14.32.png"
.Lfit2: .asciz "notes.txt"
.Lfit3: .asciz "a-very-long-file-name-that-goes-on-and-on-forever.pdf"
.Lfit4: .asciz "\xd0\xb7\xd0\xb0\xd0\xbc\xd0\xb5\xd1\x82\xd0\xba\xd0\xb8-\xd0\xbf\xd1\x80\xd0\xbe\xd0\xb5\xd0\xba\xd1\x82\xd0\xb0.md"
.Lfit5: .asciz "Makefile"
.Lfit6: .asciz "x"
.Lfit7: .asciz "report (final) v2 - copy.txt"
.Lm_upload: .asciz "Upload from computer"
.Lm_context: .asciz "Add context"
.Lat: .asciz "@"
.Ld_live: .asciz "live="
.Ld_bytes: .asciz " bytes="
.Ld_parts: .asciz "parts="
.Ld_name: .asciz " name="
.Ld_mime: .asciz " mime="
.Ld_dash: .asciz "-"
.Ld_encoded: .asciz " encoded="
.Ld_measures: .asciz " measures="
.Lk_none: .asciz "-"
.Lk_image: .asciz "image"
.Lk_pdf: .asciz "pdf"
.Lk_text: .asciz "text"
.Lk_selection: .asciz "selection"
.Lk_openfile: .asciz "openfile"
.Lk_terminal: .asciz "terminal"
.Lk_paste: .asciz "paste"
.Lx_license: .asciz "license"
.Lx_readme: .asciz "readme"
.Lx_changelog: .asciz "changelog"
.Lx_authors: .asciz "authors"
.Lx_contributors: .asciz "contributors"
.Lx_copying: .asciz "copying"
chip_kinds: .ascii "-iddsftp"
.p2align 3
fit_names: .quad .Lfit0, .Lfit1, .Lfit2, .Lfit3, .Lfit4, .Lfit5, .Lfit6, .Lfit7
fit_counts: .long 1, 5, 20, 0
kind_words: .quad .Lk_none, .Lk_image, .Lk_pdf, .Lk_text, .Lk_selection, .Lk_openfile, .Lk_terminal, .Lk_paste
tx_bare: .quad .Lx_license, .Lx_readme, .Lx_changelog, .Lx_authors, .Lx_contributors, .Lx_copying, 0
# the extension's text names (Eje, WV@3688316, 2.1.328), sorted for a binary search
tx_names:
    .quad .Ltx_adoc, .Ltx_asciidoc, .Ltx_asm, .Ltx_astro, .Ltx_babelrc, .Ltx_bash, .Ltx_bat, .Ltx_brewfile, .Ltx_c, .Ltx_cc
    .quad .Ltx_cfg, .Ltx_cjs, .Ltx_clj, .Ltx_cljc, .Ltx_cljs, .Ltx_cmake, .Ltx_cmd, .Ltx_conf, .Ltx_config, .Ltx_containerfile
    .quad .Ltx_cpp, .Ltx_cs, .Ltx_css, .Ltx_csv, .Ltx_cts, .Ltx_cxx, .Ltx_diff, .Ltx_dockerfile, .Ltx_editorconfig, .Ltx_elm
    .quad .Ltx_env, .Ltx_erl, .Ltx_eslintrc, .Ltx_ex, .Ltx_exs, .Ltx_fastfile, .Ltx_fish, .Ltx_fs, .Ltx_fsx, .Ltx_gemfile
    .quad .Ltx_gitattributes, .Ltx_gitignore, .Ltx_go, .Ltx_gql, .Ltx_gradle, .Ltx_graphql, .Ltx_h, .Ltx_hpp, .Ltx_hrl, .Ltx_hs
    .quad .Ltx_htm, .Ltx_html, .Ltx_ini, .Ltx_java, .Ltx_jl, .Ltx_js, .Ltx_json, .Ltx_jsx, .Ltx_kt, .Ltx_kts
    .quad .Ltx_latex, .Ltx_less, .Ltx_lock, .Ltx_log, .Ltx_lua, .Ltx_makefile, .Ltx_markdown, .Ltx_md, .Ltx_mdx, .Ltx_mjs
    .quad .Ltx_ml, .Ltx_mli, .Ltx_mts, .Ltx_npmrc, .Ltx_nvmrc, .Ltx_org, .Ltx_patch, .Ltx_php, .Ltx_pl, .Ltx_pm
    .quad .Ltx_podfile, .Ltx_prettierrc, .Ltx_prisma, .Ltx_procfile, .Ltx_properties, .Ltx_ps1, .Ltx_psd1, .Ltx_psm1, .Ltx_py, .Ltx_pyw
    .quad .Ltx_r, .Ltx_rakefile, .Ltx_rb, .Ltx_rs, .Ltx_rst, .Ltx_rtf, .Ltx_s, .Ltx_sass, .Ltx_scala, .Ltx_scss
    .quad .Ltx_sh, .Ltx_sql, .Ltx_sum, .Ltx_sv, .Ltx_svelte, .Ltx_svg, .Ltx_swift, .Ltx_tex, .Ltx_text, .Ltx_toml
    .quad .Ltx_ts, .Ltx_tsv, .Ltx_tsx, .Ltx_txt, .Ltx_v, .Ltx_vagrantfile, .Ltx_vhd, .Ltx_vhdl, .Ltx_vue, .Ltx_xhtml
    .quad .Ltx_xml, .Ltx_yaml, .Ltx_yarnrc, .Ltx_yml, .Ltx_zsh
.Ltx_adoc: .asciz "adoc"
.Ltx_asciidoc: .asciz "asciidoc"
.Ltx_asm: .asciz "asm"
.Ltx_astro: .asciz "astro"
.Ltx_babelrc: .asciz "babelrc"
.Ltx_bash: .asciz "bash"
.Ltx_bat: .asciz "bat"
.Ltx_brewfile: .asciz "brewfile"
.Ltx_c: .asciz "c"
.Ltx_cc: .asciz "cc"
.Ltx_cfg: .asciz "cfg"
.Ltx_cjs: .asciz "cjs"
.Ltx_clj: .asciz "clj"
.Ltx_cljc: .asciz "cljc"
.Ltx_cljs: .asciz "cljs"
.Ltx_cmake: .asciz "cmake"
.Ltx_cmd: .asciz "cmd"
.Ltx_conf: .asciz "conf"
.Ltx_config: .asciz "config"
.Ltx_containerfile: .asciz "containerfile"
.Ltx_cpp: .asciz "cpp"
.Ltx_cs: .asciz "cs"
.Ltx_css: .asciz "css"
.Ltx_csv: .asciz "csv"
.Ltx_cts: .asciz "cts"
.Ltx_cxx: .asciz "cxx"
.Ltx_diff: .asciz "diff"
.Ltx_dockerfile: .asciz "dockerfile"
.Ltx_editorconfig: .asciz "editorconfig"
.Ltx_elm: .asciz "elm"
.Ltx_env: .asciz "env"
.Ltx_erl: .asciz "erl"
.Ltx_eslintrc: .asciz "eslintrc"
.Ltx_ex: .asciz "ex"
.Ltx_exs: .asciz "exs"
.Ltx_fastfile: .asciz "fastfile"
.Ltx_fish: .asciz "fish"
.Ltx_fs: .asciz "fs"
.Ltx_fsx: .asciz "fsx"
.Ltx_gemfile: .asciz "gemfile"
.Ltx_gitattributes: .asciz "gitattributes"
.Ltx_gitignore: .asciz "gitignore"
.Ltx_go: .asciz "go"
.Ltx_gql: .asciz "gql"
.Ltx_gradle: .asciz "gradle"
.Ltx_graphql: .asciz "graphql"
.Ltx_h: .asciz "h"
.Ltx_hpp: .asciz "hpp"
.Ltx_hrl: .asciz "hrl"
.Ltx_hs: .asciz "hs"
.Ltx_htm: .asciz "htm"
.Ltx_html: .asciz "html"
.Ltx_ini: .asciz "ini"
.Ltx_java: .asciz "java"
.Ltx_jl: .asciz "jl"
.Ltx_js: .asciz "js"
.Ltx_json: .asciz "json"
.Ltx_jsx: .asciz "jsx"
.Ltx_kt: .asciz "kt"
.Ltx_kts: .asciz "kts"
.Ltx_latex: .asciz "latex"
.Ltx_less: .asciz "less"
.Ltx_lock: .asciz "lock"
.Ltx_log: .asciz "log"
.Ltx_lua: .asciz "lua"
.Ltx_makefile: .asciz "makefile"
.Ltx_markdown: .asciz "markdown"
.Ltx_md: .asciz "md"
.Ltx_mdx: .asciz "mdx"
.Ltx_mjs: .asciz "mjs"
.Ltx_ml: .asciz "ml"
.Ltx_mli: .asciz "mli"
.Ltx_mts: .asciz "mts"
.Ltx_npmrc: .asciz "npmrc"
.Ltx_nvmrc: .asciz "nvmrc"
.Ltx_org: .asciz "org"
.Ltx_patch: .asciz "patch"
.Ltx_php: .asciz "php"
.Ltx_pl: .asciz "pl"
.Ltx_pm: .asciz "pm"
.Ltx_podfile: .asciz "podfile"
.Ltx_prettierrc: .asciz "prettierrc"
.Ltx_prisma: .asciz "prisma"
.Ltx_procfile: .asciz "procfile"
.Ltx_properties: .asciz "properties"
.Ltx_ps1: .asciz "ps1"
.Ltx_psd1: .asciz "psd1"
.Ltx_psm1: .asciz "psm1"
.Ltx_py: .asciz "py"
.Ltx_pyw: .asciz "pyw"
.Ltx_r: .asciz "r"
.Ltx_rakefile: .asciz "rakefile"
.Ltx_rb: .asciz "rb"
.Ltx_rs: .asciz "rs"
.Ltx_rst: .asciz "rst"
.Ltx_rtf: .asciz "rtf"
.Ltx_s: .asciz "s"
.Ltx_sass: .asciz "sass"
.Ltx_scala: .asciz "scala"
.Ltx_scss: .asciz "scss"
.Ltx_sh: .asciz "sh"
.Ltx_sql: .asciz "sql"
.Ltx_sum: .asciz "sum"
.Ltx_sv: .asciz "sv"
.Ltx_svelte: .asciz "svelte"
.Ltx_svg: .asciz "svg"
.Ltx_swift: .asciz "swift"
.Ltx_tex: .asciz "tex"
.Ltx_text: .asciz "text"
.Ltx_toml: .asciz "toml"
.Ltx_ts: .asciz "ts"
.Ltx_tsv: .asciz "tsv"
.Ltx_tsx: .asciz "tsx"
.Ltx_txt: .asciz "txt"
.Ltx_v: .asciz "v"
.Ltx_vagrantfile: .asciz "vagrantfile"
.Ltx_vhd: .asciz "vhd"
.Ltx_vhdl: .asciz "vhdl"
.Ltx_vue: .asciz "vue"
.Ltx_xhtml: .asciz "xhtml"
.Ltx_xml: .asciz "xml"
.Ltx_yaml: .asciz "yaml"
.Ltx_yarnrc: .asciz "yarnrc"
.Ltx_yml: .asciz "yml"
.Ltx_zsh: .asciz "zsh"
