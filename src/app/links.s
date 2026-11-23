# Opening URLs and link callbacks (feature urls, docs/extensions/v1.1.md). open-url shows the
# user what an extension wants to open and opens it in the default browser (or copies it); an
# extension may be allowed to open links without asking (open_urls = yes in extensions.ini). link
# hands out a one-shot rhun://ext/OWNER/NAME/TOKEN link; when the browser (or anything) opens
# it, rhun gives it to that extension as "0 link ID LEN".
#
# Linux, and macOS between instances, start a new rhun for a link: while a token is pending the
# rhun that made it listens on DIR/link-PID (DIR: $XDG_RUNTIME_DIR/rhun, else /tmp/rhun-UID, mode
# 0700 and the user's own), and a rhun started for a rhun://ext/ link offers it there first
# ("link URL" -> "yes"/"no") and exits when one took it. Windows keeps links within the rhun that
# made them.
.include "rhun.inc"

.equ LK_MAX, 64                 # pending links, all extensions
.equ LK_PER_EXT, 4
.equ LK_LIFE_MS, 600000         # ten minutes
.equ LK_URL_MAX, 8192
STRUCT
F LK_ext, 8             # the extension, 0 for a free slot
F LK_id, 8              # the link request's id (0 link ID)
F LK_until, 8           # time_ms it expires
F LK_token, 40          # 32 lowercase hex digits and a NUL
ENDSTRUCT LK_SIZE

.bss
.p2align 3
lk_slots: .zero LK_SIZE * LK_MAX
lk_link: .zero SB_SIZE          # the last link made (links_new's answer)
lk_dir: .zero 160               # the relay folder, or empty
lk_path: .zero 200              # this rhun's relay socket, or empty
lk_addr: .zero 112
lk_line: .zero LK_URL_MAX + 16
lk_rand: .zero 16
lk_stat: .zero 160
.data
lk_sock: .long -1

.text

# ---------------- opening URLs ----------------

# FN links_url_ok(ptr, len) -> eax 1 for an http or https URL of at most 8192 bytes without spaces
# or control characters
FN links_url_ok
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 8f
    cmp r12, LK_URL_MAX
    ja 8f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lhttps]
    mov ecx, 8
    call str_starts
    test eax, eax
    jnz 1f
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lhttp]
    mov ecx, 7
    call str_starts
    test eax, eax
    jz 8f
1:  xor ecx, ecx
2:  cmp rcx, r12
    jae 9f
    movzx eax, byte ptr [rbx + rcx]
    inc rcx
    cmp eax, 0x20
    jbe 8f
    cmp eax, 0x7f
    je 8f
    jmp 2b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# FN links_host(url cstr, buf, cap): the URL's host (after "://", up to "/", "?", "#" or ":")
FN links_host
    mov rax, rdi
1:  cmp byte ptr [rax], 0
    je 3f
    cmp byte ptr [rax], ':'
    jne 2f
    cmp byte ptr [rax + 1], '/'
    jne 2f
    cmp byte ptr [rax + 2], '/'
    jne 2f
    add rax, 3
    jmp 4f
2:  inc rax
    jmp 1b
3:  mov rax, rdi
4:  dec rdx
    xor ecx, ecx
5:  cmp rcx, rdx
    jae 6f
    movzx r8d, byte ptr [rax + rcx]
    test r8d, r8d
    jz 6f
    cmp r8d, '/'
    je 6f
    cmp r8d, '?'
    je 6f
    cmp r8d, '#'
    je 6f
    cmp r8d, ':'
    je 6f
    mov [rsi + rcx], r8b
    inc rcx
    jmp 5b
6:  mov byte ptr [rsi + rcx], 0
    ret

# FN links_open(url cstr): the default browser opens it; in a --extensions or a --headless session
# RHUN_OPEN_URL names a program run with the URL instead (tests)
FN links_open
    PROLOGUE 48
    mov rbx, rdi
    cmp qword ptr [rip + g_ext_dir], 0
    jne 0f
    cmp dword ptr [rip + g_headless], 0
    je 8f
