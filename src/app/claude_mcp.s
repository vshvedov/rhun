# rhun's in-process MCP server for Claude Code's chat (phase 4 task 9): the second transport over mcpsrv.s's
# core (the bridge for terminal claude, ide_server.s, is the first). Claude Code is told of the server in
# initialize ("sdkMcpServers":["rhun"] with its manifest, so the CLI needs no handshake: README findings 44,
# 45) and asks it through mcp_message control requests: {"subtype":"mcp_message","server_name":"rhun",
# "message":JSON-RPC}, answered with a control response whose response is {"mcp_response":JSON-RPC answer}
# (a notification's: {"mcp_response":{"jsonrpc":"2.0","result":{},"id":0}}). Its one tool is the extension's
# chat server's: getDiagnostics {uri?, minSeverity?} (edtools.s's edtool_get_diagnostics), for files of the
# project only. Every tool answers at once: a prompt never waits on this server (finding 51), and
# notifications/cancelled has nothing to cancel (finding 46). Requests are served in any state of the live
# record, before the initialize answer too (finding 44). The note rhun adds to the system prompt
# (appendSystemPrompt) is rhun's own (the coordinator's decision): it names rhun and says what the editor
# gives the agent.
#
#   claude_mcp_init(sb)                 initialize's members, written with jw_* into the open request
#   claude_mcp_request(AL*, record, request) -> eax 1 answered      an mcp_message (h_request)
#   claude_mcp_ctl                      print-agent-tools, agent-mcp, agent-test-problem,
#                                       agent-test-problems-clear (control.s's ctl_tables)
.include "rhun.inc"

.equ TEST_SOURCES, 16

.bss
.p2align 3
mo: .zero SB_SIZE               # mcp_handle's answer
ro: .zero SB_SIZE               # the control response's response member
idt: .zero SB_SIZE              # a request's id as JSON text
calls: .quad 0                  # tools/call requests this transport handled
asked: .quad 0                  # mcp_message requests answered
took_us: .quad 0                # agent-mcp: how long the server took (print-agent-tools)
tbase: .quad 0                  # agent-diag-base's base
tsrc: .zero 8 * TEST_SOURCES    # agent-test-problem's sources
ntsrc: .quad 0
tpr: .zero PR_SIZE
tkey: .zero SB_SIZE
tmsg: .zero SB_SIZE
tcode: .zero SB_SIZE
tpath: .zero SB_SIZE
tlabel: .zero SB_SIZE

.data
.p2align 3
.globl rhun_ms
rhun_ms: .quad .Ls_rhun, rhun_version, rhun_tools, 1
rhun_tools:
    .quad .Lt_diag, .Ld_diag, .Ls_diag
    .long MTF_READONLY, 0
    .quad .Lti_diag, edtool_get_diagnostics

.text

# FN claude_mcp_init(sb): "sdkMcpServers":["rhun"], "sdkMcpServerManifests":{"rhun":MANIFEST},
#   "appendSystemPrompt":NOTE, "systemPromptSnapshot":true, as members of the request open in the writer
FN claude_mcp_init
    PROLOGUE
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Lk_servers]
    call jw_key
    mov rdi, rbx
    call jw_arr
    mov rdi, rbx
    lea rsi, [rip + .Ls_rhun]
    call jw_cstr
    mov rdi, rbx
    call jw_end_arr
    mov rdi, rbx
    lea rsi, [rip + .Lk_manifests]
    call jw_key
    mov rdi, rbx
    call jw_obj
    mov rdi, rbx
    lea rsi, [rip + .Ls_rhun]
    call jw_key
    lea rdi, [rip + rhun_ms]
    mov rsi, rbx
    call mcp_manifest
    mov rdi, rbx
    call jw_end_obj
    mov rdi, rbx
    lea rsi, [rip + .Lk_append]
    call jw_key
    mov rdi, rbx
    lea rsi, [rip + note]
    mov edx, note_end - note
    call jw_str
    mov rdi, rbx
    lea rsi, [rip + .Lk_snapshot]
    call jw_key
    mov rdi, rbx
    mov esi, 1
    call jw_bool
    EPILOGUE

