# when clauses and context keys (docs/extensions/v1.1.md, "When clauses"): a small expression
# language over context keys that decides whether menu items, key bindings, status items and view
# actions apply. A clause compiles once into postfix operations; evaluating it reads the keys it
# names. Built-in keys come from rhun's state (the CTXKEY_LIST in rhun.inc), other parts publish
# theirs with ctx_set, extensions set their own (extcontext.s).
#
# For other parts of rhun:
#   when_compile(ptr, len, ext) -> WC* (owned) or 0 with edx the error's byte, rcx its text
#   when_eval(wc) -> eax 1/0         reads the keys afresh (ctx_refresh first)
#   when_eval_fresh(wc) -> eax       for a batch after one ctx_refresh (a menu, a key)
#   when_free(wc), when_source(wc) -> rax ptr, rdx len
#   ctx_refresh()                    rhun's state may have changed: keys are read again
#   ctx_set(id, ptr, len), ctx_set_bool(id, 0|1)   a published key's value (CTX_*)
#   ctx_get(id) -> rax ptr, rdx len  a key's value
#   ctx_push_target(MTG*) / ctx_pop_target()        a menu's target for resource/editor keys
#
# Grammar (WHEN_MAX bytes, WHEN_OPS_MAX operations, WHEN_DEPTH_MAX levels of ! and parentheses):
#   or = and *("||" and); and = unary *("&&" unary); unary = "!" unary / "(" or ")" / true /
#   false / test; test = key [cmp value / "=~" value / in list / not in list] / quoted (in /
#   not in) list; cmp = == != <= >= < >; value = quoted / bare (always a literal); list = key /
#   quoted (space-separated words). Keys: built-in names, config.SECTION.KEY, NAME.KEY and
#   OWNER/NAME.KEY (an extension's), NAME.setting.KEY (its setting).
.include "rhun.inc"

# compiled clause: header, then ops (8 bytes: op, arg), key references, literals (offset, length
# into the text), the literals' bytes and the source
.equ WC_nops, 0
.equ WC_nkeys, 4
.equ WC_nlits, 8
.equ WC_srclen, 12
.equ WC_ext, 16
.equ WC_keys, 24                # offsets from the record's start
.equ WC_lits, 28
.equ WC_text, 32
.equ WC_src, 36
.equ WC_OPS, 48
# key reference
.equ KR_kind, 0
.equ KR_a, 4                    # built-in: id; extension keys: literal of the extension's name
.equ KR_b, 8                    # extension keys: literal of the local key or the setting
.equ KR_ptr, 16                 # SET* (config), EXT* (own keys)
.equ KR_SIZE, 24
.equ KR_BUILTIN, 1
.equ KR_CONFIG, 2
.equ KR_EXT, 3
.equ KR_EXT_OWN, 4
.equ KR_EXTSET, 5
.equ KR_EXTSET_OWN, 6
# operations
.equ OP_KEY, 1
.equ OP_LIT, 2
.equ OP_TRUE, 3
.equ OP_FALSE, 4
.equ OP_NOT, 5
.equ OP_AND, 6
.equ OP_OR, 7
.equ OP_EQ, 8
.equ OP_NE, 9
.equ OP_LT, 10
.equ OP_LE, 11
.equ OP_GT, 12
.equ OP_GE, 13
.equ OP_GLOB, 14
.equ OP_IN, 15
.equ OP_NIN, 16
.equ EVAL_STACK, 64

.data
ctx_focus_over: .long -1        # ctx_focus_as

.bss
.p2align 3
ctx_vals: .zero CTX_COUNT * 16  # (ptr, len) of each key, valid in round ctx_stamp
ctx_stamp: .zero CTX_COUNT * 4
ctx_round: .long 0
ctx_inited: .long 0
.p2align 3
ctx_idx: .zero CTX_COUNT * 16   # per key: its name, its FN (0: published) (ctx_init)
ctx_publen: .zero CTX_COUNT * 4
ctx_pub: .zero CTX_COUNT * CTX_VAL_MAX   # published values (keys without a FN)
ctx_num: .zero CTX_COUNT * 24   # numbers formatted for a key
ctx_lang: .zero 128             # resourceLang, spaces as _
ctx_prov: .zero 512             # editorProviders
.p2align 3
ctx_target: .quad 0             # MTG* a menu pushed, or 0
ctx_targets: .zero 8 * 8        # targets pushed before the current one (ctx_push_target)
ctx_ntargets: .quad 0
.globl g_wayland
g_wayland: .long 0              # the Wayland client runs (wayland.s sets it)
# the compiler's state
.p2align 3
wc_beg: .quad 0
wc_p: .quad 0
wc_end: .quad 0
wc_owner: .quad 0
wc_nops: .quad 0
wc_nkeys: .quad 0
wc_nlits: .quad 0
wc_ntext: .quad 0
wc_depth: .quad 0
wc_failed: .quad 0
wc_err_at: .quad 0
wc_ops: .zero WHEN_OPS_MAX * 8
wc_keys: .zero WHEN_OPS_MAX * KR_SIZE
wc_lits: .zero WHEN_OPS_MAX * 8
wc_text: .zero WHEN_MAX
wc_msg: .zero 192
# the evaluator's stack and number scratch
ev_stack: .zero EVAL_STACK * 16
ev_num: .zero 16 * 24
ev_numi: .quad 0
ctl_sb: .zero SB_SIZE

.text

# ---------------------------------------------------------------- compiling

# FN when_compile(ptr, len, ext) -> rax an owned WC, or 0 with edx the byte offset of the error
# and rcx its text (a static cstr). ext is the extension whose manifest has the clause (its own
# NAME.KEY), or 0.
FN when_compile
    PROLOGUE 16
    mov [rip + wc_beg], rdi
    mov [rip + wc_p], rdi
    lea rax, [rdi + rsi]
    mov [rip + wc_end], rax
    mov [rip + wc_owner], rdx
    xor eax, eax
    mov [rip + wc_nops], rax
    mov [rip + wc_nkeys], rax
    mov [rip + wc_nlits], rax
    mov [rip + wc_ntext], rax
    mov [rip + wc_depth], rax
    mov [rip + wc_failed], rax
    mov [rsp], rsi
    cmp rsi, WHEN_MAX
    jbe 1f
    mov edi, WHEN_MAX
    lea rsi, [rip + .Le_long]
    call wc_fail_at
    jmp .Lwc_failed
1:  call wc_ws
    mov rax, [rip + wc_p]
    cmp rax, [rip + wc_end]
    jb 2f
    xor edi, edi
    lea rsi, [rip + .Le_empty]
    call wc_fail_at
    jmp .Lwc_failed
2:  call p_or
    cmp qword ptr [rip + wc_failed], 0
    jne .Lwc_failed
    call wc_ws
    mov rax, [rip + wc_p]
    cmp rax, [rip + wc_end]
    jae 3f
    lea rsi, [rip + .Le_unexpected]
    call wc_fail
    jmp .Lwc_failed
3:  # the record: header, ops, keys, literals, text, source
    mov rbx, [rip + wc_nops]
    shl rbx, 3
    add rbx, WC_OPS
    mov r12, rbx                # keys' offset
    mov rax, [rip + wc_nkeys]
    imul rax, rax, KR_SIZE
    add rbx, rax
    mov r13, rbx                # literals'
    mov rax, [rip + wc_nlits]
    lea rbx, [rbx + rax*8]
    mov r14, rbx                # text's
    add rbx, [rip + wc_ntext]
    mov r15, rbx                # source's
    add rbx, [rsp]
    lea rdi, [rbx + 1]
    call mem_alloc
    mov rbx, rax
    mov rax, [rip + wc_nops]
    mov [rbx + WC_nops], eax
    mov rax, [rip + wc_nkeys]
    mov [rbx + WC_nkeys], eax
    mov rax, [rip + wc_nlits]
    mov [rbx + WC_nlits], eax
    mov rax, [rsp]
    mov [rbx + WC_srclen], eax
    mov rax, [rip + wc_owner]
    mov [rbx + WC_ext], rax
    mov [rbx + WC_keys], r12d
    mov [rbx + WC_lits], r13d
    mov [rbx + WC_text], r14d
    mov [rbx + WC_src], r15d
    lea rdi, [rbx + WC_OPS]
    lea rsi, [rip + wc_ops]
    mov rdx, [rip + wc_nops]
    shl rdx, 3
    call memcpy
    lea rdi, [rbx + r12]
    lea rsi, [rip + wc_keys]
    mov rdx, [rip + wc_nkeys]
    imul rdx, rdx, KR_SIZE
    call memcpy
    lea rdi, [rbx + r13]
    lea rsi, [rip + wc_lits]
    mov rdx, [rip + wc_nlits]
    shl rdx, 3
    call memcpy
    lea rdi, [rbx + r14]
    lea rsi, [rip + wc_text]
    mov rdx, [rip + wc_ntext]
    call memcpy
    lea rdi, [rbx + r15]
    mov rsi, [rip + wc_beg]
    mov rdx, [rsp]
    call memcpy
    mov rax, [rsp]
    add rax, r15
    mov byte ptr [rbx + rax], 0
    mov rax, rbx
    xor edx, edx
    xor ecx, ecx
    EPILOGUE
