# Claude Code's Permission rules and Sandbox dialogs (claude-chat-p7b; ext-webview-ui.md 6.9, 6.10), modules
# of claude_dlg2.s. They list what the session's process answers (list_permission_rules, get_sandbox_dialog)
# and change it only through `claude edit-permission-rules --json` and `claude edit-sandbox-settings --json`
# (README findings 84 and 85), then read it again until the process shows the change, 14 times 300 ms at
# most as the extension does (a notice says so when it does not).
.include "rhun.inc"

.equ PP_LIST, 0                 # Permission rules: pages
.equ PP_REMOVE, 1
.equ PP_ADD, 2
.equ PA_ADD, 1                  #   acts (arg: the behaviour)
.equ PA_RULE, 2                 #   (arg: the rule's index)
.equ PA_CONFIRM, 3
.equ PA_CANCEL, 4
.equ PA_SUBMIT, 5
.equ PA_DEST, 6                 #   (arg: the destination)
.equ PR_LIST, 1
.equ PW_ADD, 1
.equ PW_REMOVE, 2
.equ SA_MODE, 1                 # Sandbox: acts (arg: the mode's id cstr)
.equ SA_FALLBACK, 2
.equ SA_EXCLUDE, 3
.equ SR_DIALOG, 1
.equ SW_EDIT, 1
.equ TRIES, 14                  # re-reads after a write (300 ms apart)
.equ RULE_MAX, 400

.bss
.p2align 3
p_beh: .quad 0                  # the behaviour added or removed (0 allow, 1 ask, 2 deny)
p_dest: .quad 0                 # the add page's destination (0 local, 1 user, 2 project)
p_check: .quad 0                # 1: an added rule is waited for in the list, 2: a removed one to go
p_tries: .quad 0
p_rule: .quad 0                 # owned cstr: the rule written
p_src: .quad 0                  # owned cstr: its source (settings file id)
p_tf: .zero TF_SIZE             # the add page's field
s_tf: .zero TF_SIZE             # the sandbox's pattern field
s_want: .zero SB_SIZE           # the edit written, as JSON text (for its check)
s_tries: .quad 0
s_check: .quad 0                # 1 mode, 2 fallback, 3 an excluded pattern
s_bool: .quad 0
s_pat: .quad 0                  # owned cstr: the pattern to exclude after the first answer (/sandbox exclude)
s_mode: .quad 0                 # the mode written (static cstr)

.text

# ======================================================================================================
# Permission rules (6.9)
# ======================================================================================================

.globl perms_open, perms_act, perms_answer, perms_ran, perms_send, perms_free, perms_tick

perms_open:
    PROLOGUE
    mov qword ptr [rip + p_check], 0
    lea rdi, [rip + .Lp_loading]
    call agentdlg_loading
    mov edi, PR_LIST
    call c2_ask
    EPILOGUE

perms_free:
    PROLOGUE
    lea rdi, [rip + p_tf]
    call c2_wipe_tf
    call drop_rule
    mov qword ptr [rip + p_check], 0
    EPILOGUE

# drop_rule(): p_rule, p_src freed
drop_rule:
    PROLOGUE
    mov rdi, [rip + p_rule]
    call mem_free
    mov rdi, [rip + p_src]
    call mem_free
    mov qword ptr [rip + p_rule], 0
    mov qword ptr [rip + p_src], 0
    EPILOGUE

perms_send:
    mov rdi, rsi
    lea rsi, [rip + .Lv_list_rules]
    jmp claude_dlg2_begin

perms_tick:
    PROLOGUE
    mov edi, PR_LIST
    call c2_ask
    EPILOGUE

# perms_answer(rq, envelope): the list (its state kept), the check of a write
perms_answer:
    PROLOGUE
    mov rbx, rsi
    mov rdi, rbx
    call c2_ok
    test eax, eax
    jnz 1f
    call agentdlg_begin         # "Couldn't load permission rules from this session: ERR"
    call f_clr
    lea rdi, [rip + .Lp_failed]
    call f_c
    mov rdi, rbx
    call c2_why
    mov rdi, rax
    mov rsi, rdx
    mov edx, 2000
    call f_cl
    mov edi, DGF_ERROR
    call c2_ftext
    EPILOGUE
1:  mov rdi, rbx
    call c2_resp
    mov rdi, rax
    lea rsi, [rip + .Lk_state]
    call json_get
    mov rsi, rax
    lea rdi, [rip + c2_doc]
    call c2_keep
    cmp qword ptr [rip + p_check], 0
    je 8f
    call rule_listed            # the write's check
    mov ecx, 1
    cmp qword ptr [rip + p_check], 1
    je 2f
    xor ecx, ecx
2:  cmp eax, ecx
    je 5f
    cmp qword ptr [rip + p_tries], 0
    je 3f
    dec qword ptr [rip + p_tries]
    mov qword ptr [rip + c2_busy], 1    # (still busy: its button keeps its words)
    mov edi, 300
    call c2_later
    EPILOGUE
3:  call f_clr                  # not shown yet: the extension's notice
    cmp qword ptr [rip + p_check], 1
    jne 4f
    lea rdi, [rip + .Lp_saved_to]
    call f_c
    mov rdi, [rip + p_src]
    call src_label
    mov rdi, rax
    call f_c
    lea rdi, [rip + .Lp_not_listed]
    call f_c
    lea rdi, [rip + .Lp_not_listed_allow]
    cmp qword ptr [rip + p_beh], 0
    je 31f
    lea rdi, [rip + .Ldot]
31: call f_c
    jmp 41f
4:  lea rdi, [rip + .Lp_removed_from]
    call f_c
    mov rdi, [rip + p_src]
    call src_label
    mov rdi, rax
    call f_c
    lea rdi, [rip + .Lp_still_shown]
    call f_c
41: lea rdi, [rip + c2_msg]     # (after any warnings already there)
    mov rsi, [rip + fsb + SB_ptr]
    mov rdx, [rip + fsb + SB_len]
    call sb_push
5:  mov qword ptr [rip + p_check], 0
    mov qword ptr [rip + c2_busy], 0
    mov qword ptr [rip + c2_page], PP_LIST
    call drop_rule
8:  call perms_build
    EPILOGUE

# rule_listed() -> eax 1 when the kept state lists p_rule with p_beh and p_src
rule_listed:
    PROLOGUE
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rdi, rax
    lea rsi, [rip + .Lk_rules]
    call json_get
    mov rbx, rax
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
    mov rdi, rax
    lea rsi, [rip + .Lk_rule]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + p_rule]
    test rdx, rdx
    jz 8f
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rdi, r13
    lea rsi, [rip + .Lk_source]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + p_src]
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rdi, r13
    lea rsi, [rip + .Lk_behavior]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rax, [rip + p_beh]
    lea rcx, [rip + behaviors]
    mov rdx, [rcx + rax*8]
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# src_label(cstr or 0) -> rax its words (xU: "user settings", "project local settings", ...), else itself
src_label:
    PROLOGUE
    mov rbx, rdi
    lea rax, [rip + .Lempty]
    test rbx, rbx
    jz 9f
    lea r12, [rip + src_labels]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 8f
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jnz 2f
    add r12, 16
    jmp 1b
2:  mov rax, [r12 + 8]
    EPILOGUE
8:  mov rax, rbx
9:  EPILOGUE

# can_edit(state) -> eax 1 when rules may be added and removed here (not managedOnly)
can_edit:
    push rbx
    lea rsi, [rip + .Lk_managedOnly]
    call c2_jbool
    xor eax, 1
    pop rbx
    ret

# caption_f(rule): fsb = its source's caption (OPn): "From user settings", + " (not in effect)", or
#   " (this session only)" for cliArg
caption_f:
    PROLOGUE
    mov rbx, rdi
    call f_clr
    lea rdi, [rip + .Lp_from]
    call f_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_source]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov edx, 200
    call c2_clean
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r12, rax
    mov rdi, rax
    call src_label
    mov rdi, rax
    call f_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_notInEffect]
    call c2_jbool
    test eax, eax
    jz 1f
    lea rdi, [rip + .Lp_not_in_effect]
    call f_c
    jmp 2f
1:  mov rdi, r12
    lea rsi, [rip + .Lv_cliArg]
    call strcmp_eq
    test eax, eax
    jz 2f
    lea rdi, [rip + .Lp_session_only]
    call f_c
2:  mov rdi, r12
    call mem_free
    EPILOGUE

