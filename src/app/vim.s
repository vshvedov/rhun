# vim keys on the editor: normal, insert and visual modes (Settings: Vim mode, off by default)
#
# vim_key sees editor keys before the key bindings. In insert mode everything but Esc goes on to the
# editor. The keys of the last change are kept and typed again by ".". Yanks and deletes go to the
# clipboard; p asks the platform for it and puts the text when it arrives (vim_paste).
.include "rhun.inc"

.equ MF_LINE, 1                 # motion: linewise
.equ MF_INCL, 2                 # inclusive
.equ MF_FAIL, 4                 # not a motion, or it cannot move
.equ MF_KEEPX, 8                # keeps the preferred column
.equ MF_EOL, 16                 # $: stays at line ends
.equ MF_NOADJ, 32               # an operator's w that ends at a line end: no linewise adjustment
.equ EOL_COL, 0x40000000        # preferred column after $
.equ NMAX, 100000               # largest count
.equ KR_SIZE, 12                # recorded key: keysym, cp, mods

# keys without a character, numbered above the code points
.equ VK_ESC, 0x110000
.equ VK_LEFT, 0x110001
.equ VK_RIGHT, 0x110002
.equ VK_UP, 0x110003
.equ VK_DOWN, 0x110004
.equ VK_HOME, 0x110005
.equ VK_END, 0x110006
.equ VK_PGUP, 0x110007
.equ VK_PGDN, 0x110008
.equ VK_BS, 0x110009
.equ VK_DEL, 0x11000a
.equ VK_ENTER, 0x11000b
.equ VK_REDO, 0x11000c          # ctrl+r
.equ VK_HALFDN, 0x11000d        # ctrl+d
.equ VK_HALFUP, 0x11000e        # ctrl+u
.equ VK_NOP, 0x11000f           # Tab: taken, does nothing
.equ VK_GG, 0x110010            # gg as a motion

.data
.p2align 2
v_sdir: .long 1                 # direction of the last search; n follows it

.bss
.p2align 3
.globl g_vim_mode, g_vim_cmdline
g_vim_mode: .long 0
g_vim_cmdline: .long 0          # the key that opened the command line (: / ?), 0 when closed
v_on: .long 0                   # cfg_vim when last applied
v_count: .long 0                # count being typed
v_opcount: .long 0              # count typed before the operator
v_op: .long 0                   # pending operator: d c y > < u U ~
v_prefix: .long 0               # pending first key of two: g z Z f F t T r i a
v_n: .long 0                    # count of this command, at least 1
v_has: .long 0                  # a count was typed
v_cmdcount: .long 0             # count typed before the command's first key
v_dotcount: .long 0             # the same for the last change
v_fkind: .long 0                # last f F t T and its character
v_fchar: .long 0
v_visual: .long 0               # the change began in visual mode: "." does not repeat it
v_replay: .long 0               # typing the keys of "." again
v_inscount: .long 0             # 3ihi<Esc> types "hi" three times
v_inskey: .long 0               # the key that began insert mode
v_autoind: .long 0              # insert mode began on a line with only the indent o O cc S gave it
v_putkind: .long 0              # p or P waiting for the clipboard
v_putcount: .long 0
v_putmode: .long 0
.p2align 3
v_insstart: .quad 0             # offset in v_rec of the first key typed in insert mode
v_chgdoc: .quad 0               # document of the change in progress
v_chglen: .quad 0               # its undo length before the change
v_putdoc: .quad 0               # document waiting for the clipboard
v_sfrom: .quad 0                # / ?: where the search began
v_sanchor: .quad 0              # and the visual selection's other end
v_sop: .long 0                  # the operator the search is the motion of (d/foo)
v_sopcount: .long 0
v_exdoc: .quad 0                # vim_export: the document, its selection before and after
v_excur: .quad 0
v_exanchor: .quad 0
v_exout: .quad 0, 0
v_exmode: .long 0
v_rec: .zero SB_SIZE            # keys of the command in progress (KR_SIZE each)
v_dot: .zero SB_SIZE            # keys of the last change
v_vdot: .zero SB_SIZE           # a visual change as normal mode keys, for "." (empty: none)
v_vdotcount: .long 0            # their count: lines, or characters of one line
v_vdotop: .long 0
v_buf: .zero SB_SIZE
v_stat: .zero 64
v_tf: .zero TF_SIZE             # the command line
v_pat: .zero SB_SIZE            # / ?: the pattern before, back when the search is cancelled
v_patword: .long 0              # and whether it was a whole word (* #)

.text

# ---- helpers on g_doc ----

vlen:
    mov rdi, [rip + g_doc]
    jmp doc_len
vbyte:
    mov rsi, rdi
    mov rdi, [rip + g_doc]
    jmp doc_byte
vline:
    mov rsi, rdi
    mov rdi, [rip + g_doc]
    jmp doc_line_of
vstart:
    mov rsi, rdi
    mov rdi, [rip + g_doc]
    jmp doc_line_start
vend:
    mov rsi, rdi
    mov rdi, [rip + g_doc]
    jmp doc_line_end
vnext:
    mov rsi, rdi
    mov rdi, [rip + g_doc]
    jmp doc_next_char
vprev:
    mov rsi, rdi
    mov rdi, [rip + g_doc]
    jmp doc_prev_char
# vnl() -> lines as vim has them: the newline at the end of a file (DF_EOL) starts none (keeps all but rax)
vnl:
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push r9
    push r10
    push r11
    push rbx
    mov rbx, [rip + g_doc]
    mov rax, [rbx + DOC_nlines]
    cmp rax, 1
    jbe 9f
    test dword ptr [rbx + DOC_flags], DF_EOL
    jz 9f
    mov rdi, rbx
    call doc_len
    lea rsi, [rax - 1]
    mov rdi, rbx
    call doc_byte
    mov ecx, eax
    mov rax, [rbx + DOC_nlines]
    cmp ecx, 10
    jne 9f
    dec rax
9:  pop rbx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

# vlast() -> last line (keeps all but rax)
vlast:
    call vnl
    dec rax
    ret

# vlast_text() -> last line of the text, the empty one after a final newline too
vlast_text:
    mov rax, [rip + g_doc]
    mov rax, [rax + DOC_nlines]
    dec rax
    ret

# vlen_vim() -> end of the last line (before a final newline)
vlen_vim:
    push rbx
    call vlen
    mov rbx, rax
    call vnl
    mov rcx, [rip + g_doc]
    cmp rax, [rcx + DOC_nlines]
    mov rax, rbx
    je 1f
    dec rax
1:  pop rbx
    ret

# vfirst(line) -> first non-blank of the line (its end when blank)
vfirst:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov rdi, [rip + g_doc]
    mov rsi, r12
    call line_indent
    mov rbx, rax
    mov rdi, r12
    call vstart
    add rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

# vempty(line) -> 1 if the line has no characters
vempty:
    push rbx
    push r12
    push r13
    mov r12, rdi
    call vstart
    mov rbx, rax
    mov rdi, r12
    call vend
    cmp rax, rbx
    sete al
    movzx eax, al
    pop r13
    pop r12
    pop rbx
    ret

# vclamp(pos) -> where the normal mode cursor may be: on a character, the line end only when the line is empty
vclamp:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    call vlen_vim
    cmp rbx, rax
    jbe 0f
    mov rbx, rax
0:  call vlen
    cmp rbx, rax
    jae 1f
    mov rdi, rbx
    call vbyte
    cmp eax, 10
    jne 9f
1:  mov rdi, rbx
    call vline
    mov rdi, rax
    call vstart
    cmp rbx, rax
    jbe 9f
    mov rdi, rbx
    call vprev
    mov rbx, rax
9:  mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

# vsnap(pos) -> start of the character that holds pos
vsnap:
    push rbx
    mov rbx, rdi
1:  test rbx, rbx
    jz 2f
    mov rdi, rbx
    call vbyte
    and eax, 0xc0
    cmp eax, 0x80
    jne 2f
    dec rbx
    jmp 1b
2:  mov rax, rbx
    pop rbx
    ret

# vclass(pos, big) -> 0 blank, 1 line end, 2 word, 3 punctuation, 5 hiragana, 6 katakana,
# 7 CJK ideographs, 8 hangul (big: any non-blank is 2)
vclass:
    push rbx
    push r12
    push r13
    mov ebx, esi
    mov r12, rdi
    call vbyte
    cmp eax, 10
    je 1f
    test eax, eax
    jz 1f
    cmp eax, ' '
    je 2f
    cmp eax, 9
    je 2f
    test ebx, ebx
    jnz 3f
    # inside a character: the class of the character
    lea ecx, [rax - 0x80]
    cmp ecx, 0x3f
    ja 4f
    mov rdi, r12
    call vsnap
    mov r12, rax
    mov rdi, rax
    call vbyte
    # characters of three bytes from U+3000: scripts of their own, as in Vim
4:  lea ecx, [rax - 0xe3]
    cmp ecx, 0xef - 0xe3
    ja 5f
    mov r13d, eax
    and r13d, 0x0f
    shl r13d, 12
    lea rdi, [r12 + 1]
    call vbyte
    and eax, 0x3f
    shl eax, 6
    or r13d, eax
    lea rdi, [r12 + 2]
    call vbyte
    and eax, 0x3f
    or eax, r13d
    cmp eax, 0x3040
    jb 41f
    mov ecx, 5
    cmp eax, 0x30a0
    jb 49f
    mov ecx, 6
    cmp eax, 0x3100
    jb 49f
    mov ecx, 7
    cmp eax, 0x3400
    jb 3f
    cmp eax, 0x4dc0
    jb 49f
    cmp eax, 0x4e00
    jb 3f
    cmp eax, 0xa000
    jb 49f
    mov ecx, 8
    cmp eax, 0xac00
    jb 3f
    cmp eax, 0xd7a4
    jb 49f
    mov ecx, 7
    cmp eax, 0xf900
    jb 3f
    cmp eax, 0xfb00
    jb 49f
    jmp 3f
41: cmp eax, 0x3000             # CJK punctuation
    jb 3f
    mov ecx, 3
49: mov eax, ecx
    jmp 9f
5:  mov edi, eax
    call is_ident
    test eax, eax
    jnz 3f
    mov eax, 3
    jmp 9f
1:  mov eax, 1
    jmp 9f
2:  xor eax, eax
    jmp 9f
3:  mov eax, 2
9:  pop r13
    pop r12
    pop rbx
    ret

# vset(pos): cursor there, no selection
vset:
    mov rax, [rip + g_doc]
    mov [rax + DOC_cur], rdi
    mov [rax + DOC_anchor], rdi
    mov qword ptr [rax + DOC_prefx], -1
    jmp ed_touch

# vsetc(pos): vset(vclamp(pos))
vsetc:
    call vclamp
    mov rdi, rax
    jmp vset

# vdelete(pos, len)
vdelete:
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, [rip + g_doc]
    xor ecx, ecx
    jmp doc_delete

# vinsert_buf(pos): insert v_buf at pos
vinsert_buf:
    mov rsi, rdi
    mov rdi, [rip + g_doc]
    mov rdx, [rip + v_buf + SB_ptr]
    mov rcx, [rip + v_buf + SB_len]
    xor r8d, r8d
    jmp doc_insert

# vcopy(s, e): v_buf = text of [s, e)
vcopy:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + v_buf]
    call sb_clear
    mov rsi, r13
    sub rsi, r12
    lea rdi, [rip + v_buf]
    call sb_reserve
    mov rcx, rax
    mov rdi, [rip + g_doc]
    mov rsi, r12
    mov rdx, r13
    sub rdx, r12
    call doc_copy
    mov rax, r13
    sub rax, r12
    add [rip + v_buf + SB_len], rax
    pop r13
    pop r12
    pop rbx
    ret

# ---- pending keys, changes, "." ----

# vrec(keysym, cp, mods): append to v_rec
vrec:
    sub rsp, 24
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    lea rdi, [rip + v_rec]
    mov rsi, rsp
    mov edx, KR_SIZE
    call sb_push
    add rsp, 24
    ret

# vidle() -> 1 when no command is half typed
vidle:
    mov eax, [rip + v_op]
    or eax, [rip + v_prefix]
    or eax, [rip + v_count]
    sete al
    movzx eax, al
    ret

vcancel:
    xor eax, eax
    mov [rip + v_op], eax
    mov [rip + v_prefix], eax
    mov [rip + v_count], eax
    mov [rip + v_opcount], eax
    ret

# vbegin() -> 0 when the document is read-only; else remembers where the change's undo steps begin
vbegin:
    mov rax, [rip + g_doc]
    test dword ptr [rax + DOC_flags], DF_READONLY
    jnz 1f
    mov [rip + v_chgdoc], rax
    mov rcx, [rax + DOC_undo + VEC_len]
    mov [rip + v_chglen], rcx
    mov qword ptr [rax + DOC_lastkind], EK_OTHER
    mov eax, 1
    ret
1:  xor eax, eax
    ret

# vmerge(): the undo steps of the change become one
vmerge:
    mov rax, [rip + g_doc]
    cmp rax, [rip + v_chgdoc]
    jne 9f
    mov qword ptr [rax + DOC_lastkind], EK_OTHER
    mov rcx, [rip + v_chglen]
    mov rdx, [rax + DOC_undo + VEC_len]
    cmp rcx, rdx
    jae 9f
    mov r8, [rax + DOC_undo + VEC_ptr]
    imul rcx, rcx, UR_SIZE
    imul rdx, rdx, UR_SIZE
    mov r9, [r8 + rcx + UR_group]
1:  add rcx, UR_SIZE
    cmp rcx, rdx
    jae 9f
    mov [r8 + rcx + UR_group], r9
    jmp 1b
9:  mov qword ptr [rip + v_chgdoc], 0
    ret

# vsavedot(): this command's keys are what "." types
vsavedot:
    cmp dword ptr [rip + v_replay], 0
    jne 1f
    cmp dword ptr [rip + v_visual], 0
    jne 2f
    push rbx
    lea rdi, [rip + v_dot]
    call sb_clear
    lea rdi, [rip + v_dot]
    mov rsi, [rip + v_rec + SB_ptr]
    mov rdx, [rip + v_rec + SB_len]
    call sb_push
    mov eax, [rip + v_cmdcount]
    mov [rip + v_dotcount], eax
    pop rbx
1:  ret
2:  # a visual change: the same operator from the cursor on as many lines or characters
    push rbx
    lea rdi, [rip + v_dot]
    call sb_clear
    lea rdi, [rip + v_dot]
    mov rsi, [rip + v_vdot + SB_ptr]
    mov rdx, [rip + v_vdot + SB_len]
    call sb_push
    mov eax, [rip + v_vdotcount]
    mov [rip + v_dotcount], eax
    # c: and what was typed
    cmp qword ptr [rip + v_vdot + SB_len], 0
    je 3f
    cmp dword ptr [rip + v_vdotop], 'c'
    jne 3f
    mov rsi, [rip + v_insstart]
    mov rdx, [rip + v_rec + SB_len]
    sub rdx, rsi
    jbe 3f
    add rsi, [rip + v_rec + SB_ptr]
    lea rdi, [rip + v_dot]
    call sb_push
3:  lea rdi, [rip + v_vdot]
    call sb_clear
    pop rbx
    ret

# vdot_visual(op, s, e, lines): v_vdot for a visual change about to be made; s, e are lines when
# lines is set (the operator doubled with their count: dd >> gUU; J once), else positions of
# characters on one line (the operator and l, with their count). Characters over more lines,
# or up to the line end, have no such keys: "." then does nothing.
vdot_visual:
    PROLOGUE
    mov r15d, edi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    mov [rip + v_vdotop], edi
    mov dword ptr [rip + v_vdotcount], 0
    lea rdi, [rip + v_vdot]
    call sb_clear
    cmp r15d, 'y'
    je 9f
    test r14d, r14d
    jz 5f
    mov rax, r13
    sub rax, r12
    inc eax
    cmp r15d, 'J'
    jne 1f
    cmp eax, 2
    jge 2f
    mov eax, 2
    jmp 2f
