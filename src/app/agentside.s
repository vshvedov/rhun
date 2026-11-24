# Side panels of a conversation (generic, phase 7 part 3): the side question (/btw, ext-webview-ui.md 3.27)
# and the bookmarks (3.28, the reply's bookmark button of 3.9), docked beside the conversation when the panel
# is wide and stacked above it when it is not (7.17). One side panel at a time; it follows the conversation
# the panel shows (it is hidden, not closed, while that is not one it serves). Nothing here names an agent:
# a side question goes to the conversation's driver as DRV_action ACT_SIDEQ (the question's text; its
# history through agside_history), whose answer comes back as ev_side_answer.
#
# Lifetimes. A side question is a request of its own beside whatever the conversation is doing: a turn that
#   ends does not touch it. With no program running it starts one (agent_run) and goes once it is ready
#   (agside_ready). The program ending (agside_ended) fails it ("Failed to get an answer: NAME ended before
#   it answered."), or cancels it when rhun ended the program ("Cancelled."); the conversation or its live
#   record freed (agside_gone) cancels it. While one waits the program is not idle (agside_busy: the idle
#   stop waits). Clear drops a conversation's exchanges; an answer to a dropped one is ignored. At most
#   SQ_KEEP exchanges a conversation are kept (the bundle's 10), the oldest finished ones dropped first.
# Bookmarks belong to a conversation (its id: its file's name without the extension). A bookmark keeps the
#   reply's text (at most BM_TEXT_MAX bytes) and its identity (an FNV-1a hash and the length of the text), so
#   a reply that left the conversation (cut by a reread, a fork of it rewound) still has its row: "No longer
#   shown in the conversation" with its kept text.
# Where they are kept: rhun's state file of the project, session_project_file(".agents-side"), read once on
#   first need (a panel opened, a reply's button drawn, an answer) and written whole (temporary file and
#   rename) after each change; without a project in memory only. Lines (tab-separated, \t \n \\ escaped):
#   "agside 1" | "size BESIDE STACKED" (per mille of the panel) | "bm SID HASH LEN TEXT" | "sq SID STATE Q A"
#   (finished exchanges: done, empty, cancelled, error). At most BM_MAX bookmarks (the oldest go).
# Speed: nothing runs while nothing changes (no timer). Per frame: the open panel's few exchanges (cached
#   Markdown layouts) or the bookmark rows in view (the conversation's list is made again only when the
#   bookmarks or the conversation change); a reply's button looks its state up in a small cache keyed by
#   the row, its text's revision and the bookmarks' generation.
#
#   agside_open(kind 1 side | 2 bookmarks, AS* or 0, arg ptr, len)   /btw [Q], /bookmarks (a second
#     /bookmarks closes it); the keyboard goes to it
#   agside_close()
#   agside_split(rect in*, rect out*)    agents_draw: out is the conversation's room (in, less the panel's)
#   agside_draw()                        after the conversation: the panel in the room split left
#   agside_key(keysym, cp, mods) -> eax  after agentdlg_key in agents_key
#   agside_field() -> rax, agside_paste(ptr, len)   app.s's routing for FOCUS_AGENTS (else agentdlg's)
#   agside_ask(AS*, ptr, len) -> eax 1   a side question asked
#   agside_ready(AL*), agside_ended(AL*), agside_gone(ptr), agside_busy(AL*) -> eax, agside_flush()
#   agside_history(AL*) -> rax ptr, rdx len: the history of the question being sent, a JSON array of
#     {question, response} (rax 0: none)
#   ev_side_answer(AL*, n, ptr, len, kind SA_*)   the driver's answer to its request n
#   agbook_btn(AM*, left, right, y, rowh) -> eax  draw_msg: a reply's bookmark button at its label line's
#     right (filled while bookmarked; else only while the pointer is over the reply); the width it took
#   agbook_toggle(AS*, AM*)
#   agside_dump(sb), agside_fit_dump(sb), the headless commands (aictl.s's block)
.include "rhun.inc"

.equ SPK_SIDE, 1
.equ SPK_BOOK, 2
.equ SQS_UNSENT, 0              # an exchange's state: waits for the program
.equ SQS_PENDING, 1             #   asked
.equ SQS_DONE, 2
.equ SQS_EMPTY, 3               #   answered with nothing
.equ SQS_CANCELLED, 4
.equ SQS_ERROR, 5               #   SQ_a holds the error's text
.equ SA_ANSWER, 0               # ev_side_answer's kinds
.equ SA_ERROR, 1
.equ SA_EMPTY, 2
.equ SID_CLOSE, 1               # ID_AGSIDE + : its controls
.equ SID_CLEAR, 2
.equ SID_SEND, 3
.equ SID_FIELD, 4
.equ SID_SPLIT, 5
.equ SID_BODY, 6
.equ SID_SHOW, 7
.equ SID_REMOVE, 8
.equ SID_REPLY, 0x80            #   + (row & 0x7f): a reply's bookmark button
.equ SID_ROW, 0x100             #   + i: a bookmark's row (i < 0x100)
.equ ID_SIDE_MD, 0x750000       # + slot << 12: the links of a Markdown text in the panel (slot < 16)
.equ SQ_KEEP, 10
.equ SQ_MAX, 20                 # a conversation's exchanges at most (waiting ones are never dropped)
.equ Q_MAX, 4096
.equ A_MAX, 65536
.equ BM_MAX, 500
.equ BM_TEXT_MAX, 32768
.equ FILE_MAX, 4194304
.equ FIELDS_MAX, 6
.equ CACHE_N, 32
.equ CE_SIZE, 48                # a cache entry: AM*, rev 4, booked 4, gen 8, AS* 8, len 8, text 8

STRUCT
F BMK_sid, 8            # owned cstr
F BMK_hash, 8
F BMK_len, 8            # the reply's whole length
F BMK_text, 8           # owned, NUL-terminated (cut at BM_TEXT_MAX)
F BMK_tlen, 8
ENDSTRUCT BMK_SIZE
STRUCT
F SQX_as, 8             # the conversation, 0 once freed
F SQX_al, 8             # its live record it went to, 0 none
F SQX_sid, 8            # owned cstr ("" without one: kept in memory only)
F SQX_q, 8              # owned
F SQX_qlen, 8
F SQX_a, 8              # owned or 0: the answer, or the error's text
F SQX_alen, 8
F SQX_md, 8             # MD* of the answer, made when first drawn
F SQX_state, 4
F SQX_req, 4            # the driver's request + 1, 0 none
F SQX_mdpx, 4           # the size SQX_md was given
F SQX_h, 4              # its height as laid out last
ENDSTRUCT SQX_SIZE

.data
.p2align 2
sp_side_pm: .long 400           # beside: the panel's share of the width, per mille
sp_stack_pm: .long 450          # stacked: of the height
sp_sel: .long -1                # the bookmark shown (its index in blist), -1 none
show_row: .long -1
.p2align 3
blist_gen: .quad -1
show_n: .quad -1                # show_row was found for show_for with this many rows

.bss
.p2align 3
sp_tf: .zero TF_SIZE            # the side question's field
bms: .zero VEC_SIZE             # BMK*
sqs: .zero VEC_SIZE             # SQX*
blist: .zero VEC_SIZE           # BMK*: the bookmarks of the conversation blist_as
slist: .zero VEC_SIZE           # SQX*: the exchanges of the conversation slist_as
slist_as: .quad 0
sq_gen: .quad 0                 # counts the exchanges added and removed (slist follows it)
slist_gen: .quad 0
wsb: .zero SB_SIZE              # the file's text
fsb: .zero SB_SIZE              # a line's fields, unescaped, each NUL-terminated
hsb: .zero SB_SIZE              # the history sent with a question
tsb: .zero SB_SIZE              # scratch
dsb: .zero SB_SIZE              # dumps
foff: .zero 8 * FIELDS_MAX
fcount: .quad 0
st_path: .quad 0                # owned: the state file, 0 none
blist_as: .quad 0
bm_gen: .quad 0
sq_cur: .quad 0                 # the exchange being sent (agside_history)
md_book: .quad 0                # the shown bookmark's Markdown, for md_for
md_for: .quad 0
md_px: .long 0
show_for: .quad 0
cache: .zero CE_SIZE * CACHE_N
sp_kind: .long 0
sp_keys: .long 0                # the panel has the keyboard (with FOCUS_AGENTS)
sp_shown: .long 0               # drawn this frame (agside_split found its conversation)
sp_dock: .long 0                # 1 beside, 0 stacked
sp_scroll: .long 0
sp_max: .long 0
sp_follow: .long 0              # the side question's body sticks to its end
st_loaded: .long 0
sp_drag: .long 0
sp_field_on: .long 0
sp_rect: .zero 16               # the panel as split last: x, y, w, h
sp_thread: .zero 16             # the conversation's room
# geom's results
g_head: .long 0
g_foot: .long 0
g_pad: .long 0
g_bodyy: .long 0
g_bodyh: .long 0
g_fx: .long 0                   # the field
g_fy: .long 0
g_fw: .long 0
g_fh: .long 0
g_sx: .long 0                   # Send
g_sw: .long 0
g_content: .long 0
g_sicon: .long 0                # Send is an arrow (a narrow panel)

.text

# ---- small helpers ----

# hash_of(ptr, len) -> rax FNV-1a 64
hash_of:
    mov rax, 0xcbf29ce484222325
    mov r8, 0x100000001b3
1:  test rsi, rsi
    jz 2f
    movzx ecx, byte ptr [rdi]
    xor rax, rcx
    imul rax, r8
    inc rdi
    dec rsi
    jmp 1b
2:  ret

# cslen(rsi cstr) -> rdx its length (nothing else changes)
cslen:
    xor edx, edx
1:  cmp byte ptr [rsi + rdx], 0
    je 2f
    inc rdx
    jmp 1b
2:  ret

# sid_of(AS* or 0) -> rax ptr, rdx len: the conversation's id (its file's name without its extension);
#   rdx 0 none
sid_of:
    PROLOGUE
    xor eax, eax
    xor edx, edx
    test rdi, rdi
    jz 9f
    mov rbx, [rdi + AS_path]
    test rbx, rbx
    jz 8f
    mov rdi, rbx
    call strlen
    mov r12, rax                # the end
    mov rcx, rax
1:  test rcx, rcx
    jz 2f
    movzx edx, byte ptr [rbx + rcx - 1]
    cmp edx, '/'
    je 2f
    cmp edx, '\\'
    je 2f
    dec rcx
    jmp 1b
2:  mov r13, rcx                # the name's start
    mov rcx, r12
3:  cmp rcx, r13
    jbe 4f
    cmp byte ptr [rbx + rcx - 1], '.'
    je 5f
    dec rcx
    jmp 3b
4:  mov rcx, r12                # no extension
    jmp 6f
5:  dec rcx                     # before the dot
6:  lea rax, [rbx + r13]
    mov rdx, rcx
    sub rdx, r13
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
9:  EPILOGUE

# sid_is(cstr, ptr, len) -> eax 1 when the cstr is that id
sid_is:
    mov rax, rdi
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rax
    jmp str_eq_cstr

# viewed() -> rax the conversation the panel shows when a built-in agent's (else 0)
viewed:
    PROLOGUE
    call agents_viewed
    test rax, rax
    jz 9f
    mov rbx, rax                # p8: a session of no built-in kind has no side panels (agent_drv.s)
    mov rdi, rax
    call agent_src_flags
    test eax, SRCF_OWN
    mov eax, 0
    cmovz rax, rbx
9:  EPILOGUE

# shown_as() -> rax the conversation the open panel serves now, 0 none (none open; or a side question on a
#   conversation without a driver of its own)
shown_as:
    PROLOGUE
    xor eax, eax
    cmp dword ptr [rip + sp_kind], 0
    je 9f
    call viewed
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp dword ptr [rip + sp_kind], SPK_SIDE
    jne 8f
    mov rdi, rbx
    call agent_drv_of
    test rax, rax
    jz 7f
    test dword ptr [rax + DRV_caps], DRVC_SESSION
    jnz 7f
8:  mov rax, rbx
    EPILOGUE
7:  xor eax, eax
9:  EPILOGUE

# dup_cut(ptr, len, max) -> rax an owned NUL-terminated copy of at most max bytes (a UTF-8 character is
#   not split), rdx its length
dup_cut:
    PROLOGUE
    cmp rsi, rdx
    jbe 2f
    mov rsi, rdx
1:  test rsi, rsi
    jz 2f
    movzx eax, byte ptr [rdi + rsi]
    and eax, 0xc0
    cmp eax, 0x80
    jne 2f
    dec rsi
    jmp 1b
2:  mov rbx, rsi
    call mem_dup
    mov rdx, rbx
    EPILOGUE

# ---- the state file ----

# st_need(): the state file read, once
st_need:
    PROLOGUE
    cmp dword ptr [rip + st_loaded], 0
    jne 9f
    mov dword ptr [rip + st_loaded], 1
    lea rdi, [rip + .Lsuffix]
    call session_project_file
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov [rip + st_path], rax
    mov rdi, rax
    mov esi, FILE_MAX
    call file_read_limited
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    mov rsi, rdx
    call st_parse
    mov rdi, r12
    call mem_free
9:  EPILOGUE

# st_parse(buf, len): the file's lines
st_parse:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rdi + rsi]        # the end
    mov rdi, rbx                # "agside 1" first
    mov rsi, r12
    call line_fields
    mov r13, rax                # the next line
    cmp qword ptr [rip + fcount], 2
    jb 9f
    mov edi, 0
    call fld
    lea rsi, [rip + .Lw_head]
    mov rdi, rax
    call strcmp_eq
    test eax, eax
    jz 9f
1:  cmp r13, r12
    jae 9f
    mov rdi, r13
    mov rsi, r12
    call line_fields
    mov r13, rax
    xor edi, edi
    call fld
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .Lw_size]
    call strcmp_eq
    test eax, eax
    jnz 2f
    mov rdi, r14
    lea rsi, [rip + .Lw_bm]
    call strcmp_eq
    test eax, eax
    jnz 3f
    mov rdi, r14
    lea rsi, [rip + .Lw_sq]
    call strcmp_eq
    test eax, eax
    jnz 4f
    jmp 1b
2:  cmp qword ptr [rip + fcount], 3
    jb 1b
    mov edi, 1
    call fld_pm
    mov [rip + sp_side_pm], eax
    mov edi, 2
    call fld_pm
    mov [rip + sp_stack_pm], eax
    jmp 1b
3:  cmp qword ptr [rip + fcount], 5
    jb 1b
    cmp qword ptr [rip + bms + VEC_len], BM_MAX
    jae 1b
    mov edi, BMK_SIZE
    call mem_alloc
    mov r15, rax
    mov edi, 1
    call fld_dup
    mov [r15 + BMK_sid], rax
    mov edi, 2
    call fld
    mov rdi, rax
    call strlen
    mov rsi, rax
    mov edi, 2
    call fld
    mov rdi, rax
    call parse_hex
    mov [r15 + BMK_hash], rax
    mov edi, 3
    call fld
    mov rdi, rax
    call strlen
    mov rsi, rax
    mov edi, 3
    call fld
    mov rdi, rax
    call parse_u64
    mov [r15 + BMK_len], rax
    mov edi, 4
    call fld
    mov r14, rax
    mov rdi, rax
    call strlen
    mov rdi, r14
    mov rsi, rax
    mov edx, BM_TEXT_MAX
    call dup_cut
    mov [r15 + BMK_text], rax
    mov [r15 + BMK_tlen], rdx
    lea rdi, [rip + bms]
    mov esi, 8
    call vec_push
    mov [rax], r15
    jmp 1b
