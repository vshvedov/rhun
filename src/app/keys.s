# command registry and keybindings: "ctrl+shift+p" strings and two-stroke chords ("ctrl+k ctrl+t"),
# from the built-in table, extensions' [commands] defaults and [keys] sections, and the user's
# [keys] ("KEYS = COMMAND [ARGS] [when CLAUSE]"). A key goes to the binding whose first stroke
# matches, whose when clause holds and whose command is enabled, the best by rank (the user's,
# an extension's [keys], built-in, an extension's default), then by order. A stroke that starts a
# chord waits for the next one (status bar indicator; Escape, a click or 5 s end it; with a
# single-stroke binding of the same key, a 1 s pause runs that one instead).
.include "rhun.inc"

STRUCT
F KB_mods, 4
F KB_key, 4
F KB_mods2, 4           # the chord's second stroke; KB_key2 0: a single stroke
F KB_key2, 4
F KB_cmd, 8             # CMD*
F KB_when, 8            # WC* (owned), or 0
F KB_args, 8            # owned cstr: ARGS for FROM key, or 0
F KB_alen, 8
F KB_ext, 8             # EXT* of an extension's binding, or 0
F KB_text, 8            # owned cstr: the strokes as written
F KB_name, 8            # owned cstr: the command as written (listings), or 0
F KB_rank, 4            # KRANK_*
F KB_seq, 4             # order of making: earlier wins a tie
F KB_refused, 4         # KBR_*: why it never applies, or 0
F KB_pad, 4
ENDSTRUCT KB_SIZE
.equ KRANK_DEFAULT, 1           # an extension's [commands] default keys (v1)
.equ KRANK_BUILTIN, 2
.equ KRANK_EXT, 3               # an extension's [keys]
.equ KRANK_USER, 4
.equ KBR_COMMAND, 1             # names no command
.equ KBR_WHEN, 2                # its clause does not compile
.equ KBR_TYPING, 3              # an extension's typing key without a guard
.equ KBR_PREFIX, 4              # a chord's first stroke without ctrl, alt or super
.equ KBR_STROKES, 5             # not one or two strokes
.equ KBR_ARGS, 6                # ARGS over 4096 bytes
.equ KEY_ARGS_MAX, 4096
.equ CHORD_FALLBACK_MS, 1000    # a pause runs the single-stroke binding of the first stroke
.equ CHORD_WAIT_MS, 5000
# an extension's [keys] line, kept from its manifest (kx_lines[extension index])
.equ KX_keys, 0                 # owned cstr
.equ KX_val, 8                  # owned cstr
.equ KX_SIZE, 16
.equ KX_MAX, 128                # lines per extension

.bss
.p2align 3
bindings: .zero VEC_SIZE        # KB records
kb_tmpl: .zero KB_SIZE          # the record being made
kb_seq: .long 0
kb_err: .long 0
.p2align 3
kx_lines: .zero EXT_CAP * VEC_SIZE
keys_hit: .quad 0               # the binding keys_lookup found (its ARGS go with keys_run)
kl_chord: .long 0               # keys_lookup found a chord's first stroke: keys_run begins it
kl_mods: .long 0
kl_key: .long 0
.p2align 3
kl_fallback: .quad 0
chord_on: .long 0               # a chord waits for its second stroke
chord_mods: .long 0
chord_key: .long 0
.p2align 3
chord_fallback: .quad 0         # KB* run when the pause ends, or 0
chord_deadline: .quad 0
.globl g_key_latin
g_key_latin: .long 0            # the platform's keysym of the same key on the first (Latin) layout, or 0
.p2align 3
ks_strings: .zero VEC_SIZE      # owned strings of the Keyboard Shortcuts list
ks_sb: .zero SB_SIZE
keybuf: .zero 128
keybuf2: .zero 256

.text

# parse_combo(ptr, len) -> eax keysym (0 if invalid), edx mods
FN parse_combo
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d              # mods
    xor r15d, r15d              # key
.Lpc_tok:
    test r13, r13
    jz .Lpc_done
    # token until '+' (a '+' right at the start of a token is the key itself)
    xor ecx, ecx
    cmp byte ptr [r12], '+'
    jne 1f
    mov ecx, 1
    jmp 2f
1:  cmp rcx, r13
    jae 2f
    cmp byte ptr [r12 + rcx], '+'
    je 2f
    inc rcx
    jmp 1b
2:  mov [rsp], rcx
    mov rdi, r12
    mov rsi, rcx
    call combo_token
    test edx, edx
    jz 3f
    or r14d, edx
    jmp 4f
3:  mov r15d, eax
4:  mov rcx, [rsp]
    add r12, rcx
    sub r13, rcx
    test r13, r13
    jz .Lpc_done
    cmp byte ptr [r12], '+'
    jne .Lpc_tok
    inc r12
    dec r13
    jmp .Lpc_tok
.Lpc_done:
    mov eax, r15d
    mov edx, r14d
    EPILOGUE

# combo_token(ptr, len) -> edx mod bit if a modifier, else eax keysym
combo_token:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + mod_names]
1:  mov rdx, [rbx]
    test rdx, rdx
    jz 2f
    mov rdi, r12
    mov rsi, r13
    call str_ieq_cstr
    test eax, eax
    jnz 3f
    add rbx, 16
    jmp 1b
3:  mov edx, [rbx + 8]
    xor eax, eax
    EPILOGUE
2:  lea rbx, [rip + key_names]
4:  mov rdx, [rbx]
    test rdx, rdx
    jz 5f
    mov rdi, r12
    mov rsi, r13
    call str_ieq_cstr
    test eax, eax
    jnz 6f
    add rbx, 16
    jmp 4b
6:  mov eax, [rbx + 8]
    xor edx, edx
    EPILOGUE
5:  # single character (lowercased), else any keysym name
    xor edx, edx
    cmp r13, 1
    jne 7f
    movzx edi, byte ptr [r12]
    call to_lower
    xor edx, edx
    EPILOGUE
7:  mov rdi, r12
    mov rsi, r13
    call keysym_value
    xor edx, edx
    EPILOGUE

# str_ieq_cstr(ptr, len, cstr) -> 1 if equal ignoring ascii case
FN str_ieq_cstr
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, rax
    call str_ieq
    pop r13
    pop r12
    pop rbx
    ret

# cmd_find(ptr, len) -> CMD* or 0
FN cmd_find
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + g_commands]
1:  mov rdx, [rbx + CMD_name]
    test rdx, rdx
    jz 2f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 3f
    add rbx, CMD_SIZE
    jmp 1b
2:  mov rdi, r12
    mov rsi, r13
    call ext_cmd_find
    mov rbx, rax
3:  mov rax, rbx
    EPILOGUE

# cmd_for_fn(fn) -> the command that runs fn, or 0
FN cmd_for_fn
    lea rax, [rip + g_commands]
1:  cmp qword ptr [rax + CMD_name], 0
    je 2f
    cmp [rax + CMD_fn], rdi
    je 3f
    add rax, CMD_SIZE
    jmp 1b
2:  xor eax, eax
3:  ret


# builtin_find(ptr, len) -> CMD* of a built-in command, or 0
builtin_find:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rbx, [rip + g_commands]
1:  mov rdx, [rbx + CMD_name]
    test rdx, rdx
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 9f
    add rbx, CMD_SIZE
    jmp 1b
8:  xor ebx, ebx
9:  mov rax, rbx
    EPILOGUE

# ---------------------------------------------------------------- making bindings

# kb_strokes(ptr, len) -> eax 1 with kb_tmpl's strokes (and KB_text) set from "STROKE [STROKE]",
#   an optional linux: / mac: / windows: first limiting it to one system (edx 1: another system)
kb_strokes:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    call trim
    mov r12, rax
    mov r13, rdx
    # a system prefix
    xor r15d, r15d              # 1: for another system
    lea rbx, [rip + sys_prefixes]
1:  mov rdx, [rbx]
    test rdx, rdx
    jz 3f
    mov rdi, rdx
    call strlen
    mov r14, rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rbx]
    mov rcx, r14
    call str_starts
    test eax, eax
    jnz 2f
    add rbx, 16
    jmp 1b
2:  add r12, r14
    sub r13, r14
    cmp qword ptr [rbx + 8], 0
    jne 3f
    mov r15d, 1
3:  mov rdi, [rip + kb_tmpl + KB_text]
    call mem_free
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rip + kb_tmpl + KB_text], rax
    xor eax, eax
    mov [rip + kb_tmpl + KB_key2], eax
    mov [rip + kb_tmpl + KB_mods2], eax
    # the first stroke
    mov rdi, r12
    mov rsi, r13
    call next_word
    test rdx, rdx
    jz 8f
    mov [rsp], rcx
    mov rdi, rax
    mov rsi, rdx
    call parse_combo
    test eax, eax
    jz 8f
    mov [rip + kb_tmpl + KB_key], eax
    mov [rip + kb_tmpl + KB_mods], edx
    add r12, [rsp]
    sub r13, [rsp]
    # the second, if any; nothing after it
    mov rdi, r12
    mov rsi, r13
    call next_word
    test rdx, rdx
    jz 7f
    mov [rsp], rcx
    mov rdi, rax
    mov rsi, rdx
    call parse_combo
    test eax, eax
    jz 8f
    mov [rip + kb_tmpl + KB_key2], eax
    mov [rip + kb_tmpl + KB_mods2], edx
    add r12, [rsp]
    sub r13, [rsp]
    mov rdi, r12
    mov rsi, r13
    call next_word
    test rdx, rdx
    jnz 8f
7:  mov eax, 1
    mov edx, r15d
    EPILOGUE
8:  xor eax, eax
    mov edx, r15d
    EPILOGUE

# kb_value(ptr, len, ext, own) -> eax 0, or KBR_COMMAND / KBR_WHEN: kb_tmpl's command, ARGS and
#   clause from "COMMAND [ARGS] [when CLAUSE]". own 1: a manifest's, where NAME is its own command
#   and rhun.NAME a built-in
kb_value:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov rbx, rdx
    mov [rsp + 24], ecx
    mov rdi, r12
    mov rsi, r13
    call trim
    mov r12, rax
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    call next_word
    mov r14, rax                # the command
    mov r15, rdx
    add r12, rcx
    sub r13, rcx
    mov rdi, [rip + kb_tmpl + KB_name]
    call mem_free
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov [rip + kb_tmpl + KB_name], rax
    # ARGS up to " when ", the clause after it
    mov rdi, r12
    mov rsi, r13
    call trim
    mov r12, rax
    mov r13, rdx
    mov [rsp], rax              # ARGS
    mov [rsp + 8], rdx
    mov qword ptr [rsp + 16], 0 # the clause's start
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lwhen_sp]
    mov ecx, 5
    call str_starts
    test eax, eax
    jz 1f
    mov qword ptr [rsp + 8], 0
    lea rax, [r12 + 5]
    mov [rsp + 16], rax
    jmp 2f
1:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lsp_when_sp]
    mov ecx, 6
    call str_find
    test rax, rax
    js 2f
    mov [rsp + 8], rax
    lea rax, [r12 + rax + 6]
    mov [rsp + 16], rax