# FN claude_mcp_request(AL*, record, request) -> eax 1: an mcp_message answered: rhun's server handles its
#   JSON-RPC message (mcpsrv.s) and the answer goes back in the control response; a server of another name
#   gets an error reply. Nothing of AL is touched after the write (a write may close the connection)
FN claude_mcp_request
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    inc qword ptr [rip + asked]
    mov rdi, r12
    lea rsi, [rip + .Lk_request_id]
    call json_get
    mov r14, rax                # the request's id (a jv of the record)
    mov rdi, r13
    lea rsi, [rip + .Lk_server_name]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Ls_rhun]
    call json_is
    test eax, eax
    jz .Lmr_unknown
    mov rax, [rbx + AL_as]      # a relative uri is under the conversation's checkout, else the project
    mov rdi, [rax + AS_cwd]
    test rdi, rdi
    jnz 1f
    mov rdi, [rip + g_project]
1:  call edtool_set_base
    call mcp_calls
    mov [rsp], rax
    mov rdi, r13
    lea rsi, [rip + .Lk_message]
    call json_get
    lea rdi, [rip + rhun_ms]
    mov rsi, rax
    lea rdx, [rip + mo]
    xor ecx, ecx                # no token: every tool answers at once
    call mcp_handle
    mov r15d, eax
    xor edi, edi
    call edtool_set_base
    call mcp_calls
    sub rax, [rsp]
    add [rip + calls], rax
    lea rdi, [rip + ro]         # the control response's response member
    call sb_clear
    cmp r15d, 1
    je 3f
    cmp r15d, 2
    je 4f
    lea rdi, [rip + ro]         # a notification (or a response): answered all the same (finding 44)
    lea rsi, [rip + .Lv_notified]
    call sb_push_cstr
    jmp 5f
3:  lea rdi, [rip + ro]
    lea rsi, [rip + .Lv_resp_head]
    call sb_push_cstr
    lea rdi, [rip + ro]
    mov rsi, [rip + mo + SB_ptr]
    mov rdx, [rip + mo + SB_len]
    call sb_push
    lea rdi, [rip + ro]
    mov esi, '}'
    call sb_push_byte
    jmp 5f
4:  # a tool that would answer later (none of this server's does): an error now, so nothing waits
    lea rdi, [rip + ro]
    lea rsi, [rip + .Lv_later_head]
    call sb_push_cstr
    lea rdi, [rip + ro]
    mov rsi, [rip + mo + SB_ptr]
    mov rdx, [rip + mo + SB_len]
    call sb_push
    lea rdi, [rip + ro]
    lea rsi, [rip + .Lv_later_tail]
    call sb_push_cstr
5:  lea rdi, [rip + idt]        # the id as it came
    call jw_begin
    lea rdi, [rip + idt]
    mov rsi, r14
    call jw_jv
    mov rdi, rbx
    mov rsi, [rip + idt + SB_ptr]
    mov rdx, [rip + idt + SB_len]
    mov rcx, [rip + ro + SB_ptr]
    mov r8, [rip + ro + SB_len]
    call claude_ok_reply
    mov eax, 1
    EPILOGUE
.Lmr_unknown:
    mov rdi, rbx
    mov rsi, r14
    lea rdx, [rip + .Le_server]
    call claude_err_reply
    mov eax, 1
    EPILOGUE

# ---------------- headless commands ----------------

# arg(out, rest*, len*) helpers: the commands keep their line in rest/len
.bss
.p2align 3
c_out: .quad 0
c_rest: .quad 0
c_len: .quad 0
.text

c_set:
    mov [rip + c_out], rdi
    mov [rip + c_rest], rsi
    mov [rip + c_len], rdx
    ret

# c_arg() -> rax ptr, rdx len: the next word of the line
c_arg:
    mov rdi, [rip + c_rest]
    mov rsi, [rip + c_len]
    push rbx
    call next_word
    add [rip + c_rest], rcx
    sub [rip + c_len], rcx
    pop rbx
    ret

