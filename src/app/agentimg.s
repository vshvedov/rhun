# Pictures in a conversation as thumbnails (generic: nothing here knows which agent wrote them). One small cache
# for the whole window, keyed by content: a record is made from bytes (an image attached to the box, a reply's
# data: image; agimg_bytes copies them, so no record ever points into a pack) or from a place in a session's
# file (the n-th image of the record on that line, read again when it is wanted: agimg_place). Drawing never
# decodes and never scales from the source: agimg_draw blits a copy made for that size, or draws nothing and
# says so (the caller draws the icon). agimg_tick does the work between frames: the copies wanted, and one
# decode a pass, never within IMG_REST_MS of the last key or click (g_input_ms). Before a decode the header's
# size is read: past IMG_PX_MAX pixels, a side past IMG_SIDE_MAX or bytes past IMG_FILE_MAX the picture is
# refused (a chip without a picture, the tip "Too large to preview"). At most IMG_THUMBS_MAX thumbnails are
# kept (the least recently drawn unpinned one gives its pixels up, and is decoded again when it is drawn
# again) and at most IMG_KEEP_MAX bytes of sources (the least recently used unpinned record gives its bytes
# up and keeps its pixels: opened, it says "The picture is no longer in memory.").
#
#   agimg_bytes(ptr, len, pin) -> rax id or 0      a PNG, JPEG or GIF of at most IMG_FILE_MAX bytes, copied
#   agimg_place(AS*, off, len, n) -> rax id or 0   the n-th image of the record on that line of its file
#   agimg_chip(AS*, target ptr, len) -> rax id or 0   a chip's target: "#ID" or "@OFF:LEN:N"
#   agimg_md(link ptr, len) -> rax id or 0         a reply's data:image/png|jpeg|gif;base64, image (markdown.s
#                                                  asks at layout: the Base64 decoded, nothing else)
#   agimg_ctx(AS* or 0, row)                       the row a reply's data: images belong to (measured again
#                                                  when one is ready)
#   agimg_draw(id, x, y, side) -> eax 1 drew       the picture fitted in that square, or 0 (not ready)
#   agimg_size(id) -> eax w, edx h                 its thumbnail's size, 0, 0 while it has none
#   agimg_state(id) -> eax AIS_* (-1: no such record)
#   agimg_unpin(id);  agimg_session_gone(AS*)
#   agimg_open(id, title cstr)                     the whole picture in an image tab, after the frame
#   agimg_tick();  agimg_timeout() -> eax ms or -1
#   agimg_chip_pic(AS*, target ptr, len, x, y, side) -> eax 1 drew;  agimg_chip_open(AS*, target ptr, len,
#                                                  title cstr) -> eax   an image chip of a prompt row (agentrows.s
#                                                  draws the chips: KIND TAB LABEL TAB TARGET, LF between them);
#                                                  agimg_drew_note(chips cstr, n) what it drew, and
#                                                  agimg_chips_drew(chips cstr) -> eax the pictures drawn in them
#                                                  last frame
#   agimg_dump(sb) print-agent-images;  agimg_hold(on) agent-images-hold
.include "rhun.inc"

.equ IMG_PX_MAX, 16000000       # pixels rhun's decoder may be asked to do on the main thread
.equ IMG_SIDE_MAX, 8192
.equ IMG_FILE_MAX, 10485760     # MP_IMAGE_MAX: every image that can be attached can have its thumbnail
.equ IMG_KEEP_MAX, 33554432     # source bytes kept by unpinned records
.equ IMG_THUMB, 96              # a thumbnail's longer side at most
.equ IMG_THUMBS_MAX, 64
.equ IMG_REST_MS, 300           # no decode within this of the last key or click
.equ IMG_SHOWN_MS, 1000         # a thumbnail drawn this lately is never given up (more in view than the cap:
                                #   the cap waits, rather than decoding the same pictures over and over)
.equ RECS_MAX, 512
.equ DREW_MAX, 64               # rows whose pictures drawn last frame are remembered (agimg_chips_drew)

.equ AIK_BYTES, 1
.equ AIK_PLACE, 2
.equ AIS_WAIT, 0
.equ AIS_READY, 1
.equ AIS_REFUSED, 2
.equ AIS_FAILED, 3
.equ AIF_ASKED, 1               # drawn while it had no picture: it is decoded
.equ AIF_MD, 2                  # a reply's data: image: its row is measured again when it is ready

STRUCT
F AI_id, 8
F AI_key, 8             # the bytes' hash (AIK_BYTES), or of the place
F AI_src, 8             # owned bytes, or 0 (a place; bytes given up)
F AI_len, 8             # their length (kept when given up)
F AI_as, 8              # a place's session
F AI_off, 8             #   its line
F AI_plen, 8
F AI_cas, 8             # the session whose row drew it (agimg_session_gone), or 0
F AI_px, 8              # the thumbnail: premultiplied ARGB, AI_w x AI_h, or 0
F AI_used, 8            # the draw clock when last drawn
F AI_bused, 8           #   when its bytes were last used
F AI_ms, 8              # time_ms when last drawn
F AI_cpx, 16            # two copies at a chip's size (AI_cw x AI_ch, fitted in AI_cs)
F AI_cw, 8
F AI_ch, 8
F AI_cs, 8
F AI_n, 4               # a place's image
F AI_crow, 4            # a reply's row for AIF_MD, -1
F AI_kind, 4            # AIK_*
F AI_state, 4           # AIS_*
F AI_pin, 4             # the box's parts that hold it
F AI_flags, 4           # AIF_*
F AI_w, 4
F AI_h, 4
F AI_iw, 4              # the picture's own size (the header's), 0 unknown
F AI_ih, 4
F AI_want, 4            # a side drawn without its copy, 0 none
F AI_cnext, 4           # the copy slot replaced next
ENDSTRUCT AI_SIZE

