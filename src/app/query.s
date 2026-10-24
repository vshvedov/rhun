# The query engine of the language features (docs/extensions/v1.1.md, "Language feature queries"):
# every request rhun sends a provider is tracked here with its kind's limits, so answers, parts
# (query-part), progress reports (query-progress), expiry and withdrawal are counted per extension
# and kind. The askers (langfeat.s, complete.s, save.s) keep their own sessions; this file hands
# them the parts that arrive and tells them when a request expired (as an error answer). Also
# provider-scope's narrowed [provides] values, and the control commands that show all of it.
.include "rhun.inc"

.equ LATE_RING, 64              # withdrawn and expired requests remembered, to count late answers
.equ QP_TEXT_MAX, 200           # a progress report's text
.equ QR_ROOM, 64                # requests rhun waits on (v1 section 7), all extensions
.equ QR_ROOM_AUTO, 48           # automatic kinds wait while this many are out
.equ COLD_MS, 5000              # a request sent this soon after its program started is cold

# a pending request
STRUCT
F QR_ext, 8
F QR_id, 8
F QR_kind, 4                    # PK_*
F QR_owner, 4                   # QO_*
F QR_sent, 8                    # time_ms it went out
F QR_hard, 8                    # when it expires (0: the asker decides)
F QR_ceiling, 8                 # how far progress reports may move QR_hard
F QR_items, 8                   # records and bytes its parts brought
F QR_bytes, 8
F QR_pct, 4                     # the last progress report's percent, -1 none
F QR_flags, 4                   # QF_*
F QR_text, 8                    # owned cstr: the last progress report's text, or 0
ENDSTRUCT QR_SIZE
.equ QF_COLD, 1
.equ QF_TRUNC, 2                # the Query cap cut it short
.equ QF_PART, 4                 # a part arrived

# a kind (pk_table)
STRUCT
F PKR_name, 8                   # the verb, as statistics name it
F PKR_pv, 8                     # EXT offset of its [provides] key, 0 for none
F PKR_show, 4                   # presentation target, ms (0: when every provider answered)
F PKR_base, 4                   # hard limit, ms after sending (0: the asker's own)
F PKR_ceil, 4                   # how far progress reports may move it
F PKR_flags, 4                  # PKF_*
F PKR_items, 4                  # an answer's or part's cap: records, bytes
F PKR_bytes, 4
F PKR_qitems, 4                 # the query's cap with its parts
F PKR_qbytes, 4
ENDSTRUCT PKR_SIZE
.equ PKF_PARTS, 1               # query-part may stream its answer
.equ PKF_SILENT, 2              # never shows progress or a toast
.equ PKF_FIRST, 4               # shown at its first part
.equ PKF_SUB, 8                 # another kind's key (the Extensions page lists it once asked)

# a kind's statistics for one extension
STRUCT
F QS_asked, 8
F QS_cold, 8
F QS_answered, 8
F QS_empty, 8
F QS_failed, 8
F QS_expired, 8
F QS_late, 8
F QS_dropped, 8
F QS_cancelled, 8
F QS_total, 8                   # ms, over the answered, empty and failed ones
F QS_max, 8
ENDSTRUCT QS_SIZE

# a narrowed [provides] value (provider-scope)
STRUCT
F QSC_off, 8                     # EXT offset of the key's field
F QSC_val, 8                     # owned cstr; "" when the kind is withdrawn
ENDSTRUCT QSC_SIZE

.bss
.p2align 3
qr_vec: .zero VEC_SIZE          # QR records
late_ring: .zero LATE_RING * 24 # ext, id, kind
late_next: .quad 0
qp_buf: .zero SB_SIZE           # a value being built
q_room_items: .quad 0           # query_final_room's answer for the reply being read (query_reply
q_room_bytes: .quad 0           # sets them before any asker reads)

.text

# ---------------- kinds and statistics ----------------

# FN query_kind_row(kind) -> rax PKR*
FN query_kind_row
    imul rax, rdi, PKR_SIZE
    lea rcx, [rip + pk_table]
    add rax, rcx
    ret

# FN query_kind_first(kind) -> eax 1 for a kind shown at its first part (references, implementation)
FN query_kind_first
    call query_kind_row
    mov eax, [rax + PKR_flags]
    shr eax, 2                  # PKF_FIRST
    and eax, 1
    ret

# qs_rec(ext, kind) -> rax its QS record (the extension's records are made on first use)
qs_rec:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + EXT_qstats]
    test rax, rax
    jnz 1f
    mov edi, PK_COUNT * QS_SIZE
    call mem_alloc
    mov [rbx + EXT_qstats], rax
1:  imul rcx, r12, QS_SIZE
    add rax, rcx
    EPILOGUE

# qs_count(ext, kind, field): one more
qs_count:
    push rbx
    mov rbx, rdx
    call qs_rec
    inc qword ptr [rax + rbx]
    pop rbx
    ret

# qs_time(ext, kind, ms): an answer's time joins the average and the slowest
qs_time:
    push rbx
    mov rbx, rdx
    call qs_rec
    add [rax + QS_total], rbx
    cmp rbx, [rax + QS_max]
    jbe 1f
    mov [rax + QS_max], rbx
1:  pop rbx
    ret

# FN query_dropped(ext, kind): an answer or part broke its kind's rules or caps and was dropped
FN query_dropped
    mov edx, QS_dropped
    jmp qs_count

# ---------------- pending requests ----------------

# FN query_track(ext, id, kind, owner): a request just sent, from now on under its kind's limits
FN query_track
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    test r12, r12
    jz 9f
    lea rdi, [rip + qr_vec]
    mov esi, QR_SIZE
    call vec_push
    mov r15, rax
    mov [r15 + QR_ext], rbx
    mov [r15 + QR_id], r12
    mov [r15 + QR_kind], r13d
    mov [r15 + QR_owner], r14d
    mov dword ptr [r15 + QR_pct], -1
    call time_ms
    mov [r15 + QR_sent], rax
    mov edi, r13d
    push rax
    push rax
    call query_kind_row
    mov rcx, rax
    pop rax
    pop rax
    mov edx, [rcx + PKR_base]
    test edx, edx
    jz 2f
    lea rdx, [rax + rdx]
    mov [r15 + QR_hard], rdx
    mov [r15 + QR_ceiling], rdx
    mov edx, [rcx + PKR_ceil]
    test edx, edx
    jz 2f
    lea rdx, [rax + rdx]
    mov [r15 + QR_ceiling], rdx
2:  sub rax, [rbx + EXT_started]
    cmp rax, COLD_MS
    jae 3f
    or dword ptr [r15 + QR_flags], QF_COLD
    mov rdi, rbx
    mov esi, r13d
    mov edx, QS_cold
    call qs_count