1:  mov [rip + v_vdotcount], eax
    mov edi, r15d
    call vdot_op
    mov edi, r15d
    call vdot_key
    jmp 9f
2:  mov [rip + v_vdotcount], eax
    mov edi, 'J'
    call vdot_key
    jmp 9f
5:  mov rdi, r12
    call vline
    mov rbx, rax
    mov rdi, r13
    call vline
    cmp rax, rbx
    jne 8f
    mov rdi, rbx
    call vend
    cmp r13, rax
    ja 8f
    xor ebx, ebx
    mov r14, r12
6:  cmp r14, r13
    jae 7f
    mov rdi, r14
    call vnext
    mov r14, rax
    inc ebx
    jmp 6b
7:  test ebx, ebx
    jz 8f
    mov [rip + v_vdotcount], ebx
    mov edi, r15d
    call vdot_op
    mov edi, 'l'
    call vdot_key
    jmp 9f
8:  lea rdi, [rip + v_vdot]
    call sb_clear
9:  EPILOGUE

# vdot_op(op): the keys of an operator into v_vdot (gu gU g~ for u U ~)
vdot_op:
    push rbx
    mov ebx, edi
    cmp ebx, 'u'
    je 1f
    cmp ebx, 'U'
    je 1f
    cmp ebx, '~'
    jne 2f
1:  mov edi, 'g'
    call vdot_key
2:  mov edi, ebx
    call vdot_key
    pop rbx
    ret

# vdot_key(cp): a typed key into v_vdot
vdot_key:
    sub rsp, 24
    mov [rsp], edi
    mov [rsp + 4], edi
    mov dword ptr [rsp + 8], 0
    lea rdi, [rip + v_vdot]
    mov rsi, rsp
    mov edx, KR_SIZE
    call sb_push
    add rsp, 24
    ret

# vundo_pos(records, redo) -> where the change on top of an undo (redo) list begins, -1 if none
vundo_pos:
    mov rcx, [rdi + VEC_len]
    test rcx, rcx
    jz 8f
    mov r8, [rdi + VEC_ptr]
    dec rcx
    imul rcx, rcx, UR_SIZE
    mov r9, [r8 + rcx + UR_group]
    mov rax, -1
    xor r10d, r10d
1:  cmp [r8 + rcx + UR_group], r9
    jne 3f
    mov rdx, [r8 + rcx + UR_pos]
    cmp rdx, rax
    jae 2f
    mov rax, rdx
    lea r10, [r8 + rcx]
2:  sub rcx, UR_SIZE
    jns 1b
3:  # lines deleted at the end of the document went with the newline before them
    test esi, esi
    jnz 9f
    cmp qword ptr [r10 + UR_kind], 2
    jne 9f
    mov rdx, [r10 + UR_text]
    cmp byte ptr [rdx], 10
    jne 9f
    inc rax
9:  ret
8:  mov rax, -1
    ret

# vcommit(): a change is complete
vcommit:
    call vmerge
    call vsavedot
    mov dword ptr [rip + v_visual], 0
    ret

# vinsert(pos, key, count): insert mode at pos (vbegin was called)
vinsert:
    mov dword ptr [rip + v_autoind], 0
    mov [rip + v_inskey], esi
    mov [rip + v_inscount], edx
    mov rax, [rip + v_rec + SB_len]
    mov [rip + v_insstart], rax
    mov qword ptr [rip + v_putdoc], 0
    mov dword ptr [rip + g_vim_mode], VM_INSERT
    jmp vset

# vesc_insert(): Esc in insert mode (already recorded)
vesc_insert:
    PROLOGUE
    mov rbx, [rip + g_doc]
    # a count types the same keys again
    mov r12d, [rip + v_inscount]
    mov dword ptr [rip + v_inscount], 0
    cmp rbx, [rip + v_chgdoc]
    jne 3f
1:  cmp r12d, 1
    jle 3f
    dec r12d
    mov eax, [rip + v_inskey]
    cmp eax, 'o'
    je 11f
    cmp eax, 'O'
    jne 12f
11: call cmd_newline_below
12: mov r13, [rip + v_insstart]
2:  mov rax, [rip + v_rec + SB_len]
    sub rax, KR_SIZE            # not the Esc
    cmp r13, rax
    jge 1b
    mov rcx, [rip + v_rec + SB_ptr]
    mov edi, [rcx + r13]
    mov esi, [rcx + r13 + 4]
    mov edx, [rcx + r13 + 8]
    add r13, KR_SIZE
    call vfeed_edit
    jmp 2b
3:  mov dword ptr [rip + g_vim_mode], VM_NORMAL
    cmp dword ptr [rip + v_autoind], 0
    je 31f
    mov dword ptr [rip + v_autoind], 0
    mov rdi, [rbx + DOC_cur]
    call vline
    mov r13, rax
    mov rdi, rax
    call vstart
    mov r12, rax
    mov rdi, r13
    call vend
    mov r13, rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov rsi, rax
    mov rdi, rbx
    call line_indent
    add rax, r12
    cmp rax, r13
    jne 31f
    cmp r13, r12
    je 31f
    mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    call vdelete
31: mov r12, [rbx + DOC_cur]
    mov rdi, r12
    call vline
    mov rdi, rax
    call vstart
    cmp r12, rax
    jbe 4f
    mov rdi, r12
    call vprev
    mov r12, rax
4:  mov rdi, r12
    call vset
    call vcommit
    EPILOGUE

# vfeed_edit(keysym, cp, mods): a key as the editor takes it without vim
vfeed_edit:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov [rip + g_mods], edx
    mov esi, edx
    call keys_lookup
    test rax, rax
    jz 1f
    call rax
    EPILOGUE
1:  mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call editor_key
    EPILOGUE

# vfeed(keysym, cp, mods): a key as if typed (for ".")
vfeed:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    call vim_key
    test eax, eax
    jnz 9f
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call vfeed_edit
9:  EPILOGUE

# ---- keys ----

# vim_key(keysym, cp, mods) -> 1 when vim took the key (the editor has focus)
FN vim_key
    xor eax, eax
    cmp dword ptr [rip + cfg_vim], 0
    je 1f
    cmp qword ptr [rip + g_doc], 0
    jne 2f
1:  ret
2:  PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    # modifier keys by themselves
    lea eax, [rdi - 0xffe1]
    cmp eax, 0xffee - 0xffe1
    jbe .Lvk_no
    lea eax, [rdi - 0xfe01]
    cmp eax, 0xfe1f - 0xfe01
    jbe .Lvk_no
    cmp dword ptr [rip + g_vim_cmdline], 0
    je 0f
    cmp dword ptr [rip + v_sop], 0
    je 71f
    call vrec
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
71: call vcmdline_key
    jmp .Lvk_yes
0:  cmp dword ptr [rip + g_vim_mode], VM_INSERT
    jne .Lvk_cmd
    # insert mode: all but Esc goes on to the editor, recorded for "."
    call vrec
    cmp r12d, KEY_ESCAPE
    je 72f
    cmp r12d, '['
    jne 71f
    test r14d, MOD_CTRL
    jnz 72f
71: mov dword ptr [rip + v_autoind], 0
72: cmp r12d, KEY_ESCAPE
    je 1f
    cmp r12d, '['
    jne .Lvk_no
    test r14d, MOD_CTRL
    jz .Lvk_no
1:  call vesc_insert
    jmp .Lvk_yes
.Lvk_cmd:
    # a selection made another way is visual mode; the cursor stays on a character
    mov rdi, [rip + g_doc]
    call vim_view
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call vcode
    test eax, eax
    jnz 1f
    # not a vim key: bindings still work (on the selection as drawn), other keys would type or edit
    call vcancel
    mov edi, r12d
    mov esi, r14d
    call keys_lookup
    test rax, rax
    jz .Lvk_yes
    call vim_export
    jmp .Lvk_no
1:  mov r15d, eax
    # a new command: forget the keys of the last one
    call vidle
    test eax, eax
    jz 2f
    mov qword ptr [rip + v_rec + SB_len], 0
2:  # count digits
    cmp dword ptr [rip + v_prefix], 0
    jne 4f
    lea eax, [r15 - '0']
    cmp eax, 9
    ja 4f
    test eax, eax
    jnz 3f
    cmp dword ptr [rip + v_count], 0
    je 4f
3:  mov ecx, [rip + v_count]
    imul ecx, ecx, 10
    add ecx, eax
    cmp ecx, NMAX
    jbe 31f
    mov ecx, NMAX
31: mov [rip + v_count], ecx
    # a count inside the command (d3w) is part of it for "."; one before it is v_cmdcount
    cmp qword ptr [rip + v_rec + SB_len], 0
    je .Lvk_yes
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call vrec
    jmp .Lvk_yes
4:  cmp qword ptr [rip + v_rec + SB_len], 0
    jne 5f
    mov eax, [rip + v_count]
    mov [rip + v_cmdcount], eax
5:  mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    call vrec
    mov edi, r15d
    call vcmd
.Lvk_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
.Lvk_no:
    xor eax, eax
    EPILOGUE

# vcode(keysym, cp, mods) -> the key for vcmd, 0 if vim has no use for it
vcode:
    test edx, MOD_ALT | MOD_SUPER
    jnz 8f
    test edx, MOD_CTRL
    jz 2f
    # ctrl keys of vim; the others, and all with shift (ctrl+shift+d), keep their bindings
    test edx, MOD_SHIFT
    jnz 8f
    mov eax, edi
    lea ecx, [rax - 'A']
    cmp ecx, 25
    ja 1f
    or eax, 0x20
1:  mov ecx, VK_REDO
    cmp eax, 'r'
    je 7f
    mov ecx, VK_HALFDN
    cmp eax, 'd'
    je 7f
    mov ecx, VK_HALFUP
    cmp eax, 'u'
    je 7f
    mov ecx, VK_ESC
    cmp eax, '['
    je 7f
    jmp 8f
2:  lea r8, [rip + vk_keys]
3:  mov eax, [r8]
    test eax, eax
    jz 4f
    cmp eax, edi
    je 5f
    add r8, 8
    jmp 3b
5:  mov eax, [r8 + 4]
    ret
4:  cmp esi, ' '
    jb 8f
    cmp esi, 127
    je 8f
    mov eax, esi
    ret
7:  mov eax, ecx
    ret
8:  xor eax, eax
    ret

# vcmd(key): a key in normal or visual mode
vcmd:
    PROLOGUE 32
    mov r15d, edi
    mov rbx, [rip + g_doc]
    # count: the one before the operator times the one after it
    mov eax, [rip + v_opcount]
    mov ecx, [rip + v_count]
    mov edx, eax
    or edx, ecx
    setnz dl
    movzx edx, dl
    mov [rip + v_has], edx
    test eax, eax
    jnz 1f
    mov eax, 1
1:  test ecx, ecx
    jnz 2f
    mov ecx, 1
2:  imul rax, rcx
    cmp rax, NMAX
    jbe 3f
    mov eax, NMAX
3:  mov [rip + v_n], eax
    cmp r15d, VK_ESC
    je .Lc_esc
    mov eax, [rip + v_prefix]
    test eax, eax
    jnz .Lc_prefix
    # arrows and the like are letters here
    lea rcx, [rip + vk_alias]
4:  mov eax, [rcx]
    test eax, eax
    jz 5f
    cmp eax, r15d
    je 41f
    add rcx, 8
    jmp 4b
41: mov r15d, [rcx + 4]
5:  cmp dword ptr [rip + v_op], 0
    jne .Lc_pending
    lea rcx, [rip + vk_normal]
    cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    jb 6f
    lea rcx, [rip + vk_visual]
6:  mov eax, [rcx]
    test eax, eax
    jz .Lc_motion_key
    cmp eax, r15d
    je 7f
    add rcx, 16
    jmp 6b
7:  jmp [rcx + 8]

.Lc_motion_key:
    cmp r15d, VK_HALFDN
    je .Lc_half
    cmp r15d, VK_HALFUP
    je .Lc_half
    cmp r15d, VK_PGUP
    je .Lc_page
    cmp r15d, VK_PGDN
    je .Lc_page
    mov edi, r15d
    call vmotion
.Lc_motion:                     # rax pos, edx flags: the operator's range, or a move
    test edx, MF_FAIL
    jnz .Lc_done
    cmp dword ptr [rip + v_op], 0
    je 1f
    mov rdi, rax
    mov esi, edx
    call vop_motion
    jmp .Lc_done
1:  mov rdi, rax
    mov esi, edx
    call vmove
.Lc_done:
    call vcancel
    EPILOGUE

.Lc_esc:
    cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    jb 1f
    call vexit_visual
    jmp .Lc_done
1:  lea rdi, [rip + g_ed_find]
    call sb_clear
    jmp .Lc_done

.Lc_setprefix:
    mov [rip + v_prefix], r15d
    EPILOGUE

.Lc_op:
    mov [rip + v_op], r15d
    mov eax, [rip + v_count]
    mov [rip + v_opcount], eax
    mov dword ptr [rip + v_count], 0
    EPILOGUE

# an operator waits for its motion
.Lc_pending:
    mov eax, r15d
    cmp eax, [rip + v_op]
    je .Lc_double
    cmp eax, 'i'
    je .Lc_setprefix
    cmp eax, 'a'
    je .Lc_setprefix
    cmp eax, 'f'
    je .Lc_setprefix
    cmp eax, 'F'
    je .Lc_setprefix
    cmp eax, 't'
    je .Lc_setprefix
    cmp eax, 'T'
    je .Lc_setprefix
    cmp eax, 'g'
    je .Lc_setprefix
    cmp eax, '/'
    je .Lc_search
    cmp eax, '?'
    je .Lc_search
    jmp .Lc_motion_key

# dd cc yy >> << guu gUU g~~: count lines
.Lc_double:
    mov rdi, [rbx + DOC_cur]
    call vline
    mov r12, rax
    mov eax, [rip + v_n]
    lea r13, [r12 + rax - 1]
    call vlast
    cmp r13, rax
    cmova r13, rax
    mov edi, [rip + v_op]
    mov rsi, r12
    mov rdx, r13
    call vop_lines
    jmp .Lc_done

# the second key of two
.Lc_prefix:
    mov dword ptr [rip + v_prefix], 0
    mov r14d, eax
    cmp r15d, 0x110000
    jae .Lc_done
    cmp r14d, 'f'
    je .Lc_find
    cmp r14d, 'F'
    je .Lc_find
    cmp r14d, 't'
    je .Lc_find
    cmp r14d, 'T'
    je .Lc_find
    cmp r14d, 'r'
    je .Lc_r
    cmp r14d, 'i'
    je .Lc_obj
    cmp r14d, 'a'
    je .Lc_obj
    cmp r14d, 'g'
    je .Lc_g
    cmp r14d, 'z'
    je .Lc_z
    cmp r14d, 'Z'
    je .Lc_Z
    jmp .Lc_done

.Lc_find:
    mov [rip + v_fkind], r14d
    mov [rip + v_fchar], r15d
    mov edi, r14d
    mov esi, r15d
    xor edx, edx
    call vfind
    jmp .Lc_motion

.Lc_r:
    mov edi, r15d
    cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    jae 1f
    call vreplace
    jmp .Lc_done
1:  call vvisual_replace
    jmp .Lc_done

.Lc_obj:
    mov edi, r14d
    mov esi, r15d
    call vtextobj
    test ecx, ecx
    jz .Lc_done
    cmp dword ptr [rip + v_op], 0
    je 1f
    cmp ecx, 2
    sete cl
    movzx ecx, cl
    mov edi, [rip + v_op]
    mov rsi, rax
    call vop_range
    jmp .Lc_done