0:  lea rdi, [rip + .Lenv_open]
    call getenv
    test rax, rax
    jz 8f
    cmp byte ptr [rax], 0
    je 8f
    mov [rsp], rax
    mov [rsp + 8], rbx
    mov qword ptr [rsp + 16], 0
    mov rdi, rsp
    mov rsi, [rip + g_envp]
    xor edx, edx
    call run_piped
    test rax, rax
    jle 9f
    mov edi, edx
    mov esi, POLLIN
    lea rdx, [rip + lk_opener_done]
    mov rcx, rax
    call watch_add
    EPILOGUE
8:  mov rdi, rbx
    call desktop_open
9:  EPILOGUE

# FN links_ask_label(sb, who cstr, url cstr): "WHO wants to open HOST in your browser: URL" into sb (cleared
#   first): what the user is asked before a URL opens (an extension's open-url, a reply's link)
FN links_ask_label
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lask_wants]
    call sb_push_cstr
    mov rdi, r13
    lea rsi, [rip + lk_ask_host]
    mov edx, 200
    call links_host
    mov rdi, rbx
    lea rsi, [rip + lk_ask_host]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lask_browser]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    EPILOGUE

# FN links_ask_open(who cstr, url cstr): an http or https URL that came from WHO (a conversation's agent)
#   opens only once the user says so: the chooser "WHO wants to open HOST in your browser: URL" with Open,
#   Copy Link and Cancel (links_chose answers it; an extension's open-url has its own, with Always). Any
#   other URL: nothing
FN links_ask_open
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call strlen
    mov r13, rax
    mov rdi, r12
    mov rsi, r13
    call links_url_ok
    test eax, eax
    jz 9f
    mov rdi, [rip + lk_ask_url]
    call mem_free
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rip + lk_ask_url], rax
    lea rdi, [rip + lk_ask_sb]
    mov rsi, rbx
    mov rdx, r12
    call links_ask_label
    mov rsi, [rip + lk_ask_sb + SB_ptr]  # its first line, 200 bytes at most, as the palette's label
    mov rdx, [rip + lk_ask_sb + SB_len]
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 2f
    cmp byte ptr [rsi + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov rdi, rcx
    mov edx, 200
    call utf8_cut
    mov rsi, [rip + lk_ask_sb + SB_ptr]
    lea rdi, [rip + lk_ask_label]
    xor ecx, ecx
3:  cmp rcx, rax
    jae 4f
    mov dl, [rsi + rcx]
    mov [rdi + rcx], dl
    inc rcx
    jmp 3b
4:  mov byte ptr [rdi + rcx], 0
    call palette_links_open
    lea rdi, [rip + .Lask_open]
    mov esi, 4
    mov edx, 1
    call palette_choose_add
    lea rdi, [rip + .Lask_copy]
    mov esi, 9
    mov edx, 2
    call palette_choose_add
    lea rdi, [rip + .Lask_cancel]
    mov esi, 6
    mov edx, 3
    call palette_choose_add
    call palette_choose_ready
9:  EPILOGUE

# FN links_chose(n): the answer to links_ask_open's chooser: 1 Open (links_open), 2 Copy Link, else nothing
FN links_chose
    PROLOGUE
    mov rbx, [rip + lk_ask_url]
    test rbx, rbx
    jz 9f
    mov qword ptr [rip + lk_ask_url], 0
    cmp rdi, 1
    jne 1f
    mov rdi, rbx
    call links_open
    jmp 8f
1:  cmp rdi, 2
    jne 8f
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    xor edx, edx
    call ed_clip_set
8:  mov rdi, rbx
    call mem_free
9:  EPILOGUE

# lk_opener_done(fd, revents, pid): the test opener's output drained, the program reaped
lk_opener_done:
    PROLOGUE 256
    mov ebx, edi
    mov r12, rdx
1:  mov edi, ebx
    mov rsi, rsp
    mov edx, 256
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jg 1b
    mov edi, ebx
    call watch_remove
    mov edi, ebx
    SYS SYS_close
    mov rdi, r12
    xor esi, esi
    call proc_wait
9:  EPILOGUE

# ---------------- links ----------------

# FN links_new(ext, id) -> rax the link (rhun://ext/OWNER/NAME/TOKEN, a cstr of this module, valid
# until the next call), or -27 when the extension has LK_PER_EXT pending already, -5 without
# randomness
FN links_new
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call links_expire
    xor ecx, ecx
    xor r13d, r13d              # a free slot
    lea rax, [rip + lk_slots]
    mov edx, LK_MAX
1:  cmp qword ptr [rax + LK_ext], 0
    jne 2f
    test r13, r13
    jnz 3f
    mov r13, rax
    jmp 3f
2:  cmp [rax + LK_ext], rbx
    jne 3f
    inc ecx
3:  add rax, LK_SIZE
    dec edx
    jnz 1b
    cmp ecx, LK_PER_EXT
    jae 7f
    test r13, r13
    jz 7f
    lea rdi, [rip + lk_rand]
    mov esi, 16
    call wasi_os_random
    test rax, rax
    js 6f
    xor ecx, ecx
    lea r9, [rip + lk_rand]
4:  movzx eax, byte ptr [r9 + rcx]
    mov edx, eax
    shr eax, 4
    and edx, 15
    lea r8, [rip + .Lhex]
    movzx eax, byte ptr [r8 + rax]
    movzx edx, byte ptr [r8 + rdx]
    mov [r13 + LK_token + rcx*2], al
    mov [r13 + LK_token + rcx*2 + 1], dl
    inc ecx
    cmp ecx, 16
    jb 4b
    mov byte ptr [r13 + LK_token + 32], 0
    mov [r13 + LK_ext], rbx
    mov [r13 + LK_id], r12
    call time_ms
    add rax, LK_LIFE_MS
    mov [r13 + LK_until], rax
    lea rdi, [rip + lk_link]
    call sb_clear
    lea rdi, [rip + lk_link]
    lea rsi, [rip + .Lprefix]
    call sb_push_cstr
    mov rdi, rbx
    call ext_full_name
    lea rdi, [rip + lk_link]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + lk_link]
    mov esi, '/'
    call sb_push_byte
    lea rdi, [rip + lk_link]
    lea rsi, [r13 + LK_token]
    call sb_push_cstr
    lea rdi, [rip + lk_link]
    xor esi, esi
    call sb_push_byte
    call lk_listen
    mov rax, [rip + lk_link + SB_ptr]
    EPILOGUE
