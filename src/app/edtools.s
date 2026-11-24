# The editor's tools for Claude Code, independent of the transport (mcpsrv.s's MT functions): the bridge for
# terminal claude (ide_server.s) serves them as the official extension's IDE server does (ext-host-ide.md
# 1.6): openDiff, getDiagnostics, close_tab, closeAllDiffTabs (executeCode is left out: design section 9).
# The chat's in-process server (phase 4) can list the same functions in a server of its own.
#
#   edtool_ms                          the bridge's server: "Claude Code rhun MCP" and the four tools
#   edtool_diagnostics(sb, path cstr or 0) -> rax files    getDiagnostics' text: JSON.stringify(list, null, 2)
#                                      of {uri, linesInFile?, diagnostics: [{message, severity, range, source?,
#                                      code?}]}; positions from 0, characters in UTF-16 units; every file with a
#                                      problem, or the one named (its entry even when it has none)
#   edtool_selection(sb) -> eax 1      selection_changed's params for the active document: {text, filePath,
#                                      fileUrl, selection: {start, end, isEmpty}}; 0 when no file shows
#   edtool_selection_key() -> rax      what the selection depends on (document, version, cursor, anchor)
#                                      hashed: it changes when the selection may have
#   edtool_mention(sb) -> eax 1        at_mentioned's params: {filePath, lineStart?, lineEnd?} (lines from 0,
#                                      only for a selection that is not empty); 0 when no file shows
#   edtools_conn_gone(gen)             the transport's connection with that generation (a token's bits 20 to
#                                      55) went: its diffs close; nobody hears them
#   edtools_dump(sb)                   print-ide's "diff TOKEN id=ID tab=NAME" lines
#
# openDiff opens the proposed text in the Review tab as an offer (review.s) and answers when the user accepts
# (FILE_SAVED and the text accepted), rejects or closes it (DIFF_REJECTED and the tab's name). rhun writes no
# file: the CLI does, with the text it gets. The text before is the file's on disk only when the path is in
# a folder of the window, as the extension reads it only from its folders; anything else is an empty text.
.include "rhun.inc"

.equ PD_MAX, 32                 # diffs waiting for the user
.equ SEL_TEXT_MAX, 1048576      # selection_changed carries at most this much of the selected text

STRUCT
F PD_token, 8           # the call's token (0: a free entry)
F PD_id, 8              # its offer
F PD_tab, 8             # tab_name (owned)
ENDSTRUCT PD_SIZE

.bss
.p2align 3
pds: .zero PD_SIZE * PD_MAX
dout: .zero SB_SIZE             # an answer's content, built here
cj: .zero SB_SIZE               # getDiagnostics' list, compact
qs: .zero SB_SIZE               # one quoted string
pbuf: .zero 4200                # a path, decoded

.data
.p2align 3
.globl edtool_ms
edtool_ms: .quad .Ls_name, rhun_version, tools, 4
tools:
    .quad .Lt_open_diff, .Ld_open_diff, .Ls_open_diff
    .long 0, 0
    .quad 0, t_open_diff
    .quad .Lt_diag, .Ld_diag, .Ls_diag
    .long MTF_READONLY, 0
    .quad 0, t_diagnostics
    .quad .Lt_close_tab, 0, .Ls_close_tab
    .long 0, 0
    .quad 0, t_close_tab
    .quad .Lt_close_all, .Ld_close_all, .Ls_close_all
    .long 0, 0
    .quad 0, t_close_all
rvo: .quad offer_done, 0, .Ls_owner

.text

# ---------------- arguments ----------------

# str_arg(args, key) -> rax ptr (NUL after it), rdx len; rax 0 when it is not a string
str_arg:
    push rbx
    call json_get
    mov rdi, rax
    call json_str
    pop rbx
    ret

# path_in_folder(path cstr) -> eax 1 when it is absolute, has no ".." part and is inside a folder of the
#   window (the extension's tools read only there)
path_in_folder:
    PROLOGUE
    mov rbx, rdi
    PATH_ABSOLUTE rbx, 1f
    jmp 8f
1:  xor ecx, ecx                # a ".." part anywhere
2:  movzx eax, byte ptr [rbx + rcx]
    test eax, eax
    jz 5f
    cmp eax, '.'
    jne 4f
    cmp byte ptr [rbx + rcx + 1], '.'
    jne 4f
    test rcx, rcx
    jz 3f
    movzx eax, byte ptr [rbx + rcx - 1]
    cmp eax, '/'
    je 3f
    cmp eax, 92
    jne 4f
3:  movzx eax, byte ptr [rbx + rcx + 2]
    test eax, eax
    jz 8f
    cmp eax, '/'
    je 8f
    cmp eax, 92
    je 8f
4:  inc rcx
    jmp 2b
5:  mov rdi, rbx
    call wfold_of
    test rax, rax
    js 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- openDiff ----------------