3:  mov rdi, rbx
    mov esi, r13d
    mov edx, QS_asked
    call qs_count
9:  EPILOGUE

# qr_find(ext, id) -> rax QR* or 0 (valid until the next track or removal)
qr_find:
    mov rcx, [rip + qr_vec + VEC_len]
    mov rax, [rip + qr_vec + VEC_ptr]
1:  test rcx, rcx
    jz 8f
    cmp [rax + QR_ext], rdi
    jne 2f
    cmp [rax + QR_id], rsi
    je 9f
2:  add rax, QR_SIZE
    dec rcx
    jmp 1b
8:  xor eax, eax
9:  ret

# FN query_pending(ext, id) -> eax 1 while rhun still waits on that request
FN query_pending
    call qr_find
    test rax, rax
    setnz al
    movzx eax, al
    ret

# qr_remove(QR*): it goes; the last record takes its place
qr_remove:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + QR_text]
    call mem_free
    mov rax, [rip + qr_vec + VEC_len]
    dec rax
    mov [rip + qr_vec + VEC_len], rax
    imul rsi, rax, QR_SIZE
    add rsi, [rip + qr_vec + VEC_ptr]
    cmp rsi, rbx
    je 9f
    mov rdi, rbx
    mov edx, QR_SIZE
    call memcpy
9:  pop rbx
    ret

# late_add(ext, id, kind): an answer may still come; it will be counted late and dropped
late_add:
    mov rax, [rip + late_next]
    inc qword ptr [rip + late_next]
    and eax, LATE_RING - 1
    imul rax, rax, 24
    lea rcx, [rip + late_ring]
    add rax, rcx
    mov [rax], rdi
    mov [rax + 8], rsi
    mov [rax + 16], rdx
    ret

# late_take(ext, id) -> rax kind + 1 when it was withdrawn or expired (forgotten now), 0 otherwise
late_take:
    lea rax, [rip + late_ring]
    xor ecx, ecx
1:  cmp [rax], rdi
    jne 2f
    cmp [rax + 8], rsi
    jne 2f
    mov qword ptr [rax], 0
    mov rax, [rax + 16]
    inc rax
    ret
2:  add rax, 24
    inc ecx
    cmp ecx, LATE_RING
    jb 1b
    xor eax, eax
    ret

# FN query_final_room() -> rax the records, rdx the bytes a final answer may still bring after its
# parts (the query's caps less what the parts brought), -1 each without parts; valid while the
# askers read the answer query_reply just counted
FN query_final_room
    mov rax, [rip + q_room_items]
    mov rdx, [rip + q_room_bytes]
    ret

# body_empty(body, len, kind) -> eax 1 for an answer that says nothing: no bytes, or (for kinds whose
# answer starts with a count) a count of 0
body_empty:
    test rsi, rsi
    jz 1f
    cmp edx, PK_SIGNATURE       # these start with other numbers: only no bytes says nothing
    je 8f
    cmp edx, PK_HOVER
    je 8f
    cmp edx, PK_PREPARE_RENAME
    je 8f
    cmp edx, PK_RESOLVE
    je 8f
    cmp edx, PK_ACTION_RESOLVE
    je 8f
    cmp byte ptr [rdi], '0'
    jne 8f
    cmp rsi, 1
    je 1f
    movzx eax, byte ptr [rdi + 1]
    cmp eax, 10
    je 1f
    cmp eax, ' '
    je 1f
8:  xor eax, eax
    ret
1:  mov eax, 1
    ret

# FN query_reply(ext, id, ok, body, len) -> eax 1 when the answer comes after rhun withdrew the
# request or it expired: counted late, and nobody else hears of it. Otherwise it is counted and
# eax is 0 (the asker reads it). From extproto's pump, before the askers.
FN query_reply
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
    mov qword ptr [rip + q_room_items], -1
    mov qword ptr [rip + q_room_bytes], -1
    call qr_find
    test rax, rax
    jz .Lqrp_late
    mov [rsp], rax
    call time_ms
    mov rcx, [rsp]
    sub rax, [rcx + QR_sent]
    mov [rsp + 8], rax
    mov rax, [rcx + QR_items]
    mov [rsp + 16], rax         # what its parts brought
    # after parts, the final answer still counts toward the query's caps (query_final_room)
    test dword ptr [rcx + QR_flags], QF_PART
    jz 1f
    mov edi, [rcx + QR_kind]
    call query_kind_row
    mov rcx, [rsp]
    mov edx, [rax + PKR_qitems]
    sub rdx, [rcx + QR_items]
    jns 11f
    xor edx, edx
11: mov [rip + q_room_items], rdx
    mov edx, [rax + PKR_qbytes]
    sub rdx, [rcx + QR_bytes]
    jns 12f
    xor edx, edx
12: mov [rip + q_room_bytes], rdx
1:  mov eax, [rcx + QR_kind]
    mov [rsp], rax
    mov rdi, rcx
    call qr_remove
    mov edx, QS_failed
    test r13d, r13d
    jz 2f
    mov edx, QS_answered
    cmp qword ptr [rsp + 16], 0
    jne 2f                      # its parts brought records: answered, whatever the rest says
    mov rdi, r14
    mov rsi, r15
    mov edx, [rsp]
    call body_empty
    mov edx, QS_empty
    test eax, eax
    jnz 2f
    mov edx, QS_answered
2:  mov rdi, rbx
    mov rsi, [rsp]
    call qs_count
    mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call qs_time
    xor eax, eax
    EPILOGUE
.Lqrp_late:
    mov rdi, rbx
    mov rsi, r12
    call late_take
    test rax, rax
    jz 8f
    lea rsi, [rax - 1]
    mov rdi, rbx
    mov edx, QS_late
    call qs_count
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN query_withdraw(ext, id): rhun no longer wants the answer: "0 cancel ID", counted cancelled
FN query_withdraw
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call qr_find
    test rax, rax
    jz 1f
    mov r13d, [rax + QR_kind]
    mov rdi, rax
    call qr_remove
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call late_add
    mov rdi, rbx
    mov esi, r13d
    mov edx, QS_cancelled
    call qs_count
1:  cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 9f
    mov rdi, rbx
    mov rsi, r12
    call extproto_send_cancel
9:  EPILOGUE

# FN query_room(automatic) -> eax 1 when another request may go out: rhun waits on at most 64,
# and automatic kinds (hover, lightbulb, links, resolve, Outline) leave the last 16 to the user
FN query_room
    mov ecx, QR_ROOM
    test edi, edi
    jz 1f
    mov ecx, QR_ROOM_AUTO
1:  xor eax, eax
    cmp [rip + qr_vec + VEC_len], rcx
    setb al
    ret

