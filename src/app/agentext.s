# agent sources from extensions (wider-parity D1): the sessions of another agent an extension lists
# in the agents panel (feature agents), and the transcripts rhun asks it for. What one extension
# contributes to the AI features is kept here, in a table indexed like g_exts (ai_ext), along with
# the small reader the AI parsers share (ai_rd_*).
.include "rhun.inc"

.equ AGENT_ROWS_MAX, 1000
.equ AGENT_SID_MAX, 128
.equ AGENT_TITLE_MAX, 200       # a row's title is cut to this many bytes, the model to 120
.equ AGENT_MODEL_MAX, 120
.equ AGENT_FIELD_MAX, 4096      # any field of a row, before cutting
.equ AGENT_TEXT_MAX, 71680      # a message's text is cut at 70 KB, as OpenCode copies are
.equ AGENT_MSGS_MAX, 2000       # messages one transcript answer may hold
.equ CARD_LINES, 4              # a card's prompt wraps to this many lines, the last one cut with "…"

.bss
.p2align 3
ax_tab: .zero AX_SIZE * EXT_CAP
rd_p: .quad 0
rd_end: .quad 0
rows_new: .zero VEC_SIZE        # agentext_set_rows: the parsed rows (RW records)
keep: .zero VEC_SIZE            # and the AS objects that stay
hidden_names: .zero VEC_SIZE    # cstr OWNER/NAME of the sources switched off in Settings
qual: .zero SB_SIZE
num: .zero 32
tmp: .zero SB_SIZE
lay_box: .long 0                # box_fit: the box's width
lay_btn: .long 0                #   Send's (or Stop's) width: MI_64 with its word, MI_32 an icon
lay_below: .long 0              #   1: Send (and the mode label) on a row under the box
lay_min: .long 0                #   the least the box is given
.p2align 3
ph_last: .quad 0                # the placeholder the box was drawn with last, and the box's width
ph_w: .long 0
match_len: .quad 0              # cwd_match: the longest root that holds the CWD so far
match_name: .quad 0             #   its worktree name (a copy) when it is a linked worktree
match_cwd: .quad 0

# a row as parsed, pointing into the body
STRUCT
F AXR_updated, 8
F AXR_state, 8
F AXR_sid, 8
F AXR_sidlen, 8
F AXR_title, 8
F AXR_titlelen, 8
F AXR_model, 8
F AXR_modellen, 8
F AXR_cwd, 8
F AXR_cwdlen, 8
ENDSTRUCT AXR_SIZE

.text

# FN ai_ext(ext) -> AX*: what the extension contributes to the AI features
FN ai_ext
    mov rax, rdi
    sub rax, [rip + g_exts + VEC_ptr]
    xor edx, edx
    mov ecx, EXT_SIZE
    div rcx
    imul rax, rax, AX_SIZE
    lea rcx, [rip + ax_tab]
    add rax, rcx
    ret

# FN ai_ext_reset(ext): a record being (re)loaded from its manifest starts with nothing
FN ai_ext_reset
    PROLOGUE
    mov rbx, rdi
    call agentext_gone
    mov rdi, rbx
    call ai_ext
    mov r12, rax
    mov rdi, [r12 + AX_title]
    call mem_free
    lea rdi, [r12 + AX_rows]
    call vec_free
    mov rdi, rbx
    call tools_ext_reset
    mov rdi, r12
    mov ecx, AX_SIZE
    xor eax, eax
    rep stosb
    EPILOGUE

# ---------------- the shared reader ----------------

# FN ai_rd_init(ptr, len): the bytes the ai_rd_* functions read
FN ai_rd_init
    mov [rip + rd_p], rdi
    add rdi, rsi
    mov [rip + rd_end], rdi
    ret

# FN ai_rd_pos() -> rax the next byte's address
FN ai_rd_pos
    mov rax, [rip + rd_p]
    ret

# FN ai_rd_num() -> rax value, edx 1, and the space after it skipped; edx 0 when there is no decimal
#   number of 1 to 18 digits
FN ai_rd_num
    mov rcx, [rip + rd_p]
    mov r8, [rip + rd_end]
    xor eax, eax
    xor edx, edx
1:  cmp rcx, r8
    jae 2f
    movzx r9d, byte ptr [rcx]
    sub r9d, '0'
    cmp r9d, 9
    ja 2f
    cmp edx, 18
    jae 8f
    imul rax, rax, 10
    add rax, r9
    inc edx
    inc rcx
    jmp 1b
2:  test edx, edx
    jz 8f
    cmp rcx, r8
    jae 3f
    cmp byte ptr [rcx], ' '
    jne 3f
    inc rcx
3:  mov [rip + rd_p], rcx
    mov edx, 1
    ret
8:  xor edx, edx
    ret

# FN ai_rd_word() -> rax ptr, rdx len of the bytes up to a space or LF (the space skipped)
FN ai_rd_word
    mov rax, [rip + rd_p]
    mov r8, [rip + rd_end]
    mov rcx, rax
1:  cmp rcx, r8
    jae 2f
    cmp byte ptr [rcx], ' '
    je 2f
    cmp byte ptr [rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov rdx, rcx
    sub rdx, rax
    cmp rcx, r8
    jae 3f
    cmp byte ptr [rcx], ' '
    jne 3f
    inc rcx
3:  mov [rip + rd_p], rcx
    ret

# FN ai_rd_eol() -> eax 1 when the next byte is LF (taken), else 0
FN ai_rd_eol
    mov rcx, [rip + rd_p]
    xor eax, eax
    cmp rcx, [rip + rd_end]
    jae 1f
    cmp byte ptr [rcx], 10
    jne 1f
    inc rcx
    mov [rip + rd_p], rcx
    inc eax
1:  ret

# FN ai_rd_take(n) -> rax the address of the next n bytes (taken), or 0 when fewer are left
FN ai_rd_take
    mov rax, [rip + rd_p]
    mov rcx, [rip + rd_end]
    sub rcx, rax
    cmp rdi, rcx
    ja 1f
    add [rip + rd_p], rdi
    ret
1:  xor eax, eax
    ret

# FN ai_rd_line() -> rax ptr, rdx len of the rest of the line (the LF taken); rax 0 without an LF
FN ai_rd_line
    mov rax, [rip + rd_p]
    mov r8, [rip + rd_end]
    mov rcx, rax
1:  cmp rcx, r8
    jae 8f
    cmp byte ptr [rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov rdx, rcx
    sub rdx, rax
    inc rcx
    mov [rip + rd_p], rcx
    ret
8:  xor eax, eax
    xor edx, edx
    ret

# FN ai_rd_done() -> eax 1 when every byte was read
FN ai_rd_done
    mov rcx, [rip + rd_p]
    xor eax, eax
    cmp rcx, [rip + rd_end]
    sete al
    ret

# FN ai_cut(ptr, len, max) -> rax ptr, rdx len cut to at most max bytes, at a character boundary
FN ai_cut
    mov rax, rdi
    cmp rsi, rdx
    jbe 2f
1:  test rdx, rdx
    jz 3f
    movzx ecx, byte ptr [rdi + rdx]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne 3f
    dec rdx
    jmp 1b
2:  mov rdx, rsi
3:  ret

# FN ai_dup(ptr, len) -> a NUL-terminated copy (mem_alloc'd)
FN ai_dup
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rsi + 1]
    call mem_alloc
    mov r13, rax
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call memcpy
    mov byte ptr [r13 + r12], 0
    mov rax, r13
    EPILOGUE

# FN ai_word_ok(ptr, len, max) -> eax 1 when it is 1 to max bytes of visible ASCII (an id that goes in
#   a space-separated field)
FN ai_word_ok
    xor eax, eax
    test rsi, rsi
    jz 9f
    cmp rsi, rdx
    ja 9f
    xor ecx, ecx
1:  movzx edx, byte ptr [rdi + rcx]
    cmp edx, 0x21
    jb 9f
    cmp edx, 0x7e
    ja 9f
    inc rcx
    cmp rcx, rsi
    jb 1b
    inc eax
9:  ret

# ---------------- the manifest ----------------

# FN agentext_manifest_kv(ext, ini) -> eax 1 when the [provides] key was agents or agents.title
FN agentext_manifest_kv
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    lea rsi, [rip + .Lk_agents]
    call ini_key_is
    test eax, eax
    jz 1f
    mov rdi, rbx
    call ai_ext
    mov r13, rax
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    call parse_bool
    mov [r13 + AX_agents], eax
    mov rdi, rbx
    call agentext_hidden_load
    mov eax, 1
    EPILOGUE
1:  mov rdi, r12
    lea rsi, [rip + .Lk_agents_title]
    call ini_key_is
    test eax, eax
    jz 9f
    mov rdi, rbx
    call ai_ext
    mov r13, rax
    mov rdi, [r13 + AX_title]
    call mem_free
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    mov edx, 80
    call ai_cut
    mov rdi, rax
    mov rsi, rdx
    call ai_dup
    mov [r13 + AX_title], rax
    mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# FN agentext_title(ext) -> cstr: the name its sessions show (agents.title, else its title)
FN agentext_title
    push rbx
    mov rbx, rdi
    call ai_ext
    mov rax, [rax + AX_title]
    test rax, rax
    jnz 1f
    mov rdi, rbx
    call ext_title
1:  pop rbx
    ret

# ---------------- rows (agent-sessions) ----------------

# FN agentext_set_rows(ext, body, len) -> rax 0, or the error reply's "CODE TEXT": its rows replaced
#   by the body's: N LF, then N rows UPDATED STATE SID_LEN TITLE_LEN MODEL_LEN CWD_LEN LF and the four
#   strings. Rows keep their objects (and a fetched transcript) by session id.
FN agentext_set_rows
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov rdi, rbx
    call ai_ext
    mov r15, rax
    cmp dword ptr [r15 + AX_agents], 0
    je .Lsr_provides
    mov qword ptr [rip + rows_new + VEC_len], 0
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call ai_rd_init
    call ai_rd_num
    test edx, edx
    jz .Lsr_syntax
    mov r12, rax
    call ai_rd_eol
    test eax, eax
    jz .Lsr_syntax
    cmp r12, AGENT_ROWS_MAX
    ja .Lsr_toobig
.Lsr_row:
    test r12, r12
    jz .Lsr_parsed
    dec r12
    lea rdi, [rip + rows_new]
    mov esi, AXR_SIZE
    call vec_push
    mov r13, rax
    call ai_rd_num
    test edx, edx
    jz .Lsr_syntax
    mov [r13 + AXR_updated], rax
    call ai_rd_word
    mov rdi, rax
    mov rsi, rdx
    call state_of
    test rax, rax
    js .Lsr_syntax
    mov [r13 + AXR_state], rax
    call ai_rd_num
    test edx, edx
    jz .Lsr_syntax
    mov [r13 + AXR_sidlen], rax
    call ai_rd_num
    test edx, edx
    jz .Lsr_syntax
    mov [r13 + AXR_titlelen], rax
    call ai_rd_num
    test edx, edx
    jz .Lsr_syntax
    mov [r13 + AXR_modellen], rax
    call ai_rd_num
    test edx, edx
    jz .Lsr_syntax
    mov [r13 + AXR_cwdlen], rax
    call ai_rd_eol
    test eax, eax
    jz .Lsr_syntax
    cmp qword ptr [r13 + AXR_titlelen], AGENT_FIELD_MAX
    ja .Lsr_syntax
    cmp qword ptr [r13 + AXR_modellen], AGENT_FIELD_MAX
    ja .Lsr_syntax
    cmp qword ptr [r13 + AXR_cwdlen], AGENT_FIELD_MAX
    ja .Lsr_syntax
    mov rdi, [r13 + AXR_sidlen]
    call ai_rd_take
    test rax, rax
    jz .Lsr_syntax
    mov [r13 + AXR_sid], rax
    mov rdi, rax
    mov rsi, [r13 + AXR_sidlen]
    mov edx, AGENT_SID_MAX
    call ai_word_ok
    test eax, eax
    jz .Lsr_syntax
    mov rdi, [r13 + AXR_titlelen]
    call ai_rd_take
    test rax, rax
    jz .Lsr_syntax
    mov [r13 + AXR_title], rax
    mov rdi, [r13 + AXR_modellen]
    call ai_rd_take
    test rax, rax
    jz .Lsr_syntax
    mov [r13 + AXR_model], rax
    mov rdi, [r13 + AXR_cwdlen]
    call ai_rd_take
    test rax, rax
    jz .Lsr_syntax
    mov [r13 + AXR_cwd], rax
    # a CWD is an absolute path without NUL or LF, or nothing
    mov rcx, [r13 + AXR_cwdlen]
    test rcx, rcx
    jz .Lsr_row
    mov rdi, rax
    xor edx, edx
1:  movzx eax, byte ptr [rdi + rdx]
    test eax, eax
    jz .Lsr_syntax
    cmp eax, 10
    je .Lsr_syntax
    inc rdx
    cmp rdx, rcx
    jb 1b
    PATH_ABSOLUTE rdi, .Lsr_row
    jmp .Lsr_syntax
.Lsr_parsed:
    call ai_rd_done
    test eax, eax
    jz .Lsr_syntax
    # a session id names one row
    xor r12d, r12d
2:  cmp r12, [rip + rows_new + VEC_len]
    jae 4f
    imul r13, r12, AXR_SIZE
    add r13, [rip + rows_new + VEC_ptr]
    xor r14d, r14d
3:  cmp r14, r12
    jae 31f
    imul rax, r14, AXR_SIZE
    add rax, [rip + rows_new + VEC_ptr]
    mov rcx, [rax + AXR_sidlen]
    cmp rcx, [r13 + AXR_sidlen]
    jne 32f
    mov rdi, [rax + AXR_sid]
    mov rsi, [r13 + AXR_sid]
    mov rdx, rcx
    call memeq
    test eax, eax
    jnz .Lsr_syntax
32: inc r14
    jmp 3b
31: inc r12
    jmp 2b
4:  # the new list: existing objects updated, new ones made
    mov qword ptr [rip + keep + VEC_len], 0
    xor r12d, r12d
5:  cmp r12, [rip + rows_new + VEC_len]
    jae 7f
    imul r13, r12, AXR_SIZE
    add r13, [rip + rows_new + VEC_ptr]
    mov rdi, r15
    mov rsi, [r13 + AXR_sid]
    mov rdx, [r13 + AXR_sidlen]
    call row_find
    test rax, rax
    jnz 6f
    mov rdi, rbx
    mov rsi, r13
    call row_new
6:  mov r14, rax
    mov rdi, r14
    mov rsi, r13
    call row_update
    lea rdi, [rip + keep]
    mov esi, 8
    call vec_push
    mov [rax], r14
    inc r12
    jmp 5b
7:  # swap the lists, show them, then free the rows that went (after the panel forgot them)
    mov rax, [r15 + AX_rows + VEC_ptr]
    mov rcx, [r15 + AX_rows + VEC_len]
    mov rdx, [r15 + AX_rows + VEC_cap]
    mov [rsp + 16], rax
    mov [rsp + 24], rcx
    mov rax, [rip + keep + VEC_len]
    lea rdi, [rax*8 + 8]
    call mem_alloc
    mov [r15 + AX_rows + VEC_ptr], rax
    mov rcx, [rip + keep + VEC_len]
    mov [r15 + AX_rows + VEC_len], rcx
    inc rcx
    mov [r15 + AX_rows + VEC_cap], rcx
    mov rdi, rax
    mov rsi, [rip + keep + VEC_ptr]
    mov rdx, [rip + keep + VEC_len]
    shl rdx, 3
    call memcpy
    call agents_ext_rows
    xor r12d, r12d
8:  cmp r12, [rsp + 24]
    jae 81f
    mov rax, [rsp + 16]
    mov r13, [rax + r12*8]
    inc r12
    mov rdi, r15
    mov rsi, r13
    call row_listed
    test eax, eax
    jnz 8b
    mov rdi, r13
    call row_free
    jmp 8b
81: mov rdi, [rsp + 16]
    call mem_free
    call open_wanted            # D4: a session a prompt started opens once it is listed
    xor eax, eax
    EPILOGUE
.Lsr_provides:
    lea rax, [rip + .Le_provides]
    EPILOGUE
.Lsr_toobig:
    lea rax, [rip + .Le_rows_toobig]
    EPILOGUE
.Lsr_syntax:
    lea rax, [rip + .Le_rows_syntax]
    EPILOGUE

# state_of(ptr, len) -> rax AGS_*, or -1
state_of:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  lea rax, [rip + state_names]
    mov rdx, [rax + r13*8]
    test rdx, rdx
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r13
    jmp 1b
2:  mov rax, r13
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# row_find(AX*, sid, len) -> AS* with that session id, or 0
row_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, [rbx + AX_rows + VEC_len]
    jae 8f
    mov rax, [rbx + AX_rows + VEC_ptr]
    mov r15, [rax + r14*8]
    inc r14
    mov rdi, [r15 + AS_sid]
    mov rsi, r12
    mov rdx, r13
    call str_eq_cstr_rev
    test eax, eax
    jz 1b
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# str_eq_cstr_rev(cstr, ptr, len) -> eax 1 when equal
str_eq_cstr_rev:
    mov rax, rdi
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rax
    jmp str_eq_cstr

# row_listed(AX*, AS*) -> eax 1 when the row is in its rows
row_listed:
    xor ecx, ecx
1:  cmp rcx, [rdi + AX_rows + VEC_len]
    jae 8f
    mov rax, [rdi + AX_rows + VEC_ptr]
    cmp [rax + rcx*8], rsi
    je 9f
    inc rcx
    jmp 1b
8:  xor eax, eax
    ret
9:  mov eax, 1
    ret

# row_new(ext, RW*) -> a new AS for the row (kind 5), cleared
row_new:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov edi, AS_SIZE
    call mem_alloc
    mov r13, rax
    mov rdi, rax
    mov ecx, AS_SIZE
    xor eax, eax
    rep stosb
    mov dword ptr [r13 + AS_kind], AS_KIND_EXT
    mov [r13 + AS_ext], rbx
    mov qword ptr [r13 + AS_dirty], 0
    mov dword ptr [r13 + AS_titled], 1
    mov rdi, [r12 + AXR_sid]
    mov rsi, [r12 + AXR_sidlen]
    call ai_dup
    mov [r13 + AS_sid], rax
    # the key the panel's tables know a row by: OWNER/NAME:SID
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_owner]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, ':'
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, [r13 + AS_sid]
    call sb_push_cstr
    mov rdi, [rip + tmp + SB_ptr]
    mov rsi, [rip + tmp + SB_len]
    call ai_dup
    mov [r13 + AS_path], rax
    mov rax, r13
    EPILOGUE

