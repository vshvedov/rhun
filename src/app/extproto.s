# extension protocol v1 (docs/extensions/v1.md): parsing what an extension writes, answering its
# requests, and telling it what changed. ext.s owns the processes and the pipes.
.include "rhun.inc"

.bss
.p2align 3
line: .zero SB_SIZE             # the message being handled, as a copy (the receive buffer may move)
out: .zero SB_SIZE              # the reply or event being built
fields: .zero 8 * 32            # ptr, len of each field of the line (up to 16)
nfields: .quad 0
cur: .quad 0                    # the EXT being served
cur_id: .quad 0                 # the request id
body_ptr: .quad 0               # its body
body_len: .quad 0
syntax_seen: .quad 0            # a syntax reply went out while handling this message
toast_buf: .zero 256
pr_ext: .quad 0                 # the open prompt (choose, ask, term): its extension,
pr_id: .quad 0                  #   request id (0: no prompt is open),
pr_kind: .quad 0                #   1 choose, 2 ask, 3 term,
pr_body: .quad 0                #   the items' bytes (choose), owned
pr_opened: .quad 0              #   time_ms when it opened (a fresh term prompt ignores Enter)
pr_label: .zero 208             #   the prompt text, a cstr
pr_cmd: .zero SB_SIZE           # the command sent to the terminal

.text

# ---------------- reading ----------------

# extproto_pump(ext): handle every complete message in the receive buffer
FN extproto_pump
    PROLOGUE 16
    mov rbx, rdi
    mov [rip + cur], rbx
    call time_ms
    mov r15, rax                # this run's start: EXT_PUMP_MS at most
    # the window: a new one after EXT_WIN_MS; a window that hit a cap counts toward flooding,
    # one that did not ends the count
    mov rax, r15
    sub rax, [rbx + EXT_win_t0]
    cmp rax, EXT_WIN_MS
    jl .Lpp_next
    mov [rbx + EXT_win_t0], r15
    # a busy window (a fifth of a cap or more: 100 messages or 64 KB in 16 ms) counts; a quieter
    # one ends the count
    cmp qword ptr [rbx + EXT_win_msgs], EXT_WIN_MSGS / 5
    jae 8f
    cmp qword ptr [rbx + EXT_fbytes], EXT_WIN_BYTES / 4
    jae 8f
    mov dword ptr [rbx + EXT_flood], 0
    jmp 81f
8:  inc dword ptr [rbx + EXT_flood]
81: mov qword ptr [rbx + EXT_win_msgs], 0
    mov qword ptr [rbx + EXT_fbytes], 0
    mov dword ptr [rbx + EXT_win_hit], 0
.Lpp_next:
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    je 1f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 9f
1:  # the caps
    cmp qword ptr [rbx + EXT_win_msgs], EXT_WIN_MSGS
    jae .Lpp_cap
    cmp qword ptr [rbx + EXT_fbytes], EXT_WIN_BYTES
    jae .Lpp_cap
    mov r12, [rbx + EXT_rbuf + SB_ptr]
    mov r13, [rbx + EXT_rbuf + SB_len]
    # a message waiting for its body
    mov rax, [rbx + EXT_body]
    test rax, rax
    jz 2f
    mov rcx, [rbx + EXT_body_len]
    cmp r13, rcx
    jb 9f
    mov [rip + body_ptr], r12
    mov [rip + body_len], rcx
    mov rdi, rax
    call strlen
    mov rdi, [rbx + EXT_body]
    mov rsi, rax
    call handle_line            # the saved line, now with its body
    # the handler may have ended the program (a third syntax error): its buffers are gone
    cmp dword ptr [rbx + EXT_status], ES_STARTING
    je 11f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 9f
11: mov rdi, [rbx + EXT_body]
    call mem_free
    mov qword ptr [rbx + EXT_body], 0
    mov rdi, [rbx + EXT_body_len]
    add [rbx + EXT_fbytes], rdi
    inc qword ptr [rbx + EXT_win_msgs]
    call consume
    jmp .Lpp_time
2:  # a complete line?
    xor ecx, ecx
3:  cmp rcx, r13
    jae 9f
    cmp byte ptr [r12 + rcx], 10
    je 4f
    inc rcx
    jmp 3b
4:  mov r14, rcx                # line length without LF
    mov rdx, rcx
    test rdx, rdx
    jz 5f
    cmp byte ptr [r12 + rdx - 1], 13
    jne 5f
    dec rdx
5:  # copy the line out first: handling it may change the buffer
    mov [rsp], rdx
    lea rdi, [rip + out]        # `out` is free until a reply is built
    call sb_clear
    lea rdi, [rip + out]
    mov rsi, r12
    mov rdx, [rsp]
    call sb_push
    lea rdi, [r14 + 1]
    add [rbx + EXT_fbytes], rdi
    inc qword ptr [rbx + EXT_win_msgs]
    call consume
    mov qword ptr [rip + body_ptr], 0
    mov qword ptr [rip + body_len], 0
    mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
    call handle_line
.Lpp_time:
    # one run takes EXT_PUMP_MS at most; the rest waits like a capped window (ext_tick resumes it)
    call time_ms
    sub rax, r15
    cmp rax, EXT_PUMP_MS
    jl .Lpp_next
.Lpp_cap:
    # the window's cap: the rest waits for the next window (ext_tick resumes it)
    mov dword ptr [rbx + EXT_win_hit], 1
    mov dword ptr [rbx + EXT_throttled], 1
    cmp dword ptr [rbx + EXT_out], 0
    jl 9f
    mov edi, [rbx + EXT_out]
    xor esi, esi
    call watch_set_events
9:  EPILOGUE

# consume(n): drop n bytes from the front of rbx's receive buffer
consume:
    push rbx
    push rdi
    mov rax, [rbx + EXT_rbuf + SB_len]
    sub rax, rdi
    mov rsi, [rbx + EXT_rbuf + SB_ptr]
    add rsi, rdi
    mov rdi, [rbx + EXT_rbuf + SB_ptr]
    mov rdx, rax
    push rax
    push rax
    call memmove
    pop rax
    pop rax
    mov [rbx + EXT_rbuf + SB_len], rax
    pop rdi
    pop rbx
    ret

# split(ptr, len): fields[] from the line; a field is a run of non-space bytes
split:
    xor ecx, ecx
    mov [rip + nfields], rcx
    lea r8, [rip + fields]
    add rsi, rdi                # end
1:  cmp rdi, rsi
    jae 9f
    cmp byte ptr [rdi], ' '
    jne 2f
    inc rdi
    jmp 1b
2:  cmp rcx, 16
    jae 9f
    mov rax, rcx
    shl rax, 4
    mov [r8 + rax], rdi
    mov rdx, rdi
3:  cmp rdx, rsi
    jae 4f
    cmp byte ptr [rdx], ' '
    je 4f
    inc rdx
    jmp 3b
4:  mov rax, rdx
    sub rax, rdi
    mov r9, rcx
    shl r9, 4
    mov [r8 + r9 + 8], rax
    inc rcx
    mov [rip + nfields], rcx
    mov rdi, rdx
    jmp 1b
9:  ret

# field_u64(i) -> rax value, rdx 1 when it was a number (and only digits)
field_u64:
    cmp rdi, [rip + nfields]
    jae 8f                      # past the line's fields: what is there is an older line's
    lea r8, [rip + fields]
    shl rdi, 4
    mov rsi, [r8 + rdi + 8]
    mov rdi, [r8 + rdi]
    test rsi, rsi
    jz 8f
    push rsi
    call parse_u64
    pop rsi
    cmp rdx, rsi
    jne 8f
    mov edx, 1
    ret
8:  xor eax, eax
    xor edx, edx
    ret

# field_is(i, cstr) -> 1 if equal
field_is:
    cmp rdi, [rip + nfields]
    jae 8f
    lea r8, [rip + fields]
    mov rdx, rsi
    shl rdi, 4
    mov rsi, [r8 + rdi + 8]
    mov rdi, [r8 + rdi]
    jmp str_eq_cstr
8:  xor eax, eax
    ret

# rest_from(i) -> rax ptr, rdx len: from field i to the end of the line
rest_from:
    lea r8, [rip + fields]
    cmp rdi, [rip + nfields]
    jae 8f
    shl rdi, 4
    mov rax, [r8 + rdi]
    mov rdx, [rip + line + SB_ptr]
    add rdx, [rip + line + SB_len]
    sub rdx, rax
    ret
8:  xor eax, eax
    xor edx, edx
    ret

# handle_line(ptr, len): one message from cur (body_ptr set when it is a body message's line)
handle_line:
    PROLOGUE
    mov rbx, [rip + cur]
    test rsi, rsi
    jz 9f
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rax, [rip + line + SB_ptr]
    add rax, [rip + line + SB_len]
    mov byte ptr [rax], 0
    mov rdi, [rip + line + SB_ptr]
    mov rsi, [rip + line + SB_len]
    call split
    cmp qword ptr [rip + nfields], 0
    je 9f
    cmp dword ptr [rbx + EXT_hello], 0
    jne .Lhl_msg
    # the first line must be hello 1
    xor edi, edi
    lea rsi, [rip + .Lw_hello]
    call field_is
    test eax, eax
    jz 3f
    mov edi, 1
    call field_u64
    test edx, edx
    jz 3f
    cmp rax, 1
    jne 4f
    mov dword ptr [rbx + EXT_hello], 1
    mov dword ptr [rbx + EXT_status], ES_RUNNING
    call ext_hooks_update
    mov rdi, rbx
    call hello_features         # the features it named that rhun knows, said back before ready
    mov rdi, rbx
    call send_ready
    mov rdi, rbx
    call send_settings          # its own settings, before anything else
    mov rdi, rbx
    call extproto_events        # catch-up: nothing is known yet, so everything open is reported
    mov rax, [rbx + EXT_pending]
    test rax, rax
    jz 9f
    mov qword ptr [rbx + EXT_pending], 0
    mov rdi, rbx
    lea rsi, [rax - 1]
    call extproto_send_run
    jmp 9f
3:  mov rdi, rbx
    lea rsi, [rip + .Lr_no_hello]
    call ext_kill
    jmp 9f
4:  mov rdi, rbx
    lea rsi, [rip + .Lr_protocol]
    call ext_kill
    jmp 9f
.Lhl_msg:
    # replies to rhun's requests (section 12): "ok ID LEN" and its body, "error ID CODE TEXT"; an
    # extension that agreed no feature is asked nothing, and its stray replies are ignored
    xor edi, edi
    lea rsi, [rip + .Lw_ok]
    call field_is
    test eax, eax
    jnz .Lhl_ok
    xor edi, edi
    lea rsi, [rip + .Lw_error]
    call field_is
    test eax, eax
    jnz .Lhl_err
    xor edi, edi
    call field_u64
    test edx, edx
    jz .Lhl_syntax
    test rax, rax
    jz .Lhl_syntax              # events come from rhun, not from extensions
    cmp rax, 2147483647
    ja .Lhl_syntax
    mov [rip + cur_id], rax
    cmp qword ptr [rip + nfields], 2
    jb .Lhl_syntax
    mov qword ptr [rip + syntax_seen], 0
    # the verb
    lea r12, [rip + verbs]
