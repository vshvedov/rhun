# Claude Code's dialogs that change its configuration (claude-chat-p7b): MCP servers, Hooks, Permission
# rules, Sandbox, Manage Plugins (ext-webview-ui.md 6.1 to 6.10, 4.19). Each is the generic shell's
# (agentdlg.s, with agentdlg2.s's form rows) filled from what Claude Code answers; nothing above the driver
# knows them. Reached through DRV_action (claude_action: ACT_MCP .. ACT_PLUGINS); the answers to their
# control requests come through agent_claude.s's OA_DIALOG2 (claude_dlg2_answer).
#
# As the extension does it (ext-host-protocol.md 2.4, 1.3, 7; README findings 80 on): what a dialog lists
# comes from control requests to the conversation's process (mcp_status, get_hooks_listing,
# list_permission_rules, get_sandbox_dialog; a process is started quietly for them, as the extension's
# session is) or from `claude plugin list --json` and `claude plugin marketplace list --json`; what it
# changes goes through the CLI itself: control requests (mcp_toggle, mcp_reconnect, mcp_clear_auth,
# mcp_authenticate, mcp_oauth_callback_url, reload_plugins) or a run of claude (`mcp add|remove`, `edit-hook
# --json`, `edit-permission-rules --json`, `edit-sandbox-settings --json`, `plugin install|uninstall|enable|
# disable|update|configure`, `plugin marketplace add|remove|update`) with the conversation's environment,
# in its folder. rhun never writes a settings file itself, and nothing is written but by the user's own
# act in the dialog, exactly as it shows (the scope included); removing confirms first.
#
# Secrets: mcp_status reports a server's headers and environment; rhun keeps none of it (the list it keeps
# is rewritten without them), never logs a command line, and the error text of `claude mcp add` has the
# values typed redacted. The form's fields are emptied when the dialog closes.
# Hostile text (names, descriptions, errors from the CLI): cut to a bound, control, bidi and zero-width
# characters left out (c2_clean); a URL opens only through links_ask_open.
#
#   claude_dlg2_open(AL*, act, ptr, len) -> eax 1   the dialog of that command (0: not one of these)
#   claude_dlg2_answer(AL*, control_response's response, n)   an answer to the dialog's request n
#   claude_dlg2_install_link(AS*, plugin cstr, source cstr) -> eax 1   Manage Plugins on a link's plugin
#     (4.19's trust confirmation when its marketplace is not added yet)
.include "rhun.inc"

.equ K_MCP, 0                   # the dialogs (mods' rows; act - ACT_MCP)
.equ K_HOOKS, 1
.equ K_PERMS, 2
.equ K_SANDBOX, 3
.equ K_PLUGINS, 4
.equ K_COUNT, 5
.equ M_OPEN, 0                  # a module's functions: (ptr, len) the dialog opens with its command's rest
.equ M_ACT, 8                   #   (act, arg, DR*)
.equ M_ANSWER, 16               #   (rq, envelope) a control request's answer
.equ M_RAN, 24                  #   (what, code) a run of claude ended: c2_out, c2_eout
.equ M_SEND, 32                 #   (rq, AL*) -> rax the request's number (begun, members written), -1 none
.equ M_FREE, 40                 #   () it closes
.equ M_NAME, 48                 #   its name (print-agent-dialog)
.equ M_TITLE, 56
.equ M_START, 64                #   1: its requests start a process quietly
.equ M_TICK, 72                 #   () the time c2_later asked for has come
.equ M_SIZE, 80
.equ OUT_MAX, 4194304           # a run's output kept at most (bytes)
.equ IN_MAX, 61440              # what a run is given on its stdin at most (it fits a pipe's buffer)
.equ ARGS_MAX, 64               # a run's arguments (after the program)
.equ CLEAN_MAX, 2000            # a text from the CLI shown at most (bytes)
.equ NAME_MAX, 200
# MCP: pages, acts, requests, runs
.equ MP_LIST, 0
.equ MP_DETAIL, 1
.equ MP_ADD, 2
.equ MA_RETRY, 1
.equ MA_SERVER, 2
.equ MA_BACK, 3
.equ MA_ADDFORM, 4
.equ MA_LEARN, 5
.equ MA_RECONNECT, 6
.equ MA_CLEARAUTH, 7
.equ MA_DISABLE, 8
.equ MA_ENABLE, 9
.equ MA_AUTH, 10
.equ MA_CHECK, 11
.equ MA_REMOVE, 12
.equ MA_CONFIRM, 13
.equ MA_CANCEL, 14
.equ MA_TOOLS, 15
.equ MA_TRANSPORT, 16
.equ MA_SCOPE, 17
.equ MA_SUBMIT, 18
.equ MA_REOPEN, 19
.equ MA_CALLBACK, 20
.equ MR_LIST, 1
.equ MR_RECONNECT, 2
.equ MR_DISABLE, 3
.equ MR_ENABLE, 4
.equ MR_CLEARAUTH, 5
.equ MR_AUTH, 6
.equ MR_CALLBACK, 7
.equ MW_ADD, 1
.equ MW_REMOVE, 2
.equ SCOPES_N, 6
.equ SIDX_MAX, 512              # a scope's servers sorted at most

.data
.p2align 3
.globl c2_kind
c2_kind: .quad -1               # the open dialog (K_*), -1 none
run_fd_out: .long -1
run_fd_err: .long -1

.bss
.p2align 3
.globl c2_page, c2_arg, c2_busy, c2_doc, c2_doc2, c2_doc3, c2_msg, c2_err, c2_out, c2_eout, c2_in, fsb
c2_page: .quad 0                # the page shown (a module's)
c2_arg: .quad 0                 # the page's subject (a row's index)
c2_busy: .quad 0                # what runs (a module's act, for its button's words), 0 nothing
c2_doc: .zero SB_SIZE           # the kept list, as JSON text (parsed again for each build)
c2_doc2: .zero SB_SIZE
c2_doc3: .zero SB_SIZE
c2_msg: .zero SB_SIZE           # a notice above the rows
c2_err: .zero SB_SIZE           # an error above the rows
c2_out: .zero SB_SIZE           # a run's stdout, its stderr
c2_eout: .zero SB_SIZE
c2_in: .zero SB_SIZE            # what the next run gets on its stdin
fsb: .zero SB_SIZE              # a text being made
csb: .zero SB_SIZE              # c2_clean's
esb: .zero SB_SIZE              # c2_errout's
asb: .zero SB_SIZE              # a run's arguments, NUL-separated
aoff: .zero 8 * ARGS_MAX        # their offsets in asb
an: .quad 0                     # their count
.globl c2_as
c2_as: .quad 0                  # the open dialog's conversation
c2_rq: .quad 0                  # the request waited for
c2_pend: .quad 0                # the request to send once the process is ready
c2_gen: .quad 0                 # the dialog's generation (a run's end for an older one is dropped)
run_pid: .quad 0                # the run's process, 0 none
run_gen: .quad 0
run_what: .quad 0
run_open: .long 0               # pipes still open (2: stdout and stderr)
.p2align 3
c2_tick_at: .quad 0             # time_ms of the module's M_TICK (c2_later), 0 none
c2_tick_gen: .quad 0
.p2align 3
# MCP's own
m_name: .quad 0                 # owned cstr: the server the detail page shows
m_confirm: .long 0              # the detail page asks to confirm Remove
m_tools: .long 0                # its tools shown
m_authwait: .long 0             # authentication in the browser for m_name
m_localhost: .long 0            # its redirect may fail: the paste box
m_transport: .long 0            # the add form's choices: 0 stdio, 1 http, 2 sse
m_scope: .long 0                #   0 local, 1 user, 2 project
.p2align 3
m_authurl: .quad 0              # owned cstr: the authentication page
.globl m_tf_name
m_tf_name: .zero TF_SIZE        # the add form's fields
m_tf_cmd: .zero TF_SIZE
m_tf_args: .zero TF_SIZE
m_tf_env: .zero TF_SIZE
m_tf_url: .zero TF_SIZE
m_tf_hdr: .zero TF_SIZE
m_tf_cb: .zero TF_SIZE          # the redirect URL pasted
sidx: .zero 4 * SIDX_MAX        # scope_sorted's
sidx_n: .quad 0

.text

# ======================================================================================================
# shared: text, rows, the kept list
# ======================================================================================================

# FN f_clr(), f_c(cstr or 0), f_n(ptr, len), f_u(u64), f_cl(ptr, len, max) (c2_clean'd), f_get() -> rax ptr,
#   rdx len: fsb, a text being made
FN f_clr
    lea rdi, [rip + fsb]
    jmp sb_clear
FN f_c
    test rdi, rdi
    jz 1f
    mov rsi, rdi
    lea rdi, [rip + fsb]
    jmp sb_push_cstr
1:  ret
FN f_n
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + fsb]
    jmp sb_push
FN f_u
    mov rsi, rdi
    lea rdi, [rip + fsb]
    jmp sb_push_u64
FN f_cl
    push rbx
    call c2_clean
    mov rdi, rax
    mov rsi, rdx
    call f_n
    pop rbx
    ret
FN f_get
    mov rax, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    ret

# FN c2_clean(ptr, len, max) -> rax ptr, rdx len (csb; valid until the next call): a text from the CLI for
#   one line: control characters become spaces; C1 controls, the bidi marks and embeddings (U+061C,
#   U+200E-U+200F, U+202A-U+202E, U+2066-U+2069), zero-width spaces (U+200B, U+200C, U+FEFF) and bytes that are
#   not UTF-8 are left out; past max bytes it is cut at a character's end with "…"
FN c2_clean
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + csb]
    call sb_clear
    xor r14d, r14d              # the byte read
1:  cmp r14, r12
    jae 9f
    mov rax, [rip + csb + SB_len]
    cmp rax, r13
    jae 8f
    movzx eax, byte ptr [rbx + r14]
    cmp eax, 0x80
    jae 3f
    inc r14
    cmp eax, 0x20
    jb 2f
    cmp eax, 0x7f
    je 2f
    mov esi, eax
    jmp 7f
2:  mov esi, ' '
7:  lea rdi, [rip + csb]
    call sb_push_byte
    jmp 1b
3:  mov rdi, rbx                # a sequence: its length when valid
    add rdi, r14
    mov rsi, r12
    sub rsi, r14
    call utf8_len
    test eax, eax
    jz 6f
    mov r15d, eax
    movzx ecx, byte ptr [rbx + r14]
    movzx edx, byte ptr [rbx + r14 + 1]
    cmp ecx, 0xc2               # C1 controls
    jne 31f
    cmp edx, 0xa0
    jb 5f
31: cmp ecx, 0xd8               # U+061C
    jne 32f
    cmp edx, 0x9c
    je 5f
32: cmp ecx, 0xe2
    jne 34f
    movzx eax, byte ptr [rbx + r14 + 2]
    cmp edx, 0x80
    jne 33f
    cmp eax, 0x8b               # U+200B, U+200C (not the joiner U+200D: emoji need it)
    je 5f
    cmp eax, 0x8c
    je 5f
    cmp eax, 0x8e               # U+200E, U+200F
    je 5f
    cmp eax, 0x8f
    je 5f
    cmp eax, 0xaa               # U+202A..U+202E
    jb 35f
    cmp eax, 0xae
    jbe 5f
    jmp 35f
33: cmp edx, 0x81
    jne 35f
    cmp eax, 0xa6               # U+2066..U+2069
    jb 35f
    cmp eax, 0xa9
    jbe 5f
    jmp 35f
34: cmp ecx, 0xef               # U+FEFF
    jne 35f
    cmp edx, 0xbb
    jne 35f
    cmp byte ptr [rbx + r14 + 2], 0xbf
    je 5f
35: mov rax, [rip + csb + SB_len]   # it fits whole, or the text is cut here
    add rax, r15
    cmp rax, r13
    ja 8f
    lea rdi, [rip + csb]
    lea rsi, [rbx + r14]
    mov edx, r15d
    call sb_push
5:  add r14, r15
    jmp 1b
6:  inc r14                     # not UTF-8: left out
    jmp 1b
8:  lea rdi, [rip + csb]
    lea rsi, [rip + .Lellipsis]
    call sb_push_cstr
9:  mov rax, [rip + csb + SB_ptr]
    mov rdx, [rip + csb + SB_len]
    EPILOGUE

# utf8_len(ptr, room) -> eax the bytes of the valid UTF-8 sequence there (2 to 4), 0 when it is not one
utf8_len:
    movzx eax, byte ptr [rdi]
    mov ecx, 2
    cmp eax, 0xc2
    jb 8f
    cmp eax, 0xe0
    jb 1f
    mov ecx, 3
    cmp eax, 0xf0
    jb 1f
    mov ecx, 4
    cmp eax, 0xf4
    ja 8f
1:  cmp rsi, rcx
    jb 8f
    mov edx, 1
2:  cmp edx, ecx
    jae 3f
    movzx eax, byte ptr [rdi + rdx]
    and eax, 0xc0
    cmp eax, 0x80
    jne 8f
    inc edx
    jmp 2b
3:  mov eax, ecx
    ret
8:  xor eax, eax
    ret

# FN c2_jstr(obj, key) -> rax ptr, rdx len of a string member (0, 0 else)
FN c2_jstr
    push rbx
    call json_get
    mov rdi, rax
    call json_str
    pop rbx
    ret