# t_open_diff(args, out, token) -> MCP_LATER, or MCP_ERROR with out the message
t_open_diff:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], rdx              # token
    lea rsi, [rip + .Lk_old]
    call str_arg
    test rax, rax
    jz .Lod_args
    mov [rsp + 8], rax          # old_file_path
    mov rdi, rbx
    lea rsi, [rip + .Lk_new]
    call str_arg
    test rax, rax
    jz .Lod_args
    mov [rsp + 16], rax         # new_file_path
    mov rdi, rbx
    lea rsi, [rip + .Lk_contents]
    call str_arg
    test rax, rax
    jz .Lod_args
    mov [rsp + 24], rax         # new_file_contents
    mov [rsp + 32], rdx
    cmp rdx, 4194304
    ja .Lod_big
    mov rdi, rbx
    lea rsi, [rip + .Lk_tab]
    call str_arg
    test rax, rax
    jz .Lod_args
    mov [rsp + 40], rax         # tab_name
    # a free entry
    lea r13, [rip + pds]
    xor ecx, ecx
1:  cmp qword ptr [r13 + PD_token], 0
    je 2f
    add r13, PD_SIZE
    inc ecx
    cmp ecx, PD_MAX
    jb 1b
    lea rsi, [rip + .Le_many]
    jmp .Lod_err
2:  # a diff of the same name waits: it is rejected and closed first (the extension closes it)
    lea rdi, [rip + rvo]
    mov rsi, [rsp + 40]
    call review_offer_by_label
    test rax, rax
    jz 3f
    mov r14, rax
    mov rdi, rax
    call review_offer_reject
    mov rdi, r14
    call review_offer_close
3:  # the text before: the file on disk, when the path is in a folder of the window
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    mov rdi, [rsp + 8]
    call path_in_folder
    test eax, eax
    jz 4f
    mov rdi, [rsp + 8]
    mov esi, 4194304
    call file_read_limited
    test rax, rax
    jz 4f
    mov [rsp + 48], rax
    mov [rsp + 56], rdx
4:  # the offer: before and after (copied), the tab named tab_name
    sub rsp, 32
    mov rax, [rsp + 32 + 48]
    test rax, rax
    jnz 5f
    lea rax, [rip + .Lempty]
5:  mov [rsp + OT_old], rax
    mov rax, [rsp + 32 + 56]
    mov [rsp + OT_oldlen], rax
    mov rax, [rsp + 32 + 24]
    mov [rsp + OT_new], rax
    mov rax, [rsp + 32 + 32]
    mov [rsp + OT_newlen], rax
    lea rdi, [rip + rvo]
    mov rsi, [rsp + 32]         # ctx: the token
    mov rdx, [rsp + 32 + 40]
    mov rcx, [rsp + 32 + 16]
    lea r8, [rsp]
    mov r9d, 1
    call review_offer
    add rsp, 32
    mov r14, rax
    mov rdi, [rsp + 48]
    call mem_free
    test r14, r14
    jz .Lod_refused
    mov rax, [rsp]
    mov [r13 + PD_token], rax
    mov [r13 + PD_id], r14
    mov rdi, [rsp + 40]
    call strlen
    mov rsi, rax
    mov rdi, [rsp + 40]
    inc rsi
    call mem_dup
    mov [r13 + PD_tab], rax
    mov eax, MCP_LATER
    EPILOGUE
.Lod_args:
    lea rsi, [rip + .Le_args]
    jmp .Lod_err
.Lod_big:
    lea rsi, [rip + .Le_big]
    jmp .Lod_err
.Lod_refused:
    lea rsi, [rip + .Le_refused]
.Lod_err:
    mov rdi, r12
    call sb_push_cstr
    mov eax, MCP_ERROR
    EPILOGUE

# offer_done(token, OFFER_*, text ptr, len, edited): the user decided: FILE_SAVED and the text, or
#   DIFF_REJECTED and the tab's name
offer_done:
    PROLOGUE 16
    mov r12, rdi
    mov r13d, esi
    mov r14, rdx
    mov r15, rcx
    lea rbx, [rip + pds]
    xor ecx, ecx
1:  cmp [rbx + PD_token], r12
    je 2f
    add rbx, PD_SIZE
    inc ecx
    cmp ecx, PD_MAX
    jb 1b
    jmp 9f
2:  lea rdi, [rip + dout]
    call jw_begin
    lea rdi, [rip + dout]
    call jw_arr
    cmp r13d, OFFER_ACCEPT
    jne 3f
    lea rsi, [rip + .Lv_saved]
    mov edx, .Lv_saved_end - .Lv_saved
    call text_item
    mov rsi, r14
    mov rdx, r15
    call text_item
    jmp 4f
3:  lea rsi, [rip + .Lv_rejected]
    mov edx, .Lv_rejected_end - .Lv_rejected
    call text_item
    mov rdi, [rbx + PD_tab]
    call strlen
    mov rdx, rax
    mov rsi, [rbx + PD_tab]
    call text_item
4:  lea rdi, [rip + dout]
    call jw_end_arr
    mov qword ptr [rbx + PD_token], 0
    mov rdi, [rbx + PD_tab]
    call mem_free
    mov qword ptr [rbx + PD_tab], 0
    mov rdi, r12
    lea rsi, [rip + dout]
    mov edx, MTF_RAW
    call mcp_later_done
9:  EPILOGUE

