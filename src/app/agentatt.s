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
ch_pic: .zero 4 * AP_MAX_PARTS  #   task 6: 1 when its picture drew (print-agent-attachments thumb=)
.p2align 3
ch_lsb: .zero SB_SIZE

.data
.p2align 2
.globl g_att_wait_ms, g_att_test_caps
g_att_wait_ms: .long 0
g_att_test_caps: .long -1       # agent-test-caps: the DRVC_* bits the UI is told, -1 the driver's own
ch_room: .long -1               # the room the bottom area leaves the chips (agatt_room), -1 any

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
    mov rdi, [rbx + MP_thumb]   # task 6: its thumbnail is no longer the box's
    test rdi, rdi
    jz 0f
    call agimg_unpin
0:  mov rdi, [rbx + MP_name]
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

# thumb_part(MP*): an image part's thumbnail record (agentimg.s copies the bytes and pins it while the part
#   lives); a WebP or an image too large for one gets none (its chip draws the icon)
thumb_part:
    cmp dword ptr [rdi + MP_kind], MPK_IMAGE
    jne 1f
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + MP_data]
    mov rsi, [rbx + MP_len]
    mov edx, 1
    call agimg_bytes
    mov [rbx + MP_thumb], rax
    pop rbx
1:  ret

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
    mov rdi, rcx                # task 6: an image's thumbnail (made between frames)
    call thumb_part
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
    mov rdi, rcx                # task 6: an image's thumbnail (made between frames)
    call thumb_part
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
    call remote_refused         # a remote window: this machine's files are not attached
    test eax, eax
    jnz 9f
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
    mov rsi, r14                # task 6: an image's picture drew in its chip
    call pic_part
    test ecx, ecx
    jz 21f
    mov rdi, rbx
    lea rsi, [rip + .Ld_thumb]
    call sb_push_cstr
    xor esi, esi
    cmp r13d, [rip + ch_drawn]
    jae 22f
    lea rax, [rip + ch_pic]
    mov esi, [rax + r13*4]
22: mov rdi, rbx
    call sb_push_u64
21:
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

# ---- the chips row above the box (task 3): laid out when the pack, the width or the panel's size changed
#   (ch_* below, measures= counts the layouts), drawn every frame from that ----

# ch_key(AP*, w) -> eax 1 when the layout in ch_* is for that pack as it is now, at that width and size
ch_key:
    xor eax, eax
    cmp rdi, [rip + ch_pack]
    jne 1f
    mov rcx, [rip + g_att_gen]
    cmp rcx, [rip + ch_gen]
    jne 1f
    cmp esi, [rip + ch_w]
    jne 1f
    mov ecx, [rip + g_pmt + 4*MI_32]
    cmp ecx, [rip + ch_px]
    jne 1f
    mov rcx, [rip + ag_fsmall]
    cmp rcx, [rip + ch_face]
    jne 1f
    inc eax
1:  ret

# chip_w(label width, MP*) -> eax a chip's width: MI_8, the icon (MI_16), MI_6, the label, MI_4, the x (MI_16),
#   MI_6; an image with a thumbnail (task 6) has its picture in place of the icon: MI_2, MI_32 less MI_4, MI_6
chip_w:
    mov eax, edi
    call pic_part
    test ecx, ecx
    jz 1f
    mov eax, edi
    add eax, [rip + g_pmt + 4*MI_2]
    add eax, [rip + g_pmt + 4*MI_32]
    sub eax, [rip + g_pmt + 4*MI_4]
    jmp 2f
1:  add eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_16]
2:  add eax, [rip + g_pmt + 4*MI_6]
    add eax, [rip + g_pmt + 4*MI_4]
    add eax, [rip + g_pmt + 4*MI_16]
    add eax, [rip + g_pmt + 4*MI_6]
    ret

# pic_part(MP*) -> ecx its thumbnail's id when it is an image with one (task 6), else 0 (rsi: the part)
pic_part:
    xor ecx, ecx
    test rsi, rsi
    jz 1f
    cmp dword ptr [rsi + MP_kind], MPK_IMAGE
    jne 1f
    mov rcx, [rsi + MP_thumb]
1:  ret

# ch_layout(AP* or 0, w): the chips of that pack across the panel's width w (from MI_12 in to MI_12 before the
#   right edge), left to right, wrapping; a label is the part's name, cut to 24 characters with "…", and further
#   when the chip would be wider than the row. Nothing when ch_key says the layout is current
ch_layout:
    PROLOGUE 48
    mov rbx, rdi
    mov r12d, esi
    call ch_key
    test eax, eax
    jnz 9f
    inc qword ptr [rip + ch_measures]
    mov [rip + ch_pack], rbx
    mov rax, [rip + g_att_gen]
    mov [rip + ch_gen], rax
    mov [rip + ch_w], r12d
    mov eax, [rip + g_pmt + 4*MI_32]
    mov [rip + ch_px], eax
    mov rax, [rip + ag_fsmall]
    mov [rip + ch_face], rax
    lea rdi, [rip + ch_lsb]
    call sb_clear
    mov dword ptr [rip + ch_n], 0
    mov dword ptr [rip + ch_rows], 0
    mov dword ptr [rip + ch_drawn], 0
    mov eax, r12d               # the row's room
    sub eax, [rip + g_pmt + 4*MI_12]
    sub eax, [rip + g_pmt + 4*MI_12]
    mov ecx, 1
    cmp eax, ecx
    cmovl eax, ecx
    mov [rsp + 16], eax         # avail
    mov dword ptr [rsp + 20], 0 # x
    mov dword ptr [rsp + 24], 0 # y
    xor r13d, r13d