# print-agent-tools: "server=rhun tools=N calls=N asked=N lists=N took_us=N", then "tool NAME readonly=0|1
#   title=T" (calls: tools/call requests of the chat's server; asked: its mcp_message requests; lists: how
#   many times the editor's problems were read for any tool or hook; took_us: the last agent-mcp's time)
c_print_tools:
    PROLOGUE
    call c_set
    mov rbx, [rip + c_out]
    mov rdi, rbx
    lea rsi, [rip + .Lw_server]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + rhun_ms + MS_name]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lw_tools]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + rhun_ms + MS_ntools]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lw_calls]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + calls]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lw_asked]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + asked]
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lw_lists]
    call sb_push_cstr
    call edtool_diag_runs
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lw_took]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rip + took_us]
    call sb_push_u64
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov r12, [rip + rhun_ms + MS_tools]
    xor r13d, r13d
1:  cmp r13, [rip + rhun_ms + MS_ntools]
    jae 9f
    mov rdi, rbx
    lea rsi, [rip + .Lw_tool]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r12 + MT_name]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lw_readonly]
    call sb_push_cstr
    mov esi, [r12 + MT_flags]
    and esi, MTF_READONLY
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lw_title]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [r12 + MT_title]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    add r12, MT_SIZE
    inc r13
    jmp 1b
9:  xor eax, eax
    EPILOGUE

# agent-mcp JSON: the JSON-RPC message handled by the chat's server as an mcp_message would be (the
#   conversation's checkout: none, so a relative uri is under the project); its answer printed, or "none"
#   for a notification
c_mcp:
    PROLOGUE
    call c_set
    mov rdi, [rip + g_project]
    call edtool_set_base
    mov rdi, [rip + c_rest]
    mov rsi, [rip + c_len]
    call json_parse
    mov r12, rax
    call time_us
    mov r13, rax
    lea rdi, [rip + rhun_ms]
    mov rsi, r12
    lea rdx, [rip + mo]
    xor ecx, ecx
    call mcp_handle
    mov ebx, eax
    call time_us
    sub rax, r13
    mov [rip + took_us], rax
    xor edi, edi
    call edtool_set_base
    mov rdi, [rip + c_out]
    cmp ebx, 1
    jne 1f
    mov rsi, [rip + mo + SB_ptr]
    mov rdx, [rip + mo + SB_len]
    call sb_push
    jmp 2f
1:  lea rsi, [rip + .Lw_none]
    call sb_push_cstr
2:  mov rdi, [rip + c_out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

# agent-test-problem PATH LINE COL SEVERITY SOURCE [code=K] [end=L:C] MESSAGE: a problem into the Problems
#   store (as a task's matcher or an extension's file diagnostics put one): SEVERITY error|warning|info|hint,
#   COL 0 for none, the source "SOURCE" (its key agent-test:SOURCE); a column in characters with COL (and
#   then the end's) written cN; end: the exclusive end, 1-based
c_test_problem:
    PROLOGUE 16
    call c_set
    lea rdi, [rip + tpr]
    xor esi, esi
    mov edx, PR_SIZE
    call memset
    call c_arg                  # PATH
    lea rdi, [rip + tpath]
    call word_cstr
    mov [rip + tpr + PR_path], rax
    call c_arg                  # LINE
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov [rip + tpr + PR_line], eax
    call c_arg                  # COL, or cCOL in characters
    test rdx, rdx
    jz 8f
    cmp byte ptr [rax], 'c'
    jne 1f
    or dword ptr [rip + tpr + PR_flags], PRF_CHARS
    inc rax
    dec rdx
1:  mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov [rip + tpr + PR_col], eax
    call c_arg                  # SEVERITY
    mov rbx, rax
    mov r12, rdx
    xor r13d, r13d
2:  cmp r13d, 4
    jae 8f
    lea rax, [rip + sev_words]
    mov rdx, [rax + r13*8]
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 3f
    inc r13d
    jmp 2b
3:  mov [rip + tpr + PR_sev], r13d
    call c_arg                  # SOURCE
    mov rbx, rax
    mov r12, rdx
    lea rdi, [rip + tlabel]
    call word_cstr
    lea rdi, [rip + tkey]
    call sb_clear
    lea rdi, [rip + tkey]
    lea rsi, [rip + .Lw_key]
    call sb_push_cstr
    lea rdi, [rip + tkey]
    mov rsi, rbx
    mov rdx, r12
    call sb_push
    lea rdi, [rip + tkey]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + tkey + SB_ptr]
    mov rsi, [rip + tlabel + SB_ptr]
    call problems_source
    mov [rsp], rax
    mov rdi, rax                # kept for agent-test-problems-clear
    call tsrc_keep