# FN c2_jbool(obj, key) -> eax 1 when the member is true
FN c2_jbool
    push rbx
    call json_get
    mov rdi, rax
    call json_type
    xor ecx, ecx
    cmp eax, JT_TRUE
    sete cl
    mov eax, ecx
    pop rbx
    ret

# FN c2_jcl(obj, key, max) -> rax ptr, rdx len: the member's string, c2_clean'd
FN c2_jcl
    push rbx
    mov rbx, rdx
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, rbx
    call c2_clean
    pop rbx
    ret

# FN c2_crow(kind, flags, act, t1, t2, t3 cstrs or 0) -> rax DGR*
FN c2_crow
    PROLOGUE 16
    mov [rsp], rcx
    mov r12, r8
    mov r13, r9
    call agentdlg_row
    mov rbx, rax
    mov rdx, [rsp]
    xor esi, esi
    call ctext
    mov rdx, r12
    mov esi, 1
    call ctext
    mov rdx, r13
    mov esi, 2
    call ctext
    mov rax, rbx
    EPILOGUE

# ctext(-, which, cstr or 0) on rbx's row
ctext:
    test rdx, rdx
    jz 1f
    mov rdi, rbx
    jmp agentdlg_ctext
1:  ret

# FN c2_frow(kind, flags, act) -> rax DGR*: its t1 fsb's text
FN c2_frow
    PROLOGUE
    call agentdlg_row
    mov rbx, rax
    mov rdi, rax
    xor esi, esi
    call c2_fset
    mov rax, rbx
    EPILOGUE

# FN c2_fset(DGR*, which): that text of the row fsb's
FN c2_fset
    mov rdx, [rip + fsb + SB_ptr]
    mov rcx, [rip + fsb + SB_len]
    test rdx, rdx
    jnz agentdlg_text
    lea rdx, [rip + .Lempty]
    jmp agentdlg_text

# FN c2_head(cstr), c2_text(cstr, flags), c2_link(cstr, act): a row of that kind
FN c2_head
    mov rcx, rdi
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    jmp crow3
FN c2_text
    mov rcx, rdi
    mov edi, DGK_TEXT
    xor edx, edx
    jmp crow3
FN c2_link
    mov rcx, rdi
    mov edx, esi
    mov edi, DGK_LINK
    xor esi, esi
crow3:
    xor r8d, r8d
    xor r9d, r9d
    jmp c2_crow

# FN c2_ftext(flags): a TEXT row of fsb's text
FN c2_ftext
    mov esi, edi
    mov edi, DGK_TEXT
    xor edx, edx
    jmp c2_frow

# FN c2_msgs(): the notice and the error above the rows, when there are any
FN c2_msgs
    PROLOGUE
    cmp qword ptr [rip + c2_msg + SB_len], 0
    je 1f
    mov edi, DGK_TEXT
    mov esi, DGF_MUTED
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, [rip + c2_msg + SB_ptr]
    mov rcx, [rip + c2_msg + SB_len]
    call agentdlg_text
1:  cmp qword ptr [rip + c2_err + SB_len], 0
    je 9f
    mov edi, DGK_TEXT
    mov esi, DGF_ERROR
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, [rip + c2_err + SB_ptr]
    mov rcx, [rip + c2_err + SB_len]
    call agentdlg_text
9:  EPILOGUE

# FN c2_notes_clear(): no notice, no error
FN c2_notes_clear
    lea rdi, [rip + c2_msg]
    call sb_clear
    lea rdi, [rip + c2_err]
    jmp sb_clear

# FN c2_err_set(ptr, len), c2_err_cset(cstr), c2_msg_fsb(), c2_err_fsb(): the error / the notice
FN c2_err_set
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + c2_err]
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    mov edx, CLEAN_MAX
    call c2_clean
    lea rdi, [rip + c2_err]
    mov rsi, rax
    call sb_push
    EPILOGUE
FN c2_err_cset
    push rdi
    call strlen
    mov rsi, rax
    pop rdi
    jmp c2_err_set
FN c2_msg_fsb
    lea rdi, [rip + c2_msg]
    jmp 1f
FN c2_err_fsb
    lea rdi, [rip + c2_err]
1:  push rdi
    call sb_clear
    pop rdi
    mov rsi, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    jmp sb_push

# FN c2_keep(sb, jv): sb = the value as JSON text (jw_jv; nothing else is being written then)
FN c2_keep
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call jw_begin
    mov rdi, rbx
    mov rsi, r12
    call jw_jv
    EPILOGUE

# FN c2_parse(sb) -> rax its JSON parsed again (0: none; the parse arena's, dead after the next parse)
FN c2_parse
    mov rsi, [rdi + SB_len]
    mov rdi, [rdi + SB_ptr]
    xor eax, eax
    test rsi, rsi
    jz 1f
    jmp json_parse
1:  ret

# FN c2_ok(envelope) -> eax 1 for a success; c2_resp(envelope) -> rax its response; c2_why(envelope) -> rax
#   ptr, rdx len of its error
FN c2_ok
    push rbx
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_success]
    call json_is
    pop rbx
    ret
FN c2_resp
    lea rsi, [rip + .Lk_response]
    jmp json_get
FN c2_why
    lea rsi, [rip + .Lk_error]
    jmp c2_jstr

# FN c2_dlg_title(cstr): the dialog's title (agentdlg_title)
FN c2_dlg_title
    jmp agentdlg_title

# FN c2_tf_text(TF*) -> rax ptr, rdx len trimmed of blanks and line ends at both ends
FN c2_tf_text
    push rbx
    call tf_text
    pop rbx
    mov rdi, rax
    mov rsi, rdx
    jmp c2_trim

# FN c2_trim(ptr, len) -> rax ptr, rdx len without blanks (space, tab, CR, LF) at both ends
FN c2_trim
    mov rax, rdi
    mov rdx, rsi
    test rax, rax
    jz 9f
1:  test rdx, rdx
    jz 9f
    movzx ecx, byte ptr [rax]
    cmp ecx, ' '
    ja 2f
    inc rax
    dec rdx
    jmp 1b
2:  movzx ecx, byte ptr [rax + rdx - 1]
    cmp ecx, ' '
    ja 9f
    dec rdx
    jmp 2b
9:  ret

# FN c2_line(ptr, len, i) -> rax ptr, rdx len of line i (0 len past the last), r8 1 when there is one
FN c2_line
    xor r8d, r8d
    xor ecx, ecx                # the line's start
1:  test rdx, rdx
    jz 3f
    dec rdx
    xor r9d, r9d
2:  lea r10, [rcx + r9]
    cmp r10, rsi
    jae 4f
    cmp byte ptr [rdi + r10], 10
    je 4f
    inc r9
    jmp 2b
4:  lea rcx, [rcx + r9 + 1]
    cmp rcx, rsi
    ja 5f
    jmp 1b
5:  xor eax, eax
    xor edx, edx
    ret
3:  cmp rcx, rsi
    ja 5b
    lea rax, [rdi + rcx]
    xor edx, edx
6:  lea r10, [rcx + rdx]
    cmp r10, rsi
    jae 7f
    cmp byte ptr [rdi + r10], 10
    je 7f
    inc rdx
    jmp 6b
7:  mov r8d, 1
    ret

# ======================================================================================================
# opening, asking, answers
# ======================================================================================================

# FN claude_dlg2_open(AL*, act, ptr, len) -> eax 1 when act is one of these dialogs': it opens over the panel
FN claude_dlg2_open
    PROLOGUE
    mov rbx, rdi
    mov r14, rdx
    mov r15, rcx
    xor eax, eax
    lea ecx, [rsi - ACT_MCP]
    cmp ecx, K_COUNT
    jae 9f
    test rbx, rbx
    jz 9f
    mov r12d, ecx
    imul r13, r12, M_SIZE
    lea rax, [rip + mods]
    add r13, rax
    mov rdi, [rbx + AL_as]
    mov rsi, [r13 + M_NAME]
    mov rdx, [r13 + M_TITLE]
    lea rcx, [rip + c2_ops]
    call agentdlg_open          # (the dialog before is freed first)
    mov [rip + c2_kind], r12
    mov rax, [rbx + AL_as]
    mov [rip + c2_as], rax
    inc qword ptr [rip + c2_gen]
    mov qword ptr [rip + c2_page], 0
    mov qword ptr [rip + c2_arg], 0
    mov qword ptr [rip + c2_busy], 0
    call c2_notes_clear
    mov rdi, r14
    mov rsi, r15
    call [r13 + M_OPEN]
    mov eax, 1
9:  EPILOGUE

# mod() -> rax the open dialog's module row (0 none)
mod:
    mov rax, [rip + c2_kind]
    cmp rax, K_COUNT
    jae 1f
    imul rax, rax, M_SIZE
    lea rcx, [rip + mods]
    add rax, rcx
    ret
1:  xor eax, eax
    ret

# is_up(AL*) -> eax 1 when its process is up and past its handshake
is_up:
    xor eax, eax
    test rdi, rdi
    jz 9f
    cmp dword ptr [rdi + AL_cn + CN_state], CN_UP
    jne 9f
    mov ecx, [rdi + AL_state]
    cmp ecx, ALS_READY
    je 1f
    cmp ecx, ALS_WORKING
    je 1f
    cmp ecx, ALS_WAITING
    jne 9f
1:  mov eax, 1
9:  ret

# FN c2_up() -> eax 1 when the open dialog's conversation has its process up
FN c2_up
    PROLOGUE
    mov rdi, [rip + c2_as]
    xor eax, eax
    test rdi, rdi
    jz 9f
    call agent_live_get
    mov rdi, rax
    call is_up
9:  EPILOGUE

# FN c2_ask(rq): the dialog's control request now (the process up), once the process is ready (starting),
#   or after starting it quietly (off: the dialogs that start one); else the dialog fails saying why
FN c2_ask
    PROLOGUE
    mov r12, rdi
    mov rdi, [rip + c2_as]
    test rdi, rdi
    jz 9f
    call agent_live
    mov rbx, rax
    test rax, rax
    jz 9f
    mov rdi, rbx
    call is_up
    test eax, eax
    jz 1f
    mov rdi, r12
    mov rsi, rbx
    call send
    jmp 9f
1:  mov eax, [rbx + AL_state]
    cmp eax, ALS_STARTING
    je 3f
    cmp eax, ALS_HELD
    je 3f
    mov rdi, [rbx + AL_as]
    call agent_run
    mov rdi, [rip + c2_as]
    call agent_live
    mov rbx, rax
    mov rdi, rax
    call is_up
    test eax, eax
    jz 2f
    mov rdi, r12
    mov rsi, rbx
    call send
    jmp 9f
2:  mov eax, [rbx + AL_state]
    cmp eax, ALS_STARTING
    je 3f
    cmp eax, ALS_HELD
    je 3f
    call f_clr                  # it could not start: what it said, else that
    mov rdx, [rbx + AL_report + SB_len]
    test rdx, rdx
    jz 21f
    mov rdi, [rbx + AL_report + SB_ptr]
    mov rsi, rdx
    call f_n
    jmp 22f
21: lea rdi, [rip + .Lno_start]
    call f_c
22: mov qword ptr [rip + c2_busy], 0
    call f_get
    mov rdi, rax
    mov rsi, rdx
    call agentdlg_fail
    jmp 9f
3:  mov [rip + c2_pend], r12
    mov rdi, rbx
    call agentdlg_pend
9:  EPILOGUE

# send(rq, AL*): the module writes its request; it goes, the dialog waits for its answer
send:
    PROLOGUE
    mov r12, rdi
    mov rbx, rsi
    call mod
    test rax, rax
    jz 9f
    mov [rip + c2_rq], r12
    mov rdi, r12
    mov rsi, rbx
    call [rax + M_SEND]
    cmp rax, -1
    je 9f
    mov r13, rax
    mov rdi, rbx
    call claude_dlg2_end
    test eax, eax
    jz 7f
    mov rdi, rbx
    mov rsi, r13
    call agentdlg_wait
    EPILOGUE
7:  mov qword ptr [rip + c2_busy], 0
    lea rdi, [rip + .Lnot_sent]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Lnot_sent]
    call agentdlg_fail
9:  EPILOGUE

# FN claude_dlg2_answer(AL*, envelope, n): the answer to the dialog's request n (one it no longer waits for
#   is dropped)
FN claude_dlg2_answer
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rsi, rdx
    call agentdlg_waits
    test eax, eax
    jz 9f
    call mod
    test rax, rax
    jz 9f
    mov qword ptr [rip + c2_busy], 0
    mov rdi, [rip + c2_rq]
    mov rsi, r12
    call [rax + M_ANSWER]
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# c2_act(act, arg, DGR*): the shell's call: DA_ASK sends the request that waited; anything else the module's
c2_act:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    cmp r12d, DA_ASK
    jne 1f
    mov rdi, [rip + c2_as]
    call agent_live_get
    test rax, rax
    jz 9f
    cmp dword ptr [rax + AL_cn + CN_state], CN_UP
    jne 9f
    mov rdi, [rip + c2_pend]
    mov rsi, rax
    call send
    jmp 9f
1:  call mod
    test rax, rax
    jz 9f
    mov edi, r12d
    mov rsi, r13
    mov rdx, r14
    call [rax + M_ACT]
9:  EPILOGUE

# c2_free(): the shell's call as it closes: the module's, then what is kept goes (a run goes on to its end,
#   its answer dropped)
c2_free:
    PROLOGUE
    call mod
    test rax, rax
    jz 1f
    call [rax + M_FREE]
