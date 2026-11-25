# Claude Code's Hooks dialog (claude-chat-p7b; ext-webview-ui.md 6.7, 6.8), a module of claude_dlg2.s: the
# hooks the session's process lists (get_hooks_listing: events, hooks, eventCatalog, policy; README finding
# 82) grouped by event and matcher with their type and source badges; a hook the listing marks editable
# opens in the editor (Event, Matcher, Type and the type's fields, as the extension's Lle and Rle), the
# others read-only with why. Saving and removing go through `claude edit-hook --json` (finding 83) with
# exactly what the form shows; the listing is then read again until it changes, as the extension does.
# A hook's HTTP header values are never shown: the field lists the names, and a field left as it was keeps
# the stored values (the extension's headerLines).
.include "rhun.inc"

.equ HP_LIST, 0                 # pages
.equ HP_DETAIL, 1
.equ HP_EDIT, 2
.equ HP_EVENT, 3
.equ HA_HOOK, 1                 # acts (arg: the hook's index)
.equ HA_BACK, 2
.equ HA_ADD, 3
.equ HA_LEARN, 4
.equ HA_SOURCE, 5               # (arg: 0 local, 1 user, 2 project)
.equ HA_EVENTS, 6
.equ HA_PICKEV, 7               # (arg: the event's index in the catalog)
.equ HA_TYPE, 8                 # (arg: the type)
.equ HA_SHELL, 9                # (arg: 0 default, 1 bash, 2 powershell)
.equ HA_CHECK, 10               # (arg: the field's index)
.equ HA_SAVE, 11
.equ HA_REMOVE, 12
.equ HA_CONFIRM, 13
.equ HA_CANCEL, 14
.equ HA_OPENFILE, 15              # a refusal's settings file opened (Open settings file)
.equ HA_COPYERR, 16               # a refusal's error copied (Copy error)
.equ HR_LIST, 1
.equ HW_SAVE, 1
.equ HW_REMOVE, 2
.equ TRIES, 14
.equ FK_TEXT, 1                 # a field's kind
.equ FK_AREA, 2
.equ FK_JSONA, 3
.equ FK_JSONO, 4
.equ FK_NUM, 5
.equ FK_LINES, 6
.equ FK_HDR, 7
.equ FK_CHECK, 8
.equ FK_SHELL, 9
.equ FD_key, 0                  # a field: key, label, placeholder, TF* (0: a check or the shell), kind, the
.equ FD_label, 8                #   types it belongs to (bits: command 1, prompt 2, agent 4, http 8,
.equ FD_ph, 16                  #   mcp_tool 16, all 31), required
.equ FD_tf, 24                  #   (tf_of)
.equ FD_kind, 32
.equ FD_mask, 36
.equ FD_req, 40
.equ FD_SIZE, 48
.equ FIELDS_N, 16
.equ TYPES_N, 5

.bss
.p2align 3
h_source: .quad 0               # the form: where an added hook is saved (0 local, 1 user, 2 project)
h_type: .quad 0                 #   its type (0 command .. 4 mcp_tool)
h_shell: .quad 0
h_checks: .zero 8 * FIELDS_N    #   the checks' values, by field
h_event: .quad 0                # owned cstr: the event chosen
h_edit: .quad 0                 # the hook edited (its index), -1 a new one
h_confirm: .quad 0              # Remove asked
h_tries: .quad 0
h_orig: .zero SB_SIZE           # the hook edited: its config as JSON text, its matcher, event, source
h_omatch: .quad 0               # owned cstrs
h_oevent: .quad 0
h_osource: .quad 0
h_otype: .quad 0                # its type's index
h_refpath: .quad 0              # owned cstrs: a refusal's settings file and its error, as edit-hook said them
h_referr: .quad 0
h_hdr0: .zero SB_SIZE           # the headers field as it was filled (names only)
h_tfs: .zero TF_SIZE * FIELDS_N # the fields' text (FD_tf points here)
h_tf_matcher: .zero TF_SIZE
tsb: .zero SB_SIZE              # scratch
tsb2: .zero SB_SIZE

.text

.globl hooks_open, hooks_act, hooks_answer, hooks_ran, hooks_send, hooks_free, hooks_tick

hooks_open:
    PROLOGUE
    mov qword ptr [rip + h_tries], 0
    lea rdi, [rip + .Lh_waiting]
    call agentdlg_loading
    mov edi, HR_LIST
    call c2_ask
    EPILOGUE

hooks_free:
    PROLOGUE
    call form_clear
    mov qword ptr [rip + h_tries], 0
    EPILOGUE

hooks_send:
    mov rdi, rsi
    lea rsi, [rip + .Lv_listing]
    jmp claude_dlg2_begin

hooks_tick:
    PROLOGUE
    mov edi, HR_LIST
    call c2_ask
    EPILOGUE

# form_clear(): the form's fields wiped, what it kept freed
form_clear:
    PROLOGUE
    xor ebx, ebx
1:  cmp ebx, FIELDS_N
    jae 2f
    imul rdi, rbx, TF_SIZE
    lea rax, [rip + h_tfs]
    add rdi, rax
    call c2_wipe_tf
    inc ebx
    jmp 1b
2:  lea rdi, [rip + h_tf_matcher]
    call c2_wipe_tf
    lea rdi, [rip + h_checks]
    mov ecx, FIELDS_N
3:  mov qword ptr [rdi], 0
    add rdi, 8
    dec ecx
    jnz 3b
    lea rdi, [rip + h_orig]
    call sb_clear
    lea rdi, [rip + h_hdr0]
    call sb_clear
    lea rax, [rip + h_event]
    call free_q
    lea rax, [rip + h_omatch]
    call free_q
    lea rax, [rip + h_oevent]
    call free_q
    lea rax, [rip + h_osource]
    call free_q
    call ref_clear
    mov qword ptr [rip + h_confirm], 0
    mov qword ptr [rip + h_shell], 0
    EPILOGUE

# ref_clear(): no refusal kept
ref_clear:
    PROLOGUE
    lea rax, [rip + h_refpath]
    call free_q
    lea rax, [rip + h_referr]
    call free_q
    EPILOGUE

# ref_keep(slot rax, ptr, len): an owned copy of the string in the slot (none for an empty one)
ref_keep:
    PROLOGUE
    mov rbx, rax
    mov r12, rdi
    mov r13, rsi
    call free_q
    test r13, r13
    jz 9f
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rbx], rax
9:  EPILOGUE

# ref_rows(): under a refusal's words, Open settings file and Copy error (the extension's LMn)
ref_rows:
    PROLOGUE
    cmp qword ptr [rip + h_refpath], 0
    je 9f
    cmp qword ptr [rip + c2_err + SB_len], 0
    je 9f
    lea rdi, [rip + .Lh_open_file]
    mov esi, HA_OPENFILE
    call c2_link
    cmp qword ptr [rip + h_referr], 0
    je 9f
    lea rdi, [rip + .Lh_copy_error]
    mov esi, HA_COPYERR
    call c2_link
9:  EPILOGUE

# free_q(rax: an owned cstr's slot): freed, 0
free_q:
    push rbx
    mov rbx, rax
    mov rdi, [rbx]
    call mem_free
    mov qword ptr [rbx], 0
    pop rbx
    ret

# tf_of(FD*) -> rax its TF, 0 none
tf_of:
    mov rax, [rdi + FD_tf]
    test rax, rax
    jz 1f
    dec rax
    imul rax, rax, TF_SIZE
    lea rcx, [rip + h_tfs]
    add rax, rcx
1:  ret

# fd(i) -> rax the i-th field's descriptor
fd:
    imul rax, rdi, FD_SIZE
    lea rcx, [rip + fields]
    add rax, rcx
    ret

# hooks_answer(rq, envelope): the listing kept; after a write, read again until it changed
hooks_answer:
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
    call c2_err_set
    mov qword ptr [rip + h_tries], 0
    call hooks_build
    EPILOGUE
1:  mov rdi, rbx
    call c2_resp
    mov rsi, rax
    lea rdi, [rip + c2_doc]
    call c2_keep
    cmp qword ptr [rip + h_tries], 0
    je 8f
    lea rdi, [rip + c2_doc]     # the hooks as they were before the write (c2_doc3): changed yet?
    lea rsi, [rip + c2_doc3]
    call same_hooks
    test eax, eax
    jz 5f
    dec qword ptr [rip + h_tries]
    jz 3f
    mov qword ptr [rip + c2_busy], HA_SAVE
    mov edi, 300
    call c2_later
    EPILOGUE
3:  call f_clr                  # not yet: the extension's notice
    lea rdi, [rip + .Lh_saved_to]
    call f_c
    mov rdi, [rip + h_osource]
    call badge_of
    mov rdi, rax
    call lower_f
    lea rdi, [rip + .Lh_saved_to2]
    call f_c
    call c2_msg_fsb
5:  mov qword ptr [rip + h_tries], 0
    mov qword ptr [rip + c2_busy], 0
    mov qword ptr [rip + c2_page], HP_LIST
    call form_clear
8:  call hooks_build
    EPILOGUE

# same_hooks(sb, sb) -> eax 1 when their "hooks" members are the same JSON text
same_hooks:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call c2_parse
    mov rdi, rax
    lea rsi, [rip + .Lk_hooks]
    call json_get
    mov rsi, rax
    lea rdi, [rip + tsb]
    call c2_keep
    mov rdi, r12
    call c2_parse
    mov rdi, rax
    lea rsi, [rip + .Lk_hooks]
    call json_get
    mov rsi, rax
    lea rdi, [rip + tsb2]
    call c2_keep
    xor eax, eax
    mov rcx, [rip + tsb + SB_len]
    cmp rcx, [rip + tsb2 + SB_len]
    jne 9f
    mov rsi, [rip + tsb + SB_ptr]
    mov rdi, [rip + tsb2 + SB_ptr]
    xor edx, edx
1:  cmp rdx, rcx
    jae 2f
    movzx eax, byte ptr [rsi + rdx]
    cmp al, [rdi + rdx]
    jne 3f
    inc rdx
    jmp 1b
2:  mov eax, 1
    jmp 9f
3:  xor eax, eax
9:  EPILOGUE

# lower_f(cstr): fsb += it in lower case (ASCII)
lower_f:
    PROLOGUE
    mov rbx, rdi
1:  movzx esi, byte ptr [rbx]
    test esi, esi
    jz 9f
    inc rbx
    lea eax, [rsi - 'A']
    cmp eax, 25
    ja 2f
    or esi, 0x20
2:  lea rdi, [rip + fsb]
    call sb_push_byte
    jmp 1b
9:  EPILOGUE

# badge_of(source cstr or 0) -> rax its badge (Nle): User, Project, Local, Flag, Managed, Session, Plugin,
#   Built-in, else itself
badge_of:
    PROLOGUE
    mov rbx, rdi
    lea rax, [rip + .Lempty]
    test rbx, rbx
    jz 9f
    lea r12, [rip + badges]
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

# policy_flag(listing, key) -> eax its policy's flag
policy_flag:
    push rbx
    push rsi
    sub rsp, 8                  # (the calls' stack aligned)
    lea rsi, [rip + .Lk_policy]
    call json_get
    mov rdi, rax
    mov rsi, [rsp + 8]
    call c2_jbool
    add rsp, 16
    pop rbx
    ret

# can_edit(listing) -> eax 1 when hooks may be added and edited here: a catalog, and the policy does not
#   forbid it (XMt)
can_edit:
    PROLOGUE
    mov rbx, rdi
    lea rsi, [rip + .Lk_catalog]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_ARR
    jne 8f
    lea r12, [rip + locks]
1:  mov rsi, [r12]
    test rsi, rsi
    jz 7f
    mov rdi, rbx
    call policy_flag
    test eax, eax
    jnz 8f
    add r12, 8
    jmp 1b
7:  mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# hooks_n_f(n): fsb += "N hook" or "N hooks" (fU)
hooks_n_f:
    PROLOGUE
    mov rbx, rdi
    call f_u
    lea rdi, [rip + .Lh_hook]
    cmp rbx, 1
    je 1f
    lea rdi, [rip + .Lh_hooks]
1:  call f_c
    EPILOGUE

