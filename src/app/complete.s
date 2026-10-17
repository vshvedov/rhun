# completion lists and signature help from extensions (docs/extensions/v1.md, 12b and 12c): asking
# the providers, merging and filtering their items, the list under the cursor and putting the
# chosen item in; the signature above the cursor. Answers arrive inside extproto's pump, so they
# only change state here: whatever has to be sent goes out from the frame (complete_draw) or the
# tick, never from complete_reply.
.include "rhun.inc"

.equ CP_SHOW, 50                # items kept after filtering, best first
.equ CP_ROWS, 10                # rows the list shows at once
.equ CP_TYPED_MS, 150           # the pause after typing in a word before the list is asked for
.equ CP_QMAX, 256               # the filter text: longer filters nothing
.equ HR_MAX, 64                 # requests waiting for answers
.equ AE_MAX, 64                 # edits an accepted item makes, its own and its extra ones
.equ HR_COMPLETE, 1
.equ HR_SIGNATURE, 2
.equ CK_COUNT, 17               # item kinds (kind_names)
.equ DOC_LINES_MAX, 14          # the documentation beside the list
.equ SG_LINES_MAX, 6            # the signature's documentation

# an item of the list
STRUCT
F CI_ext, 8                     # EXT* that gave it
F CI_o1, 8                      # the range it replaces, byte offsets, as it was asked for
F CI_o2, 8
F CI_req, 8                     # the cursor when it was asked for: o2 past it moves with typing
F CI_off, 8                     # its bytes in cp_bytes: label, insert, detail, extra
F CI_llen, 4
F CI_ilen, 4
F CI_dlen, 4
F CI_xlen, 4
F CI_kind, 4
F CI_pad, 4
ENDSTRUCT CI_SIZE

# a request rhun sent and waits on
STRUCT
F HR_ext, 8
F HR_id, 8
F HR_kind, 4                    # HR_COMPLETE, HR_SIGNATURE
F HR_session, 4                 # cp_session or sg_session when it went out
F HR_req, 8                     # the cursor then
ENDSTRUCT HR_SIZE

.data
.p2align 3
cp_qo1: .quad -1                # the offset cp_q was copied from, the cursor then, its length
cp_hover: .long -1              # the row under the pointer
.long 0

.bss
.p2align 3
cp_open: .long 0                # 0 closed, 1 asked, 2 items to show
cp_session: .long 0             # each new list: answers for an older one are dropped
cp_doc: .quad 0                 # the session's DOC* and its id (a freed DOC's address can return)
cp_doc_id: .quad 0
cp_start: .quad 0               # where the word starts; the filter text runs from it to the cursor
cp_tail: .quad 0                # bytes after the cursor: the same while the user types in the word
cp_seen_cur: .quad 0            # the cursor and version the list was filtered for
cp_seen_ver: .quad 0
cp_due: .quad 0                 # time_ms when the list is asked for after typing (0: not due)
cp_more: .long 0                # a provider cut its list short: typing asks again
cp_reask: .long 0               # ask again from the frame (an answer came in the pump)
cp_sel: .long 0                 # the selected row
cp_top: .long 0                 # the first row shown
cp_nshown: .long 0
cp_shown: .zero 4 * CP_SHOW     # item indices, best first
cp_scores: .zero 4 * CP_SHOW
cp_rect: .zero 16               # where the list was drawn: x y w h (h 0: nowhere)
cp_items: .zero VEC_SIZE        # CI records
cp_bytes: .zero SB_SIZE         # their text
cp_new_items: .zero VEC_SIZE    # an answer being merged
cp_new_bytes: .zero SB_SIZE
cp_reqs: .zero VEC_SIZE         # HR records
cp_q: .zero CP_QMAX             # the filter text
cp_qlen: .quad 0
cp_qcur: .quad 0
sg_open: .long 0                # the signature shows
sg_wait: .long 0                # a request for it is out
sg_again: .long 0               # something changed while it was out: ask again when it answers
sg_session: .long 0
sg_from: .long 0                # the active parameter's bytes in the signature (-1: none)
sg_to: .long 0
sg_doc: .quad 0                 # the DOC* and id it is for
sg_doc_id: .quad 0
sg_cur: .quad 0                 # the cursor and version it was last asked for
sg_ver: .quad 0
sg_ext: .quad 0                 # EXT* that answers
sg_text: .zero SB_SIZE          # the signature, LF, the documentation
sg_siglen: .quad 0              # the signature's bytes in sg_text
sg_rect: .zero 16
# the answer parser: where it is, the end of the body and of the current line
.globl ps_ptr, ps_end, ps_lend
ps_ptr: .quad 0
ps_end: .quad 0
ps_lend: .quad 0
ps_doc: .quad 0
ps_rline: .quad 0               # the request's cursor line (0-based) and how far the cursor has moved
ps_delta: .quad 0               # since (typing in the word): positions are turned into the request's
ps_req: .quad 0                 # its cursor offset, for mapping positions back into the live text

.text

# ---------------- helpers ----------------

# is_word(byte) -> eax 1 for a letter, a digit, _ or a byte of a multibyte character
is_word:
    cmp edi, 0x80
    jae 1f
    cmp edi, '_'
    je 1f
    mov eax, edi
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 26
    jb 1f
    mov eax, edi
    sub eax, '0'
    cmp eax, 10
    jb 1f
    xor eax, eax
    ret
1:  mov eax, 1
    ret

# word_start(doc, pos) -> rax the start of the word that ends at pos
word_start:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
1:  test r12, r12
    jz 2f
    lea rsi, [r12 - 1]
    mov rdi, rbx
    call doc_byte
    mov edi, eax
    call is_word
    test eax, eax
    jz 2f
    dec r12
    jmp 1b
2:  mov rax, r12
    pop r13
    pop r12
    pop rbx
    ret

# trig_has(list, ch) -> eax 1 when ch is one of the list's characters (". :" style, ASCII)
trig_has:
    test rdi, rdi
    jz 8f
    cmp esi, 128
    jae 8f
1:  movzx eax, byte ptr [rdi]
    test eax, eax
    jz 8f
    cmp eax, ' '
    je 4f
    cmp eax, esi
    jne 3f
    movzx ecx, byte ptr [rdi + 1]
    test ecx, ecx
    jz 9f
    cmp ecx, ' '
    je 9f
3:  inc rdi                     # the rest of this word
    movzx eax, byte ptr [rdi]
    test eax, eax
    jz 8f
    cmp eax, ' '
    jne 3b
4:  inc rdi
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# focused_doc() -> rax g_doc when a document tab's editor has the keyboard, else 0
focused_doc:
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 8f
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 8f
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 8f
    mov rax, [rip + g_doc]
    ret
8:  xor eax, eax
    ret

# doc_alive() -> eax 1 when cp_doc is still the open document it was (answers arrive between frames)
doc_alive:
    push rbx
    mov rdi, [rip + cp_doc_id]
    call extproto_doc
    xor ecx, ecx
    cmp rax, [rip + cp_doc]
    sete cl
    mov eax, ecx
    pop rbx
    ret

# providers_any() -> eax 1 when an extension that is running or starting provides completion or
# signature help (one still starting asks once it has: typing in the meantime keeps the timer)
providers_any:
    xor ecx, ecx
1:  cmp rcx, [rip + g_exts + VEC_len]
    jae 8f
    imul rax, rcx, EXT_SIZE
    add rax, [rip + g_exts + VEC_ptr]
    inc rcx
    mov edx, [rax + EXT_status]
    cmp edx, ES_RUNNING
    je 2f
    cmp edx, ES_STARTING
    je 2f
    cmp edx, ES_IDLE            # an opened document activates its providers at the next tick
    jne 1b
2:  cmp qword ptr [rax + EXT_pv_complete], 0
    jne 9f
    cmp qword ptr [rax + EXT_pv_signature], 0
    je 1b
9:  mov eax, 1
    ret
8:  xor eax, eax
    ret

# req_remove(i): drop cp_reqs[i]
req_remove:
    mov rax, [rip + cp_reqs + VEC_len]
    dec rax
    mov [rip + cp_reqs + VEC_len], rax
    sub rax, rdi
    jz 9f
    imul rdx, rax, HR_SIZE
    imul rsi, rdi, HR_SIZE
    add rsi, [rip + cp_reqs + VEC_ptr]
    mov rdi, rsi
    add rsi, HR_SIZE
    jmp memmove
9:  ret

# cancel_kind(kind): "0 cancel ID" for every request of that kind still out, and forget them
cancel_kind:
    PROLOGUE
    mov r12d, edi
    xor ebx, ebx
1:  cmp rbx, [rip + cp_reqs + VEC_len]
    jae 9f
    imul rax, rbx, HR_SIZE
    add rax, [rip + cp_reqs + VEC_ptr]
    cmp [rax + HR_kind], r12d
    je 2f
    inc rbx
    jmp 1b
2:  mov rdi, [rax + HR_ext]
    mov rsi, [rax + HR_id]
    cmp dword ptr [rdi + EXT_status], ES_RUNNING
    jne 3f
    call extproto_send_cancel
3:  mov rdi, rbx
    call req_remove
    jmp 1b
9:  EPILOGUE

# line_col(doc, pos) -> rax 1-based line, rdx 1-based byte column
line_col:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call doc_line_of
    mov r13, rax
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov rdx, r12
    sub rdx, rax
    inc rdx
    lea rax, [r13 + 1]
    pop r13
    pop r12
    pop rbx
    ret

# ---------------- asking ----------------

# ask(kind cstr, ch, only_trig) -> eax the number of providers asked: "ID complete DOC VERSION
# LINE COL KIND CHAR" to each running provider whose patterns match cp_doc (with only_trig, to those
# whose triggers hold ch)
ask:
    PROLOGUE 32
    mov [rsp], rdi
    mov [rsp + 8], esi
    mov [rsp + 12], edx
    mov dword ptr [rsp + 16], 0
    mov r15, [rip + cp_doc]
    xor r13d, r13d
1:  cmp r13, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r13, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r13
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 1b
    test dword ptr [rbx + EXT_features], FEAT_COMPLETE
    jz 1b
    mov rdi, [rbx + EXT_pv_complete]
    mov rsi, r15
    call extproto_matches
    test eax, eax
    jz 1b
    cmp dword ptr [rsp + 12], 0
    je 2f
    mov rdi, [rbx + EXT_pv_ctrig]
    mov esi, [rsp + 8]
    call trig_has
    test eax, eax
    jz 1b
2:  cmp qword ptr [rip + cp_reqs + VEC_len], HR_MAX
    jae 9f
    mov rdi, rbx
    lea rsi, [rip + .Lv_complete]
    mov rdx, r15
    mov rcx, [rsp]
    mov r8d, [rsp + 8]
    call extproto_host_request
    test rax, rax
    jz 1b
    mov r12, rax
    lea rdi, [rip + cp_reqs]
    mov esi, HR_SIZE
    call vec_push
    mov [rax + HR_ext], rbx
    mov [rax + HR_id], r12
    mov dword ptr [rax + HR_kind], HR_COMPLETE
    mov ecx, [rip + cp_session]
    mov [rax + HR_session], ecx
    mov rcx, [r15 + DOC_cur]
    mov [rax + HR_req], rcx
    inc dword ptr [rsp + 16]
    jmp 1b
9:  mov eax, [rsp + 16]
    EPILOGUE

