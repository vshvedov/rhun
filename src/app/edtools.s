# The editor's tools for Claude Code, independent of the transport (mcpsrv.s's MT functions): the bridge for
# terminal claude (ide_server.s) serves them as the official extension's IDE server does (ext-host-ide.md
# 1.6): openDiff, getDiagnostics, close_tab, closeAllDiffTabs (executeCode is left out: design section 9).
# The chat's in-process server (phase 4) can list the same functions in a server of its own.
#
#   edtool_ms                          the bridge's server: "Claude Code rhun MCP" and the four tools
#   edtool_diagnostics(sb, path cstr or 0, min SEV_*, flags EDF_*) -> rax files    getDiagnostics' text: a
#                                      JSON array of {uri, linesInFile?, diagnostics: [{message, severity,
#                                      range, source?, code?}]}, compact or (EDF_PRETTY) as JSON.stringify(list,
#                                      null, 2); positions from 0; every file with a problem of min severity or
#                                      worse, or the one named (its entry even when it has none); EDF_PROJECT:
#                                      files of the project only
#   (phase 4) edtool_get_diagnostics   the chat server's getDiagnostics {uri?, minSeverity?} (an MT fn);
#                                      edtool_set_base, edtool_in_project, edtool_diag_gen, edtool_diag_runs;
#                                      edtool_diag_base, edtool_diag_new, edtool_diag_free (a file's problems
#                                      before an edit and the new ones after it); edtool_save, edtool_saved,
#                                      edtool_doc_where, edtool_doc_seen, edtool_lang_marked (the hooks)
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
.equ NMAX, 16384                # the store's problems a list reads at most (its own cap is 10,000)
.equ HSIZE, 32768               # the slots of the walk's table of paths (a power of two, twice NMAX)
.equ SV_MAX, 64                 # saves edtool_save began and waits for

STRUCT
F PD_token, 8           # the call's token (0: a free entry)
F PD_id, 8              # its offer
F PD_tab, 8             # tab_name (owned)
ENDSTRUCT PD_SIZE

# phase 4 task 9: an item of the list while it is made
STRUCT
F IT_l0, 8
F IT_c0, 8
F IT_l1, 8
F IT_c1, 8
F IT_sev, 8
F IT_msg, 8             # borrowed cstrs
F IT_src, 8             # or 0
F IT_code, 8            # or 0
ENDSTRUCT IT_SIZE
# phase 4 task 10: an item collected (a base's, or the file's now), its strings owned
STRUCT
F DI_l0, 4
F DI_c0, 4
F DI_l1, 4
F DI_c1, 4
F DI_sev, 4
F DI_pad, 4
F DI_msg, 8
F DI_src, 8             # or 0
F DI_code, 8            # or 0
ENDSTRUCT DI_SIZE
# a base: its header, then DB_n DI
STRUCT
F DB_n, 8
F DB_lines, 8           # linesInFile then, -1 when the file was not open
ENDSTRUCT DB_SIZE

.bss
.p2align 3
pds: .zero PD_SIZE * PD_MAX
dout: .zero SB_SIZE             # an answer's content, built here
cj: .zero SB_SIZE               # getDiagnostics' list, compact
qs: .zero SB_SIZE               # one quoted string
pbuf: .zero 4200                # a path, decoded
# phase 4 tasks 9, 10: the walk (edtool_diagnostics, edtool_diag_base, edtool_diag_new)
w_path: .quad 0                 # the one file asked for, or 0
w_files: .quad 0                # entries written
w_lines: .quad 0                # collected: the file's linesInFile, -1 when it is not open
w_min: .long 0                  # SEV_*: that and worse
w_flags: .long 0                # EDF_*
w_found: .long 0                # the file asked for has its entry
w_mode: .long 0                 # 0: JSON into cj; 1: collected into coll
last_pin: .long 0
.p2align 3
last_ppath: .quad 0             # path_wanted's last path and answer
base_dir: .quad 0               # edtool_set_base
diag_runs: .quad 0
coll: .zero VEC_SIZE            # DI
it: .zero IT_SIZE
it2: .zero IT_SIZE
nsv: .quad 0
svs: .zero 8 * SV_MAX           # DOC_ids of saves edtool_save waits for
nxt: .zero 4 * NMAX             # the next problem of the same file (-1: none)
slots: .zero 8 * HSIZE          # a path's first and last problem (index + 1 each), 0: none
pflags: .zero NMAX              # 1 listed, 3 its file's first

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
rvo: .quad offer_done, 0, .Ls_owner, RVOF_DECIDED_ENDS   # RVO: no lock; the last change decided ends it

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

# path_clean(path cstr) -> eax 1 when it is absolute and has no ".." part
path_clean:
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
5:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# path_in_folder(path cstr) -> eax 1 when it is absolute, has no ".." part and is inside a folder of the
#   window (the extension's tools read only there)
path_in_folder:
    PROLOGUE
    mov rbx, rdi
    call path_clean
    test eax, eax
    jz 8f
    mov rdi, rbx
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

# offer_done(token, OFFER_*, text ptr, len, edited) -> eax 1 (taken): the user decided: accepted (with the text
#   as it stands, the text before too: OFFER_REVERTED): FILE_SAVED and the text; otherwise DIFF_REJECTED and
#   the tab's name
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
    je 21f
    cmp r13d, OFFER_REVERTED
    jne 3f
21: lea rsi, [rip + .Lv_saved]
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
9:  mov eax, 1
    EPILOGUE

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
    mov edx, SEV_HINT
    mov ecx, EDF_PRETTY
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