40: mov rdi, [rip + c_rest]     # [code=K] [end=L:C]
    mov rsi, [rip + c_len]
    call next_word
    cmp rdx, 5
    jb 4f
    cmp dword ptr [rax], 0x3d646e65     # "end="
    je 42f
    cmp dword ptr [rax], 0x65646f63     # "code"
    jne 4f
    cmp byte ptr [rax + 4], '='
    jne 4f
    add [rip + c_rest], rcx
    sub [rip + c_len], rcx
    lea rsi, [rax + 5]
    sub rdx, 5
    mov rax, rsi
    lea rdi, [rip + tcode]
    call word_cstr
    mov [rip + tpr + PR_code], rax
    jmp 40b
42: add [rip + c_rest], rcx
    sub [rip + c_len], rcx
    lea rbx, [rax + 4]          # L:C
    lea r12, [rdx - 4]
    xor ecx, ecx
43: cmp rcx, r12
    jae 4f
    cmp byte ptr [rbx + rcx], ':'
    je 44f
    inc rcx
    jmp 43b
44: mov r13, rcx
    mov rdi, rbx
    mov rsi, rcx
    call parse_u64
    mov [rip + tpr + PR_endline], eax
    lea rdi, [rbx + r13 + 1]
    mov rsi, r12
    sub rsi, r13
    dec rsi
    call parse_u64
    mov [rip + tpr + PR_endcol], eax
    jmp 40b
4:  mov rdi, [rip + c_rest]     # MESSAGE: the rest, from its first non-blank
    mov rsi, [rip + c_len]
    call next_word
    mov rcx, [rip + c_rest]
    add rcx, [rip + c_len]
    sub rcx, rax
    mov rdx, rcx
    lea rdi, [rip + tmsg]
    call word_cstr
    mov [rip + tpr + PR_msg], rax
    mov rdi, [rsp]
    lea rsi, [rip + tpr]
    call problems_add
    mov rdi, [rip + c_out]
    lea rsi, [rip + .Lw_kept]
    test eax, eax
    jnz 5f
    lea rsi, [rip + .Lw_dropped]
5:  call sb_push_cstr
    xor eax, eax
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# agent-test-problems N: N problems into the store at once (the cap test): problem i in PROJECT/many/fK.c
#   (K = i / 100) at line i % 100 + 1, column 1, severity i % 4, source bulkS (S = i / 2000: a source holds
#   2000), message "problem i"; prints "kept=N"
c_test_many:
    PROLOGUE 16
    call c_set
    call c_arg
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    mov r15, rax
    xor r12d, r12d              # i
    mov qword ptr [rsp], 0      # kept