# cp_begin(kind, ch, only_trig): a new list for the word at the cursor of the focused document
cp_begin:
    PROLOGUE 16
    mov [rsp], rdi
    mov [rsp + 8], esi
    mov r12d, edx
    call cp_close
    call focused_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    jne 9f                      # not with a selection
    inc dword ptr [rip + cp_session]
    mov [rip + cp_doc], rbx
    mov rax, [rbx + DOC_id]
    mov [rip + cp_doc_id], rax
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call word_start
    mov [rip + cp_start], rax
    mov rdi, rbx
    call doc_len
    sub rax, [rbx + DOC_cur]
    mov [rip + cp_tail], rax
    mov rax, [rbx + DOC_cur]
    mov [rip + cp_seen_cur], rax
    mov rax, [rbx + DOC_version]
    mov [rip + cp_seen_ver], rax
    mov dword ptr [rip + cp_open], 1
    mov dword ptr [rip + cp_more], 0
    mov dword ptr [rip + cp_reask], 0
    mov qword ptr [rip + g_edit_lo], -1     # edits before the list do not count against it
    mov qword ptr [rip + g_edit_hi], 0
    mov rdi, [rsp]
    mov esi, [rsp + 8]
    mov edx, r12d
    call ask
    test eax, eax
    jnz 9f
    call cp_close               # nobody to ask
9:  EPILOGUE

# cp_close(): the list goes; requests still out are cancelled
cp_close:
    push rbx
    mov dword ptr [rip + cp_open], 0
    mov dword ptr [rip + cp_nshown], 0
    mov dword ptr [rip + cp_sel], 0
    mov dword ptr [rip + cp_top], 0
    mov dword ptr [rip + cp_more], 0
    mov dword ptr [rip + cp_reask], 0
    mov qword ptr [rip + cp_due], 0
    mov dword ptr [rip + cp_rect + 12], 0
    mov qword ptr [rip + cp_items + VEC_len], 0
    lea rdi, [rip + cp_bytes]
    call sb_clear
    mov qword ptr [rip + cp_qo1], -1
    mov edi, HR_COMPLETE
    call cancel_kind
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# FN complete_typed(cp): the user typed cp in the editor and it went in
FN complete_typed
    PROLOGUE
    mov r12d, edi
    call focused_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    call providers_any
    test eax, eax
    jz 9f
    # signature help: one of its triggers asks
    mov edi, r12d
    call sig_trigger
    # completion: a word grows, a trigger character starts a list, anything else ends it
    cmp r12d, 0x80
    jae 1f
    mov edi, r12d
    call is_word
    test eax, eax
    jz 3f
1:  cmp dword ptr [rip + cp_open], 0
    jne 9f                      # the open list follows the word as frames come
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call word_start
    mov rcx, [rbx + DOC_cur]
    sub rcx, rax
    cmp rcx, 2
    jb 9f
    call time_ms
    add rax, CP_TYPED_MS
    mov [rip + cp_due], rax
    jmp 9f
3:  lea rdi, [rip + .Lk_trigger]
    mov esi, r12d
    mov edx, 1
    call cp_begin
9:  EPILOGUE

# FN cmd_complete(): ctrl+space, the list at once
FN cmd_complete
    push rbx
    lea rdi, [rip + .Lk_invoked]
    mov esi, '-'
    xor edx, edx
    call cp_begin
    pop rbx
    ret

# FN complete_timeout() -> ms until the typed list is due, or -1
FN complete_timeout
    push rbx
    mov rbx, [rip + cp_due]
    test rbx, rbx
    jz 8f
    call time_ms
    sub rbx, rax
    jns 1f
    xor ebx, ebx
1:  mov eax, ebx
    pop rbx
    ret
8:  mov eax, -1
    pop rbx
    ret

# FN complete_tick(): the typed list when its pause is over
FN complete_tick
    push rbx
    mov rbx, [rip + cp_due]
    test rbx, rbx
    jz 9f
    call time_ms
    cmp rax, rbx
    jb 9f
    mov qword ptr [rip + cp_due], 0
    cmp dword ptr [rip + cp_open], 0
    jne 9f
    call focused_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call word_start
    mov rcx, [rbx + DOC_cur]
    sub rcx, rax
    cmp rcx, 2
    jb 9f                       # the word went while it waited
    # A provider may need longer than the typing pause to finish its handshake. Keep the
    # request due while a matching one starts, rather than losing the first completion.
    push r12
    push r13
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 3f
    imul r13, r12, EXT_SIZE
    add r13, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [r13 + EXT_status], ES_STARTING
    jne 1b
    mov rdi, [r13 + EXT_pv_complete]
    mov rsi, rbx
    call extproto_matches
    test eax, eax
    jz 1b
    call time_ms
    add rax, 50
    mov [rip + cp_due], rax
    pop r13
    pop r12
    jmp 9f
3:  pop r13
    pop r12
    lea rdi, [rip + .Lk_typed]
    mov esi, '-'
    xor edx, edx
    call cp_begin
9:  pop rbx
    ret

# ---------------- answers ----------------

# FN complete_reply(ext, id, ok, body, len) -> eax 1 when it was a completion's or a signature's
# request (called from extproto's pump: state only)
FN complete_reply
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov r14, rcx
    mov r15, r8
    xor r13d, r13d
1:  cmp r13, [rip + cp_reqs + VEC_len]
    jae 8f                      # not a completion's or a signature's
    imul rax, r13, HR_SIZE
    add rax, [rip + cp_reqs + VEC_ptr]
    cmp [rax + HR_ext], rbx
    jne 2f
    cmp [rax + HR_id], r12
    je 3f
2:  inc r13
    jmp 1b
3:  mov ecx, [rax + HR_kind]
    mov [rsp + 4], ecx
    mov ecx, [rax + HR_session]
    mov [rsp + 8], ecx
    mov rcx, [rax + HR_req]
    mov [rsp + 16], rcx
    mov rdi, r13
    call req_remove
    mov dword ptr [rip + g_dirty], 1
    cmp dword ptr [rsp + 4], HR_SIGNATURE
    je 5f
    # a list, for the session still open
    cmp dword ptr [rsp], 0
    je 9f                       # an error adds nothing
    mov eax, [rsp + 8]
    cmp eax, [rip + cp_session]
    jne 9f
    cmp dword ptr [rip + cp_open], 0
    je 9f
    call doc_alive
    test eax, eax
    jz 9f                       # closed meanwhile: the next frame ends the list
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    mov rcx, [rsp + 16]
    call cp_merge
    jmp 9f
5:  mov dword ptr [rip + sg_wait], 0
    mov eax, [rsp + 8]
    cmp eax, [rip + sg_session]
    jne 9f
    cmp dword ptr [rsp], 0
    je 51f
    mov rdi, r14
    mov rsi, r15
    call sg_set
    jmp 52f
51: mov dword ptr [rip + sg_open], 0
52: # moved since it was asked: ask again from the frame, whatever this answer did
    mov rax, [rip + g_doc]
    cmp rax, [rip + sg_doc]
    jne 9f
    mov rcx, [rax + DOC_cur]
    cmp rcx, [rip + sg_cur]
    jne 53f
    mov rcx, [rax + DOC_version]
    cmp rcx, [rip + sg_ver]
    je 9f
53: mov dword ptr [rip + sg_again], 1
9:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN complete_ext_gone(ext): an extension stopped: its requests and items go (no messages: this
# runs while processes are reaped)
FN complete_ext_gone
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + cp_reqs + VEC_len]
    jae 2f
    imul rax, r12, HR_SIZE
    add rax, [rip + cp_reqs + VEC_ptr]
    cmp [rax + HR_ext], rbx
    je 11f
    inc r12
    jmp 1b
11: mov rdi, r12
    call req_remove
    jmp 1b
2:  # its items
    mov rdi, rbx
    call keep_others
    lea rdi, [rip + cp_new_items]
    lea rsi, [rip + cp_items]
    call swap24
    lea rdi, [rip + cp_new_bytes]
    lea rsi, [rip + cp_bytes]
    call swap24
    mov qword ptr [rip + cp_qo1], -1
    cmp dword ptr [rip + cp_open], 0
    je 3f
    call doc_alive
    test eax, eax
    jz 3f
    call cp_filter
3:  cmp [rip + sg_ext], rbx
    jne 9f
    mov dword ptr [rip + sg_open], 0
    mov dword ptr [rip + sg_wait], 0
    mov qword ptr [rip + sg_ext], 0
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# swap24(a, b): exchange two VEC or SB records
swap24:
    mov rax, [rdi]
    mov rcx, [rsi]
    mov [rdi], rcx
    mov [rsi], rax
    mov rax, [rdi + 8]
    mov rcx, [rsi + 8]
    mov [rdi + 8], rcx
    mov [rsi + 8], rax
    mov rax, [rdi + 16]
    mov rcx, [rsi + 16]
    mov [rdi + 16], rcx
    mov [rsi + 16], rax
    ret

# keep_others(ext): cp_new_items and cp_new_bytes get the items of every other extension
keep_others:
    PROLOGUE
    mov r14, rdi
    mov qword ptr [rip + cp_new_items + VEC_len], 0
    lea rdi, [rip + cp_new_bytes]
    call sb_clear
    xor ebx, ebx
1:  cmp rbx, [rip + cp_items + VEC_len]
    jae 9f
    imul r12, rbx, CI_SIZE
    add r12, [rip + cp_items + VEC_ptr]
    inc rbx
    cmp [r12 + CI_ext], r14
    je 1b
    lea rdi, [rip + cp_new_items]
    mov esi, CI_SIZE
    call vec_push
    mov r13, rax
    # the record, then its bytes at their new place
    mov rdi, r13
    mov rsi, r12
    mov edx, CI_SIZE
    call memcpy
    mov rax, [rip + cp_new_bytes + SB_len]
    mov [r13 + CI_off], rax
    mov edx, [r12 + CI_llen]
    add edx, [r12 + CI_ilen]
    add edx, [r12 + CI_dlen]
    add edx, [r12 + CI_xlen]
    mov rsi, [r12 + CI_off]
    add rsi, [rip + cp_bytes + SB_ptr]
    lea rdi, [rip + cp_new_bytes]
    call sb_push
    jmp 1b
9:  EPILOGUE

# cp_merge(ext, body, len, req): an extension's list replaces what it said before in this session;
# a body that breaks the rules changes nothing
cp_merge:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], rcx
    cmp r13, CP_BODY_MAX
    ja 9f
    mov rdi, rbx
    call keep_others
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, [rsp]
    call cp_parse
    test eax, eax
    jz 9f
    mov [rsp + 8], edx
    or [rip + cp_more], edx
    lea rdi, [rip + cp_new_items]
    lea rsi, [rip + cp_items]
    call swap24
    lea rdi, [rip + cp_new_bytes]
    lea rsi, [rip + cp_bytes]
    call swap24
    mov qword ptr [rip + cp_qo1], -1
    call cp_filter
    cmp dword ptr [rsp + 8], 0
    je 9f
    mov rax, [rip + cp_doc]
    mov rcx, [rax + DOC_cur]
    cmp rcx, [rsp]
    je 9f
    mov dword ptr [rip + cp_reask], 1   # cut short for what was typed before: ask again
9:  EPILOGUE

# ---- the answer's parser: globals ps_ptr, ps_end, ps_lend ----

# ps_line() -> eax 1 with ps_lend at the LF ending the line from ps_ptr, 0 when there is none
FN ps_line
    mov rax, [rip + ps_ptr]
    mov rcx, [rip + ps_end]
1:  cmp rax, rcx
    jae 8f
    cmp byte ptr [rax], 10
    je 2f
    inc rax
    jmp 1b
2:  mov [rip + ps_lend], rax
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# ps_word() -> rax ptr, rdx len of the next word of the line (rdx 0 at its end); moves past it and
# one space
FN ps_word
    mov rax, [rip + ps_ptr]
    mov rcx, [rip + ps_lend]
    mov rdx, rax