# text_item(ptr, len): dout gets {"type":"text","text":T}
text_item:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + dout]
    call jw_obj
    lea rdi, [rip + dout]
    lea rsi, [rip + .Lk_type]
    call jw_key
    lea rdi, [rip + dout]
    lea rsi, [rip + .Lk_text]
    call jw_cstr
    lea rdi, [rip + dout]
    lea rsi, [rip + .Lk_text]
    call jw_key
    lea rdi, [rip + dout]
    mov rsi, r12
    mov rdx, r13
    call jw_str
    lea rdi, [rip + dout]
    call jw_end_obj
    EPILOGUE

# ---------------- close_tab, closeAllDiffTabs ----------------

# t_close_tab(args, out, token): the diff of that name closes (rejected when it was undecided)
t_close_tab:
    PROLOGUE
    mov r12, rsi
    lea rsi, [rip + .Lk_tab]
    call str_arg
    test rax, rax
    jz 1f
    lea rdi, [rip + rvo]
    mov rsi, rax
    call review_offer_by_label
    test rax, rax
    jz 1f
    mov rbx, rax
    mov rdi, rax
    call review_offer_reject
    mov rdi, rbx
    call review_offer_close
1:  mov rdi, r12
    lea rsi, [rip + .Lv_tab_closed]
    call sb_push_cstr
    mov eax, MCP_OK
    EPILOGUE

# t_close_all(args, out, token): every diff of the bridge closes: "CLOSED_N_DIFF_TABS"
t_close_all:
    PROLOGUE
    mov r12, rsi
    lea rbx, [rip + pds]        # the undecided ones are rejected first: their calls are answered
    xor r13d, r13d
1:  cmp qword ptr [rbx + PD_token], 0
    je 2f
    mov rdi, [rbx + PD_id]
    call review_offer_reject
2:  add rbx, PD_SIZE
    inc r13d
    cmp r13d, PD_MAX
    jb 1b
    lea rdi, [rip + rvo]
    call review_offers_close
    mov r13d, eax
    mov rdi, r12
    lea rsi, [rip + .Lv_closed]
    call sb_push_cstr
    mov rdi, r12
    mov esi, r13d
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Lv_diff_tabs]
    call sb_push_cstr
    mov eax, MCP_OK
    EPILOGUE

# FN edtools_conn_gone(gen): the diffs of that connection close without an answer
FN edtools_conn_gone
    PROLOGUE
    mov r12, rdi
    lea rbx, [rip + pds]
    xor r13d, r13d
1:  mov rax, [rbx + PD_token]
    test rax, rax
    jz 2f
    shl rax, 8                  # the generation: bits 20 to 55
    shr rax, 28
    cmp rax, r12
    jne 2f
    mov qword ptr [rbx + PD_token], 0
    mov rdi, [rbx + PD_tab]
    call mem_free
    mov qword ptr [rbx + PD_tab], 0
    mov rdi, [rbx + PD_id]
    call review_offer_close
2:  add rbx, PD_SIZE
    inc r13d
    cmp r13d, PD_MAX
    jb 1b
    EPILOGUE

# FN edtools_dump(sb): "diff TOKEN id=ID tab=NAME" for each waiting diff
FN edtools_dump
    PROLOGUE
    mov r12, rdi
    lea rbx, [rip + pds]
    xor r13d, r13d
1:  cmp qword ptr [rbx + PD_token], 0
    je 2f
    mov rdi, r12
    lea rsi, [rip + .Ldm_diff]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + PD_token]
    shl rsi, 8
    shr rsi, 8
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ldm_id]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + PD_id]
    call sb_push_u64
    mov rdi, r12
    lea rsi, [rip + .Ldm_tab]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [rbx + PD_tab]
    call sb_push_cstr
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
2:  add rbx, PD_SIZE
    inc r13d
    cmp r13d, PD_MAX
    jb 1b
    EPILOGUE

# ---------------- getDiagnostics ----------------

# t_diagnostics(args, out, token): the text of edtool_diagnostics for the uri given, or for every file
t_diagnostics:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
    lea rsi, [rip + .Lk_uri]
    call str_arg
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call uri_path
    test rax, rax
    jz .Ltd_bad
    mov r13, rax
1:  mov rdi, r12
    mov rsi, r13
    call edtool_diagnostics
    mov eax, MCP_OK
    EPILOGUE
.Ltd_bad:
    mov rdi, r12
    lea rsi, [rip + .Le_uri]
    call sb_push_cstr
    mov eax, MCP_ERROR
    EPILOGUE

# uri_path(ptr, len) -> rax the path it names (pbuf), or 0: "file://" and %XX decoded, or an absolute path
uri_path:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, 4096
    ja 8f
    lea r13, [rip + pbuf]
    xor r14d, r14d              # written
    xor ecx, ecx
    cmp r12, 7
    jb 3f
    mov eax, [rbx]
    or eax, 0x20202020
    cmp eax, 0x656c6966         # "file"
    jne 3f
    cmp byte ptr [rbx + 4], ':'
    jne 3f
    cmp word ptr [rbx + 5], 0x2f2f      # "//"
    jne 8f
    mov ecx, 7
.ifdef WINDOWS
    # file:///C:/x -> C:/x
    lea rax, [rcx + 3]
    cmp rax, r12
    ja 1f
    cmp byte ptr [rbx + rcx], '/'
    jne 1f
    cmp byte ptr [rbx + rcx + 2], ':'
    jne 1f
    inc ecx