4:  cmp qword ptr [rip + fcount], 5
    jb 1b
    mov edi, SQX_SIZE
    call mem_alloc
    mov r15, rax
    mov edi, 1
    call fld_dup
    mov [r15 + SQX_sid], rax
    mov edi, 2
    call fld
    mov rdi, rax
    call state_of
    mov [r15 + SQX_state], eax
    mov edi, 3
    call fld
    mov r14, rax
    mov rdi, rax
    call strlen
    mov rdi, r14
    mov rsi, rax
    mov edx, Q_MAX
    call dup_cut
    mov [r15 + SQX_q], rax
    mov [r15 + SQX_qlen], rdx
    mov edi, 4
    call fld
    mov r14, rax
    mov rdi, rax
    call strlen
    mov rdi, r14
    mov rsi, rax
    mov edx, A_MAX
    call dup_cut
    mov [r15 + SQX_a], rax
    mov [r15 + SQX_alen], rdx
    lea rdi, [rip + sqs]
    mov esi, 8
    call vec_push
    mov [rax], r15
    inc qword ptr [rip + sq_gen]
    jmp 1b
9:  EPILOGUE

# fld(i) -> rax the i-th field of the line read last (a cstr; "" past the last)
fld:
    lea rax, [rip + .Lempty]
    cmp rdi, [rip + fcount]
    jae 1f
    lea rcx, [rip + foff]
    mov rax, [rcx + rdi*8]
    add rax, [rip + fsb + SB_ptr]
1:  ret

# fld_dup(i) -> rax an owned copy of field i
fld_dup:
    PROLOGUE
    call fld
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    EPILOGUE

# fld_pm(i) -> eax field i as a per mille share within 100..900 (400 when it is not a number)
fld_pm:
    PROLOGUE
    call fld
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call parse_u64
    test rdx, rdx
    jz 1f
    cmp rax, 100
    jb 1f
    cmp rax, 900
    ja 1f
    EPILOGUE
1:  mov eax, 400
    EPILOGUE

# state_of(cstr) -> eax SQS_* (cancelled for a word it does not know)
state_of:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rip + state_words]
    xor r13d, r13d
1:  mov rsi, [r12 + r13*8]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jnz 2f
    inc r13d
    jmp 1b
2:  mov eax, r13d
    EPILOGUE
8:  mov eax, SQS_CANCELLED
    EPILOGUE

# line_fields(p, end) -> rax the next line's start: the line at p split at its tabs into fsb (unescaped,
#   each NUL-terminated; foff, fcount)
line_fields:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + fsb]
    call sb_clear
    mov qword ptr [rip + fcount], 0
    xor r13d, r13d              # a field begins
1:  test r13d, r13d
    jnz 2f
    mov r13d, 1
    mov rax, [rip + fcount]
    cmp rax, FIELDS_MAX
    jae 2f
    lea rcx, [rip + foff]
    mov rdx, [rip + fsb + SB_len]
    mov [rcx + rax*8], rdx
    inc qword ptr [rip + fcount]
2:  cmp rbx, r12
    jae 8f
    movzx eax, byte ptr [rbx]
    inc rbx
    cmp eax, 10
    je 8f
    cmp eax, 9
    jne 3f
    lea rdi, [rip + fsb]        # a field ends
    xor esi, esi
    call sb_push_byte
    xor r13d, r13d
    jmp 1b
3:  cmp eax, '\\'
    jne 5f
    cmp rbx, r12
    jae 5f
    movzx eax, byte ptr [rbx]
    inc rbx
    cmp eax, 't'
    jne 4f
    mov eax, 9
    jmp 5f
4:  cmp eax, 'n'
    jne 5f
    mov eax, 10
5:  lea rdi, [rip + fsb]
    mov esi, eax
    call sb_push_byte
    jmp 2b
8:  lea rdi, [rip + fsb]
    xor esi, esi
    call sb_push_byte
    mov rax, rbx
    EPILOGUE

# esc_push(sb, ptr, len): the text with tab, line feed and backslash escaped
esc_push:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rsi + rdx]
1:  cmp r12, r13
    jae 9f
    movzx r14d, byte ptr [r12]
    inc r12
    mov eax, 't'
    cmp r14d, 9
    je 2f
    mov eax, 'n'
    cmp r14d, 10
    je 2f
    mov eax, '\\'
    cmp r14d, '\\'
    je 2f
    mov rdi, rbx
    mov esi, r14d
    call sb_push_byte
    jmp 1b
2:  mov r14d, eax
    mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
    mov rdi, rbx
    mov esi, r14d
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# esc_cstr(sb, cstr)
esc_cstr:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call esc_push
    EPILOGUE

# tab(sb)
tab:
    mov esi, 9
    jmp sb_push_byte

# st_save(): the file written whole (nothing without a project)
st_save:
    PROLOGUE
    call st_need
    cmp qword ptr [rip + st_path], 0
    je 9f
    lea rbx, [rip + wsb]
    mov rdi, rbx
    call sb_clear
    mov rdi, rbx
    lea rsi, [rip + .Lw_head_line]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lw_size]
    call sb_push_cstr
    mov rdi, rbx
    call tab
    mov rdi, rbx
    mov esi, [rip + sp_side_pm]
    call sb_push_u64
    mov rdi, rbx
    call tab
    mov rdi, rbx
    mov esi, [rip + sp_stack_pm]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor r12d, r12d
1:  cmp r12, [rip + bms + VEC_len]
    jae 3f
    mov rax, [rip + bms + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    mov rdi, rbx
    lea rsi, [rip + .Lw_bm]
    call sb_push_cstr
    mov rdi, rbx
    call tab
    mov rdi, rbx
    mov rsi, [r13 + BMK_sid]
    call esc_cstr
    mov rdi, rbx
    call tab
    mov rdi, rbx
    mov rsi, [r13 + BMK_hash]
    call push_hex
    mov rdi, rbx
    call tab
    mov rdi, rbx
    mov rsi, [r13 + BMK_len]
    call sb_push_u64
    mov rdi, rbx
    call tab
    mov rdi, rbx
    mov rsi, [r13 + BMK_text]
    mov rdx, [r13 + BMK_tlen]
    call esc_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    jmp 1b
3:  xor r12d, r12d
4:  cmp r12, [rip + sqs + VEC_len]
    jae 6f
    mov rax, [rip + sqs + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    cmp dword ptr [r13 + SQX_state], SQS_DONE
    jb 4b                       # waiting ones are not kept
    mov rax, [r13 + SQX_sid]
    cmp byte ptr [rax], 0
    je 4b
    mov rdi, rbx
    lea rsi, [rip + .Lw_sq]
    call sb_push_cstr
    mov rdi, rbx
    call tab
    mov rdi, rbx
    mov rsi, [r13 + SQX_sid]
    call esc_cstr
    mov rdi, rbx
    call tab
    mov eax, [r13 + SQX_state]
    lea rcx, [rip + state_words]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    call tab
    mov rdi, rbx
    mov rsi, [r13 + SQX_q]
    mov rdx, [r13 + SQX_qlen]
    call esc_push
    mov rdi, rbx
    call tab
    mov rsi, [r13 + SQX_a]
    test rsi, rsi
    jz 5f
    mov rdi, rbx
    mov rdx, [r13 + SQX_alen]
    call esc_push
5:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    jmp 4b
6:  mov rdi, [rip + st_path]
    mov rsi, [rbx + SB_ptr]
    mov rdx, [rbx + SB_len]
    call file_write_all
9:  EPILOGUE

# push_hex(sb, u64): 16 hex digits
push_hex:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, 60
1:  mov rax, r12
    mov ecx, r13d
    shr rax, cl
    and eax, 15
    lea rcx, [rip + .Lhex]
    movzx esi, byte ptr [rcx + rax]
    mov rdi, rbx
    call sb_push_byte
    sub r13d, 4
    jns 1b
    EPILOGUE

# FN agside_flush(): saved, then everything freed (the project changes, rhun quits): read again on next need
FN agside_flush
    PROLOGUE
    cmp dword ptr [rip + st_loaded], 0
    je 9f
    call st_save
    call agside_close
    xor ebx, ebx
1:  cmp rbx, [rip + bms + VEC_len]
    jae 2f
    mov rax, [rip + bms + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call bm_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + bms + VEC_len], 0
    xor ebx, ebx
3:  cmp rbx, [rip + sqs + VEC_len]
    jae 4f
    mov rax, [rip + sqs + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call sq_free
    inc rbx
    jmp 3b
4:  mov qword ptr [rip + sqs + VEC_len], 0
    inc qword ptr [rip + sq_gen]
    mov qword ptr [rip + slist_as], 0
    mov rdi, [rip + st_path]
    call mem_free
    mov qword ptr [rip + st_path], 0
    mov dword ptr [rip + st_loaded], 0
    call forget
9:  EPILOGUE

# forget(): what was made from the records (the list, the shown bookmark's text, the cache) goes
forget:
    PROLOGUE
    inc qword ptr [rip + bm_gen]
    mov qword ptr [rip + blist_as], 0
    mov qword ptr [rip + blist + VEC_len], 0
    mov rdi, [rip + md_book]
    test rdi, rdi
    jz 1f
    call md_free
1:  mov qword ptr [rip + md_book], 0
    mov qword ptr [rip + md_for], 0
    mov qword ptr [rip + show_for], 0
    mov dword ptr [rip + show_row], -1
    lea rdi, [rip + cache]
    xor eax, eax
    mov ecx, CE_SIZE * CACHE_N
    rep stosb
    EPILOGUE

bm_free:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + BMK_sid]
    call mem_free
    mov rdi, [rbx + BMK_text]
    call mem_free
    mov rdi, rbx
    call mem_free
    EPILOGUE

sq_free:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + SQX_sid]
    call mem_free
    mov rdi, [rbx + SQX_q]
    call mem_free
    mov rdi, [rbx + SQX_a]
    call mem_free
    mov rdi, [rbx + SQX_md]
    test rdi, rdi
    jz 1f
    call md_free
1:  mov rdi, rbx
    call mem_free
    EPILOGUE

# vec_del(VEC*, i): the i-th pointer out, the others keep their order
vec_del:
    mov rcx, [rdi + VEC_len]
    dec rcx
    mov [rdi + VEC_len], rcx
    mov rax, [rdi + VEC_ptr]
1:  cmp rsi, rcx
    jae 2f
    mov rdx, [rax + rsi*8 + 8]
    mov [rax + rsi*8], rdx
    inc rsi
    jmp 1b
2:  ret

# ---- the panel ----

# FN agside_open(kind, AS* or 0, arg ptr, len): the side question (its text, when given, asked at once) or
#   the bookmarks (open already: closed); the keyboard goes to it
FN agside_open
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    call st_need
    call agentpop_close
    cmp ebx, SPK_BOOK
    jne 1f
    cmp dword ptr [rip + sp_kind], SPK_BOOK
    jne 1f
    test r14, r14
    jnz 1f
    call agside_close           # /bookmarks again: it closes, as the header's button toggles it
    EPILOGUE
1:  cmp [rip + sp_kind], ebx
    je 2f
    mov dword ptr [rip + sp_scroll], 0
    mov dword ptr [rip + sp_sel], -1
2:  mov [rip + sp_kind], ebx
    mov dword ptr [rip + sp_keys], 1
    mov dword ptr [rip + sp_follow], 1
    mov dword ptr [rip + sp_tf + TF_id], ID_AGSIDE + SID_FIELD
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov dword ptr [rip + g_dirty], 1
    cmp ebx, SPK_SIDE
    jne 9f
    test r14, r14
    jz 9f
    test r12, r12
    jnz 3f
    call viewed
    mov r12, rax
    test rax, rax
    jz 9f
3:  mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call agside_ask
9:  EPILOGUE

# FN agside_run(AS* or 0, act, ptr, len): agentpop_run's ACT_BTW (/btw [Q]: a draft's question makes its
#   conversation first), ACT_BOOKMARKS, ACT_TASKS (the agent map of the conversation shown)
FN agside_run
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, ACT_BASHES
    jne 0f
    mov r12d, ACT_TASKS
0:  test rbx, rbx
    jnz 1f
    cmp r12d, ACT_BTW           # a draft's question: its conversation first (as any command of a draft)
    jne 5f
    test r14, r14
    jz 5f
    call agentext_draft_own
    mov rbx, rax
    test rax, rax
    jnz 1f
5:  call viewed
    mov rbx, rax
1:  cmp r12d, ACT_TASKS
    jne 2f
    mov rdi, rbx
    call agmap_open
    test eax, eax
    jnz 9f
    lea rdi, [rip + .Le_noconv]
    call app_toast
    EPILOGUE
2:  mov r15d, SPK_BOOK
    cmp r12d, ACT_BOOKMARKS
    je 3f
    mov r15d, SPK_SIDE
3:  mov edi, r15d
    mov rsi, rbx
    mov rdx, r13
    mov rcx, r14
    call agside_open
9:  EPILOGUE

# FN agside_close(): the panel goes; the keyboard to the box when the panel shows a driven conversation
FN agside_close
    PROLOGUE
    cmp dword ptr [rip + sp_kind], 0
    je 9f
    mov dword ptr [rip + sp_kind], 0
    mov dword ptr [rip + sp_keys], 0
    mov dword ptr [rip + sp_shown], 0
    mov dword ptr [rip + g_dirty], 1
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    jne 9f
    call agents_open_driven
    test rax, rax
    jz 9f
    mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
9:  EPILOGUE

# FN agside_split(rect in*, rect out*): out = the conversation's room: in, less the open panel's (beside it at
#   the right from 576 px at 1x, else above it), which is kept for agside_draw
FN agside_split
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call viewed                 # the agent map follows the conversation drawn (agentmap.s)
    mov rdi, rax
    call agmap_tick
    mov rax, [rbx]
    mov [r12], rax
    mov rax, [rbx + 8]
    mov [r12 + 8], rax
    mov dword ptr [rip + sp_shown], 0
    cmp dword ptr [rip + fit_force], 0
    jne 0f
    call shown_as
    test rax, rax
    jz 9f
    mov dword ptr [rip + sp_shown], 1
0:  mov eax, [rbx + 8]          # w
    PM ecx, MI_64
    imul ecx, ecx, 9
    cmp eax, ecx
    jl 5f
    mov dword ptr [rip + sp_dock], 1
    imul eax, [rip + sp_side_pm]
    xor edx, edx
    mov ecx, 1000
    div ecx
    PM ecx, MI_64               # 192 at 1x at least, the conversation 320 at least
    imul ecx, ecx, 3
    cmp eax, ecx
    jge 1f
    mov eax, ecx
1:  mov ecx, [rbx + 8]
    PM edx, MI_64
    imul edx, edx, 5
    sub ecx, edx
    cmp eax, ecx
    jle 2f
    mov eax, ecx
2:  mov ecx, [rbx + 8]
    sub ecx, eax
    mov [r12 + 8], ecx          # the conversation's width
    mov edx, [rbx]
    add edx, ecx
    mov [rip + sp_rect], edx
    mov edx, [rbx + 4]
    mov [rip + sp_rect + 4], edx
    mov [rip + sp_rect + 8], eax
    mov edx, [rbx + 12]
    mov [rip + sp_rect + 12], edx
    jmp 8f
5:  mov dword ptr [rip + sp_dock], 0
    mov eax, [rbx + 8]
    mov [rip + sp_rect + 8], eax
    call geom                   # its title, its field, two lines of its body at least
    mov r13d, [rip + g_head]
    add r13d, [rip + g_foot]
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    lea r13d, [r13 + rax*2]
    add r13d, [rip + g_pmt + 4*MI_12]
    mov eax, [rbx + 12]
    imul eax, [rip + sp_stack_pm]
    xor edx, edx
    mov ecx, 1000
    div ecx
    cmp eax, r13d
    jge 6f
    mov eax, r13d
6:  mov ecx, [rbx + 12]         # the conversation keeps 192 at 1x (its title, its box)
    PM edx, MI_64
    imul edx, edx, 3
    sub ecx, edx
    cmp eax, ecx
    jle 7f
    mov eax, ecx
7:  cmp eax, r13d               # too short for both: the panel its least, at most three fifths
    jge 71f
    mov eax, r13d
    mov ecx, [rbx + 12]
    imul ecx, ecx, 3
    xor edx, edx
    mov r8d, 5
    xchg eax, ecx
    div r8d
    cmp ecx, eax
    cmovl eax, ecx
71: mov ecx, [rbx]
    mov [rip + sp_rect], ecx
    mov ecx, [rbx + 4]
    mov [rip + sp_rect + 4], ecx
    mov ecx, [rbx + 8]
    mov [rip + sp_rect + 8], ecx
    mov [rip + sp_rect + 12], eax
    add [r12 + 4], eax
    sub [r12 + 12], eax
8:  mov rax, [r12]
    mov [rip + sp_thread], rax
    mov rax, [r12 + 8]
    mov [rip + sp_thread + 8], rax
9:  EPILOGUE

# geom(): the parts of the panel at sp_rect (g_*)
geom:
    PROLOGUE
    PM eax, MI_12
    cmp dword ptr [rip + sp_rect + 8], 320
    jge 1f
    PM eax, MI_8
1:  mov [rip + g_pad], eax
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    PM ecx, MI_28
    cmp eax, ecx
    cmovl eax, ecx
    PM ecx, MI_6
    lea eax, [rax + rcx*2]
    mov [rip + g_head], eax
    mov dword ptr [rip + g_foot], 0
    mov dword ptr [rip + g_fw], 0
    mov dword ptr [rip + g_sw], 0
    cmp dword ptr [rip + sp_kind], SPK_SIDE
    jne 4f
    mov rax, [rip + ag_fui]     # the field: two lines; Send at its right
    mov [rip + sp_tf + TF_face], rax
    lea rdi, [rip + sp_tf]
    call ta_line_h_of
    lea eax, [rax*2]
    PM ecx, MI_10
    add eax, ecx
    mov [rip + g_fh], eax
    PM ecx, MI_8
    lea edx, [rax + rcx*2]
    mov [rip + g_foot], edx
    mov dword ptr [rip + g_sicon], 0
    mov rdi, [rip + ag_fui]
    lea rsi, [rip + .Lsend]
    mov edx, 4
    call text_width
    PM ecx, MI_12
    lea eax, [rax + rcx*2]
    mov ecx, [rip + sp_rect + 8]    # the field narrower than 8 characters: Send is an arrow
    sub ecx, [rip + g_pad]
    sub ecx, [rip + g_pad]
    sub ecx, eax
    sub ecx, [rip + g_pmt + 4*MI_8]
    mov rdx, [rip + ag_fui]
    mov edx, [rdx + FACE_cellw]
    shl edx, 3
    cmp ecx, edx
    jge 21f
    mov dword ptr [rip + g_sicon], 1
    PM eax, MI_28
21: mov [rip + g_sw], eax
    mov ecx, [rip + sp_rect]
    add ecx, [rip + sp_rect + 8]
    sub ecx, [rip + g_pad]
    sub ecx, eax
    mov [rip + g_sx], ecx
    mov edx, [rip + sp_rect]
    add edx, [rip + g_pad]
    mov [rip + g_fx], edx
    PM eax, MI_8
    sub ecx, eax
    sub ecx, edx
    cmp ecx, 1
    jge 3f
    mov ecx, 1
3:  mov [rip + g_fw], ecx
    mov eax, [rip + sp_rect + 4]
    add eax, [rip + sp_rect + 12]
    sub eax, [rip + g_foot]
    PM ecx, MI_8
    add eax, ecx
    mov [rip + g_fy], eax
4:  mov eax, [rip + sp_rect + 4]
    add eax, [rip + g_head]
    mov [rip + g_bodyy], eax
    mov eax, [rip + sp_rect + 12]
    sub eax, [rip + g_head]
    sub eax, [rip + g_foot]
    jns 5f
    xor eax, eax
5:  mov [rip + g_bodyh], eax
    EPILOGUE

# body_w() -> eax the body's text width
body_w:
    mov eax, [rip + sp_rect + 8]
    sub eax, [rip + g_pad]
    sub eax, [rip + g_pad]
    cmp eax, 1
    jge 1f
    mov eax, 1
1:  ret

# panel_px() -> eax the panel's text size in pixels
panel_px:
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_px]
    ret

