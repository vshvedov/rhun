# edit proposals and the Review tab (wider-parity D2, D2b): an extension proposes a workspace edit
# (feature edit-review, or the rhun.propose tool); rhun checks it as apply would, keeps each file's
# text before and after, and shows a Review tab: a read-only diff view (diffview.s draws its lines)
# with every file's hunks. The user accepts or rejects a file, a hunk or everything; an accepted
# change goes through ws_apply as one undo step, unsaved. A file that changed since it was proposed
# can only be rejected. The proposer hears what became of each file.
#
# An offer (review_offer) is a proposal of one file made by rhun itself (RVP_ext 0) for an owner (RVO): the
# bridge for terminal claude's openDiff (ide_server.s, edtools.s). Deciding it applies nothing: the owner's
# RVO_done hears once whether the text was accepted (the text before with the accepted changes) or rejected,
# or that the tab closed. Its tab opens without taking the keys.
.include "rhun.inc"

.equ RVP_PENDING_MAX, 8          # proposals of one extension not decided yet
.equ RVP_FILES_MAX, 1000
.equ RVP_EDITS_MAX, 100000
.equ RVP_TEXT_MAX, 4194304       # a file's text before or after
.equ RVP_LABEL_MAX, 200
.equ RVP_CONTEXT, 3              # lines shown around a change
.equ RVP_DMAX, 1000              # beyond this many differences a file is one change

.equ RVS_PENDING, 0
.equ RVS_ACCEPTED, 1
.equ RVS_REJECTED, 2
.equ RVS_STALE, 3                # changed since it was proposed: not applied
.equ RVS_PARTIAL, 4              # some hunks accepted, the others not

# a proposal
STRUCT
F RVP_id, 8
F RVP_ext, 8             # the extension that proposed it
F RVP_label, 8           # cstr
F RVP_sid, 8             # cstr, the agent session it came from, or 0
F RVP_files, VEC_SIZE    # RF records
F RVP_doc, 8             # its Review tab's document, 0 once closed
F RVP_events, 4          # 1: the proposer hears 0 proposal events (feature edit-review)
F RVP_done, 4            # every file decided
F RVP_gone, 4            # withdrawn: nothing more is said
F RVP_pad, 4
F RVP_waiter, 8          # tools.s: the rhun.propose call answered when it is done, or 0
# phase 4 tasks 11 and 12: an offer (review_offer): a proposal of rhun's own for an owner (an agent's request)
F RVP_offer, 4           # 1: an offer: RVP_ext 0, one file, accepting applies nothing (its owner hears it)
F RVP_pend, 4            # its outcome (OFFER_*) waiting for review_tick, 0 none
F RVP_owner, 8           # RVO*, 0 once the owner withdrew it (nothing more is said)
F RVP_ctx, 8
F RVP_orig, 8            # the proposed text as offered (owned) and its length: what "edited" compares with
F RVP_origlen, 8
F RVP_scratch, 8         # task 12: its "Edit Proposed Text" document's DOC_id, 0 none
F RVP_sver, 8            #   that document's version last seen, when its text was last taken (time_ms),
F RVP_sat, 8             #   when it is to be taken again (time_ms, 0 none), and its name (owned: the
F RVP_sdue, 8            #   document's DOC_name points at it; freed once the document is gone)
F RVP_sname, 8
ENDSTRUCT RVP_SIZE
.equ TMENU_KEEP, 24               # a tab menu's items kept before the five
.equ SCRATCH_MS, 100             # an edited proposed text is taken at most this often (wsdifftab.s's 100 ms)
.equ OFFER_HUNKS_MAX, 100        # an offer of more changes is one change (the extension's EVt)

# a file of a proposal
STRUCT
F RVF_index, 8           # its group's place in the edit, from 1
F RVF_path, 8            # cstr: the file, or 0 for an untitled document
F RVF_name, 8            # cstr: as the tab shows it
F RVF_docid, 8           # the open document it was proposed against, or 0
F RVF_old, 8             # its text before (owned) and after
F RVF_oldlen, 8
F RVF_new, 8
F RVF_newlen, 8
F RVF_ostart, 8          # line starts of both (owned): n + 1 entries, the last the length
F RVF_on, 8
F RVF_nstart, 8
F RVF_nn, 8
F RVF_hunks, VEC_SIZE    # RH records
F RVF_state, 4           # RVS_*
F RVF_line, 4            # its header's line in the Review document
F RVF_add, 4             # lines added and removed
F RVF_del, 4
ENDSTRUCT RVF_SIZE

# a hunk: old lines [ol, ol + oc) become new lines [nl, nl + nc) (0-based)
STRUCT
F RVH_ol, 8
F RVH_oc, 8
F RVH_nl, 8
F RVH_nc, 8
F RVH_state, 4           # RVS_PENDING, RVS_ACCEPTED, RVS_REJECTED, RVS_STALE
F RVH_line, 4            # its header's line in the Review document
ENDSTRUCT RVH_SIZE

# parsing: a group and an edit as read
STRUCT
F RVG_path, 8
F RVG_plen, 8
F RVG_version, 8         # -1 for -
F RVG_first, 8
F RVG_count, 8
ENDSTRUCT RVG_SIZE
STRUCT
F RVE_l1, 8
F RVE_c1, 8
F RVE_l2, 8
F RVE_c2, 8
F RVE_text, 8
F RVE_len, 8
F RVE_start, 8
F RVE_end, 8
ENDSTRUCT RVE_SIZE

.bss
.p2align 3
proposals: .zero VEC_SIZE       # RV*
next_id: .quad 0
pg: .zero VEC_SIZE
pe: .zero VEC_SIZE
sorted: .zero VEC_SIZE          # PE* of one group, by start
sort_tmp: .zero VEC_SIZE
cur_ext: .quad 0
err: .quad 0                    # the error reply's "CODE TEXT" of a failed check
path_buf: .zero 4104
text: .zero SB_SIZE
dls: .zero VEC_SIZE
line: .zero SB_SIZE
scratch: .zero SB_SIZE
ha: .quad 0                     # line hashes of the old and new text, and the flags of the diff
hb: .quad 0
fdel: .quad 0
fadd: .quad 0
vbuf: .quad 0                   # Myers: V, and V after each step
trace: .quad 0
tcap: .quad 0
maxno: .long 0
.p2align 3

.text

# ---------------- proposing ----------------

# FN review_propose(ext, body, len, events) -> rax 0 with rdx the proposal's id, or rax the error
#   reply's "CODE TEXT". The body: LABEL_LEN SID_LEN LF, the label and session id, then a workspace
#   edit (12g), checked as apply checks it. events: the proposer hears 0 proposal events.
FN review_propose
    PROLOGUE 64
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov [rsp + 24], ecx
    mov [rip + cur_ext], rdi
    call ai_ext
    mov [rsp + 32], rax
    cmp dword ptr [rax + AX_proposals], RVP_PENDING_MAX
    jae .Lrp_many
    mov qword ptr [rip + pg + VEC_len], 0
    mov qword ptr [rip + pe + VEC_len], 0
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call ai_rd_init
    call ai_rd_num
    test edx, edx
    jz .Lrp_syntax
    mov r12, rax                # label length
    call ai_rd_num
    test edx, edx
    jz .Lrp_syntax
    mov r13, rax                # session id length
    call ai_rd_eol
    test eax, eax
    jz .Lrp_syntax
    cmp r12, 4096
    ja .Lrp_syntax
    mov rdi, r12
    call ai_rd_take
    test rax, rax
    jz .Lrp_syntax
    mov [rsp + 40], rax
    mov rdi, r13
    call ai_rd_take
    test rax, rax
    jz .Lrp_syntax
    mov [rsp + 48], rax
    test r13, r13
    jz 1f
    mov rdi, rax
    mov rsi, r13
    mov edx, 128
    call ai_word_ok
    test eax, eax
    jz .Lrp_syntax
1:  # the workspace edit: N, then per file PATH_LEN VERSION M and the path, then M edits
    call ai_rd_num
    test edx, edx
    jz .Lrp_syntax
    mov r14, rax
    call ai_rd_eol
    test eax, eax
    jz .Lrp_syntax
    cmp r14, RVP_FILES_MAX
    ja .Lrp_big
.Lrp_group:
    test r14, r14
    jz .Lrp_read
    dec r14
    lea rdi, [rip + pg]
    mov esi, RVG_SIZE
    call vec_push
    mov rbx, rax
    call ai_rd_num
    test edx, edx
    jz .Lrp_syntax
    test rax, rax
    jz .Lrp_syntax
    cmp rax, 4096
    ja .Lrp_syntax
    mov [rbx + RVG_plen], rax
    call ai_rd_word
    mov qword ptr [rbx + RVG_version], -1
    cmp rdx, 1
    jne 2f
    cmp byte ptr [rax], '-'
    je 3f
2:  test rdx, rdx
    jz .Lrp_syntax
    cmp rdx, 18
    ja .Lrp_syntax
    mov r15, rdx
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    cmp rdx, r15
    jne .Lrp_syntax
    mov [rbx + RVG_version], rax
3:  call ai_rd_num
    test edx, edx
    jz .Lrp_syntax
    mov [rbx + RVG_count], rax
    mov rcx, [rip + pe + VEC_len]
    mov [rbx + RVG_first], rcx
    add rcx, rax
    cmp rcx, RVP_EDITS_MAX
    ja .Lrp_big
    call ai_rd_eol
    test eax, eax
    jz .Lrp_syntax
    mov rdi, [rbx + RVG_plen]
    call ai_rd_take
    test rax, rax
    jz .Lrp_syntax
    mov [rbx + RVG_path], rax
    mov r15, [rbx + RVG_count]
4:  test r15, r15
    jz .Lrp_group
    dec r15
    lea rdi, [rip + pe]
    mov esi, RVE_SIZE
    call vec_push
    mov rbx, rax
    call ai_rd_num
    test edx, edx
    jz .Lrp_syntax
    mov [rbx + RVE_l1], rax
    call ai_rd_num
    test edx, edx
    jz .Lrp_syntax
    mov [rbx + RVE_c1], rax
    call ai_rd_num
    test edx, edx
    jz .Lrp_syntax
    mov [rbx + RVE_l2], rax
    call ai_rd_num
    test edx, edx
    jz .Lrp_syntax
    mov [rbx + RVE_c2], rax
    call ai_rd_num
    test edx, edx
    jz .Lrp_syntax
    mov [rbx + RVE_len], rax
    call ai_rd_eol
    test eax, eax
    jz .Lrp_syntax
    mov rdi, [rbx + RVE_len]
    call ai_rd_take
    test rax, rax
    jz .Lrp_syntax
    mov [rbx + RVE_text], rax
    jmp 4b
.Lrp_read:
    call ai_rd_done
    test eax, eax
    jz .Lrp_syntax
    # the proposal, and each file's text before and after
    mov edi, RVP_SIZE
    call mem_alloc
    mov r15, rax
    mov rax, [rsp]
    mov [r15 + RVP_ext], rax
    mov eax, [rsp + 24]
    mov [r15 + RVP_events], eax
    mov rdi, [rsp + 40]
    mov rsi, r12
    call clean_label
    mov [r15 + RVP_label], rax
    test r13, r13
    jz 5f
    mov rdi, [rsp + 48]
    mov rsi, r13
    call ai_dup
    mov [r15 + RVP_sid], rax
5:  xor ebx, ebx
6:  cmp rbx, [rip + pg + VEC_len]
    jae 7f
    imul rdi, rbx, RVG_SIZE
    add rdi, [rip + pg + VEC_ptr]
    inc rbx
    mov rsi, rbx
    mov rdx, r15
    call group_file
    test rax, rax
    jnz .Lrp_fail
    jmp 6b
7:  # a file named twice, by its document and by its path, would get two sets of edits
    mov rdi, r15
    call twice
    test eax, eax
    jnz .Lrp_twice
    cmp qword ptr [r15 + RVP_files + VEC_len], 0
    je .Lrp_nothing
    inc qword ptr [rip + next_id]
    mov rax, [rip + next_id]
    mov [r15 + RVP_id], rax
    lea rdi, [rip + proposals]
    mov esi, 8
    call vec_push
    mov [rax], r15
    mov rax, [rsp + 32]
    inc dword ptr [rax + AX_proposals]
    mov rdi, r15
    call open_tab
    xor eax, eax
    mov rdx, [r15 + RVP_id]
    EPILOGUE
.Lrp_twice:
    lea rax, [rip + .Le_twice]
    mov [rip + err], rax
    jmp .Lrp_fail
.Lrp_nothing:
    lea rax, [rip + .Le_nothing]
    mov [rip + err], rax
.Lrp_fail:
    mov rdi, r15
    call proposal_free
    mov rax, [rip + err]
    EPILOGUE
.Lrp_many:
    lea rax, [rip + .Le_many]
    EPILOGUE
.Lrp_big:
    lea rax, [rip + .Le_big]
    EPILOGUE
.Lrp_syntax:
    lea rax, [rip + .Le_syntax]
    EPILOGUE

# clean_label(ptr, len) -> a cstr: the first line, cut to RVP_LABEL_MAX, controls as spaces
clean_label:
    PROLOGUE
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 2f
    cmp byte ptr [rdi + rcx], 10
    je 2f
    inc rcx
    jmp 1b
2:  mov rsi, rcx
    mov edx, RVP_LABEL_MAX
    call ai_cut
    mov rdi, rax
    mov rsi, rdx
    call ai_dup
    mov rbx, rax
    mov rcx, rax
3:  movzx edx, byte ptr [rcx]
    test edx, edx
    jz 9f
    cmp edx, 32
    jae 4f
    mov byte ptr [rcx], ' '
4:  inc rcx
    jmp 3b
9:  mov rax, rbx
    EPILOGUE

# twice(RV*) -> eax 1 when two files are one document or one path
twice:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + RVP_files + VEC_len]
    jae 8f
    imul r13, r12, RVF_SIZE
    add r13, [rbx + RVP_files + VEC_ptr]
    xor r14d, r14d
2:  cmp r14, r12
    jae 7f
    imul r15, r14, RVF_SIZE
    add r15, [rbx + RVP_files + VEC_ptr]
    inc r14
    mov rax, [r13 + RVF_docid]
    test rax, rax
    jz 3f
    cmp rax, [r15 + RVF_docid]
    je 9f
3:  mov rdi, [r13 + RVF_path]
    test rdi, rdi
    jz 2b
    mov rsi, [r15 + RVF_path]
    test rsi, rsi
    jz 2b
    call strcmp_eq
    test eax, eax
    jnz 9f
    jmp 2b
7:  inc r12
    jmp 1b
8:  xor eax, eax
    EPILOGUE
9:  mov eax, 1
    EPILOGUE

# group_file(PG*, index, RV*) -> rax 0 with an RF added to the proposal (none when the edits change
#   nothing), or the error reply (also in err)
group_file:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    # the path as a cstr
    mov rcx, [rbx + RVG_plen]
    mov rsi, [rbx + RVG_path]
    lea rdi, [rip + path_buf]
    xor eax, eax
1:  cmp rax, rcx
    jae 2f
    movzx edx, byte ptr [rsi + rax]
    test edx, edx
    jz .Lgf_syntax
    mov [rdi + rax], dl
    inc rax
    jmp 1b
2:  mov byte ptr [rdi + rax], 0
    lea rdi, [rip + .Lrf_tmp]
    mov ecx, RVF_SIZE
    xor eax, eax
    rep stosb
    lea r12, [rip + .Lrf_tmp]
    mov rax, [rsp]
    mov [r12 + RVF_index], rax
    xor r13d, r13d              # the document, when it is open
    lea rdi, [rip + path_buf]
    cmp byte ptr [rdi], '#'
    jne 3f
    # #DOC names an open document
    inc rdi
    call strlen
    lea rdi, [rip + path_buf + 1]
    mov rsi, rax
    mov r14, rax
    test rax, rax
    jz .Lgf_syntax
    call parse_u64
    cmp rdx, r14
    jne .Lgf_syntax
    mov rdi, rax
    call extproto_doc
    test rax, rax
    jz .Lgf_nodoc
    mov r13, rax
    jmp .Lgf_doc
3:  PATH_ABSOLUTE rdi, 4f
    jmp .Lgf_nofile
4:  lea rdi, [rip + path_buf]
    call open_doc_at
    test rax, rax
    js .Lgf_nofile
    jnz 41f
    # not open: a readable text file the extension may read
    lea rdi, [rip + path_buf]
    call vfs_type
    cmp eax, 0x8000
    jne .Lgf_nofile
    mov rdi, [rip + cur_ext]
    lea rsi, [rip + path_buf]
    call ext_open_path
    test rax, rax
    jz .Lgf_needs
    mov r14, rax
    mov rdi, rax
    call open_doc_at
    test rax, rax
    jz 42f
    mov r13, rax
    mov rdi, r14
    call mem_free
    test r13, r13
    js .Lgf_nofile
    jmp .Lgf_doc
41: mov r13, rax
    jmp .Lgf_doc
42: mov [r12 + RVF_path], r14
    mov rdi, r14
    call read_text
    test rax, rax
    jz .Lgf_unreadable
    mov [r12 + RVF_old], rax
    mov [r12 + RVF_oldlen], rdx
    cmp qword ptr [rbx + RVG_version], -1
    jne .Lgf_stale              # made for a document that is closed now
    mov rdi, r14
    call path_basename_c
    mov [r12 + RVF_name], rax
    jmp .Lgf_edits
.Lgf_doc:
    test dword ptr [r13 + DOC_flags], DF_READONLY
    jnz .Lgf_readonly
    mov rax, [rbx + RVG_version]
    cmp rax, -1
    jne 5f
    mov rdi, r13                # made from the file: right while it has no unsaved changes
    call doc_dirty
    test eax, eax
    jnz .Lgf_stale
    jmp 6f
5:  cmp rax, [r13 + DOC_version]
    jne .Lgf_stale
6:  mov rax, [r13 + DOC_id]
    mov [r12 + RVF_docid], rax
    mov rdi, [r13 + DOC_path]
    test rdi, rdi
    jz 7f
    call dup_cstr
    mov [r12 + RVF_path], rax
7:  mov rdi, [r13 + DOC_name]
    call dup_cstr
    mov [r12 + RVF_name], rax
    mov rdi, r13
    call doc_text_copy
    mov [r12 + RVF_old], rax
    mov [r12 + RVF_oldlen], rdx
.Lgf_edits:
    mov rdi, rbx
    mov rsi, r12
    call apply_edits
    test rax, rax
    jnz .Lgf_out
    # an edit that changes nothing proposes nothing for this file
    mov rax, [r12 + RVF_oldlen]
    cmp rax, [r12 + RVF_newlen]
    jne 8f
    mov rdi, [r12 + RVF_old]
    mov rsi, [r12 + RVF_new]
    mov rdx, rax
    call memeq
    test eax, eax
    jz 8f
    mov rdi, r12
    call file_free
    xor eax, eax
    EPILOGUE