5:  mov rsi, [r12]
    test rsi, rsi
    jz .Lhl_unknown
    mov edi, 1
    call field_is
    test eax, eax
    jnz 6f
    add r12, 24
    jmp 5b
6:  # a body verb waits for its body first
    cmp qword ptr [r12 + 16], 0
    je 7f
    cmp qword ptr [rip + body_ptr], 0
    jne 7f
    mov rdi, [rip + nfields]
    dec rdi
    call field_u64
    test edx, edx
    jz .Lhl_syntax_id
    cmp rax, [r12 + 16]
    jbe 61f
    # over the cap: the body cannot be skipped without reading it, and reading megabytes to
    # throw them away is the attack: the program ends
    mov rdi, rbx
    lea rsi, [rip + .Lr_body]
    call ext_kill
    jmp 9f
61: mov [rbx + EXT_body_len], rax
    mov rdi, [rip + line + SB_ptr]
    mov rsi, [rip + line + SB_len]
    call mem_dup
    mov [rbx + EXT_body], rax
    jmp 9f
7:  call [r12 + 8]
    cmp qword ptr [rip + syntax_seen], 0
    jne 9f
    mov dword ptr [rbx + EXT_syntax_errs], 0    # a whole request parsed: the streak is over
    jmp 9f
.Lhl_unknown:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_unknown]
    call reply_error
    jmp 9f
.Lhl_ok:
    test dword ptr [rbx + EXT_features], FEAT_PROVIDERS
    jz 9f
    cmp qword ptr [rip + nfields], 3
    jb 9f
    mov edi, 1
    call field_u64
    test edx, edx
    jz 9f
    mov r12, rax                # the id
    mov edi, 2
    call field_u64
    test edx, edx
    jz 9f
    cmp qword ptr [rip + body_ptr], 0
    jne 2f
    test rax, rax
    jz 2f                       # no body: answered at once
    cmp rax, REPLY_BODY_MAX
    jbe 1f
    mov rdi, rbx                # a body over the cap ends the program, as for requests
    lea rsi, [rip + .Lr_body]
    call ext_kill
    jmp 9f
1:  mov [rbx + EXT_body_len], rax
    mov rdi, [rip + line + SB_ptr]
    mov rsi, [rip + line + SB_len]
    call mem_dup
    mov [rbx + EXT_body], rax
    jmp 9f
2:  mov rdi, rbx
    mov rsi, r12
    mov edx, 1
    mov rcx, [rip + body_ptr]
    mov r8, [rip + body_len]
    call complete_reply
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, r12
    mov edx, 1
    mov rcx, [rip + body_ptr]
    mov r8, [rip + body_len]
    call langfeat_reply
    jmp 9f
.Lhl_err:
    test dword ptr [rbx + EXT_features], FEAT_PROVIDERS
    jz 9f
    mov edi, 1
    call field_u64
    test edx, edx
    jz 9f
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call complete_reply
    test eax, eax
    jnz 9f
    # the code and text after the id, for the user when the request was theirs (rename)
    mov edi, 2
    call rest_from
    mov rcx, rax
    mov r8, rdx
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call langfeat_reply
    jmp 9f
.Lhl_syntax:
    xor edi, edi
    call reply_syntax
    jmp 9f
.Lhl_syntax_id:
    mov rdi, [rip + cur_id]
    call reply_syntax
9:  EPILOGUE

# reply_syntax(id): "error ID syntax ..."; the third in a row ends the program
reply_syntax:
    push rbx
    mov rbx, [rip + cur]
    lea rsi, [rip + .Le_syntax]
    call reply_error
    mov qword ptr [rip + syntax_seen], 1
    inc dword ptr [rbx + EXT_syntax_errs]
    cmp dword ptr [rbx + EXT_syntax_errs], 3
    jb 9f
    mov rdi, rbx
    lea rsi, [rip + .Lr_syntax]
    call ext_kill
9:  pop rbx
    ret

# ---------------- replies ----------------

# out_begin(): start a reply or event
out_begin:
    lea rdi, [rip + out]
    jmp sb_clear
# out_cstr(cstr), out_u64(v), out_byte(b), out_bytes(ptr, len), out_end(): send it to cur
out_cstr:
    mov rsi, rdi
    lea rdi, [rip + out]
    jmp sb_push_cstr
out_u64:
    mov rsi, rdi
    lea rdi, [rip + out]
    jmp sb_push_u64
out_byte:
    mov esi, edi
    lea rdi, [rip + out]
    jmp sb_push_byte
out_bytes:
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + out]
    jmp sb_push
out_end:
    mov rdi, [rip + cur]
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    jmp ext_send

# reply_ok(id)
reply_ok:
    push rdi
    call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    pop rdi
    call out_u64
    mov edi, 10
    call out_byte
    jmp out_end

# reply_ok_u64(id, value): "ok ID VALUE"
reply_ok_u64:
    push rsi
    push rdi
    call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    pop rdi
    call out_u64
    mov edi, ' '
    call out_byte
    pop rdi
    call out_u64
    mov edi, 10
    call out_byte
    jmp out_end

# reply_error(id, "code text")
reply_error:
    push rsi
    push rdi
    call out_begin
    lea rdi, [rip + .Lw_error_sp]
    call out_cstr
    pop rdi
    call out_u64
    mov edi, ' '
    call out_byte
    pop rdi
    call out_cstr
    mov edi, 10
    call out_byte
    jmp out_end

# reply_error_u64(id, "code text ", value)
reply_error_u64:
    push rdx
    push rsi
    push rdi
    call out_begin
    lea rdi, [rip + .Lw_error_sp]
    call out_cstr
    pop rdi
    call out_u64
    mov edi, ' '
    call out_byte
    pop rdi
    call out_cstr
    pop rdi
    call out_u64
    mov edi, 10
    call out_byte
    jmp out_end

# ---------------- documents ----------------

# doc_by_id(id) -> DOC* or 0, among the open document tabs
doc_by_id:
    xor ecx, ecx
1:  cmp rcx, [rip + g_tabs + VEC_len]
    jae 8f
    imul rax, rcx, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    inc rcx
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 1b
    mov rax, [rax + TAB_doc]
    test rax, rax
    jz 1b
    cmp [rax + DOC_id], rdi
    jne 1b
    ret
8:  xor eax, eax
    ret

# arg_doc(i) -> DOC* from field i, or 0 after replying nodoc
arg_doc:
    push rbx
    call field_u64
    test edx, edx
    jz 7f
    mov rdi, rax
    call doc_by_id
    test rax, rax
    jz 8f
    pop rbx
    ret
7:  mov rdi, [rip + cur_id]
    call reply_syntax
    xor eax, eax
    pop rbx
    ret
8:  mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_nodoc]
    call reply_error
    xor eax, eax
    pop rbx
    ret

# arg_pos(doc, i) -> rax byte position from fields i, i+1 (LINE COL), or -1 after replying badpos
arg_pos:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call field_u64
    test edx, edx
    jz 8f
    test rax, rax
    jz 8f
    cmp rax, [rbx + DOC_nlines]
    ja 8f
    lea r13, [rax - 1]          # line, 0-based
    lea rdi, [r12 + 1]
    call field_u64
    test edx, edx
    jz 8f
    test rax, rax
    jz 8f
    mov r14, rax                # col, 1-based byte
    mov rdi, rbx
    mov rsi, r13
    call doc_line_start
    mov r15, rax
    mov rdi, rbx
    mov rsi, r13
    call doc_line_end
    sub rax, r15                # line length
    lea rcx, [r14 - 1]
    cmp rcx, rax
    ja 8f
    add r15, rcx
    # not inside a multibyte sequence
    cmp rcx, rax
    je 9f
    mov rdi, rbx
    mov rsi, r15
    call doc_byte
    and eax, 0xc0
    cmp eax, 0x80
    je 8f
9:  mov rax, r15
    EPILOGUE
8:  mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_badpos]
    call reply_error
    mov rax, -1
    EPILOGUE

# need(bit) -> 1 when cur has the capability, else 0 after replying needs
need:
    mov rax, [rip + cur]
    test [rax + EXT_needs], edi
    jz 1f
    mov eax, 1
    ret
1:  lea rsi, [rip + .Le_needs_read]
    cmp edi, NEEDS_DOC_WRITE
    jne 11f
    lea rsi, [rip + .Le_needs_write]
11: cmp edi, NEEDS_TERMINAL
    jne 2f
    lea rsi, [rip + .Le_needs_term]
2:  mov rdi, [rip + cur_id]
    call reply_error
    xor eax, eax
    ret

# ---------------- requests ----------------

# ID text DOC -> ok ID VERSION LEN + body
h_text:
    PROLOGUE
    mov edi, NEEDS_DOC_READ
    call need
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 3
    jb 8f
    mov edi, 2
    call arg_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rbx
    call doc_len
    mov r12, rax
    call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    mov rdi, [rip + cur_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, [rbx + DOC_version]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r12
    call out_u64
    mov edi, 10
    call out_byte
    lea rdi, [rip + out]
    mov rsi, r12
    call sb_reserve
    mov rcx, rax
    mov rdi, rbx
    xor esi, esi
    mov rdx, r12
    call doc_copy
    add [rip + out + SB_len], r12
    call out_end
    mov rdi, rbx
    call snapshot_taken
9:  EPILOGUE
8:  mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# ID range DOC L1 C1 L2 C2 -> ok ID VERSION LEN + body
h_range:
    PROLOGUE
    mov edi, NEEDS_DOC_READ
    call need
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 7
    jb .Lhr_syntax
    mov edi, 2
    call arg_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rbx
    mov esi, 3
    call arg_pos
    test rax, rax
    js 9f
    mov r12, rax
    mov rdi, rbx
    mov esi, 5
    call arg_pos
    test rax, rax
    js 9f
    mov r13, rax
    sub r13, r12                # length
    jns 1f
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_badpos]
    call reply_error
    jmp 9f
1:  call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    mov rdi, [rip + cur_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, [rbx + DOC_version]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r13
    call out_u64
    mov edi, 10
    call out_byte
    lea rdi, [rip + out]
    mov rsi, r13
    call sb_reserve
    mov rcx, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call doc_copy
    add [rip + out + SB_len], r13
    call out_end
    mov rdi, rbx
    call snapshot_taken
9:  EPILOGUE
.Lhr_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# ID replace DOC VERSION L1 C1 L2 C2 LEN + body -> ok ID NEWVERSION
h_replace:
    PROLOGUE
    mov edi, NEEDS_DOC_WRITE
    call need
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 9
    jb .Lhp_syntax
    mov edi, 2
    call arg_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    test dword ptr [rbx + DOC_flags], DF_READONLY
    jnz .Lhp_readonly
    mov edi, 3
    call field_u64
    test edx, edx
    jz .Lhp_syntax
    cmp rax, [rbx + DOC_version]
    jne .Lhp_stale
    mov rdi, rbx
    mov esi, 4
    call arg_pos
    test rax, rax
    js 9f
    mov r12, rax
    mov rdi, rbx
    mov esi, 6
    call arg_pos
    test rax, rax
    js 9f
    mov r13, rax
    sub r13, r12
    js .Lhp_badpos
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, [rip + body_ptr]
    mov r8, [rip + body_len]
    call apply_replace
    mov rdi, [rip + cur_id]
    mov rsi, [rbx + DOC_version]
    call reply_ok_u64
9:  EPILOGUE
.Lhp_stale:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_stale]
    mov rdx, [rbx + DOC_version]
    call reply_error_u64
    EPILOGUE