# hooks_build(): the page shown
hooks_build:
    PROLOGUE 48
    call agentdlg_begin
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    test rax, rax
    jnz 1f
    call c2_msgs
    EPILOGUE
1:  cmp qword ptr [rip + c2_page], HP_EVENT
    je 11f
    xor edi, edi                # only the events' page has a filter
    call agentdlg_x_filter
11: mov rax, [rip + c2_page]
    cmp rax, HP_EDIT
    je .Lhb_edit
    cmp rax, HP_EVENT
    je .Lhb_event
    cmp rax, HP_DETAIL
    je .Lhb_detail
    xor edi, edi
    call agentdlg_back
    mov rdi, rbx
    call can_edit
    mov [rsp], eax              # l: it can edit
    call c2_msgs
    mov rdi, rbx                # a settings file that failed: its hooks are not shown
    lea rsi, [rip + .Lk_errors]
    call json_get
    mov rdi, rax
    call json_len
    test eax, eax
    jz 2f
    lea rdi, [rip + .Lh_files_failed]
    mov esi, DGF_ERROR
    call c2_text
2:  mov rdi, rbx                # safe mode, bare mode
    lea rsi, [rip + .Lk_safeMode]
    call json_get
    test rax, rax
    jz 21f
    mov r12, rax
    call f_clr
    lea rdi, [rip + .Lh_safe]
    call f_c
    mov rdi, r12
    lea rsi, [rip + .Lk_managedStill]
    call c2_jbool
    test eax, eax
    jz 201f
    lea rdi, [rip + .Lh_safe_managed]
    call f_c
201:lea rdi, [rip + .Lh_safe2]
    call f_c
    mov rdi, r12
    call exit_hint_f
    mov edi, DGF_MUTED
    call c2_ftext
21: mov rdi, rbx
    lea rsi, [rip + .Lk_bareMode]
    call json_get
    test rax, rax
    jz 22f
    mov r12, rax
    call f_clr
    lea rdi, [rip + .Lh_bare]
    call f_c
    mov rdi, r12
    call exit_hint_f
    mov edi, DGF_MUTED
    call c2_ftext
22: mov rdi, rbx
    lea rsi, [rip + .Lk_policyUnreadable]
    call policy_flag
    test eax, eax
    jz 23f
    lea rdi, [rip + .Lh_unreadable]
    mov esi, DGF_MUTED
    call c2_text
23: mov rdi, rbx
    lea rsi, [rip + .Lk_hooks]
    call json_get
    mov r12, rax                # the rows
    mov rdi, rax
    call json_len
    mov [rsp + 4], eax          # their count
    xor r13d, r13d              # the disabled ones
    xor r14d, r14d
24: cmp r14d, [rsp + 4]
    jae 25f
    mov rdi, r12
    mov esi, r14d
    call json_at
    inc r14d
    mov rdi, rax
    lea rsi, [rip + .Lk_disabled]
    call c2_jbool
    add r13d, eax
    jmp 24b
25: mov rdi, rbx
    lea rsi, [rip + .Lk_disabledByPolicy]
    call policy_flag
    test eax, eax
    jz 3f
    call f_clr                  # all off by a managed file
    lea rdi, [rip + .Lh_policy_off]
    call f_c
    mov edi, r13d
    call hooks_n_f
    lea rdi, [rip + .Lh_wont_run]
    call f_c
    mov edi, DGF_MUTED
    call c2_ftext
    jmp .Lhb_groups
3:  mov rdi, rbx
    lea rsi, [rip + .Lk_managedOnly]
    call policy_flag
    mov r14d, eax
    mov rdi, rbx
    lea rsi, [rip + .Lk_pluginOnly]
    call policy_flag
    or eax, r14d
    jz 4f
    lea rdi, [rip + .Lh_managed_only]
    test r14d, r14d
    jnz 31f
    lea rdi, [rip + .Lh_plugin_only]
31: mov esi, DGF_MUTED
    call c2_text
    jmp .Lhb_groups
4:  mov rdi, rbx
    lea rsi, [rip + .Lk_allDisabled]
    call policy_flag
    test eax, eax
    jz 5f
    call f_clr                  # disableAllHooks
    lea rdi, [rip + .Lh_all_off]
    call f_c
    mov edi, r13d
    call hooks_n_f
    lea rdi, [rip + .Lh_wont_run]
    call f_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_policy]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lk_policyCount]
    call json_get
    mov rdi, rax
    call json_int
    test rax, rax
    jle 41f
    mov r14, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_bareMode]
    call json_get
    test rax, rax
    jnz 41f
    lea rdi, [rip + .Lh_managed_still]
    call f_c
    mov rdi, r14
    call hooks_n_f
    lea rdi, [rip + .Ldot]
    call f_c
41: mov edi, DGF_MUTED
    call c2_ftext
    jmp .Lhb_groups
5:  cmp dword ptr [rsp + 4], 0
    jne 6f
    lea rdi, [rip + .Lh_none]   # none
    xor esi, esi
    call c2_text
    lea rdi, [rip + .Lh_none_hint]
    cmp dword ptr [rsp], 0
    jne 51f
    lea rdi, [rip + .Lh_none_hint2]
51: mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
    jmp .Lhb_foot
6:  call f_clr                  # "N hooks configured"
    mov edi, [rsp + 4]
    call hooks_n_f
    lea rdi, [rip + .Lh_configured]
    call f_c
    mov edi, DGF_MUTED
    call c2_ftext
.Lhb_groups:
    mov rdi, rbx
    mov rsi, r12
    call groups
.Lhb_foot:
    lea rdi, [rip + .Lh_foot_edit]
    cmp dword ptr [rsp], 0
    jne 7f
    lea rdi, [rip + .Lh_foot]
7:  mov esi, DGF_MUTED | DGF_SMALL
    call c2_text
    lea rdi, [rip + .Lh_learn]
    mov esi, HA_LEARN
    call c2_link
    cmp dword ptr [rsp], 0
    je 9f
    lea rdi, [rip + .Lh_add]
    mov esi, HA_ADD
    mov edx, DBF_PRIMARY
    call agentdlg_button
9:  EPILOGUE
.Lhb_detail:
    mov rdi, rbx
    call detail_rows
    EPILOGUE
.Lhb_edit:
    mov rdi, rbx
    call edit_rows
    EPILOGUE
.Lhb_event:
    mov edi, HA_BACK            # the events of the catalog: pick one
    call agentdlg_back
    lea rdi, [rip + .Lh_filter_events]
    call agentdlg_x_filter
    mov rdi, rbx
    lea rsi, [rip + .Lk_catalog]
    call json_get
    mov r12, rax
    xor r13d, r13d
1:  mov rdi, r12
    call json_len
    cmp r13d, eax
    jae 9b
    mov rdi, r12
    mov esi, r13d
    call json_at
    inc r13d
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + h_event]
    xor ecx, ecx
    test rdx, rdx
    jz 2f
    call str_eq_cstr
    mov ecx, eax
2:  mov esi, DGF_FILTER
    test ecx, ecx
    jz 3f
    or esi, DGF_CHECK
3:  mov edi, DGK_ITEM
    mov edx, HA_PICKEV
    call agentdlg_row
    mov r15, rax
    lea eax, [r13 - 1]
    mov [r15 + DGR_arg], rax
    mov rdi, r14
    lea rsi, [rip + .Lk_name]
    mov edx, 200
    call c2_jcl
    mov rdi, r15
    xor esi, esi
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    mov rdi, r14
    lea rsi, [rip + .Lk_summary]
    mov edx, 400
    call c2_jcl
    mov rdi, r15
    mov esi, 1
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    jmp 1b

# exit_hint_f(mode object): fsb += " " + its exitHint capitalized + " to re-enable."
exit_hint_f:
    PROLOGUE
    lea rsi, [rip + .Lk_exitHint]
    mov edx, 400
    call c2_jcl
    mov rbx, rax
    mov r12, rdx
    lea rdi, [rip + .Lspace]
    call f_c
    test r12, r12
    jz 1f
    movzx esi, byte ptr [rbx]
    lea eax, [rsi - 'a']
    cmp eax, 25
    ja 2f
    and esi, 0xdf
2:  lea rdi, [rip + fsb]
    call sb_push_byte
    lea rdi, [rbx + 1]
    lea rsi, [r12 - 1]
    call f_n
1:  lea rdi, [rip + .Lh_reenable]
    call f_c
    EPILOGUE

# event_meta(listing, name ptr, len) -> rax its events[] entry (summary, supportsMatcher), 0 none
event_meta:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    lea rsi, [rip + .Lk_events]
    call json_get
    mov rbx, rax
    xor r14d, r14d
1:  mov rdi, rbx
    call json_len
    cmp r14d, eax
    jae 8f
    mov rdi, rbx
    mov esi, r14d
    call json_at
    inc r14d
    mov r15, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    cmp rdx, r13
    jne 1b
    mov rdi, rax
    mov rsi, r12
    mov rdx, r13
    call bytes_eq
    test eax, eax
    jz 1b
    mov rax, r15
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# bytes_eq(a, b, len) -> eax 1 when the same
bytes_eq:
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

# str_member_eq(obj a, obj b, key) -> eax 1 when the string members are the same
str_member_eq:
    PROLOGUE
    mov rbx, rsi
    mov r12, rdx
    mov rsi, r12
    call c2_jstr
    mov r13, rax
    mov r14, rdx
    mov rdi, rbx
    mov rsi, r12
    call c2_jstr
    cmp rdx, r14
    jne 8f
    mov rdi, rax
    mov rsi, r13
    mov rdx, r14
    call bytes_eq
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# event_matchers(listing, hooks, event row) -> eax 1 when its event shows matchers (supportsMatcher, else
#   any of its hooks has one)
event_matchers:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r13
    lea rsi, [rip + .Lk_event]
    call c2_jstr
    mov rdi, rbx
    mov rsi, rax
    call event_meta
    test rax, rax
    jz 1f
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_supportsMatcher]
    call json_get
    test rax, rax
    jz 1f
    mov rdi, r14
    lea rsi, [rip + .Lk_supportsMatcher]
    call c2_jbool
    EPILOGUE
1:  xor r14d, r14d              # any hook of that event with a matcher
2:  mov rdi, r12
    call json_len
    cmp r14d, eax
    jae 8f
    mov rdi, r12
    mov esi, r14d
    call json_at
    inc r14d
    mov r15, rax
    mov rdi, rax
    mov rsi, r13
    lea rdx, [rip + .Lk_event]
    call str_member_eq
    test eax, eax
    jz 2b
    mov rdi, r15
    lea rsi, [rip + .Lk_matcher]
    call c2_jstr
    test rdx, rdx
    jz 2b
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# groups(listing, hooks): by event (in the order they come), then by matcher: the event's heading (its
#   name, its count), its summary, "Matcher: M" when it has matchers, a row a hook (type, text, source badge)
groups:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d              # the hook that starts a group
1:  mov rdi, r12
    call json_len
    cmp r13d, eax
    jae 9f
    mov rdi, r12
    mov esi, r13d
    call json_at
    mov r14, rax                # its first hook
    inc r13d
    xor r15d, r15d              # its event came before?
2:  lea eax, [r13 - 1]
    cmp r15d, eax
    jae 3f
    mov rdi, r12
    mov esi, r15d
    call json_at
    inc r15d
    mov rdi, rax
    mov rsi, r14
    lea rdx, [rip + .Lk_event]
    call str_member_eq
    test eax, eax
    jnz 1b
    jmp 2b
3:  mov rdi, r12                # its count
    mov rsi, r14
    call event_count
    mov [rsp], eax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r14
    call event_matchers
    mov [rsp + 4], eax
    call f_clr
    mov rdi, r14
    lea rsi, [rip + .Lk_event]
    mov edx, 200
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call c2_frow
    mov [rsp + 8], rax
    call f_clr
    mov edi, [rsp]
    call hooks_n_f
    mov rdi, [rsp + 8]
    mov esi, 2
    call c2_fset
    mov rdi, r14                # its summary
    lea rsi, [rip + .Lk_event]
    call c2_jstr
    mov rdi, rbx
    mov rsi, rax
    call event_meta
    test rax, rax
    jz 4f
    mov rdi, rax
    lea rsi, [rip + .Lk_summary]
    mov edx, 400
    call c2_jcl
    test rdx, rdx
    jz 4f
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    mov edi, DGK_TEXT
    mov esi, DGF_MUTED | DGF_SMALL
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    call agentdlg_text
4:  lea eax, [r13 - 1]          # its matchers, each with its hooks
    mov [rsp + 32], eax
