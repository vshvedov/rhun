# The editor's context for a message (generic: nothing here knows which agent takes it). Phase 4 tasks 7 and 8:
# the selection chip in the footer, what goes with the next message, the mention commands and their delivery.
#
# The offer is the window's: the active tab's file (a text document with a path, not a diff, an image, a
# notebook, an untitled one); while a conversation's tab is the active tab (TAB_AGENT) the last file's offer
# stays while its document is open. With a non-empty selection and [agents] attach_selection the chip says
# "N lines selected" (A the selection's first line, B the line its end is on, from 1: the extension's OTe, also
# when the end is at column 0), else with [agents] attach_open_file the file's name. A selection's text is
# offered only when rhun knows the file is not ignored, and unknown means ignored: a component of its path in
# the exclude setting; with [agents] respect_gitignore, a file in a repository that `git check-ignore` calls
# ignored or could not be asked about (git paused, git missing, the job failing, or slower than 2 s). Until then
# the chip says the file's name, and only the name goes. One git job a file, kept for the 64 files asked last,
# forgotten when git's status changes; started only for a non-empty selection, only once the user typed in the
# conversation's box: a reader who never types starts no process. Nothing here runs on a timer: the offer is
# looked at (a compare of five numbers) only while a footer is drawn.
#
# What goes (agctx_part, at the box's Send, a driver with DRVC_CONTEXT): the chip's selection (the path, its
# lines, its text read now) or the open file (its path), only when the chip shows for that conversation (its x
# takes it away until the selection changes) and differs from what that conversation last sent. A prompt that
# the box did not send (agent-prompt, a command's) carries none (g_agctx_quiet).
#
#   agctx_sync() -> eax 1 changed;  agctx_label(AS* or 0) -> rax cstr or 0;  agctx_tip(sb, AS* or 0)
#   agctx_dismiss(AS* or 0);  agctx_has_selection() -> eax
#   agctx_part(AS*, AP*) -> eax 1 added;  agctx_sent(AS*)
#   agctx_ignored(AS* or 0) -> eax 0 no, 1 yes (unknown is yes), edx the reason (IGW_*)
#   agctx_path(sb, path cstr, AS* or 0) -> eax 1     a mention's path: relative to the conversation's checkout
#   agctx_mention(sb) -> eax 1          the active file's mention with its selection's lines; 0 none or refused
#   agctx_deliver(ptr, len)             a mention into the box (len 0: the box focused only)
#   agctx_dump(sb)                      print-agent-context
#   cmd_agents_insert_mention, agctx_focus_input, cmd_agents_add_to_chat, agctx_add_explorer (the
#   explorer's menu), agctx_chat_on() -> eax, agctx_cmd_hidden(CMD*) -> eax 1 (the palette leaves it out)
.include "rhun.inc"

.equ TAB_AGENT_, 8              # a conversation's tab (phase 4 task 13's TAB_AGENT)
.equ IG_MAX, 64                 # files whose ignored check is kept
.equ IG_SLOW_MS, 2000
.equ STASH_MS, 15000            # a mention for a box that is not there yet (OC WV@3469633)
.equ SEL_MAX, 1048576           # a selection larger than this goes as the open file
.equ IGS_FREE, 0                # an ignored check's states
.equ IGS_RUNNING, 1
.equ IGS_YES, 2
.equ IGS_NO, 3
.equ IGS_FAILED, 4
.equ IGS_NOGIT, 5
.equ IGS_NOREPO, 6
.equ IGW_EXCLUDE, 0             # agctx_ignored's reasons (print-agent-context why=)
.equ IGW_GIT, 1
.equ IGW_PAUSED, 2
.equ IGW_NOGIT, 3
.equ IGW_FAILED, 4
.equ IGW_SLOW, 5
.equ IGW_NOREPO, 6
.equ IGW_OFF, 7
.equ IGW_UNASKED, 8
.equ IGW_NONE, 9

STRUCT
F IG_hash, 8
F IG_serial, 8
F IG_t0, 8
F IG_state, 4
F IG_pad, 4
ENDSTRUCT IG_SIZE

.bss
.p2align 3
o_doc: .quad 0                  # the offer: the document's id, the selection, its version, the settings
o_s: .quad 0
o_e: .quad 0
o_ver: .quad 0
o_set: .quad 0
o_kind: .quad 0                 # 0 none, 1 the file's name, 2 a selection
o_l0: .quad 0                   # its lines (from 1) and columns (from 0)
o_l1: .quad 0
o_c0: .quad 0
o_c1: .quad 0
o_hsel: .quad 0                 # hashes: the selection (path, lines, columns), the path
o_hpath: .quad 0
o_path: .zero SB_SIZE           # the file's path, NUL-ended
o_name: .zero SB_SIZE           # its name (the chip's label without a selection)
o_lines: .zero SB_SIZE          # "N lines selected"
d_off: .quad 0                  # a new conversation's dismissal (the box's draft), handed to it at its Send
d_offp: .quad 0
p_as: .quad 0                   # what agctx_part added, for agctx_sent: its conversation and hash
p_hash: .quad 0
ig_tab: .zero IG_SIZE * IG_MAX
ig_next: .quad 0                # the slot the next new file takes
ig_serial: .quad 0
ig_ver: .quad 0                 # git_files_gen the table is for
checks: .quad 0                 # git jobs started (print-agent-context checks=)
stash: .zero SB_SIZE            # a mention waiting for its box
stash_until: .quad 0
wsb: .zero SB_SIZE
wsb2: .zero SB_SIZE
seg: .zero 264
msb: .zero SB_SIZE
ig_args: .zero 48
.globl g_agctx_quiet
g_agctx_quiet: .long 0          # 1 while a prompt the box did not write is sent (aictl.s's agent-prompt)
.p2align 3

.text

# ---- hashes ----

# fnv_mix(h, ptr, len) -> rax h FNV-1a'd over the bytes
fnv_mix:
    mov rax, rdi
    mov r8, 0x100000001b3
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 9f
    movzx r9d, byte ptr [rsi + rcx]
    xor rax, r9
    imul rax, r8
    inc rcx
    jmp 1b
9:  ret

# num_mix(h, n) -> rax h mixed with the 8 bytes of n
num_mix:
    push rsi
    mov rsi, rsp
    mov edx, 8
    call fnv_mix
    pop rsi
    ret