# FN agside_draw(): the open panel in the room agside_split left for it
FN agside_draw
    PROLOGUE 48
    cmp dword ptr [rip + sp_shown], 0
    je 9f
    call shown_as
    test rax, rax
    jz 9f
    mov rbx, rax
    call geom
    mov eax, [rip + g_pressed]  # a press elsewhere takes the keyboard from it
    test eax, 1 << BTN_LEFT
    jz 1f
    mov edi, [rip + sp_rect]
    mov esi, [rip + sp_rect + 4]
    mov edx, [rip + sp_rect + 8]
    mov ecx, [rip + sp_rect + 12]
    call ui_in
    test eax, eax
    jnz 1f
    mov dword ptr [rip + sp_keys], 0
1:  mov edi, [rip + sp_rect]
    mov esi, [rip + sp_rect + 4]
    mov edx, [rip + sp_rect + 8]
    mov ecx, [rip + sp_rect + 12]
    COLOR r8d, T_PANEL
    call gfx_fill
    mov edi, [rip + sp_rect]
    mov esi, [rip + sp_rect + 4]
    mov edx, [rip + sp_rect + 8]
    mov ecx, [rip + sp_rect + 12]
    call gfx_clip_push
    call draw_split
    call draw_head
    test eax, eax
    jnz 8f
    cmp dword ptr [rip + sp_kind], SPK_SIDE
    jne 2f
    mov rdi, rbx
    call side_body
    mov rdi, rbx
    call side_foot
    jmp 8f
2:  mov rdi, rbx
    call book_body
8:  call gfx_clip_pop
9:  EPILOGUE

# draw_split(): the border toward the conversation and its handle ("Resize bookmarks panel"): dragged, the
#   panel's share follows the pointer; let go, it is kept
draw_split:
    PROLOGUE
    PM r12d, MI_6
    cmp dword ptr [rip + sp_dock], 0
    je 1f
    mov edi, [rip + sp_rect]
    mov esi, [rip + sp_rect + 4]
    PM edx, MI_1
    mov ecx, [rip + sp_rect + 12]
    COLOR r8d, T_BORDER
    call gfx_fill
    mov edi, ID_AGSIDE + SID_SPLIT
    mov esi, [rip + sp_rect]
    mov edx, [rip + sp_rect + 4]
    mov ecx, r12d
    mov r8d, [rip + sp_rect + 12]
    call ui_btn
    mov ebx, eax
    test ebx, UB_HOVER | UB_HELD
    jz 5f
    mov edi, CUR_EW
    call ui_set_cursor
    test ebx, UB_HELD
    jz 5f
    mov eax, [rip + sp_rect]    # the panel's right end stays: its width from the pointer
    add eax, [rip + sp_rect + 8]
    sub eax, [rip + g_mx]
    mov ecx, [rip + sp_rect + 8]
    add ecx, [rip + sp_thread + 8]
    jmp 4f
1:  mov edi, [rip + sp_rect]
    mov esi, [rip + sp_rect + 4]
    add esi, [rip + sp_rect + 12]
    PM ecx, MI_1
    sub esi, ecx
    mov edx, [rip + sp_rect + 8]
    COLOR r8d, T_BORDER
    call gfx_fill
    mov edi, ID_AGSIDE + SID_SPLIT
    mov esi, [rip + sp_rect]
    mov edx, [rip + sp_rect + 4]
    add edx, [rip + sp_rect + 12]
    sub edx, r12d
    mov ecx, [rip + sp_rect + 8]
    mov r8d, r12d
    call ui_btn
    mov ebx, eax
    test ebx, UB_HOVER | UB_HELD
    jz 5f
    mov edi, CUR_NS
    call ui_set_cursor
    test ebx, UB_HELD
    jz 5f
    mov eax, [rip + g_my]
    sub eax, [rip + sp_rect + 4]
    mov ecx, [rip + sp_rect + 12]
    add ecx, [rip + sp_thread + 12]
4:  test ecx, ecx               # (eax: the size wanted, ecx: the whole)
    jle 9f
    imul eax, eax, 1000
    cdq
    idiv ecx
    cmp eax, 100
    jge 41f
    mov eax, 100
41: cmp eax, 900
    jle 42f
    mov eax, 900
42: lea rcx, [rip + sp_side_pm]
    cmp dword ptr [rip + sp_dock], 0
    jne 43f
    lea rcx, [rip + sp_stack_pm]
43: cmp [rcx], eax
    je 44f
    mov [rcx], eax
    mov dword ptr [rip + g_dirty], 1
44: mov dword ptr [rip + sp_drag], 1
    jmp 9f
5:  cmp dword ptr [rip + sp_drag], 0
    je 9f
    mov dword ptr [rip + sp_drag], 0
    call st_save
9:  EPILOGUE

# draw_head() -> eax 1 when its × closed it: the title, Clear (the side question's, with exchanges), ×
draw_head:
    PROLOGUE 16
    PM r12d, MI_28
    mov r13d, [rip + g_head]
    sub r13d, r12d
    sar r13d, 1
    add r13d, [rip + sp_rect + 4]   # the buttons' top
    mov r14d, [rip + sp_rect]
    add r14d, [rip + sp_rect + 8]
    sub r14d, [rip + g_pmt + 4*MI_6]
    sub r14d, r12d              # the ×'s x
    mov edi, ID_AGSIDE + SID_CLOSE
    mov esi, r14d
    mov edx, r13d
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_CLOSE
    call ag_icon_btn
    test eax, UB_CLICK
    jz 1f
    call agside_close
    mov eax, 1
    EPILOGUE
1:  cmp dword ptr [rip + sp_kind], SPK_SIDE
    jne 2f
    call viewed
    mov rdi, rax
    call sq_count
    test eax, eax
    jz 2f
    sub r14d, r12d
    sub r14d, [rip + g_pmt + 4*MI_2]
    mov edi, ID_AGSIDE + SID_CLEAR
    mov esi, r14d
    mov edx, r13d
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_TRASH
    call ag_icon_btn
    test eax, UB_CLICK
    jz 2f
    call viewed
    mov rdi, rax
    call sq_clear
2:  lea rsi, [rip + .Lt_side]
    cmp dword ptr [rip + sp_kind], SPK_SIDE
    je 3f
    lea rsi, [rip + .Lt_book]
3:  mov [rsp], rsi
    mov rdi, rsi
    call strlen
    mov r9, rax
    mov r8, [rsp]
    mov rdi, [rip + ag_fui]
    mov esi, [rip + sp_rect]
    add esi, [rip + g_pad]
    mov edx, [rip + sp_rect + 4]
    mov ecx, [rip + g_head]
    COLOR r10d, T_FG
    mov r11d, r14d
    sub r11d, esi
    sub r11d, [rip + g_pmt + 4*MI_4]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    mov edi, [rip + sp_rect]
    mov esi, [rip + sp_rect + 4]
    add esi, [rip + g_head]
    PM ecx, MI_1
    sub esi, ecx
    mov edx, [rip + sp_rect + 8]
    COLOR r8d, T_BORDER
    call gfx_fill
    xor eax, eax
    EPILOGUE

# wheel(): the wheel over the body scrolls it (sp_follow ends while it is not at the end)
wheel:
    PROLOGUE
    mov edi, [rip + sp_rect]
    mov esi, [rip + g_bodyy]
    mov edx, [rip + sp_rect + 8]
    mov ecx, [rip + g_bodyh]
    call ui_in
    test eax, eax
    jz 9f
    mov eax, [rip + g_scroll_y]
    test eax, eax
    jz 9f
    add eax, [rip + sp_scroll]
    call set_scroll
    mov dword ptr [rip + g_scroll_y], 0
    mov dword ptr [rip + sp_follow], 0
    mov eax, [rip + sp_scroll]
    cmp eax, [rip + sp_max]
    jl 9f
    mov dword ptr [rip + sp_follow], 1
9:  EPILOGUE

# set_scroll(eax)
set_scroll:
    cmp eax, [rip + sp_max]
    jle 1f
    mov eax, [rip + sp_max]
1:  test eax, eax
    jns 2f
    xor eax, eax
2:  mov [rip + sp_scroll], eax
    ret

# ---- the side question ----

# sq_list(AS*): slist = its exchanges in order (made again when the exchanges or the conversation changed)
sq_list:
    PROLOGUE
    mov rbx, rdi
    cmp [rip + slist_as], rbx
    jne 1f
    mov rax, [rip + sq_gen]
    cmp rax, [rip + slist_gen]
    je 9f
1:  mov [rip + slist_as], rbx
    mov rax, [rip + sq_gen]
    mov [rip + slist_gen], rax
    mov qword ptr [rip + slist + VEC_len], 0
    test rbx, rbx
    jz 9f
    mov rdi, rbx
    call sid_of
    mov r14, rax
    mov r15, rdx
    xor r12d, r12d