# ---- Claude chat phase 4 tasks 9, 10: the diagnostics as the chat's server and its hooks ask for them ----
# The list joins the Problems store (any file, in the order its files first came; a file's problems found
# through a table of their paths, so the walk is linear in the number of problems) with the marks of open
# documents an extension set and the store does not hold (an equal one, same range, severity and whole
# message, is listed once); the store's own marks (MKF_SOURCE) are its problems and are not listed again.
# Positions from 0; a store problem's column counted in characters (PRF_CHARS) is turned to UTF-16 units
# while its file is open, a byte column is kept; a mark's position is its document's, in UTF-16 units.

# FN edtool_diagnostics(sb, path cstr or 0, min SEV_*, flags EDF_*) -> rax the files listed: the JSON array
#   appended to sb, compact or (EDF_PRETTY) as JSON.stringify(list, null, 2) writes it; only problems of
#   min severity or worse; with EDF_PROJECT only files of the project (edtool_in_project)
FN edtool_diagnostics
    PROLOGUE
    mov rbx, rdi
    mov [rip + w_path], rsi
    mov [rip + w_min], edx
    mov [rip + w_flags], ecx
    mov dword ptr [rip + w_mode], 0
    lea rdi, [rip + cj]
    call jw_begin
    lea rdi, [rip + cj]
    call jw_arr
    call walk
    lea rdi, [rip + cj]
    call jw_end_arr
    test dword ptr [rip + w_flags], EDF_PRETTY
    jz 1f
    mov rdi, rbx
    mov rsi, [rip + cj + SB_ptr]
    mov rdx, [rip + cj + SB_len]
    call pretty
    jmp 2f
1:  mov rdi, rbx
    mov rsi, [rip + cj + SB_ptr]
    mov rdx, [rip + cj + SB_len]
    call sb_push
2:  mov rax, [rip + w_files]
    EPILOGUE

# FN edtool_diag_gen() -> rax a number that moves when the Problems store or any document's marks changed
FN edtool_diag_gen
    sub rsp, 8
    call problems_gen
    mov [rsp], rax
    call extmarks_gen
    add rax, [rsp]
    add rsp, 8
    ret

# FN edtool_diag_runs() -> rax how many times the list was made (print-agent-tools: nothing is read unasked)
FN edtool_diag_runs
    mov rax, [rip + diag_runs]
    ret

# FN edtool_set_base(folder cstr or 0): the conversation's checkout while its server answers: a relative uri
#   is under it, and its files count as the project's (borrowed for the call)
FN edtool_set_base
    mov [rip + base_dir], rdi
    ret

# FN edtool_in_project(path cstr) -> eax 1 when the path is absolute, has no ".." part, and is inside a folder
#   of the window or the conversation's checkout (edtool_set_base). Judged by its spelling: a symlink is
#   not followed (a link inside the project that leads out of it counts as inside, a link outside that
#   leads in counts as outside)
FN edtool_in_project
    PROLOGUE
    mov rbx, rdi
    call path_in_folder
    test eax, eax
    jnz 9f
    mov rsi, [rip + base_dir]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call path_clean
    test eax, eax
    jz 8f
    mov rdi, rbx
    mov rsi, [rip + base_dir]
    call app_path_inside
    test eax, eax
    jz 8f
    mov eax, 1
9:  EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN edtool_get_diagnostics(args, out, token) -> MCP_OK, or MCP_ERROR with out the message: the chat
#   server's getDiagnostics {uri?, minSeverity?}: compact, files of the project only; uri a file:// URI, an
#   absolute path or a path relative to the conversation's checkout
FN edtool_get_diagnostics
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov dword ptr [rsp], SEV_HINT
    xor r13d, r13d              # the path asked for
    test rbx, rbx
    jz 5f
    mov rdi, rbx
    call json_type
    cmp eax, JT_OBJ
    jne .Lgd_args
    mov rdi, rbx
    lea rsi, [rip + .Lk_min]
    call json_get
    test rax, rax
    jz 2f
    mov r14, rax
    xor r15d, r15d
1:  cmp r15d, 4
    jae .Lgd_min
    lea rax, [rip + sev_names]
    mov rsi, [rax + r15*8]
    mov rdi, r14
    call json_is
    test eax, eax
    jnz 11f
    inc r15d
    jmp 1b
11: mov [rsp], r15d
2:  mov rdi, rbx
    lea rsi, [rip + .Lk_uri]
    call json_get
    test rax, rax
    jz 5f
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Lgd_uri
    mov rdi, rax
    mov rsi, rdx
    call chat_path
    test rax, rax
    jz .Lgd_uri
    mov r13, rax
    mov rdi, rax
    call edtool_in_project
    test eax, eax
    jz .Lgd_outside
5:  mov rdi, r12
    mov rsi, r13
    mov edx, [rsp]
    mov ecx, EDF_PROJECT
    call edtool_diagnostics
    mov eax, MCP_OK
    EPILOGUE
.Lgd_args:
    lea rsi, [rip + .Le_args_obj]
    jmp 9f
.Lgd_min:
    lea rsi, [rip + .Le_min]
    jmp 9f
.Lgd_outside:
    lea rsi, [rip + .Le_outside]
    jmp 9f
.Lgd_uri:
    lea rsi, [rip + .Le_uri]
9:  mov rdi, r12
    call sb_push_cstr
    mov eax, MCP_ERROR
    EPILOGUE

