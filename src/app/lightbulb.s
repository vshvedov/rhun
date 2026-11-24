# The lightbulb (language-features.md 1.7): after the cursor rests 250 ms on a line where a
# code-actions provider has diagnostics, rhun asks those providers for quick fixes (code-actions
# with TRIGGER auto, KINDS quickfix; silent, 1 s); when an enabled one comes, a bulb takes the
# gutter's left lane on the cursor's line (full when one is preferred, faint otherwise). Clicking it
# lists the quick fixes. Lines without such diagnostics cost nothing; [editor] lightbulb = no turns
# it off. Moving to another line or editing takes it away.
#
#   lightbulb_tick(), lightbulb_timeout() -> ms, lightbulb_reply(ext, id, ok, body, len) -> eax 1
#   when it answered the lightbulb's request, lightbulb_ext_gone(ext), lightbulb_dump(sb)
.include "rhun.inc"

.equ LB_REST, 250
.equ LB_REQS, 8

.bss
.p2align 3
lb_kind: .long 0                # its gutter kind, 0 before it is made
lb_count: .long 0               # enabled quick fixes that came
lb_pref: .long 0                # a preferred one among them
lb_shown: .long 0               # the bulb shows on lb_line
lb_doc: .quad 0                 # where the cursor rests: DOC*, id, version, position, since when
lb_docid: .quad 0
lb_version: .quad 0
lb_cur: .quad 0
lb_since: .quad 0
lb_asked: .quad 0               # 1: asked for this rest (lb_line)
lb_sig: .quad 0                 # the line's diagnostics then (line_sig)
lb_line: .quad 0
lb_reqs: .zero 16 * LB_REQS     # ext, id
lb_nreqs: .quad 0
lb_tip: .zero 64

.text

# clear(): the bulb goes, the requests are withdrawn
clear:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + lb_nreqs]
    jae 2f
    mov rax, rbx
    shl rax, 4
    lea rcx, [rip + lb_reqs]
    mov rdi, [rcx + rax]
    mov rsi, [rcx + rax + 8]
    call query_withdraw
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + lb_nreqs], 0
    cmp dword ptr [rip + lb_shown], 0
    je 3f
    mov dword ptr [rip + lb_shown], 0
    mov rdi, [rip + lb_docid]
    call extproto_doc
    cmp rax, [rip + lb_doc]
    jne 3f
    mov rdi, rax
    mov esi, [rip + lb_kind]
    mov rdx, [rip + lb_line]
    xor ecx, ecx
    call gutter_glyph_set
    mov dword ptr [rip + g_dirty], 1
3:  mov dword ptr [rip + lb_count], 0
    mov dword ptr [rip + lb_pref], 0
    EPILOGUE

# FN lightbulb_tick(): watch where the cursor rests; ask once it rested on a line with diagnostics
FN lightbulb_tick
    PROLOGUE
    cmp dword ptr [rip + cfg_lightbulb], 0
    je 7f
    call lf_focused_doc
    test rax, rax
    jz 9f                       # another part has the keyboard: the bulb stays as it is
    mov rbx, rax
    cmp rbx, [rip + lb_doc]
    jne 1f
    mov rax, [rbx + DOC_id]
    cmp rax, [rip + lb_docid]
    jne 1f
    mov rax, [rbx + DOC_version]
    cmp rax, [rip + lb_version]
    jne 1f
    mov rax, [rbx + DOC_cur]
    cmp rax, [rip + lb_cur]
    je 3f
    # the cursor moved on the line: the bulb stays, nothing more is asked
    mov rdi, rbx
    mov rsi, rax
    call doc_line_of
    cmp rax, [rip + lb_line]
    jne 1f
    mov rax, [rbx + DOC_cur]
    mov [rip + lb_cur], rax
    jmp 9f
1:  # somewhere else, or the text changed: a new rest
    call clear
    mov [rip + lb_doc], rbx
    mov rax, [rbx + DOC_id]
    mov [rip + lb_docid], rax
    mov rax, [rbx + DOC_version]
    mov [rip + lb_version], rax
    mov rax, [rbx + DOC_cur]
    mov [rip + lb_cur], rax
    mov rdi, rbx
    mov rsi, rax
    call doc_line_of
    mov [rip + lb_line], rax
    mov qword ptr [rip + lb_asked], 0
    call time_ms
    mov [rip + lb_since], rax
    jmp 9f