.Lwc_failed:
    xor eax, eax
    mov rdx, [rip + wc_err_at]
    lea rcx, [rip + wc_msg]
    EPILOGUE

# FN when_free(wc)
FN when_free
    test rdi, rdi
    jz 1f
    jmp mem_free
1:  ret

# FN when_source(wc) -> rax ptr, rdx len of the clause as written
FN when_source
    mov eax, [rdi + WC_src]
    add rax, rdi
    mov edx, [rdi + WC_srclen]
    ret

# wc_fail(msg cstr): the error at the current position (the first one counts)
wc_fail:
    mov rdi, [rip + wc_p]
    sub rdi, [rip + wc_beg]
# wc_fail_at(offset, msg cstr)
wc_fail_at:
    cmp qword ptr [rip + wc_failed], 0
    jne 9f
    mov qword ptr [rip + wc_failed], 1
    mov [rip + wc_err_at], rdi
    push rbx
    lea rdi, [rip + wc_msg]
    call cstr_copy
    pop rbx
9:  ret

# wc_fail_word(msg cstr, ptr, len): "msg WORD" (the word cut at 60 bytes) at ptr
wc_fail_word:
    cmp qword ptr [rip + wc_failed], 0
    jne 9f
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    mov rbx, rdi
    mov qword ptr [rip + wc_failed], 1
    mov rax, r12
    sub rax, [rip + wc_beg]
    mov [rip + wc_err_at], rax
    lea rdi, [rip + wc_msg]
    mov rsi, rbx
    call cstr_copy
    cmp r13, 60
    jbe 1f
    mov r13d, 60
1:  mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    push rdi
    push rdi
    call memcpy
    pop rdi
    pop rdi
    mov byte ptr [rdi + r13], 0
    EPILOGUE
9:  ret

# wc_ws(): past spaces and tabs
wc_ws:
    mov rax, [rip + wc_p]
    mov rcx, [rip + wc_end]
1:  cmp rax, rcx
    jae 2f
    cmp byte ptr [rax], ' '
    je 3f
    cmp byte ptr [rax], 9
    jne 2f
3:  inc rax
    jmp 1b
2:  mov [rip + wc_p], rax
    ret

# wc_peek2() -> eax the byte at wc_p (0 at the end), edx the one after it
wc_peek2:
    mov rcx, [rip + wc_p]
    xor eax, eax
    xor edx, edx
    cmp rcx, [rip + wc_end]
    jae 9f
    movzx eax, byte ptr [rcx]
    inc rcx
    cmp rcx, [rip + wc_end]
    jae 9f
    movzx edx, byte ptr [rcx]
9:  ret

# wc_emit(op, arg): one more operation
wc_emit:
    mov rax, [rip + wc_nops]
    cmp rax, WHEN_OPS_MAX
    jae 8f
    lea rcx, [rip + wc_ops]
    mov [rcx + rax*8], edi
    mov [rcx + rax*8 + 4], esi
    inc qword ptr [rip + wc_nops]
    ret
8:  lea rsi, [rip + .Le_ops]
    jmp wc_fail

# wc_literal(ptr, len) -> eax the literal's index (its bytes copied)
wc_literal:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rax, [rip + wc_nlits]
    cmp rax, WHEN_OPS_MAX
    jae 8f
    mov rbx, rax
    lea rcx, [rip + wc_lits]
    mov rdx, [rip + wc_ntext]
    mov [rcx + rbx*8], edx
    mov [rcx + rbx*8 + 4], r13d
    lea rdi, [rip + wc_text]
    add rdi, rdx
    mov rsi, r12
    mov rdx, r13
    call memcpy
    add [rip + wc_ntext], r13
    inc qword ptr [rip + wc_nlits]
    mov eax, ebx
    EPILOGUE
8:  lea rsi, [rip + .Le_ops]
    call wc_fail
    xor eax, eax
    EPILOGUE

# wc_keyref() -> rax the next key reference (zeroed), or 0 after failing
wc_keyref:
    mov rax, [rip + wc_nkeys]
    cmp rax, WHEN_OPS_MAX
    jae 8f
    imul rax, rax, KR_SIZE
    lea rcx, [rip + wc_keys]
    add rax, rcx
    xor ecx, ecx
    mov [rax], rcx
    mov [rax + 8], rcx
    mov [rax + 16], rcx
    inc qword ptr [rip + wc_nkeys]
    ret
8:  lea rsi, [rip + .Le_ops]
    call wc_fail
    xor eax, eax
    ret

# p_or(): and *("||" and)
p_or:
    call p_and
1:  cmp qword ptr [rip + wc_failed], 0
    jne 9f
    call wc_ws
    call wc_peek2
    cmp eax, '|'
    jne 9f
    cmp edx, '|'
    jne 9f
    add qword ptr [rip + wc_p], 2
    call p_and
    mov edi, OP_OR
    xor esi, esi
    call wc_emit
    jmp 1b
9:  ret

# p_and(): unary *("&&" unary)
p_and:
    call p_unary
1:  cmp qword ptr [rip + wc_failed], 0
    jne 9f
    call wc_ws
    call wc_peek2
    cmp eax, '&'
    jne 9f
    cmp edx, '&'
    jne 9f
    add qword ptr [rip + wc_p], 2
    call p_unary
    mov edi, OP_AND
    xor esi, esi
    call wc_emit
    jmp 1b
9:  ret

# p_unary(): "!" unary / "(" or ")" / true / false / test
p_unary:
    PROLOGUE
    cmp qword ptr [rip + wc_failed], 0
    jne 9f
    call wc_ws
    call wc_peek2
    cmp eax, '!'
    jne 2f
    cmp edx, '='
    je .Lpu_bad
    inc qword ptr [rip + wc_p]
    call wc_deeper
    jz 9f
    call p_unary
    dec qword ptr [rip + wc_depth]
    mov edi, OP_NOT
    xor esi, esi
    call wc_emit
    jmp 9f
2:  cmp eax, '('
    jne 3f
    inc qword ptr [rip + wc_p]
    call wc_deeper
    jz 9f
    call p_or
    cmp qword ptr [rip + wc_failed], 0
    jne 9f
    dec qword ptr [rip + wc_depth]
    call wc_ws
    call wc_peek2
    cmp eax, ')'
    jne .Lpu_close
    inc qword ptr [rip + wc_p]
    jmp 9f
3:  cmp eax, 39
    je .Lpu_quoted
    cmp eax, '"'
    je .Lpu_quoted
    call wc_word
    test rdx, rdx
    jz .Lpu_bad
    mov r12, rax
    mov r13, rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lw_true]
    call str_eq_cstr
    test eax, eax
    jz 4f
    mov edi, OP_TRUE
    xor esi, esi
    call wc_emit
    jmp 9f
4:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lw_false]
    call str_eq_cstr
    test eax, eax
    jz 5f
    mov edi, OP_FALSE
    xor esi, esi
    call wc_emit
    jmp 9f
5:  mov rdi, r12
    mov rsi, r13
    call wc_key
    cmp qword ptr [rip + wc_failed], 0
    jne 9f
    call p_tail
    jmp 9f
.Lpu_quoted:
    # a quoted literal on the left: in / not in a list
    call wc_quoted
    cmp qword ptr [rip + wc_failed], 0
    jne 9f
    mov rdi, rax
    mov rsi, rdx
    call wc_literal
    mov esi, eax
    mov edi, OP_LIT
    call wc_emit
    call wc_ws
    call wc_in_word
    test eax, eax
    jz .Lpu_need_in
    mov r12d, eax
    call p_list
    mov edi, r12d
    xor esi, esi
    call wc_emit
    jmp 9f
.Lpu_need_in:
    lea rsi, [rip + .Le_need_in]
    call wc_fail
    jmp 9f
.Lpu_close:
    lea rsi, [rip + .Le_close]
    call wc_fail
    jmp 9f
.Lpu_bad:
    lea rsi, [rip + .Le_expected]
    call wc_fail
9:  EPILOGUE

# wc_deeper() -> ZF clear when one more level is allowed (it is counted), set after failing
wc_deeper:
    inc qword ptr [rip + wc_depth]
    cmp qword ptr [rip + wc_depth], WHEN_DEPTH_MAX
    ja 8f
    or eax, 1
    ret
8:  lea rsi, [rip + .Le_deep]
    call wc_fail
    xor eax, eax
    ret

# p_tail(): after a key: [cmp value / "=~" value / in list / not in list]
p_tail:
    PROLOGUE
    call wc_ws
    call wc_peek2
    xor ebx, ebx
    cmp eax, '='
    jne 1f
    mov ebx, OP_EQ
    cmp edx, '='
    je 2f
    mov ebx, OP_GLOB
    cmp edx, '~'
    je 2f
    jmp .Lpt_bad
