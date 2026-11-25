# Mentions in a prompt (generic, no state): the text a mention of a path is written as, and the mention tokens
# of a text that are drawn as chips. The rules are the official extension's (webview/index.js 2.1.328: oTt,
# zEn, iTt @5208957; tTt, HEn, uW @5209000-5210900; JH, eEt @5183225-5185300), checked against the bundle's own
# functions by tests/mention_test.s (tools/mention-cases.js made its golden). A line range is written "#L2-3",
# one line "#L5": the only forms that make the agent's program read just those lines (finding 42; the
# extension's Alt+K writes "#2-3", which attaches the whole file).
#
#   agmention_text(sb, path ptr, len, l0, l1) -> eax 1, 0 refused   "@PATH" or "@\"PATH\"" with "#Ll0" or
#                                       "#Ll0-l1" (l0 0: no lines) appended to sb; refused: a path the agent
#                                       would read as another mention (empty, a '"', '#', white space and
#                                       "@", "@terminal:", "@browser", blanks at an end, "~", "~/...", " (agent)")
#   agmention_next(ptr, len, from, out) -> eax 1   the next chip token at or after from: out gets start 8,
#                                       end 8, kind 4 (1 a path, 2 a terminal), quoted 4; 0 none
#   agmention_target(ptr, len, sb) -> eax l0, edx l1   a token's target into sb (appended): a path without
#                                       its quotes and line suffix, its lines (0 none); "terminal:NAME" whole
.include "rhun.inc"

.text

# ws_at(ptr, len, i) -> eax the bytes of the white space character at i (JavaScript's \s), 0 none; wse_at:
#   the same with the four CJK marks the extension counts as a word's edge (。、？！). Touch rax, rcx, r8,
#   r9 only
ws_at:
    xor r9d, r9d
    jmp 1f
wse_at:
    mov r9d, 1
1:  movzx eax, byte ptr [rdi + rdx]
    cmp eax, ' '
    je .Lws1
    lea ecx, [rax - 9]
    cmp ecx, 4
    jbe .Lws1
    cmp eax, 0xc2
    je .Lws_c2
    cmp eax, 0xe1
    jb .Lws_no
    cmp eax, 0xef
    ja .Lws_no
    lea rcx, [rdx + 2]          # a three-byte character
    cmp rcx, rsi
    jae .Lws_no
    movzx ecx, byte ptr [rdi + rdx + 1]
    movzx r8d, byte ptr [rdi + rdx + 2]
    cmp eax, 0xe1
    je .Lws_e1
    cmp eax, 0xe2
    je .Lws_e2
    cmp eax, 0xe3
    je .Lws_e3
    cmp eax, 0xef
    je .Lws_ef
    jmp .Lws_no
.Lws_e1:                        # U+1680
    cmp ecx, 0x9a
    jne .Lws_no
    cmp r8d, 0x80
    je .Lws3
    jmp .Lws_no
.Lws_e2:                        # U+2000-200A, 2028, 2029, 202F, 205F
    cmp ecx, 0x81
    jne 2f
    cmp r8d, 0x9f
    je .Lws3
    jmp .Lws_no
2:  cmp ecx, 0x80
    jne .Lws_no
    cmp r8d, 0x8a
    jbe 3f
    cmp r8d, 0xa8
    je .Lws3
    cmp r8d, 0xa9
    je .Lws3
    cmp r8d, 0xaf
    je .Lws3
    jmp .Lws_no
3:  cmp r8d, 0x80
    jae .Lws3
    jmp .Lws_no
.Lws_e3:                        # U+3000; 。 U+3002 and 、 U+3001 for wse
    cmp ecx, 0x80
    jne .Lws_no
    cmp r8d, 0x80
    je .Lws3
    test r9d, r9d
    jz .Lws_no
    cmp r8d, 0x81
    je .Lws3
    cmp r8d, 0x82
    je .Lws3
    jmp .Lws_no
.Lws_ef:                        # U+FEFF; ！ U+FF01 and ？ U+FF1F for wse
    cmp ecx, 0xbb
    jne 4f
    cmp r8d, 0xbf
    je .Lws3
    jmp .Lws_no
4:  test r9d, r9d
    jz .Lws_no
    cmp ecx, 0xbc
    jne .Lws_no
    cmp r8d, 0x81
    je .Lws3
    cmp r8d, 0x9f
    je .Lws3
    jmp .Lws_no