# row_update(AS*, RW*): the row's title, model, state, time and folder from the parsed row
row_update:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rax, [r12 + AXR_state]
    mov [rbx + AS_state], eax
    mov rax, [r12 + AXR_updated]
    cmp rax, [rbx + AS_mtime]
    je 1f
    mov [rbx + AS_mtime], rax
    mov rcx, 1000000000
    imul rax, rcx
    mov [rbx + AS_recency], rax
    call time_ms
    mov [rbx + AS_changed], rax
1:  # the title: its first line, trimmed and cut
    mov rdi, [r12 + AXR_title]
    mov rsi, [r12 + AXR_titlelen]
    xor ecx, ecx
2:  cmp rcx, rsi
    jae 3f
    cmp byte ptr [rdi + rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  mov rsi, rcx
    call trim
    mov rdi, rax
    mov rsi, rdx
    mov edx, AGENT_TITLE_MAX
    call ai_cut
    lea rdi, [rbx + AS_title]
    mov rsi, rax
    call set_slot
    mov rdi, [r12 + AXR_model]
    mov rsi, [r12 + AXR_modellen]
    mov edx, AGENT_MODEL_MAX
    call ai_cut
    lea rdi, [rbx + AS_model]
    mov rsi, rax
    call set_slot
    lea rdi, [rbx + AS_cwd]
    mov rsi, [r12 + AXR_cwd]
    mov rdx, [r12 + AXR_cwdlen]
    call set_slot
    mov rdi, rbx
    call row_match
    EPILOGUE

# set_slot(slot, ptr, len): *slot holds a copy of the bytes, or 0 for none
set_slot:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [rbx]
    call mem_free
    mov qword ptr [rbx], 0
    test r13, r13
    jz 9f
    mov rdi, r12
    mov rsi, r13
    call ai_dup
    mov [rbx], rax
9:  EPILOGUE

# row_free(AS*): a row that went; a card still open on it is answered cancelled
row_free:
    PROLOGUE
    mov rbx, rdi
    mov rsi, [rbx + AS_req]     # a transcript asked for is no longer wanted
    test rsi, rsi
    jz 1f
    mov rdi, [rbx + AS_ext]
    call query_withdraw
1:  mov rdi, rbx
    call agentext_ask_drop
    mov rdi, rbx
    call agentext_row_gone
    mov rdi, [rbx + AS_sid]
    call mem_free
    mov rdi, rbx
    call agent_session_free
    EPILOGUE

# ---------------- which rows the project shows ----------------

# row_match(AS*): AXF_MATCH and AS_worktree from its CWD: none (any project), the project or a folder
#   in it, or one of the repository's checkouts (a linked worktree gets its badge)
row_match:
    PROLOGUE
    mov rbx, rdi
    and dword ptr [rbx + AS_xflags], ~AXF_MATCH
    mov rdi, [rbx + AS_worktree]
    call mem_free
    mov qword ptr [rbx + AS_worktree], 0
    mov r12, [rbx + AS_cwd]
    test r12, r12
    jz .Lrm_yes
    cmp qword ptr [rip + g_project], 0
    je 9f
    mov [rip + match_cwd], r12
    mov qword ptr [rip + match_len], 0
    mov qword ptr [rip + match_name], 0
    xor edi, edi
    mov rsi, [rip + g_project]
    xor edx, edx
    call match_cb
    lea rdi, [rip + match_cb]
    xor esi, esi
    call git_each_agent_worktree
    cmp qword ptr [rip + match_len], 0
    je 9f
    mov rax, [rip + match_name]
    mov [rbx + AS_worktree], rax
.Lrm_yes:
    or dword ptr [rbx + AS_xflags], AXF_MATCH
9:  EPILOGUE

# match_cb(ctx, root, linked): note the root when it holds match_cwd and is longer than the last
match_cb:
    PROLOGUE
    mov r12, rsi
    mov r13d, edx
    mov rdi, r12
    call strlen
    mov r14, rax
    test r14, r14
    jz 9f
    cmp r14, [rip + match_len]
    jbe 9f
    mov rbx, [rip + match_cwd]
    mov rdi, rbx
    call strlen
    cmp rax, r14
    jb 9f
    mov r15, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call memeq
    test eax, eax
    jz 9f
    cmp r15, r14
    je 1f
    cmp byte ptr [rbx + r14], '/'
    jne 9f
1:  mov [rip + match_len], r14
    mov rdi, [rip + match_name]
    call mem_free
    mov qword ptr [rip + match_name], 0
    test r13d, r13d
    jz 9f
    mov rdi, r12
    mov rsi, r14
    call path_basename
    mov rdi, rax
    mov rsi, rdx
    call ai_dup
    mov [rip + match_name], rax
9:  EPILOGUE

# FN agentext_rematch(): the project changed: which rows it shows
FN agentext_rematch
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + g_exts + VEC_len]
    jae 9f
    imul rdi, rbx, EXT_SIZE
    add rdi, [rip + g_exts + VEC_ptr]
    inc rbx
    call ai_ext
    mov r12, rax
    xor r13d, r13d
2:  cmp r13, [r12 + AX_rows + VEC_len]
    jae 1b
    mov rax, [r12 + AX_rows + VEC_ptr]
    mov rdi, [rax + r13*8]
    inc r13
    call row_match
    jmp 2b
9:  EPILOGUE

# ---------------- transcripts ----------------

# FN agentext_changed(ext, sid ptr, len, total, first) -> rax 0, or "CODE TEXT": the session has TOTAL
#   messages now, the first changed one at FIRST; an open conversation asks for them
FN agentext_changed
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov [rsp], r8
    mov rdi, rbx
    call ai_ext
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call row_find
    test rax, rax
    jz 8f
    mov r15, rax
    mov [r15 + AS_total], r14
    mov rax, [rsp]
    cmp rax, r14
    jbe 1f
    mov rax, r14
1:  mov rcx, [r15 + AS_dirty]
    test rcx, rcx
    js 2f
    cmp rax, rcx
    jae 3f
2:  mov [r15 + AS_dirty], rax
3:  call time_ms
    mov [r15 + AS_changed], rax
    call time_now
    mov [r15 + AS_mtime], rax
    mov rdi, r15
    call agents_ext_is_open
    test eax, eax
    jz 4f
    mov rdi, r15
    call agentext_fetch
4:  mov dword ptr [rip + g_dirty], 1
    xor eax, eax
    EPILOGUE
8:  lea rax, [rip + .Le_no_session]
    EPILOGUE

# FN agentext_open(AS*): the user opened the conversation: what it does not have yet is asked for
FN agentext_open
    PROLOGUE
    mov rbx, rdi
    mov dword ptr [rbx + AS_loaded], 1
    test dword ptr [rbx + AS_xflags], AXF_FETCHED
    jnz 1f
    mov qword ptr [rbx + AS_dirty], 0
1:  mov rdi, rbx
    call agentext_fetch
    EPILOGUE

# FN agentext_fetch(AS*): "ID agent-transcript SID FROM" when the copy is behind and nothing is asked
FN agentext_fetch
    PROLOGUE 48
    mov rbx, rdi
    cmp qword ptr [rbx + AS_req], 0
    jne 9f
    mov r12, [rbx + AS_dirty]
    test r12, r12
    js 9f
    mov r13, [rbx + AS_ext]
    FEAT_TEST r13, FEAT_AGENTS
    jz 9f
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lv_transcript]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rbx + AS_sid]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, r12
    call sb_push_u64
    mov rdi, r13
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    xor ecx, ecx
    xor r8d, r8d
    call extproto_ai_request
    test rax, rax
    jz 9f
    mov [rbx + AS_req], rax
    mov [rbx + AS_from], r12
    mov qword ptr [rbx + AS_dirty], -1
    mov rdi, r13                # counted and timed with the language queries (query.s)
    mov rsi, rax
    mov edx, PK_TRANSCRIPT
    mov ecx, QO_AI
    call query_track
9:  EPILOGUE

# FN agentext_reply(ext, id, ok, body, len) -> eax 1 when it answered an agent-transcript request:
#   TOTAL N LF, then N messages ROLE NAME_LEN TEXT_LEN MODEL_LEN LF and the three strings
FN agentext_reply
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], edx
    mov [rsp + 16], rcx
    mov [rsp + 24], r8
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call ai_ext
    mov r12, rax
    xor r13d, r13d
1:  cmp r13, [r12 + AX_rows + VEC_len]
    jae 8f
    mov rax, [r12 + AX_rows + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    mov rax, [rsp]
    cmp [r14 + AS_req], rax
    jne 1b
    mov qword ptr [r14 + AS_req], 0
    cmp dword ptr [rsp + 8], 0
    je .Lar_done                # an error: the copy stays as it was
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    call ai_rd_init
    call ai_rd_num
    test edx, edx
    jz .Lar_done
    mov [rsp + 32], rax         # TOTAL
    call ai_rd_num
    test edx, edx
    jz .Lar_done
    mov r15, rax                # N
    call ai_rd_eol
    test eax, eax
    jz .Lar_done
    cmp r15, AGENT_MSGS_MAX
    ja .Lar_done
    # the answer replaces the copy from FROM on
    mov rdi, r14
    mov rsi, [r14 + AS_from]
    call agents_ext_truncate
    or dword ptr [r14 + AS_xflags], AXF_FETCHED
    mov rax, [rsp + 32]
    mov [r14 + AS_total], rax
    mov qword ptr [rsp + 40], 0
2:  cmp [rsp + 40], r15
    jae 3f
    mov rdi, r14
    call one_message
    test eax, eax
    jz 3f
    inc qword ptr [rsp + 40]
    jmp 2b
3:  # more to come: the next page from where this one ended
    mov rax, [r14 + AS_from]
    add rax, [rsp + 40]
    cmp qword ptr [rsp + 40], 0
    je .Lar_done
    cmp rax, [rsp + 32]
    jae .Lar_done
    mov rcx, [r14 + AS_dirty]
    test rcx, rcx
    js 4f
    cmp rcx, rax
    jbe .Lar_done
4:  mov [r14 + AS_dirty], rax
.Lar_done:
    mov rdi, r14
    call agents_ext_is_open
    test eax, eax
    jz 5f
    mov rdi, r14
    call agentext_fetch
5:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# one_message(AS*) -> eax 1 with the next message of the answer added, 0 when it is malformed
one_message:
    PROLOGUE 48
    mov rbx, rdi
    call ai_rd_word
    mov rdi, rax
    mov rsi, rdx
    call role_of
    test eax, eax
    jz 8f
    mov [rsp], eax
    call ai_rd_num
    test edx, edx
    jz 8f
    mov r12, rax                # NAME_LEN
    call ai_rd_num
    test edx, edx
    jz 8f
    mov r13, rax                # TEXT_LEN
    call ai_rd_num
    test edx, edx
    jz 8f
    mov r14, rax                # MODEL_LEN
    call ai_rd_eol
    test eax, eax
    jz 8f
    cmp r12, AGENT_FIELD_MAX
    ja 8f
    cmp r14, AGENT_FIELD_MAX
    ja 8f
    mov rdi, r12
    call ai_rd_take
    test rax, rax
    jz 8f
    mov [rsp + 8], rax
    mov rdi, r13
    call ai_rd_take
    test rax, rax
    jz 8f
    mov [rsp + 16], rax
    mov rdi, r14
    call ai_rd_take
    test rax, rax
    jz 8f
    mov [rsp + 24], rax
    # the label: a tool's name, a reply's model, error and info say so
    xor r15d, r15d
    mov eax, [rsp]
    mov rdi, [rsp + 8]
    mov rsi, r12
    cmp eax, 2                  # assistant: its model
    jne 1f
    mov rdi, [rsp + 24]
    mov rsi, r14
1:  mov edx, AGENT_MODEL_MAX
    call ai_cut
    test rdx, rdx
    jz 2f
    mov rdi, rax
    mov rsi, rdx
    call ai_dup
    mov r15, rax
2:  mov rdi, [rsp + 16]
    mov rsi, r13
    mov edx, AGENT_TEXT_MAX
    call ai_cut
    mov rdi, rbx
    mov esi, [rsp]
    mov rcx, rdx
    mov rdx, rax
    mov r8, r15
    call agents_ext_msg
    mov rdi, r15
    call mem_free
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# role_of(ptr, len) -> eax the panel's role (1 user, 2 assistant, 3 tool, 4 result, 5 error, 6 info), 0
role_of:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, 1
1:  lea rax, [rip + role_names]
    mov rdx, [rax + r13*8 - 8]
    test rdx, rdx
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r13d
    jmp 1b
2:  mov eax, r13d
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- an extension that stopped ----------------

# FN ai_ext_gone(ext): an extension stopped: its sessions leave the panel, its tool calls and cards end
FN ai_ext_gone
    PROLOGUE
    mov rbx, rdi
    call agentext_prompts_gone
    mov rdi, rbx
    call agentext_gone
    mov rdi, rbx
    call tools_ext_gone
    EPILOGUE

# FN agentext_gone(ext): its rows leave the panel (the conversation shown with them closes)
FN agentext_gone
    PROLOGUE 16
    mov rbx, rdi
    call ai_ext
    mov r12, rax
    mov rax, [r12 + AX_rows + VEC_len]
    test rax, rax
    jz 9f
    mov [rsp], rax
    mov rax, [r12 + AX_rows + VEC_ptr]
    mov [rsp + 8], rax
    mov qword ptr [r12 + AX_rows + VEC_ptr], 0
    mov qword ptr [r12 + AX_rows + VEC_len], 0
    mov qword ptr [r12 + AX_rows + VEC_cap], 0
    call agents_ext_rows
    xor r13d, r13d
1:  cmp r13, [rsp]
    jae 2f
    mov rax, [rsp + 8]
    mov rdi, [rax + r13*8]
    inc r13
    call row_free
    jmp 1b
2:  mov rdi, [rsp + 8]
    call mem_free
9:  EPILOGUE

# FN agentext_set_hidden(ext, hidden): Settings switched its sessions off or on
FN agentext_set_hidden
    PROLOGUE
    mov r12d, esi
    call ai_ext
    mov [rax + AX_hidden], r12d
    call agents_ext_rows
    EPILOGUE

# ---------------- Settings > Agents: a switch per source ----------------
# [agents] OWNER/NAME = false hides that extension's sessions. The names are kept as read, also for
# extensions not installed now, and written back with the other agents settings.

# FN agentext_config_reset(): the config file is read again
FN agentext_config_reset
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + hidden_names + VEC_len]
    jae 2f
    mov rax, [rip + hidden_names + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + hidden_names + VEC_len], 0
    EPILOGUE

