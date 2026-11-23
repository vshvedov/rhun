# Claude Code's requests as rich cards (agentcard.s) and their answers: the driver table's DRV_reply.
#
# A permission (can_use_tool, h_can_use in agent_claude.s) becomes a card while its request is parsed
# (claude_card_build): the header per tool (the extension's renderers, webview index.js @5245117-5270700;
# SendToProject's reader `d$` @3430380), the hook's reason ("A hook says:", at most 2000 characters) and the
# reason of a safety check as the hint, then the buttons "Yes", the rule button (only with suggestions and
# without suppress_always_allow_rule) and "No", the reject field "Tell Claude what to do instead". The rule
# button's wording is the extension's (`IPn`/`NRe` @5665708, @5654300): "Yes, allow RULE for DEST", "Yes,
# allow A and B for DEST", "Yes, allow A and N more for DEST", "Yes, allow access to DIR/ for DEST", "Yes,
# allow access to N directories for DEST", "Yes, allow all edits this session", "Yes, return to normal
# mode", "Yes, and don't ask again" (RULE: a "prefix:*" rule's prefix, else its content, cut to 17
# characters and "…" past 20, else the tool's name). Everything the answer sends that the label does not
# name is a line under the button (rhun's wording): "Also allows access to DIR/", "Also switches to “MODE”
# for this session", "Also allows RULE" and the like.
#
# What goes back is only the CLI's own permission_suggestions, kept as JSON text at answer depth (AQ_sugg):
# the schema's types (addRules, replaceRules, removeRules, addDirectories, removeDirectories, setMode;
# others dropped), a setMode bypassPermissions only through rhun's gate ([claude] allow_bypass_permissions
# and no policy against it). Each is echoed member by member, its destination replaced by the place the
# card shows (a setMode keeps its own). The places cycle "this project (just you)" (localSettings), "all
# projects" (userSettings), "this project (shared)" (projectSettings), "this session" (session); the first
# is the project's remembered one (agentcfg AGF_DEST), else the suggestions' own (the widest of theirs, the
# extension's SPn order), and a remembered value that is none of the four is "this session".
#
# Answers (claude_reply): Yes allows with the input (its command as edited: the input written again member
# by member with the new "command"); the rule button sends set_permission_mode first for a setMode whose
# destination is session (the line finished first), then allows with updatedPermissions; No denies: with
# the field's text the extension's rejection (`Xb` @5214814, its own trailing space kept) and a space and
# the text, interrupt false; without, phase 1's words, interrupt true. Every answer carries toolUseID.
#
#   claude_card_build(AL*, AQ*, request jv)  the card (AQ_card), AQ_sugg, AQ_flags
#   claude_card_show(AL*, AQ*) -> eax 1 shown   its first place, then ev_card
#   claude_reply(AL*, AQ*, CD*) -> eax 1 written (or the card gone with its request)
.include "rhun.inc"

.equ LINE_VALUES, 1000000       # json_parse_lim's limits (agent_claude.s's)
.equ LINE_DEPTH, 200
.equ CLP_NOBYPASS, 2            # AL_cfg's policy bit against bypassPermissions (claude_session.s's)
.equ HOOK_MAX, 2000             # a hook's reason, characters at most
.equ JSON_MAX, 4000             # the Details' JSON, bytes at most
.equ NAMES_MAX, 64              # rules and directories a card names or lists
.equ RULE_CUT, 20               # a rule's content past this many characters is cut to RULE_KEEP and "…"
.equ RULE_KEEP, 17
.equ D_LOCAL, 0                 # the places, in their cycle's order (dests)
.equ D_USER, 1
.equ D_PROJECT, 2
.equ D_SESSION, 3
.equ D_COUNT, 4
.equ SG_ADD, 1                  # the suggestions' kinds (type_of)
.equ SG_REPLACE, 2
.equ SG_REMOVE, 3
.equ SG_ADDDIR, 4
.equ SG_REMOVEDIR, 5
.equ SG_SETMODE, 6
.equ QS_MAX, 100000             # the question card: a question's or a label's bytes at most (sent back whole)
.equ QHEAD_MAX, 400             #   a header's, a description's, a preview's (cut past it)
.equ QDESC_MAX, 4000
.equ QPREVIEW_MAX, 100000
.equ PLS_TABBED, 1              # plan review: AQ_state of a plan (the driver's): its tab was opened once
.equ PLS_MODEWAIT, 2            #   its Yes waits for set_permission_mode auto's answer
.equ PL_INFO, 6                 #   agents.s's R_INFO: an info row

.bss
.p2align 3
hsb: .zero SB_SIZE              # a header, a line
ssb: .zero SB_SIZE              # the suggestions kept, as JSON
jsb: .zero SB_SIZE              # the Details' JSON
nsb: .zero SB_SIZE              # the names: labels and full texts, NUL-separated
msb: .zero SB_SIZE              # a deny's message
cd_now: .quad 0                 # the card being made
in_now: .quad 0                 # its input
r_lab: .zero 4 * NAMES_MAX      # the addRules' rules: their labels' and full texts' places in nsb,
r_full: .zero 4 * NAMES_MAX     #   their behaviours (0 allow, 1 deny, 2 ask)
r_beh: .zero 4 * NAMES_MAX
n_rules: .long 0
d_lab: .zero 4 * NAMES_MAX      # the addDirectories' directories
d_full: .zero 4 * NAMES_MAX
n_dirs: .long 0
m_last: .quad 0                 # the last setMode's index among the kept, -1 none
own_dest: .long 0               # the widest place the suggestions name (D_*)
own_rank: .long 0
jcut: .long 0
mbuf: .zero 40                  # a setMode's mode, copied out of the parse

.text

# ---------------------------------------------------------------- reading the request

# in_str(jv, key cstr) -> rax ptr, rdx len of a string member, else 0, 0
in_str:
    PROLOGUE
    call json_get
    test rax, rax
    jz 8f
    mov rdi, rax
    call json_str
    test rax, rax
    jz 8f
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# in_true(jv, key) -> eax 1 when the member is true
in_true:
    PROLOGUE
    call json_get
    test rax, rax
    jz 8f
    mov rdi, rax
    call json_bool
    test edx, edx
    jz 8f
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# card_text(which, ptr, len): a text of the card being made
card_text:
    mov rcx, rdx
    mov rdx, rsi
    mov esi, edi
    mov rdi, [rip + cd_now]
    jmp agentcard_text

# hsb_text(which): hsb as that text
hsb_text:
    mov rsi, [rip + hsb + SB_ptr]
    mov rdx, [rip + hsb + SB_len]
    jmp card_text

# hsb_cstr(cstr), hsb_str(ptr, len)
hsb_cstr:
    mov rsi, rdi
    lea rdi, [rip + hsb]
    jmp sb_push_cstr
hsb_str:
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + hsb]
    jmp sb_push

# base_name(ptr, len) -> rax ptr, rdx len: the part after the last "/" or "\" (the whole when it is empty)
base_name:
    mov rax, rdi
    mov rdx, rsi
    mov rcx, rsi
1:  test rcx, rcx
    jz 9f
    dec rcx
    movzx r8d, byte ptr [rdi + rcx]
    cmp r8d, '/'
    je 2f
    cmp r8d, '\\'
    jne 1b
2:  lea r8, [rcx + 1]
    cmp r8, rsi
    jae 9f                      # nothing after it: the whole
    lea rax, [rdi + r8]
    mov rdx, rsi
    sub rdx, r8
9:  ret

# h_shell(label cstr): "Allow this LABEL command?", the command editable, its description under it; a
#   command that is not a string: the fallback
h_shell:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rip + in_now]
    lea rsi, [rip + .Lk_command]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 8f
    lea rdi, [rip + hsb]
    call sb_clear
    lea rdi, [rip + .Lq_allow_this]
    call hsb_cstr
    mov rdi, rbx
    call hsb_cstr
    lea rdi, [rip + .Lq_command]
    call hsb_cstr
    mov edi, CDT_TITLE
    call hsb_text
    mov rdi, [rip + in_now]
    lea rsi, [rip + .Lk_command]
    call in_str
    mov edi, CDT_EDIT
    mov rsi, rax
    call card_text
    mov rdi, [rip + in_now]
    lea rsi, [rip + .Lk_description]
    call in_str
    test rdx, rdx
    jz 9f
    mov edi, CDT_DESC
    mov rsi, rax
    call card_text
9:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

h_bash:
    lea rdi, [rip + .Lw_bash]
    jmp h_shell
h_pwsh:
    lea rdi, [rip + .Lw_pwsh]
    jmp h_shell

# h_file(before cstr): "BEFORE NAME?" with the file's name (file_path's last part)
h_file:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + hsb]
    call sb_clear
    mov rdi, rbx
    call hsb_cstr
    mov rdi, [rip + in_now]
    lea rsi, [rip + .Lk_file_path]
    call in_str
    mov rdi, rax
    mov rsi, rdx
    call base_name
    mov rdi, rax
    mov rsi, rdx
    call hsb_str
    lea rdi, [rip + .Lq_mark]
    call hsb_cstr
    mov edi, CDT_TITLE
    call hsb_text
    mov eax, 1
    EPILOGUE

h_edit:
    lea rdi, [rip + .Lq_edit]
    jmp h_file
h_write:
    lea rdi, [rip + .Lq_write]
    jmp h_file
h_read:
    lea rdi, [rip + .Lq_read]
    jmp h_file

# h_path(with path cstr, without cstr): "WITH PATH?" when the input has a path, else WITHOUT
h_path:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + hsb]
    call sb_clear
    mov rdi, [rip + in_now]
    lea rsi, [rip + .Lk_path]
    call in_str
    test rdx, rdx
    jz 1f
    mov r13, rax
    mov r14, rdx
    mov rdi, rbx
    call hsb_cstr
    mov rdi, r13
    mov rsi, r14
    call hsb_str
    lea rdi, [rip + .Lq_mark]
    call hsb_cstr
    jmp 2f
1:  mov rdi, r12
    call hsb_cstr
2:  mov edi, CDT_TITLE
    call hsb_text
    mov eax, 1
    EPILOGUE

h_glob:
    lea rdi, [rip + .Lq_glob_in]
    lea rsi, [rip + .Lq_glob]
    jmp h_path
h_grep:
    lea rdi, [rip + .Lq_grep_in]
    lea rsi, [rip + .Lq_grep]
    jmp h_path
h_search:
    lea rdi, [rip + .Lq_search_in]
    lea rsi, [rip + .Lq_search]
    jmp h_path

# h_member(title cstr, key cstr): the title, the member's text as the detail
h_member:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call strlen
    mov edi, CDT_TITLE
    mov rsi, rbx
    mov rdx, rax
    call card_text
    mov rdi, [rip + in_now]
    mov rsi, r12
    call in_str
    test rdx, rdx
    jz 9f
    mov edi, CDT_DETAIL
    mov rsi, rax
    call card_text
9:  mov eax, 1
    EPILOGUE

h_fetch:
    lea rdi, [rip + .Lq_fetch]
    lea rsi, [rip + .Lk_url]
    jmp h_member
h_net:
    lea rdi, [rip + .Lq_net]
    lea rsi, [rip + .Lk_host]
    jmp h_member

# h_websearch: the query, then "Allowed: A, B · Blocked: C" from its domain lists
h_websearch:
    PROLOGUE
    lea rdi, [rip + .Lq_websearch]
    lea rsi, [rip + .Lk_query]
    call h_member
    lea rdi, [rip + hsb]
    call sb_clear
    lea rdi, [rip + .Lk_allowed]
    lea rsi, [rip + .Lw_allowed]
    call domains
    lea rdi, [rip + .Lk_blocked]
    lea rsi, [rip + .Lw_blocked]
    call domains
    cmp qword ptr [rip + hsb + SB_len], 0
    je 9f
    mov edi, CDT_DESC
    call hsb_text
9:  mov eax, 1
    EPILOGUE