1:  cmp r12, r15
    jae 8f
    lea rdi, [rip + tpr]
    xor esi, esi
    mov edx, PR_SIZE
    call memset
    lea rdi, [rip + tpath]      # the path
    call sb_clear
    lea rdi, [rip + tpath]
    mov rsi, [rip + g_project]
    call sb_push_cstr
    lea rdi, [rip + tpath]
    lea rsi, [rip + .Lw_many]
    call sb_push_cstr
    mov rax, r12
    xor edx, edx
    mov ecx, 100
    div rcx
    mov r13, rdx                # i % 100
    lea rdi, [rip + tpath]
    mov rsi, rax
    call sb_push_u64
    lea rdi, [rip + tpath]
    lea rsi, [rip + .Lw_dotc]
    call sb_push_cstr
    lea rdi, [rip + tpath]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + tpath + SB_ptr]
    mov [rip + tpr + PR_path], rax
    lea eax, [r13 + 1]
    mov [rip + tpr + PR_line], eax
    mov dword ptr [rip + tpr + PR_col], 1
    mov eax, r12d
    and eax, 3
    mov [rip + tpr + PR_sev], eax
    lea rdi, [rip + tmsg]       # the message
    call sb_clear
    lea rdi, [rip + tmsg]
    lea rsi, [rip + .Lw_problem]
    call sb_push_cstr
    lea rdi, [rip + tmsg]
    mov rsi, r12
    call sb_push_u64
    lea rdi, [rip + tmsg]
    xor esi, esi
    call sb_push_byte
    mov rax, [rip + tmsg + SB_ptr]
    mov [rip + tpr + PR_msg], rax
    lea rdi, [rip + tkey]       # the source
    call sb_clear
    lea rdi, [rip + tkey]
    lea rsi, [rip + .Lw_key]
    call sb_push_cstr
    lea rdi, [rip + tkey]
    lea rsi, [rip + .Lw_bulk]
    call sb_push_cstr
    mov rax, r12
    xor edx, edx
    mov ecx, 2000
    div rcx
    mov r14, rax
    lea rdi, [rip + tkey]
    mov rsi, r14
    call sb_push_u64
    lea rdi, [rip + tkey]
    xor esi, esi
    call sb_push_byte
    lea rdi, [rip + tlabel]
    call sb_clear
    lea rdi, [rip + tlabel]
    lea rsi, [rip + .Lw_bulk]
    call sb_push_cstr
    lea rdi, [rip + tlabel]
    mov rsi, r14
    call sb_push_u64
    lea rdi, [rip + tlabel]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + tkey + SB_ptr]
    mov rsi, [rip + tlabel + SB_ptr]
    call problems_source
    mov rbx, rax
    mov rdi, rax
    call tsrc_keep
    mov rdi, rbx
    lea rsi, [rip + tpr]
    call problems_add
    add [rsp], rax
    inc r12
    jmp 1b
8:  mov rdi, [rip + c_out]
    lea rsi, [rip + .Lw_kept_eq]
    call sb_push_cstr
    mov rdi, [rip + c_out]
    mov rsi, [rsp]
    call sb_push_u64
    mov rdi, [rip + c_out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

# print-agent-hooks: the hooks' answers that wait (claude_hooks.s claude_hooks_dump)
c_print_hooks:
    PROLOGUE
    call claude_hooks_dump
    xor eax, eax
    EPILOGUE

# agent-diag-base PATH: the file's problems now kept as a base (as hook_0 keeps one), a former one freed;
#   prints "base=1", or "base=0" for a file outside the project
c_diag_base:
    PROLOGUE
    call c_set
    mov rdi, [rip + tbase]
    call edtool_diag_free
    mov qword ptr [rip + tbase], 0
    mov rdi, [rip + g_project]
    call edtool_set_base
    call c_arg
    lea rdi, [rip + tpath]
    call word_cstr
    mov rdi, rax
    call edtool_diag_base
    mov [rip + tbase], rax
    xor edi, edi
    call edtool_set_base
    mov rdi, [rip + c_out]
    lea rsi, [rip + .Lw_base1]
    cmp qword ptr [rip + tbase], 0
    jne 1f
    lea rsi, [rip + .Lw_base0]
1:  call sb_push_cstr
    xor eax, eax
    EPILOGUE

# agent-diag-new PATH: what is new in the file since agent-diag-base's base (as hook_2 finds it; the base is
#   used up): "new=N", then the JSON the hook's context holds
c_diag_new:
    PROLOGUE
    call c_set
    mov rdi, [rip + g_project]
    call edtool_set_base
    call c_arg
    lea rdi, [rip + tpath]
    call word_cstr
    lea rdi, [rip + mo]
    call sb_clear
    mov rdi, [rip + tbase]
    mov qword ptr [rip + tbase], 0
    mov rsi, [rip + tpath + SB_ptr]
    lea rdx, [rip + mo]
    call edtool_diag_new
    mov ebx, eax
    xor edi, edi
    call edtool_set_base
    mov rdi, [rip + c_out]
    lea rsi, [rip + .Lw_new]
    call sb_push_cstr
    mov rdi, [rip + c_out]
    mov esi, ebx
    call sb_push_u64
    mov rdi, [rip + c_out]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rip + c_out]
    mov rsi, [rip + mo + SB_ptr]
    mov rdx, [rip + mo + SB_len]
    call sb_push
    mov rdi, [rip + c_out]
    mov esi, 10
    call sb_push_byte
    xor eax, eax
    EPILOGUE