.bss
.p2align 3
.globl g_input_ms
g_input_ms: .quad 0             # time_ms of the last key or click (app.s's app_on_key, app_on_button)
recs: .zero VEC_SIZE            # AI, in the order they were made
next_id: .quad 0
clock: .quad 0                  # moves at every draw of a record
kept: .quad 0                   # bytes of sources held
decoded: .quad 0                # decodes since start
pend_id: .quad 0                # agimg_open's picture and its title, opened after the frame
pend_title: .quad 0
ctx_as: .quad 0                 # agimg_ctx
ctx_row: .long 0
pending: .long 0                # something was asked: agimg_tick has work
hold: .long 0                   # agent-images-hold: no decode
pad0: .long 0
.p2align 3
rsb: .zero SB_SIZE              # a place's bytes read again
drew_key: .zero 8 * DREW_MAX    # agimg_chips_drew: a chips text drawn, and the pictures in it
drew_n: .zero 4 * DREW_MAX
drew_at: .long 0
pad1: .long 0
.p2align 3
img: .zero IMG_SIZE

.text

# ---- records ----

# by_id(id) -> rax AI* or 0
by_id:
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rax, [rip + recs + VEC_ptr]
    mov rcx, [rip + recs + VEC_len]
1:  test rcx, rcx
    jz 8f
    cmp [rax + AI_id], rdi
    je 9f
    add rax, AI_SIZE
    dec rcx
    jmp 1b
8:  xor eax, eax
9:  ret

# hash(ptr, len) -> rax: eight bytes at a time, multiplied and rotated (not cryptographic: equal bytes are
#   also compared by length)
hash:
    mov rax, 0xcbf29ce484222325
    mov r8, 0x100000001b3
    xor ecx, ecx
1:  lea rdx, [rcx + 8]
    cmp rdx, rsi
    ja 2f
    xor rax, [rdi + rcx]
    imul rax, r8
    rol rax, 29
    mov rcx, rdx
    jmp 1b
2:  cmp rcx, rsi
    jae 3f
    movzx edx, byte ptr [rdi + rcx]
    xor rax, rdx
    imul rax, r8
    inc rcx
    jmp 2b
3:  xor rax, rsi
    ret

# rec_new() -> rax a zeroed record at the end (the oldest unpinned one goes first when there are RECS_MAX)
rec_new:
    PROLOGUE
    cmp qword ptr [rip + recs + VEC_len], RECS_MAX
    jb 1f
    mov rax, [rip + recs + VEC_ptr]     # the least recently used unpinned record
    mov rcx, [rip + recs + VEC_len]
    xor ebx, ebx
    mov r12, -1
    xor edx, edx
2:  cmp rdx, rcx
    jae 3f
    imul r8, rdx, AI_SIZE
    add r8, rax
    cmp dword ptr [r8 + AI_pin], 0
    jne 21f
    mov r9, [r8 + AI_used]
    cmp r9, r12
    jae 21f
    mov r12, r9
    mov rbx, r8
21: inc rdx
    jmp 2b
3:  test rbx, rbx
    jz 1f
    mov rdi, rbx
    call rec_drop
1:  lea rdi, [rip + recs]
    mov esi, AI_SIZE
    call vec_push
    inc qword ptr [rip + next_id]
    mov rcx, [rip + next_id]
    mov [rax + AI_id], rcx
    mov dword ptr [rax + AI_crow], -1
    mov rcx, [rip + clock]
    mov [rax + AI_used], rcx
    mov [rax + AI_bused], rcx
    EPILOGUE

# px_free(AI*): its thumbnail and copies go (it may be decoded again)
px_free:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + AI_px]
    call mem_free
    mov qword ptr [rbx + AI_px], 0
    mov rdi, [rbx + AI_cpx]
    call mem_free
    mov rdi, [rbx + AI_cpx + 8]
    call mem_free
    xor eax, eax
    mov [rbx + AI_cpx], rax
    mov [rbx + AI_cpx + 8], rax
    mov [rbx + AI_cs], rax
    pop rbx
    ret

# src_free(AI*): its bytes go (counted off)
src_free:
    mov rax, [rdi + AI_src]
    test rax, rax
    jz 1f
    push rdi
    mov rcx, [rdi + AI_len]
    sub [rip + kept], rcx
    mov rdi, rax
    call mem_free
    pop rdi
    mov qword ptr [rdi + AI_src], 0
1:  ret

# rec_drop(AI*): the record and everything it owns
rec_drop:
    push rbx
    mov rbx, rdi
    call px_free
    mov rdi, rbx
    call src_free
    mov rax, rbx                # its index
    sub rax, [rip + recs + VEC_ptr]
    xor edx, edx
    mov ecx, AI_SIZE
    div rcx
    mov rcx, [rip + recs + VEC_len]   # the ones after it move down
    sub rcx, rax
    dec rcx
    imul rdx, rcx, AI_SIZE
    mov rdi, rbx
    lea rsi, [rbx + AI_SIZE]
    call memmove
    dec qword ptr [rip + recs + VEC_len]
    pop rbx
    ret

# keep_cap(): past IMG_KEEP_MAX bytes of sources, the least recently used unpinned records give theirs up
keep_cap:
    PROLOGUE
1:  cmp qword ptr [rip + kept], IMG_KEEP_MAX
    jbe 9f
    mov rax, [rip + recs + VEC_ptr]
    mov rcx, [rip + recs + VEC_len]
    xor ebx, ebx
    mov r12, -1
2:  test rcx, rcx
    jz 3f
    cmp qword ptr [rax + AI_src], 0
    je 21f
    cmp dword ptr [rax + AI_pin], 0
    jne 21f
    mov rdx, [rax + AI_bused]
    cmp rdx, r12
    jae 21f
    mov r12, rdx
    mov rbx, rax
21: add rax, AI_SIZE
    dec rcx
    jmp 2b
3:  test rbx, rbx
    jz 9f
    mov rdi, rbx
    call src_free
    jmp 1b
9:  EPILOGUE

# thumbs_cap(): past IMG_THUMBS_MAX thumbnails, the least recently drawn unpinned one gives its pixels up (one
#   drawn within IMG_SHOWN_MS never does)
thumbs_cap:
    PROLOGUE
    call time_ms
    sub rax, IMG_SHOWN_MS
    mov r14, rax                # drawn after this: kept