2:  # ARGS
    mov qword ptr [rip + kb_tmpl + KB_args], 0
    mov qword ptr [rip + kb_tmpl + KB_alen], 0
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call trim
    test rdx, rdx
    jz 3f
    cmp rdx, KEY_ARGS_MAX
    ja .Lkv_args
    mov [rip + kb_tmpl + KB_alen], rdx
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + kb_tmpl + KB_args], rax
3:  # the clause
    mov qword ptr [rip + kb_tmpl + KB_when], 0
    mov rdi, [rsp + 16]
    test rdi, rdi
    jz 4f
    lea rsi, [r12 + r13]
    sub rsi, rdi
    call trim
    mov rdi, rax
    mov rsi, rdx
    mov rdx, rbx
    call when_compile
    test rax, rax
    jz .Lkv_when
    mov [rip + kb_tmpl + KB_when], rax
4:  # the command: none, rhun.NAME, NAME (own, in a manifest) or any command's name
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lnone_word]
    call str_eq_cstr
    test eax, eax
    lea rax, [rip + none_cmd]
    jnz 7f
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lrhun_dot]
    mov ecx, 5
    call str_starts
    test eax, eax
    jz 5f
    lea rdi, [r14 + 5]
    lea rsi, [r15 - 5]
    call builtin_find
    jmp 6f
5:  cmp dword ptr [rsp + 24], 0
    je 51f
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Ldot]
    mov ecx, 1
    call str_find
    test rax, rax
    jns 51f
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call ext_cmd_local
    jmp 6f
51: mov rdi, r14
    mov rsi, r15
    call cmd_find
6:  test rax, rax
    jz .Lkv_command
7:  mov [rip + kb_tmpl + KB_cmd], rax
    xor eax, eax
    EPILOGUE
.Lkv_command:
    mov eax, KBR_COMMAND
    EPILOGUE
.Lkv_when:
    mov eax, KBR_WHEN
    EPILOGUE
.Lkv_args:
    mov eax, KBR_ARGS
    EPILOGUE

# kb_push(rank, ext, refused) -> rax the new binding, from kb_tmpl (which gives up its strings)
kb_push:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    mov r14d, edx
    lea rdi, [rip + bindings]
    mov esi, KB_SIZE
    call vec_push
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + kb_tmpl]
    mov edx, KB_SIZE
    call memcpy
    mov [rbx + KB_rank], r12d
    mov [rbx + KB_ext], r13
    mov [rbx + KB_refused], r14d
    inc dword ptr [rip + kb_seq]
    mov eax, [rip + kb_seq]
    mov [rbx + KB_seq], eax
    lea rdi, [rip + kb_tmpl]
    xor esi, esi
    mov edx, KB_SIZE
    call memset
    mov rax, rbx
    EPILOGUE

# kb_tmpl_clear(): drop what kb_tmpl holds (a line that made no binding)
kb_tmpl_clear:
    push rbx
    mov rdi, [rip + kb_tmpl + KB_text]
    call mem_free
    mov rdi, [rip + kb_tmpl + KB_name]
    call mem_free
    mov rdi, [rip + kb_tmpl + KB_args]
    call mem_free
    mov rdi, [rip + kb_tmpl + KB_when]
    call when_free
    lea rdi, [rip + kb_tmpl]
    xor esi, esi
    mov edx, KB_SIZE
    call memset
    pop rbx
    ret

# kb_default_list(cmd, keys cstr, rank, ext): each space-separated stroke of a command's default
#   keys; an extension's (rank DEFAULT) needs a modifier
kb_default_list:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], edx
    mov [rsp + 8], rcx
    mov rdi, r12
    call strlen
    mov r13, rax
1:  test r13, r13
    jz 9f
    mov rdi, r12
    mov rsi, r13
    call next_word
    add r12, rcx
    sub r13, rcx
    test rdx, rdx
    jz 9f
    mov r14, rax
    mov r15, rdx
    mov rdi, rax
    mov rsi, rdx
    call parse_combo
    test eax, eax
    jz 1b
    cmp dword ptr [rsp], KRANK_DEFAULT
    jne 2f
    test edx, edx               # a bare key would take typing away from the editor
    jz 1b
2:  mov [rip + kb_tmpl + KB_key], eax
    mov [rip + kb_tmpl + KB_mods], edx
    mov [rip + kb_tmpl + KB_cmd], rbx
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov [rip + kb_tmpl + KB_text], rax
    mov edi, [rsp]
    mov rsi, [rsp + 8]
    xor edx, edx
    call kb_push
    jmp 1b
9:  EPILOGUE

# kb_typing(key, mods) -> eax 1 for a key that types or edits when no ctrl, alt or super is held
kb_typing:
    xor eax, eax
    test esi, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz 9f
    cmp edi, 0x100
    jb 8f
    cmp edi, 0x1000000          # Unicode keysyms
    jae 8f
    lea rcx, [rip + typing_keys]
1:  mov edx, [rcx]
    test edx, edx
    jz 9f
    add rcx, 4
    cmp edx, edi
    jne 1b
8:  mov eax, 1
9:  ret

# kb_guarded(wc) -> eax 1 when the clause keeps the binding away from text fields: a top-level
#   && term !textInputFocus, viewFocus or view == ...
kb_guarded:
    PROLOGUE
    xor eax, eax
    test rdi, rdi
    jz 9f
    call when_source
    mov r12, rax
    lea r13, [rax + rdx]
    # a top-level || makes nothing certain
    xor ecx, ecx                # depth
    mov rax, r12
1:  cmp rax, r13
    jae 3f
    movzx edx, byte ptr [rax]
    cmp edx, '('
    jne 11f
    inc ecx
11: cmp edx, ')'
    jne 12f
    dec ecx
12: test ecx, ecx
    jnz 2f
    cmp edx, '|'
    je 8f
2:  inc rax
    jmp 1b
3:  # the terms between top-level &&
    mov r14, r12                # the term's start
    mov rax, r12
    xor ecx, ecx
4:  cmp rax, r13
    jae 5f
    movzx edx, byte ptr [rax]
    cmp edx, '('
    jne 41f
    inc ecx
41: cmp edx, ')'
    jne 42f
    dec ecx
42: test ecx, ecx
    jnz 43f
    cmp edx, '&'
    jne 43f
    mov r15, rax
    push rax
    push rcx
    mov rdi, r14
    mov rsi, r15
    sub rsi, r14
    call kb_guard_term
    pop rcx
    pop rdx
    test eax, eax
    jnz 9f
    lea rax, [rdx + 2]
    mov r14, rax
    jmp 4b
43: inc rax
    jmp 4b
5:  mov rdi, r14
    mov rsi, r13
    sub rsi, r14
    call kb_guard_term
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE
# kb_guard_term(ptr, len) -> eax 1 for !textInputFocus, viewFocus or view == ...
kb_guard_term:
    PROLOGUE
    call trim
    mov r12, rax
    mov r13, rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lg_not_text]
    call str_eq_cstr
    test eax, eax
    jnz 9f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lg_view_focus]
    call str_eq_cstr
    test eax, eax
    jnz 9f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lg_view_eq]
    mov ecx, 4
    call str_starts
    test eax, eax
    jz 9f
    # "view" then spaces, then ==
    lea rax, [r12 + 4]
    lea rcx, [r12 + r13]
1:  cmp rax, rcx
    jae 8f
    cmp byte ptr [rax], ' '
    jne 2f
    inc rax
    jmp 1b
2:  lea rdx, [rax + 1]
    cmp rdx, rcx
    jae 8f
    cmp word ptr [rax], 0x3d3d  # "=="
    jne 8f
    # and a view's identity: not empty (the text editor's view is ''), not '' or ""
    lea rdi, [rax + 2]
    mov rsi, rcx
    sub rsi, rdi
    call trim
    test rdx, rdx
    jz 8f
    cmp rdx, 2
    jne 3f
    movzx ecx, byte ptr [rax]
    cmp cl, [rax + 1]
    jne 3f
    cmp ecx, 0x27
    je 8f
    cmp ecx, '"'
    je 8f
3:  mov eax, 1
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE

# kb_manifest(ext, line): an extension's [keys] line as a binding (rank EXT), checked
kb_manifest:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [r12 + KX_keys]
    call strlen
    mov rsi, rax
    mov rdi, [r12 + KX_keys]
    call kb_strokes
    test edx, edx
    jnz .Lkm_skip                # for another system
    mov r13d, KBR_STROKES
    test eax, eax
    jz .Lkm_push
    mov rdi, [r12 + KX_val]
    call strlen
    mov rsi, rax
    mov rdi, [r12 + KX_val]
    mov rdx, rbx
    mov ecx, 1
    call kb_value
    mov r13d, eax
    test eax, eax
    jnz .Lkm_push
    # a chord starts with ctrl, alt or super; a typing key needs a guard
    cmp dword ptr [rip + kb_tmpl + KB_key2], 0
    je 1f
    mov r13d, KBR_PREFIX
    test dword ptr [rip + kb_tmpl + KB_mods], MOD_CTRL | MOD_ALT | MOD_SUPER
    jz .Lkm_push
    xor r13d, r13d
    jmp .Lkm_push
1:  mov edi, [rip + kb_tmpl + KB_key]
    mov esi, [rip + kb_tmpl + KB_mods]
    call kb_typing
    test eax, eax
    jz .Lkm_push
    mov rdi, [rip + kb_tmpl + KB_when]
    call kb_guarded
    mov r13d, KBR_TYPING
    test eax, eax
    jz .Lkm_push
    xor r13d, r13d
.Lkm_push:
    mov edi, KRANK_EXT
    mov rsi, rbx
    mov edx, r13d
    call kb_push
    EPILOGUE
.Lkm_skip:
    call kb_tmpl_clear
    EPILOGUE

# kb_free_all(): every binding's strings go and the list empties
kb_free_all:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + bindings + VEC_len]
    jae 2f
    imul r12, rbx, KB_SIZE
    add r12, [rip + bindings + VEC_ptr]
    inc rbx
    mov rdi, [r12 + KB_when]
    call when_free
    mov rdi, [r12 + KB_args]
    call mem_free
    mov rdi, [r12 + KB_text]
    call mem_free
    mov rdi, [r12 + KB_name]
    call mem_free
    jmp 1b
2:  mov qword ptr [rip + bindings + VEC_len], 0
    mov qword ptr [rip + keys_hit], 0
    mov dword ptr [rip + kl_chord], 0
    mov qword ptr [rip + kl_fallback], 0
    mov dword ptr [rip + kb_seq], 0
    EPILOGUE

# keys_reload(): bindings from scratch (the config file or the commands changed)
FN keys_reload
    PROLOGUE
    call keys_chord_cancel
    call kb_free_all
    call palette_close_keys     # the Keyboard Shortcuts list holds bindings
    call keys_build
    EPILOGUE

# keys_init(): the bindings, first time
FN keys_init
    jmp keys_reload

# keys_build(): built-in defaults and chords, extensions' defaults and [keys], the user's [keys]
keys_build:
    PROLOGUE 16
    lea rbx, [rip + g_commands]
1:  cmp qword ptr [rbx + CMD_name], 0
    je 2f
    mov rdi, rbx
    mov rsi, [rbx + CMD_keys]
    mov edx, KRANK_BUILTIN
    xor ecx, ecx
    call kb_default_list
    add rbx, CMD_SIZE
    jmp 1b
2:  # built-in chords
    lea rbx, [rip + builtin_chords]
3:  mov rdi, [rbx]
    test rdi, rdi
    jz 4f
    call strlen
    mov rsi, rax
    mov rdi, [rbx]
    call builtin_find
    test rax, rax
    jz 31f
    mov [rip + kb_tmpl + KB_cmd], rax
    mov rdi, [rbx + 8]
    call strlen
    mov rsi, rax
    mov rdi, [rbx + 8]
    call kb_strokes
    mov edi, KRANK_BUILTIN
    xor esi, esi
    xor edx, edx
    call kb_push