.endif
1:  cmp rcx, r12
    jae 7f
    movzx eax, byte ptr [rbx + rcx]
    inc rcx
    cmp eax, '%'
    jne 2f
    lea rdx, [rcx + 2]
    cmp rdx, r12
    ja 8f
    movzx edi, byte ptr [rbx + rcx]
    call hexval
    mov r15d, eax
    movzx edi, byte ptr [rbx + rcx + 1]
    call hexval
    test r15d, r15d
    js 8f
    test eax, eax
    js 8f
    shl r15d, 4
    or eax, r15d
    add rcx, 2
2:  test eax, eax
    jz 8f
    mov [r13 + r14], al
    inc r14
    jmp 1b
3:  # a plain path
    cmp rcx, r12
    jae 7f
    movzx eax, byte ptr [rbx + rcx]
    test eax, eax
    jz 8f
    mov [r13 + r14], al
    inc r14
    inc rcx
    jmp 3b
7:  mov byte ptr [r13 + r14], 0
    test r14, r14
    jz 8f
    PATH_ABSOLUTE r13, 9f
8:  xor eax, eax
    EPILOGUE
9:  mov rax, r13
    EPILOGUE

# hexval(byte) -> eax 0-15 or -1 (keeps rcx)
hexval:
    mov eax, edi
    sub eax, '0'
    cmp eax, 9
    jbe 1f
    mov eax, edi
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 5
    ja 2f
    add eax, 10
1:  ret
2:  mov eax, -1
    ret

# FN edtool_diagnostics(sb, path cstr or 0) -> rax the files listed: the list built compact in cj, then
#   written as JSON.stringify(list, null, 2) does
FN edtool_diagnostics
    PROLOGUE 32
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov qword ptr [rsp + 16], 0 # files
    mov dword ptr [rsp + 24], 0 # the named file was found open
    lea rdi, [rip + cj]
    call jw_begin
    lea rdi, [rip + cj]
    call jw_arr
    # open documents: their marks
    xor r12d, r12d
1:  cmp r12, [rip + g_tabs + VEC_len]
    jae 4f
    mov rdi, r12
    inc r12
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 1b
    mov r13, [rax + TAB_doc]
    mov rsi, [r13 + DOC_path]
    test rsi, rsi
    jz 1b
    cmp qword ptr [r13 + DOC_diff], 0
    jne 1b
    mov rdi, [rsp + 8]
    test rdi, rdi
    jz 2f
    call strcmp_eq
    test eax, eax
    jz 1b
    mov dword ptr [rsp + 24], 1
    jmp 3f
2:  mov rdi, r13                # every file: only one with a problem
    call live_marks
    test eax, eax
    jz 1b
3:  mov rdi, r13
    call doc_entry
    inc qword ptr [rsp + 16]
    jmp 1b
4:  # the Problems store: files that are not open
    xor r12d, r12d
5:  call problems_count
    cmp r12, rax
    jae 8f
    mov rdi, r12
    inc r12
    call problems_at
    mov r13, rax
    mov rdi, [r13 + PR_path]
    call file_open_doc
    test rax, rax
    jnz 5b                      # its marks were listed with its document
    mov rdi, [rsp + 8]
    test rdi, rdi
    jz 6f
    mov rsi, [r13 + PR_path]
    call strcmp_eq
    test eax, eax
    jz 5b
6:  # one entry a file: the problems of the store are in the order they came, a file's together or not
    mov rdi, r12
    dec rdi
    call first_of_path
    test eax, eax
    jz 5b
    mov rdi, r12
    dec rdi
    call store_entry
    inc qword ptr [rsp + 16]
    mov rdi, [rsp + 8]
    test rdi, rdi
    jz 5b
    mov dword ptr [rsp + 24], 1
    jmp 5b
8:  # a file named that has nothing: its empty entry
    mov rsi, [rsp + 8]
    test rsi, rsi
    jz 9f
    cmp dword ptr [rsp + 24], 0
    jne 9f
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    mov rsi, [rsp + 8]
    call uri_member
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_diagnostics]
    call jw_key
    lea rdi, [rip + cj]
    call jw_arr
    lea rdi, [rip + cj]
    call jw_end_arr
    lea rdi, [rip + cj]
    call jw_end_obj
    inc qword ptr [rsp + 16]
9:  lea rdi, [rip + cj]
    call jw_end_arr
    mov rdi, [rsp]
    mov rsi, [rip + cj + SB_ptr]
    mov rdx, [rip + cj + SB_len]
    call pretty
    mov rax, [rsp + 16]
    EPILOGUE

# file_open_doc(path) -> rax its open text document, or 0
file_open_doc:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + g_tabs + VEC_len]
    jae 8f
    mov rdi, r12
    inc r12
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 1b
    mov r13, [rax + TAB_doc]
    mov rdi, [r13 + DOC_path]
    test rdi, rdi
    jz 1b
    cmp qword ptr [r13 + DOC_diff], 0
    jne 1b
    mov rsi, rbx
    call strcmp_eq
    test eax, eax
    jz 1b
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# first_of_path(i) -> eax 1 when no problem before the i-th of the store has its path
first_of_path:
    PROLOGUE
    mov r12, rdi
    call problems_at
    mov r13, [rax + PR_path]
    xor ebx, ebx