1:  cmp rdx, rcx
    jae 2f
    cmp byte ptr [rdx], ' '
    je 2f
    inc rdx
    jmp 1b
2:  mov r8, rdx
    sub rdx, rax
    cmp r8, rcx
    jae 3f
    inc r8                      # the space
3:  mov [rip + ps_ptr], r8
    ret

# ps_num() -> rax value, edx 1 when the next word is a number of at most 10 digits
FN ps_num
    push rbx
    call ps_word
    test rdx, rdx
    jz 8f
    cmp rdx, 10
    ja 8f
    mov rbx, rdx
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    cmp rdx, rbx
    jne 8f
    mov edx, 1
    pop rbx
    ret
8:  xor eax, eax
    xor edx, edx
    pop rbx
    ret

# ps_snum() -> rax value (-1 allowed), edx 1 when the next word is one
ps_snum:
    mov rax, [rip + ps_ptr]
    cmp rax, [rip + ps_lend]
    jae ps_num
    cmp byte ptr [rax], '-'
    jne ps_num
    inc qword ptr [rip + ps_ptr]
    push rbx
    call ps_num
    neg rax
    pop rbx
    ret

# ps_eol() -> eax 1 when the line is used up; ps_ptr moves past its LF
FN ps_eol
    mov rax, [rip + ps_ptr]
    cmp rax, [rip + ps_lend]
    jne 8f
    inc rax
    mov [rip + ps_ptr], rax
    mov eax, 1
    ret
8:  xor eax, eax
    ret

# ps_pos() -> rax the byte offset of the next two words LINE COL in the document as it was when
# asked (ps_doc now, less ps_delta from the request's line on: only typing at its cursor has
# happened since), or -1 when it is not in it
ps_pos:
    push rbx
    push r12
    push r13
    call ps_num
    test edx, edx
    jz 8f
    mov r12, rax
    call ps_num
    test edx, edx
    jz 8f
    mov r13, rax
    test r12, r12
    jz 8f
    test r13, r13
    jz 8f
    mov rbx, [rip + ps_doc]
    cmp r12, [rbx + DOC_nlines]
    ja 8f
    dec r12
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    push rax
    push rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    pop rcx
    pop rcx                     # the line's end
    cmp r12, [rip + ps_rline]
    jb 2f
    je 1f
    sub rax, [rip + ps_delta]   # past the request's line: the typing moved it
1:  sub rcx, [rip + ps_delta]
2:  lea rax, [rax + r13 - 1]
    cmp rax, rcx
    jg 8f
    # Check the character boundary in the live text, where positions after the request's
    # cursor moved with subsequent typing. Never split a UTF-8 sequence with an edit.
    mov r13, rax
    mov r12, rax
    cmp r12, [rip + ps_req]
    jb 3f
    add r12, [rip + ps_delta]
3:  mov rdi, rbx
    call doc_len
    cmp r12, rax
    ja 8f
    je 4f
    mov rdi, rbx
    mov rsi, r12
    call doc_byte
    and eax, 0xc0
    cmp eax, 0x80
    je 8f
4:  mov rax, r13
    pop r13
    pop r12
    pop rbx
    ret
8:  mov rax, -1
    pop r13
    pop r12
    pop rbx
    ret

# req_coords(doc, req): ps_doc, ps_rline and ps_delta for positions asked at req
req_coords:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov [rip + ps_doc], rbx
    mov [rip + ps_req], r12
    mov rax, [rbx + DOC_cur]
    sub rax, r12
    mov [rip + ps_delta], rax
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]    # deleting in the word may put the old offset on the next line
    call doc_line_of
    mov [rip + ps_rline], rax
    pop r13
    pop r12
    pop rbx
    ret

# extra_ok(ptr, len) -> eax 1 when the bytes are whole records: a header line whose last word is a
# length of at most 10 digits, then that many bytes
extra_ok:
    PROLOGUE
    mov r12, rdi
    lea r13, [rdi + rsi]
1:  cmp r12, r13
    jae 8f
    mov rbx, r12
2:  cmp rbx, r13
    jae 9f
    cmp byte ptr [rbx], 10
    je 3f
    inc rbx
    jmp 2b
3:  mov r14, rbx
4:  cmp r14, r12
    je 5f
    cmp byte ptr [r14 - 1], ' '
    je 5f
    dec r14
    jmp 4b
5:  mov r15, rbx
    sub r15, r14
    jz 9f
    cmp r15, 10
    ja 9f
    mov rdi, r14
    mov rsi, r15
    call parse_u64
    cmp rdx, r15
    jne 9f
    lea rcx, [rbx + 1]
    mov rdx, r13
    sub rdx, rcx
    cmp rax, rdx
    ja 9f
    lea r12, [rcx + rax]
    jmp 1b
8:  mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# one_line(ptr, len) -> eax 1 when the bytes hold no line break
one_line:
    test rsi, rsi
    jz 9f
    movzx eax, byte ptr [rdi]
    cmp eax, 10
    je 8f
    cmp eax, 13
    je 8f
    inc rdi
    dec rsi
    jmp one_line
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# cp_parse(ext, body, len, req) -> eax 1 with the items appended to cp_new_items/cp_new_bytes and
# edx MORE, or eax 0 (section 12b: "N MORE", then N items, each a header line and its bytes)
cp_parse:
    PROLOGUE 64
    mov [rsp], rdi              # ext
    mov [rsp + 8], rcx          # req
    mov [rsp + 56], rsi
    mov [rsp + 48], rdx
    mov rdi, [rip + cp_doc]
    mov rsi, rcx
    call req_coords
    mov rsi, [rsp + 56]
    mov [rip + ps_ptr], rsi
    add rsi, [rsp + 48]
    mov [rip + ps_end], rsi
    call ps_line
    test eax, eax
    jz 8f
    call ps_num
    test edx, edx
    jz 8f
    cmp rax, CP_MAX_ITEMS
    ja 8f
    mov r15, rax                # N
    call ps_num
    test edx, edx
    jz 8f
    cmp rax, 1
    ja 8f
    mov [rsp + 16], eax         # MORE
    call ps_eol
    test eax, eax
    jz 8f
.Lcpp_item:
    test r15, r15
    jz .Lcpp_end
    dec r15
    call ps_line
    test eax, eax
    jz 8f
    call ps_pos
    test rax, rax
    js 8f
    mov [rsp + 24], rax         # o1
    call ps_pos
    test rax, rax
    js 8f
    mov [rsp + 32], rax         # o2
    cmp rax, [rsp + 24]
    jb 8f
    call ps_word
    mov rdi, rax
    mov rsi, rdx
    call kind_of
    mov [rsp + 40], eax
    call ps_num
    test edx, edx
    jz 8f
    mov r12, rax                # label
    call ps_num
    test edx, edx
    jz 8f
    mov r13, rax                # insert
    call ps_num
    test edx, edx
    jz 8f
    mov r14, rax                # detail
    call ps_num
    test edx, edx
    jz 8f
    mov rbx, rax                # extra
    call ps_eol
    test eax, eax
    jz 8f
    # the bytes are there, the label and the detail are one line each
    mov rax, r12
    add rax, r13
    add rax, r14
    add rax, rbx
    mov rcx, [rip + ps_end]
    sub rcx, [rip + ps_ptr]
    cmp rax, rcx
    ja 8f
    mov [rsp + 48], rax
    mov rdi, [rip + ps_ptr]
    mov rsi, r12
    call one_line
    test eax, eax
    jz 8f
    mov rdi, [rip + ps_ptr]
    add rdi, r12
    add rdi, r13
    mov rsi, r14
    call one_line
    test eax, eax
    jz 8f
    mov rdi, [rip + ps_ptr]
    add rdi, r12
    add rdi, r13
    add rdi, r14
    mov rsi, rbx
    call extra_ok
    test eax, eax
    jz 8f
    # the record
    lea rdi, [rip + cp_new_items]
    mov esi, CI_SIZE
    call vec_push
    mov rcx, [rsp]
    mov [rax + CI_ext], rcx
    mov rcx, [rsp + 24]
    mov [rax + CI_o1], rcx
    mov rcx, [rsp + 32]
    mov [rax + CI_o2], rcx
    mov rcx, [rsp + 8]
    mov [rax + CI_req], rcx
    mov rcx, [rip + cp_new_bytes + SB_len]
    mov [rax + CI_off], rcx
    mov [rax + CI_llen], r12d
    mov [rax + CI_ilen], r13d
    mov [rax + CI_dlen], r14d
    mov [rax + CI_xlen], ebx
    mov ecx, [rsp + 40]
    mov [rax + CI_kind], ecx
    lea rdi, [rip + cp_new_bytes]
    mov rsi, [rip + ps_ptr]
    mov rdx, [rsp + 48]
    call sb_push
    mov rax, [rsp + 48]
    add [rip + ps_ptr], rax
    jmp .Lcpp_item
.Lcpp_end:
    # exactly N items: nothing after them
    mov rax, [rip + ps_ptr]
    cmp rax, [rip + ps_end]
    jne 8f
    mov eax, 1
    mov edx, [rsp + 16]
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# kind_of(ptr, len) -> eax the kind's index (0, text, for one rhun does not know)
kind_of:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp ebx, CK_COUNT
    jae 8f
    lea rax, [rip + kind_names]
    mov rdx, [rax + rbx*8]
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 9f
    inc ebx
    jmp 1b
8:  xor ebx, ebx
9:  mov eax, ebx
    EPILOGUE

# ---------------- filtering ----------------

# item(i) -> rax CI*
item:
    imul rax, rdi, CI_SIZE
    add rax, [rip + cp_items + VEC_ptr]
    ret

# query_for(o1): cp_q and cp_qlen, the text from o1 to cp_doc's cursor (empty when the cursor is
# before it or the text is longer than CP_QMAX)
query_for:
    push rbx
    mov rax, [rip + cp_doc]
    mov rcx, [rax + DOC_cur]
    cmp rdi, [rip + cp_qo1]
    jne 1f
    cmp rcx, [rip + cp_qcur]
    je 9f
1:  mov [rip + cp_qo1], rdi
    mov [rip + cp_qcur], rcx
    mov qword ptr [rip + cp_qlen], 0
    sub rcx, rdi
    jbe 9f
    cmp rcx, CP_QMAX
    ja 9f
    mov [rip + cp_qlen], rcx
    mov rsi, rdi
    mov rdi, rax
    mov rdx, rcx
    lea rcx, [rip + cp_q]
    call doc_copy
9:  pop rbx
    ret

# cp_filter(): cp_shown from the items that match what was typed in the word, best first
cp_filter:
    PROLOGUE 32
    mov qword ptr [rip + cp_qo1], -1
    mov dword ptr [rip + cp_nshown], 0
    mov dword ptr [rip + cp_sel], 0
    mov dword ptr [rip + cp_top], 0
    mov r15, [rip + cp_doc]
    mov rax, [r15 + DOC_cur]
    mov [rsp], rax              # the cursor
    xor ebx, ebx
.Lcf_each:
    cmp rbx, [rip + cp_items + VEC_len]
    jae .Lcf_done
    mov rdi, rbx
    call item
    mov r12, rax
    mov rdi, [r12 + CI_o1]
    call query_for
    mov rdi, [r12 + CI_off]
    add rdi, [rip + cp_bytes + SB_ptr]
    mov esi, [r12 + CI_llen]
    lea rdx, [rip + cp_q]
    mov rcx, [rip + cp_qlen]
    call fuzzy
    test eax, eax
    js .Lcf_next
    # into the best CP_SHOW, after those that score as high (the providers' order stays)
    mov r13d, eax
    xor ecx, ecx