31: add rbx, 16
    jmp 3b
4:  # the extensions' default keys ([commands], v1)
    xor r14d, r14d
5:  cmp r14, [rip + g_ext_cmds + VEC_len]
    jae 6f
    mov rdi, r14
    call ext_cmd_live
    imul rbx, r14, CMD_SIZE
    add rbx, [rip + g_ext_cmds + VEC_ptr]
    inc r14
    test eax, eax
    jz 5b
    mov rdi, rbx
    call ext_cmd_owner
    mov rcx, rax
    mov rdi, rbx
    mov rsi, [rbx + CMD_keys]
    mov edx, KRANK_DEFAULT
    call kb_default_list
    jmp 5b
6:  # the extensions' [keys]
    xor r14d, r14d
7:  cmp r14, [rip + g_exts + VEC_len]
    jae .Lkb_user
    imul r12, r14, EXT_SIZE
    add r12, [rip + g_exts + VEC_ptr]
    imul r13, r14, VEC_SIZE
    lea rax, [rip + kx_lines]
    add r13, rax
    inc r14
    mov rdi, r12
    call ext_is_visible
    test eax, eax
    jz 7b
    xor r15d, r15d
8:  cmp r15, [r13 + VEC_len]
    jae 7b
    imul rsi, r15, KX_SIZE
    add rsi, [r13 + VEC_ptr]
    inc r15
    mov rdi, r12
    call kb_manifest
    jmp 8b
.Lkb_user:
    xor r14d, r14d
1:  cmp r14, [rip + g_keylines + VEC_len]
    jae 9f
    mov r15, r14
    shl r15, 5
    add r15, [rip + g_keylines + VEC_ptr]
    inc r14
    mov rdi, [r15]
    mov rsi, [r15 + 8]
    call kb_strokes
    test edx, edx
    jnz 3f
    mov ebx, KBR_STROKES
    test eax, eax
    jz 2f
    mov rdi, [r15 + 16]
    mov rsi, [r15 + 24]
    xor edx, edx
    xor ecx, ecx
    call kb_value
    mov ebx, eax
2:  mov edi, KRANK_USER
    xor esi, esi
    mov edx, ebx
    call kb_push
    jmp 1b
3:  call kb_tmpl_clear
    jmp 1b
9:  EPILOGUE

# ---------------------------------------------------------------- an extension's [keys]

# kx_vec(ext) -> rax its kept [keys] lines, or 0
kx_vec:
    mov rax, rdi
    sub rax, [rip + g_exts + VEC_ptr]
    jb 8f
    xor edx, edx
    mov ecx, EXT_SIZE
    div rcx
    cmp rax, EXT_CAP
    jae 8f
    imul rax, rax, VEC_SIZE
    lea rcx, [rip + kx_lines]
    add rax, rcx
    ret
8:  xor eax, eax
    ret

# FN keys_manifest_line(ext, ini): a [keys] line of its manifest, made a binding at the next reload
FN keys_manifest_line
    PROLOGUE
    mov rbx, rsi
    call kx_vec
    test rax, rax
    jz 9f
    mov r12, rax
    cmp qword ptr [r12 + VEC_len], KX_MAX
    jae 9f
    mov rdi, r12
    mov esi, KX_SIZE
    call vec_push
    mov r13, rax
    mov rdi, [rbx + INI_key]
    mov rsi, [rbx + INI_keylen]
    call mem_dup
    mov [r13 + KX_keys], rax
    mov rdi, [rbx + INI_val]
    mov rsi, [rbx + INI_vallen]
    call mem_dup
    mov [r13 + KX_val], rax
9:  EPILOGUE

# FN keys_manifest_clear(ext): its [keys] lines go (it was removed)
FN keys_manifest_clear
    PROLOGUE
    call kx_vec
    test rax, rax
    jz 9f
    mov rbx, rax
    xor r12d, r12d
1:  cmp r12, [rbx + VEC_len]
    jae 2f
    imul r13, r12, KX_SIZE
    add r13, [rbx + VEC_ptr]
    inc r12
    mov rdi, [r13 + KX_keys]
    call mem_free
    mov rdi, [r13 + KX_val]
    call mem_free
    jmp 1b
2:  mov qword ptr [rbx + VEC_len], 0
9:  EPILOGUE

# ---------------------------------------------------------------- finding a key's binding

# kb_better(a, b) -> eax 1 when binding a wins over b (b 0: always): rank, then order
kb_better:
    mov eax, 1
    test rsi, rsi
    jz 9f
    mov ecx, [rdi + KB_rank]
    cmp ecx, [rsi + KB_rank]
    ja 9f
    jb 8f
    mov ecx, [rdi + KB_seq]
    cmp ecx, [rsi + KB_seq]
    jb 9f
8:  xor eax, eax
9:  ret

# kb_live(kb) -> eax 1 when the binding applies now: not refused, its extension on, its clause
#   true and its command enabled (keys as of the last ctx_refresh)
kb_live:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    cmp dword ptr [rbx + KB_refused], 0
    jne 9f
    mov rdi, [rbx + KB_ext]
    test rdi, rdi
    jz 1f
    cmp dword ptr [rdi + EXT_disabled], 0
    jne 8f
    call ext_is_visible
    test eax, eax
    jz 9f
1:  mov rdi, [rbx + KB_when]
    test rdi, rdi
    jz 2f
    call when_eval_fresh
    test eax, eax
    jz 9f
2:  mov rdi, [rbx + KB_cmd]
    call cmd_enabled
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE

# kb_norm(keysym) -> eax as bindings hold it: letters lowercase, ISO_Left_Tab as Tab
kb_norm:
    mov eax, edi
    lea ecx, [rdi - 'A']
    cmp ecx, 25
    ja 1f
    or eax, 0x20
1:  cmp eax, KEY_ISO_LEFT_TAB
    jne 2f
    mov eax, KEY_TAB
2:  ret

# keys_lookup(keysym, mods) -> rax handler fn or 0, rdx its CMD* (callers pass it in rdi, or call
#   keys_run). A key that starts a chord gives rax keys_chord_start and rdx 0.
FN keys_lookup
    PROLOGUE 16
    mov r13d, esi
    call kb_norm
    mov r12d, eax
    mov edi, [rip + g_key_latin]
    call kb_norm
    mov r14d, eax               # the same key on the Latin layout, matched second
    cmp r14d, r12d
    jne 1f
    xor r14d, r14d
1:  mov dword ptr [rip + kl_chord], 0
    call ctx_refresh
    xor r15d, r15d              # the best single stroke
    mov qword ptr [rsp], 0      # the best chord
    xor ebx, ebx
2:  cmp rbx, [rip + bindings + VEC_len]
    jae 5f
    imul rdi, rbx, KB_SIZE
    add rdi, [rip + bindings + VEC_ptr]
    inc rbx
    cmp [rdi + KB_mods], r13d
    jne 2b
    mov eax, [rdi + KB_key]
    cmp eax, r12d
    je 3f
    test r14d, r14d
    jz 2b
    cmp eax, r14d
    jne 2b
3:  mov [rsp + 8], rdi
    call kb_live
    test eax, eax
    jz 2b
    mov rdi, [rsp + 8]
    cmp dword ptr [rdi + KB_key2], 0
    jne 4f
    mov rsi, r15
    call kb_better
    test eax, eax
    jz 2b
    mov r15, [rsp + 8]
    jmp 2b
4:  mov rsi, [rsp]
    call kb_better
    test eax, eax
    jz 2b
    mov rax, [rsp + 8]
    mov [rsp], rax
    jmp 2b
5:  mov rax, [rsp]
    test rax, rax
    jz 6f
    # a chord, unless a single stroke of a higher rank takes the key
    test r15, r15
    jz 51f
    mov ecx, [r15 + KB_rank]
    cmp ecx, [rax + KB_rank]
    ja 6f
51: mov dword ptr [rip + kl_chord], 1
    mov ecx, [rax + KB_mods]
    mov [rip + kl_mods], ecx
    mov ecx, [rax + KB_key]
    mov [rip + kl_key], ecx
    mov [rip + kl_fallback], r15
    mov qword ptr [rip + keys_hit], 0
    lea rax, [rip + keys_chord_start]
    xor edx, edx
    EPILOGUE
6:  mov [rip + keys_hit], r15
    test r15, r15
    jz 7f
    mov rdx, [r15 + KB_cmd]
    mov rax, [rdx + CMD_fn]
    EPILOGUE
7:  xor eax, eax
    xor edx, edx
    EPILOGUE

# FN keys_run(cmd*): run what keys_lookup found, as invoked by a key (FROM key, the binding's ARGS
#   as the body); 0 begins the chord it found
FN keys_run
    test rdi, rdi
    jz keys_chord_start
    mov rax, [rip + keys_hit]
    xor edx, edx
    xor ecx, ecx
    test rax, rax
    jz 1f
    cmp [rax + KB_cmd], rdi
    jne 1f
    mov rdx, [rax + KB_args]
    mov rcx, [rax + KB_alen]
1:  mov esi, INV_KEY
    xor r8d, r8d
    jmp cmd_invoke

# kb_run(kb): run a binding's command with its ARGS
kb_run:
    mov [rip + keys_hit], rdi
    mov rdx, [rdi + KB_args]
    mov rcx, [rdi + KB_alen]
    mov rdi, [rdi + KB_cmd]
    mov esi, INV_KEY
    xor r8d, r8d
    jmp cmd_invoke

# ---------------------------------------------------------------- chords

# FN keys_chord_start(): the chord keys_lookup found waits for its second stroke
FN keys_chord_start
    cmp dword ptr [rip + kl_chord], 0
    je 9f
    mov dword ptr [rip + kl_chord], 0
    PROLOGUE
    mov eax, [rip + kl_mods]
    mov [rip + chord_mods], eax
    mov eax, [rip + kl_key]
    mov [rip + chord_key], eax
    mov rax, [rip + kl_fallback]
    mov [rip + chord_fallback], rax
    call time_ms
    mov ecx, CHORD_WAIT_MS
    cmp qword ptr [rip + chord_fallback], 0
    je 1f
    mov ecx, CHORD_FALLBACK_MS
1:  add rax, rcx
    mov [rip + chord_deadline], rax
    mov dword ptr [rip + chord_on], 1
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
9:  ret

# FN keys_chord_cancel(): no chord waits any more (a click, a focus change, Escape)
FN keys_chord_cancel
    cmp dword ptr [rip + chord_on], 0
    je 1f
    mov dword ptr [rip + chord_on], 0
    mov qword ptr [rip + chord_fallback], 0
    mov dword ptr [rip + g_dirty], 1
1:  ret

# FN keys_chord_pending() -> eax 1 while a chord waits (platforms route every key to app_on_key)
FN keys_chord_pending
    mov eax, [rip + chord_on]
    ret

# FN keys_chord_key(keysym, cp, mods) -> eax 1 when a waiting chord took the key: its second stroke
#   runs the binding; Escape ends it; another key ends it with a toast; modifiers alone wait on
FN keys_chord_key
    xor eax, eax
    cmp dword ptr [rip + chord_on], 0
    je 9f
    PROLOGUE 16
    mov r13d, edx
    # a modifier alone (Shift, Control, Alt, Super, AltGr) is part of the next stroke
    lea eax, [rdi - 0xffe1]
    cmp eax, 0xffee - 0xffe1
    jbe .Lck_yes
    cmp edi, 0xfe03
    je .Lck_yes
    cmp edi, 0xff7e
    je .Lck_yes
    call kb_norm
    mov r12d, eax
    cmp r12d, KEY_ESCAPE
    jne 1f
    test r13d, r13d
    jnz 1f
    call keys_chord_cancel
    jmp .Lck_yes