# FN agentext_config_key(sec, seclen, key, keylen, val, vallen): a key config.s does not know; under
#   [agents], OWNER/NAME = false hides that source
FN agentext_config_key
    PROLOGUE 16
    mov rbx, rdx
    mov r12, rcx
    mov r13, r8
    mov r14, r9
    lea rdx, [rip + .Ls_agents]
    call str_eq_cstr
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    mov dl, '/'
    call has_byte
    test eax, eax
    jz 9f
    mov rdi, r13
    mov rsi, r14
    call parse_bool
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, r12
    call ai_dup
    mov [rsp], rax
    lea rdi, [rip + hidden_names]
    mov esi, 8
    call vec_push
    mov rcx, [rsp]
    mov [rax], rcx
    call hidden_apply
9:  EPILOGUE

# has_byte(ptr, len, dl) -> eax 1 when the byte is there
has_byte:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 9f
    cmp [rdi + rcx], dl
    je 8f
    inc rcx
    jmp 1b
8:  inc eax
9:  ret

# FN agentext_config_done(): the config file was read: every source's switch from what it said
FN agentext_config_done
    jmp hidden_apply

# FN agentext_config_save(sb): the hidden sources, as lines of [agents]
FN agentext_config_save
    PROLOGUE
    mov r12, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + hidden_names + VEC_len]
    jae 9f
    mov rax, [rip + hidden_names + VEC_ptr]
    mov rsi, [rax + rbx*8]
    inc rbx
    mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .Ls_eq_false]
    call sb_push_cstr
    jmp 1b
9:  EPILOGUE

# hidden_index(ext) -> rax the index of its name among the hidden ones, or -1
hidden_index:
    PROLOGUE
    mov rbx, rdi
    call ext_qualified
    mov r12, rax
    xor r13d, r13d
1:  cmp r13, [rip + hidden_names + VEC_len]
    jae 8f
    mov rax, [rip + hidden_names + VEC_ptr]
    mov rdi, [rax + r13*8]
    mov rsi, r12
    call strcmp_eq
    test eax, eax
    jnz 2f
    inc r13
    jmp 1b
2:  mov rax, r13
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# ext_qualified(ext) -> "OWNER/NAME" in qual (a static buffer)
ext_qualified:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + qual]
    call sb_clear
    lea rdi, [rip + qual]
    mov rsi, [rbx + EXT_owner]
    call sb_push_cstr
    lea rdi, [rip + qual]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + qual]
    mov rsi, [rbx + EXT_name]
    call sb_push_cstr
    lea rdi, [rip + qual]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + qual + SB_ptr]
    EPILOGUE

# hidden_apply(): AX_hidden of every source from the names
hidden_apply:
    PROLOGUE
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    mov rdi, rbx
    call ai_ext
    mov r13, rax
    cmp dword ptr [r13 + AX_agents], 0
    je 1b
    mov rdi, rbx
    call hidden_index
    xor ecx, ecx
    test rax, rax
    setns cl
    mov [r13 + AX_hidden], ecx
    jmp 1b
9:  call agents_ext_rows
    EPILOGUE

# FN agentext_hidden_load(ext): a loaded manifest that provides agents learns whether it is switched off
FN agentext_hidden_load
    PROLOGUE
    mov rbx, rdi
    call ai_ext
    mov r12, rax
    cmp dword ptr [r12 + AX_agents], 0
    je 9f
    mov rdi, rbx
    call hidden_index
    xor ecx, ecx
    test rax, rax
    setns cl
    mov [r12 + AX_hidden], ecx
9:  EPILOGUE

# toggle(ext): Settings switched the source
toggle:
    PROLOGUE 16
    mov rbx, rdi
    call hidden_index
    test rax, rax
    js 1f
    mov r12, rax                # shown again: its name goes
    mov rcx, [rip + hidden_names + VEC_ptr]
    mov rdi, [rcx + r12*8]
    call mem_free
    mov rcx, [rip + hidden_names + VEC_ptr]
    mov rdx, [rip + hidden_names + VEC_len]
    dec rdx
    mov [rip + hidden_names + VEC_len], rdx
    mov rax, [rcx + rdx*8]
    mov [rcx + r12*8], rax
    jmp 2f
1:  mov rdi, rbx
    call ext_qualified
    mov rdi, rax
    call strlen
    mov rsi, rax
    mov rdi, [rip + qual + SB_ptr]
    call ai_dup
    mov [rsp], rax
    lea rdi, [rip + hidden_names]
    mov esi, 8
    call vec_push
    mov rcx, [rsp]
    mov [rax], rcx
2:  call hidden_apply
    mov dword ptr [rip + g_settings_changed], 1
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# sources_each: rbx walks the installed extensions that provide agents (r12 index); used by the two
# functions below

# FN agentext_settings_rows(x, y, w) -> eax the height of the rows: a switch per source, under the
#   built-in agents in Settings
FN agentext_settings_rows
    PROLOGUE 48
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], esi         # y cursor
    xor r12d, r12d
.Lsrow_next:
    cmp r12, [rip + g_exts + VEC_len]
    jae .Lsrow_done
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je .Lsrow_next
    mov rdi, rbx
    call ai_ext
    mov r13, rax
    cmp dword ptr [r13 + AX_agents], 0
    je .Lsrow_next
    M r14d, MI_64
    mov edi, [rsp]
    mov esi, [rsp + 12]
    mov edx, [rsp + 8]
    mov ecx, r14d
    M r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    COLOR eax, T_PANEL
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    mov rdi, rbx
    call agentext_title
    mov r8, rax
    lea rdi, [rip + g_face_ui]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 12]
    add edx, [rip + g_mt + 4*MI_10]
    M ecx, MI_24
    COLOR r9d, T_FG
    call ui_text_c
    # "Show the sessions OWNER/NAME lists in the agents panel."
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Ls_show]
    call sb_push_cstr
    mov rdi, rbx
    call ext_qualified
    lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Ls_lists]
    call sb_push_cstr
    lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_16]
    mov edx, [rsp + 12]
    add edx, [rip + g_mt + 4*MI_32]
    M ecx, MI_20
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 8]
    sub r11d, [rip + g_mt + 4*MI_64]
    sub r11d, [rip + g_mt + 4*MI_16]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    M eax, MI_14
    add eax, [rip + g_mt + 4*MI_20]
    mov esi, [rsp]
    add esi, [rsp + 8]
    sub esi, [rip + g_mt + 4*MI_16]
    sub esi, eax
    mov edx, r14d
    sub edx, [rip + g_mt + 4*MI_20]
    sar edx, 1
    add edx, [rsp + 12]
    lea edi, [r12 + ID_AI_SOURCE - 1]
    xor ecx, ecx
    cmp dword ptr [r13 + AX_hidden], 0
    sete cl
    call ui_toggle
    test eax, eax
    jz 1f
    mov rdi, rbx
    call toggle
1:  add r14d, [rip + g_mt + 4*MI_8]
    add [rsp + 12], r14d
    jmp .Lsrow_next
.Lsrow_done:
    mov eax, [rsp + 12]
    sub eax, [rsp + 4]
    EPILOGUE

# FN agentext_settings_dump(sb): "agents.OWNER/NAME=true|false" per source (print-settings)
FN agentext_settings_dump
    PROLOGUE
    mov r15, rdi
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 1b
    mov rdi, rbx
    call ai_ext
    mov r13, rax
    cmp dword ptr [r13 + AX_agents], 0
    je 1b
    mov rdi, r15
    lea rsi, [rip + .Ls_agents_dot]
    call sb_push_cstr
    mov rdi, rbx
    call ext_qualified
    mov rdi, r15
    mov rsi, rax
    call sb_push_cstr
    lea rsi, [rip + .Ls_eq_true_nl]
    cmp dword ptr [r13 + AX_hidden], 0
    je 2f
    lea rsi, [rip + .Ls_eq_false_nl]
2:  mov rdi, r15
    call sb_push_cstr
    jmp 1b
9:  EPILOGUE

# FN agentext_toggle_named(name ptr, len) -> eax 1 when a source of that OWNER/NAME was switched
#   (the agents-source control command)
# FN agentext_named(ptr, len) -> rax the extension OWNER/NAME names (not removed), or 0
FN agentext_named
    PROLOGUE
    mov r13, rdi
    mov r14, rsi
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 8f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 1b
    mov rdi, rbx
    call ext_qualified
    mov rdx, rax
    mov rdi, r13
    mov rsi, r14
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rax, rbx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

FN agentext_toggle_named
    PROLOGUE
    mov r13, rdi
    mov r14, rsi
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 8f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    cmp dword ptr [rbx + EXT_status], ES_REMOVED
    je 1b
    mov rdi, rbx
    call ai_ext
    cmp dword ptr [rax + AX_agents], 0
    je 1b
    mov rdi, rbx
    call ext_qualified
    mov rdx, rax
    mov rdi, r13
    mov rsi, r14
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rdi, rbx
    call toggle
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

.section .rodata
.Lk_agents: .asciz "agents"
.Ls_agents: .asciz "agents"
.Ls_agents_dot: .asciz "agents."
.Ls_eq_false: .asciz " = false\n"
.Ls_eq_true_nl: .asciz "=true\n"
.Ls_eq_false_nl: .asciz "=false\n"
.Ls_show: .asciz "Show the sessions "
.Ls_lists: .asciz " lists in the agents panel."
.Lk_agents_title: .asciz "agents.title"
.Lv_transcript: .asciz "agent-transcript "
.Le_provides: .asciz "refused the manifest does not say [provides] agents = yes"
.Le_rows_toobig: .asciz "toobig more than 1000 sessions"
.Le_rows_syntax: .asciz "syntax the sessions cannot be read"
.Le_no_session: .asciz "refused no such session"
.Ls_idle: .asciz "idle"
.Ls_working: .asciz "working"
.Ls_waiting: .asciz "waiting"
.Ls_error: .asciz "error"
.Lr_user: .asciz "user"
.Lr_assistant: .asciz "assistant"
.Lr_tool: .asciz "tool"
.Lr_result: .asciz "result"
.Lr_info: .asciz "info"
.p2align 3
state_names: .quad .Ls_idle, .Ls_working, .Ls_waiting, .Ls_error, 0
role_names: .quad .Lr_user, .Lr_assistant, .Lr_tool, .Lr_result, .Ls_error, .Lr_info, 0
.globl agentext_state_names
agentext_state_names: .quad .Ls_idle, .Ls_working, .Ls_waiting, .Ls_error

.text
# ---------------- interactive sessions (D4) ----------------

# feature agent-prompts: a session of an extension that agreed it gets a prompt box (Enter sends
# "ID agent-prompt SID LEN" and the text), Stop while it works ("0 agent-stop SID"), and the cards
# the extension asks with agent-ask: a prompt line and up to 16 options as buttons (1 to 9 pick).
# A new session starts from the list's + button: its first prompt goes as agent-prompt - LEN, and
# the session the answer names opens once the extension lists it.
#
# The box and the cards are the generic part: a session gets them when it has a driver
# (agent_drv_of, agent_drv.s), and Send, Stop and a card's pick go through it (agent_send,
# agent_stop, agent_answer). The extension's own requests are its driver's table: agentext_ext_send,
# agentext_stop, agentext_ext_pick. A new conversation is written for an extension (new_ext) or for
# a built-in driver (new_kind, "+ Claude Code").

.equ AXK_OPTS_MAX, 16
.equ AXK_OPT_MAX, 200
.equ AXK_PROMPT_MAX, 1000
.equ AX_PROMPT_MAX, 65536       # a prompt's text

# a card
STRUCT
F AXK_ext, 8
F AXK_id, 8             # the agent-ask request it answers
F AXK_prompt, 8         # cstr
F AXK_opts, VEC_SIZE    # cstr*
F AXK_sel, 8            # the option the arrow keys moved to
F AXK_kb, 8             # 1 once the arrow keys moved: Enter picks AXK_sel
ENDSTRUCT AXK_SIZE

.bss
.p2align 3
in_tf: .zero TF_SIZE            # the prompt box
in_as: .quad 0                  # the session it belongs to
new_ext: .quad 0                # a new session of this extension is being written
new_kind: .quad 0               # or a new conversation of this built-in driver (AG_*)
pend_id: .quad 0                # the agent-prompt in flight: its id, extension
pend_ext: .quad 0
pend_new: .quad 0               # 1 when it starts a new session
pend_gen: .quad 0               # in_gen when it was sent: a refused text goes back to that box only
in_gen: .quad 0                 # changes whenever the box changes owner
keep_box: .quad 0               # open_wanted: the box moves to the new session with its text
pend_text: .zero SB_SIZE        # and its text, back in the box when it fails
want_ext: .quad 0               # open this extension's session when it is listed
want_sid: .quad 0               # cstr

.text

# FN agentext_prompts(AS*) -> eax 1 when its extension takes prompts
FN agentext_prompts
    xor eax, eax
    test rdi, rdi
    jz 9f
    cmp dword ptr [rdi + AS_kind], AS_KIND_EXT
    jne 9f
    mov rcx, [rdi + AS_ext]
    FEAT_TEST rcx, FEAT_AGENT_PROMPTS
    setnz al