2:  cmp r12, [rip + sqs + VEC_len]
    jae 9f
    mov rax, [rip + sqs + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    mov rdi, [r13 + SQX_sid]
    mov rsi, r14
    mov rdx, r15
    call sid_is
    test eax, eax
    jz 2b
    lea rdi, [rip + slist]
    mov esi, 8
    call vec_push
    mov [rax], r13
    jmp 2b
9:  EPILOGUE

# sq_count(AS* or 0) -> eax its exchanges
sq_count:
    PROLOGUE
    call sq_list
    mov rax, [rip + slist + VEC_len]
    EPILOGUE

# sq_clear(AS*): its exchanges go ("Clear side questions from this editor"); an answer still to come is
#   ignored
sq_clear:
    PROLOGUE
    test rdi, rdi
    jz 9f
    call sid_of
    mov r14, rax
    mov r15, rdx
    xor ebx, ebx
1:  cmp rbx, [rip + sqs + VEC_len]
    jae 8f
    mov rax, [rip + sqs + VEC_ptr]
    mov r12, [rax + rbx*8]
    mov rdi, [r12 + SQX_sid]
    mov rsi, r14
    mov rdx, r15
    call sid_is
    test eax, eax
    jz 2f
    mov rdi, r12
    call sq_free
    lea rdi, [rip + sqs]
    mov rsi, rbx
    call vec_del
    inc qword ptr [rip + sq_gen]
    jmp 1b
2:  inc rbx
    jmp 1b
8:  mov dword ptr [rip + sp_scroll], 0
    mov dword ptr [rip + g_dirty], 1
    call st_save
9:  EPILOGUE

# sq_trim(sid ptr, len): the conversation keeps SQ_KEEP finished exchanges at most (SQ_MAX in all), the
#   oldest go first
sq_trim:
    PROLOGUE
    mov r14, rdi
    mov r15, rsi
1:  xor ebx, ebx                # count the finished ones and the first of them
    xor r13d, r13d
    mov r12, -1
2:  cmp rbx, [rip + sqs + VEC_len]
    jae 4f
    mov rax, [rip + sqs + VEC_ptr]
    mov rax, [rax + rbx*8]
    cmp dword ptr [rax + SQX_state], SQS_DONE
    jb 3f
    mov rdi, [rax + SQX_sid]
    mov rsi, r14
    mov rdx, r15
    call sid_is
    test eax, eax
    jz 3f
    inc r13d
    cmp r12, -1
    jne 3f
    mov r12, rbx
3:  inc rbx
    jmp 2b
4:  cmp r13d, SQ_KEEP
    jbe 9f
    mov rax, [rip + sqs + VEC_ptr]
    mov rdi, [rax + r12*8]
    call sq_free
    lea rdi, [rip + sqs]
    mov rsi, r12
    call vec_del
    inc qword ptr [rip + sq_gen]
    jmp 1b
9:  EPILOGUE

# FN agside_ask(AS*, ptr, len) -> eax 1: a side question of that conversation: an exchange, then it goes to
#   the driver now or once its program is ready
FN agside_ask
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor eax, eax
    test rbx, rbx
    jz 9f
    call st_need
1:  test r13, r13               # without its blanks around
    jz 2f
    cmp byte ptr [r12 + r13 - 1], ' '
    ja 2f
    dec r13
    jmp 1b
2:  test r13, r13
    jz 8f
    cmp byte ptr [r12], ' '
    ja 3f
    inc r12
    dec r13
    jmp 2b
3:  mov edi, SQX_SIZE
    call mem_alloc
    mov r14, rax
    mov [r14 + SQX_as], rbx
    mov rdi, rbx
    call sid_of
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [r14 + SQX_sid], rax
    mov rdi, r12
    mov rsi, r13
    mov edx, Q_MAX
    call dup_cut
    mov [r14 + SQX_q], rax
    mov [r14 + SQX_qlen], rdx
    lea rdi, [rip + sqs]
    mov esi, 8
    call vec_push
    mov [rax], r14
    inc qword ptr [rip + sq_gen]
    mov rdi, [r14 + SQX_sid]
    call strlen
    mov rdi, [r14 + SQX_sid]
    mov rsi, rax
    call sq_trim
    mov dword ptr [rip + sp_follow], 1
    mov dword ptr [rip + g_dirty], 1
    mov rdi, r14
    call sq_send
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# sq_send(SQX*): to the driver when its program is up, else the program starts (agside_ready sends it)
sq_send:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + SQX_as]
    call agent_live
    test rax, rax
    jz 7f
    mov r12, rax
    mov [rbx + SQX_al], rax
    cmp dword ptr [r12 + AL_cn + CN_state], CN_UP
    jne 2f
    mov eax, [r12 + AL_state]
    cmp eax, ALS_READY
    je 1f
    cmp eax, ALS_WORKING
    je 1f
    cmp eax, ALS_WAITING
    jne 2f
1:  mov rdi, rbx
    mov rsi, r12
    call sq_write
    EPILOGUE
2:  mov dword ptr [rbx + SQX_state], SQS_UNSENT
    mov rdi, [rbx + SQX_as]
    call agent_run
    mov rdi, [rbx + SQX_as]     # (the record agent_run started, or the one that is starting)
    call agent_live_get
    mov [rbx + SQX_al], rax
    EPILOGUE
7:  mov rdi, rbx                # no driver of its own keeps this conversation
    mov esi, SQS_ERROR
    lea rdx, [rip + .Le_nodrv]
    call sq_set_c
    EPILOGUE

# sq_write(SQX*, AL*): the question through DRV_action ACT_SIDEQ (pending: its request), or its error
sq_write:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov [rbx + SQX_al], r12
    mov [rip + sq_cur], rbx
    mov rdi, r12
    mov esi, ACT_SIDEQ
    mov rdx, [rbx + SQX_q]
    mov rcx, [rbx + SQX_qlen]
    mov rax, [r12 + AL_drv]
    call [rax + DRV_action]
    mov qword ptr [rip + sq_cur], 0
    test eax, eax
    jz 1f
    mov [rbx + SQX_req], eax
    mov dword ptr [rbx + SQX_state], SQS_PENDING
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
1:  mov rdi, rbx
    mov esi, SQS_ERROR
    lea rdx, [rip + .Le_unsent]
    call sq_set_c
    EPILOGUE

# sq_set(SQX*, state, ptr, len): its state and text (copied); the file when it is finished
sq_set:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov [rbx + SQX_state], r12d
    mov dword ptr [rbx + SQX_req], 0
    mov rdi, [rbx + SQX_a]
    call mem_free
    mov qword ptr [rbx + SQX_a], 0
    mov qword ptr [rbx + SQX_alen], 0
    mov rdi, [rbx + SQX_md]
    test rdi, rdi
    jz 1f
    call md_free
    mov qword ptr [rbx + SQX_md], 0
1:  test r13, r13
    jz 2f
    mov rdi, r13
    mov rsi, r14
    mov edx, A_MAX
    call dup_cut
    mov [rbx + SQX_a], rax
    mov [rbx + SQX_alen], rdx
2:  mov dword ptr [rip + g_dirty], 1
    cmp r12d, SQS_DONE
    jb 9f
    call st_save
9:  EPILOGUE

# sq_set_c(SQX*, state, cstr)
sq_set_c:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov rcx, rax
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r13
    call sq_set
    EPILOGUE

# FN agside_history(AL*) -> rax ptr, rdx len: the finished answers of the conversation of the question being
#   sent, before it, as [{"question":Q,"response":A},...] (the CLI's own shape: question and response
#   strings); rax 0 when there are none
FN agside_history
    PROLOGUE
    mov r15, [rip + sq_cur]
    test r15, r15
    jz 8f
    lea rdi, [rip + hsb]
    call jw_begin
    lea rdi, [rip + hsb]
    call jw_arr
    xor r13d, r13d              # entries
    xor ebx, ebx
1:  cmp rbx, [rip + sqs + VEC_len]
    jae 4f
    mov rax, [rip + sqs + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    cmp r12, r15
    je 4f                       # (only those before it)
    cmp dword ptr [r12 + SQX_state], SQS_DONE
    jne 1b
    mov rdi, [r12 + SQX_sid]
    mov rsi, [r15 + SQX_sid]
    call strcmp_eq
    test eax, eax
    jz 1b
    inc r13d
    lea rdi, [rip + hsb]
    call jw_obj
    lea rdi, [rip + hsb]
    lea rsi, [rip + .Lk_question]
    call jw_key
    lea rdi, [rip + hsb]
    mov rsi, [r12 + SQX_q]
    mov rdx, [r12 + SQX_qlen]
    call jw_str
    lea rdi, [rip + hsb]
    lea rsi, [rip + .Lk_response]
    call jw_key
    lea rdi, [rip + hsb]
    mov rsi, [r12 + SQX_a]
    mov rdx, [r12 + SQX_alen]
    call jw_str
    lea rdi, [rip + hsb]
    call jw_end_obj
    jmp 1b
4:  test r13d, r13d
    jz 8f
    lea rdi, [rip + hsb]
    call jw_end_arr
    mov rax, [rip + hsb + SB_ptr]
    mov rdx, [rip + hsb + SB_len]
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# FN agside_ready(AL*): its program is ready: the side questions that waited for it go
FN agside_ready
    PROLOGUE
    mov r13, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + sqs + VEC_len]
    jae 9f
    mov rax, [rip + sqs + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    cmp dword ptr [r12 + SQX_state], SQS_UNSENT
    jne 1b
    mov rax, [r12 + SQX_as]
    test rax, rax
    jz 1b
    cmp rax, [r13 + AL_as]
    jne 1b
    mov rdi, r12
    mov rsi, r13
    call sq_write
    jmp 1b
9:  EPILOGUE

# FN agside_ended(AL*): its program ended (OFF or FAILED): what waited for it is cancelled (rhun ended it)
#   or fails ("Failed to get an answer: " and the start's report, or "NAME ended before it answered.")
FN agside_ended
    PROLOGUE
    mov r13, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + sqs + VEC_len]
    jae 9f
    mov rax, [rip + sqs + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    cmp dword ptr [r12 + SQX_state], SQS_PENDING
    ja 1b
    cmp [r12 + SQX_al], r13
    je 2f
    mov rax, [r12 + SQX_as]     # (an unsent one's record was made by its start)
    test rax, rax
    jz 1b
    cmp rax, [r13 + AL_as]
    jne 1b
    cmp dword ptr [r12 + SQX_state], SQS_UNSENT
    jne 1b
2:  test dword ptr [r13 + AL_flags], ALF_ENDING
    jz 3f
    mov rdi, r12
    mov esi, SQS_CANCELLED
    xor edx, edx
    xor ecx, ecx
    call sq_set
    jmp 1b
3:  lea rdi, [rip + tsb]
    call sb_clear
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Le_failed]
    call sb_push_cstr
    mov rdx, [r13 + AL_report + SB_len]
    test rdx, rdx
    jz 4f
    lea rdi, [rip + tsb]
    mov rsi, [r13 + AL_report + SB_ptr]
    call sb_push
    jmp 5f
4:  mov rax, [r13 + AL_drv]
    lea rsi, [rip + .Le_agent]
    test rax, rax
    jz 41f
    mov rsi, [rax + DRV_name]
41: lea rdi, [rip + tsb]
    call sb_push_cstr
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Le_ended]
    call sb_push_cstr
5:  mov rdi, r12
    mov esi, SQS_ERROR
    mov rdx, [rip + tsb + SB_ptr]
    mov rcx, [rip + tsb + SB_len]
    call sq_set
    jmp 1b
9:  EPILOGUE

# FN agside_gone(ptr): an AS or an AL is freed: what waited for it is cancelled; nothing points at it
FN agside_gone
    PROLOGUE
    mov r13, rdi
    test rdi, rdi
    jz 9f
    xor ebx, ebx
