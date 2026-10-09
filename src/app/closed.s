# recently closed tabs: Reopen Closed Tab brings them back, the last closed first, at their place in the
# strip and with the cursor, selection and scroll a file had (as VS Code's Reopen Closed Editor does)
.include "rhun.inc"

.equ CLOSED_MAX, 20             # as many as VS Code keeps
.equ CK_DIFF, 0x10              # CT_kind of a diff view (a TAB_DOC with DOC_diff)

STRUCT
F CT_kind, 8                    # TAB_DOC, TAB_IMAGE, TAB_SETTINGS, TAB_GIT or CK_DIFF
F CT_path, 8                    # the file, or the diff's path in the work tree (owned); 0 for the others
F CT_rev, 8                     # the diff's commit (owned), 0 for the work tree
F CT_index, 8                   # its place in the strip
F CT_cur, 8                     # a text file's DOC_cur, DOC_anchor and scroll
F CT_anchor, 8
F CT_scrolly, 8
F CT_scrollx, 8
F CT_wtop, 8
F CT_woff, 8
ENDSTRUCT CT_SIZE

.bss
.p2align 3
closed: .zero CT_SIZE * CLOSED_MAX     # the oldest first
closed_n: .quad 0
probe: .zero CT_SIZE                   # the tab being noted, or the one being reopened

.text

# closed_note(i): remember tab i, which is about to close
FN closed_note
    PROLOGUE
    mov r12, rdi
    lea rdi, [rip + probe]
    xor esi, esi
    mov edx, CT_SIZE
    call memset
    lea rbx, [rip + probe]
    mov [rbx + CT_index], r12
    mov rdi, r12
    call tab_at
    mov rcx, [rax + TAB_kind]
    mov [rbx + CT_kind], rcx
    mov r13, [rax + TAB_doc]
    test r13, r13
    jz .Lcn_push                # Settings, the history
    mov r14, [r13 + DOC_diff]
    test r14, r14
    jnz .Lcn_diff
    mov rdi, [r13 + DOC_path]
    test rdi, rdi
    jz 9f                       # untitled: nothing to bring back
    call str_own
    mov [rbx + CT_path], rax
    mov rax, [r13 + DOC_cur]
    mov [rbx + CT_cur], rax
    mov rax, [r13 + DOC_anchor]
    mov [rbx + CT_anchor], rax
    mov rax, [r13 + DOC_scrolly]
    mov [rbx + CT_scrolly], rax
    mov rax, [r13 + DOC_scrollx]
    mov [rbx + CT_scrollx], rax
    mov rax, [r13 + DOC_wtop]
    mov [rbx + CT_wtop], rax
    mov rax, [r13 + DOC_woff]
    mov [rbx + CT_woff], rax
    jmp .Lcn_push
.Lcn_diff:
    mov qword ptr [rbx + CT_kind], CK_DIFF
    mov rdi, [r14 + DV_path]
    call str_own
    mov [rbx + CT_path], rax
    mov rdi, [r14 + DV_rev]
    test rdi, rdi
    jz .Lcn_push
    call str_own
    mov [rbx + CT_rev], rax
.Lcn_push:
    # a tab closed again is remembered once, as the latest
    xor r12d, r12d
1:  cmp r12, [rip + closed_n]
    jae 3f
    mov rdi, r12
    call entry_at
    mov rdi, rax
    call same_as_probe
    test eax, eax
    jz 2f
    mov rdi, r12
    call closed_drop
    jmp 1b
2:  inc r12
    jmp 1b
3:  cmp qword ptr [rip + closed_n], CLOSED_MAX
    jb 4f
    xor edi, edi
    call closed_drop            # the oldest makes room
4:  mov rdi, [rip + closed_n]
    call entry_at
    mov rdi, rax
    lea rsi, [rip + probe]
    mov edx, CT_SIZE
    call memcpy
    inc qword ptr [rip + closed_n]
9:  EPILOGUE

# closed_clear(): forget every closed tab
FN closed_clear
    push rbx
1:  mov rdi, [rip + closed_n]
    test rdi, rdi
    jz 2f
    dec rdi
    mov [rip + closed_n], rdi
    call entry_at
    mov rdi, rax
    call entry_free
    jmp 1b
2:  pop rbx
    ret

# cmd_reopen_closed_tab(): the last closed tab again. One that is open already, or whose file or
#   repository is gone, gives way to the one closed before it.
FN cmd_reopen_closed_tab
    PROLOGUE
1:  mov rdi, [rip + closed_n]
    test rdi, rdi
    jz 9f
    dec rdi
    mov [rip + closed_n], rdi
    call entry_at
    lea rdi, [rip + probe]
    mov rsi, rax
    mov edx, CT_SIZE
    call memcpy                 # probe owns its strings now
    call reopen_probe
    mov ebx, eax
    lea rdi, [rip + probe]
    call entry_free
    test ebx, ebx
    jz 1b
9:  EPILOGUE