5:  mov eax, [rsp + 32]
    mov rdi, r12
    push rax
    push rax
    call json_len
    pop rcx
    pop rcx
    cmp ecx, eax
    jae 1b
    mov rdi, r12
    mov esi, ecx
    call json_at
    mov r15, rax                # a hook of this event
    inc dword ptr [rsp + 32]
    mov rdi, rax
    mov rsi, r14
    lea rdx, [rip + .Lk_event]
    call str_member_eq
    test eax, eax
    jz 5b
    mov ecx, [rsp + 32]         # its matcher came before in this event?
    dec ecx
    mov [rsp + 36], ecx
    xor eax, eax
    mov [rsp + 40], eax
51: mov eax, [rsp + 40]
    cmp eax, [rsp + 36]
    jae 52f
    mov rdi, r12
    mov esi, eax
    call json_at
    inc dword ptr [rsp + 40]
    mov [rsp + 16], rax
    mov rdi, rax
    mov rsi, r14
    lea rdx, [rip + .Lk_event]
    call str_member_eq
    test eax, eax
    jz 51b
    mov rdi, [rsp + 16]
    mov rsi, r15
    lea rdx, [rip + .Lk_matcher]
    call str_member_eq
    test eax, eax
    jnz 5b                      # (shown with the first)
    jmp 51b
52: cmp dword ptr [rsp + 4], 0  # "Matcher: M"
    je 53f
    call f_clr
    lea rdi, [rip + .Lh_matcher_c]
    call f_c
    mov rdi, r15
    lea rsi, [rip + .Lk_matcher]
    mov edx, 400
    call c2_jcl
    test rdx, rdx
    jnz 521f
    lea rax, [rip + .Lh_all]
    mov edx, 5
521:mov rdi, rax
    mov rsi, rdx
    call f_n
    mov edi, DGF_SMALL
    call c2_ftext
53: mov ecx, [rsp + 36]         # the hooks of this event and matcher, from this one
    mov [rsp + 40], ecx
54: mov eax, [rsp + 40]
    mov rdi, r12
    push rax
    push rax
    call json_len
    pop rcx
    pop rcx
    cmp ecx, eax
    jae 5b
    mov rdi, r12
    mov esi, ecx
    call json_at
    inc dword ptr [rsp + 40]
    mov [rsp + 16], rax
    mov rdi, rax
    mov rsi, r14
    lea rdx, [rip + .Lk_event]
    call str_member_eq
    test eax, eax
    jz 54b
    mov rdi, [rsp + 16]
    mov rsi, r15
    lea rdx, [rip + .Lk_matcher]
    call str_member_eq
    test eax, eax
    jz 54b
    mov rdi, [rsp + 16]
    mov esi, [rsp + 40]
    dec esi
    call hook_row
    jmp 54b
9:  EPILOGUE

# event_count(hooks, hook) -> eax the hooks of its event
event_count:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
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
    mov rsi, r12
    lea rdx, [rip + .Lk_event]
    call str_member_eq
    add r14d, eax
    jmp 1b
9:  mov eax, r14d
    EPILOGUE

# hook_row(hook, index): its row: t1 what it runs (its status message when it has one), t2 its type, t3 its
#   source's badge (", Disabled" when off)
hook_row:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    mov edi, DGK_ITEM
    xor esi, esi
    mov edx, HA_HOOK
    call agentdlg_row
    mov r13, rax
    mov [r13 + DGR_arg], r12
    mov rdi, rbx
    lea rsi, [rip + .Lk_displayText]
    mov edx, 300
    call c2_jcl
    mov rdi, r13
    xor esi, esi
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    mov edx, 100
    call c2_jcl
    mov rdi, r13
    mov esi, 1
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
    call f_clr
    mov rdi, rbx
    lea rsi, [rip + .Lk_source]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov r14, rax
    mov rdi, rax
    call badge_of
    mov rdi, rax
    call strlen
    mov rsi, rax
    mov rdi, r14
    push rsi
    push rsi
    call badge_of
    pop rsi
    pop rsi
    mov rdi, rax
    mov edx, 100
    call f_cl
    mov rdi, r14
    call mem_free
    mov rdi, rbx
    lea rsi, [rip + .Lk_disabled]
    call c2_jbool
    test eax, eax
    jz 1f
    lea rdi, [rip + .Lh_disabled_badge]
    call f_c
1:  mov rdi, r13
    mov esi, 2
    call c2_fset
    EPILOGUE

# type_of(ptr, len) -> rax the type's index (0 command .. 4 mcp_tool), -1 another
type_of:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
1:  cmp r13d, TYPES_N
    jae 8f
    lea rax, [rip + type_ids]
    mov rdx, [rax + r13*8]
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r13d
    jmp 1b
2:  mov eax, r13d
    EPILOGUE
8:  mov rax, -1
    EPILOGUE

# editable(listing, hook) -> eax 1 when the editor opens it: it has editable, the listing a catalog the
#   policy lets be used, and its type is one of the five
editable:
    PROLOGUE
    mov rbx, rsi
    call can_edit
    test eax, eax
    jz 9f
    mov rdi, rbx
    lea rsi, [rip + .Lk_editable]
    call json_get
    test rax, rax
    jz 8f
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call type_of
    cmp rax, -1
    je 8f
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# detail_rows(listing): a hook that cannot be edited here: its event, why, its fields, what it runs
detail_rows:
    PROLOGUE 16
    mov rbx, rdi
    mov edi, HA_BACK
    call agentdlg_back
    mov rdi, rbx
    lea rsi, [rip + .Lk_hooks]
    call json_get
    mov rdi, rax
    mov rsi, [rip + c2_arg]
    call json_at
    mov r12, rax
    test rax, rax
    jz 9f
    mov rdi, r12
    lea rsi, [rip + .Lk_event]
    mov edx, 200
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_clr
    mov rdi, r12
    lea rsi, [rip + .Lk_event]
    mov edx, 200
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    mov edi, DGK_HEAD
    xor esi, esi
    xor edx, edx
    call c2_frow
    mov rdi, r12
    lea rsi, [rip + .Lk_disabled]
    call c2_jbool
    test eax, eax
    jz 1f
    lea rdi, [rip + .Lh_disabled_warn]
    mov esi, DGF_MUTED
    call c2_text
1:  mov rdi, r12                # why it is read-only (xMn), else the lock's or the type's
    mov rsi, rbx
    call why_f
    test eax, eax
    jz 2f
    mov edi, DGF_MUTED
    call c2_ftext
2:  lea rdi, [rip + .Lh_event]
    lea rsi, [rip + .Lk_event]
    call pair
    mov rdi, rbx
    lea rsi, [rip + .Lk_hooks]
    call json_get
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    call event_matchers
    test eax, eax
    jz 3f
    mov rdi, r12
    lea rsi, [rip + .Lk_matcher]
    call c2_jstr
    test rdx, rdx
    jnz 21f
    lea rdi, [rip + .Lh_matcher]
    lea rsi, [rip + .Lh_all]
    call pair_c
    jmp 3f
21: lea rdi, [rip + .Lh_matcher]
    lea rsi, [rip + .Lk_matcher]
    call pair
3:  lea rdi, [rip + .Lh_type]
    lea rsi, [rip + .Lk_type]
    call pair
    lea rdi, [rip + .Lh_source]
    lea rsi, [rip + .Lk_sourceLabel]
    call pair
    lea rdi, [rip + .Lh_plugin]
    lea rsi, [rip + .Lk_pluginName]
    call pair
    lea rdi, [rip + .Lh_if]
    lea rsi, [rip + .Lk_condition]
    call pair
    mov rdi, r12                # Timeout "Ns"
    lea rsi, [rip + .Lk_timeout]
    call json_get
    mov rdi, rax
    call json_num_text
    test rdx, rdx
    jz 4f
    mov [rsp], rax
    mov [rsp + 8], rdx
    call f_clr
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov edx, 40
    call f_cl
    lea rdi, [rip + .Ls]
    call f_c
    mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    lea rcx, [rip + .Lh_timeout]
    xor r8d, r8d
    xor r9d, r9d
    call c2_crow
    mov rdi, rax
    mov esi, 1
    call c2_fset
4:  lea rdi, [rip + .Lh_status]
    lea rsi, [rip + .Lk_statusMessage]
    call pair
    call f_clr                  # Flags: runs once, runs in background
    mov rdi, r12
    lea rsi, [rip + .Lk_runsOnce]
    call c2_jbool
    test eax, eax
    jz 41f
    lea rdi, [rip + .Lh_once]
    call f_c
41: mov rdi, r12
    lea rsi, [rip + .Lk_runsInBackground]
    call c2_jbool
    test eax, eax
    jz 42f
    cmp qword ptr [rip + fsb + SB_len], 0
    je 43f
    lea rdi, [rip + .Lcomma]
    call f_c
43: lea rdi, [rip + .Lh_bg]
    call f_c
42: cmp qword ptr [rip + fsb + SB_len], 0
    je 5f
    mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    lea rcx, [rip + .Lh_flags]
    xor r8d, r8d
    xor r9d, r9d
    call c2_crow
    mov rdi, rax
    mov esi, 1
    call c2_fset
5:  mov rdi, r12                # what it runs, under its label
    lea rsi, [rip + .Lk_contentLabel]
    mov edx, 100
    call c2_jcl
    test rdx, rdx
    jz 6f
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov edi, DGK_TEXT
    mov esi, DGF_SMALL | DGF_MUTED
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    call agentdlg_text
6:  mov rdi, r12
    lea rsi, [rip + .Lk_commandText]
    mov edx, 4000
    call c2_jcl
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov edi, DGK_TEXT
    xor esi, esi
    xor edx, edx
    call agentdlg_row
    mov rdi, rax
    xor esi, esi
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    call agentdlg_text
9:  EPILOGUE

# pair(label cstr, key cstr) using r12 (the hook): a PAIR row of that member when it is a string
pair:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    mov rdi, r12
    call c2_jstr
    test rdx, rdx
    jz 9f
    mov rdi, r12
    mov rsi, [rsp]
    mov edx, 2000
    call c2_jcl
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    mov rcx, rbx
    xor r8d, r8d
    xor r9d, r9d
    call c2_crow
    mov rdi, rax
    mov esi, 1
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    call agentdlg_text
9:  EPILOGUE

# pair_c(label, value cstrs)
pair_c:
    mov rcx, rdi
    mov r8, rsi
    mov edi, DGK_PAIR
    xor esi, esi
    xor edx, edx
    xor r9d, r9d
    jmp c2_crow

# why_f(hook, listing) -> eax 1 with fsb = why it is read-only (xMn): the organization's, --settings', a
#   plugin's (named), a skill's or agent's, built in; else the lock's or the type's
why_f:
    PROLOGUE
    mov rbx, rdi
    mov r15, rsi
    mov rdi, rbx
    lea rsi, [rip + .Lk_source]
    call c2_jstr
    mov r12, rax
    mov r13, rdx
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lv_pluginHook]
    call str_eq_cstr
    test eax, eax
    jz 2f
    mov rdi, rbx
    lea rsi, [rip + .Lk_pluginName]
    call c2_jstr
    test rdx, rdx
    jz 2f
    call f_clr
    lea rdi, [rip + .Lh_by_plugin]
    call f_c
    mov rdi, rbx
    lea rsi, [rip + .Lk_pluginName]
    mov edx, 200
    call c2_jcl
    mov rdi, rax
    mov rsi, rdx
    call f_n
    lea rdi, [rip + .Lh_by_plugin2]
    call f_c
    mov eax, 1
    EPILOGUE
2:  lea r14, [rip + ro_why]
3:  mov rdx, [r14]
    test rdx, rdx
    jz 4f
    mov rdi, r12
    mov rsi, r13
    call str_eq_cstr
    test eax, eax
    jnz 5f
    add r14, 16
    jmp 3b