3:  cmp ecx, [rip + cp_nshown]
    jae 4f
    lea rdx, [rip + cp_scores]
    cmp [rdx + rcx*4], r13d
    jl 4f
    inc ecx
    jmp 3b
4:  cmp ecx, CP_SHOW
    jae .Lcf_next
    # shift the rest down one (the last falls off when full)
    mov edx, [rip + cp_nshown]
    cmp edx, CP_SHOW
    jae 5f
    inc dword ptr [rip + cp_nshown]
    jmp 6f
5:  dec edx
6:  cmp edx, ecx
    jbe 7f
    lea r8, [rip + cp_shown]
    lea r9, [rip + cp_scores]
    mov eax, [r8 + rdx*4 - 4]
    mov [r8 + rdx*4], eax
    mov eax, [r9 + rdx*4 - 4]
    mov [r9 + rdx*4], eax
    dec edx
    jmp 6b
7:  lea r8, [rip + cp_shown]
    lea r9, [rip + cp_scores]
    mov [r8 + rcx*4], ebx
    mov [r9 + rcx*4], r13d
.Lcf_next:
    inc rbx
    jmp .Lcf_each
.Lcf_done:
    mov rax, [rsp]
    mov [rip + cp_seen_cur], rax
    mov rax, [r15 + DOC_version]
    mov [rip + cp_seen_ver], rax
    mov eax, 1
    cmp dword ptr [rip + cp_nshown], 0
    je 8f
    mov eax, 2
8:  mov [rip + cp_open], eax
    mov dword ptr [rip + cp_hover], -1
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# cp_check(): each frame: the list follows the word being typed; moving away, a selection, an
# edit elsewhere or another document ends it
cp_check:
    PROLOGUE
    cmp dword ptr [rip + cp_open], 0
    je 9f
    call focused_doc
    test rax, rax
    jz 7f
    mov rbx, rax
    cmp rbx, [rip + cp_doc]
    jne 7f
    mov rax, [rbx + DOC_id]
    cmp rax, [rip + cp_doc_id]
    jne 7f
    mov rdi, rbx
    call ed_sel
    cmp rax, rdx
    jne 7f
    mov r12, [rbx + DOC_cur]
    cmp r12, [rip + cp_start]
    jb 7f
    mov rdi, rbx
    call doc_len
    sub rax, r12
    cmp rax, [rip + cp_tail]
    jne 7f
    # only word characters between the word's start and the cursor
    mov r13, [rip + cp_start]
1:  cmp r13, r12
    jae 2f
    mov rdi, rbx
    mov rsi, r13
    call doc_byte
    mov edi, eax
    call is_word
    test eax, eax
    jz 7f
    inc r13
    jmp 1b
2:  # what was typed since it was filtered: every edit since started in the word
    cmp r12, [rip + cp_seen_cur]
    jne 3f
    mov rax, [rbx + DOC_version]
    cmp rax, [rip + cp_seen_ver]
    je 4f
3:  mov rax, [rbx + DOC_version]
    cmp rax, [rip + cp_seen_ver]
    je 31f
    mov rax, [rip + g_edit_lo]
    cmp rax, [rip + cp_start]
    jb 7f
    cmp qword ptr [rip + g_edit_hi], r12
    ja 7f
31: mov qword ptr [rip + g_edit_lo], -1
    mov qword ptr [rip + g_edit_hi], 0
    call cp_filter
    cmp dword ptr [rip + cp_more], 0
    je 4f
    mov dword ptr [rip + cp_reask], 1
4:  # a list cut short is asked for again, once nothing is out for this session
    cmp dword ptr [rip + cp_reask], 0
    je 9f
    xor ecx, ecx
5:  cmp rcx, [rip + cp_reqs + VEC_len]
    jae 6f
    imul rax, rcx, HR_SIZE
    add rax, [rip + cp_reqs + VEC_ptr]
    inc rcx
    cmp dword ptr [rax + HR_kind], HR_COMPLETE
    jne 5b
    jmp 9f
6:  mov dword ptr [rip + cp_reask], 0
    mov dword ptr [rip + cp_more], 0
    lea rdi, [rip + .Lk_incomplete]
    mov esi, '-'
    xor edx, edx
    call ask
    jmp 9f
7:  call cp_close
9:  EPILOGUE

# ---------------- signature help ----------------

# sig_provider() -> rax the first running extension that agreed signature help and whose patterns
# match the focused document, or 0
sig_provider:
    PROLOGUE
    call focused_doc
    test rax, rax
    jz 8f
    mov r12, rax
    xor r13d, r13d
1:  cmp r13, [rip + g_exts + VEC_len]
    jae 8f
    imul rbx, r13, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r13
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 1b
    test dword ptr [rbx + EXT_features], FEAT_SIGNATURE
    jz 1b
    mov rdi, [rbx + EXT_pv_signature]
    mov rsi, r12
    call extproto_matches
    test eax, eax
    jz 1b
    mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# sig_trigger(ch): a typed character that is one of the provider's triggers asks
sig_trigger:
    PROLOGUE
    mov r12d, edi
    call sig_provider
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, [rbx + EXT_pv_strig]
    mov esi, r12d
    call trig_has
    test eax, eax
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_trigger]
    mov edx, r12d
    call sig_ask
9:  EPILOGUE

# sig_ask(ext, kind, ch): "ID signature DOC VERSION LINE COL KIND CHAR"
sig_ask:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    call focused_doc
    test rax, rax
    jz 9f
    mov r14, rax
    cmp qword ptr [rip + cp_reqs + VEC_len], HR_MAX
    jae 9f
    # a new help (not an update) starts a session: answers for older ones are dropped
    lea rdi, [rip + .Lk_update]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 1f
    mov edi, HR_SIGNATURE
    call cancel_kind
    inc dword ptr [rip + sg_session]
1:  mov [rip + sg_ext], rbx
    mov [rip + sg_doc], r14
    mov rax, [r14 + DOC_id]
    mov [rip + sg_doc_id], rax
    mov rax, [r14 + DOC_cur]
    mov [rip + sg_cur], rax
    mov rax, [r14 + DOC_version]
    mov [rip + sg_ver], rax
    mov dword ptr [rip + sg_again], 0
    mov rdi, rbx
    lea rsi, [rip + .Lv_signature]
    mov rdx, r14
    mov rcx, r12
    mov r8d, r13d
    call extproto_host_request
    test rax, rax
    jz 9f
    mov r15, rax
    lea rdi, [rip + cp_reqs]
    mov esi, HR_SIZE
    call vec_push
    mov [rax + HR_ext], rbx
    mov [rax + HR_id], r15
    mov dword ptr [rax + HR_kind], HR_SIGNATURE
    mov ecx, [rip + sg_session]
    mov [rax + HR_session], ecx
    mov rcx, [r14 + DOC_cur]
    mov [rax + HR_req], rcx
    mov dword ptr [rip + sg_wait], 1
9:  EPILOGUE

# FN cmd_signature_help(): ctrl+shift+space
FN cmd_signature_help
    push rbx
    call sig_provider
    test rax, rax
    jz 9f
    mov rdi, rax
    lea rsi, [rip + .Lk_invoked]
    mov edx, '-'
    call sig_ask
9:  pop rbx
    ret

# sg_set(body, len): "FROM TO", the signature, the documentation; an empty body hides it
sg_set:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    test r13, r13
    jz 8f
    cmp r13, SG_BODY_MAX
    ja 8f
    mov [rip + ps_ptr], r12
    lea rax, [r12 + r13]
    mov [rip + ps_end], rax
    call ps_line
    test eax, eax
    jz 8f
    call ps_snum
    test edx, edx
    jz 8f
    mov r14, rax
    call ps_snum
    test edx, edx
    jz 8f
    mov r15, rax
    call ps_eol
    test eax, eax
    jz 8f
    # the signature: up to the next LF or the end
    mov rbx, [rip + ps_ptr]
    mov rcx, rbx