# chat_path(ptr, len) -> rax the path (pbuf) or 0: a file: URI or an absolute path (uri_path), or a path
#   relative to the conversation's checkout; any other URI (a scheme of two or more letters) is none
chat_path:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
15: cmp r12, 2                  # "./" in front: left out
    jb 16f
    cmp word ptr [rbx], 0x2f2e
    jne 16f
    add rbx, 2
    sub r12, 2
    jmp 15b
16: test r12, r12
    jz 8f
    xor ecx, ecx                # a ':' before any '/' after two or more characters: a URI's scheme
1:  cmp rcx, r12
    jae 3f
    movzx eax, byte ptr [rbx + rcx]
    cmp eax, '/'
    je 3f
    cmp eax, 92
    je 3f
    cmp eax, ':'
    je 2f
    inc rcx
    jmp 1b
2:  cmp rcx, 2
    jae 7f                      # a URI: uri_path takes only file:
3:  cmp byte ptr [rbx], '/'
    je 7f
    PATH_ABSOLUTE rbx, 7f
    # relative: under the checkout
    mov r13, [rip + base_dir]
    test r13, r13
    jz 8f
    mov rdi, r13
    call strlen
    mov r14, rax
    lea rax, [r14 + r12 + 2]
    cmp rax, 4096
    ja 8f
    lea rdi, [rip + pbuf]
    mov rsi, r13
    mov rdx, r14
    call memcpy
    lea rax, [rip + pbuf]
    mov byte ptr [rax + r14], '/'
    lea rdi, [rax + r14 + 1]
    mov rsi, rbx
    mov rdx, r12
    call memcpy
    lea rax, [rip + pbuf]
    lea rcx, [r14 + r12 + 1]
    mov byte ptr [rax + rcx], 0
    mov rdi, rax                # a NUL inside: none
    call strlen
    lea rcx, [r14 + r12 + 1]
    cmp rax, rcx
    jne 8f
    lea rax, [rip + pbuf]
    EPILOGUE
7:  mov rdi, rbx
    mov rsi, r12
    call uri_path
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- the walk ----------------

# walk(): the list of w_path / w_min / w_flags, through file_begin, item_out, file_end (w_mode: JSON into cj,
#   or collected into coll)
walk:
    PROLOGUE 16
    inc qword ptr [rip + diag_runs]
    mov qword ptr [rip + w_files], 0
    mov dword ptr [rip + w_found], 0
    mov qword ptr [rip + last_ppath], 0
    lea rdi, [rip + slots]
    xor esi, esi
    mov edx, 8 * HSIZE
    call memset
    call problems_count
    cmp rax, NMAX
    jbe 1f
    mov eax, NMAX
1:  mov r15, rax                # problems read
    xor r12d, r12d
2:  cmp r12, r15
    jae 5f
    lea rax, [rip + pflags]
    mov byte ptr [rax + r12], 0
    mov rdi, r12
    call problems_at
    mov rbx, rax
    mov eax, [rbx + PR_sev]
    cmp eax, [rip + w_min]
    ja 4f
    mov rdi, [rbx + PR_path]
    call path_wanted
    test eax, eax
    jz 4f
    mov rdi, [rbx + PR_path]
    call slot_of
    mov r13, rax
    lea rcx, [rip + nxt]
    mov dword ptr [rcx + r12*4], -1
    mov eax, [r13]
    test eax, eax
    jnz 3f
    lea eax, [r12 + 1]          # the file's first: head and tail
    mov [r13], eax
    mov [r13 + 4], eax
    lea rcx, [rip + pflags]
    mov byte ptr [rcx + r12], 3
    jmp 4f
3:  mov ecx, [r13 + 4]          # after the file's last
    dec ecx
    lea rdx, [rip + nxt]
    mov [rdx + rcx*4], r12d
    lea eax, [r12 + 1]
    mov [r13 + 4], eax
    lea rcx, [rip + pflags]
    mov byte ptr [rcx + r12], 1
4:  inc r12
    jmp 2b
5:  # the store's files, in the order their first problem came
    xor r12d, r12d
6:  cmp r12, r15
    jae 7f
    lea rax, [rip + pflags]
    cmp byte ptr [rax + r12], 3
    jne 61f
    mov rdi, r12
    call group_out
61: inc r12
    jmp 6b
7:  # open documents the store has nothing for
    xor r12d, r12d
71: cmp r12, [rip + g_tabs + VEC_len]
    jae 8f
    mov rdi, r12
    inc r12
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 71b
    mov r13, [rax + TAB_doc]
    test r13, r13
    jz 71b
    mov rdi, [r13 + DOC_path]
    test rdi, rdi
    jz 71b
    call file_open_doc          # its first tab only
    cmp rax, r13
    jne 71b
    mov rdi, [r13 + DOC_path]
    call path_wanted
    test eax, eax
    jz 71b
    mov rdi, [r13 + DOC_path]
    call slot_of
    cmp dword ptr [rax], 0
    jne 71b                     # listed with the store's
    cmp qword ptr [rip + w_path], 0
    jne 72f                     # the file asked for: its entry even when it has nothing
    mov rdi, r13
    call doc_listed
    test eax, eax
    jz 71b
72: mov rdi, [r13 + DOC_path]
    mov rsi, r13
    call file_begin
    mov rdi, r13
    mov rsi, -1
    call marks_out
    call file_end
    jmp 71b
8:  # the file asked for, with nothing anywhere and not open: its empty entry
    cmp qword ptr [rip + w_path], 0
    je 9f
    cmp dword ptr [rip + w_found], 0
    jne 9f
    mov rdi, [rip + w_path]
    xor esi, esi
    call file_begin
    call file_end