# domains(key, word): "WORD: a, b" into hsb (" · " before it when hsb has text) when the list has strings
domains:
    PROLOGUE
    mov r12, rsi
    mov rsi, rdi
    mov rdi, [rip + in_now]
    call json_get
    mov rbx, rax
    mov rdi, rax
    call json_len
    mov r13d, eax
    xor r14d, r14d
    xor r15d, r15d              # strings written
1:  cmp r14d, r13d
    jae 9f
    mov rdi, rbx
    mov esi, r14d
    inc r14d
    call json_at
    mov rdi, rax
    call json_str
    test rax, rax
    jz 1b
    push rax
    push rdx
    test r15d, r15d
    jnz 2f
    cmp qword ptr [rip + hsb + SB_len], 0
    je 11f
    lea rdi, [rip + .Lw_dot]
    call hsb_cstr
11: mov rdi, r12
    call hsb_cstr
    jmp 3f
2:  lea rdi, [rip + .Lw_comma]
    call hsb_cstr
3:  pop rsi
    pop rdi
    call hsb_str
    inc r15d
    jmp 1b
9:  EPILOGUE

# h_skill: "Use skill /NAME?", "Claude may use instructions, code, or files from this skill.", the
#   command's description when the program listed it, "Arguments: ARGS"
h_skill:
    PROLOGUE
    lea rdi, [rip + hsb]
    call sb_clear
    lea rdi, [rip + .Lq_skill]
    call hsb_cstr
    mov rdi, [rip + in_now]
    lea rsi, [rip + .Lk_skill]
    call in_str
    mov r12, rax
    mov r13, rdx
    test r13, r13
    jz 1f
    cmp byte ptr [r12], '/'
    jne 1f
    inc r12
    dec r13
1:  mov rdi, r12
    mov rsi, r13
    call hsb_str
    lea rdi, [rip + .Lq_mark]
    call hsb_cstr
    mov edi, CDT_TITLE
    call hsb_text
    lea rdi, [rip + hsb]
    call sb_clear
    lea rdi, [rip + .Lq_skill_note]
    call hsb_cstr
    test r13, r13
    jz 2f
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call agentcfg_find_cmd
    test rax, rax
    jz 2f
    mov rbx, [rax + ACM_desc]
    test rbx, rbx
    jz 2f
    cmp byte ptr [rbx], 0
    je 2f
    lea rdi, [rip + hsb]
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    call hsb_cstr
2:  mov rdi, [rip + in_now]
    lea rsi, [rip + .Lk_args]
    call in_str
    test rdx, rdx
    jz 3f
    mov r12, rax
    mov r13, rdx
    lea rdi, [rip + hsb]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + .Lq_arguments]
    call hsb_cstr
    mov rdi, r12
    mov rsi, r13
    call hsb_str
3:  mov edi, CDT_DESC
    call hsb_text
    mov eax, 1
    EPILOGUE

# h_project: SendToProject as the extension reads it (d$: message_from typed or drafted, a proposal with
#   only a non-blank summary, a project_name): "Create the Claude Project “NAME” and send this message?"
#   (no project_id) or "Send this message to the Claude Project “NAME”?", the message, "Scroll to the end
#   of the message before approving it." and the repository line; else the fallback (eax 0)
h_project:
    PROLOGUE
    mov rbx, [rip + in_now]
    mov rdi, rbx
    lea rsi, [rip + .Lk_from]
    call json_get
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lv_typed]
    call json_is
    test eax, eax
    jnz 1f
    mov rdi, r12
    lea rsi, [rip + .Lv_drafted]
    call json_is
    test eax, eax
    jz 8f
1:  mov rdi, rbx
    lea rsi, [rip + .Lk_proposal]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_npairs
    cmp eax, 1
    jne 8f
    mov rdi, r12
    lea rsi, [rip + .Lk_summary]
    call in_str
    test rax, rax
    jz 8f
    mov r13, rax                # the words
    mov r14, rdx
    mov rdi, rax
    mov rsi, rdx
    call trim
    test rdx, rdx
    jz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_project_name]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 8f
    lea rdi, [rip + hsb]
    call sb_clear
    mov rdi, rbx                # creates: no project_id string
    lea rsi, [rip + .Lk_project_id]
    call json_get
    mov rdi, rax
    call json_type
    mov r15d, eax
    lea rdi, [rip + .Lq_proj_create]
    cmp r15d, JT_STR
    jne 2f
    lea rdi, [rip + .Lq_proj_send]
2:  call hsb_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_project_name]
    call in_str
    mov rdi, rax
    mov rsi, rdx
    call hsb_str
    lea rdi, [rip + .Lq_proj_create_end]
    cmp r15d, JT_STR
    jne 3f
    lea rdi, [rip + .Lq_proj_send_end]
3:  call hsb_cstr
    mov edi, CDT_TITLE
    call hsb_text
    mov edi, CDT_DETAIL
    mov rsi, r13
    mov rdx, r14
    call card_text
    lea rdi, [rip + hsb]
    call sb_clear
    lea rdi, [rip + .Lq_proj_scroll]
    call hsb_cstr
    cmp r15d, JT_STR            # a new project with the folder's origin
    je 4f
    mov rdi, rbx
    lea rsi, [rip + .Lk_attach]
    call in_true
    test eax, eax
    jz 4f
    mov rdi, rbx
    lea rsi, [rip + .Lk_origin]
    call in_str
    test rdx, rdx
    jz 4f
    mov r13, rax
    mov r14, rdx
    lea rdi, [rip + hsb]
    mov esi, 10
    call sb_push_byte
    lea rdi, [rip + .Lq_proj_origin]
    call hsb_cstr
    mov rdi, r13
    mov rsi, r14
    call hsb_str
    lea rdi, [rip + .Lq_proj_origin_end]
    call hsb_cstr
4:  mov edi, CDT_DESC
    call hsb_text
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# h_fallback(tool cstr): "Do you want to proceed with TOOL?" and "Details": the input as indented JSON
h_fallback:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + hsb]
    call sb_clear
    lea rdi, [rip + .Lq_proceed]
    call hsb_cstr
    mov rdi, rbx
    call hsb_cstr
    lea rdi, [rip + .Lq_mark]
    call hsb_cstr
    mov edi, CDT_TITLE
    call hsb_text
    mov rdi, [rip + in_now]
    call json_npairs
    test eax, eax
    jz 9f
    lea rdi, [rip + jsb]
    call sb_clear
    mov dword ptr [rip + jcut], 0
    mov rdi, [rip + in_now]
    xor esi, esi
    call pretty
    cmp dword ptr [rip + jcut], 0
    je 1f
    mov rdi, [rip + jsb + SB_len]
    mov rsi, [rip + jsb + SB_ptr]
    mov edx, JSON_MAX
    call utf8_cut
    mov [rip + jsb + SB_len], rax
    lea rdi, [rip + jsb]
    lea rsi, [rip + .Lellipsis]
    call sb_push_cstr
1:  mov edi, CDT_JSON
    mov rsi, [rip + jsb + SB_ptr]
    mov rdx, [rip + jsb + SB_len]
    call card_text
9:  mov eax, 1
    EPILOGUE

# pretty(jv, indent): jv into jsb as JSON.stringify(v, null, 2) writes it; stops past JSON_MAX (jcut)
pretty:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp qword ptr [rip + jsb + SB_len], JSON_MAX
    jbe 1f
    mov dword ptr [rip + jcut], 1
    EPILOGUE
1:  mov rdi, rbx
    call json_type
    cmp eax, JT_OBJ
    je .Lpj_obj
    cmp eax, JT_ARR
    je .Lpj_arr
    call jw_reset               # a scalar, as the writer writes it
    lea rdi, [rip + jsb]
    mov rsi, rbx
    call jw_jv
    EPILOGUE
.Lpj_arr:
    mov rdi, rbx
    call json_len
    mov r13d, eax
    lea rdi, [rip + jsb]
    mov esi, '['
    call sb_push_byte
    test r13d, r13d
    jz 4f
    xor r14d, r14d
2:  cmp r14d, r13d
    jae 3f
    test r14d, r14d
    jz 21f
    lea rdi, [rip + jsb]
    mov esi, ','
    call sb_push_byte
21: lea edi, [r12 + 2]
    call indent
    mov rdi, rbx
    mov esi, r14d
    call json_at
    mov rdi, rax
    lea esi, [r12 + 2]
    call pretty
    inc r14d
    jmp 2b
3:  mov edi, r12d
    call indent
4:  lea rdi, [rip + jsb]
    mov esi, ']'
    call sb_push_byte
    EPILOGUE
.Lpj_obj:
    mov rdi, rbx
    call json_npairs
    mov r13d, eax
    lea rdi, [rip + jsb]
    mov esi, '{'
    call sb_push_byte
    test r13d, r13d
    jz 7f
    xor r14d, r14d
5:  cmp r14d, r13d
    jae 6f
    test r14d, r14d
    jz 51f
    lea rdi, [rip + jsb]
    mov esi, ','
    call sb_push_byte
51: lea edi, [r12 + 2]
    call indent
    mov rdi, rbx
    mov esi, r14d
    call json_pair
    mov r15, rdx
    mov rdi, rax
    call json_str
    mov [rsp], rax
    call jw_reset
    lea rdi, [rip + jsb]
    mov rsi, [rsp]
    call jw_str                 # (rdx: the key's length, json_str's)
    lea rdi, [rip + jsb]
    lea rsi, [rip + .Lw_colon]
    call sb_push_cstr
    mov rdi, r15
    lea esi, [r12 + 2]
    call pretty
    inc r14d
    jmp 5b
6:  mov edi, r12d
    call indent
7:  lea rdi, [rip + jsb]
    mov esi, '}'
    call sb_push_byte
    EPILOGUE

# indent(n): a line feed and n spaces into jsb
indent:
    PROLOGUE
    mov ebx, edi
    lea rdi, [rip + jsb]
    mov esi, 10
    call sb_push_byte
1:  test ebx, ebx
    jle 9f
    lea rdi, [rip + jsb]
    mov esi, ' '
    call sb_push_byte
    dec ebx
    jmp 1b
9:  EPILOGUE

# ---------------------------------------------------------------- the suggestions

# bypass_ok(AL*) -> eax 1 when a setMode bypassPermissions may go back: rhun's gate and no policy against it
bypass_ok:
    xor eax, eax
    cmp dword ptr [rip + cfg_claude_allow_bypass], 0
    je 9f
    test dword ptr [rdi + AL_cfg], CLP_NOBYPASS
    jnz 9f
    mov eax, 1
9:  ret

# dest_index(ptr, len) -> eax the place's D_* (cliArg and unknown: -1); edx its rank in the extension's
#   order of width (userSettings 0, projectSettings 1, localSettings 2, session 3, cliArg 4, else 9)
dest_index:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  cmp ebx, D_COUNT
    jae 2f
    lea rax, [rip + dest_ids]
    mov rdx, [rax + rbx*8]
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 3f
    inc ebx
    jmp 1b
2:  mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lv_cliarg]
    call str_eq_cstr
    mov edx, 9
    test eax, eax
    jz 21f
    mov edx, 4
21: mov eax, -1
    EPILOGUE
3:  lea rax, [rip + dest_rank]
    mov edx, [rax + rbx*4]
    mov eax, ebx
    EPILOGUE

# name_put(ptr, len) -> eax its place in nsb (a NUL after it)
name_put:
    PROLOGUE
    mov rbx, [rip + nsb + SB_len]
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + nsb]
    call sb_push
    lea rdi, [rip + nsb]
    xor esi, esi
    call sb_push_byte
    mov eax, ebx
    EPILOGUE

# name_at(off) -> rax the cstr at that place in nsb
name_at:
    mov eax, edi
    add rax, [rip + nsb + SB_ptr]
    ret