8:  mov rdi, r12
    call file_diff
    mov rbx, [rsp + 8]
    lea rdi, [rbx + RVP_files]
    mov esi, RVF_SIZE
    call vec_push
    mov rdi, rax
    mov rsi, r12
    mov edx, RVF_SIZE
    call memcpy
    xor eax, eax
    EPILOGUE
.Lgf_syntax:
    lea rax, [rip + .Le_syntax]
    jmp .Lgf_err
.Lgf_nodoc:
    lea rax, [rip + .Le_nodoc]
    jmp .Lgf_err
.Lgf_nofile:
    lea rax, [rip + .Le_nofile]
    jmp .Lgf_err
.Lgf_unreadable:
    lea rax, [rip + .Le_unreadable]
    jmp .Lgf_err
.Lgf_needs:
    lea rax, [rip + .Le_needs]
    jmp .Lgf_err
.Lgf_readonly:
    lea rax, [rip + .Le_readonly]
    jmp .Lgf_err
.Lgf_stale:
    lea rax, [rip + .Le_stale]
.Lgf_err:
    mov [rip + err], rax
    mov rdi, r12
    call file_free
    mov rax, [rip + err]
    EPILOGUE
.Lgf_out:
    mov [rip + err], rax
    push rax
    push rax
    mov rdi, r12
    call file_free
    pop rax
    pop rax
    EPILOGUE

# open_doc_at(path) -> rax the open document with that path, 0 when none, -1 when its tab is not a
#   text document (an image)
open_doc_at:
    PROLOGUE
    call app_find_tab
    test rax, rax
    js 8f
    mov rdi, rax
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 7f
    mov rax, [rax + TAB_doc]
    EPILOGUE
7:  mov rax, -1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# path_basename_c(path) -> its last part as a cstr (mem_alloc'd)
path_basename_c:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call path_basename
    mov rdi, rax
    mov rsi, rdx
    call ai_dup
    EPILOGUE

# FN doc_text_copy(doc) -> rax its text (mem_alloc'd, NUL after it), rdx length
FN doc_text_copy
    PROLOGUE
    mov rbx, rdi
    call doc_len
    mov r12, rax
    lea rdi, [rax + 1]
    call mem_alloc
    mov r13, rax
    mov rdi, rbx
    xor esi, esi
    mov rdx, r12
    mov rcx, r13
    call doc_copy
    mov byte ptr [r13 + r12], 0
    mov rax, r13
    mov rdx, r12
    EPILOGUE

# FN review_read_text(path): read_text, for the tools
FN review_read_text
    jmp read_text

# read_text(path) -> rax the file's text as rhun keeps it (CR before LF gone), rdx length; rax 0 when
#   it cannot be read, is over 4 MB or holds a NUL
read_text:
    PROLOGUE
    mov esi, RVP_TEXT_MAX
    call vfs_read_limited
    test rax, rax
    jz 9f
    mov rbx, rax
    mov r12, rdx
    xor ecx, ecx                # read
    xor edx, edx                # written
1:  cmp rcx, r12
    jae 3f
    movzx eax, byte ptr [rbx + rcx]
    test eax, eax
    jz 8f
    cmp eax, 13
    jne 2f
    lea r8, [rcx + 1]
    cmp r8, r12
    jae 2f
    cmp byte ptr [rbx + r8], 10
    jne 2f
    inc rcx                     # CR LF: the LF alone
    jmp 1b
2:  mov [rbx + rdx], al
    inc rcx
    inc rdx
    jmp 1b
3:  mov byte ptr [rbx + rdx], 0
    mov rax, rbx
    EPILOGUE
8:  mov rdi, rbx
    call mem_free
    xor eax, eax
9:  EPILOGUE

# line_starts(text, len, *n) -> rax n + 1 offsets (mem_alloc'd): where each line starts, the last the
#   length; a line ends after its LF, and the text after the last LF (if any) is a line
line_starts:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor ecx, ecx
    xor r14d, r14d
1:  cmp rcx, r12
    jae 2f
    cmp byte ptr [rbx + rcx], 10
    jne 11f
    inc r14
11: inc rcx
    jmp 1b
2:  test r12, r12
    jz 3f
    cmp byte ptr [rbx + r12 - 1], 10
    je 3f
    inc r14
3:  mov [r13], r14
    lea rdi, [r14*8 + 8]
    call mem_alloc
    mov r15, rax
    xor ecx, ecx                # line
    xor edx, edx                # offset
    test r14, r14
    jz 6f
    mov qword ptr [r15], 0
    mov ecx, 1
4:  cmp rdx, r12
    jae 6f
    cmp byte ptr [rbx + rdx], 10
    jne 5f
    lea rax, [rdx + 1]
    cmp rcx, r14
    jae 6f
    mov [r15 + rcx*8], rax
    inc rcx
5:  inc rdx
    jmp 4b
6:  mov [r15 + r14*8], r12
    mov rax, r15
    EPILOGUE

# apply_edits(PG*, RF*) -> rax 0 with RVF_new made from RVF_old and the group's edits, or the error
apply_edits:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov qword ptr [rip + sorted + VEC_len], 0
    xor r13d, r13d
1:  cmp r13, [rbx + RVG_count]
    jae 2f
    mov r14, [rbx + RVG_first]
    add r14, r13
    imul r14, r14, RVE_SIZE
    add r14, [rip + pe + VEC_ptr]
    inc r13
    mov rdi, [r12 + RVF_old]
    mov rsi, [r12 + RVF_oldlen]
    mov rdx, [r14 + RVE_l1]
    mov rcx, [r14 + RVE_c1]
    call lc_off_fast
    test rax, rax
    js .Lae_badpos
    mov [r14 + RVE_start], rax
    mov rdi, [r12 + RVF_old]
    mov rsi, [r12 + RVF_oldlen]
    mov rdx, [r14 + RVE_l2]
    mov rcx, [r14 + RVE_c2]
    call lc_off_fast
    test rax, rax
    js .Lae_badpos
    mov [r14 + RVE_end], rax
    cmp rax, [r14 + RVE_start]
    jb .Lae_badpos
    lea rdi, [rip + sorted]
    mov esi, 8
    call vec_push
    mov [rax], r14
    jmp 1b
2:  call sort_edits
    # none over the one before
    mov r13, 1
3:  cmp r13, [rip + sorted + VEC_len]
    jae 4f
    mov rax, [rip + sorted + VEC_ptr]
    mov rcx, [rax + r13*8 - 8]
    mov rdx, [rax + r13*8]
    mov rcx, [rcx + RVE_end]
    cmp rcx, [rdx + RVE_start]
    ja .Lae_overlap
    inc r13
    jmp 3b
4:  # the text after
    lea rdi, [rip + scratch]
    call sb_clear
    xor r15d, r15d              # copied up to
    xor r13d, r13d
5:  cmp r13, [rip + sorted + VEC_len]
    jae 6f
    mov rax, [rip + sorted + VEC_ptr]
    mov r14, [rax + r13*8]
    inc r13
    lea rdi, [rip + scratch]
    mov rsi, [r12 + RVF_old]
    add rsi, r15
    mov rdx, [r14 + RVE_start]
    sub rdx, r15
    call sb_push
    lea rdi, [rip + scratch]
    mov rsi, [r14 + RVE_text]
    mov rdx, [r14 + RVE_len]
    call sb_push
    mov r15, [r14 + RVE_end]
    cmp qword ptr [rip + scratch + SB_len], RVP_TEXT_MAX
    ja .Lae_big
    jmp 5b
6:  lea rdi, [rip + scratch]
    mov rsi, [r12 + RVF_old]
    add rsi, r15
    mov rdx, [r12 + RVF_oldlen]
    sub rdx, r15
    call sb_push
    cmp qword ptr [rip + scratch + SB_len], RVP_TEXT_MAX
    ja .Lae_big
    mov rdi, [rip + scratch + SB_ptr]
    mov rsi, [rip + scratch + SB_len]
    call ai_dup
    mov [r12 + RVF_new], rax
    mov rax, [rip + scratch + SB_len]
    mov [r12 + RVF_newlen], rax
    xor eax, eax
    EPILOGUE
.Lae_badpos:
    lea rax, [rip + .Le_badpos]
    EPILOGUE
.Lae_overlap:
    lea rax, [rip + .Le_overlap]
    EPILOGUE
.Lae_big:
    lea rax, [rip + .Le_big]
    EPILOGUE

# lc_off_fast: lc_off through the file's line starts, made the first time a group needs them (r12 RF)
lc_off_fast:
    PROLOGUE 16
    mov rbx, rdx
    mov r13, rcx
    cmp qword ptr [r12 + RVF_ostart], 0
    jne 1f
    mov rdi, [r12 + RVF_old]
    mov rsi, [r12 + RVF_oldlen]
    lea rdx, [r12 + RVF_on]
    call line_starts
    mov [r12 + RVF_ostart], rax
1:  # protocol lines: one more than the starts when the text ends with LF (or is empty)
    test rbx, rbx
    jz 8f
    test r13, r13
    jz 8f
    mov r14, [r12 + RVF_on]
    mov rcx, [r12 + RVF_oldlen]
    test rcx, rcx
    jz 2f
    mov rdx, [r12 + RVF_old]
    cmp byte ptr [rdx + rcx - 1], 10
    jne 3f
2:  inc r14                     # the empty line after the last LF
3:  cmp rbx, r14
    ja 8f
    mov rdx, [r12 + RVF_ostart]
    mov rax, [r12 + RVF_on]
    cmp rbx, rax
    ja 4f
    mov r8, [rdx + rbx*8 - 8]   # the line's start
    mov r9, [rdx + rbx*8]       # and the next one's
    cmp r9, r8
    je 5f
    mov r10, [r12 + RVF_old]
    cmp byte ptr [r10 + r9 - 1], 10
    jne 5f
    dec r9                      # its end is its LF
    jmp 5f
4:  mov r8, [r12 + RVF_oldlen]   # the empty last line
    mov r9, r8
5:  lea rax, [r8 + r13 - 1]
    cmp rax, r9
    ja 8f
    cmp rax, [r12 + RVF_oldlen]
    jae 9f
    mov r10, [r12 + RVF_old]
    movzx ecx, byte ptr [r10 + rax]
    and ecx, 0xc0
    cmp ecx, 0x80
    je 8f
9:  EPILOGUE
8:  mov rax, -1
    EPILOGUE

# sort_edits(): sorted by start, then end (an insertion before a replacement that starts there),
#   equal ones in their order: a merge sort of the pointers
sort_edits:
    PROLOGUE 32
    mov r12, [rip + sorted + VEC_len]
    cmp r12, 2
    jb 9f
    lea rdi, [rip + sort_tmp]
    mov qword ptr [rdi + VEC_len], 0
    lea rsi, [r12*8]
    call sb_reserve_vec
    mov r13, 1                  # width
1:  cmp r13, r12
    jae 9f
    xor r14d, r14d              # lo
2:  cmp r14, r12
    jae 7f
    lea rax, [r14 + r13]
    cmp rax, r12
    jbe 3f
    mov rax, r12
3:  mov [rsp], rax              # mid
    lea rax, [r14 + r13*2]
    cmp rax, r12
    jbe 4f
    mov rax, r12
4:  mov [rsp + 8], rax          # hi
    mov rbx, r14                # i
    mov r15, [rsp]              # j
    mov rcx, r14                # k
5:  cmp rcx, [rsp + 8]
    jae 6f
    mov r8, [rip + sorted + VEC_ptr]
    mov r9, [rip + sort_tmp + VEC_ptr]
    cmp rbx, [rsp]
    jae 52f
    cmp r15, [rsp + 8]
    jae 51f
    mov r10, [r8 + rbx*8]
    mov r11, [r8 + r15*8]
    mov rax, [r11 + RVE_start]   # the right one first only when strictly less
    cmp rax, [r10 + RVE_start]
    jb 52f
    ja 51f
    mov rax, [r11 + RVE_end]
    cmp rax, [r10 + RVE_end]
    jb 52f
51: mov rax, [r8 + rbx*8]
    mov [r9 + rcx*8], rax
    inc rbx
    inc rcx
    jmp 5b
52: mov rax, [r8 + r15*8]
    mov [r9 + rcx*8], rax
    inc r15
    inc rcx
    jmp 5b
6:  mov r14, [rsp + 8]
    jmp 2b
7:  # the merged run back
    mov rdi, [rip + sorted + VEC_ptr]
    mov rsi, [rip + sort_tmp + VEC_ptr]
    lea rdx, [r12*8]
    call memcpy
    add r13, r13
    jmp 1b
9:  EPILOGUE

# sb_reserve_vec(vec, bytes): room for that many bytes in a vec of pointers
sb_reserve_vec:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, [rbx + VEC_cap]
    jbe 9f
    mov rdi, [rbx + VEC_ptr]
    mov rsi, r12
    call mem_realloc
    mov [rbx + VEC_ptr], rax
    mov [rbx + VEC_cap], r12
9:  EPILOGUE

# file_free(RF*): what it owns
file_free:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + RVF_path]
    call mem_free
    mov rdi, [rbx + RVF_name]
    call mem_free
    mov rdi, [rbx + RVF_old]
    call mem_free
    mov rdi, [rbx + RVF_new]
    call mem_free
    mov rdi, [rbx + RVF_ostart]
    call mem_free
    mov rdi, [rbx + RVF_nstart]
    call mem_free
    lea rdi, [rbx + RVF_hunks]
    call vec_free
    mov rdi, rbx
    mov ecx, RVF_SIZE
    xor eax, eax
    rep stosb
    EPILOGUE

# proposal_free(RV*)
proposal_free:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + RVP_files + VEC_len]
    jae 2f
    imul rdi, r12, RVF_SIZE
    add rdi, [rbx + RVP_files + VEC_ptr]
    call file_free
    inc r12
    jmp 1b
2:  lea rdi, [rbx + RVP_files]
    call vec_free
    mov rdi, [rbx + RVP_label]
    call mem_free
    mov rdi, [rbx + RVP_sid]
    call mem_free
    mov rdi, [rbx + RVP_orig]
    call mem_free
    mov rdi, rbx                # task 12: its scratch document closes in the next tick
    call scratch_orphan
    mov rdi, rbx
    call mem_free
    EPILOGUE

# ---------------- the changes of a file ----------------

# file_diff(RF*): RVF_hunks, RVF_add, RVF_del from a line diff (Myers) of its text before and after; each
#   run of changed lines is a hunk. A diff that does not give back the text after is one hunk.
file_diff:
    PROLOGUE 48
    mov rbx, rdi
    cmp qword ptr [rbx + RVF_ostart], 0
    jne 1f
    mov rdi, [rbx + RVF_old]
    mov rsi, [rbx + RVF_oldlen]
    lea rdx, [rbx + RVF_on]
    call line_starts
    mov [rbx + RVF_ostart], rax
1:  mov rdi, [rbx + RVF_new]
    mov rsi, [rbx + RVF_newlen]
    lea rdx, [rbx + RVF_nn]
    call line_starts
    mov [rbx + RVF_nstart], rax
    # hashes and flags
    mov rdi, [rip + ha]
    call mem_free
    mov rdi, [rip + hb]
    call mem_free
    mov rdi, [rip + fdel]
    call mem_free
    mov rdi, [rip + fadd]
    call mem_free
    mov rdi, [rbx + RVF_old]
    mov rsi, [rbx + RVF_ostart]
    mov rdx, [rbx + RVF_on]
    call hashes
    mov [rip + ha], rax
    mov rdi, [rbx + RVF_new]
    mov rsi, [rbx + RVF_nstart]
    mov rdx, [rbx + RVF_nn]
    call hashes
    mov [rip + hb], rax
    mov rdi, [rbx + RVF_on]
    inc rdi
    call mem_alloc
    mov [rip + fdel], rax
    mov rdi, [rbx + RVF_nn]
    inc rdi
    call mem_alloc
    mov [rip + fadd], rax
    # the common start and end
    mov r12, [rbx + RVF_on]
    mov r13, [rbx + RVF_nn]
    mov r8, [rip + ha]
    mov r9, [rip + hb]
    xor ecx, ecx
2:  cmp rcx, r12
    jae 3f
    cmp rcx, r13
    jae 3f
    mov rax, [r8 + rcx*8]
    cmp rax, [r9 + rcx*8]
    jne 3f
    inc rcx
    jmp 2b
3:  mov r14, rcx                # prefix
4:  cmp r12, r14
    jbe 5f
    cmp r13, r14
    jbe 5f
    mov rax, [r8 + r12*8 - 8]
    cmp rax, [r9 + r13*8 - 8]
    jne 5f
    dec r12
    dec r13
    jmp 4b
5:  # the middle: old [p, r12) against new [p, r13)
    lea rdi, [r8 + r14*8]
    mov rsi, r12
    sub rsi, r14
    lea rdx, [r9 + r14*8]
    mov rcx, r13
    sub rcx, r14
    mov r8, r14
    call myers
    test eax, eax
    jnz 7f
    # too different: the middle changed as a whole
    mov rcx, r14
6:  cmp rcx, r12
    jae 61f
    mov rax, [rip + fdel]
    mov byte ptr [rax + rcx], 1
    inc rcx
    jmp 6b
61: mov rcx, r14
62: cmp rcx, r13
    jae 7f
    mov rax, [rip + fadd]
    mov byte ptr [rax + rcx], 1
    inc rcx
    jmp 62b
7:  mov rdi, rbx
    call make_hunks
    mov rdi, rbx
    call hunks_check
    test eax, eax
    jnz 9f
    # one hunk: everything
    mov qword ptr [rbx + RVF_hunks + VEC_len], 0
    lea rdi, [rbx + RVF_hunks]
    mov esi, RVH_SIZE
    call vec_push
    mov rcx, [rbx + RVF_on]
    mov [rax + RVH_oc], rcx
    mov [rbx + RVF_del], ecx
    mov rcx, [rbx + RVF_nn]
    mov [rax + RVH_nc], rcx
    mov [rbx + RVF_add], ecx
9:  EPILOGUE

# hashes(text, starts, n) -> n line hashes (mem_alloc'd), each over the line and its LF
hashes:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rdx*8 + 8]
    call mem_alloc
    mov r14, rax
    xor r15d, r15d
1:  cmp r15, r13
    jae 9f
    mov rdi, [r12 + r15*8]
    mov rsi, [r12 + r15*8 + 8]
    sub rsi, rdi
    add rdi, rbx
    call hash_line
    mov [r14 + r15*8], rax
    inc r15
    jmp 1b
9:  mov rax, r14
    EPILOGUE

# make_hunks(RF*): a hunk per run of changed lines (fdel over the old lines, fadd over the new)
make_hunks:
    PROLOGUE 16
    mov rbx, rdi
    mov qword ptr [rbx + RVF_hunks + VEC_len], 0
    mov dword ptr [rbx + RVF_add], 0
    mov dword ptr [rbx + RVF_del], 0
    xor r12d, r12d              # i, old
    xor r13d, r13d              # j, new