1:  mov rdi, rbx
    call agatt_count
    cmp r13, rax
    jae 8f
    cmp r13, AP_MAX_PARTS
    jae 8f
    mov rdi, rbx
    mov rsi, r13
    call agatt_part
    mov r14, rax
    mov rdi, [r14 + MP_name]    # the label: at most 24 characters, else 23 and "…"
    call strlen
    mov r15, rax                # its bytes
    mov rdi, [r14 + MP_name]
    mov rsi, rax
    mov edx, 24
    call char_bytes
    mov [rsp], rax              # the bytes of its first 24 characters
    xor ecx, ecx
    cmp rax, r15
    je 2f
    mov rdi, [r14 + MP_name]
    mov rsi, r15
    mov edx, 23
    call char_bytes
    mov [rsp], rax
    mov ecx, 1
2:  mov [rsp + 8], ecx          # with "…"
3:  mov rdi, [rip + ag_fsmall]  # its width; past the row: one character less
    mov rsi, [r14 + MP_name]
    mov rdx, [rsp]
    call text_width
    mov [rsp + 28], eax
    cmp dword ptr [rsp + 8], 0
    je 31f
    mov rdi, [rip + ag_fsmall]
    lea rsi, [rip + .Lellipsis]
    mov edx, 3
    call text_width
    add [rsp + 28], eax
31: mov edi, [rsp + 28]
    mov rsi, r14
    call chip_w
    cmp eax, [rsp + 16]
    jle 4f
    cmp qword ptr [rsp], 0
    je 4f
    mov rdi, [r14 + MP_name]    # one character less
    mov rsi, [rsp]
    call char_back
    mov [rsp], rax
    mov dword ptr [rsp + 8], 1
    jmp 3b
4:  mov [rsp + 32], eax         # the chip's width
    mov ecx, [rsp + 20]         # wraps unless it is the row's first
    test ecx, ecx
    jz 5f
    add ecx, eax
    cmp ecx, [rsp + 16]
    jle 5f
    mov dword ptr [rsp + 20], 0
    mov eax, [rip + g_pmt + 4*MI_32]
    add eax, [rip + g_pmt + 4*MI_6]
    add [rsp + 24], eax
5:  lea rcx, [rip + ch_x]
    mov eax, [rsp + 20]
    mov [rcx + r13*4], eax
    lea rcx, [rip + ch_y]
    mov eax, [rsp + 24]
    mov [rcx + r13*4], eax
    lea rcx, [rip + ch_cw]
    mov eax, [rsp + 32]
    mov [rcx + r13*4], eax
    mov eax, [rsp + 32]
    add eax, [rip + g_pmt + 4*MI_6]
    add [rsp + 20], eax
    lea rcx, [rip + ch_lo]      # the label as shown, in ch_lsb
    mov rax, [rip + ch_lsb + SB_len]
    mov [rcx + r13*4], eax
    lea rdi, [rip + ch_lsb]
    mov rsi, [r14 + MP_name]
    mov rdx, [rsp]
    call sb_push
    cmp dword ptr [rsp + 8], 0
    je 6f
    lea rdi, [rip + ch_lsb]
    lea rsi, [rip + .Lellipsis]
    call sb_push_cstr
6:  mov rax, [rip + ch_lsb + SB_len]
    lea rcx, [rip + ch_lo]
    sub eax, [rcx + r13*4]
    lea rcx, [rip + ch_ll]
    mov [rcx + r13*4], eax
    inc r13
    jmp 1b
8:  mov [rip + ch_n], r13d
    test r13d, r13d
    jz 9f
    mov eax, [rsp + 24]         # the rows
    xor edx, edx
    mov ecx, [rip + g_pmt + 4*MI_32]
    add ecx, [rip + g_pmt + 4*MI_6]
    div ecx
    inc eax
    mov [rip + ch_rows], eax
    mov eax, [rip + ch_scroll]  # the scroll stays inside what there is
    call ch_clamp
9:  EPILOGUE

# ch_clamp(): ch_scroll within 0 and the rows hidden, a whole number of rows
ch_clamp:
    mov eax, [rip + ch_scroll]
    test eax, eax
    jle 0f
    mov ecx, [rip + g_pmt + 4*MI_32]
    add ecx, [rip + g_pmt + 4*MI_6]
    xor edx, edx
    div ecx
    imul eax, ecx
0:  push rax
    call vis_rows
    mov r8d, eax
    pop rax
    mov ecx, [rip + ch_rows]
    sub ecx, r8d
    jg 1f
    xor eax, eax
    jmp 2f