# desc_f(rule) -> eax 1 with fsb = its description (prefix, emphasis, suffix), 0 none
desc_f:
    PROLOGUE
    lea rsi, [rip + .Lk_description]
    call json_get
    mov rbx, rax
    xor eax, eax
    test rbx, rbx
    jz 9f
    call f_clr
    lea r12, [rip + desc_keys]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 2f
    mov rdi, rbx
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov edx, 400
    call f_cl
    add r12, 8
    jmp 1b
2:  mov eax, 1
9:  EPILOGUE

# readonly_f(rule) -> eax 1 with fsb = why it cannot be removed here (MPn), 0 when it can be
readonly_f:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    lea rsi, [rip + .Lk_notInEffect]
    call c2_jbool
    test eax, eax
    jnz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_editability]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_persistent]
    call str_eq_cstr
    test eax, eax
    jnz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_source]
    call c2_jstr
    mov r12, rax
    mov r13, rdx
    lea r14, [rip + ro_reasons]
1:  mov rdx, [r14]
    test rdx, rdx
    jz 2f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 2f
    add r14, 16
    jmp 1b
2:  call f_clr
    mov rdi, [r14 + 8]
    call f_c
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# perms_build(): the page shown
perms_build:
    PROLOGUE 32
    call agentdlg_begin
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax                # the state
    test rax, rax
    jz 9f
    mov rax, [rip + c2_page]
    cmp rax, PP_REMOVE
    je .Lpb_remove
    cmp rax, PP_ADD
    je .Lpb_add
    xor edi, edi
    call agentdlg_back
    mov rdi, rbx
    call can_edit
    mov [rsp], eax
    lea rdi, [rip + c2_err]     # (the list shows the notices; a write's error stays on its page)
    call sb_clear
    call c2_msgs
    mov rdi, rbx                # settings files that failed to load
    lea rsi, [rip + .Lk_errors]
    call json_get
    mov r12, rax
    xor r13d, r13d
1:  mov rdi, r12
    call json_len
    cmp r13d, eax
    jae 2f
    mov rdi, r12
    mov esi, r13d
    call json_at
    inc r13d
    mov r14, rax
    call f_clr
    lea rdi, [rip + .Lp_file_failed]
    call f_c
    mov rdi, r14
    lea rsi, [rip + .Lk_file]
    call c2_jstr
    test rdx, rdx
    jnz 11f
    lea rax, [rip + .Lv_unknown]
    mov edx, 7
11: mov rdi, rax
    mov rsi, rdx
    mov edx, 400
    call f_cl
    lea rdi, [rip + .Lp_dash]
    call f_c
    mov rdi, r14
    lea rsi, [rip + .Lk_message]
    mov edx, 800
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    lea rdi, [rip + .Lp_file_failed2]
    call f_c
    mov edi, DGF_ERROR
    call c2_ftext
    jmp 1b
2:  mov rdi, rbx
    lea rsi, [rip + .Lk_rules]
    call json_get
    mov r12, rax                # the rules
    xor r13d, r13d              # any not in effect?
    xor r14d, r14d
21: mov rdi, r12
    call json_len
    cmp r13d, eax
    jae 22f
    mov rdi, r12
    mov esi, r13d
    call json_at
    inc r13d
    mov rdi, rax
    lea rsi, [rip + .Lk_notInEffect]
    call c2_jbool
    or r14d, eax
    jmp 21b
22: test r14d, r14d
    jz 23f
    lea rdi, [rip + .Lp_managed_notice]
    mov esi, DGF_MUTED
    call c2_text
23: mov rdi, r12                # none at all: the empty state
    call json_len
    mov r13d, eax
    mov rdi, rbx
    lea rsi, [rip + .Lk_workspace]
    call json_get
    mov rdi, rax
    call json_len
    or r13d, eax
    jnz 3f
    lea rdi, [rip + .Lp_none]
    xor esi, esi
    call c2_text
    mov rdi, rbx
    lea rsi, [rip + .Lk_managedOnly]
    call c2_jbool
    test eax, eax
    jnz 3f
    lea rdi, [rip + .Lp_hint_edit]
    cmp dword ptr [rsp], 0
    jne 24f
    lea rdi, [rip + .Lp_hint]
24: mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
3:  xor r15d, r15d              # the groups: Allow, Ask, Deny
4:  cmp r15d, 3
    jae 6f
    mov rdi, r12                # its rules' count
    mov esi, r15d
    call count_beh
    mov r13d, eax
    test r13d, r13d
    jnz 41f
    cmp dword ptr [rsp], 0
    je 5f
41: call f_clr
    lea rax, [rip + beh_labels]
    mov rdi, [rax + r15*8]
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
    cmp dword ptr [rsp], 0
    je 42f
    lea rdi, [rip + .Lp_add_rule]
    mov esi, PA_ADD
    call c2_link
    mov [rax + DGR_arg], r15
42: xor r13d, r13d              # its rules
43: mov rdi, r12
    call json_len
    cmp r13d, eax
    jae 5f
    mov rdi, r12
    mov esi, r13d
    call json_at
    inc r13d
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_behavior]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + behaviors]
    mov rdx, [rax + r15*8]
    call str_eq_cstr
    test eax, eax
    jz 43b
    xor edx, edx                # removable: Enter asks to remove it
    cmp dword ptr [rsp], 0
    je 44f
    mov rdi, r14
    call readonly_f
    mov edx, PA_RULE
    test eax, eax
    jz 44f
    xor edx, edx
44: mov edi, DGK_ITEM
    xor esi, esi
    call agentdlg_row
    mov [rsp + 8], rax
    lea ecx, [r13 - 1]
    mov [rax + DGR_arg], rcx
    mov rdi, r14
    lea rsi, [rip + .Lk_rule]
    mov edx, RULE_MAX
    call c2_jcl
    mov rdi, [rsp + 8]
    xor esi, esi
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    cmp dword ptr [rsp], 0      # its description, or why it cannot be removed
    je 45f
    mov rdi, r14
    call readonly_f
    test eax, eax
    jnz 46f
45: mov rdi, r14
    call desc_f
    test eax, eax
    jz 47f
46: mov rdi, [rsp + 8]
    mov esi, 1
    call c2_fset
47: mov rdi, r14
    call caption_f
    mov rdi, [rsp + 8]
    mov esi, 2
    call c2_fset
    jmp 43b
5:  inc r15d
    jmp 4b
6:  mov rdi, rbx                # Workspace (N + 1)
    lea rsi, [rip + .Lk_workspace]
    call json_get
    mov r12, rax
    call f_clr
    lea rdi, [rip + .Lp_workspace]
    call f_c
    mov rdi, r12
    call json_len
    lea edi, [rax + 1]
    call f_u
    lea rdi, [rip + .Lclose_paren]
    call f_c
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call c2_frow
    mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    lea rcx, [rip + .Lp_original]
    xor r8d, r8d
    xor r9d, r9d
    call c2_crow
    mov [rsp + 8], rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_originalCwd]
    mov edx, 2000
    call c2_jcl
    mov rdi, [rsp + 8]
    mov esi, 1
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    xor r13d, r13d
61: mov rdi, r12
    call json_len
    cmp r13d, eax
    jae 7f
    mov rdi, r12
    mov esi, r13d
    call json_at
    inc r13d
    mov r14, rax
    call f_clr
    lea rdi, [rip + .Lp_from]
    call f_c
    mov rdi, r14
    lea rsi, [rip + .Lk_source]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r15, rax
    mov rdi, rax
    call src_label
    mov [rsp + 16], rax
    mov rdi, rax
    call strlen
    mov rsi, rax
    mov rdi, [rsp + 16]
    mov edx, 200
    call f_cl
    mov rdi, r15
    call mem_free
    mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    call c2_frow
    mov [rsp + 8], rax
    mov rdi, r14
    lea rsi, [rip + .Lk_path]
    mov edx, 2000
    call c2_jcl
    mov rdi, [rsp + 8]
    mov esi, 1
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    jmp 61b
7:  lea rdi, [rip + .Lp_scope_note]
    cmp dword ptr [rsp], 0
    je 71f
    lea rdi, [rip + .Lp_scope_note_edit]