.Lmh_next:
    mov r8, [rip + fdel]
    mov r9, [rip + fadd]
    xor eax, eax                # i changed
    cmp r12, [rbx + RVF_on]
    jae 1f
    movzx eax, byte ptr [r8 + r12]
1:  xor ecx, ecx                # j changed
    cmp r13, [rbx + RVF_nn]
    jae 2f
    movzx ecx, byte ptr [r9 + r13]
2:  mov edx, eax
    or edx, ecx
    jnz 3f
    # both unchanged, or the end
    cmp r12, [rbx + RVF_on]
    jb 21f
    cmp r13, [rbx + RVF_nn]
    jae 9f
21: inc r12
    inc r13
    jmp .Lmh_next
3:  mov r14, r12
    mov r15, r13
4:  mov r8, [rip + fdel]
    mov r9, [rip + fadd]
    xor edx, edx
    cmp r12, [rbx + RVF_on]
    jae 5f
    cmp byte ptr [r8 + r12], 0
    je 5f
    inc r12
    inc edx
5:  cmp r13, [rbx + RVF_nn]
    jae 6f
    cmp byte ptr [r9 + r13], 0
    je 6f
    inc r13
    inc edx
6:  test edx, edx
    jnz 4b
    lea rdi, [rbx + RVF_hunks]
    mov esi, RVH_SIZE
    call vec_push
    mov [rax + RVH_ol], r14
    mov rcx, r12
    sub rcx, r14
    mov [rax + RVH_oc], rcx
    add [rbx + RVF_del], ecx
    mov [rax + RVH_nl], r15
    mov rcx, r13
    sub rcx, r15
    mov [rax + RVH_nc], rcx
    add [rbx + RVF_add], ecx
    jmp .Lmh_next
9:  EPILOGUE

# hunks_check(RF*) -> eax 1 when every hunk applied to the text before gives the text after
hunks_check:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + scratch]
    call sb_clear
    mov rdi, rbx
    mov esi, 1                  # all of them
    call build_text
    xor eax, eax
    mov rcx, [rip + scratch + SB_len]
    cmp rcx, [rbx + RVF_newlen]
    jne 9f
    mov rdi, [rip + scratch + SB_ptr]
    mov rsi, [rbx + RVF_new]
    mov rdx, rcx
    call memeq
9:  EPILOGUE

# build_text(RF*, all): scratch gets the text before with the accepted hunks applied (all 1: every hunk; 2:
#   every hunk but the rejected ones)
build_text:
    PROLOGUE
    mov rbx, rdi
    mov r15d, esi
    xor r12d, r12d              # old offset copied up to
    xor r13d, r13d
1:  cmp r13, [rbx + RVF_hunks + VEC_len]
    jae 3f
    imul r14, r13, RVH_SIZE
    add r14, [rbx + RVF_hunks + VEC_ptr]
    inc r13
    cmp r15d, 1
    je 2f
    cmp r15d, 2                 # task 12: every hunk but the rejected ones
    je 21f
    cmp dword ptr [r14 + RVH_state], RVS_ACCEPTED
    jne 1b
    jmp 2f
21: cmp dword ptr [r14 + RVH_state], RVS_REJECTED
    je 1b
2:  mov rcx, [rbx + RVF_ostart]
    mov rax, [r14 + RVH_ol]
    mov rdx, [rcx + rax*8]      # the hunk's old start
    lea rdi, [rip + scratch]
    mov rsi, [rbx + RVF_old]
    add rsi, r12
    sub rdx, r12
    call sb_push
    mov rcx, [rbx + RVF_nstart]
    mov rax, [r14 + RVH_nl]
    mov rsi, [rcx + rax*8]
    add rax, [r14 + RVH_nc]
    mov rdx, [rcx + rax*8]
    sub rdx, rsi
    add rsi, [rbx + RVF_new]
    lea rdi, [rip + scratch]
    call sb_push
    mov rcx, [rbx + RVF_ostart]
    mov rax, [r14 + RVH_ol]
    add rax, [r14 + RVH_oc]
    mov r12, [rcx + rax*8]      # the hunk's old end
    jmp 1b
3:  lea rdi, [rip + scratch]
    mov rsi, [rbx + RVF_old]
    add rsi, r12
    mov rdx, [rbx + RVF_oldlen]
    sub rdx, r12
    call sb_push
    EPILOGUE

# myers(a, n, b, m, p) -> eax 1 with fdel[p + x] for old lines deleted and fadd[p + y] for new lines
#   inserted, 0 beyond RVP_DMAX differences (diff.s's walk, with both sides marked)
myers:
    PROLOGUE 64
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov [rsp + 24], rcx
    mov [rsp + 32], r8
    cmp qword ptr [rip + vbuf], 0
    jne 1f
    mov edi, (2 * RVP_DMAX + 3) * 4
    call mem_alloc
    mov [rip + vbuf], rax
1:  mov rbx, [rip + vbuf]
    add rbx, (RVP_DMAX + 1) * 4  # V[k] at rbx + 4k
    mov dword ptr [rbx + 4], 0
    xor r12d, r12d              # d
    mov qword ptr [rsp + 40], 0 # trace used (ints)
.Lmy_d:
    cmp r12, RVP_DMAX
    ja .Lmy_fail
    mov r13, r12
    neg r13                     # k
.Lmy_k:
    cmp r13, r12
    jg .Lmy_save
    mov rax, r12
    neg rax
    cmp r13, rax
    je 2f
    cmp r13, r12
    je 3f
    mov eax, [rbx + r13*4 - 4]
    cmp eax, [rbx + r13*4 + 4]
    jge 3f
2:  mov r14d, [rbx + r13*4 + 4]
    jmp 4f
3:  mov r14d, [rbx + r13*4 - 4]
    inc r14d
4:  movsxd r14, r14d            # x
    mov r15, r14
    sub r15, r13                # y
    mov rdi, [rsp]
    mov rsi, [rsp + 16]
5:  cmp r14, [rsp + 8]
    jae 6f
    cmp r15, [rsp + 24]
    jae 6f
    mov rax, [rdi + r14*8]
    cmp rax, [rsi + r15*8]
    jne 6f
    inc r14
    inc r15
    jmp 5b
6:  mov [rbx + r13*4], r14d
    cmp r14, [rsp + 8]
    jb 7f
    cmp r15, [rsp + 24]
    jb 7f
    call .Lmy_store
    jmp .Lmy_back
7:  add r13, 2
    jmp .Lmy_k
.Lmy_save:
    call .Lmy_store
    inc r12
    jmp .Lmy_d
.Lmy_fail:
    xor eax, eax
    EPILOGUE
.Lmy_store:
    mov rax, [rsp + 8 + 40]
    lea rsi, [rax + r12*2 + 1]
    lea rsi, [rsi*4]
    cmp rsi, [rip + tcap]
    jbe 1f
    lea rsi, [rsi + rsi]
    add rsi, 4096
    mov [rip + tcap], rsi
    mov rdi, [rip + trace]
    call mem_realloc
    mov [rip + trace], rax
1:  mov rdi, [rip + trace]
    mov rax, [rsp + 8 + 40]
    lea rdi, [rdi + rax*4]
    mov rsi, r12
    neg rsi
    lea rsi, [rbx + rsi*4]
    lea rcx, [r12*2 + 1]
    add [rsp + 8 + 40], rcx
    rep movsd
    ret
.Lmy_back:
    mov rax, [rsp + 40]
    lea rcx, [r12*2 + 1]
    sub rax, rcx
    mov [rsp + 48], rax
.Lmy_step:
    test r12, r12
    jz .Lmy_ok
    lea rcx, [r12*2 - 1]
    mov rax, [rsp + 48]
    sub rax, rcx
    mov [rsp + 48], rax
    mov rdi, [rip + trace]
    lea rdi, [rdi + rax*4]
    lea rcx, [r12 - 1]
    lea rdi, [rdi + rcx*4]      # V'[k] at rdi + 4k
    mov r13, r14
    sub r13, r15                # k
    mov rax, r12
    neg rax
    cmp r13, rax
    je 1f
    cmp r13, r12
    je 2f
    mov eax, [rdi + r13*4 - 4]
    cmp eax, [rdi + r13*4 + 4]
    jge 2f
1:  lea rcx, [r13 + 1]          # came down: a line of b inserted
    jmp 3f
2:  lea rcx, [r13 - 1]          # came right: a line of a deleted
3:  movsxd rax, dword ptr [rdi + rcx*4]
    mov rdx, rax
    sub rdx, rcx                # previous y
4:  cmp r14, rax
    jle 5f
    cmp r15, rdx
    jle 5f
    dec r14
    dec r15
    jmp 4b
5:  mov r8, [rsp + 32]
    cmp r14, rax
    jne 6f
    mov r9, [rip + fadd]
    lea r10, [r15 + r8 - 1]
    mov byte ptr [r9 + r10], 1
    jmp 7f
6:  mov r9, [rip + fdel]
    lea r10, [r14 + r8 - 1]
    mov byte ptr [r9 + r10], 1
7:  mov r14, rax
    mov r15, rdx
    dec r12
    jmp .Lmy_step
.Lmy_ok:
    mov eax, 1
    EPILOGUE

# ---------------- the Review tab ----------------

# open_tab(RV*): a read-only diff view of the proposal, in a tab of its own
open_tab:
    PROLOGUE
    mov rbx, rdi
    call doc_new
    mov r12, rax
    or dword ptr [r12 + DOC_flags], DF_READONLY
    mov edi, DV_SIZE
    call mem_alloc
    mov r13, rax
    mov [r12 + DOC_diff], rax
    mov [r13 + DV_review], rbx
    mov dword ptr [r13 + DV_flags], 0   # wsedit: not a wsdiff.s tab (mem_alloc does not clear)
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    lea rsi, [rip + .Ltab_prefix]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov rsi, [rbx + RVP_label]
    call sb_push_cstr
    mov rdi, [rip + line + SB_ptr]
    mov rsi, [rip + line + SB_len]
    call ai_dup
    mov [r13 + DV_name], rax
    mov [r12 + DOC_name], rax
    mov [rbx + RVP_doc], r12
    mov rdi, r12
    call doc_language_refresh
    mov rdi, r12
    mov esi, TAB_DOC
    call app_add_tab
    mov rdi, rbx
    call build_doc
    # the cursor on the first file
    mov rax, [rbx + RVP_files + VEC_ptr]
    mov eax, [rax + RVF_line]
    mov rdi, r12
    mov rsi, rax
    call doc_line_start
    mov [r12 + DOC_cur], rax
    mov [r12 + DOC_anchor], rax
    EPILOGUE

# build_doc(RV*): the Review document's text and line records from the proposal's state; the cursor
#   stays on its line
build_doc:
    PROLOGUE 48
    mov rbx, rdi
    mov r15, [rbx + RVP_doc]
    test r15, r15
    jz 99f
    mov rdi, r15
    mov rsi, [r15 + DOC_cur]
    call doc_line_of
    mov [rsp + 40], rax         # the cursor's line
    lea rdi, [rip + text]
    call sb_clear
    mov qword ptr [rip + dls + VEC_len], 0
    mov dword ptr [rip + maxno], 0
    # the title: label, source, files and what is left to decide
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    mov rsi, [rbx + RVP_label]
    call sb_push_cstr
    lea rdi, [rip + line]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    cmp dword ptr [rbx + RVP_offer], 0  # an offer has no extension: what is decided so far instead
    je 0f
    mov rdi, rbx
    call offer_title
    jmp 1f
0:  mov rdi, [rbx + RVP_ext]
    call agentext_title
    mov rsi, rax
3:  lea rdi, [rip + line]
    call sb_push_cstr
    lea rdi, [rip + line]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov rsi, [rbx + RVP_files + VEC_len]
    call sb_push_u64
    lea rdi, [rip + line]
    lea rsi, [rip + .Lfiles]
    call sb_push_cstr
    mov rdi, rbx
    call pending_files
    test rax, rax
    jz 1f
    push rax
    push rax
    lea rdi, [rip + line]
    lea rsi, [rip + .Lcomma]
    call sb_push_cstr
    pop rsi
    pop rsi
    lea rdi, [rip + line]
    call sb_push_u64
    lea rdi, [rip + line]
    lea rsi, [rip + .Lto_decide]
    call sb_push_cstr
1:  mov edi, DK_INFO
    xor esi, esi
    xor edx, edx
    call emit_line
    lea rdi, [rip + line]
    call sb_clear
    mov edi, DK_INFO
    xor esi, esi
    xor edx, edx
    call emit_line
    # the files
    xor r12d, r12d
.Lbd_file:
    cmp r12, [rbx + RVP_files + VEC_len]
    jae .Lbd_done
    imul r13, r12, RVF_SIZE
    add r13, [rbx + RVP_files + VEC_ptr]
    inc r12
    mov rax, [rip + dls + VEC_len]
    mov [r13 + RVF_line], eax
    lea rdi, [rip + line]
    call sb_clear
    mov rdi, r13
    call show_path
    lea rdi, [rip + line]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + line]
    lea rsi, [rip + .Lplus]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov esi, [r13 + RVF_add]
    call sb_push_u64
    lea rdi, [rip + line]
    lea rsi, [rip + .Lminus]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov esi, [r13 + RVF_del]
    call sb_push_u64
    lea rdi, [rip + line]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    mov rdi, r13
    call file_state_word
    lea rdi, [rip + line]
    mov rsi, rax
    call sb_push_cstr
    mov edi, DK_FILE
    xor esi, esi
    xor edx, edx
    call emit_line
    # its hunks with their context
    xor r14d, r14d
    mov qword ptr [rsp], 0      # old lines shown so far (context does not repeat)
.Lbd_hunk:
    cmp r14, [r13 + RVF_hunks + VEC_len]
    jae .Lbd_file
    imul rax, r14, RVH_SIZE
    add rax, [r13 + RVF_hunks + VEC_ptr]
    mov [rsp + 8], rax
    inc r14
    mov rcx, [rip + dls + VEC_len]
    mov [rax + RVH_line], ecx
    # @@ -ol,oc +nl,nc @@
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    lea rsi, [rip + .Lat_minus]
    call sb_push_cstr
    mov rax, [rsp + 8]
    mov rsi, [rax + RVH_ol]
    inc rsi
    lea rdi, [rip + line]
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, ','
    call sb_push_byte
    mov rax, [rsp + 8]
    lea rdi, [rip + line]
    mov rsi, [rax + RVH_oc]
    call sb_push_u64
    lea rdi, [rip + line]
    lea rsi, [rip + .Lsp_plus]
    call sb_push_cstr
    mov rax, [rsp + 8]
    mov rsi, [rax + RVH_nl]
    inc rsi
    lea rdi, [rip + line]
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, ','
    call sb_push_byte
    mov rax, [rsp + 8]
    lea rdi, [rip + line]
    mov rsi, [rax + RVH_nc]
    call sb_push_u64
    lea rdi, [rip + line]
    lea rsi, [rip + .Lat_end]
    call sb_push_cstr
    mov rax, [rsp + 8]
    mov eax, [rax + RVH_state]
    test eax, eax
    jz 2f
    lea rcx, [rip + hunk_words]
    lea rdi, [rip + line]
    mov rsi, [rcx + rax*8]
    call sb_push_cstr
2:  mov edi, DK_HUNK
    xor esi, esi
    xor edx, edx
    call emit_line
    # context before, from where the last one stopped
    mov rax, [rsp + 8]
    mov r15, [rax + RVH_ol]
    sub r15, RVP_CONTEXT
    jns 3f
    xor r15d, r15d
3:  cmp r15, [rsp]
    jae 4f
    mov r15, [rsp]
4:  mov rax, [rsp + 8]
    cmp r15, [rax + RVH_ol]
    jae 5f
    mov rdi, r13
    mov rsi, r15
    mov rdx, [rax + RVH_nl]
    sub rdx, [rax + RVH_ol]
    add rdx, r15                # its new line
    call emit_context
    inc r15
    jmp 4b
5:  # the old lines, then the new ones
    mov rax, [rsp + 8]
    mov r15, [rax + RVH_ol]
6:  mov rax, [rsp + 8]
    mov rcx, [rax + RVH_ol]
    add rcx, [rax + RVH_oc]
    cmp r15, rcx
    jae 7f
    mov rdi, r13
    mov rsi, r15
    call emit_old
    inc r15
    jmp 6b
7:  mov rax, [rsp + 8]
    mov r15, [rax + RVH_nl]
8:  mov rax, [rsp + 8]
    mov rcx, [rax + RVH_nl]
    add rcx, [rax + RVH_nc]
    cmp r15, rcx
    jae 9f
    mov rdi, r13
    mov rsi, r15
    call emit_new
    inc r15
    jmp 8b
9:  # context after, up to the next hunk
    mov rax, [rsp + 8]
    mov r15, [rax + RVH_ol]
    add r15, [rax + RVH_oc]
    mov rcx, r15
    add rcx, RVP_CONTEXT
    cmp rcx, [r13 + RVF_on]
    jbe 10f
    mov rcx, [r13 + RVF_on]
10: cmp r14, [r13 + RVF_hunks + VEC_len]
    jae 11f
    imul rdx, r14, RVH_SIZE
    add rdx, [r13 + RVF_hunks + VEC_ptr]
    mov rdx, [rdx + RVH_ol]
    cmp rcx, rdx
    jbe 11f
    mov rcx, rdx
11: mov [rsp + 16], rcx
12: cmp r15, [rsp + 16]
    jae 13f
    mov rax, [rsp + 8]
    mov rdi, r13
    mov rsi, r15
    mov rdx, [rax + RVH_nl]
    add rdx, [rax + RVH_nc]
    sub rdx, [rax + RVH_ol]
    sub rdx, [rax + RVH_oc]
    add rdx, r15
    call emit_context
    inc r15
    jmp 12b
13: mov [rsp], r15
    jmp .Lbd_hunk
.Lbd_done:
    mov r15, [rbx + RVP_doc]
    mov rdi, r15
    mov rsi, [rip + text + SB_ptr]
    mov rdx, [rip + text + SB_len]
    call doc_replace_all
    mov r12, [r15 + DOC_diff]
    mov rdi, [r12 + DV_lines]
    call mem_free
    mov rax, [rip + dls + VEC_len]
    mov [r12 + DV_n], rax
    imul rdi, rax, DL_SIZE
    mov r13, rdi
    call mem_alloc
    mov [r12 + DV_lines], rax
    mov rdi, rax
    mov rsi, [rip + dls + VEC_ptr]
    mov rdx, r13
    call memcpy
    mov eax, [rip + maxno]
    mov [r12 + DV_maxno], eax
    mov qword ptr [r15 + DOC_svalid], 0
    # the cursor back on its line
    mov rsi, [rsp + 40]
    cmp rsi, [r15 + DOC_nlines]
    jb 14f
    mov rsi, [r15 + DOC_nlines]
    dec rsi