9:  ret

# ---- cards ----

# FN agentext_ask(ext, id, sid ptr, sid len, body, len) -> rax 0 (answered when the user picks), or the
#   error reply: a card in the session's conversation; one replaces the session's earlier card
FN agentext_ask
    PROLOGUE 176                # [rsp] id, [8] body, [16] its len, [24] prompt, [32] options, [40] them
    mov rbx, rdi
    mov [rsp], rsi
    mov r12, rcx                # sid len
    mov r13, rdx                # sid
    mov [rsp + 8], r8
    mov [rsp + 16], r9
    mov qword ptr [rsp + 24], 0
    mov qword ptr [rsp + 32], 0
    mov rdi, rbx
    call ai_ext
    mov rdi, rax
    mov rsi, r13
    mov rdx, r12
    call row_find
    test rax, rax
    jz .Lak_none
    mov r14, rax
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call ai_rd_init
    call ai_rd_line
    test rax, rax
    jz .Lak_syntax              # a prompt line and at least one option
    mov rdi, rax
    mov rsi, rdx
    mov edx, AXK_PROMPT_MAX
    call ai_cut
    mov rdi, rax
    mov rsi, rdx
    call ai_dup
    mov [rsp + 24], rax
1:  call ai_rd_done
    test eax, eax
    jnz 3f
    call ai_rd_line
    test rax, rax
    jnz 2f
    call ai_rd_pos              # the last option may lack its LF
    mov rdx, [rsp + 8]
    add rdx, [rsp + 16]
    sub rdx, rax
    push rax
    push rdx
    mov rdi, rdx
    call ai_rd_take
    pop rdx
    pop rax
2:  test rdx, rdx
    jz .Lak_syntax              # an empty option
    cmp qword ptr [rsp + 32], AXK_OPTS_MAX
    jae .Lak_toobig
    mov rdi, rax
    mov rsi, rdx
    mov edx, AXK_OPT_MAX
    call ai_cut
    mov rdi, rax
    mov rsi, rdx
    call ai_dup
    mov rcx, [rsp + 32]
    mov [rsp + 40 + rcx*8], rax
    inc qword ptr [rsp + 32]
    jmp 1b
3:  cmp qword ptr [rsp + 32], 0
    je .Lak_syntax
    mov rdi, r14
    call agentext_ask_drop      # the card it had
    mov rdi, [rsp + 24]
    call strlen
    mov rdi, r14
    xor esi, esi                # an extension's card: its request below
    mov rdx, [rsp + 24]
    mov rcx, rax
    lea r8, [rsp + 40]
    mov r9, [rsp + 32]
    call agentext_card
    mov rax, [r14 + AS_ask]
    mov [rax + AXK_ext], rbx
    mov rcx, [rsp]
    mov [rax + AXK_id], rcx
    lea rdi, [rsp]
    call ask_temps_free
    xor eax, eax
    EPILOGUE
.Lak_none:
    lea rax, [rip + .Le_no_session]
    EPILOGUE
.Lak_toobig:
    lea rdi, [rsp]
    call ask_temps_free
    lea rax, [rip + .Le_card_toobig]
    EPILOGUE
.Lak_syntax:
    lea rdi, [rsp]
    call ask_temps_free
    lea rax, [rip + .Le_card_syntax]
    EPILOGUE

# ask_temps_free(frame): agentext_ask's copies of the prompt and the options go (its frame)
ask_temps_free:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + 24]
    call mem_free
    xor r12d, r12d
1:  cmp r12, [rbx + 32]
    jae 9f
    mov rdi, [rbx + 40 + r12*8]
    call mem_free
    inc r12
    jmp 1b
9:  EPILOGUE

# FN agentext_card(AS*, token, prompt ptr, len, opts cstr*, n) -> eax 1: a card on any session (it
#   replaces the one it had, unanswered); token 0 is an extension's card (agentext_ask fills AXK_ext and
#   AXK_id), else the driver's own (its AQ*, agentext_card_token). 0 without options or past 16
FN agentext_card
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    mov r12, rdx
    mov r13, rcx
    mov r14, r8
    mov r15, r9
    xor eax, eax
    test r15, r15
    jz 9f
    cmp r15, AXK_OPTS_MAX
    ja 9f
    mov rdi, rbx
    call agentext_card_drop
    mov edi, AXK_SIZE
    call mem_alloc
    mov [rbx + AS_ask], rax
    mov rcx, [rsp]
    mov [rax + AXK_id], rcx
    mov rdi, r12
    mov rsi, r13
    mov edx, AXK_PROMPT_MAX
    call ai_cut
    mov rdi, rax
    mov rsi, rdx
    call ai_dup
    mov rcx, [rbx + AS_ask]
    mov [rcx + AXK_prompt], rax
    xor r12d, r12d
1:  cmp r12, r15
    jae 2f
    mov rdi, [r14 + r12*8]
    call strlen
    mov rdi, [r14 + r12*8]
    mov rsi, rax
    mov edx, AXK_OPT_MAX
    call ai_cut
    mov rdi, rax
    mov rsi, rdx
    call ai_dup
    mov [rsp + 8], rax
    mov rdi, [rbx + AS_ask]
    add rdi, AXK_opts
    mov esi, 8
    call vec_push
    mov rcx, [rsp + 8]
    mov [rax], rcx
    inc r12
    jmp 1b
2:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# FN agentext_card_drop(AS*): its card goes without an answer
FN agentext_card_drop
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + AS_ask]
    test rdi, rdi
    jz 9f
    mov qword ptr [rbx + AS_ask], 0
    call card_free
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN agentext_card_token(AS*) -> rax the token of a driver's card on the session (its AQ*), or 0
FN agentext_card_token
    xor eax, eax
    mov rcx, [rdi + AS_ask]
    test rcx, rcx
    jz 1f
    cmp qword ptr [rcx + AXK_ext], 0
    jne 1f
    mov rax, [rcx + AXK_id]
1:  ret

# card_free(AXK*)
card_free:
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    mov rdi, [rbx + AXK_prompt]
    call mem_free
    xor r12d, r12d
1:  cmp r12, [rbx + AXK_opts + VEC_len]
    jae 2f
    mov rax, [rbx + AXK_opts + VEC_ptr]
    mov rdi, [rax + r12*8]
    call mem_free
    inc r12
    jmp 1b
2:  lea rdi, [rbx + AXK_opts]
    call vec_free
    mov rdi, rbx
    call mem_free
9:  EPILOGUE

# FN agentext_ask_drop(AS*): its card goes, answered cancelled (a driver's card goes unanswered)
FN agentext_ask_drop
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + AS_ask]
    test r12, r12
    jz 9f
    cmp qword ptr [r12 + AXK_ext], 0
    jne 1f
    call agentext_card_drop
    jmp 9f
1:  mov qword ptr [rbx + AS_ask], 0
    lea rdi, [rip + .Le_cancelled]
    call strlen
    mov rdi, [r12 + AXK_ext]
    mov rsi, [r12 + AXK_id]
    xor edx, edx
    xor ecx, ecx
    lea r8, [rip + .Le_cancelled]
    mov r9, rax
    call extproto_ai_answer
    mov rdi, r12
    call card_free
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN agentext_pick(AS*, n): the user chose option n (from 0) of the session's card: its driver answers
FN agentext_pick
    xor eax, eax
    test rdi, rdi
    jz 1f
    mov rcx, [rdi + AS_ask]
    test rcx, rcx
    jz 1f
    cmp rsi, [rcx + AXK_opts + VEC_len]
    jae 1f
    jmp agent_answer
1:  ret

# FN agentext_ext_pick(AS*, n) -> eax 1: the extension driver's answer: "N+1" to its agent-ask
FN agentext_ext_pick
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor eax, eax
    mov r13, [rbx + AS_ask]
    test r13, r13
    jz 9f
    cmp r12, [r13 + AXK_opts + VEC_len]
    jae 9f
    cmp qword ptr [r13 + AXK_ext], 0
    je 9f
    mov qword ptr [rbx + AS_ask], 0
    lea rdi, [rip + num]
    lea rsi, [r12 + 1]
    call fmt_u64
    mov rdi, [r13 + AXK_ext]
    mov rsi, [r13 + AXK_id]
    lea rdx, [rip + num]
    mov rcx, rax
    xor r8d, r8d
    xor r9d, r9d
    call extproto_ai_answer
    mov rdi, r13
    call card_free
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# FN agentext_cancel(ext, id) -> eax 1 when it was one of its cards: it goes, answered cancelled
FN agentext_cancel
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call ai_ext
    mov r13, rax
    xor r14d, r14d
1:  cmp r14, [r13 + AX_rows + VEC_len]
    jae 8f
    mov rax, [r13 + AX_rows + VEC_ptr]
    mov rdi, [rax + r14*8]
    inc r14
    mov rcx, [rdi + AS_ask]
    test rcx, rcx
    jz 1b
    cmp [rcx + AXK_id], r12
    jne 1b
    call agentext_ask_drop
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---- prompts ----

# FN agentext_send(): the box's text to the session it belongs to, or to a new session: its driver
#   takes it (agent_send), and the box empties when it went or waits to go
FN agentext_send
    PROLOGUE 16
    xor ebx, ebx
    lea rdi, [rip + in_tf]
    call tf_text
    mov r12, rax
    mov r13, rdx
    xor ecx, ecx                # only blanks: nothing to send
71: cmp rcx, r13
    jae 9f
    movzx eax, byte ptr [r12 + rcx]
    inc rcx
    cmp eax, ' '
    jbe 71b
    cmp qword ptr [rip + new_ext], 0
    je 1f
    xor edi, edi                # a new session of an extension
    mov rsi, r12
    mov rdx, r13
    call agentext_ext_send
    jmp 5f
1:  cmp qword ptr [rip + new_kind], 0
    jne 4f                      # a built-in driver's draft: checked first, its conversation made last
    call agents_open_driven     # else the session the panel shows
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp dword ptr [rbx + AS_kind], AS_KIND_EXT
    je 4f                       # an extension's driver takes the box itself (agentext_ext_send)
3:  cmp [rip + in_as], rbx      # the box is this session's from now on
    je 4f
    mov [rip + in_as], rbx
    inc qword ptr [rip + in_gen]
    mov rdi, rbx
    call composer_adopt
4:  mov rdi, rbx                # the composer's checks: invisible characters, the limit (a notice)
    call composer_send_ok
    test eax, eax
    jz 9f
    mov rdi, rbx                # a command the driver's own table runs (agentpop.s): it ran, the box
    mov rsi, r12                #   emptied and settled before it acted (agentext_slash_begin)
    mov rdx, r13
    call agentpop_slash
    test eax, eax
    jnz 10f
    test rbx, rbx               # a draft that sends: its conversation now (it opens with the text)
    jnz 41f
    mov rdi, [rip + new_kind]
    mov qword ptr [rip + keep_box], 1
    call agent_new
    mov qword ptr [rip + keep_box], 0
    test rax, rax
    jz 8f
    mov rbx, rax
    lea rdi, [rip + in_tf]      # opening it may have moved the text
    call tf_text
    mov r12, rax
    mov r13, rdx
41: mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call agent_send
5:  cmp eax, SEND_OK
    je 6f
    cmp eax, SEND_QUEUED
    je 6f
    cmp eax, SEND_HELD          # written during a turn, shown queued (SEND_TOOMANY: agent_send's toast)
    je 6f
    lea rdi, [rip + .Lsend_refused]
    cmp eax, SEND_REFUSED
    je 7f
    lea rdi, [rip + .Lsend_full]
    cmp eax, SEND_FULL
    jne 9f
7:  call app_toast
    EPILOGUE
6:  lea rdi, [rip + in_tf]
    call tf_clear
    mov rdi, rbx                # (0: an extension's new session)
    call composer_sent
10: mov dword ptr [rip + g_dirty], 1
    EPILOGUE
8:  lea rdi, [rip + .Lnew_failed]
    call app_toast
9:  EPILOGUE

# FN agentext_slash_begin(AS* or 0 for a draft): a command of the driver's table is about to act on the
#   box's text: the box empties and is that conversation's (or the draft's) before the command opens
#   another draft, a picker or a conversation (agentpop_slash)
FN agentext_slash_begin
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + in_tf]
    call tf_clear
    mov rdi, rbx
    call composer_sent
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# FN agentext_ext_send(AS* or 0 for a new session of new_ext, ptr, len) -> eax SEND_OK when the
#   agent-prompt went (its text is kept until the answer), else SEND_FAILED: the extension driver's send
FN agentext_ext_send
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r15d, SEND_FAILED
    cmp qword ptr [rip + pend_id], 0
    jne 9f                      # one prompt at a time
    cmp r13, AX_PROMPT_MAX
    ja 7f
    mov r14, [rip + new_ext]
    test rbx, rbx
    jz 1f                       # a new session
    mov rdi, rbx
    call agentext_prompts
    test eax, eax
    jz 9f
    mov r14, [rbx + AS_ext]
    cmp [rip + in_as], rbx      # the box is this session's from now on
    je 1f
    mov [rip + in_as], rbx
    inc qword ptr [rip + in_gen]
1:  test r14, r14
    jz 9f
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lv_prompt]
    call sb_push_cstr
    lea rsi, [rip + .Ldash]
    test rbx, rbx
    jz 2f
    mov rsi, [rbx + AS_sid]
2:  lea rdi, [rip + tmp]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, r13
    call sb_push_u64
    mov rdi, r14
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    mov rcx, r12
    mov r8, r13
    call extproto_ai_request
    test rax, rax
    jz 8f
    mov [rip + pend_id], rax
    mov [rip + pend_ext], r14
    xor ecx, ecx
    test rbx, rbx
    sete cl
    mov [rip + pend_new], rcx
    mov rcx, [rip + in_gen]
    mov [rip + pend_gen], rcx
    mov rdi, r14
    mov rsi, rax
    mov edx, PK_PROMPT
    mov ecx, QO_AI
    call query_track
    lea rdi, [rip + pend_text]
    call sb_clear
    lea rdi, [rip + pend_text]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov r15d, SEND_OK
    jmp 9f
8:  lea rdi, [rip + .Lnot_running]
    call app_toast
    jmp 9f
7:  lea rdi, [rip + .Lprompt_long]
    call app_toast
9:  mov eax, r15d
    EPILOGUE

# FN agentext_restore(AS*, ptr, len) -> eax 1 done: text that did not go goes back in the box when the box
#   is that session's (a driver's start failed or was stopped with prompts waiting): before what the box
#   holds now, a blank line between, so neither is lost. 0: the box is another's (the caller keeps it)
FN agentext_restore
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp [rip + in_as], rbx
    jne 9f
    lea rdi, [rip + in_tf]
    call tf_text
    test rdx, rdx
    jz 1f
    mov r14, rax
    mov r15, rdx
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lrestore_gap]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    mov r12, [rip + tmp + SB_ptr]
    mov r13, [rip + tmp + SB_len]