# ---- the offer ----

# offer_doc() -> rax the document the offer is from now (DOC*), or 0
offer_doc:
    PROLOGUE
    mov rdi, [rip + g_tab_cur]
    test rdi, rdi
    js 8f
    cmp rdi, [rip + g_tabs + VEC_len]
    jae 8f
    call tab_at
    mov rcx, [rax + TAB_kind]
    cmp rcx, TAB_AGENT_
    je 5f
    cmp rcx, TAB_DOC
    jne 8f
    mov rbx, [rax + TAB_doc]
    test rbx, rbx
    jz 8f
    cmp qword ptr [rbx + DOC_path], 0
    je 8f
    cmp qword ptr [rbx + DOC_diff], 0
    jne 8f
    cmp qword ptr [rbx + DOC_img], 0
    jne 8f
    mov rax, rbx
    EPILOGUE
5:  mov r12, [rip + o_doc]      # a conversation's tab: the last file's, while its document is open
    test r12, r12
    jz 8f
    xor ebx, ebx
6:  cmp rbx, [rip + g_tabs + VEC_len]
    jae 8f
    mov rdi, rbx
    call tab_at
    inc rbx
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 6b
    mov rax, [rax + TAB_doc]
    test rax, rax
    jz 6b
    cmp [rax + DOC_id], r12
    jne 6b
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agctx_sync() -> eax 1 when the offer changed: see the top
FN agctx_sync
    PROLOGUE 16
    call stash_flush
    call offer_doc
    mov rbx, rax
    test rbx, rbx
    jnz 1f
    xor eax, eax
    cmp qword ptr [rip + o_kind], 0
    je 9f
    mov qword ptr [rip + o_kind], 0
    mov qword ptr [rip + o_doc], 0
    mov dword ptr [rip + g_dirty], 1
    mov eax, 1
    EPILOGUE
1:  mov r12, [rbx + DOC_cur]    # the five numbers
    mov r13, [rbx + DOC_anchor]
    cmp r12, r13
    jbe 2f
    xchg r12, r13
2:  mov eax, [rip + cfg_agents_attach_selection]
    mov ecx, [rip + cfg_agents_attach_open_file]
    shl ecx, 1
    or eax, ecx
    mov [rsp], rax
    mov rax, [rbx + DOC_id]
    cmp rax, [rip + o_doc]
    jne 3f
    cmp r12, [rip + o_s]
    jne 3f
    cmp r13, [rip + o_e]
    jne 3f
    mov rax, [rbx + DOC_version]
    cmp rax, [rip + o_ver]
    jne 3f
    mov rax, [rsp]
    cmp rax, [rip + o_set]
    jne 3f
    xor eax, eax
    EPILOGUE
3:  mov rax, [rbx + DOC_id]
    mov [rip + o_doc], rax
    mov [rip + o_s], r12
    mov [rip + o_e], r13
    mov rax, [rbx + DOC_version]
    mov [rip + o_ver], rax
    mov rax, [rsp]
    mov [rip + o_set], rax
    lea rdi, [rip + o_path]     # its path and name
    call sb_clear
    lea rdi, [rip + o_path]
    mov rsi, [rbx + DOC_path]
    call sb_push_cstr
    lea rdi, [rip + o_path]
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rip + o_path + SB_len]
    lea rdi, [rip + o_name]
    call sb_clear
    mov rdi, [rip + o_path + SB_ptr]
    mov rsi, [rip + o_path + SB_len]
    call path_basename
    lea rdi, [rip + o_name]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + o_name]
    xor esi, esi
    call sb_push_byte
    mov rdi, 0xcbf29ce484222325
    mov rsi, [rip + o_path + SB_ptr]
    mov rdx, [rip + o_path + SB_len]
    call fnv_mix
    mov [rip + o_hpath], rax
    mov qword ptr [rip + o_kind], 0
    cmp r12, r13                # a selection, attach_selection on
    je 5f
    cmp dword ptr [rip + cfg_agents_attach_selection], 0
    je 5f
    mov rdi, rbx
    mov rsi, r12
    call doc_line_of
    mov r14, rax
    mov rdi, rbx
    mov rsi, r13
    call doc_line_of
    mov r15, rax
    lea rax, [r14 + 1]
    mov [rip + o_l0], rax
    lea rax, [r15 + 1]
    mov [rip + o_l1], rax
    mov rdi, rbx
    mov rsi, r14
    call doc_line_start
    mov rcx, r12
    sub rcx, rax
    mov [rip + o_c0], rcx
    mov rdi, rbx
    mov rsi, r15
    call doc_line_start
    mov rcx, r13
    sub rcx, rax
    mov [rip + o_c1], rcx
    lea rdi, [rip + o_lines]    # "N lines selected"
    call sb_clear
    mov rsi, [rip + o_l1]
    sub rsi, [rip + o_l0]
    inc rsi
    mov r14, rsi
    lea rdi, [rip + o_lines]
    call sb_push_u64
    lea rsi, [rip + .Ll_lines]
    cmp r14, 1
    jne 4f
    lea rsi, [rip + .Ll_line]
4:  lea rdi, [rip + o_lines]
    call sb_push_cstr
    lea rdi, [rip + o_lines]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + o_hpath]
    mov rsi, [rip + o_l0]
    call num_mix
    mov rdi, rax
    mov rsi, [rip + o_l1]
    call num_mix
    mov rdi, rax
    mov rsi, [rip + o_c0]
    call num_mix
    mov rdi, rax
    mov rsi, [rip + o_c1]
    call num_mix
    mov [rip + o_hsel], rax
    mov qword ptr [rip + o_kind], 2
    jmp 8f
5:  cmp dword ptr [rip + cfg_agents_attach_open_file], 0
    je 8f
    mov qword ptr [rip + o_kind], 1
8:  mov dword ptr [rip + g_dirty], 1
    mov eax, 1
9:  EPILOGUE

# marks(AS* or 0) -> rax its dismissal's selection hash, rdx its path hash (a new conversation's: the draft's)
marks:
    test rdi, rdi
    jz 1f
    mov rax, [rdi + AS_ctx_off]
    mov rdx, [rdi + AS_ctx_offp]
    ret
1:  mov rax, [rip + d_off]
    mov rdx, [rip + d_offp]
    ret