1:  cmp eax, '!'
    jne 11f
    cmp edx, '='
    jne .Lpt_bad
    mov ebx, OP_NE
    jmp 2f
11: cmp eax, '<'
    jne 12f
    mov ebx, OP_LE
    cmp edx, '='
    je 2f
    mov ebx, OP_LT
    jmp 3f
12: cmp eax, '>'
    jne 13f
    mov ebx, OP_GE
    cmp edx, '='
    je 2f
    mov ebx, OP_GT
    jmp 3f
13: # in / not in, or nothing
    call wc_in_word
    test eax, eax
    jz 9f
    mov ebx, eax
    call p_list
    jmp .Lpt_emit
2:  inc qword ptr [rip + wc_p]   # two-byte operators
3:  inc qword ptr [rip + wc_p]
    call p_value
.Lpt_emit:
    mov edi, ebx
    xor esi, esi
    call wc_emit
9:  EPILOGUE
.Lpt_bad:
    lea rsi, [rip + .Le_operator]
    call wc_fail
    EPILOGUE

# wc_in_word() -> eax OP_IN or OP_NIN when "in" or "not in" follows (moving past it), else 0
wc_in_word:
    PROLOGUE
    mov rbx, [rip + wc_p]
    call wc_word
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lw_in]
    call str_eq_cstr
    test eax, eax
    jz 1f
    mov eax, OP_IN
    EPILOGUE
1:  mov rax, [rip + wc_p]
    sub rax, rbx
    cmp rax, 3
    jne 8f
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lw_not]
    call str_eq_cstr
    test eax, eax
    jz 8f
    call wc_ws
    mov r12, [rip + wc_p]
    call wc_word
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lw_in]
    call str_eq_cstr
    test eax, eax
    jz 7f
    mov eax, OP_NIN
    EPILOGUE
7:  mov [rip + wc_p], r12
    lea rsi, [rip + .Le_need_in]
    call wc_fail
    xor eax, eax
    EPILOGUE
8:  mov [rip + wc_p], rbx
    xor eax, eax
    EPILOGUE

# p_value(): a quoted or bare literal
p_value:
    PROLOGUE
    call wc_ws
    call wc_peek2
    cmp eax, 39
    je 1f
    cmp eax, '"'
    je 1f
    call wc_bare
    test rdx, rdx
    jz 8f
    jmp 2f
1:  call wc_quoted
    cmp qword ptr [rip + wc_failed], 0
    jne 9f
2:  mov rdi, rax
    mov rsi, rdx
    call wc_literal
    mov esi, eax
    mov edi, OP_LIT
    call wc_emit
9:  EPILOGUE
8:  lea rsi, [rip + .Le_value]
    call wc_fail
    EPILOGUE

# p_list(): a key or a quoted literal (space-separated words)
p_list:
    PROLOGUE
    call wc_ws
    call wc_peek2
    cmp eax, 39
    je 1f
    cmp eax, '"'
    je 1f
    call wc_word
    test rdx, rdx
    jz 8f
    mov rdi, rax
    mov rsi, rdx
    call wc_key
    EPILOGUE
1:  call wc_quoted
    cmp qword ptr [rip + wc_failed], 0
    jne 9f
    mov rdi, rax
    mov rsi, rdx
    call wc_literal
    mov esi, eax
    mov edi, OP_LIT
    call wc_emit
9:  EPILOGUE
8:  lea rsi, [rip + .Le_list]
    call wc_fail
    EPILOGUE

# wc_word() -> rax ptr, rdx len of a key-like word ([A-Za-z0-9_./-]) at wc_p, moving past it
wc_word:
    mov rax, [rip + wc_p]
    mov rcx, rax
    mov r8, [rip + wc_end]
1:  cmp rcx, r8
    jae 2f
    movzx edx, byte ptr [rcx]
    cmp dl, '_'
    je 3f
    cmp dl, '.'
    je 3f
    cmp dl, '/'
    je 3f
    cmp dl, '-'
    je 3f
    lea r9d, [rdx - '0']
    cmp r9d, 9
    jbe 3f
    or dl, 0x20
    lea r9d, [rdx - 'a']
    cmp r9d, 25
    ja 2f
3:  inc rcx
    jmp 1b
2:  mov [rip + wc_p], rcx
    mov rdx, rcx
    sub rdx, rax
    ret

# wc_bare() -> rax ptr, rdx len of a bare value at wc_p, moving past it
wc_bare:
    mov rax, [rip + wc_p]
    mov rcx, rax
    mov r8, [rip + wc_end]
1:  cmp rcx, r8
    jae 2f
    movzx edx, byte ptr [rcx]
    lea r9, [rip + .Lbare_extra]
3:  movzx r10d, byte ptr [r9]
    test r10d, r10d
    jz 4f
    inc r9
    cmp edx, r10d
    jne 3b
    jmp 5f
4:  lea r9d, [rdx - '0']
    cmp r9d, 9
    jbe 5f
    or dl, 0x20
    lea r9d, [rdx - 'a']
    cmp r9d, 25
    ja 2f
5:  inc rcx
    jmp 1b
2:  mov [rip + wc_p], rcx
    mov rdx, rcx
    sub rdx, rax
    ret

# wc_quoted() -> rax ptr, rdx len inside the quotes at wc_p, moving past them (fails when unclosed
# or holding a control byte)
wc_quoted:
    mov rcx, [rip + wc_p]
    movzx r8d, byte ptr [rcx]
    inc rcx
    mov rax, rcx
1:  cmp rcx, [rip + wc_end]
    jae 8f
    movzx edx, byte ptr [rcx]
    cmp edx, r8d
    je 2f
    cmp edx, 0x20
    jb 8f
    cmp edx, 0x7f
    je 8f
    inc rcx
    jmp 1b
2:  lea r8, [rcx + 1]
    mov [rip + wc_p], r8
    mov rdx, rcx
    sub rdx, rax
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    call snippet_utf8_valid
    test eax, eax
    pop rdx
    pop rax
    jz 7f
    ret
7:  dec rax                     # reported at the opening quote
    mov [rip + wc_p], rax
    lea rsi, [rip + .Le_utf8]
    jmp wc_fail
8:  lea rsi, [rip + .Le_quote]
    jmp wc_fail

# wc_key(ptr, len): the key's reference and OP_KEY, or a failure naming it
wc_key:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    # config.SECTION.KEY
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lconfig_dot]
    mov ecx, 7
    call str_starts
    test eax, eax
    jz 2f
    lea r14, [r12 + 7]          # SECTION.KEY
    lea r15, [r13 - 7]
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Ldot]
    mov ecx, 1
    call str_find
    test rax, rax
    jle .Lwk_unknown
    mov rdi, r14
    mov rsi, rax
    lea rdx, [r14 + rax + 1]
    mov rcx, r15
    sub rcx, rax
    dec rcx
    jz .Lwk_unknown
    call setting_find
    test rax, rax
    jz .Lwk_unknown
    mov rbx, rax
    call wc_keyref
    test rax, rax
    jz 9f
    mov dword ptr [rax + KR_kind], KR_CONFIG
    mov [rax + KR_ptr], rbx
    jmp .Lwk_emit
2:  # an extension's: NAME.KEY, OWNER/NAME.KEY, NAME.setting.KEY
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Ldot]
    mov ecx, 1
    call str_find
    test rax, rax
    js .Lwk_builtin
    jz .Lwk_unknown
    mov [rsp], rax              # the extension name's length
    lea r14, [r12 + rax + 1]    # after the dot
    lea r15, [r13 - 1]
    sub r15, rax
    jz .Lwk_unknown
    # NAME.setting.KEY
    mov ebx, KR_EXT
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lsetting_dot]
    mov ecx, 8
    call str_starts
    test eax, eax
    jz 3f
    add r14, 8
    sub r15, 8
    jz .Lwk_unknown
    mov ebx, KR_EXTSET
    mov rdi, r14
    mov rsi, r15
    call xc_setting_name_ok
    test eax, eax
    jz .Lwk_unknown
    jmp 4f
3:  mov rdi, r14
    mov rsi, r15
    call xc_key_ok
    test eax, eax
    jz .Lwk_unknown
4:  # its own manifest: NAME.KEY is its own key
    mov rdi, [rip + wc_owner]
    test rdi, rdi
    jz 5f
    mov rsi, r12
    mov rdx, [rsp]
    call xc_names_ext
    test eax, eax
    jz 5f
    call wc_keyref
    test rax, rax
    jz 9f
    inc ebx                     # KR_EXT_OWN, KR_EXTSET_OWN
    mov [rax + KR_kind], ebx
    mov rcx, [rip + wc_owner]
    mov [rax + KR_ptr], rcx
    mov [rsp + 8], rax
    mov rdi, r14
    mov rsi, r15
    call wc_literal
    mov rcx, [rsp + 8]
    mov [rcx + KR_b], eax
    jmp .Lwk_emit