# word_cstr(sb, ptr rax, len rdx) -> rax the sb's text: those bytes and a NUL
word_cstr:
    PROLOGUE
    mov rbx, rdi
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, rbx
    xor esi, esi
    call sb_push_byte
    mov rax, [rbx + SB_ptr]
    EPILOGUE

# tsrc_keep(PS*): remembered once
tsrc_keep:
    xor ecx, ecx
1:  cmp rcx, [rip + ntsrc]
    jae 2f
    lea rax, [rip + tsrc]
    cmp [rax + rcx*8], rdi
    je 9f
    inc rcx
    jmp 1b
2:  cmp rcx, TEST_SOURCES
    jae 9f
    lea rax, [rip + tsrc]
    mov [rax + rcx*8], rdi
    inc qword ptr [rip + ntsrc]
9:  ret

# agent-test-problems-clear: the problems agent-test-problem added go (problems_clear of each source)
c_test_clear:
    PROLOGUE
    call c_set
    xor ebx, ebx
1:  cmp rbx, [rip + ntsrc]
    jae 9f
    lea rax, [rip + tsrc]
    mov rdi, [rax + rbx*8]
    inc rbx
    call problems_clear
    jmp 1b
9:  xor eax, eax
    EPILOGUE

.section .rodata
.Ls_rhun: .asciz "rhun"
.Lt_diag: .asciz "getDiagnostics"
.Lti_diag: .asciz "Get diagnostics"
# the extension's description (EXT@3189900, DSr) with rhun for VS Code, and the one sentence rhun adds
.Ld_diag: .ascii "Get the errors, warnings and other diagnostics rhun currently shows in its Problems panel, "
    .ascii "including those for unsaved changes in open editors. Returns a JSON array with one entry per "
    .ascii "file, each listing that file's diagnostics. Pass `uri` to check one file; its entry is returned "
    .ascii "even when it has no diagnostics. Omit `uri` to get only the files that have at least one "
    .ascii "diagnostic. Pass `minSeverity` to include only diagnostics at least that severe, for example "
    .ascii "`Warning` for errors and warnings only; without `uri`, files left with none are omitted. Many "
    .ascii "language extensions only analyze open files, so a missing file or an empty list can mean the "
    .ascii "file has not been checked, not that it is clean. Only files in the project's folders are "
    .asciz "listed."
# its input schema as the extension's zod schema is written (README finding 46's recording)
.Ls_diag: .ascii "{\"type\":\"object\",\"properties\":{\"uri\":{\"type\":\"string\",\"description\":\"file:// URI "
    .ascii "of the one file to check. Omit to get every file that has at least one diagnostic (at or above "
    .ascii "`minSeverity`, when given).\"},\"minSeverity\":{\"type\":\"string\",\"enum\":[\"Error\",\"Warning\","
    .ascii "\"Information\",\"Hint\"],\"description\":\"Include only diagnostics at least this severe. From "
    .ascii "most to least severe: Error, Warning, Information, Hint. Omit to include every severity.\"}},"
    .asciz "\"additionalProperties\":false,\"$schema\":\"http://json-schema.org/draft-07/schema#\"}"