5:  call f_clr
    mov rdi, [r14 + 8]
    call f_c
    mov eax, 1
    EPILOGUE
4:  mov rdi, rbx                # editable but not here: the lock's (no catalog to use) or the type's
    lea rsi, [rip + .Lk_editable]
    call json_get
    test rax, rax
    jz 8f
    mov rdi, r15
    call can_edit
    mov r14d, eax
    call f_clr
    lea rdi, [rip + .Lh_type_not]
    test r14d, r14d
    jnz 6f
    lea rdi, [rip + .Lh_locked]
6:  call f_c
    mov eax, 1
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# ======================================================================================================
# the editor
# ======================================================================================================

# event_supports(listing, name cstr) -> eax 1 when the catalog says the event takes a matcher
event_supports:
    PROLOGUE
    mov r12, rsi
    lea rsi, [rip + .Lk_catalog]
    call json_get
    mov rbx, rax
    xor r13d, r13d
    test r12, r12
    jz 8f
1:  mov rdi, rbx
    call json_len
    cmp r13d, eax
    jae 8f
    mov rdi, rbx
    mov esi, r13d
    call json_at
    inc r13d
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rdi, r14
    lea rsi, [rip + .Lk_supportsMatcher]
    call c2_jbool
    EPILOGUE
8:  xor eax, eax
    EPILOGUE

# summary_of(listing, name cstr) -> rax ptr, rdx len of the event's summary in the catalog (cleaned)
summary_of:
    PROLOGUE
    mov r12, rsi
    lea rsi, [rip + .Lk_catalog]
    call json_get
    mov rbx, rax
    xor r13d, r13d
    test r12, r12
    jz 8f
1:  mov rdi, rbx
    call json_len
    cmp r13d, eax
    jae 8f
    mov rdi, rbx
    mov esi, r13d
    call json_at
    inc r13d
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    mov rdx, r12
    call str_eq_cstr
    test eax, eax
    jz 1b
    mov rdi, r14
    lea rsi, [rip + .Lk_summary]
    mov edx, 400
    call c2_jcl
    EPILOGUE
8:  xor eax, eax
    xor edx, edx
    EPILOGUE

# edit_rows(listing): Add hook or Edit hook (6.8)
edit_rows:
    PROLOGUE 32
    mov rbx, rdi
    mov edi, HA_BACK
    call agentdlg_back
    lea rdi, [rip + .Lh_add_title]
    cmp qword ptr [rip + h_edit], -1
    je 1f
    lea rdi, [rip + .Lh_edit_title]
1:  call c2_head
    call c2_msgs
    call ref_rows
    cmp qword ptr [rip + h_edit], -1    # Save to (adding only)
    jne 2f
    lea rdi, [rip + .Lh_save_to]
    call c2_head
    lea rdi, [rip + sources]
    mov esi, [rip + h_source]
    mov edx, HA_SOURCE
    mov ecx, 3
    call c2_options
2:  call f_clr                  # Event: NAME (its summary), Enter picks another
    lea rdi, [rip + .Lh_event_c]
    call f_c
    mov rdi, [rip + h_event]
    call f_c
    mov edi, DGK_ITEM
    xor esi, esi
    mov edx, HA_EVENTS
    call c2_frow
    mov [rsp], rax
    mov rdi, rbx
    mov rsi, [rip + h_event]
    call summary_of
    test rdx, rdx
    jz 3f
    mov rdi, [rsp]
    mov esi, 1
    mov rcx, rdx
    mov rdx, rax
    call agentdlg_text
3:  mov rdi, rbx                # Matcher, when the event takes one (or the hook had one)
    mov rsi, [rip + h_event]
    call event_supports
    test eax, eax
    jnz 31f
    mov rdi, [rip + h_omatch]
    test rdi, rdi
    jz 4f
    cmp byte ptr [rdi], 0
    je 4f
31: mov edi, DGK_FIELD
    xor esi, esi
    xor edx, edx
    lea rcx, [rip + .Lh_matcher_f]
    lea r8, [rip + .Lh_matcher_ph]
    xor r9d, r9d
    call c2_crow
    lea rcx, [rip + h_tf_matcher]
    mov [rax + DGR_val], rcx
4:  lea rdi, [rip + .Lh_type]   # Type
    call c2_head
    lea rdi, [rip + types]
    mov esi, [rip + h_type]
    mov edx, HA_TYPE
    mov ecx, TYPES_N
    call c2_options
    mov ecx, [rip + h_type]     # the type's fields, then the common ones
    mov eax, 1
    shl eax, cl
    mov [rsp + 8], eax
    xor r12d, r12d
5:  cmp r12d, FIELDS_N
    jae 7f
    mov edi, r12d
    call fd
    mov r13, rax
    mov eax, [r13 + FD_mask]
    test eax, [rsp + 8]
    jz 6f
    mov eax, [r13 + FD_kind]
    cmp eax, FK_CHECK
    je 51f
    cmp eax, FK_SHELL
    je 52f
    xor esi, esi                # a field
    mov ecx, [r13 + FD_kind]
    cmp ecx, FK_AREA
    je 501f
    cmp ecx, FK_JSONA
    je 501f
    cmp ecx, FK_JSONO
    je 501f
    cmp ecx, FK_LINES
    je 501f
    cmp ecx, FK_HDR
    jne 502f
    mov esi, DGF_MULTI | DGF_SECRETV
    jmp 502f
501:mov esi, DGF_MULTI
502:mov edi, DGK_FIELD
    xor edx, edx
    mov rcx, [r13 + FD_label]
    mov r8, [r13 + FD_ph]
    xor r9d, r9d
    call c2_crow
    mov [rsp + 16], rax
    mov rdi, r13
    call tf_of
    mov rcx, [rsp + 16]
    mov [rcx + DGR_val], rax
    jmp 6f
51: lea rax, [rip + h_checks]   # a check: a switch
    xor esi, esi
    cmp qword ptr [rax + r12*8], 0
    je 511f
    mov esi, DGF_ON
511:mov edi, DGK_TOGGLE
    mov edx, HA_CHECK
    mov rcx, [r13 + FD_label]
    xor r8d, r8d
    xor r9d, r9d
    call c2_crow
    mov [rax + DGR_arg], r12
    jmp 6f
52: mov rdi, [r13 + FD_label]   # the shell: its choices
    call c2_head
    lea rdi, [rip + shells]
    mov esi, [rip + h_shell]
    mov edx, HA_SHELL
    mov ecx, 3
    call c2_options
6:  inc r12d
    jmp 5b
7:  cmp qword ptr [rip + h_confirm], 0  # Remove asked: its question
    je 8f
    call f_clr
    lea rdi, [rip + .Lh_remove_q]
    call f_c
    mov rdi, [rip + h_osource]
    call badge_of
    mov rdi, rax
    call lower_f
    lea rdi, [rip + .Lh_remove_q2]
    call f_c
    xor edi, edi
    call c2_ftext
    lea rdi, [rip + .Lh_confirm]
    cmp qword ptr [rip + c2_busy], HA_CONFIRM
    jne 71f
    lea rdi, [rip + .Lh_removing]
71: mov esi, HA_CONFIRM
    mov edx, DBF_PRIMARY
    call agentdlg_button
    lea rdi, [rip + .Lcancel]
    mov esi, HA_CANCEL
    xor edx, edx
    call agentdlg_button
    EPILOGUE
8:  lea rdi, [rip + .Lh_add]    # Add hook / Save hook (Saving…), Remove when editing
    cmp qword ptr [rip + h_edit], -1
    je 81f
    lea rdi, [rip + .Lh_save]
81: cmp qword ptr [rip + c2_busy], HA_SAVE
    jne 82f
    lea rdi, [rip + .Lh_saving]
82: mov esi, HA_SAVE
    mov edx, DBF_PRIMARY
    call agentdlg_button
    cmp qword ptr [rip + h_edit], -1
    je 9f
    lea rdi, [rip + .Lh_remove]
    mov esi, HA_REMOVE
    xor edx, edx
    call agentdlg_button
9:  EPILOGUE

# form_fill(listing, hook or 0): the form as the extension fills it ($Mt): a hook's source, event, matcher,
#   type and fields (GMt), or for a new one Local, the catalog's first event, Command
form_fill:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    call form_clear
    mov qword ptr [rip + h_source], 0
    mov qword ptr [rip + h_type], 0
    mov qword ptr [rip + h_edit], -1
    test r12, r12
    jnz 2f
    mov rdi, rbx                # a new one: the catalog's first event, else PreToolUse
    lea rsi, [rip + .Lk_catalog]
    call json_get
    mov rdi, rax
    xor esi, esi
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    test rdx, rdx
    jnz 1f
    lea rax, [rip + .Lv_pretool]
    mov edx, 10
1:  mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + h_event], rax
    EPILOGUE
2:  mov rdi, r12                # the hook's: event, source, matcher, config (kept as JSON text)
    lea rsi, [rip + .Lk_event]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + h_event], rax
    mov rdi, r12
    lea rsi, [rip + .Lk_event]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + h_oevent], rax
    mov rdi, r12
    lea rsi, [rip + .Lk_source]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + h_osource], rax
    mov rdi, r12
    lea rsi, [rip + .Lk_editable]
    call json_get
    mov r13, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_matcher]
    call c2_jstr
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov [rip + h_omatch], rax
    lea rdi, [rip + h_tf_matcher]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call tf_set
    mov rdi, r13
    lea rsi, [rip + .Lk_config]
    call json_get
    mov r13, rax                # the config
    lea rdi, [rip + h_orig]
    mov rsi, rax
    call c2_keep
    mov rdi, r13
    lea rsi, [rip + .Lk_type]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    call type_of
    cmp rax, -1
    jne 3f
    xor eax, eax
3:  mov [rip + h_type], rax
    mov [rip + h_otype], rax
    xor r14d, r14d              # each field's value from the config (GMt)
4:  cmp r14d, FIELDS_N
    jae 9f
    mov edi, r14d
    call fd
    mov r15, rax
    inc r14d
    mov rdi, r13
    mov rsi, [r15 + FD_key]
    call json_get
    test rax, rax
    jz 4b
    mov rdi, rax
    lea esi, [r14 - 1]
    mov rdx, r15
    call fill_one
    jmp 4b
9:  EPILOGUE

# fill_one(value, field index, FD*): the field's text from the config's value
fill_one:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov eax, [r13 + FD_kind]
    cmp eax, FK_CHECK
    jne 1f
    mov rdi, rbx
    call json_type
    xor ecx, ecx
    cmp eax, JT_TRUE
    sete cl
    lea rax, [rip + h_checks]
    mov [rax + r12*8], rcx
    EPILOGUE
1:  cmp eax, FK_SHELL
    jne 2f
    mov rdi, rbx
    call json_str
    xor r14d, r14d
    lea rcx, [rip + shell_ids]
11: cmp r14d, 3
    jae 9f
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    lea rcx, [rip + shell_ids]
    mov rdx, [rcx + r14*8]
    call str_eq_cstr
    pop rdx
    pop rcx
    test eax, eax
    jnz 12f
    mov rax, rcx
    inc r14d
    jmp 11b
12: mov [rip + h_shell], r14
    EPILOGUE
2:  lea rdi, [rip + tsb]
    call sb_clear
    mov eax, [r13 + FD_kind]
    cmp eax, FK_NUM
    jne 3f
    mov rdi, rbx
    call json_num_text
    mov rsi, rax
    lea rdi, [rip + tsb]
    call sb_push
    jmp 8f
3:  cmp eax, FK_LINES
    jne 4f
    xor r14d, r14d              # its strings, a line each
31: mov rdi, rbx
    call json_len
    cmp r14d, eax
    jae 8f
    mov rdi, rbx
    mov esi, r14d
    call json_at
    mov rdi, rax
    call json_str
    test rax, rax
    jz 32f
    cmp r14d, 0
    je 33f
    push rax
    push rdx
    lea rdi, [rip + tsb]
    mov esi, 10
    call sb_push_byte
    pop rdx
    pop rax