# shown(AS* or 0) -> eax 0 none, 1 the name, 2 the selection's lines: what the chip shows for that conversation
#   (the selection's lines only for a file known not to be ignored)
shown:
    PROLOGUE
    mov rbx, rdi
    call caps_ok
    test eax, eax
    jz 8f
    mov rax, [rip + o_kind]
    test rax, rax
    jz 8f
    mov rdi, rbx
    call marks
    cmp qword ptr [rip + o_kind], 2
    jne 2f
    cmp rax, [rip + o_hsel]     # this selection dismissed
    je 8f
    mov rdi, rbx
    call agctx_ignored
    test eax, eax
    jnz 1f
    mov eax, 2
    EPILOGUE
1:  mov eax, 1                  # unknown or ignored: its name
    EPILOGUE
2:  cmp rdx, [rip + o_hpath]    # the file's name dismissed (a caret move in the same file keeps it away)
    je 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# caps_ok() -> eax nonzero when the box's driver takes the editor's context (DRVC_CONTEXT)
caps_ok:
    sub rsp, 8
    call agatt_caps
    add rsp, 8
    and eax, DRVC_CONTEXT
    ret

# FN agctx_label(AS* or 0) -> rax the chip's label for that conversation, 0 no chip
FN agctx_label
    PROLOGUE
    call shown
    lea rcx, [rip + o_name]
    cmp eax, 1
    je 1f
    lea rcx, [rip + o_lines]
    cmp eax, 2
    je 1f
    xor eax, eax
    EPILOGUE
1:  mov rax, [rcx + SB_ptr]
    EPILOGUE

# FN agctx_tip(sb, AS* or 0): "Showing Claude your current file selection (LABEL)" (the driver's words), and
#   why only the name goes when that is so
FN agctx_tip
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call agctx_label
    test rax, rax
    jz 9f
    mov r13, rax
    call box_words
    mov rsi, [rax + 8*DW_SELTIP]
    mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lt_open]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r13
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ')'
    call sb_push_byte
    cmp qword ptr [rip + o_kind], 2
    jne 9f
    mov rax, [rip + o_e]
    sub rax, [rip + o_s]
    cmp rax, SEL_MAX
    jbe 9f
    mov rdi, rbx
    lea rsi, [rip + .Lt_big]
    call sb_push_cstr
9:  mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    dec qword ptr [rbx + SB_len]
    EPILOGUE

# box_words() -> rax the box's driver's words (DRV_words), or the generic ones
box_words:
    sub rsp, 8
    call agentext_box_owner
    test rax, rax
    jz 1f
    mov rdi, rax
    call agent_drv_of
    jmp 2f
1:  mov edi, edx
    call agent_drv_for_kind
2:  add rsp, 8
    test rax, rax
    jz 3f
    mov rax, [rax + DRV_words]
    test rax, rax
    jnz 4f
3:  lea rax, [rip + generic_words]
4:  ret

# FN agctx_dismiss(AS* or 0): the chip's x: it is gone for that conversation until the selection changes (a
#   caret move without a selection in the same file does not bring it back; another selection or file does)
FN agctx_dismiss
    xor eax, eax
    cmp qword ptr [rip + o_kind], 2
    jne 1f
    mov rax, [rip + o_hsel]
1:  mov rdx, [rip + o_hpath]
    test rdi, rdi
    jz 2f
    mov [rdi + AS_ctx_off], rax
    mov [rdi + AS_ctx_offp], rdx
    mov dword ptr [rdi + AS_ctx_init], 1    # its own marks now: a draft's are not handed to it
    jmp 3f
2:  mov [rip + d_off], rax
    mov [rip + d_offp], rdx
3:  mov dword ptr [rip + g_dirty], 1
    ret

# FN agctx_has_selection() -> eax 1 when the editor's file has a non-empty selection (the placeholder's (c))
FN agctx_has_selection
    sub rsp, 8
    call offer_doc
    add rsp, 8
    test rax, rax
    jz 1f
    mov rcx, [rax + DOC_cur]
    cmp rcx, [rax + DOC_anchor]
    setne al
    movzx eax, al
    ret
1:  xor eax, eax
    ret

# ---- the ignored check ----

# ig_find(hash) -> rax the slot of that file, 0 none
ig_find:
    lea rax, [rip + ig_tab]
    mov ecx, IG_MAX
1:  cmp dword ptr [rax + IG_state], IGS_FREE
    je 2f
    cmp [rax + IG_hash], rdi
    je 9f
2:  add rax, IG_SIZE
    dec ecx
    jnz 1b
    xor eax, eax
9:  ret

# ig_new(hash) -> rax a slot for that file (the oldest one is taken when all are)
ig_new:
    mov rax, [rip + ig_next]
    lea rcx, [rax + 1]
    and rcx, IG_MAX - 1
    mov [rip + ig_next], rcx
    imul rax, rax, IG_SIZE
    lea rcx, [rip + ig_tab]
    add rax, rcx
    mov [rax + IG_hash], rdi
    inc qword ptr [rip + ig_serial]
    mov rcx, [rip + ig_serial]
    mov [rax + IG_serial], rcx
    mov dword ptr [rax + IG_state], IGS_RUNNING
    ret

# ig_fresh(): git's set of untracked, added, deleted and renamed paths changed since the table was made (what
#   a .gitignore edit changes: a file it now ignores leaves the untracked set, one it no longer ignores joins
#   it): what the table says is forgotten. A status that only says a file was modified keeps it (git refreshes
#   its status often: the answers would be asked again each time). A check still running keeps its slot
ig_fresh:
    sub rsp, 8
    call git_files_gen
    add rsp, 8
    cmp rax, [rip + ig_ver]
    je 9f
    mov rcx, [rip + ig_ver]
    mov [rip + ig_ver], rax
    test rcx, rcx               # git's first status since startup: the answers asked before it hold
    jz 9f
    lea rax, [rip + ig_tab]
    mov ecx, IG_MAX
1:  cmp dword ptr [rax + IG_state], IGS_RUNNING
    je 2f
    mov dword ptr [rax + IG_state], IGS_FREE
2:  add rax, IG_SIZE
    dec ecx
    jnz 1b
9:  ret