1:  cmp rbx, [rip + sqs + VEC_len]
    jae 8f
    mov rax, [rip + sqs + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    xor r14d, r14d
    cmp [r12 + SQX_as], r13
    jne 2f
    mov qword ptr [r12 + SQX_as], 0
    inc r14d
2:  cmp [r12 + SQX_al], r13
    jne 3f
    mov qword ptr [r12 + SQX_al], 0
    inc r14d
3:  test r14d, r14d
    jz 1b
    cmp dword ptr [r12 + SQX_state], SQS_PENDING
    ja 1b
    mov rdi, r12
    mov esi, SQS_CANCELLED
    xor edx, edx
    xor ecx, ecx
    call sq_set
    jmp 1b
8:  cmp [rip + slist_as], r13
    jne 6f
    mov qword ptr [rip + slist_as], 0
6:  cmp [rip + blist_as], r13
    jne 7f
    call forget
7:  mov rdi, r13                # the agent map of it closes (agentmap.s)
    call agmap_gone
9:  EPILOGUE

# FN agside_busy(AL*) -> eax 1 while a side question waits for that program (the idle stop waits). A leaf
FN agside_busy
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, [rip + sqs + VEC_len]
    jae 9f
    mov rdx, [rip + sqs + VEC_ptr]
    mov rdx, [rdx + rcx*8]
    inc rcx
    cmp dword ptr [rdx + SQX_state], SQS_PENDING
    ja 1b
    cmp [rdx + SQX_al], rdi
    jne 1b
    mov eax, 1
9:  ret

# FN ev_side_answer(AL*, n, ptr, len, kind SA_*): the answer to the driver's request n (its error's text;
#   SA_EMPTY: none). One nobody waits for any more is dropped
FN ev_side_answer
    PROLOGUE 16
    mov r13, rdi
    mov r14d, esi
    inc r14d
    mov [rsp], rdx
    mov r15, rcx
    mov [rsp + 8], r8
    xor ebx, ebx
1:  cmp rbx, [rip + sqs + VEC_len]
    jae 8f
    mov rax, [rip + sqs + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    cmp dword ptr [r12 + SQX_state], SQS_PENDING
    jne 1b
    cmp [r12 + SQX_al], r13
    jne 1b
    cmp [r12 + SQX_req], r14d
    jne 1b
    mov rax, [rsp + 8]
    cmp eax, SA_ERROR
    je 3f
    cmp eax, SA_EMPTY
    je 2f
    test r15, r15
    jz 2f
    mov rdi, r12
    mov esi, SQS_DONE
    mov rdx, [rsp]
    mov rcx, r15
    call sq_set
    jmp 8f
2:  mov rdi, r12
    mov esi, SQS_EMPTY
    xor edx, edx
    xor ecx, ecx
    call sq_set
    jmp 8f
3:  lea rdi, [rip + tsb]
    call sb_clear
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Le_failed]
    call sb_push_cstr
    lea rdi, [rip + tsb]
    mov rsi, [rsp]
    mov rdx, r15
    call sb_push
    mov rdi, r12
    mov esi, SQS_ERROR
    mov rdx, [rip + tsb + SB_ptr]
    mov rcx, [rip + tsb + SB_len]
    call sq_set
8:  EPILOGUE

# sq_h(SQX*, w) -> eax its height: the question in its bubble, then the answer (Markdown) or its state
sq_h:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, [rip + ag_fui]
    mov rsi, [rbx + SQX_q]
    mov rdx, [rbx + SQX_qlen]
    mov ecx, r12d
    sub ecx, [rip + g_pmt + 4*MI_16]
    call lines_of
    mov rcx, [rip + ag_fui]
    imul eax, [rcx + FACE_lineh]
    PM ecx, MI_8
    lea r13d, [rax + rcx*2]     # the bubble
    add r13d, [rip + g_pmt + 4*MI_6]
    cmp dword ptr [rbx + SQX_state], SQS_DONE
    jne 1f
    mov rdi, rbx
    call sq_md
    mov rdi, rax
    mov esi, r12d
    call md_layout
    add r13d, eax
    jmp 2f
1:  mov rdi, [rip + ag_fui]
    mov rsi, [rbx + SQX_a]
    mov rdx, [rbx + SQX_alen]
    test rsi, rsi
    jnz 11f
    lea rsi, [rip + .Ls_wait]
    call cslen
11: mov ecx, r12d
    call lines_of
    mov rcx, [rip + ag_fui]
    imul eax, [rcx + FACE_lineh]
    add r13d, eax
2:  add r13d, [rip + g_pmt + 4*MI_16]
    mov [rbx + SQX_h], r13d
    mov eax, r13d
    EPILOGUE

# sq_md(SQX*) -> rax its answer's Markdown at the panel's size
sq_md:
    PROLOGUE
    mov rbx, rdi
    mov rax, [rbx + SQX_md]
    test rax, rax
    jnz 1f
    mov rdi, [rbx + SQX_a]
    mov rsi, [rbx + SQX_alen]
    call md_new
    mov [rbx + SQX_md], rax
    mov rdi, rax
    mov esi, 1
    call md_set_compact
    mov dword ptr [rbx + SQX_mdpx], -1
1:  call panel_px
    cmp eax, [rbx + SQX_mdpx]
    je 2f
    mov [rbx + SQX_mdpx], eax
    mov rdi, [rbx + SQX_md]
    mov esi, eax
    call md_set_size
2:  mov rax, [rbx + SQX_md]
    EPILOGUE

# side_body(AS*): the exchanges of the conversation, the latest at the bottom (followed while sp_follow)
side_body:
    PROLOGUE 48
    call sq_list
    call body_w
    mov [rsp + 16], eax         # w
    xor r13d, r13d              # the content's height
    xor ebx, ebx
1:  cmp rbx, [rip + slist + VEC_len]
    jae 2f
    mov rax, [rip + slist + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    mov rdi, r12
    mov esi, [rsp + 16]
    call sq_h
    add r13d, eax
    jmp 1b
2:  PM eax, MI_12
    add r13d, eax
    mov [rip + g_content], r13d
    mov eax, r13d
    sub eax, [rip + g_bodyh]
    jns 21f
    xor eax, eax
21: mov [rip + sp_max], eax
    cmp dword ptr [rip + sp_follow], 0
    je 22f
    mov [rip + sp_scroll], eax
22: mov eax, [rip + sp_scroll]
    call set_scroll
    call wheel
    mov edi, [rip + sp_rect]
    mov esi, [rip + g_bodyy]
    mov edx, [rip + sp_rect + 8]
    mov ecx, [rip + g_bodyh]
    call gfx_clip_push
    cmp r13d, [rip + g_pmt + 4*MI_12]
    jg 3f
    lea rsi, [rip + .Ls_hint]   # none yet: what it is for
    call cslen
    mov r8, rsi
    mov r9, rdx
    COLOR eax, T_MUTED
    push rax
    push rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rip + sp_rect]
    add esi, [rip + g_pad]
    mov edx, [rip + g_bodyy]
    add edx, [rip + g_pmt + 4*MI_12]
    mov ecx, [rsp + 16 + 16]
    call draw_wrap
    add rsp, 16
    jmp 8f
3:  mov eax, [rip + g_bodyy]
    add eax, [rip + g_pmt + 4*MI_12]
    sub eax, [rip + sp_scroll]
    mov [rsp + 20], eax         # the next exchange's top
    xor ebx, ebx
    mov dword ptr [rsp + 24], 0 # slots of Markdown
4:  cmp rbx, [rip + slist + VEC_len]
    jae 8f
    mov rax, [rip + slist + VEC_ptr]
    mov r12, [rax + rbx*8]
    inc rbx
    mov eax, [rsp + 20]
    mov ecx, [r12 + SQX_h]
    add [rsp + 20], ecx
    lea edx, [rax + rcx]
    cmp edx, [rip + g_bodyy]
    jle 4b                      # above the view
    mov edx, [rip + g_bodyy]
    add edx, [rip + g_bodyh]
    cmp eax, edx
    jge 8f                      # below it
    mov rdi, r12
    mov esi, eax
    mov edx, [rsp + 16]
    mov ecx, [rsp + 24]
    call sq_draw
    inc dword ptr [rsp + 24]
    jmp 4b
8:  call gfx_clip_pop
    EPILOGUE

# sq_draw(SQX*, y, w, slot): one exchange
sq_draw:
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov [rsp], ecx
    mov r14d, [rip + sp_rect]
    add r14d, [rip + g_pad]     # x
    mov rdi, [rip + ag_fui]     # the question in a bubble
    mov rsi, [rbx + SQX_q]
    mov rdx, [rbx + SQX_qlen]
    mov ecx, r13d
    sub ecx, [rip + g_pmt + 4*MI_16]
    call lines_of
    mov rcx, [rip + ag_fui]
    imul eax, [rcx + FACE_lineh]
    PM ecx, MI_8
    lea r15d, [rax + rcx*2]
    mov edi, r14d
    mov esi, r12d
    mov edx, r13d
    mov ecx, r15d
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
    COLOR eax, T_FG
    push rax
    push rax
    mov rdi, [rip + ag_fui]
    mov esi, r14d
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, r12d
    add edx, [rip + g_pmt + 4*MI_8]
    mov ecx, r13d
    sub ecx, [rip + g_pmt + 4*MI_16]
    mov r8, [rbx + SQX_q]
    mov r9, [rbx + SQX_qlen]
    call draw_wrap
    add rsp, 16
    add r12d, r15d
    add r12d, [rip + g_pmt + 4*MI_6]
    cmp dword ptr [rbx + SQX_state], SQS_DONE
    jne 2f
    mov rdi, rbx
    call sq_md
    mov r15, rax
    mov rdi, rax
    mov esi, r13d
    call md_layout
    mov r8d, eax
    mov eax, [rsp]
    and eax, 15
    shl eax, 12
    add eax, ID_SIDE_MD
    push rax
    push rax
    mov rdi, r15
    mov esi, r14d
    mov edx, r12d
    mov ecx, r13d
    xor r9d, r9d
    call md_draw
    add rsp, 16
    cmp eax, -1
    je 9f
    mov rdi, r15
    mov esi, eax
    call md_open_link
    jmp 9f
2:  mov rsi, [rbx + SQX_a]      # its state
    mov rdx, [rbx + SQX_alen]
    COLOR eax, T_ERROR
    cmp dword ptr [rbx + SQX_state], SQS_ERROR
    je 4f
    COLOR eax, T_MUTED
    lea rsi, [rip + .Ls_wait]
    call cslen
    cmp dword ptr [rbx + SQX_state], SQS_PENDING
    jbe 4f
    lea rsi, [rip + .Ls_cancelled]
    call cslen
    cmp dword ptr [rbx + SQX_state], SQS_CANCELLED
    je 4f
    lea rsi, [rip + .Ls_empty]
    call cslen
4:  mov r8, rsi
    mov r9, rdx
    push rax
    push rax
    mov rdi, [rip + ag_fui]
    mov esi, r14d
    mov edx, r12d
    mov ecx, r13d
    call draw_wrap
    add rsp, 16
9:  EPILOGUE

# side_foot(AS*): the field ("Ask a side question") and Send ("Send side question"); Enter sends
side_foot:
    PROLOGUE
    mov rbx, rdi
    mov edi, [rip + sp_rect]
    mov esi, [rip + g_fy]
    PM ecx, MI_8
    sub esi, ecx
    mov edx, [rip + sp_rect + 8]
    PM ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    xor r9d, r9d
    cmp dword ptr [rip + sp_keys], 0
    je 1f
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    jne 1f
    cmp dword ptr [rip + g_block], 0
    jne 1f
    mov r9d, 1
1:  lea rdi, [rip + sp_tf]
    mov esi, [rip + g_fx]
    mov edx, [rip + g_fy]
    mov ecx, [rip + g_fw]
    mov r8d, [rip + g_fh]
    lea rax, [rip + .Lph]
    push rax
    push rax
    call ui_textarea
    add rsp, 16
    test eax, UB_PRESS
    jz 2f
    mov dword ptr [rip + sp_keys], 1
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
2:  cmp dword ptr [rip + g_sicon], 0
    je 21f
    mov edi, ID_AGSIDE + SID_SEND   # narrow: an arrow ("Send side question")
    mov esi, [rip + g_sx]
    mov edx, [rip + g_fh]
    sub edx, [rip + g_sw]
    sar edx, 1
    add edx, [rip + g_fy]
    mov ecx, [rip + g_sw]
    mov r8d, ecx
    mov r9d, IC_ARROW_UP
    call ag_icon_btn
    mov r12d, eax
    jmp 8f
21: mov edi, ID_AGSIDE + SID_SEND
    mov esi, [rip + g_sx]
    mov edx, [rip + g_fy]
    mov ecx, [rip + g_sw]
    mov r8d, [rip + g_fh]
    call ui_btn
    mov r12d, eax
    COLOR r9d, T_ACCENT
    test r12d, UB_HOVER
    jz 3f
    COLOR r9d, T_ACTIVE
3:  mov edi, [rip + g_sx]
    mov esi, [rip + g_fy]
    mov edx, [rip + g_sw]
    mov ecx, [rip + g_fh]
    PM r8d, MI_RADIUS
    call gfx_round_rect
    mov rdi, [rip + ag_fui]
    mov esi, [rip + g_sx]
    mov edx, [rip + g_fy]
    mov ecx, [rip + g_sw]
    mov r8d, [rip + g_fh]
    lea r9, [rip + .Lsend]
    COLOR eax, T_ACCENT_FG
    push rax
    push rax
    call ui_text_center
    add rsp, 16
8:  test r12d, UB_CLICK
    jz 9f
    mov rdi, rbx
    call side_send
9:  EPILOGUE

# side_send(AS*): the field's text asked; the field empties
side_send:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + sp_tf]
    call tf_text
    test rdx, rdx
    jz 9f
    mov r12, rax
    mov r13, rdx
    lea rdi, [rip + tsb]
    call sb_clear
    lea rdi, [rip + tsb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + sp_tf]
    call tf_clear
    mov rdi, rbx
    mov rsi, [rip + tsb + SB_ptr]
    mov rdx, [rip + tsb + SB_len]
    call agside_ask
9:  EPILOGUE

# ---- bookmarks ----

# book_list(AS*): blist = its bookmarks (made again when the bookmarks or the conversation changed)
book_list:
    PROLOGUE
    mov rbx, rdi
    cmp [rip + blist_as], rbx
    jne 1f
    mov rax, [rip + bm_gen]
    cmp rax, [rip + blist_gen]
    je 9f
1:  mov [rip + blist_as], rbx
    mov rax, [rip + bm_gen]
    mov [rip + blist_gen], rax
    mov qword ptr [rip + blist + VEC_len], 0
    mov rdi, rbx
    call sid_of
    mov r14, rax
    mov r15, rdx
    test rdx, rdx
    jz 9f
    xor r12d, r12d