1:  mov rax, [rip + recs + VEC_ptr]
    mov rcx, [rip + recs + VEC_len]
    xor r13d, r13d              # thumbnails
    xor ebx, ebx
    mov r12, -1
2:  test rcx, rcx
    jz 3f
    cmp qword ptr [rax + AI_px], 0
    je 21f
    inc r13d
    cmp dword ptr [rax + AI_pin], 0
    jne 21f
    cmp [rax + AI_ms], r14
    jg 21f
    mov rdx, [rax + AI_used]
    cmp rdx, r12
    jae 21f
    mov r12, rdx
    mov rbx, rax
21: add rax, AI_SIZE
    dec rcx
    jmp 2b
3:  cmp r13d, IMG_THUMBS_MAX
    jbe 9f
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call px_free
    mov dword ptr [rbx + AI_state], AIS_WAIT
    and dword ptr [rbx + AI_flags], ~AIF_ASKED
    jmp 1b
9:  EPILOGUE

# decodable(ptr, len) -> eax IMF_PNG, IMF_JPEG or IMF_GIF when the bytes are one, else 0
decodable:
    sub rsp, 8
    xor edx, edx
    call image_sniff
    cmp eax, IMF_PNG
    je 1f
    cmp eax, IMF_JPEG
    je 1f
    cmp eax, IMF_GIF
    je 1f
    xor eax, eax
1:  add rsp, 8
    ret

# FN agimg_bytes(ptr, len, pin) -> rax id or 0: see the top. The same bytes give the same record (pinned once
#   more); nothing is decoded here
FN agimg_bytes
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    test r12, r12
    jz 8f
    cmp r12, IMG_FILE_MAX
    ja 8f
    call decodable
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call hash
    mov r14, rax
    mov rax, [rip + recs + VEC_ptr]     # made before
    mov rcx, [rip + recs + VEC_len]
1:  test rcx, rcx
    jz 3f
    cmp dword ptr [rax + AI_kind], AIK_BYTES
    jne 2f
    cmp [rax + AI_key], r14
    jne 2f
    cmp [rax + AI_len], r12
    jne 2f
    mov r15, rax
    add [r15 + AI_pin], r13d
    cmp qword ptr [r15 + AI_src], 0     # bytes it gave up come back
    jne 11f
    mov rdi, rbx
    mov rsi, r12
    call mem_dup
    mov [r15 + AI_src], rax
    add [rip + kept], r12
11: mov rax, [rip + clock]
    mov [r15 + AI_bused], rax
    mov rax, [r15 + AI_id]
    jmp 7f
2:  add rax, AI_SIZE
    dec rcx
    jmp 1b
3:  mov rdi, rbx
    mov rsi, r12
    call mem_dup
    mov r15, rax
    call rec_new
    mov [rax + AI_src], r15
    mov [rax + AI_len], r12
    mov [rax + AI_key], r14
    mov dword ptr [rax + AI_kind], AIK_BYTES
    mov [rax + AI_pin], r13d
    add [rip + kept], r12
    mov rax, [rax + AI_id]
7:  push rax
    push rax
    call keep_cap
    pop rax
    pop rax
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agimg_place(AS*, off, len, n) -> rax id or 0: the n-th image of the record on that line of the session's
#   file (asked again by the same place: the same record)
FN agimg_place
    PROLOGUE
    xor eax, eax
    test rdi, rdi
    jz 9f
    test rsi, rsi
    js 9f
    test rdx, rdx
    jz 9f
    cmp rdx, AT_REREAD_MAX
    ja 9f
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    mov rax, [rip + recs + VEC_ptr]
    mov rcx, [rip + recs + VEC_len]
1:  test rcx, rcx
    jz 3f
    cmp dword ptr [rax + AI_kind], AIK_PLACE
    jne 2f
    cmp [rax + AI_as], rbx
    jne 2f
    cmp [rax + AI_off], r12
    jne 2f
    cmp [rax + AI_plen], r13
    jne 2f
    cmp [rax + AI_n], r14d
    jne 2f
    mov rax, [rax + AI_id]
    jmp 9f
2:  add rax, AI_SIZE
    dec rcx
    jmp 1b
3:  call rec_new
    mov dword ptr [rax + AI_kind], AIK_PLACE
    mov [rax + AI_as], rbx
    mov [rax + AI_cas], rbx
    mov [rax + AI_off], r12
    mov [rax + AI_plen], r13
    mov [rax + AI_n], r14d
    mov rax, [rax + AI_id]
9:  EPILOGUE

# num(ptr, len, *pos) -> rax the decimal number at *pos (moved past it), -1 none
num:
    mov r8, [rdx]
    xor eax, eax
    xor r9d, r9d
1:  cmp r8, rsi
    jae 2f
    movzx ecx, byte ptr [rdi + r8]
    sub ecx, '0'
    cmp ecx, 9
    ja 2f
    imul rax, rax, 10
    add rax, rcx
    inc r8
    inc r9d
    cmp r9d, 18
    jb 1b
2:  mov [rdx], r8
    test r9d, r9d
    jnz 3f
    mov rax, -1
3:  ret

# FN agimg_chip(AS* or 0, target ptr, len) -> rax id or 0: a chip's target: "#ID" (a picture attached here),
#   "@OFF:LEN:N" (the n-th image of the record at that place of the session's file)
FN agimg_chip
    PROLOGUE 16
    xor eax, eax
    cmp rdx, 2
    jb 9f
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov qword ptr [rsp], 1
    movzx eax, byte ptr [r12]
    cmp eax, '#'
    je 1f
    cmp eax, '@'
    jne 8f
    mov rdi, r12                # @OFF:LEN:N
    mov rsi, r13
    lea rdx, [rsp]
    call num
    test rax, rax
    js 8f
    mov r14, rax
    mov rcx, [rsp]
    cmp rcx, r13
    jae 8f
    cmp byte ptr [r12 + rcx], ':'
    jne 8f
    inc qword ptr [rsp]
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rsp]
    call num
    test rax, rax
    jle 8f
    mov r15, rax
    mov rcx, [rsp]
    cmp rcx, r13
    jae 8f
    cmp byte ptr [r12 + rcx], ':'
    jne 8f
    inc qword ptr [rsp]
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rsp]
    call num
    test rax, rax
    js 8f
    cmp [rsp], r13
    jne 8f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    mov ecx, eax
    call agimg_place
    EPILOGUE