# excluded() -> eax 1 when a component of the offer's path (relative to the project when inside it) is a name
#   of the exclude setting
excluded:
    PROLOGUE
    mov rbx, [rip + o_path + SB_ptr]
    mov r12, [rip + o_path + SB_len]
    mov rdi, [rip + g_project]
    test rdi, rdi
    jz 1f
    call strlen
    cmp rax, r12
    jae 1f
    cmp byte ptr [rbx + rax], '/'
    jne 1f
    mov r13, rax
    mov rdi, rbx
    mov rsi, [rip + g_project]
    mov rdx, rax
    call memeq
    test eax, eax
    jz 1f
    lea rbx, [rbx + r13 + 1]
    sub r12, r13
    dec r12
1:  xor r13d, r13d              # each component
2:  cmp r13, r12
    jae 8f
    mov r14, r13
3:  cmp r14, r12
    jae 4f
    cmp byte ptr [rbx + r14], '/'
    je 4f
    inc r14
    jmp 3b
4:  mov rcx, r14
    sub rcx, r13
    jz 5f
    cmp rcx, 255
    ja 5f
    lea rdi, [rip + seg]
    lea rsi, [rbx + r13]
    rep movsb
    mov byte ptr [rdi], 0
    lea rdi, [rip + seg]
    call explorer_excluded
    test eax, eax
    jnz 9f
5:  lea r13, [r14 + 1]
    jmp 2b
8:  xor eax, eax
9:  EPILOGUE

# repo_of() -> eax 1 when a folder above the offer's file holds ".git" (wsb: that folder, NUL-ended), 0 none
repo_of:
    PROLOGUE
    lea rdi, [rip + wsb]
    call sb_clear
    lea rdi, [rip + wsb]
    mov rsi, [rip + o_path + SB_ptr]
    mov rdx, [rip + o_path + SB_len]
    call sb_push
1:  mov rbx, [rip + wsb + SB_ptr]   # up one folder
    mov r12, [rip + wsb + SB_len]
2:  test r12, r12
    jz 8f
    dec r12
    cmp byte ptr [rbx + r12], '/'
    jne 2b
    mov [rip + wsb + SB_len], r12
    lea rdi, [rip + wsb2]
    call sb_clear
    lea rdi, [rip + wsb2]
    mov rsi, [rip + wsb + SB_ptr]
    mov rdx, [rip + wsb + SB_len]
    call sb_push
    lea rdi, [rip + wsb2]
    lea rsi, [rip + .Ldot_git]
    call sb_push_cstr
    lea rdi, [rip + wsb2]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + wsb2 + SB_ptr]
    call vfs_stat
    test rax, rax
    jns 7f
    cmp qword ptr [rip + wsb + SB_len], 0
    je 8f
    jmp 1b
7:  cmp qword ptr [rip + wsb + SB_len], 0   # "/" itself
    jne 71f
    lea rdi, [rip + wsb]
    mov esi, '/'
    call sb_push_byte
71: lea rdi, [rip + wsb]
    xor esi, esi
    call sb_push_byte
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# may_ask(AS* or 0) -> eax 1 when a git job may start for the chip of that conversation: the user typed in
#   its box (AL_keyed), or, for a new conversation, its box is not empty
may_ask:
    PROLOGUE
    test rdi, rdi
    jz 2f
    call agent_live_get
    test rax, rax
    jz 8f
    xor ecx, ecx
    cmp qword ptr [rax + AL_keyed], 0
    setne cl
    mov eax, ecx
    EPILOGUE
2:  call agentext_box
    mov rdi, rax
    call tf_text
    xor eax, eax
    test rdx, rdx
    setnz al
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN agctx_ignored(AS* or 0) -> eax 0 no, 1 yes, edx the reason: the offer's file, by the rule at the top; a
#   git job is started when the answer is not known yet and the user typed in that conversation's box
FN agctx_ignored
    PROLOGUE 16
    mov r15, rdi
    cmp qword ptr [rip + o_kind], 0
    jne 1f
    mov eax, 1
    mov edx, IGW_NONE
    EPILOGUE
1:  call excluded
    test eax, eax
    jz 2f
    mov eax, 1
    mov edx, IGW_EXCLUDE
    EPILOGUE
2:  cmp dword ptr [rip + cfg_agents_respect_gitignore], 0
    jne 3f
    xor eax, eax
    mov edx, IGW_OFF
    EPILOGUE
3:  call ig_fresh
    mov rdi, [rip + o_hpath]
    call ig_find
    test rax, rax
    jnz .Lig_known
    call repo_of                # no repository above it: nothing to ask (kept, no process)
    test eax, eax
    jnz 4f
    mov rdi, [rip + o_hpath]
    call ig_new
    mov dword ptr [rax + IG_state], IGS_NOREPO
    jmp .Lig_known
4:  cmp dword ptr [rip + g_git_paused], 0
    je 5f
    mov eax, 1
    mov edx, IGW_PAUSED
    EPILOGUE
5:  mov rdi, r15
    call may_ask
    test eax, eax
    jnz 6f
    mov eax, 1
    mov edx, IGW_UNASKED
    EPILOGUE
6:  mov rdi, [rip + o_hpath]    # git check-ignore -q -- PATH, in the repository's folder
    call ig_new
    mov rbx, rax
    call time_ms
    mov [rbx + IG_t0], rax
    mov edi, 16
    call mem_alloc
    mov r12, rax
    mov rax, [rbx + IG_serial]
    mov [r12], rax
    mov [r12 + 8], rbx
    lea rax, [rip + .Lg_check]
    mov [rip + ig_args], rax
    lea rax, [rip + .Lg_q]
    mov [rip + ig_args + 8], rax
    lea rax, [rip + .Lg_dashes]
    mov [rip + ig_args + 16], rax
    mov rax, [rip + o_path + SB_ptr]
    mov [rip + ig_args + 24], rax
    mov qword ptr [rip + ig_args + 32], 0
    mov rdi, [rip + wsb + SB_ptr]
    lea rsi, [rip + ig_args]
    lea rdx, [rip + ig_done]
    mov rcx, r12
    mov r8d, 4096
    call git_start_in_plain     # (ctx freed by git.s, also when it cannot start)
    test rax, rax
    jnz 7f
    mov dword ptr [rbx + IG_state], IGS_NOGIT
    mov rax, rbx
    jmp .Lig_known
7:  inc qword ptr [rip + checks]
    mov rax, rbx