.Lhp_badpos:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_badpos]
    call reply_error
    EPILOGUE
.Lhp_readonly:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_readonly]
    call reply_error
    EPILOGUE
.Lhp_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# apply LEN + a workspace edit (section 12g): checked whole, then each document changed as one
# undo step; files that are not open open in tabs, unsaved
h_apply:
    PROLOGUE
    mov edi, NEEDS_DOC_WRITE
    call need
    test eax, eax
    jz 9f
    mov rdi, [rip + body_ptr]
    mov rsi, [rip + body_len]
    mov rdx, [rip + cur]
    call ws_apply_request
    test eax, eax
    jz 1f
    mov rdi, [rip + cur_id]
    call reply_ok
    jmp 9f
1:  mov rdi, [rip + cur_id]
    mov rsi, rdx
    call reply_error
9:  EPILOGUE

# apply_replace(doc, pos, len, ptr, blen): one undo step; the cursor and anchor follow the text
apply_replace:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    # where the cursor and the anchor end (section 4: one inside the range goes after the new
    # text; the editor's own rule would leave it at the range's start)
    mov rax, [rbx + DOC_cur]
    mov [rsp], rax
    lea rdi, [rsp]
    call move_mark
    mov rax, [rbx + DOC_anchor]
    mov [rsp + 8], rax
    lea rdi, [rsp + 8]
    call move_mark
    mov rdi, rbx
    call doc_begin_group
    test r13, r13
    jz 1f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, EK_OTHER
    call doc_delete
1:  test r15, r15
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    mov rcx, r15
    mov r8d, EK_OTHER
    call doc_insert
2:  mov rdi, rbx
    call doc_end_group
    # through the editor, so the view follows
    mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call set_marks
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# move_mark(ptr to a position): where it is after [r12, r12+r13) is replaced with r15 bytes
move_mark:
    mov rax, [rdi]
    cmp rax, r12
    jb 9f
    lea rcx, [r12 + r13]
    cmp rax, rcx
    jae 1f
    lea rax, [r12 + r15]        # inside the range: after the new text
    mov [rdi], rax
    ret
1:  sub rax, r13
    add rax, r15
    mov [rdi], rax
9:  ret

# set_marks(doc, cur, anchor): through the editor (which reveals the cursor) for the document on
# screen, directly for any other
set_marks:
    cmp rdi, [rip + g_doc]
    je 1f
    mov [rdi + DOC_cur], rsi
    mov [rdi + DOC_anchor], rdx
    ret
1:  push rbx
    push rsi
    mov rbx, rdi
    mov rsi, rdx
    xor edx, edx
    call ed_set_cursor
    pop rsi
    mov rdi, rbx
    mov edx, 1
    call ed_set_cursor
    pop rbx
    ret

# ID insert DOC VERSION LEN + body -> ok ID NEWVERSION: at the cursor, replacing the selection
h_insert:
    PROLOGUE
    mov edi, NEEDS_DOC_WRITE
    call need
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 5
    jb .Lhi_syntax
    mov edi, 2
    call arg_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    test dword ptr [rbx + DOC_flags], DF_READONLY
    jnz .Lhi_readonly
    mov edi, 3
    call field_u64
    test edx, edx
    jz .Lhi_syntax
    cmp rax, [rbx + DOC_version]
    jne .Lhi_stale
    mov rdi, rbx
    call ed_sel
    mov r12, rax
    mov r13, rdx
    cmp r12, r13
    jbe 1f
    xchg r12, r13
1:  sub r13, r12
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, [rip + body_ptr]
    mov r8, [rip + body_len]
    call apply_replace
    mov rdi, [rip + cur_id]
    mov rsi, [rbx + DOC_version]
    call reply_ok_u64
9:  EPILOGUE
.Lhi_stale:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_stale]
    mov rdx, [rbx + DOC_version]
    call reply_error_u64
    EPILOGUE
.Lhi_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE
.Lhi_readonly:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_readonly]
    call reply_error
    EPILOGUE

# ID select DOC L1 C1 L2 C2 -> ok ID: the anchor at the first position, the cursor at the second
h_select:
    PROLOGUE
    cmp qword ptr [rip + nfields], 7
    jb .Lhs_syntax
    mov edi, 2
    call arg_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rbx
    mov esi, 3
    call arg_pos
    test rax, rax
    js 9f
    mov r12, rax
    mov rdi, rbx
    mov esi, 5
    call arg_pos
    test rax, rax
    js 9f
    mov r13, rax
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r12
    call set_marks
    mov dword ptr [rip + g_dirty], 1
    mov rdi, [rip + cur_id]
    call reply_ok
9:  EPILOGUE
.Lhs_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# ID toast LEN + body -> ok ID (at most 200 bytes shown)
h_toast:
    PROLOGUE
    mov rsi, [rip + body_ptr]
    mov rdi, [rip + body_len]
    mov edx, 200
    call utf8_cut
    mov rdx, rax
    mov rsi, [rip + body_ptr]
    lea rdi, [rip + toast_buf]
    mov rcx, rdx
    push rdx
    push rdx
    call memcpy
    pop rdx
    pop rdx
    lea rdi, [rip + toast_buf]
    mov byte ptr [rdi + rdx], 0
    call app_toast
    mov rdi, [rip + cur_id]
    call reply_ok
    EPILOGUE

# ID status LEN + body -> ok ID: the extension's status text (at most 80 bytes; empty clears)
h_status:
    PROLOGUE
    mov rbx, [rip + cur]
    mov rdi, [rbx + EXT_status_text]
    call mem_free
    mov qword ptr [rbx + EXT_status_text], 0
    mov rsi, [rip + body_len]
    test rsi, rsi
    jz 1f
    mov rdi, rsi
    mov edx, 80
    mov rsi, [rip + body_ptr]
    call utf8_cut
    mov rsi, rax
    mov rdi, [rip + body_ptr]
    call mem_dup
    mov [rbx + EXT_status_text], rax
1:  mov dword ptr [rip + g_dirty], 1
    mov rdi, [rip + cur_id]
    call reply_ok
    EPILOGUE

# utf8_cut(len, ptr, max) -> the length to keep: at most max bytes, not ending inside a character
FN utf8_cut
    mov rax, rdi
    cmp rax, rdx
    jbe 9f
    mov rax, rdx
1:  test rax, rax
    jz 9f
    movzx ecx, byte ptr [rsi + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne 9f
    dec rax
    jmp 1b
9:  ret

# ID open LINE COL PATH -> ok ID DOC: a tab for the file, the cursor at the position (0 0 keeps it)
h_open:
    PROLOGUE
    cmp qword ptr [rip + nfields], 5
    jb .Lho_syntax
    mov edi, 2
    call field_u64
    test edx, edx
    jz .Lho_syntax
    mov r12, rax                # line
    mov edi, 3
    call field_u64
    test edx, edx
    jz .Lho_syntax
    mov r13, rax                # col
    mov edi, 4
    call rest_from
    mov rdi, rax
    mov rsi, rdx
    cmp byte ptr [rdi], '/'
    je 1f
.ifdef WINDOWS
    # D:/x, D:\x, \\server\share are absolute too
    cmp byte ptr [rdi], 92
    je 1f
    cmp rsi, 3
    jb 4f
    cmp byte ptr [rdi + 1], ':'
    jne 4f
    cmp byte ptr [rdi + 2], '/'
    je 1f
    cmp byte ptr [rdi + 2], 92
    je 1f
4:
.endif
    # relative: inside the project
    mov rcx, [rip + g_project]
    test rcx, rcx
    jz .Lho_nofile
    push rdi
    push rsi
    mov rdi, rcx
    call strlen
    pop rsi
    pop rdi
    push rsi
    push rdi
    lea rdi, [rip + out]
    call sb_clear
    lea rdi, [rip + out]
    mov rsi, [rip + g_project]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, '/'
    call sb_push_byte
    pop rsi
    pop rdx
    lea rdi, [rip + out]
    call sb_push
    mov rdi, [rip + out + SB_ptr]
    mov rsi, [rip + out + SB_len]
1:  call mem_dup
    mov r14, rax
.ifdef WINDOWS
    mov rdi, rax
    call win_slashes            # backslashes, as Windows programs write them
.endif
    mov rdi, r14
    call file_type
    cmp eax, 0x8000             # a regular file
    jne .Lho_missing
    mov rdi, [rip + cur]
    mov rsi, r14
    call ext_open_path
    mov r15, rax
    mov rdi, r14
    call mem_free
    test r15, r15
    jz .Lho_denied
    mov r14, r15
    mov rdi, r14
    call app_open_file
    mov rbx, rax
    mov rdi, r14
    call mem_free
    test rbx, rbx
    js .Lho_failed
    mov rdi, rbx
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne .Lho_notdoc
    mov rbx, [rax + TAB_doc]
    test r12, r12
    jz 1f
    cmp r12, [rbx + DOC_nlines]
    jbe 11f
    mov r12, [rbx + DOC_nlines]  # past the end: the last line
    mov r13, 1 << 40             # and its end
11: lea rsi, [r12 - 1]
    mov rdi, rbx
    call doc_line_start
    mov r15, rax
    lea rsi, [r12 - 1]
    mov rdi, rbx
    call doc_line_end
    sub rax, r15
    lea rcx, [r13 - 1]
    test r13, r13
    jz 2f
    cmp rcx, rax
    jbe 3f
2:  mov rcx, rax
3:  add r15, rcx
    mov rdi, rbx
    mov rsi, r15
    xor edx, edx
    call ed_set_cursor
1:  mov dword ptr [rip + g_dirty], 1
    mov rdi, [rip + cur_id]
    mov rsi, [rbx + DOC_id]
    call reply_ok_u64
    EPILOGUE
.Lho_missing:
    mov rdi, r14
    call mem_free
.Lho_nofile:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_nofile]
    call reply_error
    EPILOGUE
.Lho_denied:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_file_needs]
    call reply_error
    EPILOGUE
.Lho_notdoc:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_nodoc]
    call reply_error
    EPILOGUE
.Lho_failed:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_nofile]
    call reply_error
    EPILOGUE