# FN query_ext_gone(ext): its program ended: its requests and narrowed values go (the askers
# forget their own state in their ext_gone handlers)
FN query_ext_gone
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + qr_vec + VEC_len]
    jae 2f
    imul rdi, r12, QR_SIZE
    add rdi, [rip + qr_vec + VEC_ptr]
    cmp [rdi + QR_ext], rbx
    jne 11f
    call qr_remove
    jmp 1b
11: inc r12
    jmp 1b
2:  lea rax, [rip + late_ring]
    xor ecx, ecx
3:  cmp [rax], rbx
    jne 31f
    mov qword ptr [rax], 0
31: add rax, 24
    inc ecx
    cmp ecx, LATE_RING
    jb 3b
    # provider-scope lasts until the process stops
    xor r12d, r12d
4:  cmp r12, [rbx + EXT_scope + VEC_len]
    jae 5f
    imul rax, r12, QSC_SIZE
    add rax, [rbx + EXT_scope + VEC_ptr]
    mov rdi, [rax + QSC_val]
    call mem_free
    inc r12
    jmp 4b
5:  mov qword ptr [rbx + EXT_scope + VEC_len], 0
    EPILOGUE

# FN query_tick(): requests past their hard limit expire: "0 cancel ID", and the asker hears an
# error answer (an empty one)
FN query_tick
    PROLOGUE 16
    call time_ms
    mov r15, rax
.Lqt_scan:
    xor r12d, r12d
1:  cmp r12, [rip + qr_vec + VEC_len]
    jae 9f
    imul rdi, r12, QR_SIZE
    add rdi, [rip + qr_vec + VEC_ptr]
    inc r12
    mov rax, [rdi + QR_hard]
    test rax, rax
    jz 1b
    cmp r15, rax
    jb 1b
    mov rbx, [rdi + QR_ext]
    mov r13, [rdi + QR_id]
    mov r14d, [rdi + QR_kind]
    mov eax, [rdi + QR_owner]
    mov [rsp], rax
    call qr_remove
    mov rdi, rbx
    mov rsi, r13
    mov edx, r14d
    call late_add
    mov rdi, rbx
    mov esi, r14d
    mov edx, QS_expired
    call qs_count
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 2f
    mov rdi, rbx
    mov rsi, r13
    call extproto_send_cancel
2:  mov rax, [rsp]
    lea rcx, [rip + qo_reply]
    mov rax, [rcx + rax*8]
    test rax, rax
    jz .Lqt_scan
    mov rdi, rbx
    mov rsi, r13
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call rax
    mov dword ptr [rip + g_dirty], 1
    jmp .Lqt_scan               # the asker may have withdrawn others meanwhile
9:  EPILOGUE

# FN query_timeout() -> ms until the next request expires, or -1
FN query_timeout
    PROLOGUE
    mov rbx, -1
    call time_ms
    mov r12, rax
    xor ecx, ecx
1:  cmp rcx, [rip + qr_vec + VEC_len]
    jae 9f
    imul rax, rcx, QR_SIZE
    add rax, [rip + qr_vec + VEC_ptr]
    inc rcx
    mov rax, [rax + QR_hard]
    test rax, rax
    jz 1b
    sub rax, r12
    jns 2f
    xor eax, eax
2:  cmp rbx, -1
    je 3f
    cmp rax, rbx
    jae 1b
3:  mov rbx, rax
    jmp 1b
9:  mov rax, rbx
    EPILOGUE

# FN query_progress_of(owner) -> rax the QR* of that asker's slowest pending request that has
# reported progress (its percent in QR_pct, its text in QR_text), or 0
FN query_progress_of
    mov rcx, [rip + qr_vec + VEC_len]
    mov rdx, [rip + qr_vec + VEC_ptr]
    xor eax, eax
1:  test rcx, rcx
    jz 9f
    cmp [rdx + QR_owner], edi
    jne 2f
    cmp dword ptr [rdx + QR_pct], -1
    jne 3f
    cmp qword ptr [rdx + QR_text], 0
    je 2f
3:  test rax, rax
    jz 4f
    mov r8d, [rdx + QR_pct]
    cmp r8d, [rax + QR_pct]
    jae 2f
4:  mov rax, rdx
2:  add rdx, QR_SIZE
    dec rcx
    jmp 1b
9:  ret

# FN query_progress_label(sb): " NAME PCT% TEXT" of the language features' slowest request with a
# progress report (the Results tab's title while it searches), nothing without one
FN query_progress_label
    PROLOGUE
    mov rbx, rdi
    mov edi, QO_LANGFEAT
    call query_progress_of
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, [r12 + QR_ext]
    call ext_full_name
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov eax, [r12 + QR_pct]
    cmp eax, -1
    je 1f
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, [r12 + QR_pct]
    call sb_push_u64
    mov rdi, rbx
    mov esi, '%'
    call sb_push_byte
1:  mov rsi, [r12 + QR_text]
    test rsi, rsi
    jz 9f
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r12 + QR_text]
    call sb_push_cstr
9:  EPILOGUE

# ---------------- query-stream (extension requests) ----------------

# qp_agreed(FEAT_*) -> eax 1 when cur agreed that feature; otherwise "unknown" is answered
qp_agreed:
    push rbx
    mov ebx, edi
    call extproto_cur
    mov rdi, rax
    mov esi, ebx
    call ext_feature
    test eax, eax
    jnz 1f
    call extproto_req_id
    mov rdi, rax
    lea rsi, [rip + .Le_unknown]
    call extproto_error
    xor eax, eax
    pop rbx
    ret
1:  mov eax, 1
    pop rbx
    ret

# qp_error(cstr): the reply to the request being handled
qp_error:
    push rdi
    call extproto_req_id
    pop rsi
    mov rdi, rax
    jmp extproto_error

# FN query_h_part(): ID query-part REQ LEN + a part of REQ's answer, in its answer's grammar
FN query_h_part
    PROLOGUE 16
    mov edi, FEAT_QUERY_STREAM
    call qp_agreed
    test eax, eax
    jz 9f
    call extproto_cur
    mov rbx, rax
    call extproto_nfields
    cmp rax, 4
    jne .Lqhp_syntax
    mov edi, 2
    call extproto_field
    test edx, edx
    jz .Lqhp_syntax
    mov r12, rax
    call extproto_body
    mov r13, rax
    mov r14, rdx
    mov rdi, rbx
    mov rsi, r12
    call qr_find
    test rax, rax
    jz .Lqhp_cancelled
    mov r15, rax
    mov edi, [r15 + QR_kind]
    mov [rsp], rdi
    call query_kind_row
    test dword ptr [rax + PKR_flags], PKF_PARTS
    jz .Lqhp_refused
    mov ecx, [rax + PKR_bytes]
    cmp r14, rcx
    ja .Lqhp_drop               # over an answer's cap
    mov rcx, [r15 + QR_bytes]
    add rcx, r14
    mov edx, [rax + PKR_qbytes]
    cmp rcx, rdx
    ja .Lqhp_toobig
    mov eax, [r15 + QR_owner]
    lea rcx, [rip + qo_part]
    mov rax, [rcx + rax*8]
    test rax, rax
    jz .Lqhp_refused
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call rax                    # -> records taken, or -1 when the part breaks the rules
    test rax, rax
    js .Lqhp_drop
    mov r15, rax
    mov rdi, rbx
    mov rsi, r12
    call qr_find                # the asker may have moved the records
    test rax, rax
    jz .Lqhp_ok
    or dword ptr [rax + QR_flags], QF_PART
    add [rax + QR_items], r15
    add [rax + QR_bytes], r14
    mov r15, rax
    mov edi, [r15 + QR_kind]
    call query_kind_row
    mov ecx, [rax + PKR_qitems]
    cmp [r15 + QR_items], rcx
    ja .Lqhp_toobig