.Lig_known:
    mov ecx, [rax + IG_state]
    mov eax, 1
    mov edx, IGW_GIT
    cmp ecx, IGS_YES
    je 9f
    xor eax, eax
    cmp ecx, IGS_NO
    je 9f
    mov edx, IGW_NOREPO
    cmp ecx, IGS_NOREPO
    je 9f
    mov eax, 1
    mov edx, IGW_FAILED
    cmp ecx, IGS_FAILED
    je 9f
    mov edx, IGW_NOGIT
    cmp ecx, IGS_NOGIT
    je 9f
    mov edx, IGW_PAUSED         # running
    cmp dword ptr [rip + g_git_paused], 0
    jne 9f
    mov rdi, [rip + o_hpath]
    call ig_find
    mov rbx, rax
    call time_ms
    sub rax, [rbx + IG_t0]
    mov edx, IGW_UNASKED
    cmp rax, IG_SLOW_MS
    jb 8f
    mov edx, IGW_SLOW
8:  mov eax, 1
9:  EPILOGUE

# ig_done(ctx, output, len, status): git check-ignore's answer: 0 ignored, 1 not, anything else failed (a late
#   answer is still taken)
ig_done:
    mov rax, [rdi + 8]
    mov rdx, [rdi]
    cmp [rax + IG_serial], rdx
    jne 9f
    mov edx, IGS_YES
    test ecx, ecx
    jz 1f
    mov edx, IGS_NO
    cmp ecx, 1
    je 1f
    mov edx, IGS_FAILED
1:  mov [rax + IG_state], edx
    mov dword ptr [rip + g_dirty], 1
9:  ret

# ---- what goes ----

# FN agctx_part(AS*, AP*) -> eax 1 when a part was added (MPF_AUTO): see the top
FN agctx_part
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov qword ptr [rip + p_as], 0
    cmp dword ptr [rip + g_agctx_quiet], 0
    jne .Lpt_none
    test rbx, rbx
    jz .Lpt_none
    test r12, r12
    jz .Lpt_none
    cmp dword ptr [rbx + AS_ctx_init], 0    # a new conversation: its draft's dismissal is its own now
    jne 1f
    mov dword ptr [rbx + AS_ctx_init], 1
    mov rax, [rip + d_off]
    mov [rbx + AS_ctx_off], rax
    mov rax, [rip + d_offp]
    mov [rbx + AS_ctx_offp], rax
    mov qword ptr [rip + d_off], 0
    mov qword ptr [rip + d_offp], 0
1:  mov rdi, rbx
    xor esi, esi
    call agatt_caps_of
    test eax, DRVC_CONTEXT
    jz .Lpt_none
    call agctx_sync
    mov rdi, rbx
    call shown
    test eax, eax
    jz .Lpt_none
    cmp eax, 2
    jne .Lpt_name
    mov rax, [rip + o_e]        # past 1 MB: the open file
    sub rax, [rip + o_s]
    cmp rax, SEL_MAX
    ja .Lpt_name
    call offer_doc              # the text, read now
    test rax, rax
    jz .Lpt_none
    mov r13, rax
    lea rdi, [rip + wsb]
    call sb_clear
    mov rsi, [rip + o_e]
    sub rsi, [rip + o_s]
    mov r14, rsi
    lea rdi, [rip + wsb]
    call sb_reserve
    mov rcx, rax
    mov rdi, r13
    mov rsi, [rip + o_s]
    mov rdx, r14
    call doc_copy
    mov [rip + wsb + SB_len], r14
    mov rdi, [rip + o_hsel]     # (path, lines, columns, text)
    mov rsi, [rip + wsb + SB_ptr]
    mov rdx, r14
    call fnv_mix
    cmp rax, [rbx + AS_ctx_sent]
    je .Lpt_none
    mov [rip + p_hash], rax
    push qword ptr [rip + o_l1]
    push qword ptr [rip + o_l0]
    mov rdi, r12
    mov esi, MPK_SELECTION
    mov rdx, [rip + o_name + SB_ptr]
    mov rcx, [rip + o_path + SB_ptr]
    mov r8, [rip + wsb + SB_ptr]
    mov r9, r14
    test r8, r8
    jnz 2f
    lea r8, [rip + .Lempty]
2:  call agatt_add_text
    add rsp, 16
    jmp .Lpt_added
.Lpt_name:
    mov rdi, [rip + o_hpath]
    mov esi, 1                  # (the open file: a hash of its own kind)
    call num_mix
    cmp rax, [rbx + AS_ctx_sent]
    je .Lpt_none
    mov [rip + p_hash], rax
    push 0
    push 0
    mov rdi, r12
    mov esi, MPK_OPENFILE
    mov rdx, [rip + o_name + SB_ptr]
    mov rcx, [rip + o_path + SB_ptr]
    lea r8, [rip + .Lempty]
    xor r9d, r9d
    call agatt_add_text
    add rsp, 16
.Lpt_added:
    test eax, eax
    jnz .Lpt_none
    mov [rip + p_as], rbx
    mov eax, 1
    EPILOGUE
.Lpt_none:
    xor eax, eax
    EPILOGUE

# FN agctx_sent(AS*): the prompt was taken: what went with it is what this conversation last sent
FN agctx_sent
    test rdi, rdi
    jz 9f
    cmp rdi, [rip + p_as]
    jne 9f
    mov rax, [rip + p_hash]
    mov [rdi + AS_ctx_sent], rax
    mov qword ptr [rip + p_as], 0
9:  ret

# ---- mentions ----

# FN agctx_path(sb, path cstr, AS* or 0) -> eax 1: a mention's path appended to sb: relative to that
#   conversation's checkout (AS_cwd; else the project's folder) when the file is inside it, else absolute (the
#   extension's Add to Chat rule, FTe EXT@1247350: the only form the agent's program resolves from its working
#   directory)
FN agctx_path
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
    test rdx, rdx
    jz 1f
    mov r13, [rdx + AS_cwd]
1:  test r13, r13
    jnz 2f
    mov r13, [rip + g_project]
    test r13, r13
    jz 8f
2:  mov rdi, r13
    call strlen
    mov r14, rax
3:  cmp r14, 1                  # the folder without a "/" at its end
    jbe 4f
    cmp byte ptr [r13 + r14 - 1], '/'
    jne 4f
    dec r14
    jmp 3b