1:  cmp rbx, r12
    jae 8f
    mov rdi, rbx
    inc rbx
    call problems_at
    mov rdi, [rax + PR_path]
    mov rsi, r13
    call strcmp_eq
    test eax, eax
    jz 1b
    xor eax, eax
    EPILOGUE
8:  mov eax, 1
    EPILOGUE

# mark_alive(MK*) -> eax 1 when its owner shows it (extmarks.s's mark_live)
mark_alive:
    test dword ptr [rdi + MK_pad], MKF_SOURCE
    jnz 1f
    mov rdi, [rdi + MK_owner]
    jmp ext_is_visible
1:  mov eax, 1
    ret

# live_marks(doc) -> eax 1 when it has a mark its owner shows
live_marks:
    PROLOGUE
    mov rbx, [rdi + DOC_xmarks]
    test rbx, rbx
    jz 8f
    xor r12d, r12d
1:  cmp r12, [rbx + VEC_len]
    jae 8f
    imul rdi, r12, MK_SIZE
    add rdi, [rbx + VEC_ptr]
    inc r12
    call mark_alive
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# uri_member(cj, path): "uri": file://PATH (Windows: file:///C:/x with slashes)
uri_member:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    lea rsi, [rip + .Lk_uri]
    call jw_key
    mov rdi, r12
    call file_url
    mov rdi, rbx
    mov rsi, [rip + qs + SB_ptr]
    mov rdx, [rip + qs + SB_len]
    call jw_str
    EPILOGUE

# file_url(path): qs gets its file URL
file_url:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + qs]
    call sb_clear
    lea rdi, [rip + qs]
    lea rsi, [rip + .Lfile_scheme]
    call sb_push_cstr
.ifdef WINDOWS
    lea rdi, [rip + qs]
    mov esi, '/'
    call sb_push_byte
1:  movzx esi, byte ptr [rbx]
    test esi, esi
    jz 9f
    inc rbx
    cmp esi, 92
    jne 2f
    mov esi, '/'
2:  lea rdi, [rip + qs]
    call sb_push_byte
    jmp 1b
9:
.else
    lea rdi, [rip + qs]
    mov rsi, rbx
    call sb_push_cstr
.endif
    EPILOGUE

# doc_entry(doc): cj gets the file's entry: uri, linesInFile, its live marks
doc_entry:
    PROLOGUE 16
    mov rbx, rdi
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    mov rsi, [rbx + DOC_path]
    call uri_member
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_lines]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, [rbx + DOC_nlines]
    call jw_u64
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_diagnostics]
    call jw_key
    lea rdi, [rip + cj]
    call jw_arr
    mov r12, [rbx + DOC_xmarks]
    test r12, r12
    jz 9f
    xor r13d, r13d
1:  cmp r13, [r12 + VEC_len]
    jae 9f
    imul r14, r13, MK_SIZE
    add r14, [r12 + VEC_ptr]
    inc r13
    mov rdi, r14
    call mark_alive
    test eax, eax
    jz 1b
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_message]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, [r14 + MK_msg]
    call jw_cstr
    mov edi, [r14 + MK_sev]
    call sev_member
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_range]
    call jw_key
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_start]
    call jw_key
    mov rdi, rbx
    mov rsi, [r14 + MK_start]
    call pos_obj
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_end]
    call jw_key
    mov rdi, rbx
    mov rsi, [r14 + MK_end]
    call pos_obj
    lea rdi, [rip + cj]
    call jw_end_obj
    # source: the problems source's label, or the extension's name
    test dword ptr [r14 + MK_pad], MKF_SOURCE
    jz 2f
    mov rax, [r14 + MK_owner]
    mov rsi, [rax + PS_label]
    jmp 3f
2:  mov rdi, [r14 + MK_owner]
    call ext_full_name
    mov rsi, rax
3:  test rsi, rsi
    jz 4f
    cmp byte ptr [rsi], 0
    je 4f
    mov [rsp], rsi
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_source]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, [rsp]
    call jw_cstr
4:  lea rdi, [rip + cj]
    call jw_end_obj
    jmp 1b
9:  lea rdi, [rip + cj]
    call jw_end_arr
    lea rdi, [rip + cj]
    call jw_end_obj
    EPILOGUE

# sev_member(SEV_*): cj gets "severity": its name
sev_member:
    PROLOGUE
    mov ebx, edi
    and ebx, 3
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_severity]
    call jw_key
    lea rax, [rip + sev_names]
    mov rsi, [rax + rbx*8]
    lea rdi, [rip + cj]
    call jw_cstr
    EPILOGUE

# pos_obj(doc, pos): cj gets {"line":L,"character":C}: from 0, the character in UTF-16 units
pos_obj:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call doc_len
    cmp r12, rax
    jbe 1f
    mov r12, rax
1:  mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov r13, rax
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    call u16_count
    mov r14, rax
    mov rdi, r13
    mov rsi, r14
    call lc_obj
    EPILOGUE

# lc_obj(line, character): cj gets {"line":L,"character":C}
lc_obj:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_line]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, r12
    call jw_u64
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_character]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, r13
    call jw_u64
    lea rdi, [rip + cj]
    call jw_end_obj
    EPILOGUE