1:  imul ecx, [rip + g_pmt + 4*MI_32]
    mov edx, [rip + ch_rows]
    sub edx, r8d
    imul edx, [rip + g_pmt + 4*MI_6]
    add ecx, edx
    cmp eax, ecx
    cmovg eax, ecx
    test eax, eax
    jns 2f
    xor eax, eax
2:  mov [rip + ch_scroll], eax
    ret

# char_bytes(ptr, len, n) -> rax the bytes of the first n characters (all when it has fewer)
char_bytes:
    xor eax, eax
1:  cmp rax, rsi
    jae 9f
    test edx, edx
    jz 9f
    dec edx
2:  inc rax                     # past the character's first byte and its continuation bytes
    cmp rax, rsi
    jae 9f
    movzx ecx, byte ptr [rdi + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    je 2b
    jmp 1b
9:  ret

# char_back(ptr, len) -> rax the length without its last character
char_back:
    mov rax, rsi
1:  test rax, rax
    jz 9f
    dec rax
    movzx ecx, byte ptr [rdi + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    je 1b
9:  ret

# vis_rows() -> eax the chips' rows shown at most: CH_ROWS, fewer (one at least) when they would take more than a
#   quarter of the window's height (a large panel font in a low window: the rest scroll)
vis_rows:
    mov eax, [rip + g_cv + CV_h]
    shr eax, 2
    mov ecx, [rip + g_pmt + 4*MI_32]
    add ecx, [rip + g_pmt + 4*MI_6]
    xor edx, edx
    div ecx
    mov ecx, CH_ROWS
    cmp eax, ecx
    cmova eax, ecx
    mov ecx, 1
    cmp eax, ecx
    cmovb eax, ecx
    mov ecx, [rip + ch_room]    # and what fits the room the box and its footer leave (none: 0)
    test ecx, ecx
    js 9f
    push rax
    mov eax, ecx
    sub eax, [rip + g_pmt + 4*MI_8]
    add eax, [rip + g_pmt + 4*MI_6]
    jns 1f
    xor eax, eax
1:  mov ecx, [rip + g_pmt + 4*MI_32]
    add ecx, [rip + g_pmt + 4*MI_6]
    xor edx, edx
    div ecx
    pop rcx
    cmp eax, ecx
    cmova eax, ecx
9:  ret

# FN agatt_row_min() -> eax the room one row of the box's chips takes (MI_8 above it, MI_32), 0 without
#   chips: the bottom area may pass its cap by that much, so that a box with attachments always shows them
FN agatt_row_min
    xor eax, eax
    mov rcx, [rip + bx_pack]
    test rcx, rcx
    jz 1f
    cmp qword ptr [rcx + AP_parts + VEC_len], 0
    je 1f
    mov eax, [rip + g_pmt + 4*MI_32]
    add eax, [rip + g_pmt + 4*MI_8]
1:  ret

# FN agatt_room(room): the bottom area's room for the chips row (its height less the prompt row's and the
#   footer's): the rows shown are what fits; a panel too low for one shows none
FN agatt_room
    mov [rip + ch_room], edi
    ret

# vis_h() -> eax the chips area's height for ch_rows (at most vis_rows shown): MI_8 above, the rows, MI_6
#   between them; 0 without chips
vis_h:
    xor eax, eax
    cmp dword ptr [rip + ch_rows], 0
    je 9f
    call vis_rows
    mov ecx, [rip + ch_rows]
    cmp ecx, eax
    jbe 1f
    mov ecx, eax
1:  test ecx, ecx
    jnz 2f
    xor eax, eax
    ret
2:  mov eax, [rip + g_pmt + 4*MI_32]
    imul eax, ecx
    dec ecx
    imul ecx, [rip + g_pmt + 4*MI_6]
    add eax, ecx
    add eax, [rip + g_pmt + 4*MI_8]
9:  ret

# FN agatt_h(AS* or 0, w) -> eax the chips row's room above the prompt row (0 without chips): the box's pack,
#   laid out only when it or the width changed
FN agatt_h
    sub rsp, 8
    mov rdi, [rip + bx_pack]
    call ch_layout
    call vis_h
    add rsp, 8
    ret

# FN agatt_draw(AS* or 0, x, y, w): the box's chips (agatt_h's room at y): each its icon, its label and its
#   x ("Remove"); its name as its tip; a click on an x removes that part; a wheel over them scrolls them
#   when there are more rows than CH_ROWS. Locals: [rsp] x, [rsp+4] y, [rsp+8] w, [rsp+12] the area's h,
#   [rsp+16] the part to remove (-1), [rsp+20] i, [rsp+24] the chip's x, [rsp+28] its y, [rsp+32] UB of
#   its body, [rsp+36] UB of its x
FN agatt_draw
    PROLOGUE 48
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov dword ptr [rsp + 16], -1
    mov rdi, [rip + bx_pack]
    mov esi, ecx
    call ch_layout
    call vis_h
    test eax, eax
    jz 9f
    mov [rsp + 12], eax
    mov edi, [rsp]              # the wheel over them, when some are hidden
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, eax
    call ui_in
    test eax, eax
    jz 1f
    call vis_rows
    cmp [rip + ch_rows], eax
    jbe 1f
    mov eax, [rip + g_scroll_y] # a row at a time: a chip shows whole or not at all
    test eax, eax
    jz 1f
    mov dword ptr [rip + g_scroll_y], 0
    mov ecx, [rip + g_pmt + 4*MI_32]
    add ecx, [rip + g_pmt + 4*MI_6]
    test eax, eax
    jns 11f
    neg ecx
11: add [rip + ch_scroll], ecx
    call ch_clamp
1:  mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    sub ecx, [rip + g_pmt + 4*MI_8]
    call gfx_clip_push
    mov eax, [rip + ch_n]
    mov [rip + ch_drawn], eax
    mov dword ptr [rsp + 20], 0
2:  mov ebx, [rsp + 20]
    cmp ebx, [rip + ch_n]
    jae 8f
    mov rdi, [rip + bx_pack]
    mov esi, ebx
    call agatt_part
    mov r15, rax
    lea rcx, [rip + ch_x]
    mov eax, [rcx + rbx*4]
    add eax, [rsp]
    add eax, [rip + g_pmt + 4*MI_12]
    mov [rsp + 24], eax
    lea rcx, [rip + ch_y]
    mov eax, [rcx + rbx*4]
    add eax, [rsp + 4]
    add eax, [rip + g_pmt + 4*MI_8]
    sub eax, [rip + ch_scroll]
    mov [rsp + 28], eax
    mov ecx, [rsp + 4]          # scrolled out of the area: not drawn, nothing to press
    add ecx, [rip + g_pmt + 4*MI_8]
    cmp eax, ecx
    jl 51f
    add eax, [rip + g_pmt + 4*MI_32]
    mov ecx, [rsp + 4]
    add ecx, [rsp + 12]
    cmp eax, ecx
    jg 51f
    lea rcx, [rip + ch_cw]
    mov r12d, [rcx + rbx*4]     # its width
    PM r13d, MI_32              # its height
    lea rcx, [rip + at_x]       # as drawn (print-agent-attachments)
    mov eax, [rsp + 24]
    mov [rcx + rbx*4], eax
    lea rcx, [rip + at_y]
    mov eax, [rsp + 28]
    mov [rcx + rbx*4], eax
    mov r14d, [rsp + 24]        # its x: MI_16 square, MI_6 from its right
    add r14d, r12d
    sub r14d, [rip + g_pmt + 4*MI_6]
    sub r14d, [rip + g_pmt + 4*MI_16]
    lea rcx, [rip + xb_x]
    mov [rcx + rbx*4], r14d
    lea edi, [rbx*2 + ID_AG_CHIP]   # its body (all but the x)
    mov esi, [rsp + 24]
    mov edx, [rsp + 28]
    mov ecx, r14d
    sub ecx, [rsp + 24]
    mov r8d, r13d
    call ui_btn
    mov [rsp + 32], eax
    lea edi, [rbx*2 + ID_AG_CHIP + 1]
    mov esi, r14d
    mov edx, r13d
    sub edx, [rip + g_pmt + 4*MI_16]
    sar edx, 1
    add edx, [rsp + 28]
    lea rcx, [rip + xb_y]
    mov [rcx + rbx*4], edx
    PM ecx, MI_16
    mov r8d, ecx
    call ui_btn
    mov [rsp + 36], eax
    COLOR r9d, T_BORDER         # the chip: a frame, lit while hovered
    COLOR eax, T_POPUP
    test dword ptr [rsp + 32], UB_HOVER
    jz 3f
    COLOR eax, T_HOVER
3:  mov edi, [rsp + 24]
    mov esi, [rsp + 28]
    mov edx, r12d
    mov ecx, r13d
    PM r8d, MI_RADIUS
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    mov rsi, r15                # task 6: an image's picture in place of its icon (the icon until it is
    call pic_part               #   made, between frames)
    test ecx, ecx
    jz 30f
    mov rdi, rcx
    mov esi, [rsp + 24]
    add esi, [rip + g_pmt + 4*MI_2]
    mov edx, [rsp + 28]
    add edx, [rip + g_pmt + 4*MI_2]
    PM ecx, MI_32
    sub ecx, [rip + g_pmt + 4*MI_4]
    call agimg_draw
    lea rcx, [rip + ch_pic]
    mov [rcx + rbx*4], eax
    test eax, eax
    jnz 33f
    mov edi, IC_F_IMAGE
    PM ecx, MI_16
    PM esi, MI_32
    sub esi, ecx
    sar esi, 1
    add esi, [rsp + 24]
    jmp 34f
30: lea rcx, [rip + ch_pic]
    mov dword ptr [rcx + rbx*4], 0
    mov eax, [r15 + MP_kind]    # its icon
    mov edi, IC_FILE
    cmp eax, MPK_IMAGE
    jne 31f
    mov edi, IC_F_IMAGE
31: cmp eax, MPK_PDF
    jne 32f
    mov edi, IC_F_PDF
32: mov esi, [rsp + 24]
    add esi, [rip + g_pmt + 4*MI_8]
34: PM ecx, MI_16
    mov edx, r13d
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 28]
    COLOR r8d, T_MUTED
    call icon_draw
33: mov rsi, r15
    call pic_part
    mov rdi, [rip + ag_fsmall]  # its label as the layout cut it
    mov esi, [rsp + 24]
    test ecx, ecx
    jz 35f
    add esi, [rip + g_pmt + 4*MI_2]
    add esi, [rip + g_pmt + 4*MI_32]
    sub esi, [rip + g_pmt + 4*MI_4]
    jmp 36f
35: add esi, [rip + g_pmt + 4*MI_8]
    add esi, [rip + g_pmt + 4*MI_16]
36: add esi, [rip + g_pmt + 4*MI_6]
    mov edx, [rsp + 28]
    mov ecx, r13d
    lea rax, [rip + ch_lo]
    mov r8d, [rax + rbx*4]
    add r8, [rip + ch_lsb + SB_ptr]
    lea rax, [rip + ch_ll]
    mov r9d, [rax + rbx*4]
    COLOR eax, T_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    test dword ptr [rsp + 36], UB_HOVER     # the x: lit while hovered
    jz 4f
    PM ecx, MI_16
    mov edi, r14d
    lea rax, [rip + xb_y]
    mov esi, [rax + rbx*4]
    mov edx, ecx
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
4:  PM ecx, MI_12
    mov edi, IC_CLOSE
    mov esi, r14d
    add esi, [rip + g_pmt + 4*MI_2]
    lea rax, [rip + xb_y]
    mov edx, [rax + rbx*4]
    add edx, [rip + g_pmt + 4*MI_2]
    COLOR r8d, T_MUTED
    test dword ptr [rsp + 36], UB_HOVER
    jz 41f
    COLOR r8d, T_FG
41: call icon_draw
    mov r9, [r15 + MP_name]     # the tips: its name (task 6: a picture too large to preview says so),
    mov rsi, r15                #   "Remove"
    call pic_part
    test ecx, ecx
    jz 42f
    mov rdi, rcx
    push r9
    push r9
    call agimg_state
    pop r9
    pop r9
    cmp eax, 2                  # AIS_REFUSED
    jne 42f
    lea r9, [rip + .Lt_large]
42: lea edi, [rbx*2 + ID_AG_CHIP]
    mov esi, [rsp + 24]
    mov edx, [rsp + 28]
    add edx, r13d
    mov ecx, r14d
    sub ecx, [rsp + 24]
    mov r8d, [rsp + 32]
    call tip_note_text
    test dword ptr [rsp + 32], UB_CLICK     # task 6: a click on an image opens its picture (after the frame)
    jz 43f
    mov rsi, r15
    call pic_part
    test ecx, ecx
    jz 43f
    mov rdi, rcx
    mov rsi, [r15 + MP_name]
    call agimg_open
43:
    lea edi, [rbx*2 + ID_AG_CHIP + 1]
    mov esi, r14d
    lea rax, [rip + xb_y]
    mov edx, [rax + rbx*4]
    add edx, [rip + g_pmt + 4*MI_16]
    PM ecx, MI_16
    mov r8d, [rsp + 36]
    lea r9, [rip + .Lt_remove]
    call tip_note_text
    test dword ptr [rsp + 36], UB_CLICK
    jz 5f
    mov [rsp + 16], ebx
    jmp 5f
51: lea rcx, [rip + at_x]       # (not drawn)
    mov dword ptr [rcx + rbx*4], 0
    lea rcx, [rip + at_y]
    mov dword ptr [rcx + rbx*4], 0
5:  inc dword ptr [rsp + 20]
    jmp 2b
8:  call gfx_clip_pop
    movsxd rsi, dword ptr [rsp + 16]    # a click on an x: that part goes (after the loop)
    test rsi, rsi
    js 9f
    mov rdi, [rip + bx_pack]
    call agatt_remove
    call agatt_tidy
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN agatt_measures() -> rax the chips' layouts since start (print-agent-attachments measures=)
FN agatt_measures
    mov rax, [rip + ch_measures]
    ret

# agatt_dump_geom(sb, i): " at=X,Y,W,H x=X,Y,W,H": chip i and its x as drawn last (0s: not drawn)
agatt_dump_geom:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d              # x, y, w, h
    xor r14d, r14d
    xor r15d, r15d
    cmp r12d, [rip + ch_drawn]
    jae 1f
    lea rax, [rip + at_x]
    mov r13d, [rax + r12*4]
    lea rax, [rip + at_y]
    mov r14d, [rax + r12*4]
    lea rax, [rip + ch_cw]
    mov r15d, [rax + r12*4]
    mov eax, r13d               # (scrolled out: not drawn)
    or eax, r14d
    jnz 1f
    xor r15d, r15d
1:  mov rdi, rbx
    lea rsi, [rip + .Ld_at]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    xor r8d, r8d
    test r15d, r15d
    jz 2f
    mov r8d, [rip + g_pmt + 4*MI_32]
2:  call push_rect
    mov rdi, rbx
    lea rsi, [rip + .Ld_x]
    call sb_push_cstr
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    test r15d, r15d
    jz 3f
    lea rax, [rip + xb_x]
    mov esi, [rax + r12*4]
    lea rax, [rip + xb_y]
    mov edx, [rax + r12*4]
    mov ecx, [rip + g_pmt + 4*MI_16]
    mov r8d, ecx
3:  mov rdi, rbx
    call push_rect
    EPILOGUE

# push_rect(sb, x, y, w, h): "X,Y,W,H"
push_rect:
    PROLOGUE
    mov rbx, rdi
    mov r12d, edx
    mov r13d, ecx
    mov r14d, r8d
    movsxd rsi, esi
    call push_int
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    movsxd rsi, r12d
    call push_int
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, r14d
    call sb_push_u64
    EPILOGUE

# push_int(sb, value): a signed number
push_int:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jns 1f
    mov esi, '-'
    call sb_push_byte
    neg r12
1:  mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    EPILOGUE

# FN agatt_fit_dump(sb): print-agent-attachments-fit: for every panel size 8 to 32 and width 240 to 900 (step
#   20), with 1, 5 and 20 parts of names short and long, the chips' layout: "size=S w=W n=N h=H rows=R
#   mi16=M" then " c=X,Y,W,H,XX,XY" a chip each (from the panel's left and the area's top; XX, XY its x's
#   square of MI_16). The panel's size is the user's again after it
FN agatt_fit_dump
    PROLOGUE 32
    mov rbx, rdi
    mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    call agatt_new              # 20 parts, names from fit_names
    mov r15, rax
    xor r12d, r12d
1:  lea rax, [rip + fit_names]
    mov ecx, r12d
    and ecx, 7
    mov rdx, [rax + rcx*8]
    mov rdi, r15
    mov esi, MPK_TEXT
    mov rcx, 0
    lea r8, [rip + .Lfit_byte]
    mov r9d, 1
    call agatt_add_bytes
    inc r12d
    cmp r12d, AP_MAX_PARTS
    jb 1b
    mov r12d, 8
2:  cmp r12d, 32
    ja 8f
    mov [rip + cfg_agents_font_size], r12d
    call agents_metrics
    mov r13d, 240
3:  cmp r13d, 900
    ja 7f
    lea rax, [rip + fit_counts]
    mov dword ptr [rsp + 4], 0
4:  mov ecx, [rsp + 4]
    lea rax, [rip + fit_counts]
    mov r14d, [rax + rcx*4]
    test r14d, r14d
    jz 6f
    mov [r15 + AP_parts + VEC_len], r14 # (the first n parts)
    inc qword ptr [rip + g_att_gen]
    mov rdi, r15
    mov esi, r13d
    call ch_layout
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call fit_line
    inc dword ptr [rsp + 4]
    jmp 4b
6:  add r13d, 20
    jmp 3b
7:  inc r12d
    jmp 2b
8:  mov qword ptr [r15 + AP_parts + VEC_len], AP_MAX_PARTS
    mov rdi, r15
    call agatt_free
    inc qword ptr [rip + g_att_gen]
    mov qword ptr [rip + ch_pack], 0
    mov eax, [rsp]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    EPILOGUE

# fit_line(sb, size, w, n): one line of agatt_fit_dump from ch_*
fit_line:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    lea rsi, [rip + .Lf_size]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_w]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_n]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r14d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_h]
    call sb_push_cstr
    call vis_h
    mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_rows]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + ch_rows]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_mi16]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + g_pmt + 4*MI_16]
    call sb_push_u64
    xor r15d, r15d