.Lws_c2:                        # U+00A0
    lea rcx, [rdx + 1]
    cmp rcx, rsi
    jae .Lws_no
    cmp byte ptr [rdi + rdx + 1], 0xa0
    jne .Lws_no
    mov eax, 2
    ret
.Lws1:
    mov eax, 1
    ret
.Lws3:
    mov eax, 3
    ret
.Lws_no:
    xor eax, eax
    ret

# char_len(ptr, len, i) -> eax the bytes of the UTF-8 character at i (at most what is left). Touches rax, rcx
char_len:
    movzx eax, byte ptr [rdi + rdx]
    mov ecx, 1
    cmp eax, 0xc0
    jb 1f
    mov ecx, 2
    cmp eax, 0xe0
    jb 1f
    mov ecx, 3
    cmp eax, 0xf0
    jb 1f
    mov ecx, 4
1:  mov rax, rsi
    sub rax, rdx
    cmp rax, rcx
    jb 2f
    mov eax, ecx
2:  ret

# wse_before(ptr, len, i) -> eax 1 when the character before i is white space or a CJK mark (i > 0). Touches
#   rax, rcx, r8, r9, r10
wse_before:
    mov r10, rdx
    xor eax, eax
    test r10, r10
    jz 9f
    lea rdx, [r10 - 1]
    call wse_at
    cmp eax, 1
    je 8f
    cmp r10, 2
    jb 7f
    lea rdx, [r10 - 2]
    call wse_at
    cmp eax, 2
    je 8f
    cmp r10, 3
    jb 7f
    lea rdx, [r10 - 3]
    call wse_at
    cmp eax, 3
    je 8f
7:  xor eax, eax
    mov rdx, r10
    ret
8:  mov eax, 1
9:  mov rdx, r10
    ret

# mtoken(ptr, len, a) -> rax the end of the token whose "@" is at a (tTt's group: @"[^"]+" or @\S*[^\s.,;:!?)\]
#   。、？！]), 0 none; edx 1 when it is the quoted form
mtoken:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rcx, [r13 + 2]          # @"[^"]+"
    cmp rcx, r12
    jae .Lmt_plain
    cmp byte ptr [rbx + r13 + 1], '"'
    jne .Lmt_plain
    cmp byte ptr [rbx + rcx], '"'
    je .Lmt_plain
    inc rcx
1:  cmp rcx, r12
    jae .Lmt_plain
    cmp byte ptr [rbx + rcx], '"'
    je 2f
    inc rcx
    jmp 1b
2:  lea rax, [rcx + 1]
    mov edx, 1
    EPILOGUE
.Lmt_plain:
    lea r14, [r13 + 1]          # the run of what is not white space, its last allowed character's end
    xor r15d, r15d
3:  cmp r14, r12
    jae 7f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call ws_at
    test eax, eax
    jnz 7f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call char_len
    mov ecx, eax
    movzx eax, byte ptr [rbx + r14]
    cmp ecx, 1
    jne 5f
    lea rdx, [rip + .Lexcluded]
4:  cmp byte ptr [rdx], 0
    je 6f
    cmp al, [rdx]
    je 61f
    inc rdx
    jmp 4b
5:  push rcx
    push rcx
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call wse_at
    mov r8d, eax
    pop rcx
    pop rcx
    test r8d, r8d
    jnz 61f
6:  lea r15, [r14 + rcx]
61: add r14, rcx
    jmp 3b
7:  mov rax, r15
    xor edx, edx
    EPILOGUE

# hen(ptr, len) -> eax 1 when a token's text looks like a path (HEn): not a package scope's "types/…" and the
#   like, and holding "/", "." or "~"
hen:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rip + scopes]
1:  mov r14, [r13]
    test r14, r14
    jz 3f
    add r13, 8
    mov rdi, r14
    call strlen
    cmp rax, r12
    ja 1b
    mov rdi, rbx
    mov rsi, r14
    mov rdx, rax
    call memeq
    test eax, eax
    jz 1b
    xor eax, eax
    EPILOGUE
3:  xor ecx, ecx
    xor eax, eax
4:  cmp rcx, r12
    jae 9f
    movzx edx, byte ptr [rbx + rcx]
    inc rcx
    cmp edx, '/'
    je 5f
    cmp edx, '.'
    je 5f
    cmp edx, '~'
    jne 4b
5:  mov eax, 1
9:  EPILOGUE