.Lk_servers: .asciz "sdkMcpServers"
.Lk_manifests: .asciz "sdkMcpServerManifests"
.Lk_append: .asciz "appendSystemPrompt"
.Lk_snapshot: .asciz "systemPromptSnapshot"
.Lk_request_id: .asciz "request_id"
.Lk_server_name: .asciz "server_name"
.Lk_message: .asciz "message"
.Lv_resp_head: .asciz "{\"mcp_response\":"
.Lv_notified: .asciz "{\"mcp_response\":{\"jsonrpc\":\"2.0\",\"result\":{},\"id\":0}}"
.Lv_later_head: .asciz "{\"mcp_response\":{\"jsonrpc\":\"2.0\",\"id\":"
.Lv_later_tail: .asciz ",\"error\":{\"code\":-32603,\"message\":\"The tool did not answer\"}}}"
.Le_server: .asciz "unknown server"
.Lw_server: .asciz "server="
.Lw_tools: .asciz " tools="
.Lw_calls: .asciz " calls="
.Lw_asked: .asciz " asked="
.Lw_lists: .asciz " lists="
.Lw_took: .asciz " took_us="
.Lw_tool: .asciz "tool "
.Lw_readonly: .asciz " readonly="
.Lw_title: .asciz " title="
.Lw_none: .asciz "none"
.Lw_key: .asciz "agent-test:"
.Lw_kept: .asciz "kept\n"
.Lw_kept_eq: .asciz "kept="
.Lw_base1: .asciz "base=1\n"
.Lw_base0: .asciz "base=0\n"
.Lw_new: .asciz "new="
.Lw_many: .asciz "/many/f"
.Lw_dotc: .asciz ".c"
.Lw_problem: .asciz "problem "
.Lw_bulk: .asciz "bulk"
.Lc_test_many: .asciz "agent-test-problems"
.Lc_print_hooks: .asciz "print-agent-hooks"
.Lc_diag_base: .asciz "agent-diag-base"
.Lc_diag_new: .asciz "agent-diag-new"
.Lw_dropped: .asciz "dropped\n"
.Lsw_error: .asciz "error"
.Lsw_warning: .asciz "warning"
.Lsw_info: .asciz "info"
.Lsw_hint: .asciz "hint"
.Lc_print_tools: .asciz "print-agent-tools"
.Lc_mcp: .asciz "agent-mcp"
.Lc_test_problem: .asciz "agent-test-problem"
.Lc_test_clear: .asciz "agent-test-problems-clear"
# The note rhun adds to Claude Code's system prompt (appendSystemPrompt): rhun's own (the coordinator's
# decision), printed whole in docs/guide.md; tests/claude-mcp.py checks its SHA-256
note:
    .ascii "\n# rhun Editor Context\n\n"
    .ascii "You are running inside rhun, a code editor: the user talks to you in its chat.\n\n"
    .ascii "## Code References in Text\n"
    .ascii "When you reference files or code locations, use markdown links, so the user can open them with "
    .ascii "a click:\n"
    .ascii "- For files: [filename.ts](src/filename.ts)\n"
    .ascii "- For specific lines: [filename.ts:42](src/filename.ts#L42)\n"
    .ascii "- For a range of lines: [filename.ts:42-51](src/filename.ts#L42-L51)\n"
    .ascii "- For folders: [src/utils/](src/utils/)\n"
    .ascii "Unless the user asks for them, do not use backticks or HTML tags for file references.\n"
    .ascii "Link paths are relative to your working directory.\n\n"
    .ascii "## What the editor gives you\n"
    .ascii "- The tool mcp__rhun__getDiagnostics returns the errors, warnings and other problems rhun shows "
    .ascii "in its Problems list and in open files, for files in the project's folders. Many languages are "
    .ascii "checked only in open files: a missing file can mean it was not checked, not that it is clean.\n"
    .ascii "- The user sees each edit you propose and allows or refuses it before it is written, unless "
    .ascii "their permission mode allows edits.\n"
    .ascii "- The user's editor selection or open file may come with a message, marked with ide_selection "
    .ascii "or ide_opened_file tags; it may or may not be related to the request.\n"
    .ascii "- Before you read or edit a file that has unsaved changes in rhun, rhun saves it, unless the user "
    .ascii "turned that off.\n"
    .ascii "- After you edit a file, the problems that are new in it are reported to you in ide_diagnostics "
    .ascii "tags.\n"
note_end:
.p2align 3
sev_words: .quad .Lsw_error, .Lsw_warning, .Lsw_info, .Lsw_hint
.globl claude_mcp_ctl
claude_mcp_ctl:
    .quad .Lc_print_tools, c_print_tools
    .quad .Lc_mcp, c_mcp
    .quad .Lc_test_problem, c_test_problem
    .quad .Lc_test_clear, c_test_clear
    .quad .Lc_test_many, c_test_many
    .quad .Lc_print_hooks, c_print_hooks                            # task 10
    .quad .Lc_diag_base, c_diag_base, .Lc_diag_new, c_diag_new
    .quad 0, 0