71: mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
9:  EPILOGUE
.Lpb_remove:
    mov edi, PA_CANCEL          # "Remove allow rule?", the rule, its description, its source; the note
    call agentdlg_back
    call f_clr
    lea rdi, [rip + .Lp_remove_q]
    call f_c
    mov rax, [rip + p_beh]
    lea rcx, [rip + behaviors]
    mov rdi, [rcx + rax*8]
    call f_c
    lea rdi, [rip + .Lp_rule_q]
    call f_c
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call c2_frow
    mov rdi, rbx
    call rule_at
    test rax, rax
    jz 1f
    mov r12, rax
    call f_clr
    mov rdi, r12
    lea rsi, [rip + .Lk_rule]
    mov edx, RULE_MAX
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    xor edi, edi
    call c2_ftext
    mov rdi, r12
    call desc_f
    test eax, eax
    jz 11f
    mov edi, DGF_MUTED
    call c2_ftext
11: call f_clr
    lea rdi, [rip + .Lp_from]
    call f_c
    mov rdi, [rip + p_src]
    call src_label
    mov rdi, rax
    call f_c
    mov edi, DGF_MUTED
    call c2_ftext
1:  lea rdi, [rip + .Lp_remove_note]
    mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
    cmp qword ptr [rip + c2_err + SB_len], 0
    je 2f
    call f_clr
    lea rdi, [rip + .Lp_couldnt_remove]
    call f_c
    mov rdi, [rip + c2_err + SB_ptr]
    mov rsi, [rip + c2_err + SB_len]
    call f_n
    mov edi, DGF_ERROR
    call c2_ftext
2:  lea rdi, [rip + .Lp_remove_rule]
    cmp qword ptr [rip + c2_busy], 0
    je 3f
    lea rdi, [rip + .Lp_removing]
3:  mov esi, PA_CONFIRM
    mov edx, DBF_PRIMARY
    call agentdlg_button
    lea rdi, [rip + .Lcancel]
    mov esi, PA_CANCEL
    xor edx, edx
    call agentdlg_button
    EPILOGUE
.Lpb_add:
    mov edi, PA_CANCEL          # "Add allow rule", the note, the field, Save for, the buttons
    call agentdlg_back
    call f_clr
    lea rdi, [rip + .Lp_add_q]
    call f_c
    mov rax, [rip + p_beh]
    lea rcx, [rip + behaviors]
    mov rdi, [rcx + rax*8]
    call f_c
    lea rdi, [rip + .Lp_rule_word]
    call f_c
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call c2_frow
    lea rdi, [rip + .Lp_add_note]
    mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
    mov edi, DGK_FIELD
    xor esi, esi
    mov edx, PA_SUBMIT
    xor ecx, ecx
    lea r8, [rip + .Lp_placeholder]
    xor r9d, r9d
    call c2_crow
    lea rcx, [rip + p_tf]
    mov [rax + DGR_val], rcx
    lea rdi, [rip + .Lp_save_for]
    call c2_head
    lea rdi, [rip + dests]
    mov esi, [rip + p_dest]
    mov edx, PA_DEST
    mov ecx, 3
    call c2_options
    cmp qword ptr [rip + c2_err + SB_len], 0
    je 1f
    call f_clr
    lea rdi, [rip + .Lp_couldnt_add]
    call f_c
    mov rdi, [rip + c2_err + SB_ptr]
    mov rsi, [rip + c2_err + SB_len]
    call f_n
    mov edi, DGF_ERROR
    call c2_ftext
1:  lea rdi, [rip + .Lp_add_btn]
    cmp qword ptr [rip + c2_busy], 0
    je 2f
    lea rdi, [rip + .Lp_adding]
2:  mov esi, PA_SUBMIT
    mov edx, DBF_PRIMARY
    call agentdlg_button
    lea rdi, [rip + .Lcancel]
    mov esi, PA_CANCEL
    xor edx, edx
    call agentdlg_button
    EPILOGUE

# rule_at(state) -> rax the rule c2_arg names, 0 none
rule_at:
    push rbx
    lea rsi, [rip + .Lk_rules]
    call json_get
    mov rdi, rax
    mov rsi, [rip + c2_arg]
    call json_at
    pop rbx
    ret

# count_beh(rules, behaviour index) -> eax the rules of that behaviour
count_beh:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    xor r13d, r13d
    xor r14d, r14d
1:  mov rdi, rbx
    call json_len
    cmp r13d, eax
    jae 9f
    mov rdi, rbx
    mov esi, r13d
    call json_at
    inc r13d
    mov rdi, rax
    lea rsi, [rip + .Lk_behavior]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + behaviors]
    mov rdx, [rax + r12*8]
    call str_eq_cstr
    add r14d, eax
    jmp 1b
9:  mov eax, r14d
    EPILOGUE

# perms_act(act, arg, DGR*)
perms_act:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    cmp qword ptr [rip + c2_busy], 0
    jne 9f
    cmp r12d, PA_ADD
    je .Lpa_add
    cmp r12d, PA_RULE
    je .Lpa_rule
    cmp r12d, PA_CANCEL
    je .Lpa_cancel
    cmp r12d, PA_DEST
    je .Lpa_dest
    cmp r12d, PA_CONFIRM
    je .Lpa_confirm
    cmp r12d, PA_SUBMIT
    je .Lpa_submit
    jmp 9f
.Lpa_add:
    mov [rip + p_beh], r13
    lea rdi, [rip + p_tf]
    call c2_wipe_tf
    call last_dest
    mov [rip + p_dest], rax
    call c2_notes_clear
    mov qword ptr [rip + c2_page], PP_ADD
    mov edi, 0                  # the field has the focus
    call agentdlg_focus
    jmp 8f
.Lpa_rule:
    mov [rip + c2_arg], r13
    lea rdi, [rip + c2_doc]     # what it removes is kept: the rule, its behaviour, its source
    call c2_parse
    mov rdi, rax
    call rule_at
    test rax, rax
    jz 9f
    mov rbx, rax
    call drop_rule
    mov rdi, rbx
    lea rsi, [rip + .Lk_rule]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + p_rule], rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_source]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + p_src], rax
    xor r14d, r14d              # its behaviour's index
1:  cmp r14d, 3
    jae 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_behavior]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + behaviors]
    mov rdx, [rax + r14*8]
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r14d
    jmp 1b
2:  mov [rip + p_beh], r14
    call c2_notes_clear
    mov qword ptr [rip + c2_page], PP_REMOVE
    mov edi, 1                  # the focus on Cancel: Enter twice removes nothing by mistake
    call agentdlg_focus
    jmp 8f
.Lpa_cancel:
    call c2_notes_clear
    mov qword ptr [rip + c2_page], PP_LIST
    jmp 8f
.Lpa_dest:
    mov [rip + p_dest], r13
    jmp 8f
.Lpa_confirm:                   # {"op":"remove","rule":R,"behavior":B,"source":S}
    lea rdi, [rip + c2_err]
    call sb_clear
    lea rdi, [rip + c2_in]
    call jw_begin
    lea rdi, [rip + c2_in]
    call jw_obj
    lea rsi, [rip + .Lv_remove]
    call op_key
    lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_rule]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, [rip + p_rule]
    call jw_cstr
    call beh_key
    lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_source]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, [rip + p_src]
    call jw_cstr
    lea rdi, [rip + c2_in]
    call jw_end_obj
    mov edi, PW_REMOVE
    call run_edit
    jmp 8f
.Lpa_submit:                    # {"op":"add","rules":[R],"behavior":B,"destination":D}
    lea rdi, [rip + p_tf]
    call c2_tf_text
    test rdx, rdx
    jz 9f
    mov rbx, rax
    mov r14, rdx
    call drop_rule
    mov rdi, rbx
    mov rsi, r14
    call mem_dup
    mov [rip + p_rule], rax
    mov rax, [rip + p_dest]
    lea rcx, [rip + dest_ids]
    mov rbx, [rcx + rax*8]
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov [rip + p_src], rax
    mov rdi, [rip + p_src]      # the place is remembered, as the card's (the extension's one key)
    call keep_dest
    lea rdi, [rip + c2_err]
    call sb_clear
    lea rdi, [rip + c2_in]
    call jw_begin
    lea rdi, [rip + c2_in]
    call jw_obj
    lea rsi, [rip + .Lv_add]
    call op_key
    lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_rules]
    call jw_key
    lea rdi, [rip + c2_in]
    call jw_arr
    lea rdi, [rip + c2_in]
    mov rsi, [rip + p_rule]
    call jw_cstr
    lea rdi, [rip + c2_in]
    call jw_end_arr
    call beh_key
    lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_destination]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, [rip + p_src]
    call jw_cstr
    lea rdi, [rip + c2_in]
    call jw_end_obj
    mov edi, PW_ADD
    call run_edit
8:  call perms_build
9:  EPILOGUE