1:  mov rdi, r12                # #ID
    mov rsi, r13
    lea rdx, [rsp]
    call num
    test rax, rax
    jle 8f
    cmp [rsp], r13
    jne 8f
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# FN agimg_ctx(AS* or 0, row): the row a reply's data: images asked for from now on belong to (agents.s around
#   a reply's measure; 0: none)
FN agimg_ctx
    mov [rip + ctx_as], rdi
    mov [rip + ctx_row], esi
    ret

# FN agimg_md(link ptr, len) -> rax id or 0: a reply's "data:image/png;base64,…" (jpeg, gif too): its Base64
#   decoded into a record's own bytes; another type, bad Base64, past IMG_FILE_MAX: 0 (the chip "[Image]")
FN agimg_md
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, 11
    jb 8f
    lea rdi, [rip + .Lp_data]   # "data:image/"
    mov rsi, rbx
    mov edx, 11
    call memeq
    test eax, eax
    jz 8f
    xor r13d, r13d              # where ";base64," ends
    mov ecx, 11
1:  lea rax, [rcx + 8]
    cmp rax, r12
    ja 8f
    cmp ecx, 40
    ja 8f
    cmp byte ptr [rbx + rcx], ','
    je 8f
    cmp dword ptr [rbx + rcx], 0x7361623b       # ";bas"
    jne 2f
    cmp dword ptr [rbx + rcx + 4], 0x2c343665   # "e64,"
    jne 2f
    lea r13, [rcx + 8]
    jmp 3f
2:  inc ecx
    jmp 1b
3:  mov rax, r12                # the bytes it would make
    sub rax, r13
    shr rax, 2
    imul rax, rax, 3
    cmp rax, IMG_FILE_MAX + 3
    ja 8f
    mov rdi, rbx                # asked before: its text's hash (the Base64 is decoded once)
    add rdi, r13
    mov rsi, r12
    sub rsi, r13
    call hash
    mov r14, rax
    mov rax, [rip + recs + VEC_ptr]
    mov rcx, [rip + recs + VEC_len]
4:  test rcx, rcx
    jz 5f
    test dword ptr [rax + AI_flags], AIF_MD
    jz 41f
    cmp [rax + AI_key], r14
    jne 41f
    mov r15, rax
    jmp 7f
41: add rax, AI_SIZE
    dec rcx
    jmp 4b
5:  lea rdi, [rip + rsb]
    call sb_clear
    lea rdi, [rip + rsb]
    mov rsi, rbx
    add rsi, r13
    mov rdx, r12
    sub rdx, r13
    call b64_decode
    test eax, eax
    jz 8f
    mov rdi, [rip + rsb + SB_ptr]
    mov rsi, [rip + rsb + SB_len]
    test rsi, rsi
    jz 8f
    cmp rsi, IMG_FILE_MAX
    ja 8f
    call decodable
    test eax, eax
    jz 8f
    mov rdi, [rip + rsb + SB_ptr]
    mov rsi, [rip + rsb + SB_len]
    call mem_dup
    mov r15, rax
    call rec_new
    mov [rax + AI_src], r15
    mov rcx, [rip + rsb + SB_len]
    mov [rax + AI_len], rcx
    add [rip + kept], rcx
    mov [rax + AI_key], r14
    mov dword ptr [rax + AI_kind], AIK_BYTES
    mov dword ptr [rax + AI_flags], AIF_MD
    mov r15, rax
    lea rdi, [rip + rsb]
    call sb_free
7:  cmp dword ptr [r15 + AI_state], AIS_WAIT    # laid out: wanted (its place is the chip until it is made,
    jne 71f                                     #   and the chip asks nothing)
    or dword ptr [r15 + AI_flags], AIF_ASKED
    mov dword ptr [rip + pending], 1
71: mov rax, [rip + ctx_as]     # the row it is in
    mov [r15 + AI_cas], rax
    mov eax, [rip + ctx_row]
    mov [r15 + AI_crow], eax
    mov rax, [r15 + AI_id]
    push rax
    push rax
    call keep_cap
    pop rax
    pop rax
    EPILOGUE
8:  lea rdi, [rip + rsb]
    call sb_free
    xor eax, eax
    EPILOGUE

# FN agimg_unpin(id): a box's part that held it went
FN agimg_unpin
    sub rsp, 8
    call by_id
    test rax, rax
    jz 1f
    cmp dword ptr [rax + AI_pin], 0
    je 1f
    dec dword ptr [rax + AI_pin]
    call keep_cap
1:  add rsp, 8
    ret

# FN agimg_session_gone(AS*): its rows went (cut, read again, the session freed): the records of its file's
#   places and the unpinned ones its rows drew go; a reply's row is forgotten
FN agimg_session_gone
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    cmp [rip + ctx_as], rbx
    jne 0f
    mov qword ptr [rip + ctx_as], 0
0:  xor r12d, r12d
1:  cmp r12, [rip + recs + VEC_len]
    jae 9f
    imul r13, r12, AI_SIZE
    add r13, [rip + recs + VEC_ptr]
    cmp [r13 + AI_as], rbx
    je 3f
    cmp [r13 + AI_cas], rbx
    jne 4f
    cmp dword ptr [r13 + AI_pin], 0
    je 3f
    mov qword ptr [r13 + AI_cas], 0
    mov dword ptr [r13 + AI_crow], -1
4:  inc r12
    jmp 1b
3:  mov rdi, r13
    call rec_drop
    jmp 1b
