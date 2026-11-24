# tools (wider-parity D3): tools extensions declare in [tools] and rhun's own rhun.* tools, listed
# and called by other extensions through rhun (feature tools). A call to a tool that changes
# anything waits for the user: Allow once, Allow for this session, or Deny, one dialog at a time;
# calls queue meanwhile. rhun routes an extension tool's call to its owner (started if it is idle)
# and passes the answer back; the built-in tools run with the caller's [needs].
.include "rhun.inc"

.equ TOOLS_PER_EXT, 64          # a grant is a bit of AX_grants... per caller and tool: kept in grants
.equ TOOL_NAME_MAX, 40
.equ TOOL_TEXT_MAX, 1000        # title, description and input of a tool
.equ TOOL_START_WAIT, 10000     # ms a call waits for its tool's extension to start
.equ TOOL_CALLS_MAX, 256        # calls waiting at once, all extensions

# a tool from a manifest
STRUCT
F TLX_name, 8            # cstr, [a-z0-9_]
F TLX_title, 8           # cstr
F TLX_desc, 8            # cstr or 0
F TLX_input, 8           # cstr or 0
F TLX_ro, 4              # readonly = yes: no confirmation
F TLX_pad, 4
ENDSTRUCT TLX_SIZE

# a call in flight
STRUCT
F TCL_caller, 8          # the extension that called
F TCL_creq, 8            # its request id
F TCL_owner, 8           # the tool's extension, 0 for rhun.*
F TCL_tool, 8            # TL*, or the built-in's index
F TCL_name, 8            # cstr: OWNER/NAME.tool or rhun.tool
F TCL_input, 8           # owned copy of the input
F TCL_inlen, 8
F TCL_state, 4           # TCS_*
F TCL_ro, 4
F TCL_oreq, 8            # the tool request sent to the owner
F TCL_since, 8           # time_ms it began waiting
ENDSTRUCT TCL_SIZE

.equ TCS_CONFIRM, 0              # waits for the user's answer
.equ TCS_ASKING, 1               # the dialog asks about it
.equ TCS_START, 2                # its tool's extension is starting
.equ TCS_OWNER, 3                # sent to the owner
.equ TCS_REVIEW, 4               # rhun.propose: the Review tab decides
.equ TCS_TERM, 5                 # rhun.run: rhun's prompt decides

# built-in tools
.equ TBT_EDITORS, 0
.equ TBT_SELECTION, 1
.equ TBT_READ, 2
.equ TBT_DIAGNOSTICS, 3
.equ TBT_OPEN, 4
.equ TBT_PROPOSE, 5
.equ TBT_RUN, 6
.equ TBT_COUNT, 7

.bss
.p2align 3
calls: .zero VEC_SIZE           # CL*
grants: .zero VEC_SIZE          # (caller EXT*, name cstr) pairs: allowed for this session
asking: .quad 0                 # the CL the dialog asks about
ticking: .quad 0                # tools_tick runs: closing a dialog inside it does not run it again
out: .zero SB_SIZE
tmp: .zero SB_SIZE
num: .zero 32
dlg_q: .zero 256
dlg_line: .zero 512
kv_ptr: .quad 0                 # kv_find: the value found
kv_len: .quad 0

.text

# ---------------- the manifest ----------------

# FN tools_manifest_kv(ext, ini): NAME = Title | description, NAME.input = ..., NAME.readonly = yes
FN tools_manifest_kv
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call ai_ext
    mov r13, rax
    # the tool's name: the key up to a dot
    mov rdi, [r12 + INI_key]
    mov rsi, [r12 + INI_keylen]
    xor ecx, ecx
1:  cmp rcx, rsi
    jae 2f
    cmp byte ptr [rdi + rcx], '.'
    je 2f
    inc rcx
    jmp 1b
2:  mov [rsp], rcx              # name length
    mov r14, rsi
    sub r14, rcx                # the part from the dot
    mov rsi, rcx
    call name_ok
    test eax, eax
    jz 9f
    mov rdi, r13
    mov rsi, [r12 + INI_key]
    mov rdx, [rsp]
    call tool_find
    test rax, rax
    jnz 3f
    cmp qword ptr [r13 + AX_tools + VEC_len], TOOLS_PER_EXT
    jae 9f
    lea rdi, [r13 + AX_tools]
    mov esi, TLX_SIZE
    call vec_push
    mov r15, rax
    mov rdi, [r12 + INI_key]
    mov rsi, [rsp]
    call ai_dup
    mov [r15 + TLX_name], rax
    mov rax, r15
3:  mov r15, rax
    test r14, r14
    jnz 5f
    # NAME = Title | description
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    xor ecx, ecx
4:  cmp rcx, rsi
    jae 41f
    cmp byte ptr [rdi + rcx], '|'
    je 41f
    inc rcx
    jmp 4b
41: mov [rsp + 8], rcx
    mov rsi, rcx
    call trim
    lea rdi, [r15 + TLX_title]
    mov rsi, rax
    call set_text
    mov rcx, [rsp + 8]
    cmp rcx, [r12 + INI_vallen]
    jae 9f
    mov rdi, [r12 + INI_val]
    lea rdi, [rdi + rcx + 1]
    mov rsi, [r12 + INI_vallen]
    sub rsi, rcx
    dec rsi
    call trim
    lea rdi, [r15 + TLX_desc]
    mov rsi, rax
    call set_text
    jmp 9f
5:  mov rdi, [r12 + INI_key]
    add rdi, [rsp]
    mov rsi, r14
    lea rdx, [rip + .Lk_input]
    call str_eq_cstr
    test eax, eax
    jz 6f
    lea rdi, [r15 + TLX_input]
    mov rsi, [r12 + INI_val]
    mov rdx, [r12 + INI_vallen]
    call set_text
    jmp 9f
6:  mov rdi, [r12 + INI_key]
    add rdi, [rsp]
    mov rsi, r14
    lea rdx, [rip + .Lk_readonly]
    call str_eq_cstr
    test eax, eax
    jz 9f
    mov rdi, [r12 + INI_val]
    mov rsi, [r12 + INI_vallen]
    call parse_bool
    mov [r15 + TLX_ro], eax
9:  EPILOGUE

# name_ok(ptr, len) -> eax 1 for 1 to 40 of [a-z0-9_]
name_ok:
    xor eax, eax
    test rsi, rsi
    jz 9f
    cmp rsi, TOOL_NAME_MAX
    ja 9f
    xor ecx, ecx
1:  movzx edx, byte ptr [rdi + rcx]
    cmp edx, '_'
    je 2f
    lea r8d, [rdx - 'a']
    cmp r8d, 25
    jbe 2f
    lea r8d, [rdx - '0']
    cmp r8d, 9
    ja 9f
2:  inc rcx
    cmp rcx, rsi
    jb 1b
    inc eax
9:  ret

# set_text(slot, ptr, len): *slot holds a copy cut to TOOL_TEXT_MAX
set_text:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [rbx]
    call mem_free
    mov rdi, r12
    mov rsi, r13
    mov edx, TOOL_TEXT_MAX
    call ai_cut
    mov rdi, rax
    mov rsi, rdx
    call ai_dup
    mov [rbx], rax
    EPILOGUE

# tool_find(AX*, name, len) -> TL* or 0
tool_find:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
1:  cmp r14, [rbx + AX_tools + VEC_len]
    jae 8f
    imul r15, r14, TLX_SIZE
    add r15, [rbx + AX_tools + VEC_ptr]
    inc r14
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r15 + TLX_name]
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# FN tools_ext_reset(ext): a record being (re)loaded drops its tools
FN tools_ext_reset
    PROLOGUE
    call ai_ext
    mov rbx, rax
    xor r12d, r12d
1:  cmp r12, [rbx + AX_tools + VEC_len]
    jae 2f
    imul r13, r12, TLX_SIZE
    add r13, [rbx + AX_tools + VEC_ptr]
    inc r12
    mov rdi, [r13 + TLX_name]
    call mem_free
    mov rdi, [r13 + TLX_title]
    call mem_free
    mov rdi, [r13 + TLX_desc]
    call mem_free
    mov rdi, [r13 + TLX_input]
    call mem_free
    jmp 1b