# op_key(rsi cstr): "op":VALUE into c2_in
op_key:
    PROLOGUE
    mov rbx, rsi
    lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_op]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, rbx
    call jw_cstr
    EPILOGUE

# beh_key(): "behavior":B into c2_in
beh_key:
    PROLOGUE
    lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_behavior]
    call jw_key
    mov rax, [rip + p_beh]
    lea rcx, [rip + behaviors]
    mov rsi, [rcx + rax*8]
    lea rdi, [rip + c2_in]
    call jw_cstr
    EPILOGUE

# run_edit(what): `claude edit-permission-rules --json` with c2_in
run_edit:
    PROLOGUE
    mov rbx, rdi
    call c2_args
    lea rdi, [rip + .La_edit_rules]
    call c2_arg_c
    lea rdi, [rip + .La_json]
    call c2_arg_c
    mov rdi, rbx
    call c2_run
    test eax, eax
    jz 8f
    mov qword ptr [rip + c2_busy], 1
    EPILOGUE
8:  lea rdi, [rip + .Lno_run]
    call c2_err_cset
    EPILOGUE

# last_dest() -> rax the add page's first destination: the place the card or this page saved to last, when
#   it is a settings file (local, user, project), else local
last_dest:
    PROLOGUE
    mov edi, AG_CLAUDE
    call agentcfg_get
    lea rbx, [rax + AGC_dest]
    xor r12d, r12d
1:  cmp r12d, 3
    jae 8f
    lea rax, [rip + dest_ids]
    mov rsi, [rax + r12*8]
    mov rdi, rbx
    call strcmp_eq
    test eax, eax
    jnz 9f
    inc r12d
    jmp 1b
8:  xor r12d, r12d
9:  mov eax, r12d
    EPILOGUE

# keep_dest(cstr): the project's remembered place (agentcfg's, which the permission card shares)
keep_dest:
    PROLOGUE
    mov rbx, rdi
    mov edi, AG_CLAUDE
    call agentcfg_get
    mov r12, rax
    mov rdi, rbx
    call strlen
    mov rdi, r12
    mov esi, AGF_DEST
    mov rdx, rbx
    mov rcx, rax
    call agentcfg_set
    EPILOGUE

# perms_ran(what, code): the write ended: its warnings; then the list read again until it shows the change
perms_ran:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 1f
    mov rdi, r12
    lea rsi, [rip + .Lp_thing]
    call c2_errthing
    call c2_err_fsb
    mov qword ptr [rip + c2_busy], 0
    call perms_build
    EPILOGUE
1:  call c2_notes_clear
    lea rdi, [rip + c2_out]     # {"ok":true,"warnings":[...],"stored":[...]}: the warnings shown
    call c2_last_json
    test rax, rax
    jz 3f
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_warnings]
    call json_get
    mov r14, rax
    xor r15d, r15d
2:  mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 21f
    mov rdi, r14
    mov esi, r15d
    call json_at
    inc r15d
    mov rdi, rax
    call json_str
    mov rdi, rax
    mov rsi, rdx
    mov edx, 800
    call c2_clean
    lea rdi, [rip + c2_msg]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + c2_msg]
    mov esi, ' '
    call sb_push_byte
    jmp 2b
21: mov rdi, r13                # the rule as stored, when it says
    lea rsi, [rip + .Lk_stored]
    call json_get
    mov rdi, rax
    xor esi, esi
    call json_at
    mov rdi, rax
    call json_str
    test rdx, rdx
    jz 3f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rdi, [rip + p_rule]
    mov [rip + p_rule], rax
    call mem_free
3:  mov eax, 2
    cmp rbx, PW_ADD
    jne 4f
    mov eax, 1
4:  mov [rip + p_check], rax
    mov qword ptr [rip + p_tries], TRIES
    mov qword ptr [rip + c2_busy], 1
    mov edi, PR_LIST
    call c2_ask
    EPILOGUE

# ======================================================================================================
# Sandbox (6.10)
# ======================================================================================================

.globl sbx_open, sbx_act, sbx_answer, sbx_ran, sbx_send, sbx_free, sbx_tick

# sbx_open(rest ptr, len): "exclude PATTERN" excludes it once the dialog has come (the extension's /sandbox
#   exclude)
sbx_open:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov qword ptr [rip + s_check], 0
    mov rdi, [rip + s_pat]
    call mem_free
    mov qword ptr [rip + s_pat], 0
    cmp r12, 8
    jb 1f
    mov rdi, rbx
    mov esi, 8
    lea rdx, [rip + .Ls_exclude_sp]
    call str_eq_cstr
    test eax, eax
    jz 1f
    lea rdi, [rbx + 8]
    lea rsi, [r12 - 8]
    call c2_trim
    test rdx, rdx
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + s_pat], rax
1:  lea rdi, [rip + .Ls_loading]
    call agentdlg_loading
    mov edi, SR_DIALOG
    call c2_ask
    EPILOGUE

sbx_free:
    PROLOGUE
    lea rdi, [rip + s_tf]
    call c2_wipe_tf
    mov rdi, [rip + s_pat]
    call mem_free
    mov qword ptr [rip + s_pat], 0
    mov qword ptr [rip + s_check], 0
    EPILOGUE

sbx_send:
    mov rdi, rsi
    lea rsi, [rip + .Lv_get_sandbox]
    jmp claude_dlg2_begin

sbx_tick:
    PROLOGUE
    mov edi, SR_DIALOG
    call c2_ask
    EPILOGUE

# sbx_answer(rq, envelope): the dialog's state (its shape checked), the check of a write
sbx_answer:
    PROLOGUE
    mov rbx, rsi
    mov rdi, rbx
    call c2_ok
    test eax, eax
    jnz 1f
    mov rdi, rbx
    call c2_why
    mov rdi, rax
    mov rsi, rdx
    call sbx_error
    jmp 7f
1:  mov rdi, rbx
    call c2_resp
    mov r12, rax
    mov rdi, rax
    call shape_ok
    test eax, eax
    jnz 2f
    lea rdi, [rip + .Ls_shape]
    call c2_err_cset
    jmp 7f
2:  lea rdi, [rip + c2_doc]
    mov rsi, r12
    call c2_keep
    cmp qword ptr [rip + s_check], 0
    je 5f
    call sbx_applied
    test eax, eax
    jnz 4f
    cmp qword ptr [rip + s_tries], 0
    je 3f
    dec qword ptr [rip + s_tries]
    mov qword ptr [rip + c2_busy], 1
    mov edi, 300
    call c2_later
    EPILOGUE
3:  lea rdi, [rip + .Ls_pending]
    call strlen
    lea rdi, [rip + c2_msg]
    call sb_clear
    lea rdi, [rip + c2_msg]
    lea rsi, [rip + .Ls_pending]
    call sb_push_cstr
4:  mov qword ptr [rip + s_check], 0
    mov qword ptr [rip + c2_busy], 0
5:  mov rdi, [rip + s_pat]      # /sandbox exclude PATTERN: now
    test rdi, rdi
    jz 7f
    mov qword ptr [rip + s_pat], 0
    push rdi
    push rdi
    call strlen
    pop rdi
    pop rdi
    mov rsi, rax
    push rdi
    push rdi
    call exclude
    pop rdi
    pop rdi
    call mem_free
7:  call sbx_build
    EPILOGUE

# sbx_error(ptr, len): the error as the extension words it (jPt)
sbx_error:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdx, [rip + .Ls_cloud_key]
    call has_text
    test eax, eax
    jz 1f
    lea rdi, [rip + .Ls_cloud]
    call c2_err_cset
    EPILOGUE
1:  mov rdi, rbx
    mov rsi, r12
    call c2_err_set
    EPILOGUE

# has_text(ptr, len, cstr) -> eax 1 when the text holds it
has_text:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rdx
    call strlen
    mov r14, rax
    xor r15d, r15d
1:  mov rax, r12
    sub rax, r15
    cmp rax, r14
    jb 8f
    lea rdi, [rbx + r15]
    mov rsi, r14
    mov rdx, r13
    call str_eq_cstr
    test eax, eax
    jnz 9f
    inc r15
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# shape_ok(dialog) -> eax 1 when it has what the dialog reads (the extension's check)
shape_ok:
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
    lea rsi, [rip + .Lk_supported]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_FALSE
    je 1f
    cmp eax, JT_TRUE
    jne 8f
1:  mov rdi, rbx
    lea rsi, [rip + .Lk_dependencies]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_errors]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_excluded]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_restrictions]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_OBJ
    jne 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# sbx_applied() -> eax 1 when the kept dialog shows the write (s(i))