1:  # visual mode: select it
    cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    jb .Lc_done
    mov dword ptr [rip + g_vim_mode], VM_VISUAL
    mov [rbx + DOC_anchor], rax
    mov [rbx + DOC_cur], rax
    cmp rdx, rax
    jbe 2f
    mov rdi, rdx
    call vprev
    mov [rbx + DOC_cur], rax
2:  call ed_touch
    jmp .Lc_done

.Lc_g:
    cmp r15d, 'g'
    jne 1f
    mov edi, VK_GG
    call vmotion
    jmp .Lc_motion
1:  cmp r15d, 'u'
    je 2f
    cmp r15d, 'U'
    je 2f
    cmp r15d, '~'
    jne .Lc_done
2:  # gu gU g~: case operators
    cmp dword ptr [rip + v_op], 0
    je 3f
    cmp r15d, [rip + v_op]
    je .Lc_double
    jmp .Lc_done
3:  cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    jae .Lv_op
    jmp .Lc_op

.Lc_z:
    mov rdi, [rbx + DOC_cur]
    call vline
    mov ecx, [rip + g_ed_h_lines]
    cmp r15d, 't'
    je 2f
    cmp r15d, 'b'
    je 1f
    cmp r15d, '-'
    je 1f
    cmp r15d, 'z'
    je 3f
    cmp r15d, '.'
    jne .Lc_done
3:  shr ecx, 1              # zz: the line in the middle
    sub rax, rcx
    jmp 2f
1:  sub rax, rcx            # zb: at the bottom
    inc rax
2:  test rax, rax           # zt: at the top
    jns 4f
    xor eax, eax
4:  shl rax, 8
    mov [rbx + DOC_scrolly], rax
    mov dword ptr [rip + g_reveal], 0
    jmp .Lc_done

.Lc_Z:
    cmp r15d, 'Z'
    jne 1f
    call vx_wq
    jmp .Lc_done
1:  cmp r15d, 'Q'
    jne .Lc_done
    call vx_qbang
    jmp .Lc_done

# ---- normal mode commands ----

.Lc_i:
    mov r12, [rbx + DOC_cur]
    mov r13d, 'i'
.Lc_ins:                        # insert mode at r12, begun with key r13d
    call vbegin
    test eax, eax
    jz .Lc_done
    mov rdi, r12
    mov esi, r13d
    mov edx, [rip + v_n]
    call vinsert
    jmp .Lc_done
.Lc_a:
    mov r12, [rbx + DOC_cur]
    mov r13d, 'a'
    mov rdi, r12
    call vbyte
    cmp eax, 10
    je .Lc_ins
    test eax, eax
    jz .Lc_ins
    mov rdi, r12
    call vnext
    mov r12, rax
    jmp .Lc_ins
.Lc_I:
    mov rdi, [rbx + DOC_cur]
    call vline
    mov rdi, rax
    call vfirst
    mov r12, rax
    mov r13d, 'I'
    jmp .Lc_ins
.Lc_A:
    mov rdi, [rbx + DOC_cur]
    call vline
    mov rdi, rax
    call vend
    mov r12, rax
    mov r13d, 'A'
    jmp .Lc_ins
.Lc_o:
    call vbegin
    test eax, eax
    jz .Lc_done
    call cmd_newline_below
    mov esi, 'o'
    jmp 1f
.Lc_O:
    call vbegin
    test eax, eax
    jz .Lc_done
    call cmd_newline_above
    mov esi, 'O'
1:  mov rdi, [rbx + DOC_cur]
    mov edx, [rip + v_n]
    call vinsert
    mov dword ptr [rip + v_autoind], 1
    jmp .Lc_done

.Lc_x:
    call vright
    cmp rax, [rbx + DOC_cur]
    je .Lc_done
    mov edi, 'd'
    jmp .Lc_chars
.Lc_s:
    call vright
    mov edi, 'c'
.Lc_chars:                      # edi operator over [cursor, rax)
    mov rsi, [rbx + DOC_cur]
    mov rdx, rax
    xor ecx, ecx
    call vop_range
    jmp .Lc_done
.Lc_X:
    mov r12, [rbx + DOC_cur]
    mov rdi, r12
    call vline
    mov rdi, rax
    call vstart
    mov r13, rax
    mov r14d, [rip + v_n]
1:  cmp r12, r13
    jbe 2f
    mov rdi, r12
    call vprev
    mov r12, rax
    dec r14d
    jnz 1b
2:  cmp r12, [rbx + DOC_cur]
    je .Lc_done
    mov edi, 'd'
    mov rsi, r12
    mov rdx, [rbx + DOC_cur]
    xor ecx, ecx
    call vop_chars
    jmp .Lc_done
.Lc_D:
    mov r14d, 'd'
    jmp 1f
.Lc_C:
    mov r14d, 'c'
1:  call vcount_lines
    mov rdi, rdx
    call vend
    mov edi, r14d
    jmp .Lc_chars
.Lc_S:
    mov r14d, 'c'
    jmp 1f
.Lc_Y:
    mov r14d, 'y'
1:  call vcount_lines
    mov edi, r14d
    mov rsi, rax
    call vop_lines
    jmp .Lc_done
.Lc_J:
    mov rdi, [rbx + DOC_cur]
    call vline
    mov rdi, rax
    mov esi, [rip + v_n]
    dec esi
    jnz 1f
    inc esi
1:  call vjoin
    jmp .Lc_done
.Lc_tilde:
    call vright
    mov r12, rax
    cmp r12, [rbx + DOC_cur]
    je .Lc_done
    call vbegin
    test eax, eax
    jz .Lc_done
    mov edi, '~'
    mov rsi, [rbx + DOC_cur]
    mov rdx, r12
    call vcase
    mov rdi, r12
    call vsetc
    call vcommit
    jmp .Lc_done

.Lc_put:
    test dword ptr [rbx + DOC_flags], DF_READONLY
    jnz .Lc_done
    mov [rip + v_putdoc], rbx
    mov [rip + v_putkind], r15d
    mov eax, [rip + v_n]
    mov [rip + v_putcount], eax
    mov eax, [rip + g_vim_mode]
    mov [rip + v_putmode], eax
    cmp eax, VM_VISUAL
    jae 1f
    call vsavedot
1:  PCALL P_clip_get
    jmp .Lc_done

# u, ctrl+r: the cursor goes where the change was
.Lc_undo:
    xor r14d, r14d
    lea r15, [rip + doc_undo]
    jmp 1f
.Lc_redo:
    mov r14d, DOC_redo - DOC_undo
    lea r15, [rip + doc_redo]
1:  test dword ptr [rbx + DOC_flags], DF_READONLY
    jnz .Lc_done
    mov r12d, [rip + v_n]
    mov r13, -1
2:  lea rdi, [rbx + r14 + DOC_undo]
    mov esi, r14d
    call vundo_pos
    test rax, rax
    js 3f
    mov r13, rax
    mov rdi, rbx
    call r15
    dec r12d
    jnz 2b
3:  test r13, r13
    js .Lc_done
    mov rdi, r13
    call vsetc
    jmp .Lc_done

.Lc_dot:
    cmp qword ptr [rip + v_dot + SB_len], 0
    je .Lc_done
    mov r12d, [rip + v_dotcount]
    cmp dword ptr [rip + v_has], 0
    je 1f
    mov r12d, [rip + v_n]
1:  call vcancel
    mov [rip + v_count], r12d
    inc dword ptr [rip + v_replay]
    xor r13d, r13d
2:  cmp r13, [rip + v_dot + SB_len]
    jae 3f
    cmp qword ptr [rip + g_doc], 0
    je 3f
    mov rcx, [rip + v_dot + SB_ptr]
    mov edi, [rcx + r13]
    mov esi, [rcx + r13 + 4]
    mov edx, [rcx + r13 + 8]
    add r13, KR_SIZE
    call vfeed
    jmp 2b
3:  cmp dword ptr [rip + g_vim_mode], VM_INSERT
    jne 4f
    cmp qword ptr [rip + g_doc], 0
    je 4f
    call vesc_insert
4:  dec dword ptr [rip + v_replay]
    jmp .Lc_done

.Lc_v:
    mov dword ptr [rip + g_vim_mode], VM_VISUAL
    call ed_touch
    jmp .Lc_done
.Lc_V:
    mov dword ptr [rip + g_vim_mode], VM_VLINE
    call ed_touch
    jmp .Lc_done

.Lc_search:
    mov rax, [rbx + DOC_cur]
    mov [rip + v_sfrom], rax
    mov rax, [rbx + DOC_anchor]
    mov [rip + v_sanchor], rax
    mov eax, [rip + v_op]
    mov [rip + v_sop], eax
    mov eax, [rip + v_opcount]
    mov [rip + v_sopcount], eax
    mov eax, [rip + g_find_word]
    mov [rip + v_patword], eax
    lea rdi, [rip + v_pat]
    call sb_clear
    call find_vim_query
    lea rdi, [rip + v_pat]
    mov rsi, rax
    call sb_push
    jmp 2f
.Lc_ex:
    cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    jb 2f
    call vexit_visual
2:  mov [rip + g_vim_cmdline], r15d
    lea rdi, [rip + v_tf]
    call tf_clear
    jmp .Lc_done

# ctrl+d, ctrl+u: half a page, the view goes along
.Lc_half:
    mov eax, [rip + g_ed_h_lines]
    shr eax, 1
    jnz 1f
    inc eax
1:  mov r12, rax
    mov rdi, [rbx + DOC_cur]
    call vline
    mov r13, rax
    cmp qword ptr [rbx + DOC_prefx], -1
    jne 2f
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_col_of
    mov [rbx + DOC_prefx], rax
2:  mov rax, r12
    shl rax, 8
    cmp r15d, VK_HALFUP
    jne 3f
    neg r12
    neg rax
3:  add [rbx + DOC_scrolly], rax
    jns 4f
    mov qword ptr [rbx + DOC_scrolly], 0
4:  lea rax, [r13 + r12]
    test rax, rax
    jns 5f
    xor eax, eax
5:  push rax
    call vlast
    mov rcx, rax
    pop rax
    cmp rax, rcx
    cmova rax, rcx
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rbx + DOC_prefx]
    call doc_pos_at_col
    mov rdi, rax
    mov esi, MF_KEEPX
    call vmove
    jmp .Lc_done

.Lc_page:
    mov edi, 8
    cmp r15d, VK_PGUP
    je 1f
    mov edi, 9
1:  xor esi, esi
    cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    setae sil
    call ed_move
    mov rdi, [rbx + DOC_cur]
    mov esi, MF_KEEPX
    call vmove
    jmp .Lc_done

# ---- visual mode commands ----

.Lv_v:
    mov eax, VM_VISUAL
    jmp 1f
.Lv_V:
    mov eax, VM_VLINE
1:  cmp eax, [rip + g_vim_mode]
    jne 2f
    call vexit_visual
    jmp .Lc_done
2:  mov [rip + g_vim_mode], eax
    call ed_touch
    jmp .Lc_done
.Lv_o:
    mov rax, [rbx + DOC_cur]
    mov rcx, [rbx + DOC_anchor]
    mov [rbx + DOC_cur], rcx
    mov [rbx + DOC_anchor], rax
    call ed_touch
    jmp .Lc_done
.Lv_x:
    mov r15d, 'd'
    jmp .Lv_op
.Lv_s:
    mov r15d, 'c'
.Lv_op:
    mov edi, r15d
    xor esi, esi
    call vvisual_op
    jmp .Lc_done
.Lv_Xd:
    mov r15d, 'd'
    jmp .Lv_lines
.Lv_Y:
    mov r15d, 'y'
    jmp .Lv_lines
.Lv_C:
    mov r15d, 'c'
.Lv_lines:
    mov edi, r15d
    mov esi, 1
    call vvisual_op
    jmp .Lc_done
.Lv_J:
    call vsel_lines
    mov r12, rax
    mov r13, rdx
    mov edi, 'J'
    mov rsi, r12
    mov rdx, r13
    mov ecx, 1
    call vdot_visual
    call vexit_visual
    mov dword ptr [rip + v_visual], 1
    mov rsi, r13
    sub rsi, r12
    jnz 1f
    inc esi
1:  mov rdi, r12
    call vjoin
    mov dword ptr [rip + v_visual], 0
    jmp .Lc_done

# ---- operators ----

# vright() -> end of the count characters from the cursor, not past the line end
vright:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov rbx, [rip + g_doc]
    mov r12, [rbx + DOC_cur]
    mov rdi, r12
    call vline
    mov rdi, rax
    call vend
    mov r13, rax
    mov r14d, [rip + v_n]
1:  cmp r12, r13
    jae 2f
    mov rdi, r12
    call vnext
    mov r12, rax
    dec r14d
    jnz 1b
2:  mov rax, r12
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# vcount_lines() -> rax cursor line, rdx that line + count - 1 (within the document)
vcount_lines:
    push rbx
    mov rax, [rip + g_doc]
    mov rdi, [rax + DOC_cur]
    call vline
    mov rbx, rax
    mov edx, [rip + v_n]
    lea rdx, [rax + rdx - 1]
    push rdx
    call vlast
    pop rdx
    cmp rdx, rax
    cmova rdx, rax
    mov rax, rbx
    pop rbx
    ret

# vmove(pos, flags): the cursor to a motion's end (visual mode keeps the anchor)
vmove:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13d, esi
    mov rbx, [rip + g_doc]
    cmp dword ptr [rip + g_vim_mode], VM_NORMAL
    jne 1f
    mov rdi, r12
    call vclamp
    mov [rbx + DOC_cur], rax
    mov [rbx + DOC_anchor], rax
    jmp 2f
1:  test r13d, MF_EOL
    jnz 11f
    mov rdi, r12
    call vclamp
    mov r12, rax
11: mov [rbx + DOC_cur], r12
2:  test r13d, MF_KEEPX
    jnz 3f
    mov qword ptr [rbx + DOC_prefx], -1
    test r13d, MF_EOL
    jz 3f
    mov qword ptr [rbx + DOC_prefx], EOL_COL
3:  call ed_touch
    pop r13
    pop r12
    pop rbx
    ret

# vexit_visual(): back to normal mode, no selection
vexit_visual:
    mov dword ptr [rip + g_vim_mode], VM_NORMAL
    mov rax, [rip + g_doc]
    mov rdi, [rax + DOC_cur]
    jmp vsetc

# vsel_lines() -> rax first, rdx last line of the visual selection
vsel_lines:
    push rbx
    push r12
    push r13
    mov rbx, [rip + g_doc]
    mov rdi, rbx
    call ed_sel
    mov r12, rax
    mov rdi, rdx
    call vline
    mov r13, rax
    mov rdi, r12
    call vline
    mov rdx, r13
    pop r13
    pop r12
    pop rbx
    ret

# vvisual_op(op, lines): the operator on the visual selection (lines: whole lines even in character mode)
vvisual_op:
    PROLOGUE
    mov r15d, edi
    mov r14d, esi
    mov rbx, [rip + g_doc]
    mov dword ptr [rip + v_visual], 1
    cmp dword ptr [rip + g_vim_mode], VM_VLINE
    je 1f
    test r14d, r14d
    jnz 1f
    mov rdi, rbx
    call vim_sel
    mov r12, rax
    mov r13, rdx
    mov edi, r15d
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    call vdot_visual
    call vexit_visual
    mov edi, r15d
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    call vop_chars
    jmp 2f
1:  call vsel_lines
    mov r12, rax
    mov r13, rdx
    mov edi, r15d
    mov rsi, r12
    mov rdx, r13
    mov ecx, 1
    call vdot_visual
    call vexit_visual
    mov edi, r15d
    mov rsi, r12
    mov rdx, r13
    call vop_lines
2:  cmp dword ptr [rip + g_vim_mode], VM_INSERT
    je 3f
    mov dword ptr [rip + v_visual], 0
3:  EPILOGUE

# vop_motion(pos, flags): the pending operator from the cursor to pos
vop_motion:
    PROLOGUE
    mov rbx, [rip + g_doc]
    mov r12, [rbx + DOC_cur]
    mov r13, rdi
    mov r14d, esi
    cmp r12, r13
    jbe 1f
    xchg r12, r13