# starts(ptr, len, cstr) -> eax 1 when the text starts with the string
starts:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov rdx, rax
    xor eax, eax
    cmp rdx, r12
    ja 9f
    mov rdi, rbx
    mov rsi, r13
    call memeq
9:  EPILOGUE

# ends(ptr, len, cstr) -> eax 1 when the text ends with the string
ends:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov rdx, rax
    xor eax, eax
    cmp rdx, r12
    ja 9f
    lea rdi, [rbx + r12]
    sub rdi, rdx
    mov rsi, r13
    call memeq
9:  EPILOGUE

# unquote(ptr, len) -> rax ptr, rdx len, ecx 1: without the quotes when it starts and ends with one (uW)
unquote:
    mov rax, rdi
    mov rdx, rsi
    xor ecx, ecx
    cmp rdx, 2
    jb 9f
    cmp byte ptr [rax], '"'
    jne 9f
    cmp byte ptr [rax + rdx - 1], '"'
    jne 9f
    inc rax
    sub rdx, 2
    mov ecx, 1
9:  ret

# FN agmention_next(ptr, len, from, out) -> eax 1 when a chip token was found: see the top
FN agmention_next
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], rcx
.Lnx_scan:
    cmp r13, r12
    jae .Lnx_none
    cmp byte ptr [rbx + r13], '@'
    je 1f
    inc r13
    jmp .Lnx_scan
1:  test r13, r13               # (?:^|[\s。、？！])@
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call wse_before
    test eax, eax
    jz .Lnx_next
2:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call mtoken
    test rax, rax
    jz .Lnx_next
    mov r14, rax                # its end
    lea rdi, [rbx + r13 + 1]    # uW(token without its "@")
    mov rsi, r14
    sub rsi, r13
    dec rsi
    call unquote
    mov [rsp + 8], ecx
    mov rdi, rax
    mov rsi, rdx
    mov r15, rax
    mov [rsp + 12], edx
    lea rdx, [rip + .Lterminal]
    call starts
    mov ecx, 2
    test eax, eax
    jnz 3f
    mov rdi, r15
    mov esi, [rsp + 12]
    lea rdx, [rip + .Lbrowser]  # @browser: phase 7's; never a chip here
    call starts
    test eax, eax
    jnz .Lnx_skip
    mov rdi, r15
    mov esi, [rsp + 12]
    call hen
    test eax, eax
    jz .Lnx_skip
    mov ecx, 1
3:  push rcx
    push rcx
    mov rdi, r15
    mov esi, [rsp + 12 + 16]
    lea rdx, [rip + .Lagent]
    call ends
    pop rcx
    pop rcx
    test eax, eax
    jnz .Lnx_skip
    mov rax, [rsp]
    mov [rax], r13
    mov [rax + 8], r14
    mov [rax + 16], ecx
    mov ecx, [rsp + 8]
    mov [rax + 20], ecx
    mov eax, 1
    EPILOGUE
.Lnx_skip:
    mov r13, r14
    jmp .Lnx_scan
.Lnx_next:
    inc r13
    jmp .Lnx_scan
.Lnx_none:
    xor eax, eax
    EPILOGUE

# digits(ptr, end) -> rax the number at ptr (32 bits at most), rdx the digits read (0 none)
digits:
    xor eax, eax
    xor edx, edx
1:  lea rcx, [rdi + rdx]
    cmp rcx, rsi
    jae 9f
    movzx ecx, byte ptr [rcx]
    sub ecx, '0'
    cmp ecx, 9
    ja 9f
    imul rax, rax, 10
    add rax, rcx
    cmp rax, 0x7fffffff
    jbe 2f
    mov eax, 0x7fffffff
2:  inc rdx
    jmp 1b
9:  ret

# eet(ptr, len) -> eax 1 when the text looks like a file's path (eEt): it starts with "/", "./", "../", ".\" or
#   "..\", ends with an extension of 1 to 10 letters or digits, ends with "/" or "\", or holds a separator and
#   its last part is one of the usual folders' names
eet:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor eax, eax
    test r12, r12
    jz 9f
    lea r13, [rip + eet_starts]
1:  mov rdx, [r13]
    test rdx, rdx
    jz 2f
    add r13, 8
    mov rdi, rbx
    mov rsi, r12
    call starts
    test eax, eax
    jz 1b
    jmp 8f