14: mov rdi, r15
    call doc_line_start
    mov [r15 + DOC_cur], rax
    mov [r15 + DOC_anchor], rax
    mov rdi, r15
    call ed_top_inside
    mov dword ptr [rip + g_dirty], 1
99: EPILOGUE

# emit_line(kind, old, new): line (the SB) as the next line of the Review document
emit_line:
    PROLOGUE
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    cmp qword ptr [rip + dls + VEC_len], 0
    je 1f
    lea rdi, [rip + text]
    mov esi, 10
    call sb_push_byte
1:  lea rdi, [rip + text]
    mov rsi, [rip + line + SB_ptr]
    mov rdx, [rip + line + SB_len]
    call sb_push
    lea rdi, [rip + dls]
    mov esi, DL_SIZE
    call vec_push
    mov [rax + DL_kind], ebx
    mov [rax + DL_old], r12d
    mov [rax + DL_new], r13d
    mov eax, r12d
    cmp r13d, eax
    cmovg eax, r13d
    cmp eax, [rip + maxno]
    jle 9f
    mov [rip + maxno], eax
9:  EPILOGUE

# emit_context(RF*, old line, new line), emit_old(RF*, old line), emit_new(RF*, new line): one line
#   of the text, without its LF
emit_context:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [rbx + RVF_old]
    mov rsi, [rbx + RVF_ostart]
    mov rdx, r12
    call text_line
    mov edi, DK_CTX
    lea esi, [r12 + 1]
    lea edx, [r13 + 1]
    call emit_line
    EPILOGUE
emit_old:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + RVF_old]
    mov rsi, [rbx + RVF_ostart]
    mov rdx, r12
    call text_line
    mov edi, DK_DEL
    lea esi, [r12 + 1]
    xor edx, edx
    call emit_line
    EPILOGUE
emit_new:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + RVF_new]
    mov rsi, [rbx + RVF_nstart]
    mov rdx, r12
    call text_line
    mov edi, DK_ADD
    xor esi, esi
    lea edx, [r12 + 1]
    call emit_line
    EPILOGUE

# text_line(text, starts, i): line (the SB) holds line i of the text, without its LF
text_line:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rsi + rdx*8]
    mov r13, [rsi + rdx*8 + 8]
    cmp r13, r12
    je 1f
    cmp byte ptr [rbx + r13 - 1], 10
    jne 1f
    dec r13
1:  lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    lea rsi, [rbx + r12]
    mov rdx, r13
    sub rdx, r12
    call sb_push
    EPILOGUE

# show_path(RF*) -> cstr: the file as the Review tab names it, inside the project relative to it
show_path:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + RVF_path]
    test r12, r12
    jz 8f
    mov r13, [rip + g_project]
    test r13, r13
    jz 7f
    mov rdi, r13
    call strlen
    mov r14, rax
    mov rdi, r12
    call strlen
    lea rcx, [r14 + 1]
    cmp rax, rcx
    jbe 7f
    mov rdi, r12
    mov rsi, rax
    mov rdx, r13
    mov rcx, r14
    call str_starts
    test eax, eax
    jz 7f
    cmp byte ptr [r12 + r14], '/'
    jne 7f
    lea rax, [r12 + r14 + 1]
    EPILOGUE
7:  mov rax, r12
    EPILOGUE
8:  mov rax, [rbx + RVF_name]
    EPILOGUE

# file_state_word(RF*) -> cstr: pending, accepted, rejected, changed since proposed, partly accepted
file_state_word:
    mov eax, [rdi + RVF_state]
    lea rcx, [rip + file_words]
    mov rax, [rcx + rax*8]
    ret

# pending_files(RV*) -> rax the files not decided yet
pending_files:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, [rdi + RVP_files + VEC_len]
    jae 9f
    imul rdx, rcx, RVF_SIZE
    add rdx, [rdi + RVP_files + VEC_ptr]
    inc rcx
    cmp dword ptr [rdx + RVF_state], RVS_PENDING
    jne 1b
    inc rax
    jmp 1b
9:  ret

# ---------------- deciding ----------------

# FN review_decide(RV*, file, hunk, accept): the user's choice for one hunk (hunk >= 0), every hunk
#   of a file still open (hunk -1), or of every file (file -1). Accepting applies the hunks through
#   ws_apply as one undo step per file; a file that changed since it was proposed is not touched.
FN review_decide
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov r15d, ecx
    cmp dword ptr [rbx + RVP_done], 0
    jne 9f
    cmp dword ptr [rbx + RVP_offer], 0  # an offer: its owner decides what happens (offer_decide)
    je 0f
    mov rdi, rbx
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    mov ecx, r15d
    call offer_decide
    jmp 9f
0:  mov rax, [rsp]
    test rax, rax
    jns 2f
    xor r12d, r12d
1:  cmp r12, [rbx + RVP_files + VEC_len]
    jae 3f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, -1
    mov ecx, r15d
    call decide_file
    inc r12
    jmp 1b
2:  cmp rax, [rbx + RVP_files + VEC_len]
    jae 9f
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rsp + 8]
    mov ecx, r15d
    call decide_file
3:  mov rdi, rbx
    call check_done
    mov rdi, rbx
    call build_doc
9:  EPILOGUE

# decide_file(RV*, file, hunk or -1, accept)
decide_file:
    PROLOGUE 16
    mov rbx, rdi
    imul r12, rsi, RVF_SIZE
    add r12, [rbx + RVP_files + VEC_ptr]
    mov [rsp], rsi
    mov r13, rdx
    mov r14d, ecx
    cmp dword ptr [r12 + RVF_state], RVS_PENDING
    jne 9f
    test r13, r13
    js 1f
    cmp r13, [r12 + RVF_hunks + VEC_len]
    jae 9f
    imul rax, r13, RVH_SIZE
    add rax, [r12 + RVF_hunks + VEC_ptr]
    cmp dword ptr [rax + RVH_state], RVS_PENDING
    jne 9f
1:  test r14d, r14d
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call accept_hunks
    jmp 3f
2:  xor ecx, ecx                # rejected: nothing changes
4:  cmp rcx, [r12 + RVF_hunks + VEC_len]
    jae 3f
    imul rax, rcx, RVH_SIZE
    add rax, [r12 + RVF_hunks + VEC_ptr]
    inc rcx
    test r13, r13
    js 5f
    lea rdx, [r13 + 1]
    cmp rcx, rdx
    jne 4b
5:  cmp dword ptr [rax + RVH_state], RVS_PENDING
    jne 4b
    mov dword ptr [rax + RVH_state], RVS_REJECTED
    jmp 4b
3:  mov rdi, rbx
    mov rsi, [rsp]
    call settle
9:  EPILOGUE

# accept_hunks(RV*, RF*, hunk or -1): the file's text must still be the text before with the hunks
#   accepted so far; then a one-file workspace edit replaces each chosen hunk's lines with its new
#   ones. Otherwise, or when ws_apply refuses, the open hunks are stale.
accept_hunks:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp qword ptr [rbx + RVP_owner], 0
    jne .Lah_mark               # an offer: nothing is applied, the chosen hunks are only marked
    # what the file should be
    lea rdi, [rip + scratch]
    call sb_clear
    mov rdi, r12
    xor esi, esi
    call build_text
    # what it is
    mov qword ptr [rsp], 0      # the open document, or 0
    mov rax, [r12 + RVF_docid]
    test rax, rax
    jz 1f
    mov rdi, rax
    call extproto_doc
    test rax, rax
    jnz 2f
1:  mov rdi, [r12 + RVF_path]
    test rdi, rdi
    jz .Lah_stale
    call open_doc_at
    test rax, rax
    js .Lah_stale
    jnz 2f
    mov rdi, [r12 + RVF_path]
    call read_text
    test rax, rax
    jz .Lah_stale
    jmp 3f
2:  mov [rsp], rax
    mov rdi, rax
    call doc_text_copy
3:  mov [rsp + 8], rax          # current text (owned)
    mov [rsp + 16], rdx
    xor r14d, r14d
    cmp rdx, [rip + scratch + SB_len]
    jne 4f
    mov rdi, rax
    mov rsi, [rip + scratch + SB_ptr]
    call memeq
    mov r14d, eax
4:  mov rdi, [rsp + 8]
    call mem_free
    test r14d, r14d
    jz .Lah_stale
    # the edit: 1 LF, then REF VERSION K and the edits, positions in the current text
    lea rdi, [rip + text]
    call sb_clear
    lea rdi, [rip + line]
    call sb_clear
    mov rax, [rsp]
    test rax, rax
    jz 5f
    lea rdi, [rip + line]
    mov esi, '#'
    call sb_push_byte
    mov rax, [rsp]
    lea rdi, [rip + line]
    mov rsi, [rax + DOC_id]
    call sb_push_u64
    jmp 6f
5:  lea rdi, [rip + line]
    mov rsi, [r12 + RVF_path]
    call sb_push_cstr
6:  lea rdi, [rip + text]
    lea rsi, [rip + .Lone_lf]
    call sb_push_cstr
    lea rdi, [rip + text]
    mov rsi, [rip + line + SB_len]
    call sb_push_u64
    lea rdi, [rip + text]
    mov esi, ' '
    call sb_push_byte
    mov rax, [rsp]
    test rax, rax
    jz 7f
    lea rdi, [rip + text]
    mov rsi, [rax + DOC_version]
    call sb_push_u64
    jmp 8f
7:  lea rdi, [rip + text]
    mov esi, '-'
    call sb_push_byte
8:  lea rdi, [rip + text]
    mov esi, ' '
    call sb_push_byte
    # how many: the open hunks chosen
    xor ecx, ecx
    xor edx, edx
10: cmp rcx, [r12 + RVF_hunks + VEC_len]
    jae 11f
    mov rdi, r12
    mov rsi, rcx
    mov r8, r13
    call chosen
    add rdx, rax
    inc rcx
    jmp 10b
11: lea rdi, [rip + text]
    mov rsi, rdx
    call sb_push_u64
    lea rdi, [rip + text]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + text]
    mov rsi, [rip + line + SB_ptr]
    mov rdx, [rip + line + SB_len]
    call sb_push
    # each chosen hunk at its place in the current text: its old place, moved by the accepted ones
    # before it; lines and columns counted as the text goes
    mov qword ptr [rsp + 24], 0 # shift
    mov qword ptr [rsp + 32], 0 # scan offset
    mov qword ptr [rsp + 40], 1 # its line
    mov qword ptr [rsp + 48], 0 # its line's start
    xor r15d, r15d
12: cmp r15, [r12 + RVF_hunks + VEC_len]
    jae 15f
    imul r14, r15, RVH_SIZE
    add r14, [r12 + RVF_hunks + VEC_ptr]
    mov rdi, r12
    mov rsi, r15
    mov r8, r13
    call chosen
    inc r15
    test eax, eax
    jnz 13f
    cmp dword ptr [r14 + RVH_state], RVS_ACCEPTED
    jne 12b
    mov rdi, r12
    mov rsi, r14
    call hunk_growth
    add [rsp + 24], rax
    jmp 12b
13: mov rdi, r12
    mov rsi, r14
    call hunk_old_range
    add rax, [rsp + 24]
    add rdx, [rsp + 24]
    mov [rsp + 56], rdx
    mov rdi, rax
    lea rsi, [rsp + 32]
    call scan_to
    mov rdi, [rsp + 56]
    lea rsi, [rsp + 32]
    call scan_to
    mov rdi, r12
    mov rsi, r14
    call hunk_new_text
    push rax
    push rdx
    lea rdi, [rip + text]
    mov rsi, rdx
    call sb_push_u64
    lea rdi, [rip + text]
    mov esi, 10
    call sb_push_byte
    pop rdx
    pop rsi
    lea rdi, [rip + text]
    call sb_push
    jmp 12b                     # the edits all refer to the current text: chosen hunks do not shift
15: mov rdi, [rip + text + SB_ptr]
    mov rsi, [rip + text + SB_len]
    call ws_apply
    test eax, eax
    jz .Lah_stale
.Lah_mark:
    xor ecx, ecx
16: cmp rcx, [r12 + RVF_hunks + VEC_len]
    jae 9f
    mov rdi, r12
    mov rsi, rcx
    mov r8, r13
    call chosen
    imul rdx, rcx, RVH_SIZE
    add rdx, [r12 + RVF_hunks + VEC_ptr]
    inc rcx
    test eax, eax
    jz 16b
    mov dword ptr [rdx + RVH_state], RVS_ACCEPTED
    jmp 16b
.Lah_stale:
    lea rdi, [rip + .Lchanged_toast]
    call app_toast
    xor ecx, ecx
17: cmp rcx, [r12 + RVF_hunks + VEC_len]
    jae 9f
    imul rdx, rcx, RVH_SIZE
    add rdx, [r12 + RVF_hunks + VEC_ptr]
    inc rcx
    cmp dword ptr [rdx + RVH_state], RVS_PENDING
    jne 17b
    mov dword ptr [rdx + RVH_state], RVS_STALE
    jmp 17b
9:  EPILOGUE

# chosen(RF*, i, r8 hunk or -1) -> eax 1 when hunk i is open and chosen (keeps rcx, rdx)
chosen:
    imul r9, rsi, RVH_SIZE
    add r9, [rdi + RVF_hunks + VEC_ptr]
    xor eax, eax
    cmp dword ptr [r9 + RVH_state], RVS_PENDING
    jne 1f
    test r8, r8
    js 2f
    cmp r8, rsi
    jne 1f
2:  inc eax
1:  ret

# hunk_old_range(RF*, RH*) -> rax start, rdx end in the text before
hunk_old_range:
    mov rcx, [rdi + RVF_ostart]
    mov r8, [rsi + RVH_ol]
    mov rax, [rcx + r8*8]
    add r8, [rsi + RVH_oc]
    mov rdx, [rcx + r8*8]
    ret

# hunk_new_text(RF*, RH*) -> rax ptr, rdx len of its lines after
hunk_new_text:
    mov rcx, [rdi + RVF_nstart]
    mov r8, [rsi + RVH_nl]
    mov rax, [rcx + r8*8]
    add r8, [rsi + RVH_nc]
    mov rdx, [rcx + r8*8]
    sub rdx, rax
    add rax, [rdi + RVF_new]
    ret

# hunk_growth(RF*, RH*) -> rax bytes it adds (negative when it removes)
hunk_growth:
    push rsi
    push rdi
    call hunk_new_text
    mov r9, rdx
    pop rdi
    pop rsi
    call hunk_old_range
    sub rdx, rax
    mov rax, r9
    sub rax, rdx
    ret

# scan_to(offset, *state): state (offset, line, line start) moved forward to the offset in scratch (the
#   current text); "LINE COL " of it goes on text
scan_to:
    PROLOGUE
    mov rbx, rsi
    mov r12, rdi
    mov rcx, [rbx]
    mov r8, [rip + scratch + SB_ptr]
1:  cmp rcx, r12
    jae 2f
    cmp byte ptr [r8 + rcx], 10
    jne 11f
    inc qword ptr [rbx + 8]
    lea rax, [rcx + 1]
    mov [rbx + 16], rax
11: inc rcx
    jmp 1b
2:  mov [rbx], rcx
    lea rdi, [rip + text]
    mov rsi, [rbx + 8]
    call sb_push_u64
    lea rdi, [rip + text]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + text]
    mov rsi, r12
    sub rsi, [rbx + 16]
    inc rsi
    call sb_push_u64
    lea rdi, [rip + text]
    mov esi, ' '
    call sb_push_byte
    EPILOGUE

# settle(RV*, file): a file whose hunks are all decided gets its state, and the proposer hears it
settle:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], rsi
    imul r12, rsi, RVF_SIZE
    add r12, [rbx + RVP_files + VEC_ptr]
    cmp dword ptr [r12 + RVF_state], RVS_PENDING
    jne 9f
    xor r13d, r13d              # accepted
    xor r14d, r14d              # stale
    xor ecx, ecx
1:  cmp rcx, [r12 + RVF_hunks + VEC_len]
    jae 2f
    imul rax, rcx, RVH_SIZE
    add rax, [r12 + RVF_hunks + VEC_ptr]
    inc rcx
    mov edx, [rax + RVH_state]
    cmp edx, RVS_PENDING
    je 9f                       # still open
    cmp edx, RVS_ACCEPTED
    jne 11f
    inc r13
11: cmp edx, RVS_STALE
    jne 1b
    inc r14
    jmp 1b
2:  mov r15d, RVS_ACCEPTED
    cmp r13, [r12 + RVF_hunks + VEC_len]
    je 3f
    mov r15d, RVS_PARTIAL
    test r13, r13
    jnz 3f
    mov r15d, RVS_REJECTED
    test r14, r14
    jz 3f
    mov r15d, RVS_STALE
3:  mov [r12 + RVF_state], r15d
    # 0 proposal P I accepted|rejected|stale|partial A N
    lea rdi, [rip + line]
    call sb_clear
    mov rdi, rbx
    call event_head
    lea rdi, [rip + line]
    mov rsi, [r12 + RVF_index]
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, ' '
    call sb_push_byte
    lea rcx, [rip + event_words]
    mov eax, r15d
    lea rdi, [rip + line]
    mov rsi, [rcx + rax*8]
    call sb_push_cstr
    cmp r15d, RVS_PARTIAL
    jne 4f
    lea rdi, [rip + line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + line]
    mov rsi, r13
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + line]
    mov rsi, [r12 + RVF_hunks + VEC_len]
    call sb_push_u64
4:  mov rdi, rbx
    call send_event
9:  EPILOGUE

# event_head(RV*): line gets "proposal P "
event_head:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + line]
    lea rsi, [rip + .Lev_proposal]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov rsi, [rbx + RVP_id]
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, ' '
    call sb_push_byte
    EPILOGUE

# send_event(RV*): "0 " and line to the proposer, when it listens
send_event:
    cmp dword ptr [rdi + RVP_events], 0
    je 1f
    cmp dword ptr [rdi + RVP_gone], 0
    jne 1f
    mov rdi, [rdi + RVP_ext]
    mov rsi, [rip + line + SB_ptr]
    mov rdx, [rip + line + SB_len]
    xor ecx, ecx
    xor r8d, r8d
    jmp extproto_ai_event
1:  ret

# check_done(RV*): every file decided: "0 proposal P done ACCEPTED REJECTED", and a rhun.propose call
#   waiting for it is answered
check_done:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + RVP_done], 0
    jne 9f
    mov rdi, rbx
    call pending_files
    test rax, rax
    jnz 9f
    mov dword ptr [rbx + RVP_done], 1
    cmp qword ptr [rbx + RVP_owner], 0
    je 10f
    mov rdi, rbx                # an offer: its owner hears it, once
    call offer_done
    jmp 9f
10: mov rdi, [rbx + RVP_ext]
    call ai_ext
    dec dword ptr [rax + AX_proposals]
    jns 1f
    mov dword ptr [rax + AX_proposals], 0
1:  xor r12d, r12d              # accepted, partly accepted
    xor r13d, r13d              # rejected, stale
    xor ecx, ecx