1:  test r14d, MF_LINE
    jnz .Lom_lines
    test r14d, MF_INCL
    jz 2f
    mov rdi, r13
    call vnext
    mov r13, rax
    jmp .Lom_chars
2:  # exclusive, ending at the start of a later line: stop at the end of the line before,
    # or take whole lines when it began at or before the first non-blank
    test r14d, MF_NOADJ
    jnz .Lom_chars
    mov rdi, r13
    call vline
    mov r15, rax
    mov rdi, r12
    call vline
    cmp r15, rax
    jbe .Lom_chars
    mov rdi, r15
    call vstart
    cmp r13, rax
    jne .Lom_chars
    mov rdi, r12
    call vline
    mov rdi, rax
    call vfirst
    cmp r12, rax
    ja 3f
    mov rdi, r12
    call vline
    mov rsi, rax
    lea rdx, [r15 - 1]
    mov edi, [rip + v_op]
    call vop_lines
    EPILOGUE
3:  lea rdi, [r15 - 1]
    call vend
    mov r13, rax
.Lom_chars:
    mov edi, [rip + v_op]
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    call vop_range
    EPILOGUE

# vop_range(op, s, e, inner): vop_chars, but d over more lines with only blanks before s and after
# e takes the whole lines, as in Vim
vop_range:
    PROLOGUE
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov r15d, ecx
    cmp ebx, 'd'
    jne 6f
    test r15d, r15d
    jnz 6f
    mov rdi, r12
    call vline
    mov r14, rax
    mov rdi, r13
    call vline
    cmp rax, r14
    je 6f
    mov [rsp], rax
    mov rdi, r14
    call vfirst
    cmp rax, r12
    jb 6f
    mov rdi, r13
    call vblank_to_end
    test eax, eax
    jz 6f
    mov edi, ebx
    mov rsi, r14
    mov rdx, [rsp]
    call vop_lines
    EPILOGUE
6:  mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    mov ecx, r15d
    call vop_chars
    EPILOGUE

# vblank_to_end(pos) -> 1 when there are only blanks from pos to its line end
vblank_to_end:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    call vline
    mov rdi, rax
    call vend
    mov r12, rax
1:  cmp rbx, r12
    jae 2f
    mov rdi, rbx
    call vbyte
    cmp eax, ' '
    je 11f
    cmp eax, 9
    jne 3f
11: inc rbx
    jmp 1b
2:  mov eax, 1
    jmp 4f
3:  xor eax, eax
4:  pop r13
    pop r12
    pop rbx
    ret
.Lom_lines:
    mov rdi, r12
    call vline
    mov r12, rax
    mov rdi, r13
    call vline
    mov rdx, rax
    mov rsi, r12
    mov edi, [rip + v_op]
    call vop_lines
    EPILOGUE

# vop_chars(op, s, e, inner): an operator on [s, e); inner: an i{ over whole lines (c keeps a line to type on)
vop_chars:
    PROLOGUE
    mov r15d, edi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    cmp r12, r13
    jbe 1f
    xchg r12, r13
1:  cmp r15d, '>'
    je .Loc_lines
    cmp r15d, '<'
    je .Loc_lines
    cmp r15d, 'y'
    jne 2f
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    call vyank
    mov rdi, r12
    call vsetc
    EPILOGUE
2:  call vbegin
    test eax, eax
    jz 9f
    cmp r15d, 'd'
    je 3f
    cmp r15d, 'c'
    je 4f
    mov edi, r15d
    mov rsi, r12
    mov rdx, r13
    call vcase
    mov rdi, r12
    call vsetc
    call vcommit
    EPILOGUE
3:  mov rdi, r12
    mov rsi, r13
    xor edx, edx
    call vyank
    mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    call vdelete
    mov rdi, r12
    call vsetc
    call vcommit
    EPILOGUE
4:  mov rdi, r12
    mov rsi, r13
    xor edx, edx
    call vyank
    test r14d, r14d
    jz 41f
    cmp r13, r12
    jbe 41f
    dec r13
    # the line to type on keeps the indentation of the first line
    mov rdi, r12
    call vline
    mov rdi, rax
    call vfirst
    cmp rax, r13
    cmovb r12, rax
41: mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    call vdelete
    mov rdi, r12
    mov esi, 'c'
    mov edx, 1
    call vinsert
    test r14d, r14d
    jz 42f
    mov dword ptr [rip + v_autoind], 1
42: EPILOGUE
.Loc_lines:
    mov rdi, r12
    call vline
    mov rbx, rax
    mov rdi, r12
    cmp r13, r12
    jbe 5f
    lea rdi, [r13 - 1]
5:  call vline
    mov rdx, rax
    mov rsi, rbx
    mov edi, r15d
    call vop_lines
9:  EPILOGUE

# vop_lines(op, first, last): an operator on whole lines
vop_lines:
    PROLOGUE
    mov r15d, edi
    mov r12, rsi
    mov r13, rdx
    cmp r12, r13
    jbe 1f
    xchg r12, r13
1:  mov rbx, [rip + g_doc]
    cmp r15d, 'y'
    jne 2f
    mov rdi, r12
    mov rsi, r13
    call vyank_lines
    # yk, y{: the cursor goes up to the first line
    mov rdi, [rbx + DOC_cur]
    call vline
    cmp rax, r12
    jbe 9f
    mov rdi, rbx
    mov rsi, [rbx + DOC_cur]
    call doc_col_of
    mov rdi, rbx
    mov rsi, r12
    mov edx, eax
    call doc_pos_at_col
    mov rdi, rax
    call vsetc
    jmp 9f
2:  call vbegin
    test eax, eax
    jz 9f
    cmp r15d, 'd'
    je 3f
    cmp r15d, 'c'
    je 4f
    cmp r15d, '>'
    je 5f
    cmp r15d, '<'
    je 5f
    # case of the lines
    mov rdi, r12
    call vstart
    mov r14, rax
    mov rdi, r13
    call vend
    mov rdx, rax
    mov rsi, r14
    mov edi, r15d
    call vcase
    mov rdi, [rbx + DOC_cur]
    call vsetc
    jmp 8f
3:  mov rdi, r12
    mov rsi, r13
    call vyank_lines
    mov rdi, r12
    mov rsi, r13
    call vdel_lines
    call vlast
    cmp r12, rax
    cmova r12, rax
    mov rdi, r12
    call vfirst
    mov rdi, rax
    call vsetc
    jmp 8f
4:  # keep the indentation of the first line
    mov rdi, r12
    mov rsi, r13
    call vyank_lines
    mov rdi, r12
    call vfirst
    mov r14, rax
    mov rdi, r13
    call vend
    mov rsi, rax
    sub rsi, r14
    jbe 41f
    mov rdi, r14
    call vdelete
41: mov rdi, r14
    mov esi, 'c'
    mov edx, 1
    call vinsert
    mov dword ptr [rip + v_autoind], 1
    jmp 9f
5:  # indent: count times in visual mode
    mov r14d, 1
    cmp dword ptr [rip + v_visual], 0
    je 51f
    mov r14d, [rip + v_n]
51: mov rdi, r12
    call vstart
    mov [rbx + DOC_anchor], rax
    mov rdi, r13
    call vend
    mov [rbx + DOC_cur], rax
    mov edi, 1
    cmp r15d, '>'
    je 52f
    mov edi, -1
52: call ed_indent
    dec r14d
    jnz 51b
    mov rdi, r12
    call vfirst
    mov rdi, rax
    call vsetc
8:  call vcommit
9:  EPILOGUE

# vyank(s, e, linewise): the text goes to the clipboard (nothing for an empty range)
vyank:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov ebx, edx
    cmp r12, r13
    jb 0f
    # nothing: an empty line when lines were yanked (yy in an empty file)
    test ebx, ebx
    jz 9f
    lea rdi, [rip + v_buf]
    call sb_clear
    jmp 73f
0:  mov rdi, r12
    mov rsi, r13
    call vcopy
    test ebx, ebx
    jz 1f
    mov rax, [rip + v_buf + SB_len]
    mov rcx, [rip + v_buf + SB_ptr]
    cmp byte ptr [rcx + rax - 1], 10
    je 1f
73: lea rdi, [rip + v_buf]
    mov esi, 10
    call sb_push_byte
1:  mov rdi, [rip + v_buf + SB_ptr]
    mov rsi, [rip + v_buf + SB_len]
    mov edx, ebx
    call ed_clip_set
9:  pop r13
    pop r12
    pop rbx
    ret

# vlines_end(last) -> start of the line after it, or the end of the document
vlines_end:
    push rbx
    mov rbx, rdi
    call vlast_text
    cmp rbx, rax
    jae 1f
    lea rdi, [rbx + 1]
    pop rbx
    jmp vstart
1:  pop rbx
    jmp vlen

# vyank_lines(first, last)
vyank_lines:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    call vstart
    mov r13, rax
    mov rdi, r12
    call vlines_end
    mov rdi, r13
    mov rsi, rax
    mov edx, 1
    call vyank
    pop r13
    pop r12
    pop rbx
    ret

# vdel_lines(first, last): the lines go; at the end of the document the newline before them too
vdel_lines:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call vstart
    mov r14, rax
    mov rdi, r13
    call vlines_end
    mov r15, rax
    call vlast_text
    cmp r13, rax
    jb 1f
    test r12, r12
    jz 1f
    lea rdi, [r12 - 1]
    call vend
    mov r14, rax
1:  mov rdi, r14
    mov rsi, r15
    sub rsi, r14
    call vdelete
    EPILOGUE

# vcase(op, s, e): u lower, U upper, ~ swapped case (ASCII, and the letters of two bytes in UTF-8:
# Latin-1, Latin Extended-A, Greek, Cyrillic); the cursor stays
vcase:
    PROLOGUE 16
    mov rax, [rip + g_doc]
    mov rcx, [rax + DOC_cur]
    mov [rsp], rcx
    mov rcx, [rax + DOC_anchor]
    mov [rsp + 8], rcx
    mov r15d, edi
    mov r12, rsi
    mov r13, rdx
    cmp r12, r13
    jae 9f
    mov rdi, r12
    mov rsi, r13
    call vcopy
    mov rbx, [rip + v_buf + SB_ptr]
    mov r14, [rip + v_buf + SB_len]
    xor ecx, ecx
    xor edx, edx                # changed
1:  cmp rcx, r14
    jae 5f
    movzx eax, byte ptr [rbx + rcx]
    # a character of two bytes
    lea esi, [rax - 0xc0]
    cmp esi, 0x1f
    ja 11f
    lea rsi, [rcx + 1]
    cmp rsi, r14
    jae 4f
    movzx esi, byte ptr [rbx + rcx + 1]
    and eax, 0x1f
    shl eax, 6
    and esi, 0x3f
    or eax, esi
    push rcx
    push rdx
    mov edi, eax
    mov esi, r15d
    call ucase
    pop rdx
    pop rcx
    mov esi, eax
    shr esi, 6
    or esi, 0xc0
    and eax, 0x3f
    or eax, 0x80
    cmp sil, [rbx + rcx]
    jne 12f
    cmp al, [rbx + rcx + 1]
    je 13f
12: mov [rbx + rcx], sil
    mov [rbx + rcx + 1], al
    mov edx, 1
13: add rcx, 2
    jmp 1b
11: lea esi, [rax - 'A']
    cmp esi, 25
    jbe 2f
    lea esi, [rax - 'a']
    cmp esi, 25
    jbe 3f
    jmp 4f
2:  cmp r15d, 'U'           # an upper case letter
    je 4f
    add eax, 32
    jmp 31f
3:  cmp r15d, 'u'           # a lower case letter
    je 4f
    sub eax, 32
31: mov [rbx + rcx], al
    mov edx, 1
4:  inc rcx
    jmp 1b
5:  test edx, edx
    jz 9f
    mov rdi, r12
    mov rsi, r14
    call vdelete
    mov rdi, r12
    call vinsert_buf
    mov rax, [rip + g_doc]
    mov rcx, [rsp]
    mov [rax + DOC_cur], rcx
    mov rcx, [rsp + 8]
    mov [rax + DOC_anchor], rcx
9:  EPILOGUE

# ucase(cp, op) -> cp lower (op u), upper (U) or swapped (~), for letters of U+00C0..U+045F;
# cp itself otherwise
ucase:
    mov eax, edi
    xor ecx, ecx                # partner
    xor edx, edx                # 1 upper, 2 lower
    cmp edi, 0xc0
    jb 9f
    cmp edi, 0xde               # Latin-1
    ja 1f
    cmp edi, 0xd7
    je 9f
    lea ecx, [rdi + 0x20]
    mov edx, 1
    jmp 8f
1:  cmp edi, 0xe0
    jb 9f
    cmp edi, 0xfe
    ja 2f
    cmp edi, 0xf7
    je 9f
    lea ecx, [rdi - 0x20]
    mov edx, 2
    jmp 8f
2:  cmp edi, 0xff
    jne 21f
    mov ecx, 0x178
    mov edx, 2
    jmp 8f
21: cmp edi, 0x178
    jne 22f
    mov ecx, 0xff
    mov edx, 1
    jmp 8f
22: cmp edi, 0x17e              # Latin Extended-A: pairs
    ja 3f
    cmp edi, 0x130
    je 9f
    cmp edi, 0x131
    je 9f
    cmp edi, 0x138
    je 9f
    cmp edi, 0x149
    je 9f
    # odd upper case from 0x139 to 0x148 and from 0x179, even elsewhere
    mov r8d, 0                  # parity of the upper case letter
    cmp edi, 0x139
    jb 23f
    cmp edi, 0x148
    jbe 24f
    cmp edi, 0x179
    jb 23f
24: mov r8d, 1
23: mov ecx, edi
    and ecx, 1
    cmp ecx, r8d
    jne 25f
    mov edx, 1                  # upper: the next one is its lower case
    lea ecx, [rdi + 1]
    jmp 8f
25: mov edx, 2
    lea ecx, [rdi - 1]
    jmp 8f
3:  cmp edi, 0x391              # Greek
    jb 9f
    cmp edi, 0x3a9
    ja 31f
    cmp edi, 0x3a2
    je 9f
    lea ecx, [rdi + 0x20]
    mov edx, 1
    jmp 8f
31: cmp edi, 0x3b1
    jb 9f
    cmp edi, 0x3c9
    ja 4f
    lea ecx, [rdi - 0x20]
    cmp edi, 0x3c2              # final sigma
    jne 32f
    mov ecx, 0x3a3
32: mov edx, 2
    jmp 8f
4:  cmp edi, 0x400              # Cyrillic
    jb 9f
    cmp edi, 0x40f
    ja 41f
    lea ecx, [rdi + 0x50]
    mov edx, 1
    jmp 8f
41: cmp edi, 0x42f
    ja 42f
    lea ecx, [rdi + 0x20]
    mov edx, 1
    jmp 8f
42: cmp edi, 0x44f
    ja 43f
    lea ecx, [rdi - 0x20]
    mov edx, 2
    jmp 8f
43: cmp edi, 0x45f
    ja 9f
    lea ecx, [rdi - 0x50]
    mov edx, 2
8:  cmp esi, '~'
    je 81f
    cmp esi, 'U'
    jne 82f
    cmp edx, 2
    jne 9f
81: mov eax, ecx
    ret
82: cmp edx, 1
    je 81b
9:  ret

# vjoin(line, joins): join the next lines to this one
vjoin:
    PROLOGUE 16
    mov r12, rdi
    mov r13d, esi
    mov rbx, [rip + g_doc]
    call vbegin
    test eax, eax
    jz 9f
    mov r14, [rbx + DOC_cur]