1:  lea rdi, [rip + in_tf]
    mov rsi, r12
    mov rdx, r13
    call tf_set
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# FN agentext_prompt_reply(ext, id, ok, body, len) -> eax 1 when it answered the prompt in flight:
#   a new session's id opens it once listed; a refusal puts the text back in the box
FN agentext_prompt_reply
    PROLOGUE
    xor eax, eax
    test rsi, rsi
    jz 9f
    cmp rsi, [rip + pend_id]
    jne 9f
    cmp rdi, [rip + pend_ext]
    jne 9f
    mov rbx, rdi
    mov qword ptr [rip + pend_id], 0
    mov r12, rcx
    mov r13, r8
    test edx, edx
    jz 5f
    # a new session: opened once it is listed (it may be already), unless the user went elsewhere
    cmp qword ptr [rip + pend_new], 0
    je 4f
    cmp [rip + new_ext], rbx
    jne 4f
    mov rax, [rip + in_gen]     # the box is still the one that sent it (not a later draft)
    cmp rax, [rip + pend_gen]
    jne 4f
    mov rdi, r12
    mov rsi, r13
    mov edx, AGENT_SID_MAX
    call ai_word_ok
    test eax, eax
    jz 4f
    call want_clear
    mov rdi, r12
    mov rsi, r13
    call ai_dup
    mov [rip + want_sid], rax
    mov [rip + want_ext], rbx
    call open_wanted
4:  mov eax, 1
    EPILOGUE
5:  # refused: the reason shows, and the text goes back in its box
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lprompt_failed]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r13
    mov edx, 200
    call ai_cut
    lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + tmp]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + tmp + SB_ptr]
    call restore_pending
    mov eax, 1
9:  EPILOGUE

# restore_pending(cstr): the prompt in flight failed: the reason shows, and its text goes back in
#   the box when the box still belongs to the same session and the user typed nothing new
restore_pending:
    PROLOGUE
    call app_toast
    mov rax, [rip + in_gen]
    cmp rax, [rip + pend_gen]
    jne 9f
    lea rdi, [rip + in_tf]
    call tf_text
    test rdx, rdx
    jnz 9f
    lea rdi, [rip + in_tf]
    mov rsi, [rip + pend_text + SB_ptr]
    mov rdx, [rip + pend_text + SB_len]
    call tf_set
9:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# want_clear(): no session waits to be opened
want_clear:
    PROLOGUE
    mov rdi, [rip + want_sid]
    call mem_free
    mov qword ptr [rip + want_sid], 0
    mov qword ptr [rip + want_ext], 0
    EPILOGUE

# open_wanted(): the session a new prompt started opens when its extension lists it (and the page
#   shows it); the wish ends when it opens, the user opens another, or the extension stops
open_wanted:
    PROLOGUE
    mov rbx, [rip + want_sid]
    test rbx, rbx
    jz 9f
    mov rdi, [rip + want_ext]
    test rdi, rdi
    jz 8f
    call ai_ext
    mov r12, rax
    mov rdi, rbx
    call strlen
    mov rdi, r12
    mov rsi, rbx
    mov rdx, rax
    call row_find
    test rax, rax
    jz 9f
    mov rdi, rax
    mov qword ptr [rip + keep_box], 1   # what the user typed meanwhile goes on in its box
    call agents_open_as         # opening it ends the wish (agentext_opened)
    mov qword ptr [rip + keep_box], 0
    jmp 9f
8:  call want_clear
9:  EPILOGUE

# FN agentext_row_gone(AS*): a row is freed: the box forgets it
FN agentext_row_gone
    push rbx
    mov rbx, rdi
    call composer_row_gone      # what the composer keeps for it
    cmp [rip + in_as], rbx
    jne 1f
    mov qword ptr [rip + in_as], 0
    inc qword ptr [rip + in_gen]
1:  pop rbx
    ret

# FN agentext_stop(AS*): "0 agent-stop SID"
FN agentext_stop
    PROLOGUE
    mov rbx, rdi
    call agentext_prompts
    test eax, eax
    jz 9f
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lev_stop]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rbx + AS_sid]
    call sb_push_cstr
    mov rdi, [rbx + AS_ext]
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    xor ecx, ecx
    xor r8d, r8d
    call extproto_ai_event
9:  EPILOGUE

# FN agentext_new(ext): a new session of the extension is being written (the box, no messages yet)
FN agentext_new
    PROLOGUE
    mov rbx, rdi
    call prompts_ok
    test eax, eax
    jz 9f
    mov [rip + new_ext], rbx
    mov qword ptr [rip + new_kind], 0
    call draft_begin
9:  EPILOGUE

# FN agentext_new_kind(kind) -> eax 1: a new conversation of that built-in driver is being written (the
#   box, no messages yet); 0 when the driver is not available
FN agentext_new_kind
    PROLOGUE
    mov rbx, rdi
    call agent_drv_for_kind
    test rax, rax
    jz 9f
    mov qword ptr [rip + new_ext], 0
    mov [rip + new_kind], rbx
    call draft_begin
    mov eax, 1
9:  EPILOGUE

# draft_begin(): the box is the new session's, empty, with the keys
draft_begin:
    PROLOGUE
    mov qword ptr [rip + in_as], 0
    inc qword ptr [rip + in_gen]
    xor edi, edi                # the box empties; a new conversation's kept text comes back
    xor esi, esi
    call composer_owner
    mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# prompts_ok(ext) -> eax 1 when a new session of it can be written: it runs, agreed agents and
#   agent-prompts, lists sessions, and is switched on in Settings > Agents
prompts_ok:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
    test rbx, rbx
    jz 9f
    cmp dword ptr [rbx + EXT_status], ES_RUNNING
    jne 9f
    FEAT_TEST rbx, FEAT_AGENTS
    jz 9f
    FEAT_TEST rbx, FEAT_AGENT_PROMPTS
    jz 9f
    mov rdi, rbx
    call ai_ext
    cmp dword ptr [rax + AX_agents], 0
    je 9f
    cmp dword ptr [rax + AX_hidden], 0
    jne 9f
    mov r12d, 1
9:  mov eax, r12d
    EPILOGUE

# FN agentext_unsent_back(AS*): the box became the session's (emptied): prompts of its that never went (its
#   start failed while another was open) come back in it, with a toast (composer_owner)
FN agentext_unsent_back
    PROLOGUE
    call agent_unsent_take
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, rax
    call strlen
    lea rdi, [rip + in_tf]
    mov rsi, rbx
    mov rdx, rax
    call tf_set
    mov rdi, rbx
    call mem_free
    lea rdi, [rip + .Lunsent_back]
    call app_toast
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN agentext_opened(AS*): a session opened: no new one is written, and the box is its own (a box
#   that belonged to another session is emptied)
FN agentext_opened
    PROLOGUE
    mov rbx, rdi
    mov qword ptr [rip + new_ext], 0
    mov qword ptr [rip + new_kind], 0
    call want_clear
    cmp [rip + in_as], rbx
    je 9f
    mov [rip + in_as], rbx
    inc qword ptr [rip + in_gen]
    mov rdi, rbx                # the old owner keeps its text, the box empties and takes this one's
    xor esi, esi
    cmp qword ptr [rip + keep_box], 0
    setne sil                   # (the session its own first prompt started: the text stays)
    call composer_owner
9:  EPILOGUE

# FN agentext_remote_line(AS*) -> eax 1 when the session shows "Chat is not available in remote windows
#   yet" where its box would be: a Claude Code conversation in a remote window with the chat on
FN agentext_remote_line
    xor eax, eax
    test rdi, rdi
    jz 1f
    cmp dword ptr [rdi + AS_kind], AG_CLAUDE
    jne 1f
    cmp dword ptr [rip + cfg_claude_chat], 0
    je 1f
    cmp dword ptr [rip + g_remote], 0
    je 1f
    inc eax
1:  ret

# FN agentext_open_keep(AS*): that session opens and the box goes with it, its text kept (a copy of the
#   conversation the box was writing to)
FN agentext_open_keep
    PROLOGUE
    mov qword ptr [rip + keep_box], 1
    call agents_open_as
    mov qword ptr [rip + keep_box], 0
    EPILOGUE

# FN agentext_new_active() -> rax not 0 while a new session is written: its extension (EXT*), or the
#   built-in driver's kind (AG_*)
FN agentext_new_active
    mov rax, [rip + new_ext]
    test rax, rax
    jnz 1f
    mov rax, [rip + new_kind]
1:  ret

# FN agentext_new_leave(): back to the list
FN agentext_new_leave
    mov qword ptr [rip + new_ext], 0
    mov qword ptr [rip + new_kind], 0
    cmp dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    jne 1f
    mov dword ptr [rip + g_focus], FOCUS_AGENTS
1:  mov dword ptr [rip + g_dirty], 1
    ret

# ---- keys ----

# FN agentext_field() -> TF*: the focused field: the command menu's filter while it has the keys, else the
#   prompt box (paste, input methods)
FN agentext_field
    push rbx
    call agentpop_field
    pop rbx
    test rax, rax
    jnz 1f
    lea rax, [rip + in_tf]
1:  ret

# FN agentext_box() -> TF*: the prompt box
FN agentext_box
    lea rax, [rip + in_tf]
    ret

# FN agentext_box_owner() -> rax the session the box writes to now (0: a built-in driver's new conversation
#   being written), edx that driver's kind (0: no box of a built-in driver: an extension's, or none)
FN agentext_box_owner
    xor eax, eax
    xor edx, edx
    cmp qword ptr [rip + new_ext], 0
    jne 9f
    mov rdx, [rip + new_kind]
    test rdx, rdx
    jnz 9f
    push rbx
    call agents_open_driven
    pop rbx
    xor edx, edx
    test rax, rax
    jz 9f
    mov edx, [rax + AS_kind]
    cmp edx, AS_KIND_EXT
    jne 9f
    xor edx, edx
9:  ret

# FN agentext_draft_own() -> rax the conversation a built-in driver's draft becomes now (agent_new, the box's
#   text kept with it), or 0 (no draft, or it could not start)
FN agentext_draft_own
    PROLOGUE
    xor eax, eax
    mov rdi, [rip + new_kind]
    test rdi, rdi
    jz 9f
    mov qword ptr [rip + keep_box], 1
    call agent_new
    mov qword ptr [rip + keep_box], 0
9:  EPILOGUE

# FN agentext_box_changed(): the box's text or its caret changed (a key, a paste, a click): a driven box's
#   record is read (a writer's action), and the typed command menu follows it (agentpop.s)
FN agentext_box_changed
    PROLOGUE
    call composer_changed       # an emptied box ends the recall; a notice about another text goes
    call agentext_box_owner
    test edx, edx
    jz 1f
    mov edi, edx
    call agentcfg_get
    mov rdi, rax
    call agentcfg_need
1:  lea rdi, [rip + in_tf]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + in_tf + TF_cur]
    call agentpop_typed
    EPILOGUE

# FN agentext_typed(): text was typed into the box: the session it belongs to hears of it (agent_typing:
#   a driven session's program starts). A built-in driver's draft becomes its conversation at the first
#   character (agent_new), the text staying in the box
FN agentext_typed
    cmp qword ptr [rip + new_ext], 0
    jne 1f
    cmp qword ptr [rip + new_kind], 0
    jne 2f
    push rbx
    call agents_open_driven
    pop rbx
    test rax, rax
    jz 1f
    mov rdi, rax
    jmp agent_typing
1:  ret
2:  PROLOGUE
    lea rdi, [rip + in_tf]
    call tf_text
    test rdx, rdx
    jz 9f
    mov rdi, [rip + new_kind]
    mov qword ptr [rip + keep_box], 1
    call agent_new
    mov qword ptr [rip + keep_box], 0
    test rax, rax
    jz 8f
    mov rdi, rax
    call agent_typing
    EPILOGUE
8:  lea rdi, [rip + .Lnew_failed]
    call app_toast
9:  EPILOGUE

# FN agentext_paste(ptr, len)
FN agentext_paste
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + in_tf]
    jmp ta_insert

# FN agentext_input_key(keysym, cp, mods) -> eax 1 when the prompt box took the key: Enter sends
#   (Shift+Enter a new line), Escape leaves the box
FN agentext_input_key
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    cmp dword ptr [rip + g_show_agents], 0
    jne 6f
    mov dword ptr [rip + g_focus], FOCUS_EDITOR   # the panel was hidden: the editor has the keys
    jmp 9f
6:  call agentdlg_key           # a dialog over the panel takes the keys first (agentdlg.s)
    test eax, eax
    jz 61f
    EPILOGUE
61: mov edi, r12d               # the composer first: an open popup takes its keys (Escape closes it
    mov esi, r13d               #   before Escape means anything else)
    mov edx, r14d
    call composer_key
    test eax, eax
    jnz 8f
    cmp qword ptr [rip + new_ext], 0
    jne 0f
    cmp qword ptr [rip + new_kind], 0
    jne 0f
    call agents_open_driven     # the box has no session any more: the panel takes the keys
    test rax, rax
    jz 7f
    cmp r12d, KEY_ESCAPE        # Escape while its turn runs: Stop (agent_drv.s); the box keeps the keys
    jne 1f
    mov rdi, rax
    call agent_stop_running
    test eax, eax
    jnz 8f
0:  cmp r12d, KEY_ESCAPE
    jne 1f
7:  mov dword ptr [rip + g_focus], FOCUS_AGENTS
    cmp r12d, KEY_ESCAPE
    jne 9f
    jmp 8f
1:  cmp r12d, KEY_RETURN
    je 2f
    cmp r12d, KEY_KP_ENTER
    jne 3f
2:  test r14d, MOD_SHIFT
    jnz 3f
    call agentext_send
    jmp 8f
3:  lea rdi, [rip + in_tf]
    call tf_text
    mov r15, rdx                # its length before the key
    lea rdi, [rip + in_tf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call ta_key
    test eax, eax
    jz 9f
    mov rdi, r15
    call box_typed
    call agentext_box_changed
8:  call composer_keyed         # (a card's focus rule)
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# FN agentext_box_typed(len before), box_typed: the box took a key or a paste: when it holds text now, its
#   session hears of it: the first text starts its program (agentext_typed), more only keeps it from the idle
#   stop
FN agentext_box_typed
box_typed:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + in_tf]
    call tf_text
    test rdx, rdx
    jz 9f
    test rbx, rbx
    jnz 1f
    call agentext_typed
    EPILOGUE
1:  call agents_open_driven
    test rax, rax
    jz 9f
    mov rdi, rax
    call agent_touch
9:  EPILOGUE

# FN agentext_box_paste(ptr, len): a paste into the box (app_on_paste): as typing, it may start the
#   session's program; while the command menu's filter has the keys, into the filter
FN agentext_box_paste
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call agentpop_field
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call ta_insert
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
1:  mov rdi, r12                # a built-in driver's box: the limit, invisible characters (agentcompose.s)
    mov rsi, r13
    call composer_paste
    test eax, eax
    jnz 9f
    lea rdi, [rip + in_tf]
    call tf_text
    mov rbx, rdx
    mov rdi, r12
    mov rsi, r13
    call agentext_paste
    mov rdi, rbx
    call box_typed
    call agentext_box_changed
9:  EPILOGUE

# FN agentext_drivers_changed(): a driver went away (the settings changed): a new conversation being begun
#   for it is left
FN agentext_drivers_changed
    PROLOGUE
    mov rdi, [rip + new_kind]
    test rdi, rdi
    jz 9f
    call agent_drv_for_kind
    test rax, rax
    jnz 9f
    call agentext_new_leave
9:  EPILOGUE

# FN agentext_card_nav(AS*, keysym) -> eax 1 when the arrow keys moved among the card's options, or
#   Enter picked the one they chose (every option is reachable, also past 9 and in a cut card)
FN agentext_card_nav
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rcx, [rdi + AS_ask]
    test rcx, rcx
    jz 9f
    mov rdx, [rcx + AXK_sel]
    cmp esi, KEY_RETURN
    je 5f
    cmp esi, KEY_KP_ENTER
    je 5f
    cmp esi, KEY_LEFT
    je 1f
    cmp esi, KEY_UP
    je 1f
    cmp esi, KEY_RIGHT
    je 2f
    cmp esi, KEY_DOWN
    jne 9f