2:  cmp rcx, [rbx + RVP_files + VEC_len]
    jae 4f
    imul rax, rcx, RVF_SIZE
    add rax, [rbx + RVP_files + VEC_ptr]
    inc rcx
    mov edx, [rax + RVF_state]
    cmp edx, RVS_ACCEPTED
    je 3f
    cmp edx, RVS_PARTIAL
    je 3f
    inc r13
    jmp 2b
3:  inc r12
    jmp 2b
4:  lea rdi, [rip + line]
    call sb_clear
    mov rdi, rbx
    call event_head
    lea rdi, [rip + line]
    lea rsi, [rip + .Ldone]
    call sb_push_cstr
    lea rdi, [rip + line]
    mov rsi, r12
    call sb_push_u64
    lea rdi, [rip + line]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + line]
    mov rsi, r13
    call sb_push_u64
    mov rdi, rbx
    call send_event
    mov rdi, [rbx + RVP_waiter]
    test rdi, rdi
    jz 9f
    mov qword ptr [rbx + RVP_waiter], 0
    mov rsi, r12
    mov rdx, r13
    call tools_propose_done
9:  EPILOGUE

# ---------------- the tab closing, withdrawing, an extension stopping ----------------

# FN review_doc_gone(RV*): its Review tab closed: what was not decided is rejected, and it is forgotten
FN review_doc_gone
    PROLOGUE
    mov rbx, rdi
    mov qword ptr [rbx + RVP_doc], 0
    cmp dword ptr [rbx + RVP_offer], 0  # an offer: closed, unless its outcome still waits to be told
    je 0f
    mov rdi, rbx
    call offer_gone
    test eax, eax
    jnz 9f
    jmp 2f
0:  cmp dword ptr [rbx + RVP_done], 0
    jne 2f
    mov rdi, rbx
    mov rsi, -1
    mov rdx, -1
    xor ecx, ecx
    call review_decide
2:  mov rdi, rbx
    call forget
9:  EPILOGUE

# forget(RV*): out of the list, and freed
forget:
    PROLOGUE
    mov rbx, rdi
    xor ecx, ecx
3:  cmp rcx, [rip + proposals + VEC_len]
    jae 5f
    mov rax, [rip + proposals + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 4f
    inc rcx
    jmp 3b
4:  mov rdx, [rip + proposals + VEC_len]
    dec rdx
    mov [rip + proposals + VEC_len], rdx
    mov rdx, [rax + rdx*8]      # order does not matter: print-review sorts by id
    mov [rax + rcx*8], rdx
5:  mov rdi, rbx
    call proposal_free
    EPILOGUE

# FN review_unpropose(ext, id) -> rax 0, or the error reply: the proposer withdraws a proposal; its tab
#   closes and nothing more is said about it (files accepted stay changed)
FN review_unpropose
    PROLOGUE
    mov rbx, rdi
    mov rdi, rsi
    call find_proposal
    test rax, rax
    jz 8f
    cmp [rax + RVP_ext], rbx
    jne 8f
    cmp qword ptr [rax + RVP_waiter], 0
    jne 8f                      # a tool call's proposal ends with the call
    mov r12, rax
    mov dword ptr [r12 + RVP_gone], 1
    cmp dword ptr [r12 + RVP_done], 0
    jne 1f
    mov dword ptr [r12 + RVP_done], 1
    mov rdi, rbx
    call ai_ext
    dec dword ptr [rax + AX_proposals]
1:  mov rdi, r12
    call close_proposal
    xor eax, eax
    EPILOGUE
8:  lea rax, [rip + .Le_no_proposal]
    EPILOGUE

# close_proposal(RV*): its tab closes (which forgets it)
close_proposal:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + RVP_doc]
    test rdi, rdi
    jz 1f
    call doc_tab
    test rax, rax
    js 1f
    mov rdi, rax
    call app_close_tab_now
    EPILOGUE
1:  mov rdi, rbx
    call review_doc_gone
    EPILOGUE

# FN review_withdraw_waiter(RV*): the rhun.propose call it answers ended first: nothing waits for it
FN review_withdraw_waiter
    mov qword ptr [rdi + RVP_waiter], 0
    ret

# FN review_set_waiter(RV*, call): the rhun.propose call answered when it is done
FN review_set_waiter
    mov [rdi + RVP_waiter], rsi
    ret

# find_proposal(id) -> RV* or 0
find_proposal:
    xor ecx, ecx
1:  cmp rcx, [rip + proposals + VEC_len]
    jae 8f
    mov rax, [rip + proposals + VEC_ptr]
    mov rax, [rax + rcx*8]
    cmp [rax + RVP_id], rdi
    je 9f
    inc rcx
    jmp 1b
8:  xor eax, eax
9:  ret

# FN review_by_id(id) -> RV* or 0
FN review_by_id
    jmp find_proposal

# ---------------- keys, buttons ----------------

# FN review_of(doc) -> RV* the Review tab shows, or 0
FN review_of
    xor eax, eax
    test rdi, rdi
    jz 1f
    mov rcx, [rdi + DOC_diff]
    test rcx, rcx
    jz 1f
    mov rax, [rcx + DV_review]
1:  ret

# where(RV*, line) -> rax the file whose part holds the line (-1 above the first), rdx the hunk (-1 on
#   the file's header)
where:
    mov rax, -1
    mov rdx, -1
    xor ecx, ecx
1:  cmp rcx, [rdi + RVP_files + VEC_len]
    jae 3f
    imul r8, rcx, RVF_SIZE
    add r8, [rdi + RVP_files + VEC_ptr]
    mov r9d, [r8 + RVF_line]
    cmp rsi, r9
    jb 3f
    mov rax, rcx
    inc rcx
    jmp 1b
3:  test rax, rax
    js 9f
    imul r8, rax, RVF_SIZE
    add r8, [rdi + RVP_files + VEC_ptr]
    xor ecx, ecx
4:  cmp rcx, [r8 + RVF_hunks + VEC_len]
    jae 9f
    imul r9, rcx, RVH_SIZE
    add r9, [r8 + RVF_hunks + VEC_ptr]
    mov r9d, [r9 + RVH_line]
    cmp rsi, r9
    jb 9f
    mov rdx, rcx
    inc rcx
    jmp 4b
9:  ret

# FN review_key(keysym, cp, mods) -> eax 1 when the active Review tab took the key: ] [ next and previous
#   file, } { hunk, a r accept and reject the file, A R the hunk, Ctrl+Enter accept everything
FN review_key
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov rdi, [rip + g_doc]
    call review_of
    test rax, rax
    jz .Lrk_no
    mov rbx, rax
    mov r15, [rip + g_doc]
    cmp r12d, KEY_RETURN
    jne 1f
    test r14d, MOD_CTRL | MOD_SUPER
    jz .Lrk_no
    mov rdi, rbx
    mov rsi, -1
    mov rdx, -1
    mov ecx, 1
    call review_decide
    jmp .Lrk_yes
1:  test r14d, MOD_CTRL | MOD_ALT | MOD_SUPER
    jnz .Lrk_no
    mov rdi, r15
    mov rsi, [r15 + DOC_cur]
    call doc_line_of
    mov [rsp], rax
    mov rdi, rbx
    mov rsi, rax
    call where
    mov [rsp + 8], rdx
    mov rsi, rax
    cmp r13d, ']'
    je .Lrk_next_file
    cmp r13d, '['
    je .Lrk_prev_file
    cmp r13d, '}'
    je .Lrk_next_hunk
    cmp r13d, '{'
    je .Lrk_prev_hunk
    test rsi, rsi
    js .Lrk_no
    mov rdx, -1
    mov ecx, 1
    cmp r13d, 'a'
    je .Lrk_decide
    xor ecx, ecx
    cmp r13d, 'r'
    je .Lrk_decide
    mov rdx, [rsp + 8]
    test rdx, rdx
    jns 2f
    xor edx, edx                # on a header the first hunk
2:  mov ecx, 1
    cmp r13d, 'A'
    je .Lrk_decide
    xor ecx, ecx
    cmp r13d, 'R'
    je .Lrk_decide
.Lrk_no:
    xor eax, eax
    EPILOGUE
.Lrk_decide:
    mov rdi, rbx
    call review_decide
    jmp .Lrk_yes
.Lrk_next_file:
    inc rsi
    jmp 3f
.Lrk_prev_file:
    test rsi, rsi
    js .Lrk_yes
    imul rax, rsi, RVF_SIZE
    add rax, [rbx + RVP_files + VEC_ptr]
    mov eax, [rax + RVF_line]
    cmp rax, [rsp]
    jb 3f                       # below the header: to it
    dec rsi
    js .Lrk_yes
3:  cmp rsi, [rbx + RVP_files + VEC_len]
    jae .Lrk_yes
    imul rax, rsi, RVF_SIZE
    add rax, [rbx + RVP_files + VEC_ptr]
    mov esi, [rax + RVF_line]
    jmp .Lrk_go
.Lrk_next_hunk:
    # the first hunk header after the cursor's line
    mov rdi, rbx
    mov rsi, [rsp]
    mov edx, 1
    call hunk_line_near
    test rax, rax
    js .Lrk_yes
    mov rsi, rax
    jmp .Lrk_go
.Lrk_prev_hunk:
    mov rdi, rbx
    mov rsi, [rsp]
    xor edx, edx
    call hunk_line_near
    test rax, rax
    js .Lrk_yes
    mov rsi, rax
.Lrk_go:
    mov rdi, r15
    call doc_line_start
    mov [r15 + DOC_cur], rax
    mov [r15 + DOC_anchor], rax
    call ed_touch
.Lrk_yes:
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE

# hunk_line_near(RV*, line, after) -> rax the line of the nearest hunk header after (or before) it, -1
hunk_line_near:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, -1
    xor ecx, ecx
1:  cmp rcx, [rbx + RVP_files + VEC_len]
    jae 9f
    imul r8, rcx, RVF_SIZE
    add r8, [rbx + RVP_files + VEC_ptr]
    inc rcx
    xor edx, edx
2:  cmp rdx, [r8 + RVF_hunks + VEC_len]
    jae 1b
    imul r9, rdx, RVH_SIZE
    add r9, [r8 + RVF_hunks + VEC_ptr]
    inc rdx
    mov eax, [r9 + RVH_line]
    test r13d, r13d
    jz 3f
    cmp rax, r12
    jbe 2b
    mov r14, rax
    jmp 9f
3:  cmp rax, r12
    jae 9f
    mov r14, rax
    jmp 2b
9:  mov rax, r14
    EPILOGUE

# FN review_line_extra(doc, line, y, h): the Review tab's buttons on a line diffview_line drew: Accept
#   and Reject on the title (everything), on a file's header and on a hunk's, while open
FN review_line_extra
    PROLOGUE 48
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], edx
    mov [rsp + 20], ecx
    call review_of
    test rax, rax
    jz 9f
    mov rbx, rax
    cmp dword ptr [rbx + RVP_done], 0
    jne 9f
    mov dword ptr [rip + btn_dim], 0
    cmp dword ptr [rbx + RVP_offer], 0  # an offer's buttons are greyed while its card's lock lasts
    je 0f
    mov rdi, rbx
    call offer_locked
    test eax, eax
    jz 0f
    mov dword ptr [rip + btn_dim], 1
    mov dword ptr [rip + dim_drawn], 1
0:  mov rax, [rsp + 8]
    test rax, rax
    jnz 1f
    mov qword ptr [rsp + 24], -1    # the title: every file
    mov qword ptr [rsp + 32], -1
    lea r12, [rip + .Lb_accept_all]
    lea r13, [rip + .Lb_reject_all]
    cmp dword ptr [rbx + RVP_offer], 0  # an offer: one file, its Accept and Reject on the title
    je 5f
    lea r12, [rip + .Lb_accept]
    lea r13, [rip + .Lb_reject]
    jmp 5f
1:  mov rdi, rbx
    mov rsi, rax
    call where
    test rax, rax
    js 9f
    mov [rsp + 24], rax
    mov [rsp + 32], rdx
    imul r14, rax, RVF_SIZE
    add r14, [rbx + RVP_files + VEC_ptr]
    cmp dword ptr [r14 + RVF_state], RVS_PENDING
    jne 9f
    test rdx, rdx
    js 2f
    imul rcx, rdx, RVH_SIZE
    add rcx, [r14 + RVF_hunks + VEC_ptr]
    mov eax, [rcx + RVH_line]
    cmp rax, [rsp + 8]
    jne 9f                      # a line inside the hunk
    cmp dword ptr [rcx + RVH_state], RVS_PENDING
    jne 9f
    lea r12, [rip + .Lb_accept]
    lea r13, [rip + .Lb_reject]
    jmp 5f
2:  mov eax, [r14 + RVF_line]
    cmp rax, [rsp + 8]
    jne 9f
    cmp dword ptr [rbx + RVP_offer], 0  # an offer's file line: Edit Proposed Text (task 12), after the frame
    je 21f
    mov r15d, [rip + g_ed_x]
    add r15d, [rip + g_ed_w]
    sub r15d, [rip + g_mt + 4*MI_20]
    lea rdi, [rip + .Lb_edit]
    xor esi, esi
    mov edx, r15d
    call button
    test eax, eax
    jz 9f
    mov rax, [rbx + RVP_id]
    mov [rip + edit_id], rax
    mov dword ptr [rip + g_dirty], 1
    jmp 9f
21: lea r12, [rip + .Lb_accept]
    lea r13, [rip + .Lb_reject]
5:  # right to left: Reject, then Accept
    mov r15d, [rip + g_ed_x]
    add r15d, [rip + g_ed_w]
    sub r15d, [rip + g_mt + 4*MI_20]
    mov rdi, r13
    xor esi, esi
    mov edx, r15d
    call button
    mov r15d, edx
    test eax, eax
    jz 6f
    mov rdi, rbx
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 32]
    xor ecx, ecx
    call review_decide
    jmp 9f
6:  sub r15d, [rip + g_mt + 4*MI_6]
    mov rdi, r12
    mov esi, 1
    mov edx, r15d
    call button
    test eax, eax
    jz 9f
    mov rdi, rbx
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 32]
    mov ecx, 1
    call review_decide
9:  EPILOGUE

# button(label, primary, right) -> eax 1 when clicked, edx its left edge: drawn ending at right on the
#   caller's line ([rsp + 8] of the caller holds the line, [rsp + 16] y and [rsp + 20] h)
button:
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    mov r15d, edx
    mov rdi, rbx
    call strlen
    lea rdi, [rip + g_face_small]
    mov rsi, rbx
    mov rdx, rax
    call text_width
    add eax, [rip + g_mt + 4*MI_16]
    mov r13d, eax               # w
    mov r14d, [rbp + 16 + 16 + 4]   # the caller's h
    mov eax, [rbp + 16 + 16]        # and y
    mov [rsp], eax
    sub r15d, r13d
    mov dword ptr [rsp + 4], 0
    cmp dword ptr [rip + btn_dim], 0    # greyed (an offer's card still locked): drawn, not pressed
    je 0f
    xor r12d, r12d
    jmp 61f
0:  # an id per visible line and button
    mov rax, [rbp + 16 + 8]
    and eax, 0x3f
    lea edi, [rax*4 + ID_AI_REVIEW]
    add edi, r12d
    mov esi, r15d
    mov edx, [rsp]
    add edx, [rip + g_mt + 4*MI_2]
    mov ecx, r13d
    mov r8d, r14d
    sub r8d, [rip + g_mt + 4*MI_4]
    call ui_btn
    mov [rsp + 4], eax
61: COLOR r9d, T_BORDER
    COLOR eax, T_BG
    test dword ptr [rsp + 4], UB_HOVER
    jz 1f
    COLOR eax, T_HOVER
1:  test r12d, r12d
    jz 2f
    COLOR r9d, T_ACCENT
    COLOR eax, T_ACCENT
2:  mov edi, r15d
    mov esi, [rsp]
    add esi, [rip + g_mt + 4*MI_2]
    mov edx, r13d
    mov ecx, r14d
    sub ecx, [rip + g_mt + 4*MI_4]
    M r8d, MI_4
    push rax
    push rax
    call gfx_frame
    add rsp, 16
    COLOR eax, T_FG
    cmp dword ptr [rip + btn_dim], 0
    je 63f
    COLOR eax, T_MUTED
63: test r12d, r12d
    jz 3f
    COLOR eax, T_ACCENT_FG
3:  lea rdi, [rip + g_face_small]
    mov esi, r15d
    mov edx, [rsp]
    mov ecx, r13d
    mov r8d, r14d
    mov r9, rbx
    push rax
    push rax
    call ui_text_center
    add rsp, 16
    xor eax, eax
    test dword ptr [rsp + 4], UB_CLICK
    setnz al
    mov edx, r15d
    EPILOGUE

# ---------------- offers: rhun's own proposals for an owner ----------------

# FN review_offer(RVO*, ctx, label cstr, path cstr or 0, OT*, show) -> rax the offer's id, or 0. One file:
#   its text before and after (copied, at most RVP_TEXT_MAX each). Its tab never takes the keys: with show
#   1 it becomes the active tab unless a document has the keys (then, and with show 0, it opens behind the
#   active tab); the keyboard stays where it was.
FN review_offer
    PROLOGUE 64
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov [rsp + 24], rcx
    mov [rsp + 32], r8
    mov [rsp + 40], r9d
    mov rax, [r8 + OT_oldlen]
    cmp rax, RVP_TEXT_MAX
    ja 8f
    mov rax, [r8 + OT_newlen]
    cmp rax, RVP_TEXT_MAX
    ja 8f
    mov edi, RVP_SIZE
    call mem_alloc
    mov r15, rax
    mov rdi, rax
    xor esi, esi
    mov edx, RVP_SIZE
    call memset
    mov rax, [rsp]
    mov [r15 + RVP_owner], rax
    mov rax, [rsp + 8]
    mov [r15 + RVP_ctx], rax
    mov rdi, [rsp + 16]
    call strlen
    mov rsi, rax
    mov rdi, [rsp + 16]
    call clean_label
    mov [r15 + RVP_label], rax
    # its one file
    lea rdi, [rip + .Lrf_tmp]
    mov ecx, RVF_SIZE
    xor eax, eax
    rep stosb
    lea r12, [rip + .Lrf_tmp]
    mov qword ptr [r12 + RVF_index], 1
    mov rdi, [rsp + 24]
    test rdi, rdi
    jz 1f
    call dup_cstr
    mov [r12 + RVF_path], rax
    mov rdi, [rsp + 24]
    call path_basename_c
    jmp 2f
1:  mov rdi, [r15 + RVP_label]
    call dup_cstr