1:  cmp rcx, [rip + ps_end]
    jae 2f
    cmp byte ptr [rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  sub rcx, rbx
    mov [rip + sg_siglen], rcx
    # the active parameter within it, or none
    cmp r14, 0
    jl 3f
    cmp r15, r14
    jl 3f
    cmp r15, rcx
    jg 3f
    mov [rip + sg_from], r14d
    mov [rip + sg_to], r15d
    jmp 4f
3:  mov dword ptr [rip + sg_from], -1
    mov dword ptr [rip + sg_to], -1
4:  lea rdi, [rip + sg_text]
    call sb_clear
    lea rdi, [rip + sg_text]
    mov rsi, rbx
    mov rdx, [rip + ps_end]
    sub rdx, rbx
    call sb_push
    mov dword ptr [rip + sg_open], 1
    EPILOGUE
8:  mov dword ptr [rip + sg_open], 0
    EPILOGUE

# sg_check(): each frame: help that shows follows edits and the cursor (an update request when
# nothing is out); another document or tab hides it
sg_check:
    PROLOGUE
    mov eax, [rip + sg_open]
    or eax, [rip + sg_wait]
    or eax, [rip + sg_again]
    jz 9f
    call focused_doc
    test rax, rax
    jz 7f
    mov rbx, rax
    cmp rbx, [rip + sg_doc]
    jne 7f
    mov rax, [rbx + DOC_id]
    cmp rax, [rip + sg_doc_id]
    jne 7f
    mov rax, [rip + sg_ext]
    test rax, rax
    jz 7f
    cmp dword ptr [rax + EXT_status], ES_RUNNING
    jne 7f
    cmp dword ptr [rip + sg_wait], 0
    jne 9f                      # asked: the answer says what comes next
    cmp dword ptr [rip + sg_open], 0
    jne 51f
    cmp dword ptr [rip + sg_again], 0
    je 9f
51: mov rax, [rbx + DOC_cur]
    cmp rax, [rip + sg_cur]
    jne 1f
    mov rax, [rbx + DOC_version]
    cmp rax, [rip + sg_ver]
    je 9f
1:  cmp dword ptr [rip + sg_wait], 0
    jne 9f                      # asked when the answer comes (sg_cur still differs)
    mov rdi, [rip + sg_ext]
    lea rsi, [rip + .Lk_update]
    mov edx, '-'
    call sig_ask
    jmp 9f
7:  call sg_close
9:  EPILOGUE

# sg_close(): the help goes
sg_close:
    push rbx
    mov dword ptr [rip + sg_open], 0
    mov dword ptr [rip + sg_wait], 0
    mov dword ptr [rip + sg_again], 0
    mov dword ptr [rip + sg_rect + 12], 0
    mov edi, HR_SIGNATURE
    call cancel_kind
    mov dword ptr [rip + g_dirty], 1
    pop rbx
    ret

# ---------------- keys and accepting ----------------

# FN complete_key(keysym, cp, mods) -> eax 1 when the list or the help took the key
FN complete_key
    PROLOGUE
    mov r12d, edi
    mov r14d, edx
    test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER | MOD_SHIFT
    jnz 8f
    # Escape withdraws what was asked and not shown yet, and leaves the key to the editor
    cmp r12d, KEY_ESCAPE
    jne 71f
    cmp dword ptr [rip + cp_rect + 12], 0
    jne 71f
    mov eax, [rip + cp_open]
    or rax, [rip + cp_due]
    jz 72f
    call cp_close
72: cmp dword ptr [rip + sg_open], 0
    jne 71f
    mov eax, [rip + sg_wait]
    or eax, [rip + sg_again]
    jz 8f
    call sg_close
    jmp 8f
71:
    cmp dword ptr [rip + cp_open], 2
    jne 7f
    mov ebx, [rip + cp_nshown]
    test ebx, ebx
    jz 7f
    cmp dword ptr [rip + cp_rect + 12], 0
    je 7f                       # not on screen: the editor has the keys
    mov eax, [rip + cp_sel]
    cmp r12d, KEY_UP
    jne 1f
    dec eax
    jns 6f
    lea eax, [rbx - 1]
    jmp 6f
1:  cmp r12d, KEY_DOWN
    jne 2f
    inc eax
    cmp eax, ebx
    jb 6f
    xor eax, eax
    jmp 6f
2:  cmp r12d, KEY_PAGEUP
    jne 3f
    sub eax, CP_ROWS
    jns 6f
    xor eax, eax
    jmp 6f
3:  cmp r12d, KEY_PAGEDOWN
    jne 4f
    add eax, CP_ROWS
    cmp eax, ebx
    jb 6f
    lea eax, [rbx - 1]
    jmp 6f
4:  cmp r12d, KEY_RETURN
    je 41f
    cmp r12d, KEY_KP_ENTER
    je 41f
    cmp r12d, KEY_TAB
    jne 5f
41: call cp_accept
    jmp 9f
5:  cmp r12d, KEY_ESCAPE
    jne 7f
    call cp_close
    jmp 9f
6:  mov edi, eax
    call cp_select
    jmp 9f
7:  cmp r12d, KEY_ESCAPE
    jne 8f
    cmp dword ptr [rip + sg_open], 0
    je 8f
    call sg_close
    jmp 9f
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# cp_select(row): the selection moves there, the rows scroll to show it
cp_select:
    mov [rip + cp_sel], edi
    cmp edi, [rip + cp_top]
    jge 1f
    mov [rip + cp_top], edi
1:  mov eax, [rip + cp_top]
    add eax, CP_ROWS
    cmp edi, eax
    jl 2f
    lea eax, [rdi - CP_ROWS + 1]
    mov [rip + cp_top], eax
2:  mov dword ptr [rip + g_dirty], 1
    ret

# cp_accept(): the selected item goes in: its range, extended to the cursor by what was typed
# since, and its extra edits, as one undo step
cp_accept:
    PROLOGUE 96
    mov eax, [rip + cp_sel]
    cmp eax, [rip + cp_nshown]
    jae 8f
    lea rcx, [rip + cp_shown]
    mov edi, [rcx + rax*4]
    call item
    mov r12, rax
    call focused_doc
    test rax, rax
    jz 8f
    mov rbx, rax
    cmp rbx, [rip + cp_doc]
    jne 8f
    mov rax, [rbx + DOC_id]
    cmp rax, [rip + cp_doc_id]
    jne 8f
    test dword ptr [rbx + DOC_flags], DF_READONLY
    jnz 8f
    mov r13, [rbx + DOC_cur]
    mov rax, r13
    sub rax, [r12 + CI_req]
    mov [rsp], rax              # typed since it was asked for
    # the item's range
    mov r14, [r12 + CI_o1]
    mov r15, [r12 + CI_o2]
    cmp r15, [r12 + CI_req]
    jb 1f
    add r15, [rsp]
1:  cmp r15, r13
    jae 2f
    mov r15, r13
2:  mov rdi, rbx
    call doc_len
    cmp r15, rax
    jbe 3f
    mov r15, rax
3:  cmp r14, r15
    ja 8f
    # the edits: the item's first, then its extra ones that touch none of those before
    mov qword ptr [rip + ae_n], 0
    mov rax, [r12 + CI_off]
    add rax, [rip + cp_bytes + SB_ptr]
    mov ecx, [r12 + CI_llen]
    add rax, rcx                # the insert text
    mov [rsp + 64], rax         # the item's text, to know its record after sorting
    mov rdi, r14
    mov rsi, r15
    mov rdx, rax
    mov ecx, [r12 + CI_ilen]
    call ae_add
    mov rax, [r12 + CI_off]
    add rax, [rip + cp_bytes + SB_ptr]
    mov ecx, [r12 + CI_llen]
    add rax, rcx
    mov ecx, [r12 + CI_ilen]
    add rax, rcx
    mov ecx, [r12 + CI_dlen]
    add rax, rcx
    mov [rip + ps_ptr], rax
    mov ecx, [r12 + CI_xlen]
    add rax, rcx
    mov [rip + ps_end], rax
    mov rdi, rbx
    mov rsi, [r12 + CI_req]
    call req_coords
    mov qword ptr [rsp + 72], -1    # the cursor's offset in the item's text: none (at its end)
4:  call ps_line
    test eax, eax
    jz 5f
    call ps_word
    mov [rsp + 80], rax
    mov [rsp + 88], rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lx_edit]
    call str_eq_cstr
    test eax, eax
    jz 40f
    call ps_pos
    mov [rsp + 8], rax
    call ps_pos
    mov [rsp + 16], rax
    call ps_num
    test edx, edx
    jz 5f
    mov [rsp + 24], rax
    call ps_eol
    test eax, eax
    jz 5f
    mov rcx, [rip + ps_end]
    sub rcx, [rip + ps_ptr]
    cmp [rsp + 24], rcx
    ja 5f
    mov rax, [rip + ps_ptr]
    mov [rsp + 32], rax         # its text
    mov rcx, [rsp + 24]
    add [rip + ps_ptr], rcx
    # positions that are there, after the cursor moved by what was typed
    mov rdi, [rsp + 8]
    test rdi, rdi
    js 4b
    mov rsi, [rsp + 16]
    test rsi, rsi
    js 4b
    cmp rdi, [r12 + CI_req]
    jb 42f
    add rdi, [rsp]
42: cmp rsi, [r12 + CI_req]
    jb 43f
    add rsi, [rsp]
43: cmp rdi, rsi
    ja 4b
    mov [rsp + 8], rdi
    mov [rsp + 16], rsi
    mov rdi, rbx
    call doc_len
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    cmp rsi, rax
    ja 4b                       # not in the document as it is
    mov rdx, [rsp + 32]
    mov rcx, [rsp + 24]
    call ae_add
    jmp 4b
40: # cursor OFFSET 0: where the cursor goes in the item's text
    mov rdi, [rsp + 80]
    mov rsi, [rsp + 88]
    lea rdx, [rip + .Lx_cursor]
    call str_eq_cstr
    test eax, eax
    jz 41f
    call ps_num
    test edx, edx
    jz 5f
    mov [rsp + 48], rax
    call ps_num
    test edx, edx
    jz 5f
    test rax, rax
    jnz 5f                      # no bytes follow it
    call ps_eol
    test eax, eax
    jz 5f
    mov rax, [rsp + 48]
    mov ecx, [r12 + CI_ilen]
    cmp rax, rcx
    ja 4b                       # past the text: left out
    jae 401f
    mov rdx, [rsp + 64]
    movzx edx, byte ptr [rdx + rax]
    and edx, 0xc0
    cmp edx, 0x80
    je 4b                       # inside a character: left out
401:mov [rsp + 72], rax
    jmp 4b
41: # another record: its last word is its length
    mov rax, [rip + ps_lend]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 56], 0
44: call ps_word
    test rdx, rdx
    jz 45f
    mov [rsp + 56], rax
    mov [rsp + 48], rdx
    jmp 44b
45: mov rdi, [rsp + 56]
    test rdi, rdi
    jz 5f
    mov rsi, [rsp + 48]
    call parse_u64
    cmp rdx, [rsp + 48]
    jne 5f
    mov rcx, [rsp + 40]
    inc rcx
    add rcx, rax
    cmp rcx, [rip + ps_end]
    ja 5f
    mov [rip + ps_ptr], rcx
    jmp 4b
5:  # from the last to the first, so each edit's offsets hold when it is made
    call ae_sort
    mov rdi, rbx
    call doc_begin_group
    xor r13d, r13d
6:  cmp r13, [rip + ae_n]
    jae 7f
    imul rax, r13, 32
    lea rcx, [rip + ae_list]
    add rax, rcx
    mov [rsp + 8], rax
    mov rdx, [rax + 8]
    sub rdx, [rax]
    jz 61f
    mov rdi, rbx
    mov rsi, [rax]
    mov ecx, EK_OTHER
    call doc_delete
61: mov rax, [rsp + 8]
    mov rcx, [rax + 24]
    test rcx, rcx
    jz 62f
    mov rdi, rbx
    mov rsi, [rax]
    mov rdx, [rax + 16]
    mov r8d, EK_OTHER
    call doc_insert
62: inc r13
    jmp 6b
7:  mov rdi, rbx
    call doc_end_group
    # the cursor after the item's text, moved by the edits made before it
    mov eax, [r12 + CI_ilen]
    lea r13, [r14 + rax]
    xor ecx, ecx
71: cmp rcx, [rip + ae_n]
    jae 72f
    imul rax, rcx, 32
    lea rdx, [rip + ae_list]
    add rax, rdx
    inc rcx
    cmp [rax], r14
    jb 73f
    ja 71b
    mov rdx, [rax + 16]         # at the item's start: an insert there that is not the item
    cmp rdx, [rsp + 64]
    je 71b
    mov rdx, [rax + 8]
    cmp rdx, [rax]
    jne 71b
73: add r13, [rax + 24]
    add r13, [rax]
    sub r13, [rax + 8]
    jmp 71b
72: mov rax, [rsp + 72]
    test rax, rax
    js 74f
    mov ecx, [r12 + CI_ilen]    # a cursor record: that far into the item's text
    sub r13, rcx
    add r13, rax
74: mov [rbx + DOC_cur], r13
    mov [rbx + DOC_anchor], r13
    call ed_touch
8:  call cp_close
    EPILOGUE

# ae_add(start, end, ptr, len): one edit of the item being accepted, unless it overlaps one before
ae_add:
    mov rax, [rip + ae_n]
    cmp rax, AE_MAX
    jae 9f
    xor r8d, r8d
1:  cmp r8, rax
    jae 2f
    imul r9, r8, 32
    lea r10, [rip + ae_list]
    add r9, r10
    inc r8
    # overlapping unless one ends where (or before) the other starts
    cmp rsi, [r9]
    jbe 1b
    cmp rdi, [r9 + 8]
    jae 1b
    ret
2:  imul r9, rax, 32
    lea r10, [rip + ae_list]
    add r9, r10
    mov [r9], rdi
    mov [r9 + 8], rsi
    mov [r9 + 16], rdx
    mov [r9 + 24], rcx
    inc qword ptr [rip + ae_n]
9:  ret

# ae_sort(): last position first, with replacements before insertions at the same start
ae_sort:
    mov rcx, 1
1:  cmp rcx, [rip + ae_n]
    jae 9f
    mov rdx, rcx
2:  test rdx, rdx
    jz 3f
    imul r8, rdx, 32
    lea r9, [rip + ae_list]
    add r8, r9
    mov rax, [r8]
    cmp rax, [r8 - 32]
    jb 3f
    ja 5f
    mov rax, [r8 + 8]
    cmp rax, [r8 - 24]
    jbe 3f
5:  # swap the two records
    mov r10, 0
4:  mov rax, [r8 + r10]
    mov r11, [r8 + r10 - 32]
    mov [r8 + r10], r11
    mov [r8 + r10 - 32], rax
    add r10, 8
    cmp r10, 32
    jb 4b
    dec rdx
    jmp 2b
3:  inc rcx
    jmp 1b
9:  ret

# ---------------- drawing ----------------