1:  mov qword ptr [rip + c2_kind], -1
    mov qword ptr [rip + c2_tick_at], 0
    mov qword ptr [rip + c2_as], 0
    mov qword ptr [rip + c2_busy], 0
    inc qword ptr [rip + c2_gen]
    lea rdi, [rip + c2_doc]
    call sb_free_clear
    lea rdi, [rip + c2_doc2]
    call sb_free_clear
    lea rdi, [rip + c2_doc3]
    call sb_free_clear
    call c2_notes_clear
    lea rdi, [rip + c2_in]
    call wipe
    EPILOGUE

# sb_free_clear(sb): emptied
sb_free_clear:
    jmp sb_clear

# FN c2_wipe_tf(TF*): a field's text overwritten and emptied (a secret may have been typed in it)
FN c2_wipe_tf
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + TF_sb]
    call wipe
    mov rdi, rbx
    call tf_clear
    pop rbx
    ret

# wipe(sb): its bytes zeroed, then emptied
wipe:
    mov rcx, [rdi + SB_len]
    mov rax, [rdi + SB_ptr]
    test rax, rax
    jz 2f
1:  test rcx, rcx
    jz 2f
    dec rcx
    mov byte ptr [rax + rcx], 0
    jmp 1b
2:  jmp sb_clear

# FN c2_gone() -> eax 1 when the dialog is no longer this module's (closed, or another opened)
FN c2_shown
    xor eax, eax
    cmp qword ptr [rip + c2_kind], K_COUNT
    setb al
    ret

# ======================================================================================================
# a run of claude: `claude ARGS` in the conversation's folder with its program's environment, c2_in on its
#   stdin, stdout and stderr kept (OUT_MAX each); its end goes to the module's M_RAN
# ======================================================================================================

# FN c2_args(): the arguments emptied; c2_arg_c(cstr), c2_arg_n(ptr, len): one more
FN c2_args
    mov qword ptr [rip + an], 0
    lea rdi, [rip + asb]
    jmp wipe
FN c2_arg_c
    push rdi
    call strlen
    mov rsi, rax
    pop rdi
FN c2_arg_n
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rip + an]
    cmp rax, ARGS_MAX
    jae 9f
    mov rcx, [rip + asb + SB_len]
    lea rdx, [rip + aoff]
    mov [rdx + rax*8], rcx
    inc qword ptr [rip + an]
    lea rdi, [rip + asb]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    lea rdi, [rip + asb]
    xor esi, esi
    call sb_push_byte
9:  EPILOGUE

# FN c2_run(what) -> eax 1 when it runs: claude with the arguments made (c2_args ...); none may run already
FN c2_run
    PROLOGUE 16 + 8 * (ARGS_MAX + 16)
    mov [rsp], rdi
    xor eax, eax
    cmp qword ptr [rip + run_pid], 0
    jne 9f
    mov rdi, [rip + c2_as]
    test rdi, rdi
    jz 9f
    call agent_live
    test rax, rax
    jz 9f
    mov [rsp + 8], rax          # AL*
    call claude_exe
    test rax, rax
    jz .Lr_none
    mov r15, rax                # the prefix (owned)
    lea r14, [rsp + 16]         # argv
    xor ecx, ecx
1:  cmp ecx, edx
    jae 2f
    cmp ecx, 8
    jae 2f
    mov r8, [rax + rcx*8]
    mov [r14 + rcx*8], r8
    inc ecx
    jmp 1b
2:  xor edx, edx                # the arguments
3:  cmp rdx, [rip + an]
    jae 4f
    lea r8, [rip + aoff]
    mov r8, [r8 + rdx*8]
    add r8, [rip + asb + SB_ptr]
    mov [r14 + rcx*8], r8
    inc ecx
    inc rdx
    jmp 3b
4:  mov qword ptr [r14 + rcx*8], 0
    sub rsp, 32                 # the pipes: [0] in (it reads, rhun writes), [8] out, [16] err (rhun reads)
    lea rdi, [rsp]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    jnz .Lr_nopipe
    lea rdi, [rsp + 8]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    jnz .Lr_nopipe1
    lea rdi, [rsp + 16]
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    jnz .Lr_nopipe2
    mov rdi, [rsp + 32 + 8]
    call claude_dlg2_env
    mov rbx, rax
    mov rdi, [rsp + 32 + 8]
    call claude_dlg2_cwd
    mov rdx, rax
    mov rdi, r14
    mov rsi, rbx
    mov ecx, [rsp]
    mov r8d, [rsp + 12]
    mov r9d, [rsp + 20]
    xor eax, eax
    push rax
    push rax
    call uproc_spawn
    add rsp, 16
    mov r12, rax
    mov rdi, rbx
    call mem_free
    mov edi, [rsp]              # the child's ends
    SYS SYS_close
    mov edi, [rsp + 12]
    SYS SYS_close
    mov edi, [rsp + 20]
    SYS SYS_close
    test r12, r12
    jle .Lr_spawnfail
    mov rsi, [rip + c2_in + SB_ptr]     # its stdin: what was made, then closed
    mov rdx, [rip + c2_in + SB_len]
    cmp rdx, IN_MAX
    jbe 5f
    mov rdx, IN_MAX
5:  test rdx, rdx
    jz 6f
    mov edi, [rsp + 4]
    SYS SYS_write
6:  mov edi, [rsp + 4]
    SYS SYS_close
    lea rdi, [rip + c2_in]
    call wipe
    lea rdi, [rip + c2_out]
    call sb_clear
    lea rdi, [rip + c2_eout]
    call sb_clear
    mov edi, [rsp + 8]
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov edi, [rsp + 16]
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    mov edi, [rsp + 8]
    mov esi, POLLIN
    lea rdx, [rip + on_out]
    lea rcx, [rip + c2_out]
    call watch_try_add
    test eax, eax
    jz .Lr_nowatch
    mov edi, [rsp + 16]
    mov esi, POLLIN
    lea rdx, [rip + on_out]
    lea rcx, [rip + c2_eout]
    call watch_try_add
    test eax, eax
    jz .Lr_nowatch2
    mov eax, [rsp + 8]
    mov [rip + run_fd_out], eax
    mov eax, [rsp + 16]
    mov [rip + run_fd_err], eax
    mov dword ptr [rip + run_open], 2
    mov [rip + run_pid], r12
    mov rax, [rip + c2_gen]
    mov [rip + run_gen], rax
    mov rax, [rsp + 32]
    mov [rip + run_what], rax
    add rsp, 32
    mov rdi, r15
    call mem_free
    lea rdi, [rip + asb]
    call wipe
    mov eax, 1
    EPILOGUE
.Lr_nowatch2:
    mov edi, [rsp + 8]
    call watch_remove
.Lr_nowatch:
    mov edi, r12d
    mov esi, 2000
    call uproc_end
    mov edi, [rsp + 8]
    SYS SYS_close
    mov edi, [rsp + 16]
    SYS SYS_close
    jmp .Lr_fail
.Lr_spawnfail:
    mov edi, [rsp + 4]
    SYS SYS_close
    mov edi, [rsp + 8]
    SYS SYS_close
    mov edi, [rsp + 16]
    SYS SYS_close
    jmp .Lr_fail
.Lr_nopipe2:
    mov edi, [rsp + 8]
    SYS SYS_close
    mov edi, [rsp + 12]
    SYS SYS_close
.Lr_nopipe1:
    mov edi, [rsp]
    SYS SYS_close
    mov edi, [rsp + 4]
    SYS SYS_close
.Lr_nopipe:
.Lr_fail:
    add rsp, 32
    mov rdi, r15
    call mem_free
.Lr_none:
    lea rdi, [rip + asb]
    call wipe
    lea rdi, [rip + c2_in]
    call wipe
    xor eax, eax
9:  EPILOGUE

# on_out(fd, events, sb ctx): a run's output, kept up to OUT_MAX bytes; both ends closed: its end
on_out:
    PROLOGUE
    mov ebx, edi
    mov r12, rdx
1:  mov rdi, r12
    mov esi, 65536
    call sb_reserve
    mov rsi, rax
    mov edi, ebx
    mov edx, 65536
    SYS SYS_read
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 9f
    test rax, rax
    jle 2f
    mov rcx, [r12 + SB_len]
    cmp rcx, OUT_MAX
    jae 1b                      # past the limit: read and dropped
    add [r12 + SB_len], rax
    jmp 1b
2:  mov edi, ebx
    call watch_remove
    mov edi, ebx
    SYS SYS_close
    cmp ebx, [rip + run_fd_out]
    jne 3f
    mov dword ptr [rip + run_fd_out], -1
3:  cmp ebx, [rip + run_fd_err]
    jne 4f
    mov dword ptr [rip + run_fd_err], -1
4:  dec dword ptr [rip + run_open]
    jnz 9f
    call run_end
9:  EPILOGUE

# run_end(): both its ends closed: its exit code (waited for: it is ending), then the module's M_RAN when
#   the dialog that ran it still shows
run_end:
    PROLOGUE
    mov rdi, [rip + run_pid]
    mov qword ptr [rip + run_pid], 0
    mov r12, rdi
    xor esi, esi                # its outputs are closed: it is ending (waited for)
    call uproc_wait
    mov rbx, rax
1:  mov rax, [rip + run_gen]
    cmp rax, [rip + c2_gen]
    jne 9f
    call mod
    test rax, rax
    jz 9f
    mov qword ptr [rip + c2_busy], 0
    mov rdi, [rip + run_what]
    mov rsi, rbx
    call [rax + M_RAN]
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN c2_later(ms): the module's M_TICK in that many ms (one at a time: a later call moves it)
FN c2_later
    push rbx
    mov rbx, rdi
    call time_ms
    add rax, rbx
    mov [rip + c2_tick_at], rax
    mov rax, [rip + c2_gen]
    mov [rip + c2_tick_gen], rax
    pop rbx
    ret

# FN claude_dlg2_timeout() -> eax ms until a dialog's M_TICK (0: now), -1 none
FN claude_dlg2_timeout
    mov rax, [rip + c2_tick_at]
    test rax, rax
    jz 8f
    push rbx
    mov rbx, rax
    call time_ms
    mov rcx, rbx
    pop rbx
    sub rcx, rax
    xor eax, eax
    test rcx, rcx
    cmovg eax, ecx
    ret
8:  mov eax, -1
    ret

# FN claude_dlg2_tick(): a dialog's M_TICK once its time has come (dropped when the dialog went)
FN claude_dlg2_tick
    PROLOGUE
    mov rbx, [rip + c2_tick_at]
    test rbx, rbx
    jz 9f
    call time_ms
    cmp rax, rbx
    jl 9f
    mov qword ptr [rip + c2_tick_at], 0
    mov rax, [rip + c2_tick_gen]
    cmp rax, [rip + c2_gen]
    jne 9f
    call mod
    test rax, rax
    jz 9f
    call [rax + M_TICK]
    mov dword ptr [rip + g_dirty], 1
9:  EPILOGUE

# FN c2_errthing(code, thing cstr): fsb = a write's error as the extension words it (Hl): the run's stderr
#   (c2_errout), else "Claude Code could not save THING (exit code N)."
FN c2_errthing
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rip + c2_eout + SB_ptr]
    mov rsi, [rip + c2_eout + SB_len]
    call c2_trim
    test rdx, rdx
    jz 1f
    mov rdi, rbx
    call c2_errout
    EPILOGUE
1:  call f_clr
    lea rdi, [rip + .Lcould_not]
    call f_c
    mov rdi, r12
    call f_c
    lea rdi, [rip + .Lexit_code]
    call f_c
    mov rdi, rbx
    call f_u
    lea rdi, [rip + .Lclose_dot]
    call f_c
    EPILOGUE

# FN c2_running() -> eax 1 while a run goes on
FN c2_running
    xor eax, eax
    cmp qword ptr [rip + run_pid], 0
    setne al
    ret

# FN c2_last_json(sb) -> rax the last line of the output that parses as JSON (from its end; 0 none)
FN c2_last_json
    PROLOGUE
    mov rbx, [rdi + SB_ptr]
    mov r12, [rdi + SB_len]
    xor eax, eax
    test rbx, rbx
    jz 9f
1:  test r12, r12               # the last line's end without its line ends
    jz 8f
    movzx eax, byte ptr [rbx + r12 - 1]
    cmp eax, ' '
    ja 2f
    dec r12
    jmp 1b
2:  mov r13, r12                # its start
3:  test r13, r13
    jz 4f
    cmp byte ptr [rbx + r13 - 1], 10
    je 4f
    dec r13
    jmp 3b
4:  lea rdi, [rbx + r13]
    mov rsi, r12
    sub rsi, r13
    call json_parse
    test rax, rax
    jnz 9f
    mov r12, r13                # the line before
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# FN c2_errout(fsb): fsb = the run's error text, as the extension words it (Hl, Op): its stderr without
#   colour codes, trimmed, without a leading "Error: " (else "Claude Code exited with code N"; code in rdi)
FN c2_errout
    PROLOGUE
    mov rbx, rdi
    call f_clr
    mov rdi, [rip + c2_eout + SB_ptr]
    mov rsi, [rip + c2_eout + SB_len]
    call c2_trim
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, r13                # colour codes out
    jae 5f
    movzx esi, byte ptr [r12 + r14]
    inc r14
    cmp esi, 27
    jne 4f
    cmp r14, r13
    jae 5f
    cmp byte ptr [r12 + r14], '['
    jne 1b