2:  lea rdi, [rbx + AX_tools]
    call vec_free
    EPILOGUE

# ---------------- listing ----------------

# usable(ext) -> eax 1 when its tools are offered: installed, not turned off, not failed
usable:
    call ext_is_visible
    test eax, eax
    jz 9f
    xor eax, eax
    cmp dword ptr [rdi + EXT_status], ES_DISABLED
    je 9f
    cmp dword ptr [rdi + EXT_status], ES_FAILED
    je 9f
    inc eax
9:  ret

# FN tools_list(sb): N LF, then TOOL FLAGS TITLE_LEN DESC_LEN INPUT_LEN LF and the three texts, for
#   rhun's tools and those of every usable extension
FN tools_list
    PROLOGUE 16
    mov r15, rdi
    # count
    mov ebx, TBT_COUNT
    xor r12d, r12d
1:  cmp r12, [rip + g_exts + VEC_len]
    jae 2f
    imul rdi, r12, EXT_SIZE
    add rdi, [rip + g_exts + VEC_ptr]
    inc r12
    mov r13, rdi
    call usable
    test eax, eax
    jz 1b
    mov rdi, r13
    call ai_ext
    add rbx, [rax + AX_tools + VEC_len]
    jmp 1b
2:  mov rdi, r15
    mov rsi, rbx
    call sb_push_u64
    mov rdi, r15
    mov esi, 10
    call sb_push_byte
    # rhun's
    xor r12d, r12d
3:  cmp r12, TBT_COUNT
    jae 4f
    imul r13, r12, 40
    lea rax, [rip + builtins]
    add r13, rax
    inc r12
    mov rdi, r15
    lea rsi, [rip + .Lrhun_dot]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [r13]
    call sb_push_cstr
    mov rdi, r15
    mov rsi, [r13 + 32]         # ro
    mov rdx, [r13 + 8]
    mov rcx, [r13 + 16]
    mov r8, [r13 + 24]
    call list_rest
    jmp 3b
4:  # the extensions'
    xor r12d, r12d
5:  cmp r12, [rip + g_exts + VEC_len]
    jae 9f
    imul rdi, r12, EXT_SIZE
    add rdi, [rip + g_exts + VEC_ptr]
    inc r12
    mov r13, rdi
    call usable
    test eax, eax
    jz 5b
    mov rdi, r13
    call ai_ext
    mov r14, rax
    xor ebx, ebx
6:  cmp rbx, [r14 + AX_tools + VEC_len]
    jae 5b
    imul rax, rbx, TLX_SIZE
    add rax, [r14 + AX_tools + VEC_ptr]
    mov [rsp], rax
    inc rbx
    mov rdi, r13
    call ext_full_name
    mov rdi, r15
    mov rsi, rax
    call sb_push_cstr
    mov rdi, r15
    mov esi, '.'
    call sb_push_byte
    mov rax, [rsp]
    mov rdi, r15
    mov rsi, [rax + TLX_name]
    call sb_push_cstr
    mov rax, [rsp]
    mov rdi, r15
    mov esi, [rax + TLX_ro]
    mov rdx, [rax + TLX_title]
    mov rcx, [rax + TLX_desc]
    mov r8, [rax + TLX_input]
    call list_rest
    jmp 6b
9:  EPILOGUE

# list_rest(sb, ro, title, desc, input): " FLAGS T D I" LF and the texts
list_rest:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rdx
    mov [rsp + 8], rcx
    mov [rsp + 16], r8
    lea rax, [rip + .Lflag_rw]
    lea rcx, [rip + .Lflag_ro]
    test esi, esi
    cmovnz rax, rcx
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    xor r12d, r12d
1:  cmp r12, 3
    jae 2f
    mov rdi, [rsp + r12*8]
    xor eax, eax
    test rdi, rdi
    jz 11f
    call strlen
11: mov rdi, rbx
    mov esi, ' '
    push rax
    push rax
    call sb_push_byte
    pop rsi
    pop rsi
    mov rdi, rbx
    call sb_push_u64
    inc r12
    jmp 1b
2:  mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    xor r12d, r12d
3:  cmp r12, 3
    jae 9f
    mov rsi, [rsp + r12*8]
    inc r12
    test rsi, rsi
    jz 3b
    mov rdi, rbx
    call sb_push_cstr
    jmp 3b
9:  EPILOGUE

# ---------------- calling ----------------

# FN tools_call(caller, id, tool ptr, len, input, input len): a tool-call request; it is answered
#   now or later through extproto_ai_answer (ok ID LEN + output, or error ID ...)
FN tools_call
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], rsi
    mov r12, rdx
    mov r13, rcx
    mov [rsp + 8], r8
    mov [rsp + 16], r9
    cmp qword ptr [rip + calls + VEC_len], TOOL_CALLS_MAX
    jae .Ltc_busy
    mov edi, TCL_SIZE
    call mem_alloc
    mov r15, rax
    mov [r15 + TCL_caller], rbx
    mov rax, [rsp]
    mov [r15 + TCL_creq], rax
    mov rdi, r12
    mov rsi, r13
    call ai_dup
    mov [r15 + TCL_name], rax
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call ai_dup
    mov [r15 + TCL_input], rax
    mov rax, [rsp + 16]
    mov [r15 + TCL_inlen], rax
    call time_ms
    mov [r15 + TCL_since], rax
    lea rdi, [rip + calls]
    mov esi, 8
    call vec_push
    mov [rax], r15
    # which tool: rhun.NAME, or OWNER/NAME.TOOL
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lrhun_dot]
    mov ecx, 5
    call str_starts
    test eax, eax
    jz 3f
    xor r14d, r14d
1:  cmp r14, TBT_COUNT
    jae .Ltc_none
    imul rax, r14, 40
    lea rcx, [rip + builtins]
    lea rdi, [r12 + 5]
    lea rsi, [r13 - 5]
    mov rdx, [rcx + rax]
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r14
    jmp 1b
2:  mov [r15 + TCL_tool], r14
    imul rax, r14, 40
    lea rcx, [rip + builtins]
    mov rax, [rcx + rax + 32]
    mov [r15 + TCL_ro], eax
    cmp r14, TBT_PROPOSE
    je 21f
    cmp r14, TBT_RUN
    jne 4f
21: mov dword ptr [r15 + TCL_ro], 1  # the review and the prompt are the user's confirmation
    jmp 4f
3:  mov rdi, r15
    call find_owner
    test rax, rax
    jz .Ltc_none
4:  # a tool that changes anything waits for the user, unless allowed for this session
    cmp dword ptr [r15 + TCL_ro], 0
    jne 5f
    mov rdi, r15
    call granted
    test eax, eax
    jnz 5f
    mov dword ptr [r15 + TCL_state], TCS_CONFIRM
    call tools_tick
    EPILOGUE
5:  mov rdi, r15
    call dispatch
    EPILOGUE
.Ltc_none:
    mov rdi, r15
    lea rsi, [rip + .Le_no_tool]
    call answer_error
    EPILOGUE
.Ltc_busy:
    mov rdi, rbx
    mov rsi, [rsp]
    lea rdx, [rip + .Le_busy_calls]
    call answer_error_direct
    EPILOGUE

# find_owner(CL*) -> rax the TL of OWNER/NAME.TOOL (TCL_owner, TCL_tool, TCL_ro set), or 0
find_owner:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + TCL_name]
    mov rdi, r12
    call strlen
    mov r13, rax
    # the last dot splits the extension from the tool
    mov rcx, r13
1:  test rcx, rcx
    jz 8f
    dec rcx
    cmp byte ptr [r12 + rcx], '.'
    jne 1b
    mov r14, rcx                # dot
    xor r15d, r15d