9:  EPILOGUE

# path_wanted(path) -> eax 1 when the walk lists that file (the one asked for; with EDF_PROJECT, inside)
path_wanted:
    PROLOGUE
    mov rbx, rdi
    mov rsi, [rip + w_path]
    test rsi, rsi
    jz 1f
    call strcmp_eq
    test eax, eax
    jz 8f
1:  test dword ptr [rip + w_flags], EDF_PROJECT
    jz 7f
    mov rsi, [rip + last_ppath] # a file's problems mostly come together: its answer once
    test rsi, rsi
    jz 2f
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jz 2f
    mov eax, [rip + last_pin]
    EPILOGUE
2:  mov rdi, rbx
    call edtool_in_project
    mov [rip + last_ppath], rbx
    mov [rip + last_pin], eax
    EPILOGUE
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# slot_of(path) -> rax the table's slot of that path: its head and tail (u32, a problem's index + 1), or an
#   empty one (head 0) where it goes
slot_of:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call hash_line
    and eax, HSIZE - 1
    mov r12, rax
1:  lea r13, [rip + slots]
    lea r13, [r13 + r12*8]
    mov eax, [r13]
    test eax, eax
    jz 8f
    lea rdi, [rax - 1]
    call problems_at
    mov rdi, [rax + PR_path]
    mov rsi, rbx
    call strcmp_eq
    test eax, eax
    jnz 8f
    inc r12
    and r12d, HSIZE - 1
    jmp 1b
8:  mov rax, r13
    EPILOGUE

# group_out(i): the entry of the file whose first problem is the i-th: its problems, then the marks of its
#   open document that none of them equals
group_out:
    PROLOGUE
    mov r12, rdi
    call problems_at
    mov rbx, [rax + PR_path]
    mov rdi, rbx
    call file_open_doc
    mov r13, rax
    mov rdi, rbx
    mov rsi, r13
    call file_begin
    mov r14, r12
1:  cmp r14d, -1
    je 2f
    mov rdi, r14
    call problems_at
    mov rdi, rax
    mov rsi, r13
    lea rdx, [rip + it]
    call pr_it
    call item_out
    lea rax, [rip + nxt]
    mov r14d, [rax + r14*4]
    jmp 1b
2:  test r13, r13
    jz 3f
    mov rdi, r13
    mov rsi, r12
    call marks_out
3:  call file_end
    EPILOGUE

# doc_listed(doc) -> eax 1 when it has a mark marks_out would list
doc_listed:
    PROLOGUE
    mov rbx, [rdi + DOC_xmarks]
    test rbx, rbx
    jz 8f
    xor r12d, r12d
1:  cmp r12, [rbx + VEC_len]
    jae 8f
    imul r13, r12, MK_SIZE
    add r13, [rbx + VEC_ptr]
    inc r12
    mov rdi, r13
    call mark_listed
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# mark_listed(MK*) -> eax 1 when the walk lists it: an extension's (the store's are its problems), shown,
#   of the severity asked for
mark_listed:
    xor eax, eax
    test dword ptr [rdi + MK_pad], MKF_SOURCE
    jnz 9f
    mov ecx, [rdi + MK_sev]
    cmp ecx, [rip + w_min]
    ja 9f
    jmp mark_alive
9:  ret

# marks_out(doc, group's first problem or -1): the document's listed marks that no problem of the group
#   equals
marks_out:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    xor r13d, r13d
1:  mov r12, [rbx + DOC_xmarks]
    test r12, r12
    jz 9f
    cmp r13, [r12 + VEC_len]
    jae 9f
    imul r14, r13, MK_SIZE
    add r14, [r12 + VEC_ptr]
    inc r13
    mov rdi, r14
    call mark_listed
    test eax, eax
    jz 1b
    mov rdi, rbx
    mov rsi, r14
    call mk_it
    mov rdi, [rsp]
    mov rsi, rbx
    call in_group
    test eax, eax
    jnz 1b
    call item_out
    jmp 1b
9:  EPILOGUE

# in_group(first problem or -1, doc) -> eax 1 when a problem of that file's group equals it (range,
#   severity, whole message)
in_group:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
1:  cmp r12d, -1
    je 8f
    mov rdi, r12
    call problems_at
    mov rdi, rax
    mov rsi, r13
    lea rdx, [rip + it2]
    call pr_it
    lea rax, [rip + nxt]
    mov r12d, [rax + r12*4]
    lea rbx, [rip + it]
    lea rcx, [rip + it2]
    mov rax, [rbx + IT_l0]
    cmp rax, [rcx + IT_l0]
    jne 1b
    mov rax, [rbx + IT_c0]
    cmp rax, [rcx + IT_c0]
    jne 1b
    mov rax, [rbx + IT_l1]
    cmp rax, [rcx + IT_l1]
    jne 1b
    mov rax, [rbx + IT_c1]
    cmp rax, [rcx + IT_c1]
    jne 1b
    mov rax, [rbx + IT_sev]
    cmp rax, [rcx + IT_sev]
    jne 1b
    mov rdi, [rbx + IT_msg]
    mov rsi, [rcx + IT_msg]
    call strcmp_eq
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# pr_it(PR*, doc or 0, IT*): a store problem's item
pr_it:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov eax, [rbx + PR_line]
    test eax, eax
    jz 1f
    dec eax