1:  mov edi, [rip + g_key_latin]
    call kb_norm
    mov r14d, eax
    cmp r14d, r12d
    jne 2f
    xor r14d, r14d
2:  call ctx_refresh
    xor r15d, r15d
    xor ebx, ebx
3:  cmp rbx, [rip + bindings + VEC_len]
    jae 6f
    imul rdi, rbx, KB_SIZE
    add rdi, [rip + bindings + VEC_ptr]
    inc rbx
    cmp dword ptr [rdi + KB_key2], 0
    je 3b
    mov eax, [rip + chord_key]
    cmp [rdi + KB_key], eax
    jne 3b
    mov eax, [rip + chord_mods]
    cmp [rdi + KB_mods], eax
    jne 3b
    cmp [rdi + KB_mods2], r13d
    jne 3b
    mov eax, [rdi + KB_key2]
    cmp eax, r12d
    je 4f
    test r14d, r14d
    jz 3b
    cmp eax, r14d
    jne 3b
4:  mov [rsp], rdi
    call kb_live
    test eax, eax
    jz 3b
    mov rdi, [rsp]
    mov rsi, r15
    call kb_better
    test eax, eax
    jz 3b
    mov r15, [rsp]
    jmp 3b
6:  # the chord's text for a toast, before it ends
    test r15, r15
    jnz 7f
    lea rdi, [rip + keybuf2]
    mov esi, [rip + chord_mods]
    mov edx, [rip + chord_key]
    call fmt_stroke
    mov byte ptr [rax], ' '
    lea rdi, [rax + 1]
    mov esi, r13d
    mov edx, r12d
    call fmt_stroke
    lea rdi, [rax]
    lea rsi, [rip + .Lnot_bound]
    call cstr_copy
    call keys_chord_cancel
    lea rdi, [rip + keybuf2]
    call app_toast
    jmp .Lck_yes
7:  call keys_chord_cancel
    mov rdi, r15
    call kb_run
.Lck_yes:
    mov eax, 1
    EPILOGUE
9:  ret

# FN keys_tick(): a chord's pause ends: its fallback runs, or it just ends
FN keys_tick
    cmp dword ptr [rip + chord_on], 0
    je 9f
    PROLOGUE
    call time_ms
    cmp rax, [rip + chord_deadline]
    jb 8f
    mov rbx, [rip + chord_fallback]
    call keys_chord_cancel
    test rbx, rbx
    jz 8f
    mov rdi, rbx
    call kb_run
8:  EPILOGUE
9:  ret

# FN keys_timeout() -> eax milliseconds until the chord's pause ends, or -1
FN keys_timeout
    mov eax, -1
    cmp dword ptr [rip + chord_on], 0
    je 9f
    push rbx
    call time_ms
    mov rcx, [rip + chord_deadline]
    sub rcx, rax
    jns 1f
    xor ecx, ecx
1:  mov eax, ecx
    pop rbx
9:  ret

# FN keys_chord_draw(x, y, h) -> eax the x after it: "Ctrl+K — waiting for the next key" (or
#   "... , or pause for Select Color Theme"), in the accent color, while a chord waits; else x
FN keys_chord_draw
    mov eax, edi
    cmp dword ptr [rip + chord_on], 0
    je 9f
    PROLOGUE 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    lea rdi, [rip + keybuf2]
    mov esi, [rip + chord_mods]
    mov edx, [rip + chord_key]
    call fmt_stroke
    mov rdi, rax
    lea rsi, [rip + .Lwaiting]
    call cstr_copy
    mov rbx, [rip + chord_fallback]
    test rbx, rbx
    jz 1f
    mov rdi, rax
    lea rsi, [rip + .Lor_pause]
    call cstr_copy
    mov rdi, rax
    mov rcx, [rbx + KB_cmd]
    mov rsi, [rcx + CMD_title]
    call kb_copy_tail           # a long title is cut to what keybuf2 holds
1:  lea rdi, [rip + g_face_small]
    mov esi, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    lea r8, [rip + keybuf2]
    COLOR r9d, T_ACCENT
    call ui_text_c
    EPILOGUE
9:  ret

# kb_copy_tail(dst in keybuf2, cstr): as much of it as keybuf2 still holds, cut at a character's
#   start, NUL-ended
kb_copy_tail:
    lea rcx, [rip + keybuf2 + 255]
    xor edx, edx
    sub rcx, rdi                # room before the NUL
    jbe 3f
1:  cmp rdx, rcx
    jae 2f
    mov al, [rsi + rdx]
    test al, al
    jz 3f
    mov [rdi + rdx], al
    inc rdx
    jmp 1b
2:  # cut inside a character (the next byte continues it): that character goes
    mov al, [rsi + rdx]
    and al, 0xc0
    cmp al, 0x80
    jne 3f
21: test rdx, rdx
    jz 3f
    dec rdx
    mov al, [rdi + rdx]
    and al, 0xc0
    cmp al, 0x80
    je 21b
3:  mov byte ptr [rdi + rdx], 0
    lea rax, [rdi + rdx]
    ret

# ---------------------------------------------------------------- showing bindings

# fmt_stroke(dst, mods, key) -> rax the NUL after "Ctrl+Shift+P" (macOS: symbols, Command for Ctrl)
fmt_stroke:
    PROLOGUE
    mov r13, rdi
    mov r14d, esi
    mov r15d, edx
.ifdef MACOS
    # Tab, backtick and bare H stay Control: their Command shortcuts belong to the system
    test r14d, MOD_CTRL
    jz 21f
    cmp r15d, KEY_TAB
    je 20f
    cmp r15d, '`'
    je 20f
    cmp r15d, 'h'
    jne 21f
    cmp r14d, MOD_CTRL
    jne 21f
20: lea rsi, [rip + .Lmac_control]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
    and r14d, ~MOD_CTRL
21: test r14d, MOD_ALT
    jz 22f
    lea rsi, [rip + .Lmac_option]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
22: test r14d, MOD_SHIFT
    jz 23f
    lea rsi, [rip + .Lmac_shift]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
23: test r14d, MOD_CTRL
    jz 24f
    lea rsi, [rip + .Lmac_command]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
24: # arrows as arrows, punctuation as itself
    lea rbx, [rip + mac_key_syms]
25: cmp qword ptr [rbx], 0
    je 6f
    cmp [rbx + 8], r15d
    je 72f
    add rbx, 16
    jmp 25b
.endif
    test r14d, MOD_CTRL
    jz 3f
    lea rsi, [rip + .Lctrl]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
3:  test r14d, MOD_SHIFT
    jz 4f
    lea rsi, [rip + .Lshift]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
4:  test r14d, MOD_ALT
    jz 5f
    lea rsi, [rip + .Lalt]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
5:  test r14d, MOD_SUPER
    jz 6f
    lea rsi, [rip + .Lsuper]
    mov rdi, r13
    call cstr_copy
    mov r13, rax
6:  # the key's name, or its character capitalized
    lea rbx, [rip + key_names]
7:  cmp qword ptr [rbx], 0
    je 71f
    cmp [rbx + 8], r15d
    je 72f
    add rbx, 16
    jmp 7b
72: mov rsi, [rbx]
    mov rdi, r13
    call cstr_copy
    EPILOGUE
71: mov eax, r15d
    cmp eax, 0x80
    jb 73f
    mov eax, '?'
73: lea ecx, [rax - 'a']
    cmp ecx, 25
    ja 74f
    sub eax, 32
74: mov [r13], al
    mov byte ptr [r13 + 1], 0
    lea rax, [r13 + 1]
    EPILOGUE

# fmt_binding(dst, kb) -> rax the NUL after its strokes ("Ctrl+K Ctrl+C")
fmt_binding:
    push rbx
    mov rbx, rsi
    mov esi, [rbx + KB_mods]
    mov edx, [rbx + KB_key]
    call fmt_stroke
    cmp dword ptr [rbx + KB_key2], 0
    je 1f
    mov byte ptr [rax], ' '
    lea rdi, [rax + 1]
    mov esi, [rbx + KB_mods2]
    mov edx, [rbx + KB_key2]
    call fmt_stroke
1:  pop rbx
    ret

# kb_shadow(kb) -> rax the binding with the same strokes that wins over it (no clause, or the same
#   clause), or 0
kb_shadow:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + bindings + VEC_len]
    jae 8f
    imul r13, r12, KB_SIZE
    add r13, [rip + bindings + VEC_ptr]
    inc r12
    cmp r13, rbx
    je 1b
    cmp dword ptr [r13 + KB_refused], 0
    jne 1b
    mov rax, [r13 + KB_mods]    # mods and key
    cmp rax, [rbx + KB_mods]
    jne 1b
    mov rax, [r13 + KB_mods2]
    cmp rax, [rbx + KB_mods2]
    jne 1b
    mov rdi, r13
    mov rsi, rbx
    call kb_better
    test eax, eax
    jz 1b
    mov rdi, [r13 + KB_when]
    test rdi, rdi
    jz 9f
    mov rsi, [rbx + KB_when]
    test rsi, rsi
    jz 1b
    call when_source
    mov r14, rax
    mov r15, rdx
    mov rdi, [rbx + KB_when]
    call when_source
    mov rdi, r14
    mov rsi, r15
    mov rcx, rdx
    mov rdx, rax
    call str_eq
    test eax, eax
    jz 1b
9:  mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# keys_for(cmd*) -> its binding in force, formatted ("Ctrl+Shift+P", "Ctrl+K Ctrl+C"), or 0
FN keys_for
    PROLOGUE
    mov r12, rdi
    xor r13d, r13d              # the best
    xor ebx, ebx
1:  cmp rbx, [rip + bindings + VEC_len]
    jae 3f
    imul r14, rbx, KB_SIZE
    add r14, [rip + bindings + VEC_ptr]
    inc rbx
    cmp [r14 + KB_cmd], r12
    jne 1b
    cmp dword ptr [r14 + KB_refused], 0
    jne 1b
    mov rdi, r14
    mov rsi, r13
    call kb_better
    test eax, eax
    jz 1b
    mov rdi, r14
    call kb_shadow
    test rax, rax
    jnz 1b
    mov r13, r14
    jmp 1b
3:  test r13, r13
    jz 8f
    lea rdi, [rip + keybuf]
    mov rsi, r13
    call fmt_binding
    lea rax, [rip + keybuf]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# kb_source(sb, kb): "user", "builtin", "ext:OWNER/NAME" or "default:OWNER/NAME"
kb_source:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + KB_rank]
    lea rsi, [rip + .Ls_user]
    cmp eax, KRANK_USER
    je 1f
    lea rsi, [rip + .Ls_builtin]
    cmp eax, KRANK_BUILTIN
    je 1f
    lea rsi, [rip + .Ls_ext]
    cmp eax, KRANK_EXT
    je 2f
    lea rsi, [rip + .Ls_default]
2:  mov rdi, rbx
    call sb_push_cstr
    mov rax, [r12 + KB_ext]
    test rax, rax
    jz 9f
    mov rdi, rbx
    mov rsi, [rax + EXT_owner]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, '/'
    call sb_push_byte
    mov rax, [r12 + KB_ext]
    mov rdi, rbx
    mov rsi, [rax + EXT_name]
1:  call sb_push_cstr
9:  EPILOGUE