.Lqhp_ok:
    mov dword ptr [rip + g_dirty], 1
    call extproto_req_id
    mov rdi, rax
    call extproto_ok
9:  EPILOGUE
.Lqhp_syntax:
    lea rdi, [rip + .Le_syntax]
    call qp_error
    EPILOGUE
.Lqhp_cancelled:
    lea rdi, [rip + .Le_cancelled]
    call qp_error
    EPILOGUE
.Lqhp_refused:
    lea rdi, [rip + .Le_no_parts]
    call qp_error
    EPILOGUE
.Lqhp_drop:
    mov rdi, rbx
    mov rsi, [rsp]
    call query_dropped
    lea rdi, [rip + .Le_part_dropped]
    call qp_error
    EPILOGUE
.Lqhp_toobig:
    # the Query cap: rhun keeps what it has, withdraws REQ and the asker finishes with that
    or dword ptr [r15 + QR_flags], QF_TRUNC
    mov eax, [r15 + QR_owner]
    mov [rsp + 8], rax
    lea rdi, [rip + .Le_toobig]
    call qp_error
    mov rdi, rbx
    mov rsi, r12
    call query_withdraw
    mov rax, [rsp + 8]
    lea rcx, [rip + qo_trunc]
    mov rax, [rcx + rax*8]
    test rax, rax
    jz 1f
    mov rdi, rbx
    mov rsi, r12
    call rax
1:  mov rax, [rsp + 8]
    lea rcx, [rip + qo_reply]
    mov rax, [rcx + rax*8]
    test rax, rax
    jz 9b
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call rax
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN query_h_progress(): ID query-progress REQ PERCENT LEN + one line: how far REQ has come; it
# moves REQ's hard limit to now + its kind's base, up to its ceiling
FN query_h_progress
    PROLOGUE 16
    mov edi, FEAT_QUERY_STREAM
    call qp_agreed
    test eax, eax
    jz 9f
    call extproto_cur
    mov rbx, rax
    call extproto_nfields
    cmp rax, 5
    jne .Lqhg_syntax
    mov edi, 2
    call extproto_field
    test edx, edx
    jz .Lqhg_syntax
    mov r12, rax
    # PERCENT: 0 to 100, or - for none
    mov r13, -1
    mov edi, 3
    call extproto_field_at
    cmp rdx, 1
    jne 1f
    cmp byte ptr [rax], '-'
    je 2f
1:  mov edi, 3
    call extproto_field
    test edx, edx
    jz .Lqhg_syntax
    cmp rax, 100
    ja .Lqhg_syntax
    mov r13, rax
2:  call extproto_body
    mov r14, rax
    mov r15, rdx
    cmp r15, QP_TEXT_MAX
    ja .Lqhg_syntax
    xor ecx, ecx
3:  cmp rcx, r15
    jae 4f
    movzx eax, byte ptr [r14 + rcx]
    inc rcx
    cmp eax, 10
    je .Lqhg_syntax
    cmp eax, 13
    je .Lqhg_syntax
    test eax, eax
    jz .Lqhg_syntax
    jmp 3b
4:  mov rdi, rbx
    mov rsi, r12
    call qr_find
    test rax, rax
    jz .Lqhg_cancelled
    mov [rsp], rax
    mov [rax + QR_pct], r13d
    mov rdi, [rax + QR_text]
    call mem_free
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov rcx, [rsp]
    mov [rcx + QR_text], rax
    # a sign of life: the hard limit moves on
    cmp qword ptr [rcx + QR_hard], 0
    je 6f
    mov edi, [rcx + QR_kind]
    call query_kind_row
    mov r13d, [rax + PKR_base]
    call time_ms
    add rax, r13
    mov rcx, [rsp]
    cmp rax, [rcx + QR_ceiling]
    jbe 5f
    mov rax, [rcx + QR_ceiling]
5:  cmp rax, [rcx + QR_hard]
    jbe 6f
    mov [rcx + QR_hard], rax
6:  mov dword ptr [rip + g_dirty], 1
    call extproto_req_id
    mov rdi, rax
    call extproto_ok
9:  EPILOGUE
.Lqhg_syntax:
    lea rdi, [rip + .Le_syntax]
    call qp_error
    EPILOGUE
.Lqhg_cancelled:
    lea rdi, [rip + .Le_cancelled]
    call qp_error
    EPILOGUE

# ---------------- provider-scope ----------------

# FN ext_pv(ext, offset) -> rax the [provides] value in force for the key at that EXT offset: the
# extension's narrowed one, else the manifest's; 0 when it has none or withdrew it
FN ext_pv
    mov rax, [rdi + EXT_scope + VEC_len]
    mov rcx, [rdi + EXT_scope + VEC_ptr]
1:  test rax, rax
    jz 8f
    cmp [rcx + QSC_off], rsi
    je 2f
    add rcx, QSC_SIZE
    dec rax
    jmp 1b
8:  mov rax, [rdi + rsi]
    ret
2:  mov rax, [rcx + QSC_val]
    cmp byte ptr [rax], 0
    jne 3f
    xor eax, eax
3:  ret

# pv_key(ptr, len) -> rax the EXT offset of that [provides] key, or 0
pv_key:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + ext_pv_keys]
1:  mov rdx, [rbx]
    test rdx, rdx
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add rbx, 16
    jmp 1b
2:  mov rax, [rbx + 8]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# has_word(list cstr, ptr, len) -> eax 1 when the space-separated list holds that word
has_word:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test rbx, rbx
    jz 8f
1:  cmp byte ptr [rbx], 0
    je 8f
    cmp byte ptr [rbx], ' '
    jne 2f
    inc rbx
    jmp 1b