2:  inc r14
    cmp r14, r13
    jae 5f
    movzx eax, byte ptr [r12 + r14]
    cmp eax, 'm'
    jne 2b
    inc r14
    jmp 1b
4:  lea rdi, [rip + fsb]
    call sb_push_byte
    jmp 1b
5:  mov rdi, [rip + fsb + SB_ptr]
    mov rsi, [rip + fsb + SB_len]
    call c2_trim
    mov r12, rax
    mov r13, rdx
    cmp r13, 7
    jb 6f
    mov rdi, r12
    mov rsi, 7
    lea rdx, [rip + .Lerror_colon]
    call str_eq_cstr
    test eax, eax
    jz 6f
    add r12, 7
    sub r13, 7
    mov rdi, r12
    mov rsi, r13
    call c2_trim
    mov r12, rax
    mov r13, rdx
6:  test r13, r13
    jz 7f
    lea rdi, [rip + esb]        # (fsb's own bytes: through esb)
    call sb_clear
    lea rdi, [rip + esb]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    call f_clr
    mov rdi, [rip + esb + SB_ptr]
    mov rsi, [rip + esb + SB_len]
    mov edx, CLEAN_MAX
    call f_cl
    EPILOGUE
7:  call f_clr
    lea rdi, [rip + .Lexited]
    call f_c
    mov rdi, rbx
    call f_u
    EPILOGUE

# ======================================================================================================
# MCP servers (6.1, 6.2, 6.3)
# ======================================================================================================

mcp_open:
    PROLOGUE
    mov dword ptr [rip + m_confirm], 0
    mov dword ptr [rip + m_tools], 0
    mov dword ptr [rip + m_authwait], 0
    mov dword ptr [rip + m_localhost], 0
    mov rdi, [rip + m_name]
    call mem_free
    mov qword ptr [rip + m_name], 0
    mov rdi, [rip + m_authurl]
    call mem_free
    mov qword ptr [rip + m_authurl], 0
    lea rdi, [rip + .Lm_loading]
    call agentdlg_loading
    mov edi, MR_LIST
    call c2_ask
    EPILOGUE

mcp_free:
    PROLOGUE
    lea rdi, [rip + m_tf_name]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_cmd]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_args]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_env]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_url]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_hdr]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_cb]
    call c2_wipe_tf
    mov rdi, [rip + m_name]
    call mem_free
    mov qword ptr [rip + m_name], 0
    mov rdi, [rip + m_authurl]
    call mem_free
    mov qword ptr [rip + m_authurl], 0
    EPILOGUE

# mcp_send(rq, AL*) -> rax the request's number
mcp_send:
    PROLOGUE
    mov r12, rdi
    mov rbx, rsi
    lea rax, [rip + mcp_subtypes]
    mov rsi, [rax + r12*8 - 8]
    mov rdi, rbx
    call claude_dlg2_begin
    mov r13, rax
    cmp r12, MR_LIST
    je 9f
    call claude_dlg2_cw         # {"serverName": NAME[, "enabled": B][, "callbackUrl": U]}
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .Lk_serverName]
    call jw_key
    mov rdi, r14
    mov rsi, [rip + m_name]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lempty]
1:  call jw_cstr
    cmp r12, MR_DISABLE
    je 2f
    cmp r12, MR_ENABLE
    jne 3f
2:  mov rdi, r14
    lea rsi, [rip + .Lk_enabled]
    call jw_key
    xor esi, esi
    cmp r12, MR_ENABLE
    sete sil
    mov rdi, r14
    call jw_bool
    jmp 9f
3:  cmp r12, MR_CALLBACK
    jne 9f
    mov rdi, r14
    lea rsi, [rip + .Lk_callbackUrl]
    call jw_key
    lea rdi, [rip + m_tf_cb]
    call c2_tf_text
    mov rdi, r14
    mov rsi, rax
    call jw_str
9:  mov rax, r13
    EPILOGUE

# mcp_answer(rq, envelope)
mcp_answer:
    PROLOGUE
    mov r12, rdi
    mov rbx, rsi
    cmp r12, MR_LIST
    jne 5f
    mov rdi, rbx                # the list: kept without anything secret
    call c2_ok
    test eax, eax
    jnz 1f
    call f_clr                  # "Failed to load servers: ERR" and Retry
    lea rdi, [rip + .Lm_failed]
    call f_c
    mov rdi, rbx
    call c2_why
    mov rdi, rax
    mov rsi, rdx
    mov edx, CLEAN_MAX
    call f_cl
    call agentdlg_begin
    mov edi, DGF_ERROR
    call c2_ftext
    lea rdi, [rip + .Lm_retry]
    mov esi, MA_RETRY
    mov edx, DBF_PRIMARY
    call agentdlg_button
    EPILOGUE
1:  mov rdi, rbx
    call c2_resp
    mov rdi, rax
    call mcp_keep
    call mcp_authdone
    call mcp_build
    EPILOGUE
5:  cmp r12, MR_AUTH            # mcp_authenticate: its page opens (asked first), the wait shows
    jne 6f
    mov rdi, rbx
    call c2_ok
    test eax, eax
    jz 7f
    mov rdi, rbx
    call c2_resp
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_error]
    call c2_jstr
    test rdx, rdx
    jz 51f
    mov rdi, rax
    mov rsi, rdx
    call c2_err_set
    jmp 8f
51: mov rdi, r13
    lea rsi, [rip + .Lk_authUrl]
    call c2_jstr
    test rdx, rdx
    jz 52f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rdi, [rip + m_authurl]
    mov [rip + m_authurl], rax
    call mem_free
52: mov rdi, r13
    lea rsi, [rip + .Lk_localhost]
    call c2_jbool
    mov [rip + m_localhost], eax
    mov rdi, r13
    lea rsi, [rip + .Lk_requiresUserAction]
    call c2_jbool
    mov r14d, eax
    mov rsi, [rip + m_authurl]  # the page: in the user's browser, once they say so
    test rsi, rsi
    jz 53f
    lea rdi, [rip + .Lwho]
    call links_ask_open
53: test r14d, r14d
    jz 54f
    mov dword ptr [rip + m_authwait], 1
    jmp 8f
54: call f_clr
    lea rdi, [rip + .Lm_authed]
    call f_c
    call c2_msg_fsb
    jmp 8f
6:  mov rdi, rbx                # a change: its notice, or its error; then the list again
    call c2_ok
    test eax, eax
    jz 7f
    call f_clr
    lea rax, [rip + mcp_done]
    mov rdi, [rax + r12*8 - 8]
    call f_c
    mov rdi, [rip + m_name]
    mov rsi, NAME_MAX
    call mcp_name_f
    call c2_msg_fsb
    cmp r12, MR_DISABLE         # disabled: back to the list
    jne 8f
    mov qword ptr [rip + c2_page], MP_LIST
    jmp 8f
7:  mov rdi, rbx
    call c2_why
    test rdx, rdx
    jnz 71f
    lea rax, [rip + mcp_fails]
    mov rdi, [rax + r12*8 - 8]
    call c2_err_cset
    jmp 8f
71: mov rdi, rax
    mov rsi, rdx
    call c2_err_set
8:  mov qword ptr [rip + c2_busy], MA_RETRY
    call mcp_build              # (busy: its buttons say so until the list comes)
    mov edi, MR_LIST
    call c2_ask
    EPILOGUE

# mcp_tick(): while authentication goes on in the browser, the list is read again every 2 s (the extension's)
mcp_tick:
    PROLOGUE
    cmp dword ptr [rip + m_authwait], 0
    je 9f
    cmp qword ptr [rip + c2_busy], 0
    jne 9f
    mov edi, MR_LIST
    call c2_ask
9:  EPILOGUE

# mcp_authdone(): authenticating, the list read again: connected ends the wait; else read again in 2 s
mcp_authdone:
    PROLOGUE
    cmp dword ptr [rip + m_authwait], 0
    je 9f
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    mov rdi, rax
    mov rsi, [rip + m_name]
    call mcp_find
    cmp rax, -1
    je 8f
    mov rdi, rbx
    mov esi, eax
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lv_connected]
    call is_status
    test eax, eax
    jnz 8f
    mov edi, 2000
    call c2_later
    EPILOGUE
8:  mov dword ptr [rip + m_authwait], 0
9:  EPILOGUE

# mcp_name_f(cstr or 0, max): fsb += the name, cleaned
mcp_name_f:
    test rdi, rdi
    jz 1f
    push rsi
    push rdi
    call strlen
    mov rsi, rax
    pop rdi
    pop rdx
    jmp f_cl
1:  ret

# mcp_keep(response): c2_doc = [{name, status, scope, error, type, tools: [{name, ro, de}]}] of the servers
#   with a config (the extension's filter), "claude-vscode" left out; nothing of their config but its type
mcp_keep:
    PROLOGUE
    lea rsi, [rip + .Lk_mcpServers]
    call json_get
    mov rbx, rax
    lea rdi, [rip + c2_doc]
    call jw_begin
    lea rdi, [rip + c2_doc]
    call jw_arr
    xor r12d, r12d
1:  mov rdi, rbx
    call json_len
    cmp r12d, eax
    jae 8f
    mov rdi, rbx
    mov esi, r12d
    call json_at
    inc r12d
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lk_config]
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne 1b
    mov rdi, r13
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    test rdx, rdx
    jz 1b
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_vscode]
    call str_eq_cstr
    test eax, eax
    jnz 1b
    lea rdi, [rip + c2_doc]
    call jw_obj
    lea r15, [rip + mcp_kept]   # the string members as they are
2:  mov rsi, [r15]
    test rsi, rsi
    jz 3f
    mov rdi, r13
    call c2_jstr
    test rdx, rdx
    jz 21f
    push rdx
    push rax
    lea rdi, [rip + c2_doc]
    mov rsi, [r15]
    call jw_key
    pop rsi
    pop rdx
    lea rdi, [rip + c2_doc]
    call jw_str
21: add r15, 8
    jmp 2b
3:  mov rdi, r14                # the config's type
    lea rsi, [rip + .Lk_type]
    call c2_jstr
    test rdx, rdx
    jz 4f
    push rdx
    push rax
    lea rdi, [rip + c2_doc]
    lea rsi, [rip + .Lk_type]
    call jw_key
    pop rsi
    pop rdx
    lea rdi, [rip + c2_doc]
    call jw_str
4:  mov rdi, r13                # the tools: their names and two annotations
    lea rsi, [rip + .Lk_tools]
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne 7f
    lea rdi, [rip + c2_doc]
    lea rsi, [rip + .Lk_tools]
    call jw_key
    lea rdi, [rip + c2_doc]
    call jw_arr
    xor r15d, r15d
5:  mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 6f
    mov rdi, r14
    mov esi, r15d
    call json_at
    inc r15d
    mov [rsp], rax
    lea rdi, [rip + c2_doc]
    call jw_obj
    mov rdi, [rsp]
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    push rdx
    push rax
    lea rdi, [rip + c2_doc]
    lea rsi, [rip + .Lk_name]
    call jw_key
    pop rsi
    pop rdx
    lea rdi, [rip + c2_doc]
    call jw_str
    mov rdi, [rsp]
    lea rsi, [rip + .Lk_annotations]
    call json_get
    mov [rsp], rax
    mov rdi, rax
    lea rsi, [rip + .Lk_readOnly]
    call c2_jbool
    test eax, eax
    jz 51f
    lea rdi, [rip + c2_doc]
    lea rsi, [rip + .Lk_ro]
    call jw_key
    lea rdi, [rip + c2_doc]
    mov esi, 1
    call jw_bool
51: mov rdi, [rsp]
    lea rsi, [rip + .Lk_destructive]
    call c2_jbool
    test eax, eax
    jz 52f
    lea rdi, [rip + c2_doc]
    lea rsi, [rip + .Lk_de]
    call jw_key
    lea rdi, [rip + c2_doc]
    mov esi, 1
    call jw_bool
52: lea rdi, [rip + c2_doc]
    call jw_end_obj
    jmp 5b
6:  lea rdi, [rip + c2_doc]
    call jw_end_arr
7:  lea rdi, [rip + c2_doc]
    call jw_end_obj
    jmp 1b
8:  lea rdi, [rip + c2_doc]
    call jw_end_arr
    EPILOGUE

# meq(a, b, len) -> eax 1 when the bytes are the same
meq:
    xor ecx, ecx
1:  cmp rcx, rdx
    jae 2f
    movzx eax, byte ptr [rdi + rcx]
    cmp al, [rsi + rcx]
    jne 3f
    inc rcx
    jmp 1b
2:  mov eax, 1
    ret
3:  xor eax, eax
    ret

# mcp_find(root, name cstr) -> rax the server's index, -1 none
mcp_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
    mov rax, -1
    test r12, r12
    jz 9f
1:  mov rdi, rbx
    call json_len
    cmp r13d, eax
    jae 8f
    mov rdi, rbx
    mov esi, r13d
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    call str_eq_cstr
    test eax, eax
    jnz 7f
    inc r13d
    jmp 1b
7:  mov eax, r13d
    EPILOGUE
8:  mov rax, -1
9:  EPILOGUE