9:  EPILOGUE

# FN agimg_state(id) -> eax AIS_*, -1 no such record
FN agimg_state
    sub rsp, 8
    call by_id
    test rax, rax
    jz 1f
    mov eax, [rax + AI_state]
    add rsp, 8
    ret
1:  mov eax, -1
    add rsp, 8
    ret

# FN agimg_size(id) -> eax w, edx h of its thumbnail; 0, 0 while it has none
FN agimg_size
    sub rsp, 8
    call by_id
    xor edx, edx
    test rax, rax
    jz 1f
    cmp qword ptr [rax + AI_px], 0
    je 1f
    mov edx, [rax + AI_h]
    mov eax, [rax + AI_w]
    add rsp, 8
    ret
1:  xor eax, eax
    add rsp, 8
    ret

# fit(w, h, side) -> eax w', edx h': w x h fitted in a square of that side
fit:
    mov r8d, edx
    cmp edi, esi
    jb 1f
    mov eax, esi
    imul eax, r8d
    xor edx, edx
    div edi
    mov edx, eax
    mov eax, r8d
    jmp 2f
1:  mov eax, edi
    imul eax, r8d
    xor edx, edx
    div esi
    mov edx, r8d
2:  test eax, eax
    jnz 3f
    mov eax, 1
3:  test edx, edx
    jnz 4f
    mov edx, 1
4:  ret

# FN agimg_draw(id, x, y, side) -> eax 1 the picture drew, fitted and centred in that square; 0 not ready:
#   the record is asked for (a decode, or a copy at this size, between frames). Never decodes or scales
FN agimg_draw
    PROLOGUE
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    call by_id
    test rax, rax
    jz 8f
    mov rbx, rax
    inc qword ptr [rip + clock]
    mov rax, [rip + clock]
    mov [rbx + AI_used], rax
    call time_ms
    mov [rbx + AI_ms], rax
    cmp dword ptr [rbx + AI_state], AIS_READY
    je 1f
    cmp dword ptr [rbx + AI_state], AIS_WAIT
    jne 8f
    test dword ptr [rbx + AI_flags], AIF_ASKED
    jnz 0f
    or dword ptr [rbx + AI_flags], AIF_ASKED
    mov dword ptr [rip + pending], 1
0:  mov [rbx + AI_want], r14d
    jmp 8f
1:  xor r15d, r15d              # its copy at that side
2:  cmp [rbx + AI_cs + r15*4], r14d
    jne 3f
    mov rdx, [rbx + AI_cpx + r15*8]
    test rdx, rdx
    jz 3f
    mov ecx, [rbx + AI_cw + r15*4]
    mov r8d, [rbx + AI_ch + r15*4]
    mov edi, r14d
    sub edi, ecx
    sar edi, 1
    add edi, r12d
    mov esi, r14d
    sub esi, r8d
    sar esi, 1
    add esi, r13d
    call gfx_blit
    mov eax, 1
    EPILOGUE
3:  inc r15d
    cmp r15d, 2
    jb 2b
    mov [rbx + AI_want], r14d   # none: made between frames
    mov dword ptr [rip + pending], 1
8:  xor eax, eax
    EPILOGUE

# copy(AI*): its thumbnail at the side wanted, into the slot replaced next
copy:
    PROLOGUE
    mov rbx, rdi
    mov r12d, [rbx + AI_want]
    mov dword ptr [rbx + AI_want], 0
    test r12d, r12d
    jle 9f
    cmp r12d, 4096
    ja 9f
    cmp qword ptr [rbx + AI_px], 0
    je 9f
    mov edi, [rbx + AI_w]
    mov esi, [rbx + AI_h]
    mov edx, r12d
    call fit
    mov r13d, eax
    mov r14d, edx
    mov rdi, [rbx + AI_px]
    mov esi, [rbx + AI_w]
    mov edx, [rbx + AI_h]
    mov ecx, r13d
    mov r8d, r14d
    call nb_scale
    test rax, rax
    jz 9f
    mov r15, rax
    mov ecx, [rbx + AI_cnext]
    and ecx, 1
    push rcx
    push rcx
    mov rdi, [rbx + AI_cpx + rcx*8]
    call mem_free
    pop rcx
    pop rcx
    mov [rbx + AI_cpx + rcx*8], r15
    mov [rbx + AI_cw + rcx*4], r13d
    mov [rbx + AI_ch + rcx*4], r14d
    mov [rbx + AI_cs + rcx*4], r12d
    xor ecx, 1
    mov [rbx + AI_cnext], ecx
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# rec_bytes(AI*) -> rax ptr, rdx len, ecx 1 when the caller frees ptr; rax 0: none (given up, the file changed)
rec_bytes:
    PROLOGUE 48
    mov rbx, rdi
    cmp dword ptr [rbx + AI_kind], AIK_PLACE
    je 1f
    mov rax, [rbx + AI_src]
    test rax, rax
    jz 8f
    mov rcx, [rip + clock]
    mov [rbx + AI_bused], rcx
    mov rdx, [rbx + AI_len]
    xor ecx, ecx
    EPILOGUE
1:  mov r12, [rbx + AI_as]      # the line again: a line feed before it (or the file's start) and after
    mov rdi, [r12 + AS_path]
    test rdi, rdi
    jz 8f
    mov rdx, [rbx + AI_off]
    xor eax, eax
    test rdx, rdx
    jz 2f
    dec rdx
    mov eax, 1
2:  mov [rsp], eax
    mov rsi, [rbx + AI_plen]
    add rsi, rax
    inc rsi
    call agent_read_window
    test rax, rax
    jz 8f
    mov [rsp + 8], rax
    mov ecx, [rsp]
    mov r8, [rbx + AI_plen]
    lea r9, [r8 + rcx + 1]
    cmp rdx, r9
    jb 7f
    test ecx, ecx
    jz 3f
    cmp byte ptr [rax], 10
    jne 7f