2:  xor r14d, r14d
3:  movzx eax, byte ptr [rbx + r14]
    test eax, eax
    jz 4f
    cmp eax, ' '
    je 4f
    inc r14
    jmp 3b
4:  mov rdi, rbx
    mov rsi, r14
    mov rdx, r12
    mov rcx, r13
    call str_eq
    test eax, eax
    jnz 9f
    add rbx, r14
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# scope_set(ext, offset, value cstr owned or 0): the narrowed value (0: the manifest's again)
scope_set:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, [rbx + EXT_scope + VEC_len]
    jae 3f
    imul r15, r14, QSC_SIZE
    add r15, [rbx + EXT_scope + VEC_ptr]
    cmp [r15 + QSC_off], r12
    je 2f
    inc r14
    jmp 1b
2:  mov rdi, [r15 + QSC_val]
    call mem_free
    test r13, r13
    jz 21f
    mov [r15 + QSC_val], r13
    jmp 9f
21: # the last record takes its place
    mov rax, [rbx + EXT_scope + VEC_len]
    dec rax
    mov [rbx + EXT_scope + VEC_len], rax
    imul rax, rax, QSC_SIZE
    add rax, [rbx + EXT_scope + VEC_ptr]
    mov rcx, [rax]
    mov [r15], rcx
    mov rcx, [rax + 8]
    mov [r15 + 8], rcx
    jmp 9f
3:  test r13, r13
    jz 9f
    lea rdi, [rbx + EXT_scope]
    mov esi, QSC_SIZE
    call vec_push
    mov [rax + QSC_off], r12
    mov [rax + QSC_val], r13
9:  EPILOGUE

# FN query_h_provides(): ID provides KEY VALUES: until the process stops, KEY's values are VALUES
# (a subset of the manifest's own, each written as there), * the manifest's again, - none
FN query_h_provides
    PROLOGUE 16
    mov edi, FEAT_PROVIDER_SCOPE
    call qp_agreed
    test eax, eax
    jz 9f
    call extproto_cur
    mov rbx, rax
    call extproto_nfields
    cmp rax, 4
    jb .Lqhv_syntax
    mov edi, 2
    call extproto_field_at
    mov rdi, rax
    mov rsi, rdx
    call pv_key
    test rax, rax
    jz .Lqhv_syntax
    mov r12, rax
    mov edi, 3
    call extproto_rest
    mov r13, rax
    mov r14, rdx
    # trailing blanks are not values
1:  test r14, r14
    jz .Lqhv_syntax
    cmp byte ptr [r13 + r14 - 1], ' '
    jne 2f
    dec r14
    jmp 1b
2:  cmp r14, 1
    jne 4f
    cmp byte ptr [r13], '*'
    jne 3f
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call scope_set
    jmp .Lqhv_ok
3:  cmp byte ptr [r13], '-'
    jne 4f
    lea rdi, [rip + .Lempty]
    xor esi, esi
    call mem_dup
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call scope_set
    jmp .Lqhv_ok
4:  # each value one of the manifest's own
    xor r15d, r15d
5:  cmp r15, r14
    jae 7f
    cmp byte ptr [r13 + r15], ' '
    jne 51f
    inc r15
    jmp 5b
51: mov [rsp], r15
6:  cmp r15, r14
    jae 61f
    cmp byte ptr [r13 + r15], ' '
    je 61f
    inc r15
    jmp 6b
61: mov rdi, [rbx + r12]
    mov rsi, [rsp]
    lea rsi, [r13 + rsi]
    mov rdx, r15
    sub rdx, [rsp]
    call has_word
    test eax, eax
    jz .Lqhv_refused
    jmp 5b
7:  mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call scope_set
.Lqhv_ok:
    cmp r12, EXT_pv_definition
    jne 8f
    call definitionlink_ext_gone   # a cached confirmation cannot outlive its capability
8:
    mov dword ptr [rip + g_dirty], 1
    call extproto_req_id
    mov rdi, rax
    call extproto_ok
9:  EPILOGUE
.Lqhv_syntax:
    lea rdi, [rip + .Le_syntax]
    call qp_error
    EPILOGUE
.Lqhv_refused:
    lea rdi, [rip + .Le_not_manifest]
    call qp_error
    EPILOGUE

# ---------------- what the control commands show ----------------

# FN query_dump_stats(sb, ext or 0): "owner/name KIND asked=N cold=N answered=N empty=N failed=N
# expired=N late=N dropped=N cancelled=N avg=MS max=MS" for each kind an extension was asked
FN query_dump_stats
    PROLOGUE 16
    mov r14, rdi
    mov [rsp], rsi
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp qword ptr [rsp], 0
    je 2f
    cmp rbx, [rsp]
    jne 1b
2:  cmp qword ptr [rbx + EXT_qstats], 0
    je 1b
    xor r13d, r13d
3:  cmp r13, PK_COUNT
    jae 1b
    imul r15, r13, QS_SIZE
    add r15, [rbx + EXT_qstats]
    mov rax, [r15 + QS_asked]
    or rax, [r15 + QS_late]
    jz 8f
    mov rdi, rbx
    call ext_full_name
    mov rdi, r14
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r14
    mov esi, ' '
    call sb_push_byte
    mov edi, r13d
    call query_kind_row
    mov rdi, r14
    mov rsi, [rax + PKR_name]
    call sb_push_cstr
    xor ecx, ecx
4:  lea rax, [rip + qs_names]
    mov rsi, [rax + rcx*8]
    test rsi, rsi
    jz 5f
    mov [rsp + 8], rcx
    mov rdi, r14
    call sb_push_cstr
    mov rcx, [rsp + 8]
    mov rdi, r14
    mov rsi, [r15 + rcx*8]
    call sb_push_u64
    mov rcx, [rsp + 8]
    inc rcx
    jmp 4b
5:  # the average over what was answered
    mov rdi, r14
    lea rsi, [rip + .Ls_avg]
    call sb_push_cstr
    mov rcx, [r15 + QS_answered]
    add rcx, [r15 + QS_empty]
    add rcx, [r15 + QS_failed]
    xor eax, eax
    test rcx, rcx
    jz 6f
    mov rax, [r15 + QS_total]
    xor edx, edx
    div rcx
6:  mov rdi, r14
    mov rsi, rax
    call sb_push_u64
    mov rdi, r14
    lea rsi, [rip + .Ls_max]
    call sb_push_cstr
    mov rdi, r14
    mov rsi, [r15 + QS_max]
    call sb_push_u64
    mov rdi, r14
    mov esi, 10
    call sb_push_byte
8:  inc r13
    jmp 3b
9:  EPILOGUE