1:  cmp r15d, [rip + ch_n]
    jae 9f
    mov rdi, rbx
    lea rsi, [rip + .Lf_c]
    call sb_push_cstr
    lea rax, [rip + ch_x]
    mov esi, [rax + r15*4]
    add esi, [rip + g_pmt + 4*MI_12]
    lea rax, [rip + ch_y]
    mov edx, [rax + r15*4]
    add edx, [rip + g_pmt + 4*MI_8]
    lea rax, [rip + ch_cw]
    mov ecx, [rax + r15*4]
    mov r8d, [rip + g_pmt + 4*MI_32]
    mov rdi, rbx
    call push_rect
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    lea rax, [rip + ch_x]       # its x's square
    mov esi, [rax + r15*4]
    add esi, [rip + g_pmt + 4*MI_12]
    lea rax, [rip + ch_cw]
    add esi, [rax + r15*4]
    sub esi, [rip + g_pmt + 4*MI_6]
    sub esi, [rip + g_pmt + 4*MI_16]
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    lea rax, [rip + ch_y]
    mov esi, [rax + r15*4]
    add esi, [rip + g_pmt + 4*MI_8]
    mov eax, [rip + g_pmt + 4*MI_32]
    sub eax, [rip + g_pmt + 4*MI_16]
    sar eax, 1
    add esi, eax
    mov rdi, rbx
    call sb_push_u64
    inc r15d
    jmp 1b
9:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# ---- the "+" menu and Attach File (task 3) ----

# FN agatt_plus_menu(x, y): the footer's "+" was clicked (its top-left at x, y): its menu above it: "Upload from
#   computer" (the path browser as Attach File), and, with DRVC_MENTIONS, "Add context" ("@" at the caret) and
#   "Browse the web" (rows 1.27, 1.19: browser tabs come from the agent's browser extension, which rhun does not
#   connect: it says so instead of inserting "@browser:")
FN agatt_plus_menu
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    call agatt_caps
    lea rdi, [rip + plus_items2]
    mov ebx, 3
    test eax, DRVC_MENTIONS
    jnz 1f
    lea rdi, [rip + plus_items1]
    mov ebx, 1
1:  imul ecx, ebx, 4            # its height: MI_12 and MI_32 an item (the context menu's, explorer.s)
    mov eax, [rip + g_mt + 4*MI_32]
    imul eax, ebx
    add eax, [rip + g_mt + 4*MI_12]
    mov edx, r13d
    sub edx, eax
    jns 2f
    xor edx, edx
2:  mov esi, r12d
    call ctx_menu_open
    EPILOGUE

# FN agatt_upload(): "Upload from computer", "Attach file…": the path browser as Attach File (not in a remote
#   window: remote_refused)
FN agatt_upload
    sub rsp, 8
    call remote_refused
    add rsp, 8
    test eax, eax
    jnz 1f
    mov edi, 3
    jmp browse_open_kind