# u16_count(doc, from, to) -> rax the UTF-16 units of those bytes
u16_count:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r12, r13
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_byte
    inc r12
    mov ecx, eax
    and ecx, 0xc0
    cmp ecx, 0x80
    je 1b                       # a continuation byte
    inc r14
    cmp eax, 0xf0
    jb 1b
    inc r14                     # four bytes: a surrogate pair
    jmp 1b
9:  mov rax, r14
    EPILOGUE

# store_entry(i): cj gets the entry of the i-th problem's file: every problem of the store with its path
store_entry:
    PROLOGUE 16
    call problems_at
    mov r15, [rax + PR_path]
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    mov rsi, r15
    call uri_member
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_diagnostics]
    call jw_key
    lea rdi, [rip + cj]
    call jw_arr
    xor r12d, r12d
1:  call problems_count
    cmp r12, rax
    jae 9f
    mov rdi, r12
    inc r12
    call problems_at
    mov rbx, rax
    mov rdi, [rbx + PR_path]
    mov rsi, r15
    call strcmp_eq
    test eax, eax
    jz 1b
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_message]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, [rbx + PR_msg]
    call jw_cstr
    mov edi, [rbx + PR_sev]
    call sev_member
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_range]
    call jw_key
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_start]
    call jw_key
    mov edi, [rbx + PR_line]    # 1-based: 0 none
    mov esi, [rbx + PR_col]
    call from1
    mov r13, rdi
    mov r14, rsi
    call lc_obj
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_end]
    call jw_key
    mov r13d, [rbx + PR_line]   # a missing end is the start
    mov r14d, [rbx + PR_col]
    cmp dword ptr [rbx + PR_endline], 0
    je 2f
    mov r13d, [rbx + PR_endline]
    mov r14d, [rbx + PR_endcol]
2:  mov edi, r13d
    mov esi, r14d
    call from1
    call lc_obj
    lea rdi, [rip + cj]
    call jw_end_obj
    mov rax, [rbx + PR_src]
    mov rsi, [rax + PS_label]
    test rsi, rsi
    jz 3f
    cmp byte ptr [rsi], 0
    je 3f
    mov [rsp], rsi
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_source]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, [rsp]
    call jw_cstr
3:  mov rsi, [rbx + PR_code]
    test rsi, rsi
    jz 4f
    cmp byte ptr [rsi], 0
    je 4f
    mov [rsp], rsi
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_code]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, [rsp]
    call jw_cstr
4:  lea rdi, [rip + cj]
    call jw_end_obj
    jmp 1b
9:  lea rdi, [rip + cj]
    call jw_end_arr
    lea rdi, [rip + cj]
    call jw_end_obj
    EPILOGUE

# from1(line, col) -> rdi, rsi from 0 (1-based numbers, 0 for none)
from1:
    mov eax, edi
    test eax, eax
    jz 1f
    dec eax
1:  mov ecx, esi
    test ecx, ecx
    jz 2f
    dec ecx
2:  mov edi, eax
    mov esi, ecx
    ret

# pretty(sb, json ptr, len): compact JSON (the writer's) appended as JSON.stringify(v, null, 2) writes it:
#   two spaces a level, ": " after a key, an empty array or object as [] or {}
pretty:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d              # read
    xor r15d, r15d              # depth
1:  cmp r14, r13
    jae 9f
    movzx esi, byte ptr [r12 + r14]
    inc r14
    cmp esi, '"'
    je .Lpp_string
    cmp esi, '{'
    je .Lpp_open
    cmp esi, '['
    je .Lpp_open
    cmp esi, '}'
    je .Lpp_close
    cmp esi, ']'
    je .Lpp_close
    cmp esi, ','
    je .Lpp_comma
    cmp esi, ':'
    je .Lpp_colon
    mov rdi, rbx
    call sb_push_byte
    jmp 1b
.Lpp_string:
    mov rdi, rbx
    call sb_push_byte
2:  cmp r14, r13
    jae 9f
    movzx esi, byte ptr [r12 + r14]
    inc r14
    mov rdi, rbx
    push rsi
    push rsi
    call sb_push_byte
    pop rsi
    pop rsi
    cmp esi, '\\'
    jne 3f
    cmp r14, r13
    jae 9f
    movzx esi, byte ptr [r12 + r14]
    inc r14
    mov rdi, rbx
    call sb_push_byte
    jmp 2b
3:  cmp esi, '"'
    jne 2b
    jmp 1b
.Lpp_open:
    mov rdi, rbx
    call sb_push_byte
    cmp r14, r13                # empty: [] or {}
    jae 1b
    movzx eax, byte ptr [r12 + r14]
    cmp eax, ']'
    je 4f
    cmp eax, '}'
    je 4f
    inc r15
    call newline
    jmp 1b
4:  mov esi, eax
    inc r14
    mov rdi, rbx
    call sb_push_byte
    jmp 1b
.Lpp_close:
    push rsi
    push rsi
    dec r15
    call newline
    pop rsi
    pop rsi
    mov rdi, rbx
    call sb_push_byte
    jmp 1b
.Lpp_comma:
    mov rdi, rbx
    call sb_push_byte
    call newline
    jmp 1b