.Lho_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# ID diagnostics DOC VERSION N + body -> ok ID: the extension's marks on the document
h_diagnostics:
    PROLOGUE
    mov edi, NEEDS_DOC_READ
    call need
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 6
    jb .Lhd_syntax
    mov edi, 2
    call arg_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov edi, 3
    call field_u64
    test edx, edx
    jz .Lhd_syntax
    cmp rax, [rbx + DOC_version]
    jne .Lhd_stale
    mov edi, 4
    call field_u64
    test edx, edx
    jz .Lhd_syntax
    cmp rax, MARKS_MAX
    ja .Lhd_toobig
    mov r12, rax
    mov rdi, rbx
    mov rsi, [rip + cur]
    mov rdx, [rip + body_ptr]
    mov rcx, [rip + body_len]
    mov r8, r12
    call extmarks_set
    test rax, rax
    jnz .Lhd_bad
    mov dword ptr [rip + g_dirty], 1
    mov rdi, [rip + cur_id]
    call reply_ok
9:  EPILOGUE
.Lhd_bad:
    mov rdi, [rip + cur_id]
    mov rsi, rax
    call reply_error
    EPILOGUE
.Lhd_stale:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_stale]
    mov rdx, [rbx + DOC_version]
    call reply_error_u64
    EPILOGUE
.Lhd_toobig:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_toobig]
    call reply_error
    EPILOGUE
.Lhd_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# ID hover DOC LINE COL LEN + body -> ok ID: shown if the pointer still rests there
h_hover:
    PROLOGUE
    mov edi, NEEDS_DOC_READ
    call need
    test eax, eax
    jz 9f
    cmp qword ptr [rip + nfields], 6
    jb .Lhh_syntax
    mov edi, 2
    call arg_doc
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rbx
    mov esi, 3
    call arg_pos
    test rax, rax
    js 9f
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rip + body_ptr]
    mov rcx, [rip + body_len]
    call ext_hover_text_set
    mov rdi, [rip + cur_id]
    call reply_ok
9:  EPILOGUE
.Lhh_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# ID cancel ID2 -> ok ID: requests are handled as they arrive, so there is nothing to withdraw
h_cancel:
    # of this extension's open prompt: the prompt closes, answered cancelled
    cmp qword ptr [rip + pr_id], 0
    je 1f
    mov rax, [rip + cur]
    cmp [rip + pr_ext], rax
    jne 1f
    mov edi, 2
    call field_u64
    test edx, edx
    jz 1f
    cmp rax, [rip + pr_id]
    jne 1f
    call palette_close          # extproto_prompt_abort answers it
1:  mov rdi, [rip + cur_id]
    jmp reply_ok

# field_at(i) -> rax ptr, rdx len
field_at:
    lea r8, [rip + fields]
    shl rdi, 4
    mov rax, [r8 + rdi]
    mov rdx, [r8 + rdi + 8]
    ret

# ---------------- gate 4: register, option, prompts, cmd ----------------

# ID register NAME KEYS TITLE -> ok ID: a command for this session
h_register:
    PROLOGUE
    cmp qword ptr [rip + nfields], 5
    jb .Lhreg_syntax
    mov edi, 2
    call field_at
    mov r12, rax
    mov r13, rdx                # name
    test rdx, rdx
    jz .Lhreg_syntax
    cmp rdx, 40
    ja .Lhreg_syntax
    xor ecx, ecx
1:  cmp rcx, r13
    jae 2f
    movzx eax, byte ptr [r12 + rcx]
    inc rcx
    cmp al, '_'
    je 1b
    sub al, '0'
    cmp al, 9
    jbe 1b
    sub al, 'a' - '0'
    cmp al, 25
    jbe 1b
    jmp .Lhreg_syntax
2:  mov edi, 4
    call rest_from
    mov rdi, rdx
    mov rsi, rax
    mov edx, 80
    push rsi
    call utf8_cut
    pop rsi
    mov rdx, rax
    lea rdi, [rip + out]
    push rsi
    push rdx
    call sb_clear
    pop rdx
    pop rsi
    lea rdi, [rip + out]
    call sb_push
    lea rdi, [rip + out]
    xor esi, esi
    call sb_push_byte           # the title, as a cstr
    mov edi, 3
    call field_at
    mov rcx, rax
    mov r8, rdx                 # keys
    mov rdi, [rip + cur]
    mov rsi, r12
    mov rdx, r13
    mov r9, [rip + out + SB_ptr]
    call ext_cmd_register
    test eax, eax
    jz 8f
    lea rsi, [rip + .Le_refused_name]
    cmp eax, 1
    je 7f
    lea rsi, [rip + .Le_toobig_cmds]
7:  mov rdi, [rip + cur_id]
    call reply_error
    EPILOGUE
8:  mov rdi, [rip + cur_id]
    call reply_ok
    EPILOGUE
.Lhreg_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# ID option DOC KEY VALUE -> ok ID: a per-document override (section 6c)
h_option:
    PROLOGUE
    cmp qword ptr [rip + nfields], 5
    jne .Lhop_syntax
    mov edi, 2
    call arg_doc
    test rax, rax
    jz .Lhop_ret
    mov rbx, rax
    xor r12d, r12d              # the key's index
1:  cmp r12d, 4
    jae .Lhop_syntax
    lea rax, [rip + opt_names]
    mov rsi, [rax + r12*8]
    mov edi, 3
    call field_is
    test eax, eax
    jnz 2f
    inc r12d
    jmp 1b
2:  cmp r12d, OPT_TRIM
    jb 21f
    mov edi, NEEDS_DOC_WRITE    # trim and the final newline change what is written to disk
    call need
    test eax, eax
    jz .Lhop_ret
21: mov edi, 4
    lea rsi, [rip + .Lo_dash]
    call field_is
    test eax, eax
    jz 3f
    # remove this extension's override
    mov rax, [rip + cur]
    cmp [rbx + DOC_oown + r12*8], rax
    jne 8f
    mov qword ptr [rbx + DOC_oown + r12*8], 0
    mov dword ptr [rbx + DOC_oval + r12*4], 0
    jmp 8f
3:  test r12d, r12d
    jnz 4f
    mov edi, 4
    call field_u64
    test edx, edx
    jz .Lhop_syntax
    test rax, rax
    jz .Lhop_syntax
    cmp rax, 16
    ja .Lhop_syntax
    jmp 6f
4:  mov eax, 2
    mov edi, 4
    lea rsi, [rip + .Lo_yes]
    call field_is
    test eax, eax
    mov eax, 2
    jnz 6f
    mov edi, 4
    lea rsi, [rip + .Lo_no]
    call field_is
    test eax, eax
    jz .Lhop_syntax
    mov eax, 1
6:  mov [rbx + DOC_oval + r12*4], eax
    mov rax, [rip + cur]
    mov [rbx + DOC_oown + r12*8], rax
8:  call ext_options_apply
    mov dword ptr [rip + g_dirty], 1
    mov rdi, [rip + cur_id]
    call reply_ok
.Lhop_ret:
    EPILOGUE
.Lhop_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# prompt_busy() -> 1 after replying busy when a prompt or the palette is open
prompt_busy:
    cmp qword ptr [rip + pr_id], 0
    jne 1f
    push rax
    call palette_is_open
    pop rcx
    test eax, eax
    jnz 1f
    xor eax, eax
    ret
1:  mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_busy]
    call reply_error
    mov eax, 1
    ret

# prompt_begin(kind): the open prompt is cur's current request
prompt_begin:
    push rbx
    mov [rip + pr_kind], rdi
    mov rax, [rip + cur]
    mov [rip + pr_ext], rax
    mov rax, [rip + cur_id]
    mov [rip + pr_id], rax
    call time_ms
    mov [rip + pr_opened], rax
    pop rbx
    ret

# extproto_prompt_fresh() -> 1 while a term prompt is less than half a second old: an Enter that
# early was meant for whatever had the focus before the prompt appeared
FN extproto_prompt_fresh
    xor eax, eax
    cmp qword ptr [rip + pr_kind], 3
    jne 9f
    push rbx
    call time_ms
    pop rbx
    sub rax, [rip + pr_opened]
    cmp rax, 500
    jge 8f
    mov eax, 1
    ret
8:  xor eax, eax
9:  ret

# prompt_clear(): no prompt is open
prompt_clear:
    push rbx
    mov rdi, [rip + pr_body]
    call mem_free
    mov qword ptr [rip + pr_body], 0
    mov qword ptr [rip + pr_id], 0
    mov qword ptr [rip + pr_ext], 0
    mov qword ptr [rip + pr_kind], 0
    pop rbx
    ret

# set_label(ptr, len): the prompt text into pr_label, the first line only, at most 200 bytes
set_label:
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 2f
    cmp byte ptr [rdi + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  push rdi
    mov rsi, rdi
    mov rdi, rcx
    mov edx, 200
    call utf8_cut
    pop rsi
    lea rdi, [rip + pr_label]
    mov rdx, rax
    mov byte ptr [rdi + rax], 0
    jmp memcpy

# ID choose LEN + body -> ok ID N when the user picks the N-th item (section 8), or cancelled
h_choose:
    PROLOGUE
    cmp qword ptr [rip + nfields], 3
    jne .Lhc_syntax
    call prompt_busy
    test eax, eax
    jnz .Lhc_ret
    mov r12, [rip + body_ptr]
    mov r13, [rip + body_len]
    # the first line is the prompt
    xor ebx, ebx
1:  cmp rbx, r13
    jae .Lhc_syntax             # no items
    cmp byte ptr [r12 + rbx], 10
    je 2f
    inc rbx
    jmp 1b
2:  mov rdi, r12
    mov rsi, rbx
    call set_label
    inc rbx                     # the items start here
    # count the item lines
    xor r14d, r14d              # items
    xor r15d, r15d              # non-empty items
    mov rcx, rbx
3:  cmp rcx, r13
    jae 4f
    mov rdx, rcx
31: cmp rdx, r13
    jae 32f
    cmp byte ptr [r12 + rdx], 10
    je 32f
    inc rdx
    jmp 31b
32: inc r14
    cmp rdx, rcx
    je 33f
    inc r15
33: lea rcx, [rdx + 1]
    jmp 3b
4:  test r15, r15
    jz .Lhc_syntax
    cmp r14, EXT_CHOOSE_MAX
    ja .Lhc_toobig
    # the items' bytes outlive the receive buffer
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rip + pr_body], rax
    mov r12, rax
    lea rdi, [rip + pr_label]
    call palette_choose_open
    xor r14d, r14d              # item number - 1
    mov rcx, rbx
5:  cmp rcx, r13
    jae 7f
    mov rdx, rcx
51: cmp rdx, r13
    jae 52f
    cmp byte ptr [r12 + rdx], 10
    je 52f
    inc rdx
    jmp 51b
52: inc r14
    mov rsi, rdx
    sub rsi, rcx
    jz 6f                       # an empty line keeps its number but is not shown
    push rcx
    push rdx
    lea rdi, [r12 + rcx]
    mov rdi, rsi
    lea rsi, [r12 + rcx]
    mov edx, 200
    call utf8_cut
    pop rdx
    pop rcx
    push rcx
    push rdx
    lea rdi, [r12 + rcx]
    mov rsi, rax
    mov rdx, r14
    call palette_choose_add
    pop rdx
    pop rcx