33: lea rdi, [rip + tsb]
    mov rsi, rax
    call sb_push
32: inc r14d
    jmp 31b
4:  cmp eax, FK_HDR
    jne 5f
    xor r14d, r14d              # its names, "Name: " a line (the values are not shown)
41: mov rdi, rbx
    call json_npairs
    cmp r14d, eax
    jae 42f
    mov rdi, rbx
    mov esi, r14d
    call json_pair
    mov rdi, rax
    call json_str
    test r14d, r14d
    jz 43f
    push rax
    push rdx
    lea rdi, [rip + tsb]
    mov esi, 10
    call sb_push_byte
    pop rdx
    pop rax
43: lea rdi, [rip + tsb]
    mov rsi, rax
    call sb_push
    lea rdi, [rip + tsb]
    lea rsi, [rip + .Lcolon_sp]
    call sb_push_cstr
    inc r14d
    jmp 41b
42: lea rdi, [rip + h_hdr0]
    call sb_clear
    lea rdi, [rip + h_hdr0]
    mov rsi, [rip + tsb + SB_ptr]
    mov rdx, [rip + tsb + SB_len]
    call sb_push
    jmp 8f
5:  cmp eax, FK_JSONA
    je 51f
    cmp eax, FK_JSONO
    jne 6f
    mov rdi, rbx                # an object: two blanks a level (JSON.stringify(v, null, 2))
    call json_type
    cmp eax, JT_OBJ
    jne 8f
    lea rdi, [rip + tsb]
    mov rsi, rbx
    call json_pretty
    jmp 8f
51: mov rdi, rbx                # an array: on one line
    call json_type
    cmp eax, JT_ARR
    jne 8f
    lea rdi, [rip + tsb]
    mov rsi, rbx
    call c2_keep
    jmp 8f
6:  mov rdi, rbx                # a string
    call json_str
    mov rsi, rax
    lea rdi, [rip + tsb]
    call sb_push
8:  mov rdi, r13
    call tf_of
    mov rdi, rax
    test rdi, rdi
    jz 9f
    mov rsi, [rip + tsb + SB_ptr]
    mov rdx, [rip + tsb + SB_len]
    call tf_set
9:  EPILOGUE

# hooks_act(act, arg, DGR*)
hooks_act:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    cmp r12d, HA_LEARN
    jne 1f
    lea rdi, [rip + .Lwho]
    lea rsi, [rip + .Lh_url]
    call links_ask_open
    jmp 9f
1:  cmp r12d, HA_OPENFILE
    jne 11f
    mov rdi, [rip + h_refpath]  # the file in an editor tab; the dialog stays, without the refusal
    test rdi, rdi
    jz 9f
    call app_open_file
    call c2_notes_clear
    call ref_clear
    jmp 8f
11: cmp r12d, HA_COPYERR
    jne 12f
    mov rdi, [rip + h_referr]
    test rdi, rdi
    jz 9f
    call strlen
    mov rsi, rax
    mov rdi, [rip + h_referr]
    xor edx, edx
    call ed_clip_set
    lea rdi, [rip + .Lh_copied]
    call app_toast
    jmp 9f
12: cmp qword ptr [rip + c2_busy], 0
    jne 9f
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    test rax, rax
    jz 9f
    cmp r12d, HA_HOOK
    je .Lha_hook
    cmp r12d, HA_BACK
    je .Lha_back
    cmp r12d, HA_ADD
    je .Lha_add
    cmp r12d, HA_SOURCE
    je .Lha_source
    cmp r12d, HA_EVENTS
    je .Lha_events
    cmp r12d, HA_PICKEV
    je .Lha_pickev
    cmp r12d, HA_TYPE
    je .Lha_type
    cmp r12d, HA_SHELL
    je .Lha_shell
    cmp r12d, HA_CHECK
    je .Lha_check
    cmp r12d, HA_REMOVE
    je .Lha_remove
    cmp r12d, HA_CANCEL
    je .Lha_cancel
    cmp r12d, HA_CONFIRM
    je .Lha_confirm
    cmp r12d, HA_SAVE
    je .Lha_save
    jmp 9f
.Lha_hook:
    mov [rip + c2_arg], r13
    call c2_notes_clear
    mov rdi, rbx
    lea rsi, [rip + .Lk_hooks]
    call json_get
    mov rdi, rax
    mov rsi, r13
    call json_at
    test rax, rax
    jz 9f
    mov r14, rax
    mov rdi, rbx
    mov rsi, r14
    call editable
    test eax, eax
    jnz 2f
    mov qword ptr [rip + c2_page], HP_DETAIL
    jmp 7f
2:  mov rdi, rbx
    mov rsi, r14
    call form_fill
    mov [rip + h_edit], r13
    mov qword ptr [rip + c2_page], HP_EDIT
    jmp 7f
.Lha_back:
    cmp qword ptr [rip + c2_page], HP_EVENT
    jne 3f
    xor edi, edi                # the picker: back to the form (no filter there)
    call agentdlg_x_filter
    mov qword ptr [rip + c2_page], HP_EDIT
    jmp 8f
3:  call c2_notes_clear
    mov qword ptr [rip + c2_page], HP_LIST
    call form_clear
    jmp 8f
.Lha_add:
    call c2_notes_clear
    mov rdi, rbx
    xor esi, esi
    call form_fill
    mov qword ptr [rip + c2_page], HP_EDIT
    jmp 7f
.Lha_source:
    mov [rip + h_source], r13
    jmp 8f
.Lha_events:
    mov qword ptr [rip + c2_page], HP_EVENT
    jmp 7f
.Lha_pickev:
    mov rdi, rbx
    lea rsi, [rip + .Lk_catalog]
    call json_get
    mov rdi, rax
    mov rsi, r13
    call json_at
    mov rdi, rax
    lea rsi, [rip + .Lk_name]
    call c2_jstr
    test rdx, rdx
    jz 9f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    mov rdi, [rip + h_event]
    mov [rip + h_event], rax
    call mem_free
    xor edi, edi
    call agentdlg_x_filter
    mov qword ptr [rip + c2_page], HP_EDIT
    jmp 8f
.Lha_type:
    mov [rip + h_type], r13
    jmp 8f
.Lha_shell:
    mov [rip + h_shell], r13
    jmp 8f
.Lha_check:
    cmp r13, FIELDS_N
    jae 9f
    lea rax, [rip + h_checks]
    xor qword ptr [rax + r13*8], 1
    jmp 8f
.Lha_remove:
    mov qword ptr [rip + h_confirm], 1
    call hooks_build
    mov edi, 1000               # the focus on Cancel
    call agentdlg_focus
    jmp 9f
.Lha_cancel:
    mov qword ptr [rip + h_confirm], 0
    jmp 8f
.Lha_confirm:
    call remove_write
    jmp 8f
.Lha_save:
    call save_write
    jmp 8f
7:  xor edi, edi
    call agentdlg_focus
8:  call hooks_build
9:  EPILOGUE

# remove_write(): {"op":"remove","source":S,"event":E,"target":{"event":E,"matcher":M,"hook":CONFIG}}
remove_write:
    PROLOGUE
    lea rdi, [rip + c2_in]
    call jw_begin
    lea rdi, [rip + c2_in]
    call jw_obj
    lea rsi, [rip + .Lk_op]
    lea rdx, [rip + .Lv_remove]
    call kv
    lea rsi, [rip + .Lk_source]
    mov rdx, [rip + h_osource]
    call kv
    lea rsi, [rip + .Lk_event]
    mov rdx, [rip + h_oevent]
    call kv
    call target
    lea rdi, [rip + c2_in]
    call jw_end_obj
    mov edi, HW_REMOVE
    mov esi, HA_CONFIRM
    call run_edit
    EPILOGUE

# kv(-, key cstr, value cstr or 0): "key":"value" into c2_in
kv:
    PROLOGUE
    mov rbx, rdx
    lea rdi, [rip + c2_in]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, rbx
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lempty]
1:  call jw_cstr
    EPILOGUE

# target(): "target":{"event":E,"matcher":M,"hook":CONFIG} of the hook edited into c2_in
target:
    PROLOGUE
    lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_target]
    call jw_key
    lea rdi, [rip + c2_in]
    call jw_obj
    lea rsi, [rip + .Lk_event]
    mov rdx, [rip + h_oevent]
    call kv
    lea rsi, [rip + .Lk_matcher]
    mov rdx, [rip + h_omatch]
    call kv
    lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_hook]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, [rip + h_orig + SB_ptr]
    mov rdx, [rip + h_orig + SB_len]
    call jw_rawn
    lea rdi, [rip + c2_in]
    call jw_end_obj
    EPILOGUE

# run_edit(what, busy act): `claude edit-hook --json` with c2_in
run_edit:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call c2_notes_clear
    call ref_clear
    call c2_args
    lea rdi, [rip + .La_edit_hook]
    call c2_arg_c
    lea rdi, [rip + .La_json]
    call c2_arg_c
    lea rdi, [rip + c2_doc3]    # the hooks before: the re-read waits for a change from them
    call sb_clear
    lea rdi, [rip + c2_doc3]
    mov rsi, [rip + c2_doc + SB_ptr]
    mov rdx, [rip + c2_doc + SB_len]
    call sb_push
    mov rdi, rbx
    call c2_run
    test eax, eax
    jz 8f
    mov [rip + c2_busy], r12
    EPILOGUE
8:  lea rdi, [rip + .Lno_run]
    call c2_err_cset
    EPILOGUE

# save_write(): the form checked and written as the extension writes it (jMt, cMn): {"op":"add","source":S,
#   "event":E,"matcher":M,"hook":{...}} or {"op":"replace","source":S,"event":E,"matcher":M,"hook":{...},
#   "target":{...}}; a field that fails its check: its error, nothing written
save_write:
    PROLOGUE 48
    call c2_notes_clear
    lea rdi, [rip + c2_doc]
    call c2_parse
    mov rbx, rax
    lea rdi, [rip + c2_in]
    call jw_begin
    lea rdi, [rip + c2_in]
    call jw_obj
    lea rsi, [rip + .Lk_op]
    lea rdx, [rip + .Lv_add]
    cmp qword ptr [rip + h_edit], -1
    je 1f
    lea rdx, [rip + .Lv_replace]
1:  call kv
    lea rsi, [rip + .Lk_source]
    mov rdx, [rip + h_osource]
    cmp qword ptr [rip + h_edit], -1
    jne 2f
    mov rax, [rip + h_source]
    lea rcx, [rip + source_ids]
    mov rdx, [rcx + rax*8]
2:  call kv
    lea rsi, [rip + .Lk_event]
    mov rdx, [rip + h_event]
    call kv
    lea rdi, [rip + c2_in]      # the matcher: the field's when the event takes one or it is the hook's
    lea rsi, [rip + .Lk_matcher]   #   own event, else empty
    call jw_key
    mov rdi, rbx
    mov rsi, [rip + h_event]
    call event_supports
    test eax, eax
    jnz 3f
    mov rdi, [rip + h_oevent]
    test rdi, rdi
    jz 31f
    mov rsi, [rip + h_event]
    call strcmp_eq
    test eax, eax
    jnz 3f
31: lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lempty]
    call jw_cstr
    jmp 4f
3:  lea rdi, [rip + h_tf_matcher]
    call tf_text
    mov rsi, rax
    lea rdi, [rip + c2_in]
    call jw_str
4:  lea rdi, [rip + c2_in]
    lea rsi, [rip + .Lk_hook]
    call jw_key
    lea rdi, [rip + c2_in]
    call jw_obj
    mov rax, [rip + h_type]     # editing the same type: the original's other members first
    cmp qword ptr [rip + h_edit], -1
    je 5f
    cmp rax, [rip + h_otype]
    jne 5f
    call copy_unknown
5:  lea rsi, [rip + .Lk_type]
    mov rax, [rip + h_type]
    lea rcx, [rip + type_ids]
    mov rdx, [rcx + rax*8]
    call kv
    mov ecx, [rip + h_type]
    mov eax, 1
    shl eax, cl
    mov [rsp], eax
    xor r12d, r12d