1:  call vlast
    cmp r12, rax
    jae 8f
    mov rdi, r12
    call vend
    mov r14, rax                # the newline
    mov rdi, rbx
    lea rsi, [r12 + 1]
    call line_indent
    lea r15, [r14 + rax + 1]    # first non-blank of the next line
    # one space, unless this line is empty or ends in a blank, or the next is blank or starts with ')'
    mov dword ptr [rsp], 0
    mov rdi, r12
    call vstart
    cmp rax, r14
    je 2f
    lea rdi, [r14 - 1]
    call vbyte
    cmp eax, ' '
    je 2f
    cmp eax, 9
    je 2f
    lea rdi, [r12 + 1]
    call vend
    cmp rax, r15
    je 2f
    mov rdi, r15
    call vbyte
    cmp eax, ')'
    je 2f
    mov dword ptr [rsp], 1
2:  mov rdi, r14
    mov rsi, r15
    sub rsi, r14
    call vdelete
    cmp dword ptr [rsp], 0
    je 3f
    mov rdi, rbx
    mov rsi, r14
    lea rdx, [rip + .Lspace]
    mov ecx, 1
    xor r8d, r8d
    call doc_insert
3:  dec r13d
    jnz 1b
8:  mov rdi, r14
    call vsetc
    call vcommit
9:  EPILOGUE

# vreplace(cp): r: the count characters under the cursor become cp
vreplace:
    PROLOGUE 16
    mov [rsp], edi
    mov rbx, [rip + g_doc]
    mov r12, [rbx + DOC_cur]
    mov rdi, r12
    call vline
    mov rdi, rax
    call vend
    mov r14, rax
    mov r13, r12
    mov r15d, [rip + v_n]
1:  cmp r13, r14
    jae 9f                      # not that many characters
    mov rdi, r13
    call vnext
    mov r13, rax
    dec r15d
    jnz 1b
    call vbegin
    test eax, eax
    jz 9f
    mov edi, [rsp]
    lea rsi, [rsp + 8]
    call utf8_encode
    mov r15, rax
    lea rdi, [rip + v_buf]
    call sb_clear
    mov r14d, [rip + v_n]
2:  lea rdi, [rip + v_buf]
    lea rsi, [rsp + 8]
    mov rdx, r15
    call sb_push
    dec r14d
    jnz 2b
    mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    call vdelete
    mov rdi, r12
    call vinsert_buf
    mov rdi, r12
    add rdi, [rip + v_buf + SB_len]
    sub rdi, r15
    call vset
    call vcommit
9:  EPILOGUE

# vvisual_replace(cp): r in visual mode: every character selected becomes cp
vvisual_replace:
    PROLOGUE 16
    mov [rsp], edi
    lea rdi, [rip + v_vdot]
    call sb_clear
    mov rbx, [rip + g_doc]
    mov rdi, rbx
    call vim_sel
    mov r12, rax
    mov r13, rdx
    call vexit_visual
    call vbegin
    test eax, eax
    jz 9f
    mov dword ptr [rip + v_visual], 1
    mov edi, [rsp]
    lea rsi, [rsp + 8]
    call utf8_encode
    mov r15, rax
    lea rdi, [rip + v_buf]
    call sb_clear
    mov r14, r12
1:  cmp r14, r13
    jae 3f
    mov rdi, r14
    call vbyte
    cmp eax, 10
    jne 2f
    lea rdi, [rip + v_buf]
    mov esi, 10
    call sb_push_byte
    inc r14
    jmp 1b
2:  lea rdi, [rip + v_buf]
    lea rsi, [rsp + 8]
    mov rdx, r15
    call sb_push
    mov rdi, r14
    call vnext
    mov r14, rax
    jmp 1b
3:  mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    call vdelete
    mov rdi, r12
    call vinsert_buf
    mov rdi, r12
    call vsetc
    call vcommit
9:  EPILOGUE

# ---- put ----

# vim_paste(ptr, len) -> 1 when the clipboard text was for p
FN vim_paste
    xor eax, eax
    mov rcx, [rip + v_putdoc]
    test rcx, rcx
    jz 1f
    mov qword ptr [rip + v_putdoc], 0
    cmp rcx, [rip + g_doc]
    jne 1f
    cmp dword ptr [rip + g_vim_mode], VM_INSERT
    je 1f
    push rbx
    call vput
    pop rbx
    mov eax, 1
1:  ret

# vput(ptr, len): p or P with this text
vput:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov rbx, [rip + g_doc]
    test r13, r13
    jz 9f
    # whole lines: our line copy, or text ending in a newline
    mov rdi, r12
    mov rsi, r13
    call ed_clip_linewise
    mov r14d, eax
    cmp byte ptr [r12 + r13 - 1], 10
    jne 1f
    mov r14d, 1
1:  lea rdi, [rip + v_buf]
    call sb_clear
    mov r15d, [rip + v_putcount]
2:  lea rdi, [rip + v_buf]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    dec r15d
    jnz 2b
    mov rdi, rbx
    call doc_begin_group
    cmp dword ptr [rip + v_putmode], VM_VISUAL
    jae .Lpt_visual
    test r14d, r14d
    jnz .Lpt_lines
    # characters: after the cursor (p) or at it (P)
    mov r12, [rbx + DOC_cur]
    cmp dword ptr [rip + v_putkind], 'P'
    je .Lpt_chars
    mov rdi, r12
    call vbyte
    cmp eax, 10
    je .Lpt_chars
    test eax, eax
    jz .Lpt_chars
    mov rdi, r12
    call vnext
    mov r12, rax
.Lpt_chars:                     # v_buf at r12; the cursor on its last character, or its start when it has lines
    mov rdi, r12
    call vinsert_buf
    mov rdi, [rip + v_buf + SB_ptr]
    mov rsi, [rip + v_buf + SB_len]
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    mov rdi, r12
    test rax, rax
    jns 3f
    add rdi, [rip + v_buf + SB_len]
    call vprev
    mov rdi, rax
3:  call vsetc
    jmp .Lpt_end
.Lpt_lines:
    mov rdi, [rbx + DOC_cur]
    call vline
    mov r12, rax
    cmp dword ptr [rip + v_putkind], 'P'
    je 4f
    inc r12
.Lpt_above:                     # the lines go above line r12 (below the last line when r12 is past it)
    call vlast_text
    cmp r12, rax
    ja 5f
4:  mov rdi, r12
    call vstart
    mov rdi, rax
    call vinsert_buf
    jmp 6f
5:  # after the last line: a newline first, the text without its own
    call vlen
    mov r13, rax
    mov rdi, rbx
    mov rsi, r13
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    xor r8d, r8d
    call doc_insert
    dec qword ptr [rip + v_buf + SB_len]
    lea rdi, [r13 + 1]
    call vinsert_buf
6:  mov rdi, r12
    call vfirst
    mov rdi, rax
    call vsetc
    jmp .Lpt_end
.Lpt_visual:
    lea rdi, [rip + v_vdot]
    call sb_clear
    # replace the selection
    mov eax, [rip + v_putmode]
    mov [rip + g_vim_mode], eax
    cmp eax, VM_VLINE
    je 7f
    mov rdi, rbx
    call vim_sel
    mov r12, rax
    mov r13, rdx
    mov dword ptr [rip + g_vim_mode], VM_NORMAL
    mov rdi, r12
    mov rsi, r13
    sub rsi, r12
    call vdelete
    test r14d, r14d
    jz .Lpt_chars
    # lines into a line: on lines of their own
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    xor r8d, r8d
    call doc_insert
    lea rdi, [r12 + 1]
    call vinsert_buf
    lea rdi, [r12 + 1]
    call vsetc
    jmp .Lpt_end
7:  call vsel_lines
    mov r12, rax
    mov r13, rdx
    mov dword ptr [rip + g_vim_mode], VM_NORMAL
    test r14d, r14d
    jnz 8f
    lea rdi, [rip + v_buf]
    mov esi, 10
    call sb_push_byte
8:  mov rdi, r12
    mov rsi, r13
    call vdel_lines
    jmp .Lpt_above
.Lpt_end:
    mov rdi, rbx
    call doc_end_group
    call ed_touch
9:  EPILOGUE

# ---- motions ----

# vmotion(key) -> rax position, edx MF_* (from the cursor, v_n times)
vmotion:
    PROLOGUE 32
    mov r13d, edi
    mov rbx, [rip + g_doc]
    mov r12, [rbx + DOC_cur]
    mov r14d, [rip + v_n]
    xor r15d, r15d
    lea rcx, [rip + vk_motions]
1:  mov eax, [rcx]
    test eax, eax
    jz .Lm_fail
    cmp eax, r13d
    je 2f
    add rcx, 16
    jmp 1b
2:  jmp [rcx + 8]
.Lm_fail:
    mov rax, r12
    mov edx, MF_FAIL
    EPILOGUE
.Lm_ret:
    mov rax, r12
    mov edx, r15d
    EPILOGUE

# rax = min(rax, last line)
.Lm_clampline:
    push rax
    call vlast
    mov rcx, rax
    pop rax
    cmp rax, rcx
    cmova rax, rcx
    ret

.Lm_h:
    mov rdi, r12
    call vline
    mov rdi, rax
    call vstart
    mov [rsp], rax
1:  cmp r12, [rsp]
    jbe .Lm_ret
    mov rdi, r12
    call vprev
    mov r12, rax
    dec r14d
    jnz 1b
    jmp .Lm_ret

.Lm_l:
    mov rdi, r12
    call vline
    mov rdi, rax
    call vend
    mov [rsp], rax
1:  mov rdi, r12
    call vnext
    cmp rax, [rsp]
    ja .Lm_ret
    jb 2f
    # onto the line end only for an operator (dl on the last character)
    cmp dword ptr [rip + v_op], 0
    je .Lm_ret
2:  mov r12, rax
    dec r14d
    jnz 1b
    jmp .Lm_ret

.Lm_bs:
1:  test r12, r12
    jz .Lm_ret
    mov rdi, r12
    call vprev
    mov r12, rax
    # a line end counts with the character before it
    mov rdi, r12
    call vbyte
    cmp eax, 10
    jne 2f
    mov rdi, r12
    call vline
    mov rdi, rax
    call vstart
    cmp rax, r12
    je 2f
    mov rdi, r12
    call vprev
    mov r12, rax
2:  dec r14d
    jnz 1b
    jmp .Lm_ret

.Lm_space:
    call vlen_vim
    mov [rsp], rax
1:  cmp r12, [rsp]
    jae .Lm_ret
    mov rdi, r12
    call vnext
    mov r12, rax
    mov rdi, r12
    call vbyte
    cmp eax, 10
    jne 2f
    mov rdi, r12
    call vline
    mov rdi, rax
    call vstart
    cmp rax, r12
    je 2f
    mov rdi, r12
    call vnext
    mov r12, rax
2:  dec r14d
    jnz 1b
    jmp .Lm_ret

.Lm_j:
    mov rdi, r12
    call vline
    mov [rsp + 8], rax
    add rax, r14
    call .Lm_clampline
    jmp .Lm_vert
.Lm_k:
    mov rdi, r12
    call vline
    mov [rsp + 8], rax
    sub rax, r14
    jns .Lm_vert
    xor eax, eax
.Lm_vert:
    cmp rax, [rsp + 8]
    je .Lm_fail
    mov [rsp], rax
    cmp qword ptr [rbx + DOC_prefx], -1
    jne 1f
    mov rdi, rbx
    mov rsi, r12
    call doc_col_of
    mov [rbx + DOC_prefx], rax
1:  mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, [rbx + DOC_prefx]
    call doc_pos_at_col
    mov r12, rax
    mov r15d, MF_LINE | MF_KEEPX
    jmp .Lm_ret

.Lm_0:
    mov rdi, r12
    call vline
    mov rdi, rax
    call vstart
    mov r12, rax
    jmp .Lm_ret
.Lm_caret:
    mov rdi, r12
    call vline
    mov rdi, rax
    call vfirst
    mov r12, rax
    jmp .Lm_ret
.Lm_dollar:
    mov rdi, r12
    call vline
    lea rax, [rax + r14 - 1]
    call .Lm_clampline
    mov rdi, rax
    call vend
    mov r12, rax
    mov r15d, MF_EOL
    jmp .Lm_ret
.Lm_under:
    mov rdi, r12
    call vline
    lea rax, [rax + r14 - 1]
    call .Lm_clampline
    jmp .Lm_linefirst
.Lm_plus:
    mov rdi, r12
    call vline
    add rax, r14
    mov rcx, rax
    call vnl
    xchg rax, rcx
    cmp rax, rcx
    jae .Lm_fail
    jmp .Lm_linefirst
.Lm_minus:
    mov rdi, r12
    call vline
    sub rax, r14
    js .Lm_fail
    jmp .Lm_linefirst
.Lm_G:
    call vlast
    cmp dword ptr [rip + v_has], 0
    je .Lm_linefirst
    lea rax, [r14 - 1]
    call .Lm_clampline
    jmp .Lm_linefirst
.Lm_gg:
    xor eax, eax
    cmp dword ptr [rip + v_has], 0
    je .Lm_linefirst
    lea rax, [r14 - 1]
    call .Lm_clampline
.Lm_linefirst:
    mov rdi, rax
    call vfirst
    mov r12, rax
    mov r15d, MF_LINE
    jmp .Lm_ret

.Lm_w:
    xor ecx, ecx
    jmp .Lm_words
.Lm_W:
    mov ecx, 1
.Lm_words:
    mov [rsp + 16], ecx
    mov [rsp], r12
    # cw on a word changes to its end, like ce
    cmp dword ptr [rip + v_op], 'c'
    jne 5f
    mov rdi, r12
    mov esi, ecx
    call vclass
    cmp eax, 2
    jb 5f
    mov [rsp + 8], eax
1:  lea rdi, [r12 + 1]
    mov esi, [rsp + 16]
    call vclass
    cmp eax, [rsp + 8]
    jne 2f
    inc r12
    jmp 1b
2:  mov rdi, r12
    call vsnap
    mov r12, rax
    mov r15d, MF_INCL
3:  dec r14d
    jz .Lm_ret
    mov rdi, r12
    mov esi, [rsp + 16]
    call vword_end
    mov r12, rax
    jmp 3b
5:  mov [rsp + 8], r12         # the start of the last word moved over
    mov rdi, r12
    mov esi, [rsp + 16]
    call vword_fwd
    mov r12, rax
    dec r14d
    jnz 5b
    # an operator stops at the end of the line of the last word moved over
    cmp dword ptr [rip + v_op], 0
    je .Lm_ret
    mov rdi, r12
    call vline
    mov r13, rax
    mov rdi, [rsp + 8]
    call vline
    cmp r13, rax
    jbe .Lm_ret
    mov rdi, rax
    call vend
    mov r12, rax
    mov r15d, MF_NOADJ
    # dw on an empty line: the line goes
    cmp rax, [rsp]
    jne .Lm_ret
    cmp dword ptr [rip + v_op], 'd'
    jne .Lm_ret
    mov r15d, MF_LINE
    jmp .Lm_ret

.Lm_e:
    xor ecx, ecx
    jmp 1f
.Lm_E:
    mov ecx, 1
1:  mov [rsp + 16], ecx
2:  mov rdi, r12
    mov esi, [rsp + 16]
    call vword_end
    mov r12, rax
    dec r14d
    jnz 2b
    mov r15d, MF_INCL
    jmp .Lm_ret

.Lm_b:
    xor ecx, ecx
    jmp 1f
.Lm_B:
    mov ecx, 1
1:  mov [rsp + 16], ecx
2:  mov rdi, r12
    mov esi, [rsp + 16]
    call vword_back
    mov r12, rax
    dec r14d
    jnz 2b
    jmp .Lm_ret

.Lm_semi:
    mov edi, [rip + v_fkind]
    test edi, edi
    jz .Lm_fail
    jmp 1f
.Lm_comma:
    mov edi, [rip + v_fkind]
    test edi, edi
    jz .Lm_fail
    xor edi, 0x20               # f F, t T: the other way