6:  lea rcx, [rdx + 1]
    jmp 5b
7:  call palette_choose_ready
    mov edi, 1
    call prompt_begin
.Lhc_ret:
    EPILOGUE
.Lhc_toobig:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_toobig_items]
    call reply_error
    EPILOGUE
.Lhc_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# ID ask LEN + body -> ok ID LEN + the answer, or cancelled
h_ask:
    PROLOGUE
    cmp qword ptr [rip + nfields], 3
    jne .Lha_syntax
    call prompt_busy
    test eax, eax
    jnz .Lha_ret
    mov rdi, [rip + body_ptr]
    mov rsi, [rip + body_len]
    call set_label
    lea rdi, [rip + pr_label]
    mov esi, PROMPT_ASK
    xor edx, edx
    xor ecx, ecx
    call palette_ext_prompt_open
    mov edi, 2
    call prompt_begin
.Lha_ret:
    EPILOGUE
.Lha_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# ID term LEN + body -> ok ID once the user ran it in the terminal, or cancelled
h_term:
    PROLOGUE
    cmp qword ptr [rip + nfields], 3
    jne .Lht_syntax
    mov edi, NEEDS_TERMINAL
    call need
    test eax, eax
    jz .Lht_ret
    mov r12, [rip + body_ptr]
    mov r13, [rip + body_len]
    test r13, r13
    jz .Lht_syntax
    cmp r13, EXT_TERM_MAX
    ja .Lht_toobig
    mov rdi, r12
    mov rsi, r13
    call plain_text             # one line of valid UTF-8, nothing that hides or reorders text
    test eax, eax
    jz .Lht_syntax              # what is shown is what runs
    call prompt_busy
    test eax, eax
    jnz .Lht_ret
    lea rdi, [rip + .Lrun_label]
    mov esi, PROMPT_TERM
    mov rdx, r12
    mov rcx, r13
    call palette_ext_prompt_open
    call palette_field
    mov qword ptr [rax + TF_cur], 0     # the start of the command is what the user sees
    mov qword ptr [rax + TF_anchor], 0
    mov edi, 3
    call prompt_begin
.Lht_ret:
    EPILOGUE
.Lht_toobig:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_toobig_term]
    call reply_error
    EPILOGUE
.Lht_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# ID cmd NAME -> ok ID: one of rhun's own commands, from the list of section 8a
# ---------------- views (section 12a) ----------------

# view_agreed() -> ZF clear when the views feature was agreed; otherwise the reply is sent
view_agreed:
    mov rax, [rip + cur]
    test dword ptr [rax + EXT_features], FEAT_VIEWS
    jnz 1f
    push rax
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_unknown]
    call reply_error
    pop rax
    xor eax, eax                # ZF set: answered
1:  ret

# ID view TITLE -> ok ID VIEW
h_view:
    PROLOGUE
    call view_agreed
    jz 9f
    cmp qword ptr [rip + nfields], 3
    jb .Lhvw_syntax
    mov edi, 2
    call rest_from
    mov rdi, [rip + cur]
    mov rsi, rax
    call extview_open
    test rax, rax
    js .Lhvw_toobig
    mov rdi, [rip + cur_id]
    mov rsi, rax
    call reply_ok_u64
    EPILOGUE
.Lhvw_toobig:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_toobig_views]
    call reply_error
    EPILOGUE
.Lhvw_syntax:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_syntax]
    call reply_error
9:  EPILOGUE

# view_arg() -> rax the VW* named by field 2, or 0 with the reply sent
view_arg:
    PROLOGUE
    cmp qword ptr [rip + nfields], 3
    jb 7f
    mov edi, 2
    call field_u64
    test edx, edx
    jz 8f
    mov rdi, [rip + cur]
    mov esi, eax
    call extview_find
    test rax, rax
    jnz 9f
8:  mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_noview]
    call reply_error
    xor eax, eax
    EPILOGUE
7:  mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_syntax]
    call reply_error
    xor eax, eax
9:  EPILOGUE

# ID draw VIEW LEN + body -> ok ID: the view's picture
h_draw:
    PROLOGUE
    call view_agreed
    jz 9f
    call view_arg
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, [rip + body_ptr]
    mov rdx, [rip + body_len]
    call extview_set
    test eax, eax
    jnz 1f
    mov rdi, [rip + cur_id]
    call reply_ok
    EPILOGUE
1:  mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_syntax_line]
    mov edx, eax
    call reply_error_u64
9:  EPILOGUE

# ID unview VIEW -> ok ID: its tab closes
h_unview:
    PROLOGUE
    call view_agreed
    jz 9f
    call view_arg
    test rax, rax
    jz 9f
    mov rdi, rax
    call extview_close
    mov rdi, [rip + cur_id]
    call reply_ok
9:  EPILOGUE

h_cmd:
    PROLOGUE
    cmp qword ptr [rip + nfields], 3
    jne .Lhcm_syntax
    lea rbx, [rip + cmd_allow]
1:  mov rsi, [rbx]
    test rsi, rsi
    jz .Lhcm_refused
    add rbx, 16
    mov edi, 2
    call field_is
    test eax, eax
    jz 1b
    mov edi, [rbx - 8]          # what the command needs: a document write, the terminal
    test edi, edi
    jz 2f
    call need
    test eax, eax
    jz .Lhcm_ret
2:  mov edi, 2
    call field_at
    mov rdi, rax
    mov rsi, rdx
    call cmd_find
    test rax, rax
    jz .Lhcm_refused
    mov r12, rax
    mov rdi, [rip + cur_id]
    call reply_ok
    mov rdi, r12
    call [r12 + CMD_fn]
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
.Lhcm_refused:
    mov rdi, [rip + cur_id]
    lea rsi, [rip + .Le_refused_cmd]
    call reply_error
.Lhcm_ret:
    EPILOGUE

# plain_text(ptr, len) -> 1 when the bytes are one line of valid UTF-8 with no control
# character (C0, DEL, C1), no bidi control (U+202A-202E, U+2066-2069) and no zero-width
# character (U+200B-200F, U+2060, U+FEFF): text that shows as it is
plain_text:
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 9f
    movzx eax, byte ptr [rdi + rcx]
    cmp al, 0x20
    jb 8f
    cmp al, 0x7f
    je 8f
    jb 7f                       # ASCII
    cmp al, 0xc2
    jb 8f                       # a continuation byte or an overlong lead
    cmp al, 0xf4
    ja 8f
    # the sequence length and its continuation bytes
    mov edx, 1
    cmp al, 0xe0
    jb 2f
    inc edx
    cmp al, 0xf0
    jb 2f
    inc edx
2:  lea r8, [rcx + rdx]
    cmp r8, rsi
    jae 8f                      # cut short
    push rcx
    push rdx
3:  inc rcx
    movzx r9d, byte ptr [rdi + rcx]
    and r9d, 0xc0
    cmp r9d, 0x80
    jne 6f
    dec edx
    jnz 3b
    pop rdx
    pop rcx
    # the characters that hide or reorder what follows
    cmp al, 0xc2
    jne 4f
    movzx r9d, byte ptr [rdi + rcx + 1]
    cmp r9d, 0xa0
    jb 8f                       # U+0080-009F
4:  cmp al, 0xe2
    jne 5f
    movzx r9d, byte ptr [rdi + rcx + 1]
    movzx r10d, byte ptr [rdi + rcx + 2]
    cmp r9d, 0x80
    jne 41f
    cmp r10d, 0x8b
    jb 5f
    cmp r10d, 0x8f
    jbe 8f                      # U+200B-200F
    cmp r10d, 0xaa
    jb 5f
    cmp r10d, 0xae
    jbe 8f                      # U+202A-202E
    jmp 5f
41: cmp r9d, 0x81
    jne 5f
    cmp r10d, 0xa0
    je 8f                       # U+2060
    cmp r10d, 0xa6
    jb 5f
    cmp r10d, 0xa9
    jbe 8f                      # U+2066-2069
5:  cmp al, 0xef
    jne 51f
    cmp byte ptr [rdi + rcx + 1], 0xbb
    jne 51f
    cmp byte ptr [rdi + rcx + 2], 0xbf
    je 8f                       # U+FEFF
51: add rcx, rdx
7:  inc rcx
    jmp 1b
6:  pop rdx
    pop rcx
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret
.Lhcm_syntax:
    mov rdi, [rip + cur_id]
    call reply_syntax
    EPILOGUE

# extproto_prompt_abort(): the open prompt, if any, is answered cancelled (the palette closed or
# changed mode under it)
FN extproto_prompt_abort
    PROLOGUE
    cmp qword ptr [rip + pr_id], 0
    je 9f
    mov rbx, [rip + cur]
    mov rax, [rip + pr_ext]
    mov [rip + cur], rax
    mov rdi, [rip + pr_id]
    lea rsi, [rip + .Le_cancelled]
    call reply_error
    mov [rip + cur], rbx
    call prompt_clear
9:  EPILOGUE

# extproto_prompt_chose(n): the user picked item n of the choose prompt
FN extproto_prompt_chose
    PROLOGUE
    cmp qword ptr [rip + pr_id], 0
    je 9f
    mov r12, rdi
    mov rbx, [rip + cur]
    mov rax, [rip + pr_ext]
    mov [rip + cur], rax
    mov rdi, [rip + pr_id]
    mov rsi, r12
    call reply_ok_u64
    mov [rip + cur], rbx
    call prompt_clear
9:  EPILOGUE

# extproto_prompt_text(ptr, len, PROMPT_ASK | PROMPT_TERM): the user accepted the field's text
FN extproto_prompt_text
    PROLOGUE
    cmp qword ptr [rip + pr_id], 0
    je 9f
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov rbx, [rip + cur]
    mov rax, [rip + pr_ext]
    mov [rip + cur], rax
    cmp r14d, PROMPT_TERM
    je 5f
    # ask: "ok ID LEN" + the answer
    call out_begin
    lea rdi, [rip + .Lw_ok_sp]
    call out_cstr
    mov rdi, [rip + pr_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r13
    call out_u64
    mov edi, 10
    call out_byte
    mov rdi, r12
    mov rsi, r13
    call out_bytes
    call out_end
    jmp 8f
5:  # term: an empty line is a dismissal; otherwise the line runs in the terminal panel
    test r13, r13
    jnz 6f
    mov rdi, [rip + pr_id]
    lea rsi, [rip + .Le_cancelled]
    call reply_error
    jmp 8f
6:  mov rdi, r12
    mov rsi, r13
    call plain_text             # the user may have edited it: the same rule
    test eax, eax
    jz 61f
    lea rdi, [rip + pr_cmd]
    call sb_clear
    lea rdi, [rip + pr_cmd]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + pr_cmd]
    mov esi, 10
    call sb_push_byte
    cmp dword ptr [rip + g_term_open], 0
    jne 7f
    call term_show