# FN query_kind_warn(ext, kind) -> eax 1 when the kind's numbers deserve the warning color: an
# average over a second, or failing or expiring on more than 10% of at least 10 requests
FN query_kind_warn
    PROLOGUE
    cmp qword ptr [rdi + EXT_qstats], 0
    je 8f
    imul rbx, rsi, QS_SIZE
    add rbx, [rdi + EXT_qstats]
    mov rcx, [rbx + QS_answered]
    add rcx, [rbx + QS_empty]
    add rcx, [rbx + QS_failed]
    test rcx, rcx
    jz 1f
    mov rax, [rbx + QS_total]
    xor edx, edx
    div rcx
    cmp rax, 1000
    ja 7f
1:  mov rcx, [rbx + QS_asked]
    cmp rcx, 10
    jb 8f
    mov rax, [rbx + QS_failed]
    add rax, [rbx + QS_expired]
    imul rax, rax, 10
    cmp rax, rcx
    ja 7f
8:  xor eax, eax
    EPILOGUE
7:  mov eax, 1
    EPILOGUE

# FN query_kind_label(ext, kind, sb) -> eax 1 when the Extensions page lists the kind (its
# [provides] key is in force, or it was asked): "name  patterns" into sb (cleared, a cstr)
FN query_kind_label
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov rdi, r13
    call sb_clear
    mov edi, r12d
    call query_kind_row
    mov r14, rax
    xor r15d, r15d              # its patterns in force
    mov rsi, [r14 + PKR_pv]
    test rsi, rsi
    jz 1f
    mov rdi, rbx
    call ext_pv
    mov r15, rax
1:  test r15, r15
    jz 2f
    test dword ptr [r14 + PKR_flags], PKF_SUB
    jz 3f
2:  cmp qword ptr [rbx + EXT_qstats], 0
    je 8f
    imul rax, r12, QS_SIZE
    add rax, [rbx + EXT_qstats]
    cmp qword ptr [rax + QS_asked], 0
    je 8f
3:  mov rdi, r13
    mov rsi, [r14 + PKR_name]
    call sb_push_cstr
    test r15, r15
    jz 4f
    mov rdi, r13
    lea rsi, [rip + .Ls_two]
    call sb_push_cstr
    mov rdi, r13
    mov rsi, r15
    call sb_push_cstr
4:  mov rdi, r13
    xor esi, esi
    call sb_push_byte
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN query_kind_numbers(ext, kind, sb): "N asked, AVG ms" and the failed and expired ones, or "not
# asked yet", into sb (cleared, a cstr)
FN query_kind_numbers
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov rdi, r13
    call sb_clear
    cmp qword ptr [rbx + EXT_qstats], 0
    je 7f
    imul r14, r12, QS_SIZE
    add r14, [rbx + EXT_qstats]
    cmp qword ptr [r14 + QS_asked], 0
    je 7f
    mov rdi, r13
    mov rsi, [r14 + QS_asked]
    call sb_push_u64
    mov rdi, r13
    lea rsi, [rip + .Ls_n_asked]
    call sb_push_cstr
    mov rcx, [r14 + QS_answered]
    add rcx, [r14 + QS_empty]
    add rcx, [r14 + QS_failed]
    xor eax, eax
    test rcx, rcx
    jz 1f
    mov rax, [r14 + QS_total]
    xor edx, edx
    div rcx
1:  mov rdi, r13
    mov rsi, rax
    call sb_push_u64
    mov rdi, r13
    lea rsi, [rip + .Ls_n_ms]
    call sb_push_cstr
    mov rsi, [r14 + QS_failed]
    test rsi, rsi
    jz 2f
    mov rdi, r13
    lea rsi, [rip + .Ls_n_sep]
    call sb_push_cstr
    mov rdi, r13
    mov rsi, [r14 + QS_failed]
    call sb_push_u64
    mov rdi, r13
    lea rsi, [rip + .Ls_n_failed]
    call sb_push_cstr
2:  mov rsi, [r14 + QS_expired]
    test rsi, rsi
    jz 8f
    mov rdi, r13
    lea rsi, [rip + .Ls_n_sep]
    call sb_push_cstr
    mov rdi, r13
    mov rsi, [r14 + QS_expired]
    call sb_push_u64
    mov rdi, r13
    lea rsi, [rip + .Ls_n_expired]
    call sb_push_cstr
    jmp 8f
7:  mov rdi, r13
    lea rsi, [rip + .Ls_n_never]
    call sb_push_cstr
8:  mov rdi, r13
    xor esi, esi
    call sb_push_byte
    EPILOGUE

# FN query_dump_provides(sb, ext): "KEY = VALUES" for each [provides] key in force
FN query_dump_provides
    PROLOGUE
    mov r14, rdi
    mov r13, rsi
    lea rbx, [rip + ext_pv_keys]
1:  cmp qword ptr [rbx], 0
    je 9f
    mov rdi, r13
    mov rsi, [rbx + 8]
    call ext_pv
    test rax, rax
    jz 2f
    mov r12, rax
    mov rdi, r14
    mov rsi, [rbx]
    call sb_push_cstr
    mov rdi, r14
    lea rsi, [rip + .Ls_equals]
    call sb_push_cstr
    mov rdi, r14
    mov rsi, r12
    call sb_push_cstr
    mov rdi, r14
    mov esi, 10
    call sb_push_byte
2:  add rbx, 16
    jmp 1b
9:  EPILOGUE

# FN query_dump_pending(sb): "owner/name ID KIND pct=N items=N text=T" per request rhun waits on
FN query_dump_pending
    PROLOGUE
    mov r14, rdi
    xor r12d, r12d
1:  cmp r12, [rip + qr_vec + VEC_len]
    jae 9f
    imul rbx, r12, QR_SIZE
    add rbx, [rip + qr_vec + VEC_ptr]
    inc r12
    mov rdi, [rbx + QR_ext]
    call ext_full_name
    mov rdi, r14
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r14
    mov esi, ' '
    call sb_push_byte
    mov rdi, r14
    mov rsi, [rbx + QR_id]
    call sb_push_u64
    mov rdi, r14
    mov esi, ' '
    call sb_push_byte
    mov edi, [rbx + QR_kind]
    call query_kind_row
    mov rdi, r14
    mov rsi, [rax + PKR_name]
    call sb_push_cstr
    mov rdi, r14
    lea rsi, [rip + .Ls_pct]
    call sb_push_cstr
    movsxd rsi, dword ptr [rbx + QR_pct]
    test rsi, rsi
    jns 2f
    mov rdi, r14
    mov esi, '-'
    call sb_push_byte
    jmp 3f
2:  mov rdi, r14
    call sb_push_u64
3:  mov rdi, r14
    lea rsi, [rip + .Ls_items]
    call sb_push_cstr
    mov rdi, r14
    mov rsi, [rbx + QR_items]
    call sb_push_u64
    test dword ptr [rbx + QR_flags], QF_TRUNC
    jz 4f
    mov rdi, r14
    lea rsi, [rip + .Ls_trunc]
    call sb_push_cstr