1:  mov [r13 + IT_l0], rax
    mov rdi, r12
    mov rsi, rax
    mov edx, [rbx + PR_col]
    mov ecx, [rbx + PR_flags]
    call col_units
    mov [r13 + IT_c0], rax
    mov rax, [r13 + IT_l0]      # a missing end is the start
    mov [r13 + IT_l1], rax
    mov rax, [r13 + IT_c0]
    mov [r13 + IT_c1], rax
    mov eax, [rbx + PR_endline]
    test eax, eax
    jz 2f
    dec eax
    mov [r13 + IT_l1], rax
    mov rdi, r12
    mov rsi, rax
    mov edx, [rbx + PR_endcol]
    mov ecx, [rbx + PR_flags]
    call col_units
    mov [r13 + IT_c1], rax
2:  mov eax, [rbx + PR_sev]
    and eax, 3
    mov [r13 + IT_sev], rax
    mov rax, [rbx + PR_msg]
    mov [r13 + IT_msg], rax
    mov rax, [rbx + PR_src]
    mov rax, [rax + PS_label]
    call nonempty
    mov [r13 + IT_src], rax
    mov rax, [rbx + PR_code]
    call nonempty
    mov [r13 + IT_code], rax
    EPILOGUE

# nonempty(rax cstr or 0) -> rax itself, or 0 when it is empty
nonempty:
    test rax, rax
    jz 1f
    cmp byte ptr [rax], 0
    jne 1f
    xor eax, eax
1:  ret

# col_units(doc or 0, line from 0, column from 1 (0 none), PRF_* flags) -> rax the column from 0: a count of
#   characters turned to UTF-16 units on the open document's line; bytes kept
col_units:
    PROLOGUE
    xor eax, eax
    test edx, edx
    jz 9f
    lea eax, [rdx - 1]
    test rdi, rdi
    jz 9f
    test ecx, PRF_CHARS
    jz 9f
    mov rbx, rdi
    mov r12, rsi
    mov r13, rax                # characters left
    cmp r12, [rbx + DOC_nlines]
    jae 9f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_end
    mov r15, rax
    mov rdi, rbx
    mov rsi, r12
    call doc_line_start
    mov r12, rax                # the position
    xor r14d, r14d              # units
1:  test r13, r13
    jz 8f
    cmp r12, r15
    jae 7f
    mov rdi, rbx
    mov rsi, r12
    call doc_byte
    dec r13
    inc r14
    mov ecx, 1
    cmp eax, 0xc0
    jb 2f
    mov ecx, 2
    cmp eax, 0xe0
    jb 2f
    mov ecx, 3
    cmp eax, 0xf0
    jb 2f
    mov ecx, 4
    inc r14                     # four bytes: a surrogate pair
2:  add r12, rcx
    jmp 1b
7:  add r14, r13                # past the line's end: one unit each
8:  mov rax, r14
9:  EPILOGUE

# mk_it(doc, MK*): a mark's item (it): its document's positions in UTF-16 units, the extension as source
mk_it:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rip + it]
    mov rdi, rbx
    mov rsi, [r12 + MK_start]
    call pos_lc
    mov [r13 + IT_l0], rax
    mov [r13 + IT_c0], rdx
    mov rdi, rbx
    mov rsi, [r12 + MK_end]
    call pos_lc
    mov [r13 + IT_l1], rax
    mov [r13 + IT_c1], rdx
    mov eax, [r12 + MK_sev]
    and eax, 3
    mov [r13 + IT_sev], rax
    mov rax, [r12 + MK_msg]
    mov [r13 + IT_msg], rax
    mov qword ptr [r13 + IT_code], 0
    xor eax, eax
    test dword ptr [r12 + MK_pad], MKF_SOURCE
    jnz 1f
    mov rdi, [r12 + MK_owner]
    call ext_full_name
    call nonempty
1:  mov [r13 + IT_src], rax
    EPILOGUE

# pos_lc(doc, pos) -> rax line, rdx character (UTF-16 units), from 0
pos_lc:
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
    mov rdx, rax
    mov rax, r13
    EPILOGUE

# file_begin(path, doc or 0): a file's entry begins: {"uri":…,"linesInFile":N,"diagnostics":[ (JSON), or the
#   file's line count (collected)
file_begin:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    inc qword ptr [rip + w_files]
    cmp qword ptr [rip + w_path], 0
    je 1f
    mov dword ptr [rip + w_found], 1
1:  cmp dword ptr [rip + w_mode], 0
    jne 5f
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    mov rsi, rbx
    call uri_member
    test r12, r12
    jz 2f
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_lines]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, [r12 + DOC_nlines]
    call jw_u64
2:  lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_diagnostics]
    call jw_key
    lea rdi, [rip + cj]
    call jw_arr
    EPILOGUE
5:  mov rax, -1
    test r12, r12
    jz 6f
    mov rax, [r12 + DOC_nlines]
6:  mov [rip + w_lines], rax
    EPILOGUE

# file_end(): the entry's end (JSON)
file_end:
    cmp dword ptr [rip + w_mode], 0
    jne 9f
    sub rsp, 8
    lea rdi, [rip + cj]
    call jw_end_arr
    lea rdi, [rip + cj]
    call jw_end_obj
    add rsp, 8
9:  ret