7:  mov rdi, [rip + pr_cmd + SB_ptr]
    mov rsi, [rip + pr_cmd + SB_len]
    call term_panel_write       # typed into the shell, not pasted: Enter is Enter
    test eax, eax
    jz 61f
    mov rdi, [rip + pr_id]
    call reply_ok
    jmp 8f
61: mov rdi, [rip + pr_id]
    lea rsi, [rip + .Le_cancelled]
    call reply_error
8:  mov [rip + cur], rbx
    call prompt_clear
9:  EPILOGUE

# extproto_prompt_owner_gone(ext): the extension stopped: its prompt leaves the screen unanswered
FN extproto_prompt_owner_gone
    push rbx
    cmp qword ptr [rip + pr_id], 0
    je 9f
    cmp [rip + pr_ext], rdi
    jne 9f
    call prompt_clear
    call palette_is_open
    test eax, eax
    jz 9f
    call palette_close
9:  pop rbx
    ret

# ---------------- events ----------------

# send_settings(ext): "0 setting KEY VALUE" for each of its own settings
send_settings:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + EXT_sdefs + VEC_len]
    jae 9f
    imul rsi, r12, SD_SIZE
    add rsi, [rbx + EXT_sdefs + VEC_ptr]
    inc r12
    mov rdi, rbx
    call extproto_send_setting
    jmp 1b
9:  EPILOGUE

# extproto_send_setting(ext, sd): "0 setting KEY VALUE"
FN extproto_send_setting
    PROLOGUE
    mov rbx, rsi
    mov r12, [rip + cur]
    mov [rip + cur], rdi
    call out_begin
    lea rdi, [rip + .Lev_setting]
    call out_cstr
    mov rdi, [rbx + SD_key]
    call out_cstr
    mov edi, ' '
    call out_byte
    mov rdi, [rbx + SD_value]
    call out_cstr
    mov edi, 10
    call out_byte
    call out_end
    mov [rip + cur], r12
    EPILOGUE

# FN extproto_doc(id) -> rax the open document with that id, or 0 (it may have been closed)
FN extproto_doc
    jmp doc_by_id

# FN extproto_matches(patterns, doc) -> eax 1 when the document's name matches the patterns
FN extproto_matches
    jmp sub_matches