4:  mov rdi, r14
    lea rsi, [rip + .Ls_text]
    call sb_push_cstr
    mov rsi, [rbx + QR_text]
    test rsi, rsi
    jz 5f
    mov rdi, r14
    call sb_push_cstr
5:  mov rdi, r14
    mov esi, 10
    call sb_push_byte
    jmp 1b
9:  cmp qword ptr [rip + qr_vec + VEC_len], 0
    jne 91f
    mov rdi, r14
    lea rsi, [rip + .Ls_none]
    call sb_push_cstr
91: EPILOGUE

.section .rodata
.Le_unknown: .asciz "unknown"
.Le_syntax: .asciz "syntax"
.Le_cancelled: .asciz "cancelled"
.Le_toobig: .asciz "toobig the query's cap is reached"
.Le_no_parts: .asciz "refused this request takes no parts"
.Le_part_dropped: .asciz "syntax the part was dropped"
.Le_not_manifest: .asciz "refused a value the manifest does not declare for this key"
.Lempty: .asciz ""
.Ls_avg: .asciz " avg="
.Ls_max: .asciz " max="
.Ls_equals: .asciz " = "
.Ls_pct: .asciz " pct="
.Ls_items: .asciz " items="
.Ls_trunc: .asciz " truncated"
.Ls_text: .asciz " text="
.Ls_none: .asciz "none\n"
.Ls_two: .asciz "  "
.Ls_n_asked: .asciz " asked, "
.Ls_n_ms: .asciz " ms"
.Ls_n_sep: .asciz ", "
.Ls_n_failed: .asciz " failed"
.Ls_n_expired: .asciz " expired"
.Ls_n_never: .asciz "not asked yet"
.Lq_asked: .asciz " asked="
.Lq_cold: .asciz " cold="
.Lq_answered: .asciz " answered="
.Lq_empty: .asciz " empty="
.Lq_failed: .asciz " failed="
.Lq_expired: .asciz " expired="
.Lq_late: .asciz " late="
.Lq_dropped: .asciz " dropped="
.Lq_cancelled: .asciz " cancelled="
.Lk_complete: .asciz "complete"
.Lk_resolve: .asciz "complete-resolve"
.Lk_signature: .asciz "signature"
.Lk_hover: .asciz "hover-query"
.Lk_definition: .asciz "definition"
.Lk_declaration: .asciz "declaration"
.Lk_typedef: .asciz "type-definition"
.Lk_implementation: .asciz "implementation"
.Lk_references: .asciz "references"
.Lk_symbols: .asciz "symbols"
.Lk_wsymbols: .asciz "workspace-symbols"
.Lk_selection: .asciz "selection-ranges"
.Lk_callh: .asciz "call-hierarchy"
.Lk_typeh: .asciz "type-hierarchy"
.Lk_calls: .asciz "hierarchy-items"
.Lk_actions: .asciz "code-actions"
.Lk_actions_auto: .asciz "code-actions-auto"
.Lk_action_resolve: .asciz "code-action-resolve"
.Lk_prepare: .asciz "prepare-rename"
.Lk_rename: .asciz "rename"
.Lk_format: .asciz "format"
.Lk_range_format: .asciz "range-format"
.Lk_type_format: .asciz "type-format"
.Lk_links: .asciz "document-links"
.Lk_save_actions: .asciz "save-actions"
.Lk_commit_message: .asciz "commit-message"
.Lk_quickdiff: .asciz "quickdiff"
.Lk_tests_resolve: .asciz "tests-resolve"
.Lk_test_run: .asciz "test-run"
.Lk_transcript: .asciz "agent-transcript"
.Lk_tool: .asciz "tool"
.Lk_prompt: .asciz "agent-prompt"
.Lk_nb_open: .asciz "nb-open"
.Lk_nb_save: .asciz "nb-save"
.Lk_folding: .asciz "folding-ranges"
.Lk_tokens: .asciz "semantic-tokens"
.Lk_hints: .asciz "inlay-hints"
.Lk_lens: .asciz "code-lens"
.Lk_inline: .asciz "inline-complete"
.Lk_colors: .asciz "colors"
.Lk_color_edit: .asciz "color-edit"
.Lk_highlights: .asciz "highlights"
.Lk_linked: .asciz "linked"
.Lk_ed_open: .asciz "editor-open"
.Lk_ed_save: .asciz "editor-save"
.Lk_ed_cmd: .asciz "editor-undo"
.Lk_debug_resolve: .asciz "debug-resolve"
.p2align 3
qs_names: .quad .Lq_asked, .Lq_cold, .Lq_answered, .Lq_empty, .Lq_failed, .Lq_expired
    .quad .Lq_late, .Lq_dropped, .Lq_cancelled, 0
# per asker (QO_*): its reply handler (an expired request is an error answer to it), what takes a
# query-part, and what hears that the Query cap cut a request short
qo_reply: .quad 0, langfeat_reply, complete_reply, 0, scmext_reply, testproto_expired, ai_query_expired, nb_reply
    .quad present_reply         # QO_PRESENT
    .quad ws_linked_reply       # QO_LINKED
    .quad ce_reply              # QO_CUSTOM
qo_part: .quad 0, langfeat_part, complete_part, 0, 0, 0, 0, 0, 0, 0, 0
qo_trunc: .quad 0, langfeat_truncated, 0, 0, 0, 0, 0, 0, 0, 0, 0
# the kinds (docs/extensions/v1.1.md, "Language feature queries"): name, [provides] key, show,
# hard limit and ceiling (ms), flags, an answer's cap (records, bytes), the query's cap
.macro PK name, pv, show, base, ceil, flags, items, bytes, qitems, qbytes
    .quad \name, \pv
    .long \show, \base, \ceil, \flags, \items, \bytes, \qitems, \qbytes