5:  # another extension's: an ambiguous short name is an error; an unknown one is empty
    mov rdi, r12
    mov rsi, [rsp]
    call xc_resolve
    test edx, edx
    jnz .Lwk_ambiguous
    call wc_keyref
    test rax, rax
    jz 9f
    mov [rax + KR_kind], ebx
    mov [rsp + 8], rax
    mov rdi, r12
    mov rsi, [rsp]
    call wc_literal
    mov rcx, [rsp + 8]
    mov [rcx + KR_a], eax
    mov rdi, r14
    mov rsi, r15
    call wc_literal
    mov rcx, [rsp + 8]
    mov [rcx + KR_b], eax
    jmp .Lwk_emit
.Lwk_builtin:
    call ctx_ready
    lea rbx, [rip + ctx_idx]
    xor r14d, r14d
6:  cmp r14d, CTX_COUNT
    jae .Lwk_unknown
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rbx]
    call str_eq_cstr
    test eax, eax
    jnz 7f
    add rbx, 16
    inc r14d
    jmp 6b
7:  call wc_keyref
    test rax, rax
    jz 9f
    mov dword ptr [rax + KR_kind], KR_BUILTIN
    mov [rax + KR_a], r14d
.Lwk_emit:
    mov rsi, [rip + wc_nkeys]
    dec esi
    mov edi, OP_KEY
    call wc_emit
9:  EPILOGUE
.Lwk_unknown:
    lea rdi, [rip + .Le_unknown]
    mov rsi, r12
    mov rdx, r13
    call wc_fail_word
    EPILOGUE
.Lwk_ambiguous:
    lea rdi, [rip + .Le_ambiguous]
    mov rsi, r12
    mov rdx, [rsp]
    call wc_fail_word
    EPILOGUE

# ---------------------------------------------------------------- evaluating

# FN when_eval(wc) -> eax 1 when the clause holds (0 for a null clause: always true is the caller's
# choice); rhun's state is read afresh
FN when_eval
    push rdi
    call ctx_refresh
    pop rdi
    jmp when_eval_fresh

# FN when_eval_fresh(wc) -> eax 1 when the clause holds, reading keys as of the last ctx_refresh
FN when_eval_fresh
    PROLOGUE 16
    mov rbx, rdi
    xor eax, eax
    test rbx, rbx
    jz 9f
    mov qword ptr [rip + ev_numi], 0
    lea r12, [rip + ev_stack]   # the next free slot
    xor r13d, r13d              # the operation
.Lev_next:
    cmp r13d, [rbx + WC_nops]
    jae .Lev_done
    mov eax, [rbx + WC_OPS + r13*8]
    mov r14d, [rbx + WC_OPS + r13*8 + 4]
    inc r13d
    cmp eax, OP_KEY
    jne 1f
    mov edi, r14d
    imul rdi, rdi, KR_SIZE
    mov ecx, [rbx + WC_keys]
    add rdi, rcx
    add rdi, rbx
    mov rsi, rbx
    call ev_key
    jmp .Lev_push
1:  cmp eax, OP_LIT
    jne 2f
    mov rdi, rbx
    mov esi, r14d
    call ev_literal
    jmp .Lev_push
2:  cmp eax, OP_TRUE
    jne 3f
    lea rax, [rip + .Lw_true]
    mov edx, 4
    jmp .Lev_push
3:  cmp eax, OP_FALSE
    jne 4f
    lea rax, [rip + .Lw_false]
    mov edx, 5
    jmp .Lev_push
4:  cmp eax, OP_NOT
    jne 5f
    lea rdi, [r12 - 16]
    call ev_truth
    xor eax, 1
    sub r12, 16
    jmp .Lev_bool
5:  # binary: a at r12 - 32, b at r12 - 16
    mov r15d, eax
    lea rdi, [r12 - 32]
    lea rsi, [r12 - 16]
    sub r12, 32
    cmp r15d, OP_AND
    jne 51f
    call ev_truth
    test eax, eax
    jz .Lev_bool
    lea rdi, [r12 + 16]
    call ev_truth
    jmp .Lev_bool
51: cmp r15d, OP_OR
    jne 52f
    call ev_truth
    test eax, eax
    jnz .Lev_bool
    lea rdi, [r12 + 16]
    call ev_truth
    jmp .Lev_bool
52: cmp r15d, OP_EQ
    jne 53f
    call ev_equal
    jmp .Lev_bool
53: cmp r15d, OP_NE
    jne 54f
    call ev_equal
    xor eax, 1
    jmp .Lev_bool
54: cmp r15d, OP_GLOB
    jne 55f
    mov rdx, [rsi]
    mov rcx, [rsi + 8]
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call glob_match
    jmp .Lev_bool
55: cmp r15d, OP_IN
    jne 56f
    call ev_in
    jmp .Lev_bool
56: cmp r15d, OP_NIN
    jne 57f
    call ev_in
    xor eax, 1
    jmp .Lev_bool
57: # numbers: <, <=, >, >= (false unless both are integers)
    mov [rsp], rsi
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    call ev_int
    test edx, edx
    jz .Lev_false
    mov r14, rax
    mov rax, [rsp]
    mov rdi, [rax]
    mov rsi, [rax + 8]
    call ev_int
    test edx, edx
    jz .Lev_false
    cmp r15d, OP_LT
    jne 571f
    cmp r14, rax
    setl al
    jmp 58f
571:cmp r15d, OP_LE
    jne 572f
    cmp r14, rax
    setle al
    jmp 58f
572:cmp r15d, OP_GT
    jne 573f
    cmp r14, rax
    setg al
    jmp 58f
573:cmp r14, rax
    setge al
58: movzx eax, al
    jmp .Lev_bool
.Lev_false:
    xor eax, eax
.Lev_bool:
    lea rcx, [rip + .Lw_false]
    mov edx, 5
    test eax, eax
    jz .Lev_push_rc
    lea rcx, [rip + .Lw_true]
    mov edx, 4
.Lev_push_rc:
    mov rax, rcx
.Lev_push:
    lea rcx, [rip + ev_stack + EVAL_STACK * 16]
    cmp r12, rcx
    jae .Lev_overflow
    mov [r12], rax
    mov [r12 + 8], rdx
    add r12, 16
    jmp .Lev_next
.Lev_done:
    lea rcx, [rip + ev_stack]
    cmp r12, rcx
    jbe .Lev_overflow
    lea rdi, [r12 - 16]
    call ev_truth
9:  EPILOGUE
.Lev_overflow:
    xor eax, eax
    EPILOGUE

# ev_truth(value*) -> eax 1 unless empty, "false" or "0"
ev_truth:
    mov rcx, [rdi + 8]
    xor eax, eax
    test rcx, rcx
    jz 9f
    mov rdx, [rdi]
    cmp rcx, 1
    jne 1f
    cmp byte ptr [rdx], '0'
    je 9f
    jmp 8f
1:  cmp rcx, 5
    jne 8f
    cmp dword ptr [rdx], 0x736c6166     # "fals"
    jne 8f
    cmp byte ptr [rdx + 4], 'e'
    je 9f
8:  mov eax, 1
9:  ret

# ev_equal(a*, b*) -> eax 1 when the bytes are equal
ev_equal:
    mov rcx, [rsi + 8]
    mov rdx, [rsi]
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    jmp str_eq

# ev_in(x*, list*) -> eax 1 when x equals one of the list's space-separated words
ev_in:
    PROLOGUE
    mov r12, [rdi]
    mov r13, [rdi + 8]
    mov r14, [rsi]
    mov r15, [rsi + 8]
1:  test r15, r15
    jz 8f
    mov rdi, r14
    mov rsi, r15
    call next_word
    add r14, rcx
    sub r15, rcx
    test rdx, rdx
    jz 8f
    mov rdi, r12
    mov rsi, r13
    mov rcx, rdx
    mov rdx, rax
    call str_eq
    test eax, eax
    jz 1b
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN when_number(ptr, len) -> rax a signed decimal integer, edx 1 when the whole text is one
FN when_number
    jmp ev_int

# ev_int(ptr, len) -> rax a signed decimal integer, edx 1 when the whole value is one that fits
#   in 64 bits (leading zeros allowed)
ev_int:
    xor eax, eax
    xor r8d, r8d                # negative
    test rsi, rsi
    jz 8f
    cmp byte ptr [rdi], '-'
    jne 2f
    mov r8d, 1
    inc rdi
    dec rsi
    jz 8f
2:  movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja 8f
    mov r9, 922337203685477580  # (2^63 - 1) / 10: one more digit must not pass 2^63 - 1 (2^63 negative)
    cmp rax, r9
    ja 8f
    jb 4f
    lea r10d, [r8 + 7]
    cmp ecx, r10d
    ja 8f
4:  imul rax, rax, 10
    add rax, rcx
    inc rdi
    dec rsi
    jnz 2b
    test r8d, r8d
    jz 3f
    neg rax
3:  mov edx, 1
    ret