# item_out(): `it` as {message, severity, range, source?, code?} (JSON), or a DI in coll with its strings
#   copied (collected)
item_out:
    PROLOGUE
    lea rbx, [rip + it]
    cmp dword ptr [rip + w_mode], 0
    jne 5f
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_message]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, [rbx + IT_msg]
    call jw_cstr
    mov edi, [rbx + IT_sev]
    call sev_member
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_range]
    call jw_key
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_start]
    call jw_key
    mov rdi, [rbx + IT_l0]
    mov rsi, [rbx + IT_c0]
    call lc_obj
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_end]
    call jw_key
    mov rdi, [rbx + IT_l1]
    mov rsi, [rbx + IT_c1]
    call lc_obj
    lea rdi, [rip + cj]
    call jw_end_obj
    cmp qword ptr [rbx + IT_src], 0
    je 1f
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_source]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, [rbx + IT_src]
    call jw_cstr
1:  cmp qword ptr [rbx + IT_code], 0
    je 2f
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_code]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, [rbx + IT_code]
    call jw_cstr
2:  lea rdi, [rip + cj]
    call jw_end_obj
    EPILOGUE
5:  cmp qword ptr [rip + coll + VEC_len], NMAX * 2
    jae 9f
    lea rdi, [rip + coll]
    mov esi, DI_SIZE
    call vec_push
    mov r12, rax
    mov eax, [rbx + IT_l0]
    mov [r12 + DI_l0], eax
    mov eax, [rbx + IT_c0]
    mov [r12 + DI_c0], eax
    mov eax, [rbx + IT_l1]
    mov [r12 + DI_l1], eax
    mov eax, [rbx + IT_c1]
    mov [r12 + DI_c1], eax
    mov eax, [rbx + IT_sev]
    mov [r12 + DI_sev], eax
    mov rdi, [rbx + IT_msg]
    call cdup
    mov [r12 + DI_msg], rax
    mov rdi, [rbx + IT_src]
    call cdup
    mov [r12 + DI_src], rax
    mov rdi, [rbx + IT_code]
    call cdup
    mov [r12 + DI_code], rax
9:  EPILOGUE

# cdup(cstr or 0) -> rax an owned copy, or 0
cdup:
    test rdi, rdi
    jz 9f
    push rdi
    call strlen
    mov rsi, rax
    pop rdi
    jmp mem_dup
9:  xor eax, eax
    ret

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

# file_open_doc(path) -> rax its open text document (the first tab's), or 0
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
    test r13, r13
    jz 1b
    mov rdi, [r13 + DOC_path]
    test rdi, rdi
    jz 1b
    cmp qword ptr [r13 + DOC_diff], 0
    jne 1b
    cmp qword ptr [r13 + DOC_img], 0
    jne 1b
    mov rsi, rbx
    call strcmp_eq
    test eax, eax
    jz 1b
    mov rax, r13
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# mark_alive(MK*) -> eax 1 when its owner shows it (extmarks.s's mark_live)
mark_alive:
    test dword ptr [rdi + MK_pad], MKF_SOURCE
    jnz 1f
    mov rdi, [rdi + MK_owner]
    jmp ext_is_visible
1:  mov eax, 1
    ret

# ---------------- task 10: a baseline of one file's problems, and what is new since ----------------

# collect(path): coll holds the file's items (every severity, a file of the project only) and w_lines its
#   line count (-1: not open); the strings of what coll held before are freed
collect:
    PROLOGUE
    mov rbx, rdi
    call coll_clear
    mov qword ptr [rip + w_lines], -1
    mov [rip + w_path], rbx
    mov dword ptr [rip + w_min], SEV_HINT
    mov dword ptr [rip + w_flags], EDF_PROJECT
    mov dword ptr [rip + w_mode], 1
    call walk
    mov dword ptr [rip + w_mode], 0
    EPILOGUE

# coll_clear(): coll's strings freed, its length 0
coll_clear:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + coll + VEC_len]
    jae 2f
    imul r12, rbx, DI_SIZE
    add r12, [rip + coll + VEC_ptr]
    inc rbx
    mov rdi, [r12 + DI_msg]
    call mem_free
    mov rdi, [r12 + DI_src]
    call mem_free
    mov rdi, [r12 + DI_code]
    call mem_free
    jmp 1b
2:  mov qword ptr [rip + coll + VEC_len], 0
    EPILOGUE

# FN edtool_diag_base(path cstr) -> rax an owned base of the file's problems now (their whole messages,
#   severities, sources, codes, ranges, and the file's line count while it is open), or 0 for a file outside
#   the project; edtool_diag_new or edtool_diag_free frees it
FN edtool_diag_base
    PROLOGUE
    mov rbx, rdi
    call edtool_in_project
    test eax, eax
    jz 8f
    mov rdi, rbx
    call collect
    mov rax, [rip + coll + VEC_len]
    imul rdi, rax, DI_SIZE
    add rdi, DB_SIZE
    call mem_alloc
    mov r12, rax
    mov rax, [rip + coll + VEC_len]
    mov [r12 + DB_n], rax
    mov rax, [rip + w_lines]
    mov [r12 + DB_lines], rax
    lea rdi, [r12 + DB_SIZE]    # the items move into the base with their strings
    mov rsi, [rip + coll + VEC_ptr]
    imul rdx, [rip + coll + VEC_len], DI_SIZE
    call memcpy
    mov qword ptr [rip + coll + VEC_len], 0
    mov rax, r12
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN edtool_diag_free(base or 0)
FN edtool_diag_free
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz 9f
    xor r12d, r12d
1:  cmp r12, [rbx + DB_n]
    jae 2f
    imul r13, r12, DI_SIZE
    lea r13, [rbx + r13 + DB_SIZE]
    inc r12
    mov rdi, [r13 + DI_msg]
    call mem_free
    mov rdi, [r13 + DI_src]
    call mem_free
    mov rdi, [r13 + DI_code]
    call mem_free
    jmp 1b