2:  cmp r12, [rip + bms + VEC_len]
    jae 9f
    mov rax, [rip + bms + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    mov rdi, [r13 + BMK_sid]
    mov rsi, r14
    mov rdx, r15
    call sid_is
    test eax, eax
    jz 2b
    lea rdi, [rip + blist]
    mov esi, 8
    call vec_push
    mov [rax], r13
    jmp 2b
9:  EPILOGUE

# find_bm(AS*, hash, len) -> rax its BMK* in blist, or 0
find_bm:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    call book_list
    xor ecx, ecx
1:  xor eax, eax
    cmp rcx, [rip + blist + VEC_len]
    jae 9f
    mov rax, [rip + blist + VEC_ptr]
    mov rax, [rax + rcx*8]
    inc rcx
    cmp [rax + BMK_hash], r12
    jne 1b
    cmp [rax + BMK_len], r13
    jne 1b
9:  EPILOGUE

# booked(AS*, AM*) -> eax 1 when the reply is bookmarked (the cache's entry for it, made when missing)
booked:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rax, r12
    shr rax, 4
    and eax, CACHE_N - 1
    imul eax, eax, CE_SIZE
    lea r13, [rip + cache]
    add r13, rax
    cmp [r13], r12
    jne 1f
    mov eax, [r12 + AM_rev]
    cmp [r13 + 8], eax
    jne 1f
    mov rax, [rip + bm_gen]
    cmp [r13 + 16], rax
    jne 1f
    cmp [r13 + 24], rbx
    jne 1f
    mov rax, [r12 + AM_len]
    cmp [r13 + 32], rax
    jne 1f
    mov rax, [r12 + AM_text]
    cmp [r13 + 40], rax
    jne 1f
    mov eax, [r13 + 12]
    EPILOGUE
1:  mov [r13], r12
    mov eax, [r12 + AM_rev]
    mov [r13 + 8], eax
    mov rax, [rip + bm_gen]
    mov [r13 + 16], rax
    mov [r13 + 24], rbx
    mov rax, [r12 + AM_len]
    mov [r13 + 32], rax
    mov rax, [r12 + AM_text]
    mov [r13 + 40], rax
    mov rdi, [r12 + AM_text]
    mov rsi, [r12 + AM_len]
    call hash_of
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [r12 + AM_len]
    call find_bm
    test rax, rax
    setnz al
    movzx eax, al
    mov [r13 + 12], eax
    EPILOGUE

# FN agbook_toggle(AS*, AM*): the reply bookmarked, or its bookmark removed
FN agbook_toggle
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz 9f
    call st_need
    mov rdi, rbx
    call sid_of
    test rdx, rdx
    jz 9f
    mov r14, rax
    mov r15, rdx
    mov rdi, [r12 + AM_text]
    mov rsi, [r12 + AM_len]
    call hash_of
    mov r13, rax
    mov rdi, rbx
    mov rsi, r13
    mov rdx, [r12 + AM_len]
    call find_bm
    test rax, rax
    jz 1f
    mov rdi, rax
    call bm_remove
    jmp 9f
1:  cmp qword ptr [rip + bms + VEC_len], BM_MAX
    jb 2f
    mov rax, [rip + bms + VEC_ptr]     # full: the oldest goes
    mov rdi, [rax]
    call bm_free
    lea rdi, [rip + bms]
    xor esi, esi
    call vec_del
2:  mov edi, BMK_SIZE
    call mem_alloc
    mov rbx, rax
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov [rbx + BMK_sid], rax
    mov [rbx + BMK_hash], r13
    mov rax, [r12 + AM_len]
    mov [rbx + BMK_len], rax
    mov rdi, [r12 + AM_text]
    mov rsi, [r12 + AM_len]
    mov edx, BM_TEXT_MAX
    call dup_cut
    mov [rbx + BMK_text], rax
    mov [rbx + BMK_tlen], rdx
    lea rdi, [rip + bms]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    inc qword ptr [rip + bm_gen]
    mov dword ptr [rip + g_dirty], 1
    call st_save
9:  EPILOGUE

# bm_remove(BMK*): it goes (the shown one: none is shown)
bm_remove:
    PROLOGUE
    mov rbx, rdi
    xor ecx, ecx
1:  cmp rcx, [rip + bms + VEC_len]
    jae 9f
    mov rax, [rip + bms + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 2f
    inc rcx
    jmp 1b
2:  lea rdi, [rip + bms]
    mov rsi, rcx
    call vec_del
    cmp [rip + md_for], rbx
    jne 3f
    mov rdi, [rip + md_book]
    call md_free
    mov qword ptr [rip + md_book], 0
    mov qword ptr [rip + md_for], 0
3:  cmp [rip + show_for], rbx
    jne 4f
    mov qword ptr [rip + show_for], 0
4:  mov rdi, rbx
    call bm_free
    mov dword ptr [rip + sp_sel], -1
    inc qword ptr [rip + bm_gen]
    mov dword ptr [rip + g_dirty], 1
    call st_save
9:  EPILOGUE

# bm_row(AS*, BMK*) -> eax the conversation's row that is that reply, -1 none (found again only when the
#   rows changed: a row kept is checked first)
bm_row:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + AS_msgs + VEC_len]
    cmp [rip + show_for], r12
    jne 1f
    cmp [rip + show_n], rax
    jne 1f
    mov eax, [rip + show_row]
    EPILOGUE
1:  mov [rip + show_for], r12
    mov [rip + show_n], rax
    movsxd r13, dword ptr [rip + show_row]
    test r13, r13
    js 2f
    cmp r13, rax
    jae 2f
    mov rdi, r13
    call try_row
    test eax, eax
    jnz 8f
2:  xor r13d, r13d
3:  cmp r13, [rbx + AS_msgs + VEC_len]
    jae 7f
    mov rdi, r13
    call try_row
    test eax, eax
    jnz 8f
    inc r13
    jmp 3b
7:  mov r13, -1
8:  mov [rip + show_row], r13d
    mov eax, r13d
    EPILOGUE

# try_row(i) -> eax 1 when row i of rbx's conversation is r12's reply (inside bm_row)
try_row:
    push rbx
    imul rax, rdi, AM_SIZE
    add rax, [rbx + AS_msgs + VEC_ptr]
    mov rbx, rax
    xor eax, eax
    cmp dword ptr [rbx + AM_role], R_ASSIST
    jne 9f
    mov rcx, [rbx + AM_len]
    cmp rcx, [r12 + BMK_len]
    jne 9f
    mov rdi, [rbx + AM_text]
    mov rsi, rcx
    call hash_of
    cmp rax, [r12 + BMK_hash]
    sete al
    movzx eax, al
9:  pop rbx
    ret

# FN agbook_btn(AM*, left, right, y, rowh) -> eax the width it took: a finished reply's bookmark button at
#   the right of its label line (y its top, MI_20 tall): filled while bookmarked ("Remove bookmark"), else
#   an outline only while the pointer is over the reply ("Bookmark response"); a click toggles it
FN agbook_btn
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    xor eax, eax
    cmp dword ptr [rbx + AM_role], R_ASSIST
    jne 9f
    test dword ptr [rbx + AM_flags], AMF_LIVE | AMF_QUEUED
    jnz 9f
    cmp qword ptr [rbx + AM_len], 0
    je 9f
    call viewed
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rax
    call sid_of
    test rdx, rdx
    jz 9f
    call st_need
    mov rdi, r12
    mov rsi, rbx
    call booked
    mov r13d, eax
    test r13d, r13d
    jnz 1f
    mov edi, [rsp]              # not bookmarked: shown while the pointer is over the reply
    mov esi, [rsp + 8]
    mov edx, [rsp + 4]
    sub edx, edi
    mov ecx, [rsp + 12]
    call ui_in
    test eax, eax
    jz 9f
1:  PM r14d, MI_16
    mov r15d, [rsp + 4]
    sub r15d, r14d              # its x
    mov rax, rbx                # its id: the row's
    sub rax, [r12 + AS_msgs + VEC_ptr]
    xor edx, edx
    mov ecx, AM_SIZE
    div rcx
    and eax, 0x7f
    lea edi, [rax + ID_AGSIDE + SID_REPLY]
    mov esi, r15d
    mov edx, [rsp + 8]
    PM ecx, MI_20
    sub ecx, r14d
    sar ecx, 1
    add edx, ecx
    mov [rsp + 16], edx         # its top
    mov ecx, r14d
    mov r8d, r14d
    call ui_btn
    mov [rsp + 20], eax
    COLOR r9d, T_ACCENT
    test r13d, r13d
    jnz 2f
    COLOR r9d, T_MUTED
    test dword ptr [rsp + 20], UB_HOVER
    jz 2f
    COLOR r9d, T_FG
2:  mov edi, r15d
    mov esi, [rsp + 16]
    mov edx, r14d
    mov ecx, r13d
    call glyph
    test dword ptr [rsp + 20], UB_CLICK
    jz 3f
    mov rdi, r12
    mov rsi, rbx
    call agbook_toggle
3:  mov eax, r14d
    add eax, [rip + g_pmt + 4*MI_6]
9:  EPILOGUE

# glyph(x, y, size, filled, argb r9d): a bookmark (a ribbon with a notch at its foot), filled or outlined
glyph:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    mov [rsp + 16], r9d
    mov eax, edx                # the ribbon: 5/8 of the size wide, centred
    imul eax, eax, 5
    shr eax, 3
    cmp eax, 3
    jge 1f
    mov eax, 3
1:  mov [rsp + 20], eax         # w
    mov ecx, edx
    sub ecx, eax
    shr ecx, 1
    add [rsp], ecx              # x
    mov eax, edx
    shr eax, 3
    add [rsp + 4], eax          # y: an eighth down
    mov eax, edx
    imul eax, eax, 3
    shr eax, 2
    mov [rsp + 24], eax         # h: three quarters
    shr eax, 2
    cmp eax, 1
    jge 2f
    mov eax, 1
2:  mov [rsp + 28], eax         # the notch's depth
    PM r12d, MI_1               # the line's width
    xor ebx, ebx                # each pixel row: its two parts outside the notch
3:  cmp ebx, [rsp + 24]
    jge 9f
    mov eax, [rsp + 24]         # the notch's half width at this row (0 above it)
    sub eax, [rsp + 28]
    mov r13d, ebx
    sub r13d, eax
    js 31f
    mov eax, r13d
    imul eax, [rsp + 20]
    cdq
    mov ecx, [rsp + 28]
    shl ecx, 1
    idiv ecx
    mov r13d, eax
    jmp 32f
31: xor r13d, r13d
32: mov r14d, [rsp + 20]        # the half
    shr r14d, 1
    sub r14d, r13d              # each part's width
    jle 8f
    cmp dword ptr [rsp + 12], 0
    jne 5f
    cmp ebx, r12d               # outlined: the top, the sides, and the notch's edges
    jl 5f
    mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, ebx
    mov edx, r12d
    mov ecx, 1
    mov r8d, [rsp + 16]
    call gfx_fill
    mov edi, [rsp]
    add edi, [rsp + 20]
    sub edi, r12d
    mov esi, [rsp + 4]
    add esi, ebx
    mov edx, r12d
    mov ecx, 1
    mov r8d, [rsp + 16]
    call gfx_fill
    test r13d, r13d
    jz 8f
    mov edi, [rsp]
    add edi, r14d
    sub edi, r12d
    mov esi, [rsp + 4]
    add esi, ebx
    mov edx, r12d
    mov ecx, 1
    mov r8d, [rsp + 16]
    call gfx_fill
    mov edi, [rsp]
    add edi, [rsp + 20]
    sub edi, r14d
    mov esi, [rsp + 4]
    add esi, ebx
    mov edx, r12d
    mov ecx, 1
    mov r8d, [rsp + 16]
    call gfx_fill
    jmp 8f
5:  mov edi, [rsp]
    mov esi, [rsp + 4]
    add esi, ebx
    mov edx, r14d
    mov ecx, 1
    mov r8d, [rsp + 16]
    call gfx_fill
    mov edi, [rsp]
    add edi, [rsp + 20]
    sub edi, r14d
    mov esi, [rsp + 4]
    add esi, ebx
    mov edx, r14d
    mov ecx, 1
    mov r8d, [rsp + 16]
    call gfx_fill
    mov eax, [rsp + 20]         # an odd width's middle column, above the notch
    test eax, 1
    jz 8f
    test r13d, r13d
    jnz 8f
    mov edi, [rsp]
    shr eax, 1
    add edi, eax
    mov esi, [rsp + 4]
    add esi, ebx
    mov edx, 1
    mov ecx, 1
    mov r8d, [rsp + 16]
    call gfx_fill
8:  inc ebx
    jmp 3b
9:  EPILOGUE

# first_line(BMK*) -> rax ptr, rdx len: its text's first line that is not blank (heading marks left out)
first_line:
    mov rax, [rdi + BMK_text]
    mov rcx, [rdi + BMK_tlen]
    lea r8, [rax + rcx]
1:  cmp rax, r8                 # blanks, line ends and "#" first
    jae 3f
    movzx ecx, byte ptr [rax]
    cmp ecx, ' '
    jbe 2f
    cmp ecx, '#'
    jne 3f
2:  inc rax
    jmp 1b
3:  mov rdx, rax
4:  cmp rdx, r8
    jae 5f
    cmp byte ptr [rdx], 10
    je 5f
    inc rdx
    jmp 4b
5:  sub rdx, rax
    ret

# book_body(AS*): the conversation's bookmarks, one a row, the one picked shown under them
book_body:
    PROLOGUE 48
    mov rbx, rdi
    call book_list
    movsxd rax, dword ptr [rip + sp_sel]
    cmp rax, [rip + blist + VEC_len]
    jl 1f
    mov dword ptr [rip + sp_sel], -1
1:  call body_w
    mov [rsp], eax              # w
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    PM ecx, MI_6
    lea eax, [rax + rcx*2]
    mov [rsp + 4], eax          # a row's height
    mov rax, [rip + blist + VEC_len]
    imul eax, [rsp + 4]
    PM ecx, MI_8
    add eax, ecx
    mov [rsp + 8], eax          # the detail's top in the content
    call detail_h               # the detail's height (lays out the shown one)
    add eax, [rsp + 8]
    PM ecx, MI_12
    add eax, ecx
    mov [rip + g_content], eax
    sub eax, [rip + g_bodyh]
    jns 2f
    xor eax, eax
2:  mov [rip + sp_max], eax
    mov eax, [rip + sp_scroll]
    call set_scroll
    call wheel
    mov edi, [rip + sp_rect]
    mov esi, [rip + g_bodyy]
    mov edx, [rip + sp_rect + 8]
    mov ecx, [rip + g_bodyh]
    call gfx_clip_push
    mov eax, [rip + g_bodyy]
    sub eax, [rip + sp_scroll]
    mov [rsp + 12], eax         # the content's top on screen
    cmp qword ptr [rip + blist + VEC_len], 0
    jne 3f
    lea rsi, [rip + .Ls_none]   # none
    call cslen
    mov r8, rsi
    mov r9, rdx
    COLOR eax, T_MUTED
    push rax
    push rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rip + sp_rect]
    add esi, [rip + g_pad]
    mov edx, [rsp + 12 + 16]
    add edx, [rip + g_pmt + 4*MI_8]
    mov ecx, [rsp + 16]
    call draw_wrap
    add rsp, 16
    jmp 8f
3:  mov eax, [rip + sp_scroll]  # the rows in view
    xor edx, edx
    div dword ptr [rsp + 4]
    mov r12, rax                # the first
4:  cmp r12, [rip + blist + VEC_len]
    jae 6f
    mov eax, r12d
    imul eax, [rsp + 4]
    add eax, [rsp + 12]
    mov [rsp + 16], eax         # its top
    mov ecx, [rip + g_bodyy]
    add ecx, [rip + g_bodyh]
    cmp eax, ecx
    jge 6f
    mov rdi, rbx
    mov esi, r12d
    mov edx, eax
    mov ecx, [rsp + 4]
    call book_row
    inc r12
    jmp 4b
6:  mov edi, [rip + sp_rect]
    add edi, [rip + g_pad]
    mov esi, [rsp + 12]
    add esi, [rsp + 8]
    mov edx, [rsp]
    mov rcx, rbx
    call detail_draw
8:  call gfx_clip_pop
    EPILOGUE

# book_row(AS*, i, y, h): bookmark i's row: its first line; a click shows it
book_row:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    lea edi, [r12 + ID_AGSIDE + SID_ROW]
    cmp r12d, 0xff
    jbe 1f
    mov edi, ID_AGSIDE + SID_ROW + 0xff
1:  mov esi, [rip + sp_rect]
    mov edx, r13d
    mov ecx, [rip + sp_rect + 8]
    mov r8d, r14d
    call ui_btn
    mov r15d, eax
    COLOR r8d, T_SELECTION
    cmp r12d, [rip + sp_sel]
    je 2f
    COLOR r8d, T_HOVER
    test r15d, UB_HOVER
    jz 3f
2:  mov edi, [rip + sp_rect]
    mov esi, r13d
    mov edx, [rip + sp_rect + 8]
    mov ecx, r14d
    call gfx_fill
3:  mov rax, [rip + blist + VEC_ptr]
    mov rdi, [rax + r12*8]
    call first_line
    mov r8, rax
    mov r9, rdx
    mov rdi, [rip + ag_fui]
    mov esi, [rip + sp_rect]
    add esi, [rip + g_pad]
    mov edx, r13d
    mov ecx, r14d
    COLOR r10d, T_FG
    call body_w
    mov r11d, eax
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    test r15d, UB_CLICK
    jz 9f
    mov [rip + sp_sel], r12d
    mov dword ptr [rip + sp_keys], 1
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# shown_bm() -> rax the bookmark shown (BMK*), 0 none
shown_bm:
    xor eax, eax
    movsxd rcx, dword ptr [rip + sp_sel]
    test rcx, rcx
    js 1f
    cmp rcx, [rip + blist + VEC_len]
    jae 1f
    mov rax, [rip + blist + VEC_ptr]
    mov rax, [rax + rcx*8]
1:  ret

# book_md(BMK*) -> rax its Markdown at the panel's size (one kept, for the bookmark shown)
book_md:
    PROLOGUE
    mov rbx, rdi
    cmp [rip + md_for], rbx
    je 1f
    mov rdi, [rip + md_book]
    test rdi, rdi
    jz 2f
    call md_free
2:  mov rdi, [rbx + BMK_text]
    mov rsi, [rbx + BMK_tlen]
    call md_new
    mov [rip + md_book], rax
    mov [rip + md_for], rbx
    mov rdi, rax
    mov esi, 1
    call md_set_compact
    mov dword ptr [rip + md_px], -1
1:  call panel_px
    cmp eax, [rip + md_px]
    je 3f
    mov [rip + md_px], eax
    mov rdi, [rip + md_book]
    mov esi, eax
    call md_set_size
3:  mov rax, [rip + md_book]
    EPILOGUE

# links_two() -> eax 1 when the links do not fit on one line (the longer first link, the gap, Remove)
links_two:
    PROLOGUE
    lea rsi, [rip + .Ls_gone]
    call cslen
    mov rdi, [rip + ag_fsmall]
    call text_width
    mov ebx, eax
    lea rsi, [rip + .Ls_remove]
    call cslen
    mov rdi, [rip + ag_fsmall]
    call text_width
    add ebx, eax
    add ebx, [rip + g_pmt + 4*MI_12]
    call body_w
    cmp ebx, eax
    setg al
    movzx eax, al
    EPILOGUE