8:  xor eax, eax
    xor edx, edx
    ret

# ev_literal(wc, index) -> rax ptr, rdx len
ev_literal:
    mov eax, [rdi + WC_lits]
    add rax, rdi
    mov ecx, [rax + rsi*8]
    mov edx, [rax + rsi*8 + 4]
    mov eax, [rdi + WC_text]
    add rax, rdi
    add rax, rcx
    ret

# ev_key(kr*, wc) -> rax ptr, rdx len: the key's value now
ev_key:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [rbx + KR_kind]
    cmp eax, KR_BUILTIN
    jne 1f
    mov edi, [rbx + KR_a]
    call ctx_get
    EPILOGUE
1:  cmp eax, KR_CONFIG
    jne 2f
    mov rdi, [rbx + KR_ptr]
    call ev_setting
    EPILOGUE
2:  # an extension's key or setting: its local name
    mov rdi, r12
    mov esi, [rbx + KR_b]
    call ev_literal
    mov r13, rax
    mov r14, rdx
    mov eax, [rbx + KR_kind]
    cmp eax, KR_EXT_OWN
    je 3f
    cmp eax, KR_EXTSET_OWN
    je 3f
    mov rdi, r12
    mov esi, [rbx + KR_a]
    call ev_literal
    mov rdi, rax
    mov rsi, rdx
    call xc_resolve
    test edx, edx
    jnz 8f                      # ambiguous since: empty
    test rax, rax
    jz 8f
    jmp 4f
3:  mov rax, [rbx + KR_ptr]
4:  mov rdi, rax
    mov rsi, r13
    mov rdx, r14
    mov eax, [rbx + KR_kind]
    cmp eax, KR_EXTSET
    je 5f
    cmp eax, KR_EXTSET_OWN
    je 5f
    call xc_value
    EPILOGUE
5:  call xc_setting
    EPILOGUE
8:  lea rax, [rip + .Lw_true]
    xor edx, edx
    EPILOGUE

# ev_setting(SET*) -> rax ptr, rdx len: a rhun setting as the config file writes it
ev_setting:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + SET_ptr]
    mov eax, [rbx + SET_type]
    cmp eax, ST_BOOL
    jne 1f
    lea rax, [rip + .Lw_false]
    mov edx, 5
    cmp dword ptr [r12], 0
    je 9f
    lea rax, [rip + .Lw_true]
    mov edx, 4
    jmp 9f
1:  cmp eax, ST_INT
    jne 3f
    # a number: hundredths as "1.5" for decimal settings
    mov rax, [rip + ev_numi]
    and eax, 15
    inc qword ptr [rip + ev_numi]
    imul rax, rax, 24
    lea r13, [rip + ev_num]
    add r13, rax
    mov eax, [r12]
    cmp dword ptr [rbx + SET_decimal], 0
    je 2f
    xor edx, edx
    mov ecx, 100
    div ecx
    mov r14d, edx
    mov rdi, r13
    mov esi, eax
    call fmt_u64
    mov r15, rax
    mov byte ptr [r13 + r15], '.'
    inc r15
    mov eax, r14d
    xor edx, edx
    mov ecx, 10
    div ecx
    mov r14d, edx
    add eax, '0'
    mov [r13 + r15], al
    inc r15
    test r14d, r14d
    jz 11f
    add r14d, '0'
    mov [r13 + r15], r14b
    inc r15
11: mov rax, r13
    mov rdx, r15
    jmp 9f
2:  mov rdi, r13
    mov esi, eax
    call fmt_u64
    mov rdx, rax
    mov rax, r13
    jmp 9f
3:  cmp eax, ST_CHOICE
    jne 4f
    mov rdi, [rbx + SET_opts]
    mov esi, [r12]
    call choice_entry
    test rax, rax
    jz 8f
    jmp 5f
4:  mov rax, [r12]              # strings: the value's cstr
    test rax, rax
    jz 8f
5:  mov r13, rax
    mov rdi, rax
    call strlen
    mov rdx, rax
    mov rax, r13
    jmp 9f
8:  lea rax, [rip + .Lw_false]
    xor edx, edx
9:  EPILOGUE

# FN glob_match(text, tlen, pattern, plen) -> eax 1 when the whole text fits: * any run, ? one
# character (UTF-8), other bytes exactly
FN glob_match
    PROLOGUE
    mov r12, rdi                # text and its end
    lea r13, [rdi + rsi]
    mov r14, rdx                # pattern and its end
    lea r15, [rdx + rcx]
    xor ebx, ebx                # the pattern after the last *, 0 before any
    xor r8d, r8d                # the text where that * matched last
1:  cmp r14, r15
    jae 5f
    movzx eax, byte ptr [r14]
    cmp eax, '*'
    jne 2f
    inc r14
    mov rbx, r14
    mov r8, r12
    jmp 1b
2:  cmp r12, r13
    jae 6f
    cmp eax, '?'
    jne 3f
    inc r14
    call glob_char
    jmp 1b
3:  cmp al, [r12]
    jne 6f
    inc r14
    inc r12
    jmp 1b
5:  cmp r12, r13
    je 7f
6:  # backtrack: the last * takes one more character
    test rbx, rbx
    jz 8f
    cmp r8, r13
    jae 8f
    mov r12, r8
    call glob_char
    mov r8, r12
    mov r14, rbx
    jmp 1b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE
# glob_char(): r12 past one UTF-8 character (not past r13)
glob_char:
    inc r12
1:  cmp r12, r13
    jae 2f
    movzx eax, byte ptr [r12]
    and eax, 0xc0
    cmp eax, 0x80
    jne 2f
    inc r12
    jmp 1b
2:  ret

# ---------------------------------------------------------------- context keys

# FN ctx_refresh(): rhun's state may have changed since the keys were last read
FN ctx_refresh
    inc dword ptr [rip + ctx_round]
    jnz 1f
    inc dword ptr [rip + ctx_round]    # 0 is never a round
1:  ret

# FN ctx_push_target(MTG*): the resource and editor keys describe this menu target until
# ctx_pop_target
FN ctx_push_target
    mov rax, [rip + ctx_ntargets]
    cmp rax, 8
    jae 1f                      # deeper than any menu nests: the outer ones are kept
    lea rcx, [rip + ctx_targets]
    mov rdx, [rip + ctx_target]
    mov [rcx + rax*8], rdx
    inc qword ptr [rip + ctx_ntargets]
1:  mov [rip + ctx_target], rdi
    jmp ctx_refresh
FN ctx_pop_target
    xor edx, edx
    mov rax, [rip + ctx_ntargets]
    test rax, rax
    jz 1f
    dec rax
    mov [rip + ctx_ntargets], rax
    lea rcx, [rip + ctx_targets]
    mov rdx, [rcx + rax*8]
1:  mov [rip + ctx_target], rdx
    jmp ctx_refresh

# FN ctx_get(id) -> rax ptr, rdx len: the value of built-in key CTX_* (empty for a bad id)
FN ctx_get
    PROLOGUE
    mov ebx, edi
    cmp ebx, CTX_COUNT
    jae 8f
    cmp dword ptr [rip + ctx_inited], 0
    jne 1f
    call ctx_init
1:  lea rcx, [rip + ctx_stamp]
    mov eax, [rip + ctx_round]
    test eax, eax
    jz 2f
    cmp [rcx + rbx*4], eax
    jne 2f
    mov rax, rbx
    shl rax, 4
    lea rcx, [rip + ctx_vals]
    mov rdx, [rcx + rax + 8]
    mov rax, [rcx + rax]
    EPILOGUE
2:  # a view target names its view and item (view, viewItem)
    mov rcx, [rip + ctx_target]
    test rcx, rcx
    jz 21f
    mov rdi, [rcx + MTG_view]
    cmp ebx, CTX_VIEW
    je 20f
    mov rdi, [rcx + MTG_item]
    cmp ebx, CTX_VIEW_ITEM
    je 20f
    mov rdi, [rcx + MTG_scm]    # a source control target names its provider (scmProvider)
    cmp ebx, CTX_SCM_PROVIDER
    jne 21f
20: test rdi, rdi
    jz 21f
    call ck_cstr
    jmp 4f
21: mov rax, rbx
    shl rax, 4
    lea rcx, [rip + ctx_idx]
    mov rax, [rcx + rax + 8]
    test rax, rax
    jz 3f
    call rax
    jmp 4f
3:  # published
    mov rax, rbx
    imul rax, rax, CTX_VAL_MAX
    lea rcx, [rip + ctx_pub]
    add rax, rcx
    lea rcx, [rip + ctx_publen]
    mov edx, [rcx + rbx*4]
4:  mov rcx, rbx
    shl rcx, 4
    lea r8, [rip + ctx_vals]
    mov [r8 + rcx], rax
    mov [r8 + rcx + 8], rdx
    mov ecx, [rip + ctx_round]
    lea r8, [rip + ctx_stamp]
    mov [r8 + rbx*4], ecx
    EPILOGUE