1:  ret

# remote_refused() -> eax 1 in a remote window, with a toast naming its host: the agent runs there, and this
#   machine's files are not attached to what it is sent (the "+" menu's Attach File, files dropped or given)
remote_refused:
    PROLOGUE
    xor eax, eax
    cmp dword ptr [rip + g_remote_window], 0
    jne 1f
    cmp dword ptr [rip + g_remote], 0
    je 9f
1:  lea rdi, [rip + wsb]
    call sb_clear
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Lrr_before]
    call sb_push_cstr
    call remote_host
    cmp byte ptr [rax], 0
    jne 2f
    lea rax, [rip + .Lrr_the_host]
2:  lea rdi, [rip + wsb]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + wsb]
    lea rsi, [rip + .Lrr_after]
    call sb_push_cstr
    lea rdi, [rip + wsb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + wsb + SB_ptr]
    call app_toast
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# FN agatt_browse(): "Browse the web": not available in rhun (no connection to a browser extension's tabs)
FN agatt_browse
    sub rsp, 8
    lea rdi, [rip + .Lm_browse_no]
    call app_toast
    mov dword ptr [rip + g_dirty], 1
    add rsp, 8
    ret

# FN agatt_add_context(): "Add context", "Mention file from this project…": the box gets the keys and "@" at
#   its caret (the mention menu opens on it: task 7)
FN agatt_add_context
    sub rsp, 8
    mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    lea rdi, [rip + .Lat]
    mov esi, 1
    xor edx, edx
    call composer_insert
    add rsp, 8
    ret