2:  movzx eax, byte ptr [rbx + r12 - 1]
    cmp eax, '/'
    je 8f
    cmp eax, '\\'
    je 8f
    mov rcx, r12                # \.[a-zA-Z0-9]{1,10}$
3:  test rcx, rcx
    jz 5f
    movzx eax, byte ptr [rbx + rcx - 1]
    cmp eax, '.'
    je 4f
    mov edx, eax
    sub edx, '0'
    cmp edx, 9
    jbe 31f
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    ja 5f
31: dec rcx
    jmp 3b
4:  mov rax, r12
    sub rax, rcx                # the letters after the dot
    jz 5f
    cmp rax, 10
    jbe 8f
5:  xor r13d, r13d              # a separator, and the last part
    xor r14d, r14d              # where the last part starts
    xor ecx, ecx
6:  cmp rcx, r12
    jae 7f
    movzx eax, byte ptr [rbx + rcx]
    inc rcx
    cmp eax, '/'
    je 61f
    cmp eax, '\\'
    jne 6b
61: mov r13d, 1
    mov r14, rcx
    jmp 6b
7:  test r13d, r13d
    jz 9f
    lea r15, [rip + eet_dirs]
71: mov rdx, [r15]
    test rdx, rdx
    jz 72f
    add r15, 8
    push rdx
    push rdx
    mov rdi, rdx
    call strlen
    mov rcx, rax
    pop rdx
    pop rdx
    lea rdi, [rbx + r14]
    mov rsi, r12
    sub rsi, r14
    call str_ieq
    test eax, eax
    jnz 8f
    jmp 71b
72: xor eax, eax
    EPILOGUE
8:  mov eax, 1
9:  EPILOGUE

# FN agmention_target(ptr, len, sb) -> eax l0, edx l1: see the top (JH: PATH, PATH:L, PATH#L, PATH#LL-LM,
#   PATH:L-M; a path that does not look like one keeps its suffix, as the extension opens it)
FN agmention_target
    PROLOGUE 16
    mov r14, rdx
    lea rdi, [rdi + 1]          # the token without its "@"
    dec rsi
    call unquote
    mov rbx, rax
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lterminal]
    call starts
    test eax, eax
    jnz .Ltg_whole
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lslashes]
    call starts
    test eax, eax
    jnz .Ltg_whole
    xor r13d, r13d              # the first ":" or "#"
1:  cmp r13, r12
    jae .Ltg_plain
    movzx eax, byte ptr [rbx + r13]
    cmp eax, ':'
    je 2f
    cmp eax, '#'
    je 2f
    inc r13
    jmp 1b
2:  test r13, r13
    jz .Ltg_whole
    lea r15, [rbx + r13 + 1]    # [:#]L?(\d+)(?:-L?(\d+))?$
    lea rax, [rbx + r12]
    mov [rsp], rax              # the end
    cmp r15, rax
    jae .Ltg_heading
    cmp byte ptr [r15], 'L'
    jne 3f
    inc r15
3:  mov rdi, r15
    mov rsi, [rsp]
    call digits
    test rdx, rdx
    jz .Ltg_heading
    add r15, rdx
    mov [rsp + 8], eax          # l0
    mov dword ptr [rsp + 12], 0
    cmp r15, [rsp]
    je .Ltg_lines
    cmp byte ptr [r15], '-'
    jne .Ltg_heading
    inc r15
    cmp r15, [rsp]
    jae .Ltg_heading
    cmp byte ptr [r15], 'L'
    jne 4f
    inc r15
4:  mov rdi, r15
    mov rsi, [rsp]
    call digits
    test rdx, rdx
    jz .Ltg_heading
    add r15, rdx
    cmp r15, [rsp]
    jne .Ltg_heading
    mov [rsp + 12], eax
.Ltg_lines:
    mov rdi, rbx
    mov rsi, r13
    call eet
    test eax, eax
    jz .Ltg_whole
    mov rdi, r14
    mov rsi, rbx
    mov rdx, r13
    call sb_push
    mov eax, [rsp + 8]
    mov edx, [rsp + 12]
    EPILOGUE
.Ltg_heading:                   # ^([^:#]+?)#([^#]+)$: the path before the heading
    cmp byte ptr [rbx + r13], '#'
    jne .Ltg_whole
    lea rcx, [r13 + 1]
    cmp rcx, r12
    jae .Ltg_whole
5:  cmp rcx, r12
    jae 6f
    cmp byte ptr [rbx + rcx], '#'
    je .Ltg_whole
    inc rcx
    jmp 5b