3:  add rax, rcx
    cmp byte ptr [rax + r8], 10
    jne 7f
    mov rdi, rax
    mov rsi, r8
    call json_parse
    test rax, rax
    jz 7f
    mov r13, rax
    mov edi, [r12 + AS_kind]    # the reader gives the image's bytes
    mov esi, 3
    call agent_reader
    test rax, rax
    jz 7f
    mov r14, rax
    lea rdi, [rip + rsb]
    call sb_clear
    mov rdi, r12
    mov rsi, r13
    mov edx, [rbx + AI_n]
    lea rcx, [rip + rsb]
    call r14
    test eax, eax
    jz 7f
    mov rdi, [rsp + 8]
    call mem_free
    mov rax, [rip + rsb + SB_ptr]       # the buffer is the caller's
    mov rdx, [rip + rsb + SB_len]
    xorps xmm0, xmm0
    movups [rip + rsb], xmm0
    mov qword ptr [rip + rsb + 16], 0
    test rdx, rdx
    jnz 6f
    mov rdi, rax
    call mem_free
    jmp 8f
6:  mov ecx, 1
    EPILOGUE
7:  mov rdi, [rsp + 8]
    call mem_free
    lea rdi, [rip + rsb]
    call sb_free
8:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    EPILOGUE

# decode(AI*): the one job of a pass: its bytes, their header, the decode, the thumbnail; everything else
#   freed in the same pass
decode:
    PROLOGUE 16
    mov rbx, rdi
    and dword ptr [rbx + AI_flags], ~AIF_ASKED
    mov rdi, rbx
    call rec_bytes
    test rax, rax
    jz .Ldc_failed
    mov r12, rax
    mov r13, rdx
    mov [rsp], ecx
    mov dword ptr [rbx + AI_state], AIS_REFUSED
    cmp r13, IMG_FILE_MAX
    ja .Ldc_done
    mov rdi, r12
    mov rsi, r13
    call decodable
    test eax, eax
    jz .Ldc_bad
    mov r14d, eax
    mov rdi, r12
    mov rsi, r13
    mov edx, eax
    call image_size
    test eax, eax
    jz .Ldc_bad
    mov [rbx + AI_iw], eax
    mov [rbx + AI_ih], edx
    cmp eax, IMG_SIDE_MAX
    ja .Ldc_done
    cmp edx, IMG_SIDE_MAX
    ja .Ldc_done
    mov ecx, eax
    imul rcx, rdx
    cmp rcx, IMG_PX_MAX
    ja .Ldc_done
    mov rdi, r12
    mov rsi, r13
    mov edx, r14d
    lea rcx, [rip + img]
    call image_decode
    test eax, eax
    jnz .Ldc_bad
    inc qword ptr [rip + decoded]
    mov edi, [rip + img + IMG_w]
    mov esi, [rip + img + IMG_h]
    mov [rbx + AI_iw], edi
    mov [rbx + AI_ih], esi
    mov r14d, edi               # the thumbnail's size: a small picture keeps its own
    mov r15d, esi
    cmp edi, IMG_THUMB
    ja 1f
    cmp esi, IMG_THUMB
    jbe 2f
1:  mov edx, IMG_THUMB
    call fit
    mov r14d, eax
    mov r15d, edx
2:  mov rdi, [rip + img + IMG_px]
    mov esi, [rip + img + IMG_w]
    mov edx, [rip + img + IMG_h]
    mov ecx, r14d
    mov r8d, r15d
    call nb_scale
    push rax
    push rax
    lea rdi, [rip + img]
    call image_free
    pop rax
    pop rax
    test rax, rax
    jz .Ldc_bad
    mov [rbx + AI_px], rax
    mov [rbx + AI_w], r14d
    mov [rbx + AI_h], r15d
    mov dword ptr [rbx + AI_state], AIS_READY
    inc qword ptr [rip + clock]  # made now: as if just drawn (thumbs_cap never gives up the one it just made)
    mov rax, [rip + clock]
    mov [rbx + AI_used], rax
    call time_ms
    mov [rbx + AI_ms], rax
    cmp dword ptr [rbx + AI_want], 0
    je .Ldc_done
    mov rdi, rbx
    call copy
    jmp .Ldc_done
.Ldc_bad:
    mov dword ptr [rbx + AI_state], AIS_FAILED
.Ldc_done:
    cmp dword ptr [rsp], 0
    je 1f
    mov rdi, r12
    call mem_free
1:  mov rax, rbx                # a reply's image: its row measured again
    test dword ptr [rbx + AI_flags], AIF_MD
    jz 3f
    mov rdi, [rbx + AI_cas]
    movsxd rsi, dword ptr [rbx + AI_crow]
    test rdi, rdi
    jz 2f
    test rsi, rsi
    js 2f
    call agents_msg_changed
    jmp 3f
2:  call agents_view_changed
3:  mov rax, [rbx + AI_id]      # (thumbs_cap may move records)
    mov [rsp + 8], rax
    call thumbs_cap
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
.Ldc_failed:
    mov dword ptr [rbx + AI_state], AIS_FAILED
    mov dword ptr [rsp], 0
    jmp 1b

# FN agimg_open(id, title cstr): the whole picture in an image tab, after the frame
FN agimg_open
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rip + pend_title]
    call mem_free
    mov qword ptr [rip + pend_title], 0
    mov [rip + pend_id], rbx
    test r12, r12
    jz 1f
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov [rip + pend_title], rax
1:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# do_open(): agimg_open's picture: its bytes (kept, or its line read again) into iv_open_bytes; neither: the
#   toast; a picture too large to preview is not opened either
do_open:
    PROLOGUE
    mov rdi, [rip + pend_id]
    mov qword ptr [rip + pend_id], 0
    call by_id
    test rax, rax
    jz 7f
    mov rbx, rax
    cmp dword ptr [rbx + AI_state], AIS_REFUSED
    je 6f
    mov rdi, rbx
    call rec_bytes
    test rax, rax
    jz 7f
    mov r12, rax
    mov r13, rdx
    mov r14d, ecx
    mov rdi, r12                # past the pixels allowed (not decoded yet): not opened
    mov rsi, r13
    call decodable
    test eax, eax
    jz 5f
    mov rdi, r12
    mov rsi, r13
    mov edx, eax
    call image_size
    mov ecx, eax
    imul rcx, rdx
    cmp rcx, IMG_PX_MAX
    ja 51f
    cmp eax, IMG_SIDE_MAX
    ja 51f
    cmp edx, IMG_SIDE_MAX
    ja 51f