# FN agatt_browse_dir() -> rax the folder Attach File starts in: the box's conversation's checkout, else 0 (the
#   browser's own: the project, else the home folder)
FN agatt_browse_dir
    sub rsp, 8
    call agentext_box_owner
    add rsp, 8
    test rax, rax
    jz 1f
    mov rax, [rax + AS_cwd]
1:  ret

# ---- phase 4 task 7: a terminal's text for its mention (agentext_send's hook) ----

# FN agterm_parts(AS* or 0, AP*, ptr, len): for each "@terminal:NAME" chip of the prompt, in order and each name
#   once, the last 100 lines of the terminal whose title with spaces as "_" is NAME, as a part (MPK_TERMINAL,
#   MPF_AUTO: never kept in the box). A name that is no terminal adds nothing; a name a link's prompt brought
#   (agterm_block) adds nothing until the user picked that terminal from the mention menu. Read now, at the Send
FN agterm_parts
    PROLOGUE 48
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    test r12, r12
    jz 9f
    lea rdi, [rip + term_seen]
    call sb_clear
    xor r15d, r15d              # from
1:  mov rdi, r13
    mov rsi, r14
    mov rdx, r15
    lea rcx, [rsp]
    call agmention_next
    test eax, eax
    jz 8f
    mov r15, [rsp + 8]
    cmp dword ptr [rsp + 16], 2
    jne 1b
    mov rbx, [rsp]              # its name: after "@terminal:" (or '@"terminal:', to before its '"')
    add rbx, 10
    mov eax, [rsp + 20]
    add rbx, rax
    lea rax, [r13 + rbx]
    mov [rsp + 24], rax
    mov rax, r15
    sub rax, rbx
    mov ecx, [rsp + 20]
    sub rax, rcx
    mov [rsp + 32], rax
    jle 1b
    mov rdi, [rsp + 24]         # once a name; not one a link brought
    mov rsi, [rsp + 32]
    lea rdx, [rip + term_seen]
    call name_in
    test eax, eax
    jnz 1b
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    lea rdx, [rip + term_blocked]
    call name_in
    test eax, eax
    jnz 1b
    lea rdi, [rip + term_seen]
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 32]
    call sb_push
    lea rdi, [rip + term_seen]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rip + term_text]
    call sb_clear
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    mov edx, 100
    lea rcx, [rip + term_text]
    call term_tail
    test eax, eax
    jz 1b
    mov rdi, [rsp + 24]         # its name as a string
    mov rsi, [rsp + 32]
    call mem_dup
    mov [rsp + 40], rax
    push 0
    push 0
    mov rdi, r12
    mov esi, MPK_TERMINAL
    mov rdx, rax
    xor ecx, ecx
    mov r8, [rip + term_text + SB_ptr]
    mov r9, [rip + term_text + SB_len]
    test r8, r8
    jnz 2f
    lea r8, [rip + .Lempty_text]