2:  mov [r12 + RVF_name], rax
    mov rbx, [rsp + 32]
    mov rdi, [rbx + OT_old]
    mov rsi, [rbx + OT_oldlen]
    call text_dup
    mov [r12 + RVF_old], rax
    mov [r12 + RVF_oldlen], rdx
    mov rdi, [rbx + OT_new]
    mov rsi, [rbx + OT_newlen]
    call text_dup
    mov [r12 + RVF_new], rax
    mov [r12 + RVF_newlen], rdx
    mov rdi, r12
    call file_diff
    lea rdi, [r15 + RVP_files]
    mov esi, RVF_SIZE
    call vec_push
    mov rdi, rax
    lea rsi, [rip + .Lrf_tmp]
    mov edx, RVF_SIZE
    call memcpy
    inc qword ptr [rip + next_id]
    mov rax, [rip + next_id]
    mov [r15 + RVP_id], rax
    lea rdi, [rip + proposals]
    mov esi, 8
    call vec_push
    mov [rax], r15
    # its tab, without the keys
    mov eax, [rip + g_focus]
    mov [rsp + 44], eax
    mov rax, [rip + g_tab_cur]
    mov [rsp + 48], rax
    mov rdi, r15
    call open_tab
    cmp dword ptr [rsp + 40], 0
    je 3f
    cmp dword ptr [rsp + 44], FOCUS_EDITOR
    jne 4f
3:  mov rdi, [rsp + 48]         # behind: the tab that was active is again
    test rdi, rdi
    js 4f
    call app_activate_tab
4:  mov eax, [rsp + 44]
    mov [rip + g_focus], eax
    mov dword ptr [rip + g_dirty], 1
    mov rax, [r15 + RVP_id]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# text_dup(ptr, len) -> rax an owned copy with a NUL after it, rdx len
text_dup:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rsi + 1]
    call mem_alloc
    mov r13, rax
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r12
    call memcpy
    mov byte ptr [r13 + r12], 0
    mov rax, r13
    mov rdx, r12
    EPILOGUE

# offer_done(RV*): every change of an offer is decided, or its tab closed: the owner hears it once (unless
#   it was closed by its owner: RVP_gone)
offer_done:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + RVP_gone], 0
    jne 9f
    mov dword ptr [rbx + RVP_gone], 1
    mov rax, [rbx + RVP_files + VEC_ptr]
    mov r12, rax                # its one file
    mov r13d, OFFER_CLOSED
    cmp dword ptr [rbx + RVP_closing], 0
    jne 2f
    mov r13d, OFFER_REJECT
    mov eax, [r12 + RVF_state]
    cmp eax, RVS_ACCEPTED
    je 1f
    cmp eax, RVS_PARTIAL
    jne 2f
1:  mov r13d, OFFER_ACCEPT
    cmp qword ptr [r12 + RVF_hunks + VEC_len], 0
    je 11f
    lea rdi, [rip + scratch]    # the text before with the accepted changes
    call sb_clear
    mov rdi, r12
    xor esi, esi
    call build_text
    mov rdx, [rip + scratch + SB_ptr]
    mov rcx, [rip + scratch + SB_len]
    jmp 3f
11: mov rdx, [r12 + RVF_new]    # nothing to decide: the proposed text
    mov rcx, [r12 + RVF_newlen]
    jmp 3f
2:  xor edx, edx
    xor ecx, ecx
3:  mov rax, [rbx + RVP_owner]
    mov rdi, [rbx + RVP_ctx]
    mov esi, r13d
    xor r8d, r8d
    call [rax + RVO_done]
9:  EPILOGUE

# FN review_offer_accept(id) -> eax 1 when it was an offer still undecided: every change accepted
FN review_offer_accept
    PROLOGUE
    call find_proposal
    test rax, rax
    jz 8f
    cmp qword ptr [rax + RVP_owner], 0
    je 8f
    cmp dword ptr [rax + RVP_done], 0
    jne 8f
    mov rdi, rax
    mov rsi, -1
    mov rdx, -1
    mov ecx, 1
    call review_decide
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN review_offer_reject(id) -> eax 1 when it was an offer still undecided: every change rejected
FN review_offer_reject
    PROLOGUE
    call find_proposal
    test rax, rax
    jz 8f
    cmp qword ptr [rax + RVP_owner], 0
    je 8f
    cmp dword ptr [rax + RVP_done], 0
    jne 8f
    mov rdi, rax
    mov rsi, -1
    mov rdx, -1
    xor ecx, ecx
    call review_decide
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN review_offer_close(id): its tab closes and its owner hears nothing more
FN review_offer_close
    PROLOGUE
    call find_proposal
    test rax, rax
    jz 9f
    cmp qword ptr [rax + RVP_owner], 0
    je 9f
    mov dword ptr [rax + RVP_gone], 1
    mov rdi, rax
    call close_proposal
9:  EPILOGUE

# FN review_offer_by_label(RVO*, label cstr) -> rax the id of that owner's open offer with this label
#   (as it was given, cleaned), or 0
FN review_offer_by_label
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp rbx, [rip + proposals + VEC_len]
    jae 8f
    mov rax, [rip + proposals + VEC_ptr]
    mov r14, [rax + rbx*8]
    inc rbx
    cmp [r14 + RVP_owner], r12
    jne 1b
    mov rdi, [r14 + RVP_label]
    mov rsi, r13
    call strcmp_eq
    test eax, eax
    jz 1b
    mov rax, [r14 + RVP_id]
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN review_offers_close(RVO*) -> eax how many of that owner's offers closed (their owner hears nothing)
FN review_offers_close
    PROLOGUE
    mov r12, rdi
    xor r13d, r13d
1:  xor ebx, ebx
2:  cmp rbx, [rip + proposals + VEC_len]
    jae 9f
    mov rax, [rip + proposals + VEC_ptr]
    mov r14, [rax + rbx*8]
    inc rbx
    cmp [r14 + RVP_owner], r12
    jne 2b
    inc r13d
    mov dword ptr [r14 + RVP_gone], 1
    mov rdi, r14
    call close_proposal         # it leaves the list: start again
    jmp 1b
9:  mov eax, r13d
    EPILOGUE

# ---------------- tests ----------------

# FN review_dump(sb): per proposal "proposal=ID label=LABEL done=0|1", per file "proposal=ID file=I
#   path=P +A -D state=..." and per hunk "  hunk=J -ol,oc +nl,nc state=..." (print-review)
FN review_dump
    PROLOGUE 16
    mov r15, rdi
    mov qword ptr [rsp], 0      # the last id printed
.Lrd_next:
    # proposals in the order of their ids
    xor ebx, ebx
    xor ecx, ecx
1:  cmp rcx, [rip + proposals + VEC_len]
    jae 2f
    mov rax, [rip + proposals + VEC_ptr]
    mov rax, [rax + rcx*8]
    inc rcx
    mov rdx, [rax + RVP_id]
    cmp rdx, [rsp]
    jbe 1b
    test rbx, rbx
    jz 11f
    cmp rdx, [rbx + RVP_id]
    jae 1b
11: mov rbx, rax
    jmp 1b
2:  test rbx, rbx
    jz 9f
    mov rax, [rbx + RVP_id]
    mov [rsp], rax
    mov rdi, r15
    lea rsi, [rip + .Ld_proposal]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + RVP_id]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_label]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + RVP_label]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_done]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + RVP_done]
    call sb_push_u64
    cmp dword ptr [rbx + RVP_offer], 0
    je 0f
    mov rdi, r15
    lea rsi, [rip + .Ld_offer]
    call sb_push_cstr
0:  mov rdi, r15
    mov esi, 10
    call sb_push_byte
    xor r12d, r12d
3:  cmp r12, [rbx + RVP_files + VEC_len]
    jae .Lrd_next
    imul r13, r12, RVF_SIZE
    add r13, [rbx + RVP_files + VEC_ptr]
    inc r12
    mov rdi, r15
    lea rsi, [rip + .Ld_proposal]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + RVP_id]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_file]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, r12
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_path]
    call sb_push_cstr
    mov rdi, r13
    call show_path
    mov rdi, r15
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_plus]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [r13 + RVF_add]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_minus]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [r13 + RVF_del]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    mov eax, [r13 + RVF_state]
    lea rcx, [rip + dump_words]
    mov rdi, r15
    mov rsi, [rcx + rax*8]
    call sb_push_cstr
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    xor r14d, r14d
4:  cmp r14, [r13 + RVF_hunks + VEC_len]
    jae 3b
    imul rax, r14, RVH_SIZE
    add rax, [r13 + RVF_hunks + VEC_ptr]
    mov [rsp + 8], rax
    inc r14
    mov rdi, r15
    lea rsi, [rip + .Ld_hunk]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, r14
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_hminus]
    call sb_push_cstr
    mov rax, [rsp + 8]
    mov rsi, [rax + RVH_ol]
    inc rsi
    mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    mov esi, ','
    call sb_push_byte
    mov rax, [rsp + 8]
    mov rdi, r15
    mov rsi, [rax + RVH_oc]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_hplus]
    call sb_push_cstr
    mov rax, [rsp + 8]
    mov rsi, [rax + RVH_nl]
    inc rsi
    mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    mov esi, ','
    call sb_push_byte
    mov rax, [rsp + 8]
    mov rdi, r15
    mov rsi, [rax + RVH_nc]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    mov rax, [rsp + 8]
    mov eax, [rax + RVH_state]
    lea rcx, [rip + dump_words]
    mov rdi, r15
    mov rsi, [rcx + rax*8]
    call sb_push_cstr
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    jmp 4b
9:  EPILOGUE

# FN review_current() -> RV*: the one the active tab shows, else the newest open one, or 0
FN review_current
    mov rdi, [rip + g_doc]
    call review_of
    test rax, rax
    jnz 9f
    xor ecx, ecx
1:  cmp rcx, [rip + proposals + VEC_len]
    jae 9f
    mov rdx, [rip + proposals + VEC_ptr]
    mov rdx, [rdx + rcx*8]
    inc rcx
    test rax, rax
    jz 2f
    mov r8, [rdx + RVP_id]
    cmp r8, [rax + RVP_id]
    jbe 1b
2:  mov rax, rdx
    jmp 1b
9:  ret

# ---------------- offers (phase 4 tasks 11 and 12) ----------------
#
# An offer is a proposal of rhun's own for an owner (an agent's request to edit one file, agentoffer.s): the
# same tab, drawing and keys as an extension's proposal, but nothing is ever applied. Its outcome (accepted
# with the text as it stands, rejected, the tab closed, everything taken out) goes to the owner (RVO_done)
# from review_tick, after the frame, never from inside a drawing or a tab's closing; a close waits out the
# card's lock (RVO_locked), every other decision is refused while it lasts. Once decided the tab stays, read
# only, until the owner closes it (review_offer_close); the owner withdrawing it first is never told
# anything. Its tab never takes the keyboard (offer_tab).
#
#   review_offer(RVO*, ctx, label, path or 0, TX*, show) -> rax id or 0
#   review_offer_close(id); review_offers_close() -> eax n; review_offer_show(id)
#   review_offer_text(id) -> rax ptr, rdx len, ecx edited, r8d reverted; review_offer_before(id) -> rax, rdx
#   review_offer_dump(id, sb); review_tick(); review_timeout() -> eax ms or -1

# FN review_offer(RVO*, ctx, label cstr, path cstr or 0, TX*, show) -> rax its id, or 0 when there is nothing
#   to show (the two texts equal, or one over 4 MB). Its tab becomes the active one with show while the
#   keyboard is not in the editor, and the keyboard stays where it was; otherwise it waits behind the active tab
FN review_offer
    PROLOGUE 48
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov [rsp + 24], rcx
    mov rbx, r8
    mov [rsp + 32], r9d
    xor eax, eax
    cmp qword ptr [rbx + TX_oldlen], RVP_TEXT_MAX
    ja 9f
    cmp qword ptr [rbx + TX_newlen], RVP_TEXT_MAX
    ja 9f
    mov rcx, [rbx + TX_oldlen]
    cmp rcx, [rbx + TX_newlen]
    jne 1f
    mov rdi, [rbx + TX_old]
    mov rsi, [rbx + TX_new]
    mov rdx, rcx
    call memeq
    test eax, eax
    jz 1f
    xor eax, eax
    jmp 9f
1:  mov edi, RVP_SIZE
    call mem_alloc
    mov r15, rax
    mov dword ptr [r15 + RVP_offer], 1
    mov rax, [rsp]
    mov [r15 + RVP_owner], rax
    mov rax, [rsp + 8]
    mov [r15 + RVP_ctx], rax
    mov rdi, [rsp + 16]
    call strlen
    mov rdi, [rsp + 16]
    mov rsi, rax
    call clean_label
    mov [r15 + RVP_label], rax
    mov rdi, [rbx + TX_new]
    mov rsi, [rbx + TX_newlen]
    call ai_dup
    mov [r15 + RVP_orig], rax
    mov rax, [rbx + TX_newlen]
    mov [r15 + RVP_origlen], rax
    # its one file
    lea rdi, [rip + .Lrf_tmp]
    mov ecx, RVF_SIZE
    xor eax, eax
    rep stosb
    lea r12, [rip + .Lrf_tmp]
    mov qword ptr [r12 + RVF_index], 1
    mov rdi, [rsp + 24]
    test rdi, rdi
    jz 2f
    call dup_cstr
    mov [r12 + RVF_path], rax
    mov rdi, rax
    call path_basename_c
    jmp 3f
2:  mov rdi, [r15 + RVP_label]
    call dup_cstr
3:  mov [r12 + RVF_name], rax
    mov rdi, [rbx + TX_old]
    mov rsi, [rbx + TX_oldlen]
    call ai_dup
    mov [r12 + RVF_old], rax
    mov rax, [rbx + TX_oldlen]
    mov [r12 + RVF_oldlen], rax
    mov rdi, [rbx + TX_new]
    mov rsi, [rbx + TX_newlen]
    call ai_dup
    mov [r12 + RVF_new], rax
    mov rax, [rbx + TX_newlen]
    mov [r12 + RVF_newlen], rax
    mov rdi, r12
    call file_diff
    mov rdi, r12
    call offer_cap
    lea rdi, [r15 + RVP_files]
    mov esi, RVF_SIZE
    call vec_push
    mov rdi, rax
    mov rsi, r12
    mov edx, RVF_SIZE
    call memcpy
    inc qword ptr [rip + next_id]
    mov rax, [rip + next_id]
    mov [r15 + RVP_id], rax
    lea rdi, [rip + proposals]
    mov esi, 8
    call vec_push
    mov [rax], r15
    mov rdi, r15
    mov esi, [rsp + 32]
    call offer_tab
    mov rax, [r15 + RVP_id]
9:  EPILOGUE

# offer_cap(RF*): more than OFFER_HUNKS_MAX changes are one, from the first to the last
offer_cap:
    mov rax, [rdi + RVF_hunks + VEC_len]
    cmp rax, OFFER_HUNKS_MAX
    jbe 9f
    mov rsi, [rdi + RVF_hunks + VEC_ptr]
    imul rcx, rax, RVH_SIZE
    lea rdx, [rsi + rcx - RVH_SIZE]
    mov rcx, [rdx + RVH_ol]
    add rcx, [rdx + RVH_oc]
    sub rcx, [rsi + RVH_ol]
    mov [rsi + RVH_oc], rcx
    mov rcx, [rdx + RVH_nl]
    add rcx, [rdx + RVH_nc]
    sub rcx, [rsi + RVH_nl]
    mov [rsi + RVH_nc], rcx
    mov qword ptr [rdi + RVF_hunks + VEC_len], 1
9:  ret

# offer_tab(RV*, show): the offer's Review tab, after the active one (after the pinned ones). Never through
#   app_add_tab (it activates the tab and gives the editor the keyboard): made active only with show, while
#   the keyboard is outside the editor (the panel, its box, the terminal), and the keyboard put back; with
#   the keyboard in the editor (a document, its find field, Settings, the Extensions page) it waits behind
offer_tab:
    PROLOGUE
    mov rbx, rdi
    mov r15d, esi
    call doc_new
    mov r12, rax
    or dword ptr [r12 + DOC_flags], DF_READONLY
    mov edi, DV_SIZE
    call mem_alloc
    mov r13, rax
    mov [r12 + DOC_diff], rax
    mov [r13 + DV_review], rbx
    mov rdi, [rbx + RVP_label]
    call dup_cstr
    mov [r13 + DV_name], rax
    mov [r12 + DOC_name], rax
    mov [rbx + RVP_doc], r12
    mov rdi, r12
    call doc_language_refresh
    lea rdi, [rip + g_tabs]
    mov esi, TAB_SIZE
    call vec_push               # zeroed: not pinned
    mov qword ptr [rax + TAB_kind], TAB_DOC
    mov [rax + TAB_doc], r12
    mov r13, [rip + g_tabs + VEC_len]
    dec r13
    mov r14, [rip + g_tab_cur]
    inc r14
    call tabs_pinned
    cmp r14, rax
    cmovb r14, rax
    mov rdi, r13
    mov rsi, r14
    call tab_move
    mov rdi, rbx
    call build_doc
    mov rax, [rbx + RVP_files + VEC_ptr]
    mov eax, [rax + RVF_line]
    mov rdi, r12
    mov rsi, rax
    call doc_line_start
    mov [r12 + DOC_cur], rax
    mov [r12 + DOC_anchor], rax
    cmp qword ptr [rip + g_tab_cur], 0
    jl 2f                       # no active tab: it is the one
    test r15d, r15d
    jz 8f
    mov eax, [rip + g_focus]
    cmp eax, FOCUS_EDITOR
    je 8f
    cmp eax, FOCUS_FIND
    je 8f
    cmp eax, FOCUS_SETTINGS
    je 8f
    cmp eax, FOCUS_EXT_SEARCH
    je 8f
2:  mov r13d, [rip + g_focus]
    mov rdi, r14
    call app_activate_tab
    mov [rip + g_focus], r13d
8:  mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# offer_locked(RV*) -> eax ms its owner's lock still lasts, 0 none
offer_locked:
    mov rax, [rdi + RVP_owner]
    test rax, rax
    jz 1f
    mov rdi, [rdi + RVP_ctx]
    jmp [rax + RVO_locked]
1:  xor eax, eax
    ret

# offer_decide(RV*, file, hunk, accept): the user's choice in an offer's tab: nothing while the card's lock
#   lasts (and nothing kept for later); the file or everything: the offer is decided (offer_finish)
offer_decide:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    mov rdi, rbx
    call offer_locked
    test eax, eax
    jnz 9f
    test r12, r12
    js 1f
    test r13, r13
    jns 2f
1:  mov rdi, rbx                # the whole: with the text its edit holds now
    call scratch_take
    mov rdi, rbx
    mov esi, r14d
    call offer_finish
    jmp 9f