1:  mov esi, [rip + v_fchar]
    mov edx, 1
    call vfind
    EPILOGUE

.Lm_pct:
    mov rdi, r12
    call vline
    mov rdi, rax
    call vend
    mov r13, rax
1:  cmp r12, r13
    jae .Lm_fail
    mov rdi, r12
    call vbyte
    mov [rsp + 16], eax
    mov edi, eax
    call vbracket
    test edx, edx
    jnz 2f
    inc r12
    jmp 1b
2:  mov [rsp + 20], eax         # the partner
    movsxd r13, edx             # direction
    xor r14d, r14d              # depth
    mov r15d, 1 << 22           # steps left
    call vlen
    mov [rsp], rax
3:  add r12, r13
    js .Lm_fail
    cmp r12, [rsp]
    jae .Lm_fail
    dec r15d
    jz .Lm_fail
    mov rdi, r12
    call vbyte
    cmp eax, [rsp + 16]
    jne 4f
    inc r14d
    jmp 3b
4:  cmp eax, [rsp + 20]
    jne 3b
    sub r14d, 1
    jns 3b
    mov r15d, MF_INCL
    jmp .Lm_ret

.Lm_pdn:
    mov rdi, r12
    call vline
    mov r13, rax
1:  call vnl                       # past empty lines, then the paragraph
    cmp r13, rax
    jae 2f
    mov rdi, r13
    call vempty
    test eax, eax
    jz 2f
    inc r13
    jmp 1b
2:  call vnl
    cmp r13, rax
    jae 3f
    mov rdi, r13
    call vempty
    test eax, eax
    jnz 3f
    inc r13
    jmp 2b
3:  dec r14d
    jnz 1b
    call vnl
    cmp r13, rax
    jb 4f
    call vlen_vim
    mov r12, rax
    jmp .Lm_ret
4:  mov rdi, r13
    call vstart
    mov r12, rax
    jmp .Lm_ret
.Lm_pup:
    mov rdi, r12
    call vline
    mov r13, rax
1:  test r13, r13
    jz 2f
    mov rdi, r13
    call vempty
    test eax, eax
    jz 2f
    dec r13
    jmp 1b
2:  test r13, r13
    jz 3f
    mov rdi, r13
    call vempty
    test eax, eax
    jnz 3f
    dec r13
    jmp 2b
3:  dec r14d
    jnz 1b
    mov rdi, r13
    call vstart
    mov r12, rax
    jmp .Lm_ret

# H M L: lines on screen, a line of margin as reveal keeps it
.Lm_H:
    mov rax, [rbx + DOC_scrolly]
    sar rax, 8
    test rax, rax
    jz 1f
    inc rax
1:  lea rax, [rax + r14 - 1]
    call .Lm_clampline
    jmp .Lm_linefirst
.Lm_L:
    mov rax, [rbx + DOC_scrolly]
    sar rax, 8
    mov ecx, [rip + g_ed_h_lines]
    lea rax, [rax + rcx - 1]
    push rax
    call vlast
    mov rcx, rax
    pop rax
    cmp rax, rcx
    jl 1f
    mov rax, rcx
    jmp 2f
1:  dec rax
2:  sub rax, r14
    inc rax
    jns .Lm_linefirst
    xor eax, eax
    jmp .Lm_linefirst
.Lm_M:
    mov rax, [rbx + DOC_scrolly]
    sar rax, 8
    mov ecx, [rip + g_ed_h_lines]
    lea rdx, [rax + rcx - 1]
    push rax
    call vlast
    mov rcx, rax
    pop rax
    cmp rdx, rcx
    cmovg rdx, rcx
    add rax, rdx
    sar rax, 1
    jns .Lm_linefirst
    xor eax, eax
    jmp .Lm_linefirst

.Lm_n:
    mov eax, [rip + v_sdir]
    jmp 1f
.Lm_N:
    mov eax, [rip + v_sdir]
    neg eax
1:  mov [rsp + 16], eax
.Lm_search:
    mov rdi, r12
    mov esi, [rsp + 16]
    call find_vim_step
    test rax, rax
    js .Lm_fail
    mov r12, rax
    dec r14d
    jnz .Lm_search
    jmp .Lm_ret
.Lm_star:
    mov eax, 1
    jmp 1f
.Lm_hash:
    mov eax, -1
1:  mov [rip + v_sdir], eax
    mov [rsp + 16], eax
    mov rdi, rbx
    mov rsi, r12
    call word_at
    cmp rax, rdx
    je .Lm_fail
    mov r12, rax                # from the word's start
    sub rdx, rax
    mov [rsp + 8], rdx
    mov rdi, rbx
    mov rsi, rax
    call doc_range
    mov rdi, rax
    mov rsi, [rsp + 8]
    mov edx, 1
    call find_vim_word
    jmp .Lm_search

# vbracket(byte) -> eax partner, edx 1 opening / -1 closing / 0 not a bracket
vbracket:
    lea r8, [rip + .Lbrackets]
    xor ecx, ecx
1:  movzx eax, byte ptr [r8 + rcx]
    test eax, eax
    jz 3f
    cmp eax, edi
    je 2f
    inc ecx
    jmp 1b
2:  test ecx, 1
    jnz 4f
    movzx eax, byte ptr [r8 + rcx + 1]
    mov edx, 1
    ret
4:  movzx eax, byte ptr [r8 + rcx - 1]
    mov edx, -1
    ret
3:  xor edx, edx
    ret

# vword_fwd(pos, big) -> start of the next word (w); an empty line is one
vword_fwd:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    call vlen_vim
    mov r14, rax
    cmp r12, r14
    jae 9f
    mov rdi, r12
    mov esi, r13d
    call vclass
    mov ebx, eax
    cmp ebx, 2
    jb 2f
1:  inc r12
    cmp r12, r14
    jae 9f
    mov rdi, r12
    mov esi, r13d
    call vclass
    cmp eax, ebx
    je 1b
2:  cmp r12, r14
    jae 9f
    mov rdi, r12
    call vbyte
    cmp eax, ' '
    je 3f
    cmp eax, 9
    je 3f
    cmp eax, 10
    jne 9f
    inc r12
    mov rdi, r12
    call vbyte
    cmp eax, 10
    je 9f
    jmp 2b
3:  inc r12
    jmp 2b
9:  mov rax, r12
    EPILOGUE

# vword_end(pos, big) -> end of this or the next word (e)
vword_end:
    PROLOGUE
    mov rbx, rdi
    mov r13d, esi
    call vlen_vim
    mov r14, rax
    mov rdi, rbx
    call vnext
    mov r12, rax
1:  cmp r12, r14
    jae 8f
    mov rdi, r12
    mov esi, r13d
    call vclass
    cmp eax, 1
    ja 2f
    inc r12
    jmp 1b
2:  mov r15d, eax
3:  lea rdi, [r12 + 1]
    cmp rdi, r14
    jae 4f
    mov esi, r13d
    call vclass
    cmp eax, r15d
    jne 4f
    inc r12
    jmp 3b
4:  mov rdi, r12
    call vsnap
    EPILOGUE
8:  # no word after it: the last character
    mov rdi, r14
    call vprev
    cmp rax, rbx
    cmovb rax, rbx
    EPILOGUE

# vword_back(pos, big) -> start of this or the previous word (b); an empty line is one
vword_back:
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    test r12, r12
    jz 9f
    dec r12
1:  mov rdi, r12
    call vbyte
    cmp eax, ' '
    je 2f
    cmp eax, 9
    je 2f
    cmp eax, 10
    jne 3f
    test r12, r12
    jz 9f
    lea rdi, [r12 - 1]
    call vbyte
    cmp eax, 10
    je 9f
2:  test r12, r12
    jz 9f
    dec r12
    jmp 1b
3:  mov rdi, r12
    mov esi, r13d
    call vclass
    mov ebx, eax
4:  test r12, r12
    jz 9f
    lea rdi, [r12 - 1]
    mov esi, r13d
    call vclass
    cmp eax, ebx
    jne 9f
    dec r12
    jmp 4b
9:  mov rax, r12
    EPILOGUE

# vfind(kind, cp, again) -> rax position, edx MF_* : f F t T on the cursor's line, v_n times
# (again: ; and , where t and T skip a match right next to the cursor)
vfind:
    PROLOGUE 48
    mov r14d, edi
    mov [rsp + 40], edx
    mov rbx, [rip + g_doc]
    mov edi, esi
    lea rsi, [rsp]
    call utf8_encode
    mov [rsp + 8], rax          # needle length
    mov rdi, [rbx + DOC_cur]
    call vline
    mov r15, rax
    mov rdi, r15
    call vstart
    mov [rsp + 16], rax         # line start
    mov rdi, rbx
    mov rsi, r15
    call doc_line_text
    mov r13, rax
    mov [rsp + 24], rdx         # line length
    mov r12, [rbx + DOC_cur]
    sub r12, [rsp + 16]         # offset of the cursor
    mov r15d, [rip + v_n]
    cmp r14d, 'f'
    je .Lf_fwd
    cmp r14d, 't'
    je .Lf_fwd
    # backward: the last match before the offset
    cmp r14d, 'T'
    jne 1f
    cmp dword ptr [rsp + 40], 0
    je 1f
    test r12, r12
    jz 1f
    dec r12
1:  mov rcx, r12
2:  test rcx, rcx
    jz .Lf_none
    dec rcx
    mov rax, rcx
    add rax, [rsp + 8]
    cmp rax, [rsp + 24]
    ja 2b
    lea rdi, [r13 + rcx]
    lea rsi, [rsp]
    mov rdx, [rsp + 8]
    push rcx
    push rcx
    call memeq
    pop rcx
    pop rcx
    test eax, eax
    jz 2b
    dec r15d
    jnz 2b
    mov r12, rcx
    add r12, [rsp + 16]
    xor r15d, r15d
    cmp r14d, 'T'
    jne .Lf_ret
    mov rdi, r12
    call vnext
    mov r12, rax
    jmp .Lf_ret
.Lf_fwd:
    lea rcx, [r12 + 1]
    cmp r14d, 't'
    jne 3f
    cmp dword ptr [rsp + 40], 0
    je 3f
    inc rcx
3:  mov [rsp + 32], rcx
    mov rsi, [rsp + 24]
    sub rsi, rcx
    jbe .Lf_none
    lea rdi, [r13 + rcx]
    lea rdx, [rsp]
    mov rcx, [rsp + 8]
    call str_find
    test rax, rax
    js .Lf_none
    add rax, [rsp + 32]
    lea rcx, [rax + 1]
    dec r15d
    jnz 3b
    mov r12, rax
    add r12, [rsp + 16]
    mov r15d, MF_INCL
    cmp r14d, 't'
    jne .Lf_ret
    mov rdi, r12
    call vprev
    mov r12, rax
.Lf_ret:
    mov rax, r12
    mov edx, r15d
    EPILOGUE
.Lf_none:
    mov rax, [rbx + DOC_cur]
    mov edx, MF_FAIL
    EPILOGUE

# ---- text objects ----

# vtextobj(kind, key) -> rax start, rdx end, ecx 0 none / 1 / 2 (an inner block of whole lines)
vtextobj:
    PROLOGUE 48
    mov r14d, edi
    mov r15d, esi
    mov rbx, [rip + g_doc]
    mov r12, [rbx + DOC_cur]
    xor ecx, ecx
    cmp r15d, 'w'
    je .Lto_word
    inc ecx
    cmp r15d, 'W'
    je .Lto_word
    cmp r15d, '"'
    je .Lto_quote
    cmp r15d, 0x27              # '
    je .Lto_quote
    cmp r15d, '`'
    je .Lto_quote
    lea rcx, [rip + .Lobj_pairs]
1:  movzx eax, byte ptr [rcx]
    test eax, eax
    jz .Lto_none
    cmp eax, r15d
    je 2f
    add rcx, 3
    jmp 1b
2:  movzx r13d, byte ptr [rcx + 1]
    movzx eax, byte ptr [rcx + 2]
    mov [rsp + 32], eax
    jmp .Lto_block
.Lto_none:
    xor ecx, ecx
    EPILOGUE

.Lto_word:
    mov [rsp], ecx              # big
    mov rdi, r12
    mov esi, ecx
    call vclass
    cmp eax, 1
    je .Lto_none
    mov r13d, eax
    mov [rsp + 8], r12
1:  mov rax, [rsp + 8]
    test rax, rax
    jz 2f
    lea rdi, [rax - 1]
    mov esi, [rsp]
    call vclass
    cmp eax, r13d
    jne 2f
    dec qword ptr [rsp + 8]
    jmp 1b
2:  mov [rsp + 16], r12
3:  mov rdi, [rsp + 16]
    mov esi, [rsp]
    call vclass
    cmp eax, r13d
    jne 4f
    inc qword ptr [rsp + 16]
    jmp 3b
4:  cmp r14d, 'a'
    jne .Lto_se
    test r13d, r13d
    jz 7f
    # a word: with the blanks after it, else those before it
    mov rdi, [rsp + 16]
    mov esi, [rsp]
    call vclass
    test eax, eax
    jnz 60f
5:  mov rdi, [rsp + 16]
    mov esi, [rsp]
    call vclass
    test eax, eax
    jnz .Lto_se
    inc qword ptr [rsp + 16]
    jmp 5b
60: # (not the indentation of a line's first word)
    mov rax, [rsp + 8]
    mov [rsp + 24], rax
    mov rdi, rax
    call vline
    mov rdi, rax
    call vstart
    mov [rsp + 32], rax
6:  mov rax, [rsp + 8]
    test rax, rax
    jz 61f
    lea rdi, [rax - 1]
    mov esi, [rsp]
    call vclass
    test eax, eax
    jnz 61f
    dec qword ptr [rsp + 8]
    jmp 6b
61: mov rax, [rsp + 8]
    cmp rax, [rsp + 32]
    jne .Lto_se
    mov rax, [rsp + 24]
    mov [rsp + 8], rax
    jmp .Lto_se
7:  # blanks: and the word after them
    mov rdi, [rsp + 16]
    mov esi, [rsp]
    call vclass
    cmp eax, 2
    jb .Lto_se
    mov r13d, eax
8:  mov rdi, [rsp + 16]
    mov esi, [rsp]
    call vclass
    cmp eax, r13d
    jne .Lto_se
    inc qword ptr [rsp + 16]
    jmp 8b
.Lto_se:
    mov rax, [rsp + 8]
    mov rdx, [rsp + 16]
    mov ecx, 1
    EPILOGUE

# quotes pair up from the line start; the pair around the cursor, else the next one
.Lto_quote:
    mov rdi, r12
    call vline
    mov r13, rax
    mov rdi, rax
    call vstart
    mov [rsp], rax              # line start
    mov rdi, rbx
    mov rsi, r13
    call doc_line_text
    mov r13, rax                # text
    mov [rsp + 8], rdx          # length
    sub r12, [rsp]              # cursor offset
    xor ecx, ecx
1:  call .Lto_qnext
    js .Lto_none
    mov [rsp + 16], rcx         # opening
    inc rcx
    call .Lto_qnext
    js .Lto_none
    mov [rsp + 24], rcx         # closing
    inc rcx
    cmp r12, [rsp + 24]
    ja 1b
    mov rax, [rsp + 16]
    mov rdx, [rsp + 24]
    add rax, [rsp]
    add rdx, [rsp]
    cmp r14d, 'a'
    je 2f
    inc rax
    mov ecx, 1
    EPILOGUE
2:  inc rdx
    mov [rsp + 8], rax
    mov [rsp + 16], rdx
    # with the blanks after it, else those before it
    mov rdi, rdx
    call vbyte
    cmp eax, ' '
    je 3f
    cmp eax, 9
    jne 5f
3:  mov rdi, [rsp + 16]
    call vbyte
    cmp eax, ' '
    je 4f
    cmp eax, 9
    jne .Lto_se
4:  inc qword ptr [rsp + 16]
    jmp 3b