2:  call agatt_add_text
    add rsp, 16
    mov rdi, [rsp + 40]
    call mem_free
    jmp 1b
8:  lea rdi, [rip + term_blocked]   # the prompt left the box: what a link brought goes with it
    call sb_clear
9:  EPILOGUE

# name_in(ptr, len, names sb) -> eax 1 when the name is one of the NUL-ended names
name_in:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rdx + SB_ptr]
    mov r14, [rdx + SB_len]
    add r14, r13
    xor eax, eax
    test r13, r13
    jz 9f
1:  cmp r13, r14
    jae 8f
    mov rdi, r13
    call strlen
    lea r15, [r13 + rax + 1]
    cmp rax, r12
    jne 2f
    mov rdi, r13
    mov rsi, rbx
    mov rdx, r12
    call memeq
    test eax, eax
    jnz 9f
2:  mov r13, r15
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# FN agterm_block(ptr, len): a link's prompt was put in the box: its "@terminal:" names are blocked (until the
#   user picks that terminal from the menu, or the prompt leaves the box)
FN agterm_block
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + term_blocked]
    call sb_clear
    xor r14d, r14d
1:  mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    lea rcx, [rsp]
    call agmention_next
    test eax, eax
    jz 9f
    mov r14, [rsp + 8]
    cmp dword ptr [rsp + 16], 2
    jne 1b
    mov rbx, [rsp]              # (quoted: '@"terminal:NAME"')
    add rbx, 10
    mov eax, [rsp + 20]
    add rbx, rax
    lea rdi, [rip + term_blocked]
    lea rsi, [r12 + rbx]
    mov rdx, r14
    sub rdx, rbx
    mov eax, [rsp + 20]
    sub rdx, rax
    call sb_push
    lea rdi, [rip + term_blocked]
    xor esi, esi
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# FN agterm_unblock(name ptr, len): the user picked that terminal from the menu: its text may go
FN agterm_unblock
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
1:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + term_blocked]
    call name_in
    test eax, eax
    jz 9f
    mov rbx, [rip + term_blocked + SB_ptr]  # (each name once is enough: blank them all)
    mov r14, [rip + term_blocked + SB_len]
    xor ecx, ecx
2:  cmp rcx, r14
    jae 9f
    lea rdi, [rbx + rcx]
    push rcx
    push rcx
    call strlen
    pop rcx
    pop rcx
    lea r15, [rcx + rax + 1]
    cmp rax, r13
    jne 3f
    push rcx
    push rcx
    lea rdi, [rbx + rcx]
    mov rsi, r12
    mov rdx, r13
    call memeq
    pop rcx
    pop rcx
    test eax, eax
    jz 3f
    mov byte ptr [rbx + rcx], 1 # no name matches it any more
3:  mov rcx, r15
    jmp 2b
9:  EPILOGUE

# FN agterm_blocked_clear(): the box emptied (composer_paint): nothing a link brought is left in it
FN agterm_blocked_clear
    lea rdi, [rip + term_blocked]
    jmp sb_clear

.bss
.p2align 3
term_seen: .zero SB_SIZE        # (phase 4 task 7) the terminals' names a Send took
term_blocked: .zero SB_SIZE     #   the names a link's prompt brought
term_text: .zero SB_SIZE

.section .rodata
.Lrr_before: .asciz "Files on this computer cannot be attached in a remote window: the agent runs on "
.Lrr_the_host: .asciz "the host"
.Lrr_after: .asciz "."
.Lm_png: .asciz "image/png"
.Lempty_text: .asciz ""
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
.Lt_large: .asciz "Too large to preview"
.Ld_thumb: .asciz " thumb="
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
.Lm_browse: .asciz "Browse the web"
.Lm_browse_no: .asciz "Browser tabs come from a browser extension that rhun does not connect: give the page's address instead."
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
plus_items1: .quad .Lm_upload, agatt_upload, 0, 0
plus_items2: .quad .Lm_upload, agatt_upload, .Lm_context, agatt_add_context, .Lm_browse, agatt_browse, 0, 0
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