3:  cmp qword ptr [rip + lb_asked], 0
    je 31f
    mov rdi, rbx                # the line's diagnostics changed since (published later, cleared):
    call line_sig               # asked again
    cmp rax, [rip + lb_sig]
    je 9f
    call clear
    mov qword ptr [rip + lb_asked], 0
    mov dword ptr [rip + g_dirty], 1
    jmp 9f
31: call time_ms
    sub rax, [rip + lb_since]
    cmp rax, LB_REST
    jl 9f
    mov qword ptr [rip + lb_asked], 1
    mov rdi, rbx
    call line_sig
    mov [rip + lb_sig], rax
    mov rdi, rbx
    call ask
    jmp 9f
7:  call clear
9:  EPILOGUE

# ask(doc): the quick fixes, of each code-actions provider with diagnostics on the cursor's line
ask:
    PROLOGUE
    mov rbx, rdi
    cmp qword ptr [rbx + DOC_xmarks], 0
    je 9f
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul r13, r12, EXT_SIZE
    add r13, [rip + g_exts + VEC_ptr]
    inc r12
    cmp qword ptr [rip + lb_nreqs], LB_REQS
    jae 9f
    mov rdi, r13
    call ext_is_visible
    test eax, eax
    jz 1b
    cmp dword ptr [r13 + EXT_status], ES_RUNNING
    jne 1b
    mov rdi, r13
    mov esi, FEAT_CODE_ACTIONS
    call ext_feature
    test eax, eax
    jz 1b
    mov rdi, r13
    mov esi, EXT_pv_actions
    call ext_pv
    mov rdi, rax
    mov rsi, rbx
    call extproto_matches
    test eax, eax
    jz 1b
    mov rdi, r13
    mov rsi, rbx
    call has_marks
    test eax, eax
    jz 1b
    mov edi, 1
    call query_room
    test eax, eax
    jz 9f
    mov rdi, r13
    mov rsi, rbx
    call langfeat_actions_auto
    mov rcx, rdx
    mov rdx, rax
    mov rdi, r13
    mov rsi, rbx
    call extproto_host_send
    test rax, rax
    jz 1b
    mov r14, rax
    mov rdi, r13
    mov rsi, rax
    mov edx, PK_ACTIONS_AUTO
    mov ecx, QO_LANGFEAT
    call query_track
    mov rax, [rip + lb_nreqs]
    shl rax, 4
    lea rcx, [rip + lb_reqs]
    mov [rcx + rax], r13
    mov [rcx + rax + 8], r14
    inc qword ptr [rip + lb_nreqs]
    jmp 1b
9:  EPILOGUE

# has_marks(ext, doc) -> eax 1 when the extension has a diagnostic on the cursor's line
has_marks:
    PROLOGUE
    mov r14, rdi
    mov rbx, rsi
    xor r12d, r12d
1:  mov rcx, [rbx + DOC_xmarks]
    cmp r12, [rcx + VEC_len]
    jae 8f
    imul r13, r12, MK_SIZE
    add r13, [rcx + VEC_ptr]
    inc r12
    mov rdi, r14
    mov rsi, [r13 + MK_owner]
    call langfeat_mark_mine
    test eax, eax
    jz 1b
    mov rdi, rbx
    mov rsi, [r13 + MK_start]
    call doc_line_of
    cmp rax, [rip + lb_line]
    jne 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# line_sig(doc) -> rax a hash of the diagnostics on lb_line (their places, severities and owners;
# 0 for none): a change asks again
line_sig:
    PROLOGUE
    mov rbx, rdi
    xor r14d, r14d
    xor r12d, r12d
1:  mov rcx, [rbx + DOC_xmarks]
    test rcx, rcx
    jz 9f
    cmp r12, [rcx + VEC_len]
    jae 9f
    imul r13, r12, MK_SIZE
    add r13, [rcx + VEC_ptr]
    inc r12
    mov rdi, rbx
    mov rsi, [r13 + MK_start]
    call doc_line_of
    cmp rax, [rip + lb_line]
    jne 1b
    imul r14, r14, 1000003
    add r14, [r13 + MK_start]
    imul r14, r14, 1000003
    add r14, [r13 + MK_end]
    imul r14, r14, 1000003
    mov eax, [r13 + MK_sev]
    add r14, rax
    add r14, [r13 + MK_owner]
    inc r14
    jmp 1b
9:  mov rax, r14
    EPILOGUE

# FN lightbulb_reply(ext, id, ok, body, len) -> eax 1 when it answered one of the lightbulb's
# requests: its enabled quick fixes counted; the last answer shows the bulb
FN lightbulb_reply
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
    xor ecx, ecx