2:  mov rax, [rbx + RVP_files + VEC_ptr]   # a change (task 12)
    cmp r13, [rax + RVF_hunks + VEC_len]
    jae 9f
    imul rcx, r13, RVH_SIZE
    add rcx, [rax + RVF_hunks + VEC_ptr]
    cmp dword ptr [rcx + RVH_state], RVS_PENDING
    jne 9f
    mov dword ptr [rcx + RVH_state], RVS_ACCEPTED   # accepted: only marked
    test r14d, r14d
    jnz 3f
    mov dword ptr [rcx + RVH_state], RVS_REJECTED   # rejected: taken out of the proposed text
    lea rdi, [rip + scratch]
    call sb_clear
    mov rdi, [rbx + RVP_files + VEC_ptr]
    mov esi, 2
    call build_text
    mov rdi, rbx
    mov rsi, [rip + scratch + SB_ptr]
    mov rdx, [rip + scratch + SB_len]
    call offer_retext
    mov rdi, rbx                # its edit, when open, shows the text too
    call scratch_put
3:  mov rdi, rbx
    call offer_all_toast
    mov rdi, rbx
    call build_doc
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# offer_finish(RV*, accept): decided: accepted (its text as it stands; the text before: reverted) or rejected;
#   the outcome waits for review_tick, the tab shows it and its buttons go
offer_finish:
    PROLOGUE
    mov rbx, rdi
    mov r15d, OFFER_REJECT
    mov r14d, RVS_REJECTED
    mov r12, [rbx + RVP_files + VEC_ptr]
    test esi, esi
    jz 1f
    mov r15d, OFFER_ACCEPT
    mov r14d, RVS_ACCEPTED
    mov rcx, [r12 + RVF_newlen]
    cmp rcx, [r12 + RVF_oldlen]
    jne 1f
    mov rdi, [r12 + RVF_new]
    mov rsi, [r12 + RVF_old]
    mov rdx, rcx
    call memeq
    test eax, eax
    jz 1f
    mov r15d, OFFER_REVERTED
    mov r14d, RVS_REJECTED
1:  mov dword ptr [rbx + RVP_done], 1
    mov [rbx + RVP_pend], r15d
    mov [r12 + RVF_state], r14d
    mov rdi, rbx
    call build_doc
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE

# offer_gone(RV*) -> eax 1 when it stays for review_tick: its tab closed; undecided, that is its outcome
offer_gone:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    cmp qword ptr [rbx + RVP_owner], 0
    je 9f
    cmp dword ptr [rbx + RVP_done], 0
    jne 1f
    mov dword ptr [rbx + RVP_done], 1
    mov dword ptr [rbx + RVP_pend], OFFER_CLOSED
1:  xor eax, eax
    cmp dword ptr [rbx + RVP_pend], 0
    setne al
9:  EPILOGUE

# offer_title(RV*): the title line's part for an offer (line): "N changes", then its state once decided
offer_title:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + RVP_files + VEC_ptr]
    lea rdi, [rip + line]
    mov rsi, [r12 + RVF_hunks + VEC_len]
    call sb_push_u64
    lea rsi, [rip + .Lo_changes]
    cmp qword ptr [r12 + RVF_hunks + VEC_len], 1
    jne 1f
    lea rsi, [rip + .Lo_change]
1:  lea rdi, [rip + line]
    call sb_push_cstr
    cmp dword ptr [rbx + RVP_done], 0
    jne 3f
    mov rdi, r12                # task 12: some decided, the others still to decide
    call hunks_pending
    test rax, rax
    jz 9f
    cmp rax, [r12 + RVF_hunks + VEC_len]
    je 9f
    push rax
    push rax
    lea rdi, [rip + line]
    lea rsi, [rip + .Lcomma]
    call sb_push_cstr
    pop rsi
    pop rsi
    lea rdi, [rip + line]
    call sb_push_u64
    lea rdi, [rip + line]
    lea rsi, [rip + .Lto_decide]
    call sb_push_cstr
    jmp 9f
3:  lea rdi, [rip + line]
    lea rsi, [rip + .Ldot]
    call sb_push_cstr
    mov rdi, r12
    call file_state_word
    lea rdi, [rip + line]
    mov rsi, rax
    call sb_push_cstr
9:  EPILOGUE

# cur_offer() -> rax the offer the active tab shows, or 0
cur_offer:
    PROLOGUE
    mov rdi, [rip + g_doc]
    call review_of
    test rax, rax
    jz 9f
    cmp dword ptr [rax + RVP_offer], 0
    jne 9f
    xor eax, eax
9:  EPILOGUE

# cur_text(RV*) -> rax ptr, rdx len of its proposed text as it stands, ecx 1 when it is not the text offered
#   (edited), r8d 1 when it is the text before (reverted)
cur_text:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + RVP_files + VEC_ptr]
    xor r13d, r13d
    mov rcx, [r12 + RVF_newlen]
    cmp rcx, [rbx + RVP_origlen]
    jne 1f
    mov rdi, [r12 + RVF_new]
    mov rsi, [rbx + RVP_orig]
    mov rdx, rcx
    call memeq
    test eax, eax
    jnz 2f
1:  mov r13d, 1
2:  xor r14d, r14d
    mov rcx, [r12 + RVF_newlen]
    cmp rcx, [r12 + RVF_oldlen]
    jne 3f
    mov rdi, [r12 + RVF_new]
    mov rsi, [r12 + RVF_old]
    mov rdx, rcx
    call memeq
    mov r14d, eax
3:  mov rax, [r12 + RVF_new]
    mov rdx, [r12 + RVF_newlen]
    mov ecx, r13d
    mov r8d, r14d
    EPILOGUE

# offer_by_id(id) -> rax the offer, or 0
offer_by_id:
    PROLOGUE
    call find_proposal
    test rax, rax
    jz 9f
    cmp dword ptr [rax + RVP_offer], 0
    jne 9f
    xor eax, eax
9:  EPILOGUE

# FN review_offer_close(id): its owner withdraws it: nothing more is said, its tab closes
FN review_offer_close
    PROLOGUE
    call offer_by_id
    test rax, rax
    jz 9f
    mov rbx, rax
    mov qword ptr [rbx + RVP_owner], 0
    mov dword ptr [rbx + RVP_pend], 0
    mov dword ptr [rbx + RVP_done], 1
    mov rdi, rbx
    call close_proposal
9:  EPILOGUE

# FN review_offers_close() -> eax how many offers were closed (their owners are not told)
FN review_offers_close
    PROLOGUE
    xor r12d, r12d
1:  xor ecx, ecx
2:  cmp rcx, [rip + proposals + VEC_len]
    jae 9f
    mov rax, [rip + proposals + VEC_ptr]
    mov rax, [rax + rcx*8]
    inc rcx
    cmp dword ptr [rax + RVP_offer], 0
    je 2b
    mov rdi, [rax + RVP_id]
    call review_offer_close
    inc r12d
    jmp 1b
9:  mov eax, r12d
    EPILOGUE

# FN review_offer_show(id): its tab becomes the active one after the frame (review_tick); the keyboard stays
#   where it is
FN review_offer_show
    mov [rip + show_id], rdi
    mov dword ptr [rip + g_dirty], 1
    ret

# offer_show_now(id)
offer_show_now:
    PROLOGUE
    call offer_by_id
    test rax, rax
    jz 9f
    mov rdi, [rax + RVP_doc]
    test rdi, rdi
    jz 9f
    call doc_tab
    test rax, rax
    js 9f
    mov ebx, [rip + g_focus]
    mov rdi, rax
    call app_activate_tab
    mov [rip + g_focus], ebx
9:  EPILOGUE

# FN review_offer_text(id) -> rax ptr, rdx len of the proposed text as it stands, ecx 1 edited (not the text
#   offered), r8d 1 reverted (the text before); rax 0 when there is no such offer
FN review_offer_text
    PROLOGUE
    call offer_by_id
    test rax, rax
    jz 8f
    mov rdi, rax
    call cur_text
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    EPILOGUE

# FN review_offer_before(id) -> rax ptr, rdx len of its text before (rax 0: no such offer)
FN review_offer_before
    PROLOGUE
    call offer_by_id
    test rax, rax
    jz 8f
    mov rax, [rax + RVP_files + VEC_ptr]
    mov rdx, [rax + RVF_oldlen]
    mov rax, [rax + RVF_old]
    EPILOGUE
8:  xor edx, edx
    EPILOGUE

# FN review_offer_dump(id, sb): "offer=ID file=PATH label=LABEL changes=N decided=N edited=0|1 scratch=0|1
#   shown=0|1 done=0|1 locked=0|1", or "offer=none"
FN review_offer_dump
    PROLOGUE
    mov r15, rsi
    call offer_by_id
    test rax, rax
    jnz 1f
    mov rdi, r15
    lea rsi, [rip + .Lo_none]
    call sb_push_cstr
    EPILOGUE
1:  mov rbx, rax
    mov r12, [rbx + RVP_files + VEC_ptr]
    mov rdi, r15
    lea rsi, [rip + .Lo_offer]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + RVP_id]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lo_file]
    call sb_push_cstr
    mov rdi, r12
    call show_path
    mov rdi, r15
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Ld_label]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [rbx + RVP_label]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rip + .Lo_changes_d]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [r12 + RVF_hunks + VEC_len]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lo_decided]
    call sb_push_cstr
    xor r13d, r13d              # changes decided
    xor ecx, ecx
2:  cmp rcx, [r12 + RVF_hunks + VEC_len]
    jae 3f
    imul rax, rcx, RVH_SIZE
    add rax, [r12 + RVF_hunks + VEC_ptr]
    inc rcx
    cmp dword ptr [rax + RVH_state], RVS_PENDING
    je 2b
    inc r13
    jmp 2b
3:  mov rdi, r15
    mov rsi, r13
    call sb_push_u64
    mov rdi, rbx
    call cur_text
    mov r13d, ecx
    mov rdi, r15
    lea rsi, [rip + .Lo_edited]
    call sb_push_cstr
    mov rdi, r15
    mov esi, r13d
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lo_scratch]
    call sb_push_cstr
    xor esi, esi
    cmp qword ptr [rbx + RVP_scratch], 0
    je 4f
    mov rdi, [rbx + RVP_scratch]
    call extproto_doc
    xor esi, esi
    test rax, rax
    setnz sil
4:  mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lo_shown]
    call sb_push_cstr
    call cur_offer
    xor esi, esi
    cmp rax, rbx
    sete sil
    mov rdi, r15
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Ld_done]
    call sb_push_cstr
    mov rdi, r15
    mov esi, [rbx + RVP_done]
    call sb_push_u64
    mov rdi, r15
    lea rsi, [rip + .Lo_locked]
    call sb_push_cstr
    mov rdi, rbx
    call offer_locked
    xor esi, esi
    test eax, eax
    setnz sil
    mov rdi, r15
    call sb_push_u64
    EPILOGUE

# FN review_tick(): outcomes decided since the last pass go to their owners (an owner that withdrew hears
#   nothing; a close waits out the card's lock); a tab drawn greyed is drawn again once the lock is over
FN review_tick
    PROLOGUE
    mov rdi, [rip + show_id]    # a card's "Review the change"
    test rdi, rdi
    jz 71f
    mov qword ptr [rip + show_id], 0
    call offer_show_now
71: mov rdi, [rip + edit_id]    # task 12: its button's Edit Proposed Text
    test rdi, rdi
    jz 72f
    mov qword ptr [rip + edit_id], 0
    call offer_by_id
    test rax, rax
    jz 72f
    mov rdi, rax
    call offer_edit_open
72: cmp qword ptr [rip + orphans + VEC_len], 0
    je 73f
    call orphans_close
73: call scratch_follow
    cmp dword ptr [rip + dim_drawn], 0
    je 1f
    call cur_offer
    test rax, rax
    jz 0f
    mov rdi, rax
    call offer_locked
    test eax, eax
    jnz 1f
0:  mov dword ptr [rip + dim_drawn], 0
    mov dword ptr [rip + g_dirty], 1
1:  xor r12d, r12d
2:  cmp r12, [rip + proposals + VEC_len]
    jae 8f
    mov rax, [rip + proposals + VEC_ptr]
    mov rbx, [rax + r12*8]
    inc r12
    cmp dword ptr [rbx + RVP_pend], 0
    je 2b
    mov r13, [rbx + RVP_owner]
    test r13, r13
    jnz 3f
    mov dword ptr [rbx + RVP_pend], 0     # withdrawn: nothing is said
    cmp qword ptr [rbx + RVP_doc], 0
    jne 2b
    mov rdi, rbx
    call forget
    xor r12d, r12d
    jmp 2b
3:  cmp dword ptr [rbx + RVP_pend], OFFER_CLOSED
    jne 4f
    mov rdi, rbx
    call offer_locked
    test eax, eax
    jnz 2b                      # a close waits for the card's lock to end
4:  mov r14, [rbx + RVP_id]
    mov r15d, [rbx + RVP_pend]
    mov dword ptr [rbx + RVP_pend], 0
    mov rdi, rbx
    call cur_text
    mov r8d, ecx
    mov rcx, rdx
    mov rdx, rax
    mov esi, r15d
    mov rdi, [rbx + RVP_ctx]
    call [r13 + RVO_done]
    mov ebx, eax
    mov rdi, r14                # the owner may have closed it meanwhile
    call find_proposal
    test rax, rax
    jz 7f
    test ebx, ebx
    jnz 5f
    mov [rax + RVP_pend], r15d  # not taken: again in a later pass
    jmp 8f
5:  cmp qword ptr [rax + RVP_doc], 0
    jne 7f
    mov rdi, rax                # its tab is gone: so is it
    call forget
7:  xor r12d, r12d              # the list may have changed: from its start
    jmp 2b
8:  EPILOGUE

# FN review_timeout() -> eax ms until review_tick has something to do, or -1
FN review_timeout
    PROLOGUE
    mov r12d, -1
    xor r13d, r13d
1:  cmp r13, [rip + proposals + VEC_len]
    jae 5f
    mov rax, [rip + proposals + VEC_ptr]
    mov rbx, [rax + r13*8]
    inc r13
    cmp dword ptr [rbx + RVP_pend], 0
    je 1b
    xor eax, eax
    cmp qword ptr [rbx + RVP_owner], 0
    je 3f
    cmp dword ptr [rbx + RVP_pend], OFFER_CLOSED
    jne 3f
    mov rdi, rbx
    call offer_locked
3:  cmp r12d, -1
    je 4f
    cmp eax, r12d
    jge 1b
4:  mov r12d, eax
    jmp 1b
5:  cmp qword ptr [rip + show_id], 0
    je 51f
    xor r12d, r12d
51: cmp qword ptr [rip + edit_id], 0    # task 12: an edit to open, edits to close, an edit's text due
    je 52f
    xor r12d, r12d
52: cmp qword ptr [rip + orphans + VEC_len], 0
    je 53f
    xor r12d, r12d
53: call scratch_due
    cmp eax, -1
    je 54f
    cmp r12d, -1
    je 55f
    cmp eax, r12d
    jge 54f
55: mov r12d, eax
54: cmp dword ptr [rip + dim_drawn], 0
    je 9f
    call cur_offer
    xor ecx, ecx
    test rax, rax
    jz 6f
    mov rdi, rax
    call offer_locked
    mov ecx, eax
6:  cmp r12d, -1
    je 7f
    cmp ecx, r12d
    jge 9f
7:  mov r12d, ecx
9:  mov eax, r12d
    EPILOGUE


# ---------------- an offer a change at a time, and its text edited (phase 4 task 12) ----------------
#
# A change of an offer accepted is only marked; rejected, it is taken out of the proposed text (the file's
# text after is made again, its changes found again, those accepted before keep their marks by their old
# lines). Once every change is decided a toast says what is left to do: the answer is still the whole Accept
# (the text as it stands) or Reject. "Edit Proposed Text" opens the proposed text in an untitled document of
# the file's language ("NAME (proposed)"): never dirty (nothing to save, no question when it closes), Save and
# Save As refused with a toast, in no session file and not in Reopen Closed Tab (it has no path); while it is
# open the offer takes its text when it changed, at most every 100 ms, and Accept takes it at once; closed, the
# offer keeps the text last taken; it closes with the offer. Deciding and editing obey the card's lock.
#
#   review_cmd_accept, review_cmd_reject, review_cmd_accept_change, review_cmd_reject_change, review_cmd_edit
#   ck_viewing_proposed() -> rax ptr, rdx len      viewingProposedChange
#   review_tab_menu(items, tab index) -> rax items  a Review tab's menu gains the five
#   review_scratch_save() -> eax 1 refused          Save or Save As in an offer's edit

# hunks_pending(RF*) -> rax its changes not decided yet
hunks_pending:
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, [rdi + RVF_hunks + VEC_len]
    jae 9f
    imul rdx, rcx, RVH_SIZE
    add rdx, [rdi + RVF_hunks + VEC_ptr]
    inc rcx
    cmp dword ptr [rdx + RVH_state], RVS_PENDING
    jne 1b
    inc rax
    jmp 1b
9:  ret

# offer_retext(RV*, ptr, len): its proposed text is now that (copied); its changes found again, those of the
#   same old lines that were accepted marked again
offer_retext:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + RVP_files + VEC_ptr]
    mov r13, rsi
    mov r14, rdx
    mov qword ptr [rip + marks + VEC_len], 0
    xor r15d, r15d
1:  cmp r15, [r12 + RVF_hunks + VEC_len]
    jae 2f
    imul rax, r15, RVH_SIZE
    add rax, [r12 + RVF_hunks + VEC_ptr]
    inc r15
    cmp dword ptr [rax + RVH_state], RVS_ACCEPTED
    jne 1b
    push rax
    push rax
    lea rdi, [rip + marks]
    mov esi, 16
    call vec_push
    pop rcx
    pop rcx
    mov rdx, [rcx + RVH_ol]
    mov [rax], rdx
    mov rdx, [rcx + RVH_oc]
    mov [rax + 8], rdx
    jmp 1b
2:  mov rdi, r13
    mov rsi, r14
    call ai_dup
    mov r15, rax
    mov rdi, [r12 + RVF_new]
    call mem_free
    mov [r12 + RVF_new], r15
    mov [r12 + RVF_newlen], r14
    mov rdi, [r12 + RVF_nstart]
    call mem_free
    mov qword ptr [r12 + RVF_nstart], 0
    mov rdi, r12
    call file_diff
    mov rdi, r12
    call offer_cap
    xor r15d, r15d
3:  cmp r15, [r12 + RVF_hunks + VEC_len]
    jae 9f
    imul rax, r15, RVH_SIZE
    add rax, [r12 + RVF_hunks + VEC_ptr]
    inc r15
    xor ecx, ecx
4:  cmp rcx, [rip + marks + VEC_len]
    jae 3b
    mov rdx, rcx
    shl rdx, 4
    add rdx, [rip + marks + VEC_ptr]
    inc rcx
    mov r8, [rdx]
    cmp r8, [rax + RVH_ol]
    jne 4b
    mov r8, [rdx + 8]
    cmp r8, [rax + RVH_oc]
    jne 4b
    mov dword ptr [rax + RVH_state], RVS_ACCEPTED
    jmp 3b
9:  EPILOGUE