2:  inc rdx
    cmp rdx, [rcx + AXK_opts + VEC_len]
    jb 3f
    dec rdx
    jmp 3f
1:  test rdx, rdx
    jz 3f
    dec rdx
3:  mov [rcx + AXK_sel], rdx
    mov qword ptr [rcx + AXK_kb], 1
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  ret
5:  cmp qword ptr [rcx + AXK_kb], 0
    je 9b
    mov rsi, rdx
    push rbx
    call agentext_pick
    pop rbx
    mov eax, 1
    ret

# FN agentext_card_key(AS*, cp) -> eax 1 when 1 to 9 picked an option of the session's card
FN agentext_card_key
    xor eax, eax
    test rdi, rdi
    jz 9f
    mov rcx, [rdi + AS_ask]
    test rcx, rcx
    jz 9f
    sub esi, '1'
    cmp esi, 8
    ja 9f
    movsxd rsi, esi
    cmp rsi, [rcx + AXK_opts + VEC_len]
    jae 9f
    push rbx
    call agentext_pick
    pop rbx
    mov eax, 1
9:  ret

# ---- drawing ----

# card_h(AS*, w) -> eax the card's height (0 without one): its prompt, then rows of buttons
card_h:
    PROLOGUE
    xor eax, eax
    mov rbx, [rdi + AS_ask]
    test rbx, rbx
    jz 9f
    mov r12d, esi
    mov rdi, rbx
    mov rdx, [rbx + AXK_opts + VEC_len]
    dec rdx
    call opt_row
    inc eax                     # rows
    mov ecx, [rip + g_pmt + 4*MI_32]
    add ecx, [rip + g_pmt + 4*MI_6]
    imul eax, ecx
    add eax, [rip + g_pmt + 4*MI_40]
    add eax, [rip + g_pmt + 4*MI_12]
    mov r13d, eax
    mov rdi, [rbx + AXK_prompt] # the prompt's lines past its first
    mov esi, r12d
    sub esi, [rip + g_pmt + 4*MI_48]
    call prompt_lines
    dec eax
    imul eax, [rip + g_pmt + 4*MI_24]
    add eax, r13d
9:  EPILOGUE

# prompt_line(ptr, len, maxw) -> rax the bytes of a card prompt's first line at maxw px (the panel's
#   face), broken after a word when it can be; rdx the bytes it takes, with the space after it
prompt_line:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, [rip + ag_fui]
    mov rsi, r12
    mov ecx, edx
    mov rdx, r13
    call text_fit
    cmp rax, r13
    jae 7f
    mov rbx, rax                # what fits; the break is at a space there, or the last one before it
    mov rcx, rax
1:  cmp byte ptr [r12 + rcx], ' '
    je 2f
    test rcx, rcx
    jz 3f
    dec rcx
    jmp 1b
2:  test rcx, rcx
    jz 3f
    mov rax, rcx
    lea rdx, [rcx + 1]
    EPILOGUE
3:  test rbx, rbx               # one word longer than the line: cut where it fits (a character at least)
    jnz 4f
    mov rdi, r12
    mov rsi, r13
    call utf8_decode
    mov rbx, rdx
4:  mov rax, rbx
    mov rdx, rbx
    EPILOGUE
7:  mov rax, r13
    mov rdx, r13
    EPILOGUE

# prompt_lines(prompt cstr, maxw) -> eax the lines a card's prompt takes (1 to CARD_LINES)
prompt_lines:
    PROLOGUE
    mov r12, rdi
    mov r14d, esi
    call strlen
    mov r13, rax
    xor ebx, ebx
1:  inc ebx
    cmp ebx, CARD_LINES
    jae 9f
    mov rdi, r12
    mov rsi, r13
    mov edx, r14d
    call prompt_line
    add r12, rdx
    sub r13, rdx
    test r13, r13
    jnz 1b
9:  mov eax, ebx
    EPILOGUE

# opt_row(AXK*, w, i) -> eax the row (from 0) option i wraps to in a card w wide
opt_row:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rdx
    mov r12d, esi
    sub r12d, [rip + g_pmt + 4*MI_24]
    sub r12d, [rip + g_pmt + 4*MI_24]
    xor r13d, r13d              # row
    xor r14d, r14d              # x in the row
    xor r15d, r15d
1:  cmp r15, [rbx + AXK_opts + VEC_len]
    jae 3f
    cmp r15, [rsp]
    ja 3f
    mov rdi, rbx
    mov rsi, r15
    mov edx, r12d
    call opt_w
    inc r15
    test r14d, r14d
    jz 2f
    lea ecx, [r14 + rax]
    cmp ecx, r12d
    jle 2f
    inc r13d
    xor r14d, r14d
2:  add r14d, eax
    add r14d, [rip + g_pmt + 4*MI_6]
    jmp 1b
3:  mov eax, r13d
    EPILOGUE

# opt_w(AXK*, i, max) -> eax the width of option i's button ("N  text"), at most max
opt_w:
    PROLOGUE
    mov r12d, edx
    mov rax, [rdi + AXK_opts + VEC_ptr]
    mov rbx, [rax + rsi*8]
    mov rdi, rbx
    call strlen
    mov rdi, [rip + ag_fsmall]
    mov rsi, rbx
    mov rdx, rax
    call text_width
    add eax, [rip + g_pmt + 4*MI_32]
    add eax, [rip + g_pmt + 4*MI_8]
    mov ecx, [rip + g_pmt + 4*MI_64]   # long options are cut, also to the card's width
    imul ecx, ecx, 6
    cmp ecx, r12d
    cmovg ecx, r12d
    cmp eax, ecx
    cmovg eax, ecx
    EPILOGUE

# FN agentext_bottom_h(AS*, w) -> eax the height under a session's messages, top to bottom: its bands
#   (agentfoot.s), its card (a rich one, agentcard.s, else the simple one) and, when it has a driver, the
#   prompt box and its footer
FN agentext_bottom_h
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call bands_h
    mov r13d, eax
    mov rdi, rbx
    mov esi, r12d
    call any_card_h
    add r13d, eax
    mov rdi, rbx
    call agent_drv_of
    test rax, rax
    jnz 2f
    mov rdi, rbx                # a remote window's Claude Code conversation: one line where the box would be
    call agentext_remote_line
    test eax, eax
    jz 1f
    add r13d, [rip + g_pmt + 4*MI_32]
    jmp 1f
2:  mov rdi, rbx
    mov esi, r12d
    call box_keep
    add r13d, eax
1:  mov eax, r13d
    EPILOGUE

# box_keep(AS*, w) -> eax the room the prompt box and its footer keep (the bands and the card are cut
#   first); 0 without a driver
box_keep:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call agent_drv_of
    xor r13d, r13d
    test rax, rax
    jz 9f
    mov edi, r12d
    mov rsi, rbx
    call input_h
    mov r13d, eax
    mov rdi, rbx
    mov esi, r12d
    call foot_h
    add r13d, eax
9:  mov eax, r13d
    EPILOGUE

# box_focused() -> eax 1 when the box is drawn with the keys: it has them, and no popup's field takes them
box_focused:
    xor eax, eax
    cmp dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    jne 1f
    push rbx
    call agentpop_field
    pop rbx
    test rax, rax
    sete al
    movzx eax, al
1:  ret

# any_card_h(AS*, w) -> eax the session's card's height: its rich card's (agentcard.s) and, while the box
#   has text, the "Waiting for permission…" line under it; else the simple one's
any_card_h:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    call agentcard_of
    mov rdi, rbx
    mov esi, r12d
    test rax, rax
    jz 1f
    call agentcard_h
    mov r13d, eax
    mov rdi, rbx
    call waiting_h
    add eax, r13d
    EPILOGUE
1:  call card_h
    EPILOGUE

# waiting_h(AS*) -> eax the height of the line under a rich card that waits while the box has text, or 0
waiting_h:
    PROLOGUE
    call agentcard_waiting
    test rax, rax
    jz 9f
    mov rax, [rip + ag_fsmall]
    mov eax, [rax + FACE_lineh]
    add eax, [rip + g_pmt + 4*MI_8]
9:  EPILOGUE

# any_card_draw(AS*, x, y, w, h): its rich card (and the waiting line under it), else the simple one
any_card_draw:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    call agentcard_of
    test rax, rax
    jnz 2f
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r15d
    call card_draw
    EPILOGUE
2:  mov rdi, rbx
    call waiting_h
    mov [rsp], eax
    mov esi, r15d               # its room (none: not drawn, and no key answers it)
    sub esi, eax
    mov [rsp + 4], esi
    mov rdi, rbx
    call agentcard_room
    mov r8d, [rsp + 4]
    test r8d, r8d
    jle 3f
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call agentcard_draw
3:  cmp dword ptr [rsp], 0
    je 9f
    mov rdi, rbx                # "Waiting for permission…", right under the card, muted
    call agentcard_waiting
    test rax, rax               # (a click answered the card while it drew: it is gone)
    jz 9f
    mov [rsp + 8], rax
    mov rdi, rax
    call strlen
    mov [rsp + 4], eax
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rsp + 8]
    mov edx, eax
    call text_width
    mov ecx, r14d
    sub ecx, [rip + g_pmt + 4*MI_24]
    sub ecx, [rip + g_pmt + 4*MI_24]
    cmp eax, ecx
    cmovg eax, ecx
    mov esi, r12d
    add esi, r14d
    sub esi, [rip + g_pmt + 4*MI_24]
    sub esi, eax
    mov edx, r13d
    add edx, r15d
    sub edx, [rsp]
    mov ecx, [rsp]
    sub ecx, [rip + g_pmt + 4*MI_4]
    mov r8, [rsp + 8]
    mov r9d, [rsp + 4]
    push rax
    COLOR eax, T_MUTED
    push rax
    mov rdi, [rip + ag_fsmall]
    call ui_text_v_fit
    add rsp, 16
9:  EPILOGUE

# box_fit(w, AS* or 0): the prompt row across the panel's width w, in lay_*. In a row: the box (from
#   MI_12 in), Send with its word (MI_64), ending MI_40 - MI_8 - MI_12 before the right edge. The box gets
#   at least lay_min: four MI_32 (about ten characters), or the whole row when the panel is narrower.
#   Short of that Send becomes an icon (MI_32), then Send goes on a row under the box and the box takes the
#   whole row. The permission mode is the footer's (agentfoot.s)
box_fit:
    PROLOGUE
    mov r12d, edi
    mov rbx, rsi
    mov r13d, r12d              # the whole row: w - MI_40 + MI_8
    sub r13d, [rip + g_pmt + 4*MI_40]
    add r13d, [rip + g_pmt + 4*MI_8]
    mov eax, [rip + g_pmt + 4*MI_32]
    shl eax, 2
    cmp eax, r13d
    cmovg eax, r13d
    mov [rip + lay_min], eax
    mov dword ptr [rip + lay_below], 0
    mov r15d, [rip + g_pmt + 4*MI_64]
1:  mov eax, r12d               # in a row: w - Send - MI_40
    sub eax, r15d
    sub eax, [rip + g_pmt + 4*MI_40]
    cmp eax, [rip + lay_min]
    jge 8f
    cmp r15d, [rip + g_pmt + 4*MI_32]
    je 3f
    mov r15d, [rip + g_pmt + 4*MI_32]   # Send as an icon
    jmp 1b
3:  mov dword ptr [rip + lay_below], 1  # Send under the box
    mov r15d, [rip + g_pmt + 4*MI_64]
    cmp r15d, r13d
    jle 5f
    mov r15d, [rip + g_pmt + 4*MI_32]
5:  mov eax, r13d
    test eax, eax
    jg 8f
    mov eax, 1
8:  mov [rip + lay_box], eax
    mov [rip + lay_btn], r15d
    EPILOGUE

# below_h() -> eax the room box_fit's row under the box takes (0 when Send is beside it)
below_h:
    xor eax, eax
    cmp dword ptr [rip + lay_below], 0
    je 1f
    mov eax, [rip + g_pmt + 4*MI_32]
    add eax, [rip + g_pmt + 4*MI_8]
1:  ret

# input_h(w, AS* or 0) -> eax the prompt row's height: the box grows to 5 lines (in the panel's face;
#   fewer for a large one, as many as 5 of the interface's would take, at least 2), and the row under it
#   when Send goes there (box_fit, whose lay_* it leaves)
input_h:
    PROLOGUE
    mov rax, [rip + ag_fui]
    mov [rip + in_tf + TF_face], rax
    call box_fit
    mov esi, [rip + lay_box]
    lea rdi, [rip + in_tf]
    call ta_layout
    mov ebx, eax
    test ebx, ebx
    jnz 1f
    mov ebx, 1
1:  call agents_font_size
    mov ecx, eax
    mov eax, [rip + cfg_ui_font_size]
    imul eax, eax, 5
    xor edx, edx
    div ecx
    mov ecx, 5
    cmp eax, ecx
    cmova eax, ecx
    mov ecx, 2
    cmp eax, ecx
    cmovb eax, ecx
    cmp ebx, eax
    jbe 2f
    mov ebx, eax
2:  lea rdi, [rip + in_tf]
    call ta_line_h_of
    imul eax, ebx
    PM ecx, MI_12               # the text area's own padding is the interface's: never less
    cmp ecx, [rip + g_mt + 4*MI_12]
    jge 3f
    mov ecx, [rip + g_mt + 4*MI_12]
3:  add eax, ecx
    add eax, [rip + g_pmt + 4*MI_20]
    mov ebx, eax
    call below_h
    add eax, ebx
    EPILOGUE

# FN agentext_box_dump(sb): print-agents-box: for the open session (its mode label) at every panel size 8
#   to 32 and every panel width 240 to 900 in steps of 20, box_fit's layout, a line each: "size=S w=W
#   x=X box=B min=M btn_x=BX btn_w=BW below=0|1 h=H" (x the box's left, BX Send's, from the
#   panel's left; H the prompt row's height). The setting is the user's again after it
FN agentext_box_dump
    PROLOGUE 16
    mov rbx, rdi
    mov eax, [rip + cfg_agents_font_size]
    mov [rsp], eax
    call agents_open_driven
    mov r15, rax
    mov r12d, 8
1:  cmp r12d, 32
    ja 8f
    mov [rip + cfg_agents_font_size], r12d
    call agents_metrics
    mov r13d, 240
2:  cmp r13d, 900
    ja 7f
    mov edi, r13d
    mov rsi, r15
    call input_h
    mov r14d, eax
    mov rdi, rbx
    lea rsi, [rip + .Lbd_size]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_w]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r13d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_x]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + g_pmt + 4*MI_12]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_box]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + lay_box]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_min]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + lay_min]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_btn_x]
    call sb_push_cstr
    xor edi, edi
    call send_x
    mov esi, eax
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_btn_w]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + lay_btn]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_below]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + lay_below]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lbd_h]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r14d
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add r13d, 20
    jmp 2b
7:  inc r12d
    jmp 1b
8:  mov eax, [rsp]
    mov [rip + cfg_agents_font_size], eax
    call agents_metrics
    EPILOGUE