5:  mov rax, [rsp + 8]
    cmp rax, [rsp]
    jbe .Lto_se
    lea rdi, [rax - 1]
    call vbyte
    cmp eax, ' '
    je 6f
    cmp eax, 9
    jne .Lto_se
6:  dec qword ptr [rsp + 8]
    jmp 5b
# rcx = offset of the next quote at or after rcx that no backslash escapes, sign set when none
.Lto_qnext:
1:  cmp rcx, [rsp + 16]         # [rsp + 8] of the caller: length
    jae 3f
    movzx eax, byte ptr [r13 + rcx]
    cmp eax, r15d
    jne 2f
    test rcx, rcx
    jz 4f
    cmp byte ptr [r13 + rcx - 1], 0x5c
    jne 4f
2:  inc rcx
    jmp 1b
3:  mov rcx, -1
4:  test rcx, rcx
    ret

# brackets: r13d opening, [rsp + 32] closing
.Lto_block:
    mov [rsp + 40], r14d        # i or a; r14 counts depth
    mov rdi, r12
    call vbyte
    cmp eax, r13d
    je 3f
    xor r14d, r14d
    mov r15, r12
1:  test r15, r15
    jz .Lto_none
    dec r15
    mov rdi, r15
    call vbyte
    cmp eax, [rsp + 32]
    jne 2f
    inc r14d
    jmp 1b
2:  cmp eax, r13d
    jne 1b
    sub r14d, 1
    jns 1b
    mov r12, r15
3:  # r12 opening; its partner
    call vlen
    mov [rsp + 24], rax
    xor r14d, r14d
    mov r15, r12
4:  inc r15
    cmp r15, [rsp + 24]
    jae .Lto_none
    mov rdi, r15
    call vbyte
    cmp eax, r13d
    jne 5f
    inc r14d
    jmp 4b
5:  cmp eax, [rsp + 32]
    jne 4b
    sub r14d, 1
    jns 4b
    # r12 opening, r15 closing
    cmp dword ptr [rsp + 40], 'a'
    jne 6f
    mov rax, r12
    lea rdx, [r15 + 1]
    mov ecx, 1
    EPILOGUE
6:  lea r13, [r12 + 1]          # inside
    mov [rsp + 8], r15
    mov dword ptr [rsp + 16], 0
    mov rdi, r13
    call vbyte
    cmp eax, 10
    jne 7f
    inc r13
    inc dword ptr [rsp + 16]
7:  # the closing bracket after blanks at a line start: the inside ends with the line before
    mov rdi, r15
    call vline
    mov r14, rax
    mov rdi, r12
    call vline
    cmp r14, rax
    jbe 9f
    mov rdi, r14
    call vstart
    mov r14, rax
    mov rcx, rax
8:  cmp rcx, r15
    jae 81f
    mov rdi, rcx
    push rcx
    push rcx
    call vbyte
    pop rcx
    pop rcx
    cmp eax, ' '
    je 82f
    cmp eax, 9
    jne 9f
82: inc rcx
    jmp 8b
81: mov [rsp + 8], r14
    inc dword ptr [rsp + 16]
9:  mov rax, r13
    mov rdx, [rsp + 8]
    cmp rax, rdx
    cmova rax, rdx
    mov ecx, 1
    cmp dword ptr [rsp + 16], 2
    jne 91f
    mov ecx, 2
91: EPILOGUE

# ---- state for the rest of the app ----

# vim_sel(doc) -> rax start, rdx end of the selection as drawn (visual mode includes the cursor's character)
FN vim_sel
    cmp dword ptr [rip + cfg_vim], 0
    je ed_sel
    cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    jb ed_sel
    PROLOGUE
    mov rbx, rdi
    call ed_sel
    mov r12, rax
    mov r13, rdx
    cmp dword ptr [rip + g_vim_mode], VM_VLINE
    je 1f
    mov rdi, rbx
    mov rsi, r13
    call doc_next_char
    mov r13, rax
    jmp 9f
1:  mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov r12, rax
    mov rdi, rbx
    mov rsi, r13
    call doc_line_of
    lea rsi, [rax + 1]
    cmp rsi, [rbx + DOC_nlines]
    jae 2f
    mov rdi, rbx
    call doc_line_start
    mov r13, rax
    jmp 9f
2:  mov rdi, rbx
    call doc_len
    mov r13, rax
9:  mov rax, r12
    mov rdx, r13
    EPILOGUE

# vim_view(doc): before drawing: a selection from the mouse or a command is visual mode;
# the normal mode cursor stays on a character
FN vim_view
    cmp dword ptr [rip + g_focus], FOCUS_EDITOR
    jne 1f
    cmp dword ptr [rip + g_vim_cmdline], 0
    jne 1f
    cmp dword ptr [rip + g_vim_mode], VM_NORMAL
    je 2f
1:  ret
2:  PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + DOC_cur]
    cmp r12, [rbx + DOC_anchor]
    je 3f
    call vcancel
    # the selection vim_export made, untouched: the visual mode it came from
    cmp rbx, [rip + v_exdoc]
    jne 5f
    mov qword ptr [rip + v_exdoc], 0
    cmp r12, [rip + v_exout]
    jne 5f
    mov rax, [rbx + DOC_anchor]
    cmp rax, [rip + v_exout + 8]
    jne 5f
    mov eax, [rip + v_exmode]
    mov [rip + g_vim_mode], eax
    mov rax, [rip + v_excur]
    mov [rbx + DOC_cur], rax
    mov rax, [rip + v_exanchor]
    mov [rbx + DOC_anchor], rax
    jmp 9f
5:  mov dword ptr [rip + g_vim_mode], VM_VISUAL
    # the end that is past the last character selected steps back onto it
    lea r13, [rbx + DOC_cur]
    cmp r12, [rbx + DOC_anchor]
    ja 4f
    lea r13, [rbx + DOC_anchor]
4:  mov rdi, rbx
    mov rsi, [r13]
    call doc_prev_char
    mov [r13], rax
    jmp 9f
3:  mov rdi, r12
    call vclamp
    mov [rbx + DOC_cur], rax
    mov [rbx + DOC_anchor], rax
9:  EPILOGUE

# vim_export(): the visual selection becomes the editor's own, as drawn, for its commands
# (vim_view turns it back into the same visual selection)
FN vim_export
    cmp dword ptr [rip + cfg_vim], 0
    je 1f
    cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    jae 2f
1:  ret
2:  PROLOGUE
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov [rip + v_exdoc], rbx
    mov eax, [rip + g_vim_mode]
    mov [rip + v_exmode], eax
    mov rax, [rbx + DOC_cur]
    mov [rip + v_excur], rax
    mov rax, [rbx + DOC_anchor]
    mov [rip + v_exanchor], rax
    mov rdi, rbx
    call vim_sel
    mov rcx, [rbx + DOC_cur]
    cmp rcx, [rbx + DOC_anchor]
    jb 3f
    mov [rbx + DOC_anchor], rax
    mov [rbx + DOC_cur], rdx
    jmp 4f
3:  mov [rbx + DOC_anchor], rdx
    mov [rbx + DOC_cur], rax
4:  mov rax, [rbx + DOC_cur]
    mov [rip + v_exout], rax
    mov rax, [rbx + DOC_anchor]
    mov [rip + v_exout + 8], rax
    mov dword ptr [rip + g_vim_mode], VM_NORMAL
    call vcancel
9:  EPILOGUE

# vim_click(): a click closes the command line; without shift it ends visual mode
FN vim_click
    cmp dword ptr [rip + cfg_vim], 0
    je 1f
    call vcmdline_close
    test dword ptr [rip + g_mods], MOD_SHIFT
    jnz 1f
    cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    jb vcancel
    mov dword ptr [rip + g_vim_mode], VM_NORMAL
    jmp vcancel
1:  ret

# vleave(): out of insert and visual mode and the command line
vleave:
    push rbx
    mov qword ptr [rip + v_putdoc], 0
    call vcmdline_close
    call vcancel
    mov eax, [rip + g_vim_mode]
    mov dword ptr [rip + g_vim_mode], VM_NORMAL
    cmp eax, VM_INSERT
    jne 1f
    mov dword ptr [rip + v_inscount], 0
    call vcommit
    jmp 9f
1:  cmp eax, VM_VISUAL
    jb 9f
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov rax, [rbx + DOC_cur]
    mov [rbx + DOC_anchor], rax
9:  pop rbx
    ret

# vim_leave(): another tab
FN vim_leave
    cmp dword ptr [rip + cfg_vim], 0
    jne vleave
    ret

# vim_sync(): after settings changed
FN vim_sync
    mov eax, [rip + cfg_vim]
    cmp eax, [rip + v_on]
    je 1f
    mov [rip + v_on], eax
    jmp vleave
1:  ret

# vim_forget(doc): the document is closed
FN vim_forget
    cmp rdi, [rip + v_chgdoc]
    jne 1f
    mov qword ptr [rip + v_chgdoc], 0
1:  cmp rdi, [rip + v_putdoc]
    jne 2f
    mov qword ptr [rip + v_putdoc], 0
2:  cmp rdi, [rip + v_exdoc]
    jne 3f
    mov qword ptr [rip + v_exdoc], 0
3:  ret

FN cmd_toggle_vim
    xor dword ptr [rip + cfg_vim], 1
    mov dword ptr [rip + g_settings_changed], 1
    mov dword ptr [rip + g_dirty], 1
    jmp vim_sync

# vim_mode_name() -> "normal", "insert", "visual", "vline", "command" after ':', "search" after / and ?
FN vim_mode_name
    mov ecx, [rip + g_vim_cmdline]
    lea rax, [rip + .Lm_command]
    cmp ecx, ':'
    je 1f
    lea rax, [rip + .Ls_search]
    test ecx, ecx
    jnz 1f
    mov eax, [rip + g_vim_mode]
    lea rcx, [rip + .Lmode_names]
    mov rax, [rcx + rax*8]
1:  ret

# vim_status() -> the mode and the keys typed so far, for the status bar
FN vim_status
    PROLOGUE
    lea rdi, [rip + v_stat]
    mov eax, [rip + g_vim_mode]
    lea rcx, [rip + .Lmode_titles]
    mov rsi, [rcx + rax*8]
    call cstr_copy
    mov rbx, rax
    call vidle
    test eax, eax
    jnz 9f
    mov byte ptr [rbx], ' '
    inc rbx
    mov esi, [rip + v_opcount]
    test esi, esi
    jz 1f
    mov rdi, rbx
    call fmt_u64
    add rbx, rax
1:  mov eax, [rip + v_op]
    call .Lst_key
    mov esi, [rip + v_count]
    test esi, esi
    jz 2f
    mov rdi, rbx
    call fmt_u64
    add rbx, rax
2:  mov eax, [rip + v_prefix]
    call .Lst_key
    mov byte ptr [rbx], 0
9:  lea rax, [rip + v_stat]
    EPILOGUE
# the letters of an operator (gU is stored as U) or a prefix key
.Lst_key:
    test eax, eax
    jz 2f
    cmp eax, 'u'
    je 1f
    cmp eax, 'U'
    je 1f
    cmp eax, '~'
    jne 3f
    cmp dword ptr [rip + v_op], eax
    jne 3f
1:  mov byte ptr [rbx], 'g'
    inc rbx
3:  mov [rbx], al
    inc rbx
2:  ret

# ---- the : command line ----

# vcmdline_key(keysym, cp, mods): Enter runs the command or search; Esc, or Backspace on nothing, closes it
vcmdline_key:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    cmp r12d, KEY_ESCAPE
    je 2f
    cmp r12d, '['
    jne 1f
    test r14d, MOD_CTRL
    jnz 2f
1:  cmp r12d, KEY_RETURN
    je 3f
    cmp r12d, KEY_KP_ENTER
    je 3f
    cmp r12d, KEY_BACKSPACE
    jne 4f
    cmp qword ptr [rip + v_tf + TF_sb + SB_len], 0
    je 2f
4:  lea rdi, [rip + v_tf]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call tf_key
    call vim_field_changed
    EPILOGUE
2:  call vcmdline_close
    EPILOGUE
3:  mov eax, [rip + g_vim_cmdline]
    mov dword ptr [rip + g_vim_cmdline], 0
    cmp eax, ':'
    jne 5f
    lea rdi, [rip + v_tf]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call vim_ex
    EPILOGUE
5:  mov edi, eax
    call vsearch_accept
    EPILOGUE

# vcmdline_close(): closed without Enter; a search goes back to where it began
vcmdline_close:
    mov eax, [rip + g_vim_cmdline]
    mov dword ptr [rip + g_vim_cmdline], 0
    test eax, eax
    jz 1f
    cmp eax, ':'
    jne vsearch_cancel
1:  ret

# vim_field_changed(): the text of a / or ? search changed: the cursor to the first match from where
# it began (? before it), the matches marked
FN vim_field_changed
    mov eax, [rip + g_vim_cmdline]
    test eax, eax
    jz 1f
    cmp eax, ':'
    jne 2f
1:  ret
2:  PROLOGUE
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    lea rdi, [rip + v_tf]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    xor edx, edx
    call find_vim_word
    mov r12, [rip + v_sfrom]
    mov [rbx + DOC_cur], r12
    mov [rbx + DOC_anchor], r12
    mov rdi, r12
    mov esi, 1
    cmp dword ptr [rip + g_vim_cmdline], '?'
    jne 3f
    mov esi, -1
3:  call find_vim_step
    test rax, rax
    js 8f
    mov [rbx + DOC_anchor], rax
    add rax, [rip + v_tf + TF_sb + SB_len]
    mov [rbx + DOC_cur], rax
8:  call ed_touch
9:  EPILOGUE

# vsearch_accept(key): Enter after / or ?: to the match; with nothing typed, the last pattern again
vsearch_accept:
    PROLOGUE
    mov r13d, 1
    cmp edi, '?'
    jne 1f
    mov r13d, -1
1:  mov [rip + v_sdir], r13d
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    cmp qword ptr [rip + v_tf + TF_sb + SB_len], 0
    jne 2f
    mov rdi, [rip + v_pat + SB_ptr]
    mov rsi, [rip + v_pat + SB_len]
    mov edx, [rip + v_patword]
    call find_vim_word
2:  mov rdi, [rip + v_sfrom]
    mov esi, r13d
    call find_vim_step
    test rax, rax
    jns 4f
    # not found: say so, stay
    call find_vim_query
    test rdx, rdx
    jz 3f
    mov r12, rax
    mov r13, rdx
    lea rdi, [rip + v_buf]
    call sb_clear
    lea rdi, [rip + v_buf]
    lea rsi, [rip + .Lnot_found]
    call sb_push_cstr
    lea rdi, [rip + v_buf]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + v_buf]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + v_buf + SB_ptr]
    call app_toast
3:  mov rax, [rip + v_sfrom]
    # an operator does nothing without a match
    mov dword ptr [rip + v_sop], 0
4:  mov r12, rax
    mov rax, [rip + v_sfrom]
    mov [rbx + DOC_cur], rax
    mov rax, [rip + v_sanchor]
    mov [rbx + DOC_anchor], rax
    mov eax, [rip + v_sop]
    test eax, eax
    jnz 5f
    mov rdi, r12
    cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    jae 41f
    call vset
    jmp 9f
41: xor esi, esi
    call vmove
    jmp 9f
5:  mov dword ptr [rip + v_sop], 0
    mov [rip + v_op], eax
    mov eax, [rip + v_sopcount]
    mov [rip + v_opcount], eax
    mov rdi, r12
    xor esi, esi
    call vop_motion
    call vcancel
9:  EPILOGUE

# vsearch_cancel(): back to where the search began; n and N keep the pattern from before
vsearch_cancel:
    mov dword ptr [rip + v_sop], 0
    PROLOGUE
    mov rdi, [rip + v_pat + SB_ptr]
    mov rsi, [rip + v_pat + SB_len]
    mov edx, [rip + v_patword]
    call find_vim_word
    lea rdi, [rip + g_ed_find]
    call sb_clear
    mov rbx, [rip + g_doc]
    test rbx, rbx
    jz 9f
    mov rdi, [rip + v_sfrom]
    cmp dword ptr [rip + g_vim_mode], VM_VISUAL
    jae 1f
    call vset
    jmp 9f