8:  lea rax, [rip + .Lw_true]
    xor edx, edx
    EPILOGUE

# ctx_ready(): the key index exists
ctx_ready:
    cmp dword ptr [rip + ctx_inited], 0
    jne 1f
    jmp ctx_init
1:  ret

# ctx_init(): the key index from ctx_table, then the published keys' defaults (ctx_defaults)
ctx_init:
    PROLOGUE
    mov dword ptr [rip + ctx_inited], 1
    lea rbx, [rip + ctx_table]
    lea r12, [rip + ctx_idx]
    xor r13d, r13d
1:  cmp r13d, CTX_COUNT
    jae 3f
    mov rax, [rbx]
    mov [r12 + 8], rax
    lea rdi, [rbx + 8]
    mov [r12], rdi
    call strlen
    lea rbx, [rbx + rax + 8 + 1 + 7]
    and rbx, -8
    add r12, 16
    inc r13d
    jmp 1b
3:  lea rbx, [rip + ctx_defaults]
4:  mov edi, [rbx]
    cmp edi, -1
    je 5f
    xor esi, esi
    xor edx, edx                # empty: the default
    call ctx_set
    add rbx, 16
    jmp 4b
5:  EPILOGUE

# FN ctx_set(id, ptr, len): a published key's value (cut at CTX_VAL_MAX bytes); a computed key
# is not changed
FN ctx_set
    PROLOGUE
    mov ebx, edi
    push rsi
    push rdx
    call ctx_ready
    pop rdx
    pop rsi
    mov r12, rsi
    mov r13, rdx
    cmp ebx, CTX_COUNT
    jae 9f
    mov rax, rbx
    shl rax, 4
    lea rcx, [rip + ctx_idx]
    cmp qword ptr [rcx + rax + 8], 0
    jne 9f
    test r13, r13
    jnz 0f
    # cleared: the key's default, if it has one
    lea rcx, [rip + ctx_defaults]
2:  mov eax, [rcx]
    cmp eax, -1
    je 1f
    add rcx, 16
    cmp eax, ebx
    jne 2b
    mov r12, [rcx - 8]
    mov rdi, r12
    call strlen
    mov r13, rax
    jmp 1f
0:  cmp r13, CTX_VAL_MAX
    jbe 1f
    mov edi, r13d
    mov rsi, r12
    mov edx, CTX_VAL_MAX
    call utf8_cut
    mov r13, rax
1:  mov rdi, rbx
    imul rdi, rdi, CTX_VAL_MAX
    lea rcx, [rip + ctx_pub]
    add rdi, rcx
    mov rsi, r12
    mov rdx, r13
    call memmove
    lea rcx, [rip + ctx_publen]
    mov [rcx + rbx*4], r13d
    lea rcx, [rip + ctx_stamp]
    mov dword ptr [rcx + rbx*4], 0
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN ctx_set_bool(id, 0|1): "true" or "false"
FN ctx_set_bool
    lea rcx, [rip + .Lw_true]
    mov edx, 4
    test esi, esi
    jnz 1f
    lea rcx, [rip + .Lw_false]
    mov edx, 5
1:  mov rsi, rcx
    jmp ctx_set

# ---- the computed keys: each -> rax ptr, rdx len ----

ck_bool:
    test eax, eax
    jz 1f
    lea rax, [rip + .Lw_true]
    mov edx, 4
    ret
1:  lea rax, [rip + .Lw_false]
    mov edx, 5
    ret
ck_empty:
    lea rax, [rip + .Lw_true]
    xor edx, edx
    ret
# ck_cstr(cstr or 0) -> its bytes
ck_cstr:
    test rdi, rdi
    jz ck_empty
    push rdi
    call strlen
    mov rdx, rax
    pop rax
    ret
# ck_number(id in ebx, value) -> formatted in the key's number slot
ck_number:
    push r12
    imul r12, rbx, 24
    lea rax, [rip + ctx_num]
    add r12, rax
    mov rsi, rdi
    mov rdi, r12
    call fmt_u64
    mov rdx, rax
    mov rax, r12
    pop r12
    ret

ck_focus_is:                    # eax 1 when the focus is edi
    call ctx_focus
    cmp eax, edi
    sete al
    movzx eax, al
    ret
# ctx_focus() -> eax g_focus, or the focus a list is evaluated for (ctx_focus_as)
ctx_focus:
    mov eax, [rip + ctx_focus_over]
    test eax, eax
    jns 1f
    mov eax, [rip + g_focus]
1:  ret
# FN ctx_focus_as(focus or -1): clauses see this focus (the palette lists commands as of the
# focus before it opened); -1 ends it
FN ctx_focus_as
    mov [rip + ctx_focus_over], edi
    jmp ctx_refresh

ck_editor_focus:
    call ctx_editor_focused
    jmp ck_bool
# ctx_editor_focused() -> eax 1 when a text document has the keys
ctx_editor_focused:
    xor eax, eax
    cmp qword ptr [rip + g_doc], 0
    je 1f
    call ctx_focus
    cmp eax, FOCUS_EDITOR
    sete al
    movzx eax, al
1:  ret
ck_text_input_focus:
    call ctx_editor_focused
    test eax, eax
    jnz ck_bool
    call ctx_focus
    mov ecx, eax
    cmp ecx, FOCUS_PALETTE
    je 1f
    cmp ecx, FOCUS_PROMPT
    je 1f
    cmp ecx, FOCUS_FIND
    je 1f
    cmp ecx, FOCUS_SETTINGS
    je 1f
    cmp ecx, FOCUS_SCM
    je 1f
    cmp ecx, FOCUS_AGENT_INPUT
    je 1f
    xor eax, eax
    jmp ck_bool
1:  mov eax, 1
    jmp ck_bool
ck_palette_focus:
    mov edi, FOCUS_PALETTE
    call ck_focus_is
    test eax, eax
    jnz ck_bool
    mov edi, FOCUS_PROMPT
    call ck_focus_is
    jmp ck_bool
ck_find_focus:
    mov edi, FOCUS_FIND
    call ck_focus_is
    jmp ck_bool
ck_explorer_focus:
    mov edi, FOCUS_EXPLORER
    call ck_focus_is
    jmp ck_bool
ck_agents_focus:
    mov edi, FOCUS_AGENTS
    call ck_focus_is
    jmp ck_bool
ck_terminal_focus:
    mov edi, FOCUS_TERMINAL
    call ck_focus_is
    jmp ck_bool
ck_scm_focus:
    mov edi, FOCUS_SCM
    call ck_focus_is
    jmp ck_bool
ck_settings_focus:
    mov edi, FOCUS_SETTINGS
    call ck_focus_is
    jmp ck_bool
ck_find_visible:
    xor eax, eax
    cmp dword ptr [rip + find_open], 0
    setne al
    jmp ck_bool
ck_completion_visible:
    xor eax, eax
    cmp dword ptr [rip + cp_open], 2
    sete al
    jmp ck_bool
ck_signature_visible:
    xor eax, eax
    cmp dword ptr [rip + sg_open], 0
    setne al
    jmp ck_bool
ck_snippet_active:
    xor eax, eax
    mov rcx, [rip + g_doc]
    test rcx, rcx
    jz ck_bool
    cmp qword ptr [rcx + DOC_snippet], 0
    setne al
    jmp ck_bool

# ctx_tab() -> rax the active TAB*, or 0
ctx_tab:
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 8f
    cmp rdi, [rip + g_tabs + VEC_len]
    jae 8f
    imul rax, rdi, TAB_SIZE
    add rax, [rip + g_tabs + VEC_ptr]
    ret
8:  xor eax, eax
    ret
ck_active_tab:
    call ctx_tab
    test rax, rax
    jz ck_empty
    mov rdi, [rax + TAB_kind]
    call ctx_tab_kind_name
    mov rdi, rax
    jmp ck_cstr
# FN ctx_tab_kind_name(TAB_*) -> rax "doc" "image" "settings" "git" "extensions" "view" "markdown", or 0
FN ctx_tab_kind_name
    lea rax, [rip + .Lv_notebook]   # notebooks: TAB_NOTEBOOK (from the notebooks' block) is "notebook"
    cmp rdi, TAB_NOTEBOOK
    je 9f
    xor eax, eax
    dec rdi
    cmp rdi, TAB_MDDOC - 1          # plan review: TAB_MDDOC (mdtab.s) is "markdown"
    ja 9f
    lea rax, [rip + tab_kind_names]
    mov rax, [rax + rdi*8]
9:  ret
ck_active_tab_pinned:
    call ctx_tab
    test rax, rax
    jz ck_bool
    mov rcx, [rax + TAB_flags]
    xor eax, eax
    test ecx, TF_PIN
    setnz al
    jmp ck_bool
ck_tab_count:
    mov rdi, [rip + g_tabs + VEC_len]
    jmp ck_number

# ctx_rdoc() -> rax the document the resource and editor keys describe: the target's, else the
# active text document
ctx_rdoc:
    mov rax, [rip + ctx_target]
    test rax, rax
    jz 1f
    mov rax, [rax + MTG_doc]
    ret