# reopen_probe() -> eax 1 when the tab in probe opened (or a toast said why it could not), 0 when it
#   was passed over
reopen_probe:
    PROLOGUE
    lea rbx, [rip + probe]
    call probe_open
    test rax, rax
    jns 8f
    mov rax, [rbx + CT_kind]
    cmp rax, TAB_SETTINGS
    je .Lrp_settings
    cmp rax, TAB_GIT
    je .Lrp_git
    cmp rax, CK_DIFF
    je .Lrp_diff
    # a file, as long as it is still there
    mov rdi, [rbx + CT_path]
    call file_type
    test eax, eax
    jz 8f
    mov rdi, [rbx + CT_path]
    call app_open_file
    test rax, rax
    js 7f
    mov r12, [rip + g_doc]
    test r12, r12
    jz .Lrp_place               # an image
    mov rdi, r12
    mov rsi, [rbx + CT_cur]
    call clamp_pos
    mov [r12 + DOC_cur], rax
    mov rdi, r12
    mov rsi, [rbx + CT_anchor]
    call clamp_pos
    mov [r12 + DOC_anchor], rax
    mov rax, [rbx + CT_scrolly]
    mov [r12 + DOC_scrolly], rax
    mov rax, [rbx + CT_scrollx]
    mov [r12 + DOC_scrollx], rax
    mov rax, [rbx + CT_wtop]
    mov [r12 + DOC_wtop], rax
    mov rax, [rbx + CT_woff]
    mov [r12 + DOC_woff], rax
    mov dword ptr [rip + g_reveal], 0     # the view as it was, even with the cursor out of it
    jmp .Lrp_place
.Lrp_settings:
    call cmd_settings
    jmp .Lrp_place
.Lrp_git:
    cmp dword ptr [rip + g_git_on], 0
    je 8f
    call cmd_git_history
    jmp .Lrp_place
.Lrp_diff:
    cmp dword ptr [rip + g_git_on], 0
    je 8f
    mov rdi, [rbx + CT_path]
    call strlen
    mov rdx, rax
    mov rdi, [rbx + CT_rev]
    mov rsi, [rbx + CT_path]
    call git_open_diff
.Lrp_place:
    mov rdi, [rbx + CT_index]
    call app_place_tab
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# probe_open() -> the index of the tab probe stands for when it is open, or -1
probe_open:
    PROLOGUE
    lea r12, [rip + probe]
    mov r13, [r12 + CT_kind]
    cmp r13, TAB_SETTINGS
    je 1f
    cmp r13, TAB_GIT
    je 1f
    cmp r13, CK_DIFF
    je 1f
    mov rdi, [r12 + CT_path]
    call app_find_tab
    EPILOGUE
1:  xor ebx, ebx
2:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 8f
    mov rdi, rbx
    call tab_at
    mov rcx, [rax + TAB_kind]
    cmp r13, CK_DIFF
    je 3f
    cmp rcx, r13
    je 9f
    jmp 5f
3:  cmp rcx, TAB_DOC
    jne 5f
    mov rax, [rax + TAB_doc]
    mov r14, [rax + DOC_diff]
    test r14, r14
    jz 5f
    mov rdi, [r14 + DV_path]
    mov rsi, [r12 + CT_path]
    call str_same
    test eax, eax
    jz 5f
    mov rdi, [r14 + DV_rev]
    mov rsi, [r12 + CT_rev]
    call str_same
    test eax, eax
    jnz 9f
5:  inc rbx
    jmp 2b
8:  mov rbx, -1
9:  mov rax, rbx
    EPILOGUE

# same_as_probe(entry) -> eax 1 when it stands for the same tab as probe
same_as_probe:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rip + probe]
    mov rax, [rbx + CT_kind]
    cmp rax, [r12 + CT_kind]
    jne 8f
    mov rdi, [rbx + CT_path]
    mov rsi, [r12 + CT_path]
    call str_same
    test eax, eax
    jz 8f
    mov rdi, [rbx + CT_rev]
    mov rsi, [r12 + CT_rev]
    call str_same
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# closed_drop(i): forget entry i, the later ones moving down
closed_drop:
    PROLOGUE
    mov r12, rdi
    call entry_at
    mov rbx, rax
    mov rdi, rbx
    call entry_free
    mov rax, [rip + closed_n]
    dec rax
    mov [rip + closed_n], rax
    sub rax, r12
    imul rdx, rax, CT_SIZE
    mov rdi, rbx
    lea rsi, [rbx + CT_SIZE]
    call memmove
    EPILOGUE

# entry_at(i) -> CT*
entry_at:
    imul rax, rdi, CT_SIZE
    lea rcx, [rip + closed]
    add rax, rcx
    ret

# entry_free(entry): its strings
entry_free:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + CT_path]
    call mem_free
    mov rdi, [rbx + CT_rev]
    call mem_free
    mov qword ptr [rbx + CT_path], 0
    mov qword ptr [rbx + CT_rev], 0
    pop rbx
    ret

# str_same(a, b) -> eax 1 when both cstrs are equal, or both 0
str_same:
    cmp rdi, rsi
    je 1f
    test rdi, rdi
    jz 2f
    test rsi, rsi
    jz 2f
    jmp strcmp_eq
1:  mov eax, 1
    ret
2:  xor eax, eax
    ret

# str_own(cstr) -> a copy of it
str_own:
    push rbx
    mov rbx, rdi
    call strlen
    mov rsi, rax
    mov rdi, rbx
    pop rbx
    jmp mem_dup

# clamp_pos(doc, pos) -> pos inside the text, at the start of a character: the file may have changed
#   since its tab closed
clamp_pos:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call doc_len
    cmp r12, rax
    cmova r12, rax
1:  test r12, r12
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    call doc_byte
    and eax, 0xc0
    cmp eax, 0x80
    jne 2f
    dec r12
    jmp 1b
2:  mov rax, r12
    EPILOGUE