4:  mov rdi, r12
    call strlen
    cmp rax, r14
    jbe 8f
    cmp byte ptr [r12 + r14], '/'
    jne 8f
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call memeq
    test eax, eax
    jz 8f
    lea rsi, [r12 + r14 + 1]
    cmp byte ptr [rsi], 0
    je 8f
    mov rdi, rbx
    call sb_push_cstr
    mov eax, 1
    EPILOGUE
8:  mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov eax, 1
    EPILOGUE

# refused_toast(path ptr, len): the driver's words "This path can't be @-mentioned, …" and the path
refused_toast:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call box_words
    mov rbx, [rax + 8*DW_MENTION_REFUSED]
    lea rdi, [rip + wsb2]
    call sb_clear
    lea rdi, [rip + wsb2]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rip + wsb2]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rdi, [rip + wsb2]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + wsb2 + SB_ptr]
    call app_toast
    EPILOGUE

# FN agctx_mention(sb) -> eax 1: the active file's mention (its selection's lines: "#L5", "#L2-3"; the path as
#   agctx_path makes it) appended to sb; 0 when no file shows, or refused (the toast)
FN agctx_mention
    PROLOGUE 16
    mov rbx, rdi
    call offer_doc
    test rax, rax
    jz 8f
    mov r12, rax
    xor r14d, r14d              # the lines
    xor r15d, r15d
    mov rsi, [r12 + DOC_cur]
    mov rdx, [r12 + DOC_anchor]
    cmp rsi, rdx
    je 1f
    jb 11f
    xchg rsi, rdx
11: mov [rsp], rdx
    mov rdi, r12
    call doc_line_of
    lea r14, [rax + 1]
    mov rdi, r12
    mov rsi, [rsp]
    call doc_line_of
    lea r15, [rax + 1]
1:  lea rdi, [rip + wsb]
    call sb_clear
    call agentext_box_owner
    mov rdx, rax
    lea rdi, [rip + wsb]
    mov rsi, [r12 + DOC_path]
    call agctx_path
    mov rdi, rbx
    mov rsi, [rip + wsb + SB_ptr]
    mov rdx, [rip + wsb + SB_len]
    mov ecx, r14d
    mov r8d, r15d
    call agmention_text
    test eax, eax
    jnz 9f
    mov rdi, [rip + wsb + SB_ptr]
    mov rsi, [rip + wsb + SB_len]
    call refused_toast
8:  xor eax, eax
9:  EPILOGUE

# FN agctx_chat_on() -> eax 1 when a built-in driver takes prompts in this window (the panel can have a box)
FN agctx_chat_on
    sub rsp, 8
    mov edi, 1                  # the default driver (agent_drv_for_kind: 0 when its chat is off)
    call agent_drv_for_kind
    add rsp, 8
    test rax, rax
    setnz al
    movzx eax, al
    ret

# box_ready() -> eax 1 when the panel shows a built-in driver's box (a conversation or a draft)
box_ready:
    sub rsp, 8
    call agentext_box_owner
    add rsp, 8
    xor eax, eax
    test edx, edx
    setnz al
    ret

# FN agctx_deliver(ptr, len): a mention to the box (len 0: the box only gets the keys): the panel shown; the
#   conversation it shows, else a new conversation of the default driver; inserted at the caret with a space
#   after it, the box focused. While a card is up nothing is inserted (the card keeps the keys). A box that is
#   not there yet gets it when it is (kept as text for 15 s)
FN agctx_deliver
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call agctx_chat_on
    test eax, eax
    jz 9f
    call cmd_focus_agents       # the panel shown (and the keys in it)
    call box_ready
    test eax, eax
    jnz 1f
    mov edi, 1                  # the list: a new conversation of the default driver
    call agentext_new_kind
1:  call agentext_box_owner
    test rax, rax
    jz 2f
    mov rbx, rax
    cmp qword ptr [rbx + AS_ask], 0
    jne 9f                      # a card is up: it keeps the keys
    mov rdi, rbx
    call agentcard_of
    test rax, rax
    jnz 9f
2:  lea rdi, [rip + stash]
    call sb_clear
    test r13, r13
    jz 3f
    lea rdi, [rip + stash]
    mov rsi, r12
    mov rdx, r13
    call sb_push
3:  call time_ms
    add rax, STASH_MS
    mov [rip + stash_until], rax
    mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    call stash_flush
9:  EPILOGUE

# stash_flush(): a mention kept for a box goes into it when the box is there (dropped after 15 s)
stash_flush:
    PROLOGUE
    cmp qword ptr [rip + stash_until], 0
    je 9f
    call time_ms
    cmp rax, [rip + stash_until]
    jae 8f
    call box_ready
    test eax, eax
    jz 9f
    mov dword ptr [rip + g_focus], FOCUS_AGENT_INPUT
    mov rsi, [rip + stash + SB_len]
    test rsi, rsi
    jz 8f
    mov rdi, [rip + stash + SB_ptr]
    mov edx, 1
    call composer_insert
8:  mov qword ptr [rip + stash_until], 0
    lea rdi, [rip + stash]
    call sb_clear
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# ---- the commands (keys.s) ----

# FN cmd_agents_insert_mention(): Alt+K: the active file's mention, with its selection's lines, into the box
FN cmd_agents_insert_mention
    PROLOGUE
    call agctx_chat_on
    test eax, eax
    jz 9f
    lea rdi, [rip + msb]
    call sb_clear
    lea rdi, [rip + msb]
    call agctx_mention
    test eax, eax
    jz 9f
    mov rdi, [rip + msb + SB_ptr]
    mov rsi, [rip + msb + SB_len]
    call agctx_deliver
9:  EPILOGUE

# FN agctx_focus_input(): Ctrl+Esc (Cmd+Esc), cmd_agents_focus_input's chat side (claudeterm.s keeps the
#   terminal's): from a conversation's panel or box the keys go back to the editor; from anywhere else the box
#   gets them, the editor's selection's mention inserted first
FN agctx_focus_input
    PROLOGUE
    call agctx_chat_on
    test eax, eax
    jz 9f
    mov eax, [rip + g_focus]
    cmp eax, FOCUS_AGENT_INPUT
    je 1f
    cmp eax, FOCUS_AGENTS
    jne 2f
1:  mov dword ptr [rip + g_focus], FOCUS_EDITOR
    mov dword ptr [rip + g_dirty], 1
    EPILOGUE