# FN complete_hole(): at the frame's start: the list drawn last frame keeps the pointer from what
# is drawn under it this frame
FN complete_hole
    mov eax, [rip + cp_rect + 12]
    mov [rip + g_hole2 + 12], eax
    mov eax, [rip + cp_rect]
    mov [rip + g_hole2], eax
    mov eax, [rip + cp_rect + 4]
    mov [rip + g_hole2 + 4], eax
    mov eax, [rip + cp_rect + 8]
    mov [rip + g_hole2 + 8], eax
    ret

# FN complete_draw(): the frame's list and signature help, over everything but menus and dialogs
FN complete_draw
    PROLOGUE
    call cp_check
    call sg_check
    mov dword ptr [rip + g_hole2 + 12], 0   # the list's rows take the pointer themselves
    mov dword ptr [rip + cp_rect + 12], 0
    mov dword ptr [rip + sg_rect + 12], 0
    cmp dword ptr [rip + g_caret_ok], 0
    je 9f
    cmp dword ptr [rip + sg_open], 0
    je 1f
    call sg_draw
1:  cmp dword ptr [rip + cp_open], 2
    jne 9f
    cmp dword ptr [rip + cp_nshown], 0
    je 9f
    call cp_draw
9:  EPILOGUE

# baseline(face, y, h) -> eax the baseline of a line of the face centered in [y, y + h)
baseline:
    mov eax, edx
    sub eax, [rdi + FACE_ascent]
    sub eax, [rdi + FACE_descent]
    sar eax, 1
    add eax, esi
    add eax, [rdi + FACE_ascent]
    ret

# cp_draw(): the list under the word (above it when there is no room below)
cp_draw:
    PROLOGUE 96
    # the rows' height, the widest label and detail
    mov eax, [rip + g_lh]
    add eax, [rip + g_mt + 4*MI_4]
    mov [rsp], eax              # row height
    xor eax, eax
    mov [rsp + 4], eax          # label width
    mov [rsp + 8], eax          # detail width
    xor ebx, ebx
1:  cmp ebx, [rip + cp_nshown]
    jae 2f
    lea rax, [rip + cp_shown]
    mov edi, [rax + rbx*4]
    call item
    mov r12, rax
    lea rdi, [rip + g_face_code]
    mov rsi, [r12 + CI_off]
    add rsi, [rip + cp_bytes + SB_ptr]
    mov edx, [r12 + CI_llen]
    call text_width
    cmp eax, [rsp + 4]
    jle 11f
    mov [rsp + 4], eax
11: lea rdi, [rip + g_face_small]
    mov rsi, [r12 + CI_off]
    add rsi, [rip + cp_bytes + SB_ptr]
    mov eax, [r12 + CI_llen]
    add rsi, rax
    mov eax, [r12 + CI_ilen]
    add rsi, rax
    mov edx, [r12 + CI_dlen]
    call text_width
    cmp eax, [rsp + 8]
    jle 12f
    mov [rsp + 8], eax
12: inc ebx
    jmp 1b
2:  M eax, MI_64
    imul eax, eax, 3
    cmp [rsp + 8], eax
    jle 21f
    mov [rsp + 8], eax          # details give way
21: # the width: badge, label, detail, padding
    M eax, MI_4
    add eax, eax
    add eax, [rip + g_mt + 4*MI_6]
    add eax, [rip + g_mt + 4*MI_16]
    add eax, [rip + g_mt + 4*MI_8]
    mov [rsp + 12], eax         # the label's x within the list
    add eax, [rsp + 4]
    add eax, [rip + g_mt + 4*MI_8]
    cmp dword ptr [rsp + 8], 0
    je 22f
    add eax, [rip + g_mt + 4*MI_24]
    add eax, [rsp + 8]
22: M ecx, MI_64
    imul ecx, ecx, 3
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, [rip + g_editor_rect + 8]
    sub ecx, [rip + g_mt + 4*MI_16]
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 16], eax         # w
    # rows shown and the height
    mov eax, [rip + cp_nshown]
    cmp eax, CP_ROWS
    jbe 23f
    mov eax, CP_ROWS
23: mov [rsp + 20], eax         # rows
    imul eax, [rsp]
    M ecx, MI_4
    lea eax, [rax + rcx*2]
    mov [rsp + 24], eax         # h
    # x: the labels line up with the word being typed
    mov rbx, [rip + cp_doc]
    mov rsi, [rip + cp_start]
    mov rdx, [rbx + DOC_cur]
    sub rdx, rsi
    xor eax, eax
    cmp rdx, CP_QMAX
    ja 24f
    test rdx, rdx
    jz 24f
    mov [rsp + 40], rdx
    mov rdi, rbx
    call doc_range
    lea rdi, [rip + g_face_code]
    mov rsi, rax
    mov rdx, [rsp + 40]
    call text_width
24: mov ecx, [rip + g_caret_x]
    sub ecx, eax
    sub ecx, [rsp + 12]
    mov eax, [rip + g_cv + CV_w]
    sub eax, [rsp + 16]
    sub eax, [rip + g_mt + 4*MI_4]
    cmp ecx, eax
    cmovg ecx, eax
    mov eax, [rip + g_editor_rect]
    cmp ecx, eax
    cmovl ecx, eax
    mov [rsp + 28], ecx         # x
    # y: below the line, or above it when the editor ends first
    mov eax, [rip + g_caret_y]
    add eax, [rip + g_lh]
    mov ecx, eax
    add ecx, [rsp + 24]
    mov edx, [rip + g_editor_rect + 4]
    add edx, [rip + g_editor_rect + 12]
    cmp ecx, edx
    jle 25f
    mov ecx, [rip + g_caret_y]
    sub ecx, [rsp + 24]
    cmp ecx, [rip + g_editor_rect + 4]
    jl 25f
    mov eax, ecx
25: mov [rsp + 32], eax         # y
    # the card
    mov edi, [rsp + 28]
    mov esi, [rsp + 32]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 24]
    M r8d, MI_8
    M r9d, MI_2
    M eax, MI_RADIUS
    push rax
    push rax
    call ui_card_shadow
    add rsp, 16
    mov eax, [rsp + 28]
    mov [rip + cp_rect], eax
    mov eax, [rsp + 32]
    mov [rip + cp_rect + 4], eax
    mov eax, [rsp + 16]
    mov [rip + cp_rect + 8], eax
    mov eax, [rsp + 24]
    mov [rip + cp_rect + 12], eax
    # the wheel scrolls the rows
    mov edi, [rsp + 28]
    mov esi, [rsp + 32]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 24]
    call ui_in
    test eax, eax
    jz 3f
    mov eax, [rip + g_scroll_y]
    test eax, eax
    jz 3f
    mov dword ptr [rip + g_scroll_y], 0
    mov ecx, [rip + cp_top]
    test eax, eax
    jg 26f
    inc ecx
    jmp 27f
26: dec ecx
27: mov eax, [rip + cp_nshown]
    sub eax, [rsp + 20]
    cmp ecx, eax
    cmovg ecx, eax
    xor eax, eax
    cmp ecx, eax
    cmovl ecx, eax
    mov [rip + cp_top], ecx
3:  # the rows
    mov dword ptr [rsp + 36], -1    # a row clicked
    xor ebx, ebx
.Lcd_row:
    cmp ebx, [rsp + 20]
    jae .Lcd_rows_done
    mov eax, ebx
    imul eax, [rsp]
    add eax, [rsp + 32]
    add eax, [rip + g_mt + 4*MI_4]
    mov r13d, eax               # the row's y
    mov r14d, ebx
    add r14d, [rip + cp_top]    # the row
    lea rax, [rip + cp_shown]
    mov edi, [rax + r14*4]
    call item
    mov r12, rax
    lea edi, [rbx + ID_COMPLETE]
    mov esi, [rsp + 28]
    add esi, [rip + g_mt + 4*MI_4]
    mov edx, r13d
    mov ecx, [rsp + 16]
    sub ecx, [rip + g_mt + 4*MI_4]
    sub ecx, [rip + g_mt + 4*MI_4]
    mov r8d, [rsp]
    call ui_btn
    mov r15d, eax
    test r15d, UB_CLICK
    jz 31f
    mov [rsp + 36], r14d
31: # the selected row, the one under the pointer
    COLOR r9d, T_ACTIVE
    cmp r14d, [rip + cp_sel]
    je 32f
    test r15d, UB_HOVER
    jz 33f
    COLOR r9d, T_HOVER
32: mov edi, [rsp + 28]
    add edi, [rip + g_mt + 4*MI_4]
    mov esi, r13d
    mov edx, [rsp + 16]
    sub edx, [rip + g_mt + 4*MI_4]
    sub edx, [rip + g_mt + 4*MI_4]
    mov ecx, [rsp]
    M r8d, MI_4
    call gfx_round_rect
33: # the kind's badge: its letter in its color, on a tint of it
    mov eax, [r12 + CI_kind]
    lea rcx, [rip + kind_colors]
    movzx eax, byte ptr [rcx + rax]
    lea rcx, [rip + g_theme]
    mov eax, [rcx + rax*4]
    mov [rsp + 40], eax
    and eax, 0x00ffffff
    or eax, 0x33000000
    mov r9d, eax
    mov edi, [rsp + 28]
    add edi, [rip + g_mt + 4*MI_4]
    add edi, [rip + g_mt + 4*MI_6]
    mov [rsp + 44], edi
    mov esi, [rsp]
    sub esi, [rip + g_mt + 4*MI_16]
    sar esi, 1
    add esi, r13d
    mov [rsp + 48], esi
    M edx, MI_16
    M ecx, MI_16
    M r8d, MI_4
    call gfx_round_rect
    mov eax, [r12 + CI_kind]
    lea rcx, [rip + kind_letters]
    lea r9, [rcx + rax*2]
    mov eax, [rsp + 40]
    push rax
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, [rsp + 44 + 16]
    mov edx, [rsp + 48 + 16]
    M ecx, MI_16
    mov r8d, ecx
    call ui_text_center
    add rsp, 16
    # the detail's width in this row
    xor eax, eax
    mov [rsp + 60], eax
    cmp dword ptr [r12 + CI_dlen], 0
    je 35f
    mov rsi, [r12 + CI_off]
    add rsi, [rip + cp_bytes + SB_ptr]
    mov eax, [r12 + CI_llen]
    add rsi, rax
    mov eax, [r12 + CI_ilen]
    add rsi, rax
    lea rdi, [rip + g_face_small]
    mov edx, [r12 + CI_dlen]
    call text_width
    mov edx, [rsp + 8]
    cmp eax, edx
    cmovg eax, edx
    mov [rsp + 60], eax
35: # the label, what was typed in it in the accent color, clipped to what the detail leaves
    mov edi, [rsp + 28]
    add edi, [rsp + 12]
    mov [rsp + 52], edi         # its x
    mov esi, r13d
    mov edx, [rsp + 16]
    sub edx, [rsp + 12]
    sub edx, [rip + g_mt + 4*MI_8]
    sub edx, [rsp + 60]
    cmp dword ptr [rsp + 60], 0
    je 36f
    sub edx, [rip + g_mt + 4*MI_8]