# kb_state(sb, kb): "active", "shadowed:SOURCE" or "refused:WHY"
kb_state:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + KB_refused]
    test eax, eax
    jz 1f
    mov rdi, rbx
    lea rsi, [rip + .Ls_refused]
    call sb_push_cstr
    mov eax, [r12 + KB_refused]
    dec eax
    lea rcx, [rip + refusal_names]
    mov rsi, [rcx + rax*8]
    mov rdi, rbx
    call sb_push_cstr
    EPILOGUE
1:  mov rdi, r12
    call kb_shadow
    test rax, rax
    jnz 2f
    mov rdi, rbx
    lea rsi, [rip + .Ls_active]
    call sb_push_cstr
    EPILOGUE
2:  mov r13, rax
    mov rdi, rbx
    lea rsi, [rip + .Ls_shadowed]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    call kb_source
    EPILOGUE

# kb_describe(sb, kb): "STROKES COMMAND source=S rank=R [args=A] [when=W] state=..."
kb_describe:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov rsi, [r12 + KB_text]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rsi, [r12 + KB_name]
    test rsi, rsi
    jnz 1f
    mov rax, [r12 + KB_cmd]
    mov rsi, [rax + CMD_name]
1:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ls_source]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    call kb_source
    mov rdi, rbx
    lea rsi, [rip + .Ls_rank]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, [r12 + KB_rank]
    call sb_push_u64
    cmp qword ptr [r12 + KB_args], 0
    je 2f
    mov rdi, rbx
    lea rsi, [rip + .Ls_args]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r12 + KB_args]
    call sb_push_cstr
2:  mov rdi, [r12 + KB_when]
    test rdi, rdi
    jz 3f
    call when_source
    mov r13, rax
    mov r14, rdx
    mov rdi, rbx
    lea rsi, [rip + .Ls_when]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call sb_push
3:  mov rdi, rbx
    lea rsi, [rip + .Ls_state]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    call kb_state
    EPILOGUE

# FN keys_dump(out sb, ext or 0): print-keys: a line per binding (only the extension's when given)
FN keys_dump
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, [rip + bindings + VEC_len]
    jae 9f
    imul r14, rbx, KB_SIZE
    add r14, [rip + bindings + VEC_ptr]
    inc rbx
    test r13, r13
    jz 2f
    cmp [r14 + KB_ext], r13
    jne 1b
2:  mov rdi, r12
    mov rsi, r14
    call kb_describe
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# FN keys_chord_dump(out sb): print-chord: "chord=none" or "chord=STROKE fallback=NAME ms=N"
FN keys_chord_dump
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Ls_chord]
    call sb_push_cstr
    cmp dword ptr [rip + chord_on], 0
    jne 1f
    mov rdi, rbx
    lea rsi, [rip + .Ls_none_nl]
    call sb_push_cstr
    EPILOGUE
1:  lea rdi, [rip + keybuf2]
    mov esi, [rip + chord_mods]
    mov edx, [rip + chord_key]
    call fmt_stroke
    mov rdi, rbx
    lea rsi, [rip + keybuf2]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ls_fallback]
    call sb_push_cstr
    mov rax, [rip + chord_fallback]
    lea rsi, [rip + .Ls_dash]
    test rax, rax
    jz 2f
    mov rax, [rax + KB_cmd]
    mov rsi, [rax + CMD_name]
2:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ls_ms]
    call sb_push_cstr
    call time_ms
    mov rsi, [rip + chord_deadline]
    sub rsi, rax
    jns 3f
    xor esi, esi
3:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

# ---------------------------------------------------------------- Keyboard Shortcuts

# FN keys_list(add fn(label, len, detail, cmd)): every binding that is not refused, for the
#   Keyboard Shortcuts list: "Ctrl+K Ctrl+C  Toggle Comment" and "source · when ... · shadowed by
#   ..."; the strings live until the next list or reload
FN keys_list
    PROLOGUE 16
    mov [rsp], rdi
    # the last list's strings
    xor ebx, ebx
1:  cmp rbx, [rip + ks_strings + VEC_len]
    jae 2f
    mov rax, [rip + ks_strings + VEC_ptr]
    mov rdi, [rax + rbx*8]
    call mem_free
    inc rbx
    jmp 1b
2:  mov qword ptr [rip + ks_strings + VEC_len], 0
    xor ebx, ebx
3:  cmp rbx, [rip + bindings + VEC_len]
    jae 9f
    imul r12, rbx, KB_SIZE
    add r12, [rip + bindings + VEC_ptr]
    inc rbx
    cmp dword ptr [r12 + KB_refused], 0
    jne 3b
    lea rax, [rip + none_cmd]
    cmp [r12 + KB_cmd], rax
    je 3b
    # the label
    lea rdi, [rip + keybuf]
    mov rsi, r12
    call fmt_binding
    lea rdi, [rip + ks_sb]
    call sb_clear
    lea rdi, [rip + ks_sb]
    lea rsi, [rip + keybuf]
    call sb_push_cstr
    lea rdi, [rip + ks_sb]
    lea rsi, [rip + .Ls_two_sp]
    call sb_push_cstr
    mov rax, [r12 + KB_cmd]
    lea rdi, [rip + ks_sb]
    mov rsi, [rax + CMD_title]
    call sb_push_cstr
    mov rdi, [rip + ks_sb + SB_ptr]
    mov rsi, [rip + ks_sb + SB_len]
    call mem_dup
    mov r13, rax
    mov r15, [rip + ks_sb + SB_len]
    lea rdi, [rip + ks_strings]
    mov esi, 8
    call vec_push
    mov [rax], r13
    # the detail
    lea rdi, [rip + ks_sb]
    call sb_clear
    lea rdi, [rip + ks_sb]
    mov rsi, r12
    call kb_source
    mov rdi, [r12 + KB_when]
    test rdi, rdi
    jz 4f
    call when_source
    mov r14, rax
    mov [rsp + 8], rdx
    lea rdi, [rip + ks_sb]
    lea rsi, [rip + .Ls_dot_when]
    call sb_push_cstr
    lea rdi, [rip + ks_sb]
    mov rsi, r14
    mov rdx, [rsp + 8]
    call sb_push
4:  mov rdi, r12
    call kb_shadow
    test rax, rax
    jz 5f
    mov r14, rax
    lea rdi, [rip + ks_sb]
    lea rsi, [rip + .Ls_dot_shadowed]
    call sb_push_cstr
    lea rdi, [rip + ks_sb]
    mov rsi, r14
    call kb_source
5:  mov rdi, [rip + ks_sb + SB_ptr]
    mov rsi, [rip + ks_sb + SB_len]
    call mem_dup
    mov r14, rax
    lea rdi, [rip + ks_strings]
    mov esi, 8
    call vec_push
    mov [rax], r14
    mov rdi, r13
    mov rsi, r15
    mov rdx, r14
    mov rcx, [r12 + KB_cmd]
    call [rsp]
    jmp 3b
9:  EPILOGUE

# FN keys_page_rows(ext): the extension page's Keys rows (contribpage.s): each binding it makes,
#   "Ctrl+K Ctrl+C  Toggle Comment", and "active", "overrides built-in TITLE", "shadowed by your
#   [keys]" (or by built-in, by OWNER/NAME) or "refused: WHY", its clause, its arguments
FN keys_page_rows
    PROLOGUE
    mov r15, rdi
    xor ebx, ebx
1:  cmp rbx, [rip + bindings + VEC_len]
    jae 9f
    imul r12, rbx, KB_SIZE
    add r12, [rip + bindings + VEC_ptr]
    inc rbx
    cmp [r12 + KB_ext], r15
    jne 1b
    # the strokes (as written when they cannot be read) and the command
    mov rdi, [r12 + KB_text]
    cmp dword ptr [r12 + KB_key], 0
    je 2f
    lea rdi, [rip + keybuf]
    mov rsi, r12
    call fmt_binding
    lea rdi, [rip + keybuf]
2:  call contrib_page_text
    lea rdi, [rip + .Ls_two_sp]
    call contrib_page_text
    mov rax, [r12 + KB_cmd]
    test rax, rax
    jz 3f
    lea rcx, [rip + none_cmd]
    cmp rax, rcx
    je 3f
    mov rdi, [rax + CMD_title]
    call contrib_page_title
    jmp 4f
3:  mov rdi, [r12 + KB_name]
    test rdi, rdi
    jz 4f
    call contrib_page_text
4:  # how it stands
    mov eax, [r12 + KB_refused]
    test eax, eax
    jz 5f
    dec eax
    lea rcx, [rip + refusal_words]
    mov r13, [rcx + rax*8]
    lea rdi, [rip + .Lp_refused]
    call contrib_page_detail
    mov rdi, r13
    call contrib_page_detail
    mov edi, 1
    call contrib_page_tone
    jmp 7f
5:  mov rdi, r12
    call kb_shadow
    test rax, rax
    jz 6f
    mov r13, rax
    lea rdi, [rip + .Lp_shadowed]
    call contrib_page_detail
    mov rdi, r13
    call kp_source
    mov edi, 1
    call contrib_page_tone
    jmp 7f
6:  mov rdi, r12
    call kb_overrides
    test rax, rax
    jz 61f
    mov r13, rax
    lea rdi, [rip + .Lp_overrides]
    call contrib_page_detail
    mov rax, [r13 + KB_cmd]
    mov rdi, [rax + CMD_title]
    call contrib_page_detail
    jmp 7f
61: lea rdi, [rip + .Ls_active]
    call contrib_page_detail
7:  cmp dword ptr [r12 + KB_rank], KRANK_DEFAULT
    jne 71f
    call contrib_page_part
    lea rdi, [rip + .Lp_default]
    call contrib_page_detail
71: mov rdi, [r12 + KB_when]
    test rdi, rdi
    jz 72f
    call when_source
    mov r13, rax
    mov r14, rdx
    call contrib_page_part
    lea rdi, [rip + .Lwhen_sp]
    call contrib_page_detail
    mov rdi, r13
    mov rsi, r14
    call contrib_page_detail_n
72: mov rdi, [r12 + KB_args]
    test rdi, rdi
    jz 73f
    mov r13, rdi
    call contrib_page_part
    lea rdi, [rip + .Lp_args]
    call contrib_page_detail
    mov rdi, r13
    call contrib_page_detail
73: call contrib_page_end
    jmp 1b
9:  EPILOGUE

# kp_source(kb): who a binding is, in the page's words: "your [keys]", "built-in", "OWNER/NAME"
kp_source:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + .Lp_user]
    cmp dword ptr [rbx + KB_rank], KRANK_USER
    je 8f
    lea rdi, [rip + .Lp_builtin]
    cmp dword ptr [rbx + KB_rank], KRANK_BUILTIN
    je 8f
    mov r12, [rbx + KB_ext]
    test r12, r12
    jz 9f
    mov rdi, [r12 + EXT_owner]
    call contrib_page_detail
    lea rdi, [rip + .Lp_slash]
    call contrib_page_detail
    mov rdi, [r12 + EXT_name]
8:  call contrib_page_detail
9:  EPILOGUE