sbx_applied:
    PROLOGUE
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    mov rax, [rip + s_check]
    cmp rax, 1
    jne 2f
    mov rdi, rbx
    lea rsi, [rip + .Lk_mode]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + s_mode]
    call str_eq_cstr
    EPILOGUE
2:  cmp rax, 2
    jne 3f
    mov rdi, rbx
    lea rsi, [rip + .Lk_fallback]
    call c2_jbool
    cmp rax, [rip + s_bool]
    sete al
    movzx eax, al
    EPILOGUE
3:  mov rdi, rbx                # the pattern (its quotes and blanks off) among the excluded
    lea rsi, [rip + .Lk_excluded]
    call json_get
    mov r12, rax
    xor r13d, r13d
4:  mov rdi, r12
    call json_len
    cmp r13d, eax
    jae 8f
    mov rdi, r12
    mov esi, r13d
    call json_at
    inc r13d
    mov rdi, rax
    call json_str
    cmp rdx, [rip + s_want + SB_len]
    jne 4b
    mov rdi, rax
    mov rsi, [rip + s_want + SB_ptr]
    mov rcx, rdx
    xor edx, edx
5:  cmp rdx, rcx
    jae 7f
    movzx r8d, byte ptr [rdi + rdx]
    cmp r8b, [rsi + rdx]
    jne 4b
    inc rdx
    jmp 5b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# sbx_build(): the dialog
sbx_build:
    PROLOGUE 32
    call agentdlg_begin
    call c2_msgs
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    test rax, rax
    jz 9f
    mov rdi, rbx                # why it cannot change (y), why it is not running (b)
    call lock_f
    mov [rsp], eax              # y: 1 locked
    test eax, eax
    jz 1f
    mov edi, DGF_MUTED
    call c2_ftext
1:  mov rdi, rbx
    call unavailable_f
    test eax, eax
    jz 2f
    mov edi, DGF_MUTED
    call c2_ftext
2:  mov rdi, rbx
    lea rsi, [rip + .Lk_supported]
    call c2_jbool
    test eax, eax
    jz 9f
    xor eax, eax                # the modes and overrides are off while locked or writing
    cmp dword ptr [rsp], 0
    jne 21f
    cmp qword ptr [rip + c2_busy], 0
    je 22f
21: mov eax, DGF_OFF
22: mov [rsp + 4], eax
    lea rdi, [rip + .Ls_mode]
    call c2_head
    mov rdi, rbx                # the mode shown: regular for disabled when no sandbox is not allowed
    lea rsi, [rip + .Lk_mode]
    call c2_jstr
    mov r12, rax
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lk_no_sandbox]
    call c2_jbool
    mov [rsp + 8], eax
    test eax, eax
    jnz 23f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lv_disabled]
    call str_eq_cstr
    test eax, eax
    jz 23f
    lea r12, [rip + .Lv_regular]
    mov r13d, 7
23: mov rdi, rbx
    lea rsi, [rip + .Lk_auto_allow]
    call c2_jbool
    mov r14d, eax
    test eax, eax               # auto-allow, when available
    jz 24f
    lea rcx, [rip + .Ls_auto]
    lea r8, [rip + .Ls_auto_d]
    lea rax, [rip + .Lv_auto_allow]
    call mode_row
24: lea rcx, [rip + .Ls_regular]    # regular: its label as auto-allow is or is not offered
    test r14d, r14d
    jnz 25f
    lea rcx, [rip + .Ls_regular1]
25: lea r8, [rip + .Ls_regular_d]
    lea rax, [rip + .Lv_regular]
    call mode_row
    cmp dword ptr [rsp + 8], 0  # no sandbox, when allowed
    je 26f
    lea rcx, [rip + .Ls_none]
    lea r8, [rip + .Ls_none_d]
    lea rax, [rip + .Lv_disabled]
    call mode_row
26: lea rdi, [rip + .Ls_overrides]
    call c2_head
    mov rdi, rbx                # the fallback switch: inert when off in the settings or locked
    lea rsi, [rip + .Lk_fallback]
    call c2_jbool
    mov r14d, eax
    xor esi, esi
    test eax, eax
    jz 27f
    mov esi, DGF_ON
27: mov rdi, rbx
    push rsi
    push rsi
    call fallback_inert
    pop rsi
    pop rsi
    test eax, eax
    jz 271f
    or esi, DGF_OFF
271:mov edi, DGK_TOGGLE
    mov edx, SA_FALLBACK
    lea rcx, [rip + .Ls_fallback]
    xor r8d, r8d
    xor r9d, r9d
    call c2_crow
    call f_clr                  # its help
    lea rdi, [rip + .Ls_fb_on]
    test r14d, r14d
    jnz 28f
    lea rdi, [rip + .Ls_fb_off]
28: call f_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_enabled_in_settings]
    call c2_jbool
    test eax, eax
    jnz 281f
    lea rdi, [rip + .Ls_turn_on]
    call f_c
    jmp 29f
281:mov rdi, rbx
    lea rsi, [rip + .Lk_overrides_locked]
    call c2_jbool
    test eax, eax
    jz 29f
    lea rdi, [rip + .Ls_higher]
    call f_c
29: mov edi, DGF_MUTED | DGF_SMALL
    call c2_ftext
    lea rdi, [rip + .Ls_excluded]   # Excluded commands
    call c2_head
    lea rdi, [rip + .Ls_excl_help]
    mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
    mov rdi, rbx
    lea rsi, [rip + .Lk_excluded]
    call json_get
    mov r12, rax
    mov rdi, rax
    call json_len
    test eax, eax
    jnz 3f
    lea rdi, [rip + .Ls_none_word]
    mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
    jmp 4f
3:  mov rdi, r12
    xor esi, esi
    call list_rows
4:  xor esi, esi                # the pattern's field and Exclude: off while locked or writing
    mov rdi, rbx
    lea rsi, [rip + .Lk_locked]
    call c2_jbool
    mov esi, 0
    test eax, eax
    jnz 41f
    cmp qword ptr [rip + c2_busy], 0
    je 42f
41: mov esi, DGF_OFF
42: mov edi, DGK_FIELD
    mov edx, SA_EXCLUDE
    xor ecx, ecx
    lea r8, [rip + .Ls_pattern_ph]
    xor r9d, r9d
    call c2_crow
    lea rcx, [rip + s_tf]
    mov [rax + DGR_val], rcx
    mov rdi, rbx                # Dependencies
    lea rsi, [rip + .Lk_dependencies]
    call json_get
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_errors]
    call json_get
    mov r13, rax
    mov rdi, r12
    lea rsi, [rip + .Lk_warnings]
    call json_get
    mov r14, rax
    mov rdi, r13
    call json_len
    mov r15d, eax
    mov rdi, r14
    call json_len
    or eax, r15d
    jz 5f
    lea rdi, [rip + .Ls_deps]
    call c2_head
    mov rdi, r13
    mov esi, DGF_ERROR
    call list_rows
    mov rdi, r14
    xor esi, esi
    call list_rows
5:  mov rdi, rbx                # the restrictions
    lea rsi, [rip + .Lk_restrictions]
    call json_get
    mov r12, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_net_managed]
    call c2_jbool
    mov r13d, eax
    test eax, eax
    jz 51f
    mov rdi, r12
    lea rsi, [rip + .Lk_net_allowed]
    call json_get
    mov rdi, rax
    call json_len
    test eax, eax
    jnz 51f
    lea rdi, [rip + .Ls_net_managed]
    mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
51: xor r14d, r14d              # any to show?
    xor r15d, r15d
52: lea rax, [rip + restrictions]
    mov rsi, [rax + r15*8]
    test rsi, rsi
    jz 53f
    mov rdi, r12
    call json_get
    mov rdi, rax
    call json_len
    or r14d, eax
    add r15d, 2
    jmp 52b
53: test r14d, r14d
    jz 8f
    lea rdi, [rip + .Ls_restrictions]
    call c2_head
    xor r15d, r15d
54: lea rax, [rip + restrictions]
    mov rsi, [rax + r15*8]
    test rsi, rsi
    jz 8f
    mov rdi, r12
    call json_get
    mov r14, rax
    mov rdi, rax
    call json_len
    test eax, eax
    jz 56f
    lea rax, [rip + restrictions]   # the label (allowed domains: "(managed)" when managed)
    mov rcx, [rax + r15*8 + 8]
    cmp r15d, 8
    jne 55f
    test r13d, r13d
    jz 55f
    lea rcx, [rip + .Ls_r_domains_m]