# rule_names(rule jv, behavior 0|1|2): the rule's label and full text ("Tool(content)", or "Tool") kept
#   (NAMES_MAX at most)
rule_names:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], esi
    mov eax, [rip + n_rules]
    cmp eax, NAMES_MAX
    jae 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_tool_name_r]
    call in_str
    mov r12, rax                # the tool
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_rule_content]
    call in_str
    mov r14, rax                # its content
    mov r15, rdx
    lea rdi, [rip + hsb]        # the full text
    call sb_clear
    mov rdi, r12
    mov rsi, r13
    call hsb_str
    test r15, r15
    jz 1f
    lea rdi, [rip + .Lw_paren]
    call hsb_cstr
    mov rdi, r14
    mov rsi, r15
    call hsb_str
    lea rdi, [rip + .Lw_paren_end]
    call hsb_cstr
1:  mov rdi, [rip + hsb + SB_ptr]
    mov rsi, [rip + hsb + SB_len]
    call name_put
    mov ecx, [rip + n_rules]
    lea rdx, [rip + r_full]
    mov [rdx + rcx*4], eax
    lea rdx, [rip + r_beh]
    mov esi, [rsp]
    mov [rdx + rcx*4], esi
    # the label: a prefix:* rule's prefix, its content cut, or the tool
    lea rdi, [rip + hsb]
    call sb_clear
    test r15, r15
    jnz 2f
    mov rdi, r12
    mov rsi, r13
    call hsb_str
    jmp 6f
2:  cmp r15, 3
    jb 3f
    cmp byte ptr [r14 + r15 - 1], '*'
    jne 3f
    cmp byte ptr [r14 + r15 - 2], ':'
    jne 3f
    mov rdi, r14
    lea rsi, [r15 - 2]
    call hsb_str
    jmp 6f
3:  xor ecx, ecx                # characters in it, and where the 17th ends
    xor edx, edx
    mov [rsp + 8], r15
    xor r8d, r8d
4:  cmp rcx, r15
    jae 5f
    movzx eax, byte ptr [r14 + rcx]
    inc rcx
    and eax, 0xc0
    cmp eax, 0x80
    je 4b
    inc edx
    cmp edx, RULE_KEEP
    jne 4b
    mov r8, rcx                 # (the 17th character starts one byte back: find its end)
41: cmp r8, r15
    jae 42f
    movzx eax, byte ptr [r14 + r8]
    and eax, 0xc0
    cmp eax, 0x80
    jne 42f
    inc r8
    jmp 41b
42: mov [rsp + 8], r8
    jmp 4b
5:  cmp edx, RULE_CUT
    jbe 51f
    mov rdi, r14
    mov rsi, [rsp + 8]
    call hsb_str
    lea rdi, [rip + .Lellipsis]
    call hsb_cstr
    jmp 6f
51: mov rdi, r14
    mov rsi, r15
    call hsb_str
6:  mov rdi, [rip + hsb + SB_ptr]
    mov rsi, [rip + hsb + SB_len]
    call name_put
    mov ecx, [rip + n_rules]
    lea rdx, [rip + r_lab]
    mov [rdx + rcx*4], eax
    inc dword ptr [rip + n_rules]
9:  EPILOGUE

# dir_names(path ptr, len): the directory's label ("NAME/") and full text ("PATH/") kept
dir_names:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov eax, [rip + n_dirs]
    cmp eax, NAMES_MAX
    jae 9f
    lea rdi, [rip + hsb]
    call sb_clear
    mov rdi, r12
    mov rsi, r13
    call hsb_str
    test r13, r13
    jz 1f
    cmp byte ptr [r12 + r13 - 1], '/'
    je 2f
1:  lea rdi, [rip + .Lw_slash]
    call hsb_cstr
2:  mov rdi, [rip + hsb + SB_ptr]
    mov rsi, [rip + hsb + SB_len]
    call name_put
    mov ecx, [rip + n_dirs]
    lea rdx, [rip + d_full]
    mov [rdx + rcx*4], eax
    mov rdi, r12
    mov rsi, r13
    call base_name
    mov r12, rax
    mov r13, rdx
    lea rdi, [rip + hsb]
    call sb_clear
    mov rdi, r12
    mov rsi, r13
    call hsb_str
    lea rdi, [rip + .Lw_slash]
    call hsb_cstr
    mov rdi, [rip + hsb + SB_ptr]
    mov rsi, [rip + hsb + SB_len]
    call name_put
    mov ecx, [rip + n_dirs]
    lea rdx, [rip + d_lab]
    mov [rdx + rcx*4], eax
    inc dword ptr [rip + n_dirs]
9:  EPILOGUE

# type_of(jv) -> eax the suggestion's kind (SG_*: 0 unknown)
type_of:
    PROLOGUE
    lea rsi, [rip + .Lk_type]
    call json_get
    mov r12, rax
    mov ebx, 1
1:  cmp ebx, SG_SETMODE
    ja 8f
    lea rax, [rip + type_names]
    mov rsi, [rax + rbx*8 - 8]
    mov rdi, r12
    call json_is
    test eax, eax
    jnz 2f
    inc ebx
    jmp 1b
2:  mov eax, ebx
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# behavior_of(jv) -> eax 0 allow, 1 deny, 2 ask
behavior_of:
    PROLOGUE
    lea rsi, [rip + .Lk_behavior]
    call json_get
    mov rbx, rax
    mov r12d, 1
    mov rdi, rax
    lea rsi, [rip + .Lv_deny]
    call json_is
    test eax, eax
    jnz 9f
    mov r12d, 2
    mov rdi, rbx
    lea rsi, [rip + .Lv_ask]
    call json_is
    test eax, eax
    jnz 9f
    xor r12d, r12d
9:  mov eax, r12d
    EPILOGUE

# mode_label(ptr, len) -> rax the mode's label (its id when rhun does not know it: then rdx its length)
mode_label:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
1:  lea rax, [rip + mode_names]
    mov rdx, [rax + rbx*8]
    test rdx, rdx
    jz 8f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add ebx, 2
    jmp 1b
2:  lea rax, [rip + mode_names]
    mov rdi, [rax + rbx*8 + 8]
    mov rbx, rdi
    call strlen
    mov rdx, rax
    mov rax, rbx
    EPILOGUE
8:  mov rax, r12
    mov rdx, r13
    EPILOGUE

# extra_line(before cstr, name ptr, len, after cstr or 0): "BEFORE NAMEAFTER" under the rule button
extra_line:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    lea rdi, [rip + hsb]
    call sb_clear
    mov rdi, rbx
    call hsb_cstr
    mov rdi, r12
    mov rsi, r13
    call hsb_str
    test r14, r14
    jz 1f
    mov rdi, r14
    call hsb_cstr
1:  lea rdi, [rip + hsb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + cd_now]
    mov rsi, [rip + hsb + SB_ptr]
    call agentcard_extra
    EPILOGUE

# rule_lines(suggestion jv, before cstr): a line per rule of a replaceRules or removeRules
rule_lines:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rsi, [rip + .Lk_rules]
    call json_get
    mov r13, rax
    mov rdi, rax
    call json_len
    mov r14d, eax
    xor r15d, r15d
1:  cmp r15d, r14d
    jae 9f
    mov rdi, r13
    mov esi, r15d
    inc r15d
    call json_at
    mov rbx, rax
    mov rdi, rbx                # its full text
    lea rsi, [rip + .Lk_tool_name_r]
    call in_str
    push rax
    push rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_rule_content]
    call in_str
    mov [rip + m_tmp_p], rax
    mov [rip + m_tmp_n], rdx
    lea rdi, [rip + hsb]
    call sb_clear
    pop rsi
    pop rdi
    call hsb_str
    cmp qword ptr [rip + m_tmp_n], 0
    je 2f
    lea rdi, [rip + .Lw_paren]
    call hsb_cstr
    mov rdi, [rip + m_tmp_p]
    mov rsi, [rip + m_tmp_n]
    call hsb_str
    lea rdi, [rip + .Lw_paren_end]
    call hsb_cstr
2:  mov rdi, [rip + hsb + SB_ptr]
    mov rsi, [rip + hsb + SB_len]
    call name_put
    mov edi, eax
    call name_at
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov rdi, r12
    mov rsi, rbx
    mov rdx, rax
    xor ecx, ecx
    call extra_line
    jmp 1b
9:  EPILOGUE

# keep_suggestions(AL*, request jv): the suggestions the card may send, kept in ssb as a JSON array at
#   answer depth (the schema's types; a setMode bypassPermissions only through the gate); their names
#   (n_rules, n_dirs, m_last), own_dest. -> eax how many were kept (0 also when one could not be echoed)
keep_suggestions:
    PROLOGUE 16
    mov rbx, rdi
    mov dword ptr [rip + n_rules], 0
    mov dword ptr [rip + n_dirs], 0
    mov qword ptr [rip + m_last], -1
    mov dword ptr [rip + own_dest], D_SESSION
    mov dword ptr [rip + own_rank], 9
    lea rdi, [rip + nsb]
    call sb_clear
    mov rdi, rsi
    lea rsi, [rip + .Lk_suggestions]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_len
    mov r13d, eax
    lea rdi, [rip + ssb]        # at the depth an answer writes them (three objects, then their bytes cleared)
    call jw_begin
    lea rdi, [rip + ssb]
    call jw_obj
    lea rdi, [rip + ssb]
    call jw_obj
    lea rdi, [rip + ssb]
    call jw_obj
    lea rdi, [rip + ssb]
    call sb_clear
    lea rdi, [rip + ssb]
    call jw_arr
    xor r14d, r14d              # read
    xor r15d, r15d              # kept
    mov dword ptr [rsp], 1      # every one echoed
1:  cmp r14d, r13d
    jae 8f
    mov rdi, r12
    mov esi, r14d
    inc r14d
    call json_at
    mov [rsp + 8], rax
    mov rdi, rax
    call type_of
    test eax, eax
    jz 1b                       # not one of the schema's
    cmp eax, SG_SETMODE
    jne 2f
    mov rdi, [rsp + 8]
    lea rsi, [rip + .Lk_mode]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_bypass]
    call json_is
    test eax, eax
    jz 11f
    mov rdi, rbx
    call bypass_ok
    test eax, eax
    jz 1b                       # bypass is rhun's gate alone
11: mov [rip + m_last], r15
2:  lea rdi, [rip + ssb]
    mov rsi, [rsp + 8]
    call jw_jv
    test eax, eax
    jnz 3f
    mov dword ptr [rsp], 0
3:  inc r15d
    mov rdi, [rsp + 8]          # its own place, for the first shown
    lea rsi, [rip + .Lk_destination]
    call in_str
    test rdx, rdx
    jz 4f
    mov rdi, rax
    mov rsi, rdx
    call dest_index
    cmp edx, [rip + own_rank]
    jae 4f
    mov [rip + own_rank], edx
    test eax, eax
    jns 31f
    mov eax, D_SESSION          # cliArg: rhun cycles only the four
31: mov [rip + own_dest], eax
4:  mov rdi, [rsp + 8]          # its names
    call type_of
    cmp eax, SG_ADD
    je 5f
    cmp eax, SG_ADDDIR
    je 6f
    jmp 1b
5:  mov rdi, [rsp + 8]
    call behavior_of
    mov [rsp + 4], eax
    mov rdi, [rsp + 8]
    lea rsi, [rip + .Lk_rules]
    call json_get
    mov [rsp + 8], rax
    xor ecx, ecx
51: mov [rip + m_tmp_n], rcx
    mov rdi, [rsp + 8]
    call json_len
    mov rcx, [rip + m_tmp_n]
    cmp ecx, eax
    jae 1b
    mov rdi, [rsp + 8]
    mov esi, ecx
    call json_at
    mov rdi, rax
    mov esi, [rsp + 4]
    call rule_names
    mov rcx, [rip + m_tmp_n]
    inc rcx
    jmp 51b
6:  mov rdi, [rsp + 8]
    lea rsi, [rip + .Lk_directories]
    call json_get
    mov [rsp + 8], rax
    xor ecx, ecx
61: mov [rip + m_tmp_n], rcx
    mov rdi, [rsp + 8]
    call json_len
    mov rcx, [rip + m_tmp_n]
    cmp ecx, eax
    jae 1b
    mov rdi, [rsp + 8]
    mov esi, ecx
    call json_at
    mov rdi, rax
    call json_str
    test rax, rax
    jz 62f
    mov rdi, rax
    mov rsi, rdx
    call dir_names