# mcp_build(): the page shown, from c2_doc
mcp_build:
    PROLOGUE
    call agentdlg_begin
    mov rax, [rip + c2_page]
    cmp rax, MP_ADD
    je .Lmb_add
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    cmp qword ptr [rip + c2_page], MP_DETAIL
    jne .Lmb_list
    mov rdi, rbx                # the detail page's server, found again by its name
    mov rsi, [rip + m_name]
    call mcp_find
    cmp rax, -1
    je 1f
    mov rdi, rbx
    mov esi, eax
    call json_at
    mov rdi, rax
    call mcp_detail
    EPILOGUE
1:  mov qword ptr [rip + c2_page], MP_LIST
    xor edi, edi
    call agentdlg_back
.Lmb_list:
    xor edi, edi
    call agentdlg_back
    call c2_msgs
    mov rdi, rbx
    call json_len
    test eax, eax
    jnz 2f
    lea rdi, [rip + .Lm_none]   # "No MCP servers configured." and Add server
    xor esi, esi
    call c2_text
    jmp 6f
2:  lea rdi, [rip + .Lm_filter]
    call agentdlg_filter
    lea r12, [rip + scope_order]    # the groups in the extension's order, then the others
    xor r13d, r13d
3:  cmp r13d, SCOPES_N
    jae 4f
    mov rdi, rbx
    mov rsi, [r12 + r13*8]
    xor edx, edx
    call mcp_group
    inc r13d
    jmp 3b
4:  mov rdi, rbx                # the other scopes, each once, in the order they come
    xor esi, esi
    mov edx, 1
    call mcp_group
6:  lea rdi, [rip + .Lm_learn]
    mov esi, MA_LEARN
    call c2_link
    lea rdi, [rip + .Lm_add]
    mov esi, MA_ADDFORM
    mov edx, DBF_PRIMARY
    call agentdlg_button
    EPILOGUE
.Lmb_add:
    call mcp_add_rows
    EPILOGUE

# mcp_group(root, scope cstr or 0, others): the servers of that scope (sorted by name: the order the CLI
#   gives is kept, as both sort), its heading "Label (N)"; others: every server whose scope is none of
#   scope_order's, a group per scope in the order they first come
mcp_group:
    PROLOGUE 48                 # ([rsp + 32]: a row's server index)
    mov rbx, rdi
    mov r12, rsi
    mov [rsp + 40], edx
    test edx, edx
    jz 5f
    xor r14d, r14d              # others: a group for each new scope
1:  mov rdi, rbx
    call json_len
    cmp r14d, eax
    jae 9f
    mov rdi, rbx
    mov esi, r14d
    call json_at
    inc r14d
    mov rdi, rax
    lea rsi, [rip + .Lk_scope]
    call c2_jstr
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rax
    mov rsi, rdx
    call known_scope
    test eax, eax
    jnz 1b
    xor r15d, r15d              # seen before?
2:  lea eax, [r14 - 1]
    cmp r15d, eax
    jae 3f
    mov rdi, rbx
    mov esi, r15d
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_scope]
    call c2_jstr
    inc r15d
    cmp rdx, [rsp + 8]
    jne 2b
    mov rdi, rax
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call meq
    test eax, eax
    jz 2b
    jmp 1b
3:  mov rdi, [rsp]              # a new one
    mov rsi, [rsp + 8]
    call mem_dup
    mov [rsp + 16], rax
    mov rdi, rbx
    mov rsi, rax
    xor edx, edx
    call mcp_group
    mov rdi, [rsp + 16]
    call mem_free
    jmp 1b
5:  xor r13d, r13d              # count
    xor r14d, r14d
51: mov rdi, rbx
    call json_len
    cmp r14d, eax
    jae 52f
    mov rdi, rbx
    mov esi, r14d
    call json_at
    inc r14d
    mov rdi, rax
    mov rsi, r12
    call has_scope
    add r13d, eax
    jmp 51b
52: test r13d, r13d
    jz 9f
    call f_clr                  # the heading
    mov rdi, r12
    call scope_label
    mov rdi, rax
    call f_c
    lea rdi, [rip + .Lopen_paren]
    call f_c
    mov edi, r13d
    call f_u
    lea rdi, [rip + .Lclose_paren]
    call f_c
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call c2_frow
    mov rdi, rbx                # the rows, by name (the extension sorts each scope's)
    mov rsi, r12
    call scope_sorted
    xor r14d, r14d
6:  cmp r14, [rip + sidx_n]
    jae 9f
    lea rax, [rip + sidx]
    mov esi, [rax + r14*4]
    inc r14d
    mov [rsp + 32], esi
    mov rdi, rbx
    call json_at
    mov r15, rax
    mov edi, DGK_ITEM
    mov esi, DGF_FILTER
    mov edx, MA_SERVER
    call agentdlg_row
    mov r13, rax
    mov eax, [rsp + 32]
    mov [r13 + DGR_arg], rax
    mov rdi, r15
    lea rsi, [rip + .Lk_name]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, r13
    xor esi, esi
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    mov rdi, r15
    call status_f
    mov rdi, r13
    mov esi, 2
    call c2_fset
    jmp 6b
9:  EPILOGUE

# scope_sorted(root, scope cstr): sidx = the indexes of that scope's servers by name (ASCII case ignored, as
#   localeCompare mostly is), SIDX_MAX at most
scope_sorted:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov qword ptr [rip + sidx_n], 0
    xor r13d, r13d
1:  mov rdi, rbx
    call json_len
    cmp r13d, eax
    jae 9f
    cmp qword ptr [rip + sidx_n], SIDX_MAX
    jae 9f
    mov rdi, rbx
    mov esi, r13d
    call json_at
    mov r14, rax
    inc r13d
    mov rdi, rax
    mov rsi, r12
    call has_scope
    test eax, eax
    jz 1b
    mov rdi, r14                # its name
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov r15, [rip + sidx_n]     # into place among those before
2:  test r15, r15
    jz 3f
    lea rax, [rip + sidx]
    mov esi, [rax + r15*4 - 4]
    mov rdi, rbx
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    mov rdi, rax                # before's name > this one's: it moves on
    mov rsi, rdx
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    call ci_cmp
    test eax, eax
    jle 3f
    lea rax, [rip + sidx]
    mov ecx, [rax + r15*4 - 4]
    mov [rax + r15*4], ecx
    dec r15
    jmp 2b
3:  lea rax, [rip + sidx]
    lea ecx, [r13 - 1]
    mov [rax + r15*4], ecx
    inc qword ptr [rip + sidx_n]
    jmp 1b
9:  EPILOGUE

# ci_cmp(a, alen, b, blen) -> eax <0, 0, >0 (ASCII case ignored)
ci_cmp:
    xor r8d, r8d
1:  cmp r8, rsi
    jae 3f
    cmp r8, rcx
    jae 4f
    movzx eax, byte ptr [rdi + r8]
    movzx r9d, byte ptr [rdx + r8]
    lea r10d, [rax - 'A']
    cmp r10d, 25
    ja 11f
    or eax, 0x20
11: lea r10d, [r9 - 'A']
    cmp r10d, 25
    ja 12f
    or r9d, 0x20
12: sub eax, r9d
    jnz 9f
    inc r8
    jmp 1b
3:  xor eax, eax
    cmp r8, rcx
    je 9f
    mov eax, -1
    ret
4:  mov eax, 1
9:  ret

# known_scope(ptr, len) -> eax 1 for one of scope_order's
known_scope:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13d, SCOPES_N
    jae 8f
    lea rax, [rip + scope_order]
    mov rdx, [rax + r13*8]
    inc r13d
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jz 1b
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# has_scope(server, scope cstr) -> eax 1 when its scope is that one
has_scope:
    push rbx
    mov rbx, rsi
    lea rsi, [rip + .Lk_scope]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, rbx
    call str_eq_cstr
    pop rbx
    ret

# scope_label(cstr) -> rax its words (UMn): Project, Local, User, claude.ai, Managed, Enterprise, else itself
scope_label:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12d, SCOPES_N
    jae 8f
    lea rax, [rip + scope_order]
    mov rsi, [rax + r12*8]
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jnz 2f
    inc r12d
    jmp 1b
2:  lea rax, [rip + scope_labels]
    mov rax, [rax + r12*8]
    EPILOGUE
8:  mov rax, rbx
    EPILOGUE

# status_f(server): fsb = its badge: "✓ Connected", "✗ Failed", "⚠ Needs Auth", "◐ Connecting…", "○ Disabled",
#   else "? STATUS"
status_f:
    PROLOGUE
    lea rsi, [rip + .Lk_status]
    call c2_jstr
    mov rbx, rax
    mov r12, rdx
    call f_clr
    lea r13, [rip + status_tbl]
1:  mov rdx, [r13]
    test rdx, rdx
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add r13, 16
    jmp 1b
2:  mov rdi, [r13 + 8]
    call f_c
    EPILOGUE
8:  lea rdi, [rip + .Lq_status]
    call f_c
    mov rdi, rbx
    mov rsi, r12
    mov edx, NAME_MAX
    call f_cl
    EPILOGUE

# is_status(server, cstr) -> eax 1 when its status is that one
is_status:
    push rbx
    mov rbx, rsi
    lea rsi, [rip + .Lk_status]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, rbx
    call str_eq_cstr
    pop rbx
    ret

# is_type(server, cstr) -> eax 1 when its config's type is that one
is_type:
    push rbx
    mov rbx, rsi
    lea rsi, [rip + .Lk_type]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, rbx
    call str_eq_cstr
    pop rbx
    ret

# remote(server) -> eax 1 for sse, http and claudeai-proxy (xRe)
remote:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lv_sse]
    call is_type
    test eax, eax
    jnz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lv_http]
    call is_type
    test eax, eax
    jnz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lv_proxy]
    call is_type
9:  EPILOGUE

# mcp_detail(server): its page (6.2)
mcp_detail:
    PROLOGUE 16
    mov rbx, rdi
    mov edi, MA_BACK
    call agentdlg_back
    call c2_msgs
    cmp qword ptr [rip + c2_err + SB_len], 0
    jne 1f
    mov rdi, rbx                # its error (jMn: tags out, the first line, 200 at most)
    lea rsi, [rip + .Lk_error]
    call c2_jstr
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call error_f
    mov edi, DGF_ERROR
    call c2_ftext
1:  mov rdi, rbx                # its name and its badge
    call status_f
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov r12, rax
    mov rdi, rax
    mov esi, 2
    call c2_fset
    mov rdi, rbx
    lea rsi, [rip + .Lk_name]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, r12
    xor esi, esi
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    mov rdi, rbx
    lea rsi, [rip + .Lv_connected]
    call is_status
    mov r13d, eax               # connected
    cmp dword ptr [rip + m_authwait], 0  # authentication in the browser
    je 3f
    test r13d, r13d
    jnz 3f
    lea rdi, [rip + .Lm_completing]
    mov esi, DGF_MUTED
    call c2_text
    cmp dword ptr [rip + m_localhost], 0
    je 2f
    lea rdx, [rip + .Lm_paste_ph]
    lea rcx, [rip + .Lm_paste]
    mov edi, DGK_FIELD
    xor esi, esi
    mov r8, rdx
    mov rcx, rcx
    mov edx, MA_CALLBACK
    xor r9d, r9d
    call c2_crow
    lea rcx, [rip + m_tf_cb]
    mov [rax + DGR_val], rcx
    lea rdi, [rip + .Lm_submit]
    mov esi, MA_CALLBACK
    xor edx, edx
    call agentdlg_button
2:  cmp qword ptr [rip + m_authurl], 0
    je 3f
    lea rdi, [rip + .Lm_reopen]
    mov esi, MA_REOPEN
    call c2_link
3:  test r13d, r13d             # the tools
    jz 5f
    mov rdi, rbx
    lea rsi, [rip + .Lk_tools]
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_len
    test eax, eax
    jz 5f
    mov r15d, eax
    call f_clr
    cmp dword ptr [rip + m_tools], 0
    jne 31f
    lea rdi, [rip + .Lm_viewtools]
    call f_c
    mov edi, r15d
    call f_u
    lea rdi, [rip + .Lm_viewtools2]
    call f_c
    jmp 32f
31: lea rdi, [rip + .Lm_hidetools]
    call f_c
32: mov edi, DGK_LINK
    xor esi, esi
    mov edx, MA_TOOLS
    call c2_frow
    cmp dword ptr [rip + m_tools], 0
    je 5f
    xor r15d, r15d
4:  mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 5f
    mov rdi, r14
    mov esi, r15d
    call json_at
    inc r15d
    mov [rsp], rax
    mov edi, DGK_ITEM
    mov esi, DGF_FILTER
    xor edx, edx
    call agentdlg_row
    mov r12, rax
    mov rdi, [rsp]
    lea rsi, [rip + .Lk_name]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, r12
    xor esi, esi
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    call f_clr
    mov rdi, [rsp]
    lea rsi, [rip + .Lk_ro]
    call c2_jbool
    test eax, eax
    jz 41f
    lea rdi, [rip + .Lm_ro]
    call f_c
41: mov rdi, [rsp]
    lea rsi, [rip + .Lk_de]
    call c2_jbool
    test eax, eax
    jz 42f
    cmp qword ptr [rip + fsb + SB_len], 0
    je 43f
    lea rdi, [rip + .Lspace]
    call f_c
43: lea rdi, [rip + .Lm_de]
    call f_c
42: cmp qword ptr [rip + fsb + SB_len], 0
    je 4b
    mov rdi, r12
    mov esi, 2
    call c2_fset
    jmp 4b