1:  mov [rbx + DOC_cur], rdi
    mov rax, [rip + v_sanchor]
    mov [rbx + DOC_anchor], rax
    call ed_touch
9:  EPILOGUE

# vim_field() -> the command line's text field while it is open (pastes go there), else 0
FN vim_field
    xor eax, eax
    cmp dword ptr [rip + g_vim_cmdline], 0
    je 1f
    lea rax, [rip + v_tf]
1:  ret

# vim_cmdline_draw(x, y, h): ':' (or / ?) and what was typed after it, in the status bar
FN vim_cmdline_draw
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov eax, [rip + g_vim_cmdline]
    mov [rsp], eax
    lea rdi, [rip + g_face_small]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    lea r8, [rsp]
    COLOR r9d, T_UI_FG
    call ui_text_c
    mov r15d, eax
    lea rdi, [rip + v_tf]
    call tf_text
    mov rbx, rax
    mov [rsp], rdx
    lea rdi, [rip + g_face_small]
    mov rsi, rbx
    mov rdx, [rip + v_tf + TF_cur]
    call text_width
    add eax, r15d
    mov [rsp + 8], eax          # caret x
    lea rdi, [rip + g_face_small]
    mov esi, r15d
    mov edx, r13d
    mov ecx, r14d
    mov r8, rbx
    mov r9, [rsp]
    COLOR eax, T_UI_FG
    push rax
    push rax
    call ui_text_v
    add rsp, 16
    # caret: as tall as the text, centered like it
    lea rax, [rip + g_face_small]
    mov ecx, [rax + FACE_ascent]
    add ecx, [rax + FACE_descent]
    mov esi, r14d
    sub esi, ecx
    sar esi, 1
    add esi, r13d
    mov edi, [rsp + 8]
    M edx, MI_2
    COLOR r8d, T_CURSOR
    call gfx_fill
    EPILOGUE

# vim_ex(ptr, len): run a command typed after ':'
FN vim_ex
    PROLOGUE 16
    call trim
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 9f
    cmp qword ptr [rip + g_doc], 0
    je 1f
    # a line number, or $
    cmp r13, 1
    jne 11f
    cmp byte ptr [r12], '$'
    jne 11f
    call vlast
    jmp 12f
11: mov rdi, r12
    mov rsi, r13
    call parse_u64
    cmp rdx, r13
    jne 1f
    dec rax
    jns 12f
    xor eax, eax
12: call .Lm_clampline_g
    mov rdi, rax
    call vfirst
    mov rdi, rax
    call vsetc
    jmp 9f
1:  # the command and what follows it
    mov rdi, r12
    mov rsi, r13
    call next_word
    mov r14, rax
    mov r15, rdx
    lea rdi, [r12 + rcx]
    mov rsi, r13
    sub rsi, rcx
    call trim
    mov [rsp], rax
    mov [rsp + 8], rdx
    lea rbx, [rip + .Lex_table]
2:  mov rdx, [rbx]
    test rdx, rdx
    jz 3f
    mov rdi, r14
    mov rsi, r15
    call str_eq_cstr
    test eax, eax
    jnz 4f
    add rbx, 16
    jmp 2b
4:  mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call [rbx + 8]
    jmp 9f
3:  lea rdi, [rip + v_buf]
    call sb_clear
    lea rdi, [rip + v_buf]
    lea rsi, [rip + .Lnot_cmd]
    call sb_push_cstr
    lea rdi, [rip + v_buf]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + v_buf]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + v_buf + SB_ptr]
    call app_toast
9:  EPILOGUE

.Lm_clampline_g:
    push rax
    call vlast
    mov rcx, rax
    pop rax
    cmp rax, rcx
    cmova rax, rcx
    ret

vx_w:
    jmp cmd_save
vx_q:
    jmp cmd_close_tab
vx_qbang:
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 1f
    jmp app_close_tab_now
1:  ret
vx_wq:
    push rbx
    call cmd_save
    mov rdi, [rip + g_doc]
    test rdi, rdi
    jz 1f
    call doc_dirty
    test eax, eax
    jnz 1f
    call cmd_close_tab
1:  pop rbx
    ret
vx_qabang:
    call session_save
    mov dword ptr [rip + g_quit], 1
    ret
# wa: every changed file that has a path
vx_wa:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 9f
    mov rdi, rbx
    call tab_at
    inc rbx
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 1b
    mov r12, [rax + TAB_doc]
    test dword ptr [r12 + DOC_flags], DF_READONLY
    jnz 1b
    cmp qword ptr [r12 + DOC_path], 0
    je 1b
    mov rdi, r12
    call doc_dirty
    test eax, eax
    jz 1b
    mov rdi, r12
    call doc_save
    test rax, rax
    js 1b
    mov rdi, r12
    call app_after_save
    jmp 1b
9:  EPILOGUE
vx_wqa:
    call vx_wa
    jmp cmd_quit
vx_noh:
    lea rdi, [rip + g_ed_find]
    jmp sb_clear
# e path: open it (relative to the project); e!: back to the file on disk
vx_e:
    PROLOGUE
    test rsi, rsi
    jz 9f
    call mem_dup
    mov r12, rax
    mov r13, rax
    PATH_ABSOLUTE r12, 1f
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 1f
    mov rsi, r12
    call path_join
    mov r13, rax
1:  mov rdi, r13
    call app_open_path
    cmp r13, r12
    je 2f
    mov rdi, r13
    call mem_free
2:  mov rdi, r12
    call mem_free
9:  EPILOGUE
vx_ebang:
    jmp cmd_reload_file

.section .rodata
.Lspace: .ascii " "
.Lnl: .ascii "\n"
.Lbrackets: .asciz "()[]{}"
.Lnot_cmd: .asciz "Not an editor command: "
# text objects: key, opening, closing
.Lobj_pairs:
    .byte '(', '(', ')', ')', '(', ')', 'b', '(', ')'
    .byte '{', '{', '}', '}', '{', '}', 'B', '{', '}'
    .byte '[', '[', ']', ']', '[', ']', '<', '<', '>', '>', '<', '>'
    .byte 0
.Lm_normal: .asciz "normal"
.Lm_insert: .asciz "insert"
.Lm_visual: .asciz "visual"
.Lm_vline: .asciz "vline"
.Lm_command: .asciz "command"
.Ls_search: .asciz "search"
.Lnot_found: .asciz "Pattern not found: "
.Lt_normal: .asciz "NORMAL"
.Lt_insert: .asciz "INSERT"
.Lt_visual: .asciz "VISUAL"
.Lt_vline: .asciz "VISUAL LINE"
.Lx_w: .asciz "w"
.Lx_write: .asciz "write"
.Lx_q: .asciz "q"
.Lx_quit: .asciz "quit"
.Lx_clo: .asciz "clo"
.Lx_close: .asciz "close"
.Lx_qbang: .asciz "q!"
.Lx_quitbang: .asciz "quit!"
.Lx_wq: .asciz "wq"
.Lx_x: .asciz "x"
.Lx_xit: .asciz "xit"
.Lx_exit: .asciz "exit"
.Lx_qa: .asciz "qa"
.Lx_qall: .asciz "qall"
.Lx_quitall: .asciz "quitall"
.Lx_qabang: .asciz "qa!"
.Lx_qallbang: .asciz "qall!"
.Lx_wa: .asciz "wa"
.Lx_wall: .asciz "wall"
.Lx_wqa: .asciz "wqa"
.Lx_xa: .asciz "xa"
.Lx_noh: .asciz "noh"
.Lx_nohl: .asciz "nohlsearch"
.Lx_e: .asciz "e"
.Lx_edit: .asciz "edit"
.Lx_ebang: .asciz "e!"
.p2align 3
.Lmode_names: .quad .Lm_normal, .Lm_insert, .Lm_visual, .Lm_vline
.Lmode_titles: .quad .Lt_normal, .Lt_insert, .Lt_visual, .Lt_vline
.Lex_table:
    .quad .Lx_w, vx_w, .Lx_write, vx_w, .Lx_q, vx_q, .Lx_quit, vx_q, .Lx_clo, vx_q, .Lx_close, vx_q
    .quad .Lx_qbang, vx_qbang, .Lx_quitbang, vx_qbang
    .quad .Lx_wq, vx_wq, .Lx_x, vx_wq, .Lx_xit, vx_wq, .Lx_exit, vx_wq
    .quad .Lx_qa, cmd_quit, .Lx_qall, cmd_quit, .Lx_quitall, cmd_quit
    .quad .Lx_qabang, vx_qabang, .Lx_qallbang, vx_qabang
    .quad .Lx_wa, vx_wa, .Lx_wall, vx_wa, .Lx_wqa, vx_wqa, .Lx_xa, vx_wqa
    .quad .Lx_noh, vx_noh, .Lx_nohl, vx_noh
    .quad .Lx_e, vx_e, .Lx_edit, vx_e, .Lx_ebang, vx_ebang
    .quad 0, 0
# keysyms of keys without a character
vk_keys:
    .long KEY_ESCAPE, VK_ESC, KEY_LEFT, VK_LEFT, KEY_RIGHT, VK_RIGHT, KEY_UP, VK_UP
    .long KEY_DOWN, VK_DOWN, KEY_HOME, VK_HOME, KEY_END, VK_END, KEY_PAGEUP, VK_PGUP
    .long KEY_PAGEDOWN, VK_PGDN, KEY_BACKSPACE, VK_BS, KEY_DELETE, VK_DEL
    .long KEY_RETURN, VK_ENTER, KEY_KP_ENTER, VK_ENTER, KEY_TAB, VK_NOP, KEY_ISO_LEFT_TAB, VK_NOP
    .long 0, 0
# ... and the letters they stand for
vk_alias:
    .long VK_LEFT, 'h', VK_RIGHT, 'l', VK_UP, 'k', VK_DOWN, 'j', VK_HOME, '0', VK_END, '$'
    .long VK_DEL, 'x', VK_ENTER, '+'
    .long 0, 0
.p2align 3
vk_normal:
    .long 'd', 0
    .quad .Lc_op
    .long 'c', 0
    .quad .Lc_op
    .long 'y', 0
    .quad .Lc_op
    .long '>', 0
    .quad .Lc_op
    .long '<', 0
    .quad .Lc_op
    .long 'g', 0
    .quad .Lc_setprefix
    .long 'z', 0
    .quad .Lc_setprefix
    .long 'Z', 0
    .quad .Lc_setprefix
    .long 'f', 0
    .quad .Lc_setprefix
    .long 'F', 0
    .quad .Lc_setprefix
    .long 't', 0
    .quad .Lc_setprefix
    .long 'T', 0
    .quad .Lc_setprefix
    .long 'r', 0
    .quad .Lc_setprefix
    .long 'i', 0
    .quad .Lc_i
    .long 'a', 0
    .quad .Lc_a
    .long 'I', 0
    .quad .Lc_I
    .long 'A', 0
    .quad .Lc_A
    .long 'o', 0
    .quad .Lc_o
    .long 'O', 0
    .quad .Lc_O
    .long 'x', 0
    .quad .Lc_x
    .long 'X', 0
    .quad .Lc_X
    .long 'D', 0
    .quad .Lc_D
    .long 'C', 0
    .quad .Lc_C
    .long 's', 0
    .quad .Lc_s
    .long 'S', 0
    .quad .Lc_S
    .long 'Y', 0
    .quad .Lc_Y
    .long 'J', 0
    .quad .Lc_J
    .long '~', 0
    .quad .Lc_tilde
    .long 'p', 0
    .quad .Lc_put
    .long 'P', 0
    .quad .Lc_put
    .long 'u', 0
    .quad .Lc_undo
    .long VK_REDO, 0
    .quad .Lc_redo
    .long '.', 0
    .quad .Lc_dot
    .long 'v', 0
    .quad .Lc_v
    .long 'V', 0
    .quad .Lc_V
    .long '/', 0
    .quad .Lc_search
    .long '?', 0
    .quad .Lc_search
    .long ':', 0
    .quad .Lc_ex
    .long 0, 0
vk_visual:
    .long '/', 0
    .quad .Lc_search
    .long '?', 0
    .quad .Lc_search
    .long 'v', 0
    .quad .Lv_v
    .long 'V', 0
    .quad .Lv_V
    .long 'o', 0
    .quad .Lv_o
    .long 'd', 0
    .quad .Lv_op
    .long 'x', 0
    .quad .Lv_x
    .long 'y', 0
    .quad .Lv_op
    .long 'c', 0
    .quad .Lv_op
    .long 's', 0
    .quad .Lv_s
    .long '~', 0
    .quad .Lv_op
    .long 'u', 0
    .quad .Lv_op
    .long 'U', 0
    .quad .Lv_op
    .long '>', 0
    .quad .Lv_lines
    .long '<', 0
    .quad .Lv_lines
    .long 'X', 0
    .quad .Lv_Xd
    .long 'D', 0
    .quad .Lv_Xd
    .long 'Y', 0
    .quad .Lv_Y
    .long 'C', 0
    .quad .Lv_C
    .long 'S', 0
    .quad .Lv_C
    .long 'R', 0
    .quad .Lv_C
    .long 'J', 0
    .quad .Lv_J
    .long 'p', 0
    .quad .Lc_put
    .long 'P', 0
    .quad .Lc_put
    .long 'r', 0
    .quad .Lc_setprefix
    .long 'i', 0
    .quad .Lc_setprefix
    .long 'a', 0
    .quad .Lc_setprefix
    .long 'g', 0
    .quad .Lc_setprefix
    .long 'z', 0
    .quad .Lc_setprefix
    .long 'f', 0
    .quad .Lc_setprefix
    .long 'F', 0
    .quad .Lc_setprefix
    .long 't', 0
    .quad .Lc_setprefix
    .long 'T', 0
    .quad .Lc_setprefix
    .long ':', 0
    .quad .Lc_ex
    .long 0, 0
vk_motions:
    .long 'h', 0
    .quad .Lm_h
    .long 'l', 0
    .quad .Lm_l
    .long 'j', 0
    .quad .Lm_j
    .long 'k', 0
    .quad .Lm_k
    .long VK_BS, 0
    .quad .Lm_bs
    .long ' ', 0
    .quad .Lm_space
    .long '0', 0
    .quad .Lm_0
    .long '^', 0
    .quad .Lm_caret
    .long '$', 0
    .quad .Lm_dollar
    .long '_', 0
    .quad .Lm_under
    .long '+', 0
    .quad .Lm_plus
    .long '-', 0
    .quad .Lm_minus
    .long 'G', 0
    .quad .Lm_G
    .long VK_GG, 0
    .quad .Lm_gg
    .long 'w', 0
    .quad .Lm_w
    .long 'W', 0
    .quad .Lm_W
    .long 'e', 0
    .quad .Lm_e
    .long 'E', 0
    .quad .Lm_E
    .long 'b', 0
    .quad .Lm_b
    .long 'B', 0
    .quad .Lm_B
    .long 0x3b, 0               # ;
    .quad .Lm_semi
    .long 0x2c, 0               # ,
    .quad .Lm_comma
    .long '%', 0
    .quad .Lm_pct
    .long '{', 0
    .quad .Lm_pup
    .long '}', 0
    .quad .Lm_pdn
    .long 'H', 0
    .quad .Lm_H
    .long 'M', 0
    .quad .Lm_M
    .long 'L', 0
    .quad .Lm_L
    .long 'n', 0
    .quad .Lm_n
    .long 'N', 0
    .quad .Lm_N
    .long '*', 0
    .quad .Lm_star
    .long 0x23, 0               # #
    .quad .Lm_hash
    .long 0, 0