2:  call agctx_has_selection
    test eax, eax
    jz 3f
    lea rdi, [rip + msb]
    call sb_clear
    lea rdi, [rip + msb]
    call agctx_mention
    test eax, eax
    jz 3f
    mov rdi, [rip + msb + SB_ptr]
    mov rsi, [rip + msb + SB_len]
    call agctx_deliver
    EPILOGUE
3:  xor edi, edi
    xor esi, esi
    call agctx_deliver
9:  EPILOGUE

# add_paths(list of cstr, n): Add to Chat: each path's mention ("@P", "@\"P\""; a folder's with its "/"), a
#   space between them, into the box; the paths that cannot be mentioned counted in a toast
add_paths:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d              # refused
    lea rdi, [rip + msb]
    call sb_clear
    xor r14d, r14d
1:  cmp r14, r12
    jae 5f
    mov r15, [rbx + r14*8]
    inc r14
    lea rdi, [rip + wsb]
    call sb_clear
    call agentext_box_owner
    mov rdx, rax
    lea rdi, [rip + wsb]
    mov rsi, r15
    call agctx_path
    mov rdi, r15                # a folder: its "/"
    call vfs_is_dir
    test eax, eax
    jz 2f
    mov rax, [rip + wsb + SB_ptr]
    mov rcx, [rip + wsb + SB_len]
    test rcx, rcx
    jz 2f
    cmp byte ptr [rax + rcx - 1], '/'
    je 2f
    lea rdi, [rip + wsb]
    mov esi, '/'
    call sb_push_byte
2:  mov rax, [rip + msb + SB_len]
    mov [rsp], rax
    test rax, rax
    jz 3f
    lea rdi, [rip + msb]
    mov esi, ' '
    call sb_push_byte
3:  lea rdi, [rip + msb]
    mov rsi, [rip + wsb + SB_ptr]
    mov rdx, [rip + wsb + SB_len]
    xor ecx, ecx
    xor r8d, r8d
    call agmention_text
    test eax, eax
    jnz 1b
    mov rax, [rsp]              # refused: what this one added goes
    mov [rip + msb + SB_len], rax
    inc r13d
    jmp 1b
5:  test r13d, r13d
    jz 6f
    lea rdi, [rip + wsb2]
    call sb_clear
    lea rsi, [rip + .Lr_one]
    cmp r13d, 1
    je 51f
    lea rdi, [rip + wsb2]
    mov esi, r13d
    call sb_push_u64
    lea rsi, [rip + .Lr_many]
51: lea rdi, [rip + wsb2]
    call sb_push_cstr
    lea rdi, [rip + wsb2]
    lea rsi, [rip + .Lr_tail]
    call sb_push_cstr
    lea rdi, [rip + wsb2]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + wsb2 + SB_ptr]
    call app_toast
6:  mov rsi, [rip + msb + SB_len]
    test rsi, rsi
    jz 9f
    mov rdi, [rip + msb + SB_ptr]
    call agctx_deliver
9:  EPILOGUE

# FN cmd_agents_add_to_chat(): Add to Chat from the palette: the active file
FN cmd_agents_add_to_chat
    PROLOGUE 16
    call agctx_chat_on
    test eax, eax
    jz 9f
    call offer_doc
    test rax, rax
    jz 9f
    mov rax, [rax + DOC_path]
    mov [rsp], rax
    lea rdi, [rsp]
    mov esi, 1
    call add_paths
9:  EPILOGUE

# FN agctx_add_explorer(): Add to Chat from the explorer's menu: its row's file or folder
FN agctx_add_explorer
    PROLOGUE 16
    call agctx_chat_on
    test eax, eax
    jz 9f
    lea rax, [rip + g_explorer_target]
    mov [rsp], rax
    lea rdi, [rsp]
    mov esi, 1
    call add_paths
9:  EPILOGUE

# FN agctx_cmd_hidden(CMD*) -> eax 1 when the palette leaves the command out: the mention commands with the
#   chat off (no built-in driver takes prompts)
FN agctx_cmd_hidden
    PROLOGUE
    mov rbx, [rdi + CMD_fn]
    xor eax, eax
    lea rcx, [rip + cmd_agents_insert_mention]
    cmp rbx, rcx
    je 1f
    lea rcx, [rip + cmd_agents_focus_input]
    cmp rbx, rcx
    je 1f
    lea rcx, [rip + cmd_agents_add_to_chat]
    cmp rbx, rcx
    jne 9f
1:  call agctx_chat_on
    xor eax, 1
9:  EPILOGUE

# FN agctx_passes(keysym, mods) -> eax 1 when the stroke is bound to a mention command: the box and the panel
#   leave it to the bindings (on macOS Option+K would type a character)
FN agctx_passes
    sub rsp, 8
    call keys_lookup
    add rsp, 8
    lea rcx, [rip + cmd_agents_insert_mention]
    cmp rax, rcx
    je 1f
    lea rcx, [rip + cmd_agents_focus_input]
    cmp rax, rcx
    je 1f
    lea rcx, [rip + cmd_agents_add_to_chat]
    cmp rax, rcx
    je 1f
    xor eax, eax
    ret
1:  mov eax, 1
    ret

# FN agctx_placeholder_c() -> rax the box's placeholder (c), or 0: "⌘ Esc to attach selected text" (macOS;
#   "ctrl esc …" elsewhere) while the editor has a selection, the driver takes the editor's context and neither
#   the panel nor the box has the keys (WV@5816400)
FN agctx_placeholder_c
    sub rsp, 8
    xor eax, eax
    mov ecx, [rip + g_focus]
    cmp ecx, FOCUS_AGENTS
    je 9f
    cmp ecx, FOCUS_AGENT_INPUT
    je 9f
    call caps_ok
    test eax, eax
    jz 9f
    call agctx_has_selection
    test eax, eax
    jz 9f
    lea rax, [rip + .Lph_attach]
9:  add rsp, 8
    ret

# FN agctx_placeholder_e(DRV*) -> rax the box's placeholder (e): "⌘ Esc " (macOS; "ctrl esc " elsewhere) and
#   the driver's "to focus or unfocus Claude" (DRV_words), made once a driver
FN agctx_placeholder_e
    PROLOGUE
    mov rbx, rdi
    cmp rbx, [rip + ph_drv]
    je 8f
    mov [rip + ph_drv], rbx
    lea rdi, [rip + ph_sb]
    call sb_clear
    lea rdi, [rip + ph_sb]
    lea rsi, [rip + .Lph_key]
    call sb_push_cstr
    lea rax, [rip + generic_words]
    test rbx, rbx
    jz 1f
    mov rcx, [rbx + DRV_words]
    test rcx, rcx
    jz 1f
    mov rax, rcx