.endm
pk_table:
    PK .Lk_complete, EXT_pv_complete, 0, 0, 0, PKF_PARTS, 4096, 1048576, 8192, 2097152
    PK .Lk_resolve, EXT_pv_complete, 0, 1000, 0, PKF_SILENT | PKF_SUB, 1, 65536, 1, 65536
    PK .Lk_signature, EXT_pv_signature, 0, 0, 0, PKF_SILENT, 32, 65536, 32, 65536
    PK .Lk_hover, EXT_pv_hover, 1000, 3000, 0, PKF_SILENT, 1, 65536, 1, 262144
    PK .Lk_definition, EXT_pv_definition, 0, 5000, 30000, PKF_PARTS, 10000, 1048576, 10000, 4194304
    PK .Lk_declaration, EXT_pv_declaration, 0, 5000, 30000, PKF_PARTS, 10000, 1048576, 10000, 4194304
    PK .Lk_typedef, EXT_pv_type_definition, 0, 5000, 30000, PKF_PARTS, 10000, 1048576, 10000, 4194304
    PK .Lk_implementation, EXT_pv_implementation, 0, 10000, 60000, PKF_PARTS | PKF_FIRST, 10000, 1048576, 20000, 8388608
    PK .Lk_references, EXT_pv_references, 0, 10000, 120000, PKF_PARTS | PKF_FIRST, 10000, 1048576, 100000, 16777216
    PK .Lk_symbols, EXT_pv_symbols, 0, 5000, 0, 0, 10000, 1048576, 10000, 1048576
    PK .Lk_wsymbols, EXT_pv_workspace_symbols, 300, 5000, 30000, PKF_PARTS, 10000, 1048576, 20000, 4194304
    PK .Lk_selection, EXT_pv_selection_ranges, 0, 1000, 0, PKF_SILENT, 4096, 65536, 4096, 65536
    PK .Lk_callh, EXT_pv_call_hierarchy, 0, 5000, 0, 0, 64, 262144, 64, 262144
    PK .Lk_typeh, EXT_pv_type_hierarchy, 0, 5000, 0, 0, 64, 262144, 64, 262144
    PK .Lk_calls, 0, 0, 5000, 30000, PKF_PARTS | PKF_FIRST, 1000, 1048576, 10000, 4194304
    PK .Lk_actions, EXT_pv_actions, 0, 3000, 0, 0, 1000, 4194304, 1000, 4194304
    PK .Lk_actions_auto, EXT_pv_actions, 0, 1000, 0, PKF_SILENT | PKF_SUB, 1000, 4194304, 1000, 4194304
    PK .Lk_action_resolve, EXT_pv_actions, 0, 5000, 60000, PKF_SUB, 1, 4194304, 1, 4194304
    PK .Lk_prepare, EXT_pv_rename, 0, 2000, 0, PKF_SUB, 1, 4096, 1, 4096
    PK .Lk_rename, EXT_pv_rename, 0, 15000, 120000, 0, 100000, 4194304, 100000, 4194304
    PK .Lk_format, EXT_pv_format, 0, 10000, 30000, 0, 100000, 4194304, 100000, 4194304
    PK .Lk_range_format, EXT_pv_range_format, 0, 10000, 30000, 0, 100000, 4194304, 100000, 4194304
    PK .Lk_type_format, EXT_pv_type_format, 0, 500, 0, PKF_SILENT, 100000, 65536, 100000, 65536
    PK .Lk_links, EXT_pv_document_links, 0, 2000, 0, PKF_SILENT, 10000, 1048576, 10000, 1048576
    PK .Lk_save_actions, EXT_pv_save_actions, 0, 0, 0, PKF_SILENT, 1000, 4194304, 1000, 4194304
    # source control (scmext.s): the asker keeps its own time limits
    PK .Lk_commit_message, EXT_pv_commit, 0, 0, 0, PKF_SILENT, 1, 4194304, 1, 4194304
    PK .Lk_quickdiff, EXT_pv_quickdiff, 0, 0, 0, PKF_SILENT, 1, 4194304, 1, 4194304
    # testing: a tests-resolve answer waits 30 s, a test-run's "ok ID 0" 10 s
    PK .Lk_tests_resolve, EXT_pv_tests, 0, 30000, 0, PKF_SILENT, 10000, 4194304, 10000, 4194304
    PK .Lk_test_run, EXT_pv_tests, 0, 10000, 0, PKF_SILENT | PKF_SUB, 1, 65536, 1, 65536
    # AI (agentext.s, tools.s): a transcript page, a tool call (the caller's patience, no limit here),
    # a prompt to an agent session
    PK .Lk_transcript, 0, 0, 30000, 0, PKF_SILENT, 2000, 4194304, 2000, 4194304
    PK .Lk_tool, 0, 0, 0, 0, PKF_SILENT, 1, 4194304, 1, 4194304
    PK .Lk_prompt, 0, 0, 30000, 0, PKF_SILENT, 1, 4096, 1, 4096
    # notebooks: the notebook keeps its own deadline (nbdoc.s)
    PK .Lk_nb_open, EXT_pv_notebook, 0, 0, 0, PKF_SILENT, 1, 67108864, 1, 67108864
    PK .Lk_nb_save, EXT_pv_notebook, 0, 0, 0, PKF_SILENT | PKF_SUB, 1, 67108864, 1, 67108864
    # editor presentation (present.s): automatic and silent; an answer that never comes frees its
    # request's slot after the hard limit
    PK .Lk_folding, EXT_pv_folding, 0, 30000, 0, PKF_SILENT, 50000, 4194304, 50000, 4194304
    PK .Lk_tokens, EXT_pv_semantic_tokens, 0, 30000, 0, PKF_SILENT, 1000000, 4194304, 1000000, 4194304
    PK .Lk_hints, EXT_pv_inlay_hints, 0, 10000, 0, PKF_SILENT, 5000, 4194304, 5000, 4194304
    PK .Lk_lens, EXT_pv_code_lens, 0, 10000, 0, PKF_SILENT, 10000, 4194304, 10000, 4194304
    PK .Lk_inline, EXT_pv_inline_complete, 0, 0, 0, PKF_SILENT, 8, 4194304, 8, 4194304
    PK .Lk_colors, EXT_pv_colors, 0, 10000, 0, PKF_SILENT, 10000, 1048576, 10000, 1048576
    PK .Lk_color_edit, EXT_pv_colors, 0, 5000, 0, PKF_SILENT | PKF_SUB, 100000, 4194304, 100000, 4194304
    PK .Lk_highlights, EXT_pv_highlights, 0, 5000, 0, PKF_SILENT, 5000, 1048576, 5000, 1048576
    # wsedit: linked editing (wslinked.s): an answer within a second, at most 64 ranges
    PK .Lk_linked, EXT_pv_linked, 0, 1000, 0, PKF_SILENT, 64, 65536, 64, 65536
    # custom editors: the editor keeps its own deadline (customed.s)
    PK .Lk_ed_open, EXT_pv_editor, 0, 0, 0, PKF_SILENT, 1, 65536, 1, 65536
    PK .Lk_ed_save, EXT_pv_editor, 0, 0, 0, PKF_SILENT | PKF_SUB, 1, 4194368, 1, 4194368
    PK .Lk_ed_cmd, EXT_pv_editor, 0, 0, 0, PKF_SILENT | PKF_SUB, 1, 65536, 1, 65536
    # debugger (debugext.s): debug-resolve keeps its own 60 s; a configuration body of 1 MB at most
    PK .Lk_debug_resolve, 0, 0, 0, 0, PKF_SILENT, 1, 1048576, 1, 1048576