2:  mov rdi, rbx
    call mem_free
9:  EPILOGUE

# FN edtool_diag_new(base or 0, path cstr, sb) -> eax the problems of the file that the base does not hold:
#   sb gets them as JSON.stringify(list, null, 2) of {filePath, line, column, message, code, severity} (line
#   and column from 1, code "" when none), nothing when there are none. Old as the extension's
#   areDiagnosticsEqual has it: the same whole message, severity, source, code, start and end column, and
#   start and end line each within D, D the difference of the file's line counts then and now (0 when
#   either is unknown). The base is freed
FN edtool_diag_new
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    xor eax, eax
    mov [rsp + 16], rax         # new ones
    mov rdi, rsi
    call edtool_in_project
    test eax, eax
    jz 9f
    mov rdi, [rsp]
    call collect
    xor eax, eax                # D
    test rbx, rbx
    jz 1f
    mov rcx, [rbx + DB_lines]
    mov rdx, [rip + w_lines]
    test rcx, rcx
    js 1f
    test rdx, rdx
    js 1f
    mov rax, rcx
    sub rax, rdx
    jns 1f
    neg rax
1:  mov [rsp + 24], rax
    lea rdi, [rip + cj]
    call jw_begin
    lea rdi, [rip + cj]
    call jw_arr
    xor r12d, r12d
2:  cmp r12, [rip + coll + VEC_len]
    jae 5f
    imul r13, r12, DI_SIZE
    add r13, [rip + coll + VEC_ptr]
    inc r12
    mov rdi, rbx
    mov rsi, r13
    mov rdx, [rsp + 24]
    call in_base
    test eax, eax
    jnz 2b
    inc qword ptr [rsp + 16]
    mov rdi, r13
    mov rsi, [rsp]
    call new_item
    jmp 2b
5:  lea rdi, [rip + cj]
    call jw_end_arr
    cmp qword ptr [rsp + 16], 0
    je 9f
    mov rdi, [rsp + 8]
    mov rsi, [rip + cj + SB_ptr]
    mov rdx, [rip + cj + SB_len]
    call pretty
9:  call coll_clear
    mov rdi, rbx
    call edtool_diag_free
    mov rax, [rsp + 16]
    EPILOGUE

# in_base(base or 0, DI*, D) -> eax 1 when the base holds one equal to it (areDiagnosticsEqual)
in_base:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r15, rdx
    test rbx, rbx
    jz 8f
    xor r13d, r13d
1:  cmp r13, [rbx + DB_n]
    jae 8f
    imul r14, r13, DI_SIZE
    lea r14, [rbx + r14 + DB_SIZE]
    inc r13
    mov eax, [r12 + DI_sev]
    cmp eax, [r14 + DI_sev]
    jne 1b
    mov eax, [r12 + DI_c0]
    cmp eax, [r14 + DI_c0]
    jne 1b
    mov eax, [r12 + DI_c1]
    cmp eax, [r14 + DI_c1]
    jne 1b
    mov eax, [r12 + DI_l0]
    sub eax, [r14 + DI_l0]
    jns 2f
    neg eax
2:  cmp rax, r15
    ja 1b
    mov eax, [r12 + DI_l1]
    sub eax, [r14 + DI_l1]
    jns 3f
    neg eax
3:  cmp rax, r15
    ja 1b
    mov rdi, [r12 + DI_msg]
    mov rsi, [r14 + DI_msg]
    call opt_eq
    test eax, eax
    jz 1b
    mov rdi, [r12 + DI_src]
    mov rsi, [r14 + DI_src]
    call opt_eq
    test eax, eax
    jz 1b
    mov rdi, [r12 + DI_code]
    mov rsi, [r14 + DI_code]
    call opt_eq
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# opt_eq(cstr or 0, cstr or 0) -> eax 1 when both are none or the same text
opt_eq:
    test rdi, rdi
    jz 1f
    test rsi, rsi
    jz 8f
    jmp strcmp_eq
1:  xor eax, eax
    test rsi, rsi
    sete al
    ret
8:  xor eax, eax
    ret

# new_item(DI*, path): cj gets {"filePath":P,"line":L,"column":C,"message":M,"code":K,"severity":S}
new_item:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + cj]
    call jw_obj
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_file_path]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, r12
    call jw_cstr
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_line]
    call jw_key
    lea rdi, [rip + cj]
    mov esi, [rbx + DI_l0]
    inc rsi
    call jw_u64
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_column]
    call jw_key
    lea rdi, [rip + cj]
    mov esi, [rbx + DI_c0]
    inc rsi
    call jw_u64
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_message]
    call jw_key
    lea rdi, [rip + cj]
    mov rsi, [rbx + DI_msg]
    call jw_cstr
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_code]
    call jw_key
    mov rsi, [rbx + DI_code]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lempty]
1:  lea rdi, [rip + cj]
    call jw_cstr
    lea rdi, [rip + cj]
    lea rsi, [rip + .Lk_severity]
    call jw_key
    mov eax, [rbx + DI_sev]
    and eax, 3
    lea rcx, [rip + sev_names]
    mov rsi, [rcx + rax*8]
    lea rdi, [rip + cj]
    call jw_cstr
    lea rdi, [rip + cj]
    call jw_end_obj
    EPILOGUE

# ---------------- task 10: an open file, its state, saving it ----------------