# detail_h() -> eax the height under the rows: the hint, or the links (a line or two) and the shown one's text
detail_h:
    PROLOGUE
    mov rax, [rip + ag_fsmall]
    mov ebx, [rax + FACE_lineh]
    add ebx, [rip + g_pmt + 4*MI_8]
    call links_two
    test eax, eax
    jz 1f
    mov rax, [rip + ag_fsmall]
    add ebx, [rax + FACE_lineh]
1:  call shown_bm
    test rax, rax
    jz 8f
    mov rdi, rax
    call book_md
    mov rdi, rax
    call body_w
    mov esi, eax
    call md_layout
    add ebx, eax
    add ebx, [rip + g_pmt + 4*MI_8]
8:  mov eax, ebx
    EPILOGUE

# detail_draw(x, y, w, AS* rcx): under the rows: "Click a bookmark to show it here.", or the links line
#   ("Show in conversation" | "No longer shown in the conversation" · "Remove bookmark") and its text
detail_draw:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov rbx, rcx
    call shown_bm
    mov r12, rax
    test rax, rax
    jnz 1f
    cmp qword ptr [rip + blist + VEC_len], 0
    je 9f
    lea rsi, [rip + .Ls_pick]
    call cslen
    mov r8, rsi
    mov r9, rdx
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rip + g_pmt + 4*MI_20]
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 8]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    EPILOGUE
1:  mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + 12], eax         # the links' height
    mov [rip + link_h], eax
    mov eax, [rsp + 4]
    mov [rip + link_y], eax
    call links_two
    mov [rsp + 16], eax
    test eax, eax
    jz 11f
    mov rax, [rip + ag_fsmall]  # two lines: Remove under the first
    mov eax, [rax + FACE_lineh]
    mov [rip + link_h], eax
    add [rsp + 12], eax
11: mov rdi, rbx
    mov rsi, r12
    call bm_row
    mov r13d, eax
    mov r14d, [rsp]             # x
    test r13d, r13d
    js 2f
    lea rsi, [rip + .Ls_show]
    call cslen
    mov edi, ID_AGSIDE + SID_SHOW
    mov ecx, r14d
    call link
    add r14d, eax
    test edx, UB_CLICK
    jz 3f
    mov rdi, rbx
    mov esi, r13d
    call show_in
    jmp 3f
2:  lea rsi, [rip + .Ls_gone]   # gone from the conversation
    call cslen
    mov rdi, [rip + ag_fsmall]
    call text_width
    mov r15d, eax
    lea rsi, [rip + .Ls_gone]
    call cslen
    mov r8, rsi
    mov r9, rdx
    mov rdi, [rip + ag_fsmall]
    mov esi, r14d
    mov edx, [rip + link_y]
    mov ecx, [rip + link_h]
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 8]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    add r14d, r15d
3:  add r14d, [rip + g_pmt + 4*MI_12]
    cmp dword ptr [rsp + 16], 0
    je 31f
    mov r14d, [rsp]             # its own line
    mov eax, [rip + link_h]
    add [rip + link_y], eax
31: lea rsi, [rip + .Ls_remove]
    call cslen
    mov edi, ID_AGSIDE + SID_REMOVE
    mov ecx, r14d
    call link
    test edx, UB_CLICK
    jz 4f
    mov rdi, r12
    call bm_remove
    EPILOGUE
4:  mov rdi, r12                # its text
    call book_md
    mov r15, rax
    mov rdi, rax
    mov esi, [rsp + 8]
    call md_layout
    mov r8d, eax
    mov eax, ID_SIDE_MD + 15 * 4096
    push rax
    push rax
    mov rdi, r15
    mov esi, [rsp + 16]
    mov edx, [rsp + 16 + 4]
    add edx, [rsp + 16 + 12]
    mov ecx, [rsp + 16 + 8]
    xor r9d, r9d
    call md_draw
    add rsp, 16
    cmp eax, -1
    je 9f
    mov rdi, r15
    mov esi, eax
    call md_open_link
9:  EPILOGUE

# link(id, ptr, len, x ecx) -> eax its width, edx its UB bits: a link in the small face on the links line
#   (link_y, link_h)
link:
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov [rsp + 4], ecx
    mov rdi, [rip + ag_fsmall]
    call text_width
    mov r12d, eax
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rip + link_y]
    mov ecx, r12d
    mov r8d, [rip + link_h]
    call ui_btn
    mov r13d, eax
    test r13d, UB_HOVER
    jz 1f
    mov edi, CUR_POINTER
    call ui_set_cursor
1:  mov rdi, [rip + ag_fsmall]
    mov esi, [rsp + 4]
    mov edx, [rip + link_y]
    mov ecx, [rip + link_h]
    mov r8, [rsp + 8]
    mov r9, [rsp + 16]
    COLOR r10d, T_ACCENT
    mov r11d, r12d
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    mov eax, r12d
    mov edx, r13d
    EPILOGUE

# show_in(AS*, row): "Show in conversation": the reply brought into view, the keyboard to the box
show_in:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    mov esi, r12d
    call agents_reveal
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# ---- keys and the fields' routing ----

# FN agside_key(keysym, cp, mods) -> eax 1 taken: the panel with the keyboard. Escape closes it. The side
#   question: Enter sends (Shift+Enter a new line), the rest edits its field; Page Up and Down scroll. The
#   bookmarks: Up and Down pick, Enter "Show in conversation", Delete "Remove bookmark", Home, End
FN agside_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    xor eax, eax
    cmp dword ptr [rip + sp_keys], 0
    je 9f
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    jne 9f
    call shown_as
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp r12d, KEY_ESCAPE
    jne 1f
    call agside_close
    jmp 8f
1:  cmp r12d, KEY_PAGEUP
    jne 2f
    mov eax, [rip + sp_scroll]
    sub eax, [rip + g_bodyh]
    call set_scroll
    mov dword ptr [rip + sp_follow], 0
    jmp 7f
2:  cmp r12d, KEY_PAGEDOWN
    jne 3f
    mov eax, [rip + sp_scroll]
    add eax, [rip + g_bodyh]
    call set_scroll
    jmp 7f
3:  cmp dword ptr [rip + sp_kind], SPK_SIDE
    jne 5f
    cmp r12d, KEY_RETURN
    je 31f
    cmp r12d, KEY_KP_ENTER
    jne 4f
31: test r14d, MOD_SHIFT
    jnz 4f
    mov rdi, rbx
    call side_send
    jmp 7f
4:  lea rdi, [rip + sp_tf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call ta_key
    test eax, eax
    jnz 7f
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz 9f
    jmp 7f
5:  mov rdi, rbx                # the bookmarks
    call book_list
    mov rcx, [rip + blist + VEC_len]
    movsxd rax, dword ptr [rip + sp_sel]
    cmp r12d, KEY_DOWN
    jne 51f
    inc rax
    cmp rax, rcx
    jl 50f
    lea rax, [rcx - 1]
50: mov [rip + sp_sel], eax
    jmp 7f
51: cmp r12d, KEY_UP
    jne 52f
    dec rax
    jns 50b
    xor eax, eax
    test rcx, rcx
    jnz 50b
    mov eax, -1
    jmp 50b
52: cmp r12d, KEY_HOME
    jne 53f
    xor eax, eax
    mov dword ptr [rip + sp_scroll], 0
    test rcx, rcx
    jnz 50b
    jmp 7f
53: cmp r12d, KEY_END
    jne 54f
    lea rax, [rcx - 1]
    mov ecx, [rip + sp_max]
    mov [rip + sp_scroll], ecx
    jmp 50b
54: cmp r12d, KEY_RETURN
    je 55f
    cmp r12d, KEY_KP_ENTER
    jne 56f
55: call shown_bm
    test rax, rax
    jz 7f
    mov rdi, rbx
    mov rsi, rax
    call bm_row
    test eax, eax
    js 7f
    mov rdi, rbx
    mov esi, eax
    call show_in
    jmp 7f
56: cmp r12d, KEY_DELETE
    je 57f
    cmp r12d, KEY_BACKSPACE
    jne 58f
57: call shown_bm
    test rax, rax
    jz 7f
    mov rdi, rax
    call bm_remove
    jmp 7f
58: test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz 9f
7:  mov dword ptr [rip + g_dirty], 1
8:  mov eax, 1
9:  EPILOGUE

# has_field() -> eax 1 when the side question's field has the keyboard (no dialog over the panel)
has_field:
    PROLOGUE
    xor eax, eax
    call agentdlg_open_now
    test eax, eax
    jnz 8f
    cmp dword ptr [rip + sp_keys], 0
    je 8f
    cmp dword ptr [rip + sp_kind], SPK_SIDE
    jne 8f
    call shown_as
    test rax, rax
    setnz al
    movzx eax, al
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agside_field() -> rax the field with the keyboard under FOCUS_AGENTS: the side question's, else the
#   dialog's or the card's (agentdlg_field)
FN agside_field
    PROLOGUE
    call has_field
    test eax, eax
    jz 1f
    lea rax, [rip + sp_tf]
    EPILOGUE
1:  call agentdlg_field
    EPILOGUE

# FN agside_paste(ptr, len): a paste under FOCUS_AGENTS: into the side question's field, else agentdlg_paste
FN agside_paste
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call has_field
    test eax, eax
    jz 1f
    lea rdi, [rip + sp_tf]
    mov rsi, rbx
    mov rdx, r12
    call ta_insert
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
1:  mov rdi, rbx
    mov rsi, r12
    call agentdlg_paste
    EPILOGUE

# ---- text helpers (as agentdlg.s's) ----

# wrap1(face, ptr, len, w) -> rax the first line's bytes, rdx the bytes it takes (its break too)
wrap1:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    xor ecx, ecx
1:  cmp rcx, r13
    jae 2f
    cmp byte ptr [r12 + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov r15, rcx
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    mov ecx, r14d
    call text_fit
    cmp rax, r15
    jb 3f
    mov rax, r15
    mov rdx, r15
    cmp r15, r13
    jae 9f
    inc rdx
    jmp 9f
3:  mov rcx, rax
4:  test rcx, rcx
    jz 5f
    cmp byte ptr [r12 + rcx], ' '
    je 6f
    dec rcx
    jmp 4b
6:  mov rax, rcx
    lea rdx, [rcx + 1]
    jmp 9f
5:  test rax, rax
    jnz 7f
    mov rax, 1
8:  cmp rax, r15
    jae 7f
    movzx ecx, byte ptr [r12 + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne 7f
    inc rax
    jmp 8b
7:  mov rdx, rax
9:  EPILOGUE

# lines_of(face, ptr, len, w) -> eax its lines wrapped at w (1 for an empty text; 400 at most)
lines_of:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    xor r15d, r15d
1:  inc r15d
    test r13, r13
    jz 9f
    cmp r15d, 400
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, r14d
    call wrap1
    add r12, rdx
    sub r13, rdx
    test r13, r13
    jnz 1b
9:  mov eax, r15d
    EPILOGUE

# draw_wrap(face, x, y, w, ptr, len, [stack] argb) -> eax lines: the text wrapped at w from y down
draw_wrap:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov r12, r8
    mov r13, r9
    mov eax, [rbp + 16]
    mov [rsp + 12], eax
    xor r15d, r15d
1:  inc r15d
    test r13, r13
    jz 9f
    cmp r15d, 400
    ja 9f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, [rsp + 8]
    call wrap1
    mov r14, rdx
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rbx + FACE_ascent]
    mov rcx, r12
    mov r8, rax
    mov r9d, [rsp + 12]
    call text_draw
    mov eax, [rbx + FACE_lineh]
    add [rsp + 4], eax
    add r12, r14
    sub r13, r14
    test r13, r13
    jnz 1b
9:  mov eax, r15d
    EPILOGUE

# ---- headless ----

# FN agside_dump(sb): print-agent-side: "side=none|side|bookmarks shown=0|1 dock=beside|stacked keys=0|1
#   rect=X,Y,W,H thread=X,Y,W,H scroll=N max=N sel=N sizes=B,S field=TEXT", then the side question's
#   exchanges ("q TEXT" / "a STATE TEXT") or the bookmarks ("bm[N] FIRST_LINE" and, for the one shown,
#   "shown row=N|gone"), then "store bookmarks=N exchanges=N"
FN agside_dump
    PROLOGUE 16
    mov rbx, rdi
    call st_need
    mov rdi, rbx
    lea rsi, [rip + .Ld_side]
    call sb_push_cstr
    mov eax, [rip + sp_kind]
    lea rcx, [rip + kind_words]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_shown]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + sp_shown]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_dock]
    call sb_push_cstr
    lea rsi, [rip + .Ld_stacked]
    cmp dword ptr [rip + sp_dock], 0
    je 1f
    lea rsi, [rip + .Ld_beside]
1:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_keys]
    call sb_push_cstr
    xor esi, esi
    cmp dword ptr [rip + sp_keys], 0
    je 11f
    cmp dword ptr [rip + g_focus], FOCUS_AGENTS
    jne 11f
    mov esi, 1
11: mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_rect]
    lea rdx, [rip + sp_rect]
    call push_rect
    mov rdi, rbx
    lea rsi, [rip + .Ld_thread]
    lea rdx, [rip + sp_thread]
    call push_rect
    mov rdi, rbx
    lea rsi, [rip + .Ld_scroll]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + sp_scroll]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_max]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + sp_max]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_sel]
    call sb_push_cstr
    mov rdi, rbx
    movsxd rsi, dword ptr [rip + sp_sel]
    call push_int
    mov rdi, rbx
    lea rsi, [rip + .Ld_sizes]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + sp_side_pm]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rip + sp_stack_pm]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_field]
    call sb_push_cstr
    lea rdi, [rip + sp_tf]
    call tf_text
    mov rdi, rbx
    mov rsi, rax
    call esc_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    call viewed
    mov r12, rax
    test rax, rax
    jz 7f
    cmp dword ptr [rip + sp_kind], SPK_BOOK
    je 5f
    mov rdi, r12                # the conversation's exchanges
    call sid_of
    mov [rsp], rax
    mov [rsp + 8], rdx
    xor r13d, r13d
2:  cmp r13, [rip + sqs + VEC_len]
    jae 7f
    mov rax, [rip + sqs + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    mov rdi, [r14 + SQX_sid]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sid_is
    test eax, eax
    jz 2b
    mov rdi, rbx
    lea rsi, [rip + .Ld_q]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r14 + SQX_q]
    mov rdx, [r14 + SQX_qlen]
    call esc_push
    mov rdi, rbx
    lea rsi, [rip + .Ld_a]
    call sb_push_cstr
    mov eax, [r14 + SQX_state]
    lea rcx, [rip + state_words]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    mov rsi, [r14 + SQX_a]
    test rsi, rsi
    jz 3f
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r14 + SQX_a]
    mov rdx, [r14 + SQX_alen]
    call esc_push
3:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    jmp 2b
5:  mov rdi, r12                # the bookmarks
    call book_list
    xor r13d, r13d