1:  mov rax, [rip + g_doc]
    ret
# ctx_rpath() -> rax the resource's path (cstr) or 0: the target's, else the active file's
ctx_rpath:
    mov rax, [rip + ctx_target]
    test rax, rax
    jz 1f
    mov rcx, [rax + MTG_path]
    test rcx, rcx
    jnz 3f
    mov rax, [rax + MTG_doc]
    jmp 2f
1:  mov rax, [rip + g_file]
    test rax, rax
    jnz 2f
    mov rax, [rip + g_doc]
2:  test rax, rax
    jz 9f
    mov rax, [rax + DOC_path]
9:  ret
3:  mov rax, rcx
    ret
ck_resource_path:
    call ctx_rpath
    mov rdi, rax
    jmp ck_cstr
ck_resource_filename:
    call ctx_rpath
    test rax, rax
    jz ck_empty
    push rax
    mov rdi, rax
    call strlen
    mov rsi, rax
    pop rdi
    jmp path_basename
ck_resource_dirname:
    call ctx_rpath
    test rax, rax
    jz ck_empty
    push rax
    mov rdi, rax
    call strlen
    mov rsi, rax
    mov rdi, [rsp]
    call path_dirlen
    mov rdx, rax
    pop rax
    test rdx, rdx
    jnz 1f
    cmp byte ptr [rax], '/'     # a file at the root: its folder is /
    jne 1f
    mov edx, 1
1:  ret
ck_resource_ext:
    call ctx_rpath
    test rax, rax
    jz ck_empty
    push rax
    mov rdi, rax
    call strlen
    mov rsi, rax
    pop rdi
    call path_ext
    test rdx, rdx
    jz ck_empty
    dec rax                     # with its dot
    inc rdx
    ret
ck_resource_scheme:
    call ctx_rpath
    test rax, rax
    jz 1f
    lea rax, [rip + .Lv_file]
    mov edx, 4
    ret
1:  call ctx_rdoc
    test rax, rax
    jz ck_empty
    lea rax, [rip + .Lv_untitled]
    mov edx, 8
    ret
ck_resource_in_project:
    call ctx_rpath
    test rax, rax
    jz ck_bool
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 1f
    mov rdi, rax
    call app_path_inside
    jmp ck_bool
1:  xor eax, eax
    jmp ck_bool
ck_resource_lang:
    PROLOGUE
    xor r12d, r12d              # the grammar
    call ctx_rdoc
    test rax, rax
    jz 1f
    mov r12, [rax + DOC_lang]
    jmp 2f
1:  call ctx_rpath              # a file without a document: the grammar rhun picks for its name
    test rax, rax
    jz 2f
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call path_basename
    mov rdi, rax
    mov rsi, rdx
    call syntax_for_name
    mov r12, rax
2:  test r12, r12
    jz 8f
    mov rsi, [r12 + GR_name]
    test rsi, rsi
    jz 8f
    lea rdi, [rip + ctx_lang]
    xor ecx, ecx
3:  movzx eax, byte ptr [rsi + rcx]
    test eax, eax
    jz 4f
    cmp ecx, 127
    jae 4f
    cmp eax, ' '
    jne 31f
    mov eax, '_'
31: mov [rdi + rcx], al
    inc ecx
    jmp 3b
4:  mov rax, rdi
    mov edx, ecx
    EPILOGUE
8:  call ck_empty
    EPILOGUE
ck_editor_readonly:
    call ctx_rdoc
    test rax, rax
    jz ck_bool
    mov ecx, [rax + DOC_flags]
    xor eax, eax
    test ecx, DF_READONLY
    setnz al
    jmp ck_bool
ck_editor_dirty:
    call ctx_rdoc
    test rax, rax
    jz ck_bool
    mov rdi, rax
    call doc_dirty
    jmp ck_bool
ck_editor_has_selection:
    PROLOGUE
    call ctx_rdoc
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rcx, [rbx + DOC_cur]
    cmp rcx, [rbx + DOC_anchor]
    jne 7f
    mov rdi, rbx
    call doc_selections_count
    mov r12, rax
    mov r13d, 1
1:  cmp r13, r12
    jae 8f
    mov rdi, rbx
    mov rsi, r13
    call doc_selections_get
    inc r13
    cmp rax, rdx
    je 1b
7:  mov eax, 1
    call ck_bool
    EPILOGUE
8:  xor eax, eax
    call ck_bool
    EPILOGUE
ck_editor_multi:
    call ctx_rdoc
    test rax, rax
    jz ck_bool
    mov rdi, rax
    call doc_selections_count
    cmp rax, 1
    seta al
    movzx eax, al
    jmp ck_bool
ck_editor_providers:
    PROLOGUE
    lea rdi, [rip + ctx_prov]
    mov byte ptr [rdi], 0
    call ctx_rdoc
    test rax, rax
    jz 9f
    mov r12, rax
    xor r13d, r13d              # the kind
1:  lea rax, [rip + prov_fields]
    mov r14, [rax + r13*8]
    test r14, r14
    jz 9f
    xor r15d, r15d              # the extension
2:  cmp r15, [rip + g_exts + VEC_len]
    jae 5f
    imul rbx, r15, EXT_SIZE
    add rbx, [rip + g_exts + VEC_ptr]
    inc r15
    mov rdi, rbx
    call ext_is_visible
    test eax, eax
    jz 2b
    cmp dword ptr [rbx + EXT_disabled], 0
    jne 2b
    mov rdi, rbx                # the values in force (language features' provider-scope)
    mov rsi, r14
    call ext_pv
    mov rdi, rax
    test rdi, rdi
    jz 2b
    mov rsi, r12
    call extproto_matches
    test eax, eax
    jz 2b
    # a provider: the kind's word
    lea rdi, [rip + ctx_prov]
    cmp byte ptr [rdi], 0
    je 3f
    call strlen
    lea rdi, [rip + ctx_prov]
    mov word ptr [rdi + rax], ' '
3:  lea rax, [rip + prov_names]
    mov rsi, [rax + r13*8]
    lea rdi, [rip + ctx_prov]
    push rsi
    call strlen
    pop rsi
    lea rdi, [rip + ctx_prov]
    add rdi, rax
    call cstr_copy
5:  inc r13d
    jmp 1b
9:  lea rdi, [rip + ctx_prov]
    call ck_cstr
    EPILOGUE
ck_vim_mode:
    cmp dword ptr [rip + cfg_vim], 0
    je ck_empty
    mov eax, [rip + g_vim_mode]
    cmp eax, 3
    ja ck_empty
    lea rcx, [rip + vim_names]
    mov rdi, [rcx + rax*8]
    jmp ck_cstr
ck_sidebar_visible:
    mov eax, [rip + g_show_side]
    jmp ck_bool
ck_agents_visible:
    mov eax, [rip + g_show_agents]
    jmp ck_bool
ck_terminal_visible:
    mov eax, [rip + g_term_open]
    jmp ck_bool
ck_project_open:
    xor eax, eax
    cmp qword ptr [rip + g_project], 0
    setne al
    jmp ck_bool
ck_project_path:
    mov rdi, [rip + g_project]
    jmp ck_cstr
ck_git_repo:
    mov eax, [rip + g_git_on]
    jmp ck_bool
ck_git_branch:
    lea rdi, [rip + g_branch]
    jmp ck_cstr
ck_git_changes:
    mov edi, [rip + g_git_changes]
    jmp ck_number
ck_is_linux:
.ifdef MACOS
    xor eax, eax
.else
.ifdef WINDOWS
    xor eax, eax
.else
    mov eax, 1
.endif
.endif
    jmp ck_bool
ck_is_mac:
    xor eax, eax
.ifdef MACOS
    mov eax, 1
.endif
    jmp ck_bool
ck_is_windows:
    xor eax, eax
.ifdef WINDOWS
    mov eax, 1
.endif
    jmp ck_bool
ck_is_wayland:
    mov eax, [rip + g_wayland]
    jmp ck_bool
ck_target_kind:
    mov rax, [rip + ctx_target]
    test rax, rax
    jz ck_empty
    mov rdi, [rax + MTG_kind]
    jmp ck_cstr
ck_target_is_folder:
    mov rax, [rip + ctx_target]
    test rax, rax
    jz ck_bool
    mov rdi, [rax + MTG_kind]
    test rdi, rdi
    jz ck_empty
    lea rsi, [rip + .Lv_folder]
    call strcmp_eq
    test eax, eax
    jnz ck_bool
    mov rax, [rip + ctx_target]
    mov rdi, [rax + MTG_kind]
    lea rsi, [rip + .Lv_root]
    call strcmp_eq
    jmp ck_bool
ck_target_is_root:
    mov rax, [rip + ctx_target]
    test rax, rax
    jz ck_bool
    mov rdi, [rax + MTG_kind]
    test rdi, rdi
    jz ck_empty
    lea rsi, [rip + .Lv_root]
    call strcmp_eq
    jmp ck_bool