62: mov rcx, [rip + m_tmp_n]
    inc rcx
    jmp 61b
8:  lea rdi, [rip + ssb]
    call jw_end_arr
    mov eax, r15d
    cmp dword ptr [rsp], 0
    jne 9f
    xor eax, eax                # one could not be echoed whole: none go
9:  EPILOGUE

# rule_button(request jv): the rule button's label and the lines under it, from the names kept and the
#   suggestions (parsed still)
rule_button:
    PROLOGUE 16
    mov [rsp], rdi
    lea rdi, [rip + hsb]
    call sb_clear
    mov r12d, [rip + n_rules]
    mov r13d, [rip + n_dirs]
    xor r14d, r14d              # CDBF_DEST
    test r12d, r12d
    jnz .Lrb_rules
    test r13d, r13d
    jnz .Lrb_dirs
    lea rdi, [rip + .Lb_dont_ask]
    cmp qword ptr [rip + m_last], 0
    jl 1f
    call last_mode              # a mode change alone
    mov rbx, rax
    mov r15, rdx
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Lv_accept]
    call str_eq_cstr
    lea rdi, [rip + .Lb_all_edits]
    test eax, eax
    jnz 1f
    mov rdi, rbx
    mov rsi, r15
    lea rdx, [rip + .Lv_default]
    call str_eq_cstr
    lea rdi, [rip + .Lb_normal]
    test eax, eax
    jnz 1f
    lea rdi, [rip + .Lb_dont_ask]
1:  call hsb_cstr
    jmp .Lrb_made
.Lrb_rules:
    lea rdi, [rip + .Lb_allow]
    call hsb_cstr
    mov edi, [rip + r_lab]
    call name_at
    mov rdi, rax
    call hsb_cstr
    cmp r12d, 1
    je 2f
    lea rdi, [rip + .Lb_and]
    call hsb_cstr
    cmp r12d, 2
    jne 21f
    mov edi, [rip + r_lab + 4]
    call name_at
    mov rdi, rax
    call hsb_cstr
    jmp 2f
21: lea rdi, [rip + hsb]
    lea esi, [r12 - 1]
    call sb_push_u64
    lea rdi, [rip + .Lb_more]
    call hsb_cstr
2:  lea rdi, [rip + .Lb_for]
    call hsb_cstr
    mov r14d, CDBF_DEST
    jmp .Lrb_made
.Lrb_dirs:
    lea rdi, [rip + .Lb_access]
    call hsb_cstr
    cmp r13d, 1
    jne 3f
    mov edi, [rip + d_lab]
    call name_at
    mov rdi, rax
    call hsb_cstr
    jmp 31f
3:  lea rdi, [rip + hsb]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + .Lb_dirs]
    call hsb_cstr
31: lea rdi, [rip + .Lb_for]
    call hsb_cstr
    mov r14d, CDBF_DEST
.Lrb_made:
    lea rdi, [rip + hsb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + cd_now]
    mov rsi, [rip + hsb + SB_ptr]
    mov edx, CBA_RULE
    mov ecx, r14d
    call agentcard_btn
    # the lines: the rules the label does not name
    cmp r12d, 2
    jbe 5f
    mov r15d, 1
4:  cmp r15d, r12d
    jae 5f
    lea rax, [rip + r_beh]
    mov eax, [rax + r15*4]
    lea rcx, [rip + beh_words]
    mov rbx, [rcx + rax*8]
    lea rax, [rip + r_full]
    mov edi, [rax + r15*4]
    call name_at
    mov [rsp + 8], rax
    mov rdi, rax
    call strlen
    mov rdi, rbx
    mov rsi, [rsp + 8]
    mov rdx, rax
    xor ecx, ecx
    call extra_line
    inc r15d
    jmp 4b
5:  # the directories it does not name: all when there are rules, or more than one
    test r12d, r12d
    jnz 51f
    cmp r13d, 1
    jbe 6f
51: xor r15d, r15d
52: cmp r15d, r13d
    jae 6f
    lea rax, [rip + d_full]
    mov edi, [rax + r15*4]
    call name_at
    mov [rsp + 8], rax
    mov rdi, rax
    call strlen
    lea rdi, [rip + .Lx_access]
    mov rsi, [rsp + 8]
    mov rdx, rax
    xor ecx, ecx
    call extra_line
    inc r15d
    jmp 52b
6:  # every other kind, and each mode change the label does not name
    mov rdi, [rsp]
    call other_lines
    EPILOGUE

# last_mode() -> rax ptr, rdx len: the mode of the last kept setMode (from ssb's parse... read live: the
#   kept list is the request's own in order, so it is found again there)
last_mode:
    PROLOGUE
    mov rax, [rip + lm_ptr]
    mov rdx, [rip + lm_len]
    EPILOGUE

# other_lines(request jv): a line for each replaceRules or removeRules rule, removeDirectories directory,
#   and setMode the label does not name (the last one is named only when it is the only kind)
other_lines:
    PROLOGUE 16
    lea rsi, [rip + .Lk_suggestions]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_len
    mov r13d, eax
    xor r14d, r14d              # read
    xor r15d, r15d              # kept (the index m_last counts)
1:  cmp r14d, r13d
    jae 9f
    mov rdi, r12
    mov esi, r14d
    inc r14d
    call json_at
    mov rbx, rax
    mov rdi, rax
    call type_of
    test eax, eax
    jz 1b
    mov [rsp], eax
    cmp eax, SG_SETMODE
    jne 2f
    mov rdi, rbx
    lea rsi, [rip + .Lk_mode]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_bypass]
    call json_is
    test eax, eax
    jz 2f
    mov rdi, [rip + al_now]
    call bypass_ok
    test eax, eax
    jz 1b                       # dropped: not kept, not counted
2:  inc r15d
    mov eax, [rsp]
    cmp eax, SG_REPLACE
    je 3f
    cmp eax, SG_REMOVE
    je 4f
    cmp eax, SG_REMOVEDIR
    je 5f
    cmp eax, SG_SETMODE
    je 6f
    jmp 1b
3:  mov rdi, rbx
    lea rsi, [rip + .Lx_replace]
    call rule_lines
    jmp 1b
4:  mov rdi, rbx
    lea rsi, [rip + .Lx_remove]
    call rule_lines
    jmp 1b
5:  mov rdi, rbx
    lea rsi, [rip + .Lk_directories]
    call json_get
    mov [rsp + 8], rax
    xor ecx, ecx
51: mov [rip + m_tmp_n], rcx
    mov rdi, [rsp + 8]
    call json_len
    mov rcx, [rip + m_tmp_n]
    cmp ecx, eax
    jae 1b
    mov rdi, [rsp + 8]
    mov esi, ecx
    call json_at
    mov rdi, rax
    call json_str
    test rax, rax
    jz 52f
    lea rdi, [rip + .Lx_unaccess]
    mov rcx, rax
    mov rsi, rax
    lea rcx, [rip + .Lw_slash]
    call extra_line
52: mov rcx, [rip + m_tmp_n]
    inc rcx
    jmp 51b
6:  # a mode change: named by the label only when it is the last one and nothing else is
    lea eax, [r15 - 1]
    cmp rax, [rip + m_last]
    jne 61f
    cmp dword ptr [rip + n_rules], 0
    jne 61f
    cmp dword ptr [rip + n_dirs], 0
    jne 61f
    mov rdi, rbx
    lea rsi, [rip + .Lk_destination]
    call in_str
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_session]
    call str_eq_cstr
    test eax, eax
    jz 61f
    mov rdi, rbx                # acceptEdits and default have their own labels; others do not name it
    lea rsi, [rip + .Lk_mode]
    call json_get
    mov [rsp + 8], rax
    mov rdi, rax
    lea rsi, [rip + .Lv_accept]
    call json_is
    test eax, eax
    jnz 1b
    mov rdi, [rsp + 8]
    lea rsi, [rip + .Lv_default]
    call json_is
    test eax, eax
    jnz 1b
61: mov rdi, rbx
    call mode_line
    jmp 1b
9:  EPILOGUE

# mode_line(setMode jv): "Also switches to “LABEL” for this session", or "Also makes “LABEL” the default
#   mode for PLACE" for a place that saves it
mode_line:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_mode]
    call in_str
    mov rdi, rax
    mov rsi, rdx
    call mode_label
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_destination]
    call in_str
    mov r14, rax
    mov r15, rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_session]
    call str_eq_cstr
    test eax, eax
    jz 1f
    lea rdi, [rip + .Lx_switch]
    mov rsi, r12
    mov rdx, r13
    lea rcx, [rip + .Lx_switch_end]
    call extra_line
    EPILOGUE
1:  mov rdi, r14
    mov rsi, r15
    call dest_index
    lea rcx, [rip + .Lv_cliarg_label]
    test eax, eax
    js 2f
    lea rcx, [rip + dest_labels]
    mov rcx, [rcx + rax*8]
2:  lea rdi, [rip + hsb]
    call sb_clear
    push rcx
    push rcx
    lea rdi, [rip + .Lx_makes]
    call hsb_cstr
    mov rdi, r12
    mov rsi, r13
    call hsb_str
    lea rdi, [rip + .Lx_makes_mid]
    call hsb_cstr
    pop rdi
    pop rcx
    call hsb_cstr
    lea rdi, [rip + hsb]
    xor esi, esi
    call sb_push_byte
    mov rdi, [rip + cd_now]
    mov rsi, [rip + hsb + SB_ptr]
    call agentcard_extra
    EPILOGUE

# FN claude_card_build(AL*, AQ*, request jv): the permission request's card while it is parsed (AQ_card),
#   its flags (AQF_*), the suggestions it may send back (AQ_sugg)
FN claude_card_build
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rip + al_now], rbx
    mov rdi, r13
    lea rsi, [rip + .Lk_suppress]
    call in_true
    test eax, eax
    jz 1f
    or dword ptr [r12 + AQ_flags], AQF_NOSAVE
1:  mov rdi, r13
    lea rsi, [rip + .Lk_defno]
    call in_true
    test eax, eax
    jz 2f
    or dword ptr [r12 + AQ_flags], AQF_DEFNO
2:  mov edi, CDK_PERMISSION
    call agentcard_new
    mov r14, rax
    mov [rip + cd_now], rax
    mov [r12 + AQ_card], rax
    mov [rax + CD_token], r12
    test dword ptr [r12 + AQ_flags], AQF_DEFNO
    jz 3f
    or dword ptr [r14 + CD_flags], CDF_DEFNO
3:  mov rdi, r13
    lea rsi, [rip + .Lk_input]
    call json_get
    mov [rip + in_now], rax
    # the header, per tool
    lea r15, [rip + headers]
4:  mov rsi, [r15]
    test rsi, rsi
    jz 5f
    mov rdi, [r12 + AQ_tool]
    call strcmp_eq
    test eax, eax
    jnz 41f
    add r15, 16
    jmp 4b
41: call [r15 + 8]
    test eax, eax
    jnz 6f
5:  mov rdi, [r12 + AQ_tool]
    call h_fallback
6:  # a hook's reason; a safety check's as the hint
    mov rdi, r13
    lea rsi, [rip + .Lk_reason_type]
    call json_get
    mov r15, rax
    mov rdi, rax
    lea rsi, [rip + .Lv_hook]
    call json_is
    test eax, eax
    jz 61f
    mov rdi, r13
    lea rsi, [rip + .Lk_reason]
    call in_str
    test rdx, rdx
    jz 7f
    push rax
    push rax
    mov rdi, rax
    mov rsi, rdx
    call hook_cut
    pop rsi
    pop rsi
    mov edi, CDT_NOTE
    mov rdx, rax
    call card_text
    jmp 7f
61: mov rdi, r15
    lea rsi, [rip + .Lv_safety]
    call json_is
    test eax, eax
    jnz 62f
    mov rdi, r15
    lea rsi, [rip + .Lv_subcommands]
    call json_is
    test eax, eax
    jz 7f