6:  mov rax, -5
    EPILOGUE
7:  mov rax, -27
    EPILOGUE

# FN links_pending(ext) -> eax 1 while a link of the extension is pending (it is not idle)
FN links_pending
    lea rax, [rip + lk_slots]
    mov ecx, LK_MAX
1:  cmp [rax + LK_ext], rdi
    je 8f
    add rax, LK_SIZE
    dec ecx
    jnz 1b
    xor eax, eax
    ret
8:  test rdi, rdi
    jz 9f
    mov eax, 1
    ret
9:  xor eax, eax
    ret

# FN links_ext_exited(ext): its program is gone: its links will not be taken
FN links_ext_exited
    PROLOGUE
    lea rax, [rip + lk_slots]
    mov ecx, LK_MAX
1:  cmp [rax + LK_ext], rdi
    jne 2f
    mov qword ptr [rax + LK_ext], 0
2:  add rax, LK_SIZE
    dec ecx
    jnz 1b
    call lk_close_idle
    EPILOGUE

# FN links_expire(): links past their ten minutes go
FN links_expire
    PROLOGUE
    call time_ms
    mov r12, rax
    lea rbx, [rip + lk_slots]
    mov ecx, LK_MAX
1:  cmp qword ptr [rbx + LK_ext], 0
    je 2f
    cmp r12, [rbx + LK_until]
    jb 2f
    mov qword ptr [rbx + LK_ext], 0
2:  add rbx, LK_SIZE
    dec ecx
    jnz 1b
    call lk_close_idle
    EPILOGUE

# FN links_is_link(cstr) -> eax 1 for a rhun://ext/ link (the scheme and "ext" in any case)
FN links_is_link
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Lprefix]
    mov ecx, 11
    call str_istarts
    EPILOGUE

# str_istarts(s, slen, prefix, plen) -> eax 1 when s starts with prefix, ASCII case ignored
str_istarts:
    xor eax, eax
    cmp rsi, rcx
    jb 9f
    xor r8d, r8d