# FN edtool_doc_where(path) -> eax 0 not open, 1 open, 2 open in the active tab
FN edtool_doc_where
    PROLOGUE
    call file_open_doc
    test rax, rax
    jz 9f
    mov ecx, 1
    cmp rax, [rip + g_doc]
    jne 1f
    mov ecx, 2
1:  mov eax, ecx
9:  EPILOGUE

# FN edtool_doc_seen(path) -> rax a number that changes when the open document's text changes (an edit, a
#   reload from disk), 0 when it is not open
FN edtool_doc_seen
    PROLOGUE
    call file_open_doc
    test rax, rax
    jz 9f
    mov rcx, [rax + DOC_version]
    mov rdx, 0x9e3779b97f4a7c15
    imul rcx, rdx
    xor rcx, [rax + DOC_mtime]
    or rcx, 1
    mov rax, rcx
9:  EPILOGUE

# FN edtool_lang_marked(path) -> eax 1 when the file is open and a document of its language ever had marks
#   in this window (an extension checks that language: waiting for its problems is worth it)
FN edtool_lang_marked
    PROLOGUE
    call file_open_doc
    test rax, rax
    jz 9f
    mov rdi, rax
    call extmarks_lang_marked
9:  EPILOGUE

# FN edtool_save(path) -> eax EDS_NOTOPEN (no document of it is open), EDS_CLEAN (nothing unsaved), EDS_SAVING
#   (its save began: ask edtool_saved), EDS_FAILED (read-only, changed on disk since it was read: a save that
#   would ask the user something is not begun, or the save failed). The save is the user's own (format on
#   save and the save actions run as for Ctrl+S)
FN edtool_save
    PROLOGUE
    call file_open_doc
    test rax, rax
    jz 7f
    mov rbx, rax
    mov rdi, rbx
    call doc_dirty
    test eax, eax
    jz 6f
    test dword ptr [rbx + DOC_flags], DF_READONLY | DF_DISK_CHANGED
    jnz 8f
    mov rdi, rbx
    call doc_readonly
    test eax, eax
    jnz 8f
    mov rdi, [rbx + DOC_id]     # a save of it that edtool_save began already: waited for once
    call sv_find
    test rax, rax
    jns 4f
    cmp qword ptr [rip + nsv], SV_MAX
    jae 8f
    mov rdi, rbx
    xor esi, esi
    lea rdx, [rip + save_done]
    mov rcx, [rbx + DOC_id]
    call app_save_start
    test rax, rax
    js 8f
    cmp rax, 1
    jne 5f
    mov rcx, [rip + nsv]        # waits: kept until its callback
    lea rdx, [rip + svs]
    mov rax, [rbx + DOC_id]
    mov [rdx + rcx*8], rax
    inc qword ptr [rip + nsv]
4:  mov eax, EDS_SAVING
    EPILOGUE
5:  mov rdi, rbx                # done at once
    call doc_dirty
    test eax, eax
    jnz 8f
6:  mov eax, EDS_CLEAN
    EPILOGUE
7:  mov eax, EDS_NOTOPEN
    EPILOGUE
8:  mov eax, EDS_FAILED
    EPILOGUE

# sv_find(doc id) -> rax its index in svs, or -1
sv_find:
    xor ecx, ecx
1:  cmp rcx, [rip + nsv]
    jae 8f
    lea rdx, [rip + svs]
    cmp [rdx + rcx*8], rdi
    je 9f
    inc rcx
    jmp 1b
8:  mov rcx, -1
9:  mov rax, rcx
    ret

# save_done(doc id, arg, result): a save edtool_save began ended: no longer waited for
save_done:
    xor ecx, ecx
1:  cmp rcx, [rip + nsv]
    jae 9f
    lea rdx, [rip + svs]
    cmp [rdx + rcx*8], rsi
    je 2f
    inc rcx
    jmp 1b
2:  mov rax, [rip + nsv]
    dec rax
    mov [rip + nsv], rax
    mov r8, [rdx + rax*8]
    mov [rdx + rcx*8], r8
    mov dword ptr [rip + g_dirty], 1    # a frame: whoever waits for it asks again
9:  ret

# FN edtool_saved(path) -> eax EDS_*: the save edtool_save began, asked again: EDS_SAVING while it runs
FN edtool_saved
    PROLOGUE
    call file_open_doc
    test rax, rax
    jz 7f
    mov rbx, rax
    mov rdi, rbx
    call doc_dirty
    test eax, eax
    jz 6f
    mov rdi, [rbx + DOC_id]
    call sv_find
    test rax, rax
    js 8f
    mov eax, EDS_SAVING
    EPILOGUE
6:  mov eax, EDS_CLEAN
    EPILOGUE
7:  mov eax, EDS_NOTOPEN
    EPILOGUE
8:  mov eax, EDS_FAILED
    EPILOGUE
# ---- end ----

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
.Le_outside: .asciz "uri must name a file in the project's folders"
.Le_args_obj: .asciz "The arguments must be an object"
.Le_min: .asciz "minSeverity must be Error, Warning, Information or Hint"
.Lk_min: .asciz "minSeverity"
.Lk_column: .asciz "column"
.Ldm_diff: .asciz "diff "
.Ldm_id: .asciz " id="
.Ldm_tab: .asciz " tab="
.Lsev_error: .asciz "Error"
.Lsev_warning: .asciz "Warning"
.Lsev_info: .asciz "Information"
.Lsev_hint: .asciz "Hint"
.p2align 3
sev_names: .quad .Lsev_error, .Lsev_warning, .Lsev_info, .Lsev_hint