62: mov rdi, r13
    lea rsi, [rip + .Lk_reason]
    call in_str
    test rdx, rdx
    jz 7f
    mov edi, CDT_HINT
    mov rsi, rax
    call card_text
7:  # the buttons
    mov rdi, r14
    lea rsi, [rip + .Lb_yes]
    mov edx, CBA_YES
    xor ecx, ecx
    call agentcard_btn
    test dword ptr [r12 + AQ_flags], AQF_NOSAVE
    jnz 8f
    mov rdi, rbx
    mov rsi, r13
    call keep_suggestions
    test eax, eax
    jz 8f
    mov rdi, [rip + ssb + SB_ptr]
    mov rsi, [rip + ssb + SB_len]
    call mem_dup
    mov [r12 + AQ_sugg], rax
    mov rax, [rip + ssb + SB_len]
    mov [r12 + AQ_sugglen], rax
    mov eax, [rip + own_dest]
    mov [r14 + CD_dest], eax
    mov rdi, r13
    call find_last_mode
    mov rdi, r13
    call rule_button
8:  mov rdi, r14
    lea rsi, [rip + .Lb_no]
    mov edx, CBA_NO
    xor ecx, ecx
    call agentcard_btn
    lea rdi, [rip + .Lph_field]
    call strlen
    mov rdi, r14
    mov esi, CDT_PH
    lea rdx, [rip + .Lph_field]
    mov rcx, rax
    call agentcard_text
    xor ebx, ebx                # the places
9:  cmp ebx, D_COUNT
    jae 10f
    lea rax, [rip + dest_ids]
    mov rsi, [rax + rbx*8]
    lea rax, [rip + dest_labels]
    mov rdx, [rax + rbx*8]
    lea rax, [rip + dest_tips]
    mov rcx, [rax + rbx*8]
    mov rdi, r14
    call agentcard_dest
    inc ebx
    jmp 9b
10: EPILOGUE

# hook_cut(ptr, len) -> rax its length at most HOOK_MAX characters (cut at a character's start)
hook_cut:
    xor ecx, ecx                # bytes
    xor edx, edx                # characters
1:  cmp rcx, rsi
    jae 8f
    movzx eax, byte ptr [rdi + rcx]
    and eax, 0xc0
    cmp eax, 0x80
    je 2f
    cmp edx, HOOK_MAX
    jae 8f
    inc edx
2:  inc rcx
    jmp 1b
8:  mov rax, rcx
    ret

# find_last_mode(request jv): lm_ptr/lm_len, the mode of the m_last-th kept suggestion (a setMode)
find_last_mode:
    PROLOGUE
    mov qword ptr [rip + lm_ptr], 0
    mov qword ptr [rip + lm_len], 0
    cmp qword ptr [rip + m_last], 0
    jl 9f
    lea rsi, [rip + .Lk_suggestions]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_len
    mov r13d, eax
    xor r14d, r14d
    xor r15d, r15d              # kept so far
1:  cmp r14d, r13d
    jae 9f
    mov rdi, r12
    mov esi, r14d
    inc r14d
    call json_at
    mov rbx, rax
    mov rdi, rax
    call type_of
    test eax, eax
    jz 1b
    cmp eax, SG_SETMODE
    jne 2f
    mov rdi, rbx
    lea rsi, [rip + .Lk_mode]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_bypass]
    call json_is
    test eax, eax
    jz 11f
    mov rdi, [rip + al_now]
    call bypass_ok
    test eax, eax
    jz 1b
11: cmp r15, [rip + m_last]
    jne 2f
    mov rdi, rbx
    lea rsi, [rip + .Lk_mode]
    call in_str
    mov [rip + lm_ptr], rax
    mov [rip + lm_len], rdx
    EPILOGUE
2:  inc r15
    jmp 1b
9:  EPILOGUE

# FN claude_card_show(AL*, AQ*) -> eax 1 shown: the card's first place (the project's remembered one: one
#   of the four, else this session; none remembered: the suggestions' own), then ev_card
FN claude_card_show
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, [r12 + AQ_card]
    xor eax, eax
    test r13, r13
    jz 9f
    cmp dword ptr [r12 + AQ_kind], AQK_PLAN     # plan review: the card, then its tab
    je .Lcs_plan
    test dword ptr [r13 + CD_flags], CDF_SHOWN
    jnz 8f
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r14, rax
    mov rdi, rax
    call agentcfg_need
    lea rdi, [r14 + AGC_dest]
    cmp byte ptr [rdi], 0
    je 8f
    call strlen
    lea rdi, [r14 + AGC_dest]
    mov rsi, rax
    call dest_index
    test eax, eax
    jns 1f
    mov eax, D_SESSION          # remembered, but none of the four
1:  mov [r13 + CD_dest], eax
8:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call ev_card
9:  EPILOGUE

# ---------------------------------------------------------------- the answers

# FN claude_reply(AL*, AQ*, CD*) -> eax 1 when the card's answer was written, or the request went with the
#   connection a write broke; 0 when the request is not the one on show or the action is unknown. A write
#   that is refused shows the card again with a toast (claude_req_after)
FN claude_reply
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor eax, eax
    cmp qword ptr [rbx + AL_reqs + VEC_len], 0
    je 9f
    mov rcx, [rbx + AL_reqs + VEC_ptr]
    cmp [rcx], r12
    jne 9f
    mov [rip + al_now], rbx
    cmp dword ptr [r12 + AQ_kind], AQK_PLAN     # plan review: a plan's answers
    je .Lcr_plan
    mov eax, [r13 + CD_chosen]
    cmp eax, CBA_YES
    je .Lcr_yes
    cmp eax, CBA_RULE
    je .Lcr_rule
    cmp eax, CBA_NO
    je .Lcr_no
    cmp eax, CBA_SUBMIT             # the question card's "Submit answers"
    je .Lcr_submit
    xor eax, eax
    EPILOGUE
.Lcr_submit:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call write_answers
    jmp .Lcr_after
.Lcr_yes:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    xor ecx, ecx
    call write_allow
    jmp .Lcr_after
.Lcr_rule:
    cmp qword ptr [r12 + AQ_sugg], 0
    je .Lcr_yes
    mov rdi, r12                # a setMode for this session: the mode first
    call session_mode
    test eax, eax
    jz 1f
    mov rdi, rbx
    lea rsi, [rip + mbuf]
    call claude_mode_quiet
    test eax, eax
    jz .Lcr_after               # refused: nothing went
    mov rdi, rbx
    mov rsi, r12
    call claude_req_kept
    test eax, eax
    jz .Lcr_gone                # the write broke the connection: the request went with it
1:  mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, 1
    call write_allow
    jmp .Lcr_after
.Lcr_no:
    lea rdi, [r13 + CD_field]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call trim
    test rdx, rdx
    jz 2f
    mov r14, rax
    mov r15, rdx
    lea rdi, [rip + msb]
    call sb_clear
    lea rdi, [rip + msb]
    lea rsi, [rip + .Lr_reason]
    call sb_push_cstr
    lea rdi, [rip + msb]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + msb]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rip + msb + SB_ptr]
    mov rcx, [rip + msb + SB_len]
    xor r8d, r8d
    call write_deny
    jmp .Lcr_after
2:  lea rdi, [rip + .Lr_rejected]
    call strlen
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lr_rejected]
    mov rcx, rax
    mov r8d, 1
    call write_deny
.Lcr_after:
    mov rdi, rbx
    mov rsi, r12
    mov edx, eax
    call claude_req_after
.Lcr_gone:
    mov eax, 1
9:  EPILOGUE

# session_mode(AQ*) -> eax 1 when a kept setMode's destination is session: its mode in mbuf
session_mode:
    PROLOGUE
    mov rbx, rdi
    mov rdi, [rbx + AQ_sugg]
    mov rsi, [rbx + AQ_sugglen]
    mov edx, LINE_VALUES
    mov ecx, LINE_DEPTH
    call json_parse_lim
    test rax, rax
    jz 8f
    mov r12, rax
    mov rdi, rax
    call json_len
    mov r13d, eax
    xor r14d, r14d
1:  cmp r14d, r13d
    jae 8f
    mov rdi, r12
    mov esi, r14d
    inc r14d
    call json_at
    mov r15, rax
    mov rdi, rax
    call type_of
    cmp eax, SG_SETMODE
    jne 1b
    mov rdi, r15
    lea rsi, [rip + .Lk_destination]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_session]
    call json_is
    test eax, eax
    jz 1b
    mov rdi, r15
    lea rsi, [rip + .Lk_mode]
    call in_str
    test rdx, rdx
    jz 1b
    cmp rdx, 39
    ja 1b
    mov rsi, rax
    lea rdi, [rip + mbuf]
    mov rcx, rdx
    rep movsb
    mov byte ptr [rdi], 0
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# write_allow(AL*, AQ*, CD*, with the rules) -> eax 1 written: {"behavior":"allow","updatedInput":INPUT
#   [,"updatedPermissions":[...]],"toolUseID":ID}; the input with the command as edited
write_allow:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov [rsp], ecx
    mov rdi, rbx
    mov rsi, r12
    call claude_reply_begin
    lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lk_behavior]
    call jw_key
    lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lv_allow]
    call jw_cstr
    lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lk_updatedInput]
    call jw_key
    test dword ptr [r13 + CD_flags], CDF_EDIT
    jz 1f
    mov rdi, r12
    mov rsi, r13
    call write_edited
    test eax, eax
    jnz 2f
1:  lea rdi, [rip + claude_cw]
    mov rsi, [r12 + AQ_input]
    mov rdx, [r12 + AQ_inlen]
    call jw_rawn
2:  cmp dword ptr [rsp], 0
    je 8f
    lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lk_updatedPermissions]
    call jw_key
    mov rdi, r12
    mov rsi, r13
    call write_rules
8:  mov rdi, rbx
    mov rsi, r12
    call claude_reply_end
    EPILOGUE

# write_edited(AQ*, CD*) -> eax 1 when the input went with the edited command (member by member); 0 when
#   the command was not changed (nothing written: the input goes as it came)
write_edited:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + AQ_input]
    mov rsi, [rbx + AQ_inlen]
    mov edx, LINE_VALUES
    mov ecx, LINE_DEPTH
    call json_parse_lim
    test rax, rax
    jz 8f
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_command]
    call in_str
    mov r14, rax
    mov r15, rdx
    lea rdi, [r12 + CD_edit]
    call tf_text
    cmp rdx, r15
    jne 1f
    mov rdi, rax
    mov rsi, r14
    call memeq
    test eax, eax
    jnz 8f                      # unchanged
1:  lea rdi, [rip + claude_cw]
    call jw_obj
    xor r14d, r14d
2:  mov rdi, r13
    call json_npairs
    cmp r14d, eax
    jae 4f
    mov rdi, r13
    mov esi, r14d
    inc r14d
    call json_pair
    mov r15, rdx
    mov rdi, rax
    call json_str
    mov rbx, rax
    push rdx
    push rdx
    lea rdi, [rip + claude_cw]
    mov rsi, rax
    call jw_keyn
    pop rdx
    pop rdx
    mov rdi, rbx
    mov rsi, rdx
    lea rdx, [rip + .Lk_command]
    call str_eq_cstr
    test eax, eax
    jz 3f
    lea rdi, [r12 + CD_edit]
    call tf_text
    lea rdi, [rip + claude_cw]
    mov rsi, rax
    call jw_str
    jmp 2b
3:  lea rdi, [rip + claude_cw]
    mov rsi, r15
    call jw_jv
    jmp 2b
4:  lea rdi, [rip + claude_cw]
    call jw_end_obj
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# write_rules(AQ*, CD*): the kept suggestions, each member as it came but the destination: the card's
#   place (a setMode keeps its own)
write_rules:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + CD_dest]
    cmp eax, D_COUNT
    jb 1f
    mov eax, D_SESSION