1:  cmp r8, rcx
    jae 8f
    movzx eax, byte ptr [rdi + r8]
    movzx r9d, byte ptr [rdx + r8]
    or eax, 0x20
    or r9d, 0x20
    cmp eax, r9d
    jne 7f
    inc r8
    jmp 1b
7:  xor eax, eax
    ret
8:  mov eax, 1
9:  ret

# FN links_deliver(ptr, len) -> eax 1 when the link was pending: "0 link ID LEN" and the link go
# to its extension and the token is spent
FN links_deliver
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lprefix]
    mov ecx, 11
    call str_istarts
    test eax, eax
    jz 8f
    call links_expire
    # OWNER/NAME/TOKEN after the prefix
    lea r13, [rbx + 11]
    lea r14, [rbx + r12]
    lea rax, [rip + lk_slots]
    mov [rsp], rax
    mov dword ptr [rsp + 8], LK_MAX
1:  mov r15, [rsp]
    mov rdi, [r15 + LK_ext]
    test rdi, rdi
    jz 3f
    # OWNER/NAME/ must follow, then the 32 digits, then the end, "/", "?" or "#"
    call ext_full_name
    mov rdi, rax
    call strlen
    lea rcx, [r13 + rax + 1 + 32]
    cmp rcx, r14
    ja 3f
    mov [rsp + 12], eax
    mov rdi, [r15 + LK_ext]
    call ext_full_name
    mov rdx, rax
    mov ecx, [rsp + 12]
    mov rdi, r13
    mov rsi, rcx
    call str_eq
    test eax, eax
    jz 3f
    mov ecx, [rsp + 12]
    lea rdi, [r13 + rcx]
    cmp byte ptr [rdi], '/'
    jne 3f
    inc rdi
    lea rsi, [r15 + LK_token]
    mov edx, 32
    call memeq
    test eax, eax
    jz 3f
    mov ecx, [rsp + 12]
    lea rax, [r13 + rcx + 33]
    cmp rax, r14
    je 2f
    movzx eax, byte ptr [rax]
    cmp eax, '/'
    je 2f
    cmp eax, '?'
    je 2f
    cmp eax, '#'
    jne 3f
2:  # pending: its extension hears it, if it still runs
    mov rdi, [r15 + LK_ext]
    mov rsi, [r15 + LK_id]
    mov qword ptr [r15 + LK_ext], 0
    cmp dword ptr [rdi + EXT_status], ES_RUNNING
    jne 8f
    mov rdx, rbx
    mov rcx, r12
    call extproto_send_link
    call lk_close_idle
    mov eax, 1
    EPILOGUE
3:  add qword ptr [rsp], LK_SIZE
    dec dword ptr [rsp + 8]
    jnz 1b
8:  call lk_close_idle
    xor eax, eax
    EPILOGUE

# FN links_open_path(path cstr) -> eax 1 when it was a rhun://ext/ link and is handled: given to
# its extension, else offered to the other rhun instances (macOS), else the user is told it is not
# expected
FN links_open_path
    PROLOGUE
    mov rbx, rdi
    call links_is_link
    test eax, eax
    jz 8f
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call links_deliver
    test eax, eax
    jnz 9f
    mov rdi, rbx
    call links_relay
    test eax, eax
    jnz 9f
    lea rdi, [rip + .Lt_unexpected]
    call app_toast
    jmp 9f
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# ---------------- the relay between rhun instances ----------------

# lk_dir_ready() -> eax 1 with lk_dir the relay folder: made with mode 0700, owned by the user,
# 0700; 0 when there is none to trust
lk_dir_ready:
.ifdef WINDOWS
    xor eax, eax
    ret
.else
    PROLOGUE
    lea rdi, [rip + lk_dir]
    mov byte ptr [rdi], 0
    cmp qword ptr [rip + g_ext_dir], 0
    je 1f
    lea rdi, [rip + .Lenv_dir]   # tests: RHUN_LINK_DIR
    call getenv
    test rax, rax
    jz 1f
    mov rsi, rax
    jmp 3f
1:
.ifndef MACOS
    lea rdi, [rip + .Lenv_runtime]
    call getenv
    test rax, rax
    jz 2f
    cmp byte ptr [rax], 0
    je 2f
    mov rbx, rax
    mov rdi, rax
    call strlen
    cmp rax, 100
    jae 2f
    lea rdi, [rip + lk_dir]
    mov rsi, rbx
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Lslash_rhun]
    call cstr_copy
    jmp 4f