2:  cmp r15, [rip + g_exts + VEC_len]
    jae 8f
    imul rdi, r15, EXT_SIZE
    add rdi, [rip + g_exts + VEC_ptr]
    inc r15
    push rdi
    push rdi
    call usable
    pop rdi
    pop rdi
    test eax, eax
    jz 2b
    push rdi
    push rdi
    call ext_full_name
    mov rdx, rax
    mov rdi, r12
    mov rsi, r14
    call str_eq_cstr
    pop rdi
    pop rdi
    test eax, eax
    jz 2b
    mov [rbx + TCL_owner], rdi
    call ai_ext
    mov rdi, rax
    lea rsi, [r12 + r14 + 1]
    mov rdx, r13
    sub rdx, r14
    dec rdx
    call tool_find
    test rax, rax
    jz 8f
    mov [rbx + TCL_tool], rax
    mov ecx, [rax + TLX_ro]
    mov [rbx + TCL_ro], ecx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# granted(CL*) -> eax 1 when the user allowed this caller this tool for the session
granted:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + grants + VEC_len]
    jae 8f
    mov rax, [rip + grants + VEC_ptr]
    shl r12, 4
    mov rcx, [rax + r12]
    mov rdi, [rax + r12 + 8]
    shr r12, 4
    inc r12
    cmp rcx, [rbx + TCL_caller]
    jne 1b
    mov rsi, [rbx + TCL_name]
    call strcmp_eq
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# dispatch(CL*): the call runs: a built-in now, an extension's tool goes to its owner
dispatch:
    PROLOGUE
    mov rbx, rdi
    cmp qword ptr [rbx + TCL_owner], 0
    jne 1f
    mov rdi, rbx
    call run_builtin
    EPILOGUE
1:  mov r12, [rbx + TCL_owner]
    mov eax, [r12 + EXT_status]
    cmp eax, ES_RUNNING
    je 3f
    cmp eax, ES_STARTING
    je 2f
    cmp eax, ES_IDLE
    je 21f
    cmp eax, ES_CRASHED
    je 21f
    mov rdi, rbx
    lea rsi, [rip + .Le_not_running]
    call answer_error
    EPILOGUE
21: mov rdi, r12
    call ext_start
2:  mov dword ptr [rbx + TCL_state], TCS_START
    call time_ms
    mov [rbx + TCL_since], rax
    EPILOGUE
3:  FEAT_TEST r12, FEAT_TOOLS
    jnz 4f
    mov rdi, rbx
    lea rsi, [rip + .Le_no_calls]
    call answer_error
    EPILOGUE
4:  # ID tool NAME CALLER LEN + input
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lv_tool]
    call sb_push_cstr
    mov rax, [rbx + TCL_tool]
    lea rdi, [rip + tmp]
    mov rsi, [rax + TLX_name]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, ' '
    call sb_push_byte
    mov rdi, [rbx + TCL_caller]
    call ext_full_name
    lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, [rbx + TCL_inlen]
    call sb_push_u64
    mov rdi, r12
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    mov rcx, [rbx + TCL_input]
    mov r8, [rbx + TCL_inlen]
    call extproto_ai_request
    test rax, rax
    jz 8f
    mov [rbx + TCL_oreq], rax
    mov dword ptr [rbx + TCL_state], TCS_OWNER
    mov rdi, r12                # counted with the language queries (query.s)
    mov rsi, rax
    mov edx, PK_TOOL
    mov ecx, QO_AI
    call query_track
    EPILOGUE
8:  mov rdi, rbx
    lea rsi, [rip + .Le_not_running]
    call answer_error
    EPILOGUE

# FN tools_owner_ready(ext): the extension said hello: the calls that waited for it go out
FN tools_owner_ready
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + calls + VEC_len]
    jae 9f
    mov rax, [rip + calls + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    cmp [r13 + TCL_owner], rbx
    jne 1b
    cmp dword ptr [r13 + TCL_state], TCS_START
    jne 1b
    mov rdi, r13
    call dispatch
    xor r12d, r12d              # dispatch may have answered (and removed) calls
    jmp 1b
9:  EPILOGUE

# FN tools_reply(ext, id, ok, body, len) -> eax 1 when it was an owner's answer to a tool request:
#   passed to the caller as it came (an error's code and text too)
FN tools_reply
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
    xor ecx, ecx
1:  cmp rcx, [rip + calls + VEC_len]
    jae 8f
    mov rax, [rip + calls + VEC_ptr]
    mov rdi, [rax + rcx*8]
    inc rcx
    cmp [rdi + TCL_owner], rbx
    jne 1b
    cmp dword ptr [rdi + TCL_state], TCS_OWNER
    jne 1b
    cmp [rdi + TCL_oreq], r12
    jne 1b
    test r13d, r13d
    jz 2f
    mov rsi, r14
    mov rdx, r15
    call answer_ok
    jmp 9f
2:  # "CODE TEXT" of the owner's error, as one line of at most 1000 bytes
    mov [rsp], rdi
    lea rdi, [rip + tmp]
    call sb_clear
    mov rdi, r14
    mov rsi, r15
    mov edx, 1000
    call ai_cut
    lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + tmp]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rsp]
    mov rsi, [rip + tmp + SB_ptr]
    cmp byte ptr [rsi], 0
    jne 3f
    lea rsi, [rip + .Le_tool_failed]
3:  call answer_error
9:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ---------------- answers ----------------

# answer_ok(CL*, ptr, len): "ok ID LEN" and the output to the caller; the call is done
answer_ok:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + num]
    mov rsi, r13
    call fmt_u64
    mov rdi, [rbx + TCL_caller]
    mov rsi, [rbx + TCL_creq]
    lea rdx, [rip + num]
    mov rcx, rax
    mov r8, r12
    mov r9, r13
    call extproto_ai_answer
    mov rdi, rbx
    call call_done
    EPILOGUE

# answer_error(CL*, "CODE TEXT"): the call is done with an error
answer_error:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + TCL_caller]
    mov rsi, [rbx + TCL_creq]
    mov rdx, r12
    call answer_error_direct
    mov rdi, rbx
    call call_done
    EPILOGUE

# answer_error_direct(ext, id, "CODE TEXT")
answer_error_direct:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r13
    call strlen
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    xor ecx, ecx
    mov r8, r13
    mov r9, rax
    call extproto_ai_answer
    EPILOGUE

# call_done(CL*): out of the list, freed
call_done:
    PROLOGUE
    mov rbx, rdi
    xor ecx, ecx
1:  cmp rcx, [rip + calls + VEC_len]
    jae 3f
    mov rax, [rip + calls + VEC_ptr]
    cmp [rax + rcx*8], rbx
    je 2f
    inc rcx
    jmp 1b
2:  # keep the order: later calls asked later
    lea rdi, [rax + rcx*8]
    lea rsi, [rax + rcx*8 + 8]
    mov rdx, [rip + calls + VEC_len]
    sub rdx, rcx
    dec rdx
    shl rdx, 3
    call memmove
    dec qword ptr [rip + calls + VEC_len]
3:  cmp [rip + asking], rbx
    jne 4f
    mov qword ptr [rip + asking], 0
4:  mov rdi, [rbx + TCL_name]
    call mem_free
    mov rdi, [rbx + TCL_input]
    call mem_free
    mov rdi, rbx
    call mem_free
    EPILOGUE

# ---------------- the user's confirmation ----------------

# FN tools_tick(): the first call waiting for the user gets the dialog when none is open; a call
#   whose tool's extension did not start in time fails
FN tools_tick
    PROLOGUE
    cmp qword ptr [rip + ticking], 0
    jne 99f
    mov qword ptr [rip + ticking], 1
    call tick
    mov qword ptr [rip + ticking], 0
99: EPILOGUE

tick:
    PROLOGUE
    call time_ms
    mov r13, rax
    xor r12d, r12d
1:  cmp r12, [rip + calls + VEC_len]
    jae 2f
    mov rax, [rip + calls + VEC_ptr]
    mov rbx, [rax + r12*8]
    inc r12
    cmp dword ptr [rbx + TCL_state], TCS_START
    ja 1b
    mov rax, [rbx + TCL_owner]      # queued, asking or starting: its tool's extension stopped for
    test rax, rax                   # good (not a retry, which is starting again)
    jz 11f
    cmp dword ptr [rax + EXT_status], ES_STOPPED
    jb 11f
    xor r14d, r14d
    cmp dword ptr [rbx + TCL_state], TCS_ASKING
    sete r14b
    mov rdi, rbx                    # the call goes first (freed), then its dialog closes
    lea rsi, [rip + .Le_owner_gone]
    call answer_error
    test r14d, r14d
    jz 12f
    mov qword ptr [rip + asking], 0
    xor edi, edi
    call app_dialog_answer