6:  mov rdi, rbx
    mov rsi, r13
    call eet
    test eax, eax
    jz .Ltg_whole
    mov rdi, r14
    mov rsi, rbx
    mov rdx, r13
    call sb_push
    xor eax, eax
    xor edx, edx
    EPILOGUE
.Ltg_plain:
.Ltg_whole:
    mov rdi, r14
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    xor eax, eax
    xor edx, edx
    EPILOGUE

# has_ws(ptr, len) -> eax 1 when the text holds white space anywhere
has_ws:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13, r12
    jae 8f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call ws_at
    test eax, eax
    jnz 9f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call char_len
    add r13, rax
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# ends_ws(ptr, len) -> eax 1 when the text's last character is white space
ends_ws:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, 1
1:  cmp r13, 3
    ja 8f
    cmp r13, r12
    ja 8f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r12
    sub rdx, r13
    call ws_at
    cmp rax, r13
    je 9f
    inc r13
    jmp 1b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# refused(ptr, len) -> eax 1 when a path cannot be mentioned (oTt's and iTt's refusals)
refused:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 8f
    xor r13d, r13d              # '"', '#', white space (or a CJK mark) before an "@"
1:  cmp r13, r12
    jae 3f
    movzx eax, byte ptr [rbx + r13]
    cmp eax, '"'
    je 8f
    cmp eax, '#'
    je 8f
    cmp eax, '@'
    jne 2f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call wse_before
    test eax, eax
    jnz 8f
    lea rdi, [rbx + r13]        # "@terminal:"; "@browser" before ":", white space or the end
    mov rsi, r12
    sub rsi, r13
    lea rdx, [rip + .Lat_terminal]
    call starts
    test eax, eax
    jnz 8f
    lea rdi, [rbx + r13]
    mov rsi, r12
    sub rsi, r13
    lea rdx, [rip + .Lat_browser]
    call starts
    test eax, eax
    jz 2f
    lea rdx, [r13 + 8]
    cmp rdx, r12
    jae 8f
    cmp byte ptr [rbx + rdx], ':'
    je 8f
    mov rdi, rbx
    mov rsi, r12
    call ws_at
    test eax, eax
    jnz 8f
2:  inc r13
    jmp 1b
3:  mov rdi, rbx                # white space at either end
    mov rsi, r12
    xor edx, edx
    call ws_at
    test eax, eax
    jnz 8f
    mov rdi, rbx
    mov rsi, r12
    call ends_ws
    test eax, eax
    jnz 8f
    cmp r12, 1                  # "~", "~/..."
    jne 4f
    cmp byte ptr [rbx], '~'
    je 8f
4:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Ltilde]
    call starts
    test eax, eax
    jnz 8f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lagent]
    call ends
    test eax, eax
    jnz 8f
    xor eax, eax
    EPILOGUE
8:  mov eax, 1
    EPILOGUE

# bare(ptr, len, suffixed) -> eax 1 when the path is written without quotes (zEn)
bare:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    call has_ws
    test eax, eax
    jnz 8f
    xor ecx, ecx
1:  cmp rcx, r12
    jae 2f
    cmp byte ptr [rbx + rcx], ':'
    je 8f
    inc rcx
    jmp 1b
2:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lagent_dash]
    call starts
    test eax, eax
    jnz 8f
    lea rdi, [rip + .Lbrowser_word]
    call strlen
    cmp rax, r12
    jne 3f
    mov rdi, rbx
    lea rsi, [rip + .Lbrowser_word]
    mov rdx, r12
    call memeq
    test eax, eax
    jnz 8f
3:  test r13d, r13d             # a suffix ends in a digit: nothing more to look at
    jnz 9f
    mov rcx, r12                # its trailing slashes off: it must end in a letter, a digit or "_"
4:  test rcx, rcx
    jz 8f
    cmp byte ptr [rbx + rcx - 1], '/'
    jne 5f
    dec rcx
    jmp 4b
5:  movzx eax, byte ptr [rbx + rcx - 1]
    cmp eax, '_'
    je 6f
    mov edx, eax
    sub edx, '0'
    cmp edx, 9
    jbe 6f
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    ja 8f
6:  cmp rcx, r12
    je 9f
    movzx eax, byte ptr [rbx]   # slashes were taken off: not when it starts with one
    cmp eax, '/'
    je 8f
    cmp eax, '\\'
    je 8f
9:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agmention_text(sb, path ptr, len, l0, l1) -> eax 1 written, 0 refused: see the top
FN agmention_text
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    mov r15d, r8d
    mov rdi, r12
    mov rsi, r13
    call refused
    test eax, eax
    jnz 8f
    lea rdi, [rsp]              # the suffix: "#L5" or "#L2-3"
    xor ecx, ecx
    test r14d, r14d
    jz 3f
    mov byte ptr [rdi], '#'
    mov byte ptr [rdi + 1], 'L'
    lea rdi, [rsp + 2]
    mov esi, r14d
    call put_u32
    cmp r15d, 0
    je 2f
    cmp r15d, r14d
    je 2f
    mov byte ptr [rdi], '-'
    inc rdi
    mov esi, r15d
    call put_u32
2:  mov rcx, rdi
    sub rcx, rsp
3:  mov [rsp + 40], rcx
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    test rcx, rcx
    setnz dl
    call bare
    mov [rsp + 32], eax
    mov rdi, rbx
    mov esi, '@'
    call sb_push_byte
    cmp dword ptr [rsp + 32], 0
    jne 4f
    mov rdi, rbx
    mov esi, '"'
    call sb_push_byte
4:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, rbx
    lea rsi, [rsp]
    mov rdx, [rsp + 40]
    call sb_push
    cmp dword ptr [rsp + 32], 0
    jne 5f
    mov rdi, rbx
    mov esi, '"'
    call sb_push_byte
5:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# put_u32(dst, n) -> rdi after the decimal digits of n written at dst
put_u32:
    mov eax, esi
    xor ecx, ecx
    mov r8d, 10
1:  xor edx, edx
    div r8d
    add edx, '0'
    push rdx
    inc ecx
    test eax, eax
    jnz 1b
2:  pop rax
    mov [rdi], al
    inc rdi
    dec ecx
    jnz 2b
    ret

.section .rodata
.Lexcluded: .asciz ".,;:!?)]"
.Lterminal: .asciz "terminal:"
.Lbrowser: .asciz "browser:"
.Lbrowser_word: .asciz "browser"
.Lagent: .asciz " (agent)"
.Lagent_dash: .asciz "agent-"
.Lat_terminal: .asciz "@terminal:"
.Lat_browser: .asciz "@browser"
.Ltilde: .asciz "~/"
.Lslashes: .asciz "//"
.Ls1: .asciz "types/"
.Ls2: .asciz "babel/"
.Ls3: .asciz "eslint/"
.Ls4: .asciz "typescript-eslint/"
.Ls5: .asciz "angular/"
.Ls6: .asciz "vue/"
.Ls7: .asciz "nestjs/"
.Ls8: .asciz "testing-library/"
.Ls9: .asciz "tanstack/"
.Ls10: .asciz "radix-ui/"
.Ls11: .asciz "reduxjs/"
.Ls12: .asciz "emotion/"
.Ls13: .asciz "mui/"
.Ls14: .asciz "swc/"
.Le1: .asciz "/"
.Le2: .asciz "./"
.Le3: .asciz "../"
.Le4: .asciz ".\\"
.Le5: .asciz "..\\"
.Ld1: .asciz "src"
.Ld2: .asciz "lib"
.Ld3: .asciz "test"
.Ld4: .asciz "tests"
.Ld5: .asciz "dist"
.Ld6: .asciz "build"
.Ld7: .asciz "node_modules"
.Ld8: .asciz "components"
.Ld9: .asciz "utils"
.Ld10: .asciz "services"
.Ld11: .asciz "api"
.Ld12: .asciz "assets"
.Ld13: .asciz "public"
.Ld14: .asciz "private"
.Ld15: .asciz "config"
.Ld16: .asciz "scripts"
.Ld17: .asciz "docs"
.p2align 3
scopes: .quad .Ls1, .Ls2, .Ls3, .Ls4, .Ls5, .Ls6, .Ls7, .Ls8, .Ls9, .Ls10, .Ls11, .Ls12, .Ls13, .Ls14, 0
eet_starts: .quad .Le1, .Le2, .Le3, .Le4, .Le5, 0
eet_dirs: .quad .Ld1, .Ld2, .Ld3, .Ld4, .Ld5, .Ld6, .Ld7, .Ld8, .Ld9, .Ld10, .Ld11, .Ld12, .Ld13, .Ld14, .Ld15
    .quad .Ld16, .Ld17, 0