# kb_overrides(kb) -> rax the built-in binding of the same strokes it wins over, or 0
kb_overrides:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + bindings + VEC_len]
    jae 8f
    imul r13, r12, KB_SIZE
    add r13, [rip + bindings + VEC_ptr]
    inc r12
    cmp dword ptr [r13 + KB_rank], KRANK_BUILTIN
    jne 1b
    cmp dword ptr [r13 + KB_refused], 0
    jne 1b
    mov rax, [r13 + KB_mods]    # mods and key
    cmp rax, [rbx + KB_mods]
    jne 1b
    mov rax, [r13 + KB_mods2]
    cmp rax, [rbx + KB_mods2]
    jne 1b
    cmp qword ptr [r13 + KB_cmd], 0
    je 1b
    mov rdi, rbx
    mov rsi, r13
    call kb_better
    test eax, eax
    jz 1b
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

FN cmd_none
    ret

.section .rodata
.p2align 3
none_cmd: .quad .Lnone, .Lnone, cmd_none, .Lnone
.Lnone: .asciz ""
.ifdef MACOS
.Lmac_control: .asciz "\342\214\203"
.Lmac_option: .asciz "\342\214\245"
.Lmac_shift: .asciz "\342\207\247"
.Lmac_command: .asciz "\342\214\230"
.Lmac_up: .asciz "\342\206\221"
.Lmac_down: .asciz "\342\206\223"
.Lmac_left: .asciz "\342\206\220"
.Lmac_right: .asciz "\342\206\222"
.Lmac_comma: .asciz ","
.Lmac_plus: .asciz "+"
.p2align 3
mac_key_syms:
    .quad .Lmac_up, KEY_UP, .Lmac_down, KEY_DOWN, .Lmac_left, KEY_LEFT, .Lmac_right, KEY_RIGHT
    .quad .Lmac_comma, ',', .Lmac_plus, '+', 0, 0
.endif
# built-in chords: command, strokes (one line each)
builtin_chords:
    .quad .Lc_select_theme, .Lk_select_theme
    .quad .Lc_fold_all, .Lk_fold_all, .Lc_unfold_all, .Lk_unfold_all   # editor presentation
    .quad 0, 0
.Lc_fold_all: .asciz "fold_all"
.Lk_fold_all: .asciz "ctrl+k ctrl+0"
.Lc_unfold_all: .asciz "unfold_all"
.Lk_unfold_all: .asciz "ctrl+k ctrl+j"
.Lc_select_theme: .asciz "select_theme"
.Lk_select_theme: .asciz "ctrl+k ctrl+t"
# linux: / mac: / windows: before a binding's strokes: 1 for this system
sys_prefixes:
.ifdef MACOS
    .quad .Lp_linux, 0, .Lp_mac, 1, .Lp_windows, 0, 0, 0
.else
.ifdef WINDOWS
    .quad .Lp_linux, 0, .Lp_mac, 0, .Lp_windows, 1, 0, 0
.else
    .quad .Lp_linux, 1, .Lp_mac, 0, .Lp_windows, 0, 0, 0
.endif
.endif
.Lp_linux: .asciz "linux:"
.Lp_mac: .asciz "mac:"
.Lp_windows: .asciz "windows:"
# keys besides characters that type or edit (an extension needs a guard to bind them bare)
.p2align 2
typing_keys: .long KEY_RETURN, KEY_TAB, KEY_ISO_LEFT_TAB, KEY_BACKSPACE, KEY_DELETE, KEY_ESCAPE
    .long KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN
    .long KEY_INSERT, 0
.p2align 3
refusal_names: .quad .Lr_command, .Lr_when, .Lr_typing, .Lr_prefix, .Lr_strokes, .Lr_args
.Lr_command: .asciz "command"
.Lr_when: .asciz "when"
.Lr_typing: .asciz "typing"
.Lr_prefix: .asciz "prefix"
.Lr_strokes: .asciz "strokes"
.Lr_args: .asciz "args"
refusal_words: .quad .Lw_command, .Lw_when, .Lw_typing, .Lw_prefix, .Lw_strokes, .Lw_args
.Lw_command: .asciz "no such command"
.Lw_when: .asciz "its when clause does not compile"
.Lw_typing: .asciz "a typing key needs a when guard"
.Lw_prefix: .asciz "a chord's first stroke needs ctrl, alt or super"
.Lw_strokes: .asciz "not one or two strokes"
.Lw_args: .asciz "arguments over 4096 bytes"
.Lp_refused: .asciz "refused: "
.Lp_shadowed: .asciz "shadowed by "
.Lp_overrides: .asciz "overrides built-in "
.Lp_default: .asciz "the command's default key"
.Lp_args: .asciz "arguments "
.Lp_user: .asciz "your [keys]"
.Lp_builtin: .asciz "built-in"
.Lp_slash: .asciz "/"
.Lwhen_sp: .asciz "when "
.Lsp_when_sp: .asciz " when "
.Lnone_word: .asciz "none"
.Lrhun_dot: .asciz "rhun."
.Ldot: .asciz "."
.Lg_not_text: .asciz "!textInputFocus"
.Lg_view_focus: .asciz "viewFocus"
.Lg_view_eq: .asciz "view"
.Lnot_bound: .asciz " is not bound"
.Lwaiting: .asciz " \342\200\224 waiting for the next key"
.Lor_pause: .asciz ", or pause for "
.Ls_user: .asciz "user"
.Ls_builtin: .asciz "builtin"
.Ls_ext: .asciz "ext:"
.Ls_default: .asciz "default:"
.Ls_refused: .asciz "refused:"
.Ls_active: .asciz "active"
.Ls_shadowed: .asciz "shadowed:"
.Ls_source: .asciz " source="
.Ls_rank: .asciz " rank="
.Ls_args: .asciz " args="
.Ls_when: .asciz " when="
.Ls_state: .asciz " state="
.Ls_chord: .asciz "chord="
.Ls_none_nl: .asciz "none\n"
.Ls_fallback: .asciz " fallback="
.Ls_dash: .asciz "-"
.Ls_ms: .asciz " ms="
.Ls_two_sp: .asciz "  "
.Ls_dot_when: .asciz " \302\267 when "
.Ls_dot_shadowed: .asciz " \302\267 shadowed by "
.Lctrl: .asciz "Ctrl+"
.Lshift: .asciz "Shift+"
.Lalt: .asciz "Alt+"
.Lsuper: .asciz "Super+"
mod_names:
    .quad .Lm_ctrl, MOD_CTRL, .Lm_control, MOD_CTRL, .Lm_shift, MOD_SHIFT, .Lm_alt, MOD_ALT
    .quad .Lm_super, MOD_SUPER, .Lm_cmd, MOD_SUPER, .Lm_meta, MOD_SUPER, 0, 0
.Lm_ctrl: .asciz "ctrl"
.Lm_control: .asciz "control"
.Lm_shift: .asciz "shift"
.Lm_alt: .asciz "alt"
.Lm_super: .asciz "super"
.Lm_cmd: .asciz "cmd"
.Lm_meta: .asciz "meta"
key_names:
    .quad .Lk_enter, KEY_RETURN, .Lk_return, KEY_RETURN, .Lk_tab, KEY_TAB, .Lk_esc, KEY_ESCAPE
    .quad .Lk_escape, KEY_ESCAPE, .Lk_bs, KEY_BACKSPACE, .Lk_del, KEY_DELETE, .Lk_delete, KEY_DELETE
    .quad .Lk_up, KEY_UP, .Lk_down, KEY_DOWN, .Lk_left, KEY_LEFT, .Lk_right, KEY_RIGHT
    .quad .Lk_home, KEY_HOME, .Lk_end, KEY_END, .Lk_pgup, KEY_PAGEUP, .Lk_pgdn, KEY_PAGEDOWN
    .quad .Lk_ins, KEY_INSERT, .Lk_space, ' ', .Lk_plus, '+', .Lk_comma, ','
    .quad .Lk_f1, KEY_F1, .Lk_f2, KEY_F1 + 1, .Lk_f3, KEY_F1 + 2, .Lk_f4, KEY_F1 + 3
    .quad .Lk_f5, KEY_F1 + 4, .Lk_f6, KEY_F1 + 5, .Lk_f7, KEY_F1 + 6, .Lk_f8, KEY_F1 + 7
    .quad .Lk_f9, KEY_F1 + 8, .Lk_f10, KEY_F1 + 9, .Lk_f11, KEY_F1 + 10, .Lk_f12, KEY_F1 + 11
    .quad 0, 0
.Lk_enter: .asciz "Enter"
.Lk_return: .asciz "Return"
.Lk_tab: .asciz "Tab"
.Lk_esc: .asciz "Esc"
.Lk_escape: .asciz "Escape"
.Lk_bs: .asciz "Backspace"
.Lk_del: .asciz "Del"
.Lk_delete: .asciz "Delete"
.Lk_up: .asciz "Up"
.Lk_down: .asciz "Down"
.Lk_left: .asciz "Left"
.Lk_right: .asciz "Right"
.Lk_home: .asciz "Home"
.Lk_end: .asciz "End"
.Lk_pgup: .asciz "PageUp"
.Lk_pgdn: .asciz "PageDown"
.Lk_ins: .asciz "Insert"
.Lk_space: .asciz "Space"
.Lk_plus: .asciz "Plus"
.Lk_comma: .asciz "Comma"
.Lk_f1: .asciz "F1"
.Lk_f2: .asciz "F2"
.Lk_f3: .asciz "F3"
.Lk_f4: .asciz "F4"
.Lk_f5: .asciz "F5"
.Lk_f6: .asciz "F6"
.Lk_f7: .asciz "F7"
.Lk_f8: .asciz "F8"
.Lk_f9: .asciz "F9"
.Lk_f10: .asciz "F10"
.Lk_f11: .asciz "F11"
.Lk_f12: .asciz "F12"

.macro COMMAND name, title, fn, keys
    .quad 1f, 2f, \fn, 3f
    .pushsection .rodata.str, "aMS", @progbits, 1
1:  .asciz "\name"
2:  .asciz "\title"
3:  .asciz "\keys"
    .popsection
.endm

