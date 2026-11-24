# text/uri-list (RFC 2483) as local paths: what X11 and Wayland give for files copied or dragged (phase 4
# tasks 4 and 5). Portable: the platforms call it, and its unit checks run everywhere.
#
#   uri_list_paths(ptr, len) -> rax owned paths, a NUL after each (0: none), rdx their bytes
#     Lines end in CR LF (or LF); a line beginning "#" is a comment. Only file: URIs whose host is empty or
#     "localhost" are taken ("file:///p", "file://localhost/p"; "file:/p" too, as some programs write it); a
#     URI of another scheme or host is skipped. %XX is decoded; a path that decodes to a NUL, is empty or is
#     not absolute is skipped. At most CLIP_FILES_MAX bytes: the paths past that are left out.
.include "rhun.inc"

.bss
.p2align 3
usb: .zero SB_SIZE
.text

# hexval(byte) -> eax 0..15, or -1
hexval:
    lea eax, [rdi - '0']
    cmp eax, 9
    jbe 1f
    or edi, 0x20
    lea eax, [rdi - 'a']
    cmp eax, 5
    ja 2f
    add eax, 10
1:  ret
2:  mov eax, -1
    ret

# line(ptr, len): one URI into usb, a NUL after it (nothing when it is not a local file's)
line:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, 5
    jb 9f
    mov eax, [rbx]              # "file:" (any case)
    or eax, 0x20202020
    cmp eax, 0x656c6966
    jne 9f
    cmp byte ptr [rbx + 4], ':'
    jne 9f
    add rbx, 5
    sub r12, 5
    cmp r12, 2                  # "//host": empty or localhost
    jb 3f
    cmp word ptr [rbx], 0x2f2f
    jne 3f
    add rbx, 2
    sub r12, 2
    xor ecx, ecx
1:  cmp rcx, r12
    jae 9f
    cmp byte ptr [rbx + rcx], '/'
    je 2f
    inc rcx
    jmp 1b
2:  test rcx, rcx
    jz 3f
    cmp rcx, 9
    jne 9f
    mov rdi, rbx
    lea rsi, [rip + .Llocalhost]
    mov edx, 9
    call memeq
    test eax, eax
    jz 9f
    add rbx, 9
    sub r12, 9
3:  test r12, r12               # the path: absolute
    jz 9f
    cmp byte ptr [rbx], '/'
    jne 9f
    mov r14, [rip + usb + SB_len]   # where it begins, to take it back
    xor r13d, r13d
4:  cmp r13, r12
    jae 7f
    movzx esi, byte ptr [rbx + r13]
    inc r13
    cmp esi, '%'
    jne 6f
    lea rax, [r13 + 2]
    cmp rax, r12
    ja 6f                       # a lone "%": as it is
    movzx edi, byte ptr [rbx + r13]
    call hexval
    test eax, eax
    js 5f
    mov r15d, eax
    movzx edi, byte ptr [rbx + r13 + 1]
    call hexval
    test eax, eax
    js 5f
    shl r15d, 4
    or eax, r15d
    test eax, eax
    jz 8f                       # a NUL in a path: the path goes
    mov esi, eax
    add r13, 2
    jmp 6f
5:  mov esi, '%'
6:  lea rdi, [rip + usb]
    call sb_push_byte
    jmp 4b
7:  lea rdi, [rip + usb]
    xor esi, esi
    call sb_push_byte
    cmp qword ptr [rip + usb + SB_len], CLIP_FILES_MAX
    jbe 9f
8:  mov [rip + usb + SB_len], r14
9:  EPILOGUE

# FN uri_list_paths(ptr, len) -> rax owned paths or 0, rdx len: see the top
FN uri_list_paths
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + usb]
    call sb_clear
    xor r13d, r13d              # a line's start
1:  cmp r13, r12
    jae 8f
    mov r14, r13                # its end (LF), less a CR before it
2:  cmp r14, r12
    jae 3f
    cmp byte ptr [rbx + r14], 10
    je 3f
    inc r14
    jmp 2b
3:  mov rsi, r14
    sub rsi, r13
    jz 5f
    lea rax, [rbx + r13]
    cmp byte ptr [rax + rsi - 1], 13
    jne 4f
    dec rsi
    jz 5f
4:  cmp byte ptr [rbx + r13], '#'
    je 5f
    lea rdi, [rbx + r13]
    call line
5:  lea r13, [r14 + 1]
    jmp 1b
8:  xor eax, eax
    xor edx, edx
    cmp qword ptr [rip + usb + SB_len], 0
    je 9f
    mov rdi, [rip + usb + SB_ptr]
    mov rsi, [rip + usb + SB_len]
    call mem_dup
    mov rdx, [rip + usb + SB_len]
9:  EPILOGUE

.section .rodata
.Llocalhost: .ascii "localhost"