1:  lea rcx, [rip + dest_ids]
    mov rax, [rcx + rax*8]
    mov [rsp], rax              # the place's id
    mov rdi, [rbx + AQ_sugg]
    mov rsi, [rbx + AQ_sugglen]
    mov edx, LINE_VALUES
    mov ecx, LINE_DEPTH
    call json_parse_lim
    mov r13, rax
    lea rdi, [rip + claude_cw]
    call jw_arr
    test r13, r13
    jz 8f
    xor r14d, r14d
2:  mov rdi, r13
    call json_len
    cmp r14d, eax
    jae 8f
    mov rdi, r13
    mov esi, r14d
    inc r14d
    call json_at
    mov r15, rax
    mov rdi, rax
    call type_of
    mov [rsp + 8], eax
    lea rdi, [rip + claude_cw]
    call jw_obj
    xor ebx, ebx
3:  mov rdi, r15
    call json_npairs
    cmp ebx, eax
    jae 6f
    mov rdi, r15
    mov esi, ebx
    inc ebx
    call json_pair
    mov [rip + m_tmp_p], rdx    # the value
    mov rdi, rax
    call json_str
    mov [rip + m_tmp_n], rdx
    push rax
    push rax
    lea rdi, [rip + claude_cw]
    mov rsi, rax
    call jw_keyn
    pop rdi
    pop rdi
    mov rsi, [rip + m_tmp_n]
    lea rdx, [rip + .Lk_destination]
    call str_eq_cstr
    test eax, eax
    jz 5f
    cmp dword ptr [rsp + 8], SG_SETMODE
    je 5f
    lea rdi, [rip + claude_cw]
    mov rsi, [rsp]
    call jw_cstr
    jmp 3b
5:  lea rdi, [rip + claude_cw]
    mov rsi, [rip + m_tmp_p]
    call jw_jv
    jmp 3b
6:  lea rdi, [rip + claude_cw]
    call jw_end_obj
    jmp 2b
8:  lea rdi, [rip + claude_cw]
    call jw_end_arr
    EPILOGUE

# write_deny(AL*, AQ*, message ptr, len, interrupt) -> eax 1 written: {"behavior":"deny","message":M,
#   "interrupt":B,"toolUseID":ID}
write_deny:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15d, r8d
    call claude_reply_begin
    lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lk_behavior]
    call jw_key
    lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lv_deny]
    call jw_cstr
    lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lk_message]
    call jw_key
    lea rdi, [rip + claude_cw]
    mov rsi, r13
    mov rdx, r14
    call jw_str
    lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lk_interrupt]
    call jw_key
    lea rdi, [rip + claude_cw]
    mov esi, r15d
    call jw_bool
    mov rdi, rbx
    mov rsi, r12
    call claude_reply_end
    EPILOGUE

# ---------------------------------------------------------------- the question card
#
# AskUserQuestion (finding 23: questions {question, header, multiSelect, options [{label, description,
# preview}]}, the previews Markdown) as a CDK_QUESTIONS card: a question per tab, its options and Other
# (agentcard.s). A question that is not an object with a string "question", an option without a string
# "label", more than CDQ_MAX questions or CDQ_OPTS_MAX options a question: rhun cannot show it (the caller
# denies the request, as phase 1 does for cards it cannot show). The texts that go back as the answer's keys
# and values (the question, the labels) are kept whole (past QS_MAX bytes: not shown); the header, the
# descriptions and the previews are cut at a character's start. "Submit answers" allows with the input's
# members kept and "answers" {question: "label" | "a, b" | the Other text} (agentcard_qtext); the × and
# Escape are the card's No (claude_reply: phase 1's words, interrupt true, as the extension's onClose).
#
#   claude_question_build(AL*, AQ*, input jv) -> eax 1 the card made (AQ_card), 0 it cannot be shown

# q_member(jv, key, max) -> rax ptr, rdx len of a string member (rdx cut to max bytes at a character's
#   start), ecx 1 when it is a string (0: rax and rdx 0)
q_member:
    PROLOGUE
    mov r12d, edx
    call json_get
    mov rbx, rax
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne 8f
    mov rdi, rbx
    call json_str
    mov rbx, rax
    mov rdi, rdx
    mov rsi, rax
    mov edx, r12d
    call utf8_cut
    mov rdx, rax
    mov rax, rbx
    mov ecx, 1
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    xor ecx, ecx
    EPILOGUE

# q_cstr(sb, ptr, len) -> rax the bytes as a cstr in sb
q_cstr:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
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

# FN claude_question_build(AL*, AQ*, input jv) -> eax 1 when its card is made (AQ_card), 0 when rhun cannot
#   show it (nothing made). Locals: [rsp] the questions, [rsp + 8] a question, [rsp + 16] its options,
#   [rsp + 24] its CDQ*, [rsp + 32] the option, [rsp + 40] the preview's bytes
FN claude_question_build
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rdx
    lea rsi, [rip + .Lk_questions_q]
    call json_get
    mov [rsp], rax
    mov rdi, rax
    call json_len
    test eax, eax
    jz .Lqb_no
    cmp eax, CDQ_MAX
    ja .Lqb_no
    mov r15d, eax               # the questions
    mov edi, CDK_QUESTIONS
    call agentcard_new
    mov r13, rax
    mov [r12 + AQ_card], rax
    mov [rax + CD_token], r12
    lea rdx, [rip + .Lq_title_one]
    cmp r15d, 1
    je 1f
    lea rdx, [rip + .Lq_title_many]
1:  mov rdi, rdx
    push rdx
    push rdx
    call strlen
    pop rdx
    pop rdx
    mov rdi, r13
    mov esi, CDT_TITLE
    mov rcx, rax
    call agentcard_text
    mov rdi, r13
    lea rsi, [rip + .Lq_submit]
    mov edx, CBA_SUBMIT
    xor ecx, ecx
    call agentcard_btn
    xor r14d, r14d
.Lqb_q:
    cmp r14d, r15d
    jae .Lqb_done
    mov rdi, [rsp]
    mov esi, r14d
    inc r14d
    call json_at
    mov [rsp + 8], rax
    mov rdi, rax                # its text (an answer's key: whole)
    lea rsi, [rip + .Lk_question_q]
    mov edx, QS_MAX + 1
    call q_member
    test ecx, ecx
    jz .Lqb_fail
    cmp rdx, QS_MAX
    ja .Lqb_fail
    lea rdi, [rip + nsb]
    mov rsi, rax
    call q_cstr
    mov rdi, [rsp + 8]          # its header
    lea rsi, [rip + .Lk_header_q]
    mov edx, QHEAD_MAX
    call q_member
    lea rdi, [rip + hsb]
    mov rsi, rax
    call q_cstr
    mov rdi, [rsp + 8]
    lea rsi, [rip + .Lk_multi_q]
    call in_true
    mov ecx, eax
    mov rdi, r13
    mov rsi, [rip + hsb + SB_ptr]
    mov rdx, [rip + nsb + SB_ptr]
    call agentcard_question
    test rax, rax
    jz .Lqb_fail
    mov [rsp + 24], rax
    mov rdi, [rsp + 8]          # its options
    lea rsi, [rip + .Lk_options_q]
    call json_get
    mov [rsp + 16], rax
    mov rdi, rax
    call json_len
    cmp eax, CDQ_OPTS_MAX
    ja .Lqb_fail
    mov r12d, eax
    xor ebx, ebx
.Lqb_o:
    cmp ebx, r12d
    jae .Lqb_q
    mov rdi, [rsp + 16]
    mov esi, ebx
    inc ebx
    call json_at
    mov [rsp + 32], rax
    mov rdi, rax                # its label (an answer: whole)
    lea rsi, [rip + .Lk_label_q]
    mov edx, QS_MAX + 1
    call q_member
    test ecx, ecx
    jz .Lqb_fail
    cmp rdx, QS_MAX
    ja .Lqb_fail
    lea rdi, [rip + hsb]
    mov rsi, rax
    call q_cstr
    mov rdi, [rsp + 32]
    lea rsi, [rip + .Lk_desc_q]
    mov edx, QDESC_MAX
    call q_member
    lea rdi, [rip + nsb]
    mov rsi, rax
    call q_cstr
    mov rdi, [rsp + 32]
    lea rsi, [rip + .Lk_preview_q]
    mov edx, QPREVIEW_MAX
    call q_member
    mov [rsp + 40], rdx
    mov rcx, rax
    mov r8, rdx
    mov rdi, [rsp + 24]
    mov rsi, [rip + hsb + SB_ptr]
    mov rdx, [rip + nsb + SB_ptr]
    call agentcard_option
    jmp .Lqb_o
.Lqb_done:
    mov eax, 1
    EPILOGUE
.Lqb_fail:
    mov rax, [r13 + CD_token]   # (r12 holds a count here)
    mov qword ptr [rax + AQ_card], 0
    mov rdi, r13
    call agentcard_free
.Lqb_no:
    xor eax, eax
    EPILOGUE

# write_answers(AL*, AQ*, CD*) -> eax 1 written: {"behavior":"allow","updatedInput":{the input's members but
#   "answers", "answers":{QUESTION:ANSWER,...}},"toolUseID":ID}, the answers from the card (agentcard_qtext)
write_answers:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, [r12 + AQ_input]
    mov rsi, [r12 + AQ_inlen]
    mov edx, LINE_VALUES
    mov ecx, LINE_DEPTH
    call json_parse_lim
    mov r14, rax
    test rax, rax
    jnz 1f
    lea rdi, [rip + .Lq_noecho]
    call strlen
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lq_noecho]
    mov rcx, rax
    xor r8d, r8d
    call write_deny
    EPILOGUE
1:  mov rdi, rbx
    mov rsi, r12
    call claude_reply_begin
    lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lk_behavior]
    call jw_key
    lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lv_allow]
    call jw_cstr
    lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lk_updatedInput]
    call jw_key
    lea rdi, [rip + claude_cw]
    call jw_obj
    xor r15d, r15d
2:  mov rdi, r14                # the input's members but its answers
    call json_npairs
    cmp r15d, eax
    jae 3f
    mov rdi, r14
    mov esi, r15d
    inc r15d
    call json_pair
    mov [rsp], rdx
    mov rdi, rax
    call json_str
    mov [rsp + 8], rax
    push rdx
    push rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lk_answers_q]
    call str_eq_cstr
    pop rdx
    pop rdx
    test eax, eax
    jnz 2b
    lea rdi, [rip + claude_cw]
    mov rsi, [rsp + 8]
    call jw_keyn
    lea rdi, [rip + claude_cw]
    mov rsi, [rsp]
    call jw_jv
    jmp 2b
3:  lea rdi, [rip + claude_cw]
    lea rsi, [rip + .Lk_answers_q]
    call jw_key
    lea rdi, [rip + claude_cw]
    call jw_obj
    xor r15d, r15d
4:  cmp r15, [r13 + CD_qs + VEC_len]
    jae 5f
    mov rax, [r13 + CD_qs + VEC_ptr]
    mov r14, [rax + r15*8]
    inc r15
    mov rdi, [r14 + CDQ_text]
    call strlen
    lea rdi, [rip + claude_cw]
    mov rsi, [r14 + CDQ_text]
    mov rdx, rax
    call jw_keyn
    lea rdi, [rip + msb]
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + msb]
    call agentcard_qtext
    lea rdi, [rip + claude_cw]
    mov rsi, [rip + msb + SB_ptr]
    mov rdx, [rip + msb + SB_len]
    call jw_str
    jmp 4b
5:  lea rdi, [rip + claude_cw]
    call jw_end_obj             # the answers
    lea rdi, [rip + claude_cw]
    call jw_end_obj             # updatedInput
    mov rdi, rbx
    mov rsi, r12
    call claude_reply_end
    EPILOGUE