36: mov ecx, [rsp]
    call gfx_clip_push
    mov rdi, [r12 + CI_o1]
    call query_for
    lea rdi, [rip + g_face_code]
    mov esi, r13d
    mov edx, [rsp]
    call baseline
    mov esi, eax
    mov edi, [rsp + 52]
    mov rdx, r12
    call draw_label
    call gfx_clip_pop
    # the detail at the right, muted
    mov eax, [rsp + 60]
    test eax, eax
    jz 34f
    mov rsi, [r12 + CI_off]
    add rsi, [rip + cp_bytes + SB_ptr]
    mov ecx, [r12 + CI_llen]
    add rsi, rcx
    mov ecx, [r12 + CI_ilen]
    add rsi, rcx
    mov [rsp + 56], rsi
    mov ecx, [rsp + 28]
    add ecx, [rsp + 16]
    sub ecx, [rip + g_mt + 4*MI_4]
    sub ecx, [rip + g_mt + 4*MI_8]
    sub ecx, eax
    mov eax, [rsp + 8]
    push rax
    COLOR eax, T_MUTED
    push rax
    lea rdi, [rip + g_face_small]
    mov esi, ecx
    mov edx, r13d
    mov ecx, [rsp + 16]
    mov r8, [rsp + 56 + 16]
    mov r9d, [r12 + CI_dlen]
    call ui_text_v_fit
    add rsp, 16
34: inc ebx
    jmp .Lcd_row
.Lcd_rows_done:
    # the documentation of the selected item beside the list
    mov edi, [rsp + 28]
    mov esi, [rsp + 32]
    mov edx, [rsp + 16]
    call cp_doc_draw
    mov eax, [rsp + 36]
    test eax, eax
    js 9f
    mov edi, eax
    call cp_select
    call cp_accept
9:  EPILOGUE

# draw_label(x, baseline, CI*): the label in the code face, the bytes the filter text matched
# (in order, ASCII, any case) in the accent color
draw_label:
    PROLOGUE 32
    mov [rsp], edi              # pen
    mov [rsp + 4], esi          # baseline
    mov r12, rdx
    mov r13, [r12 + CI_off]
    add r13, [rip + cp_bytes + SB_ptr]
    mov r14d, [r12 + CI_llen]
    xor ebx, ebx                # byte
    xor r15d, r15d              # query byte
1:  cmp ebx, r14d
    jae 9f
    # this run: matched or not, as its first byte is
    mov edi, ebx
    call lmatch
    mov [rsp + 8], eax
    add r15d, eax
    lea ecx, [rbx + 1]
2:  cmp ecx, r14d
    jae 3f
    push rcx
    push rcx
    mov edi, ecx
    call lmatch
    pop rcx
    pop rcx
    cmp eax, [rsp + 8]
    jne 3f
    add r15d, eax
    inc ecx
    jmp 2b
3:  mov [rsp + 12], ecx
    COLOR r9d, T_FG
    cmp dword ptr [rsp + 8], 0
    je 4f
    COLOR r9d, T_ACCENT
4:  lea rdi, [rip + g_face_code]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    lea rcx, [r13 + rbx]
    mov r8d, [rsp + 12]
    sub r8d, ebx
    call text_draw
    mov [rsp], eax
    mov ebx, [rsp + 12]
    jmp 1b
9:  EPILOGUE

# lmatch(i) -> eax 1 when label byte i (r13 the label) is the next query byte (r15d of cp_q)
lmatch:
    xor eax, eax
    cmp r15, [rip + cp_qlen]
    jae 9f
    movzx ecx, byte ptr [r13 + rdi]
    cmp ecx, 0x80
    jae 9f
    lea rdx, [rip + cp_q]
    movzx edx, byte ptr [rdx + r15]
    lea r8d, [rcx - 'A']
    cmp r8d, 25
    ja 1f
    or ecx, 0x20
1:  lea r8d, [rdx - 'A']
    cmp r8d, 25
    ja 2f
    or edx, 0x20
2:  cmp ecx, edx
    jne 9f
    mov eax, 1
9:  ret

# item_doc(CI*) -> rax ptr, rdx len of the documentation in the item's extra records (len 0: none)
item_doc:
    PROLOGUE
    mov r12, rdi
    mov rax, [r12 + CI_off]
    add rax, [rip + cp_bytes + SB_ptr]
    mov ecx, [r12 + CI_llen]
    add rax, rcx
    mov ecx, [r12 + CI_ilen]
    add rax, rcx
    mov ecx, [r12 + CI_dlen]
    add rax, rcx
    mov [rip + ps_ptr], rax
    mov ecx, [r12 + CI_xlen]
    add rax, rcx
    mov [rip + ps_end], rax
1:  call ps_line
    test eax, eax
    jz 8f
    mov rbx, [rip + ps_lend]
    # the record's last word is its length
    xor r13d, r13d
    xor r14d, r14d
    call ps_word
    mov r15, rax                # its name
2:  call ps_word
    test rdx, rdx
    jz 3f
    mov r13, rax
    mov r14, rdx
    jmp 2b
3:  test r13, r13
    jz 8f
    mov rdi, r13
    mov rsi, r14
    call parse_u64
    cmp rdx, r14
    jne 8f
    lea rcx, [rbx + 1]          # its bytes
    lea rdx, [rcx + rax]
    cmp rdx, [rip + ps_end]
    ja 8f
    mov [rip + ps_ptr], rdx
    # "doc LEN"
    cmp byte ptr [r15], 'd'
    jne 1b
    cmp byte ptr [r15 + 1], 'o'
    jne 1b
    cmp byte ptr [r15 + 2], 'c'
    jne 1b
    cmp byte ptr [r15 + 3], ' '
    jne 1b
    mov rdx, rax
    mov rax, rcx
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# wrap(face, ptr, len, maxw, x, y, lh, argb, lines left, draw) -> eax lines it takes (drawn when draw
# is 1): paragraphs at LF, lines broken at the last space that fits
# (args: rdi face, rsi ptr, rdx len, ecx maxw, r8d x, r9d y, [stack] lh, argb, max lines, draw)
wrap:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
    mov [rsp + 4], r8d
    mov [rsp + 8], r9d
    mov eax, [rbp + 16]
    mov [rsp + 12], eax         # lh
    mov eax, [rbp + 24]
    mov [rsp + 16], eax         # argb
    mov eax, [rbp + 32]
    mov [rsp + 20], eax         # lines at most
    mov eax, [rbp + 40]
    mov [rsp + 24], eax         # draw
    xor r15d, r15d              # lines
1:  test r13, r13
    jz 9f
    cmp r15d, [rsp + 20]
    jae 9f
    # this paragraph's end
    xor r14d, r14d
2:  cmp r14, r13
    jae 3f
    cmp byte ptr [r12 + r14], 10
    je 3f
    inc r14
    jmp 2b
3:  mov [rsp + 32], r14         # the paragraph's length
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    mov ecx, [rsp]
    call text_fit
    mov r14, rax
    cmp r14, [rsp + 32]
    jae 5f
    # break at the last space that fits
    mov rcx, r14
4:  test rcx, rcx
    jz 41f
    cmp byte ptr [r12 + rcx], ' '
    je 42f
    dec rcx
    jmp 4b
41: test r14, r14
    jnz 5f
    mov r14d, 1                 # not even one character fits: one anyway
    jmp 5f
42: mov r14, rcx
5:  cmp dword ptr [rsp + 24], 0
    je 6f
    mov eax, [rsp + 16]
    push rax
    push rax
    mov rdi, rbx
    mov esi, [rsp + 4 + 16]
    mov edx, r15d
    imul edx, [rsp + 12 + 16]
    add edx, [rsp + 8 + 16]
    mov ecx, [rsp + 12 + 16]
    mov r8, r12
    mov r9, r14
    call ui_text_v
    add rsp, 16
6:  inc r15d
    add r12, r14
    sub r13, r14
    # past the space or the line break where it broke
    test r13, r13
    jz 9f
    movzx eax, byte ptr [r12]
    cmp eax, ' '
    je 7f
    cmp eax, 10
    jne 1b
7:  inc r12
    dec r13
    jmp 1b
9:  mov eax, r15d
    EPILOGUE

# cp_doc_draw(x, y, w): the selected item's detail and documentation beside the list at x, y, w
cp_doc_draw:
    PROLOGUE 64
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov eax, [rip + cp_sel]
    lea rcx, [rip + cp_shown]
    mov edi, [rcx + rax*4]
    call item
    mov r12, rax
    mov rdi, r12
    call item_doc
    mov r13, rax
    mov r14, rdx                # the documentation
    mov eax, [r12 + CI_dlen]
    or rax, r14
    jz 9f                       # nothing to tell
    # its width; right of the list, else left of it
    M eax, MI_64
    imul eax, eax, 6
    mov ecx, [rip + g_cv + CV_w]
    shr ecx, 1
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp + 12], eax         # pw
    mov ecx, [rsp]
    add ecx, [rsp + 8]
    add ecx, [rip + g_mt + 4*MI_4]
    mov edx, ecx
    add edx, eax
    mov r8d, [rip + g_cv + CV_w]
    sub r8d, [rip + g_mt + 4*MI_4]
    cmp edx, r8d
    jle 1f
    mov ecx, [rsp]
    sub ecx, eax
    sub ecx, [rip + g_mt + 4*MI_4]
    js 9f
1:  mov [rsp + 16], ecx         # px
    # its height: the detail's line, then the documentation's
    M eax, MI_8
    mov ecx, [rsp + 12]
    sub ecx, eax
    sub ecx, eax
    mov [rsp + 20], ecx         # the text's width
    xor r15d, r15d
    cmp dword ptr [r12 + CI_dlen], 0
    je 2f
    mov r15d, [rip + g_face_code + FACE_lineh]
2:  mov [rsp + 24], r15d        # the detail's height
    xor eax, eax
    test r14, r14
    jz 3f
    xor eax, eax
    push rax
    mov eax, DOC_LINES_MAX
    push rax
    xor eax, eax
    push rax
    mov eax, [rip + g_face_small + FACE_lineh]
    push rax
    lea rdi, [rip + g_face_small]
    mov rsi, r13
    mov rdx, r14
    mov ecx, [rsp + 20 + 32]
    xor r8d, r8d
    xor r9d, r9d
    call wrap
    add rsp, 32
    imul eax, [rip + g_face_small + FACE_lineh]
3:  mov [rsp + 28], eax         # the documentation's height
    add eax, [rsp + 24]
    M ecx, MI_8
    lea eax, [rax + rcx*2]
    cmp dword ptr [rsp + 24], 0
    je 4f
    cmp dword ptr [rsp + 28], 0
    je 4f
    add eax, [rip + g_mt + 4*MI_4]
4:  mov [rsp + 32], eax         # ph
    mov edi, [rsp + 16]
    mov esi, [rsp + 4]
    mov edx, [rsp + 12]
    mov ecx, eax
    M r8d, MI_8
    M r9d, MI_2
    M eax, MI_RADIUS
    push rax
    push rax
    call ui_card_shadow
    add rsp, 16
    mov eax, [rsp + 4]
    add eax, [rip + g_mt + 4*MI_8]
    mov [rsp + 36], eax         # the next line's y
    cmp dword ptr [rsp + 24], 0
    je 5f
    mov eax, [rsp + 20]
    push rax
    COLOR eax, T_FG
    push rax
    lea rdi, [rip + g_face_code]
    mov esi, [rsp + 16 + 16]
    add esi, [rip + g_mt + 4*MI_8]
    mov edx, [rsp + 36 + 16]
    mov ecx, [rsp + 24 + 16]
    mov r8, [r12 + CI_off]
    add r8, [rip + cp_bytes + SB_ptr]
    mov eax, [r12 + CI_llen]
    add r8, rax
    mov eax, [r12 + CI_ilen]
    add r8, rax
    mov r9d, [r12 + CI_dlen]
    call ui_text_v_fit
    add rsp, 16
    mov eax, [rsp + 24]
    add eax, [rip + g_mt + 4*MI_4]
    add [rsp + 36], eax