12: xor r12d, r12d
    jmp 1b
11: cmp dword ptr [rbx + TCL_state], TCS_START
    jne 1b
    mov rax, r13
    sub rax, [rbx + TCL_since]
    cmp rax, TOOL_START_WAIT
    jb 1b
    mov rdi, rbx
    lea rsi, [rip + .Le_start_slow]
    call answer_error
    xor r12d, r12d
    jmp 1b
2:  cmp qword ptr [rip + asking], 0
    jne 9f
    call app_dialog_open
    test eax, eax
    jnz 9f
    xor r12d, r12d
3:  cmp r12, [rip + calls + VEC_len]
    jae 9f
    mov rax, [rip + calls + VEC_ptr]
    mov rbx, [rax + r12*8]
    inc r12
    cmp dword ptr [rbx + TCL_state], TCS_CONFIRM
    jne 3b
    mov rdi, rbx
    call ask
9:  EPILOGUE

# FN tools_timeout() -> ms until tools_tick should run again, or -1
FN tools_timeout
    xor ecx, ecx
1:  cmp rcx, [rip + calls + VEC_len]
    jae 8f
    mov rax, [rip + calls + VEC_ptr]
    mov rax, [rax + rcx*8]
    inc rcx
    cmp dword ptr [rax + TCL_state], TCS_START
    je 2f
    cmp dword ptr [rax + TCL_state], TCS_CONFIRM
    jne 1b
    cmp qword ptr [rip + asking], 0
    jne 1b
2:  mov eax, 100
    ret
8:  mov eax, -1
    ret

# ask(CL*): "Allow CALLER to use TOOL?", the tool's title and the start of the input
ask:
    PROLOGUE
    mov rbx, rdi
    mov [rip + asking], rbx
    mov dword ptr [rbx + TCL_state], TCS_ASKING
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lq_allow]
    call sb_push_cstr
    mov rdi, [rbx + TCL_caller]
    call ext_title
    lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lq_use]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov rsi, [rbx + TCL_name]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, '?'
    call sb_push_byte
    lea rdi, [rip + dlg_q]
    mov esi, 250
    call copy_tmp
    # the line: the tool's title, then the input's first line
    lea rdi, [rip + tmp]
    call sb_clear
    mov rax, [rbx + TCL_owner]
    test rax, rax
    jz 1f
    mov rax, [rbx + TCL_tool]
    mov rsi, [rax + TLX_title]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + tmp]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    lea rsi, [rip + .Lcolon]
    call sb_push_cstr
1:  mov rdi, [rbx + TCL_input]
    mov rsi, [rbx + TCL_inlen]
    xor ecx, ecx
2:  cmp rcx, rsi
    jae 3f
    cmp byte ptr [rdi + rcx], 10
    je 3f
    inc rcx
    jmp 2b
3:  mov rsi, rcx
    mov edx, 200
    call ai_cut
    lea rdi, [rip + tmp]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + dlg_line]
    mov esi, 500
    call copy_tmp
    lea rdi, [rip + dlg_q]
    lea rsi, [rip + dlg_line]
    lea rdx, [rip + .Lb_once]
    lea rcx, [rip + choose_once]
    call app_confirm
    lea rdi, [rip + .Lb_session]
    lea rsi, [rip + choose_session]
    lea rdx, [rip + .Lb_deny]
    call app_confirm_alt
    lea rdi, [rip + choose_deny]
    call app_confirm_cancel
    EPILOGUE

# copy_tmp(dst, max): tmp as a cstr, cut at a character boundary, controls as spaces
copy_tmp:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rip + tmp + SB_ptr]
    mov rsi, [rip + tmp + SB_len]
    mov rdx, r12
    call ai_cut
    mov r13, rdx
    mov rdi, rbx
    mov rsi, rax
    call memcpy
    mov byte ptr [rbx + r13], 0
    xor ecx, ecx
1:  cmp rcx, r13
    jae 9f
    cmp byte ptr [rbx + rcx], 32
    jae 2f
    mov byte ptr [rbx + rcx], ' '
2:  inc rcx
    jmp 1b
9:  EPILOGUE

# choose_once(), choose_session(), choose_deny(): the dialog's buttons
FN tools_choose_once
choose_once:
    PROLOGUE
    mov rbx, [rip + asking]
    test rbx, rbx
    jz 9f
    mov qword ptr [rip + asking], 0
    mov rdi, rbx
    call dispatch
9:  call tools_tick
    EPILOGUE

FN tools_choose_session
choose_session:
    PROLOGUE
    mov rbx, [rip + asking]
    test rbx, rbx
    jz 9f
    mov qword ptr [rip + asking], 0
    lea rdi, [rip + grants]
    mov esi, 16
    call vec_push
    mov rcx, [rbx + TCL_caller]
    mov [rax], rcx
    mov r12, rax
    mov rdi, [rbx + TCL_name]
    call dup_cstr
    mov [r12 + 8], rax
    mov rdi, rbx
    call dispatch
    # what else this caller asked of this tool is allowed now too
    xor r12d, r12d
1:  cmp r12, [rip + calls + VEC_len]
    jae 9f
    mov rax, [rip + calls + VEC_ptr]
    mov rbx, [rax + r12*8]
    inc r12
    cmp dword ptr [rbx + TCL_state], TCS_CONFIRM
    jne 1b
    mov rdi, rbx
    call granted
    test eax, eax
    jz 1b
    mov rdi, rbx
    call dispatch
    xor r12d, r12d
    jmp 1b
9:  call tools_tick
    EPILOGUE

FN tools_choose_deny
choose_deny:
    PROLOGUE
    mov rbx, [rip + asking]
    test rbx, rbx
    jz 9f
    mov qword ptr [rip + asking], 0
    mov rdi, rbx
    lea rsi, [rip + .Le_denied]
    call answer_error
9:  call tools_tick
    EPILOGUE

# FN tools_asking() -> rax the CL the dialog asks about, or 0
FN tools_asking
    mov rax, [rip + asking]
    ret

# ---------------- extensions stopping, calls withdrawn ----------------

# FN tools_ext_gone(ext): an extension stopped: its own calls end (the owners hear 0 cancel), and
#   calls to its tools fail
FN tools_ext_gone
    PROLOGUE
    mov rbx, rdi
1:  xor r12d, r12d
2:  cmp r12, [rip + calls + VEC_len]
    jae 9f
    mov rax, [rip + calls + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    cmp [r13 + TCL_caller], rbx
    jne 3f
    mov rdi, r13
    call withdraw
    jmp 1b
3:  cmp [r13 + TCL_owner], rbx    # a call sent to it fails; calls still queued or waiting for
    jne 2b                          # its start wait: an exit may be a retry (confinement falls
    cmp dword ptr [r13 + TCL_state], TCS_OWNER  # back to unconfined); tools_tick fails them when
    jne 2b                          # the extension stays stopped
    mov rdi, r13
    lea rsi, [rip + .Le_owner_gone]
    call answer_error
    jmp 1b
9:  EPILOGUE

# withdraw(CL*): the caller no longer wants it: nothing is answered
withdraw:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + TCL_state], TCS_OWNER
    jne 1f
    mov rdi, [rbx + TCL_owner]   # 0 cancel ID to the owner
    mov rsi, [rbx + TCL_oreq]
    call query_withdraw
1:  cmp dword ptr [rbx + TCL_state], TCS_REVIEW
    jne 2f
    mov rdi, [rbx + TCL_oreq]    # the proposal it waits for stays for the user
    call review_by_id
    test rax, rax
    jz 2f
    mov rdi, rax
    call review_withdraw_waiter
2:  xor r12d, r12d
    cmp dword ptr [rbx + TCL_state], TCS_ASKING
    sete r12b
    mov rdi, rbx                # the call goes first (freed), then its dialog closes
    call call_done
    test r12d, r12d
    jz 3f
    mov qword ptr [rip + asking], 0
    xor edi, edi
    call app_dialog_answer
