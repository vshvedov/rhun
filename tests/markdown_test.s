# The link under a point (markdown.s md_link_at): a link's own words answer with it; the gap before
# it, a line without links, a point above or below the document, a blocked image's chip and a code
# block's Copy button answer -1; the scroll moves the point; a footnote's number is a link. On a
# failure the exit status is the number of the check that failed.
.include "rhun.inc"
.bss
.p2align 3
doc: .quad 0
step: .long 0
.text

# load(ptr, len) -> eax the height: doc is that text, laid out 600 wide (the one before freed)
load:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, [rip + doc]
    call md_free
    mov rdi, r12
    mov rsi, r13
    call md_new
    mov [rip + doc], rax
    mov rdi, rax
    mov esi, 600
    call md_layout
    EPILOGUE

# at(x, y, scroll) -> eax md_link_at of doc
at:
    mov ecx, edx
    mov edx, esi
    mov esi, edi
    mov rdi, [rip + doc]
    jmp md_link_at

# scan(link, y, scroll) -> eax the first x of 0..599 where the point is in that link, edx the last;
#   both -1 when there is none
scan:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov ebx, -1
    mov r15d, -1
    mov dword ptr [rsp], 0
1:  cmp dword ptr [rsp], 600
    jge 3f
    mov edi, [rsp]
    mov esi, r13d
    mov edx, r14d
    call at
    cmp eax, r12d
    jne 2f
    mov r15d, [rsp]
    cmp ebx, -1
    jne 2f
    mov ebx, [rsp]
2:  inc dword ptr [rsp]
    jmp 1b
3:  mov eax, ebx
    mov edx, r15d
    EPILOGUE

# hits(y, scroll) -> eax how many x of 0..599 are over a link
hits:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    xor ebx, ebx
    mov dword ptr [rsp], 0
1:  cmp dword ptr [rsp], 600
    jge 3f
    mov edi, [rsp]
    mov esi, r12d
    mov edx, r13d
    call at
    test eax, eax
    js 2f
    inc ebx
2:  inc dword ptr [rsp]
    jmp 1b
3:  mov eax, ebx
    EPILOGUE

.macro STEP n
    mov dword ptr [rip + step], \n
.endm

FN main
    PROLOGUE 16
    call app_load_fonts
    call ui_update_metrics
    # two links in a sentence, a paragraph without any
    STEP 1
    lea rdi, [rip + t1]
    mov esi, t1_end - t1
    call load
    mov [rsp + 12], eax         # the height
    mov rdi, [rip + doc]
    xor esi, esi
    call md_link_y
    test eax, eax
    js .Lfail
    add eax, 3
    mov r12d, eax               # a y inside the first line
    xor edi, edi
    mov esi, r12d
    xor edx, edx
    call scan
    STEP 2
    test eax, eax
    jle .Lfail                  # "Go to " comes first
    cmp edx, eax
    jle .Lfail
    mov r13d, eax               # the first link's first and last x
    mov r14d, edx
    STEP 3
    lea edi, [r13 - 1]          # just left of it
    mov esi, r12d
    xor edx, edx
    call at
    cmp eax, -1
    jne .Lfail
    STEP 4
    mov edi, r13d               # the same point, the document scrolled 40 down
    mov esi, r12d
    sub esi, 40
    mov edx, 40
    call at
    test eax, eax
    jne .Lfail
    STEP 5
    mov edi, r13d               # above the document, below it
    mov esi, -5
    xor edx, edx
    call at
    cmp eax, -1
    jne .Lfail
    mov edi, r13d
    mov esi, [rsp + 12]
    add esi, 5
    xor edx, edx
    call at
    cmp eax, -1
    jne .Lfail
    STEP 6
    mov edi, 1                  # the second link, after the first
    mov esi, r12d
    xor edx, edx
    call scan
    cmp eax, r14d
    jle .Lfail
    STEP 7
    mov edi, [rsp + 12]         # the last line: no link
    sub edi, 3
    xor esi, esi
    call hits
    test eax, eax
    jnz .Lfail
    # a footnote's number
    STEP 8
    lea rdi, [rip + t2]
    mov esi, t2_end - t2
    call load
    mov rdi, [rip + doc]
    xor esi, esi
    call md_link_y
    test eax, eax
    js .Lfail
    lea esi, [rax + 2]
    xor edi, edi
    xor edx, edx
    call scan
    test eax, eax
    jle .Lfail
    # a blocked image's chip is no link; the link after it is
    STEP 9
    lea rdi, [rip + t3]
    mov esi, t3_end - t3
    call load
    mov rdi, [rip + doc]
    xor esi, esi
    call md_link_y
    test eax, eax
    js .Lfail
    lea r12d, [rax + 3]
    xor edi, edi
    mov esi, r12d
    xor edx, edx
    call scan
    cmp eax, -1
    jne .Lfail
    STEP 10
    mov edi, 1
    mov esi, r12d
    xor edx, edx
    call scan
    test eax, eax
    jle .Lfail
    # a code block's Copy button is no link
    STEP 11
    lea rdi, [rip + t4]
    mov esi, t4_end - t4
    call load
    mov rdi, [rip + doc]
    xor esi, esi
    call md_link_y
    test eax, eax
    js .Lfail
    lea esi, [rax + 2]
    xor edi, edi
    xor edx, edx
    call scan
    cmp eax, -1
    jne .Lfail
    mov rdi, [rip + doc]
    call md_free
    lea rdi, [rip + ok]
    call log_cstr
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + failed]
    call log_cstr
    mov eax, [rip + step]
    EPILOGUE

.section .rodata
t1: .ascii "Go to [the docs](https://a.example) now and [two](https://b.example).\n\nNo links here at all.\n"
t1_end:
t2: .ascii "A note[^n] here.\n\n[^n]: the note\n"
t2_end:
t3: .ascii "![a picture](https://e.example/x.png) and [a link](https://a.example)\n"
t3_end:
t4: .ascii "```\ncode\n```\n"
t4_end:
ok: .asciz "ok\n"
failed: .asciz "failed\n"