55: mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call c2_crow
    mov [rsp + 16], rax
    call f_clr                  # the values joined by ", "
    xor ecx, ecx
    mov [rsp + 24], ecx
551:mov rdi, r14
    call json_len
    cmp [rsp + 24], eax
    jae 552f
    cmp dword ptr [rsp + 24], 0
    je 553f
    lea rdi, [rip + .Lcomma]
    call f_c
553:mov rdi, r14
    mov esi, [rsp + 24]
    call json_at
    inc dword ptr [rsp + 24]
    mov rdi, rax
    call json_str
    mov rdi, rax
    mov rsi, rdx
    mov edx, 400
    call f_cl
    jmp 551b
552:mov rdi, [rsp + 16]
    mov esi, 1
    call c2_fset
56: add r15d, 2
    jmp 54b
8:  lea rdi, [rip + .Ls_exclude_btn]
    mov esi, SA_EXCLUDE
    xor edx, edx
    call agentdlg_button
9:  EPILOGUE

# mode_row(-, -, -, label rcx, description r8, id rax): an OPTION row of sbx_build's (r12/r13 the mode shown,
#   [rsp + 4 of the caller] its flags): chosen when its id is the mode shown
mode_row:
    PROLOGUE 16
    mov rbx, rax
    mov [rsp], rcx
    mov r14, r8
    mov rdi, r12
    mov rsi, r13
    mov rdx, rbx
    call str_eq_cstr
    xor esi, esi
    test eax, eax
    jz 1f
    mov esi, DGF_ON
1:  or esi, [rip + mode_flags]
    mov edi, DGK_OPTION
    mov edx, SA_MODE
    mov rcx, [rsp]
    mov r8, r14
    xor r9d, r9d
    call c2_crow
    mov [rax + DGR_arg], rbx
    EPILOGUE

# lock_f(dialog) -> eax 1 with fsb = why the settings cannot be changed here ($Pn), 0 when they can
lock_f:
    PROLOGUE
    mov rbx, rdi
    mov dword ptr [rip + mode_flags], 0
    lea rsi, [rip + .Lk_supported]
    call c2_jbool
    test eax, eax
    jnz 2f
    call f_clr
    mov rdi, rbx
    lea rsi, [rip + .Lk_unsupported_reason]
    call c2_jstr
    mov r12, rax
    mov r13, rdx
    lea rdi, [rip + .Ls_unsup]
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lv_wsl1]
    call str_eq_cstr
    lea rdi, [rip + .Ls_wsl1]
    test eax, eax
    jnz 1f
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .Lv_excluded_platform]
    call str_eq_cstr
    lea rdi, [rip + .Ls_excl_platform]
    test eax, eax
    jnz 1f
    lea rdi, [rip + .Ls_unsup]
1:  call f_c
    jmp 8f
2:  mov rdi, rbx
    lea rsi, [rip + .Lk_locked]
    call c2_jbool
    test eax, eax
    jz 3f
    call f_clr
    lea rdi, [rip + .Ls_locked]
    call f_c
    jmp 8f
3:  mov rdi, rbx
    lea rsi, [rip + .Lk_dependencies]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_errors]
    call json_get
    mov rdi, rax
    call json_len
    test eax, eax
    jz 7f
    call f_clr
    lea rdi, [rip + .Ls_missing]
    call f_c
8:  mov dword ptr [rip + mode_flags], DGF_OFF
    mov eax, 1
    EPILOGUE
7:  xor eax, eax
    cmp qword ptr [rip + c2_busy], 0
    je 9f
    mov dword ptr [rip + mode_flags], DGF_OFF
9:  EPILOGUE

# unavailable_f(dialog) -> eax 1 with fsb = why the sandbox on in the settings is not running (jPn)
unavailable_f:
    PROLOGUE
    mov rbx, rdi
    xor eax, eax
    lea rsi, [rip + .Lk_supported]
    call c2_jbool
    test eax, eax
    jz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_enabled_in_settings]
    call c2_jbool
    test eax, eax
    jz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_enabled]
    call c2_jbool
    test eax, eax
    jnz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_dependencies]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_errors]
    call json_get
    mov rdi, rax
    call json_len
    test eax, eax
    jnz 8f
    call f_clr
    mov rdi, rbx
    lea rsi, [rip + .Lk_unavailable_reason]
    call c2_jstr
    test rdx, rdx
    jz 1f
    push rdx
    push rax
    lea rdi, [rip + .Ls_on_cannot]
    call f_c
    pop rdi
    pop rsi
    mov edx, 800
    call f_cl
    jmp 2f
1:  lea rdi, [rip + .Ls_on_not_started]
    call f_c
2:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# fallback_inert(dialog) -> eax 1 when the fallback switch cannot be changed (w, or a write going on)
fallback_inert:
    PROLOGUE
    mov rbx, rdi
    mov eax, 1
    cmp qword ptr [rip + c2_busy], 0
    jne 9f
    lea rsi, [rip + .Lk_supported]
    call c2_jbool
    test eax, eax
    jz 1f
    mov rdi, rbx
    lea rsi, [rip + .Lk_enabled_in_settings]
    call c2_jbool
    test eax, eax
    jz 1f
    mov rdi, rbx
    lea rsi, [rip + .Lk_overrides_locked]
    call c2_jbool
    EPILOGUE
1:  mov eax, 1
9:  EPILOGUE

# list_rows(array, flags): a small TEXT row for each string
list_rows:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    or r12d, DGF_SMALL
    xor r13d, r13d
1:  mov rdi, rbx
    call json_len
    cmp r13d, eax
    jae 9f
    mov rdi, rbx
    mov esi, r13d
    call json_at
    inc r13d
    mov rdi, rax
    call json_str
    mov rdi, rax
    mov rsi, rdx
    mov edx, 800
    call c2_clean
    mov r14, rax
    mov r15, rdx
    mov edi, DGK_TEXT
    mov esi, r12d
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, r14
    mov rcx, r15
    call agentdlg_text
    jmp 1b
9:  EPILOGUE

# sbx_act(act, arg, DGR*)
sbx_act:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    cmp qword ptr [rip + c2_busy], 0
    jne 9f
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    test rax, rax
    jz 9f
    cmp r12d, SA_MODE
    jne 2f
    mov rdi, rbx                # a mode other than the one in effect: {"mode": M}
    call lock_f
    test eax, eax
    jnz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_mode]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r13
    call str_eq_cstr
    test eax, eax
    jnz 9f
    mov [rip + s_mode], r13
    lea rdi, [rip + c2_in]
    call jw_begin
    lea rdi, [rip + c2_in]
    call jw_obj
    lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_mode]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, r13
    call jw_cstr
    lea rdi, [rip + c2_in]
    call jw_end_obj
    mov edi, 1
    call sbx_write
    jmp 9f
2:  cmp r12d, SA_FALLBACK
    jne 3f
    mov rdi, rbx                # {"allowUnsandboxedCommands": !fallback}
    call fallback_inert
    test eax, eax
    jnz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_fallback]
    call c2_jbool
    xor eax, 1
    mov [rip + s_bool], rax
    lea rdi, [rip + c2_in]
    call jw_begin
    lea rdi, [rip + c2_in]
    call jw_obj
    lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_allow_unsandboxed]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, [rip + s_bool]
    call jw_bool
    lea rdi, [rip + c2_in]
    call jw_end_obj
    mov edi, 2
    call sbx_write
    jmp 9f
3:  cmp r12d, SA_EXCLUDE
    jne 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_locked]
    call c2_jbool
    test eax, eax
    jnz 9f
    lea rdi, [rip + s_tf]
    call c2_tf_text
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call exclude
    lea rdi, [rip + s_tf]
    call tf_clear
9:  EPILOGUE

# exclude(ptr, len): {"excludeCommand": PATTERN} (1000 bytes at most, as the extension's check); the
#   notice `Added "X" to the excluded commands` once it shows
exclude:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    mov rsi, r12
    call c2_trim
    test rdx, rdx
    jz 9f
    cmp rdx, 1000
    ja 9f
    mov rbx, rax
    mov r12, rdx
    lea rdi, [rip + s_want]     # the pattern as the check finds it: its quotes off, trimmed
    call sb_clear
    mov rdi, rbx
    mov rsi, r12
    cmp byte ptr [rdi], 34
    je 1f
    cmp byte ptr [rdi], 39
    jne 2f
1:  inc rdi
    dec rsi