3:  EPILOGUE

# FN tools_cancel(ext, id) -> eax 1 when it was one of its tool calls: answered cancelled
FN tools_cancel
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor ecx, ecx
1:  cmp rcx, [rip + calls + VEC_len]
    jae 8f
    mov rax, [rip + calls + VEC_ptr]
    mov r13, [rax + rcx*8]
    inc rcx
    cmp [r13 + TCL_caller], rbx
    jne 1b
    cmp [r13 + TCL_creq], r12
    jne 1b
    cmp dword ptr [r13 + TCL_state], TCS_TERM
    je 8f                       # rhun's prompt answers it
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Le_cancelled]
    call answer_error_direct
    mov rdi, r13
    call withdraw
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

.section .rodata
.Lk_input: .asciz ".input"
.Lk_readonly: .asciz ".readonly"
.Lrhun_dot: .asciz "rhun."
.Lflag_ro: .asciz " ro"
.Lflag_rw: .asciz " rw"
.Lv_tool: .asciz "tool "
.Lq_allow: .asciz "Allow "
.Lq_use: .asciz " to use "
.Lcolon: .asciz ": "
.Lb_once: .asciz "Allow once"
.Lb_session: .asciz "Allow for this session"
.Lb_deny: .asciz "Deny"
.Le_no_tool: .asciz "refused no such tool"
.Le_busy_calls: .asciz "busy 256 tool calls are waiting"
.Le_not_running: .asciz "refused the tool's extension is not running"
.Le_no_calls: .asciz "refused the tool's extension does not take tool calls"
.Le_start_slow: .asciz "busy the tool's extension did not start in time"
.Le_tool_failed: .asciz "refused the tool failed"
.Le_denied: .asciz "refused denied by the user"
.Le_owner_gone: .asciz "cancelled the tool's extension stopped"
.Le_cancelled: .asciz "cancelled"

.text
# ---------------- rhun's own tools ----------------

# kv_find(CL*, key cstr) -> eax 1 with kv_ptr, kv_len the key's value in the call's input: KEY VALUE
#   lines, and KEY LEN, a line feed and LEN bytes for text and edit
kv_find:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    mov rdi, [rbx + TCL_input]
    mov rsi, [rbx + TCL_inlen]
    call ai_rd_init
1:  call ai_rd_done
    test eax, eax
    jnz 8f
    call ai_rd_word
    mov r12, rax
    mov r13, rdx
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lk_text]
    call str_eq_cstr
    mov r14d, eax
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lk_edit]
    call str_eq_cstr
    or r14d, eax
    jz 3f
    call ai_rd_num              # text LEN, edit LEN
    test edx, edx
    jz 8f
    mov r15, rax
    call ai_rd_eol
    test eax, eax
    jz 8f
    mov rdi, r15
    call ai_rd_take
    test rax, rax
    jz 8f
    mov rdx, r15
    jmp 4f
3:  call ai_rd_line             # KEY VALUE: the rest of the line
    test rax, rax
    jnz 4f
    call ai_rd_pos              # the last line may lack its LF
    mov rdx, [rbx + TCL_input]
    add rdx, [rbx + TCL_inlen]
    sub rdx, rax
    push rax
    push rdx
    mov rdi, rdx
    call ai_rd_take
    pop rdx
    pop rax
4:  mov [rip + kv_ptr], rax
    mov [rip + kv_len], rdx
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp]
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# kv_num(CL*, key, default) -> rax the key's number, or the default
kv_num:
    PROLOGUE
    mov rbx, rdx
    call kv_find
    test eax, eax
    jz 8f
    mov rdi, [rip + kv_ptr]
    mov rsi, [rip + kv_len]
    call trim
    mov rdi, rax
    mov rsi, rdx
    mov r12, rdx
    call parse_u64
    cmp rdx, r12
    jne 8f
    test r12, r12
    jz 8f
    EPILOGUE
8:  mov rax, rbx
    EPILOGUE

# needs(CL*, bit) -> eax 1 when the caller has it, else 0 after answering needs
needs:
    PROLOGUE
    mov rbx, rdi
    mov rax, [rbx + TCL_caller]
    test [rax + EXT_needs], esi
    jnz 1f
    lea rax, [rip + .Le_needs_read]
    cmp esi, NEEDS_TERMINAL
    jne 2f
    lea rax, [rip + .Le_needs_term]
2:  mov rdi, rbx
    mov rsi, rax
    call answer_error
    xor eax, eax
    EPILOGUE
1:  mov eax, 1
    EPILOGUE

# run_builtin(CL*)
run_builtin:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + out]
    call sb_clear
    mov rax, [rbx + TCL_tool]
    lea rcx, [rip + builtin_fns]
    mov rdi, rbx
    call [rcx + rax*8]
    EPILOGUE

# shown(doc) -> eax 1 for a text document a tool reports (not a diff or Review view)
shown:
    xor eax, eax
    test rdi, rdi
    jz 9f
    cmp qword ptr [rdi + DOC_diff], 0
    jne 9f
    inc eax
9:  ret

# rhun.editors: DOC DIRTY LANG PATH per open document, then active DOC
bt_editors:
    PROLOGUE
    mov rbx, rdi
    mov esi, NEEDS_DOC_READ
    call needs
    test eax, eax
    jz 9f
    xor r12d, r12d
1:  cmp r12, [rip + g_tabs + VEC_len]
    jae 3f
    mov rdi, r12
    inc r12
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 1b
    mov r13, [rax + TAB_doc]
    mov rdi, r13
    call shown
    test eax, eax
    jz 1b
    lea rdi, [rip + out]
    mov rsi, [r13 + DOC_id]
    call sb_push_u64
    mov rdi, r13
    call doc_dirty
    lea esi, [rax + '0']
    push rsi
    push rsi
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    pop rsi
    pop rsi
    lea rdi, [rip + out]
    call sb_push_byte
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, r13
    call doc_language
    test rax, rax
    jz 2f
    mov rdi, [rax + GR_name]
    call push_word
    jmp 21f
2:  lea rdi, [rip + out]
    mov esi, '-'
    call sb_push_byte
21: lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, r13
    call doc_ref
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    jmp 1b
3:  lea rdi, [rip + out]
    lea rsi, [rip + .Lactive]
    call sb_push_cstr
    xor esi, esi
    mov rdi, [rip + g_doc]
    call shown
    test eax, eax
    jz 4f
    mov rax, [rip + g_doc]
    mov rsi, [rax + DOC_id]
4:  lea rdi, [rip + out]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    call answer_out
9:  EPILOGUE

# push_word(cstr): out gets it with each space as an underscore
push_word:
    PROLOGUE
    mov rbx, rdi
1:  movzx esi, byte ptr [rbx]
    test esi, esi
    jz 9f
    cmp esi, ' '
    jne 2f
    mov esi, '_'
2:  lea rdi, [rip + out]
    call sb_push_byte
    inc rbx
    jmp 1b
9:  EPILOGUE

# doc_ref(doc): out gets its path, or - for an untitled document
doc_ref:
    mov rsi, [rdi + DOC_path]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Ldash]
1:  lea rdi, [rip + out]
    jmp sb_push_cstr

# answer_out(CL*): out is the answer
answer_out:
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    jmp answer_ok

# pos_lc(doc, pos): out gets "LINE COL" of a byte position
pos_lc:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call doc_line_of
    mov r13, rax
    lea rsi, [rax + 1]
    lea rdi, [rip + out]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    call doc_line_start
    mov rsi, r12
    sub rsi, rax
    inc rsi
    lea rdi, [rip + out]
    call sb_push_u64
    EPILOGUE