.p2align 3
.globl g_commands
g_commands:
    COMMAND quick_open, "Go to File", cmd_quick_open, "ctrl+p ctrl+e"
    COMMAND command_palette, "Command Palette", cmd_command_palette, "ctrl+shift+p F1"
    COMMAND keyboard_shortcuts, "Keyboard Shortcuts", cmd_keyboard_shortcuts, ""
    COMMAND select_file_icon_theme, "Select File Icon Theme", cmd_select_file_icon_theme, ""
    COMMAND new_file, "New File", cmd_new_file, "ctrl+n"
    COMMAND new_window, "New Window", cmd_new_window, "ctrl+shift+n"
    COMMAND save, "Save", cmd_save, "ctrl+s"
    COMMAND save_without_formatting, "Save Without Formatting", cmd_save_without_formatting, ""
    COMMAND cancel_save, "Cancel Save", cmd_cancel_save, ""
    COMMAND save_all, "Save All", cmd_save_all, ""
    COMMAND save_as, "Save As", cmd_save_as, "ctrl+shift+s"
    COMMAND close_tab, "Close Tab", cmd_close_tab, "ctrl+w ctrl+F4"
    COMMAND close_all_tabs, "Close All Tabs", cmd_close_all, "ctrl+shift+w"
    COMMAND reopen_closed_tab, "Reopen Closed Tab", cmd_reopen_closed_tab, "ctrl+shift+t"
    COMMAND pin_tab, "Pin Tab", cmd_pin_tab, ""
    COMMAND unpin_tab, "Unpin Tab", cmd_unpin_tab, ""
    COMMAND next_tab, "Next Tab", cmd_next_tab, "ctrl+Tab ctrl+PageDown"
    COMMAND prev_tab, "Previous Tab", cmd_prev_tab, "ctrl+shift+Tab ctrl+PageUp"
    COMMAND quit, "Quit", cmd_quit, "ctrl+q"
    COMMAND undo, "Undo", cmd_undo, "ctrl+z"
    COMMAND redo, "Redo", cmd_redo, "ctrl+shift+z ctrl+y"
    COMMAND undo_workspace_edit, "Undo Last Multi-File Edit", cmd_undo_workspace_edit, ""
    COMMAND redo_workspace_edit, "Redo Last Multi-File Edit", cmd_redo_workspace_edit, ""
    COMMAND snippet_choose, "Snippet: Choose Value", cmd_snippet_choose, ""
    COMMAND snippet_next, "Snippet: Next Field", cmd_snippet_next, ""
    COMMAND snippet_previous, "Snippet: Previous Field", cmd_snippet_previous, ""
    COMMAND snippet_cancel, "Snippet: Finish Editing Fields", cmd_snippet_cancel, ""
    COMMAND cut, "Cut", cmd_cut, "ctrl+x shift+Delete"
    COMMAND copy, "Copy", cmd_copy, "ctrl+c ctrl+Insert"
    COMMAND paste, "Paste", cmd_paste, "ctrl+v shift+Insert"
    COMMAND select_all, "Select All", cmd_select_all, "ctrl+a"
    COMMAND select_line, "Select Line", cmd_select_line, "ctrl+l"
    # multi-cursor (editorsel.s): the primary is the selection added last
    COMMAND select_next, "Select Word or Add Next Match", cmd_select_next, "ctrl+d"
    COMMAND select_next_skip, "Move Selection to Next Match", cmd_select_next_skip, ""
    COMMAND select_all_matches, "Select All Matches", cmd_select_all_matches, "ctrl+shift+l"
    # shift+alt too: GNOME and other desktops take ctrl+alt+arrows for workspaces
    COMMAND add_cursor_above, "Add Cursor Above", cmd_add_cursor_above, "ctrl+alt+Up shift+alt+Up"
    COMMAND add_cursor_below, "Add Cursor Below", cmd_add_cursor_below, "ctrl+alt+Down shift+alt+Down"
    COMMAND remove_last_selection, "Remove Last Selection", cmd_remove_last_selection, "ctrl+u"
    COMMAND cursors_to_line_ends, "Add Cursors to Line Ends", cmd_cursors_to_line_ends, "shift+alt+i"
    COMMAND column_select_up, "Column Select Up", cmd_column_select_up, "ctrl+shift+alt+Up"
    COMMAND column_select_down, "Column Select Down", cmd_column_select_down, "ctrl+shift+alt+Down"
    COMMAND column_select_left, "Column Select Left", cmd_column_select_left, "ctrl+shift+alt+Left"
    COMMAND column_select_right, "Column Select Right", cmd_column_select_right, "ctrl+shift+alt+Right"
    COMMAND duplicate_line, "Duplicate Line", cmd_duplicate_line, "ctrl+shift+d"
    COMMAND delete_line, "Delete Line", cmd_delete_line, "ctrl+shift+k"
    COMMAND move_line_up, "Move Line Up", cmd_move_line_up, "alt+Up"
    COMMAND move_line_down, "Move Line Down", cmd_move_line_down, "alt+Down"
    COMMAND indent, "Indent", cmd_indent, "ctrl+]"
    COMMAND outdent, "Outdent", cmd_outdent, "ctrl+["
    COMMAND toggle_comment, "Toggle Comment", cmd_toggle_comment, "ctrl+/"
    COMMAND newline_below, "Insert Line Below", cmd_newline_below, "ctrl+Enter"
    COMMAND newline_above, "Insert Line Above", cmd_newline_above, "ctrl+shift+Enter"
    COMMAND find, "Find", cmd_find_bar, "ctrl+f"
    COMMAND replace, "Replace", cmd_replace_bar, "ctrl+h"
    COMMAND find_next, "Find Next", cmd_find_next, "F3"
    COMMAND find_prev, "Find Previous", cmd_find_prev, "shift+F3"
    COMMAND find_in_files, "Find in Files", cmd_find_in_files, "ctrl+shift+f"
    COMMAND goto_line, "Go to Line", cmd_goto_line, "ctrl+g"
    COMMAND settings, "Open Settings", cmd_settings, "ctrl+,"
    COMMAND open_config, "Open Settings File", cmd_open_config, ""
    COMMAND select_theme, "Select Color Theme", cmd_select_theme, ""
    COMMAND toggle_light_dark_theme, "Toggle Light/Dark Theme", cmd_toggle_light_dark, ""
    COMMAND select_language, "Change Language Mode", cmd_select_language, ""
    COMMAND toggle_sidebar, "Toggle File Explorer", cmd_toggle_sidebar, "ctrl+b"
    COMMAND toggle_agents, "Toggle Agents Panel", cmd_toggle_agents, "ctrl+shift+a"
    COMMAND focus_explorer, "Focus File Explorer", cmd_focus_explorer, "ctrl+shift+e"
    COMMAND reveal_file, "Show File in System File Manager", cmd_reveal_file, ""
    COMMAND trust_folder, "Trust Folder for Git", cmd_trust_folder, ""
    COMMAND website, "Open rhun Website", cmd_website, ""
    COMMAND email, "Email rhun", cmd_email, ""
    COMMAND feedback, "Send Feedback or Report a Bug", cmd_feedback, ""
    COMMAND focus_agents, "Focus Agents Panel", cmd_focus_agents, ""
    COMMAND open_file, "Open File", cmd_open_file, "ctrl+o"
    COMMAND open_folder, "Open Folder", cmd_open_folder, "ctrl+shift+o"
    COMMAND add_workspace_folder, "Add Folder to Workspace", cmd_add_workspace_folder, ""   # resources: workspace.s
    COMMAND remove_workspace_folder, "Remove Folder from Workspace", cmd_remove_workspace_folder, ""
    COMMAND save_workspace_as, "Save Workspace As", cmd_save_workspace_as, ""
    COMMAND new_folder, "New Folder", cmd_new_folder, ""
    COMMAND rename_file, "Rename File", cmd_rename_file, "F2"
    COMMAND delete_file, "Delete File", cmd_delete_file, ""
    COMMAND zoom_in, "Zoom In", cmd_zoom_in, "ctrl+= ctrl++ ctrl+shift+= ctrl+shift++ ctrl+KP_Add ctrl+KP_Equal"
    COMMAND zoom_out, "Zoom Out", cmd_zoom_out, "ctrl+- ctrl+KP_Subtract"
    COMMAND zoom_reset, "Reset Zoom", cmd_zoom_reset, "ctrl+0 ctrl+KP_0"
    COMMAND toggle_word_wrap, "Toggle Word Wrap", cmd_toggle_word_wrap, "alt+z"
    COMMAND complete, "Show Completions", cmd_complete, "ctrl+Space"
    COMMAND signature_help, "Show Signature Help", cmd_signature_help, "ctrl+shift+Space"
    COMMAND definition, "Go to Definition", cmd_definition, "F12"
    COMMAND references, "Find All References", cmd_references, "shift+F12"
    COMMAND symbols, "Go to Symbol in File", cmd_symbols, "ctrl+r"
    COMMAND code_actions, "Show Code Actions", cmd_code_actions, "ctrl+."
    COMMAND format_document, "Format Document", cmd_format_document, "shift+alt+f"
    # language features (protocol 1.1)
    COMMAND declaration, "Go to Declaration", cmd_declaration, ""
    COMMAND type_definition, "Go to Type Definition", cmd_type_definition, ""
    COMMAND implementation, "Go to Implementation", cmd_implementation, "ctrl+F12"
    COMMAND format_selection, "Format Selection", cmd_format_selection, ""
    COMMAND quick_fix_auto, "Auto Fix", cmd_quick_fix_auto, "shift+alt+."
    COMMAND quick_fix, "Quick Fix...", cmd_quick_fix, ""
    COMMAND organize_imports, "Organize Imports", cmd_organize_imports, "shift+alt+o"
    COMMAND fix_all, "Fix All", cmd_fix_all, ""
    COMMAND refactor, "Refactor...", cmd_refactor, "ctrl+shift+r"
    COMMAND source_action, "Source Action...", cmd_source_action, ""
    COMMAND show_hover, "Show Hover", cmd_show_hover, "ctrl+i"
    COMMAND workspace_symbols, "Go to Symbol in Project", cmd_workspace_symbols, "ctrl+t"
    COMMAND open_link, "Open Link", cmd_open_link, ""
    COMMAND next_problem, "Next Problem", cmd_next_problem, "F8"
    COMMAND prev_problem, "Previous Problem", cmd_prev_problem, "shift+F8"
    COMMAND expand_selection, "Expand Selection", cmd_expand_selection, "shift+alt+Right"
    COMMAND shrink_selection, "Shrink Selection", cmd_shrink_selection, "shift+alt+Left"
    COMMAND peek_definition, "Peek Definition", cmd_peek_definition, "alt+F12"
    COMMAND peek_declaration, "Peek Declaration", cmd_peek_declaration, ""
    COMMAND peek_type_definition, "Peek Type Definition", cmd_peek_type_definition, ""
    COMMAND peek_implementation, "Peek Implementation", cmd_peek_implementation, ""
    COMMAND peek_references, "Peek References", cmd_peek_references, ""
    COMMAND cancel_query, "Cancel Language Query", cmd_cancel_query, ""
    COMMAND next_result, "Next Result", cmd_next_result, "F4"
    COMMAND prev_result, "Previous Result", cmd_prev_result, "shift+F4"
    COMMAND focus_results, "Focus Results", cmd_focus_results, ""
    COMMAND focus_outline, "Focus Outline", cmd_focus_outline, ""
    COMMAND results_back, "Results: Previous Set", cmd_results_back, ""
    COMMAND results_forward, "Results: Next Set", cmd_results_forward, ""
    COMMAND results_drop, "Results: Clear Set", cmd_results_drop, ""
    COMMAND results_flip, "Results: Switch Hierarchy Direction", cmd_results_flip, ""
    COMMAND call_hierarchy, "Show Call Hierarchy", cmd_call_hierarchy, "shift+alt+h"
    COMMAND type_hierarchy, "Show Type Hierarchy", cmd_type_hierarchy, ""
    COMMAND select_default_formatter, "Select Default Formatter", cmd_select_default_formatter, ""
    COMMAND select_rename_provider, "Select Rename Provider", cmd_select_rename_provider, ""
    COMMAND select_signature_provider, "Select Signature Provider", cmd_select_signature_provider, ""
    COMMAND select_symbol_provider, "Select Symbol Provider", cmd_select_symbol_provider, ""
    COMMAND toggle_whitespace, "Toggle Whitespace", cmd_toggle_whitespace, ""
    COMMAND toggle_line_numbers, "Toggle Line Numbers", cmd_toggle_line_numbers, ""
    COMMAND toggle_vim, "Toggle Vim Mode", cmd_toggle_vim, ""
    COMMAND reload_file, "Revert File", cmd_reload_file, ""
    COMMAND toggle_terminal, "Toggle Terminal", cmd_toggle_terminal, "ctrl+`"
    # views group: places
    COMMAND toggle_panel, "Toggle Panel", cmd_toggle_panel, "ctrl+j"
    COMMAND toggle_side, "Toggle Side Views", cmd_toggle_side, ""
    COMMAND focus_notifications, "Focus Notifications", cmd_focus_notifications, ""
    COMMAND clear_notifications, "Clear All Notifications", cmd_clear_notifications, ""
    COMMAND extensions, "Extensions", cmd_extensions, ""
    COMMAND extensions_menu, "Extensions Menu", extbar_open_menu, ""
    COMMAND install_extension, "Install Extension from GitHub", cmd_install_extension, ""
    # extension management
    COMMAND install_extension_folder, "Install Extension from Folder", cmd_install_extension_folder, ""
    COMMAND link_extension_folder, "Link Extension Folder (development)", cmd_link_extension_folder, ""
    COMMAND install_extension_archive, "Install Extension from Archive", cmd_install_extension_archive, ""
    COMMAND new_extension, "Extensions: New Extension\342\200\246", cmd_new_extension, ""
    COMMAND submit_extension, "Extensions: Submit to Index\342\200\246", cmd_submit_extension, ""
    COMMAND new_terminal, "New Terminal", cmd_new_terminal, "ctrl+shift+` ctrl+shift+~"
    # tasks and terminals
    COMMAND toggle_problems, "Toggle Problems", cmd_toggle_problems, "ctrl+shift+m"
    COMMAND run_task, "Run Task", cmd_run_task, ""
    COMMAND run_build_task, "Run Build Task", cmd_run_build_task, "ctrl+shift+b"
    COMMAND run_test_task, "Run Test Task", cmd_run_test_task, ""
    COMMAND rerun_last_task, "Re-run Last Task", cmd_rerun_last_task, ""
    COMMAND restart_task, "Restart Task", cmd_restart_task, ""
    COMMAND stop_task, "Stop Task", cmd_stop_task, ""
    COMMAND show_task, "Show Task", cmd_show_task, ""
    COMMAND clear_task_problems, "Clear Task Problems", cmd_clear_task_problems, ""
    COMMAND kill_terminal, "Kill Terminal", cmd_kill_terminal, ""
    COMMAND clear_terminal, "Clear Terminal", cmd_clear_terminal, ""
    COMMAND git_history, "Git: Show History", cmd_git_history, ""
    COMMAND toggle_git_history, "Toggle Git History", cmd_toggle_git, "ctrl+shift+g"
    COMMAND git_changes, "Git: Open Changes", cmd_git_changes, ""
    COMMAND git_commit, "Git: Commit", cmd_git_commit, ""
    COMMAND git_generate_message, "Git: Generate Commit Message", cmd_git_generate_message, ""
    COMMAND ai_detect, "Git: Check AI Provider", cmd_ai_detect, ""
    COMMAND ai_setup, "Git: Download Local Model", cmd_ai_setup, ""
    COMMAND ai_delete, "Git: Delete Local Model", cmd_ai_delete, ""
    COMMAND ai_cancel, "Git: Cancel AI Operation", cmd_ai_cancel, ""
    COMMAND git_commit_amend, "Git: Commit (Amend)", cmd_git_commit_amend, ""
    COMMAND git_pull, "Git: Pull", cmd_git_pull, ""
    COMMAND git_push, "Git: Push", cmd_git_push, ""
    COMMAND git_sync, "Git: Sync", cmd_git_sync, ""
    COMMAND git_fetch, "Git: Fetch", cmd_git_fetch, ""
    COMMAND git_stage_all, "Git: Stage All Changes", cmd_git_stage_all, ""
    COMMAND git_unstage_all, "Git: Unstage All Changes", cmd_git_unstage_all, ""
    COMMAND git_discard_all, "Git: Discard All Changes", cmd_git_discard_all, ""
    COMMAND git_reset_all, "Git: Reset All Changes", cmd_git_reset_all, ""
    COMMAND check_for_updates, "Check for Updates", cmd_check_for_updates, ""
    COMMAND install_update, "Install Update", cmd_install_update, ""
    COMMAND restart_to_update, "Restart to Update", cmd_restart_to_update, ""
    # debugger (debugview.s)
    COMMAND debug_start, "Debug: Start or Continue", cmd_debug_start, "F5"
    COMMAND debug_run, "Debug: Run Without Debugging", cmd_debug_run, "ctrl+F5"
    COMMAND debug_stop, "Debug: Stop", cmd_debug_stop, "shift+F5"
    COMMAND debug_restart, "Debug: Restart", cmd_debug_restart, "ctrl+shift+F5"
    COMMAND debug_pause, "Debug: Pause", cmd_debug_pause, "F6"
    COMMAND debug_continue, "Debug: Continue", cmd_debug_continue, ""
    COMMAND debug_step_over, "Debug: Step Over", cmd_debug_step_over, "F10"
    COMMAND debug_step_into, "Debug: Step Into", cmd_debug_step_into, "F11"
    COMMAND debug_step_out, "Debug: Step Out", cmd_debug_step_out, "shift+F11"
    COMMAND debug_toggle_breakpoint, "Debug: Toggle Breakpoint", cmd_debug_toggle_breakpoint, "F9"
    COMMAND debug_show, "Debug: Show or Hide", cmd_debug_show, "ctrl+shift+y"
    COMMAND debug_condition, "Debug: Edit Breakpoint Condition", cmd_debug_condition, ""
    COMMAND debug_hit_count, "Debug: Edit Breakpoint Hit Count", cmd_debug_hit_count, ""
    COMMAND debug_logpoint, "Debug: Add Logpoint", cmd_debug_logpoint, ""
    COMMAND debug_disable_breakpoint, "Debug: Enable or Disable Breakpoint", cmd_debug_disable_breakpoint, ""
    COMMAND debug_remove_all_breakpoints, "Debug: Remove All Breakpoints", cmd_debug_remove_all_breakpoints, ""
    COMMAND debug_add_function_breakpoint, "Debug: Add Function Breakpoint", cmd_debug_add_function_breakpoint, ""
    COMMAND debug_add_watch, "Debug: Add Watch Expression", cmd_debug_add_watch, ""
    COMMAND debug_evaluate_selection, "Debug: Evaluate Selection in Console", cmd_debug_evaluate_selection, ""
    COMMAND debug_focus_console, "Debug: Focus Debug Console", cmd_debug_focus_console, ""
    COMMAND debug_open_configurations, "Debug: Open Launch Configurations", cmd_debug_open_configurations, ""
    COMMAND debug_select_configuration, "Debug: Select Configuration", cmd_debug_select_configuration, ""
    COMMAND debug_add_configuration, "Debug: Add Configuration", cmd_debug_add_configuration, ""
    # testing (testview.s)
    COMMAND testing, "Testing", cmd_testing, ""
    COMMAND test_run_all, "Run All Tests", cmd_test_run_all, ""
    COMMAND test_run_file, "Run Tests in Current File", cmd_test_run_file, ""
    COMMAND test_run_cursor, "Run Test at Cursor", cmd_test_run_cursor, ""
    COMMAND test_debug_cursor, "Debug Test at Cursor", cmd_test_debug_cursor, ""
    COMMAND test_coverage_all, "Run All Tests with Coverage", cmd_test_coverage_all, ""
    COMMAND test_rerun_failed, "Re-run Failed Tests", cmd_test_rerun_failed, ""
    COMMAND test_rerun_last, "Re-run Last Test Run", cmd_test_rerun_last, ""
    COMMAND test_cancel, "Cancel Test Runs", cmd_test_cancel, ""
    COMMAND test_coverage_toggle, "Show Test Coverage", cmd_test_coverage_toggle, ""
    COMMAND test_next_failure, "Go to Next Test Failure", cmd_test_next_failure, ""
    # notebooks (nbkeys.s): the notebook's own keys are its command and edit modes
    COMMAND notebook.run_cell, "Notebook: Run Cell", cmd_nb_run_cell, ""
    COMMAND notebook.run_and_select_below, "Notebook: Run Cell and Select Below", cmd_nb_run_next, ""
    COMMAND notebook.run_and_insert_below, "Notebook: Run Cell and Insert Below", cmd_nb_run_insert, ""
    COMMAND notebook.run_all, "Notebook: Run All", cmd_nb_run_all, ""
    COMMAND notebook.interrupt, "Notebook: Interrupt Kernel", cmd_nb_interrupt, ""
    COMMAND notebook.restart, "Notebook: Restart Kernel", cmd_nb_restart, ""
    COMMAND notebook.select_kernel, "Notebook: Select Kernel", cmd_nb_kernel, ""
    COMMAND notebook.clear_outputs, "Notebook: Clear All Outputs", cmd_nb_clear_outputs, ""
    COMMAND notebook.insert_above, "Notebook: Insert Code Cell Above", cmd_nb_insert_above, ""
    COMMAND notebook.insert_below, "Notebook: Insert Code Cell Below", cmd_nb_insert_below, ""
    COMMAND notebook.delete_cell, "Notebook: Delete Cell", cmd_nb_delete_cell, ""
    COMMAND notebook.undo_cell, "Notebook: Undo Cell Operation", cmd_nb_undo_cell, ""
    COMMAND notebook.to_markup, "Notebook: Change Cell to Markdown", cmd_nb_to_markup, ""
    COMMAND notebook.to_code, "Notebook: Change Cell to Code", cmd_nb_to_code, ""
    COMMAND notebook.move_up, "Notebook: Move Cell Up", cmd_nb_move_up, ""
    COMMAND notebook.move_down, "Notebook: Move Cell Down", cmd_nb_move_down, ""
    COMMAND notebook.toggle_outputs, "Notebook: Show or Hide Outputs", cmd_nb_toggle_outputs, ""
    COMMAND notebook.edit_cell, "Notebook: Edit Cell", cmd_nb_edit, ""
    COMMAND notebook.command_mode, "Notebook: Command Mode", cmd_nb_command_mode, ""
    COMMAND notebook.reopen_as_text, "Notebook: Reopen as Text", cmd_nb_open_as_text, ""
    # custom editors (customed.s)
    COMMAND reopen_with, "Reopen Editor With...", cmd_reopen_with, ""
    # remote hosts (remoteui.s)
    COMMAND connect_to_host, "Remote: Connect to Host", cmd_connect_to_host, ""
    COMMAND attach_to_container, "Remote: Attach to Container", cmd_attach_to_container, ""
    COMMAND connect_to_wsl, "Remote: Connect to WSL", cmd_connect_to_wsl, ""
    COMMAND remote_disconnect, "Remote: Disconnect", cmd_remote_disconnect, ""
    COMMAND remote_reconnect, "Remote: Reconnect", cmd_remote_reconnect, ""
    COMMAND remote_show_log, "Remote: Show Log", cmd_remote_show_log, ""
    COMMAND remote_forward_port, "Remote: Forward a Port", cmd_remote_forward_port, ""
    COMMAND remote_stop_forwarding, "Remote: Stop Forwarding Ports", cmd_remote_stop_forwarding, ""
    # editor presentation (fold.s)
    COMMAND fold, "Fold", cmd_fold, "ctrl+shift+[ ctrl+shift+{"
    COMMAND unfold, "Unfold", cmd_unfold, "ctrl+shift+] ctrl+shift+}"
    COMMAND toggle_fold, "Toggle Fold", cmd_toggle_fold, ""
    COMMAND fold_all, "Fold All", cmd_fold_all, ""
    COMMAND inline_complete, "Trigger Inline Completion", cmd_inline_complete, "alt+\\"
    COMMAND unfold_all, "Unfold All", cmd_unfold_all, ""
    COMMAND fold_level_1, "Fold Level 1", cmd_fold_level_1, ""
    COMMAND fold_level_2, "Fold Level 2", cmd_fold_level_2, ""
    COMMAND fold_level_3, "Fold Level 3", cmd_fold_level_3, ""
    .quad 0, 0, 0, 0