.section .rodata
.Lq_title_one: .asciz "Question"
.Lq_title_many: .asciz "Questions"
.Lq_submit: .asciz "Submit answers"
.Lq_noecho: .asciz "rhun cannot pass this input back unchanged"
.Lk_questions_q: .asciz "questions"
.Lk_question_q: .asciz "question"
.Lk_header_q: .asciz "header"
.Lk_multi_q: .asciz "multiSelect"
.Lk_options_q: .asciz "options"
.Lk_label_q: .asciz "label"
.Lk_desc_q: .asciz "description"
.Lk_preview_q: .asciz "preview"
.Lk_answers_q: .asciz "answers"
.text

# ---------------------------------------------------------------- plan review (task 11)
#
# ExitPlanMode's card (CDK_PLAN; agentcard.s draws its comments and header): "1 Yes, and use auto mode"
# when auto mode is offered for the model (claude_modes), else "1 Yes, and auto-accept"; "2 Yes, and
# manually approve edits"; "3 No, keep planning"; the field; "Send feedback and keep planning" shows only
# with comments. When the card shows, the plan opens in a tab ("Plan", mdtab.s) whose comments go to the
# card; the card's answer, a withdrawal or the process's end close it (agent_aq_free -> mdtab_drop). The
# answers are the extension's (webview index.js @5657000-5662000; finding 24):
#   auto: set_permission_mode auto, and when its answer is an error acceptEdits, then allow with the input;
#   auto-accept: set_permission_mode acceptEdits, then allow; manual: set_permission_mode default, then
#   allow with updatedPermissions [{"type":"setMode","mode":"default","destination":"session"}];
#   No and Send feedback: deny, its message `Xb` " " TEXT or "User chose to stay in plan mode and continue
#   planning", then with comments "\n\nComments on the plan:\n" and a line `[Re: "QUOTE"] COMMENT` each;
#   interrupt only without text and comments.
# /plan in plan mode asks get_plan and shows its content in a tab without comments (claude_plan_answer):
# "Already in plan mode. No plan written yet." without one, "Couldn't show the plan" on an error.
#
#   claude_plan_build(AL*, AQ*)               the card (AQ_card), the manual answer's rule (AQ_sugg)
#   claude_plan_mode_answer(AL*, response)   set_permission_mode auto's answer: the allow follows
#   claude_plan_answer(AL*, response)        get_plan's

# FN claude_plan_build(AL*, AQ*): ExitPlanMode's card
FN claude_plan_build
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov edi, CDK_PLAN
    call agentcard_new
    mov r13, rax
    mov [r12 + AQ_card], rax
    mov [rax + CD_token], r12
    lea rdi, [rip + .Lpl_rule]  # the manual answer's update, sent as a kept suggestion is (write_rules)
    call strlen
    mov r14, rax
    lea rdi, [rip + .Lpl_rule]
    mov rsi, rax
    call mem_dup
    mov [r12 + AQ_sugg], rax
    mov [r12 + AQ_sugglen], r14
    lea r14, [rip + .Lpl_accept]
    mov r15d, CBA_YES
    mov rdi, rbx
    call plan_auto
    test eax, eax
    jz 1f
    lea r14, [rip + .Lpl_auto]
    mov r15d, CBA_YES_AUTO
1:  mov rdi, r13
    mov rsi, r14
    mov edx, r15d
    xor ecx, ecx
    call agentcard_btn
    mov rdi, r13
    lea rsi, [rip + .Lpl_manual]
    mov edx, CBA_YES_MANUAL
    xor ecx, ecx
    call agentcard_btn
    mov rdi, r13
    lea rsi, [rip + .Lpl_no]
    mov edx, CBA_NO
    xor ecx, ecx
    call agentcard_btn
    mov rdi, r13
    lea rsi, [rip + .Lpl_feedback]
    mov edx, CBA_FEEDBACK
    xor ecx, ecx
    call agentcard_btn
    lea rdi, [rip + .Lph_field]
    call strlen
    mov rdi, r13
    mov esi, CDT_PH
    lea rdx, [rip + .Lph_field]
    mov rcx, rax
    call agentcard_text
    EPILOGUE

# plan_auto(AL*) -> eax 1 when auto mode is offered now (the mode picker's rule: claude_modes)
plan_auto:
    PROLOGUE 16
    mov rdi, [rdi + AL_as]
    lea rsi, [rsp]
    call claude_modes
    mov r12d, eax
    mov rbx, [rsp]
    xor r13d, r13d
1:  cmp r13d, r12d
    jae 8f
    imul rax, r13, AMD_SIZE
    mov rdi, [rbx + rax + AMD_id]
    lea rsi, [rip + .Lv_auto]
    call strcmp_eq
    test eax, eax
    jnz 9f
    inc r13d
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# .Lcs_plan: claude_card_show's part for a plan (rbx AL*, r12 AQ*, r13 CD*): the card, then its tab (once)
.Lcs_plan:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call ev_card
    mov r14d, eax
    test eax, eax
    jz 9f
    test dword ptr [r12 + AQ_state], PLS_TABBED
    jnz 9f
    or dword ptr [r12 + AQ_state], PLS_TABBED
    mov rdi, [r12 + AQ_input]   # the plan (parsed again: the arena is global)
    mov rsi, [r12 + AQ_inlen]
    mov edx, LINE_VALUES
    mov ecx, LINE_DEPTH
    call json_parse_lim
    test rax, rax
    jz 9f
    mov rdi, rax
    lea rsi, [rip + .Lk_plan]
    call in_str
    lea rdi, [rip + .Lpl_title]
    mov rsi, rax
    lea rcx, [rip + plan_mdo]
    mov r8, r12
    call mdtab_open
    test rax, rax
    js 9f
    mov [r12 + AQ_tab], r12     # its ctx: the request
9:  mov eax, r14d
    EPILOGUE

# plan_on_comment(ctx AQ*, quote ptr, len, text ptr, len): a comment from its tab onto its card
plan_on_comment:
    mov rdi, [rdi + AQ_card]
    test rdi, rdi
    jz 1f
    jmp agentcard_comment
1:  ret

# plan_on_closed(ctx AQ*): the user closed its tab (nothing is sent)
plan_on_closed:
    mov qword ptr [rdi + AQ_tab], 0
    ret

# .Lcr_plan: claude_reply's part for a plan (rbx AL*, r12 AQ*, r13 CD*); nothing while an auto Yes waits
.Lcr_plan:
    test dword ptr [r12 + AQ_state], PLS_MODEWAIT
    jnz .Lcr_gone
    mov eax, [r13 + CD_chosen]
    lea r14, [rip + .Lv_accept]
    xor r15d, r15d
    cmp eax, CBA_YES
    je .Lpr_mode
    lea r14, [rip + .Lv_default]
    mov r15d, 1
    cmp eax, CBA_YES_MANUAL
    je .Lpr_mode
    cmp eax, CBA_YES_AUTO
    je .Lpr_auto
    cmp eax, CBA_NO
    je .Lpr_no
    cmp eax, CBA_FEEDBACK
    je .Lpr_no
    xor eax, eax
    EPILOGUE
.Lpr_mode:                      # the mode first (its line finished), then the allow
    mov rdi, rbx
    mov rsi, r14
    call claude_mode_quiet
    test eax, eax
    jz .Lcr_after               # refused: nothing went
    mov rdi, rbx
    mov rsi, r12
    call claude_req_kept
    test eax, eax
    jz .Lcr_gone
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, r15d
    call write_allow
    jmp .Lcr_after
.Lpr_auto:                      # auto first; its answer sends the allow (claude_plan_mode_answer)
    mov rdi, rbx
    lea rsi, [rip + .Lv_auto]
    call claude_mode_plan
    test eax, eax
    jz .Lcr_after
    mov rdi, rbx
    mov rsi, r12
    call claude_req_kept
    test eax, eax
    jz .Lcr_gone
    or dword ptr [r12 + AQ_state], PLS_MODEWAIT
    jmp .Lcr_gone
.Lpr_no:
    lea rdi, [r13 + CD_field]
    call tf_text
    mov rdi, rax
    mov rsi, rdx
    call trim
    mov r14, rax
    mov r15, rdx
    lea rdi, [rip + msb]
    call sb_clear
    test r15, r15
    jz 1f
    lea rdi, [rip + msb]        # the extension's reason, a space, the text
    lea rsi, [rip + .Lr_reason]
    call sb_push_cstr
    lea rdi, [rip + msb]
    mov esi, ' '
    call sb_push_byte
    lea rdi, [rip + msb]
    mov rsi, r14
    mov rdx, r15
    call sb_push
    jmp 2f
1:  lea rdi, [rip + msb]        # else: keep planning
    lea rsi, [rip + .Lpl_keep]
    call sb_push_cstr
2:  cmp qword ptr [r13 + CD_comments + VEC_len], 0
    je 5f
    lea rdi, [rip + msb]
    lea rsi, [rip + .Lpl_comments]
    call sb_push_cstr
    xor r14d, r14d
3:  cmp r14, [r13 + CD_comments + VEC_len]
    jae 5f
    test r14, r14
    jz 4f
    lea rdi, [rip + msb]
    mov esi, 10
    call sb_push_byte
4:  imul rax, r14, CDC_SIZE
    add rax, [r13 + CD_comments + VEC_ptr]
    push rax
    push rax
    lea rdi, [rip + msb]
    lea rsi, [rip + .Lpl_re]
    call sb_push_cstr
    mov rax, [rsp]
    lea rdi, [rip + msb]
    mov rsi, [rax + CDC_quote]
    call sb_push_cstr
    lea rdi, [rip + msb]
    lea rsi, [rip + .Lpl_re_end]
    call sb_push_cstr
    pop rax
    pop rax
    lea rdi, [rip + msb]
    mov rsi, [rax + CDC_text]
    call sb_push_cstr
    inc r14
    jmp 3b
5:  xor r8d, r8d                # interrupt: neither text nor comments
    test r15, r15
    jnz 6f
    cmp qword ptr [r13 + CD_comments + VEC_len], 0
    jne 6f
    mov r8d, 1
6:  mov rdi, rbx
    mov rsi, r12
    mov rdx, [rip + msb + SB_ptr]
    mov rcx, [rip + msb + SB_len]
    call write_deny
    jmp .Lcr_after

# FN claude_plan_mode_answer(AL*, control_response's response): set_permission_mode auto's answer for the
#   plan whose Yes waits: in effect, or refused and acceptEdits asked instead; then the allow with the input
FN claude_plan_mode_answer
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d              # the plan waiting
    cmp qword ptr [rbx + AL_reqs + VEC_len], 0
    je 1f
    mov rax, [rbx + AL_reqs + VEC_ptr]
    mov rax, [rax]
    cmp dword ptr [rax + AQ_kind], AQK_PLAN
    jne 1f
    test dword ptr [rax + AQ_state], PLS_MODEWAIT
    jz 1f
    mov r13, rax
    and dword ptr [r13 + AQ_state], ~PLS_MODEWAIT
1:  mov rdi, r12
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_success]
    call json_is
    mov r14d, eax
    mov rdi, rbx                # the mode in effect (an error changes nothing)
    mov rsi, r12
    xor edx, edx
    call claude_mode_answer
    test r13, r13
    jz 9f                       # withdrawn meanwhile: nothing more
    test r14d, r14d
    jnz 2f
    mov rdi, rbx                # refused: acceptEdits instead
    lea rsi, [rip + .Lv_accept]
    call claude_mode_quiet
    test eax, eax
    jz 3f
    mov rdi, rbx
    mov rsi, r13
    call claude_req_kept
    test eax, eax
    jz 9f
2:  mov rdi, rbx
    mov rsi, r13
    mov rdx, [r13 + AQ_card]
    xor ecx, ecx
    call write_allow
3:  mov rdi, rbx
    mov rsi, r13
    mov edx, eax
    call claude_req_after
9:  EPILOGUE

# FN claude_plan_answer(AL*, control_response's response): get_plan's: its content in a tab of its own (no
#   comments), else the extension's info row
FN claude_plan_answer
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rip + .Lpl_unshown]
    mov rdi, r12
    lea rsi, [rip + .Lk_subtype]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_success]
    call json_is
    test eax, eax
    jz 8f
    mov rdi, r12
    lea rsi, [rip + .Lk_response]
    call json_get
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_exists]
    call in_true
    test eax, eax
    jnz 1f
    lea r13, [rip + .Lpl_none]
    jmp 8f