6:  cmp r12d, FIELDS_N
    jae 7f
    mov edi, r12d
    call fd
    mov r13, rax
    mov eax, [r13 + FD_mask]
    test eax, [rsp]
    jz 61f
    mov edi, r12d
    mov rsi, r13
    call field_write
    test eax, eax
    jz .Lsw_fail
61: inc r12d
    jmp 6b
7:  lea rdi, [rip + c2_in]
    call jw_end_obj
    cmp qword ptr [rip + h_edit], -1
    je 71f
    call target
71: lea rdi, [rip + c2_in]
    call jw_end_obj
    mov edi, HW_SAVE
    mov esi, HA_SAVE
    call run_edit
    EPILOGUE
.Lsw_fail:
    lea rdi, [rip + c2_in]
    call sb_clear
    call c2_err_fsb
    EPILOGUE

# copy_unknown(): the members of the hook edited that no field of the form writes, as they were
copy_unknown:
    PROLOGUE
    lea rdi, [rip + h_orig]
    call c2_parse
    mov rbx, rax
    xor r12d, r12d
1:  mov rdi, rbx
    call json_npairs
    cmp r12d, eax
    jae 9f
    mov rdi, rbx
    mov esi, r12d
    call json_pair
    inc r12d
    mov r13, rax
    mov r14, rdx
    mov rdi, r13
    call json_str
    mov rdi, rax
    mov rsi, rdx
    call known_key
    test eax, eax
    jnz 1b
    mov rdi, r13
    call json_str
    mov rsi, rax
    lea rdi, [rip + c2_in]
    call jw_keyn
    lea rdi, [rip + c2_in]
    mov rsi, r14
    call jw_jv
    jmp 1b
9:  EPILOGUE

# known_key(ptr, len) -> eax 1 for "type" or a field's key (lMn)
known_key:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdx, [rip + .Lk_type]
    call str_eq_cstr
    test eax, eax
    jnz 9f
    xor r13d, r13d
1:  cmp r13d, FIELDS_N
    jae 8f
    mov edi, r13d
    call fd
    inc r13d
    mov rdx, [rax + FD_key]
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jz 1b
    EPILOGUE
8:  xor eax, eax
9:  EPILOGUE

# field_write(field index, FD*) -> eax 1 with the field written into the hook (or left out: empty, not
#   required), 0 with fsb its error (cMn's words)
field_write:
    PROLOGUE 48
    mov r12d, edi
    mov r13, rsi
    mov eax, [r13 + FD_kind]
    cmp eax, FK_CHECK
    jne 1f
    lea rax, [rip + h_checks]   # a check: true, or left out
    cmp qword ptr [rax + r12*8], 0
    je .Lfw_ok
    lea rdi, [rip + c2_in]
    mov rsi, [r13 + FD_key]
    call jw_key
    lea rdi, [rip + c2_in]
    mov esi, 1
    call jw_bool
    jmp .Lfw_ok
1:  cmp eax, FK_SHELL
    jne 2f
    mov rax, [rip + h_shell]    # the shell: left out for the default
    test rax, rax
    jz .Lfw_ok
    lea rcx, [rip + shell_ids]
    mov rdx, [rcx + rax*8]
    mov rsi, [r13 + FD_key]
    call kv
    jmp .Lfw_ok
2:  mov rdi, r13
    call tf_of
    mov rdi, rax
    call tf_text
    mov [rsp], rax
    mov [rsp + 8], rdx
    cmp dword ptr [r13 + FD_kind], FK_HDR
    jne 3f
    cmp qword ptr [rip + h_edit], -1    # headers, editing the same type: as filled, kept; emptied, {}
    je 3f
    mov rax, [rip + h_type]
    cmp rax, [rip + h_otype]
    jne 3f
    mov rcx, [rsp + 8]
    cmp rcx, [rip + h_hdr0 + SB_len]
    jne 21f
    mov rdi, [rsp]
    mov rsi, [rip + h_hdr0 + SB_ptr]
    mov rdx, rcx
    call bytes_eq
    test eax, eax
    jnz .Lfw_ok
21: mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call c2_trim
    test rdx, rdx
    jnz 3f
    lea rdi, [rip + c2_in]
    mov rsi, [r13 + FD_key]
    call jw_key
    lea rdi, [rip + c2_in]
    call jw_obj
    lea rdi, [rip + c2_in]
    call jw_end_obj
    jmp .Lfw_ok
3:  mov rdi, [rsp]              # empty: required, or left out
    mov rsi, [rsp + 8]
    call c2_trim
    test rdx, rdx
    jnz 4f
    cmp dword ptr [r13 + FD_req], 0
    je .Lfw_ok
    call f_clr
    mov rdi, [r13 + FD_label]
    call f_c
    lea rdi, [rip + .Lh_required]
    call f_c
    jmp .Lfw_fail
4:  mov eax, [r13 + FD_kind]
    cmp eax, FK_NUM
    je .Lfw_num
    cmp eax, FK_LINES
    je .Lfw_lines
    cmp eax, FK_HDR
    je .Lfw_hdr
    cmp eax, FK_JSONA
    je .Lfw_json
    cmp eax, FK_JSONO
    je .Lfw_json
    lea rdi, [rip + c2_in]      # text: as typed
    mov rsi, [r13 + FD_key]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call jw_str
    jmp .Lfw_ok
.Lfw_num:
    mov rdi, [rsp]              # digits, a fraction, above 0
    mov rsi, [rsp + 8]
    call c2_trim
    mov r14, rax
    mov r15, rdx
    xor ecx, ecx
    xor r8d, r8d                # a dot seen
    xor r9d, r9d                # a digit above 0 seen
1:  cmp rcx, r15
    jae 3f
    movzx eax, byte ptr [r14 + rcx]
    inc rcx
    cmp eax, '.'
    jne 2f
    test r8d, r8d
    jnz .Lfw_numbad
    cmp rcx, 1
    je .Lfw_numbad
    cmp rcx, r15
    je .Lfw_numbad
    mov r8d, 1
    jmp 1b
2:  sub eax, '0'
    cmp eax, 9
    ja .Lfw_numbad
    test eax, eax
    jz 1b
    mov r9d, 1
    jmp 1b
3:  test r9d, r9d
    jz .Lfw_numbad
    lea rdi, [rip + c2_in]
    mov rsi, [r13 + FD_key]
    call jw_key
    xor ecx, ecx                # leading zeros of the whole part off ("05" is 5, "0.5" stays)
31: lea rax, [rcx + 1]
    cmp rax, r15
    jae 32f
    cmp byte ptr [r14 + rcx], '0'
    jne 32f
    cmp byte ptr [r14 + rcx + 1], '.'
    je 32f
    inc rcx
    jmp 31b
32: lea rsi, [r14 + rcx]
    mov rdx, r15
    sub rdx, rcx
    lea rdi, [rip + c2_in]
    call jw_rawn
    jmp .Lfw_ok
.Lfw_numbad:
    call f_clr
    mov rdi, [r13 + FD_label]
    call label_f
    lea rdi, [rip + .Lh_number]
    call f_c
    jmp .Lfw_fail
.Lfw_lines:
    lea rdi, [rip + c2_in]      # a string a line that is not blank
    mov rsi, [r13 + FD_key]
    call jw_key
    lea rdi, [rip + c2_in]
    call jw_arr
    xor r14d, r14d
1:  mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov edx, r14d
    call c2_line
    test r8d, r8d
    jz 2f
    inc r14d
    mov rdi, rax
    mov rsi, rdx
    call c2_trim
    test rdx, rdx
    jz 1b
    mov rsi, rax
    lea rdi, [rip + c2_in]
    call jw_str
    jmp 1b
2:  lea rdi, [rip + c2_in]
    call jw_end_arr
    jmp .Lfw_ok
.Lfw_hdr:
    xor r14d, r14d              # first a check of every line (Ile; names that are not allowed)
1:  mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov edx, r14d
    call c2_line
    test r8d, r8d
    jz 4f
    inc r14d
    mov rdi, rax
    mov rsi, rdx
    call c2_trim
    test rdx, rdx
    jz 1b
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    xor ecx, ecx
2:  cmp rcx, rdx
    jae 3f
    cmp byte ptr [rax + rcx], ':'
    je 21f
    inc rcx
    jmp 2b
21: test rcx, rcx
    jz 3f
    mov rdi, rax
    mov rsi, rcx
    call c2_trim
    mov rdi, rax
    mov rsi, rdx
    call proto_name
    test eax, eax
    jz 1b
    call f_clr
    lea rdi, [rip + .Lh_hdr_name]
    call f_c
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    mov edx, 100
    call f_cl
    lea rdi, [rip + .Lh_not_allowed]
    call f_c
    jmp .Lfw_fail
3:  call f_clr
    lea rdi, [rip + .Lh_hdr_bad]
    call f_c
    mov edi, r14d
    call f_u
    lea rdi, [rip + .Lh_line_end]
    call f_c
    jmp .Lfw_fail
4:  lea rdi, [rip + c2_in]      # then the object
    mov rsi, [r13 + FD_key]
    call jw_key
    lea rdi, [rip + c2_in]
    call jw_obj
    xor r14d, r14d
5:  mov rdi, [rsp]
    mov rsi, [rsp + 8]
    mov edx, r14d
    call c2_line
    test r8d, r8d
    jz 7f
    inc r14d
    mov rdi, rax
    mov rsi, rdx
    call c2_trim
    test rdx, rdx
    jz 5b
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    xor ecx, ecx
6:  cmp byte ptr [rax + rcx], ':'
    je 61f
    inc rcx
    jmp 6b
61: mov [rsp + 32], ecx
    mov rdi, rax
    mov rsi, rcx
    call c2_trim
    mov rsi, rax
    lea rdi, [rip + c2_in]
    call jw_keyn
    mov rax, [rsp + 16]
    mov ecx, [rsp + 32]
    lea rdi, [rax + rcx + 1]
    mov rsi, [rsp + 24]
    sub rsi, rcx
    dec rsi
    call c2_trim
    mov rsi, rax
    lea rdi, [rip + c2_in]
    call jw_str
    jmp 5b
7:  lea rdi, [rip + c2_in]
    call jw_end_obj
    jmp .Lfw_ok
.Lfw_json:
    mov rdi, [rsp]              # JSON: an array of strings, or an object
    mov rsi, [rsp + 8]
    call json_parse
    test rax, rax
    jz .Lfw_jsonbad
    mov r14, rax
    mov rdi, rax
    call json_type
    cmp dword ptr [r13 + FD_kind], FK_JSONO
    jne 1f
    cmp eax, JT_OBJ
    jne .Lfw_jsonbad
    jmp 3f
1:  cmp eax, JT_ARR
    jne .Lfw_jsonbad
    xor r15d, r15d
2:  mov rdi, r14
    call json_len
    cmp r15d, eax
    jae 3f
    mov rdi, r14
    mov esi, r15d
    call json_at
    inc r15d
    mov rdi, rax
    call json_type
    cmp eax, JT_STR
    jne .Lfw_jsonbad
    jmp 2b
3:  lea rdi, [rip + c2_in]
    mov rsi, [r13 + FD_key]
    call jw_key
    lea rdi, [rip + c2_in]
    mov rsi, r14
    call jw_jv
    test eax, eax
    jz .Lfw_jsonbad
    jmp .Lfw_ok
.Lfw_jsonbad:
    call f_clr
    mov rdi, [r13 + FD_label]
    call label_f
    lea rdi, [rip + .Lh_must_json]
    call f_c
    lea rdi, [rip + .Lv_array]
    cmp dword ptr [r13 + FD_kind], FK_JSONA
    je 1f
    lea rdi, [rip + .Lv_object]
1:  call f_c
    lea rdi, [rip + .Ldot]
    call f_c
.Lfw_fail:
    xor eax, eax
    EPILOGUE
.Lfw_ok:
    mov eax, 1
    EPILOGUE

# label_f(cstr): fsb += the label without its last " (...)" (the extension's replace(/ \(.*\)$/, ""))
label_f:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
    xor ecx, ecx                # the first " (" whose text runs to a ")" at the end