# FN agentext_placeholder_dump(sb): "placeholder=TEXT" as the box drew it last: cut with "…" at a
#   character's end when wider than the box (ui_textarea's room: MI_10 each side), "" before any box
FN agentext_placeholder_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_placeholder]
    call sb_push_cstr
    mov r12, [rip + ph_last]
    test r12, r12
    jz 8f
    mov rdi, r12
    call strlen
    mov r13, rax
    mov r14, [rip + in_tf + TF_face]
    test r14, r14
    jnz 1f
    lea r14, [rip + g_face_ui]
1:  mov r15d, [rip + ph_w]
    sub r15d, [rip + g_mt + 4*MI_10]
    sub r15d, [rip + g_mt + 4*MI_10]
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    call text_width
    cmp eax, r15d
    jle 7f
    mov rdi, r14
    lea rsi, [rip + ellipsis]
    mov edx, 3
    call text_width
    sub r15d, eax
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    mov ecx, r15d
    call text_fit
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call sb_push
    mov rdi, rbx
    lea rsi, [rip + ellipsis]
    mov edx, 3
    call sb_push
    jmp 8f
7:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
8:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# send_x(x) -> eax where Send starts for a panel whose left is x (box_fit's lay_*): right of the box, or
#   at the right end of the row under the box
send_x:
    lea eax, [rdi]
    add eax, [rip + g_pmt + 4*MI_12]
    add eax, [rip + lay_box]
    cmp dword ptr [rip + lay_below], 0
    jne 1f
    add eax, [rip + g_pmt + 4*MI_8]
    ret
1:  sub eax, [rip + lay_btn]
    ret

# FN agentext_send_at(w, AS* or 0) -> eax Send's x, edx its y, ecx its width, r8d its height (from the panel's
#   left and the prompt row's top), r9d the prompt row's height (input_h): what print-agents-foot checks the
#   footer against
FN agentext_send_at
    PROLOGUE
    call input_h
    mov r13d, eax
    xor edi, edi
    call send_x
    mov r14d, eax
    PM r15d, MI_10              # the box's top, and Send's when it is beside the box
    cmp dword ptr [rip + lay_below], 0
    je 1f
    call below_h                # under the box: below its bottom, MI_8 down
    mov ecx, r13d
    sub ecx, [rip + g_pmt + 4*MI_20]
    sub ecx, eax
    add r15d, ecx
    add r15d, [rip + g_pmt + 4*MI_8]
1:  mov eax, r14d
    mov edx, r15d
    mov ecx, [rip + lay_btn]
    PM r8d, MI_32
    mov r9d, r13d
    EPILOGUE

# FN agentext_bottom_draw(AS* or 0 for a new session, x, y, w, h): the card, then the prompt box with
#   Send, or Stop while the session works
FN agentext_bottom_draw
    PROLOGUE 64
    mov rbx, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    # the box belongs to the session shown
    cmp rbx, [rip + in_as]
    je 1f
    test rbx, rbx
    jz 1f
    mov [rip + in_as], rbx
    inc qword ptr [rip + in_gen]
    mov rdi, rbx                # the old owner keeps its text, the box takes this one's
    xor esi, esi
    call composer_owner
1:  mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    PM ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    mov eax, [rsp + 4]
    mov [rsp + 16], eax         # y cursor
    test rbx, rbx
    jz 3f
    mov rdi, rbx                # the box and its footer keep their room; the bands, then the card are cut
    mov esi, [rsp + 8]
    call box_keep
    mov ecx, [rsp + 12]
    sub ecx, eax
    mov [rsp + 20], ecx         # what the bands and the card may take
    mov rdi, rbx                # the bands
    mov esi, [rsp + 8]
    call bands_h
    cmp eax, [rsp + 20]
    jle 13f
    mov eax, [rsp + 20]
13: test eax, eax
    jle 14f
    mov [rsp + 44], eax
    mov edi, [rsp]
    mov esi, [rsp + 16]
    mov edx, [rsp + 8]
    mov ecx, eax
    call gfx_clip_push
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 8]
    call bands_draw
    call gfx_clip_pop
    mov eax, [rsp + 44]
    add [rsp + 16], eax
    sub [rsp + 20], eax
14: mov rdi, rbx                # the card
    mov esi, [rsp + 8]
    call any_card_h
    test eax, eax
    jz 2f
    cmp eax, [rsp + 20]
    jle 12f
    mov eax, [rsp + 20]
12: test eax, eax
    jg 15f
    mov rdi, rbx                # no room for it: not drawn, and no key answers it
    xor esi, esi
    call agentcard_room
    jmp 2f
15:
    mov [rsp + 20], eax
    mov edi, [rsp]
    mov esi, [rsp + 16]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 20]
    call gfx_clip_push
    mov rdi, rbx
    mov esi, [rsp]
    mov edx, [rsp + 16]
    mov ecx, [rsp + 8]
    mov r8d, [rsp + 20]
    call any_card_draw
    call gfx_clip_pop
    mov eax, [rsp + 20]
    add [rsp + 16], eax
2:  mov rdi, rbx
    call agent_drv_of
    test rax, rax
    jnz 3f
    mov rdi, rbx                # no box: in a remote window a Claude Code conversation says why
    call agentext_remote_line
    test eax, eax
    jz 9f
    lea rdi, [rip + .Lremote_line]
    call strlen
    mov r9, rax
    mov rdi, [rip + ag_fsmall]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_16]
    mov edx, [rsp + 16]
    PM ecx, MI_32
    lea r8, [rip + .Lremote_line]
    COLOR r10d, T_MUTED
    mov r11d, [rsp + 8]
    sub r11d, [rip + g_pmt + 4*MI_32]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    jmp 9f
3:  # the box (box_fit: Send beside it, or under it in a narrow panel), its frame in the mode's colour
    mov edi, [rsp + 8]
    mov rsi, rbx
    call input_h
    mov [rsp + 24], eax
    PM eax, MI_12
    mov ecx, [rsp]
    add ecx, eax
    mov [rsp + 28], ecx         # box x
    mov ecx, [rip + lay_box]
    mov [rsp + 32], ecx         # box w
    mov dword ptr [rip + in_tf + TF_id], ID_AI_CARD + 34
    mov rdi, rbx
    call foot_ring
    mov [rip + in_tf + TF_ring], eax
    mov edx, [rsp + 16]
    add edx, [rip + g_pmt + 4*MI_10]
    mov [rsp + 36], edx         # box y
    call below_h
    mov r8d, [rsp + 24]
    sub r8d, [rip + g_pmt + 4*MI_20]
    sub r8d, eax
    mov [rsp + 40], r8d         # box h
    mov edi, [rsp]
    call send_x
    mov [rsp + 52], eax         # Send's x
    mov eax, [rsp + 36]
    cmp dword ptr [rip + lay_below], 0
    je 31f
    add eax, [rsp + 40]
    add eax, [rip + g_pmt + 4*MI_8]
31: mov [rsp + 56], eax         # Send's y
    mov eax, [rip + lay_btn]
    mov [rsp + 60], eax         # its width
    mov rdi, rbx                # the placeholder: the composer's (a suggestion, a turn running, the first
    call composer_placeholder   #   use), else a new draft's, an extension's session's, or Claude Code's
    test rax, rax
    jnz 4f
    lea rax, [rip + .Lph_new]
    test rbx, rbx
    jz 4f
    lea rax, [rip + .Lph_reply]
    cmp dword ptr [rbx + AS_kind], AS_KIND_EXT
    je 4f
    lea rax, [rip + .Lph_claude]
4:  cmp qword ptr [rip + in_tf + TF_sb + SB_len], 0
    je 41f
    xor eax, eax                # none over text
41: mov [rip + ph_last], rax    # (print-agent-placeholder)
    mov ecx, [rsp + 32]
    mov [rip + ph_w], ecx
    lea rdi, [rip + in_tf]      # the word its driver paints (TF_paint)
    mov rsi, rbx
    call composer_paint
    mov rax, [rip + ph_last]
    push rax
    push rax
    lea rdi, [rip + in_tf]
    mov esi, [rsp + 16 + 28]
    mov edx, [rsp + 16 + 36]
    mov ecx, [rsp + 16 + 32]
    mov r8d, [rsp + 16 + 40]
    call box_focused
    mov r9d, eax
    lea rdi, [rip + in_tf]
    mov esi, [rsp + 16 + 28]
    mov edx, [rsp + 16 + 36]
    mov ecx, [rsp + 16 + 32]
    mov r8d, [rsp + 16 + 40]
    call ui_textarea
    add rsp, 16
    test eax, UB_PRESS | UB_HELD
    jz 5f
    test eax, UB_PRESS
    jz 52f
    mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
52: call agentext_box_changed   # the caret moved: the typed command menu follows it
5:  call agentext_box_owner     # a command's argument hint after "/NAME " (agentcompose.s)
    lea rdi, [rip + in_tf]
    mov esi, edx
    mov edx, [rsp + 28]
    mov ecx, [rsp + 36]
    mov r8d, [rsp + 32]
    mov r9d, [rsp + 40]
    call composer_hint_draw
    mov rdi, rbx                # the footer under the box
    mov esi, [rsp]
    mov edx, [rsp + 16]
    add edx, [rsp + 24]
    mov ecx, [rsp + 8]
    call foot_draw
    # Send, or Stop while it works (an icon when narrow: an arrow, a square)
    mov edi, ID_AI_CARD + 32
    lea r12, [rip + .Lb_send]
    test rbx, rbx
    jz 6f
    cmp dword ptr [rbx + AS_state], AGS_WORKING
    jne 6f
    mov edi, ID_AI_CARD + 33
    lea r12, [rip + .Lb_stop]
6:  mov [rsp + 44], edi
    mov esi, [rsp + 52]
    mov edx, [rsp + 56]
    mov ecx, [rsp + 60]
    PM r8d, MI_32
    mov r13d, esi
    call ui_btn
    mov r14d, eax
    COLOR r9d, T_ACCENT
    COLOR eax, T_ACCENT
    cmp dword ptr [rsp + 44], ID_AI_CARD + 33
    jne 7f
    COLOR r9d, T_BORDER
    COLOR eax, T_POPUP
    test r14d, UB_HOVER
    jz 7f
    COLOR eax, T_HOVER
7:  mov edi, r13d
    mov esi, [rsp + 56]
    mov edx, [rsp + 60]
    PM ecx, MI_32
    PM r8d, MI_RADIUS
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    COLOR eax, T_ACCENT_FG
    cmp dword ptr [rsp + 44], ID_AI_CARD + 33
    jne 71f
    COLOR eax, T_FG
71: mov ecx, [rsp + 60]
    cmp ecx, [rip + g_pmt + 4*MI_64]
    jl 72f
    mov rdi, [rip + ag_fui]
    mov esi, r13d
    mov edx, [rsp + 56]
    PM r8d, MI_32
    mov r9, r12
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    jmp 74f
72: mov r9d, eax                # an icon: Send's arrow, Stop's square (MI_ICON in the panel's size)
    PM ecx, MI_ICON
    mov esi, [rsp + 60]
    sub esi, ecx
    sar esi, 1
    add esi, r13d
    mov edx, [rsp + 60]         # the button is square
    sub edx, ecx
    sar edx, 1
    add edx, [rsp + 56]
    cmp dword ptr [rsp + 44], ID_AI_CARD + 33
    je 73f
    mov edi, IC_ARROW_UP
    mov r8d, r9d
    call icon_draw
    jmp 74f
73: mov edi, esi                # a square half the icon's size
    mov esi, edx
    mov eax, ecx
    shr eax, 2
    add edi, eax
    add esi, eax
    mov edx, ecx
    shr edx, 1
    mov ecx, edx
    mov r8d, r9d
    call gfx_fill
74: test r14d, UB_CLICK
    jz 9f
    cmp dword ptr [rsp + 44], ID_AI_CARD + 33
    je 8f
    call agentext_send
    jmp 9f
8:  mov rdi, rbx
    call agent_stop
9:  EPILOGUE

# card_draw(AS*, x, y, w, h): the card's prompt and its options as buttons (1 to 9 pick)
card_draw:
    PROLOGUE 48
    mov rbx, [rdi + AS_ask]
    mov r15, rdi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    mov [rsp + 12], r8d
    PM eax, MI_12
    mov edi, [rsp]
    add edi, eax
    mov esi, [rsp + 4]
    add esi, [rip + g_pmt + 4*MI_6]
    mov edx, [rsp + 8]
    sub edx, eax
    sub edx, eax
    mov ecx, [rsp + 12]
    sub ecx, [rip + g_pmt + 4*MI_8]
    PM r8d, MI_RADIUS
    COLOR r9d, T_ACCENT
    COLOR eax, T_PANEL
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    # the prompt, wrapped at words (CARD_LINES at most, the last cut with "…")
    mov r12, [rbx + AXK_prompt]
    mov rdi, r12
    call strlen
    mov r13, rax
    mov eax, [rsp + 8]
    sub eax, [rip + g_pmt + 4*MI_48]
    mov [rsp + 44], eax         # its width
    xor r14d, r14d              # the line
.Lcd_line:
    mov rdi, r12
    mov rsi, r13
    mov edx, [rsp + 44]
    call prompt_line
    lea ecx, [r14 + 1]
    cmp ecx, CARD_LINES
    jb 1f
    mov rax, r13                # the last line takes the rest
    mov rdx, r13
1:  mov [rsp + 32], rdx
    mov r9, rax
    mov rdi, [rip + ag_fui]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_24]
    mov edx, r14d
    imul edx, [rip + g_pmt + 4*MI_24]
    add edx, [rsp + 4]
    add edx, [rip + g_pmt + 4*MI_10]
    PM ecx, MI_24
    mov r8, r12
    COLOR r10d, T_FG
    mov r11d, [rsp + 44]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    mov rdx, [rsp + 32]
    add r12, rdx
    sub r13, rdx
    inc r14d
    test r13, r13
    jz 2f
    cmp r14d, CARD_LINES
    jb .Lcd_line
2:  lea eax, [r14 - 1]
    imul eax, [rip + g_pmt + 4*MI_24]
    mov [rsp + 44], eax         # the room the lines past the first take
    # the options, wrapping; scrolled by rows so the selected one shows in a card that is cut
    mov eax, [rsp + 12]
    sub eax, [rip + g_pmt + 4*MI_40]
    sub eax, [rip + g_pmt + 4*MI_12]
    sub eax, [rsp + 44]
    mov ecx, [rip + g_pmt + 4*MI_32]
    add ecx, [rip + g_pmt + 4*MI_6]
    mov [rsp + 32], ecx                # a row's height
    cdq
    idiv ecx
    cmp eax, 1
    jge 5f
    mov eax, 1
5:  mov [rsp + 28], eax                # rows that fit
    mov rdi, rbx
    mov esi, [rsp + 8]
    mov rdx, [rbx + AXK_sel]
    call opt_row
    sub eax, [rsp + 28]
    inc eax                            # the first row shown
    jge 6f
    xor eax, eax
6:  imul eax, [rsp + 32]
    mov r13d, [rsp + 4]
    add r13d, [rip + g_pmt + 4*MI_40]   # y
    add r13d, [rsp + 44]
    mov ecx, r13d
    mov [rsp + 36], ecx                # the options' top
    sub r13d, eax
    mov eax, [rsp + 4]
    add eax, [rsp + 12]
    sub eax, [rip + g_pmt + 4*MI_8]
    mov [rsp + 40], eax                # their bottom
    mov r12d, [rsp]
    add r12d, [rip + g_pmt + 4*MI_24]   # x
    mov eax, [rsp]
    add eax, [rsp + 8]
    sub eax, [rip + g_pmt + 4*MI_24]
    mov [rsp + 16], eax                # right
    xor r14d, r14d