# rhun.selection: DOC L1 C1 L2 C2, a line feed, the selected text
bt_selection:
    PROLOGUE
    mov rbx, rdi
    mov esi, NEEDS_DOC_READ
    call needs
    test eax, eax
    jz 9f
    mov r12, [rip + g_doc]
    mov rdi, r12
    call shown
    test eax, eax
    jz 8f
    lea rdi, [rip + out]
    mov rsi, [r12 + DOC_id]
    call sb_push_u64
    mov rdi, r12
    call ed_sel
    mov r13, rax
    mov r14, rdx
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, r12
    mov rsi, r13
    call pos_lc
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rdi, r12
    mov rsi, r14
    call pos_lc
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    sub rdx, r13
    call doc_range
    lea rdi, [rip + out]
    mov rsi, rax
    mov rdx, r14
    sub rdx, r13
    call sb_push
    mov rdi, rbx
    call answer_out
    EPILOGUE
8:  mov rdi, rbx
    lea rsi, [rip + .Le_no_active]
    call answer_error
9:  EPILOGUE

# target(CL*) -> rax the document the input names (path or doc), or 1 with rdx the file's text read
#   from disk (owned), or 0 after answering why not
target:
    PROLOGUE 16
    mov rbx, rdi
    mov rdi, rbx
    lea rsi, [rip + .Lk_doc]
    call kv_find
    test eax, eax
    jz 2f
    mov rdi, [rip + kv_ptr]
    mov rsi, [rip + kv_len]
    call trim
    mov r12, rdx
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    cmp rdx, r12
    jne .Ltg_syntax
    mov rdi, rax
    call extproto_doc
    mov rdi, rax
    push rax
    push rax
    call shown
    pop rcx
    pop rcx
    test eax, eax
    jz .Ltg_nodoc
    mov rax, rcx
    EPILOGUE
2:  mov rdi, rbx
    call path_arg
    test rax, rax
    jz 9f
    mov r12, rax                # the path (owned)
    mov rdi, r12
    call app_find_tab
    test rax, rax
    js 3f
    mov rdi, rax
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne .Ltg_nofile_free
    mov r13, [rax + TAB_doc]
    mov rdi, r12
    call mem_free
    mov rax, r13
    EPILOGUE
3:  mov rdi, r12
    call vfs_type
    cmp eax, 0x8000
    jne .Ltg_nofile_free
    mov rdi, [rbx + TCL_caller]
    mov rsi, r12
    call ext_open_path
    mov r13, rax
    mov rdi, r12
    call mem_free
    test r13, r13
    jz .Ltg_needs
    mov rdi, r13
    call app_find_tab           # open under its real path
    test rax, rax
    js 4f
    mov rdi, rax
    call tab_at
    mov r14, [rax + TAB_doc]
    mov rdi, r13
    call mem_free
    mov rax, r14
    EPILOGUE
4:  mov rdi, r13
    call review_read_text
    mov r14, rax
    mov [rsp], rdx
    mov rdi, r13
    call mem_free
    test r14, r14
    jz .Ltg_unreadable
    mov eax, 1
    mov rdx, r14
    mov rcx, [rsp]              # its length
    EPILOGUE
.Ltg_syntax:
    mov rdi, rbx
    lea rsi, [rip + .Le_syntax]
    call answer_error
    xor eax, eax
    EPILOGUE
.Ltg_nodoc:
    mov rdi, rbx
    lea rsi, [rip + .Le_nodoc]
    call answer_error
    xor eax, eax
    EPILOGUE
.Ltg_nofile_free:
    mov rdi, r12
    call mem_free
    mov rdi, rbx
    lea rsi, [rip + .Le_nofile]
    call answer_error
    xor eax, eax
    EPILOGUE
.Ltg_needs:
    mov rdi, rbx
    lea rsi, [rip + .Le_file_needs]
    call answer_error
    xor eax, eax
    EPILOGUE
.Ltg_unreadable:
    mov rdi, rbx
    lea rsi, [rip + .Le_unreadable]
    call answer_error
    xor eax, eax
9:  EPILOGUE

# path_arg(CL*) -> rax the input's path as an absolute cstr (owned; a relative one is inside the
#   project), or 0 after answering why not
path_arg:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_path]
    call kv_find
    test eax, eax
    jz 8f
    mov rdi, [rip + kv_ptr]
    mov rsi, [rip + kv_len]
    call trim
    test rdx, rdx
    jz 8f
    cmp rdx, 4096
    ja 8f
    mov r12, rax
    mov r13, rdx
    lea rdi, [rip + tmp]
    call sb_clear
    PATH_ABSOLUTE r12, 1f
    mov rsi, [rip + g_project]
    test rsi, rsi
    jz 7f
    lea rdi, [rip + tmp]
    call sb_push_cstr
    lea rdi, [rip + tmp]
    mov esi, '/'
    call sb_push_byte
1:  lea rdi, [rip + tmp]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, [rip + tmp + SB_ptr]
    mov rsi, [rip + tmp + SB_len]
    call ai_dup
    mov r12, rax
    mov rdi, rax
    call strlen
    cmp rax, r13
    jb 6f                       # a NUL in it
    mov rax, r12
    EPILOGUE
6:  mov rdi, r12
    call mem_free
7:  mov rdi, rbx
    lea rsi, [rip + .Le_nofile]
    call answer_error
    xor eax, eax
    EPILOGUE
8:  mov rdi, rbx
    lea rsi, [rip + .Le_syntax]
    call answer_error
    xor eax, eax
    EPILOGUE

# rhun.read: the text of a document (unsaved changes included) or a file; from and to are lines
bt_read:
    PROLOGUE 32
    mov rbx, rdi
    mov esi, NEEDS_DOC_READ
    call needs
    test eax, eax
    jz 9f
    mov rdi, rbx
    call target
    test rax, rax
    jz 9f
    cmp rax, 1
    je 1f
    mov rdi, rax
    call doc_text_copy
1:  mov [rsp], rdx              # the text (owned): a document's copy, or the file
    mov [rsp + 8], rcx
    cmp rax, 1
    je 2f
    mov [rsp], rax
    mov [rsp + 8], rdx
2:  mov rdi, rbx
    lea rsi, [rip + .Lk_from]
    mov edx, 1
    call kv_num
    mov r12, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_to]
    mov rdx, -1
    call kv_num
    mov r13, rax
    # lines from r12 to r13, both counted from 1
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    xor ecx, ecx                # offset
    mov r8, 1                   # line
    mov r14, -1                 # start
    xor r15d, r15d
3:  cmp r8, r12
    jb 31f
    test r14, r14
    jns 31f
    mov r14, rcx
31: cmp r8, r13
    ja 5f
    cmp rcx, rsi
    jae 5f
    cmp byte ptr [rdi + rcx], 10
    jne 4f
    inc r8
4:  inc rcx
    jmp 3b
5:  test r14, r14
    jns 6f
    mov r14, rcx
6:  lea rdi, [rip + out]
    mov rsi, [rsp]
    add rsi, r14
    mov rdx, rcx
    sub rdx, r14
    call sb_push
    mov rdi, [rsp]
    call mem_free
    mov rdi, rbx
    call answer_out
9:  EPILOGUE

# rhun.diagnostics: PATH L1 C1 L2 C2 SEVERITY OWNER/NAME MESSAGE per mark on an open document
bt_diagnostics:
    PROLOGUE 16
    mov rbx, rdi
    mov esi, NEEDS_DOC_READ
    call needs
    test eax, eax
    jz 9f
    mov qword ptr [rsp], 0      # only this path, when given
    mov rdi, rbx
    lea rsi, [rip + .Lk_path]
    call kv_find
    test eax, eax
    jz 1f
    mov rdi, rbx
    call path_arg
    test rax, rax
    jz 9f
    mov [rsp], rax
1:  xor r12d, r12d
2:  cmp r12, [rip + g_tabs + VEC_len]
    jae 8f
    mov rdi, r12
    inc r12
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne 2b
    mov r13, [rax + TAB_doc]
    mov rdi, r13
    call shown
    test eax, eax
    jz 2b
    mov rdi, [rsp]
    test rdi, rdi
    jz 3f
    mov rsi, [r13 + DOC_path]
    test rsi, rsi
    jz 2b
    call strcmp_eq
    test eax, eax
    jz 2b
3:  mov r14, [r13 + DOC_xmarks]
    test r14, r14
    jz 2b
    xor r15d, r15d