1:  lea rax, [rcx + 1]
    cmp rax, r12
    jae 3f
    cmp byte ptr [rbx + rcx], ' '
    jne 2f
    cmp byte ptr [rbx + rcx + 1], '('
    jne 2f
    cmp byte ptr [rbx + r12 - 1], ')'
    jne 3f
    mov r12, rcx
    jmp 3f
2:  inc rcx
    jmp 1b
3:  mov rdi, rbx
    mov rsi, r12
    call f_n
    EPILOGUE

# proto_name(ptr, len) -> eax 1 for __proto__, constructor or prototype
proto_name:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea r13, [rip + protos]
1:  mov rdx, [r13]
    test rdx, rdx
    jz 8f
    mov rdi, rbx
    mov rsi, r12
    call str_eq_cstr
    test eax, eax
    jnz 9f
    add r13, 8
    jmp 1b
8:  xor eax, eax
9:  EPILOGUE

# hooks_ran(what, code): the write ended: {"ok":true} reads the listing again until it changes; a refusal
#   or an error says why (TMn, ePt)
hooks_ran:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rip + c2_out]
    call c2_last_json
    mov r13, rax
    test r12, r12
    jnz 2f
    test rax, rax
    jz 1f
    mov rdi, rax
    lea rsi, [rip + .Lk_ok]
    call c2_jbool
    test eax, eax
    jz 2f
1:  mov qword ptr [rip + h_confirm], 0  # written: read again until it shows
    mov qword ptr [rip + h_tries], TRIES
    mov qword ptr [rip + c2_busy], HA_SAVE
    mov edi, HR_LIST
    call c2_ask
    call hooks_build
    EPILOGUE
2:  test r13, r13               # refused: {"refusal":{"code","file"}} in the extension's words (Tir, TMn)
    jz 4f
    mov rdi, r13
    lea rsi, [rip + .Lk_refusal]
    call json_get
    mov r14, rax
    mov rdi, rax
    lea rsi, [rip + .Lk_code]
    call c2_jstr
    test rdx, rdx
    jz 3f
    mov rdi, rax
    mov rsi, rdx
    call refusal_f
    test eax, eax
    jz 3f
    mov rdi, r14                # its file, for Open settings file; its error, for Copy error
    lea rsi, [rip + .Lk_file]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + h_refpath]
    call ref_keep
    mov rdi, r13
    lea rsi, [rip + .Lk_error]
    call c2_jstr
    mov rdi, rax
    mov rsi, rdx
    lea rax, [rip + h_referr]
    call ref_keep
    jmp 5f
3:  mov rdi, r13                # its error, its settings named in words (ePt)
    lea rsi, [rip + .Lk_error]
    call c2_jstr
    test rdx, rdx
    jz 4f
    mov rdi, rax
    mov rsi, rdx
    call ept_f
    jmp 5f
4:  mov rdi, r12
    lea rsi, [rip + .Lh_thing]
    call c2_errthing
5:  call c2_err_fsb
    mov qword ptr [rip + h_confirm], 0
    call hooks_build
    EPILOGUE

# refusal_f(code ptr, len) -> eax 1 with fsb = the refusal's words (TMn), 0 for another code
refusal_f:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    lea rdx, [rip + .Lv_legacy]
    call str_eq_cstr
    test eax, eax
    jz 1f
    call f_clr
    lea rdi, [rip + .Lh_ref_legacy]
    call f_c
    jmp 8f
1:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lv_unloadable]
    call str_eq_cstr
    test eax, eax
    jz 2f
    call f_clr                  # "The local settings file could not be loaded, so ..."
    lea rdi, [rip + .Lh_ref_the_cap]
    call f_c
    call file_f
    lea rdi, [rip + .Lh_ref_unloadable]
    call f_c
    jmp 8f
2:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lv_twins]
    call str_eq_cstr
    test eax, eax
    jz 3f
    call f_clr
    lea rdi, [rip + .Lh_ref_twins]
    call f_c
    lea rdi, [rip + .Lh_ref_the]
    call f_c
    call file_f
    lea rdi, [rip + .Lh_ref_twins2]
    call f_c
    jmp 8f
3:  mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lv_notalist]
    call str_eq_cstr
    test eax, eax
    jz 9f
    call f_clr
    lea rdi, [rip + .Lh_ref_the_cap]
    call f_c
    mov rdi, [rip + h_event]
    call f_c
    lea rdi, [rip + .Lh_ref_entry]
    call f_c
    lea rdi, [rip + .Lh_ref_the]
    call f_c
    call file_f
    lea rdi, [rip + .Lh_ref_notalist]
    call f_c
8:  mov eax, 1
9:  EPILOGUE

# file_f(): fsb += "local settings file" for the write's source
file_f:
    PROLOGUE
    mov rdi, [rip + h_osource]
    cmp qword ptr [rip + h_edit], -1
    jne 1f
    mov rax, [rip + h_source]
    lea rcx, [rip + source_ids]
    mov rdi, [rcx + rax*8]
1:  call badge_of
    mov rdi, rax
    call lower_f
    lea rdi, [rip + .Lh_ref_file]
    call f_c
    EPILOGUE

# ept_f(ptr, len): fsb = an edit-hook error as the extension words it (ePt): without its "edit_hook: ", each
#   settings id named ("user settings"), its first letter a capital
ept_f:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp r12, 11
    jb 1f
    mov rdi, rbx
    mov esi, 11
    lea rdx, [rip + .Lv_edit_hook_c]
    call str_eq_cstr
    test eax, eax
    jnz 11f
    mov rdi, rbx
    mov esi, 10
    lea rdx, [rip + .Lv_edit_hook_s]
    call str_eq_cstr
    test eax, eax
    jz 1f
    add rbx, 10
    sub r12, 10
    jmp 1f
11: add rbx, 11
    sub r12, 11
1:  mov rdi, rbx
    mov rsi, r12
    mov edx, 2000
    call c2_clean
    lea rdi, [rip + tsb]
    call sb_clear
    lea rdi, [rip + tsb]
    mov rsi, rax
    call sb_push
    call f_clr
    xor r13d, r13d
2:  cmp r13, [rip + tsb + SB_len]
    jae 8f
    lea r14, [rip + badges]     # a settings id here: its words
3:  mov r15, [r14]
    test r15, r15
    jz 5f
    mov rdi, r15
    call strlen
    mov rcx, [rip + tsb + SB_len]
    sub rcx, r13
    cmp rcx, rax
    jb 4f
    push rax
    push rax
    mov rdi, [rip + tsb + SB_ptr]
    add rdi, r13
    mov rsi, rax
    mov rdx, r15
    call str_eq_cstr
    pop rcx
    pop rcx
    test eax, eax
    jz 4f
    add r13, rcx
    mov rdi, [r14 + 8]
    call lower_f
    lea rdi, [rip + .Lh_settings_word]
    call f_c
    jmp 2b
4:  add r14, 16
    jmp 3b
5:  mov rax, [rip + tsb + SB_ptr]
    movzx esi, byte ptr [rax + r13]
    inc r13
    lea rdi, [rip + fsb]
    call sb_push_byte
    jmp 2b
8:  mov rax, [rip + fsb + SB_ptr]   # the first letter a capital
    test rax, rax
    jz 9f
    cmp qword ptr [rip + fsb + SB_len], 0
    je 9f
    movzx ecx, byte ptr [rax]
    lea edx, [rcx - 'a']
    cmp edx, 25
    ja 9f
    and ecx, 0xdf
    mov [rax], cl
9:  EPILOGUE

.section .rodata
.p2align 3
fields:                         # key, label, placeholder, its TF's index + 1 (0: none; a TF_SIZE in a data
                                #   expression is the last STRUCT's size on macOS), kind, types, required
    .quad .Lf_command, .Lf_command_l, 0, 1
    .long FK_AREA, 1, 1, 0
    .quad .Lf_args, .Lf_args_l, 0, 2
    .long FK_JSONA, 1, 0, 0
    .quad .Lf_shell, .Lf_shell_l, 0, 0
    .long FK_SHELL, 1, 0, 0
    .quad .Lf_async, .Lf_async_l, 0, 0
    .long FK_CHECK, 1, 0, 0
    .quad .Lf_prompt, .Lf_prompt_l, 0, 5
    .long FK_AREA, 6, 1, 0
    .quad .Lf_model, .Lf_model_l, 0, 6
    .long FK_TEXT, 6, 0, 0
    .quad .Lf_continue, .Lf_continue_l, 0, 0
    .long FK_CHECK, 2, 0, 0
    .quad .Lf_url, .Lf_url_l, .Lf_url_ph, 8
    .long FK_TEXT, 8, 1, 0
    .quad .Lf_headers, .Lf_headers_l, 0, 9
    .long FK_HDR, 8, 0, 0
    .quad .Lf_envvars, .Lf_envvars_l, 0, 10
    .long FK_LINES, 8, 0, 0
    .quad .Lf_server, .Lf_server_l, 0, 11
    .long FK_TEXT, 16, 1, 0
    .quad .Lf_tool, .Lf_tool_l, 0, 12
    .long FK_TEXT, 16, 1, 0
    .quad .Lf_input, .Lf_input_l, 0, 13
    .long FK_JSONO, 16, 0, 0
    .quad .Lf_if, .Lf_if_l, .Lf_if_ph, 14
    .long FK_TEXT, 31, 0, 0
    .quad .Lf_timeout, .Lf_timeout_l, 0, 15
    .long FK_NUM, 31, 0, 0
    .quad .Lf_status, .Lf_status_l, 0, 16
    .long FK_TEXT, 31, 0, 0
type_ids: .quad .Lv_command, .Lv_prompt, .Lv_agent, .Lv_http, .Lv_mcp_tool
types: .quad .Lt_command, .Lt_command_d, .Lt_prompt, .Lt_prompt_d, .Lt_agent, .Lt_agent_d, .Lt_http
    .quad .Lt_http_d, .Lt_mcp, .Lt_mcp_d
shell_ids: .quad .Lempty, .Lv_bash, .Lv_powershell
shells: .quad .Lsh_default, .Lsh_default_d, .Lv_bash, 0, .Lsh_pwsh, 0
source_ids: .quad .Lv_localSettings, .Lv_userSettings, .Lv_projectSettings
sources: .quad .Lw_local, .Lso_local_d, .Lw_user, .Lso_user_d, .Lw_project, .Lso_project_d
badges:
    .quad .Lv_userSettings, .Lw_user, .Lv_projectSettings, .Lw_project, .Lv_localSettings, .Lw_local
    .quad .Lv_flagSettings, .Lw_flag, .Lv_policySettings, .Lw_managed, .Lv_sessionHook, .Lw_session
    .quad .Lv_pluginHook, .Lw_plugin, .Lv_builtinHook, .Lw_builtin, 0, 0
ro_why:
    .quad .Lv_policySettings, .Lr_policy, .Lv_flagSettings, .Lr_flag, .Lv_pluginHook, .Lr_plugin
    .quad .Lv_sessionHook, .Lr_session, .Lv_builtinHook, .Lr_builtin, 0, 0