# FN extproto_host_request(ext, verb, doc, kind, ch) -> rax the id of "ID VERB DOC VERSION LINE COL
# KIND CHAR" sent to the extension (section 12), or 0: every event about the document goes first,
# and a document it does not know is not asked about
FN extproto_host_request
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rsi
    mov r12, rdx
    mov [rsp + 8], rcx
    mov [rsp + 16], r8d
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 8f
    mov rdi, rbx
    call extproto_events
    mov rdi, rbx
    mov rsi, [r12 + DOC_id]
    call known_find
    test rax, rax
    jz 8f
    mov [rip + cur], rbx
    inc qword ptr [rbx + EXT_hreq]
    mov r13, [rbx + EXT_hreq]
    call out_begin
    mov rdi, r13
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, [rsp]
    call out_cstr
    mov edi, ' '
    call out_byte
    mov rdi, [r12 + DOC_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, [r12 + DOC_version]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r12
    mov rsi, [r12 + DOC_cur]
    call doc_line_of
    mov r14, rax
    lea rdi, [rax + 1]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r12
    mov rsi, r14
    call doc_line_start
    mov rdi, [r12 + DOC_cur]
    sub rdi, rax
    inc rdi
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, [rsp + 8]
    call out_cstr
    mov edi, ' '
    call out_byte
    mov edi, [rsp + 16]
    lea rsi, [rsp + 20]
    call utf8_encode
    lea rdi, [rsp + 20]
    mov rsi, rax
    call out_bytes
    mov edi, 10
    call out_byte
    call out_end
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN extproto_host_send(ext, doc, line, len) -> rax the id of "ID LINE" sent to the extension, or
# 0: every event about the document goes first, and a document it does not know is not asked about
FN extproto_host_send
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 8f
    mov rdi, rbx
    call extproto_events
    mov rdi, rbx
    mov rsi, [r12 + DOC_id]
    call known_find
    test rax, rax
    jz 8f
    mov [rip + cur], rbx
    inc qword ptr [rbx + EXT_hreq]
    mov r15, [rbx + EXT_hreq]
    call out_begin
    mov rdi, r15
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, r13
    mov rsi, r14
    call out_bytes
    mov edi, 10
    call out_byte
    call out_end
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN extproto_send_action(ext, data, len): "0 action LEN" and the bytes of a chosen code action
FN extproto_send_action
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 9f
    mov [rip + cur], rbx
    call out_begin
    lea rdi, [rip + .Lev_action]
    call out_cstr
    mov rdi, r13
    call out_u64
    mov edi, 10
    call out_byte
    mov rdi, r12
    mov rsi, r13
    call out_bytes
    call out_end
9:  EPILOGUE

# FN extproto_send_cancel(ext, id): "0 cancel ID", a request rhun no longer needs the answer to
FN extproto_send_cancel
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov [rip + cur], rbx
    call out_begin
    lea rdi, [rip + .Lev_cancel]
    call out_cstr
    mov rdi, r12
    call out_u64
    mov edi, 10
    call out_byte
    call out_end
    EPILOGUE

# send_ready(ext): "0 ready PROJECT"
# hello_features(ext): EXT_features from the names after "hello 1" (the fields of the current line),
# and "0 features NAME..." with those rhun knows, when there are any
hello_features:
    PROLOGUE
    mov rbx, rdi
    mov [rip + cur], rdi
    mov dword ptr [rbx + EXT_features], 0
    mov r12d, 2                 # the field
1:  cmp r12, [rip + nfields]
    jae 4f
    lea r13, [rip + feature_names]
    xor r14d, r14d              # the feature's bit index
2:  mov rsi, [r13 + r14*8]
    test rsi, rsi
    jz 3f
    mov edi, r12d
    call field_is
    test eax, eax
    jz 21f
    mov ecx, r14d
    mov eax, 1
    shl eax, cl
    or [rbx + EXT_features], eax
21: inc r14d
    jmp 2b
3:  inc r12d
    jmp 1b
4:  and dword ptr [rbx + EXT_features], FEAT_HOST
    cmp dword ptr [rbx + EXT_features], 0
    je 9f
    call out_begin
    lea rdi, [rip + .Lev_features]
    call out_cstr
    xor r14d, r14d
5:  lea rax, [rip + feature_names]
    mov rsi, [rax + r14*8]
    test rsi, rsi
    jz 7f
    mov eax, [rbx + EXT_features]
    mov ecx, r14d
    shr eax, cl
    test eax, 1
    jz 6f
    mov edi, ' '
    push rsi
    push rsi
    call out_byte
    pop rdi
    pop rsi
    call out_cstr
6:  inc r14d
    jmp 5b
7:  mov edi, 10
    call out_byte
    call out_end
9:  EPILOGUE

send_ready:
    PROLOGUE
    mov [rip + cur], rdi
    call out_begin
    lea rdi, [rip + .Lev_ready]
    call out_cstr
    mov rdi, [rip + g_project]
    test rdi, rdi
    jnz 1f
    lea rdi, [rip + .Ldash]
1:  call out_cstr
    mov edi, 10
    call out_byte
    call out_end
    EPILOGUE

# extproto_send_run(ext, command index): "0 run NAME DOC"
FN extproto_send_run
    PROLOGUE
    mov rbx, rsi
    # what changed since the last tick goes first: the extension must know the document
    # (opened, active) before it is asked to act on it
    call extproto_events
    mov rax, [rip + cur]
    cmp dword ptr [rax + EXT_status], ES_RUNNING
    jne 9f
    call out_begin
    lea rdi, [rip + .Lev_run]
    call out_cstr
    imul rax, rbx, CMD_SIZE
    add rax, [rip + g_ext_cmds + VEC_ptr]
    mov rdi, [rax + CMD_name]
    call out_cstr
    mov edi, ' '
    call out_byte
    call active_doc_id
    mov rdi, rax
    call out_u64
    mov edi, 10
    call out_byte
    call out_end
9:  EPILOGUE

# active_doc_id() -> the active document's id, or 0
active_doc_id:
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 8f
    cmp rdi, [rip + g_tabs + VEC_len]
    jae 8f
    imul rax, rdi, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 8f
    mov rax, [rax + TAB_doc]
    test rax, rax
    jz 8f
    mov rax, [rax + DOC_id]
    ret
8:  xor eax, eax
    ret

# extproto_events(ext): what changed since the extension was last told, as events
FN extproto_events
    PROLOGUE
    mov rbx, rdi
    mov [rip + cur], rbx
    # forget nothing yet: mark every known document unseen
    xor ecx, ecx
1:  cmp rcx, [rbx + EXT_known + VEC_len]
    jae 2f
    imul rax, rcx, XK_SIZE
    add rax, [rbx + EXT_known + VEC_ptr]
    mov qword ptr [rax + XK_seen], 0
    inc rcx
    jmp 1b
2:  # every open document
    xor r12d, r12d
.Lev_tabs:
    cmp r12, [rip + g_tabs + VEC_len]
    jae .Lxe_closed
    imul rax, r12, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    inc r12
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne .Lev_tabs
    mov r13, [rax + TAB_doc]
    test r13, r13
    jz .Lev_tabs
    mov rdi, rbx
    mov rsi, [r13 + DOC_id]
    call known_find
    test rax, rax
    jnz 3f
    # new to this extension
    mov rdi, [rbx + EXT_sub_opened]
    mov rsi, r13
    call sub_matches            # opened is the gate: a document never opened to it stays unknown
    test eax, eax
    jz .Lev_tabs
    lea rdi, [rbx + EXT_known]
    mov esi, XK_SIZE
    call vec_push
    mov r14, rax
    mov rcx, [r13 + DOC_id]
    mov [r14 + XK_id], rcx
    mov rcx, [r13 + DOC_version]
    mov [r14 + XK_ver], rcx
    mov rcx, [r13 + DOC_saves]
    mov [r14 + XK_saves], rcx
    mov rcx, [r13 + DOC_cur]
    mov [r14 + XK_cur], rcx
    mov rcx, [r13 + DOC_anchor]
    mov [r14 + XK_anchor], rcx
    mov qword ptr [r14 + XK_seen], 2    # new this pass: no edits for it yet
    mov rax, [r13 + DOC_xedits]
    xor rcx, rcx
    test rax, rax
    jz 30f
    mov rcx, [rax + SB_len]
30: mov [r14 + XK_eoff], rcx           # the records so far are in the text it is told about
    cmp qword ptr [rbx + EXT_sub_opened], 0
    je 31f
    mov rdi, r13
    call send_opened
31: # the active document's position is part of the snapshot, sent after `active` below
    call active_doc_id
    cmp rax, [r13 + DOC_id]
    jne .Lev_tabs
    mov qword ptr [r14 + XK_cur], -1
    mov qword ptr [r14 + XK_anchor], -1
    jmp .Lev_tabs
3:  mov r14, rax
    mov qword ptr [r14 + XK_seen], 1
    # edits since the last frame, or a resync, for an edits subscriber
    mov rdi, [rbx + EXT_sub_edits]
    mov rsi, r13
    call sub_matches
    test eax, eax
    jz 30f
    cmp dword ptr [r13 + DOC_xresync], 0
    je 29f
    lea rdi, [rip + .Lev_resync]
    mov rsi, r13
    call send_doc_version
    jmp 30f
29: mov rax, [r13 + DOC_xedits]
    test rax, rax
    jz 30f
    mov rcx, [r14 + XK_eoff]
    cmp rcx, [rax + SB_len]
    jae 30f
    mov rdi, r13
    mov rsi, r14
    call send_edits
30: # changed? (before saved, so a save after a change reports both)
    mov rcx, [r13 + DOC_version]
    cmp rcx, [r14 + XK_ver]
    je 4f
    mov [r14 + XK_ver], rcx
    mov rdi, [rbx + EXT_sub_changed]
    mov rsi, r13
    call sub_matches
    test eax, eax
    jz 4f
    lea rdi, [rip + .Lev_changed]
    mov rsi, r13
    call send_doc_version
4:  # saved?
    mov rcx, [r13 + DOC_saves]
    cmp rcx, [r14 + XK_saves]
    je 5f
    mov [r14 + XK_saves], rcx
    mov rdi, [rbx + EXT_sub_saved]
    mov rsi, r13
    call sub_matches
    test eax, eax
    jz 5f
    lea rdi, [rip + .Lev_saved]
    mov rsi, r13
    call send_doc_version
5:  # cursor or selection?
    mov rcx, [r13 + DOC_cur]
    mov rdx, [r13 + DOC_anchor]
    cmp rcx, [r14 + XK_cur]
    jne 6f
    cmp rdx, [r14 + XK_anchor]
    je .Lev_tabs
6:  mov rax, [r14 + XK_cur]
    cmp rax, [r14 + XK_anchor]
    setne r15b                  # a selection existed before
    cmp rax, rcx
    sete r15b                   # bit 1: the cursor itself did not move
    shl r15b, 1
    mov rax, [r14 + XK_cur]
    cmp rax, [r14 + XK_anchor]
    setne al
    or r15b, al
    mov [r14 + XK_cur], rcx
    mov [r14 + XK_anchor], rdx
    # the cursor moved: cursor subscribers hear it, selection or not
    test r15b, 2
    jnz 62f
    mov rdi, [rbx + EXT_sub_cursor]
    mov rsi, r13
    call sub_matches
    test eax, eax
    jz 62f
    mov rdi, r13
    call send_cursor
62: # a selection exists, or one just collapsed: selection subscribers hear the range
    mov rcx, [r14 + XK_cur]
    cmp rcx, [r14 + XK_anchor]
    jne 7f
    test r15b, 1
    jz .Lev_tabs
7:  mov rdi, [rbx + EXT_sub_selection]
    mov rsi, r13
    call sub_matches
    test eax, eax
    jz .Lev_tabs
    mov rdi, r13
    call send_selection
    jmp .Lev_tabs
.Lxe_closed:
    # known documents that are gone
    xor r12d, r12d
8:  cmp r12, [rbx + EXT_known + VEC_len]
    jae .Lxe_active
    imul rax, r12, XK_SIZE
    add rax, [rbx + EXT_known + VEC_ptr]
    cmp qword ptr [rax + XK_seen], 0
    jne 81f
    mov rdi, [rax + XK_id]
    call send_closed
    # remove: move the last into this slot
    mov rcx, [rbx + EXT_known + VEC_len]
    dec rcx
    mov [rbx + EXT_known + VEC_len], rcx
    imul rsi, rcx, XK_SIZE
    add rsi, [rbx + EXT_known + VEC_ptr]
    imul rdi, r12, XK_SIZE
    add rdi, [rbx + EXT_known + VEC_ptr]
    mov edx, XK_SIZE
    call memcpy
    jmp 8b
81: inc r12
    jmp 8b
.Lxe_active:
    call active_doc_id
    cmp rax, [rbx + EXT_active]
    je 85f
    mov [rbx + EXT_active], rax
    mov rdi, rax
    call send_active
85: # positions held back during catch-up (XK_cur -1): the active document's, now
    xor r12d, r12d
86: cmp r12, [rbx + EXT_known + VEC_len]
    jae 9f
    imul r14, r12, XK_SIZE
    add r14, [rbx + EXT_known + VEC_ptr]
    inc r12
    cmp qword ptr [r14 + XK_cur], -1
    jne 86b
    mov rdi, [r14 + XK_id]
    call doc_by_id
    test rax, rax
    jz 86b
    mov r13, rax
    mov rcx, [r13 + DOC_cur]
    mov rdx, [r13 + DOC_anchor]
    mov [r14 + XK_cur], rcx
    mov [r14 + XK_anchor], rdx
    mov rdi, [rbx + EXT_sub_cursor]
    mov rsi, r13
    call sub_matches
    test eax, eax
    jz 88f
    mov rdi, r13
    call send_cursor
88: mov rcx, [r14 + XK_cur]
    cmp rcx, [r14 + XK_anchor]
    je 86b
    mov rdi, [rbx + EXT_sub_selection]
    mov rsi, r13
    call sub_matches
    test eax, eax
    jz 86b
    mov rdi, r13
    call send_selection
    jmp 86b
9:  EPILOGUE

# extproto_known(ext, id) -> XK* or 0: what the extension was told about the document
FN extproto_known
    jmp known_find

# known_find(ext, id) -> XK* or 0
known_find:
    xor ecx, ecx
1:  cmp rcx, [rdi + EXT_known + VEC_len]
    jae 8f
    imul rax, rcx, XK_SIZE
    add rax, [rdi + EXT_known + VEC_ptr]
    inc rcx
    cmp [rax + XK_id], rsi
    jne 1b
    ret
8:  xor eax, eax
    ret

# sub_matches(patterns cstr or 0, doc) -> 1 when the document's name matches ("*" matches all,
# untitled documents too)
sub_matches:
    PROLOGUE
    test rdi, rdi
    jz 8f
    mov rbx, rdi
    mov r12, rsi
    cmp byte ptr [rbx], '*'
    jne 1f
    cmp byte ptr [rbx + 1], 0
    je 9f
1:  mov rdi, [r12 + DOC_path]
    test rdi, rdi
    jz 8f
    mov rsi, rbx
    call ext_path_matches
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# send_opened(doc): "0 opened DOC VERSION LANG PATH"
send_opened:
    PROLOGUE
    mov rbx, rdi
    call out_begin
    lea rdi, [rip + .Lev_opened]
    call out_cstr
    mov rdi, [rbx + DOC_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, [rbx + DOC_version]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rax, [rbx + DOC_lang]
    test rax, rax
    jz 1f
    mov rdi, [rax + GR_name]
    call out_word               # "Visual Basic" travels as Visual_Basic
    jmp 2f
1:  lea rdi, [rip + .Ldash]
    call out_cstr
2:  mov edi, ' '
    call out_byte
    mov rdi, [rbx + DOC_path]
    test rdi, rdi
    jnz 3f
    lea rdi, [rip + .Ldash]
3:  call out_cstr
    mov edi, 10
    call out_byte
    call out_end
    EPILOGUE

# out_word(cstr): the text with each space as an underscore
out_word:
    push rbx
    mov rbx, rdi
1:  movzx edi, byte ptr [rbx]
    test edi, edi
    jz 9f
    cmp edi, ' '
    jne 2f
    mov edi, '_'
2:  call out_byte
    inc rbx
    jmp 1b
9:  pop rbx
    ret

# extproto_send_project_all(): "0 project PATH" to every running extension
FN extproto_send_project_all
    PROLOGUE
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 1b
    mov [rip + cur], rbx
    call out_begin
    lea rdi, [rip + .Lev_project]
    call out_cstr
    mov rdi, [rip + g_project]
    test rdi, rdi
    jnz 2f
    lea rdi, [rip + .Ldash]
2:  call out_cstr
    mov edi, 10
    call out_byte
    call out_end
    jmp 1b
9:  EPILOGUE

# send_doc_version(event cstr "0 saved ", doc): "EVENT DOC VERSION"
send_doc_version:
    PROLOGUE
    mov rbx, rsi
    mov r12, rdi
    call out_begin
    mov rdi, r12
    call out_cstr
    mov rdi, [rbx + DOC_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, [rbx + DOC_version]
    call out_u64
    mov edi, 10
    call out_byte
    call out_end
    EPILOGUE

# send_edits(doc, xk): "0 edits DOC VERSION LEN" + the records this extension has not had yet
# (from XK_eoff to the end of the frame's records); the offset moves to the end
send_edits:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call out_begin
    lea rdi, [rip + .Lev_edits]
    call out_cstr
    mov rdi, [rbx + DOC_id]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rdi, [rbx + DOC_version]
    call out_u64
    mov edi, ' '
    call out_byte
    mov rax, [rbx + DOC_xedits]
    mov r13, [r12 + XK_eoff]
    mov rdi, [rax + SB_len]
    sub rdi, r13
    call out_u64
    mov edi, 10
    call out_byte
    mov rax, [rbx + DOC_xedits]
    mov rdi, [rax + SB_ptr]
    add rdi, r13
    mov rsi, [rax + SB_len]
    sub rsi, r13
    mov [r12 + XK_eoff], rsi
    add [r12 + XK_eoff], r13
    call out_bytes
    call out_end
    EPILOGUE

# snapshot_taken(doc): the extension was just given the document's text (text, range): the
# records so far are in what it has
snapshot_taken:
    push rbx
    mov rbx, rdi
    mov rdi, [rip + cur]
    mov rsi, [rbx + DOC_id]
    call known_find
    test rax, rax
    jz 9f
    mov rcx, [rbx + DOC_xedits]
    xor edx, edx
    test rcx, rcx
    jz 1f
    mov rdx, [rcx + SB_len]
1:  mov [rax + XK_eoff], rdx
9:  pop rbx
    ret

# extproto_send_hover_all(doc, pos): "0 hover DOC LINE COL" to the running extensions whose
# hover subscription names the document
FN extproto_send_hover_all
    PROLOGUE
    mov r13, rdi
    mov r14, rsi
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 1b
    mov rdi, [rbx + EXT_sub_hover]
    mov rsi, r13
    call sub_matches
    test eax, eax
    jz 1b
    mov [rip + cur], rbx
    call out_begin
    lea rdi, [rip + .Lev_hover]
    call out_cstr
    mov rdi, [r13 + DOC_id]
    call out_u64
    mov rdi, r13
    mov rsi, r14
    call out_pos
    mov edi, 10
    call out_byte
    call out_end
    jmp 1b
9:  EPILOGUE

# out_pos(doc, pos): " LINE COL"
out_pos:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov r13, rax
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov r14, r12
    sub r14, rax
    mov edi, ' '
    call out_byte
    lea rdi, [r13 + 1]
    call out_u64
    mov edi, ' '
    call out_byte
    lea rdi, [r14 + 1]
    call out_u64
    EPILOGUE

# send_cursor(doc): "0 cursor DOC LINE COL"
send_cursor:
    PROLOGUE
    mov rbx, rdi
    call out_begin
    lea rdi, [rip + .Lev_cursor]
    call out_cstr
    mov rdi, [rbx + DOC_id]
    call out_u64
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call out_pos
    mov edi, 10
    call out_byte
    call out_end
    EPILOGUE

# send_selection(doc): "0 selection DOC L1 C1 L2 C2" (anchor, then cursor)
send_selection:
    PROLOGUE
    mov rbx, rdi
    call out_begin
    lea rdi, [rip + .Lev_selection]
    call out_cstr
    mov rdi, [rbx + DOC_id]
    call out_u64
    mov rdi, rbx
    mov rsi, [rbx + DOC_anchor]
    call out_pos
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call out_pos
    mov edi, 10
    call out_byte
    call out_end
    EPILOGUE

# send_closed(id): "0 closed DOC"
send_closed:
    push rdi
    call out_begin
    lea rdi, [rip + .Lev_closed]
    call out_cstr
    pop rdi
    call out_u64
    mov edi, 10
    call out_byte
    jmp out_end

# send_active(id): "0 active DOC"
send_active:
    push rdi
    call out_begin
    lea rdi, [rip + .Lev_active]
    call out_cstr
    pop rdi
    call out_u64
    mov edi, 10
    call out_byte
    jmp out_end

.section .rodata
.p2align 3
# verb table: name, handler, body cap (0: no body)
verbs:
    .quad .Lv_text, h_text, 0
    .quad .Lv_range, h_range, 0
    .quad .Lv_replace, h_replace, EXT_BODY_MAX
    .quad .Lv_insert, h_insert, EXT_BODY_MAX
    .quad .Lv_select, h_select, 0
    .quad .Lv_toast, h_toast, EXT_BODY_MAX
    .quad .Lv_status, h_status, EXT_BODY_MAX
    .quad .Lv_open, h_open, 0
    .quad .Lv_cancel, h_cancel, 0
    .quad .Lv_diagnostics, h_diagnostics, EXT_BODY_MAX
    .quad .Lv_hover, h_hover, EXT_BODY_MAX
    .quad .Lv_register, h_register, 0
    .quad .Lv_option, h_option, 0
    .quad .Lv_choose, h_choose, EXT_BODY_MAX
    .quad .Lv_ask, h_ask, EXT_BODY_MAX
    .quad .Lv_term, h_term, EXT_BODY_MAX
    .quad .Lv_cmd, h_cmd, 0
    .quad .Lv_view, h_view, 0
    .quad .Lv_draw, h_draw, VIEW_BODY_MAX
    .quad .Lv_unview, h_unview, 0
    .quad .Lv_apply, h_apply, EXT_BODY_MAX
    .quad 0, 0, 0
.Lv_register: .asciz "register"
.Lv_option: .asciz "option"
.Lv_choose: .asciz "choose"
.Lv_ask: .asciz "ask"
.Lv_term: .asciz "term"
.Lv_cmd: .asciz "cmd"
.Lv_view: .asciz "view"
.Lv_draw: .asciz "draw"
.Lv_unview: .asciz "unview"
.Lv_apply: .asciz "apply"
.Le_toobig_views: .asciz "toobig 8 views"
.Le_noview: .asciz "noview no such view"
.Le_syntax_line: .asciz "syntax line "
.Lo_tab: .asciz "tab_width"
.Lo_spaces: .asciz "insert_spaces"
.Lo_trim: .asciz "trim_trailing_whitespace"
.Lo_final: .asciz "final_newline"
.Lo_yes: .asciz "yes"
.Lo_no: .asciz "no"
.Lo_dash: .asciz "-"
.Le_busy: .asciz "busy a prompt is open"
.Le_cancelled: .asciz "cancelled"
.Le_refused_cmd: .asciz "refused not a command an extension may run"
.Le_refused_name: .asciz "refused the name is in use"
.Le_toobig_cmds: .asciz "toobig 64 commands"
.Le_toobig_items: .asciz "toobig 1000 items"
.Le_toobig_term: .asciz "toobig 4096 bytes"
.Le_needs_term: .asciz "needs terminal=yes"
.Lrun_label: .asciz "Run in the terminal: Enter, or Esc"
.p2align 3
opt_names: .quad .Lo_tab, .Lo_spaces, .Lo_trim, .Lo_final
# the commands cmd may run (section 8a): name, what it needs (0, NEEDS_DOC_WRITE for the ones
# that change the document, NEEDS_TERMINAL for the terminal panel's); cut, copy and paste are
# not here: the clipboard is no extension's, and a paste can reach the terminal
cmd_allow:
    .quad .La_undo, NEEDS_DOC_WRITE, .La_redo, NEEDS_DOC_WRITE, .La_select_all, 0, .La_select_line, 0
    .quad .La_select_next, 0, .La_duplicate_line, NEEDS_DOC_WRITE, .La_delete_line, NEEDS_DOC_WRITE
    .quad .La_move_line_up, NEEDS_DOC_WRITE, .La_move_line_down, NEEDS_DOC_WRITE
    .quad .La_indent, NEEDS_DOC_WRITE, .La_outdent, NEEDS_DOC_WRITE, .La_toggle_comment, NEEDS_DOC_WRITE
    .quad .La_newline_below, NEEDS_DOC_WRITE, .La_newline_above, NEEDS_DOC_WRITE
    .quad .La_find, 0, .La_replace, 0, .La_find_next, 0, .La_find_prev, 0, .La_find_in_files, 0, .La_goto_line, 0
    .quad .La_quick_open, 0, .La_command_palette, 0, .La_next_tab, 0, .La_prev_tab, 0, .La_reveal_file, 0
    .quad .La_focus_explorer, 0, .La_toggle_sidebar, 0, .La_toggle_agents, 0
    .quad .La_toggle_terminal, NEEDS_TERMINAL, .La_new_terminal, NEEDS_TERMINAL, .La_clear_terminal, NEEDS_TERMINAL
    .quad .La_toggle_word_wrap, 0, .La_toggle_whitespace, 0, .La_toggle_line_numbers, 0
    .quad .La_zoom_in, 0, .La_zoom_out, 0, .La_zoom_reset, 0, 0, 0
.La_undo: .asciz "undo"
.La_redo: .asciz "redo"
.La_select_all: .asciz "select_all"
.La_select_line: .asciz "select_line"
.La_select_next: .asciz "select_next"
.La_duplicate_line: .asciz "duplicate_line"
.La_delete_line: .asciz "delete_line"
.La_move_line_up: .asciz "move_line_up"
.La_move_line_down: .asciz "move_line_down"
.La_indent: .asciz "indent"
.La_outdent: .asciz "outdent"
.La_toggle_comment: .asciz "toggle_comment"
.La_newline_below: .asciz "newline_below"
.La_newline_above: .asciz "newline_above"
.La_find: .asciz "find"
.La_replace: .asciz "replace"
.La_find_next: .asciz "find_next"
.La_find_prev: .asciz "find_prev"
.La_find_in_files: .asciz "find_in_files"
.La_goto_line: .asciz "goto_line"
.La_quick_open: .asciz "quick_open"
.La_command_palette: .asciz "command_palette"
.La_next_tab: .asciz "next_tab"
.La_prev_tab: .asciz "prev_tab"
.La_reveal_file: .asciz "reveal_file"
.La_focus_explorer: .asciz "focus_explorer"
.La_toggle_sidebar: .asciz "toggle_sidebar"
.La_toggle_agents: .asciz "toggle_agents"
.La_toggle_terminal: .asciz "toggle_terminal"
.La_new_terminal: .asciz "new_terminal"
.La_clear_terminal: .asciz "clear_terminal"
.La_toggle_word_wrap: .asciz "toggle_word_wrap"
.La_toggle_whitespace: .asciz "toggle_whitespace"
.La_toggle_line_numbers: .asciz "toggle_line_numbers"
.La_zoom_in: .asciz "zoom_in"
.La_zoom_out: .asciz "zoom_out"
.La_zoom_reset: .asciz "zoom_reset"
.Lv_text: .asciz "text"
.Lv_range: .asciz "range"
.Lv_replace: .asciz "replace"
.Lv_insert: .asciz "insert"
.Lv_select: .asciz "select"
.Lv_toast: .asciz "toast"
.Lv_status: .asciz "status"
.Lv_open: .asciz "open"
.Lv_cancel: .asciz "cancel"
.Lv_diagnostics: .asciz "diagnostics"
.Lv_hover: .asciz "hover"
.Lw_hello: .asciz "hello"
.Lev_features: .asciz "0 features"
.Lev_cancel: .asciz "0 cancel "
.Lev_action: .asciz "0 action "
.Lf_views: .asciz "views"
.Lf_complete: .asciz "complete"
.Lf_signature: .asciz "signature"
.Lf_definition: .asciz "definition"
.Lf_references: .asciz "references"
.Lf_symbols: .asciz "symbols"
.Lf_actions: .asciz "actions"
.Lf_rename: .asciz "rename"
.Lf_format: .asciz "format"
.p2align 3
feature_names: .quad .Lf_views, .Lf_complete, .Lf_signature, .Lf_definition, .Lf_references   # bit i: FEAT_*
    .quad .Lf_symbols, .Lf_actions, .Lf_rename, .Lf_format, 0
.Lw_ok: .asciz "ok"
.Lw_error: .asciz "error"
.Lw_ok_sp: .asciz "ok "
.Lw_error_sp: .asciz "error "
.Ldash: .asciz "-"
.Lev_ready: .asciz "0 ready "
.Lev_run: .asciz "0 run "
.Lev_opened: .asciz "0 opened "
.Lev_saved: .asciz "0 saved "
.Lev_changed: .asciz "0 changed "
.Lev_cursor: .asciz "0 cursor "
.Lev_selection: .asciz "0 selection "
.Lev_closed: .asciz "0 closed "
.Lev_active: .asciz "0 active "
.Lev_project: .asciz "0 project "
.Lev_edits: .asciz "0 edits "
.Lev_resync: .asciz "0 resync "
.Lev_hover: .asciz "0 hover "
.Lev_setting: .asciz "0 setting "
.Le_unknown: .asciz "unknown no such request"
.Le_syntax: .asciz "syntax cannot parse the line"
.Le_nodoc: .asciz "nodoc no such document"
.Le_badpos: .asciz "badpos position outside the document or inside a character"
.Le_stale: .asciz "stale "
.Le_needs_read: .asciz "needs documents=read"
.Le_needs_write: .asciz "needs documents=write"
.Le_nofile: .asciz "nofile no such file"
.Le_file_needs: .asciz "needs file=read"
.Le_readonly: .asciz "readonly the document cannot be edited"
.Le_toobig: .asciz "toobig more than 2000 diagnostics"
.Lr_no_hello: .asciz "the first line was not hello 1"
.Lr_protocol: .asciz "protocol version not supported (rhun speaks 1)"
.Lr_body: .asciz "a body over its cap"
.Lr_syntax: .asciz "three unparsable lines in a row"