.Lcd_opt:
    cmp r14, [rbx + AXK_opts + VEC_len]
    jae 9f
    mov rdi, rbx
    mov rsi, r14
    mov edx, [rsp + 16]
    sub edx, [rsp]
    sub edx, [rip + g_pmt + 4*MI_24]
    call opt_w
    mov [rsp + 20], eax
    mov ecx, [rsp]
    add ecx, [rip + g_pmt + 4*MI_24]
    cmp r12d, ecx
    je 1f
    lea ecx, [r12 + rax]
    cmp ecx, [rsp + 16]
    jle 1f
    mov r12d, [rsp]
    add r12d, [rip + g_pmt + 4*MI_24]
    add r13d, [rip + g_pmt + 4*MI_32]
    add r13d, [rip + g_pmt + 4*MI_6]
1:  cmp r13d, [rsp + 36]
    jl 4f                              # scrolled away
    mov eax, r13d
    add eax, [rip + g_pmt + 4*MI_32]
    cmp eax, [rsp + 40]
    jg 4f                              # past the cut
    lea edi, [r14 + ID_AI_CARD]
    mov esi, r12d
    mov edx, r13d
    mov ecx, [rsp + 20]
    PM r8d, MI_32
    call ui_btn
    mov [rsp + 24], eax
    mov edi, r12d
    mov esi, r13d
    mov edx, [rsp + 20]
    PM ecx, MI_32
    PM r8d, MI_RADIUS
    COLOR r9d, T_BORDER
    cmp qword ptr [rbx + AXK_kb], 0
    je 21f
    cmp r14, [rbx + AXK_sel]
    jne 21f
    COLOR r9d, T_ACCENT                # the option the arrow keys chose
21: COLOR eax, T_INPUT
    test dword ptr [rsp + 24], UB_HOVER
    jz 2f
    COLOR eax, T_HOVER
2:  push rax
    push rax
    call gfx_frame
    add rsp, 16
    # the key, then the text
    cmp r14, 9
    jae 3f
    lea eax, [r14 + '1']
    mov [rip + num], al
    mov rdi, [rip + ag_fsmall]
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_10]
    mov edx, r13d
    PM ecx, MI_32
    lea r8, [rip + num]
    mov r9d, 1
    COLOR eax, T_MUTED
    push rax
    push rax
    call ui_text_v
    add rsp, 16
3:  mov rax, [rbx + AXK_opts + VEC_ptr]
    mov r8, [rax + r14*8]
    mov rdi, r8
    push r8
    push r8
    call strlen
    mov r9, rax
    pop r8
    pop r8
    mov rdi, [rip + ag_fsmall]
    mov esi, r12d
    add esi, [rip + g_pmt + 4*MI_24]
    add esi, [rip + g_pmt + 4*MI_4]
    mov edx, r13d
    PM ecx, MI_32
    COLOR eax, T_FG
    mov r10d, [rsp + 20]
    sub r10d, [rip + g_pmt + 4*MI_24]
    sub r10d, [rip + g_pmt + 4*MI_12]
    push r10
    push rax
    call ui_text_v_fit
    add rsp, 16
    test dword ptr [rsp + 24], UB_CLICK
    jz 4f
    mov rdi, r15
    mov rsi, r14
    call agentext_pick
    jmp 9f
4:  add r12d, [rsp + 20]
    add r12d, [rip + g_pmt + 4*MI_6]
    inc r14
    jmp .Lcd_opt
9:  EPILOGUE

# FN agentext_new_draw(x, y, w, h): writing a new session: a header with Back, a line, the box
FN agentext_new_draw
    PROLOGUE 32
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    PM r12d, MI_28
    PM r15d, MI_40
    mov edi, ID_AI_CARD + 35
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, r15d
    sub edx, r12d
    sar edx, 1
    add edx, [rsp + 4]
    mov ecx, r12d
    mov r8d, r12d
    mov r9d, IC_BACK
    call ag_icon_btn
    test eax, UB_CLICK
    jz 1f
    call agentext_new_leave
    jmp 9f
1:  lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lnew_head]
    call sb_push_cstr
    mov rdi, [rip + new_ext]
    test rdi, rdi
    jz 11f
    call agentext_title
    jmp 12f
11: mov rdi, [rip + new_kind]   # a built-in driver's: its name
    call agent_drv_for_kind
    test rax, rax
    jz 12f
    mov rax, [rax + DRV_name]
12: lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lnew_tail]
    call sb_push_cstr
    mov rdi, [rip + ag_fui]
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_40]
    mov edx, [rsp + 4]
    mov ecx, r15d
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR r10d, T_FG
    mov r11d, [rsp + 8]
    sub r11d, [rip + g_pmt + 4*MI_64]
    push r11
    push r10
    call ui_text_v_fit
    add rsp, 16
    mov edi, [rsp]              # the line under the header
    mov esi, [rsp + 4]
    add esi, r15d
    dec esi
    mov edx, [rsp + 8]
    PM ecx, MI_1
    COLOR r8d, T_BORDER
    call gfx_fill
    mov rdi, [rip + ag_fsmall]   # what happens next
    mov esi, [rsp]
    add esi, [rip + g_pmt + 4*MI_16]
    mov edx, [rsp + 4]
    add edx, r15d
    add edx, [rip + g_pmt + 4*MI_8]
    PM ecx, MI_24
    lea r8, [rip + .Lnew_hint]
    COLOR r9d, T_MUTED
    call ui_text_c
    mov edi, [rsp + 8]
    xor esi, esi
    call input_h
    mov [rsp + 16], eax
    xor edi, edi                # and its footer (a built-in driver's draft has one)
    mov esi, [rsp + 8]
    call foot_h
    add [rsp + 16], eax
    mov r8d, [rsp + 16]         # the box at the bottom
    xor edi, edi                # no session yet
    mov esi, [rsp]
    mov edx, [rsp + 4]
    add edx, [rsp + 12]
    sub edx, r8d
    mov ecx, [rsp + 8]
    call agentext_bottom_draw
    cmp qword ptr [rip + new_kind], 0
    je 9f
    mov edi, [rsp]              # the command menu over the space above the box (agentpop.s)
    mov esi, [rsp + 4]
    add esi, [rsp + 12]
    sub esi, [rsp + 16]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    sub ecx, [rsp + 16]
    sub ecx, [rip + g_pmt + 4*MI_40]
    call agentpop_draw
9:  EPILOGUE

# FN agentext_list_buttons(right, y, h, left) -> eax the left edge: "+ TITLE" for each running extension
#   that takes prompts, right to left, then "+ Claude Code" when its driver is available (those that
#   would cross left are left out); a click starts a new session of it
FN agentext_list_buttons
    PROLOGUE 32
    mov r13d, edi
    mov [rsp], esi
    mov [rsp + 4], edx
    mov [rsp + 8], ecx
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rbx, r12, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r12
    mov rdi, rbx
    call prompts_ok
    test eax, eax
    jz 1b
    mov rdi, rbx
    call agentext_title
    lea edi, [r12 + ID_AI_CARD + 40 - 1]
    mov rsi, rax
    mov edx, r13d
    mov ecx, [rsp]
    mov r8d, [rsp + 4]
    mov r9d, [rsp + 8]
    call plus_btn
    mov r13d, eax
    test edx, edx
    jz 3f
    mov rdi, rbx
    call agentext_new
3:  sub r13d, [rip + g_pmt + 4*MI_4]
    jmp 1b
9:  mov edi, AG_CLAUDE          # the built-in driver, leftmost
    call agent_drv_for_kind
    test rax, rax
    jz 10f
    mov edi, ID_AI_CARD + 36
    mov rsi, [rax + DRV_name]
    mov edx, r13d
    mov ecx, [rsp]
    mov r8d, [rsp + 4]
    mov r9d, [rsp + 8]
    call plus_btn
    mov r13d, eax
    sub r13d, [rip + g_pmt + 4*MI_4]
    test edx, edx
    jz 10f
    mov edi, AG_CLAUDE
    call agentext_new_kind
10: mov eax, r13d
    EPILOGUE

# plus_btn(id, title cstr, right, y, h, left) -> eax its left edge, edx 1 when it was clicked: "+ TITLE"
#   ending at right; nothing (right and 0) when it would begin left of left
plus_btn:
    PROLOGUE 16
    mov [rsp], edi
    mov rbx, rsi
    mov r13d, edx
    mov [rsp + 4], ecx
    mov [rsp + 8], r8d
    mov [rsp + 12], r9d
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lplus_sp]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, rbx
    call sb_push_cstr
    mov rdi, [rip + ag_fsmall]
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    call text_width
    add eax, [rip + g_pmt + 4*MI_16]
    mov r14d, eax
    mov ecx, r13d
    sub ecx, eax
    cmp ecx, [rsp + 12]
    jge 1f
    mov eax, r13d               # no room
    xor edx, edx
    EPILOGUE
1:  mov r13d, ecx
    mov edi, [rsp]
    mov esi, r13d
    mov edx, [rsp + 4]
    mov ecx, r14d
    mov r8d, [rsp + 8]
    call ui_btn
    mov r15d, eax
    test r15d, UB_HOVER
    jz 2f
    mov edi, r13d
    mov esi, [rsp + 4]
    mov edx, r14d
    mov ecx, [rsp + 8]
    PM r8d, MI_RADIUS
    COLOR r9d, T_HOVER
    call gfx_round_rect
2:  mov rdi, [rip + ag_fsmall]
    mov esi, r13d
    add esi, [rip + g_pmt + 4*MI_8]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    mov r8, [rip + tmp + SB_ptr]
    mov r9, [rip + tmp + SB_len]
    COLOR eax, T_ACCENT
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    mov eax, r13d
    xor edx, edx
    test r15d, UB_CLICK
    setnz dl
    EPILOGUE

# FN agentext_input_dump(sb): "input=TEXT focus=0|1 new=OWNER/NAME|KIND|- pending=0|1 box=0|1", the
#   open card's "card=PROMPT options=A|B", and in a remote window "notice=TEXT" for a Claude Code
#   conversation (print-agent-input)
FN agentext_input_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ld_input]
    call sb_push_cstr
    lea rdi, [rip + in_tf]
    call tf_text
    mov rdi, rbx
    mov rsi, rax
    call sb_push
    mov rdi, rbx
    lea rsi, [rip + .Ld_focus]
    call sb_push_cstr
    xor esi, esi
    cmp dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    sete sil
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_new]
    call sb_push_cstr
    mov rdi, [rip + new_ext]
    lea rax, [rip + .Ldash]
    test rdi, rdi
    jz 1f
    call ext_qualified
    jmp 12f
1:  mov rdi, [rip + new_kind]   # a built-in driver's new conversation: its word (agent-new claude)
    test rdi, rdi
    jz 12f
    call agent_kind_name
12: mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_pending]
    call sb_push_cstr
    xor esi, esi
    cmp qword ptr [rip + pend_id], 0
    setne sil
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx                # box=1 when the draft or the open session has a driver
    lea rsi, [rip + .Ld_box]
    call sb_push_cstr
    call agentext_new_active
    mov esi, 1
    test rax, rax
    jnz 13f
    call agents_open_driven
    xor esi, esi
    test rax, rax
    setnz sil
13: mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    call agents_open_driven
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, rbx                # a rich card's line (agentcard.s), else the simple card's
    mov rsi, rax
    call agentcard_input_line
    test eax, eax
    jnz 9f
    mov r12, [r12 + AS_ask]
    test r12, r12
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + .Ld_card]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r12 + AXK_prompt]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_options]
    call sb_push_cstr
    xor r13d, r13d
1:  cmp r13, [r12 + AXK_opts + VEC_len]
    jae 2f
    test r13, r13
    jz 11f
    mov rdi, rbx
    mov esi, '|'
    call sb_push_byte
11: mov rax, [r12 + AXK_opts + VEC_ptr]
    mov rdi, rbx
    mov rsi, [rax + r13*8]
    call sb_push_cstr
    inc r13
    jmp 1b
2:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
9:  call agents_open_any        # the line a remote window shows instead of the box
    mov rdi, rax
    call agentext_remote_line
    test eax, eax
    jz 10f
    mov rdi, rbx
    lea rsi, [rip + .Ld_notice]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lremote_line]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
10: EPILOGUE

# FN agentext_prompts_gone(ext): an extension stopped: its prompt in flight and new session end
FN agentext_prompts_gone
    PROLOGUE
    mov rbx, rdi
    cmp [rip + pend_ext], rbx
    jne 1f
    mov qword ptr [rip + pend_ext], 0
    cmp qword ptr [rip + pend_id], 0
    je 1f
    mov qword ptr [rip + pend_id], 0
    lea rdi, [rip + .Lnot_running]
    call restore_pending
1:  cmp [rip + new_ext], rbx
    jne 2f
    mov qword ptr [rip + new_ext], 0
2:  cmp [rip + want_ext], rbx
    jne 3f
    call want_clear
3:  EPILOGUE

.section .rodata
.Lv_prompt: .asciz "agent-prompt "
.Lev_stop: .asciz "agent-stop "
.Ldash: .asciz "-"
.Lnot_running: .asciz "The agent's extension is not running"
.Lprompt_failed: .asciz "The agent refused the prompt: "
.Lprompt_long: .asciz "The prompt is longer than 64 KB"
.Lsend_refused: .asciz "Claude is still working. Stop it or wait for the reply."
.Lsend_full: .asciz "Four prompts are already waiting to be sent."
.Lnew_failed: .asciz "The new conversation could not be started."
.Lph_reply: .asciz "Reply to the agent (Enter sends, Shift+Enter a new line)"
.Lph_new: .asciz "Start a conversation"
# Claude chat phase 5: the extension's placeholder (e) once Ctrl+Esc (Cmd+Esc) exists (claudeterm.s)
.ifdef MACOS
.Lph_claude: .asciz "\xe2\x8c\x98 Esc to focus or unfocus Claude"
.else
.Lph_claude: .asciz "ctrl esc to focus or unfocus Claude"
.endif
.Ld_placeholder: .asciz "placeholder="
.Lb_send: .asciz "Send"
.Lrestore_gap: .asciz "\n\n"
.Lunsent_back: .asciz "A prompt that was not sent is back in the box."
.Lbd_size: .asciz "size="
.Lbd_w: .asciz " w="
.Lbd_x: .asciz " x="
.Lbd_box: .asciz " box="
.Lbd_min: .asciz " min="
.Lbd_btn_x: .asciz " btn_x="
.Lbd_btn_w: .asciz " btn_w="
.Lbd_below: .asciz " below="
.Lbd_h: .asciz " h="
.Lb_stop: .asciz "Stop"
.Lnew_head: .asciz "New "
.Lnew_tail: .asciz " session"
.Lnew_hint: .asciz "The agent starts a session with your first prompt."
.Lplus_sp: .asciz "+ "
.Ld_input: .asciz "input="
.Ld_focus: .asciz " focus="
.Ld_pending: .asciz " pending="
.Ld_new: .asciz " new="
.Ld_box: .asciz " box="
.Ld_card: .asciz "card="
.Ld_notice: .asciz "notice="
.globl agentext_remote_text
agentext_remote_text:
.Lremote_line: .asciz "Chat is not available in remote windows yet"
.Ld_options: .asciz " options="
.Le_cancelled: .asciz "cancelled"
.Le_card_syntax: .asciz "syntax a prompt line and 1 to 16 options, none empty"
.Le_card_toobig: .asciz "toobig more than 16 options"
.text