locks: .quad .Lk_disabledByPolicy, .Lk_managedOnly, .Lk_pluginOnly, .Lk_policyUnreadable, 0
protos: .quad .Lv_proto, .Lv_constructor, .Lv_prototype, 0
.Lempty: .asciz ""
.Lspace: .asciz " "
.Ldot: .asciz "."
.Lcomma: .asciz ", "
.Lcolon_sp: .asciz ": "
.Ls: .asciz "s"
.Lcancel: .asciz "Cancel"
.Lwho: .asciz "Claude Code"
.Lno_run: .asciz "Claude Code could not be started."
.Lk_hooks: .asciz "hooks"
.Lk_events: .asciz "events"
.Lk_catalog: .asciz "eventCatalog"
.Lk_policy: .asciz "policy"
.Lk_errors: .asciz "errors"
.Lk_safeMode: .asciz "safeMode"
.Lk_bareMode: .asciz "bareMode"
.Lk_managedStill: .asciz "managedHooksStillApply"
.Lk_exitHint: .asciz "exitHint"
.Lk_disabledByPolicy: .asciz "disabledByPolicy"
.Lk_managedOnly: .asciz "managedOnly"
.Lk_pluginOnly: .asciz "pluginOnly"
.Lk_allDisabled: .asciz "allDisabled"
.Lk_policyCount: .asciz "policyHookCount"
.Lk_policyUnreadable: .asciz "policyUnreadable"
.Lk_name: .asciz "name"
.Lk_summary: .asciz "summary"
.Lk_supportsMatcher: .asciz "supportsMatcher"
.Lk_event: .asciz "event"
.Lk_matcher: .asciz "matcher"
.Lk_source: .asciz "source"
.Lk_sourceLabel: .asciz "sourceLabel"
.Lk_type: .asciz "type"
.Lk_displayText: .asciz "displayText"
.Lk_commandText: .asciz "commandText"
.Lk_contentLabel: .asciz "contentLabel"
.Lk_pluginName: .asciz "pluginName"
.Lk_condition: .asciz "condition"
.Lk_timeout: .asciz "timeout"
.Lk_statusMessage: .asciz "statusMessage"
.Lk_runsOnce: .asciz "runsOnce"
.Lk_runsInBackground: .asciz "runsInBackground"
.Lk_disabled: .asciz "disabled"
.Lk_editable: .asciz "editable"
.Lk_config: .asciz "config"
.Lk_op: .asciz "op"
.Lk_target: .asciz "target"
.Lk_hook: .asciz "hook"
.Lk_ok: .asciz "ok"
.Lk_code: .asciz "code"
.Lk_refusal: .asciz "refusal"
.Lk_file: .asciz "file"
.Lk_error: .asciz "error"
.Lv_listing: .asciz "get_hooks_listing"
.Lv_pretool: .asciz "PreToolUse"
.Lv_add: .asciz "add"
.Lv_replace: .asciz "replace"
.Lv_remove: .asciz "remove"
.Lv_command: .asciz "command"
.Lv_prompt: .asciz "prompt"
.Lv_agent: .asciz "agent"
.Lv_http: .asciz "http"
.Lv_mcp_tool: .asciz "mcp_tool"
.Lv_bash: .asciz "bash"
.Lv_powershell: .asciz "powershell"
.Lv_localSettings: .asciz "localSettings"
.Lv_userSettings: .asciz "userSettings"
.Lv_projectSettings: .asciz "projectSettings"
.Lv_flagSettings: .asciz "flagSettings"
.Lv_policySettings: .asciz "policySettings"
.Lv_sessionHook: .asciz "sessionHook"
.Lv_pluginHook: .asciz "pluginHook"
.Lv_builtinHook: .asciz "builtinHook"
.Lv_unloadable: .asciz "unloadable"
.Lv_legacy: .asciz "legacy"
.Lv_twins: .asciz "twins"
.Lv_notalist: .asciz "not-a-list"
.Lv_array: .asciz "array"
.Lv_object: .asciz "object"
.Lv_proto: .asciz "__proto__"
.Lv_constructor: .asciz "constructor"
.Lv_prototype: .asciz "prototype"
.Lv_edit_hook_c: .asciz "edit_hook: "
.Lv_edit_hook_s: .asciz "edit_hook "
.Lw_user: .asciz "User"
.Lw_project: .asciz "Project"
.Lw_local: .asciz "Local"
.Lw_flag: .asciz "Flag"
.Lw_managed: .asciz "Managed"
.Lw_session: .asciz "Session"
.Lw_plugin: .asciz "Plugin"
.Lw_builtin: .asciz "Built-in"
.Lso_local_d: .asciz "Private to you in this project (.claude/settings.local.json)"
.Lso_user_d: .asciz "Available in all your projects (~/.claude/settings.json)"
.Lso_project_d: .asciz "Shared via .claude/settings.json in this project"
.Lt_command: .asciz "Command"
.Lt_command_d: .asciz "Runs a shell command"
.Lt_prompt: .asciz "Prompt"
.Lt_prompt_d: .asciz "Asks a model to evaluate a prompt"
.Lt_agent: .asciz "Agent"
.Lt_agent_d: .asciz "Runs an agent to verify something"
.Lt_http: .asciz "HTTP"
.Lt_http_d: .asciz "Posts the hook input to a URL"
.Lt_mcp: .asciz "MCP tool"
.Lt_mcp_d: .asciz "Calls a tool on a configured MCP server"
.Lsh_default: .asciz "Default"
.Lsh_default_d: .asciz "bash where available, PowerShell on Windows without Git Bash"
.Lsh_pwsh: .asciz "PowerShell"
.Lf_command: .asciz "command"
.Lf_command_l: .asciz "Command"
.Lf_args: .asciz "args"
.Lf_args_l: .asciz "Arguments (JSON array, optional; no shell when set)"
.Lf_shell: .asciz "shell"
.Lf_shell_l: .asciz "Shell"
.Lf_async: .asciz "async"
.Lf_async_l: .asciz "Run in background"
.Lf_prompt: .asciz "prompt"
.Lf_prompt_l: .asciz "Prompt"
.Lf_model: .asciz "model"
.Lf_model_l: .asciz "Model (optional)"
.Lf_continue: .asciz "continueOnBlock"
.Lf_continue_l: .asciz "Keep going when this prompt blocks, instead of ending the turn"
.Lf_url: .asciz "url"
.Lf_url_l: .asciz "URL"
.Lf_url_ph: .asciz "https://example.com/hook"
.Lf_headers: .asciz "headers"
.Lf_headers_l: .asciz "Headers (Header-Name: value, one per line; stored values are kept unless you retype them)"
.Lf_envvars: .asciz "allowedEnvVars"
.Lf_envvars_l: .asciz "Environment variables allowed in headers (one per line)"
.Lf_server: .asciz "server"
.Lf_server_l: .asciz "MCP server"
.Lf_tool: .asciz "tool"
.Lf_tool_l: .asciz "Tool"
.Lf_input: .asciz "input"
.Lf_input_l: .asciz "Input (JSON object, optional)"
.Lf_if: .asciz "if"
.Lf_if_l: .asciz "Only when the tool call matches (optional)"
.Lf_if_ph: .asciz "Bash(git *)"
.Lf_timeout: .asciz "timeout"
.Lf_timeout_l: .asciz "Timeout in seconds (optional)"
.Lf_status: .asciz "statusMessage"
.Lf_status_l: .asciz "Status message while running (optional)"
.Lh_waiting: .asciz "Waiting for settings from Claude Code\342\200\246"
.Lh_files_failed: .asciz "A settings file could not be parsed, so hooks defined there are not shown and will not run."
.Lh_safe: .asciz "Safe mode: hooks from settings files are suspended and will not run this session"
.Lh_safe_managed: .asciz " (managed policy hooks still apply)"
.Lh_safe2: .asciz "; session hooks created by /goal, agents, and skills still run. Settings edits save but don't load until safe mode is off."
.Lh_bare: .asciz "Bare mode: hooks from settings files, plugins, and managed policies are disabled and will not run this session; session hooks created by /goal, agents, and skills still run."
.Lh_reenable: .asciz " to re-enable."
.Lh_unreadable: .asciz "Your organization's managed settings could not be read, so hooks cannot be edited here."
.Lh_policy_off: .asciz "All hooks are currently disabled by a managed settings file. You have "
.Lh_wont_run: .asciz " configured that will not run."
.Lh_managed_only: .asciz "Only hooks from managed settings can run. Hooks from user, project, local, and flag settings are blocked, and managed hooks are not shown here."
.Lh_plugin_only: .asciz "Your organization restricts hooks to managed and plugin sources. Hooks from user, project, local, and flag settings will not run, and managed hooks are not shown here."
.Lh_all_off: .asciz "All hooks are currently disabled by the disableAllHooks setting. You have "
.Lh_managed_still: .asciz " Hooks from managed settings still run \342\200\224 "
.Lh_none: .asciz "No hooks configured"
.Lh_none_hint: .asciz "Hooks run your commands, prompts, or HTTP calls in response to Claude Code events like tool calls and prompt submission."
.Lh_none_hint2: .asciz "Hooks run your commands, prompts, or HTTP calls in response to Claude Code events like tool calls and prompt submission. Configure them in settings.json."
.Lh_configured: .asciz " configured"
.Lh_hook: .asciz " hook"
.Lh_hooks: .asciz " hooks"
.Lh_matcher_c: .asciz "Matcher: "
.Lh_all: .asciz "(all)"
.Lh_disabled_badge: .asciz ", Disabled"
.Lh_foot_edit: .asciz "Click a hook to view, edit, or remove it. Managed, plugin, session, and built-in hooks are read-only."
.Lh_foot: .asciz "To add or modify hooks, edit settings.json directly or ask Claude."
.Lh_learn: .asciz "Learn more about hooks"
.Lh_open_file: .asciz "Open settings file"
.Lh_copy_error: .asciz "Copy error"
.Lh_copied: .asciz "Copied to clipboard"
.Lh_url: .asciz "https://code.claude.com/docs/en/hooks"
.Lh_add: .asciz "Add hook"
.Lh_save: .asciz "Save hook"
.Lh_saving: .asciz "Saving\342\200\246"
.Lh_remove: .asciz "Remove"
.Lh_confirm: .asciz "Confirm remove"
.Lh_removing: .asciz "Removing\342\200\246"
.Lh_remove_q: .asciz "Remove this hook from "
.Lh_remove_q2: .asciz " settings?"
.Lh_filter_events: .asciz "Filter events\342\200\246"
.Lh_disabled_warn: .asciz "Disabled: this hook will not run this session."
.Lh_by_plugin: .asciz "Defined by the "
.Lh_by_plugin2: .asciz " plugin; change it in the plugin."
.Lr_policy: .asciz "Set by your organization in managed settings."
.Lr_flag: .asciz "Set for this session by the --settings startup option."
.Lr_plugin: .asciz "Defined by a plugin; change it in the plugin."
.Lr_session: .asciz "Registered for this session by a skill, an agent, or a goal."
.Lr_builtin: .asciz "Built into Claude Code."
.Lh_locked: .asciz "Hooks are locked by a managed settings file, so this one cannot be edited here."
.Lh_type_not: .asciz "This hook type cannot be edited here."
.Lh_event: .asciz "Event"
.Lh_matcher: .asciz "Matcher"
.Lh_type: .asciz "Type"
.Lh_source: .asciz "Source"
.Lh_plugin: .asciz "Plugin"
.Lh_if: .asciz "If"
.Lh_timeout: .asciz "Timeout"
.Lh_status: .asciz "Status message"
.Lh_flags: .asciz "Flags"
.Lh_once: .asciz "runs once"
.Lh_bg: .asciz "runs in background"
.Lh_add_title: .asciz "Add hook"
.Lh_edit_title: .asciz "Edit hook"
.Lh_save_to: .asciz "Save to"
.Lh_event_c: .asciz "Event: "
.Lh_matcher_f: .asciz "Matcher (leave empty to match everything)"
.Lh_matcher_ph: .asciz "Bash"
.Lh_required: .asciz " is required."
.Lh_number: .asciz " must be a number above 0."
.Lh_must_json: .asciz " must be a JSON "
.Lh_hdr_bad: .asciz "Headers must be \"Header-Name: value\" (line "
.Lh_line_end: .asciz ")."
.Lh_hdr_name: .asciz "Header name "
.Lh_not_allowed: .asciz " is not allowed."
.Lh_saved_to: .asciz "Saved to "
.Lh_saved_to2: .asciz " settings. If the change is not shown yet, Claude Code is still re-reading its settings; reopen this dialog to check."
.Lh_settings_word: .asciz " settings"
.Lh_thing: .asciz "the hook"
.Lh_ref_legacy: .asciz "This hook lives in this folder's own settings.local.json, which the dialog cannot edit."
.Lh_ref_the_cap: .asciz "The "
.Lh_ref_the: .asciz "the "
.Lh_ref_file: .asciz " settings file"
.Lh_ref_unloadable: .asciz " could not be loaded, so the hook could not be saved."
.Lh_ref_twins: .asciz "More than one identical hook is in "
.Lh_ref_twins2: .asciz ", so the dialog cannot tell which one to change."
.Lh_ref_entry: .asciz " entry in "
.Lh_ref_notalist: .asciz " is not a list, so the hook could not be saved."
.La_edit_hook: .asciz "edit-hook"
.La_json: .asciz "--json"