1:  cmp rcx, [rip + lb_nreqs]
    jae 8f
    mov rax, rcx
    shl rax, 4
    lea rdx, [rip + lb_reqs]
    add rax, rdx
    inc rcx
    cmp [rax], rbx
    jne 1b
    cmp [rax + 8], r12
    jne 1b
    mov rdx, [rip + lb_nreqs]   # its record goes (the last takes its place)
    dec rdx
    mov [rip + lb_nreqs], rdx
    shl rdx, 4
    lea rcx, [rip + lb_reqs]
    mov rsi, [rcx + rdx]
    mov [rax], rsi
    mov rsi, [rcx + rdx + 8]
    mov [rax + 8], rsi
    test r13d, r13d
    jz 2f
    mov rdi, r14
    mov rsi, r15
    call count_fixes
2:  cmp qword ptr [rip + lb_nreqs], 0
    jne 7f
    cmp dword ptr [rip + lb_count], 0
    je 7f
    mov rdi, [rip + lb_docid]
    call extproto_doc
    cmp rax, [rip + lb_doc]
    jne 7f
    mov rcx, [rax + DOC_version]
    cmp rcx, [rip + lb_version]
    jne 7f
    mov rbx, rax
    cmp dword ptr [rip + lb_kind], 0
    jne 3f
    mov edi, GK_PRIO_BULB
    xor esi, esi
    lea rdx, [rip + bulb_click]
    lea rcx, [rip + bulb_tip]
    xor r8d, r8d
    call gutter_kind
    mov [rip + lb_kind], eax
    test eax, eax
    jz 7f
3:  mov ecx, GS_BULB | (T_WARNING << 8)
    cmp dword ptr [rip + lb_pref], 0
    jne 4f
    or ecx, GF_FAINT << 16
4:  mov rdi, rbx
    mov esi, [rip + lb_kind]
    mov rdx, [rip + lb_line]
    call gutter_glyph_set
    mov dword ptr [rip + lb_shown], 1
7:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# count_fixes(body, len): lb_count += its enabled quickfix actions, lb_pref when one is preferred
# ("N", then KIND TITLE_LEN EDIT_LEN EXTRA_LEN LF and the bytes; extras "preferred 0", "disabled LEN")
count_fixes:
    PROLOGUE 16
    mov rdx, 1000
    call lf_head
    test rax, rax
    js 9f
    mov r15, rax
1:  test r15, r15
    jz 9f
    dec r15
    call ps_line
    test eax, eax
    jz 9f
    call ps_word                # KIND: quickfix, or below it
    mov r12, rax
    mov r13, rdx
    call ps_num                 # TITLE_LEN
    test edx, edx
    jz 9f
    mov rbx, rax
    call ps_num                 # EDIT_LEN
    test edx, edx
    jz 9f
    add rbx, rax
    call ps_num                 # EXTRA_LEN
    test edx, edx
    jz 9f
    mov r14, rax
    call ps_eol
    test eax, eax
    jz 9f
    mov rdi, rbx
    call lf_take
    test rax, rax
    jz 9f
    mov rdi, r14
    call lf_take
    test rax, rax
    jz 9f
    mov [rsp], rax
    # a quick fix?
    cmp r13, 8
    jb 1b
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lquickfix]
    mov ecx, 8
    call str_starts
    test eax, eax
    jz 1b
    cmp r13, 8
    je 2f
    cmp byte ptr [r12 + 8], '.'
    jne 1b
2:  # its extras: disabled ones do not count
    mov rdi, [rsp]
    mov rsi, r14
    lea rdx, [rip + .Ldisabled]
    call has_record
    test eax, eax
    jnz 1b
    inc dword ptr [rip + lb_count]
    mov rdi, [rsp]
    mov rsi, r14
    lea rdx, [rip + .Lpreferred]
    call has_record
    or [rip + lb_pref], eax
    jmp 1b
9:  EPILOGUE

# has_record(ptr, len, name cstr) -> eax 1 when the extra records hold one of that name (each "NAME
# ... LEN" LF + LEN bytes; read loosely: a record that breaks the grammar ends the search)
has_record:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rdi + rsi]
    mov r13, rdx
    mov rdi, r13
    call strlen
    mov r14, rax
1:  cmp rbx, r12
    jae 8f
    mov r15, rbx                # the header's end
2:  cmp r15, r12
    jae 8f
    cmp byte ptr [r15], 10
    je 3f
    inc r15
    jmp 2b