ck_tab_kind:
    mov rax, [rip + ctx_target]
    test rax, rax
    jz ck_empty
    mov rdi, [rax + MTG_tabkind]
    jmp ck_cstr

# ---------------------------------------------------------------- headless control

# FN when_ctl(out sb, rest, len): "when=1", "when=0" or "when error at N: TEXT"
FN when_ctl
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    mov rsi, rdx
    xor edx, edx
    call when_compile
    test rax, rax
    jz 8f
    mov r12, rax
    mov rdi, rax
    call when_eval
    mov r13d, eax
    mov rdi, r12
    call when_free
    mov rdi, rbx
    lea rsi, [rip + .Lc_when1]
    test r13d, r13d
    jnz 1f
    lea rsi, [rip + .Lc_when0]
1:  call sb_push_cstr
    xor eax, eax
    EPILOGUE
8:  mov r12, rdx
    mov r13, rcx
    mov rdi, rbx
    lea rsi, [rip + .Lc_when_err]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lc_colon]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

# FN ctx_dump(out sb, rest, len): "KEY=VALUE" for every built-in key, or the one named (any key a
# clause can name: config.*, extension keys)
FN ctx_dump
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call ctx_ready
    call ctx_refresh
    mov rdi, r12
    mov rsi, r13
    call trim
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 5f
    # one key: compile it as a clause and read its value
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    call when_compile
    test rax, rax
    jz 7f
    mov r14, rax
    cmp dword ptr [r14 + WC_nops], 1
    jne 6f
    cmp dword ptr [r14 + WC_OPS], OP_KEY
    jne 6f
    mov edi, [r14 + WC_keys]
    add rdi, r14
    mov rsi, r14
    call ev_key
    mov r15, rax
    mov [rsp], rdx
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, rbx
    mov esi, '='
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r15
    mov rdx, [rsp]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
6:  mov rdi, r14
    call when_free
    xor eax, eax
    EPILOGUE
7:  mov r12, rdx                # the error's byte and text
    mov r13, rcx
    mov rdi, rbx
    lea rsi, [rip + .Lc_error_at]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lc_colon]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE
5:  xor r14d, r14d
1:  cmp r14d, CTX_COUNT
    jae 9f
    mov rax, r14
    shl rax, 4
    lea rcx, [rip + ctx_idx]
    mov rsi, [rcx + rax]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    mov esi, '='
    call sb_push_byte
    mov edi, r14d
    call ctx_get
    mov rdi, rbx
    mov rsi, rax
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc r14d
    jmp 1b
9:  xor eax, eax
    EPILOGUE

# FN ctx_ctl_set(out sb, rest, len): "ctx-set KEY VALUE" sets a published key ("-" clears it)
FN ctx_ctl_set
    PROLOGUE
    push rsi
    push rdx
    call ctx_ready
    pop rdx
    pop rsi
    mov rdi, rsi
    mov rsi, rdx
    mov r14, rdi
    mov r15, rsi
    call next_word
    mov r12, rax                # the key
    mov r13, rdx
    add r14, rcx                # the value: the rest, trimmed
    sub r15, rcx
    mov rdi, r14
    mov rsi, r15
    call trim
    mov r14, rax
    mov r15, rdx
    cmp r15, 1
    jne 1f
    cmp byte ptr [r14], '-'
    jne 1f
    xor r15d, r15d
1:  xor ebx, ebx
2:  cmp ebx, CTX_COUNT
    jae 9f
    mov rax, rbx
    shl rax, 4
    lea rcx, [rip + ctx_idx]
    mov rdx, [rcx + rax]
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 3f
    inc ebx
    jmp 2b
3:  mov edi, ebx
    mov rsi, r14
    mov rdx, r15
    call ctx_set
9:  xor eax, eax
    EPILOGUE

.section .rodata
.p2align 3
# the built-in keys in CTX_* order: FN (0: published), the name, padding (ctx_init indexes them)
.set CTXKEY_NAMES, 1
ctx_table:
    CTXKEY_LIST
# by TAB_*: TAB_DOC 1, TAB_SETTINGS 2, TAB_IMAGE 3, TAB_GIT 4, TAB_EXT 5, TAB_VIEW 6, TAB_MDDOC 7
# published keys with a value until they are set, and again when cleared: id, value
.p2align 3
ctx_defaults:
    .long CTX_DEBUG_STATE, 0
    .quad .Lv_inactive
    .long CTX_IN_DEBUG_MODE, 0
    .quad .Lw_false
    .long -1, 0
.p2align 3
tab_kind_names: .quad .Lv_doc, .Lv_settings, .Lv_image, .Lv_git, .Lv_extensions, .Lv_view, .Lv_markdown
vim_names: .quad .Lv_normal, .Lv_insert, .Lv_visual, .Lv_vline
prov_fields: .quad EXT_pv_complete, EXT_pv_signature, EXT_pv_definition, EXT_pv_references
    .quad EXT_pv_symbols, EXT_pv_actions, EXT_pv_rename, EXT_pv_format
    # language features (protocol 1.1)
    .quad EXT_pv_hover, EXT_pv_declaration, EXT_pv_type_definition, EXT_pv_implementation
    .quad EXT_pv_selection_ranges, EXT_pv_call_hierarchy, EXT_pv_type_hierarchy
    .quad EXT_pv_workspace_symbols, EXT_pv_range_format, EXT_pv_type_format, EXT_pv_document_links, 0
prov_names: .quad .Lp_complete, .Lp_signature, .Lp_definition, .Lp_references, .Lp_symbols
    .quad .Lp_actions, .Lp_rename, .Lp_format
    .quad .Lp_hover, .Lp_declaration, .Lp_type_definition, .Lp_implementation
    .quad .Lp_selection_ranges, .Lp_call_hierarchy, .Lp_type_hierarchy
    .quad .Lp_workspace_symbols, .Lp_range_format, .Lp_type_format, .Lp_document_links
.Lp_complete: .asciz "complete"
.Lp_signature: .asciz "signature"
.Lp_definition: .asciz "definition"
.Lp_references: .asciz "references"
.Lp_symbols: .asciz "symbols"
.Lp_actions: .asciz "actions"
.Lp_rename: .asciz "rename"
.Lp_format: .asciz "format"
.Lp_hover: .asciz "hover"
.Lp_declaration: .asciz "declaration"
.Lp_type_definition: .asciz "type_definition"
.Lp_implementation: .asciz "implementation"
.Lp_selection_ranges: .asciz "selection_ranges"
.Lp_call_hierarchy: .asciz "call_hierarchy"
.Lp_type_hierarchy: .asciz "type_hierarchy"
.Lp_workspace_symbols: .asciz "workspace_symbols"
.Lp_range_format: .asciz "range_format"
.Lp_type_format: .asciz "type_format"
.Lp_document_links: .asciz "document_links"
.Lv_doc: .asciz "doc"
.Lv_image: .asciz "image"
.Lv_settings: .asciz "settings"
.Lv_git: .asciz "git"
.Lv_extensions: .asciz "extensions"
.Lv_view: .asciz "view"
.Lv_notebook: .asciz "notebook"
.Lv_markdown: .asciz "markdown"
.Lv_normal: .asciz "normal"
.Lv_insert: .asciz "insert"
.Lv_visual: .asciz "visual"
.Lv_vline: .asciz "vline"
.Lv_file: .asciz "file"
.Lv_untitled: .asciz "untitled"
.Lv_folder: .asciz "folder"
.Lv_root: .asciz "root"
.Lv_inactive: .asciz "inactive"
.Lw_true: .asciz "true"
.Lw_false: .asciz "false"
.Lw_in: .asciz "in"
.Lw_not: .asciz "not"
.Lconfig_dot: .asciz "config."
.Lsetting_dot: .asciz "setting."
.Ldot: .asciz "."
.Lbare_extra: .asciz "_-./:*?+#@$"
.Le_long: .asciz "too long (512 bytes at most)"
.Le_empty: .asciz "empty clause"
.Le_unexpected: .asciz "expected && or ||"
.Le_ops: .asciz "too many operations (64 at most)"
.Le_deep: .asciz "nested too deeply (8 levels at most)"
.Le_expected: .asciz "expected a key, true, false, ! or ("
.Le_close: .asciz "expected )"
.Le_operator: .asciz "expected == != < <= > >= =~ in or not in"
.Le_need_in: .asciz "expected in or not in"
.Le_value: .asciz "expected a value"
.Le_list: .asciz "expected a key or a quoted list"
.Le_quote: .asciz "unclosed quote"
.Le_utf8: .asciz "a quoted value that is not UTF-8"
.Le_unknown: .asciz "unknown key "
.Le_ambiguous: .asciz "ambiguous extension name "
.Lc_when1: .asciz "when=1\n"
.Lc_when0: .asciz "when=0\n"
.Lc_when_err: .asciz "when error at "
.Lc_colon: .asciz ": "
.Lc_error_at: .asciz "error at "