1:  mov rsi, [rax + 8*DW_UNFOCUS]
    lea rdi, [rip + ph_sb]
    call sb_push_cstr
    lea rdi, [rip + ph_sb]
    xor esi, esi
    call sb_push_byte
8:  mov rax, [rip + ph_sb + SB_ptr]
    EPILOGUE

# ---- the dump ----

# dismissed(AS* or 0) -> eax 1 when the chip would show but for its x
dismissed:
    PROLOGUE
    call marks
    xor ecx, ecx
    cmp qword ptr [rip + o_kind], 0
    je 9f
    cmp qword ptr [rip + o_kind], 2
    je 1f
    cmp rdx, [rip + o_hpath]
    sete cl
    jmp 9f
1:  cmp rax, [rip + o_hsel]
    sete cl
9:  mov eax, ecx
    EPILOGUE

# FN agctx_dump(sb): print-agent-context: "chip=0|1 label=L file=PATH lines=A-B ignored=0|1|? why=W checks=N
#   dismissed=0|1 sent=0|1 stash=0|1" for the box's conversation
FN agctx_dump
    PROLOGUE 16
    mov rbx, rdi
    call agctx_sync
    call agentext_box_owner
    mov r12, rax
    mov rdi, r12
    call agctx_label
    mov r13, rax
    mov rdi, rbx
    lea rsi, [rip + .Ld_chip]
    call sb_push_cstr
    xor esi, esi
    test r13, r13
    setnz sil
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_label]
    call sb_push_cstr
    mov rsi, r13
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Ldash]
1:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_file]
    call sb_push_cstr
    lea rsi, [rip + .Ldash]
    cmp qword ptr [rip + o_kind], 0
    je 2f
    mov rsi, [rip + o_path + SB_ptr]
2:  mov rdi, rbx
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_lines]
    call sb_push_cstr
    cmp qword ptr [rip + o_kind], 2
    je 3f
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    jmp 4f
3:  mov rdi, rbx
    mov rsi, [rip + o_l0]
    call sb_push_u64
    mov rdi, rbx
    mov esi, '-'
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [rip + o_l1]
    call sb_push_u64
4:  mov rdi, rbx
    lea rsi, [rip + .Ld_ignored]
    call sb_push_cstr
    cmp qword ptr [rip + o_kind], 2
    je 5f
    mov rdi, rbx
    mov esi, '?'
    call sb_push_byte
    lea r14, [rip + .Ldash]
    jmp 6f
5:  mov rdi, r12
    call agctx_ignored
    mov r15d, edx
    lea esi, [rax + '0']
    mov rdi, rbx
    call sb_push_byte
    lea rax, [rip + why_words]
    mov r14, [rax + r15*8]
6:  mov rdi, rbx
    lea rsi, [rip + .Ld_why]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r14
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_checks]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + checks]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_dismissed]
    call sb_push_cstr
    mov rdi, r12
    call dismissed
    mov rdi, rbx
    mov esi, eax
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_sent]
    call sb_push_cstr
    xor esi, esi
    test r12, r12
    jz 7f
    cmp qword ptr [r12 + AS_ctx_sent], 0
    setne sil
7:  mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ld_stash]
    call sb_push_cstr
    xor esi, esi
    cmp qword ptr [rip + stash_until], 0
    setne sil
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx                # "tip TEXT" when the chip shows
    lea rsi, [rip + .Ld_tip]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    call agctx_tip
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    EPILOGUE

.bss
.p2align 3
ph_drv: .quad 0                 # the placeholder (e) made for that driver
ph_sb: .zero SB_SIZE

.section .rodata
.ifdef MACOS
.Lph_attach: .asciz "\xe2\x8c\x98 Esc to attach selected text"
.Lph_key: .asciz "\xe2\x8c\x98 Esc "
.else
.Lph_attach: .asciz "ctrl esc to attach selected text"
.Lph_key: .asciz "ctrl esc "
.endif
.Ll_lines: .asciz " lines selected"
.Ll_line: .asciz " line selected"
.Lt_open: .asciz " ("
.Lt_big: .asciz " \xc2\xb7 only the file's name goes: the selection is larger than 1 MB"
.Ldot_git: .asciz "/.git"
.Lg_check: .asciz "check-ignore"
.Lg_q: .asciz "-q"
.Lg_dashes: .asciz "--"
.Lempty: .asciz ""
.Ldash: .asciz "-"
.Lr_one: .asciz "1 selected path was"
.Lr_many: .asciz " selected paths were"
.Lr_tail: .asciz " not added to the chat. Some paths can't be @-mentioned, such as one with # or a double quote in it. Describe the file or folder in your message instead."
.Lw_unfocus: .asciz "to focus or unfocus the agent"
.Lw_refused: .asciz "This path can't be @-mentioned: "
.Lw_seltip: .asciz "Showing the agent your current file selection"
.Ld_chip: .asciz "chip="
.Ld_label: .asciz " label="
.Ld_file: .asciz " file="
.Ld_lines: .asciz " lines="
.Ld_ignored: .asciz " ignored="
.Ld_why: .asciz " why="
.Ld_checks: .asciz " checks="
.Ld_dismissed: .asciz " dismissed="
.Ld_sent: .asciz " sent="
.Ld_stash: .asciz " stash="
.Ld_tip: .asciz "tip "
.Lw_exclude: .asciz "exclude"
.Lw_git: .asciz "git"
.Lw_paused: .asciz "paused"
.Lw_nogit: .asciz "nogit"
.Lw_failed: .asciz "failed"
.Lw_slow: .asciz "slow"
.Lw_norepo: .asciz "norepo"
.Lw_off: .asciz "off"
.Lw_unasked: .asciz "unasked"
.p2align 3
generic_words: .quad .Lw_unfocus, .Lw_refused, .Lw_seltip
why_words: .quad .Lw_exclude, .Lw_git, .Lw_paused, .Lw_nogit, .Lw_failed, .Lw_slow, .Lw_norepo, .Lw_off
    .quad .Lw_unasked, .Ldash