1:  mov rdi, r14
    lea rsi, [rip + .Lk_content]
    call in_str
    test rax, rax
    jz 8f
    lea rdi, [rip + .Lpl_title]
    mov rsi, rax
    xor ecx, ecx
    xor r8d, r8d
    call mdtab_open
    test rax, rax
    jns 9f
8:  mov rdi, r13
    call strlen
    mov rdi, rbx
    mov esi, PL_INFO
    mov rdx, r13
    mov rcx, rax
    call ev_note
9:  EPILOGUE

.bss
.p2align 3
al_now: .quad 0                 # the conversation the card is made or answered for
m_tmp_p: .quad 0
m_tmp_n: .quad 0
lm_ptr: .quad 0                 # the last kept setMode's mode (find_last_mode)
lm_len: .quad 0

.section .rodata
.p2align 3
headers:                        # a tool's name, its header's maker (-> eax 0: the fallback instead)
    .quad .Lt_bash, h_bash
    .quad .Lt_pwsh, h_pwsh
    .quad .Lt_edit, h_edit
    .quad .Lt_multiedit, h_edit
    .quad .Lt_write, h_write
    .quad .Lt_read, h_read
    .quad .Lt_glob, h_glob
    .quad .Lt_grep, h_grep
    .quad .Lt_search, h_search
    .quad .Lt_webfetch, h_fetch
    .quad .Lt_websearch, h_websearch
    .quad .Lt_net, h_net
    .quad .Lt_skill, h_skill
    .quad .Lt_project, h_project
    .quad 0, 0
dest_ids: .quad .Lv_local, .Lv_user, .Lv_project, .Lv_session
dest_labels: .quad .Ld_local, .Ld_user, .Ld_project, .Ld_session
dest_tips: .quad .Lp_local, .Lp_user, .Lp_project, .Lp_session
type_names: .quad .Lv_add, .Lv_replace, .Lv_remove, .Lv_adddir, .Lv_removedir, .Lv_setmode
beh_words: .quad .Lx_allows, .Lx_denies, .Lx_asks
mode_names:                     # a mode's id, its label (claude_session.s's)
    .quad .Lv_dont_ask, .Lml_dont_ask, .Lv_default, .Lml_default, .Lv_accept, .Lml_accept
    .quad .Lv_plan, .Lml_plan, .Lv_auto, .Lml_auto, .Lv_bypass, .Lml_bypass, 0, 0
.p2align 2
dest_rank: .long 2, 0, 1, 3     # the four's width (the extension's SPn: user, project, local, session)
.Lt_bash: .asciz "Bash"
.Lt_pwsh: .asciz "PowerShell"
.Lt_edit: .asciz "Edit"
.Lt_multiedit: .asciz "MultiEdit"
.Lt_write: .asciz "Write"
.Lt_read: .asciz "Read"
.Lt_glob: .asciz "Glob"
.Lt_grep: .asciz "Grep"
.Lt_search: .asciz "Search"
.Lt_webfetch: .asciz "WebFetch"
.Lt_websearch: .asciz "WebSearch"
.Lt_net: .asciz "SandboxNetworkAccess"
.Lt_skill: .asciz "Skill"
.Lt_project: .asciz "SendToProject"
.Lq_allow_this: .asciz "Allow this "
.Lq_command: .asciz " command?"
.Lw_bash: .asciz "bash"
.Lw_pwsh: .asciz "PowerShell"
.Lq_edit: .asciz "Make this edit to "
.Lq_write: .asciz "Allow write to "
.Lq_read: .asciz "Allow reading from "
.Lq_mark: .asciz "?"
.Lq_glob_in: .asciz "Allow glob search in "
.Lq_glob: .asciz "Allow this glob command"
.Lq_grep_in: .asciz "Allow grep in "
.Lq_grep: .asciz "Allow this grep command"
.Lq_search_in: .asciz "Allow searching in "
.Lq_search: .asciz "Allow this search"
.Lq_fetch: .asciz "Allow fetching this url?"
.Lq_websearch: .asciz "Allow searching for this query?"
.Lq_net: .asciz "Allow network connection to this host?"
.Lq_skill: .asciz "Use skill /"
.Lq_skill_note: .asciz "Claude may use instructions, code, or files from this skill."
.Lq_arguments: .asciz "Arguments: "
.Lq_proj_create: .asciz "Create the Claude Project \342\200\234"
.Lq_proj_create_end: .asciz "\342\200\235 and send this message?"
.Lq_proj_send: .asciz "Send this message to the Claude Project \342\200\234"
.Lq_proj_send_end: .asciz "\342\200\235?"
.Lq_proj_scroll: .asciz "Scroll to the end of the message before approving it."
.Lq_proj_origin: .asciz "This folder\342\200\231s GitHub origin, "
.Lq_proj_origin_end: .asciz ", is added as the project\342\200\231s repository, so its threads start from what\342\200\231s on GitHub."
.Lq_proceed: .asciz "Do you want to proceed with "
.Lw_allowed: .asciz "Allowed: "
.Lw_blocked: .asciz "Blocked: "
.Lw_dot: .asciz " \302\267 "
.Lw_comma: .asciz ", "
.Lw_colon: .asciz ": "
.Lw_paren: .asciz "("
.Lw_paren_end: .asciz ")"
.Lw_slash: .asciz "/"
.Lellipsis: .asciz "\342\200\246"
.Lb_yes: .asciz "Yes"
.Lb_no: .asciz "No"
.Lb_allow: .asciz "Yes, allow "
.Lb_and: .asciz " and "
.Lb_more: .asciz " more"
.Lb_for: .asciz " for "
.Lb_access: .asciz "Yes, allow access to "
.Lb_dirs: .asciz " directories"
.Lb_all_edits: .asciz "Yes, allow all edits this session"
.Lb_normal: .asciz "Yes, return to normal mode"
.Lb_dont_ask: .asciz "Yes, and don't ask again"
.Lph_field: .asciz "Tell Claude what to do instead"
.Lx_allows: .asciz "Also allows "
.Lx_denies: .asciz "Also denies "
.Lx_asks: .asciz "Also asks before "
.Lx_access: .asciz "Also allows access to "
.Lx_unaccess: .asciz "Also removes access to "
.Lx_replace: .asciz "Also replaces the rules with "
.Lx_remove: .asciz "Also removes the rule "
.Lx_switch: .asciz "Also switches to \342\200\234"
.Lx_switch_end: .asciz "\342\200\235 for this session"
.Lx_makes: .asciz "Also makes \342\200\234"
.Lx_makes_mid: .asciz "\342\200\235 the default mode for "
.Lv_local: .asciz "localSettings"
.Lv_user: .asciz "userSettings"
.Lv_project: .asciz "projectSettings"
.Lv_session: .asciz "session"
.Lv_cliarg: .asciz "cliArg"
.Lv_cliarg_label: .asciz "startup options"
.Ld_local: .asciz "this project (just you)"
.Ld_user: .asciz "all projects"
.Ld_project: .asciz "this project (shared)"
.Ld_session: .asciz "this session"
.Lp_local: .asciz "Saves to .claude/settings.local.json (gitignored)"
.Lp_user: .asciz "Saves to ~/.claude/settings.json"
.Lp_project: .asciz "Saves to .claude/settings.json (shared with team)"
.Lp_session: .asciz "Only for this session (not saved)"
.Lv_add: .asciz "addRules"
.Lv_replace: .asciz "replaceRules"
.Lv_remove: .asciz "removeRules"
.Lv_adddir: .asciz "addDirectories"
.Lv_removedir: .asciz "removeDirectories"
.Lv_setmode: .asciz "setMode"
.Lv_dont_ask: .asciz "dontAsk"
.Lv_default: .asciz "default"
.Lv_accept: .asciz "acceptEdits"
.Lv_plan: .asciz "plan"
.Lv_auto: .asciz "auto"
.Lv_bypass: .asciz "bypassPermissions"
.Lml_dont_ask: .asciz "Don't ask"
.Lml_default: .asciz "Manual"
.Lml_accept: .asciz "Edit automatically"
.Lml_plan: .asciz "Plan"
.Lml_auto: .asciz "Auto"
.Lml_bypass: .asciz "Bypass permissions"
.Lv_hook: .asciz "hook"
.Lv_safety: .asciz "safetyCheck"
.Lv_subcommands: .asciz "subcommandResults"
.Lv_typed: .asciz "typed"
.Lv_drafted: .asciz "drafted"
.Lv_allow: .asciz "allow"
.Lv_deny: .asciz "deny"
.Lv_ask: .asciz "ask"
.Lk_input: .asciz "input"
.Lk_command: .asciz "command"
.Lk_description: .asciz "description"
.Lk_file_path: .asciz "file_path"
.Lk_path: .asciz "path"
.Lk_url: .asciz "url"
.Lk_host: .asciz "host"
.Lk_query: .asciz "query"
.Lk_allowed: .asciz "allowed_domains"
.Lk_blocked: .asciz "blocked_domains"
.Lk_skill: .asciz "skill"
.Lk_args: .asciz "args"
.Lk_from: .asciz "message_from"
.Lk_proposal: .asciz "proposal"
.Lk_summary: .asciz "summary"
.Lk_project_name: .asciz "project_name"
.Lk_project_id: .asciz "project_id"
.Lk_attach: .asciz "attach_git_remote"
.Lk_origin: .asciz "detected_origin"
.Lk_suppress: .asciz "suppress_always_allow_rule"
.Lk_defno: .asciz "default_to_no"
.Lk_reason_type: .asciz "decision_reason_type"
.Lk_reason: .asciz "decision_reason"
.Lk_suggestions: .asciz "permission_suggestions"
.Lk_type: .asciz "type"
.Lk_mode: .asciz "mode"
.Lk_destination: .asciz "destination"
.Lk_rules: .asciz "rules"
.Lk_directories: .asciz "directories"
.Lk_behavior: .asciz "behavior"
.Lk_tool_name_r: .asciz "toolName"
.Lk_rule_content: .asciz "ruleContent"
.Lk_updatedInput: .asciz "updatedInput"
.Lk_updatedPermissions: .asciz "updatedPermissions"
.Lk_message: .asciz "message"
.Lk_interrupt: .asciz "interrupt"
# the extension's rejection with a reason (webview index.js @5214814 `Xb`: it ends with a space)
.Lr_reason: .asciz "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). The user provided the following reason for the rejection: "
# phase 1's (`Yb`)
.Lr_rejected: .asciz "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."
# plan review (task 11): the plan card's words (webview index.js @5662587, @5664426), its answers
#   (@5214753 `zIe`, @5657000-5662000), /plan's rows (@5369281)
.Lpl_accept: .asciz "Yes, and auto-accept"
.Lpl_auto: .asciz "Yes, and use auto mode"
.Lpl_manual: .asciz "Yes, and manually approve edits"
.Lpl_no: .asciz "No, keep planning"
.Lpl_feedback: .asciz "Send feedback and keep planning"
.Lpl_title: .asciz "Plan"
.Lpl_keep: .asciz "User chose to stay in plan mode and continue planning"
.Lpl_comments: .asciz "\n\nComments on the plan:\n"
.Lpl_re: .asciz "[Re: \""
.Lpl_re_end: .asciz "\"] "
.Lpl_unshown: .asciz "Couldn't show the plan"
.Lpl_none: .asciz "Already in plan mode. No plan written yet."
.Lpl_rule: .asciz "[{\"type\":\"setMode\",\"mode\":\"default\",\"destination\":\"session\"}]"
.Lk_plan: .asciz "plan"
.Lk_exists: .asciz "exists"
.Lk_content: .asciz "content"
.Lk_subtype: .asciz "subtype"
.Lk_response: .asciz "response"
.Lv_success: .asciz "success"
.p2align 3
plan_mdo: .quad plan_on_comment, plan_on_closed     # its tab's owner (MDO, mdtab.s)