2:  test rsi, rsi
    jz 3f
    movzx eax, byte ptr [rdi + rsi - 1]
    cmp eax, 34
    je 21f
    cmp eax, 39
    jne 3f
21: dec rsi
3:  call c2_trim
    lea rdi, [rip + s_want]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + c2_in]
    call jw_begin
    lea rdi, [rip + c2_in]
    call jw_obj
    lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_exclude_command]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, rbx
    mov rdx, r12
    call jw_str
    lea rdi, [rip + c2_in]
    call jw_end_obj
    mov edi, 3
    call sbx_write
9:  EPILOGUE

# sbx_write(check): `claude edit-sandbox-settings --json` with c2_in
sbx_write:
    PROLOGUE
    mov rbx, rdi
    call c2_notes_clear
    call c2_args
    lea rdi, [rip + .La_edit_sandbox]
    call c2_arg_c
    lea rdi, [rip + .La_json]
    call c2_arg_c
    mov edi, 1
    call c2_run
    test eax, eax
    jz 8f
    mov [rip + s_check], rbx
    mov qword ptr [rip + c2_busy], 1
    call sbx_build
    EPILOGUE
8:  lea rdi, [rip + .Lno_run]
    call c2_err_cset
    call sbx_build
    EPILOGUE

# sbx_ran(what, code): the write ended: read again until it shows (its notice), or its error and the dialog
#   read again (the extension's)
sbx_ran:
    PROLOGUE
    mov r12, rsi
    test r12, r12
    jz 1f
    mov rdi, r12
    lea rsi, [rip + .Ls_thing]
    call c2_errthing
    call f_get
    mov rdi, rax
    mov rsi, rdx
    call sbx_error
    mov qword ptr [rip + s_check], 0
    call sbx_build
    mov edi, SR_DIALOG
    call c2_ask
    EPILOGUE
1:  cmp qword ptr [rip + s_check], 3
    jne 2f
    call f_clr                  # Added "X" to the excluded commands
    lea rdi, [rip + .Ls_added]
    call f_c
    mov rdi, [rip + s_want + SB_ptr]
    mov rsi, [rip + s_want + SB_len]
    mov edx, 400
    call f_cl
    lea rdi, [rip + .Ls_added2]
    call f_c
    call c2_msg_fsb
2:  mov qword ptr [rip + s_tries], TRIES
    mov qword ptr [rip + c2_busy], 1
    mov edi, SR_DIALOG
    call c2_ask
    EPILOGUE

.data
.p2align 2
mode_flags: .long 0             # sbx_build: the OPTION rows' extra flags (DGF_OFF while locked or writing)

.section .rodata
.p2align 3
behaviors: .quad .Lv_allow, .Lv_ask, .Lv_deny
beh_labels: .quad .Lw_allow, .Lw_ask, .Lw_deny
dest_ids: .quad .Lv_localSettings, .Lv_userSettings, .Lv_projectSettings
dests: .quad .Ld_local, .Ld_local_d, .Ld_user, .Ld_user_d, .Ld_project, .Ld_project_d
desc_keys: .quad .Lk_prefix, .Lk_emphasis, .Lk_suffix, 0
src_labels:
    .quad .Lv_userSettings, .Lsl_user, .Lv_projectSettings, .Lsl_project, .Lv_localSettings, .Lsl_local
    .quad .Lv_flagSettings, .Lsl_flag, .Lv_policySettings, .Lsl_policy, .Lv_cliArg, .Lsl_cli
    .quad .Lv_command, .Lsl_command, .Lv_session, .Lsl_session, .Lv_mcpMount, .Lsl_mount
    .quad .Lv_toolsNarrowing, .Lsl_narrow, .Lv_mcpServerPolicy, .Lsl_mcppol, .Lv_hostCredential, .Lsl_host
    .quad 0, 0
ro_reasons:
    .quad .Lv_cliArg, .Lro_cli, .Lv_session, .Lro_session, .Lv_policySettings, .Lro_policy
    .quad .Lv_flagSettings, .Lro_flag, .Lv_command, .Lro_command, 0, .Lro_default
restrictions:                   # the restrictions' keys and labels, in the extension's order
    .quad .Lk_fs_deny_read, .Ls_r_deny_read, .Lk_fs_allow_read, .Ls_r_allow_read
    .quad .Lk_fs_allow_write, .Ls_r_allow_write, .Lk_fs_deny_write, .Ls_r_deny_write
    .quad .Lk_net_allowed, .Ls_r_domains, .Lk_net_denied, .Ls_r_denied_domains
    .quad .Lk_unix_sockets, .Ls_r_sockets, .Lk_ignored_globs, .Ls_r_globs, 0, 0