4:  cmp r15, [r14 + VEC_len]
    jae 2b
    imul rax, r15, MK_SIZE
    add rax, [r14 + VEC_ptr]
    mov [rsp + 8], rax
    inc r15
    mov rdi, r13
    call doc_ref
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rax, [rsp + 8]
    mov rdi, r13
    mov rsi, [rax + MK_start]
    call pos_lc
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rax, [rsp + 8]
    mov rdi, r13
    mov rsi, [rax + MK_end]
    call pos_lc
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rax, [rsp + 8]
    mov eax, [rax + MK_sev]
    and eax, 3
    lea rcx, [rip + sev_words]
    lea rdi, [rip + out]
    mov rsi, [rcx + rax*8]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rax, [rsp + 8]
    mov rdi, [rax + MK_owner]
    call ext_full_name
    lea rdi, [rip + out]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    mov rax, [rsp + 8]
    mov rdi, [rax + MK_msg]     # as shown: cut at MARK_MSG_MAX (phase 4 task 9: marks keep it whole)
    call extmarks_shown
    lea rdi, [rip + out]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    jmp 4b
8:  mov rdi, [rsp]
    call mem_free
    mov rdi, rbx
    call answer_out
9:  EPILOGUE

# rhun.open: a file in a tab at a position (path, line, col) -> DOC
bt_open:
    PROLOGUE 16
    mov rbx, rdi
    mov rdi, rbx
    call path_arg
    test rax, rax
    jz 9f
    mov r12, rax
    mov rdi, r12
    call vfs_type
    cmp eax, 0x8000
    jne .Lbo_nofile
    mov rdi, [rbx + TCL_caller]
    mov rsi, r12
    call ext_open_path
    mov r13, rax
    mov rdi, r12
    call mem_free
    test r13, r13
    jz .Lbo_needs
    mov rdi, r13
    call app_open_file
    mov r14, rax
    mov rdi, r13
    call mem_free
    test r14, r14
    js .Lbo_nofile2
    mov rdi, r14
    call tab_at
    cmp qword ptr [rax + TAB_kind], TAB_DOC
    jne .Lbo_nofile2
    mov r12, [rax + TAB_doc]
    mov rdi, rbx
    lea rsi, [rip + .Lk_line]
    xor edx, edx
    call kv_num
    mov r13, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_col]
    mov edx, 1
    call kv_num
    mov r14, rax
    test r13, r13
    jz 3f
    cmp r13, [r12 + DOC_nlines]
    jbe 1f
    mov r13, [r12 + DOC_nlines]
1:  lea rsi, [r13 - 1]
    mov rdi, r12
    call doc_line_start
    mov r15, rax
    lea rsi, [r13 - 1]
    mov rdi, r12
    call doc_line_end
    sub rax, r15
    lea rcx, [r14 - 1]
    cmp rcx, rax
    jbe 2f
    mov rcx, rax
2:  lea rsi, [r15 + rcx]
    mov rdi, r12
    xor edx, edx
    call ed_set_cursor
    mov dword ptr [rip + g_reveal], 1
3:  mov dword ptr [rip + g_dirty], 1
    lea rdi, [rip + out]
    mov rsi, [r12 + DOC_id]
    call sb_push_u64
    mov rdi, rbx
    call answer_out
9:  EPILOGUE
.Lbo_nofile:
    mov rdi, r12
    call mem_free
.Lbo_nofile2:
    mov rdi, rbx
    lea rsi, [rip + .Le_nofile]
    call answer_error
    EPILOGUE
.Lbo_needs:
    mov rdi, rbx
    lea rsi, [rip + .Le_file_needs]
    call answer_error
    EPILOGUE

# rhun.propose: a workspace edit (edit LEN), or a file's new text (path, text LEN), shown in the
#   Review tab; answered accepted N rejected M once the user decided every file
bt_propose:
    PROLOGUE 48
    mov rbx, rdi
    mov esi, NEEDS_DOC_READ
    call needs
    test eax, eax
    jz 9f
    # the proposal's head: its label
    lea rsi, [rip + .Lproposed]
    mov rdi, rbx
    push rsi
    push rsi
    lea rsi, [rip + .Lk_label]
    call kv_find
    pop rsi
    pop rsi
    mov r12, rsi
    test eax, eax
    jz 1f
    mov rdi, [rip + kv_ptr]
    mov rsi, [rip + kv_len]
    call ai_dup
    mov r12, rax
1:  mov [rsp + 32], r12
    mov rdi, r12
    call strlen
    mov r13, rax
    lea rdi, [rip + out]
    mov rsi, r13
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Lzero_lf]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    lea rax, [rip + .Lproposed]
    cmp r12, rax
    je 2f
    mov rdi, r12
    call mem_free
2:  mov rdi, rbx
    lea rsi, [rip + .Lk_edit]
    call kv_find
    test eax, eax
    jz 3f
    lea rdi, [rip + out]
    mov rsi, [rip + kv_ptr]
    mov rdx, [rip + kv_len]
    call sb_push
    jmp 6f
3:  # path and text: the whole file replaced
    mov rdi, rbx
    lea rsi, [rip + .Lk_text]
    call kv_find
    test eax, eax
    jz .Lbp_syntax
    mov rax, [rip + kv_ptr]
    mov [rsp], rax
    mov rax, [rip + kv_len]
    mov [rsp + 8], rax
    mov rdi, rbx
    call target
    test rax, rax
    jz 9f
    cmp rax, 1
    je 4f
    mov r14, rax                # an open document: #DOC at its version
    mov rdi, rax
    call doc_text_copy
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov esi, '#'
    call sb_push_byte
    lea rdi, [rip + tmp]
    mov rsi, [r14 + DOC_id]
    call sb_push_u64
    mov r15, [r14 + DOC_version]
    jmp 5f
4:  mov [rsp + 16], rdx         # a file: its path, made from the disk
    mov [rsp + 24], rcx
    mov rdi, rbx
    call path_arg
    test rax, rax
    jz 9f
    mov r14, rax
    lea rdi, [rip + tmp]
    call sb_clear
    lea rdi, [rip + tmp]
    mov rsi, r14
    call sb_push_cstr
    mov rdi, r14
    call mem_free
    mov r15, -1
5:  # 1 LF, PATH_LEN VERSION 1 LF and the path, 1 1 L C LEN LF and the text
    lea rdi, [rip + out]
    lea rsi, [rip + .Lone_lf]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, [rip + tmp + SB_len]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    cmp r15, -1
    jne 51f
    lea rdi, [rip + out]
    mov esi, '-'
    call sb_push_byte
    jmp 52f
51: lea rdi, [rip + out]
    mov rsi, r15
    call sb_push_u64
52: lea rdi, [rip + out]
    lea rsi, [rip + .Lone_edit]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, [rip + tmp + SB_ptr]
    mov rdx, [rip + tmp + SB_len]
    call sb_push
    # the end of the old text, as LINE COL
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    mov r8, 1
    xor r9d, r9d                # its last line's start
    xor ecx, ecx
53: cmp rcx, rsi
    jae 54f
    cmp byte ptr [rdi + rcx], 10
    jne 531f
    inc r8
    lea r9, [rcx + 1]
531: inc rcx
    jmp 53b
54: sub rsi, r9
    inc rsi
    mov [rsp + 40], rsi
    mov r14, r8                 # the line, past the calls below
    lea rdi, [rip + out]
    lea rsi, [rip + .Lone_one]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, r14
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [rsp + 40]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [rsp + 8]
    call sb_push_u64
    lea rdi, [rip + out]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + out]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
    mov rdi, [rsp + 16]
    call mem_free
6:  mov rdi, [rbx + TCL_caller]
    mov rsi, [rip + out + SB_ptr]
    mov rdx, [rip + out + SB_len]
    xor ecx, ecx
    call review_propose
    test rax, rax
    jnz .Lbp_error
    mov [rbx + TCL_oreq], rdx    # the proposal it waits for
    mov dword ptr [rbx + TCL_state], TCS_REVIEW
    mov rdi, rdx
    call review_by_id
    mov rdi, rax
    mov rsi, rbx
    call review_set_waiter
    EPILOGUE