5:  cmp dword ptr [rip + m_confirm], 0  # Remove asked: its question and Confirm remove, Cancel
    je 6f
    call f_clr
    lea rdi, [rip + .Lm_remove_q]
    call f_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_name]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    lea rdi, [rip + .Lfrom]
    call f_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_scope]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    lea rdi, [rip + .Lm_config_q]
    call f_c
    xor edi, edi
    call c2_ftext
    lea rdi, [rip + .Lm_confirm]
    cmp qword ptr [rip + c2_busy], MA_CONFIRM
    jne 51f
    lea rdi, [rip + .Lm_removing]
51: mov esi, MA_CONFIRM
    mov edx, DBF_PRIMARY
    call agentdlg_button
    lea rdi, [rip + .Lm_cancel]
    mov esi, MA_CANCEL
    xor edx, edx
    call agentdlg_button
    jmp 8f
6:  test r13d, r13d             # the buttons by state
    jz 61f
    mov edi, MA_RECONNECT       # connected: Reconnect, Clear authentication (remote, not a proxy), Disable
    call act_btn
    mov rdi, rbx
    call remote
    test eax, eax
    jz 60f
    mov rdi, rbx
    lea rsi, [rip + .Lv_proxy]
    call is_type
    test eax, eax
    jnz 60f
    mov edi, MA_CLEARAUTH
    call act_btn
60: mov edi, MA_DISABLE
    call act_btn
    jmp 7f
61: mov rdi, rbx
    lea rsi, [rip + .Lv_needsauth]
    call is_status
    test eax, eax
    jz 63f
    cmp dword ptr [rip + m_authwait], 0  # needs auth: Authenticate (remote), Check connection (a proxy),
    jne 62f                              #   Disable; while waiting: Check connection
    mov rdi, rbx
    call remote
    test eax, eax
    jz 611f
    mov edi, MA_AUTH
    call act_btn
611:mov rdi, rbx
    lea rsi, [rip + .Lv_proxy]
    call is_type
    test eax, eax
    jz 612f
    mov edi, MA_CHECK
    call act_btn
612:mov edi, MA_DISABLE
    call act_btn
    jmp 7f
62: mov edi, MA_CHECK
    call act_btn
    jmp 7f
63: mov rdi, rbx
    lea rsi, [rip + .Lv_failed]
    call is_status
    test eax, eax
    jz 64f
    cmp dword ptr [rip + m_authwait], 0
    jne 62b
    mov rdi, rbx                # failed: Authenticate (remote), Reconnect, Disable
    call remote
    test eax, eax
    jz 631f
    mov edi, MA_AUTH
    call act_btn
631:mov edi, MA_RECONNECT
    call act_btn
    mov edi, MA_DISABLE
    call act_btn
    jmp 7f
64: mov rdi, rbx
    lea rsi, [rip + .Lv_disabled]
    call is_status
    test eax, eax
    jz 7f
    mov edi, MA_ENABLE          # disabled: Enable
    call act_btn
7:  mov rdi, rbx                # Remove, for the scopes `claude mcp remove` takes
    call removable
    test eax, eax
    jz 8f
    mov edi, MA_REMOVE
    call act_btn
8:  lea rdi, [rip + .Lm_learn]
    mov esi, MA_LEARN
    call c2_link
    EPILOGUE

# removable(server) -> eax 1 when its scope is local, user or project (dMn)
removable:
    PROLOGUE
    mov rbx, rdi
    lea r12, [rip + rm_scopes]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call has_scope
    test eax, eax
    jnz 9f
    add r12, 8
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# act_btn(act): its button, in its busy words while it runs (the Add server and Remove ones primary)
act_btn:
    PROLOGUE
    mov ebx, edi
    lea rax, [rip + btn_words]
    mov rdi, [rax + rbx*8]
    cmp rbx, [rip + c2_busy]
    jne 1f
    lea rax, [rip + btn_busy]
    mov rdi, [rax + rbx*8]
1:  mov esi, ebx
    xor edx, edx
    cmp ebx, MA_AUTH
    jne 2f
    mov edx, DBF_PRIMARY
2:  cmp ebx, MA_ENABLE
    jne 3f
    mov edx, DBF_PRIMARY
3:  call agentdlg_button
    EPILOGUE

# error_f(ptr, len): fsb = a server's error as the detail page shows it (jMn): tags taken out, its first
#   line, 200 characters at most with "…"
error_f:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call f_clr
    xor r13d, r13d
    xor r14d, r14d              # inside a tag
1:  cmp r13, r12
    jae 5f
    movzx esi, byte ptr [rbx + r13]
    inc r13
    cmp esi, 10
    je 5f
    test r14d, r14d
    jz 2f
    cmp esi, '>'
    jne 1b
    xor r14d, r14d
    jmp 1b
2:  cmp esi, '<'
    jne 3f
    mov r14d, 1
    jmp 1b
3:  lea rdi, [rip + fsb]
    call sb_push_byte
    jmp 1b
5:  lea rdi, [rip + csb]        # cleaned and cut (fsb's bytes go through csb)
    call sb_clear
    mov rsi, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    lea rdi, [rip + c2_out]     # (a spare buffer: no run goes while a page is built)
    call sb_clear
    lea rdi, [rip + c2_out]
    mov rsi, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    call sb_push
    call f_clr
    mov rdi, [rip + c2_out + SB_ptr]
    mov rsi, [rip + c2_out + SB_len]
    mov edx, 200
    call f_cl
    lea rdi, [rip + c2_out]
    call sb_clear
    EPILOGUE

# mcp_add_rows(): the Add MCP server form (6.3)
mcp_add_rows:
    PROLOGUE
    mov edi, MA_BACK
    call agentdlg_back
    lea rdi, [rip + .Lm_add_title]
    call c2_head
    cmp qword ptr [rip + c2_err + SB_len], 0
    je 1f
    call c2_msgs
1:  mov edi, DGK_FIELD
    xor esi, esi
    xor edx, edx
    lea rcx, [rip + .Lm_f_name]
    lea r8, [rip + .Lm_f_name_ph]
    xor r9d, r9d
    call c2_crow
    lea rcx, [rip + m_tf_name]
    mov [rax + DGR_val], rcx
    lea rdi, [rip + .Lm_transport]
    call c2_head
    lea rdi, [rip + transports]
    mov esi, [rip + m_transport]
    mov edx, MA_TRANSPORT
    mov ecx, 3
    call options
    cmp dword ptr [rip + m_transport], 0
    jne 2f
    lea rcx, [rip + .Lm_f_cmd]
    lea r8, [rip + .Lm_f_cmd_ph]
    lea rax, [rip + m_tf_cmd]
    xor esi, esi
    call field
    lea rcx, [rip + .Lm_f_args]
    xor r8d, r8d
    lea rax, [rip + m_tf_args]
    mov esi, DGF_MULTI
    call field
    lea rcx, [rip + .Lm_f_env]
    xor r8d, r8d
    lea rax, [rip + m_tf_env]
    mov esi, DGF_MULTI | DGF_SECRETV
    call field
    jmp 3f
2:  lea rcx, [rip + .Lm_f_url]
    lea r8, [rip + .Lm_f_url_ph]
    lea rax, [rip + m_tf_url]
    xor esi, esi
    call field
    lea rcx, [rip + .Lm_f_hdr]
    xor r8d, r8d
    lea rax, [rip + m_tf_hdr]
    mov esi, DGF_MULTI | DGF_SECRETV
    call field
3:  lea rdi, [rip + .Lm_scope]
    call c2_head
    lea rdi, [rip + mcp_scopes]
    mov esi, [rip + m_scope]
    mov edx, MA_SCOPE
    mov ecx, 3
    call options
    cmp dword ptr [rip + m_scope], 2
    jne 4f
    lea rdi, [rip + .Lm_project_warn]
    mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
4:  lea rdi, [rip + .Lm_add_server]
    cmp qword ptr [rip + c2_busy], MA_SUBMIT
    jne 5f
    lea rdi, [rip + .Lm_adding]
5:  mov esi, MA_SUBMIT
    mov edx, DBF_PRIMARY
    call agentdlg_button
    EPILOGUE

# field(-, flags esi, -, label rcx, placeholder r8, TF* rax): a FIELD row (Enter moves on)
field:
    PROLOGUE
    mov rbx, rax
    mov edi, DGK_FIELD
    xor edx, edx
    xor r9d, r9d
    call c2_crow
    mov [rax + DGR_val], rbx
    EPILOGUE

# FN c2_options(table {label, description}*, chosen, act, n): an OPTION row each (arg: its index)
FN c2_options
options:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    xor r15d, r15d
1:  cmp r15d, r14d
    jae 9f
    xor esi, esi
    cmp r15d, r12d
    jne 2f
    mov esi, DGF_ON
2:  mov edi, DGK_OPTION
    mov edx, r13d
    mov rcx, [rbx]
    mov r8, [rbx + 8]
    xor r9d, r9d
    call c2_crow
    mov [rax + DGR_arg], r15
    add rbx, 16
    inc r15d
    jmp 1b
9:  EPILOGUE

# mcp_act(act, arg, DGR*)
mcp_act:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    cmp r12d, MA_LEARN          # these go whatever runs
    je .Lma_learn
    cmp r12d, MA_REOPEN
    je .Lma_reopen
    cmp r12d, MA_TOOLS
    je .Lma_tools
    cmp qword ptr [rip + c2_busy], 0
    jne 9f                      # one thing at a time
    cmp r12d, MA_TRANSPORT
    je .Lma_transport
    cmp r12d, MA_SCOPE
    je .Lma_scope
    cmp r12d, MA_RETRY
    je .Lma_retry
    cmp r12d, MA_SERVER
    je .Lma_server
    cmp r12d, MA_BACK
    je .Lma_back
    cmp r12d, MA_ADDFORM
    je .Lma_addform
    cmp r12d, MA_SUBMIT
    je .Lma_submit
    cmp r12d, MA_REMOVE
    je .Lma_remove
    cmp r12d, MA_CANCEL
    je .Lma_cancel
    cmp r12d, MA_CONFIRM
    je .Lma_confirm
    cmp r12d, MA_CALLBACK
    je .Lma_callback
    mov edi, MR_RECONNECT       # the requests about the server shown
    cmp r12d, MA_RECONNECT
    je 1f
    cmp r12d, MA_CHECK
    je 2f
    mov edi, MR_DISABLE
    cmp r12d, MA_DISABLE
    je 1f
    mov edi, MR_ENABLE
    cmp r12d, MA_ENABLE
    je 1f
    mov edi, MR_CLEARAUTH
    cmp r12d, MA_CLEARAUTH
    je 1f
    mov edi, MR_AUTH
    cmp r12d, MA_AUTH
    jne 9f
1:  mov [rip + c2_busy], r12
    push rdi
    push rdi
    call c2_notes_clear
    call mcp_build
    pop rdi
    pop rdi
    call c2_ask
    jmp 9f
2:  mov dword ptr [rip + m_authwait], 0   # Check connection: a reconnect, the wait over
    mov edi, MR_RECONNECT
    jmp 1b
.Lma_learn:
    lea rdi, [rip + .Lwho]
    lea rsi, [rip + .Lm_url]
    call links_ask_open
    jmp 9f
.Lma_reopen:
    mov rsi, [rip + m_authurl]
    test rsi, rsi
    jz 9f
    lea rdi, [rip + .Lwho]
    call links_ask_open
    jmp 9f
.Lma_tools:
    xor dword ptr [rip + m_tools], 1
    jmp 8f
.Lma_transport:
    mov [rip + m_transport], r13d
    jmp 8f
.Lma_scope:
    mov [rip + m_scope], r13d
    jmp 8f
.Lma_retry:
    call c2_notes_clear
    lea rdi, [rip + .Lm_retrying]
    call agentdlg_loading
    mov edi, MR_LIST
    call c2_ask
    jmp 9f
.Lma_server:
    lea rdi, [rip + c2_doc]     # its name kept: the list may change under the page
    call c2_parse
    mov rdi, rax
    mov esi, r13d
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rdi, [rip + m_name]
    mov [rip + m_name], rax
    call mem_free
    call c2_notes_clear
    mov dword ptr [rip + m_confirm], 0
    mov dword ptr [rip + m_tools], 0
    mov qword ptr [rip + c2_page], MP_DETAIL
    xor edi, edi                # the focus on the first thing of the page
    call agentdlg_focus
    jmp 8f
.Lma_back:
    call c2_notes_clear
    mov dword ptr [rip + m_authwait], 0
    mov qword ptr [rip + c2_page], MP_LIST
    jmp 8f
.Lma_addform:
    call c2_notes_clear
    mov qword ptr [rip + c2_page], MP_ADD
    mov dword ptr [rip + m_transport], 0
    mov dword ptr [rip + m_scope], 0
    lea rdi, [rip + m_tf_name]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_cmd]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_args]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_env]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_url]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_hdr]
    call c2_wipe_tf
    mov edi, 0
    call agentdlg_focus
    jmp 8f
.Lma_remove:
    mov dword ptr [rip + m_confirm], 1
    call c2_notes_clear
    call mcp_build
    mov edi, 1000               # the focus on Cancel (the last: the shell keeps it in range): Enter
    call agentdlg_focus         #   twice removes nothing by mistake
    jmp 9f