5:  mov rdi, [rip + pend_title]
    test rdi, rdi
    jnz 4f
    lea rdi, [rip + .Lt_image]
4:  mov rsi, r12
    mov rdx, r13
    call iv_open_bytes
    jmp 52f
51: lea rdi, [rip + .Lt_large]
    call app_toast
52: test r14d, r14d
    jz 8f
    mov rdi, r12
    call mem_free
    jmp 8f
6:  lea rdi, [rip + .Lt_large]
    call app_toast
    jmp 8f
7:  lea rdi, [rip + .Lt_gone]
    call app_toast
8:  mov rdi, [rip + pend_title]
    call mem_free
    mov qword ptr [rip + pend_title], 0
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agimg_hold(on): agent-images-hold: 1 no decode until 0
FN agimg_hold
    mov [rip + hold], edi
    mov dword ptr [rip + pending], 1
    ret

# rested() -> eax ms still to wait since the last key or click (0: rested)
rested:
    sub rsp, 8
    call time_ms
    sub rax, [rip + g_input_ms]
    mov ecx, IMG_REST_MS
    sub rcx, rax
    xor eax, eax
    test rcx, rcx
    jle 1f
    mov eax, ecx
1:  add rsp, 8
    ret

# FN agimg_tick(): a picture to open; the copies wanted; one decode, when rested
FN agimg_tick
    PROLOGUE
    cmp qword ptr [rip + pend_id], 0
    je 1f
    call do_open
1:  cmp dword ptr [rip + pending], 0
    je 9f
    xor r12d, r12d              # the copies wanted, and the oldest record asked for
    xor r13d, r13d
2:  cmp r12, [rip + recs + VEC_len]
    jae 4f
    imul rbx, r12, AI_SIZE
    add rbx, [rip + recs + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + AI_state], AIS_READY
    jne 3f
    cmp dword ptr [rbx + AI_want], 0
    je 2b
    mov rdi, rbx
    call copy
    jmp 2b
3:  cmp dword ptr [rbx + AI_state], AIS_WAIT
    jne 2b
    test dword ptr [rbx + AI_flags], AIF_ASKED
    jz 2b
    test r13, r13
    jnz 2b
    mov r13, [rbx + AI_id]
    jmp 2b
4:  test r13, r13
    jnz 5f
    mov dword ptr [rip + pending], 0
    jmp 9f
5:  cmp dword ptr [rip + hold], 0
    jne 9f
    call rested
    test eax, eax
    jnz 9f
    mov rdi, r13
    call by_id
    mov rdi, rax
    call decode
9:  EPILOGUE

# FN agimg_timeout() -> eax 0 while there is work and the keys rest, the rest of IMG_REST_MS while they do not,
#   -1 with nothing to do
FN agimg_timeout
    xor eax, eax
    cmp qword ptr [rip + pend_id], 0
    jne 9f
    mov eax, -1
    cmp dword ptr [rip + pending], 0
    je 9f
    cmp dword ptr [rip + hold], 0
    jne 1f
    jmp rested
1:  xor eax, eax                # held: only copies (agimg_tick clears pending when there are none)
    push rbx
    xor ecx, ecx
2:  cmp rcx, [rip + recs + VEC_len]
    jae 3f
    imul rbx, rcx, AI_SIZE
    add rbx, [rip + recs + VEC_ptr]
    inc rcx
    cmp dword ptr [rbx + AI_state], AIS_READY
    jne 2b
    cmp dword ptr [rbx + AI_want], 0
    je 2b
    pop rbx
    ret
3:  pop rbx
    mov eax, -1
9:  ret

# ---- a prompt row's image chips (agentrows.s's bubble draws the chips; these draw and open the pictures) ----

# FN agimg_chip_pic(AS* or 0, target ptr, len, x, y, side) -> eax 1 the chip's picture drew, fitted in that
#   square; 0 the image icon instead (no picture yet, refused, or no such target)
FN agimg_chip_pic
    PROLOGUE 16
    mov r15, rdi
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov [rsp + 8], r9d
    call agimg_chip
    mov rbx, rax
    test rax, rax
    jz 4f
    mov rdi, rax
    call by_id
    test rax, rax
    jz 3f
    test r15, r15
    jz 3f
    mov [rax + AI_cas], r15     # the conversation it is shown in
3:  mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    call agimg_draw
    test eax, eax
    jnz 9f
4:  PM ecx, MI_16               # the icon, centred
    cmp ecx, [rsp + 8]
    jle 5f
    mov ecx, [rsp + 8]
5:  mov esi, [rsp + 8]
    sub esi, ecx
    sar esi, 1
    mov edx, esi
    add esi, [rsp]
    add edx, [rsp + 4]
    mov edi, IC_F_IMAGE
    COLOR r8d, T_MUTED
    call icon_draw
    xor eax, eax
9:  EPILOGUE

# FN agimg_chip_open(AS* or 0, target ptr, len, title cstr) -> eax 1: the chip's picture opened whole in an
#   image tab (after the frame); 0 no such picture
FN agimg_chip_open
    PROLOGUE
    mov r12, rcx
    call agimg_chip
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, r12
    call agimg_open
    mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# FN agimg_drew_note(chips cstr, n): the pictures drawn in that chips text this frame (agimg_chips_drew)
FN agimg_drew_note
    mov eax, [rip + drew_at]
    lea rcx, [rip + drew_key]
    mov [rcx + rax*8], rdi
    lea rcx, [rip + drew_n]
    mov [rcx + rax*4], esi
    inc eax
    and eax, DREW_MAX - 1
    mov [rip + drew_at], eax
    ret