.endif
2:  # /tmp/rhun-UID
    lea rdi, [rip + lk_dir]
    lea rsi, [rip + .Ltmp_rhun]
    call cstr_copy
    mov rbx, rax
    SYS SYS_getuid
    mov rdi, rbx
    mov esi, eax
    call fmt_u64
    mov byte ptr [rbx + rax], 0
    jmp 4f
3:  mov rdi, rsi
    call strlen
    cmp rax, 100
    jae 8f
    lea rdi, [rip + lk_dir]
    call cstr_copy
4:  lea rdi, [rip + lk_dir]
    mov esi, 0700
    SYS SYS_mkdir
    # the user's own, and nobody else's to read or write
    lea rdi, [rip + lk_dir]
    lea rsi, [rip + lk_stat]
    SYS SYS_lstat
    test rax, rax
    js 8f
    mov ebx, [rip + lk_stat + 28]     # st_uid
    SYS SYS_getuid
    cmp eax, ebx
    jne 8f
    mov eax, [rip + lk_stat + 24]     # st_mode
    and eax, 0170777
    cmp eax, 0040700                  # a folder, rwx------
    jne 8f
    mov eax, 1
    EPILOGUE
8:  mov byte ptr [rip + lk_dir], 0
    xor eax, eax
    EPILOGUE
.endif

# lk_sun(path cstr) -> lk_addr: a sockaddr_un for it (paths over 103 bytes are refused: eax 0)
lk_sun:
    push rbx
    mov rbx, rdi
    call strlen
    cmp rax, 103
    ja 8f
    lea rdi, [rip + lk_addr]
    mov word ptr [rdi], AF_UNIX
    add rdi, 2
    mov rsi, rbx
    call cstr_copy
    mov eax, 1
    pop rbx
    ret
8:  xor eax, eax
    pop rbx
    ret

# lk_listen(): this rhun listens for links while one is pending
lk_listen:
.ifdef WINDOWS
    ret
.else
    PROLOGUE
    cmp dword ptr [rip + lk_sock], 0
    jge 9f
    call lk_dir_ready
    test eax, eax
    jz 9f
    lea rdi, [rip + lk_path]
    lea rsi, [rip + lk_dir]
    call cstr_copy
    mov rdi, rax
    lea rsi, [rip + .Lslash_link]
    call cstr_copy
    mov rbx, rax
    SYS SYS_getpid
    mov rdi, rbx
    mov esi, eax
    call fmt_u64
    mov byte ptr [rbx + rax], 0
    lea rdi, [rip + lk_path]
    call lk_sun
    test eax, eax
    jz 8f
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js 8f
    mov ebx, eax
    lea rdi, [rip + lk_path]
    SYS SYS_unlink
    mov edi, ebx
    lea rsi, [rip + lk_addr]
    mov edx, 110
    SYS SYS_bind
    test rax, rax
    js 7f
    mov edi, ebx
    mov esi, 4
    SYS SYS_listen
    test rax, rax
    js 7f
    mov [rip + lk_sock], ebx
    mov edi, ebx
    mov esi, POLLIN
    lea rdx, [rip + lk_accept]
    xor ecx, ecx
    call watch_add
    EPILOGUE
7:  mov edi, ebx
    SYS SYS_close
8:  mov byte ptr [rip + lk_path], 0
9:  EPILOGUE
.endif

# lk_close_idle(): no link pending: the socket goes
lk_close_idle:
    PROLOGUE
    cmp dword ptr [rip + lk_sock], 0
    jl 9f
    lea rax, [rip + lk_slots]
    mov ecx, LK_MAX
1:  cmp qword ptr [rax + LK_ext], 0
    jne 9f
    add rax, LK_SIZE
    dec ecx
    jnz 1b
    mov ebx, [rip + lk_sock]
    mov dword ptr [rip + lk_sock], -1
    mov edi, ebx
    call watch_remove
    mov edi, ebx
    SYS SYS_close
    lea rdi, [rip + lk_path]
    SYS SYS_unlink
    mov byte ptr [rip + lk_path], 0
9:  EPILOGUE