.Lpp_colon:
    mov rdi, rbx
    call sb_push_byte
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# newline(): rbx gets a line feed and two spaces for each of r15 levels
newline:
    push r14
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov r14, r15
1:  test r14, r14
    jle 9f
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    dec r14
    jmp 1b
9:  pop r14
    ret

# ---------------- the selection and mentions ----------------

# usable_doc() -> rax the active text document with a file, or 0 (a Review or diff tab, an image, a document
#   without a path: none)
usable_doc:
    mov rax, [rip + g_doc]
    test rax, rax
    jz 9f
    cmp qword ptr [rax + DOC_path], 0
    je 8f
    cmp qword ptr [rax + DOC_diff], 0
    jne 8f
    cmp qword ptr [rax + DOC_img], 0
    jne 8f
    ret
8:  xor eax, eax
9:  ret

# FN edtool_selection_key() -> rax
FN edtool_selection_key
    sub rsp, 8
    call usable_doc
    add rsp, 8
    test rax, rax
    jz 9f
    mov rcx, [rax + DOC_version]
    imul rcx, rcx, 1000003
    xor rcx, [rax + DOC_cur]
    imul rcx, rcx, 1000003
    xor rcx, [rax + DOC_anchor]
    imul rcx, rcx, 1000003
    xor rax, rcx
9:  ret

# FN edtool_selection(sb) -> eax 1 with sb the params of selection_changed, 0 when no file shows
FN edtool_selection
    PROLOGUE 16
    mov r15, rdi
    call usable_doc
    test rax, rax
    jz 8f
    mov rbx, rax
    mov r12, [rbx + DOC_cur]    # start, end
    mov r13, [rbx + DOC_anchor]
    cmp r12, r13
    jbe 1f
    xchg r12, r13
1:  mov rdi, r15
    call jw_begin
    mov rdi, r15
    call jw_obj
    mov rdi, r15
    lea rsi, [rip + .Lk_text]
    call jw_key
    # the selected text, at most SEL_TEXT_MAX bytes (cut at a character's start)
    mov r14, r13
    sub r14, r12
    cmp r14, SEL_TEXT_MAX
    jbe 2f
    mov r14d, SEL_TEXT_MAX
21: lea rsi, [r12 + r14]
    mov rdi, rbx
    call doc_byte
    and eax, 0xc0
    cmp eax, 0x80
    jne 2f
    dec r14
    jnz 21b
2:  lea rdi, [r14 + 1]
    call mem_alloc
    mov [rsp], rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    mov rcx, [rsp]
    call doc_copy
    mov rdi, r15
    mov rsi, [rsp]
    mov rdx, r14
    call jw_str
    mov rdi, [rsp]
    call mem_free
    mov rdi, r15
    lea rsi, [rip + .Lk_file_path]
    call jw_key
    mov rdi, r15
    mov rsi, [rbx + DOC_path]
    call jw_cstr
    mov rdi, r15
    lea rsi, [rip + .Lk_file_url]
    call jw_key
    mov rdi, [rbx + DOC_path]
    call file_url
    mov rdi, r15
    mov rsi, [rip + qs + SB_ptr]
    mov rdx, [rip + qs + SB_len]
    call jw_str
    mov rdi, r15
    lea rsi, [rip + .Lk_selection]
    call jw_key
    mov rdi, r15
    call jw_obj
    mov rdi, r15
    lea rsi, [rip + .Lk_start]
    call jw_key
    mov rdi, r15
    mov rsi, rbx
    mov rdx, r12
    call sel_pos
    mov rdi, r15
    lea rsi, [rip + .Lk_end]
    call jw_key
    mov rdi, r15
    mov rsi, rbx
    mov rdx, r13
    call sel_pos
    mov rdi, r15
    lea rsi, [rip + .Lk_is_empty]
    call jw_key
    xor esi, esi
    cmp r12, r13
    sete sil
    mov rdi, r15
    call jw_bool
    mov rdi, r15
    call jw_end_obj
    mov rdi, r15
    call jw_end_obj
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# sel_pos(sb, doc, pos): sb gets {"line":L,"character":C} (UTF-16 units)
sel_pos:
    PROLOGUE
    mov r15, rdi
    mov rbx, rsi
    mov r12, rdx
    mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov r13, rax
    mov rdi, rbx
    mov rsi, rax
    call doc_line_start
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    call u16_count
    mov r14, rax
    mov rdi, r15
    call jw_obj
    mov rdi, r15
    lea rsi, [rip + .Lk_line]
    call jw_key
    mov rdi, r15
    mov rsi, r13
    call jw_u64
    mov rdi, r15
    lea rsi, [rip + .Lk_character]
    call jw_key
    mov rdi, r15
    mov rsi, r14
    call jw_u64
    mov rdi, r15
    call jw_end_obj
    EPILOGUE

# FN edtool_mention(sb) -> eax 1 with sb at_mentioned's params, 0 when no file shows
FN edtool_mention
    PROLOGUE
    mov r15, rdi
    call usable_doc
    test rax, rax
    jz 8f
    mov rbx, rax
    mov rdi, r15
    call jw_begin
    mov rdi, r15
    call jw_obj
    mov rdi, r15
    lea rsi, [rip + .Lk_file_path]
    call jw_key
    mov rdi, r15
    mov rsi, [rbx + DOC_path]
    call jw_cstr
    mov r12, [rbx + DOC_cur]
    mov r13, [rbx + DOC_anchor]
    cmp r12, r13
    je 7f
    jb 1f
    xchg r12, r13