.Lma_cancel:
    mov dword ptr [rip + m_confirm], 0
    jmp 8f
.Lma_confirm:
    call mcp_remove
    jmp 8f
.Lma_submit:
    call mcp_submit
    jmp 8f
.Lma_callback:
    lea rdi, [rip + m_tf_cb]
    call c2_tf_text
    test rdx, rdx
    jz 9f
    mov dword ptr [rip + m_authwait], 0
    mov qword ptr [rip + c2_busy], MA_CHECK
    call mcp_build
    mov edi, MR_CALLBACK
    call c2_ask
    jmp 9f
8:  call mcp_build
9:  EPILOGUE

# mcp_remove(): `claude mcp remove --scope SCOPE -- NAME` for the server shown
mcp_remove:
    PROLOGUE
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    mov rdi, rax
    mov rsi, [rip + m_name]
    call mcp_find
    cmp rax, -1
    je 9f
    mov rdi, rbx
    mov esi, eax
    call json_at
    mov rbx, rax
    mov rdi, rax
    call removable
    test eax, eax
    jz 9f
    call c2_args
    lea rdi, [rip + .La_mcp]
    call c2_arg_c
    lea rdi, [rip + .La_remove]
    call c2_arg_c
    lea rdi, [rip + .La_scope]
    call c2_arg_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_scope]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call c2_arg_n
    lea rdi, [rip + .La_dashes]
    call c2_arg_c
    mov rdi, [rip + m_name]
    call c2_arg_c
    lea rdi, [rip + c2_in]
    call sb_clear
    call c2_notes_clear
    mov edi, MW_REMOVE
    call c2_run
    test eax, eax
    jz 8f
    mov qword ptr [rip + c2_busy], MA_CONFIRM
    EPILOGUE
8:  lea rdi, [rip + .Lno_run]
    call c2_err_cset
9:  EPILOGUE

# mcp_submit(): the form checked as the extension checks it (UMt, VMt, Ile), then `claude mcp add --scope S
#   --transport T [--env K=V]... -- NAME COMMAND ARGS...` or `[--header H]... -- NAME URL`
mcp_submit:
    PROLOGUE 32
    call c2_notes_clear
    lea rdi, [rip + m_tf_name]
    call c2_tf_text
    mov rbx, rax
    mov r12, rdx
    test r12, r12
    jnz 1f
    lea rdi, [rip + .Lm_e_name]
    call c2_err_cset
    jmp 9f
1:  xor ecx, ecx                # letters, digits, - and _ only
2:  cmp rcx, r12
    jae 4f
    movzx eax, byte ptr [rbx + rcx]
    inc rcx
    cmp eax, '-'
    je 2b
    cmp eax, '_'
    je 2b
    lea edx, [rax - '0']
    cmp edx, 9
    jbe 2b
    or eax, 0x20
    lea edx, [rax - 'a']
    cmp edx, 25
    jbe 2b
    call f_clr                  # "Invalid name NAME. Names can only contain ..."
    lea rdi, [rip + .Lm_e_invalid]
    call f_c
    mov rdi, rbx
    mov rsi, r12
    mov edx, NAME_MAX
    call f_cl
    lea rdi, [rip + .Lm_e_invalid2]
    call f_c
    call c2_err_fsb
    jmp 9f
4:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lv_vscode]
    call str_eq_cstr
    test eax, eax
    jz 5f
    lea rdi, [rip + .Lm_e_reserved]
    call c2_err_cset
    jmp 9f
5:  call c2_args                # mcp add --scope S --transport T
    lea rdi, [rip + .La_mcp]
    call c2_arg_c
    lea rdi, [rip + .La_add]
    call c2_arg_c
    lea rdi, [rip + .La_scope]
    call c2_arg_c
    mov eax, [rip + m_scope]
    lea rcx, [rip + mcp_scope_ids]
    mov rdi, [rcx + rax*8]
    call c2_arg_c
    lea rdi, [rip + .La_transport]
    call c2_arg_c
    mov eax, [rip + m_transport]
    lea rcx, [rip + transport_ids]
    mov rdi, [rcx + rax*8]
    call c2_arg_c
    cmp dword ptr [rip + m_transport], 0
    jne 20f
    lea rdi, [rip + m_tf_cmd]   # stdio: the command, its environment, its arguments
    call c2_tf_text
    test rdx, rdx
    jnz 11f
    lea rdi, [rip + .Lm_e_command]
    call c2_err_cset
    jmp 8f
11: lea rdi, [rip + m_tf_env]
    mov esi, '='
    lea rdx, [rip + .La_env]
    call kv_lines
    test eax, eax
    jz 8f
    lea rdi, [rip + .La_dashes]
    call c2_arg_c
    mov rdi, rbx
    mov rsi, r12
    call c2_arg_n
    lea rdi, [rip + m_tf_cmd]
    call c2_tf_text
    mov rdi, rax
    mov rsi, rdx
    call c2_arg_n
    lea rdi, [rip + m_tf_args]  # one an argument a line, trimmed, the empty ones left out
    call tf_text
    mov [rsp], rax
    mov [rsp + 8], rdx
    xor r13d, r13d
12: mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov edx, r13d
    call c2_line
    test r8d, r8d
    jz 30f
    inc r13d
    mov rdi, rax
    mov rsi, rdx
    call c2_trim
    test rdx, rdx
    jz 12b
    mov rdi, rax
    mov rsi, rdx
    call c2_arg_n
    jmp 12b
20: lea rdi, [rip + m_tf_url]   # http, sse: the URL, its headers
    call c2_tf_text
    test rdx, rdx
    jnz 21f
    lea rdi, [rip + .Lm_e_url]
    call c2_err_cset
    jmp 8f
21: lea rdi, [rip + m_tf_hdr]
    mov esi, ':'
    lea rdx, [rip + .La_header]
    call kv_lines
    test eax, eax
    jz 8f
    lea rdi, [rip + .La_dashes]
    call c2_arg_c
    mov rdi, rbx
    mov rsi, r12
    call c2_arg_n
    lea rdi, [rip + m_tf_url]
    call c2_tf_text
    mov rdi, rax
    mov rsi, rdx
    call c2_arg_n
30: lea rdi, [rip + c2_in]
    call sb_clear
    mov edi, MW_ADD
    call c2_run
    test eax, eax
    jz 31f
    mov qword ptr [rip + c2_busy], MA_SUBMIT
    jmp 9f
31: lea rdi, [rip + .Lno_run]
    call c2_err_cset
8:  call c2_args                # (the values typed are not kept in the arguments)
9:  EPILOGUE

# kv_lines(TF*, sep, flag cstr) -> eax 1 when every line that is not blank is NAME<sep>value (a name before
#   the separator; for = the name and the value trimmed, as VMt; for : the line trimmed, as Ile): each goes
#   as `flag LINE`; else 0 with the error "... (line N)."
kv_lines:
    PROLOGUE 32
    mov [rsp + 16], esi
    mov [rsp + 24], rdx
    call tf_text
    mov [rsp], rax
    mov [rsp + 8], rdx
    xor r13d, r13d
1:  mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov edx, r13d
    call c2_line
    test r8d, r8d
    jz 8f
    inc r13d
    mov rdi, rax
    mov rsi, rdx
    call c2_trim
    test rdx, rdx
    jz 1b
    mov r14, rax
    mov r15, rdx
    xor ecx, ecx                # the separator's place
2:  cmp rcx, r15
    jae 6f
    movzx eax, byte ptr [r14 + rcx]
    cmp eax, [rsp + 16]
    je 3f
    inc rcx
    jmp 2b
3:  mov rbx, rcx
    mov rdi, r14
    mov rsi, rcx
    call c2_trim
    test rdx, rdx               # no name before it
    jz 6f
    test rbx, rbx
    jz 6f
    mov rdi, [rsp + 24]
    call c2_arg_c
    cmp dword ptr [rsp + 16], '='
    jne 4f
    call f_clr                  # KEY=value, both trimmed
    mov rdi, r14
    mov rsi, rbx
    call c2_trim
    mov rdi, rax
    mov rsi, rdx
    call f_n
    lea rdi, [rip + .Leq]
    call f_c
    lea rdi, [r14 + rbx + 1]
    mov rsi, r15
    sub rsi, rbx
    dec rsi
    call c2_trim
    mov rdi, rax
    mov rsi, rdx
    call f_n
    call f_get
    mov rdi, rax
    mov rsi, rdx
    call c2_arg_n
    lea rdi, [rip + fsb]
    call wipe
    jmp 1b
4:  mov rdi, r14
    mov rsi, r15
    call c2_arg_n
    jmp 1b
6:  call f_clr
    lea rdi, [rip + .Lm_e_env]
    cmp dword ptr [rsp + 16], '='
    je 7f
    lea rdi, [rip + .Lm_e_hdr]
7:  call f_c
    mov edi, r13d
    call f_u
    lea rdi, [rip + .Lm_e_line2]
    call f_c
    call c2_err_fsb
    xor eax, eax
    EPILOGUE
8:  mov eax, 1
    EPILOGUE

# mcp_ran(what, code): `claude mcp add` or `remove` ended
mcp_ran:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jnz 5f
    call f_clr                  # success: the extension's notice; to the list, read again
    mov eax, [rip + m_scope]
    cmp rbx, MW_ADD
    jne 2f
    lea rdi, [rip + .Lm_added]
    call f_c
    lea rdi, [rip + m_tf_name]
    call c2_tf_text
    mov rdi, rax
    mov rsi, rdx
    mov edx, NAME_MAX
    call f_cl
    lea rdi, [rip + .Lto]
    call f_c
    mov eax, [rip + m_scope]
    lea rcx, [rip + mcp_scope_ids]
    mov rdi, [rcx + rax*8]
    call f_c
    lea rdi, [rip + .Lm_added2]
    call f_c
    call c2_msg_fsb
    call mcp_free_form
    jmp 3f
2:  lea rdi, [rip + .Lm_removed]
    call f_c
    mov rdi, [rip + m_name]
    mov rsi, NAME_MAX
    call mcp_name_f
    lea rdi, [rip + .Lfrom]
    call f_c
    call removed_scope
    lea rdi, [rip + .Lm_removed2]
    call f_c
    call c2_msg_fsb
3:  mov dword ptr [rip + m_confirm], 0
    mov qword ptr [rip + c2_page], MP_LIST
    xor edi, edi
    call agentdlg_back
    mov qword ptr [rip + c2_busy], MA_RETRY
    call mcp_build
    mov edi, MR_LIST
    call c2_ask
    EPILOGUE
5:  mov rdi, r12                # its error, the values typed redacted
    call c2_errout
    cmp rbx, MW_ADD
    jne 6f
    call redact
6:  call c2_err_fsb
    mov dword ptr [rip + m_confirm], 0
    call mcp_build
    EPILOGUE

# removed_scope(): fsb += the scope of the server removed (from the kept list)
removed_scope:
    PROLOGUE
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    mov rdi, rax
    mov rsi, [rip + m_name]
    call mcp_find
    cmp rax, -1
    je 9f
    mov rdi, rbx
    mov esi, eax
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_scope]
    mov edx, NAME_MAX
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
9:  EPILOGUE

# mcp_free_form(): the form's fields emptied (after a server was added)
mcp_free_form:
    PROLOGUE
    lea rdi, [rip + m_tf_cmd]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_args]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_env]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_url]
    call c2_wipe_tf
    lea rdi, [rip + m_tf_hdr]
    call c2_wipe_tf
    EPILOGUE

# redact(): every value typed in the environment and headers fields (4 bytes or more) becomes "<redacted>"
#   in fsb (the extension's I9e and Iir, for the values)
redact:
    PROLOGUE 32
    lea rdi, [rip + m_tf_env]
    mov esi, '='
    call redact_tf
    lea rdi, [rip + m_tf_hdr]
    mov esi, ':'
    call redact_tf
    EPILOGUE

# redact_tf(TF*, sep): its lines' values out of fsb
redact_tf:
    PROLOGUE 32
    mov [rsp + 16], esi
    call tf_text
    mov [rsp], rax
    mov [rsp + 8], rdx
    xor r13d, r13d
1:  mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov edx, r13d
    call c2_line
    test r8d, r8d
    jz 9f
    inc r13d
    xor ecx, ecx
2:  cmp rcx, rdx
    jae 1b
    movzx r8d, byte ptr [rax + rcx]
    inc rcx
    cmp r8d, [rsp + 16]
    jne 2b
    lea rdi, [rax + rcx]
    mov rsi, rdx
    sub rsi, rcx
    call c2_trim
    cmp rdx, 4
    jb 1b
    mov rdi, rax
    mov rsi, rdx
    call fsb_replace
    jmp 1b
9:  EPILOGUE

# fsb_replace(ptr, len): every copy of those bytes in fsb becomes "<redacted>"
fsb_replace:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + csb]
    call sb_clear
    xor r13d, r13d
1:  mov rax, [rip + fsb + SB_len]
    sub rax, r13
    jb 5f
    cmp rax, r12
    jb 4f
    mov rdi, [rip + fsb + SB_ptr]
    add rdi, r13
    mov rsi, rbx
    mov rdx, r12
    call meq
    test eax, eax
    jz 3f
    lea rdi, [rip + csb]
    lea rsi, [rip + .Lredacted]
    call sb_push_cstr
    add r13, r12
    jmp 1b