5:  test r14, r14
    jz 9f
    mov eax, 1
    push rax
    mov eax, DOC_LINES_MAX
    push rax
    COLOR eax, T_MUTED
    push rax
    mov eax, [rip + g_face_small + FACE_lineh]
    push rax
    lea rdi, [rip + g_face_small]
    mov rsi, r13
    mov rdx, r14
    mov ecx, [rsp + 20 + 32]
    mov r8d, [rsp + 16 + 32]
    add r8d, [rip + g_mt + 4*MI_8]
    mov r9d, [rsp + 36 + 32]
    call wrap
    add rsp, 32
9:  EPILOGUE

# sg_draw(): the signature above the cursor, the active parameter in the accent color, then its
# documentation
sg_draw:
    PROLOGUE 64
    mov r12, [rip + sg_text + SB_ptr]
    mov r13, [rip + sg_siglen]
    mov r14, [rip + sg_text + SB_len]
    sub r14, r13                # the documentation, after the signature's LF
    jz 1f
    dec r14
1:  lea r15, [r12 + r13 + 1]
    # the width
    lea rdi, [rip + g_face_code]
    mov rsi, r12
    mov rdx, r13
    call text_width
    M ecx, MI_8
    lea eax, [rax + rcx*2]
    M ecx, MI_64
    imul ecx, ecx, 5
    cmp eax, ecx
    cmovl eax, ecx
    mov ecx, [rip + g_editor_rect + 8]
    sub ecx, [rip + g_mt + 4*MI_16]
    cmp eax, ecx
    cmovg eax, ecx
    mov [rsp], eax              # w
    M ecx, MI_8
    sub eax, ecx
    sub eax, ecx
    mov [rsp + 4], eax          # the text's width
    # the documentation's lines
    xor eax, eax
    test r14, r14
    jz 2f
    xor eax, eax
    push rax
    mov eax, SG_LINES_MAX
    push rax
    xor eax, eax
    push rax
    mov eax, [rip + g_face_small + FACE_lineh]
    push rax
    lea rdi, [rip + g_face_small]
    mov rsi, r15
    mov rdx, r14
    mov ecx, [rsp + 4 + 32]
    xor r8d, r8d
    xor r9d, r9d
    call wrap
    add rsp, 32
    imul eax, [rip + g_face_small + FACE_lineh]
    test eax, eax
    jz 2f
    add eax, [rip + g_mt + 4*MI_4]
2:  mov [rsp + 8], eax          # its height
    add eax, [rip + g_face_code + FACE_lineh]
    M ecx, MI_6
    lea eax, [rax + rcx*2]
    mov [rsp + 12], eax         # h
    # above the line, or below it at the top of the editor
    mov ecx, [rip + g_caret_x]
    sub ecx, [rip + g_mt + 4*MI_8]
    mov edx, [rip + g_cv + CV_w]
    sub edx, [rsp]
    sub edx, [rip + g_mt + 4*MI_4]
    cmp ecx, edx
    cmovg ecx, edx
    mov edx, [rip + g_editor_rect]
    cmp ecx, edx
    cmovl ecx, edx
    mov [rsp + 16], ecx         # x
    mov eax, [rip + g_caret_y]
    sub eax, [rsp + 12]
    sub eax, [rip + g_mt + 4*MI_4]
    cmp eax, [rip + g_editor_rect + 4]
    jge 3f
    mov eax, [rip + g_caret_y]
    add eax, [rip + g_lh]
    add eax, [rip + g_mt + 4*MI_4]
3:  mov [rsp + 20], eax         # y
    mov edi, [rsp + 16]
    mov esi, eax
    mov edx, [rsp]
    mov ecx, [rsp + 12]
    M r8d, MI_8
    M r9d, MI_2
    M eax, MI_RADIUS
    push rax
    push rax
    call ui_card_shadow
    add rsp, 16
    mov eax, [rsp + 16]
    mov [rip + sg_rect], eax
    mov eax, [rsp + 20]
    mov [rip + sg_rect + 4], eax
    mov eax, [rsp]
    mov [rip + sg_rect + 8], eax
    mov eax, [rsp + 12]
    mov [rip + sg_rect + 12], eax
    # the signature: before the parameter, the parameter, after it
    mov edi, [rsp + 16]
    add edi, [rip + g_mt + 4*MI_8]
    mov esi, [rsp + 20]
    add esi, [rip + g_mt + 4*MI_6]
    mov edx, [rsp + 4]
    mov ecx, [rip + g_face_code + FACE_lineh]
    call gfx_clip_push
    lea rdi, [rip + g_face_code]
    mov esi, [rsp + 20]
    add esi, [rip + g_mt + 4*MI_6]
    mov edx, [rip + g_face_code + FACE_lineh]
    call baseline
    mov [rsp + 24], eax
    mov eax, [rsp + 16]
    add eax, [rip + g_mt + 4*MI_8]
    mov [rsp + 28], eax         # the pen
    movsxd rbx, dword ptr [rip + sg_from]
    movsxd rax, dword ptr [rip + sg_to]
    test rbx, rbx
    jns 4f
    mov rbx, r13                # no parameter: all of it before one
    mov rax, r13
4:  mov [rsp + 32], rax
    mov rdx, rbx
    mov rcx, r12
    COLOR r9d, T_FG
    call sg_run
    mov rdx, [rsp + 32]
    sub rdx, rbx
    lea rcx, [r12 + rbx]
    COLOR r9d, T_ACCENT
    call sg_run
    mov rax, [rsp + 32]
    mov rdx, r13
    sub rdx, rax
    lea rcx, [r12 + rax]
    COLOR r9d, T_FG
    call sg_run
    call gfx_clip_pop
    # the documentation
    test r14, r14
    jz 9f
    mov eax, 1
    push rax
    mov eax, SG_LINES_MAX
    push rax
    COLOR eax, T_MUTED
    push rax
    mov eax, [rip + g_face_small + FACE_lineh]
    push rax
    lea rdi, [rip + g_face_small]
    mov rsi, r15
    mov rdx, r14
    mov ecx, [rsp + 4 + 32]
    mov r8d, [rsp + 16 + 32]
    add r8d, [rip + g_mt + 4*MI_8]
    mov r9d, [rsp + 20 + 32]
    add r9d, [rip + g_mt + 4*MI_6]
    add r9d, [rip + g_face_code + FACE_lineh]
    add r9d, [rip + g_mt + 4*MI_4]
    call wrap
    add rsp, 32
9:  EPILOGUE

# sg_run(rcx ptr, rdx len, r9d argb): a piece of the signature at the pen ([rsp + 28] of sg_draw's
# frame), the pen moved past it
sg_run:
    test rdx, rdx
    jz 9f
    push rbx
    lea rdi, [rip + g_face_code]
    mov esi, [rsp + 8 + 8 + 28]
    mov r8, rdx
    mov edx, [rsp + 8 + 8 + 24]
    call text_draw
    mov [rsp + 8 + 8 + 28], eax
    pop rbx
9:  ret

# ---------------- for the tests ----------------

# FN complete_dump(sb): "complete open=O items=N shown=S sel=I labels=A|B|..." and
# "signature open=O from=F to=T text=SIGNATURE"
FN complete_dump
    PROLOGUE
    mov r12, rdi
    mov rdi, r12
    lea rsi, [rip + .Ld_open]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rip + cp_open]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_items]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rip + cp_items + VEC_len]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_shown]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rip + cp_nshown]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_sel]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rip + cp_sel]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_labels]
    call sb_push_cstr
    xor ebx, ebx
1:  cmp ebx, [rip + cp_nshown]
    jae 2f
    test ebx, ebx
    jz 11f
    mov rdi, r12
    mov esi, '|'
    call sb_push_byte
11: lea rax, [rip + cp_shown]
    mov edi, [rax + rbx*4]
    call item
    mov rsi, [rax + CI_off]
    add rsi, [rip + cp_bytes + SB_ptr]
    mov edx, [rax + CI_llen]
    mov rdi, r12
    call sb_push
    inc ebx
    jmp 1b
2:  mov rdi, r12
    lea rsi, [rip + .Ld_sig]
    call sb_push_cstr
    mov rdi, r12
    mov esi, [rip + sg_open]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_from]
    call sb_push_cstr
    movsxd rax, dword ptr [rip + sg_from]
    test rax, rax
    jns 3f
    mov rdi, r12
    mov esi, '-'
    call sb_push_byte
    mov eax, 1
3:  mov rdi, r12
    mov esi, eax
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_to]
    call sb_push_cstr
    movsxd rax, dword ptr [rip + sg_to]
    test rax, rax
    jns 4f
    mov rdi, r12
    mov esi, '-'
    call sb_push_byte
    mov eax, 1
4:  mov rdi, r12
    mov esi, eax
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ld_text]
    call sb_push_cstr
    cmp dword ptr [rip + sg_open], 0
    je 5f
    mov rdi, r12
    mov rsi, [rip + sg_text + SB_ptr]
    mov rdx, [rip + sg_siglen]
    call sb_push
5:  mov rdi, r12
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.bss
.p2align 3
ae_n: .quad 0                   # the edits of the item being accepted: start end ptr len
ae_list: .zero 32 * AE_MAX

.section .rodata
.p2align 3
kind_names: .quad .Lck_text, .Lck_method, .Lck_function, .Lck_field, .Lck_variable, .Lck_class
    .quad .Lck_struct, .Lck_interface, .Lck_module, .Lck_property, .Lck_enum, .Lck_keyword
    .quad .Lck_snippet, .Lck_constant, .Lck_value, .Lck_file, .Lck_folder
# the badge's letter and color per kind
kind_letters: .ascii "t\0m\0f\0d\0v\0C\0S\0I\0M\0p\0E\0k\0s\0c\0V\0F\0D\0"
kind_colors: .byte T_MUTED, T_ICON + 5, T_ICON + 5, T_ICON + 4, T_ICON + 4, T_ICON + 1, T_ICON + 1
    .byte T_ICON + 7, T_ICON + 3, T_ICON + 4, T_ICON + 2, T_MUTED, T_ICON + 6, T_ICON + 2
    .byte T_ICON + 4, T_MUTED, T_MUTED
.Lck_text: .asciz "text"
.Lck_method: .asciz "method"
.Lck_function: .asciz "function"
.Lck_field: .asciz "field"
.Lck_variable: .asciz "variable"
.Lck_class: .asciz "class"
.Lck_struct: .asciz "struct"
.Lck_interface: .asciz "interface"
.Lck_module: .asciz "module"
.Lck_property: .asciz "property"
.Lck_enum: .asciz "enum"
.Lck_keyword: .asciz "keyword"
.Lck_snippet: .asciz "snippet"
.Lck_constant: .asciz "constant"
.Lck_value: .asciz "value"
.Lck_file: .asciz "file"
.Lck_folder: .asciz "folder"
.Lv_complete: .asciz "complete"
.Lv_signature: .asciz "signature"
.Lk_typed: .asciz "typed"
.Lk_trigger: .asciz "trigger"
.Lk_invoked: .asciz "invoked"
.Lk_incomplete: .asciz "incomplete"
.Lk_update: .asciz "update"
.Lx_edit: .asciz "edit"
.Lx_cursor: .asciz "cursor"
.Ld_open: .asciz "complete open="
.Ld_items: .asciz " items="
.Ld_shown: .asciz " shown="
.Ld_sel: .asciz " sel="
.Ld_labels: .asciz " labels="
.Ld_sig: .asciz "\nsignature open="
.Ld_from: .asciz " from="
.Ld_to: .asciz " to="
.Ld_text: .asciz " text="