1:  mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov r12, rax
    mov rdi, rbx
    mov rsi, r13
    call doc_line_of
    mov r13, rax
    mov rdi, r15
    lea rsi, [rip + .Lk_line_start]
    call jw_key
    mov rdi, r15
    mov rsi, r12
    call jw_u64
    mov rdi, r15
    lea rsi, [rip + .Lk_line_end]
    call jw_key
    mov rdi, r15
    mov rsi, r13
    call jw_u64
7:  mov rdi, r15
    call jw_end_obj
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

.section .rodata
.Ls_name: .asciz "Claude Code rhun MCP"
.Ls_owner: .asciz "Claude Code in the terminal"
.Lt_open_diff: .asciz "openDiff"
.Ld_open_diff: .asciz "Open a git diff for the file"
.Ls_open_diff: .asciz "{\"type\":\"object\",\"properties\":{\"old_file_path\":{\"type\":\"string\",\"description\":\"Path to the file to show diff for. If not provided, uses active editor.\"},\"new_file_path\":{\"type\":\"string\",\"description\":\"Path to the file to show diff for. If not provided, uses active editor.\"},\"new_file_contents\":{\"type\":\"string\",\"description\":\"Contents of the new file. If not provided then the current file contents of new_file_path will be used.\"},\"tab_name\":{\"type\":\"string\",\"description\":\"Path to the file to show diff for. If not provided, uses active editor.\"}},\"required\":[\"old_file_path\",\"new_file_path\",\"new_file_contents\",\"tab_name\"],\"additionalProperties\":false,\"$schema\":\"http://json-schema.org/draft-07/schema#\"}"
.Lt_diag: .asciz "getDiagnostics"
.Ld_diag: .asciz "Get language diagnostics from rhun"
.Ls_diag: .asciz "{\"type\":\"object\",\"properties\":{\"uri\":{\"type\":\"string\",\"description\":\"Optional file URI to get diagnostics for. If not provided, gets diagnostics for all files.\"}},\"additionalProperties\":false,\"$schema\":\"http://json-schema.org/draft-07/schema#\"}"
.Lt_close_tab: .asciz "close_tab"
.Ls_close_tab: .asciz "{\"type\":\"object\",\"properties\":{\"tab_name\":{\"type\":\"string\"}},\"required\":[\"tab_name\"],\"additionalProperties\":false,\"$schema\":\"http://json-schema.org/draft-07/schema#\"}"
.Lt_close_all: .asciz "closeAllDiffTabs"
.Ld_close_all: .asciz "Close all diff tabs in the editor"
.Ls_close_all: .asciz "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false,\"$schema\":\"http://json-schema.org/draft-07/schema#\"}"
.Lk_old: .asciz "old_file_path"
.Lk_new: .asciz "new_file_path"
.Lk_contents: .asciz "new_file_contents"
.Lk_tab: .asciz "tab_name"
.Lk_uri: .asciz "uri"
.Lk_type: .asciz "type"
.Lk_text: .asciz "text"
.Lk_lines: .asciz "linesInFile"
.Lk_diagnostics: .asciz "diagnostics"
.Lk_message: .asciz "message"
.Lk_severity: .asciz "severity"
.Lk_range: .asciz "range"
.Lk_start: .asciz "start"
.Lk_end: .asciz "end"
.Lk_line: .asciz "line"
.Lk_character: .asciz "character"
.Lk_source: .asciz "source"
.Lk_code: .asciz "code"
.Lk_file_path: .asciz "filePath"
.Lk_file_url: .asciz "fileUrl"
.Lk_selection: .asciz "selection"
.Lk_is_empty: .asciz "isEmpty"
.Lk_line_start: .asciz "lineStart"
.Lk_line_end: .asciz "lineEnd"
.Lv_saved: .ascii "FILE_SAVED"
.Lv_saved_end:
.Lv_rejected: .ascii "DIFF_REJECTED"
.Lv_rejected_end:
.Lv_tab_closed: .asciz "TAB_CLOSED"
.Lv_closed: .asciz "CLOSED_"
.Lv_diff_tabs: .asciz "_DIFF_TABS"
.Lfile_scheme: .asciz "file://"
.Lempty: .asciz ""
.Le_args: .asciz "Invalid arguments: old_file_path, new_file_path, new_file_contents and tab_name must be strings"
.Le_big: .asciz "The new file's contents are over 4 MB"
.Le_many: .asciz "Too many diffs are waiting for the user"
.Le_refused: .asciz "The diff could not be opened"
.Le_uri: .asciz "uri must name a file"
.Ldm_diff: .asciz "diff "
.Ldm_id: .asciz " id="
.Ldm_tab: .asciz " tab="
.Lsev_error: .asciz "Error"
.Lsev_warning: .asciz "Warning"
.Lsev_info: .asciz "Information"
.Lsev_hint: .asciz "Hint"
.p2align 3
sev_names: .quad .Lsev_error, .Lsev_warning, .Lsev_info, .Lsev_hint