3:  mov rax, [rip + fsb + SB_ptr]
    movzx esi, byte ptr [rax + r13]
    lea rdi, [rip + csb]
    call sb_push_byte
    inc r13
    jmp 1b
4:  mov rax, [rip + fsb + SB_len]   # the rest
    cmp r13, rax
    jae 5f
    mov rsi, [rip + fsb + SB_ptr]
    add rsi, r13
    sub rax, r13
    mov rdx, rax
    lea rdi, [rip + csb]
    call sb_push
5:  call f_clr
    mov rdi, [rip + csb + SB_ptr]
    mov rsi, [rip + csb + SB_len]
    call f_n
    EPILOGUE

.section .rodata
.p2align 3
c2_ops: .quad c2_act, c2_free
mods:                           # K_*: open, act, answer, ran, send, free, name, title, start
    .quad mcp_open, mcp_act, mcp_answer, mcp_ran, mcp_send, mcp_free, .Ln_mcp, .Lt_mcp, 1, mcp_tick
    .quad hooks_open, hooks_act, hooks_answer, hooks_ran, hooks_send, hooks_free, .Ln_hooks, .Lt_hooks, 1
    .quad hooks_tick
    .quad perms_open, perms_act, perms_answer, perms_ran, perms_send, perms_free, .Ln_perms, .Lt_perms, 1
    .quad perms_tick
    .quad sbx_open, sbx_act, sbx_answer, sbx_ran, sbx_send, sbx_free, .Ln_sandbox, .Lt_sandbox, 1
    .quad sbx_tick
    .quad plg_open, plg_act, plg_answer, plg_ran, plg_send, plg_free, .Ln_plugins, .Lt_plugins, 0
    .quad plg_tick
mcp_subtypes: .quad .Lv_mcp_status, .Lv_mcp_reconnect, .Lv_mcp_toggle, .Lv_mcp_toggle, .Lv_mcp_clear_auth
    .quad .Lv_mcp_authenticate, .Lv_mcp_callback
mcp_done: .quad 0, .Lm_d_reconnect, .Lm_d_disable, .Lm_d_enable, .Lm_d_clear, 0, .Lm_d_reconnect
mcp_fails: .quad 0, .Lm_f_reconnect, .Lm_f_disable, .Lm_f_enable, .Lm_f_clear, .Lm_f_auth, .Lm_f_callback
scope_order: .quad .Lv_project, .Lv_local, .Lv_user, .Lv_claudeai, .Lv_managed, .Lv_enterprise
scope_labels: .quad .Lw_project, .Lw_local, .Lw_user, .Lw_claudeai, .Lw_managed, .Lw_enterprise
rm_scopes: .quad .Lv_local, .Lv_user, .Lv_project, 0
status_tbl: .quad .Lv_connected, .Ls_connected, .Lv_failed, .Ls_failed, .Lv_needsauth, .Ls_needsauth
    .quad .Lv_pending, .Ls_pending, .Lv_disabled, .Ls_disabled, 0, 0
mcp_kept: .quad .Lk_name, .Lk_status, .Lk_scope, .Lk_error, 0
btn_words: .quad 0, 0, 0, 0, 0, 0, .Lb_reconnect, .Lb_clear, .Lb_disable, .Lb_enable, .Lb_auth, .Lb_check
    .quad .Lb_remove
btn_busy: .quad 0, 0, 0, 0, 0, 0, .Lb_reconnecting, .Lb_clearing, .Lb_disabling, .Lb_enabling, .Lb_authing
    .quad .Lb_reconnecting, .Lb_remove
transports: .quad .Lt_stdio, .Lt_stdio_d, .Lt_http, .Lt_http_d, .Lt_sse, .Lt_sse_d
transport_ids: .quad .Lv_stdio, .Lv_http, .Lv_sse
mcp_scopes: .quad .Lw_local, .Lsc_local_d, .Lw_user, .Lsc_user_d, .Lw_project, .Lsc_project_d
mcp_scope_ids: .quad .Lv_local, .Lv_user, .Lv_project
.Ln_mcp: .asciz "mcp"
.Lt_mcp: .asciz "MCP servers"
.Ln_hooks: .asciz "hooks"
.Lt_hooks: .asciz "Hooks"
.Ln_perms: .asciz "permissions"
.Lt_perms: .asciz "Permission rules"
.Ln_sandbox: .asciz "sandbox"
.Lt_sandbox: .asciz "Sandbox"
.Ln_plugins: .asciz "plugins"
.Lt_plugins: .asciz "Manage Plugins"
.Lempty: .asciz ""
.Lspace: .asciz " "
.Leq: .asciz "="
.Lellipsis: .asciz "\342\200\246"
.Lopen_paren: .asciz " ("
.Lclose_paren: .asciz ")"
.Lfrom: .asciz " from "
.Lto: .asciz " to "
.Lredacted: .asciz "<redacted>"
.Lerror_colon: .asciz "Error: "
.Lexited: .asciz "Claude Code exited with code "
.Lcould_not: .asciz "Claude Code could not save "
.Lexit_code: .asciz " (exit code "
.Lclose_dot: .asciz ")."
.Lno_start: .asciz "Claude Code could not start."
.Lnot_sent: .asciz "The request could not be sent to Claude Code."
.Lno_run: .asciz "Claude Code could not be started."
.Lwho: .asciz "Claude Code"
.Lk_subtype: .asciz "subtype"
.Lk_response: .asciz "response"
.Lk_error: .asciz "error"
.Lk_serverName: .asciz "serverName"
.Lk_enabled: .asciz "enabled"
.Lk_callbackUrl: .asciz "callbackUrl"
.Lk_authUrl: .asciz "authUrl"
.Lk_localhost: .asciz "localhostRedirectMayFail"
.Lk_requiresUserAction: .asciz "requiresUserAction"
.Lk_mcpServers: .asciz "mcpServers"
.Lk_config: .asciz "config"
.Lk_name: .asciz "name"
.Lk_status: .asciz "status"
.Lk_scope: .asciz "scope"
.Lk_type: .asciz "type"
.Lk_tools: .asciz "tools"
.Lk_annotations: .asciz "annotations"
.Lk_readOnly: .asciz "readOnly"
.Lk_destructive: .asciz "destructive"
.Lk_ro: .asciz "ro"
.Lk_de: .asciz "de"
.Lv_success: .asciz "success"
.Lv_vscode: .asciz "claude-vscode"
.Lv_mcp_status: .asciz "mcp_status"
.Lv_mcp_reconnect: .asciz "mcp_reconnect"
.Lv_mcp_toggle: .asciz "mcp_toggle"
.Lv_mcp_clear_auth: .asciz "mcp_clear_auth"
.Lv_mcp_authenticate: .asciz "mcp_authenticate"
.Lv_mcp_callback: .asciz "mcp_oauth_callback_url"
.Lv_project: .asciz "project"
.Lv_local: .asciz "local"
.Lv_user: .asciz "user"
.Lv_claudeai: .asciz "claudeai"
.Lv_managed: .asciz "managed"
.Lv_enterprise: .asciz "enterprise"
.Lv_connected: .asciz "connected"
.Lv_failed: .asciz "failed"
.Lv_needsauth: .asciz "needs-auth"
.Lv_pending: .asciz "pending"
.Lv_disabled: .asciz "disabled"
.Lv_sse: .asciz "sse"
.Lv_http: .asciz "http"
.Lv_stdio: .asciz "stdio"
.Lv_proxy: .asciz "claudeai-proxy"
.Lw_project: .asciz "Project"
.Lw_local: .asciz "Local"
.Lw_user: .asciz "User"
.Lw_claudeai: .asciz "claude.ai"
.Lw_managed: .asciz "Managed"
.Lw_enterprise: .asciz "Enterprise"
.Ls_connected: .asciz "\342\234\223 Connected"
.Ls_failed: .asciz "\342\234\227 Failed"
.Ls_needsauth: .asciz "\342\232\240 Needs Auth"
.Ls_pending: .asciz "\342\227\220 Connecting\342\200\246"
.Ls_disabled: .asciz "\342\227\213 Disabled"
.Lq_status: .asciz "? "
.Lm_loading: .asciz "Loading MCP servers\342\200\246"
.Lm_retrying: .asciz "Retrying\342\200\246"
.Lm_failed: .asciz "Failed to load servers: "
.Lm_retry: .asciz "Retry"
.Lm_none: .asciz "No MCP servers configured."
.Lm_filter: .asciz "Filter servers\342\200\246"
.Lm_add: .asciz "Add server"
.Lm_learn: .asciz "Learn more about MCP"
.Lm_url: .asciz "https://code.claude.com/docs/en/mcp"
.Lm_completing: .asciz "Completing authentication in browser\342\200\246"
.Lm_paste: .asciz "If the redirect page shows a connection error, paste the URL from your browser's address bar:"
.Lm_paste_ph: .asciz "http://localhost:.../callback?code=...&state=..."
.Lm_reopen: .asciz "Re-open authentication page"
.Lm_submit: .asciz "Submit"
.Lm_viewtools: .asciz "View tools ("
.Lm_viewtools2: .asciz ") \342\226\276"
.Lm_hidetools: .asciz "Hide tools \342\226\264"
.Lm_ro: .asciz "read-only"
.Lm_de: .asciz "destructive"
.Lm_remove_q: .asciz "Remove "
.Lm_config_q: .asciz " config?"
.Lm_confirm: .asciz "Confirm remove"
.Lm_removing: .asciz "Removing\342\200\246"
.Lm_cancel: .asciz "Cancel"
.Lm_authed: .asciz "Authenticated successfully"
.Lm_d_reconnect: .asciz "Reconnected to "
.Lm_d_disable: .asciz "Disabled "
.Lm_d_enable: .asciz "Enabled "
.Lm_d_clear: .asciz "Cleared authentication for "
.Lm_f_reconnect: .asciz "Failed to reconnect"
.Lm_f_disable: .asciz "Failed to disable server"
.Lm_f_enable: .asciz "Failed to enable server"
.Lm_f_clear: .asciz "Failed to clear authentication"
.Lm_f_auth: .asciz "Authentication failed"
.Lm_f_callback: .asciz "Failed to submit callback URL"
.Lb_reconnect: .asciz "Reconnect"
.Lb_reconnecting: .asciz "Reconnecting\342\200\246"
.Lb_clear: .asciz "Clear authentication"
.Lb_clearing: .asciz "Clearing\342\200\246"
.Lb_disable: .asciz "Disable"
.Lb_disabling: .asciz "Disabling\342\200\246"
.Lb_enable: .asciz "Enable"
.Lb_enabling: .asciz "Enabling\342\200\246"
.Lb_auth: .asciz "Authenticate"
.Lb_authing: .asciz "Authenticating\342\200\246"
.Lb_check: .asciz "Check connection"
.Lb_remove: .asciz "Remove"
.Lm_add_title: .asciz "Add MCP server"
.Lm_f_name: .asciz "Name"
.Lm_f_name_ph: .asciz "example-tools"
.Lm_transport: .asciz "Transport"
.Lt_stdio: .asciz "Local command (stdio)"
.Lt_stdio_d: .asciz "Runs a command on your machine"
.Lt_http: .asciz "HTTP (remote)"
.Lt_http_d: .asciz "Connects to a server by URL"
.Lt_sse: .asciz "SSE (remote, legacy)"
.Lt_sse_d: .asciz "Older remote protocol; prefer HTTP"
.Lm_f_cmd: .asciz "Command"
.Lm_f_cmd_ph: .asciz "npx"
.Lm_f_args: .asciz "Arguments (one per line)"
.Lm_f_env: .asciz "Environment variables (KEY=value, one per line)"
.Lm_f_url: .asciz "URL"
.Lm_f_url_ph: .asciz "https://example.com/mcp"
.Lm_f_hdr: .asciz "Headers (Header-Name: value, one per line)"
.Lm_scope: .asciz "Scope"
.Lsc_local_d: .asciz "Private to you in this project"
.Lsc_user_d: .asciz "Available in all your projects"
.Lsc_project_d: .asciz "Shared via .mcp.json in this project"
.Lm_project_warn: .asciz "Saved to .mcp.json and shared with everyone who opens this project. In IDE sessions, project servers connect without a separate approval step. If no folder is open, this writes to your home directory."
.Lm_add_server: .asciz "Add server"
.Lm_adding: .asciz "Adding\342\200\246"
.Lm_e_name: .asciz "Server name is required."
.Lm_e_invalid: .asciz "Invalid name "
.Lm_e_invalid2: .asciz ". Names can only contain letters, numbers, hyphens, and underscores."
.Lm_e_reserved: .asciz "claude-vscode is reserved for the extension itself."
.Lm_e_command: .asciz "Command is required."
.Lm_e_url: .asciz "URL is required."
.Lm_e_env: .asciz "Environment variables must be KEY=value (line "
.Lm_e_hdr: .asciz "Headers must be \"Header-Name: value\" (line "
.Lm_e_line2: .asciz ")."
.Lm_added: .asciz "Added "
.Lm_added2: .asciz " config. It will be available in new sessions."
.Lm_removed: .asciz "Removed "
.Lm_removed2: .asciz " config. Running sessions keep it until restarted."
.La_mcp: .asciz "mcp"
.La_add: .asciz "add"
.La_remove: .asciz "remove"
.La_scope: .asciz "--scope"
.La_transport: .asciz "--transport"
.La_env: .asciz "--env"
.La_header: .asciz "--header"
.La_dashes: .asciz "--"