6:  cmp r13, [rip + blist + VEC_len]
    jae 61f
    mov rdi, rbx
    lea rsi, [rip + .Ld_bm]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [r13 + 1]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_close_bracket]
    call sb_push_cstr
    mov rax, [rip + blist + VEC_ptr]
    mov rdi, [rax + r13*8]
    call first_line
    mov rdi, rbx
    mov rsi, rax
    call esc_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r13
    jmp 6b
61: call shown_bm
    test rax, rax
    jz 7f
    mov rdi, r12
    mov rsi, rax
    call bm_row
    mov r13d, eax
    mov rdi, rbx
    lea rsi, [rip + .Ld_shown_row]
    call sb_push_cstr
    test r13d, r13d
    js 62f
    mov rdi, rbx
    mov esi, r13d
    inc esi
    call sb_push_u64
    jmp 63f
62: mov rdi, rbx
    lea rsi, [rip + .Ld_gone]
    call sb_push_cstr
63: mov rdi, rbx
    mov esi, 10
    call sb_push_byte
7:  mov rdi, rbx
    lea rsi, [rip + .Ld_store]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + bms + VEC_len]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_exch]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + sqs + VEC_len]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# push_rect(sb, label cstr, rect*)
push_rect:
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    call sb_push_cstr
    xor r13d, r13d
1:  mov rdi, rbx
    movsxd rsi, dword ptr [r12 + r13*4]
    call push_int
    inc r13d
    cmp r13d, 4
    jae 9f
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# push_int(sb, signed)
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

# FN agside_fit_dump(sb): the panel's layout at panel sizes 8, 13, 32 and widths 240 to 900 (step 60, 700
#   tall): "size=S w=W dock=beside|stacked side=X,Y,W,H thread=W,H head=H body=H field=W send=W in=0|1" (in:
#   the title, a line of the body and, for the side question, the field and Send fit)
FN agside_fit_dump
    PROLOGUE 48
    mov rbx, rdi
    mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    mov rax, [rip + sp_rect]
    mov [rsp + 8], rax
    mov rax, [rip + sp_rect + 8]
    mov [rsp + 16], rax
    mov rax, [rip + sp_thread]
    mov [rsp + 24], rax
    mov rax, [rip + sp_thread + 8]
    mov [rsp + 32], rax
    xor r12d, r12d
1:  cmp r12d, 3
    jae 8f
    lea rax, [rip + fit_sizes]
    mov eax, [rax + r12*4]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    mov r13d, 240
2:  cmp r13d, 900
    ja 7f
    mov dword ptr [rip + fit_in], 0
    mov dword ptr [rip + fit_in + 4], 0
    mov [rip + fit_in + 8], r13d
    mov dword ptr [rip + fit_in + 12], 700
    lea rdi, [rip + fit_in]
    lea rsi, [rip + fit_out]
    call split_any
    call geom
    mov rdi, rbx
    lea rsi, [rip + .Lf_size]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + cfg_agents_font_size]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_w]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_dock]
    call sb_push_cstr
    lea rsi, [rip + .Ld_stacked]
    cmp dword ptr [rip + sp_dock], 0
    je 3f
    lea rsi, [rip + .Ld_beside]
3:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lf_side]
    lea rdx, [rip + sp_rect]
    call push_rect
    mov rdi, rbx
    lea rsi, [rip + .Lf_thread]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + fit_out + 8]
    call sb_push_u64
    mov rdi, rbx
    mov esi, ','
    call sb_push_byte
    mov rdi, rbx
    mov esi, [rip + fit_out + 12]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_head]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + g_head]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_body]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + g_bodyh]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_field]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + g_fw]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lf_send]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + g_sw]
    call sb_push_u64
    xor r14d, r14d              # in: a line of the body, the conversation at least as tall as its header
    mov rax, [rip + ag_fui]
    mov eax, [rax + FACE_lineh]
    cmp [rip + g_bodyh], eax
    jl 5f
    PM eax, MI_40
    cmp [rip + fit_out + 12], eax
    jl 5f
    cmp dword ptr [rip + sp_kind], SPK_SIDE
    jne 4f
    mov rax, [rip + ag_fui]     # the field: a word at least, and Send inside the panel
    mov eax, [rax + FACE_cellw]
    shl eax, 2
    cmp [rip + g_fw], eax
    jl 5f
    mov eax, [rip + g_sx]
    add eax, [rip + g_sw]
    mov ecx, [rip + sp_rect]
    add ecx, [rip + sp_rect + 8]
    cmp eax, ecx
    jg 5f
4:  mov r14d, 1
5:  mov rdi, rbx
    lea rsi, [rip + .Lf_in]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r14d
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add r13d, 60
    jmp 2b
7:  inc r12d
    jmp 1b
8:  mov eax, [rsp]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    mov rax, [rsp + 8]
    mov [rip + sp_rect], rax
    mov rax, [rsp + 16]
    mov [rip + sp_rect + 8], rax
    mov rax, [rsp + 24]
    mov [rip + sp_thread], rax
    mov rax, [rsp + 32]
    mov [rip + sp_thread + 8], rax
    EPILOGUE

# split_any(in*, out*): agside_split's arithmetic whatever the panel shows (the fit dump)
split_any:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, [rip + sp_kind]
    test r13d, r13d
    jnz 1f
    mov dword ptr [rip + sp_kind], SPK_SIDE
1:  mov dword ptr [rip + fit_force], 1
    mov rdi, rbx
    mov rsi, r12
    call agside_split
    mov dword ptr [rip + fit_force], 0
    mov [rip + sp_kind], r13d
    test r13d, r13d
    jnz 9f
    mov dword ptr [rip + sp_kind], SPK_SIDE     # (geom's parts of the side question)
    call geom
    mov dword ptr [rip + sp_kind], 0
9:  EPILOGUE

# ---- the headless commands (aictl.s's block) ----

# cargs(rest, len) -> rax, rdx without the blanks around
cargs:
1:  test rsi, rsi
    jz 2f
    cmp byte ptr [rdi], ' '
    ja 2f
    inc rdi
    dec rsi
    jmp 1b
2:  test rsi, rsi
    jz 3f
    cmp byte ptr [rdi + rsi - 1], ' '
    ja 3f
    dec rsi
    jmp 2b
3:  mov rax, rdi
    mov rdx, rsi
    ret

# word(ptr, len) -> rax its first word's length
word_len:
    xor eax, eax
1:  cmp rax, rsi
    jae 2f
    cmp byte ptr [rdi + rax], ' '
    jbe 2f
    inc rax
    jmp 1b
2:  ret

# FN agside_c_open(out, rest, len): agent-side btw [QUESTION] | bookmarks | close | clear
FN agside_c_open
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call cargs
    mov rbx, rax
    mov r12, rdx
    mov rdi, rax
    mov rsi, rdx
    call word_len
    mov r13, rax
    mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Lc_close]
    call str_eq_cstr
    test eax, eax
    jz 0f
    call agside_close
    jmp 8f
0:  mov rdi, rbx                # clear: the side question's Clear
    mov rsi, r13
    lea rdx, [rip + .Lc_clear]
    call str_eq_cstr
    test eax, eax
    jz 1f
    call viewed
    mov rdi, rax
    call sq_clear
    jmp 8f
1:  mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Lc_bookmarks]
    call str_eq_cstr
    test eax, eax
    jz 2f
    mov edi, SPK_BOOK
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call agside_open
    jmp 8f
2:  mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Lc_btw]
    call str_eq_cstr
    test eax, eax
    jz 7f
    lea rdi, [rbx + r13]
    mov rsi, r12
    sub rsi, r13
    call cargs
    mov rcx, rdx
    mov rdx, rax
    xor edi, edi
    mov esi, ACT_BTW
    call agside_run
8:  xor eax, eax
    EPILOGUE
7:  mov rax, -1
    EPILOGUE

# FN agside_c_bookmark(out, rest, len): agent-bookmark N: the bookmark of the open conversation's row N (from
#   1, as print-agent-row) toggled, as its button's click
FN agside_c_bookmark
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call cargs
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov rbx, rax
    call viewed
    test rax, rax
    jz 7f
    mov r12, rax
    test rbx, rbx
    jz 7f
    dec rbx
    cmp rbx, [r12 + AS_msgs + VEC_len]
    jae 7f
    imul rsi, rbx, AM_SIZE
    add rsi, [r12 + AS_msgs + VEC_ptr]
    cmp dword ptr [rsi + AM_role], R_ASSIST
    jne 7f
    mov rdi, r12
    call agbook_toggle
    xor eax, eax
    EPILOGUE
7:  mov rax, -1
    EPILOGUE

# FN agside_c_pick(out, rest, len): agent-side-pick N: bookmark N (from 1) shown, as its row's click;
#   agent-side-pick show | remove: its links
FN agside_c_pick
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call cargs
    mov rbx, rax
    mov r12, rdx
    call viewed
    test rax, rax
    jz 7f
    mov r13, rax
    mov rdi, rax
    call book_list
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lc_show]
    call str_eq_cstr
    test eax, eax
    jz 1f
    call shown_bm
    test rax, rax
    jz 7f
    mov rdi, r13
    mov rsi, rax
    call bm_row
    test eax, eax
    js 7f
    mov rdi, r13
    mov esi, eax
    call show_in
    jmp 8f
1:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lc_remove]
    call str_eq_cstr
    test eax, eax
    jz 2f
    call shown_bm
    test rax, rax
    jz 7f
    mov rdi, rax
    call bm_remove
    jmp 8f
2:  mov rdi, rbx
    mov rsi, r12
    call parse_u64
    test rax, rax
    jz 7f
    cmp rax, [rip + blist + VEC_len]
    ja 7f
    dec eax
    mov [rip + sp_sel], eax
    mov dword ptr [rip + sp_keys], 1
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
    mov dword ptr [rip + g_dirty], 1
8:  xor eax, eax
    EPILOGUE
7:  mov rax, -1
    EPILOGUE

# FN agside_c_size(out, rest, len): agent-side-size BESIDE STACKED: the shares (per mille), kept as a drag
#   that ends keeps them
FN agside_c_size
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call cargs
    mov rbx, rax
    mov r12, rdx
    mov rdi, rax
    mov rsi, rdx
    call word_len
    mov r13, rax
    mov rdi, rbx
    mov rsi, rax
    call parse_u64
    cmp rax, 100
    jb 7f
    cmp rax, 900
    ja 7f
    mov r14, rax
    lea rdi, [rbx + r13]
    mov rsi, r12
    sub rsi, r13
    call cargs
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    cmp rax, 100
    jb 7f
    cmp rax, 900
    ja 7f
    mov [rip + sp_stack_pm], eax
    mov [rip + sp_side_pm], r14d
    mov dword ptr [rip + g_dirty], 1
    call st_save
    xor eax, eax
    EPILOGUE
7:  mov rax, -1
    EPILOGUE

# FN agside_c_print(out, rest, len): print-agent-side [fit]
FN agside_c_print
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    call cargs
    mov rdi, rbx
    test rdx, rdx
    jnz 1f
    call agside_dump
    xor eax, eax
    EPILOGUE
1:  call agside_fit_dump
    xor eax, eax
    EPILOGUE

.bss
.p2align 2
fit_in: .zero 16
fit_out: .zero 16
fit_force: .long 0
link_y: .long 0
link_h: .long 0

.section .rodata
.p2align 3
state_words: .quad .Lw_unsent, .Lw_pending, .Lw_done, .Lw_empty, .Lw_cancelled, .Lw_error, 0
kind_words: .quad .Lw_none, .Lc_btw_word, .Lc_bookmarks
fit_sizes: .long 8, 13, 32
.globl agside_n_open, agside_n_bookmark, agside_n_pick, agside_n_size, agside_n_print
agside_n_open: .asciz "agent-side"
agside_n_bookmark: .asciz "agent-bookmark"
agside_n_pick: .asciz "agent-side-pick"
agside_n_size: .asciz "agent-side-size"
agside_n_print: .asciz "print-agent-side"
.Lsuffix: .asciz ".agents-side"
.Lw_head: .asciz "agside"
.Lw_head_line: .asciz "agside\t1\n"
.Lw_size: .asciz "size"
.Lw_bm: .asciz "bm"
.Lw_sq: .asciz "sq"
.Lw_unsent: .asciz "unsent"
.Lw_pending: .asciz "pending"
.Lw_done: .asciz "done"
.Lw_empty: .asciz "empty"
.Lw_cancelled: .asciz "cancelled"
.Lw_error: .asciz "error"
.Lw_none: .asciz "none"
.Lempty: .asciz ""
.Lhex: .ascii "0123456789abcdef"
.Lk_question: .asciz "question"
.Lk_response: .asciz "response"
.Lt_side: .asciz "Side question"
.Lt_book: .asciz "Bookmarks"
.Lph: .asciz "Ask a side question"
.Lsend: .asciz "Send"
.Ls_wait: .asciz "\342\234\273 Answering\342\200\246"
.Ls_cancelled: .asciz "Cancelled."
.Ls_empty: .asciz "Claude didn't return an answer for this side question."
.Ls_hint: .asciz "Ask a quick side question without interrupting the main conversation."
.Ls_none: .asciz "Bookmark a response with the bookmark button under it to keep it here."
.Ls_pick: .asciz "Click a bookmark to show it here."
.Ls_show: .asciz "Show in conversation"
.Ls_gone: .asciz "No longer shown in the conversation"
.Ls_remove: .asciz "Remove bookmark"
.Le_failed: .asciz "Failed to get an answer: "
.Le_ended: .asciz " ended before it answered."
.Le_agent: .asciz "The agent"
.Le_noconv: .asciz "Open a conversation first."
.Le_nodrv: .asciz "Side questions need a conversation rhun drives."
.Le_unsent: .asciz "Failed to get an answer: the question could not be sent."
.Ld_side: .asciz "side="
.Ld_shown: .asciz " shown="
.Ld_dock: .asciz " dock="
.Ld_beside: .asciz "beside"
.Ld_stacked: .asciz "stacked"
.Ld_keys: .asciz " keys="
.Ld_rect: .asciz " rect="
.Ld_thread: .asciz " thread="
.Ld_scroll: .asciz " scroll="
.Ld_max: .asciz " max="
.Ld_sel: .asciz " sel="
.Ld_sizes: .asciz " sizes="
.Ld_field: .asciz " field="
.Ld_q: .asciz "q "
.Ld_a: .asciz "\na "
.Ld_bm: .asciz "bm["
.Ld_close_bracket: .asciz "] "
.Ld_shown_row: .asciz "shown row="
.Ld_gone: .asciz "gone"
.Ld_store: .asciz "store bookmarks="
.Ld_exch: .asciz " exchanges="
.Lf_size: .asciz "size="
.Lf_w: .asciz " w="
.Lf_side: .asciz " side="
.Lf_thread: .asciz " thread="
.Lf_head: .asciz " head="
.Lf_body: .asciz " body="
.Lf_field: .asciz " field="
.Lf_send: .asciz " send="
.Lf_in: .asciz " in="
.Lc_close: .asciz "close"
.Lc_clear: .asciz "clear"
.Lc_bookmarks: .asciz "bookmarks"
.Lc_btw: .asciz "btw"
.Lc_btw_word: .asciz "side"
.Lc_show: .asciz "show"
.Lc_remove: .asciz "remove"