.Lbp_error:
    mov rdi, rbx
    mov rsi, rax
    call answer_error
    EPILOGUE
.Lbp_syntax:
    mov rdi, rbx
    lea rsi, [rip + .Le_syntax]
    call answer_error
9:  EPILOGUE

# FN tools_propose_done(CL*, accepted, rejected): the review a rhun.propose call waited for is done
FN tools_propose_done
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + out]
    call sb_clear
    lea rdi, [rip + out]
    lea rsi, [rip + .Laccepted]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, r12
    call sb_push_u64
    lea rdi, [rip + out]
    lea rsi, [rip + .Lrejected]
    call sb_push_cstr
    lea rdi, [rip + out]
    mov rsi, r13
    call sb_push_u64
    mov rdi, rbx
    call answer_out
    EPILOGUE

# rhun.run: the command in rhun's prompt; ok once the user pressed Enter (it went to the terminal)
bt_run:
    PROLOGUE
    mov rbx, rdi
    mov esi, NEEDS_TERMINAL
    call needs
    test eax, eax
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_command]
    call kv_find
    test eax, eax
    jz 8f
    mov rdi, [rbx + TCL_caller]
    mov rsi, [rbx + TCL_creq]
    mov rdx, [rip + kv_ptr]
    mov rcx, [rip + kv_len]
    mov r8, rbx
    call extproto_tool_term
    test rax, rax
    jnz 7f
    mov dword ptr [rbx + TCL_state], TCS_TERM
    EPILOGUE
7:  mov rdi, rbx
    mov rsi, rax
    call answer_error
    EPILOGUE
8:  mov rdi, rbx
    lea rsi, [rip + .Le_syntax]
    call answer_error
9:  EPILOGUE

# FN tools_term_done(CL*, ran): rhun.run's prompt closed: Enter ran it, anything else did not
FN tools_term_done
    PROLOGUE
    mov rbx, rdi
    test esi, esi
    jz 1f
    lea rdi, [rip + out]
    call sb_clear
    lea rdi, [rip + out]
    lea rsi, [rip + .Lok]
    call sb_push_cstr
    mov rdi, rbx
    call answer_out
    EPILOGUE
1:  mov rdi, rbx
    lea rsi, [rip + .Le_cancelled]
    call answer_error
    EPILOGUE

# ---------------- tests ----------------

# FN tools_dump(sb): the tools tools-list would give, then "call CALLER TOOL state=..." per call
FN tools_dump
    PROLOGUE
    mov rbx, rdi
    call tools_list
    xor r12d, r12d
1:  cmp r12, [rip + calls + VEC_len]
    jae 9f
    mov rax, [rip + calls + VEC_ptr]
    mov r13, [rax + r12*8]
    inc r12
    mov rdi, rbx
    lea rsi, [rip + .Ld_call]
    call sb_push_cstr
    mov rdi, [r13 + TCL_caller]
    call ext_full_name
    mov rdi, rbx
    mov rsi, rax
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, [r13 + TCL_name]
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ld_state]
    call sb_push_cstr
    mov eax, [r13 + TCL_state]
    lea rcx, [rip + state_words]
    mov rdi, rbx
    mov rsi, [rcx + rax*8]
    call sb_push_cstr
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

.section .rodata
.Lk_text: .asciz "text"
.Lk_edit: .asciz "edit"
.Lk_doc: .asciz "doc"
.Lk_path: .asciz "path"
.Lk_from: .asciz "from"
.Lk_to: .asciz "to"
.Lk_line: .asciz "line"
.Lk_col: .asciz "col"
.Lk_label: .asciz "label"
.Lk_command: .asciz "command"
.Lactive: .asciz "active "
.Ldash: .asciz "-"
.Lproposed: .asciz "Proposed edit"
.Lzero_lf: .asciz " 0\n"
.Lone_lf: .asciz "1\n"
.Lone_edit: .asciz " 1\n"
.Lone_one: .asciz "1 1 "
.Laccepted: .asciz "accepted "
.Lrejected: .asciz " rejected "
.Lok: .asciz "ok"
.Ld_call: .asciz "call "
.Ld_state: .asciz " state="
.Le_needs_read: .asciz "needs documents=read"
.Le_needs_term: .asciz "needs terminal=yes"
.Le_no_active: .asciz "nodoc no document is active"
.Le_syntax: .asciz "syntax the input cannot be read"
.Le_nodoc: .asciz "nodoc no such document"
.Le_nofile: .asciz "nofile no such file"
.Le_file_needs: .asciz "needs file=read"
.Le_unreadable: .asciz "nofile the file cannot be read as text of at most 4 MB"
.Ls_error: .asciz "error"
.Ls_warning: .asciz "warning"
.Ls_info: .asciz "info"
.Ls_hint: .asciz "hint"
.Lw_confirm: .asciz "confirm"
.Lw_asking: .asciz "asking"
.Lw_start: .asciz "starting"
.Lw_owner: .asciz "sent"
.Lw_review: .asciz "review"
.Lw_term: .asciz "prompt"
# built-ins: name, title, description, input, readonly
.Lbn_editors: .asciz "editors"
.Lbt_editors: .asciz "Open editors"
.Lbd_editors: .asciz "The documents open in rhun: DOC DIRTY LANG PATH per line (PATH - for an untitled one), then active DOC"
.Lbn_selection: .asciz "selection"
.Lbt_selection: .asciz "Selection"
.Lbd_selection: .asciz "The active document's selection: DOC L1 C1 L2 C2, a line feed, then the selected text"
.Lbn_read: .asciz "read"
.Lbt_read: .asciz "Read"
.Lbd_read: .asciz "A document's text as rhun has it, unsaved changes included, or a file's"
.Lbi_read: .asciz "path PATH or doc DOC; from LINE and to LINE, optional"
.Lbn_diagnostics: .asciz "diagnostics"
.Lbt_diagnostics: .asciz "Diagnostics"
.Lbd_diagnostics: .asciz "Problems extensions reported in open documents: PATH L1 C1 L2 C2 SEVERITY OWNER/NAME MESSAGE per line"
.Lbi_diagnostics: .asciz "path PATH, optional"
.Lbn_open: .asciz "open"
.Lbt_open: .asciz "Open"
.Lbd_open: .asciz "Opens a file in rhun at a position; the answer is its DOC"
.Lbi_open: .asciz "path PATH; line LINE and col COL, optional"
.Lbn_propose: .asciz "propose"
.Lbt_propose: .asciz "Propose an edit"
.Lbd_propose: .asciz "Shows a change in rhun's Review tab; answers accepted N rejected M once the user decided"
.Lbi_propose: .asciz "edit LEN and a workspace edit, or path PATH and text LEN and the file's new text; label TEXT, optional"
.Lbn_run: .asciz "run"
.Lbt_run: .asciz "Run in the terminal"
.Lbd_run: .asciz "Puts a command in rhun's prompt; it runs in the terminal when the user presses Enter, and the answer is ok"
.Lbi_run: .asciz "command TEXT"
.p2align 3
builtins:
    .quad .Lbn_editors, .Lbt_editors, .Lbd_editors, 0, 1
    .quad .Lbn_selection, .Lbt_selection, .Lbd_selection, 0, 1
    .quad .Lbn_read, .Lbt_read, .Lbd_read, .Lbi_read, 1
    .quad .Lbn_diagnostics, .Lbt_diagnostics, .Lbd_diagnostics, .Lbi_diagnostics, 1
    .quad .Lbn_open, .Lbt_open, .Lbd_open, .Lbi_open, 1
    .quad .Lbn_propose, .Lbt_propose, .Lbd_propose, .Lbi_propose, 0
    .quad .Lbn_run, .Lbt_run, .Lbd_run, .Lbi_run, 0
builtin_fns: .quad bt_editors, bt_selection, bt_read, bt_diagnostics, bt_open, bt_propose, bt_run
sev_words: .quad .Ls_error, .Ls_warning, .Ls_info, .Ls_hint
state_words: .quad .Lw_confirm, .Lw_asking, .Lw_start, .Lw_owner, .Lw_review, .Lw_term