.Lempty: .asciz ""
.Ldot: .asciz "."
.Lcomma: .asciz ", "
.Lopen_paren: .asciz " ("
.Lclose_paren: .asciz ")"
.Lcancel: .asciz "Cancel"
.Lno_run: .asciz "Claude Code could not be started."
.Lk_state: .asciz "state"
.Lk_rules: .asciz "rules"
.Lk_rule: .asciz "rule"
.Lk_source: .asciz "source"
.Lk_behavior: .asciz "behavior"
.Lk_description: .asciz "description"
.Lk_prefix: .asciz "prefix"
.Lk_emphasis: .asciz "emphasis"
.Lk_suffix: .asciz "suffix"
.Lk_editability: .asciz "editability"
.Lk_notInEffect: .asciz "notInEffect"
.Lk_managedOnly: .asciz "managedOnly"
.Lk_workspace: .asciz "workspaceDirectories"
.Lk_originalCwd: .asciz "originalCwd"
.Lk_path: .asciz "path"
.Lk_errors: .asciz "errors"
.Lk_file: .asciz "file"
.Lk_message: .asciz "message"
.Lk_op: .asciz "op"
.Lk_destination: .asciz "destination"
.Lk_warnings: .asciz "warnings"
.Lk_stored: .asciz "stored"
.Lk_supported: .asciz "supported"
.Lk_unsupported_reason: .asciz "unsupported_reason"
.Lk_unavailable_reason: .asciz "unavailable_reason"
.Lk_locked: .asciz "locked"
.Lk_overrides_locked: .asciz "overrides_locked"
.Lk_enabled: .asciz "enabled"
.Lk_enabled_in_settings: .asciz "enabled_in_settings"
.Lk_mode: .asciz "mode"
.Lk_auto_allow: .asciz "auto_allow_available"
.Lk_no_sandbox: .asciz "no_sandbox_allowed"
.Lk_fallback: .asciz "unsandboxed_fallback"
.Lk_dependencies: .asciz "dependencies"
.Lk_excluded: .asciz "excluded_commands"
.Lk_restrictions: .asciz "restrictions"
.Lk_net_managed: .asciz "network_managed"
.Lk_net_allowed: .asciz "network_allowed_domains"
.Lk_net_denied: .asciz "network_denied_domains"
.Lk_fs_deny_read: .asciz "fs_deny_read"
.Lk_fs_allow_read: .asciz "fs_allow_read"
.Lk_fs_allow_write: .asciz "fs_allow_write"
.Lk_fs_deny_write: .asciz "fs_deny_write"
.Lk_unix_sockets: .asciz "unix_sockets"
.Lk_ignored_globs: .asciz "ignored_glob_patterns"
.Lk_allow_unsandboxed: .asciz "allowUnsandboxedCommands"
.Lk_exclude_command: .asciz "excludeCommand"
.Lv_list_rules: .asciz "list_permission_rules"
.Lv_get_sandbox: .asciz "get_sandbox_dialog"
.Lv_add: .asciz "add"
.Lv_remove: .asciz "remove"
.Lv_allow: .asciz "allow"
.Lv_ask: .asciz "ask"
.Lv_deny: .asciz "deny"
.Lv_persistent: .asciz "persistent"
.Lv_unknown: .asciz "unknown"
.Lv_localSettings: .asciz "localSettings"
.Lv_userSettings: .asciz "userSettings"
.Lv_projectSettings: .asciz "projectSettings"
.Lv_flagSettings: .asciz "flagSettings"
.Lv_policySettings: .asciz "policySettings"
.Lv_cliArg: .asciz "cliArg"
.Lv_command: .asciz "command"
.Lv_session: .asciz "session"
.Lv_mcpMount: .asciz "mcpMount"
.Lv_toolsNarrowing: .asciz "toolsNarrowing"
.Lv_mcpServerPolicy: .asciz "mcpServerPolicy"
.Lv_hostCredential: .asciz "hostCredential"
.Lv_auto_allow: .asciz "auto-allow"
.Lv_regular: .asciz "regular"
.Lv_disabled: .asciz "disabled"
.Lv_wsl1: .asciz "wsl1"
.Lv_excluded_platform: .asciz "excluded_platform"
.Lw_allow: .asciz "Allow"
.Lw_ask: .asciz "Ask"
.Lw_deny: .asciz "Deny"
.Lsl_user: .asciz "user settings"
.Lsl_project: .asciz "shared project settings"
.Lsl_local: .asciz "project local settings"
.Lsl_flag: .asciz "settings given at startup"
.Lsl_policy: .asciz "enterprise managed settings"
.Lsl_cli: .asciz "startup options"
.Lsl_command: .asciz "a command's configuration"
.Lsl_session: .asciz "current session"
.Lsl_mount: .asciz "Remote Control server mount"
.Lsl_narrow: .asciz "a limited tool set"
.Lsl_mcppol: .asciz "MCP server policy"
.Lsl_host: .asciz "cloud-session credential guard"
.Lro_cli: .asciz "Not saved in a settings file."
.Lro_session: .asciz "Approved for this session only; not saved in a settings file."
.Lro_policy: .asciz "Managed by enterprise settings."
.Lro_flag: .asciz "From a settings file given at startup."
.Lro_command: .asciz "Granted by a command; change it in the command."
.Lro_default: .asciz "Read-only."
.Ld_local: .asciz "this project (just you)"
.Ld_local_d: .asciz "Saves to .claude/settings.local.json (gitignored)"
.Ld_user: .asciz "all projects"
.Ld_user_d: .asciz "Saves to ~/.claude/settings.json"
.Ld_project: .asciz "this project (shared)"
.Ld_project_d: .asciz "Saves to .claude/settings.json (shared with team)"
.Lp_loading: .asciz "Loading permission rules\342\200\246"
.Lp_failed: .asciz "Couldn\342\200\231t load permission rules from this session: "
.Lp_file_failed: .asciz "Settings file failed to load: "
.Lp_dash: .asciz " \342\200\224 "
.Lp_file_failed2: .asciz ". Its settings, including permission rules, are not in effect."
.Lp_managed_notice: .asciz "Enterprise managed settings allow only managed permission rules. Rules from other settings files are shown below but are not in effect."
.Lp_none: .asciz "No permission rules are saved."
.Lp_hint: .asciz "Choosing an \342\200\234Always\342\200\235 option on a permission prompt saves a rule here."
.Lp_hint_edit: .asciz "Choosing an \342\200\234Always\342\200\235 option on a permission prompt saves a rule here, or add one below."
.Lp_add_rule: .asciz "Add rule\342\200\246"
.Lp_from: .asciz "From "
.Lp_not_in_effect: .asciz " (not in effect)"
.Lp_session_only: .asciz " (this session only)"
.Lp_workspace: .asciz "Workspace ("
.Lp_original: .asciz "Original working directory"
.Lp_scope_note: .asciz "Rules and workspace directories come from the running session, including approvals made for this session only and rules set when the session started. Workspace directories are listed here for reference."
.Lp_scope_note_edit: .asciz "Rules and workspace directories come from the running session, including approvals made for this session only and rules set when the session started. Rules you add or remove here are written to the settings file you choose. Workspace directories are listed here for reference."
.Lp_remove_q: .asciz "Remove "
.Lp_rule_q: .asciz " rule?"
.Lp_remove_note: .asciz "The rule is deleted from its settings file and stops applying to this session once Claude Code has re-read its settings."
.Lp_couldnt_remove: .asciz "Couldn\342\200\231t remove the rule: "
.Lp_remove_rule: .asciz "Remove rule"
.Lp_removing: .asciz "Removing\342\200\246"
.Lp_add_q: .asciz "Add "
.Lp_rule_word: .asciz " rule"
.Lp_add_note: .asciz "A permission rule is a tool name, optionally followed by a specifier in parentheses, e.g. WebFetch or Bash(ls *)."
.Lp_placeholder: .asciz "Enter permission rule\342\200\246"
.Lp_save_for: .asciz "Save for"
.Lp_couldnt_add: .asciz "Couldn\342\200\231t add the rule: "
.Lp_add_btn: .asciz "Add rule"
.Lp_adding: .asciz "Adding\342\200\246"
.Lp_thing: .asciz "the permission rule"
.Lp_saved_to: .asciz "Saved to "
.Lp_not_listed: .asciz ". Not listed yet: this session is still re-reading its settings (reopen this dialog to check)"
.Lp_not_listed_allow: .asciz ", or it ignores this rule (in auto permission mode, allow rules for risky commands are not applied)."
.Lp_removed_from: .asciz "Removed from "
.Lp_still_shown: .asciz ". If the rule is still shown, Claude Code is still re-reading its settings; reopen this dialog to check."
.La_edit_rules: .asciz "edit-permission-rules"
.La_edit_sandbox: .asciz "edit-sandbox-settings"
.La_json: .asciz "--json"
.Ls_loading: .asciz "Loading\342\200\246"
.Ls_exclude_sp: .asciz "exclude "
.Ls_shape: .asciz "The sandbox dialog reply was not in the expected shape"
.Ls_cloud_key: .asciz "not available in a cloud-hosted session"
.Ls_cloud: .asciz "The sandbox settings can't be shown or changed here while this session runs in the cloud."
.Ls_pending: .asciz "Saved, but this session still shows the previous value. A higher-priority setting may be overriding it, or the session hasn't picked the change up yet."
.Ls_wsl1: .asciz "Sandboxing needs WSL2; it is not available on WSL1."
.Ls_excl_platform: .asciz "Sandboxing is turned off for this platform by your organization's settings."
.Ls_unsup: .asciz "Sandboxing is not available on this platform."
.Ls_locked: .asciz "These settings are set by a higher-priority configuration and cannot be changed here."
.Ls_missing: .asciz "The sandbox cannot run until the missing dependencies below are installed."
.Ls_on_cannot: .asciz "The sandbox is on in the settings but cannot run: "
.Ls_on_not_started: .asciz "The sandbox is on in the settings but did not start in this session; start a new session to try again."
.Ls_mode: .asciz "Mode"
.Ls_auto: .asciz "Sandbox commands, with auto-allow"
.Ls_auto_d: .asciz "Sandboxed commands run without a permission prompt; your ask and deny rules still apply"
.Ls_regular: .asciz "Sandbox commands, with regular permissions"
.Ls_regular1: .asciz "Sandbox commands"
.Ls_regular_d: .asciz "Commands run inside the sandbox; the usual permission prompts apply"
.Ls_none: .asciz "No sandbox"
.Ls_none_d: .asciz "Commands run outside the sandbox"
.Ls_overrides: .asciz "Overrides"
.Ls_fallback: .asciz "Allow unsandboxed fallback"
.Ls_fb_on: .asciz "When a command fails because of a sandbox restriction, Claude may retry it outside the sandbox, with the usual permission prompts."
.Ls_fb_off: .asciz "Every command Claude runs must run in the sandbox, unless its pattern is excluded below."
.Ls_turn_on: .asciz " Turn the sandbox on to change this."
.Ls_higher: .asciz " Set by a higher-priority configuration."
.Ls_excluded: .asciz "Excluded commands"
.Ls_excl_help: .asciz "Commands matching these patterns run outside the sandbox."
.Ls_none_word: .asciz "None"
.Ls_pattern_ph: .asciz "Command pattern, for example npm run test:*"
.Ls_exclude_btn: .asciz "Exclude"
.Ls_deps: .asciz "Dependencies"
.Ls_net_managed: .asciz "The allowed domains are set by a higher-priority configuration."
.Ls_restrictions: .asciz "Restrictions"
.Ls_r_deny_read: .asciz "Denied reads"
.Ls_r_allow_read: .asciz "Allowed within denied reads"
.Ls_r_allow_write: .asciz "Allowed writes"
.Ls_r_deny_write: .asciz "Denied within allowed writes"
.Ls_r_domains: .asciz "Allowed domains"
.Ls_r_domains_m: .asciz "Allowed domains (managed)"
.Ls_r_denied_domains: .asciz "Denied domains"
.Ls_r_sockets: .asciz "Allowed Unix sockets"
.Ls_r_globs: .asciz "Patterns ignored on Linux"
.Ls_thing: .asciz "the sandbox setting"
.Ls_added: .asciz "Added \""
.Ls_added2: .asciz "\" to the excluded commands"