# lk_read_line(fd, deadline) -> rax the line's length in lk_line (without LF), or -1
lk_read_line:
    PROLOGUE 16
    mov ebx, edi
    mov r12, rsi
    xor r13d, r13d
1:  call time_ms
    mov rdx, r12
    sub rdx, rax
    jle 8f
    mov [rsp], ebx
    mov dword ptr [rsp + 4], POLLIN
    lea rdi, [rsp]
    mov esi, 1
    SYS SYS_poll
    cmp rax, -EINTR
    je 1b
    cmp rax, 1
    jne 8f
    mov edi, ebx
    lea rsi, [rip + lk_line]
    add rsi, r13
    mov edx, LK_URL_MAX + 8
    sub rdx, r13
    jle 8f
    SYS SYS_read
    cmp rax, -EAGAIN
    je 1b
    test rax, rax
    jle 8f
    add r13, rax
    xor ecx, ecx
2:  cmp rcx, r13
    jae 1b
    lea rax, [rip + lk_line]
    cmp byte ptr [rax + rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  mov rax, rcx
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# lk_accept(fd, revents, ctx): another rhun offers a link: "link URL" -> "yes" or "no"
lk_accept:
.ifndef WINDOWS
    PROLOGUE
    mov edi, [rip + lk_sock]
    test edi, edi
    js 9f
    xor esi, esi
    xor edx, edx
    mov r10d, SOCK_CLOEXEC
    SYS SYS_accept4
    test rax, rax
    js 9f
    mov ebx, eax
    call time_ms
    lea rsi, [rax + 300]
    mov edi, ebx
    call lk_read_line
    lea r12, [rip + .Lno]
    test rax, rax
    js 7f
    cmp rax, 5
    jbe 7f
    cmp dword ptr [rip + lk_line], 0x6b6e696c       # "link"
    jne 7f
    cmp byte ptr [rip + lk_line + 4], ' '
    jne 7f
    lea rdi, [rip + lk_line + 5]
    lea rsi, [rax - 5]
    call links_deliver
    test eax, eax
    jz 7f
    lea r12, [rip + .Lyes]
7:  mov rdi, r12
    call strlen
    mov rdx, rax
    mov edi, ebx
    mov rsi, r12
    call write_all
    mov edi, ebx
    SYS SYS_close
9:  EPILOGUE
.else
    ret
.endif

# FN links_relay(url cstr) -> eax 1 when another rhun took the link (500 ms at most in all)
FN links_relay
.ifdef WINDOWS
    xor eax, eax
    ret
.else
    PROLOGUE 16
    mov rbx, rdi
    call strlen
    cmp rax, LK_URL_MAX
    ja 8f
    mov [rip + lk_relay_url], rbx
    mov qword ptr [rip + lk_relay_took], 0
    call time_ms
    add rax, 500
    mov [rip + lk_relay_until], rax
    call lk_dir_ready
    test eax, eax
    jz 8f
    lea rdi, [rip + lk_dir]
    lea rsi, [rip + lk_relay_one]
    xor edx, edx
    call dir_each
    mov rax, [rip + lk_relay_took]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# lk_relay_one(ctx, name, is_dir): a link-PID socket other than ours: offered the link
lk_relay_one:
    PROLOGUE
    mov rbx, rsi
    cmp qword ptr [rip + lk_relay_took], 0
    jne 9f
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    lea rdx, [rip + .Llink_dash]
    mov ecx, 5
    call str_starts
    test eax, eax
    jz 9f
    call time_ms
    cmp rax, [rip + lk_relay_until]
    jae 9f
    # its path
    lea rdi, [rip + lk_line]
    lea rsi, [rip + lk_dir]
    call cstr_copy
    mov byte ptr [rax], '/'
    lea rdi, [rax + 1]
    mov rsi, rbx
    call cstr_copy
    lea rdi, [rip + lk_line]
    lea rsi, [rip + lk_path]
    call strcmp_eq
    test eax, eax
    jnz 9f                      # our own
    lea rdi, [rip + lk_line]
    call lk_sun
    test eax, eax
    jz 9f
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM | SOCK_CLOEXEC
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js 9f
    mov r12d, eax
    mov edi, r12d
    lea rsi, [rip + lk_addr]
    mov edx, 110
    SYS SYS_connect
    test rax, rax
    jns 1f
    cmp rax, -111               # ECONNREFUSED: nobody listens there any more
    jne 7f
    lea rdi, [rip + lk_addr + 2]
    SYS SYS_unlink
    jmp 7f
1:  mov edi, r12d
    lea rsi, [rip + .Llink_sp]
    mov edx, 5
    call write_all
    mov rdi, [rip + lk_relay_url]
    call strlen
    mov rdx, rax
    mov edi, r12d
    mov rsi, [rip + lk_relay_url]
    call write_all
    mov edi, r12d
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
    mov edi, r12d
    mov rsi, [rip + lk_relay_until]
    call lk_read_line
    cmp rax, 3
    jne 7f
    cmp word ptr [rip + lk_line], 0x6579           # "ye"
    jne 7f
    cmp byte ptr [rip + lk_line + 2], 's'
    jne 7f
    mov qword ptr [rip + lk_relay_took], 1
7:  mov edi, r12d
    SYS SYS_close
9:  EPILOGUE
.endif

# FN links_relay_args(): a rhun started for nothing but a rhun://ext/ link offers it to the rhun
# that made it, and quits when that one took it (before any window)
FN links_relay_args
    PROLOGUE
    cmp qword ptr [rip + g_start_paths + VEC_len], 1
    jne 9f
    mov rax, [rip + g_start_paths + VEC_ptr]
    mov rbx, [rax]
    mov rdi, rbx
    call links_is_link
    test eax, eax
    jz 9f
    mov rdi, rbx
    call links_relay
    test eax, eax
    jz 9f
    xor edi, edi
    call sys_exit
9:  EPILOGUE

# ---------------- for the tests ----------------

# c_link_deliver(out, args, len): link-deliver URL, as if the system opened the link
FN c_link_deliver
    PROLOGUE
    mov rdi, rsi
    mov rsi, rdx
    call trim
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rbx, rax
    mov rdi, rax
    call links_open_path
    mov rdi, rbx
    call mem_free
    xor eax, eax
    EPILOGUE

# c_print_links(out, args, len): "links=N dir=D listening=0|1"
FN c_print_links
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
    lea rax, [rip + lk_slots]
    mov ecx, LK_MAX
1:  cmp qword ptr [rax + LK_ext], 0
    je 2f
    inc r12d
2:  add rax, LK_SIZE
    dec ecx
    jnz 1b
    mov rdi, rbx
    lea rsi, [rip + .Lp_links]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, r12d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lp_listening]
    call sb_push_cstr
    xor esi, esi
    cmp dword ptr [rip + lk_sock], 0
    jl 3f
    mov esi, 1
3:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

.bss
.p2align 3
lk_relay_url: .quad 0
lk_relay_took: .quad 0
lk_relay_until: .quad 0
lk_ask_url: .quad 0             # owned cstr: the URL links_ask_open's chooser asks about, or 0
lk_ask_sb: .zero SB_SIZE
lk_ask_host: .zero 208
lk_ask_label: .zero 208         # the chooser's label (the palette keeps the pointer)

.section .rodata
.Lhttps: .asciz "https://"
.Lhttp: .asciz "http://"
.Lprefix: .asciz "rhun://ext/"
.Lhex: .ascii "0123456789abcdef"
.Lenv_open: .asciz "RHUN_OPEN_URL"
.Lenv_dir: .asciz "RHUN_LINK_DIR"
.Lenv_runtime: .asciz "XDG_RUNTIME_DIR"
.Lslash_rhun: .asciz "/rhun"
.Ltmp_rhun: .asciz "/tmp/rhun-"
.Llink_dash: .asciz "link-"
.Lslash_link: .asciz "/link-"
.Llink_sp: .ascii "link "
.Lnl: .ascii "\n"
.Lyes: .asciz "yes\n"
.Lno: .asciz "no\n"
.Lt_unexpected: .asciz "This link is not expected by any extension (it may have expired)"
.Lp_links: .asciz "links="
.Lp_listening: .asciz " listening="
.Lask_wants: .asciz " wants to open "
.Lask_browser: .asciz " in your browser: "
.Lask_open: .asciz "Open"
.Lask_copy: .asciz "Copy Link"
.Lask_cancel: .asciz "Cancel"