# offer_all_toast(RV*): every change decided: what is left to do
offer_all_toast:
    PROLOGUE
    mov rbx, [rdi + RVP_files + VEC_ptr]
    mov rdi, rbx
    call hunks_pending
    test rax, rax
    jnz 9f
    lea rdi, [rip + .Lt_reviewed]
    cmp qword ptr [rbx + RVF_hunks + VEC_len], 0
    jne 1f
    lea rdi, [rip + .Lt_rejected_all]
1:  call app_toast
9:  EPILOGUE

# scratch_doc(RV*) -> rax its edit's document, or 0
scratch_doc:
    PROLOGUE
    xor eax, eax
    mov rdi, [rdi + RVP_scratch]
    test rdi, rdi
    jz 9f
    call extproto_doc
9:  EPILOGUE

# clean(doc): nothing to save in it (its savepoint is where its undo is)
clean:
    mov rax, [rdi + DOC_undo + VEC_len]
    mov [rdi + DOC_savepoint], rax
    ret

# scratch_take(RV*): its edit's text, when open and different, is its proposed text now
scratch_take:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + RVP_done], 0
    jne 9f
    call scratch_doc
    test rax, rax
    jz 9f
    mov r14, rax
    mov rax, [r14 + DOC_version]
    mov [rbx + RVP_sver], rax
    mov qword ptr [rbx + RVP_sdue], 0
    call time_ms
    mov [rbx + RVP_sat], rax
    mov rdi, r14
    call clean
    mov rdi, r14
    call doc_text_copy
    mov r12, rax
    mov r13, rdx
    mov rcx, [rbx + RVP_files + VEC_ptr]
    cmp rdx, [rcx + RVF_newlen]
    jne 1f
    mov rdi, rax
    mov rsi, [rcx + RVF_new]
    call memeq
    test eax, eax
    jnz 8f
1:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call offer_retext
    mov rdi, rbx
    call build_doc
8:  mov rdi, r12
    call mem_free
9:  EPILOGUE

# scratch_put(RV*): its edit, when open, shows the proposed text as it is now
scratch_put:
    PROLOGUE
    mov rbx, rdi
    call scratch_doc
    test rax, rax
    jz 9f
    mov r12, rax
    mov rcx, [rbx + RVP_files + VEC_ptr]
    mov rdi, rax
    mov rsi, [rcx + RVF_new]
    mov rdx, [rcx + RVF_newlen]
    call doc_set_text
    mov rdi, r12
    call clean
    mov rax, [r12 + DOC_version]
    mov [rbx + RVP_sver], rax
    mov qword ptr [rbx + RVP_sdue], 0
9:  EPILOGUE

# scratch_orphan(RV*): it is freed: its edit closes in the next pass (its name freed with it)
scratch_orphan:
    PROLOGUE
    mov rbx, rdi
    cmp qword ptr [rbx + RVP_sname], 0
    jne 1f
    cmp qword ptr [rbx + RVP_scratch], 0
    je 9f
1:  lea rdi, [rip + orphans]
    mov esi, 16
    call vec_push
    mov rcx, [rbx + RVP_scratch]
    mov [rax], rcx
    mov rcx, [rbx + RVP_sname]
    mov [rax + 8], rcx
    mov qword ptr [rbx + RVP_scratch], 0
    mov qword ptr [rbx + RVP_sname], 0
9:  EPILOGUE

# orphans_close(): the edits of freed offers close (without a question: they are never dirty)
orphans_close:
    PROLOGUE
    xor ebx, ebx
1:  cmp rbx, [rip + orphans + VEC_len]
    jae 8f
    mov r12, rbx
    shl r12, 4
    add r12, [rip + orphans + VEC_ptr]
    inc rbx
    mov rdi, [r12]
    test rdi, rdi
    jz 3f
    call extproto_doc
    test rax, rax
    jz 3f
    mov rdi, rax
    call doc_tab
    test rax, rax
    js 1b                       # a document without its tab keeps its name (not freed)
    mov rdi, rax
    call app_close_tab_now
3:  mov rdi, [r12 + 8]
    call mem_free
    jmp 1b
8:  mov qword ptr [rip + orphans + VEC_len], 0
    EPILOGUE

# scratch_follow(): each open edit's text taken when it changed, at most every SCRATCH_MS; an edit closed
#   leaves the text last taken
scratch_follow:
    PROLOGUE
    xor r12d, r12d
1:  cmp r12, [rip + proposals + VEC_len]
    jae 9f
    mov rax, [rip + proposals + VEC_ptr]
    mov rbx, [rax + r12*8]
    inc r12
    cmp qword ptr [rbx + RVP_scratch], 0
    je 1b
    mov rdi, rbx
    call scratch_doc
    test rax, rax
    jnz 2f
    mov qword ptr [rbx + RVP_scratch], 0    # closed: the text last taken stays
    mov qword ptr [rbx + RVP_sdue], 0
    mov rdi, [rbx + RVP_sname]
    mov qword ptr [rbx + RVP_sname], 0
    call mem_free
    jmp 1b
2:  mov r13, rax
    cmp dword ptr [rbx + RVP_done], 0
    jne 1b
    mov rax, [r13 + DOC_version]
    cmp rax, [rbx + RVP_sver]
    je 4f
    mov [rbx + RVP_sver], rax
    mov rdi, r13                # never dirty
    call clean
    call time_ms
    mov rcx, [rbx + RVP_sat]
    add rcx, SCRATCH_MS
    cmp rax, rcx
    jb 3f
    mov rdi, rbx
    call scratch_take
    jmp 1b
3:  mov [rbx + RVP_sdue], rcx
    jmp 1b
4:  mov rcx, [rbx + RVP_sdue]
    test rcx, rcx
    jz 1b
    push rcx
    push rcx
    call time_ms
    pop rcx
    pop rcx
    cmp rax, rcx
    jb 1b
    mov rdi, rbx
    call scratch_take
    jmp 1b
9:  EPILOGUE

# scratch_due() -> eax ms until an edit's text is due to be taken, -1 none
scratch_due:
    PROLOGUE
    mov r13d, -1
    xor r12d, r12d
1:  cmp r12, [rip + proposals + VEC_len]
    jae 9f
    mov rax, [rip + proposals + VEC_ptr]
    mov rbx, [rax + r12*8]
    inc r12
    cmp qword ptr [rbx + RVP_sdue], 0
    je 1b
    call time_ms
    mov rcx, [rbx + RVP_sdue]
    sub rcx, rax
    jns 2f
    xor ecx, ecx
2:  cmp r13d, -1
    je 3f
    cmp ecx, r13d
    jge 1b
3:  mov r13d, ecx
    jmp 1b
9:  mov eax, r13d
    EPILOGUE

# offer_edit_open(RV*): "Edit Proposed Text": its edit (an untitled document of the file's language, the
#   proposed text) the active tab with the keyboard; not while its card's lock lasts, not once it is decided
offer_edit_open:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + RVP_done], 0
    jne 9f
    call offer_locked
    test eax, eax
    jnz 9f
    mov rdi, rbx
    call scratch_doc
    test rax, rax
    jz 1f
    mov rdi, rax
    call doc_tab
    test rax, rax
    js 9f
    mov rdi, rax
    call app_activate_tab
    jmp 9f
1:  mov rdi, [rbx + RVP_sname]      # (an edit closed before: its name was freed when it was seen gone)
    call mem_free
    mov qword ptr [rbx + RVP_sname], 0
    call doc_new
    mov r12, rax
    mov r13, [rbx + RVP_files + VEC_ptr]
    mov rdi, r12
    mov rsi, [r13 + RVF_new]
    mov rdx, [r13 + RVF_newlen]
    call doc_set_text
    mov qword ptr [r12 + DOC_cur], 0
    mov qword ptr [r12 + DOC_anchor], 0
    mov rax, [r13 + RVF_path]   # its language: the file's (found by its path, which it does not keep)
    mov [r12 + DOC_path], rax
    mov rdi, r12
    call doc_language_refresh
    mov qword ptr [r12 + DOC_path], 0
    lea rdi, [rip + line]
    call sb_clear
    lea rdi, [rip + line]
    mov rsi, [r13 + RVF_name]
    call sb_push_cstr
    lea rdi, [rip + line]
    lea rsi, [rip + .Lproposed]
    call sb_push_cstr
    mov rdi, [rip + line + SB_ptr]
    mov rsi, [rip + line + SB_len]
    call ai_dup
    mov [rbx + RVP_sname], rax
    mov [r12 + DOC_name], rax
    mov rdi, r12
    call clean
    mov rax, [r12 + DOC_id]
    mov [rbx + RVP_scratch], rax
    mov rax, [r12 + DOC_version]
    mov [rbx + RVP_sver], rax
    mov qword ptr [rbx + RVP_sdue], 0
    call time_ms
    mov [rbx + RVP_sat], rax
    mov rdi, r12
    mov esi, TAB_DOC
    call app_add_tab
9:  EPILOGUE

# cmd_review() -> rax the proposal the active tab shows, or 0 with the toast "No proposed change is shown."
cmd_review:
    PROLOGUE
    mov rdi, [rip + g_doc]
    call review_of
    test rax, rax
    jnz 9f
    lea rdi, [rip + .Lt_none]
    call app_toast
    xor eax, eax
9:  EPILOGUE

# FN review_cmd_accept(), FN review_cmd_reject(): "Review: Accept Proposed Changes" and "Review: Reject
#   Proposed Changes": the whole proposal shown, as Ctrl+Enter and r (for an extension's: every file)
FN review_cmd_accept
    mov ecx, 1
    jmp cmd_whole
FN review_cmd_reject
    xor ecx, ecx
cmd_whole:
    PROLOGUE
    mov r12d, ecx
    call cmd_review
    test rax, rax
    jz 9f
    mov rdi, rax
    mov rsi, -1
    mov rdx, -1
    mov ecx, r12d
    call review_decide
9:  EPILOGUE

# FN review_cmd_accept_change(), FN review_cmd_reject_change(): "Review: Accept Change at Cursor" and "Reject
#   Change at Cursor": the change the cursor is in (on a file's header: its first), as A and R
FN review_cmd_accept_change
    mov ecx, 1
    jmp cmd_change
FN review_cmd_reject_change
    xor ecx, ecx
cmd_change:
    PROLOGUE
    mov r12d, ecx
    call cmd_review
    test rax, rax
    jz 9f
    mov rbx, rax
    mov rdi, [rip + g_doc]
    mov rsi, [rdi + DOC_cur]
    call doc_line_of
    mov rdi, rbx
    mov rsi, rax
    call where
    test rax, rax
    js 9f
    test rdx, rdx
    jns 1f
    xor edx, edx
1:  mov rdi, rbx
    mov rsi, rax
    mov ecx, r12d
    call review_decide
9:  EPILOGUE

# FN review_cmd_edit(): "Review: Edit Proposed Text" (an offer's only)
FN review_cmd_edit
    PROLOGUE
    call cmd_review
    test rax, rax
    jz 9f
    cmp dword ptr [rax + RVP_offer], 0
    jne 1f
    lea rdi, [rip + .Lt_noedit]
    call app_toast
    jmp 9f
1:  mov rdi, rax
    call offer_edit_open
9:  EPILOGUE

# FN ck_viewing_proposed() -> rax ptr, rdx len: viewingProposedChange: the active tab is a Review tab with
#   something not decided yet
FN ck_viewing_proposed
    PROLOGUE
    mov rdi, [rip + g_doc]
    call review_of
    test rax, rax
    jz 8f
    cmp dword ptr [rax + RVP_done], 0
    jne 8f
    lea rax, [rip + .Lv_true]
    mov edx, 4
    EPILOGUE
8:  lea rax, [rip + .Lv_false]
    mov edx, 5
    EPILOGUE

# FN review_tab_menu(items, tab index) -> rax the items of a tab's menu: for the active tab when it is a
#   Review tab, those and the five commands after a line
FN review_tab_menu
    PROLOGUE
    mov rbx, rdi
    cmp rsi, [rip + g_tab_cur]
    jne 8f
    mov rdi, [rip + g_doc]
    call review_of
    test rax, rax
    jz 8f
    lea rdi, [rip + tmenu]
    xor ecx, ecx
1:  cmp ecx, TMENU_KEEP
    jae 2f
    mov rax, [rbx]
    mov rdx, [rbx + 8]
    mov r8, rax
    or r8, rdx
    jz 2f
    mov [rdi], rax
    mov [rdi + 8], rdx
    add rbx, 16
    add rdi, 16
    inc ecx
    jmp 1b
2:  lea rsi, [rip + tmenu_five]
    mov ecx, 14 * 8             # the line, the five, the end: 7 pairs
    rep movsb
    lea rax, [rip + tmenu]
    EPILOGUE
8:  mov rax, rbx
    EPILOGUE

# FN review_scratch_save() -> eax 1 when the active document is an offer's edit: Save and Save As refused,
#   with a toast
FN review_scratch_save
    PROLOGUE
    mov rax, [rip + g_doc]
    test rax, rax
    jz 8f
    mov rdx, [rax + DOC_id]
    xor ecx, ecx
1:  cmp rcx, [rip + proposals + VEC_len]
    jae 8f
    mov rax, [rip + proposals + VEC_ptr]
    mov rax, [rax + rcx*8]
    inc rcx
    cmp dword ptr [rax + RVP_offer], 0
    je 1b
    cmp [rax + RVP_scratch], rdx
    jne 1b
    lea rdi, [rip + .Lt_save]
    call app_toast
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

.section .rodata
.Ltab_prefix: .asciz "Review: "
.Ldot: .asciz "  \302\267  "
.Lfiles: .asciz " files"
.Lcomma: .asciz ", "
.Lto_decide: .asciz " to decide"
.Lplus: .asciz "   +"
.Lminus: .asciz " -"
.Lat_minus: .asciz "@@ -"
.Lsp_plus: .asciz " +"
.Lat_end: .asciz " @@"
.Lone_lf: .asciz "1\n"
.Lev_proposal: .asciz "proposal "
.Ldone: .asciz "done "
.Lw_pending: .asciz "pending"
.Lw_accepted: .asciz "accepted"
.Lw_rejected: .asciz "rejected"
.Lw_stale: .asciz "stale"
.Lw_partial: .asciz "partial"
.Lf_changed: .asciz "changed since proposed"
.Lf_partly: .asciz "partly accepted"
.Lh_accepted: .asciz "  \302\267  accepted"
.Lh_rejected: .asciz "  \302\267  rejected"
.Lh_stale: .asciz "  \302\267  changed since proposed"
.Lb_accept: .asciz "Accept"
.Lb_reject: .asciz "Reject"
.Lb_accept_all: .asciz "Accept all"
.Lb_reject_all: .asciz "Reject all"
.Lchanged_toast: .asciz "The file changed since it was proposed: not applied"
.Ld_proposal: .asciz "proposal="
.Ld_label: .asciz " label="
.Ld_offer: .asciz " offer=1"
.Ld_done: .asciz " done="
.Ld_offer: .asciz " offer=1"
.Ld_file: .asciz " file="
.Ld_path: .asciz " path="
.Ld_plus: .asciz " +"
.Ld_minus: .asciz " -"
.Ld_state: .asciz " state="
.Ld_hunk: .asciz "  hunk="
.Ld_hminus: .asciz " -"
.Ld_hplus: .asciz " +"
.Le_syntax: .asciz "syntax the proposal cannot be read"
.Le_many: .asciz "toobig 8 proposals are waiting for the user"
.Le_big: .asciz "toobig more than 4 MB, 1000 files or 100000 edits"
.Le_nodoc: .asciz "nodoc no such document"
.Le_nofile: .asciz "nofile no such text file"
.Le_unreadable: .asciz "nofile the file cannot be read as text of at most 4 MB"
.Le_needs: .asciz "needs file=read"
.Le_readonly: .asciz "readonly the document cannot be edited"
.Le_stale: .asciz "stale the document changed since the edit was made"
.Le_badpos: .asciz "badpos a position is outside the text or inside a character"
.Le_overlap: .asciz "badpos two edits overlap"
.Le_twice: .asciz "syntax a file appears twice"
.Le_nothing: .asciz "refused the edit changes nothing"
.Le_no_proposal: .asciz "refused no such proposal"
.p2align 3
file_words: .quad .Lw_pending, .Lw_accepted, .Lw_rejected, .Lf_changed, .Lf_partly
hunk_words: .quad .Lw_pending, .Lh_accepted, .Lh_rejected, .Lh_stale
event_words: .quad .Lw_pending, .Lw_accepted, .Lw_rejected, .Lw_stale, .Lw_partial
dump_words: .quad .Lw_pending, .Lw_accepted, .Lw_rejected, .Lw_stale, .Lw_partial

.Lo_change: .asciz " change"
.Lo_changes: .asciz " changes"
.Lo_none: .asciz "offer=none"
.Lo_offer: .asciz "offer="
.Lo_file: .asciz " file="
.Lo_changes_d: .asciz " changes="
.Lo_decided: .asciz " decided="
.Lo_edited: .asciz " edited="
.Lo_scratch: .asciz " scratch="
.Lo_shown: .asciz " shown="
.Lo_locked: .asciz " locked="
.Lb_edit: .asciz "Edit Proposed Text"
.Lproposed: .asciz " (proposed)"
.Lt_reviewed: .asciz "Every change reviewed. Accept Proposed Changes to apply them."
.Lt_rejected_all: .asciz "Every change rejected. Reject Proposed Changes or close the tab to finish."
.Lt_none: .asciz "No proposed change is shown."
.Lt_noedit: .asciz "Only a change an agent asks to make can be edited before it is accepted."
.Lt_save: .asciz "Accept the change in its Review tab to apply it."
.Lv_true: .asciz "true"
.Lv_false: .asciz "false"
.Lm_line: .asciz ""
.Lm_accept: .asciz "Accept Proposed Changes"
.Lm_reject: .asciz "Reject Proposed Changes"
.Lm_accept_c: .asciz "Accept Change at Cursor"
.Lm_reject_c: .asciz "Reject Change at Cursor"
.Lm_edit: .asciz "Edit Proposed Text"
.p2align 3
tmenu_five: .quad .Lm_line, 0, .Lm_accept, review_cmd_accept, .Lm_reject, review_cmd_reject
    .quad .Lm_accept_c, review_cmd_accept_change, .Lm_reject_c, review_cmd_reject_change
    .quad .Lm_edit, review_cmd_edit, 0, 0

.bss
.p2align 3
.Lrf_tmp: .zero RVF_SIZE
btn_dim: .long 0                # button(): greyed and not pressed (an offer whose card's lock lasts)
dim_drawn: .long 0              # an offer's tab was drawn greyed: drawn again when the lock is over
.p2align 3
show_id: .quad 0                # an offer whose tab is to be shown after the frame (review_offer_show)
edit_id: .quad 0                # task 12: an offer whose edit is to be opened after the frame (its button)
marks: .zero VEC_SIZE           # offer_retext: the accepted changes' old lines, {ol, oc}
orphans: .zero VEC_SIZE         # edits of freed offers, {DOC_id, name}: closed in the next pass
tmenu: .zero 16 * (TMENU_KEEP + 8)  # review_tab_menu's items