3:  mov rdi, rbx                # its name?
    mov rsi, r15
    sub rsi, rbx
    mov rdx, r13
    mov rcx, r14
    call str_starts
    test eax, eax
    jz 4f
    lea rax, [rbx + r14]
    cmp rax, r15
    je 7f
    cmp byte ptr [rax], ' '
    je 7f
4:  mov rcx, r15                # its last word: the length of its bytes
5:  cmp rcx, rbx
    je 8f
    cmp byte ptr [rcx - 1], ' '
    je 6f
    dec rcx
    jmp 5b
6:  mov rdi, rcx
    mov rsi, r15
    sub rsi, rcx
    call parse_u64
    lea rbx, [r15 + 1 + rax]
    jmp 1b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# bulb_click(doc, line, button, glyph): the quick fixes listed
bulb_click:
    cmp edx, BTN_LEFT
    jne 1f
    jmp cmd_quick_fix
1:  ret

# bulb_tip(doc, line, glyph) -> rax its tooltip
bulb_tip:
    PROLOGUE
    lea rdi, [rip + lb_tip]
    lea rsi, [rip + .Ltip]
    call cstr_copy
    mov rbx, rax
    mov edi, [rip + lb_count]
    lea rsi, [rip + lb_tip + 40]
    xchg rdi, rsi
    call fmt_u64
    lea rsi, [rip + lb_tip + 40]
    mov byte ptr [rsi + rax], 0
    mov rdi, rbx
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Ltip_end]
    call cstr_copy
    lea rax, [rip + lb_tip]
    EPILOGUE

# FN lightbulb_timeout() -> ms until the cursor's rest is due, or -1
FN lightbulb_timeout
    cmp qword ptr [rip + lb_asked], 0
    jne 8f
    cmp qword ptr [rip + lb_doc], 0
    je 8f
    cmp dword ptr [rip + cfg_lightbulb], 0
    je 8f
    push rbx
    call lf_focused_doc         # the keys elsewhere: the rest waits for them (lightbulb_tick does nothing
    cmp rax, [rip + lb_doc]     #   until then; a deadline passed meanwhile would wake the loop on every pass)
    jne 7f
    call time_ms
    mov rcx, [rip + lb_since]
    add rcx, LB_REST
    sub rcx, rax
    jns 1f
    xor ecx, ecx
1:  mov eax, ecx
    pop rbx
    ret
7:  pop rbx
8:  mov eax, -1
    ret

# FN lightbulb_ext_gone(ext): its request is not waited for
FN lightbulb_ext_gone
    xor ecx, ecx
1:  cmp rcx, [rip + lb_nreqs]
    jae 9f
    mov rax, rcx
    shl rax, 4
    lea rdx, [rip + lb_reqs]
    add rax, rdx
    cmp [rax], rdi
    je 2f
    inc rcx
    jmp 1b
2:  mov rdx, [rip + lb_nreqs]
    dec rdx
    mov [rip + lb_nreqs], rdx
    shl rdx, 4
    lea r8, [rip + lb_reqs]
    mov rsi, [r8 + rdx]
    mov [rax], rsi
    mov rsi, [r8 + rdx + 8]
    mov [rax + 8], rsi
    jmp 1b
9:  ret

# FN lightbulb_dump(sb): print-lightbulb: "lightbulb=none", "lightbulb=asking line=L" or
# "lightbulb line=L count=N preferred=P"
FN lightbulb_dump
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rip + lb_shown], 0
    jne 2f
    cmp qword ptr [rip + lb_nreqs], 0
    jne 1f
    mov rdi, rbx
    lea rsi, [rip + .Ld_none]
    call sb_push_cstr
    EPILOGUE
1:  mov rdi, rbx
    lea rsi, [rip + .Ld_asking]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + lb_line]
    inc rsi
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE
2:  mov rdi, rbx
    lea rsi, [rip + .Ld_line]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + lb_line]
    inc rsi
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_count]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + lb_count]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_pref]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [rip + lb_pref]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.section .rodata
.Lquickfix: .ascii "quickfix"
.Ldisabled: .asciz "disabled"
.Lpreferred: .asciz "preferred"
.Ltip: .asciz "Quick fixes ("
.Ltip_end: .asciz ")"
.Ld_none: .asciz "lightbulb=none\n"
.Ld_asking: .asciz "lightbulb=asking line="
.Ld_line: .asciz "lightbulb line="
.Ld_count: .asciz " count="
.Ld_pref: .asciz " preferred="