# FN agimg_chips_drew(chips cstr) -> eax the pictures drawn in that chips text when it was last drawn (0: none,
#   or not drawn lately)
FN agimg_chips_drew
    xor eax, eax
    test rdi, rdi
    jz 9f
    xor ecx, ecx
    lea r8, [rip + drew_key]
    lea r9, [rip + drew_n]
    mov edx, [rip + drew_at]    # the newest first
1:  cmp ecx, DREW_MAX
    jae 9f
    dec edx
    and edx, DREW_MAX - 1
    inc ecx
    cmp [r8 + rdx*8], rdi
    jne 1b
    mov eax, [r9 + rdx*4]
9:  ret

# ---- dumps ----

# kv(): " NAME=N" into rbx's sb: the name r12, the number r13 (agimg_dump's registers)
kv:
    sub rsp, 8
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    call sb_push_u64
    add rsp, 8
    ret

# FN agimg_dump(sb): print-agent-images: "records=N waiting=N decoded=N refused=N failed=N thumbs=N kept=N
#   copies=N", then a line a record "ID KIND STATE asked=0|1 pin=N size=WxH thumb=WxH bytes=N"
FN agimg_dump
    PROLOGUE 48
    mov rbx, rdi
    xor eax, eax
    mov [rsp], rax              # waiting, refused
    mov [rsp + 8], rax          # failed, thumbs
    mov [rsp + 16], rax         # copies
    xor ecx, ecx
1:  cmp rcx, [rip + recs + VEC_len]
    jae 2f
    imul rdx, rcx, AI_SIZE
    add rdx, [rip + recs + VEC_ptr]
    inc rcx
    mov eax, [rdx + AI_state]
    cmp eax, AIS_WAIT
    jne 11f
    test dword ptr [rdx + AI_flags], AIF_ASKED
    jz 11f
    inc dword ptr [rsp]
11: cmp eax, AIS_REFUSED
    jne 12f
    inc dword ptr [rsp + 4]
12: cmp eax, AIS_FAILED
    jne 13f
    inc dword ptr [rsp + 8]
13: cmp qword ptr [rdx + AI_px], 0
    je 14f
    inc dword ptr [rsp + 12]
14: cmp qword ptr [rdx + AI_cpx], 0
    je 15f
    inc dword ptr [rsp + 16]
15: cmp qword ptr [rdx + AI_cpx + 8], 0
    je 1b
    inc dword ptr [rsp + 16]
    jmp 1b
2:  lea r12, [rip + .Ld_records]
    mov r13, [rip + recs + VEC_len]
    call kv
    lea r12, [rip + .Ld_waiting]
    mov r13d, [rsp]
    call kv
    lea r12, [rip + .Ld_decoded]
    mov r13, [rip + decoded]
    call kv
    lea r12, [rip + .Ld_refused]
    mov r13d, [rsp + 4]
    call kv
    lea r12, [rip + .Ld_failed]
    mov r13d, [rsp + 8]
    call kv
    lea r12, [rip + .Ld_thumbs]
    mov r13d, [rsp + 12]
    call kv
    lea r12, [rip + .Ld_kept]
    mov r13, [rip + kept]
    call kv
    lea r12, [rip + .Ld_copies]
    mov r13d, [rsp + 16]
    call kv
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor r14d, r14d              # a line a record
3:  cmp r14, [rip + recs + VEC_len]
    jae 9f
    imul r15, r14, AI_SIZE
    add r15, [rip + recs + VEC_ptr]
    inc r14
    mov rdi, rbx
    mov rsi, [r15 + AI_id]
    call sb_push_u64
    mov eax, [r15 + AI_kind]
    lea rcx, [rip + kind_names]
    mov rsi, [rcx + rax*8 - 8]
    mov rdi, rbx
    call sb_push_cstr
    mov eax, [r15 + AI_state]
    lea rcx, [rip + state_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    lea r12, [rip + .Ld_asked]
    mov r13d, [r15 + AI_flags]
    and r13d, AIF_ASKED
    call kv
    lea r12, [rip + .Ld_pin]
    mov r13d, [r15 + AI_pin]
    call kv
    lea r12, [rip + .Ld_size]
    mov r13d, [r15 + AI_iw]
    call kv
    mov rdi, rbx
    mov esi, 'x'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r15 + AI_ih]
    call sb_push_u64
    lea r12, [rip + .Ld_thumb]
    mov r13d, [r15 + AI_w]
    call kv
    mov rdi, rbx
    mov esi, 'x'
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r15 + AI_h]
    call sb_push_u64
    lea r12, [rip + .Ld_bytes]
    xor r13d, r13d
    cmp qword ptr [r15 + AI_src], 0
    je 31f
    mov r13, [r15 + AI_len]
31: call kv
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    jmp 3b
9:  EPILOGUE

.section .rodata
.Lp_data: .ascii "data:image/"
.Lt_large: .asciz "Too large to preview"
.Lt_gone: .asciz "The picture is no longer in memory."
.Lt_image: .asciz "Image"
.Ld_records: .asciz "records="
.Ld_waiting: .asciz " waiting="
.Ld_decoded: .asciz " decoded="
.Ld_refused: .asciz " refused="
.Ld_failed: .asciz " failed="
.Ld_thumbs: .asciz " thumbs="
.Ld_kept: .asciz " kept="
.Ld_copies: .asciz " copies="
.Ld_asked: .asciz " asked="
.Ld_pin: .asciz " pin="
.Ld_size: .asciz " size="
.Ld_thumb: .asciz " thumb="
.Ld_bytes: .asciz " bytes="
.Lk_bytes: .asciz " bytes"
.Lk_place: .asciz " place"
.Ls_wait: .asciz " waiting"
.Ls_ready: .asciz " ready"
.Ls_refused: .asciz " refused"
.Ls_failed: .asciz " failed"
.p2align 3
kind_names: .quad .Lk_bytes, .Lk_place
state_names: .quad .Ls_wait, .Ls_ready, .Ls_refused, .Ls_failed
